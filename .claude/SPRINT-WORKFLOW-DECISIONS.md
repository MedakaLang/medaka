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

### Amended before landing, by independent review

An independent reviewer graded the round against the cost/throughput goals
(`COHERENT WITH EXCEPTIONS: 15`) and 11 of its findings were applied before
merge. The ones that changed a rule rather than its prose:

| Was | Is | Why |
|---|---|---|
| Per-tick heartbeat check `grep -o 'RUN-<stage>-[0-9]{3}'` vs `ls rulings/` | Phase-boundary two-directional `comm` anchored on the `## RUN-…` HEADING | The original **passes on the incident that motivated the whole protocol**: run against ctor-identity's real ledger it sees 37 numbers against 18 entries, `RUN-CTOR-034` among them, purely from citations — and `^RUN-` is no better, two prose lines in that file begin with the bare ID |
| `scribed:` confirmation per ruling | Confirmations RIDE the next message to the brain | A dedicated confirmation is one daughter wake per ruling — ~40/sprint at the 5-min-TTL write price, i.e. the exact tax H3's rotation exists to remove, and ~10× the cost of all 970 added lines of text |
| `entries: <N>` + "a number you did not allocate → re-request" | `run=` reserves a contiguous RUN; the reply repeats the whole block per entry | As written, a correct multi-ruling reply was rejected and cost a round trip — the opposite of the claim that this replaces the one-per-reply throttle |
| "exit 1 whose colliding lanes are ALL absent from the live table → re-run" | Derive the lane list at grant time; exit 1 → brain, no fourth case | Mapping a colliding FILE to an owning lane through a prose `region` summary is judgment at a mechanical seat (principle 2) — and it re-authorized the improvisation it was meant to replace |
| Front seat creates writer worktrees AND sets `isolation:"worktree"` | The sprint-start probe SELECTS one mode (A/B/C/D table), including a rebase branch for outcome C | Both mandated at once means one is dead work every slice, and the probe had no written branch for a negative result |
| `--ff-only` described as free | Free on the sole-lane path; a refusal with a second live lane is the ordinary two-lane case, not a wrong base | Guaranteed to fire on every multi-lane landing (8 fix-forward slices in one sprint) and invites a false escalation |
| OBLIGATIONS row poked "past the phase it belonged to" | Row gains a `due-by` column; the poke is a string compare | No phase field existed, so the check was unexecutable — and the motivating incident was precisely a deadline failure |
| packet §2: "`MEDAKA_STRICT=1` … on the depot arm it fails every case" | Derived: the depot has no `compiler/`, so `sourceStalenessVerdict` returns `None` and strict is INERT there | The claim was false, in a "do NOT re-derive" position, and it broke this same round's new rule against unverified mechanism claims |
| Depot built at step 3, "3 consumers" | Built at 6b after the packet-#1 dispatch; 2 consumers; H13 cost marked UNDERIVED with the command to measure it | A cold build ahead of the first dispatch is pure serialization; a fix's control is the sprint head, not `$BASE` |
| Wrap-up sweep over `reports/*.md` | Sweep excludes `rear-seat-ledger.md` | The ledger is not a §9 report and bounces every sprint — one known-false alarm is how a check stops being believed |
| `time:` asserted at ~12 roles, checked nowhere | `sprint-report-check.sh` checks it | It is the only wall-clock instrument, and H13's grading target depends on it |

Also adopted from the review: a standing **deletion quota** for every future
retro round (≥2 retirement candidates, same evidence standard as an addition) —
this round was 23 additions to 0 deletions while the front-seat-resident skill
grew 62%, which is how weight accumulates one defensible rule at a time.

The review's remaining findings were accepted as-is: F12's timing estimate
stays UNDERIVED by design (no build was run), and F15's text-trimming
suggestion was measured at ~$3–8/sprint against a $591.70 sprint — under 1.5%,
so no rule was cut to save prose.

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

---

## v6 — 2026-08-20, from `sprint/emit-inputs` (12 proposals, 2 retirements, 2 escalations)

The sprint that FIRST RAN v5. Six landings, ~2.1/hour to MERGED, 32 rulings, 18
findings, max severity S2, zero S0/S1. Adversarial review caught 11 of 18;
required-check CI and the existing gates caught **zero** — third sprint running,
and the standing argument for deferred verification and against ever trading the
review pair for schedule.

### Adopted

| # | Change | Where | Evidence |
|---|---|---|---|
| P1 | A packet MAY NOT contain an ancestor SHA; the dispatch brief supplies the sprint head, re-derived at lane grant | packet §1, `slice-landed` 3 | Two BLOCKED Opus dispatches (~162k tokens), same class, opposite polarity: pinned to the plan base it passes on a tree with zero sprint commits (vacuous); pinned to a sprint-only commit it can never pass in HARNESS mode (unsatisfiable) |
| P2 | Every acceptance clause carries `fails-on:`; binds the brain for checks it MANDATES, not only probes it runs | packet §6, `sprint-brain`, `sprint-planner` | Three cannot-fail instruments in three unrelated domains in ONE sprint; two authored or endorsed by the judgment seat, so it cannot be a planner-discipline rule |
| P3 | Refusals table defined exhaustively (REFUSED/BLOCKED/`declined-out-of-band:`/falsified premise/pre-licensed partial), reviewer findings excluded, `mechanism: license\|assertion` column (E2), three-source cross-check at wrap-up, verifier's VAL item de-judgment-claused | `sprint-findings` 1b, orchestrator 3, `slice-landed`, `sprint-rear` | Table closed with ZERO rows and the owning seat read that as "none occurred" — against 3 BLOCKED dispatches and 6 ruling-recorded falsified premises. H9's criterion (4) was ungradable |
| P4 | Per-landing + heavy-round claim-surface sweep (Haiku, ~$0.35): citations resolve, counted claims re-run, commit citations exist | `sprint-rear` pipeline 3 | Five mechanical citation/count defects consumed reviewer attention at 20–60× the price. ADDITIVE — never a reason to trim the review pair |
| P5 | `base-arm <depot path>` mandatory in the `landed:` handoff, in the rear's inputs, in the breaker's brief AND in `slice-breaker.md` itself | `slice-landed` 2, `sprint-rear`, `slice-breaker`, packet §2 | Depot built, ZERO consumers; the one breaker that needed a base arm built its own (two rebuilds, inside ~35 of its 55 min of build time) against a packet sentence addressed to the writer |
| P6 | Rulings carry `applies-to:` and one `falsified-premise:` line per falsified premise; planners are handed ruling PATHS by `grep -rl`, not "read DECISIONS.md" | `sprint-brain`, `slice-landed` 4, orchestrator scribe 9 | Ledger ended at 3,905 lines/242 KB; three planner reports name ledger reading as their dominant cost, the L1 planner spending 40 of 55 minutes on it plus two other documents |
| P7 | The 250-line packet ceiling counts PLANNER-AUTHORED prose; ruling text and §7/§8 boilerplate travel by pointer | packet preamble, `sprint-planner` | All four slice packets over — 285/325/511/613 — every overshoot the planner correctly refusing to drop ruling-mandated text; one spent three passes on the ceiling alone |
| P8 | The sprint branch is MERGED into, never rebased; the sequencing ruling also asks what main's independent change proved about our design grain | orchestrator | Derived under enqueue pressure as RUN-EMIT-029; a rebase silently voids the ledger's whole citation graph. (The drafted post-merge citation check was NOT adopted — see Declined) |
| P9 | ONE phase-boundary block: ledger sequence check + obligations reconcile + rotate both daughters, one trigger, `rotated: none — <reason>` when declined; a writer return preempts it | orchestrator | The sequence check ran and recovered 2 lost rulings; rotation ran ZERO times in the sprint that ADOPTED it (H3 ungraded, daughter cache-writes 53%/51% of cost); the obligations writeback ran only at wrap-up, 47 stale rows |
| P10 | A stalled writer gets TWO resumes, the second CORRECTIVE (names the mechanism, quotes §8); abandon on the third. Fix briefs paste §7 + §8's first two bullets inline | orchestrator heartbeat 4, packet Fix form | Two stalls of one fixer on a backgrounded build. ⚠️ The retro's own draft said "one resume, the second has never worked" — DECISIONS.md:3304-3306 shows resume 2 is what landed the fix (`895c44c5`). Adopted against the draft |
| P11 | `sprint-cost-report.py --session/--exclude-session`; `SESSION=` recorded beside `BASE=`; COSTS.md carries the sprint's own instruments | `scripts/sprint-cost-report.py`, orchestrator 1 + 7(a) | ~52% of a $513 report was three unrelated sessions, landing in the `main-session`/`general-purpose` rows H5/H10 are graded on; H9's `corrections:` never reached COSTS.md as its own criterion (5) requires |
| P12 | A planner's negative claim about the tree carries the command that would have falsified it | `sprint-planner` | "No deterministic net-extern fixture pattern exists" when `test/net_fixtures/` + `test/diff_net.sh` existed and were CI-registered; propagated into a partial refusal and two packet revisions |
| D1 | DELETE `effort: low` from `sprint-verifier.md` / `sprint-scout.md` | both agent defs | H11's own second probe: the harness silently drops `effort` on Haiku 4.5 (records `None`). A control that appears set and is not |
| D2 | DELETE the tick-time `self-audit: clean` clause (the per-EVENT rule is untouched) | orchestrator heartbeat 6 | **Val, 2026-08-20.** Derived across all three sprint records (~9,000 ledger lines): the clause produced ONE line ever (`pds-phase0-substrate/DECISIONS.md:1000`), and it rode a tick already recording live lanes with agent ids, orphan state and a dispatch decision — the attestation added nothing the line did not already prove. Nor is it functioning as a prompt: the two sprints running the per-TICK form produced 0 and 5 self-audit lines, the sprint running the per-EVENT form produced 7. Stated trade (retro's): it was the only positive attestation that a quiet interval was quiet — answered by the data, since a seat that skips the event line skips this one too |
| — | `friction-triage` gains a SATURATED class: a fully-characterised, already-mitigated, not-ours-to-fix issue takes an occurrence COUNT, never a drafted comment; only a NEW mechanism reopens drafting. #1148 and #1716 named as saturated | `friction-triage` | #1148 accumulated 7 comments / ~32 occurrences across 5 sprints, one per sprint, after its mechanism was fully characterised on 2026-07-31. Each cost a triage slot, a rear-seat filing and a reader's attention for zero marginal information |
| E1 (partial) | packet §8 + `AGENTS.md` `[B-ISOLATION-COMPOUND]` + `ORCHESTRATING.md`: one plain command per Bash call, multi-step work into a script file, the mandatory build redirect INSIDE it; `make` denied in your OWN worktree is a BLOCKED verdict | packet §8, AGENTS.md, ORCHESTRATING.md | 7 refusals across 6 agents, 8 distinct shapes, all in-tree (#1148). The docs named only the `cp` trigger. The expensive failure is the agent that continues source-only and produces unsupportable existence claims |

### Declined, with the reason (do not re-propose without new evidence)

- **P8's post-merge citation-graph check** (drafted, adopted, then REMOVED the
  same day on independent review). It cannot fail: a merge rewrites no SHAs, and
  a rebased-away commit still resolves to `git cat-file -e` as an unreachable
  object — verified in a scratch repo. Its regex also matched 79 tokens on a
  healthy record of which 38 were decimals, CI run ids and MD5s. SHA resolution
  belongs to P4's sweep, which sees the real defect (a mistyped abbreviation)
  continuously. Naming it here because the *idea* will recur.

### Deletion quota — honest accounting

v5's own retro flagged that round as 23 additions to 0 deletions with the
front-seat skill growing 62%. **v6 does better, but not by much:** three
removals — D1 (two lines), the drafted citation-graph check, and D2's tick
clause — plus one net-negative rule (`friction-triage`'s SATURATED class, which
removes a recurring per-sprint comment) against ~14 additions, measured by an
independent review at +17.7 KB / ~4.4k tokens across the always-loaded files,
≈1% of a sprint-scoped run. P7 is the only change that reduces downstream
packet weight. The next retro should still carry a real deletion quota.

### Escalated to Val — open, not decided here

- **E1 (emit-inputs): RESOLVED by Val, 2026-08-20** — mitigate in docs, stop
  tallying, take it upstream. The avoidance rule, the `sh
  test/build_native_medaka.sh` workaround and the BLOCKED exit are adopted
  above; `friction-triage` now treats #1148 as saturated; an upstream report is
  drafted. Remedies 2 and 3 (clear the carried-forward denial; recognise `make
  -C <own worktree>`) remain the harness's, not ours.
- **E2 (emit-inputs): should the Refusals ledger distinguish license from
  assertion?** ADOPTED as a `mechanism:` column rather than left open — the two
  instruments have different failure modes and an assertion can itself be
  vacuous (one of the two that fired was). Recorded here so the adoption is
  visible as a decision, not an assumption; reversible in one column.

---

## v8 — 2026-08-22, Val's directive after `sprint/selector-identity` (not a retro round)

**This entry is a RESET, not an adoption round.** Val's ruling, verbatim in
intent: the workflow had accreted so much bookkeeping and tracking that agents
could no longer stay focused; the sprint model is re-stated as *"a series of
implementers that run one after another and do minimal verification … then at
the end a more thorough review round to catch gaps and a fix round to address
them."* Goals, in order: (1) high throughput of implemented code, (2) low
token cost, (3) correctness prior to merge to main.

Evidence for the reset (`/var/tmp/medaka-sprints/selector-identity/`): 1 of 4
packets landed; packet-04 dispatched five times, every BLOCKED verdict a
process defect (tree-placement admissibility), zero packet-content defects;
9 of 38 rulings (24%) adjudicated the workflow itself; DECISIONS.md reached
523 KB. Prior: method-identity's rear seat cost $219 of prompt-cache traffic
for $4.88 of output (COSTS.md); machinery:product ratio 83:17 (H15).

### Adopted (the v8 shape)

- **Serial implementers, minimal per-slice verification** — a one-page packet
  (≤80 lines target), 3–5 acceptance checks as a ceiling; CI and the end
  review own everything else. Parallel pair only with contract-declared,
  `sprint-disjoint.sh`-verified disjointness, re-verified at dispatch.
- **One end-of-sprint review round** (`sprint-reviewer`, new role folding
  slice-breaker + spec-conformance-reviewer + domain-adversary lenses into
  one whole-diff pass) **+ one fix round**, then the merge queue as the
  correctness authority. Consistent with the 2026-08-13 audit's "repair round
  is load-bearing".
- **Single-session front seat, no persistent daughters.** Routine judgment
  is the orchestrator's; contested calls go to Val.
- **State = STATUS.md + NOTES.md + git history.** Mid-sprint findings are
  one NOTES.md line each, triaged at the review round (except
  blocks-later-slices, fixed immediately).
- **Worktree placement**: harness `isolation:"worktree"` mints (proven,
  selector-identity dispatches #4/#5) + a verbatim licensed `--ff-only` sync
  in packet §2. The derive-your-tree/refuse-on-mismatch contract (v5 #7/#8)
  is retired as structurally unsatisfiable (selector-identity RETRO §1).

### Retired

Roles: `sprint-brain`, `sprint-rear`, `sprint-planner`, `sprint-verifier`,
`sprint-scout`, `bug-reproducer`, `friction-triage`, `slice-breaker`,
`spec-conformance-reviewer`, `domain-adversary`. Skills: `slice-landed`,
`sprint-findings`. Mechanisms: rulings-as-files + DECISIONS/OBLIGATIONS/
FINDINGS/QUEUE/DEBT/FRICTION ledgers, per-slice reviewer pairs, mid-sprint
findings lifecycle, brain rotation, heartbeat self-audit, base-arm depot as a
standing requirement. The incident lessons those mechanisms encoded survive
as checklist lines inside the three remaining skills and two agent defs —
lessons live in gates and checklists, not process.

### Standing bias, binding on future retros

A retro proposes AT MOST three changes, deletion-biased; a new rule is
proposable only for a failure that occurred in that sprint, cost something
real, and cannot live in an existing gate or checklist line. This ledger
remains the place a declined proposal goes to die visibly.

---

## v8.1 — 2026-09-03, from the 71-retro corpus (not a single sprint's round)

The first adoption round drawn from the WHOLE post-reset record rather than one
sprint's retro: 71 `RETRO.md` files, 2026-08-22 → 2026-09-03. Two consults
audited the conclusions before anything was written — one attacking the resync
mechanism claim first-hand in a scratch repo, one re-deriving the counts and
checking each proposal against what had already landed. Both changed the
outcome: two of five proposals were withdrawn, and the admitted ones amended.

Standing read of the corpus: **the v8 shape needs no change.** 42 of 71 retros
record the review round catching an S0/S1 that per-slice checks structurally
could not see; refusals are graded correct and self-paying throughout. What HAD
re-accreted was packet-authoring weight — `sprint-packet` had grown three
per-gate reminder blocks, each bought by one sprint's incident, with a fourth
proposed three times. That is the v7 failure restarting, so this round is a net
deletion.

### Adopted

| # | Change | Where | Evidence |
|---|---|---|---|
| 1 | Packet §2 CHECKS OUT the sprint base (`checkout --detach`) instead of `merge --ff-only`, and asserts `FETCH_HEAD` = the base SHA | `sprint-packet` §2, `sprint-reviewer` Setup 1 | The harness mints every dispatched tree at `origin/main`'s tip (corroborated first-hand: implementer `git log` transcripts, and 337 of 338 live agent worktrees at `origin/main` rather than the stale local checkout). `merge --ff-only <base>` therefore succeeds only while `main` has not moved — verified in a scratch repo, exit 0 vs `fatal: Not possible to fast-forward` exit 128. Twelve recorded BLOCKED round-trips are this and nothing else, several on docs-only, CI-only or stdlib-only landings that could not touch the slice. The `rev-parse` assertion is NEW coverage: ff-only caught a stale base only when `main` had also moved (`capture-free-closures`); when it had not, both forms accept a stale SHA silently |
| 2 | The pre-dispatch resync MANDATE becomes a pre-dispatch CHECK (fetch + log/diff, no merge), with four named merge triggers | `sprint-orchestrator` loop 2 | ~21 of 71 retros name resync the biggest or second-biggest time sink; 47 mention it. No retro cites a defect a mid-sprint resync prevented. `prelude-shadow-build-agreement` measured the elective case: a resync that cost a rebuild and a re-bless, prevented nothing, and the branch was `CONFLICTING` at land anyway. [W-MERGE-QUEUE] means branch currency is never required. The check survives because `comment-register`'s fetch-and-diff — not its merge — found a sibling sprint shipping the same tool and let a doomed slice be dropped before review |
| 3 | `scripts/sprint-resync.sh` — the resync battery mechanized; refuses off-branch or dirty, re-derives goldens via the gates' own capture paths, exits non-zero if re-derived artifacts are uncommitted | new script, ledgered in `test/CI-COVERAGE-TOOLS.txt` | Three orchestrator git slips from hand-running the sequence: a bare merge pushed without its blessed goldens (cost part of a fix dispatch), a `git checkout <stale-sha> --` over an already-verified bless (full rebuild+rebless+preflight redo), a merge into the wrong branch. Ranked the #1 item the proposal set had missed |
| 4 | ONE unnarrowed `gh workflow run ci.yml --ref sprint/<stage>` at last-slice-landed, read into the fix-now triage | `sprint-orchestrator` end-of-sprint 1b | It is the only pre-queue execution of the full suite, and the sole pre-queue run of `registry_keying_ratchet.sh` (inside `compiler-soundness`, invisible to `make preflight`) — which is why that reminder was proposed three times and the gap hit six. ~40 min wall-clock in parallel with a ~1h14 review round, so off the critical path; runner-minutes are free on this repo; the concurrency group keys on `github.ref` so PR runs are not cancelled. Already practiced ad hoc by one orchestrator, where it independently found 3 golden-family misses plus a 4th class before the reviewer reported |
| 5 | DELETE the three per-gate §6 reminder blocks (snapshot/LEG-A bless, `backend/*`→fixpoint, cross-module acceptance) and the orchestrator's duplicate | `sprint-packet` §6, `sprint-orchestrator` fix round | The list does not converge — unnamed gate was a golden bless ×10, ratchet ×6, fixpoint ×3, docs-index ×4, plus lextok, doctest goldens, cross-backend parity. And the reminders do not work: the snapshot line entered the skill after `selector-identity-2` and was omitted in ≥5 later sprints, one report calling it "the line the skill already mandates". Superseded by 4, which is mechanical. The cross-module block is separately redundant with `sprint-reviewer` and [T-GLOBAL-TABLE] |
| 6 | A one-line fix a previous fixer already located is folded into the packet in flight or done orchestrator-direct — never its own dispatch | `sprint-orchestrator` fix round | Nine sprints spun a full worktree+build+report cycle for a change the prior packet's own report had already named and located; one chain burned 1h10 for a ~10-min packet. Orchestrator-direct fixes measured at ~10 min against 18–36 min per dispatch. Proposed in identical words by two retros independently |
| 7 | Subagents finish every build/gate run INSIDE the turn; the contradictory "background it" advice corrected at both sites | `sprint-implementer` loop 3, `AGENTS.md` [L-NO-FULL-NOT-FIXPOINT] | Seven dispatches stalled backgrounding a step and ending the turn to await a notification a subagent never receives; one stalled four times in a row; one stalled with the warning already in its packet. ⚠️ The FOREGROUND line had been in the implementer definition since 2026-08-16 and ALL of those stalls happened with it present — so deleting the contradictory parenthetical was not enough, and the fix states the mechanism that worked instead |

### Declined, with the reason (do not re-propose without new evidence)

- **"A packet may not assert a site it hasn't measured" / drop line-column
  citations / state the property not the literal check** (proposed off ~31
  falsified-premise sprints). Two-thirds is ALREADY THE RULE: §4 requires "each
  with the command that proved it" (v5 adoption #14), and unknown-site→SPIKE-
  FIRST is `sprint-plan` step 3. Of the ~31, only **3** are citation failures,
  and in the worst the expensive miss was a wrong FUNCTION NAME, which "state
  the property" would not have prevented. The corpus grades these refusals as
  the system working at one sonnet dispatch each, and two retros declined this
  exact rule as taxing the ~90% of packets whose claims hold. The remedy the
  corpus does validate — a cheap pre-dispatch grep before asserting a site — is
  §4's existing rule, applied. A compliance matter, not a missing rule.
- **"Enrol a new gate, accept the `ci-gen-drift` red, discharge in a
  follow-up"** (proposed off 14 sprints). **Structurally impossible, and
  AGENTS.md said it anyway** — `ci-gen-drift` is a REQUIRED context (ruleset
  18885875) and its script runs `medaka gate balance --check`
  (`test/diff_compiler_ci_gen_drift.sh:80`), so the refusal blocks the merge
  queue. Three sprints hit that wall. The AGENTS.md text is corrected and the
  real defect — the collector's success-only filter, and closed packing rows —
  re-filed as tooling issue #2602. The five hand-run steps were already
  scripted in `test/gate_cost_collect.sh`.
- **"Every closed issue owes a regression fixture in the same commit"** (6
  sprints, each caught by the review round at one fix dispatch). Covered by
  [W-QUIETER], and all six occurrences PREDATE the packet self-check Q5 ("which
  test vehicle carries the new behaviour"), which is the covering line and has
  not yet been tested by a sprint. Revisit only if a fixture-less close reaches
  `main`.
- **A fourth per-gate reminder for `registry_keying_ratchet.sh`** (proposed
  three times, gap hit six). Superseded by adoption 4 — the reminder is the
  thing that keeps failing; the unnarrowed run is the thing that catches it.
- **Single-occurrence items:** `ENTRIES.log` ruling authorship, `Agent(to:)`
  spawn semantics, `pkill` scoping, `gh` auth in implementer worktrees, "one
  `Closes #N` per line" (`scripts/pr.sh` has no `Closes` rendering at all — a
  convention for `docs/ops/PR-HELPER.md`, not a sprint skill), `MEDAKA_EMITTER`
  in [D-TWO-ARM-STDLIB].
- **Anything altering the review/fix-round split, the refusal license, or the
  packet size ceiling.** 42 retros' worth of evidence that these are
  load-bearing. Several retros proposed STRENGTHENING per-slice checks; every
  one self-declined on the grounds that the finding was structurally invisible
  to a single slice. That is the design working, not a gap.

### Corrections to the record

- **A phantom rule:** `entailment-verdict`'s retro justified a resync by citing
  a "[W-PR-FLOW] descendant-of-main requirement". No such requirement exists —
  [W-MERGE-QUEUE] states the opposite. Killed here so it stops propagating.
- "Resync costs 3-7 cycles per sprint" overstates it: of 78 sprints with
  NOTES.md, 9 never resync and 76 resync lines describe a clean, file-disjoint
  merge. Adoption 2 cuts the COUNT (~2.5/sprint → ~1); adoption 3 cuts the
  per-resync battery.
- `argtag-decidability`'s `copyDriverState` non-compiling clean auto-merge is
  cited in places as an argument FOR mid-sprint resync. It is not: it happened
  at LAND time, after four mid-sprint resyncs had already run and prevented
  nothing, and [T-LEGA-REBASE]'s rebuild is what caught it.

### Open, for a later round

Two costs the corpus names that this round does not address, both CI-
infrastructure rather than sprint workflow. **Known-flake merge-queue
round-trips**: 12 retros name a rerun or re-enqueue, and the reverse hazard
fired once — a real regression pattern-matched away as the known flake. The
remedy is tier-3 demotion of the wall-clock arm (`docs/ops/CI-ARCHITECTURE.md`
§3.6). And **fix-round regressions reach the queue unreviewed** (5 sprints):
the review round runs before the fix round by construction, so anything the fix
round breaks gets only CI. Adoption 4's run fires at last-slice-landed and does
not see it either.
