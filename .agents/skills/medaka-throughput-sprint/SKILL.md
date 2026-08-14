---
name: medaka-throughput-sprint
description: Runs coherent, stage-sized Medaka compiler sprints with continuous implementer occupancy, prepared handoff packets, proven-disjoint parallel writers, rolling parallel verification and CI, and a mandatory repair round. Use when executing many related refactor or migration slices for one reviewable stage without sacrificing quality.
---

# Medaka Throughput Sprint

Optimize, in order: continuous eligible-writer occupancy, low rework, then integrated slices per hour. Treat packet preparation as conductor's primary product. Use GitHub issues and comments for durable run state; keep compiler diffs free of process ledgers.

Read [github-protocol.md](references/github-protocol.md) before admitting sprint. Read [packet.md](references/packet.md) before dispatching any writer.

## Admit one coherent sprint

Select one architecture stage and tightly coupled subitems. Require one reviewable claim, fixed behavior, bounded ownership, ordered slice DAG, and stage-level exit checks. Split or combine tracker nodes when source evidence requires it. Never enlarge scope merely to keep agents busy.

Pin base revision. Create conductor integration branch/worktree. Post admission comment on stage issue with scope, non-goals, semantic authority, tentative DAG, expected mirrors, repair-round requirement, and enqueue approval boundary.

Escalate only choices materially changing accepted programs, runtime meaning, type/effect/interface semantics, evaluation order, failure behavior, or cross-backend semantic contract. Reorder, split, defer, or cancel work autonomously when evidence changes.

## Keep rolling lanes full

Maintain lanes in priority order:

1. primary writer on eligible slice;
2. preparation for successor; target prepared-queue depth two while tracking
   dispatchable depth separately;
3. prompt integration of completed slices;
4. high-value parallel verification and lightweight review;
5. CI on coherent pushed checkpoints;
6. broader preparation or proven-disjoint extra writers.

Never consume last available child slot with verification while eligible writer waits. Root conductor prepares packets directly; delegate bounded research only when it shortens eligibility path. On writer completion, dispatch successor immediately only when it is dispatchable. A prepared packet is not dispatchable while it overlaps an unreviewed carrier, harness, generated artifact, or acceptance boundary from the completed slice. Run lightweight diff review first for such overlap; overlap builds and verification, not successor edits. Create its writer worktree only after this gate clears.

Use child completion or ten-minute intervals as heartbeat. Record active writer, prepared depth, dispatchable depth, completed/integrated/reworked/discarded slices, writer gaps, integration and verification backlog, bottleneck, and concrete scheduling action. Status-only heartbeat fails contract.

## Admit writers by evidence

Slice eligible when writer can reach first edit after targeted named-code reading without architecture discovery or observable-semantic choice. Packet must satisfy [packet.md](references/packet.md).

Eligibility also requires an exact route/read observability matrix. For every migrated semantic field, distinguish shipping/probe routes (including scalar, ref, record, census, or aborting routes as applicable), name the reader reached, and classify evidence as data-correctness, ownership-only, or vacuous. A route with a discarded read is not dispatchable evidence.

One writer remains default. Add writers only after proving disjointness: distinct paths/regions, no shared API/carrier/semantic authority, no shared generated artifacts, no premise dependency, independent checks, deterministic integration order, and explicit collision scan. Different files alone do not prove disjointness. Every writer gets isolated worktree/branch.

If pinned assumptions or owned region changed, writer stops; it does not adapt across another writer's work. Conductor re-admits packet.

## Integrate and verify continuously

Only conductor integrates. Inspect diff against packet, run cheapest fail-capable integration discriminator, commit one coherent slice, push coherent checkpoints early, and post checkpoint SHA plus receipts/debt to stage issue. Do not let optional prose delay integration or successor dispatch.

Run highest-value verification in spare capacity: direct reproducer and nearest miss, compile/typecheck, changed-boundary differential, relevant eval/native/Wasm mirror, emitter fixpoint, lightweight adversarial review, then breadth. CI is parallel verifier. Continue writing while CI runs; stop writer only when failure invalidates its packet or shared premise. Record unrun, skipped, inconclusive, stale, or superseded checks as debt, never green.

Generated snapshots, selfproc goldens, seed, and similar exact-head artifacts have one derivation authority. Never merge competing generated outputs.

Mutation execution has one conductor-owned serialized lane. Designers and
reviewers may specify or audit rows; only `compiler-mutation-verifier` mutates
source. `sprint-verifier` owns ordinary gates and never substitutes legacy or
generic rows for caller's matrix. Create a durable receipt directory at
admission; after final freeze, bind one row per applicable field/class pair.
Capture each transaction's command/output there with exact transform,
expected/observed ID, exit state, restore hash, clean porcelain, and process
proof.

One assigned executable turn without a command or live yielded session is a
stall: interrupt and re-dispatch with exact packet. Long builds use yielded
sessions and polling instead of partial completion reports.

## Repair before landing

Repair round is mandatory and budgeted from admission. Stop admitting ordinary slices; preserve one repair writer when actionable findings exist. Run heavy independent adversarial review over exact pushed head, work every `could move` and nearest-miss obligation, reconcile CI, run remaining proportional gates, audit deleted/retained legacy authorities, and update GitHub debt disposition.

Push repaired head and obtain clean blocking verdict. Prepare final PR summary and explicit residuals. Ask user before enqueueing full sprint PR. Green CI, prior sprint approval, or permission to push does not imply enqueue approval.

Freeze pushed repair head during final heavy review and mutation. Any head
movement requires delta review and invalidation analysis before prior receipts
can carry forward.

Run `orchestrator-wrapup` before declaring completion.

## Measure outcomes

Track externally observed timestamps:

- primary-writer active minutes / eligible elapsed minutes;
- writer gaps and blockers;
- prepared versus dispatchable queue depth;
- dispatch-to-first-edit and dispatch-to-coherent-diff latency;
- diff-to-integration latency;
- completed, integrated, reworked, and discarded slices;
- rework minutes per integrated slice;
- integrated slices per hour;
- verification/CI overlap.

Optimize integrated coherent slices, not utilization, token output, or diff size. Weak packets that create rework reduce throughput.
