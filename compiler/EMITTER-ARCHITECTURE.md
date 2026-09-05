# Emitter Architecture - the derived current map

**Status:** CURRENT - source-derived LLVM/WasmGC emitter map, re-derived 2026-09-03 at `7132909b7`
(zero ambient state on both backends; `wasm_reach`; `EmitTarget`; the playground divergence).
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
       -> core_ir_lower.lowerProgramEmit <EmitTarget>   (TargetNative | TargetWasm | TargetBothUnknown)
       -> CProgram
            -> llvm_emit.emitProgram -> LLVM text -> clang -> native binary
            -> wasm_reach.wasmReachFilter (Wasm product paths only, post-lower)
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
`wasm_emit_modules_main` leaves the browser compiler on the old seam. The
duplication is deliberate for the wrap glue (the browser reports elaboration
failures as JSON diagnostics, not `failWith`), but the two `emitTail` bodies
had already diverged by 2026-09-03: `playground_main` passed `[]` where the
product entry passes the validated FFI extern table, so a user FFI extern in
the browser died as an unbound variable instead of the named WasmGC rejection.
Fixed by the 2026-09-03 parity change; the shape remains a trap.

Two things entered this pipeline after the 2026-08-07 map without a doc row.
`backend/wasm_reach.mdk` (#2359/#2377) is a second, dispatch-rooted
reachability pass over the lowered `CProgram`, on both Wasm product paths and
on neither native path: a whole-program analysis that exists on one backend.
`lowerProgramEmit` takes an `EmitTarget` first parameter (#1970): only
`TargetNative` narrows anything (it relaxes the 30-bit Wasm `dictTag`
collision check), so a physical fact is threaded up into the shared lowering
seam. Both are absorbed by the shared plan record in
`EMITTER-TARGET-ARCHITECTURE.md` R5.

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

```medaka-nocheck: type-shape sketch naming CProgram's four list fields, not a declaration
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
`WasmEmit`; census coverage is ownership-only. X-W.H2b.11 moves `charFromCode`
runtime demand into `WasmEmit`; census coverage is ownership-only. CharClass, FloatRng,
StrCodec, and Math-import demand follow the same per-emission ownership. Value comparison,
String-to-Float, process-argument, and byte-file runtime demand now use that carrier too;
the byte-file controls separate read and write producers and execute only against a
gate-owned temporary path. The remaining fifteen ambient cells were lifted onto
`WasmEmit` in one commit (`d0217232e`, PR #1947, 2026-08-25); `wasm_emit.mdk`
has held zero module-level `Ref` cells since, and
`test/wasm/diff_wasm_typed.sh` pins the set at empty. X-W.H is complete.

### 3.3 Per-program derived indexes

`llvm_emit.emitProgram` also builds indexes in its per-emission `Emit` context,
including `knownFnMap`, `lazyGlobalMap`, `ctorMap`, `sigMap`, `defArityMap`,
`ctorTypeMap`, `recByName`, `recByLabel`, and implementation-group indexes.
Wasm builds a parallel `Prog` value plus a per-emission `WasmEmit` context
holding its indexes and feature flags. Neither backend has module-level state
left; `Emit` carries 42 `Ref` fields and `WasmEmit` 54 (derive:
`sed -n '/^data EmitData/,/^}/p' compiler/backend/llvm_emit.mdk | grep -c ': Ref '`
and the `WasmEmit` peer). The two records are disjoint: `WasmEmitInput` is a
13-field positional constructor carrying four fewer semantic facts than
`EmitInput` (`returnsSelf`, `selfFnParams`, `methodConstraintIfaces`,
`mainIsUnit`), so the two backends do not receive the same semantic program.

These indexes improve asymptotic behavior when they are caches of authoritative
data. They become semantic authorities when the underlying fact was absent from
Core. That distinction is not represented in their types.

## 4. Decisions reconstructed below Core

| Judgment | LLVM implementation | Wasm implementation | Shared/upstream fragment |
|---|---|---|---|
| Scalar/runtime type | `LTy`, `inferSigs`, `typeOf`, `paramUseTy`, inline `emitExpr` recovery | `WTy`, `cexprIsFloat`, `refMainKind`, Float registries | partial `CBinPrim` stamp |
| Method/source arity | the `methodArityOfInput`/`Iface`/`Entry`/`Tag`/`Route` family (split from one function 2026-08-21 to 08-27) | the `methodArityOfW`/`InputW`/`IfaceW`/`EntryW`/`TagW` family | arrow-spine table from `core_ir_lower` plus the impl clause's own pattern count (#1034) |
| Exact/PAP/over-application | `emitApp`/`emitOverApp` plus `emitPapClosure`/`emitMethodPap`/`emitCtorPap` families | closure arity plus `$mdk_apply` branches | none |
| Record field slot | `Emit.recByName`/`recByLabel`/`recFields` | record-name and label indexes built into `WasmEmitInput` | record-name strings on some nodes; ordinals nowhere |
| Dispatch arm/default | `implEntryRouteWords`, dispatch/default chain synthesis | `implEntryRouteKeyW`, dispatch chains, incomplete default synthesis | `Route` plus incomplete `CImplEntry` set |
| Closure captures/layout | LLVM free-variable and allocation paths | Wasm closure-use scan and lifted functions | none |
| Global forcing | native realization of shared classification | Wasm realization of shared classification | `emit_support.eagerReachMap` / `lazyGlobalNames` |
| Tail/TRMC realization | `musttail`, destination cells, dispatch-group inlining | `return_call`, typed destination structs | `trmc_analysis` eligibility/groups |
| Link symbols/tags | LLVM sanitization and tagged-word spaces | WAT identifiers and i32 tag spaces | `private_mangle`, dense logical ctor ordinals |
| Extern capability/runtime group | LLVM extern predicate ladders and C declarations | Wasm extern ladders and host/runtime inclusion flags | `stdlib/runtime.mdk` plus capability ledgers |

The table is the central current-state finding. Core is a shared syntax, but the
backends remain partial typecheckers, linkers, closure converters, and runtime
planners. Measured 2026-09-03: 767 top-level signatures in `llvm_emit.mdk`, 667
in `wasm_emit.mdk`, 89 named twins (31 identical names, 58 `W`-suffixed), 40
of them in dispatch/defaults, evidence rewriting, arity/eta/PAP, and impl
indexing. Derive with a signature grep on each file and `comm -12`.

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

Neither emitter has module-level `Ref`s (since PR #1947, 2026-08-25; the
lowering stage followed in PR #2457, 2026-09-01). LLVM constructs a fresh
`Emit` per emission; Wasm constructs a fresh `WasmEmit` for strict, record, and
gap-census calls; both take their semantic input as an explicit immutable
argument. Same-process re-emission isolation is gated on the Wasm side
(`test/wasm/diff_wasm_typed.sh`, P -> U -> P) and structurally on the LLVM side
(`test/diff_compiler_llvm_typed_ir.sh`'s X-N.H2 ratchet).

The product driver still shells out to a fresh emitter process. That is now a
defense in depth rather than the only source of pristine state. What remains
impure is not ambience: it is that 96 mutable cells across two disjoint
per-emission records are where semantic decisions are still made, and their
types do not distinguish a cache of an authoritative fact from the authority
itself (section 3.3).

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
8. (added 2026-09-03) A physical fact must not travel up into the shared
   lowering seam. `EmitTarget` on `lowerProgramEmit` is the live instance.
9. (added 2026-09-03) A whole-program analysis that exists on one backend only
   (`wasm_reach`) is a divergence, not a feature; it becomes shared or it is
   named as a Wasm physical choice.

How these are met is `EMITTER-TARGET-ARCHITECTURE.md`'s REVISION block
(R3-R9): Core IR grown one fact at a time, one shared plan record, a Core
validator, no new intermediate representations.
