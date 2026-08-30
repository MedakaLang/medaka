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
sha: 98f4815325960b5ef6279cfb1bd75bf9e89962d3
timer: gnu (/usr/bin/time -v)
load:  05:16:45 up 48 days,  7:47,  5 users,  load average: 3.38, 2.77, 2.27
N=3 warm runs (min-of-N, 1 discarded warm-up); cold = first invocation, no warm-up
Ir runs: cachegrind --cache-sim=no --branch-sim=no, GC_INITIAL_HEAP_SIZE=1073741824 pinned

| verb  | workload | cold  | warm  | co-metric   | RSS |
|-------|----------|-------|-------|-------------|-----|
| new   | hello   | 0.01s | 0.01s | bytes=20480 | 7MB |
| new   | project | 0.01s | 0.01s | bytes=20480 | 7MB |
| check | hello   | 0.22s | 0.33s | Ir=1383205823 | 27MB |
| check | project | 0.7s | 0.71s | Ir=3962842015 | 43MB |
| build | hello   | 0.93s | 0.9s | Ir=1026016138 | 92MB |
| build | project | 1.87s | 1.69s | Ir=3374986796 | 96MB |
| run   | hello   | 0.17s | 0.17s | Ir=1021223209 | 27MB |
| run   | project | 0.64s | 0.69s | Ir=3671967914 | 43MB |
| test  | hello   | 0.17s | 0.14s | Ir=782773226 | 19MB |
| test  | project | 0.32s | 0.35s | Ir=1982480596 | 35MB |

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

## Proposed per-verb targets — UNCONFIRMED, PENDING VAL

No target for any verb has been agreed by Val as of this writing (see #2040's
acceptance: "a stated target per verb, agreed BEFORE the run" — that agreement
has not happened, so #2040 stays open/re-scoped rather than closing; see the
issue drafts below). What follows is a **proposal**, not a decision: rationale
per verb, derived from what a user visibly waits on, plus a verdict against
the post-sprint numbers above so the shape of a miss is visible now rather
than after confirmation.

| verb | workload | proposed target (warm) | rationale | post-sprint | verdict |
|---|---|---|---|---:|---|
| `new` | either | < 0.1s | scaffolding a project must feel instantaneous; both workloads already 10x under this | 0.01s | **HIT** |
| `check` | hello | < 0.25s | the inner edit-loop floor; S-3 found ~98% of this is prelude parse/typecheck redundancy, a fixed cost independent of program size — 0.25s leaves headroom above that floor without hiding it | 0.19s | **HIT** |
| `check` | project | < 0.5s | "the one people compare against other languages" (#2040) on a 0.1.0-scale (3.6k line) project; chosen as roughly 2x the hello floor, since a 9-file project pays multi-module loader/resolve cost hello does not | 0.59s | **MISS** (18% over) |
| `build` | hello | < 1.0s | clang-bound (#2040); post-cache this is now typecheck+emit+one clang invocation on a tiny .c+.ll pair | 0.85s | **HIT** |
| `build` | project | < 2.0s | scaling the hello target by workload size the same way `check` does; `build` is clang-bound so this is more clang-time-dependent than compiler-controlled | 1.59s | **HIT** |
| `run` | hello | < 0.2s | interpreter path, same order as `check` hello since both share the front end and `run` skips clang entirely | 0.14s | **HIT** |
| `run` | project | < 0.7s | scaled the same way as `check project` | 0.54s | **HIT** |
| `test` | hello | < 0.2s | doctests+props over a near-empty file; dominated by the same prelude floor as `check` | 0.12s | **HIT** |
| `test` | project | < 0.4s | scaled the same way as `check project` | 0.30s | **HIT** |

**One miss: `check`/`project` at 0.59s vs a proposed 0.5s target (18% over).**
Filed as a named item (draft below, not `gh`-written per §5): the multi-module
loader/resolve path on a 9-file project is the standing cost this harness's
`check`/`build` split cannot separately attribute (S-3's decomposition was
`check`-hello-only; `check`-project has not been profiled the same way). This
is exactly the shape #2040 asks every miss to produce — a named Wave 2 item,
not a shrug.

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
