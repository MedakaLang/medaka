# Jev: the experiment ledger

What has been tried, what is still being iterated on, and what is settled and
must not be relitigated. Epic #3117; the design and the measurement writeups
are `docs/design/JEV-DESIGN.md`; the loop is the `jev-judgments` skill.

This file is the **index of attempts**. It is deliberately short: each row is a
verdict and a date, with the detail one link away. Its job is to stop a later
session from re-proposing something that was already measured and rejected.

## 0. The one rule that keeps this file true

**Record verdicts and dates. Never transcribe a live number.**

A *refuted* experiment's number is frozen -- the run will not happen again, so
writing it down is what keeps the verdict from being reopened, and it cannot
rot. A *shipped* question's number is live: `cache_key` in
`scripts/jev/jev_census.py` hashes the model, the state, and the **whole
question dict**, and the policy sentence lives in the state that every comment
question reads. Editing the policy, or editing a sibling question's criteria,
silently re-asks all four questions and moves every recorded figure. So a
shipped number is a command, not a table:

```
python3 scripts/jev/jev_eval.py --kind comments
python3 scripts/jev/jev_eval.py --kind do
```

That distinction is why the design doc stopped recording per-level means as
durable facts on 2026-09-17, after they moved twice in one day.

## 1. Accepted, not iterating

Settled. Reopen only with a measurement, and say in the PR body which row you
are reopening.

| What | Settled | Verdict |
|---|---|---|
| The four principles: code finds / Jev judges / agent rewrites; never a gate; language facts in the state; a question ships only with a number | 2026-09-16 | `docs/design/JEV-DESIGN.md` section 3. Principle 2 is absolute: no Jev script is ever in `test/gates.toml`, and every one exits 0. |
| Language notes in the state | 2026-09-16 | Required, measured by the control run. Removing them held the ranking (AUC 0.98) but broke the scale: every readability score inflated about one level, verbatim-chain false positives went 6 to 36, recommendation accuracy 0.65 to 0.57. Not re-run since; these are that run's figures. |
| One request per candidate, all questions batched | 2026-09-16 | 12x cheaper and 10x faster than one question per request, with identical answers. |
| `history`, `offsite`, `register` (comments); `uniform_chain`, `readability_gain`, `recommend` (declarations) | 2026-09-16 | Shipped with operating points; `docs/design/JEV-DESIGN.md` section 4.1. |
| `ephemeral` replaces `reviewer` | 2026-09-17 | Shipped. The rule is **locatability, not tense**: a comment is a defect when it anchors to a change the reader cannot identify. First comment question besides `history` and `offsite` to beat its mechanical baseline. |
| Defensive prose is the register Medaka wants | 2026-09-17, Val | Not a defect. Prose that argues against a wrong reading, or defends a choice, is stating a constraint the code cannot show. The policy sentence in the state says so explicitly. |
| The native Medaka client | 2026-09-17, Val | **Parked, not declined** (#3132). The transport was never the cost; Medaka has no TLS anywhere. It unparks only if TLS is prioritized on its own merits, and nothing in this work is a reason to build TLS. |
| The corpus is one reader's judgment, and says so | 2026-09-16 | Agreement with these labels is not truth. #3124 adds a second reader. |

## 2. Live -- still being iterated on

| What | State | Next move |
|---|---|---|
| `ephemeral` recall on long blocks | **The largest known gap in a shipped question.** Recall falls from 0.86 at 20 lines or fewer to 0.50 above it; precision holds. | Needs a mechanism other than paragraph chunking, which is refuted (section 3). Unproposed. |
| Comment-versus-code mismatch, as claim pairing (#3121) | Filed, not built. The first framing is refuted (section 3). | Code pairs each backticked identifier and each checkable claim with the declaration; Jev judges the pair, not the fragment. |
| Doc-comment register for `stdlib/*.mdk` | Not filed. | Needs a sample first: the stdlib editorial pass left the corpus clean enough that the question may have no customer. Rules are in `stdlib/README.md`. |
| Suppression rationale quality | Not filed. | `rule-directive-reason` checks a `lint-disable` carries a reason; whether the reason is a reason is a judgment. |
| The J-REVIEW tools (#3122, #3125 through #3131) | Filed as children of #3117, none built. | `docs/design/JEV-DESIGN.md` section 5 ranks them; each issue carries its own acceptance and measurement plan. |
| The cheap-hand proposals | **Awaiting Val.** Five proposals from the 2026-09-17 measurement, offered for decision and not adopted. | `docs/design/JEV-DESIGN.md` section 8.6. |

## 3. Tried and refuted -- do not relitigate

Every row here was measured. The figures are frozen: the run that produced
them is over, and they are the evidence, not a status.

| Attempt | Measured | Verdict |
|---|---|---|
| `mismatch`: "does the code below lack what the comment describes" | 2026-09-16 | **Wrong evidence, not wrong wording.** Yes on 81 of 100. A code fragment below a comment cannot show what the comment describes elsewhere. Reframed as claim pairing, #3121. |
| `verbatim_chain` | 2026-09-16 | Retired. The lint rule owns the shape and the tree is clean of it -- one positive in the sample. |
| `meaning_change`: "would a naive `do` rewrite change behavior" | 2026-09-16 | Retired. True on 59 of 60, so it carries no information once `uniform_chain` is asked. A label base rate near 0 or 1 is a question with nothing to say. |
| `defensive` as a shipped arm of the old `reviewer` question | 2026-09-17 | **Dropped, not split.** AUC 0.496 -- a coin flip -- against the corrected label, and it fires on 76% of the tree. #3123 asked for a split into narrates-own-draft and argues-against-objection; the measurement says one arm is not a defect at all, so only `ephemeral` ships. |
| The `register` top-level collapse is caused by the policy's reviewer-prose clause | 2026-09-17 | **Refuted.** Both policies over the same 101 rows: every level fell about 0.2 and the smallest step moved 0.11 to 0.16. The collapse survives the policy edit. |
| ... is caused by long blocks diluting "entirely" | 2026-09-17 | **Refuted and inverted.** The shortfall at labels 2 and 3 is *larger* on short blocks, 0.76 against 0.49; Spearman(length, shortfall) is -0.19. |
| ... is fixed by rewriting all four `register` levels | 2026-09-17 | **Not supported.** The rewrite was frozen before the held-out labels existed and scored 0.753 / 0.37; striking the single word `argument` scored 0.765 / 0.37. Shipped the word, dropped the rewrite: a rewrite that buys nothing still costs every recorded number its comparability. |
| Retire the 3-way `recommend` for a direct 2-way Choice | 2026-09-17 | **Refuted.** Against the same binary label: collapsed 3-way 0.973, 2-way Choice 0.950, no question at all (chain times gain) 0.939. Giving the model somewhere to put a partial answer and collapsing afterwards beats forcing the binary up front. The question stays; only the claim about its 3-way accuracy was retired. |
| Chunk long comment blocks by paragraph | 2026-09-17 | **Refuted.** Max over paragraphs, which is how a chunked census reports at block level, gets 0.948 against the whole block's 0.974 -- and 0.926 against 0.961 on exactly the long blocks it targeted, at 2.6x the requests. |

What the `register` refutations leave standing: the collapse is **range use**,
not compression. Level 3 takes 2% of the probability mass on average, never
more than 32% on any row, and the highest score the Score has ever returned is
2.14 out of 3. What bounds it: the 80-row held-out draw contains **no level-3
block at all**, so the top level is rare in the tree and the collapse costs
less than the step size suggests. Threshold the Score; never read a rank
*within* the selected list as an ordering.

## 4. Declined without measurement

Not refuted -- ruled out on grounds a measurement would not change.

- **Idiom quotas** ("use `|>` here"). The `style-review` DECLINED register
  forbids density targets; a Jev Score would only make a forbidden demand
  cheaper. A candidate-and-vet shape is legitimate but has no consumer until
  `lint --fix` is safe on comment-bearing declarations.
- **"Did this golden change because the code got better?"** The highest-value
  review question, and it needs reasoning over semantics rather than a
  calibrated judgment over text. Route it to a reviewer; do not pretend a Noul
  answers it.
- **Anything as a required check.** Principle 2.
- **A `.sh` wrapper anywhere in the tree.** A tracked `.sh` is a gate
  candidate (`[WEB-SH-IS-A-GATE]`); the tooling stays Python.

## 5. Findings about the instrument itself

Not about any one question. Each of these has already cost a wrong number.

- **The cache key hashes the state and the whole question dict.** Editing the
  policy, or a *sibling* question's criteria, re-asks every question about that
  candidate and moves every recorded figure. This is section 0's rule, and it
  bit twice on 2026-09-17.
- **Two label sets on two rules must not be pooled.** `register` labels
  C000-C100 were assigned while prose arguing for a design still counted as a
  defect; F000-F079 after the ruling that it does not. They answer two
  different questions. `scripts/jev/eval_corpus.json` marks each row with
  `register_rule` and `scripts/jev/jev_eval.py` reports the populations apart.
- **Reading a score before assigning a label destroys the label.** Eight
  tuning rows at `register` level 3 cannot be re-labeled under the current
  rule, because their scores were read while diagnosing the collapse. They are
  left alone and the held-out draw carries the post-ruling evidence instead. A
  label informed by the instrument is the one thing the corpus rule forbids.
- **Do not tune criteria against the labeled sample.** The sample is the test.
  Structural changes to a question are safe; rewording it against the items it
  got wrong is not.
- **A fresh draw is the only way to keep the corpus a test.** The 2026-09-17
  round drew 80 new rows precisely because the original 101 had become both the
  training signal and the test.
