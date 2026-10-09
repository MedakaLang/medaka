---
name: add-primitive
description: Add or modify a native stdlib extern — signature in stdlib/runtime.mdk, implementation in compiler/eval/eval.mdk. Use when a built-in can't be written in Medaka.
---

# Add a stdlib primitive (extern)

**This file is the canonical procedure** — `stdlib/README.md` points here
rather than duplicating it.

Primitives are the native operations exposed to Medaka programs. Their
signatures live in `stdlib/runtime.mdk` (read from disk by the compiler at
startup — no generation/embed step) and their implementations are native,
one per execution engine: the tree-walking interpreter
(`compiler/eval/eval.mdk`, used by `medaka run`/`test`/`repl`), the LLVM
backend (`compiler/backend/llvm_emit.mdk`, used by `medaka build`), and the
WasmGC backend (`compiler/backend/wasm_emit.mdk`, used by the browser
playground). **A new primitive minimally needs the interpreter**; whether it
also needs the two compiled backends depends on where it must run — see step
2 and step 4.

When you write **Medaka** code (e.g. wrappers in `core.mdk`/`list.mdk`), use
`x y => body`, never curried `x => y => body`.

## Steps

1. **Declare the signature** — add an `extern` line to `stdlib/runtime.mdk`:
   ```
   extern foo : a -> b
   ```
   Put an effect annotation on the **return type** if the operation is
   effectful — the effect checker reads these automatically:
   - pure → no annotation
   - IO → `<IO>`, or a finer-grained tag if one fits: `<Stdout>`, `<Stdin>`,
     `<FileRead "_">`, `<Net "_">` (see existing entries in `runtime.mdk` for
     examples of each)
   - every effect label is a host capability — there is no internal/purity
     label class. Mutation via refs and `panic`/unrecoverable exit carry no
     effect row at all (untracked); don't reach for `<Mut>`/`<Panic>` — those
     labels were removed from the language 2026-07-14.
   Type variables are implicitly universally quantified.

2. **Implement it in the interpreter** — add a matching `("name", primN ...)`
   entry to the `externBindings` list in `compiler/eval/eval.mdk` (search for
   `export externBindings`), or to `ioExternBindings` a bit further down if
   it's real host I/O (file/env/stdin/clock — `ioExternBindings` overrides
   `externBindings` only under `medaka run`'s driver; other consumers, like
   the differential oracle, need an effect-free-observable stand-in in
   `externBindings`). The name must match the extern exactly — a startup
   completeness check fails at runtime if `runtime.mdk` and the interpreter's
   bindings disagree.

3. **Rebuild** — `make medaka`. This recompiles the native compiler from
   `compiler/` source; the new extern becomes visible to the type checker and
   evaluator immediately.

4. **Wire up the compiled backends, or record the gap.**
   `compiler/backend/extern_catalog_gate_test.mdk` checks that every extern in
   `runtime.mdk` has a row in `compiler/backend/extern_catalog.mdk`, which
   names how each of the three engines (interpreter/LLVM/wasm) handles it; an
   engine that does not lower it gets a `NotProvided` disposition with a kind
   and a reason (read `test/CAPABILITY-MATRIX.md` for the kind vocabulary —
   `BUG`/`TODO`/`PERMANENT`/`WASM-GAP`/etc). If the
   primitive only needs to work under `medaka run`, file `NotProvided` for
   `llvm`/`wasm` with an honest reason instead of implementing it there. If it
   must also work under `medaka build` or the wasm playground, add dispatch
   for it: for llvm, give the row an `LlvmFamily` in its llvm column and add the
   clause to that family's emitter in `compiler/backend/llvm_emit.mdk`
   (`externEmitter` maps families to emitters, so `isAnyExtern` and
   `emitExternApplied` follow the row); for wasm, give the row a `WasmFamily`
   in its wasm column and add the clause to that family's emitter in
   `compiler/backend/wasm_emit.mdk` (`emitAppRef` selects it by `wasmFamily`),
   and list every runtime group the lowering needs in `wasmUseRows` (a `WasmUse`
   per `WasmEmit.use*` flag, implied ones written out). Run the gate and the
   catalog's sibling test, which checks those demands and the WAT they produce:
   ```sh
   MEDAKA_STRICT=1 ./medaka test compiler/backend/extern_catalog_gate_test.mdk
   MEDAKA_STRICT=1 ./medaka test compiler/backend/extern_catalog_test.mdk
   ```

## Verify

```sh
./medaka test stdlib/core.mdk        # run doctests
./medaka check stdlib/runtime.mdk    # extern signatures parse cleanly
```

Write an end-to-end program that calls the primitive and confirm it runs:

```sh
./medaka run scratch.mdk
```

For a broader gate, run the diff suite that exercises eval, plus the
capability matrix if you touched more than the interpreter:

```sh
bash test/diff_compiler_eval.sh
bash test/diff_compiler_check_test.mdk
./medaka test compiler/backend/extern_catalog_gate_test.mdk
```
