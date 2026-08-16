---
name: slice-landed
description: The FRONT seat's fixed sequence for the moment an implementer returns — report intake, refill the writer lane, merge the slice into the sprint branch (golden re-cut rule), one handoff message to the sprint-rear seat, dispatch the planner, then bookkeeping. Run on EVERY implementer return (landed, refused, or blocked; slice or family leaf). Order is load-bearing.
---

# Slice landed — the front-seat completion sequence

Run this the moment any implementer returns. The order exists because the
measured sprint bottleneck was the orchestrator doing bookkeeping serially with
ZERO writers live (0.73× parallel efficiency; 33 of 122 minutes dead): everything
that refills or feeds the writer lane happens BEFORE anything that merely
records. In v3 the sequence is also SHORT by design — everything downstream of
the sprint-branch merge (push, PR, CI, reviewers, findings) belongs to the
`sprint-rear` seat and leaves your critical path in one message. Do not
reorder, do not interleave, do not "just quickly" verify something between
steps 1 and 2.

## Step 0 — report intake (always, for every verdict)

0. **Take the lock:** create `SEQUENCE.lock` in the sprint dir. The heartbeat
   takes no dispatch/merge action while it exists; remove it as this sequence's
   final act. (A heartbeat tick finding a lock older than ~30 min escalates to
   the brain rather than deleting it.)
1. The report file exists at the packet's named path under
   `/var/tmp/medaka-sprints/<stage>/reports/`. If the agent wrote in-worktree
   anyway, copy it out NOW — the worktree can be reclaimed, and a return
   message is a summary, not an artifact.
2. All six §9 sections present ("Verdict" / "Evidence" / "Decisions surfaced" /
   "Deviations from packet" / "Not covered" / "Friction"), each non-absent
   (`NONE` valid). Missing any → BOUNCE via SendMessage; do not proceed on a
   bounced report; do not fill the gap.
3. Read ONLY the "Verdict" line to branch below. You are not the report's
   evaluator — its content routes in step 5.

## Verdict = LANDED

**1. Refill the writer lane.** Take the next packet from QUEUE.md and:
- **Completeness scan** (mechanical presence check): every §0–§9 section
  present, §4 facts each carrying a command, §1 carrying pinned sprint-branch
  SHA + worktree path + form + classification. Missing anything → BOUNCE to the
  planner, take the next independent packet instead.
- **Create the worktree** at the CURRENT sprint-branch head (after this
  sequence's step 2 merge if you can cheaply wait one step — otherwise at the
  pre-merge head; the packet's §1 drift check covers the gap):
  `git worktree add <path> <sprint-branch head SHA>`. Record the SHA in the
  dispatch brief alongside the packet's pinned SHA. Worktree creation is
  YOURS — no agent creates its own.
- **Dispatch** — one-line brief ("Execute packet <path> under the sprint-packet
  contract; your tree is at <head SHA>, packet pinned <SHA>"), model read off
  §1: `parity` → Sonnet; `behavior-changing` (incl. every spike and
  unstable-DAG slice) → `model: opus`.
If no packet is queued, that is a runway failure: note it in QUEUE.md and make
step 4 a blocking priority.

**2. Merge into the sprint branch — the handoff token.** Merge the slice branch
into `sprint/<stage>` locally. Then the ONE non-mechanical-looking check, done
mechanically:
- **Golden rule:** if the merge touched any golden/snapshot family
  (`test/selfproc_goldens/`, `test/snapshots/`, `*.golden`) from BOTH sides,
  never accept git's clean auto-merge — a blend has no conflict marker and no
  gate can see it (3 recorded incidents in one session). Reset those paths to
  the pre-merge sprint-branch version and RE-DERIVE from the merged head
  (`sh test/capture_goldens.sh --frozen selfproc_legA`; the snapshot gate's
  `--bless <path>` by name), building the merged head first if needed — or
  dispatch `sprint-verifier` with that exact command checklist. Read the diff:
  legA moves must be additive-only. One side moved, other side didn't →
  auto-merge is fine.
- A merge CONFLICT in source files → brain (sequencing ruling), never
  hand-resolved at this seat.

**3. Hand off to the rear seat — one message:**
`landed: <slice handle>, sprint-branch head <sha>, report <path>, packet <path>`
(+ the breaker worktree path if you pre-created it). The rear seat pushes,
updates the sprint PR, and dispatches both reviewers. Expect an acknowledgment
by the next heartbeat tick; you do NOT wait for it now.

**4. Dispatch `sprint-planner`** for slice N+2's packet: the contract section or
ruling to plan, the just-landed report's path (it must read "Deviations" and
"Decisions surfaced" before writing — feed-forward is its rule), and the NEW
sprint-branch head as the pin.

**5. Bookkeeping — only now, while all of the above runs:**
- Route the report mechanically: `Decisions surfaced` ≠ NONE or `Deviations from
  packet` ≠ NONE → brain consult (question + rule + file path — never a
  paraphrase). "Not covered" → OPEN-QUESTIONS.md verbatim. "Friction" →
  FRICTION.md verbatim. Any bug/gap anywhere in the report → forward the row to
  the REAR seat (FINDINGS.md is its file) in the same handoff thread.
- DEBT row present with all five §6 fields non-blank (presence check only).
- Append dispatch-log entries to DECISIONS.md; update QUEUE.md's lane table
  (old lane closed, new lane opened with its worktree + region).
- **Release the lock** — last act of the sequence.

## Verdict = `LANDED leaf <id> (<k>/<n>)` — family leaf, not final

Finality is read off the Verdict line alone (`LANDED family-final` takes the
full sequence). Mid-family leaf, lighter path: intake the leaf's report block
(step 0); if the packet licenses per-leaf merging, run step 2 + the rear-seat
handoff for the leaf (CI runs while later leaves execute); then **continue the
SAME implementer via SendMessage** ("leaf <next-id> next"). Leaf "Decisions
surfaced" / "Deviations" still route to the brain immediately. Release the lock
after each leaf intake.

## Verdict = REFUSED or BLOCKED

A refused slice is landed work — same energy, and the lane's refill never waits
on adjudication:

1. **Refill the lane in parallel** with an INDEPENDENT queued packet if one
   exists. Independence is mechanical: `depends-on` does not name the refused
   slice, AND §1's collision matrix records zero intersection with it, AND no
   §4 fact cites its handle. Any check fails or is ambiguous → dependent. If
   nothing qualifies, the lane legitimately idles — record why in DECISIONS.md.
2. **Brain consult, immediately:** refusal report path + packet path + the rule
   ("any refusal"). The brain's default is believe-and-re-cut.
3. **Execute the brain's Actions verbatim** — typically: planner revises the
   packet folding the measurement into §4; the re-cut enters the queue front.
4. Bookkeeping as in step 5. The refused packet is retained — it is evidence.
   Nothing merges to the sprint branch; no rear-seat handoff.

## Reviewer / fixer returns

These arrive at the REAR seat in v3 — it runs the same step-0 intake and the
`sprint-findings` lifecycle, consulting the brain through you as a verbatim
relay. The only reviewer-driven action at YOUR seat: a brain REPAIR ruling that
resequences the queue (you re-order QUEUE.md), a fixer-lane request (you run
`scripts/sprint-disjoint.sh` against every live lane and grant or queue it), and
an S0-class finding (record its heavy-round adversarial-review obligation in
DECISIONS.md — it blocks the terminal enqueue, never the writer lane).
