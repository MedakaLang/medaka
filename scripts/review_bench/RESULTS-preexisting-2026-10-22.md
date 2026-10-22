# Pre-existing comment drop, dev split: 2026-10-22

`review.py` now drops a `comment.*` finding (bar `comment.stale`) whose quote is
text the base already held in a file the diff changed, deleted or renamed away
from (`review.BaseText`; README.md, "Reviewing a live diff"). This is the
dev-split measurement of that filter as the `preexisting` arm of `diffbench.py`,
against the `baseline` arm's cached answers. It asked nothing new. These numbers
describe these prompts, labels and samples; rerun them rather than quote them.

## Why

The filter answers a live-review failure, not a benchmark one. The end-of-sprint
style pass over one arch Phase 2 sprint (the one that moved declarations from
`typecheck.mdk` into `tc_types.mdk`; its ledger survives in the orchestrator's
scratchpad, its exact range does not) dismissed **197 of 214** review-diff
findings by hand as "pure move from typecheck.mdk (text present at merge
base)"; sprint 6e kept 9 and dismissed 96.
A moved or re-indented declaration is reviewed in full, and every old comment in
it sits on a changed line, so the scope filter lets it through. The move skip
(`moved-unchanged`) does not fire, because the declaration gained a parameter.

## Setup

- **Code:** branch `review-diff-preexisting-stream`; `review.py`'s
  `review_units` with `preexisting=BaseText(...)`, `diffbench.py`'s
  `preexisting` arm, `--units-of baseline`.
- **Prompts pinned to the baseline's commit.** The rubric (R50, R51 rows),
  the fixtures and `evidence.py` changed after the baseline ran at `1788fceab`,
  and each of those changes a cache key, so a run at HEAD found 0 of 592 units
  comparable. A scratch driver re-pointed `rubric.load_rubric`,
  `items.DEFAULT_FIXTURES` and `evidence._SRC_HASH` at `1788fceab`'s versions
  before calling `diffbench.main()`, with `REVIEW_BENCH_CACHE` set to a copy of
  the baseline's cache. With that, 581 of 592 units were comparable (the 11 left
  out are the evidence hash-order units the dev file already lists) and no
  battery or confirm call was new: **new spend $0.00**.
- **Scope:** the filter is code over cached answers. It cannot change which
  classes the battery flags; it can only remove findings.

## Labelled items (581 units)

| arm | recall | FPR | recall, no anchor | FPR, no anchor |
|---|---:|---:|---:|---:|
| baseline | 0.61 (68/112) | 0.19 (11/59) | 0.54 (61/112) | 0.15 (9/59) |
| preexisting | 0.61 (68/112) | 0.19 (11/59) | 0.54 (61/112) | 0.15 (9/59) |

Identical. No labelled positive and no control is a comment the base already
held in a touched file.

## What it dropped

`preexisting` against `baseline`: **23 findings dropped (unlabelled 23), 0 new.**
The run's `preexisting` list holds 42 entries: 38 caught at the battery stage
and 4 at the confirm stage. 23 of the 42 were findings the baseline reported;
the other 19 were battery flags the baseline's confirm stage had not turned
into findings, now not sent to confirm at all. By class: `comment.history` 17,
`comment.provenance` 15, `comment.shout` 5, `comment.ephemeral` 3,
`comment.speculative` 1, `comment.restates` 1.

Read by eye, every dropped quote is a history, provenance or shout line of code
the commit edited around (`typecheck.mdk` driver comments, `trmc_analysis.mdk`
phase notes, `test_cmd.mdk` relocation notes). None is a comment the commit
wrote.

Unlabelled findings fall from 818 to 795 over the 581 units: a 3% cut on
ordinary commits, where moves are rare. The benchmark holds no sweep commit, so
the sweep case, where the hand ledger dismissed 92% of findings, is measured
live below, not here.

## Live sweep runs

The benchmark has no sweep commit, so the filter was run live, at HEAD's prompts,
over two arch Phase 2 stage-6 sprint ranges. These are single runs with no
labels; the reader's check is the two lists in each run's JSON.

**Sprint 4, `31f730fa4..720dfa654`** (the `ModuleCtx` cell table; 5 files, 139
units, $0.51, 18 min of funnel after 9 min of unit cutting):

| | count |
|---|---:|
| findings reported | 29 |
| of which `comment.*` | 10 |
| dropped as pre-existing | 31 |

The 31 dropped are all provenance, history, shout and measurement lines of
`typecheck.mdk` and `tc_types.mdk` declarations the sweep re-wrapped (`#156 S3a`,
`#1375 item 2`, `RULED 2026-08-10`, `stored at IR line 1693`). The 10 comment
findings kept name the sprint's own work (`freshModuleCtx` no longer re-seeds,
`#2547 unit 3`, the G1 sticky mirror), so they are the diff's to answer. The
other 19 findings are 12 `dup.in-diff`, 2 `dup.existing`, 2
`idiom.let-underscore-unit` (the pattern #4349 files), 1 `dead.code`, 1
`shape.do-cascade` and 1 `test.gap`.

**Stage-6 range `8c292fa33..40df5a2a4`** (the orchestrator's other dry run; 235
units, $0.91, 33 min of funnel after 15 min of unit cutting):

| | count |
|---|---:|
| findings reported | 143 |
| of which `comment.*` | 5 |
| dropped as pre-existing | 10 |

139 of the 143 findings are in `typecheck.mdk`: `dup.in-diff` 40, `dead.code`
15, `data.bool-blind` 15, `idiom.let-underscore-unit` 14,
`shape.threaded-invariants` 14, `test.gap` 11, `dup.existing` 9,
`data.param-clump` 8, the rest smaller. Only 15 comment-class findings reached
the diff-scope filter at all, and the drop took 10 of them. The 5 kept are
`#866`, `#411` and `P0-19 d4b` provenance tags on lines whose code the sweep
also changed, so the quote is not base text: a reader's call, and the kind of
line a hand ledger dismisses in seconds.

This is not a re-score of the 197-of-214 ledger: that run's prompts (rubric
before R50 and R51, earlier fixtures) are gone, and at today's prompts the same
kind of range draws few comment findings in the first place. What the two live
runs show is the filter's behaviour on sweep diffs: it drops only `comment.*`
quotes the base held, it leaves comments that name the sprint's own work, and
on a range where the battery does raise old comments (sprint 4) it removes
three of every four.

**Time.** Both runs passed Val's 20-minute budget for the pass: 27 and 48
minutes of wall at `--jobs 4` on the shared box, of which unit cutting (evidence
generation, git-bound) was 9 and 15 minutes. Streaming makes the time visible;
it does not shorten it. The leads left are the evidence generators (about 4 s
of CPU per unit) and the battery-then-confirm barrier per batch of 8 units.

## Cost and time

- Dev arm: $0.00 new; about 20 minutes of wall for unit cutting over 592 units
  from the evidence cache, 17 seconds for the funnel from the answer cache.
- The pin driver and cache copy are scratch files, not tools: a future
  re-measurement after a rubric change needs either a fresh baseline run (about
  $3.40 on dev) or the same pin.
