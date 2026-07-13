#!/bin/sh
# SHADOW-SEMANTICS decision-matrix gate (docs/spec/SHADOW-SEMANTICS.md).
#
# test/shadow_fixtures/ is the enforcement corpus for that spec -- one fixture
# per matrix cell -- and until this gate existed NOTHING ran it (audit finding,
# 2026-07-13: 5 orphaned fixture directories tree-wide; this was the worst,
# because it is a SPEC's enforcement, not just a regression corpus). A design
# agent needing to know what a cell actually does had to drive every fixture by
# hand. See test/diff_compiler_run_check_agreement.sh for the general shape
# this gate follows (check/run/build agreement, exit-code AND value).
#
# ⚠️ THIS GATE PINS WHAT THE BINARY ACTUALLY DOES ON CURRENT MAIN, NOT WHAT THE
# SPEC SAYS SHOULD HAPPEN. Per clause S7, `run`/`check`/`build` are specified to
# agree on every cell, so this gate checks all three -- exit-code verdict AND,
# for cells where run+build both accept, that they print the SAME, PINNED
# value (a P0-20-shaped bug -- build exits 0 printing a WRONG number -- is
# invisible to an exit-code-only gate; see that gate's own history).
#
# As of this writing (main built from a fresh cold bootstrap, no PR merged past
# `ef066191`), EVERY numbered matrix cell that ships a fixture in
# test/shadow_fixtures/ (rows 3-20 in the doc's table: d1/d1b/d2/d3/d4/d4b/d5/
# d5b/d6/d7/d8/d9/i1/i3/i4) is CONFORMANT: check/run/build agree with each
# other AND with the doc's S1-S8-specified outcome. The doc's own matrix STATUS
# column (section 2) still marks rows 10/12/13/14 as BUG -- that column is
# STALE: the P0-19 (2026-07-10) and P0-20 (2026-07-13) fixes already closed all
# four, and the doc's OWN section-5 update notes say so a few paragraphs below
# the stale table. This gate's empirical run is the tiebreaker: those four rows
# are pinned ACCEPT/ACCEPT/ACCEPT (or REJECT/REJECT/REJECT) below, matching
# current reality, not the stale BUG marker.
#
# Two more cells (d10, d11) exist ONLY in this gate's corpus -- added alongside
# this gate to cover the doc's section-5 "Residuals" (2 bugs still explicitly
# open, NOT closed by P0-19/P0-20):
#   - d10_definer_constrained.mdk: a CONSTRAINED standalone (`Num a =>`) shadow
#     -- the dict-passing/RLocal seam bug ("S-1"). A design doc + fix exist on
#     branch fix/s1-constrained-shadow-dict (PR #25) but are NOT merged as of
#     this writing, and that PR's own d10 fixture is byte-identical .mdk
#     SOURCE to this one (only the header comment differs, since this one
#     describes the CURRENT wrong behavior rather than the post-fix one) --
#     expect a path collision to reconcile when that PR lands; that is
#     intentional, not an accident, per "a ledger entry must fail when the bug
#     is fixed."
#   - d11_definer_multityparam_iface.mdk: a multi-TYPARAM interface
#     (`interface Ix a i`) bypasses the whole definer-shadow machinery (every
#     entry point gates on counting INTERFACE type params, not method params).
#     No fix is in flight for this one.
# Both are KNOWN-BAD rows below: pinned to the CURRENT (wrong) split behavior,
# with a comment on what they must become once fixed. A KNOWN-BAD row is not a
# skip -- it runs and asserts every turn; it goes red the day the bug is
# fixed, which is the signal to correct its expectation, not silence it.
#
# Untested-per-the-doc (rows 21-23: importer value-position / importer N-way /
# return-position method shadow) ship NO fixture in test/shadow_fixtures/ and
# are out of scope here -- adding fixtures for them is follow-up work, not a
# silent gap in THIS gate (this gate covers 100% of what test/shadow_fixtures/
# actually contains, checked by the coverage self-audit below, which fails
# loudly the moment a new fixture is dropped into the directory without being
# wired into the TABLE).
#
# Usage:  sh test/diff_compiler_shadow_semantics.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/shadow_fixtures"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -d "$FIXDIR" ] || { echo "missing fixture dir: $FIXDIR"; exit 2; }

bound() { perl -e 'alarm 60; exec @ARGV' "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; asserts=0

# Table: entry-path (relative to FIXDIR) | label | exp_check | exp_run | exp_build | mode | value
#   exp_* in {ACCEPT, REJECT} -- ACCEPT means exit 0, REJECT means nonzero exit.
#   mode in:
#     NONE             -- no stdout assertion (all three REJECT; nothing ran)
#     ALL_EXACT        -- run and build both ACCEPT: their stdouts, AND the
#                         pinned `value`, must all be byte-identical (S7 value
#                         agreement + ground-truth pin, P0-20 shape)
#     BUILD_EXACT      -- only build's stdout is asserted against `value`
#                         (used when run is expected to REJECT but build is
#                         expected to ACCEPT with a specific, deterministic
#                         value -- a check/build-agree-run-diverges split)
#     BUILD_NOTEQ_INT  -- build's stdout must be a bare integer (digits only)
#                         that is NOT equal to `value` (used for a
#                         non-deterministic garbage-pointer miscompile, where
#                         the wrong value differs run to run but is always
#                         "some integer, not the right one")
#   `value` uses literal backslash-n for embedded newlines (expanded via
#   `printf '%b'`); empty for mode NONE.
TABLE='d1b_definer_noimpl_zeroimpls.mdk|D1b definer, iface has ZERO impls (S2)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d1_definer_noimpl.mdk|D1 definer, no-impl receiver, impl exists elsewhere (S2)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d2_definer_liveimpl.mdk|D2 definer, live-impl receiver + no-impl fallback (S2)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n4
d3_definer_nway.mdk|D3 definer, N-way multi-impl selection (S3)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n30\n4
d4_definer_value_pos.mdk|D4 definer, value position over no-impl elements (S4)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[2, 3, 4]
d4b_definer_value_pos_liveimpl.mdk|D4b definer, value position over LIVE-impl elements (S4)|REJECT|REJECT|REJECT|NONE|
d5_definer_poly_receiver.mdk|D5 definer, ungrounded receiver monomorphises to standalone (S5)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d5b_definer_poly_liveimpl_call.mdk|D5b definer, poly wrapper CALLED at live-impl type (S5)|REJECT|REJECT|REJECT|NONE|
d6_definer_parametric_receiver.mdk|D6 definer, live impl at parametric receiver head (S2)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|9\n4
d7_definer_multiparam_method.mdk|D7 definer, two-param interface method shadow (S8)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n6
d9_definer_reject.mdk|D9 definer, no-impl receiver + standalone domain mismatch (S2)|REJECT|REJECT|REJECT|NONE|
d8_definer_imported_impl/main.mdk|D8 definer, shadowed iface + impl IMPORTED (S6)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n4
i1_importer_local_iface/main.mdk|I1/I2 importer shadow, LOCAL interface (S2/S6)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n4
i3_importer_imported_iface/main.mdk|I3 importer shadow, iface+impl in a THIRD module (S6)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n4
i4_importer_prelude_iface/main.mdk|I4 importer shadow of a PRELUDE method (S2, stdlib shape)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|True\nFalse\nFalse\nTrue
d10_definer_constrained.mdk|D10 KNOWN-BAD: constrained standalone, dict-passing seam (S-1, doc residual #1)|ACCEPT|REJECT|ACCEPT|BUILD_NOTEQ_INT|4
d11_definer_multityparam_iface.mdk|D11 KNOWN-BAD: multi-typaram interface bypasses shadow machinery (doc residual #2)|ACCEPT|REJECT|ACCEPT|BUILD_EXACT|4\n3'

# --- Coverage self-audit: every top-level fixture unit (a .mdk file, or a
# directory) in FIXDIR must appear in TABLE, or this gate silently re-creates
# the exact orphan-corpus problem it exists to close. ---
listed="$(printf '%s\n' "$TABLE" | awk -F'|' 'NF>1{print $1}' | sed 's#/main\.mdk$##' | sort -u)"
actual="$(cd "$FIXDIR" && for e in *; do
            if [ -d "$e" ] || { [ -f "$e" ] && [ "${e%.mdk}" != "$e" ]; }; then
              echo "$e"
            fi
          done | sort -u)"

uncovered=0
for a in $actual; do
  hit=0
  for l in $listed; do
    [ "$a" = "$l" ] && hit=1 && break
  done
  if [ "$hit" -eq 0 ]; then
    uncovered=$((uncovered+1))
    fail=$((fail+1))
    printf 'FAIL coverage: %s exists in %s but is NOT wired into this gate'"'"'s TABLE\n' "$a" "$FIXDIR"
  fi
done
asserts=$((asserts+1))
if [ "$uncovered" -eq 0 ]; then
  pass=$((pass+1))
  printf 'ok   coverage: every fixture in %s is wired into this gate (%d units)\n' "$FIXDIR" "$(printf '%s\n' "$actual" | grep -c .)"
fi
echo

printf '%-70s %-6s %-6s %-6s %-11s %s\n' 'fixture' 'check' 'run' 'build' 'value' 'result'
printf '%-70s %-6s %-6s %-6s %-11s %s\n' '----------------------------------------------------------------------' '------' '------' '------' '-----------' '------'

printf '%s\n' "$TABLE" | while IFS='|' read -r entry label exp_check exp_run exp_build mode value; do
  [ -z "$entry" ] && continue
  entrypath="$FIXDIR/$entry"
  base="$(printf '%s' "$entry" | sed 's#/main\.mdk$##' | tr '/' '_')"

  if [ ! -f "$entrypath" ]; then
    printf '%-70s %s\n' "$entry" 'FAIL MISSING FIXTURE FILE'
    echo "FAIL" >> "$TMP/verdicts"
    continue
  fi

  bound "$MEDAKA" check "$entrypath" >/dev/null 2>"$TMP/$base.chk.err"
  check_code=$?
  bound "$MEDAKA" run "$entrypath" >"$TMP/$base.run.out" 2>"$TMP/$base.run.err"
  run_code=$?
  bound "$MEDAKA" build "$entrypath" -o "$TMP/$base.bin" >"$TMP/$base.build.err" 2>&1
  build_code=$?

  if [ "$check_code" -eq 0 ]; then check_v='ACCEPT'; else check_v='REJECT'; fi
  if [ "$run_code" -eq 0 ]; then run_v='ACCEPT'; else run_v='REJECT'; fi
  if [ "$build_code" -eq 0 ] && [ -x "$TMP/$base.bin" ]; then
    build_v='ACCEPT'
    bound "$TMP/$base.bin" >"$TMP/$base.build.out" 2>"$TMP/$base.build.runerr"
  else
    build_v='REJECT'
    : >"$TMP/$base.build.out"
  fi

  row_ok=1
  [ "$check_v" = "$exp_check" ] || row_ok=0
  [ "$run_v" = "$exp_run" ] || row_ok=0
  [ "$build_v" = "$exp_build" ] || row_ok=0

  value_v='-'
  case "$mode" in
    NONE) ;;
    ALL_EXACT)
      if [ "$run_v" = 'ACCEPT' ] && [ "$build_v" = 'ACCEPT' ]; then
        printf '%b\n' "$value" > "$TMP/$base.expected"
        if cmp -s "$TMP/$base.run.out" "$TMP/$base.build.out" && cmp -s "$TMP/$base.run.out" "$TMP/$base.expected"; then
          value_v='ok'
        else
          value_v='DIFF'
          row_ok=0
        fi
      else
        value_v='n/a'
      fi
      ;;
    BUILD_EXACT)
      if [ "$build_v" = 'ACCEPT' ]; then
        printf '%b\n' "$value" > "$TMP/$base.expected"
        if cmp -s "$TMP/$base.build.out" "$TMP/$base.expected"; then
          value_v='ok'
        else
          value_v='WRONG'
          row_ok=0
        fi
      else
        value_v='n/a'
      fi
      ;;
    BUILD_NOTEQ_INT)
      if [ "$build_v" = 'ACCEPT' ]; then
        got="$(tr -d '[:space:]' < "$TMP/$base.build.out")"
        case "$got" in
          ''|*[!0-9]*)
            value_v='NOTINT'
            row_ok=0
            ;;
          "$value")
            value_v='EQ-WANT-NE'
            row_ok=0
            ;;
          *)
            value_v='ok(garbage)'
            ;;
        esac
      else
        value_v='n/a'
      fi
      ;;
  esac

  if [ "$row_ok" -eq 1 ]; then
    result='PASS'
    echo "PASS" >> "$TMP/verdicts"
  else
    result='FAIL'
    echo "FAIL" >> "$TMP/verdicts"
  fi
  printf '%-70s %-6s %-6s %-6s %-11s %s\n' "$entry" "$check_v" "$run_v" "$build_v" "$value_v" "$result"
done

# The `printf | while read` above runs in dash/ash as a subshell of the
# pipeline (POSIX allows this; dash actually does fork the last stage of a
# pipe), so pass/fail/asserts mutated INSIDE that loop would NOT survive to
# here. We therefore tally the real per-row verdicts from $TMP/verdicts
# (written from inside the loop, which DOES survive since it's a file, not a
# shell variable) rather than trusting variables mutated in the subshell.
if [ -f "$TMP/verdicts" ]; then
  row_pass="$(grep -c '^PASS$' "$TMP/verdicts")"
  row_fail="$(grep -c '^FAIL$' "$TMP/verdicts")"
else
  row_pass=0
  row_fail=0
fi
pass=$((pass+row_pass))
fail=$((fail+row_fail))
asserts=$((asserts+row_pass+row_fail))

echo
printf '%s: %d passed, %d failed (%d assertions)\n' "$(basename "$0")" "$pass" "$fail" "$asserts"
[ "$fail" -eq 0 ]
