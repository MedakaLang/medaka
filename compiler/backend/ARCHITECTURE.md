# backend/ — Core IR to LLVM text and WAT, plus the checks that gate emission

**Status:** CURRENT — re-derived from source at the P5.15 documentation cut. When it drifts, re-derive; do not patch.

## What this directory is
The last stage (`ARCHITECTURE.md` section 1), layer `backend` in A1: above `ir/`. It consumes
Core IR and the per-emission Plan and produces LLVM text (handed to `clang`) or a WAT module
for WasmGC. Name mangling (`private_mangle`) moved to `types/` (P0-D6), so backend consumes
Core IR and the Plan rather than reaching for a mangling module of its own.

## Parts
| Module | Owns | Entry points |
|---|---|---|
| `core_validate.mdk` | Checks a lowered program must pass before an emitter writes any of it: records, calls, extern coverage, impl symbols, dict tags | `validateForEmission`, `validateImplSymbolInjectivity`, `validateDictTags`, `validateBinderStamps` |
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
- **Mode policy.** A duplicate definition or contradictory prototype is fatal in every mode. Strict production output also requires every reference closed. Record mode (`emitProgramRecord`) permits an unresolved reference only where a named unsupported gap accounts for it (`excuseSymbol`). The gap census (`emitProgramGaps`) checks its audited fragments and writes no module. Unchecked inputs do not bypass physical call coverage or declaration and shape checks.
- **Diagnostics.** A defect is returned to the driver, never panicked: `defectCode` gives the `E-PHYS-*` family (`E-PHYS-DUPLICATE`, `E-PHYS-SHAPE`, `E-PHYS-UNDEFINED`, plus the Wasm-only `E-PHYS-UNDECLARED-TYPE` and `E-PHYS-UNDECLARED-FUNCREF`), `defectOrigin` locates it, and `driver/diagnostics.mdk` renders it. Codes are listed in `compiler/DIAGNOSTIC-CODES-DESIGN.md`.
- **Physical output audit.** `llvm_text_coverage.mdk` and `wasm_text_coverage.mdk` tokenize finalized target text, ignore strings and comments, and compare materialized declarations and named dependencies with each target registry. Every materialized named call needs its exact checked receipt; receipts bind the exact rendered text to the typed call descriptor. Wasm helpers carry independent counted type/global Uses in `HelperManifest`; JS wrappers carry per-conversion Uses, with tokenized drift tests in `wasm_preamble_test.mdk`. Complete strict and record output share each finalizer. Census mode checks only its exact audited fragments and retains its separate helper-function domain judge; it is not a full materialized-module closure claim. Registry seeds alone do not prove a helper or declaration reached output. The guarantee is named-call coverage plus registry agreement with typed descriptors and explicit named-use metadata, not independent Wasm operand-stack reconstruction; `wasm-tools` validation and execution remain corroborating judges. LLVM/Wasm spelling-only call pins and the old strict-only substring closure scan were retired after their bypass victims transferred to structural mutation tests.
- **Before physical lowering.** Source definition origins govern grouping in `ir/core_ir_lower.mdk`; source module components use an injective encoding in `types/private_mangle.mdk`.

## Ratchets

`compiler/backend/emit_plan_test.mdk` (native, `inlang-backend-emit-plan-test`) reads emitter and entry source. Its retirement judge parses complete historical function families, prints normalized source, erases identifier tokens and rejects matching family fingerprints. Seven retained fixtures cover R-ROSTER/R-ORD/R-GROUP for LLVM and Wasm plus R-VALUSE for Wasm; mutation controls exercise original and alpha-renamed restorations, while target-specific physical adapters remain passing neighbors. This is a bounded floor for those historical shapes, not a semantic-equivalence checker: arbitrary control-flow, literal, constructor, or clause-order rewrites can evade the fingerprint. The other listed ratchets remain spelling checks. Named-call coverage is enforced by the physical output audit above.
- `declareOfDefine` or `emitDeclaresFor` in either emitter or `llvm_preamble.mdk`;
- `leadingDictPats`, `wLeadingDictPats`, `isDictParamName` or a `startsWith "$dict"` counter in an emitter, `trmc_analysis.mdk` or `emit_plan.mdk`;
- an entry that imports an emitter without being in the pinned roster, or that builds no plan with `buildEmitPlan*`.

## Fact ledger

Each fact has one producer; a carrier moves it; a validator or fixture fails when it is wrong.

Phase 5's B1–B5 evidence is bounded by these producer/carrier/consumer checks. The listed
fixtures are judges; historical P5 reports are evidence of their execution on their recorded
heads, not a claim that this documentation slice reran them. The final integrated checks
and phase disposition are tracked by #4604.

| Rule | Producer / carrier | Consumers | Validator | Independent fixture / deletion |
|---|---|---|---|---|
| B1 Plan | `buildEmitPlan*` in `emit_plan.mdk`; `EmitPlan` carries target, extern requirements, global init, constructor facts and impl groups | LLVM and Wasm renderers; ten `entries/*_main.mdk` routes | `validateForEmission` in `core_validate.mdk` | `emit_plan_test.mdk` route roster and plan construction; P5.5, P5.10–12 evidence records |
| B2 checked capabilities and extern demand | checked request publishes `CapabilityManifest`; `externRequirements` derives reachable extern requirements into `EmitPlan` | policy/manifest consumers and both backend demand paths; playground compiler | `validateForEmission` validates requirements and physical demand; `validateWasmDemand` checks Wasm imports against Core | `core_validate_test.mdk` paired extern/projection and import/signature mutations; P5.15 `F-product-observe` compares the same validated invocation's import projection to actual shipping artifacts |
| B3 shared facts / twin retirement | `planGlobals` in `global_plan.mdk` and other fact producers listed below; immutable fields in `EmitPlan` | both backend emitters | `core_validate` plan validators | global order and corruption cases in `emit_plan_test.mdk` / `core_validate_test.mdk`; seven identifier-insensitive historical-family fingerprints and original/renamed restoration controls in `emit_plan_test.mdk`; P5.10–12 recorded twin retirement. This is a bounded historical-shape floor with rewrite blind spots. Physical instructions/layouts remain target-owned; zero twins is not a target |
| B4 route validation | `validateForEmission` in `core_validate.mdk` | all public strict, record, unchecked, census/gap, stats and playground routes; ten emitter entry routes | signature-derived public renderer roster in `core_validate_test.mdk`, entry roster in `emit_plan_test.mdk` | `core_validate_test.mdk` renderer corruption matrix and valid neighbors; P5.15 product route execution is Node shipping-artifact evidence only |
| B5 physical identity / materialized output | per-emission LLVM/Wasm symbol registries; typed Core and plan facts | physical emitters and final text audits | registries plus `llvm_text_coverage` / `wasm_text_coverage` and gateway validators | registry/gateway mutation tests and `test/wasm/assemble_check_main.sh`; deleted text-derived declarations, private dict counters, duplicate group/value-use builders, and recursive `scan*ValueUses` (see P5.8–12 reports). No independent Wasm operand-stack reconstruction claim |

| Fact | Producer | Carrier | Validator | Fixture | Deleted duplicate |
|---|---|---|---|---|---|
| LLVM symbol identity and prototype | `compiler/backend/llvm_symbols.mdk` | `symbols : Ref SymbolRegistry` in the emission state of `compiler/backend/llvm_emit.mdk` | `checkCall`, `checkRef`, `unresolved` | `compiler/backend/llvm_symbols_test.mdk`, `test/diff_compiler_llvm_symbol_collision.sh` | `declareOfDefine`, `emitDeclaresFor`; ratchet "no emitter derives declares from emitted text" |
| Wasm symbol identity | `compiler/backend/wasm_symbols.mdk` | `symbols : Ref SymbolRegistry` in the emission state of `compiler/backend/wasm_emit.mdk` | `checkCall`, `checkRef`, `checkDeclared`, `checkTypeUse`, `unresolved` | `compiler/backend/wasm_symbols_test.mdk`, `test/wasm/diff_wasm_typed.sh` | `requireHelperW`'s `unplanned-wasm-helper` judge; named calls require checked receipts in finalized output |
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
