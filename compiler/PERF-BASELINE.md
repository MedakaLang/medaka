# PERF-BASELINE.md — absolute CLI-verb latency baseline

**Status:** GENERATED — this entire file is the stdout of `sh test/perf_baseline.sh`.
Regenerate with: `sh test/perf_baseline.sh > compiler/PERF-BASELINE.md` (one command).
Do not hand-edit below this line; edit test/perf_baseline.sh's echo/comment text instead.

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
`drop_caches`-cold start (that needs root and was not requested).
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
sha: 93a4038211252dd5133c11883e4e0f09dff957f2
timer: gnu (/usr/bin/time -v)
load:  03:40:13 up 48 days,  6:11,  5 users,  load average: 1.24, 1.03, 0.86
N=3 warm runs (min-of-N, 1 discarded warm-up); cold = first invocation, no warm-up
Ir runs: cachegrind --cache-sim=no --branch-sim=no, GC_INITIAL_HEAP_SIZE=1073741824 pinned

| verb  | workload | cold  | warm  | co-metric   | RSS |
|-------|----------|-------|-------|-------------|-----|
| new   | hello   | 0.01s | 0.01s | bytes=20480 | 7MB |
| new   | project | 0.01s | 0.01s | bytes=20480 | 7MB |
| check | hello   | 0.34s | 0.24s | Ir=1595149913 | 27MB |
| check | project | 0.7s | 0.75s | Ir=4465066742 | 44MB |
| build | hello   | 1.61s | 1.63s | Ir=1177674541 | 108MB |
| build | project | 2.61s | 2.48s | Ir=3807687676 | 109MB |
| run   | hello   | 0.17s | 0.19s | Ir=1174421916 | 27MB |
| run   | project | 0.6s | 0.6s | Ir=4106109095 | 36MB |
| test  | hello   | 0.13s | 0.14s | Ir=911304657 | 18MB |
| test  | project | 0.31s | 0.35s | Ir=2260917624 | 36MB |

## Reproduction

```sh
sh test/perf_baseline.sh > compiler/PERF-BASELINE.md
```
