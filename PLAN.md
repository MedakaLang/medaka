# Medaka — Roadmap

The working handoff between sessions. Read it before starting a task; update it
when you finish one. This document holds only **forward-looking** work — the
completed Phases 1–97 (with their detailed implementation notes) live in
[`PLAN-ARCHIVE.md`](./PLAN-ARCHIVE.md). For how to build/test and the codebase's
non-obvious gotchas, see [`AGENTS.md`](./AGENTS.md).

## Current status (2026-06-02)

The compiler pipeline is complete end-to-end —
`lexer → parser → resolve → method_marker → typecheck → exhaust → desugar →
eval` — and 97 numbered phases are done. The language has records, ADTs,
interfaces (with superinterfaces, `deriving`, dictionary-passing for
return-position/multi-param dispatch), effect rows, exhaustiveness checking,
`do`-notation, guards (with fall-through), list comprehensions, string
interpolation, type aliases/newtypes, property testing, doctests, an LSP server,
a formatter, and a project-config/`medaka new` surface. Operators are wired to
the real `Eq`/`Ord`/`Num` interfaces in `core.mdk` (Phase 52).

The stdlib in Medaka covers `core`, `list`, `array`, and a drafted `string`
(STDLIB.md Modules 1–4). The remaining stdlib modules are user-written by
design (see the stdlib division-of-labor convention).

**Conventions.** Work is still organized by numbered **Phases**; commit messages
and code comments reference them. Phases that were left *partial* keep their
original number (e.g. Phase 82, 91, 92); genuinely new work gets the next free
number continuing from 97. At task triage, match the work against AGENTS.md's
task-playbook table and load the matching skill before planning.

---

## Open roadmap

Each item is independently shippable; pick one per session. Grouped by area, not
strict priority.

### Compiler / language

- **Phase 98 — `do`→`Thenable` desugar.** `<-` is currently handled
  *structurally* in the typechecker (each line unifies its expression against
  `m a` for a fresh `m`); the `Thenable` interface in `core.mdk` is never
  consulted, so it is inert at the type level (eval already routes bind through
  the `andThen` VMulti at runtime). To make the constraint load-bearing, `<-`
  should desugar to checked `andThen` calls. **Design question first:** is this
  worth doing, or should `Thenable` instead be *deleted*? `do` already works on
  anything shaped like `m a`, so the interface currently earns nothing — wiring
  it adds a constraint that could reject programs that work today. Decide the
  direction before implementing. Lands in `lib/typecheck.ml` (+ `lib/desugar.ml`
  if wiring). Skill: **add-language-feature**.

- **Phase 91 (continued) — guard gaps.** Fall-through (item 1) is done; two
  remain:
  - **(2) Compile-time non-exhaustive-guard detection.** Today an exhausted
    guard chain is a runtime error. `exhaust.ml` does pattern matrices but not
    guard coverage. Guards are arbitrary `Bool`, so only `| otherwise` /
    literal-`True` coverage is decidable — a conservative "guards may not be
    exhaustive" warning is the realistic target. Lands in `lib/exhaust.ml`.
  - **(3) Inline guard form.** `f n | n <= 0 = []` on one line is a parse error;
    guards must be on indented continuation lines. Lands in `lib/parser.mly` /
    `lib/lexer.mll` — re-measure parser conflicts after the grammar change.
  - Skill: **add-language-feature**.

- **Phase 92 (continued) — doctest harness reaches cross-module instances.**
  `medaka test <file>` type-checks via the single-file `check_program`, so a
  doctest can't see an instance defined in a *sibling* stdlib module (e.g. a
  `core` doctest that `show`s an `Array`, whose `Show Array` lives in
  `array.mdk`). String/Char were special-cased into the prelude; the general fix
  routes `lib/doctest.ml` through the multi-module (`typecheck_module`) path.
  Note the hazard documented in the archive: flattening `list.mdk` + `array.mdk`
  into one module merges their deliberately-reused top-level names — the fix must
  preserve module separation. Skill: **add-language-feature** (touches the
  doctest harness, not just the typechecker).

- **Phase 42 (residual) — property-test generators.** The `prop`/`Arbitrary`
  machinery is done, but `lib/prop_runner.ml`'s `gen_for_type` has gaps:
  - No generation for `Array a` or tuples.
  - Parametric user types (`TyApp (TyCon custom, _)`) aren't routed through
    `Eval.arbitrary_registry` — only nullary `TyCon custom` is.
  - Built-in generation is native OCaml and bypasses the Medaka-level
    `arbitrary`/`shrink` methods; unifying both paths (drive everything through
    the interface) is open.
  - Skill: **add-primitive** / **add-language-feature** depending on approach.

- **Phase 83 / 84 (residuals, deferred — layered like 69.x→74).** Lower priority;
  each is a known limitation with a correct-enough fallback today:
  - Runtime dict-threading *into* an inferred constrained body (currently arg-tag
    dispatch, correct for argument-dispatched wrappers). Needs a post-typecheck
    marker re-run against the final constraint tables — a pipeline restructure.
  - Self-/mutually-recursive *unsignatured* wrappers under-infer their own
    recursive-call routing.
  - `pure` in a do-block with **no `<-`** is groundable only from surrounding
    type context.
  - `Result e` with a free `e` mis-dispatches even when signatured (a multi-param
    dict-resolution gap).
  - Skill: **harden-typechecker** / **add-language-feature** (cross-cutting).

### CLI surface (Phase 82, continued)

The design spec lists `new build run check test fmt lsp doc add remove update`;
`check / run / test / repl / lsp / fmt / new` exist, plus `bench`. Remaining
non-package-manager gaps:

- **`medaka build`** — needs its own design first: there is no artifact cache or
  typed-IR serialization format in the tree, so "typecheck + cache" has no honest
  implementation. Until that exists it would only be an alias of `check`.
- **`medaka doc`** — needs (a) a comment→decl matcher (doc comments aren't
  attached to AST nodes — a parallel `Lexer.take_comments()` stream matched by
  position, like `doctest.ml` does), (b) a signature renderer for a typechecker
  `scheme`, and (c) an output-format decision.
- **`medaka check --json` multi-file** — currently single-file (`Diagnostics.
  analyze` doesn't invoke the `Loader`), so a file with `import`s can
  resolve-error in the JSON output. Multi-file `--json` is the follow-up.
- Skill: none specific (lands in `bin/main.ml` + `lib/lsp_server.ml`).

### Stdlib enablement (Phase 19 — user-owned)

Deliberately hand-written by the user; listed for completeness, not as agent
work unless explicitly delegated (see the stdlib division-of-labor convention).

- **`stdlib/string.mdk`** is drafted and passes its 45 doctests but is flagged
  *awaiting user review* (archive Phase 75 step 3). Open decisions: the
  `length`/`isEmpty`/`count` omissions and `toUpper` vs `charToUpper` naming.
- **Modules 5–8 unstarted:** `map`/`set` (persistent trees), `mut_array`/
  `hash_map`/`hash_set`, `io` (`readFile`/`writeFile`/`readLine`), `json`
  (type + parser + serializer). Expect each to surface new language gaps —
  record them here as new phases when they do.

### Blocked on a package manager (out of scope until one exists)

- `medaka add` / `remove` / `update`, and a `medaka.lock` file.

---

## Won't-do (kept intentional)

- **Phase 78c — multi-module method shadowing.** Investigated 2026-06-01 and
  dropped: the motivating need (`length`/`isEmpty`/`toList` on `Array`) is
  already met by interface impls, and there is no safe export path for a bare
  `length : String -> Int` (it would shadow `Foldable.length` everywhere). The
  real lever, if ever needed, is a `Sized`/`HasLength` interface — which is
  stdlib design, not a compiler feature. Reopen only for a genuine, non-cosmetic
  need that interface impls can't serve.
- The broader **rejected-features** list (labeled arguments, active patterns,
  computation expressions, polymorphic variants, first-class modules, row
  polymorphism, macros, lazy sequences, higher-rank polymorphism, custom
  symbolic operators, …) lives in PLAN-ARCHIVE.md §8 with per-item rationale.
  Consult it before proposing any of them so the rejection stays intentional.
