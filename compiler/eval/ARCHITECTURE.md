# eval/ — the tree-walking interpreter and its 64-bit integer halves

**Status:** CURRENT — re-derived from source at `ffd3bdb65897da35db70d06dbb5df3df35d884d7` on 2026-10-16. When it drifts, re-derive; do not patch.

## What this directory is
The interpreter behind `medaka run`, the REPL and the Core IR equivalence oracle (`ARCHITECTURE.md`
section 1). By A1 it sits beside `ir/` above `types/`: it reads the desugared, elaborated program and
runs it. `eval.mdk` is one very large module; the rest of the directory is one helper. The
interpreter is itself a Medaka program, so its `Int` is 63 bits wide.

## Parts
| Module | Owns | Entry points |
|---|---|---|
| `eval.mdk` | The engine: values, environments, pattern matching, typeclass dispatch (`VMulti`, `VTypedImpl`, dict application), externs, the multi-module driver | `evalModules`, `evalModulesWith`, `ppValue` |
| `u64_halves.mdk` | `U64` and `I64` arithmetic as two 32-bit `Int` halves, so no intermediate exceeds 2^62; total and bit-for-bit equal to the native operations | `add`, `mul`, `compareU64` |

## Laws that bind it
- **A1** — `eval` may depend on `frontend`, `types` and a shared data module. Today `eval.mdk` imports `driver.diagnostics` (the one `eval -> driver` edge), and `ir/` and `backend/` import `eval`.
- **A2** — a stage's output is a value; the interpreter's result is a rendered `Value`, not a mutated global.
- **A3** — `eval.mdk` keeps module-level `Ref` tables (constructor-to-type, extern names, field orders); `test/arch_goldens/cells.golden` counts them.
- **A7** — `evalModules` here and `cevalModules` in `ir/core_ir_eval.mdk` are parallel drivers; a fix lands in both.

## Boundaries and checks
- `test/arch_boundaries_test.mdk` and `test/arch_goldens/layering.golden`: the layering edge count, which includes the `eval` edges.
- `test/arch_goldens/cells.golden`: module-level cells per module.
- `test/diff_compiler_eval_test.mdk`: the engine's rows, including the `eval_modules_fixtures` regressions for loader-only dispatch bugs.
- `test/diff_compiler_selfproc.sh`: LEG A re-runs the compiler's own modules through the interpreter; `test/selfproc_goldens/legA/eval.eval.golden` moves with a top-level change here.

## Where the design lives
- `compiler/RUNTIME-DESIGN.md`, `compiler/EMITTER-GAPS.md`.
- `docs/design/INTEGER-TYPES-DESIGN.md` section 6.2 for the halves.
- `ARCHITECTURE.md` section 3: the destination is a consumer of `CheckedProgram` that stays the pure oracle (#1122).

## Traps
- `[T-EVAL-LOCKSTEP]` — fix `evalModules` and `ir/core_ir_eval.mdk`'s `cevalModules` together; cross-module tables key per module, never by bare name.
- `[T-DISPATCH-LOADER]` — a dispatch bug that shows only via the loader is usually the eval driver.
- `[T-PRELUDE-DICT]` — untyped eval is first-impl-wins; `pure` needs types.
- `[T-LEGA-GOLDEN]` — a top-level binding change here moves `legA/eval.eval.golden`.
