# Diff level, test split: 2026-10-18

This is the one look at the test split for `diffbench.py` (README.md,
"Diff-level benchmark"), approved by Val: the **baseline arm only**
(`review.py`'s defaults: merged units, `diff` scope, no twin notes), then one
Opus audit of 40 unlabelled findings. No other arm ran on test. Nothing was
changed after a test result was seen: prompts, rubric, evidence generators,
scoring and sampling are as at `1788fceab`, where the dev results
(`RESULTS-diffs-dev-2026-10-18.md`) were taken. These numbers describe these
prompts, labels and samples; rerun them rather than quote them.

## Setup

- **Code:** branch `review-bench-test-run` from `1788fceab`, with the dev
  passes' model and evidence cache. The only change before the run raised the
  ledger's budget in `diffbench.py` by $7.00 for this pass. Seed 20261018 and
  the plan are the dev passes' (the plan was drawn for both splits at once).
- **Introducing commits:** of 307 test positives and controls, **252 are kept**
  (174 positives, 78 controls) over 155 commits. Of the 55 dropped:
  - 38 because the commit that wrote most of the excerpt wrote under half of it;
  - 16 because the file is not `.mdk`;
  - 1 because the file is in a fixture directory review.py skips.

  The classes that lose most are `dup.in-diff` (9 of 30), `dead.code` (8 of
  11), `comment.stale` (6 of 25), `test.vehicle` (all 5, shell gates and other
  non-`.mdk` files) and `comment.history` (4 of 25). Every other class loses 3
  or fewer. `diffbench.py map` prints the full table.
- **Mixed commits:** 28 of the 155 test labelled commits hold items from both
  splits. Each item is scored in its own split.
- **Units:** 789 planned for test:
  - 201 units overlapping a kept test item;
  - 407 other units, up to 3 sampled per labelled commit;
  - 181 units from 30 clean commits, up to 8 per commit.

  A clean commit on test averages 14.6 units and 145 changed lines (median 11
  units), against 8.9 units and 104 lines on dev.
- **Units reviewed:** all 789. None was cut by the budget.
- **Exclusion:** 8 units (5 item, 3 other) are left out of every figure below,
  leaving **781 compared units**. Their battery prompt differs when their
  evidence is regenerated in another process, the same test that left 12 dev
  units out. Details:
  - On dev, the exclusion fell out of the non-baseline arms' runs: an edit to
    `evidence.py` invalidated the evidence cache, and the regenerated evidence
    differed for 12 units. On test only the baseline runs and the cache is
    intact, so `diffbench.py` has nothing to compare.
  - Instead, a scratch script rebuilt the test units as `make_units` does (4
    threads, no twin notes), once from the cache and once with every generator
    run afresh in a second process. A unit is excluded when its battery request
    differs. The excluded set was fixed before any test result was read.
  - `report` and `audit` then ran with those 8 units subtracted from the
    baseline's reviewed set. That is the set dev's arm intersection produced.
    Nothing else in `diffbench.py` was touched.
  - The differing generators are `dup.cross-file` (6 units), `dup.in-diff` (2)
    and `comment.stale` (2), the hash-order dependence the dev file lists as
    still open.
- **Scored:** 166 of the 174 kept test positives and 77 of the 78 controls.
  With the 8 units kept in, the baseline scores 0.70 (121/174) and 0.17
  (13/78). So the exclusion takes 8 positives and 1 control out of the
  denominators, and 8 found positives and 1 control hit out of the numerators.

## Labelled items (781 units)

A positive is found when a surviving finding of its class lies in the item's
mapped range (plus or minus 2 lines), or when its unit's anchor names the
item's declaration. The same test on a control counts as a false positive. The
item-level row is the stored `verify:battery-pc` test result
(RESULTS-confirm-2026-10-18.md's arm), read from the cache for these same
items. It was not re-run.

| arm | recall | FPR |
|---|---:|---:|
| item level, same items | 0.75 (125/166) | 0.08 (6/77) |
| baseline | 0.68 (113/166) | 0.16 (12/77) |

The scoring rule matters. If the anchor clause is dropped and only the line
test is kept, baseline scores 0.61 (102/166) and 0.09 (7/77).

**On test, diff level costs about 7 points of recall and doubles the FPR
against the item benchmark.** On dev the recall cost was 18 points. The two
levels agree on 99 positives. 14 are found only at diff level and 26 only at
item level; 27 are found by neither.

Of the 12 controls hit, 7 are line hits and 5 come only through the anchor
clause. 8 of the 12 are clean at item level.

## Why positives are missed

For each of the 53 missed positives, the cause is the furthest its class got
in the units overlapping it.

| cause of the miss | item level found it | item level missed it |
|---|---:|---:|
| battery did not flag the class in the unit | 17 | 24 |
| battery flagged it, confirm said no | 3 | 2 |
| flagged, but its quote was on unchanged lines (scope filter) | 4 | 1 |
| a finding of the class in the unit, but outside the range and anchor | 2 | 0 |
| **total** | 26 | 27 |

As on dev, the largest single loss is the battery never flagging the class in
a merged, evidence-heavy unit: 17 of the 26 positives item level finds and
diff level misses. 306 of the 781 units are merged multi-declaration units.

Recall by family (baseline, item level in brackets):

| family | baseline | item level |
|---|---:|---:|
| comment | 36/61 | (45/61) |
| dup | 32/44 | (35/44) |
| data | 13/18 | (13/18) |
| test | 10/12 | (11/12) |
| shape | 7/7 | (7/7) |
| diag | 1/5 | (1/5) |
| idiom | 4/5 | (1/5) |
| dead, magic, iface, naming, doc, defensive, suppress | 10/14 | (12/14) |

Recall by evidence scope (baseline, item level in brackets):

| evidence scope | baseline | item level |
|---|---:|---:|
| local | 75/98 | (83/98) |
| file | 22/35 | (21/35) |
| repo | 16/33 | (21/33) |

## Unlabelled findings

An unlabelled finding sits on no item of its class, and is neither an
`also_present` class nor a judgment item's class.

| unit kind | units | changed lines | unlabelled | per unit | per 100 changed lines |
|---|---:|---:|---:|---:|---:|
| item | 196 | 4,572 | 284 | 1.45 | 6.21 |
| other | 404 | 4,831 | 407 | 1.01 | 8.42 |
| clean | 181 | 2,012 | 164 | 0.91 | 8.15 |
| **all** | 781 | 11,415 | 855 | 1.09 | 7.49 |

At whole-commit scale, a clean test commit of 14.6 units draws about **13
findings** outside the labels, and a labelled commit of 41.4 units about 42.
The audit says most of them are real (below).

The scope filter sent **862 battery flags** to no confirm, because every
verified quote sat on unchanged lines, about 1.1 per unit. Another 30
confirmed findings were dropped after confirm. The top classes were
`comment.provenance` 112, `dup.in-diff` 98, `comment.history` 92,
`comment.stale` 86 and `test.gap` 65. (`report`'s own table counts all 789
reviewed units: 868 and 30.)

## Cost

| unit kind | $ / unit | $ / 100 changed lines |
|---|---:|---:|
| item | $0.0076 | $0.033 |
| other | $0.0054 | $0.045 |
| clean | $0.0052 | $0.047 |
| **all** | $0.0059 | $0.040 |

These are what each unit's answers cost when first asked. The run's new
spend was $4.64 for the 780 units without a cached battery answer, $0.0060
each, against the $0.0057 estimated from dev.

## Audit

`claude-opus-5-5` judged a fixed-seed sample (seed 20261018, as on dev) of 40
of the 846 unlabelled baseline findings in the audit pool. The pool is the
compared units of commits whose noise counts in test. The prompt is the dev
audit's: battery.py's audit prompt with the diff's scope paragraph, the
changed lines listed after the excerpt, and a cause for each "no". The judge
saw the twin notes.

| sample | yes | no | unsure | precision (yes / yes+no) |
|---|---:|---:|---:|---:|
| test baseline, 40 of 846 | 30 | 8 | 2 | 0.79 (30/38), plus or minus 0.13 |
| dev baseline, 30 of 664 | 25 | 4 | 1 | 0.86 (25/29), plus or minus 0.13 |

The sample held 21 findings from other units, 11 from item units and 8 from
clean units. Precision was 7/8 on clean, 7/10 on item and 16/20 on other
units.

**Causes of the 8 "no"s:**

| cause | count | the findings |
|---|---:|---|
| the class's rule | 6 | three `dup.in-diff` (a shared shape with different suffixes; two calls to already-factored helpers repeated in sibling clauses; a consumer-specific match arm), one `dup.cross-file` (a new generic traversal read as a copy of unchanged pass-specific code), one `defensive.redundant` (a guard on a string from an external source), one `test.bool-helper` (an inline match, not a `Bool` helper) |
| G2, pre-existing code | 2 | an `idiom.let-underscore-unit` argued from an unchanged line while quoting a changed one; a `data.sentinel` on new rows filling a field of an unchanged record type |
| G1, deliberate twin | 0 | |
| missing evidence | 0 | |
| misread | 0 | |

The 2 "unsure"s are both `test.gap`: the judge could not see whether a gate or
snapshot outside the evidence covers the new branch.

`dup.in-diff` is the weakest class in the sample (4 yes, 3 no). All 6
`comment.provenance` findings were judged real. With 38 decided findings the
proportion is good to about plus or minus 0.13. Opus is one judge, not the
labels.

## Dev vs test

Dev figures are the baseline's on its 580 compared units
(`RESULTS-diffs-dev-2026-10-18.md`).

| figure | dev | test |
|---|---:|---:|
| compared units (merged) | 580 (218) | 781 (306) |
| positives, controls scored | 111, 59 | 166, 77 |
| item-level recall, same items | 0.79 (88/111) | 0.75 (125/166) |
| item-level FPR, same items | 0.08 (5/59) | 0.08 (6/77) |
| diff-level recall | 0.61 (68/111) | 0.68 (113/166) |
| diff-level FPR | 0.19 (11/59) | 0.16 (12/77) |
| recall, no anchor clause | 0.55 (61/111) | 0.61 (102/166) |
| FPR, no anchor clause | 0.15 (9/59) | 0.09 (7/77) |
| recall cost of diff level | 18 points | 7 points |
| misses: battery never flagged the class | 23 of 43 | 41 of 53 |
| unlabelled per unit: item, other, clean | 1.20, 1.20, 1.16 | 1.45, 1.01, 0.91 |
| unlabelled per 100 changed lines: item, other, clean | 5.31, 8.12, 10.29 | 6.21, 8.42, 8.15 |
| unlabelled per 100 changed lines, all | 7.49 (691/9,227) | 7.49 (855/11,415) |
| battery flags out of scope, per unit | 1.06 (612/580) | 1.10 (862/781) |
| $ per unit, all kinds | $0.0057 | $0.0059 |
| $ per unit, clean | $0.0052 | $0.0052 |
| $ per 100 changed lines, all | $0.036 | $0.040 |
| audit precision | 0.86 (25/29) | 0.79 (30/38) |
| audit "no" causes | rule 2, G1 1, evidence 1 | rule 6, G2 2 |

**Reading.** On test, diff-level review holds the dev picture:
- recall is lower than item level and the FPR about double;
- noise is about 7.5 unlabelled findings per 100 changed lines;
- cost is about half a cent per unit;
- most unlabelled findings are real.

The recall gap is smaller on test (7 points against 18). That is partly
because item-level recall on these test items is 4 points lower than on dev's,
and partly because diff level does 7 points better. With 111 and 166
positives, the difference in diff-level recall (0.61 against 0.68) is a little
over one standard error, about 0.06, so it is not evidence that the funnel
does better on test. The audit's 0.79 and dev's 0.86 overlap well
within their plus or minus 0.13.

## Spend

| what | new spend |
|---|---:|
| baseline run, 789 units (780 uncached) | $4.64 |
| Opus audit, 40 baseline findings | $1.96 |
| **total** | **$6.60** (cap $7.00) |

The audit cost $0.049 per call, against the $0.045 in `AUDIT_USD`. The ledger
now stands at $14.49 of the file's $14.90.

## Caveats

- **Exclusion by a side script.** The excluded set came from one second
  process, as on dev, so a unit whose evidence depends on hash order but
  matched by chance stays in. The scripts lived in the session's scratch
  directory and are not committed; the method is described under Setup.
- **A generator error in 3 test units.** `gen_comment_stale` raised
  `IndexError` (the `evidence: None: IndexError: list index out of range`
  seen while the test evidence was generated) on 3 planned test units, so
  their `comment.stale` evidence is empty in the battery prompt:
  - `Lbab0e4af0fb2`, a clean unit, `stdlib/core.mdk` `println / print`;
  - `L766f17c1d988`, an other unit, `stdlib/async.mdk` `DeferredThenable … / spawn`;
  - `Ld189cbdc0f68`, an item unit, `compiler/frontend/lexer.mdk`
    `keywordOrIdent`, which holds `RB-0479` (`comment.speculative`). That
    positive is missed at diff level and found at item level.

  The error is deterministic, so these units are not excluded. It is what
  `review.py` would do on a live diff, and dev ran with it too (one dev item
  unit, `L96a034adb5c0`, `compiler/support/util.mdk` `maxI / minI`). The cause
  and the fix are in the commit after this one.
- **Scoring.** As on dev, the anchor clause credits a finding anywhere in a
  merged unit whose anchor names the item's declaration (see the sensitivity
  line).
- **Labels.** Clean commits are unlabelled, not certified clean. "Unlabelled"
  is volume; the audit says most of it is real.

## Reproduce

From the repository root, with `D="python3 -I scripts/review_bench/diffbench.py"`
and the dev passes' cache:

```sh
$D run --split test --arm baseline --dry-run
$D run --split test --arm baseline --approved --max-usd 5.10
$D audit --split test --arm baseline --n 40 --approved   # with the 8 units subtracted, see Setup
$D report --split test --arms baseline
```
