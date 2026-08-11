---
name: medaka-structural-migration-tests
description: Designs fail-capable controls for Medaka migrations from ambient Refs, global tables, caches, or duplicate registries to explicit per-program carriers. Use when moving shared compiler state or ownership without changing semantics.
---

# Medaka Structural Migration Tests

Use this skill for behavior-neutral ownership migrations: ambient `Ref`s to
per-run contexts, list/map caches to immutable indexes, duplicate registries to
one carrier, or spelling-keyed global tables to scoped identities. It does not
choose semantics or justify changed output.

## 1. Count semantic facts, not storage cells

Inventory every old declaration, installer/reset, read site, fallback, and
caller. Then collapse duplicate representations of one fact. A list plus a set
of the same names is two cells but one semantic field. Acceptance and mutation
rows are per semantic field; structural ratchets still ban every retired cell.

## 2. Make ownership observable

For each field, name:

- the P value;
- an unrelated U value that differs;
- the P reader exercised by the harness;
- the output or failure that reader controls;
- any fallback route that must be forced by omitting the preferred input.

For a reader that returns, run P → U → P in one process. For census/mode APIs,
include the alternate route between the two P emissions. Both P executions must
exercise the migrated reader; require first and last P byte-identical.

An aborting or panicking sensitive reader uses a replacement shape, not the
returning P → U → P byte-identity rule: run any non-aborting setup/control,
exercise the alternate U/record/census route, print a pre-P marker, then make the
sensitive P the final operation in that same process. Require direct nonzero
status and the expected diagnostic after the marker. A gap-free, cache-free, or
otherwise insensitive P cannot substitute for the sensitive final reader, and a
separate-process negative control proves only fresh-process defaults.

`P != U` alone proves almost nothing: ordinary bodies may differ while a migrated
field remains constant or unread. Add family-specific assertions proving P and U
differ in each field and that the relevant reader affected a parse-valid artifact.

## 3. Make captures non-vacuous

Require:

- exact marker cardinality and order;
- direct command exit status;
- nonempty captures;
- a P/U positive control;
- parsing and validation of generated IR/WAT where applicable;
- execution when the migration can affect runtime behavior;
- nonzero fixture enrollment and exact fixture/result accounting.

A worker pipeline must fail closed. If a Bash script recursively invokes itself,
preserve the interpreter with `bash "$0"`, not `sh "$0"`.

## 4. Ratchet structure as a set

Reject every retired state and installer symbol, not a count. Positively require
the new carrier, builders, and every field accessor. Ensure all shipping, probe,
snapshot, profile, census, and playground callers reach the same public seam.
Structural checks complement behavior; they do not replace it.

## 5. Mutation-test every semantic field

After a clean implementation revision, define one reversible private mutation
per field, normally emptying or corrupting only that accessor. For each row:

1. apply one mutation;
2. rebuild only the focused probe;
3. require the named harness/family assertion to go red;
4. restore immediately;
5. prove source matches the baseline before the next row.

Use `compiler-mutation-verifier` for a fixed, caller-designed matrix. A timeout,
phantom skip, unrelated compile failure, or empty output is not observed-red
credit unless it is the explicitly relevant consequence. Finish by rebuilding
restored source and rerunning clean green.

For mode/reset migrations, include a renamed-authority mutant rather than only
mutating the retired symbol names: reintroduce an ambient cell, make the alternate
route write it, and make the final sensitive P read it. The behavioral assertion,
not an exact-name ratchet, must go red.

## 6. Preserve behavior and performance

- Current output is regression evidence, not semantic authority.
- Preserve first-match/order policy explicitly when replacing assoc lists with maps.
- Build indexes once per program; do not duplicate the old cache beside the new one.
- Keep semantic inputs separate from mutable physical emission state.
- Do not claim the entire migration complete while residual mode, buffer, counter,
  or dynamic-scope state remains ambient.

## Required handoff

Record: semantic-field inventory; retired-cell set; P/U/read matrix; mutation
matrix with observed failures; clean-green receipt; routes checked; residual
ambient state; snapshots/selfproc/fixpoint obligations; and deferred CI breadth.
