---
name: medaka-throughput-sprint
description: "Run a Medaka implementation sprint (v8): 3–5 serial packeted slices, minimal slice checks, one whole-diff review and fix round, then merge-queue closeout. Use for one coherent stage, not an ordinary small PR."
---

# Medaka throughput sprint (v8)

Run one coherent implementation stage from this session. The priority order is
implementation throughput, low process cost, then correctness before merge.
The deliberately small mechanism is serial writers with 3–5 focused checks,
one whole-diff review at the end, one serial fix round, and the merge queue.
Do not recreate the retired persistent brain/rear/planner/verifier seats,
per-slice review, or process-ledger system.

Use this skill only when the work naturally cuts into 3–5 dependent slices.
For fewer than three slices, make an ordinary PR instead. The root conductor
authors packets and makes routine sequencing decisions; escalate only a choice
that materially changes accepted semantics or the approved contract.

## Read only what the phase needs

- Before admitting or cutting a sprint, read [planning.md](references/planning.md).
- Before writing, executing, or assessing a slice packet, read
  [packet.md](references/packet.md).
- Before dispatching an agent or relying on a report, read
  [transport.md](references/transport.md). It documents the real Codex
  worktree and fixed-model limits rather than pretending that Claude transport
  exists here.

Use `gates` when a gate is involved, `medaka-verification-scope` before
choosing local checks, `medaka-pr-lifecycle` for PR/queue/merge work, and
`orchestrator-wrapup` before declaring the sprint complete.

## Durable state

Create `/var/tmp/medaka-sprints/<stage>/` with `CONTRACT.md`, `packets/`, and
`reports/`. Its only run-state files are:

- `STATUS.md`: one row per slice with `queued`, `running`, `landed`,
  `refused`, or `dropped`, plus landed SHA and report path. Update it at every
  transition.
- `NOTES.md`: append-only one-line findings, decisions, scope declines, and
  contract edits. The end review triages these; only a finding that blocks a
  later slice is fixed immediately or escalated.

Do not add decision, obligation, finding, queue, debt, or friction ledgers.
Git history plus these two files is the resumable record. The conductor alone
opens/edits issues and PRs, pushes the integration branch, and verifies every
GitHub write by readback.

## Start

1. Re-derive the candidate from tracker, current source, history, and its
   semantic authority at one pinned `origin/main` revision. Write the compact
   contract and create the sprint branch/early draft PR from that revision.
2. Check `known-red` before diagnosing a red gate. Keep any expected-red
   statement in contract §6; do not invent a second ledger.
3. Write `STATUS.md`, author packet 1, and retain only the next packet in
   preparation while a writer is active.

## Slice loop

1. Author a one-page packet from the contract. Its base is the current sprint
   head. Before *every* implementer dispatch, including fixes, fetch the
   sprint branch and `origin/main`. If main has moved, examine the true
   merge-base and overlap against stage-owned files; when safe, resync the
   sprint branch and update the packet base before dispatching. A stale-main
   block is a conductor transport failure, not routine implementer work.
2. Dispatch one `sprint_implementer` using the transport reference. While it
   runs, prepare only the successor packet. Parallel writers are exceptional:
   the contract must mark them `parallel-ok` and prove current-head
   disjointness, including generated artifacts and fixtures. Otherwise run
   serially.
3. Read the on-disk report, not merely the return line. For `LANDED @sha`,
   verify the commit and merge that exact SHA into the sprint branch; never
   merge a mutable branch name. Push, update `STATUS.md`, and continue without
   waiting for CI. For `REFUSED`, correct the packet or contract and record a
   one-line note before retrying; if its premise is overturned, drop it. For
   `BLOCKED`, repair the actual transport/environment fault; stop and report
   the same block after two attempts. For `SPIKE-DONE`, revise and dispatch the
   real packet.

## Review, repair, and landing

1. When every slice is landed or dropped, dispatch one `sprint_reviewer` on
   the exact sprint head and merge-base. Give it the contract, `NOTES.md`, and
   any domain property classes named by the contract. It reviews the complete
   diff, not individual slices. A second reviewer is allowed only when it has
   a distinct stated lens.
2. Triage review and NOTES leads into fix-now, file, or dismiss. Reproduce
   before filing; apply [W-QUIETER] when a formerly failing path begins to
   return a value. Record terse rationale in `NOTES.md`.
3. Stop ordinary work and dispatch small fix packets serially until fix-now is
   empty. Repeat the same pre-dispatch freshness/resync check. Re-review the
   final exact head if a fix changes a reviewed claim or invalidates evidence.
4. Run targeted fmt/lint and the proportional checks chosen through
   `medaka-verification-scope`; use `make preflight` only when its blast radius
   is warranted. Mark the PR ready and take it through the lifecycle skill:
   enqueue, required CI, merge-group result, and fresh-main ancestry of each
   reported landing SHA.
5. Update the tracking issue with what landed, what was filed, exact SHAs, and
   whether successor work is unblocked. Dispatch `sprint_retro`, persist its
   short report under `reports/`, update terminal `STATUS.md`, then run wrapup.

## Invariants

- Pin refs before an operation; shared remotes and `origin/main` move.
- Never edit compiler source while a build is in flight. Use `MEDAKA_STRICT=1`
  for probes whose result matters.
- Rebuild relevant oracles after a merge/rebase before any golden capture or
  bless. A packet licenses only its named golden paths.
- No dispatched agent performs GitHub write operations. Every `gh` write by
  the conductor is read back; queue state and fresh-main ancestry, not command
  exit status, prove a landing.
