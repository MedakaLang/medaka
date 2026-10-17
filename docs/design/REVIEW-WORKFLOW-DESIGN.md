# Review workflow: a cheap reviewer and the benchmark that measures it

Status: design plus benchmark scaffolding, 2026-10-17. The rules the reviewer
applies are `docs/design/STYLE-RUBRIC.md`; the fixtures and harness are
`scripts/review_bench/`.

## The problem

Agent-authored diffs carry style problems and slop that gates cannot see:
history narrated in comments, hand-rolled stdlib functions, sentinel values,
stringly-typed data, weak tests. Reviewing every diff with the strongest model
would be accurate and too expensive. The goal is satisfactory accuracy at low
cost, measured rather than asserted.

## The shape: a funnel where each stage costs more and sees less

1. **Mechanical (free).** `medaka lint`, `medaka fmt`, the comment-register
   census. The reviewer never re-reports what a gate already enforces.
2. **Candidate generation (free).** Code cuts the diff into units (each added or
   changed declaration and comment block) and attaches the evidence a judge
   needs: the definition behind each backticked identifier in a comment, existing
   helpers with a similar name or signature for a new helper, the suppression
   reason under each `lint-disable`, the declared return type of a `let _ =`
   head. A class with no candidate generator falls through to stage 3.
3. **Decision model.** One narrow yes/no question per class per candidate, all
   of a candidate's questions batched into one request. Scores below a per-class
   low threshold are dismissed; scores above a per-class high threshold are
   reported only for classes whose precision has been measured; the middle band
   moves on. Each question is asked in both option orders and averaged, because
   decision models are position-biased.
4. **Cheap generative checker (Haiku).** The middle band, plus classes that need
   reasoning across two snippets (a stale comment against the code that
   contradicts it, a duplicate against its original). One class per prompt;
   few-shot examples come from the benchmark's dev split only. Every finding must
   quote its evidence.
5. **Mechanical verifier.** The quoted lines exist; the named helper exists. A
   model re-reading its own finding does not count as verification: published
   measurements show plain LLM judges reject only a small fraction of
   plausible-but-wrong review comments unless grounded in code evidence.
6. **Escalation (budgeted).** A stronger model only for disagreements and
   high-severity classes.

Output uses the `pr-review` finding format, filtered through the DECLINED
register of `.claude/skills/style-review/SKILL.md`.

## The benchmark

Fixtures are real excerpts from this tree, pinned to a commit SHA, each labelled
with a rubric class and a polarity:

- **Positive**: a reviewer must flag it.
- **Control**: a reviewer must not flag it. Controls include the exceptions the
  rubric carves out, declined findings from past reviews, and the after-fix state
  of a fixed positive, which gives a minimal pair.
- **Judgment**: scored neither way.

Label strength, strongest first: `val` (a ruling on that exact instance), `fixed`
(a fix round changed it as asked), `declined` (ruled not a defect),
`candidate` (a miner's judgment, pending review).

Measurements:

- **Item level**: per class and per stage, recall on positives, false-positive
  rate on controls, AUC for scored stages, and cost per item.
- **Diff level** (planned): rebuild a fixture's diff from the commit that
  introduced it and run the whole funnel, matching findings by file, declaration
  and class. Whole clean diffs act as controls.
- **Ceiling**: one strong-model single pass over the same items, to show how much
  accuracy the cheap funnel gives up and at what saving.

Splits are by source (sprint or mined file), so an exemplar used in a prompt is
never scored. Thresholds are set on the dev split and reported on the test
split. Rewording a question against the items it got wrong turns the test split
into training data, which `docs/design/JEV-LEDGER.md` records as a mistake
already made once.

## What is known going in

- Jev already answers two of these classes well: the comment-register questions
  (`history`, `offsite`) and the `do`-conversion questions (`uniform_chain`,
  `recommend`), per `docs/design/JEV-LEDGER.md`.
- Synthetic fault injection overstates real-world accuracy by a wide margin in
  published code-review evaluations, which is why every fixture is a real
  excerpt.
- Production review systems with published architectures (Anthropic's code
  review, Cursor's Bugbot, ByteDance's BitsAI-CR) converged on narrow per-rule
  finders, a verification pass, and deduplication or voting.
