# SQL JOIN family (CROSS / RIGHT / FULL) — dogfood findings

Completing the JOIN family in the `sqlite/` dogfood engine: `CROSS JOIN`,
`RIGHT [OUTER] JOIN`, `FULL [OUTER] JOIN` threaded through parser → AST → renderer
→ executor. Pure-Medaka library change; no compiler edits.

## BLOCKER — a forbidden-file assertion the feature invalidates (needs orchestrator action)

`sqlite/test/alias_test.mdk:79-82` asserts:

```
test "RIGHT JOIN is rejected, not swallowed as a table alias" =
  expectEqual
    (map renderSelect (parseSelect "SELECT a FROM t RIGHT JOIN u ON t.x = u.y"))
    (Err "unsupported SQL: 'RIGHT' at 22")
```

This feature makes `RIGHT JOIN` **parse** (it now yields
`Ok "SELECT a FROM t RIGHT JOIN u ON (t.x = u.y)"`), so this assertion is now
false and the `gates (sqlite)` shard's in-language suite (`inlang_test_oracle.sh`)
will go **red** on it.

`sqlite/test/*_test.mdk` was placed **off-limits** for this task ("verify via
doctests + `sql_oracle.sh`, NOT the in-language suite"), so per the instruction
to STOP and report on a forbidden file, I did **not** edit it. It is the SINGLE
blocking assertion (a tree-wide scan of every `*_test.mdk` + `inlang_test_oracle.sh`
for `CROSS`/`RIGHT`/`FULL`/`OUTER` found only this one).

**Required fix (one test):** the check's *intent* — "`RIGHT` is not swallowed as a
table alias" — is still worth keeping; only the verdict changed. Two options:
- retarget it at a still-rejected keyword, e.g.
  `parseSelect "SELECT a FROM t NATURAL JOIN u ON t.x = u.y"` →
  `Err "unsupported SQL: 'NATURAL' at 24"` (still exercises the not-an-alias path); or
- flip it to a positive: `RIGHT JOIN` now round-trips to
  `Ok "SELECT a FROM t RIGHT JOIN u ON (t.x = u.y)"`.

**This is the recurring shape of "a feature that flips a REJECTED case to ACCEPTED
owes an update to every test asserting the rejection" — and here those tests were
carved out of the owned set, so the owner cannot self-drain them.** The rejection
assertion lives in three places; two were mine to fix and I did (`sql_probe.mdk`
rejects corpus, `sql_oracle.sh` REJECTS array), the third is off-limits.

## Language / tooling dogfood notes

- **Positive: extending a `deriving (Eq, Debug)` ADT and threading it through `match`
  was frictionless.** Adding `JRight`/`JFull`/`JCross` to `JoinKind` and letting the
  exhaustiveness checker point me at every `match joinKind` / `joinKindText` /
  `joinKindSql` arm that needed a new case is exactly the dogfood story you want —
  the type system did the "did I miss a site?" bookkeeping. No silent fall-through.

- **`medaka check <single-library-file>` dumps the whole inferred interface to
  stdout** (dozens of `name : Type` lines) rather than a terse "ok" / silence. On a
  file with zero errors it is ambiguous whether that dump *is* the success signal or
  a warning of some kind; I ended up piping through
  `grep -iE 'error|unbound|mismatch|expected'` to confirm a clean check. A one-line
  "N declarations checked, 0 errors" summary (or reserving stdout for diagnostics)
  would read better. Minor S3 ergonomics.

- **`Join.on : SqlExpr` is non-optional, but `CROSS JOIN` has no `ON`.** I stored a
  placeholder `ELit (LInt 1)` that the executor never evaluates (JCross → product)
  and both renderers omit. This keeps the `Join` record shape stable and INNER/LEFT
  byte-identical, but the honest model would be `on : Option SqlExpr`. Not a language
  bug — a pre-existing library design point; flagging it as the tidier refactor if
  someone revisits `Join`.

- **`sqlite3` (3.46.1) leniently ACCEPTS an `ON` on `CROSS JOIN`** and treats it as a
  filter (`A CROSS JOIN B ON p` == `A INNER JOIN B ON p`). This engine follows the SQL
  standard instead: `CROSS JOIN` takes **no** `ON`; a stray `ON` after `CROSS JOIN t`
  is left unconsumed and surfaces as a loud downstream parse error. This is a
  deliberate accept-side divergence only — the oracle never feeds `CROSS ... ON` to
  either engine, so no row output diverges. Documented at `joinCondition` in
  `sqlstmt.mdk`.

## Harness friction (not Medaka — the agent sandbox)

The worktree-isolation classifier refused several ordinary `bash` invocations as
"too complex to verify it stays inside the worktree" — specifically any compound
command containing a `>` redirect, a `cd`, or `git rev-parse --show-toplevel`. Each
had to be rewritten as a single plain command with the absolute worktree path
hardcoded. Repeated, mild; noting because the task said to log tooling friction of
any size. (Also: the shared scratchpad meant a sibling agent's build log clobbered
mine at the same path — used a private subdir after that.)

## What was verified (all green, on the freshly cold-bootstrapped binary)

- `medaka test sqlite/lib/sqlstmt.mdk` → 38/38 (incl. new RIGHT/FULL/CROSS
  round-trip doctests); `sqlite/lib/select.mdk` → 26/26.
- `sql_oracle.sh` → **192 queries / 0 diffs** vs `sqlite3`, 35 rejections clean,
  round-trip 82/82, shape 12/12. The +16 new JOIN-family queries cover: CROSS
  product sizes + CROSS-with-WHERE + CROSS-with-aliases; RIGHT with unmatched-right
  (NULL left cols) in both a synthetic and the realistic schema; FULL with orphans
  on BOTH sides; a multi-row/multi-column case; and `count(*)` over a join.
- No regression: `join_oracle.sh`, `left_join_oracle.sh`, `select_oracle.sh`,
  `projection_oracle.sh`, `groupby_oracle.sh` all still PASS (INNER/LEFT byte-identical).
- `medaka fmt --check` clean; `medaka lint sqlite` → 0 findings.
