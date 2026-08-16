---
name: sprint-findings
description: The playbook for bugs and gaps discovered during a sprint — intake, the mechanical bug-reproducer phase (repro/pin/attribution bundle), the brain's two-question architectural ruling (in-sprint with adjustment sweep, or orthogonal placed as PLANNED-into-an-arc vs GAP-needing-closure) resolving to REPAIR / ABSORB / FILE / DEFER / DISMISS, the filing protocol, and the exit guarantee that every finding reaches a terminal state. Load when any report carries a finding, when a gate goes unexpectedly red or green, or at sprint close-out.
---

# Findings playbook

A finding is anything discovered that the sprint did not set out to produce: a
bug, a spec gap, a wrong ledger row, an unexpected gate flip, a "this looks
wrong" in passing. The playbook exists because findings are where sprints leak:
the audited sprints' worst outcomes were findings mishandled — a phantom drain
nearly closing five live bugs, an unreproduced claim filed as fact, evidence
surviving only as session-scratch prose. The lifecycle below is mechanical for
the orchestrator; every judgment inside it is a brain ruling.

## 1. Intake — every finding gets a row before anything else

Append to `.claude/sprint-<stage>/FINDINGS.md` immediately, one row:
`F<n> | <one-line claim> | source report path | status: OPEN`. No triage yet,
no severity yet, no dedup yet — the row exists so the finding cannot be lost
between its report and its ruling. A finding mentioned in conversation or a
return message but absent from a report file gets BOUNCED to its reporter
first (reports are the record; chat is not).

## 2. Mechanical phase — dispatch `bug-reproducer`; judgment waits for its bundle

The mechanical and architectural halves are deliberately SPLIT: repro, pin, and
attribution are fixture work (Sonnet), and spending brain judgment on them
muddies the ruling with shell mechanics. For any bug-shaped finding, dispatch
`bug-reproducer` with the FINDINGS row, the source report path, and both SHAs
(pinned base + slice head). Its bundle is: first-hand minimized repro,
base-vs-slice × channel attribution matrix, a pin fixture PROVEN to reproduce
(or a reasoned not-pinnable row), and a ready-to-file issue draft with no
severity and no interpretation. Paper-only findings (a conformance gap, a wrong
ledger row) skip the reproducer and go straight to ruling.

Orchestrator-side checks BEFORE dispatching (they need no agent):

- A new RED first checks the contract's expected-red block (HANDOFF.md) —
  a licensed red is not a finding; debugging one is a recorded time sink.
- ⚠️ **Quiescence before trusting any gate-derived finding** (a drain, a new
  red, a count): no measurement is valid while a writer holds uncommitted
  edits. Run it twice; two runs disagreeing means the tree is moving, not the
  suite. A non-quiescent must-fail run once reported 5 phantom DRAINS.
- ⚠️ **A differential is blind to what is in both arms**: "reproduces on base
  too" means PRE-EXISTING, not FINE. It changes the routing, never the truth
  of the finding.
- `NOT-REPRODUCED` from the reproducer is a conflicting-reports consult (the
  brain designs the third probe), never a quiet drop of the finding.

## 3. Ruling — two architectural questions, then a terminal route

Consult the brain with the FINDINGS row + the reproducer's bundle. The ruling
answers TWO questions in order, and lands in DECISIONS.md:

### Q1 — in-sprint, or orthogonal?

**In-sprint** means it interacts with the sprint's one question: a slice caused
it, it blocks or falsifies a queued slice's premise, it lives in the sites the
sprint is transforming, or it contradicts a ruling the sprint rests on.
**Orthogonal** means none of those — however severe. Severity does not make a
bug in-sprint; interaction does (an orthogonal S0 is filed as an S0, urgently —
it still is not this sprint's work unless Val re-scopes).

**If IN-SPRINT, the ruling MUST include the adjustment sweep** — naming what
the bug changes, not just that it gets fixed:

- Which queued packets' §4 facts does it falsify? (Planner re-cuts them — a
  premise that fell in one place usually has siblings in others.)
- Which DAG leaves reorder or re-cut? Does the contract's slice table change?
- Does any LANDED slice rest on the now-false premise? (→ re-review, possibly
  a repair slice against merged work.)
- Does a DECISIONS.md ruling need amending? (Amend by new entry, never edit.)

Terminal route for in-sprint: **REPAIR** (slice-caused, blocks that PR's
ARMING — never the writer lane; planner cuts the repair slice at the front of
the queue) or **ABSORB** (pre-existing but it advances the sprint's question
and fits the size budget — the brain must say WHY; absorb-by-default is how
sprints sprawl). S0/S1 slice-caused is always REPAIR, and the direction rule
applies: a slice that made an existing defect QUIETER (loud crash → wrong
answer at exit 0) is a severity increase and repairs, even though "the crash
is gone."

### Q2 — for ORTHOGONAL findings: does it have an architectural home?

- **PLANNED** — the bug's class is already owned by an arc/spec (a
  `docs/spec/*` section, a `*-TARGET-ARCHITECTURE.md` arc, a standing ruling
  that names this mechanism). The issue is filed INTO that plan: it cites the
  owning doc/arc, and the arc gets a BACK-reference to the issue — citations
  must be bidirectional; a one-directional citation is how two arcs came to
  own the same work without either knowing (B-2.4/X-E.C).
- **GAP** — no governing text owns this bug class (the conformance reviewer's
  `UNGOVERNED` class lands here). Then the finding is TWO deliverables: the
  bug issue, AND a gap-closure item — a named addition to a spec/arc, or a
  decision point for Val when it would move formal semantics (that boundary is
  the brain's standing VAL escalation). Silent wrongness lives where no text
  governs; filing the bug without closing the gap re-ships the next instance.

Terminal route for orthogonal: **FILE** (this session — annotate the row
`FILE(planned: <arc>)` or `FILE(gap: <closure action>)`) or **DEFER** (real,
deliberately sequenced after the sprint, recorded with a CHECKABLE trigger
condition — a fired trigger is otherwise indistinguishable from a waiting one).

**DISMISS** remains available at either stage: not a real finding, recorded
WITH the disproving derivation — debunking needs the same proof as filing;
"seems fine" dismisses nothing.

## 4. Filing protocol — when the ruling is FILE

Mechanical, in order; the orchestrator executes from the reproducer's bundle,
the brain has already ruled:

1. **The first-hand repro requirement is satisfied by the reproducer's bundle**
   — it ran fresh, independently of the reporting agent. A finding with no
   bundle (paper-only findings excepted) does not get filed; there are no
   exceptions, and the orchestrator's own inferences are not exempt (both
   failure directions are on record).
2. **Dedupe against the tracker**: `gh issue list --search "<key symbols>"`
   plus a search for the mechanism, not just the symptom — the same bug class
   often has an open sibling under different words. A hit → comment the new
   evidence on the existing issue instead of filing. For a PLANNED finding,
   also grep the owning arc — its ledger may already row this bug.
3. **File the reproducer's draft verbatim**, adding only what the ruling
   supplies: the severity **LABEL** (`S0: silent wrongness`, ... — the tracker
   is queried by label; prose titles are not filed anywhere) and, for PLANNED,
   the owning arc/spec citation. **No closing keywords anywhere in the body** —
   "do NOT close #N" has closed #N; reference issues as `see issue N` in prose.
4. **Land the pin** (already authored and proven by the reproducer): rename to
   `test/must_fail_fixtures/<N>-slug/` with the real issue number and commit it
   with the filing PR. Not-pinnable → the reproducer's drafted
   `test/MUST-FAIL-NOT-PINNABLE.txt` row lands instead.
5. **Close the citation loop**: PLANNED → add the back-reference to the owning
   arc/spec doc (bidirectional, per the ruling); GAP → execute the gap-closure
   action the ruling named (spec/arc addition, or the VAL decision point) and
   record where it landed in the FINDINGS row.
6. **Verify every write by readback** — `gh issue view <n> --json labels,title,body`;
   gh write paths silently no-op here.

## 5. Special cases

- **A pin DRAINS mid-sprint** (must-fail flips green): quiescence check first
  (§2), run twice. Real drain → brain rules close-vs-re-point; prefer
  RE-POINTING at a regression gate over deleting (a drained fixture is not a
  drained class — a sibling one constructor over stayed live), and check the
  fixture's shape was the mechanism's ONLY trigger before believing the fix is
  whole. The close itself checks the PIN, not the sprint's narrative.
- **A finding in `Not covered`** is not a bug report — it is unexamined
  territory. It accumulates in FINDINGS.md as input to the repair round, not
  as an OPEN finding needing a ruling now.
- **Spike discoveries**: a spike that unearths a live bug reports it as a
  finding like anyone else — the spike's throwaway diff is not a fix and must
  still end byte-identical.
- **Repair-round findings** at sprint end follow the same lifecycle, with one
  tightening: REPAIR rulings there block the SPRINT's exit, not just a PR.

## 6. The exit guarantee

At sprint close-out (before `orchestrator-wrapup`), the verifier sweeps
FINDINGS.md: **every row is terminal** — REPAIR→fixed-and-reviewed,
ABSORB→landed, FILE→issue number + pin path + (planned: arc back-reference
exists | gap: closure action landed), DEFER→trigger condition recorded,
DISMISS→derivation recorded. An OPEN row blocks exit. This sweep is mechanical
(status column non-OPEN + the named artifact exists) — which is exactly why it
works: the recorded failure was owed desk-closes that everyone believed done
and nobody had executed.
