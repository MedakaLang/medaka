---
name: slice-landed
description: The FRONT seat's fixed sequence for the moment an implementer returns — report intake, merge into the sprint branch (golden rule), refill the writer lane from the merged head, one handoff message to the sprint-rear seat, dispatch the planner, then bookkeeping. Run on EVERY implementer return (landed, refused, blocked, spike, fixer, or family leaf). Order is load-bearing.
---

# Slice landed — the front-seat completion sequence

Run this the moment any implementer (slice, spike, family leaf, or fixer)
returns. The order exists because the measured sprint bottleneck was the
orchestrator doing bookkeeping serially with ZERO writers live (0.73× parallel
efficiency; 33 of 122 minutes dead): bookkeeping comes last. In v3 the merge
comes FIRST — before the lane refill — because the next worktree must be cut
from the MERGED head: a worktree cut pre-merge starts one slice behind the
sprint branch, which manufactures exactly the two-sided golden merge the golden
rule below exists to prevent. The merge is local and takes seconds; the
sequence stays short because everything downstream of it (push, PR, CI,
reviewers) leaves in one message to the `sprint-rear` seat. Do not reorder, do
not interleave.

**All merges happen in the LANDING WORKTREE** — the dedicated worktree holding
`sprint/<stage>`, created once at sprint start (see the `sprint-orchestrator`
skill). Never build in it; never merge anywhere else (a branch cannot be
checked out in two worktrees, so ad-hoc checkouts fail against sibling trees).

## Step 0 — report intake (always, for every verdict)

0. **Take the lock:** `touch /var/tmp/medaka-sprints/<stage>/SEQUENCE.lock`.
   The heartbeat takes no dispatch/merge action while it exists; `rm` it as
   this sequence's final act. (A tick finding a lock older than ~30 min —
   `find <dir>/SEQUENCE.lock -mmin +30` non-empty — escalates to the brain
   rather than deleting it.)
1. The report file exists at the packet's named path under
   `/var/tmp/medaka-sprints/<stage>/reports/`. If the agent wrote in-worktree
   anyway, copy it out NOW.
2. All six §9 sections present — check it mechanically:
   `sh scripts/sprint-report-check.sh <report path>` ("Verdict" / "Evidence" /
   "Decisions surfaced" / "Deviations from packet" / "Not covered" /
   "Friction"; `NONE` valid, absence not). Exit 1 → BOUNCE via SendMessage; do
   not proceed on a bounced report; do not fill the gap.
3. Read ONLY the "Verdict" line and branch on it — the closed vocabulary is:
   `LANDED` (below) · `LANDED leaf <id> (<k>/<n>) @<sha>` (family, mid) ·
   `LANDED family-final @<sha>` (family, last — full LANDED sequence) ·
   `FIX-LANDED` (fixer — light path below) · `SPIKE-DONE (stability: …)` ·
   `REFUSED` / `REFUSED leaf <id> (<k>/<n>)` · `BLOCKED`. Any other verdict
   string → bounce (closed vocabulary, packet §9).

## Verdict = LANDED (or `LANDED family-final @<sha>`)

**1. Merge into the sprint branch — the handoff token.** In the landing
worktree:
```sh
git -C <landing> fetch origin <slice-branch>
git -C <landing> merge --ff-only FETCH_HEAD     # sprint/<stage> is checked out here
```
**`--ff-only` is the default and it is a free detector (v5):** a branch cut
from the wrong base cannot merge quietly — git refuses, from an artifact
neither party authored. Wrong-base worktrees recurred at least three times in
one sprint and were caught only because the writer happened to check. Fall
back to `git merge --no-edit` (a true merge) ONLY after running the
golden-intersection check below first, and record that you did in the merge
log line.
(FETCH_HEAD is repo-global and clobbered by any sibling fetch — merge
immediately after fetching, or fetch into a pinned SHA first.) Then:
- **Fast-forward short-circuit:** if the merge fast-forwarded (single live
  lane — the common case; `git merge-base --is-ancestor <old sprint head>
  <slice head>` was true), there is only one line of development: the golden
  rule below is vacuous, skip it.
- **Golden rule (true merges only — ≥2 lanes):** determine "touched from both
  sides" mechanically:
  ```sh
  MB=$(git merge-base <old sprint head> <slice head>)
  comm -12 <(git diff --name-only $MB <old sprint head> | sort) \
           <(git diff --name-only $MB <slice head> | sort) \
    | grep -E 'test/selfproc_goldens/|test/snapshots/|\.golden$'
  ```
  Empty → the auto-merge stands. Non-empty → NEVER accept the auto-merge (a
  blend has no conflict marker and no gate can see it): reset those paths to
  `<old sprint head>`'s version, create a RE-CUT WORKTREE at the merged head,
  and dispatch `sprint-verifier` with the exact re-derivation checklist —
  build `make medaka`, **rebuild the legA oracles first** (`for o in
  check_all_main eval_modules_main eval_typed_modules_main; do FORCE=1 JOBS=1
  sh test/build_oracles.sh --build-one $o; done` — a stale oracle here
  BLESSES a wrong golden, permanently), then `sh test/capture_goldens.sh
  --frozen selfproc_legA` and the snapshot gate's `--bless <path>` per moved
  file, then report the diff (legA must be additive-only). Commit the re-cut
  on the sprint branch; the step-2 handoff WAITS for it (rare case;
  correctness beats latency here).
- **A merge conflict touching a golden** → `git -C <landing> merge --abort`,
  then treat as the non-empty case above: re-merge taking the pre-merge
  version of the golden paths (`git checkout --ours` on them), re-derive via
  the verifier checklist.
- **A merge conflict in source files** → `git -C <landing> merge --abort` →
  brain (sequencing ruling), never hand-resolved at this seat.

**2. Hand off to the rear seat — one message, fixed format:**
`landed: <slice handle> | head <merged sprint-branch SHA> | report <path> |
packet <path> | breaker-wt <path>` — where `breaker-wt` is a worktree YOU
create now at the merged head (`git worktree add <path> <sha>`); it is
MANDATORY in the message (an optional field here deadlocked the breaker
dispatch in review). The rear seat pushes exactly the named SHA, dispatches
both reviewers, and replies `ack:`. You do NOT wait for the reply; the
heartbeat's poke tick collects it.

**3. Refill the writer lane.** Take the next `status: queued` packet row from
QUEUE.md (row format: `<slice handle> | packet <path> | depends-on <handles|
NONE> | status: queued|dispatched|landed|refused`) and:
- **Completeness scan** (mechanical presence check): every §1–§9 section
  present, §4 facts each carrying a command, §1 carrying pinned SHA + branch +
  worktree path + form + classification. Missing anything → BOUNCE to the
  planner, take the next independent packet instead.
- **Create the worktree** at the sprint branch's CURRENT (merged) head:
  `git worktree add <path under the record dir> <merged head SHA>`. Record
  both SHAs in the dispatch brief. Worktree creation is YOURS — no agent
  creates its own. (Reviewer and reproducer worktrees work the same way; a
  writer dispatched with `isolation: "worktree"` may land in a
  harness-created tree instead, which is fine and is why the packet no longer
  names a path — see the pre-dispatch checklist.)
- **Pre-dispatch checklist — three mechanical assertions, no judgment (v5):**
  1. `isolation: "worktree"` is set **on the Agent tool call**, not merely
     described in the prompt. Measured: the FIRST implementer dispatch of
     `sprint/ctor-identity` omitted it, ran in the front seat's own inherited
     worktree, switched that worktree's branch out from under the seat, and an
     observed uncommitted `typecheck.mdk` edit vanished; recovery cost three
     rulings and a four-dispatch positive-control programme. Packet prose does
     NOT substitute for the flag.
  2. The brief names **the front-seat repo path** as a tree the agent must NOT
     be in, and requires as its first act: `git rev-parse --show-toplevel`,
     `git rev-parse HEAD`, and
     `git merge-base --is-ancestor <merged head SHA> HEAD && echo BASE-OK` —
     all three reported in Evidence. `isolation:"worktree"` can mint a tree
     from `main` rather than the sprint branch, and `git rev-parse HEAD` looks
     perfectly healthy when it does.
  3. Merges are `--ff-only` (step 1). Self-correcting a wrong base is licensed
     ONLY when all of: verified with `merge-base` (not assumed), flagged in
     the report, correct base reachable in the same tree. Missing any one is
     indistinguishable from a wrong-base landing → BLOCKED → brain.
- **Dispatch** — brief: "Execute packet <path> under the sprint-packet
  contract; sprint head <merged head SHA>; packet pinned <§1 SHA>; front-seat
  repo (do NOT work here) <path>." Model read off §1: `parity` → Sonnet;
  `behavior-changing` (incl. every spike and unstable-DAG slice) →
  `model: opus`. Update the QUEUE.md row to `dispatched`.
If no packet is queued, that is a runway failure: note it in QUEUE.md and make
step 4 a blocking priority.

**4. Dispatch `sprint-planner`** for slice N+2's packet: the contract section
or ruling to plan, the just-landed report's path (it must read "Deviations"
and "Decisions surfaced" before writing — feed-forward is its rule), and the
NEW merged head as the pin. On its return: `PACKET-READY` → append the
QUEUE.md row; `SPIKE-NEEDED` → dispatch the spike per the orchestrator
skill's slice-forms handling; `BLOCKED` → brain consult.

**5. Bookkeeping — only now, while all of the above runs:**
- Route the report mechanically: "Decisions surfaced" ≠ NONE or "Deviations
  from packet" ≠ NONE → brain consult. "Not covered" → OPEN-QUESTIONS.md
  verbatim. "Friction" → FRICTION.md verbatim. Any bug/gap anywhere →
  `finding: <one-line claim> | report <path>` message to the REAR seat
  (FINDINGS.md is its file; it appends the row on receipt — the front seat
  never writes FINDINGS.md).
- DEBT row present with all five §6 fields non-blank (presence check only).
- Append dispatch-log entries to DECISIONS.md; update QUEUE.md's lane table
  (lane row format: `<occupant handle> | worktree <path> | region <file-set
  summary> | evidence <disjoint-run id|SOLE>`; close the old row, open the
  new).
- **Release the lock** — last act.

## Verdict = FIX-LANDED — fixer return, light path

A fixer is a writer dispatched by YOU on a brain REPAIR ruling (branch
`fix/<finding-slug>`, cut from the sprint head at lane grant). On return: step
0 intake → **step 1 merge** (same golden rule) → handoff to the rear seat as
`landed-fix: <finding handle> | head <sha> | report <path>` (rear pushes and
updates the FINDINGS row; NO reviewer dispatch — the heavy round reviews
fixes — unless the REPAIR ruling's Actions said otherwise) → close the fixer's
lane row → bookkeeping, **including the fixer's five-field DEBT.md row** (one
row per landing, fixes included — with no fix packet it is the only structured
record of the fix's residual risk) **and closing the ruling's OBLIGATIONS.md
rows with their evidence**. No planner dispatch, no lane refill (the fix lane
was extra).

## Verdict = `LANDED leaf <id> (<k>/<n>) @<sha>` — family leaf, not final

Lighter path: intake the leaf's report block (step 0); if the packet licenses
per-leaf merging (the family packet's §6 must say `per-leaf-merge: yes|no` —
planner's call at cut time), run step 1 on the leaf's `@<sha>` and send the
rear seat `landed-leaf: <family handle> leaf <id> | head <sha>` (rear PUSHES
only — no reviewer dispatch; reviewers fire once, at family-final). Then
**continue the SAME implementer via SendMessage** ("leaf <next-id> next").
Leaf "Decisions surfaced" / "Deviations" still route to the brain immediately;
leaf findings forward as `finding:` messages. No planner dispatch mid-family.
Release the lock after each leaf intake.

## Verdict = `SPIKE-DONE (stability: STABLE | UNSTABLE)`

No merge, no handoff — a spike ships knowledge, never code. BEFORE reaping its
worktree: `git -C <spike-wt> diff --stat` and `git -C <spike-wt> status
--short` both print nothing (the report's Evidence must carry the same
outputs); a spike that shipped code bounces. Then route on the stability word
alone: STABLE → dispatch the planner to cut the family packet (leaf DAG from
the spike report); UNSTABLE → dispatch the planner to cut ONE standard
`behavior-changing` slice. Refill the lane meanwhile with an independent
queued packet if one exists (independence test below). Bookkeeping; release
the lock.

## Verdict = REFUSED, `REFUSED leaf <id> (<k>/<n>)`, or BLOCKED

A refused slice is landed work — same energy, and the lane's refill never
waits on adjudication:

1. **Refill the lane in parallel** with an INDEPENDENT queued packet if one
   exists. Independence is mechanical: its QUEUE.md `depends-on` does not name
   the refused slice, AND its §1 collision matrix records zero intersection
   with it, AND no §4 fact cites its handle. Any check fails or is ambiguous →
   dependent. If nothing qualifies, the lane legitimately idles — record why
   in DECISIONS.md.
2. **Branch by verdict:**
   - `REFUSED` → brain consult immediately (report + packet paths + the rule
     "any refusal"; default is believe-and-re-cut). Execute its Actions
     verbatim — typically the planner revises the packet, re-cut enters the
     queue front. Nothing merges; the branch is retained as evidence.
   - `REFUSED leaf …` → the landed leaves STAY merged (their green boundaries
     are the design); the family PAUSES (do not send "leaf next"). Brain
     consult; typically the planner revises only the REMAINING leaves and the
     SAME implementer is continued on the revised DAG.
   - `BLOCKED` → a packet defect (missing section, unreadable path, premise
     it could not evaluate): BOUNCE the packet to the planner with the report;
     brain consult only if the blockage names a judgment question.
3. Bookkeeping as above. Findings in the report still forward to the rear
   seat as `finding:` messages (the refusal path skips the merge handoff, not
   findings intake — refusals are the highest-yield finding source on
   record). **Also send `refusal: <raised-by> | <claim> | report <path>`** —
   one per refusal, stop-and-report, declined out-of-band instruction, or
   falsified premise, whichever verdict the report carried, so the signal is
   COUNTABLE. The rear seat carries the row to its verdict once the brain
   rules.

## Reviewer returns

Reviewers return to the REAR seat (it dispatched them); it runs intake and
the `sprint-findings` lifecycle there. The only reviewer-driven actions at
YOUR seat, each arriving as a rear-seat reply or a brain ruling: a REPAIR
ruling → you dispatch the fixer directly from the ruling + repro bundle (v4 —
no fix packet; the sprint-packet Fix form defines the brief), lane grant (run
`scripts/sprint-disjoint.sh` YOURSELF at grant time, PAIRWISE against each
live lane row, under the staleness rules in the orchestrator skill's "Parallel
writers" section — a stamped head ≠ current sprint head is INVALID, and an
exit 1 naming only lanes absent from the live lane table is re-run, not a
brain consult), fixer dispatch on branch
`fix/<finding-slug>`; a queue resequencing → re-order QUEUE.md; an S0-class
finding → record its heavy-round adversarial-review obligation in
DECISIONS.md (blocks the terminal enqueue, never the writer lane).
