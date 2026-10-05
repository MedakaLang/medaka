<p align="center">
  <img src="playground/brand/logo.svg" width="96" alt="">
</p>

<h1 align="center">Medaka</h1>

<p align="center">A practical functional language with static types, interfaces, and effects.</p>

<p align="center">
  <a href="https://medaka-lang.dev">Playground</a> ·
  <a href="https://medaka-lang.dev/guide/">Guide</a> ·
  <a href="https://medaka-lang.dev/stdlib/">Standard library</a> ·
  <a href="docs/spec/SYNTAX.md">Syntax</a>
</p>

Medaka sits between a cleaned-up OCaml, a practical Haskell, and a
garbage-collected Rust: Hindley-Milner inference, interfaces for ad-hoc
polymorphism, tracked effects, exhaustive pattern matching, and a small
standard library written in the language itself.

```
data Shape
  = Circle Float
  | Rect Float Float

area : Shape -> Float
area (Circle r) = 3.14159 * r * r
area (Rect w h) = w * h

main =
  let shapes = [Circle 1.0, Rect 3.0 4.0]
  println "areas: \{map area shapes}"
```

The quickest way to try it is the [playground](https://medaka-lang.dev), which
runs the full compiler in your browser. The [guide](https://medaka-lang.dev/guide/)
walks through the language from a first program to modules and tooling.

## The compiler

The compiler is written in Medaka (`compiler/`) and compiles itself through a
native LLVM backend to a self-contained binary, reproducing its own output
byte for byte. A second backend targets WasmGC and is what the playground
runs. `make medaka` builds the compiler from a checked-in IR seed, so the only
toolchain it needs is clang and the Boehm GC. See
[compiler/BOOTSTRAP.md](compiler/BOOTSTRAP.md) for how the self-hosting works.
Open work is tracked in the
[0.1.0 milestone](https://github.com/MedakaLang/medaka/milestone/1) and the
[issue tracker](https://github.com/MedakaLang/medaka/issues); [PLAN.md](PLAN.md)
is an older working log, not the current roadmap.

This repository is developed with coding agents. `AGENTS.md` and `.claude/` are their
playbooks; they are the reason the tree carries more process files than a typical project.

## Projects written in Medaka

Besides the compiler and `stdlib/`, the repository holds several programs and libraries
written in the language, each with its own `medaka.toml`:

- [`pds/`](pds/README.md): a Bluesky Personal Data Server, from HTTP framing and the
  cryptographic primitives up.
- [`sqlite/`](sqlite/README.md): a SQLite file reader and writer with a small SQL engine.
- [`parsec/`](parsec/README.md): a general parser-combinator library (`sqlite/` uses it).
- [`gzip/`](gzip/README.md): a DEFLATE/gzip codec.
- [`demo/`](demo/README.md): two edge plugins used to demonstrate effect-policy checking.

Pipeline stages, in order:

- **Lexer** — `compiler/frontend/lexer.mdk` (indentation-sensitive)
- **Parser** — `compiler/frontend/parser.mdk` (recursive-descent)
- **AST** — `compiler/frontend/ast.mdk`
- **Desugar** — `compiler/frontend/desugar.mdk` (`deriving` → impls, record punning, do-blocks, default-method specialization)
- **Resolver** — `compiler/frontend/resolve.mdk` (every reference bound; multi-module aware)
- **Type checker** — `compiler/types/typecheck.mdk` (Hindley-Milner + interfaces + effects + exhaustiveness; marks method dispatch per binding group)
- **Exhaustiveness** — `compiler/frontend/exhaust.mdk` (Maranget pattern-matrix; called from typecheck)
- **Evaluator** — `compiler/eval/eval.mdk` (tree-walking interpreter with dict-passing typeclass dispatch)
- **Core IR / LLVM emit** — `compiler/ir/core_ir_lower.mdk` → `compiler/backend/llvm_emit.mdk` → `clang`
- **WasmGC backend** — `compiler/backend/wasm_emit.mdk` (2nd backend, browser playground)
- **Loader / CLI** — `compiler/driver/loader.mdk` + `compiler/driver/medaka_cli.mdk`
- **Tools** — `compiler/tools/` (fmt, printer, LSP, doctest, doc, repl, new_cmd, test_cmd, check)

## Status

Medaka is **experimental (0.1.0 preview)**. The language, compiler, standard
library, formatter, linter, language server, and browser playground all work;
the surface syntax and library are still settling ahead of a first tagged
release. Open work is tracked in
[GitHub issues](https://github.com/MedakaLang/medaka/issues).

## Install

Medaka builds from source and needs only **clang and the Boehm GC**. There is no
OCaml, opam, or dune. You also need `make`, `git`, and `gunzip` (the cold build
unpacks the checked-in IR seed with it).

```sh
# Debian / Ubuntu
sudo apt install clang libgc-dev
# macOS
brew install bdw-gc
```

```sh
git clone https://github.com/MedakaLang/medaka
cd medaka
make medaka                       # first build takes a few minutes
export PATH="$PWD:$PATH"          # run `medaka` from anywhere
printf 'main = println "Hello world!"\n' > hello.mdk
medaka run hello.mdk
```

The first build bootstraps the compiler from the checked-in seed
(`compiler/seed/emitter.ll.gz`); later rebuilds are faster. Leave the binary in
the checkout: it finds the standard library relative to its own location, so put
the checkout directory on `PATH` rather than copying `medaka` elsewhere.

Linux is the platform CI covers. macOS builds, but that path is verified by hand
rather than by CI
([#549 (no macOS CI coverage)](https://github.com/MedakaLang/medaka/issues/549)).

New to the language? Start with the
[quick start](docs/guide/01-quick-start.md).

## Using it

`medaka check`, `run`, `build`, `fmt`, `lint`, `test`, `doc`, `repl`, `lsp`, and
`new` are covered in the guide's
[tooling chapter](docs/guide/10-tooling-and-workflow.md). Build-cache switches,
editor setup (VS Code, Neovim, Helix, Zed), and the source layout are in
[docs/ops/TOOLING-REFERENCE.md](docs/ops/TOOLING-REFERENCE.md). The standard
library reference is at [medaka-lang.dev/stdlib](https://medaka-lang.dev/stdlib/);
every other document is indexed in [docs/README.md](docs/README.md).

## Running tests

```sh
make preflight       # the gates relevant to your diff, derived from it
make test            # the in-language suite: doctests, property tests, `test` blocks
make gates           # the full differential suite (CI runs this; it is slow locally)
```

The gates compare the native compiler against captured goldens and against the
interpreter, stage by stage, and check that the emitter reproduces itself.
[AGENTS.md](AGENTS.md) describes the suite and its knobs; see also
[CONTRIBUTING.md](CONTRIBUTING.md).
