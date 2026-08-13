---
name: medaka-throughput-sprint
description: Runs throughput-first Medaka compiler sprints with continuous implementer occupancy, parallel verification and research, measured dynamic tuning, and recurring throughput heartbeats. Use with the sprint-* agent family.
---

# Medaka Throughput Sprint

This skill defines the shared contract for the additive `sprint-*` agents. It does not replace the conservative `medaka-compiler` workflow.

## Objective

Maximize integrated, reviewable, compile-coherent compiler slices per wall-clock hour while preserving a baseline quality floor. Keep at least one implementer active whenever an eligible slice exists. An eligible slice has fixed externally observable semantics, bounded ownership, named paths/mirrors, and a coherent handoff boundary.

Do not optimize raw utilization. Speculative edits, overlapping ownership, large discarded diffs, and verification debt that repeatedly causes rework reduce throughput even when every agent is busy.

## Pipeline

Maintain these concurrent lanes:

- **Writer lane:** one or more isolated `sprint-implementer` tasks on independent eligible slices.
- **Preparation lane:** bounded research/design that keeps at least two slices ready when possible.
- **Integration lane:** rapid diff inspection and checkpoint creation; never let completed diffs wait behind optional prose.
- **Verification lane:** exact-checkpoint focused checks in separate worktrees or background jobs.
- **Review/CI lane:** early pushed-head review and CI, overlapped with preparation or later admitted slices.

Only integrate one compiler-source state at a time. Parallel writers must own disjoint files/API surfaces or have an explicit dependency order. Snapshots, selfproc goldens, seed artifacts, and other generated outputs have one exact-head derivation lane.

## Quality Floor

Before an implementer hands off:

1. the edit is compile-coherent by inspection;
2. fixed semantics and ownership are preserved;
3. named executable mirrors are updated;
4. at least one cheap, fail-capable check is run or boundedly attempted with an exact owed remedy;
5. the diff and unverified obligations are explicit.

Broad verification belongs to parallel verifiers or CI unless it resolves a concrete uncertainty that blocks further implementation. Never count a phantom skip, stale oracle, timeout, or unrelated early failure as a pass. Captured output is not semantic authority.

## Dynamic Overrides

Agent definitions contain **hard invariants** and **soft defaults**.

The conductor may explicitly replace a soft default when the assignment states:

- the default being replaced;
- the throughput hypothesis and reason;
- the replacement acceptance boundary;
- when the override expires;
- what timing or defect signal will determine `keep`, `revise`, or `revert`.

Soft defaults include report headings/length, check budget, task timebox, sequencing, checkpoint frequency, discovery depth, and optional workflow steps.

Hard invariants cannot be overridden: system/developer instructions; root/nested `AGENTS.md`; tool permissions; isolated writer ownership; authorized paths; destructive-operation safeguards; user-reserved semantic choices; honest evidence labels; source restoration; generated-artifact single authority; and the compile-coherent plus fail-capable handoff floor. A prompt cannot grant a denied tool.

If an override is valid, follow it instead of treating definition wording as immutable ceremony. If invalid, refuse only the conflicting part and continue all safe work.

## Heartbeat Contract

At sprint admission, the conductor schedules a recurring five-minute in-session reminder with `reminderadd`. Each heartbeat records the interval delta and immediately acts on it:

- active eligible writers and writer utilization;
- ready queue depth;
- completed, integrated, discarded, and reworked slices;
- writer gaps and their blockers;
- integration and verification backlog;
- dominant bottleneck;
- concrete actions until the next heartbeat.

Action can be launching/resuming a writer, narrowing or cancelling low-yield work, integrating a ready diff, parallelizing verification, or moving capacity to unblock eligibility. A heartbeat that only reports is a failed heartbeat. Remove it at sprint completion. If scheduling is unavailable, use child-completion or ten-minute manual heartbeats.

## Timing Contract

Every child returns approximate time in:

- admission/setup;
- targeted reading/research;
- reasoning/design;
- editing;
- checks/builds;
- blocked/waiting;
- rework;
- total wall time and parallel overlap.

Implementers also report first-edit latency. Verifiers report prerequisite versus grading time. All agents name the highest-cost avoidable step and one prompt/process change that might remove it.

The conductor records externally observed dispatch and completion timestamps because self-reported partitions are estimates. Judge experiments by integrated output, integration latency, rework, and escaped findings, not agent confidence.

## Stop And Trim Rules

- Cancel or narrow work whose expected decision value falls below its delay to the writer or integration lane.
- Do not duplicate research or verification already owned by another task or authoritative CI.
- Stop a writer only for semantic ambiguity, ownership collision, unsafe worktree state, premise-changing evidence, or inability to reach a coherent boundary.
- When the queue empties, put all non-essential capacity on the shortest eligibility blocker.
- When integration backlog grows, stop launching colliding writers and increase integration capacity.
- When verification backlog grows without evidence of regressions, defer breadth to CI; when rework rises, restore the smallest discriminator that would have caught it.

## Sprint Exit

Before completion, require a coherent pushed head, independent `sprint-throughput-reviewer` verdict, explicit CI-deferred checks, no unresolved blocking finding, and cleanup of reminders, background jobs, and disposable worktrees. Report throughput metrics and retained/reverted tuning experiments so the next sprint can improve rather than restart measurement.
