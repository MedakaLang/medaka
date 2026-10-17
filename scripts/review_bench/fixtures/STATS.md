# Fixture statistics

Generated from `fixtures.jsonl`. Counts are items; one excerpt can carry items of several classes.

Total 565 items: 231 dev (40%), 334 test.

| | positive | control | judgment | total |
|---|---|---|---|---|
| val | 70 | 16 | 3 | 89 |
| fixed | 90 | 77 | 7 | 174 |
| declined | 0 | 4 | 4 | 8 |
| candidate | 206 | 72 | 16 | 294 |
| **all** | 366 | 169 | 30 | 565 |

Source kinds: `derived` 8, `file-mining` 97, `scan` 163, `style-report` 210, `val-ruling` 87.

## By class

Positives, controls and judgments as dev/test; `val`, `fixed`, `cand` count positives by label strength.

| class | pos dev/test | val | fixed | cand | ctrl dev/test | judg |
|---|---|---|---|---|---|---|
| `data.sentinel` | 6/3 | 1 | 0 | 8 | 0/0 | 0 |
| `data.bool-blind` | 3/2 | 2 | 0 | 3 | 1/0 | 1 |
| `data.stringly-error` | 3/2 | 2 | 0 | 3 | 3/0 | 0 |
| `data.clone-type` | 1/0 | 1 | 0 | 0 | 2/4 | 1 |
| `data.param-clump` | 1/4 | 1 | 0 | 4 | 0/0 | 1 |
| `data.tuple-as-record` | 3/2 | 2 | 0 | 3 | 3/0 | 0 |
| `data.string-enum` | 1/3 | 3 | 0 | 1 | 2/1 | 0 |
| `data.string-key` | 1/4 | 3 | 0 | 2 | 1/0 | 0 |
| `data.container` | 3/3 | 3 | 0 | 3 | 0/3 | 2 |
| `iface.underused` | 3/2 | 2 | 0 | 3 | 0/3 | 0 |
| `shape.do-cascade` | 2/5 | 3 | 0 | 4 | 1/2 | 2 |
| `shape.nested-match` | 2/3 | 1 | 0 | 4 | 0/0 | 0 |
| `shape.threaded-invariants` | 1/3 | 1 | 0 | 3 | 1/2 | 0 |
| `idiom.inside-out-pipeline` | 3/2 | 1 | 0 | 4 | 1/2 | 0 |
| `idiom.let-underscore-unit` | 1/3 | 0 | 0 | 4 | 0/3 | 0 |
| `defensive.discarded-result` | 5/1 | 1 | 0 | 5 | 0/0 | 0 |
| `dup.existing` | 12/22 | 7 | 5 | 22 | 3/5 | 3 |
| `magic-literal` | 4/5 | 4 | 0 | 5 | 0/4 | 0 |
| `suppress.invalid-reason` | 5/1 | 4 | 1 | 1 | 3/3 | 2 |
| `module.scattered-concern` | 0/0 | 0 | 0 | 0 | 0/0 | 1 |
| `comment.history` | 14/21 | 2 | 13 | 20 | 6/4 | 0 |
| `comment.provenance` | 7/12 | 2 | 7 | 10 | 2/4 | 5 |
| `comment.measurement` | 7/5 | 3 | 3 | 6 | 3/1 | 0 |
| `comment.restates` | 2/2 | 0 | 0 | 4 | 1/8 | 2 |
| `comment.ephemeral` | 1/4 | 1 | 1 | 3 | 0/1 | 0 |
| `comment.speculative` | 1/3 | 1 | 0 | 3 | 0/3 | 0 |
| `comment.shout` | 3/5 | 2 | 0 | 6 | 1/2 | 0 |
| `doc.register` | 0/0 | 0 | 0 | 0 | 4/3 | 4 |
| `test.weak-reject` | 3/2 | 1 | 0 | 4 | 1/0 | 0 |
| `test.bool-helper` | 3/1 | 1 | 0 | 3 | 0/0 | 1 |
| `test.length-not-contents` | 3/2 | 2 | 0 | 3 | 2/1 | 0 |
| `test.escaped-program` | 1/3 | 2 | 0 | 2 | 0/1 | 0 |
| `test.hand-count` | 3/2 | 2 | 0 | 3 | 1/2 | 0 |
| `test.probe-in-production` | 2/2 | 1 | 0 | 3 | 1/2 | 0 |
| `test.repeated-columns` | 1/1 | 1 | 0 | 1 | 0/0 | 0 |
| `test.doctest-costume` | 3/1 | 2 | 1 | 1 | 2/1 | 0 |
| `test.vehicle` | 3/4 | 5 | 0 | 2 | 2/1 | 1 |
| `comment.stale` | 8/19 | 0 | 17 | 10 | 7/7 | 1 |
| `comment.layout` | 4/6 | 0 | 5 | 5 | 3/0 | 0 |
| `dup.in-diff` | 8/23 | 0 | 12 | 19 | 5/7 | 0 |
| `dup.cross-file` | 3/11 | 0 | 11 | 3 | 4/9 | 1 |
| `dead.code` | 2/9 | 0 | 4 | 7 | 2/2 | 1 |
| `naming.misleading` | 2/3 | 0 | 4 | 1 | 1/1 | 0 |
| `defensive.silent-default` | 4/1 | 0 | 2 | 3 | 2/2 | 0 |
| `defensive.redundant` | 0/0 | 0 | 0 | 0 | 0/0 | 1 |
| `diag.quality` | 1/5 | 0 | 4 | 2 | 0/4 | 0 |
| `test.gap` | 0/0 | 0 | 0 | 0 | 0/0 | 0 |

## Below target

Targets: four or more positives per class; three or more controls where the rubric names an exception; one dev positive per class.

- `data.clone-type`: 1 positive. Why: the tree has few unsuppressed Option/Result clones; most two-case types are domain states (now controls).
- `data.string-key`: 1 control for a named exception. Why: serialization-boundary keys with a matching parser are rare in the tree.
- `module.scattered-concern`: 0 positives, 0 controls for a named exception. Why: the class is about a diff adding a concern to the wrong file; existing disorganization is census, not review (R24), so item-level positives need diff fixtures.
- `doc.register`: 0 positives. Why: stdlib doc comments were cleaned up under the 2026-10-11 rule; no clear implementation narration was found, only judgment cases.
- `test.repeated-columns`: 2 positives. Why: only the two verdict tables R43 describes exist.
- `defensive.redundant`: 0 positives. Why: no mined or scanned instance clear enough to label; one judgment item.
- `test.gap`: 0 positives. Why: needs the diff that added untested behaviour; no excerpt-level instance.
