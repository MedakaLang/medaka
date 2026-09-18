---
name: jev-judgments
description: Design, measure, and iterate a set of Jev (TypeSafe) questions over Medaka candidates — enumerate in code, sample, hand-label, ask, read AUC and calibration, revise the question or the state, ship with numbers. Use when asked to test Jev against a class of fix candidates, to add or change a question in scripts/jev, to build any new Jev-backed tool from the roadmap in docs/design/JEV-DESIGN.md, or when a Jev ranking looks wrong and you need to know whether the question, the state, or the labels are at fault.
---

# Jev judgments — measure before you trust

Jev returns typed answers with calibrated probabilities (Choice / Score /
Noul) and never text. That makes it cheap and fast, and it makes every
answer a number you must read against labels before acting on it. This
skill is the loop that produced the numbers in `docs/design/JEV-DESIGN.md`;
the tool is `scripts/jev/` and its usage is in `scripts/jev/README.md`.

**Before proposing a change to a question, read `docs/design/JEV-LEDGER.md`** —
the index of what has been tried, with each refuted attempt and its frozen
evidence. Paragraph chunking, a 2-way `recommend`, a four-level `register`
rewrite and a `defensive` arm are all measured and rejected; re-proposing one
spends a round of API calls to re-learn what the ledger already says.

**Four rules that are not negotiable** (epic #3117):

1. **Code finds, Jev judges, the agent rewrites.** Jev never generates the
   fix. A result is a site, a class, and a probability.
2. **Never a gate.** External API, probabilistic answers. Census or
   review-seam input only. Exit 0. Not in `test/gates.toml`.
3. **Language facts go in the state.** Jev reads Medaka's shape unaided, but
   without the language notes every Score inflated by a level and verbatim
   chain false positives went from 6 to 36. Supply the spec excerpt and an
   in-tree exemplar for any question over Medaka source.
4. **A question ships only with a number.** Every shipped question has rows
   in `scripts/jev/eval_corpus.json` and its operating point recorded in the
   design doc.

## The loop

### 1. Enumerate candidates in code, loosely

Write the enumerator for recall, not precision. The judgment is the model's
job; a mechanical filter that is too tight hides the very sites you wanted
judged. The do-syntax enumerator accepts any declaration with two nested
matches on Result or Option arms; the linter's own rule for the shape needs
four guards and finds nothing left in the tree.

Chunk to the unit the question is about. A comment block with the code
directly below it; a whole top-level declaration; never a whole file
(`compiler/types/typecheck.mdk` is 47k lines). Cap the unit and count what
you skipped, so the report says so.

### 2. Sample with a fixed seed, stratified

Draw a labeled sample of 50 to 100 per question family. Stratify so both
sides of every judgment are present: regex-census hits and non-hits, shallow
and deep nesting, short and long blocks. Oversample the rare stratum you
care about. Record the seed. The `sample.py` step in the original experiment
is the shape; `scripts/jev/eval_corpus.json` is the result.

### 3. Write the label rule down, then label by reading everything

Before labeling, write one sentence per label saying what counts. "Uniform
chain: two or more successive matches over one monad whose failure arms share
one shape and whose success payload feeds the next step." Then read every
sampled item in full and label it against that sentence. Add a `note` where
you hesitated: those are the items a second reader should check first, and
they are the items whose disagreements later will tell you whether the
question or the rule is wrong.

Your labels are one reader's judgment standing in for the expensive LLM
pass. Say so in the corpus header. Do not present agreement with them as
truth.

### 4. Write the questions

One judgment per question. Put the policy or the language facts in the state
and point at them with a backticked field name in the instructions. Give
criteria that describe concrete situations, not adjectives. The details are
in "Iterating" below; write the first draft, then measure.

### 5. Ask, batched and cached

All questions about one candidate go in one request: TypeSafe measured 12x
cheaper and 10x faster than one question per request, with identical
answers. Reuse the ask-all and cache-key functions in
`scripts/jev/jev_census.py`: they batch, bound concurrency to eight, retry
on rate limits, and cache every answer under `.jev-cache/` by a hash of the
model, the state, and the question text. A rerun after an edit costs only
what changed.

### 6. Measure

`scripts/jev/jev_eval.py` prints what you need; reuse its functions for a new
family rather than reimplementing them. Read in this order:

- **AUC** answers "does the ranking work at all". Below 0.85, fix the
  question or the state before anything else.
- **Calibration by bucket** answers "which threshold". The 0.6 to 0.8 bucket
  is where Jev over-predicts on this corpus; every shipped operating point
  came out between 0.55 and 0.80, never 0.5.
- **Precision and recall at that threshold** are what the roadmap consumer
  will experience.
- **The mechanical baseline on the same sample.** A Jev question earns its
  place by beating the regex or the lint rule it sits beside, not by looking
  good alone. History detection was worth shipping because it went from the
  regex census's precision 0.81 and recall 0.72 to 0.96 and 0.91.
- **For a Choice**, accuracy at confidence tiers and the confusion matrix.
  A three-way choice that is 0.65 accurate overall and 0.88 at confidence
  0.7 is usable with a tier; one whose confusion is all in one adjacent pair
  is a policy question in disguise.
- **For a Score**, rank correlation and the mean predicted score per label
  level. If the means are not monotone the levels are not ordered in the
  model's reading; rewrite them.

### 7. Read the disagreements, then decide who is wrong

List the largest disagreements per question. Each one is one of three
things, and the fix differs:

- **The label is wrong or the rule is fuzzy.** Fix the corpus, not the
  question. Add a `note`.
- **The state lacks the evidence.** The comment-versus-code mismatch
  question failed because a code fragment below a comment cannot show what
  the comment describes elsewhere; the fix is pairing claims with evidence
  in code, not rewording. If the model says yes to nearly everything, look
  here first.
- **The question is ambiguous or merges two judgments.** Split it. The
  reviewer-addressed question conflates a comment narrating its own drafts
  with a comment arguing against an objection, and its disagreements
  cluster by that split.

A disagreement at low confidence on a site the labels decided by rule of
thumb is a policy line, not a model error. Decide the policy once, write it
into the criteria, relabel.

### 8. Ship with the numbers

Add the sampled items to the corpus with their text inline, so the corpus
survives tree drift. Record the operating point in the design doc's table.
State the label provenance. If a later drain finds a wrong recommendation,
add that site to the corpus with a note, so the question is re-measured
against the case that fooled it.

## Iterating on question and state content

What moved the numbers in the first experiment, and what did not.

**State**

- **Name the fields and point at them.** State is a JSON object with a
  `policy`, a `comment`, a `code_after`; the instructions say "given
  `policy`, does `comment` ...". A bare string state loses the distinction
  between the evidence and the rule.
- **Supply the fact the judgment depends on.** The register policy sentence
  sits in the state, not in the instructions, so every comment question
  reads the same rule. The do-syntax notes carry the desugaring, the
  uniform-handler equivalence, and the `typecheckGate` exemplar from
  `compiler/driver/medaka_cli.mdk`. Stripping them is the control run, and
  it is what showed the scale depends on them.
- **Give the smallest unit that decides the question, and all of it.** A
  declaration for a rewrite question. A comment plus the code directly below
  it for a register question. Not a file, and not a fragment when the claim
  reaches past the fragment.
- **Keep the state the same across the questions in one request.** They
  cannot see each other's answers, and a state tuned for one question
  starves another. If two questions need different evidence, that is two
  requests.

**Questions**

- **One judgment each.** "Is this a chain AND would a rewrite change
  meaning" is two questions with two failure modes. Ask both; combine in
  code.
- **Criteria describe situations.** "A substantial part of the comment is
  about the past: a former shape, a date, a sequence of changes, or who
  decided what" beats "the comment is historical". For a Score, every level
  must describe a concrete state a reader could point to, and the levels
  must be ordered in the model's reading (check the per-level means).
- **Use the repo's own phrasing, verbatim.** Adding "this slice", "earlier
  cut", "measured on this diff", "see the report's Notes" to the reviewer
  criteria took its AUC from 0.86 to 0.91 with no other change. The model
  does not know this repo's vocabulary until the criteria teach it.
- **Give a way out.** A Choice needs the option you will act on when nothing
  fits (`leave`, `none`); a Noul needs a `false` criterion that names the
  benign case ("a bare issue number as a pointer does not count").
- **Make the options the actions.** Convert / partial / leave are what a
  maintainer can do. The ranking key is then a sum of the actionable
  probabilities, and thresholding that binary was more useful than the
  three-way accuracy.
- **Drop a question whose label base rate is near 0 or 1.** "Would a naive
  rewrite change behavior" was true on 59 of 60 sites; it carries no
  information once the chain question is asked. The verbatim-chain question
  had one positive because the lint rule already drained the shape.
- **Do not tune the criteria against the labeled sample.** The sample is
  the test; write criteria from the rule you wrote in step 3, not from the
  items. If you must use examples in the criteria, take them from outside
  the sample.
- **Ask speculative questions in the same request when they are free.** A
  question you might not use costs tokens, not a round trip. Ask the
  Choice and the Score together and pick the ranking key after measuring.

**Reading answers**

- **Confidence is distribution shape, not correctness.** A Choice at 0.9
  confidence can be wrong; a Noul near 0.5 means "as likely as not", not
  "medium". Route on it, never act on it alone for anything irreversible.
- **Thresholds come from the calibration table, per question.** Never carry
  one threshold across questions.
- **Precision at the operating point, not overall.** A whole-tree run that
  says 648 reviewer-addressed blocks at 0.5 means about half of them, at that
  question's measured precision. Sort by the better-calibrated key.

## Reusable pieces

- `scripts/jev/jev_census.py`: the question dicts, the state builders, the
  enumerators, batched cached asking, the ranked report, diff scoping.
- `scripts/jev/jev_eval.py`: precision/recall/AUC, calibration buckets,
  Spearman for Scores, confidence-tier accuracy and confusion for Choices,
  the regex-baseline comparison, the disagreement list, the control flag.
- `scripts/jev/eval_corpus.json`: the corpus format, one item per object
  with text inline, `labels`, optional `note`, and `origin` as provenance.
- Live TypeSafe docs: <https://docs.typesafe.ai/llms.txt>; the cookbooks
  most often the right starting shape are line-by-line search (rank many
  ids in one Choice), citation check (one Choice per claim against its
  evidence), and entity alignment (a Score whose levels are the actions).

## Do not

- Ship a question without a corpus row and a number.
- Enrol any Jev script as a gate, or add a `.sh` for it anywhere in the tree
  (a tracked `.sh` is a gate candidate; keep Jev tooling in Python until
  the native client, #3132).
- Ask Jev to generate, explain, or reason. A question that needs semantics
  over an execution ("did this golden change because the code got better")
  goes to a reviewer.
- Turn a Jev score into an idiom quota. The `style-review` DECLINED register
  stands.
- Put the API key in a transcript, a command line, or a commit. It lives in
  `TYPESAFE_API_KEY` or `~/.config/typesafe/api_key`, created from a
  terminal.
