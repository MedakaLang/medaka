# entries/ — per-stage probe mains for the differential gates and the oracles

**Status:** CURRENT — re-derived from source at `ffd3bdb65897da35db70d06dbb5df3df35d884d7` on 2026-10-15. When it drifts, re-derive; do not patch.

## What this directory is
Thin `main` programs, each driving one pipeline stage (`ARCHITECTURE.md` section 1) so a shell gate or an
oracle can run the stage as a process and diff its output. They sit at the top of A1 with `driver/` and
`tools/`; nothing imports them. Most run under `medaka run` and are not compiled into the `medaka`
binary, so they may import the whole compiler. The shared setup (read the runtime, prelude and target
off argv, parse and desugar each) lives in `entry_support.mdk`, and each probe adds its terminal call.

## Parts
This directory holds one probe per pipeline stage and mode, so it takes the template's one exception: rows group
probes by filename family, and the count column says how many files a row covers.

| Module (family) | Owns | Entry points |
|---|---|---|
| `entry_support.mdk` (1) | The shared loader and setup scaffolding for the probes | `rootsOrDefault`, `elaborateOne` wiring |
| `lex_main`, `typecheck_main` (2) | Lexer token dump and the typecheck probe | `main` |
| `parse_*` (2) | Parser output and parse-result probes | `main` |
| `resolve_*` (3) | Resolve probes: single, modules, batch | `main` |
| `check_*` (6) | The composed front-end check: single, all, batch, match, modules, one-diags | `main` |
| `eval_*` (12) | The interpreter over plain, typed, dict and modules inputs; batched variants; the auto-print probe | `main` |
| `core_ir_*` (10) | Core IR lowering, dumps, round trip, dict printing and true-execution through the IR | `main` |
| `llvm_*` (4) | LLVM IR emission (plain, modules, typed) and the bootstrap lexer probe | `main` |
| `wasm_emit_*` (4) | Wasm emission and the gaps report | `main` |
| `profile_*` (3) | Per-stage timing drivers under `MEDAKA_PERF` | `main` |
| `selfproc_*` (3) | The compiler's own lexer, parser and typechecker run as probes for the self-processing gate | `main` |
| `lsp_*` (2) | The language server entry and its harness | `main` |
| `fmt_main`, `lint_main`, `lint_fix_main` (3) | Formatter and lint probes | `main` |
| `test_main`, `build_main`, `new_main`, `repl_main`, `refindex_main` (5) | Interpreted drivers for the verbs whose logic is in `tools/` or `driver/` | `main` |
| `diagnostics_project_main`, `native_doctest_probe_main`, `fuzz_gen_main`, `playground_main` (4) | The project diagnostics probe, the native doctest probe, the fuzz program generator, the playground compiler entry | `main` |
| `all_modules_entry.mdk` (1) | A synthetic entry importing one name from every compiler module, for the batch typecheck leg | closure of the whole compiler |
| `module_closure_probe.mdk` (1) | Prints the loader's real import closure of an entry | `main` |
| `oracle_multicall.mdk` (1) | One binary dispatching on its own basename, standing in for the oracles `test/build_oracles.sh` builds | `oracleMain` arms |

## Laws that bind it
- **A1** — an entry may import anything; no compiler module imports an entry.
- **A2** — a probe prints its stage's output as a value for a gate to diff; it holds no pipeline logic of its own.
- **A6** — `entry_support.mdk` is where the hooks record is to be installed for the probe mains.
- **A7** — a probe is a single drive of one stage; a batch variant exists to parse the prelude once.

## Boundaries and checks
- `test/arch_boundaries_test.mdk` and `layering.golden`: probes import down, never the reverse.
- `test/build_oracles.sh` and `test/diff_compiler_*` gates run the probes and diff their output; `medaka gate explain <probe path>` names the nearest gate.
- `[W-MODULE-BLIND]`: a module outside every entry's import closure is invisible to `make medaka`; `all_modules_entry.mdk` is the batch typecheck net.
- `test/diff_compiler_selfproc.sh`: the `selfproc_*` probes.

## Where the design lives
- `.claude/skills/architecture/SKILL.md` (placement), `compiler/BOOTSTRAP.md`.
- `docs/ops/CLI-CONFORMANCE.md` for what the verbs the probes mirror must do.

## Traps
- `[D-GATE-OVERRIDE]` — some gates hardcode their binary, so a two-arm run reports identical.
- `[L-SELFPROC-CARVEOUT]` — build `check_all_main`, `eval_modules_main`, `eval_typed_modules_main` before the selfproc gate.
- `[T-EVAL-LOCKSTEP]` — `eval_*` and `core_ir_*` probes exercise the paired drivers.
- `[W-THIRD-CONSUMER]` — a new directory of probes must be visible to `test/preflight.sh`.
