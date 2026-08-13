# FX-2 — the base-vs-branch behavioural differential

**The instrument this sprint never had.** Every other gate in this round compares the branch against
**committed goldens that this sprint re-cut**. This compares **BASE behaviour against BRANCH
behaviour on the same programs**, with no golden anywhere in the loop.

| arm | commit | binary |
|---|---|---|
| BASE | `2b9dc798` | `scratchpad/sprintbase/medaka` — pre-existing from an earlier bite, **not rebuilt** |
| BRANCH | `2ac5120b` | the trunk worktree's `./medaka` |

**Hygiene, checked before any measurement:**

- `env | grep -i medaka` → `PWD` and `TMPDIR` only. **`MEDAKA_ROOT` and `MEDAKA_EMITTER` are
  unset**, so neither arm's exe-relative root is crossed.
- Both arms are fresh against their own source: `MEDAKA_STRICT=1 <arm>/medaka run hello.mdk` →
  **exit 0, empty stderr** on both. (Strict mode, because a stale binary exits 0 with the
  right-looking answer otherwise.)
- BASE arm's identity read off `/root/medaka/.git/worktrees/sprintbase/HEAD` →
  `2b9dc798fd7459e5cd0f3298bcb645a658a177fe`.
- `diff -rq <base>/stdlib <branch>/stdlib` → **exit 0, no output.** `stdlib/` is byte-identical
  between the arms, which matters for reading §3 below.

What the sprint actually changed, for scale (`git diff --stat 2b9dc798 HEAD -- compiler stdlib runtime`):
`types/typecheck.mdk` **+1902**, `ir/core_ir_lower.mdk` 12, `types/registry.mdk` 7, `eval/eval.mdk` 2,
`seed/emitter.ll.gz`. **`stdlib/` and `runtime/` are untouched.**

---

## 1 — Corpus, and what I excluded

**250 programs**, all run on **both** arms.

| corpus | dirs | entries | channels |
|---|---|---|---|
| `test/must_fail_fixtures/*/` | 100 | 100 | check · run · build · exe |
| `test/llvm_fixtures_modules/*/` | 56 | 56 | check · run · build · exe |
| `test/import_order_fixtures/*/` | 14 | 14 | check · run · build · exe |
| `test/eval_modules_fixtures/*/` | 11 | 11 | check · run · build · exe |
| `stdlib/*.mdk` | — | 29 | check · run · build |
| `sqlite/*.mdk` (top-level programs) | — | 41 | check · run |
| **total** | | **250** | |

Entry rule: files matching `main*.mdk` or `entry*.mdk` at a fixture directory's top level, plus every
top-level `.mdk` in `stdlib/` and `sqlite/`.

**Channels graded per program**, all four, on both arms:

- `check` — **exit code + full normalized diagnostic text** (a superset of the `code`; the text
  carries the code's range and message, and it is what moves when a code moves).
- `run` — exit code + stdout/stderr.
- `build` — exit code + stdout/stderr, **redirected to a file with `$?` read directly.** Never
  piped: `medaka build`'s exit code does not survive a pipe.
- **the built binary** — exit code + stdout.

Build/exe ran on **176** of the 209 fixture+stdlib entries; **33 were skipped because `check` failed
on BOTH arms** (nothing to build, and the check channel already recorded them as agreeing).

**🚨 What I EXCLUDED, and why — stated so a truncation cannot read as coverage:**

- **`compiler/**` — deliberately not swept.** Each file is a whole-compiler compile; the 1335-file
  sweep a prior agent started would have run ~7 hours. **Not run, not claimed.**
- **`sqlite/`'s build + exe channels** — check and run only. The 41 programs are large; build would
  have roughly tripled the leg for a channel the fixture corpora already cover densely.
- **`test/wasm/*` and the wasm arm entirely.** ⚠️ **UNVERIFIED.** No wasm oracle was built and no
  wasm program was run on either arm. Command owed: `sh test/wasm/build_wasm_oracle.sh` then
  `sh test/wasm/diff_wasm_modules.sh`, twice.
- `gzip/`, `mq/`, `demo/`, `playground/`, `byteparser/`, `test/*_fixtures/` families outside the four
  above.

---

## 2 — 🚨 The known-difference control: the instrument is demonstrated fail-capable

**A clean differential is worth nothing unless the harness is shown able to detect a difference.**
It is, and not with a synthetic case — **four programs in the corpus differ, and the harness flagged
every one**, across three different channels:

| control | channel that caught it | base | branch |
|---|---|---|---|
| `must_fail/1564-…` | `check` exit **and** `build` exit **and** exe stdout | reject, exit 1 | exit 0, `wrap(int)` |
| `import_order/evidence-unroutable-invariant` | `check` · `run` · `build` · exe stdout | reject, exit 1 | exit 0, `wrap(int)` |
| `must_fail/1599-…` | **exe stdout only** (build exit 0 on both) | `1003` | `5` |
| `must_fail/1072-…` | **exe stdout only** (check/run/build all exit 0 on both) | `general` | `specific` |

The last two are the important half of the demonstration: **their exit codes are identical on both
arms in every channel.** Had this harness graded exit codes alone — the trap FX-2's own brief warns
about — it would have reported those two as "no difference". It caught them because it diffs the
**built binary's stdout**.

---

## 3 — 🚨 TWO HARNESS ARTIFACTS, both proven symmetric, both discarded

I report these because each first appeared as a large, alarming block of differences, and one of
them is exactly the shape the brief said to flag hardest — *a loud reject on base becoming exit 0 on
branch*. **Both are artifacts of running a binary against another tree's files. Neither is a
compiler difference.**

### (a) The exe-relative internal-extern guard — 15 stdlib "differences", all false

First pass reported `check` **exit 1 on base, exit 0 on branch** for 15 of 29 stdlib modules, with
base emitting *"'arrayGetUnsafe' is an internal-only primitive. Cannot be used outside the standard
library"*. Read naively: the branch stopped enforcing an internal-extern restriction — an S0.

It is not. A binary resolves `MEDAKA_ROOT` from **its own directory**, so the base binary checking
`<branch>/stdlib/array.mdk` sees a file **outside its own stdlib** and correctly rejects. The
cross-check settles it — the failure is **symmetric**:

```
base   on base   stdlib/array.mdk: exit=0
branch on branch stdlib/array.mdk: exit=0
base   on branch stdlib/array.mdk: exit=1
branch on base   stdlib/array.mdk: exit=1   <- branch rejects base's copy just as loudly
cmp <base>/stdlib/array.mdk <branch>/stdlib/array.mdk  ->  IDENTICAL
```

**Re-run correctly** — each arm on its **own** (byte-identical) copy:

```
=== stdlib: total=29 differing=0 ===
```

⚠️ **Anyone else running a two-arm differential in this tree will hit this.** The rule: for files
that live *under a compiler root*, each arm must read its own copy. It does not affect
`test/`-rooted fixtures, which is why the other 180 entries were unaffected.

### (b) The `-o` path in `build`'s own stdout — 148 "differences", all false

`build` prints `built <src> -> <dst>`, and my `-o` target embedded the arm name
(`….base.exe` vs `….branch.exe`). That alone reported **152/176 differing**. Normalizing the arm
token out of the output (no rebuild needed) gives **18**, of which 14 are artifact (a) again — so
**4 real**.

---

## 4 — Every difference, classified

**250 programs · 4 channels · 2 arms. Four real differences. All four INTENDED. Zero UNINTENDED.**

### INTENDED — 1 of 4 · `must_fail/1564-import-order-decides-conditional-impl-candidacy`

A **loud reject on base became exit 0 on branch** — the flagged shape, and here it is the drain.

```
arm=base   entry=main     check=1  run=1  build=1  exe=NOBIN
arm=base   entry=control  check=0  run=0 [wrap(int)]  build=0  exe=0 [wrap(int)]
arm=branch entry=main     check=0  run=0 [wrap(int)]  build=0  exe=0 [wrap(int)]
arm=branch entry=control  check=0  run=0 [wrap(int)]  build=0  exe=0 [wrap(int)]
```

Base's rejection is `T-REQUIRES-UNROUTED` at `nest.mdk:3:16`, whose own message calls itself
*"a compiler limitation, not a missing impl."* **Correct answer derived from the spec, not from the
engines:** DICT §8 I5 — *instance candidacy is graph-global; import scoping filters NAMES, never
instances* — so the conditional `impl Tag (Wrap a) requires Tag a` is a candidate at `nest`'s goal,
`Tag Int` discharges the residual, and the program prints `wrap(int)`. The branch prints exactly
that, **under both import orders**, which is the C4 order-invariance the sprint was for.

⚠️ **This is the FULL drain, not the half-drain the fixture warns about.** `claim.txt` records that
between A-3.6 and Door 4 `check` was already exit 0 while the built binary faulted at 139, and
demands *"Re-run `medaka run main.mdk` and the built binary before closing."* Done, above: `run`,
`build` and the **executed binary** all clean and all printing `wrap(int)`, matching the control.
The `must_fail` row will now flip green and **fail its gate naming #1564** — that is the tracker
self-draining, not a break.

### INTENDED — 2 of 4 · `import_order/evidence-unroutable-invariant`

Base: `check`/`run`/`build` all exit 1, same `T-REQUIRES-UNROUTED`. Branch: exit 0, `wrap(int)`.

**The fixture predicted this in writing, before the sprint ran.** Its own `case.txt`:

> *"It drains when ARCH B-2 moves the reader onto `IE` — at which point every ordering here starts
> printing `wrap(int)`, still invariantly, and this row keeps passing."*

Its stated invariance property is preserved: this graph has **no** accepting order (`wrapimpl`
imports `nest`, so it can never sort earlier), and the branch accepts it under every ordering
rather than under some. The verdict moved from invariantly-reject to invariantly-accept — which is
the drain, not the signature-split the row exists to catch.

### INTENDED — 3 of 4 · `must_fail/1599-reachable-conditional-beats-unreachable-specific`

**Caught on the built binary's stdout alone.** Build exits 0 on both arms.

```
base   run: exit 1  main.mdk:5:26: runtime error [E-NOT-A-FUNCTION]: applied non-function: 5
base   exe: exit 0  1003
branch run: exit 0  5
branch exe: exit 0  5
control (both arms): exe exit 0, prints 5
```

**Correct answer derived independently:** `useIt = show2 (Box T)` is posed in `user.mdk`, which
imports `base` and `gen` but **not** `spec`. Under graph-global candidacy plus most-specific-wins,
`impl Show2 (Box T)` (= `5`) subsumes the conditional `impl Show2 (Box a) requires Show2 a`
(= `1000 + 3` = `1003`), so **`5` is correct** — the fixture's control, which poses the same goal
from a module that *can* name `spec`, prints `5` on both arms and pins that independently.
Branch = `5`. Drained.

⚠️ **Sub-observation, base-arm only:** base's `run` (`E-NOT-A-FUNCTION`) and base's built binary
(`1003`) **disagree with each other** — a pre-existing eval-vs-native divergence on this shape at
`2b9dc798`. It is moot on the branch (both give `5`) and is **not** a branch finding; recorded only
so nobody re-derives it as new.

### INTENDED — 4 of 4 · `must_fail/1072-overlap-xmod-bare-head-arm-order`

**Also caught on exe stdout alone** — `check`, `run` and `build` all exit 0 on **both** arms, and
the two binaries print different words.

```
base   exe: exit 0  general      <- the pinned bug
branch exe: exit 0  specific
control, arm=base:   build=0 exe=0  [specific]
control, arm=branch: build=0 exe=0  [specific]
```

`claim.txt` states the correct answer outright — *"`specific` is correct … `general` is the pinned
bug"* — resting on most-specific-wins being a **feature** (memory: `decided_most_specific_wins_spec`),
not on any engine's opinion. **The control was mandatory here and it holds on both arms**: the
fixture warns that if the control breaks or both files print `general`, the gate must read
CONTROL-BROKE rather than "fixed". It prints `specific` on base and on branch, so the drain is
genuine.

### UNINTENDED — **none.**

Across `must_fail_fixtures` (100), `llvm_fixtures_modules` (56), `import_order_fixtures` (14),
`eval_modules_fixtures` (11), `stdlib` (29) and `sqlite` (41), on `check` + `run` + `build` + built
binary, **every program not listed above is byte-identical between `2b9dc798` and `2ac5120b` in
every graded channel.** In particular:

- **`sqlite/`: 41 programs, 0 differences.** Real multi-module application code, dispatch-heavy,
  entirely unmoved.
- **`llvm_fixtures_modules/`: 56 programs, 0 differences** after artifact (b) — including every
  `ctor_collision_*`, `record_receiver_ident_*`, `method_scope_*` and `iface_*_collision` row, which
  are the corpus closest to what B-2 touched.
- `must_fail_fixtures/1575-self-naming-requires-aborts-compiler` **aborts with exit 134 on both
  arms, identically.** Pre-existing, unchanged, not a difference.

---

## 5 — Part 2: the fourth engine arm (`core_ir_eval`) — **PRE-EXISTING. File, do not fix here.**

**Verdict: BASE IS ALREADY WRONG, identically to BRANCH. This sprint did not break it; it merely
sat next to it.**

The `medaka run compiler/entries/core_ir_modules_main.mdk …` route in R6's recipe **cannot reach
this answer at all** — it dies on **both** arms:

```
core_ir_eval exit=1
  runtime error [E-STACK-OVERFLOW]: recursion too deep (evaluator call depth exceeded 25000);
  the tree-walking interpreter has no tail-call optimisation
```

So I built the probe **natively on each arm from that arm's own compiler source**
(`<arm>/medaka build <arm>/compiler/entries/core_ir_modules_main.mdk`, both exit 0) and ran it.
Correct answers derived from DICT head-matching, **never from engine agreement** (#1071/#1062/#1047):
`speak (Box "s")` → only `Box String` matches → `boxstr`; `speak (Box 1)` → only `Box Int` matches →
`boxint`.

| import order | program | correct | **base** `core_ir_eval` | **branch** `core_ir_eval` | eval | LLVM native |
|---|---|---|---|---|---|---|
| `ints` then `strs` | `speak (Box "s")` | `boxstr` | **`boxint`** ✗ | **`boxint`** ✗ | `boxstr` ✓ | `boxstr` ✓ |
| `ints` then `strs` | `speak (Box 1)` | `boxint` | `boxint` ✓ | `boxint` ✓ | `boxint` ✓ | `boxint` ✓ |
| `strs` then `ints` | `speak (Box "s")` | `boxstr` | `boxstr` ✓ | `boxstr` ✓ | `boxstr` ✓ | — |
| `strs` then `ints` | `speak (Box 1)` | `boxint` | **`boxstr`** ✗ | **`boxstr`** ✗ | `boxint` ✓ | — |

**Base and branch are identical in all four cells.** The sprint moved this arm by exactly zero.

**The mechanism, established rather than asserted.** The brief's reading — *"looks like arg-tag
first-impl-wins"* — is confirmed, and I added the discriminator that proves it rather than inferring
it from one cell. Swapping only the two `import` lines **flips both answers together**: the arm
returns whichever impl the import order puts first and **ignores the receiver type entirely**. That
is why the first table row and the fourth are wrong while rows two and three are right *by luck* —
and it is why a probe that graded only the original two cells could report "wrong on main, right on
the control" and mislead about which way the mechanism runs.

⚠️ **The brief's premise that it was "wrong on the control too" does not reproduce.** In the
`ints`-first order the control prints `boxint`, which is **correct** — correct for the wrong reason,
since the arm would print `boxint` for any receiver. I flag this because that premise, taken at face
value, points at a different mechanism than the one actually present.

**Why this is invisible to CI, restated as measured fact rather than source-reading:** the arm's only
gate runs the **untyped** path, where no `Route` is stamped at all, so it structurally cannot
distinguish a correct route word from no route word. **The gate's green proves nothing in either
direction — the program above is the evidence.** This is F1's finding 5 / R6's F-2, now with a
base-arm measurement attached: **it is a pre-existing defect this sprint revealed, not caused. It
should be FILED, not fixed in this round.**

---

## 6 — What I refused, and what is UNVERIFIED

- **I did not fix anything.** No edits to `compiler/`, `test/`, `stdlib/` or any ledger. **No
  commits.** One file written: this one.
- **I never offered engine agreement as evidence.** Every correct answer above is derived from DICT
  semantics or from a fixture's own independently-pinned control.
- **I refused to report the 15 stdlib rejects and the 148 build-line diffs as findings** — each was
  proven symmetric first. The stdlib one would have been a headline S0 ("branch stopped enforcing
  the internal-extern restriction"); it is a harness artifact and reporting it would have burned
  someone's round.
- **⚠️ UNVERIFIED — the wasm arm.** Not measured on either arm. Owed:
  `sh test/wasm/build_wasm_oracle.sh; sh test/wasm/diff_wasm_modules.sh` on each arm.
- **⚠️ UNVERIFIED — `compiler/**` as a corpus.** ~1335 files, ~7 h. Not run. The
  self-compile fixpoint and `typecheck_compiler_source.sh` are the right instruments for that
  surface and CI owns them.
- **⚠️ UNVERIFIED — `sqlite/` build + built-binary channels** (check and run only).
- **⚠️ UNVERIFIED — permutation.** I ran each fixture in the import order it ships with. I did not
  permute import clauses across the corpus, so an order-dependence that both arms share is
  invisible to this instrument by construction. That is the one class a base-vs-branch differential
  cannot see: **a defect present identically in both arms.** #1575's shared abort and the
  `core_ir_eval` result in §5 are two members of it that I found only because I looked for them
  directly.

---

## 7 — DEBT.md row (handed to the sub-orchestrator — **I did not append it**)

```
### FX-2 — repair/differential — base-vs-branch behavioural differential over 250 programs; 0 unintended differences
sites:        no source touched. One file written:
              .claude/sprint-b/repair/FX2-differential.md
transform:    none — measurement only. BASE 2b9dc798 (pre-existing scratchpad/sprintbase arm,
              not rebuilt) vs BRANCH 2ac5120b, both MEDAKA_STRICT=1 clean, MEDAKA_ROOT/
              MEDAKA_EMITTER unset. 250 programs (must_fail 100, llvm_fixtures_modules 56,
              import_order 14, eval_modules 11, stdlib 29, sqlite 41) x 4 channels
              (check exit+diagnostic text, run, build, BUILT BINARY exit+stdout) x 2 arms.
              This is the check DEBT rows have been recording as "did not run the full corpus
              (CI owns it)" since B-2 landed. It is now run.
could move:   Nothing — no source changed. What the MEASUREMENT moves is the sprint's evidence
              base: the acceptance change is now bounded by observation rather than by argument.
              Exactly 4 programs differ between the arms, all INTENDED, each independently
              adjudicated against DICT semantics (never against engine agreement) and each with
              its fixture's own control re-run on BOTH arms and holding:
                #1564  reject exit 1 -> exit 0 wrap(int); FULL drain incl. built binary
                       (claim.txt demands this: check-only was previously a half-drain at 139)
                evidence-unroutable-invariant  same drain; its case.txt predicted it verbatim
                #1599  built binary 1003 -> 5   (build exits 0 on BOTH arms)
                #1072  built binary general -> specific  (check/run/build exit 0 on BOTH arms)
              The last two are invisible to every exit code in the tree.
nearest miss: **The class this instrument CANNOT see: a defect present identically in BOTH arms.**
              A differential subtracts it out by construction. I found two members only by
              looking directly: (1) `core_ir_eval` is wrong on both arms (see engines:), and
              (2) must_fail/1575 aborts exit 134 on both arms. Nearest UNCOVERED program:
              any import-clause PERMUTATION of a corpus fixture — I ran each fixture in the
              order it ships with and did not permute, so a shared order-dependence is outside
              this instrument. `diff_compiler_import_order.sh` is the gate that owns that axis.
              Second nearest: `compiler/**` as a corpus (~1335 files, ~7 h) — NOT RUN; the
              fixpoint + typecheck_compiler_source.sh are the right instruments and CI owns them.
engines:      * eval / LLVM native — BOTH measured on both arms across all 250 programs. Agree
                everywhere except the 4 intended rows. ⚠️ Not offered as corroboration of each
                other; each row's correct answer was derived from the spec first.
              * wasm — ⚠️ NOT MEASURED on either arm. Owed: build_wasm_oracle.sh +
                diff_wasm_modules.sh, twice. This is the one engine this round did not observe.
              * core_ir_eval (fourth arm) — MEASURED on both arms, natively (the `medaka run`
                route dies E-STACK-OVERFLOW at depth 25000 on BOTH arms, so R6's recipe cannot
                reach it). VERDICT: **PRE-EXISTING, NOT OURS.** Identical in all 4 cells on
                base and branch. Mechanism established, not inferred: swapping the two import
                lines flips BOTH answers, so it selects by import order and ignores the
                receiver type. FILE IT; do not fix in this round. ⚠️ The brief's premise that
                it was "wrong on the control too" does NOT reproduce — the control is right
                (for the wrong reason), which points at a different mechanism if taken at face.
unchecked:    * wasm (above). * compiler/** corpus (above). * import-clause permutation (above).
              * sqlite build + built-binary channels — check/run only for those 41.
              * ⚠️ TWO HARNESS ARTIFACTS were found and DISCARDED, both proven symmetric; anyone
                repeating a two-arm differential will hit them: (a) the internal-extern guard is
                exe-root-relative, so a base binary checking BRANCH's stdlib rejects 15 modules
                at exit 1 — this reads exactly like "the branch stopped enforcing an S0 guard"
                and is not (branch rejects base's byte-identical copy just as loudly; re-run
                per-arm: 29/29 clean). (b) `build`'s own `built X -> Y` line embeds the -o path,
                which carried the arm name: 152/176 "differing" collapsed to 18, then to 4.
```
