# Medaka

A pragmatic, modern functional programming language. Sits at the intersection of
a cleaned-up OCaml, a practical Haskell, and a more functional, garbage-collected
Rust. See [language-design.md](./language-design.md) for the full design.

The compiler is written in OCaml (Phase 1). Eventually we'll target LLVM and/or
self-host.

## Status

Very early. So far:

- **AST** — `lib/ast.ml`
- **Lexer** — `lib/lexer.mll` (indentation-sensitive, OCaml-style)
- **Parser** — `lib/parser.mly` (Menhir)
- **Test suite** — `test/test_parser.ml` (40 cases via Alcotest)

Not yet: name resolution, type checking, codegen, anything that runs Medaka code.

## Building

Requires OCaml 5.x, dune, menhir, alcotest.

```sh
opam install dune menhir alcotest
dune build
```

## Running tests

```sh
dune build && ./_build/default/test/test_parser.exe --compact
```

(Running via `dune test` works too, just slower.)

## Trying the parser

```sh
dune build && ./_build/default/bin/main.exe path/to/file.mdk
```

Prints a one-line summary of each top-level declaration found in the file.

## Layout

```
lib/
  ast.ml          AST type definitions + pretty printer
  lexer.mll       Tokenizer with INDENT/DEDENT handling
  parser.mly      Grammar
bin/
  main.ml         CLI entry point
test/
  test_parser.ml  Alcotest suite
  debug.ml        Quick parse-and-print harness for ad-hoc inspection
```
