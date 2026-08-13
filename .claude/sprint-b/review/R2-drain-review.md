# R2 — adversarial review of the drain bite and its follow-ons

Scope: `23f4da83` (`a3`), `1e7cbbbb` (the drain), `086aeb35` (`f`). All source read from
`git show 086aeb35:<path>` copies — the working tree was never read, nothing was built or run.
**Every finding below is a SOURCE READING.** The three that need a binary are labelled
`⚠️ UNVERIFIED — needs a probe` with the exact command.

---

## R2-1 — `f`'s over-fire set includes a LIVE IR-GOLDEN FIXTURE, and that fixture's own header says the program is correct. S1 (loud), and it reds a required shard.
`⚠️ UNVERIFIED — needs a probe`

`test/llvm_fixtures_modules/module_local_route_word/` is not a must-fail pin — it is a live
`diff_compiler_llvm_modules` corpus member with a committed IR golden, and it is **constructed to
be exactly `routeWordHeadSkew`'s firing condition**, in prose, in its own source:

* `a.mdk:1-8 @086aeb35` — *"Crucially `a` does NOT import `b`, so a's typecheck sees exactly ONE
  impl at head tycon `Box` and `keyForSiteByIface` therefore stamps the BARE HEAD `"Box"`"*;
  `export impl Speak (Box Int)` + `export impl Loud (Box Int)`.
* `b.mdk:1-13 @086aeb35` — `export impl Speak (Box String)` + `export impl Loud (Box String)`,
  same head tycon, *"Nothing in this module is ever dispatched on. Its mere PRESENCE IN THE
  PROGRAM…"*
* `entry.mdk:20 @086aeb35` — the wrong behaviour it pins is *"Silent wrongness, on a program that
  is **CORRECT on main**."*

So for method `speak` at head `Box`: prefix count (a's closure) = 1, graph count = 2 ⇒
`routeWordHeadSkew` True (`typecheck.mdk` `routeWordHeadSkew`/`ieCountHeadByMethod`, added by
`086aeb35`) ⇒ `T-ROUTE-WORD-AMBIGUOUS` ⇒ `build` exit 1. **`f`'s over-fire set is therefore
strictly bigger than {#1397, #1514}: at minimum it also contains this fixture, and both its
variants (`Speak` and `Loud`).** The DEBT/HANDOFF framing — "two must-fail pins over-fire" —
under-reports the blast radius because **the over-fire sweep was done against the must-fail suite,
which by construction only contains pinned bugs.**

Consequences worth stating separately: (a) this is a capability regression on a program the tree
itself certifies as correct, same class as #1514 but on a *legitimate* corpus; (b) `gates
(backend)`/the llvm-modules gate goes red, so the branch cannot be enqueued even if #1514 were
waived; (c) the fixture exists specifically to prevent a *silent* re-narrowing of the route-word
set — `f` makes that axis unrepresentable by refusing the program, which removes the only live
guard on it.

**Probe (yours to run):**
```sh
./medaka build test/llvm_fixtures_modules/module_local_route_word/entry.mdk -o /tmp/mlrw \
  > /tmp/mlrw.log 2>&1; echo "build: $?"; grep -c T-ROUTE-WORD-AMBIGUOUS /tmp/mlrw.log
sh test/run_gates.sh 'diff_compiler_llvm_modules*'
```
(Redirect, don't pipe — `build`'s exit code does not survive a pipe.)

---

## R2-2 — `f`'s in-source safety derivation for the #1599 drain is CONTRADICTED by #1599's own fixture. If it fires there, #1599 is a FALSE DRAIN (drained by a reject, not by correct selection). S0-if-true (a live bug would be closed as fixed).
`⚠️ UNVERIFIED — needs a probe`

`f` justifies "the three drains stay drained" with: *"#1564's and #1599's programs declare ONE
impl at the head, so the graph count is 1 and this cannot fire"* (`typecheck.mdk`,
`ieCountHeadByMethod` header block, `086aeb35`). #1599's fixture declares **two**:

* `test/must_fail_fixtures/1599-reachable-conditional-beats-unreachable-specific/gen.mdk` — `impl
  Show2 Box …`
* `…/spec.mdk` — `impl Show2 Box …`

One graph, one head spelling, same interface ⇒ same method set. The issue's own title —
*reachable conditional beats **unreachable** specific* — means the site's module does **not** see
`spec`, i.e. prefix = 1 while graph = 2: **precisely the skew condition.** Either `f`'s derivation
is wrong on its own flagship drain, or the site's prefix already collides (in which case the
sentence is still wrong as written, just harmlessly). The dangerous branch matters because a
must-fail pin flips to DRAINED when the program stops misbehaving **for any reason, including a
build refusal** — the same check-only blindness that produced RUN-B-023's report over a segfault.
If #1599 is drained by `T-ROUTE-WORD-AMBIGUOUS`, closing it puts a live silent-wrongness bug in
the tracker as fixed.

**Probe:**
```sh
cd test/must_fail_fixtures/1599-reachable-conditional-beats-unreachable-specific
/root/.../medaka build main.mdk -o /tmp/x1599 > /tmp/x1599.log 2>&1; echo "build: $?"
grep -c T-ROUTE-WORD-AMBIGUOUS /tmp/x1599.log   # >0 ⇒ the drain is a REJECT, not a fix
```
Same probe is owed for #1564 (`1560`/`1576`/`1579`-family fixtures also show two same-head rows
per dir, though those are control/main **separate programs** — confirm per-dir before counting
them).

---

## R2-3 — SEVERITY UNDERSTATED IN A `DEBT.md` ROW: the drain's `could move:` "tie-break semantics change" bullet is a silent-dispatch change at exit 0 with NO gate. S0-shaped, filed as a spec note.
Derivation: `.claude/sprint-b/DEBT.md`, `B-2.1-b2` row, `could move:` bullet *"Tie-break semantics
change, deliberately … the fallback moves from arbitrary (a violated ascending precondition over a
per-module-restarted index) to graph-global declaration order … only the order is now statable."*

That sentence describes **which impl a non-closed, no-unique-minimum multi-module goal selects**,
changing for every such program in the tree — no diagnostic, exit 0, different emitted call. The
row records it as a spec-statability improvement. Its *worst* realisation is identical in shape to
the S0 that was found by accident: a program that built correctly now builds a different, wrong
binary at exit 0. **And nothing observes it:** value goldens see values only where the selection
changes an observable, `must_fail` grades `check`, the snapshot/LEG A families are deliberately
unblessed this run, `diff_compiler_engines` is deferred, and the three engines re-derive selection
order independently (`eval.pickTagFallback`, `core_ir_eval`'s `score`, `llvm_emit.headTagUnique`)
— none of which moved in this diff. This is the row I would loudest re-grade: it is written as a
deliberate improvement and it is an ungated silent behaviour change.

Second understated cell in the same row: *"⚠️ Not identical arithmetic: that side counts DISTINCT
canonical keys, this one counts rows — a pre-existing difference … not claimed as fixed."*
**That difference is not a footnote, it is the mechanism of `f`'s entire over-fire class.** Two
same-spelled types in two modules give 2 rows but 1 distinct canonical key: the emitter says
*unique* (bare word correct, program builds and runs — #1514 printed 11/110/7), typecheck's
row-count says *collision*. #1514, #1397 and R2-1 are all one instance of this recorded-as-benign
arithmetic mismatch. It should be a named defect, not a parenthetical.

---

## R2-4 — What the drain moved that NO gate observes (target 1)
Enumerated from `1e7cbbbb`'s diff (`compiler/types/typecheck.mdk` 404 lines,
`compiler/ir/core_ir_lower.mdk` comment-only, `compiler/types/registry.mdk` comment-only,
`test/diff_compiler_flat_vs_onemodule.sh` +67):

| moved | gate that would see a regression |
|---|---|
| legs 1/2a/2b selection population (prefix ⇒ graph-global) | `must_fail` (**check only**), `flat_vs_onemodule` (13 rows) — neither grades the built binary except where a row does |
| the *emitted IR* for every goal whose impl sits in a later module | `selfcompile_fixpoint` — **OWED, unrun**; snapshot + LEG A goldens — **deliberately unblessed** ⇒ nothing watching |
| tie-break order at non-closed goals | **NOTHING** (R2-3) |
| cross-engine agreement (typecheck now selects on a population the other three engines do not re-derive) | `diff_compiler_engines` — **deferred to the repair round** |
| impls-per-head cost (`a3`'s O(bucket) filing) | **NOTHING** — `perf_scaling` scales decls/modules, not impls-per-head (`a3` row states this itself) |

So the two things this bite most plausibly broke — emitted-IR selection and engine agreement — are
each watched only by a gate this run has explicitly deferred. That is not a gap in my reading; it
is the run's design, and it is why R2-1/R2-2 are source readings rather than measurements.

---

## R2-5 — `a3`'s `ieByHead` seam: no row shape reaches one filing path and not the other; one key-shape caveat stands. S3.
The seam is genuine: `ieInsertRow` (Module) and `ieIndexRows` (Flat) both call `ieFileRow`
(`typecheck.mdk:4304`, `:4190-4193`, `:4306-4361 @086aeb35`), so the only per-row difference left
is the `ieRows` append, and `ieInsertRowAt` (per-`oblIfaceKeys`-element) files no head index —
which is the double-file hazard, correctly avoided. Key is `headBucketKey (univReceiverTag tys)`,
minted by the one function `KeyBuckets` also uses, and has **no interface component**, so R1's F1
cannot be inherited — I agree with `a3` there.

Residual I would not call closed: `a3`'s own `nearest miss:` states `ieByHead` files a `tys = []`
impl under the **headless** key while `keyEntryOfRow` **drops** such rows — *"harmless while the
consumer drops those rows, and an S0 the day it does not."* `f`'s new consumer
`ieCountHeadByMethod` reads `ieHeadRows hd env` with `hd = Some hk` only (`routeWordHeadSkew`
returns False on `None`), so it does not read the headless bucket — the superset stays dormant.
**But it is now one `Some`/`None` edit away from live**, and the guard's count is the thing a
reject is derived from. Worth a comment at `routeWordHeadSkew`, not a fix.

---

## R2-6 — Retracted
`test/dict_fixtures/s6-c1-xmod-same-spelled-ifaces-accepted` looked like a fourth over-fire member
(two modules, interface both spelled `Same`, both `impl Same Int`, entry imports one method from
each, expected value 109). **It is not:** `amod`'s method is `foo`, `zmod`'s is `bar`
(`amod.mdk:4-7`, `zmod.mdk:6-9 @086aeb35`), and `ieCountHeadByMethodGo` counts only rows whose
method SET contains the queried name — so each count is 1 and the guard cannot fire. Retracted
before reporting. Note the corollary, which is a real (unpinned) shape: **two same-spelled
interfaces sharing a METHOD name** at one head would fire, and that is #1182's shape, still REPRO.

---

## Build-verifications I want (in priority order, none run by me)
1. `medaka build test/llvm_fixtures_modules/module_local_route_word/entry.mdk` — expect exit 1 +
   `T-ROUTE-WORD-AMBIGUOUS`; then `sh test/run_gates.sh 'diff_compiler_llvm_modules*'`. (R2-1)
2. `medaka build` on `1599-…/main.mdk` and on #1564's `order2` fixture, grepping the log for
   `T-ROUTE-WORD-AMBIGUOUS` — decides whether either drain is a reject. (R2-2)
3. A permutation differential for R2-3: same non-closed multi-module goal, two import orders,
   compare `--keep-ir` bytes on the base binary vs this branch's.
