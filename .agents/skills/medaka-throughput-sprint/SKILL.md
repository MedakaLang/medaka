---
name: medaka-throughput-sprint
description: Runs coherent, stage-sized Medaka compiler sprints with continuous implementer occupancy, prepared handoff packets, proven-disjoint parallel writers, rolling parallel verification and CI, and a mandatory repair round. Use when executing many related refactor or migration slices for one reviewable stage without sacrificing quality.
---

# Medaka Throughput Sprint

Optimize, in order: continuous eligible-writer occupancy, low rework, then integrated slices per hour. Treat packet preparation as conductor's primary product. Use GitHub issues and comments for durable run state; keep compiler diffs free of process ledgers.

Read [github-protocol.md](references/github-protocol.md), [codex-mapping.md](references/codex-mapping.md), and [run-ledgers.md](references/run-ledgers.md) before admitting sprint. Read [planning.md](references/planning.md) before cutting stage. Read [packet.md](references/packet.md) before dispatching any writer. Read [findings-and-retro.md](references/findings-and-retro.md) before findings intake or closeout.

## Admit one coherent sprint

Select one architecture stage and tightly coupled subitems. Require one reviewable claim, fixed behavior, bounded ownership, ordered slice DAG, and stage-level exit checks. Split or combine tracker nodes when source evidence requires it. Never enlarge scope merely to keep agents busy.

Pin base revision. Create conductor integration branch/worktree. Post admission comment on stage issue with scope, non-goals, semantic authority, tentative DAG, expected mirrors, repair-round requirement, and enqueue approval boundary.

Before first writer, run one disposable isolation smoke probe. First report toplevel/head/status and compare to conductor path. If equal, stop before any git mutation and select `FRONT-SEAT`: conductor creates each writer worktree and every writer command uses that absolute `workdir`. Only inside a proven distinct tree test `/var/tmp` write, throwaway commit, push-by-ref, and remote-ref cleanup. Correct ancestry selects `HARNESS`; wrong head selects `HARNESS+REBASE` with one explicitly licensed SHA-pinned rebase. Anything else blocks for judgment. Never claim isolation before probe.

For each expected red, record `masks:` with command-derived skipped successor checks and `unmask-by:` scheduled in sprint's first half. `unmask-by: wrap-up` is invalid. After writer #1 is active, build one immutable base-arm depot from pinned base for reviewer/reproducer differentials; copy binaries plus `stdlib/` and `runtime/`, record SHA/path, and never use depot for fix before/after attribution.

Derive candidate scope from current issues, source, history, and merged work; inherited plans are claims. Budget property-class review when code's deployment domain adds obligations stage acceptance cannot express: constant-time behavior, hostile-input trust boundaries, crypto/protocol misuse, irreversible effects, or concurrency. Dispatch one property class per `domain-adversary` review.

Escalate only choices materially changing accepted programs, runtime meaning, type/effect/interface semantics, evaluation order, failure behavior, or cross-backend semantic contract. Reorder, split, defer, or cancel work autonomously when evidence changes.

Use one persistent `sprint-brain` judgment seat when rulings become frequent. It reads primary artifacts and writes numbered ruling files; conductor mechanically applies them. Never run two brains concurrently. Rotate brain and rear at phase boundaries and after roughly five landings: successor reads required ledgers first. Keep `sprint-rear` live when slots permit; root conductor remains responsible for transport and final state. Ledgers, not growing daughter context, carry state.

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

Designate one dependency-free `independent-refill` packet outside main DAG and prepare it immediately after packet #1. If none exists, record why. Two prepared packets depending on active slice do not protect runway.

Use child completion or ten-minute intervals as heartbeat. Record active writer, prepared depth, dispatchable depth, completed/integrated/reworked/discarded slices, writer gaps, integration and verification backlog, bottleneck, and concrete scheduling action. Status-only heartbeat fails contract.

At phase boundaries, verify ruling sequence and obligation closure mechanically. Pause by writing exact head, active work, dispatchable packets, open findings/refusals/obligations, CI state, and next action; do not rely on live agent context.

## Admit writers by evidence

Slice eligible when writer can reach first edit after targeted named-code reading without architecture discovery or observable-semantic choice. Packet must satisfy [packet.md](references/packet.md).

Eligibility also requires an exact route/read observability matrix. For every migrated semantic field, distinguish shipping/probe routes (including scalar, ref, record, census, or aborting routes as applicable), name the reader reached, and classify evidence as data-correctness, ownership-only, or vacuous. A route with a discarded read is not dispatchable evidence.

One writer remains default. Add writers only after proving disjointness: distinct paths/regions, no shared API/carrier/semantic authority, no shared generated artifacts, no premise dependency, independent checks, deterministic integration order, and explicit collision scan. Different files alone do not prove disjointness. Every writer gets isolated worktree/branch.

If pinned assumptions or owned region changed, writer stops; it does not adapt across another writer's work. Conductor re-admits packet.

After dispatch, packet is immutable. Mid-flight communication has two channels only:

- `fact:` derived advisory evidence; non-binding;
- `stop:` abort dispatch.

Added sites, edits, checks, or acceptance criteria require packet revision before work starts or successor packet after landing. Writer declines and records any inline amendment. Track every refusal or premise conflict with claimant, claim, evidence, adjudication, and terminal verdict (`UPHELD`, `OVERRULED`, or `PARTIAL`). Zero refusals must remain distinguishable from missing records.

## Integrate and verify continuously

Only conductor integrates. Inspect diff against packet, run cheapest fail-capable integration discriminator, commit one coherent slice, push coherent checkpoints early, and post checkpoint SHA plus receipts/debt to stage issue. Do not let optional prose delay integration or successor dispatch.

Require every non-brain agent response to contain literal `time:` plus `Verdict`, `Evidence`, `Decisions surfaced`, `Deviations from packet`, `Not covered`, and `Friction`; `NONE` is valid, omission is not. Every dispatch names report path. Because read-only Codex roles cannot write `/var/tmp`, conductor writes returned text verbatim to that path, then always runs `sh scripts/sprint-report-check.sh <report>`; never summarize or reconstruct it. Role-specific tables/findings live inside Evidence. Brain uses numbered ruling-file contract instead.

After every behavior-changing landing, run mandatory parallel pair: `sprint-reviewer` as slice breaker attacking claim/counterexamples, and `sprint-conformance-reviewer` checking packet/rulings/spec/prose. Queue pair behind writer when slots clamp; do not defer it to heavy round. For parity landings, run pair when `could move`, nearest miss, or overlap review demands it.

Run remaining verification in spare capacity: direct reproducer and nearest miss, compile/typecheck, changed-boundary differential, relevant eval/native/Wasm mirror, emitter fixpoint, then breadth. CI is parallel verifier. Continue writing while CI runs; stop writer only when failure invalidates packet/shared premise. Record unrun, skipped, inconclusive, stale, or superseded checks as debt, never green.

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

Re-derive packet, ruling, debt, and comment claims: counts, SHAs, line numbers, performance figures, executed checks, and required/optional status. Verify touched or relied-on safety prose and structural invariants. Treat filename-only search, one-hop enumeration, and unexecuted mechanism claims as candidates, not evidence.

Push repaired head and obtain clean blocking verdict. Prepare final PR summary and explicit residuals. Ask user before enqueueing full sprint PR. Green CI, prior sprint approval, or permission to push does not imply enqueue approval.

Freeze pushed repair head during final heavy review and mutation. Any head
movement requires delta review and invalidation analysis before prior receipts
can carry forward.

Run `orchestrator-wrapup` before declaring completion.

After merge-queue completion, run retrospective against durable artifacts and terminal `merge_group` CI. Attribute each finding to refusal, slice review, domain review, repair review, CI, or nobody. Propose at least two rule retirements with evidence; workflow only grows otherwise. Port accepted durable changes into `.agents/skills/` and `.codex/agents/`, not Claude-only definitions.

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
