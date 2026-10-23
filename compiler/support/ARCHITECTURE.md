# support/ — the compiler-private mini-stdlib, the hooks seam and the write-only counters

**Status:** CURRENT — re-derived from source at `ffd3bdb65897da35db70d06dbb5df3df35d884d7` on 2026-10-15. When it drifts, re-derive; do not patch.

## What this directory is
The bottom layer of A1 (`ARCHITECTURE.md` section 1): `support` < `frontend` < `types` < `ir` <
`backend`. Every stage imports from it and it imports no stage. It holds the small list, string,
path and map helpers the compiler uses instead of the public standard library, one shared graph
algorithm, the late-bound hooks seam (A6) and the process-wide counters (A7).

## Parts
| Module | Owns | Entry points |
|---|---|---|
| `util.mdk` | Shared list, string and option helpers; a generic helper goes here, not hand-rolled locally | `reverseL`, `minI`, `startsWith` |
| `char.mdk` | ASCII `Char -> Bool` predicates for the lexer, parser and lsp | `isSp`, `isTab` |
| `path.mdk` | POSIX path string operations | `dirOf`, `joinPath` |
| `ordmap.mdk` | `OrdMap a`, a transparent alias for `Map String a`, with String-keyed helpers | `omEmpty`, `omInsert`, `omLookup` |
| `scc.mdk` | Tarjan's strongly connected components, used to order top-level groups and effect equalities | `tarjanSCCs` |
| `manifest.mdk` | Typed accessors for `medaka.toml`'s own schema; not in `stdlib/toml.mdk` on purpose | `packageName`, `packageVersion` |
| `cli_targets.mdk` | The shared walk from a CLI path argument to the `.mdk` files a verb works on (lint, fmt, codemod, test, snapshot) | `expandLintTarget` |
| `sexp_value.mdk` | S-expression values, one rendering, a fail-closed reader | `renderSExp`, `parseSExp` |
| `hooks.mdk` | The late-bound hooks seam: a contract header plus `hookUnset`; the `Hooks` record is not yet written | `hookUnset` |
| `stage_count.mdk` | Per-process stage call counters, write-only, dumped to stderr | `stageBump`, `stageCountInit`, `stageDump` |
| `opcount.mdk` | A deterministic per-stage operation counter that sees a quadratic scan; write-only | `opBump` |
| `timer.mdk` | Per-stage wall-clock timing under `MEDAKA_PERF`; output on stderr | `emitPhase`, `emitTotal` |

## The hooks seam (A6)
`hooks.mdk` is the only place a lower module may read a higher module's behaviour without an import.
The first consumer adds a `data Hooks` record of function-typed lookups and one `Ref (Option Hooks)`,
installed whole by `driver/medaka_cli.mdk` and `entries/entry_support.mdk`. Until then the file is the
header and `hookUnset : String -> a`, which panics naming the field. Hooks are for rendering, tooling
and backend-fact lookups, and never inside inference: `test/arch_boundaries_test.mdk` fails a `types/`
module outside its allowlist (empty today) whose import closure reaches `support.hooks`.

## The counters (A7)
`stage_count.mdk` counts how many times each stage ran in this process, so a duplicated stage shows as
a number. It is write-only: only `stageDump` reads it, no pass may, so output is identical with
counting on or off. Counting is on when `MEDAKA_STAGE_COUNTS` is non-empty; the dump goes to stderr as
`[stage]<TAB>key<TAB>n`. `opcount.mdk` and `timer.mdk` follow the same rule.

## Laws that bind it
- **A1** — imports only the prelude and the standard library; no stage.
- **A3** — `scc.mdk` (6), `stage_count.mdk` (2), `opcount.mdk` (2) and `timer.mdk` (3) hold module-level cells, counted in `cells.golden`.
- **A6** — one hooks record, fields counted, no reader inside inference.
- **A7** — counters never feed control.

## Boundaries and checks
- `test/arch_boundaries_test.mdk`: layering, cells and the hooks reader allowlist.
- `test/arch_goldens/hooks.golden` (`hooks.fields`), raised only with a `Hooks-Field:` commit trailer via `test/arch_ratchet.sh`.
- `test/stage_counts_test.mdk` with `test/arch_goldens/stage_counts.golden`.
- Module tests: `util_test.mdk`, `ordmap_test.mdk`, `scc_test.mdk`, `sexp_value_test.mdk`.

## Where the design lives
- `ARCHITECTURE.md` A6 and A7; `ARCHITECTURE-PLAYBOOK.md` decision D2 and the G2b row.
- `[T-STDLIB-IMPORT]` for why `manifest.mdk` imports `toml` while the loader scans `medaka.toml` itself.
- Owners: #4201, #4202.

## Traps
- `[T-STDLIB-IMPORT]` — import `list` and `string` selectively; never `.*`-import two modules with colliding names.
- `[T-GLOBAL-TABLE]` — key a new table by scope and audit every `_ =>` arm.
- `[H-FMT]` — a hook-field addition needs its commit trailer.
