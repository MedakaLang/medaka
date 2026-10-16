# compiler — the Medaka-in-Medaka compiler

**Status:** CURRENT — the compiler is written in Medaka, self-hosts to a reproducing fixpoint and
builds an OCaml-free `medaka` binary through the native LLVM backend. The OCaml reference compiler
was removed on 2026-06-26.

## What it is
`compiler/` is one project (`compiler/medaka.toml`). The whole pipeline (lexer, parser, desugar,
resolve, typecheck, Core IR, emitters, interpreter and every `medaka` verb) is Medaka source. The
LLVM emitter turns it into text IR, `clang` links that with the C runtime (`runtime/medaka_rt.c`)
and Boehm GC, and the result is the `medaka` binary that compiles this tree again.

For the pipeline, the layers and the laws that bind them, read `ARCHITECTURE.md` section 1 and
its laws A1 to A10. For the plan that closes the gaps, `ARCHITECTURE-PLAYBOOK.md`. For rules an
agent must follow while editing here, `AGENTS.md` in this directory and the repository root.

## The directory maps
Each directory has an `ARCHITECTURE.md` that lists its modules, the laws that bind it, the
guards that check it and its traps. Open the map before editing a file in that directory.

| Directory | Role | Map |
|---|---|---|
| `frontend/` | Lexer, parser, desugar, resolve, exhaustiveness | [frontend/ARCHITECTURE.md](frontend/ARCHITECTURE.md) |
| `types/` | Type inference, interfaces, effects, facts downstream stages read | [types/ARCHITECTURE.md](types/ARCHITECTURE.md) |
| `ir/` | Core IR: types, lowering, serialization, DCE, the Core IR interpreter | [ir/ARCHITECTURE.md](ir/ARCHITECTURE.md) |
| `backend/` | LLVM and wasm emission, TRMC analysis | [backend/ARCHITECTURE.md](backend/ARCHITECTURE.md) |
| `eval/` | The tree-walking interpreter and its 64-bit integer halves | [eval/ARCHITECTURE.md](eval/ARCHITECTURE.md) |
| `driver/` | The `medaka` CLI dispatcher, loader, diagnostics, `build` | [driver/ARCHITECTURE.md](driver/ARCHITECTURE.md) |
| `tools/` | One module per user-facing tool: fmt, lint, test, doc, lsp, mcp, gate | [tools/ARCHITECTURE.md](tools/ARCHITECTURE.md) |
| `support/` | The compiler-private mini-stdlib, the hooks seam, write-only counters | [support/ARCHITECTURE.md](support/ARCHITECTURE.md) |
| `entries/` | Per-stage probe mains for the differential gates and oracles | [entries/ARCHITECTURE.md](entries/ARCHITECTURE.md) |

`seed/` holds the checked-in LLVM IR seed for the cold bootstrap; `test/refresh_seed.sh` manages
it and nothing edits it by hand.

## Building
`make medaka` builds the binary (cold bootstrap from `seed/`, then a two-stage rebuild). The
as-built bootstrap log and the fixpoint procedure are in [BOOTSTRAP.md](BOOTSTRAP.md); native
codegen gaps are in [EMITTER-GAPS.md](EMITTER-GAPS.md). Testing is `make preflight`, described
in the repository root `AGENTS.md`.

## Where history lives
- `archive/design/` holds designs that shipped. The bootstrap-era port log that used to be this
  file is [archive/design/COMPILER-PORT-LOG.md](../archive/design/COMPILER-PORT-LOG.md).
- `docs/design/` holds proposals that are open or unlanded.
- `docs/README.md` is the generated index of both.
