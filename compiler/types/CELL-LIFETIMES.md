# Typechecker cell lifetimes

One row per piece of mutable typechecker state: the module-level cells of `compiler/types/typecheck.mdk`, the fields of its four bundle records (declared in `compiler/types/tc_types.mdk`) and the fields of the context records that replace them (`DynCtx`, `SiteCtx`), and the cells outside the file that a drive reads or writes. It is the inventory the state-by-lifetime split works from.

Columns: `name | holds | lifetime | owner-today | writers | reset | target | interface-fills | source | issue`.

- `lifetime` is the measured one, from the writers and the reset site, not the declaring comment: `process` (never reset), `config` (set by the driver before the drive), `graph` (re-minted per graph), `module` (re-minted per module), `group` (reset per check group), `run` (saved and restored around one walk), `unknown`.
- `target` is where the cell lands: `TcEnv` (run), `GroupCtx`, `ModuleCtx`, `GraphCtx`, `TcConfig`, `interner` (stays process-wide), `delete` (dead or test-only).
- `interface-fills` is `yes` when a loaded ModuleInterface would have to populate the cell for an importer to typecheck against the module without re-checking it. `source` then names the published fields it derives from (`cpSchemes cpCore cpEvidence cpDispositions`), `derived(<field>)` where a computation over one reproduces it, or `none`. `cpBinders` does not exist in `CheckedProgram` at this base, so binder rows have source `none`.
- Bundle container cells (`driverState`, `crossRun`, `graphRun`, `perRun`) are rows of their own; their fields are the rows that carry the lifetimes.

## Typechecker cells

| name | holds | lifetime | owner-today | writers | reset | target | interface-fills | source | issue |
|---|---|---|---|---|---|---|---|---|---|
| driverState | container: the DriverState bundle; the record is never replaced, only its fields; fields have their own rows | process | module-level | none (fields only) | never | delete | no | - | - |
| crossRun | container: the CrossRun bundle; fields have their own rows | graph | module-level | resetCrossModuleState, checkCoreMemoized (hit install), checkModulesChainReportFor (hit install), probes | resetCrossModuleState (graphPreamble) | delete | no | - | - |
| typeErrorsSticky | build or run abort flag armed at the first recorded type error | process | module-level | recordTypeError | resetTypeErrorsSticky (snapshot.mdk and tests only; production never resets); rolled back by checkGraphFinish, captureTypeErrors, methodReturnOwnershipProbe | GraphCtx | no | - | - |
| typeErrorsStickyDiags | the diagnostics behind the sticky flag | process | module-level | recordTypeError, replaceAmbiguityAt | resetTypeErrorsSticky (snapshot.mdk and tests only); rolled back by checkGraphFinish, captureTypeErrors, methodReturnOwnershipProbe | GraphCtx | no | - | - |
| currentLoc | innermost ELoc span for diagnostics; written about 35 times in save and restore brackets; never reset to None | run | module-level | infer ELoc arm and save-restore brackets | never (not in resetState) | TcEnv | n/a | - | #1752 |
| assumptionTraceEnabled | test-only gate for the assumption trace (set and cleared by begin and finish pairs; no production reader) | run | module-level | begin and finish helpers for the trace | finish helper clears | delete | n/a | - | - |
| assumptionTraceEntries | test-only buffer for the assumption trace (set and cleared by begin and finish pairs; no production reader) | run | module-level | begin and finish helpers for the trace | finish helper clears | delete | n/a | - | - |
| numericPredicateTraceEnabled | test-only gate for the numeric predicate trace (set and cleared by begin and finish pairs; no production reader) | run | module-level | begin and finish helpers for the trace | finish helper clears | delete | n/a | - | - |
| numericPredicateTraceEntries | test-only buffer for the numeric predicate trace (set and cleared by begin and finish pairs; no production reader) | run | module-level | begin and finish helpers for the trace | finish helper clears | delete | n/a | - | - |
| methodReturnTraceEnabled | test-only gate for the method-return trace (set and cleared by begin and finish pairs; no production reader) | run | module-level | begin and finish helpers for the trace | finish helper clears | delete | n/a | - | - |
| methodReturnTraceEntries | test-only buffer for the method-return trace (set and cleared by begin and finish pairs; no production reader) | run | module-level | begin and finish helpers for the trace | finish helper clears | delete | n/a | - | - |
| evidenceObservationEnabled | test-only gate for the evidence observation trace (set and cleared by begin and finish pairs; no production reader) | run | module-level | begin and finish helpers for the trace | finish helper clears | delete | n/a | - | - |
| evidenceObservationEntries | test-only buffer for the evidence observation trace (set and cleared by begin and finish pairs; no production reader) | run | module-level | begin and finish helpers for the trace | finish helper clears | delete | n/a | - | - |
| graphRun | container: the GraphRun bundle; fields have their own rows | graph | module-level | resetGraphLineage, markModules, memo hit installs, probes | resetGraphLineage (via resetGraphState) | delete | no | - | - |
| perRun | container: the PerRun bundle; fields have their own rows | module | module-level | resetState, memo hit installs, enterStampCtx, drainStampQueue | resetState (checkBodyImpl) | delete | no | - | - |
| coreCheckMemoRef | process-wide core-pass memo, one entry | process | module-level | checkCoreMemoized | never (test helper methodReturnMemoTeardownStats clears and restores) | interner | no | - | - |
| preludePreambleMemoRef | prelude preamble memo, one entry of pure values | process | module-level | preludePreambleStore | never | interner | no | - | - |
| moduleChainMemoRef | module-chain prefix memo | process | module-level | checkModulesChainReportFor | never (test helper clears and restores) | interner | no | - | - |
| DriverState.effectDomains | effect label to domain table; builtins seeded then user effect decls registered | graph | DriverState | seedEffectDomains, registerEffectDomain | never | GraphCtx | yes | none | - |
| DriverState.ioJoin | atoms IO joins in this drive, taken from the selected profile | graph | DriverState | setIoJoin, (graphPreamble) | never | TcConfig | no | - | - |
| DriverState.ioJoinProfile | name of the profile ioJoin was taken from; part of the memo keys | graph | DriverState | setIoJoin, (graphPreamble), preludePreambleStore | never | TcConfig | no | - | - |
| DriverState.graphAdmittedMethodsRef | per module (dependency id, method) pairs deAliasMethodImports admitted for dispatch | module | DriverState | renameAliasedMethods | never | ModuleCtx | no | - | - |
| DriverState.declEnvsRef | stage K declaration envelope for the whole graph (deOwnersBefore, deKindsBefore, deIfaces, deImpls, deModules) | graph | DriverState | graphPreamble | never | GraphCtx | yes | none | - |
| DriverState.abstractRecordTypesRef | record types exported abstractly, seeded from decls | graph | DriverState | seedAbstractRecordTypes | never | GraphCtx | yes | none | - |
| DriverState.argDispatchIdxByIdRef | interface method argument dispatch index, from the graph mark sets | graph | DriverState | markSetsOf | never | GraphCtx | yes | none | - |
| DriverState.dictEligibleRef | user function names eligible for dictionary passing (list view) | graph | DriverState | setDictEligible | never | GraphCtx | yes | derived(cpSchemes) | - |
| DriverState.dictEligibleSetRef | set view of dictEligibleRef | graph | DriverState | setDictEligible | never | GraphCtx | yes | derived(cpSchemes) | - |
| DriverState.mangledShadowMapRef | mangled shadow name map from the graph mark sets | graph | DriverState | markSetsOf | never | GraphCtx | yes | none | - |
| DriverState.mangledFunDefsPresentRef | flag: mangled function definitions exist in the graph | graph | DriverState | graphPreamble | never | GraphCtx | no | - | - |
| DriverState.coherenceUserDecls | user declarations for the coherence conflict check | graph | DriverState | setCoherenceUserDecls | never | GraphCtx | no | - | - |
| DriverState.stdlibOwnedModsRef | set of stdlib-owned module ids, from the driver module list | graph | DriverState | setStdlibOwnership | never | GraphCtx | no | - | - |
| DriverState.flatEntryIsStdlibRef | flag: the flat entry is a stdlib module | graph | DriverState | setStdlibOwnership | never | GraphCtx | no | - | - |
| DriverState.builtinExternNamesRef | builtin extern name to (type, arity) catalog from runtime decls | graph | DriverState | noteBuiltinExternNames, restoreCoreDriverFields | never (restoreCoreDriverFields reinstalls on a memo hit) | GraphCtx | yes | none | - |
| DriverState.superDeclsRef | superclass declarations in scope for the module being checked | module | DriverState | checkBodyImpl, drainStampQueue, elabModuleStamp, enterStampCtx, graphModuleWorker, graphPreamble, restoreCoreDriverFields | never (rewritten per module; saved and restored by drainStampQueue) | ModuleCtx | no | - | - |
| DriverState.standaloneValuesRef | standalone value names of the module being checked | module | DriverState | checkBodyImpl, restoreCoreDriverFields | never (rewritten per module by checkBodyImpl) | ModuleCtx | no | - | - |
| DriverState.methodDispatchIdxByIdRef | method dispatch index scratch, set fresh per module | module | DriverState | checkBodyImpl, restoreCoreDriverFields | never (rewritten per module by checkBodyImpl) | ModuleCtx | no | - | - |
| DriverState.matchOracle | constructor oracle for exhaustiveness checks of the current check group | group | DriverState | graphPreamble, restoreCoreDriverFields, seedCheckRun | graphPreamble (tree arm), seedCheckRun | GroupCtx | n/a | - | - |
| DriverState.matchWarnings | match warnings accumulated for the current check group | group | DriverState | checkMatchExhaustive, checkRedundantGo, pushCoherenceWarning, restoreCoreDriverFields, seedCheckRun | seedCheckRun | GroupCtx | n/a | - | - |
| DriverState.promotionHarvestRef | names promoted during the graph, harvested at the end | graph | DriverState | graphModuleWorker, graphPreamble | graphPreamble | GraphCtx | no | - | - |
| DriverState.mainSchemeRef | scheme of the entry main, read for autoprint and the emit path | graph | DriverState | graphModuleWorker, graphPreamble, setMainSchemeIfEntry | graphPreamble (tree arm clears) | GraphCtx | no | - | #2257 |
| DriverState.sigNameSetRef | names with signatures in the module being checked | module | DriverState | processTopGroups, restoreCoreDriverFields | never (rewritten per module by processTopGroups) | ModuleCtx | no | - | - |
| DriverState.sigTyMapRef | signature types of the module being checked | module | DriverState | processTopGroups, restoreCoreDriverFields | never (rewritten per module by processTopGroups) | ModuleCtx | no | - | - |
| DriverState.currentModuleRef | module whose body checkBodyImpl is inferring, tags diagnostics | module | DriverState | checkBodyImpl, drainStampQueue, enterStampCtx | never (rewritten per module; saved and restored by drainStampQueue) | ModuleCtx | no | - | - |
| DriverState.markSetsRef | graph mark sets; also the mode flag for grants (grantsEnabled) | graph | DriverState | markSetsOf | never (None until a preamble runs) | GraphCtx | yes | none | - |
| DriverState.invocationViewRef | last checked module constructors and variance tables for lastInvocationOps | module | DriverState | recordInvocationView | never (rewritten per module) | ModuleCtx | no | - | - |
| CrossRun.universeFunNamesRef | names of functions registered by earlier modules | graph | CrossRun | appendUniverseAccums | resetCrossModuleState | GraphCtx | yes | derived(cpSchemes) | - |
| CrossRun.universeMethodDispatchIdxByIdRef | interface dispatch-index universe keyed by (IfaceRef, method) | graph | CrossRun | appendUniverseAccums | resetCrossModuleState | GraphCtx | yes | none | - |
| CrossRun.universeDataCtors | every registered head with its parameters and constructors, read by tyCarries | graph | CrossRun | recordCtors | resetCrossModuleState | GraphCtx | yes | none | - |
| CrossRun.universeCtorPop | public constructor schemes by declaration identity, grown per module | graph | CrossRun | appendDataUniverse | resetCrossModuleState | GraphCtx | yes | none | - |
| CrossRun.universeRecordPop | public record infos by declaration identity, grown per module | graph | CrossRun | appendDataUniverse, loadDataUniverse | resetCrossModuleState | GraphCtx | yes | none | - |
| CrossRun.builtinClassesRef | identities and presence of the four operator and literal classes read off the prelude interfaces | graph | CrossRun | methodRowNumObservation, seedBuiltinClasses | resetCrossModuleState | GraphCtx | yes | none | - |
| CrossRun.crossModuleFunPredicateSlotsRef | per-function dictionary slots (bare table, PSArgsUnknown) | graph | CrossRun | checkBodyImpl | resetCrossModuleState | GraphCtx | yes | derived(cpSchemes) | - |
| CrossRun.crossModuleFunPredicateSlotsQualRef | per-function dictionary slots keyed (module, name), with signature vectors | graph | CrossRun | checkBodyImpl | resetCrossModuleState | GraphCtx | yes | derived(cpSchemes) | - |
| CrossRun.crossModuleFunConstraintDeclaredRef | declared constraint prefix per function | graph | CrossRun | checkBodyImpl | resetCrossModuleState | GraphCtx | yes | none | - |
| CrossRun.crossModuleFunConstraintDeclaredQualRef | declared constraint prefix keyed (module, name) | graph | CrossRun | checkBodyImpl | resetCrossModuleState | GraphCtx | yes | none | - |
| CrossRun.crossModuleMethodPredicateSlotsRef | per-method predicate slots | graph | CrossRun | checkBodyImpl | resetCrossModuleState | GraphCtx | yes | none | - |
| CrossRun.crossModuleMethodPredicateSlotsQualRef | per-method predicate slots keyed (module, name) | graph | CrossRun | checkBodyImpl | resetCrossModuleState | GraphCtx | yes | none | - |
| CrossRun.coreSchemeObligationsRef | scheme obligations of the core pass, snapshotted after it | graph | CrossRun | checkCoreMemoized | resetCrossModuleState | GraphCtx | yes | derived(cpCore) | - |
| CrossRun.crossModuleSchemeOblsQualRef | every user module scheme obligations keyed (module, name) | graph | CrossRun | checkBodyImpl | resetCrossModuleState | GraphCtx | yes | derived(cpSchemes) | - |
| GraphRun.tyvarCounter | type variable id source; ids stay unique across the graph | graph | GraphRun | newTyvarId | resetGraphLineage (fresh counter) | GraphCtx | yes | derived(cpSchemes) | - |
| GraphRun.effvarCounter | effect variable id source | graph | GraphRun | newEffvarId | resetGraphLineage | GraphCtx | yes | derived(cpSchemes) | - |
| GraphRun.ctorExistentialsRef | quantified authority ids of existential constructor binders | graph | GraphRun | recordExistentials | resetGraphLineage | GraphCtx | yes | none | - |
| GraphRun.patternAuthIdsRef | ids of authority variables minted pattern-ranging | graph | GraphRun | freshAuthvarRanged | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.anyExistentialsRef | flag: some constructor with an existential binder was registered | graph | GraphRun | recordExistentials | resetGraphLineage | GraphCtx | yes | none | - |
| GraphRun.goals | the one channel of route-stamped site goals, drained at graph end | graph | GraphRun | copyGraphRunForMemo, dropGoalsSince, pushGoal, resolveAdmittedSite | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.numlitRefs | numeric literal defaulting channel | graph | GraphRun | pushNumlit | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.numlitN | length of numlitRefs for O(1) marks | graph | GraphRun | pushNumlit | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.activeDictVars | dictionary variables active per tyvar id | graph | GraphRun | registerEachActive, registerEachActiveId, registerImplMethodDictOne, registerOneMethodDict | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.gGiven | given environment keyed by module | graph | GraphRun | pushGiven | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.moduleRanges | per-module channel marks, so the drain cuts a module window | graph | GraphRun | recordModuleStart | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.stampCtxs | one StampCtx per module that finished elaborating, replayed at graph end | graph | GraphRun | drainStampQueue, enqueueStampCtx | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.goalsN | length of goals for O(1) marks | graph | GraphRun | copyGraphRunForMemo, dropGoalsSince, pushGoal | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.evCounter | ordinal source for evidence ids; carried across graph resets so ids never repeat in a process | process | GraphRun | autoPrintEvidence, freshEvId, judgeEvidence, resetGraphLineage | never (resetGraphLineage carries it) | GraphCtx | yes | derived(cpEvidence) | - |
| GraphRun.evBase | evCounter value when this graph lineage began | graph | GraphRun | resetGraphLineage (plain field, re-minted) | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.markedAhead | set by markModules when marking precedes the driver reset | graph | GraphRun | markModules (plain field, re-minted) | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.evJudged | ordinal below which method cells were judged complete | graph | GraphRun | judgeEvidence, resetGraphLineage | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.evTable | solved evidence, one entry per goal, appended at graph-end drain | graph | GraphRun | autoPrintEvidence, recordEvidence | resetGraphLineage | GraphCtx | yes | cpEvidence | - |
| GraphRun.memoMethodReturns | immutable observations of drained ordinary returns, diagnostic only | graph | GraphRun | copyGraphRunForMemo | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.evCells | method occurrence working cells indexed by ordinal less evBase | graph | GraphRun | mintMethodCellRaw (array grown by doubling) | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.siteCells | operator, literal and record-head site cells indexed like evCells | graph | GraphRun | mintSite (array grown by doubling) | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.scopeStore | store of binding scope frames | graph | GraphRun | openScope, closeScope (store mutated in place) | resetGraphLineage (fresh store) | GraphCtx | no | - | - |
| GraphRun.localAbs | dictionary-abstracted local bindings; binder names survive, quantified ids cleared | process | GraphRun | freshLocalAbsName, forgetLocalAbs, recordLocalQuantified, recordLocalRecOcc, registerLocalAbs, resetGraphLineage | never (resetGraphLineage carries it and clears lasQuantified) | GraphCtx | no | - | #4284 |
| GraphRun.grants | authorities granted per occurrence; survives, sourceless set cleared | process | GraphRun | inferMethodAt, inferMethodCandidateAt, instantiateValueTracked, methodGrantUse, resetGraphLineage | never (resetGraphLineage carries it and clears gsSourceless) | GraphCtx | no | - | - |
| GraphRun.binderPending | binders inferred since the last drain with live type cells | graph | GraphRun | materializeBinderTypes, recordBinderType | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.binderRows | runtime-type table of materialized binder rows this graph publishes | graph | GraphRun | materializeBinderTypes | resetGraphLineage | GraphCtx | yes | cpBinders | - |
| GraphRun.liveRoots | open variables non-generalized members left at module end, emptied by every drain | graph | GraphRun | defaultLiveNumRoots, recordLiveRoots | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.liveNumRoots | the Num-constrained subset of liveRoots, emptied by every drain | graph | GraphRun | defaultLiveNumRoots, recordLiveRoots | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.liveNumGoals | goals on liveNumRoots, emptied by every drain | graph | GraphRun | defaultLiveNumRoots, recordLiveRoots | resetGraphLineage | GraphCtx | no | - | - |
| GraphRun.liveGoals | goals boundaries held on live variables, emptied by every drain | graph | GraphRun | judgeLiveGoals, recordLiveRoots | resetGraphLineage | GraphCtx | no | - | - |
| PerRun.currentScope | cursor of the open binding scope | run | PerRun | closeScope, openScope | resetState | TcEnv | n/a | - | - |
| PerRun.admittedOccObls | method occurrences whose spelling has two or more admitted declarations, checked once the receiver grounds | module | PerRun | pushAdmittedOccObl | resetState | ModuleCtx | no | - | #2705 |
| PerRun.curEffect | effect rows performed by the expression being inferred | run | PerRun | performEffect, captureEffects | resetState | TcEnv | n/a | - | - |
| PerRun.effectSummaries | effect summary solver state across scopes | module | PerRun | beginEffectSummaryScope, EffectSolver.* (solver value) | resetState | ModuleCtx | no | - | - |
| PerRun.pendingJoinsRef | joins of alternatives with no shape yet, decided when the scope closes | group | PerRun | deferJoin, postponePendingJoins, resolvePendingJoins, settlePending, settlePendingJoins, takeJoinsShapedBy | resetState | GroupCtx | n/a | - | - |
| PerRun.fileValueFlows | windowed file-value flows, cut by finishFileValueScope | module | PerRun | finishFileValueScope, recordFileValueFlow, unifySpineProbe | resetState | ModuleCtx | no | - | - |
| PerRun.fileValueScopes | stack of open file-value scopes | run | PerRun | beginEffectSummaryScope, finishFileValueScope | resetState | TcEnv | n/a | - | - |
| PerRun.rigidEffvarsRef | effect variables rigid inside the current contract | run | PerRun | beginEffectContract, finishEffectContract, processSCC, unifyRowPlain | finishEffectContract restores; resetState | TcEnv | n/a | - | - |
| PerRun.rigidAuthvarsRef | authority variables rigid inside the current contract | run | PerRun | beginEffectContract, finishEffectContract, freshAuthSubstOpeningIn, processSCC | finishEffectContract restores; resetState | TcEnv | n/a | - | - |
| PerRun.effectSitesRef | first site per (binding, label) that performed the label | module | PerRun | recordEffectSites | resetState | ModuleCtx | no | - | - |
| PerRun.rowFailureReportedRef | bindings whose row failure the scoped solver already reported | module | PerRun | reportEffectSummaryFailures | resetState | ModuleCtx | no | - | - |
| PerRun.typeErrorKeySetRef | dedup set of (code, location, message) triples | module | PerRun | pushTypeErrorAt | resetState | ModuleCtx | no | - | - |
| PerRun.escapedExistentialsRef | existential cells reported as escaping their scope | module | PerRun | closeExistentialScope | resetState | ModuleCtx | no | - | - |
| PerRun.openedAuthvarsRef | cells a pattern opened for an existential binder | module | PerRun | freshAuthSubstOpeningIn | resetState | ModuleCtx | no | - | - |
| PerRun.indexSubstitutedRef | index variables an index equality substituted a term for | module | PerRun | substituteIndexLinked | resetState | ModuleCtx | no | - | - |
| PerRun.extendedBindersRef | authority variables an argument extended on the right | module | PerRun | noteArgumentShape | resetState | ModuleCtx | no | - | - |
| PerRun.displayHiddenBindersRef | authority variables an interpolation hid behind a non-prelude display | module | PerRun | noteArgumentShape | resetState | ModuleCtx | no | - | - |
| PerRun.openedExistentialsRef | existential cells opened at the pattern site being inferred | run | PerRun | openExistentials, parkOpenedExistentials, refuseOpenedExistentials, takeOpenedExistentials | resetState | TcEnv | n/a | - | - |
| PerRun.openedExistentialsStackRef | stack of parked opened-existential lists | run | PerRun | parkOpenedExistentials, refuseOpenedExistentials | resetState | TcEnv | n/a | - | - |
| PerRun.recordByNameRef | record infos by name, seeded each module from universeRecordPop | module | PerRun | loadDataUniverse, overrideScopedRecords, registerCachedRecord, registerRecordInfoKeyed | resetState | ModuleCtx | no | - | - |
| PerRun.fieldOwnersRef | field name to owning records, seeded each module | module | PerRun | declEnvSeedDataUniverse, registerCachedRecord, registerRecordInfoKeyed | resetState | ModuleCtx | no | - | - |
| PerRun.dataParamKindsRef | kinds of data type parameters, seeded each module | module | PerRun | declEnvSeedDataUniverse, recordParamKinds, withDeclParamKinds | resetState | ModuleCtx | no | - | - |
| PerRun.dataParamNameIndexRef | name-only index over dataParamKindsRef keys | module | PerRun | declEnvSeedDataUniverse, recordParamKinds, withDeclParamKinds | resetState | ModuleCtx | no | - | #2158 |
| PerRun.dataParamPolarityRef | variance twin of dataParamKindsRef | module | PerRun | declEnvSeedDataUniverse, recordParamPolarities, seedParamPolarityFixpointScoped | resetState | ModuleCtx | no | - | #1119 |
| PerRun.dataParamRowAtomsRef | atoms each KRow parameter is charged at every occurrence | module | PerRun | declEnvSeedDataUniverse, recordParamRowAtoms | resetState | ModuleCtx | no | - | #2110 |
| PerRun.aliasTableRef | type alias table, seeded each module | module | PerRun | loadDataUniverse, registerData | resetState | ModuleCtx | no | - | - |
| PerRun.numLitFromIntAnchorRef | identity-selected prelude Num.fromInt descriptor row | module | PerRun | seedNumLitFromIntAnchor | resetState | ModuleCtx | no | - | - |
| PerRun.definerShadowNamesRef | definer-shadow names in scope for the current group | group | PerRun | checkBodyImpl | resetState | GroupCtx | n/a | - | - |
| PerRun.definerShadowSigsRef | signatures of definer-shadow names | module | PerRun | checkBodyImpl | resetState | ModuleCtx | no | - | - |
| PerRun.bodyImplEnvRef | impl environment of the module body being checked | module | PerRun | checkBodyImpl, methodReturnProbeCodes, methodReturnProbeStamp, methodReturnResolutionMutationProbe | resetState | ModuleCtx | no | - | - |
| PerRun.methodAliasEntriesRef | alias method spellings the imports supply, mapped to declaration entries | module | PerRun | checkBodyImpl, methodReturnProbeSpelling | resetState | ModuleCtx | no | - | #1386 |
| PerRun.methodScopeCtxRef | this module decls and ordinal, inputs of methodScopeHere | module | PerRun | checkBodyImpl | resetState | ModuleCtx | no | - | #2563 |
| PerRun.methodScopeMemoRef | methodScopeAt answers for spellings read in this module | module | PerRun | methodScopeHere | resetState | ModuleCtx | no | - | #2563 |
| PerRun.aliasMethodOriginsRef | alias-qualified method spellings mapped to origin method names | module | PerRun | checkBodyImpl | resetState | ModuleCtx | no | - | #1386 |
| PerRun.implObls | windowed impl obligation channel | module | PerRun | checkMethodBodyAgainst, inferUserImplBodies, pushExactReturnObl | resetState | ModuleCtx | no | - | #841 |
| PerRun.poisonedVars | type variables poisoned by a mismatch, to suppress follow-on errors | module | PerRun | checkSigVarGoal, poisonMismatchVars, propagatePoison | resetState | ModuleCtx | no | - | - |
| PerRun.deferrableVarIds | quantified variable ids of generalized schemes; undetermined goals on them defer into the scheme | module | PerRun | registerSchemeObligations | resetState | ModuleCtx | no | - | #838 |
| PerRun.liveMemberMonosRef | types of closed top-level members that left a variable open | module | PerRun | liveMemberIds | resetState | ModuleCtx | no | - | - |
| PerRun.quiescentGoalsRef | goals on live-member variables with their boundary data | module | PerRun | judgeQuiescentGoals, undeterminedVectorVerdict | resetState | ModuleCtx | no | - | - |
| PerRun.heldLiveGoalsRef | goals a boundary held without a verdict | module | PerRun | undeterminedVectorVerdict | resetState | ModuleCtx | no | - | - |
| PerRun.determinedRowsRef | impl row chosen by each determination commit, by variable | module | PerRun | fileDeterminedRow, refileDeterminedRows | resetState | ModuleCtx | no | - | - |
| PerRun.declaredSigVarIds | variables a closed binder declares, held rigid | module | PerRun | declareRigidVars | resetState | ModuleCtx | no | - | - |
| PerRun.tupleCallCandidates | tuple-call hint candidates | module | PerRun | inferAppExpr | resetState | ModuleCtx | no | - | - |
| PerRun.numlitVarLocs | numeric literal variable locations | module | PerRun | recordNumlitLoc | resetState | ModuleCtx | no | - | - |
| PerRun.patLitPending | integer literal patterns since the enclosing pattern site began | run | PerRun | inferIntLitPat, settlePatLitsOnly, takePatLits | resetState | TcEnv | n/a | - | - |
| PerRun.patLitDeferred | integer literal patterns whose scrutinee type was unknown at their site | module | PerRun | settleDeferredPatLits, settlePatLitsGo | resetState | ModuleCtx | no | - | - |
| PerRun.matchChecksDeferred | matches whose scrutinee type was unknown after their arms, checked at module end | module | PerRun | inferMatch | resetState | ModuleCtx | no | - | - |
| PerRun.numlitRanges | source integer literals for the fixed-width range check | module | PerRun | recordNegatedLitRange, recordNumlitRange, settlePatLitsGo | resetState | ModuleCtx | no | - | - |
| PerRun.wideLitRanges | wide literals for checkWideLiterals | module | PerRun | inferWideLit, recordNegatedLitRange | resetState | ModuleCtx | no | - | - |
| PerRun.numlitUntainted | numeric literal locations not tainted by an operator | module | PerRun | markNumlitOpTaint, recordNumlitLoc | resetState | ModuleCtx | no | - | - |
| PerRun.numlitOpLocs | operator locations of numeric literals | module | PerRun | taintAndDrop | resetState | ModuleCtx | no | - | - |
| PerRun.numlitCtxTags | numeric literal locations tagged with join context | module | PerRun | tagLitLocsWithRoot | resetState | ModuleCtx | no | - | - |
| PerRun.localBindRefs | local bindings with their types, for tooling tables | module | PerRun | recordLocalBind | resetState | ModuleCtx | no | - | - |
| PerRun.localSchemesOut | local schemes captured for the entry tables (captureEntryTables) | module | PerRun | checkBodyImpl | resetState | ModuleCtx | no | - | - |
| PerRun.seedSchemesOut | import seed schemes captured for the entry tables | module | PerRun | checkBodyImpl | resetState | ModuleCtx | no | - | - |
| PerRun.funPredicateSlotsRef | function dictionary slots, seeded from crossRun and written back per module | module | PerRun | checkBodyImpl, setFunConstraintEntry, setFunPredicateSlots | resetState | ModuleCtx | no | - | - |
| PerRun.funPredicateSlotsIdxRef | first-wins index over funPredicateSlotsRef | module | PerRun | setFunConstraintEntry, setFunPredicateSlots | resetState | ModuleCtx | no | - | - |
| PerRun.funConstraintDeclaredRef | declared constraint prefixes, seeded from crossRun | module | PerRun | checkBodyImpl, dictPassModulesIfEnabled, dictPassModulesScoped | resetState | ModuleCtx | no | - | - |
| PerRun.currentImportDefinersRef | imported definer names of this module imports | module | PerRun | checkBodyImpl | resetState | ModuleCtx | no | - | - |
| PerRun.currentImportOriginsRef | imported origin names of this module imports | module | PerRun | checkBodyImpl | resetState | ModuleCtx | no | - | - |
| PerRun.importedSchemeOblsRef | scheme contexts of this module imported bindings, by local spelling | module | PerRun | checkBodyImpl | resetState | ModuleCtx | no | - | #1114 |
| PerRun.obls | windowed call obligation channel | module | PerRun | inferUserImplBodies, recordOblAt | resetState | ModuleCtx | no | - | #838 |
| PerRun.absorptions | row-unifier atom-discard trail, write-only | module | PerRun | recordAbsorptions | resetState | ModuleCtx | no | - | #839 |
| PerRun.schemeObligationsRef | scheme obligations keyed (name, binding id) | module | PerRun | registerSchemeObligations | resetState | ModuleCtx | no | - | #837 |
| PerRun.schemeDefIdsRef | top-level value binder to binding id | module | PerRun | checkBodyImpl | resetState | ModuleCtx | no | - | #837 |
| PerRun.methodPredicateSlotsRef | method predicate slots, seeded from crossRun | module | PerRun | checkBodyImpl, dictPassModulesIfEnabled, dictPassModulesScoped, methodReturnProbeSlotCase, setMethodPredicateSlotEntry | resetState | ModuleCtx | no | - | - |
| PerRun.currentFn | top-level function whose body is being inferred | run | PerRun | inferMembers, inferMethodBody | resetState | TcEnv | n/a | - | - |
| PerRun.currentImplBody | true while inferring an impl method body | run | PerRun | inferMethodBody | resetState | TcEnv | n/a | - | - |
| PerRun.methodSiteFns | method site mono lists per function | module | PerRun | recordArgSiteFn, recordNumLitSite, recordSite | resetState | ModuleCtx | no | - | - |
| PerRun.dictAppFns | dictionary application mono lists per function | module | PerRun | inferDeclaredDictAt, pushLocalDictApp | resetState | ModuleCtx | no | - | - |
| PerRun.residualUnivRef | impl universe for residual predicate walks | module | PerRun | checkBodyImpl | resetState | ModuleCtx | no | - | - |
| PerRun.promotedRef | names promoted by inference | module | PerRun | registerInferredFor | resetState | ModuleCtx | no | - | - |
| PerRun.fieldOwnerModulesRef | field-owner key to declaring module ids; comment says graph-global but it is re-minted per module | module | PerRun | declEnvSeedDataUniverse | resetState | ModuleCtx | no | - | #1597 |
| PerRun.fieldOwnerReachRef | module ids this module can reach through DUse | module | PerRun | declEnvSeedDataUniverse | resetState | ModuleCtx | no | - | #1597 |
| DynCtx.dcJoin | the construct whose alternatives a value join is equating, which names the mismatch | run | DynCtx | joinValueEqual | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| DynCtx.dcNonCovariant | inside a non-covariant type argument, where two closed effect rows must be equal | run | DynCtx | paramVarianceGuard | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| DynCtx.dcSuppressRLocalRecord | typing a definer-shadow occurrence that heads an application, so recordRLocalSite pushes nothing | run | DynCtx | inferDefinerShadowAppAt | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| DynCtx.dcSuppressArgStamp | typing a definer-shadow occurrence that heads an application, so recordArgStamp pushes nothing | run | DynCtx | inferDefinerShadowAppAt | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| DynCtx.dcShadowHeadCtx | typing a shadow occurrence that heads its own application, so the value-position standalone pin does not apply | run | DynCtx | shadowHeadEnv (callers: inferShadowAppHead, shadowVarHeadMethodScheme, inferDefinerStandaloneVarAppAt) | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| DynCtx.dcDo | inside a do-lowered chain, where a monad-shape mismatch reads as "do requires a monad" | run | DynCtx | infer (the EDoOrigin arm, which installs the DoCtx); recordDoMonadError (sets the Ref `doReported` in the installed DoCtx) | none for the field (immutable; a nested walk gets an updated copy); the `doReported` Ref inside it is mutable, set once per region by recordDoMonadError and fresh in each nested do | TcEnv | n/a | - | - |
| DynCtx.dcMethodMismatch | unifying an interface default body against its declared type, so a leaf mismatch names the method | run | DynCtx | checkMethodBodyAgainst | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| SiteCtx.sxSite | the span of the dispatch site being resolved, for a diagnostic raised where no span argument exists | run | SiteCtx | resolveArgStamps, resolveSites, resolveRLocalSites, resolveOpSites, resolveDictApps, checkEnteredReqs, checkImplHeadGoal, residualBoundPreds | none (immutable; a nested walk gets an updated copy) | TcEnv | n/a | - | - |
| SiteCtx.sxInner | the notes accumulator of the running stamp, which each route built below the top level is ORed into | run | SiteCtx | routeWalkMemoized, stampNoting (install the accumulator); noteInner (ORs into the Ref content) | none for the field (immutable; a nested walk gets an updated copy); the accumulator Ref content is mutable and ORed monotonically by noteInner during the stamp | TcEnv | n/a | - | - |
| PerRun.typeErrors | windowed diagnostic output channel | module | PerRun | recordTypeError, replaceAmbiguityAt | resetState | ModuleCtx | no | - | #1146 |
| PerRun.typeErrorMsgSetRef | membership index over typeErrors rendered messages | module | PerRun | recordTypeError, replaceAmbiguityAt | resetState | ModuleCtx | no | - | #2068 |
| PerRun.ambiguitySitesRef | spans holding a T-AMBIGUOUS-INSTANCE | module | PerRun | pushAmbiguityAt | resetState | ModuleCtx | no | - | - |
| PerRun.ambiguityVarsRef | boundary-owned variables already reported ambiguous | module | PerRun | pushBoundaryAmbiguity | resetState | ModuleCtx | no | - | - |
| PerRun.errorsDetected | control signal counting detected type errors | module | PerRun | noteTypeErrorDetected | resetState | ModuleCtx | no | - | #1146 |
| PerRun.occursCheckFailed | set by bindVar on an occurs failure, read and cleared by the caller | run | PerRun | bindValueUpper, bindVar, occursAdjustUnbound | resetState | TcEnv | n/a | - | - |
| PerRun.currentLevel | inference level counter | run | PerRun | enterLevel, exitLevel, lowerToCurrent | resetState | TcEnv | n/a | - | - |
| PerRun.markingRef | module marking from beginModuleMarking | module | PerRun | beginModuleMarking | resetState | ModuleCtx | no | - | - |

## Cells outside the file

| name | holds | lifetime | owner-today | writers | reset | target | interface-fills | source | issue |
|---|---|---|---|---|---|---|---|---|---|
| selectedProfile | target profile selected by the driver (types/target_profile.mdk); typecheck reads it once in graphPreamble via setIoJoin; published types depend on its IO join | config | module-level | mcp.mdk, entry_support.mdk, playground_main.mdk, medaka_cli.mdk, build_cmd.mdk, profile_select.mdk, tests | build_cmd saves it, clears it, and restores it around a build; mcp.mdk and profile_select.mdk set it back to None when no profile is selected | TcConfig | yes | none | - |
| binderOrdinalRef | desugar binder ordinal counter (frontend/desugar.mdk); ordinals are never reused within a process | process | module-level | freshBinderId | never | interner | no | - | - |
| preludeScopeMemoRef | prelude scope memo, one entry (frontend/resolve.mdk) | process | module-level | preludeScopeFor | never | interner | no | - | - |
| loadedSourcesRef | path to source text of every loaded file (driver/loader.mdk, the one driver.loader cell in cells.golden) | process | module-level | noteLoadedSource | never | interner | no | - | - |
| program_facts.currentFacts | the ProgramFacts value lowering and eval read for the run in progress (types/program_facts.mdk); deleted by the issue "thread ProgramFacts through lower and EvalEnv" | run | module-level | withFacts | withFacts restores the previous value | delete | n/a | - | #4317 |
