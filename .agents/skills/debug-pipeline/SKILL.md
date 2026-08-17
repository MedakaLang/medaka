---
name: debug-pipeline
description: Diagnose a Medaka parse, resolve, typecheck, or eval failure — isolate which pipeline stage is at fault using the entry probes, the diagnostics accumulator, and the Core IR / --keep-ir dumps. Use when a .mdk program errors unexpectedly or returns a wrong value, when dispatch picks the wrong impl or a dict routes wrongly, when the engines disagree (eval vs native vs wasm), when a test fails opaquely, or when you are setting up a two-arm (old-binary vs new-binary) differential.
---

# Debug a pipeline failure

The goal is to find the *first* stage that misbehaves, then read its source.
Errors don't abort on first failure — they accumulate in
`compiler/driver/diagnostics.mdk`, so a later-stage message may be downstream of
an earlier real cause.

**The real execution order** (driven by `compiler/driver/medaka_cli.mdk`):

```
lexer → parser → desugar → resolve → marker → typecheck → eval
```

Two facts that decide *where a bug can possibly live* — get these wrong and you
will bisect in the wrong half of the compiler:

- **`desugar` runs FIRST**, before resolve/typecheck — not last. So the surface
  sugar nodes (`EGuards`, `ESection`, `EStringInterp`, `EDo`)
  are **already lowered to core** by the time resolve/typecheck/eval see the tree.
  A misbehaviour that needs the *sugar shape* to explain it is a `desugar.mdk` bug,
  and it cannot be downstream of typecheck.
- **`exhaust` is NOT a stage in the chain.** `compiler/frontend/exhaust.mdk` is
  called *from inside* `compiler/types/typecheck.mdk` — once per `EMatch`, with the
  scrutinee type known (`checkMatchExhaustive` / `checkMatchRedundant`,
  `typecheck.mdk:5841` / `:5862`). (The one exception is
  `checkGuardExhaustiveness` (`exhaust.mdk:835`), a standalone pass on the RAW
  pre-desugar AST.)
- **`marker` (`compiler/frontend/marker.mdk`) runs between resolve and typecheck**
  and is where interface-method `EVar`s become `EMethodRef`/`EDictApp`. It owns the
  most common bug class this skill exists for — **dispatch**.

## Isolate the stage

Build first: `make medaka`. The primary loop is a scratch `.mdk` file plus the
CLI, which reads real files and reports full accumulated diagnostics:

```sh
./medaka check scratch.mdk          # front end only (no eval)
./medaka check --json scratch.mdk   # ← REACH FOR THIS. One JSON object per diagnostic,
                                    #   carrying a STABLE `code` (T-* type · R-* resolve ·
                                    #   P-* parse · L-* lex · W-* warning), `kind`, a real
                                    #   `range`, `severity`, `message`, and — where the
                                    #   compiler can offer one — `help` + a machine-applicable
                                    #   `fix { range, replacement }`.
./medaka run   scratch.mdk          # full pipeline incl. eval
```

⚠️ **Make sure you're not debugging a stale binary.** Every `./medaka` invocation
checks a build-time source fingerprint against the live `<root>/compiler/*.mdk`
and WARNS on mismatch by default — `MEDAKA_STRICT=1` promotes that to a hard
`exit 1`. Set it whenever you need certainty that the fix you just made (or the
bug you're chasing) is actually in the binary you're running.

The `code` prefix tells you which stage owns the failure before you read a line of
source. Key off `code`, not the wording — it is the stable handle.

Reason about which stage owns the failure:

- **Parse** (`P-*` / `L-*`) — error with file/line/col (structured `ParseError` from
  `compiler/driver/loader.mdk`) → bug in `compiler/frontend/lexer.mdk` or
  `compiler/frontend/parser.mdk`.
- **Resolve/Typecheck** (`R-*` / `T-*` / `W-*`) — unbound name, type mismatch, or
  non-exhaustive-match warning → `compiler/frontend/resolve.mdk`,
  `compiler/types/typecheck.mdk`, `compiler/frontend/exhaust.mdk`. Errors are
  collected by `compiler/driver/diagnostics.mdk` (no exit-on-error), so a later
  message can be downstream of an earlier real cause — **fix the first one.**
- **Wrong value at runtime** — do NOT jump straight to `compiler/eval/eval.mdk`.
  See "Is it a run≠build miscompile?" below: there are **three** engines and eval is
  only one of them.

## Is it a run≠build miscompile?

Medaka has **three implementations of its own semantics** — the tree-walking
interpreter (`medaka run`), the LLVM backend (`medaka build`), and the WasmGC
backend. A "wrong value" bug may be in any of them, and the repo has a whole
category of bugs where `run` was right and `build` was wrong (or vice versa).

**First: does the bug survive the change of engine?**

```sh
sh test/diff_compiler_engines.sh   # eval == native == wasm on the same programs
                                   # known-divergence ledger: test/engine_divergence.txt
```

- Same wrong answer in all three → a **front-end / semantics** bug (desugar,
  resolve, marker, typecheck).
- `run` right, `build` wrong → an **emitter** bug
  (`compiler/backend/llvm_emit.mdk`, or the Core IR lowering in
  `compiler/ir/core_ir_lower.mdk`).
- ⚠️ **`medaka build` shells out to `./medaka_emitter`.** A fix you just made to
  the emitter is **not in the binary you just ran** unless you rebuild it:
  `FORCE_EMITTER_REBUILD=1 make medaka`. This trap has cost agents entire sessions.

## Entry probes — raw AST / type dumps

For internals the CLI doesn't print, use the entry probes in
`compiler/entries/`. These are standalone `.mdk` programs built into the
`./medaka` binary; run them with `./medaka run compiler/entries/<probe>.mdk`:

- `compiler/entries/parse_main.mdk` — dump the parsed AST for a file
- `compiler/entries/resolve_main.mdk` — dump resolved names
- `compiler/entries/typecheck_main.mdk` — dump inferred types
- `compiler/entries/eval_typed_main.mdk` — the **single-file** typed eval path
- `compiler/entries/eval_modules_main.mdk` — the **multi-module loader** path
- `compiler/entries/eval_main.mdk` — untyped single-file eval

These probes read the target file path as their argument — check each entry's
`main` for the exact invocation form.

## Who actually uses this binder?

`grep` matches text, not bindings — it can't tell a shadowed local from the
top-level of the same name, or follow an `as`-alias/re-export back to its origin.
`compiler/tools/refindex.mdk` (driven by `compiler/entries/refindex_main.mdk`)
resolves def/use through the same binder keys the resolver uses, so it separates
same-name-different-scope locals and collapses alias spellings to one binder:

```sh
medaka run compiler/entries/refindex_main.mdk --dump <runtime.mdk> <core.mdk> <entry.mdk> [root ...]
```

Reach for this over `grep` before renaming or removing a helper you suspect is
dead — it names every real use site of that exact binder, not every line that
happens to contain its spelling.

## The signature bug shape: loader-only dispatch failures

**A dispatch bug that reproduces through the loader but is a green single-file run
is *usually* the eval driver, not dict-passing.** The loader's `evalModules` uses
per-module frames and a separate prelude/install order, so binding-order and
impl-install-order bugs surface *only* there.

**Run BOTH probes on the same input and diff:**

```sh
./medaka run compiler/entries/eval_modules_main.mdk   # loader path      (evalModules)
./medaka run compiler/entries/eval_typed_main.mdk     # single-file path
```

Identical input, but only the modules path errors ⇒ the eval driver
(`compiler/eval/eval.mdk`). One probe drives one path — you need both.

⚠️ **But VERIFY; this heuristic has a documented exception.** Phase 134 was
loader-only *and* dict-passing, and the two-probe comparison did **not** flag it —
both probes behaved identically. **"No divergence" does NOT exonerate
dict-passing.** The printer also renders `EDictApp`/`EMethodRef` transparently as
the bare name, so a dict-passed dump *looks* clean. When the comparison comes back
clean and the bug is still there, instrument eval's `EVar`/`EMethodRef`/`EDictApp`
arms and see how the name *actually* resolves. (Full counterexample:
`.claude/dossier/traps.md`, [T-DISPATCH-LOADER].)

Because single-file masks these, **the regression test must exercise the
multi-module path** (`test/diff_compiler_eval_modules.sh`), not a single-file
doctest.

## Build a minimal repro

Shrink the failing program to the smallest snippet that still reproduces. Once
fixed, add it as a regression fixture in the matching gate. Fixtures are
**per-stage** — `test/parse_fixtures/`, `test/llvm_fixtures/`,
`test/eval_modules_fixtures/`, `test/fmt_fixtures/`, `test/wasm/fixtures/`, … —
there is no generic `test/fixtures/`.

⚠️ **A fixture directory is a SHARED CORPUS.** Adding one silently enrols you in
gates you never named. Before you add a file, find every consumer and run them all:

```sh
grep -rl '<fixture_dir>' test/
```

e.g. `test/eval_modules_fixtures/` feeds **both** `diff_compiler_eval_modules.sh`
**and** `diff_compiler_core_ir_modules.sh`; `test/wasm/fixtures/` feeds **four**
consumers. Capture the golden with `CAPTURE=1` on the specific gate.

## Probe and flag catalogue

Moved here from `AGENTS.md` — none of it is reachable until you are already
debugging. `AGENTS.md` keeps the ones whose failure mode is a right-looking wrong
answer ([D-JSON-HOLE], [D-BUILD-PIPE], [D-TWO-ARM-STDLIB], [D-RUN-VS-BUILD],
[D-GATE-OVERRIDE]).

**Incident narrative for every `[D-*]` item below: `.claude/dossier/tooling.md`.**
Come to it when you want to know why a rule is shaped the way it is — what went
wrong, and which previously-confident sentence turned out to be false.

**[D-CHECK-JSON]** `medaka check --json <file>` emits `Diag` JSON: `code`
(`T-*`/`R-*`/`P-*`/`L-*`/`W-*`), `kind`, `range`, `severity`, `message`, `help`/`fix`. **Key off
`code`.** `run --json`/`lint --json` share it.

**[D-TYPES-FLAG]** `--types` restores the full prelude scheme dump (bare `check` shows only
your own bindings).

**[D-CORE-IR-TYPED]** `compiler/entries/core_ir_typed_modules_dump_main.mdk` — the TYPED,
DICT-PASSED Core IR (`$dict` params, routes). **The probe for any dispatch/dict-routing/
`requires` bug — reach for it BEFORE reasoning from source.**
⚠️ **[D-CORE-IR-TRAP] NOT `core_ir_dump_main.mdk`** — prelude-free, typecheck-free, hides
`$dict`/`CDict`/`CMethod`.

**[D-KEEP-IR]** `medaka build --keep-ir <file>` (or `MEDAKA_KEEP_IR=1`) → IR at `<output>.ll`;
prints only the path. **`cat` the `.ll`.** On write failure prints `warning: could not keep IR
at <path>: <err>` and the build still SUCCEEDS — the note is best-effort.
⚠️ `MEDAKA_KEEP_IR=""` correctly reads as **unset** (`envOr` maps `Some ""` to the default) —
the one documented exception to the empty-env-var-reads-as-SET trap.
⚠️ **[D-EMITTER-CLI]** `./medaka_emitter <file>` is NOT how to get IR (CLI:
`<runtime.mdk> <core.mdk> <entry.mdk> [root...]`). Use `medaka build --keep-ir`.

**[D-RUN-VS-BUILD]** `run`/`build` share the typechecker; differ only in engine. **NOT** two
independent observations of resolve/typecheck behavior.

## Two-arm differentials (old binary vs new binary)

⭐ **[D-TWO-ARM] A `medaka` binary resolves emitter + stdlib from `exeDir`**, never cwd, never
the target file's project root. `MEDAKA_EMITTER`/`MEDAKA_ROOT` exported in your shell CROSS the
arms — check first.
```sh
mkdir -p /tmp/alt && cp ./medaka /tmp/alt/
printf 'main = println 12345\n' > /tmp/hello.mdk
/tmp/alt/medaka run /tmp/hello.mdk                    # exit 1: looks in /tmp/alt/stdlib
MEDAKA_ROOT="$PWD" /tmp/alt/medaka run /tmp/hello.mdk # exit 0: 12345
```
⚠️ A cwd containing `stdlib/` does **not** rescue it.

🚨 **[D-TWO-ARM-STDLIB] The differential is UNSOUND when the target is a `stdlib/*` file** —
it manufactures false FINDINGS. ⇒ **Give each arm its own tree or set `MEDAKA_ROOT` per arm.**

🚨 **[D-TWO-ARM-RUNTIME] `medaka build` also needs `runtime/` beside the binary** (only the
FIRST `build` exposes the gap). Derive the mechanism, don't trust this paragraph:
`grep -n 'medaka_rt.c' compiler/driver/build_cmd.mdk` (the `joinPath root` site + the
`clangLink cc rtC …` call). Continuing [D-TWO-ARM]:
```sh
cp ./medaka_emitter /tmp/alt/ && ln -s "$PWD/stdlib" /tmp/alt/stdlib
/tmp/alt/medaka run   /tmp/hello.mdk                   # exit 0: 12345 — looks complete
/tmp/alt/medaka build /tmp/hello.mdk -o /tmp/alt/hello > /tmp/alt/b.log 2>&1; echo "build: $?"
cat /tmp/alt/b.log   # exit 1 — no such file: '/tmp/alt/runtime/medaka_rt.c'
ln -s "$PWD/runtime" /tmp/alt/runtime
/tmp/alt/medaka build /tmp/hello.mdk -o /tmp/alt/hello > /tmp/alt/b.log 2>&1; echo "build: $?"   # 0
```
⚠️ [D-BUILD-PIPE] applies here too — `medaka build`'s exit code does not survive a pipe, so
don't shorten to `| tail`. Redirect to a file, read `$?`, then read the file.

⚠️ Freshness across the two arms is **[B-STRICT-TWO-ARM]** in `AGENTS.md` (which stays
resident) — do not set `MEDAKA_STRICT=1` on both arms.

⚠️ **[D-GATE-OVERRIDE] Not every gate takes a second binary.** **Derive, don't trust a count:**
```sh
grep -rln 'MEDAKA="${MEDAKA:-' test/*.sh
```
⚠️ Run from a script file, not inline (this harness mangles a `${…}` in a quoted inline arg
and returns zero matches). Hardcoded: `test/diff_compiler_shadow_semantics.sh` (**#1431**).
🚨 This paragraph carried a wrong COUNT for months *while citing the command that refutes it* —
a claim shipping its own derivation is only honest if someone ran it.

## Tips

- For LSP-surfaced errors, run `bash test/diff_compiler_lsp.sh` and
  `test/lsp_harness.sh`.
- For multi-module bugs, run `bash test/diff_compiler_check_modules.sh` and
  `bash test/diff_compiler_eval_modules.sh` to isolate the loader path.
- Before blaming the compiler, run `gh issue list --label known-red` — one issue
  per expected-red gate, closed when it goes green again. A red gate is often
  already known and not your bug.
