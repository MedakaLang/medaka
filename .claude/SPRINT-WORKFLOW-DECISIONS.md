# Sprint workflow — retro adoption ledger

What each retro round proposed, what was adopted, and what was DECLINED with the
reason. Its job is to stop a declined proposal being re-proposed every sprint as
if new, and to give an adopted change a citable home once the sprint record dir
is tar'd and deleted. Owner: Val. Retro reports themselves are ephemeral
(`/var/tmp/medaka-sprints/<stage>.tar.gz`); this file is not.

Cost-lever hypotheses live in `.claude/SPRINT-COST-HYPOTHESES.md` (H-numbers);
this file covers everything else.

---

## v5 — 2026-08-17, from `sprint/ctor-identity` (13 proposals) + `sprint/pds-phase0-substrate` (15)

Both retros ran against v4 (slim packets, no fix packets, daughter rotation,
front-seat compaction, per-agent effort). Where the two disagreed, the sprint
that actually RAN the mechanism wins.

### Adopted

| # | Change | Where | Evidence |
|---|---|---|---|
| 1 | Rulings are FILES (`rulings/RUN-<stage>-NNN.md`); replies open `entries: <N> — <numbers>`; front seat allocates `run=` at consult time, `cat`s the file into DECISIONS.md, confirms by number; heartbeat checks the sequence is contiguous | `sprint-brain`, `sprint-orchestrator` | 4 rulings lost in relay in one sprint (2 never recovered, one cited 3× as authority incl. for a public issue amendment); 2 more unscribed or condensed in the other |
| 2 | OBLIGATIONS.md — one row per ruling Action, terminal-or-blocked at enqueue | `sprint-orchestrator` | A ruling's Actions list is not self-executing: one action owed for 26 rulings turned a sprint's only soundness signal dark; a ruling mandating this very audit went unexecuted |
| 3 | Rulings bind a `property:`, suggest a `mechanism:`, name an `acceptance:` probe | `sprint-brain`, packet §5 | 3 brain instruction errors in one sprint, each property-right/mechanism-wrong; one not executable at all, one provably unsatisfiable |
| 4 | Brain mechanism claims carry a call-site-level instrument (`grep -rln` is a candidate, never a citation) | `sprint-brain` | 3 errors, one shape: "an inference presented where a derivation belonged"; one reached Val before being retracted |
| 5 | Six §9 sections for EVERY role + `scripts/sprint-report-check.sh` at both seats; out-of-roster dispatches carry the contract in their brief | packet §9, orchestrator, reviewer/verifier/reproducer defs | 10 of 31 reports non-conformant with 0 bounces (the definitions licensed it); 6 of 7 ad-hoc dispatches returned bespoke formats, so no reviewer/verifier friction ever reached FRICTION.md |
| 6 | Mid-flight amendment protocol: `fact:` advisory / `stop:` binding, everything else is a packet edit or a follow-up packet; agents DECLINE and log; `declined-out-of-band:` in DECISIONS.md | orchestrator, packet §8, implementer | Same front-seat error twice, both correctly declined; nothing anywhere said it was wrong |
| 7 | Packets name NO worktree path — the writer derives its tree, asserts it is not the front seat's, asserts ancestry over the sprint head, pushes by ref | packet §1, implementer, planner | The live text cost a dispatch (BLOCKED); the derived convention held for 14 dispatches |
| 8 | Pre-dispatch checklist: `isolation:"worktree"` on the tool call, ancestry assertion, `--ff-only` merges | `slice-landed` | First dispatch of a sprint ran in the front seat's own tree and switched its branch; wrong-base worktrees recurred ≥3× and were caught only by writers who happened to check |
| 9 | Disjointness has an expiry: authoritative check at LANE GRANT by the front seat, `head=<sha>` stamp, mechanical staleness rules, `paths` mode | orchestrator, `slice-landed`, planner, `scripts/sprint-disjoint.sh` | Both stale results were collisions against lanes that had already landed; one was resolved by the front seat improvising against the escalation table |
| 10 | Expected-red rows carry derived `masks:` and a first-half `unmask-by:` | orchestrator, `sprint-plan` §6 | One licensed red kept `soundness` red all sprint, so the typecheck gate and C3b fixpoint never ran once — both found real defects the moment they did |
| 11 | Val decisions are `VAL-<stage>-NNN` blocks with a `destination:` and an `executed:` readback, followed by one premise-falsification consult | orchestrator | 5 interventions, 3 formats, none citable; one project-scoped decision needed an extra ruling and a whole fixer slice to reach the design doc |
| 12 | Refusals table in FINDINGS.md; front seat sends `refusal:` rows | `sprint-findings`, rear, `slice-landed` | "Refusals right 7 of 8" was not derivable from the record; 3 correct declines were visible only inside `Deviations` sections |
| 13 | Fix landings carry a DEBT row | packet Fix form, `slice-landed`, orchestrator sweep | 4 fix landings, 0 rows, incl. both S1 severity-increase repairs — absent from the heavy round's own attack list |
| 14 | Executed facts only: formulas, example commands and pre-fix controls are RUN by the planner with output pasted | packet §4, planner | 5 instances in one sprint, all in "do NOT re-derive" sections; the worst PASSED for the wrong reason |
| 15 | Self-audit is per EVENT (tick-`clean` only when the interval was quiet) | orchestrator, retro | Per-tick form produced 0 lines in one sprint and 2 informative lines in the other — every informative one was event-triggered |
| 16 | Base-arm depot built once at sprint start (H13) | orchestrator, packet §2 | Build = 30.8% of writer wall-clock; three FRICTION entries name base-arm attribution |
| 17 | Wrap-up sweeps become a `sprint-verifier` dispatch (H14) | orchestrator | Verifier and reproducer dispatched 0 times while the front seat hand-swept and 4 Opus agents ran the heavy round |
| 18 | Isolation smoke probe at sprint start | orchestrator | Converted a sprint-blocking unknown into a 1-agent answer, after a full implementer was already lost |
| 19 | Pause/resume procedure written down | orchestrator | Improvised once, worked, existed in no skill |
| 20 | `domain-adversary` role + `sprint-plan` §8b trigger; heavy-round dispatch keeps the report contract | new agent, `sprint-plan`, orchestrator | 3 ad-hoc security reviews → 33 items → 5 findings incl. a LANGUAGE-level gap the contract could never have asked about — and all three lost the report contract |
| 21 | Independent-refill slice required in the contract (or an explicit one-line why-not) | `sprint-plan`, orchestrator heartbeat | Writer lane idled twice with the reason honestly recorded: a discovered decomposition is a chain |
| 22 | Retro runs AFTER friction-triage and AFTER MERGED, or scopes CI attribution out | orchestrator step 7, `sprint-retro` | Run in parallel once (retro lost its named input); run pre-enqueue once (CI attribution unanswerable); COSTS.md missing at retro time once |
| 23 | `time:` line required from every dispatched agent, not just writers | packet §9 | No sprint can say how much of its clock went to adjudication or review |

### Declined, with the reason

- **Per-tick mandatory self-audit with a ≥1/hour floor** (ctor P5a). Superseded
  by adoption 15: the sprint that actually ran per-tick self-audits produced two
  "clean" lines and every informative line came from an event. A floor measures
  compliance, not improvisation.
- **Retiring the self-audit protocol entirely** (ctor P5b, ctor E1). The
  seat-model question is now answerable from evidence rather than absence: the
  front seat's five recorded errors in pds-phase0 were all "no loop step
  existed", none were inline adjudication. Keep the Sonnet front seat, keep the
  instrument, fix the loop — which is what most of this round does.
- **Deleting the front seat's post-merge push** (pds P14ii). Already correct in
  the skill: the front seat pushes only the branch-creation commit at sprint
  start, the rear seat pushes landings. The observed duplicate push was an
  improvisation, not a loop defect — its self-audit line worked as designed.
- **`sprint-disjoint.sh --corpus` and `--evidence` flags** (pds P6 tool items
  3–4). `--evidence` would move a brain-signed judgment into a shell flag,
  against principle 2, and both rest on a single sprint's `pds/test/` corpus.
  Re-propose with a second sprint's evidence if planners keep hand-augmenting.
- **Auto-detecting file-vs-inline arguments in `lists` mode.** A repo-relative
  path IS an existing file, so auto-detection silently reads a source file in as
  a path list and reports a false collision — the permissive direction. Hence a
  separate `paths` mode.

### Escalated to Val — open, not decided here

- **E1 (pds): should the brain WRITE DECISIONS.md directly?** Adoption 1 makes
  losses recoverable and detectable but keeps "the front seat is the ledger's
  sole writer". Making the brain the writer trades that invariant away. Not
  taken unilaterally.
- **E2 (pds): where do project-level principles born mid-sprint live?**
  Adoption 11 forces a `destination:` field; the "principle" class still has no
  standing destination (AGENTS.md? `docs/decisions/`? the memory index?).
- **E3 (pds): should the adversarial-review-plus-fix tail be its own budgeted
  phase?** pds-phase0 landed 7 planned slices and 8 fix-forward slices, 5 of
  them after "all slices landed". Sprint exit is currently gated on a phase
  whose size is discovered at the end.
- **ctor E2 (H9 grading):** the v4 slim-packet/Sonnet-planner trial's stated
  rule is an absence-of-disaster test. Adoption via the `corrections: <n>`
  instrument (see H9's Evidence column) is in; whether H9 survives its first
  graded sprint is Val's call.
