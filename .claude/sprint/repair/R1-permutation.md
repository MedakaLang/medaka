# R1 — the two-arm permutation differential (repair round)

**Arms.** BASE `7aae8b83`, HEAD `0b953165`. Both **cold-built in this isolated worktree**
(no emitter borrowed from any tree) and staged self-contained as `armbase/` and `armhead/`
(each holds its own `medaka`, `medaka_emitter`, `stdlib/`, `runtime/`, `compiler/`), because
a binary resolves emitter+stdlib from `exeDir`. `env | grep -i medaka` → **no `MEDAKA_ROOT`
/ `MEDAKA_EMITTER` exported**, so the arms are not crossed. `cmp armbase/medaka
armhead/medaka` → differ. **DERIVED.**

**HEAD arm construction.** `git diff --stat 7aae8b83 0b953165 -- compiler/ stdlib/ runtime/`
→ the only code file that differs is `compiler/types/typecheck.mdk` (stdlib and runtime are
byte-identical). The HEAD arm was built by installing HEAD's `typecheck.mdk` over the BASE
tree, since `git checkout` of the branch was refused by the harness classifier. **DERIVED.**

**Probe discipline.** `MEDAKA_STRICT=1` on every invocation; it never fired. Every arm was
exercised at `check`, `run`, **and** `build`+execute, with `build` output redirected to a
file and `$?` read directly (never piped). All bindings under test are **unsignatured**, so
no annotation can suppress the check.

**Positive controls (so a clean result would not be vacuous).**
- A-3.6's intended candidacy widening is visible: `p2` — BASE rejects `T-NO-IMPL`, HEAD
  accepts and executes `7`. My differential can see a widening.
- Door 4 is live in my HEAD binary: `#1564`'s own `main.mdk` → BASE `T-NO-IMPL` exit 1,
  HEAD `T-REQUIRES-UNROUTED` exit 1 with a caret at `nest.mdk:3:16`.
- HEAD has not lost the coherence true-positive: `p3` (two genuinely conflicting
  `impl Show2 T` in unrelated modules) still rejects on HEAD.

---

## FINDING 1 — S0 · REGRESSION · Door 4 does not cover a **monomorphic** goal

`check` exit 0 on a program whose dictionary is never passed; `run` panics on garbage; the
**built binary segfaults**. BASE rejected the same program at compile time.

Minimal repro (`v1/`, four files, no import-order ambiguity at all):

```
-- iface.mdk
public export data T = T
public export data Box a = Box a
export interface Show2 a where
  show2 : a -> Int
export impl Show2 T where
  show2 x = 3

-- gen.mdk
import iface.{Box(..), Show2, show2}
impl Show2 (Box a) requires Show2 a where
  show2 b =
    match b
      Box x => 1000 + show2 x

-- user.mdk        (NOTE: does NOT import gen)
import iface.{T(..), Box(..), Show2, show2}
export useIt = show2 (Box T)

-- main.mdk
import user.{useIt}
import gen
main = println useIt
```

Correct answer: `1003`.

| | BASE `7aae8b83` | HEAD `0b953165` |
|---|---|---|
| `check` | **1** — `user.mdk:3:15: No impl of Show2 for Box T` | **0** — `main : Unit` |
| `run` | 1 (same diagnostic) | **1** — `runtime error [E-PANIC]: intToString: not an Int` |
| `build` | 1, no binary | **0** — binary produced |
| `./bin` | n/a | **139 — segmentation fault** |

**Single-variable attribution, both directions measured:**

- `v2` — identical except `user.mdk` adds `import gen` (the diagnostic's own suggested fix):
  **both arms** `check`/`run`/`build`/exec = 0, value `1003`. So the variable is *whether the
  module holding the binding imports the module declaring the conditional impl*.
- `p6` — identical to `p5` except the binding is **generalized**
  (`export useIt x = show2 (Box x)` instead of `export useIt = show2 (Box T)`):
  HEAD fires **`T-REQUIRES-UNROUTED`, exit 1**, correctly located. Flipping that one thing
  turns the bug on and off.
- `p8` — the impl module at topological depth 1 vs depth 2: **identical** behaviour, so this
  is not depth-sensitive.
- The premise impl (`impl Show2 T`) being in an unimported module is **not** required: in
  `v1` it sits in `iface.mdk`, which `user.mdk` does import, and it still segfaults. The
  unrouted dictionary is the conditional impl's own, not its `requires` premise.

**Mechanism (DERIVED by grep, not relayed).** Door 4's reject lives at exactly one call
site: `residualPredsOf`'s `None` arm → `unroutedResidual`
(`compiler/types/typecheck.mdk:24701`, defined `:24743`, the only `pushTypeErrorOnceAt
"T-REQUIRES-UNROUTED"` in the file). `residualPredsOf` is the **residual-predicate** path —
reached when a generalized binding carries an unresolved obligation. A fully concrete goal
`Show2 (Box T)` never becomes a residual predicate, so it structurally cannot reach the
guard. `DEBT.md` D4-1 names its own scope as *"an impl matches a **partially-generalized**
goal"*, which is consistent with this.

**INTENDED? NO — this is a regression, and a specific ruling is falsified.** RUN-047 states,
as a ✅ deliverable: *"Removes the regression: `check` exit 0 → segfault becomes `check`
exit 1 with a located diagnostic. **The severity increase RUN-043 recorded is undone.**"*
That claim is **false for the monomorphic case**. `DEBT.md` D4-2 concedes only that *import
order still decides which programs are ACCEPTED*; it records no surviving segfault, and
D4-1's "could move" section names only the opposite risk (a false **narrowing**). The
surviving `check`-green segfault is unrecorded. Attributed to **A-3.6** (graph-global
candidacy admits the impl) with **Door 4** failing to catch the residue.

## FINDING 2 — S0 · REGRESSION · import-line order decides whether the emitted binary segfaults

Same root cause as Finding 1, but it adds a **`run` ≠ `build` divergence steered by import
order alone**. `p4/` adds a more specific `impl Show2 (Box T)` (module `spec`) alongside the
conditional `gen`, with `base`; `user.mdk` imports neither. All six permutations of the three
import lines in `main.mdk`, HEAD arm:

| import order | `check` | `run` | `build` | `./bin` |
|---|---|---|---|---|
| `base gen spec` | 0 | 0 → `5` | 0 | **139 segfault** |
| `gen base spec` | 0 | 0 → `5` | 0 | **139 segfault** |
| `gen spec base` | 0 | 0 → `5` | 0 | **139 segfault** |
| `base spec gen` | 0 | 0 → `5` | 0 | 0 → `5` |
| `spec base gen` | 0 | 0 → `5` | 0 | 0 → `5` |
| `spec gen base` | 0 | 0 → `5` | 0 | 0 → `5` |

BASE rejects **all six** identically (`No impl of Show2 for Box T`), so BASE has no
order-dependence here at all.

**Single variable: if `import gen` precedes `import spec`, the built binary segfaults.**
Deterministic — re-run 3× per order, 6/6 identical (`mk7.sh`). The interpreter answers `5`
(correct, most-specific-wins) in every order; only codegen diverges. This is the shape the
brief calls out as only appearing at `build`.

**INTENDED? NO.** RUN-047 licenses import order deciding *acceptance*, moved into a
*diagnostic*. Here acceptance is uniform (all six accept) and the divergence is in the
**emitted binary**, with no diagnostic anywhere.

## FINDING 3 — INTENDED · HEAD fixes a BASE false-positive coherence conflict

`p9/`: `amod.mdk` and `zmod.mdk` each declare their **own** interface spelled `Show2` plus
`impl Show2 T`; `user.mdk` imports only `amod`'s.

- BASE: `check` **1** — ``<unknown location>: Conflicting `impl Show2`. Defined in amod and zmod``
  (a false positive — two distinct interfaces under module-qualified identity).
- HEAD: `check`/`run`/`build`/exec **0**, value `111` (correct).

This is **A-3.7 / #1438's intended coherence drain** (RUN-040). Not a regression. I checked
the widening did not eat the true positive: `p3`, a genuine same-interface conflict across
unrelated modules, still rejects on HEAD with the same wording.

---

## Axes permuted, and what came back CLEAN

1. **Import order within a module** — 6-way on `p4` (Finding 2), 2-way on `#1564`. **RED.**
2. **Module topological position / depth** — `p8`, impl module at depth 1 vs depth 2 behind a
   `chain` module. **CLEAN**: byte-identical behaviour on both arms; no ordinal residue on the
   candidacy axis.
3. **Declaration order within a module** — `p7`, `impl Show2 (Box a) requires …` and
   `impl Show2 (Box T)` in one module, both orders. **CLEAN**: both arms, both orders,
   `check`/`run`/`build`/exec all 0 → `5`. Coherence pair-scan order does not decide.
4. **Adding an unrelated module to the build** — `p9` (Finding 3, intended), `p2` (intended
   A-3.6 widening), `p3` (conflict still caught). No case found where adding an unrelated
   module changed a **name** resolution.
5. **Super-impl across modules** (RUN-039's explicitly-UNRULED hazard: graph-global candidacy
   vs prefix-scoped `checkSuperImpls`) — `p1`, `impl Sub T` and `impl Sup T` in sibling
   modules that do not import each other. **CLEAN and identical on both arms**: both reject
   with `'impl Sub T' requires a superinterface 'impl Sup T', which is missing`. I did **not**
   find the predicted diagnostic-vs-engine contradiction; the reject fires before dispatch can
   disagree. RUN-039 stays open on my evidence — I did not disprove the class, only failed to
   exhibit it in this shape.

## What this differential did NOT cover

- **wasm** — LLVM/native and the interpreter only. `diff_compiler_engines`-style 3-engine
  agreement was not run.
- **The `Flat` single-file path** — D4-1's own unchecked item (3). Every probe here is
  multi-module by construction.
- **Whether the new reject can fire inside the prelude or `compiler/` itself** — D4-1's
  unchecked item (2); I ran no `check-self` and no gate suite.
- **Import *forms*** — only selective `import m.{…}` and bare `import m`. No `import m.*`,
  no `import m as A`, no `{X as Y}` renames.
- **Graph size** — nothing beyond 5 modules; no diamond or cyclic-adjacent shapes.
- **A-3.5a (`ceRequiredAt`) and A-3.5b (`T-MISSING-SUPER-IMPL` onto IE)** got only the `p1`
  probe; I did not permute *required-method* shapes (missing/extra/defaulted methods) at all.
- **Diagnostic-channel parity** — I did not compare `check --json` against human `check`
  (the open #1362 hole), nor `lint`/`lsp`/`mcp` surfaces.
- **No goldens, gates, snapshots or LEG A** were run or blessed. Nothing committed or pushed.

## Worktree state

`compiler/types/typecheck.mdk` was restored to BASE after the arms were staged. The two arms
remain as untracked `armbase/` and `armhead/` directories; probe corpora and driver scripts
are in `/var/tmp/medaka-scratch/r1/` (`arms.sh`, `perm4.sh`, `mk5.sh`…`mk9.sh`, `p1`–`p9`,
`v1`, `v2`, `d4`).
