# Diff level, dev split: 2026-10-18

This is the first run of `diffbench.py` (README.md, "Diff-level benchmark"). It
runs `review.py`'s funnel (Haiku battery, then per-class confirm, generated
evidence, diff scope) over the commits that introduced the labelled fixtures,
plus a sample of clean commits. It ran on the **dev split only**. The test split
was not run: it is looked at once, with Val's approval. The estimate for that
run is at the end. These numbers describe these prompts, labels and samples;
rerun them rather than quote them.

The two variants measured here are G1 and G2. G1 (`--twin-notes`) adds evidence
about suppressions and deliberate twins. G2 (`--scope strict`) tightens the
scope filter. Both were chosen from the rubric's wording, measured on dev, and
left off by default.

## Setup

- **Code:** branch `review-bench-diffs` from `df3c2a990`. The clean sample was
  drawn from `origin/main` at `261b94a2d` (`MAIN` in the file). Seed 20261018.
- **Introducing commits:** of 218 dev positives and controls, **184 are kept**
  (123 positives, 61 controls) over 131 commits. Of the 34 dropped:
  - 18 because the commit that wrote most of the excerpt wrote under half of it;
  - 15 because the file is not `.mdk` (review.py reads Medaka only);
  - 1 because the file is in a fixture directory review.py skips.

  Drops by class are spread thin:
  - `comment.measurement` loses 3;
  - `comment.ephemeral`, `data.sentinel`, `dead.code`,
    `defensive.silent-default`, `dup.in-diff`, `magic-literal`,
    `naming.misleading` and `test.vehicle` lose 2 each (`test.vehicle`'s are
    shell gates);
  - `idiom.let-underscore-unit` loses its only dev item.

  `python3 -I scripts/review_bench/diffbench.py map` prints the full per-class
  table for both splits. Test keeps 252 of 307.
- **Mixed commits:** 28 of the 131 dev labelled commits hold items from both
  splits. Each item is scored in its own split. A commit's other units count in
  the split of the majority of its items.
- **Units:** 618 planned for dev:
  - 154 units overlapping a kept dev item;
  - 324 other units, up to 3 sampled per labelled commit;
  - 140 units from 30 clean commits, up to 8 per commit.

  A labelled commit averages 72.5 units: these are sprint-sized commits. A clean
  commit averages 8.9 units and 104 changed lines (median 5 units). The clean
  commits come from 3,799 candidates: non-merge commits touching `.mdk` in the
  labelled commits' date span, with no seed refreshes and not the two commits
  that exposed the gaps.
- **Units reviewed:** 580 of the 618.
  - 26 were not reviewed because the baseline run reached its $3.40 cap. They
    are the last 9 commits in sha order: 10 clean, 9 other, 7 item units.
  - 12 more are left out of every comparison. Their evidence without twin notes
    differs between the baseline process and later ones (see Caveats), so their
    arms would not differ by G1 or G2 alone.
  - As a result, 111 of the 123 kept dev positives and 59 of the 61 controls
    are scored.

## Labelled items (580 units)

A positive is found when a surviving finding of its class lies in the item's
mapped range (plus or minus 2 lines), or when its unit's anchor names the
item's declaration. The same test on a control counts as a false positive. The
item-level column is the stored `verify:battery-pc` result
(RESULTS-confirm-2026-10-18.md's arm) on these same items.

| arm | recall | FPR |
|---|---:|---:|
| item level, same items | 0.79 (88/111) | 0.08 (5/59) |
| baseline | 0.61 (68/111) | 0.19 (11/59) |
| g2 (strict scope) | 0.61 (68/111) | 0.19 (11/59) |
| g2-exempt (variant) | 0.61 (68/111) | 0.19 (11/59) |
| g1 (twin notes) | 0.60 (67/111) | 0.22 (13/59) |
| fixed (g1 + g2) | 0.60 (67/111) | 0.22 (13/59) |

The scoring rule matters. If the anchor clause is dropped and only the line
test is kept, baseline scores 61/111 and 9/59, and fixed scores 62/111 and
10/59.

**Diff level costs about 18 points of recall and doubles the FPR against the
item benchmark.** Why the 43 baseline misses happen:

| cause of the miss | item level found it | item level missed it |
|---|---:|---:|
| battery did not flag the class in the unit | 12 | 11 |
| battery flagged it, confirm said no | 6 | 4 |
| flagged, but its quote was on unchanged lines (scope filter) | 5 | 2 |
| a finding of the class in the unit, but outside the range and anchor | 3 | 0 |

The units are larger than fixture excerpts: 218 of the 580 are merged
multi-declaration units. They also come with whole-unit evidence. The
battery's attention is spread thinner, and that is the largest single loss.
Of the 11 controls hit, 9 are clean at item level. A finding elsewhere in the
same unit lands on the control's range or declaration.

Recall by family (baseline, item level in brackets):

| family | baseline | item level |
|---|---:|---:|
| comment | 19/33 | (26/33) |
| test | 12/18 | (14/18) |
| dup | 15/20 | (19/20) |
| data | 4/15 | (10/15) |
| defensive | 4/6 | (6/6) |
| suppress | 4/5 | (5/5) |
| shape, iface, magic, idiom | 10/11 | (7/11) |

The other families have one item each.

Recall by evidence scope (baseline, item level in brackets):

| evidence scope | baseline | item level |
|---|---:|---:|
| local | 54/78 | (68/78) |
| file | 7/17 | (13/17) |
| repo | 7/16 | (7/16) |

## Unlabelled findings

An unlabelled finding sits on no item of its class, and is neither an
`also_present` class nor a judgment item's class.

| arm | units | per unit: item units | per unit: other units | per unit: clean units | per 100 changed lines: other | per 100 changed lines: clean | $ / unit, clean |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 580 | 1.20 | 1.20 | 1.16 | 8.1 | 10.3 | $0.0052 |
| g2 | 580 | 1.20 | 1.19 | 1.13 | 8.0 | 10.1 | $0.0051 |
| g1 | 580 | 1.21 | 1.19 | 1.16 | 8.1 | 10.4 | $0.0053 |
| fixed | 580 | 1.21 | 1.18 | 1.14 | 8.0 | 10.2 | $0.0053 |

Unit counts by kind: 141 item units (3,183 changed lines), 310 other units
(4,596 lines), 129 clean units (1,448 lines). Mean cost per unit across all
kinds was $0.0057; item units cost $0.0068 because they are larger.

At whole-commit scale, a clean commit of 8.9 units draws about **10 findings**
outside the labels, and a sprint-sized labelled commit of 72 units about 87.
The audit says most of those are real (below). This is a volume figure, not an
error rate.

## What the scope filter dropped

The default filter (`scope`: a quote touching a changed line survives) already
drops a lot. Over 580 units, **612 battery flags** were never sent to confirm
because every verified quote sat on unchanged lines, about one per unit. The
top classes were:

- `comment.provenance` 86;
- `dup.in-diff` 60;
- `comment.stale` 56;
- `comment.history` 46;
- `comment.shout` 45.

Another 11 confirmed findings were dropped after confirm.

G2's half rule removes little on top of that. Against baseline, `g2` drops 8
findings (7 unlabelled, 1 positive) and gains 1 positive by placing it on a
different line. Against `g1`, `fixed` drops 7 unlabelled findings.

On the two live commits, with cached answers, `--scope strict` drops two
findings from `e5a3d0380`:

- `dispatchSub`'s `dup.in-diff`, whose quote is 3 lines with 1 changed: the
  exit line;
- `runCheckPolicyArgs`'s `test.gap`, also 3 lines with 1 changed.

It drops nothing from `3f3e63a12`. The `g2-exempt` variant, which exempts
`dup.in-diff`, `test.gap` and `module.scattered-concern`, keeps both of those
`e5a3d0380` findings. On dev it removes only 4 battery flags and 3 findings.

## Audit

`claude-opus-5-5` judged a fixed-seed sample of baseline unlabelled findings.
It used battery.py's audit prompt with its scope paragraph replaced by the
diff's. The lines the diff changed are listed after the excerpt. Each "no"
carries a cause. The judge saw the twin notes whatever the arm.

| sample | yes | no | unsure | precision (yes / yes+no) |
|---|---:|---:|---:|---:|
| baseline, 30 of 664 | 25 | 4 | 1 | 0.86 |
| fixed, new or changed vs baseline, 6 of 67 | 3 | 3 | 0 | 0.50 |

**Causes of the 4 baseline "no"s:**

- **G1, deliberate twin: 1.** A `dup.cross-file` finding on `wasm_reach.mdk`
  `canonKey`. Its own new comment says it is deliberately not consolidated with
  `dce.canonRef`. The quote *is* that comment, so the reviewer saw it.
- **The class's rule: 2.** A short repeated idiom flagged as `dup.in-diff`, and
  single-use traversal arms flagged as `iface.underused`.
- **Missing evidence: 1.** `test.repeated-columns` with only two added rows
  visible.
- **G2, pre-existing code: 0.**

**Causes of the fixed-arm "no"s:**

- **G2-type, unchanged context: 1.** A `dup.in-diff` quote on a changed comment
  line, about arms that did not change.
- **Rule: 1.** `defensive.redundant` on a needed `None` arm.
- **Misread: 1.** A `test.gap` on a line that only gained a threaded argument.

Both G2-type cases pass the half rule: the quoted line did change, but
trivially.

Which audited findings each arm keeps:

| verdict | audited | baseline | g2 | g1 | fixed |
|---|---:|---:|---:|---:|---:|
| yes | 25 | 25 | 25 | 24 | 24 |
| no | 4 | 4 | 4 | 3 | 3 |

The finding g1 drops among the "yes"es is a real `test.gap`, and the one among
the "no"s is the `iface.underused` judged wrong under the rule. **G1 does not
drop the deliberate-twin finding it was built for.** With 30 audited, each
proportion is good to about plus or minus 0.13. Opus is one judge, not the
labels.

## G1: twin notes

**Rule:** for the `dup.*` classes, `evidence.twin_notes` adds neutral facts to
the generated evidence. It changes no prompt template:

- each `lint-disable` of the class's lint rule (`rule-duplicate-body`, or
  `rule-stdlib-reimpl` for `dup.existing`), with the comment above it. A
  file-wide disable counts anywhere; a next-line disable counts inside the
  declaration;
- comment sentences inside the excerpt's or the candidate twin's declaration
  that speak of a copy and give a reason for it (independence, an oracle, a
  deliberate or intentional choice, a distinct type);
- comment blocks anywhere in either file that name the other file and speak of
  either.

The facts about the excerpt's own file go first, as a location-only ref. A
twin's facts are appended to that twin's own ref. Example, on `3f3e63a12`:
`` `stdlib/set.mdk` line 30 suppresses `rule-duplicate-body` for the whole
file, under the comment: "set/map are identical weight-balanced-tree bodies
over DISTINCT ADTs; consolidation needs a Set = Map _ Unit refactor (out of
scope)." ``

**Effect:**

- The notes change the battery prompt of 171 of the 580 units, and the
  `dup.existing` and `dup.cross-file` few-shot examples.
- They do not reduce `dup.*` findings: on the changed units, unlabelled
  `dup.cross-file` went from 17 to 22.
- At item level they change the evidence of 11 of 35 dev `dup.*` items and
  leave per-class Haiku exactly where it was: recall 21/23, FPR 4/12, both arms.
- The arm-level differences (one positive fewer, two control hits more) are the
  size of the reshuffle that any prompt change causes.

**Reading:** the reviewer is not missing the information. It does not treat a
suppression or a "deliberate" comment as an exception, and the rubric does not
say it is one:

- `dup.cross-file` has no such exception;
- `dup.existing` excepts an independence requirement only for an oracle;
- R19 (`suppress.invalid-reason`) makes "out of scope", the reason `set.mdk`
  gives, an invalid reason.

So G1 is a rule question for Val, not an evidence gap. The `3f3e63a12` set/map
findings were not re-run with the notes, because the budget was spent.

## G2: strict scope

**Rule (`review.scope_strict`):** the rubric says "a finding is about code the
diff adds or changes" (STYLE-RUBRIC.md, preamble). style-review § Scope says a
defect in untouched code is "at most one line in the report". The rule is:

- a quote in the excerpt counts only when **at least half of its non-blank
  lines are changed lines**;
- `comment.stale` also counts when a changed quoted line is a comment line,
  that is, when the diff edited the comment;
- either of a finding's two quotes (battery, confirm) may qualify;
- evidence-only quotes keep the default rule.

I did not exempt `dup.in-diff`, `test.gap` and `module.scattered-concern`,
although the brief suggested exempting the first two. Their rules name the
instance as new code: "repeated within the new code", "new behaviour", "a diff
that adds". A reviewer may quote the original as well, and the second quote
allows for that. The exempt variant is measured beside it (`g2-exempt`). It
keeps exactly the `e5a3d0380` `dispatchSub` finding that motivated G2.

**Effect:** on dev it is small, because the default filter already removes
quotes on wholly unchanged lines, and introducing commits are mostly new code.
The remaining G2-type wrong findings quote a line that changed trivially (an
added argument, an edited comment line). A line-share rule cannot see that.

## Spend

| what | new spend |
|---|---:|
| baseline run, 592 units | $3.40 |
| g1 run, 580 units | $0.91 |
| g2, g2-exempt and fixed runs (all cached) | $0.00 |
| item-level dev `dup.*` with twin notes, 22 uncached calls (upper bound) | $0.05 |
| Opus audit, 30 baseline | $1.35 |
| Opus audit, 6 fixed | $0.30 |
| **total** | **$6.00** (cap $6.00) |

The dry run estimated $3.21 for the baseline at the item-level $0.0052 per
unit. The real cost was $0.0057, because live units are larger than fixture
excerpts.

## Caveats

- **Evidence nondeterminism.**
  - **Fixed in this branch:** a thread race. `Tree.decls` could hand two threads
    different declaration lists, and `gen_dup_existing` compares declarations
    by identity, so on 4 threads it could offer the excerpt's own declaration
    as its twin. Five of 3,390 fixture evidence entries differed between
    threaded runs.
  - **Fixed in this branch:** a `set` iteration in `gen_comment_stale`.
  - **Fixed in this branch:** a shared temporary file in the evidence cache.
  - **Still open:** `similar_decls` (`dup.in-diff`, `dup.cross-file`) and
    `gen_comment_stale` still depend on the process's string-hash order,
    through iteration over a set of names. That makes 12 of the 592 units'
    evidence differ between processes, which is why they are excluded. The
    cache hides this within one tree.
- **Budget.** The budget stopped the baseline 26 units short. Audits are 30 and
  6, against the planned 40.
- **Scoring.** The anchor clause credits a finding anywhere in a unit whose
  anchor names the item's declaration. Merged units make that generous for
  positives and harsh for controls (see the sensitivity line above).
- **Labels.** Clean commits are unlabelled, not certified clean. "Unlabelled"
  is volume, and the audit says most of it is real.
- **Proof that the default is unchanged.** At `PYTHONHASHSEED=0`, the base code
  (single-threaded) and this branch (4 threads) were dumped and compared with
  `cmp`. Every artefact matched byte for byte:
  - `EV.generate` for all 3,390 (fixture, generated class) pairs;
  - the battery requests for all 535 fixture units, with the prompt cache on
    and off;
  - review.py's units, battery requests and all 47 per-class confirm requests
    for `3f3e63a12` (15 units) and `e5a3d0380` (54 units).

  The base copy carried the one-line `sorted` fix. With the defaults,
  review.py's prompts are unchanged.

## Test-run estimate (not run)

The test plan is 789 units: 201 item, 407 other, 181 clean. At dev's measured
costs:

| arm or step | estimate |
|---|---:|
| baseline, $0.0057 per unit | $4.50 |
| g1, $0.0016 per unit | $1.25 |
| g2, g2-exempt, fixed | $0 |
| Opus audit, 40 baseline findings | $1.80 |
| Opus audit, about 20 fixed-arm new findings | $0.90 |
| **total** | **about $8.50** |

- The total is over the $5 that the style-rule skill says to ask Val about.
- On a shared box with `--jobs 4`, the runs take about 2.5 hours, plus about
  40 minutes of evidence generation.
- `diffbench.py estimate --splits test` gives the unit counts without asking
  any model.
- `run` and `audit` on test refuse without `--approved`.

## Reproduce

Run from the repository root, with `D="python3 -I scripts/review_bench/diffbench.py"`:

```sh
$D map
$D plan
$D run --split dev --arm baseline --max-usd 3.40
for arm in g2 g2-exempt g1 fixed; do $D run --split dev --arm $arm --units-of baseline; done
$D audit --split dev --arm baseline --n 30
$D audit --split dev --arm fixed --new-against baseline --n 6
$D report --split dev --arms baseline g2 g2-exempt g1 fixed
```
