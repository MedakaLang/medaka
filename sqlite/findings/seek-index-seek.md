# Findings — S-index-seek (sqlite: seek instead of scan, #2541)

**Status:** CLOSED RECORD. Dated sqlite-dogfood write-up; kept for provenance, not current guidance.

Task: given a table and an equality on a column, find the serving index and
fetch matching rows. Landed `e6f4f15f064e9ce321d7f41efd2d6c36a9bd7d11`.

## F1 — `NULL = NULL` under `compareCellsSqlite` resolves `Eq`, needing an explicit guard

- **Category:** surprising-semantics (library-internal, not language/compiler)
- **Severity:** none — caught and guarded in-slice before landing
- **Detail:** `compareCellsSqlite CNull CNull = Eq` (consistent with its use as
  a total ORDER for index-entry sorting, where NULLs must sort together), but
  SQL's `x = NULL` is never true. `seekByIndex` needed an explicit
  `isNullTarget` guard returning `Ok []` before walking the index, or it would
  silently "find" every NULL-keyed row for a `= NULL` target.
- **Disposition:** not-a-finding requiring further action — fixed in-slice,
  confirmed correct by the end-of-sprint review against a real `sqlite3`
  index with a NULL-keyed entry (`REVIEW.md`, property class 1).

## F2 — `servesColumn` conservatively refuses any index `parseCreateIndex` can't parse

- **Category:** surprising-semantics / missing feature (write-side surface,
  not this slice's scope)
- **Severity:** workaround-required only in the sense that a real multi-column
  or partial index's leading column gets no seek, correctly falling back to a
  scan
- **Detail:** `parseCreateIndex` (from `S-index-pages`'s writer-side sibling)
  refuses UNIQUE, multi-column, partial (`WHERE`), `COLLATE`, and `DESC`
  indexes. `servesColumn` inherits that refusal, so any such index is
  correctly invisible to the planner rather than mis-served.
- **Disposition:** not filed — correct-but-conservative behavior, confirmed
  safe by the end-of-sprint review (`REVIEW.md`, "index shapes
  `parseCreateIndex` must refuse"). `CREATE INDEX` surface widening is
  explicitly out of this sprint's scope (contract §2); a future sprint
  widening the write-side parser would need no change here — the planner
  would simply start serving more shapes as `parseCreateIndex` accepts them.

## F3 — this sprint's index fixtures were all single-leaf; multi-leaf duplicate-key correctness was argued, not proven

- **Category:** tooling (test coverage gap, not a compiler or library bug)
- **Severity:** none — the underlying code was correct
- **Detail:** at landing time, every index fixture in the sprint fit on one
  index-leaf page, so duplicate keys spanning a real multi-leaf boundary were
  correct "by construction" (`scanIndexPage` already concatenates interior
  children in key order) but untested by any fixture.
- **Disposition:** RESOLVED by the end-of-sprint review, not filed as an
  issue — the reviewer built two real `sqlite3` multi-leaf indexes (2,000
  entries / 38 pages; 1,500 entries / 31 pages with 500-row duplicate runs
  spanning ~10 leaves) and found byte-identical decode and zero seek
  failures across a 205-key sweep. The gap was in the fixtures, not the code.
