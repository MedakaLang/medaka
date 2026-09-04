# Findings — S-rowid-seek (sqlite: seek instead of scan, #2541)

**Status:** CLOSED RECORD. Dated sqlite-dogfood write-up; kept for provenance, not current guidance.

Task: descend the table b-tree to one rowid instead of scanning. Landed
`f728135d9d52d76ae7ddc193052c78e02ad9494f`.

## F1 — `test "name \{expr}"` (string interpolation in a test name) is a misleading parse error

- **Category:** error-message (misleading diagnostic)
- **Severity:** annoyance — workaround is trivial (don't interpolate the name)
  once you know the cause, but the message actively points at the wrong fix
- **Repro:**
  ```medaka
  x = 3
  test "name \{intToString x}" =
    expectEqual 1 1
  ```
  ```
  error: ...:3:0: `test` is a reserved keyword — it can't be used as a
  variable or pattern name. Rename it (e.g. `test_`).
  ```
  A plain string-literal test name works fine; interpolation is the trigger.
- **Disposition:** filed as
  [#2574](https://github.com/MedakaLang/medaka/issues/2574) (S2, `verified` —
  reproduced first-hand by the orchestrator at the sprint SHA
  `7a89c35ccd21a758d0965c515070fec1cf808b55`).

## F2 — the interpreter's per-leaf decode cost scales with rows-per-leaf, real under `medaka test`

- **Category:** ergonomics / tooling (test-fixture-writing friction, not a
  compiler bug)
- **Severity:** workaround-required for anyone writing a large in-language
  fixture
- **Detail:** a 700-unpadded-row table-b-tree fixture made a seek-verification
  loop (`medaka test`) run 3+ minutes at 110%+ CPU — not an infinite loop, but
  `decodeLeafPage`-per-seek cost scaling with rows-per-leaf under the
  tree-walking interpreter. Fixed in-slice by shrinking the fixture to 30
  padded rows (still a real interior-rooted tree, still full coverage),
  cutting the run to ~7.4s.
- **Disposition:** not filed — perf is explicitly out of this sprint's scope
  (contract §2), and the fix (a smaller, carefully-constructed fixture) is the
  correct response to an interpreter performance *characteristic*, not a bug.
  Flagged here for a future `perf-hunt` pass on `medaka test`'s cost model if
  large in-language fixtures become common.
