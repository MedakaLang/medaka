#!/bin/sh
# test/t4_census.sh — per-site W-OPEN-GOAL-COMMITTED (T4) census, run via
# `make t4-census`. Not a gate: this is a reporting tool. It asserts nothing
# and always exits 0.
#
# WHY THIS EXISTS (#2665 item 1, arc #1122 ruling 2, tracking #3027). T4 is
# the §6.2 open-goal-commitment warning: `pickMostSpecificEntry`'s
# no-unique-minimum arm commits to the first-declared candidate at a goal
# that is still open (an unbound metavariable nothing in the program
# determines), and the warning says so out loud
# (`compiler/types/typecheck.mdk`, `reportOverlapForIface` /
# `openGoalCommitWarnCode`). Two mechanisms used to hide the true population:
#
#   1. `pushMatchWarningOnceAt` deduped by MESSAGE TEXT, so two distinct
#      commitment SITES that happen to produce the same message collapsed to
#      one warning. Re-keyed to `(code, loc, msg)` in this same change.
#   2. The human `medaka check` arm prints only `filter isDiagError diags`,
#      so a file that ALSO carries a type error drops every warning,
#      T4-committed or not. This census reads `check --json`, never the
#      human arm's stdout, so it is not blind to that population.
#
# WHAT THIS COUNTS. Per root (`test/`, `stdlib/`), every tracked `.mdk` file
# is run through `./medaka check --json`, and every `W-OPEN-GOAL-COMMITTED`
# diagnostic entry in the resulting envelope is a row: one row per SITE
# (file:line:col), not per distinct message. `test/t4_census_fixtures/`
# itself (this census's own positive-control corpus -- proves the instrument
# fires at all) is excluded from the wild-population walk and reported
# separately: folding it into `total` would make an empty census
# structurally unreachable, defeating contract §7 criterion 2's "an empty
# census is a valid answer."
#
# Needs a built ./medaka and jq. Portable POSIX sh.
#
# Usage:  sh test/t4_census.sh
# Output: a per-site table (file:line:col, code, message) plus a per-root and
#         total count. Always exits 0 -- this is a report, not a pass/fail
#         check.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

MEDAKA="$ROOT/medaka"
CODE="W-OPEN-GOAL-COMMITTED"

if [ ! -x "$MEDAKA" ]; then
  echo "t4_census: no built ./medaka at $MEDAKA -- run 'make medaka' first" >&2
  exit 1
fi

echo "== W-OPEN-GOAL-COMMITTED (T4) per-site census (#2665 item 1, #3027) =="
echo ""

total=0
# Split on newline only -- some paths could in principle contain spaces.
IFS='
'
for r in test stdlib; do
  [ -d "$ROOT/$r" ] || continue
  files="$(git ls-files -- "$r/*.mdk" | grep -v '^test/t4_census_fixtures/')"
  n_files=0
  echo "-- root: $r --"
  raw="$(mktemp)"
  for f in $files; do
    [ -n "$f" ] || continue
    n_files=$((n_files + 1))
    out="$("$MEDAKA" check --json "$ROOT/$f" 2>/dev/null)"
    [ -n "$out" ] || continue
    rows="$(printf '%s' "$out" | jq -r --arg code "$CODE" '
      .files[]? | .file as $file | .diagnostics[]?
        | select(.code == $code)
        | "\($file):\(.range.start.line + 1):\(.range.start.character + 1)\t\(.code)\t\(.message)"
    ' 2>/dev/null)"
    [ -n "$rows" ] || continue
    printf '%s\n' "$rows" >> "$raw"
  done
  # A site inside an IMPORTED module gets one JSON entry per entry-point that
  # reaches it -- reported once when it's swept as its own entry (path
  # spelled absolute, "$ROOT/$f") and again when reached via an importer
  # (path spelled relative-to-cwd by the envelope, which is $ROOT since this
  # script cd's there). Same site, two path spellings for one location:
  # normalize both to $ROOT-relative and de-dup before counting.
  norm="$(sed "s|^$ROOT/||" "$raw" | sort -u)"
  rm -f "$raw"
  n_hits=0
  if [ -n "$norm" ]; then
    printf '%s\n' "$norm"
    n_hits="$(printf '%s\n' "$norm" | grep -c .)"
  fi
  echo "  root $r: $n_hits site(s) across $n_files file(s)"
  echo ""
  total=$((total + n_hits))
done

echo "total $CODE sites: $total (wild population only, excludes the control corpus below)"
echo ""

echo "-- control: test/t4_census_fixtures (positive-control, NOT in total) --"
control_hits=0
control_files="$(git ls-files -- 'test/t4_census_fixtures/*.mdk')"
for f in $control_files; do
  [ -n "$f" ] || continue
  out="$("$MEDAKA" check --json "$ROOT/$f" 2>/dev/null)"
  [ -n "$out" ] || continue
  rows="$(printf '%s' "$out" | jq -r --arg code "$CODE" '
    .files[]? | .file as $file | .diagnostics[]?
      | select(.code == $code)
      | "\($file):\(.range.start.line + 1):\(.range.start.character + 1)\t\(.code)\t\(.message)"
  ' 2>/dev/null)"
  [ -n "$rows" ] || continue
  printf '%s\n' "$rows"
  hits="$(printf '%s\n' "$rows" | grep -c .)"
  control_hits=$((control_hits + hits))
done
echo "  control corpus: $control_hits site(s) (expected > 0 -- proves the instrument fires)"
echo ""

echo "(report only -- exits 0 by design. Re-key that stopped one undercount"
echo " mechanism: compiler/types/typecheck.mdk pushMatchWarningOnceAt. The"
echo " other -- check --json vs. the human arm on an error-bearing file --"
echo " is read around, not fixed, by using --json here.)"
exit 0
