# Typechecker cell lifetimes

One row per piece of mutable typechecker state: the seven module-level cells of `compiler/types/typecheck.mdk`, the fields of its bundle records (`ModuleCtx`, `GraphCtx`, `GraphRun`, `CrossRun`, declared in `compiler/types/tc_types.mdk`), the fields of the records that carry the drive's configuration (`TcConfig`, `DriveInputs`, `TraceSink`) and of the context records that replace the old cells (`GroupCtx`, `DynCtx`, `SiteCtx`), and the cells outside the file that a drive reads or writes. It is the inventory the state-by-lifetime split works from.

Counts: 7 module-level cells in `types.typecheck`; field rows `ModuleCtx` 91, `GraphRun` 30, `CrossRun` 14, `GraphCtx` 18, `TcConfig` 5, `DriveInputs` 4, `TraceSink` 8; 5 rows outside the file. The first table is pinned to the cell census by `test/arch_boundaries_test.mdk`.

Stage-6 denominators (`fnmap.py` on `compiler/types/typecheck.mdk` at the sprint base; `frontier` is not a command of that tool, so `refs` and `closure` stand for it): functions that mention the shim / functions that reach one. `perRun` 345 / 1210, `graphCtx` 195 / 1439, `currentLoc` 83 / 744, `driveInputs` 6 / 235, of 3417 top-level functions.

Columns: `name | holds | lifetime | owner-today | writers | reset | target | interface-fills | source | issue`.

- `lifetime` is the measured one, from the writers and the reset site, not the declaring comment: `process` (never reset), `config` (set by the driver before the drive), `graph` (re-minted per graph), `module` (re-minted per module), `group` (reset per check group), `run` (saved and restored around one walk), `unknown`.
- `target` is where the cell lands: `TcEnv` (run), `GroupCtx`, `ModuleCtx`, `GraphCtx`, `TcConfig`, `interner` (stays process-wide), `delete` (dead or test-only).
- `interface-fills` is `yes` when a loaded ModuleInterface would have to populate the cell for an importer to typecheck against the module without re-checking it. `source` then names the published fields it derives from (`cpSchemes cpCore cpEvidence cpDispositions`), `derived(<field>)` where a computation over one reproduces it, or `none`. `cpBinders` does not exist in `CheckedProgram` at this base, so binder rows have source `none`.
- Bundle container cells (`graphCtx`, `perRun`, `driveInputs`) and `GraphCtx`'s sub-record and configuration fields (`GraphCtx.crossRun`, `GraphCtx.graphRun`, `GraphCtx.config`) are rows of their own; their fields are the rows that carry the lifetimes. `graphCtx` and `perRun` are shims and `driveInputs` is a handoff; the row says what stage 6 does to each.
- "Interface fills (input to playbook C1)", after the second table, is outside the parsed tables: it names, for each row the awk `$8=="yes" && $9=="none"` selects (and for the caveat rows), the field that owns it, its producer and its kind.

## Typechecker cells

| name | holds | lifetime | owner-today | writers | reset | target | interface-fills | source | issue |
|---|---|---|---|---|---|---|---|---|---|
| graphCtx | container, a shim (stage 6 threads the GraphCtx through the drive as a value and deletes the cell): the graph shim, the current drive's GraphCtx; replaced whole by mintGraphCtx and by the memo-hit install (installGraphCtx of a restoreGraphCtx record), which carry every Ref field by identity except builtinExternNamesRef (a hit replaces it), so the Ref fields outlive the record; fields have their own rows | graph | module-level | mintGraphCtx (graphPreamble), installGraphCtx (checkCoreMemoized hit, checkModulesChainReportFor hit), installCross, installRun, installSubRecords (markModules, probes) | mintGraphCtx (graphPreamble) | delete | no | - | - |
| currentLoc | innermost ELoc span for diagnostics; written about 35 times in save and restore brackets; never reset to None | run | module-level | infer ELoc arm and save-restore brackets | never (not in freshModuleCtx) | TcEnv | n/a | - | #1752 |
| driveInputs | container, a handoff (the drivers' one handoff into the typechecker besides selectedProfile; stage 6 makes it an argument of the drive entry and deletes the cell): the DriveInputs record the drivers hand the typechecker before a drive (stdlib ownership, coherence user decls, the test-only trace sink with its four gates and four buffers); replaced whole by the publishers setStdlibOwnership, setCoherenceUserDecls and the begin and finish trace helpers, read by tcConfigOf and the note trace functions | config | module-level | setStdlibOwnership, setCoherenceUserDecls, begin and finish helpers for the trace | never (the trace finish helpers clear their buffers and gates) | TcConfig | no | - | - |
| perRun | container, a shim (stage 6 threads the ModuleCtx through the module walk and deletes the cell): the module shim, the last-minted ModuleCtx; fields have their own rows | module | module-level | checkBodyImpl mint, memo hit installs, enterStampCtx, drainStampQueue, test probes | freshModuleCtx (checkBodyImpl) | delete | no | - | - |
| coreCheckMemoRef | process-wide core-pass memo, one entry (holds copies of the core pass's two sub-records and extern-name map) | process | module-level | checkCoreMemoized | never (test helper methodReturnMemoTeardownStats clears and restores) | interner | no | - | - |
| preludePreambleMemoRef | prelude preamble memo, one entry of pure values | process | module-level | preludePreambleStore | never | interner | no | - | - |
| moduleChainMemoRef | module-chain prefix memo (each step holds one GraphCtx snapshot) | process | module-level | checkModulesChainReportFor | never (test helper clears and restores) | interner | no | - | - |
| GraphCtx.effectDomains | effect label to domain table; builtins seeded then user effect decls registered | graph | GraphCtx | populateEffectDomainsGraph (seedEffectDomains, registerEffectDomain) | never | GraphCtx | yes | none | - |
| GraphCtx.config | the drive's TcConfig: the IO join and its profile name (which keys the memos), and the stdlib ownership, flat-entry flag and coherence user decls copied from driveInputs | graph | GraphCtx | graphPreamble | never (rebuilt by graphPreamble on every drive, after the effect domains its IO join reads) | GraphCtx | no | - | - |
| TcConfig.tcIoJoin | atoms IO joins in this drive, taken from the selected profile | graph | TcConfig | graphPreamble (tcConfigOf) | never (immutable; rebuilt whole by graphPreamble on every drive) | TcConfig | no | - | - |
| TcConfig.tcIoJoinProfile | name of the profile tcIoJoin was taken from; part of the memo keys | graph | TcConfig | graphPreamble (tcConfigOf) | never (immutable; rebuilt whole by graphPreamble on every drive) | TcConfig | no | - | - |
| TcConfig.tcStdlibOwned | set of stdlib-owned module ids, copied from driveInputs | graph | TcConfig | graphPreamble (tcConfigOf) | never (immutable; rebuilt whole by graphPreamble on every drive) | TcConfig | no | - | - |
| TcConfig.tcFlatEntryIsStdlib | flag: the flat entry is a stdlib module, copied from driveInputs | graph | TcConfig | graphPreamble (tcConfigOf) | never (immutable; rebuilt whole by graphPreamble on every drive) | TcConfig | no | - | - |
| TcConfig.tcCoherenceUserDecls | user declarations for the coherence conflict check, copied from driveInputs | graph | TcConfig | graphPreamble (tcConfigOf) | never (immutable; rebuilt whole by graphPreamble on every drive) | TcConfig | no | - | - |
| DriveInputs.diStdlibOwned | set of stdlib-owned module ids from the driver module list | config | DriveInputs | setStdlibOwnership | never (replaced whole by the next publisher call) | TcConfig | no | - | - |
| DriveInputs.diFlatEntryIsStdlib | flag: the flat entry is a stdlib module | config | DriveInputs | setStdlibOwnership | never (replaced whole by the next publisher call) | TcConfig | no | - | - |
| DriveInputs.diCoherenceUserDecls | user declarations coherence is checked over | config | DriveInputs | setCoherenceUserDecls | never (replaced whole by the next publisher call) | TcConfig | no | - | - |
| DriveInputs.diTrace | `Option TraceSink` (`None`: every trace off): the TraceSink the tests turn on before a drive and read after it; test-only | config | DriveInputs | setTraceSink | never (the finish helpers clear the buffers and gates) | delete | n/a | - | - |
| TraceSink.tsAssumptionEnabled | test-only gate for the assumption trace (no production reader) | config | TraceSink | setTraceSink (begin and finish helpers for the trace) | finish helper clears | delete | n/a | - | - |
| TraceSink.tsAssumptionEntries | test-only buffer for the assumption trace (no production reader) | config | TraceSink | note functions append; begin and finish helpers for the trace | finish helper clears | delete | n/a | - | - |
| TraceSink.tsNumericPredicateEnabled | test-only gate for the numeric predicate trace (no production reader) | config | TraceSink | setTraceSink (begin and finish helpers for the trace) | finish helper clears | delete | n/a | - | - |
| TraceSink.tsNumericPredicateEntries | test-only buffer for the numeric predicate trace (no production reader) | config | TraceSink | note functions append; begin and finish helpers for the trace | finish helper clears | delete | n/a | - | - |
| TraceSink.tsMethodReturnEnabled | test-only gate for the method-return trace (no production reader) | config | TraceSink | setTraceSink (begin and finish helpers for the trace) | finish helper clears | delete | n/a | - | - |
| TraceSink.tsMethodReturnEntries | test-only buffer for the method-return trace (no production reader) | config | TraceSink | note functions append; begin and finish helpers for the trace | finish helper clears | delete | n/a | - | - |
| TraceSink.tsEvidenceObservationEnabled | test-only gate for the evidence observation trace (no production reader) | config | TraceSink | setTraceSink (begin and finish helpers for the trace) | finish helper clears | delete | n/a | - | - |
| TraceSink.tsEvidenceObservationEntries | test-only buffer for the evidence observation trace (no production reader) | config | TraceSink | note functions append; begin and finish helpers for the trace | finish helper clears | delete | n/a | - | - |
| GraphCtx.crossRun | the CrossRun sub-record; its fields have their own rows | graph | GraphCtx | mintGraphCtx, installGraphCtx (checkCoreMemoized hit, checkModulesChainReportFor hit), installCross, installSubRecords (probes) | mintGraphCtx (graphPreamble) | GraphCtx | no | - | - |
| GraphCtx.graphRun | the GraphRun sub-record; its fields have their own rows | graph | GraphCtx | mintGraphCtx (graphLineageRun), markModules, installGraphCtx (memo hits), installRun, installSubRecords (probes) | mintGraphCtx (graphLineageRun) | GraphCtx | no | - | - |
| GraphCtx.typeErrorsSticky | build or run abort flag armed at the first recorded type error | process | GraphCtx | recordTypeError | resetTypeErrorsSticky (snapshot.mdk and tests only; production never resets); rolled back by checkGraphFinish, captureTypeErrors, methodReturnOwnershipProbe; mintGraphCtx carries it by identity | GraphCtx | no | - | - |
| GraphCtx.typeErrorsStickyDiags | the diagnostics behind the sticky flag | process | GraphCtx | recordTypeError, replaceAmbiguityAt | resetTypeErrorsSticky (snapshot.mdk and tests only); rolled back by checkGraphFinish, captureTypeErrors, methodReturnOwnershipProbe; mintGraphCtx carries it by identity | GraphCtx | no | - | - |
| GraphCtx.graphAdmittedMethodsRef | per module (dependency id, method) pairs deAliasMethodImports admitted for dispatch; renameAliasedMethods writes it before graphPreamble, and the two projection drives (checkModulesPreambleK, checkModulesPartialK) never call it yet read it through admittedIn, so they see the previous drive's map | graph | GraphCtx | renameAliasedMethods | never | GraphCtx | no | - | - |
| GraphCtx.declEnvsRef | stage K declaration envelope for the whole graph (deOwnersBefore, deKindsBefore, deIfaces, deImpls, deModules) | graph | GraphCtx | graphPreamble (buildDeclEnvs) | never | GraphCtx | yes | none | - |
| GraphCtx.abstractRecordTypesRef | record types exported abstractly, seeded from decls | graph | GraphCtx | seedAbstractRecordTypes | never | GraphCtx | yes | none | - |
| GraphCtx.argDispatchIdxByIdRef | interface method argument dispatch index, from the graph mark sets | graph | GraphCtx | markSetsOf | never | GraphCtx | yes | none | - |
| GraphCtx.dictEligibleRef | user function names eligible for dictionary passing (list view) | graph | GraphCtx | setDictEligible | never | GraphCtx | yes | derived(cpSchemes) | - |
| GraphCtx.dictEligibleSetRef | set view of dictEligibleRef | graph | GraphCtx | setDictEligible | never | GraphCtx | yes | derived(cpSchemes) | - |
| GraphCtx.mangledShadowMapRef | mangled shadow name map from the graph mark sets | graph | GraphCtx | markSetsOf | never | GraphCtx | yes | none | - |
| GraphCtx.mangledFunDefsPresentRef | flag: mangled function definitions exist in the graph | graph | GraphCtx | graphPreamble | never | GraphCtx | no | - | - |
| GraphCtx.builtinExternNamesRef | builtin extern name to (type, arity) catalog from runtime decls | graph | GraphCtx | noteBuiltinExternNames (via externSchemes); on a memo hit restoreGraphCtx builds a record with the snapshot's value, which graphPreamble and checkModulesChainReportFor install | never (a memo hit's returned record carries the snapshot's value) | GraphCtx | yes | none | - |
| ModuleCtx.superDeclsRef | superclass declarations in scope for the module being checked | module | ModuleCtx | freshModuleCtx, stampCtxOf, installSnapshotModuleCtx | never (rewritten per module by the mint) | ModuleCtx | no | - | - |
| ModuleCtx.standaloneValuesRef | standalone value names of the module being checked | module | ModuleCtx | checkBodyImpl, installSnapshotModuleCtx | never (rewritten per module by checkBodyImpl) | ModuleCtx | no | - | - |
| ModuleCtx.methodDispatchIdxByIdRef | method dispatch index scratch, set fresh per module | module | ModuleCtx | checkBodyImpl, installSnapshotModuleCtx | never (rewritten per module by checkBodyImpl) | ModuleCtx | no | - | - |
| ModuleCtx.matchOracle | constructor oracle for exhaustiveness checks; installed once per module by the mint from the CheckRunSeed (seedCheckRun on both checkModuleFullDiags arms), while cmCheckWorker and the core pass carry the residue of the last record | module | ModuleCtx | graphPreamble, installSnapshotModuleCtx, freshModuleCtx | graphPreamble (tree arm), freshModuleCtx | ModuleCtx | n/a | - | - |
| ModuleCtx.matchWarnings | match warnings accumulated for the module; reset once per module by the mint, appended after the module by pushCoherenceWarning (runFinalChecks), read by hadMatchWarnings after the whole check | module | ModuleCtx | checkMatchExhaustive, checkRedundantGo, pushCoherenceWarning, installSnapshotModuleCtx, freshModuleCtx | freshModuleCtx | ModuleCtx | n/a | - | - |
| GraphCtx.promotionHarvestRef | names promoted during the graph, harvested at the end | graph | GraphCtx | graphModuleWorker, graphPreamble | graphPreamble | GraphCtx | no | - | - |
| GraphCtx.mainSchemeRef | scheme of the entry main, read for autoprint and the emit path | graph | GraphCtx | graphModuleWorker, graphPreamble, setMainSchemeIfEntry | graphPreamble (tree arm clears) | GraphCtx | no | - | #2257 |
| ModuleCtx.sigNameSetRef | names with signatures in the module being checked | module | ModuleCtx | processTopGroups, installSnapshotModuleCtx | never (rewritten per module by processTopGroups) | ModuleCtx | no | - | - |
| ModuleCtx.sigTyMapRef | signature types of the module being checked | module | ModuleCtx | processTopGroups, installSnapshotModuleCtx | never (rewritten per module by processTopGroups) | ModuleCtx | no | - | - |
| ModuleCtx.currentModuleRef | module whose body checkBodyImpl is inferring, tags diagnostics | module | ModuleCtx | freshModuleCtx, stampCtxOf, checkBodyImpl | never (rewritten per module by the mint) | ModuleCtx | no | - | - |
| GraphCtx.markSetsRef | graph mark sets; also the mode flag for grants (grantsEnabled) | graph | GraphCtx | markSetsOf | never (None until a preamble runs) | GraphCtx | yes | none | - |
| ModuleCtx.invocationViewRef | last checked module constructors and variance tables for lastInvocationOps | module | ModuleCtx | recordInvocationView | never (rewritten per module) | ModuleCtx | no | - | - |
| CrossRun.universeFunNamesRef | names of functions registered by earlier modules | graph | CrossRun | appendUniverseAccums | mintGraphCtx | GraphCtx | yes | derived(cpSchemes) | - |
| CrossRun.universeMethodDispatchIdxByIdRef | interface dispatch-index universe keyed by (IfaceRef, method) | graph | CrossRun | appendUniverseAccums | mintGraphCtx | GraphCtx | yes | none | - |
| CrossRun.universeDataCtors | every registered head with its parameters and constructors, read by tyCarries | graph | CrossRun | recordCtors | mintGraphCtx | GraphCtx | yes | none | - |
| CrossRun.universeCtorPop | public constructor schemes by declaration identity, grown per module | graph | CrossRun | appendDataUniverse | mintGraphCtx | GraphCtx | yes | none | - |
| CrossRun.universeRecordPop | public record infos by declaration identity, grown per module | graph | CrossRun | appendDataUniverse, loadDataUniverse | mintGraphCtx | GraphCtx | yes | none | - |
| CrossRun.builtinClassesRef | identities and presence of the four operator and literal classes read off the prelude interfaces | graph | CrossRun | methodRowNumObservation, seedBuiltinClasses | mintGraphCtx | GraphCtx | yes | none | - |
| CrossRun.crossModuleFunPredicateSlotsRef | per-function dictionary slots (bare table, PSArgsUnknown) | graph | CrossRun | checkBodyImpl | mintGraphCtx | GraphCtx | yes | derived(cpSchemes) | - |
| CrossRun.crossModuleFunPredicateSlotsQualRef | per-function dictionary slots keyed (module, name), with signature vectors | graph | CrossRun | checkBodyImpl | mintGraphCtx | GraphCtx | yes | derived(cpSchemes) | - |
| CrossRun.crossModuleFunConstraintDeclaredRef | declared constraint prefix per function | graph | CrossRun | checkBodyImpl | mintGraphCtx | GraphCtx | yes | none | - |
| CrossRun.crossModuleFunConstraintDeclaredQualRef | declared constraint prefix keyed (module, name) | graph | CrossRun | checkBodyImpl | mintGraphCtx | GraphCtx | yes | none | - |
| CrossRun.crossModuleMethodPredicateSlotsRef | per-method predicate slots | graph | CrossRun | checkBodyImpl | mintGraphCtx | GraphCtx | yes | none | - |
| CrossRun.crossModuleMethodPredicateSlotsQualRef | per-method predicate slots keyed (module, name) | graph | CrossRun | checkBodyImpl | mintGraphCtx | GraphCtx | yes | none | - |
| CrossRun.coreSchemeObligationsRef | scheme obligations of the core pass, snapshotted after it | graph | CrossRun | checkCoreMemoized | mintGraphCtx | GraphCtx | yes | derived(cpCore) | - |
| CrossRun.crossModuleSchemeOblsQualRef | every user module scheme obligations keyed (module, name) | graph | CrossRun | checkBodyImpl | mintGraphCtx | GraphCtx | yes | derived(cpSchemes) | - |
| GraphRun.tyvarCounter | type variable id source; ids stay unique across the graph | graph | GraphRun | newTyvarId | graphLineageRun (fresh counter) | GraphCtx | yes | derived(cpSchemes) | - |
| GraphRun.effvarCounter | effect variable id source | graph | GraphRun | newEffvarId | graphLineageRun | GraphCtx | yes | derived(cpSchemes) | - |
| GraphRun.ctorExistentialsRef | quantified authority ids of existential constructor binders | graph | GraphRun | recordExistentials | graphLineageRun | GraphCtx | yes | none | - |
| GraphRun.patternAuthIdsRef | ids of authority variables minted pattern-ranging | graph | GraphRun | freshAuthvarRanged | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.anyExistentialsRef | flag: some constructor with an existential binder was registered | graph | GraphRun | recordExistentials | graphLineageRun | GraphCtx | yes | none | - |
| GraphRun.goals | the one channel of route-stamped site goals, drained at graph end | graph | GraphRun | copyGraphRunForMemo, dropGoalsSince, pushGoal, resolveAdmittedSite | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.numlitRefs | numeric literal defaulting channel | graph | GraphRun | pushNumlit | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.numlitN | length of numlitRefs for O(1) marks | graph | GraphRun | pushNumlit | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.activeDictVars | dictionary variables active per tyvar id | graph | GraphRun | registerEachActive, registerEachActiveId, registerImplMethodDictOne, registerOneMethodDict | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.gGiven | given environment keyed by module | graph | GraphRun | pushGiven | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.moduleRanges | per-module channel marks, so the drain cuts a module window | graph | GraphRun | recordModuleStart | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.stampCtxs | one StampCtx per module that finished elaborating, replayed at graph end | graph | GraphRun | drainStampQueue, enqueueStampCtx | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.goalsN | length of goals for O(1) marks | graph | GraphRun | copyGraphRunForMemo, dropGoalsSince, pushGoal | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.evCounter | ordinal source for evidence ids; carried across graph resets so ids never repeat in a process | process | GraphRun | autoPrintEvidence, freshEvId, judgeEvidence, graphLineageRun | never (graphLineageRun carries it) | GraphCtx | yes | derived(cpEvidence) | - |
| GraphRun.evBase | evCounter value when this graph lineage began | graph | GraphRun | graphLineageRun (plain field, re-minted) | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.markedAhead | set by markModules when marking precedes the driver reset | graph | GraphRun | markModules (plain field, re-minted) | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.evJudged | ordinal below which method cells were judged complete | graph | GraphRun | judgeEvidence, graphLineageRun | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.evTable | solved evidence, one entry per goal, appended at graph-end drain | graph | GraphRun | autoPrintEvidence, recordEvidence | graphLineageRun | GraphCtx | yes | cpEvidence | - |
| GraphRun.memoMethodReturns | immutable observations of drained ordinary returns, diagnostic only | graph | GraphRun | copyGraphRunForMemo | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.evCells | method occurrence working cells indexed by ordinal less evBase | graph | GraphRun | mintMethodCellRaw (array grown by doubling) | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.siteCells | operator, literal and record-head site cells indexed like evCells | graph | GraphRun | mintSite (array grown by doubling) | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.scopeStore | store of binding scope frames | graph | GraphRun | openScope, closeScope (store mutated in place) | graphLineageRun (fresh store) | GraphCtx | no | - | - |
| GraphRun.localAbs | dictionary-abstracted local bindings; binder names survive, quantified ids cleared | process | GraphRun | freshLocalAbsName, forgetLocalAbs, recordLocalQuantified, recordLocalRecOcc, registerLocalAbs, graphLineageRun | never (graphLineageRun carries it and clears lasQuantified) | GraphCtx | no | - | #4284 |
| GraphRun.grants | authorities granted per occurrence; survives, sourceless set cleared | process | GraphRun | inferMethodAt, inferMethodCandidateAt, instantiateValueTracked, methodGrantUse, graphLineageRun | never (graphLineageRun carries it and clears gsSourceless) | GraphCtx | no | - | - |
| GraphRun.binderPending | binders inferred since the last drain with live type cells | graph | GraphRun | materializeBinderTypes, recordBinderType | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.binderRows | runtime-type table of materialized binder rows this graph publishes | graph | GraphRun | materializeBinderTypes | graphLineageRun | GraphCtx | yes | cpBinders | - |
| GraphRun.liveRoots | open variables non-generalized members left at module end, emptied by every drain | graph | GraphRun | defaultLiveNumRoots, recordLiveRoots | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.liveNumRoots | the Num-constrained subset of liveRoots, emptied by every drain | graph | GraphRun | defaultLiveNumRoots, recordLiveRoots | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.liveNumGoals | goals on liveNumRoots, emptied by every drain | graph | GraphRun | defaultLiveNumRoots, recordLiveRoots | graphLineageRun | GraphCtx | no | - | - |
| GraphRun.liveGoals | goals boundaries held on live variables, emptied by every drain | graph | GraphRun | judgeLiveGoals, recordLiveRoots | graphLineageRun | GraphCtx | no | - | - |
| ModuleCtx.currentScope | cursor of the open binding scope | run | ModuleCtx | closeScope, openScope | freshModuleCtx | TcEnv | n/a | - | - |
| ModuleCtx.admittedOccObls | method occurrences whose spelling has two or more admitted declarations, checked once the receiver grounds | module | ModuleCtx | pushAdmittedOccObl | freshModuleCtx | ModuleCtx | no | - | #2705 |
| ModuleCtx.curEffect | effect rows performed by the expression being inferred | run | ModuleCtx | performEffect, captureEffects | freshModuleCtx | TcEnv | n/a | - | - |
| ModuleCtx.effectSummaries | effect summary solver state across scopes | module | ModuleCtx | beginEffectSummaryScope, EffectSolver.* (solver value) | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.pendingJoinsRef | joins of alternatives with no shape yet, decided when the scope closes; a module channel keyed by level, drained by processSCC at its level, by processTopGroups at 0 and by finishEffectContract | module | ModuleCtx | deferJoin, postponePendingJoins, resolvePendingJoins, settlePending, settlePendingJoins, takeJoinsShapedBy | freshModuleCtx | ModuleCtx | n/a | - | - |
| ModuleCtx.fileValueFlows | windowed file-value flows, cut by finishFileValueScope | module | ModuleCtx | finishFileValueScope, recordFileValueFlow, unifySpineProbe | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.fileValueScopes | stack of open file-value scopes | run | ModuleCtx | beginEffectSummaryScope, finishFileValueScope | freshModuleCtx | TcEnv | n/a | - | - |
| ModuleCtx.rigidEffvarsRef | effect variables rigid inside the current contract | run | ModuleCtx | beginEffectContract, finishEffectContract, processSCC, unifyRowPlain | finishEffectContract restores; freshModuleCtx | TcEnv | n/a | - | - |
| ModuleCtx.rigidAuthvarsRef | authority variables rigid inside the current contract | run | ModuleCtx | beginEffectContract, finishEffectContract, freshAuthSubstOpeningIn, processSCC | finishEffectContract restores; freshModuleCtx | TcEnv | n/a | - | - |
| ModuleCtx.effectSitesRef | first site per (binding, label) that performed the label | module | ModuleCtx | recordEffectSites | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.rowFailureReportedRef | bindings whose row failure the scoped solver already reported | module | ModuleCtx | reportEffectSummaryFailures | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.typeErrorKeySetRef | dedup set of (code, location, message) triples | module | ModuleCtx | pushTypeErrorAt | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.escapedExistentialsRef | existential cells reported as escaping their scope | module | ModuleCtx | closeExistentialScope | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.openedAuthvarsRef | cells a pattern opened for an existential binder | module | ModuleCtx | freshAuthSubstOpeningIn | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.indexSubstitutedRef | index variables an index equality substituted a term for | module | ModuleCtx | substituteIndexLinked | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.extendedBindersRef | authority variables an argument extended on the right | module | ModuleCtx | noteArgumentShape | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.displayHiddenBindersRef | authority variables an interpolation hid behind a non-prelude display | module | ModuleCtx | noteArgumentShape | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.openedExistentialsRef | existential cells opened at the pattern site being inferred | run | ModuleCtx | openExistentials, parkOpenedExistentials, refuseOpenedExistentials, takeOpenedExistentials | freshModuleCtx | TcEnv | n/a | - | - |
| ModuleCtx.openedExistentialsStackRef | stack of parked opened-existential lists | run | ModuleCtx | parkOpenedExistentials, refuseOpenedExistentials | freshModuleCtx | TcEnv | n/a | - | - |
| ModuleCtx.recordByNameRef | record infos by name, seeded each module from universeRecordPop | module | ModuleCtx | loadDataUniverse, overrideScopedRecords, registerCachedRecord, registerRecordInfoKeyed | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.fieldOwnersRef | field name to owning records, seeded each module | module | ModuleCtx | declEnvSeedDataUniverse, registerCachedRecord, registerRecordInfoKeyed | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.dataParamKindsRef | kinds of data type parameters, seeded each module | module | ModuleCtx | declEnvSeedDataUniverse, recordParamKinds, withDeclParamKinds | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.dataParamNameIndexRef | name-only index over dataParamKindsRef keys | module | ModuleCtx | declEnvSeedDataUniverse, recordParamKinds, withDeclParamKinds | freshModuleCtx | ModuleCtx | no | - | #2158 |
| ModuleCtx.dataParamPolarityRef | variance twin of dataParamKindsRef | module | ModuleCtx | declEnvSeedDataUniverse, recordParamPolarities, seedParamPolarityFixpointScoped | freshModuleCtx | ModuleCtx | no | - | #1119 |
| ModuleCtx.dataParamRowAtomsRef | atoms each KRow parameter is charged at every occurrence | module | ModuleCtx | declEnvSeedDataUniverse, recordParamRowAtoms | freshModuleCtx | ModuleCtx | no | - | #2110 |
| ModuleCtx.aliasTableRef | type alias table, seeded each module | module | ModuleCtx | loadDataUniverse, registerData | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.numLitFromIntAnchorRef | identity-selected prelude Num.fromInt descriptor row | module | ModuleCtx | seedNumLitFromIntAnchor | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.definerShadowNamesRef | definer-shadow names in scope; written once per module by checkBodyImpl (the per-group writer was removed with the dead flat path) | module | ModuleCtx | checkBodyImpl | freshModuleCtx | ModuleCtx | n/a | - | - |
| ModuleCtx.definerShadowSigsRef | signatures of definer-shadow names | module | ModuleCtx | checkBodyImpl | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.bodyImplEnvRef | impl environment of the module body being checked | module | ModuleCtx | checkBodyImpl, methodReturnProbeCodes, methodReturnProbeStamp, methodReturnResolutionMutationProbe | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.methodAliasEntriesRef | alias method spellings the imports supply, mapped to declaration entries | module | ModuleCtx | checkBodyImpl, methodReturnProbeSpelling | freshModuleCtx | ModuleCtx | no | - | #1386 |
| ModuleCtx.methodScopeCtxRef | this module decls and ordinal, inputs of methodScopeHere | module | ModuleCtx | checkBodyImpl | freshModuleCtx | ModuleCtx | no | - | #2563 |
| ModuleCtx.methodScopeMemoRef | methodScopeAt answers for spellings read in this module | module | ModuleCtx | methodScopeHere | freshModuleCtx | ModuleCtx | no | - | #2563 |
| ModuleCtx.aliasMethodOriginsRef | alias-qualified method spellings mapped to origin method names | module | ModuleCtx | checkBodyImpl | freshModuleCtx | ModuleCtx | no | - | #1386 |
| ModuleCtx.implObls | windowed impl obligation channel | module | ModuleCtx | checkMethodBodyAgainst, inferUserImplBodies, pushExactReturnObl | freshModuleCtx | ModuleCtx | no | - | #841 |
| ModuleCtx.poisonedVars | type variables poisoned by a mismatch, to suppress follow-on errors | module | ModuleCtx | checkSigVarGoal, poisonMismatchVars, propagatePoison | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.deferrableVarIds | quantified variable ids of generalized schemes; undetermined goals on them defer into the scheme | module | ModuleCtx | registerSchemeObligations | freshModuleCtx | ModuleCtx | no | - | #838 |
| ModuleCtx.liveMemberMonosRef | types of closed top-level members that left a variable open | module | ModuleCtx | liveMemberIds | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.quiescentGoalsRef | goals on live-member variables with their boundary data | module | ModuleCtx | judgeQuiescentGoals, undeterminedVectorVerdict | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.heldLiveGoalsRef | goals a boundary held without a verdict | module | ModuleCtx | undeterminedVectorVerdict | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.determinedRowsRef | impl row chosen by each determination commit, by variable | module | ModuleCtx | fileDeterminedRow, refileDeterminedRows | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.declaredSigVarIds | variables a closed binder declares, held rigid | module | ModuleCtx | declareRigidVars | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.tupleCallCandidates | tuple-call hint candidates | module | ModuleCtx | inferAppExpr | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.numlitVarLocs | numeric literal variable locations | module | ModuleCtx | recordNumlitLoc | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.patLitPending | integer literal patterns since the enclosing pattern site began | run | ModuleCtx | inferIntLitPat, settlePatLitsOnly, takePatLits | freshModuleCtx | TcEnv | n/a | - | - |
| ModuleCtx.patLitDeferred | integer literal patterns whose scrutinee type was unknown at their site | module | ModuleCtx | settleDeferredPatLits, settlePatLitsGo | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.matchChecksDeferred | matches whose scrutinee type was unknown after their arms, checked at module end | module | ModuleCtx | inferMatch | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.numlitRanges | source integer literals for the fixed-width range check | module | ModuleCtx | recordNegatedLitRange, recordNumlitRange, settlePatLitsGo | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.wideLitRanges | wide literals for checkWideLiterals | module | ModuleCtx | inferWideLit, recordNegatedLitRange | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.numlitUntainted | numeric literal locations not tainted by an operator | module | ModuleCtx | markNumlitOpTaint, recordNumlitLoc | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.numlitOpLocs | operator locations of numeric literals | module | ModuleCtx | taintAndDrop | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.numlitCtxTags | numeric literal locations tagged with join context | module | ModuleCtx | tagLitLocsWithRoot | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.localBindRefs | local bindings with their types, for tooling tables | module | ModuleCtx | recordLocalBind | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.localSchemesOut | local schemes captured for the entry tables (captureEntryTables) | module | ModuleCtx | checkBodyImpl | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.seedSchemesOut | import seed schemes captured for the entry tables | module | ModuleCtx | checkBodyImpl | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.funPredicateSlotsRef | function dictionary slots, seeded from GraphCtx.crossRun and written back per module | module | ModuleCtx | checkBodyImpl, setFunConstraintEntry, setFunPredicateSlots | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.funPredicateSlotsIdxRef | first-wins index over funPredicateSlotsRef | module | ModuleCtx | setFunConstraintEntry, setFunPredicateSlots | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.funConstraintDeclaredRef | declared constraint prefixes, seeded from GraphCtx.crossRun | module | ModuleCtx | checkBodyImpl, dictPassModulesIfEnabled, dictPassModulesScoped | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.currentImportDefinersRef | imported definer names of this module imports | module | ModuleCtx | checkBodyImpl | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.currentImportOriginsRef | imported origin names of this module imports | module | ModuleCtx | checkBodyImpl | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.importedSchemeOblsRef | scheme contexts of this module imported bindings, by local spelling | module | ModuleCtx | checkBodyImpl | freshModuleCtx | ModuleCtx | no | - | #1114 |
| ModuleCtx.obls | windowed call obligation channel | module | ModuleCtx | inferUserImplBodies, recordOblAt | freshModuleCtx | ModuleCtx | no | - | #838 |
| ModuleCtx.absorptions | row-unifier atom-discard trail, write-only | module | ModuleCtx | recordAbsorptions | freshModuleCtx | ModuleCtx | no | - | #839 |
| ModuleCtx.schemeObligationsRef | scheme obligations keyed (name, binding id) | module | ModuleCtx | registerSchemeObligations | freshModuleCtx | ModuleCtx | no | - | #837 |
| ModuleCtx.schemeDefIdsRef | top-level value binder to binding id | module | ModuleCtx | checkBodyImpl | freshModuleCtx | ModuleCtx | no | - | #837 |
| ModuleCtx.methodPredicateSlotsRef | method predicate slots, seeded from GraphCtx.crossRun | module | ModuleCtx | checkBodyImpl, dictPassModulesIfEnabled, dictPassModulesScoped, methodReturnProbeSlotCase, setMethodPredicateSlotEntry | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.currentFn | top-level function whose body is being inferred | run | ModuleCtx | inferMembers, inferMethodBody | freshModuleCtx | TcEnv | n/a | - | - |
| ModuleCtx.currentImplBody | true while inferring an impl method body | run | ModuleCtx | inferMethodBody | freshModuleCtx | TcEnv | n/a | - | - |
| ModuleCtx.methodSiteFns | method site mono lists per function | module | ModuleCtx | recordArgSiteFn, recordNumLitSite, recordSite | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.dictAppFns | dictionary application mono lists per function | module | ModuleCtx | inferDeclaredDictAt, pushLocalDictApp | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.residualUnivRef | impl universe for residual predicate walks | module | ModuleCtx | checkBodyImpl | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.promotedRef | names promoted by inference | module | ModuleCtx | registerInferredFor | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.fieldOwnerModulesRef | field-owner key to declaring module ids; comment says graph-global but it is re-minted per module | module | ModuleCtx | declEnvSeedDataUniverse | freshModuleCtx | ModuleCtx | no | - | #1597 |
| ModuleCtx.fieldOwnerReachRef | module ids this module can reach through DUse | module | ModuleCtx | declEnvSeedDataUniverse | freshModuleCtx | ModuleCtx | no | - | #1597 |
| GroupCtx.gcMonos | the group's constraint variables as (interface name, instantiated mono), read by definerReceiverIsDictVar to dispatch a definer-shadow occurrence through the dict | group | GroupCtx | processSCC | dropped when processSCC returns | GroupCtx | n/a | - | - |
| GroupCtx.gcPendingEscapes | the retained post-hoc effect-escape walk's findings, held until the group's solver scope has closed | group | GroupCtx | processSCC, checkEffectEscapeIn, flushPendingEscapes | dropped when processSCC returns | GroupCtx | n/a | - | - |
| DynCtx.dcJoin | the construct whose alternatives a value join is equating, which names the mismatch | run | DynCtx | joinValueEqual | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| DynCtx.dcNonCovariant | inside a non-covariant type argument, where two closed effect rows must be equal | run | DynCtx | paramVarianceGuard | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| DynCtx.dcSuppressRLocalRecord | typing a definer-shadow occurrence that heads an application, so recordRLocalSite pushes nothing | run | DynCtx | inferDefinerShadowAppAt | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| DynCtx.dcSuppressArgStamp | typing a definer-shadow occurrence that heads an application, so recordArgStamp pushes nothing | run | DynCtx | inferDefinerShadowAppAt | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| DynCtx.dcShadowHeadCtx | typing a shadow occurrence that heads its own application, so the value-position standalone pin does not apply | run | DynCtx | shadowHeadEnv (callers: inferShadowAppHead, shadowVarHeadMethodScheme, inferDefinerStandaloneVarAppAt) | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| DynCtx.dcDo | inside a do-lowered chain, where a monad-shape mismatch reads as "do requires a monad" | run | DynCtx | infer (the EDoOrigin arm, which installs the DoCtx); recordDoMonadError (sets the Ref `doReported` in the installed DoCtx) | none for the field (immutable; a nested walk gets an updated copy); the `doReported` Ref inside it is mutable, set once per region by recordDoMonadError and fresh in each nested do | TcEnv | n/a | - | - |
| DynCtx.dcMethodMismatch | unifying an interface default body against its declared type, so a leaf mismatch names the method | run | DynCtx | checkMethodBodyAgainst | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| DynCtx.dcGroup | the GroupCtx of the top-level binding group being inferred (its constraint monos and its held effect-escape findings); None outside a group | group | DynCtx | processSCC | none for the field (immutable; a nested walk gets an updated copy); the gcPendingEscapes Ref inside it is minted per group by processSCC | GroupCtx | n/a | - | - |
| SiteCtx.sxSite | the span of the dispatch site being resolved, for a diagnostic raised where no span argument exists | run | SiteCtx | resolveArgStamps, resolveSites, resolveRLocalSites, resolveOpSites, resolveDictApps, checkEnteredReqs, checkImplHeadGoal, residualBoundPreds | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| SiteCtx.sxInner | the notes accumulator of the running stamp, which each route built below the top level is ORed into | run | SiteCtx | routeWalkMemoized, stampNoting (install the accumulator); noteInner (ORs into the Ref content) | none for the field (immutable; a nested walk gets an updated copy); the accumulator Ref content is mutable and ORed monotonically by noteInner during the stamp | TcEnv | n/a | - | - |
| ModuleCtx.typeErrors | windowed diagnostic output channel | module | ModuleCtx | recordTypeError, replaceAmbiguityAt | freshModuleCtx | ModuleCtx | no | - | #1146 |
| ModuleCtx.typeErrorMsgSetRef | membership index over typeErrors rendered messages | module | ModuleCtx | recordTypeError, replaceAmbiguityAt | freshModuleCtx | ModuleCtx | no | - | #2068 |
| ModuleCtx.ambiguitySitesRef | spans holding a T-AMBIGUOUS-INSTANCE | module | ModuleCtx | pushAmbiguityAt | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.ambiguityVarsRef | boundary-owned variables already reported ambiguous | module | ModuleCtx | pushBoundaryAmbiguity | freshModuleCtx | ModuleCtx | no | - | - |
| ModuleCtx.errorsDetected | control signal counting detected type errors | module | ModuleCtx | noteTypeErrorDetected | freshModuleCtx | ModuleCtx | no | - | #1146 |
| ModuleCtx.occursCheckFailed | set by bindVar on an occurs failure, read and cleared by the caller | run | ModuleCtx | bindValueUpper, bindVar, occursAdjustUnbound | freshModuleCtx | TcEnv | n/a | - | - |
| ModuleCtx.currentLevel | inference level counter | run | ModuleCtx | enterLevel, exitLevel, lowerToCurrent | freshModuleCtx | TcEnv | n/a | - | - |
| ModuleCtx.markingRef | module marking from beginModuleMarking | module | ModuleCtx | beginModuleMarking | freshModuleCtx | ModuleCtx | no | - | - |

## Cells outside the file

| name | holds | lifetime | owner-today | writers | reset | target | interface-fills | source | issue |
|---|---|---|---|---|---|---|---|---|---|
| selectedProfile | target profile selected by the driver (types/target_profile.mdk); typecheck reads it once in graphPreamble via tcConfigOf; published types depend on its IO join | config | module-level | mcp.mdk, entry_support.mdk, playground_main.mdk, medaka_cli.mdk, build_cmd.mdk, profile_select.mdk, tests | build_cmd saves it, clears it, and restores it around a build; mcp.mdk and profile_select.mdk set it back to None when no profile is selected | TcConfig | yes | none | - |
| binderOrdinalRef | desugar binder ordinal counter (frontend/desugar.mdk); ordinals are never reused within a process | process | module-level | freshBinderId | never | interner | no | - | - |
| preludeScopeMemoRef | prelude scope memo, one entry (frontend/resolve.mdk) | process | module-level | preludeScopeFor | never | interner | no | - | - |
| loadedSourcesRef | path to source text of every loaded file (driver/loader.mdk, the one driver.loader cell in cells.golden) | process | module-level | noteLoadedSource | never | interner | no | - | - |
| program_facts.currentFacts | the ProgramFacts value lowering and eval read for the run in progress (types/program_facts.mdk); deleted by the issue "thread ProgramFacts through lower and EvalEnv" | run | module-level | withFacts | withFacts restores the previous value | delete | n/a | - | #4317 |

## Interface fills (input to playbook C1)

The rows of the typechecker tables whose `interface-fills` is `yes` and whose `source` is `none` (the strict rows), plus the rows whose `source` is `derived(cpSchemes)` that the cell table's first review left as a caveat (the function-versus-method split of the predicate slots, and `dictEligible*`). A loaded `ModuleInterface` would have to restore each one for an importer to typecheck against a module without re-checking it. `kind` is what C1 needs: a `computed once` value is rebuilt from the loaded graph's declarations in one call; an `accumulated` value grows as each module is checked, so C1 restores it from each loaded module's interface. The two counters `GraphRun.tyvarCounter` and `GraphRun.effvarCounter` are also `derived(cpSchemes)` but are id sources, not interface content, and are not listed.

| field | owner | producer | kind | status |
|---|---|---|---|---|
| GraphCtx.effectDomains | GraphCtx | populateEffectDomainsGraph (seedEffectDomains, registerEffectDomain), from graphPreamble | computed once from the whole graph's declarations | strict |
| GraphCtx.declEnvsRef | GraphCtx | buildDeclEnvs, installed by graphPreamble | computed once from the whole graph's declarations | strict |
| GraphCtx.abstractRecordTypesRef | GraphCtx | seedAbstractRecordTypes, from graphPreamble | computed once from the whole graph's declarations | strict |
| GraphCtx.argDispatchIdxByIdRef | GraphCtx | markSetsOf, from graphPreamble | computed once from the whole graph's declarations | strict |
| GraphCtx.mangledShadowMapRef | GraphCtx | markSetsOf, from graphPreamble | computed once from the whole graph's declarations | strict |
| GraphCtx.builtinExternNamesRef | GraphCtx | noteBuiltinExternNames, from externSchemes over runtimeDecls | accumulated by union over every catalog build (runtime declarations, not per module); a memo hit restores the snapshot's value | strict |
| GraphCtx.markSetsRef | GraphCtx | markSetsOf, from graphPreamble | computed once from the whole graph's declarations | strict |
| CrossRun.universeMethodDispatchIdxByIdRef | GraphCtx.crossRun | appendUniverseAccums | accumulated module by module | strict |
| CrossRun.universeDataCtors | GraphCtx.crossRun | recordCtors | accumulated module by module | strict |
| CrossRun.universeCtorPop | GraphCtx.crossRun | appendDataUniverse | accumulated module by module | strict |
| CrossRun.universeRecordPop | GraphCtx.crossRun | appendDataUniverse | accumulated module by module | strict |
| CrossRun.builtinClassesRef | GraphCtx.crossRun | seedBuiltinClasses (methodRowNumObservation in its probe) | computed once from the prelude's declarations (the core pass), not the whole graph | strict |
| CrossRun.crossModuleFunConstraintDeclaredRef | GraphCtx.crossRun | checkBodyImpl | accumulated module by module | strict |
| CrossRun.crossModuleFunConstraintDeclaredQualRef | GraphCtx.crossRun | checkBodyImpl | accumulated module by module | strict |
| CrossRun.crossModuleMethodPredicateSlotsRef | GraphCtx.crossRun | checkBodyImpl | accumulated module by module | strict |
| CrossRun.crossModuleMethodPredicateSlotsQualRef | GraphCtx.crossRun | checkBodyImpl | accumulated module by module | strict |
| GraphRun.ctorExistentialsRef | GraphCtx.graphRun | recordExistentials | accumulated module by module | strict |
| GraphRun.anyExistentialsRef | GraphCtx.graphRun | recordExistentials | accumulated module by module | strict |
| selectedProfile | driver cell; the typechecker owns its value through TcConfig.tcIoJoin and TcConfig.tcIoJoinProfile | the drivers (see the row above); graphPreamble copies the join through tcConfigOf | selected by the driver before the drive, once per graph | strict |
| GraphCtx.dictEligibleRef | GraphCtx | setDictEligible | computed once from the whole graph's declarations | caveat, derived(cpSchemes) |
| GraphCtx.dictEligibleSetRef | GraphCtx | setDictEligible | computed once from the whole graph's declarations | caveat, derived(cpSchemes) |
| CrossRun.universeFunNamesRef | GraphCtx.crossRun | appendUniverseAccums | accumulated module by module | caveat, derived(cpSchemes) |
| CrossRun.crossModuleFunPredicateSlotsRef | GraphCtx.crossRun | checkBodyImpl | accumulated module by module | caveat, derived(cpSchemes) |
| CrossRun.crossModuleFunPredicateSlotsQualRef | GraphCtx.crossRun | checkBodyImpl | accumulated module by module | caveat, derived(cpSchemes) |
| CrossRun.crossModuleSchemeOblsQualRef | GraphCtx.crossRun | checkBodyImpl | accumulated module by module | caveat, derived(cpSchemes) |
