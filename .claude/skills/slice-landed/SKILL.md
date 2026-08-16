---
name: slice-landed
description: The orchestrator's fixed sequence for the moment an implementer returns — report intake, refill the writer lane, push/arm CI, dispatch both reviewers and the planner, then bookkeeping. Run on EVERY implementer return (landed, refused, or blocked; slice or family leaf). Order is load-bearing.
---

# Slice landed — the completion sequence

Run this the moment any implementer returns. The order exists because the
measured sprint bottleneck was the orchestrator doing bookkeeping serially with
ZERO writers live (0.73× parallel efficiency; 33 of 122 minutes dead): everything
that refills or feeds the writer lane happens BEFORE anything that merely
records. Do not reorder, do not interleave, do not "just quickly" verify
something between steps 1 and 2.

## Step 0 — report intake (always, for every verdict)

1. The report file exists at the packet's named path. Agent ran isolated? Copy it
   out NOW — `cp <agent-wt>/<report> .claude/sprint-<stage>/reports/` — before
   anything else; the worktree can be reclaimed and a return message is a
   summary, not an artifact.
2. All five §9 sections present (`Verdict` / `Evidence` / `Decisions surfaced` /
   `Deviations from packet` / `Not covered`), each non-absent (`NONE` is valid).
   Missing any → BOUNCE: continue the agent via SendMessage telling it which
   section to complete. Do not proceed on a bounced report; do not fill the gap.
3. Read ONLY the `Verdict` line to branch below. You are not the report's
   evaluator — its content routes in step 5.

## Verdict = LANDED

**1. Refill the writer lane.** Dispatch the next implementer from the queued
packet — one-line brief ("Execute packet <path> under the sprint-packet
contract"), model per the packet §1 classification (parity → default Sonnet;
behavior-changing / spike / unstable-DAG → `model: opus`). If no packet is
queued, that is a planner stall: note it, and make step 4 a blocking priority.

**2. Push and arm; stop looking.** Push the slice branch; open/update the PR
(`scripts/pr.sh body` — hand-rolled `gh` writes silently no-op) and enqueue
(`scripts/pr.sh enqueue`, which verifies queue membership via GraphQL rather
than trusting exit codes — the exit code of `gh pr merge --auto` carries no
signal either way). Then STOP: no watching, no per-shard checks. The heartbeat
reads the rollup; the merge queue is the authority. Serialized landing: if
another PR of yours is already queued, do NOT enqueue this one yet — record it
as arm-next in the queue file and let the heartbeat arm it after the first
merges.

**3. Dispatch both reviewers, one message, in parallel:** `slice-breaker`
(isolation: worktree; give it packet path, implementer report path, slice head
SHA, and its report path) and `spec-conformance-reviewer` (give it the same plus
the pinned base SHA). They run concurrently with the new writer — readers don't
collide with writers.

**4. Dispatch `sprint-planner`** for slice N+2's packet: give it the sprint
contract section or ruling to plan, the just-landed report's path (it must read
`Deviations` and `Decisions surfaced` before writing — feed-forward is its
rule), and the pinned base.

**5. Bookkeeping — only now, while all of the above runs:**
- Route the report mechanically: `Decisions surfaced` ≠ NONE or `Deviations from
  packet` ≠ NONE → brain consult (question + triggering rule + file path — never
  a paraphrase). `Not covered` items → append verbatim to FINDINGS.md.
- DEBT row present with non-blank fields (presence check only — content
  judgment is the conformance reviewer's).
- Append the dispatch log entries to DECISIONS.md (who dispatched, on what, when
  — this log is the end-of-sprint report-sweep checklist).

## Verdict = LANDED, family leaf (not final)

Lighter path: intake the leaf's report block (step 0), commit is already on the
branch — push it so the draft PR's CI runs while later leaves execute — then
**continue the SAME implementer via SendMessage** ("leaf N next"). Reviewers and
planner fire once, at the FAMILY's final leaf, via the full sequence above.
Leaf `Decisions surfaced` / `Deviations` still route to the brain immediately —
adjudication does not wait for the family.

## Verdict = REFUSED or BLOCKED

A refused slice is landed work — treat it with the same energy, and keep the
writer lane's refill from waiting on adjudication:

1. **Refill the lane in parallel** with an INDEPENDENT queued packet if one
   exists (one whose §1 collision matrix and premises don't depend on the
   refused slice's outcome). If the only queued work is downstream of the
   refusal, the lane legitimately idles — record why in DECISIONS.md; do not
   dispatch dependent work against an unadjudicated premise.
2. **Brain consult, immediately:** the refusal report's path + the packet path +
   the escalation rule ("any refusal"). The brain's default is believe-and-re-cut.
3. **Execute the brain's Actions verbatim** — typically: planner revises the
   packet (or the DAG's remaining leaves) folding the refusing agent's
   measurement into §4; the re-cut slice enters the queue at the front.
4. Bookkeeping as in step 5 above. The refused packet is retained, not deleted —
   it is evidence, and the ledger entry points at it.

## Reviewer returns (arrive later, asynchronously)

Intake per step 0. Verdict `CLEAR` → record in DECISIONS.md; if `Not covered` is
empty on a CLEAR, bounce it — that is the one report shape to distrust on sight.
Verdict `FINDINGS` → load the `sprint-findings` skill and run its lifecycle:
FINDINGS.md row first, attribution second, brain ruling third (REPAIR / ABSORB /
FILE / DEFER / DISMISS), execution fourth. Critical/high finding on a PR already
queued: dequeue FIRST (GraphQL `dequeuePullRequest` — `--disable-auto` does not
dequeue), then consult. The writer lane never blocks on review adjudication; a
repair slice enters the queue like any other packet, cut by the planner from the
brain's ruling.
