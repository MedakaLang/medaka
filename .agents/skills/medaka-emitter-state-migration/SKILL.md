---
name: medaka-emitter-state-migration
description: Designs behavior-neutral LLVM/Wasm emitter-state ownership slices, especially X-N.H/X-W.H ambient Ref migrations into per-emission contexts. Use for emitter epic state-hygiene continuation work.
---

# Medaka Emitter State Migration

Use this skill for pre-plan emitter hygiene that moves existing physical state
from module-level `Ref`s into a fresh per-emission context without changing
language semantics or emitted behavior. Load `medaka-structural-migration-tests`
alongside it.

## 1. Derive the live population

Do not inherit a remaining-Ref count from tracker prose. Enumerate top-level Ref
signatures and direct definitions in the selected emitter, including public and
underscore-prefixed identifiers, normalize the sorted unique set, and group the
members by semantic fact rather than storage cell.

For each candidate family inventory its declaration, initializer,
reset/install/save/restore sites, every writer/reader/drain, every public route,
and duplicate list/set or cache/source representations. Compare candidates by
signature breadth, recursive call-graph breadth, semantic facts, executable
routes, and harness cost. Select the smallest family that can land
compile-coherently with no duplicate authority.

For an established continuation, return this compact derivation rather than a
history recap:

1. normalized ambient-authority set derived from signatures and definitions;
2. candidate families grouped by semantic fact;
3. selected family plus rejected candidates and the deciding cost;
4. exact declarations, readers, writers, drains, reset/scope sites, and routes;
5. route classification: rendering, event-only, or aborting;
6. capture/mutation evidence chosen before implementation;
7. retired authorities, acceptance boundary, and re-derived residual set.

Use `medaka-continuation-receipt` when the conductor needs a compact derived
packet for dispatch, review, PR prose, and tracker handoff.

## 2. Preserve the ownership boundary

- Semantic inputs stay in immutable `EmitInput`/`WasmEmitInput` or validated
  upstream plans; do not move them into mutable physical context.
- Physical accumulators, counters, feature observations, and scoped dynamic
  emission context may belong to one fresh `Emit`/`WasmEmit`.
- Preserve list order, first-match policy, save/set/read/restore extent, and
  renderer output exactly.
- Every public invocation route constructs fresh ownership. A fresh process is
  defense in depth, not the ownership proof.
- Do not claim an H2 family complete while residual ambient state remains;
  re-derive and record the residual set.

## 3. Prove the apparatus before building

Name the exact private reader and the emitted artifact or failure it controls.
Establish whether an existing probe can perform P → alternate U/record/census →
P in one process. If not, plan a capture-only hook before exact assertions.

For hand-built Core/IR probes whose assertion concerns an emitted function or
impl body, keep `main` inert where possible. Assert the generated body directly
so artifact capture does not accidentally evaluate a recursive test program.
Pair the hand-built reader-isolation probe with a separate source-derived
end-to-end fixture that proves real lowering reaches the same mechanism.

Require ordered nonempty captures, P1=P2, a field-sensitive P/U distinction,
parse/validation, execution where meaningful, direct status, and empty stderr.
When census returns only events, pair its non-vacuous event with structural
freshness and a route-specific renamed-authority mutant. A discarded read is not
an observable census result; state that the mutant proves route ownership, while
rendering/capture routes prove data correctness.

## 4. Ratchet and mutate

The structural gate rejects retired names, derives the complete normalized
top-level authority set, and requires the new field, initializer, operational
sites, restoration, and every route's fresh construction. Emit stable rule
identifiers for ownership failures where practical.

Define one behavioral mutant per semantic field and a legal renamed ambient
authority mutant. Inspect gate ordering and name the earliest applicable
expected-red rule. Use `scripts/mutation_transaction.sh` for one-source rows;
run one final matrix only after independent review of a new or changed harness.

## 5. Verification and handoff

Run targeted formatter/linter first. Emitter source changes owe the named source
snapshot, compiler-source typecheck, and native fixpoint; Wasm changes also owe
focused typed/module/product routes selected by the diff. Re-derive selfproc LEG
A applicability. Defer broad independent corpora to merge-group CI after direct
local signal.

Update current architecture/workstream prose and the generated docs index. The
handoff records the family and facts moved, routes/mirrors, behavioral and
structural controls, observed-red mutants, exact-head clean-green receipts,
derived residual population, and next bounded census question.
