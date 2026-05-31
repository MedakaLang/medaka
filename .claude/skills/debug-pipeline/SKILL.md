---
name: debug-pipeline
description: Diagnose a Medaka parse, resolve, typecheck, or eval failure — isolate which pipeline stage is at fault using the dev probes and the diagnostics accumulator. Use when a .mdk program errors unexpectedly, a test fails opaquely, or you need to narrow down a compiler bug.
---

# Debug a pipeline failure

Medaka's stages run in order (lex → parse → resolve → typecheck → exhaust →
desugar → eval). The goal is to find the *first* stage that misbehaves, then
read its source. Errors don't abort on first failure — they accumulate in
`lib/diagnostics.ml`, so a later-stage message may be downstream of an earlier
real cause.

## Isolate the stage

Build first: `dune build`. The primary loop is a scratch `.mdk` file plus the
CLI, which reads real files and reports full accumulated diagnostics:

```sh
./_build/default/bin/main.exe check scratch.mdk   # front end only (no eval)
./_build/default/bin/main.exe run   scratch.mdk   # full pipeline incl. eval
```

Reason about which stage owns the failure:

- **Parse** — error with file/line/col (structured `ParseError` from
  `lib/loader.ml`) → bug in `lib/lexer.mll` or `lib/parser.mly`.
- **Resolve/Typecheck** — unbound name, type mismatch, or non-exhaustive-match
  warning → `lib/resolve.ml`, `lib/typecheck.ml`, `lib/exhaust.ml`. Errors are
  collected by `lib/diagnostics.ml` (no exit-on-error), so a later message can
  be downstream of an earlier real cause — fix the first one.
- **Eval** — type-checks but produces the wrong value → `lib/eval.ml` (or
  `lib/desugar.ml` if the construct is sugar).

## Dev probes — raw AST / type dumps

For internals the CLI doesn't print, use the probes in `dev/`. **They are
ad-hoc: you edit the hardcoded `src` string in the source, rebuild, and run**
(they do not read stdin):

- `dev/debug.ml` — edit `src`, then `dune build && ./_build/default/dev/debug.exe`
  to dump the parsed AST.
- `dev/tc_debug.ml` — same pattern; dumps inferred types.

### Custom probe for a library-internal function

When the bug is in a specific function the CLI never exercises in isolation —
a parser entry point (`Parser.program` vs `Parser.repl_expr`), a repl helper
(`Repl.try_parse`, `Repl.ends_indented`), `Typecheck.check_repl_decl`, the
marker pass — write a throwaway probe rather than reasoning from the source.
`medaka_lib` exposes everything (no `.mli`s), so:

1. add a file `dev/probe_tmp.ml` that `open Medaka_lib` and calls the function
   directly, printing what you need;
2. add its name to `dev/dune`'s `(names …)`;
3. `dune build dev/probe_tmp.exe && ./_build/default/dev/probe_tmp.exe`;
4. delete the file and revert `dev/dune` when done.

This is often faster than the CLI for narrowing *which* function misbehaves —
e.g. feeding a whole multi-line string to `check_repl_decl` (works) vs. driving
it line-by-line through `try_parse` (reproduces) cleanly bisects a repl bug to
the input-collection layer rather than the typechecker.

## Build a minimal repro

Shrink the failing program to the smallest snippet that still reproduces. Once
fixed, add it as a regression test in the matching `test/test_*.ml` suite.

## Tips

- For LSP-surfaced errors, also run `dev/lsp_smoke.sh`.
