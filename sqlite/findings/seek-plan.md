# Findings — S-plan (sqlite: seek instead of scan, #2541)

**Status:** CLOSED RECORD. Dated sqlite-dogfood write-up; kept for provenance, not current guidance.

Task: a query planner choosing a rowid/index seek over a scan for single-table
equality WHERE clauses. REFUSED twice on genuine module cycles before landing
in-file (`sqlite/lib/select.mdk`) at `7a89c35ccd21a758d0965c515070fec1cf808b55`.

## F1 — blob equality diverges between the scan filter and the index seek (S0, pre-existing)

- **Category:** compiler-bug — well, library-bug: `sqlite/lib/select.mdk`'s
  `cmpOrder` compares two `CBlob` cells by array length only, not byte
  content, so `WHERE b = X'...'` matches every same-length blob.
  `compareCellsSqlite` (the seek's comparator) compares bytes correctly.
- **Severity:** blocker (S0, silent wrongness) — pre-existing, independent of
  this sprint's diff (untouched by it), but discovered *because* this
  sprint's equivalence law needed the two comparators to agree.
- **Repro:** verified first-hand by the orchestrator against a real
  `sqlite3`-written database at the sprint SHA — see the filed issue.
- **Disposition:** filed as
  [#2573](https://github.com/MedakaLang/medaka/issues/2573) (S0, `verified`).
  Guarded, not fixed, in this sprint: `seekableTarget (LBlob _) = False`
  prevents the planner from ever exposing the divergence through ordinary
  SQL (confirmed unbypassable by the end-of-sprint review); the divergence
  remains reachable by a caller who constructs a `Plan` value directly
  through the exported API rather than through `planFor` — noted in #2573.

## F2 — a second, direct 2-node module cycle blocked the contracted placement

- **Category:** surprising-semantics (module system), and an architecture gap
  in this sprint's own contract, not a compiler bug
- **Severity:** none as a language finding — the packet's placement was wrong
  for this codebase's type layout, not the language's cycle rule
- **Detail:** the contract specified a new `sqlite/lib/plan.mdk`. `Select`,
  `SqlExpr`, and `Literal` are defined *in* `select.mdk`, so any module
  computing a `Plan` from a `Select` must import `lib.select`, while wiring
  the plan into `runPipelineCore` requires the reverse edge —
  `lib.plan → lib.select → lib.plan`, a direct cycle no module ordering
  escapes. Refuted with stub bodies before any real logic was written.
- **Disposition:** not filed — resolved by moving the planner in-file into
  `select.mdk` (a placement deviation from the contract's stated Surface row,
  recorded in NOTES.md and confirmed reasonable by the end-of-sprint
  style-review pass, which flagged only that the contract record should note
  the override rather than that the override was wrong).

## F3 — the scan/filter and index-seek comparators' agreement is an undocumented general invariant, not just a blob-specific exception

- **Category:** surprising-semantics / documentation gap
- **Severity:** annoyance today; would become a real landmine if `cmpOrder`'s
  blob comparison is ever fixed in isolation (see #2573's body)
- **Detail:** the planner's safety invariant ("a plan may only narrow, never
  answer") holds only because `cmpOrder` and `compareCellsSqlite` currently
  agree on equality for every literal the planner is willing to seek on. The
  in-source comment states this for the blob case specifically but not as a
  general rule.
- **Disposition:** fix-now in the sprint's fix round (F1-plan-review-fixes,
  see `reports/F1-plan-review-fixes.md`) — a comment addition, not a behavior
  change.

## F4 — a related, separate engine-vs-`sqlite3` divergence: type affinity is ignored in comparisons

- **Category:** compiler-bug — library-bug, `cmpOrder` again (a different arm)
- **Severity:** S2 (misleading) — both the scan and the seek are wrong in the
  same way, so this sprint's equivalence law holds even though the *answer*
  disagrees with real `sqlite3`
- **Detail:** `WHERE s = 5` on a TEXT-affinity column returns 0 rows from
  Medaka where `sqlite3` returns 1 (SQLite applies TEXT affinity to the
  literal before comparing; Medaka's engine does not apply affinity anywhere).
  Found by the end-of-sprint review, not by this slice.
- **Disposition:** folded into issue #2573's body as a related dependency
  note rather than filed separately — same root function (`cmpOrder`), and a
  fix to one without checking the other could re-break the planner's safety
  invariant from a different direction. Not fix-now: pre-existing,
  independent of this sprint's diff, and affinity handling more broadly is
  out of this sprint's scope (contract §2).
