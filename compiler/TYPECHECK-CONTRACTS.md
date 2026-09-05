# Typechecker destination contracts

**Status:** target architecture, implementation incomplete. Adopted through epic
[#1122](https://github.com/MedakaLang/medaka/issues/1122), 2026-09-05.
This is the current destination and completion contract. The
[migration design and landing ledger](TYPECHECK-TARGET-ARCHITECTURE.md) retain the
history, measured prerequisites, and per-unit implementation details. The language
specifications remain authoritative: [dictionaries](../docs/spec/DICT-SEMANTICS.md),
[effects](../docs/spec/EFFECTS-SEMANTICS.md),
[shadowing](../docs/spec/SHADOW-SEMANTICS.md), and
[the HM core](../docs/spec/HM-CORE-SEMANTICS.md).

The names below are proposed interfaces, not declarations claimed to exist.
These contracts refine L1–L5; they do not change accepted programs by themselves.

## 1. Scope and preserved decisions

Borrow GHC's separation of scoped constraint generation, solving, evidence, and
reporting. Keep Medaka's eager union-find unification, levels, SCC scheduling,
strict evaluation and value restriction. Effects keep their own equality,
subsumption, polarity and escape rules; they do not select dictionary instances.
No GADTs, type families, deferred runtime type errors, or GHC generalization policy
are introduced by this plan. Complete the owed HM rules under #2555 before a
change depends on them; the current draft is not a complete specification.

The active M2 representation sprint #2667 keeps its existing scope and placement.
An evidence-id table containing routes is a compatibility bridge. Its completion
does not imply unconditional solving, a single checking path, or semantic evidence.
The approved default-body `RNone` exception stays pinned until its owning evidence
work supplies a replacement. B-1/G1 is not a prerequisite of that sprint.

Warn-first T4 and emitter diagnostics remain migration policies under the existing
owner rulings. A final successful artifact must not conceal a fatal constraint
failure. Defaulting (#2646), the per-goal T4 census correction (#2665), and the
owner's measured SC-3 decision precede any hardening of T4; this amendment does not
turn warnings into errors. The emitter-process/resolve choice remains deferred
until after M2. Release scheduling and the one compiler-source PR rule remain.

## 2. Environments and inference

The immutable global environment owns resolved identities, declaration facts,
interfaces, instances and dispatch admissibility. Module environments express
visibility without rebuilding identities from spellings. Lexical scopes own a
scope identity, parent scope, inference level, givens and evidence binders.
Generated dictionary names are renderings of binder identities, not scope keys.

Inference retains eager equality solving. It produces typed syntax and scoped
wanteds; this may use a scoped accumulator rather than allocate a pair at every
recursive call. A class wanted carries a goal identity, full predicate argument
vector, source origin, lexical scope and evidence destination. All syntax bodies
participate: top-level and local bindings, impl/default methods, tests and props.
Binding/shadow selection belongs to resolution and inference; it is not an extra
premise smuggled into dictionary entailment.

A qualified scheme packages quantified type/effect variables, predicates and the
body type, with an explicit ordered correspondence between predicates and evidence
parameters (including dictionary arity). Instantiation uses one substitution
across all three and emits fresh wanteds with fresh evidence destinations in that
order. This wrapper can sit above the existing
unqualified HM scheme; it does not require rewriting the HM kernel. Generalized
predicates become evidence parameters under the same binding-group policy.
Local dictionary abstraction remains the separately gated acceptance work #1082;
introducing this representation must not silently widen local generalization or
move a strict binding's evaluation from definition time to use time.

## 3. One solving judgment, scoped scheduling

The solver returns one of three outcomes for a wanted:

```text
Solved(evidence)
Deferred(residual, blocking variables or scope)
Insoluble(failure with goal identity and origin)
```

Satisfiability checking and evidence selection consume this same outcome. There
must not be a second checker deciding success independently of the evidence
builder. Ordinary equality/effect constraints may use domain-specific results;
they are not forced to fabricate runtime dictionaries.

Simplification runs at binding/generalization boundaries. It discharges available
givens and superclass projections, solves eligible instances, and retains residuals
with their original scope. At generalization, permitted residual predicates become
parameters. Non-generalized variables can remain live and externally constrainable:
those goals survive to whole-graph finalization as required by DICT T4/T6.
An instance commitment must satisfy the spec's closure and specificity conditions.
One solver does not mean one invocation at graph end. Per-group and quiescence
defaulting retain their separate specified ownership and ordering.

Residual storage may be a scope tree or a flat bag with explicit scope links. A
worklist must track progress/blocking dependencies and report unsupported or
insoluble residuals; moving the old whole-program promotion retry into the solver
does not discharge the fixpoint deletion. Termination/cycle handling and evidence
sharing must cover nested `requires` without unbounded tree duplication.

## 4. Evidence and the published program

Semantic evidence distinguishes at least:

```text
Given(evidenceBinder)
Instance(instanceIdentity, typeArguments, prerequisiteEvidence)
Superclass(existingEvidence, projectionPath)
```

Evidence bindings have identities, predicates and scopes. Instance prerequisites
are captured at construction; superclass evidence is projected from an existing
dictionary, never selected again. Default methods and generalized local bindings
use the same abstraction/application discipline when their respective milestones
land. Any temporary builtin/runtime-refinement case has an explicit disposition,
spec justification, owner and discriminating fixture; absence of evidence cannot
silently mean fallback selection. Routes may survive as lower-level data derived
from evidence. Removing a datatype named `Route` is not the success criterion;
removing independent semantic selection by consumers is.

The public typechecking result separates useful incomplete analysis from success:

```text
TcReport { partialAnalysis, diagnostics, checkedProgram: Option CheckedProgram }
CheckedProgram { typedProgram, schemes, evidence, downstreamFacts }
```

Finalization resolves inference links (zonking), validates evidence and freezes
the result. No later inference request may mutate the meaning of a published
program. Legitimate quantified variables remain; freezing is not grounding every
type. Unsolved fatal obligations preclude `CheckedProgram`, while LSP diagnostics,
hover and partial types remain available. Immediate syntax/declaration errors and
recovery still accumulate; they need not be recast as dictionary residuals.

Check, run, build, LSP and probes share this semantic pipeline. Eval and lowering
consume successful artifacts; only their output projections differ. The separate
emitter executable must eventually either receive the artifact or invoke the same
pipeline with the same validation policy. Removing a CLI precheck is licensed
only after its checks, including exhaustiveness and impl obligations, are covered
by that pipeline. Publication also includes the complete instance-method
disposition table: exactly one supplied/default disposition for every accepted
method slot, produced by #1112/A-3 with #993. Emitter #1403/X-E consumes that table;
it does not fill missing slots or choose defaults. F6 certification requires both
semantic evidence and the complete table. This preserves the producer/consumer
split of emitter epic #1398, not a second backend redesign.

## 5. State boundaries and cache validity

Separate immutable environments, per-request inference storage, lexical contexts,
solver work/evidence and diagnostics by ownership. Mutable implementation is
permitted behind those interfaces. Whole `PerRun`/`Toggles` replay is migration
scaffolding with a deletion owner, not the permanent solver input contract.

For #2586, a failed closed-island extraction triggers a boundary design: enumerate
outside calls/state reads, design narrow services or explicit context parameters,
then migrate one boundary and measure it. Stateful modules with acyclic imports
are valid. Do not require every extraction to be a pure leaf like `repr.mdk`.
This refines ruling 8's mechanism, not its sequencing: no immediate compiler split
or mass threading of records through `infer` is scheduled here. Shared contracts
and state access move only in the accepted implementing slice. Put typechecking
services in `compiler/types/`; give interpreter/lowering consumers a dependency-safe
shared data module. The active #2667 AST placement is unchanged.

Cache immutable finalized summaries, or constraint templates instantiated into
fresh request-owned variables and evidence destinations. No cached entry may share
mutable inference cells with a later request. Keys cover source/dependency
identities, relevant options and any instance/admissibility environment on which
the cached answer depends. A prefix unchanged in source is insufficient for
evidence affected by whole-graph instances. Conservative graph-generation
invalidation is a valid first implementation; fine-grained invalidation is optional.

## 6. Delivery owners and dependency edges

These are completion packages within existing issues, not claims those issues
have landed. #1122 owns cross-package tracking. Before an implementation slice,
its owning issue must record the concrete API, deletion set, placement and tests.

| Package | Owner | Dependencies and completion evidence |
|---|---|---|
| Compatibility evidence table | #2549 phase 1 / #2667 | Existing contract unchanged; publish its limited completion honestly. |
| Solver/scoping contract and one vertical migration | #2549 phase 2, coordinated with #2547 and #1318 | After phase 1; design wanted/scope/qualified-scheme/outcome APIs, migrate one goal family through checking and evidence, remove both old paths for it. No all-at-once inference rewrite. |
| Single pipeline and finalized report | #2549 phase 2 + #2544; #1116/#1117 deletions | After the migrated solver covers the precheck's responsibilities; retain partial LSP analysis, remove semantic mode gates, duplicate checking and promotion discovery with acceptance accounting. |
| Semantic superclass/default evidence | #993 (B-1/G1), coordinated with #2549 and emitter #1398 | Contract design can proceed alongside phase 2; implementation follows shared evidence API. Required before certifying L4 for supers/default bodies; not a retroactive phase-1 prerequisite. |
| Complete instance-method dispositions | #1112/A-3 with #993; #1403/X-E consumes | Publish exactly one supplied/default disposition per accepted method slot. F6 requires this table as well as semantic evidence; consumers never synthesize missing dispositions. #2667 remains unchanged. |
| Complete namespace identity | #2563 with #1111 | Existing #2547 unit-3 substrate prerequisite stands. Its scoped exclusions remain assigned to their existing owners; do not report pipeline-wide identity complete while excluded consumers still re-derive it. |
| Finalized-result caching | #2549 phase 2; #2007 for declaration-cache overlap | Design alongside the report API, land before enabling cached evidence. Own removal of mutable state snapshot/reinstall for migrated results and graph-sensitive invalidation. |
| Designed module boundaries | #2586 | Follow the contracts/state moves enabling each cut; acyclic APIs and behavioral/performance checks, not purity or file-size counts. |
| Finalization policy | #2646 + #2665 census, then SC-3 under #2548 | Correct defaulting and goal counts before the owner decides warning-to-error behavior; no implicit default-to-instance fallback. |
| Contract verification | #616 with each implementing owner | Tests precede the corresponding semantic/consumer change; the checks below are required evidence for completion. |

#2667 already requires a phase-two issue at closeout. That issue must carry these
phase-two packages and any further bounded child issues, rather than leave them
as deletion promises. The table gives ownership now without inventing a parallel
epic or assigning all open soundness bugs to the representation sprint.

## 7. Verification and completion

Retain spec-derived verdicts, schemes and executable values, import/impl-order
permutations, source soundness, self-hosting fixpoint, and all three engines where
the consumer contract changes. A shared wrong solver can make all engines agree;
agreement and byte-identical compatibility goldens are not semantic oracles.

Add a production Module-path observation of semantic evidence before lowering:
given forwarding, instance identity and prerequisites, superclass projection,
lexical binder scope, default-body disposition and dictionary arity. Verify these
against hand-derived cases. An evidence validator checks binding scope, predicate
compatibility and completeness, but cannot alone prove most-specific selection;
retain independent specificity and permutation cases. Mutation checks must show
the new assertions fail for wrong evidence, including well-typed wrong selection.

Run same-process P → unrelated/conflicting Q → P, including a failed Q and cache
hits, and compare P's schemes, diagnostics, residuals and evidence with a cold P.
Separately compare cold/warm results when adding a graph-visible instance: an
answer may legitimately change, but a stale cached answer must not survive.
Exercise alias/re-export collisions across type, interface, method, constructor
and value identities. Local/default evidence changes also pin strict evaluation
timing and value restriction, not just dictionary shape.

Use M2's recorded cold/warm LSP instruction-count instrument and its existing
approximately 25% soft budget (#2549). Report allocation and retained memory for
graph-lived goals/evidence alongside it, without silently imposing a new numeric
ceiling. Compare retention at the same lifecycle points: after request-owned work
is released with the session/cache retained, and after session/cache teardown,
using the same GC measurement policy on both arms. Keep per-stage scaling tests.
No new gate is presumed enrolled: implement
through existing relevant vehicles where possible; new gates follow the measured
cost/enrolment workflow.

The epic's destination is reached only when the shared solving judgment, scoped
semantic evidence, complete identity contracts, finalized publication, cache
isolation and single pipeline are implemented and verified. Intermediate packages
may land with explicit adapters and exceptions; each names what remains and its
owner. Publication of an `EvId` table alone satisfies only the first package.

## References

- [GHC constraint types](https://ghc.gitlab.haskell.org/ghc/doc/libraries/ghc-9.15-inplace/GHC-Tc-Types-Constraint.html): wanted evidence destinations and scoped implications.
- [GHC eager unifier](https://ghc.gitlab.haskell.org/ghc/doc/libraries/ghc-9.15-inplace/src/GHC.Tc.Utils.Unify.html): eager unification and deferred constraints coexist.
- [OutsideIn(X)](https://www.microsoft.com/en-us/research/publication/outsideinx-modular-type-inference-with-local-assumptions/): the architectural reference, not a replacement for Medaka's language semantics.
