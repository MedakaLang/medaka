# PERF-BASELINE.md — absolute CLI-verb latency baseline

**Status:** the `## Table` section is GENERATED — its content is the stdout of
`sh test/perf_baseline.sh` (see `## Reproduction`). Everything from
`## Where the time goes` onward is a hand-authored section that does NOT
regenerate from this script and must be preserved across a regeneration —
see `## Reproduction`'s splice instructions, not a raw redirect.
Do not hand-edit the `## Table` section; edit test/perf_baseline.sh's
echo/comment text instead, then re-run the reproduction command.

## What this measures

Absolute (not relative/regression) latency of the five user-facing CLI verbs —
`new`, `check`, `build`, `run`, `test` — on two workloads:

- **hello**: `test/native_cli_fixtures/run/hello.mdk` (1 file, existing fixture, reused rather than adding
  a new one to the shared corpus).
- **project**: `gzip/main.mdk` (9 files, 3,650 lines — a 0.1.0-scale small real
  project; `parsec/` was the other plausible candidate at 4 files/761 lines,
  `sqlite/`/`pds/` are too large and `mq/`/`byteparser/` too small — see the
  sprint contract's project-inventory finding).

This is a DIFFERENT harness from test/bench.sh, which times compiled FIXTURE
BINARIES (fib/listsum/selfcompile) for emitter/runtime perf work. This script
times the CLI VERBS themselves end to end — the number a human waiting on
`medaka check` actually experiences.

**cold** = the first invocation of that verb+workload cell in this run of the
script, no warm-up. This is page-cache-cold-ISH first touch, NOT a
`drop_caches`-cold start (that needs root and was not requested), and — for
`build` specifically — NOT an empty rt-object-cache start either: this script
does not clear S-2's persistent $MEDAKA_CACHE_DIR before measuring, so on a
dev box that has built before, `build`'s cold column is cache-warm, not
genuinely first-ever. See the note under the Table.
**warm** = min-of-N after one discarded warm-up run (same convention as
test/bench.sh's `time_min`).

**co-metric** (deterministic, chosen per verb):
- `check`/`build`/`run`/`test`: cachegrind **Ir** (instruction count) of the
  `medaka` process itself — same method as the sprint contract's F7 citation
  (`valgrind --tool=cachegrind --cache-sim=no --branch-sim=no`, heap pinned via
  `GC_INITIAL_HEAP_SIZE`). For `build`, cachegrind does not trace the forked
  `clang` child, so this Ir number is the compiler's own typecheck+emit cost,
  excluding clang.
- `new`: total bytes of the scaffolded project tree — no compiler pipeline
  runs for this verb, so Ir is not a meaningful cost signal.

**Cross-check against the sprint contract's already-settled numbers
(F1: check hello 0.23-0.24s; F3: build hello wall 1.50-1.58s; F7: check hello
Ir=1,598,935,204):** compare the `check`/`hello` and `build`/`hello` rows
below by eye each time this is regenerated — they should agree within a few
percent. A larger drift is a finding, not something to smooth over.

## Table

host: Linux 6.12.95+deb13-amd64 x86_64
sha: ce504eee58f0f9848c1abf40792d9b6750b192da
timer: gnu (/usr/bin/time -v)
load:  08:37:28 up 48 days, 11:08,  7 users,  load average: 1.35, 4.11, 3.47
N=3 warm runs (min-of-N, 1 discarded warm-up); cold = first invocation, no warm-up
Ir runs: cachegrind --cache-sim=no --branch-sim=no, GC_INITIAL_HEAP_SIZE=1073741824 pinned

| verb  | workload | cold  | warm  | co-metric   | RSS |
|-------|----------|-------|-------|-------------|-----|
| new   | hello   | 0.01s | 0.01s | bytes=20480 | 7MB |
| new   | project | 0.01s | 0.01s | bytes=20480 | 7MB |
| check | hello   | 0.12s | 0.1s | Ir=625431278 | 18MB |
| check | project | 0.5s | 0.47s | Ir=3044719683 | 43MB |
| build | hello   | 0.73s | 0.83s | Ir=621128808 | 92MB |
| build | project | 1.64s | 1.73s | Ir=3375080908 | 96MB |
| run   | hello   | 0.14s | 0.13s | Ir=844785956 | 27MB |
| run   | project | 0.57s | 0.56s | Ir=3672111497 | 43MB |
| test  | hello   | 0.1s | 0.1s | Ir=606358888 | 18MB |
| test  | project | 0.28s | 0.33s | Ir=1982497117 | 34MB |

**Note on `build`'s `cold` column:** this run does not empty S-2's
persistent rt-object-cache ($MEDAKA_CACHE_DIR / $XDG_CACHE_HOME/medaka /
$HOME/.cache/medaka) first, so the number above is cache-warm-from-earlier-
development, not a genuinely first-ever build. Measured directly with the
cache dir removed, same box: a genuinely first-ever `build` costs ~1.7-1.9s
— slightly MORE than the pre-sprint (no-cache) baseline of ~1.6s, since it
now also pays the one-time cache-population cost on top of the old inline
compile. Every build after the first is the number in the Table above.

## Reproduction

The `## Table` section above (and everything before it, down through this
`## Reproduction` block) is GENERATED — its content is this script's stdout.
`## Where the time goes` onward in the committed doc is hand-authored and
must survive a regeneration, so splice rather than overwrite:

```sh
sh test/perf_baseline.sh > /tmp/perf_baseline_generated.md
awk '/^## Where the time goes/,0' compiler/PERF-BASELINE.md > /tmp/perf_baseline_handauthored.md
cat /tmp/perf_baseline_generated.md /tmp/perf_baseline_handauthored.md > compiler/PERF-BASELINE.md
```

## Where the time goes

The sprint's headline finding, decomposed and committed here so it outlives
the sprint directory (the source measurements live in the sprint's ephemeral
`reports/S-2-build-floor.md` §6.1 and `reports/S-3-check-floor.md` §6.1/§6.2,
which are not part of the repo).

### `check` (hello-world, ~0.23s floor)

Instruction attribution (Callgrind, heap pinned, `--separate-callers=3`,
1,597,372,412 Ir total) of `medaka check` on a one-line program:

| term | Ir | share |
|---|---:|---:|
| Prelude lex+parse, done **four times** | 885.0M | 55.4% |
| Typecheck, done **three times** (`checkOneDiags`, `cleanReport`, `elaborateModules`) | 677.8M | 42.4% |
| The user's own one-line file (`parseLocated`, with spans) | 0.2M | 0.013% |

**Verdict:** ~98% of a hello-world `medaka check` is redundant prelude work —
`stdlib/runtime.mdk`+`stdlib/core.mdk` parsed 4x and typechecked 3x on every
invocation, not user code. This is a caching/dedup fix, not an algorithmic
one; #followups propose sharing the parse (~40%) and, harder, the typecheck
(~42%) across `checkRoute`'s three consumers.

Boehm's real share, same workload, two Callgrind runs (heap pinned vs.
unpinned so collection is forced) isolate the collector from the allocator:

| | total Ir | libgc Ir | libgc share |
|---|---:|---:|---:|
| unpinned (38 collections) | 1,687,622,644 | 878,529,475 | 52.06% |
| pinned (0 collections) | 1,597,372,412 | 790,804,807 | 49.51% |

Difference (90.25M Ir, 87.7M inside libgc) **is** the collector; the rest of
libgc's share is the allocator fast path. So: **collector = 5.3pp of
instructions (38 collections); allocator = 46.8pp — nine times the
collector.**

**Verdict:** #124's "`check` is GC-bound" is upheld in kind on this workload
(52% vs. #124's 62% on a larger program, different instrument), but now
decomposed — nine-tenths of Boehm's share is the ALLOCATOR, not the
collector, so a fix should target allocating less, not collecting less.

### `build` (hello-world)

`MEDAKA_PERF=1 medaka build` sub-row split, same workload, three cache states:

| state | typecheck | emit-ir | gc-probe | rt-obj | clang | **total** |
|---|---:|---:|---:|---:|---:|---:|
| cache disabled (old default shape) | 0.174s | 0.122s | 0.006s | 0.00004s (inline) | 1.282s | **1.591s** |
| warm cache (new default, steady state) | 0.169s | 0.116s | 0.007s | 0.025s (cache hit) | 0.480s | **0.805s** |
| cold cache (first build on a machine) | — | — | — | 0.832s (cache miss, builds+writes) | — | **1.699s** |

**Verdict:** `clang` dominates a cache-disabled build (81% of the total); S-2's
rt-object cache turns every build after the first into a cache hit instead of
a full inline `medaka_rt.c` recompile, **1.59s → 0.80s (2.0x) on every build
after the first** — the very first build on a machine is slightly slower than
the old baseline (it pays the one-time cache-population cost), see the note
under `## Table` above.

### Capture-free closure allocation (capture-free-closures sprint, #2237)

A separate finding from the same allocator-vs-collector framing above:
`workFlat`/`workWhere`/`workWhere2`/`eta` probes
(`test/closure_alloc_fixtures/`), 2,000,000 calls each, `allocBytes()`
(`stdlib/runtime.mdk`, an extern backed by `GC_get_total_bytes()`), pinned
`MEDAKA_STRICT=1`:

| case | before (S-1/S-2's base, `b6d029cd`) | after (S-1+S-2) |
|---|---:|---:|
| top-level fn, invariant threaded explicitly (`flat`) | 32 B (baseline; one-time) | 32 B |
| `where`-binding closing over nothing (`where-nocapture`) | 63,996,384 B (32 B × 2,000,000 calls) | 32 B |
| top-level fn passed as a bare value in a tight loop (`eta`) | 63,996,384 B (32 B × 2,000,000 calls) | 32 B |

**Verdict:** before S-1/S-2, a capture-free `where`-binding or an eta-closure
allocated a fresh 32-byte closure cell on EVERY call, indistinguishable in
cost from a genuinely capturing closure — capture was never the driver of
the cost, allocating a closure cell at all was. S-1 (static-cell hoisting)
and S-2 (eta-closure sweep) hoist the cell to a one-time constant global for
the capture-free case, collapsing per-call cost to the same one-time 32 B as
the flat baseline — a >2,000,000x reduction in bytes allocated for this
workload shape. Pinned by `test/diff_compiler_closure_alloc.sh` (#2237,
S-3), with a generous `< 10,000` byte threshold rather than an exact `32` so
the gate isn't brittle to incidental allocator bookkeeping. Source
measurements: the sprint's `reports/S-1-static-cell.md` §Evidence and
`reports/S-2-capture-free-sweep.md` §Evidence (not part of the repo).

## Before / after this sprint

Pre-sprint = S-1's original harness run, sha `93a40382` (before S-2's build-object
cache and S-3's `mdk_string_append` allocation fix). Post-sprint = the `## Table`
run above, sha `c895844b` (S-1+S-2+S-3 landed). Same box, same script, same
method (`sh test/perf_baseline.sh`), rerun rather than re-derived — this is the
literal stdout of two separate invocations of the one-command harness, placed
side by side.

`warm` is wall-clock (min-of-3); the co-metric is deterministic instruction
count (Ir) except for `new`, which is bytes and does not move (no compiler
pipeline runs for that verb, expected and confirmed: identical both runs).

| verb  | workload | warm (pre) | warm (post) | Δwarm   | co-metric (pre) | co-metric (post) | Δco-metric |
|-------|----------|-----------:|------------:|--------:|-----------------:|------------------:|-----------:|
| new   | hello   | 0.01s | 0.01s |    0.0% | bytes=20480     | bytes=20480       |       0.0% |
| new   | project | 0.01s | 0.01s |    0.0% | bytes=20480     | bytes=20480       |       0.0% |
| check | hello   | 0.24s | 0.19s |  -20.8% | Ir=1,595,149,913 | Ir=1,383,205,845  |     -13.3% |
| check | project | 0.75s | 0.59s |  -21.3% | Ir=4,465,066,742 | Ir=3,962,844,357  |     -11.2% |
| build | hello   | 1.63s | 0.85s |  -47.9% | Ir=1,177,674,541 | Ir=1,026,016,963  |     -12.9% |
| build | project | 2.48s | 1.59s |  -35.9% | Ir=3,807,687,676 | Ir=3,374,982,713  |     -11.4% |
| run   | hello   | 0.19s | 0.14s |  -26.3% | Ir=1,174,421,916 | Ir=1,021,223,209  |     -13.0% |
| run   | project | 0.60s | 0.54s |  -10.0% | Ir=4,106,109,095 | Ir=3,671,965,588  |     -10.6% |
| test  | hello   | 0.14s | 0.12s |  -14.3% | Ir=911,304,657   | Ir=782,773,226    |     -14.1% |
| test  | project | 0.35s | 0.30s |  -14.3% | Ir=2,260,917,624 | Ir=1,982,480,596  |     -12.3% |

**Reading it.** Both S-2 (rt.o build-object cache) and S-3 (single-allocation
`mdk_string_append`) are visible, and separable by verb:

- **`build`'s warm-wall drop (-36% to -48%) is dominated by S-2's cache** — its
  own measurement (S-2's report, §6.3) put the hello-world build at 1.59s →
  0.80s (2.0x) in isolation; this harness's independent rerun lands at
  1.63s → 0.85s (1.9x), same effect, different run. `build`'s **Ir** column
  (which excludes the forked clang child — see `## What this measures`) moves
  by only ~12-13%, the same band as every other verb: the cache change is a
  clang-avoidance win, invisible to an instruction count that never counted
  clang in the first place. That the Ir delta for `build` tracks `check`'s Ir
  delta almost exactly (-12.9%/-11.4% vs -13.3%/-11.2%) is the expected
  signature of "the two changes are additive and mostly orthogonal."
- **The ~11-14% Ir drop present on every verb, including `run`/`test`/`build`
  which never touch S-2's cache path, is S-3's `mdk_string_append` fix** —
  every verb parses+typechecks the prelude and therefore exercises string
  concatenation in the same hot path S-3 profiled (S-3's own isolated
  measurement: -13.28% total Ir on `check` hello). The band is consistent
  (10.6%-14.1%) across both workloads and all five verbs, which is what a
  fix to a function called from the shared front end, rather than
  anything verb-specific, should look like.
- **`new` is the control** — it runs no compiler pipeline, and it is the one
  row that shows exactly 0.0% on both columns. That both changes leave the
  one untouched verb completely unmoved is evidence the deltas above are real
  effects of S-2/S-3, not noise or a harness artifact.
- Every `warm` delta is larger in magnitude than its corresponding Ir delta —
  expected, since `warm` also captures S-2's clang-avoidance (a real wall-clock
  win invisible to Ir) stacked on top of S-3's allocation win (visible to
  both), and general run-to-run wall-clock noise this harness does not
  isolate (single 3-run min, not a `perf stat -r 15` band).

## Before/after the `prelude-floor` sprint (S-1..S-4)

Pre-sprint = `b6d029cd` (this sprint's merge-base and the base F1 was measured against;
this row is a fresh re-run on that commit, not a re-derivation of an old number — see S-4's
report for the full command trace). Post-sprint = the current `## Table` run above, sha
`ce504eee` (S-1 prelude-parse-once + S-2 editor-loop + S-3 prelude-typecheck-once, plus a
resync merge of `origin/main` that landed two unrelated sprints, cost-enforcement #2225 and
ffi-residual-closeout #2230 — neither touches the prelude parse/typecheck path). Same box,
same script (`sh test/perf_baseline.sh`), both rerun for this comparison rather than
re-derived from prose.

| verb  | workload | warm (pre, `b6d029cd`) | warm (post, `ce504eee`) | Δwarm | Ir (pre) | Ir (post) | ΔIr |
|-------|----------|-----------:|------------:|--------:|-----------------:|------------------:|-----------:|
| new   | hello   | 0.01s | 0.01s |   0.0% | bytes=20480 | bytes=20480 |   0.0% |
| new   | project | 0.01s | 0.01s |   0.0% | bytes=20480 | bytes=20480 |   0.0% |
| check | hello   | 0.21s | 0.10s | -52.4% | 1,383,199,470 | 625,431,278 | -54.8% |
| check | project | 0.64s | 0.47s | -26.6% | 3,962,837,854 | 3,044,719,683 | -23.2% |
| build | hello   | 0.89s | 0.83s |  -6.7% | 1,026,010,501 | 621,128,808 | -39.5% |
| build | project | 1.75s | 1.73s |  -1.1% | 3,374,981,052 | 3,375,080,908 |   0.0% |
| run   | hello   | 0.17s | 0.13s | -23.5% | 1,021,216,777 | 844,785,956 | -17.3% |
| run   | project | 0.56s | 0.56s |   0.0% | 3,671,959,406 | 3,672,111,497 |   0.0% |
| test  | hello   | 0.12s | 0.10s | -16.7% | 782,766,737 | 606,358,888 | -22.5% |
| test  | project | 0.29s | 0.33s | +13.8% | 1,982,474,164 | 1,982,497,117 |   0.0% |

**Reading it — the sprint's win is `check`-shaped, not front-end-shaped.** `check`'s Ir drops
substantially on BOTH workloads (-54.8% hello, -23.2% project) — the verb whose call sites
(`checkRoute`, `analyzeFrom`, `checkJsonSingle`/`checkJsonFile`) S-1/S-3 actually converted
to the memoized `parsePrelude`/reduced-typecheck path. `build`/`run`/`test` show **~0% Ir
movement on the project workload** and only partial movement on hello (`build`/hello -39.5%
Ir but only -6.7% warm, since clang dominates wall time there) — S-1's own report flagged
this deliberately: "NOT converted: `run`/`build`/`test`(`test_cmd.mdk`) routes... each still
parses the prelude an extra time or two." This before/after table is the first empirical
confirmation of that scope note: **the redundant-prelude fix has not yet reached
`run`/`build`/`test`**, only `check`. A follow-up slice converting those remaining call
sites (S-1's Notes N3 lists the exact line numbers) is the obvious next win and is
explicitly out of this sprint's contract (S-4 measures, does not fix).

## `check gzip/` instruction attribution (S-4, #2235)

Command (F1's method; `--separate-callers` omitted for this aggregate roll-up — see the
report for why; a plain callgrind run's exclusive per-function cost sums to the program
total exactly, which a `--separate-callers` breakdown does not due to recursion-cycle
double-booking):

```
MEDAKA_STRICT=1 GC_INITIAL_HEAP_SIZE=1073741824 valgrind --tool=callgrind \
  --callgrind-out-file=cg.out ./medaka check gzip/main.mdk
I refs: 3,042,768,884
```

`callgrind_annotate --threshold=99.99`, function-name-prefix bucketed (rows sum to
3,042,465,135, 99.99% of the program total):

| bucket | Ir | share |
|---|---:|---:|
| GC (libgc + unnamed libgc addresses) | 1,504,970,983 | 49.5% |
| other compiler internals (mostly anonymous closures compiled from parser/typecheck bodies) | 354,152,013 | 11.6% |
| libc (memcpy/memcmp/printf/pthread/tls) | 348,691,661 | 11.5% |
| stdlib data structures (map/set/list/string/hash_*) | 325,627,988 | 10.7% |
| `frontend.parser` | 158,755,236 | 5.2% |
| `types.typecheck` | 121,626,030 | 4.0% |
| `frontend.lexer` | 80,583,056 | 2.6% |
| dispatch glue | 55,180,835 | 1.8% |
| `frontend.resolve` | 26,506,537 | 0.9% |
| `frontend.desugar` | 21,442,884 | 0.7% |
| `frontend.ast` | 19,030,700 | 0.6% |
| `frontend.exhaust` | 2,349,373 | 0.1% |
| `frontend.marker` | 1,925,955 | 0.1% |
| `driver.loader` (the multi-module walk/topo-sort glue itself) | 253,211 | 0.01% |
| `driver.diagnostics` | 14,301 | 0.00% |

**Verdict on #2235:** `check gzip/` at this binary is **0.47s warm / 0.50s cold** — under
the proposed <0.5s target on `warm`, exactly at the boundary on `cold` (see the updated
targets table below). Same allocator-dominated shape as hello-world (S-3's finding):
GC/allocator is ~50% of the cost at 9-file scale too, not a project-scale-specific
bottleneck. `driver.loader`'s own glue (module walk, topo sort, cycle detection) is
negligible (0.01%) — all real work is delegated to parser/resolve/typecheck per module, one
call each, which is exactly what §6.3's per-module scaling result below explains
mechanically.

## #983 verdict: per-INVOCATION multiplier, not per-module (S-4)

Three synthetic projects (1, 3, 9 trivial one-line modules imported by `main.mdk`, generated
fresh — content held constant, only module COUNT varies), cachegrind Ir
(`--cache-sim=no --branch-sim=no`, `GC_INITIAL_HEAP_SIZE` pinned, `MEDAKA_STRICT=1`):

| modules | Ir | marginal Ir/module vs previous row |
|---:|---:|---:|
| 1 | 817,605,012 | — |
| 3 | 861,138,345 | 21,766,667 |
| 9 | 992,314,026 | 21,862,614 |

Marginal Ir per additional module is constant to within 0.4% across a 3x range of module
count. A linear fit `base + k*N` (`k = 21,766,667`, `base = 795,838,345`) predicts N=9 at
991,764,398 against the measured 992,314,026 — 0.06% error.

**Verdict: REFUTED.** #983's literal "3x PER MODULE" claim does not hold on this (post
S-1..S-3) binary. The three-driver/prelude cost is a fixed per-INVOCATION constant
(collapsed by S-1: 4 prelude parses → 1; by S-3: 3 prelude typechecks → 2), independent of
module count. What scales with module count is the ordinary linear cost of parsing +
resolving + typechecking each module's own (small) file — ~21.8M Ir/module here, three
orders of magnitude below the ~180-220M Ir size of a single prelude parse or typecheck, so a
per-module repeat of the prelude cost would be obvious in this data and is not present. The
correct reading, per S-3's own edit to #983, is "3x per invocation" (confirmed, partially
fixed — 2 of 3 typechecks remain per this sprint's contract scope), not "3x per module."

## Proposed per-verb targets — UNCONFIRMED, PENDING VAL

No target for any verb has been agreed by Val as of this writing (see #2040's
acceptance: "a stated target per verb, agreed BEFORE the run" — that agreement
has not happened, so #2040 stays open/re-scoped rather than closing; see the
issue drafts below). What follows is a **proposal**, not a decision: rationale
per verb, derived from what a user visibly waits on, plus a verdict against
the post-sprint numbers above so the shape of a miss is visible now rather
than after confirmation.

**Re-measured by S-4 on the post-S-1..S-3 (+ resync) binary, sha `ce504eee`** — the
`post-sprint` column and verdicts below supersede the numbers an earlier slice recorded
before the sprint branch was resynced onto `origin/main`; targets/rationale are unchanged.

| verb | workload | proposed target (warm) | rationale | post-sprint | verdict |
|---|---|---|---|---:|---|
| `new` | either | < 0.1s | scaffolding a project must feel instantaneous; both workloads already 10x under this | 0.01s | **HIT** |
| `check` | hello | < 0.25s | the inner edit-loop floor; S-3 found ~98% of this is prelude parse/typecheck redundancy, a fixed cost independent of program size — 0.25s leaves headroom above that floor without hiding it | 0.10s | **HIT** |
| `check` | project | < 0.5s | "the one people compare against other languages" (#2040) on a 0.1.0-scale (3.6k line) project; chosen as roughly 2x the hello floor, since a 9-file project pays multi-module loader/resolve cost hello does not | 0.47s warm / 0.50s cold | **HIT (warm); at boundary (cold)** |
| `build` | hello | < 1.0s | clang-bound (#2040); post-cache this is now typecheck+emit+one clang invocation on a tiny .c+.ll pair | 0.83s | **HIT** |
| `build` | project | < 2.0s | scaling the hello target by workload size the same way `check` does; `build` is clang-bound so this is more clang-time-dependent than compiler-controlled | 1.73s | **HIT** |
| `run` | hello | < 0.2s | interpreter path, same order as `check` hello since both share the front end and `run` skips clang entirely | 0.13s | **HIT** |
| `run` | project | < 0.7s | scaled the same way as `check project` | 0.56s | **HIT** |
| `test` | hello | < 0.2s | doctests+props over a near-empty file; dominated by the same prelude floor as `check` | 0.10s | **HIT** |
| `test` | project | < 0.4s | scaled the same way as `check project` | 0.33s | **HIT** |

**The one prior miss, `check`/`project`, is now resolved to a HIT on `warm` (0.47s vs a
proposed 0.5s target) and sits exactly at the boundary on `cold` (0.50s).** This is S-1/S-3's
memoization discharging #2235 in the ordinary case (warm cache/second+ invocation, the
normal edit-loop shape); the `cold` column is the very first check of a session and is
inherently noisier (this harness's own caveat: page-cache-cold-ish, not `drop_caches`-cold).
**All nine measured cells now read HIT or at-boundary** against the proposed targets — no
named miss remains to carry forward as a Wave 2 item from this table. This does NOT mean
#2040 is discharged: the before/after table above shows `build`/`run`/`test` improved little
or not at all on the `project` workload (the redundant-prelude fix reached only `check`'s
call sites), so their current HITs reflect the *original* (pre-sprint) targets being
comfortably loose, not a sprint win on those verbs specifically.
## LSP editor-loop latency (#2040 residual, #962)

First committed numbers for the two editor-loop metrics #2040 names
(`prelude-floor` S-2). Method: a Python harness drives `medaka lsp` over its
real stdio JSON-RPC framing (Content-Length, same protocol
`test/diff_compiler_lsp*.sh` uses) — no gate/CLI shortcut — timing wall-clock
`time.perf_counter()` around the actual request/response or request/
notification pair, one fresh `medaka lsp` subprocess per trial, N=7 trials,
min-of-N and median reported (min isolates steady-state cost from scheduler
noise; median shown alongside since N is small). Box: this sprint's build box
(`.claude/workstreams` "shared box", not isolated). Two workloads:

- **open-file → first-diagnostic**: time from sending `textDocument/didOpen`
  (a one-line program with a type error) to receiving the
  `textDocument/publishDiagnostics` notification.
- **keystroke → hover**: time from sending `textDocument/didChange` (a
  full-document resync simulating one keystroke) — after draining that
  didChange's own diagnostics — to receiving the `textDocument/hover`
  response for a hover request sent immediately after, over the identifier
  `double` in `double x = x + x\nmain = println (double 3)\n`.

| workload | min (s) | median (s) | N |
|---|---:|---:|---:|
| open-file → first-diagnostic | 0.058 | 0.064 | 7 |
| keystroke → hover | 0.062 | 0.067 | 7 |

**Before/after this slice**, same harness, same box, re-run rather than
re-derived (the "before" run used the pre-slice binary, `docSchemes` in
`compiler/tools/lsp.mdk` calling `parseResult` on the prelude sources
directly instead of the S-1 memo):

| workload | before (min) | after (min) | note |
|---|---:|---:|---|
| open-file → first-diagnostic | 0.053 | 0.058 | unchanged (within noise) — this path (`analyzeLocated` → `analyzeFrom`) already routed through S-1's `parsePrelude` memo *before* this slice; S-1 already discharged it |
| keystroke → hover | 0.097 | 0.062 | **~37% faster** — `docSchemes` (hover/completion/inlayHint env build, `lsp.mdk:701-702`) was the one remaining site still calling `parseResult` on the raw prelude source on every request; this slice routes it through `parsePrelude` too |

**Verdict:** S-1's memo did NOT fully discharge #2040/#962 on its own —
`analyzeLocated`'s diagnostics path was already covered (confirmed by the
unchanged before/after number above), but `docSchemes` was not, and it is the
env build behind hover/completion/inlayHint. This slice wires that one
remaining site onto the existing memo; the LSP's third prelude-parsing path,
`analyzeProject`/`publishProjectDiagnostics` (multi-module diagnostics,
`lsp.mdk:1602`), already had its own independent once-per-session memo
(`preludeDesugared`, keyed on a `Ref` threaded from the LSP's own
`projectParseCache`, pre-dating this sprint) and needed no change.
`buildRefIndexProject`'s `seedPrelude` (`compiler/tools/refindex.mdk`, the
`textDocument/references` path) still re-parses the prelude every request via
`parseWithPositionsOpt` — a LOCATED parse, explicitly out of scope per
`parse_cache.mdk`'s "WHAT THIS IS NOT FOR" (only the non-located `parse` is
memoized); left untouched, noted as a candidate for a future slice, not part
of this one's §5.

**Parity, not a behavior change**: `docSchemes` returns `List (String,
Scheme)` (`(name, type scheme)` pairs) with no `Loc`/span field anywhere in
its result — unlike `analyzeLocated`'s `Diag`s, nothing it produces can carry
a stale or zero-span prelude location, so swapping its prelude source from
`parseResult`+`unwrapDecls` to the memoized `parsePrelude` changes no
observable output. `parsePrelude`'s own doc comment establishes `parse` and
`parseResult`'s `Ok` payload are the same decls for prelude source (a strict
refinement, `parseResult` only adds a pre-scan `parse` skips) — moot here
regardless, since `stdlib/core.mdk`/`stdlib/runtime.mdk` always parse
successfully and `docSchemes`'s own `unwrapDecls` already treated a
theoretical `Err` on the prelude as `[]` defensively.
