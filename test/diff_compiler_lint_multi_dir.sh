#!/bin/sh
# Regression gate for the multi-DIRECTORY-target resolveLintTargets bug: passing
# MULTIPLE directory args used to be returned as-is (no expansion), so neither
# directory's .mdk files were discovered and the cross-file rule tier silently
# saw nothing. Invokes the CLI with TWO directory targets and diffs output.
# Uses the ./medaka CLI directly (multi-file orchestration lives in runLintCmd,
# not the lint_main oracle binary).
#
# Usage:  sh test/diff_compiler_lint_multi_dir.sh
#         CAPTURE=1 sh test/diff_compiler_lint_multi_dir.sh   # (re)capture golden
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/lint_multi_dir_fixtures"
GOLDEN="$FIXDIR/multi_dir.expected"

[ -x "$MEDAKA" ] || { echo "build ./medaka first (missing $MEDAKA)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
# Also normalise absolute ROOT path to "ROOT/" so goldens are machine-portable.
strip_and_norm() { sed '$ s/()$//; ${/^$/d;}' | sed "s|$ROOT/|ROOT/|g"; }

run_lint() {
  MEDAKA_ROOT="$ROOT" "$MEDAKA" lint "$FIXDIR/dirA" "$FIXDIR/dirB" 2>/dev/null | strip_and_norm
}

if [ "${CAPTURE:-0}" = "1" ]; then
  run_lint > "$GOLDEN"
  printf 'captured multi_dir.expected in %s\n' "$FIXDIR"
  exit 0
fi

[ -f "$GOLDEN" ] || { echo "golden missing — run: CAPTURE=1 sh $0"; exit 2; }

golden="$(cat "$GOLDEN")"
self="$(run_lint)"
if [ "$self" = "$golden" ]; then
  printf 'ok   lint multi-directory-target (two dir args, cross-file dup)\n'
  multi_dir_ok=0
else
  printf 'FAIL lint multi-directory-target (two dir args, cross-file dup)\n'
  gtmp="$(mktemp)"; stmp="$(mktemp)"
  printf '%s\n' "$golden" > "$gtmp"
  printf '%s\n' "$self" > "$stmp"
  diff "$gtmp" "$stmp" || true
  rm -f "$gtmp" "$stmp"
  multi_dir_ok=1
fi

# ── #1173 regressions: resolveLintTargets / flag parsing must fail LOUDLY ───
# rather than silently report clean. Same file since both bugs live in the
# argv-to-target path this gate already exercises directly against the CLI.
pass=0; fail=0

name="1173/nonexistent-path"
out="$("$MEDAKA" lint --json "$FIXDIR/does-not-exist-1173.mdk" 2>&1)"; status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'do not exist'; then
  pass=$((pass+1)); printf 'ok   %s\n' "$name"
else
  fail=$((fail+1)); printf 'FAIL %s (expected exit 1 + "do not exist", got exit=%s out=%s)\n' "$name" "$status" "$out"
fi

# #1173 originally REJECTED the space form outright, because `lintTargets` left
# the rule name behind as an ordinary lint TARGET with the flag applied to
# nothing.  CLI-CONFORMANCE.md C1 supersedes that ruling: both spellings are
# accepted by every value-taking flag of every verb.  So the assertion becomes
# the STRONGER one -- the space form must be HONOURED, not merely un-rejected.
# #1173's actual harm (the silent drop) is what this now pins: `rule-dead-code`
# fires on dirA/one.mdk, so promoting it must flip the exit code 0 -> 1, and it
# must do so IDENTICALLY in both spellings.  A space form that was accepted and
# then dropped would exit 0 here and fail this check.
probe="$FIXDIR/dirA"

name="C1/deny-space-form-honoured"
eq_out="$("$MEDAKA" lint --deny=rule-dead-code "$probe" 2>&1)"; eq_status=$?
sp_out="$("$MEDAKA" lint --deny rule-dead-code "$probe" 2>&1)"; sp_status=$?
if [ "$eq_status" -eq 1 ] && [ "$sp_status" -eq 1 ] && [ "$eq_out" = "$sp_out" ]; then
  pass=$((pass+1)); printf 'ok   %s\n' "$name"
else
  fail=$((fail+1))
  printf 'FAIL %s (both spellings must promote to error and agree; = form exit=%s, space form exit=%s)\n' \
    "$name" "$eq_status" "$sp_status"
  printf '  = form: %s\n  space : %s\n' "$eq_out" "$sp_out"
fi

name="C1/only-space-form-not-a-target"
# The rule name must never be read as a PATH: `--only <rule>` over a dir whose
# only finding is rule-dead-code keeps that finding (it is not filtered away by
# a bogus rule set) and reports no missing target.
out="$("$MEDAKA" lint --only rule-dead-code "$probe" 2>&1)"; status=$?
if [ "$status" -eq 0 ] \
  && ! printf '%s' "$out" | grep -q 'do not exist' \
  && printf '%s' "$out" | grep -q 'rule-dead-code'; then
  pass=$((pass+1)); printf 'ok   %s\n' "$name"
else
  fail=$((fail+1)); printf 'FAIL %s (exit=%s out=%s)\n' "$name" "$status" "$out"
fi

name="1173/deny-equals-form-still-works"
out="$("$MEDAKA" lint --json --deny=rule-match-on-param "$probe" 2>&1)"; status=$?
if [ "$status" -eq 0 ] || [ "$status" -eq 1 ]; then
  # exit code depends on whether the rule fires; what matters is it did NOT hit
  # the "require a value" rejection and did NOT treat the rule name as a path.
  if printf '%s' "$out" | grep -q 'require a value'; then
    fail=$((fail+1)); printf 'FAIL %s (equals form wrongly rejected): %s\n' "$name" "$out"
  elif printf '%s' "$out" | grep -q 'rule-match-on-param.*diagnostics'; then
    fail=$((fail+1)); printf 'FAIL %s (rule name treated as a file target): %s\n' "$name" "$out"
  else
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  fi
else
  fail=$((fail+1)); printf 'FAIL %s (unexpected exit %s): %s\n' "$name" "$status" "$out"
fi

printf '\n%d ok, %d failing (plus multi-dir: %s)\n' "$pass" "$fail" "$([ "$multi_dir_ok" -eq 0 ] && echo ok || echo FAIL)"
[ "$fail" -eq 0 ] && [ "$multi_dir_ok" -eq 0 ]
