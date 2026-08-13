---
name: medaka-emitter-sprint
description: Conducts batched design and rolling implementation sprints for Medaka emitter epic #1398. Use for X-N/X-W/X-L sprint intake, candidate synthesis, serial integration, and one-PR finalization.
---

# Medaka Emitter Sprint

Use this skill for a bounded #1398 sprint that increases throughput through
parallel evidence and design work without weakening revision isolation,
verification, or landing authority. It supplements, rather than replaces,
`medaka-epic-intake`, `medaka-emitter-state-migration`,
`medaka-structural-migration-tests`, `medaka-continuation-receipt`,
`medaka-verification-scope`, and `medaka-pr-lifecycle`.

## 1. Admit the run

Fetch and pin `TASK_BASE`, create the detached intake worktree, and derive
readiness from tracker, merged history, and source. Create a unique disposable
run root only after the milestone is selected:

```text
/var/tmp/medaka-scratch/opencode/emitter-sprint-1398/<base12>-<utc>/
```

Record admission in `ADMISSION.md`: exact base, intake/topic paths, branch or
detached state, clean porcelain, owners, and the derivation of the selected
pre-fan-in lane. Never carry a residual count or issue status from a prior run.

The tracked sprint document is a durable protocol and scope proposal, not live
state. Runtime packets, command logs, captures, receipts, and reviews stay in
the disposable run root and are deleted at wrap-up.

## 2. Phase 0 is parallel and read-only

Fan out bounded packets against one exact revision:

- `P0-INTAKE`: tracker/history/source readiness and completed carriers;
- `P0-CENSUS`: normalized raw authority set, then semantic-family grouping;
- `P0-APPARATUS-<family>`: executable routes, P/U/read/observable matrix,
  rendering/event-only/aborting classification, capture-hook feasibility;
- `P0-DESIGN-A`: smallest coherent candidate;
- `P0-DESIGN-B`: nearest alternative and the reason A may be unsafe or
  undersized;
- `P0-SYNTHESIS`: conductor-adjudicated selection or explicit deferral;
- `P0-REVIEW`: fresh independent audit of fail-capability, sizing, mirrors, and
  residuals.

The census reports sets and evidence, not architecture. Candidate designers do
not select the sprint winner independently. The conductor verifies decisive
premises and owns synthesis. All packets name producer, phase, base/head,
evidence status (`OBSERVED`, `DERIVED`, `RELAYED`, `OWED`), artifact paths, and
invalidation conditions. A relayed premise must be independently re-derived
before implementation admission.

Phase 0 completes only when every packet agrees on its revision and source
population. Resolve disagreement from source/evidence; never average reports or
merge their prose.

## 3. Admit one implementation slice at a time

A selected family must pass all of these gates:

1. one bounded implementer turn reaches a compile-coherent boundary;
2. semantic inputs stay in immutable input/validated-plan carriers;
3. all declarations, initializers, resets, writers, readers, drains, dynamic
   scopes, callers, and public routes are named;
4. current ordering, first-match policy, save/set/read/restore extent, output,
   and diagnostic behavior are fixed by authority or observed controls;
5. the apparatus is executable and fail-capable before exact assertions are
   authored;
6. one mutant per semantic field plus legal renamed-authority ownership mutants
   is specified with the earliest stable expected-red rule;
7. focused verification, snapshot, selfproc, fixpoint, and deferred-CI
   obligations are explicit;
8. the residual authority set will be re-derived after the slice.

If execution is needed to discover generated IR/WAT or diagnostic text, split
capture-hook work from exact assertions. A promising census candidate is not an
implementation packet.

## 4. Parallelize readers; isolate writers; serialize integration

Read-only, revision-insensitive census/design/review packets may run in
parallel. Write-capable or race-sensitive work always receives its own
worktree/branch. The sole compiler implementation authority remains
`compiler-implementer` at its fixed daughter path, one assignment at a time.

Provisional analysis of the next family may overlap implementation or
verification of the current family, but it is invalidated by any intervening
source change that can affect its census, routes, apparatus, or acceptance
boundary. Re-admit it against the new exact head before dispatch.

Only the conductor integrates. Never share a writer worktree, merge generated
goldens, or allow two branches to derive snapshots from different compiler
states. Compiler-source landings and their exact-head measurements are serial.

## 5. Checkpoint every integrated family

Before another family is integrated, require:

- stateless source feedback on the coherent daughter diff;
- targeted format and lint;
- the focused executable ownership/control harness with no phantom skip;
- compiler-source typecheck;
- native self-compile fixpoint;
- relevant Wasm typed/module/product route when Wasm is touched;
- re-derived snapshot and selfproc obligations;
- normalized residual authority set and no duplicate authority;
- fresh review of code and any new/materially changed harness.

Stop the sprint on an unexpected behavior change, premise conflict, invalid
apparatus, unexplained residual, or regression. Reconcile premise-changing
evidence with `compiler-designer`; ask the user only when externally observable
semantics or durable architecture direction requires a choice.

## 6. Finalize one reviewed batch

After the last accepted family, run one final mutation matrix on the reviewed
exact-head harness. Then derive snapshots/goldens once from the final source,
inspect every generated diff, rerun their gates, and apply proportional local
verification. Open one PR for the coherent batch and follow
`medaka-pr-lifecycle`; merge-group CI remains landing authority.

The PR and tracker handoff name every family moved, completed carriers not
duplicated, exact local receipts, review and mutation verdicts, the newly
derived residual set, and the next bounded census question. Run
`orchestrator-wrapup`, retain no disposable sprint artifact, and report any
intentionally retained branch or worktree.

## Do not create

- a shared-trunk writer fleet;
- another compiler implementer or backend-writer path;
- permanent `DECISIONS.md`/`DEBT.md` append-only ledgers;
- tracked logs, captures, receipts, or probe outputs;
- a fixed remaining-state count in workflow instructions;
- an implementation-ready label for a family before apparatus and plan review;
- mid-sprint golden merges or hand-resolved generated artifacts.
