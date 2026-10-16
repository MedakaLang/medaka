# backend/ — Core IR to LLVM text and WAT, plus the checks that gate emission

**Status:** CURRENT — re-derived from source at e6ed1546a6ab399d084f40fb118c294fc36dfdef on 2026-10-16. When it drifts, re-derive; do not patch.

## What this directory is
The last stage (`ARCHITECTURE.md` section 1), layer `backend` in A1: above `ir/`. It consumes
Core IR and the per-emission Plan and produces LLVM text (handed to `clang`) or a WAT module
for WasmGC. Name mangling (`private_mangle`) moved to `types/` (P0-D6), so backend consumes
Core IR and the Plan rather than reaching for a mangling module of its own.

## Parts
| Module | Owns | Entry points |
|---|---|---|
| `core_validate.mdk` | Checks a lowered program must pass before an emitter writes any of it: records, calls, extern coverage, impl symbols, dict tags | `validateExterns`, `validateRecords`, `validateCalls`, `Backend` |
| `emit_plan.mdk` | The per-emission plan: facts about the lowered program both backends read and neither recomputes | `buildEmitPlan`, `buildEmitPlanReached` |
| `emit_support.mdk` | Backend-neutral helpers shared by both emitters, the canonical definition | shared emit helpers |
| `extern_catalog.mdk` | The runtime extern catalog as data: one row per `stdlib/runtime.mdk` extern, naming how each backend lowers it | catalog rows |
| `trmc_analysis.mdk` | Backend-agnostic tail-recursion-modulo-cons eligibility analysis | `trmcEligible` |
| `llvm_emit.mdk` | Core IR to textual LLVM IR; shells out to `clang`; the canonical native backend | `emitProgram` |
| `llvm_preamble.mdk` | The fixed runtime `declare` lines heading every LLVM module; pure data, order load-bearing | preamble lines |
| `wasm_emit.mdk` | WasmGC emitter, peer of `llvm_emit.mdk` over the same Core IR | `emitProgram` |
| `wasm_preamble.mdk` | The fixed lines heading every WAT module; pure data | preamble lines |
| `wasm_reach.mdk` | Dispatch-rooted reachability filter for the WasmGC modules path, after `dce` | reachability filter |
| `wasm_file_grants.mdk` | Wasm file-capability prerequisites on the elaborated AST, shared with the in-browser compiler | `moduleGrantDiags` |

## Laws that bind it
- **A1** — backend is the top compiler layer below `driver/`; it imports `ir/`, `frontend/`, `support/` and small fact modules from `types/`, never the reverse.
- **A4** — a fact both emitters need is a field of Core IR or the Plan, checked by `core_validate.mdk`, then transcribed. The two emitters still share named twin functions, pinned in `test/arch_goldens/twins.golden`.
- **A9** — validators run before either emitter writes text, on every build.
- **A8** — a new target concern is a new module, as the preamble and reach modules were.

## Boundaries and checks
- `test/arch_boundaries_test.mdk` and `test/arch_ratchet.sh`: layering, cells, hooks, closures; may-only-fall pins.
- `test/arch_goldens/twins.golden` (llvm/wasm twin functions), `dupbodies.golden` (identical-body names), `layering.golden`, `cells.golden`.
- `test/stage_counts_test.mdk`: per-stage work counts.
- Fixpoint and parity gates for emitters are in `test/gates.toml`; measure emitter changes with the `benchmark-emitter` skill.

## Where the design lives
- `EMITTER-TARGET-ARCHITECTURE.md` (destination), `EMITTER-ARCHITECTURE.md` (current), `EMITTER-ARCH-BUG-FIT.md`.
- `EMITTER-GAPS.md` for known gaps; `RUNTIME-DESIGN.md` and `FFI-ABI.md` for the C runtime.
- `docs/design/TARGETS-DESIGN.md` for the extern catalog and profiles.

## Traps
- `[T-EMITTER-BENCH]` — measuring an emitter change needs a double forced rebuild and a seed refresh.
- `[B-NO-BORROW-ISOLATED]` — never copy an emitter from another tree.
- `[T-GUARDS]` — match guards lower natively; see `EMITTER-GAPS.md`.
- `[D-EMITTER-CLI]` — emitter probes live in the `debug-pipeline` skill.
