<p align="center">
  <img src="playground/brand/logo.svg" width="96" alt="">
</p>

<h1 align="center">Medaka</h1>

<p align="center">A practical functional language with static types, interfaces, and effects.</p>

<p align="center">
  <a href="https://medaka-lang.dev">Playground</a> ·
  <a href="https://medaka-lang.dev/guide/">Guide</a> ·
  <a href="https://medaka-lang.dev/stdlib/">Standard library</a> ·
  <a href="docs/spec/language-design.md">Design</a>
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
[compiler/BOOTSTRAP.md](compiler/BOOTSTRAP.md) for how the self-hosting works
and [PLAN.md](PLAN.md) for the roadmap.

Pipeline stages, in order:

- **Lexer** — `compiler/frontend/lexer.mdk` (indentation-sensitive)
- **Parser** — `compiler/frontend/parser.mdk` (recursive-descent)
- **AST** — `compiler/frontend/ast.mdk`
- **Desugar** — `compiler/frontend/desugar.mdk` (`deriving` → impls, record punning, do-blocks, default-method specialization)
- **Resolver** — `compiler/frontend/resolve.mdk` (every reference bound; multi-module aware)
- **Method marker** — `compiler/frontend/marker.mdk` (EVar → EMethodRef rewrite for dispatch)
- **Type checker** — `compiler/types/typecheck.mdk` (Hindley-Milner + interfaces + effects + exhaustiveness)
- **Exhaustiveness** — `compiler/frontend/exhaust.mdk` (Maranget pattern-matrix; called from typecheck)
- **Evaluator** — `compiler/eval/eval.mdk` (tree-walking interpreter with dict-passing typeclass dispatch)
- **Core IR / LLVM emit** — `compiler/ir/core_ir_lower.mdk` → `compiler/backend/llvm_emit.mdk` → `clang`
- **WasmGC backend** — `compiler/backend/wasm_emit.mdk` (2nd backend, browser playground)
- **Loader / CLI** — `compiler/driver/loader.mdk` + `compiler/driver/medaka_cli.mdk`
- **Tools** — `compiler/tools/` (fmt, printer, LSP, doctest, doc, repl, new_cmd, test_cmd, check)

## Status

Pre-release. The language, compiler, standard library, formatter, linter,
language server, and browser playground are all working; the surface syntax
and library are still settling ahead of a first tagged release. Open work is
tracked in [GitHub issues](https://github.com/MedakaLang/medaka/issues).

## Building

Medaka builds on **Linux and macOS**, and needs only **clang + the Boehm GC** — no OCaml, no opam,
no dune.

```sh
# Debian / Ubuntu
sudo apt install clang libgc-dev
# macOS
brew install bdw-gc
```

**Build the native compiler:**
```sh
make medaka          # WARM (./medaka_emitter present): 2-stage rebuild from
                     # current source.  COLD (fresh clone): bootstraps
                     # the emitter from compiler/seed/emitter.ll.gz first.
./medaka run yourfile.mdk
```
The checked-in seed carries no LLVM target triple, so a cold `make medaka` bootstraps on **x86_64 or
arm64** from the same bytes.
The result is a self-contained ~1.9 MB native binary doing
check/fmt/new/build/run/test/repl/lsp. For fully OCaml-free user builds,
`export MEDAKA_EMITTER=$(pwd)/medaka_emitter` so `medaka build` uses the
native emitter. (`make help` lists all targets.)

## Running tests

```sh
make preflight       # the gates relevant to your diff, derived from it
make test            # the in-language suite: doctests, property tests, `test` blocks
make gates           # the full differential suite (CI runs this; it is slow locally)
```

The gates compare the native compiler against captured goldens and against
the interpreter, stage by stage, and check that the emitter reproduces
itself. `AGENTS.md` describes the suite and its knobs.

## Using the compiler

**Type-check a file:**
```sh
medaka check path/to/file.mdk
```

**Run a file** (requires a `main : <IO> Unit` binding):
```sh
medaka run path/to/file.mdk
```

**Compile to a native binary:**
```sh
medaka build path/to/file.mdk -o prog   # medaka build --help lists every flag
```

Every native build links a compiled copy of the C runtime
(`runtime/medaka_rt.c`). Because that object is identical for every program on
the machine, `medaka build` **caches it by default** rather than spending ~0.76s
recompiling it each time. The cache lives in `$MEDAKA_CACHE_DIR` if set, else
`$XDG_CACHE_HOME/medaka`, else `$HOME/.cache/medaka`, and holds one `rt-<hash>.o`
per distinct runtime build. The hash covers the `.c` source, the C compiler and
its version, and the exact compile flags, so a changed runtime or a new compiler
never reuses a stale object. It is safe to delete at any time. Two escape
hatches: `MEDAKA_NO_OBJ_CACHE=1` disables the cache entirely (the runtime is
compiled inline on every build), and `MEDAKA_CACHE_DIR=<dir>` relocates it — e.g.
to a per-job scratch directory in CI. An explicit `MEDAKA_RT_OBJ=<obj>` still
takes precedence over the cache. Every cache failure is fail-open: the build
falls back to the inline compile rather than erroring.

**Interactive REPL:**
```sh
medaka repl
```

**Language server** (for editor integration — speaks LSP over stdio):
```sh
medaka lsp
```

**Scaffold a new project:**
```sh
medaka new myproj
cd myproj && medaka run
```

This creates `myproj/` containing `medaka.toml`, `main.mdk`,
`.gitignore`, and `README.md`. The `medaka.toml` is a minimal
Cargo-style file:

```toml
[package]
name = "myproj"
version = "0.1.0"
entry = "main.mdk"
```

Its presence marks the project root: `medaka run` / `medaka check`
with no file argument resolves `entry` from `medaka.toml` in the cwd
(walking up), and `import` paths in any file under the project tree
are resolved relative to the root.

**Format source code:**
```sh
medaka fmt path/to/file.mdk        # read-only: report unformatted files, exit 1 if any
medaka fmt --write path/to/file.mdk  # rewrite in place; prints a one-line summary
medaka fmt --check src/            # explicit form of the default (report-only, exit 1 if any)
medaka fmt --stdout one_file.mdk   # print to stdout (single file only)
```

The formatter parses, re-prints, and verifies the output reparses to
the same AST. Line comments (`--`) and block comments (`{- … -}`,
nesting) are preserved at their original positions.

**Generate Markdown documentation:**
```sh
medaka doc path/to/file.mdk
```

Outputs one `## name` section per public declaration with the
inferred type signature and any `--` doc comments immediately above
the declaration. Run inside a project (`medaka.toml`) and the file
argument may be omitted.

**Lint for style issues:**
```sh
medaka lint path/to/file.mdk       # lint one file
medaka lint src/                   # lint a directory (recursive)
medaka lint                        # lint the whole medaka.toml project
medaka lint --fix file.mdk         # apply safe autofixes in place
medaka lint --deny=rule-name f.mdk # treat a rule's findings as errors (exit 1)
medaka lint --disable=r1,r2 src/   # turn rules off (or --only=r1,r2)
medaka lint --cache src/           # skip files whose content is unchanged
```

A modular, rule-based linter for style issues that the formatter
deliberately won't auto-change (they alter a definition's *shape*, not
just layout). Per-file rules flag immediate `match`-on-a-bare-param
(→ multi-clause), hand-rolled `Eq`/`Ord`/`Debug` (→ `deriving`), and
re-implemented stdlib functions; a cross-file rule flags structurally
duplicated function bodies across modules. Rules are warnings by
default (exit 0); `--deny` promotes a rule to an error (exit 1). `--fix`
applies the safe autofixes (currently the match-on-param → multi-clause
rewrite). Adding a custom rule is one function plus one registry entry
in `compiler/tools/lint.mdk`.

`--cache` (opt-in, like ESLint's) reuses the previous run's results for
every file whose *content* is unchanged, which on a repo-sized lint is
the difference between ~6.7s and ~0.4s. Results are keyed on a hash of
the file's contents (never its mtime) *and* of the compiler binary, so
editing a rule — or rebuilding the compiler at all — invalidates the
cache rather than serving stale findings. Cross-file rules still run in
full on every invocation: only their per-file inputs are cached, so a
duplicate-body finding is retracted the moment the other file stops
duplicating it. The cache lives in `.medaka/lint-cache/` next to
`medaka.toml` and is safe to delete at any time (and to gitignore —
`medaka new` does). `--cache` is currently a no-op alongside `--fix` and
`--json`.

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
debug : a -> String
...
> :quit
```

REPL meta-commands:

| Command | Alias | Description |
|---------|-------|-------------|
| `:quit` | `:q` | Exit the REPL |
| `:reset` | | Clear all session bindings |
| `:type <expr>` | `:t` | Print inferred type of an expression |
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

The stdlib lives in `stdlib/` and is written in Medaka on top of the `extern`
primitives cataloged in `stdlib/runtime.mdk`. `stdlib/core.mdk` is the prelude:
its types (`Option`, `Result`, `Ordering`), interfaces (`Eq`, `Ord`, `Debug`,
`Num`, `Mappable`, `Foldable`, `Applicative`, `Thenable`, `Semigroup`,
`Monoid`, …), and helpers are available in every program without an import.
The other modules (`list`, `string`, `array`, `map`, `set`, `json`, …) are
imported by name.

The reference is generated from the source: browse it at
[medaka-lang.dev/stdlib](https://medaka-lang.dev/stdlib/) or in
[docs/stdlib/index.md](docs/stdlib/index.md). Conventions for adding
primitives are in [stdlib/README.md](stdlib/README.md).

## Editor setup

### VS Code / Cursor

A language extension lives in `editors/vscode-medaka/`. It provides
syntax highlighting for `.mdk` files via a TextMate grammar, and connects
to the Medaka language server (`medaka lsp`) for live error diagnostics.

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
compiler/
  frontend/
    ast.mdk         AST type definitions
    lexer.mdk       Tokenizer with INDENT/DEDENT handling
    parser.mdk      Recursive-descent grammar
    desugar.mdk     `deriving` expansion, record puns, do-blocks, default methods
    resolve.mdk     Name resolution (single-file and multi-module)
    marker.mdk      EVar→EMethodRef rewrite for dispatch
    exhaust.mdk     Maranget's pattern-matrix exhaustiveness algorithm
  types/
    typecheck.mdk   Hindley-Milner + interfaces + effects + exhaustiveness
    annotate.mdk    Type annotation helpers
  ir/
    core_ir.mdk         Core IR type definitions
    core_ir_lower.mdk   AST → Core IR lowering
    core_ir_sexp.mdk    Core IR S-expr serializer
    dce.mdk             Dead code elimination
  backend/
    llvm_emit.mdk       Core IR → LLVM text IR → clang
    wasm_emit.mdk       Core IR → WasmGC text IR (2nd backend)
    private_mangle.mdk  Universal constructor name mangling
    trmc_analysis.mdk   Tail-recursion-modulo-cons analysis
  eval/
    eval.mdk        Tree-walking interpreter (dict-passing dispatch for typeclasses)
  driver/
    loader.mdk      Multi-file dependency walk + topological sort + medaka.toml walk-up
    diagnostics.mdk Accumulating parse/resolve/typecheck pipeline (no exit-on-error)
    build_cmd.mdk   `medaka build` — LLVM pipeline driver
    medaka_cli.mdk  CLI entry point (check / run / repl / lsp / fmt / doc / new / build)
  tools/
    printer.mdk     AST → source (round-trip)
    fmt.mdk         `medaka fmt` — comment-preserving formatter
    lsp.mdk         LSP server: stdio JSON-RPC, diagnostics + formatting,
                    document symbols, hover, definition, highlight,
                    completion, inlay hints
    doc.mdk         `medaka doc` — doc-comment→Markdown extractor
    doctest.mdk     `medaka test` — doctest extractor + runner
    test_cmd.mdk    `medaka test` — test command driver + prop tests
    repl.mdk        `medaka repl` — interactive REPL loop
    new_cmd.mdk     `medaka new` — project scaffolder
    check.mdk       `medaka check` — type-check entry
    check_policy.mdk  `medaka check-policy` — policy checker
  support/
    util.mdk        Generic helpers (compiler private mini-stdlib)
    ordmap.mdk      Ordered map (SMap/EMap)
    char.mdk        Character utilities
    path.mdk        Path utilities
    timer.mdk       Timing utilities
  entries/           Per-stage probe entry points
  seed/
    emitter.ll.gz   Gzipped LLVM IR seed for cold bootstrap
stdlib/
  runtime.mdk     Extern primitive catalog (loaded at startup)
  core.mdk        Core interfaces, instances, helpers (implicit prelude)
  list.mdk        List operations
  string.mdk      String operations
  array.mdk       Array operations
  byteparser.mdk  Generic binary parser-combinator library (big-endian decoders)
  bytebuilder.mdk Symmetric byte-output builder (emit*/buildArray)
runtime/
  medaka_rt.c     C runtime + Boehm GC
test/
  run_gates.sh         Parallel runner for the whole diff_compiler_* suite
  diff_compiler_*.sh   Differential golden-diff test gates (~67 suites)
  bootstrap_*.sh       Per-stage native==interpreter gates
  selfcompile_*.sh     Emitter self-compile fixpoint gates
  build_oracles.sh     Oracle golden capture / force-rebuild (parallel)
  capture_goldens.sh   Golden capture helper
  bench.sh             Performance benchmark harness
  *_fixtures/          Input fixture files for each gate
  *_goldens/           Golden output files for each gate
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
