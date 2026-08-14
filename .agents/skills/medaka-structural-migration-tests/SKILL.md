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

Every named route must be non-vacuous for the selected field. A census that
records real gaps but never reads or writes the migrated buffer/counter is still
vacuous for that migration. When an API returns only events rather than the
selected state, pair a field-sensitive input with a structural freshness check
and a route-specific renamed-authority mutant.

Separate two claims for event-only routes:

- **data correctness:** the migrated values/order are correct where an observable
  renderer or capture consumes them;
- **ownership correctness:** every route receives fresh exclusive authority.

A route-specific renamed-authority mutant can prove ownership even when that
route exposes no selected data, but it does not prove the hidden contents. A
computed read whose result is discarded proves neither contents nor externally
observable behavior; call it structurally exercised, not behaviorally observed.
For each event-only mutant, name the single claim it proves.

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
- direct zero status, expected stdout, and empty stderr for successful subprocess
  controls (capturing stdout alone does not preserve status);
- nonzero fixture enrollment and exact fixture/result accounting.

A worker pipeline must fail closed. If a Bash script recursively invokes itself,
preserve the interpreter with `bash "$0"`, not `sh "$0"`.

## 4. Ratchet structure as a set

Reject every retired state and installer symbol, not a count. Positively require
the new carrier, builders, actual field readers/writers, and every route's fresh
construction. Ensure all shipping, probe, snapshot, profile, census, and
playground callers reach the same public seam. If exclusive ownership rests on
an allowlisted declaration set, derive both top-level signatures and direct
definitions; cover every legal identifier start (including `_`) and visibility
prefix; normalize as a sorted unique set rather than source order. Structural
checks complement behavior; they do not replace it.

## 5. Mutation-test every semantic field

After a clean implementation revision, define reversible private mutations per
field. Ambient-state migrations require three distinct classes when applicable:

- reader/runtime: corrupt selected reader or runtime demand;
- fresh-context U-absence: seed only that fresh carrier field with U;
- renamed ambient authority: roundtrip selected carrier field through a legal
  renamed top-level authority on relevant route.

Generic carrier mutations do not substitute for these claims. After final
implementation/harness freeze, create one row per applicable field/class pair.
Record row ID, semantic field, class, route, claim, exact head, target file,
unique anchor, exact before/after text and mutation command, prepare/check/
restore-check commands, baseline hash, caller-owned receipt path, and earliest
stable expected-red identifier. Then:

1. apply one mutation;
2. rebuild only the focused probe;
3. require the named harness/family assertion to go red;
4. restore immediately;
5. prove source matches the baseline before the next row.

Use `compiler-mutation-verifier` for a fixed, caller-designed matrix. A timeout,
phantom skip, unrelated compile failure, or empty output is not observed-red
credit unless it is the explicitly relevant consequence. Finish by rebuilding
restored source and rerunning clean green.

Before naming expected-red evidence, inspect assertion order and identify the
**earliest applicable assertion**. Prefer a stable rule identifier such as
`H2B3-IMPL-SELF-AUTHORITY` in the failure text. When several assertions directly
prove the same forbidden property, the caller may provide an explicit regex/set
of acceptable identifiers; do not use a broad substring that could accept an
unrelated failure. An earlier directly-equivalent authority rejection is valid
credit, but an unrelated early exit is not.

For a one-source mutation, prefer `scripts/mutation_transaction.sh` so EXIT and
HUP/INT/TERM restoration, baseline hash proof, direct check status, expected-red
matching, and final clean-state proof are one transaction. Backend mutations must
use `--prepare` to force the emitter/native rebuild and rebuild the focused probe;
use `--restore-check` to rebuild restored artifacts. A source mutation tested by
a stale probe is invalid even when it reports green or red. The helper restores
bytes without Git index writes, so isolated-worktree `.git/worktrees/*/index.lock`
restrictions are not grounds for a custom transaction. Use custom shell only
for a shape the helper cannot express, and retain the same guarantees.

Unexpected green means wrong target or stale build until re-derived; report
`BLOCKED_WRONG_TARGET`. Do not relabel it non-discriminating, substitute another
row, or weaken expected evidence without reviewer confirmation. Successful row
receipt requires: expected ID observed; transaction exited; source blob equals
HEAD; porcelain empty; no mutation/build process; retained log path.
Independently inspect final filesystem state instead of trusting reported hash.
Long prepares run in yielded sessions and are polled to completion.

For mode/reset migrations, include renamed-authority mutants rather than only
mutating retired names. One mutant restores the old reset choreography so output
remains conformant while exclusive ownership is wrong; the normalized authority
set must reject it. A second route-specific mutant moves only a non-rendering
census/mode route onto a renamed ambient authority. Also retain a no-reset mutant
when cross-call contamination is behaviorally observable. Use a legal adversarial
name such as an underscore-prefixed identifier. Name in advance whether structural
or behavioral assertion must go red.

Mutation receipts are revision-scoped to the executable harness. Any later change
to fixture source, assertions, ordering, subprocess handling, or structural
ratchets invalidates affected rows. Prefer independent review of a new harness
before paying for one final exact-head matrix; do not accumulate superseded runs.

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
