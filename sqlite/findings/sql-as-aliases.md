# SQLite dogfood findings — `AS` aliases (column + table)

Task: thread `AS` aliases (column-output aliases and table aliases in FROM/JOIN)
through `lib.sqlparse`/`lib.sqlstmt`/`lib.select` — parser, AST, renderer, executor.

The language held up well — most of the work was straightforward. One genuine tooling
papercut, one minor gate-running friction, and two positives worth recording (including
one I initially mis-diagnosed and had to walk back).

## F1 — cross-file `rule-duplicate-body` fires on the standard in-memory `specs` test fixture

- **Category:** tooling (`medaka lint`)
- **Severity:** annoyance
- **Repro:** add any new `sqlite/*_probe.mdk`/`*_demo.mdk` that defines the usual
  in-memory `specs : List (String, String, Option Int, List (List Cell))` fixture the
  same way every other probe already does. `medaka lint sqlite` then reports:
  ```
  [rule-duplicate-body] function 'specs' has a body structurally identical to a
  definition in sqlite/inmem_groupby_probe.mdk, ... — consolidate into a shared module
  ```
- **Expected:** a per-file test fixture that is *deliberately* parallel across many
  independent demos shouldn't be flagged as accidental logic duplication.
- **Actual:** every new probe/demo trips the cross-file rule and must carry a
  `-- lint-disable-file rule-duplicate-body` — which is exactly what the existing probes
  already do (see `inmem_join_probe.mdk:15`), so the rule is already opted out of, one
  file at a time, across the whole corpus.
- **Workaround:** added the `lint-disable-file` directive, matching the convention.
- **Notes:** `compiler/tools/lint.mdk`. The rule can't distinguish "shared boilerplate
  test fixture" from real logic duplication. A directory-scoped suppression, or exempting
  nullary data fixtures, would remove a papercut every new probe hits — the current state
  (N files each disabling the same rule) is the smell the rule is meant to catch, inverted.

## F2 — the sqlite `*_oracle.sh` gates need `bash` + `MEDAKA_ROOT`, not the `sh` the preflight list implies

- **Category:** tooling
- **Severity:** annoyance
- **Repro:** `PREFLIGHT_DRY=1 sh test/preflight.sh` lists `GATE sqlite/test/sql_oracle.sh`
  for a `sqlite/` diff. Running it the obvious way fails twice:
  ```
  $ sh sqlite/test/sql_oracle.sh
  sqlite/test/sql_oracle.sh:30: MEDAKA_ROOT: set MEDAKA_ROOT to the repo root
  $ MEDAKA_ROOT=$PWD sh sqlite/test/sql_oracle.sh
  sqlite/test/sql_oracle.sh:69: Syntax error: "(" unexpected     # bash arrays under dash
  ```
- **Expected:** the gate to run from the preflight-suggested invocation, or to say what
  it needs.
- **Actual:** it needs `MEDAKA_ROOT=<repo root> bash sqlite/test/<name>_oracle.sh`. The
  scripts use bash arrays (`QUERIES=( … )`), so `sh` (dash) rejects them.
- **Workaround:** ran them under `bash` with `MEDAKA_ROOT` exported. Once invoked
  correctly they work perfectly (and are the strongest validation available — a
  row-for-row diff against real `sqlite3`).
- **Notes:** minor, but CI presumably invokes them correctly; a human/agent copying the
  preflight line does not. A shebang-honoring runner or a one-line "run me with bash and
  MEDAKA_ROOT" banner would save the two-failure discovery loop.

## Positive — the "optional HEAD, mandatory tail" idiom gives clean alias errors (I mis-blamed it first)

I initially expected `parsec`'s unconditionally-backtracking `optional`/`orElse` (the
documented F5 limitation) to swallow a committed-`AS`-with-missing-alias into a far-away
"unsupported SQL" error, and nearly filed that as a finding. It does NOT: writing the
alias parser as `aliasOpt = do { hasAs <- optional (keyword "AS"); aliasAfterAs hasAs }`,
where the `Some` branch runs a `label`-wrapped `attempt` alias parser with no `orElse`
fallback beneath it, produces exactly the right message in every case I tried —
`SELECT a FROM users AS WHERE …` → `expected an alias name at 23`,
`SELECT a, b AS FROM t` → `expected an alias name at 15` (even for a non-first projection
item under `many`). The farthest-failure tracking surfaces the deep alias error over the
shallower clause-boundary error. The idiom the codebase already standardizes on is doing
its job; no finding. (Recording the walk-back so the next agent doesn't re-file it.)

## Positive — partial record patterns kept the `Select` ADT change small

Adding `fromAlias` + `columnAliases` to `Select` and `alias` to `Join` touched only the
sites that needed the new data. Every executor destructure that ignores them
(`runPipeline`, `renderJoin`, `joinTable`, …) is a PARTIAL record pattern, so it kept
compiling untouched — a wide, evolving ADT edited at a handful of sites instead of every
match arm. A concrete reason to prefer records over positional constructors here.

## Deferred (scope note, not a language finding)

Variadic `TRIM(x, chars)` / `LTRIM` / `RTRIM` (the 2-arg character-set form) stays
unsupported: `lib.sqlparse.fnFromArgs "TRIM" [a] = …; "TRIM" _ = failWith "TRIM(...)
expects exactly 1 argument"`, and `lib.select.compileFnCall` handles only the 1-arg form.
It is orthogonal to aliases (needs a new trim-set evaluator + sqlite3-verified
NULL/empty-set semantics), so it was left out to keep this PR focused. Clean follow-up.
