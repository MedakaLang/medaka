#!/bin/sh
# PRELUDE-SHADOW BUILD-AGREEMENT CENSUS (#2153, sprint prelude-shadow-build-
# agreement, slice S-shadow-census-gate).
#
# #2153 claims 23-of-57 top-level stdlib/core.mdk standalone functions panic
# at `build` when shadowed by a same-named interface method, while `check`
# and `run` both accept -- but the claim was PROSE ONLY: no script survived
# the previous sprint that produced it (`find
# /var/tmp/medaka-sprints/prelude-shadow-agreement -name '*.sh'` -> empty).
# This gate is that instrument: for EVERY standalone name stdlib/core.mdk
# currently exports, it drives one probe --
#
#   interface Ifc c where
#     <name> : c -> Int
#   impl Ifc Int where
#     <name> v = v
#   main = println (<name> 1)
#
# -- through `check`, `run`, and `build` (executing the built binary too),
# same shape as test/diff_compiler_shadow_semantics.sh and, one level further
# back, test/diff_compiler_run_check_agreement.sh: exit-code verdict AND,
# wherever a verb's stdout is meaningful, the PRINTED VALUE -- an exit-code-
# only gate cannot see a P0-20-shaped bug (build exits 0 printing the WRONG
# number).
#
# test/prelude_shadow_census.ledger is the RATCHET this gate enforces: each
# name's current measured verdict (PASS / FAIL_BUILD / SPECIAL_RUN_REJECT,
# see the ledger's own header) is pinned there, derived from the ACTUAL
# binary, never transcribed from the issue. A name moving off its pinned
# verdict in EITHER direction fails this gate -- a PASS regressing is a new
# defect; a FAIL_BUILD flipping to PASS is slices 2-5's own job and must be
# landed by RE-PINNING this ledger in that slice's diff, on purpose, not by
# this gate silently absorbing the fix.
#
# Names are derived from stdlib/core.mdk at RUN TIME, never hand-copied --
# the coverage self-audit below fails loudly the moment a name here vanishes
# from core.mdk, or a core.mdk standalone has no ledger row (a new prelude
# function shipping with no census coverage).
#
# COST: the names fan out over xargs -P (PRELUDE_SHADOW_JOBS, default
# min(4, NCPU/2), at least 1). Each name's probe runs in its own directory;
# per-name results are written to $TMP and replayed in derivation order, so
# the printed table and the counters match the old serial loop.
#
# Usage:  sh test/diff_compiler_prelude_shadow_census.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
CORE="$ROOT/stdlib/core.mdk"
LEDGER="$ROOT/test/prelude_shadow_census.ledger"
SELF="$ROOT/test/diff_compiler_prelude_shadow_census.sh"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -f "$CORE" ] || { echo "missing $CORE"; exit 2; }
[ -f "$LEDGER" ] || { echo "missing ledger: $LEDGER"; exit 2; }

bound() { perl -e 'alarm 60; exec @ARGV or die qq(exec: $!)' "$@"; }

# worker_one N — the per-name probe for line N of $TMP/names. Writes the table row to
# $TMP/r.N.line and the verdict (PASS|FAIL) to $TMP/r.N.res. Runs under xargs -P.
worker_one() {
  n="$1"
  name="$(sed -n "${n}p" "$TMP/names")"
  d="$TMP/d.$n"
  mkdir -p "$d"
  cat > "$d/main.mdk" <<EOF
interface Ifc c where
  $name : c -> Int

impl Ifc Int where
  $name v = v

main = println ($name 1)
EOF

  bound "$MEDAKA" check "$d/main.mdk" >/dev/null 2>"$d/chk.err"
  check_code=$?
  bound "$MEDAKA" run "$d/main.mdk" >"$d/run.out" 2>"$d/run.err"
  run_code=$?
  bound "$MEDAKA" build "$d/main.mdk" -o "$d/bin" >"$d/build.err" 2>&1
  build_code=$?

  if [ "$check_code" -eq 0 ]; then check_v='ACCEPT'; else check_v='REJECT'; fi
  if [ "$run_code" -eq 0 ]; then run_v='ACCEPT'; else run_v='REJECT'; fi

  runval='-'
  [ "$run_v" = 'ACCEPT' ] && runval="$(tr -d '[:space:]' < "$d/run.out")"

  binval='-'
  if [ "$build_code" -eq 0 ] && [ -x "$d/bin" ]; then
    build_v='ACCEPT'
    bound "$d/bin" >"$d/bin.out" 2>"$d/bin.err"
    binval="$(tr -d '[:space:]' < "$d/bin.out")"
  else
    build_v='REJECT'
  fi

  if [ "$check_v" = 'ACCEPT' ] && [ "$run_v" = 'ACCEPT' ] && [ "$build_v" = 'ACCEPT' ] \
     && [ "$runval" = '1' ] && [ "$binval" = '1' ]; then
    verdict='PASS'
  elif [ "$check_v" = 'ACCEPT' ] && [ "$run_v" = 'ACCEPT' ] && [ "$build_v" = 'REJECT' ]; then
    verdict='FAIL_BUILD'
  elif [ "$check_v" = 'ACCEPT' ] && [ "$run_v" = 'REJECT' ] && [ "$build_v" = 'ACCEPT' ] && [ "$binval" = '1' ]; then
    verdict='SPECIAL_RUN_REJECT'
  else
    verdict="UNKNOWN:$check_v/$run_v/$build_v/run=$runval/bin=$binval"
  fi

  expected="$(awk -F'|' -v n="$name" 'NF>1 && $1==n{print $2; exit}' "$LEDGER")"
  [ -z "$expected" ] && expected='(no ledger row)'

  if [ "$verdict" = "$expected" ]; then
    result='PASS'
  else
    result='FAIL'
  fi
  printf '%-20s %-6s %-6s %-6s %-6s %-6s %-20s %-20s %s\n' "$name" "$check_v" "$run_v" "$build_v" "$runval" "$binval" "$verdict" "$expected" "$result" > "$TMP/r.$n.line"
  printf '%s\n' "$result" > "$TMP/r.$n.res"
}

# --worker mode: xargs re-invokes this script as `sh "$SELF" --worker "$TMP" <n>`.
if [ "${1:-}" = "--worker" ]; then
  TMP="$2"
  worker_one "$3"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; asserts=0

# Derive the standalone top-level function names from stdlib/core.mdk, in
# either of two shapes: (1) an `export` line ALONE on its own line,
# immediately followed by a `name : type` signature line, or (2) the
# single-line form `export name : type`. `export interface`/`export impl`/
# `export data` all put that keyword directly followed by something other
# than `name :` (an interface/impl/type name with no colon right after it),
# so neither pattern ever matches those. #2187: the coverage self-audit
# below reuses this SAME derivation, so a name only one of the two shapes
# could reach still had to be recognized HERE, not patched over downstream.
names="$(awk '
{
  if (prevWasExport==1) {
    line=$0
    if (line ~ /^[a-zA-Z_][A-Za-z0-9_'"'"']*[ \t]*:/) {
      match(line, /^[a-zA-Z_][A-Za-z0-9_'"'"']*/)
      print substr(line, RSTART, RLENGTH)
    }
    prevWasExport=0
  }
  t=$0; gsub(/^[ \t]+|[ \t]+$/,"",t)
  if (t=="export") { prevWasExport=1; next }
  if (t ~ /^export[ \t]+[a-zA-Z_][A-Za-z0-9_'"'"']*[ \t]*:/) {
    rest=t; sub(/^export[ \t]+/,"",rest)
    match(rest, /^[a-zA-Z_][A-Za-z0-9_'"'"']*/)
    print substr(rest, RSTART, RLENGTH)
  }
}' "$CORE")"

# --- Coverage self-audit (both directions), same shape as
# diff_compiler_shadow_semantics.sh's fixture-vs-TABLE audit. ---
ledger_names="$(awk -F'|' 'NF>1 && $1 !~ /^#/{print $1}' "$LEDGER" | sort -u)"
derived_names="$(printf '%s\n' "$names" | sort -u)"

missing_from_ledger=0
for n in $derived_names; do
  hit=0
  for l in $ledger_names; do [ "$n" = "$l" ] && hit=1 && break; done
  if [ "$hit" -eq 0 ]; then
    missing_from_ledger=$((missing_from_ledger+1))
    fail=$((fail+1))
    printf 'FAIL coverage: %s is a stdlib/core.mdk standalone but has NO row in %s\n' "$n" "$LEDGER"
  fi
done
asserts=$((asserts+1))
[ "$missing_from_ledger" -eq 0 ] && { pass=$((pass+1)); printf 'ok   coverage: every stdlib/core.mdk standalone has a ledger row\n'; }

stale_ledger=0
for l in $ledger_names; do
  hit=0
  for n in $derived_names; do [ "$n" = "$l" ] && hit=1 && break; done
  if [ "$hit" -eq 0 ]; then
    stale_ledger=$((stale_ledger+1))
    fail=$((fail+1))
    printf 'FAIL coverage: ledger row %s names no current stdlib/core.mdk standalone (stale row)\n' "$l"
  fi
done
asserts=$((asserts+1))
[ "$stale_ledger" -eq 0 ] && { pass=$((pass+1)); printf 'ok   coverage: no stale ledger rows\n'; }
echo

printf '%-20s %-6s %-6s %-6s %-6s %-6s %-20s %-20s %s\n' 'name' 'check' 'run' 'build' 'runv' 'binv' 'verdict' 'expected' 'result'
printf '%-20s %-6s %-6s %-6s %-6s %-6s %-20s %-20s %s\n' '--------------------' '------' '------' '------' '------' '------' '--------------------' '--------------------' '------'

# Fan out one worker per name. Names are numbered in derivation order; the replay
# below prints rows in exactly that order.
: > "$TMP/names"
for name in $derived_names; do printf '%s\n' "$name" >> "$TMP/names"; done
N="$(wc -l < "$TMP/names" | tr -d ' ')"

NCPU="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
JOBS=$(( NCPU / 2 ))
[ "$JOBS" -gt 4 ] && JOBS=4
[ "$JOBS" -lt 1 ] && JOBS=1
JOBS="${PRELUDE_SHADOW_JOBS:-$JOBS}"

if [ "$N" -gt 0 ]; then
  i=1
  while [ "$i" -le "$N" ]; do echo "$i"; i=$((i + 1)); done \
    | xargs -P "$JOBS" -n 1 sh "$SELF" --worker "$TMP"
fi

i=1
while [ "$i" -le "$N" ]; do
  if [ -s "$TMP/r.$i.line" ]; then
    cat "$TMP/r.$i.line"
  else
    printf '%s: no result (worker produced none)\n' "$(sed -n "${i}p" "$TMP/names")"
  fi
  asserts=$((asserts+1))
  if [ "$(cat "$TMP/r.$i.res" 2>/dev/null)" = 'PASS' ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
  fi
  i=$((i + 1))
done

echo
printf '%s: %d passed, %d failed (%d assertions)\n' "$(basename "$0")" "$pass" "$fail" "$asserts"
[ "$fail" -eq 0 ]
