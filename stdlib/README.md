# Medaka stdlib

<!-- Verified against native compiler, 2026-07-16 -->

## `runtime.mdk` — built-in extern catalog

`stdlib/runtime.mdk` is the authoritative source of type signatures for all
`extern` primitives — the native operations exposed to Medaka programs. It is
read from disk at compiler startup (no embed/generation step).

### Adding a new primitive

The canonical, step-by-step procedure — declaring the signature in
`runtime.mdk`, implementing it in `compiler/eval/eval.mdk`, and (if the
primitive must also work under `medaka build`/the WasmGC playground) wiring
it into the LLVM and/or WasmGC backends, plus the `test/diff_compiler_capability_matrix.sh`
gate that checks all three engines agree — is documented in
[`.claude/skills/add-primitive/SKILL.md`](../.claude/skills/add-primitive/SKILL.md).
Follow that; this file does not duplicate it.

### Convention

- Pure functions: no effect annotation (`extern foo : a -> b`).
- Effectful operations carry an effect on the **return type**, read
  automatically by the effect checker — e.g. `<Stdout>`, `<Stdin>`,
  `<FileRead "_">`, `<Net "_">`, or the coarser `<IO>` alias. See existing
  entries in `runtime.mdk` for examples of each. Mutation (e.g. `setRef`) is
  **untracked** — it carries no effect label at all, since 2026-07-14 (the
  old internal-label class, which included `<Mut>` and `<Panic>`, was removed
  outright; see `runtime.mdk:215` and `docs/stdlib/STDLIB.md` §"Design
  resolution — panic vs exit").
- Type variables in extern signatures are implicitly universally quantified.
- A handful of unsafe externs (`arrayGetUnsafe`, `arraySetUnsafe`, `arrayBlit`,
  `arrayFill`, `bytesToFloat64`) are restricted to trusted roots — see
  `internalExterns` in `compiler/frontend/resolve.mdk` and the `--allow-internal`
  CLI flag — if your primitive is similarly unsafe, follow that pattern. A
  project may also opt in from either its `[package]` or `[project]` manifest
  section with the canonical unquoted boolean `allow-internal = true`. An
  optional trailing `#` comment is permitted; quoted `"true"`, `false`, malformed
  values, comment text, and a dependency named `allow-internal` do not grant the
  privilege.

## API conventions

Ratified by #2306's surface-freeze sheet (leg 9). These govern the *library*
surface — `stdlib/*.mdk` modules other than `runtime.mdk` — not the extern
catalog above. `docs/stdlib/inventory.json` and
`test/diff_compiler_stdlib_conventions.sh` (below) enforce what a mechanical
check can catch; the rest is judgment a reviewer applies by hand. Full
reasoning and the counter-example each rule exists to protect: PR #2429
(issue #2306, leg 9). The sentences below are the durable record.

1. **A total peer of a partial prelude name is licensed exactly when the
   type makes it total.** `nonempty.head : NonEmpty a -> a` beside
   `list.head : List a -> Option a` is correct — a non-empty type discharges
   the partiality the `Option` exists to signal, so this is not "varying a
   return shape" in the sense rule 5 forbids.
2. **A module may re-export a monomorphic specialization of a prelude
   generic when it is a measured fast path or a named layer boundary** —
   `array.find` avoids a dictionary lookup on a hot container; `time.now`
   keeps `runtime` the primitive-only page. It is not licensed as a bare
   convenience alias.
3. **Data-last is the default, with a stated exception for resource handles
   and run/parse subjects.** A resource handle (`net`'s `Connection`), the
   subject of a `run`/`parse` verb (`byteparser.runBP`, `args.parseArgs`),
   or a `memmove`-shaped bulk copy (`array.blit`) takes its principal
   argument first — the pipeline idiom data-last serves does not fit any of
   the three.
4. **A `runtime` extern returning a raw tuple should have a typed library
   peer** returning a named record (`fs.stat` over
   `runtime.statFile`'s tuple) — the extern stays; the pair is not
   duplication, it's the primitive layer doing its job.
5. **Hash containers carry only the order-independent operations of their
   ordered peers.** `union`/`unionWith`/`difference`/`intersectionWith`/
   `filterWithKey`/`adjust`/`insertWith`/`mapWithKey`/`singleton`/
   `isSubsetOf`/`elems` are fair game to add to `hash_map`/`hash_set`
   eventually; `minView`/`maxView`/`getMin`/`getMax`/`deleteMin`/`deleteMax`
   and any order-promising `foldlWithKey`/`foldrWithKey` are not — they are
   meaningless without an order. This parity gap is a deliberate, standing
   deferral, not sprint residue.
6. **`toml` has no renderer, deferred behind #2240, on the record.** The
   asymmetry with `json` (parse + stringify) is real and acknowledged;
   `impl Display Toml` is a debug rendering, not TOML syntax, and not a
   substitute.
7. **`isEmpty` is a `Foldable` method, not a per-module function.** A
   container gets `isEmpty` for free by having a `Foldable` impl (the
   default method). Do not declare a module-level `isEmpty` on a `Foldable`
   container — it would shadow the interface method, not complete the
   surface. `map`/`hash_map` carry their own only because they are not
   `Foldable`.
