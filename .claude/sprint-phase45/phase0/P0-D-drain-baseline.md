# P0-D — PRE-FIX DRAIN BASELINE + Q5

**Packet:** P0-D (Stage B Phase 4/4b sprint, Phase 0)
**Date:** 2026-08-14
**Worktree:** `/root/medaka/.claude/worktrees/peppy-brewing-kitten`
**Binary under test:** `/root/medaka/.claude/worktrees/peppy-brewing-kitten/medaka` (pre-built by
another agent; **NOT rebuilt by this packet**)
**HEAD:** `aaa437167b633d6070adccd055c8c2a19e9bb8c6`
**All probes run with `MEDAKA_STRICT=1`.** Read-only w.r.t. the repo; every probe program lives in
`/var/tmp/medaka-scratch/P0D/`.

## 0. Environment hygiene — the crossed-arms check

```
$ env | grep -i MEDAKA
PWD=/root/medaka/.claude/worktrees/peppy-brewing-kitten
TMPDIR=/var/tmp/medaka-scratch
```

**No `MEDAKA_ROOT`, no `MEDAKA_EMITTER` exported** — the arms are not crossed. The binary sits in
the worktree root, so `exeDir` resolution reaches this worktree's `stdlib/`, `runtime/` and
`medaka_emitter`. Every `build` below succeeded or failed for a semantic reason, never for a missing
`runtime/`.

```
$ git -C /root/medaka/.claude/worktrees/peppy-brewing-kitten rev-parse HEAD
aaa437167b633d6070adccd055c8c2a19e9bb8c6
$ ls -la .../medaka
-rwxr-xr-x 1 root root 4148224 Aug 14 08:58 .../medaka
```

`MEDAKA_STRICT=1` was set on every invocation, so a stale binary would have hard-failed at exit 1
rather than silently answering. **No staleness warning fired on any probe.**

**Trap discipline used throughout:** every command redirects stdout/stderr to files and reads `$?`
immediately — never `| tail` — because `medaka build`'s exit code does not survive a pipe.

The probe harness (`/var/tmp/medaka-scratch/P0D/probe.sh`) runs, for one file:
`check` → `check --json` → `run` → `build -o <dir>/prog` → execute `<dir>/prog`, printing the exact
exit code, stdout and stderr of each.

---

## Deliverable 1 — pre-fix baseline, per drain target

### Summary table (details below)

| issue | state | reproduces on `aaa43716`? | pin |
|---|---|---|---|
| **#1182** | OPEN | ✅ **REPRODUCES**, both permutations | live, reproduces |
| **#1617** | OPEN | ✅ **REPRODUCES**, both permutations | live, reproduces |
| **#1619** | OPEN | ✅ **REPRODUCES** | live, reproduces |
| **#1620** | OPEN | ✅ **REPRODUCES** | live, reproduces |
| **#1608** | OPEN | ✅ **REPRODUCES** (probe-driver arm) | none — refused, see Q5 |
| **#1618** *(sibling)* | OPEN | ✅ **REPRODUCES** | live, reproduces |

---

## #1182 — two interfaces declaring the same method name; `impl` block ORDER decides

`gh issue view 1182` → **STATE: OPEN**, labels `S0: silent wrongness, verified, ws:soundness,
ws:typecheck`. (The sprint doc's blocking tracker correction has been actioned — it is open again.)

Repro taken verbatim from the issue body. Two files differ **only** in the order of the two `impl`
blocks.

`/var/tmp/medaka-scratch/P0D/i1182/ab/main.mdk` (A1 first):

```medaka
data Q a b c = Q a b c

interface A1 a where
  m : a -> Int

interface A2 a where
  m : a -> Int

impl A1 (Q Int y z) where
  m _ = 1

impl A2 (Q x Bool z) where
  m _ = 2

main = println (m (Q 1 True 7))
```

`/var/tmp/medaka-scratch/P0D/i1182/ba/main.mdk` is byte-identical except the two `impl` blocks are
swapped.

### PERMUTATION AB (A1 first) — all four arms

```
$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/P0D/i1182/ab/main.mdk
exit=0
stdout:
main : Unit
-- /var/tmp/medaka-scratch/P0D/i1182/ab/main.mdk: ok (1 declaration(s) checked, 0 errors)
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka check --json /var/tmp/medaka-scratch/P0D/i1182/ab/main.mdk
exit=0
stdout:
{"files":[{"file":"/var/tmp/medaka-scratch/P0D/i1182/ab/main.mdk","diagnostics":[]}]}
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka run /var/tmp/medaka-scratch/P0D/i1182/ab/main.mdk
exit=0
stdout:
1
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka build .../i1182/ab/main.mdk -o .../i1182/ab/prog
exit=0
stdout:
built /var/tmp/medaka-scratch/P0D/i1182/ab/main.mdk -> /var/tmp/medaka-scratch/P0D/i1182/ab/prog
stderr:
(empty)

$ /var/tmp/medaka-scratch/P0D/i1182/ab/prog
exit=0
stdout:
1
stderr:
(empty)
```

### PERMUTATION BA (A2 first) — all four arms

```
$ MEDAKA_STRICT=1 ./medaka check /var/tmp/medaka-scratch/P0D/i1182/ba/main.mdk
exit=0
stdout:
main : Unit
-- /var/tmp/medaka-scratch/P0D/i1182/ba/main.mdk: ok (1 declaration(s) checked, 0 errors)
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka check --json /var/tmp/medaka-scratch/P0D/i1182/ba/main.mdk
exit=0
stdout:
{"files":[{"file":"/var/tmp/medaka-scratch/P0D/i1182/ba/main.mdk","diagnostics":[]}]}
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka run /var/tmp/medaka-scratch/P0D/i1182/ba/main.mdk
exit=0
stdout:
2
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka build .../i1182/ba/main.mdk -o .../i1182/ba/prog
exit=0
stdout:
built /var/tmp/medaka-scratch/P0D/i1182/ba/main.mdk -> /var/tmp/medaka-scratch/P0D/i1182/ba/prog
stderr:
(empty)

$ /var/tmp/medaka-scratch/P0D/i1182/ba/prog
exit=0
stdout:
2
stderr:
(empty)
```

**VERDICT: REPRODUCES EXACTLY as the issue body's table states.** `check`/`check --json` clean and
silent in both permutations; `run` and the built native binary both answer **1** under AB and **2**
under BA. The permutations **DISAGREE** — that disagreement is the defect.

### The mechanism discriminator (issue body's own second probe) — also reproduces

`/var/tmp/medaka-scratch/P0D/i1182/spec/main.mdk`: fully-general `impl A2 (Q x y z)` **declared
first**, strictly more specific `impl A1 (Q Int Bool Int)` **declared second**.

```
$ MEDAKA_STRICT=1 ./medaka run /var/tmp/medaka-scratch/P0D/i1182/spec/main.mdk
exit=0
stdout:
1
stderr:
(empty)
$ /var/tmp/medaka-scratch/P0D/i1182/spec/prog     # native, built exit=0
exit=0
stdout:
1
```

The answer is **1** — the *more specific* impl, belonging to the *other* interface, declared
*second*. Plain declaration order would give `2`. **Only cross-interface min⊑ ranking explains
this**, so the mechanism the issue names (`matchingEntries` selects by method-name membership, not
by interface; `pickMostSpecificEntry` then ranks across interfaces) is confirmed on this binary, not
merely inherited.

### The pin

`test/must_fail_fixtures/1182-two-ifaces-same-method-name-order-decides/` — **LIVE**. Contents:
`claim.txt` (7114 B), `main.mdk`, `control.mdk`, `specificity-probe.mdk` (the third file is shipped
but NOT graded by the harness).

`claim.txt` asserts: `cmd: run main.mdk` / `exit: 0` / `stdout: 1`, control `run control.mdk`.
⚠️ It explicitly **does not assert that `1` is correct** — it pins the **ORDER DEPENDENCE**: the
pair (order A → 1) ∧ (order B → 2). The control slot is spent on the second ordering rather than a
near-miss, so both orderings are graded by one row.

Run of the pin's own two files (fixture case only, not the whole suite):

```
$ MEDAKA_STRICT=1 ./medaka run test/must_fail_fixtures/1182-.../main.mdk
exit=0
stdout: 1
$ MEDAKA_STRICT=1 ./medaka run test/must_fail_fixtures/1182-.../control.mdk
exit=0
stdout: control-ok:2
```

Both match `claim.txt` exactly ⇒ **the pin currently REPRODUCES; it is not drained.**

⚠️ **`claim.txt` lines 58-71 carry a booby trap the drain grader must read before believing a
verdict.** If the fix converges both orderings on **1**, `main.mdk` still matches and the *control*
panics, and the harness reports **CONTROL-BROKE** with the message *"the ENVIRONMENT moved, not the
bug — do not close #1182"*. That message is **WRONG in this one case**: convergence *is* the fix.
Check the panic text (`control regressed: with the impl blocks swapped the answer is no longer 2`)
before acting. If instead the fix converges on **2**, or rejects either file, `main.mdk`'s pin moves
and the harness reports a clean DRAINED.

### 🎯 THE DISCRIMINATOR — what a successful drain must change

**The two permutations must stop disagreeing on `run` stdout**: `run ab/main.mdk` and
`run ba/main.mdk` must produce the **same** value (whichever of `1`/`2` the fix elects), or both
must be rejected with a diagnostic — where today they produce `1` and `2` respectively at exit 0.

⚠️ **"Both permutations agree" is meaningless without the pre-fix value**, which is why it is
recorded here: today they **DISAGREE** (`1` vs `2`). Post-fix agreement is therefore a real move,
not a restatement.

⚠️ **Causal vs shape-move test for exit criterion 3:** if the drain arrives with both permutations
answering `1` **and** the specificity probe still answering `1`, that is a *shape move* — the
selector still ranks cross-interface and merely became order-insensitive. A **causal** drain
re-keys the candidate set by interface, so the `spec` probe's `impl A1 (Q Int Bool Int)` is no
longer a candidate for a goal minted from `A2` at all; grade the `spec` probe too, not just the
pair.

---

## #1617 — a function-typed impl head falls into the `noneHeadTag` bucket

`gh issue view 1617` → **STATE: OPEN**, labels `S0: silent wrongness, verified, ws:typecheck`.

Repro taken verbatim from the issue body; `ab`/`ba` differ only in the order of the two `impl`
blocks; the control substitutes two `data` types for the two function types.

### PERMUTATION AB (`Int -> Int` first) — `/var/tmp/medaka-scratch/P0D/i1617/ab/main.mdk`

```
$ MEDAKA_STRICT=1 ./medaka check .../i1617/ab/main.mdk
exit=0
stdout:
f : Int -> Int
g : Bool -> Bool
main : Unit
-- /var/tmp/medaka-scratch/P0D/i1617/ab/main.mdk: ok (3 declaration(s) checked, 0 errors)
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka check --json .../i1617/ab/main.mdk
exit=0
stdout:
{"files":[{"file":"/var/tmp/medaka-scratch/P0D/i1617/ab/main.mdk","diagnostics":[]}]}
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka run .../i1617/ab/main.mdk
exit=0
stdout:
(5, 5)
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka build .../i1617/ab/main.mdk -o .../i1617/ab/prog
exit=1
stdout:
(empty)
stderr:
error: emitter failed compiling /var/tmp/medaka-scratch/P0D/i1617/ab/main.mdk
runtime error [E-PANIC]: arg-tag dispatch on impl type that owns no constructors (primitive receiver carries no cell tag)

exec: NOBIN (no executable produced)
```

### PERMUTATION BA (`Bool -> Bool` first) — `/var/tmp/medaka-scratch/P0D/i1617/ba/main.mdk`

```
$ MEDAKA_STRICT=1 ./medaka check .../i1617/ba/main.mdk
exit=0
stdout:
f : Int -> Int
g : Bool -> Bool
main : Unit
-- /var/tmp/medaka-scratch/P0D/i1617/ba/main.mdk: ok (3 declaration(s) checked, 0 errors)
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka check --json .../i1617/ba/main.mdk
exit=0
stdout:
{"files":[{"file":"/var/tmp/medaka-scratch/P0D/i1617/ba/main.mdk","diagnostics":[]}]}
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka run .../i1617/ba/main.mdk
exit=0
stdout:
(9, 9)
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka build .../i1617/ba/main.mdk -o .../i1617/ba/prog
exit=1
stdout:
(empty)
stderr:
error: emitter failed compiling /var/tmp/medaka-scratch/P0D/i1617/ba/main.mdk
runtime error [E-PANIC]: arg-tag dispatch on impl type that owns no constructors (primitive receiver carries no cell tag)

exec: NOBIN (no executable produced)
```

### CONTROL (two `data` heads, everything else the same shape)

```
$ MEDAKA_STRICT=1 ./medaka check .../i1617/ctl/main.mdk   -> exit=0, "ok (3 declaration(s) checked, 0 errors)"
$ MEDAKA_STRICT=1 ./medaka check --json .../i1617/ctl/main.mdk -> exit=0, {"...","diagnostics":[]}
$ MEDAKA_STRICT=1 ./medaka run .../i1617/ctl/main.mdk
exit=0
stdout:
(5, 9)
$ MEDAKA_STRICT=1 ./medaka build .../i1617/ctl/main.mdk -o .../i1617/ctl/prog
exit=0
stdout:
built /var/tmp/medaka-scratch/P0D/i1617/ctl/main.mdk -> /var/tmp/medaka-scratch/P0D/i1617/ctl/prog
$ .../i1617/ctl/prog
exit=0
stdout:
(5, 9)
```

**VERDICT: REPRODUCES EXACTLY**, matching the issue body's table cell-for-cell:

```
ab:  check=0 run=0 [(5, 5)] build=1 exec=NOBIN
ba:  check=0 run=0 [(9, 9)] build=1 exec=NOBIN
ctl: check=0 run=0 [(5, 9)] build=0 exec=0 [(5, 9)]
```

**The correct answer is `(5, 9)`** (each function's own type selects its own impl), derived from the
source before running, and the control demonstrates the language can produce it. `run` is wrong in
**BOTH** permutations at exit 0 — and, critically, **wrong DIFFERENTLY in each**: AB collapses both
calls onto the first impl (`(5, 5)`), BA onto the other (`(9, 9)`). Both `sz f` and `sz g` resolve to
whichever function-typed impl was declared first, i.e. the two heads are indistinguishable inside the
`noneHeadTag` bucket. `build` is an S1 arm: **exit 1 with an E-PANIC, not a diagnostic**.

⚠️ Note the two permutations here **do not agree** (unlike some members of this batch) — they agree
only in *being wrong*. Post-fix, agreement alone is insufficient; see the discriminator.

### The pin

`test/must_fail_fixtures/1617-fn-typed-impl-head-none-bucket/` — **LIVE**. Files: `claim.txt`,
`main.mdk`, `control.mdk`, `permutation.mdk`.

`claim.txt` asserts `cmd: run main.mdk` / `exit: 0` / `stdout: False` / `control: run control.mdk`.
Note it grades a **Bool projection** (`False`), not the raw tuple, and its `why-verb` block records
that `build` is deliberately NOT the pinned verb — `medaka build` exits 1 here, which the harness
treats as MALFORMED (126) for `build-run`, and one fix (giving `TyFun` a head tag in `headTyconTy`)
closes both arms.

```
$ MEDAKA_STRICT=1 ./medaka run test/must_fail_fixtures/1617-.../main.mdk
exit=0
stdout: False
$ MEDAKA_STRICT=1 ./medaka run test/must_fail_fixtures/1617-.../control.mdk
exit=0
stdout: control-ok:(5, 9)
$ MEDAKA_STRICT=1 ./medaka run test/must_fail_fixtures/1617-.../permutation.mdk   # ungraded third file
exit=0
stdout: (9, 9)
```

Matches `claim.txt` exactly ⇒ **the pin REPRODUCES; not drained.**

### 🎯 THE DISCRIMINATOR — what a successful drain must change

**`run` on BOTH permutations must print `(5, 9)`, and `build` must exit 0 on both with the built
binary also printing `(5, 9)`.** Equivalently, the pin's `main.mdk` must print `True` where it prints
`False` today.

⚠️ **Agreement between permutations is NOT the discriminator here** — the value is. A change that
made both permutations print `(5, 5)` would be order-independent and still wrong. The bar is the
*hand-derived* value `(5, 9)`, on all four cells.

⚠️ **Causal vs shape-move:** this issue is **NOT drained by Phase 4b** (the sprint doc's residual 2
says so explicitly). Its mechanism is the `headTyconTy`/`headTyconHead` `_ => None` **arm set**,
spanning `typecheck.mdk`, `eval.mdk` (`headTyconHead` defined/exported) and `core_ir_lower.mdk`
(importer). If it drains during 4b **without** the arm set being touched, that is a **shape move**
(the selector re-key incidentally masked it) and must be reported as such — the `TyFun`-into-
`noneHeadTag` collapse would still be latent for any program not covered by the new interface key.

---

## #1619 — a cross-module interface DEFAULT is silently hijacked by a same-spelled interface

`gh issue view 1619` → **STATE: OPEN**, labels `S0: silent wrongness, verified, ws:emitter`.

Four modules, re-authored from the issue body (and cross-checked against the pin's own sources,
which match): `di.mdk` exports `interface Tag` **with a default body** `tag _ = 7`; `dimpl.mdk`
imports it and declares a **method-less** `impl Tag Box` that inherits the default; `other.mdk`
declares its **own same-spelled** `interface Tag` with an **explicit** `impl Tag Box` giving `100`;
`main.mdk` prints `(dtag Box, otag Box)`.

**Hand-derived correct answer, from DICT §8 I4** (a class is `(module, name)`, so `di::Tag` and
`other::Tag` are two distinct classes) **plus §5** (a default applies only when the *selected*
instance omits the method): **`(7, 100)`**.

### PERMUTATION A — `main.mdk` imports `dimpl` first (`/var/tmp/medaka-scratch/P0D/i1619/coll/`)

```
$ MEDAKA_STRICT=1 ./medaka check .../i1619/coll/main.mdk
exit=0
stdout:
main : Unit
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka check --json .../i1619/coll/main.mdk
exit=0
stdout:
{"files":[{"file":".../i1619/coll/di.mdk","diagnostics":[]},{"file":".../i1619/coll/dimpl.mdk","diagnostics":[]},{"file":".../i1619/coll/other.mdk","diagnostics":[]},{"file":".../i1619/coll/main.mdk","diagnostics":[]}]}
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka run .../i1619/coll/main.mdk
exit=0
stdout:
(100, 100)
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka build .../i1619/coll/main.mdk -o .../i1619/coll/prog
exit=0
stdout:
built /var/tmp/medaka-scratch/P0D/i1619/coll/main.mdk -> /var/tmp/medaka-scratch/P0D/i1619/coll/prog
stderr:
(empty)

$ .../i1619/coll/prog
exit=0
stdout:
(100, 100)
stderr:
(empty)
```

### PERMUTATION B — the two import lines SWAPPED, nothing else changed (`.../i1619/permB/`)

```
$ MEDAKA_STRICT=1 ./medaka check .../i1619/permB/main.mdk        -> exit=0, "main : Unit", stderr empty
$ MEDAKA_STRICT=1 ./medaka check --json .../i1619/permB/main.mdk -> exit=0, all four files "diagnostics":[]
$ MEDAKA_STRICT=1 ./medaka run .../i1619/permB/main.mdk
exit=0
stdout:
(100, 100)
$ MEDAKA_STRICT=1 ./medaka build .../i1619/permB/main.mdk -o .../i1619/permB/prog
exit=0
stdout:
built /var/tmp/medaka-scratch/P0D/i1619/permB/main.mdk -> /var/tmp/medaka-scratch/P0D/i1619/permB/prog
$ .../i1619/permB/prog
exit=0
stdout:
(100, 100)
```

🚨 **BOTH PERMUTATIONS AGREE, AT THE WRONG ANSWER `(100, 100)`, ON ALL FOUR ARMS.** This is exactly
the case the packet brief warned must be captured: the issue body's dedup states this bug is **NOT**
order-dependent (*"swapping the imports changes nothing, because the colliding module is
topologically later in both orders"*) and that is confirmed here, not assumed. **Post-fix agreement
between these two permutations therefore proves NOTHING on its own** — they already agree today.
Only the *value* discriminates.

### CONTROL — `other.mdk` deleted (`/var/tmp/medaka-scratch/P0D/i1619/ctl/`)

```
$ MEDAKA_STRICT=1 ./medaka run .../i1619/ctl/main.mdk
exit=0
stdout:
7
$ MEDAKA_STRICT=1 ./medaka build .../i1619/ctl/main.mdk -o .../i1619/ctl/prog   -> exit=0
$ .../i1619/ctl/prog
exit=0
stdout:
7
```

**The control FIRES**: with the colliding module gone, `di`'s default *is* reached and answers `7`.
So `7` is producible; the collision is what suppresses it.

### BOTH-METHOD-LESS variant (`/var/tmp/medaka-scratch/P0D/i1619/ml/`)

`other.mdk`'s interface given its own default `tag _ = 200` and a method-less impl.

```
$ MEDAKA_STRICT=1 ./medaka run .../i1619/ml/main.mdk
exit=0
stdout:
(200, 200)
$ .../i1619/ml/prog            # build exit=0
exit=0
stdout:
(200, 200)
```

Correct is `(7, 200)`; measured `(200, 200)`. ⚠️ This is the arm the issue **flags rather than
asserts** as possibly belonging to #1265 — recorded here because it reproduces, not as a claim on
ownership.

### The pin

`test/must_fail_fixtures/1619-xmod-default-hijacked-by-same-spelled-iface/` — **LIVE**. Files:
`claim.txt`, `di.mdk`, `dimpl.mdk`, `other.mdk`, `main.mdk`, `control.mdk`. Asserts
`cmd: run main.mdk` / `exit: 0` / `stdout: False` / `control: run control.mdk`.

⚠️ `main.mdk`'s own header explains why it grades a **Bool projection** rather than the raw tuple:
the collapse is last-write-wins, so *which* wrong value survives depends on what else is in the
graph, and a `stdout: (100, 100)` pin would read as DRAINED on any change that merely moved the
program to a *different* wrong pair (e.g. `(7, 7)`). Comparing against the hand-derived `(7, 100)`
collapses every wrong pair to `False`.

```
$ MEDAKA_STRICT=1 ./medaka run test/must_fail_fixtures/1619-.../main.mdk
exit=0
stdout: False
$ MEDAKA_STRICT=1 ./medaka run test/must_fail_fixtures/1619-.../control.mdk
exit=0
stdout: control-ok:7
```

Matches `claim.txt` exactly ⇒ **the pin REPRODUCES; not drained.**

### 🎯 THE DISCRIMINATOR — what a successful drain must change

**`run` and the built binary must print `(7, 100)`** on the collision program, in **both** import
permutations — equivalently the pin's `main.mdk` must print `True` where it prints `False` today.

⚠️ **Do NOT accept "both permutations agree" as evidence** for this issue: they already agree
pre-fix. And **do not accept any wrong-pair-to-different-wrong-pair move** (`(7, 7)`, `(100, 7)`) as
a drain — the projection exists precisely to catch that.

⚠️ **Causal vs shape-move:** a causal drain gives the default registry an **interface-identity**
component so `di::Tag`'s default and `other::Tag`'s explicit impl cannot collapse. If the value
moves to `(7, 100)` while the registry is still bare-head-tag keyed (e.g. because Phase 4's frozen
table happens to route around it for this shape), that is a shape move — and the both-method-less
variant `(200, 200)` is the probe that will still show it. **Grade the `ml` variant too.**

---

## #1620 — two interfaces sharing a METHOD name in ONE file

`gh issue view 1620` → **STATE: OPEN**, labels `S0: silent wrongness, verified, ws:typecheck`.

Repro verbatim from the issue body (`ab`): `interface Alpha a where ping : a -> String` and
`interface Beta a where ping : a -> Int`, both with an explicit `impl … T`, `main = println (ping T)`.
`ba` swaps BOTH the interface declarations and the impl blocks. `ctl` deletes `Beta` and its impl.

### PERMUTATION AB (Alpha first) — the issue's own ordering

```
$ MEDAKA_STRICT=1 ./medaka check .../i1620/ab/main.mdk
exit=0
stdout:
main : Unit
-- /var/tmp/medaka-scratch/P0D/i1620/ab/main.mdk: ok (1 declaration(s) checked, 0 errors)
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka check --json .../i1620/ab/main.mdk
exit=0
stdout:
{"files":[{"file":"/var/tmp/medaka-scratch/P0D/i1620/ab/main.mdk","diagnostics":[]}]}
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka run .../i1620/ab/main.mdk
exit=1
stdout:
(empty)
stderr:
runtime error [E-PANIC]: intToString: not an Int

$ MEDAKA_STRICT=1 ./medaka build .../i1620/ab/main.mdk -o .../i1620/ab/prog
exit=0
stdout:
built /var/tmp/medaka-scratch/P0D/i1620/ab/main.mdk -> /var/tmp/medaka-scratch/P0D/i1620/ab/prog
stderr:
(empty)

$ .../i1620/ab/prog
exit=0
stdout:
47131247286584
stderr:
(empty)
```

**REPRODUCES EXACTLY** as filed: `check=0 run=1 build=0 exec=0 [<raw word>]`, and the printed value
differs from the issue's `47457582201144` — confirming the issue's note that the word is a **live
heap address and is NOT byte-stable**, which is why its pin uses a Bool projection.

### PERMUTATION BA (Beta first) — 🚨 **A NEW OBSERVATION; the issue did not run this**

The issue's dedup asserts *"This reproduces **unconditionally**; no permutation is needed."* That is
**true of "it reproduces" and FALSE of "the character is order-independent"** — measured:

```
$ MEDAKA_STRICT=1 ./medaka check .../i1620/ba/main.mdk
exit=0
stdout:
main : Unit
-- /var/tmp/medaka-scratch/P0D/i1620/ba/main.mdk: ok (1 declaration(s) checked, 0 errors)
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka check --json .../i1620/ba/main.mdk
exit=0
stdout:
{"files":[{"file":"/var/tmp/medaka-scratch/P0D/i1620/ba/main.mdk","diagnostics":[]}]}
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka run .../i1620/ba/main.mdk
exit=1
stdout:
(empty)
stderr:
runtime error [E-PANIC]: putStrLn: not a String

$ MEDAKA_STRICT=1 ./medaka build .../i1620/ba/main.mdk -o .../i1620/ba/prog
exit=0
stdout:
built /var/tmp/medaka-scratch/P0D/i1620/ba/main.mdk -> /var/tmp/medaka-scratch/P0D/i1620/ba/prog
stderr:
(empty)

$ .../i1620/ba/prog
exit=139
stdout:
(empty)
stderr:
runtime error [E-FATAL-SIGNAL]: fatal memory fault (segmentation fault)
```

⚠️ **The two permutations fail DIFFERENTLY, and BA is strictly worse:**

| arm | AB (Alpha first) | BA (Beta first) |
|---|---|---|
| `check` / `check --json` | 0, silent | 0, silent |
| `run` | 1, `intToString: not an Int` | 1, **`putStrLn: not a String`** |
| `build` | 0 | 0 |
| built binary | **0**, prints a raw word | **139**, **SEGFAULT** |

The two E-PANIC messages are **mirror images**, which names the mechanism: the *type* the occurrence
of `ping` receives and the *impl* actually selected come from different decisions and disagree, in
opposite directions per ordering. **BA's native arm is a memory-safety fault reachable from a
`check`-clean program**, which the issue does not record.

### Symbols and the emitted call — the issue's claim, re-derived on this binary

`medaka build --keep-ir` (both permutations, both `build exit=0`):

```
$ grep -o '@mdk_impl_[A-Za-z0-9_]*ping[A-Za-z0-9_]*' .../i1620/ab/prog2.ll | sort -u
@mdk_impl_main__Alpha_T__ping
@mdk_impl_main__Beta_T__ping
$ grep -o '@mdk_impl_[A-Za-z0-9_]*ping[A-Za-z0-9_]*' .../i1620/ba/prog2.ll | sort -u
@mdk_impl_main__Alpha_T__ping
@mdk_impl_main__Beta_T__ping
```

**TWO, DISTINCT, in both permutations** — the issue's claim that the wrongness is *downstream of
naming* is confirmed (the mangled names now carry a `main__` module component the issue's transcript
predates; the distinctness claim is unaffected).

Which one is actually CALLED, and with which `Display` dictionary:

```
$ grep -n 'call.*@mdk_impl_main__.*ping' .../i1620/ab/prog2.ll
163:  %t0 = call i64 @mdk_impl_main__Alpha_T__ping(i64 42949672961)
$ grep -n 'call.*@mdk_impl_main__.*ping' .../i1620/ba/prog2.ll
163:  %t0 = call i64 @mdk_impl_main__Beta_T__ping(i64 42949672961)

$ grep -n 'mdk_dc_0' .../i1620/ab/prog2.ll
164:  %t1 = call i64 @mdk_core__println(i64 ptrtoint (ptr @mdk_dc_0 to i64), i64 %t0)
10360:@mdk_dc_0 = internal constant [1 x i64] [i64 193460240]
$ grep -n 'mdk_dc_0' .../i1620/ba/prog2.ll
164:  %t1 = call i64 @mdk_core__println(i64 ptrtoint (ptr @mdk_dc_0 to i64), i64 %t0)
10360:@mdk_dc_0 = internal constant [1 x i64] [i64 6952779160540]
```

🎯 **This is the mis-selection made visible, and it answers the issue's "⚠️ What is NOT derived"
section in part.** The emitted `main` calls **whichever interface's impl was declared FIRST**
(`Alpha` in AB, `Beta` in BA) while `println`'s `Display` dictionary constant **differs between the
permutations** and is the one implied by the *other* interface's signature. So `ping T`'s **value**
and `ping T`'s **type** are decided by two different selections that disagree — the raw word in AB is
Alpha's `String` pointer printed through `Int`'s `Display`, and the segfault in BA is Beta's `Int` 7
dereferenced through `String`'s `Display`. **The mis-selecting site is still not named** (that
remains owed), but the shape is now: *impl choice tracks declaration order; type/dict choice tracks
the other one.*

### CONTROL (`Beta` and its impl deleted)

```
$ MEDAKA_STRICT=1 ./medaka run .../i1620/ctl/main.mdk
exit=0
stdout:
alpha
$ MEDAKA_STRICT=1 ./medaka build .../i1620/ctl/main.mdk -o .../i1620/ctl/prog   -> exit=0
$ .../i1620/ctl/prog
exit=0
stdout:
alpha
```

Control fires; `alpha` at exit 0 on both engines.

### The pin

`test/must_fail_fixtures/1620-two-ifaces-same-method-binary-wrong-value/` — **LIVE**. Asserts
`cmd: build-run main.mdk` / `exit: 0` / `stdout: False` / `control: build-run control.mdk`. The Bool
projection is deliberate: the raw word is a live heap address, not byte-stable.

```
$ MEDAKA_STRICT=1 ./medaka build test/must_fail_fixtures/1620-.../main.mdk -o <tmp>/prog_main
build exit=0
$ <tmp>/prog_main
exec exit=0
stdout: False
$ MEDAKA_STRICT=1 ./medaka build test/must_fail_fixtures/1620-.../control.mdk -o <tmp>/prog_control
build exit=0
$ <tmp>/prog_control
exec exit=0
stdout: control-ok:alpha
```

Matches `claim.txt` exactly ⇒ **the pin REPRODUCES; not drained.**

⚠️ **The pin covers ONE permutation only** (the `Alpha`-first ordering). **Nothing in the corpus
grades the BA ordering, whose native arm SEGFAULTS.** See the recommendation at the end of
Deliverable 3.

### 🎯 THE DISCRIMINATOR — what a successful drain must change

**In BOTH permutations:** `run` must exit **0** printing `alpha` (or the program must be **rejected**
with a diagnostic at `check`, if the elected semantics is to reject an ambiguous occurrence), and the
built binary must exit **0** printing the same thing — where today AB gives `run`=1 /
binary=`<raw word>` at exit 0, and BA gives `run`=1 / binary=**segfault at 139**. Equivalently the
pin's `main.mdk` must print `True`.

⚠️ **The minimum acceptable outcome is not "no longer segfaults."** A change that turned BA's 139
into AB's silent raw word would be a **severity increase** by this repo's own ladder (loud → silent).
Grade the *value*, and grade both permutations.

⚠️ **Causal vs shape-move:** causal means the emitted `main` calls the impl whose interface the
occurrence's type resolved to, i.e. the `@mdk_impl_main__*_T__ping` call and the `@mdk_dc_0` Display
constant become **consistent with each other**. Re-run the two `--keep-ir` greps above post-fix: if
the two permutations still emit *different* `@mdk_dc_0` constants for the same source program modulo
ordering, the underlying disagreement survives and any value-level green is a shape move.

---

## #1618 (SIBLING, not a drain-target member) — an effect-carrying impl head cannot be BUILT

`gh issue view 1618` → **STATE: OPEN**, labels `S1: loud breakage, verified, ws:typecheck`.

### The issue's own repro (`/var/tmp/medaka-scratch/P0D/i1618/eff/`)

```
$ MEDAKA_STRICT=1 ./medaka check .../i1618/eff/main.mdk
exit=0
stdout:
main : Unit
-- /var/tmp/medaka-scratch/P0D/i1618/eff/main.mdk: ok (1 declaration(s) checked, 0 errors)
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka check --json .../i1618/eff/main.mdk
exit=0
stdout:
{"files":[{"file":"/var/tmp/medaka-scratch/P0D/i1618/eff/main.mdk","diagnostics":[]}]}
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka run .../i1618/eff/main.mdk
exit=0
stdout:
2
stderr:
(empty)

$ MEDAKA_STRICT=1 ./medaka build .../i1618/eff/main.mdk -o .../i1618/eff/prog
exit=1
stdout:
(empty)
stderr:
error: emitter failed compiling /var/tmp/medaka-scratch/P0D/i1618/eff/main.mdk
runtime error [E-PANIC]: no impl of method 'sz' for type '__none__'

exec: NOBIN (no executable produced)
```

### CONTROL — the impl head is plain `Int`, one effect row away

```
$ MEDAKA_STRICT=1 ./medaka run .../i1618/ctl/main.mdk    -> exit=0, stdout: 2
$ MEDAKA_STRICT=1 ./medaka build .../i1618/ctl/main.mdk -o .../i1618/ctl/prog -> exit=0
$ .../i1618/ctl/prog
exit=0
stdout:
2
```

**REPRODUCES EXACTLY as filed** (`check=0 run=0 [2] build=1` vs control `build=0 exec=0 [2]`), with
the byte-identical E-PANIC text.

### Permutations

⚠️ **The issue's repro has exactly ONE `impl` block, so it has no declaration order to permute** —
recorded as such rather than faked. To exercise an ordering dimension I added a second, unrelated
`impl Sz W` and ran both orderings (`/var/tmp/medaka-scratch/P0D/i1618/permA|permB/`):

| | `check` | `check --json` | `run` | `build` |
|---|---|---|---|---|
| permA (effect head declared first) | 0, ok | 0, `[]` | 0, `(2, 3)` | **1, E-PANIC `no impl of method 'sz' for type '__none__'`** |
| permB (`W` head declared first) | 0, ok | 0, `[]` | 0, `(2, 3)` | **1, same E-PANIC** |

**Both permutations identical, both correct on `run`, both un-buildable.** So #1618 is
**order-INDEPENDENT** — consistent with its mechanism (two head *projections* disagreeing), which has
no ranking step in it.

### The pin

`test/must_fail_fixtures/1618-effect-carrying-impl-head-cannot-build/` — **LIVE**. Asserts
`cmd: build main.mdk` / `exit: 1` / `control: build control.mdk`.

```
$ MEDAKA_STRICT=1 ./medaka build test/must_fail_fixtures/1618-.../main.mdk -o <tmp>/prog_main
exit=1
stderr:
error: emitter failed compiling .../1618-effect-carrying-impl-head-cannot-build/main.mdk
runtime error [E-PANIC]: no impl of method 'sz' for type '__none__'
$ MEDAKA_STRICT=1 ./medaka build test/must_fail_fixtures/1618-.../control.mdk -o <tmp>/prog_control
exit=0
stdout: built .../control.mdk -> <tmp>/prog_control
```

Matches `claim.txt` exactly ⇒ **the pin REPRODUCES; not drained.**

### 🎯 THE DISCRIMINATOR — what a successful drain must change

**`medaka build` on the effect-headed program must exit 0**, and the built binary must exit 0
printing **`2`** — i.e. the pin's asserted `exit: 1` must become `exit: 0`, which is what makes this
pin self-drain.

⚠️ **`build` exiting 0 is necessary but NOT sufficient**: also execute the binary. A fix that makes
the emitter accept the head but route it to the wrong impl would turn an S1 into an S0 — the
loud→silent regression this repo classifies as a **severity increase**.

⚠️ **This is not a Phase 4b target.** Like #1617 it lives in the `_ => None` **arm set**, and the
sprint doc's residual 2 rides it with 4b rather than with X-E. #1617 needs `TyFun` to be *given* a
tag; **#1618 needs the two head projections (`typecheck.headTyconTy` vs `eval`/`core_ir_lower`'s
`headTycon`) to AGREE** — the issue is explicit that these are different fixes and that neither
repairs the other. **If one drains and the other does not, that is the expected outcome, not a
partial failure** — grade them separately.

---

## #1608 — `core_ir_eval` selects a cross-module impl by IMPORT ORDER

`gh issue view 1608` → **STATE: OPEN**, labels `S1: loud breakage, verified, ws:emitter`.

Four modules (`/var/tmp/medaka-scratch/P0D/i1608/permA/`), re-authored from the issue body:
`iface.mdk` (`public export data Box a = Box a` + `export interface Sh x where sh : x -> String`),
`impl_int.mdk` (`impl Sh (Box Int)` → `"boxint"`), `impl_str.mdk` (`impl Sh (Box String)` →
`"boxstr"`), and `main.mdk` — the goal module — with
`main = println (sh (Box "hello"))`.

**Hand-derived correct answer: `boxstr`** (the receiver is `Box String`).

### ⚠️ First, a method note: the interpreted route to this arm DOES NOT WORK

`compiler/entries/core_ir_modules_main.mdk` cannot be driven with `medaka run`:

```
$ MEDAKA_STRICT=1 ./medaka run compiler/entries/core_ir_modules_main.mdk stdlib/core.mdk .../i1608/permA/main.mdk .../i1608/permA
EXITCODE=1
stderr:
.../compiler/entries/core_ir_modules_main.mdk:371:26: runtime error [E-STACK-OVERFLOW]: recursion too deep (evaluator call depth exceeded 25000); the tree-walking interpreter has no tail-call optimisation
```

So the probe must be **compiled**. That independently corroborates
`MUST-FAIL-NOT-PINNABLE.txt:174`'s *"the only driver … is the compiled probe … i.e. a `test/bin/*`
oracle, which is a different harness by construction."* Built into **scratch**, never the worktree,
with a plain `medaka build` (not `make`, not `test/build_oracles.sh`):

```
$ MEDAKA_STRICT=1 ./medaka build compiler/entries/core_ir_modules_main.mdk -o /var/tmp/medaka-scratch/P0D/core_ir_modules_main
built .../compiler/entries/core_ir_modules_main.mdk -> /var/tmp/medaka-scratch/P0D/core_ir_modules_main
EXITCODE=0
```

### PERMUTATION A — `main.mdk` imports `impl_int` first

`eval` and native arms:

```
$ MEDAKA_STRICT=1 ./medaka check .../i1608/permA/main.mdk        -> exit=0, "main : Unit"
$ MEDAKA_STRICT=1 ./medaka check --json .../i1608/permA/main.mdk -> exit=0, all four files "diagnostics":[]
$ MEDAKA_STRICT=1 ./medaka run .../i1608/permA/main.mdk
exit=0
stdout:
boxstr
$ MEDAKA_STRICT=1 ./medaka build .../i1608/permA/main.mdk -o .../i1608/permA/prog   -> exit=0
$ .../i1608/permA/prog
exit=0
stdout:
boxstr
```

**`cevalModules` arm** (the compiled probe):

```
$ /var/tmp/medaka-scratch/P0D/core_ir_modules_main <root>/stdlib/core.mdk .../i1608/permA/main.mdk .../i1608/permA
exit=0
stdout:
boxint
stderr:
(empty)
```

### PERMUTATION B — the two import lines SWAPPED (`impl_str` first), nothing else changed

```
$ MEDAKA_STRICT=1 ./medaka check .../i1608/permB/main.mdk        -> exit=0, "main : Unit"
$ MEDAKA_STRICT=1 ./medaka check --json .../i1608/permB/main.mdk -> exit=0, all four "diagnostics":[]
$ MEDAKA_STRICT=1 ./medaka run .../i1608/permB/main.mdk
exit=0
stdout:
boxstr
$ MEDAKA_STRICT=1 ./medaka build .../i1608/permB/main.mdk -o .../i1608/permB/prog   -> exit=0
$ .../i1608/permB/prog
exit=0
stdout:
boxstr

$ /var/tmp/medaka-scratch/P0D/core_ir_modules_main <root>/stdlib/core.mdk .../i1608/permB/main.mdk .../i1608/permB
exit=0
stdout:
boxstr
stderr:
(empty)
```

### The four-engine table

| arm | permA (`impl_int` first) | permB (`impl_str` first) | correct |
|---|---|---|---|
| `check` / `check --json` | 0, silent | 0, silent | — |
| `eval` (`run`) | `boxstr` ✅ | `boxstr` ✅ | `boxstr` |
| native (`build`+exec) | `boxstr` ✅ | `boxstr` ✅ | `boxstr` |
| **`cevalModules`** (probe) | **`boxint`** ❌ | `boxstr` ✅ | `boxstr` |

**VERDICT: REPRODUCES.** The Core-IR interpreter answers `boxint` for a `Box String` receiver, at
exit 0, with `check` clean.

⚠️ **One wording correction to the issue body, recorded rather than smoothed over.** The issue says
*"swapping the two import lines flips **both** answers."* Measured here, **`eval` and native are
order-INVARIANT and correct in both orderings**; only the `cevalModules` arm moves. The claim the
measurement supports is *"the `cevalModules` answer tracks import order and ignores the receiver
type"* — which is still the mechanism the issue argues for, and it is established by the flip, not
inferred. Whether the issue's original program differed, or the wording is loose, is **UNVERIFIED**;
either way the defect is confirmed.

⚠️ Note the flip means **permB's `cevalModules` cell is ACCIDENTALLY CORRECT.** A one-ordering probe
that happened to pick permB would report this issue as **not reproducing**. That is the concrete
reason a single ordering proves nothing here.

### The pin

**THERE IS NO PIN, and the refusal is on the record.** `test/MUST-FAIL-NOT-PINNABLE.txt:174` carries
the entry, refusing with the derived argument reproduced in Deliverable 2 below. Confirmed by
listing: `test/must_fail_fixtures/` has directories for 1182, 1617, 1618, 1619 and 1620 — **none for
1608**.

### 🎯 THE DISCRIMINATOR — what a successful drain must change

**`core_ir_modules_main <core.mdk> permA/main.mdk permA/` must print `boxstr`** (not `boxint`) at
exit 0, **and permB must still print `boxstr`** — i.e. the `cevalModules` arm becomes both correct
and order-invariant, matching the `eval` and native arms it already diverges from.

⚠️ **Do NOT grade this by "all engines agree"** — three of the four already agree today, and the
issue's own body warns against cross-engine agreement as an oracle (all three have been equally
wrong before, #1047). Grade the fourth arm's *value*, on **both** orderings, because one of them is
already right by accident.

⚠️ **This is NOT drained by Phase 4 or Phase 4b.** The sprint doc's residual 3 states it is a genuine
engine defect in `core_ir_eval.mdk`'s independent dispatcher, outside X-E.C's LLVM/wasm scope and
outside typecheck, needing its own owner call. **If it drains during this sprint, that is a shape
move by definition** — say so, and identify what actually moved.

---

# Deliverable 2 — Q5: which harness carries #1608?

## Clause-by-clause verification of the sprint doc's §4 Q5 paragraph

### Clause 1 — *"`run_verb` offers check / check-json / check-types / run / build / build-run / fmt-write / mcp-call, and every one drives `eval.mdk` or the native path; none reaches `cevalModules`."* ✅ **VERIFIED**

`test/diff_compiler_must_fail.sh:234-270`. The `case` has exactly these arms:

```
    check)       bound "$MEDAKA" check         "$_dir/$_file" ...
    check-json)  bound "$MEDAKA" check --json  "$_dir/$_file" ...
    check-types) bound "$MEDAKA" check --types "$_dir/$_file" ...
    run)         bound "$MEDAKA" run           "$_dir/$_file" ...
    build)       bound "$MEDAKA" build "$_dir/$_file" -o "$_out.bin" ...
    build-run)   bound "$MEDAKA" build ... ; bound "$_out.bin" ...
    fmt-write)   bound "$MEDAKA" fmt --write "$_work/$_file" ...
    mcp-call)    ( cd "$ROOT" && bound "$MEDAKA" mcp <"$_dir/$_file" ... )
    *) echo "unknown verb: $_verb" >"$_out"; return 127 ;;
```

**Eight verbs, all invoking `$MEDAKA`** — the shipped binary — via `check`/`run`/`build`/`fmt`/`mcp`.
None invokes a `test/bin/*` oracle; none can reach `cevalModules`. **Independently corroborated by
measurement above:** the shipped binary is CORRECT on this program on every verb available here
(`run` → `boxstr`, `build`+exec → `boxstr`, both orderings), so a fixture written here would pin
behaviour that is already right — the opposite of what the suite is for.

### Clause 2 — *"`diff_compiler_engines.sh` has three arms (eval, native, wasm) and this driver is not one of them."* ✅ **VERIFIED**

`test/diff_compiler_engines.sh:19` — *"for each fixture f:   eval(f) == native(f) == wasm(f)"*;
`:247` — *"signature = `<en>:<nw>:<ew>:<eval>:<native>:<wasm>` — the three PAIRWISE verdicts"*;
`:292-293` initialises exactly `eval.out` / `native.out` / `wasm.out` (and their `.err` siblings).
**Three arms; no Core-IR arm.**

### Clause 3 — *"the only driver that reaches the broken arm is the compiled probe `compiler/entries/core_ir_modules_main.mdk`."* ⚠️ **VERIFIED WITH A CORRECTION — there are TWO**

```
$ grep -n "cevalModules\|cevalProgram\|cevalModulesOutput" compiler/entries/*.mdk
compiler/entries/core_ir_modules_main.mdk:22:import ir.core_ir_eval.{cevalModulesOutput}
compiler/entries/core_ir_modules_main.mdk:45:    Ok mods => putStr (cevalModulesOutput ...)
compiler/entries/profile_eval_main.mdk:42:import ir.core_ir_eval.{cevalModulesOutput}
compiler/entries/profile_eval_main.mdk:102:  let outC = cevalModulesOutput coreDecls modules
```

**`compiler/entries/profile_eval_main.mdk` also drives `cevalModulesOutput`**, and it IS gated —
`test/diff_compiler_eval_scaling.sh:91` reads `test/bin/profile_eval_main` (nightly). **The clause's
CONCLUSION survives anyway**, for two reasons visible in that driver's own header: it is a **timing**
driver graded on `[perf]` lines, not values, and it is explicitly **UNTYPED and single-file** —
*"⚠️ UNTYPED PATH, DELIBERATELY. Both drivers take DESUGARED decls and run WITHOUT marker/typecheck"*,
over a one-element module list `[("target", decls)]`. So it cannot grade #1608's value and cannot
reach a cross-module goal at all. **Correct wording: two entries reach `cevalModules`; neither can
grade this defect, and only `core_ir_modules_main` is even multi-module.**

### Clause 4 — 🚨 *"the one gate that does run `cevalModules` drives the UNTYPED path (desugar + annotate, no marker, no typecheck) … its green proves nothing in either direction."* ✅ **VERIFIED, and the gate is `test/diff_compiler_core_ir_modules.sh`**

Found by derivation, not assumption:

```
$ grep -rln "core_ir_modules_main\|cevalModules" test/
test/MUST-FAIL-NOT-PINNABLE.txt
test/build_oracles.sh
test/ENGINE-DIVERGENCE.md
test/diff_compiler_eval_scaling.sh
test/diff_compiler_core_ir_modules.sh
test/registry_keying_ratchet.sh
test/snapshots/compiler/{core_ir_eval,eval,typecheck,core_ir_lower,resolve}.md
test/must_fail_fixtures/{1462,1292,1397,1396}-*/claim.txt
test/eval_modules_fixtures/ctor_type_member_arity/main_ctortypemember.mdk
```

Of those, the **gate** is `test/diff_compiler_core_ir_modules.sh` (`SELF="$ROOT/test/bin/core_ir_modules_main"`, line 21).
Its own header, lines 12-13: *"Each fixture is a directory under `test/eval_modules_fixtures/` …
**Fixtures stay on the UNTYPED path.**"* And the entry it drives says, lines 6-8: *"desugars +
**annotates** each … LOWERS them per-module to Core IR"* — **no marker, no typecheck**. Confirmed
independently by `profile_eval_main.mdk:25-27`, which names both drivers as untyped.
**The clause is exactly right.**

Its consequence, restated precisely: the gate diffs against `main.eval.golden` — goldens captured
from `medaka run`, i.e. the **tree-walker** — so it is a genuine equivalence check *of the untyped
path*, but with no `Route` ever stamped it cannot tell a correct route word from no route word,
which is exactly where #1608 lives.

## The answer: cheapest harness change that makes #1608 gradeable

### Option A — a FOURTH engine arm in `diff_compiler_engines.sh`

**Cost: HIGH. Recommend against.**

- `engines` is the **POLE shard** (373s/364s on merge_group runs `31655422530` / `31653614351`, per
  `ci.yml`'s own re-derivation at the `flat_vs_onemodule` entry). A fourth arm across that corpus is
  the worst available place to add work.
- The gate's design is *"a fixture must run on ALL THREE arms to be in the corpus at all"* (line 52).
  A fourth arm is not an addition, it is a re-definition of corpus membership, plus a 4th-arm
  expansion of the pairwise signature (three pairs → six).
- 🚨 **It would still drive the UNTYPED path** and therefore still be structurally blind to route
  words. This option pays the highest price and does not buy the missing property.
- It adds a `test/bin` oracle dependency to the pole shard, plus a large one-time
  `test/engine_divergence.txt` ledger churn for every corpus fixture whose typed and untyped answers
  differ.

### Option B — a TYPED multi-module gate driving `cevalModules` ⭐ **RECOMMENDED**

**Cost: MEDIUM in code, LOW in CI, and it is the only option that runs where the bug lands with
routes stamped.**

Three of the four pieces already exist:

1. **The entry is a near-twin of one already in the tree.**
   `compiler/entries/core_ir_typed_modules_dump_main.mdk` already performs
   `driveModules → runEmitWith → mangle → elaborateModules → dceFilter → lowerProgramEmit` — the
   full **typed, dict-passed, multi-module** lowering — and then prints `cprogramToSexp`. A sibling
   `core_ir_typed_modules_main.mdk` that calls **`cevalModules`** instead of `cprogramToSexp` is a
   small, local delta over a proven driver. Its header also independently confirms the build note in
   Deliverable 1: *"Build it native: `medaka run` on any compiler-graph entry overflows the
   tree-walking interpreter's 25000-frame budget."*
2. **The gate skeleton exists.** `test/diff_compiler_core_ir_modules.sh` is ~40 lines: loop fixture
   dirs, run `$SELF $CORE $entry $dir`, diff against `main.eval.golden`. A typed sibling is the same
   shape against the typed reference path.
3. **The typed multi-module corpus exists**: `test/eval_typed_modules_fixtures/` — **21 fixtures**,
   currently read by exactly one gate (`test/diff_compiler_eval_typed_modules.sh`).
   ⚠️ Adding a second consumer enrols that directory in the shared-corpus rule — both gates must be
   run together thereafter, and that must be written into both headers.

🎯 **The decisive cost fact: NO `ci.yml` EDIT AND NO `CI-COVERAGE-EXCEPTIONS.txt` ROW ARE NEEDED.**
The `gates (eval)` shard's pattern already contains the glob `'diff_compiler_core_ir*'`
(`.github/workflows/ci.yml:701`), so a PROPOSED gate placed under test/ and named with the
prefix `diff_compiler_core_ir` plus a `_typed_modules` suffix — spelled in parts rather than as a
path, because it does not exist yet and the doc-link gate correctly refuses a citation to a
non-existent file — is
matched the moment it is created and `diff_compiler_ci_shard_coverage.sh` is satisfied
automatically — the usual new-`test/*.sh` tax does not apply. And `eval` is the **cheapest shard on
both re-derived runs** (149s/151s), the opposite end of the cost distribution from Option A.
⚠️ Those shard numbers are quoted from `ci.yml`'s own comment and rot; re-derive with the one-liner
recorded beside them before committing to placement.

Remaining real cost: one new `compiler/entries/*.mdk`, one new oracle name in
`test/build_oracles.sh`, one new ~40-line gate, and a golden capture across 21 fixtures — plus one
fixture for #1608's own shape.

### Option C — a new `run_verb` in the must-fail harness

**Cost: LOWEST in lines, WRONG in shape. Recommend against.**

- It would be the **first verb in that harness that does not invoke the shipped `$MEDAKA` binary**,
  breaking an invariant all eight current verbs hold. It introduces a `test/bin/*` oracle dependency
  into a harness with no oracle-staleness handling — a missing or stale oracle would turn every row's
  verdict into noise, in the one suite whose reds are supposed to mean *"someone fixed something."*
- 🚨 **It would drive the UNTYPED path**, so it pins the untyped answer and still cannot see a route
  word — Option A's blindness, for one issue instead of a corpus.
- It buys coverage for **exactly one issue** and no gate coverage for the class.
  `MUST-FAIL-NOT-PINNABLE.txt:174` already frames it correctly: *"Delete this line … the day this
  harness gains a Core-IR-interpreter verb, at which point pin it there instead"* — i.e. the verb is
  a **follow-on convenience once the engine is gradeable**, not the fix.

### 🎯 RECOMMENDATION

**Option B — build the typed multi-module Core-IR *evaluating* gate.** It is the only one of the
three that satisfies *"a gate must RUN where the bug lands"* **with routes stamped**; it costs
nothing in CI wiring (the shard glob already matches) and lands on the cheapest shard; and it reuses
an existing near-twin entry, an existing gate skeleton and an existing typed corpus. Once it exists,
Option C becomes a cheap optional extra and `MUST-FAIL-NOT-PINNABLE.txt:174` retires on its own
stated terms.

⚠️ **Two things Option B does NOT do, stated so nobody infers them:** it does not fix #1608, and its
first green would mean **capturing goldens from an engine known to be wrong on this class** — the
`CAPTURE=1` hazard verbatim. The #1608 fixture's expected value must be **hand-derived from DICT §8**
and written to assert the *correct* answer, so that it starts **RED**; it must never be captured
from `cevalModules`.

⚠️ **Ownership: still UNOWNED.** The sprint doc's residual 3 states #1608 needs its own owner call
and the adopted ruling does not make one. This deliverable **sizes** the options; the call is the
owner's.

---

# Deliverable 3 — the permutation instrument

## `test/diff_compiler_import_order.sh` — current signature and arms

521 lines. From its own header:

> `diff_compiler_import_order.sh` — the IMPORT-CLAUSE PERMUTATION DIFFERENTIAL.
> Unit 0 of #1319 (constructor-namespace identity). It exists for one reason:
> **⭐ A GOLDEN CANNOT CATCH AN OVER-WIDENING.** … The check for an order-dependence bug is a
> PERMUTATION DIFFERENTIAL: permute the input along the suspect axis and require the answer to be
> invariant. That needs NO ground truth, which is what makes it able to see a widening nobody has
> written down the right answer for.

**The axis: the ENTRY MODULE'S IMPORT-CLAUSE ORDER.** The unit is a **directory** (multi-module),
distinguishing it from `test/diff_compiler_dict_semantics.sh` §4, which is the sibling permutation
differential and permutes **`impl` BLOCKS** in a **single file**.

**THE SIGNATURE** — the one-line reduction that must be invariant across every ordering:

```
check=<exit>;codes=<sorted,comma>;schemes=<check stdout>;run=<exit>:<stdout>;build=<exit>/<exec-exit>:<stdout>
```

**Five cells, three engine-facing arms:**

| cell | what it grades |
|---|---|
| `check=` | `medaka check --json` exit code (exact code kept — 1 vs 2 is a change) |
| `codes=` | every `"code":"…"` from `check --json`, **sorted**, as a **multiset** not a set |
| `schemes=` | plain `medaka check`'s scheme dump for the user's own top-level bindings, selected by FORMAT (`<name> : <type>` at column 0). Sees *"exit 0, same printed value, but the binding was INFERRED AT A DIFFERENT TYPE"* |
| `run=` | **eval arm** — `medaka run` exit code + stdout |
| `build=` | **native arm** — `medaka build` exit code, then the built binary's exit code + stdout (`-` if no binary) |

Deliberately NOT compared: diagnostic **message text** (`R-AMBIGUOUS-CTOR` names colliding modules
in import-clause order on purpose).

## Does it have a wasm arm? **NO.**

```
$ grep -ni wasm test/diff_compiler_import_order.sh
505:# every wasm gate in this tree once shelled out to an absent tool, printed "skipping"
```

**Exactly ONE hit, at line 505, and it is a comment about an unrelated absent-tool hazard.**
Re-derived at HEAD `aaa43716`; this confirms the sprint doc's §4 Q4 finding is **still true** and
nothing has landed since. ⚠️ Q4 is SUPERSEDED as *this sprint's* work (inherited by X-E.C per the
adoption table), but the fact is re-derived here because Deliverable 3 asks for it and because
X-E.C's owner will need a fresh derivation rather than an inherited one.

## Are any of the six shapes already fixtures in `test/import_order_fixtures/`? **NO — none.**

```
$ ls test/import_order_fixtures/
1253-record-form-ctor-head-decided-by-import-order
1284-overlay-sibling-ctor-beats-named-import
1351-methoddispatchidx-import-order-collision
733-ambiguous-ctor-reject-cascade-order-dependent
733-wildcard-import-ctor-falls-to-universe
conditional-impl-evidence-routed-invariant
control-ambiguous-ctor-reject-invariant
control-named-ctor-import-invariant
control-three-clause-invariant
evidence-unroutable-invariant
field-owner-no-narrowing-invariant
record-named-type-vs-held-value-invariant
record-value-only-import-invariant
record-reexport-identity-invariant
```

**14 cases. Issue-named: #1253, #1284, #1351, #733 ×2. NONE of #1182 / #1608 / #1617 / #1618 /
#1619 / #1620 appears.** `test/IMPORT-ORDER-LEDGER.txt` currently carries exactly **two live
known-bad rows** — `733-ambiguous-ctor-reject-cascade-order-dependent` (#733) and
`1351-methoddispatchidx-import-order-collision` (#1351); three further rows were **drained**
2026-08-05 by #1319 unit 1 and their fixtures kept as invariance guards.

### ⚠️ But "uncovered" is not the same as "belongs here" — split the six by AXIS

The gate permutes **import clauses in the entry module**. That is the wrong axis for three of the
six, and filing them here would produce a fixture that cannot fail:

| issue | order axis | belongs in |
|---|---|---|
| **#1182** | `impl` BLOCK order, single file | `diff_compiler_dict_semantics.sh` §4 (`KNOWNBAD_PERM`) — **but see below** |
| **#1617** | `impl` BLOCK order, single file | same |
| **#1620** | `impl` BLOCK + `interface` decl order, single file | same |
| **#1618** | **NO order axis** (one impl; measured invariant with a second added) | neither — its pin is correct as-is |
| **#1619** | IMPORT-CLAUSE order — **but measured INVARIANT** (both orders give `(100, 100)`) | ⚠️ **an INVARIANT case, not a ledger row** |
| **#1608** | IMPORT-CLAUSE order — **measured DIVERGENT** on the `cevalModules` arm only | ⭐ **this gate — except the gate has no arm that can see it** |

## 🎯 The named uncovered shape — and the honest complication

**#1113's own comment** (`gh issue view 1113`) recommends its uncovered shape for
`test/import_order_fixtures/` as a known-bad ledger row:

> **Uncovered shape** (same-spelled interfaces, impls at the **same head**, same method name):
> **conjunct 2 holds, conjunct 1 fails.** Both qualified symbols are emitted with order-invariant
> bodies — and **both call sites still call the same one**, with import order deciding which.
> Identical to base on all four channels, `check` exit 0, no diagnostic.
> … The discriminating regression program is the uncovered shape above; it is recommended for
> `test/import_order_fixtures/` as a known-bad ledger row.

**That shape is NOT any of my six.** It is same-*spelled* interfaces at the same head; #1182 is
differently-spelled interfaces sharing a method name, single-file, `impl`-order. So #1113's
recommendation stands on its own and is **still unfiled** — no `1113-*` directory exists.

**Naming which of MY shapes is uncovered here, as asked:**

⭐ **#1608 is the one that belongs in this gate and is uncovered — and it CANNOT be filed today,
because the gate's signature has no cell that can see it.** All five signature cells
(`check`/`codes`/`schemes`/`run`/`build`) are **invariant** across #1608's two orderings — measured
above, every one of them identical — while the `cevalModules` arm flips `boxint` ↔ `boxstr`. A
fixture filed here now would be graded **INVARIANT and pass**, which is worse than no fixture: it
would stand as positive evidence that the shape is order-free.

> 🎯 **This is the same structural gap Deliverable 2 answers, arriving from the other direction.**
> Q5 says no must-fail verb reaches `cevalModules`; Deliverable 3 says no *permutation-differential*
> cell reaches it either. **Option B (a typed multi-module Core-IR evaluating gate) is what unblocks
> BOTH** — and a natural sixth signature cell, `ceval=<exit>:<stdout>`, would let this gate carry
> #1608 as a proper known-bad row afterwards. That is a strictly larger change than Option B alone
> and is **not** part of the recommendation; it is named so the owner can see the end state.

### Secondary recommendation — #1619 as an INVARIANCE case, not a ledger row

#1619 is multi-module and import-ordered in shape but **measured order-INVARIANT** (both orderings:
`(100, 100)` on `check`/`run`/`build`/binary). Per the ledger's own format rule — *"At least TWO
signatures are required — a row asserts a DIVERGENCE, and one signature is not a divergence"* — it
**cannot legally be a ledger row.** If it is wanted here at all it is as an ordinary **invariant**
case (no ledger row), which would then guard against a future fix *introducing* order-dependence
while #1619's own must-fail pin keeps grading the value. ⚠️ Modest value; the must-fail pin already
grades the thing that is wrong. Recorded as an option, not a recommendation.

### ⚠️ Five things a reviewer must demand before ANY new ledger row

Transcribed from `test/IMPORT-ORDER-LEDGER.txt`'s own header, because Phase 4b will be tempted to add
one and the file is explicit that *"a tripwire's false positive is its masking path"*:

1. an issue number `#<digits>` of an **OPEN** issue (the gate checks syntax only; check by hand);
2. a fixture directory named `<issue-number>-...` — the anti-reflexive-bump lock;
3. **the actual outputs, transcribed** — never hand-derived; run the gate with the row absent and
   paste what it prints;
4. a **pre-existing** bug, not one the PR introduced;
5. the case's own `case.txt` saying **how the expected values were established**.

### ⚠️ CORRECTION to the axis table above — the `impl`-order routing is NOT a clean handoff

The table's right-hand column for #1182 / #1617 / #1620 says *"`diff_compiler_dict_semantics.sh` §4"*
and carried a "but see below" — this is the below, and it partially retracts that routing. Derived
from the gate's own header rather than assumed:

- `test/diff_compiler_dict_semantics.sh:295` — *"🚨 Section 4 permutes `impl` BLOCKS **WITHIN ONE
  FILE**"*; `:252` — *"Section 4 is scoped to files directly in `test/dict_fixtures/*.mdk`"*;
  `:245` — *"Section 4 tests exactly **ONE reordering** per qualifying fixture"*, not all `n!`.
- So the **mechanism** does reach a single-file `impl`-order shape. **#1617** (one interface, two
  function-typed impls) is a clean fit.
- **But #1182's own `claim.txt:89-96` argues the corpus does not:** *"§4 permutes `impl` blocks
  within a fixture whose impls belong to **one class**, so nothing there can reach this shape."*
  #1182 and #1620 are **two interfaces**; a fixture for them would be the first multi-interface
  member of `test/dict_fixtures/`, which is a corpus-scope change, not a fixture addition.
- ⚠️ And §4 grades only `run` and `build` ledgers — it has **no `check --json` codes cell and no
  scheme cell**, so it could not see #1620's `check`-clean-but-divergent-`@mdk_dc_0` character.

**Net:** #1617 is routable to §4 today; **#1182 and #1620 are not, without widening that corpus.**
All three already have live must-fail pins that grade the value, so nothing is currently ungated —
what is missing is *permutation* coverage, and for #1620 specifically the **BA ordering is graded by
nothing at all** (its pin covers only the `Alpha`-first ordering, and BA's native arm **segfaults**).

⭐ **Concrete, cheap follow-on, sized but NOT recommended by this packet** (it is a second issue's
work, not Phase 4b's): add `permutation.mdk` to the #1620 fixture the way #1617's fixture already
ships one as an ungraded sibling — it costs one file, documents the segfault ordering in the tree,
and makes the asymmetry visible to whoever grades the drain. Alternatively file the BA segfault as
its own issue; **this packet does not file it**, per the standing rule against filing an
unreproduced-by-a-second-party claim. It IS reproduced first-hand here, twice, with the exact
transcript in Deliverable 1 — the owner can file it from that.

---

# Repeatability spot-checks (quiescence discipline, applied to the two unstable cells)

## #1620 permutation BA — the segfault is DETERMINISTIC, 3/3

```
$ .../i1620/ba/prog        (three consecutive executions)
run 1: exit=139   stdout: (empty)   stderr: runtime error [E-FATAL-SIGNAL]: fatal memory fault (segmentation fault)
run 2: exit=139   stdout: (empty)   stderr: runtime error [E-FATAL-SIGNAL]: fatal memory fault (segmentation fault)
run 3: exit=139   stdout: (empty)   stderr: runtime error [E-FATAL-SIGNAL]: fatal memory fault (segmentation fault)
```

Not a flake. This is a stable, `check`-clean path to a memory fault.

## #1620 permutation AB — the raw word is NOT byte-stable, 3/3 distinct

```
$ .../i1620/ab/prog        (three consecutive executions)
run 1: exit=0   stdout: 47383624360248
run 2: exit=0   stdout: 46933065644344
run 3: exit=0   stdout: 47172059699512
```

Three executions, three values, all at exit 0 — **first-hand confirmation of the issue's own warning**
that an exact-match pin on this word would red on the next run for no reason, and therefore that its
fixture's Bool projection is the right instrument. ⚠️ **Any post-fix grading of #1620 must use the
projection, never the word.**

---

# REFUSALS

Nothing in this packet failed to reproduce. The items below are things stated as **not derived**,
**corrected**, or **out of this packet's authority**, recorded rather than smoothed over.

### UNVERIFIED — #1608's *"swapping the two import lines flips BOTH answers"*
Measured here, `eval` and native are **order-INVARIANT and correct** in both orderings; only the
`cevalModules` arm flips (`boxint` → `boxstr`). The defect and its mechanism are confirmed; the
issue body's word *"both"* is not. Whether the original program differed or the wording is loose is
**UNVERIFIED** — I did not have the reporter's exact sources. It does not change the finding.

### CORRECTED — Q5 clause 3, *"the ONLY driver … is `core_ir_modules_main.mdk`"*
**Two** entries call `cevalModulesOutput`; the second is `compiler/entries/profile_eval_main.mdk`
(gated by `test/diff_compiler_eval_scaling.sh`, nightly). The clause's conclusion survives — that
driver is a **timing** driver over a **single-file, untyped** module list — but the word *"only"* is
wrong as written and is fixed in Deliverable 2.

### CORRECTED — my own Deliverable 3 axis table
It initially routed #1182 / #1617 / #1620 to `diff_compiler_dict_semantics.sh` §4 without checking
that gate's corpus scope. Retracted in the correction block: **#1617 is routable there today; #1182
and #1620 are not**, because §4's corpus is single-class by construction (#1182's own `claim.txt`
argues exactly this) and §4 has no `codes`/`schemes` cell.

### NOT DERIVED — #1620's mis-selecting SITE
The issue records this as owed and it remains owed. This packet narrows it: the emitted `main` calls
whichever interface's impl was **declared first**, while `println`'s `Display` dictionary constant
`@mdk_dc_0` differs between the permutations and follows the *other* interface's signature. **That is
a shape, not a site** — I did not identify the function that makes the wrong choice.

### NOT FILED — the #1620 BA-ordering segfault
Reproduced first-hand, three consecutive deterministic executions, transcript in Deliverable 1. **This
packet does not open an issue for it** (P0-D is a read-only baseline packet, and filing is the
owner's call). It is recorded here so it cannot be lost, and it is currently **graded by nothing**:
#1620's pin covers the `Alpha`-first ordering only.

### NOT ANSWERED — #1608's ownership
Deliverable 2 **sizes** three options and recommends one. It does **not** assign an owner; the
sprint doc's residual 3 reserves that call, and this packet does not make it.

### NOT RUN — the full must-fail suite
Per the brief, only the five relevant fixture directories were inspected and their own graded cases
run individually. **No claim is made about the suite's overall verdict**, and in particular
*"100 reproduce, 0 drained"* is inherited from the sprint doc, not re-derived here.

### NOT RUN — any gate, and no rebuild of `./medaka`
No `make`, no `test/build_oracles.sh`, no `run_gates.sh`, no `preflight`. The one compilation this
packet performed was `medaka build compiler/entries/core_ir_modules_main.mdk -o /var/tmp/...`, a
plain per-process `medaka build` writing **only** to `/var/tmp/medaka-scratch/P0D/`, which cannot
collide with the worktree owner's build. **No file inside the repository worktree was modified**
except this record.

---

# Exit-criterion-3 checklist for whoever grades the drain on the FINAL binary

Re-run the transcripts above and compare against these pre-fix values. **All probe sources are
preserved at `/var/tmp/medaka-scratch/P0D/`** and can be re-run with
`sh /var/tmp/medaka-scratch/P0D/probe.sh "<label>" <file>`.

| # | observable | PRE-FIX value (this binary, `aaa43716`) | drained iff |
|---|---|---|---|
| **1182** | `run` stdout, both `impl` orders | `1` / `2` — **DISAGREE** | both orders agree, or both rejected |
| **1182** | specificity probe `run` stdout | `1` (specific-but-second wins) | causal fix removes it from the candidate set entirely |
| **1617** | `run` stdout, both orders | `(5, 5)` / `(9, 9)` | **both** print `(5, 9)` |
| **1617** | `build` exit, both orders | `1` + E-PANIC | `0`, binary prints `(5, 9)` |
| **1619** | `run` + binary stdout, both import orders | `(100, 100)` — **AGREE, wrongly** | `(7, 100)` |
| **1619** | both-method-less variant | `(200, 200)` | `(7, 200)` |
| **1620** | AB: `run` exit / binary exit+stdout | `1` (`intToString: not an Int`) / `0` + unstable raw word | `0` + `alpha` on both |
| **1620** | BA: `run` exit / binary exit | `1` (`putStrLn: not a String`) / **`139` SEGFAULT** | `0` + `alpha` |
| **1620** | `@mdk_dc_0` constant across the two orders | **DIFFERENT** (`193460240` vs `6952779160540`) | consistent with the impl actually called |
| **1608** | `core_ir_modules_main` stdout, permA / permB | `boxint` ❌ / `boxstr` ✅ | `boxstr` on **both** |
| **1618** | `build` exit | `1` + `no impl of method 'sz' for type '__none__'` | `0`, binary prints `2` |

🚨 **Three cells above already "agree" pre-fix** (#1619 both orders, #1618 both orders, #1608 permB).
For those, **agreement post-fix proves nothing** — grade the VALUE. That is the single most
important thing this baseline exists to record.
