# R4 — repair round, first job: attacking `DEBT.md`'s `could move:` / `nearest miss:` columns

**Pin `61c4eebd`. Read-only: I built nothing, ran no gate, ran no `./medaka`.** Every source
citation is `file:line @61c4eebd`, derived by `git show 61c4eebd:<path>`. Every finding whose
verdict needs a binary is labelled **⚠️ UNVERIFIED — needs a probe** with the exact command; the
programs are written out in full at the bottom so the orchestrator can run them without redesign.

Ranked most-severe first. **Two retractions are included — both are good outcomes.**

---

## F1 — S0-shaped. `b2`/`g`'s tie-break bullet is understated by roughly two levels: the change is to the candidate **SET**, not to the **ORDER** of an already-arbitrary decision. ⚠️ UNVERIFIED

**The claim under attack**, `DEBT.md:1164-1168` (`b2`) and restated verbatim at `1800-1808` (`g`
item 5):

> *"at a non-closed, no-unique-minimum multi-module goal the fallback moves from **arbitrary** … to
> **graph-global declaration order**. … The non-closed goal is still silently decided by list order;
> **only the order is now statable**."*

That sentence is filed as a spec improvement — a previously-unstatable internal constant becomes a
statable one. **It is true about the ordering and silent about the thing that actually moved.**

**Derivation.** The selector's *input* changed substrate, not just its sort key:

* `ieCandidatesForIface` / `ieCandidatesForMethod`, `typecheck.mdk:18969-18980` — merge the goal's
  head bucket with the headless bucket, both from `ieHeadRows` (`4390-4391`) over
  `ieByHead` (`4092`), which `buildImplEnv` (`4134-4143`) folds across **every module in the
  envelope**. The predecessor it replaced, `candidateBucket`, read `universeKeyBucketsRef` — the
  module's **topological prefix** (`b2` row, `DEBT.md:1114-1120`; `mergeByDeclIdx`'s own obituary,
  `typecheck.mdk:18449-18457`).
* `pickMostSpecificEntry`, `typecheck.mdk:18506-18512` — `findMostSpecificEntry` first; on `None`
  (⊑-**incomparable overlap** only, per its own corrected note at `18471-18482`) it calls
  `reportAmbiguousOverlap` and then returns **`Some e` — the head of the list**.
* `reportAmbiguousOverlap` is gated on **CLOSEDNESS** (`typecheck.mdk:18517-18527`): a goal still
  carrying an unbound metavariable is deferred, *not* reported.

So a goal that had exactly **one** candidate in its prefix can now have **two**. Three outcomes;
the row records only the third:

| | candidates | goal | base (prefix) | branch (graph-global) | recorded? |
|---|---|---|---|---|---|
| (a) | ⊑-comparable | any | 1 cand → forced | min⊑ wins | ✅ this is the drain |
| (b) | ⊑-incomparable | **closed** | 1 cand → **accepted** | `T-AMBIGUOUS-INSTANCE` → **rejected** | ❌ **nowhere** |
| (c) | ⊑-incomparable | **non-closed** | 1 cand → forced, deterministic | **silent head-of-list pick**, exit 0 | ⚠️ recorded only as "the order is statable" |

**Why the understatement matters.** For (c) the row's framing implies the decision was *already*
order-decided and merely became statable. It was not: at a one-candidate goal there is no order to
decide anything — the answer was forced. The population of goals *reaching the silent fallback at
all* grew, and every newly-reaching goal moves from **forced-and-correct** to
**decided-by-graph-global-declaration-order**. **Worst realisation: a different impl is selected
than at base, at exit 0, with no diagnostic on any verb.** That is a wrong binary at exit 0.

For (b) the worst realisation is milder but is a **reject-widening that no row claims**. `f`'s
`could move:` (`DEBT.md:1502-1521`) enumerates a named reject-widening set and scopes it entirely to
`keyForSite`'s **count guard**; `g` then reports that set drained. Neither row mentions
`pickMostSpecificEntry`'s **ambiguity arm**, which is a different guard on a different function and
is not covered by `g`'s repoint.

**Why no gate can see it.** (c) is diagnostic-free and value-only, so `check`-graded rows are blind;
`diff_compiler_engines` is upstream-blind (see **F3**); the `a1` FLAT-vs-Module rows are on a path
where prefix == whole program, which `b2`'s own `unchecked:` calls *"inert as evidence about the
drain"* (`DEBT.md:1261-1267`).

**Discriminator: D1.** Falsifies F1 outright if branch == base on both orders.

---

## F2 — S0-shaped. The *"not identical arithmetic"* parenthetical is not a footnote: the arithmetic is unchanged but its **operand set** is not, and that is exactly how the divergence goes live. ⚠️ UNVERIFIED

**The claim under attack**, `DEBT.md:1161-1163`, mirrored in the source at
`typecheck.mdk:19059-19061` and `core_ir_lower.mdk:1355-1357`:

> *"⚠️ Not identical arithmetic: that side counts DISTINCT canonical keys, this one counts rows — a
> pre-existing difference `ifaceDeclHeadUnique`'s own comment records, **unchanged here and not
> claimed as fixed**."*

Both halves of that are literally true and together they license the wrong conclusion. The
paragraph's whole point is that the two sides *"now count the same population"* — and the
parenthetical then concedes they compute different functions **of that population** while calling
the difference "pre-existing". **The difference is pre-existing; its reachability is not.**

**Derivation — the two functions, and exactly when they disagree.**

* typecheck side, **rows**: `ieHeadCollidesByIface env iface hd = ieCountHeadByIface env iface hd > 1`
  (`typecheck.mdk:19076-19077`) → `ieCountHeadByIfaceGo` (`19156-19161`) adds **`1 +`** per matching
  row, no dedup.
* emitter side, **distinct keys**: `ifaceDeclHeadUnique iface tag = listLen (declKeysAtHead … ) <= 1`
  (`core_ir_lower.mdk:1361-1363`) → `declKeysAtHead` (`1365-1370`) accumulates only when
  **`not (contains k acc)`** — an explicit dedup on the canonical key `k`.
* They disagree **iff two rows at one (iface, head) share a canonical key** `implKeyTc ir.irName tys`
  (`typecheck.mdk:18915`). `implKeyTc` is built from the interface **name** and the `tys`
  **spelling**, and the bucket key is spelling-keyed too (`headBucketKey` → `dispHeadTab`,
  `18234-18236`; the full derivation for why spelling and not identity is at `19079-19135`). So the
  shape is: **two unrelated modules each declaring their OWN type of the SAME NAME, each with an
  impl of the same interface** — i.e. precisely the `#1397`/`#1514` class.

**What moved.** Before `b2`, the typecheck side counted the importer's **prefix**, so the
disagreement required *both* rows inside that prefix — normally impossible for two mutually
non-importing modules. After `b2` it requires only that both rows **exist anywhere in the graph**.
The population in which the two sides can disagree is therefore **strictly wider, and newly live**.

**Consequence when they disagree.** `keyForSiteByIface` (`typecheck.mdk:19062-19072`) stamps
`implKeyTc ir.irName tys` when its own count says "collides", while the emitter, counting one
distinct key, says unique and derives the **bare head word**. That is the dict-word skew
`keyForSite`'s own #1128 note calls *"invisible on the direct-call path … and **live on the RDict
path**"* (`19097-19102`) and which `19104-19121` records as **measured, not predicted** (#1317: the
same two scans, three instrumented builds, `(1,2)` → `(1,1)`, *"a valid program, exit 0, wrong
answer, no diagnostic"*).

**Why nobody has looked.** `f` built the **method**-keyed instance of this exact guard and it
immediately over-fired on `#1397` and `#1514` (`DEBT.md:1522-1541`) — direct evidence that the
same-spelling shape reaches a graph-global head count. `g` then repointed the *method* word and both
pins returned to REPRO (`DEBT.md:1756-1766`). **The `iface`-keyed count `ieHeadCollidesByIface` was
left graph-global throughout and nobody ran the same-spelling shape through it.** `b2`'s Item 4
(`DEBT.md:1216-1220`) discusses this skew in the *method*-keyed direction only and calls the
iface-keyed instance drained via #1072 — but #1072 is a *bare-head* fixture, not a same-spelling one,
so it cannot exercise the rows-vs-keys disagreement at all.

**Worst realisation: exit 0 from `check` and a built binary that routes through the wrong dict cell**
— either the wrong impl's body, or the general-instance fallback tier
(`emitGeneralRKey` → `findByTag noneHeadTag`), which `g` itself flags as *"empirical, not
structural"* (`DEBT.md:1812-1814`).

**Discriminator: D2.** ⚠️ **Grade the MECHANISM (the stamped word in the `.ll`), not the exit code** —
an exit-code-graded control answers the wrong question here, and the two words can coincide by luck
on any single fixture.

---

## F3 — S2. `EX-3` names `diff_compiler_engines` as *the* discriminator for the semantic question. It cannot be — the change sits **upstream of the engine split** — and the row carries the rule that says so two bullets later. **VERIFIED by derivation.**

`DEBT.md:2558-2563` (`EX-3`'s `nearest miss:`):

> *"The genuinely unsettled part is **semantic**, and the discriminator is not a golden at all: it is
> `diff_compiler_engines` (**0 regressions / 0 promotions / 0 pinfail across 583 fixtures**) plus the
> `must_fail` drain reproducing twice. **Those are behavioural and they agree.**"*

`diff_compiler_engines` compares **eval == native == wasm on the same binary**. Everything this
sprint moved lives in `compiler/types/typecheck.mdk` — the route word and the selected impl are
**stamped before** the engines diverge (`b2`'s own `engines:` line, `DEBT.md:1225-1231`: *"no engine
arm moved, because no engine source changed"*). A wrongly-selected impl or a wrongly-stamped word is
therefore delivered **identically to all three engines**, and the gate reports agreement. It is
structurally incapable of separating "right" from "consistently wrong" for this diff.

The row states the governing rule itself, 80 lines later (`DEBT.md:2640-2642`): *"value goldens
cannot see a diagnostic-only change, absence probes cannot see an undercount, and **eval agreement
proves nothing on a dispatch shape**."* The `nearest miss:` leans on the gate anyway. **The
`nearest miss:` as written is therefore not merely understated — its stated remedy is invalid**, and
the honest attack it invites (*"you did not prove any owning source edit was right"*) is left with
**no** behavioural backstop except six hand-built per-bite 4-arm tables over roughly a dozen
programs.

**What is actually missing:** the whole sprint contains **no base-vs-branch value differential over
any corpus**. Every base column in `DEBT.md` is a hand-built table on a program written to exhibit
the bug being fixed. **Discriminator: D4.**

---

## F4 — S2, and it is the *"what happens to code that has NOTHING to do with it"* answer: the tree's only recorded answer is *"it is still silently wrong, and that is not a regression."*

Asked directly of this sprint: the landed change makes **instance candidacy graph-global**, so two
modules that import nothing from each other now contribute candidates to each other's dispatch. The
only fixtures in the tree that exercise a genuine bystander are `#1397`'s
(`aamod`/`zzmod`/`zzmod_distinct`) and `#1514`'s (which literally ships a `bystander.mdk`) — and
`g` deliberately returned **both to REPRO** (`DEBT.md:1756-1766`), i.e. to their original silent
wrongness. That is a defensible call (`f`'s guard over-fired and cost `#1514` a working binary), but
it means **the sprint's recorded answer to the unrelated-code question is "still broken"**, and no
row anywhere asserts positively that a module importing none of the moved dispatch surface behaves
as it did at `2b9dc798`. The acceptance rows that look like they would (`a1`'s FLAT-vs-Module pins)
are disowned as evidence by `b2` itself (`DEBT.md:1261-1267`). **Discriminator: D4**, which is the
same probe F3 needs — one run answers both.

---

## F5 — S3, perf. `EX-3`'s perf clearance and `a2`'s *"LINEAR BY DESIGN"* banner both grade an axis the change is not on. ⚠️ UNVERIFIED

`DEBT.md:2626-2632`: *"`ops typecheck: ok r1=1.20 r2=1.33` … **sub-linear, so the graph-global `IE`
substrate did not introduce a quadratic** in the stage that now reads it."*

The scans this sprint made graph-global are **O(rows in ONE head bucket) per dispatch site**:
`ieEntriesForIface`/`…ForMethod` (`typecheck.mdk:18934-18949`), `ieCountHeadByIfaceGo`
(`19156-19161`), and `ieRowOfEntry`'s re-scan of the same bucket for the winner
(`19013-19021`) — plus `keyEntryOfRow` (`18912-18915`) building a fresh `implKeyTc` **string per
matching row per site**, where the deleted `KeyBuckets` held those `KeyEntry` values **precomputed
once**. So the cost axis is *impls sharing one head*, times *dispatch sites*.

**`perf_scaling`'s corpus has no dimension in which one head bucket grows.** `gen_wasm_dispatch`
(`test/diff_compiler_perf_scaling.sh:481-499`) emits N interfaces each with one impl at a **distinct**
type `T$i` ⇒ N buckets of **size 1**; `gen_modules` (`:273`) is a fixed **K=8** impls per module.
The green is real and grades the wrong axis — an absence probe that cannot see this undercount.

Separately, `buildFlatImplEnv`'s 🚨 banner (`typecheck.mdk:4176-4188`) — *"LINEAR BY DESIGN, AND THAT
IS WHY IT DOES NOT CALL `ieAddRows`"* — is **false as written**. It removes `ieInsertRow`'s
`env.ieRows ++ [r]` (`4318`), correctly, but `ieIndexRows` → `ieFileRow` → `ieFileRowByHead`
(`4205-4207`, `4341-4343`, `4377`) still calls `mregAppendK`, which is `vs ++ [v]`
(`registry.mdk:706-711`) — **O(bucket²) per bucket, on every single-file compile, including
per-keystroke LSP**, since `a2` seats this on the FLAT arm reached by `check`/`lsp`/`repl`/`doc`/
`lint`/`snapshot` (`4149-4152`). Magnitude is small today (`a3`: `maxbucket=16`), which is why this
is S3 and not higher — but the banner claims a **structural** property the function does not have,
and `a3`'s `maxbucket=16` is a measurement of *the compiler's own graph*, not a bound on user code.

---

## Retractions — two claims I attacked and could not break

**R-a. `ieRowOfEntry` really is an exact inverse, not a search. `b2`'s claim HOLDS.**
`DEBT.md:1110-1113` asserts the winner's row is in *"the bucket of its own head — which is the
`KeyEntry`'s own `hd` field, same `headTyconTy` mint."* I tried to falsify it via a head projection
that could differ between the file side and the entry side. It cannot: `keyEntryOfRow` stamps
`hd = headTyconTy headTy` (`typecheck.mdk:18915`); `ieFileRowByHead` files under
`headBucketKey (univReceiverTag tys)` (`4377`); and `univReceiverTag (headTy::_) = headTyconTy headTy`
(`22318-22320`). Same projection, same bucket, single scan. **Retracted — no probe needed.**

**R-b. `EX-3`'s 4th-re-signature attribution HOLDS — but its stated remedy is unrunnable, and that
is a real S3 finding on top of a correct claim.**
`EX-3` (`DEBT.md:2567-2571`) resolves whether `keyForSite`'s re-signature belongs to `g` or is an
unclaimed semantic change, and instructs: *"a reviewer who distrusts that should **re-run that
script**, not re-read this row"* — citing `scratchpad/attrib.sh`, plus seven siblings at
`DEBT.md:2645-2650`.

**None of those eight scripts exists in any commit, or on disk.** Derived:
`git log --oneline --all -- scratchpad/attrib.sh scratchpad/percommit.sh scratchpad/srcmoved.sh` →
**empty**; `git ls-tree -r 61c4eebd --name-only | grep -c scratchpad` → **0**; the directory is
absent from the working tree. `61c4eebd`'s own commit message teaches exactly this lesson for
`EX-2`'s **one** dangling citation (*"the dangling path should be corrected by whoever next edits
that row"*) and **misses `EX-3`'s eight**.

I therefore derived the claim independently, which is what the row should have shipped:

```
git show 2b9dc798:compiler/types/typecheck.mdk | grep -m1 '^keyForSite :'
#   keyForSite : KeyBuckets -> String -> List Mono -> Option String
git show 086aeb35:compiler/types/typecheck.mdk | grep -m1 '^keyForSite :'   # = bite f
#   keyForSite : KeyBuckets -> String -> List Mono -> Option String
git show 26423f93:compiler/types/typecheck.mdk | grep -m1 '^keyForSite :'   # = bite g
#   keyForSite : String -> List Mono -> Option String
```

`g` moved it. **`EX-3`'s attribution is CORRECT and I am not disputing it** — only recording that
its evidence was unreachable and that a one-line `git show` pair belongs in the row instead of a
deleted script. **Repair action:** replace the eight `scratchpad/*.sh` citations with the three
commands above (or delete them), the same correction `61c4eebd` already prescribed for `EX-2`.

---

# Discriminators — written out, ready to run

**Standing rules for all four** (from AGENTS.md, and each has bitten in this repo):
`medaka build`'s exit code **does not survive a pipe** — redirect to a file and read `$?`, then read
the file. A copied binary resolves `stdlib/` **and `runtime/`** from **its own directory**, and the
missing `runtime/` bites only on the **first `build`** — so a two-arm differential needs
`medaka` + `medaka_emitter` + `stdlib/` + `runtime/` beside each binary, or two worktrees. Check that
neither `MEDAKA_ROOT` nor `MEDAKA_EMITTER` is exported in your shell before believing any arm.

Base arm = `2b9dc798` (the sprint's parent). Branch arm = `61c4eebd`.

---

## D1 — F1: does the widened candidate set change or reject a program that base accepted?

Two ⊑-**incomparable** impls at one head, in two modules; the goal's module has **one** of them in
its topological prefix and the other **after** it.

`/var/tmp/r4-d1/iface.mdk`
```
public export data Pair a b = Pair a b

export interface Lab t where
  lab : t -> String
```

`/var/tmp/r4-d1/m1.mdk`
```
import iface.{Lab, lab, Pair}

export impl Lab (Pair Int b) where
  lab _ = "m1-int-left"
```

`/var/tmp/r4-d1/m2.mdk`
```
import iface.{Lab, lab, Pair}

export impl Lab (Pair a Bool) where
  lab _ = "m2-bool-right"
```

`/var/tmp/r4-d1/use.mdk`
```
import iface.{Lab, lab, Pair}

export useIt : String
useIt = lab (Pair 1 True)
```

`/var/tmp/r4-d1/main.mdk` — **the discriminating order: `m2` lands AFTER `use`**
```
import iface.{Lab, lab, Pair}
import m1
import use.{useIt}
import m2

main = putStrLn useIt
```

`/var/tmp/r4-d1/control.mdk` — **`m2` BEFORE `use`; differs from `main.mdk` in import order alone**
```
import iface.{Lab, lab, Pair}
import m1
import m2
import use.{useIt}

main = putStrLn useIt
```

Run, both binaries, both entry files, all four arms:
```sh
for B in /path/to/base /path/to/branch; do for E in main control; do
  $B/medaka check /var/tmp/r4-d1/$E.mdk        > /var/tmp/d1.$E.chk 2>&1; echo "check $E $B -> $?"
  $B/medaka check --json /var/tmp/r4-d1/$E.mdk > /var/tmp/d1.$E.json 2>&1; echo "json  $E $B -> $?"
  $B/medaka run   /var/tmp/r4-d1/$E.mdk        > /var/tmp/d1.$E.run 2>&1; echo "run   $E $B -> $?"
  $B/medaka build /var/tmp/r4-d1/$E.mdk --keep-ir -o /var/tmp/d1.$E.bin > /var/tmp/d1.$E.log 2>&1
  echo "build $E $B -> $?"; /var/tmp/d1.$E.bin; echo "bin   $E $B -> $?"
done; done
```

**How to read it.** Base `main.mdk` is expected `0, m1-int-left` (one prefix candidate, forced).
* Branch `main.mdk` = `1` + `T-AMBIGUOUS-INSTANCE` ⇒ **F1(b) confirmed: a new reject of a program
  base accepted**, and it is outside `f`'s enumerated widening set. **S1.**
* Branch `main.mdk` = `0` with a value **different from base's** ⇒ **F1(c) confirmed: silent
  dispatch change at exit 0. S0.**
* Branch `main.mdk` == base on **both** orders ⇒ **F1 retracted for this shape**; then re-try with
  `useIt` given **no type signature** (`export useIt = lab (Pair 1 True)` used at two different
  instantiations) to push the goal to non-closed, which is the arm (c) actually needs.

`control.mdk` is the fixture-integrity control: it must compile on **both** binaries. If it does
not, the fixture is wrong, not the compiler.

---

## D2 — F2: rows-vs-distinct-keys on the **iface-keyed** leg. Grade the stamped word, not the exit code.

Same-spelled types in two mutually non-importing modules, both `impl`-ing one interface **with a
`requires`**, so the site reaches `keyForSiteByIface` via the RDict path (`b2`'s leg 2b).

`/var/tmp/r4-d2/iface.mdk`
```
export interface Tag t where
  tagOf : t -> String

export impl Tag Int where
  tagOf _ = "int"
```

`/var/tmp/r4-d2/w1.mdk`
```
import iface.{Tag, tagOf}

public export data Wrap a = Wrap a

export impl Tag (Wrap a) requires Tag a where
  tagOf (Wrap x) = "w1(\{tagOf x})"
```

`/var/tmp/r4-d2/w2.mdk` — **its own, unrelated type, spelled identically**
```
import iface.{Tag, tagOf}

public export data Wrap a = Wrap a

export impl Tag (Wrap a) requires Tag a where
  tagOf (Wrap x) = "w2(\{tagOf x})"
```

`/var/tmp/r4-d2/nest1.mdk`
```
import iface.{Tag, tagOf}
import w1.{Wrap(..)}

export nest1 x = tagOf (Wrap x)
```

`/var/tmp/r4-d2/main.mdk` — `w2` present in the graph, imported by nobody `nest1` can see
```
import iface.{Tag, tagOf}
import nest1.{nest1}
import w2

main = println (nest1 5)
```

`/var/tmp/r4-d2/control.mdk` — **identical minus `import w2`**
```
import iface.{Tag, tagOf}
import nest1.{nest1}

main = println (nest1 5)
```

The correct answer on **both** entries is `w1(int)`.

```sh
for B in /path/to/base /path/to/branch; do for E in main control; do
  $B/medaka build /var/tmp/r4-d2/$E.mdk --keep-ir -o /var/tmp/d2.$B.$E.bin > /var/tmp/d2.$B.$E.log 2>&1
  echo "build $E $B -> $?"; /var/tmp/d2.$B.$E.bin; echo "bin $E $B -> $?"
done; done
grep -nE '@mdk_impl_[A-Za-z0-9_]*Wrap|@mdk_dc_|Tag__Wrap' /var/tmp/d2.*.main.bin.ll
```

**The grade is the word, not the exit code.** `⚠️ (memory: an exit-code-graded control answers the
wrong question)` — read the `.ll` and answer: **does the key typecheck stamped into the caller's
dict cell match the word the emitter derived for the impl?**
* stamped **canonical** (`Tag__Wrap_a__`-shaped) while the emitter defines/registers under the
  **bare head word** ⇒ **F2 confirmed — the skew is live. S0.**
* both bare, `main` and `control` both print `w1(int)` on both binaries ⇒ **F2 retracted for this
  shape**; then re-try with the two `Wrap`s under **different interfaces sharing a method name**,
  which is the other way `implKeyTc` can collide.
* `main` differs from `control` on the branch binary at all ⇒ finding regardless of mechanism: a
  module nobody imports changed the program's meaning. **This is also the F4 probe in miniature.**

---

## D3 — F5: the perf axis nothing measures. One head, many impls.

Add one generator to a **scratch copy** of `test/diff_compiler_perf_scaling.sh` (do not commit — a
new `test/*.sh` reds `diff_compiler_ci_shard_coverage`, which is what `61c4eebd` itself is a cleanup
of). N interfaces, **one shared head type**, N dispatch sites:

```sh
gen_onehead() {                       # $1 = N, $2 = outfile
  f="$2"; : > "$f"
  printf 'data T = T Int\n' >> "$f"
  i=1; while [ "$i" -le "$1" ]; do
    printf 'interface Sh%s a where\n  sh%s : a -> Int\n' "$i" "$i" >> "$f"
    printf 'impl Sh%s T where\n  sh%s _ = %s\n' "$i" "$i" "$i"     >> "$f"
    i=$((i+1))
  done
  printf 'total : Int\ntotal = ' >> "$f"
  i=1; while [ "$i" -le "$1" ]; do printf 'sh%s (T 1) + ' "$i" >> "$f"; i=$((i+1)); done
  printf '0\n\nmain = println total\n' >> "$f"
}
```

Grade the **allocation/op** arm at N=200→400→800, base vs branch. Contrast with
`gen_wasm_dispatch`, which puts each impl at its **own** head (`T$i`) — that is why the committed
corpus cannot see this. A ratio near 2.0 per doubling refutes F5; near 4.0 confirms it.

---

## D4 — F3 + F4: the base-vs-branch **corpus** differential this sprint never ran.

Not a golden run and not an engine run — **the same corpus through two binaries, values compared to
each other.**

```sh
for f in test/eval_modules_fixtures/*/main.mdk test/llvm_fixtures_modules/*/main.mdk; do
  /path/to/base/medaka   run "$f" > /var/tmp/d4.base.out 2>&1; rb=$?
  /path/to/branch/medaka run "$f" > /var/tmp/d4.brch.out 2>&1; rr=$?
  if [ "$rb" != "$rr" ] || ! cmp -s /var/tmp/d4.base.out /var/tmp/d4.brch.out; then
    echo "MOVED: $f  base=$rb branch=$rr"; diff /var/tmp/d4.base.out /var/tmp/d4.brch.out
  fi
done
```

**This is the only probe in the sprint that can fail for a reason nobody predicted**, and it is the
one that answers *"what happens to code that has nothing to do with this change?"* Every hit is
either an intended drain (name the bite) or an unclaimed semantic change. **A clean run is the
positive evidence `EX-3`'s `nearest miss:` reaches for and `diff_compiler_engines` cannot supply.**
Extend to `test/wasm/fixtures_modules/` if it comes back clean — and word-bound the glob, since
`llvm_fixtures`/`llvm_fixtures_modules`/`llvm_fixtures_typed` are three real sibling corpora.

---

## Summary of DEBT.md rows whose severity I believe is understated

| row | claim | filed as | I believe |
|---|---|---|---|
| `b2` 1164-1168 / `g` 1800-1808 | *"only the order is now statable"* | spec improvement | **S0-shaped** — candidate **set** widened; silent impl change at exit 0, plus an unclaimed reject-widening. **No gate.** |
| `b2` 1161-1163 | *"not identical arithmetic … pre-existing"* | parenthetical footnote | **S0-shaped** — operand set widened ⇒ a pre-existing skew becomes newly reachable on the iface-keyed leg. Untested. |
| `EX-3` 2558-2563 | *"the discriminator … is `diff_compiler_engines`"* | settled | **S2** — invalid inference; the gate is upstream-blind to this diff. The row states the governing rule 80 lines later. |
| `EX-3` 2567-2571, 2645-2650 | *"re-run that script"* | reproduction | **S3** — the eight cited scripts exist in no commit. Claim itself **holds** (re-derived above). |
| `EX-3` 2626-2632 | *"did not introduce a quadratic"* | perf clearance | **S3** — grades an axis the corpus does not scale. |
| `a2` `typecheck.mdk:4176` | *"LINEAR BY DESIGN"* | structural | **S3** — `mregAppendK` is `vs ++ [v]`; O(bucket²) survives on every single-file compile. |
