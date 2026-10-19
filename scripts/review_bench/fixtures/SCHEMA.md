# Review-benchmark fixtures: schema

`fixtures.jsonl` holds one JSON object per line. Each object is one labelled
excerpt of real Medaka source, pinned to a commit. Classes and rules are those of
`docs/design/STYLE-RUBRIC.md`; the rulings (`R1` onward) are the project
owner's, recorded in `docs/design/STYLE-RULINGS.md`. `STATS.md` has the
counts.

## Fields

| field | type | meaning |
|---|---|---|
| `id` | `"RB-0001"`… | Stable identifier. New items are appended; ids are never reused. |
| `polarity` | `positive` \| `control` \| `judgment` | A reviewer must flag it; must not flag it; or is scored neither way. |
| `class` | rubric slug | For a control, the class it is a control *for*. |
| `control_kind` | string \| null | Controls only: `exception` (a rubric exception), `after-fix` (the fixed state of a positive, which must be clean for its class; a fix that left a defect of the class behind makes the item `judgment`), `declined` (raised in a past review and ruled not a defect), `clean` (ordinary code the class could tempt a reviewer to flag). |
| `ruling` | `"R14"` \| null | The ruling that governs the class or this instance; null for the classes established before the rulings. |
| `severity` | `high` \| `medium` \| `low` \| null | Positives only. |
| `summary` | string | One sentence: what a correct reviewer says, or why the item must not be flagged. |
| `file`, `anchor` | string | Repo path, and the enclosing top-level declaration (stable across line drift). |
| `sha`, `lines` | string | Full commit SHA; `start-end` line range at that SHA. |
| `excerpt` | string | Byte-exact `git show <sha>:<file>` lines `start..end`, at most 40 lines. |
| `evidence_scope` | `local` \| `file` \| `repo` | Whether the excerpt alone suffices, or the judge needs more of the file or other files. |
| `evidence_refs` | list | `{file, anchor, sha, lines, excerpt, note?}` for the code a judge needs (the original being duplicated, the contradicting code). `excerpt` is `""` when the reference is a whole module or could not be resolved; `note` says which. |
| `label_strength` | `val` \| `fixed` \| `declined` \| `reviewed` \| `candidate` | `val`: a ruling on this exact instance. `fixed`: a fix round changed it as asked (after-fix controls carry `fixed` too). `declined`: ruled not a defect in a past review. `reviewed`: a candidate a second reader checked against the rulings after the judges contested it. `candidate`: a miner's or scanner's judgment against the rubric, pending review. |
| `source` | `{kind, ref}` | `kind` is `style-report` (end-of-sprint review), `file-mining` (one file read end to end), `val-ruling`, `scan` (found with a scan script or grep while applying a ruling), or `derived` (a second class read off a mined item's excerpt or fix state; `ref` is the original's source). |
| `fix` | object \| null | `{sha, file, lines, excerpt_after}` for a positive whose fix landed. `file` differs from `file` above when the fix moved the code. |
| `split` | `dev` \| `test` | See below. |
| `also_present` | list of slugs | Other classes this excerpt also exhibits. A finding of one of these classes on this item is not a false positive; score per class. |
| `notes` | string | Provenance of the label, relabelling history (`Mined as …`), doubts. |

## Scoring

Score per class. A positive of class C is a miss if the reviewer raises no
class-C finding on it. A control of class C is a false positive if the reviewer
raises a class-C finding on it; findings of other classes on a control are
scored against `also_present` (allowed) or as ordinary false positives
(not listed). Judgment items count neither way. Several items share one
excerpt when the excerpt exhibits several classes; each is scored for its own
class only.

## Splits

Items are grouped by source: one sprint report, one mined file, or one new
ruled instance or scan find. Groups are then joined when they share a
`(file, anchor)` or overlapping lines at one SHA, so the same code never lands in
both splits. Groups are ordered by a SHA-1 hash of their smallest source key;
`dev` takes groups in that order until it holds 40% of the items. Last, any class
with positives but none in `dev` gets its smallest group moved to `dev`, so every
class has a few-shot example. Use `dev` for prompts and thresholds, `test` for
reporting.

## Relabelling the mined candidates

The 326 mined records predate the rubric. They were mapped to rubric slugs
(for example `perf.list-as-set` became `data.container`, sentinel-arm
`magic-literal` became `data.sentinel`, plan ids became `comment.provenance`)
and re-judged against the rulings; the ruling wins over a mined label. Flipped
items say so in `notes`. Records about markdown documents, typos, and findings
with no rubric class were dropped (19 records).

## Caveats

- Review is diff-scoped; most excerpts are existing code shown as if under
  review. `module.scattered-concern` and `test.gap` need diff fixtures.
- `candidate` labels are unreviewed. Treat precision measured on them as an
  estimate until the owner confirms them.
