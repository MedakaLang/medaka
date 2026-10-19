# Diff level, one declaration per unit, dev split: 2026-10-18

This pass adds the `onedecl` arm to `diffbench.py`: `review.py`'s funnel with
`--one-decl` cutting, everything else as in the baseline of
`RESULTS-diffs-dev-2026-10-18.md`. It ran on the **dev split only**. The test
split was not run; its estimate is at the end. These numbers describe these
prompts, labels and samples; rerun them rather than quote them.

**Question.** On dev, diff-level review scored recall 0.61 and FPR 0.19, against
0.79 and 0.08 at item level on the same items. 218 of the 580 compared units
merge adjacent touched declarations. The hypothesis was that one declaration
per unit recovers much of that gap, at some cost per changed line.

**Answer: it does not.** Recall and FPR stay where they were. Unlabelled
findings per 100 changed lines rise by half, and cost per 100 changed lines by
half.

## Setup

- **Code:** branch `review-bench-onedecl` from `c68ace6ab`, with the previous
  pass's model and evidence cache. Seed 20261018 and the plan are unchanged.
- **Units:** each of the baseline's compared units is cut with
  `review.cut_units(..., merge=False)` over the same commit and file. Its pieces
  are the one-declaration units inside it. A piece takes its parent's kind
  (item, other, clean), so both arms count the same changed lines under each
  kind.
  - All 580 parents and all their changed lines are covered: no changed line of
    a parent falls outside its pieces.
  - The 362 single-declaration parents are their own piece. All 362 were served
    from the baseline's cache: their prompts are byte-identical and their new
    spend was $0.
  - The 218 merged parents become 776 pieces.
- **Exclusion:** the 12 evidence-nondeterministic units the previous pass left
  out stay out. They are mapped onto their pieces: the arm's parents are the
  baseline's 580 compared units, so no piece of an excluded unit is reviewed.
- **Budget cut:** all 580 parents would be 1,138 pieces, 767 of them uncached,
  estimated at $2.76 against the $2.00 cap. So only the pieces of the **item
  and clean** parents were reviewed: 270 parents (141 item, 129 clean), 117 of
  them merged, giving **583 pieces**, 430 of them new. The other units of the
  labelled commits (310 parents) were not reviewed in this arm.
- **Comparison:** `report` compares arms on parent units. Both arms below are
  on the same 270 parents, 4,631 changed lines, 111 positives and 59 controls.
  The baseline scores 67/111 here rather than 68/111 on all 580 units. One
  positive was credited by a finding in a neighbouring "other" unit within the
  2-line slack.

## Headline

| arm | units | recall | FPR | unlabelled per 100 changed lines | $ per 100 changed lines |
|---|---:|---:|---:|---:|---:|
| item level, same items | | 0.79 (88/111) | 0.08 (5/59) | | |
| baseline | 270 | 0.60 (67/111) | 0.19 (11/59) | 6.87 (318/4,631) | $0.035 |
| onedecl | 583 | 0.59 (66/111) | 0.19 (11/59) | 10.32 (478/4,631) | $0.052 |

The scoring rule matters. Without the anchor clause, so that only the line
test counts, baseline scores 61/111 and 9/59 and onedecl scores 66/111 and
10/59. The anchor clause credits a finding anywhere in a merged unit whose
anchor names the item's declaration. That is worth 6 positives to the baseline
and none to onedecl, whose anchor is a single declaration. Under the line test
alone, cutting finds 5 more positives and hits 1 more control. Under the
report's rule, the two arms are level.

The arms agree on 59 positives. 8 are found only by baseline and 7 only by
onedecl, the size of reshuffle any prompt change causes. Of the 7 found only
by onedecl, 4 were found at item level. Of the 8 found only by baseline, 4 were
too.

### Unlabelled findings and cost by unit kind

| arm | unit kind | units | changed lines | unlabelled | per unit | per 100 changed lines | $ / unit | $ / 100 changed lines |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | item | 141 | 3,183 | 169 | 1.20 | 5.31 | $0.0068 | $0.030 |
| baseline | clean | 129 | 1,448 | 149 | 1.16 | 10.29 | $0.0052 | $0.046 |
| onedecl | item | 357 | 3,183 | 270 | 0.76 | 8.48 | $0.0042 | $0.047 |
| onedecl | clean | 226 | 1,448 | 208 | 0.92 | 14.36 | $0.0041 | $0.065 |

Per unit, onedecl looks quieter and cheaper, because its units are smaller. Per
100 changed lines, the comparable figure, it is noisier and dearer.

The whole difference comes from the merged parents, since a single-declaration
parent is the same unit in both arms:

| parents | baseline: unlabelled per 100 lines | onedecl | baseline: $ per 100 lines | onedecl |
|---|---:|---:|---:|---:|
| 117 merged (2,877 changed lines; 430 pieces) | 7.09 | 12.65 | $0.031 | $0.059 |
| 153 single (1,754 changed lines) | 6.50 | 6.50 | $0.041 | $0.041 |

A new piece costs $0.0039 on average, against $0.0074 for a merged baseline unit
(all 218). Most of a battery call's cost is the rubric prefix, and a merged unit
held 3.7 pieces, so cutting it nearly doubles the cost of its lines. The battery
also finds about as much to say about each small piece as it did about the
merged unit: the unlabelled findings that grow most are `dup.in-diff` (32 to
50), `dup.cross-file` (20 to 48), `dup.existing` (18 to 41) and `test.gap` (26
to 46).

## Why positives are missed

On the same 270 parents. For each missed positive, the cause is the furthest
its class got in the units overlapping it.

| cause of the miss | baseline: item level found it | baseline: item level missed it | onedecl: item level found it | onedecl: item level missed it |
|---|---:|---:|---:|---:|
| battery did not flag the class in the unit | 12 | 11 | 10 | 13 |
| battery flagged it, confirm said no | 7 | 4 | 9 | 3 |
| flagged, but its quote was on unchanged lines (scope filter) | 5 | 2 | 5 | 2 |
| a finding of the class in the unit, but outside the range and anchor | 3 | 0 | 3 | 0 |
| **total** | 27 | 17 | 27 | 18 |

Cutting turns 2 of the 12 "battery never flagged it, item level did" misses
into battery flags, and confirm then rejects them. The battery's attention
being spread over a merged unit is not what loses these positives.

## Control hits

The brief read the 11 baseline control hits as findings from elsewhere in a
merged unit landing on the control. The scoring says otherwise:

- 9 of the 11 are line hits: the finding lies on the control's own mapped
  lines, plus or minus 2. Only 2 come through the anchor clause (`RB-0560`
  `test.vehicle` and `RB-0019` `dup.in-diff`).
- Onedecl hits 11 controls too, 10 of them by line. It clears `RB-0560`, keeps
  `RB-0019` through its single-declaration anchor (the finding is in the same
  declaration, outside the control's range), and adds a line hit on `RB-0004`
  (`defensive.silent-default`).
- 9 of the 11 are clean at item level in both arms.

So the reviewer flags the control's own lines at diff level and not at item
level. The difference lies in what else the unit and its evidence show, not in
the merging.

## Audit

`claude-opus-5-5` judged 6 unlabelled findings that onedecl has and baseline
lacks (`audit --new-against baseline`). The prompt was the previous pass's.

| sample | yes | no | unsure | precision (yes / yes+no) |
|---|---:|---:|---:|---:|
| baseline, 30 of 664 (previous pass) | 25 | 4 | 1 | 0.86 |
| fixed, new vs baseline, 6 of 67 (previous pass) | 3 | 3 | 0 | 0.50 |
| onedecl, new vs baseline, 6 of 236 | 1 | 5 | 0 | 0.17 |

Causes of the 5 onedecl "no"s:

- **The class's rule: 3.** A display string for an absent value flagged as
  `data.sentinel`; a test predicate's `Err _ => False` flagged as
  `defensive.silent-default`; two opposite-offset copy loops flagged as
  `dup.in-diff`.
- **Misread: 1.** A `test.gap` on a function whose body only gained a field.
- **Missing evidence: 1.** A `data.string-key` that turns on a helper's body,
  which the reviewer was not shown.

The one "yes" is a real `data.sentinel` on an empty list standing for a missing
field (`compiler/tools/gate_cost.mdk`). With 6 audited, the proportion is good
to about plus or minus 0.3. A new-against sample is also not like-for-like with
the baseline's whole-pool sample. Still, the extra findings that cutting adds
look mostly wrong.

## Spend

| what | new spend |
|---|---:|
| onedecl run, 583 pieces (430 new, 153 cached at $0) | $1.65 |
| Opus audit, 6 onedecl findings | $0.25 |
| **total** | **$1.90** (cap $2.00) |

The dry run estimated $1.52 at $0.0036 per piece, the baseline's figure for
single-declaration units of at most 20 lines. The real figure was $0.0039 per
new piece. `USD_PER_PIECE` now carries it. The ledger stands at $7.90 of the
file's $8.00 ($6.00 for the first pass, $2.00 for this one).

## Defaults unchanged

This branch changes only `diffbench.py`; `review.py`, `battery.py`,
`evidence.py`, `bench.py`, `items.py` and `rubric.py` are as at `c68ace6ab`. As
in the previous pass, at `PYTHONHASHSEED=0` a copy of `c68ace6ab`'s
`scripts/review_bench` (single-threaded) and this branch (4 threads) dumped
review.py's default units, battery requests and per-class confirm requests for
`e5a3d0380` (54 units, 54 battery and 32 confirm requests) and `3f3e63a12` (15
units, 15 battery and 17 confirm requests), asking no model. The two dumps are
`cmp`-identical. The dump answers from the cache only, so the 5 requests with no
cached answer (the same in both) count as errors there.

## Test-run estimate (not run)

`diffbench.py estimate --splits test` (no model): the test plan is 789 units,
780 of them without a cached battery answer. Cut one declaration per unit, they
are 1,592 pieces: 477 single-declaration units, which are the baseline's own,
and 1,115 new pieces (437 item, 440 other, 238 clean). At dev's measured costs:

| run | model spend | with an Opus audit of 40 unlabelled findings ($1.80) |
|---|---:|---:|
| (a) baseline alone: 780 units at $0.0057 | $4.45 | $6.25 |
| (b) onedecl alone: 477 units at $0.0047 and 1,115 pieces at $0.0039 | $6.59 | $8.39 |
| both arms: baseline, then onedecl's 1,115 new pieces | $8.80 | $10.60 with one audit, $12.40 with one per arm |
| (c) the better alone: baseline, as (a) | $4.45 | $6.25 |

- On this dev evidence, the better arm is the baseline. Onedecl gives the same
  recall and FPR under the report's rule at half again the noise and cost per
  changed line.
- The only case for spending on onedecl at test is the line-only scoring rule,
  where it found 5 more positives on dev.
- Every row but (c) is over the $5 that the style-rule skill says to ask Val
  about.
- On dev, the onedecl run took about 40 minutes for 583 pieces at `--jobs 4`,
  after about half an hour of evidence generation for the new pieces.

## Reproduce

Run from the repository root, with `D="python3 -I scripts/review_bench/diffbench.py"`,
after the previous pass's runs:

```sh
$D run --split dev --arm onedecl --dry-run
$D run --split dev --arm onedecl --roles item clean --max-usd 1.80
$D audit --split dev --arm onedecl --new-against baseline --n 6
$D report --split dev --arms baseline onedecl
$D estimate --splits test
```
