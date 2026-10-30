# test/lint_rule_lists.sh -- the lint rule lists the hook and the CI twin enforce.
#
# Sourced by .githooks/pre-commit and test/diff_compiler_lint_baseline.sh, so the
# two derive the SAME lists one way.  The caller defines `rule_names ARGS...`
# (`medaka lint --list-rules --names ARGS`); nothing here names a rule.
#
# After `derive_lint_rules`:
#   LINT_CROSS       gated rules with a cross-file tier, comma-separated
#   LINT_BASELINED   baselined rules, comma-separated (may be EMPTY: draining the
#                    last one must not leave a dangling comma in --only)
#   LINT_GATED_FILE  gated per-file rules that are not also cross-file
#   LINT_DENY        every gated rule: per-file plus cross-file
#   LINT_ONLY        --only= value: LINT_DENY plus the baselined rules
# A rule that exists as both a same-file rule and a cross-file rule under one
# name (rule-duplicate-body) is named once, in LINT_CROSS; naming it selects both
# tiers.

csv() { paste -sd, - ; }

derive_lint_rules() {
  _cross_nl="$(rule_names --ratchet=gated --tier=cross)"
  LINT_CROSS="$(printf '%s\n' "$_cross_nl" | grep -v '^$' | csv)"
  LINT_BASELINED="$(rule_names --ratchet=baselined | grep -v '^$' | csv)"
  _gated_file=""
  for _n in $(rule_names --ratchet=gated); do
    case "
$_cross_nl
" in
      *"
$_n
"*) ;;
      *) _gated_file="$_gated_file,$_n" ;;
    esac
  done
  LINT_GATED_FILE="${_gated_file#,}"
  LINT_DENY="$LINT_GATED_FILE"
  [ -n "$LINT_CROSS" ] && LINT_DENY="${LINT_DENY:+$LINT_DENY,}$LINT_CROSS"
  LINT_ONLY="$LINT_DENY"
  [ -n "$LINT_BASELINED" ] && LINT_ONLY="${LINT_ONLY:+$LINT_ONLY,}$LINT_BASELINED"
  return 0
}
