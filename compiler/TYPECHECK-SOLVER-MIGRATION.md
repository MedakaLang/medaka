# Scoped solver: first return-position migration

**Status:** proposed design for #2549 contract package 2, with package 7 designed
alongside it. This is a design record on the running branch, not an implementation
or a completion claim. The owning issue must carry this record before its first
implementation slice, as required by [destination contract §6](TYPECHECK-CONTRACTS.md).

The architecture baseline is `2b6e08c8d`; the current packet head is `f57016b44`,
which adds the closed test/prop defaulting prerequisite. The destination contract
governs this design;
[DICT](../docs/spec/DICT-SEMANTICS.md),
[effects](../docs/spec/EFFECTS-SEMANTICS.md),
[shadowing](../docs/spec/SHADOW-SEMANTICS.md), and
[HM](../docs/spec/HM-CORE-SEMANTICS.md) govern behavior. The September 10 ruling on
#2549 selects return-position dispatch as the first vertical migration. It does
not select further driver cleanup, #993, or namespace completion as the next unit.

## Boundary and invariant

Today a return-position method occurrence can enter both the ordinary obligation
checker and the return-site stamper. Their independent judgments can disagree.
The migrated family will have one scoped wanted and one solver outcome. Checking
and evidence publication consume that outcome. Legacy routes are derived once
from the chosen evidence; neither the adapter nor downstream consumers may select
an instance again.

This retains eager HM unification, the existing SCC schedule, value restriction,
effect rules and strict evaluation. It does not enable local dictionary abstraction
(#1082), implement superclass evidence (#993), or change the warning policy for
unresolved goals. A first migrated family does not constitute a CheckedProgram or
complete M2.

## Data contracts and placement

All names in this section are proposed. Request data may contain live inference
variables; published and cached data may not.

| Contract | Required information |
|---|---|
| Goal identity | Module identity and a request-local nominal ordinal, independent of source location and spelling |
| Scope identity | Request-local nominal identity, parent scope and inference level |
| Evidence binder identity | Nominal binder identity and owning scope; dictionary names are renderings |
| Wanted | Goal identity, full interface predicate, origin, lexical scope and evidence destination |
| Qualified scheme | Existing HM scheme plus an ordered list of predicate/evidence-binder pairs |
| Solved | Request-owned semantic evidence for that wanted |
| Deferred | Original wanted plus blocking variables, scope or whole-graph finalization dependency |
| Insoluble | Original wanted plus a structured failure, including missing instance, ambiguity or resolution cycle |

The ordered qualifier list owns both predicate order and dictionary parameter
order. Arity is derived from it. Instantiation constructs one type/effect
substitution and applies it to the body and every predicate, then mints fresh
wanteds and evidence destinations in that order. Once a binding migrates, its old
predicate sidecars become adapters for unmigrated readers, not another authority.
Generalization assigns each permitted residual predicate a fresh formal evidence
binder and closes that residual's occurrence destination with a reference to the
binder. The ordered predicate/binder pair is indivisible: instantiation substitutes
the predicate and maps the corresponding formal binder to that new wanted's
destination. Tests must distinguish two different predicates of the same arity;
preserving the length while swapping their binders must fail.

Proposed files and dependency direction:

* `compiler/types/solver_contract.mdk`: request identities, wanted/outcome contracts
  and qualified schemes; imports the existing representation and evidence data.
* `compiler/types/evidence.mdk`: evidence identities and distinct request and frozen
  evidence contracts, available to eval and lowering without importing the
  typechecker. Common scope/binder/instance identity types live here to avoid a
  cycle with the request contracts. Consumers receive only the frozen contract.
* `compiler/types/frozen_repr.mdk`: immutable type/effect templates, imported by
  evidence and cache data. It has no dependency on solver state or the typechecker.

The first implementation must measure the actual import graph. These placements
are responsibilities, not permission to duplicate existing representation types
or to introduce files without a consumer. Existing EvId placement in
`frontend/ast.mdk` remains unchanged.

`SolverEvidence` is request-owned and may carry live type arguments. Its instance
prerequisites and superclass source are evidence-node identities in a request DAG,
not recursively copied proof trees. `FrozenEvidence` uses immutable type templates
and summary-local node identities. A single zonk/freeze traversal validates scope,
completeness and cycles, then translates the DAG while preserving sharing. Request
evidence cannot inhabit a published or cached field. Thawing remints identities.

Both phases distinguish a given binder, one selected instance with its type
arguments and prerequisite evidence, and a superclass projection from existing
evidence. The first vertical need not implement all constructors.
The approved default-body RNone exception remains an explicitly classified legacy
disposition, with its owner and fixture; it must not be relabelled as valid semantic
evidence merely to make the outcome exhaustive. Standalone shadows are likewise
term-denotation choices, not class evidence.

## Solver services

The solver receives immutable class/instance/admissibility facts and explicit
scope/given views. Its narrow services distinguish these results:

| Service | Results |
|---|---|
| Scoped given lookup | Miss, matching evidence binder, or blocked with reasons |
| Instance selection | No match, one selected instance fact, ambiguous identities, or blocked with reasons |
| Selected instance fact | Identity, matched type arguments, and prerequisites substituted using that same head match |

No service emits diagnostics, writes a Route, or collapses missing, ambiguous and
blocked into one optional result. Recursive prerequisite solving belongs to this
same judgment. It has explicit cycle detection and a progress/blocking worklist;
it must not replace the retired whole-program promotion retry with another retry
loop. Instance prerequisites are captured at construction, not re-selected later.

Given lookup precedes instance commitment. Superclass lookup has a contract here
but implementation stays with #993. A missing implementation cannot manufacture a
successful superclass proof.

## Return occurrence and deletion set

Before posing a class wanted, inference classifies the occurrence's denotation.
It retains the full method type, resolved interface/method identity, origin, scope
and destination. The classifier returns a complete predicate, a standalone-shadow
disposition, `LegacyDefaultBodyRNone(owner, origin)`, a deferred denotation or a
located denotation error. The legacy disposition is selected before minting a
wanted, has one compatibility-cell writer, and remains owned by #993 until its
semantic replacement lands. The switch must enumerate its concrete existing
fixtures before deleting any old producer; an unclassified absence is an error.
This preserves
the shadow/admission rules without smuggling them into entailment.

The existing exception's primary pins are
`test/engine_fixtures/prelude_default_parametric_requires.mdk` and its
`test/eval_dict_fixtures/` mirror: inherited `Ord` defaults retain `RNone` for their
inner `compare`. Non-constant sibling-method coverage lives in
`test/llvm_fixtures_modules/typearg_inherited_default_dispatch/`.
`method_constraint_foldmap_{list,string}.mdk` in the engine and eval-dict corpora,
and `test/eval_typed_modules_fixtures/cross_module_default_constrained/main.mdk`,
also pin constrained/cross-interface default behavior. These fixtures are a
starting ledger, not proof that every reachable legacy site is classified.

The full-vector invariant is mandatory: the current PSArgsUnknown/result-only
fallback is not a valid solver input. Census genuine single-admitted return sites
before switching them. Missing vectors require fixing their producer first.

At each eligible group boundary and at finalization, the one outcome determines
both acceptance and evidence. Deferred wanteds keep their original scope. Numeric
defaulting must precede the corresponding final ambiguity decision. A route
adapter can look up an already-selected instance by identity and project its
prerequisite evidence; it cannot run matching or specificity again.

The atomic return-family switch owes these deletions:

1. Replace the return-site producer and retire its old pending-site payload where
   it has no other consumers.
2. Remove the return step from both stamper orders and remove `resolveSites` and
   `resolveSite` after all callers migrate.
3. Remove EKReturn and its branches in the entailment helpers. Keep the other
   entailment families until their own migrations.
4. Stop duplicating genuine return-position method obligations into implObls on
   both marked and unmarked inference paths. Retain argument-position and
   method-level obligations. Before removal, move every non-checking reader to
   the authoritative wanted or an explicitly derived adapter: numeric defaulting,
   ambiguity registration, scheme obligation retention/generalization, signature
   coverage, and method-site/inferred-interface recovery. Record each reader,
   replacement and discriminating fixture in the implementation packet. Deleting
   its checker does not license dropping those constraints.
5. Move return-position multi-admitted-method classification out of the independent
   admitted-occurrence checker. It may continue serving unmigrated argument sites.
6. Remove cell readback as the authority for migrated return evidence. Any surviving
   compatibility method cells have exactly one writer, derived from semantic
   evidence. Retain separate standalone-shadow handling only as an explicit
   disposition with one owner.

The Flat/unmarked inference path is part of the producer census. Leaving it on
the old checker must be named as an incomplete migration, not described as all
verbs sharing the vertical. Unrelated operator, argument and dictionary-application
stampers are outside the deletion set.

## Caching contract

Current core and module-chain memos replay mutable schemes and state. Prefix
draining is not whole-graph finalization. Migrated return results cannot be reused
under those prefix keys or copied into their shared mutable cell graphs.

A frozen summary contains immutable qualified schemes, diagnostics, closed
evidence and/or residual templates. Type variables, scopes, binders and evidence
destinations in templates are positional. Thawing remints fresh request-owned
identities and inference cells. No live Mono, Scheme, Decl, Ref, GraphRun or run-local
EvId ordinal is a frozen payload.

The initial cache key may conservatively fingerprint the whole graph: compiler/
schema generation, canonical module/source and dependency identities, relevant
options, class/instance environment, and admissibility/visibility/shadow facts.
An unchanged source prefix is insufficient when a later module adds an instance.

Current InstRef ordinals are request identities, not cross-request cache keys.
Until a stable frozen instance identity is specified and tested, instance-bearing
summaries are non-cacheable. Do not hash a current ordinal and call it stable.

While the return vertical is enabled, unconditionally force misses in all three
existing typechecking memo layers: core, module-chain and prelude-preamble, and
disable their stores. Core and chain hits cannot tell us whether skipped inference
would produce the migrated family; no post-hit classification can authorize replay.
They restore already-drained snapshots, so there are no retained wanteds from which
merely recomputing the output could recover the judgment. Do not replay a mutable
snapshot and then attempt to repair its evidence.

Prelude-preamble has a different ownership defect: it does not restore a run bundle
or itself skip inference, but `ppEnvAcc.daImpls.iaEnv` contains `ImplRow` values with
request-local `InstRef`s. An otherwise immutable declaration payload is not a frozen
instance summary. A later package-7 split may retain proven pure preamble fields
while rebuilding/reminting its impl accumulator, under a separately verified contract.
The [cache audit](https://github.com/MedakaLang/medaka/issues/2549#issuecomment-5639671213)
records this distinction; it does not authorize an unchanged-preamble exemption. The
September 10 owner ruling requires replacement of all three layers as families
migrate; there is no prelude exemption. Measure the bypass's cold/warm instruction
and allocation cost before enabling the vertical, and report any breach of the
existing approximately 25% soft instruction-count budget. Package 7 owns its deletion.
Caching resumes only through immutable summaries/templates
whose freeze/thaw and graph-sensitive keys satisfy this section.

## Implementation slices and checks

### Next packet: contract foundation

This packet changes no production producer, instance selection, generalization
policy, cache hit or route. It supplies request-local contracts and instantiation
through an explicit service boundary, exercised by
`compiler/types/solver_contract_test.mdk`, explicitly named in the Makefile's
`test:` target. The return census is a prerequisite of the later switch, not of
these data invariants.

The concrete proposed API is the following contract notation:

```text
ClassPredicate = { interface: IfaceRef, arguments: List Mono }
Qualifier = { predicate: ClassPredicate, formal: EvidenceBinderId }
QualifiedScheme = { hm: Scheme, qualifiers: List Qualifier }
GoalOrigin = { location: Option Loc, moduleId: String, binding: Option Ident }
Wanted = { id: GoalId, predicate: ClassPredicate, origin: GoalOrigin,
           scope: ScopeId, destination: EvId }
Instantiation = { body: Mono,
                  arguments: List { formal: EvidenceBinderId, wanted: Wanted } }
InstantiationServices subst = {
    makeSubstitution: List Int -> List Int -> subst,
    substituteBody: subst -> Mono -> Mono,
    substituteArgument: subst -> Mono -> Mono,
    freshGoal: GoalOrigin -> ScopeId -> GoalId,
    freshDestination: GoalOrigin -> ScopeId -> EvId
}
instantiateQualified(InstantiationServices subst, ScopeId, GoalOrigin, QualifiedScheme)
    -> Instantiation
```

`Loc`, `Ident` and `EvId` come from `frontend/ast.mdk`. `moduleId` is the
loader's canonical module identity, supplied explicitly to both identity mints.
An enclosing binding is absent only for an origin without a resolved binding;
synthetic and recovery occurrences may also lack a location. The existing private `EvDest` route-cell sum
remains behind the later compatibility adapter and is not a solver API type.
The service's `subst` parameter is opaque to this module; it permits the existing
HM substitution representation without importing private typechecker operations
or introducing another substitution-map implementation.

`InstantiationServices` supplies request-owned allocation and the existing HM
substitution operations. The implementation allocates one map for quantified type
variables and one map for quantified effect variables; both maps apply to the
scheme body and every qualifier predicate. The body operation preserves the
existing variance-sensitive row reopening in `substMonoP`; qualifier substitution
does not independently reopen rows or allocate another substitution. Goal and
destination allocation runs once per qualifier, in stored order. The result keeps
each formal binder beside its wanted, so an application has no second zip or
spelling lookup with which to reconstruct the correspondence. Failure to represent
a full predicate vector is a construction error, never a scalar fallback.

`solver_contract.mdk` owns this API and the three outcome cases. The consumed
identity/evidence contracts live in `evidence.mdk`; prerequisite edges are node
identities, not embedded proof trees. The frozen representation module is created
only with its first freeze/thaw consumer, not as unused scaffolding in this packet.
Likewise, no frozen instance identity is invented for the foundation.

The deletion set for this packet is empty: existing scheme/obligation storage is
unchanged until an occurrence family adopts the API. The following packet must
give the new API a production consumer before adding more parallel contracts.
This is explicitly a foundation slice, not completion of package 2 or a claim
that the existing scheme sidecars have ceased to be authoritative.

Acceptance covers shared body/predicate type and effect substitutions, two calls
with disjoint fresh identities/cells, n-ary and nullary predicate vectors, stored
qualifier order/arity, and distinct predicates with swapped formal binders. An
allocation-service test double makes aliasing observable; mutation controls must
break each assertion by using two substitutions, reusing a destination, truncating
a vector or swapping binder associations. Production acceptance remains unchanged.

### Subsequent packets

| Slice | Result and acceptance |
|---|---|
| Contract foundation | Minimal consumed identity/outcome/qualified-scheme contracts; tests prove one substitution, fresh identities, qualifier order and arity; no behavior switch |
| Scope/given adapter | Lexical scope/parent identities and evidence binders; tests distinguish siblings, nesting and given precedence |
| Production evidence observer | Observe evidence before lowering on real Module paths; hand-derived expectations and fail-capable mutations |
| Return vertical | Switch producers, solving and evidence together; remove the old return-family checker/stamper paths listed above |
| Frozen summaries | Implement freeze/thaw and full-graph invalidation before enabling evidence caching; retire mutable replay for migrated results |

Use compiler sibling tests for data invariants and existing dictionary/module/
engine gates for production behavior. The evidence observer must distinguish a
well-typed wrong instance, a swapped prerequisite, a truncated n-ary predicate,
an out-of-scope given and an unexplained missing-evidence fallback. A validator
alone cannot prove most-specific selection, so retain independent specificity
and declaration/import permutation assertions.

Retain source soundness, self-hosting fixpoint, run/check agreement and all three
engines where consumer behavior changes. For caches, compare cold P with same-
process P → conflicting or failed Q → P, including hits, then add a graph-visible
instance and demonstrate invalidation. Compare schemes, diagnostics, residuals and
evidence, not just values.

Measure the existing cold/warm LSP instruction-count instrument and soft budget,
plus allocation and retained memory at matched request/session lifecycle points.
No new numerical performance ceiling is introduced here.

## Decisions required before the vertical switch

* Complete the full-vector producer census, including Flat/unmarked occurrences.
* Classify multi-admitted return occurrences under the current shadow semantics.
  The measured import/shadow cases below require no new language rule; a new
  uncovered case must be reproduced before proposing an owner decision.
* Enumerate the default-body legacy exception by reachable site, owner and fixture.
* Complete the non-checking implObls consumer ledger before removing return entries.
* Specify stable instance identity before freezing instance-bearing evidence.
* Reconcile finalization with prefix memo admission; never default or commit an
  externally constrainable wanted merely to save a prefix snapshot.
* Re-derive the numeric-defaulting census. The two historical examples named in
  #2646 produced no elaboration residual on the pinned base. The closed test/prop
  body fix on this branch is a prerequisite, not completion of graph defaulting.

## Producer census and constraint-consumer ledger

Read-only census at `f57016b44`, after the initial design review:

Method-row preparation (`ee61c0a35`) subsequently replaced the separate numeric
scheme/parameter refs with `numLitFromIntAnchorRef : Ref (Option LegacyNumLiteralAnchor)`.
In the numeric row below, `numLitFromIntParamsRef` names the historical
field; its current reader consumes the anchor's `lnlaParams`. This ownership
consolidation preserves the legacy parameter walk and does not resolve the
checker/return-producer identity split identified by the census.

| Current population | Predicate information and required migration |
|---|---|
| Genuine marked method, one admitted interface | The declaration and occurrence instantiation can supply the complete vector; assert their common identity at construction. |
| Multi-parameter result dispatch | `fromEntries` needs both container and element, not just the result carrier. |
| Numeric literal | The checker uses `numLitFromIntParamsRef`, but the return route reads a spelling-keyed `fromInt` row. A collision can produce a known vector for the wrong interface. Construct the wanted directly from the identity-selected builtin declaration and its occurrence substitution. |
| Name-marked standalone or local shadow | May currently have a known method vector or a mismatched/unknown vector. Classify term denotation before constructing a wanted; a known vector does not prove method denotation. |
| At least two admitted interfaces | Admission alone does not identify the term declaration. Preserve resolver rejection of two actual method imports, the unique actual method when the other import binds only an interface, and SHADOW S4/I9 standalone precedence. Obtain the vector from that resolved declaration, not the arbitrary floor row; pin import-order permutations. |
| Missing row or shape mismatch | Existing code can fall back to the scalar result. Exclude the population until its producer supplies the vector. After that precondition, a mismatch is a located internal invariant failure, not a licensed new language rejection; never construct an incomplete class wanted. |
| Ordinary Flat/unmarked check | `inferVarPlainId` emits the obligation but no return goal or AST evidence destination. Its eventual wanted needs an explicitly owned destination or the shared marking schedule. |

The two current `recordSite` callers are `inferMethodAt` and
`inferNumLitMethod`. `recordSite` also independently adds a scalar entry to
`methodSiteFns`. Module inference marks SCCs and tail bodies on its schedule;
Flat `elaborateDict` pre-marks, while ordinary Flat checking remains unmarked.
Eligibility cannot be reduced to `PSArgsKnown`: it requires method denotation,
one resolved admitted declaration, and the complete vector from that same
declaration and occurrence substitution.

Strong existing pins include `engine_fixtures/single_impl_return_pos.mdk`,
`same_head_impls.mdk`, `inferred_empty.mdk`, `instance_requires_list.mdk`,
`nested_instance_dicts.mdk`, and the set/map literal build fixtures. Dictionary
semantics rows X9/X10 pin numeric identity; D24/D25 and I9/I21 pin shadows.
These are existing fixture names under `test/`, not a new gate registration.

Follow-up reproduction on separately built base `2b6e08c8d` and slice
`f57016b44` resolved the suspected policy gap in the multi-admitted row. Two
interfaces define `make : Int -> a`, with distinguishable implementations for
the same result type. Importing both actual methods rejects with an ambiguous
occurrence in both orders. Importing one actual method and only the other
interface name selects the former and prints `1` in both orders. With the
standalone `make` shadow, both orders print `901`, as SHADOW S4/I9 requires.
Accepted cases agree across checking, interpretation and native execution.
This corrects the earlier census claim that this population necessarily needed
a semantic decision. Producer identity remains an implementation obligation;
these controls do not establish that every return occurrence has been classified.

Removing return `PMethodOcc` entries from `implObls` owes each replacement below.
Every adapter is a projection of the authoritative wanted/qualified scheme; none
may perform a second instance selection.

| Consumer | Replacement before deletion | Discriminating existing pins |
|---|---|---|
| `groundMultiParamObligations` and final obligation checks | Selected instance substitution, verdict and evidence come from one outcome. | set/map literals; nested function-key rejection; same-head specificity; nested requires |
| Local/SCC/impl/default/test/prop numeric defaulting windows | Scope-owned wanted predicates remain visible; defaulting unifies the direct Num variable but does not discard the wanted. | new s6-d1 test/prop fixtures; impl-body numeric overlap and polymorphism fixtures |
| `registerAmbiguousConstraints` | Preserve receiver projection, owner level, member ids, anchors and location until binding-boundary solving replaces the adapter. | `ambiguous_return_{noconstraint,nested}.mdk`; `ambiguous_captured_in_let.mdk` |
| `registerSchemeObligations` | Qualified schemes own ordered full predicates and formal binders; old call-site rows are derived, with the signed/unsigned distinction retained. | s4-gen signature/residual fixtures; `inferred_empty.mdk` |
| `checkSigConstraintCoverage` | Compare declared context against body-required full predicates, including uses discharged by a declared given. | s4-gen signature rejection; s9 vector rejection; joint cross-pairing fixtures |
| Impl/default method rigidity | Preserve interface-vs-method variable ownership and survivor entailment. Deferral is not proof. | s3-w3 rigidity fixtures; `impl_constraint_via_{helper,local_alias}.mdk` |
| `maybeInferConstraint`, `inferredConstraintIds`, `ifaceForInferredId` and `methodSiteFns` | Derive temporary scalar and full-vector views from the same wanted; replace the recovery joins when qualified-scheme consumers migrate. | `inferred_empty.mdk`; `inferred_chain.mdk`; s-cardinality-inferred; s4-gen residual fixtures |
| Impl/default body snapshots and rollback | Scope-local commit/discard or equivalent transactional windows; preserve decidable-obligation filtering and cascade suppression. | `accept_792_parametric_impl_abstract_and_ground.mdk`; ground impl-body rejection; `iface_default_dedup_cascade.mdk` |
| Bundled method-level obligations | Split the producer so removing the receiver occurrence retains its independent method-level predicates. | method-constraint foldMap fixtures |

`methodOccArgPairs` needs no return adapter: its `firstDispatchIdx = None` arm
contributes no argument pairs. Argument-position entries remain unchanged.

An intermediate single-admitted cut would leave excluded return populations using
the legacy stamper. It therefore cannot delete `SSReturnSites`, `resolveSites`,
`resolveSite`, `EKReturn`, `SKReturn` or `GKReturnSite` globally, and cannot claim
completion of the selected goal family. This record retains the full-family
completion requirement. Before that switch, resolve the populations above and
the numeric literal's existing standalone/local suppression policy. The current
foundation packet is independent of those decisions.
