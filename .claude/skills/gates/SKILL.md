---
name: gates
description: The Medaka differential gate suite — what each gate proves when one goes red, and how to author a new one (fixture, golden capture, and the dash-not-bash shell half). Use when a gate, shard, or CI job fails or goes unexpectedly green — preflight, soundness, must-fail, selfcompile fixpoint, engines, perf-scaling, capability-matrix, bootstrap, snapshot, oracle staleness — and when adding or changing a test/diff_compiler_*.sh gate, a fixture corpus, or a regression test, or before capturing or blessing any golden.
---

# The gate suite: triage a red one, author a new one

`AGENTS.md` keeps the loop (`make preflight`) and the four traps whose violation is
**silent**. This skill carries the reference table and the authoring procedure — the
parts you only need once you are already looking at a specific gate.

**Before diagnosing a red gate, check whether it is already known-red:**

```sh
gh issue list --label known-red
```

One issue per expected-red gate, closed when the gate is green again. It is usually
not your break.

The invocations (`make preflight`, `make gates`, `sh test/run_gates.sh 'pat*'`, the doc-rot
targets) are in `AGENTS.md` § The gates, which is loaded alongside this skill — they are
deliberately NOT repeated here, so there is only one copy to drift.

## What each gate proves

**[G-LIST]**

| Gate | What it proves |
|------|----------------|
| `test/diff_compiler_*.sh` | Differential: native stage output vs captured goldens |
| `test/selfcompile_fixpoint.sh` | Self-compile fixpoint (C3a/C3b) — decisive gate for compiler-source changes |
| `test/typecheck_compiler_source.sh` | Strict-typechecks WHOLE source. Build oracle first: `FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one <name>`; rebuild each edit. ⚠️ A missing/stale oracle exits 2 — reads like a skip, not a failure. Fast alt: `make check-self` |
| `test/diff_compiler_engines.sh` | eval == native == wasm. Ledger: `test/engine_divergence.txt` |
| `test/diff_compiler_perf_scaling.sh` | O(n²) detector: allocation growth N vs 2N (linear ≈2.0×, quadratic ≈4.0×) |
| `test/diff_compiler_capability_matrix.sh` | Externs vs engine coverage. Ledger: `test/CAPABILITY-EXCEPTIONS.txt`; pure externs need a verdict in `test/EXTERN-DOMAIN-LEDGER.txt` or self-drain (#476). Would have caught the `floatToInt` 3-way edge divergence (#346) structurally |
| `test/diff_compiler_tmc_parity.sh` | Both backends TMC same functions (`sh test/wasm/build_wasm_oracle.sh`) |
| `test/bootstrap_*.sh` | Each native stage == interpreter output |
| `test/diff_compiler_must_fail.sh` | **[G-MUST-FAIL]** Each `test/must_fail_fixtures/*/` pins an OPEN issue; a fix flips it green and FAILS the gate. RED here is usually GOOD. Runs in `soundness` |
| `test/check_removed_constructs.sh` | Scan for removed constructs (`JOBS=` knob) |

⚠️ **[G-PIN-DRAIN]** DRAINED must-fail pin: prefer RE-POINTING at a regression gate over
deleting. Derive the destination — a gate already owning siblings of that bug class.

🚨 **[G-DRAIN-INVISIBLE]** Invisible locally — `test/preflight.sh` never maps `soundness`. A
failed must-fail step skips later steps in that job (`typecheck_compiler_source.sh`, C3b) — read
the step list:
```sh
gh api repos/MedakaLang/medaka/actions/jobs/<job-id> --jq '[.steps[] | "\(.conclusion) :: \(.name)"]'
```

**[G-PARALLELISM]** Cap fan-out: `JOBS=n` (oracle build/gates/wasm), `INNER_JOBS=n` (per-gate).
Opt-level knobs (`EMITTER_OPT` -O2, `ORACLE_OPT` -O0, `CLI_OPT` -O2, `WASM_ORACLE_OPT` -O2,
`GC_INITIAL_HEAP_SIZE`) preserve byte-identical IR (text IR is produced before `clang` runs) —
⚠️ `ORACLE_OPT -O0` overflows deep-TCO fixtures. `compiler/PERF-RESULTS.md`.

**[G-BUILD-RACE]** Concurrent `medaka build` is scratch-path safe (per-process `mktemp -d`).
⚠️ NOT two `make medaka` runs in the SAME worktree (#1141) — outputs write to `*.new.$$` beside
their final path, promoted via same-filesystem `mv`.

## Authoring a gate case

**[WT-STEPS]** Each `test/diff_compiler_*.sh` runs a stage against `test/*_fixtures/` or
`*_goldens/`.
1. Add a fixture (first read [T-SHARED-CORPUS] in `AGENTS.md`).
2. Capture: `bash test/capture_goldens.sh`, or a gate with `CAPTURE=1`.
   `sh test/capture_goldens.sh <tag>` narrows; `--check` dry-runs.
3. Verify: `bash test/diff_compiler_<name>.sh` passes.

Add cases to the gate matching the stage changed (parser → `diff_compiler_parse*.sh`).

🚨 **[WT-GOLDEN-ENSHRINES]** A captured golden records what the engine DID, not what's CORRECT —
`eval` is a known-wrong oracle in several open S0s. Before `CAPTURE=1`:
- Work out the right answer independently, from semantics, first.
- Cross-check engines — all three agreeing does NOT prove correctness.
- Near a known-wrong area (interface defaults, dict routing, method-less impls, head-tycon
  collisions, dict-forwarding locals)? Record in the fixture how you established the value.
- Untrustworthy? Don't capture — use a correct neighbouring shape, or pin in
  `test/must_fail_fixtures/` (see `test/MUST-FAIL-NOT-PINNABLE.txt`).

⚠️ Same for **snapshot**/**selfproc LEG A** — don't `--bless` without independently deciding
correctness.

## ⚠️ Writing the SHELL half of a gate

`/bin/sh` here is **dash**, not bash (`readlink -f /bin/sh`), and gates run as `sh test/…`.

- 🚨 **[WT-DASH-PRINTF]** `printf '\xNN'` does NOT work in dash. Use octal:
  `printf '\336\255\276\357'`. Rewriting a fixed-width field? Assert the file LENGTH is
  unchanged.
- ⚠️ **[WT-TIMEOUT]** `timeout` (coreutils) doesn't exist on macOS. Use the shim from
  `test/diff_compiler_engines.sh`:
  ```sh
  run_t() { perl -e 'alarm shift; exec @ARGV' "$@"; }
  ```
  Not a drop-in — reports **142**, `timeout` reports **124**. Verify: `run_t 1 sleep 5; echo $?`.

Check in review: `grep -n "printf '\\\\x\|[^a-z]timeout " <gate>`.

⚠️ **[B-DUAL-PLATFORM]** applies to every line you write here — keep both arms alive
(`stat -c %Y` *or* `stat -f %m`), because CI is `ubuntu-latest` only and will not catch a
macOS-only break.

## Registering a new gate in CI

A gate matching `test/diff_compiler_*.sh` but not enrolled in `test/gates.toml` (with a
`shard` field) SILENTLY NEVER RUNS — `medaka gate verify` (via
`test/diff_compiler_gate_registry.sh`) catches it; it owns ENROLMENT, while
`diff_compiler_ci_shard_coverage.sh` owns CI REACHABILITY of what is already enrolled. Enrol
it in `test/gates.toml`, then run `medaka gate balance` and `make gen-ci` and commit both
files together. 🚨 That check's input is the TREE, not `test/`, so a `.sh` you add ANYWHERE
trips it. If a script isn't a gate, add a `test/CI-COVERAGE-EXCEPTIONS.txt` row with a
reason, not a rename.

🚨 **[W-SHARD-COST] `shard` is a DERIVED OUTPUT — you do not choose it, and a hand edit
reds a REQUIRED check** (#2178). Rows are filled by measured cost, never by theme, and the
thing doing the filling is `medaka gate balance`: it packs every schedulable gate onto the
open rows from the per-gate costs in `test/gate_cost_baseline.json`, honouring each row's
`wasm_arm` toolchain constraint and `full_cores` closure and an enforced pole/median budget.

A new `[[gate]]` still needs SOME `shard` string — the schema requires the field and it
cannot be left pending. **Write any row name you like (or `other-job` if a job outside the
`gates` matrix runs it), then let the tool place it:**
```sh
medaka gate balance      # rewrites every `shard` value from measured cost
make gen-ci              # regenerates ci.yml's matrix to match
```
Commit both files in ONE commit — committing either alone reds the required
`diff_compiler_ci_shard_coverage.sh` by construction.

⚠️ **Running `make gen-ci` after a hand edit does NOT make it legitimate.** That only makes
the registry and the workflow agree with each other about a row nothing derived, which
`medaka gate ci --check` is happy with. The required `ci-gen-drift` context also runs
`medaka gate balance --check`, which compares the committed assignment against the one the
baseline derives — that is what catches it, and its message names the offending gate.

🚨 Never trust a shard-cost ranking in prose; derive it, every time:
```sh
gh run view <id> --json jobs --jq '.jobs[]|select(.name|startswith("gates"))|{name,s:((.completedAt|fromdate)-(.startedAt|fromdate))}'
```
The registry's own view of the same question, with no network:
`medaka gate balance --check` prints the projected per-row totals, the pole, the median and
the enforced target.

Incident narrative for every `[G-*]` and `[WT-*]` item above: `.claude/dossier/gates.md`
and `.claude/dossier/traps.md`.
