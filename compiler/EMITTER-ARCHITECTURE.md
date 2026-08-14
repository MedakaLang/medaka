# Emitter Architecture - the derived current map

**Status:** CURRENT - source-derived LLVM/WasmGC emitter map through X-W.H2b.10.
This is a description of the current
implementation, not the target design. The target is
[`EMITTER-TARGET-ARCHITECTURE.md`](EMITTER-TARGET-ARCHITECTURE.md), and the
per-bug fit ledger is
[`EMITTER-ARCH-BUG-FIT.md`](EMITTER-ARCH-BUG-FIT.md).
Cross-backend migration is tracked by #1398.

**Derivation rule.** Names and file paths below are queries; counts and line
numbers are deliberately not architecture. Re-derive top-level declarations
with `medaka symbols` or a declaration grep, the product paths from
`compiler/entries/{llvm,wasm}_emit_modules_main.mdk`, and open defects from the
GitHub severity labels. The map was checked against source rather than copied
from `STAGE2-DESIGN.md`, `EMITTER-GAPS.md`, tracker #362, or tracker #384; all
four contain useful history and stale status.

## 1. Pipeline and product paths

Both compiled backends consume the same elaborated program and the same Core
IR type:

```text
loader module graph
  -> parse / desugar
  -> private_mangle.mangleUnits
  -> resolve / mark / typecheck / dictionary elaboration
  -> backend-specific emitTail
       -> dce.dceFilter (except native half modes that deliberately retain all)
       -> core_ir_lower.lowerProgramEmit
       -> CProgram
            -> llvm_emit.emitProgram -> LLVM text -> clang -> native binary
            -> wasm_emit.emitProgram -> WAT -> wasm-tools -> WasmGC module
```

`compiler/entries/entry_support.mdk` owns the common command-line module driver.
Its `runEmitWith`/`emitModulesWith` functions parameterize only the terminal
`emitTail`, so composite-`main` rewriting, mangling, and elaboration are shared
by the LLVM/Wasm command-line entries. DCE and lower/emit installation are wired
inside each backend's `emitTail`; native prelude/program-half modes may bypass
DCE.

The shipping compiler products include:

| Binary | Entry | Role |
|---|---|---|
| `medaka_emitter` | `compiler/entries/llvm_emit_modules_main.mdk` | Self-hosted LLVM emitter used by `medaka build` |
| `medaka` | `compiler/driver/medaka_cli.mdk` | User CLI, itself compiled by `medaka_emitter` |
| browser compiler | `compiler/entries/playground_main.mdk` | Shipping Wasm self-host used by the playground |

The Wasm product emitter is built separately from
`compiler/entries/wasm_emit_modules_main.mdk` by
`test/wasm/build_wasm_oracle.sh`, then supplied to `build_cmd.mdk` through
`MEDAKA_WASM_EMITTER`. `medaka build --target wasm` does not build that emitter
for itself; an unset/missing path is an actionable error.

`playground_main.runEmit` is a third product consumer and currently repeats the
mangle -> elaborate -> DCE -> input construction -> `lowerProgramEmit` -> `emitProgram`
sequence instead of using `entry_support.runEmitWith`. It is built by the
playground Wasm build scripts. Any contract migration that updates only
`wasm_emit_modules_main` leaves the browser compiler on the old seam.

The canonical `run` path is not a Core-IR consumer. It evaluates the elaborated
AST through `compiler/eval/eval.mdk`. `compiler/ir/core_ir_eval.mdk` is a
differential interpreter, not a product engine. Consequently:

- `run` versus `build` is an independent observation only after the shared
  front end;
- LLVM and Wasm agreement can certify a shared lowering defect rather than
  correctness;
- a target architecture that changes Core does not automatically remove the
  independent AST evaluator's realization defects.

## 2. What Core IR carries

`compiler/ir/core_ir.mdk` defines `CProgram` as four lists:

```medaka
CProgram
  (List CBind)
  (List (String, Int))
  (List (String, String))
  (List CImplEntry)
```

They are function groups, constructor arities, constructor-to-type names, and
lowered implementation/default entries. `CExpr` is desugared and effects are
erased. It carries some decisions explicitly:

| Decision | Current carrier |
|---|---|
| Lexical reference | `CVar String Addr` (although Core eval still looks up by name) |
| Dictionary route | `CMethod` / `CDict` containing `Route` recipes |
| Match discrimination | `CDecision` and `CTree` |
| Primitive scalar exception | string field on `CBinPrim` (`"Int"`, `"Float"`, or empty) |
| Record ownership hints | record/constructor name strings on record operations |
| Guard fallthrough | label encoded through `emit_support.labelFallthrough` |

The upstream AST now has the settled namespace-tagged `Ident` type
(`Ns` + origin + spelling), but Core does not yet carry that authoritative
identity for every namespace. It also does not carry
complete runtime-type facts, field ownership/ordinals, a complete instance
method table, source arity, dictionary-prefix shape, closure application mode,
global force policy, capability requirements, or backend linkage identity.

The header calls routes "dicts explicit", but they are not ordinary dictionary
construction/projection/application terms. Each engine still interprets the
route and can reconstruct a different realization. Open #1068 is exactly this
producer/consumer disagreement.

`lowerProgram` and `lowerProgramEmit` also form two Core variants.
`lowerProgramEmit` applies emitter-only record-pattern rewriting and nullary
memoization before either physical backend sees the program. Core evaluation
does not consume that form.

## 3. The hidden emitter input

`CProgram` is not the whole product-emitter input. Each module driver computes
additional facts from the elaborated declarations and passes an immutable
backend input beside `CProgram`.

### 3.1 LLVM semantic input

X-N.H replaced the LLVM install surface with immutable `llvm_emit.EmitInput`.
Every LLVM product/probe constructs it from the declaration-derived method,
constraint, constructor, signature, main-kind, split-half, prelude-symbol, source,
and record-order facts that route already produced. `emitProgram`, record mode,
and the gap census require that value; one fresh per-emission `Emit` context owns
the remaining physical state.

### 3.2 Wasm semantic input

X-W.H1 is complete: `wasm_emit.makeWasmEmitInput` builds one immutable
`WasmEmitInput` from method-interface metadata, declaration signatures,
constructor field types, the main-Float hint, and record field orders. Both
`emitProgram` and `emitProgramGaps` receive it explicitly; `Prog` carries it to
the semantic readers. Product and probe entries retain their previous populated
or omitted values rather than being equalized. Declaration-order first-match
indexes are built once in the input.

The old Wasm install hooks and the shared `emit_support` method-metadata Refs are
gone. X-W.H2b.1 moved gap mode, event logging, and binding attribution into a
fresh private `WasmEmit`; X-W.H2b.2 adds passive string-segment state, and
X-W.H2b.3 adds the scoped impl-self tail-emission context. X-W.H2b.4 moves the
two synthesized-default facts (seen names and definition blocks) from three
ambient cells into that same context; the ordered name list was duplicate
authority and was removed. `emitProgram`, `emitProgramRecord`, and
`emitProgramGaps` each mint the context, `Prog` routes default membership/writes,
and `emitRefProgram` drains its definitions in the existing reverse/flatten
order. X-W.H2b.5 moves current diagnostic-binding attribution into `WasmEmit`:
fresh calls start at `?`; top-level `P`, nested `lg:P`, and the existing post-lift
`lg:L` dynamic extent remain explicit. X-W.H2b.6 moves the Stage-1 TRMC context
into `WasmEmit`'s `trmcCtx`. X-W.H2b.7 moves lambda IDs, ordered lifted definitions,
named-lift de-duplication, and function-reference list/set state into `WasmEmit`;
former lifted-name Ref was unread duplicate authority and is retired. X-W.H2b.8 moves
the coded-stderr-trap import event into `WasmEmit`'s `trapImportNeeded`. X-W.H2b.9
moves divisor-local, record-update-local, RNG, hash, and stderr-runtime demand into
`WasmEmit`; trap-only emissions still import the byte writer without the stderr runtime. The typed
entry and `test/wasm/diff_wasm_typed.sh` grade strict, record, census, and
no-writer isolation. X-W.H2b.10 moves one fact, `hashFloat` runtime demand, into
`WasmEmit`; census coverage is ownership-only. The re-derived remaining ambient
top-level `Ref` population is 24, in output, feature, numeric, and dispatch families.
H2b and #1407 remain open; those four families remain X-W.H2 work.

### 3.3 Per-program derived indexes

`llvm_emit.emitProgram` also builds indexes in its per-emission `Emit` context,
including `knownFnMap`, `lazyGlobalMap`, `ctorMap`, `sigMap`, `defArityMap`,
`ctorTypeMap`, `recByName`, `recByLabel`, and implementation-group indexes.
Wasm builds a parallel `Prog` value plus module-level indexes and feature flags.

These indexes improve asymptotic behavior when they are caches of authoritative
data. They become semantic authorities when the underlying fact was absent from
Core. That distinction is not represented in their types.

## 4. Decisions reconstructed below Core

| Judgment | LLVM implementation | Wasm implementation | Shared/upstream fragment |
|---|---|---|---|
| Scalar/runtime type | `LTy`, `inferSigs`, `typeOf`, `paramUseTy`, inline `emitExpr` recovery | `WTy`, `cexprIsFloat`, `refMainKind`, Float registries | partial `CBinPrim` stamp |
| Method/source arity | `methodArityOf`, definition/call helpers | `methodArityOfW`, closure eta/application helpers | arrow-spine table from `core_ir_lower` |
| Exact/PAP/over-application | `emitApp`/`emitOverApp` plus `emitPapClosure`/`emitMethodPap`/`emitCtorPap` families | closure arity plus `$mdk_apply` branches | none |
| Record field slot | bare-name record and label indexes | `recFieldsRef` and record-name lookup | record-name strings on some nodes |
| Dispatch arm/default | `implEntryRouteWords`, dispatch/default chain synthesis | `implEntryRouteKeyW`, dispatch chains, incomplete default synthesis | `Route` plus incomplete `CImplEntry` set |
| Closure captures/layout | LLVM free-variable and allocation paths | Wasm closure-use scan and lifted functions | none |
| Global forcing | native realization of shared classification | Wasm realization of shared classification | `emit_support.eagerReachMap` / `lazyGlobalNames` |
| Tail/TRMC realization | `musttail`, destination cells, dispatch-group inlining | `return_call`, typed destination structs | `trmc_analysis` eligibility/groups |
| Link symbols/tags | LLVM sanitization and tagged-word spaces | WAT identifiers and i32 tag spaces | `private_mangle`, dense logical ctor ordinals |
| Extern capability/runtime group | LLVM extern predicate ladders and C declarations | Wasm extern ladders and host/runtime inclusion flags | `stdlib/runtime.mdk` plus capability ledgers |

The table is the central current-state finding. Core is a shared syntax, but the
backends remain partial typecheckers, linkers, closure converters, and runtime
planners.

## 5. Shared architecture that already works

Three existing modules establish the useful boundary:

| Module | Shared decision | Backend-specific realization |
|---|---|---|
| `backend/trmc_analysis.mdk` | TRMC eligibility and dispatch groups | LLVM destination/GEP lowering versus Wasm mutable struct/`return_call` lowering |
| `backend/emit_support.mdk` | eager reachability, lazy-global classification, fallthrough labels | force-cell layouts, blocks, calls, and text |
| `backend/private_mangle.mdk` | pre-flatten module disambiguation | final LLVM/WAT symbol legality and collision domains |

The #553/#561 global-init arc is both precedent and warning. Sharing the
analysis fixed two backends together, but the earlier shared walk omitted
subexpressions and calls, making both compiled engines wrong. Shared code removes
drift; it does not prove the shared decision.

## 6. Physical divergence

The representations are intentionally different, as ratified by
`RUNTIME-DESIGN.md` section 8.6.

| Concern | LLVM/native | WasmGC |
|---|---|---|
| Value slot | uniform tagged `i64` word | `(ref eq)` in ref mode; raw `i64` scalar mode for a restricted program |
| Int | 63-bit low-bit-tagged immediate | i31 immediate or `$boxint`; scalar mode raw `i64` |
| Heap | Boehm-managed cells with word headers | typed GC structs/arrays |
| Float | boxed cell, with local unboxing optimizations | `$float` struct |
| Closure | code pointer + arity/captures in native cell | typed `$clos` with code ref, arity, captures |
| Control | LLVM CFG/SSA/phi nodes | structured blocks, typed branches |
| Tail calls | `musttail` where legal, plus LLVM TMC realization | `return_call` / `return_call_ref`, plus Wasm TMC realization |
| Runtime | `runtime/medaka_rt.c`, Boehm, libc/libm | WAT preamble plus JS host imports |
| Toolchain | textual LLVM -> `clang` | WAT -> `wasm-tools` |

One physical plan cannot honestly serve both. The shared boundary can describe a
logical field ordinal, call mode, capture order, or trap; it cannot prescribe an
LLVM byte offset or a Wasm struct field type.

Wasm scalar mode is a second physical lowering selected at whole-program scope
by `useRef`. It previously required a separate Int-normalization fix because no
box seam exists there. Its target status must be decided by measured value, not
preserved merely because it exists or removed merely because it duplicates code.

## 7. State lifecycle and determinism

Both emitters rely on module-level `Ref`s. Some are ordinary local mutation
(output buffers, counters) and some are scoped emission contexts. Wasm
declaration-derived semantic input is no longer installed through Refs (X-W.H1);
H2b has moved its gap lifecycle, string, impl-self, TRMC, lifting, function-reference,
and coded-trap-import plus H2b.9/H2b.10 feature-demand lifecycle into fresh `WasmEmit` contexts. The remaining 24
top-level ambient Refs are X-W.H2 output, feature, numeric, and dispatch families.

The product driver shells out to a fresh emitter process specifically to obtain
pristine state. Within one process:

- LLVM constructs a fresh `Emit` record but also resets/installs external refs;
- Wasm creates a fresh `WasmEmit` for strict, record, and gap-census calls; gap
  lifecycle, passive string segments, impl-self scope, Stage-1 TRMC context,
  lambda/lifted-definition/function-reference state, coded-trap-import state, H2b.9/H2b.10 feature demand, and
  synthesized-default membership/definition buffers belong there; the remaining
  24 ambient top-level Refs are output, feature, numeric, and dispatch families;
- gap-census paths own a separate gap lifecycle but still duplicate the remaining
  physical setup;
- X-W.H2 still owns the remaining physical-state lifecycle.

Fresh-process isolation is a useful defense, not proof that emission is a pure
function. The current architecture cannot express `emit : Program -> Output`
without ambient prerequisites.

Determinism is nevertheless strongly enforced on the native path by the
self-compile fixpoint. `prelude.o` also requires program-independent prelude
bodies and stable outlining. Any migration has to preserve those properties,
not merely observable output.

## 8. Runtime and host trusted boundaries

Native code relies on `runtime/medaka_rt.c` for allocation, process setup,
externs, arithmetic helpers, traps, and IO. The emitted program runs on a
GC-registered worker thread with a large stack. Boehm is a settled physical
choice, not a shared semantic requirement.

Wasm code embeds more runtime behavior in the WAT preamble and delegates parts
of observable semantics to host JavaScript. The host set is derived from the
shared-shim markers in `test/wasm/run.js`, `playground/worker.js`, and
`playground/compile.mjs`; hard-coded counts have repeatedly omitted a host.
Formatter/parser behavior, stderr flushing, exits, path/result byte channels,
and capability failures are therefore part of the Wasm backend's trusted base.

## 9. Gate coverage and blind spots

| Gate | Property sampled |
|---|---|
| `test/selfcompile_fixpoint.sh` | native emitter reproduction/determinism |
| `test/typecheck_compiler_source.sh` | compiler source is well typed |
| `test/diff_compiler_engines.sh` | eval/native/Wasm observations agree on enrolled programs |
| `test/diff_compiler_llvm*.sh` | native emitted output and typed-IR shapes |
| `test/wasm/diff_wasm*.sh` | WAT assembly, validation, and behavior |
| `test/diff_compiler_tmc_parity.sh` | shared TMC population parity |
| `test/diff_compiler_dispatch_shape.sh` | outlined dispatch and prelude independence |
| `test/diff_compiler_capability_matrix.sh` | extern existence/disposition and pure-domain ledger |
| `test/diff_compiler_wasm_shim_parity.sh` | every marker block declared by reference host `run.js` is present and byte-identical across marker-discovered hosts (WH3); not symmetric key-set completeness |
| `test/diff_compiler_perf_scaling.sh` | selected allocation/time growth classes |
| `test/diff_compiler_must_fail.sh` | open verified issue still reproduces |

The gates do not prove:

- a decision shared by every engine is semantically correct (#1265);
- a probe installed the same metadata as the product path (#587);
- a new table cannot affect unrelated modules;
- a wildcard arm handled a new IR constructor;
- a constant-factor allocation regression is absent;
- a named tracker is still open or its prose still describes current code.

## 10. Historical conclusions to retain or retire

| Prior conclusion | Current verdict |
|---|---|
| Core IR should remain above an ISA | Retain |
| Build a bytecode VM before LLVM (`STAGE2-DESIGN.md`) | Retire; the VM experiment was abandoned and LLVM is canonical |
| Share TRMC analysis, not target mechanics | Retain; proven by two backends |
| Install tables are a principled permanent seam (`ARCH-REVIEW.md`) | Revisit; they now carry semantic facts omitted from Core and differ by entry/backend |
| Extract LLVM `LTy` as a module | Retire as target direction; `LTy` is physical, while the missing input is a backend-neutral runtime type |
| Wasm mirrors LLVM concern-by-concern | Retire as architecture; it produced parallel judgments and repeated one-backend fixes |
| One physical representation is needed for one language | Rejected and still rejected; the abstract contract is shared, physical encodings are peers |
| Parity is the primary backend assurance | Retain only as one sample; shared wrongness requires clause-derived conformance tests |

## 11. Architectural pressure points

The current map yields seven target requirements without yet prescribing their
implementation:

1. The elaboration/Core output must be a semantic closure for backend consumers.
2. Semantic identity, evidence, call shape, type facts, and layout cannot be
   reconstructed from spelling or declaration scans.
3. Shared transformations must make evaluation order and failure explicit.
4. Whole-program analyses must produce immutable, validated decisions once.
5. LLVM and Wasm physical planning must remain distinct.
6. Serializers must consume complete plans without ambient semantic state.
7. Conformance must include malformed-plan rejection, unrelated-code controls,
   and hand-derived expected behavior, not parity alone.
