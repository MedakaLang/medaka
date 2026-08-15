# DEBT ledger — Stage B Phase 4/4b implementation

Four fields are MANDATORY per bite: `could move:` · `nearest miss:` · `engines:` · `unchecked:`.
*"Nothing, and here is why"* is a valid `could move:`; silence is not.

---

## Bite 0 — #1630, constraint-wrapper peel on an impl head (PR #1638)

`headTyNode (TyConstrained _ t) = headTyNode t` — one arm, `compiler/types/typecheck.mdk`.

- **could move:** emitted IR at any impl whose head is a constrained type with a headed body — those
  impls move from the `noneHeadTag` headless bucket to their real head. Acceptance is claimed
  unchanged **by construction**, not by measurement alone: the three acceptance readers
  (`implHeadTagForIface`, `implTysIfMatch`, `univHeadCountsInCensus`) go through
  `censusHeadNameTy`/`headTySpineNode`, which PR #1629 split off and this bite does not touch.
  ⚠️ That claim is the review's first target, since #1629 narrowed acceptance through exactly three
  such readers at 11/12 green.
- **nearest miss:** the census residual — a return-position undetermined receiver whose interface's
  only impl is the constrained one. **Built, probed, and the answer was NULL**: identical in all four
  cells to its unconstrained control. Recorded in-source as *structural, not demonstrated* — NOT as
  "measured benign", which is the exact over-generalisation that produced #1630 out of #1617/#1618.
- **engines:** `check` · `run` · `build` · **executed binary**, on the repro plus five sibling shapes
  (`Eq a => Bool`, `Eq a => Option a`, `Eq a => Int -> Int`, `Eq a => <Stdout> Int`, a two-constrained-
  head overlap) and on the headless control `Eq a => a` (3 on every cell, both arms — preserved).
- **unchecked:** `make preflight` to completion (~40 gates here, incl. `engines` and the ~35-minute
  `diff_compiler_dict_semantics`), the wasm arm, macOS. Left to CI, disclosed in the PR.

**Verdicts:** C3a PASS and C3b PASS, separately, no seed re-mint. Snapshots `typecheck`/`registry`/
`eval` blessed by name in a terminal commit, plain re-check **202/202**. `selfproc_legA` **measured**
unmoved (16 ok / 0 failing, `git status` clean) with the mechanism recorded. Pin: two rows on
`diff_compiler_dict_semantics.sh`, both proven able to fail (2→3, 6→7 reds exactly those rows).

**Not decided by the implementer, correctly:** auto-merge NOT enqueued (left for adversarial review);
the surviving `TyTuple` tag mirror (`tupleHeadTag` vs `tupleHeadTagTc`) recorded in-source but **not
filed**, because no program separates the two spellings — filing an unreproduced inference is the
thing this arc keeps paying for.
