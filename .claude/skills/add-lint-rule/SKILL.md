---
name: add-lint-rule
description: Add a lint rule to `medaka lint` - the rule module, the single registry line, classification (universal vs internal), fixtures, the ratchet drain, the perf budget, the generated rules page and goldens. Use when adding or changing a rule in compiler/tools/lint_rule_*.mdk.
---

# Add a lint rule

One rule = one module + one registry line. The framework (`lint_core`, `lint_dup`, `lint_walk`)
and the CLI never name a rule; `compiler/tools/lint_registry.mdk` is the only place that lists them
(`lint_shared` holds the `ruleName*` constants). Module map: `compiler/tools/ARCHITECTURE.md`.

## 1. The module

Create `compiler/tools/lint_rule_<name>.mdk` (universal) or
`compiler/tools/lint_rule_internal_<name>.mdk` (internal), with a one-line header comment
`-- lint rule <rule-name>: <what it flags>. <what to write instead>.` where `<rule-name>` is the
full registered name including its `rule-` prefix (`-- lint rule rule-not-eq: ...`), then imports. It exports
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
registry or the runner (`lint_walk`). A helper two rules need moves to `lint_shared` and is
exported only once a second module reads it. Rule-name constants live in `lint_shared.mdk`. Reach for `stdlib/` and
`compiler/support/` helpers before writing one (`docs/stdlib/index.md`).

## 2. The registry line

In `lint_registry.mdk` add `import tools.lint_rule_<name> as Alias` and one `Alias.rule,` entry in
`allRules`. The list position IS the output order of findings; place the entry where its output
should sort. Cross-file rules are `ProjectRule`s and go in the project registry instead
(`allProjectRules`), and three things follow:

- A project rule has a `prSummarize` (one file to a `Summary`, a pure function of that file) and a
  `prEvaluate` (every file's summary to findings, run on every run). Add a `Summary` constructor
  with its codec arms in `lint_cache.mdk` (`encSummary`, `summaryTag`, `readSummary`; the encoder
  has no wildcard arm, so a missing arm does not compile). Every registered rule's summary is
  stored in the shard, so `--cache` stays on with no switch to relax.
- A project rule may not be `ratchet = Baselined`: a baseline row is per file and a cross-file
  finding has none, so nothing would enforce it. `projectRuleMetaProblems` rejects it and
  `lint_test.mdk` runs that check over `allProjectRules`.
- A project rule with `scope = Internal` is fine: `dropInactiveInternalProject` filters its
  findings by whether internal rules are active for the file each lands in, on the text, `--json`,
  `--cache` and MCP paths alike.

## 3. Classify

- `Universal`: the pattern is worse in any Medaka program, whatever the project.
- `Internal`: this repository's taste, convention or compiler-private code. It runs only under
  `--internal` or a manifest whose `[lint]` section says `internal = true`; the CLI and
  `medaka_lint` over MCP share one activation helper (`internalDisabledFor`, `lint_cmd.mdk`).
- `ratchet = Gated` means zero findings across every per-file root: `compiler stdlib sqlite` and
  the five other top-level directories holding tracked `.mdk` outside `test/` (eight in all),
  which `test/diff_compiler_lint_baseline.sh` lints. `Baselined` (a per-file count that may only
  fall) needs Val's ruling; so does an advisory severity.

`fixability` caps what `--fix` may apply, and the fix itself is a span edit: see § 8.

## 4. Fixtures

A rule's tests are `test/lint_rule_fixtures/<name>.mdk` (name without the `rule-` prefix, plus
`.fixed` when fixable), run by the harness `compiler/tools/lint_rule_fixtures_test.mdk` with only
that rule enabled, so a new rule moves no other rule's golden. Mark positives
`-- expect-next-line <rule>` in a top-level function, a `test` body, a `prop` body and a let-group
or interface default; include a case that must NOT fire (the false-positive guard); add the name
to `fixtureNames` and a `test` block (grammar in its header). Decide the expected output from the
rule's doc; a golden records what the engine did. Native tests go in `compiler/tools/lint_test.mdk`
(`expectEqual`, `expectTrue`). Its registry test derives its counts from the registry (the listing
equals `allRuleNames`; scope and ratchet filters partition it), so a new rule bumps no number there.

`test/lint_fixtures` and `test/lint_fix_fixtures` keep only what the marker grammar cannot express
(directive suppression, the fixer's interior-comment and `test`-import cases). Each of their
fixtures names its rules in that directory's `ONLY.txt` and runs `--only=<those rules>`; a new
entry there raises the expected count in the matching narrowed-failures call in
`test/diff_compiler_fmt_test.mdk`. Re-cut those goldens with
`sh test/capture_goldens.sh --frozen lint` / `--frozen lint_fix`.

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

Before pushing, drain the whole tree the way the hook and the CI twin do: `lint --internal` over
every top-level directory, not only `compiler stdlib sqlite`.

## 8. Fixes

A fix is a span edit. The visitor attaches a `Fix` (`fixApplicability`, `fixEdits : List FixEdit`,
`fixMessage`) to each finding; `fixSource` in `tools/lint.mdk` runs the edit loop over the rules that
emit edits, then the decl-rewrite adapter. `compiler/tools/lint_fix.mdk` validates every edit against
the source snapshot, applies a non-overlapping subset, re-parses, and repeats for at most 32 passes.
A rule whose fix cannot be expressed as span edits stays on the decl-rewrite adapter (`exprRuleFix`
in `lint_shared.mdk`).

**Ceiling.** `fixability` caps what `--fix` may apply: `Fixable` is `Safe`, `FixableUnsafe` is
`Unsafe` (applied only under `--unsafe-fixes`), `SuggestOnly` is `Suggest` (never applied).
`grep -ln 'FixableUnsafe\|SuggestOnly' compiler/tools/lint_rule_*.mdk` lists the rules that use the
last two.

**Build the fix.** In the visitor, with the detector's rewritten node `rewritten` and the node `e`:

```
replaceFix "<one-line message>" (nodeSpan ctx e) (bindingOf rewritten) ctx (exprToString rewritten)
```

- `nodeSpan ctx e` is the node's own `ELoc`, brackets included, else `tightSpan e` (the operands'
  extent). It is `None` when an operand is a prefix or field node whose tokens no `ELoc` covers, so
  the fix is withheld rather than placed wrong.
- `bindingOf` grades the rewritten text: `Closed` (an atom), `Applied` (a call), `Open` (an operator,
  `if`, lambda, `match`). `parenIfNeeded` (`lint_fix.mdk`) brackets it for the parent kind in `ctx`.
- `replaceFix` returns `None` for text spanning more than one line: the printer does not know the
  indentation the text lands in.
- A lambda's `ELoc` starts at its arrow and its parameters carry no `Loc`. Write a span function like
  `lambdaSpan` (`lint_rule_lambda_section.mdk`) or return `None`.
- A `Fix` may hold several edits; they must not overlap each other, or the whole fix is dropped.
- `exprRuleEditVisitors` skips test and prop bodies (`not ctxInTest`). A rule that must reach them
  builds its own `OnExpr` visitors, or uses a hint row (section 9), whose visitor reaches them.

**Choose the applicability.**

- `Safe` only when the rewrite cannot change meaning. Guard what it reads or writes, and set
  `needs = [NeedsScopes]` in the meta:
  - a prelude name the rewrite consumes from a matched call: `usesPreludeName facts hd`, per use;
  - a prelude name the rewrite introduces: `bindsName facts "<name>"`, file-wide, because a binder
    carries no extent to test a use against;
  - an instance method the introduced call could resolve to: `rule-if-max-min` withholds inside an
    `impl Ord` (`inOrdImpl`), where the call would resolve to the method being defined.
- `Unsafe`: the rewrite may change behaviour, and the author accepts it under `--unsafe-fixes`.
- `Suggest`: never applied. The driver demotes to `Suggest` any fix whose edit overlaps a comment,
  so a rule need not declare it for that.

**Fixtures.** On top of § 4, a fixable rule's `.fixed` fixture carries:

- a rebound-name case, marked `unfixed`, for each guarded name;
- one bracket case per parent kind the output can meet: an argument, an operator operand, a chain;
- a comment inside the replaced span (`unfixed`) and a comment outside it (fixed, comment kept);
- a `-- lint-disable-next-line <rule>` case.

Place each marker on the line the finding reports. Read that line from `medaka lint --json` on the
fixture rather than guessing: a bare application at the root of a multi-line declaration reports on
the declaration's line. Regenerate `.fixed` with `medaka lint --fix --only=<rule>` on a copy, read
the diff against the `.mdk` line by line, and classify every moved line:

- **E1** a pinned line that does not move;
- **E2** a newly fixed site whose comment lies outside the span (the old adapter bailed on any
  comment in the declaration);
- **E3** a newly reached body (test, prop, `let rec`, interface default) the old fixer never rewrote,
  if the rule's visitor admits it;
- **E4** a pinned positive now withheld by a guard;
- **D** a site a directive suppresses that the old adapter rewrote; the edit path honours directives.

**Stays on the adapter.** A rule stays when its fix reshapes a pattern: `rule-bind-then-destructure`
changes a bind's pattern and splices an arm body into the block. A fix that also edits an import
can be one multi-edit `Fix` when the import edit depends on that finding alone. When the import is a
union over the file's other findings, as the test-verb import widen is for `rule-test-equal-in-true`
and `rule-test-bool-literal-equal`, the rule stays on the adapter until the driver can compute the
union.

## 9. A rewrite rule is a hint row plus a fixture

When the rule rewrites one expression shape to another, write a row, not a detector. A row is
`lhs ==> rhs` in Medaka syntax, in `hintRows` of the rule module; `compiler/tools/lint_hints.mdk`
is the matcher. `lint_rule_not_eq.mdk` and `lint_rule_double_reverse.mdk` are the models:

```
HintRow {
  rowText = "reverse (reverse a) ==> a",
  rowMessage = "`reverse (reverse …)` is a no-op",   -- finding: "<message>. Rewrite as '<rhs>'"
  rowFix = "drop the double reversal",
  rowApplicability = Safe,
  rowConds = [],
}
```

and `hints = compileHints hintRows`, `mkVisitorRule meta (idx path facts pos decls => hintVisitors <ruleName> SevWarning hints idx path facts pos decls) None`
(the lambda keeps the rows unparsed until the rule runs).

- **Metavariables:** a single lowercase letter, optionally followed by digits (`a`, `b`, `x1`). It
  binds any subexpression; a repeated one must match structurally equal subexpressions. Any other
  name is literal and matches the unqualified spelling only.
- **Templates** hold names, literals, the empty list `[]`, applications and binary operators. The left side's root is an
  application or an operator; every metavariable of the right side is bound on the left.
- **Prelude guard (always on):** each lowercase literal name on the left is a head. Each matched use
  must resolve to the prelude (`usesPreludeName`: no binder, no wildcard import that may bring the
  name), else the finding is reported without a fix. The same holds for each lowercase name the
  right side writes (`rebinds`: the file binds it, a wildcard import may, or it is the enclosing definition). Declare `needs = [NeedsScopes, NeedsWildIndex]`.
- **`Atomic "m"`:** the row matches only where `m` is bound to a name or a literal.
- **`NotInDefOf names`:** the fix is withheld inside the definition of a function so named.
- The replacement text is the right side printed with the matched subexpressions put in, bracketed
  for its parent (`parenIfNeeded`); the first matching row reports. A row that does not compile
  panics when the rule first runs, and `lint_hints_test.mdk` compiles every row listed there: add the
  module's `hintRows` to its "every registered row compiles" test.
- **Fixture:** `test/lint_rule_fixtures/<name>.{mdk,fixed}` with a positive, a shadowed head (a
  `where`, a `let` and a parameter binding the name, marked `unfixed`) and the near misses.

**Do not use a row** for a rewrite that is not one expression to another (declaration or pattern
rewrites, several statements), that needs types, that depends on context the matcher cannot see
(strictness of a default, whether a scrutinee is a value), or whose right side spans lines.
