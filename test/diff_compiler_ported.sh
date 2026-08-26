#!/bin/sh
# test/diff_compiler_ported.sh — gate for the in-language ported test suite.
#
# test/ported/*.mdk holds 324 `test "…" = <Expectation>` assertions ported from
# the old OCaml alcotest suites (test/ported/README.md). Nothing ran them until
# this gate: no Makefile target, hook, or other gate globbed test/ported/. This
# gate runs each file under the native ./medaka and requires: (1) the process
# exits 0 (medaka test already exits nonzero on a failing/erroring assertion —
# P0-6, see diff_compiler_test.sh), and (2) it did not panic/crash (a crash also
# exits nonzero, but is reported distinctly below since it aborts the WHOLE file
# — every assertion after the panic site never ran, unlike an ordinary FAIL).
#
# No OCaml/oracle comparison here (these files have no golden — `medaka test`'s
# own pass/fail report IS the check), so this only needs the native ./medaka,
# not a test/bin/* oracle.
#
# Usage:  sh test/diff_compiler_ported.sh
# Exit:   0 if every file's every assertion passes; nonzero otherwise.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/medaka"
DIR="$ROOT/test/ported"

[ -x "$NATIVE" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }

files="test_eval_ported.mdk test_run_ported.mdk test_loader_ported.mdk
test_eval_divergent_ported.mdk test_eval_letrec_toplevel_ported.mdk
test_eval_internal_prims_ported.mdk"

# ── KNOWN FAILURES ───────────────────────────────────────────────────────────
# These files fail on REAL INTERPRETER BUGS, not test rot. They are recorded here
# rather than skipped, following the same model as diff_compiler_engines.sh's
# ledger and CAPABILITY-EXCEPTIONS.txt (and rustc's tests/crashes): each entry
# asserts the CURRENT, WRONG behavior, so that
#   (a) the bug cannot get any worse silently, and
#   (b) an ACCIDENTAL FIX is detected — if a listed file starts passing, this gate
#       FAILS and tells you to promote it.
# A plain skip-list cannot do (b), and a skip-list is exactly how test/ported/
# rotted in the first place (nothing ran it for months). Do not "simplify" this
# into a skip.
#
# Both bugs are the same family as the 36 remaining interpreter-extern gaps
# (test/CAPABILITY-EXCEPTIONS.txt, category BUG) — eval.mdk was written as a value
# ORACLE and was silently promoted to be the production `medaka run` engine when
# the OCaml reference compiler was deleted (2026-06-26).
#
#   test_run_ported.mdk     charIsAlpha on a non-ASCII char ('é') panics
#                           "no matching impl for dispatch" (line 135). Unicode
#                           char classification is not implemented in the interpreter.
#   test_loader_ported.mdk  ⚠️ CAUSE CORRECTED 2026-08-09 (#1445).  This row used
#                           to read '"eval: unsupported node (slice 2)" — the
#                           interpreter does not lower slice syntax.'  That is
#                           WRONG: there is NO slice syntax in this file or in any
#                           module it imports — all six `.[` occurrences under
#                           test/ported/ are in test_run_ported.mdk, a DIFFERENT
#                           known-failure (derive it: grep -n '\.\[' test/ported/*.mdk).
#                           MEASURED cause: the run aborts with
#                             runtime error [E-PANIC]: '++' requires Semigroup
#                               (List, String, or a type with append)
#                           immediately after the assertion at :91, i.e. at the
#                           Phase 69.x-e case `foldMap MkSum [1, 2, 3, 4]` over
#                           summod.mdk's user `impl Semigroup Sum`.  Same family
#                           as the "native `++` ignores a user `append`" gap
#                           already recorded in test_eval_ported.mdk's removed-
#                           cases note.  Re-derive rather than trust this text:
#                             ./medaka test test/ported/test_loader_ported.mdk
KNOWN_FAIL="test_run_ported.mdk test_loader_ported.mdk"

is_known() {
  for k in $KNOWN_FAIL; do [ "$k" = "$1" ] && return 0; done
  return 1
}

pass=0; fail=0; known=0; promote=0
for f in $files; do
  path="$DIR/$f"
  [ -f "$path" ] || { fail=$((fail+1)); printf 'FAIL %s (missing file)\n' "$f"; continue; }
  # stdout/stderr captured SEPARATELY (not merged via 2>&1): the native runtime
  # runs the deeply-recursive compiler on a worker pthread (runtime/medaka_rt.c)
  # and a panic's stderr write can interleave mid-line with the worker's still-
  # buffered stdout when both land in one merged stream — a real race, harmless
  # to the exit-code check below but it garbles text-matching on a combined
  # capture, so classify PANIC from stderr alone.
  errfile="$(mktemp)"
  out="$("$NATIVE" test "$path" 2>"$errfile")"
  code=$?
  err="$(cat "$errfile")"; rm -f "$errfile"
  summary="$(printf '%s\n' "$out" | grep -E ': [0-9]+/[0-9]+ passed' | tail -1)"
  if [ "$code" -eq 0 ]; then
    if is_known "$f"; then
      # ACCIDENTAL FIX. Someone fixed the underlying interpreter bug. Fail loudly:
      # an un-promoted known-failure silently becomes a skip, and then rots.
      promote=$((promote+1))
      printf 'PROMOTE %s — it now PASSES (%s) but is still listed in KNOWN_FAIL.\n' "$f" "${summary:-all assertions passed}"
      printf '        The underlying interpreter bug is FIXED. Remove it from KNOWN_FAIL in %s\n' "$0"
      printf '        and drop its row from test/CAPABILITY-EXCEPTIONS.txt if applicable.\n'
    else
      pass=$((pass+1))
      printf 'ok   %s (%s)\n' "$f" "${summary:-all assertions passed}"
    fi
  elif printf '%s\n' "$err" | grep -q '^runtime error \[E-PANIC\]'; then
    if is_known "$f"; then
      known=$((known+1))
      printf 'known %s — PANICKED (known interpreter bug; see KNOWN_FAIL in %s)\n' "$f" "$(basename "$0")"
      printf '%s\n' "$err" | grep '^runtime error' | sed 's/^/       /'
    else
      fail=$((fail+1))
      printf 'FAIL %s — PANICKED (aborted mid-suite, assertions after the panic never ran)\n' "$f"
      printf '%s\n' "$err" | grep '^runtime error' | sed 's/^/       /'
    fi
  else
    if is_known "$f"; then
      known=$((known+1))
      printf 'known %s (%s) — known interpreter bug\n' "$f" "${summary:-exit $code}"
    else
      fail=$((fail+1))
      printf 'FAIL %s (%s)\n' "$f" "${summary:-exit $code}"
      printf '%s\n' "$out" | grep '^  FAIL' | sed 's/^/       /'
    fi
  fi
done

printf '\n%d passing, %d known-failing, %d unexpected-failing, %d awaiting-promotion\n' \
  "$pass" "$known" "$fail" "$promote"

# Never exit 0 having compared nothing.
[ $((pass + known + fail + promote)) -gt 0 ] || {
  echo "FAIL: the gate ran no files at all"; exit 1; }

# ── TYPECHECK LEDGER (#1445) ─────────────────────────────────────────────────
# Everything above grades `medaka test` — whether the ASSERTIONS pass. This
# section grades `medaka check` — whether each file TYPECHECKS. They are
# different questions and nothing else in the tree asks the second one.
#
# WHY THIS EXISTS. `medaka test` skips typechecking for any module carrying a
# `test "…"`/`prop "…"` decl (the carve-out #1445 decided to retire), so every
# file here has always been able to drift into type errors invisibly. The #1445
# triage measured them for the first time and repaired what was repairable; that
# measurement was a ONE-TIME MANUAL RESULT with nothing defending it. Without
# this ledger the next edit silently re-dirties a clean file, the residue set
# recorded in test/ported/TYPECHECK-TRIAGE.txt rots, and the #1445 follow-up
# plans its exemption against a stale list — the same rot that put a WRONG cause
# in the KNOWN_FAIL block above and left it there.
#
# Same model as KNOWN_FAIL, for the same reason: each REJECT row asserts the
# CURRENT, WRONG state and names the issue, so a fix cannot land silently — the
# row goes red and demands promotion. Do not "simplify" a REJECT row into a skip.
#
# ⚠️ A REJECT row is NOT a licence to leave a file dirty. It is a debt marker
# with an issue number. Adding one without an issue makes this a skip-list.
#
#   CLEAN         `medaka check <file>`                 must exit 0
#   CLEAN-INT     `medaka check --allow-internal <file>` must exit 0
#                 (plain `check` rejects: the file calls internal-only
#                 primitives on purpose — that is a FLAG question, not a type
#                 error. Note `medaka test` does NOT enforce the internal-extern
#                 restriction on either of its routes today, so this file gates
#                 clean there with no flag; the day the open S0 #1362 is fixed
#                 that changes, and this row is where it will surface.)
#   REJECT #N     `medaka check <file>` must exit NONZERO, blocked on issue N
typecheck_ledger="\
test_run_ported.mdk|CLEAN|
test_eval_ported.mdk|CLEAN|
test_eval_internal_prims_ported.mdk|CLEAN-INT|
test_loader_ported.mdk|CLEAN|
test_eval_divergent_ported.mdk|REJECT|1461
test_eval_letrec_toplevel_ported.mdk|REJECT|807"

tc_ok=0; tc_fail=0; tc_reject=0; tc_promote=0
printf '\n── typecheck ledger (medaka check) ──\n'
# Feed the loop from a FILE, not a pipe: in dash a `… | while read` body runs in a
# SUBSHELL and every counter increment below would be discarded, so the summary
# would print 0/0/0/0 and the gate would exit 0 having graded nothing.
tc_rows="$(mktemp)"
printf '%s\n' "$typecheck_ledger" > "$tc_rows"

while IFS='|' read -r tf mode issue; do
  [ -n "$tf" ] || continue
  tpath="$DIR/$tf"
  if [ ! -f "$tpath" ]; then
    tc_fail=$((tc_fail+1)); printf 'FAIL %s (missing file — typecheck ledger row has no file)\n' "$tf"; continue
  fi
  case "$mode" in
    CLEAN-INT) "$NATIVE" check --allow-internal "$tpath" >/dev/null 2>&1; tcode=$? ;;
    *)         "$NATIVE" check "$tpath" >/dev/null 2>&1;                  tcode=$? ;;
  esac
  case "$mode" in
    CLEAN|CLEAN-INT)
      if [ "$tcode" -eq 0 ]; then
        tc_ok=$((tc_ok+1)); printf 'ok    %s typechecks%s\n' "$tf" \
          "$([ "$mode" = CLEAN-INT ] && echo ' (--allow-internal)')"
      else
        tc_fail=$((tc_fail+1))
        printf 'FAIL  %s NO LONGER TYPECHECKS (exit %d).\n' "$tf" "$tcode"
        printf '      This file was clean and an edit re-dirtied it. Run:\n'
        printf '        ./medaka check %s%s\n' \
          "$([ "$mode" = CLEAN-INT ] && echo '--allow-internal ')" "test/ported/$tf"
        printf '      Fix it, or — if the rejection is a real compiler bug — file the issue\n'
        printf '      and move this row to REJECT with that number. Do NOT just delete the row.\n'
      fi
      ;;
    REJECT)
      if [ "$tcode" -ne 0 ]; then
        tc_reject=$((tc_reject+1)); printf 'known %s does not typecheck — blocked on #%s\n' "$tf" "$issue"
      else
        tc_promote=$((tc_promote+1))
        printf 'PROMOTE %s NOW TYPECHECKS but is still listed REJECT (#%s).\n' "$tf" "$issue"
        printf '        Issue #%s looks FIXED. Promote this row to CLEAN in %s,\n' "$issue" "$0"
        printf '        update test/ported/TYPECHECK-TRIAGE.txt, and close #%s.\n' "$issue"
        printf '        For #1461 also check whether test_eval_divergent_ported.mdk can be\n'
        printf '        folded back into test_eval_ported.mdk; same for #807 and\n'
        printf '        test_eval_letrec_toplevel_ported.mdk.\n'
      fi
      ;;
    *) tc_fail=$((tc_fail+1)); printf 'FAIL %s (unknown typecheck-ledger mode "%s")\n' "$tf" "$mode" ;;
  esac
done < "$tc_rows"
rm -f "$tc_rows"

printf '%d typechecking, %d known-rejected, %d regressed, %d awaiting-promotion\n' \
  "$tc_ok" "$tc_reject" "$tc_fail" "$tc_promote"

# Never exit 0 having graded no typecheck rows.
[ $((tc_ok + tc_reject + tc_fail + tc_promote)) -gt 0 ] || {
  echo "FAIL: the typecheck ledger graded no files at all"; exit 1; }

# Green only if BOTH halves are green: the assertions ran clean AND every file's
# typecheck verdict is still the one the ledger records.
[ "$fail" -eq 0 ] && [ "$promote" -eq 0 ] \
  && [ "$tc_fail" -eq 0 ] && [ "$tc_promote" -eq 0 ]
