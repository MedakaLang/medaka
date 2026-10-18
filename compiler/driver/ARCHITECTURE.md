# driver/ — the `medaka` CLI, the module loader, diagnostics and `build`

**Status:** CURRENT — re-derived from source at `ffd3bdb65897da35db70d06dbb5df3df35d884d7` on 2026-10-15. When it drifts, re-derive; do not patch.

## What this directory is
The top of the stack (A1: `driver`, `tools` and `entries` sit above every layer and nothing below imports
them). It turns argv and a root file into a dependency-ordered module list, runs the pipeline of
`ARCHITECTURE.md` section 1, and prints the result. Verb logic that is larger than dispatch lives in
`tools/`; this directory keeps the dispatcher, the loader, the diagnostic pipeline and the native build.

## Parts
| Module | Owns | Entry points |
|---|---|---|
| `medaka_cli.mdk` | The native `medaka` dispatcher: one arm per verb (check, fmt, new, build, run, test, snapshot, repl, lsp, mcp, doc, codemod, check-policy, manifest, gate, lint); installs the stage-count dump | `main` |
| `loader.mdk` | The dependency walk: dotted module id to file, topological order, cycle detection, project-root discovery from `medaka.toml` | `loadProgramE`, `findProjectRoot`, `fileOfModuleId` |
| `diagnostics.mdk` | The accumulating error pipeline: every stage runs without exit-on-first-error and returns a structured `Diag` list with optional spans, plus hints and fixes | `mkDiag`, `diagOfResError` |
| `build_cmd.mdk` | `medaka build`: shells out to a fresh emitter process, then clang, the C runtime and Boehm GC; native and wasm targets | `runBuild`, `runBuildNative`, `envOr` |
| `main_autoprint.mdk` | Wraps the elaborated trees of a bare non-Unit value `main` in the prelude's own elaborated `println` under an unspellable name, applied with the drive's auto-print evidence; the `Async` main driver wrap; the async-main shape check | `executedTrees`, `mainIsWrapped`, `shouldAutoPrintMain` |

## Laws that bind it
- **A1** — nothing below `driver/` imports it. The one `eval -> driver` edge (`eval.mdk` importing `diagnostics`) is a counted violation.
- **A5** — `diagnostics.mdk` is the accumulator: errors are data and nothing exits early.
- **A6** — `medaka_cli.mdk` is where the hooks record is to be installed once; `support/hooks.mdk` does not yet carry a record.
- **A7** — one load per process is the target (#4141); `loader.mdk` bumps `support.stage_count` so a repeated load shows as a count.

## Boundaries and checks
- `test/arch_boundaries_test.mdk` and `test/arch_goldens/layering.golden`: layering.
- `test/stage_counts_test.mdk` with `test/arch_goldens/stage_counts.golden`: how many times each stage ran per verb.
- `test/diff_compiler_cli_reject_floor_test.mdk`: flag rejection across the dispatcher.
- `compiler/driver/build_cmd_test.mdk` and `diagnostics_test.mdk`: module-local tests.

## Where the design lives
- `docs/ops/CLI-CONFORMANCE.md` for verb conventions; `compiler/BOOTSTRAP.md` for building.
- `TYPECHECK-CONTRACTS.md` section 5 and #4141 for the destination session (module graph, interface cache); #2732.
- `archive/design/COMPOSITE-MAIN-AUTOPRINT-DESIGN.md` for the auto-print wrap.

## Traps
- `[T-ERRORS-ACCUM]` — errors accumulate in `diagnostics.mdk`; no early exits.
- `[T-MAIN-ZERO-ARG]` — `main = …` is a value; `main () = …` is an error on `run` and `build`.
- `[D-BUILD-PIPE]` — `medaka build`'s exit code does not survive a pipe.
- `[B-STALENESS]` — every run compares the baked source fingerprint with disk.
