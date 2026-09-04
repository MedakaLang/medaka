#!/bin/sh
# diff_compiler_test_native.sh — Stage 4 of the native-`medaka test` arc (#81):
# a CI gate that keeps native doctest execution HONEST going forward.
#
# Stages 0/1 (#1341) built `compiler/tools/native_doctest.mdk`; Stage 2 (#1345) gave
# it a loud, named skip for the two shapes it cannot run (the ledger below); Stage 3
# (#1355) wired `medaka test --native` / `--engines eval,native` into the CLI. None
# of that is graded anywhere — a regression in the native engine, or a silent skip
# turning into a silent pass, would ship with every existing gate green. This is
# that gate.
#
# ── WHY THIS NEEDS NO CAPTURED GOLDENS ──────────────────────────────────────────
#
# AGENTS.md's own warning about this suite: a captured golden records what an ENGINE
# did, not what is CORRECT — and 178 `*.eval.golden` files already enshrine bugs in
# at least five open S0s (#1034, #1037, #1040, #1047, #1062). This gate does not add
# a 179th. Every `stdlib/*.mdk` doctest example is a HAND-WRITTEN pin, independent of
# any engine: the `-- > expr` / `-- expected` pairs were written by a person reading
# the language spec, not captured from a run. That is the oracle. So the assertion
# here is not "does native's output match a snapshot of native's output" (which
# would prove nothing) but "does `medaka test --engines eval,native <module>` exit 0
# with BOTH engines reporting the SAME hand-authored pass count" — i.e. does the
# native engine agree with the doctests as WRITTEN, cross-checked by the interpreter
# also agreeing. Nothing here is a rubber stamp: if either engine regresses, or if a
# doctest itself starts failing, the pass count changes and the gate goes red without
# anyone needing to bless a new golden.
#
# Only ONE thing is a genuine pin, and it is the SMALLEST possible one: the expected
# "N/N passed" count per named module, taken from AGENTS.md's already-measured clean
# run (string 72/72, list 143/143, map 45/45). If a module's doctest count changes on
# purpose (someone adds/removes a doctest), update the number in this script the same
# turn — there is no `--bless` because there is nothing to capture, only a count to
# read off the module and update by hand, same discipline as this repo's must-fail
# suite (which also pins by hand, never by capture).
#
# ── MODULE SET: NAMED AND SMALL, ON PURPOSE ─────────────────────────────────────
#
# stdlib/string.mdk, stdlib/list.mdk, stdlib/map.mdk — three modules, chosen for
# variety (string ops, list/higher-order, an ordered-tree ADT) without widening to
# all nine native-clean modules from AGENTS.md. Widening the set is a separate
# decision (more clang time per run) left to a future PR.
#
# ── THE LOUD-SKIP PATHS ──────────────────────────────────────────────────────────
#
# 1. stdlib/core.mdk (the prelude) must still report its NAMED skip and exit
#    non-zero under both `--native` and `--engines eval,native` — never silent,
#    never a quiet pass. This is the exact hazard native_doctest.mdk's own header
#    warns about: "a SQL expression parser once shipped 32/32 green with every
#    arithmetic operator in its grammar broken natively."
#
# 2. test/NATIVE-DOCTEST-EXCEPTIONS.txt is SELF-DRAINING, modeled on
#    test/diff_compiler_must_fail.sh's idiom (read it first if touching this): every
#    row's SET is DERIVED from the ledger file itself (never hand-copied into this
#    script), and each row's stated reason is independently RE-CHECKED against the
#    live binary. A row whose reason no longer holds fails this gate by NAME, never
#    silently rots the way a plain skip-list would.
#
#    Known tags and how each is re-checked (a THIRD tag is a hard error — see below,
#    same "derive the set, not the interpretation" split diff_compiler_must_fail.sh
#    uses for its verbs):
#      PRELUDE-TARGET <path> <issue>  — re-run `medaka test --native <path>` and
#        require the SAME named skip + issue number to still appear, with a non-zero
#        exit. If #1334 is fixed and stdlib/core.mdk builds/runs natively, this
#        assertion breaks and the gate names the row to delete.
#      OWNS-MAIN <structural>          — re-scan every `.mdk` under stdlib/ and
#        compiler/ for a top-level `main` binding, and assert NONE of them also
#        carries a doctest (`-- > ` line) — the exact invariant the row's own note
#        claims ("no module in stdlib/ or compiler/ defines main except the entry
#        points, which carry no doctests"). A module that violates this is where the
#        native engine's synthesized-`main` collision would actually bite, so this
#        check is the thing that would have caught the row going stale.
#
# ── COST CONTROL ─────────────────────────────────────────────────────────────────
#
# One clang link per module-per-engine (`--native` compiles a real binary) adds up
# fast, so this precompiles runtime/medaka_rt.c and the prelude ONCE (same
# MEDAKA_RT_OBJ / MEDAKA_PRELUDE_OBJ fast path as diff_compiler_engines.sh, proven
# byte-identical to the inline path by diff_compiler_rt_obj.sh / diff_compiler_prelude_obj.sh)
# and links every per-module build against those objects at -O1 (MEDAKA_CLANG_OPT;
# NOT -O0, which overflows the deep-TCO fixtures per AGENTS.md).
#
# Usage:  sh test/diff_compiler_test_native.sh
# Exit:   0 every check passed; 1 a real assertion failed (regression, silent skip,
#         or a drained ledger row); 2 infra error (no ./medaka, missing tool).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
LEDGER="$ROOT/test/NATIVE-DOCTEST-EXCEPTIONS.txt"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -f "$LEDGER" ] || { echo "missing ledger: $LEDGER"; exit 2; }
command -v clang >/dev/null 2>&1 || {
  echo "clang not found — this gate compiles real binaries via 'medaka test --native'."
  echo "This is an INFRA ERROR, not a skip: silently skipping would report GREEN having"
  echo "never checked the native engine, exactly the hazard this gate exists to catch."
  exit 2
}

export MEDAKA_ROOT="$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

# ── cost-control fast path (best-effort; see header) ────────────────────────────
RTOBJ="$WORK/medaka_rt.o"
if bound "$MEDAKA" build --emit-rt-obj "$RTOBJ" >/dev/null 2>&1 && [ -f "$RTOBJ" ]; then
  export MEDAKA_RT_OBJ="$RTOBJ"
fi
PRELUDEOBJ="$WORK/prelude.o"
if bound "$MEDAKA" build --emit-prelude-obj "$PRELUDEOBJ" >/dev/null 2>&1 && [ -f "$PRELUDEOBJ" ]; then
  export MEDAKA_PRELUDE_OBJ="$PRELUDEOBJ"
fi
: "${MEDAKA_CLANG_OPT:=-O1}"
export MEDAKA_CLANG_OPT

fail=0
checked=0

note() { printf '%s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; fail=1; }

# ── module set (see header: NAMED, SMALL) ────────────────────────────────────────
# module path : expected doctest count, measured clean per AGENTS.md.
MODULES="stdlib/string.mdk:72 stdlib/list.mdk:143 stdlib/map.mdk:45"

for entry in $MODULES; do
  mod="${entry%%:*}"
  expected="${entry##*:}"
  out="$WORK/$(printf '%s' "$mod" | tr '/.' '__').out"
  bound "$MEDAKA" test --engines eval,native "$ROOT/$mod" >"$out" 2>&1
  rc=$?
  checked=$((checked + 1))
  if [ "$rc" -ne 0 ]; then
    bad "$mod: 'medaka test --engines eval,native' exited $rc (expected 0) — see $out"
    continue
  fi
  # Each engine's block prints "<target>: P/T passed" — grep both, in order.
  # -F is intentional: the module path can contain characters ('/','.') basic
  # regex would treat specially; nothing here is a pattern.
  counts="$(grep -F "$ROOT/$mod:" "$out" | sed -n 's/.*: \([0-9][0-9]*\)\/\([0-9][0-9]*\) passed.*/\1 \2/p')"
  n="$(printf '%s\n' "$counts" | grep -c '.')"
  if [ "$n" -ne 2 ]; then
    bad "$mod: expected exactly 2 '<target>: P/T passed' lines (eval + native), found $n — see $out"
    continue
  fi
  i=0
  printf '%s\n' "$counts" | while read -r p t; do
    i=$((i + 1))
    eng=eval
    [ "$i" -eq 2 ] && eng=native
    if [ "$p" != "$t" ] || [ "$p" != "$expected" ]; then
      echo "$mod ($eng): got $p/$t passed, expected $expected/$expected" >>"$WORK/mismatch.$$"
    fi
  done
  if [ -f "$WORK/mismatch.$$" ]; then
    while IFS= read -r line; do bad "$line"; done <"$WORK/mismatch.$$"
    rm -f "$WORK/mismatch.$$"
  else
    note "ok   $mod: eval and native both $expected/$expected passed"
  fi
done

# ── loud-skip path 1: the prelude, under BOTH --native and --engines ────────────
check_prelude_skip() {
  _flag="$1"
  _out="$WORK/core_${_flag#--}.out"
  # shellcheck disable=SC2086
  bound "$MEDAKA" test $_flag "$ROOT/stdlib/core.mdk" >"$_out" 2>&1
  _rc=$?
  checked=$((checked + 1))
  if [ "$_rc" -eq 0 ]; then
    bad "stdlib/core.mdk under 'medaka test $_flag' exited 0 — the prelude native skip must be LOUD (non-zero exit), never a silent pass. See $_out"
    return
  fi
  if ! grep -q "SKIPPED $ROOT/stdlib/core.mdk" "$_out"; then
    bad "stdlib/core.mdk under 'medaka test $_flag' did not print the named SKIPPED line — see $_out"
    return
  fi
  if ! grep -q '#1334' "$_out"; then
    bad "stdlib/core.mdk under 'medaka test $_flag' skip message no longer cites #1334 — see $_out"
    return
  fi
  note "ok   stdlib/core.mdk under 'medaka test $_flag': loud named skip, exit $_rc, cites #1334"
}
check_prelude_skip --native

# --engines takes its value as a SEPARATE argv token (parseTestEngines reads
# `testFlagValue "--engines" argv`), not `--engines=...`, so it gets its own
# small driver rather than reusing check_prelude_skip's single-flag shape.
check_prelude_skip_engines() {
  _out="$WORK/core_engines.out"
  bound "$MEDAKA" test --engines eval,native "$ROOT/stdlib/core.mdk" >"$_out" 2>&1
  _rc=$?
  checked=$((checked + 1))
  if [ "$_rc" -eq 0 ]; then
    bad "stdlib/core.mdk under '--engines eval,native' exited 0 — must be non-zero (native arm skips)."
    return
  fi
  if ! grep -q "SKIPPED $ROOT/stdlib/core.mdk" "$_out"; then
    bad "stdlib/core.mdk under '--engines eval,native' did not print the named SKIPPED line — see $_out"
    return
  fi
  if ! grep -q '#1334' "$_out"; then
    bad "stdlib/core.mdk under '--engines eval,native' skip message no longer cites #1334 — see $_out"
    return
  fi
  note "ok   stdlib/core.mdk under '--engines eval,native': loud named skip, exit $_rc, cites #1334"
}
check_prelude_skip_engines

# ── loud-skip path 2: the exceptions ledger self-drains ─────────────────────────
# Derive the row SET from the ledger — never hand-copy it into this script (same
# "derive, don't encode" discipline as diff_compiler_must_fail.sh). A row header is
# a line with EXACTLY two leading spaces followed by an uppercase/hyphen tag; the
# prose continuation lines are indented six spaces, so they never match.
tags="$(grep -E '^  [A-Z][A-Z-]*  ' "$LEDGER" | awk '{print $1}')"
if [ -z "$tags" ]; then
  bad "no exception rows found in $LEDGER — either the ledger format changed (update this gate's parser) or every native-incompatible shape got fixed (drop the ledger, drop this section, and say so in the PR)."
fi

for tag in $tags; do
  checked=$((checked + 1))
  case "$tag" in
    PRELUDE-TARGET)
      # Row: "  PRELUDE-TARGET   stdlib/core.mdk   #1334"
      row="$(grep -E '^  PRELUDE-TARGET  ' "$LEDGER")"
      scope="$(printf '%s\n' "$row" | awk '{print $2}')"
      issue="$(printf '%s\n' "$row" | awk '{print $3}')"
      _out="$WORK/ledger_prelude.out"
      bound "$MEDAKA" test --native "$ROOT/$scope" >"$_out" 2>&1
      _rc=$?
      if [ "$_rc" -eq 0 ]; then
        bad "ledger row PRELUDE-TARGET $scope $issue no longer reproduces: 'medaka test --native $scope' now exits 0. The row's DRAINS WHEN condition appears met — remove the arm in native_doctest.mdk's nativeSkipReason AND this row from $LEDGER, and close $issue."
        continue
      fi
      if ! grep -q "SKIPPED $ROOT/$scope" "$_out" || ! grep -qF "$issue" "$_out"; then
        bad "ledger row PRELUDE-TARGET $scope $issue: skip message shape changed (no longer names both the module and $issue) — see $_out. Update the row or the emitted message to match."
        continue
      fi
      note "ok   ledger row PRELUDE-TARGET $scope $issue still reproduces"
      ;;
    OWNS-MAIN)
      # Structural row, no fixed scope path — re-derive the SET of `.mdk` files
      # defining a top-level `main` and assert NONE also carries a doctest
      # (`-- > ` line), which is exactly the invariant the row's own note claims.
      offenders=""
      for f in $(grep -rlE '^main[ =(]' "$ROOT/stdlib" "$ROOT/compiler" --include='*.mdk' 2>/dev/null); do
        if grep -q '^-- > ' "$f"; then
          rel="${f#"$ROOT"/}"
          offenders="$offenders $rel"
        fi
      done
      if [ -n "$offenders" ]; then
        bad "ledger row OWNS-MAIN's invariant no longer holds: the following module(s) define a top-level 'main' AND carry doctests, so the native engine's synthesized-main collision is now a live bug, not a documented design limit:$offenders. File/verify an issue and update the OWNS-MAIN row in $LEDGER to point at it."
      else
        note "ok   ledger row OWNS-MAIN: no module defines main and carries doctests (invariant holds)"
      fi
      ;;
    *)
      bad "unrecognized ledger tag '$tag' in $LEDGER — this gate's self-drain logic only knows PRELUDE-TARGET and OWNS-MAIN. Add a case for '$tag' to test/diff_compiler_test_native.sh before this can pass (a tag this gate doesn't understand is a row it cannot verify, i.e. exactly the silent rot the ledger is supposed to prevent)."
      ;;
  esac
done

# ── abort rule (#2657/#2588: native_test_abort.mdk) ──────────────────────────
# The probe dies inside test 2 of 4: tests 2, 3 and 4 have no complete output
# and must be reported as errors — never dropped, never counted as passing.
# Test 1 already printed its result before the abort and is judged normally.
ab="$ROOT/test/compiler_test_fixtures/native_test_abort.mdk"
ab_out="$WORK/abort.out"
bound "$MEDAKA" test --native "$ab" >"$ab_out" 2>&1
ab_rc=$?
checked=$((checked + 1))
if [ "$ab_rc" -eq 0 ]; then
  bad "native_test_abort.mdk: 'medaka test --native' exited 0 — an aborting probe must never report a clean pass. See $ab_out"
elif ! grep -qF "ok   $ab:13: runs before the abort" "$ab_out"; then
  bad "native_test_abort.mdk: test 1 (before the abort) did not report ok — see $ab_out"
elif grep -qE "^  ok   $ab:(15|17|19):" "$ab_out"; then
  bad "native_test_abort.mdk: a test at or after the abort reported ok — the abort rule was not enforced. See $ab_out"
elif ! grep -qF "$ab: 1/4 passed (0 failed, 3 errors)" "$ab_out"; then
  bad "native_test_abort.mdk: expected summary '1/4 passed (0 failed, 3 errors)' (tests 2-4 named as errors, never passes or silent drops) — see $ab_out"
else
  note "ok   native_test_abort.mdk: abort rule holds — test 1 ok, tests 2-4 reported as errors, never dropped"
fi

# ── subject stays a valid, boring `medaka check` target (native_test_subject.mdk) ──
# native_test_exec.mdk's own rule is only as good as this fixture staying a
# fixture `medaka check` accepts cleanly — pin that directly rather than only
# indirectly through the exec fixture below.
subj="$ROOT/test/compiler_test_fixtures/native_test_subject.mdk"
subj_out="$WORK/subject_check.out"
bound "$MEDAKA" check "$subj" >"$subj_out" 2>&1
subj_rc=$?
checked=$((checked + 1))
if [ "$subj_rc" -ne 0 ]; then
  bad "native_test_subject.mdk: 'medaka check' exited $subj_rc (expected 0) — see $subj_out"
else
  note "ok   native_test_subject.mdk: 'medaka check' accepts it cleanly"
fi

# ── capability-gated exec rule (#2657/#2588: native_test_exec.mdk) ───────────
# Under --native, with MEDAKA resolved via the environment (never PATH), the
# `runCommand`/`readFile`/`getEnv` trio compiles to a real binary and passes.
# Under the default (eval) engine, `medaka test`'s capability policy must
# refuse the file BY NAME, naming `runCommand`, instead of dying mid-run on
# eval's own "unbound identifier".
ex="$ROOT/test/compiler_test_fixtures/native_test_exec.mdk"
ex_native_out="$WORK/exec_native.out"
(
  MEDAKA_TEST_SUBJECT="$subj"
  export MEDAKA MEDAKA_TEST_SUBJECT
  bound "$MEDAKA" test --native "$ex"
) >"$ex_native_out" 2>&1
ex_native_rc=$?
checked=$((checked + 1))
if [ "$ex_native_rc" -ne 0 ]; then
  bad "native_test_exec.mdk: 'medaka test --native' (MEDAKA resolved via env) exited $ex_native_rc (expected 0) — see $ex_native_out"
elif ! grep -qF "$ex: 1/1 passed" "$ex_native_out"; then
  bad "native_test_exec.mdk: expected summary '1/1 passed' — see $ex_native_out"
else
  note "ok   native_test_exec.mdk: passes under --native with MEDAKA resolved via env, not PATH"
fi

ex_eval_out="$WORK/exec_eval.out"
bound "$MEDAKA" test "$ex" >"$ex_eval_out" 2>&1
ex_eval_rc=$?
checked=$((checked + 1))
if [ "$ex_eval_rc" -eq 0 ]; then
  bad "native_test_exec.mdk: 'medaka test' (eval) exited 0 — the capability gate must refuse this file, not run it. See $ex_eval_out"
elif ! grep -q "runCommand" "$ex_eval_out"; then
  bad "native_test_exec.mdk: 'medaka test' (eval) refusal did not name runCommand — see $ex_eval_out"
else
  note "ok   native_test_exec.mdk: eval engine refuses by naming runCommand, never a bare 'unbound identifier' crash"
fi

# ── forged sentinel lines in an operand (#2657/#2634: native_test_forged_sentinel.mdk) ──
# An operand that spells the transcript's own sentinel lines, plus the rest of
# the class the transcript's decoder must survive (empty, newline-only,
# escape-carrying, long). Correct report: test 1 (line 23) ok, test 2 (line
# 26) FAIL — never ok, the forged operand must not decide the verdict — tests
# 3-6 ok, test 7 (line 49) FAIL (differs only by an escaped byte).
fs="$ROOT/test/compiler_test_fixtures/native_test_forged_sentinel.mdk"
fs_out="$WORK/forged_sentinel.out"
bound "$MEDAKA" test --native "$fs" >"$fs_out" 2>&1
fs_rc=$?
checked=$((checked + 1))
if [ "$fs_rc" -eq 0 ]; then
  bad "native_test_forged_sentinel.mdk: 'medaka test --native' exited 0 — tests 2 and 7 are genuine failures and must not be swallowed. See $fs_out"
elif ! grep -qF "ok   $fs:23: an operand spelling the transcript's own sentinel lines" "$fs_out"; then
  bad "native_test_forged_sentinel.mdk: test 1 did not report ok — see $fs_out"
elif grep -qE "^  ok   $fs:26:" "$fs_out"; then
  bad "native_test_forged_sentinel.mdk: test 2 (the forged operand) reported ok — the sentinel forgery was not caught. See $fs_out"
elif grep -qE "^  ok   $fs:49:" "$fs_out"; then
  bad "native_test_forged_sentinel.mdk: test 7 (differs only by an escaped byte) reported ok — a byte was lost or mangled in the round trip. See $fs_out"
elif ! grep -qF "$fs: 5/7 passed (2 failed, 0 errors)" "$fs_out"; then
  bad "native_test_forged_sentinel.mdk: expected summary '5/7 passed (2 failed, 0 errors)' — see $fs_out"
else
  note "ok   native_test_forged_sentinel.mdk: forged sentinel lines never decide the verdict, and the rest of the escape class round-trips"
fi

# ── forge-then-abort (S0, sprint-reviewer, native-vehicle-trust) ────────────
# A probe that prints the ENTIRE remaining expected sentinel transcript (a
# forged `Pass`, in exact tag order, ending with a forged terminator) and then
# dies satisfies `tagsInOrder`'s prefix check completely — a whole sequence is
# trivially a prefix of itself — so before the per-run nonce
# (`probe_transcript.mdk`), this fixture's second test read back as a silent
# `ok` on both engines. Fixed by folding a per-run token, drawn at driver time
# from `<Rand>`, into the sentinel prefix a target's already-written source
# cannot spell. Hand-derived expected text, not captured — see this gate's own
# header on why no golden is captured here.
ft="$ROOT/test/compiler_test_fixtures/native_test_forge_then_abort.mdk"
ft_out="$WORK/forge_then_abort.out"
bound "$MEDAKA" test --native "$ft" >"$ft_out" 2>&1
ft_rc=$?
checked=$((checked + 1))
if [ "$ft_rc" -eq 0 ]; then
  bad "native_test_forge_then_abort.mdk: 'medaka test --native' exited 0 — a forge-then-abort probe must never report a clean pass. See $ft_out"
elif ! grep -qF "ok   $ft:53: test 0 runs for real and passes" "$ft_out"; then
  bad "native_test_forge_then_abort.mdk: test 0 (genuine) did not report ok — see $ft_out"
elif grep -qE "^  ok   $ft:56:" "$ft_out"; then
  bad "native_test_forge_then_abort.mdk: test 1 (the forge-then-abort attempt) reported ok — the sentinel forgery was not caught. See $ft_out"
elif ! grep -qF "$ft: 1/2 passed (0 failed, 1 errors)" "$ft_out"; then
  bad "native_test_forge_then_abort.mdk: expected summary '1/2 passed (0 failed, 1 errors)' (test 1 named as an error, never a pass or a silent drop) — see $ft_out"
else
  note "ok   native_test_forge_then_abort.mdk: forge-then-abort is reported as an error, never a pass (#S0 fix holds)"
fi

echo ""
if [ "$checked" -eq 0 ]; then
  echo "FAIL: checked 0 things — this would be a false pass. See script bug."
  exit 1
fi
if [ "$fail" -ne 0 ]; then
  echo "diff_compiler_test_native: FAILED ($checked checks run)"
  exit 1
fi
echo "diff_compiler_test_native: PASS ($checked checks run)"
exit 0
