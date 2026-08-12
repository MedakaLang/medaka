# R2 — adversarial audit of the `could move:` column (repair round)

Trunk `0b953165`, binary untouched (no rebuild, no bless, no tracked-file edit).
All probes `MEDAKA_STRICT=1`, exit codes read from a file, never from a pipe.
Tree state at measurement time: only `.claude/sprint/DECISIONS.md` dirty (another
agent); **no compiler/test source was modified during any measurement**.

Label key: **DERIVED** = I ran it here. **RELAYED** = taken from the ledger. **OWED** = not done.

---

## 1. RUN-035 re-derivation — LEG A scheme delta (DERIVED)

Method: the gate's own comparison, read-only, blessing nothing —
`test/bin/check_all_main stdlib/runtime.mdk stdlib/core.mdk compiler/entries/all_modules_entry.mdk compiler stdlib`,
section-extracted with `awk '/^## MODULE /'`, `LC_ALL=C sort` both sides, diffed
against `test/selfproc_goldens/legA/<mid>.golden`.

**Result: RUN-035's property still HOLDS, extended over the four units that landed
after checkpoint 1. Zero unattributed hunks.**

* Of the 13 LEG A modules, **exactly one moved**: `types.typecheck` (60 changed
  lines). The other 12 are byte-identical after sort — so nothing leaked into
  `resolve`, `loader`, `eval`, `ast`, …
* Golden 1758 schemes → 1764. Delta = **18 added / 12 deleted / 15 re-typed**:
  * added: `ceRequiredAt` `ceRowRequired` (A5a-1/2) · `cohImplIfaceName` (3.7-4) ·
    `cohImplOfRow` (3.7-5b) · `cohRowVisible` `cohRowsOf` `cohRowsOwnedBy` (3.7-6) ·
    `cohSameIface` (3.7-3) · `deSeedChainProbe` `deSeedRowN` (C-1) · `flatImplEnvOf`
    (A5b-2) · `ieCandidacyVisibleAt` (C-3) · `ieRowsAll` `ieRowsOwnedBy` (3.7-1) ·
    `ieRowsVisibleAt` (A5b-1) · `implRowMatchesSuper` (A5b-3) · `requiresUnroutedMsg`
    `unroutedResidual` (D4-1).
  * deleted: `checkImplCompleteness` `implCompletenessMsgsOf` `ifaceRequiredMethods`
    (A5a-4) · `insertIfaceRequired` (A5a-5) · `declEnvsUpTo` `declEnvsUpToGo`
    `declEnvsVisible` (C-0) · `cohImplsOf` `cohImplsOfMid` `cohCollectImpls`
    `cohCollectModuleImpls` (3.7-9) · `implMatchesSuper` (renamed, A5b-3).
  * re-typed: `checkCoherence` `globalCoherenceConflict` (3.7-7/8) ·
    `checkImplCompletenessMap` `implCompletenessMsgsOfMap` (A5a-3) · `checkSuperImpls`
    `superImplExists` `superImplMsgsOf` `superMsgFor` (A5b-3) · `cohClassify` `cohScan`
    `cohScanInner` `cohScanOuter` `cohSoftInScope` (3.7-5a) · `cohImplIface` (3.7-4) ·
    `runFinalChecks` (A5b-4 + 3.7-7).
* **Every one of the 45 is owned by a named bite. No surviving binding's inferred
  type moved except the 15 that were specified in advance.**

⚠️ Two caveats on my own derivation, so it is not read as more than it is:
`test/bin/check_all_main` was built at 21:03 while `typecheck.mdk` is 22:20 — the
*checker* is one commit stale, though the *corpus* is on-disk and current (it did
surface D4-1's two new bindings). And LEG A grades 13 of the 33 modules the dump
emits.

## 2. RUN-042 re-derivation — the eight `declEnvVisibleAt` reader paths (DERIVED)

Holds. At HEAD `declEnvVisibleAt`'s body is byte-identical (`:2873
declEnvVisibleAt cur entryOrd = entryOrd <= cur`) and its only direct callers are
`declEnvVisibleTo:2981`, `ieRowsVisibleAt:4320`, `ceLookupAt:4759`,
`ceRowsVisibleAt:4782` — i.e. all seven KEPT paths still reach the ordinal test
only through it. `ieCandidacyVisibleAt _ _ = True` (`:2902`) has exactly one
non-comment reader, `ieSnapAt:4293`. One flipped, the rest held.

## 3. FINDINGS

### F1 — S3 (ledger defect: asserted without checking, and FALSE)
**Row falsified: `A5a-4` `could move:` item 1** — *"A flat program where a USER
interface shadows a PRELUDE one by spelling … A real Flat acceptance delta with no
existing fixture, in BOTH directions … the testing round's first target for
A-3.5a."*

The shape **cannot exist**: resolve rejects the program before any completeness
check runs, so there is no acceptance delta in either direction.

```
$ cat /var/tmp/r2p/dbg_shadow.mdk       # also reproduced with `interface Eq`
interface Debug a where
  dbg : a -> Int
  dbg2 : a -> Int
data Foo = Foo
impl Debug Foo where
  dbg x = 1
main = println 1

$ MEDAKA_STRICT=1 ./medaka check /var/tmp/r2p/dbg_shadow.mdk ; echo $?
<unknown location>: Duplicate interface: Debug
<unknown location>: Method 'dbg' is not part of interface 'Debug'
1
```
Same for `Eq`. `compiler/frontend/resolve.mdk` is untouched by the whole sprint
(`git diff 176feb50 HEAD --stat`), so this is base behaviour too. **Retire item 1
as a target; do not write the fixture it asks for.**

### F2 — S2 (real asymmetry, first reproducer; discharges A5b-1 / RUN-042's ninth path)
The unruled question — *"if candidacy is graph-global but super-EXISTENCE is
prefix-scoped, an `impl Sup T` in a topologically LATER module satisfies dispatch
while still being reported missing"* — **reproduces**:

```
/var/tmp/r2m5/  amod.mdk: interface Sup; interface Sub requires Sup
                umod.mdk: import amod; data Bar; impl Sub Bar   (no impl Sup Bar here)
                main.mdk: import amod.{Sup,sf}; import umod.{Bar,ufn}; impl Sup Bar where sf x = 3

$ MEDAKA_STRICT=1 ./medaka check /var/tmp/r2m5/main.mdk ; echo $?
/var/tmp/r2m5/umod.mdk:6:9: 'impl Sub Bar' requires a superinterface 'impl Sup Bar', which is missing
1
```
The impl **is** in the graph and, post-A-3.6, **is** a candidate for dispatch; only
`checkSuperImpls`' `ieRowsVisibleAt` (still on `declEnvVisibleAt`) cannot see it.
Not a regression from base — base rejected too, both axes being prefix-scoped — so
what is NEW is the *inconsistency*, which is exactly what A5b-1 and C-3 item 9 flag
as UNRULED and UNOWNED. P0-B §4.3(4)'s missing fixture now has a program.

### F3 — S3 (asserted without checking, and TRUE)
`3.7-6`'s `unchecked:` hands the round five HARD-arm fixtures P0-D listed and only
one was run. **All five re-run at HEAD (i.e. after 3.7-7/8/9, not only at 3.7-4)
and all hold**, exit 1 with unchanged `Overlapping impls of …` wording:
`typecheck_error_fixtures/{dup_impl,overlapping_impls}.mdk`,
`check_json_fixtures/conflicting_impl_duplicate.mdk`,
`dict_fixtures/{s6-c1-duplicate-heads-rejected,s6-c1-hard-and-soft-in-one-file}.mdk`,
`run_check_agreement_fixtures/p0_1_overlapping_impls.mdk`; plus
`lint_fixtures/derivable_needs_datadecl.mdk` exit 0. Attack list discharged.

### F4 — S3 (stale symbol, already flagged by 3.7-9, still live)
`test/dict_fixtures/s6-c1-hard-and-soft-in-one-file.mdk:18` names the **deleted**
`cohCollectImpls`. Outside `agent-doc-symbols`' corpus, so no gate can see it.
(A fixture's line count is load-bearing; a re-word must be line-count-neutral.)

## 4. Claims I re-derived and which SURVIVED

* **Must-fail suite, first QUIESCENT reading since `5efc8525`** (RUN-036 requires
  this to be the round's first act): `sh test/diff_compiler_must_fail.sh` →
  **99 fixtures, 98 reproduce, 1 DRAINED (`1438-*`), 0 control-broke, 0 malformed.**
  This supersedes every contaminated reading in `3.7-CONTAMINATION`/RUN-032/033/041.
  It corroborates F-0 (`1597-*` REPRO), C-3 (`1072-*` REPRO), 3.7-0 (`1438-*`
  DRAINED — **#1438 still must not be closed**, per its own `why-note`), and D4-1
  (`1564-*` back to REPRO under the re-pointed `diag-code`).
* **D4-1's segfault closure, all three arms** (its `unchecked:` says run/build were
  *not* re-measured; now they are): on `1564-*/main.mdk` — `check --json` exit 1
  `T-REQUIRES-UNROUTED` at range `2:16-2:21` exactly as pinned; `run` exit 1, same
  message at `nest.mdk:3:16`; `build` exit 1 (log read from a file). **No exit-0
  build, no 139.** RUN-043's segfault is closed.
* **The ledger-repair commit really is comment-only + one deletion.**
  `git show f37b2562 -- compiler/types/typecheck.mdk` filtered of `--` lines
  contains exactly: C-0's three function deletions, and the `numlitRefs` field line
  re-emitted with a trailing comment. #829 could not fire — `:6683 data PerRun =
  PerRun {` is the SAFE collapsed header and the comment sits on its own field
  (`:6704`). `fmt --check` and `lint` on `typecheck.mdk` both exit 0 at HEAD.
* **F-3's "byte-identical to base"**: no hunk in `git diff 176feb50 HEAD --
  compiler/types/typecheck.mdk` touches `declEnvDeclFieldOwners` or
  `publicDataDecl`. #1586 still live, measured on the **unsignatured** form
  (`g r = r.s`): exit 0, `g : A -> Int`, silent.
* **Doc gates**: `make agent-doc-symbols` PASS (0 dead — C-5's reported dead
  `universeIfaceRequiredRef` in `DICT-SEMANTICS.md` has since been repaired) and
  `make docs-links` PASS.
* **Ratchet**: `sh test/registry_keying_ratchet.sh` PASS — `23 CrossRun field(s)`,
  `23 crossRun.value.* write target(s)`, IE block 129 lines. Corroborates A5a-5
  (24→23), 3.7-1 and 3.7-9's "shrinks `driver_allowed` by ZERO".
* **A-3.5a/A-3.5b identity-miss hunt (`None => []` silent accept) — could NOT
  produce a miss.** Four shapes, all correctly rejected:
  1. Module-arm incomplete impl of a PRELUDE interface (`impl Bounded Foo` missing
     `maxBound`) → exit 1, located in the *imported* module.
  2. Two same-spelled interfaces `Same` in unrelated modules + an incomplete impl of
     one → exit 1 naming the RIGHT missing method (`af2`, amod's), i.e. identity
     keying picked the right row.
  3. Same graph with the two entry imports PERMUTED → byte-identical verdict.
  4. Same-spelled `Sub` (one with a super, one without) + `impl Sub Bar` lacking
     `impl Sup Bar` → exit 1 `T-MISSING-SUPER-IMPL`; the abstention did not fire.
  Also: an **attributed** (`@deprecated`) interface declaration — A5a-4's explicitly
  unmeasured case — is inert for a different reason than the row argues: resolve
  rejects it outright (`Unknown interface: Loc`, exit 1), so `classEnvDeclFact`'s
  `DAttrib` unwrapping is never reached from that shape.

## 5. Could NOT test, and why

* **The `DL` population set-equality** owed by A5a-3 and A5b-3 (is IE/CE's visible
  row set at `cur` the same set as `accAll ++ accData ++ prog`?) — needs the
  instrumented hard-panic build A-3.4 PR2 used. **No build permitted; still OWED,
  and it remains the most load-bearing unchecked item in the sprint.**
* **D4-1's narrowing class** (a program accepted-and-correct before, now
  `T-REQUIRES-UNROUTED`). I could not run a two-arm differential without a base
  binary. What I did establish: adding an explicit constraint context does *not*
  rescue the #1564 shape — `nest : Tag a => a -> String` still rejects in order 2 and
  still compiles and prints `wrap(int)` in order 1 — so the reject is order-driven,
  not signature-driven. **OWED: base-arm build + a corpus sweep.**
* **3.7-8's permutation differential in its two-arm form** — same reason (no base
  binary in this worktree).
* **Allocation/perf items** (A5b-1's per-call list, A5b-2's second whole-program
  fold, 3.7-7's new `flatImplEnvOf userDecls` on every seeded flat check) — deferred
  by §5 and unmeasurable read-only.
* **C-5's 14 prose re-cuts** — verifiable only by reading, which is #1574's point;
  I spot-checked the symbols they name (all resolve) but did not re-derive each claim.
