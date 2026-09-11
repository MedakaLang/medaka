#!/bin/sh
# Cross-file lint gate: exercises BOTH multi-file features added on lint-crossfile,
# on both the human-text channel AND the `--json` envelope.
#   1. Recursive directory walk — the fixture dir has a NESTED subdir whose .mdk
#      carries a per-file finding; a top-level-only walk would miss it.
#   2. Cross-file rule tier — `rule-duplicate-body` fires on two files (one nested)
#      that share an identical non-trivial body, and stays QUIET on trivial /
#      unique bodies.
#   3. (#2701 leg 3) The `--json` envelope carries the SAME cross-file findings as
#      the text channel, each attributed to its OWN file's `diagnostics` array —
#      no new top-level key, nothing silently dropped.
# Uses the ./medaka CLI directly (cross-file orchestration lives in runLintCmd /
# runLintJsonCmd).
#
# Usage:  sh test/diff_compiler_lint_crossfile.sh
#         CAPTURE=1 sh test/diff_compiler_lint_crossfile.sh   # (re)capture goldens
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/lint_crossfile_fixtures"
GOLDEN="$FIXDIR/crossfile.expected"
JSON_GOLDEN="$FIXDIR/crossfile.json.expected"

[ -x "$MEDAKA" ] || { echo "build ./medaka first (missing $MEDAKA)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return) and normalise the
# absolute ROOT path to "ROOT/" so goldens are machine-portable.
strip_and_norm() { sed '$ s/()$//; ${/^$/d;}' | sed "s|$ROOT/|ROOT/|g"; }
norm_only() { sed "s|$ROOT/|ROOT/|g"; }

run_lint() {
  MEDAKA_ROOT="$ROOT" "$MEDAKA" lint "$FIXDIR" 2>/dev/null | strip_and_norm
}

# `--only=rule-duplicate-body` keeps the golden focused on the cross-file
# finding this gate is about, same rule the text-channel run above exercises.
run_lint_json() {
  MEDAKA_ROOT="$ROOT" "$MEDAKA" lint --json --only=rule-duplicate-body "$FIXDIR" \
    2>/dev/null | norm_only
}

if [ "${CAPTURE:-0}" = "1" ]; then
  run_lint > "$GOLDEN"
  run_lint_json > "$JSON_GOLDEN"
  printf 'captured crossfile.expected + crossfile.json.expected in %s\n' "$FIXDIR"
  exit 0
fi

[ -f "$GOLDEN" ] || { echo "golden missing — run: CAPTURE=1 sh $0"; exit 2; }
[ -f "$JSON_GOLDEN" ] || { echo "json golden missing — run: CAPTURE=1 sh $0"; exit 2; }

fails=0

golden="$(cat "$GOLDEN")"
self="$(run_lint)"
if [ "$self" = "$golden" ]; then
  printf 'ok   lint cross-file (recursive walk + duplicate-body)\n'
else
  printf 'FAIL lint cross-file (recursive walk + duplicate-body)\n'
  # POSIX-clean diff (no process substitution → runs under strict /bin/sh, so the
  # gate is not SKIP'd by run_gates.sh's `sh` invocation).
  gtmp="$(mktemp)"; stmp="$(mktemp)"
  printf '%s\n' "$golden" > "$gtmp"
  printf '%s\n' "$self" > "$stmp"
  diff "$gtmp" "$stmp" || true
  rm -f "$gtmp" "$stmp"
  fails=$((fails + 1))
fi

json_golden="$(cat "$JSON_GOLDEN")"
json_self="$(run_lint_json)"
if [ "$json_self" = "$json_golden" ]; then
  printf 'ok   lint cross-file --json (duplicate-body reaches the JSON envelope)\n'
else
  printf 'FAIL lint cross-file --json (duplicate-body reaches the JSON envelope)\n'
  gtmp="$(mktemp)"; stmp="$(mktemp)"
  printf '%s\n' "$json_golden" > "$gtmp"
  printf '%s\n' "$json_self" > "$stmp"
  diff "$gtmp" "$stmp" || true
  rm -f "$gtmp" "$stmp"
  fails=$((fails + 1))
fi

ok=$((2 - fails))
printf '\n%s ok, %s failing\n' "$ok" "$fails"
[ "$fails" -eq 0 ]
