# Whole-rubric review per hunk, 2026-10-17: does a Jev router pay?

The per-item benchmark asks each judge only the class an item is labelled for.
A real review asks all 47 classes of every hunk, and most (hunk, class) pairs
are negatives, which is where a cheap router could pay. This run measures that.
Harness: `battery.py`; fixtures and rubric as of `RESULTS-stage1-2026-10-17.md`
plus RB-0126 relabelled. These numbers describe these prompts, these Jev states
and these labels; rerun rather than quote.

## Setup

- **Unit:** one distinct excerpt (items grouped by sha, file and lines): 224 on
  dev, 311 on test. Its labelled classes are its items' classes (147 positives,
  71 controls on dev; 214 and 93 on test). `also_present` and judgment classes
  are allowed and never scored. A flag on any other class is **unlabelled**: it
  is counted (volume, cost) and scored only through the Opus audit.
- **Evidence:** `generated` is the headline, since nobody curates refs for a
  live diff. A whole-rubric prompt gets the union of the six `evidence.py`
  generators' refs, one generator's best ref first in turn, capped at 8,000
  characters (`UNION_CAP_CHARS`; 647 tokens per excerpt on dev, 711 on test).
  A per-class prompt gets its own class's generator only, as `bench.py` does.
  `curated` (the fixtures' refs, 30 tokens per excerpt) is the ceiling and was
  run on dev only.
- **Arms.** A: one `claude-haiku-5-5` call per excerpt, the whole rubric
  (every class's rule and exceptions, every Medaka note) in the system prompt,
  returning a list of findings, each quote verified. B: one Jev request per
  excerpt asking every class's yes/no question in both option orders, then the
  existing per-class Haiku prompt (2 dev shots) on the classes with P(flag) at
  or above a global threshold fit on dev for 95% recall of labelled positives.
  B': the battery prompt restricted to the forwarded classes. C: per-class
  Haiku on all 47 classes, on a fixed-seed sample of 24 dev excerpts (15
  positives, 9 controls). Two compositions are computed from the same answers
  with no new calls: Jev as a post-filter on A's findings, and per-class Haiku
  as a verifier of A's findings.
- **What is complete where.** Per-class Haiku was asked on every labelled
  (excerpt, class) pair on dev, on every pair of the 24-excerpt sample, and on
  the forwarded labelled pairs on test. So B's and C's recall and FPR are over
  all of dev (B's over all of test), while their unlabelled-flag volume and
  cost per excerpt come from the 24-excerpt sample only.

## Dev, generated evidence (the headline)

Recall and FPR over all 224 excerpts; volume and cost where the column says.

| arm | recall | FPR | unlabelled flags / excerpt | classes asked / excerpt | $ / excerpt | Claude seconds / excerpt |
|---|---:|---:|---:|---:|---:|---:|
| A: Haiku battery | 0.83 (122/147) | 0.23 (16/71) | 1.25 | 47 | $0.0025 | 11 (one call) |
| B: Jev shared, t = 0.030, then per-class Haiku | 0.85 (125/147) | 0.08 (6/71) | 0.92 (sample) | 10.3 (sample) | $0.0107 (sample) | 36 (10 calls) |
| C: per-class Haiku, every class | 0.86 (127/147) | 0.08 (6/71) | 1.17 (sample) | 47 | $0.0376 (sample) | 117 (47 calls) |
| A, then Jev perclass as a filter | 0.82 (120/147) | 0.20 (14/71) | 0.96 | 47 | $0.0051 | 11 |
| A, then per-class Haiku verifies each finding | 0.78 (114/147) | 0.07 (5/71) | 0.42 (sample) | 2.2 (sample) | $0.0047 (sample) | 20 |

The same 24-excerpt sample, every arm complete (15 positives, 9 controls, so
each cell is a handful of items):

| arm | recall | FPR | unlabelled flags / excerpt | $ / excerpt |
|---|---:|---:|---:|---:|
| A | 0.80 | 0.33 | 1.17 | $0.0024 |
| B | 0.93 | 0.00 | 0.92 | $0.0107 |
| C | 0.93 | 0.00 | 1.17 | $0.0376 |
| A, then per-class verify | 0.80 | 0.00 | 0.42 | $0.0047 |

## The Jev router alone, and the state iteration

P(flag) for every class of every excerpt. "t" is the global threshold that
keeps 95% of dev's labelled positives; "forwarded" is classes per excerpt at t.
The AUC against unlabelled pairs treats them as negatives, which most are.

| evidence | state layout | AUC pos vs ctl | AUC pos vs unlabelled | t | controls forwarded | forwarded / excerpt | $ / excerpt |
|---|---|---:|---:|---:|---:|---:|---:|
| curated | shared: one request, all rules and notes in one state | 0.86 | 0.97 | 0.060 | 0.52 | 6.7 | $0.00097 |
| curated | shared1: shared, flag-first order only | 0.86 | 0.97 | 0.040 | 0.58 | 8.1 | $0.00059 |
| curated | family: one request per note family (5) | 0.87 | 0.97 | 0.045 | 0.52 | 7.6 | $0.00112 |
| curated | perclass: one request per class, that class's rule and notes only | 0.89 | 0.97 | 0.120 | 0.45 | 6.5 | $0.00266 |
| generated | shared (union of generators' refs) | 0.83 | 0.96 | 0.030 | 0.75 | 10.9 | $0.00102 |
| generated | perclass (each class's own generator) | 0.84 | 0.96 | 0.060 | 0.63 | 9.1 | $0.00261 |

The question text is the per-item benchmark's, unchanged; only where the rule,
the notes and the evidence sit moved (a shared state names its rule as
`rules.<class>`). Narrowing the state helped as the TypeSafe docs and the ledger
predict, from AUC 0.86 to 0.89 with curated evidence, but it forwards almost as
many classes (6.5 against 6.7) at 2.7 times the cost. With generated evidence
the union of six generators' refs in one state hurts the router (t falls to
0.030, 10.9 classes forwarded, 75% of controls forwarded); giving each class
only its own generator recovers a little (9.1). At 95% recall no layout
dismisses a hunk: at most one of dev's 81 excerpts with no labelled positive
had nothing forwarded (curated evidence), and none with generated evidence.

## Dev, curated evidence (the stage-1 ceiling)

| arm | recall | FPR | unlabelled flags / excerpt | $ / excerpt |
|---|---:|---:|---:|---:|
| A: Haiku battery | 0.86 (127/147) | 0.15 (11/71) | 0.64 | $0.0018 |
| B': Jev shared, t = 0.060, then the battery on the 6.7 forwarded classes | 0.86 (126/147) | 0.11 (8/71) | 0.63 | $0.0023 |
| B: Jev shared, then per-class Haiku | 0.90 (133/147) | 0.04 (3/71) | not measured | about $0.0077 |
| C: per-class Haiku, every class | 0.93 (137/147) | 0.04 (3/71) | not measured | about $0.047 |
| A, then Jev shared as a filter | 0.85 (125/147) | 0.14 (10/71) | 0.52 | $0.0027 |
| A, then per-class verify | 0.84 (123/147) | 0.04 (3/71) | not measured | about $0.0021 |

B's and C's costs here are estimates: Jev's measured cost plus the classes
asked times the measured per-class call ($0.0010 with curated evidence). B' was
not rerun with generated evidence; with curated evidence it matched A's recall
for 31% more cost.

## Test, generated evidence (run once)

The configurations carried to test: A, B with Jev shared at the dev-fit
t = 0.030, and the Jev filter. 311 excerpts, 214 positives, 93 controls.

| arm | recall | FPR | unlabelled flags / excerpt | $ / excerpt |
|---|---:|---:|---:|---:|
| A: Haiku battery | 0.84 (179/214) | 0.13 (12/93) | 1.41 | $0.0027 |
| B: Jev shared, then per-class Haiku | 0.79 (169/214) | 0.06 (6/93) | not measured | about $0.0100 |
| A, then Jev shared as a filter | 0.82 (175/214) | 0.13 (12/93) | 1.32 | $0.0037 |
| Jev shared alone at t | 0.94 (201/214) | 0.75 (70/93) | 9.91 | $0.0010 |

On test the router forwarded 11.2 classes per excerpt and kept 94% of the
positives; per-class Haiku then found 169 of the 201 it was given (0.84), the
same recall the battery reaches over all 47 classes. B's test cost is Jev's
measured cost plus 11.2 per-class calls at the $0.0008 measured on the dev
sample. Recall by evidence scope, A against B: local 0.91 and 0.93, file 0.78
and 0.59, repo 0.70 and 0.63. Most of what B gives up is `comment.stale` (12
misses against A's 10) and `dup.existing` (6 against 4).

## Audit of unlabelled flags (dev, generated)

`claude-opus-5-5` judged each sampled flag against its class's rubric row,
with the excerpt, the evidence, the quote and the reviewer's reason: is this a
real finding of that class (yes / no / unsure)? Fixed seed 20261017.

| arm | unlabelled flags | audited | yes | no | unsure | precision (yes / yes + no) |
|---|---:|---:|---:|---:|---:|---:|
| A: battery, all of dev | 280 | 25 | 14 | 10 | 1 | 0.58 |
| B: route, the 24-excerpt sample | 22 | 15 | 9 | 6 | 0 | 0.60 |

About 0.52 wrong unlabelled findings per excerpt for A (1.25 times 0.42) and
0.37 for B (0.92 times 0.40). A's wrong ones scatter over classes
(`comment.stale` 2, `defensive.silent-default` 2, one each of six others);
B's no-votes include two `test.gap` and two `comment.stale`. With 25 and 15
items a precision is good to about plus or minus 0.2, so the two arms'
unlabelled precision is indistinguishable. Opus is one judge, not the labels.

## Cost per hunk

| arm | dev | test | what the cost is |
|---|---:|---:|---|
| A: battery | $0.0025 | $0.0027 | one Haiku call (about 11,600 input tokens with curated evidence, of which about 6,700 are a shared prefix) |
| B: router, then per-class | $0.0107 | about $0.0100 | Jev $0.0010 plus 10 to 11 per-class calls at $0.0008 |
| C: per-class, every class | $0.0376 | - | 47 per-class calls |
| A, then per-class verify | $0.0047 | - | A plus 2.2 per-class calls |
| Jev router alone | $0.0010 | $0.0010 | about 23,000 input tokens: 94 questions and the shared state |

Headless Claude Code adds a fixed per-call overhead: a restricted battery over
6.7 classes cost $0.0013 against $0.0018 for all 47 (curated), so pruning
classes out of a battery saves a quarter of the call, less than the router
costs. **Prompt cache:** on 20 dev excerpts, `--prompt-cache` took the battery
from $0.00186 to $0.00170 per call (input-side cost from $0.00116 to
$0.00104), about 9%. The rubric prefix (6,753 tokens) is read from the cache,
but about 4,850 tokens per call are written fresh at the cache-write
surcharge. The battery runs above used it.

Wall time: a battery call takes 7 to 12 seconds. A Jev request took about 0.35
seconds (222 in 20 s at concurrency 4). B's 10 per-class calls are 36 seconds
of calls, 9 or more seconds of wall time at concurrency 4.

## Recommendation

**Drop Jev from the review funnel and use the Haiku battery as the cheap
stage.** One Haiku call over the whole rubric, with generated evidence, gets
recall 0.84 and FPR 0.13 on test for $0.0027 per hunk. Jev cannot make that
cheaper. Its pass over every class costs $0.0010, 40% of the battery itself,
it never dismisses a whole hunk at the recall a reviewer needs, and removing
classes from a battery call saves less than the router costs. In front of
per-class Haiku (B), Jev does what it should: it makes per-class prompting 3.5
times cheaper than asking every class (C), keeps 94 to 95% of positives, and
halves the control FPR against the battery (0.06 against 0.13 on test). But B
costs four times the battery and lost five points of recall on test (0.79
against 0.84), and its lower FPR comes from the per-class prompt with shots,
not from Jev. The cheaper way to buy that precision is to verify the battery's
findings with the per-class prompt (FPR 0.07 and 0.42 unlabelled flags per
excerpt on dev, at $0.0047), which needs no router; it costs about five points
of recall on dev and was not run on test. As a post-filter on the battery, Jev
removed almost nothing (FPR 0.13 to 0.13 on test) for 40% more cost. The state
iteration moved Jev's ranking (AUC 0.86 to 0.89 with curated evidence) but not
the forwarded count, and no layout changes the cost argument, so this is not a
question-and-state result that more iteration is likely to reverse.

What the evidence does not settle: whether the battery's 1.4 unlabelled flags
per hunk are worth their 0.4 to 0.5 wrong ones, and whether battery plus
per-class verify holds its dev numbers on test. Both turn on unlabelled
precision measured from 15 to 25 audited flags. A larger audit (about 100
flags per arm, about $4 at Opus prices) and the verify arm on test (about
$0.5) would settle them. Neither would bring Jev back as a cost saver: that
needs the router plus ten per-class calls to cost less than one battery call,
where here they cost four times as much.

## Caveats

- The per-class prompts carry two dev few-shot examples; the battery carries
  none. Part of the per-class FPR advantage is the shots.
- Dev's few-shot pool is dev itself (other sources only), so per-class dev
  numbers are a little optimistic; the test numbers have no such advantage.
- Fixture excerpts were chosen because they exhibit something: 64% of dev
  excerpts (143 of 224) carry a labelled positive. A real diff has many clean
  hunks. That would favour a router only if Jev dismissed clean hunks, and at
  95% recall it dismissed none of the 81 dev excerpts with no positive under
  generated evidence, one under curated.
- Costs are headless Claude Code's `total_cost_usd`, which includes Claude
  Code's own per-call prompt; a direct API caller would pay less per call, and
  most for the small per-class prompts, which narrows but does not close B's gap.
- Unlabelled flags are scored only by the audit. A real review's noise
  includes them; the labels cannot.
- Commands, from the repository root, with `B="python3 -I scripts/review_bench/battery.py"`:
  `$B jev --layout shared --evidence generated`,
  `$B battery --prompt-cache --evidence generated`,
  `$B perclass --which labelled --evidence generated`,
  `$B perclass --which all --sample 24 --evidence generated`,
  `$B route --router shared:fit95 --labelled-only --split test --evidence generated`,
  `$B audit --arm battery-pc --n 25 --evidence generated`,
  `$B report --evidence generated --arms battery-pc route:shared:fit95 perclass verify:battery-pc`.
- Total spend for this run: $7.11 (Jev $1.90, Haiku $3.60, Opus audit $1.61).
