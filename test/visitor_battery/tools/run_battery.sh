#!/bin/bash
# run_battery.sh — drive every test/visitor_battery/*.mdk program through up to
# three engines and record what each one did.
#
#   run     ./medaka run (the tree-walking interpreter)
#   native  ./medaka build, then execute the binary
#   wasm    the playground compiler (playground/dist/playground.wasm, built by
#           playground/build_playground_wasm.sh) through playground/compile.mjs
#           in node, assembled with wasm-tools, run with test/wasm/run.js
#
# Usage:  bash test/visitor_battery/tools/run_battery.sh [all|run|native|wasm] [OUT_DIR]
#         TIMEOUT=<seconds> caps each program's run (default 30).
# Output: OUT_DIR/summary.tsv (program, arm, exit, seconds) plus per-program
#         stdout/stderr/diagnostics; read it with tools/show_results.py.
#         OUT_DIR defaults to test/visitor_battery/results (gitignored).
#
# This is a TOOL, not a gate: it records, it does not judge. The exit column is
# the program's own: 0 ran, 1 a diagnostic or runtime error, 124 timeout, B1 the
# build refused, C1 the playground compiler refused, P the WAT did not assemble.
# The browser arm (the live page in Chrome) is tools/browser_battery.mjs.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
B="$HERE/.."
MODE=${1:-all}
R=${2:-$B/results}
T=${TIMEOUT:-30}
mkdir -p "$R"
: > "$R/summary.tsv"
printf 'hello from stdin\n' > "$R/stdin.txt"
export MEDAKA_ROOT="$ROOT"
now() { date +%s.%N; }
elapsed() { echo "$2 - $1" | bc; }
for f in "$B"/*.mdk; do
  n=$(basename "$f" .mdk)
  stdin="$R/stdin.txt"
  if [ "$MODE" = all ] || [ "$MODE" = run ]; then
    s=$(now)
    timeout "$T" "$ROOT/medaka" run "$f" <"$stdin" >"$R/$n.run.out" 2>"$R/$n.run.err"; ec=$?
    printf '%s\trun\t%s\t%.2f\n' "$n" "$ec" "$(elapsed "$s" "$(now)")" >>"$R/summary.tsv"
  fi
  if [ "$MODE" = all ] || [ "$MODE" = native ]; then
    s=$(now)
    timeout 120 "$ROOT/medaka" build "$f" -o "$R/$n.bin" >"$R/$n.build.out" 2>"$R/$n.build.err"; bec=$?
    if [ $bec -eq 0 ] && [ -x "$R/$n.bin" ]; then
      timeout "$T" "$R/$n.bin" <"$stdin" >"$R/$n.native.out" 2>"$R/$n.native.err"; ec=$?
    else
      ec="B$bec"
    fi
    printf '%s\tnative\t%s\t%.2f\n' "$n" "$ec" "$(elapsed "$s" "$(now)")" >>"$R/summary.tsv"
  fi
  if { [ "$MODE" = all ] || [ "$MODE" = wasm ]; } && [ -f "$ROOT/playground/dist/playground.wasm" ]; then
    s=$(now)
    timeout 120 node "$HERE/pg_compile.mjs" "$f" >"$R/$n.wat" 2>"$R/$n.wasm.cerr"; cec=$?
    if [ $cec -eq 0 ]; then
      if wasm-tools parse "$R/$n.wat" -o "$R/$n.wasm" >"$R/$n.wasm.perr" 2>&1; then
        timeout "$T" node "$ROOT/test/wasm/run.js" "$R/$n.wasm" <"$stdin" >"$R/$n.wasm.out" 2>"$R/$n.wasm.err"; ec=$?
      else
        ec=P
      fi
    else
      ec="C$cec"
    fi
    printf '%s\twasm\t%s\t%.2f\n' "$n" "$ec" "$(elapsed "$s" "$(now)")" >>"$R/summary.tsv"
  fi
done
echo "wrote $R/summary.tsv"
