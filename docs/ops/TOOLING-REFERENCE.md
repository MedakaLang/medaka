# TOOLING-REFERENCE.md — build cache, lint cache, editors, and the source layout

**Status:** REFERENCE — material that used to live in the repository README, kept
here so the README can stay a front door. The guide's
[tooling chapter](../guide/10-tooling-and-workflow.md) is the tutorial; this page
is the detail behind it.

## Building

`make medaka` needs only clang and the Boehm GC. Debian / Ubuntu: `clang
libgc-dev`. macOS: `brew install bdw-gc`. A warm tree (`./medaka_emitter`
present) rebuilds in two stages from current source; a cold tree bootstraps the
emitter from `compiler/seed/emitter.ll.gz` first. The checked-in seed carries no
LLVM target triple, so a cold build works on x86_64 or arm64 from the same
bytes. For a `medaka build` that uses the native emitter from outside the
checkout, `export MEDAKA_EMITTER=$(pwd)/medaka_emitter`. `make help` lists every
target.

## The runtime object cache

Every native build links a compiled copy of the C runtime
(`runtime/medaka_rt.c`). Because that object is identical for every program on
the machine, `medaka build` caches it by default rather than recompiling it each
time. The cache lives in `$MEDAKA_CACHE_DIR` if set, else
`$XDG_CACHE_HOME/medaka`, else `$HOME/.cache/medaka`, and holds one
`rt-<hash>.o` per distinct runtime build. The hash covers the `.c` source, the C
compiler and its version, and the exact compile flags, so a changed runtime or a
new compiler never reuses a stale object. It is safe to delete at any time. A
build ages out its own `rt-*.o` entries after 30 days and never removes anything
else from that directory.

- `MEDAKA_NO_OBJ_CACHE=1` disables the cache entirely (the runtime is compiled
  inline on every build).
- `MEDAKA_CACHE_DIR=<dir>` relocates it, for example to a per-job scratch
  directory in CI.
- An explicit `MEDAKA_RT_OBJ=<obj>` takes precedence over the cache.
- Every cache failure is fail-open: the build falls back to the inline compile.

By default a native build links the program and the runtime through one ThinLTO
link, so the runtime's small helpers inline into the program. `MEDAKA_NO_LTO=1`
(any non-empty value) forces the plain, non-ThinLTO link instead, for a consumer
that needs a native runtime object, which `ld -r` can merge and ThinLTO bitcode
cannot (`test/diff_compiler_llvm_ffi_test.mdk` and the memcheck probe in
`pds/test/constant_time_signing.sh` are the two current consumers). A runtime
object produced by `--emit-rt-obj` follows the same switch, so `MEDAKA_RT_OBJ`
must be paired with the matching link mode: set `MEDAKA_NO_LTO` for both the
build that emits the object and the build that links it, or for neither.

## Projects and `medaka.toml`

`medaka new myproj` creates `myproj/` containing `medaka.toml`, `main.mdk`,
`.gitignore`, and `README.md`. The manifest is minimal:

```toml
[package]
name = "myproj"
version = "0.1.0"
entry = "main.mdk"
```

Its presence marks the project root: `medaka run` and `medaka check` with no file
argument resolve `entry` from the `medaka.toml` in the cwd (walking up), and
`import` paths in any file under the project tree resolve relative to the root.

## Formatter, doc, and lint flags

```sh
medaka fmt path/to/file.mdk          # read-only: report unformatted files, exit 1 if any
medaka fmt --write path/to/file.mdk  # rewrite in place; prints a one-line summary
medaka fmt --check src/              # explicit form of the default
medaka fmt --stdout one_file.mdk     # print to stdout (single file only)
```

The formatter parses, re-prints, and verifies the output reparses to the same
AST. Line comments (`--`) and block comments (`{- … -}`, nesting) are preserved.

`medaka doc path/to/file.mdk` writes one `## name` section per public
declaration with the inferred type signature and any `--` doc comments directly
above it; inside a project the file argument may be omitted.

```sh
medaka lint path/to/file.mdk       # lint one file
medaka lint src/                   # lint a directory (recursive)
medaka lint                        # lint the whole medaka.toml project
medaka lint --fix file.mdk         # apply safe autofixes in place
medaka lint --deny=rule-name f.mdk # treat a rule's findings as errors (exit 1)
medaka lint --disable=r1,r2 src/   # turn rules off (or --only=r1,r2)
medaka lint --cache src/           # skip files whose content is unchanged
```

The linter flags style issues the formatter deliberately will not change because
they alter a definition's shape: an immediate `match` on a bare parameter (to a
multi-clause definition), hand-written `Eq`/`Ord`/`Debug` (to `deriving`), and
re-implemented stdlib functions; a cross-file rule flags structurally duplicated
function bodies across modules. Rules are warnings by default (exit 0); `--deny`
promotes a rule to an error. Adding a rule is one function plus one registry
entry in `compiler/tools/lint.mdk`.

`--cache` (opt-in) reuses the previous run's results for every file whose
content is unchanged. Results are keyed on a hash of the file's contents (never
its mtime) and of the compiler binary, so editing a rule or rebuilding the
compiler invalidates the cache. Cross-file rules still run in full on every
invocation. The cache lives in `.medaka/lint-cache/` next to `medaka.toml`, is
safe to delete, and `medaka new` gitignores it. `--cache` is a no-op alongside
`--fix` and `--json`.

## Editor setup

`medaka lsp` speaks LSP over stdio and provides diagnostics, formatting,
document symbols, hover, go-to-definition, highlights, completion, and inlay
hints.

### VS Code / Cursor

`editors/vscode-medaka/` provides syntax highlighting through a TextMate grammar
and connects to `medaka lsp` for diagnostics. From the repository root:

```sh
ln -s "$(pwd)/editors/vscode-medaka" ~/.vscode/extensions/medaka
ln -s "$(pwd)/editors/vscode-medaka" ~/.cursor/extensions/medaka   # Cursor
```

Restart the editor. To install as a VSIX instead, run `vsce package` inside
`editors/vscode-medaka` (after `npm install -g @vscode/vsce`) and `code
--install-extension` the result.

### Neovim (nvim-treesitter)

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

Copy the highlights query, then run `:TSInstall medaka` inside Neovim:

```sh
mkdir -p ~/.config/nvim/after/queries/medaka
cp tree-sitter-medaka/queries/highlights.scm \
   ~/.config/nvim/after/queries/medaka/highlights.scm
```

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

```sh
mkdir -p ~/.config/helix/runtime/queries/medaka
cp tree-sitter-medaka/queries/highlights.scm \
   ~/.config/helix/runtime/queries/medaka/highlights.scm
```

### Zed

Create a language extension following the
[Zed extension docs](https://zed.dev/docs/extensions/languages), point
`grammar.repository` at `tree-sitter-medaka/`, and set `file_types = ["mdk"]`.

### Rebuilding the tree-sitter grammar

```sh
cd tree-sitter-medaka
npm install
npx tree-sitter generate   # regenerates src/parser.c
npx tree-sitter test       # run corpus tests
```

## Source layout

The pipeline stages, in order: lexer, parser, AST, desugar, resolver, type
checker (which runs exhaustiveness checking per `match`), then either the
tree-walking evaluator or Core IR lowering followed by an emitter (LLVM text IR
through `clang`, or WasmGC for the playground). `AGENTS.md` carries the
authoritative stage table.

```
compiler/
  frontend/   lexer, parser, ast, desugar, resolve, marker, exhaust
  types/      typecheck, annotate, repr
  ir/         core_ir, core_ir_lower, core_ir_sexp, dce
  backend/    llvm_emit, wasm_emit, private_mangle, trmc_analysis
  eval/       eval (tree-walking interpreter, dict-passing dispatch)
  driver/     loader, diagnostics, build_cmd, medaka_cli
  tools/      printer, fmt, lsp, doc, doctest, test_cmd, repl, new_cmd, check
  support/    compiler-private mini-stdlib
  entries/    per-stage probe entry points
  seed/       emitter.ll.gz, the IR seed for cold bootstrap
stdlib/       runtime.mdk (extern catalog), core.mdk (prelude), list, string, array, ...
runtime/      medaka_rt.c, the C runtime with Boehm GC
test/         run_gates.sh, diff_compiler_*.sh gates, *_fixtures/, *_goldens/
tree-sitter-medaka/   grammar.js, generated parser, highlight queries
editors/vscode-medaka/   VS Code / Cursor extension
```

The stdlib reference is generated: [docs/stdlib/index.md](../stdlib/index.md).
Conventions for adding primitives are in [stdlib/README.md](../../stdlib/README.md).
