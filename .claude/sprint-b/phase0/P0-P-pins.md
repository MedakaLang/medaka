# P0-P — the three unpinned drains (#1071, #1068, #1075)

**Agent:** P0-P (Phase 0, Stage B sprint). **Tree:** `arch/stage-b-sprint`, BASE `2b9dc798`.
**Binary:** the pre-built `/root/medaka/.claude/worktrees/giggly-tinkering-rainbow/medaka` —
**not rebuilt, no `make` run, no golden blessed, no compiler source touched.**
**Date of every measurement below:** 2026-08-13.

Every exit code below was taken by redirecting to a file and reading `$?`. **No pipes** —
`medaka run x.mdk 2>&1 | tail` reports `tail`'s status and would have made a failing program
read as exit 0.

## Verdict table

| issue | verdict | where it lands |
|---|---|---|
| **#1071** | **PINNED, observed RED (row reads `REPRO`), proven fail-capable** | `test/must_fail_fixtures/1071-eval-inherited-default-sibling-calls-typearg/` |
| **#1068** | **NOT PINNABLE in this harness** — wasm-only, no wasm verb exists; already covered by a self-draining ledger | `test/MUST-FAIL-NOT-PINNABLE.txt` entry `1068` |
| **#1075** | **NOT PINNABLE — the filed observable does not exist on this tree** (conditional on unmerged PR #1074); pinning either candidate observable would be a false drain | `test/MUST-FAIL-NOT-PINNABLE.txt` entry `1075`, labelled OUT OF SCOPE for Stage B |

## Files written

Only these. Nothing else was created or edited.

- `test/must_fail_fixtures/1071-eval-inherited-default-sibling-calls-typearg/{claim.txt,dface.mdk,main.mdk,control.mdk}` (new)
- `test/MUST-FAIL-NOT-PINNABLE.txt` — two appended entries (`1068`, `1075`). ⚠️ **This file is
  outside the `test/must_fail_fixtures/` scope my brief named**; the brief authorized it
  explicitly ("the honest deliverable is a `MUST-FAIL-NOT-PINNABLE.txt` entry with a reason"),
  but flagging it so the single writer of history sees it in the diff on purpose.
- this report.

`git status --short` at hand-off shows exactly: `M test/MUST-FAIL-NOT-PINNABLE.txt` and
`?? test/must_fail_fixtures/1071-…/` (plus two `.claude/sprint-b/phase0/*.md` files owned by
other Phase 0 agents, which I did not touch).

---

## #1071 — PINNED and RED

**Fixture:** `test/must_fail_fixtures/1071-eval-inherited-default-sibling-calls-typearg/`
**Row name:** `1071-eval-inherited-default-sibling-calls-typearg`
**Pin:** `cmd: run main.mdk` · `exit: 0` · `stdout: int/31` / `stdout: int/31`
**Control:** `run control.mdk` (second impl moved to a **different head tycon**, `Bag String`)

### The RED witness, first-hand

Command (a scratch script; cwd resets between calls, so absolute paths throughout):

```sh
W=/root/medaka/.claude/worktrees/giggly-tinkering-rainbow
F=$W/test/must_fail_fixtures/1071-eval-inherited-default-sibling-calls-typearg
"$W/medaka" check "$F/main.mdk"    > c1 2>&1;      echo "exit: $?"
"$W/medaka" run   "$F/main.mdk"    > r1 2>r1e;     echo "exit: $?"
"$W/medaka" check "$F/control.mdk" > c2 2>&1;      echo "exit: $?"
"$W/medaka" run   "$F/control.mdk" > r2 2>r2e;     echo "exit: $?"
"$W/medaka" build "$F/main.mdk" -o m.bin > mb 2>&1; echo "build exit: $?"
./m.bin > mo 2>&1;                                 echo "BIN exit: $?"
```

Actual output:

```
=== check main.mdk
  exit: 0
useD : Described a => a -> String
main : Unit
=== run main.mdk  (THE PIN)
  exit: 0
  stdout: [int/31
int/31]
  stderr: []
=== check control.mdk
  exit: 0
useD : Described a => a -> String
main : Unit
=== run control.mdk  (THE CONTROL)
  exit: 0
  stdout: [int/31
str/71]
  stderr: []
=== native build-run main.mdk (recorded under what:, NOT pinned)
  build exit: 0
  BIN exit: 0
  bin stdout: [int/31
str/71]
```

So on the same program: **eval prints `int/31` twice; native prints `int/31` then `str/71`.**
That is the eval-vs-native discrimination the brief asked for, and it is measured, not inferred.

### The row reads REPRO, not DRAINED and not a skip

```
$ sh test/diff_compiler_must_fail.sh > mf3.log 2>&1; echo "SUITE EXIT: $?"
SUITE EXIT: 0
$ grep -n '1071\|^checked' mf3.log
16:REPRO      1071-eval-inherited-default-sibling-calls-typearg (#1071: pin still reproduces — issue OPEN/CLOSED not checked here; see must_fail_census.sh)
105:checked 100 fixtures: 100 still reproduce, 0 DRAINED, 0 control-broke, 0 malformed
```

100 fixtures, 0 malformed, 0 control-broke — so the new row is well-formed, its control is
green, and the two new `MUST-FAIL-NOT-PINNABLE.txt` entries parse (the gate's tree-side ledger
drain iterates every line and printed no `MALFORMED`).

### Proven FAIL-CAPABLE (a passing probe is not a pin)

A pin that reads REPRO proves the bug reproduces; it does **not** prove the row would notice a
fix. So I temporarily changed the claim's second `stdout:` line to the CORRECT value `str/71`
and re-ran the suite:

```
SUITE EXIT: 1
16:DRAINED    1071-eval-inherited-default-sibling-calls-typearg (issue #1071)
18:  ✅ ISSUE #1071 APPEARS FIXED — this is a GOOD failure, probably not your bug.
42:     stdout: expected [int/31|str/71|] got [int/31|int/31|]
44:     Its CONTROL still passes, so this is a real fix, not a broken environment.
46:       1. gh issue close 1071 --comment "fixed by <sha>; must-fail fixture drained"
```

Reverted immediately; the third suite run above (`SUITE EXIT: 0`, `REPRO`) is the committed
state. **The row will go RED the moment eval's second line becomes `str/71`.**

### How the correct answer was derived — from DICT-SEMANTICS, not from an engine

Written into `main.mdk`'s own header comment and `claim.txt`'s `why-expected:`, because
**eval is a known-wrong oracle on exactly this shape** (that is the entire content of #1071):

A method call's evidence is the instance selected for the receiver's **full applied type**, not
its head tycon. `useD (Box "v")` discharges `Described (Box String)`, so the dict forwarded into
`describe` is `Box String`'s, and a sibling call inside the default body must read **its own
dict's** slots — `tagOf` = `"str"`, `sizeOf` = `7`. Hence line 2 is
`"str" ++ "/" ++ intToString (7 * 10 + 1)` = **`str/71`**, and line 1 is **`int/31`**
(`3 * 10 + 1`) by the same rule. The native backend independently produces exactly that pair,
which **corroborates** the derivation rather than being its source.

The pin's discriminating power, stated: `int/…` vs `str/…` reports where `tagOf` went;
`…/31` vs `…/71` reports where `sizeOf` went, **through arithmetic**. A fix that re-narrowed
only the String-returning sibling would leave `int/71` or `str/31`, neither of which satisfies
the row. `str/71` twice — the same defect with impl order reversed — also fails rather than
passes.

### ⚠️ FINDING THE ORCHESTRATOR MUST SEE: #1071 may be a DUPLICATE of #1062, and #1071's stated discriminator is FALSE

This is the one thing in this report that changes a decision, so it is here and in the
fixture's `why-note:` rather than only in a summary.

`test/must_fail_fixtures/1062-eval-sibling-call-in-default-head-collision/` already pins what
looks like the same interpreter defect: an inherited default body's sibling call not re-narrowed
by the canonical impl key at a head tycon shared by two impls differing only in their type
argument. #1062's shape is `loud x = "<" ++ speak x ++ ">"` with both impls overriding `speak`;
#1071's is `describe x = tagOf x ++ "/" ++ intToString (sizeOf x * 10 + 1)` with both impls
overriding `tagOf`/`sizeOf`. Structurally the same.

#1071's body claims a discriminator: *"A default body with only ONE sibling call did not
reproduce for me… anyone attempting to confirm or refute this should use the exact body — a
passing single-call probe is not a refutation."* **That claim is false on this tree.** MEASURED:
the same two-impl program with the default reduced to `describe x = tagOf x` reproduces
identically —

```
=========== ONE sibling call (describe x = tagOf x) ===========
  run exit: 0
  stdout: [int
int]
  build exit: 0
  BIN exit: 0
  bin stdout: [int
str]
```

so the **sibling-call count is not the trigger**, and #1071 and #1062 are plausibly one bug.

**Why I pinned it anyway rather than resolving it:** #1071 is an open drain target of this
sprint and an unpinned drain claim is unfalsifiable — that is the deliverable I was given. But
the suite's own header is explicit that two rows for one bug is a real defect (both drain, the
fixer deletes the one the message names, the second reads as an unexplained failure), and the
harness's uniqueness check keys on the `issue:` field so it **cannot** see this. So:

- the hazard is written into `claim.txt`'s `why-note:` in full, with the one-call measurement;
- **recommendation for the orchestrator / repair round:** if #1071 is adjudicated a duplicate of
  #1062, close #1071 and `git rm -r` this directory — do **not** hunt for a second fix, and do
  **not** read a simultaneous drain of both rows as two separate fixes.

I did **not** close, merge, or relabel anything. That adjudication is not mine to make.

### Sprint routing

Expected to drain at **B-2.4** (`eval.mdk`'s mirrored dispatch). #1071 also records a corpus
consequence worth carrying forward: `test/llvm_fixtures_modules/` goldens are captured **from
eval**, so the shared-head + non-constant-default axis is deliberately unpinned there
(PR #1058 routed around it at distinct head tycons). Whoever fixes this should add that axis to
`test/llvm_fixtures_modules/typearg_inherited_default_dispatch/` in the same PR — and per the
sprint's blessing freeze, that is repair-round work, not in-run.

---

## #1068 — NOT PINNABLE in this harness (wasm); ledgered instead

**Ledger entry:** `test/MUST-FAIL-NOT-PINNABLE.txt`, line beginning `1068`.

### What running the wasm arm actually requires here — derived, not assumed

The brief asked me to confirm this before asserting anything.

- **There is no `test/bin/` directory in this worktree at all** (`ls test/bin/` →
  `No such file or directory`), so **no oracle is built** — including
  `test/bin/wasm_emit_modules_main`, the binary the wasm arm reads.
- Building it means `sh test/wasm/build_wasm_oracle.sh --modules-only`, which compiles
  `compiler/entries/wasm_emit_modules_main.mdk` through `medaka build`
  (`test/wasm/build_wasm_oracle.sh` header: *"the MULTI-MODULE entry. Gates:
  test/wasm/diff_wasm_modules.sh, test/wasm/diff_sqlite.sh, test/build_wasm_cmd.sh, and (the
  only one it needs) test/diff_compiler_engines.sh:144"*). Toolchain is present here
  (`clang`, `node`, `wasm-tools` all on PATH), so it is buildable in principle.
- **I did not build it.** It writes new artifacts into `test/bin/` in a worktree where five
  other agents are live and quiescence is the sprint's non-negotiable protocol, and — see next
  — the result would not have changed the verdict.

### Why it is moot: the harness has no wasm engine

`run_verb` (`test/diff_compiler_must_fail.sh`) offers exactly
`check` / `check-json` / `check-types` / `run` / `build` / `build-run` / `fmt-write` /
`mcp-call`. Every one drives the interpreter or the LLVM/native path; **none reaches a wasm
engine**, so the diverging arm is unreachable from any verb — the same structural gap the
ledger already records for #1349, #1130, #1316.

And on the LLVM/native side the compiler is **correct** on these programs (eval and native both
produce the right output, per #1068's own two WAT-verified rows). So any pin this harness
*could* write would assert behaviour that is already right — the opposite of what the suite is
for.

### Where it IS covered, and that coverage self-drains

`test/engine_divergence.txt` carries **two** rows naming #1068, both with verdicts verified
from the emitted WAT rather than inferred:

- `llvmM/typearg_inherited_default_dispatch` — **shape A** (a sibling *inherits* the default),
  jointly ledgered with #1020; wasm traps with **EMPTY stdout**.
- `llvmM/module_local_route_word` — **shape B** (both siblings *override*, no default involved
  at all); wasm prints a **first correct line** (`boxint`) and *then* traps.

That partial-output asymmetry is the discriminator between the two shapes and is exactly the
"one variant emits a partial correct line first" the brief told me to be precise about: **shape
A is empty-stdout, shape B is partial-then-trap.** A crash-only assertion would miss half the
issue — and note this also means shape B **cannot** be explained by #1020.

The ledger is self-draining in the strong direction: a ledgered divergence that starts passing
prints `PROMOTE` and is a **HARD FAIL** — `test/diff_compiler_engines.sh`: *"A known-failure
entry started PASSING. That is good news and a HARD FAIL: the ledger must be promoted, or the
fix will silently rot back later."* Verified by reading the gate, not assumed.

### Owed / not witnessed

**I did not witness #1068 RED first-hand**, and I am saying so plainly rather than restating the
issue's numbers as if I had measured them. The WAT word values in the issue body and in the two
ledger rows (`601874966` vs `193452654`; `193452654` vs `20598550`/`580753986`) are **quoted, not
re-derived by me.** Re-deriving them needs the wasm oracle built and `node run.js` over the two
fixtures. **Owed to whoever lands B-2.4:** build the modules-only wasm oracle and re-measure both
shapes before and after, since the deferred `diff_compiler_engines` run is the only gate that
will notice, and it is deferred to the repair round.

---

## #1075 — NOT PINNABLE: the filed observable does not exist on this tree

**Ledger entry:** `test/MUST-FAIL-NOT-PINNABLE.txt`, line beginning `1075`, explicitly labelled
**OUT OF SCOPE for Stage B**.

### Measured, first-hand, on the current binary

I built the issue's own 2-file repro verbatim (`impl Speak Int` method-less at a **primitive**
head, `impl Speak Cat` overriding, reached through a local lambda `f = v => speak v`) plus two
candidate controls, and swept `check` / `run` / `build` / the built binary:

```
################ main.mdk        (the issue's repro: method-less impl at PRIMITIVE head)
  check exit: 0
  run   exit: 0
  run stdout: [woof|meow]
  build exit: 0
  BIN   exit: 0
  bin stdout: [meow|meow]        <-- SILENTLY WRONG, exit 0
  bin stderr: []
################ ctlA.mdk        (same, but method-less impl at an ADT head: Dog)
  check exit: 0
  run   exit: 0
  run stdout: [woof|meow]
  build exit: 0
  BIN   exit: 0
  bin stdout: [meow|meow]
  bin stderr: []
################ ctlB.mdk        (primitive head, but the impl DEFINES speak)
  check exit: 0
  run   exit: 0
  run stdout: [woof|meow]
  build exit: 1
  no binary; build log:
error: emitter failed compiling …/ctlB.mdk
runtime error [E-PANIC]: arg-tag dispatch on impl type that owns no constructors (primitive receiver carries no cell tag)
```

**#1075's claimed observable — a coded `[E-PANIC] … no impl arm` abort at exit 1 from the built
binary — does not occur.** The repro instead produces `meow|meow` at exit 0: the **pre-existing
#1046 mechanism**, already pinned at `test/must_fail_fixtures/1046-methodless-impl-argtag-dispatch/`
(that row reads `REPRO` in the run above). The reason is stated in #1075's own body: it was
measured on a binary built from **PR #1074's branch**, and PR #1074 is not in this tree.

### Why both candidate pins would be wrong

- Pinning `exit 1` + the E-PANIC: **red today for a reason that is not a fix**, and it would flip
  the moment #1074 merely made #1075 *reachable* — a drain message telling someone to close a bug
  that had just become live. A false drain closing a live S1.
- Pinning `meow|meow` / exit 0: **duplicates #1046's row** under a second issue number. One fix
  drains two rows and the second reads as an unexplained failure — the exact defect the suite's
  one-fixture-per-issue section describes.

### Corroboration, and what it says about the gap the sprint doc noticed

I reached this independently and *then* found commit `17f3c185`
(*"test(must-fail): pin #1034, #1169, #1174, #1369; **#1075 and #1162 do not reproduce**"*),
whose reasoning matches mine line for line. **It recorded that reasoning only in a commit
message**, which is why the sprint doc could correctly observe #1075 had "no must-fail pin" with
nothing in the tree explaining why. The ledger line I added puts it where the census
(`test/must_fail_census.sh`) and the next agent can see it.

### Out-of-scope label, as instructed

The ledger entry says so in words: the design doc routes **#1075 with #1046 to unit F-1** (their
sites reach dispatch through a **local lambda**, so arg-tag survives there until locals carry
evidence). Therefore **a still-unpinned or still-broken #1075 is NOT a Stage B failure**, and a
Stage B PR that claims to drain it has done something out of scope. The line also names the
condition for deleting itself: *"Delete this line and pin #1075 as a `build-run` row (exit 1,
empty stdout) once #1074 or an equivalent primitive-head fix lands and the claimed observable
becomes real."*

### One incidental observation, reported and NOT filed

`ctlB.mdk` above — a primitive head where the impl **defines** the method — makes the **emitter
itself** E-PANIC at build time with `arg-tag dispatch on impl type that owns no constructors`,
i.e. `medaka build` exits 1 on a program `check` and `run` both accept. That is the same
primitive-no-cell-tag limitation #1075 describes, surfacing loudly at a *different* trigger. I
have **not** searched the tracker for an existing issue and I am **not** filing it: filing an
unreproduced-against-the-backlog claim is the failure mode this repo has documented repeatedly,
and it is outside my brief. Recording it here so the orchestrator can route it (`ws:emitter`,
S1-shaped) if a dedup search comes back empty.

---

## What I refused / did not do

- **Did not rebuild.** No `make`, no `refresh_seed.sh`, no oracle build, no golden blessed. The
  pre-built binary was used as-is.
- **Did not touch compiler source.** `git status --short` confirms.
- **Did not commit.** The single writer of history owns that.
- **Did not build the wasm oracle** (see #1068 above) — it would not have changed the verdict and
  it writes artifacts into a worktree under a quiescence protocol.
- **Did not force a pin for #1068 or #1075.** Both refusals are ledgered with a reason that names
  the shape, per the suite's rule that a reason which does not survive being read aloud is not a
  reason.
- **Did not resolve the #1071/#1062 duplicate question.** Flagged for adjudication instead.
