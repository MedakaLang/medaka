# Stage A sprint — run doc

**Status:** planning artifact for a single long-running orchestration session.
**Premise:** implement the whole of Stage A's residue on one branch, in one worktree, with
verification deliberately deferred to a testing round that runs *after* implementation.
**This document is the contract.** Every agent in the fleet reads it before acting.

> ⚠️ **This run trades verification latency for implementation throughput. That trade is only
> safe because the debt is WRITTEN DOWN.** An agent that skips a `DEBT.md` row has not saved
> time — it has converted a deferred check into a check nobody will ever know to make. The
> ledgers are the deliverable that makes the testing round possible; the diff alone is not.

---

## 1. Scope

Derived 2026-08-12 from the tracker, not from the epic's table (which the 2026-08-09 amendment
already re-cut once). Re-derive before starting — issue state moves.

### In scope

| Group | Nodes | Notes |
|---|---|---|
| A-3a tail | #1512 (A-3.2b, slices in flight), #1593 | #1593 is "the rows A-3.2b left" — same territory, pair them |
| A-3b chain | A-3.4, #1557 (A-3.5), #1558 (A-3.6), #1559 (A-3.7) | **Strictly serial.** A-3.4 has no issue — it lives only in #1112's decomposition table |
| A-2 namespace follow-ons | #1354 (owns #1276, #1351), #1319 | Both need a unit split before implementation |
| Storage residual | #991 | Bundled with #1446, which closed without it — confirm still live |
| Epic shells | #1111, #1112 | No work of their own; close by their children |

**A-2's spine is already done** — A-1 (#1110) and the A-2 tail atom (#1446) are both closed.
What remains under A-2 is follow-on work, not spine.

### Out of scope (ruled 2026-08-12)

- **#1425** and **#1337** — off-spine by the epic's own 2026-08-09 amendment, which placed them
  adjacent to B-3 and recorded that values do not gate A-3. #1337 is additionally a shell
  pending a retire-vs-re-scope adjudication. Both are the most ambiguous nodes in the residue,
  and this run's premise requires pre-cut, mechanical bites.
- Everything in Stages B, C, D, E.

### Issue-closure policy

**The run implements S0/S1-draining work. It does not close it.** #1276 and #1351 (under #1354)
stay open through the sprint. Their must-fail pins will flip red as the fixes land — *that red is
a deliverable*, not a break, and it is the testing round's attack list. Closure requires the
adversarial review gate that every soundness fix in this repo gets, which happens after.

---

## 2. Phases

Each phase gate is a hard stop. No phase starts before its predecessor's deliverable exists.

### Phase 0 — design fan-out (parallel, read-only)

The critical path of this whole run. Nothing is implementable until it lands, because
**A-3.5/3.6/3.7's scopes are currently stubs** — #1557 records verbatim that scope beyond
"decl-time checks relocated, coherence excluded" "is not established," and was filed for an
implementer to derive against `compiler/TYPECHECK-TARGET-ARCHITECTURE.md`.

~5 Opus arch agents, one per unit, plus one Fable consult. All read-only, so zero merge risk —
this is the only genuinely parallel *work* in the sprint.

Deliverables, all written into `.claude/sprint/DECISIONS.md`:

- Bite-level decomposition for A-3.4, A-3.5, A-3.6, A-3.7, #1593 — see §4 for what a bite is.
- Unit splits for #1354 and #1319.
- Confirmation of #991's live status and of the #1111/#1112 shell status.
- **Fable's single question:** does this cut still deliver A-3's headline C4/I2-by-construction
  claim? Per the epic, that claim rides entirely on A-3b. This is the one broad,
  formal-semantics-scale question in the run and the only thing Fable is spent on.

**Gate:** every in-scope unit has a written bite list, or it is deferred out of the sprint.

### Phase 1 — A-3a tail

#1512's remaining slices, then #1593.

### Phase 2 — the A-3b chain

A-3.4 → A-3.5 → A-3.6 → A-3.7. Serial, per the ratified edge `{3.2,3.3,3.4} → 3.5` with
3.6 and 3.7 following. Parallelism lives *inside* each unit (§4), never across them.

### Phase 3 — namespace follow-ons

#1354 (M-1/M-2 per its adopted split), then #1319.

### Between every unit — the integration checkpoint

Backgrounded `sh test/preflight.sh` plus `sh test/selfcompile_fixpoint.sh`. This is the only
real signal the run gets, since nothing reaches CI until the end. It bounds bisect blast radius
to one unit; without it, a silent widening discovered at A-3.7 is unbisectable across the whole
stage.

⚠️ Run it detached and poll. Preflight forces the fixpoint on backend-adjacent diffs and can
exceed the 10-minute foreground tool ceiling — a kill at 600s with exit 143 is the ceiling, not
a hang.

---

## 3. Agent architecture

| Role | Model | Count | Charter |
|---|---|---|---|
| Run orchestrator | Opus | 1 | Owns the trunk worktree, the phase gates, and the checkpoints. Integration is mechanical scheduling — not a Fable job. |
| Unit sub-orchestrator | Opus | 1 live at a time | Owns one unit. Cuts bites from the Phase 0 decomposition, dispatches implementers, commits their work, batch-builds. |
| Architecture companion | Opus | 1 per live sub-orchestrator | Answers the questions that would otherwise pull the sub-orchestrator off coordination. Writes every ruling to `DECISIONS.md`. |
| Implementer | Sonnet | 3–5 concurrent | Executes one bite. See §4. |
| Referee | Sonnet | 1 | See §6. |
| Fable consult | Fable | 1, Phase 0 only | The C4/I2 question. Nothing else. |

**Why Opus at the top:** the standing calibration reserves Fable for questions that are broad,
refactor-scale, or move the formal semantics. In this run that is exactly one question, asked
once, in Phase 0.

---

## 4. The bite protocol

**A bite is a transformation over named sites.** If it cannot be stated as *"apply this
transformation to these N named sites"*, it is not a bite: it goes back to the architecture
companion to be cut further, or it is done by the sub-orchestrator itself. This test is the
whole reason Sonnet can be trusted inside a 27,810-line `compiler/types/typecheck.mdk`.

An implementer's deliverable is **the edit plus a `DEBT.md` row**:

```
### <bite id> — <unit> — <one-line description>
sites:      <the files:lines actually touched>
transform:  <what was applied>
could move: <what acceptance behavior could plausibly have changed, incl. "nothing — pure rename">
unchecked:  <what I did not verify, and why>
```

**`could move:` may not be left blank.** "Nothing, and here is why" is a valid entry; silence is
not. This field is what the testing round reads.

### Region discipline

All implementers work **in the trunk worktree**, on disjoint named regions. There are no
per-implementer worktrees and there is no merging — divergent history is never created, so a
conflict cannot arise. The worst case is an edit failing to match, which is loud and retriable.

🚨 **An implementer whose region has already changed under it STOPS and reports.** It does not
adapt. Adapting is how two agents' edits become a plausible blend that no gate can see — the
same failure that produced three silently blended golden re-cuts in one session, arriving here
with no conflict marker and no red gate.

**The sub-orchestrator is the single writer of history.** Implementers edit; the sub-orchestrator
commits, one commit per bite. `DECISIONS.md` and `DEBT.md` are likewise single-writer (the
sub-orchestrator appends), so the ledgers never contend.

---

## 5. Verification posture

### Runs, always

After roughly every 3 landed bites, the sub-orchestrator batch-builds:

```sh
make -C <trunk worktree absolute path> medaka && make -C <trunk worktree absolute path> check-self
```

Batching is the point: the build is the expensive step and the box has ~12 cores, so build slots
— not agent count — bound throughput. A break still localizes, because bites are small and
disjoint and `check-self` names the site.

This is not run for correctness. It is run because **every downstream implementer inherits this
base**, and a tree that does not self-typecheck makes all subsequent work unverifiable and
unbisectable.

### Deferred to the testing round

Goldens, snapshots, the selfproc LEG A schemes, differential gates, engines, must-fail, the
capability matrix, doc gates.

🚨 **Bless zero goldens for the entire run.** Mid-run blessing enshrines intermediate states and
produces N conflicting re-cuts of the same file. Goldens are re-cut **once**, from the final
binary, in the testing round — never merged, never hand-resolved.

---

## 6. Communications

**Chatter is a structural problem, not a discipline problem.** Agents re-ask each other because
there is no write-once shared artifact to consult. So:

- `.claude/sprint/DECISIONS.md` — append-only. Architecture companions write; everyone reads
  **before** asking. Every entry carries its derivation, not just its conclusion.
- `.claude/sprint/DEBT.md` — append-only, one row per bite (§4).
- Direct fleet messaging is for things the ledgers cannot carry: a decision that invalidates
  work already in flight, or a blocked unit.

### Referee charter

One Sonnet agent, with real authority:

1. **Keeps the ledgers honest.** An entry that states a fact without a derivation gets bounced.
   This tree has a long history of ledger prose that was ungated and wrong.
2. **Cuts cross-talk.** Tells agents when an exchange has stopped serving the task.
3. **Enforces the bite protocol.** No bite lands without a `could move:` row.
4. **Forces escalation.** May stop a sub-orchestrator and rule that a question is architectural,
   sending it to the companion rather than letting it be improvised into a bite.

---

## 7. Operational traps

These will each eat repeated agent turns if not handled up front.

- **The pre-commit hook fights every commit.** Compiler source moves snapshots, so the snapshot
  check trips on each one. Standing instruction: `PRECOMMIT_SNAPSHOT_DEFER=1 git commit …` —
  **not** `--no-verify`, which would also drop fmt, lint, and lextok.
- **Write the expected-red set into `.claude/HANDOFF.md` before starting.** Snapshot, selfproc
  LEG A, and must-fail are red for the duration *by design*. Otherwise an agent diagnoses the
  run's own deferred debt as a break.
- **`fmt --write` is mandatory** (the hook gates on it) and #829's record-comment corruption is
  live. Standing rule: **no interior record comments on a record whose header is still the
  two-line `data X =` / `| X {` form.** Check the shape before adding one; `PerRun` is currently
  the safe collapsed form, `DriverState` is not.
- **CI gives zero signal for days.** The per-unit checkpoint is the only signal. Do not compress
  it, and do not let agents poll a queue that has nothing in it.
- **Sole occupancy.** For the duration, no other session touches `compiler/types/typecheck.mdk`.
  Confirm no scheduled agents are pointed at this tree before Phase 0.
- **Absolute paths everywhere.** The shell cwd resets between calls, so a relative path edits the
  main checkout, which the trunk build never sees.

---

## 8. Exit criteria

The sprint is done when every in-scope node's bites are landed and the tree builds and
self-typechecks. It is **not** done in any other sense — that is the design.

Handoff to the testing round is: the branch, `DEBT.md`, `DECISIONS.md`, and the set of must-fail
pins that flipped red. The testing round's first job is to work `DEBT.md`'s `could move:` column,
because the gate suite is structurally blind to this run's characteristic failure — a silently
widened acceptance. Value goldens cannot see a diagnostic-only change, and absence probes cannot
see an undercount.
