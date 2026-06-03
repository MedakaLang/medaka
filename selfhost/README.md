# selfhost — Medaka-in-Medaka compiler (Stage 1)

The self-hosted Medaka compiler, ported one pipeline stage at a time from the
OCaml reference in `lib/` and validated against it via differential testing.
See the **North star → Stage 1** section of [`../PLAN.md`](../PLAN.md).

Runs **on the existing tree-walking interpreter** (`medaka run …`) — correctness
first; native codegen is Stage 2.

## Layout

| File | Role |
|------|------|
| `lexer.mdk` | Port of `lib/lexer.mll`. `Token` ADT + `tokenToString` (mirror the OCaml `token_to_string` byte-for-byte) + `tokenize`. Prelude + global externs only — no stdlib import, so `selfhost/` is the sole project root. |
| `lex_main.mdk` | Runnable entry: `medaka run selfhost/lex_main.mdk <src.mdk>` reads the file, tokenizes, prints one token per line in the canonical reference form. |
| `medaka.toml` | Project config (import root). |

## Validation

```sh
dune build --root .                       # build the reference binary
sh test/diff_selfhost_lexer.sh            # diff the Medaka lexer vs OCaml goldens
```

The harness runs the Medaka lexer over every fixture in `test/diff_fixtures/`
and diffs its token stream against that fixture's golden `=== TOKENS ===`
section (those goldens are emitted by the OCaml `Lexer.tokenize_string`). A
fixture flips from `FAIL` to `ok` as the corresponding lexer behavior is ported;
the stage is done when all pass.

## Status

- ✅ Scaffold + harness wiring (token ADT, canonical serializer, runnable entry,
  diff loop). Positive control (empty source → `NEWLINE`/`EOF`) passes.
- ⏳ `tokenize` is a **stub** (emits only the layout-terminated empty stream).
  Next slice: port real tokenization — literals, idents, keywords, operators,
  then the stateful INDENT/DEDENT/NEWLINE layout algorithm. 0/15 fixtures pass
  until then.
