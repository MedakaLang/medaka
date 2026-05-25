# Medaka

A pragmatic, modern functional programming language. Sits at the intersection of
a cleaned-up OCaml, a practical Haskell, and a more functional, garbage-collected
Rust. See [language-design.md](./language-design.md) for the full design.

The compiler is written in OCaml (Phase 1). Eventually we'll target LLVM and/or
self-host.

## Status

Frontend and interpreter complete; codegen not yet started.

- **AST** — `lib/ast.ml`
- **Lexer** — `lib/lexer.mll` (indentation-sensitive, OCaml-style)
- **Parser** — `lib/parser.mly` (Menhir)
- **Printer** — `lib/printer.ml` (AST → parseable source)
- **Resolver** — `lib/resolve.ml` (every reference is bound)
- **Type checker** — `lib/typecheck.ml` (Hindley-Milner with let-polymorphism,
  ADTs, records, pattern matching, interfaces with constraint checking,
  effect tracking, exhaustiveness/usefulness)
- **Evaluator** — `lib/eval.ml` (tree-walking interpreter)
- **REPL** — `lib/repl.ml` (incremental parse/typecheck/eval with persistent env)
- **CLI** — `bin/main.ml` — `check`, `run`, and `repl` subcommands
- **Test suite** — 400 cases across parser, roundtrip, resolve, typecheck,
  eval, run, and repl suites

Not yet: codegen, stdlib. See [PLAN.md](./PLAN.md) for the roadmap.

## Building

Requires OCaml 5.x, dune, menhir, alcotest.

```sh
opam install dune menhir alcotest
dune build
```

## Running tests

```sh
dune test
```

Or run individual suites directly (preferred — `dune test` can hang):

```sh
./_build/default/test/test_parser.exe    --compact
./_build/default/test/test_typecheck.exe --compact
./_build/default/test/test_eval.exe      --compact
./_build/default/test/test_run.exe       --compact
```

## Using the compiler

**Type-check a file:**
```sh
./_build/default/bin/main.exe check path/to/file.mdk
```

**Run a file** (requires a `main : <IO> Unit` binding):
```sh
./_build/default/bin/main.exe run path/to/file.mdk
```

**Interactive REPL:**
```sh
./_build/default/bin/main.exe repl
```

```
medaka repl  (:quit to exit, :reset to clear session)
> x = 42
val x : Int
> x + 1
43 : Int
> data Color = Red | Green | Blue
type Color
> Red
Red : Color
> :type [1, 2, 3]
List Int
> :load stdlib/core.mdk
loaded stdlib/core.mdk — 12 bindings
> :browse
eq : a -> a -> Bool
show : a -> String
...
> :quit
```

REPL meta-commands:

| Command | Alias | Description |
|---------|-------|-------------|
| `:quit` | `:q` | Exit the REPL |
| `:reset` | | Clear all session bindings |
| `:type <expr>` | `:t` | Show inferred type of an expression |
| `:load <path>` | | Load a `.mdk` file into the session |
| `:reload` | `:r` | Reload the last loaded file |
| `:browse` | `:env` | List all bindings currently in scope |

Multi-line definitions work naturally — keep typing indented lines and press
Enter on a blank line to commit:

```
> insert x t = match t
    Leaf => Node x Leaf Leaf
    Node v l r => if x < v
                    then Node v (insert x l) r
                    else Node v l (insert x r)
  
val insert : a -> BTree a -> BTree a
```

## Standard library

The stdlib lives in `stdlib/`. `stdlib/runtime.mdk` is the authoritative catalog
of extern primitives — their type signatures are embedded at build time and
available in all programs without an explicit import. See
[stdlib/README.md](stdlib/README.md) for conventions on adding new primitives.

The higher-level stdlib modules (`core`, `list`, `string`, `array`, …) are
written in Medaka itself and developed interactively via the REPL. See
[STDLIB.md](STDLIB.md) for the module plan.

## Editor setup

### VS Code / Cursor

A minimal language extension lives in `editors/vscode-medaka/`. It provides
syntax highlighting for `.mdk` files via a TextMate grammar.

**Install (symlink, recommended for development):**
```sh
ln -s "$(pwd)/editors/vscode-medaka" ~/.vscode/extensions/medaka
# For Cursor:
ln -s "$(pwd)/editors/vscode-medaka" ~/.cursor/extensions/medaka
```

Restart VS Code / Cursor. Files ending in `.mdk` will be highlighted.

**Install as VSIX (one-time):**
```sh
cd editors/vscode-medaka
npm install -g @vscode/vsce
vsce package          # produces medaka-0.1.0.vsix
code --install-extension medaka-0.1.0.vsix
```

### Neovim (nvim-treesitter)

Add to your config:

```lua
local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
parser_config.medaka = {
  install_info = {
    url = vim.fn.expand("~/medaka/tree-sitter-medaka"),
    files = { "src/parser.c", "src/scanner.c" },
  },
  filetype = "medaka",
}
vim.filetype.add({ extension = { mdk = "medaka" } })
```

Copy the highlights query:
```sh
mkdir -p ~/.config/nvim/after/queries/medaka
cp tree-sitter-medaka/queries/highlights.scm \
   ~/.config/nvim/after/queries/medaka/highlights.scm
```

Then run `:TSInstall medaka` inside Neovim.

### Helix

Add to `~/.config/helix/languages.toml`:

```toml
[[language]]
name = "medaka"
scope = "source.medaka"
file-types = ["mdk"]
roots = []
comment-token = "--"
indent = { tab-width = 2, unit = "  " }

[language.grammar]
source = { path = "~/medaka/tree-sitter-medaka" }
```

Copy the highlights query:
```sh
mkdir -p ~/.config/helix/runtime/queries/medaka
cp tree-sitter-medaka/queries/highlights.scm \
   ~/.config/helix/runtime/queries/medaka/highlights.scm
```

### Zed

Create a language extension following the [Zed extension docs](https://zed.dev/docs/extensions/languages).
Point `grammar.repository` at `tree-sitter-medaka/` and set `file_types = ["mdk"]`.

## Tree-sitter grammar

The tree-sitter grammar lives in `tree-sitter-medaka/`. To rebuild after grammar
changes:

```sh
cd tree-sitter-medaka
npm install
npx tree-sitter generate   # regenerates src/parser.c
npx tree-sitter test       # run corpus tests
```

## Layout

```
lib/
  ast.ml          AST type definitions
  lexer.mll       Tokenizer with INDENT/DEDENT handling
  parser.mly      Menhir grammar
  printer.ml      AST → source (round-trip)
  resolve.ml      Name resolution
  typecheck.ml    Hindley-Milner + interfaces + effects + exhaustiveness
  exhaust.ml      Maranget's pattern-matrix algorithm
  eval.ml         Tree-walking interpreter
  runtime.ml      Extern dispatch + runtime.mdk embedding
bin/
  main.ml         CLI entry point (check / run / repl)
  repl.ml         Interactive REPL loop shim
gen/
  embed.ml        Build-time helper: embeds runtime.mdk as an OCaml string
stdlib/
  runtime.mdk     Extern primitive catalog (embedded at build time)
  core.mdk        Core interfaces and instances
  list.mdk        List operations
  string.mdk      String operations
  array.mdk       Array operations
test/
  test_parser.ml      AST shape per construct
  test_roundtrip.ml   parse → print → parse stability
  test_resolve.ml     Resolution errors
  test_typecheck.ml   Inferred types, type errors, exhaustiveness warnings
  test_eval.ml        Interpreter correctness
  test_run.ml         End-to-end program runs
  test_repl.ml        REPL meta-commands and load atomicity
  test_loader.ml      Module loader and cross-file imports
dev/
  debug.ml            Ad-hoc parse-and-print probe
  tc_debug.ml         Ad-hoc type-check probe
tree-sitter-medaka/
  grammar.js          Tree-sitter grammar definition
  src/parser.c        Generated parser (committed)
  src/scanner.c       External scanner for INDENT/DEDENT/NEWLINE
  queries/
    highlights.scm    Syntax highlight queries
  test/corpus/        Corpus tests for the grammar
editors/
  vscode-medaka/      VS Code / Cursor extension
```
