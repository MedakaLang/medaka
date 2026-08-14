# R3 — focused re-review of PR #1629's AMENDMENT (a8a226cb → 41a1d77d)

Scope: the amendment only. R1's clearances are not re-litigated.
Merge base of the branch = `aaa43716` = current `origin/main` (`git merge-base 41a1d77d origin/main`).

Delta commits:
```
41a1d77d test: split the acceptance pin into a CHECK-only corpus, unbreak the bystander
3cbea687 test(goldens): re-cut the two golden families the acceptance-census split moved
ef4cf1eb test(bystander): pose the undetermined constraint from a DEAD binding
699f0b5b fix(typecheck): keep the #1617/#1618 dispatch fix OUT of the acceptance census
```

**Arms used.** BASE = `/root/medaka/.claude/worktrees/peppy-brewing-kitten/medaka`,
verified fresh against `aaa43716` (`MEDAKA_STRICT=1 medaka run hello.mdk` → `12345`, exit 0).
HEAD = cold-bootstrapped `make medaka` in a private detached worktree at `41a1d77d`
(`$SCRATCH/headarm`), likewise `MEDAKA_STRICT=1`-clean. No emitter was borrowed.

---

## ITEM 1 — the two-writer iface→head-tag SET  ✅ CLEAN

### 1a. Writer enumeration (derived)

`ieIfaceTags` — EVERY occurrence in compiler source at `41a1d77d`
(`git grep -n 'ieIfaceTags' 41a1d77d -- compiler/`): 4091 comment · 4103 field decl ·
4137 empty init · 4413 new comment · **4416 the sole write**. ⇒ one writer, and
**zero readers** (see 1c).

`ImplUniverse`'s third field: every *constructor application* is 22366
(`emptyImplUniverse`), 22516 and 22520 (`insertUnivImplAt`). Every other hit is a type
position or a pattern match. ⇒ **one** non-empty writer, `insertUnivImplAt`.

**No third writer on either set.** Both were changed, and both were routed through the
SAME helper pair (`univHeadCountsInCensus` / `univAddIfaceTag`), so a lockstep divergence
now requires editing the helper — structurally stronger than "two sites kept in sync".

### 1b. Is the guard the same predicate base used? — YES, extensionally identical

Base gate: `univReceiverTag tys = headTyconTy headTy` answering `Some`, where base
`headTyconTy` matches `headTyNode` (base: `TyApp` spine only) with arms
`TyCon → Some · TyTuple → Some · _ → None`.

Amended gate: `isSome (censusHeadNameTy headTy)`, where `censusHeadNameTy` matches
`headTySpineNode` (`TyApp` spine only) with arms `TyCon → Some · TyTuple → Some · _ → None`.

Same walk, same arms, same Some/None partition ⇒ **the tag set is byte-for-byte the base
set: no narrowing AND no widening.** The identical argument holds for `censusHeadNameTy`
vs base `headTyconNameTy`, which restores `implHeadTagForIface` and `implTysIfMatch`
exactly. This is a proof, not a probe.

### 1c. Flat-vs-module divergence — impossible here, and measured absent

The Module path does **not** reach `implCountForIfaceU` through `ieIfaceTags`.
`ieUniverseAt cur env = ieSnapAt cur env.ieUnivSnaps emptyImplUniverse` (4456-4457);
`ieUnivSnaps` is built by `ieBuildSnaps`/`ieBuildSnapsGo` → `insertUnivImpl` →
`insertUnivImplKeys` → **`insertUnivImplAt`**. So BOTH the Flat driver
(`buildImplUniverse` → `growImplUniverse` → `insertUnivImpl`) and the Module driver reach
the census through the ONE guarded writer.

Measured anyway (the same interface set, once flat and once as a 2-module project):

| shape | base check | head check | base `run` | head `run` |
|---|---|---|---|---|
| flat `impl_head_census_acceptance.mdk` | 0 | 0 | `(7, 55, True)` | `(7, 21, True)` |
| 2-module `lib.mdk` + `main.mdk`, same impls | 0 | 0 | `(7, 55, True)` | `(7, 21, True)` |

Flat and module agree with each other **on each arm** ⇒ no flat-vs-module divergence.
(The 55→21 move is the #1617 fix itself: on base the arrow impl, sitting in the headless
bucket that matches ANY receiver, answered a non-arrow goal. `55` is `impl Sz (Int -> Int)`'s
`szc`; `21` is `impl Sz Bool`'s. Head's value is the one consistent with its own census.)

### 1d. FINDING F-R3-2 (S3) — a new comment states a mechanism that does not exist

`compiler/types/typecheck.mdk:4413-4415` (added by this amendment):
> `-- ⚠️ `ieIfaceTags` is the ACCEPTANCE census (`ieUniverseAt` hands it to`
> `-- `implCountForIfaceU`), so it is guarded — `univHeadCountsInCensus`.`

`ieUniverseAt` does not read `ieIfaceTags` — it reads `ieUnivSnaps` (proof in 1c), and
`ieIfaceTags` has **no reader at all**, at head *or* at `aaa43716`
(`git grep -n ieIfaceTags` shows decl + init + one write, both revisions). The same
implication is repeated in the `univHeadCountsInCensus` header ("`ieInsertRowAt` (`IE`, the
Module path `ieUniverseAt` projects the universe out of)").

Behaviourally harmless — the write was guarded anyway, and guarding a dead index is the
right defensive call. But it is a mechanism claim that is false, in prose whose whole job is
to stop the next reader re-deriving this. Suggested correction: say `ieIfaceTags` is
currently a **write-only** index kept in lockstep with the live one, and that the live
census reaches `implCountForIfaceU` via `ieUnivSnaps` → `insertUnivImplAt`.

---

## ITEM 2 — did acceptance actually get restored, and is anything WIDENED?  ✅ CLEAN

The three-probe worry is answered structurally rather than by probe count: by 1b the two
`censusHeadNameTy` readers and the universe census are **extensionally identical to base**,
so no program's acceptance can move through them, in either direction.

What is NOT restored (deliberately) is the *bucket placement*: an arrow-/effect-headed impl
now files into `conc` at `__fun__` / at its peeled head, instead of `hl`. Checked every
reader of those two buckets:

```
22802-22803 implMatchesU          = bucketArgsMatch conc(goalHead) || bucketArgsMatch headless
22813-22814 implMatchesReceiverU  = same shape
23438-23439 implMatchesWithReqsU  = same shape
22867-22870 findMatchingImplReqsU = concreteReqMatchByIface (KeyBuckets/min⊑) then headless
```
The first three are `||`-unions of the two buckets ⇒ **order-insensitive booleans**, so
moving a row from one bucket to the other cannot change the answer as long as the goal-side
key finds it — and `headTyconMono` gained the matching `TFun` arm (verified at
`typecheck.mdk:20999-21015`). `findMatchingImplReqsU`'s concrete arm goes through
`ieSelectRowByIface`'s min⊑ selector, not `univConcreteBucket`, so there is no
declaration-order/priority hazard from the move either.

Differential probes, base vs head (each: `check` / `run` / `build` / exec of the built binary):

| probe | base | head |
|---|---|---|
| only `impl Sz (<Stdout> Bool)`, goal `Bool` | accepts, `6` | accepts, `6` (unchanged) |
| only `impl Sz (Int -> Int)`, goal `Bool` | rejects | rejects (unchanged) |
| `impl Sz Bool` + `impl Sz (<Stdout> Bool)`, goal `Bool` | rejects | rejects (unchanged) |
| `impl Sz a` (headless general) | `(9, 9)` | `(9, 9)` (unchanged) |
| minimal `Sz` arrow+effect, concrete goal | `7` | `7` (unchanged) |

**No widening found**: no probe accepts on head that base rejected. The one acceptance
*narrowing* vs base that does exist is confined to "an arrow/effect impl silently answering
a goal it does not match", i.e. the filed defect — a general `impl C a` still lands headless
(`TyVar` head → `None` in every projection) and is unaffected.

⚠️ Residual honestly stated: I did not sweep the whole corpus for route-word moves either;
the gates did (see item 3), and `diff_compiler_dict_semantics` includes 30 decl-order
permutation assertions, which is the check that a *widening* would show up in.

---

## ITEM 3 — is the dispatch fix still intact?  ✅ YES, measured

On HEAD (`$SCRATCH/headarm/medaka`), run in the branch tree:

```
diff_compiler_build          exit 0 — 84 ok, 0 failing (of 84)
  ok effect_head_impl_ab / _ba / _single
  ok fun_head_impl_ab / _ba / _single / _bystander      <- BOTH permutations
diff_compiler_check_json     exit 0 — 69 ok, 0 failing  (ok impl_head_census_acceptance)
diff_compiler_dict_semantics exit 0 — 187/187 assertions
diff_compiler_snapshot_frontend exit 0 — 202/202
medaka fmt --check / medaka lint on both changed compiler files — exit 0
```
Direct exec of the built bystander binary on HEAD: `(48, True, True)`, exit 0.
Minimal #1618 reduction (`conv` + effect-headed sibling): base built binary **segfaults**,
head prints `True`, exit 0.

The two must-fail pins (`1617-…`, `1618-…`) are deleted by the PR, and CI's `soundness` job
ran *"Open bugs must still reproduce"* → success, so the drain is consistent.

---

## ITEM 4 — the new fixtures  ✅ CLAIMS HOLD (one prose claim does not — see F-R3-1)

**E-PANIC-on-base — VERIFIED.** With the base binary:
```
medaka check  accept.mdk  -> exit 0, {"diagnostics":[]}
medaka build  accept.mdk  -> exit 1
   error: emitter failed compiling …
   runtime error [E-PANIC]: no impl of method 'szc' for type 'List'
```
and the author's *"a single-impl `Sz` with no arrow and no effect anywhere still fails
`build` on base"* reproduces exactly (8-line `min.mdk`: check 0, build 1, same E-PANIC).
⇒ the check-only corpus placement is correct and the defect is genuinely not this PR's.

**Non-vacuity — VERIFIED, and fail-capable.** The gate globs `"$FIXDIR"/*.mdk`
(`test/diff_compiler_check_json.sh`), so the fixture is auto-enrolled, and the golden is a
byte-compare of the whole envelope, so ANY diagnostic fails it. Demonstrated on HEAD by
adding one concrete-headed `impl Sz Int` to a copy of the fixture:
```
{"code":"T-AMBIGUOUS-INSTANCE","message":"Ambiguous instance for `Sz` …", …}   exit 1
```
i.e. RULE 3 is live and reachable at exactly this fixture's `szc []` site; the fixture sits
on the edge, one census entry away from red.

**Shared-corpus enrollment — checked.** `check_json_fixtures` has exactly one globbing
consumer. `engine_fixtures` is globbed only by `diff_compiler_engines.sh`
(`test/wasm/diff_playground_input.sh` cites ONE named file, not a glob;
`check_agent_doc_symbols.sh`'s hit is a comment); `build_diff_fixtures` only by
`diff_compiler_build.sh` (`diff_compiler_test.sh`'s hit is a comment). No silent enrollment.

**`MEDAKA_PRELUDE_OBJ` changes what is emitted — CONFIRMED, but it is DOCUMENTED, not a new
trap.** `compiler/driver/build_cmd.mdk:411-419` — when the env var is set the driver calls
`withEmitHalf "program"` and *"tell[s] the emitter to emit THIS PROGRAM ONLY (declaring what
prelude.o defines)"*. So the fast path genuinely compiles a different module split, and
`test/diff_compiler_prelude_obj.sh`'s own header says so verbatim: the two paths *"CANNOT be
byte-equal"* (unlike `MEDAKA_RT_OBJ`, which is held to byte-identity) and it names the two
miscompiles it watches for. Recommend NOT filing this as a new trap; it is stated at both
the producer and the gate. The engines shard executed on this PR's CI run (steps
`Gate shard — engines=success`), so the fixture passed under that env.

---

## GOLDENS ✅ and PR BODY

**LEG A re-cut is genuinely additive.** Not just amendment-local — over the WHOLE PR:
```
$ git diff aaa43716..41a1d77d -- test/selfproc_goldens/legA/ | grep '^[-+]' | grep -v '^[-+][-+][-+]'
+censusHeadNameTy : Ty -> Option String
+headTySpineNode : Ty -> Ty
+univAddIfaceTag : Bool -> RegKey -> TabKey -> Registry SetRegistry -> Registry SetRegistry
+univHeadCountsInCensus : List Ty -> Bool
```
Four added lines, **zero removals, zero modified lines** ⇒ no existing binding's inferred
type changed. Claim verified as stated.

**PR body.** §5's retraction is accurate (LEG A did move, and the quoted four lines match the
real diff byte-for-byte). §6's replacement of the un-derivable `8/8` with the full engines run
and its explicit "T2/T3 did NOT run locally" is honest. §4's corpus enumeration is correct in
conclusion. §10's measured table is consistent with what I re-measured for the cells it
reports (`run`-level), and the shard-execution claim checks out against the API.

### FINDING F-R3-1 (S2, non-blocking) — a MEASURED claim in committed fixture prose is FALSE

`test/engine_fixtures/fun_head_impl_bystander.mdk` and its identical twin
`test/build_diff_fixtures/fun_head_impl_bystander.mdk`, header:

> `-- 🚨 MEASURED ON THE COMMIT THAT HAD THE NARROWING (`a8a226cb`), THIS FILE`
> `-- SEGFAULTS … On base `aaa43716` and on the amended branch all four cells`
> `-- agree on `(48, True, True)`.`

**Base does not agree.** Measured on the fresh base binary, 5/5 deterministic:
```
medaka build by.mdk -o by.bin   -> exit 0
./by.bin                        -> runtime error [E-FATAL-SIGNAL]: fatal memory fault
                                   exit 139   (x5)
```
`check` 0 and `run` `(48, True, True)` on base are correct; the fourth cell (exec) is a
segfault. Reduced to an 8-line repro — the `Conv` multi-param block with its effect-headed
sibling alone — base: build 0, exec 139; head: build 0, exec 0, `True`.

Consequences:
- The segfault is **not** something `a8a226cb` introduced; it is the pre-existing #1618
  defect, and this fixture is a **direct repro of the bug the PR fixes**, not the pure
  bystander the header bills it as.
- The fixture is therefore *stronger* than advertised — but a future reader told "base
  agrees on all four cells" would reasonably conclude it has no regression-detection value
  for #1618 and could weaken or delete it. That is the coverage-loss risk that makes this
  S2 (misleading) rather than S3.
- The PR body's §4 row inherits the same implication ("On the un-amended `a8a226cb` it
  segfaults") without stating that base segfaults too.

Fix is a comment edit only: state that base `aaa43716` segfaults at the built binary, that
`a8a226cb` does too, and that the amended branch is the first arm where all four cells hold.

---

## VERDICT

No defect in the amendment's code. The restoration is exact (proved, not probed), the
two-writer set has no third writer and no flat-vs-module divergence, the dispatch fix is
intact in both permutations, and the new check-only fixture is correctly placed and
fail-capable.

Two prose findings, neither blocking: **F-R3-1 (S2)** — a false MEASURED claim in the
bystander fixture header (base also segfaults; the fixture is a #1618 repro, not a
bystander); **F-R3-2 (S3)** — a new comment attributing the acceptance census to
`ieIfaceTags`/`ieUniverseAt`, which is not the live path (`ieIfaceTags` has no reader).

**PR #1629 should merge as it stands.** Both findings are comment-only and can land as a
follow-up; neither changes a byte of behaviour.
