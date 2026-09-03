#!/bin/sh
# LINT ENFORCEMENT FLOOR: enrolment completeness + the count-baseline ratchet,
# both asserted where `--no-verify` / a hookless clone cannot route around them
# (#2619 baseline; #2642 enrolment completeness + the max-ratchet CI twin).
#
# `.githooks/pre-commit` enforces THREE things per STAGED file: check 2
# (GATED_LINT_RULES) is a MAX RATCHET -- the whole tree is at 0 findings for
# every gated rule, so ANY new finding fails the commit; check 3
# (GATED_CROSSFILE_RULES) is the same max ratchet, project-wide; check 2b
# (BASELINED_LINT_RULES) is a per-file COUNT ratchet for a rule the tree is not
# yet clean of. All three are per-commit and all three are bypassable:
# `git commit --no-verify` skips every hook, and a hook is not installed at all
# in a fresh clone. This gate makes the whole-tree assertion where neither can
# be routed around -- on every PR:
#
#   1. ENROLMENT COMPLETENESS: every rule name compiler/tools/lint.mdk actually
#      registers is enrolled in at least one of the hook's three lists
#      (GATED_LINT_RULES, GATED_CROSSFILE_RULES, BASELINED_LINT_RULES). A rule
#      that exists in the linter but is enforced by NOTHING was previously
#      silent -- not gated, not baselined, not even warned about in CI.
#   2. THE MAX-RATCHET CI TWIN: the SAME `medaka lint --baseline` invocation
#      that checks the baselined rules ALSO covers every gated and cross-file
#      rule. Those have no row in test/lint_baseline.toml, so the baseline's
#      own invariant ("a file that HAS findings for a rule but no row is a
#      violation") makes ANY finding under a gated/cross-file rule fail here
#      too -- folded into one pass rather than a second full-tree lint run.
#
# WHAT IT PROVES: (1) a lint rule cannot exist while enforced by nothing;
# (2) no baselined-rule count exceeds its pinned row, and no gated/cross-file
# rule has ANY finding, anywhere under the lint roots. A count that FELL is
# fine and is not a failure here -- the baseline is a ceiling, not an equality.
#
# WHAT IT DOES NOT PROVE: that a rule itself is right, or that the pinned
# counts are ones anyone wants. They are a debt ledger, drained by fixing the
# findings and regenerating.
#
# The rule lists and the source roots are READ OUT OF THE HOOK, never re-typed
# here: two consumers of one list cannot drift apart if only one of them holds
# it. The CANONICAL rule-name list (for assertion 1) is read out of
# compiler/tools/lint.mdk's own `ruleName*` bindings -- the one place a new
# rule's name is declared, per the module's own header convention (append a
# `ruleNameFoo` binding + a `Rule`/`CrossFileRule` entry) -- rather than a
# blind grep for any quoted "rule-*" string, which a doc comment mentioning a
# rule name in prose would false-positive, and a programmatically-built name
# could escape.
#
# Usage:  sh test/diff_compiler_lint_baseline.sh            # CHECK (the gate)
#         sh test/diff_compiler_lint_baseline.sh --write    # REGENERATE the file
#
# --write is the ONLY sanctioned way a baselined count moves. Hand-editing a
# row is how a baseline stops describing the tree, at which point it reports
# green about a state that never existed.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
HOOK="$ROOT/.githooks/pre-commit"
LINT_SRC="$ROOT/compiler/tools/lint.mdk"
BASELINE_REL="test/lint_baseline.toml"
BASELINE="$ROOT/$BASELINE_REL"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -f "$HOOK" ] || { echo "missing $HOOK"; exit 2; }
[ -f "$LINT_SRC" ] || { echo "missing $LINT_SRC"; exit 2; }

GATED="$(sed -n 's/^GATED_LINT_RULES="\(.*\)"$/\1/p' "$HOOK")"
CROSSFILE="$(sed -n 's/^GATED_CROSSFILE_RULES="\(.*\)"$/\1/p' "$HOOK")"
RULES="$(sed -n 's/^BASELINED_LINT_RULES="\(.*\)"$/\1/p' "$HOOK")"
ROOTS="$(sed -n 's/^LINT_ROOTS="\(.*\)"$/\1/p' "$HOOK")"
[ -n "$GATED" ] || { echo "could not read GATED_LINT_RULES from $HOOK"; exit 2; }
[ -n "$CROSSFILE" ] || { echo "could not read GATED_CROSSFILE_RULES from $HOOK"; exit 2; }
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

# ── assertion 1: enrolment completeness ──────────────────────────────────────
# Every `ruleName<Foo> = "rule-..."` assignment line in lint.mdk, one per
# registered Rule/CrossFileRule. Pure text -- no build needed, so an injected
# rule name is caught even before anyone rebuilds the binary.
canon="$(sed -n 's/^ruleName[A-Za-z]* = "\(rule-[a-z-]*\)"$/\1/p' "$LINT_SRC" | sort -u)"
[ -n "$canon" ] || { echo "FAIL: could not read any ruleName* binding from $LINT_SRC"; exit 1; }

enrolled_csv="$GATED,$CROSSFILE,$RULES"
orphans=""
for n in $canon; do
  case ",$enrolled_csv," in
    *",$n,"*) ;;
    *) orphans="$orphans $n" ;;
  esac
done

if [ -n "$orphans" ]; then
  echo "FAIL: lint rule(s) registered in $LINT_SRC but enrolled in NONE of"
  echo "  GATED_LINT_RULES / GATED_CROSSFILE_RULES / BASELINED_LINT_RULES in $HOOK:"
  echo ""
  for n in $orphans; do echo "    $n"; done
  echo ""
  echo "  A lint rule enforced by nothing can regress silently forever."
  echo "  Enrol it in GATED_LINT_RULES (tree already clean of it) or"
  echo "  BASELINED_LINT_RULES (tree not clean yet), then regenerate:"
  echo "    sh test/diff_compiler_lint_baseline.sh --write"
  exit 1
fi

if [ ! -f "$BASELINE" ]; then
  echo "FAIL: missing $BASELINE_REL"
  echo "  regenerate: sh test/diff_compiler_lint_baseline.sh --write"
  exit 1
fi

# ── assertion 2: count-baseline ratchet + the max-ratchet CI twin ───────────
# One invocation, --only widened to GATED + CROSSFILE + BASELINED: a
# gated/cross-file rule has no row in the baseline at all, so any finding
# under one is "a file that HAS findings but no row" -- a violation, by the
# same invariant that already governs the baselined rules.
ALL_RULES="$GATED,$CROSSFILE,$RULES"
log="$(mktemp)"
# shellcheck disable=SC2086
"$MEDAKA" lint --baseline="$BASELINE_REL" --only="$ALL_RULES" $targets >"$log" 2>&1
status=$?

if [ "$status" -ne 0 ]; then
  echo "FAIL: lint baseline/max-ratchet violated ($ALL_RULES)"
  echo ""
  grep 'medaka lint: baseline:' "$log" || cat "$log"
  echo ""
  echo "  A baselined rule's per-file count may only FALL; a GATED or"
  echo "  CROSS-FILE rule may never fire at all. Remove the new finding(s), or"
  echo "  silence an intentional one with an inline"
  echo "  '-- lint-disable-next-line <rule>' directive above the site."
  echo "  A baselined count that legitimately moves is re-pinned by"
  echo "  REGENERATING:"
  echo "    sh test/diff_compiler_lint_baseline.sh --write"
  rm -f "$log"
  exit 1
fi

rows="$(grep -c '^\[\[entry\]\]' "$BASELINE")"
rm -f "$log"
echo "-- lint enforcement floor: ok (enrolment complete, $rows pinned baseline row(s), roots:$targets)"
exit 0
