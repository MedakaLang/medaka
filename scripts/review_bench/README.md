# scripts/review_bench — measuring a cheap style reviewer

**Status:** harness, 2026-10-17. Design: `docs/design/REVIEW-WORKFLOW-DESIGN.md`.
Rules and classes: `docs/design/STYLE-RUBRIC.md`. Fixtures and their schema:
`fixtures/` and `fixtures/SCHEMA.md`.

The benchmark scores each reviewer stage against labelled excerpts
from this tree: **positives** a reviewer must flag, **controls** it must not,
and **judgment** items scored neither way. It is a measurement, not a gate: it
calls external models, exits 0, and must never be enrolled in `test/gates.toml`.

The Jev and cascade stages were measured and removed (Val, 2026-10-18); the code that produced `RESULTS-2026-10-17*.md` and `RESULTS-battery-2026-10-17.md` is at commit 8fbc5977f.

## Stages

| Stage | What it asks | Unit |
|---|---|---|
| `haiku` | `claude-haiku-5-5`, system prompt = the class's rubric row with its exceptions, user = excerpt + evidence; JSON `{flag, confidence, evidence_quote, reason}` | per item |
| `opus` | the same prompt on `claude-opus-5-5`: the ceiling, on a `--limit`ed sample only | per item |

Every Haiku and Opus finding goes through **verify**: its
`evidence_quote` must occur, whitespace-normalized, in the excerpt, an
evidence excerpt or an evidence ref's `fact`. An unverifiable finding is
dropped and counted.

## Evidence modes (stage 1)

`run --evidence curated|generated|none` picks the evidence blocks a judge sees.
`curated` (the default) is the fixtures' hand-written `evidence_refs`; `none`
is the excerpt alone; `generated` is what `evidence.py` finds for the item,
which is what a real pipeline would have, since nobody curates refs for a live
diff. Results are stored per mode (`haiku.json`, `haiku@generated.json`,
`haiku@none.json`) and `report --evidence none curated generated` shows them
side by side. Cache keys hash the rendered prompt, so each mode is cached
apart.

A generator reads only the item's `file`, `sha`, `excerpt` and line range,
never `anchor` (sometimes a labeller's prose) or anything a labeller wrote,
and works with `git show`/`git grep` at the item's sha. It returns at most 3
refs of at most 40 lines and 6,000 characters in all. What a search found,
absence included, is the ref's `fact`.

| class | what it attaches |
|---|---|
| `dead.code` | per declared name, reference counts outside its definition (this file / other non-test files / tests and scripts, counted apart, not filtered: a helper only a test reaches is still live for it) and the sites; imported names on the excerpt's lines unused in the file; parameters and `let`s never used, or only passed back into the recursion; short definitions an `if`/`match` condition depends on; the rest of a truncated declaration |
| `dup.existing` | the 3 best stdlib and `compiler/support` candidates, interface methods and externs included (`docs/stdlib/index.md` lists names only and omits interface methods, #4269, so the sources are read): a catalogue of Prelude-style recursion shapes, IDF-weighted body-shape shingles, a one-way signature matcher, name and doc-comment words |
| `dup.in-diff` | the most similar declarations in the same file (raw-token and identifier-normalized shingles, IDF-weighted), plus one cross-file candidate when it scores high |
| `dup.cross-file` | candidates from greps at the sha (same name, verbatim and identifier-generalized distinctive lines, declaration names sharing a long name word), ranked by the same similarity |
| `comment.stale` | each path, identifier, `module.name`, environment variable, flag and issue number the comment names, with whether it exists or where it is defined (absences listed first; issue state is not checked); the use sites of the declaration under the comment; current definitions and production reads |
| `magic-literal` | named constants in the file or stdlib whose value equals a numeric literal in the excerpt |

No generator for the other classes with non-local positives (one to five
each: `naming.misleading`, `diag.quality`, `defensive.silent-default`,
`data.*`, `test.*`, `iface.underused`, `suppress.invalid-reason`): the counts
are too small to measure a generator against, and the evidence each needs
(call sites of a diagnostic, the type a name claims) is class-specific.

`bench.py evidence --split dev [--misses]` measures generator recall without a
model: of the curated refs on positives, how many a generated ref covers (same
file and declaration or overlapping lines; a fact-only curated ref is covered
by a generated fact naming the same thing). `bench.py evidence --show RB-0071`
prints one item's generated refs.

Claude runs as headless Claude Code (`claude -p --tools ""`) from an empty
directory under `.cache/cwd/`, so no `CLAUDE.md`, memory or MCP config enters
the prompt. Claude Code's prompt cache is off by default (`--prompt-cache` turns
it on): every prompt is unique, so the cache write is pure surcharge.

## Running it

```sh
B="python3 -I scripts/review_bench/bench.py"
$B questions --check                          # every rubric class has a question
$B questions --class comment.history          # print one class's prompt
$B run --stage haiku --split test --dry-run --show 1   # counts, token estimate, one prompt

$B run --stage haiku   --split test --shots 2
$B run --stage opus    --split test --shots 2 --limit 40
$B run --stage haiku   --split dev --shots 2 --evidence generated --classes 'dup.*' dead.code comment.stale
$B evidence --split dev --misses              # generator recall against curated refs, no model
$B verify                                     # re-check stored quotes (run also does it)
$B report --split test --out /tmp/review-bench.md
```

Shared flags: `--fixtures <jsonl or dir>...`, `--classes <name or glob>...`
(`comment.*`), `--jobs N` (default 4; the box is shared), `--limit N` (a
stratified sample: classes in a fixed hash order, positive and control side by
side). `run` skips judgment items and classes not in the rubric, and says how
many.

## Reviewing a live diff

`review.py` runs the measured arm, battery then per-class confirm with
generated evidence, over a real diff. The skill is
`.claude/skills/review-diff/SKILL.md`.

```sh
R="python3 -I scripts/review_bench/review.py"
$R --dry-run                    # units, token and cost estimate
$R --rev A..B [--json] [--max-usd 1.00] [--jobs 4]
```

- **Scope:** `.mdk` files the diff adds or changes, at B, committed code only.
  Deleted files, `compiler/seed/`, `test/snapshots/`, goldens and any file in a
  `*fixture*` or `must_fail` directory are skipped and listed.
- **Units:** each touched top-level declaration with its leading comments
  (evidence.py's `parse_decls`). An import run is one unit. Adjacent touched
  declarations share a unit up to 40 lines, the fixtures' excerpt size, unless
  `--one-decl` is given. A span over 80 lines becomes windows of the changed
  runs with 8 lines of context each side. A changed blank line is no change.
- **Prompts:** built by `battery.battery_request` and `bench.claude_request`
  (2 dev shots), the measured functions. The battery runs with Claude Code's
  prompt cache, as the measured `battery-pc` arm did.
- **Diff scope:** a battery class goes to confirm only if one of its verified
  battery findings (read back from the cached answer, since `run_battery`
  keeps one per class) quotes a changed line, or quotes only evidence blocks.
  A confirmed finding is reported at the first changed line its confirm or
  battery quote overlaps; one argued only from evidence blocks is marked and
  placed at the unit's first changed line. On `e5a3d0380` this halved the
  confirm spend and dropped no finding judged real.
- **Budget:** `--max-usd` is checked before each batch of `2 * --jobs` units,
  so a run can pass it by one batch.
- **Output:** findings ranked by battery times confirm confidence (the rubric
  carries no per-class severity), the units, what was skipped, the spend.

## Cache and results

Every answer is cached under `.cache/claude/` by a hash of model,
prompt and item content, so a rerun is free and an edit re-asks only what it
changed. Editing the rubric row, the notes, or `rubric.py` changes the hash and
re-asks that class; so does a change of few-shot examples. Each entry records
what it cost, so reported costs include cached answers. Results per stage are
`.cache/results/<stage>.json`, keyed by fixture id; `report` reads them. The
whole `.cache/` is regenerable and ignores itself (a `*` `.gitignore` written
when it is created).

## Cost

Measured on 10-item smoke runs (2026-10-17, draft fixtures, `--shots 2`):

| Stage | Per item | Source of the figure |
|---|---|---|
| `haiku` | about $0.001 | `total_cost_usd` |
| `opus` | about $0.033 | `total_cost_usd` |

A few hundred fixtures cost well under a dollar at the Haiku stage and about
$1.30 for a 40-item Opus ceiling.

## The dev/test discipline

- Splits are by source (sprint or mined file), recorded in each fixture's
  `split`. Few-shot examples come only from `dev`, never from the scored item's
  own source.
- Rewording a prompt against the test items it got wrong turns the test split
  into training data. Change prompts from the rule, re-measure on `dev`, and
  look at `test` once.
- Nothing a labeller wrote (summary, notes, ruling, status) reaches a prompt,
  except a dev item's summary as the "why" of a few-shot example.

## Adding a class

1. Add the row to `docs/design/STYLE-RUBRIC.md`: positive, exceptions, ruling.
   The rule text is parsed from there at run time.
2. Add one entry to `SUBJECTS` in `rubric.py`: the subject phrase (written
   from the rule, never from fixture items), the extra notes it needs
   (`comments`, `monads`, `tests`, `stdlib_doc`), and whether it needs
   reasoning across two snippets.
3. `bench.py questions --check` must report no class without an entry.
4. Add fixtures to both splits.

## Files

- `bench.py`: the CLI, verification and the report.
- `rubric.py`: rubric parsing, per-class subjects and notes, Haiku/Opus
  system prompts.
- `items.py`: fixture loading, selection, evidence modes, prompt rendering,
  few-shot draw.
- `evidence.py`: stage-1 evidence generators; cached under `.cache/evidence/`
  by a hash of its own source and the item's code fields.
- `engines.py`: the headless-Claude caller and the cache.
- `battery.py`: the hunk-level measurement, every class asked of every
  excerpt: a whole-rubric Haiku call, per-class Haiku on every class, and an
  Opus audit of unlabelled flags. Its docstring lists the arms;
  `RESULTS-battery-2026-10-17.md` is its first run.
- `review.py`: the battery-then-confirm reviewer over a live diff (see
  "Reviewing a live diff").
- `RESULTS-*.md`: frozen measurements, one per pass; rerun rather than quote.
