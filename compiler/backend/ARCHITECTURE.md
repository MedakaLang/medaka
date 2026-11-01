# backend/ — Core IR to LLVM text and WAT, plus the checks that gate emission

**Status:** CURRENT — re-derived from source at 1901e7111267f00b65670cd8779cbb2c9d886f29 on 2026-10-30. When it drifts, re-derive; do not patch.

## What this directory is
The last stage (`ARCHITECTURE.md` section 1), layer `backend` in A1: above `ir/`. It consumes
Core IR and the per-emission Plan and produces LLVM text (handed to `clang`) or a WAT module
for WasmGC. Name mangling (`private_mangle`) moved to `types/` (P0-D6), so backend consumes
Core IR and the Plan rather than reaching for a mangling module of its own.

## Parts
| Module | Owns | Entry points |
|---|---|---|
| `core_validate.mdk` | Checks a lowered program must pass before an emitter writes any of it: records, calls, extern coverage, impl symbols, dict tags | `validateExterns`, `validateRecords`, `validateCalls`, `validateForEmission` |
| `emit_target.mdk` | Backend identity shared by validation, plans and the runtime catalog | `Backend`, `backendName`, `profileColumn` |
| `emit_plan.mdk` | The per-emission plan: facts about the lowered program both backends read and neither recomputes | `buildEmitPlan`, `buildEmitPlanReached` |
| `impl_groups.mdk` | Ordered partition of Core implementation clauses by method and key, with indices into the original program list | `groupImplEntries`, `validateImplGroups` |
| `emit_support.mdk` | Backend-neutral helpers shared by both emitters, the canonical definition | shared emit helpers |
| `extern_catalog.mdk` | The runtime extern catalog as data: one row per `stdlib/runtime.mdk` extern, naming how each backend lowers it | catalog rows |
| `trmc_analysis.mdk` | Backend-agnostic tail-recursion-modulo-cons eligibility analysis | `trmcEligible` |
| `llvm_emit.mdk` | Core IR to textual LLVM IR; shells out to `clang`; the canonical native backend | `emitProgram` |
| `llvm_preamble.mdk` | The runtime declarations heading every LLVM module, as a table of `RuntimeDecl` rows: `declareLine` renders a row's text and `declareRuntime` registers its prototype, so a call is checked against the prototype the text declares; order load-bearing | `RuntimeDecl`, `declareLine`, `declareRuntime` |
| `llvm_symbols.mdk` | Leaf. The per-emission registry of LLVM symbols: each function and global, its prototype, the binding whose emission wrote it; judges a definition, declaration, call or address use against it | `SymbolRegistry`, `declareSymbol`, `defineSymbol`, `declareOnce`, `checkCall`, `checkRef`, `unresolved`, `defectCode` |
| `wasm_symbols.mdk` | Leaf. The same over Wasm functions, types, globals, data segments and `elem declare` entries | `SymbolRegistry`, `declareSymbol`, `defineSymbol`, `checkCall`, `checkRef`, `checkDeclared`, `checkTypeUse`, `unresolved`, `defectCode` |
| `../support/symbol_origin.mdk` | Where a symbol was written or used (`SymbolOrigin`), shared by both registries and the driver's diagnostic | `SymbolOrigin`, `bindingOf`, `placeOf` |
| `wasm_emit.mdk` | WasmGC emitter, peer of `llvm_emit.mdk` over the same Core IR; one recursive value/control traversal selects raw or boxed physical instructions | `emitProgram` |
| `wasm_repr.mdk` | WasmGC physical value representations and typed local-slot accessors; no traversal or explicit imports | `WasmRepr`, `WasmValue`, `LocalSlot` |
| `wasm_preamble.mdk` | The fixed lines heading every WAT module, as helper blocks; the registry is seeded from the `HelperManifest` rows in `wasm_demand.mdk` (`helperManifest`), which state per block the functions it defines, external calls and counted named type/global Uses, so a helper call is judged without reading helper text | `declarePlannedHelpers`, `checkPlannedHelperUses`, `plannedHelperBlock` |
| `wasm_reach.mdk` | Dispatch-rooted reachability filter for the WasmGC modules path, after `dce` | reachability filter |
| `wasm_file_grants.mdk` | Wasm file-capability prerequisites on the elaborated AST, shared with the in-browser compiler | `moduleGrantDiags` |

## Laws that bind it
- **A1** — backend is the top compiler layer below `driver/`; it imports `ir/`, `frontend/`, `support/` and small fact modules from `types/`, never the reverse.
- **A4** — a fact both emitters need is a field of Core IR or the Plan, checked by `core_validate.mdk`, then transcribed. The two emitters still share named twin functions, pinned in `test/arch_goldens/twins.golden`.
- **A9** — validators run before either emitter writes text, on every build.
- **A8** — a new target concern is a new module, as the preamble and reach modules were.

`impl_groups.mdk` is a pure Core consumer leaf. It imports `ir/core_ir` and
`support/ordmap`/`support/util` only (plus the prelude); it does not import an
emitter, driver, tools, type inference or `emit_plan`.

## Physical identity

The Core gateway (`core_validate.mdk`) judges names that exist before lowering. Names minted by physical lowering (`mdk.gen.*`, `mdk.impl.*`, `mdk.force.*`, `$codety`, helper functions) exist only inside one emitter, so each emitter keeps a registry (`llvm_symbols.mdk`, `wasm_symbols.mdk`) and checks each definition, declaration, call and reference as it writes it. A registry is a leaf: it imports `support/` only, and neither imports an emitter, `ir/`, `types/` or the other registry (closure goldens `test/arch_goldens/closure.backend.llvm_symbols.golden`, `closure.backend.wasm_symbols.golden`).

- **Timing.** A type, global, runtime helper or data segment is declared before it is used, so a use of an undeclared one is a defect at the use. A function may be called before it is defined, so such a call waits and is judged when the definition arrives; what still waits when the module is complete is `unresolved`.
- **Mode policy.** A duplicate definition or contradictory prototype is fatal in every mode. Strict production output also requires every reference closed. Record mode (`emitProgramRecord`, the gap census `emitProgramGaps`) keeps an incomplete module only where a named unsupported gap accounts for the unresolved reference (`excuseSymbol`); the census refuses the duplicate and shape defects and writes no module. The input-isolation harness keeps only its final closure exemption.
- **Diagnostics.** A defect is returned to the driver, never panicked: `defectCode` gives the `E-PHYS-*` family (`E-PHYS-DUPLICATE`, `E-PHYS-SHAPE`, `E-PHYS-UNDEFINED`, plus the Wasm-only `E-PHYS-UNDECLARED-TYPE` and `E-PHYS-UNDECLARED-FUNCREF`), `defectOrigin` locates it, and `driver/diagnostics.mdk` renders it. Codes are listed in `compiler/DIAGNOSTIC-CODES-DESIGN.md`.
- **Physical output audit.** `wasm_text_coverage.mdk` tokenizes the assembled module, ignores strings and comments, and compares actual declarations and named dependencies with the registry. Every named direct call needs its exact checked receipt. Helpers carry independent counted type/global Uses in `HelperManifest`; JS wrappers carry per-conversion Uses, with tokenized drift tests in `wasm_preamble_test.mdk`. Complete strict and record output share this finalizer; the census checks fragments and retains its separate helper-function domain judge. This guarantees named-call coverage and agreement with typed descriptors and explicit Uses, not Wasm operand-stack reconstruction; validation and execution remain corroborating judges. The old strict-only substring closure scan is retired.
- **Before physical lowering.** Source definition origins govern grouping in `ir/core_ir_lower.mdk`; source module components use an injective encoding in `types/private_mangle.mdk`.

## Ratchets

`compiler/backend/emit_plan_test.mdk` (native, `inlang-backend-emit-plan-test`) reads emitter and entry source and fails when a retired mechanism returns in its known spelling. These are spelling checks, not a structural guarantee: a call assembled by concatenation (for example `"call " ++ ty ++ " @" ++ f`, or `"return_call " ++ "$" ++ f`) is not seen, and the LLVM check accepts any `checkWordCall` in the three preceding lines, not only one for the same call.
- an LLVM `call <ty> @name` written outside `directCall` and not preceded by `checkWordCall`;
- a `call $` in `wasm_emit.mdk` outside `callInstrW`;
- `declareOfDefine` or `emitDeclaresFor` in either emitter or `llvm_preamble.mdk`;
- `leadingDictPats`, `wLeadingDictPats`, `isDictParamName` or a `startsWith "$dict"` counter in an emitter, `trmc_analysis.mdk` or `emit_plan.mdk`;
- an entry that imports an emitter without being in the pinned roster, or that builds no plan with `buildEmitPlan*`.

## Fact ledger

Each fact has one producer; a carrier moves it; a validator or fixture fails when it is wrong.

| Fact | Producer | Carrier | Validator | Fixture | Deleted duplicate |
|---|---|---|---|---|---|
| LLVM symbol identity and prototype | `compiler/backend/llvm_symbols.mdk` | `symbols : Ref SymbolRegistry` in the emission state of `compiler/backend/llvm_emit.mdk` | `checkCall`, `checkRef`, `unresolved` | `compiler/backend/llvm_symbols_test.mdk`, `test/diff_compiler_llvm_symbol_collision.sh` | `declareOfDefine`, `emitDeclaresFor`; ratchet "no emitter derives declares from emitted text" |
| Wasm symbol identity | `compiler/backend/wasm_symbols.mdk` | `symbols : Ref SymbolRegistry` in the emission state of `compiler/backend/wasm_emit.mdk` | `checkCall`, `checkRef`, `checkDeclared`, `checkTypeUse`, `unresolved` | `compiler/backend/wasm_symbols_test.mdk`, `test/wasm/diff_wasm_typed.sh` | `requireHelperW`'s `unplanned-wasm-helper` judge; ratchet "wasm_emit writes a direct call only through callInstrW" |
| Symbol origin (binding and position) | `compiler/support/symbol_origin.mdk` | `SymbolOrigin` inside each `SymbolDefect` | `defectOrigin` located by `compiler/driver/diagnostics.mdk` | `compiler/support/symbol_origin_test.mdk` | the per-emitter origin helpers (`bindingOf`, `placeOf` had three identical bodies) |
| Leading dictionary count | `leadingDictParams` in `compiler/ir/core_ir.mdk` | clause patterns | every consumer reads the one function | `compiler/ir/core_ir_lower_test.mdk` ("leadingDictParams counts only the leading dict witnesses") | `leadingDictPats`, `wLeadingDictPats`, `isDictParamName`; ratchet "no emitter counts leading dictionary parameters from their spelling" |
| Runtime constructor facts and declared constructor facts | `runtimeCtorFact` / `runtimeRoster` in `compiler/frontend/runtime_constructors.mdk`; `planConstructors` in `compiler/ir/constructor_facts.mdk` | `constructorFacts` in `EmitPlan` | `validateConstructorFacts` from `core_validate.mdk` before backend output | `runtime_constructors_test.mdk`, `constructor_facts_test.mdk`, `core_validate_test.mdk` | LLVM semantic constructor maps and ordinal derivation; Wasm `WasmCtorIndex` semantic tables and ordinal derivation |
| Implementation-clause grouping | `groupImplEntries` in `compiler/backend/impl_groups.mdk` | `implGroups` in `EmitPlan` | `validateImplGroups` from `core_validate.mdk` before backend output | `impl_groups_test.mdk`, `core_validate_test.mdk`, emitter route tests | LLVM and Wasm duplicate key/group builders; physical group records and method dispatch buckets remain target-owned |
| Dispatch and definition arities | `definedArityOf` in `compiler/ir/core_ir_lower.mdk` | `e.arities` of the LLVM emission state | `checkCall` shape check | `compiler/backend/llvm_symbols_test.mdk`, `test/diff_compiler_call_arity_test.mdk` | the LLVM dispatch-graph arity table |
| Int-helper membership | `plan.censusIntHelpers` / `intHelpers` in `compiler/backend/wasm_demand.mdk` | the Wasm demand plan | `UndefinedReference` from the helper rows of `compiler/backend/wasm_preamble.mdk` | `compiler/backend/wasm_demand_test.mdk` | `noteIntRt` and its `unplanned-wasm-helper: Int` panic |
| Wasm function-wrapper value demand | `fnValueUses` in `compiler/backend/wasm_fn_values.mdk`, using selected fallthrough symbols from `wasm_demand.mdk` | `fnValues : OrdMap Unit` in `WasmDemandPlan` | `validateWasmDemand` independently replans the exact supplied Core program and rejects missing/extra keys before emission | `compiler/backend/wasm_fn_values_test.mdk`, `compiler/backend/wasm_demand_test.mdk`, `compiler/backend/core_validate_test.mdk`, `test/wasm/assemble_check_main.sh` | `wasm_emit.mdk`'s recursive `scan*ValueUses` family; ratchet in `emit_plan_test.mdk` |
| Wasm helper manifest | `helperManifest` in `compiler/backend/wasm_demand.mdk` | `HelperManifest` rows | block text agrees with its row | `compiler/backend/wasm_preamble_test.mdk` ("each helper block's text defines and calls what its manifest row states") | none |
| LLVM preamble table | `compiler/backend/llvm_preamble.mdk` | `RuntimeDecl` rows | `declareRuntime` registers each row | `compiler/backend/llvm_preamble_test.mdk` | the fixed preamble text lines |
| Emit routes | the roster in `compiler/backend/emit_plan_test.mdk` | `compiler/entries/*.mdk` | "the emit-route entries are exactly the pinned roster and each builds its plan" | same test | none |

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
