# frontend/ — source text to resolved, marked AST

**Status:** CURRENT — re-derived from source at e6ed1546a6ab399d084f40fb118c294fc36dfdef on 2026-10-15. When it drifts, re-derive; do not patch.

## What this directory is
The first four stages of the pipeline (`ARCHITECTURE.md` section 1): lexer, parser, desugar,
resolve, plus the marker and the pre-desugar guard-exhaustiveness check. It sits just above
`support/` in the layering (A1). It consumes source text and produces the surface AST, then the
desugared and resolved AST that `types/` infers over. Syntactic only: no type information.

## Parts
| Module | Owns | Entry points |
|---|---|---|
| `ast.mdk` | The surface (pre-desugar) AST nodes the parser builds; post-parse-only nodes are omitted by design | `Lit`, `Expr`, `Decl`, `Pat` |
| `lexer.mdk` | Tokenizer plus the INDENT/DEDENT/NEWLINE layout pass | `tokenize` |
| `parser.mdk` | Monadic combinator parser over the token list; stratified operator ladder | `parse`, `parseLocated`, `parseResult` |
| `desugar.mdk` | Lowers sugar (guards, sections, interpolation, comprehensions, do, `?`, deriving) to the core AST; runs after parse, before resolve; owns the shared `mapExpr`/`mapDecl` traversal | `desugar` |
| `resolve.mdk` | Name environment and scope checks: unbound names, duplicates, privacy; single-file and multi-module paths | `resolveProgram`, `resolveModulesToLines` |
| `visibility.mdk` | A module's export surface, built from its declarations and the surfaces of the modules it re-exports; imports no resolver state | `ModuleExports`, `buildExportsWith`, `coreExports` |
| `marker.mdk` | Rewrites interface-method and constrained-function occurrences to marked nodes; not on `check`/`run`/`build` (typecheck marks per binding group) | `markWithPrelude` |
| `exhaust.mdk` | Guard-fall-through check on the raw pre-desugar AST via the pattern-matrix `useful` recursion; match exhaustiveness is in `types/` | `checkGuardExhaustiveness` |
| `parse_cache.mdk` | Source-keyed memo of the implicit prelude parse | `parsePrelude` |
| `desugar_cache.mdk` | Source-keyed memo of the desugared prelude, a sibling tier above `parse_cache` | `desugaredPrelude` |

## Laws that bind it
- **A1** — frontend imports only `support/` (and stdlib); it must not know Core IR, LLVM or any CLI verb.
- **A2** — `ast.mdk` carries no mutable field in the destination; today the typechecker writes dispatch routes into `Ref` cells that `ast.mdk` declares, which Phase 1 of the playbook removes.
- **A9** — the import closure of `frontend/ast.mdk` is a committed golden; adding an import to it fails the check.
- **A8** — a new frontend subsystem is a new module, as `parse_cache` and `desugar_cache` were.

## Boundaries and checks
- `test/arch_boundaries_test.mdk` pins layering edges, module-level cells, the hooks record and the leaf-module import closures.
- `test/arch_goldens/closure.frontend.ast.golden` is the closure of `ast.mdk`; `layering.golden` and `cells.golden` are the repo-wide counts.
- `test/arch_ratchet.sh` fails a rise in any pinned number unless a commit trailer names it.
- `test/stage_counts_test.mdk` pins per-stage work counts (`test/arch_goldens/stage_counts.golden`).
- Lexer, parser and desugar outputs are pinned by the snapshot corpus (`[T-SNAPSHOT-SELF]`).

## Where the design lives
- `ARCHITECTURE.md` and `ARCHITECTURE-PLAYBOOK.md` for the laws and the plan (`A2` is playbook Phase 1).
- `docs/spec/SYNTAX.md` and `docs/spec/LAYOUT-SEMANTICS.md` for syntax and layout ground truth.
- `ERROR-QUALITY.md` and `DIAGNOSTIC-CODES-DESIGN.md` for diagnostics wording and codes.

## Traps
- `[P-DESUGAR-FIRST]` — desugar runs before resolve and typecheck; sugar-shape checks must run on the raw AST.
- `[P-NO-MARK-PASS]` — `markWithPrelude` is not on a production verb.
- `[T-LAYOUT-SPEC]` — a token stream the parser cannot consume is a parser bug.
- `[T-GLOBAL-TABLE]` — a new AST constructor means auditing every `_ =>` arm.
- `[DG-REMOVED]` — removed syntax is a hard parse error, not a warning.
