#!/bin/sh
# bench.sh — native-backend performance harness for Medaka.
#
# Times the standard workloads on the CURRENT sources/binary and prints a table.
# Companion to compiler/PERF-SCOPE.md (plan) and compiler/PERF-RESULTS.md (log).
#
# Workloads:
#   fib 38      test/bench_fixtures/fib.mdk     — pure compute, NO heap alloc.
#   listsum     test/bench_fixtures/listsum.mdk — cons churn / GC pressure.
#   (the runtime micro-suite loop) — float/ADT/list/closure/string isolation
#               fixtures; see compiler/PERF-RUNTIME.md's fixture table.
#   startup     trivial `main = putStrLn "x"` — process/runtime-init floor,
#               isolates fixed per-process overhead from every workload above.
#   fib_c/bintrees_c — hand-written C equivalents of fib/bintrees
#               (test/bench_fixtures/c/*.c), no GC/runtime, -O2: a sanity
#               ceiling, not a fair comparison (see compiler/PERF-RUNTIME.md).
#   selfcompile native emitter emitting its OWN module graph (~10 MB IR) — the
#               heaviest representative workload, the OCaml-retirement perf bar.
#
# It builds each fixture via `medaka build` (so it picks up whatever clang flags
# the build driver currently uses) and times the native binary min-of-N, also
# reporting each binary's on-disk size. `selfcompile` additionally builds the
# emitter once, then times it.
#
# Usage:
#   sh test/bench.sh            # N=3, all workloads
#   sh test/bench.sh -n 5       # min-of-5
#   sh test/bench.sh --quick    # skip selfcompile + interpreter (fast micros only)
#   sh test/bench.sh --interp   # also time the OCaml interpreter self-compile (slow)
#
# Quiet-machine discipline (see PERF-SCOPE §2b): run single-threaded, close other
# apps, warm the file cache (the harness warms once before timing).
#
# Timing arms (probed once, in preference order, by the inline detection
# block right after the prerequisite checks below — no separate function):
#   macos    /usr/bin/time -l   (BSD time: "real" in seconds, RSS in BYTES)
#   gnu      /usr/bin/time -v, or PATH `time -v` (GNU time: "Elapsed (wall clock)
#            time" as [h:]m:ss[.ss], RSS in KILOBYTES — NOT bytes; do not reuse
#            the macOS divisor here, it would under-report RSS by 1024x)
#   fallback `date +%s.%N` around the child process. No external time binary
#            needed for wall-clock (GNU coreutils `date` gives sub-second
#            resolution for free); RSS is not obtainable this way and is
#            reported as `rss=n/a` rather than guessed at or skipped.
# The selected arm is printed in the header so a reader always knows the
# provenance of the numbers below it.
#
# Exit: 0 ok; 2 if prerequisites are missing (binary not built, no clang/libgc).
# Platform is NOT a prerequisite-missing reason — every platform gets at least
# the fallback arm, so this script no longer skips on Linux.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Prefer the native `medaka` (the OCaml `medaka build` path is dead — its
# interpreter can no longer parse the compiler emitter source). Builds shell out
# to an emitter, so point MEDAKA_EMITTER at the native emitter for OCaml-free builds.
MAIN="$ROOT/medaka"
[ -x "$ROOT/medaka_emitter" ] && export MEDAKA_EMITTER="$ROOT/medaka_emitter"
EMIT_DRIVER="compiler/entries/llvm_emit_modules_main.mdk"
RUNTIME="stdlib/runtime.mdk"
CORE="stdlib/core.mdk"

N=3
DO_SELFCOMPILE=1
DO_INTERP=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="$2"; shift 2 ;;
    --quick) DO_SELFCOMPILE=0; shift ;;
    --interp) DO_INTERP=1; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

[ -x "$MAIN" ] || { echo "build first: make medaka (missing $MAIN)"; exit 2; }
command -v clang >/dev/null 2>&1 || { echo "no clang on PATH — skipping"; exit 2; }

cd "$ROOT" || exit 2

# ── detect the best available timing mechanism (once) ───────────────────────
# Preference: macOS BSD `time -l` > GNU `time -v` (either at /usr/bin/time or
# found on PATH, e.g. after `apt install time`) > no-external-binary fallback.
# Each candidate is executed against `true` and its OUTPUT is inspected (not
# just its exit code) before being trusted, because a wrong-flavor `time`
# binary at the expected path can still exit 0 while printing nothing useful,
# or exit nonzero for an unsupported flag (both observed while writing this).
TIME_ARM=""
TIME_BIN=""
_probe="/tmp/_bench_probe.$$"

if /usr/bin/time -l true >"$_probe" 2>&1 && grep -q 'maximum resident set size' "$_probe"; then
  TIME_ARM="macos"
  TIME_BIN="/usr/bin/time -l"
fi

if [ -z "$TIME_ARM" ]; then
  for _cand in /usr/bin/time "$(command -v time 2>/dev/null || true)"; do
    [ -n "$_cand" ] && [ -x "$_cand" ] || continue
    if "$_cand" -v true >"$_probe" 2>&1 && grep -q 'Elapsed (wall clock) time' "$_probe"; then
      TIME_ARM="gnu"
      TIME_BIN="$_cand -v"
      break
    fi
  done
fi

rm -f "$_probe"

if [ -z "$TIME_ARM" ]; then
  TIME_ARM="fallback"
  TIME_BIN=""
fi

# convert GNU time's "[h:]mm:ss[.ss]" elapsed string to plain seconds
elapsed_to_secs() {
  printf '%s' "$1" | awk -F: '{
    n = NF
    if (n == 3) { s = $1*3600 + $2*60 + $3 }
    else if (n == 2) { s = $1*60 + $2 }
    else { s = $1 }
    printf "%s", s
  }'
}

# run CMD N times, print "  min=<s>s  rss=<MB>MB" (or "rss=n/a") using the
# min real/elapsed time over runs. Dispatches on TIME_ARM detected above.
time_min() {
  _best=""; _rss=""
  i=0
  while [ "$i" -lt "$N" ]; do
    case "$TIME_ARM" in
      macos)
        $TIME_BIN "$@" >/dev/null 2>/tmp/_bench_t.$$
        _r="$(awk '/real/{print $1}' /tmp/_bench_t.$$)"
        _rss_bytes="$(awk '/maximum resident/{print $1}' /tmp/_bench_t.$$)"
        _m="$((_rss_bytes / 1048576))" # bytes -> MB (macOS reports bytes)
        ;;
      gnu)
        $TIME_BIN "$@" >/dev/null 2>/tmp/_bench_t.$$
        _elapsed="$(awk -F': ' '/Elapsed \(wall clock\)/{print $2}' /tmp/_bench_t.$$)"
        _r="$(elapsed_to_secs "$_elapsed")"
        _rss_kb="$(awk -F': ' '/Maximum resident set size/{print $2}' /tmp/_bench_t.$$)"
        _m="$((_rss_kb / 1024))" # KB -> MB (GNU time reports kilobytes, NOT bytes)
        ;;
      fallback)
        _t0="$(date +%s.%N)"
        "$@" >/dev/null 2>/tmp/_bench_t.$$
        _t1="$(date +%s.%N)"
        _r="$(awk "BEGIN{printf \"%.3f\", $_t1 - $_t0}")"
        _m="n/a"
        ;;
    esac
    if [ -z "$_best" ] || awk "BEGIN{exit !($_r < $_best)}"; then _best="$_r"; _rss="$_m"; fi
    i=$((i + 1))
  done
  rm -f /tmp/_bench_t.$$
  if [ "$_rss" = "n/a" ]; then
    printf 'min=%ss  rss=n/a' "$_best"
  else
    printf 'min=%ss  rss=%dMB' "$_best" "$_rss"
  fi
}

echo "== Medaka native-backend benchmark =="
echo "host: $(uname -m)  clang: $(clang --version | head -1 | sed 's/ (.*//')"
echo "N=$N (min-of-$N), single-threaded recommended"
case "$TIME_ARM" in
  macos) echo "timer: macos (/usr/bin/time -l)" ;;
  gnu) echo "timer: gnu ($TIME_BIN)" ;;
  fallback) echo "timer: fallback (date +%s.%N; no external time binary — rss=n/a)" ;;
esac
echo

# ── micro: fib (no alloc) ────────────────────────────────────────────────────
echo "building fib..."; "$MAIN" build test/bench_fixtures/fib.mdk -o /tmp/_bench_fib >/dev/null 2>&1 \
  || { echo "fib build FAILED"; exit 2; }
"/tmp/_bench_fib" >/dev/null 2>&1 # warm
printf 'fib 38       %s  size=%sB\n' "$(time_min /tmp/_bench_fib)" "$(wc -c </tmp/_bench_fib | tr -d ' ')"

# ── micro: listsum (GC pressure) ─────────────────────────────────────────────
echo "building listsum..."; "$MAIN" build test/bench_fixtures/listsum.mdk -o /tmp/_bench_ls >/dev/null 2>&1 \
  || { echo "listsum build FAILED"; exit 2; }
"/tmp/_bench_ls" >/dev/null 2>&1 # warm
printf 'listsum      %s  size=%sB\n' "$(time_min /tmp/_bench_ls)" "$(wc -c </tmp/_bench_ls | tr -d ' ')"

# ── runtime micro-suite (float/ADT/list/closure/string) ──────────────────────
# See compiler/PERF-RUNTIME.md. floatsum/mandel isolate float boxing (Win 1/2:
# fusion + let-unboxing); bintrees = ADT/GC; listops/closures = cons/closure churn.
for b in intsum floatsum floatsum_guard mandel mandel_let bintrees closures strbuild dispatch strlit listlit tuplit listops taylor fhelp; do
  src="test/bench_fixtures/$b.mdk"
  [ -f "$src" ] || continue
  if "$MAIN" build "$src" -o "/tmp/_bench_$b" >/dev/null 2>&1; then
    "/tmp/_bench_$b" >/dev/null 2>&1 # warm
    _size="$(wc -c </tmp/_bench_$b | tr -d ' ')"
    printf '%-12s %s  size=%sB\n' "$b" "$(time_min "/tmp/_bench_$b")" "$_size"
  else
    printf '%-12s BUILD FAILED\n' "$b"
  fi
done

# ── startup floor (trivial main; isolates process/runtime-init overhead from
#    any workload above) ──────────────────────────────────────────────────────
_startup_src="/tmp/_bench_startup_src.mdk"
printf 'main : <IO> Unit\nmain = putStrLn "x"\n' >"$_startup_src"
echo "building startup floor..."
if "$MAIN" build "$_startup_src" -o /tmp/_bench_startup >/dev/null 2>&1; then
  /tmp/_bench_startup >/dev/null 2>&1 # warm
  _size="$(wc -c </tmp/_bench_startup | tr -d ' ')"
  printf '%-12s %s  size=%sB\n' "startup" "$(time_min /tmp/_bench_startup)" "$_size"
else
  printf '%-12s BUILD FAILED\n' "startup"
fi

# ── C sanity ceiling (fib/bintrees, no GC/runtime, -O2) ──────────────────────
# test/bench_fixtures/c/{fib,bintrees}.c are hand-written equivalents of the
# same two fixtures (same recursion, same input, malloc/free instead of Boehm
# GC for bintrees). Not a fair like-for-like (no GC, no boxing, no dispatch)
# — an upper bound, not a target: see compiler/PERF-RUNTIME.md's C sanity
# paragraph for the flags and the caveat.
for cb in fib bintrees; do
  csrc="test/bench_fixtures/c/$cb.c"
  [ -f "$csrc" ] || continue
  if clang -O2 -o "/tmp/_bench_c_$cb" "$csrc" >/dev/null 2>&1; then
    "/tmp/_bench_c_$cb" >/dev/null 2>&1 # warm
    printf '%-12s %s  (C sanity ceiling)\n' "${cb}_c" "$(time_min "/tmp/_bench_c_$cb")"
  else
    printf '%-12s C BUILD FAILED\n' "${cb}_c"
  fi
done

# ── selfcompile (representative heavy workload) ──────────────────────────────
if [ "$DO_SELFCOMPILE" -eq 1 ]; then
  echo "building native emitter (slow: clang of ~10 MB IR)..."
  "$MAIN" build "$EMIT_DRIVER" -o /tmp/_bench_emitter >/dev/null 2>&1 \
    || { echo "emitter build FAILED"; exit 2; }
  /tmp/_bench_emitter "$RUNTIME" "$CORE" "$EMIT_DRIVER" compiler stdlib >/dev/null 2>&1 # warm
  printf 'selfcompile  %s\n' \
    "$(time_min /tmp/_bench_emitter "$RUNTIME" "$CORE" "$EMIT_DRIVER" compiler stdlib)"

  if [ "$DO_INTERP" -eq 1 ]; then
    echo "timing OCaml interpreter self-compile (slow, ~2 min/run)..."
    printf 'selfcompile(interp)  %s\n' \
      "$(time_min "$MAIN" run "$EMIT_DRIVER" "$RUNTIME" "$CORE" "$EMIT_DRIVER" compiler stdlib)"
  fi
fi

echo
echo "done. log results in compiler/PERF-RESULTS.md"
