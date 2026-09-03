#!/bin/sh
# LINT COUNT-BASELINE RATCHET (#2619).
#
# `.githooks/pre-commit` check 2b enforces test/lint_baseline.toml per STAGED
# file. That is the fast feedback, and it is also bypassable: `git commit
# --no-verify` skips every hook, and a hook is not installed at all in a fresh
# clone. This gate is the same assertion made where it cannot be skipped -- over
# the WHOLE tree, on every PR -- so an increase cannot reach main by routing
# around the hook.
#
# WHAT IT PROVES: for every file under the lint roots, its finding count for
# each baselined rule is <= its pinned row in test/lint_baseline.toml, and every
# file that HAS findings has a row at all. A count that FELL is fine and is not
# a failure here -- the baseline is a ceiling, not an equality.
#
# WHAT IT DOES NOT PROVE: that the rule itself is right, or that the pinned
# counts are ones anyone wants. They are a debt ledger, drained by fixing the
# findings and regenerating.
#
# The rule list and the source roots are READ OUT OF THE HOOK, never re-typed
# here: two consumers of one list cannot drift apart if only one of them holds
# it.
#
# Usage:  sh test/diff_compiler_lint_baseline.sh            # CHECK (the gate)
#         sh test/diff_compiler_lint_baseline.sh --write    # REGENERATE the file
#
# --write is the ONLY sanctioned way a count moves. Hand-editing a row is how a
# baseline stops describing the tree, at which point it reports green about a
# state that never existed.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
HOOK="$ROOT/.githooks/pre-commit"
BASELINE_REL="test/lint_baseline.toml"
BASELINE="$ROOT/$BASELINE_REL"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -f "$HOOK" ] || { echo "missing $HOOK"; exit 2; }

RULES="$(sed -n 's/^BASELINED_LINT_RULES="\(.*\)"$/\1/p' "$HOOK")"
ROOTS="$(sed -n 's/^LINT_ROOTS="\(.*\)"$/\1/p' "$HOOK")"
[ -n "$RULES" ] || { echo "could not read BASELINED_LINT_RULES from $HOOK"; exit 2; }
[ -n "$ROOTS" ] || { echo "could not read LINT_ROOTS from $HOOK"; exit 2; }

targets=""
for r in $ROOTS; do
  [ -d "$ROOT/$r" ] && targets="$targets $r"
done
[ -n "$targets" ] || { echo "no lint roots ($ROOTS) present under $ROOT"; exit 2; }

# The baseline keys on paths relative to the working directory, so every
# invocation of it -- this gate's and the hook's -- runs at the repo root.
cd "$ROOT" || exit 2

if [ "${1:-}" = "--write" ]; then
  # shellcheck disable=SC2086
  "$MEDAKA" lint --write-baseline="$BASELINE_REL" --only="$RULES" $targets || exit 1
  echo "-- regenerated $BASELINE_REL; review 'git diff $BASELINE_REL' before committing"
  exit 0
fi

if [ ! -f "$BASELINE" ]; then
  echo "FAIL: missing $BASELINE_REL"
  echo "  regenerate: sh test/diff_compiler_lint_baseline.sh --write"
  exit 1
fi

log="$(mktemp)"
# shellcheck disable=SC2086
"$MEDAKA" lint --baseline="$BASELINE_REL" --only="$RULES" $targets >"$log" 2>&1
status=$?

if [ "$status" -ne 0 ]; then
  echo "FAIL: lint count baseline exceeded ($RULES)"
  echo ""
  grep 'medaka lint: baseline:' "$log" || cat "$log"
  echo ""
  echo "  A baselined rule's per-file count may only FALL. Remove the new"
  echo "  finding(s), or silence an intentional one with an inline"
  echo "  '-- lint-disable-next-line <rule>' directive above the site."
  echo "  A count that legitimately moves is re-pinned by REGENERATING:"
  echo "    sh test/diff_compiler_lint_baseline.sh --write"
  rm -f "$log"
  exit 1
fi

rows="$(grep -c '^\[\[entry\]\]' "$BASELINE")"
rm -f "$log"
echo "-- lint count baseline: ok ($RULES, $rows pinned row(s), roots:$targets)"
exit 0
