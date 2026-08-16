---
name: sprint-findings
description: The playbook for bugs and gaps discovered during a sprint — intake, attribution, the brain's five terminal rulings (REPAIR / ABSORB / FILE / DEFER / DISMISS), the filing and pinning protocol, and the exit guarantee that every finding reaches a terminal state. Load when any reviewer/implementer/spike report carries a finding, when a gate goes unexpectedly red or green, or at sprint close-out.
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

## 2. Attribution — slice-caused or pre-existing? Evidence, not vibes

The single most consequential fact about a finding, and it is measurable:
**does it reproduce on the pinned base?**

- `slice-breaker` reports carry a `base-arm:` field — if it says `ran`, use it.
- If not run: the brain designs the exact probe; a `sprint-verifier` (or the
  breaker, continued) executes it against BOTH the base binary and the slice
  binary. Two rebuilds spent on attribution is the right call — a reviewer once
  retracted 14 "findings" after the base arm reversed the direction.
- ⚠️ **A differential is blind to what is in both arms**: "reproduces on base
  too" means PRE-EXISTING, not FINE. It changes the routing, never the truth of
  the finding.
- ⚠️ **Quiescence before trusting any gate-derived finding** (a drain, a new
  red, a count): no measurement is valid while a writer holds uncommitted
  edits. Run it twice; two runs disagreeing means the tree is moving, not the
  suite. A non-quiescent must-fail run once reported 5 phantom DRAINS.
- A new RED first checks the contract's expected-red block (HANDOFF.md) —
  a licensed red is not a finding; debugging one is a recorded time sink.

## 3. Ruling — the brain assigns exactly one of five terminal routes

Consult the brain with the FINDINGS row + report path + attribution evidence.
Its ruling lands in DECISIONS.md and sets the row's status:

| Ruling | When | What happens |
|---|---|---|
| **REPAIR** | Slice-caused, and severity or spec-conformance demands an in-sprint fix | Blocks ARMING of that slice's PR (never the writer lane); planner cuts a repair slice at the front of the queue |
| **ABSORB** | Pre-existing, but it advances the sprint's one question and fits the size budget | Becomes a normal slice: planner packets it, it enters the queue. The brain must say WHY it belongs — absorb-by-default is how sprints sprawl |
| **FILE** | Real, but not this sprint's work | The filing protocol below, THIS session — "file later" rows are how owed desk-closes went stale |
| **DEFER** | Real, in scope, but sequenced after the sprint deliberately | Recorded with its trigger condition — a deferred note whose trigger has fired is indistinguishable from one still waiting, so name the condition checkably |
| **DISMISS** | Not a real finding | Recorded WITH the disproving derivation — debunking needs the same proof as filing; "seems fine" dismisses nothing |

**Severity calibration for REPAIR-vs-FILE:** S0 (wrong answer/destroyed source,
no error) and S1 slice-caused regressions are always REPAIR. And the direction
rule: a slice that made an existing defect QUIETER (loud crash → wrong answer
at exit 0) is a severity INCREASE and repairs, even though "the crash is gone."

## 4. Filing protocol — when the ruling is FILE

Mechanical, in order; the orchestrator executes, the brain has already ruled:

1. **Reproduce first-hand before filing.** An agent's claim — however good the
   report — is not reproduced until someone runs it fresh against the pinned
   base. This rule has no exceptions and the orchestrator's own inferences are
   not exempt (both failure directions are on record). If it does not
   reproduce, back to the brain — that is a new conflicting-reports consult.
2. **Dedupe against the tracker**: `gh issue list --search "<key symbols>"`
   plus a search for the mechanism, not just the symptom — the same bug class
   often has an open sibling under different words. A hit → comment the new
   evidence on the existing issue instead of filing.
3. **File with:** the repro (exact commands + program, committed or quoted in
   full — never a path into session scratch), the expected-vs-got with the
   expected value's derivation, the attribution evidence, and the sprint/
   report provenance. **Severity is a LABEL** (`S0: silent wrongness`, ...) —
   the tracker is queried by label; prose titles are not filed anywhere.
   **No closing keywords anywhere in the body** — "do NOT close #N" has closed
   #N; reference issues as `see issue N` in prose.
4. **Pin it**: an open bug gets a self-draining fixture in
   `test/must_fail_fixtures/<N>-slug/` (see the `bug-hunt` skill for the
   harness mechanics) so the tracker self-drains when a fix lands. Not
   pinnable → a `test/MUST-FAIL-NOT-PINNABLE.txt` row with the reason. A pin
   asserts the bug REPRODUCES — run the fixture before committing it; a
   malformed pin reports "drained" and lies.
5. **Verify the write by readback** — `gh issue view <n> --json labels,title,body`;
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
ABSORB→landed, FILE→issue number + pin path, DEFER→trigger condition recorded,
DISMISS→derivation recorded. An OPEN row blocks exit. This sweep is mechanical
(status column non-OPEN + the named artifact exists) — which is exactly why it
works: the recorded failure was owed desk-closes that everyone believed done
and nobody had executed.
