# Stage-1 evidence generation, 2026-10-17

What a judge does when nobody curates its evidence. The same Haiku and Jev
prompts as `RESULTS-2026-10-17b.md` (fixtures and rubric after the first
adjudication pass), run three ways: `none` (excerpt only), `curated` (the
fixtures' hand-written `evidence_refs`), and `generated` (what `evidence.py`
finds from the item's file, sha and excerpt). Classes: the five with the most
non-local positives plus `magic-literal`. These numbers describe this
generator, these prompts and these labels; rerun rather than quote.

Generator structure was iterated on dev only, then frozen; test was run once
per mode. Haiku with 2 dev shots, `--jobs 4`.

## Haiku, test split (87 positives, 34 controls, 6 judgment items excluded)

| evidence | recall | FPR | precision | cost per item |
|---|---:|---:|---:|---:|
| none | 0.38 | 0.06 | 0.94 | $0.00093 |
| curated | 0.84 | 0.09 | 0.96 | $0.00110 |
| generated | 0.70 | 0.18 | 0.91 | $0.00120 |

| class | pos/ctl | none | curated | generated |
|---|---:|---|---|---|
| `comment.stale` | 18/7 | 0.17 / 0.00 | 0.67 / 0.00 | 0.44 / 0.00 |
| `dead.code` | 9/2 | 0.11 / 0.00 | 0.56 / 0.00 | 0.56 / 0.50 |
| `dup.cross-file` | 11/9 | 0.18 / 0.00 | 1.00 / 0.11 | 0.91 / 0.11 |
| `dup.existing` | 21/5 | 0.67 / 0.20 | 0.95 / 0.20 | 0.71 / 0.40 |
| `dup.in-diff` | 23/7 | 0.35 / 0.14 | 0.87 / 0.14 | 0.83 / 0.29 |
| `magic-literal` | 5/4 | 1.00 / 0.00 | 1.00 / 0.00 | 0.80 / 0.00 |

Cells are recall / FPR. Per class, two to nine controls make every FPR a
handful of items.

By `evidence_scope` of the positive (recall):

| evidence | local (15) | file (34) | repo (38) |
|---|---:|---:|---:|
| none | 0.93 | 0.35 | 0.18 |
| curated | 1.00 | 0.82 | 0.79 |
| generated | 1.00 | 0.65 | 0.63 |

## Haiku, dev split (37 positives, 21 controls)

| evidence | recall | FPR | cost per item |
|---|---:|---:|---:|
| none | 0.49 | 0.05 | $0.00093 |
| curated | 0.95 | 0.10 | $0.00109 |
| generated | 0.89 | 0.19 | $0.00125 |

## Jev, test split (flag at P >= 0.5)

| evidence | recall | FPR | AUC | cost per item |
|---|---:|---:|---:|---:|
| none | 0.32 | 0.06 | 0.72 | $0.00005 |
| curated | 0.62 | 0.06 | 0.89 | $0.00006 |
| generated | 0.66 | 0.21 | 0.81 | $0.00007 |

## Generator recall against curated refs (no model)

Positives whose curated refs resolve (refs into docs or skills excluded). A
generated ref covers a curated one when it names the same file and
declaration or overlapping lines; a fact-only curated ref is covered by a
generated fact naming the same thing.

| class | dev: refs covered | dev: items with one | test: refs covered | test: items with one |
|---|---:|---:|---:|---:|
| `comment.stale` | 7/11 | 6/8 | 7/27 | 7/14 |
| `dead.code` | 1/1 | 1/1 | 4/15 | 3/8 |
| `dup.cross-file` | 4/5 | 3/3 | 9/18 | 7/10 |
| `dup.existing` | 2/3 | 2/3 | 5/24 | 5/16 |
| `dup.in-diff` | 5/7 | 4/6 | 16/29 | 11/17 |
| `magic-literal` | 1/1 | 1/1 | 1/7 | 1/3 |
| **all** | 20/28 | 17/22 | 42/120 | 34/68 |

Generated evidence averages about 190 to 240 tokens per item (characters / 4),
which with the longer prompt is the $0.0001 to $0.0002 per item over `none`.

## What the run says

- **Generated evidence closes about 70% of the gap.** Haiku recall goes from
  0.38 with the excerpt alone to 0.70 with generated evidence, against 0.84
  with curated evidence. On file- and repo-scope positives it goes from 0.35
  and 0.18 to 0.65 and 0.63. `dup.cross-file` and `dup.in-diff` are nearly at
  the curated level; `comment.stale` and `dup.existing` are not.
- **It doubles the false-positive rate**, 0.09 to 0.18 on 34 controls (three
  more flags). Similar-code candidates make a judge see duplication in
  controls that keep a near-twin on purpose, and a candidate list makes it
  more willing to call a helper a reimplementation. One `dead.code` control
  flagged with generated evidence (RB-0126) is a correct finding: its import
  list still names `runCheck` and `checkHasErrors`, which the file uses only in
  comments at that sha. The fixture is probably wrong, not the judge.
- **The dev numbers overstate the generator.** Its recall against curated refs
  was 20/28 on dev and 42/120 on test: 22 dev positives with resolvable refs
  were too few to iterate on without fitting them. Test recall against curated
  refs is lower than the judge's recall gain suggests, because a generated ref
  that is not the curated one is often still enough (a different near-twin, the
  definition behind an absent name).
- **Jev gains as much as Haiku from generated evidence and loses more
  precision.** Recall 0.32 to 0.66 (above curated, 0.62), FPR 0.06 to 0.21, AUC
  0.81 against 0.89 curated: its score rises on controls whenever a candidate
  looks similar.
- **Cost is not the constraint.** Generation is local `git` work (a few
  seconds per item uncached, mostly parsing large files); the extra evidence
  costs about 9% over curated per Haiku call.

## Caveats

- Curated evidence is optimistic by construction, and after adjudication more
  so: the adjudicator added facts written knowing the answer ("the names
  survive only in comments"). The curated rows are a ceiling for stage 1, not
  a baseline.
- Generator structure was iterated on dev before the base branch's
  adjudication pass and checked on dev after it; the test split was seen in
  the fixture survey that shaped the generator classes, but no generator rule
  was tuned against a test item's outcome.
- Small classes: `dead.code` has 2 dev and 9 test positives, `magic-literal`
  4 and 5. Read the pooled rows.
- Measured on fixtures, so each item is one excerpt of existing code framed as
  a diff; a real diff unit would add its own hunks as context.
