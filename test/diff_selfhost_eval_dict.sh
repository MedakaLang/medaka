#!/bin/sh
# Validation for the self-hosted DICT-PASSING eval path: programs whose
# `=>`-constrained functions use a return-position method (empty/minBound/…) at
# the constraint variable's type — which has no discriminating argument, so plain
# arg-tag / RKey dispatch cannot resolve it.  The Monoid (etc.) dictionary the
# caller supplies must be threaded into the function body.
#
# Reference: the committed test/eval_dict_fixtures/<name>.eval.golden, captured
# (test/capture_goldens.sh) from the reference `main.exe run <file>` (which
# dict-passes the whole program) while OCaml was trusted.
#
# DOCUMENTED BASELINE: this gate is "22 ok, 3 failing" (+batch "7 ok, 18 failing")
# and that IS the correct/expected state — do NOT treat the 3 (+18) as a regression.
# The failing fixtures are `method_constraint_foldmap_list`, `method_constraint_foldmap_string`,
# and `method_constraint_user_iface`: a pre-existing **method-level-constraint gap** —
# `foldMap : Monoid m => (a -> m) -> t a -> m` (a constraint on a METHOD's own tyvar,
# distinct from the function-level `=>` this gate's name describes). It is the residual
# #55-adjacent gap; verified failing-identically on baseline across the 2026-06-14
# dispatch work (driver collapse, #21, the argStampEnabled unification, #44) — none of
# which touched it. A real fix belongs in the method-level-constraint dict threading.
# Until then, 22/3 (+ batch 7/18) is GREEN.
# Self-host (OCaml-free, REROOT-PLAN.md Phase 2): the pre-compiled native binary
# test/bin/eval_dict_main (built by test/build_oracles.sh) runs the self-hosted dict
# elaboration + eval; its stdout must match the golden.
#
# Usage:  sh test/diff_selfhost_eval_dict.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DICT="$ROOT/test/bin/eval_dict_main"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_dict_fixtures"
[ -x "$DICT" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $DICT)"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }  # drop native runtime's trailing Unit auto-print
pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$("$DICT" "$RT" "$CORE" "$f" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$name" "$ref"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
