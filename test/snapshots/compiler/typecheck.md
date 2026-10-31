# META
source_lines=3740
stages=DESUGAR,MARK
# SOURCE
-- typecheck: the entry module: the graph drive (`driveGraphK`), the chain and core memos and
-- interface continuation, serving, import seeding, publication, value-main judgment,
-- configuration and the verb-facing API; the pre-inference alias rewrite, a driver step
-- (`aliasSchemes`, `aliasSchemeEntry`, `coreAliasSchemes`, `renameAliasedMethods*`,
-- `deAliasMethod*`, `resolveAliasMethodSpellings`); and the `export import types.publish` facade.
-- Everything else the typechecker does is a `tc_*` module's: the per-module check is
-- `types/tc_module.mdk`'s, interfaces, impls and coherence are `types/tc_global.mdk`'s, the
-- dict-passing elaboration the backends consume is `types/tc_elab.mdk`'s, the expression
-- recursion and exhaustiveness are `types/tc_infer.mdk`'s and `types/tc_infer_records.mdk`'s,
-- and the solver lives in the `tc_solve*` modules. `checkMatchExhaustive`
-- (`compiler/frontend/exhaust.mdk`) is called once per `EMatch` from `tc_infer`
-- ([P-EXHAUST-IN-TYPECHECK]). Architecture doc: `compiler/types/ARCHITECTURE.md`.
--
-- Spec: TYPECHECK-CONTRACTS section 4, section 5; DICT section 7.1, section 8.
--
-- Placement: this is the entry module (P4-D4); declarations are placed by R1-R6 of the Phase 4
-- module table, compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module imports the `tc_*` modules and no `tc_*` module imports it.
-- `preludeMarkFactsOf` stays here: its home is `tc_occurrence`, which was at the A8 band when
-- extracted, and a `tc_mark` module would hold it (owed, Val).
--
-- One solving graph driver, two output selections.  `driveGraphK` is the single whole-graph
-- solving driver: `GOutDiags` (per-module diagnostics and schemes) is what `medaka check`,
-- `check --json`, the LSP, MCP, the playground and `medaka test`'s gate consume, and
-- `GOutTrees` (the same diagnostics plus the elaborated, dict-passed trees, the
-- residual and the evidence table) is what `run`, `build`'s child, `medaka test`'s
-- phases and the emit entries consume.  They share one preamble, one per-module
-- worker and one graph-end drain, so a module is checked against the same universe,
-- the same seed and the same mark sets on both.  `checkModulesK`, `checkModulesPartialK` and
-- `checkModulesPartialLast` (LSP hover and completion reach the second through
-- `driver/diagnostics.mdk`) are a second fold, `cmFold`: it marks but does not solve or drain,
-- so its types are not the drive's by construction.  A keyed diagnostics drive
-- (`checkModulesDiagsChain (Some …)`) hands the one fold a serve policy (`diagsServe`),
-- which serves each unchanged module before the entry from its recorded interface
-- (`types/module_interface.mdk`) instead of checking it.
--
-- One thing the selections still differ on by construction, and it is observable:
-- `GOutTrees` promotes (inferred-constraint user fns join the dict-name set).  So
-- acceptance under one selection is still not proof about the other for a program that
-- promotes an inferred-constraint fn across modules; its consequence for the gate over
-- this compiler's own source is #1811.  `renameAliasedMethods` is NOT a second such
-- difference: it runs on both selections, because half (b) of it decides which
-- declaration a bare method name binds to, so skipping it on one selection would make
-- that selection typecheck a different program
-- (`test/run_check_agreement_fixtures/reject_1812_alias_import_order.mdk` and its
-- permuted accepting twin).
--
-- Single-file consumers are one-module projections of the same graph driver. There
-- is no second stamper order; `checkOne*` and `elaborateOne`
-- supply the one-module entry surface.

import types.invocation_basis.{
  readInvocationView,
  requestedWrapperViewModules,
  invocationResolver,
  slotVariances,
  ctorsByHead,
  paramPolaritiesIn,
  frozenInvocationOps,
  completionInvocationViews,
}

import frontend.ast.{
  Ns(..),
  DataVis(..),
  implMethodName,
  Ty(..),
  EffParamTy(..),
  TyConOrigin(..),
  Ident(..),
  EvId(..),
  EvVal(..),
  EvEntry(..),
  Pat(..),
  Expr(..),
  Loc(..),
  Decl(..),
  UsePath(..),
  UseMember(..),
  useMemberOrigin,
  useMemberAlias,
  qualifiedLocal,
  TabKey(..),
  lookupTab,
}
import types.repr.{
  Tyvar(..),
  normalize,
  IfaceRef(..),
  Mono(..),
  Scheme(..),
  VecObl(..),
  spineParts,
}
import types.effect_param_decode.{
  dtopIn,
  writtenParam,
}
import types.effect_domain.{
  Param(..),
}
import types.effect_rows.{
  Atom(..),
  builtinLabel,
  atomWith,
  pureRow,
}
import types.effect_solver as EffectSolver
import types.effect_invocation.{InvocationOps(..)}
import types.tc_types.{
  StandaloneOrigin(..),
  SiteKind(..),
  ServeStep(..),
  Provenance(..),
  NumBoundaryDisposition(..),
  GoalPayload(..),
  DeclaringBinder(..),
  Accumulate(..),
  ModulePlace(..),
  FoldPlan(..),
  siteFor,
  DeclEnvModule(..),
  DeclEnvs(..),
  ImplRow(..),
  ImplEnv(..),
  ClassEnv(..),
  GraphCtx(..),
  TcConfig(..),
  DriveInputs(..),
  DriveArgs(..),
  DriveOutputs(..),
  withPublishedManifests,
  manifestDriverFor,
  Predicate(..),
  GraphRun(..),
  ModuleCtx(..),
  InvocationView(..),
  ModuleBindings(..),
  ExportBinding(..),
  ModuleSeed(..),
  PreludePreamble(..),
  GraphOut(..),
  ModuleServe(..),
  GraphDrive(..),
  GraphPreamble(..),
  ElabResult(..),
  ElabFacts(..),
  DrainFinding(..),
  MarkSets(..),
  PreludeMarkFacts(..),
}
import map as IdMap

import types.evidence.{
  ScopeId(..),
}
import types.scopes.{
  ScopeOwner(..),
}
import types.scopes as Scopes
export import types.publish.{
  TcDiag(..),
  tcCode,
  tcMsg,
  ModDiags,
  pubSchemes,
}
import types.publish.{
  PubScheme(..),
  tcLoc,
  TcReport,
  PartialAnalysis,
  EntryTables(..),
  noEntryTables,
  partialAnalysis,
  freezePub,
  freezeRows,
  freezeModDiags,
  graphReportWithOutcome,
  publishSelected,
  publishCore,
  publishWithContexts,
  publishedCore,
  publishedEntrySchemes,
  ppPubScheme,
}
import types.entry_outcome.{
  mainUseDiags,
  printlnIface,
  mainBodySpan,
  driveOutputsNow,
  entryOutcomeNow,
  mainIsAsyncNow,
  mainAsyncPayloadIsUnitNow,
  mainIsUnitNow,
}
import frontend.desugar.{mapProg}
import frontend.visibility.{
  useModId,
  pubUsePaths,
  exportedValueNames,
  nsAbstractData,
}
import types.value_main.{inMainBinding}
import frontend.resolve.{
  programIsCore,
  -- #1280: the extern-signature half of the identity supply — see `externSchemes`.
  stampTyOrigins,
  runtimeExternTyOriginScope,
}
-- The type-aware non-exhaustive-`match` check (`check_match` in compiler/frontend/exhaust.mdk)
-- reuses the Maranget matrix machinery already ported in exhaust.mdk — the only
-- difference from the guard-coverage pass is the ctor oracle (here it comes from
-- the typechecked program's data decls + the inferred scrutinee type).
import types.private_mangle.{mangledName}
import support.ordmap.{
  OrdMap,
  omEmpty,
  omInsert,
  omLookup,
  omHasKey,
  omKeys,
  omFromPairs,
  omFromNames,
  omMapValues,
}
import list.{
  drop,
  take,
  last,
}
import support.util.{
  listLen,
  lookupAssoc,
  contains,
  reverseL,
  joinWith,
  joinNl,
  filterList,
  anyList,
  isNonEmptyL,
  isSome,
  dedup,
  lenKey,
  sortUniqS,
}
-- Stage A-2 unit A-2.2 (#1111): the head-tycon projections below return a key
-- that CAN carry identity.  `HeadKey`'s declaration half is A-2.3's `TabKey`
-- itself; why it has a second inhabitant anyway, and why the `Option` around
-- it stays, are derived at the type in that file.
import types.registry.{
  HeadKey(..),
  identKey,
  regKeyOfTab,
  -- the registry types the impl and class tables are built from.
  -- the cross-run constructor and record populations (`CrossRun`).
}
-- B-2.2-e: THE route-word mint, shared with `eval/eval.mdk` and
-- `ir/core_ir_lower.mdk`.  Before this bite each of those spelled its own copy
-- (`implKeyTc` here, `implKeyOf` there) over its own `Ty` printer; they are now
-- one function, so the caller side and the definition side of the dict-word seam
-- agree BY CONSTRUCTION rather than by two mirrors staying in lockstep.
import types.route_key.{
  typeTagOf,
  implRouteKeyWord,
  ifaceWordOf,
}
import types.disposition.{
  InstId(..),
  MethodDisposition(..),
  DispositionTable,
  InstanceShape(..),
  buildDispositionTableWithShapes,
  validateDispositionTable,
}
import types.target_profile.{
  TargetProfile,
  hostLabels,
  ioJoinGrants,
  profileName,
}
import types.runtime_types.{
  RuntimeType(..),
}
import types.program_facts.{ProgramFacts, factsOfElab}
import types.serve_policy.{ServeOps(..), serveStateOf, diagsServe, treeServe}
import types.prelude_interface.{
  PreludeInterface,
  freezeInterface,
  thawInterface,
  seedPreludeInterface,
  preludeCacheHit,
}
import types.prelude_elab.{
  PreludeElab(..),
  heldPreludeEvCounter,
  preludeElabFor,
  withShippedRows,
}
import types.tc_mono.{
  anyMember,
  dedupI,
  headTyconMono,
  instantiateFields,
  invocationHeadKey,
  monoUnboundIds,
  substMono,
  tconBuiltin,
}
import types.tc_state.{
  builtinCtors,
  callUOblsWindow,
  checkRunResidue,
  currentScopeStore,
  emptyDataEnv,
  freshGraphRun,
  graphLineageRun,
  initialGraphCtx,
  initialModuleCtx,
  interners,
  internersOf,
  mctxAt,
  mintGraphCtx,
  noteHighWater,
  noteInterners,
  raiseToHighWater,
  wMark,
}
import types.tc_env.{
  aliasOwnAt,
  aliasUniverseAt,
  boundNames,
  ceLookupAt,
  ceRowMethodNames,
  ceRowRequired,
  declEnvModule,
  emptyDeclEnvAcc,
  funDefs,
  graphPubDefiners,
  ieRowInst,
  ieRowMethodNames,
  ieRowOrd,
  ieRowsAll,
  ieRowTriple,
  ifaceMethodNames,
  ifaceTabKey,
  importedBindings,
  instRefMid,
  instRefSeq,
  methodExportsIndex,
  namesToSet,
  ordOfIndex,
  publicDataDecls,
}
import types.tc_diag_text.{
  prependConflict,
  prependIncomparable,
  dropAmbiguity,
  stickyDiagsInPushOrder,
}
import types.tc_scope.{
  aliasRowSpelling,
  importFormRows,
  memberAliasCands,
  moduleAliasKeys,
  useKeyCands,
}
import types.tc_unify.{
  ambiguousImportTyvarId,
  enterLevel,
  exitLevel,
  freshVar,
  instantiateTracked,
  lookupSchemeObls,
  recordObl,
  recordSchemeCallObligations,
  unify,
  closeScope,
}
import types.tc_decls_types.{
  populateEffectDomainsGraph,
}
import types.tc_decls.{
  buildDeclEnvs,
  dataEnvFromDeclsGo,
  declEnvAccOf,
  declEnvModulesFrom,
  pubTopFnNames,
  stampGraphDecls,
  withDeclParamKinds,
}
import types.tc_foreign.{
  directExternSigs,
  externDecls,
  externSigsToMap,
  ffiExternTypeRowsWith,
}
import types.tc_solve_entail.{
  directSuperGoals,
}
import types.tc_solve.{
  goalsMark,
  openScope,
  returnPosMethodNames,
  routesOfMonosTopV,
}
import types.tc_solve_check.{
  checkCallObligationsU,
}
import types.tc_effects.{
  grantOrder,
}
import types.tc_occurrence.{
  argDispatchIndices,
  argDispatchIndicesById,
  constrainedSigNames,
  markDictNames,
  markSetsOf,
  methodConstraintNames,
}
import types.tc_groups.{
  allEVars,
}
import types.tc_elab.{
  dictPassModulesIfEnabled,
  drivenEvidence,
}
import types.tc_global.{
  globalCoherenceConflict,
}
import types.tc_module.{
  captureTypeErrors,
  checkBodyImpl,
  checkGraphFinish,
  checkModuleFull,
  checkModuleFullDiags,
  drainStampQueue,
  elabModuleStamp,
  externSchemesGo,
  settleClosedBody,
  verdictFinding,
}

-- What `IO` joins in this drive: the selected profile's grants of the alias
-- labels, each at the parameter granted, in `hostLabels` order.  With no
-- profile that is all eleven at their tops.  Every module of the program is
-- judged against the one join, the shipped stdlib included.
export
ioJoinAtoms : List (String, Param) -> List (String, EffParamTy) -> List Atom
ioJoinAtoms domains grants =
  filterMap
    (l =>
      map
        (granted =>
          atomWith
            (builtinLabel l)
            (writtenParam (dtopIn domains (builtinLabel l)) granted))
        (lookupAssoc l grants))
    hostLabels

-- The names of all `VisAbstract` data decls.  Only record-shaped ones can be a
-- dot-access receiver, but harvesting any is harmless: a positional ADT's fields
-- never exist, so a field access cannot reach the abstract branch.
collectAbstractRecordTypes : List Decl -> List String
collectAbstractRecordTypes decls = flatMap nsAbstractData.nsDirectOf decls

-- seed abstractRecordTypesRef from every module's decls (the per-module progs plus
-- the prelude/core decls), once, before checking begins.  Keyed by the type
-- word (`typeTagOf`), so a program's own type that shares an abstract export's
-- name is not mistaken for it.
seedAbstractRecordTypes : GraphCtx ->
  List Decl ->
  List (String, List Decl) ->
  Unit
seedAbstractRecordTypes gctx coreDecls modules =
  let abstracts =
    collectAbstractRecordTypes coreDecls
      ++ flatMap (m => abstractTypeWords (fst m) (snd m)) modules
  gctx.abstractRecordTypesRef := namesToSet abstracts omEmpty

abstractTypeWords : String -> List Decl -> List String
abstractTypeWords mid decls =
  map (n => typeTagOf (OriginModule mid) n) (collectAbstractRecordTypes decls)

-- Test-only observation (R5): read by `typecheck_test.mdk`, no production caller.
--
-- #2544 (M4): every diagnostic that armed the sticky gate in the drive, each tagged
-- with the module it was recorded in, in push order, deduplicated PER GOAL —
-- module, code, location and text together — never by text alone (a text key would
-- re-introduce the suppressed-check shape OD5 forbids: two goals at two sites with
-- the same rendering are two findings).
export
stickyTypeErrorDiags : DriveOutputs -> List (String, TcDiag)
stickyTypeErrorDiags o = stickyDiagsInPushOrder o.doStickyDiags

-- True iff the drive recorded a type error, as the drive left it.
export
hadTypeErrors : DriveOutputs -> Bool
hadTypeErrors o = o.doHadTypeErrors

-- Whether the `main` binding recorded obligations remains inference-private; the
-- publication module receives its Boolean answer rather than this side table.
mainHasObligations : ModuleCtx -> Bool
mainHasObligations mctx =
  let id = optionOr 0 (omLookup "main" mctx.mcCells.schemeDefIdsRef.value)
  match lookupSchemeObls "main" id mctx.mcCells.schemeObligationsRef.value
    Some (_ :: _) => True
    _ => False

-- True iff the last typecheck pass pushed any match warning.  Read by the snapshot
-- runner (`tools/snapshot.mdk`) to decide whether a rendered `# TYPES` section carries
-- diagnostic prose — a `W-*` warning is graded by `compiler/ERROR-QUALITY.md` exactly
-- like an error is, so a `# TYPES` section holding one is NOT `--bless`-able.  Keyed on
-- the accumulator rather than sniffing the rendered text: the renderer must not have to
-- guess which of its own lines are diagnostics.
export
hadMatchWarnings : DriveOutputs -> Bool
hadMatchWarnings o = o.doHadMatchWarnings

-- The drive inputs of a driver that loads no stdlib ownership and selects no
-- profile: no module stdlib-owned, the flat entry not stdlib, every trace off, and
-- the `IO` join of no profile.  A pure value (it holds no `Ref`).
--
-- No ownership means every `extern` is stamped (#2072, `ffiStampModeOwned`), and that
-- direction is the safe one on purpose: a driver that passes no ownership suppresses
-- nothing, so the worst it can do is render an `FFI` atom on the stdlib catalog when
-- someone points it at stdlib source.  The inverse default would leave #2072's hole
-- (a user `extern f : Int -> <> Int` typing pure) open on every such path, which is
-- a soundness hole rather than a cosmetic one.
export
defaultDriveInputs : DriveInputs
defaultDriveInputs = DriveInputs {
  diExecutedMainDriver = None,
  diManifestRequests = [],
  diStdlibOwned = omEmpty,
  diFlatEntryIsStdlib = False,
  diTrace = None,
  diIoJoinGrants = ioJoinGrants None,
  diProfileName = "",
  diPreludeKey = None,
}

-- The drive inputs a driver builds from the profile it selected and the loader's
-- owning-root fact (`stdlibOwnership`, `driver/loader.mdk`): whether the flat entry
-- is a stdlib module, and the stdlib-owned module ids.  That fact is read by
-- `ffiStampMode`, which decides whether an `extern` DECLARATION in the program
-- under check is the stdlib's extern catalog (never stamped) or a user's FFI
-- declaration (always stamped).
--
-- Two ownership fields because graph checks carry different amounts of identity.
-- `Module mid _ _` has a module id, so the Module arm asks "is THIS module
-- stdlib-owned" of the set.  `Flat _` has no id at all (the flat driver has already
-- flattened the program into one anonymous decl list), so the entry's ownership
-- arrives as its own Bool.
--
-- NOT `projectTrustedMods` (`driver/loader.mdk`): that predicate answers a different
-- question (may module M *reference* an internal-only extern?) and is opt-in-able
-- from any `medaka.toml` via `allow-internal` (#1713).  Routing this through it would
-- let a user exempt their own externs from the stamp by writing one manifest line.
export
driveInputsFor : Option TargetProfile -> Bool -> List String -> DriveInputs
driveInputsFor profile flatEntry mods = { defaultDriveInputs |
  diStdlibOwned = namesToSet mods omEmpty,
  diFlatEntryIsStdlib = flatEntry,
  diIoJoinGrants = ioJoinGrants profile,
  diProfileName = match profile
    None => ""
    Some p => profileName p,
}

-- The summary's operations over the view of the entry the drive [o] checked.  The
-- field instantiation runs in a graph record of its own, whose effect-variable
-- counter continues from the drive's (`doEffvarNext`).
lastInvocationOps : DriveOutputs -> InvocationOps
lastInvocationOps o = match o.doInvocationView
  InvocationView ctors pols kinds =>
    let byHead = ctorsByHead invocationHeadKey ctors
    let gctx = initialGraphCtx builtinCtors (freshGraphRun ())
    gctx.graphRun.effvarCounter := o.doEffvarNext
    InvocationOps {
      headVariances =
        h => match headTyconMono h
          Some (HkDecl key) =>
            slotVariances (paramPolaritiesIn pols key) (lookupTab key kinds)
          _ => None,
      appliedFields =
        applied =>
          let (h, args) = spineParts applied
          flatMap
            (c => instantiateFields gctx args c)
            (optionOr [] (omLookup (invocationHeadKey h) byHead)),
      headKey = invocationHeadKey,
    }

-- The context the module last checked recorded for its binding [n].
ownContext : ModuleCtx -> String -> List VecObl
ownContext mctx n =
  -- #837: key the obligation lookup by (name, binding-id), exactly as the check-path
  -- reader does — recovering the id from schemeDefIdsRef (top-level binders of the
  -- module last checked).  With the leak-guard windows retired this is what stops a
  -- where-helper `g`'s obligation rendering on an unrelated top-level `g`; a binder
  -- absent from schemeDefIdsRef (id 0) falls to the bare-name scan (today's path).
  let id = optionOr 0 (omLookup n mctx.mcCells.schemeDefIdsRef.value)
  optionOr [] (lookupSchemeObls n id mctx.mcCells.schemeObligationsRef.value)

-- A module's own schemes, each with its context, taken when the module closes:
-- [mctx] still holds that module's tables, and the next module's check
-- mints its own record.
publishOwn : ModuleCtx -> List (String, Scheme) -> List (String, PubScheme)
publishOwn mctx = publishWithContexts (ownContext mctx)

-- Core's own obligations, keyed by bare name (#837: the binding-id half of each
-- key is dropped, as every cross-module reader looks a prelude name up by name).
-- Read right after the core pass, from the record [mctx] core was checked in.
coreOwnContexts : ModuleCtx -> OrdMap (List VecObl)
coreOwnContexts mctx =
  omFromPairs
    (map (kv => (fst (fst kv), snd kv)) mctx.mcCells.schemeObligationsRef.value)
    omEmpty

-- The context a seed name renders with, by three steps in order.  A name the
-- module last checked BINDS takes that module's own context, or none, and never
-- reaches the prelude store, so a buffer's own `isEven x = "s"` cannot pick up the
-- prelude `isEven`'s context (#2054's shape).  The prelude's contexts are consulted
-- ONLY for a name this module does not bind and whose per-run table has no entry
-- at all: on the module arm each module gets its own `freshModuleCtx`, so the
-- prelude's obligations are not in [mctx], and a prelude scheme would otherwise
-- render without its `=>`.
-- The third step reads [coreContexts], the prelude's contexts keyed by bare name.
seedContext : ModuleCtx -> OrdMap (List VecObl) -> String -> List VecObl
seedContext mctx coreContexts n =
  match omLookup n mctx.mcCells.schemeDefIdsRef.value
    Some _ => ownContext mctx n
    None => match lookupSchemeObls n 0 mctx.mcCells.schemeObligationsRef.value
      Some obs => obs
      None => optionOr [] (omLookup n coreContexts)

-- The last module of [modules], checked in [mctx]: its locals and its import seed,
-- frozen with their contexts.  The seed's prelude contexts come from
-- [coreContexts], `graphPreamble`'s snapshot.
captureEntryTables : ModuleCtx ->
  OrdMap (List VecObl) ->
  List (String, List Decl) ->
  EntryTables
captureEntryTables mctx coreContexts modules = match last modules
  None => noEntryTables
  Some (mid, _) => EntryTables {
    etModule = mid,
    etLocals =
      map
        ((n, loc, s) => (n, freezePub s (ownContext mctx n), loc))
        mctx.mcCells.localSchemesOut.value,
    etSeed =
      map
        (b => (
          fst b,
          freezePub (snd b) (seedContext mctx coreContexts (fst b)),
        ))
        mctx.mcCells.seedSchemesOut.value,
  }

-- How many grants a top-level binding with this scheme takes ahead of its value
-- arguments.
export
bindingGrantArity : DriveOutputs -> String -> Scheme -> Int
bindingGrantArity o _ sch =
  if o.doGrantsEnabled then listLen (grantOrder sch) else 0

-- ── 1-module wrapper over the multi-module path ────────────────────────────
-- elaborateOne runs the SINGLE program [prog] (the user's decls, the live prelude
-- ALREADY shadow-dropped by the caller) through elaborateModules as the degenerate
-- 1-module list [(rootId, prog)], returning the flat shape its callers consume:
-- core2 (dict-passed core) ++ the dict-passed module's decls.
--
-- The 1-module case automatically satisfies that shape's invariants — one
-- `freshModuleCtx` (one module ⇒ one checkModuleFullImpl), zero imports ⇒ the full
-- constraint set, and elaborateModules runs the eval-dict layer unconditionally
-- (ARGSTAMP-UNIFY Phase 4), so the return-position constrained-fn dict layer is
-- present here too.
--
-- The dict-name set is the module path's own: elaborateModules computes it via
-- `moduleDictNames` (the prelude's constrained names followed by the module graph's
-- FULL `constrainedSigNames`), rather than taking an externally built list.  This
-- wrapper therefore takes `coreDecls` SEPARATE (not pre-flattened into prog),
-- exactly as elaborateModules expects.  The grader for the Flat-vs-Module relation
-- is test/diff_compiler_flat_vs_onemodule.sh (ARCH B-2.1-a): it now pins the
-- own acceptance and diagnostics, and grades the relation only through a clause
-- true on both sides of the #1564 fix — every arm that ACCEPTS must compute the
-- same value.  Read its header before changing either arm.
export
elaborateOne : DriveInputs ->
  List Decl ->
  List Decl ->
  (String, List Decl) ->
  List Decl
elaborateOne inputs runtimeDecls coreDecls prog =
  fst (elaborateOneFacts inputs runtimeDecls coreDecls prog)

-- `elaborateOne` with the `ProgramFacts` value its elaboration built, for a caller that lowers
-- the flat decls.
export
elaborateOneFacts : DriveInputs ->
  List Decl ->
  List Decl ->
  (String, List Decl) ->
  (List Decl, ProgramFacts)
elaborateOneFacts inputs runtimeDecls coreDecls (rootId, prog) =
  let elab = elaborateModules inputs runtimeDecls coreDecls [(rootId, prog)]
  let coreD = elab.erCore
  let modules = elab.erModules
  (coreD ++ flatMap snd modules, factsOfElab elab)

-- #415 item 3: the ONLY writer of dictEligibleRef / dictEligibleSetRef.  The set is
-- DERIVED from the list here rather than mirrored at each set site, so the two cannot
-- drift: there is no longer a second side for a future edit to be absent from.  (Both
-- former sites hand-wrote `namesToSet <names> omEmpty` next to the list store; the
-- module site additionally recomputed `moduleUserFnNames modules` for the mirror.)
setDictEligible : GraphCtx -> List String -> Unit
setDictEligible gctx names =
  gctx.dictEligibleRef := names
  gctx.dictEligibleSetRef := namesToSet names omEmpty

-- the USER modules' top-level fn names (NOT core/prelude) — the promotion-eligible
-- set on the build path. Mirrors the retired elaborator's user-function eligibility.
moduleUserFnNames : List (String, List Decl) -> List String
moduleUserFnNames modules =
  dedup (flatMap (p => map fst (funDefs (snd p))) modules)

-- The PRELUDE's own `=>`-constrained fns that must ALSO be dict-passed: those
-- whose body uses a return-position method (`when`/`unless` use `pure`), so
-- arg-tag dispatch can't resolve it at a constraint variable's type.  Every OTHER
-- constrained prelude fn (sum/any/elem/clamp/…) uses only arg-position methods —
-- arg-tag already resolves those, and the goldens type-check with them on RKey, so
-- they stay OUT.  [allDecls] supplies the interface set for returnPosMethodNames;
-- bodies come from [preludeDecls] (the shadow-dropped prelude).
export
preludeReturnPosDictNames : List Decl -> List Decl -> List String
preludeReturnPosDictNames preludeDecls allDecls =
  let rpNames = returnPosMethodNames allDecls
  filterList
    (n => anyMember (declBodyVars n preludeDecls) rpNames)
    (constrainedSigNames preludeDecls)

-- D3b-2: the PRELUDE's `=>`-constrained fns that dispatch a method in ARGUMENT
-- position (the ~23 helpers: neq/elem/any/all/find/count/sum/product/maximum/
-- minimum/clamp/flatMap/flat/debugListItems/displayListItems/hashListItems/print/
-- println).  These stay OUT of the eval/golden dict set — arg-tag resolves them in
-- ceval (tagged values) and the goldens type-check with them on RKey — but the
-- NATIVE emit path MUST dict-pass them: arg-tag cannot dispatch on a PRIMITIVE
-- element (an `Int`/`String` immediate carries no cell tag).  The arg-position
-- analogue of preludeReturnPosDictNames: every constrained prelude fn that is NOT
-- already return-position.  Wired (alongside preludeReturnPosDictNames) into the
-- emit + dict_pp-oracle drivers ONLY (llvm_emit_typed_main / core_ir_dict_pp_main),
-- which no golden driver shares — so module/`=== TYPES ===`/eval goldens stay
-- byte-identical; the body sites route RDict $dict_<method>_<slot> through the same
-- activeDictVars layer registerConstraintRegs already builds for return-position.
export
preludeArgPosDictNames : List Decl -> List Decl -> List String
preludeArgPosDictNames preludeDecls allDecls =
  let rpSet = preludeReturnPosDictNames preludeDecls allDecls
  filterList (n => not (contains n rpSet)) (constrainedSigNames preludeDecls)

-- the EVars referenced anywhere in [n]'s definition body (multi-clause: union)
declBodyVars : String -> List Decl -> List String
declBodyVars n decls = flatMap (declBodyVarsOf n) decls

declBodyVarsOf : String -> Decl -> List String
declBodyVarsOf n (DFunDef _ m _ body _ _)
  | n == m = allEVars body
  | otherwise = []
declBodyVarsOf _ _ = []

-- extern declarations become top-level schemes (like interface methods)
--
-- 🚨 #1280: THE STAMPING WALK IS PART OF THIS FUNCTION, NOT OF ITS CALLERS, AND
-- THAT IS THE FIX.  Every other tree that reaches typecheck has already been
-- through `stampTyOrigins` at a driver (`stampGraphTyOrigins` on the module arm,
-- the retired single-program stamping path).
-- `runtimeDecls` was the one tree that reached a `Scheme` without ever entering
-- that walk on EITHER arm, so every `Mono` `fromAstTypeE` built out of an extern's
-- declared type carried `OriginUnresolved` — the SUPPLY half of the dispatch-key
-- blocker recorded at `dispHeadTab`, and the absent head #1279 bridges two
-- distinct identities through.
--
-- The scope is a parameter and not a `List Decl` prelude on purpose: two
-- `List Decl` arguments are positionally interchangeable and `stampTyHead`'s
-- immunity rule makes a wrong first stamp PERMANENT (`stampFlatTyOrigins`'
-- comment in `frontend/resolve.mdk` records that hazard costing a defect once
-- already).  Build it with `externTyOriginScope`, which owns the derivation of
-- WHY one scope is right for this population on both arms.
--
-- ⚠️ `externTyOriginScope []` at a call site is not a shrug: it is the same
-- historical "prelude boundary unknown" answer from that path when its
-- prelude declaration list is `[]` — those callers have already FLATTENED the prelude into the
-- program they check, so the prelude's own `Option`/`Ordering`/`Result`
-- declarations are unstamped on that path too and the two sides stay symmetric.
-- The builtin layer is still supplied there, so it is strictly more identity than
-- before, never a claim the driver cannot justify.
--
-- 🚨 FILTER BEFORE STAMPING, AND THAT ORDER IS PERFORMANCE, NOT STYLE.  The first
-- cut here was `externSchemesGo (stampTyOrigins scope decls)`, which is a no-op
-- difference for `runtimeDecls` (every element IS a `DExtern`) and wrong-shaped at
-- the `checkBodyImpl` call site, where `decls` is the WHOLE MODULE.  Read the
-- chain rather than take this on trust: `stampTyOrigins` is `map
-- (stampDeclTyOrigins scope)`, and `stampDeclTyOrigins` is `mapOriginsInDecl`,
-- i.e. a full `mapTyInDecl` REBUILD of the decl — so that shape reconstructs every
-- declaration in the program and then discards all but the externs, in a stage
-- `compiler/AGENTS.md` calls GC-bound.  Filtering first makes the walk
-- proportional to the externs, which is all this function reads.
--
-- ⚠️ THE MECHANISM ABOVE IS READ OFF THE SOURCE; THE MAGNITUDE WAS NOT MEASURED.
-- No before/after allocation number was taken, so this is a shape argument, not a
-- perf result — do not cite it as one.  It needs no number to be the right shape:
-- rebuilding what you are about to throw away is never the cheaper branch.
externSchemes : ModuleCtx ->
  OrdMap TyConOrigin ->
  List Decl ->
  List (String, Scheme)
externSchemes mctx scope decls =
  let ds = externDecls decls
  -- #2074: THIS function is the stdlib extern CATALOG builder — its one call
  -- site passes `runtimeDecls`, and `userExternSchemes` (`types/tc_module.mdk`) is the
  -- declaration-site sibling that handles the program under check.  So this is
  -- the one seam where the set of names the emitter's `isAnyExtern` ladder will
  -- answer for is known, and it is recorded here rather than re-derived.  See
  -- `ffiIsBuiltinExternName` for what reads it and why.
  noteBuiltinExternNames mctx.mcGraph ds
  externSchemesGo mctx (stampTyOrigins scope ds)

-- Union, never replace: a driver may build the catalog seed more than once per
-- process (`medaka test` runs several engines), and a later call carrying a
-- shorter list must not shrink the set a guard is reading.
--
-- Each row records the catalog's written signature and the positions of its
-- argument binders, which `ffiCheckExternsShadow` and
-- `ffiCheckExternsCatalogRow` (#2163) both read: one map, so the two rules about
-- the same declaration cannot read two tables that fell out of step.
--
-- The signature's rows stay as written labels, not `List Atom`.  `atomsOfWritten`
-- resolves each bare label against `GraphCtx.effectDomains`, and this seam can
-- run before that registry is populated, so both sides are lifted at the check
-- seam, where the registry is the same for both.
--
-- Union means a re-seed REWRITES an existing row rather than skipping it — the two
-- seeds are the same `runtimeDecls` list, so the value is the same pair either
-- way, and preferring the later write keeps the map's contents a function of the
-- last seed rather than of call order.
noteBuiltinExternNames : GraphCtx -> List Decl -> Unit
noteBuiltinExternNames gctx ds =
  gctx.builtinExternNamesRef :=
    externSigsToMap ds gctx.builtinExternNamesRef.value

-- ── canonical checked FFI rows for backend input (#2174/#2135) ─────────────
--
-- A typed emitter must not reinterpret the written heads of `DExtern`: the five
-- declaration guards above have already expanded aliases through the current
-- module's alias table, and accepting one shape while lowering another is exactly
-- #2174's check/build split.  These two exported producers reuse the SAME helper
-- body (`expandAliasHeadTyWith`) against the alias carrier that survives the
-- relevant typed path:
--
--   * flat typed probes derive one side-effect-free stage-K `DataEnv` from their
--     already-stamped declaration list;
--   * module emitters read `DeclEnvs.deData.deAliases`, projected at each module's
--     own ordinal by the same visibility machinery the live typecheck used.
--
-- The builtin subtraction is a lookup in the extern catalog `noteBuiltinExternNames`
-- seeds.  These producers run after their drive, so they read the catalog from the
-- interners, which hold the catalog of the graph record most recently minted or restored.  Lowering
-- therefore no longer independently scans `runtimeDecls` to decide whether a checked
-- declaration routes as a builtin.
-- Typed emitters use these canonical producers for checked extern facts.
export
checkedFfiExternTypeNames : List Decl ->
  List (String, (List (String, String), (List String, String)))
checkedFfiExternTypeNames decls =
  let denv = dataEnvFromDeclsGo 0 decls emptyDataEnv
  ffiExternTypeRowsWith
    interners.value.externCatalog.value
    (aliasOwnAt 0 denv.deAliases)
    decls

export
checkedFfiExternTypeNamesModules : DriveOutputs ->
  List (String, List Decl) ->
  List (String, (List (String, String), (List String, String)))
checkedFfiExternTypeNamesModules o modules =
  flatMap
    (checkedFfiExternTypeNamesModule interners.value.externCatalog.value o)
    modules

checkedFfiExternTypeNamesModule : OrdMap (Ty, List (String, Int)) ->
  DriveOutputs ->
  (String, List Decl) ->
  List (String, (List (String, String), (List String, String)))
checkedFfiExternTypeNamesModule catalog o (mid, decls) =
  let cur = ordOfIndex mid o.doOrdIndex
  let aliases =
    aliasOwnAt cur o.doFfiAliases ++ aliasUniverseAt cur o.doFfiAliases
  ffiExternTypeRowsWith catalog aliases decls

-- Render accumulated type errors as `TYPE ERROR: <msg>` lines (in order of
-- occurrence — typeErrors accumulates newest-first, so reverse).
typeErrorLines : List String -> List String
typeErrorLines [] = []
typeErrorLines (e :: rest) = "TYPE ERROR: " ++ e :: typeErrorLines rest

-- L3 (xmod-identity #1351 spine, RUN-XMOD-022/026): the graph-level fact "this
-- compile's decls carry at least one top-level funDef with its own module's
-- mangle prefix" — the DENOTATION the new GraphCtx flag below actually
-- records (F12).  NOT literally "a mangler ran": a hand-written `m__foo` in
-- module `m` on the un-mangled (check/run) path also satisfies it, harmlessly
-- (see that flag's callers).  Reuses `isMangledFor` (F6) rather than a second
-- prefix test, and `funDefs` rather than a second decl walk.
-- Monomorphic, explicit-recursion, short-circuits on the first hit — do NOT
-- delegate to prelude `any`/`elem` here (AGENTS.md: costed +56% self-compile
-- on this file's hot helpers).
--
-- 🚨 RUN-XMOD-045 CORRECTION (post-landing, slice-breaker finding): on EVERY
-- emit path this flag is CONSTANT TRUE, not merely "true when some module
-- shadows an interface method."  `private_mangle.mdk:14-16` states the
-- mangler's actual scope: "EVERY top-level FUNCTION binding (in core + every
-- module) is renamed to a module-qualified unique symbol," unconditionally,
-- BEFORE `elaborateModules` (and therefore this function) ever runs.  So
-- `core`'s own funDefs already carry the `core__` prefix by the time this
-- walks them, and the very first unit checked (`("core", coreDecls)`, see
-- both call sites below) already satisfies `unitCarriesMangledFunDefs` —
-- MEASURED: a feature-free `main = println 1` build emits ~70 distinct
-- `@mdk_core__*`/`@mdk_<mid>__*` symbols in its own IR with zero user
-- modules, zero shadows, zero interfaces.  The ORIGINAL packet's inertness
-- argument (F8: "a non-empty route symbol implies this flag is True") is
-- still literally correct but was read as "this flag is sometimes False,"
-- which is false — it is NEVER False on the emit path, so F8's implication
-- is vacuously satisfied rather than doing narrowing work.  The precondition
-- F8's phrasing hid: BOTH writers (this flag AND the route-symbol conjunct
-- in `importerShadowOnEmitPath`) are stamped by the SAME compile, and on
-- that compile this flag is always True the moment mangling has run at all —
-- see `importerShadowOnEmitPath`'s own header for the consequence.
--
-- 🚨 THIS FACT CURRENTLY HAS NO DISCRIMINATING CONSUMER — L4's conjunct is
-- constant-True on emit and its partner (`occurrenceCarriesMangledShadowSym`)
-- is always-empty off emit.  It is explicit documentation of an implicit
-- invariant, not a live condition.  Do not migrate a reader onto it
-- expecting it to select.  KEPT (not reverted) by owner ruling because it is
-- provably zero-risk and reads better than the anonymous test it replaced —
-- see `importerShadowOnEmitPath`.
graphCarriesMangledFunDefs : List (String, List Decl) -> Bool
graphCarriesMangledFunDefs [] = False
graphCarriesMangledFunDefs ((mid, decls) :: rest) =
  if unitCarriesMangledFunDefs mid (funDefs decls) then
    True
  else
    graphCarriesMangledFunDefs rest

unitCarriesMangledFunDefs : String -> List (String, (List Pat, Expr)) -> Bool
unitCarriesMangledFunDefs mid [] = False
unitCarriesMangledFunDefs mid ((n, _) :: rest) =
  if isMangledFor mid n then True else unitCarriesMangledFunDefs mid rest

-- WS-1a fix: every impl in scope, EXPORT OR NOT.  Instances are GLOBAL (coherence
-- + dispatch leak across module boundaries regardless of `export`), so the
-- superinterface existence query (checkSuperImpls/superImplExists) must see an
-- imported module's `impl Semigroup T` even when it isn't `export`-marked — else
-- `impl Monoid T` in an importer is falsely rejected for a "missing" super impl.
pickSchemes : List String -> OrdMap Scheme -> List (String, Scheme)
pickSchemes [] _ = []
pickSchemes (n :: ns) table = match omLookup n table
  Some s => (n, s) :: pickSchemes ns table
  None => pickSchemes ns table

-- The ordinary winner and standalone alternative travel together through
-- import selection, aliases, re-exports, and graph memoization.
tagModuleExports : OrdMap Scheme ->
  List (String, Scheme) ->
  List (String, ExportBinding)
tagModuleExports standalones schemes =
  map
    ((name, scheme) => (
      name,
      ExportBinding {
        xbScheme = scheme,
        xbStandalone = omLookup name standalones,
        xbExtern = False,
      },
    ))
    schemes

publicModuleExports : List Decl ->
  ModuleBindings ->
  List (String, ExportBinding)
publicModuleExports prog bindings =
  let standalones =
    omFromPairs
      (flatMap
        (name => match omLookup name bindings.mbStandaloneSchemes
          Some scheme => [(name, scheme)]
          None => [])
        (pubTopFnNames prog))
      omEmpty
  let externs =
    omFromNames (map fst (directExternSigs (externDecls prog))) omEmpty
  map
    ((name, binding) => (
      name,
      ExportBinding { binding | xbExtern = omHasKey name externs },
    ))
    (tagModuleExports
      standalones
      (pickSchemes
        (exportedValueNames prog)
        (omFromPairs (reverseL bindings.mbSchemes) omEmpty)))

-- The first row for a name wins, unless a second import supplies a different
-- declaration of the same name: then the occurrence is the ambiguity the
-- resolver reports as R-AMBIGUOUS-OCCURRENCE (`ambiguousSet`, keyed by
-- declaration through `importValueDecls`, whichever module each import names;
-- a local definition, which it exempts, shadows the seed here anyway).
-- Choosing either supplier would type the use against a definition the program
-- never named, and the cascade would change with the order the imports were
-- written.
importedBindingWinners : ModuleCtx ->
  List (String, (Option String, ExportBinding)) ->
  OrdMap Unit ->
  OrdMap Unit ->
  List (String, ExportBinding)
importedBindingWinners mctx [] _ _ = []
importedBindingWinners mctx ((name, (_, binding)) :: rest) seen ambiguous =
  if omHasKey name seen then
    importedBindingWinners mctx rest seen ambiguous
  else
    let chosen =
      if omHasKey name ambiguous then
        ambiguousImportBinding mctx ()
      else
        binding
    (name, chosen)
      :: importedBindingWinners mctx rest (omInsert name () seen) ambiguous

ambiguousImports : List (String, (Option String, a)) -> OrdMap Unit
ambiguousImports rows = ambiguousImportsGo rows omEmpty omEmpty

ambiguousImportsGo : List (String, (Option String, a)) ->
  OrdMap String ->
  OrdMap Unit ->
  OrdMap Unit
ambiguousImportsGo [] _ acc = acc
ambiguousImportsGo ((_, (None, _)) :: rest) firstMid acc =
  ambiguousImportsGo rest firstMid acc
ambiguousImportsGo ((name, (Some mid, _)) :: rest) firstMid acc =
  match omLookup name firstMid
    None => ambiguousImportsGo rest (omInsert name mid firstMid) acc
    Some seen => ambiguousImportsGo rest firstMid (if seen == mid then
      acc
    else
      omInsert name () acc)

-- An ambiguous name types as a fresh, poisoned variable at every occurrence
-- (`freshSubst` recognises the reserved quantifier), so the resolver's
-- rejection stays the only diagnostic on the drivers that keep typechecking
-- after a resolve error (`check --json`, the LSP).
ambiguousImportBinding : ModuleCtx -> Unit -> ExportBinding
ambiguousImportBinding mctx _ =
  let cell =
    Ref (Unbound ambiguousImportTyvarId mctx.mcCells.currentLevel.value)
  ExportBinding {
    xbScheme = Forall [ambiguousImportTyvarId] [] [] [] pureRow (TVar cell),
    xbStandalone = None,
    xbExtern = False,
  }

moduleImportSeed : ModuleCtx ->
  List (String, Scheme) ->
  List (String, (Option String, ExportBinding)) ->
  ModuleSeed
moduleImportSeed mctx base imported =
  let selected =
    importedBindingWinners mctx imported omEmpty (ambiguousImports imported)
  ModuleSeed {
    msSchemes =
      base ++ map ((name, binding) => (name, binding.xbScheme)) selected,
    msImportedValues =
      omFromPairs
        (flatMap
          ((name, binding) => match binding.xbStandalone
            Some scheme => [(name, scheme)]
            None => [])
          selected)
        omEmpty,
    msImportedNames = omFromNames (map fst selected) omEmpty,
    msImportedExterns =
      omFromNames
        (flatMap
          ((name, binding) => if binding.xbExtern then [name] else [])
          selected)
        omEmpty,
  }

-- `import m as A` binds EVERY value m exports under `A.name` — so it enumerates the
-- dependency's schemes rather than a fixed member list.
--
-- Same golden/mangled split as above: on the emit path the reference is already
-- `<definer>__name`, so the key must stay mangled; on the golden path the reference is
-- the flat `A.name` that desugar produced, so bind it under that.
--
-- #1337/#1427/#1472: the mangle test asks the LOADED MODULE-ID SET, not just the module
-- the importer spelled.  A key reached through `export import` is mangled for its
-- DEFINER, not for the re-exporter `m` that the importer named — so a spelled-mid-only
-- prefix test answered False for it and re-bound `lib_plain__g` as `A.lib_plain__g`,
-- while types/private_mangle (which chases re-exports to the definer) had already
-- rewritten the body's reference to the bare `lib_plain__g`.  The lookup then missed:
-- for a constrained callee that reaches inferDictAt's panic and `build` fails outright
-- (#1427); for an unconstrained one the enclosing prelude call's dict route resolves to
-- nothing, the emitter writes a null dict operand, and the BINARY segfaults (#1472).
--
-- Conservatism (the property this rests on): a BARE key — one no loaded module exports
-- under that exact name with that module's own mangle prefix — is still re-bound under
-- the alias.  That population is exactly the interface METHODS (exportedValueNames admits
-- them; private_mangle's rename map, built from unitDefNames/pubFnNames, never renames
-- them), which is the occurrence-carrier question #1276/#1386 own — deliberately NOT
-- moved here.  The only keys whose binding changes are those a DIFFERENT loaded module
-- actually exports under its mangled name, i.e. precisely the re-exported ones, i.e.
-- precisely the defect.
--
-- 🚨 THE TEST IS AN IDENTITY TEST, NOT A STRING-SHAPE TEST (RUN-XMOD-039 F2), and it
-- must stay one.  A first version asked only "does `k` carry SOME loaded module's mangle
-- prefix?" — a pure spelling question — and that regressed a program base accepted: with
-- a module `lib.plain` loaded, an unrelated module's ordinary exported binding literally
-- named `lib_plain__g` was misread as already-mangled and rejected `Unbound variable:
-- O.lib_plain__g` at exit 1.  That surface is UNBOUNDED AND GROWS WITH THE MODULE GRAPH
-- (every module `a.b` makes `a_b__x` a landmine), and a sprint whose thesis is "identity
-- must not be derived from spelling" cannot decide identity by spelling, even in a guard.
-- ⚠️ So do NOT repair a future false positive here by TIGHTENING THE PREFIX PATTERN — a
-- narrower heuristic has a smaller unbounded surface, not a bounded one.  The conjunct
-- below is what bounds it: `k` must be a name the candidate module ACTUALLY EXPORTS, so
-- a false positive now requires two modules to genuinely export the same symbol rather
-- than one identifier to merely look like a mangled one.
aliasSchemes : List (String, List (String, a)) ->
  String ->
  List (String, a) ->
  List (String, a)
aliasSchemes deps alias depSchemes =
  map (aliasSchemeEntry deps alias) depSchemes

aliasSchemeEntry : List (String, List (String, a)) ->
  String ->
  (String, a) ->
  (String, a)
aliasSchemeEntry deps alias (k, s) =
  if isMangledExportOfAny deps k then (k, s) else (qualifiedLocal alias k, s)

-- does `k` carry the `<sanitized mid>__` prefix the mangler would have given it?
isMangledFor : String -> String -> Bool
isMangledFor mid k =
  let pre = mangledName mid ""
  let lp = stringLength pre
  lp <= stringLength k && stringSlice 0 lp k == pre

-- is `k` a symbol some loaded module ACTUALLY EXPORTS under that module's own mangled
-- name?  Both halves are load-bearing and the ORDER is deliberate: the cheap spelling
-- test gates the assoc lookup, so the scan below runs only for the rare key that already
-- looks mangled.  Short-circuiting and monomorphic on purpose (a dict-passed `any` over
-- a closure is the measured anti-pattern here).
--
-- 🚨 THE HONEST RESIDUAL, RECORDED SO THE NEXT READER DOES NOT HAVE TO RE-DERIVE IT
-- (RUN-XMOD-042).  This is "SHAPE **AND** ACTUALLY-EXPORTED", **not** pure identity, and
-- the distinction matters if you are auditing it against the sprint's own thesis that
-- identity must not be derived from spelling.  `isMangledFor` is still a string test; it
-- has simply stopped being the *whole* decision.  What the `isSome (lookupAssoc k pubV)`
-- conjunct buys is that the surface becomes BOUNDED BY THE PROGRAM'S REAL EXPORT SET: a
-- false positive now needs a GENUINE SYMBOL COLLISION -- module `m` must actually export
-- something named exactly `k`, where `k` also carries `m`'s mangle prefix -- instead of
-- merely a similar-LOOKING name.  Before the conjunct, the surface grew with the module
-- graph (every module `a.b` made `a_b__x` a landmine, which is what regressed `core__foo`
-- and `lib_plain__g`); now it does not grow with the graph at all.
--
-- ⚠️ WHY NOT DROP THE SHAPE HALF AND MAKE IT PURE IDENTITY?  Because that is measurably
-- WRONG here, not merely purer: a re-exported interface METHOD key is also a key of its
-- declaring module's `pubV`, so "is `k` a key of some other loaded module?" alone answers
-- True for methods and would re-bind them -- moving the bare-key population that
-- #1276/#1386 own and that this slice must not touch.  The shape half is precisely what
-- holds methods out (a bare method name carries no `<mid>__` prefix).  So the two halves
-- are not redundant and neither may be removed on tidiness grounds.
--
-- ⚠️ The residual's true root is one level down and is NOT fixed here: private_mangle's
-- `(module, name) -> symbol` encoding is not injective -- a module `lib.plain` and a
-- module literally named `lib_plain` both yield `lib_plain__g`.  That is the common root
-- of both regressions above and is bigger than this function; do not try to repair it by
-- editing this test.
isMangledExportOfAny : List (String, List (String, a)) -> String -> Bool
isMangledExportOfAny [] _ = False
isMangledExportOfAny ((m, pubV) :: rest) k =
  isMangledFor m k && isSome (lookupAssoc k pubV) || isMangledExportOfAny rest k

-- the (key, scheme) pairs a single `import` form brings into scope, resolving each
-- member to its (possibly mangled) key in the dependency's schemes.  `deps` is the
-- loaded dependency environment — module id PLUS that module's public schemes, because
-- the alias arm's test needs the exported NAMES, not just the ids (see aliasSchemes).
-- The non-alias arms ignore it — their resolution is definer-agnostic by construction
-- (a `__<name>` SUFFIX test, and the wildcard form performs no mangle test at all).
--
-- Passing `depEnv` WHOLE is also what supplies the spelled `depId` itself: both callers
-- reach this only through a successful `lookupAssoc depId depEnv`, so the spelled module
-- is in the list by construction and needs no separate term.
--
-- 🚨 `"core"` IS DELIBERATELY **NOT** IN `mids`, AND MUST NOT BE ADDED BACK
-- (RUN-XMOD-039).  It was, briefly.  The argument for it reads well — `reexportSeed`'s
-- own comment records core as the one source NOT in depEnv, and private_mangle *does*
-- mangle core's exports to `core__<name>` — but it was DERIVED, never witnessed: a
-- `export import core.{…}` reached through an alias is green on every verb with or
-- without the term, because core's names are seeded via `baseSeed` and resolve before
-- the alias binding is ever consulted.  Meanwhile the term has a MEASURED cost: it made
-- `mangledName "core" "" == "core__"` a live prefix, so an ordinary user binding named
-- `core__foo` reached through an alias import was misread as already-mangled and left
-- un-rebound — `Unbound variable: O.core__foo`, exit 1, on a program that compiled and
-- printed correctly before.  Zero measured benefit, measured cost.
importFormSchemes : List (String, List (String, a)) ->
  UsePath ->
  List (String, a) ->
  List (String, a)
importFormSchemes deps (UseAlias _ alias) depSchemes =
  aliasSchemes deps alias depSchemes
importFormSchemes _ path depSchemes = importFormRows path depSchemes

-- ── import aliasing of an interface/impl METHOD ─────────────────────────────────
-- A method is GLOBAL-BY-NAME.  Impl coalescing, dispatch routing, the emitter's method
-- tables and the METHOD-side dict-arity tables are every one of them keyed by the
-- method's own name, and there is exactly ONE cell per name — a method is deliberately
-- NOT a per-module binding (eval.mdk's globalCells / coalesceImpls).  So an alias of a
-- method is not a new binding at all: it is a second SPELLING of the same method.
--
-- No alias spelling is resolved here, module or member.  The alias spelling is what
-- makes the occurrence decidable.  Erasing `A.area` makes it the same name as an
-- unrelated imported standalone `area`, and the standalone shadow wins (#1386 Repro B);
-- erasing a member alias `import m.{area as computeArea}` makes `computeArea` and a bare
-- `area` one name, so the import's method captures an `area` that resolve bound to
-- another declaration (#3708).  Inference gets the spelling supplied to it
-- (`aliasQualifiedMethodEntries`, `moduleMarkCtx`, `originMethodName`) and
-- `resolveAliasMethodSpellings` puts the occurrence back under its origin name once
-- inference is done, so every stage after elaboration still sees an ordinary method
-- reference and needs no alias awareness.
--
-- That is also precisely why the METHOD-side predicate carrier and its qualified
-- scoped projection need no alias re-keying the
-- way funConstraintsRef did: by the time they are built, no aliased method name survives.
-- The standalone `=>`-constrained functions are the opposite case — they ARE per-module
-- bindings that keep their local name, which is why they needed the re-keying.
--
-- What this pass does rewrite is a module alias's `DUse`: it keeps its own non-method
-- values and an `import m.{…m's methods…}` is appended beside it, so the origin name is
-- in scope for the occurrence `resolveAliasMethodSpellings` resolves it to.  A member
-- alias's `DUse` is rewritten to its origin name by that same restore, after inference.
-- Beside the rewritten modules it returns each module's admissions, which the drive's
-- mint installs (`GraphCtx.graphAdmittedMethodsRef`, read by `admittedIn`).
renameAliasedMethods : List Decl ->
  List (String, List Decl) ->
  (OrdMap (List (String, String)), List (String, List Decl))
renameAliasedMethods coreDecls modules =
  let coreEntry = ("core", declMethodNames coreDecls)
  let methodsPerMid = coreEntry :: methodsPerMidGo [coreEntry] modules
  let admitted =
    omFromPairs
      (map
        ((mid, prog) => (mid, synthesizedAdmissions methodsPerMid prog))
        modules)
      omEmpty
  (admitted, map (renameAliasedMethodsIn methodsPerMid) modules)

admittedIn : GraphCtx -> String -> List (String, String)
admittedIn gctx mid =
  optionOr [] (omLookup mid gctx.graphAdmittedMethodsRef.value)

-- The method names `deAliasMethodImports` admits WITHOUT a binding the resolver
-- counted: every method of an alias-imported module.  `importSeed` reads this so
-- such a row never makes a bare name look supplied twice.
synthesizedAdmissions : List (String, List String) ->
  List Decl ->
  List (String, String)
synthesizedAdmissions _ [] = []
synthesizedAdmissions mm ((DAttrib _ d) :: rest) =
  synthesizedAdmissions mm (d :: rest)
synthesizedAdmissions mm ((DUse _ path _) :: rest) =
  let mid = useModId path
  let here = match lookupAssoc mid mm
    None => []
    Some methods => match path
      UseAlias _ _ => map (n => (mid, n)) methods
      _ => []
  here ++ synthesizedAdmissions mm rest
synthesizedAdmissions mm (_ :: rest) = synthesizedAdmissions mm rest

-- A module's method set is what it DECLARES *plus what it RE-EXPORTS*, folded in
-- dependency-first (loader) order so a re-export resolves against its source's
-- already-computed set (and a >1-hop chain still resolves).
--
-- The `++ reexportedMethodNames` half closes a run≠build divergence that predates
-- core re-exports and is NOT core-specific: with a module's set limited to its own
-- `declMethodNames`, a module that re-exports a method did not list it, so at an
-- importer's `import reExporter.{method as alias}` neither half of the rewrite fired
-- — the alias was not dropped from the DUse (b) and references were not renamed to the
-- origin (a).  `run` still worked (eval's import frame binds the alias to the origin's
-- cell), but a method is global-by-name with no per-module symbol, so EMIT had nothing
-- to bind `alias` to and died with `unbound variable '<alias>'`.  Observed on a pure
-- user-module chain (b defines `area`; c re-exports it; main imports `area as surface`
-- → run prints 16, build fails), and on `import list.{filter as f}` once
-- `export import core.{filter}` began re-exporting at all.
methodsPerMidGo : List (String, List String) ->
  List (String, List Decl) ->
  List (String, List String)
methodsPerMidGo _ [] = []
methodsPerMidGo acc ((mid, decls) :: rest) =
  let entry =
    (mid, dedup (declMethodNames decls ++ reexportedMethodNames acc decls))
  entry :: methodsPerMidGo (entry :: acc) rest

-- method names a module re-exports via `export import src.{…}` (`DUse True`), taken
-- from `acc` — the dependency's already-folded method set.
reexportedMethodNames : List (String, List String) -> List Decl -> List String
reexportedMethodNames acc ds =
  flatMap (reexportedMethodsOf acc) (pubUsePaths ds)

reexportedMethodsOf : List (String, List String) -> UsePath -> List String
reexportedMethodsOf acc path = match lookupAssoc (useModId path) acc
  None => []
  Some srcMethods => match importedBindings path
    -- `export import src.*` re-exports every one of src's methods
    None => srcMethods
    Some bs => filterList (n => contains n srcMethods) (map fst bs)

-- Only a MODULE alias is rewritten before inference (`deAliasMethodImports`).  A
-- member alias reaches inference as written, so `import m.{mth as loc}` binds `loc`
-- and not `mth`; `resolveAliasMethodSpellings` restores the origin name afterwards.
-- The pass is a no-op on a module whose imports name no method.
renameAliasedMethodsIn : List (String, List String) ->
  (String, List Decl) ->
  (String, List Decl)
renameAliasedMethodsIn methodsPerMid (mid, prog) =
  (mid, flatMap (deAliasMethodImports methodsPerMid) prog)

-- `import m as A` is kept (its non-method values are still `A.f`) and gains a sibling
-- `import m.{…m's methods…}`, the origin name `resolveAliasMethodSpellings` resolves
-- `A.area` to once inference is done.  The rewrite is recorded in
-- `graphAdmittedMethodsRef` (`synthesizedAdmissions`), because the resolver never saw
-- it.  The added import keeps the alias import's path and location, which is how the
-- method scope ladder tells it from a written one (`writtenImportsOf`).
deAliasMethodImports : List (String, List String) -> Decl -> List Decl
deAliasMethodImports mm (DAttrib attrs d) =
  map (DAttrib attrs) (deAliasMethodImports mm d)
deAliasMethodImports mm (d@(DUse pub path loc)) =
  match lookupAssoc (useModId path) mm
    None => [d]
    Some methods => match path
      UseAlias quals _ => match methodMembersOf methods loc
        [] => [d]
        mems => [d, DUse pub (UseGroup quals mems) loc]
      _ => [d]
deAliasMethodImports _ d = [d]

methodMembersOf : List String -> Loc -> List UseMember
methodMembersOf methods loc = map (n => UseMember n False loc None) methods

-- [qualified] holds the `A.mth` spellings: nothing but the method can be spelled that
-- way, so every occurrence moves.  [members] holds the member-alias locals no own
-- top-level value takes (`memberAliasCands`), which a local binder can still spell;
-- only a MARKED occurrence is the import's, since the marker leaves a locally-bound
-- name unmarked (`rewriteArgScoped`).
renameMethodVar : List (String, String) -> List (String, String) -> Expr -> Expr
renameMethodVar qualified _ (e@(EVar x)) = match lookupAssoc x qualified
  Some origin => EVar origin
  None => e
renameMethodVar qualified _ (e@(EVarId x _)) = match lookupAssoc x qualified
  Some origin => EVar origin
  None => e
-- A marked occurrence: `resolveAliasMethodSpellings` runs after inference, on a tree
-- the schedule has already marked.  Only the NAME moves — the route cell carries the
-- dispatch decision inference reached under the alias spelling.
renameMethodVar qualified members (e@(EMethodAt x sym ev)) =
  match lookupAssoc x qualified
    Some origin => EMethodAt origin sym ev
    None => match lookupAssoc x members
      Some origin => EMethodAt origin sym ev
      None => e
renameMethodVar _ _ e = e

-- ── #1386: the alias-qualified spelling, resolved AFTER inference ───────────────
-- `A.mth`, and a member alias `loc` from `import m.{mth as loc}`, reach inference
-- spelled as written, because that spelling is what makes the occurrence decidable:
-- rewriting either to a bare `mth` up front merges it with whatever else a bare `mth`
-- names in this module (`renameAliasedMethods`' header, #1386 Repro B, #3708).  Every
-- reader inference needs is supplied under that spelling — the obligation table, the
-- mark sets, the dispatch index — so the distinction survives exactly as long as it
-- decides something.
--
-- It must not survive further.  Everything DOWNSTREAM of elaboration keys a method by
-- its origin name and only its origin name: eval's coalesced method cells and its
-- per-(method, tag) `requires` counts (`methodReqCountRef`, whose miss would turn a
-- dispatch into the inherited-default path), the Core-IR interpreter's twin, and the
-- emitter's method tables.  Resolving the spelling here leaves all of them the tree
-- they get today, so the fix is a VERDICT change and nothing else.
resolveAliasMethodSpellings : GraphCtx ->
  (String, List Decl) ->
  (String, List Decl)
resolveAliasMethodSpellings gctx (mid, prog) =
  let qualified = map aliasRowSpelling (useKeyCands (moduleAliasKeys gctx) prog)
  let members = map aliasRowSpelling (memberAliasCands gctx prog)
  match (qualified, members)
    ([], []) => (mid, prog)
    _ => (
      mid,
      mapProg
        (renameMethodVar qualified members)
        (map (deAliasMethodMembers members) prog),
    )

-- `import m.{mth as loc}` → `import m.{mth}`, once every `loc` occurrence carries `mth`:
-- downstream of elaboration a method is bound by its origin name only.  Only a
-- `DUse` names import members, so every other decl passes through unchanged.
deAliasMethodMembers : List (String, String) -> Decl -> Decl
deAliasMethodMembers rows (DAttrib attrs d) =
  DAttrib attrs (deAliasMethodMembers rows d)
deAliasMethodMembers rows (DUse pub (UseGroup quals ms) loc) =
  DUse pub (UseGroup quals (map (deAliasMethodMember rows) ms)) loc
deAliasMethodMembers _ d = d

deAliasMethodMember : List (String, String) -> UseMember -> UseMember
deAliasMethodMember rows (m@(UseMember n allCtors loc (Some local)))
  | containsPair (local, n) rows = UseMember n allCtors loc None
  | otherwise = m
deAliasMethodMember _ m = m

-- every interface/impl method name a decl list declares (interface methods with or
-- without a default, plus impl method names).
declMethodNames : List Decl -> List String
declMethodNames decls = dedup (flatMap declMethodNamesOf decls)

declMethodNamesOf : Decl -> List String
declMethodNamesOf (DAttrib _ d) = declMethodNamesOf d
declMethodNamesOf (DInterface { methods, ... }) = ifaceMethodNames methods
declMethodNamesOf (DImpl { methods, ... }) = map implMethodName methods
declMethodNamesOf _ = []

-- `core` is never in `depEnv` (it is the implicit prelude — `reexportSeed`'s comment
-- carries the full reason), so it is passed separately as `coreV`, and it contributes
-- ONE thing: the keys an ALIAS introduces.  A plain `import core.{f}` still seeds
-- nothing, because `f` is already in `baseSeed` under that very spelling and seeding it
-- twice only adds a duplicate assoc entry — but `import core as C` and
-- `import core.{f as g}` ask for `C.f` / `g`, which `baseSeed` does not hold under any
-- spelling.  `resolve.mdk`'s `coreAliasNames` binds exactly the same two forms, and the
-- two must agree: a key bound in scope with no scheme here is a `T-UNBOUND` at the use
-- site, which is what #95 measured for six years.
-- Each row a use-path BINDS carries the declaration it denotes
-- (`importSupplierKey`), the same identity the resolver's value ambiguity check
-- keys on (`importValueDecls`), so `moduleImportSeed` can refuse to pick a winner
-- by import order for a name the resolver has already rejected, and still
-- accept one declaration reached through two imports. A row the form admits
-- without binding its name (a bare method row admitted for dispatch, a mangled
-- twin) carries no supplier, and core is exempt there as it is in the resolver.
-- The key is looked up by local name, so one member list binding a local twice
-- (`import m.{a as b, b}`) gives both rows one key and the first row wins here;
-- the resolver rejects that occurrence by declaration all the same.
importSeed : GraphCtx ->
  List (String, a) ->
  List (String, String) ->
  List Decl ->
  List (String, List (String, a)) ->
  List (String, (Option String, a))
importSeed gctx _ _ [] _ = []
importSeed gctx coreV admitted ((DAttrib _ d) :: rest) depEnv =
  importSeed gctx coreV admitted (d :: rest) depEnv
importSeed gctx coreV admitted ((DUse _ path _) :: rest) depEnv =
  let depId = useModId path
  if depId == "core" then
    map (suppliedBy None) (coreAliasSchemes path coreV)
      ++ importSeed gctx coreV admitted rest depEnv
  else match lookupAssoc depId depEnv
    None => importSeed gctx coreV admitted rest depEnv
    Some depSchemes =>
      let bound = boundNames path
      let decls =
        omFromPairs
          (reverseL (importFormRows path (graphPubDefiners gctx depId)))
          omEmpty
      let methods =
        identKeysByName
          omEmpty
          (importFormRows
            path
            (match omLookup depId (methodExportsIndex gctx ())
              Some rows => rows
              None => []))
      map
          (row =>
            suppliedBy
              (if bindsName bound (fst row)
                && not (containsPair (depId, fst row) admitted) then
                Some (importSupplierKey depId decls methods (fst row))
              else
                None)
              row)
          (importFormSchemes depEnv path depSchemes)
        ++ importSeed gctx coreV admitted rest depEnv
importSeed gctx coreV admitted (_ :: rest) depEnv =
  importSeed gctx coreV admitted rest depEnv

-- The identity one import's binding of `name` is compared by: the declaration
-- it denotes.  A standalone value is `(defining module, name there)` from
-- `graphPubDefiners`, first row winning as it does there; an interface method
-- is the set of method declarations the import carries under that name
-- (`meExports`).  A driver without an import graph knows neither, so the
-- binding falls back to the importing module's id.  The three key shapes are
-- two, a multiple of four, and one netstring long, so no two can coincide.
importSupplierKey : String ->
  OrdMap (String, String) ->
  OrdMap (List String) ->
  String ->
  String
importSupplierKey depId decls methods name = match omLookup name decls
  Some (defMid, origin) => "\{lenKey defMid}\{lenKey origin}"
  None => match omLookup name methods
    Some keys => joinWith "" (sortUniqS keys)
    None => lenKey depId

identKeysByName : OrdMap (List String) ->
  List (String, Ident) ->
  OrdMap (List String)
identKeysByName acc [] = acc
identKeysByName acc ((n, ident) :: rest) =
  let seen = match omLookup n acc
    Some keys => keys
    None => []
  identKeysByName (omInsert n (identKey ident :: seen) acc) rest

suppliedBy : Option String -> (String, a) -> (String, (Option String, a))
suppliedBy mid (name, row) = (name, (mid, row))

containsPair : (String, String) -> List (String, String) -> Bool
containsPair _ [] = False
containsPair (a, b) ((x, y) :: rest) =
  a == x && b == y || containsPair (a, b) rest

bindsName : Option (OrdMap Unit) -> String -> Bool
bindsName None _ = True
bindsName (Some names) name = omHasKey name names

-- the schemes a `core` use-path binds under a spelling the prelude did not supply.
coreAliasSchemes : UsePath -> List (String, a) -> List (String, a)
coreAliasSchemes (UseAlias _ a) coreV = map (coreQualScheme a) coreV
coreAliasSchemes (UseGroup _ ms) coreV = flatMap (coreRenameScheme coreV) ms
coreAliasSchemes _ _ = []

coreQualScheme : String -> (String, a) -> (String, a)
coreQualScheme a (k, s) = (qualifiedLocal a k, s)

coreRenameScheme : List (String, a) -> UseMember -> List (String, a)
coreRenameScheme coreV m = match useMemberAlias m
  None => []
  Some local => match lookupAssoc (useMemberOrigin m) coreV
    None => []
    Some s => [(local, s)]

-- the (key, scheme) pairs a module RE-EXPORTS via `export import` (`DUse True`).
-- Mirrors resolve's re-export set (resolve.pubUsePaths filters the same `DUse True`)
-- into the typecheck seed: walk the export-flagged DUse decls and, for each, pick the
-- re-exported member names out of the SOURCE dependency's public schemes already in
-- depEnv — the exact member resolution importSeed uses (importFormSchemes /
-- resolveMemberRows), so it works on both golden and mangled emit paths.  Schemes
-- come from depEnv by IDENTITY (the definer's original schemes, never re-generalized),
-- which preserves the original-definer constraint ids (D2 diamond-safety).  ONLY
-- `DUse True` is threaded, so a plain `import` never leaks the importer's names
-- downstream.  Transitivity is automatic: pubV accumulates these and is carried
-- forward as depEnv, so a second `export import` hop re-resolves against the enriched
-- pubV.  Methods need no special case — the source module's pubV already holds the
-- method scheme (exportedValueNames includes DInterface method names).
--
-- `core` is the one source that is NOT in depEnv: it is the implicit prelude, so its
-- schemes go into `baseSeed`, not into the per-module dep chain.  It is therefore
-- passed separately as `coreV` — without it, `lookupAssoc "core" depEnv` missed and
-- `export import core.{filter}` re-exported nothing (in silence, and forever).
-- `coreV` is consulted ONLY here, on `DUse True`: `importSeed` keeps taking the plain
-- depEnv, so a plain `import core.{…}` still seeds nothing (its names are already in
-- baseSeed — seeding them twice would only add duplicate assoc entries).
reexportSeed : List (String, a) ->
  List Decl ->
  List (String, List (String, a)) ->
  List (String, a)
reexportSeed coreV decls depEnv =
  flatMap (reexportSeedOf coreV depEnv) (pubUsePaths decls)

reexportSeedOf : List (String, a) ->
  List (String, List (String, a)) ->
  UsePath ->
  List (String, a)
reexportSeedOf coreV depEnv path =
  let depId = useModId path
  let src = if depId == "core" then Some coreV else lookupAssoc depId depEnv
  match src
    None => []
    Some depSchemes => importFormSchemes depEnv path depSchemes

foldModules : FoldPlan e acc ->
  Option (ModuleServe e) ->
  acc ->
  List (String, List (String, ExportBinding)) ->
  List Decl ->
  List Decl ->
  ModuleCtx ->
  List (String, List Decl) ->
  (acc, Option (ModuleServe e), ModuleCtx)
foldModules plan serve base depEnv accData accAll prev modules =
  let (done, served, last) =
    workModules plan serve depEnv accData accAll [] prev modules
  (collectModules plan.fpCollect base done, served, last)

-- `foldModules`' loop: runs the worker over [modules] head-first, threading the
-- accumulators, the record and the serve policy, and returns each module's payload,
-- newest first.  The recursive call is a tail call: a frame waiting on the rest would
-- keep its module's record reachable until the graph end.
workModules : FoldPlan e acc ->
  Option (ModuleServe e) ->
  List (String, List (String, ExportBinding)) ->
  List Decl ->
  List Decl ->
  List (String, e) ->
  ModuleCtx ->
  List (String, List Decl) ->
  (List (String, e), Option (ModuleServe e), ModuleCtx)
workModules _ serve _ _ _ done prev [] = (done, serve, prev)
workModules plan serve depEnv accData accAll done prev [(mid, prog)] =
  let seed = moduleSeedFor prev plan.fpBaseSeed plan.fpCoreV mid prog depEnv
  let (_, extra, next) = plan.fpWorker prev mid seed accData accAll prog
  ((mid, extra) :: done, serve, next)
workModules plan serve depEnv accData accAll done prev ((mid, prog) :: rest) =
  let step = map (policy => policy.msStep mid prog prev) serve
  let (own, done2, serve2, next) = match step
    Some (ServeHit own extra policy) =>
      (own, (mid, extra) :: done, Some policy, prev)
    _ =>
      let seed = moduleSeedFor prev plan.fpBaseSeed plan.fpCoreV mid prog depEnv
      let (schemes, extra, next) =
        plan.fpWorker prev mid seed accData accAll prog
      let own = publicModuleExports prog schemes
      match step
        Some (ServeCheck after) =>
          let (done3, policy) = after next own ((mid, extra) :: done)
          (own, done3, Some policy, next)
        _ => (own, (mid, extra) :: done, serve, next)
  workModules
    plan
    serve2
    ((mid, own ++ reexportSeed plan.fpCoreV prog depEnv) :: depEnv)
    (match plan.fpAccumulate
      AccumulateBoth => accData ++ publicDataDecls prog
      AccumulateNone => accData)
    (match plan.fpAccumulate
      AccumulateBoth => accAll ++ prog
      AccumulateNone => accAll)
    done2
    next
    rest

-- The import-scoped seed [mid] is checked from: [baseSeed] and what [prog]'s imports
-- select from [depEnv].
moduleSeedFor : ModuleCtx ->
  List (String, Scheme) ->
  List (String, ExportBinding) ->
  String ->
  List Decl ->
  List (String, List (String, ExportBinding)) ->
  ModuleSeed
moduleSeedFor prev baseSeed coreV mid prog depEnv =
  moduleImportSeed
    prev
    baseSeed
    (importSeed prev.mcGraph coreV (admittedIn prev.mcGraph mid) prog depEnv)

-- The right fold of `collect` over the payloads [done] (newest first): the last module
-- first, the only one `collect` sees as last, onto [base].
collectModules : (ModulePlace -> String -> e -> acc -> acc) ->
  acc ->
  List (String, e) ->
  acc
collectModules _ base [] = base
collectModules collect base ((mid, extra) :: older) =
  fold
    (acc (m, x) => collect NotLastModule m x acc)
    (collect LastModule mid extra base)
    older

-- The core pass, through the prelude interface (`types/prelude_interface.mdk`).
-- Under the caller's prelude key a hit is the cached interface whose section lists
-- this drive's IO join.  A miss checks core, drains it, freezes the result, caches
-- it when keyed, and continues from that frozen value as a hit does, so the record
-- past core is one shape however the drive came by it: core's evidence, binder rows,
-- scope frames and goals stay in the run core was checked in, and its schemes reach
-- inference as fresh cells.
-- The interface's extern catalog is the one [runtimeDecls] alone build, not the
-- process's union, which holds whatever runtimes earlier drives declared.
-- Returns the bindings inference reads, the prelude's published rows and the module
-- record to continue from, whose `mcGraph` is the graph record.
checkCoreMemoized : ModuleCtx ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  List (String, Scheme) ->
  (ModuleBindings, List (String, PubScheme), ModuleCtx)
checkCoreMemoized prev key runtimeDecls coreDecls runtimeSeed =
  let gctx = prev.mcGraph
  let join = gctx.config.value.tcIoJoin
  let cached = match key
    Some k => preludeCacheHit k join
    None => None
  match cached
    Some pi => continueFromInterface gctx gctx.graphRun pi
    None =>
      -- #2705: core is marked inside the pass, with the unsplit set
      -- (`moduleMarkCtx`'s core arm), in the run the continuation below leaves.
      let (coreSchemes, _, coreCtx) =
        checkModuleFull prev runtimeSeed [] coreDecls
      -- #2705: drain core's stamping context before the freeze, so core is solved
      -- once per process rather than once per analyze.  This treats core as closed
      -- at its own end.  The prelude has no diagnostics list for a hole to land in.
      match checkGraphFinish coreCtx
        [] => ()
        f :: _ => panic "evidence hole in the prelude: \{tcMsg f.dfDiag}"
      -- #673/#837: the published rows carry core's own obligations, keyed by bare
      -- name; the thaw derives `coreSchemeObligationsRef` from them.
      let pi =
        freezeInterface
          gctx.crossRun
          gctx.graphRun
          (externSigsToMap runtimeDecls omEmpty)
          (publishCore (coreOwnContexts coreCtx) coreSchemes.mbSchemes)
          (omMapValues (_ => ()) coreSchemes.mbStandaloneSchemes)
          coreCtx.mcCells.invocationViewRef.value
      match key
        Some k => seedPreludeInterface k [([join], pi)]
        None => ()
      continueFromInterface gctx (graphLineageRun (internersOf gctx).lineage) pi

-- The record a drive continues from past the core pass: [gctx] with [pi] thawed
-- into it.  [run] is a graph run core was not checked in; it takes the interface's
-- id counters and existential cells and nothing else of core's.  Core's module
-- record is not carried: the diagnostics worker seeds each module from its own
-- decls (`seedCheckRun`), and `cmCheckWorker` seeds its first module from this
-- blank record, an empty oracle (the one core was checked from) and no warning.
-- The interface's externs join the drive's catalog, whose own rows lose to them on
-- a collision, so a hit leaves the catalog a miss would and never shrinks it.
continueFromInterface : GraphCtx ->
  GraphRun ->
  PreludeInterface ->
  (ModuleBindings, List (String, PubScheme), ModuleCtx)
continueFromInterface gctx run pi =
  let (bindings, corePub, cross, seed) = thawInterface gctx pi
  run.tyvarCounter := seed.grsTyvarNext
  run.effvarCounter := seed.grsEffvarNext
  run.ctorExistentialsRef := seed.grsCtorExistentials
  run.anyExistentialsRef := seed.grsAnyExistentials
  let restored = GraphCtx { gctx |
    crossRun = cross,
    graphRun = run,
    builtinExternNamesRef =
      Ref (IdMap.union pi.piExternNames gctx.builtinExternNamesRef.value),
  }
  let mctx = initialModuleCtx restored
  mctx.mcCells.invocationViewRef := readInvocationView pi.piInvocationView
  (bindings, corePub, mctx)

preludePreambleMemoRef : Ref (Option (((Int, Int), String), PreludePreamble))
preludePreambleMemoRef = Ref None

preludePreambleOf : GraphCtx -> List Decl -> DeclEnvModule -> PreludePreamble
preludePreambleOf gctx coreDecls coreRow = PreludePreamble {
  ppEnvAcc = declEnvAccOf gctx [coreRow] emptyDeclEnvAcc,
  ppMangledFunDefs = unitCarriesMangledFunDefs "core" (funDefs coreDecls),
  ppMarkFacts = preludeMarkFactsOf coreDecls,
}

preludePreambleFor : GraphCtx ->
  Option (Int, Int) ->
  List Decl ->
  DeclEnvModule ->
  PreludePreamble
preludePreambleFor gctx None coreDecls coreRow =
  preludePreambleOf gctx coreDecls coreRow
preludePreambleFor gctx (Some k) coreDecls coreRow =
  match !preludePreambleMemoRef
    Some entry =>
      if fst entry == (k, gctx.config.value.tcIoJoinProfile) then
        snd entry
      else
        preludePreambleStore gctx k coreDecls coreRow
    None => preludePreambleStore gctx k coreDecls coreRow

-- One entry only (the prelude does not change under a process); a different
-- prelude simply misses and replaces it.
preludePreambleStore : GraphCtx ->
  (Int, Int) ->
  List Decl ->
  DeclEnvModule ->
  PreludePreamble
preludePreambleStore gctx k coreDecls coreRow =
  let p = preludePreambleOf gctx coreDecls coreRow
  preludePreambleMemoRef := Some ((k, gctx.config.value.tcIoJoinProfile), p)
  p

-- The drive's configuration: the IO join of the selected profile's grants (after the
-- effect domains it reads), the profile's name, and the stdlib ownership.
export
tcConfigOf : List (String, Param) -> DriveInputs -> TcConfig
tcConfigOf domains inputs = TcConfig {
  tcIoJoin = ioJoinAtoms domains inputs.diIoJoinGrants,
  tcIoJoinProfile = inputs.diProfileName,
  tcStdlibOwned = inputs.diStdlibOwned,
  tcFlatEntryIsStdlib = inputs.diFlatEntryIsStdlib,
  tcKey =
    "\{inputs.diProfileName}\n\{inputs.diFlatEntryIsStdlib}\n\{joinWith "," (omKeys inputs.diStdlibOwned)}",
}

-- [admitted]: the per-module method admissions `renameAliasedMethods` computed for
-- the drive's graph, or `omEmpty` on a drive that does not rename.  The last
-- `gpCoreCtx` is the record the core pass leaves current, which the drive's first
-- module starts from.
graphPreamble : DriveInputs ->
  OrdMap (List (String, String)) ->
  GraphOut ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  GraphPreamble
graphPreamble inputs admitted sel preludeKey runtimeDecls coreDecls modules =
  -- S-emit-interleave-leak (#2049), TREES only: THE EMIT DRIVER OWNS ITS OWN
  -- (empty) ctor oracle.  A module checked without a `CheckRunSeed` carries the
  -- previous module record's `matchOracle`, and the tree arm's core pass is one
  -- (the seed is `seedCheckRun`'s, reached from `checkModuleFullDiags`
  -- only).  So every `oGetCtors`
  -- reader the tree arm reaches — `ctorSiblingWithholdingName`, `matchCol0Type` —
  -- would read whatever the LAST CHECK RUN IN THIS PROCESS left behind.
  --
  -- That residue used to be unreachable by accident rather than absent: `typeCtors`
  -- is keyed by DECLARATION IDENTITY (`tabKeyOf NsType <dataOrigin> <tyname>`), the
  -- flat entries build it from UNSTAMPED decls (`TkBare` rows), and this arm's
  -- readers mint `TkIdent` for a module-stamped head — so every lookup MISSED and
  -- every reader fell through its fail-open `None` arm.  A `Module`-arm re-check
  -- interleaved between two elaborations (the emit path's async-wrap re-check)
  -- writes rows under the entry module's OWN identity, i.e. under exactly the key
  -- these readers mint — so the lookups start HITTING, against rows built from the
  -- UN-MANGLED tree while the drive walks the MANGLED one.  MEASURED:
  -- `ctorSiblingWithholdingName` then reads the un-mangled ctor `A` as a sibling of
  -- the mangled survivor and false-rejects `a.k` with `Field 'k' is not declared by
  -- every constructor of 'A'`; `Display` cannot ground, the `println` route stays
  -- RNone, and the emitter writes a NULL dict word (`i64 0`) — SILENTLY on
  -- `runEmitWith`'s own path (`compiler/entries/entry_support.mdk`), which never
  -- reads `hadTypeErrors` after the call.  Clean exit 0, SIGSEGV at runtime.
  --
  -- The module record starts from `initialModuleCtx` of the minted graph record,
  -- whose oracle is empty, so no reader can see a previous run's residue, no matter
  -- which arm (or none) ran before.  It is what the core pass below runs against; each
  -- user module then overwrites it from its own decls (`checkModuleFullDiags` →
  -- `seedCheckRun`).
  --
  -- A process holding the prelude's elaborated trees (`types/prelude_elab.mdk`)
  -- starts every lineage past the evidence ordinals those trees carry, so no drive
  -- of it mints one again, whichever arm it takes.  Local binder names need no such
  -- raise: they carry their module's id.
  match heldPreludeEvCounter ()
    Some k =>
      let lineage = interners.value.lineage
      lineage.lnEvCounter := max lineage.lnEvCounter.value k
    None => ()
  let gctx = mintGraphCtx inputs admitted
  let initial = initialModuleCtx gctx
  -- #80/#201: populate effect domains ONCE over the WHOLE import graph (builtins +
  -- every `effect …` decl in core or any module), BEFORE the per-module foldModules
  -- loop, so a module using an effect declared in ANOTHER module sees its domain.
  -- `freshModuleCtx` no longer re-seeds, so this survives every per-module reset below.
  -- Must precede the core checkModuleFull (it runs checkEffectParams, reading these).
  --
  -- It must also precede the declaration ENVELOPE below, and that ordering is the
  -- newer half of the constraint: the envelope's atom-guarantee seed
  -- (`declEnvRowAtomsEntries` → `dtopFor`) READS this table, so an envelope built
  -- first degrades every parameterized label to its ⊤ and over-rejects an honest
  -- relay into an abstractly-exported wrapper.
  --
  -- #1112 A-3.1: the units here are what `deAllDecls` flattens (`declEnvDeclsOf`),
  -- in the same order; `populateEffectDomainsGraph` walks them without building
  -- that concatenation a second time.
  populateEffectDomainsGraph gctx coreDecls modules
  -- What `IO` joins, from the grants of the profile the verb selected, after the
  -- domains the atoms take their tops from.  `run` checks against `runProfile` of
  -- that profile, whose host-label grants are the selected profile's own.
  gctx.config := tcConfigOf gctx.effectDomains.value inputs
  -- the prelude's own contribution to every derivation below, from the memo when
  -- the caller supplied a prelude key -- see `PreludePreamble`.  The row is built
  -- HERE, not inside the memo, because it carries THIS analyze's decls.
  let coreRow = declEnvModule gctx 0 "core" coreDecls
  let modRows = declEnvModulesFrom gctx 1 modules
  let prelude = preludePreambleFor gctx preludeKey coreDecls coreRow
  -- L3 (xmod-identity #1351 spine): the graph-level mangled-funDefs fact, under the
  -- two-part safety property stated on `meExports` (F3: unconditional
  -- whole-value overwrite at the Module-mode driver entry + no reset point after it
  -- is what keeps compile N's flag from leaking into compile N+1).  The two terms
  -- are the `("core", coreDecls) :: modules` unit list split on its head, which
  -- `graphCarriesMangledFunDefs` folds with `||`.
  gctx.mangledFunDefsPresentRef :=
    prelude.ppMangledFunDefs || graphCarriesMangledFunDefs modules
  -- #1112 A-3.1: the whole-graph declaration envelope, under the same two-part
  -- property as the line above (nothing resets it within the drive, and the
  -- Module-mode driver entry writes it unconditionally).  See `buildDeclEnvs`.  It
  -- carries the method namespace (`deMethods`) and the constructor export index
  -- (`deData.deCtorExports`), so it is written before any module — the core pass
  -- included — reads a method's scope or a constructor's import witness.
  let declEnvs = buildDeclEnvs gctx prelude.ppEnvAcc coreRow modRows
  gctx.declEnvsRef := declEnvs
  -- #1280: `coreDecls` arrives here ALREADY STAMPED (the caller's
  -- `stampGraphTyOrigins` line), but the scope is derived from its type
  -- NAMES, not its origins, so it is the same map either way.
  -- An extern's signature may index a prelude head by an authority
  -- (`netSend : Socket h -> … <Net h> …`), and a name in an index slot is an
  -- authority binder only by the head's declared kind.
  let runtimeSeed = withDeclParamKinds initial coreDecls (u =>
    externSchemes initial (runtimeExternTyOriginScope coreDecls) runtimeDecls)
  seedAbstractRecordTypes gctx coreDecls modules
  -- #2705: BOTH arms MARK (solving is not optional), with the same sets, and each
  -- module is marked on the schedule inside `checkBodyImpl` — after any memo
  -- restore of `GraphCtx.graphRun`, never before, which is what keeps a minted cell indexing
  -- the table it was minted into.  `markSetsOf` publishes the sets to
  -- `checkBodyImpl` and writes `mangledShadowMapRef`/`argDispatchIdxByIdRef`.
  -- The split of the mark set (`msMarkRpNames` vs `msMarkSharedNames`) and every
  -- input that can become an `EMethodAt` are enumerated in `moduleMarkCtx`; the
  -- return-position/non-nameable axis it scopes is expressed by
  -- `test/shadow_fixtures/d24_definer_return_pos_not_nameable/`.
  let ms =
    markSetsOf gctx prelude.ppMarkFacts coreDecls modules declEnvs.deAllDecls
  -- Both arms PROMOTE: an unsignatured user fn whose body dispatches a method gets
  -- an inferred constraint and joins the dict-name set, so its occurrences route
  -- through its own dictionary parameter on every verb.  The completeness judgment
  -- reads those routes, and a check driver that left such a body unpromoted would
  -- see `RNone` where the tree arm sees `RDict`.  The eligible set is written and
  -- the harvest cleared at the entry of every drive, which `maybeInferConstraint`
  -- reads.
  setDictEligible gctx (moduleUserFnNames modules)
  gctx.promotionHarvestRef := []
  -- The core pass.  The diags arm continues from the prelude interface, cached
  -- under the caller's prelude key (see `checkCoreMemoized`, which drains core's
  -- stamping context before it freezes).  The tree arm needs core's dict-passed
  -- decls as well, which an interface does not hold: it continues from the
  -- interface only when the process also holds the prelude's shipped trees for
  -- the drive's key (`treeArmHit`), and otherwise runs the pass outright and
  -- drains only at graph end.
  -- The prelude's published rows come back here only when this pass closed core
  -- (the diags arm, and the tree arm's hit); otherwise the tree arm publishes them
  -- after its graph-end drain.  Both arms return core's own contexts as a value.
  -- The tree arm's snapshot is never written to
  -- `CrossRun.coreSchemeObligationsRef`, which inference reads.
  let (coreSchemes, corePub, coreContexts, coreTree, coreCtx) = match sel
    GOutDiags =>
      let (bindings, published, coreCtx) =
        checkCoreMemoized initial preludeKey runtimeDecls coreDecls runtimeSeed
      -- The graph record the drive continues from, with the interface thawed into
      -- it.  Nothing holds `initial` past this point.
      noteInterners coreCtx.mcGraph
      (
        bindings,
        Some published,
        coreCtx.mcGraph.crossRun.coreSchemeObligationsRef.value,
        [],
        coreCtx,
      )
    GOutTrees => match treeArmHit inputs coreDecls gctx
      Some (pe, pi) =>
        let (bindings, published, coreCtx) =
          continueFromInterface gctx gctx.graphRun pi
        noteInterners coreCtx.mcGraph
        (
          bindings,
          Some published,
          coreCtx.mcGraph.crossRun.coreSchemeObligationsRef.value,
          pe.peDecls,
          coreCtx,
        )
      None =>
        let (bindings, tree, coreCtx) =
          elabModuleStamp initial "" runtimeSeed [] coreDecls coreDecls
        (bindings, None, coreOwnContexts coreCtx, tree, coreCtx)
  GraphPreamble {
    gpRuntimeSeed = runtimeSeed,
    gpCoreSchemes = coreSchemes,
    gpCorePub = corePub,
    gpCoreContexts = coreContexts,
    gpCoreTree = coreTree,
    gpMarkSets = ms,
    gpCoreCtx = coreCtx,
  }

-- The prelude's shipped trees for a tree-arm drive (`types/prelude_elab.mdk`), moved
-- onto the binders of [coreDecls], the drive's own desugar of core: held for the
-- drive's prelude key.
treeArmElab : DriveInputs -> List Decl -> Option PreludeElab
treeArmElab inputs coreDecls = match inputs.diPreludeKey
  Some k => preludeElabFor k coreDecls
  None => None

-- Those trees with the interface of the same key cached for the drive's IO join:
-- a drive takes both or neither.
treeArmHit : DriveInputs ->
  List Decl ->
  GraphCtx ->
  Option (PreludeElab, PreludeInterface)
treeArmHit inputs coreDecls gctx = do
  k <- inputs.diPreludeKey
  pi <- preludeCacheHit k gctx.config.value.tcIoJoin
  pe <- treeArmElab inputs coreDecls
  Some (pe, pi)

-- `graphPreamble`'s `(runtimeSeed, coreSchemes, record)` projection, for the
-- schemes-only driver (`checkModulesK`), which neither marks trees nor reads the mark
-- sets back.
checkModulesPreambleK : DriveInputs ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  (List (String, Scheme), ModuleBindings, ModuleCtx)
checkModulesPreambleK inputs preludeKey runtimeDecls coreDecls modules =
  let pre =
    graphPreamble
      inputs
      omEmpty
      GOutDiags
      preludeKey
      runtimeDecls
      coreDecls
      modules
  (pre.gpRuntimeSeed, pre.gpCoreSchemes, pre.gpCoreCtx)

-- worker: plain per-module typecheck (no diagnostics harvest, no accAll).  Surfaces
-- `schemes` twice — once as the pubV source foldModules needs, once as the payload
-- checkModules collects.
--
-- #1508 (U2a): it calls `checkModuleFullImpl` with the module id `foldModules` hands
-- it, so every user module reaches `checkBodyImpl`'s Module arm under its own id
-- (`declEnvsOrdOf`), as `graphModuleWorker` does through `checkModuleFullDiags`; only
-- the prelude is `""`, and a user module keyed `""` loses the qualified cross-module
-- tables (below).  It passes `accData` and `[]` implDecls (the perf-gate
-- path reads neither accumulator).
--
-- 🚨 THIS IS NOT ATTRIBUTION-ONLY, AND THE FIRST DRAFT OF THIS COMMENT SAID IT WAS.
-- The `""` key made `crossModuleSchemeOblsQualRef` and its three sibling qual tables
-- unreadable on this driver — their readers derive `src` from a real import path
-- (`useModId`), so they missed universally — which means an INFERRED
-- cross-module obligation was SILENTLY DROPPED from the importer's scheme.  MEASURED,
-- two arms, same fixture and `MEDAKA_ROOT`, only the probe differing:
--
--   p.mdk      export f x = "\{x}!"        -- Display a, INFERRED (no signature)
--   entry.mdk  import p.{f} / g v = f v
--
--   before:  g : a -> String              ← the `Display a =>` context is GONE
--   after:   g : Display a => a -> String  (and `medaka check`, an untouched driver
--                                           routing through `analyzeProject`, agrees)
--
-- That reached users through `projectEntrySchemes` — LSP project hover reported the
-- unconstrained type.  Pinned at
-- `test/check_module_fixtures/inferred_cross_module_obligation/`, whose header records
-- why the other eight fixtures were blind to the shape (all signatured or
-- interface-method-typed, so their contexts are DECLARED and ride the module seed).
-- An under-claimed fix is one nobody writes a test for, which is exactly what happened
-- between this comment's first draft and adversarial review.
cmCheckWorker : ModuleCtx ->
  String ->
  ModuleSeed ->
  List Decl ->
  List Decl ->
  List Decl ->
  (ModuleBindings, List (String, PubScheme), ModuleCtx)
cmCheckWorker prev mid seed _accData _accAll prog =
  -- #2705: this is the SCHEMES-ONLY query driver — LSP hover/completion
  -- (`projectEntrySchemes`) and the linear-time perf gate — and it does NOT solve:
  -- it types the marked tree (`checkBodyImpl` directly, so no stamping context is
  -- queued) and reads schemes off inference.  A solve here would need the impl
  -- universe (`accAll ++ prog`, the concat #154 PR-C removed from this path; MEASURED
  -- to red `diff_compiler_perf_scaling`'s `modules` row at 4.48 against a 4.2
  -- ceiling) and would re-solve the whole graph per hover.  The memoized solve that
  -- makes this path one driver with the others is #2719.
  let (schemes, _, mctx) =
    checkBodyImpl prev.mcGraph (checkRunResidue prev) seed mid [] prog
  (schemes, publishOwn mctx schemes.mbSchemes, mctx)

-- check every module in dependency order against a shared prelude + runtime.
-- modules = (moduleId, desugared program) in dependency-first order.
export
checkModules : DriveInputs ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List (String, List (String, PubScheme))
checkModules inputs runtimeDecls coreDecls0 modules0 =
  checkModulesK inputs None runtimeDecls coreDecls0 modules0

-- Keyed form of `checkModules`.  `preludeKey` is the desugar-cache generation pair
-- identifying `runtimeDecls`/`coreDecls0`; passing it lets `checkCoreMemoized` hit
-- the process-wide prelude interface instead of re-typechecking AND re-solving the
-- whole prelude on every call.  `None` reproduces the unkeyed behavior exactly.
--
-- #2719 (a1): the LSP hover/completion driver (`projectEntrySchemes`) used the
-- unkeyed `checkModules`, so an unkeyed lookup never hit and every hover paid
-- a cold prelude check-and-solve.  Caching the interface from HERE cannot poison a
-- later analyze: the miss arm computes the identical thing either way
-- (`checkModuleFull` over core, then `checkGraphFinish`), and this driver's own
-- worker (`cmCheckWorker`) queues no stamping context, so no drain interacts.
export
checkModulesK : DriveInputs ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List (String, List (String, PubScheme))
checkModulesK inputs preludeKey runtimeDecls coreDecls0 modules0 =
  -- #1110: acquire type-constructor identity over the whole graph before anything
  -- typechecks; the rebind shadows the raw params so no line below can read the
  -- unstamped tree.  See `checkModulesPreambleK` for why it is here and not there.
  let (coreDecls, modules) = stampGraphDecls coreDecls0 modules0
  let (runtimeSeed, coreSchemes, coreCtx) =
    checkModulesPreambleK inputs preludeKey runtimeDecls coreDecls modules
  fst (cmFold runtimeSeed coreSchemes coreCtx modules)

-- `checkModulesK` also handing back what its drive left for the last module it
-- checked (its locals and import seed), taken at the drive's end.  It returns no
-- `TcReport`: the drive harvests no diagnostics, so it judges nothing.
export
checkModulesPartialK : DriveInputs ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  PartialAnalysis
checkModulesPartialK inputs preludeKey runtimeDecls coreDecls0 modules0 =
  fst
    (checkModulesPartialLast inputs preludeKey runtimeDecls coreDecls0 modules0)

-- `checkModulesPartialK` beside the record its drive ends in, for the callers that
-- read what the drive left (`matchWarningsNow`).
export
checkModulesPartialLast : DriveInputs ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  (PartialAnalysis, ModuleCtx)
checkModulesPartialLast inputs preludeKey runtimeDecls coreDecls0 modules0 =
  let (coreDecls, modules) = stampGraphDecls coreDecls0 modules0
  let GraphPreamble { gpRuntimeSeed = runtimeSeed, gpCoreSchemes = coreSchemes, gpCorePub = coreClosed, gpCoreContexts = coreContexts, gpCoreCtx = coreCtx, ... } =
    graphPreamble
      inputs
      omEmpty
      GOutDiags
      preludeKey
      runtimeDecls
      coreDecls
      modules
  let (rows, lastCtx) = cmFold runtimeSeed coreSchemes coreCtx modules
  (
    partialAnalysis
      rows
      (publishedCore coreClosed coreContexts coreSchemes.mbSchemes)
      (captureEntryTables lastCtx coreContexts modules),
    lastCtx,
  )

-- [coreCtx] is the record the core pass left current; the last module's record comes
-- back beside the rows.
cmFold : List (String, Scheme) ->
  ModuleBindings ->
  ModuleCtx ->
  List (String, List Decl) ->
  (List (String, List (String, PubScheme)), ModuleCtx)
cmFold runtimeSeed coreSchemes coreCtx modules =
  -- cmCheckWorker reads NEITHER accData (checkModuleFull → Module path, where
  -- checkBodyImpl binds it `_` and never reads it) NOR accAll (its `_accAll` param),
  -- so AccumulateNone threads them unchanged (no copy) and the `[] []` initials keep
  -- the dead values empty → the whole perf-gate `checkModules` path is O(N).  #2705: this
  -- driver marks but does not solve — see `cmCheckWorker` — so it queues nothing and
  -- drains nothing.
  let (rows, _, lastCtx) =
    foldModules
      FoldPlan {
        fpAccumulate = AccumulateNone,
        fpWorker = cmCheckWorker,
        fpCollect = _place mid schemes rest => (mid, schemes) :: rest,
        fpBaseSeed = runtimeSeed ++ coreSchemes.mbSchemes,
        fpCoreV =
          tagModuleExports coreSchemes.mbStandaloneSchemes coreSchemes.mbSchemes,
      }
      None
      []
      []
      []
      []
      coreCtx
      modules
  (map (m => (fst m, freezeRows (snd m))) rows, lastCtx)

-- multi-module diagnostics driver: threads the runtime+core seed and per-module
-- PUBLIC accumulators exactly as foldModules threads, but at each module harvests its
-- ISOLATED diagnostics via checkModuleFullDiags.  Returns one
-- (mid, (errs, warns)) per module in load order.  Core is checked ONCE (its
-- diagnostics are not surfaced — it is the trusted prelude, as in checkModules).
-- IMPORT-SCOPED seed (baseSeed ++ importSeed prog depEnv), exactly like
-- foldModules — NOT a flat union of every earlier module's publics, which let
-- a same-named function from a non-imported module win by load order (e.g.
-- string.reverse shadowing the list.reverse a module imports → spurious errors).
-- worker: ISOLATED per-module diagnostics harvest (`checkModuleFullDiags` in
-- `types/tc_module.mdk`).  Surfaces this module's own `schemes` (for pubV) plus the
-- (marked tree, schemes, errs, warns) payload.  IMPORT-SCOPED seed exactly like
-- cmCheckWorker; NOT a flat union.  ONE worker serves EVERY graph consumer — the
-- per-module diagnostics fold behind `analyzeProject` and the LSP, the entry report (`checkModulesEntryFullSplitK`), and the elaboration behind
-- `run`/`build`/`test`/the emit entries.  They differ in what they PROJECT from the
-- payload, never in what a module is checked against.  Keeping it one function is
-- what makes that a property of the code rather than of a comment: the consumers
-- CANNOT drift on the universe or the seed.
--
-- The `GOutTrees` writes are the only per-module divergence, and each is a
-- consequence of dict-passing rather than of checking: `mainSchemeRef` is written
-- Some-only so the last module binding
-- `main` wins (the diags arm's `collect` writes it SET-OR-CLEAR on the entry module
-- instead), and the promotion harvest unions THIS module's inferred-constraint
-- promotions before the next module's `freshModuleCtx` wipes `promotedRef` —
-- `foldModules` calls the worker HEAD-first, which is what makes that read safe.
--
-- The impl universe is `accAll ++ prog`, NOT bare `accAll` — it includes THIS module.
-- `foldModules` never folds a module into its own
-- `accAll` (see `checkModuleFullImpl`'s E5 note: "a caller that needs this module's own
-- decls too must fold [prog] in itself"), so the readers of `checkBodyImpl`'s
-- `implDecls` on this arm — `visibleMethodRows`, `inferUserImplBodies`' field-type
-- universe, `superDecls` and the `importerShadows` emptiness test — see this
-- module's own declarations only through this fold.  Return-only dispatch on an
-- own-module impl (`test/engine_fixtures/return_only_param_dispatch.mdk`, and
-- `test/run_check_agreement_fixtures/accept_own_module_impl_return_only_dispatch.mdk`
-- for the entry module of a graph) does not depend on it: determination reads the
-- whole-graph `IE` through `improvementPool`.
-- Cost: `accAll ++ prog` copies the accumulator, so O(|accAll|) per module and
-- quadratic over the graph; this is not the perf-gated `checkModules` path, which is
-- `cmCheckWorker`'s.  Each copy is short-lived only while nothing holds it until graph
-- end, which is why a module's stamping context keeps the interface decls alone.
--
-- #2246: the payload carries `schemes` a SECOND time.  `foldModules` hands the worker's
-- FIRST component to the NEXT module (it is the fold's seed, never `collect`'s), so the
-- only way the terminal module's own bindings reach `graphCollect` — which owes
-- `mainSchemeRef` its SET-OR-CLEAR write — is inside the payload, and the entry-report
-- projection needs the same triple to keep the terminal module's OWN schemes/warns.
-- Costs nothing: `checkModuleFullDiags` already computed them, and the marked tree is
-- the same list value the module was marked in, not a copy. The diagnostics
-- payload omits trees because the fold retains payloads until graph completion.
graphModuleWorker : OrdMap Unit ->
  GraphOut ->
  ModuleCtx ->
  String ->
  ModuleSeed ->
  List Decl ->
  List Decl ->
  List Decl ->
  (ModuleBindings, (List Decl, List (String, PubScheme), List TcDiag, List TcDiag, Option InvocationView), ModuleCtx)
graphModuleWorker capture sel prev mid seed accData accAll prog =
  let implDecls = accAll ++ prog
  let (schemes, marked, errs, warns, mctx) =
    checkModuleFullDiags prev.mcGraph mid seed accData implDecls prog
  let published = publishOwn mctx schemes.mbSchemes
  let tree = match sel
    GOutTrees =>
      match lookupAssoc "main" schemes.mbSchemes
        Some sc => prev.mcGraph.mainSchemeRef := Some sc
        None => ()
      prev.mcGraph.promotionHarvestRef :=
        dedup
          (prev.mcGraph.promotionHarvestRef.value
            ++ mctx.mcCells.promotedRef.value)
      marked
    GOutDiags => []
  let view =
    if omHasKey mid capture then
      Some mctx.mcCells.invocationViewRef.value
    else
      None
  (schemes, (tree, published, errs, warns, view), mctx)

-- collect: keeps the worker's marked tree and its `(schemes, errs, warns)` payload
-- per module in load order, and on the DIAGS selection's TERMINAL module records
-- that module's `main` scheme.  Two accumulators rather than two folds — the worker
-- computes both in one per-module pass, and the tree arm's `dictPassModulesIfEnabled`
-- consumes the first while every arm's caller consumes the second.  The tree arm
-- does NOT write `mainSchemeRef` here: its worker already wrote it per module,
-- Some-only.  The `schemes` half is what lets a caller derive the ENTRY REPORT — the
-- terminal module's own schemes and warnings, plus every module's errors — from this
-- one pass instead of from a second, entry-only driver over the same graph
-- (`checkModulesEntryFromDiags` below is that projection, and it is the old
-- entry-only `collect` written as a fold over this list).  `checkModulesDiagsChain`'s
-- exported signature (a selfproc LEG A row) keeps the narrower `(errs, warns)` shape:
-- it projects.
--
-- #2246: this is the multi-module `analyzeProject` path's ONLY producer of
-- `mainSchemeRef`.  S-3 (#2234) made `mainShapeWarnings` pure — it now READS the ref
-- rather than re-elaborating — which was correct for every caller that had a
-- producer, but `checkJsonFile`'s multi-module arm (driver/diagnostics.mdk) had NONE:
-- `analyzeProject` → `typecheckPassFull` → here, and nothing on that chain wrote it.
-- Both directions of that hole are pinned:
--   * fresh process — the ref is `None`, `mainIsUnitNow` answers False on `None`,
--     so W-MAIN-SHAPE FIRED on a clean Unit main (false positive on every
--     `check --json` / MCP `medaka_check` of a multi-module project);
--   * long-lived process (`medaka mcp`, `medaka lsp`) — the ref held whatever an
--     EARLIER request left, so a genuinely non-Unit `main` had its real warning
--     SILENTLY VANISH behind a previous request's Unit scheme.  [W-QUIETER]: that
--     direction is the more dangerous one.
-- SET-OR-CLEAR in ONE write, never a conditional/partial one: `lookupAssoc` yields
-- `None` when the terminal module has no `main`, and writing that `None` is what
-- clears a previous run's leftover.  Mirrors `checkModulesEntryFullSplitK`'s write
-- (same last-wins entry-module rule; dependency-first order puts the entry last).
graphCollect : GraphCtx ->
  GraphOut ->
  ModulePlace ->
  String ->
  (List Decl, List (String, PubScheme), List TcDiag, List TcDiag, Option InvocationView) ->
  (List (String, List Decl), List ModDiags, List (String, InvocationView)) ->
  (List (String, List Decl), List ModDiags, List (String, InvocationView))
graphCollect gctx sel place mid (marked, schemes, errs, warns, view) (markedRest, diagsRest, views) =
  match sel
    GOutDiags => setMainSchemeIfEntry gctx place schemes
    GOutTrees => ()
  -- The DIAGS selection keeps no tree: its `driveGraphK` arm returns
  -- `gdModules = []`, and its worker puts none in the payload (`graphModuleWorker`).
  let markedOut = match sel
    GOutDiags => markedRest
    GOutTrees => (mid, marked) :: markedRest
  (
    markedOut,
    (mid, (schemes, errs, warns)) :: diagsRest,
    option views (v => (mid, v) :: views) view,
  )

-- the `(errs, warns)` projection of one full per-module entry, for the exported
-- drivers whose contract is the narrower pair.
export
dropModSchemes : ModDiags -> (String, (List TcDiag, List TcDiag))
dropModSchemes (mid, (_, errs, warns)) = (mid, (errs, warns))

-- The ENTRY REPORT as a projection over the full per-module list: the TERMINAL
-- module's own schemes and warnings, and every module's errors accumulated
-- dependency-first — a type error in an IMPORTED module is still a hard error of
-- `check`ing the entry graph and must surface (else it silently reaches codegen, the
-- G1-class soundness hole).  This is what makes the entry report and the diagnostics
-- fold ONE typecheck rather than two.
--
-- The whole-graph coherence verdict is already attached by the driver
-- (`attachCoherenceConflict`): the soft half sits at the front of the terminal
-- module's warnings, exactly where `checkModulesEntryFullSplitK` prepends it.  The
-- hard half sits at the front of the terminal module's ERRORS rather than at the
-- front of the accumulated list, which differs only on a graph that has both a
-- conflict and an imported-module type error — a graph whose caller has already
-- reported errors and exited.
checkModulesEntryFromDiags : List ModDiags ->
  (List (String, PubScheme), List TcDiag, List TcDiag)
checkModulesEntryFromDiags [] = ([], [], [])
checkModulesEntryFromDiags [(_, (s, e, w))] = (s, e, w)
checkModulesEntryFromDiags ((_, (_, e, _)) :: rest) =
  let (eS, eE, eW) = checkModulesEntryFromDiags rest
  (eS, e ++ eE, eW)

-- `checkModulesEntryReport`'s renderer, over per-module diagnostics a driver already
-- produced.  Both must render identically or `check`'s multi-module report changes
-- shape, which is why the match below is `checkModulesEntryReport`'s verbatim.
export
entryReportFromDiags : List ModDiags -> String
entryReportFromDiags perMod = match checkModulesEntryFromDiags perMod
  (schemes, [], warns) => joinNl (schemeLines schemes ++ map tcMsg warns)
  (_, errs, _) => joinNl (typeErrorLines (map tcMsg errs))

-- The SET-OR-CLEAR write itself, on the terminal (entry) module only.  Split out of
-- `graphCollect` so the "never a partial write" property is one two-clause
-- function rather than an inline conditional.
setMainSchemeIfEntry : GraphCtx ->
  ModulePlace ->
  List (String, PubScheme) ->
  Unit
setMainSchemeIfEntry gctx NotLastModule _ = ()
setMainSchemeIfEntry gctx LastModule schemes =
  gctx.mainSchemeRef := map (p => p.psScheme) (lookupAssoc "main" schemes)

-- The prelude generation pair plus the chain key: the driver's pass caches
-- (`driver/diagnostics.mdk`) carry it whole, and the module interfaces' graph key
-- (`serveStateOf`) only its first line, the generation, never the entry or roots.
export
chainFullKey : Int -> Int -> String -> String
chainFullKey rk ck chainKey = "\{intToString rk},\{intToString ck}\n\{chainKey}"

-- `driveGraphK GOutDiags` over [modules0].  Under a prelude key the drive serves the
-- modules before the entry from their interfaces (`diagsServe`), with [stepKeys]
-- pairing one source key with each module positionally.  The per-module payload is
-- the worker's whole `(schemes, errs, warns)` triple: a caller that also needs the
-- graph's ENTRY REPORT derives it from this list (`entryReportFromDiags`) instead of
-- running a second, entry-only driver over the same graph.  `dropModSchemes` is the
-- narrower `(errs, warns)` projection the bucketing fold consumes.
export
checkModulesDiagsChain : DriveInputs ->
  Option (Int, Int) ->
  String ->
  List (Option String) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List ModDiags
checkModulesDiagsChain inputs preludeKey chainKey stepKeys runtimeDecls coreDecls0 modules0 =
  checkModulesDiagsChainFor
    inputs
    False
    preludeKey
    chainKey
    stepKeys
    runtimeDecls
    coreDecls0
    modules0

-- `checkModulesDiagsChain` for a caller that passes its value-main candidate
-- (`autoPrintWanted`).
checkModulesDiagsChainFor : DriveInputs ->
  Bool ->
  Option (Int, Int) ->
  String ->
  List (Option String) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  List ModDiags
checkModulesDiagsChainFor inputs valueMain preludeKey chainKey stepKeys runtimeDecls coreDecls0 modules0 =
  (fst
    (checkModulesChainReportFor
      inputs
      valueMain
      preludeKey
      chainKey
      stepKeys
      runtimeDecls
      coreDecls0
      modules0)).trDiagnostics

-- `checkModulesDiagsChainFor` returning the drive's whole report beside its
-- outputs.
export
checkModulesChainReportFor : DriveInputs ->
  Bool ->
  Option (Int, Int) ->
  String ->
  List (Option String) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  (TcReport, DriveOutputs)
checkModulesChainReportFor inputs valueMain preludeKey chainKey stepKeys runtimeDecls coreDecls0 modules0 =
  fst
    (checkModulesChainReportForGraph
      (chainArgs
        inputs
        valueMain
        preludeKey
        chainKey
        stepKeys
        runtimeDecls
        coreDecls0
        modules0))

-- The arguments of a drive keyed under the prelude generation pair [preludeKey] and
-- [chainKey], with one source key per module in [stepKeys]; unkeyed under `None`.
export
chainArgs : DriveInputs ->
  Bool ->
  Option (Int, Int) ->
  String ->
  List (Option String) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  DriveArgs
chainArgs inputs valueMain preludeKey chainKey stepKeys runtimeDecls coreDecls0 modules0 =
  let base =
    driveArgs inputs valueMain preludeKey runtimeDecls coreDecls0 modules0
  { base |
    daKeyed =
      map ((rk, ck) => (chainFullKey rk ck chainKey, stepKeys)) preludeKey,
  }

-- The arguments of an unkeyed drive that executes nothing.
export
driveArgs : DriveInputs ->
  Bool ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  DriveArgs
driveArgs inputs valueMain preludeKey runtimeDecls coreDecls0 modules0 =
  DriveArgs
    inputs
    valueMain
    None
    preludeKey
    None
    runtimeDecls
    coreDecls0
    modules0

-- `checkModulesChainReportFor` beside the graph record its drive ends in, for a test
-- that observes that record after the drive.
export
checkModulesChainReportForGraph : DriveArgs ->
  ((TcReport, DriveOutputs), GraphCtx)
checkModulesChainReportForGraph args =
  let g = driveGraphK GOutDiags args
  ((g.gdReport, g.gdOutputs), g.gdGraph)

-- ── serving modules from their interfaces ───────────────────────────────────

-- The drain and open-variable test the serve policy (`types/serve_policy.mdk`) calls.
serveOps : ServeOps
serveOps = ServeOps {
  soDrain =
    mctx rows => match checkGraphFinish mctx
      [] => rows
      findings => attachDrainFindings findings rows,
  soUnboundIds = monoUnboundIds,
}

-- [rows] with every row past the oldest [n] frozen: the oldest [n] were frozen when
-- they were recorded or served.
freezeFrom : Int -> List ModDiags -> List ModDiags
freezeFrom n rows = take n rows ++ map freezeModDiags (drop n rows)

-- #1112 A-3: the disposition producer.  For every accepted instance
-- (`ieRowsAll` — every impl row in the whole-graph `IE`, prelude included) and
-- every method of its interface's `CeRow`, exactly one row: `Supplied` when the
-- impl names the method, `InheritedDefault` when it does not and the method is
-- not in `ceRowRequired` (a required method with no default and no override is
-- rejected upstream, M1 — never reaches this walk at all).
buildDispositions : GraphCtx -> DeclEnvs -> DispositionTable
buildDispositions gctx envs =
  let impls = ieRowsAll envs.deImpls
  let table =
    buildDispositionTableWithShapes
      (dispositionRowsOfImpls envs.deImpls impls envs.deIfaces)
      (map (ifaceSuperCountOfRow gctx) impls)
  validateDispositionTable (dispositionSlotsOfImpls impls envs.deIfaces) table
  table

-- Every slot an accepted instance must have exactly one disposition for: each
-- method of its interface that it names, or that has a default to inherit.
dispositionSlotsOfImpls : List ImplRow ->
  ClassEnv ->
  List (InstId, IfaceRef, String)
dispositionSlotsOfImpls [] _ = []
dispositionSlotsOfImpls (r :: rest) ce =
  let (iface, _, _) = ieRowTriple r
  let inst = InstId (instRefMid (ieRowInst r)) (instRefSeq (ieRowInst r))
  let supplied = ieRowMethodNames r
  let here =
    match (ceLookupAt
      (regKeyOfTab (ifaceTabKey iface.irOrigin iface.irName))
      (ieRowOrd r)
      ce)
      None => []
      Some ceRow =>
        map
          (m => (inst, iface, m))
          (filter
            (m => contains m supplied || not (contains m (ceRowRequired ceRow)))
            (ceRowMethodNames ceRow))
  here ++ dispositionSlotsOfImpls rest ce

dispositionRowsOfImpls : ImplEnv ->
  List ImplRow ->
  ClassEnv ->
  List (InstanceShape, String, MethodDisposition)
dispositionRowsOfImpls _ [] _ = []
dispositionRowsOfImpls ie (r :: rest) ce =
  dispositionRowsOfImpl ie r ce ++ dispositionRowsOfImpls ie rest ce

-- Each row carries its instance's shape and its interface's word.  The shape's
-- route word is minted by the same call the lowering and eval install passes make
-- on the impl's declaration (`implRouteKeyWord` over the impl's own origin and type
-- arguments), so an inherited slot's entry is named and reached exactly as the
-- instance's supplied methods are.
dispositionRowsOfImpl : ImplEnv ->
  ImplRow ->
  ClassEnv ->
  List (InstanceShape, String, MethodDisposition)
dispositionRowsOfImpl _ r ce =
  let (iface, tys, _) = ieRowTriple r
  let inst = InstId (instRefMid (ieRowInst r)) (instRefSeq (ieRowInst r))
  let ifaceWord = ifaceWordOf iface.irOrigin iface.irName
  let supplied = ieRowMethodNames r
  let shape = InstanceShape {
    isWord = implRouteKeyWord iface.irOrigin iface.irName tys None,
    isTys = tys,
  }
  match (ceLookupAt
    (regKeyOfTab (ifaceTabKey iface.irOrigin iface.irName))
    (ieRowOrd r)
    ce)
    -- An impl whose interface is not visible has already been reported, and
    -- `dispositionSlotsOfImpls` expects no slot for it either.
    None => []
    Some ceRow =>
      map
        (d => (shape, ifaceWord, d))
        (dispositionRowsOfMethods
          inst
          iface
          supplied
          (ceRowRequired ceRow)
          (ceRowMethodNames ceRow))

-- The interface word of [r]'s interface with its direct superinterface count: the
-- super segment every dictionary of that interface stores.
ifaceSuperCountOfRow : GraphCtx -> ImplRow -> (String, Int)
ifaceSuperCountOfRow gctx r =
  let (iface, _, _) = ieRowTriple r
  (
    ifaceWordOf iface.irOrigin iface.irName,
    listLen (directSuperGoals gctx iface []),
  )

dispositionRowsOfMethods : InstId ->
  IfaceRef ->
  List String ->
  List String ->
  List String ->
  List MethodDisposition
dispositionRowsOfMethods _ _ _ _ [] = []
dispositionRowsOfMethods inst iface supplied required (m :: rest) =
  let restRows = dispositionRowsOfMethods inst iface supplied required rest
  if contains m supplied then
    Supplied { instance = inst, iface = iface, method = m } :: restRows
  else if not (contains m required) then
    InheritedDefault { instance = inst, iface = iface, method = m } :: restRows
  else
    -- A required method with no default and no override: M1 pushes a
    -- diagnostic (accumulate-errors, never an abort — T-ERRORS-ACCUM), so
    -- elaboration still reaches this walk on an already-ill-typed program.
    -- No disposition is correct for a slot the program will not compile
    -- with, so it is skipped rather than fabricated — panicking here turned
    -- a clean REJECT into a crash on
    -- test/run_check_agreement_fixtures/p0_17_missing_impl_method.mdk.
    restRows

-- Drive the whole module graph ONCE: stamp type-constructor identity, run the
-- shared preamble, check every module dependency-first through one worker, drain
-- at graph end, and attach the whole-graph coherence verdict.  `sel` chooses what
-- comes back (see `GraphOut`).  Every whole-graph entry point below is a projection
-- of this function.
--
-- [keyed] is a keyed drive's chain key (`chainFullKey`) and one source key per
-- module, `None` for every other drive.  Under it the fold serves each unchanged
-- module before the entry from its recorded interface and records the modules it
-- checks (`diagsServe`); a tree drive also serves and records each module's marked
-- trees, which `dictPass` then passes with the rest of the graph (`treeServe`).
-- Whether a drive is keyed is its caller's choice: a one-shot process passes no
-- source keys, so it neither serves nor records, and a session (the LSP, the
-- playground, `medaka test`) keeps the interfaces between drives.
--
-- `preludeKey` is the desugar-cache generation pair for the prelude interface (see
-- `checkCoreMemoized`); the tree arm ignores it and reads the drive's own
-- `diPreludeKey` (`treeArmHit`), since it also needs core's dict-passed decls,
-- which an interface does not hold.  `valueMain` is the caller's
-- value-main candidate and `executes` names the `async` driver of a caller that
-- runs the trees, `None` for one that does not (`autoPrintWanted`).
driveGraphK : GraphOut -> DriveArgs -> GraphDrive
driveGraphK sel (DriveArgs inputs valueMain executes preludeKey keyed runtimeDecls coreDecls0 modulesIn) =
  -- IMPORT ALIASING of an interface/impl METHOD — a method is global-by-name, so an
  -- alias of one is a second SPELLING, not a second binding.  A member alias and a
  -- module alias both keep their spelling through inference and are resolved at the
  -- end of the tree arm (`resolveAliasMethodSpellings`).  See
  -- `renameAliasedMethods`.  BOTH selections rename: that rewrite makes
  -- `import m as A` bind `m`'s methods under their ORIGIN name as well, which decides
  -- WHICH declaration a bare occurrence of that name resolves to — a binding change,
  -- not a spelling one, so a selection that skips it typechecks a different program.
  -- Only the RESTORE (`resolveAliasMethodSpellings`) is tree-arm-only: it rewrites
  -- occurrences in trees the diags arm does not emit.
  let (admitted, modulesAliased) = renameAliasedMethods coreDecls0 modulesIn
  -- #1110: acquire type-constructor identity over the whole graph before anything
  -- typechecks; the rebind shadows the raw params so no line below can read the
  -- unstamped tree.  It is HERE, not in the preamble, because this is the seam the
  -- RUN path and the separate `medaka_emitter` BUILD process share — the emitter
  -- never runs resolve, so acquiring identity anywhere upstream would give `check`
  -- and `build` different trees.  Method-alias renaming comes first: it is a name
  -- rewrite on VALUES and cannot move a type head, so the graph reaches identity
  -- minting in its final shape and no later pass has to re-mint.
  let (coreDecls, modules) = stampGraphDecls coreDecls0 modulesAliased
  let GraphPreamble { gpRuntimeSeed = runtimeSeed, gpCoreSchemes = coreSchemes, gpCorePub = coreClosed, gpCoreContexts = coreContexts, gpCoreTree = coreTree, gpMarkSets = ms, gpCoreCtx = coreCtx } =
    graphPreamble inputs admitted sel preludeKey runtimeDecls coreDecls modules
  let capture =
    requestedWrapperViewModules
      inputs.diManifestRequests
      (manifestDriverFor inputs executes)
  let serve =
    map
      (k =>
        let st = serveStateOf serveOps capture coreCtx.mcGraph modules k
        match sel
          GOutDiags => diagsServe st
          GOutTrees => treeServe st)
      keyed
  if isSome serve then raiseToHighWater coreCtx.mcGraph
  -- The worker reads BOTH accData (buildOracle `prog ++ accData`) and
  -- accAll (checkModuleFullImpl implDecls), and
  -- both are order-observable (oracle first-wins, implDecls scan order), so both
  -- concats are RETAINED — this is not the perf-gate path, which is `cmCheckWorker`'s.
  let coreView = coreCtx.mcCells.invocationViewRef.value
  let ((modules2, perModRaw, views), served, lastCtx) =
    foldModules
      FoldPlan {
        fpAccumulate = AccumulateBoth,
        fpWorker = graphModuleWorker capture sel,
        fpCollect = graphCollect coreCtx.mcGraph sel,
        fpBaseSeed = runtimeSeed ++ coreSchemes.mbSchemes,
        fpCoreV =
          tagModuleExports coreSchemes.mbStandaloneSchemes coreSchemes.mbSchemes,
      }
      serve
      ([], [], [])
      []
      (publicDataDecls coreDecls)
      coreDecls
      coreCtx
      modules
  -- #2548: quiescence.  Every module (core first) has been inferred and has queued
  -- its stamping context; drain them all now, in module order, before any tree goes
  -- to `dictPassModulesIfEnabled`.  The drive ends in the last module's record.  A
  -- keyed drive's drains, its recording modules' and this one, restore the sticky
  -- type-error cells (`checkGraphFinish`), so a served module's recorded sticky rows
  -- are the ones a check of it leaves.
  let findings =
    if isSome serve then checkGraphFinish lastCtx else drainStampQueue lastCtx
  if isSome serve then noteHighWater lastCtx.mcGraph
  let servedCount = optionOr 0 (map (policy => policy.msServed) served)
  -- D3 / WS-2 part-2: attach any cross-module coherence conflict to the ENTRY
  -- module's diagnostics (last in dependency-first order), so LSP/analyzeProject
  -- surfaces it too.  User modules only (prelude excluded).
  -- #414: no span — see globalCoherenceConflict (the entry module it attaches to is
  -- not the module the span would name, and the renderer keys the file by group).
  -- F-3d: the ⊑-incomparable half rides the WARNING list of the same module.
  -- #1559 A-3.7: the whole-graph `IE` the preamble built above; `cohRowsOf` is
  -- what excludes the prelude, replacing "walk the user `modules` list".
  -- It reads `deImpls` only, which nothing between here and the tree arm's return
  -- writes, so attaching once here serves both selections.
  let (wanted, autoPrint) =
    autoPrintWanted
      lastCtx
      valueMain
      executes
      findings
      perModRaw
      coreDecls
      modules
  let outcome = entryOutcomeNow lastCtx (mainHasObligations lastCtx) autoPrint
  -- The graph is closed: the drain, its defaulting and the auto-print verdict
  -- have run, so the published rows are frozen now, once.
  let perMod =
    attachCoherenceConflict
      lastCtx
      (attachDrainFindings
        (findings ++ wanted)
        (freezeFrom
          (optionOr 0 (map (policy => policy.msFrozen) served))
          perModRaw))
  -- Before the tree arm's `dictPass`, which writes the record's slot tables.
  let entryTables = captureEntryTables lastCtx coreContexts modules
  let corePub = publishedCore coreClosed coreContexts coreSchemes.mbSchemes
  let (requests, manifests, manifestDiags) =
    publishSelected
      lastCtx.mcGraph.effectDomains.value
      (invocationResolver
        (frozenInvocationOps
          lastInvocationOps
          (driveOutputsNow lastCtx outcome))
        (completionInvocationViews lastCtx coreView views))
      inputs.diManifestRequests
      perMod
      corePub
      outcome
      (manifestDriverFor inputs executes)
      valueMain
  -- #1112 A-3: the whole-graph IE/CE `buildDeclEnvs` filled in the preamble
  -- above is already complete at this point, on both arms alike.
  let dispositions =
    buildDispositions lastCtx.mcGraph lastCtx.mcGraph.declEnvsRef.value
  match sel
    -- A served module's evidence cells are not carried (`types/module_interface.mdk`),
    -- so a keyed drive's `cpEvidence` holds the checked modules' cells only.  No
    -- diagnostics-arm consumer reads it.
    GOutDiags => GraphDrive {
      gdPerMod = perMod,
      gdCoreSchemes = corePub,
      gdCoreContexts = coreContexts,
      gdCore = [],
      gdModules = [],
      gdResidual = [],
      gdEvTable = lastCtx.mcGraph.graphRun.evTable.value,
      gdDispositions = dispositions,
      gdBinders = lastCtx.mcGraph.graphRun.binderRows.value,
      gdReport =
        graphReportWithOutcome
          outcome
          manifests
          manifestDiags
          perMod
          corePub
          []
          (drivenEvidence lastCtx.mcGraph)
          dispositions
          lastCtx.mcGraph.graphRun.binderRows.value
          None
          entryTables,
      gdGraph = lastCtx.mcGraph,
      gdOutputs = withPublishedManifests
        requests
        manifests
        { driveOutputsNow lastCtx outcome | doServedModules = servedCount },
    }
    GOutTrees =>
      -- The set `dictPass` prepends dict params for: the bare set plus every
      -- promotion the sweep made, with the import aliases of both — the union of
      -- what every module was marked with (`beginModuleMarking`,
      -- `markRecursiveOccurrences`).
      let dictNames =
        markDictNames
          lastCtx.mcGraph
          (dedup
            (ms.msBareDictNames ++ lastCtx.mcGraph.promotionHarvestRef.value))
          coreDecls
          modules
      -- On a hit (`treeArmHit`: the core pass closed core) core's trees arrive
      -- dict-passed, and core's evidence and binder rows join the drive's.
      let shipped = match coreClosed
        Some _ => treeArmElab inputs coreDecls
        None => None
      let (coreD, modules3) =
        dictPassModulesIfEnabled
          lastCtx
          dictNames
          (isSome shipped)
          coreTree
          modules2
      -- `resolveAliasMethodSpellings` restores the origin name behind every
      -- alias-qualified method occurrence (`A.mth` -> `mth`) that inference kept.
      -- Only the user modules go through it: core imports nothing, so it holds no
      -- alias-qualified spelling to restore.
      let modulesOut =
        map (resolveAliasMethodSpellings lastCtx.mcGraph) modules3
      let residual =
        stickyDiagsInPushOrder lastCtx.mcGraph.typeErrorsStickyDiags.value
      -- read after `dictPass`, so it carries the `EMethodAt` nodes `dictPass` minted
      let (evidence, binders) =
        withShippedRows
          shipped
          (drivenEvidence lastCtx.mcGraph ())
          lastCtx.mcGraph.graphRun.binderRows.value
      GraphDrive {
        gdPerMod = perMod,
        gdCoreSchemes = corePub,
        gdCoreContexts = coreContexts,
        gdCore = coreD,
        gdModules = modulesOut,
        gdResidual = residual,
        gdEvTable = evidence,
        gdDispositions = dispositions,
        gdBinders = binders,
        gdReport =
          graphReportWithOutcome
            outcome
            manifests
            manifestDiags
            perMod
            corePub
            residual
            (_ => evidence)
            dispositions
            binders
            (Some (coreD, modulesOut))
            entryTables,
        gdGraph = lastCtx.mcGraph,
        gdOutputs = withPublishedManifests
          requests
          manifests
          { driveOutputsNow lastCtx outcome | doServedModules = servedCount },
      }

-- The whole-graph coherence verdict, attached to the entry module's diagnostics —
-- the tail `driveGraphK` ends with.  The narrower
-- `(errs, warns)` view is `map dropModSchemes` OVER this result: `cohOntoFull`
-- passes `schemes` through untouched and `attachEntryPayload` rewrites one entry,
-- so dropping the schemes commutes with attaching.
attachCoherenceConflict : ModuleCtx -> List ModDiags -> List ModDiags
attachCoherenceConflict mctx perMod =
  match globalCoherenceConflict mctx mctx.mcGraph.declEnvsRef.value.deImpls
    (None, None) => perMod
    (hard, soft) => attachEntryPayload (cohOntoFull hard soft) perMod

cohOntoFull : Option String ->
  Option String ->
  (List (String, PubScheme), List TcDiag, List TcDiag) ->
  (List (String, PubScheme), List TcDiag, List TcDiag)
cohOntoFull hard soft (schemes, errs, warns) =
  (schemes, prependConflict hard errs, prependIncomparable soft warns)

-- rewrite the LAST module's payload in a per-module diag list (the entry module is
-- last in dependency-first order).
attachEntryPayload : (p -> p) -> List (String, p) -> List (String, p)
attachEntryPayload _ [] = []
attachEntryPayload f [(mid, p)] = [(mid, f p)]
attachEntryPayload f (m :: rest) = m :: attachEntryPayload f rest

-- The auto-print obligation of a value `main` (driver/main_autoprint.mdk), posed
-- at graph end by the drive that checks the entry module.  [valueMain] is the
-- caller's syntactic candidate (a parameterless `main` with `println` in scope);
-- whether `main` is printed at all is decided here from its own scheme, so a
-- Unit-shaped or `Async` main poses nothing.  The obligation is the `println`
-- signature's own context at τ_main, `main`'s scheme as the entry module left it:
-- the declared type under a signature, else the inferred one.  It joins the entry
-- module's errors whether or not the drive already has some, except that an
-- ambiguity verdict is dropped when one of [reported] lies in `main`'s binding:
-- that error already explains the undetermined type.  It runs after the drain, which can still default a numeric `main`, and before anything later
-- reads `main`'s variables, since the verdict can ground them.  An [executes]
-- drive, whose trees the driver wraps and runs, also returns the evidence of a
-- use judged clean (`autoPrintEvidence`); a check-only drive mints none.  Such a
-- drive judges an `Async` main's application to the driver it names instead
-- (`asyncDriverFindings`).  [mctx] is the record current after the drain, whose
-- type-error channel the verdict is taken from.
autoPrintWanted : ModuleCtx ->
  Bool ->
  Option String ->
  List DrainFinding ->
  List ModDiags ->
  List Decl ->
  List (String, List Decl) ->
  (List DrainFinding, Option EvId)
autoPrintWanted mctx False _ _ _ _ _ = ([], None)
autoPrintWanted mctx True executes findings perMod coreDecls modules =
  let decls = coreDecls ++ flatMap snd modules
  match (
    mctx.mcGraph.mainSchemeRef.value,
    last modules,
    printlnIface decls,
  )
    (Some scheme, Some (mid, entry), Some iface) =>
      if mainIsUnitNow mctx.mcGraph (mainHasObligations mctx) () then
        ([], None)
      else if mainIsAsyncNow mctx.mcGraph () then
        (asyncDriverFindings mctx executes mid entry scheme perMod, None)
      else
        -- A top-level `main` has no givens: the use is judged in a module scope
        -- of its own.
        let scope =
          Scopes.freshScope
            (currentScopeStore mctx.mcGraph ())
            None
            0
            mid
            ModuleOwner
        openScope mctx scope
        let loc = mainBodySpan entry
        let atMain = mctxAt loc mctx
        let posed = Ref None
        let diags = captureTypeErrors atMain (_ =>
          posed := Some (judgeAutoPrintUse atMain iface scheme loc))
        let ev = match (executes, diags, posed.value)
          (Some _, [], Some tau) =>
            Some (autoPrintEvidence atMain mid scope iface tau)
          _ => None
        closeScope mctx ()
        let reported = driveErrs findings perMod
        let kept =
          if anyList (d => inMainBinding entry (tcLoc d)) reported then
            dropAmbiguity diags
          else
            diags
        (map (verdictFinding mid False) (mainUseDiags loc entry ++ kept), ev)
    _ => ([], None)

-- Every error a drive has reported so far, the drain's included.
driveErrs : List DrainFinding -> List ModDiags -> List TcDiag
driveErrs findings perMod =
  map (f => f.dfDiag) findings ++ flatMap modDiagErrs perMod

-- The printing use of `main` is a closed boundary, as a test body is (see
-- `settleClosedBody`): it instantiates `main`'s scheme with its context, poses
-- `iface` at the instance, and publishes no polymorphic result.  So a numeric
-- variable defaults as at any such boundary, a variable nothing determines is
-- ambiguous, and a closed goal gets the call channel's verdict, `requires`
-- included.  The instance the goal was posed at is returned.
judgeAutoPrintUse : ModuleCtx -> IfaceRef -> Scheme -> Option Loc -> Mono
judgeAutoPrintUse mctx iface scheme loc =
  judgeMainUse
    mctx
    (tau =>
      recordObl mctx Predicate { iface = iface, args = [tau] } 0 PCallSlot loc)
    scheme

-- The `async` driver [executes] names applied to an `Async` main, judged as the
-- printing use is (`judgeMainUse`) against the driver's scheme as the `async`
-- module published it: the drivers wrap exactly this application
-- (driver/main_autoprint.mdk's `shouldAsyncWrapMain`), after the drive.
asyncDriverFindings : ModuleCtx ->
  Option String ->
  String ->
  List Decl ->
  Scheme ->
  List ModDiags ->
  List DrainFinding
asyncDriverFindings mctx executes mid entry scheme perMod =
  let published = match lookupAssoc "async" perMod
    Some (rows, _, _) => rows
    None => []
  match option None (d => lookupAssoc d published) executes
    Some driver if mainAsyncPayloadIsUnitNow mctx.mcGraph () =>
      let scope =
        Scopes.freshScope
          (currentScopeStore mctx.mcGraph ())
          None
          0
          mid
          ModuleOwner
      openScope mctx scope
      let atMain = mctxAt (mainBodySpan entry) mctx
      let diags = captureTypeErrors atMain (_ =>
        let _ = judgeMainUse atMain (asyncDriverUse atMain driver) scheme
        ())
      closeScope mctx ()
      map (verdictFinding mid False) diags
    _ => []

-- The driver's parameter unified with `main`'s instance, the driver's context
-- posed at its own.
asyncDriverUse : ModuleCtx -> PubScheme -> Mono -> Unit
asyncDriverUse mctx driver tau =
  let (driverTy, subst) = instantiateTracked mctx driver.psScheme
  recordSchemeCallObligations mctx 0 driver.psContext subst
  match normalize driverTy
    TFun param _ _ => unify mctx param tau
    _ => ()

-- A use of `main` judged as a closed boundary: [pose] states the use's goal at
-- `main`'s instance before `main`'s own context is posed there.
judgeMainUse : ModuleCtx -> (Mono -> Unit) -> Scheme -> Mono
judgeMainUse mctx pose scheme =
  enterLevel mctx ()
  let oblMark = wMark mctx.mcCells.implObls
  let callMark = wMark mctx.mcCells.obls
  let dictMark = goalsMark mctx.mcGraph ()
  let (tau0, subst) = instantiateTracked mctx scheme
  -- A variable the value restriction left in `main`'s type is a live root, and
  -- the drain that could bind it has run: at this use it is the boundary's own,
  -- as a quantified one is.
  let fresh = flatMap (p => monoUnboundIds (snd p)) subst
  let held =
    filterList (i => not (anyList (== i) fresh)) (dedupI (monoUnboundIds tau0))
  let tau =
    substMono mctx.mcGraph (map (i => (i, freshVar mctx ())) held) [] [] tau0
  let id = optionOr 0 (omLookup "main" mctx.mcCells.schemeDefIdsRef.value)
  let context =
    lookupSchemeObls "main" id mctx.mcCells.schemeObligationsRef.value
  pose tau
  recordSchemeCallObligations mctx id (optionOr [] context) subst
  exitLevel mctx ()
  settleClosedBody mctx (tconBuiltin "Unit") oblMark callMark dictMark
  checkCallObligationsU
    mctx
    False
    mctx.mcCells.residualUnivRef.value
    (callUOblsWindow mctx callMark)
  tau

-- The evidence of the auto-print's one `Display τ_main` goal, published beside the
-- goals the drive solved so the driver's printing wrap can name it.
autoPrintEvidence : ModuleCtx -> String -> ScopeId -> IfaceRef -> Mono -> EvId
autoPrintEvidence mctx mid scope iface tau =
  let routes = routesOfMonosTopV (siteFor mctx) "" scope [tau] [iface] [[tau]]
  let g = mctx.mcGraph.graphRun
  let n = g.evCounter.value
  g.evCounter := n + 1
  let ev = EvId mid n
  g.evTable := EvEntry ev (EvMany routes) :: g.evTable.value
  ev

-- ── multi-module `check` CLI report (DRIVER-COLLAPSE Phase 4, OPTION A) ─────
-- The unified `medaka check` path for IMPORT-BEARING files: the caller loads the
-- entry + its transitive imports (loadProgram), then this typechecks the whole
-- graph in dependency order (checkModuleFullDiags per module: per-module-frame,
-- prelude seeded once) and harvests the ENTRY module's OWN (schemes, errs, warns).
-- Imports are RESOLVED (their public schemes seed the entry), so a valid cross-
-- module reference no longer falls through to `UnknownModule` — the known "native
-- check is single-file" limitation, fixed.  The entry is last in dependency-first
-- order.
--
-- ⚠️ ROUTING, corrected 2026-08-26: this comment used to say "no-import (1-module)
-- files still route through runCheck … this path is reached ONLY when the load
-- returned more than one module."  FALSE since S-migrate-check-route (E-1 #1115).
-- A no-import file now reaches HERE too, via the 1-module wrappers
-- `checkOneScheme` / `checkOneDiags` / `checkOneToLinesWithRuntime` /
-- `checkOneErrorsWithRuntime`, each of which calls this function with a SINGLETON
-- module list.  So every clause below must be correct on a 1-module graph, not
-- merely defensible on one: `foldModules`' singleton clause is a genuinely
-- user-reachable path (it is where #2024's `accAll` = initial-value defect lives),
-- and so is the whole-graph coherence prepend at the bottom.
checkModulesEntryFull : DriveInputs ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  (List (String, PubScheme), List TcDiag, List TcDiag)
checkModulesEntryFull inputs runtimeDecls coreDecls modules =
  checkModulesEntryFullK inputs None runtimeDecls coreDecls modules

checkModulesEntryFullK : DriveInputs ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  (List (String, PubScheme), List TcDiag, List TcDiag)
checkModulesEntryFullK inputs preludeKey runtimeDecls coreDecls modules =
  let (_, schemes, errs, warns) =
    checkModulesEntryFullSplitK
      inputs
      False
      preludeKey
      runtimeDecls
      coreDecls
      modules
  (schemes, errs, warns)

-- S-full-env-scheme-entry (#1116): the SAME driver, but ALSO returning the
-- prelude's own schemes — the `coreSchemes` `checkModulesPreambleK` already
-- computes and this function has always had in scope but dropped on the floor.
-- Nothing else changes: `checkModulesEntryFull` above is this minus the first
-- component, so every existing caller is byte-identical.
--
-- 🚨 The two lists are returned SEPARATE, and in this order — `(coreSchemes,
-- ownSchemes, …)` — precisely so a caller CANNOT accidentally get #2054's
-- shape.  A consumer that wants one flat env for a first-match lookup
-- (`lookupSchemeL`, `lookupAssoc`) must concat OWN FIRST: `own ++ core`.  With
-- the prelude first, a user top-level binding that shadows a prelude name
-- (`isEven x = "s"`) would lose the linear-scan race to the prelude's
-- `Int -> Bool`, which is exactly the class of defect #2054 pins on the Flat
-- arm.  The Module arm's own fold is NOT affected — `checkModulesEntryFromDiags`'
-- terminal clause still returns only the terminal module's own schemes, and no
-- re-checking or re-unification against `coreSchemes` happens here: the
-- prelude list is carried out for LOOKUP only, alongside (never merged with)
-- the module's own entry for the same bare name.
-- `preludeKey`: the prelude key for the prelude interface (see `checkCoreMemoized`);
-- `None` = unkeyed, no cache.
checkModulesEntryFullSplitK : DriveInputs ->
  Bool ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  (List (String, PubScheme), List (String, PubScheme), List TcDiag, List TcDiag)
checkModulesEntryFullSplitK inputs valueMain preludeKey runtimeDecls coreDecls0 modules0 =
  entrySplit
    (fst
      (checkModulesEntryFullReportK
        inputs
        valueMain
        preludeKey
        runtimeDecls
        coreDecls0
        modules0))

-- `checkModulesEntryFullSplitK`'s four parts, read off its drive's report.
export
entrySplit : TcReport ->
  (List (String, PubScheme), List (String, PubScheme), List TcDiag, List TcDiag)
entrySplit r =
  let (schemes, errs, warns) = checkModulesEntryFromDiags r.trDiagnostics
  (r.trPartial.paCore, schemes, errs, warns)

-- `checkModulesEntryFullSplitK` returning its drive's whole report beside its
-- outputs.
export
checkModulesEntryFullReportK : DriveInputs ->
  Bool ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  (TcReport, DriveOutputs)
checkModulesEntryFullReportK inputs valueMain preludeKey runtimeDecls coreDecls0 modules0 =
  fst
    (checkModulesEntryFullReportKGraph
      (driveArgs inputs valueMain preludeKey runtimeDecls coreDecls0 modules0))

-- `checkModulesEntryFullReportK` beside the graph record its drive ends in.
checkModulesEntryFullReportKGraph : DriveArgs ->
  ((TcReport, DriveOutputs), GraphCtx)
checkModulesEntryFullReportKGraph (DriveArgs inputs valueMain _ preludeKey _ runtimeDecls coreDecls0 modules0) =
  -- The single-file front door loads stdlib/core.mdk twice: once as its prelude and
  -- once as the singleton `__user__` module.  Resolve already owns the syntactic
  -- self-test that prevents double-seeding core.  Apply that same authority before
  -- identity stamping, so one declaration graph is not stamped once as `core` and
  -- again as `__user__`.  `None` also prevents the empty prelude pass from sharing a
  -- memo key with the separately loaded declarations we deliberately dropped.
  -- Partial lookalikes remain ordinary because `programIsCore` requires BOTH halves.
  let (effectivePreludeKey, effectiveCoreDecls0, effectiveModules0) =
    match modules0
      [(_, prog)] =>
        if programIsCore prog then
          (None, [], [("core", prog)])
        else
          (preludeKey, coreDecls0, modules0)
      _ => (preludeKey, coreDecls0, modules0)
  let g =
    driveGraphK
      GOutDiags
      (driveArgs
        inputs
        valueMain
        effectivePreludeKey
        runtimeDecls
        effectiveCoreDecls0
        effectiveModules0)
  ((g.gdReport, g.gdOutputs), g.gdGraph)

-- render the entry report: type errors win (each `TYPE ERROR: …`), else the
-- entry's `name : scheme` lines followed by its non-exhaustive-match warnings.
-- The harness sorts, so scheme/warn relative order is not load-bearing.  Mirrors
-- runCheck's single-file shape, but over the entry module of a resolved graph.
export
checkModulesEntryReport : DriveInputs ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  String
checkModulesEntryReport inputs runtimeDecls coreDecls modules =
  fst (checkModulesEntryReportOut inputs runtimeDecls coreDecls modules)

-- `checkModulesEntryReport` beside the outputs of its drive.
checkModulesEntryReportOut : DriveInputs ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  (String, DriveOutputs)
checkModulesEntryReportOut inputs runtimeDecls coreDecls modules =
  let (report, outputs) =
    checkModulesEntryFullReportK
      inputs
      False
      None
      runtimeDecls
      coreDecls
      modules
  let (_, schemes, errs, warns) = entrySplit report
  match errs
    [] => (joinNl (schemeLines schemes ++ map tcMsg warns), outputs)
    _ => (joinNl (typeErrorLines (map tcMsg errs)), outputs)

-- exit-code predicate analog of checkHasErrors: any type error in ANY module of
-- the resolved graph (entry or imported — see checkModulesEntryFromDiags).
checkModulesEntryHasErrors : DriveInputs ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  Bool
checkModulesEntryHasErrors inputs runtimeDecls coreDecls modules =
  let (_, errs, _) = checkModulesEntryFull inputs runtimeDecls coreDecls modules
  match errs
    [] => False
    _ => True

-- ── ONE-MODULE Module-arm wrapper (S-check-one-wrapper, E-1 #1115) ─────────
-- The scheme/diagnostic-tree analogue of `elaborateOne` (above): runs a SINGLE
-- program through the `Module` arm as a degenerate one-entry module list, the
-- same way `elaborateOne` runs it through `elaborateModules`.  `checkModulesEntryFull`
-- is the entry-report projection of the one whole-graph driver (see the file header
-- and `driveGraphK`) — it therefore performs BOTH halves of the
-- two-part safety property a standalone `Module`-arm caller must uphold
-- (`mintGraphCtx` and the unconditional `mangledFunDefsPresentRef`/
-- `declEnvsRef` overwrites, the last carrying the method and constructor export
-- indices — see `checkModuleFullDiags`'s header comment just above its `export`).
-- Delegating to it (rather than hand-assembling a bare `checkModuleFullDiags` call
-- with an invented module id / degenerate accData/implDecls) gets that property for
-- free and needs no "empty module id" convention of its own — `foldModules`'s own
-- singleton-list clause (`[(mid, prog)]`) already IS the degenerate one-entry case,
-- run through the identical preamble every N-module call gets.  `rootId` names the
-- program's own module id (analogous to `elaborateOne`'s `rootId`); `checkModulesEntryFull`
-- has previously only been reached with 2+-module graphs (`checkModulesEntryReport`/
-- `checkModulesEntryHasErrors`, both import-bearing-only per its own header comment) —
-- this is its first 1-module caller.
export
checkOneScheme : DriveInputs ->
  List Decl ->
  List Decl ->
  (String, List Decl) ->
  List (String, Scheme)
checkOneScheme inputs runtimeDecls coreDecls (rootId, prog) =
  let (schemes, _, _) =
    checkModulesEntryFull inputs runtimeDecls coreDecls [(rootId, prog)]
  pubSchemes schemes

-- FULL-ENVIRONMENT sibling of `checkOneScheme` (S-full-env-scheme-entry, #1116),
-- `checkOneSchemeFullK`:
-- `(preludeSchemes, ownSchemes)` for a ONE-MODULE program, the Module-arm
-- replacement for the retired single-program environment that the
-- introspection consumers (LSP hover/completion/inlayHint, the playground's
-- hover/complete query, `check-policy --fn <name>`) need: they look names up by
-- BARE NAME with no idea whether the name is the user's or the prelude's, so
-- `checkOneScheme`'s terminal-module-own-only answer is not enough for them.
--
-- The two halves are handed back SEPARATE, not pre-concatenated, so the caller
-- states the precedence it wants explicitly.  Every current consumer wants
-- `own ++ prelude` (first match wins ⇒ a user redefinition shadows the prelude's
-- binding of the same name) — see `checkModulesEntryFullSplitK`'s note.  This
-- is NOT a widening of the `medaka check` front door, whose narrowed
-- own-schemes-only report is deliberate and unchanged.
--
-- The prelude key is for the prelude interface (see
-- `checkCoreMemoized`): pass `Some (desugaredPreludeKey runtimeSrc,
-- desugaredPreludeKey coreSrc)` when `runtimeDecls`/`coreDecls` are exactly what
-- `desugaredPrelude` returned for those sources; `None` otherwise.
export
checkOneSchemeFullK : DriveInputs ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  (String, List Decl) ->
  (List (String, PubScheme), List (String, PubScheme))
checkOneSchemeFullK inputs preludeKey runtimeDecls coreDecls prog =
  fst
    (checkOneSchemeFullKGraph
      (driveArgs inputs False preludeKey runtimeDecls coreDecls [prog]))

-- `checkOneSchemeFullK` beside the graph record its drive ends in, for a test that
-- observes that record after the drive.
export
checkOneSchemeFullKGraph : DriveArgs ->
  ((List (String, PubScheme), List (String, PubScheme)), GraphCtx)
checkOneSchemeFullKGraph args =
  let (report, gctx) = checkOneReportKGraph args
  let (coreSchemes, schemes, _, _) = entrySplit report
  ((coreSchemes, schemes), gctx)

-- diagnostics-returning sibling of `checkOneScheme`, matching the former wrapper's
-- return shape (`(errs, warns)`) exactly, so a call site can swap targets with no
-- shape change (this slice's own acceptance bar — see the packet).
export
checkOneDiags : DriveInputs ->
  List Decl ->
  List Decl ->
  (String, List Decl) ->
  (List TcDiag, List TcDiag)
checkOneDiags inputs runtimeDecls coreDecls prog =
  checkOneDiagsK inputs False None runtimeDecls coreDecls prog

-- `checkOneDiags` beside the graph record its drive ends in, for a test that observes
-- that record after the drive.
export
checkOneDiagsGraph : DriveArgs -> ((List TcDiag, List TcDiag), GraphCtx)
checkOneDiagsGraph args =
  let (report, gctx) = checkOneReportKGraph args
  let (_, _, errs, warns) = entrySplit report
  ((errs, warns), gctx)

-- `checkOneDiags` with the prelude key for the prelude interface — same contract as
-- `checkOneSchemeFullK` — and the caller's value-main candidate (`autoPrintWanted`).
checkOneDiagsK : DriveInputs ->
  Bool ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  (String, List Decl) ->
  (List TcDiag, List TcDiag)
checkOneDiagsK inputs valueMain preludeKey runtimeDecls coreDecls prog =
  let (_, _, errs, warns) =
    entrySplit
      (checkOneReportK inputs valueMain preludeKey runtimeDecls coreDecls prog)
  (errs, warns)

-- The report-returning sibling of both `checkOneSchemeFullK` and `checkOneDiagsK`:
-- the one-module drive's whole report, which each of them projects.
export
checkOneReportK : DriveInputs ->
  Bool ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  (String, List Decl) ->
  TcReport
checkOneReportK inputs valueMain preludeKey runtimeDecls coreDecls prog =
  fst
    (checkOneReportKGraph
      (driveArgs inputs valueMain preludeKey runtimeDecls coreDecls [prog]))

-- `checkOneReportK` beside the graph record its drive ends in.
checkOneReportKGraph : DriveArgs -> (TcReport, GraphCtx)
checkOneReportKGraph args =
  let ((report, _), gctx) = checkModulesEntryFullReportKGraph args
  (report, gctx)

-- Thin ONE-MODULE String/Bool wrappers of the (runtimeDecls, coreProg, userProg) shape,
-- called by `compiler/tools/snapshot.mdk` and `compiler/tools/check.mdk`, so the call sites
-- swap targets with no shape change.  They delegate to the
-- entry-report/-hasErrors functions above over a singleton module list rather than
-- duplicating the rendering (`joinNl (schemeLines ++ warns)` on success,
-- `typeErrorLines` on error).  `"__user__"` mirrors `elaborateOne`'s own
-- rootId convention for a bare/no-import file (`entry_support.mdk`).
export
checkOneToLinesWithRuntime : DriveInputs ->
  List Decl ->
  List Decl ->
  List Decl ->
  (String, DriveOutputs)
checkOneToLinesWithRuntime inputs runtimeDecls coreProg userProg = checkModulesEntryReportOut
  inputs
  runtimeDecls
  coreProg
  [("__user__", userProg)]

-- `checkOneToLinesWithRuntime` with the prelude key for the prelude interface (see
-- `checkCoreMemoized`): same contract as `checkOneSchemeFullK`.  Same render as
-- `checkModulesEntryReport`, over the keyed driver.
export
checkOneToLinesWithRuntimeK : DriveInputs ->
  Option (Int, Int) ->
  List Decl ->
  List Decl ->
  List Decl ->
  String
checkOneToLinesWithRuntimeK inputs preludeKey runtimeDecls coreProg userProg =
  let (schemes, errs, warns) = checkModulesEntryFullK
    inputs
    preludeKey
    runtimeDecls
    coreProg
    [("__user__", userProg)]
  match errs
    [] => joinNl (schemeLines schemes ++ map tcMsg warns)
    _ => joinNl (typeErrorLines (map tcMsg errs))

export
checkOneToLines : DriveInputs -> List Decl -> String
checkOneToLines inputs userProg =
  fst (checkOneToLinesWithRuntime inputs [] [] userProg)

export
checkOneErrorsWithRuntime : DriveInputs ->
  List Decl ->
  List Decl ->
  List Decl ->
  Bool
checkOneErrorsWithRuntime inputs runtimeDecls coreProg userProg = checkModulesEntryHasErrors
  inputs
  runtimeDecls
  coreProg
  [("__user__", userProg)]

-- One-module match-report wrapper: the type-aware
-- non-exhaustive-match report for ONE module, runtime externs seeded and NO
-- prelude, rendered as one `Warning: non-exhaustive match …` line per warning.
--
-- WARNINGS ONLY — type errors are dropped on the floor rather than rendered, which
-- is this report's contract, not an oversight: the caller
-- (`compiler/entries/check_match_main.mdk`) compares match warnings and nothing else.
-- `checkOneDiags` is the wrapper this delegates to precisely because it hands the
-- two halves back SEPARATE, so the split needs no new projection.
--
-- The empty `coreDecls` is what makes the seed identical to the `Flat` wrapper's
-- hand-built `externSchemes (runtimeExternTyOriginScope []) runtimeDecls`: `graphPreamble`
-- computes `externSchemes (runtimeExternTyOriginScope coreDecls) runtimeDecls`, which
-- collapses to the same expression at `coreDecls = []`.  `"__user__"` mirrors
-- `checkOneToLinesWithRuntime`'s rootId convention just above.
export
checkOneMatchToLines : DriveInputs -> List Decl -> List Decl -> String
checkOneMatchToLines inputs runtimeDecls prog =
  let (_, warns) = checkOneDiags inputs runtimeDecls [] ("__user__", prog)
  joinNl (map tcMsg warns)

-- run the multi-module front-end and render the ENTRY module's own bindings as
-- `name : scheme` per line (the harness sorts) — diffs vs dev/tc_module_probe.
export
checkModulesEntryLines : DriveInputs ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  String
checkModulesEntryLines inputs runtimeDecls coreDecls modules =
  joinNl
    (schemeLines
      (publishedEntrySchemes
        (checkModules inputs runtimeDecls coreDecls modules)))

-- Emit EVERY module's bindings in one pass, each section preceded by a
-- `## MODULE <mid>` marker line.  A single full-closure run can then cover many
-- modules at once (the batch harness splits on the marker and diffs each
-- section vs its per-module oracle).  Scheme of a module depends only on its
-- dependency-closure (which precedes it in topo order), so a module's section
-- is identical whether checked alone or inside a larger union closure.
export
checkModulesAllLines : DriveInputs ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  String
checkModulesAllLines inputs runtimeDecls coreDecls modules =
  joinNl (allModuleLines (checkModules inputs runtimeDecls coreDecls modules))

allModuleLines : List (String, List (String, PubScheme)) -> List String
allModuleLines [] = []
allModuleLines ((mid, ss) :: rest) =
  "## MODULE " ++ mid :: schemeLines ss ++ allModuleLines rest

-- The multi-module analog of `elaborate`: the composition of `checkModules`
-- (per-module-frame typecheck, dependency-first) and the EMethodAt route-
-- stamping `elaborate` does single-module.  prePasses the prelude + every module
-- (rewriting return-position method occurrences to EMethodAt over the WHOLE
-- program's RP method set), typechecks each module in dependency order (seeded
-- like checkModules), and STAMPS each module's route refs from its now-resolved
-- result types.  Returns the SAME trees (refs filled) so evalModulesWith can route
-- return-position dispatch (`pure`/`andThen` — the Parser monad) by RKey instead
-- of the untyped arg-tag fallback.  RKey-only (dictNames = []): the bootstrap
-- source uses no `=>`-constrained user polymorphism, so no EDictAt / dict params
-- and no pendingDictApps / pendingRecDictApps to resolve.  Return shape: `ElabResult`.
export
elaborateModules : DriveInputs ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  ElabResult
-- E4: D3b's ARG-position dict-passing per module runs inside the drive
-- (`dictPassModulesIfEnabled`), on every path (single elaboration mode, #157).
--
-- Impl-body inference runs on every driver, so a standalone-shadow method call
-- INSIDE an impl body (map's `Debug`/`Eq`/`Ord`/`Display (Map k v)` bodies all call
-- standalone `toList m`) RECORDS its RLocal site (recordRLocalSite -> the goal
-- channel) for resolveRLocalSites to stamp.  Without it the impl-body `toList` route
-- stays at its default RNone -> eval arg-tag-dispatches a Map through the
-- no-matching-tag `keepOrAll` fallback to Foldable List's `toList = identity` ->
-- returns the Map unchanged -> `debug`/`display` recurse forever (SIGBUS on
-- `medaka test stdlib/map.mdk`).
--
-- #2705: what distinguishes this projection from the diagnostics one is no longer
-- WHAT is solved — the same driver, the same preamble, the same worker, the same
-- graph-end drain — but that `GOutTrees` sets the promotion-eligible set (so its
-- groups PROMOTE and their call sites are marked as dict applications), publishes
-- the evidence table and dict-passes the marked trees, and that it returns the
-- diagnostics the drive raised as its residual.
elaborateModules inputs runtimeDecls coreDecls0 modulesIn =
  match (elaborateModulesWithSchemes
    inputs
    False
    runtimeDecls
    coreDecls0
    modulesIn)
    (result, _, _) => result

-- `elaborateModules` beside the graph record its drive ends in, for a test that
-- observes that record after the drive.
export
elaborateModulesGraph : DriveArgs -> (ElabResult, GraphCtx)
elaborateModulesGraph args =
  let ((result, _, _), gctx) = elabTreesDrive args
  (result, gctx)

-- `elaborateModules` together with the prelude's schemes and the entry module's own
-- schemes, from the SAME drive: a verb that both reads types and evaluates the
-- elaborated program (`check-policy`) typechecks once.  `valueMain` is the caller's
-- value-main candidate (`autoPrintWanted`).
export
elaborateModulesWithSchemes : DriveInputs ->
  Bool ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  (ElabResult, List (String, PubScheme), List (String, PubScheme))
elaborateModulesWithSchemes inputs valueMain runtimeDecls coreDecls0 modulesIn =
  let (result, r, _) =
    elaborateModulesWithReport
      inputs
      valueMain
      None
      runtimeDecls
      coreDecls0
      modulesIn
  let (core, entrySchemes, _, _) = entrySplit r
  (result, core, entrySchemes)

-- `elaborateModulesWithSchemes` returning its drive's whole report and outputs
-- beside the elaboration.  `executes` names the `async` driver of a caller that runs or
-- emits the trees: its checked program then carries the auto-print evidence.
export
elaborateModulesWithReport : DriveInputs ->
  Bool ->
  Option String ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  (ElabResult, TcReport, DriveOutputs)
elaborateModulesWithReport inputs valueMain executes runtimeDecls coreDecls0 modulesIn =
  fst
    (elabTreesDrive
      (DriveArgs
        inputs
        valueMain
        executes
        None
        None
        runtimeDecls
        coreDecls0
        modulesIn))

-- `elaborateModulesWithReport` keyed as `checkModulesChainReportFor` is: under the
-- prelude generation pair and [chainKey], with one source key per module in
-- [stepKeys], each module before the entry that is unchanged since it was recorded
-- is served from its recorded trees, and each module the drive checks records them.
export
elaborateModulesChainReport : DriveInputs ->
  Bool ->
  (Int, Int) ->
  String ->
  List (Option String) ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  (ElabResult, TcReport, DriveOutputs)
elaborateModulesChainReport inputs valueMain (rk, ck) chainKey stepKeys runtimeDecls coreDecls0 modulesIn =
  fst
    (elabTreesDrive
      (DriveArgs
        inputs
        valueMain
        None
        None
        (Some (chainFullKey rk ck chainKey, stepKeys))
        runtimeDecls
        coreDecls0
        modulesIn))

-- The tree-producing drive of [args], as `elaborateModules` projects it.
elabTreesDrive : DriveArgs -> ((ElabResult, TcReport, DriveOutputs), GraphCtx)
elabTreesDrive args = elabDriveResult (driveGraphK GOutTrees args)

elabDriveResult : GraphDrive -> ((ElabResult, TcReport, DriveOutputs), GraphCtx)
elabDriveResult g = (
  (
    ElabResult {
      erCore = g.gdCore,
      erModules = g.gdModules,
      erPerModule = map dropModSchemes g.gdPerMod,
      erResidual = g.gdResidual,
      erEvidence = g.gdEvTable,
      erDispositions = g.gdDispositions,
      erFacts = ElabFacts {
        efManifests = g.gdOutputs.doManifests,
        efBinders = g.gdBinders,
        efEntryOutcome = g.gdOutputs.doEntryOutcome,
      },
    },
    g.gdReport,
    g.gdOutputs,
  ),
  g.gdGraph,
)

-- The report of `elaborateModules`' drive, for a test that reads it.
export
elaborateModulesReport : DriveInputs ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  TcReport
elaborateModulesReport inputs runtimeDecls coreDecls0 modulesIn =
  match (elaborateModulesWithReport
    inputs
    False
    None
    runtimeDecls
    coreDecls0
    modulesIn)
    (_, report, _) => report
-- #2548 (ARCH M3/Q2, DICT §6.2 T4): ONE ordered resolve pass over the whole graph,
-- at quiescence.  Every module's goals are stamped after every module has been
-- inferred, so a goal in an early module is decided against the final solution
-- rather than against the solution as it stood when that module closed.
--
-- The per-module context is REPLAYED, not re-derived (see `StampCtx`), and restored
-- afterwards so `dictPassModulesIfEnabled` — which runs next — sees the state the
-- last module left, exactly as it does today.
-- Each drain verdict joins the errors of the module it belongs to, and each hole
-- does unless that module then has errors: a hole beside a type error is usually its
-- consequence.  A live finding is dropped when any module of [perMod] has errors,
-- since the live root it rests on may be one an erroneous importer grounded or left
-- open.  A finding in no module of [perMod] is a module the drive has no list for,
-- which only the prelude is.
attachDrainFindings : List DrainFinding -> List ModDiags -> List ModDiags
attachDrainFindings [] perMod = perMod
attachDrainFindings findings perMod =
  let orphans =
    filterList (f => not (anyList (pm => fst pm == f.dfModule) perMod)) findings
  match orphans
    [] => ()
    f :: _ =>
      panic
        "evidence hole in module `\{f.dfModule}`, which has no diagnostics list: \{tcMsg f.dfDiag}"
  let erred = anyList (pm => isNonEmptyL (modDiagErrs pm)) perMod
  let kept = if erred then filterList (f => not f.dfLive) findings else findings
  map (pm => findingsOnto kept pm) perMod

modDiagErrs : ModDiags -> List TcDiag
modDiagErrs (_, (_, errs, _)) = errs

findingsOnto : List DrainFinding -> ModDiags -> ModDiags
findingsOnto findings (mid, (schemes, errs, warns)) =
  let mine = filterList (f => f.dfModule == mid) findings
  let verdicts = map (f => f.dfDiag) (filterList (f => f.dfVerdict) mine)
  match errs ++ verdicts
    [] => (mid, (schemes, map (f => f.dfDiag) mine, warns))
    all => (mid, (schemes, all, warns))

-- Writes `mangledShadowMapRef`, `argDispatchIdxByIdRef` and `markSetsRef` as a side
-- effect: the first two are read by the inference of a marked tree (P0-18 shadow
-- recovery, `argDispatchOf`), the third by `checkBodyImpl`, which marks each module's
-- groups on the schedule — so the driver that marks must be the driver that sets
-- them.  Empty / index-only on the un-mangled check path, exactly as the emit path
-- derives them.  `markSetsOf` below is the function; unkeyed, its prelude half is
-- `preludeMarkFactsOf coreDecls`.

preludeMarkFactsOf : List Decl -> PreludeMarkFacts
preludeMarkFactsOf coreDecls = PreludeMarkFacts {
  pmfReturnPos = returnPosMethodNames coreDecls,
  pmfMethodConstraints = methodConstraintNames coreDecls,
  pmfArgDispatch = argDispatchIndices coreDecls,
  pmfArgDispatchById = argDispatchIndicesById coreDecls,
  pmfConstrainedNames = constrainedSigNames coreDecls,
}

export
schemeLines : List (String, PubScheme) -> List String
schemeLines [] = []
schemeLines ((n, p) :: rest) = "\{n} : \{ppPubScheme p}" :: schemeLines rest
# DESUGAR
(DUse false (UseGroup ("types" "invocation_basis") ((mem "readInvocationView" false) (mem "requestedWrapperViewModules" false) (mem "invocationResolver" false) (mem "slotVariances" false) (mem "ctorsByHead" false) (mem "paramPolaritiesIn" false) (mem "frozenInvocationOps" false) (mem "completionInvocationViews" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Ns" true) (mem "DataVis" true) (mem "implMethodName" false) (mem "Ty" true) (mem "EffParamTy" true) (mem "TyConOrigin" true) (mem "Ident" true) (mem "EvId" true) (mem "EvVal" true) (mem "EvEntry" true) (mem "Pat" true) (mem "Expr" true) (mem "Loc" true) (mem "Decl" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberOrigin" false) (mem "useMemberAlias" false) (mem "qualifiedLocal" false) (mem "TabKey" true) (mem "lookupTab" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Tyvar" true) (mem "normalize" false) (mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "VecObl" true) (mem "spineParts" false))))
(DUse false (UseGroup ("types" "effect_param_decode") ((mem "dtopIn" false) (mem "writtenParam" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "builtinLabel" false) (mem "atomWith" false) (mem "pureRow" false))))
(DUse false (UseAlias ("types" "effect_solver") "EffectSolver"))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "InvocationOps" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "StandaloneOrigin" true) (mem "SiteKind" true) (mem "ServeStep" true) (mem "Provenance" true) (mem "NumBoundaryDisposition" true) (mem "GoalPayload" true) (mem "DeclaringBinder" true) (mem "Accumulate" true) (mem "ModulePlace" true) (mem "FoldPlan" true) (mem "siteFor" false) (mem "DeclEnvModule" true) (mem "DeclEnvs" true) (mem "ImplRow" true) (mem "ImplEnv" true) (mem "ClassEnv" true) (mem "GraphCtx" true) (mem "TcConfig" true) (mem "DriveInputs" true) (mem "DriveArgs" true) (mem "DriveOutputs" true) (mem "withPublishedManifests" false) (mem "manifestDriverFor" false) (mem "Predicate" true) (mem "GraphRun" true) (mem "ModuleCtx" true) (mem "InvocationView" true) (mem "ModuleBindings" true) (mem "ExportBinding" true) (mem "ModuleSeed" true) (mem "PreludePreamble" true) (mem "GraphOut" true) (mem "ModuleServe" true) (mem "GraphDrive" true) (mem "GraphPreamble" true) (mem "ElabResult" true) (mem "ElabFacts" true) (mem "DrainFinding" true) (mem "MarkSets" true) (mem "PreludeMarkFacts" true))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse true (UseGroup ("types" "publish") ((mem "TcDiag" true) (mem "tcCode" false) (mem "tcMsg" false) (mem "ModDiags" false) (mem "pubSchemes" false))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "tcLoc" false) (mem "TcReport" false) (mem "PartialAnalysis" false) (mem "EntryTables" true) (mem "noEntryTables" false) (mem "partialAnalysis" false) (mem "freezePub" false) (mem "freezeRows" false) (mem "freezeModDiags" false) (mem "graphReportWithOutcome" false) (mem "publishSelected" false) (mem "publishCore" false) (mem "publishWithContexts" false) (mem "publishedCore" false) (mem "publishedEntrySchemes" false) (mem "ppPubScheme" false))))
(DUse false (UseGroup ("types" "entry_outcome") ((mem "mainUseDiags" false) (mem "printlnIface" false) (mem "mainBodySpan" false) (mem "driveOutputsNow" false) (mem "entryOutcomeNow" false) (mem "mainIsAsyncNow" false) (mem "mainAsyncPayloadIsUnitNow" false) (mem "mainIsUnitNow" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapProg" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "useModId" false) (mem "pubUsePaths" false) (mem "exportedValueNames" false) (mem "nsAbstractData" false))))
(DUse false (UseGroup ("types" "value_main") ((mem "inMainBinding" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "programIsCore" false) (mem "stampTyOrigins" false) (mem "runtimeExternTyOriginScope" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "mangledName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omFromPairs" false) (mem "omFromNames" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "take" false) (mem "last" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "lookupAssoc" false) (mem "contains" false) (mem "reverseL" false) (mem "joinWith" false) (mem "joinNl" false) (mem "filterList" false) (mem "anyList" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "dedup" false) (mem "lenKey" false) (mem "sortUniqS" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "identKey" false) (mem "regKeyOfTab" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "typeTagOf" false) (mem "implRouteKeyWord" false) (mem "ifaceWordOf" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "InstId" true) (mem "MethodDisposition" true) (mem "DispositionTable" false) (mem "InstanceShape" true) (mem "buildDispositionTableWithShapes" false) (mem "validateDispositionTable" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "hostLabels" false) (mem "ioJoinGrants" false) (mem "profileName" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "RuntimeType" true))))
(DUse false (UseGroup ("types" "program_facts") ((mem "ProgramFacts" false) (mem "factsOfElab" false))))
(DUse false (UseGroup ("types" "serve_policy") ((mem "ServeOps" true) (mem "serveStateOf" false) (mem "diagsServe" false) (mem "treeServe" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "PreludeInterface" false) (mem "freezeInterface" false) (mem "thawInterface" false) (mem "seedPreludeInterface" false) (mem "preludeCacheHit" false))))
(DUse false (UseGroup ("types" "prelude_elab") ((mem "PreludeElab" true) (mem "heldPreludeEvCounter" false) (mem "preludeElabFor" false) (mem "withShippedRows" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "anyMember" false) (mem "dedupI" false) (mem "headTyconMono" false) (mem "instantiateFields" false) (mem "invocationHeadKey" false) (mem "monoUnboundIds" false) (mem "substMono" false) (mem "tconBuiltin" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "builtinCtors" false) (mem "callUOblsWindow" false) (mem "checkRunResidue" false) (mem "currentScopeStore" false) (mem "emptyDataEnv" false) (mem "freshGraphRun" false) (mem "graphLineageRun" false) (mem "initialGraphCtx" false) (mem "initialModuleCtx" false) (mem "interners" false) (mem "internersOf" false) (mem "mctxAt" false) (mem "mintGraphCtx" false) (mem "noteHighWater" false) (mem "noteInterners" false) (mem "raiseToHighWater" false) (mem "wMark" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "aliasOwnAt" false) (mem "aliasUniverseAt" false) (mem "boundNames" false) (mem "ceLookupAt" false) (mem "ceRowMethodNames" false) (mem "ceRowRequired" false) (mem "declEnvModule" false) (mem "emptyDeclEnvAcc" false) (mem "funDefs" false) (mem "graphPubDefiners" false) (mem "ieRowInst" false) (mem "ieRowMethodNames" false) (mem "ieRowOrd" false) (mem "ieRowsAll" false) (mem "ieRowTriple" false) (mem "ifaceMethodNames" false) (mem "ifaceTabKey" false) (mem "importedBindings" false) (mem "instRefMid" false) (mem "instRefSeq" false) (mem "methodExportsIndex" false) (mem "namesToSet" false) (mem "ordOfIndex" false) (mem "publicDataDecls" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "prependConflict" false) (mem "prependIncomparable" false) (mem "dropAmbiguity" false) (mem "stickyDiagsInPushOrder" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "aliasRowSpelling" false) (mem "importFormRows" false) (mem "memberAliasCands" false) (mem "moduleAliasKeys" false) (mem "useKeyCands" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "ambiguousImportTyvarId" false) (mem "enterLevel" false) (mem "exitLevel" false) (mem "freshVar" false) (mem "instantiateTracked" false) (mem "lookupSchemeObls" false) (mem "recordObl" false) (mem "recordSchemeCallObligations" false) (mem "unify" false) (mem "closeScope" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "populateEffectDomainsGraph" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "buildDeclEnvs" false) (mem "dataEnvFromDeclsGo" false) (mem "declEnvAccOf" false) (mem "declEnvModulesFrom" false) (mem "pubTopFnNames" false) (mem "stampGraphDecls" false) (mem "withDeclParamKinds" false))))
(DUse false (UseGroup ("types" "tc_foreign") ((mem "directExternSigs" false) (mem "externDecls" false) (mem "externSigsToMap" false) (mem "ffiExternTypeRowsWith" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "directSuperGoals" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "goalsMark" false) (mem "openScope" false) (mem "returnPosMethodNames" false) (mem "routesOfMonosTopV" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "checkCallObligationsU" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "grantOrder" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "argDispatchIndices" false) (mem "argDispatchIndicesById" false) (mem "constrainedSigNames" false) (mem "markDictNames" false) (mem "markSetsOf" false) (mem "methodConstraintNames" false))))
(DUse false (UseGroup ("types" "tc_groups") ((mem "allEVars" false))))
(DUse false (UseGroup ("types" "tc_elab") ((mem "dictPassModulesIfEnabled" false) (mem "drivenEvidence" false))))
(DUse false (UseGroup ("types" "tc_global") ((mem "globalCoherenceConflict" false))))
(DUse false (UseGroup ("types" "tc_module") ((mem "captureTypeErrors" false) (mem "checkBodyImpl" false) (mem "checkGraphFinish" false) (mem "checkModuleFull" false) (mem "checkModuleFullDiags" false) (mem "drainStampQueue" false) (mem "elabModuleStamp" false) (mem "externSchemesGo" false) (mem "settleClosedBody" false) (mem "verdictFinding" false))))
(DTypeSig true "ioJoinAtoms" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "ioJoinAtoms" ((PVar "domains") (PVar "grants")) (EApp (EApp (EVar "filterMap") (ELam ((PVar "l")) (EApp (EApp (EVar "map") (ELam ((PVar "granted")) (EApp (EApp (EVar "atomWith") (EApp (EVar "builtinLabel") (EVar "l"))) (EApp (EApp (EVar "writtenParam") (EApp (EApp (EVar "dtopIn") (EVar "domains")) (EApp (EVar "builtinLabel") (EVar "l")))) (EVar "granted"))))) (EApp (EApp (EVar "lookupAssoc") (EVar "l")) (EVar "grants"))))) (EVar "hostLabels")))
(DTypeSig false "collectAbstractRecordTypes" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectAbstractRecordTypes" ((PVar "decls")) (EApp (EApp (EVar "flatMap") (EFieldAccess (EVar "nsAbstractData") "nsDirectOf")) (EVar "decls")))
(DTypeSig false "seedAbstractRecordTypes" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Unit")))))
(DFunDef false "seedAbstractRecordTypes" ((PVar "gctx") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "abstracts") (EBinOp "++" (EApp (EVar "collectAbstractRecordTypes") (EVar "coreDecls")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EApp (EApp (EVar "abstractTypeWords") (EApp (EVar "fst") (EVar "m"))) (EApp (EVar "snd") (EVar "m"))))) (EVar "modules")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "abstractRecordTypesRef")) (EApp (EApp (EVar "namesToSet") (EVar "abstracts")) (EVar "omEmpty"))))))
(DTypeSig false "abstractTypeWords" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "abstractTypeWords" ((PVar "mid") (PVar "decls")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EVar "typeTagOf") (EApp (EVar "OriginModule") (EVar "mid"))) (EVar "n")))) (EApp (EVar "collectAbstractRecordTypes") (EVar "decls"))))
(DTypeSig true "stickyTypeErrorDiags" (TyFun (TyCon "DriveOutputs") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))))
(DFunDef false "stickyTypeErrorDiags" ((PVar "o")) (EApp (EVar "stickyDiagsInPushOrder") (EFieldAccess (EVar "o") "doStickyDiags")))
(DTypeSig true "hadTypeErrors" (TyFun (TyCon "DriveOutputs") (TyCon "Bool")))
(DFunDef false "hadTypeErrors" ((PVar "o")) (EFieldAccess (EVar "o") "doHadTypeErrors"))
(DTypeSig false "mainHasObligations" (TyFun (TyCon "ModuleCtx") (TyCon "Bool")))
(DFunDef false "mainHasObligations" ((PVar "mctx")) (EBlock (DoLet false false (PVar "id") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (ELit (LString "main"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeDefIdsRef") "value")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "lookupSchemeObls") (ELit (LString "main"))) (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value")) (arm (PCon "Some" (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False"))))))
(DTypeSig true "hadMatchWarnings" (TyFun (TyCon "DriveOutputs") (TyCon "Bool")))
(DFunDef false "hadMatchWarnings" ((PVar "o")) (EFieldAccess (EVar "o") "doHadMatchWarnings"))
(DTypeSig true "defaultDriveInputs" (TyCon "DriveInputs"))
(DFunDef false "defaultDriveInputs" () (ERecordCreate "DriveInputs" ((fa "diExecutedMainDriver" (EVar "None")) (fa "diManifestRequests" (EListLit)) (fa "diStdlibOwned" (EVar "omEmpty")) (fa "diFlatEntryIsStdlib" (EVar "False")) (fa "diTrace" (EVar "None")) (fa "diIoJoinGrants" (EApp (EVar "ioJoinGrants") (EVar "None"))) (fa "diProfileName" (ELit (LString ""))) (fa "diPreludeKey" (EVar "None")))))
(DTypeSig true "driveInputsFor" (TyFun (TyApp (TyCon "Option") (TyCon "TargetProfile")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "DriveInputs")))))
(DFunDef false "driveInputsFor" ((PVar "profile") (PVar "flatEntry") (PVar "mods")) (ERecordUpdate (EVar "defaultDriveInputs") ((fa "diStdlibOwned" (EApp (EApp (EVar "namesToSet") (EVar "mods")) (EVar "omEmpty"))) (fa "diFlatEntryIsStdlib" (EVar "flatEntry")) (fa "diIoJoinGrants" (EApp (EVar "ioJoinGrants") (EVar "profile"))) (fa "diProfileName" (EMatch (EVar "profile") (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "profileName") (EVar "p"))))))))
(DTypeSig false "lastInvocationOps" (TyFun (TyCon "DriveOutputs") (TyCon "InvocationOps")))
(DFunDef false "lastInvocationOps" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "doInvocationView") (arm (PCon "InvocationView" (PVar "ctors") (PVar "pols") (PVar "kinds")) () (EBlock (DoLet false false (PVar "byHead") (EApp (EApp (EVar "ctorsByHead") (EVar "invocationHeadKey")) (EVar "ctors"))) (DoLet false false (PVar "gctx") (EApp (EApp (EVar "initialGraphCtx") (EVar "builtinCtors")) (EApp (EVar "freshGraphRun") (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "effvarCounter")) (EFieldAccess (EVar "o") "doEffvarNext"))) (DoExpr (ERecordCreate "InvocationOps" ((fa "headVariances" (ELam ((PVar "h")) (EMatch (EApp (EVar "headTyconMono") (EVar "h")) (arm (PCon "Some" (PCon "HkDecl" (PVar "key"))) () (EApp (EApp (EVar "slotVariances") (EApp (EApp (EVar "paramPolaritiesIn") (EVar "pols")) (EVar "key"))) (EApp (EApp (EVar "lookupTab") (EVar "key")) (EVar "kinds")))) (arm PWild () (EVar "None"))))) (fa "appliedFields" (ELam ((PVar "applied")) (EBlock (DoLet false false (PTuple (PVar "h") (PVar "args")) (EApp (EVar "spineParts") (EVar "applied"))) (DoExpr (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EApp (EApp (EApp (EVar "instantiateFields") (EVar "gctx")) (EVar "args")) (EVar "c")))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EVar "invocationHeadKey") (EVar "h"))) (EVar "byHead")))))))) (fa "headKey" (EVar "invocationHeadKey")))))))))
(DTypeSig false "ownContext" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl")))))
(DFunDef false "ownContext" ((PVar "mctx") (PVar "n")) (EBlock (DoLet false false (PVar "id") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeDefIdsRef") "value")))) (DoExpr (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EApp (EVar "lookupSchemeObls") (EVar "n")) (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value"))))))
(DTypeSig false "publishOwn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))
(DFunDef false "publishOwn" ((PVar "mctx")) (EApp (EVar "publishWithContexts") (EApp (EVar "ownContext") (EVar "mctx"))))
(DTypeSig false "coreOwnContexts" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl")))))
(DFunDef false "coreOwnContexts" ((PVar "mctx")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (ELam ((PVar "kv")) (ETuple (EApp (EVar "fst") (EApp (EVar "fst") (EVar "kv"))) (EApp (EVar "snd") (EVar "kv"))))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value"))) (EVar "omEmpty")))
(DTypeSig false "seedContext" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl"))))))
(DFunDef false "seedContext" ((PVar "mctx") (PVar "coreContexts") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeDefIdsRef") "value")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "ownContext") (EVar "mctx")) (EVar "n"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "lookupSchemeObls") (EVar "n")) (ELit (LInt 0))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value")) (arm (PCon "Some" (PVar "obs")) () (EVar "obs")) (arm (PCon "None") () (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "coreContexts"))))))))
(DTypeSig false "captureEntryTables" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "EntryTables")))))
(DFunDef false "captureEntryTables" ((PVar "mctx") (PVar "coreContexts") (PVar "modules")) (EMatch (EApp (EVar "last") (EVar "modules")) (arm (PCon "None") () (EVar "noEntryTables")) (arm (PCon "Some" (PTuple (PVar "mid") PWild)) () (ERecordCreate "EntryTables" ((fa "etModule" (EVar "mid")) (fa "etLocals" (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "n") (PVar "loc") (PVar "s"))) (ETuple (EVar "n") (EApp (EApp (EVar "freezePub") (EVar "s")) (EApp (EApp (EVar "ownContext") (EVar "mctx")) (EVar "n"))) (EVar "loc")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "localSchemesOut") "value"))) (fa "etSeed" (EApp (EApp (EVar "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EApp (EVar "freezePub") (EApp (EVar "snd") (EVar "b"))) (EApp (EApp (EApp (EVar "seedContext") (EVar "mctx")) (EVar "coreContexts")) (EApp (EVar "fst") (EVar "b"))))))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "seedSchemesOut") "value"))))))))
(DTypeSig true "bindingGrantArity" (TyFun (TyCon "DriveOutputs") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "Int")))))
(DFunDef false "bindingGrantArity" ((PVar "o") PWild (PVar "sch")) (EIf (EFieldAccess (EVar "o") "doGrantsEnabled") (EApp (EVar "listLen") (EApp (EVar "grantOrder") (EVar "sch"))) (ELit (LInt 0))))
(DTypeSig true "elaborateOne" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "elaborateOne" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "prog")) (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "elaborateOneFacts") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "prog"))))
(DTypeSig true "elaborateOneFacts" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ProgramFacts")))))))
(DFunDef false "elaborateOneFacts" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EBlock (DoLet false false (PVar "elab") (EApp (EApp (EApp (EApp (EVar "elaborateModules") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog"))))) (DoLet false false (PVar "coreD") (EFieldAccess (EVar "elab") "erCore")) (DoLet false false (PVar "modules") (EFieldAccess (EVar "elab") "erModules")) (DoExpr (ETuple (EBinOp "++" (EVar "coreD") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules"))) (EApp (EVar "factsOfElab") (EVar "elab"))))))
(DTypeSig false "setDictEligible" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "setDictEligible" ((PVar "gctx") (PVar "names")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "dictEligibleRef")) (EVar "names"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "dictEligibleSetRef")) (EApp (EApp (EVar "namesToSet") (EVar "names")) (EVar "omEmpty"))))))
(DTypeSig false "moduleUserFnNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleUserFnNames" ((PVar "modules")) (EApp (EVar "dedup") (EApp (EApp (EVar "flatMap") (ELam ((PVar "p")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "funDefs") (EApp (EVar "snd") (EVar "p")))))) (EVar "modules"))))
(DTypeSig true "preludeReturnPosDictNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "preludeReturnPosDictNames" ((PVar "preludeDecls") (PVar "allDecls")) (EBlock (DoLet false false (PVar "rpNames") (EApp (EVar "returnPosMethodNames") (EVar "allDecls"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "anyMember") (EApp (EApp (EVar "declBodyVars") (EVar "n")) (EVar "preludeDecls"))) (EVar "rpNames")))) (EApp (EVar "constrainedSigNames") (EVar "preludeDecls"))))))
(DTypeSig true "preludeArgPosDictNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "preludeArgPosDictNames" ((PVar "preludeDecls") (PVar "allDecls")) (EBlock (DoLet false false (PVar "rpSet") (EApp (EApp (EVar "preludeReturnPosDictNames") (EVar "preludeDecls")) (EVar "allDecls"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "rpSet"))))) (EApp (EVar "constrainedSigNames") (EVar "preludeDecls"))))))
(DTypeSig false "declBodyVars" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declBodyVars" ((PVar "n") (PVar "decls")) (EApp (EApp (EVar "flatMap") (EApp (EVar "declBodyVarsOf") (EVar "n"))) (EVar "decls")))
(DTypeSig false "declBodyVarsOf" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declBodyVarsOf" ((PVar "n") (PCon "DFunDef" PWild (PVar "m") PWild (PVar "body") PWild PWild)) (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EApp (EVar "allEVars") (EVar "body")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "declBodyVarsOf" (PWild PWild) (EListLit))
(DTypeSig false "externSchemes" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "externSchemes" ((PVar "mctx") (PVar "scope") (PVar "decls")) (EBlock (DoLet false false (PVar "ds") (EApp (EVar "externDecls") (EVar "decls"))) (DoExpr (EApp (EApp (EVar "noteBuiltinExternNames") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ds"))) (DoExpr (EApp (EApp (EVar "externSchemesGo") (EVar "mctx")) (EApp (EApp (EVar "stampTyOrigins") (EVar "scope")) (EVar "ds"))))))
(DTypeSig false "noteBuiltinExternNames" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "noteBuiltinExternNames" ((PVar "gctx") (PVar "ds")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "builtinExternNamesRef")) (EApp (EApp (EVar "externSigsToMap") (EVar "ds")) (EFieldAccess (EFieldAccess (EVar "gctx") "builtinExternNamesRef") "value"))))
(DTypeSig true "checkedFfiExternTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "checkedFfiExternTypeNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "denv") (EApp (EApp (EApp (EVar "dataEnvFromDeclsGo") (ELit (LInt 0))) (EVar "decls")) (EVar "emptyDataEnv"))) (DoExpr (EApp (EApp (EApp (EVar "ffiExternTypeRowsWith") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "interners") "value") "externCatalog") "value")) (EApp (EApp (EVar "aliasOwnAt") (ELit (LInt 0))) (EFieldAccess (EVar "denv") "deAliases"))) (EVar "decls")))))
(DTypeSig true "checkedFfiExternTypeNamesModules" (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "checkedFfiExternTypeNamesModules" ((PVar "o") (PVar "modules")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkedFfiExternTypeNamesModule") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "interners") "value") "externCatalog") "value")) (EVar "o"))) (EVar "modules")))
(DTypeSig false "checkedFfiExternTypeNamesModule" (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))) (TyFun (TyCon "DriveOutputs") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))))
(DFunDef false "checkedFfiExternTypeNamesModule" ((PVar "catalog") (PVar "o") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "cur") (EApp (EApp (EVar "ordOfIndex") (EVar "mid")) (EFieldAccess (EVar "o") "doOrdIndex"))) (DoLet false false (PVar "aliases") (EBinOp "++" (EApp (EApp (EVar "aliasOwnAt") (EVar "cur")) (EFieldAccess (EVar "o") "doFfiAliases")) (EApp (EApp (EVar "aliasUniverseAt") (EVar "cur")) (EFieldAccess (EVar "o") "doFfiAliases")))) (DoExpr (EApp (EApp (EApp (EVar "ffiExternTypeRowsWith") (EVar "catalog")) (EVar "aliases")) (EVar "decls")))))
(DTypeSig false "typeErrorLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "typeErrorLines" ((PList)) (EListLit))
(DFunDef false "typeErrorLines" ((PCons (PVar "e") (PVar "rest"))) (EBinOp "::" (EBinOp "++" (ELit (LString "TYPE ERROR: ")) (EVar "e")) (EApp (EVar "typeErrorLines") (EVar "rest"))))
(DTypeSig false "graphCarriesMangledFunDefs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool")))
(DFunDef false "graphCarriesMangledFunDefs" ((PList)) (EVar "False"))
(DFunDef false "graphCarriesMangledFunDefs" ((PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EIf (EApp (EApp (EVar "unitCarriesMangledFunDefs") (EVar "mid")) (EApp (EVar "funDefs") (EVar "decls"))) (EVar "True") (EApp (EVar "graphCarriesMangledFunDefs") (EVar "rest"))))
(DTypeSig false "unitCarriesMangledFunDefs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyCon "Bool"))))
(DFunDef false "unitCarriesMangledFunDefs" ((PVar "mid") (PList)) (EVar "False"))
(DFunDef false "unitCarriesMangledFunDefs" ((PVar "mid") (PCons (PTuple (PVar "n") PWild) (PVar "rest"))) (EIf (EApp (EApp (EVar "isMangledFor") (EVar "mid")) (EVar "n")) (EVar "True") (EApp (EApp (EVar "unitCarriesMangledFunDefs") (EVar "mid")) (EVar "rest"))))
(DTypeSig false "pickSchemes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))
(DFunDef false "pickSchemes" ((PList) PWild) (EListLit))
(DFunDef false "pickSchemes" ((PCons (PVar "n") (PVar "ns")) (PVar "table")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "table")) (arm (PCon "Some" (PVar "s")) () (EBinOp "::" (ETuple (EVar "n") (EVar "s")) (EApp (EApp (EVar "pickSchemes") (EVar "ns")) (EVar "table")))) (arm (PCon "None") () (EApp (EApp (EVar "pickSchemes") (EVar "ns")) (EVar "table")))))
(DTypeSig false "tagModuleExports" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))))
(DFunDef false "tagModuleExports" ((PVar "standalones") (PVar "schemes")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "name") (PVar "scheme"))) (ETuple (EVar "name") (ERecordCreate "ExportBinding" ((fa "xbScheme" (EVar "scheme")) (fa "xbStandalone" (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "standalones"))) (fa "xbExtern" (EVar "False"))))))) (EVar "schemes")))
(DTypeSig false "publicModuleExports" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))))
(DFunDef false "publicModuleExports" ((PVar "prog") (PVar "bindings")) (EBlock (DoLet false false (PVar "standalones") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "flatMap") (ELam ((PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "bindings") "mbStandaloneSchemes")) (arm (PCon "Some" (PVar "scheme")) () (EListLit (ETuple (EVar "name") (EVar "scheme")))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "pubTopFnNames") (EVar "prog")))) (EVar "omEmpty"))) (DoLet false false (PVar "externs") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "directExternSigs") (EApp (EVar "externDecls") (EVar "prog"))))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "name") (PVar "binding"))) (ETuple (EVar "name") (EVariantUpdate "ExportBinding" (EVar "binding") ((fa "xbExtern" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "externs")))))))) (EApp (EApp (EVar "tagModuleExports") (EVar "standalones")) (EApp (EApp (EVar "pickSchemes") (EApp (EVar "exportedValueNames") (EVar "prog"))) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EFieldAccess (EVar "bindings") "mbSchemes"))) (EVar "omEmpty"))))))))
(DTypeSig false "importedBindingWinners" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "ExportBinding")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))))))
(DFunDef false "importedBindingWinners" ((PVar "mctx") (PList) PWild PWild) (EListLit))
(DFunDef false "importedBindingWinners" ((PVar "mctx") (PCons (PTuple (PVar "name") (PTuple PWild (PVar "binding"))) (PVar "rest")) (PVar "seen") (PVar "ambiguous")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "importedBindingWinners") (EVar "mctx")) (EVar "rest")) (EVar "seen")) (EVar "ambiguous")) (EBlock (DoLet false false (PVar "chosen") (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "ambiguous")) (EApp (EApp (EVar "ambiguousImportBinding") (EVar "mctx")) (ELit LUnit)) (EVar "binding"))) (DoExpr (EBinOp "::" (ETuple (EVar "name") (EVar "chosen")) (EApp (EApp (EApp (EApp (EVar "importedBindingWinners") (EVar "mctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "seen"))) (EVar "ambiguous")))))))
(DTypeSig false "ambiguousImports" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyVar "a")))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "ambiguousImports" ((PVar "rows")) (EApp (EApp (EApp (EVar "ambiguousImportsGo") (EVar "rows")) (EVar "omEmpty")) (EVar "omEmpty")))
(DTypeSig false "ambiguousImportsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyVar "a")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "ambiguousImportsGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "ambiguousImportsGo" ((PCons (PTuple PWild (PTuple (PCon "None") PWild)) (PVar "rest")) (PVar "firstMid") (PVar "acc")) (EApp (EApp (EApp (EVar "ambiguousImportsGo") (EVar "rest")) (EVar "firstMid")) (EVar "acc")))
(DFunDef false "ambiguousImportsGo" ((PCons (PTuple (PVar "name") (PTuple (PCon "Some" (PVar "mid")) PWild)) (PVar "rest")) (PVar "firstMid") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "firstMid")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ambiguousImportsGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "mid")) (EVar "firstMid"))) (EVar "acc"))) (arm (PCon "Some" (PVar "seen")) () (EApp (EApp (EApp (EVar "ambiguousImportsGo") (EVar "rest")) (EVar "firstMid")) (EIf (EBinOp "==" (EVar "seen") (EVar "mid")) (EVar "acc") (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "acc")))))))
(DTypeSig false "ambiguousImportBinding" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "ExportBinding"))))
(DFunDef false "ambiguousImportBinding" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EApp (EApp (EVar "Unbound") (EVar "ambiguousImportTyvarId")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")))) (DoExpr (ERecordCreate "ExportBinding" ((fa "xbScheme" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EListLit (EVar "ambiguousImportTyvarId"))) (EListLit)) (EListLit)) (EListLit)) (EVar "pureRow")) (EApp (EVar "TVar") (EVar "cell")))) (fa "xbStandalone" (EVar "None")) (fa "xbExtern" (EVar "False")))))))
(DTypeSig false "moduleImportSeed" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "ExportBinding")))) (TyCon "ModuleSeed")))))
(DFunDef false "moduleImportSeed" ((PVar "mctx") (PVar "base") (PVar "imported")) (EBlock (DoLet false false (PVar "selected") (EApp (EApp (EApp (EApp (EVar "importedBindingWinners") (EVar "mctx")) (EVar "imported")) (EVar "omEmpty")) (EApp (EVar "ambiguousImports") (EVar "imported")))) (DoExpr (ERecordCreate "ModuleSeed" ((fa "msSchemes" (EBinOp "++" (EVar "base") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "name") (PVar "binding"))) (ETuple (EVar "name") (EFieldAccess (EVar "binding") "xbScheme")))) (EVar "selected")))) (fa "msImportedValues" (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "name") (PVar "binding"))) (EMatch (EFieldAccess (EVar "binding") "xbStandalone") (arm (PCon "Some" (PVar "scheme")) () (EListLit (ETuple (EVar "name") (EVar "scheme")))) (arm (PCon "None") () (EListLit))))) (EVar "selected"))) (EVar "omEmpty"))) (fa "msImportedNames" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "selected"))) (EVar "omEmpty"))) (fa "msImportedExterns" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "name") (PVar "binding"))) (EIf (EFieldAccess (EVar "binding") "xbExtern") (EListLit (EVar "name")) (EListLit)))) (EVar "selected"))) (EVar "omEmpty"))))))))
(DTypeSig false "aliasSchemes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "aliasSchemes" ((PVar "deps") (PVar "alias") (PVar "depSchemes")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "aliasSchemeEntry") (EVar "deps")) (EVar "alias"))) (EVar "depSchemes")))
(DTypeSig false "aliasSchemeEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyVar "a")) (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "aliasSchemeEntry" ((PVar "deps") (PVar "alias") (PTuple (PVar "k") (PVar "s"))) (EIf (EApp (EApp (EVar "isMangledExportOfAny") (EVar "deps")) (EVar "k")) (ETuple (EVar "k") (EVar "s")) (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "alias")) (EVar "k")) (EVar "s"))))
(DTypeSig false "isMangledFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isMangledFor" ((PVar "mid") (PVar "k")) (EBlock (DoLet false false (PVar "pre") (EApp (EApp (EVar "mangledName") (EVar "mid")) (ELit (LString "")))) (DoLet false false (PVar "lp") (EApp (EVar "stringLength") (EVar "pre"))) (DoExpr (EBinOp "&&" (EBinOp "<=" (EVar "lp") (EApp (EVar "stringLength") (EVar "k"))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "lp")) (EVar "k")) (EVar "pre"))))))
(DTypeSig false "isMangledExportOfAny" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isMangledExportOfAny" ((PList) PWild) (EVar "False"))
(DFunDef false "isMangledExportOfAny" ((PCons (PTuple (PVar "m") (PVar "pubV")) (PVar "rest")) (PVar "k")) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EVar "isMangledFor") (EVar "m")) (EVar "k")) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "k")) (EVar "pubV")))) (EApp (EApp (EVar "isMangledExportOfAny") (EVar "rest")) (EVar "k"))))
(DTypeSig false "importFormSchemes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "importFormSchemes" ((PVar "deps") (PCon "UseAlias" PWild (PVar "alias")) (PVar "depSchemes")) (EApp (EApp (EApp (EVar "aliasSchemes") (EVar "deps")) (EVar "alias")) (EVar "depSchemes")))
(DFunDef false "importFormSchemes" (PWild (PVar "path") (PVar "depSchemes")) (EApp (EApp (EVar "importFormRows") (EVar "path")) (EVar "depSchemes")))
(DTypeSig false "renameAliasedMethods" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "renameAliasedMethods" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "coreEntry") (ETuple (ELit (LString "core")) (EApp (EVar "declMethodNames") (EVar "coreDecls")))) (DoLet false false (PVar "methodsPerMid") (EBinOp "::" (EVar "coreEntry") (EApp (EApp (EVar "methodsPerMidGo") (EListLit (EVar "coreEntry"))) (EVar "modules")))) (DoLet false false (PVar "admitted") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "mid") (PVar "prog"))) (ETuple (EVar "mid") (EApp (EApp (EVar "synthesizedAdmissions") (EVar "methodsPerMid")) (EVar "prog"))))) (EVar "modules"))) (EVar "omEmpty"))) (DoExpr (ETuple (EVar "admitted") (EApp (EApp (EVar "map") (EApp (EVar "renameAliasedMethodsIn") (EVar "methodsPerMid"))) (EVar "modules"))))))
(DTypeSig false "admittedIn" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "admittedIn" ((PVar "gctx") (PVar "mid")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EFieldAccess (EVar "gctx") "graphAdmittedMethodsRef") "value"))))
(DTypeSig false "synthesizedAdmissions" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "synthesizedAdmissions" (PWild (PList)) (EListLit))
(DFunDef false "synthesizedAdmissions" ((PVar "mm") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "synthesizedAdmissions") (EVar "mm")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "synthesizedAdmissions" ((PVar "mm") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoLet false false (PVar "here") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "mm")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "methods")) () (EMatch (EVar "path") (arm (PCon "UseAlias" PWild PWild) () (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "mid") (EVar "n")))) (EVar "methods"))) (arm PWild () (EListLit)))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EVar "synthesizedAdmissions") (EVar "mm")) (EVar "rest"))))))
(DFunDef false "synthesizedAdmissions" ((PVar "mm") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "synthesizedAdmissions") (EVar "mm")) (EVar "rest")))
(DTypeSig false "methodsPerMidGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "methodsPerMidGo" (PWild (PList)) (EListLit))
(DFunDef false "methodsPerMidGo" ((PVar "acc") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EBlock (DoLet false false (PVar "entry") (ETuple (EVar "mid") (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "declMethodNames") (EVar "decls")) (EApp (EApp (EVar "reexportedMethodNames") (EVar "acc")) (EVar "decls")))))) (DoExpr (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "methodsPerMidGo") (EBinOp "::" (EVar "entry") (EVar "acc"))) (EVar "rest"))))))
(DTypeSig false "reexportedMethodNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reexportedMethodNames" ((PVar "acc") (PVar "ds")) (EApp (EApp (EVar "flatMap") (EApp (EVar "reexportedMethodsOf") (EVar "acc"))) (EApp (EVar "pubUsePaths") (EVar "ds"))))
(DTypeSig false "reexportedMethodsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reexportedMethodsOf" ((PVar "acc") (PVar "path")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "useModId") (EVar "path"))) (EVar "acc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "srcMethods")) () (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EVar "srcMethods")) (arm (PCon "Some" (PVar "bs")) () (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "srcMethods")))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "bs"))))))))
(DTypeSig false "renameAliasedMethodsIn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "renameAliasedMethodsIn" ((PVar "methodsPerMid") (PTuple (PVar "mid") (PVar "prog"))) (ETuple (EVar "mid") (EApp (EApp (EVar "flatMap") (EApp (EVar "deAliasMethodImports") (EVar "methodsPerMid"))) (EVar "prog"))))
(DTypeSig false "deAliasMethodImports" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "deAliasMethodImports" ((PVar "mm") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "map") (EApp (EVar "DAttrib") (EVar "attrs"))) (EApp (EApp (EVar "deAliasMethodImports") (EVar "mm")) (EVar "d"))))
(DFunDef false "deAliasMethodImports" ((PVar "mm") (PAs "d" (PCon "DUse" (PVar "pub") (PVar "path") (PVar "loc")))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "useModId") (EVar "path"))) (EVar "mm")) (arm (PCon "None") () (EListLit (EVar "d"))) (arm (PCon "Some" (PVar "methods")) () (EMatch (EVar "path") (arm (PCon "UseAlias" (PVar "quals") PWild) () (EMatch (EApp (EApp (EVar "methodMembersOf") (EVar "methods")) (EVar "loc")) (arm (PList) () (EListLit (EVar "d"))) (arm (PVar "mems") () (EListLit (EVar "d") (EApp (EApp (EApp (EVar "DUse") (EVar "pub")) (EApp (EApp (EVar "UseGroup") (EVar "quals")) (EVar "mems"))) (EVar "loc")))))) (arm PWild () (EListLit (EVar "d")))))))
(DFunDef false "deAliasMethodImports" (PWild (PVar "d")) (EListLit (EVar "d")))
(DTypeSig false "methodMembersOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyCon "UseMember")))))
(DFunDef false "methodMembersOf" ((PVar "methods") (PVar "loc")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "n")) (EVar "False")) (EVar "loc")) (EVar "None")))) (EVar "methods")))
(DTypeSig false "renameMethodVar" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "renameMethodVar" ((PVar "qualified") PWild (PAs "e" (PCon "EVar" (PVar "x")))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "qualified")) (arm (PCon "Some" (PVar "origin")) () (EApp (EVar "EVar") (EVar "origin"))) (arm (PCon "None") () (EVar "e"))))
(DFunDef false "renameMethodVar" ((PVar "qualified") PWild (PAs "e" (PCon "EVarId" (PVar "x") PWild))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "qualified")) (arm (PCon "Some" (PVar "origin")) () (EApp (EVar "EVar") (EVar "origin"))) (arm (PCon "None") () (EVar "e"))))
(DFunDef false "renameMethodVar" ((PVar "qualified") (PVar "members") (PAs "e" (PCon "EMethodAt" (PVar "x") (PVar "sym") (PVar "ev")))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "qualified")) (arm (PCon "Some" (PVar "origin")) () (EApp (EApp (EApp (EVar "EMethodAt") (EVar "origin")) (EVar "sym")) (EVar "ev"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "members")) (arm (PCon "Some" (PVar "origin")) () (EApp (EApp (EApp (EVar "EMethodAt") (EVar "origin")) (EVar "sym")) (EVar "ev"))) (arm (PCon "None") () (EVar "e"))))))
(DFunDef false "renameMethodVar" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "resolveAliasMethodSpellings" (TyFun (TyCon "GraphCtx") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "resolveAliasMethodSpellings" ((PVar "gctx") (PTuple (PVar "mid") (PVar "prog"))) (EBlock (DoLet false false (PVar "qualified") (EApp (EApp (EVar "map") (EVar "aliasRowSpelling")) (EApp (EApp (EVar "useKeyCands") (EApp (EVar "moduleAliasKeys") (EVar "gctx"))) (EVar "prog")))) (DoLet false false (PVar "members") (EApp (EApp (EVar "map") (EVar "aliasRowSpelling")) (EApp (EApp (EVar "memberAliasCands") (EVar "gctx")) (EVar "prog")))) (DoExpr (EMatch (ETuple (EVar "qualified") (EVar "members")) (arm (PTuple (PList) (PList)) () (ETuple (EVar "mid") (EVar "prog"))) (arm PWild () (ETuple (EVar "mid") (EApp (EApp (EVar "mapProg") (EApp (EApp (EVar "renameMethodVar") (EVar "qualified")) (EVar "members"))) (EApp (EApp (EVar "map") (EApp (EVar "deAliasMethodMembers") (EVar "members"))) (EVar "prog")))))))))
(DTypeSig false "deAliasMethodMembers" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "deAliasMethodMembers" ((PVar "rows") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "deAliasMethodMembers") (EVar "rows")) (EVar "d"))))
(DFunDef false "deAliasMethodMembers" ((PVar "rows") (PCon "DUse" (PVar "pub") (PCon "UseGroup" (PVar "quals") (PVar "ms")) (PVar "loc"))) (EApp (EApp (EApp (EVar "DUse") (EVar "pub")) (EApp (EApp (EVar "UseGroup") (EVar "quals")) (EApp (EApp (EVar "map") (EApp (EVar "deAliasMethodMember") (EVar "rows"))) (EVar "ms")))) (EVar "loc")))
(DFunDef false "deAliasMethodMembers" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "deAliasMethodMember" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyCon "UseMember"))))
(DFunDef false "deAliasMethodMember" ((PVar "rows") (PAs "m" (PCon "UseMember" (PVar "n") (PVar "allCtors") (PVar "loc") (PCon "Some" (PVar "local"))))) (EIf (EApp (EApp (EVar "containsPair") (ETuple (EVar "local") (EVar "n"))) (EVar "rows")) (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "n")) (EVar "allCtors")) (EVar "loc")) (EVar "None")) (EIf (EVar "otherwise") (EVar "m") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "deAliasMethodMember" (PWild (PVar "m")) (EVar "m"))
(DTypeSig false "declMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declMethodNames" ((PVar "decls")) (EApp (EVar "dedup") (EApp (EApp (EVar "flatMap") (EVar "declMethodNamesOf")) (EVar "decls"))))
(DTypeSig false "declMethodNamesOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declMethodNamesOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declMethodNamesOf") (EVar "d")))
(DFunDef false "declMethodNamesOf" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EVar "ifaceMethodNames") (EVar "methods")))
(DFunDef false "declMethodNamesOf" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "map") (EVar "implMethodName")) (EVar "methods")))
(DFunDef false "declMethodNamesOf" (PWild) (EListLit))
(DTypeSig false "importSeed" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyVar "a"))))))))))
(DFunDef false "importSeed" ((PVar "gctx") PWild PWild (PList) PWild) (EListLit))
(DFunDef false "importSeed" ((PVar "gctx") (PVar "coreV") (PVar "admitted") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "depEnv")) (EApp (EApp (EApp (EApp (EApp (EVar "importSeed") (EVar "gctx")) (EVar "coreV")) (EVar "admitted")) (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "depEnv")))
(DFunDef false "importSeed" ((PVar "gctx") (PVar "coreV") (PVar "admitted") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "depEnv")) (EBlock (DoLet false false (PVar "depId") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "depId") (ELit (LString "core"))) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "suppliedBy") (EVar "None"))) (EApp (EApp (EVar "coreAliasSchemes") (EVar "path")) (EVar "coreV"))) (EApp (EApp (EApp (EApp (EApp (EVar "importSeed") (EVar "gctx")) (EVar "coreV")) (EVar "admitted")) (EVar "rest")) (EVar "depEnv"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "depId")) (EVar "depEnv")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "importSeed") (EVar "gctx")) (EVar "coreV")) (EVar "admitted")) (EVar "rest")) (EVar "depEnv"))) (arm (PCon "Some" (PVar "depSchemes")) () (EBlock (DoLet false false (PVar "bound") (EApp (EVar "boundNames") (EVar "path"))) (DoLet false false (PVar "decls") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "importFormRows") (EVar "path")) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "depId"))))) (EVar "omEmpty"))) (DoLet false false (PVar "methods") (EApp (EApp (EVar "identKeysByName") (EVar "omEmpty")) (EApp (EApp (EVar "importFormRows") (EVar "path")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "depId")) (EApp (EApp (EVar "methodExportsIndex") (EVar "gctx")) (ELit LUnit))) (arm (PCon "Some" (PVar "rows")) () (EVar "rows")) (arm (PCon "None") () (EListLit)))))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "row")) (EApp (EApp (EVar "suppliedBy") (EIf (EBinOp "&&" (EApp (EApp (EVar "bindsName") (EVar "bound")) (EApp (EVar "fst") (EVar "row"))) (EApp (EVar "not") (EApp (EApp (EVar "containsPair") (ETuple (EVar "depId") (EApp (EVar "fst") (EVar "row")))) (EVar "admitted")))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "importSupplierKey") (EVar "depId")) (EVar "decls")) (EVar "methods")) (EApp (EVar "fst") (EVar "row")))) (EVar "None"))) (EVar "row")))) (EApp (EApp (EApp (EVar "importFormSchemes") (EVar "depEnv")) (EVar "path")) (EVar "depSchemes"))) (EApp (EApp (EApp (EApp (EApp (EVar "importSeed") (EVar "gctx")) (EVar "coreV")) (EVar "admitted")) (EVar "rest")) (EVar "depEnv")))))))))))
(DFunDef false "importSeed" ((PVar "gctx") (PVar "coreV") (PVar "admitted") (PCons PWild (PVar "rest")) (PVar "depEnv")) (EApp (EApp (EApp (EApp (EApp (EVar "importSeed") (EVar "gctx")) (EVar "coreV")) (EVar "admitted")) (EVar "rest")) (EVar "depEnv")))
(DTypeSig false "importSupplierKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "importSupplierKey" ((PVar "depId") (PVar "decls") (PVar "methods") (PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "decls")) (arm (PCon "Some" (PTuple (PVar "defMid") (PVar "origin"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lenKey") (EVar "defMid")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "lenKey") (EVar "origin")))) (ELit (LString "")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "methods")) (arm (PCon "Some" (PVar "keys")) () (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EVar "sortUniqS") (EVar "keys")))) (arm (PCon "None") () (EApp (EVar "lenKey") (EVar "depId")))))))
(DTypeSig false "identKeysByName" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "identKeysByName" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "identKeysByName" ((PVar "acc") (PCons (PTuple (PVar "n") (PVar "ident")) (PVar "rest"))) (EBlock (DoLet false false (PVar "seen") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "acc")) (arm (PCon "Some" (PVar "keys")) () (EVar "keys")) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EVar "identKeysByName") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "::" (EApp (EVar "identKey") (EVar "ident")) (EVar "seen"))) (EVar "acc"))) (EVar "rest")))))
(DTypeSig false "suppliedBy" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyVar "a")) (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyVar "a"))))))
(DFunDef false "suppliedBy" ((PVar "mid") (PTuple (PVar "name") (PVar "row"))) (ETuple (EVar "name") (ETuple (EVar "mid") (EVar "row"))))
(DTypeSig false "containsPair" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "containsPair" (PWild (PList)) (EVar "False"))
(DFunDef false "containsPair" ((PTuple (PVar "a") (PVar "b")) (PCons (PTuple (PVar "x") (PVar "y")) (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "x")) (EBinOp "==" (EVar "b") (EVar "y"))) (EApp (EApp (EVar "containsPair") (ETuple (EVar "a") (EVar "b"))) (EVar "rest"))))
(DTypeSig false "bindsName" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "bindsName" ((PCon "None") PWild) (EVar "True"))
(DFunDef false "bindsName" ((PCon "Some" (PVar "names")) (PVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "names")))
(DTypeSig false "coreAliasSchemes" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "coreAliasSchemes" ((PCon "UseAlias" PWild (PVar "a")) (PVar "coreV")) (EApp (EApp (EVar "map") (EApp (EVar "coreQualScheme") (EVar "a"))) (EVar "coreV")))
(DFunDef false "coreAliasSchemes" ((PCon "UseGroup" PWild (PVar "ms")) (PVar "coreV")) (EApp (EApp (EVar "flatMap") (EApp (EVar "coreRenameScheme") (EVar "coreV"))) (EVar "ms")))
(DFunDef false "coreAliasSchemes" (PWild PWild) (EListLit))
(DTypeSig false "coreQualScheme" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyVar "a")) (TyTuple (TyCon "String") (TyVar "a")))))
(DFunDef false "coreQualScheme" ((PVar "a") (PTuple (PVar "k") (PVar "s"))) (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "k")) (EVar "s")))
(DTypeSig false "coreRenameScheme" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "coreRenameScheme" ((PVar "coreV") (PVar "m")) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "local")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "useMemberOrigin") (EVar "m"))) (EVar "coreV")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EListLit (ETuple (EVar "local") (EVar "s"))))))))
(DTypeSig false "reexportSeed" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "reexportSeed" ((PVar "coreV") (PVar "decls") (PVar "depEnv")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "reexportSeedOf") (EVar "coreV")) (EVar "depEnv"))) (EApp (EVar "pubUsePaths") (EVar "decls"))))
(DTypeSig false "reexportSeedOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "reexportSeedOf" ((PVar "coreV") (PVar "depEnv") (PVar "path")) (EBlock (DoLet false false (PVar "depId") (EApp (EVar "useModId") (EVar "path"))) (DoLet false false (PVar "src") (EIf (EBinOp "==" (EVar "depId") (ELit (LString "core"))) (EApp (EVar "Some") (EVar "coreV")) (EApp (EApp (EVar "lookupAssoc") (EVar "depId")) (EVar "depEnv")))) (DoExpr (EMatch (EVar "src") (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "depSchemes")) () (EApp (EApp (EApp (EVar "importFormSchemes") (EVar "depEnv")) (EVar "path")) (EVar "depSchemes")))))))
(DTypeSig false "foldModules" (TyFun (TyApp (TyApp (TyCon "FoldPlan") (TyVar "e")) (TyVar "acc")) (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "ModuleServe") (TyVar "e"))) (TyFun (TyVar "acc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyVar "acc") (TyApp (TyCon "Option") (TyApp (TyCon "ModuleServe") (TyVar "e"))) (TyCon "ModuleCtx")))))))))))
(DFunDef false "foldModules" ((PVar "plan") (PVar "serve") (PVar "base") (PVar "depEnv") (PVar "accData") (PVar "accAll") (PVar "prev") (PVar "modules")) (EBlock (DoLet false false (PTuple (PVar "done") (PVar "served") (PVar "last")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "workModules") (EVar "plan")) (EVar "serve")) (EVar "depEnv")) (EVar "accData")) (EVar "accAll")) (EListLit)) (EVar "prev")) (EVar "modules"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "collectModules") (EFieldAccess (EVar "plan") "fpCollect")) (EVar "base")) (EVar "done")) (EVar "served") (EVar "last")))))
(DTypeSig false "workModules" (TyFun (TyApp (TyApp (TyCon "FoldPlan") (TyVar "e")) (TyVar "acc")) (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "ModuleServe") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "e"))) (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "e"))) (TyApp (TyCon "Option") (TyApp (TyCon "ModuleServe") (TyVar "e"))) (TyCon "ModuleCtx")))))))))))
(DFunDef false "workModules" (PWild (PVar "serve") PWild PWild PWild (PVar "done") (PVar "prev") (PList)) (ETuple (EVar "done") (EVar "serve") (EVar "prev")))
(DFunDef false "workModules" ((PVar "plan") (PVar "serve") (PVar "depEnv") (PVar "accData") (PVar "accAll") (PVar "done") (PVar "prev") (PList (PTuple (PVar "mid") (PVar "prog")))) (EBlock (DoLet false false (PVar "seed") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "moduleSeedFor") (EVar "prev")) (EFieldAccess (EVar "plan") "fpBaseSeed")) (EFieldAccess (EVar "plan") "fpCoreV")) (EVar "mid")) (EVar "prog")) (EVar "depEnv"))) (DoLet false false (PTuple PWild (PVar "extra") (PVar "next")) (EApp (EApp (EApp (EApp (EApp (EApp (EFieldAccess (EVar "plan") "fpWorker") (EVar "prev")) (EVar "mid")) (EVar "seed")) (EVar "accData")) (EVar "accAll")) (EVar "prog"))) (DoExpr (ETuple (EBinOp "::" (ETuple (EVar "mid") (EVar "extra")) (EVar "done")) (EVar "serve") (EVar "next")))))
(DFunDef false "workModules" ((PVar "plan") (PVar "serve") (PVar "depEnv") (PVar "accData") (PVar "accAll") (PVar "done") (PVar "prev") (PCons (PTuple (PVar "mid") (PVar "prog")) (PVar "rest"))) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EVar "map") (ELam ((PVar "policy")) (EApp (EApp (EApp (EFieldAccess (EVar "policy") "msStep") (EVar "mid")) (EVar "prog")) (EVar "prev")))) (EVar "serve"))) (DoLet false false (PTuple (PVar "own") (PVar "done2") (PVar "serve2") (PVar "next")) (EMatch (EVar "step") (arm (PCon "Some" (PCon "ServeHit" (PVar "own") (PVar "extra") (PVar "policy"))) () (ETuple (EVar "own") (EBinOp "::" (ETuple (EVar "mid") (EVar "extra")) (EVar "done")) (EApp (EVar "Some") (EVar "policy")) (EVar "prev"))) (arm PWild () (EBlock (DoLet false false (PVar "seed") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "moduleSeedFor") (EVar "prev")) (EFieldAccess (EVar "plan") "fpBaseSeed")) (EFieldAccess (EVar "plan") "fpCoreV")) (EVar "mid")) (EVar "prog")) (EVar "depEnv"))) (DoLet false false (PTuple (PVar "schemes") (PVar "extra") (PVar "next")) (EApp (EApp (EApp (EApp (EApp (EApp (EFieldAccess (EVar "plan") "fpWorker") (EVar "prev")) (EVar "mid")) (EVar "seed")) (EVar "accData")) (EVar "accAll")) (EVar "prog"))) (DoLet false false (PVar "own") (EApp (EApp (EVar "publicModuleExports") (EVar "prog")) (EVar "schemes"))) (DoExpr (EMatch (EVar "step") (arm (PCon "Some" (PCon "ServeCheck" (PVar "after"))) () (EBlock (DoLet false false (PTuple (PVar "done3") (PVar "policy")) (EApp (EApp (EApp (EVar "after") (EVar "next")) (EVar "own")) (EBinOp "::" (ETuple (EVar "mid") (EVar "extra")) (EVar "done")))) (DoExpr (ETuple (EVar "own") (EVar "done3") (EApp (EVar "Some") (EVar "policy")) (EVar "next"))))) (arm PWild () (ETuple (EVar "own") (EBinOp "::" (ETuple (EVar "mid") (EVar "extra")) (EVar "done")) (EVar "serve") (EVar "next"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "workModules") (EVar "plan")) (EVar "serve2")) (EBinOp "::" (ETuple (EVar "mid") (EBinOp "++" (EVar "own") (EApp (EApp (EApp (EVar "reexportSeed") (EFieldAccess (EVar "plan") "fpCoreV")) (EVar "prog")) (EVar "depEnv")))) (EVar "depEnv"))) (EMatch (EFieldAccess (EVar "plan") "fpAccumulate") (arm (PCon "AccumulateBoth") () (EBinOp "++" (EVar "accData") (EApp (EVar "publicDataDecls") (EVar "prog")))) (arm (PCon "AccumulateNone") () (EVar "accData")))) (EMatch (EFieldAccess (EVar "plan") "fpAccumulate") (arm (PCon "AccumulateBoth") () (EBinOp "++" (EVar "accAll") (EVar "prog"))) (arm (PCon "AccumulateNone") () (EVar "accAll")))) (EVar "done2")) (EVar "next")) (EVar "rest")))))
(DTypeSig false "moduleSeedFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))) (TyCon "ModuleSeed"))))))))
(DFunDef false "moduleSeedFor" ((PVar "prev") (PVar "baseSeed") (PVar "coreV") (PVar "mid") (PVar "prog") (PVar "depEnv")) (EApp (EApp (EApp (EVar "moduleImportSeed") (EVar "prev")) (EVar "baseSeed")) (EApp (EApp (EApp (EApp (EApp (EVar "importSeed") (EFieldAccess (EVar "prev") "mcGraph")) (EVar "coreV")) (EApp (EApp (EVar "admittedIn") (EFieldAccess (EVar "prev") "mcGraph")) (EVar "mid"))) (EVar "prog")) (EVar "depEnv"))))
(DTypeSig false "collectModules" (TyFun (TyFun (TyCon "ModulePlace") (TyFun (TyCon "String") (TyFun (TyVar "e") (TyFun (TyVar "acc") (TyVar "acc"))))) (TyFun (TyVar "acc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "e"))) (TyVar "acc")))))
(DFunDef false "collectModules" (PWild (PVar "base") (PList)) (EVar "base"))
(DFunDef false "collectModules" ((PVar "collect") (PVar "base") (PCons (PTuple (PVar "mid") (PVar "extra")) (PVar "older"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PTuple (PVar "m") (PVar "x"))) (EApp (EApp (EApp (EApp (EVar "collect") (EVar "NotLastModule")) (EVar "m")) (EVar "x")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "collect") (EVar "LastModule")) (EVar "mid")) (EVar "extra")) (EVar "base"))) (EVar "older")))
(DTypeSig false "checkCoreMemoized" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyCon "ModuleCtx"))))))))
(DFunDef false "checkCoreMemoized" ((PVar "prev") (PVar "key") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "runtimeSeed")) (EBlock (DoLet false false (PVar "gctx") (EFieldAccess (EVar "prev") "mcGraph")) (DoLet false false (PVar "join") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoin")) (DoLet false false (PVar "cached") (EMatch (EVar "key") (arm (PCon "Some" (PVar "k")) () (EApp (EApp (EVar "preludeCacheHit") (EVar "k")) (EVar "join"))) (arm (PCon "None") () (EVar "None")))) (DoExpr (EMatch (EVar "cached") (arm (PCon "Some" (PVar "pi")) () (EApp (EApp (EApp (EVar "continueFromInterface") (EVar "gctx")) (EFieldAccess (EVar "gctx") "graphRun")) (EVar "pi"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "coreSchemes") PWild (PVar "coreCtx")) (EApp (EApp (EApp (EApp (EVar "checkModuleFull") (EVar "prev")) (EVar "runtimeSeed")) (EListLit)) (EVar "coreDecls"))) (DoExpr (EMatch (EApp (EVar "checkGraphFinish") (EVar "coreCtx")) (arm (PList) () (ELit LUnit)) (arm (PCons (PVar "f") PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "evidence hole in the prelude: ")) (EApp (EVar "display") (EApp (EVar "tcMsg") (EFieldAccess (EVar "f") "dfDiag")))) (ELit (LString ""))))))) (DoLet false false (PVar "pi") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "freezeInterface") (EFieldAccess (EVar "gctx") "crossRun")) (EFieldAccess (EVar "gctx") "graphRun")) (EApp (EApp (EVar "externSigsToMap") (EVar "runtimeDecls")) (EVar "omEmpty"))) (EApp (EApp (EVar "publishCore") (EApp (EVar "coreOwnContexts") (EVar "coreCtx"))) (EFieldAccess (EVar "coreSchemes") "mbSchemes"))) (EApp (EApp (EVar "omMapValues") (ELam (PWild) (ELit LUnit))) (EFieldAccess (EVar "coreSchemes") "mbStandaloneSchemes"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "coreCtx") "mcCells") "invocationViewRef") "value"))) (DoExpr (EMatch (EVar "key") (arm (PCon "Some" (PVar "k")) () (EApp (EApp (EVar "seedPreludeInterface") (EVar "k")) (EListLit (ETuple (EListLit (EVar "join")) (EVar "pi"))))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "continueFromInterface") (EVar "gctx")) (EApp (EVar "graphLineageRun") (EFieldAccess (EApp (EVar "internersOf") (EVar "gctx")) "lineage"))) (EVar "pi")))))))))
(DTypeSig false "continueFromInterface" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GraphRun") (TyFun (TyCon "PreludeInterface") (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyCon "ModuleCtx"))))))
(DFunDef false "continueFromInterface" ((PVar "gctx") (PVar "run") (PVar "pi")) (EBlock (DoLet false false (PTuple (PVar "bindings") (PVar "corePub") (PVar "cross") (PVar "seed")) (EApp (EApp (EVar "thawInterface") (EVar "gctx")) (EVar "pi"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "run") "tyvarCounter")) (EFieldAccess (EVar "seed") "grsTyvarNext"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "run") "effvarCounter")) (EFieldAccess (EVar "seed") "grsEffvarNext"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "run") "ctorExistentialsRef")) (EFieldAccess (EVar "seed") "grsCtorExistentials"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "run") "anyExistentialsRef")) (EFieldAccess (EVar "seed") "grsAnyExistentials"))) (DoLet false false (PVar "restored") (EVariantUpdate "GraphCtx" (EVar "gctx") ((fa "crossRun" (EVar "cross")) (fa "graphRun" (EVar "run")) (fa "builtinExternNamesRef" (EApp (EVar "Ref") (EApp (EApp (EVar "IdMap.union") (EFieldAccess (EVar "pi") "piExternNames")) (EFieldAccess (EFieldAccess (EVar "gctx") "builtinExternNamesRef") "value"))))))) (DoLet false false (PVar "mctx") (EApp (EVar "initialModuleCtx") (EVar "restored"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "invocationViewRef")) (EApp (EVar "readInvocationView") (EFieldAccess (EVar "pi") "piInvocationView")))) (DoExpr (ETuple (EVar "bindings") (EVar "corePub") (EVar "mctx")))))
(DTypeSig false "preludePreambleMemoRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")) (TyCon "PreludePreamble")))))
(DFunDef false "preludePreambleMemoRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig false "preludePreambleOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "DeclEnvModule") (TyCon "PreludePreamble")))))
(DFunDef false "preludePreambleOf" ((PVar "gctx") (PVar "coreDecls") (PVar "coreRow")) (ERecordCreate "PreludePreamble" ((fa "ppEnvAcc" (EApp (EApp (EApp (EVar "declEnvAccOf") (EVar "gctx")) (EListLit (EVar "coreRow"))) (EVar "emptyDeclEnvAcc"))) (fa "ppMangledFunDefs" (EApp (EApp (EVar "unitCarriesMangledFunDefs") (ELit (LString "core"))) (EApp (EVar "funDefs") (EVar "coreDecls")))) (fa "ppMarkFacts" (EApp (EVar "preludeMarkFactsOf") (EVar "coreDecls"))))))
(DTypeSig false "preludePreambleFor" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "DeclEnvModule") (TyCon "PreludePreamble"))))))
(DFunDef false "preludePreambleFor" ((PVar "gctx") (PCon "None") (PVar "coreDecls") (PVar "coreRow")) (EApp (EApp (EApp (EVar "preludePreambleOf") (EVar "gctx")) (EVar "coreDecls")) (EVar "coreRow")))
(DFunDef false "preludePreambleFor" ((PVar "gctx") (PCon "Some" (PVar "k")) (PVar "coreDecls") (PVar "coreRow")) (EMatch (EUnOp "!" (EVar "preludePreambleMemoRef")) (arm (PCon "Some" (PVar "entry")) () (EIf (EBinOp "==" (EApp (EVar "fst") (EVar "entry")) (ETuple (EVar "k") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoinProfile"))) (EApp (EVar "snd") (EVar "entry")) (EApp (EApp (EApp (EApp (EVar "preludePreambleStore") (EVar "gctx")) (EVar "k")) (EVar "coreDecls")) (EVar "coreRow")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "preludePreambleStore") (EVar "gctx")) (EVar "k")) (EVar "coreDecls")) (EVar "coreRow")))))
(DTypeSig false "preludePreambleStore" (TyFun (TyCon "GraphCtx") (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "DeclEnvModule") (TyCon "PreludePreamble"))))))
(DFunDef false "preludePreambleStore" ((PVar "gctx") (PVar "k") (PVar "coreDecls") (PVar "coreRow")) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "preludePreambleOf") (EVar "gctx")) (EVar "coreDecls")) (EVar "coreRow"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "preludePreambleMemoRef")) (EApp (EVar "Some") (ETuple (ETuple (EVar "k") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoinProfile")) (EVar "p"))))) (DoExpr (EVar "p"))))
(DTypeSig true "tcConfigOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "DriveInputs") (TyCon "TcConfig"))))
(DFunDef false "tcConfigOf" ((PVar "domains") (PVar "inputs")) (ERecordCreate "TcConfig" ((fa "tcIoJoin" (EApp (EApp (EVar "ioJoinAtoms") (EVar "domains")) (EFieldAccess (EVar "inputs") "diIoJoinGrants"))) (fa "tcIoJoinProfile" (EFieldAccess (EVar "inputs") "diProfileName")) (fa "tcStdlibOwned" (EFieldAccess (EVar "inputs") "diStdlibOwned")) (fa "tcFlatEntryIsStdlib" (EFieldAccess (EVar "inputs") "diFlatEntryIsStdlib")) (fa "tcKey" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "inputs") "diProfileName"))) (ELit (LString "\n"))) (EApp (EVar "display") (EFieldAccess (EVar "inputs") "diFlatEntryIsStdlib"))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EVar "omKeys") (EFieldAccess (EVar "inputs") "diStdlibOwned"))))) (ELit (LString "")))))))
(DTypeSig false "graphPreamble" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "GraphOut") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "GraphPreamble")))))))))
(DFunDef false "graphPreamble" ((PVar "inputs") (PVar "admitted") (PVar "sel") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EBlock (DoExpr (EMatch (EApp (EVar "heldPreludeEvCounter") (ELit LUnit)) (arm (PCon "Some" (PVar "k")) () (EBlock (DoLet false false (PVar "lineage") (EFieldAccess (EFieldAccess (EVar "interners") "value") "lineage")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "lineage") "lnEvCounter")) (EApp (EApp (EVar "max") (EFieldAccess (EFieldAccess (EVar "lineage") "lnEvCounter") "value")) (EVar "k")))))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false (PVar "gctx") (EApp (EApp (EVar "mintGraphCtx") (EVar "inputs")) (EVar "admitted"))) (DoLet false false (PVar "initial") (EApp (EVar "initialModuleCtx") (EVar "gctx"))) (DoExpr (EApp (EApp (EApp (EVar "populateEffectDomainsGraph") (EVar "gctx")) (EVar "coreDecls")) (EVar "modules"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "config")) (EApp (EApp (EVar "tcConfigOf") (EFieldAccess (EFieldAccess (EVar "gctx") "effectDomains") "value")) (EVar "inputs")))) (DoLet false false (PVar "coreRow") (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "core"))) (EVar "coreDecls"))) (DoLet false false (PVar "modRows") (EApp (EApp (EApp (EVar "declEnvModulesFrom") (EVar "gctx")) (ELit (LInt 1))) (EVar "modules"))) (DoLet false false (PVar "prelude") (EApp (EApp (EApp (EApp (EVar "preludePreambleFor") (EVar "gctx")) (EVar "preludeKey")) (EVar "coreDecls")) (EVar "coreRow"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "mangledFunDefsPresentRef")) (EBinOp "||" (EFieldAccess (EVar "prelude") "ppMangledFunDefs") (EApp (EVar "graphCarriesMangledFunDefs") (EVar "modules"))))) (DoLet false false (PVar "declEnvs") (EApp (EApp (EApp (EApp (EVar "buildDeclEnvs") (EVar "gctx")) (EFieldAccess (EVar "prelude") "ppEnvAcc")) (EVar "coreRow")) (EVar "modRows"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "declEnvsRef")) (EVar "declEnvs"))) (DoLet false false (PVar "runtimeSeed") (EApp (EApp (EApp (EVar "withDeclParamKinds") (EVar "initial")) (EVar "coreDecls")) (ELam ((PVar "u")) (EApp (EApp (EApp (EVar "externSchemes") (EVar "initial")) (EApp (EVar "runtimeExternTyOriginScope") (EVar "coreDecls"))) (EVar "runtimeDecls"))))) (DoExpr (EApp (EApp (EApp (EVar "seedAbstractRecordTypes") (EVar "gctx")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "ms") (EApp (EApp (EApp (EApp (EApp (EVar "markSetsOf") (EVar "gctx")) (EFieldAccess (EVar "prelude") "ppMarkFacts")) (EVar "coreDecls")) (EVar "modules")) (EFieldAccess (EVar "declEnvs") "deAllDecls"))) (DoExpr (EApp (EApp (EVar "setDictEligible") (EVar "gctx")) (EApp (EVar "moduleUserFnNames") (EVar "modules")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "promotionHarvestRef")) (EListLit))) (DoLet false false (PTuple (PVar "coreSchemes") (PVar "corePub") (PVar "coreContexts") (PVar "coreTree") (PVar "coreCtx")) (EMatch (EVar "sel") (arm (PCon "GOutDiags") () (EBlock (DoLet false false (PTuple (PVar "bindings") (PVar "published") (PVar "coreCtx")) (EApp (EApp (EApp (EApp (EApp (EVar "checkCoreMemoized") (EVar "initial")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "runtimeSeed"))) (DoExpr (EApp (EVar "noteInterners") (EFieldAccess (EVar "coreCtx") "mcGraph"))) (DoExpr (ETuple (EVar "bindings") (EApp (EVar "Some") (EVar "published")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "coreCtx") "mcGraph") "crossRun") "coreSchemeObligationsRef") "value") (EListLit) (EVar "coreCtx"))))) (arm (PCon "GOutTrees") () (EMatch (EApp (EApp (EApp (EVar "treeArmHit") (EVar "inputs")) (EVar "coreDecls")) (EVar "gctx")) (arm (PCon "Some" (PTuple (PVar "pe") (PVar "pi"))) () (EBlock (DoLet false false (PTuple (PVar "bindings") (PVar "published") (PVar "coreCtx")) (EApp (EApp (EApp (EVar "continueFromInterface") (EVar "gctx")) (EFieldAccess (EVar "gctx") "graphRun")) (EVar "pi"))) (DoExpr (EApp (EVar "noteInterners") (EFieldAccess (EVar "coreCtx") "mcGraph"))) (DoExpr (ETuple (EVar "bindings") (EApp (EVar "Some") (EVar "published")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "coreCtx") "mcGraph") "crossRun") "coreSchemeObligationsRef") "value") (EFieldAccess (EVar "pe") "peDecls") (EVar "coreCtx"))))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "bindings") (PVar "tree") (PVar "coreCtx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "elabModuleStamp") (EVar "initial")) (ELit (LString ""))) (EVar "runtimeSeed")) (EListLit)) (EVar "coreDecls")) (EVar "coreDecls"))) (DoExpr (ETuple (EVar "bindings") (EVar "None") (EApp (EVar "coreOwnContexts") (EVar "coreCtx")) (EVar "tree") (EVar "coreCtx"))))))))) (DoExpr (ERecordCreate "GraphPreamble" ((fa "gpRuntimeSeed" (EVar "runtimeSeed")) (fa "gpCoreSchemes" (EVar "coreSchemes")) (fa "gpCorePub" (EVar "corePub")) (fa "gpCoreContexts" (EVar "coreContexts")) (fa "gpCoreTree" (EVar "coreTree")) (fa "gpMarkSets" (EVar "ms")) (fa "gpCoreCtx" (EVar "coreCtx")))))))
(DTypeSig false "treeArmElab" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "PreludeElab")))))
(DFunDef false "treeArmElab" ((PVar "inputs") (PVar "coreDecls")) (EMatch (EFieldAccess (EVar "inputs") "diPreludeKey") (arm (PCon "Some" (PVar "k")) () (EApp (EApp (EVar "preludeElabFor") (EVar "k")) (EVar "coreDecls"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "treeArmHit" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "GraphCtx") (TyApp (TyCon "Option") (TyTuple (TyCon "PreludeElab") (TyCon "PreludeInterface")))))))
(DFunDef false "treeArmHit" ((PVar "inputs") (PVar "coreDecls") (PVar "gctx")) (EApp (EApp (EVar "andThen") (EFieldAccess (EVar "inputs") "diPreludeKey")) (ELam ((PVar "k")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "preludeCacheHit") (EVar "k")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoin"))) (ELam ((PVar "pi")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "treeArmElab") (EVar "inputs")) (EVar "coreDecls"))) (ELam ((PVar "pe")) (EApp (EVar "Some") (ETuple (EVar "pe") (EVar "pi"))))))))))
(DTypeSig false "checkModulesPreambleK" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "ModuleBindings") (TyCon "ModuleCtx"))))))))
(DFunDef false "checkModulesPreambleK" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "pre") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphPreamble") (EVar "inputs")) (EVar "omEmpty")) (EVar "GOutDiags")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoExpr (ETuple (EFieldAccess (EVar "pre") "gpRuntimeSeed") (EFieldAccess (EVar "pre") "gpCoreSchemes") (EFieldAccess (EVar "pre") "gpCoreCtx")))))
(DTypeSig false "cmCheckWorker" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "ModuleSeed") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyCon "ModuleCtx")))))))))
(DFunDef false "cmCheckWorker" ((PVar "prev") (PVar "mid") (PVar "seed") (PVar "_accData") (PVar "_accAll") (PVar "prog")) (EBlock (DoLet false false (PTuple (PVar "schemes") PWild (PVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkBodyImpl") (EFieldAccess (EVar "prev") "mcGraph")) (EApp (EVar "checkRunResidue") (EVar "prev"))) (EVar "seed")) (EVar "mid")) (EListLit)) (EVar "prog"))) (DoExpr (ETuple (EVar "schemes") (EApp (EApp (EVar "publishOwn") (EVar "mctx")) (EFieldAccess (EVar "schemes") "mbSchemes")) (EVar "mctx")))))
(DTypeSig true "checkModules" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))))))
(DFunDef false "checkModules" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesK") (EVar "inputs")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0")))
(DTypeSig true "checkModulesK" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))))))))
(DFunDef false "checkModulesK" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EBlock (DoLet false false (PTuple (PVar "coreDecls") (PVar "modules")) (EApp (EApp (EVar "stampGraphDecls") (EVar "coreDecls0")) (EVar "modules0"))) (DoLet false false (PTuple (PVar "runtimeSeed") (PVar "coreSchemes") (PVar "coreCtx")) (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesPreambleK") (EVar "inputs")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoExpr (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "cmFold") (EVar "runtimeSeed")) (EVar "coreSchemes")) (EVar "coreCtx")) (EVar "modules"))))))
(DTypeSig true "checkModulesPartialK" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "PartialAnalysis")))))))
(DFunDef false "checkModulesPartialK" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesPartialLast") (EVar "inputs")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0"))))
(DTypeSig true "checkModulesPartialLast" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "PartialAnalysis") (TyCon "ModuleCtx"))))))))
(DFunDef false "checkModulesPartialLast" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EBlock (DoLet false false (PTuple (PVar "coreDecls") (PVar "modules")) (EApp (EApp (EVar "stampGraphDecls") (EVar "coreDecls0")) (EVar "modules0"))) (DoLet false false (PRec "GraphPreamble" ((rf "gpRuntimeSeed" (PVar "runtimeSeed")) (rf "gpCoreSchemes" (PVar "coreSchemes")) (rf "gpCorePub" (PVar "coreClosed")) (rf "gpCoreContexts" (PVar "coreContexts")) (rf "gpCoreCtx" (PVar "coreCtx"))) true) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphPreamble") (EVar "inputs")) (EVar "omEmpty")) (EVar "GOutDiags")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PTuple (PVar "rows") (PVar "lastCtx")) (EApp (EApp (EApp (EApp (EVar "cmFold") (EVar "runtimeSeed")) (EVar "coreSchemes")) (EVar "coreCtx")) (EVar "modules"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "partialAnalysis") (EVar "rows")) (EApp (EApp (EApp (EVar "publishedCore") (EVar "coreClosed")) (EVar "coreContexts")) (EFieldAccess (EVar "coreSchemes") "mbSchemes"))) (EApp (EApp (EApp (EVar "captureEntryTables") (EVar "lastCtx")) (EVar "coreContexts")) (EVar "modules"))) (EVar "lastCtx")))))
(DTypeSig false "cmFold" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyCon "ModuleBindings") (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))) (TyCon "ModuleCtx")))))))
(DFunDef false "cmFold" ((PVar "runtimeSeed") (PVar "coreSchemes") (PVar "coreCtx") (PVar "modules")) (EBlock (DoLet false false (PTuple (PVar "rows") PWild (PVar "lastCtx")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "foldModules") (ERecordCreate "FoldPlan" ((fa "fpAccumulate" (EVar "AccumulateNone")) (fa "fpWorker" (EVar "cmCheckWorker")) (fa "fpCollect" (ELam ((PVar "_place") (PVar "mid") (PVar "schemes") (PVar "rest")) (EBinOp "::" (ETuple (EVar "mid") (EVar "schemes")) (EVar "rest")))) (fa "fpBaseSeed" (EBinOp "++" (EVar "runtimeSeed") (EFieldAccess (EVar "coreSchemes") "mbSchemes"))) (fa "fpCoreV" (EApp (EApp (EVar "tagModuleExports") (EFieldAccess (EVar "coreSchemes") "mbStandaloneSchemes")) (EFieldAccess (EVar "coreSchemes") "mbSchemes")))))) (EVar "None")) (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EVar "coreCtx")) (EVar "modules"))) (DoExpr (ETuple (EApp (EApp (EVar "map") (ELam ((PVar "m")) (ETuple (EApp (EVar "fst") (EVar "m")) (EApp (EVar "freezeRows") (EApp (EVar "snd") (EVar "m")))))) (EVar "rows")) (EVar "lastCtx")))))
(DTypeSig false "graphModuleWorker" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GraphOut") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "ModuleSeed") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "Option") (TyCon "InvocationView"))) (TyCon "ModuleCtx")))))))))))
(DFunDef false "graphModuleWorker" ((PVar "capture") (PVar "sel") (PVar "prev") (PVar "mid") (PVar "seed") (PVar "accData") (PVar "accAll") (PVar "prog")) (EBlock (DoLet false false (PVar "implDecls") (EBinOp "++" (EVar "accAll") (EVar "prog"))) (DoLet false false (PTuple (PVar "schemes") (PVar "marked") (PVar "errs") (PVar "warns") (PVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModuleFullDiags") (EFieldAccess (EVar "prev") "mcGraph")) (EVar "mid")) (EVar "seed")) (EVar "accData")) (EVar "implDecls")) (EVar "prog"))) (DoLet false false (PVar "published") (EApp (EApp (EVar "publishOwn") (EVar "mctx")) (EFieldAccess (EVar "schemes") "mbSchemes"))) (DoLet false false (PVar "tree") (EMatch (EVar "sel") (arm (PCon "GOutTrees") () (EBlock (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "main"))) (EFieldAccess (EVar "schemes") "mbSchemes")) (arm (PCon "Some" (PVar "sc")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "prev") "mcGraph") "mainSchemeRef")) (EApp (EVar "Some") (EVar "sc")))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "prev") "mcGraph") "promotionHarvestRef")) (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "prev") "mcGraph") "promotionHarvestRef") "value") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "promotedRef") "value"))))) (DoExpr (EVar "marked")))) (arm (PCon "GOutDiags") () (EListLit)))) (DoLet false false (PVar "view") (EIf (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EVar "capture")) (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "invocationViewRef") "value")) (EVar "None"))) (DoExpr (ETuple (EVar "schemes") (ETuple (EVar "tree") (EVar "published") (EVar "errs") (EVar "warns") (EVar "view")) (EVar "mctx")))))
(DTypeSig false "graphCollect" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GraphOut") (TyFun (TyCon "ModulePlace") (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "Option") (TyCon "InvocationView"))) (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "InvocationView")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "InvocationView")))))))))))
(DFunDef false "graphCollect" ((PVar "gctx") (PVar "sel") (PVar "place") (PVar "mid") (PTuple (PVar "marked") (PVar "schemes") (PVar "errs") (PVar "warns") (PVar "view")) (PTuple (PVar "markedRest") (PVar "diagsRest") (PVar "views"))) (EBlock (DoExpr (EMatch (EVar "sel") (arm (PCon "GOutDiags") () (EApp (EApp (EApp (EVar "setMainSchemeIfEntry") (EVar "gctx")) (EVar "place")) (EVar "schemes"))) (arm (PCon "GOutTrees") () (ELit LUnit)))) (DoLet false false (PVar "markedOut") (EMatch (EVar "sel") (arm (PCon "GOutDiags") () (EVar "markedRest")) (arm (PCon "GOutTrees") () (EBinOp "::" (ETuple (EVar "mid") (EVar "marked")) (EVar "markedRest"))))) (DoExpr (ETuple (EVar "markedOut") (EBinOp "::" (ETuple (EVar "mid") (ETuple (EVar "schemes") (EVar "errs") (EVar "warns"))) (EVar "diagsRest")) (EApp (EApp (EApp (EVar "option") (EVar "views")) (ELam ((PVar "v")) (EBinOp "::" (ETuple (EVar "mid") (EVar "v")) (EVar "views")))) (EVar "view"))))))
(DTypeSig true "dropModSchemes" (TyFun (TyCon "ModDiags") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))
(DFunDef false "dropModSchemes" ((PTuple (PVar "mid") (PTuple PWild (PVar "errs") (PVar "warns")))) (ETuple (EVar "mid") (ETuple (EVar "errs") (EVar "warns"))))
(DTypeSig false "checkModulesEntryFromDiags" (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))
(DFunDef false "checkModulesEntryFromDiags" ((PList)) (ETuple (EListLit) (EListLit) (EListLit)))
(DFunDef false "checkModulesEntryFromDiags" ((PList (PTuple PWild (PTuple (PVar "s") (PVar "e") (PVar "w"))))) (ETuple (EVar "s") (EVar "e") (EVar "w")))
(DFunDef false "checkModulesEntryFromDiags" ((PCons (PTuple PWild (PTuple PWild (PVar "e") PWild)) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "eS") (PVar "eE") (PVar "eW")) (EApp (EVar "checkModulesEntryFromDiags") (EVar "rest"))) (DoExpr (ETuple (EVar "eS") (EBinOp "++" (EVar "e") (EVar "eE")) (EVar "eW")))))
(DTypeSig true "entryReportFromDiags" (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyCon "String")))
(DFunDef false "entryReportFromDiags" ((PVar "perMod")) (EMatch (EApp (EVar "checkModulesEntryFromDiags") (EVar "perMod")) (arm (PTuple (PVar "schemes") (PList) (PVar "warns")) () (EApp (EVar "joinNl") (EBinOp "++" (EApp (EVar "schemeLines") (EVar "schemes")) (EApp (EApp (EVar "map") (EVar "tcMsg")) (EVar "warns"))))) (arm (PTuple PWild (PVar "errs") PWild) () (EApp (EVar "joinNl") (EApp (EVar "typeErrorLines") (EApp (EApp (EVar "map") (EVar "tcMsg")) (EVar "errs")))))))
(DTypeSig false "setMainSchemeIfEntry" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ModulePlace") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyCon "Unit")))))
(DFunDef false "setMainSchemeIfEntry" ((PVar "gctx") (PCon "NotLastModule") PWild) (ELit LUnit))
(DFunDef false "setMainSchemeIfEntry" ((PVar "gctx") (PCon "LastModule") (PVar "schemes")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "mainSchemeRef")) (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EFieldAccess (EVar "p") "psScheme"))) (EApp (EApp (EVar "lookupAssoc") (ELit (LString "main"))) (EVar "schemes")))))
(DTypeSig true "chainFullKey" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "chainFullKey" ((PVar "rk") (PVar "ck") (PVar "chainKey")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "rk")))) (ELit (LString ","))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ck")))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "chainKey"))) (ELit (LString ""))))
(DTypeSig true "checkModulesDiagsChain" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ModDiags"))))))))))
(DFunDef false "checkModulesDiagsChain" ((PVar "inputs") (PVar "preludeKey") (PVar "chainKey") (PVar "stepKeys") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesDiagsChainFor") (EVar "inputs")) (EVar "False")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "stepKeys")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0")))
(DTypeSig false "checkModulesDiagsChainFor" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ModDiags")))))))))))
(DFunDef false "checkModulesDiagsChainFor" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "chainKey") (PVar "stepKeys") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EFieldAccess (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesChainReportFor") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "stepKeys")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0"))) "trDiagnostics"))
(DTypeSig true "checkModulesChainReportFor" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")))))))))))
(DFunDef false "checkModulesChainReportFor" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "chainKey") (PVar "stepKeys") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EVar "fst") (EApp (EVar "checkModulesChainReportForGraph") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "stepKeys")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0")))))
(DTypeSig true "chainArgs" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "DriveArgs"))))))))))
(DFunDef false "chainArgs" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "chainKey") (PVar "stepKeys") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EBlock (DoLet false false (PVar "base") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0"))) (DoExpr (ERecordUpdate (EVar "base") ((fa "daKeyed" (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "rk") (PVar "ck"))) (ETuple (EApp (EApp (EApp (EVar "chainFullKey") (EVar "rk")) (EVar "ck")) (EVar "chainKey")) (EVar "stepKeys")))) (EVar "preludeKey"))))))))
(DTypeSig true "driveArgs" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "DriveArgs"))))))))
(DFunDef false "driveArgs" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DriveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "None")) (EVar "preludeKey")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0")))
(DTypeSig true "checkModulesChainReportForGraph" (TyFun (TyCon "DriveArgs") (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphCtx"))))
(DFunDef false "checkModulesChainReportForGraph" ((PVar "args")) (EBlock (DoLet false false (PVar "g") (EApp (EApp (EVar "driveGraphK") (EVar "GOutDiags")) (EVar "args"))) (DoExpr (ETuple (ETuple (EFieldAccess (EVar "g") "gdReport") (EFieldAccess (EVar "g") "gdOutputs")) (EFieldAccess (EVar "g") "gdGraph")))))
(DTypeSig false "serveOps" (TyCon "ServeOps"))
(DFunDef false "serveOps" () (ERecordCreate "ServeOps" ((fa "soDrain" (ELam ((PVar "mctx") (PVar "rows")) (EMatch (EApp (EVar "checkGraphFinish") (EVar "mctx")) (arm (PList) () (EVar "rows")) (arm (PVar "findings") () (EApp (EApp (EVar "attachDrainFindings") (EVar "findings")) (EVar "rows")))))) (fa "soUnboundIds" (EVar "monoUnboundIds")))))
(DTypeSig false "freezeFrom" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "ModDiags")))))
(DFunDef false "freezeFrom" ((PVar "n") (PVar "rows")) (EBinOp "++" (EApp (EApp (EVar "take") (EVar "n")) (EVar "rows")) (EApp (EApp (EVar "map") (EVar "freezeModDiags")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "rows")))))
(DTypeSig false "buildDispositions" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "DeclEnvs") (TyCon "DispositionTable"))))
(DFunDef false "buildDispositions" ((PVar "gctx") (PVar "envs")) (EBlock (DoLet false false (PVar "impls") (EApp (EVar "ieRowsAll") (EFieldAccess (EVar "envs") "deImpls"))) (DoLet false false (PVar "table") (EApp (EApp (EVar "buildDispositionTableWithShapes") (EApp (EApp (EApp (EVar "dispositionRowsOfImpls") (EFieldAccess (EVar "envs") "deImpls")) (EVar "impls")) (EFieldAccess (EVar "envs") "deIfaces"))) (EApp (EApp (EVar "map") (EApp (EVar "ifaceSuperCountOfRow") (EVar "gctx"))) (EVar "impls")))) (DoExpr (EApp (EApp (EVar "validateDispositionTable") (EApp (EApp (EVar "dispositionSlotsOfImpls") (EVar "impls")) (EFieldAccess (EVar "envs") "deIfaces"))) (EVar "table"))) (DoExpr (EVar "table"))))
(DTypeSig false "dispositionSlotsOfImpls" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyTuple (TyCon "InstId") (TyCon "IfaceRef") (TyCon "String"))))))
(DFunDef false "dispositionSlotsOfImpls" ((PList) PWild) (EListLit))
(DFunDef false "dispositionSlotsOfImpls" ((PCons (PVar "r") (PVar "rest")) (PVar "ce")) (EBlock (DoLet false false (PTuple (PVar "iface") PWild PWild) (EApp (EVar "ieRowTriple") (EVar "r"))) (DoLet false false (PVar "inst") (EApp (EApp (EVar "InstId") (EApp (EVar "instRefMid") (EApp (EVar "ieRowInst") (EVar "r")))) (EApp (EVar "instRefSeq") (EApp (EVar "ieRowInst") (EVar "r"))))) (DoLet false false (PVar "supplied") (EApp (EVar "ieRowMethodNames") (EVar "r"))) (DoLet false false (PVar "here") (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")))) (EApp (EVar "ieRowOrd") (EVar "r"))) (EVar "ce")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "ceRow")) () (EApp (EApp (EVar "map") (ELam ((PVar "m")) (ETuple (EVar "inst") (EVar "iface") (EVar "m")))) (EApp (EApp (EVar "filter") (ELam ((PVar "m")) (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "m")) (EVar "supplied")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "m")) (EApp (EVar "ceRowRequired") (EVar "ceRow"))))))) (EApp (EVar "ceRowMethodNames") (EVar "ceRow"))))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EVar "dispositionSlotsOfImpls") (EVar "rest")) (EVar "ce"))))))
(DTypeSig false "dispositionRowsOfImpls" (TyFun (TyCon "ImplEnv") (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyTuple (TyCon "InstanceShape") (TyCon "String") (TyCon "MethodDisposition")))))))
(DFunDef false "dispositionRowsOfImpls" (PWild (PList) PWild) (EListLit))
(DFunDef false "dispositionRowsOfImpls" ((PVar "ie") (PCons (PVar "r") (PVar "rest")) (PVar "ce")) (EBinOp "++" (EApp (EApp (EApp (EVar "dispositionRowsOfImpl") (EVar "ie")) (EVar "r")) (EVar "ce")) (EApp (EApp (EApp (EVar "dispositionRowsOfImpls") (EVar "ie")) (EVar "rest")) (EVar "ce"))))
(DTypeSig false "dispositionRowsOfImpl" (TyFun (TyCon "ImplEnv") (TyFun (TyCon "ImplRow") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyTuple (TyCon "InstanceShape") (TyCon "String") (TyCon "MethodDisposition")))))))
(DFunDef false "dispositionRowsOfImpl" (PWild (PVar "r") (PVar "ce")) (EBlock (DoLet false false (PTuple (PVar "iface") (PVar "tys") PWild) (EApp (EVar "ieRowTriple") (EVar "r"))) (DoLet false false (PVar "inst") (EApp (EApp (EVar "InstId") (EApp (EVar "instRefMid") (EApp (EVar "ieRowInst") (EVar "r")))) (EApp (EVar "instRefSeq") (EApp (EVar "ieRowInst") (EVar "r"))))) (DoLet false false (PVar "ifaceWord") (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName"))) (DoLet false false (PVar "supplied") (EApp (EVar "ieRowMethodNames") (EVar "r"))) (DoLet false false (PVar "shape") (ERecordCreate "InstanceShape" ((fa "isWord" (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")) (EVar "tys")) (EVar "None"))) (fa "isTys" (EVar "tys"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")))) (EApp (EVar "ieRowOrd") (EVar "r"))) (EVar "ce")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "ceRow")) () (EApp (EApp (EVar "map") (ELam ((PVar "d")) (ETuple (EVar "shape") (EVar "ifaceWord") (EVar "d")))) (EApp (EApp (EApp (EApp (EApp (EVar "dispositionRowsOfMethods") (EVar "inst")) (EVar "iface")) (EVar "supplied")) (EApp (EVar "ceRowRequired") (EVar "ceRow"))) (EApp (EVar "ceRowMethodNames") (EVar "ceRow")))))))))
(DTypeSig false "ifaceSuperCountOfRow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ImplRow") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "ifaceSuperCountOfRow" ((PVar "gctx") (PVar "r")) (EBlock (DoLet false false (PTuple (PVar "iface") PWild PWild) (EApp (EVar "ieRowTriple") (EVar "r"))) (DoExpr (ETuple (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")) (EApp (EVar "listLen") (EApp (EApp (EApp (EVar "directSuperGoals") (EVar "gctx")) (EVar "iface")) (EListLit)))))))
(DTypeSig false "dispositionRowsOfMethods" (TyFun (TyCon "InstId") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodDisposition"))))))))
(DFunDef false "dispositionRowsOfMethods" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "dispositionRowsOfMethods" ((PVar "inst") (PVar "iface") (PVar "supplied") (PVar "required") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoLet false false (PVar "restRows") (EApp (EApp (EApp (EApp (EApp (EVar "dispositionRowsOfMethods") (EVar "inst")) (EVar "iface")) (EVar "supplied")) (EVar "required")) (EVar "rest"))) (DoExpr (EIf (EApp (EApp (EVar "contains") (EVar "m")) (EVar "supplied")) (EBinOp "::" (ERecordCreate "Supplied" ((fa "instance" (EVar "inst")) (fa "iface" (EVar "iface")) (fa "method" (EVar "m")))) (EVar "restRows")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "m")) (EVar "required"))) (EBinOp "::" (ERecordCreate "InheritedDefault" ((fa "instance" (EVar "inst")) (fa "iface" (EVar "iface")) (fa "method" (EVar "m")))) (EVar "restRows")) (EVar "restRows"))))))
(DTypeSig false "driveGraphK" (TyFun (TyCon "GraphOut") (TyFun (TyCon "DriveArgs") (TyCon "GraphDrive"))))
(DFunDef false "driveGraphK" ((PVar "sel") (PCon "DriveArgs" (PVar "inputs") (PVar "valueMain") (PVar "executes") (PVar "preludeKey") (PVar "keyed") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modulesIn"))) (EBlock (DoLet false false (PTuple (PVar "admitted") (PVar "modulesAliased")) (EApp (EApp (EVar "renameAliasedMethods") (EVar "coreDecls0")) (EVar "modulesIn"))) (DoLet false false (PTuple (PVar "coreDecls") (PVar "modules")) (EApp (EApp (EVar "stampGraphDecls") (EVar "coreDecls0")) (EVar "modulesAliased"))) (DoLet false false (PRec "GraphPreamble" ((rf "gpRuntimeSeed" (PVar "runtimeSeed")) (rf "gpCoreSchemes" (PVar "coreSchemes")) (rf "gpCorePub" (PVar "coreClosed")) (rf "gpCoreContexts" (PVar "coreContexts")) (rf "gpCoreTree" (PVar "coreTree")) (rf "gpMarkSets" (PVar "ms")) (rf "gpCoreCtx" (PVar "coreCtx"))) false) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphPreamble") (EVar "inputs")) (EVar "admitted")) (EVar "sel")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "capture") (EApp (EApp (EVar "requestedWrapperViewModules") (EFieldAccess (EVar "inputs") "diManifestRequests")) (EApp (EApp (EVar "manifestDriverFor") (EVar "inputs")) (EVar "executes")))) (DoLet false false (PVar "serve") (EApp (EApp (EVar "map") (ELam ((PVar "k")) (EBlock (DoLet false false (PVar "st") (EApp (EApp (EApp (EApp (EApp (EVar "serveStateOf") (EVar "serveOps")) (EVar "capture")) (EFieldAccess (EVar "coreCtx") "mcGraph")) (EVar "modules")) (EVar "k"))) (DoExpr (EMatch (EVar "sel") (arm (PCon "GOutDiags") () (EApp (EVar "diagsServe") (EVar "st"))) (arm (PCon "GOutTrees") () (EApp (EVar "treeServe") (EVar "st")))))))) (EVar "keyed"))) (DoExpr (EIf (EApp (EVar "isSome") (EVar "serve")) (EApp (EVar "raiseToHighWater") (EFieldAccess (EVar "coreCtx") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "coreView") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "coreCtx") "mcCells") "invocationViewRef") "value")) (DoLet false false (PTuple (PTuple (PVar "modules2") (PVar "perModRaw") (PVar "views")) (PVar "served") (PVar "lastCtx")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "foldModules") (ERecordCreate "FoldPlan" ((fa "fpAccumulate" (EVar "AccumulateBoth")) (fa "fpWorker" (EApp (EApp (EVar "graphModuleWorker") (EVar "capture")) (EVar "sel"))) (fa "fpCollect" (EApp (EApp (EVar "graphCollect") (EFieldAccess (EVar "coreCtx") "mcGraph")) (EVar "sel"))) (fa "fpBaseSeed" (EBinOp "++" (EVar "runtimeSeed") (EFieldAccess (EVar "coreSchemes") "mbSchemes"))) (fa "fpCoreV" (EApp (EApp (EVar "tagModuleExports") (EFieldAccess (EVar "coreSchemes") "mbStandaloneSchemes")) (EFieldAccess (EVar "coreSchemes") "mbSchemes")))))) (EVar "serve")) (ETuple (EListLit) (EListLit) (EListLit))) (EListLit)) (EApp (EVar "publicDataDecls") (EVar "coreDecls"))) (EVar "coreDecls")) (EVar "coreCtx")) (EVar "modules"))) (DoLet false false (PVar "findings") (EIf (EApp (EVar "isSome") (EVar "serve")) (EApp (EVar "checkGraphFinish") (EVar "lastCtx")) (EApp (EVar "drainStampQueue") (EVar "lastCtx")))) (DoExpr (EIf (EApp (EVar "isSome") (EVar "serve")) (EApp (EVar "noteHighWater") (EFieldAccess (EVar "lastCtx") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "servedCount") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "map") (ELam ((PVar "policy")) (EFieldAccess (EVar "policy") "msServed"))) (EVar "served")))) (DoLet false false (PTuple (PVar "wanted") (PVar "autoPrint")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "autoPrintWanted") (EVar "lastCtx")) (EVar "valueMain")) (EVar "executes")) (EVar "findings")) (EVar "perModRaw")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "outcome") (EApp (EApp (EApp (EVar "entryOutcomeNow") (EVar "lastCtx")) (EApp (EVar "mainHasObligations") (EVar "lastCtx"))) (EVar "autoPrint"))) (DoLet false false (PVar "perMod") (EApp (EApp (EVar "attachCoherenceConflict") (EVar "lastCtx")) (EApp (EApp (EVar "attachDrainFindings") (EBinOp "++" (EVar "findings") (EVar "wanted"))) (EApp (EApp (EVar "freezeFrom") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "map") (ELam ((PVar "policy")) (EFieldAccess (EVar "policy") "msFrozen"))) (EVar "served")))) (EVar "perModRaw"))))) (DoLet false false (PVar "entryTables") (EApp (EApp (EApp (EVar "captureEntryTables") (EVar "lastCtx")) (EVar "coreContexts")) (EVar "modules"))) (DoLet false false (PVar "corePub") (EApp (EApp (EApp (EVar "publishedCore") (EVar "coreClosed")) (EVar "coreContexts")) (EFieldAccess (EVar "coreSchemes") "mbSchemes"))) (DoLet false false (PTuple (PVar "requests") (PVar "manifests") (PVar "manifestDiags")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publishSelected") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "effectDomains") "value")) (EApp (EApp (EVar "invocationResolver") (EApp (EApp (EVar "frozenInvocationOps") (EVar "lastInvocationOps")) (EApp (EApp (EVar "driveOutputsNow") (EVar "lastCtx")) (EVar "outcome")))) (EApp (EApp (EApp (EVar "completionInvocationViews") (EVar "lastCtx")) (EVar "coreView")) (EVar "views")))) (EFieldAccess (EVar "inputs") "diManifestRequests")) (EVar "perMod")) (EVar "corePub")) (EVar "outcome")) (EApp (EApp (EVar "manifestDriverFor") (EVar "inputs")) (EVar "executes"))) (EVar "valueMain"))) (DoLet false false (PVar "dispositions") (EApp (EApp (EVar "buildDispositions") (EFieldAccess (EVar "lastCtx") "mcGraph")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "declEnvsRef") "value"))) (DoExpr (EMatch (EVar "sel") (arm (PCon "GOutDiags") () (ERecordCreate "GraphDrive" ((fa "gdPerMod" (EVar "perMod")) (fa "gdCoreSchemes" (EVar "corePub")) (fa "gdCoreContexts" (EVar "coreContexts")) (fa "gdCore" (EListLit)) (fa "gdModules" (EListLit)) (fa "gdResidual" (EListLit)) (fa "gdEvTable" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "graphRun") "evTable") "value")) (fa "gdDispositions" (EVar "dispositions")) (fa "gdBinders" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "graphRun") "binderRows") "value")) (fa "gdReport" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphReportWithOutcome") (EVar "outcome")) (EVar "manifests")) (EVar "manifestDiags")) (EVar "perMod")) (EVar "corePub")) (EListLit)) (EApp (EVar "drivenEvidence") (EFieldAccess (EVar "lastCtx") "mcGraph"))) (EVar "dispositions")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "graphRun") "binderRows") "value")) (EVar "None")) (EVar "entryTables"))) (fa "gdGraph" (EFieldAccess (EVar "lastCtx") "mcGraph")) (fa "gdOutputs" (EApp (EApp (EApp (EVar "withPublishedManifests") (EVar "requests")) (EVar "manifests")) (ERecordUpdate (EApp (EApp (EVar "driveOutputsNow") (EVar "lastCtx")) (EVar "outcome")) ((fa "doServedModules" (EVar "servedCount"))))))))) (arm (PCon "GOutTrees") () (EBlock (DoLet false false (PVar "dictNames") (EApp (EApp (EApp (EApp (EVar "markDictNames") (EFieldAccess (EVar "lastCtx") "mcGraph")) (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EVar "ms") "msBareDictNames") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "promotionHarvestRef") "value")))) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "shipped") (EMatch (EVar "coreClosed") (arm (PCon "Some" PWild) () (EApp (EApp (EVar "treeArmElab") (EVar "inputs")) (EVar "coreDecls"))) (arm (PCon "None") () (EVar "None")))) (DoLet false false (PTuple (PVar "coreD") (PVar "modules3")) (EApp (EApp (EApp (EApp (EApp (EVar "dictPassModulesIfEnabled") (EVar "lastCtx")) (EVar "dictNames")) (EApp (EVar "isSome") (EVar "shipped"))) (EVar "coreTree")) (EVar "modules2"))) (DoLet false false (PVar "modulesOut") (EApp (EApp (EVar "map") (EApp (EVar "resolveAliasMethodSpellings") (EFieldAccess (EVar "lastCtx") "mcGraph"))) (EVar "modules3"))) (DoLet false false (PVar "residual") (EApp (EVar "stickyDiagsInPushOrder") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "typeErrorsStickyDiags") "value"))) (DoLet false false (PTuple (PVar "evidence") (PVar "binders")) (EApp (EApp (EApp (EVar "withShippedRows") (EVar "shipped")) (EApp (EApp (EVar "drivenEvidence") (EFieldAccess (EVar "lastCtx") "mcGraph")) (ELit LUnit))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "graphRun") "binderRows") "value"))) (DoExpr (ERecordCreate "GraphDrive" ((fa "gdPerMod" (EVar "perMod")) (fa "gdCoreSchemes" (EVar "corePub")) (fa "gdCoreContexts" (EVar "coreContexts")) (fa "gdCore" (EVar "coreD")) (fa "gdModules" (EVar "modulesOut")) (fa "gdResidual" (EVar "residual")) (fa "gdEvTable" (EVar "evidence")) (fa "gdDispositions" (EVar "dispositions")) (fa "gdBinders" (EVar "binders")) (fa "gdReport" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphReportWithOutcome") (EVar "outcome")) (EVar "manifests")) (EVar "manifestDiags")) (EVar "perMod")) (EVar "corePub")) (EVar "residual")) (ELam (PWild) (EVar "evidence"))) (EVar "dispositions")) (EVar "binders")) (EApp (EVar "Some") (ETuple (EVar "coreD") (EVar "modulesOut")))) (EVar "entryTables"))) (fa "gdGraph" (EFieldAccess (EVar "lastCtx") "mcGraph")) (fa "gdOutputs" (EApp (EApp (EApp (EVar "withPublishedManifests") (EVar "requests")) (EVar "manifests")) (ERecordUpdate (EApp (EApp (EVar "driveOutputsNow") (EVar "lastCtx")) (EVar "outcome")) ((fa "doServedModules" (EVar "servedCount")))))))))))))))
(DTypeSig false "attachCoherenceConflict" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "ModDiags")))))
(DFunDef false "attachCoherenceConflict" ((PVar "mctx") (PVar "perMod")) (EMatch (EApp (EApp (EVar "globalCoherenceConflict") (EVar "mctx")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deImpls")) (arm (PTuple (PCon "None") (PCon "None")) () (EVar "perMod")) (arm (PTuple (PVar "hard") (PVar "soft")) () (EApp (EApp (EVar "attachEntryPayload") (EApp (EApp (EVar "cohOntoFull") (EVar "hard")) (EVar "soft"))) (EVar "perMod")))))
(DTypeSig false "cohOntoFull" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))))
(DFunDef false "cohOntoFull" ((PVar "hard") (PVar "soft") (PTuple (PVar "schemes") (PVar "errs") (PVar "warns"))) (ETuple (EVar "schemes") (EApp (EApp (EVar "prependConflict") (EVar "hard")) (EVar "errs")) (EApp (EApp (EVar "prependIncomparable") (EVar "soft")) (EVar "warns"))))
(DTypeSig false "attachEntryPayload" (TyFun (TyFun (TyVar "p") (TyVar "p")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "p"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "p"))))))
(DFunDef false "attachEntryPayload" (PWild (PList)) (EListLit))
(DFunDef false "attachEntryPayload" ((PVar "f") (PList (PTuple (PVar "mid") (PVar "p")))) (EListLit (ETuple (EVar "mid") (EApp (EVar "f") (EVar "p")))))
(DFunDef false "attachEntryPayload" ((PVar "f") (PCons (PVar "m") (PVar "rest"))) (EBinOp "::" (EVar "m") (EApp (EApp (EVar "attachEntryPayload") (EVar "f")) (EVar "rest"))))
(DTypeSig false "autoPrintWanted" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyApp (TyCon "Option") (TyCon "EvId")))))))))))
(DFunDef false "autoPrintWanted" ((PVar "mctx") (PCon "False") PWild PWild PWild PWild PWild) (ETuple (EListLit) (EVar "None")))
(DFunDef false "autoPrintWanted" ((PVar "mctx") (PCon "True") (PVar "executes") (PVar "findings") (PVar "perMod") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "decls") (EBinOp "++" (EVar "coreDecls") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules")))) (DoExpr (EMatch (ETuple (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "mainSchemeRef") "value") (EApp (EVar "last") (EVar "modules")) (EApp (EVar "printlnIface") (EVar "decls"))) (arm (PTuple (PCon "Some" (PVar "scheme")) (PCon "Some" (PTuple (PVar "mid") (PVar "entry"))) (PCon "Some" (PVar "iface"))) () (EIf (EApp (EApp (EApp (EVar "mainIsUnitNow") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "mainHasObligations") (EVar "mctx"))) (ELit LUnit)) (ETuple (EListLit) (EVar "None")) (EIf (EApp (EApp (EVar "mainIsAsyncNow") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit)) (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "asyncDriverFindings") (EVar "mctx")) (EVar "executes")) (EVar "mid")) (EVar "entry")) (EVar "scheme")) (EVar "perMod")) (EVar "None")) (EBlock (DoLet false false (PVar "scope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "None")) (ELit (LInt 0))) (EVar "mid")) (EVar "ModuleOwner"))) (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EVar "scope"))) (DoLet false false (PVar "loc") (EApp (EVar "mainBodySpan") (EVar "entry"))) (DoLet false false (PVar "atMain") (EApp (EApp (EVar "mctxAt") (EVar "loc")) (EVar "mctx"))) (DoLet false false (PVar "posed") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false (PVar "diags") (EApp (EApp (EVar "captureTypeErrors") (EVar "atMain")) (ELam (PWild) (EApp (EApp (EVar "setRef") (EVar "posed")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "judgeAutoPrintUse") (EVar "atMain")) (EVar "iface")) (EVar "scheme")) (EVar "loc"))))))) (DoLet false false (PVar "ev") (EMatch (ETuple (EVar "executes") (EVar "diags") (EFieldAccess (EVar "posed") "value")) (arm (PTuple (PCon "Some" PWild) (PList) (PCon "Some" (PVar "tau"))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "autoPrintEvidence") (EVar "atMain")) (EVar "mid")) (EVar "scope")) (EVar "iface")) (EVar "tau")))) (arm PWild () (EVar "None")))) (DoExpr (EApp (EApp (EVar "closeScope") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "reported") (EApp (EApp (EVar "driveErrs") (EVar "findings")) (EVar "perMod"))) (DoLet false false (PVar "kept") (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "d")) (EApp (EApp (EVar "inMainBinding") (EVar "entry")) (EApp (EVar "tcLoc") (EVar "d"))))) (EVar "reported")) (EApp (EVar "dropAmbiguity") (EVar "diags")) (EVar "diags"))) (DoExpr (ETuple (EApp (EApp (EVar "map") (EApp (EApp (EVar "verdictFinding") (EVar "mid")) (EVar "False"))) (EBinOp "++" (EApp (EApp (EVar "mainUseDiags") (EVar "loc")) (EVar "entry")) (EVar "kept"))) (EVar "ev"))))))) (arm PWild () (ETuple (EListLit) (EVar "None")))))))
(DTypeSig false "driveErrs" (TyFun (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "TcDiag")))))
(DFunDef false "driveErrs" ((PVar "findings") (PVar "perMod")) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EFieldAccess (EVar "f") "dfDiag"))) (EVar "findings")) (EApp (EApp (EVar "flatMap") (EVar "modDiagErrs")) (EVar "perMod"))))
(DTypeSig false "judgeAutoPrintUse" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))))))
(DFunDef false "judgeAutoPrintUse" ((PVar "mctx") (PVar "iface") (PVar "scheme") (PVar "loc")) (EApp (EApp (EApp (EVar "judgeMainUse") (EVar "mctx")) (ELam ((PVar "tau")) (EApp (EApp (EApp (EApp (EApp (EVar "recordObl") (EVar "mctx")) (ERecordCreate "Predicate" ((fa "iface" (EVar "iface")) (fa "args" (EListLit (EVar "tau")))))) (ELit (LInt 0))) (EVar "PCallSlot")) (EVar "loc")))) (EVar "scheme")))
(DTypeSig false "asyncDriverFindings" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "DrainFinding")))))))))
(DFunDef false "asyncDriverFindings" ((PVar "mctx") (PVar "executes") (PVar "mid") (PVar "entry") (PVar "scheme") (PVar "perMod")) (EBlock (DoLet false false (PVar "published") (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "async"))) (EVar "perMod")) (arm (PCon "Some" (PTuple (PVar "rows") PWild PWild)) () (EVar "rows")) (arm (PCon "None") () (EListLit)))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "option") (EVar "None")) (ELam ((PVar "d")) (EApp (EApp (EVar "lookupAssoc") (EVar "d")) (EVar "published")))) (EVar "executes")) (arm (PCon "Some" (PVar "driver")) ((GBool (EApp (EApp (EVar "mainAsyncPayloadIsUnitNow") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit)))) (EBlock (DoLet false false (PVar "scope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "None")) (ELit (LInt 0))) (EVar "mid")) (EVar "ModuleOwner"))) (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EVar "scope"))) (DoLet false false (PVar "atMain") (EApp (EApp (EVar "mctxAt") (EApp (EVar "mainBodySpan") (EVar "entry"))) (EVar "mctx"))) (DoLet false false (PVar "diags") (EApp (EApp (EVar "captureTypeErrors") (EVar "atMain")) (ELam (PWild) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "judgeMainUse") (EVar "atMain")) (EApp (EApp (EVar "asyncDriverUse") (EVar "atMain")) (EVar "driver"))) (EVar "scheme"))) (DoExpr (ELit LUnit)))))) (DoExpr (EApp (EApp (EVar "closeScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "map") (EApp (EApp (EVar "verdictFinding") (EVar "mid")) (EVar "False"))) (EVar "diags"))))) (arm PWild () (EListLit))))))
(DTypeSig false "asyncDriverUse" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PubScheme") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "asyncDriverUse" ((PVar "mctx") (PVar "driver") (PVar "tau")) (EBlock (DoLet false false (PTuple (PVar "driverTy") (PVar "subst")) (EApp (EApp (EVar "instantiateTracked") (EVar "mctx")) (EFieldAccess (EVar "driver") "psScheme"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EVar "mctx")) (ELit (LInt 0))) (EFieldAccess (EVar "driver") "psContext")) (EVar "subst"))) (DoExpr (EMatch (EApp (EVar "normalize") (EVar "driverTy")) (arm (PCon "TFun" (PVar "param") PWild PWild) () (EApp (EApp (EApp (EVar "unify") (EVar "mctx")) (EVar "param")) (EVar "tau"))) (arm PWild () (ELit LUnit))))))
(DTypeSig false "judgeMainUse" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "Mono") (TyCon "Unit")) (TyFun (TyCon "Scheme") (TyCon "Mono")))))
(DFunDef false "judgeMainUse" ((PVar "mctx") (PVar "pose") (PVar "scheme")) (EBlock (DoExpr (EApp (EApp (EVar "enterLevel") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "oblMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls"))) (DoLet false false (PVar "callMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls"))) (DoLet false false (PVar "dictMark") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (DoLet false false (PTuple (PVar "tau0") (PVar "subst")) (EApp (EApp (EVar "instantiateTracked") (EVar "mctx")) (EVar "scheme"))) (DoLet false false (PVar "fresh") (EApp (EApp (EVar "flatMap") (ELam ((PVar "p")) (EApp (EVar "monoUnboundIds") (EApp (EVar "snd") (EVar "p"))))) (EVar "subst"))) (DoLet false false (PVar "held") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "i")))) (EVar "fresh"))))) (EApp (EVar "dedupI") (EApp (EVar "monoUnboundIds") (EVar "tau0"))))) (DoLet false false (PVar "tau") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "map") (ELam ((PVar "i")) (ETuple (EVar "i") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))))) (EVar "held"))) (EListLit)) (EListLit)) (EVar "tau0"))) (DoLet false false (PVar "id") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (ELit (LString "main"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeDefIdsRef") "value")))) (DoLet false false (PVar "context") (EApp (EApp (EApp (EVar "lookupSchemeObls") (ELit (LString "main"))) (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value"))) (DoExpr (EApp (EVar "pose") (EVar "tau"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EVar "mctx")) (EVar "id")) (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "context"))) (EVar "subst"))) (DoExpr (EApp (EApp (EVar "exitLevel") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "settleClosedBody") (EVar "mctx")) (EApp (EVar "tconBuiltin") (ELit (LString "Unit")))) (EVar "oblMark")) (EVar "callMark")) (EVar "dictMark"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkCallObligationsU") (EVar "mctx")) (EVar "False")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "residualUnivRef") "value")) (EApp (EApp (EVar "callUOblsWindow") (EVar "mctx")) (EVar "callMark")))) (DoExpr (EVar "tau"))))
(DTypeSig false "autoPrintEvidence" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Mono") (TyCon "EvId")))))))
(DFunDef false "autoPrintEvidence" ((PVar "mctx") (PVar "mid") (PVar "scope") (PVar "iface") (PVar "tau")) (EBlock (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EApp (EVar "siteFor") (EVar "mctx"))) (ELit (LString ""))) (EVar "scope")) (EListLit (EVar "tau"))) (EListLit (EVar "iface"))) (EListLit (EListLit (EVar "tau"))))) (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "n") (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evCounter")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoLet false false (PVar "ev") (EApp (EApp (EVar "EvId") (EVar "mid")) (EVar "n"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evTable")) (EBinOp "::" (EApp (EApp (EVar "EvEntry") (EVar "ev")) (EApp (EVar "EvMany") (EVar "routes"))) (EFieldAccess (EFieldAccess (EVar "g") "evTable") "value")))) (DoExpr (EVar "ev"))))
(DTypeSig false "checkModulesEntryFull" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))
(DFunDef false "checkModulesEntryFull" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFullK") (EVar "inputs")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules")))
(DTypeSig false "checkModulesEntryFullK" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))))))
(DFunDef false "checkModulesEntryFullK" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PTuple PWild (PVar "schemes") (PVar "errs") (PVar "warns")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFullSplitK") (EVar "inputs")) (EVar "False")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoExpr (ETuple (EVar "schemes") (EVar "errs") (EVar "warns")))))
(DTypeSig false "checkModulesEntryFullSplitK" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))))
(DFunDef false "checkModulesEntryFullSplitK" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EVar "entrySplit") (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFullReportK") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0")))))
(DTypeSig true "entrySplit" (TyFun (TyCon "TcReport") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))
(DFunDef false "entrySplit" ((PVar "r")) (EBlock (DoLet false false (PTuple (PVar "schemes") (PVar "errs") (PVar "warns")) (EApp (EVar "checkModulesEntryFromDiags") (EFieldAccess (EVar "r") "trDiagnostics"))) (DoExpr (ETuple (EFieldAccess (EFieldAccess (EVar "r") "trPartial") "paCore") (EVar "schemes") (EVar "errs") (EVar "warns")))))
(DTypeSig true "checkModulesEntryFullReportK" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")))))))))
(DFunDef false "checkModulesEntryFullReportK" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EVar "fst") (EApp (EVar "checkModulesEntryFullReportKGraph") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0")))))
(DTypeSig false "checkModulesEntryFullReportKGraph" (TyFun (TyCon "DriveArgs") (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphCtx"))))
(DFunDef false "checkModulesEntryFullReportKGraph" ((PCon "DriveArgs" (PVar "inputs") (PVar "valueMain") PWild (PVar "preludeKey") PWild (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0"))) (EBlock (DoLet false false (PTuple (PVar "effectivePreludeKey") (PVar "effectiveCoreDecls0") (PVar "effectiveModules0")) (EMatch (EVar "modules0") (arm (PList (PTuple PWild (PVar "prog"))) () (EIf (EApp (EVar "programIsCore") (EVar "prog")) (ETuple (EVar "None") (EListLit) (EListLit (ETuple (ELit (LString "core")) (EVar "prog")))) (ETuple (EVar "preludeKey") (EVar "coreDecls0") (EVar "modules0")))) (arm PWild () (ETuple (EVar "preludeKey") (EVar "coreDecls0") (EVar "modules0"))))) (DoLet false false (PVar "g") (EApp (EApp (EVar "driveGraphK") (EVar "GOutDiags")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "effectivePreludeKey")) (EVar "runtimeDecls")) (EVar "effectiveCoreDecls0")) (EVar "effectiveModules0")))) (DoExpr (ETuple (ETuple (EFieldAccess (EVar "g") "gdReport") (EFieldAccess (EVar "g") "gdOutputs")) (EFieldAccess (EVar "g") "gdGraph")))))
(DTypeSig true "checkModulesEntryReport" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))))
(DFunDef false "checkModulesEntryReport" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "checkModulesEntryReportOut") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))))
(DTypeSig false "checkModulesEntryReportOut" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "String") (TyCon "DriveOutputs")))))))
(DFunDef false "checkModulesEntryReportOut" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PTuple (PVar "report") (PVar "outputs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFullReportK") (EVar "inputs")) (EVar "False")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PTuple PWild (PVar "schemes") (PVar "errs") (PVar "warns")) (EApp (EVar "entrySplit") (EVar "report"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (ETuple (EApp (EVar "joinNl") (EBinOp "++" (EApp (EVar "schemeLines") (EVar "schemes")) (EApp (EApp (EVar "map") (EVar "tcMsg")) (EVar "warns")))) (EVar "outputs"))) (arm PWild () (ETuple (EApp (EVar "joinNl") (EApp (EVar "typeErrorLines") (EApp (EApp (EVar "map") (EVar "tcMsg")) (EVar "errs")))) (EVar "outputs")))))))
(DTypeSig false "checkModulesEntryHasErrors" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool"))))))
(DFunDef false "checkModulesEntryHasErrors" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PTuple PWild (PVar "errs") PWild) (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFull") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "False")) (arm PWild () (EVar "True"))))))
(DTypeSig true "checkOneScheme" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "checkOneScheme" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EBlock (DoLet false false (PTuple (PVar "schemes") PWild PWild) (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFull") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog"))))) (DoExpr (EApp (EVar "pubSchemes") (EVar "schemes")))))
(DTypeSig true "checkOneSchemeFullK" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))))))
(DFunDef false "checkOneSchemeFullK" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "prog")) (EApp (EVar "fst") (EApp (EVar "checkOneSchemeFullKGraph") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveArgs") (EVar "inputs")) (EVar "False")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EListLit (EVar "prog"))))))
(DTypeSig true "checkOneSchemeFullKGraph" (TyFun (TyCon "DriveArgs") (TyTuple (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (TyCon "GraphCtx"))))
(DFunDef false "checkOneSchemeFullKGraph" ((PVar "args")) (EBlock (DoLet false false (PTuple (PVar "report") (PVar "gctx")) (EApp (EVar "checkOneReportKGraph") (EVar "args"))) (DoLet false false (PTuple (PVar "coreSchemes") (PVar "schemes") PWild PWild) (EApp (EVar "entrySplit") (EVar "report"))) (DoExpr (ETuple (ETuple (EVar "coreSchemes") (EVar "schemes")) (EVar "gctx")))))
(DTypeSig true "checkOneDiags" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))
(DFunDef false "checkOneDiags" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkOneDiagsK") (EVar "inputs")) (EVar "False")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "prog")))
(DTypeSig true "checkOneDiagsGraph" (TyFun (TyCon "DriveArgs") (TyTuple (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))) (TyCon "GraphCtx"))))
(DFunDef false "checkOneDiagsGraph" ((PVar "args")) (EBlock (DoLet false false (PTuple (PVar "report") (PVar "gctx")) (EApp (EVar "checkOneReportKGraph") (EVar "args"))) (DoLet false false (PTuple PWild PWild (PVar "errs") (PVar "warns")) (EApp (EVar "entrySplit") (EVar "report"))) (DoExpr (ETuple (ETuple (EVar "errs") (EVar "warns")) (EVar "gctx")))))
(DTypeSig false "checkOneDiagsK" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))))
(DFunDef false "checkOneDiagsK" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "prog")) (EBlock (DoLet false false (PTuple PWild PWild (PVar "errs") (PVar "warns")) (EApp (EVar "entrySplit") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkOneReportK") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "prog")))) (DoExpr (ETuple (EVar "errs") (EVar "warns")))))
(DTypeSig true "checkOneReportK" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "TcReport"))))))))
(DFunDef false "checkOneReportK" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "prog")) (EApp (EVar "fst") (EApp (EVar "checkOneReportKGraph") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EListLit (EVar "prog"))))))
(DTypeSig false "checkOneReportKGraph" (TyFun (TyCon "DriveArgs") (TyTuple (TyCon "TcReport") (TyCon "GraphCtx"))))
(DFunDef false "checkOneReportKGraph" ((PVar "args")) (EBlock (DoLet false false (PTuple (PTuple (PVar "report") PWild) (PVar "gctx")) (EApp (EVar "checkModulesEntryFullReportKGraph") (EVar "args"))) (DoExpr (ETuple (EVar "report") (EVar "gctx")))))
(DTypeSig true "checkOneToLinesWithRuntime" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "String") (TyCon "DriveOutputs")))))))
(DFunDef false "checkOneToLinesWithRuntime" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreProg") (PVar "userProg")) (EApp (EApp (EApp (EApp (EVar "checkModulesEntryReportOut") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreProg")) (EListLit (ETuple (ELit (LString "__user__")) (EVar "userProg")))))
(DTypeSig true "checkOneToLinesWithRuntimeK" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))))
(DFunDef false "checkOneToLinesWithRuntimeK" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreProg") (PVar "userProg")) (EBlock (DoLet false false (PTuple (PVar "schemes") (PVar "errs") (PVar "warns")) (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFullK") (EVar "inputs")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreProg")) (EListLit (ETuple (ELit (LString "__user__")) (EVar "userProg"))))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EApp (EVar "joinNl") (EBinOp "++" (EApp (EVar "schemeLines") (EVar "schemes")) (EApp (EApp (EVar "map") (EVar "tcMsg")) (EVar "warns"))))) (arm PWild () (EApp (EVar "joinNl") (EApp (EVar "typeErrorLines") (EApp (EApp (EVar "map") (EVar "tcMsg")) (EVar "errs")))))))))
(DTypeSig true "checkOneToLines" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "checkOneToLines" ((PVar "inputs") (PVar "userProg")) (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "checkOneToLinesWithRuntime") (EVar "inputs")) (EListLit)) (EListLit)) (EVar "userProg"))))
(DTypeSig true "checkOneErrorsWithRuntime" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))))
(DFunDef false "checkOneErrorsWithRuntime" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreProg") (PVar "userProg")) (EApp (EApp (EApp (EApp (EVar "checkModulesEntryHasErrors") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreProg")) (EListLit (ETuple (ELit (LString "__user__")) (EVar "userProg")))))
(DTypeSig true "checkOneMatchToLines" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))
(DFunDef false "checkOneMatchToLines" ((PVar "inputs") (PVar "runtimeDecls") (PVar "prog")) (EBlock (DoLet false false (PTuple PWild (PVar "warns")) (EApp (EApp (EApp (EApp (EVar "checkOneDiags") (EVar "inputs")) (EVar "runtimeDecls")) (EListLit)) (ETuple (ELit (LString "__user__")) (EVar "prog")))) (DoExpr (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "tcMsg")) (EVar "warns"))))))
(DTypeSig true "checkModulesEntryLines" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))))
(DFunDef false "checkModulesEntryLines" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EApp (EVar "joinNl") (EApp (EVar "schemeLines") (EApp (EVar "publishedEntrySchemes") (EApp (EApp (EApp (EApp (EVar "checkModules") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))))))
(DTypeSig true "checkModulesAllLines" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))))
(DFunDef false "checkModulesAllLines" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EApp (EVar "joinNl") (EApp (EVar "allModuleLines") (EApp (EApp (EApp (EApp (EVar "checkModules") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules")))))
(DTypeSig false "allModuleLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allModuleLines" ((PList)) (EListLit))
(DFunDef false "allModuleLines" ((PCons (PTuple (PVar "mid") (PVar "ss")) (PVar "rest"))) (EBinOp "::" (EBinOp "++" (ELit (LString "## MODULE ")) (EVar "mid")) (EBinOp "++" (EApp (EVar "schemeLines") (EVar "ss")) (EApp (EVar "allModuleLines") (EVar "rest")))))
(DTypeSig true "elaborateModules" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ElabResult"))))))
(DFunDef false "elaborateModules" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modulesIn")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "elaborateModulesWithSchemes") (EVar "inputs")) (EVar "False")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modulesIn")) (arm (PTuple (PVar "result") PWild PWild) () (EVar "result"))))
(DTypeSig true "elaborateModulesGraph" (TyFun (TyCon "DriveArgs") (TyTuple (TyCon "ElabResult") (TyCon "GraphCtx"))))
(DFunDef false "elaborateModulesGraph" ((PVar "args")) (EBlock (DoLet false false (PTuple (PTuple (PVar "result") PWild PWild) (PVar "gctx")) (EApp (EVar "elabTreesDrive") (EVar "args"))) (DoExpr (ETuple (EVar "result") (EVar "gctx")))))
(DTypeSig true "elaborateModulesWithSchemes" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "ElabResult") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))))))
(DFunDef false "elaborateModulesWithSchemes" ((PVar "inputs") (PVar "valueMain") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modulesIn")) (EBlock (DoLet false false (PTuple (PVar "result") (PVar "r") PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "elaborateModulesWithReport") (EVar "inputs")) (EVar "valueMain")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modulesIn"))) (DoLet false false (PTuple (PVar "core") (PVar "entrySchemes") PWild PWild) (EApp (EVar "entrySplit") (EVar "r"))) (DoExpr (ETuple (EVar "result") (EVar "core") (EVar "entrySchemes")))))
(DTypeSig true "elaborateModulesWithReport" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "ElabResult") (TyCon "TcReport") (TyCon "DriveOutputs")))))))))
(DFunDef false "elaborateModulesWithReport" ((PVar "inputs") (PVar "valueMain") (PVar "executes") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modulesIn")) (EApp (EVar "fst") (EApp (EVar "elabTreesDrive") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DriveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "executes")) (EVar "None")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modulesIn")))))
(DTypeSig true "elaborateModulesChainReport" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "ElabResult") (TyCon "TcReport") (TyCon "DriveOutputs")))))))))))
(DFunDef false "elaborateModulesChainReport" ((PVar "inputs") (PVar "valueMain") (PTuple (PVar "rk") (PVar "ck")) (PVar "chainKey") (PVar "stepKeys") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modulesIn")) (EApp (EVar "fst") (EApp (EVar "elabTreesDrive") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DriveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "None")) (EVar "None")) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EVar "chainFullKey") (EVar "rk")) (EVar "ck")) (EVar "chainKey")) (EVar "stepKeys")))) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modulesIn")))))
(DTypeSig false "elabTreesDrive" (TyFun (TyCon "DriveArgs") (TyTuple (TyTuple (TyCon "ElabResult") (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphCtx"))))
(DFunDef false "elabTreesDrive" ((PVar "args")) (EApp (EVar "elabDriveResult") (EApp (EApp (EVar "driveGraphK") (EVar "GOutTrees")) (EVar "args"))))
(DTypeSig false "elabDriveResult" (TyFun (TyCon "GraphDrive") (TyTuple (TyTuple (TyCon "ElabResult") (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphCtx"))))
(DFunDef false "elabDriveResult" ((PVar "g")) (ETuple (ETuple (ERecordCreate "ElabResult" ((fa "erCore" (EFieldAccess (EVar "g") "gdCore")) (fa "erModules" (EFieldAccess (EVar "g") "gdModules")) (fa "erPerModule" (EApp (EApp (EVar "map") (EVar "dropModSchemes")) (EFieldAccess (EVar "g") "gdPerMod"))) (fa "erResidual" (EFieldAccess (EVar "g") "gdResidual")) (fa "erEvidence" (EFieldAccess (EVar "g") "gdEvTable")) (fa "erDispositions" (EFieldAccess (EVar "g") "gdDispositions")) (fa "erFacts" (ERecordCreate "ElabFacts" ((fa "efManifests" (EFieldAccess (EFieldAccess (EVar "g") "gdOutputs") "doManifests")) (fa "efBinders" (EFieldAccess (EVar "g") "gdBinders")) (fa "efEntryOutcome" (EFieldAccess (EFieldAccess (EVar "g") "gdOutputs") "doEntryOutcome"))))))) (EFieldAccess (EVar "g") "gdReport") (EFieldAccess (EVar "g") "gdOutputs")) (EFieldAccess (EVar "g") "gdGraph")))
(DTypeSig true "elaborateModulesReport" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "TcReport"))))))
(DFunDef false "elaborateModulesReport" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modulesIn")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "elaborateModulesWithReport") (EVar "inputs")) (EVar "False")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modulesIn")) (arm (PTuple PWild (PVar "report") PWild) () (EVar "report"))))
(DTypeSig false "attachDrainFindings" (TyFun (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "ModDiags")))))
(DFunDef false "attachDrainFindings" ((PList) (PVar "perMod")) (EVar "perMod"))
(DFunDef false "attachDrainFindings" ((PVar "findings") (PVar "perMod")) (EBlock (DoLet false false (PVar "orphans") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "pm")) (EBinOp "==" (EApp (EVar "fst") (EVar "pm")) (EFieldAccess (EVar "f") "dfModule")))) (EVar "perMod"))))) (EVar "findings"))) (DoExpr (EMatch (EVar "orphans") (arm (PList) () (ELit LUnit)) (arm (PCons (PVar "f") PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence hole in module `")) (EApp (EVar "display") (EFieldAccess (EVar "f") "dfModule"))) (ELit (LString "`, which has no diagnostics list: "))) (EApp (EVar "display") (EApp (EVar "tcMsg") (EFieldAccess (EVar "f") "dfDiag")))) (ELit (LString ""))))))) (DoLet false false (PVar "erred") (EApp (EApp (EVar "anyList") (ELam ((PVar "pm")) (EApp (EVar "isNonEmptyL") (EApp (EVar "modDiagErrs") (EVar "pm"))))) (EVar "perMod"))) (DoLet false false (PVar "kept") (EIf (EVar "erred") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EFieldAccess (EVar "f") "dfLive")))) (EVar "findings")) (EVar "findings"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "pm")) (EApp (EApp (EVar "findingsOnto") (EVar "kept")) (EVar "pm")))) (EVar "perMod")))))
(DTypeSig false "modDiagErrs" (TyFun (TyCon "ModDiags") (TyApp (TyCon "List") (TyCon "TcDiag"))))
(DFunDef false "modDiagErrs" ((PTuple PWild (PTuple PWild (PVar "errs") PWild))) (EVar "errs"))
(DTypeSig false "findingsOnto" (TyFun (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyFun (TyCon "ModDiags") (TyCon "ModDiags"))))
(DFunDef false "findingsOnto" ((PVar "findings") (PTuple (PVar "mid") (PTuple (PVar "schemes") (PVar "errs") (PVar "warns")))) (EBlock (DoLet false false (PVar "mine") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EBinOp "==" (EFieldAccess (EVar "f") "dfModule") (EVar "mid")))) (EVar "findings"))) (DoLet false false (PVar "verdicts") (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EFieldAccess (EVar "f") "dfDiag"))) (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EFieldAccess (EVar "f") "dfVerdict"))) (EVar "mine")))) (DoExpr (EMatch (EBinOp "++" (EVar "errs") (EVar "verdicts")) (arm (PList) () (ETuple (EVar "mid") (ETuple (EVar "schemes") (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EFieldAccess (EVar "f") "dfDiag"))) (EVar "mine")) (EVar "warns")))) (arm (PVar "all") () (ETuple (EVar "mid") (ETuple (EVar "schemes") (EVar "all") (EVar "warns"))))))))
(DTypeSig false "preludeMarkFactsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "PreludeMarkFacts")))
(DFunDef false "preludeMarkFactsOf" ((PVar "coreDecls")) (ERecordCreate "PreludeMarkFacts" ((fa "pmfReturnPos" (EApp (EVar "returnPosMethodNames") (EVar "coreDecls"))) (fa "pmfMethodConstraints" (EApp (EVar "methodConstraintNames") (EVar "coreDecls"))) (fa "pmfArgDispatch" (EApp (EVar "argDispatchIndices") (EVar "coreDecls"))) (fa "pmfArgDispatchById" (EApp (EVar "argDispatchIndicesById") (EVar "coreDecls"))) (fa "pmfConstrainedNames" (EApp (EVar "constrainedSigNames") (EVar "coreDecls"))))))
(DTypeSig true "schemeLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "schemeLines" ((PList)) (EListLit))
(DFunDef false "schemeLines" ((PCons (PTuple (PVar "n") (PVar "p")) (PVar "rest"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppPubScheme") (EVar "p")))) (ELit (LString ""))) (EApp (EVar "schemeLines") (EVar "rest"))))
# MARK
(DUse false (UseGroup ("types" "invocation_basis") ((mem "readInvocationView" false) (mem "requestedWrapperViewModules" false) (mem "invocationResolver" false) (mem "slotVariances" false) (mem "ctorsByHead" false) (mem "paramPolaritiesIn" false) (mem "frozenInvocationOps" false) (mem "completionInvocationViews" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Ns" true) (mem "DataVis" true) (mem "implMethodName" false) (mem "Ty" true) (mem "EffParamTy" true) (mem "TyConOrigin" true) (mem "Ident" true) (mem "EvId" true) (mem "EvVal" true) (mem "EvEntry" true) (mem "Pat" true) (mem "Expr" true) (mem "Loc" true) (mem "Decl" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberOrigin" false) (mem "useMemberAlias" false) (mem "qualifiedLocal" false) (mem "TabKey" true) (mem "lookupTab" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Tyvar" true) (mem "normalize" false) (mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "VecObl" true) (mem "spineParts" false))))
(DUse false (UseGroup ("types" "effect_param_decode") ((mem "dtopIn" false) (mem "writtenParam" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "builtinLabel" false) (mem "atomWith" false) (mem "pureRow" false))))
(DUse false (UseAlias ("types" "effect_solver") "EffectSolver"))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "InvocationOps" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "StandaloneOrigin" true) (mem "SiteKind" true) (mem "ServeStep" true) (mem "Provenance" true) (mem "NumBoundaryDisposition" true) (mem "GoalPayload" true) (mem "DeclaringBinder" true) (mem "Accumulate" true) (mem "ModulePlace" true) (mem "FoldPlan" true) (mem "siteFor" false) (mem "DeclEnvModule" true) (mem "DeclEnvs" true) (mem "ImplRow" true) (mem "ImplEnv" true) (mem "ClassEnv" true) (mem "GraphCtx" true) (mem "TcConfig" true) (mem "DriveInputs" true) (mem "DriveArgs" true) (mem "DriveOutputs" true) (mem "withPublishedManifests" false) (mem "manifestDriverFor" false) (mem "Predicate" true) (mem "GraphRun" true) (mem "ModuleCtx" true) (mem "InvocationView" true) (mem "ModuleBindings" true) (mem "ExportBinding" true) (mem "ModuleSeed" true) (mem "PreludePreamble" true) (mem "GraphOut" true) (mem "ModuleServe" true) (mem "GraphDrive" true) (mem "GraphPreamble" true) (mem "ElabResult" true) (mem "ElabFacts" true) (mem "DrainFinding" true) (mem "MarkSets" true) (mem "PreludeMarkFacts" true))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true))))
(DUse false (UseAlias ("types" "scopes") "Scopes"))
(DUse true (UseGroup ("types" "publish") ((mem "TcDiag" true) (mem "tcCode" false) (mem "tcMsg" false) (mem "ModDiags" false) (mem "pubSchemes" false))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "tcLoc" false) (mem "TcReport" false) (mem "PartialAnalysis" false) (mem "EntryTables" true) (mem "noEntryTables" false) (mem "partialAnalysis" false) (mem "freezePub" false) (mem "freezeRows" false) (mem "freezeModDiags" false) (mem "graphReportWithOutcome" false) (mem "publishSelected" false) (mem "publishCore" false) (mem "publishWithContexts" false) (mem "publishedCore" false) (mem "publishedEntrySchemes" false) (mem "ppPubScheme" false))))
(DUse false (UseGroup ("types" "entry_outcome") ((mem "mainUseDiags" false) (mem "printlnIface" false) (mem "mainBodySpan" false) (mem "driveOutputsNow" false) (mem "entryOutcomeNow" false) (mem "mainIsAsyncNow" false) (mem "mainAsyncPayloadIsUnitNow" false) (mem "mainIsUnitNow" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapProg" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "useModId" false) (mem "pubUsePaths" false) (mem "exportedValueNames" false) (mem "nsAbstractData" false))))
(DUse false (UseGroup ("types" "value_main") ((mem "inMainBinding" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "programIsCore" false) (mem "stampTyOrigins" false) (mem "runtimeExternTyOriginScope" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "mangledName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omFromPairs" false) (mem "omFromNames" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "take" false) (mem "last" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "lookupAssoc" false) (mem "contains" false) (mem "reverseL" false) (mem "joinWith" false) (mem "joinNl" false) (mem "filterList" false) (mem "anyList" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "dedup" false) (mem "lenKey" false) (mem "sortUniqS" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "identKey" false) (mem "regKeyOfTab" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "typeTagOf" false) (mem "implRouteKeyWord" false) (mem "ifaceWordOf" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "InstId" true) (mem "MethodDisposition" true) (mem "DispositionTable" false) (mem "InstanceShape" true) (mem "buildDispositionTableWithShapes" false) (mem "validateDispositionTable" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "hostLabels" false) (mem "ioJoinGrants" false) (mem "profileName" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "RuntimeType" true))))
(DUse false (UseGroup ("types" "program_facts") ((mem "ProgramFacts" false) (mem "factsOfElab" false))))
(DUse false (UseGroup ("types" "serve_policy") ((mem "ServeOps" true) (mem "serveStateOf" false) (mem "diagsServe" false) (mem "treeServe" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "PreludeInterface" false) (mem "freezeInterface" false) (mem "thawInterface" false) (mem "seedPreludeInterface" false) (mem "preludeCacheHit" false))))
(DUse false (UseGroup ("types" "prelude_elab") ((mem "PreludeElab" true) (mem "heldPreludeEvCounter" false) (mem "preludeElabFor" false) (mem "withShippedRows" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "anyMember" false) (mem "dedupI" false) (mem "headTyconMono" false) (mem "instantiateFields" false) (mem "invocationHeadKey" false) (mem "monoUnboundIds" false) (mem "substMono" false) (mem "tconBuiltin" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "builtinCtors" false) (mem "callUOblsWindow" false) (mem "checkRunResidue" false) (mem "currentScopeStore" false) (mem "emptyDataEnv" false) (mem "freshGraphRun" false) (mem "graphLineageRun" false) (mem "initialGraphCtx" false) (mem "initialModuleCtx" false) (mem "interners" false) (mem "internersOf" false) (mem "mctxAt" false) (mem "mintGraphCtx" false) (mem "noteHighWater" false) (mem "noteInterners" false) (mem "raiseToHighWater" false) (mem "wMark" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "aliasOwnAt" false) (mem "aliasUniverseAt" false) (mem "boundNames" false) (mem "ceLookupAt" false) (mem "ceRowMethodNames" false) (mem "ceRowRequired" false) (mem "declEnvModule" false) (mem "emptyDeclEnvAcc" false) (mem "funDefs" false) (mem "graphPubDefiners" false) (mem "ieRowInst" false) (mem "ieRowMethodNames" false) (mem "ieRowOrd" false) (mem "ieRowsAll" false) (mem "ieRowTriple" false) (mem "ifaceMethodNames" false) (mem "ifaceTabKey" false) (mem "importedBindings" false) (mem "instRefMid" false) (mem "instRefSeq" false) (mem "methodExportsIndex" false) (mem "namesToSet" false) (mem "ordOfIndex" false) (mem "publicDataDecls" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "prependConflict" false) (mem "prependIncomparable" false) (mem "dropAmbiguity" false) (mem "stickyDiagsInPushOrder" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "aliasRowSpelling" false) (mem "importFormRows" false) (mem "memberAliasCands" false) (mem "moduleAliasKeys" false) (mem "useKeyCands" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "ambiguousImportTyvarId" false) (mem "enterLevel" false) (mem "exitLevel" false) (mem "freshVar" false) (mem "instantiateTracked" false) (mem "lookupSchemeObls" false) (mem "recordObl" false) (mem "recordSchemeCallObligations" false) (mem "unify" false) (mem "closeScope" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "populateEffectDomainsGraph" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "buildDeclEnvs" false) (mem "dataEnvFromDeclsGo" false) (mem "declEnvAccOf" false) (mem "declEnvModulesFrom" false) (mem "pubTopFnNames" false) (mem "stampGraphDecls" false) (mem "withDeclParamKinds" false))))
(DUse false (UseGroup ("types" "tc_foreign") ((mem "directExternSigs" false) (mem "externDecls" false) (mem "externSigsToMap" false) (mem "ffiExternTypeRowsWith" false))))
(DUse false (UseGroup ("types" "tc_solve_entail") ((mem "directSuperGoals" false))))
(DUse false (UseGroup ("types" "tc_solve") ((mem "goalsMark" false) (mem "openScope" false) (mem "returnPosMethodNames" false) (mem "routesOfMonosTopV" false))))
(DUse false (UseGroup ("types" "tc_solve_check") ((mem "checkCallObligationsU" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "grantOrder" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "argDispatchIndices" false) (mem "argDispatchIndicesById" false) (mem "constrainedSigNames" false) (mem "markDictNames" false) (mem "markSetsOf" false) (mem "methodConstraintNames" false))))
(DUse false (UseGroup ("types" "tc_groups") ((mem "allEVars" false))))
(DUse false (UseGroup ("types" "tc_elab") ((mem "dictPassModulesIfEnabled" false) (mem "drivenEvidence" false))))
(DUse false (UseGroup ("types" "tc_global") ((mem "globalCoherenceConflict" false))))
(DUse false (UseGroup ("types" "tc_module") ((mem "captureTypeErrors" false) (mem "checkBodyImpl" false) (mem "checkGraphFinish" false) (mem "checkModuleFull" false) (mem "checkModuleFullDiags" false) (mem "drainStampQueue" false) (mem "elabModuleStamp" false) (mem "externSchemesGo" false) (mem "settleClosedBody" false) (mem "verdictFinding" false))))
(DTypeSig true "ioJoinAtoms" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "ioJoinAtoms" ((PVar "domains") (PVar "grants")) (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "l")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "granted")) (EApp (EApp (EVar "atomWith") (EApp (EVar "builtinLabel") (EVar "l"))) (EApp (EApp (EVar "writtenParam") (EApp (EApp (EVar "dtopIn") (EVar "domains")) (EApp (EVar "builtinLabel") (EVar "l")))) (EVar "granted"))))) (EApp (EApp (EVar "lookupAssoc") (EVar "l")) (EVar "grants"))))) (EVar "hostLabels")))
(DTypeSig false "collectAbstractRecordTypes" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectAbstractRecordTypes" ((PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EFieldAccess (EVar "nsAbstractData") "nsDirectOf")) (EVar "decls")))
(DTypeSig false "seedAbstractRecordTypes" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Unit")))))
(DFunDef false "seedAbstractRecordTypes" ((PVar "gctx") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "abstracts") (EBinOp "++" (EApp (EVar "collectAbstractRecordTypes") (EVar "coreDecls")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EApp (EApp (EVar "abstractTypeWords") (EApp (EVar "fst") (EVar "m"))) (EApp (EVar "snd") (EVar "m"))))) (EVar "modules")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "abstractRecordTypesRef")) (EApp (EApp (EVar "namesToSet") (EVar "abstracts")) (EVar "omEmpty"))))))
(DTypeSig false "abstractTypeWords" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "abstractTypeWords" ((PVar "mid") (PVar "decls")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EVar "typeTagOf") (EApp (EVar "OriginModule") (EVar "mid"))) (EVar "n")))) (EApp (EVar "collectAbstractRecordTypes") (EVar "decls"))))
(DTypeSig true "stickyTypeErrorDiags" (TyFun (TyCon "DriveOutputs") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))))
(DFunDef false "stickyTypeErrorDiags" ((PVar "o")) (EApp (EVar "stickyDiagsInPushOrder") (EFieldAccess (EVar "o") "doStickyDiags")))
(DTypeSig true "hadTypeErrors" (TyFun (TyCon "DriveOutputs") (TyCon "Bool")))
(DFunDef false "hadTypeErrors" ((PVar "o")) (EFieldAccess (EVar "o") "doHadTypeErrors"))
(DTypeSig false "mainHasObligations" (TyFun (TyCon "ModuleCtx") (TyCon "Bool")))
(DFunDef false "mainHasObligations" ((PVar "mctx")) (EBlock (DoLet false false (PVar "id") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (ELit (LString "main"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeDefIdsRef") "value")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "lookupSchemeObls") (ELit (LString "main"))) (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value")) (arm (PCon "Some" (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False"))))))
(DTypeSig true "hadMatchWarnings" (TyFun (TyCon "DriveOutputs") (TyCon "Bool")))
(DFunDef false "hadMatchWarnings" ((PVar "o")) (EFieldAccess (EVar "o") "doHadMatchWarnings"))
(DTypeSig true "defaultDriveInputs" (TyCon "DriveInputs"))
(DFunDef false "defaultDriveInputs" () (ERecordCreate "DriveInputs" ((fa "diExecutedMainDriver" (EVar "None")) (fa "diManifestRequests" (EListLit)) (fa "diStdlibOwned" (EVar "omEmpty")) (fa "diFlatEntryIsStdlib" (EVar "False")) (fa "diTrace" (EVar "None")) (fa "diIoJoinGrants" (EApp (EVar "ioJoinGrants") (EVar "None"))) (fa "diProfileName" (ELit (LString ""))) (fa "diPreludeKey" (EVar "None")))))
(DTypeSig true "driveInputsFor" (TyFun (TyApp (TyCon "Option") (TyCon "TargetProfile")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "DriveInputs")))))
(DFunDef false "driveInputsFor" ((PVar "profile") (PVar "flatEntry") (PVar "mods")) (ERecordUpdate (EVar "defaultDriveInputs") ((fa "diStdlibOwned" (EApp (EApp (EVar "namesToSet") (EVar "mods")) (EVar "omEmpty"))) (fa "diFlatEntryIsStdlib" (EVar "flatEntry")) (fa "diIoJoinGrants" (EApp (EVar "ioJoinGrants") (EVar "profile"))) (fa "diProfileName" (EMatch (EVar "profile") (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "profileName") (EVar "p"))))))))
(DTypeSig false "lastInvocationOps" (TyFun (TyCon "DriveOutputs") (TyCon "InvocationOps")))
(DFunDef false "lastInvocationOps" ((PVar "o")) (EMatch (EFieldAccess (EVar "o") "doInvocationView") (arm (PCon "InvocationView" (PVar "ctors") (PVar "pols") (PVar "kinds")) () (EBlock (DoLet false false (PVar "byHead") (EApp (EApp (EVar "ctorsByHead") (EVar "invocationHeadKey")) (EVar "ctors"))) (DoLet false false (PVar "gctx") (EApp (EApp (EVar "initialGraphCtx") (EVar "builtinCtors")) (EApp (EVar "freshGraphRun") (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "effvarCounter")) (EFieldAccess (EVar "o") "doEffvarNext"))) (DoExpr (ERecordCreate "InvocationOps" ((fa "headVariances" (ELam ((PVar "h")) (EMatch (EApp (EVar "headTyconMono") (EVar "h")) (arm (PCon "Some" (PCon "HkDecl" (PVar "key"))) () (EApp (EApp (EVar "slotVariances") (EApp (EApp (EVar "paramPolaritiesIn") (EVar "pols")) (EVar "key"))) (EApp (EApp (EVar "lookupTab") (EVar "key")) (EVar "kinds")))) (arm PWild () (EVar "None"))))) (fa "appliedFields" (ELam ((PVar "applied")) (EBlock (DoLet false false (PTuple (PVar "h") (PVar "args")) (EApp (EVar "spineParts") (EVar "applied"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EApp (EApp (EApp (EVar "instantiateFields") (EVar "gctx")) (EVar "args")) (EVar "c")))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EVar "invocationHeadKey") (EVar "h"))) (EVar "byHead")))))))) (fa "headKey" (EVar "invocationHeadKey")))))))))
(DTypeSig false "ownContext" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl")))))
(DFunDef false "ownContext" ((PVar "mctx") (PVar "n")) (EBlock (DoLet false false (PVar "id") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeDefIdsRef") "value")))) (DoExpr (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EApp (EVar "lookupSchemeObls") (EVar "n")) (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value"))))))
(DTypeSig false "publishOwn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))
(DFunDef false "publishOwn" ((PVar "mctx")) (EApp (EVar "publishWithContexts") (EApp (EVar "ownContext") (EVar "mctx"))))
(DTypeSig false "coreOwnContexts" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl")))))
(DFunDef false "coreOwnContexts" ((PVar "mctx")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "kv")) (ETuple (EApp (EVar "fst") (EApp (EVar "fst") (EVar "kv"))) (EApp (EVar "snd") (EVar "kv"))))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value"))) (EVar "omEmpty")))
(DTypeSig false "seedContext" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl"))))))
(DFunDef false "seedContext" ((PVar "mctx") (PVar "coreContexts") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeDefIdsRef") "value")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "ownContext") (EVar "mctx")) (EVar "n"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "lookupSchemeObls") (EVar "n")) (ELit (LInt 0))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value")) (arm (PCon "Some" (PVar "obs")) () (EVar "obs")) (arm (PCon "None") () (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "coreContexts"))))))))
(DTypeSig false "captureEntryTables" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "EntryTables")))))
(DFunDef false "captureEntryTables" ((PVar "mctx") (PVar "coreContexts") (PVar "modules")) (EMatch (EApp (EVar "last") (EVar "modules")) (arm (PCon "None") () (EVar "noEntryTables")) (arm (PCon "Some" (PTuple (PVar "mid") PWild)) () (ERecordCreate "EntryTables" ((fa "etModule" (EVar "mid")) (fa "etLocals" (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "n") (PVar "loc") (PVar "s"))) (ETuple (EVar "n") (EApp (EApp (EVar "freezePub") (EVar "s")) (EApp (EApp (EVar "ownContext") (EVar "mctx")) (EVar "n"))) (EVar "loc")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "localSchemesOut") "value"))) (fa "etSeed" (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EApp (EVar "freezePub") (EApp (EVar "snd") (EVar "b"))) (EApp (EApp (EApp (EVar "seedContext") (EVar "mctx")) (EVar "coreContexts")) (EApp (EVar "fst") (EVar "b"))))))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "seedSchemesOut") "value"))))))))
(DTypeSig true "bindingGrantArity" (TyFun (TyCon "DriveOutputs") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "Int")))))
(DFunDef false "bindingGrantArity" ((PVar "o") PWild (PVar "sch")) (EIf (EFieldAccess (EVar "o") "doGrantsEnabled") (EApp (EVar "listLen") (EApp (EVar "grantOrder") (EVar "sch"))) (ELit (LInt 0))))
(DTypeSig true "elaborateOne" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "elaborateOne" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "prog")) (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "elaborateOneFacts") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "prog"))))
(DTypeSig true "elaborateOneFacts" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ProgramFacts")))))))
(DFunDef false "elaborateOneFacts" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EBlock (DoLet false false (PVar "elab") (EApp (EApp (EApp (EApp (EVar "elaborateModules") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog"))))) (DoLet false false (PVar "coreD") (EFieldAccess (EVar "elab") "erCore")) (DoLet false false (PVar "modules") (EFieldAccess (EVar "elab") "erModules")) (DoExpr (ETuple (EBinOp "++" (EVar "coreD") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules"))) (EApp (EVar "factsOfElab") (EVar "elab"))))))
(DTypeSig false "setDictEligible" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "setDictEligible" ((PVar "gctx") (PVar "names")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "dictEligibleRef")) (EVar "names"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "dictEligibleSetRef")) (EApp (EApp (EVar "namesToSet") (EVar "names")) (EVar "omEmpty"))))))
(DTypeSig false "moduleUserFnNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleUserFnNames" ((PVar "modules")) (EApp (EVar "dedup") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "p")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "funDefs") (EApp (EVar "snd") (EVar "p")))))) (EVar "modules"))))
(DTypeSig true "preludeReturnPosDictNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "preludeReturnPosDictNames" ((PVar "preludeDecls") (PVar "allDecls")) (EBlock (DoLet false false (PVar "rpNames") (EApp (EVar "returnPosMethodNames") (EVar "allDecls"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "anyMember") (EApp (EApp (EVar "declBodyVars") (EVar "n")) (EVar "preludeDecls"))) (EVar "rpNames")))) (EApp (EVar "constrainedSigNames") (EVar "preludeDecls"))))))
(DTypeSig true "preludeArgPosDictNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "preludeArgPosDictNames" ((PVar "preludeDecls") (PVar "allDecls")) (EBlock (DoLet false false (PVar "rpSet") (EApp (EApp (EVar "preludeReturnPosDictNames") (EVar "preludeDecls")) (EVar "allDecls"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "rpSet"))))) (EApp (EVar "constrainedSigNames") (EVar "preludeDecls"))))))
(DTypeSig false "declBodyVars" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declBodyVars" ((PVar "n") (PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declBodyVarsOf") (EVar "n"))) (EVar "decls")))
(DTypeSig false "declBodyVarsOf" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declBodyVarsOf" ((PVar "n") (PCon "DFunDef" PWild (PVar "m") PWild (PVar "body") PWild PWild)) (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EApp (EVar "allEVars") (EVar "body")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "declBodyVarsOf" (PWild PWild) (EListLit))
(DTypeSig false "externSchemes" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "externSchemes" ((PVar "mctx") (PVar "scope") (PVar "decls")) (EBlock (DoLet false false (PVar "ds") (EApp (EVar "externDecls") (EVar "decls"))) (DoExpr (EApp (EApp (EVar "noteBuiltinExternNames") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ds"))) (DoExpr (EApp (EApp (EVar "externSchemesGo") (EVar "mctx")) (EApp (EApp (EVar "stampTyOrigins") (EVar "scope")) (EVar "ds"))))))
(DTypeSig false "noteBuiltinExternNames" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "noteBuiltinExternNames" ((PVar "gctx") (PVar "ds")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "builtinExternNamesRef")) (EApp (EApp (EVar "externSigsToMap") (EVar "ds")) (EFieldAccess (EFieldAccess (EVar "gctx") "builtinExternNamesRef") "value"))))
(DTypeSig true "checkedFfiExternTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "checkedFfiExternTypeNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "denv") (EApp (EApp (EApp (EVar "dataEnvFromDeclsGo") (ELit (LInt 0))) (EVar "decls")) (EVar "emptyDataEnv"))) (DoExpr (EApp (EApp (EApp (EVar "ffiExternTypeRowsWith") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "interners") "value") "externCatalog") "value")) (EApp (EApp (EVar "aliasOwnAt") (ELit (LInt 0))) (EFieldAccess (EVar "denv") "deAliases"))) (EVar "decls")))))
(DTypeSig true "checkedFfiExternTypeNamesModules" (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "checkedFfiExternTypeNamesModules" ((PVar "o") (PVar "modules")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkedFfiExternTypeNamesModule") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "interners") "value") "externCatalog") "value")) (EVar "o"))) (EVar "modules")))
(DTypeSig false "checkedFfiExternTypeNamesModule" (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))) (TyFun (TyCon "DriveOutputs") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))))
(DFunDef false "checkedFfiExternTypeNamesModule" ((PVar "catalog") (PVar "o") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "cur") (EApp (EApp (EVar "ordOfIndex") (EVar "mid")) (EFieldAccess (EVar "o") "doOrdIndex"))) (DoLet false false (PVar "aliases") (EBinOp "++" (EApp (EApp (EVar "aliasOwnAt") (EVar "cur")) (EFieldAccess (EVar "o") "doFfiAliases")) (EApp (EApp (EVar "aliasUniverseAt") (EVar "cur")) (EFieldAccess (EVar "o") "doFfiAliases")))) (DoExpr (EApp (EApp (EApp (EVar "ffiExternTypeRowsWith") (EVar "catalog")) (EVar "aliases")) (EVar "decls")))))
(DTypeSig false "typeErrorLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "typeErrorLines" ((PList)) (EListLit))
(DFunDef false "typeErrorLines" ((PCons (PVar "e") (PVar "rest"))) (EBinOp "::" (EBinOp "++" (ELit (LString "TYPE ERROR: ")) (EVar "e")) (EApp (EVar "typeErrorLines") (EVar "rest"))))
(DTypeSig false "graphCarriesMangledFunDefs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool")))
(DFunDef false "graphCarriesMangledFunDefs" ((PList)) (EVar "False"))
(DFunDef false "graphCarriesMangledFunDefs" ((PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EIf (EApp (EApp (EVar "unitCarriesMangledFunDefs") (EVar "mid")) (EApp (EVar "funDefs") (EVar "decls"))) (EVar "True") (EApp (EVar "graphCarriesMangledFunDefs") (EVar "rest"))))
(DTypeSig false "unitCarriesMangledFunDefs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyCon "Bool"))))
(DFunDef false "unitCarriesMangledFunDefs" ((PVar "mid") (PList)) (EVar "False"))
(DFunDef false "unitCarriesMangledFunDefs" ((PVar "mid") (PCons (PTuple (PVar "n") PWild) (PVar "rest"))) (EIf (EApp (EApp (EVar "isMangledFor") (EVar "mid")) (EVar "n")) (EVar "True") (EApp (EApp (EVar "unitCarriesMangledFunDefs") (EVar "mid")) (EVar "rest"))))
(DTypeSig false "pickSchemes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))
(DFunDef false "pickSchemes" ((PList) PWild) (EListLit))
(DFunDef false "pickSchemes" ((PCons (PVar "n") (PVar "ns")) (PVar "table")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "table")) (arm (PCon "Some" (PVar "s")) () (EBinOp "::" (ETuple (EVar "n") (EVar "s")) (EApp (EApp (EVar "pickSchemes") (EVar "ns")) (EVar "table")))) (arm (PCon "None") () (EApp (EApp (EVar "pickSchemes") (EVar "ns")) (EVar "table")))))
(DTypeSig false "tagModuleExports" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))))
(DFunDef false "tagModuleExports" ((PVar "standalones") (PVar "schemes")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "name") (PVar "scheme"))) (ETuple (EVar "name") (ERecordCreate "ExportBinding" ((fa "xbScheme" (EVar "scheme")) (fa "xbStandalone" (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "standalones"))) (fa "xbExtern" (EVar "False"))))))) (EVar "schemes")))
(DTypeSig false "publicModuleExports" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))))
(DFunDef false "publicModuleExports" ((PVar "prog") (PVar "bindings")) (EBlock (DoLet false false (PVar "standalones") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "bindings") "mbStandaloneSchemes")) (arm (PCon "Some" (PVar "scheme")) () (EListLit (ETuple (EVar "name") (EVar "scheme")))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "pubTopFnNames") (EVar "prog")))) (EVar "omEmpty"))) (DoLet false false (PVar "externs") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "directExternSigs") (EApp (EVar "externDecls") (EVar "prog"))))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "name") (PVar "binding"))) (ETuple (EVar "name") (EVariantUpdate "ExportBinding" (EVar "binding") ((fa "xbExtern" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "externs")))))))) (EApp (EApp (EVar "tagModuleExports") (EVar "standalones")) (EApp (EApp (EVar "pickSchemes") (EApp (EVar "exportedValueNames") (EVar "prog"))) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EFieldAccess (EVar "bindings") "mbSchemes"))) (EVar "omEmpty"))))))))
(DTypeSig false "importedBindingWinners" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "ExportBinding")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))))))
(DFunDef false "importedBindingWinners" ((PVar "mctx") (PList) PWild PWild) (EListLit))
(DFunDef false "importedBindingWinners" ((PVar "mctx") (PCons (PTuple (PVar "name") (PTuple PWild (PVar "binding"))) (PVar "rest")) (PVar "seen") (PVar "ambiguous")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "importedBindingWinners") (EVar "mctx")) (EVar "rest")) (EVar "seen")) (EVar "ambiguous")) (EBlock (DoLet false false (PVar "chosen") (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "ambiguous")) (EApp (EApp (EVar "ambiguousImportBinding") (EVar "mctx")) (ELit LUnit)) (EVar "binding"))) (DoExpr (EBinOp "::" (ETuple (EVar "name") (EVar "chosen")) (EApp (EApp (EApp (EApp (EVar "importedBindingWinners") (EVar "mctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "seen"))) (EVar "ambiguous")))))))
(DTypeSig false "ambiguousImports" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyVar "a")))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "ambiguousImports" ((PVar "rows")) (EApp (EApp (EApp (EVar "ambiguousImportsGo") (EVar "rows")) (EVar "omEmpty")) (EVar "omEmpty")))
(DTypeSig false "ambiguousImportsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyVar "a")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "ambiguousImportsGo" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "ambiguousImportsGo" ((PCons (PTuple PWild (PTuple (PCon "None") PWild)) (PVar "rest")) (PVar "firstMid") (PVar "acc")) (EApp (EApp (EApp (EVar "ambiguousImportsGo") (EVar "rest")) (EVar "firstMid")) (EVar "acc")))
(DFunDef false "ambiguousImportsGo" ((PCons (PTuple (PVar "name") (PTuple (PCon "Some" (PVar "mid")) PWild)) (PVar "rest")) (PVar "firstMid") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "firstMid")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ambiguousImportsGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "mid")) (EVar "firstMid"))) (EVar "acc"))) (arm (PCon "Some" (PVar "seen")) () (EApp (EApp (EApp (EVar "ambiguousImportsGo") (EVar "rest")) (EVar "firstMid")) (EIf (EBinOp "==" (EVar "seen") (EVar "mid")) (EVar "acc") (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "acc")))))))
(DTypeSig false "ambiguousImportBinding" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "ExportBinding"))))
(DFunDef false "ambiguousImportBinding" ((PVar "mctx") PWild) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EApp (EApp (EVar "Unbound") (EVar "ambiguousImportTyvarId")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentLevel") "value")))) (DoExpr (ERecordCreate "ExportBinding" ((fa "xbScheme" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EListLit (EVar "ambiguousImportTyvarId"))) (EListLit)) (EListLit)) (EListLit)) (EVar "pureRow")) (EApp (EVar "TVar") (EVar "cell")))) (fa "xbStandalone" (EVar "None")) (fa "xbExtern" (EVar "False")))))))
(DTypeSig false "moduleImportSeed" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyCon "ExportBinding")))) (TyCon "ModuleSeed")))))
(DFunDef false "moduleImportSeed" ((PVar "mctx") (PVar "base") (PVar "imported")) (EBlock (DoLet false false (PVar "selected") (EApp (EApp (EApp (EApp (EVar "importedBindingWinners") (EVar "mctx")) (EVar "imported")) (EVar "omEmpty")) (EApp (EVar "ambiguousImports") (EVar "imported")))) (DoExpr (ERecordCreate "ModuleSeed" ((fa "msSchemes" (EBinOp "++" (EVar "base") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "name") (PVar "binding"))) (ETuple (EVar "name") (EFieldAccess (EVar "binding") "xbScheme")))) (EVar "selected")))) (fa "msImportedValues" (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "name") (PVar "binding"))) (EMatch (EFieldAccess (EVar "binding") "xbStandalone") (arm (PCon "Some" (PVar "scheme")) () (EListLit (ETuple (EVar "name") (EVar "scheme")))) (arm (PCon "None") () (EListLit))))) (EVar "selected"))) (EVar "omEmpty"))) (fa "msImportedNames" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "selected"))) (EVar "omEmpty"))) (fa "msImportedExterns" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "name") (PVar "binding"))) (EIf (EFieldAccess (EVar "binding") "xbExtern") (EListLit (EVar "name")) (EListLit)))) (EVar "selected"))) (EVar "omEmpty"))))))))
(DTypeSig false "aliasSchemes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "aliasSchemes" ((PVar "deps") (PVar "alias") (PVar "depSchemes")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "aliasSchemeEntry") (EVar "deps")) (EVar "alias"))) (EVar "depSchemes")))
(DTypeSig false "aliasSchemeEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyVar "a")) (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "aliasSchemeEntry" ((PVar "deps") (PVar "alias") (PTuple (PVar "k") (PVar "s"))) (EIf (EApp (EApp (EVar "isMangledExportOfAny") (EVar "deps")) (EVar "k")) (ETuple (EVar "k") (EVar "s")) (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "alias")) (EVar "k")) (EVar "s"))))
(DTypeSig false "isMangledFor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isMangledFor" ((PVar "mid") (PVar "k")) (EBlock (DoLet false false (PVar "pre") (EApp (EApp (EVar "mangledName") (EVar "mid")) (ELit (LString "")))) (DoLet false false (PVar "lp") (EApp (EVar "stringLength") (EVar "pre"))) (DoExpr (EBinOp "&&" (EBinOp "<=" (EVar "lp") (EApp (EVar "stringLength") (EVar "k"))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "lp")) (EVar "k")) (EVar "pre"))))))
(DTypeSig false "isMangledExportOfAny" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isMangledExportOfAny" ((PList) PWild) (EVar "False"))
(DFunDef false "isMangledExportOfAny" ((PCons (PTuple (PVar "m") (PVar "pubV")) (PVar "rest")) (PVar "k")) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EVar "isMangledFor") (EVar "m")) (EVar "k")) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "k")) (EVar "pubV")))) (EApp (EApp (EVar "isMangledExportOfAny") (EVar "rest")) (EVar "k"))))
(DTypeSig false "importFormSchemes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "importFormSchemes" ((PVar "deps") (PCon "UseAlias" PWild (PVar "alias")) (PVar "depSchemes")) (EApp (EApp (EApp (EVar "aliasSchemes") (EVar "deps")) (EVar "alias")) (EVar "depSchemes")))
(DFunDef false "importFormSchemes" (PWild (PVar "path") (PVar "depSchemes")) (EApp (EApp (EVar "importFormRows") (EVar "path")) (EVar "depSchemes")))
(DTypeSig false "renameAliasedMethods" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "renameAliasedMethods" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "coreEntry") (ETuple (ELit (LString "core")) (EApp (EVar "declMethodNames") (EVar "coreDecls")))) (DoLet false false (PVar "methodsPerMid") (EBinOp "::" (EVar "coreEntry") (EApp (EApp (EVar "methodsPerMidGo") (EListLit (EVar "coreEntry"))) (EVar "modules")))) (DoLet false false (PVar "admitted") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "mid") (PVar "prog"))) (ETuple (EVar "mid") (EApp (EApp (EVar "synthesizedAdmissions") (EVar "methodsPerMid")) (EVar "prog"))))) (EVar "modules"))) (EVar "omEmpty"))) (DoExpr (ETuple (EVar "admitted") (EApp (EApp (EMethodRef "map") (EApp (EVar "renameAliasedMethodsIn") (EVar "methodsPerMid"))) (EVar "modules"))))))
(DTypeSig false "admittedIn" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "admittedIn" ((PVar "gctx") (PVar "mid")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EFieldAccess (EVar "gctx") "graphAdmittedMethodsRef") "value"))))
(DTypeSig false "synthesizedAdmissions" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "synthesizedAdmissions" (PWild (PList)) (EListLit))
(DFunDef false "synthesizedAdmissions" ((PVar "mm") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "synthesizedAdmissions") (EVar "mm")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "synthesizedAdmissions" ((PVar "mm") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoLet false false (PVar "here") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "mm")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "methods")) () (EMatch (EVar "path") (arm (PCon "UseAlias" PWild PWild) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "mid") (EVar "n")))) (EVar "methods"))) (arm PWild () (EListLit)))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EVar "synthesizedAdmissions") (EVar "mm")) (EVar "rest"))))))
(DFunDef false "synthesizedAdmissions" ((PVar "mm") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "synthesizedAdmissions") (EVar "mm")) (EVar "rest")))
(DTypeSig false "methodsPerMidGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "methodsPerMidGo" (PWild (PList)) (EListLit))
(DFunDef false "methodsPerMidGo" ((PVar "acc") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EBlock (DoLet false false (PVar "entry") (ETuple (EVar "mid") (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "declMethodNames") (EVar "decls")) (EApp (EApp (EVar "reexportedMethodNames") (EVar "acc")) (EVar "decls")))))) (DoExpr (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "methodsPerMidGo") (EBinOp "::" (EVar "entry") (EVar "acc"))) (EVar "rest"))))))
(DTypeSig false "reexportedMethodNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reexportedMethodNames" ((PVar "acc") (PVar "ds")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "reexportedMethodsOf") (EVar "acc"))) (EApp (EVar "pubUsePaths") (EVar "ds"))))
(DTypeSig false "reexportedMethodsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reexportedMethodsOf" ((PVar "acc") (PVar "path")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "useModId") (EVar "path"))) (EVar "acc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "srcMethods")) () (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EVar "srcMethods")) (arm (PCon "Some" (PVar "bs")) () (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "srcMethods")))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "bs"))))))))
(DTypeSig false "renameAliasedMethodsIn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "renameAliasedMethodsIn" ((PVar "methodsPerMid") (PTuple (PVar "mid") (PVar "prog"))) (ETuple (EVar "mid") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "deAliasMethodImports") (EVar "methodsPerMid"))) (EVar "prog"))))
(DTypeSig false "deAliasMethodImports" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "deAliasMethodImports" ((PVar "mm") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "DAttrib") (EVar "attrs"))) (EApp (EApp (EVar "deAliasMethodImports") (EVar "mm")) (EVar "d"))))
(DFunDef false "deAliasMethodImports" ((PVar "mm") (PAs "d" (PCon "DUse" (PVar "pub") (PVar "path") (PVar "loc")))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "useModId") (EVar "path"))) (EVar "mm")) (arm (PCon "None") () (EListLit (EVar "d"))) (arm (PCon "Some" (PVar "methods")) () (EMatch (EVar "path") (arm (PCon "UseAlias" (PVar "quals") PWild) () (EMatch (EApp (EApp (EVar "methodMembersOf") (EVar "methods")) (EVar "loc")) (arm (PList) () (EListLit (EVar "d"))) (arm (PVar "mems") () (EListLit (EVar "d") (EApp (EApp (EApp (EVar "DUse") (EVar "pub")) (EApp (EApp (EVar "UseGroup") (EVar "quals")) (EVar "mems"))) (EVar "loc")))))) (arm PWild () (EListLit (EVar "d")))))))
(DFunDef false "deAliasMethodImports" (PWild (PVar "d")) (EListLit (EVar "d")))
(DTypeSig false "methodMembersOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyCon "UseMember")))))
(DFunDef false "methodMembersOf" ((PVar "methods") (PVar "loc")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "n")) (EVar "False")) (EVar "loc")) (EVar "None")))) (EVar "methods")))
(DTypeSig false "renameMethodVar" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "renameMethodVar" ((PVar "qualified") PWild (PAs "e" (PCon "EVar" (PVar "x")))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "qualified")) (arm (PCon "Some" (PVar "origin")) () (EApp (EVar "EVar") (EVar "origin"))) (arm (PCon "None") () (EVar "e"))))
(DFunDef false "renameMethodVar" ((PVar "qualified") PWild (PAs "e" (PCon "EVarId" (PVar "x") PWild))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "qualified")) (arm (PCon "Some" (PVar "origin")) () (EApp (EVar "EVar") (EVar "origin"))) (arm (PCon "None") () (EVar "e"))))
(DFunDef false "renameMethodVar" ((PVar "qualified") (PVar "members") (PAs "e" (PCon "EMethodAt" (PVar "x") (PVar "sym") (PVar "ev")))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "qualified")) (arm (PCon "Some" (PVar "origin")) () (EApp (EApp (EApp (EVar "EMethodAt") (EVar "origin")) (EVar "sym")) (EVar "ev"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "members")) (arm (PCon "Some" (PVar "origin")) () (EApp (EApp (EApp (EVar "EMethodAt") (EVar "origin")) (EVar "sym")) (EVar "ev"))) (arm (PCon "None") () (EVar "e"))))))
(DFunDef false "renameMethodVar" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "resolveAliasMethodSpellings" (TyFun (TyCon "GraphCtx") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "resolveAliasMethodSpellings" ((PVar "gctx") (PTuple (PVar "mid") (PVar "prog"))) (EBlock (DoLet false false (PVar "qualified") (EApp (EApp (EMethodRef "map") (EVar "aliasRowSpelling")) (EApp (EApp (EVar "useKeyCands") (EApp (EVar "moduleAliasKeys") (EVar "gctx"))) (EVar "prog")))) (DoLet false false (PVar "members") (EApp (EApp (EMethodRef "map") (EVar "aliasRowSpelling")) (EApp (EApp (EVar "memberAliasCands") (EVar "gctx")) (EVar "prog")))) (DoExpr (EMatch (ETuple (EVar "qualified") (EVar "members")) (arm (PTuple (PList) (PList)) () (ETuple (EVar "mid") (EVar "prog"))) (arm PWild () (ETuple (EVar "mid") (EApp (EApp (EVar "mapProg") (EApp (EApp (EVar "renameMethodVar") (EVar "qualified")) (EVar "members"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "deAliasMethodMembers") (EVar "members"))) (EVar "prog")))))))))
(DTypeSig false "deAliasMethodMembers" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "deAliasMethodMembers" ((PVar "rows") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "deAliasMethodMembers") (EVar "rows")) (EVar "d"))))
(DFunDef false "deAliasMethodMembers" ((PVar "rows") (PCon "DUse" (PVar "pub") (PCon "UseGroup" (PVar "quals") (PVar "ms")) (PVar "loc"))) (EApp (EApp (EApp (EVar "DUse") (EVar "pub")) (EApp (EApp (EVar "UseGroup") (EVar "quals")) (EApp (EApp (EMethodRef "map") (EApp (EVar "deAliasMethodMember") (EVar "rows"))) (EVar "ms")))) (EVar "loc")))
(DFunDef false "deAliasMethodMembers" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "deAliasMethodMember" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyCon "UseMember"))))
(DFunDef false "deAliasMethodMember" ((PVar "rows") (PAs "m" (PCon "UseMember" (PVar "n") (PVar "allCtors") (PVar "loc") (PCon "Some" (PVar "local"))))) (EIf (EApp (EApp (EVar "containsPair") (ETuple (EVar "local") (EVar "n"))) (EVar "rows")) (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "n")) (EVar "allCtors")) (EVar "loc")) (EVar "None")) (EIf (EVar "otherwise") (EVar "m") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "deAliasMethodMember" (PWild (PVar "m")) (EVar "m"))
(DTypeSig false "declMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declMethodNames" ((PVar "decls")) (EApp (EVar "dedup") (EApp (EApp (EDictApp "flatMap") (EVar "declMethodNamesOf")) (EVar "decls"))))
(DTypeSig false "declMethodNamesOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declMethodNamesOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declMethodNamesOf") (EVar "d")))
(DFunDef false "declMethodNamesOf" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EVar "ifaceMethodNames") (EVar "methods")))
(DFunDef false "declMethodNamesOf" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EVar "implMethodName")) (EVar "methods")))
(DFunDef false "declMethodNamesOf" (PWild) (EListLit))
(DTypeSig false "importSeed" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyVar "a"))))))))))
(DFunDef false "importSeed" ((PVar "gctx") PWild PWild (PList) PWild) (EListLit))
(DFunDef false "importSeed" ((PVar "gctx") (PVar "coreV") (PVar "admitted") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "depEnv")) (EApp (EApp (EApp (EApp (EApp (EVar "importSeed") (EVar "gctx")) (EVar "coreV")) (EVar "admitted")) (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "depEnv")))
(DFunDef false "importSeed" ((PVar "gctx") (PVar "coreV") (PVar "admitted") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "depEnv")) (EBlock (DoLet false false (PVar "depId") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "depId") (ELit (LString "core"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "suppliedBy") (EVar "None"))) (EApp (EApp (EVar "coreAliasSchemes") (EVar "path")) (EVar "coreV"))) (EApp (EApp (EApp (EApp (EApp (EVar "importSeed") (EVar "gctx")) (EVar "coreV")) (EVar "admitted")) (EVar "rest")) (EVar "depEnv"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "depId")) (EVar "depEnv")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "importSeed") (EVar "gctx")) (EVar "coreV")) (EVar "admitted")) (EVar "rest")) (EVar "depEnv"))) (arm (PCon "Some" (PVar "depSchemes")) () (EBlock (DoLet false false (PVar "bound") (EApp (EVar "boundNames") (EVar "path"))) (DoLet false false (PVar "decls") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "importFormRows") (EVar "path")) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "depId"))))) (EVar "omEmpty"))) (DoLet false false (PVar "methods") (EApp (EApp (EVar "identKeysByName") (EVar "omEmpty")) (EApp (EApp (EVar "importFormRows") (EVar "path")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "depId")) (EApp (EApp (EVar "methodExportsIndex") (EVar "gctx")) (ELit LUnit))) (arm (PCon "Some" (PVar "rows")) () (EVar "rows")) (arm (PCon "None") () (EListLit)))))) (DoExpr (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (EApp (EApp (EVar "suppliedBy") (EIf (EBinOp "&&" (EApp (EApp (EVar "bindsName") (EVar "bound")) (EApp (EVar "fst") (EVar "row"))) (EApp (EVar "not") (EApp (EApp (EVar "containsPair") (ETuple (EVar "depId") (EApp (EVar "fst") (EVar "row")))) (EVar "admitted")))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "importSupplierKey") (EVar "depId")) (EVar "decls")) (EVar "methods")) (EApp (EVar "fst") (EVar "row")))) (EVar "None"))) (EVar "row")))) (EApp (EApp (EApp (EVar "importFormSchemes") (EVar "depEnv")) (EVar "path")) (EVar "depSchemes"))) (EApp (EApp (EApp (EApp (EApp (EVar "importSeed") (EVar "gctx")) (EVar "coreV")) (EVar "admitted")) (EVar "rest")) (EVar "depEnv")))))))))))
(DFunDef false "importSeed" ((PVar "gctx") (PVar "coreV") (PVar "admitted") (PCons PWild (PVar "rest")) (PVar "depEnv")) (EApp (EApp (EApp (EApp (EApp (EVar "importSeed") (EVar "gctx")) (EVar "coreV")) (EVar "admitted")) (EVar "rest")) (EVar "depEnv")))
(DTypeSig false "importSupplierKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "importSupplierKey" ((PVar "depId") (PVar "decls") (PVar "methods") (PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "decls")) (arm (PCon "Some" (PTuple (PVar "defMid") (PVar "origin"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EVar "defMid")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EVar "origin")))) (ELit (LString "")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "methods")) (arm (PCon "Some" (PVar "keys")) () (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EVar "sortUniqS") (EVar "keys")))) (arm (PCon "None") () (EApp (EVar "lenKey") (EVar "depId")))))))
(DTypeSig false "identKeysByName" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "identKeysByName" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "identKeysByName" ((PVar "acc") (PCons (PTuple (PVar "n") (PVar "ident")) (PVar "rest"))) (EBlock (DoLet false false (PVar "seen") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "acc")) (arm (PCon "Some" (PVar "keys")) () (EVar "keys")) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EVar "identKeysByName") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "::" (EApp (EVar "identKey") (EVar "ident")) (EVar "seen"))) (EVar "acc"))) (EVar "rest")))))
(DTypeSig false "suppliedBy" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyVar "a")) (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyVar "a"))))))
(DFunDef false "suppliedBy" ((PVar "mid") (PTuple (PVar "name") (PVar "row"))) (ETuple (EVar "name") (ETuple (EVar "mid") (EVar "row"))))
(DTypeSig false "containsPair" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "containsPair" (PWild (PList)) (EVar "False"))
(DFunDef false "containsPair" ((PTuple (PVar "a") (PVar "b")) (PCons (PTuple (PVar "x") (PVar "y")) (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "x")) (EBinOp "==" (EVar "b") (EVar "y"))) (EApp (EApp (EVar "containsPair") (ETuple (EVar "a") (EVar "b"))) (EVar "rest"))))
(DTypeSig false "bindsName" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "bindsName" ((PCon "None") PWild) (EVar "True"))
(DFunDef false "bindsName" ((PCon "Some" (PVar "names")) (PVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "names")))
(DTypeSig false "coreAliasSchemes" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "coreAliasSchemes" ((PCon "UseAlias" PWild (PVar "a")) (PVar "coreV")) (EApp (EApp (EMethodRef "map") (EApp (EVar "coreQualScheme") (EVar "a"))) (EVar "coreV")))
(DFunDef false "coreAliasSchemes" ((PCon "UseGroup" PWild (PVar "ms")) (PVar "coreV")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "coreRenameScheme") (EVar "coreV"))) (EVar "ms")))
(DFunDef false "coreAliasSchemes" (PWild PWild) (EListLit))
(DTypeSig false "coreQualScheme" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyVar "a")) (TyTuple (TyCon "String") (TyVar "a")))))
(DFunDef false "coreQualScheme" ((PVar "a") (PTuple (PVar "k") (PVar "s"))) (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "k")) (EVar "s")))
(DTypeSig false "coreRenameScheme" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "coreRenameScheme" ((PVar "coreV") (PVar "m")) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "local")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "useMemberOrigin") (EVar "m"))) (EVar "coreV")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EListLit (ETuple (EVar "local") (EVar "s"))))))))
(DTypeSig false "reexportSeed" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "reexportSeed" ((PVar "coreV") (PVar "decls") (PVar "depEnv")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "reexportSeedOf") (EVar "coreV")) (EVar "depEnv"))) (EApp (EVar "pubUsePaths") (EVar "decls"))))
(DTypeSig false "reexportSeedOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "reexportSeedOf" ((PVar "coreV") (PVar "depEnv") (PVar "path")) (EBlock (DoLet false false (PVar "depId") (EApp (EVar "useModId") (EVar "path"))) (DoLet false false (PVar "src") (EIf (EBinOp "==" (EVar "depId") (ELit (LString "core"))) (EApp (EVar "Some") (EVar "coreV")) (EApp (EApp (EVar "lookupAssoc") (EVar "depId")) (EVar "depEnv")))) (DoExpr (EMatch (EVar "src") (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "depSchemes")) () (EApp (EApp (EApp (EVar "importFormSchemes") (EVar "depEnv")) (EVar "path")) (EVar "depSchemes")))))))
(DTypeSig false "foldModules" (TyFun (TyApp (TyApp (TyCon "FoldPlan") (TyVar "e")) (TyVar "acc")) (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "ModuleServe") (TyVar "e"))) (TyFun (TyVar "acc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyVar "acc") (TyApp (TyCon "Option") (TyApp (TyCon "ModuleServe") (TyVar "e"))) (TyCon "ModuleCtx")))))))))))
(DFunDef false "foldModules" ((PVar "plan") (PVar "serve") (PVar "base") (PVar "depEnv") (PVar "accData") (PVar "accAll") (PVar "prev") (PVar "modules")) (EBlock (DoLet false false (PTuple (PVar "done") (PVar "served") (PVar "last")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "workModules") (EVar "plan")) (EVar "serve")) (EVar "depEnv")) (EVar "accData")) (EVar "accAll")) (EListLit)) (EVar "prev")) (EVar "modules"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "collectModules") (EFieldAccess (EVar "plan") "fpCollect")) (EVar "base")) (EVar "done")) (EVar "served") (EVar "last")))))
(DTypeSig false "workModules" (TyFun (TyApp (TyApp (TyCon "FoldPlan") (TyVar "e")) (TyVar "acc")) (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "ModuleServe") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "e"))) (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "e"))) (TyApp (TyCon "Option") (TyApp (TyCon "ModuleServe") (TyVar "e"))) (TyCon "ModuleCtx")))))))))))
(DFunDef false "workModules" (PWild (PVar "serve") PWild PWild PWild (PVar "done") (PVar "prev") (PList)) (ETuple (EVar "done") (EVar "serve") (EVar "prev")))
(DFunDef false "workModules" ((PVar "plan") (PVar "serve") (PVar "depEnv") (PVar "accData") (PVar "accAll") (PVar "done") (PVar "prev") (PList (PTuple (PVar "mid") (PVar "prog")))) (EBlock (DoLet false false (PVar "seed") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "moduleSeedFor") (EVar "prev")) (EFieldAccess (EVar "plan") "fpBaseSeed")) (EFieldAccess (EVar "plan") "fpCoreV")) (EVar "mid")) (EVar "prog")) (EVar "depEnv"))) (DoLet false false (PTuple PWild (PVar "extra") (PVar "next")) (EApp (EApp (EApp (EApp (EApp (EApp (EFieldAccess (EVar "plan") "fpWorker") (EVar "prev")) (EVar "mid")) (EVar "seed")) (EVar "accData")) (EVar "accAll")) (EVar "prog"))) (DoExpr (ETuple (EBinOp "::" (ETuple (EVar "mid") (EVar "extra")) (EVar "done")) (EVar "serve") (EVar "next")))))
(DFunDef false "workModules" ((PVar "plan") (PVar "serve") (PVar "depEnv") (PVar "accData") (PVar "accAll") (PVar "done") (PVar "prev") (PCons (PTuple (PVar "mid") (PVar "prog")) (PVar "rest"))) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EMethodRef "map") (ELam ((PVar "policy")) (EApp (EApp (EApp (EFieldAccess (EVar "policy") "msStep") (EVar "mid")) (EVar "prog")) (EVar "prev")))) (EVar "serve"))) (DoLet false false (PTuple (PVar "own") (PVar "done2") (PVar "serve2") (PVar "next")) (EMatch (EVar "step") (arm (PCon "Some" (PCon "ServeHit" (PVar "own") (PVar "extra") (PVar "policy"))) () (ETuple (EVar "own") (EBinOp "::" (ETuple (EVar "mid") (EVar "extra")) (EVar "done")) (EApp (EVar "Some") (EVar "policy")) (EVar "prev"))) (arm PWild () (EBlock (DoLet false false (PVar "seed") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "moduleSeedFor") (EVar "prev")) (EFieldAccess (EVar "plan") "fpBaseSeed")) (EFieldAccess (EVar "plan") "fpCoreV")) (EVar "mid")) (EVar "prog")) (EVar "depEnv"))) (DoLet false false (PTuple (PVar "schemes") (PVar "extra") (PVar "next")) (EApp (EApp (EApp (EApp (EApp (EApp (EFieldAccess (EVar "plan") "fpWorker") (EVar "prev")) (EVar "mid")) (EVar "seed")) (EVar "accData")) (EVar "accAll")) (EVar "prog"))) (DoLet false false (PVar "own") (EApp (EApp (EVar "publicModuleExports") (EVar "prog")) (EVar "schemes"))) (DoExpr (EMatch (EVar "step") (arm (PCon "Some" (PCon "ServeCheck" (PVar "after"))) () (EBlock (DoLet false false (PTuple (PVar "done3") (PVar "policy")) (EApp (EApp (EApp (EVar "after") (EVar "next")) (EVar "own")) (EBinOp "::" (ETuple (EVar "mid") (EVar "extra")) (EVar "done")))) (DoExpr (ETuple (EVar "own") (EVar "done3") (EApp (EVar "Some") (EVar "policy")) (EVar "next"))))) (arm PWild () (ETuple (EVar "own") (EBinOp "::" (ETuple (EVar "mid") (EVar "extra")) (EVar "done")) (EVar "serve") (EVar "next"))))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "workModules") (EVar "plan")) (EVar "serve2")) (EBinOp "::" (ETuple (EVar "mid") (EBinOp "++" (EVar "own") (EApp (EApp (EApp (EVar "reexportSeed") (EFieldAccess (EVar "plan") "fpCoreV")) (EVar "prog")) (EVar "depEnv")))) (EVar "depEnv"))) (EMatch (EFieldAccess (EVar "plan") "fpAccumulate") (arm (PCon "AccumulateBoth") () (EBinOp "++" (EVar "accData") (EApp (EVar "publicDataDecls") (EVar "prog")))) (arm (PCon "AccumulateNone") () (EVar "accData")))) (EMatch (EFieldAccess (EVar "plan") "fpAccumulate") (arm (PCon "AccumulateBoth") () (EBinOp "++" (EVar "accAll") (EVar "prog"))) (arm (PCon "AccumulateNone") () (EVar "accAll")))) (EVar "done2")) (EVar "next")) (EVar "rest")))))
(DTypeSig false "moduleSeedFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))))) (TyCon "ModuleSeed"))))))))
(DFunDef false "moduleSeedFor" ((PVar "prev") (PVar "baseSeed") (PVar "coreV") (PVar "mid") (PVar "prog") (PVar "depEnv")) (EApp (EApp (EApp (EVar "moduleImportSeed") (EVar "prev")) (EVar "baseSeed")) (EApp (EApp (EApp (EApp (EApp (EVar "importSeed") (EFieldAccess (EVar "prev") "mcGraph")) (EVar "coreV")) (EApp (EApp (EVar "admittedIn") (EFieldAccess (EVar "prev") "mcGraph")) (EVar "mid"))) (EVar "prog")) (EVar "depEnv"))))
(DTypeSig false "collectModules" (TyFun (TyFun (TyCon "ModulePlace") (TyFun (TyCon "String") (TyFun (TyVar "e") (TyFun (TyVar "acc") (TyVar "acc"))))) (TyFun (TyVar "acc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "e"))) (TyVar "acc")))))
(DFunDef false "collectModules" (PWild (PVar "base") (PList)) (EVar "base"))
(DFunDef false "collectModules" ((PVar "collect") (PVar "base") (PCons (PTuple (PVar "mid") (PVar "extra")) (PVar "older"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PTuple (PVar "m") (PVar "x"))) (EApp (EApp (EApp (EApp (EVar "collect") (EVar "NotLastModule")) (EVar "m")) (EVar "x")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "collect") (EVar "LastModule")) (EVar "mid")) (EVar "extra")) (EVar "base"))) (EVar "older")))
(DTypeSig false "checkCoreMemoized" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyCon "ModuleCtx"))))))))
(DFunDef false "checkCoreMemoized" ((PVar "prev") (PVar "key") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "runtimeSeed")) (EBlock (DoLet false false (PVar "gctx") (EFieldAccess (EVar "prev") "mcGraph")) (DoLet false false (PVar "join") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoin")) (DoLet false false (PVar "cached") (EMatch (EVar "key") (arm (PCon "Some" (PVar "k")) () (EApp (EApp (EVar "preludeCacheHit") (EVar "k")) (EVar "join"))) (arm (PCon "None") () (EVar "None")))) (DoExpr (EMatch (EVar "cached") (arm (PCon "Some" (PVar "pi")) () (EApp (EApp (EApp (EVar "continueFromInterface") (EVar "gctx")) (EFieldAccess (EVar "gctx") "graphRun")) (EVar "pi"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "coreSchemes") PWild (PVar "coreCtx")) (EApp (EApp (EApp (EApp (EVar "checkModuleFull") (EVar "prev")) (EVar "runtimeSeed")) (EListLit)) (EVar "coreDecls"))) (DoExpr (EMatch (EApp (EVar "checkGraphFinish") (EVar "coreCtx")) (arm (PList) () (ELit LUnit)) (arm (PCons (PVar "f") PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "evidence hole in the prelude: ")) (EApp (EMethodRef "display") (EApp (EVar "tcMsg") (EFieldAccess (EVar "f") "dfDiag")))) (ELit (LString ""))))))) (DoLet false false (PVar "pi") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "freezeInterface") (EFieldAccess (EVar "gctx") "crossRun")) (EFieldAccess (EVar "gctx") "graphRun")) (EApp (EApp (EVar "externSigsToMap") (EVar "runtimeDecls")) (EVar "omEmpty"))) (EApp (EApp (EVar "publishCore") (EApp (EVar "coreOwnContexts") (EVar "coreCtx"))) (EFieldAccess (EVar "coreSchemes") "mbSchemes"))) (EApp (EApp (EVar "omMapValues") (ELam (PWild) (ELit LUnit))) (EFieldAccess (EVar "coreSchemes") "mbStandaloneSchemes"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "coreCtx") "mcCells") "invocationViewRef") "value"))) (DoExpr (EMatch (EVar "key") (arm (PCon "Some" (PVar "k")) () (EApp (EApp (EVar "seedPreludeInterface") (EVar "k")) (EListLit (ETuple (EListLit (EVar "join")) (EVar "pi"))))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EApp (EVar "continueFromInterface") (EVar "gctx")) (EApp (EVar "graphLineageRun") (EFieldAccess (EApp (EVar "internersOf") (EVar "gctx")) "lineage"))) (EVar "pi")))))))))
(DTypeSig false "continueFromInterface" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GraphRun") (TyFun (TyCon "PreludeInterface") (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyCon "ModuleCtx"))))))
(DFunDef false "continueFromInterface" ((PVar "gctx") (PVar "run") (PVar "pi")) (EBlock (DoLet false false (PTuple (PVar "bindings") (PVar "corePub") (PVar "cross") (PVar "seed")) (EApp (EApp (EVar "thawInterface") (EVar "gctx")) (EVar "pi"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "run") "tyvarCounter")) (EFieldAccess (EVar "seed") "grsTyvarNext"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "run") "effvarCounter")) (EFieldAccess (EVar "seed") "grsEffvarNext"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "run") "ctorExistentialsRef")) (EFieldAccess (EVar "seed") "grsCtorExistentials"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "run") "anyExistentialsRef")) (EFieldAccess (EVar "seed") "grsAnyExistentials"))) (DoLet false false (PVar "restored") (EVariantUpdate "GraphCtx" (EVar "gctx") ((fa "crossRun" (EVar "cross")) (fa "graphRun" (EVar "run")) (fa "builtinExternNamesRef" (EApp (EVar "Ref") (EApp (EApp (EVar "IdMap.union") (EFieldAccess (EVar "pi") "piExternNames")) (EFieldAccess (EFieldAccess (EVar "gctx") "builtinExternNamesRef") "value"))))))) (DoLet false false (PVar "mctx") (EApp (EVar "initialModuleCtx") (EVar "restored"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "invocationViewRef")) (EApp (EVar "readInvocationView") (EFieldAccess (EVar "pi") "piInvocationView")))) (DoExpr (ETuple (EVar "bindings") (EVar "corePub") (EVar "mctx")))))
(DTypeSig false "preludePreambleMemoRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")) (TyCon "PreludePreamble")))))
(DFunDef false "preludePreambleMemoRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig false "preludePreambleOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "DeclEnvModule") (TyCon "PreludePreamble")))))
(DFunDef false "preludePreambleOf" ((PVar "gctx") (PVar "coreDecls") (PVar "coreRow")) (ERecordCreate "PreludePreamble" ((fa "ppEnvAcc" (EApp (EApp (EApp (EVar "declEnvAccOf") (EVar "gctx")) (EListLit (EVar "coreRow"))) (EVar "emptyDeclEnvAcc"))) (fa "ppMangledFunDefs" (EApp (EApp (EVar "unitCarriesMangledFunDefs") (ELit (LString "core"))) (EApp (EVar "funDefs") (EVar "coreDecls")))) (fa "ppMarkFacts" (EApp (EVar "preludeMarkFactsOf") (EVar "coreDecls"))))))
(DTypeSig false "preludePreambleFor" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "DeclEnvModule") (TyCon "PreludePreamble"))))))
(DFunDef false "preludePreambleFor" ((PVar "gctx") (PCon "None") (PVar "coreDecls") (PVar "coreRow")) (EApp (EApp (EApp (EVar "preludePreambleOf") (EVar "gctx")) (EVar "coreDecls")) (EVar "coreRow")))
(DFunDef false "preludePreambleFor" ((PVar "gctx") (PCon "Some" (PVar "k")) (PVar "coreDecls") (PVar "coreRow")) (EMatch (EUnOp "!" (EVar "preludePreambleMemoRef")) (arm (PCon "Some" (PVar "entry")) () (EIf (EBinOp "==" (EApp (EVar "fst") (EVar "entry")) (ETuple (EVar "k") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoinProfile"))) (EApp (EVar "snd") (EVar "entry")) (EApp (EApp (EApp (EApp (EVar "preludePreambleStore") (EVar "gctx")) (EVar "k")) (EVar "coreDecls")) (EVar "coreRow")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "preludePreambleStore") (EVar "gctx")) (EVar "k")) (EVar "coreDecls")) (EVar "coreRow")))))
(DTypeSig false "preludePreambleStore" (TyFun (TyCon "GraphCtx") (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "DeclEnvModule") (TyCon "PreludePreamble"))))))
(DFunDef false "preludePreambleStore" ((PVar "gctx") (PVar "k") (PVar "coreDecls") (PVar "coreRow")) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "preludePreambleOf") (EVar "gctx")) (EVar "coreDecls")) (EVar "coreRow"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "preludePreambleMemoRef")) (EApp (EVar "Some") (ETuple (ETuple (EVar "k") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoinProfile")) (EVar "p"))))) (DoExpr (EVar "p"))))
(DTypeSig true "tcConfigOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "DriveInputs") (TyCon "TcConfig"))))
(DFunDef false "tcConfigOf" ((PVar "domains") (PVar "inputs")) (ERecordCreate "TcConfig" ((fa "tcIoJoin" (EApp (EApp (EVar "ioJoinAtoms") (EVar "domains")) (EFieldAccess (EVar "inputs") "diIoJoinGrants"))) (fa "tcIoJoinProfile" (EFieldAccess (EVar "inputs") "diProfileName")) (fa "tcStdlibOwned" (EFieldAccess (EVar "inputs") "diStdlibOwned")) (fa "tcFlatEntryIsStdlib" (EFieldAccess (EVar "inputs") "diFlatEntryIsStdlib")) (fa "tcKey" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "inputs") "diProfileName"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "inputs") "diFlatEntryIsStdlib"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EVar "omKeys") (EFieldAccess (EVar "inputs") "diStdlibOwned"))))) (ELit (LString "")))))))
(DTypeSig false "graphPreamble" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "GraphOut") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "GraphPreamble")))))))))
(DFunDef false "graphPreamble" ((PVar "inputs") (PVar "admitted") (PVar "sel") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EBlock (DoExpr (EMatch (EApp (EVar "heldPreludeEvCounter") (ELit LUnit)) (arm (PCon "Some" (PVar "k")) () (EBlock (DoLet false false (PVar "lineage") (EFieldAccess (EFieldAccess (EVar "interners") "value") "lineage")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "lineage") "lnEvCounter")) (EApp (EApp (EMethodRef "max") (EFieldAccess (EFieldAccess (EVar "lineage") "lnEvCounter") "value")) (EVar "k")))))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false (PVar "gctx") (EApp (EApp (EVar "mintGraphCtx") (EVar "inputs")) (EVar "admitted"))) (DoLet false false (PVar "initial") (EApp (EVar "initialModuleCtx") (EVar "gctx"))) (DoExpr (EApp (EApp (EApp (EVar "populateEffectDomainsGraph") (EVar "gctx")) (EVar "coreDecls")) (EVar "modules"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "config")) (EApp (EApp (EVar "tcConfigOf") (EFieldAccess (EFieldAccess (EVar "gctx") "effectDomains") "value")) (EVar "inputs")))) (DoLet false false (PVar "coreRow") (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "core"))) (EVar "coreDecls"))) (DoLet false false (PVar "modRows") (EApp (EApp (EApp (EVar "declEnvModulesFrom") (EVar "gctx")) (ELit (LInt 1))) (EVar "modules"))) (DoLet false false (PVar "prelude") (EApp (EApp (EApp (EApp (EVar "preludePreambleFor") (EVar "gctx")) (EVar "preludeKey")) (EVar "coreDecls")) (EVar "coreRow"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "mangledFunDefsPresentRef")) (EBinOp "||" (EFieldAccess (EVar "prelude") "ppMangledFunDefs") (EApp (EVar "graphCarriesMangledFunDefs") (EVar "modules"))))) (DoLet false false (PVar "declEnvs") (EApp (EApp (EApp (EApp (EVar "buildDeclEnvs") (EVar "gctx")) (EFieldAccess (EVar "prelude") "ppEnvAcc")) (EVar "coreRow")) (EVar "modRows"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "declEnvsRef")) (EVar "declEnvs"))) (DoLet false false (PVar "runtimeSeed") (EApp (EApp (EApp (EVar "withDeclParamKinds") (EVar "initial")) (EVar "coreDecls")) (ELam ((PVar "u")) (EApp (EApp (EApp (EVar "externSchemes") (EVar "initial")) (EApp (EVar "runtimeExternTyOriginScope") (EVar "coreDecls"))) (EVar "runtimeDecls"))))) (DoExpr (EApp (EApp (EApp (EVar "seedAbstractRecordTypes") (EVar "gctx")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "ms") (EApp (EApp (EApp (EApp (EApp (EVar "markSetsOf") (EVar "gctx")) (EFieldAccess (EVar "prelude") "ppMarkFacts")) (EVar "coreDecls")) (EVar "modules")) (EFieldAccess (EVar "declEnvs") "deAllDecls"))) (DoExpr (EApp (EApp (EVar "setDictEligible") (EVar "gctx")) (EApp (EVar "moduleUserFnNames") (EVar "modules")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "promotionHarvestRef")) (EListLit))) (DoLet false false (PTuple (PVar "coreSchemes") (PVar "corePub") (PVar "coreContexts") (PVar "coreTree") (PVar "coreCtx")) (EMatch (EVar "sel") (arm (PCon "GOutDiags") () (EBlock (DoLet false false (PTuple (PVar "bindings") (PVar "published") (PVar "coreCtx")) (EApp (EApp (EApp (EApp (EApp (EVar "checkCoreMemoized") (EVar "initial")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "runtimeSeed"))) (DoExpr (EApp (EVar "noteInterners") (EFieldAccess (EVar "coreCtx") "mcGraph"))) (DoExpr (ETuple (EVar "bindings") (EApp (EVar "Some") (EVar "published")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "coreCtx") "mcGraph") "crossRun") "coreSchemeObligationsRef") "value") (EListLit) (EVar "coreCtx"))))) (arm (PCon "GOutTrees") () (EMatch (EApp (EApp (EApp (EVar "treeArmHit") (EVar "inputs")) (EVar "coreDecls")) (EVar "gctx")) (arm (PCon "Some" (PTuple (PVar "pe") (PVar "pi"))) () (EBlock (DoLet false false (PTuple (PVar "bindings") (PVar "published") (PVar "coreCtx")) (EApp (EApp (EApp (EVar "continueFromInterface") (EVar "gctx")) (EFieldAccess (EVar "gctx") "graphRun")) (EVar "pi"))) (DoExpr (EApp (EVar "noteInterners") (EFieldAccess (EVar "coreCtx") "mcGraph"))) (DoExpr (ETuple (EVar "bindings") (EApp (EVar "Some") (EVar "published")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "coreCtx") "mcGraph") "crossRun") "coreSchemeObligationsRef") "value") (EFieldAccess (EVar "pe") "peDecls") (EVar "coreCtx"))))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "bindings") (PVar "tree") (PVar "coreCtx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "elabModuleStamp") (EVar "initial")) (ELit (LString ""))) (EVar "runtimeSeed")) (EListLit)) (EVar "coreDecls")) (EVar "coreDecls"))) (DoExpr (ETuple (EVar "bindings") (EVar "None") (EApp (EVar "coreOwnContexts") (EVar "coreCtx")) (EVar "tree") (EVar "coreCtx"))))))))) (DoExpr (ERecordCreate "GraphPreamble" ((fa "gpRuntimeSeed" (EVar "runtimeSeed")) (fa "gpCoreSchemes" (EVar "coreSchemes")) (fa "gpCorePub" (EVar "corePub")) (fa "gpCoreContexts" (EVar "coreContexts")) (fa "gpCoreTree" (EVar "coreTree")) (fa "gpMarkSets" (EVar "ms")) (fa "gpCoreCtx" (EVar "coreCtx")))))))
(DTypeSig false "treeArmElab" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "PreludeElab")))))
(DFunDef false "treeArmElab" ((PVar "inputs") (PVar "coreDecls")) (EMatch (EFieldAccess (EVar "inputs") "diPreludeKey") (arm (PCon "Some" (PVar "k")) () (EApp (EApp (EVar "preludeElabFor") (EVar "k")) (EVar "coreDecls"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "treeArmHit" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "GraphCtx") (TyApp (TyCon "Option") (TyTuple (TyCon "PreludeElab") (TyCon "PreludeInterface")))))))
(DFunDef false "treeArmHit" ((PVar "inputs") (PVar "coreDecls") (PVar "gctx")) (EApp (EApp (EMethodRef "andThen") (EFieldAccess (EVar "inputs") "diPreludeKey")) (ELam ((PVar "k")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "preludeCacheHit") (EVar "k")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcIoJoin"))) (ELam ((PVar "pi")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "treeArmElab") (EVar "inputs")) (EVar "coreDecls"))) (ELam ((PVar "pe")) (EApp (EVar "Some") (ETuple (EVar "pe") (EVar "pi"))))))))))
(DTypeSig false "checkModulesPreambleK" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "ModuleBindings") (TyCon "ModuleCtx"))))))))
(DFunDef false "checkModulesPreambleK" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "pre") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphPreamble") (EVar "inputs")) (EVar "omEmpty")) (EVar "GOutDiags")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoExpr (ETuple (EFieldAccess (EVar "pre") "gpRuntimeSeed") (EFieldAccess (EVar "pre") "gpCoreSchemes") (EFieldAccess (EVar "pre") "gpCoreCtx")))))
(DTypeSig false "cmCheckWorker" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "ModuleSeed") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyCon "ModuleCtx")))))))))
(DFunDef false "cmCheckWorker" ((PVar "prev") (PVar "mid") (PVar "seed") (PVar "_accData") (PVar "_accAll") (PVar "prog")) (EBlock (DoLet false false (PTuple (PVar "schemes") PWild (PVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkBodyImpl") (EFieldAccess (EVar "prev") "mcGraph")) (EApp (EVar "checkRunResidue") (EVar "prev"))) (EVar "seed")) (EVar "mid")) (EListLit)) (EVar "prog"))) (DoExpr (ETuple (EVar "schemes") (EApp (EApp (EVar "publishOwn") (EVar "mctx")) (EFieldAccess (EVar "schemes") "mbSchemes")) (EVar "mctx")))))
(DTypeSig true "checkModules" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))))))
(DFunDef false "checkModules" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesK") (EVar "inputs")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0")))
(DTypeSig true "checkModulesK" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))))))))
(DFunDef false "checkModulesK" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EBlock (DoLet false false (PTuple (PVar "coreDecls") (PVar "modules")) (EApp (EApp (EVar "stampGraphDecls") (EVar "coreDecls0")) (EVar "modules0"))) (DoLet false false (PTuple (PVar "runtimeSeed") (PVar "coreSchemes") (PVar "coreCtx")) (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesPreambleK") (EVar "inputs")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoExpr (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "cmFold") (EVar "runtimeSeed")) (EVar "coreSchemes")) (EVar "coreCtx")) (EVar "modules"))))))
(DTypeSig true "checkModulesPartialK" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "PartialAnalysis")))))))
(DFunDef false "checkModulesPartialK" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesPartialLast") (EVar "inputs")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0"))))
(DTypeSig true "checkModulesPartialLast" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "PartialAnalysis") (TyCon "ModuleCtx"))))))))
(DFunDef false "checkModulesPartialLast" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EBlock (DoLet false false (PTuple (PVar "coreDecls") (PVar "modules")) (EApp (EApp (EVar "stampGraphDecls") (EVar "coreDecls0")) (EVar "modules0"))) (DoLet false false (PRec "GraphPreamble" ((rf "gpRuntimeSeed" (PVar "runtimeSeed")) (rf "gpCoreSchemes" (PVar "coreSchemes")) (rf "gpCorePub" (PVar "coreClosed")) (rf "gpCoreContexts" (PVar "coreContexts")) (rf "gpCoreCtx" (PVar "coreCtx"))) true) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphPreamble") (EVar "inputs")) (EVar "omEmpty")) (EVar "GOutDiags")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PTuple (PVar "rows") (PVar "lastCtx")) (EApp (EApp (EApp (EApp (EVar "cmFold") (EVar "runtimeSeed")) (EVar "coreSchemes")) (EVar "coreCtx")) (EVar "modules"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "partialAnalysis") (EVar "rows")) (EApp (EApp (EApp (EVar "publishedCore") (EVar "coreClosed")) (EVar "coreContexts")) (EFieldAccess (EVar "coreSchemes") "mbSchemes"))) (EApp (EApp (EApp (EVar "captureEntryTables") (EVar "lastCtx")) (EVar "coreContexts")) (EVar "modules"))) (EVar "lastCtx")))))
(DTypeSig false "cmFold" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyCon "ModuleBindings") (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))) (TyCon "ModuleCtx")))))))
(DFunDef false "cmFold" ((PVar "runtimeSeed") (PVar "coreSchemes") (PVar "coreCtx") (PVar "modules")) (EBlock (DoLet false false (PTuple (PVar "rows") PWild (PVar "lastCtx")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "foldModules") (ERecordCreate "FoldPlan" ((fa "fpAccumulate" (EVar "AccumulateNone")) (fa "fpWorker" (EVar "cmCheckWorker")) (fa "fpCollect" (ELam ((PVar "_place") (PVar "mid") (PVar "schemes") (PVar "rest")) (EBinOp "::" (ETuple (EVar "mid") (EVar "schemes")) (EVar "rest")))) (fa "fpBaseSeed" (EBinOp "++" (EVar "runtimeSeed") (EFieldAccess (EVar "coreSchemes") "mbSchemes"))) (fa "fpCoreV" (EApp (EApp (EVar "tagModuleExports") (EFieldAccess (EVar "coreSchemes") "mbStandaloneSchemes")) (EFieldAccess (EVar "coreSchemes") "mbSchemes")))))) (EVar "None")) (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EVar "coreCtx")) (EVar "modules"))) (DoExpr (ETuple (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (ETuple (EApp (EVar "fst") (EVar "m")) (EApp (EVar "freezeRows") (EApp (EVar "snd") (EVar "m")))))) (EVar "rows")) (EVar "lastCtx")))))
(DTypeSig false "graphModuleWorker" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GraphOut") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "ModuleSeed") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleBindings") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "Option") (TyCon "InvocationView"))) (TyCon "ModuleCtx")))))))))))
(DFunDef false "graphModuleWorker" ((PVar "capture") (PVar "sel") (PVar "prev") (PVar "mid") (PVar "seed") (PVar "accData") (PVar "accAll") (PVar "prog")) (EBlock (DoLet false false (PVar "implDecls") (EBinOp "++" (EVar "accAll") (EVar "prog"))) (DoLet false false (PTuple (PVar "schemes") (PVar "marked") (PVar "errs") (PVar "warns") (PVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModuleFullDiags") (EFieldAccess (EVar "prev") "mcGraph")) (EVar "mid")) (EVar "seed")) (EVar "accData")) (EVar "implDecls")) (EVar "prog"))) (DoLet false false (PVar "published") (EApp (EApp (EVar "publishOwn") (EVar "mctx")) (EFieldAccess (EVar "schemes") "mbSchemes"))) (DoLet false false (PVar "tree") (EMatch (EVar "sel") (arm (PCon "GOutTrees") () (EBlock (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "main"))) (EFieldAccess (EVar "schemes") "mbSchemes")) (arm (PCon "Some" (PVar "sc")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "prev") "mcGraph") "mainSchemeRef")) (EApp (EVar "Some") (EVar "sc")))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "prev") "mcGraph") "promotionHarvestRef")) (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "prev") "mcGraph") "promotionHarvestRef") "value") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "promotedRef") "value"))))) (DoExpr (EVar "marked")))) (arm (PCon "GOutDiags") () (EListLit)))) (DoLet false false (PVar "view") (EIf (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EVar "capture")) (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "invocationViewRef") "value")) (EVar "None"))) (DoExpr (ETuple (EVar "schemes") (ETuple (EVar "tree") (EVar "published") (EVar "errs") (EVar "warns") (EVar "view")) (EVar "mctx")))))
(DTypeSig false "graphCollect" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "GraphOut") (TyFun (TyCon "ModulePlace") (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "Option") (TyCon "InvocationView"))) (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "InvocationView")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "InvocationView")))))))))))
(DFunDef false "graphCollect" ((PVar "gctx") (PVar "sel") (PVar "place") (PVar "mid") (PTuple (PVar "marked") (PVar "schemes") (PVar "errs") (PVar "warns") (PVar "view")) (PTuple (PVar "markedRest") (PVar "diagsRest") (PVar "views"))) (EBlock (DoExpr (EMatch (EVar "sel") (arm (PCon "GOutDiags") () (EApp (EApp (EApp (EVar "setMainSchemeIfEntry") (EVar "gctx")) (EVar "place")) (EVar "schemes"))) (arm (PCon "GOutTrees") () (ELit LUnit)))) (DoLet false false (PVar "markedOut") (EMatch (EVar "sel") (arm (PCon "GOutDiags") () (EVar "markedRest")) (arm (PCon "GOutTrees") () (EBinOp "::" (ETuple (EVar "mid") (EVar "marked")) (EVar "markedRest"))))) (DoExpr (ETuple (EVar "markedOut") (EBinOp "::" (ETuple (EVar "mid") (ETuple (EVar "schemes") (EVar "errs") (EVar "warns"))) (EVar "diagsRest")) (EApp (EApp (EApp (EVar "option") (EVar "views")) (ELam ((PVar "v")) (EBinOp "::" (ETuple (EVar "mid") (EVar "v")) (EVar "views")))) (EVar "view"))))))
(DTypeSig true "dropModSchemes" (TyFun (TyCon "ModDiags") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))
(DFunDef false "dropModSchemes" ((PTuple (PVar "mid") (PTuple PWild (PVar "errs") (PVar "warns")))) (ETuple (EVar "mid") (ETuple (EVar "errs") (EVar "warns"))))
(DTypeSig false "checkModulesEntryFromDiags" (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))
(DFunDef false "checkModulesEntryFromDiags" ((PList)) (ETuple (EListLit) (EListLit) (EListLit)))
(DFunDef false "checkModulesEntryFromDiags" ((PList (PTuple PWild (PTuple (PVar "s") (PVar "e") (PVar "w"))))) (ETuple (EVar "s") (EVar "e") (EVar "w")))
(DFunDef false "checkModulesEntryFromDiags" ((PCons (PTuple PWild (PTuple PWild (PVar "e") PWild)) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "eS") (PVar "eE") (PVar "eW")) (EApp (EVar "checkModulesEntryFromDiags") (EVar "rest"))) (DoExpr (ETuple (EVar "eS") (EBinOp "++" (EVar "e") (EVar "eE")) (EVar "eW")))))
(DTypeSig true "entryReportFromDiags" (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyCon "String")))
(DFunDef false "entryReportFromDiags" ((PVar "perMod")) (EMatch (EApp (EVar "checkModulesEntryFromDiags") (EVar "perMod")) (arm (PTuple (PVar "schemes") (PList) (PVar "warns")) () (EApp (EVar "joinNl") (EBinOp "++" (EApp (EVar "schemeLines") (EVar "schemes")) (EApp (EApp (EMethodRef "map") (EVar "tcMsg")) (EVar "warns"))))) (arm (PTuple PWild (PVar "errs") PWild) () (EApp (EVar "joinNl") (EApp (EVar "typeErrorLines") (EApp (EApp (EMethodRef "map") (EVar "tcMsg")) (EVar "errs")))))))
(DTypeSig false "setMainSchemeIfEntry" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ModulePlace") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyCon "Unit")))))
(DFunDef false "setMainSchemeIfEntry" ((PVar "gctx") (PCon "NotLastModule") PWild) (ELit LUnit))
(DFunDef false "setMainSchemeIfEntry" ((PVar "gctx") (PCon "LastModule") (PVar "schemes")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gctx") "mainSchemeRef")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EFieldAccess (EVar "p") "psScheme"))) (EApp (EApp (EVar "lookupAssoc") (ELit (LString "main"))) (EVar "schemes")))))
(DTypeSig true "chainFullKey" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "chainFullKey" ((PVar "rk") (PVar "ck") (PVar "chainKey")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "rk")))) (ELit (LString ","))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ck")))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "chainKey"))) (ELit (LString ""))))
(DTypeSig true "checkModulesDiagsChain" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ModDiags"))))))))))
(DFunDef false "checkModulesDiagsChain" ((PVar "inputs") (PVar "preludeKey") (PVar "chainKey") (PVar "stepKeys") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesDiagsChainFor") (EVar "inputs")) (EVar "False")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "stepKeys")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0")))
(DTypeSig false "checkModulesDiagsChainFor" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ModDiags")))))))))))
(DFunDef false "checkModulesDiagsChainFor" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "chainKey") (PVar "stepKeys") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EFieldAccess (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesChainReportFor") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "stepKeys")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0"))) "trDiagnostics"))
(DTypeSig true "checkModulesChainReportFor" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")))))))))))
(DFunDef false "checkModulesChainReportFor" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "chainKey") (PVar "stepKeys") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EVar "fst") (EApp (EVar "checkModulesChainReportForGraph") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "chainKey")) (EVar "stepKeys")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0")))))
(DTypeSig true "chainArgs" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "DriveArgs"))))))))))
(DFunDef false "chainArgs" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "chainKey") (PVar "stepKeys") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EBlock (DoLet false false (PVar "base") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0"))) (DoExpr (ERecordUpdate (EVar "base") ((fa "daKeyed" (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "rk") (PVar "ck"))) (ETuple (EApp (EApp (EApp (EVar "chainFullKey") (EVar "rk")) (EVar "ck")) (EVar "chainKey")) (EVar "stepKeys")))) (EVar "preludeKey"))))))))
(DTypeSig true "driveArgs" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "DriveArgs"))))))))
(DFunDef false "driveArgs" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DriveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "None")) (EVar "preludeKey")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0")))
(DTypeSig true "checkModulesChainReportForGraph" (TyFun (TyCon "DriveArgs") (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphCtx"))))
(DFunDef false "checkModulesChainReportForGraph" ((PVar "args")) (EBlock (DoLet false false (PVar "g") (EApp (EApp (EVar "driveGraphK") (EVar "GOutDiags")) (EVar "args"))) (DoExpr (ETuple (ETuple (EFieldAccess (EVar "g") "gdReport") (EFieldAccess (EVar "g") "gdOutputs")) (EFieldAccess (EVar "g") "gdGraph")))))
(DTypeSig false "serveOps" (TyCon "ServeOps"))
(DFunDef false "serveOps" () (ERecordCreate "ServeOps" ((fa "soDrain" (ELam ((PVar "mctx") (PVar "rows")) (EMatch (EApp (EVar "checkGraphFinish") (EVar "mctx")) (arm (PList) () (EVar "rows")) (arm (PVar "findings") () (EApp (EApp (EVar "attachDrainFindings") (EVar "findings")) (EVar "rows")))))) (fa "soUnboundIds" (EVar "monoUnboundIds")))))
(DTypeSig false "freezeFrom" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "ModDiags")))))
(DFunDef false "freezeFrom" ((PVar "n") (PVar "rows")) (EBinOp "++" (EApp (EApp (EVar "take") (EVar "n")) (EVar "rows")) (EApp (EApp (EMethodRef "map") (EVar "freezeModDiags")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "rows")))))
(DTypeSig false "buildDispositions" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "DeclEnvs") (TyCon "DispositionTable"))))
(DFunDef false "buildDispositions" ((PVar "gctx") (PVar "envs")) (EBlock (DoLet false false (PVar "impls") (EApp (EVar "ieRowsAll") (EFieldAccess (EVar "envs") "deImpls"))) (DoLet false false (PVar "table") (EApp (EApp (EVar "buildDispositionTableWithShapes") (EApp (EApp (EApp (EVar "dispositionRowsOfImpls") (EFieldAccess (EVar "envs") "deImpls")) (EVar "impls")) (EFieldAccess (EVar "envs") "deIfaces"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ifaceSuperCountOfRow") (EVar "gctx"))) (EVar "impls")))) (DoExpr (EApp (EApp (EVar "validateDispositionTable") (EApp (EApp (EVar "dispositionSlotsOfImpls") (EVar "impls")) (EFieldAccess (EVar "envs") "deIfaces"))) (EVar "table"))) (DoExpr (EVar "table"))))
(DTypeSig false "dispositionSlotsOfImpls" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyTuple (TyCon "InstId") (TyCon "IfaceRef") (TyCon "String"))))))
(DFunDef false "dispositionSlotsOfImpls" ((PList) PWild) (EListLit))
(DFunDef false "dispositionSlotsOfImpls" ((PCons (PVar "r") (PVar "rest")) (PVar "ce")) (EBlock (DoLet false false (PTuple (PVar "iface") PWild PWild) (EApp (EVar "ieRowTriple") (EVar "r"))) (DoLet false false (PVar "inst") (EApp (EApp (EVar "InstId") (EApp (EVar "instRefMid") (EApp (EVar "ieRowInst") (EVar "r")))) (EApp (EVar "instRefSeq") (EApp (EVar "ieRowInst") (EVar "r"))))) (DoLet false false (PVar "supplied") (EApp (EVar "ieRowMethodNames") (EVar "r"))) (DoLet false false (PVar "here") (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")))) (EApp (EVar "ieRowOrd") (EVar "r"))) (EVar "ce")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "ceRow")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (ETuple (EVar "inst") (EVar "iface") (EVar "m")))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "m")) (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "m")) (EVar "supplied")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "m")) (EApp (EVar "ceRowRequired") (EVar "ceRow"))))))) (EApp (EVar "ceRowMethodNames") (EVar "ceRow"))))))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EVar "dispositionSlotsOfImpls") (EVar "rest")) (EVar "ce"))))))
(DTypeSig false "dispositionRowsOfImpls" (TyFun (TyCon "ImplEnv") (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyTuple (TyCon "InstanceShape") (TyCon "String") (TyCon "MethodDisposition")))))))
(DFunDef false "dispositionRowsOfImpls" (PWild (PList) PWild) (EListLit))
(DFunDef false "dispositionRowsOfImpls" ((PVar "ie") (PCons (PVar "r") (PVar "rest")) (PVar "ce")) (EBinOp "++" (EApp (EApp (EApp (EVar "dispositionRowsOfImpl") (EVar "ie")) (EVar "r")) (EVar "ce")) (EApp (EApp (EApp (EVar "dispositionRowsOfImpls") (EVar "ie")) (EVar "rest")) (EVar "ce"))))
(DTypeSig false "dispositionRowsOfImpl" (TyFun (TyCon "ImplEnv") (TyFun (TyCon "ImplRow") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyTuple (TyCon "InstanceShape") (TyCon "String") (TyCon "MethodDisposition")))))))
(DFunDef false "dispositionRowsOfImpl" (PWild (PVar "r") (PVar "ce")) (EBlock (DoLet false false (PTuple (PVar "iface") (PVar "tys") PWild) (EApp (EVar "ieRowTriple") (EVar "r"))) (DoLet false false (PVar "inst") (EApp (EApp (EVar "InstId") (EApp (EVar "instRefMid") (EApp (EVar "ieRowInst") (EVar "r")))) (EApp (EVar "instRefSeq") (EApp (EVar "ieRowInst") (EVar "r"))))) (DoLet false false (PVar "ifaceWord") (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName"))) (DoLet false false (PVar "supplied") (EApp (EVar "ieRowMethodNames") (EVar "r"))) (DoLet false false (PVar "shape") (ERecordCreate "InstanceShape" ((fa "isWord" (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")) (EVar "tys")) (EVar "None"))) (fa "isTys" (EVar "tys"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")))) (EApp (EVar "ieRowOrd") (EVar "r"))) (EVar "ce")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "ceRow")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (ETuple (EVar "shape") (EVar "ifaceWord") (EVar "d")))) (EApp (EApp (EApp (EApp (EApp (EVar "dispositionRowsOfMethods") (EVar "inst")) (EVar "iface")) (EVar "supplied")) (EApp (EVar "ceRowRequired") (EVar "ceRow"))) (EApp (EVar "ceRowMethodNames") (EVar "ceRow")))))))))
(DTypeSig false "ifaceSuperCountOfRow" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ImplRow") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "ifaceSuperCountOfRow" ((PVar "gctx") (PVar "r")) (EBlock (DoLet false false (PTuple (PVar "iface") PWild PWild) (EApp (EVar "ieRowTriple") (EVar "r"))) (DoExpr (ETuple (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")) (EApp (EVar "listLen") (EApp (EApp (EApp (EVar "directSuperGoals") (EVar "gctx")) (EVar "iface")) (EListLit)))))))
(DTypeSig false "dispositionRowsOfMethods" (TyFun (TyCon "InstId") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodDisposition"))))))))
(DFunDef false "dispositionRowsOfMethods" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "dispositionRowsOfMethods" ((PVar "inst") (PVar "iface") (PVar "supplied") (PVar "required") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoLet false false (PVar "restRows") (EApp (EApp (EApp (EApp (EApp (EVar "dispositionRowsOfMethods") (EVar "inst")) (EVar "iface")) (EVar "supplied")) (EVar "required")) (EVar "rest"))) (DoExpr (EIf (EApp (EApp (EVar "contains") (EVar "m")) (EVar "supplied")) (EBinOp "::" (ERecordCreate "Supplied" ((fa "instance" (EVar "inst")) (fa "iface" (EVar "iface")) (fa "method" (EVar "m")))) (EVar "restRows")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "m")) (EVar "required"))) (EBinOp "::" (ERecordCreate "InheritedDefault" ((fa "instance" (EVar "inst")) (fa "iface" (EVar "iface")) (fa "method" (EVar "m")))) (EVar "restRows")) (EVar "restRows"))))))
(DTypeSig false "driveGraphK" (TyFun (TyCon "GraphOut") (TyFun (TyCon "DriveArgs") (TyCon "GraphDrive"))))
(DFunDef false "driveGraphK" ((PVar "sel") (PCon "DriveArgs" (PVar "inputs") (PVar "valueMain") (PVar "executes") (PVar "preludeKey") (PVar "keyed") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modulesIn"))) (EBlock (DoLet false false (PTuple (PVar "admitted") (PVar "modulesAliased")) (EApp (EApp (EVar "renameAliasedMethods") (EVar "coreDecls0")) (EVar "modulesIn"))) (DoLet false false (PTuple (PVar "coreDecls") (PVar "modules")) (EApp (EApp (EVar "stampGraphDecls") (EVar "coreDecls0")) (EVar "modulesAliased"))) (DoLet false false (PRec "GraphPreamble" ((rf "gpRuntimeSeed" (PVar "runtimeSeed")) (rf "gpCoreSchemes" (PVar "coreSchemes")) (rf "gpCorePub" (PVar "coreClosed")) (rf "gpCoreContexts" (PVar "coreContexts")) (rf "gpCoreTree" (PVar "coreTree")) (rf "gpMarkSets" (PVar "ms")) (rf "gpCoreCtx" (PVar "coreCtx"))) false) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphPreamble") (EVar "inputs")) (EVar "admitted")) (EVar "sel")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "capture") (EApp (EApp (EVar "requestedWrapperViewModules") (EFieldAccess (EVar "inputs") "diManifestRequests")) (EApp (EApp (EVar "manifestDriverFor") (EVar "inputs")) (EVar "executes")))) (DoLet false false (PVar "serve") (EApp (EApp (EMethodRef "map") (ELam ((PVar "k")) (EBlock (DoLet false false (PVar "st") (EApp (EApp (EApp (EApp (EApp (EVar "serveStateOf") (EVar "serveOps")) (EVar "capture")) (EFieldAccess (EVar "coreCtx") "mcGraph")) (EVar "modules")) (EVar "k"))) (DoExpr (EMatch (EVar "sel") (arm (PCon "GOutDiags") () (EApp (EVar "diagsServe") (EVar "st"))) (arm (PCon "GOutTrees") () (EApp (EVar "treeServe") (EVar "st")))))))) (EVar "keyed"))) (DoExpr (EIf (EApp (EVar "isSome") (EVar "serve")) (EApp (EVar "raiseToHighWater") (EFieldAccess (EVar "coreCtx") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "coreView") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "coreCtx") "mcCells") "invocationViewRef") "value")) (DoLet false false (PTuple (PTuple (PVar "modules2") (PVar "perModRaw") (PVar "views")) (PVar "served") (PVar "lastCtx")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "foldModules") (ERecordCreate "FoldPlan" ((fa "fpAccumulate" (EVar "AccumulateBoth")) (fa "fpWorker" (EApp (EApp (EVar "graphModuleWorker") (EVar "capture")) (EVar "sel"))) (fa "fpCollect" (EApp (EApp (EVar "graphCollect") (EFieldAccess (EVar "coreCtx") "mcGraph")) (EVar "sel"))) (fa "fpBaseSeed" (EBinOp "++" (EVar "runtimeSeed") (EFieldAccess (EVar "coreSchemes") "mbSchemes"))) (fa "fpCoreV" (EApp (EApp (EVar "tagModuleExports") (EFieldAccess (EVar "coreSchemes") "mbStandaloneSchemes")) (EFieldAccess (EVar "coreSchemes") "mbSchemes")))))) (EVar "serve")) (ETuple (EListLit) (EListLit) (EListLit))) (EListLit)) (EApp (EVar "publicDataDecls") (EVar "coreDecls"))) (EVar "coreDecls")) (EVar "coreCtx")) (EVar "modules"))) (DoLet false false (PVar "findings") (EIf (EApp (EVar "isSome") (EVar "serve")) (EApp (EVar "checkGraphFinish") (EVar "lastCtx")) (EApp (EVar "drainStampQueue") (EVar "lastCtx")))) (DoExpr (EIf (EApp (EVar "isSome") (EVar "serve")) (EApp (EVar "noteHighWater") (EFieldAccess (EVar "lastCtx") "mcGraph")) (ELit LUnit))) (DoLet false false (PVar "servedCount") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "policy")) (EFieldAccess (EVar "policy") "msServed"))) (EVar "served")))) (DoLet false false (PTuple (PVar "wanted") (PVar "autoPrint")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "autoPrintWanted") (EVar "lastCtx")) (EVar "valueMain")) (EVar "executes")) (EVar "findings")) (EVar "perModRaw")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "outcome") (EApp (EApp (EApp (EVar "entryOutcomeNow") (EVar "lastCtx")) (EApp (EVar "mainHasObligations") (EVar "lastCtx"))) (EVar "autoPrint"))) (DoLet false false (PVar "perMod") (EApp (EApp (EVar "attachCoherenceConflict") (EVar "lastCtx")) (EApp (EApp (EVar "attachDrainFindings") (EBinOp "++" (EVar "findings") (EVar "wanted"))) (EApp (EApp (EVar "freezeFrom") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "policy")) (EFieldAccess (EVar "policy") "msFrozen"))) (EVar "served")))) (EVar "perModRaw"))))) (DoLet false false (PVar "entryTables") (EApp (EApp (EApp (EVar "captureEntryTables") (EVar "lastCtx")) (EVar "coreContexts")) (EVar "modules"))) (DoLet false false (PVar "corePub") (EApp (EApp (EApp (EVar "publishedCore") (EVar "coreClosed")) (EVar "coreContexts")) (EFieldAccess (EVar "coreSchemes") "mbSchemes"))) (DoLet false false (PTuple (PVar "requests") (PVar "manifests") (PVar "manifestDiags")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "publishSelected") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "effectDomains") "value")) (EApp (EApp (EVar "invocationResolver") (EApp (EApp (EVar "frozenInvocationOps") (EVar "lastInvocationOps")) (EApp (EApp (EVar "driveOutputsNow") (EVar "lastCtx")) (EVar "outcome")))) (EApp (EApp (EApp (EVar "completionInvocationViews") (EVar "lastCtx")) (EVar "coreView")) (EVar "views")))) (EFieldAccess (EVar "inputs") "diManifestRequests")) (EVar "perMod")) (EVar "corePub")) (EVar "outcome")) (EApp (EApp (EVar "manifestDriverFor") (EVar "inputs")) (EVar "executes"))) (EVar "valueMain"))) (DoLet false false (PVar "dispositions") (EApp (EApp (EVar "buildDispositions") (EFieldAccess (EVar "lastCtx") "mcGraph")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "declEnvsRef") "value"))) (DoExpr (EMatch (EVar "sel") (arm (PCon "GOutDiags") () (ERecordCreate "GraphDrive" ((fa "gdPerMod" (EVar "perMod")) (fa "gdCoreSchemes" (EVar "corePub")) (fa "gdCoreContexts" (EVar "coreContexts")) (fa "gdCore" (EListLit)) (fa "gdModules" (EListLit)) (fa "gdResidual" (EListLit)) (fa "gdEvTable" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "graphRun") "evTable") "value")) (fa "gdDispositions" (EVar "dispositions")) (fa "gdBinders" (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "graphRun") "binderRows") "value")) (fa "gdReport" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphReportWithOutcome") (EVar "outcome")) (EVar "manifests")) (EVar "manifestDiags")) (EVar "perMod")) (EVar "corePub")) (EListLit)) (EApp (EVar "drivenEvidence") (EFieldAccess (EVar "lastCtx") "mcGraph"))) (EVar "dispositions")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "graphRun") "binderRows") "value")) (EVar "None")) (EVar "entryTables"))) (fa "gdGraph" (EFieldAccess (EVar "lastCtx") "mcGraph")) (fa "gdOutputs" (EApp (EApp (EApp (EVar "withPublishedManifests") (EVar "requests")) (EVar "manifests")) (ERecordUpdate (EApp (EApp (EVar "driveOutputsNow") (EVar "lastCtx")) (EVar "outcome")) ((fa "doServedModules" (EVar "servedCount"))))))))) (arm (PCon "GOutTrees") () (EBlock (DoLet false false (PVar "dictNames") (EApp (EApp (EApp (EApp (EVar "markDictNames") (EFieldAccess (EVar "lastCtx") "mcGraph")) (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EVar "ms") "msBareDictNames") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "promotionHarvestRef") "value")))) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "shipped") (EMatch (EVar "coreClosed") (arm (PCon "Some" PWild) () (EApp (EApp (EVar "treeArmElab") (EVar "inputs")) (EVar "coreDecls"))) (arm (PCon "None") () (EVar "None")))) (DoLet false false (PTuple (PVar "coreD") (PVar "modules3")) (EApp (EApp (EApp (EApp (EApp (EVar "dictPassModulesIfEnabled") (EVar "lastCtx")) (EVar "dictNames")) (EApp (EVar "isSome") (EVar "shipped"))) (EVar "coreTree")) (EVar "modules2"))) (DoLet false false (PVar "modulesOut") (EApp (EApp (EMethodRef "map") (EApp (EVar "resolveAliasMethodSpellings") (EFieldAccess (EVar "lastCtx") "mcGraph"))) (EVar "modules3"))) (DoLet false false (PVar "residual") (EApp (EVar "stickyDiagsInPushOrder") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "typeErrorsStickyDiags") "value"))) (DoLet false false (PTuple (PVar "evidence") (PVar "binders")) (EApp (EApp (EApp (EVar "withShippedRows") (EVar "shipped")) (EApp (EApp (EVar "drivenEvidence") (EFieldAccess (EVar "lastCtx") "mcGraph")) (ELit LUnit))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "lastCtx") "mcGraph") "graphRun") "binderRows") "value"))) (DoExpr (ERecordCreate "GraphDrive" ((fa "gdPerMod" (EVar "perMod")) (fa "gdCoreSchemes" (EVar "corePub")) (fa "gdCoreContexts" (EVar "coreContexts")) (fa "gdCore" (EVar "coreD")) (fa "gdModules" (EVar "modulesOut")) (fa "gdResidual" (EVar "residual")) (fa "gdEvTable" (EVar "evidence")) (fa "gdDispositions" (EVar "dispositions")) (fa "gdBinders" (EVar "binders")) (fa "gdReport" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphReportWithOutcome") (EVar "outcome")) (EVar "manifests")) (EVar "manifestDiags")) (EVar "perMod")) (EVar "corePub")) (EVar "residual")) (ELam (PWild) (EVar "evidence"))) (EVar "dispositions")) (EVar "binders")) (EApp (EVar "Some") (ETuple (EVar "coreD") (EVar "modulesOut")))) (EVar "entryTables"))) (fa "gdGraph" (EFieldAccess (EVar "lastCtx") "mcGraph")) (fa "gdOutputs" (EApp (EApp (EApp (EVar "withPublishedManifests") (EVar "requests")) (EVar "manifests")) (ERecordUpdate (EApp (EApp (EVar "driveOutputsNow") (EVar "lastCtx")) (EVar "outcome")) ((fa "doServedModules" (EVar "servedCount")))))))))))))))
(DTypeSig false "attachCoherenceConflict" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "ModDiags")))))
(DFunDef false "attachCoherenceConflict" ((PVar "mctx") (PVar "perMod")) (EMatch (EApp (EApp (EVar "globalCoherenceConflict") (EVar "mctx")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deImpls")) (arm (PTuple (PCon "None") (PCon "None")) () (EVar "perMod")) (arm (PTuple (PVar "hard") (PVar "soft")) () (EApp (EApp (EVar "attachEntryPayload") (EApp (EApp (EVar "cohOntoFull") (EVar "hard")) (EVar "soft"))) (EVar "perMod")))))
(DTypeSig false "cohOntoFull" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))))
(DFunDef false "cohOntoFull" ((PVar "hard") (PVar "soft") (PTuple (PVar "schemes") (PVar "errs") (PVar "warns"))) (ETuple (EVar "schemes") (EApp (EApp (EVar "prependConflict") (EVar "hard")) (EVar "errs")) (EApp (EApp (EVar "prependIncomparable") (EVar "soft")) (EVar "warns"))))
(DTypeSig false "attachEntryPayload" (TyFun (TyFun (TyVar "p") (TyVar "p")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "p"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "p"))))))
(DFunDef false "attachEntryPayload" (PWild (PList)) (EListLit))
(DFunDef false "attachEntryPayload" ((PVar "f") (PList (PTuple (PVar "mid") (PVar "p")))) (EListLit (ETuple (EVar "mid") (EApp (EVar "f") (EVar "p")))))
(DFunDef false "attachEntryPayload" ((PVar "f") (PCons (PVar "m") (PVar "rest"))) (EBinOp "::" (EVar "m") (EApp (EApp (EVar "attachEntryPayload") (EVar "f")) (EVar "rest"))))
(DTypeSig false "autoPrintWanted" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyApp (TyCon "Option") (TyCon "EvId")))))))))))
(DFunDef false "autoPrintWanted" ((PVar "mctx") (PCon "False") PWild PWild PWild PWild PWild) (ETuple (EListLit) (EVar "None")))
(DFunDef false "autoPrintWanted" ((PVar "mctx") (PCon "True") (PVar "executes") (PVar "findings") (PVar "perMod") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "decls") (EBinOp "++" (EVar "coreDecls") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules")))) (DoExpr (EMatch (ETuple (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "mainSchemeRef") "value") (EApp (EVar "last") (EVar "modules")) (EApp (EVar "printlnIface") (EVar "decls"))) (arm (PTuple (PCon "Some" (PVar "scheme")) (PCon "Some" (PTuple (PVar "mid") (PVar "entry"))) (PCon "Some" (PVar "iface"))) () (EIf (EApp (EApp (EApp (EVar "mainIsUnitNow") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "mainHasObligations") (EVar "mctx"))) (ELit LUnit)) (ETuple (EListLit) (EVar "None")) (EIf (EApp (EApp (EVar "mainIsAsyncNow") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit)) (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "asyncDriverFindings") (EVar "mctx")) (EVar "executes")) (EVar "mid")) (EVar "entry")) (EVar "scheme")) (EVar "perMod")) (EVar "None")) (EBlock (DoLet false false (PVar "scope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "None")) (ELit (LInt 0))) (EVar "mid")) (EVar "ModuleOwner"))) (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EVar "scope"))) (DoLet false false (PVar "loc") (EApp (EVar "mainBodySpan") (EVar "entry"))) (DoLet false false (PVar "atMain") (EApp (EApp (EVar "mctxAt") (EVar "loc")) (EVar "mctx"))) (DoLet false false (PVar "posed") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false (PVar "diags") (EApp (EApp (EVar "captureTypeErrors") (EVar "atMain")) (ELam (PWild) (EApp (EApp (EVar "setRef") (EVar "posed")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "judgeAutoPrintUse") (EVar "atMain")) (EVar "iface")) (EVar "scheme")) (EVar "loc"))))))) (DoLet false false (PVar "ev") (EMatch (ETuple (EVar "executes") (EVar "diags") (EFieldAccess (EVar "posed") "value")) (arm (PTuple (PCon "Some" PWild) (PList) (PCon "Some" (PVar "tau"))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "autoPrintEvidence") (EVar "atMain")) (EVar "mid")) (EVar "scope")) (EVar "iface")) (EVar "tau")))) (arm PWild () (EVar "None")))) (DoExpr (EApp (EApp (EVar "closeScope") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "reported") (EApp (EApp (EVar "driveErrs") (EVar "findings")) (EVar "perMod"))) (DoLet false false (PVar "kept") (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "d")) (EApp (EApp (EVar "inMainBinding") (EVar "entry")) (EApp (EVar "tcLoc") (EVar "d"))))) (EVar "reported")) (EApp (EVar "dropAmbiguity") (EVar "diags")) (EVar "diags"))) (DoExpr (ETuple (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "verdictFinding") (EVar "mid")) (EVar "False"))) (EBinOp "++" (EApp (EApp (EVar "mainUseDiags") (EVar "loc")) (EVar "entry")) (EVar "kept"))) (EVar "ev"))))))) (arm PWild () (ETuple (EListLit) (EVar "None")))))))
(DTypeSig false "driveErrs" (TyFun (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "TcDiag")))))
(DFunDef false "driveErrs" ((PVar "findings") (PVar "perMod")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EFieldAccess (EVar "f") "dfDiag"))) (EVar "findings")) (EApp (EApp (EDictApp "flatMap") (EVar "modDiagErrs")) (EVar "perMod"))))
(DTypeSig false "judgeAutoPrintUse" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Mono"))))))
(DFunDef false "judgeAutoPrintUse" ((PVar "mctx") (PVar "iface") (PVar "scheme") (PVar "loc")) (EApp (EApp (EApp (EVar "judgeMainUse") (EVar "mctx")) (ELam ((PVar "tau")) (EApp (EApp (EApp (EApp (EApp (EVar "recordObl") (EVar "mctx")) (ERecordCreate "Predicate" ((fa "iface" (EVar "iface")) (fa "args" (EListLit (EVar "tau")))))) (ELit (LInt 0))) (EVar "PCallSlot")) (EVar "loc")))) (EVar "scheme")))
(DTypeSig false "asyncDriverFindings" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "DrainFinding")))))))))
(DFunDef false "asyncDriverFindings" ((PVar "mctx") (PVar "executes") (PVar "mid") (PVar "entry") (PVar "scheme") (PVar "perMod")) (EBlock (DoLet false false (PVar "published") (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "async"))) (EVar "perMod")) (arm (PCon "Some" (PTuple (PVar "rows") PWild PWild)) () (EVar "rows")) (arm (PCon "None") () (EListLit)))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "option") (EVar "None")) (ELam ((PVar "d")) (EApp (EApp (EVar "lookupAssoc") (EVar "d")) (EVar "published")))) (EVar "executes")) (arm (PCon "Some" (PVar "driver")) ((GBool (EApp (EApp (EVar "mainAsyncPayloadIsUnitNow") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit)))) (EBlock (DoLet false false (PVar "scope") (EApp (EApp (EApp (EApp (EApp (EVar "Scopes.freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (EVar "None")) (ELit (LInt 0))) (EVar "mid")) (EVar "ModuleOwner"))) (DoExpr (EApp (EApp (EVar "openScope") (EVar "mctx")) (EVar "scope"))) (DoLet false false (PVar "atMain") (EApp (EApp (EVar "mctxAt") (EApp (EVar "mainBodySpan") (EVar "entry"))) (EVar "mctx"))) (DoLet false false (PVar "diags") (EApp (EApp (EVar "captureTypeErrors") (EVar "atMain")) (ELam (PWild) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "judgeMainUse") (EVar "atMain")) (EApp (EApp (EVar "asyncDriverUse") (EVar "atMain")) (EVar "driver"))) (EVar "scheme"))) (DoExpr (ELit LUnit)))))) (DoExpr (EApp (EApp (EVar "closeScope") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "verdictFinding") (EVar "mid")) (EVar "False"))) (EVar "diags"))))) (arm PWild () (EListLit))))))
(DTypeSig false "asyncDriverUse" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "PubScheme") (TyFun (TyCon "Mono") (TyCon "Unit")))))
(DFunDef false "asyncDriverUse" ((PVar "mctx") (PVar "driver") (PVar "tau")) (EBlock (DoLet false false (PTuple (PVar "driverTy") (PVar "subst")) (EApp (EApp (EVar "instantiateTracked") (EVar "mctx")) (EFieldAccess (EVar "driver") "psScheme"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EVar "mctx")) (ELit (LInt 0))) (EFieldAccess (EVar "driver") "psContext")) (EVar "subst"))) (DoExpr (EMatch (EApp (EVar "normalize") (EVar "driverTy")) (arm (PCon "TFun" (PVar "param") PWild PWild) () (EApp (EApp (EApp (EVar "unify") (EVar "mctx")) (EVar "param")) (EVar "tau"))) (arm PWild () (ELit LUnit))))))
(DTypeSig false "judgeMainUse" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "Mono") (TyCon "Unit")) (TyFun (TyCon "Scheme") (TyCon "Mono")))))
(DFunDef false "judgeMainUse" ((PVar "mctx") (PVar "pose") (PVar "scheme")) (EBlock (DoExpr (EApp (EApp (EVar "enterLevel") (EVar "mctx")) (ELit LUnit))) (DoLet false false (PVar "oblMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "implObls"))) (DoLet false false (PVar "callMark") (EApp (EVar "wMark") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "obls"))) (DoLet false false (PVar "dictMark") (EApp (EApp (EVar "goalsMark") (EFieldAccess (EVar "mctx") "mcGraph")) (ELit LUnit))) (DoLet false false (PTuple (PVar "tau0") (PVar "subst")) (EApp (EApp (EVar "instantiateTracked") (EVar "mctx")) (EVar "scheme"))) (DoLet false false (PVar "fresh") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "p")) (EApp (EVar "monoUnboundIds") (EApp (EVar "snd") (EVar "p"))))) (EVar "subst"))) (DoLet false false (PVar "held") (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "i")))) (EVar "fresh"))))) (EApp (EVar "dedupI") (EApp (EVar "monoUnboundIds") (EVar "tau0"))))) (DoLet false false (PVar "tau") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (ETuple (EVar "i") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))))) (EVar "held"))) (EListLit)) (EListLit)) (EVar "tau0"))) (DoLet false false (PVar "id") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (ELit (LString "main"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeDefIdsRef") "value")))) (DoLet false false (PVar "context") (EApp (EApp (EApp (EVar "lookupSchemeObls") (ELit (LString "main"))) (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value"))) (DoExpr (EApp (EVar "pose") (EVar "tau"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordSchemeCallObligations") (EVar "mctx")) (EVar "id")) (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "context"))) (EVar "subst"))) (DoExpr (EApp (EApp (EVar "exitLevel") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "settleClosedBody") (EVar "mctx")) (EApp (EVar "tconBuiltin") (ELit (LString "Unit")))) (EVar "oblMark")) (EVar "callMark")) (EVar "dictMark"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkCallObligationsU") (EVar "mctx")) (EVar "False")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "residualUnivRef") "value")) (EApp (EApp (EVar "callUOblsWindow") (EVar "mctx")) (EVar "callMark")))) (DoExpr (EVar "tau"))))
(DTypeSig false "autoPrintEvidence" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "ScopeId") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "Mono") (TyCon "EvId")))))))
(DFunDef false "autoPrintEvidence" ((PVar "mctx") (PVar "mid") (PVar "scope") (PVar "iface") (PVar "tau")) (EBlock (DoLet false false (PVar "routes") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "routesOfMonosTopV") (EApp (EVar "siteFor") (EVar "mctx"))) (ELit (LString ""))) (EVar "scope")) (EListLit (EVar "tau"))) (EListLit (EVar "iface"))) (EListLit (EListLit (EVar "tau"))))) (DoLet false false (PVar "g") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "n") (EFieldAccess (EFieldAccess (EVar "g") "evCounter") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evCounter")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoLet false false (PVar "ev") (EApp (EApp (EVar "EvId") (EVar "mid")) (EVar "n"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "evTable")) (EBinOp "::" (EApp (EApp (EVar "EvEntry") (EVar "ev")) (EApp (EVar "EvMany") (EVar "routes"))) (EFieldAccess (EFieldAccess (EVar "g") "evTable") "value")))) (DoExpr (EVar "ev"))))
(DTypeSig false "checkModulesEntryFull" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))
(DFunDef false "checkModulesEntryFull" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFullK") (EVar "inputs")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules")))
(DTypeSig false "checkModulesEntryFullK" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))))))
(DFunDef false "checkModulesEntryFullK" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PTuple PWild (PVar "schemes") (PVar "errs") (PVar "warns")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFullSplitK") (EVar "inputs")) (EVar "False")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoExpr (ETuple (EVar "schemes") (EVar "errs") (EVar "warns")))))
(DTypeSig false "checkModulesEntryFullSplitK" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))))
(DFunDef false "checkModulesEntryFullSplitK" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EVar "entrySplit") (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFullReportK") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0")))))
(DTypeSig true "entrySplit" (TyFun (TyCon "TcReport") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))
(DFunDef false "entrySplit" ((PVar "r")) (EBlock (DoLet false false (PTuple (PVar "schemes") (PVar "errs") (PVar "warns")) (EApp (EVar "checkModulesEntryFromDiags") (EFieldAccess (EVar "r") "trDiagnostics"))) (DoExpr (ETuple (EFieldAccess (EFieldAccess (EVar "r") "trPartial") "paCore") (EVar "schemes") (EVar "errs") (EVar "warns")))))
(DTypeSig true "checkModulesEntryFullReportK" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")))))))))
(DFunDef false "checkModulesEntryFullReportK" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0")) (EApp (EVar "fst") (EApp (EVar "checkModulesEntryFullReportKGraph") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modules0")))))
(DTypeSig false "checkModulesEntryFullReportKGraph" (TyFun (TyCon "DriveArgs") (TyTuple (TyTuple (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphCtx"))))
(DFunDef false "checkModulesEntryFullReportKGraph" ((PCon "DriveArgs" (PVar "inputs") (PVar "valueMain") PWild (PVar "preludeKey") PWild (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modules0"))) (EBlock (DoLet false false (PTuple (PVar "effectivePreludeKey") (PVar "effectiveCoreDecls0") (PVar "effectiveModules0")) (EMatch (EVar "modules0") (arm (PList (PTuple PWild (PVar "prog"))) () (EIf (EApp (EVar "programIsCore") (EVar "prog")) (ETuple (EVar "None") (EListLit) (EListLit (ETuple (ELit (LString "core")) (EVar "prog")))) (ETuple (EVar "preludeKey") (EVar "coreDecls0") (EVar "modules0")))) (arm PWild () (ETuple (EVar "preludeKey") (EVar "coreDecls0") (EVar "modules0"))))) (DoLet false false (PVar "g") (EApp (EApp (EVar "driveGraphK") (EVar "GOutDiags")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "effectivePreludeKey")) (EVar "runtimeDecls")) (EVar "effectiveCoreDecls0")) (EVar "effectiveModules0")))) (DoExpr (ETuple (ETuple (EFieldAccess (EVar "g") "gdReport") (EFieldAccess (EVar "g") "gdOutputs")) (EFieldAccess (EVar "g") "gdGraph")))))
(DTypeSig true "checkModulesEntryReport" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))))
(DFunDef false "checkModulesEntryReport" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "checkModulesEntryReportOut") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))))
(DTypeSig false "checkModulesEntryReportOut" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "String") (TyCon "DriveOutputs")))))))
(DFunDef false "checkModulesEntryReportOut" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PTuple (PVar "report") (PVar "outputs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFullReportK") (EVar "inputs")) (EVar "False")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PTuple PWild (PVar "schemes") (PVar "errs") (PVar "warns")) (EApp (EVar "entrySplit") (EVar "report"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (ETuple (EApp (EVar "joinNl") (EBinOp "++" (EApp (EVar "schemeLines") (EVar "schemes")) (EApp (EApp (EMethodRef "map") (EVar "tcMsg")) (EVar "warns")))) (EVar "outputs"))) (arm PWild () (ETuple (EApp (EVar "joinNl") (EApp (EVar "typeErrorLines") (EApp (EApp (EMethodRef "map") (EVar "tcMsg")) (EVar "errs")))) (EVar "outputs")))))))
(DTypeSig false "checkModulesEntryHasErrors" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool"))))))
(DFunDef false "checkModulesEntryHasErrors" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PTuple PWild (PVar "errs") PWild) (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFull") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "False")) (arm PWild () (EVar "True"))))))
(DTypeSig true "checkOneScheme" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))))))))
(DFunDef false "checkOneScheme" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EBlock (DoLet false false (PTuple (PVar "schemes") PWild PWild) (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFull") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog"))))) (DoExpr (EApp (EVar "pubSchemes") (EVar "schemes")))))
(DTypeSig true "checkOneSchemeFullK" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))))))
(DFunDef false "checkOneSchemeFullK" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "prog")) (EApp (EVar "fst") (EApp (EVar "checkOneSchemeFullKGraph") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveArgs") (EVar "inputs")) (EVar "False")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EListLit (EVar "prog"))))))
(DTypeSig true "checkOneSchemeFullKGraph" (TyFun (TyCon "DriveArgs") (TyTuple (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (TyCon "GraphCtx"))))
(DFunDef false "checkOneSchemeFullKGraph" ((PVar "args")) (EBlock (DoLet false false (PTuple (PVar "report") (PVar "gctx")) (EApp (EVar "checkOneReportKGraph") (EVar "args"))) (DoLet false false (PTuple (PVar "coreSchemes") (PVar "schemes") PWild PWild) (EApp (EVar "entrySplit") (EVar "report"))) (DoExpr (ETuple (ETuple (EVar "coreSchemes") (EVar "schemes")) (EVar "gctx")))))
(DTypeSig true "checkOneDiags" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))
(DFunDef false "checkOneDiags" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkOneDiagsK") (EVar "inputs")) (EVar "False")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "prog")))
(DTypeSig true "checkOneDiagsGraph" (TyFun (TyCon "DriveArgs") (TyTuple (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))) (TyCon "GraphCtx"))))
(DFunDef false "checkOneDiagsGraph" ((PVar "args")) (EBlock (DoLet false false (PTuple (PVar "report") (PVar "gctx")) (EApp (EVar "checkOneReportKGraph") (EVar "args"))) (DoLet false false (PTuple PWild PWild (PVar "errs") (PVar "warns")) (EApp (EVar "entrySplit") (EVar "report"))) (DoExpr (ETuple (ETuple (EVar "errs") (EVar "warns")) (EVar "gctx")))))
(DTypeSig false "checkOneDiagsK" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))))
(DFunDef false "checkOneDiagsK" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "prog")) (EBlock (DoLet false false (PTuple PWild PWild (PVar "errs") (PVar "warns")) (EApp (EVar "entrySplit") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkOneReportK") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "prog")))) (DoExpr (ETuple (EVar "errs") (EVar "warns")))))
(DTypeSig true "checkOneReportK" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "TcReport"))))))))
(DFunDef false "checkOneReportK" ((PVar "inputs") (PVar "valueMain") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "prog")) (EApp (EVar "fst") (EApp (EVar "checkOneReportKGraph") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "driveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EListLit (EVar "prog"))))))
(DTypeSig false "checkOneReportKGraph" (TyFun (TyCon "DriveArgs") (TyTuple (TyCon "TcReport") (TyCon "GraphCtx"))))
(DFunDef false "checkOneReportKGraph" ((PVar "args")) (EBlock (DoLet false false (PTuple (PTuple (PVar "report") PWild) (PVar "gctx")) (EApp (EVar "checkModulesEntryFullReportKGraph") (EVar "args"))) (DoExpr (ETuple (EVar "report") (EVar "gctx")))))
(DTypeSig true "checkOneToLinesWithRuntime" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "String") (TyCon "DriveOutputs")))))))
(DFunDef false "checkOneToLinesWithRuntime" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreProg") (PVar "userProg")) (EApp (EApp (EApp (EApp (EVar "checkModulesEntryReportOut") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreProg")) (EListLit (ETuple (ELit (LString "__user__")) (EVar "userProg")))))
(DTypeSig true "checkOneToLinesWithRuntimeK" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))))
(DFunDef false "checkOneToLinesWithRuntimeK" ((PVar "inputs") (PVar "preludeKey") (PVar "runtimeDecls") (PVar "coreProg") (PVar "userProg")) (EBlock (DoLet false false (PTuple (PVar "schemes") (PVar "errs") (PVar "warns")) (EApp (EApp (EApp (EApp (EApp (EVar "checkModulesEntryFullK") (EVar "inputs")) (EVar "preludeKey")) (EVar "runtimeDecls")) (EVar "coreProg")) (EListLit (ETuple (ELit (LString "__user__")) (EVar "userProg"))))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EApp (EVar "joinNl") (EBinOp "++" (EApp (EVar "schemeLines") (EVar "schemes")) (EApp (EApp (EMethodRef "map") (EVar "tcMsg")) (EVar "warns"))))) (arm PWild () (EApp (EVar "joinNl") (EApp (EVar "typeErrorLines") (EApp (EApp (EMethodRef "map") (EVar "tcMsg")) (EVar "errs")))))))))
(DTypeSig true "checkOneToLines" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "checkOneToLines" ((PVar "inputs") (PVar "userProg")) (EApp (EVar "fst") (EApp (EApp (EApp (EApp (EVar "checkOneToLinesWithRuntime") (EVar "inputs")) (EListLit)) (EListLit)) (EVar "userProg"))))
(DTypeSig true "checkOneErrorsWithRuntime" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))))
(DFunDef false "checkOneErrorsWithRuntime" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreProg") (PVar "userProg")) (EApp (EApp (EApp (EApp (EVar "checkModulesEntryHasErrors") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreProg")) (EListLit (ETuple (ELit (LString "__user__")) (EVar "userProg")))))
(DTypeSig true "checkOneMatchToLines" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))
(DFunDef false "checkOneMatchToLines" ((PVar "inputs") (PVar "runtimeDecls") (PVar "prog")) (EBlock (DoLet false false (PTuple PWild (PVar "warns")) (EApp (EApp (EApp (EApp (EVar "checkOneDiags") (EVar "inputs")) (EVar "runtimeDecls")) (EListLit)) (ETuple (ELit (LString "__user__")) (EVar "prog")))) (DoExpr (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "tcMsg")) (EVar "warns"))))))
(DTypeSig true "checkModulesEntryLines" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))))
(DFunDef false "checkModulesEntryLines" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EApp (EVar "joinNl") (EApp (EVar "schemeLines") (EApp (EVar "publishedEntrySchemes") (EApp (EApp (EApp (EApp (EVar "checkModules") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules"))))))
(DTypeSig true "checkModulesAllLines" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))))
(DFunDef false "checkModulesAllLines" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "modules")) (EApp (EVar "joinNl") (EApp (EVar "allModuleLines") (EApp (EApp (EApp (EApp (EVar "checkModules") (EVar "inputs")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "modules")))))
(DTypeSig false "allModuleLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allModuleLines" ((PList)) (EListLit))
(DFunDef false "allModuleLines" ((PCons (PTuple (PVar "mid") (PVar "ss")) (PVar "rest"))) (EBinOp "::" (EBinOp "++" (ELit (LString "## MODULE ")) (EVar "mid")) (EBinOp "++" (EApp (EVar "schemeLines") (EVar "ss")) (EApp (EVar "allModuleLines") (EVar "rest")))))
(DTypeSig true "elaborateModules" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ElabResult"))))))
(DFunDef false "elaborateModules" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modulesIn")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "elaborateModulesWithSchemes") (EVar "inputs")) (EVar "False")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modulesIn")) (arm (PTuple (PVar "result") PWild PWild) () (EVar "result"))))
(DTypeSig true "elaborateModulesGraph" (TyFun (TyCon "DriveArgs") (TyTuple (TyCon "ElabResult") (TyCon "GraphCtx"))))
(DFunDef false "elaborateModulesGraph" ((PVar "args")) (EBlock (DoLet false false (PTuple (PTuple (PVar "result") PWild PWild) (PVar "gctx")) (EApp (EVar "elabTreesDrive") (EVar "args"))) (DoExpr (ETuple (EVar "result") (EVar "gctx")))))
(DTypeSig true "elaborateModulesWithSchemes" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "ElabResult") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))))))
(DFunDef false "elaborateModulesWithSchemes" ((PVar "inputs") (PVar "valueMain") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modulesIn")) (EBlock (DoLet false false (PTuple (PVar "result") (PVar "r") PWild) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "elaborateModulesWithReport") (EVar "inputs")) (EVar "valueMain")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modulesIn"))) (DoLet false false (PTuple (PVar "core") (PVar "entrySchemes") PWild PWild) (EApp (EVar "entrySplit") (EVar "r"))) (DoExpr (ETuple (EVar "result") (EVar "core") (EVar "entrySchemes")))))
(DTypeSig true "elaborateModulesWithReport" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "ElabResult") (TyCon "TcReport") (TyCon "DriveOutputs")))))))))
(DFunDef false "elaborateModulesWithReport" ((PVar "inputs") (PVar "valueMain") (PVar "executes") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modulesIn")) (EApp (EVar "fst") (EApp (EVar "elabTreesDrive") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DriveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "executes")) (EVar "None")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modulesIn")))))
(DTypeSig true "elaborateModulesChainReport" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "ElabResult") (TyCon "TcReport") (TyCon "DriveOutputs")))))))))))
(DFunDef false "elaborateModulesChainReport" ((PVar "inputs") (PVar "valueMain") (PTuple (PVar "rk") (PVar "ck")) (PVar "chainKey") (PVar "stepKeys") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modulesIn")) (EApp (EVar "fst") (EApp (EVar "elabTreesDrive") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DriveArgs") (EVar "inputs")) (EVar "valueMain")) (EVar "None")) (EVar "None")) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EVar "chainFullKey") (EVar "rk")) (EVar "ck")) (EVar "chainKey")) (EVar "stepKeys")))) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modulesIn")))))
(DTypeSig false "elabTreesDrive" (TyFun (TyCon "DriveArgs") (TyTuple (TyTuple (TyCon "ElabResult") (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphCtx"))))
(DFunDef false "elabTreesDrive" ((PVar "args")) (EApp (EVar "elabDriveResult") (EApp (EApp (EVar "driveGraphK") (EVar "GOutTrees")) (EVar "args"))))
(DTypeSig false "elabDriveResult" (TyFun (TyCon "GraphDrive") (TyTuple (TyTuple (TyCon "ElabResult") (TyCon "TcReport") (TyCon "DriveOutputs")) (TyCon "GraphCtx"))))
(DFunDef false "elabDriveResult" ((PVar "g")) (ETuple (ETuple (ERecordCreate "ElabResult" ((fa "erCore" (EFieldAccess (EVar "g") "gdCore")) (fa "erModules" (EFieldAccess (EVar "g") "gdModules")) (fa "erPerModule" (EApp (EApp (EMethodRef "map") (EVar "dropModSchemes")) (EFieldAccess (EVar "g") "gdPerMod"))) (fa "erResidual" (EFieldAccess (EVar "g") "gdResidual")) (fa "erEvidence" (EFieldAccess (EVar "g") "gdEvTable")) (fa "erDispositions" (EFieldAccess (EVar "g") "gdDispositions")) (fa "erFacts" (ERecordCreate "ElabFacts" ((fa "efManifests" (EFieldAccess (EFieldAccess (EVar "g") "gdOutputs") "doManifests")) (fa "efBinders" (EFieldAccess (EVar "g") "gdBinders")) (fa "efEntryOutcome" (EFieldAccess (EFieldAccess (EVar "g") "gdOutputs") "doEntryOutcome"))))))) (EFieldAccess (EVar "g") "gdReport") (EFieldAccess (EVar "g") "gdOutputs")) (EFieldAccess (EVar "g") "gdGraph")))
(DTypeSig true "elaborateModulesReport" (TyFun (TyCon "DriveInputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "TcReport"))))))
(DFunDef false "elaborateModulesReport" ((PVar "inputs") (PVar "runtimeDecls") (PVar "coreDecls0") (PVar "modulesIn")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "elaborateModulesWithReport") (EVar "inputs")) (EVar "False")) (EVar "None")) (EVar "runtimeDecls")) (EVar "coreDecls0")) (EVar "modulesIn")) (arm (PTuple PWild (PVar "report") PWild) () (EVar "report"))))
(DTypeSig false "attachDrainFindings" (TyFun (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "ModDiags")))))
(DFunDef false "attachDrainFindings" ((PList) (PVar "perMod")) (EVar "perMod"))
(DFunDef false "attachDrainFindings" ((PVar "findings") (PVar "perMod")) (EBlock (DoLet false false (PVar "orphans") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "pm")) (EBinOp "==" (EApp (EVar "fst") (EVar "pm")) (EFieldAccess (EVar "f") "dfModule")))) (EVar "perMod"))))) (EVar "findings"))) (DoExpr (EMatch (EVar "orphans") (arm (PList) () (ELit LUnit)) (arm (PCons (PVar "f") PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence hole in module `")) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "dfModule"))) (ELit (LString "`, which has no diagnostics list: "))) (EApp (EMethodRef "display") (EApp (EVar "tcMsg") (EFieldAccess (EVar "f") "dfDiag")))) (ELit (LString ""))))))) (DoLet false false (PVar "erred") (EApp (EApp (EVar "anyList") (ELam ((PVar "pm")) (EApp (EVar "isNonEmptyL") (EApp (EVar "modDiagErrs") (EVar "pm"))))) (EVar "perMod"))) (DoLet false false (PVar "kept") (EIf (EVar "erred") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EFieldAccess (EVar "f") "dfLive")))) (EVar "findings")) (EVar "findings"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "pm")) (EApp (EApp (EVar "findingsOnto") (EVar "kept")) (EVar "pm")))) (EVar "perMod")))))
(DTypeSig false "modDiagErrs" (TyFun (TyCon "ModDiags") (TyApp (TyCon "List") (TyCon "TcDiag"))))
(DFunDef false "modDiagErrs" ((PTuple PWild (PTuple PWild (PVar "errs") PWild))) (EVar "errs"))
(DTypeSig false "findingsOnto" (TyFun (TyApp (TyCon "List") (TyCon "DrainFinding")) (TyFun (TyCon "ModDiags") (TyCon "ModDiags"))))
(DFunDef false "findingsOnto" ((PVar "findings") (PTuple (PVar "mid") (PTuple (PVar "schemes") (PVar "errs") (PVar "warns")))) (EBlock (DoLet false false (PVar "mine") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EBinOp "==" (EFieldAccess (EVar "f") "dfModule") (EVar "mid")))) (EVar "findings"))) (DoLet false false (PVar "verdicts") (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EFieldAccess (EVar "f") "dfDiag"))) (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EFieldAccess (EVar "f") "dfVerdict"))) (EVar "mine")))) (DoExpr (EMatch (EBinOp "++" (EVar "errs") (EVar "verdicts")) (arm (PList) () (ETuple (EVar "mid") (ETuple (EVar "schemes") (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EFieldAccess (EVar "f") "dfDiag"))) (EVar "mine")) (EVar "warns")))) (arm (PVar "all") () (ETuple (EVar "mid") (ETuple (EVar "schemes") (EDictApp "all") (EVar "warns"))))))))
(DTypeSig false "preludeMarkFactsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "PreludeMarkFacts")))
(DFunDef false "preludeMarkFactsOf" ((PVar "coreDecls")) (ERecordCreate "PreludeMarkFacts" ((fa "pmfReturnPos" (EApp (EVar "returnPosMethodNames") (EVar "coreDecls"))) (fa "pmfMethodConstraints" (EApp (EVar "methodConstraintNames") (EVar "coreDecls"))) (fa "pmfArgDispatch" (EApp (EVar "argDispatchIndices") (EVar "coreDecls"))) (fa "pmfArgDispatchById" (EApp (EVar "argDispatchIndicesById") (EVar "coreDecls"))) (fa "pmfConstrainedNames" (EApp (EVar "constrainedSigNames") (EVar "coreDecls"))))))
(DTypeSig true "schemeLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "schemeLines" ((PList)) (EListLit))
(DFunDef false "schemeLines" ((PCons (PTuple (PVar "n") (PVar "p")) (PVar "rest"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppPubScheme") (EVar "p")))) (ELit (LString ""))) (EApp (EVar "schemeLines") (EVar "rest"))))
