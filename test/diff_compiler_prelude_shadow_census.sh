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
# COST: measured 2026-08-28 on the sprint implementer's cold-built binary,
# this worktree: all 57 names x (check + run + build [+ running the binary])
# = up to 171 compiler invocations, up to 57 of them a full `clang` link,
# ran in ~90s wall-clock, single-threaded, no fan-out knob. That is cheap
# enough to run in full on every PR (no cheap-verbs-only / nightly-build
# split was needed) -- see the sprint report for the exact timing and the
# shard this was placed in.
#
# Usage:  sh test/diff_compiler_prelude_shadow_census.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
CORE="$ROOT/stdlib/core.mdk"
LEDGER="$ROOT/test/prelude_shadow_census.ledger"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -f "$CORE" ] || { echo "missing $CORE"; exit 2; }
[ -f "$LEDGER" ] || { echo "missing ledger: $LEDGER"; exit 2; }

bound() { perl -e 'alarm 60; exec @ARGV' "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; asserts=0

# Derive the standalone top-level function names from stdlib/core.mdk: an
# `export` line ALONE on its own line, immediately followed by a
# `name : type` signature line. `export interface`/`export impl`/`export
# data` all put that keyword on the SAME line as `export`, so this pattern
# only ever matches a standalone function/value declaration.
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
  if (t=="export") prevWasExport=1
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

for name in $derived_names; do
  d="$TMP/$name"
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
    pass=$((pass+1))
  else
    result='FAIL'
    fail=$((fail+1))
  fi
  asserts=$((asserts+1))
  printf '%-20s %-6s %-6s %-6s %-6s %-6s %-20s %-20s %s\n' "$name" "$check_v" "$run_v" "$build_v" "$runval" "$binval" "$verdict" "$expected" "$result"
done

echo
printf '%s: %d passed, %d failed (%d assertions)\n' "$(basename "$0")" "$pass" "$fail" "$asserts"
[ "$fail" -eq 0 ]
