# Emitter Sprint 01 — remaining pre-AP hygiene

**Status:** ready for admission and Phase 0; no compiler family is yet approved
for implementation.

**Objective:** increase #1398 throughput by deriving several remaining
pre-fan-in emitter families in parallel, then integrating only reviewed,
behavior-preserving ownership slices serially into one coherent PR.

**Workflow authority:** `.opencode/skills/medaka-emitter-sprint/SKILL.md`.
This document fixes the first run's questions and phase gates. It carries no
live SHA, issue state, residual count, command receipt, or captured output.

## 1. Admission and scope

At run start, load `medaka-epic-intake` and derive the earliest uncompleted and
unblocked #1398 lane from a fresh detached intake at pinned `origin/main`.
Confirm all completed X-N/X-W/X-0 carriers from tracker, merged PR history, and
source before selecting work; issue-open state is not proof of residual work.

### Proposed in-scope lanes

- **X-W.H2 continuation:** derive the current remaining Wasm ambient physical
  authority set and identify implementation-sized ownership families.
- **X-L.H groundwork:** design the current extern-catalog and target collision
  validation domains. It may advance to isolated implementation only after a
  separate complete packet and Phase 0 review; it must not be bundled into a
  Wasm family merely to fill writer capacity.
- Focused apparatus or capture-hook work required to make an admitted family
  fail-capable.

### Hard out of scope

- X-0V and canonical V/ANF/AP production until their authoritative producers
  are present and intake proves readiness;
- all AP-dependent `.C` cutovers, pure-renderer claims, and X-X deletion;
- language-semantics changes, high-severity fixes without their own verified
  scope, scalar-mode policy, and broad extern/linkage redesign;
- duplicating already-landed immutable inputs, indexes, or per-emission fields;
- seed remint or performance claims unless a landed slice independently creates
  that obligation.

The conductor records the final admitted lanes and any delta from this proposal
in the disposable run root. A blocked lane is deferred, not forced into scope.

## 2. Disposable run artifacts

Create:

```text
/var/tmp/medaka-scratch/opencode/emitter-sprint-1398/<base12>-<utc>/
  ADMISSION.md
  phase0/P0-INTAKE.md
  phase0/P0-CENSUS.md
  phase0/P0-APPARATUS-<family>.md
  phase0/P0-DESIGN-A.md
  phase0/P0-DESIGN-B.md
  phase0/P0-SYNTHESIS.md
  phase0/P0-REVIEW.md
  receipts/<phase>-<head12>-<purpose>.md
```

Every file names exact revision, producer, direct artifact locations, epistemic
status, unresolved premises, and invalidation condition. Copy isolated-agent
deliverables into this root before reaping their worktrees. The conversation
ledger remains authoritative; these are disposable projections, not shared
mutable state. Delete the entire root during wrap-up.

## 3. Phase 0 assignments

All assignments are read-only except an explicitly authorized reproducer's
task-owned external scratch probes.

### P0-INTAKE — readiness

Derive tracker/history/source agreement for #1398 and candidate stage issues.
Return completed carriers, blocked milestones, open pre-fan-in lanes, decisive
premises for conductor verification, and the next source-census question.

### P0-CENSUS — remaining Wasm authority

Enumerate top-level `Ref` signatures and direct definitions from current source,
including visibility and underscore-prefixed identifiers. Return the normalized
raw set before its count. Group cells by semantic fact; for each family name
initializer/reset, writers, readers, drains, save/restore scopes, duplicate
representations, recursive call breadth, and strict/record/census/product routes.
Explicitly exclude every landed carrier verified by P0-INTAKE.

Candidate questions must include, without preselecting an answer:

- whether current binding-attribution state has a complete per-emission and
  nested-lift ownership boundary;
- whether lifted definitions, names, function references, dedup sets, and fresh
  IDs form one ordering-sensitive family or several;
- how scan-derived representation facts differ from ordered tuple arities;
- how runtime/import feature flags partition by producer and renderer;
- which numeric facts are whole-program versus dynamically scoped;
- whether TMC context, dispatch context, and dispatch groups can move together.

### P0-APPARATUS — fail-capability

For the smallest census candidates, use `compiler-reproducer` to establish:

- existing executable probe and artifact freshness;
- exact P, unrelated U, private reader, and controlled artifact/diagnostic;
- rendering, event-only, and aborting route classification;
- same-process P → alternate route/U → P feasibility;
- scalar/ref, function/value/main, impl/lifted, strict/record/census coverage as
  applicable;
- whether a capture-only hook is required before exact assertions;
- a separate source-derived end-to-end control with inert `main` where possible;
- data-correctness versus ownership-correctness evidence;
- candidate mutations and earliest stable expected-red rules.

Ordinary byte-identical WAT is vacuous for a diagnostic-only reader. A discarded
read is not observable. Stop rather than approximate an inaccessible private
route.

### P0-DESIGN-A/B — competing slices

`compiler-designer` produces two independent continuation packets:

- A selects the smallest coherent family supported by census and apparatus.
- B analyzes the nearest alternative and attacks A's claimed boundary, caller
  breadth, behavior neutrality, and harness cost.

Each packet must pass the implementer-sized-slice test, name exact authorized
paths and mirrors, preserve physical/semantic ownership separation, specify
acceptance and mutation matrices, and state the exact residual. Neither packet
is globally selected merely by being complete.

### P0-SYNTHESIS and P0-REVIEW

The conductor independently verifies decisive evidence, reconciles A/B, and
selects one slice or defers both. A fresh `compiler-reviewer` then audits the
synthesis for specification conformance, apparatus fail-capability, omitted
routes, sizing, performance hazards, and misleading completion claims.

**Phase 0 gate:** all packets agree on revision and source population; every
review finding is resolved; the selected family has a complete implementation
packet. Otherwise no writer is dispatched.

## 4. Rolling implementation and checkpoints

Use only the existing fixed-path `compiler-implementer`, one assignment at a
time. The conductor integrates each uncommitted daughter diff serially. Readers
may prepare the next provisional family concurrently, but its packet is
re-admitted after every source integration.

For every family:

1. core ownership/caller edit and capture hook, if needed;
2. stateless source feedback and implementation-conforming repair;
3. independently adjudicated exact assertions;
4. targeted format/lint;
5. focused executable harness with direct grading and no phantom skip;
6. compiler-source typecheck and native C3a/C3b fixpoint;
7. relevant Wasm typed/module/product controls;
8. re-derived snapshot and selfproc LEG A obligations;
9. re-derived normalized residual authority set;
10. fresh independent review.

The sprint stops on unexpected output/diagnostic movement, duplicate authority,
premise-changing source evidence, non-fail-capable apparatus, unexplained
residuals, or a regression. Do not classify a current contamination repair as a
behavior-neutral migration without an explicit architecture ruling.

## 5. Batch and exit criteria

The conductor may add another family to the same PR only after the previous
family's checkpoint is green and the next packet survives re-admission at the
new head. Batch size is earned by evidence, not fixed in advance.

Before PR creation:

- obtain review of the final combined diff and cross-family interactions;
- run the final reviewed mutation matrix once and hash-prove restoration;
- derive and inspect named snapshots/goldens once from final source, then rerun
  their gates;
- run proportional local verification selected by
  `medaka-verification-scope`;
- record checks intentionally deferred to narrowed PR and full merge-group CI.

The sprint exits only after the PR head is independently reviewed, authoritative
merge-group CI proves the intended head landed, tracker handoffs record the
newly derived residual and next bounded question, and all task-owned daughters,
scratch probes, receipts, and run-root artifacts are reaped.

## 6. Explicit non-goals

Do not create a sprint conductor, referee, architecture-companion, or second
implementer agent. Do not create tracked `DECISIONS.md`, `DEBT.md`, logs, or
receipts. Do not treat binding attribution—or any other family named above—as
implementation-ready before Phase 0 synthesis and review.
