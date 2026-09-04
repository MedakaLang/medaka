# Findings — S-index-pages (sqlite: seek instead of scan, #2541)

**Status:** CLOSED RECORD. Dated sqlite-dogfood write-up; kept for provenance, not current guidance.

Task: decode index-leaf (`0x0A`) and index-interior (`0x02`) b-tree pages in
`sqlite/lib/btree.mdk`. Landed `45d8be5bc03058ef450445239051587778734fd7`.

## F1 — SQLite index b-trees are a B+tree exception: interior cells carry real keys

- **Category:** surprising-semantics (of the on-disk format, not the language)
- **Severity:** none — a design fact, not a defect
- **Detail:** a SQLite *table* b-tree is a pure B+tree: interior cells are
  routing-only (max-rowid-in-left-subtree, no payload). An *index* b-tree is
  NOT — interior cells carry the same `(key, rowid)` record a leaf cell does,
  plus the leading left-child pointer. Missing this would have made the
  decoder silently drop every key stored at an interior level.
- **Verified:** corroborated byte-for-byte against a real, `dbstat`-confirmed
  interior page from a 301-entry index `sqlite3` wrote (Gate 10,
  `sqlite/test/index_write_oracle.sh`).
- **Disposition:** not-a-finding requiring action — this is the central
  technical fact the slice exists to discover and encode; it is now
  documented in `sqlite/lib/btree.mdk`'s comments and gated by Gate 10.

## F2 — a design site not named in the packet was needed and added

- **Category:** ergonomics (packet/contract completeness, not a compiler bug)
- **Severity:** none
- **Detail:** the packet named only `sqlite/lib/btree.mdk` as the surface, but
  the acceptance checks needed a way to open a `Db` and scan an index by
  name — added `findIndex`/`scanIndexRows` to `sqlite/lib/sqlite.mdk`,
  mirroring the existing `findTable`/`scanTableRows`.
- **Disposition:** not-a-finding — judged in-slice as "answers the same
  question as the named sites," recorded in NOTES.md at the time, not
  contested by the end-of-sprint review.
