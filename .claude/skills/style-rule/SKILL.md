---
name: style-rule
description: Add or change a style rule (a rubric class, an exception, or a ruling) and measure what it does to the cheap reviewer. Load when Val makes a style call, when a review finding keeps recurring or keeps being wrong, or before editing docs/design/STYLE-RUBRIC.md or scripts/review_bench/fixtures/.
---

# Adding or changing a style rule

The rules the reviewer applies live in **`docs/design/STYLE-RUBRIC.md`**; each
row cites the rulings it rests on, recorded in **`docs/design/STYLE-RULINGS.md`**.
The benchmark that measures the reviewer is `scripts/review_bench/` (its
README; fixture fields in `fixtures/SCHEMA.md`). A rule is not done until it
has a ruling, a rubric row, fixtures, and a measurement.

## 0. Is it a rubric rule at all?

- **Syntactically detectable and seen twice** → a lint-rule issue, not a
  rubric row (the shrink rule in `.claude/skills/style-review/SKILL.md`).
- **Caused by the language or tooling** → a row in the rubric's "Language and
  tooling causes" table, plus an issue or a proposal. Stdlib additions need a
  proposal Val reviews first.
- **Already ruled** → check `STYLE-RULINGS.md` first. A settled ruling is not
  re-asked; a case it does not cover, or one that conflicts with it, is a new
  question that names the ruling it would amend.

## 1. Get the ruling

Rulings are Val's. The target style is plain, readable Haskell: typed and
idiomatic, never clever for its own sake.

- **One question per message.** Settle it before asking the next; queue the
  rest.
- **Ask on a real instance**: file, declaration and commit, shown as a
  before/after pair (the code as it is, the rewrite). Give the options,
  including "fine as it is", and your recommendation with the reason.
- **Probe every language claim before it goes in a question or a rule.**
  Haskell's withDefault and foldl do not exist here (`optionOr`, `fold`); interface
  methods such as `orElse` are missing from `docs/stdlib/index.md` (#4269), so
  read `stdlib/core.mdk`. A wrong premise in a question gets a wrong ruling.
- A threshold you choose to make a ruling checkable (three caps words, two
  call sites) is yours, not Val's: record it as an operationalization.

## 2. Record it

1. Append `### R<n>` to `docs/design/STYLE-RULINGS.md`: instance, ruling
   (quote Val), class, what it amends, anything left open.
2. Edit the rubric row: **Positive**, **Exceptions and controls**, and the
   **Ruling** column citing `R<n>`. Write it from the rule, never from fixture
   items. A new class gets a `family.name` slug in the right section.
3. A new class also needs its `SUBJECTS` entry in
   `scripts/review_bench/rubric.py` (README § "Adding a class"); then
   `python3 -I scripts/review_bench/bench.py questions --check`.
4. A skill or doc that restates the rule (`write-tests`, `style-review`'s
   DECLINED table, `stdlib/README.md`) is changed to agree, preferably to a
   pointer.

## 3. Fixtures

Every item is real code from the tree, framed as "a diff adding this code".

- **The ruled instance** is `label_strength: val`, `source.kind: val-ruling`,
  `ruling: R<n>`.
- **Mine the sprint ledgers.** Each end-of-sprint style report ends with a
  review-diff ledger (`style-review` § Scope). A dismissed finding is a
  candidate control for its class, and a kept one is a candidate positive.
- **Find more with a scan.** Targets: four or more positives, three or more
  controls when the row names an exception. Controls are the exceptions,
  after-fix states (which must be clean for the class, or the item is
  `judgment`), and clean look-alikes. Scanned items are `candidate` until a
  second reader checks them (`reviewed`).
- **Give the judge what it needs.** Add `evidence_refs` when the finding rests
  on code outside the excerpt. Use a ref's `fact` for an absence ("`x` occurs
  only in comments at this commit"): neutral and mechanically checkable, never
  the verdict.
- **Relabel what the ruling moves.** Read the existing items of the class and
  its neighbours; flip each one with a `note` that cites the ruling.
- **Tools** (`scripts/review_bench/curate.py`):
  - `add new.jsonl` allocates ids and assigns splits by source, keeping the
    same code in one split;
  - `edit edits.json` relabels;
  - `check` validates the schema, the classes, the ruling ids, byte-exact
    excerpts and split leakage;
  - `stats` regenerates `fixtures/STATS.md`.

## 4. Measure

Dev first. A rubric edit changes the battery's shared prompt for every class,
so re-measure the battery too, not just the class.

```sh
B=scripts/review_bench
python3 -I $B/bench.py run --stage haiku --split dev --shots 2 --classes <class>
python3 -I $B/battery.py battery --prompt-cache --evidence generated --split dev
python3 -I $B/battery.py report --split dev --evidence generated --arms battery-pc verify:battery-pc
python3 -I $B/curate.py contested --split dev
```

Read every contested item. Each is one of three things, with different fixes:

- **The label is wrong.** Fix the fixture, with a note.
- **The judge lacked the evidence.** Add a ref or a fact, or a generator in
  `evidence.py`. A generator reads only code fields, never a label.
- **The rule is fuzzy.** Ask Val a new question; never reword the rubric to
  fit the items it missed.

Then run the test split **once** and, if the headline moved, freeze the numbers
in a new `scripts/review_bench/RESULTS-<date>.md`. Rewording against test
items turns the test split into training data.

**Cost:**
- Per-item Haiku: about $0.001 an item.
- Battery: about $0.0027 a hunk, and about $0.0052 with confirm.
- Opus: about $0.03 a call.

Ask Val before a run over $5.

## 5. Land

The ruling, the rubric row, the fixtures, `STATS.md` and any results file go
in together, on a branch, through a PR Val reviews. Run `make docs-links` and
`make agent-doc-symbols` first. The reviewer (`review-diff` skill) reads the
rubric at run time, so a landed rule applies on its next run. Nothing here is
ever a gate.
