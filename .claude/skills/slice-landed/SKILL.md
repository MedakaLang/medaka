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

0. **Take the lock:** create `SEQUENCE.lock` in the sprint dir. The heartbeat
   takes no dispatch/arming action while it exists; remove it as this
   sequence's final act. (A crashed sequence leaves a stale lock — a heartbeat
   tick finding a lock older than ~30 min escalates it to the brain rather
   than deleting it.)
1. The report file exists at the packet's named path — which is under
   `/var/tmp/medaka-sprints/<stage>/reports/`, OUTSIDE every worktree, so even
   isolated agents write it there directly. If an agent wrote in-worktree
   anyway, copy it out NOW (`cp <agent-wt>/<report> .../reports/`) before
   anything else — the worktree can be reclaimed, and a return message is a
   summary, not an artifact.
2. All six §9 sections present ("Verdict" / "Evidence" / "Decisions surfaced" /
   "Deviations from packet" / "Not covered" / "Friction"), each non-absent
   (`NONE` is valid).
   Missing any → BOUNCE: continue the agent via SendMessage telling it which
   section to complete. Do not proceed on a bounced report; do not fill the gap.
3. Read ONLY the "Verdict" line to branch below. You are not the report's
   evaluator — its content routes in step 5.

## Verdict = LANDED

**1. Refill the writer lane.** Take the next packet from QUEUE.md and:
- **Completeness scan** (mechanical presence check): every §0–§9 section
  present, §4 facts each carrying a command, §1 carrying base SHA + worktree
  path + form + classification. Missing anything → BOUNCE to the planner, and
  take the next independent packet instead — never dispatch a known-incomplete
  packet to burn a worktree discovering it.
- **Create the worktree** the packet's §1 names, if absent:
  `git worktree add <path> <packet's pinned base SHA>`. Worktree creation is
  YOURS — no agent creates its own, and the packet's path is only a name until
  this step.
- **Dispatch** — one-line brief ("Execute packet <path> under the sprint-packet
  contract"), model read off §1: `parity` → default Sonnet; `behavior-changing`
  (which includes every spike and unstable-DAG slice, per §1) → `model: opus`.
If no packet is queued, that is a planner stall: note it in QUEUE.md, and make
step 4 a blocking priority.

**2. Push and arm; stop looking.** Push the slice branch; open/update the PR
(`scripts/pr.sh body` — hand-rolled `gh` writes silently no-op) and arm with
**`scripts/pr.sh enqueue --timeout 60`** — the short timeout is deliberate:
default `enqueue` polls queue membership for up to 900 s, which is waiting on
CI (a PR joins the queue only once required checks pass) and busts the
foreground ceiling. Sixty seconds arms and verifies the arming; if membership
isn't observable yet that is EXPECTED — the heartbeat's rollup tick re-verifies
until `MERGED`. Then STOP: no watching, no per-shard checks; the merge queue is
the authority. Serialized landing: if another PR of yours is already queued, do
NOT arm this one — record it as arm-next in `QUEUE.md`; the heartbeat's rollup
tick arms it after the first merges.

**3. Dispatch both reviewers, one message, in parallel:** `slice-breaker` (in a
worktree YOU create at the slice head SHA — `git worktree add <path> <head>`;
give it that path, the packet path, implementer report path, and its report
path) and `spec-conformance-reviewer` (no worktree — read-only via `git show`;
give it the same paths plus the pinned base SHA). They run concurrently with
the new writer — readers don't collide with writers.

**4. Dispatch `sprint-planner`** for slice N+2's packet: give it the sprint
contract section or ruling to plan, the just-landed report's path (it must read
"Deviations" and "Decisions surfaced" before writing — feed-forward is its
rule), and the pinned base.

**5. Bookkeeping — only now, while all of the above runs:**
- Route the report mechanically: `Decisions surfaced` ≠ NONE or `Deviations from
  packet` ≠ NONE → brain consult (question + triggering rule + file path — never
  a paraphrase). "Not covered" items → append verbatim to OPEN-QUESTIONS.md.
  "Friction" items → FRICTION.md.
- DEBT row present with all five §6 fields non-blank (presence check only —
  content judgment is the conformance reviewer's).
- Append the dispatch log entries to DECISIONS.md (who dispatched, on what, when
  — this log is the end-of-sprint report-sweep checklist).
- **Release the lock** (`SEQUENCE.lock`) — last act of the sequence.

## Verdict = `LANDED leaf <id> (<k>/<n>)` — family leaf, not final

Finality is read off the Verdict line alone: a mid-family leaf reports
`LANDED leaf <id> (<k>/<n>)`; the last leaf reports `LANDED family-final` and
takes the FULL sequence above. For a mid-family leaf, the lighter path: intake
the leaf's report block (step 0), commit is already on the branch — push it so
the draft PR's CI runs while later leaves execute — then **continue the SAME
implementer via SendMessage** ("leaf <next-id> next"). Leaf "Decisions
surfaced" / "Deviations" still route to the brain immediately — adjudication
does not wait for the family. Release the lock after each leaf intake.

## Verdict = REFUSED or BLOCKED

A refused slice is landed work — treat it with the same energy, and keep the
writer lane's refill from waiting on adjudication:

1. **Refill the lane in parallel** with an INDEPENDENT queued packet if one
   exists. Independence is mechanical, not judged: the candidate's contract
   `depends-on` list does not name the refused slice, AND its §1 collision
   matrix records zero intersection with it, AND no §4 fact cites the refused
   slice's handle. Any of the three fails or is ambiguous → treat as dependent.
   If nothing qualifies, the lane legitimately idles — record why in
   DECISIONS.md (mechanical append); do not dispatch dependent work against an
   unadjudicated premise.
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
FILE / DEFER / DISMISS), execution fourth. S0/S1 finding on a PR already queued:
dequeue FIRST (the GraphQL dequeuePullRequest mutation — `--disable-auto` does not
dequeue), then consult. A conformance report whose finding carries a non-NONE
`suggested-runtime-check` → continue the `slice-breaker` via SendMessage with
that probe list (its worktree persists until you reap it; if already reaped,
the probe design goes to a fresh breaker dispatch) — the field exists so the
severity-direction check reaches a binary, and it must not die in the report.
The writer lane never blocks on review adjudication; a repair slice enters the
queue like any other packet, cut by the planner from the brain's ruling.
Release the lock when intake + routing are done.
