# F1 — verification round: six S0-candidates run against three binaries

**Pin `fdc0109c` (branch).** Two extra arms built cold in their own worktrees, no emitter borrowed:

| arm | commit | what it is |
|---|---|---|
| `sprintbase` | `2b9dc798` | the sprint's parent — the true base |
| `predrain` | `85ceec1f` | immediate parent of `1e7cbbbb` (B-2.1-b2, THE drain); has `a2`/`a3`/`a4`, **not** `b2`/`g` |
| `branch` | `fdc0109c` | the pin |

`MEDAKA_ROOT`/`MEDAKA_EMITTER` confirmed unexported before any differential. Every `build` redirected
to a file with `$?` read directly — never piped. No verdict below rests on engine agreement.

**Ranked, loudest first.**

---

## 🚨 Finding 6 (R3's P1) — **CONFIRMED S1.** A loud compile-time refusal became an exit-0 build of a crashing binary, and C4 is still violated.

The single highest-value result of this round, and R3's own mandatory control is what makes it stand up.

**P1 proper** — impl in `n` defines only `lt`, **inherits** `compare`; `m` uses it and does not import `n`;
the lever is the order of `import n` / `import m` in `main.mdk`.

```
--- arm=sprintbase order=a ---
run:   1  out=[/var/tmp/r3p1a/m.mdk:5:12: Cannot pass a dictionary for `Cmp (Box Int)`: a matching
               `impl Cmp …` does exist in this program and is a candidate here, but this compiler
               cannot yet route its evidence to this code — the impl is declared in a module that
               this one does not import. This is a compiler l…]
build: 1
--- arm=sprintbase order=b ---
run:   0  out=[True]        build: 0    exe: 0  out=[True]

--- arm=branch order=a ---
run:   1  out=[runtime error [E-PANIC]: no matching impl for dispatch]
build: 0                                       <-- the compiler ACCEPTS it
exe:   1  out=[runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match]
--- arm=branch order=b ---
run:   0  out=[True]        build: 0    exe: 0  out=[True]
```

IR diff between the two orders on the branch: **589 lines** (base cannot build order a at all).

**Positive control — R3 said P1 is worthless without it.** Identical five files, except the impl in `n`
**also defines `compare`**, so `implDefinesMethodAt`'s answer stops mattering (both names select the
same row):

```
--- CONTROL arm=sprintbase order=ca --- run: 1 (same limitation diagnostic)   build: 1
--- CONTROL arm=sprintbase order=cb --- run: 0  out=[True]
--- CONTROL arm=branch     order=ca --- run: 0  out=[True]   build: 0   exe: 0  out=[True]
--- CONTROL arm=branch     order=cb --- run: 0  out=[True]   build: 0   exe: 0  out=[True]
```

**The control CONVERGES on the branch while P1 does not.** That is the whole finding: the
discriminator is the *method-set-membership guard*, not the program shape. **R3's root cause is
CONFIRMED, not retracted.** R3's own falsifier (*"if `m` rejects under both orders, P1 is inert"*)
does not fire — order b compiles and runs on both arms.

Two things confirmed at once:

1. **C4 is still violated on the branch.** The same program's fate depends on import order
   (`a` ≠ `b`). This reproduces R3's *CONJUNCT-2-ONLY — NARROWED but NOT CLOSED* verdict
   **behaviourally**, not by source reading. Note the control shows the sprint did close a real
   sub-case: base rejected `ca`, branch accepts both.
2. **The sprint made this quieter, which AGENTS.md rules a severity INCREASE.** Base refused at
   compile time and *said exactly why*. The branch builds it at exit 0 and hands you a binary that
   dies. `medaka build` returning 0 for a program it cannot route is the S1.

**Not S0** — no wrong value at exit 0; both failure paths are loud at runtime.
**What else could explain it:** nothing benign I can find — the control isolates the guard, and the
base arm proves the fixture is compilable, so this is not fixture breakage.

---

## 🚨 Finding 5 (R6-D1) — **CONFIRMED, S1 gate-coverage gap.** The fourth engine arm is blind by construction.

⚠️ **R6's command as written does not work**: `medaka run compiler/entries/core_ir_modules_main.mdk …`
dies with `E-STACK-OVERFLOW` (interpreter call depth > 25000). The **native oracle is required** —
`FORCE=1 sh test/build_oracles.sh --build-one core_ir_modules_main`.

`speak (Box "s")` with `Box Int` and `Box String` impls in two sibling modules — correct answer `boxstr`:

```
eval:          boxstr   ✓
native (LLVM): boxstr   ✓
core_ir_eval:  boxint   ✗   (test/bin/core_ir_modules_main, exit 0)
```

**Positive control** — `speak (Box 1)`, correct answer `boxint`:

```
eval: boxint ✓   native: boxint ✓   core_ir_eval: boxint  (same value as the other program)
```

The fourth arm returns `boxint` for **both** programs — it is arg-tag first-impl-wins, exactly as R6
predicted. The typed arms move with the program, so the harness is demonstrably fail-capable; the
constant is the arm, not the probe.

**Read it as R6 instructs:** this is *not* a new bug in `cevalModules`. It is proof that
`diff_compiler_core_ir_modules.sh` — the only gate exercising `cevalModules` — runs the **untyped**
path, where no `Route` is stamped at all, and therefore **cannot distinguish a correct route word
from no route word**. F-2 confirmed as a live structural blind spot, green or red.

---

## Finding 1 (R4-D1) — **CONFIRMED as arm (b): S2 unrecorded reject-widening. Arm (c), the S0, is STILL UNVERIFIED.**

```
--- sprintbase main ---  check: 0   run: 0  out=[m1-int-left]   build: 0   exe: 0  out=[m1-int-left]
                         (warning only: "Overlapping impls of Lab (defined in m1 and m2)…")
--- predrain   main ---  check: 0   run: 0  out=[m1-int-left]   build: 0   exe: 0  out=[m1-int-left]
--- branch     main ---  check: 1   "Ambiguous instance for `Lab`. The goal `Lab (Pair Int Bool)`
                                     matches `impl Lab (Pair Int b)` and `impl Lab (Pair a Bool)`…"
--- ALL THREE arms, control (import order swapped) --- check: 1, same ambiguity error
```

**R4's table row (b) reproduces: a program base ACCEPTED at exit 0 is now REJECTED.** It survives
`predrain` too, so the mover is `b2`/`g`, not `a2`/`a3`.

`control.mdk` is both the fixture-integrity control and the positive control: it rejects on all three
arms, so the fixture really does construct a ⊑-incomparable overlap **and** base is demonstrably
capable of emitting this rejection. The probe can fail in both directions.

**What else could explain it — and it changes the severity.** Base's acceptance was **itself
import-order-dependent** (accepts under one order, rejects under the other) — the #1564 class. The
branch is order-**invariant**. So the new reject is the *correct* answer under DICT C3/C4 and is the
intended drain direction. The finding is therefore **not that the branch is wrong**, but that a real
acceptance regression landed that **no `DEBT.md` row records**, and it sits outside `f`'s enumerated
widening set exactly as R4 said. **S2, not S0.**

**Arm (c) — the silent-head-of-list S0 — STILL UNVERIFIED.** I could not construct a goal that is
⊑-incomparable *and* non-closed at the moment of selection: every variant I could write closed
before `pickMostSpecificEntry` ran and produced the loud reject instead of the silent fallback.
I am recording this as unverified, **not refuted** — the arm R4 flagged as the S0 has not been reached.

---

## Findings 2 + 3 (R6-F1 / R4-D2) — **NOT REPRODUCED.** Graded on the stamped word, not the exit code.

Six arms (base / predrain / branch × main / control), same-spelled `Wrap` in two mutually
non-importing modules through the `requires` (RDict) leg. **All six: exit 0, `w1(int)`** — the
correct answer, derived from the spec before running.

The exit codes are not the grade. The grade:

```
diff bin.sprintbase.main.ll bin.branch.main.ll    ->  exit 0    (BYTE-IDENTICAL)
diff bin.branch.main.ll     bin.branch.control.ll ->  exit 1, 119 lines
```

**The sprint did not move the emitted IR on the discriminating shape.** The rows-vs-distinct-keys
divergence R4/R6 predicted would become newly reachable did not materialise here, so the "introduced"
hypothesis does not hold for this shape and the bite's `pre-existing` comment survives *this* attack.

**Fail-capability of the grader:** the 119-line `main`-vs-`control` diff shows it detects real
differences, and the same two binaries produced opposite verdicts on Finding 1 — they are
demonstrably different compilers, so a byte-identical result is a measurement, not a no-op.

**Separate observation, identical on base and branch, therefore NOT a sprint finding:** the emitter
defines exactly **one** `@mdk_impl_Wrap_tagOf` for the two distinct `Wrap` types. Reading the IR,
w1's and w2's bodies are **merged into one function as fall-through clauses** discriminated by
constructor tag; it returns the right answer only because the two `Wrap` constructors carry different
tags. That is the #1397/#1514 collision class, byte-for-byte unchanged by the sprint.

⚠️ **What I could not run:** R6's D-2 word-vs-symbol grader. `test/bin/core_ir_typed_modules_dump_main`
rejects a `/var/tmp` project root with `unknown module: <dir>` (both fixture dirs, dashed and
undashed). The verdict rests on the byte-identical base-vs-branch IR instead, which answers the
"introduced by the sprint" question more directly than the dump would have.

⚠️ **Scope of the NOT-REPRODUCED:** this clears the shape R4 shipped. I did **not** construct a case
where two rows at one `(iface, head)` share a canonical key on the **module** arm, which is the
population R6-F1 §2 flags as the one that would decide it. The class is not cleared; this program is.

---

## Finding 4 (#1072) — **probe DISCRIMINATES. #1072 genuinely drained. R5's predicted hole NOT REPRODUCED.**

This is the fail-capability the brief asked for, and it came back positive.

```
--- sprintbase 2b9dc798, cross-module --- run: 0  out=[general]   exe: 0  out=[general]   ✗ WRONG
--- predrain   85ceec1f, cross-module --- run: 0  out=[general]   exe: 0  out=[general]   ✗ WRONG
--- branch     fdc0109c, cross-module --- run: 0  out=[DEFAULT]   exe: 0  out=[DEFAULT]   ✓
```

**Mandatory positive control** (R5's own: the same program flattened into ONE file, where
`fillImplDefaults` sees the co-located `DInterface`):

```
--- sprintbase flat --- DEFAULT      --- predrain flat --- DEFAULT      --- branch flat --- DEFAULT
```

The control is `DEFAULT` on **all three** arms while the cross-module fixture is `general` on two of
them — so the lever is the **cross-module axis**, exactly as R5 required, and not the program shape.

**The probe can fail, it did fail pre-drain, and the drain is what fixed it.** `predrain` is the
immediate parent of `1e7cbbbb` and still prints `general`, which localises the fix to `b2`/`g`.
R5's derived hole — that an impl inheriting a default keeps `ms` empty, so the method-keyed count
stays 1 and a bare head is stamped — **does not reproduce on the branch**. #1072's inherited-default
variant is genuinely drained; the earlier green was not vacuous after all.

R5's separate `None`-arm / headless-goal residual is untouched by this probe and remains open.

---

## What I refused

- I never offered engine agreement as evidence. Every verdict rests on a base-vs-branch differential
  or a hand-derived correct answer, per #1071/#1062/#1047.
- I refused to grade Findings 2/3 on exit codes — all six arms exit 0 and print the right value, and
  that fact alone would have been the wrong question.
- I refused to mark Finding 1's arm (c) refuted merely because I could not reach it.
- I did not run R4's D3 (perf axis) or D4 (corpus differential) — outside the six findings assigned,
  and D4 in particular is a real gap that someone should still run.
- No commits, no edits to `compiler/`, `test/`, or any ledger `.md`. One file written: this one.
  Two scratch worktrees left at `scratchpad/{predrain,sprintbase}` — reap when the round closes.
