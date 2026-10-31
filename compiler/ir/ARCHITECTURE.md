# ir/ — Core IR: types, lowering, serialization, DCE and the Core IR interpreter

**Status:** CURRENT — re-derived from source at e6ed1546a6ab399d084f40fb118c294fc36dfdef on 2026-10-15. When it drifts, re-derive; do not patch.

## What this directory is
The seam between front and back (`ARCHITECTURE.md` section 1), layer `ir` in A1: above `types/`,
below `backend/`. It consumes the elaborated AST (desugared, typed, dict-routed) and produces
the backend-neutral Core IR that both emitters and the equivalence oracle read. Also holds the
AST S-expression dump (`sexp.mdk`), kept here with the Core IR dumpers.

## Parts
| Module | Owns | Entry points |
|---|---|---|
| `core_ir.mdk` | The Core IR itself: a serializable, backend-neutral representation that lives above any ISA | `CProgram`, `CExpr` |
| `core_ir_lower.mdk` | Elaborated AST to Core IR lowering; reads the typechecker's dispatch cells out into immutable nodes | `lowerProgramWithFacts`, `lowerProgramEmitWith`, `definedArityOf` |
| `core_ir_sexp.mdk` | Structural S-expression dump of the Core IR, the frozen serialization contract | `cprogramToSexp` |
| `core_ir_sexp_parse.mdk` | Round-trip deserializer for that format back into a `CProgram` | `parseCProgram` |
| `core_ir_eval.mdk` | Core IR interpreter that reuses the AST evaluator's runtime, diffed against it as the equivalence oracle | `cevalModules` |
| `dce.mdk` | Conservative dead-code elimination for the native emit path; every impl body stays a root | `dceFilter` |
| `sexp.mdk` | Structural S-expression dump of the surface AST | `programToSexp` |

## Laws that bind it
- **A1** — ir sits above `types/`; today only `core_ir_eval.mdk` imports `eval.eval`, the one `ir -> eval` edge in `test/arch_goldens/layering.golden`, and it may only fall. The lowering's closure is pinned free of `eval` (`closure.ir.core_ir_lower.golden`): what it shares with the interpreter lives in `types/dispatch_keys.mdk` and `types/expr_loc.mdk`.
- **A4** — a fact two backends need (arity, field ordinal, dispatch target) is stamped here once and carried on the IR, then checked by `backend/core_validate.mdk`.
- **A2** — lowering reads cells out of the AST into values; Core IR itself holds no mutable cell.
- **A9** — the closure of `core_ir.mdk` is a committed golden.

## Boundaries and checks
- `test/arch_goldens/closure.ir.core_ir.golden` pins the import closure of `core_ir.mdk`.
- `test/arch_goldens/layering.golden` pins the layering-violation count; `cells.golden` and `twins.golden` pin neighbouring counts.
- `test/arch_boundaries_test.mdk` computes them; `test/arch_ratchet.sh` fails a rise unless a commit trailer names it.
- `test/stage_counts_test.mdk` pins per-stage work counts.
- `test/diff_compiler_core_ir_typed_modules.sh` diffs Core IR evaluation against the AST evaluator over the typed-modules corpus.

## Where the design lives
- `archive/design/STAGE2-DESIGN.md` for the IR's origin and its Axis discipline (history).
- `EMITTER-TARGET-ARCHITECTURE.md`, `EMITTER-ARCHITECTURE.md` and `EMITTER-GAPS.md` for what lowering must provide.
- `ARCHITECTURE-PLAYBOOK.md` for the Plan record and the fact ledger.

## Traps
- `[T-EVAL-LOCKSTEP]` — `evalModulesWith` and `cevalModules` are parallel drivers; fix both.
- `[T-LEGA-GOLDEN]` — `ir.sexp` is a LEG A module; a top-level change moves its selfproc golden.
- `[T-GLOBAL-TABLE]` — a new IR constructor means auditing every `_ =>` arm.
- `[D-CORE-IR-TYPED]` — the Core IR dump probes live in the `debug-pipeline` skill.
