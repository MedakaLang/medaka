#!/bin/sh
# test/slop_census.sh — the ONE composing entry point over the slop-burndown
# crusade's (#2276) member censuses, run via `make slop-census`. It is not a
# gate: it asserts nothing and always exits 0.
#
# WHY THIS EXISTS (#2304): the crusade grew several independent, on-demand
# census scripts (comment-register, architecture, fmt-clean, CLI-conformance,
# ...) with no single place that lists all of them. This script IS that
# place — a REGISTRY, encoded as data in this file, of every member census.
# It never reimplements a member: each row shells out to the owner script
# (or, for the lint-rule row, the one-line invocation the owner names) and
# reports what that invocation said. Composing, not duplicating.
#
# THE GOVERNING PROPERTY: a registry row whose script does not exist on disk
# reports MISSING, never 0. A composer that silently printed 0 for an
# unbuilt/absent detector would read as "clean" — exactly the fail-open shape
# test/diff_compiler_ci_shard_coverage.sh exists to close for CI enrolment.
# This script closes the analogous hole for its own registry: absence is
# reported as absence, never laundered into a zero count. See §6 check 2 of
# this slice's packet for a live demonstration (rename a member script aside,
# rerun, read MISSING).
#
# BUILD-GATED BY DEFAULT: some registry rows need a built ./medaka
# (fmt-clean-census, cli-conformance-census, the rule-stdlib-reimpl lint
# row). The default invocation (`make slop-census` / `sh test/slop_census.sh`
# with no flags) does NOT build or invoke ./medaka — those rows are SKIPPED
# with a reason. Pass SLOP_CENSUS_FULL=1 to also run them (this will invoke
# the already-built ./medaka at $ROOT/medaka; it does not build it for you —
# the `slop-census` Make target has NO `medaka` prerequisite, by design, to
# stay cheap and side-effect-free by default, so you must build it yourself
# first: run `make medaka`, then `make slop-census SLOP_CENSUS_FULL=1`).
#
# Needs no built ./medaka by default. Portable POSIX sh.
#
# Usage:  sh test/slop_census.sh
#         SLOP_CENSUS_FULL=1 sh test/slop_census.sh
# Output: one line per registry row (PRESENT/ran, SKIPPED <reason>, or
#         MISSING), a row count derived by iterating the registry (never
#         hand-typed), then each present+run row's own output. Always exits
#         0 — this is a report, not a pass/fail check.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FULL="${SLOP_CENSUS_FULL:-}"
MEDAKA="$ROOT/medaka"

# ── the registry ──────────────────────────────────────────────────────────
# One row per member census. Fields, '|'-separated:
#   name | path (repo-relative, no leading ./) | needs_build (0/1) | command
# `command` is what gets run (via `sh -c`) when the row is present and (if
# needs_build=1) FULL is set. It is NOT re-derived — it's the documented
# invocation from each owner script's own header / this slice's packet §4.
registry='
comment-register-census|test/comment_register_census.sh|0|sh test/comment_register_census.sh
arch-census|test/arch_census.sh|0|sh test/arch_census.sh
fmt-clean-census|test/fmt_clean_census.sh|1|sh test/fmt_clean_census.sh
cli-conformance-census|test/cli_conformance_census.sh|1|sh test/cli_conformance_census.sh
rule-stdlib-reimpl|compiler/tools/lint.mdk|1|"$MEDAKA" lint --only=rule-stdlib-reimpl compiler stdlib
diag-census (leg 8, #2446)|test/diag_census.sh|1|sh test/diag_census.sh
doc-disposition (#2300)|test/doc_census.sh|0|sh test/doc_census.sh
doctest-shape (leg 5)|test/doctest_shape_census.sh|0|sh test/doctest_shape_census.sh
'

# The rule-stdlib-reimpl row has no owner .sh file of its own (§4 of the
# packet: "do not create a .sh wrapper unless the invocation genuinely needs
# one") — its presence is not "does a script exist" but "is the lint rule
# wired into the built binary." We probe that via the rule name appearing in
# compiler/tools/lint.mdk, which is the one Medaka source file that can ever
# make the invocation succeed.
RULE_STDLIB_REIMPL_SRC="$ROOT/compiler/tools/lint.mdk"

n_total=0
n_present=0
n_missing=0
n_ran=0
n_failed=0
n_skipped=0

IFS='
'
for row in $registry; do
  [ -n "$row" ] || continue
  name="${row%%|*}"
  rest="${row#*|}"
  path="${rest%%|*}"
  rest="${rest#*|}"
  needs_build="${rest%%|*}"
  cmd="${rest#*|}"

  n_total=$((n_total + 1))

  if [ "$name" = "rule-stdlib-reimpl" ]; then
    present=0
    [ -f "$RULE_STDLIB_REIMPL_SRC" ] && grep -q 'ruleNameStdlibReimpl = "rule-stdlib-reimpl"' "$RULE_STDLIB_REIMPL_SRC" && present=1
  else
    present=0
    [ -f "$ROOT/$path" ] && present=1
  fi

  if [ "$present" -eq 0 ]; then
    n_missing=$((n_missing + 1))
    printf '[MISSING]  %s  (expected at %s)\n' "$name" "$path"
    continue
  fi

  n_present=$((n_present + 1))

  if [ "$needs_build" = "1" ] && [ -z "$FULL" ]; then
    n_skipped=$((n_skipped + 1))
    printf '[SKIPPED]  %s  (needs a built ./medaka — rerun with SLOP_CENSUS_FULL=1)\n' "$name"
    continue
  fi

  if [ "$needs_build" = "1" ] && [ ! -x "$MEDAKA" ]; then
    n_skipped=$((n_skipped + 1))
    printf '[SKIPPED]  %s  (SLOP_CENSUS_FULL=1 set, but no built ./medaka at %s — run `make medaka` first)\n' "$name" "$MEDAKA"
    continue
  fi

  # Capture the member's own exit status without a trailing pipe eating it
  # (POSIX sh has no PIPESTATUS) — run into a temp file, check $? directly,
  # then sed the file separately.
  out_file="$(mktemp "${TMPDIR:-/tmp}/slop_census.XXXXXX")"
  if ( cd "$ROOT" && eval "$cmd" ) >"$out_file" 2>&1; then
    member_status=0
  else
    member_status=$?
  fi

  if [ "$member_status" -eq 0 ]; then
    n_ran=$((n_ran + 1))
    printf '[RAN]      %s\n' "$name"
  else
    n_failed=$((n_failed + 1))
    printf '[FAIL]     %s  (exit %s)\n' "$name" "$member_status"
  fi
  echo '  --------------------------------------------------------------'
  sed 's/^/  /' "$out_file"
  rm -f "$out_file"
  echo
done

echo
echo "slop_census: $n_total registry rows — $n_present present ($n_ran ran, $n_failed failed, $n_skipped skipped), $n_missing MISSING"

exit 0
