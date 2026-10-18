# Review workflow: a cheap reviewer and the benchmark that measures it

Status: design, measured 2026-10-17 to 2026-10-18. The rules the reviewer
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
2. **Evidence generation (free).** Code cuts the diff into hunks and attaches
   the evidence a judge needs from outside the hunk, found with `git grep` and
   `git show` at the diff's commit (`scripts/review_bench/evidence.py`): reference
   counts for each declared name, existing stdlib and `compiler/support`
   helpers with a similar shape, similar declarations in the same and other
   files, whether each identifier, path and flag a comment names exists, named
   constants equal to a literal.
3. **Haiku battery.** One `claude-haiku-5-5` call per hunk with the whole
   rubric in the system prompt, returning a list of findings, each quoting its
   evidence.
4. **Per-class confirm.** Each class the battery flagged is asked again with
   that class's own prompt (its rule and exceptions, its notes, two dev-split
   examples, its own generated evidence); a finding survives only if both flag
   it.
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
split. Rewording a prompt against the items it got wrong turns the test split
into training data.

## What was measured

On the test split with generated evidence (`scripts/review_bench/RESULTS-*.md`):

- The battery alone: recall 0.84, false-positive rate 0.13, $0.0027 per hunk;
  about half of its findings on classes a hunk was not labelled for are wrong
  by an Opus audit.
- Battery then confirm: recall 0.76, false-positive rate 0.08, $0.0052 per
  hunk; wrong findings on unlabelled classes fall from about 0.61 to 0.25 per
  hunk while 79% of the real ones are kept.
- A decision-model stage (Jev, a router or a confidence cascade in front of
  Haiku) was measured and dropped (Val, 2026-10-18): the router cost 40% of a
  battery call, dismissed no hunk at 95% recall, and as a filter after the
  battery removed nothing.
- Evidence generation lifts recall on the classes that need context outside
  the hunk from 0.38 (excerpt only) to 0.70; hand-picked evidence reaches 0.84.

## What was known going in

- Synthetic fault injection overstates real-world accuracy by a wide margin in
  published code-review evaluations, which is why every fixture is a real
  excerpt.
- Production review systems with published architectures (Anthropic's code
  review, Cursor's Bugbot, ByteDance's BitsAI-CR) converged on narrow per-rule
  finders, a verification pass, and deduplication or voting.
