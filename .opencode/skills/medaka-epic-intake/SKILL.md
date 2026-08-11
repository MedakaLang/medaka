---
name: medaka-epic-intake
description: Derives the earliest uncompleted and unblocked Medaka epic milestone from issue state, merged PR history, and current source. Use for staged architecture epics and migration DAG continuation requests.
---

# Medaka Epic Intake

Use this skill before designing or implementing the “next item” in a staged
compiler architecture epic. Tracker state is a lead, not proof: a stage issue may
remain open after a sub-milestone landed, and migration order may describe a
future fan-in that does not block independent hygiene work.

## 1. Pin and isolate intake

Fetch `origin/main`, record immutable `TASK_BASE`, and create a detached intake
worktree at that revision. Perform issue/history/source readiness reads there.
Do not use a stale shared checkout or a moving branch ref as current-main proof.

## 2. Derive readiness from three authorities

For each candidate sub-milestone, collect:

1. **Tracker:** epic/stage body and latest handoff comments, including explicit
   prerequisites and residual scope.
2. **History:** merged PR state, intended head, merge commit, and chronology.
3. **Source:** the claimed carrier, retired authority, or consumer is present or
   absent at `TASK_BASE`.

Open/closed issue state alone is insufficient. A merged PR title alone is
insufficient. A source symbol alone does not prove its acceptance criteria or
authoritative merge-group result.

## 3. Select the milestone

Choose the earliest candidate that is both:

- **uncompleted:** its acceptance carrier or residual is absent in current
  source/history; and
- **unblocked:** every prerequisite that owns an authoritative producer is
  present, or the issue explicitly permits this independent pre-fan-in lane.

Do not infer “blocked” merely because later canonical stages remain open. Do not
duplicate a landed hygiene slice or begin a consumption/cutover slice before its
validated producer exists.

## 4. Keep readiness bounded

Return the selected milestone, completed siblings with immutable evidence,
blocked candidates and why, the source carrier checked, and the exact next
source-census question. Do not combine this readiness derivation with an
exhaustive implementation call graph unless both demonstrably fit the assigned
turn. A scout that finishes readiness and names a second bounded census is better
than one that exhausts its budget halfway through both.

## Required packet

Record: pinned base and intake path; selected milestone; tracker/history/source
evidence; completed siblings; blocked prerequisites; observations versus
inferences; unresolved uncertainty; recommended next bounded assignment; and
friction under `medaka-friction-report`.
