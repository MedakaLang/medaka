# R6 — the four engine arms, and the ungated surface

**Pin `61c4eebd`. Read-only: I built nothing, ran no gate, ran no `./medaka`.** Every claim below is
either derived from source at the pin (cited) or labelled **⚠️ UNVERIFIED** with the exact command.

---

## 0. What the sprint actually changed, at the pin

`git diff 2b9dc798 61c4eebd -- compiler/` touches **three** files:

| file | change |
|---|---|
| `compiler/types/typecheck.mdk` | **+1819/−…** — the whole substance |
| `compiler/ir/core_ir_lower.mdk` | **comment-only** (12 lines, two doc blocks) |
| `compiler/types/registry.mdk` | **comment-only** (7 lines, one doc block) |

**No engine arm was edited.** So the whole engine question is: *what do the four arms consume that
the typecheck-side change moved?* There is exactly one such thing, and it is the one that matters.

**The changed axis is the ROUTE WORD POPULATION.** `keyForSite` / `keyForSiteByIface`
(`typecheck.mdk:18383-18409`) now read `perRun.bodyImplEnvRef` — the **graph-global `IE`** — where
before B-2.1-b2/g they read the **topological-prefix** `shadowKeyTableRef`. The word they return is
stamped into the AST as `Route` (`RKey key reqs`, `ast.mdk`), and **all four arms consume `Route`**:

- **eval** — `evalMethodAt` / `dictOfRoute` / `methodAtNarrow` (`eval.mdk:1114-1189, 1345`).
- **core_ir_eval** — `ceval env (CMethod name route implRoutes methRoutes)`
  (`core_ir_eval.mdk:170-173`); the routes are read out of the typed AST at lowering time and
  **core_ir_eval re-uses eval's own `methodAtNarrow`/`applyMethodDicts`** (imported, `:79`).
- **LLVM / wasm** — the same `Route` reaches the emitters through Core IR; the emitted dict word
  must byte-match `core_ir_lower.declRouteKey` (`core_ir_lower.mdk:1346-1347`).

The sprint's own commit message on `core_ir_lower.mdk` states the reconciliation: the checker side
"now counts the graph-global `IE`, i.e. the same population" as `lowerProgramEmit allDecls`. **See
F-1 below for the half of that sentence that is not reconciled.**

---

## 1. The four-arm × changed-axis table

Guarding gate = a gate that, at the pin, **could go red** if this arm's behaviour on this axis
regressed. "**none**" is a finding.

| axis \ arm | LLVM | wasm | eval | **`core_ir_eval`** |
|---|---|---|---|---|
| **A1** route word, **cross-module** (`keyForSite*` → graph-global `IE`) — the bite that landed | `diff_compiler_llvm_modules`, `diff_compiler_check_cli_modules` (IR order-invariance), `selfcompile_fixpoint` | `test/wasm/diff_wasm_modules.sh` (36 fixtures, full front end, vs native oracle) | `diff_compiler_eval_modules` | 🚨 **none** |
| **A2** route word, **flat / 1-module** (B-2.1-a2 seated a populated `IE` on the FLAT arm, which was `emptyImplEnv`) | `diff_compiler_llvm_typed_ir`, `diff_compiler_llvm_typed` | `test/wasm/diff_wasm_typed.sh` | `diff_compiler_flat_vs_onemodule` (13 rows), `diff_compiler_eval` | `diff_compiler_core_ir_typed` (via `core_ir_typed_main` → `elaborateOne`) |
| **A3** specificity **score** (`CImplEntry name score …`) | producer unchanged (`lowerImplMethod`, `core_ir_lower.mdk:1396-1404`) | same | `declImplEntries` | producer unchanged — `tyvarsInArgs typeArgs` is pure-AST |
| **A4** interface-default **iface identity** (`CImplDefault ifaceId`, `defaultCellName`) | unchanged this sprint | unchanged | unchanged | producer unchanged (`core_ir_lower.mdk:1382`, `core_ir_eval.mdk:431-451`) |
| **A5** **tie-break order** between two equally-⊑ candidates (`mergeEntries` "Ties keep the LEFT operand", `pickMostSpecificEntry`) | 🚨 **none** | 🚨 **none** | 🚨 **none** | 🚨 **none** |
| **A6** **impls-per-head cost** (`ieHeadRows` bucket scan; `ieCountHeadBy*Go` is O(bucket) per site) | 🚨 **none** — `diff_compiler_perf_scaling` scales **declarations**, not impls-per-head | **none** | **none** | **none** |
| **A7** **agreement** between the checker's stamped word and the emitter's defined symbol | 🚨 **none as a property** — only `check_cli_modules`' hand-written SA-4c row, one shape | **none** | n/a | **none** |

**A3/A4 are RETRACTIONS of my own starting assumption.** The brief told me `core_ir_eval` "builds
its own `VTypedImpl` and registers its own default cells — check those producer sites against what
the sprint changed." I checked them (`core_ir_eval.mdk:432-455`, `:587-588`): they are fed
**entirely** by `CImplEntry`/`CImplTagged`/`CImplDefault` from `core_ir_lower.lowerImplMethod` /
`lowerDefault`, whose inputs are `headTyconHead typeArgs`, `implKeyOf`, `tyvarsInArgs`,
`ifaceIdentity o ifaceName` — **all pure-AST, none typecheck-derived, and `core_ir_lower.mdk` was
comment-only this sprint.** The bites that *would* have moved them (`B-2.4-a`/`B-2.4-b`, which
`.claude/sprint-b/design/D2-phase5-engines.md:197-207` marks "✅ REQUIRED, `:453-455`") are **Phase
5 and did not land.** So the "owed and never paid" debt on `core_ir_eval` is **not** on its
producer sites. It is on A1, and A1 is worse than the debt ledger says.

---

## 2. Findings, by severity

### 🚨 F-1 — S0-candidate · ⚠️ UNVERIFIED — *the two sides now share a population but not an arithmetic*

`core_ir_lower.mdk:1349-1360` (added by this sprint, in the same breath as the reconciliation):

> *"It now counts the graph-global `IE`, i.e. the same population. **The arithmetic still differs
> and that difference is pre-existing: this side counts DISTINCT canonical keys, that side counts
> rows.**"*

That is verified in source, both sides, at the pin:

- **lower**: `declKeysAtHead` (`:1367-1373`) accumulates `not (contains k acc)` → **distinct keys**;
  `ifaceDeclHeadUnique` = `listLen … <= 1`.
- **typecheck**: `ieCountHeadByIfaceGo` / `ieCountHeadByMethodGo` (`typecheck.mdk:19156-19161`,
  `:19228-19233`) are `1 + …go rest` → **rows**.

Whenever the same canonical key occupies **two rows** at one `(iface, head)`, the two sides reach
**opposite** verdicts: typecheck sees `2 > 1` → collision → stamps `implKeyTc` (the full canonical
key); lower sees `1` distinct → `declRouteKey tag key True` → the **bare tag**. The stamped dict
word then does not name the defined impl. That is a silent dispatch miss, not a diagnostic.

`core_ir_lower.mdk:1350-1352` states such duplicate rows **do occur**: *"a re-imported prelude impl
appears in the joint decl list twice under ONE key"*. `IE` is built from that same list value —
`declEnvDeclsOf` is documented at `typecheck.mdk:2853-2857` as *"the same LIST VALUE the two drivers
built as `coreDecls ++ flatMap snd modules`"* — and `ieInsertRow` (`:4317-4318`) appends
**unconditionally, with no key dedup**.

**Two things I could not settle read-only, and they decide the severity:**

1. **Is it pre-existing or introduced?** The comment asserts "pre-existing". That assertion is
   ungated prose written by the bite's own author, and it is exactly the shape my brief warns
   about. If the *prefix* table this leg read before B-2.1-b2 was key-deduped (it fed
   `selectImplEntryByIface`, an entry table), then **widening to a row list introduced the
   discrepancy**, and F-1 is a sprint regression, not inherited debt.
2. **Does the duplicate actually reach a *cross-module* `IE`?** `buildImplEnvGo`
   (`typecheck.mdk:4139-4143`) folds **one `DeclEnvModule` per module**, each with its own
   `demDecls` — so the prelude appears once on the MODULE arm. The duplicate is likely reachable
   only on the **FLAT / doctest-flatten** arm (which B-2.1-a2 newly populated, from
   `emptyImplEnv`) — and that arm was *empty* before this sprint, which points at **introduced**.

**No gate can see F-1** (row A7): no gate compares the checker's word to the emitter's symbol as a
property. `grep -rln 'declRouteKey\|ifaceImplRouteKeys\|ifaceDeclHeadUnique' test/*.sh test/wasm/*.sh`
returns exactly **one** file — `diff_compiler_check_cli_modules.sh`, the sprint's own hand-written
SA-4c row, which pins **one** shape.

### 🚨 F-2 — S1 · **VERIFIED IN SOURCE** — *no gate runs `core_ir_eval` on the TYPED MULTI-MODULE path*

This is the concrete content of the "owed and never paid" debt, and it is structural, not a
scheduling accident. Read the entries:

| gate | entry | typed? | multi-module? |
|---|---|---|---|
| `diff_compiler_core_ir_modules.sh` | `core_ir_modules_main.mdk` | ❌ **desugar + `annotateProgram` only** (`:20,:33-45`) — **no marker, no typecheck** | ✅ `cevalModules` |
| `diff_compiler_core_ir_typed.sh` | `core_ir_typed_main.mdk` | ✅ `elaborateOne` (`:19,:34`) | ❌ single-file `cevalOutput` (the **FLAT** arm) |
| `diff_compiler_core_ir_run.sh` / `…_core_ir.sh` | `core_ir_run_main` / `core_ir_main` | ❌ `annotateProgram` | ❌ |
| `diff_compiler_engines.sh` | — | — | **three arms only**: eval · native · wasm (`:6-8`). `core_ir_eval` is not one. |

So `cevalModules` — the parallel module driver `AGENTS.md` names in the precedent — is exercised by
**exactly one gate, on the UNTYPED path, where no `Route` is stamped at all** and dispatch falls
back to arg-tag *first-impl-wins*. **The shared `test/eval_modules_fixtures/*/` corpus that
`AGENTS.md` cites as the P0-9 precedent does not save you here**: its `core_ir` consumer is looking
at a *different pipeline*, not merely a lagging one. A route-word regression is invisible to it **by
construction**, and it would have been invisible even if the gate had been green all sprint. The
"its gates were on the known-red list, so a run wouldn't inform" reasoning happened to reach the
right operational conclusion for the wrong reason — the run would not have informed **even green**.

### ⚠️ F-3 — S2 · **VERIFIED** — *wasm's single clean observation was on a corpus that does cover A1*

Better news than the ledger implies. `test/wasm/diff_wasm_modules.sh` drives
`wasm_emit_modules_main` through the **full `medaka build` front end** (`:4-8`) over **36**
`fixtures_modules`, diffed against the native oracle. So wasm's A1 cell is genuinely gated; the
sprint's exposure is *one observation*, not *no coverage*. **Do not upgrade this** — but do note
`HANDOFF.md`'s "wasm … has never been observed across `b2`/`c`/`f`/`g`" describes the run's
attention, not the gate's reach.

### ⚠️ F-4 — S2 · **VERIFIED, extends the earlier reviewer** — *the sprint's own instruments grade a narrower surface than "engines"*

- `diff_compiler_flat_vs_onemodule.sh` — 13 rows (`:263-276`). Verdicts from `check`; the `value`
  column is **`medaka run` only** (`:130`, `:140`). **Zero rows touch `build`, wasm, or
  `core_ir_eval`**, and no row has two impls sharing a head tag with distinct type args (the A1
  collision shape) — `c5/p5` has two impls but is a `T-AMBIGUOUS-INSTANCE` reject.
- `must_fail` pins **grade `check` only** — blind to every arm in the table.
- Both therefore sit in eval's column, and **eval is the known-wrong oracle** (#1071/#1062). The
  sprint's two headline instruments observe the arm whose agreement my brief forbids me to count.

### ⚠️ F-5 — S3 · **VERIFIED** — *A5 tie-break order and A6 impls-per-head are confirmed ungated*

I set out to check the earlier reviewer's enumeration and it holds, with the mechanism:

- **A5** — the tie-break is `mergeEntries`' documented *"Ties keep the LEFT operand (the goal's own
  head bucket) first"* + `pickMostSpecificEntry`'s head fallback (`typecheck.mdk`, above
  `goalHeadCon`). Nothing in `test/` constructs two equally-⊑ candidates and asserts *which* wins;
  every ambiguity fixture I found asserts the *rejection* (`T-AMBIGUOUS-INSTANCE`), not the order.
  A reordering regression is therefore observable only as a *value* change, on a shape no corpus has.
- **A6** — `diff_compiler_perf_scaling.sh` scales **declarations**. `ieHeadRows` returns a bucket
  and `ieCountHeadBy*Go` walks it per site: cost is `sites × impls-per-head`, an axis nothing
  varies. Two impls per head is the whole corpus.

---

## 3. Discriminators — hand these to the orchestrator

Written as source, prioritised as the brief asks: **D-1 is the one that would show `core_ir_eval`
diverging.** All paths absolute; nothing here needs a second worktree.

### D-1 (run first) — makes F-2's blindness *visible* on the canonical #1036 shape

This is `core_ir_lower.mdk:1250-1258`'s own documented failure (*"a direct call to the `Box Int`
body — `use (Box "s")` printed `boxint`"*), rebuilt cross-module. **It is fail-capable in both
directions**: the typed arms must print `boxstr`; if the untyped `core_ir` arm prints `boxint`, F-2
is demonstrated as a live blind spot rather than a source-reading.

```sh
mkdir -p /var/tmp/r6d1
cat > /var/tmp/r6d1/box.mdk <<'EOF'
public export data Box a = Box a

export interface Speak a where
  speak : a -> String
EOF
cat > /var/tmp/r6d1/ints.mdk <<'EOF'
import box.{Box(..), Speak}

impl Speak (Box Int) where
  speak _ = "boxint"
EOF
cat > /var/tmp/r6d1/strs.mdk <<'EOF'
import box.{Box(..), Speak}

impl Speak (Box String) where
  speak _ = "boxstr"
EOF
cat > /var/tmp/r6d1/main.mdk <<'EOF'
import box.{Box(..), Speak, speak}
import ints
import strs

main = putStrLn (speak (Box "s"))
EOF
```

Run all four arms (note the redirect on `build` — its exit code does not survive a pipe):

```sh
cd /root/medaka/.claude/worktrees/giggly-tinkering-rainbow
./medaka run /var/tmp/r6d1/main.mdk                                   # eval          -> expect boxstr
./medaka build /var/tmp/r6d1/main.mdk -o /var/tmp/r6d1/a > /var/tmp/r6d1/b.log 2>&1; echo "build:$?"
/var/tmp/r6d1/a                                                       # LLVM          -> expect boxstr
./medaka run compiler/entries/core_ir_modules_main.mdk \
    stdlib/core.mdk /var/tmp/r6d1/main.mdk /var/tmp/r6d1               # core_ir_eval  -> ⚠️ predict boxint
```

**Reading it.** `boxint` from the last line is **not** a new bug — it is the untyped arm behaving as
designed. It is the *evidence* for F-2: the only gate that runs `cevalModules` cannot distinguish a
correct route word from no route word at all. If it prints `boxstr`, **retract F-2's strength** —
the arg-tag fallback happens to agree here, and I owe a shape where it cannot.

**Positive control** (must print `boxint`, or D-1 proves nothing): change `main.mdk`'s last line to
`speak (Box 1)` and re-run all four.

### D-2 — F-1's word-vs-symbol discriminator (the S0 candidate)

Grades the **mechanism**, not an exit code — read the two words and compare them directly.

```sh
cd /root/medaka/.claude/worktrees/giggly-tinkering-rainbow
# what the CHECKER stamped:
./medaka run compiler/entries/core_ir_typed_modules_dump_main.mdk \
    stdlib/core.mdk /var/tmp/r6d1/main.mdk /var/tmp/r6d1 \
  > /var/tmp/r6d1/typed.sexp 2>&1
grep -n 'RKey\|Speak' /var/tmp/r6d1/typed.sexp | head -40
# what the EMITTER defined:
./medaka build --keep-ir /var/tmp/r6d1/main.mdk -o /var/tmp/r6d1/a > /var/tmp/r6d1/b.log 2>&1; echo "build:$?"
grep -n 'mdk_impl_.*Speak\|@mdk_impl' /var/tmp/r6d1/a.ll | head -40
```

**Verdict rule:** every `RKey` word in the dump must name a symbol the `.ll` actually defines. A
bare tag `Box` where the `.ll` defines only `Speak__Box_Int__` / `Speak__Box_String__` (or the
inverse) **is F-1**, regardless of whether the program happens to print the right answer.

### D-3 — F-1's duplicate-row probe (decides *introduced* vs *pre-existing*)

F-1 needs a `(iface, head)` with **one canonical key across two rows**. The flatten path is where I
expect it. Cheapest attempt:

```sh
cd /root/medaka/.claude/worktrees/giggly-tinkering-rainbow
./medaka test stdlib/list.mdk            # doctest flatten: prelude concatenated into the decl list
./medaka test /var/tmp/r6d1/main.mdk
```

Then re-run **D-2** against the FLAT arm (`core_ir_typed_main`, single file, no imports) with two
impls at one head, and compare the stamped word before/after `git stash`-free A/B — **⚠️ this half
needs the base binary, which I cannot build.** Label the answer UNVERIFIED until someone runs it.

### D-4 — A5 tie-break, the axis with nothing watching it

```medaka
interface P a where
  tag : a -> String
data W a = W a
impl P (W a)   where  tag _ = "generic"
impl P (W Int) where  tag _ = "specific"
main = putStrLn (tag (W 1))
```
Must print `specific` (most-specific-wins is a decided feature). Run through **all four** arms as in
D-1. Then **permute the two `impl` blocks' order** and re-run: a value that moves under permutation
is an A5 regression, and **no gate in the tree would have caught it** — a permutation differential
is the only check that can see a tie-break widening.

---

## 4. What I did not do

I ran **no build, no gate, no `./medaka`** — four reviewers were live and the brief forbade it.
Everything in §1's table marked with a gate name is a *source-derived* claim that the gate's entry
point reaches that arm; I did **not** confirm any of those gates is currently green, and
`diff_compiler_core_ir_*` was on the run's known-red list. **F-2 does not depend on that** — it is a
claim about which pipeline the entry runs, read off `compiler/entries/core_ir_modules_main.mdk:20`
and `:33-45`, and it holds green or red.
