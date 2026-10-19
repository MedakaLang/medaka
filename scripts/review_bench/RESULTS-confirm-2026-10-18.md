# Battery, then per-class confirm, on test: 2026-10-18

Follows `RESULTS-battery-2026-10-17.md`, which measured the confirm arm on dev
only and audited 25 battery flags. Same fixtures, prompts, generated evidence
and cached battery answers; nothing was tuned between that run and this one.
These numbers describe these prompts and labels; rerun rather than quote.

- **Confirm arm (`verify:battery-pc`):** the Haiku battery runs once per
  excerpt; then the per-class prompt (that class's rule, notes, 2 dev shots,
  that class's generated evidence) is asked of each class the battery flagged,
  and a finding survives only if both flag it. 727 (excerpt, class) pairs on
  test, 189 already cached from the battery run.
- **Audit:** `claude-opus-5-5` judged 100 of the battery's 440 unlabelled test
  flags (fixed seed 20261017), yes / no / unsure, as in the battery run. The
  confirm arm's unlabelled flags are a subset of the battery's, so the one
  audit scores both.

## Test, generated evidence (311 excerpts, 214 positives, 93 controls)

| arm | recall | FPR | unlabelled flags / excerpt | audited precision of those | $ / excerpt |
|---|---:|---:|---:|---:|---:|
| A: Haiku battery | 0.84 (179/214) | 0.13 (12/93) | 1.41 | 0.50 (43 yes, 43 no, 14 unsure) | $0.0027 |
| A, then per-class confirm | 0.76 (163/214) | 0.08 (7/93) | 0.73 | 0.65 (34 yes, 18 no, 5 unsure of 57 kept) | $0.0052 |

Dev for comparison (from the battery run): A 0.83 / 0.23; A then confirm
0.78 / 0.07. The confirm arm held on test within about two points.

## What confirm does to the unlabelled flags (test audit)

| Opus verdict | kept by confirm | dropped by confirm |
|---|---:|---:|
| yes | 34 | 9 |
| no | 18 | 25 |
| unsure | 5 | 9 |

Per excerpt, scaling the audit to the 1.41 unlabelled flags: the battery
reports about 0.61 real, 0.61 wrong and 0.20 unsure extra findings; after
confirm, about 0.48 real, 0.25 wrong and 0.07 unsure. Confirm keeps 79% of the
real extra findings (34 of 43) and removes 58% of the wrong ones (25 of 43).
The dropped set is 26% real (9 of 34 judged), so it is not worth showing as a
second tier. With 100 audited flags each proportion is good to about plus or
minus 0.1. The battery's wrong extra flags concentrate in `dup.in-diff` (9),
`dup.cross-file` (7) and `defensive.silent-default` (5); Opus is one judge,
not the labels.

## What confirm costs

- **Recall:** 16 labelled positives lost on test, 8 on dev, spread over 11
  and 8 classes with no class losing more than 2: `comment.history`,
  `comment.stale`, `idiom.let-underscore-unit`, `dead.code` and `dup.existing`
  two each on test. No class is systematically blinded, so there is no
  per-class carve-out to make, and choosing one from these counts would tune
  on test.
- **Money and time:** $0.0052 per excerpt against $0.0027, and about 23 Claude
  seconds against 12 (2.3 per-class calls per excerpt on top of the battery).

## Spend

Haiku $0.58 for the 538 uncached confirm calls; Opus audit $4.22. Total $4.80.

## Reproduce

From the repository root, with `B="python3 -I scripts/review_bench/battery.py"`
and the battery run's cache present:
`$B perclass --which flagged --base battery-pc --split test --evidence generated`,
`$B audit --arm battery-pc --n 100 --split test --evidence generated`,
`$B report --split test --evidence generated --arms battery-pc verify:battery-pc`.
