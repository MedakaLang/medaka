# Retro candidates — rules seen once

A general workflow rule enters the sprint skills only on its second independent sighting. The
first sighting is one entry here (`.claude/agents/sprint-retro.md`, routing question 3). Each
retro reads this list: a match from a different sprint promotes the entry into the skill named
in its row, and the adopting PR deletes it here. An entry whose expiry date passes without a
second sighting is dropped by the next retro's adopting PR. Expiry is six weeks after the first
sighting, which is about five sprints at the current pace.

Tool fixes and sprint-family rules never come here; they go to an issue and to
`.claude/dossier/sprint-families.md`.

Row shape: **rule, in one line** — first sighting (sprint, date): the evidence. Would land in:
skill and section. Expires: date.

## Open

The five entries below were demoted from the sprint skills on 2026-11-04, when this list was
created; each had one recorded incident behind it.

- **A docs-only slice's self-check is one line: every number and every "no X does Y" written
  into a doc is the output of a command quoted in Evidence.** First sighting: vis-test-split,
  2026-11-02, whose docs slice answered four of five self-check questions "not applicable" and
  still wrote a tree-wide claim that was false for about 30 names. Would land in:
  `sprint-packet`, the author self-check. Expires: 2026-12-16.
- **A survey or decision slice that proposes a variant measures the variant's retention
  (heap rows) beside its instruction counts, before the landing slice is cut.** First sighting:
  arch-p2 stage 6e (rule added 2026-10-21), whose landed variant breached the +5% heap bound (+20.9%), which
  cost a carrier slice and a three-arm measurement. Would land in: `sprint-plan` step 3,
  acceptance shape. Expires: 2026-12-16.
- **The style pass tails the `review-diff` log and never kills a run that is still printing
  batch lines.** First sighting: one sprint (not recorded which) killed two runs at 50 minutes
  and got nothing. `review.py` has streamed progress to stderr since PR #4376, which may already
  prevent it. Would land in: `sprint-orchestrator` end-of-sprint step 1c. Expires: 2026-12-16.
- **Grep the other arcs and docs for your issue numbers before scoping a slice**
  (`grep -rn '#<NNN>' docs/ .claude/`). First sighting: one sprint scoped a slice that was
  verbatim another arc's claimed work. Would land in: `sprint-plan` step 1. Expires: 2026-12-16.
- **Make scratch directories with `mktemp -d`; never write into an existing scratch directory.**
  First sighting: param-clump-sweep, 2026-11-04, where one slice overwrote a `medaka` binary in
  another session's tree. Would land in: `sprint-packet` §2. Expires: 2026-12-16.
- **A "red on base" claim names a commit on `origin/main` (the sprint's cut SHA), never a sprint-branch
  commit; a packet that attributes a red states the base SHA it measured against.** First sighting:
  core-pass-pipeline, 2026-11-06, where two regressions were dismissed as red on base because the
  "base" was a sprint commit; the review found them green at the cut `f52a37d57`. Possible form: a
  `scripts/red_on_base.sh <gate> [sha]` that reads the base from the STATUS.md header. Would land in:
  `sprint-packet` §4 (attribution line). Expires: 2026-12-16.
- **A refusal packet's numeric bar is derived from the failing run's own number, not only main versus
  sprint.** First sighting: core-pass-pipeline, 2026-11-06, where FIX-6's "within 0.05 of main" bar
  compared main's 3.66 with the sprint's 3.68 while the failure was the queue reading 3.69 against a
  ceiling of 3.68 (zero headroom), so the worker refused correctly and bought nothing. Scope: perf-pin
  packets (sprint-families, "pass/IR-node migration"). Would land in: `sprint-packet` §3 (pin
  re-derivation). Expires: 2026-12-16.
