#!/bin/bash
# Drive every battery program through: interpreter (run), native (build+exec), playground wasm.
ROOT=/root/medaka/.claude/worktrees/swirling-munching-kahn
S=/var/tmp/medaka-scratch/claude-0/-root-medaka/42371736-88ae-460b-b194-a26e487bb4d9/scratchpad
B=$S/battery
R=$S/results
mkdir -p "$R"
MODE=${1:-all}
T=${TIMEOUT:-30}
export MEDAKA_ROOT=$ROOT
for f in "$B"/*.mdk; do
  n=$(basename "$f" .mdk)
  stdin=/dev/null
  if [ "$n" = "34_stdin" ]; then stdin="$S/stdin.txt"; fi
  if [ "$MODE" = all ] || [ "$MODE" = run ]; then
    s=$(date +%s.%N)
    timeout "$T" "$ROOT/medaka" run "$f" <"$stdin" >"$R/$n.run.out" 2>"$R/$n.run.err"; ec=$?
    e=$(date +%s.%N)
    printf '%s\trun\t%s\t%.2f\n' "$n" "$ec" "$(echo "$e - $s" | bc)" >>"$R/summary.tsv"
  fi
  if [ "$MODE" = all ] || [ "$MODE" = build ]; then
    s=$(date +%s.%N)
    timeout 120 "$ROOT/medaka" build "$f" -o "$R/$n.bin" >"$R/$n.build.out" 2>"$R/$n.build.err"; bec=$?
    if [ $bec -eq 0 ] && [ -x "$R/$n.bin" ]; then
      timeout "$T" "$R/$n.bin" <"$stdin" >"$R/$n.native.out" 2>"$R/$n.native.err"; ec=$?
    else
      ec="B$bec"
    fi
    e=$(date +%s.%N)
    printf '%s\tnative\t%s\t%.2f\n' "$n" "$ec" "$(echo "$e - $s" | bc)" >>"$R/summary.tsv"
  fi
  if { [ "$MODE" = all ] || [ "$MODE" = wasm ]; } && [ -f "$ROOT/playground/dist/playground.wasm" ]; then
    s=$(date +%s.%N)
    timeout 120 node "$S/pg_compile.mjs" "$ROOT" "$f" >"$R/$n.wat" 2>"$R/$n.wasm.cerr"; cec=$?
    if [ $cec -eq 0 ]; then
      if wasm-tools parse "$R/$n.wat" -o "$R/$n.wasm" >"$R/$n.wasm.perr" 2>&1; then
        timeout "$T" node "$ROOT/test/wasm/run.js" "$R/$n.wasm" <"$stdin" >"$R/$n.wasm.out" 2>"$R/$n.wasm.err"; ec=$?
      else
        ec=P
      fi
    else
      ec="C$cec"
    fi
    e=$(date +%s.%N)
    printf '%s\twasm\t%s\t%.2f\n' "$n" "$ec" "$(echo "$e - $s" | bc)" >>"$R/summary.tsv"
  fi
done
echo done
