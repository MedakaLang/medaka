## Nominal assumption ownership slice

Parent design: #2549 phase 2 / #1122, `compiler/TYPECHECK-CONTRACTS.md` §§2–6 and `compiler/TYPECHECK-SOLVER-MIGRATION.md`. Concrete existing-semantics bug: #2895. This is the first production consumer of the new scope/binder/evidence contracts, before the complete return-family migration. It does not complete package 2.

The `foo`/`foo_bar` reproducer selects a sibling's dictionary via generated-name prefix matching. DICT §3 already requires the lexical given. Both declaration orders must print `7` through the interpreter and native execution, and continue checking successfully. No language-policy change is proposed.

### API and placement

Keep the state adapter private in `compiler/types/typecheck.mdk`; reuse `ScopeId`, `EvidenceBinderId`, and `GivenEvidence` from `compiler/types/evidence.mdk`.

- `ScopeFrame { id, parent, level, moduleId, renderOwner }` contains immutable values only. Graph-owned indexed storage holds the frames and a fresh scope counter; `PerRun.currentScope : Ref ScopeCursor` records the active lexical owner.
- Mint a distinct frame at each top-level binding, default body, impl-method body, test and prop body, with valid roots for both Flat and Module inference. Local bindings inherit until #1082; this is an explicitly incomplete local-scope carveout, not completion of general lexical nesting. Preserve the actual frame used during body inference through delayed registration, including positional pairing of impl methods and their scopes. Never recover scope by method spelling.
- `GivenEntry.geBinder : EvidenceBinderId` replaces `geDict : String`; its ordinal is the existing dictionary parameter slot. Registration receives the scope/binder explicitly. One rendering helper resolves the frame owner and applies existing `dictParamName owner ordinal`.
- Carry mandatory `ScopeId` beside the existing enclosing name through every deferred carrier reaching assumption selection: checker `UObligation` (all real and synthetic producers), route `Obligation`/`PendingEntry`, dictionary applications, method dictionaries and recursive dictionary applications. Preserve it through nested requirement checks, draining and replay. An absent active scope outside inference never licenses an unscoped goal or fallback. Keep the enclosing name only for unmigrated name/instance routing and rendering.
- `givenVisibleFrom : ScopeId -> ScopeId -> Bool` accepts the same scope or a lexical ancestor. Predicate lookup combines this relation with existing full-vector/interface identity and `GivenMatch`/id-witness checks. Derive the module bucket from the captured goal's `ScopeFrame.moduleId`, not the ambient module. It is a cross-module barrier and lookup partition, never an alternative lexical visibility rule.
- Change `activeDictVars` to `Ref (List (Int, EvidenceBinderId))`. Registration stores binder identity; scalar readers take mandatory occurrence scope and filter visibility before rendering. This includes `firstDictForEncl`, `activeDictVarForEncl`, `activeDictVarOf`, `enclDictVarOf`, `opDictVarOf` and `checkUndeterminedObligation`'s ambiguity suppression. Keep scalar and predicate matching separate and preserve their existing precedence.
- Give predicate entries `DirectGiven | LegacySuperclassAlias` provenance, independently of `GivenMatch`. Only direct predicate givens produce `GivenEvidence binder`. Superclass-expanded aliases and scalar-only matches remain explicitly legacy answers carrying nominal binders; they do not assert that one binder inhabits multiple predicates. `AssumAnswer = SemanticGiven SolverEvidence | LegacyScalar EvidenceBinderId | LegacyPredicate EvidenceBinderId | LegacySuperAlias EvidenceBinderId` is immediately lowered to the old route representation. Preserve each `EntailKind`'s existing lookup order: `EKNestedTop` already tries function predicate givens before its scalar fallback, while other kinds have their own scalar/impl-requires precedence. Every assumption path still precedes instance selection. No instance or superclass evidence is fabricated; #993 retains semantic superclass projection ownership.

### Required deletions and explicit residuals

Delete `GivenEntry.geDict`, scalar/predicate dictionary-string ownership storage, all prefix visibility tests in scalar and predicate assumption helpers, and `activeDictPredOf`'s unscoped module fallback. `goalMatchesGiven`/`anyGivenMatches` must receive the originating `UObligation`'s scope and use the same lexical visibility relation: module-wide matching is not an allowed exception. The scalar ambiguity check and in-impl operator bypass also query with captured scope.

Retain the scalar registry and its lookup rungs as distinct legacy matching mechanisms, now nominally owned; their semantic consolidation remains later work. Preserve the operator bypass's parameter-offset and matching policy while fixing its ownership. Qualified-scheme production/generalization, superclass projection, instance selection, final report publication and the atomic return-family deletion set remain later work.

### Cache and performance boundary

`copyGraphRun` copies the frame array into a fresh array with fresh array/counter refs. Frames must contain no `Ref`, `Mono`, `PredicateSlot`, or mutable collection. Scope ordinals are request-local and may repeat across disjoint graph namespaces; never compare them across requests. Existing `gGiven` predicate/Mono replay remains mutable legacy scaffolding, so this slice neither publishes semantic evidence nor claims finalized immutable caching. The return vertical still owes the parent design's cache replacement/bypass.

Use indexed frame lookup and bounded lexical-parent walks, not a graph-wide list scan per goal. Measure the existing LSP cold/warm instruction-count instrument (~25% soft budget). Observe scope-frame counts and retention across fresh/copy/restore/reset, including detached storage writes. Existing instruments do not expose retained live heap at matched LSP lifecycle points; that measurement remains explicit package-7 instrumentation debt. Do not label peak RSS or frame counts as live-heap measurements. Source soundness and semantic checks remain separate from these measurements.

### Acceptance and fail capability

- Pin both #2895 structured impl orders and the all-bare nested-call method orders: check succeeds, interpreter prints `7`, built binary prints `7`. Add crossed interface/method order and direct-global controls. The evidence observation must distinguish selecting the correct given from silently falling back to the global instance.
- Preserve structured/n-ary givens, given-before-instance precedence, superclass forwarding, `impl_requires_structured_overlap`, `impl_requires_nonfunctor_sibling`, and recursive forwarding.
- Preserve same-name controls in both import orders: both actual methods reject; one actual method plus the other interface name prints `1`; standalone SHADOW S4/I9 prints `901`. Add an internal observation proving same-spelled owners receive distinct binder identities; name rendering alone is not evidence identity.
- Observe direct predicate-given evidence before route lowering in a production Module-path probe, with legacy superclass aliases visibly distinguished. Test distinct sibling ownership, ancestor visibility in the scope service, outer given visibility through an inherited local body, id-witness versus full-predicate matching, and a foreign-scope negative for `anyGivenMatches`. Pin the in-impl operator bypass, `++` and unary residual cases.
- Mutation checks: restoring prefix selection fails #2895; dropping the scope filter from `anyGivenMatches` fails the foreign-scope negative; equating binder identities by rendered owner fails the nominal identity observation.
- Same-process cold P versus P → failed/conflicting Q → P, including cache hits, preserves the new scope/binder ownership observations. Existing `test/diff_compiler_lsp.sh` P6 separately pins diagnostics. It does not observe schemes, residuals or evidence; full finalized-result comparison and graph-instance invalidation remain package-7 acceptance obligations unless explicitly exercised by the new probe. Do not claim the diagnostic-only gate covers them.
- Fresh build, fmt/lint, targeted dictionary/scope/cache gates, source soundness and self-hosting fixpoint. Extend existing registered gates and compiler sibling tests with explicit Makefile enrollment; avoid an unregistered standalone gate.

Stop and revise this packet if preserving body identity requires a spelling-keyed map, if visibility requires retaining a prefix fallback, if a frame acquires mutable type state, or if carrier threading cannot remain one coherent production change. A standalone unused scope schema or observe-only service call is not an acceptable substitute.

### Concrete carrier and test appendix

Private adapter declarations in `typecheck.mdk`:

```text
ScopeOwner = ModuleOwner | BindingOwner String | PropOwner String | TestOwner String
ScopeCursor = ScopeClosed | ScopeOpen ScopeId
freshScope : Option ScopeId -> Int -> String -> ScopeOwner -> ScopeId
captureScope : Unit -> ScopeId
scopeFrame : ScopeId -> ScopeFrame
givenVisibleFrom : ScopeId -> ScopeId -> Bool
binderAt : ScopeId -> Int -> EvidenceBinderId
renderEvidenceBinder : EvidenceBinderId -> String
```

`captureScope` on `ScopeClosed`, a missing frame, or rendering a binder outside a binding owner is an internal invariant failure, never a spelling/module fallback. `ScopeFrame` stores `id`, `parent`, `level`, `moduleId`, and `owner`. Graph storage grows geometrically, like existing evidence-cell storage.

`checkBodyImpl` sets the module identity, performs the existing Flat graph reset where required, resets `PerRun`, and opens the module root before `recordModuleStart` or any obligation producer. Capture checker/stamper work before closing the cursor. Draining uses captured scopes. `inferPropBodiesGo` and `inferTestBodies` bracket their respective body scopes.

`processSCC` creates positionally aligned `ScopedMember { name, mono, scope }` values after placeholders. `inferMembers` opens that member's exact scope. Signature pre-unification returns `ConstraintReg { name, scope, ifaceMonos, argVecs }`; `registerConstraintRegs` consumes its scope. Pair returned schemes back with the same members (assert matching names) into `ScopedScheme` values for inferred registration, then project the existing public scheme pairs. A name assertion checks alignment; it never supplies identity.

`inferRequiresImpl` pre-mints `ScopedImplMethod { method, scope }`. Both method inference and delayed `registerImplRequires` traverse that same list. Shared impl type roots still settle before registration. Default body scope stays open through its scalar/predicate registration. These changes apply in the shared helpers used by both Flat and Module paths.

Add a mandatory scope field to `UObligation`, `Obligation`, `PendingEntry`, `PendingDictApp`, `PendingMethodDict`, and `RecDictApp`. Producers capture it once. `checkCallObligationsU` passes the source obligation scope through `checkOneCallObligation`, its no-instance path, `checkNestedReqs`, `checkReqObligations`, and `checkReqOne`; both `goalDefersOpenWorld` sites and `checkUndeterminedObligation` receive it. `registerAmbiguousGo/One/Dispatch` preserve their source obligation's scope. Add `callUOblsWindow` so `numCallObls` can copy scope instead of reading the lossy tuple window; `numDictObls` copies the pending dictionary application's scope. Synthetic goals must either inherit a source goal scope or capture an active valid body/module scope explicitly.

The same `binderAt bodyScope slot` feeds both indexes. `registerFunPredGiven` marks the original slot direct and its transitive-super tail legacy. Only an exact direct predicate match may become semantic given evidence. Every id-only scalar answer stays legacy, including an enclosing-name helper's id-only arm.

The opt-in observation API is exported from `typecheck.mdk` for its subject sibling:

```text
AssumptionTraceKind = ATDirectPredicate | ATLegacyScalar | ATLegacyPredicate | ATLegacySuperclass
AssumptionTraceEntry = { atGoalScope : ScopeId,
                        atBinder : EvidenceBinderId,
                        atKind : AssumptionTraceKind }
beginAssumptionTrace : Unit -> Unit
finishAssumptionTrace : Unit -> List AssumptionTraceEntry
scopeFrameStats : Unit -> (Int, Int)
scopeTraceContext : ScopeId -> (String, String)
```

`scopeTraceContext` returns immutable module/owner display labels for observing a live request; it is never a lookup key for selection. Begin clears/enables a dedicated instrumentation buffer outside replayed state. Finish disables, returns oldest-first entries, and clears. One note point records the final assumption answer before rendering; disabled instrumentation checks one Boolean and allocates nothing. This does not write `EvTable` or discharge draft `FactEvidence`.

Add `compiler/types/typecheck_test.mdk`, reached by the existing `./medaka test compiler/types` Makefile directory target. It uses the real Module API and the trace API to distinguish direct predicate, scalar legacy and superclass legacy selection. Observe distinct same-rendering binders within a request; compare independent requests by ownership relationships and display context, not numerical `ScopeId` equality. Test private frame-copy/visibility invariants through a narrow exported test probe or same-file doctests if they cannot be exercised through this public observation surface; do not export mutable graph state. The local fixture proves inherited same-scope forwarding; a service test supplies the ancestor proof.

Name the external regressions `test/dict_fixtures/s3-scope-prefix-predicate-{foo-first,foo-bar-first}.mdk`, `s3-scope-prefix-scalar-nested-{foo-first,foo-bar-first}.mdk`, and `s3-scope-local-inherits-outer-given.mdk`, enrolled in `test/diff_compiler_dict_semantics.sh`. Reuse its structured, n-ary, superclass, recursive, operator and SHADOW controls; add the measured import-order cases if absent. Keep `compiler/types/solver_contract_test.mdk` focused on the foundation contract.

Run `test/diff_compiler_lsp.sh` for the existing failed-request/cache-hit diagnostic seam. The new sibling compares fresh real-Module P, repeat P, P → failed Q → P and P → conflicting Q → P for scope ownership and bounded frame retention. A cache hit may legitimately perform no new assumption lookup: do not confuse an empty trace with lost evidence, or claim replayed semantic evidence is observed. Separate uncached user-body trace assertions from cache-copy/frame and diagnostic assertions. Full cache artifact comparisons remain the package-7 obligation above.

Performance commands and validated N=0..3 request streams are in `/tmp/rearch-scope-perf/run_lsp_cachegrind.py`; record reproducible commands/results in the branch's design ledger when validating. Base is `2b6e08c8d`, with cold/warm `Ir` of 356,961,559/24,936,667 (playground) and 593,052,249/38,318,523 (import-list). Both N=3 warm repeats were stable. Use the same source inputs, heap and lifecycle points for the changed arm.

Implementation clarification (issue comment 5639483714): known full-vector direct matches alone construct `GivenEvidence`. Unknown-vector/id-assisted predicate matches and the #1318 spelling-only residual use `LegacyPredicate` / `ATLegacyPredicate`; scalar-only and superclass answers retain their distinct legacy kinds. This classifies the existing answer without changing route selection. The private selection probe distinguishes complete direct, incomplete predicate and superclass cases.
