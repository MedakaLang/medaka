# Medaka stdlib

**Status:** LIVE. Conventions for writing stdlib modules and their doc comments.

<!-- Verified against native compiler, 2026-07-16 -->

## Writing documentation

`medaka doc` renders `stdlib/*.mdk` into the published reference
(`docs/stdlib/`, served at `medaka-lang.dev/stdlib`). The reference is
generated from the source, so the doc comments *are* the documentation.
These rules say what a doc comment is, what goes in it, and how it should
read.

### What renders

- **A doc comment is a `{- | ... -}` block, or a run of `-- |` lines, directly
  above a declaration.** Only marked comments render. An unmarked `--`
  comment is a note to maintainers and never reaches the reference, wherever
  it sits. Put a note directly above the doc block, not under it: `medaka
  test` reads comment lines directly under an example as its expected
  output, and a note separated from the block by a blank line becomes the
  declaration's only comment, which hides the doc.
- **A module header is a `{- | ... -}` block at the top of the file.** Its
  first sentence is the module's one-line summary in the library index.
- **A section heading is a standalone `-- # Title` comment** between
  declarations. Sections group a page and appear in its table of contents.
  Use them on any module with more than a screenful of entries.
- **An example is a `> expr` line followed by its result** inside a doc
  comment. `medaka test` runs every example, so a rendered example is a
  verified one. The same `-- > expr` form in an unmarked comment is still run
  by `medaka test` but not rendered: put edge-case checks there, or in a
  `prop`, and keep the doc comment's examples illustrative.
- Instances (`impl`) need no doc comment. The generator lists them under
  their type. Give an instance its own doc comment only when it has
  behavior a reader must know about, such as `Ord Float`'s treatment of NaN.

### What a doc comment contains

The signature is printed above the prose, so the prose never restates the
type. It says what the signature cannot.

1. **A first sentence that stands alone.** It is the summary a reader skims,
   and it must make sense with nothing after it. Write it as a statement
   about the result, in the form "Returns the list in reverse order" or "The
   first element, or `None` when the list is empty". Do not start with the
   function's name.
2. **A short paragraph for behavior the signature does not show**, only
   when there is some: what happens at the boundaries (empty input, negative
   count, out-of-range index), which occurrence wins, whether order is
   preserved, what is clamped and what panics. One paragraph is the usual
   maximum.
3. **One or two examples** that show the typical call. An example is not a
   test; the boundary cases that only prove a claim in point 2 go in an
   unmarked comment or a `prop`.
4. **For container modules only, the cost**, as `O(log n)` in the paragraph,
   when it is what a reader chooses the operation by.

Everything else stays out. In particular:

- **No history.** Issue numbers, PR numbers, what a function used to do, who
  decided what, and why a name was chosen belong in git and the issue
  tracker. A doc comment describes the function as it is.
- **No implementation notes.** How a function is built (doubling, an
  accumulator, a merge sort) is a maintainer's concern. If it matters to the
  caller, state the consequence (`O(log n)` call depth, stable, tail-recursive
  and safe on long lists) not the mechanism. Mechanism goes in an unmarked
  comment beside the code.
- **No warnings to maintainers.** "Do not delete", "load-bearing", and their
  relatives are maintainer notes; write them as unmarked comments.
- **No comparisons to other languages** and no rationale. The reference says
  what a function does, not why it is not Haskell's.

### How it reads

- Plain, direct sentences. One idea per sentence.
- No em-dashes. Use a comma, a full stop, or parentheses.
- No emphasis for warning: no capitals, no bold, no emoji. If a fact matters,
  say it in a sentence.
- Name arguments in backticks when the prose refers to them (`n`, `sep`,
  `xs`). Name other functions the same way, and qualify them with the module
  when they live elsewhere (`string.split`, `map.Map`).
- Prefer "when" to "if" for conditions on values: "empty when `n <= 0`".
- Say `None`, `Some`, `Ok`, `Err` for results; say "panics" only for
  operations that actually panic, and say what panics.

A finished entry looks like this:

```
{- | The elements at indices `[lo, hi)`.

   Indices are clamped to the list, so an out-of-range slice is shorter
   rather than a panic. `xs.[lo..hi]` is the panicking form.

   > sliceClamped 1 3 [10, 20, 30, 40]
   [20, 30] -}
export
sliceClamped : Int -> Int -> List a -> List a
sliceClamped lo hi xs = drop lo (take hi xs)

-- > sliceClamped 5 9 [1, 2]
-- []
```

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
8. **`<type><Op>` ("xToY"-shaped) names are the primitive layer's naming
   marker.** `runtime.mdk` externs stay in that shape
   (`string.toDigit`/`fromDigit`, `validation.toResult`/`fromResult` are the
   library-layer companions, not the marker itself); a library module
   exporting a new name of that exact shape would claim the marker for a
   name that isn't a primitive — `docs/stdlib/runtime.md` labels the page
   "primitive layer — prefer the library name" for exactly this reason.
9. **The `keys`/`values`/`toList`/`elems`/`entries`/`items` container-
   accessor family settled to one name per shape per module.**
   `hash_map.entries` was removed (kept `toList`); `map.elems` was renamed
   to `map.values`. A module re-introducing two family names with an
   identical signature is the synonym drift that ruling closed.
10. **A `*InPlace` suffix is the mutation contract on a container that also
    has a persistent name.** `hash_map`/`hash_set`/`array`/`vector`'s
    mutating writers are `insertInPlace`/`setInPlace`/`deleteInPlace`;
    persistent containers keep the bare `insert`/`set`/`delete`. The suffix
    is what tells a reader "this mutates the receiver" without reading the
    signature.
11. **`repeat` and `replicate` are a ratified same-English-word exception,
    not drift.** `string.repeat` (concatenation) and `<container>.replicate`
    (element repetition into a container) are different operations that
    happen to share a name; the conventions detector must not flag this
    pair.
12. **Index-callback argument order: the index immediately precedes the
    element; an accumulator, when present, precedes the index.** E.g.
    `array.mapWithIndex`, `list.foldWithIndex`/`forEachWithIndex`. This is
    the shape every `WithIndex`/`WithKey` callback in the surface follows.
13. **`core.flat` is a ratified exception to the "no same-shaped synonym"
    sweep — no rename.** It collides in spelling only with `string.join`
    (different operation entirely) and is self-consistent with `flatMap`;
    the reasoning is recorded here so the detector never flags it.
