---
name: review-diff
description: Cheap first craft pass over a branch, PR or sprint diff with the measured Haiku style reviewer (scripts/review_bench/review.py), before a human or Opus review. About half a cent per changed declaration, capped at $1 by default. Never a gate.
---

# Review a diff cheaply

`scripts/review_bench/review.py` runs the measured funnel of
`docs/design/REVIEW-WORKFLOW-DESIGN.md` (generated evidence, a Haiku battery
over the whole rubric, a per-class confirm, the quote verifier) over the Medaka
declarations a diff touches. It prints ranked findings in the `pr-review`
shape. It is the first, cheap pass: `style-review` (end of sprint) and
`pr-review` (per PR) still follow, and they own the verdict.

## Run it

```sh
R="python3 -I scripts/review_bench/review.py"
$R --dry-run                     # units, token and cost estimate; asks nothing
$R                               # $(git merge-base origin/main HEAD)..HEAD
$R --rev A..B --max-usd 0.50     # any range; `--rev <sha>` is that commit alone
$R --json > findings.json        # records for diff-level benchmarking
```

It reviews committed code at B only and warns on stderr if a reviewed file is
dirty. Answers are cached under `scripts/review_bench/.cache/`, so a rerun is
free. The README section "Reviewing a live diff" says how units are cut and
scoped.

## Moved declarations are skipped

By default a touched declaration is dropped when the base commit holds a same-named one (this file or another) with the same text after removing a visibility prefix, whitespace and comment wrapping, 🚨/⚠️/🔒 sigils and case: a pure move is not a change. Dropped ones are listed (`--json`: `skipped_units`, reason `moved-unchanged`) and `--dry-run` counts without them.
`--keep-moved` reviews them anyway. A rename or a one-token edit is never skipped. Tests: `python3 -I scripts/review_bench/review_test.py`.

## What it sees

- Medaka only. Other files, deleted files, goldens, snapshots, the seed and
  fixture directories are skipped and listed (rubric R27 exempts fixtures).
- Six classes have an evidence generator (`scripts/review_bench/README.md`,
  "Evidence modes"). The other classes whose positives need context outside
  the excerpt get none and are weak.
- `comment.stale` and `dead.code` have the lowest recall
  (`scripts/review_bench/RESULTS-stage1-2026-10-17.md`): silence there means
  little.
- A finding whose quote sits on lines the diff did not change is dropped in
  code (`style-review` § Scope).

## Reading a finding

- Check it against its class's row in `docs/design/STYLE-RUBRIC.md`, exceptions
  included, before acting. A finding that matches an exception is wrong.
- Check the DECLINED register in `.claude/skills/style-review/SKILL.md`.
- Over real commits on the test split, the reviewer finds 0.68 of labelled
  defects (113/166) and flags 0.16 of clean controls (12/77). About 7 findings
  land per 100 changed lines outside the labels. An Opus audit judged 0.79 of
  those real (30/38); most wrong ones misapply the class's own rule, and
  `dup.in-diff` is the weakest
  (`scripts/review_bench/RESULTS-diffs-test-2026-10-18.md`).
- A finding marked "from an evidence block" is argued from other code. Read
  that code before believing it.

## Cost

About $0.006 per unit, or $0.04 per 100 changed lines, measured over real
commits (`RESULTS-diffs-test-2026-10-18.md`). A unit is one
touched declaration, or adjacent touched ones up to 40 lines (cutting one
declaration per unit was measured: no better, half again the noise and cost).
A 16-file compiler commit cut into 54 units and cost about $0.24; a 2-file
stdlib commit into 15 units, $0.07. At `--jobs 4` a unit takes about 11
seconds, so a sprint-sized diff of about 70 units takes about 15 minutes.
`--max-usd` (default 1.00) stops asking and reports how many units went
unreviewed. Run `--dry-run` first on a sprint diff.

## Never a gate

It calls external models and always exits 0. It never goes into
`test/gates.toml` or a required check (`scripts/review_bench/README.md`).
