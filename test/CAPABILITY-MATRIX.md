# CAPABILITY-MATRIX.md — which engine implements which extern

**Status:** LIVE. Prose explanation of what `compiler/backend/extern_catalog_gate_test.mdk` proves. The data is the extern catalog, `compiler/backend/extern_catalog.mdk`.

## The bug this exists to catch

Medaka has three execution engines that each must independently implement
every `extern` primitive declared in `stdlib/runtime.mdk`:

- the tree-walking **interpreter** (`compiler/eval/eval.mdk`) — runs
  `medaka run` / `medaka test`
- the **LLVM backend** (`compiler/backend/llvm_emit.mdk`) — runs `medaka
  build`
- the **WasmGC backend** (`compiler/backend/wasm_emit.mdk`) — runs `medaka
  build --target wasm`

`eval.mdk` was originally written as a *value oracle* for differential
testing against the (now-deleted, 2026-06-26) OCaml reference compiler — it
only ever needed to compute `main`'s value, so effectful/IO externs
(`readFile`, `exit`, …) were legitimately out of scope. When OCaml was
removed, `eval.mdk` was silently promoted to be the production `medaka run`
engine and its contract was never re-litigated. The result: **a block of
externs type-checked GREEN and then panicked at runtime** with `unbound
identifier: X` under `medaka run` — including a *pure* extern with no effect row at all
(`arraySortBy`). Nothing in `test/` or `scripts/` ever compared the three
engines' extern coverage against each other, so this drifted silently for
weeks.

The catalog and its gate are the fix. Every extern has one row naming how each
engine handles it, and a gap is a `NotProvided` row that must carry a kind and
a reason, so an extern an engine does not lower can no longer be absent
without a stated cause.

## How to read it

`compiler/backend/extern_catalog.mdk` holds one `ExternRow` per extern, with
the llvm, wasm and eval dispositions. A `NotProvided` disposition carries one
of these kinds:

| Category | Meaning |
|---|---|
| `BUG` | Works in ≥1 other engine; this engine's gap is a real regression to fix. |
| `DEAD` | Declared but not called by current stdlib code (superseded by a rewrite); still directly reachable by a user program. |
| `TODO` | Unimplemented everywhere — a forward-declared primitive with no caller yet, not an asymmetric gap. |
| `PERMANENT` | Structurally unavailable on this engine (e.g. WasmGC has no raw-socket equivalent, and no wasm profile grants `Exec`). |
| `WASM-GAP` | Unported to WasmGC; a lowering is possible, just not written. |

Two other dispositions are bound but are not the extern's meaning: `TrapStub`
lowers to an abort (better than a silent wrong value, still not real), and
`FrozenConstant` is bound to a fabricated value (worse than missing, because
it is silent instead of a loud panic).

## What is checked, and where

- `compiler/backend/extern_catalog_gate_test.mdk` (registry gate
  `diff_compiler_capability_matrix`): every `stdlib/runtime.mdk` extern has
  exactly one row and no row names an undeclared extern; each `NotProvided`
  row has a reason; and every pure extern (no capability in its signature) has
  one verdict in `test/EXTERN-DOMAIN-LEDGER.txt`. Each check names the extern
  it fails on.
- `compiler/backend/extern_catalog_test.mdk`: the catalog has exactly the
  externs `stdlib/runtime.mdk` declares; every wasm family an application
  dispatches through has members; a wasm runtime demand (`wasmUses`) is listed
  only for a wasm-bound extern; each demand has exactly its producers; its eval
  column equals the interpreter's binding tables; and the WAT `wasm_emit.mdk`
  emits for a program reaching an extern contains each runtime group the row
  demands.
- `compiler/backend/core_validate.mdk`: a `NotProvided` llvm or wasm column is
  refused before emission, at every reference to that extern, with the row's
  kind and reason. Tests: `compiler/backend/core_validate_test.mdk`,
  `test/wasm/diff_wasm_ffi_wall.sh`.

## How to add a new primitive without breaking an engine

Follow `.claude/skills/add-primitive` (or the manual version below).

1. **Declare it** in `stdlib/runtime.mdk`: `extern myThing : T1 -> <Effect> T2`.
   The gate fails and names `myThing` until it has a row.
2. **Add its row** to `compiler/backend/extern_catalog.mdk`, in declaration
   order. An engine that does not lower it gets `NotProvided <kind> "<reason>"`
   — nothing else needs editing for that to be green.
3. **Interpreter**: implement it in `compiler/eval/eval.mdk` and add the
   `("myThing", ...)` entry to the binding table. The row's eval column is
   `Interpreted`.
4. **LLVM** and **WasmGC**: the row's llvm / wasm family selects the emitter
   arm, so give the row an `LlvmFamily` / `WasmFamily`, write the arm in
   `llvm_emit.mdk` / `wasm_emit.mdk`, and list the runtime groups the wasm
   lowering needs in `wasmUseRows`. `extern_catalog_test.mdk` reds if a listed
   demand is not emitted in the WAT.
5. If the extern is pure, give it a verdict in `test/EXTERN-DOMAIN-LEDGER.txt`.

If you deliberately do not support a primitive on one engine (e.g. it has no
meaning there, like `net*` on wasm), file it `PERMANENT` with a real reason
instead of skipping the gate. The reason is printed verbatim in the refusal
`compiler/backend/core_validate.mdk` raises, so write it for the user who
reads it; the `net*` rows' reason (`wasmNoSockets` in
`compiler/backend/extern_catalog.mdk`) is the model.
