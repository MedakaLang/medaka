# FX-1 — the `DEBT.md` row, handed back (I am not the writer of that ledger)

Append verbatim. ⚠️ **Bite letter:** I named it **`B-2.1-h`** and that string appears at **4 source
sites** (`grep -n 'B-2.1-h' compiler/types/typecheck.mdk`). `h` is not used as a bite id anywhere
else, but `next/QUEUED-h-exit.md` / `QUEUED-h-revert.md` use `h` as a *packet* letter. If that
collision bothers you, rename before merge — it is a 4-site `sed` **plus a snapshot re-bless**
(`sh test/diff_compiler_snapshot_frontend.sh --bless compiler/types/typecheck.mdk`).

---

### `B-2.1-h` — repair round (FX-1) — **the method-set guard moved onto the graph-global `IE`. Closes F1's finding 6 / R3's F-1: the last "one decision, two substrates" site, measured.**

sites:
* `compiler/types/typecheck.mdk:15716` — `stampOpRouteVal`'s `dictMethod` guard
* `compiler/types/typecheck.mdk:19762` — `entailInst`'s `EKArg` arm, `dictName`
* `compiler/types/typecheck.mdk:15743-15790` — `implDefinesMethodAt`/`…Go` **DELETED**, replaced by
  `ieDefinesReqMethodAt`/`…Go` + `implRowHasReqs`
* `compiler/types/typecheck.mdk:18113` — the `#1128 (F-3b) AUDIT` bullet, which enumerated
  `ImplBuckets`' readers **by name** and would otherwise have gone stale on this diff
* `compiler/eval/eval.mdk:1440` — comment citing the dead symbol by name
* goldens re-cut: `test/snapshots/compiler/typecheck.md`, `test/snapshots/compiler/eval.md`,
  `test/selfproc_goldens/legA/types.typecheck.golden`

transform:
`implDefinesMethodAt implTable name tag` (cumulative-prefix `ImplBuckets`, `bucketOf tag`, string
compare `tag2 == tag`) → `ieDefinesReqMethodAt perRun.value.bodyImplEnvRef.value name
(headTyconMono m)` (graph-global `IE`, `ieHeadRows`, `headTabEq`/`dispHeadTab`). **The population
moved and nothing else did**, and each half of that was held deliberately:
* **key strength unchanged** — both sides still project through `dispHeadTab`, i.e. the head tycon
  SPELLING, exactly what `tag2 == tag` compared. A structural `HeadKey` compare here re-opens #1111
  (see `headTabIs`' 🚨 note), so it was not taken.
* **the `requires`-only filter is KEPT** (`implRowHasReqs`). `ImplBuckets` came from `implEntryOf`,
  whose `match reqs [] => []` arm drops every context-free impl, so the predecessor could only ever
  answer True for a `requires`-carrying impl. Dropping it is a *second* semantic change; it is
  recorded under `nearest miss:` and **tested**, not smuggled in.
* **head choice is `headTyconMono m`, not `goalHeadCon goals`** — `m` is the mono `entail` derived
  this arm's `tag` from (`headTyconNameMono`), so the two are the same head by construction.
  Re-aiming the guard at the vector's head would move n≥2 interfaces for unrelated reasons.

Net: a pure **widening** of the same predicate. Every True the prefix answered, this answers.

evidence (the S1, graded on IR — `check` is blind here, the stampers are elaborate-only):
F1's repaired P1 (`iface`/`base`/`n`/`m`/`main`, impl in `n` defines `lt` and inherits `compare`,
`m` does not import `n`, lever = the two `import` lines in `main.mdk`).

```
                       run   build   exe    IR diff (order a vs b)
pre-fix  (79741bbc)  a: 1     0      1  E-NONEXHAUSTIVE-MATCH     589 lines
                     b: 0     0      0  True
post-fix             a: 0     0      0  True                      0 lines  (BYTE-IDENTICAL)
                     b: 0     0      0  True
```
* **Outcome chosen: the program BUILDS AND RUNS CORRECTLY** (`True`), not "refused with a located
  diagnostic". That is the right arm under DICT **§8 I5** (candidacy is graph-global — `n`'s impl
  *is* a candidate at `m` under both orders) and **C4** (same predicate ⇒ same instance set ⇒ same
  evidence). Base's exit-1 refusal was a self-described *compiler limitation* diagnostic, not a
  semantic reject; restoring it would have re-shipped a limitation, not a rule.
* **Fail-capability**: the identical script + identical fixtures against the pre-branch binary
  produced the 589-line diff and the crashing binary, in this session
  (`scratchpad/fx1/probe.sh`, `scratchpad/fx1/irdiff.branch` vs `irdiff.fix`).
* **The previously-CORRECT order did not move**: order-b IR is **byte-identical** pre- vs post-fix
  (`diff pb/out.branch.ll pb/out.fix.ll` → 0). So the fix moved only the broken order onto the good
  one — the minimal possible motion, measured rather than asserted.
* R3's mandatory **positive control** (impl also defines `compare`) still converges, and is now
  order-invariant in IR too (0 lines).

could move:
**Bounded, and the bound is structural, not a survey.** The guard's False arm is
`innerDefaultMethod name`, which is the **identity** for every name outside the hardcoded six
(`lt`/`gt`/`lte`/`gte`/`min`/`max`, `innerDefaultMethod:15731`). So **any program whose dispatched
method is not one of those six is byte-identical by construction, whatever the widening answers.**
Inside that set, the programs that move are exactly: *a `requires`-bearing impl at head `T` that
defines μ and inherits `compare`, sitting in a module the use site's topological prefix does not
reach.* Those previously stamped `compare` and now stamp μ, which moves the element-dict routes,
hence emitted dict arity, hence (as measured) acceptance of the built binary. Everything already
inside the prefix is unmoved — order-b's byte-identical IR is the evidence for that half.
⚠️ Direction of the widening is **toward** the DICT answer, but it is still a widening: it makes the
guard answer True where it answered False, so a shape that *depended* on the reduction-to-`compare`
would move. I found none, and I did not run the full corpus (CI owns it).

nearest miss:
**Two, and I ran the first.**
1. **The kept `requires` filter.** The nearest uncovered program is P1 with `impl Cmp (Box Int)`
   carrying **no `requires`** (defines `lt`, inherits `compare`) — outside `implEntryOf`'s
   population, therefore outside my scan too. **RUN, both orders** (`scratchpad/fx1n/`):
   `run 0 / build 0 / exe 0 / True` on both, **IR diff 0 lines**. So it is order-invariant and
   correct today; the filter costs nothing observable here. It is order-invariant under *both*
   substrates by construction (the row is in neither population), which is why this is a residual
   and not a defect: the open question it leaves is whether reducing a context-free `lt`-defining
   impl to `compare` is right *in general*, and that is a separate semantic bite.
2. **F1's UNREACHED arm (c)** — a goal that is ⊑-incomparable *and* non-closed at the moment of
   selection. **My fix does not change that, and I did not construct one either.** It lives in
   `pickMostSpecificEntry`'s no-unique-minimum tie-break (organ 8), which this diff does not touch.
   Recorded UNREACHED, **not refuted** — I am not claiming movement without a program.

engines:
* **typecheck / route stamper** — the only thing moved. All typed engines consume the corrected
  route word.
* **LLVM** — measured directly (the IR diffs above are `--keep-ir` output).
* **eval** — moved with it (`run` goes from `E-PANIC` to `True` on order a). ⚠️ Not offered as
  corroboration of anything: eval agreement proves nothing on a dispatch shape.
* **wasm** — inherits the same stamped route by construction; **not measured here**
  (`diff_compiler_engines` / the wasm gates are outside this round's floor — CI owns them).
* **`core_ir_eval` (the fourth arm)** — ⚠️ **NOT touched by this change.** `ir/core_ir_eval.mdk` is
  unedited; `cevalModules` would consume the corrected route on a typed run, but **its only gate
  (`diff_compiler_core_ir_modules.sh`) runs the UNTYPED path, where no `Route` is stamped at all** —
  so this change is **structurally invisible** to that arm's gate, green or red. That is F1's
  finding 5 / R6-D1 restated, unimproved and unworsened by me.

unchecked:
* `selfcompile_fixpoint.sh`, the corpus sweeps, `diff_compiler_engines`, the wasm gates and the
  remaining 50-odd preflight gates — **deliberately not run**, per the round's floor; CI owns them.
  ⚠️ This diff is `compiler/types` + a comment in `compiler/eval`, **not** `compiler/backend`, so no
  seed re-mint is implied — but the fixpoint is still the decisive gate for the merge candidate.
* I did not re-run F1's other five findings; nothing here targets them.
* I did not verify the widening against the 193-project multi-module fixture corpus.

🔗 **`DECISIONS.md` cross-ref (owed from you, not written by me):** this row rests on a ruling I
made and you own — **the S1 is closed by unifying the STAMPER's substrate, and it does NOT require
identity-in-routes (#1113 / Phase 3′).** The argument: the defect was the *population* the guard
read, not the *word* the route carries. Two same-spelled heads still mint one word (`implKeyTc` is
a pure rendering, `:18268`) and #1397/#1514 still REPRO — that half is untouched and stays #1113's.
R3's *"pending #1113"* qualifier on conjunct 2 therefore still stands after this bite; what changes
is that organ 2's **prefix reader is gone**, so `R3`'s organ table row 2 ("🔴 THE GAP") can be
re-graded, and the `ImplBuckets` readers are down to two (`findImplEntry`'s `iface == ""`
first-match arm and `argImplDictRoutesFor`) — both enumerated in the `#1128` audit bullet I updated.
