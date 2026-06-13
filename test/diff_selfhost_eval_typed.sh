#!/bin/sh
# Validation for the TYPED self-hosted eval path (return-position dispatch / RKey):
# type-check (resolving each return-position method occurrence to its concrete
# impl) then evaluate, and match the reference TYPED path — `medaka run <file>`
# stdout.  These programs use a USER monad (Box) whose `pure`/do-blocks can only
# be dispatched by the return type, which the untyped path gets wrong.
#
# Usage:  sh test/diff_selfhost_eval_typed.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
TYPED="$ROOT/selfhost/entries/eval_typed_main.mdk"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_typed_fixtures"
[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }
pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$MAIN" run "$f" 2>/dev/null)"
  self="$("$MAIN" run "$TYPED" "$RT" "$CORE" "$f" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$name" "$ref"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
