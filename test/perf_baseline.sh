#!/bin/sh
# perf_baseline.sh — absolute CLI-verb latency baseline for Medaka.
#
# Times `new`/`check`/`build`/`run`/`test` on TWO workloads (hello-world-scale,
# and one small real 0.1.0-scale project) and prints a markdown table with
# wall-clock (cold + warm), a deterministic co-metric, peak RSS, and full
# provenance. Companion to compiler/PERF-BASELINE.md (the committed snapshot)
# and test/bench.sh (a DIFFERENT harness — bench.sh times compiled FIXTURE
# BINARIES for emitter/runtime perf work; this script times the CLI VERBS
# themselves, end to end, for user-latency baselining). Not a gate: reports
# numbers, asserts nothing. See test/CI-COVERAGE-TOOLS.txt.
#
# Usage:
#   sh test/perf_baseline.sh                 # N=3 warm runs per cell
#   sh test/perf_baseline.sh -n 5             # min-of-5 warm runs
#   sh test/perf_baseline.sh > /tmp/perf_baseline_generated.md   # regenerate the
#     GENERATED prefix of compiler/PERF-BASELINE.md (through "## Reproduction")
#     only — see that section's own splice instructions to fold it back in
#     without clobbering the doc's hand-authored sections ("## Where the time
#     goes" onward). Do NOT redirect straight over compiler/PERF-BASELINE.md —
#     that destroys the hand-authored sections.
#
# Workloads:
#   hello    test/native_cli_fixtures/run/hello.mdk  (1 file, existing fixture
#            — reused rather than adding a new one, see AGENTS.md T-SHARED-CORPUS)
#   project  gzip/main.mdk  (9 files, 3,650 lines — 0.1.0-scale small project;
#            see compiler/PERF-BASELINE.md for why gzip over parsec/sqlite/mq)
#
# Verbs measured: new, check, build, run, test.
#
# Cold vs warm: "cold" is the FIRST invocation of that verb+workload cell in
# this run of the script (no warm-up) — it reflects page-cache-cold-ish
# first-touch cost. "warm" is min-of-N after one discarded warm-up run, same
# convention as test/bench.sh's time_min. This is NOT a `sync; echo 3 >
# drop_caches` cold start (that needs root and is not requested by the
# packet) — say so plainly rather than imply something stronger.
#
# Co-metric per verb (deterministic, chosen per verb — see compiler/PERF-BASELINE.md):
#   check/build/run/test: cachegrind Ir (instruction count) of the `medaka`
#     process itself, same method as compiler/PERF-BASELINE.md's F7 citation
#     (`valgrind --tool=cachegrind --cache-sim=no --branch-sim=no`, heap
#     pinned via GC_INITIAL_HEAP_SIZE). For `build`, cachegrind does NOT trace
#     the forked `clang` child (no --trace-children), so this Ir number is
#     the compiler's own typecheck+emit cost, excluding clang.
#   new: total bytes of the scaffolded project tree (no compiler pipeline
#     runs, so Ir is not a meaningful cost signal here).
#
# Timing arm (copied from test/bench.sh's detection block, kept in sync by
# hand — small enough that sourcing bench.sh, which RUNS a benchmark as a
# side effect, is not worth doing):
#   macos    /usr/bin/time -l
#   gnu      /usr/bin/time -v
#   fallback date +%s.%N (rss=n/a)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
[ -x "$ROOT/medaka_emitter" ] && export MEDAKA_EMITTER="$ROOT/medaka_emitter"

N=3
while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -x "$MEDAKA" ] || { echo "build first: make medaka (missing $MEDAKA)" >&2; exit 2; }
command -v valgrind >/dev/null 2>&1 || { echo "no valgrind on PATH — required for the Ir co-metric" >&2; exit 2; }

cd "$ROOT" || exit 2

HELLO_FILE="test/native_cli_fixtures/run/hello.mdk"
PROJECT_FILE="gzip/main.mdk"
[ -f "$HELLO_FILE" ] || { echo "missing $HELLO_FILE" >&2; exit 2; }
[ -f "$PROJECT_FILE" ] || { echo "missing $PROJECT_FILE" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── timing-arm detection (see test/bench.sh header for full rationale) ──────
TIME_ARM=""
TIME_BIN=""
_probe="$WORK/probe"
if /usr/bin/time -l true >"$_probe" 2>&1 && grep -q 'maximum resident set size' "$_probe"; then
  TIME_ARM="macos"; TIME_BIN="/usr/bin/time -l"
fi
if [ -z "$TIME_ARM" ]; then
  for _cand in /usr/bin/time "$(command -v time 2>/dev/null || true)"; do
    [ -n "$_cand" ] && [ -x "$_cand" ] || continue
    if "$_cand" -v true >"$_probe" 2>&1 && grep -q 'Elapsed (wall clock) time' "$_probe"; then
      TIME_ARM="gnu"; TIME_BIN="$_cand -v"; break
    fi
  done
fi
[ -z "$TIME_ARM" ] && TIME_ARM="fallback"

elapsed_to_secs() {
  printf '%s' "$1" | awk -F: '{
    n=NF
    if (n==3) s=$1*3600+$2*60+$3
    else if (n==2) s=$1*60+$2
    else s=$1
    printf "%s", s
  }'
}

# run_one CMD... -> prints "SECS RSS_MB_or_na" on stdout for a single run.
run_one() {
  case "$TIME_ARM" in
    macos)
      $TIME_BIN "$@" >/dev/null 2>"$WORK/t.err"
      _r="$(awk '/real/{print $1}' "$WORK/t.err")"
      _rb="$(awk '/maximum resident/{print $1}' "$WORK/t.err")"
      _m="$((_rb / 1048576))"
      ;;
    gnu)
      $TIME_BIN "$@" >/dev/null 2>"$WORK/t.err"
      _el="$(awk -F': ' '/Elapsed \(wall clock\)/{print $2}' "$WORK/t.err")"
      _r="$(elapsed_to_secs "$_el")"
      _rk="$(awk -F': ' '/Maximum resident set size/{print $2}' "$WORK/t.err")"
      _m="$((_rk / 1024))"
      ;;
    fallback)
      _t0="$(date +%s.%N)"
      "$@" >/dev/null 2>"$WORK/t.err"
      _t1="$(date +%s.%N)"
      _r="$(awk "BEGIN{printf \"%.3f\", $_t1 - $_t0}")"
      _m="n/a"
      ;;
  esac
  printf '%s %s\n' "$_r" "$_m"
}

# ir_of CMD... -> prints the cachegrind Ir total for one run of CMD (heap pinned).
ir_of() {
  GC_INITIAL_HEAP_SIZE=1073741824
  export GC_INITIAL_HEAP_SIZE
  valgrind --tool=cachegrind --cache-sim=no --branch-sim=no \
    --cachegrind-out-file="$WORK/cg.out" \
    "$@" >/dev/null 2>"$WORK/vg.err"
  _ir="$(grep -a 'I  *refs:' "$WORK/vg.err" | sed 's/.*I *refs: *//' | tr -d ' ,')"
  unset GC_INITIAL_HEAP_SIZE
  case "$_ir" in
    ''|*[!0-9]*) printf 'n/a' ;;
    *) printf '%s' "$_ir" ;;
  esac
}

dirsize_bytes() {
  du -sk "$1" 2>/dev/null | awk '{print $1*1024}'
}

# measure_cell VERB WORKLOAD -> prints one markdown table row.
measure_cell() {
  _verb="$1"; _wl="$2"
  if [ "$_wl" = "hello" ]; then _f="$HELLO_FILE"; else _f="$PROJECT_FILE"; fi
  _outbin="$WORK/out_${_verb}_${_wl}"

  case "$_verb" in
    new)
      _newbase="$WORK/newroot_${_wl}"
      rm -rf "$_newbase"; mkdir -p "$_newbase"
      _i=0
      _cold_read=""
      while [ "$_i" -le "$N" ]; do
        rm -rf "$_newbase/p"
        _line="$(cd "$_newbase" && run_one "$MEDAKA" new p)"
        [ "$_i" -eq 0 ] && _cold_read="$_line" # first invocation = cold
        [ "$_i" -ge 1 ] && printf '%s\n' "$_line" >>"$WORK/warm.$$"
        _i=$((_i + 1))
      done
      _cometric="$(dirsize_bytes "$_newbase/p")"
      _cometric_name="bytes"
      ;;
    check) _cmd="$MEDAKA check $_f" ;;
    build) _cmd="$MEDAKA build $_f -o $_outbin" ;;
    run)   _cmd="$MEDAKA run $_f" ;;
    test)  _cmd="$MEDAKA test $_f" ;;
  esac

  if [ "$_verb" != "new" ]; then
    _cold_read="$(run_one $_cmd)"
    rm -f "$WORK/warm.$$"
    _i=0
    while [ "$_i" -lt "$N" ]; do
      run_one $_cmd >>"$WORK/warm.$$" # discard first (warm-up) below
      _i=$((_i + 1))
    done
    _cometric="$(ir_of $_cmd)"
    _cometric_name="Ir"
  fi

  # warm-up: the first line of warm.$$ is a warm-up run, discard it; take
  # min-of-remaining. If fewer than 2 lines exist, fall back to what's there.
  _wcount="$(wc -l <"$WORK/warm.$$" 2>/dev/null || echo 0)"
  _best=""; _brss=""
  _n=0
  while IFS=' ' read -r _s _m; do
    _n=$((_n + 1))
    [ "$_n" -eq 1 ] && continue # discard warm-up
    if [ -z "$_best" ] || awk "BEGIN{exit !($_s < $_best)}"; then _best="$_s"; _brss="$_m"; fi
  done <"$WORK/warm.$$"
  [ -z "$_best" ] && { _best="$(echo "$_cold_read" | awk '{print $1}')"; _brss="$(echo "$_cold_read" | awk '{print $2}')"; }
  rm -f "$WORK/warm.$$"

  _cs="$(echo "$_cold_read" | awk '{print $1}')"
  printf '| %-5s | %-7s | %ss | %ss | %s=%s | %sMB |\n' \
    "$_verb" "$_wl" "$_cs" "$_best" "$_cometric_name" "$_cometric" "$_brss"
}

echo "# PERF-BASELINE.md — absolute CLI-verb latency baseline"
echo
echo "**Status:** the \`## Table\` section is GENERATED — its content is the stdout of"
echo "\`sh test/perf_baseline.sh\` (see \`## Reproduction\`). Everything from"
echo "\`## Where the time goes\` onward is a hand-authored section that does NOT"
echo "regenerate from this script and must be preserved across a regeneration —"
echo "see \`## Reproduction\`'s splice instructions, not a raw redirect."
echo "Do not hand-edit the \`## Table\` section; edit test/perf_baseline.sh's"
echo "echo/comment text instead, then re-run the reproduction command."
echo
echo "## What this measures"
echo
echo "Absolute (not relative/regression) latency of the five user-facing CLI verbs —"
echo "\`new\`, \`check\`, \`build\`, \`run\`, \`test\` — on two workloads:"
echo
echo "- **hello**: \`$HELLO_FILE\` (1 file, existing fixture, reused rather than adding"
echo "  a new one to the shared corpus)."
echo "- **project**: \`$PROJECT_FILE\` (9 files, 3,650 lines — a 0.1.0-scale small real"
echo "  project; \`parsec/\` was the other plausible candidate at 4 files/761 lines,"
echo "  \`sqlite/\`/\`pds/\` are too large and \`mq/\`/\`byteparser/\` too small — see the"
echo "  sprint contract's project-inventory finding)."
echo
echo "This is a DIFFERENT harness from test/bench.sh, which times compiled FIXTURE"
echo "BINARIES (fib/listsum/selfcompile) for emitter/runtime perf work. This script"
echo "times the CLI VERBS themselves end to end — the number a human waiting on"
echo "\`medaka check\` actually experiences."
echo
echo "**cold** = the first invocation of that verb+workload cell in this run of the"
echo "script, no warm-up. This is page-cache-cold-ISH first touch, NOT a"
echo "\`drop_caches\`-cold start (that needs root and was not requested), and — for"
echo "\`build\` specifically — NOT an empty rt-object-cache start either: this script"
echo "does not clear S-2's persistent \$MEDAKA_CACHE_DIR before measuring, so on a"
echo "dev box that has built before, \`build\`'s cold column is cache-warm, not"
echo "genuinely first-ever. See the note under the Table."
echo "**warm** = min-of-N after one discarded warm-up run (same convention as"
echo "test/bench.sh's \`time_min\`)."
echo
echo "**co-metric** (deterministic, chosen per verb):"
echo "- \`check\`/\`build\`/\`run\`/\`test\`: cachegrind **Ir** (instruction count) of the"
echo "  \`medaka\` process itself — same method as the sprint contract's F7 citation"
echo "  (\`valgrind --tool=cachegrind --cache-sim=no --branch-sim=no\`, heap pinned via"
echo "  \`GC_INITIAL_HEAP_SIZE\`). For \`build\`, cachegrind does not trace the forked"
echo "  \`clang\` child, so this Ir number is the compiler's own typecheck+emit cost,"
echo "  excluding clang."
echo "- \`new\`: total bytes of the scaffolded project tree — no compiler pipeline"
echo "  runs for this verb, so Ir is not a meaningful cost signal."
echo
echo "**Cross-check against the sprint contract's already-settled numbers"
echo "(F1: check hello 0.23-0.24s; F3: build hello wall 1.50-1.58s; F7: check hello"
echo "Ir=1,598,935,204):** compare the \`check\`/\`hello\` and \`build\`/\`hello\` rows"
echo "below by eye each time this is regenerated — they should agree within a few"
echo "percent. A larger drift is a finding, not something to smooth over."
echo
echo "## Table"
echo
echo "host: $(uname -srm)"
echo "sha: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
echo "timer: $TIME_ARM ($TIME_BIN)"
echo "load: $(uptime 2>/dev/null || echo n/a)"
echo "N=$N warm runs (min-of-N, 1 discarded warm-up); cold = first invocation, no warm-up"
echo "Ir runs: cachegrind --cache-sim=no --branch-sim=no, GC_INITIAL_HEAP_SIZE=1073741824 pinned"
echo
echo "| verb  | workload | cold  | warm  | co-metric   | RSS |"
echo "|-------|----------|-------|-------|-------------|-----|"
for verb in new check build run test; do
  for wl in hello project; do
    measure_cell "$verb" "$wl"
  done
done
echo
echo "**Note on \`build\`'s \`cold\` column:** this run does not empty S-2's"
echo "persistent rt-object-cache (\$MEDAKA_CACHE_DIR / \$XDG_CACHE_HOME/medaka /"
echo "\$HOME/.cache/medaka) first, so the number above is cache-warm-from-earlier-"
echo "development, not a genuinely first-ever build. Measured directly with the"
echo "cache dir removed, same box: a genuinely first-ever \`build\` costs ~1.7-1.9s"
echo "— slightly MORE than the pre-sprint (no-cache) baseline of ~1.6s, since it"
echo "now also pays the one-time cache-population cost on top of the old inline"
echo "compile. Every build after the first is the number in the Table above."
echo
echo "## Reproduction"
echo
echo "The \`## Table\` section above (and everything before it, down through this"
echo "\`## Reproduction\` block) is GENERATED — its content is this script's stdout."
echo "\`## Where the time goes\` onward in the committed doc is hand-authored and"
echo "must survive a regeneration, so splice rather than overwrite:"
echo
echo '```sh'
echo "sh test/perf_baseline.sh > /tmp/perf_baseline_generated.md"
echo "awk '/^## Where the time goes/,0' compiler/PERF-BASELINE.md > /tmp/perf_baseline_handauthored.md"
echo "cat /tmp/perf_baseline_generated.md /tmp/perf_baseline_handauthored.md > compiler/PERF-BASELINE.md"
echo '```'
echo
