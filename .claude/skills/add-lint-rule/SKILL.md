---
name: add-lint-rule
description: Add a lint rule to `medaka lint` - the rule module, the single registry line, classification (universal vs internal), fixtures, the ratchet drain, the perf budget, the generated rules page and goldens. Use when adding or changing a rule in compiler/tools/lint_rule_*.mdk.
---

# Add a lint rule

One rule = one module + one registry line. The framework (`lint_core`, `lint_shared`,
`lint_dup`, `lint_walk`) and the CLI never name a rule; `compiler/tools/lint_registry.mdk` is the
only place that does. Module map: `compiler/tools/ARCHITECTURE.md`.

## 1. The module

Create `compiler/tools/lint_rule_<name>.mdk` (universal) or
`compiler/tools/lint_rule_internal_<name>.mdk` (internal), with a one-line header comment
`-- lint rule <rule-name>: <what it flags>. <what to write instead>.`, then imports. It exports
exactly `rule : Rule`, built with `mkRule`:

```
export
rule : Rule
rule = mkRule RuleMeta { name = "rule-name", summary = "...", doc = "...\n\nBefore:\n  ...\nAfter:\n  ...",
  category = Style, scope = Universal, ratchet = Gated, defaultSeverity = SevWarning,
  fixability = NotFixable, needs = [] } checkFn None
```

Import limits: a rule module imports `lint_core`, `lint_shared` (and `lint_dup` if it reads
duplicate facts) plus frontend/support modules. It may NOT import another rule module, the
registry or the runner (`lint_walk`). A helper two rules need moves to `lint_shared`.
Rule-name constants live in `lint_shared.mdk`. Reach for `stdlib/` and
`compiler/support/` helpers before writing one (`docs/stdlib/index.md`).

## 2. The registry line

In `lint_registry.mdk` add `import tools.lint_rule_<name> as Alias` and one `Alias.rule,` entry in
`allRules`. The list position IS the output order of findings; place the entry where its output
should sort. Cross-file rules go in the cross-file registry instead.

## 3. Classify

- `Universal`: the pattern is worse in any Medaka program, whatever the project.
- `Internal`: this repository's taste, convention or compiler-private code. It runs only under
  `--internal` or a manifest whose `[lint]` section says `internal = true`; the CLI and
  `medaka_lint` over MCP share one activation helper (`internalDisabledFor`, `lint_cmd.mdk`).
- `ratchet = Gated` means zero findings across `compiler stdlib sqlite`. `Baselined` (a per-file
  count that may only fall) needs Val's ruling; so does an advisory severity.

`fixability = Fixable` only with a `fix` that is a pure AST rewrite; the printer re-renders it.

## 4. Fixtures

`test/lint_fixtures/<name>.mdk` + `.expected` for report-only rules; `test/lint_fix_fixtures/<name>.mdk`
+ `.fixed` for fixable ones. Include a case that must NOT fire (the false-positive guard). Capture
with `sh test/capture_goldens.sh --frozen lint_fix` only after deciding the expected output from
the rule's doc; a golden records what the engine did. Native tests go in
`compiler/tools/lint_test.mdk` (`expectEqual`, `expectTrue`). Its registry test derives its counts
from the registry (the listing equals `allRuleNames`; scope and ratchet filters partition it), so a
new rule bumps no number there.

## 5. Ratchet and drain (same PR)

1. Census: `medaka lint --only=<rule> compiler stdlib sqlite` (add `--internal` for an internal rule).
2. Read the findings. A false positive is fixed by TIGHTENING the rule, never by suppressing sites.
3. Drain the real findings in the same PR so the rule lands gated at zero.
4. A site-specific `-- lint-disable-next-line <rule>` needs a comment in its block stating the
   constraint that forced it (`rule-directive-reason`).
5. Regenerate baselines only by tool: `sh test/diff_compiler_lint_baseline.sh --write`.

## 6. Perf budget

A new rule adds at most 2% to the Ir of `medaka lint compiler/frontend`. Measure before and after
with callgrind on a quiet box:

```sh
GC_MARKERS=1 valgrind --tool=callgrind --callgrind-out-file=$P/B.out \
  $W/medaka lint $W/compiler/frontend >/dev/null 2>$P/B.log; grep Collected $P/B.log
# tiny file:   $W/medaka lint $W/compiler/tools/source_edits.mdk           (arm C)
# cached path: $W/medaka lint --cache compiler stdlib sqlite  (run once to fill, then measure)  (arm D)
```

Wall time for the whole tree is the fourth arm: three runs of
`/usr/bin/time -f "%U+%S" $W/medaka lint $W/compiler $W/stdlib $W/sqlite` with
`GC_INITIAL_HEAP_SIZE=2147483648`. Share per-file facts through `FileFacts`
(`factComments`, `factOracle`, ...) rather than re-walking the AST.

## 7. Generated page, goldens, snapshots

- `medaka lint --list-rules --markdown > docs/ops/LINT-RULES.md` (`lint_test.mdk` fails on drift).
- `medaka fmt --write` and `medaka lint --internal` on every touched file, then `make medaka`.
- A new `.mdk`: `sh test/snapshot_bless.sh --new`; a moved one: `--bless <path>`; then
  `make snapshot-check`. Stage `test/snapshots/` last.
- `sh test/comment_register_census.sh --write test/comment_register_baseline.toml` if comment
  counts moved; `medaka test test/arch_boundaries_test.mdk` for the module-shape goldens
  (`test/arch_goldens/`).
- `MEDAKA_STRICT=1 medaka test compiler/tools`.
