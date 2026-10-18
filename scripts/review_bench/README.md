# scripts/review_bench — measuring a cheap cascaded style reviewer

**Status:** harness, 2026-10-17. Design: `docs/design/REVIEW-WORKFLOW-DESIGN.md`.
Rules and classes: `docs/design/STYLE-RUBRIC.md`. Fixtures and their schema:
`fixtures/` and `fixtures/SCHEMA.md`.

The benchmark scores each stage of the review funnel against labelled excerpts
from this tree: **positives** a reviewer must flag, **controls** it must not,
and **judgment** items scored neither way. It is a measurement, not a gate: it
calls external models, exits 0, and must never be enrolled in `test/gates.toml`.

## Stages

| Stage | What it asks | Unit |
|---|---|---|
| `jev` | One yes/no Choice per class (`flag` / `leave`), asked in both option orders inside one request, P(flag) averaged | per item |
| `haiku` | `claude-haiku-5-5`, system prompt = the class's rubric row with its exceptions, user = excerpt + evidence; JSON `{flag, confidence, evidence_quote, reason}` | per item |
| `opus` | the same prompt on `claude-opus-5-5`: the ceiling, on a `--limit`ed sample only | per item |
| `cascade` | Jev bands per class: below `low` dismissed, at or above `high` reported, the middle band to Haiku | per item |

Every Haiku, Opus and cascade finding goes through **verify**: its
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
$B questions --class comment.history          # print one class's Jev question and prompt
$B run --stage haiku --split test --dry-run --show 1   # counts, token estimate, one prompt

$B cascade                                    # Jev over dev, fits thresholds.json
$B run --stage jev     --split test
$B run --stage haiku   --split test --shots 2
$B run --stage cascade --split test --shots 2
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

The SDK lives in the user site, which `-I` hides; `engines.py` adds it back.
The Jev key is `TYPESAFE_API_KEY` or `~/.config/typesafe/api_key`
(`scripts/jev/README.md`).

## Cache and results

Every answer is cached under `.cache/jev/` or `.cache/claude/` by a hash of model,
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
| `jev` | about $0.00005 (about 1,200 input tokens) | reported tokens at $0.042/Mtok input; output is free |
| `haiku` | about $0.001 | `total_cost_usd` |
| `opus` | about $0.033 | `total_cost_usd` |
| `cascade` | about $0.0007 | Jev plus Haiku on the middle band |

A few hundred fixtures cost cents at the Jev stage, well under a dollar at the
Haiku stage, and about $1.30 for a 40-item Opus ceiling. If the SDK reports no
token count, the Jev cost is estimated from characters and the report says so.

## The dev/test discipline

- Splits are by source (sprint or mined file), recorded in each fixture's
  `split`. Few-shot examples come only from `dev`, never from the scored item's
  own source.
- Thresholds are fit on `dev` by `bench.py cascade` and reported on `test`.
  `thresholds.json` is committed beside the code; never edit it by hand and
  never refit on `test`.
- Rewording a question or a prompt against the test items it got wrong turns
  the test split into training data (`docs/design/JEV-LEDGER.md`, section 5).
  Change questions from the rule, re-measure on `dev`, and look at `test` once.
- Nothing a labeller wrote (summary, notes, ruling, status) reaches a prompt,
  except a dev item's summary as the "why" of a few-shot example.

## Adding a class

1. Add the row to `docs/design/STYLE-RUBRIC.md`: positive, exceptions, ruling.
   The rule text is parsed from there at run time.
2. Add one entry to `SUBJECTS` in `rubric.py`: the subject phrase of the yes/no
   question (written from the rule, never from fixture items), the extra notes
   it needs (`comments`, `monads`, `tests`, `stdlib_doc`), and whether it needs
   reasoning across two snippets (those always go to Haiku in the cascade).
3. `bench.py questions --check` must report no class without a question.
4. Add fixtures to both splits, then refit with `bench.py cascade`.

## Files

- `bench.py`: the CLI, verification, threshold fitting and the report.
- `rubric.py`: rubric parsing, per-class subjects and notes, Jev questions,
  Haiku/Opus system prompts.
- `items.py`: fixture loading, selection, evidence modes, prompt rendering,
  few-shot draw.
- `evidence.py`: stage-1 evidence generators; cached under `.cache/evidence/`
  by a hash of its own source and the item's code fields.
- `engines.py`: the Jev and headless-Claude callers and the cache.
- `thresholds.json`: per-class Jev bands written by `bench.py cascade`.
- `RESULTS-*.md`: frozen measurements, one per pass; rerun rather than quote.
