#!/bin/sh
# Differential validation for the self-hosted EXHAUST stage.
#
# Oracle: dev/diagdump.exe --exhaust  (parse → Exhaust.check_guard_exhaustiveness
# on the RAW pre-desugar AST; sorted, location-stripped warning strings).
# NOTE: this covers GUARD coverage only; match/clause exhaustiveness lives in
# the typecheck-internal check_match and is validated through that stage.
#
# Two checks per fixture in test/exhaust_fixtures/ (each a deliberately-broken
# .mdk with a committed <name>.expected golden):
#   A. reference stability — diagdump output must equal the committed golden
#      (so the harness is green and self-documenting now, before any port).
#   B. if selfhost/exhaust_main.mdk exists — the self-hosted resolve's output
#      (sorted) must equal the same golden.
#
# Usage:  sh test/diff_selfhost_exhaust.sh
# Exit:   0 if every fixture passes (B skipped until the selfhost side lands).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIAG="$ROOT/_build/default/dev/diagdump.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
SELFMAIN="$ROOT/selfhost/exhaust_main.mdk"
FIXDIR="$ROOT/test/exhaust_fixtures"

[ -x "$DIAG" ] || { echo "build first: dune build --root . (missing $DIAG)"; exit 2; }

have_self=0
[ -f "$SELFMAIN" ] && have_self=1
[ "$have_self" -eq 0 ] && echo "note: selfhost/exhaust_main.mdk not yet ported — checking reference vs goldens only."

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="$(cat "${f%.mdk}.expected")"
  ref="$("$DIAG" --exhaust "$f" 2>/dev/null)"
  ok=1
  [ "$ref" = "$golden" ] || { ok=0; reason="reference drifted from golden"; }
  if [ "$ok" -eq 1 ] && [ "$have_self" -eq 1 ]; then
    self="$("$MAIN" run "$SELFMAIN" "$f" 2>/dev/null | LC_ALL=C sort)"
    [ "$self" = "$golden" ] || { ok=0; reason="selfhost differs from reference"; }
  fi
  if [ "$ok" -eq 1 ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s (%s)\n' "$name" "$reason"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]