#!/bin/sh
# LINT ENFORCEMENT FLOOR: the count-baseline ratchet and the max-ratchet CI twin,
# both asserted where `--no-verify` / a hookless clone cannot route around them
# (#2619 baseline; #2642 the max-ratchet twin; #2528 the shared roots).
#
# `.githooks/pre-commit` enforces, per STAGED file, a MAX RATCHET for every gated
# rule (any NEW finding fails the commit), a per-file COUNT ratchet for every
# baselined rule (the tree is not yet clean of it), and a project-wide scan for
# the gated rules that compare a body against other files. All three are
# per-commit and all three are bypassable: `git commit --no-verify` skips every
# hook, and a hook is not installed at all in a fresh clone. This gate makes the
# whole-tree assertion where neither can be routed around -- on every PR:
#
#   1. THE MAX-RATCHET CI TWIN: ONE `medaka lint --baseline` invocation checks the
#      baselined rules AND every gated per-file rule, including the same-file
#      arm of a rule that also has a cross-file tier (it shares the rule's name,
#      so naming the rule selects both). Gated rules have no row in
#      test/lint_baseline.toml, so the baseline's own invariant ("a file that HAS
#      findings for a rule but no row is a violation") makes ANY finding under a
#      gated rule fail here too -- folded into one pass rather than a second
#      full-tree lint run. It covers the SAME roots the hook can lint: every
#      top-level directory holding a tracked .mdk outside test/.
#   2. THE CROSS-FILE MAX RATCHET: a separate `--deny` pass over CROSS_ROOTS for
#      the gated rules that have a cross-file tier. It is separate because it has
#      to be: `--baseline` promotes PER-FILE findings, and a cross-file rule's
#      findings come from a whole-target-set tier the baseline never sees (#2861).
#
# The rule lists come from the binary (`medaka lint --list-rules --names`), never
# from this file or the hook: a rule cannot exist without registry metadata, so
# "every rule is enforced by something" holds by construction, and a new rule is
# enforced the moment it is registered. The hook derives the same lists the same
# way, so the two cannot drift.
#
# WHAT IT PROVES: no baselined-rule count exceeds its pinned row, no gated
# per-file rule has ANY finding anywhere under the lint roots, and no cross-file
# rule has ANY finding under CROSS_ROOTS. A count that FELL is fine -- the
# baseline is a ceiling, not an equality.
#
# WHAT IT DOES NOT PROVE, and the reason `make dup-census` exists: a cross-file
# rule reporting zero is not the same as the tree having no duplicates. The zero
# can be manufactured entirely by inline suppressions. The count those
# suppressions hide is reported by test/dup_suppression_census.sh, which this
# gate deliberately does NOT assert on -- it is a debt ledger, not a floor. Nor
# does it prove a rule is right, or that the pinned counts are ones anyone wants.
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
BASELINE_REL="test/lint_baseline.toml"
BASELINE="$ROOT/$BASELINE_REL"
# Narrower than the per-file roots on purpose: the other projects carry cross-file
# findings that are not yet drained (#2881). Keep in step with the hook.
CROSS_ROOTS="compiler stdlib sqlite"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

# The baseline keys on paths relative to the working directory, so every
# invocation of it -- this gate's and the hook's -- runs at the repo root.
cd "$ROOT" || exit 2

rule_names() { "$MEDAKA" lint --list-rules --names "$@" 2>/dev/null; }
. "$ROOT/test/lint_rule_lists.sh"

# The derivation must survive an empty baselined set (the last baselined rule
# drained) and an empty cross set: no dangling comma in --only.  Checked against
# scratch registry listings, since the real registry has both kinds today.
derive_selftest() {
  (
    rule_names() {
      case "$*" in
        "--ratchet=gated --tier=cross") printf '%s\n' $FAKE_CROSS ;;
        "--ratchet=baselined") printf '%s\n' $FAKE_BASELINED ;;
        "--ratchet=gated") printf '%s\n' $FAKE_GATED ;;
      esac
    }
    FAKE_GATED="rule-a rule-dup rule-b"
    FAKE_CROSS="rule-dup"
    FAKE_BASELINED=""
    derive_lint_rules
    [ "$LINT_ONLY" = "rule-a,rule-b,rule-dup" ] || { echo "empty baselined: --only=$LINT_ONLY"; exit 1; }
    FAKE_BASELINED="rule-z"
    derive_lint_rules
    [ "$LINT_ONLY" = "rule-a,rule-b,rule-dup,rule-z" ] || { echo "baselined: --only=$LINT_ONLY"; exit 1; }
    FAKE_CROSS=""
    FAKE_GATED="rule-a"
    FAKE_BASELINED=""
    derive_lint_rules
    [ "$LINT_ONLY" = "rule-a" ] || { echo "no cross, no baselined: --only=$LINT_ONLY"; exit 1; }
  )
}
derive_selftest || { echo "FAIL: lint rule-list derivation (test/lint_rule_lists.sh)"; exit 1; }

derive_lint_rules
CROSS="$LINT_CROSS"
RULES="$LINT_BASELINED"
ONLY="$LINT_ONLY"
[ -n "$LINT_DENY" ] || { echo "could not list the gated lint rules from $MEDAKA"; exit 2; }

# Every top-level directory with a tracked .mdk outside test/: the projects the
# hook can lint.
targets="$(git ls-files -- '*.mdk' ':(exclude)test/**' | sed -n 's,/.*,,p' | sort -u | tr '\n' ' ')"
[ -n "$targets" ] || { echo "no lint roots found under $ROOT"; exit 2; }

if [ "${1:-}" = "--write" ]; then
  # shellcheck disable=SC2086
  "$MEDAKA" lint --internal --write-baseline="$BASELINE_REL" --only="${RULES:-$LINT_DENY}" $targets || exit 1
  echo "-- regenerated $BASELINE_REL; review 'git diff $BASELINE_REL' before committing"
  exit 0
fi

if [ ! -f "$BASELINE" ]; then
  echo "FAIL: missing $BASELINE_REL"
  echo "  regenerate: sh test/diff_compiler_lint_baseline.sh --write"
  exit 1
fi

# ── assertion 1: count-baseline ratchet + the max-ratchet CI twin ───────────
log="$(mktemp)"
# shellcheck disable=SC2086
"$MEDAKA" lint --internal --baseline="$BASELINE_REL" --only="$ONLY" $targets >"$log" 2>&1
status=$?

if [ "$status" -ne 0 ]; then
  echo "FAIL: lint baseline/max-ratchet violated ($ONLY)"
  echo ""
  grep 'medaka lint: baseline:' "$log" || cat "$log"
  echo ""
  echo "  A baselined rule's per-file count may only FALL; a GATED rule may"
  echo "  never fire at all. Remove the new finding(s), or silence an"
  echo "  intentional one with an inline"
  echo "  '-- lint-disable-next-line <rule>' directive above the site."
  echo "  A baselined count that legitimately moves is re-pinned by"
  echo "  REGENERATING:"
  echo "    sh test/diff_compiler_lint_baseline.sh --write"
  rm -f "$log"
  exit 1
fi

# ── assertion 2: the CROSS-FILE max ratchet ─────────────────────────────────
# A cross-file rule compares a body against OTHER files, so its findings are
# produced by a tier that runs once over the whole target set rather than per
# file. That tier is not reached by `--baseline` and its findings are WARNINGS,
# which exit 0. `--deny` is the promotion channel that DOES reach it, and it is
# the channel the hook's cross-file check uses, so the two agree by construction.
crosstargets=""
for r in $CROSS_ROOTS; do
  [ -d "$ROOT/$r" ] && crosstargets="$crosstargets $r"
done
crosslog="$(mktemp)"
crossstatus=0
if [ -n "$CROSS" ] && [ -n "$crosstargets" ]; then
  # shellcheck disable=SC2086
  "$MEDAKA" lint --internal --only="$CROSS" --deny="$CROSS" $crosstargets >"$crosslog" 2>&1
  crossstatus=$?
fi

if [ "$crossstatus" -ne 0 ]; then
  echo "FAIL: cross-file lint rule(s) fired ($CROSS)"
  echo ""
  grep '^error:\|^warning:' "$crosslog" || cat "$crosslog"
  echo ""
  echo "  A cross-file rule may never fire at all. Remove the duplicate, or --"
  echo "  if the duplication is deliberate -- silence it at the site with"
  echo "  '-- lint-disable-next-line <rule>' AND a comment stating the"
  echo "  constraint that forced it. An issue number is not a reason."
  echo "  What the suppressions currently hide: make dup-census"
  rm -f "$log" "$crosslog"
  exit 1
fi

rows="$(grep -c '^\[\[entry\]\]' "$BASELINE")"
rm -f "$log" "$crosslog"
echo "-- lint enforcement floor: ok ($rows pinned baseline row(s), cross-file clean, roots: $targets)"
exit 0
