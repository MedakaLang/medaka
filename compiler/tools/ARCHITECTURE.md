# tools/ — one module per user-facing tool: check, fmt, lint, test, doc, lsp, mcp, gate

**Status:** CURRENT — re-derived from source at `ffd3bdb65897da35db70d06dbb5df3df35d884d7` on 2026-10-15. The `lint*` rows were re-derived at `0b4dd5bb05916f91a392e47493ef4421a0881387` on 2026-10-29. When it drifts, re-derive; do not patch.

## What this directory is
The verbs and services built on the pipeline (`ARCHITECTURE.md` section 1), at the top of A1 beside
`driver/`: `driver/medaka_cli.mdk` dispatches to them, and nothing below imports them. Each tool
parses, desugars and checks its own input; the destination is that all of them read one memoized
set of entries (#4141).

## Parts
| Module | Owns | Entry points |
|---|---|---|
| `check.mdk` | The composed front-end pass parse, desugar, resolve, exhaust, typecheck | `runCheck`, `runCheckFromDecls` |
| `check_policy.mdk` | `medaka check-policy`: does an entry's effect summary fit an allow list | `analyzeProgram`, `runCheckPolicy` |
| `target_check.mdk` | Does an entry fit a target profile; a refusal is one located diagnostic | target-capability check |
| `target_parse.mdk` | One parse, desugar and comment scan of a `medaka test` target per process | per-process memo |
| `printer.mdk` | The comment-free Wadler/Leijen document printer over the AST | AST to source |
| `fmt.mdk` | The comment-preserving formatter over `printer.mdk` | `formatProgram` |
| `lint.mdk` | The `medaka lint` facade: re-exports the framework, registry and runner surface the CLI, MCP and tests consume; holds the `--fix` driver | re-exports, `fixSource` |
| `lint_core.mdk` | The framework's data types: `Finding`, `Fix`, `FixEdit`, `Applicability`, `Fixability`, `Directive`, `FileFacts`, `Rule`, `RuleCheck`, `Ctx`, `Visitor`, `RuleMeta`, `StdlibIndex`; imports no rule, registry or runner; its closure still holds about 100 `types.*` modules, reached through `frontend.exhaust` (`Oracle`) and `tools.printer` (`ppTy`), pinned by `test/arch_goldens/closure.tools.lint_core.golden` | types |
| `lint_shared.mdk` | Helpers used by more than one lint module: rule-name constants, location helpers, the directive parser, stdlib path predicates | shared helpers |
| `lint_scope.mdk` | The per-file scope model: every binder with its kind and span, every identifier use resolved to its binder, unused local binders and import-member use counts; built on `frontend.ast_walk`, forbidden to import `types.*` or `tools.refindex`; built as a `FileFacts` memo only for a rule whose `needs` lists `NeedsScopes` | `FileScopes`, `binderOf`, `unusedBinders`, `importUses` |
| `lint_dup.mdk` | The duplicate-body occurrence engine: per-clause facts, grouping and the cross-file join | `fileDupOccs` |
| `lint_walk.mdk` | The lint runner: the one visitor walk per file, per-file facts, the autofix driver, filters, inline suppressions, the cross-file runner, stdlib-index builders; imports `lint_registry`, since running a rule means reading the registry's lists | `lintProgram*`, `runVisitors` |
| `lint_fix.mdk` | The `--fix` edit pipeline: resolves each fix's span edits against the source snapshot, applies the non-overlapping subset the applicability limit allows, re-parses; imports no rule, registry or runner (the caller passes the linter in) | `applyFixes`, `parenIfNeeded` |
| `lint_registry.mdk` | THE REGISTRY: `allRules`, the cross-file registry and rule-name selection; one `import ... as Alias` and one `Alias.rule,` line per rule | `allRules`, `allCrossFileRules`, `allRuleNames` |
| `lint_rule_<name>.mdk` | One universal lint rule per module, exporting `rule`; may not import another rule module, the registry or the runner | `rule` |
| `lint_rule_internal_<name>.mdk` | One internal-scope rule (this repository's conventions) per module, exporting `rule`; same import limits | `rule` |
| `lint_cmd.mdk` | The `medaka lint` engine: targets, cached pass, cross-file tier, JSON | lint engine |
| `lint_cache.mdk` | The on-disk per-file cache behind `lint --cache` | content-keyed shards |
| `lint_baseline.mdk` | The per-file, per-rule finding-count baseline | `--baseline` reader |
| `codemod.mdk` | Named source-preserving AST transforms and their registry | codemod registry |
| `doc.mdk` | `medaka doc`: doc-comment extraction and Markdown rendering, single file or library | `runDoc`, `renderModulePage` |
| `lsp.mdk` | The language server: hover, completion, references, rename | LSP server |
| `lsp_harness.mdk` | A native harness driving the `medaka lsp` binary over JSON-RPC | test harness |
| `mcp.mdk` | `medaka mcp`: the MCP server over stdio and its tool registry | tool registry |
| `refindex.mdk` | The whole-project binder-keyed reference index under references and rename | reference index |
| `repl.mdk` | The self-hosted REPL | REPL loop |
| `new_cmd.mdk` | `medaka new`: project scaffolding | `newProject` |
| `syntax_cache.mdk` | Session-owned bounded FIFO reuse of exact prepared syntax | `lookupSyntax`, `insertSyntax`, `invalidateSyntax` |
| `source_edits.mdk` | Validate and apply immutable source edits | `validateSourceEdits`, `applySourceEdits` |
| `snapshot_syntax.mdk` | Binds a source revision to admitted syntax and the shared source index, or budget metadata alone | `prepareSnapshotSyntax`, `snapshotSyntaxSource` |
| `snapshot.mdk` | `medaka snapshot`: the in-process snapshot runner | snapshot verb |
| `test_cmd.mdk` | `medaka test`: doctests, properties and `test` blocks, shared by CLI and probe | `runTest` |
| `test_runner.mdk` | The `test "…"` declaration runner returning an `Expectation` value | test rows |
| `doctest.mdk` | Doctest extraction and running | `ExResult` |
| `native_doctest.mdk` | The native doctest engine: compile the module plus examples, run, report | native engine |
| `native_test_decls.mdk` | The native engine for `test "…"` declarations (`medaka test --native`); named to avoid the `_test.mdk` sibling suffix | `runNativeTests` |
| `native_props.mdk` | The native property runner: one probe per target | native engine |
| `native_probe.mdk` | One probe build for all the native arms of a file, run once per arm, with per-arm fallbacks | `runMergedNativeArms` |
| `probe_transcript.mdk` | The sentinel-delimited stdout format both native engines read back | transcript format |
| `prop_plan.mdk` | Engine-neutral property planning: parameter types, constructors, shrink order | plan layer |
| `prop_helpers.mdk` | Typed bridge bindings for custom `Arbitrary` parameters | bridge bindings |
| `prop_runner.mdk` | The interpreted property runner: generate, check, shrink | `PropResult` |
| `eval_props.mdk` | Nonce-framed rows between `test_cmd` and the isolated property worker | worker protocol |
| `test_pins.mdk` | The typed known-red ledger schema and parser | `medaka-test-pins.toml` |
| `test_pins_io.mdk` | The filesystem context for that ledger | project pin lookup |
| `test_pins_report.mdk` | Verdict grading of raw runner outcomes against the ledger | pin verdicts |
| `gate_cmd.mdk` | `medaka gate`: list, run, verify and the other registry commands | gate verbs |
| `gate_registry.mdk` | The `test/gates.toml` schema, reader, selector language and renderers | registry reader |
| `gate_cost.mdk` | The reader for `test/gate_cost_baseline.json` | cost baseline |
| `gate_pack.mdk` | The gate scheduler: bin packing and the budget governor | `balance`, `budget` |
| `interface_cmd.mdk` | `medaka interface`: write, show and verify the prelude interface file | interface verbs |

`lint_fix.mdk` applies the span edits of `Fix` values in passes of at most eight, keeping the
non-overlapping subset that the applicability limit allows, and writes nothing when a pass's output
does not parse. `fixSource` in `tools/lint.mdk` runs that loop over the rules that emit edits, then
the decl-rewrite adapter for the rest.

## Writing a walking rule
A rule built with `mkVisitorRule` returns its visitors once per file from the same inputs a `WholeFile` check gets, and computes any per-file state there. `OnAnyExpr f` is called on every expression node whatever its kind; the detector-based rules (`exprRuleVisitors` in `lint_shared.mdk`) use it. `OnExpr kinds f` is called on every expression node whose `frontend.ast_walk.ExprKind` is listed, in every body `declBodies` names: function clauses, `impl` methods, interface defaults, tests, props and top-level let-group clauses. `OnDecl f` is called on every top-level declaration. Each call gets a `Ctx`: the body owner's name and parameter patterns, whether the body is a test or prop, the parent node's kind, and the nearest enclosing `ELoc` span. `lintProgramFacts` runs one walk for every visitor rule of the file and emits findings rule by rule in registry order. A rule that reads no expressions, such as dead-code or the comment rules, stays a `WholeFile` check built with `mkRule`. `Ctx` and `Visitor` live in `lint_core.mdk` because rule modules may not import `lint_walk.mdk`.

Two further shapes cover the rules that are not a per-node check. A rule that reports a pattern's outermost node and then consumes it (`rule-concat-to-interp`, `rule-orelse-staircase`, `rule-bind-chain-to-do`) is an `OnDecl` visitor over `declHeadHits` in `lint_shared.mdk`: the rule supplies only a `pick` function, and the descent is the shared `collectHeads` over `ast_walk.childExprs`. A decl-rewrite fixer uses `exprRuleFix` (bottom-up from a node-local detector); a span-edit fixer builds its edit with `replaceFix` over the node's span, and the driver in `tools/lint.mdk` applies the edits. A rule module holds no traversal of its own. `Ctx.ctxDeclLoc` is the declaration's start line, where an inline suppression sits; a rule that reports there rather than at `ctxSpan` keeps its existing suppressions.

## Laws that bind it
- **A1** — `tools` may import any lower layer; only `driver` and `entries` import `tools`.
- **A3** — `printer.mdk`, `repl.mdk`, `prop_runner.mdk`, `lsp.mdk`, `lsp_harness.mdk`, `probe_transcript.mdk`, `test_cmd.mdk`, `refindex.mdk` and `target_parse.mdk` hold module-level cells; `cells.golden` counts them.
- **A5** — `check.mdk` and the lint tier report diagnostics as data.
- **A7** — `target_parse.mdk` is the compute-once memo for `medaka test`.

## Boundaries and checks
- `test/arch_boundaries_test.mdk`, `test/arch_goldens/layering.golden`, `cells.golden`.
- The pre-commit hook (`.githooks/pre-commit`): format, lint rules and snapshot check over staged `.mdk`. The hook and `test/diff_compiler_lint_baseline.sh` pass `--internal` for every root, not only `stdlib/`, so the internal-scope rules are enforced wherever they lint, whatever a project's manifest says; both derive their rule lists through `test/lint_rule_lists.sh`.
- `test/gates.toml` and `medaka gate verify`: the registry these modules read.
- Module tests are `*_test.mdk` siblings.

## Where the design lives
- `docs/ops/CLI-CONFORMANCE.md`, `docs/ops/MCP.md`, `docs/design/TYPE-AWARE-LINT-DESIGN.md`.
- `ARCHITECTURE.md` section 3: one file per tool over memoized entries (#4141).

## Traps
- `[P-TEST-SIBLING]` — a compiler-internal test is a `foo_test.mdk` sibling.
- `[W-MODULE-BLIND]` — a module outside every entry's import closure is invisible to `make medaka`; name it in the Makefile `test:` target.
- `[H-FMT]`, `[H-LINT]` — the hook runs fmt and lint over staged `.mdk`.
- `[T-PERRUN-COMMENTS]` — diff `fmt --write` output on comment-bearing record decls.
- `[W-SHARD-DERIVED]` — `shard` in `test/gates.toml` comes from `medaka gate balance`.
