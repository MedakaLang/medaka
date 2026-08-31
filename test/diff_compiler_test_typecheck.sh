#!/bin/sh
# diff_compiler_test_typecheck.sh — `medaka test` must TYPE-CHECK its target.
#
# Issue #1229 (S2, misleading): `medaka test <file>` on a file with ZERO doctests
# never type-checked it. It printed `(no doctests found)` and exited 0 — on source
# `medaka check` rejects at exit 1. A green that tested nothing, and worse, a green
# from the verb a user reaches for to ask "is this file OK?".
#
# Issue #260 had already fixed the DOCTEST-BEARING half (`compiler/tools/test_cmd.mdk`,
# `doctestGate` → `typecheckErrors`), but keyed the gate on doctest presence alone,
# so the zero-doctest case fell through the `[] => None` arm.
#
# THE FIX (test_cmd.mdk, doctestGate): type-check unless the module carries
# `test "…"` / `prop "…"` decls. That exemption is deliberate and is NOT collateral
# damage to be cleaned up later — the ported eval-regression corpus (test/ported/*.mdk,
# run by diff_compiler_ported.sh) has 0 doctests and 200+ `test "…"` assertions whose
# entire point is exercising eval on constructs the type checker REJECTS. Gating those
# would break the suite that exists to measure eval-vs-check divergence.
#
# WHAT THIS GATE PINS — the four cells of the behaviour matrix, plus four boundary
# cells that make the fix's SCOPE observable rather than merely asserted:
#
#   a  zero doctests, ill-typed      exit 1 + the check-first diagnostic   <- the #1229 bug
#   b  zero doctests, clean          exit 0 + "(no doctests found)"
#   c  doctests present, passing     exit 0 + "1/1 passed"
#   d  doctests present, failing     exit 1 + "FAIL" + "0/1 passed"
#   e  `test "…"` decls, ill-typed   exit 0 + the test actually PASSES  <- the exemption
#   f  directory with a zero-doctest ill-typed member      exit 1
#   g  IMPORT-BEARING, zero doctests, ill-typed            exit 1 + located diagnostic
#   h  `prop "…"` decls, ill-typed   exit 0 + the prop actually RUNS    <- the exemption
#
# ...and five more (issue #1680) pinning that the exemption is no longer SILENT:
#
#   i  hasTests exemption            the note, naming the `test "…"` disjunct
#   k  hasProps exemption            the note, naming the `prop "…"` disjunct
#   l  #1680's own repro             the note AND the panic it explains, one run
#   j  doctest + `test "…"` decl     NO note (doctest wins; the module IS checked)
#   m  clean module, no tests        NO note (the gated arm; nothing was skipped)
#
# Cells b/c/d are the regression guard for the fix, and they matter more than they
# look: this change turns a path that reported NOTHING into one that reports SOMETHING,
# so every pre-existing fixture in the tree covers only the old empty case and NONE of
# them can fail on a bad version of it. Cells e and h are the inverse guard — they fail
# if the gate is widened to swallow the eval-regression corpus. They cover the two
# disjuncts of the exemption predicate SEPARATELY (`hasTests` and `hasProps`), because
# one cell can only ever exercise one of them.
#
# Cell g exists because `typecheckErrors` ROUTES on `hasUseDecls` (test_cmd.mdk): an
# import-bearing target goes to projectTypeErrors -> `analyzeProject`, a prelude-only
# one to singleFileTypeErrors -> `analyzeLocated`. Cells a and f are both import-free,
# so without g every assertion about the newly-opened path would land on ONE of the two
# arms. It is also the arm worth watching: `analyzeProject` is the function carrying
# #1362's silent-accept hole, and a zero-doctest ill-typed file WITH imports is newly
# routed through it by this change. Its fixture uses a genuine `Type mismatch` (not an
# unbound name) so the assertion reaches the type checker, not just the resolver.
#
# Cell b is why the exit code stays 0 for a clean file with no tests: a source file
# with no tests is a legitimate steady state for `medaka test <dir>`, not a phantom
# skip, and it is the overwhelming majority of this tree. Derive that rather than
# trusting a number in a comment:
#   for f in $(git ls-files '*.mdk'); do grep -qE '^[[:space:]]*(-- )?> ' "$f" && continue
#     grep -qE '^[[:space:]]*(prop|test) "' "$f" || echo "$f"; done | wc -l
# (2807 of 2886 tracked .mdk files, measured 2026-08-09.) The substantive change is
# that REACHING exit 0 now requires type-checking clean.
# ⚠️ The `(-- )?` is load-bearing: doctest.mdk's `isInputLine` tests `startsWith "-- > "`
# AFTER `expandBlock`/`expandLines` trim each `{- … -}` inner line and re-prefix "-- ",
# so a bare `> expr` in a block comment IS a doctest — the dominant form in stdlib. A
# line-comment-only pattern scores stdlib/list.mdk at 0 doctests when it has 123, and
# inflates the exempt set from 18 files to 36. Those two functions are the authority.
#
# Fixtures are written to a temp dir rather than a committed corpus: each is 1-6 lines,
# three of them deliberately do not typecheck (so they would fight the fmt/lint/snapshot
# hooks and enrol in gates they have no business in), and a shared fixture directory is
# a shared corpus.
#
# ⚠️ FIXTURE NAMES ARE PART OF THE ASSERTION SURFACE. Every expected substring is
# grepped against output that contains the fixture's own PATH, so a name sharing a
# substring with an expectation makes that expectation self-satisfying. This gate had
# exactly that bug in review: cell e's fixture was named `e_testdecl_broken.mdk` and its
# expectation was `ok`, which matched the `ok` inside br-OK-en on the `running doctests
# in <target>` line — unconditionally, whether the test passed or failed. Names below
# are chosen to share no substring with any expectation, and the expectations use the
# runner's SPACED prefixes (`  ok   `, three spaces) which no path can contain.
#
# Usage:  sh test/diff_compiler_test_typecheck.sh
#         MEDAKA=/other/tree/medaka sh test/diff_compiler_test_typecheck.sh   # 2-arm diff
# Exit:   0 all cells pass; 1 a cell failed; 2 no binary to test.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# ── fixtures ─────────────────────────────────────────────────────────────────
# a: zero doctests, zero test/prop decls, does not typecheck (issue #1229's own repro).
cat > "$TMP/a_nodoc_broken.mdk" <<'EOF'
main = println nosuchvariable
EOF

# b: zero doctests, zero test/prop decls, typechecks clean.
cat > "$TMP/b_nodoc_clean.mdk" <<'EOF'
inc : Int -> Int
inc x = x + 1
EOF

# c: one passing doctest.
cat > "$TMP/c_doctest_pass.mdk" <<'EOF'
-- > double 3
-- 6
double : Int -> Int
double x = x * 2
EOF

# d: one FAILING doctest (the function is correct; the expectation is wrong).
cat > "$TMP/d_doctest_wrong_expectation.mdk" <<'EOF'
-- > double 3
-- 7
double : Int -> Int
double x = x * 2
EOF

# e: zero doctests but a `test "…"` decl, alongside an ill-typed binding. This is the
# shape test/ported/*.mdk has, and the gate must NOT fire on it. The assertion is that
# the run REACHES and PASSES the test — exit 0 alone would also be produced by a gate
# that fired and swallowed its own diagnostic.
cat > "$TMP/e_exempt_via_testdecl.mdk" <<'EOF'
import test.{expectEqual}

illTyped = nosuchvariable

test "sum of two" = expectEqual 2 (1 + 1)
EOF

# h: the OTHER disjunct of the exemption predicate — `prop "…"` with no `test "…"`.
# `hasProps || hasTests` needs a cell per disjunct; cell e only ever exercises hasTests.
cat > "$TMP/h_exempt_via_prop.mdk" <<'EOF'
illTyped = nosuchvariable

prop "addition commutes" (x : Int) (y : Int) = x + y == y + x
EOF

# i: issue #1680's own repro, verbatim. The exemption swallowed the type error and the
# run died at `f "x"` with a bare `unknown op '+'` panic and NOTHING linking the two.
# The exemption stays; the silence does not.
cat > "$TMP/i_1680_repro.mdk" <<'EOF'
f : Int -> Int
f x = x + 1

test "t" = f "x" == 3
EOF

# j: a module carrying BOTH a doctest and a `test "…"` decl. Doctest presence WINS
# (the first guard), so this module IS type-checked — and therefore must NOT announce
# a skip. It is the negative control for the announcement: a version that printed the
# note unconditionally would pass every positive cell below and fail only here.
cat > "$TMP/j_doctest_beats_testdecl.mdk" <<'EOF'
import test.{expectEqual}

-- > triple 3
-- 9
triple : Int -> Int
triple x = x * 3

test "triple two" = expectEqual 6 (triple 2)
EOF

# f: a directory whose members are a passing-doctest file and a zero-doctest ill-typed
# file. The aggregate run must be nonzero — the issue's "directory variant".
mkdir -p "$TMP/dir"
cp "$TMP/c_doctest_pass.mdk" "$TMP/dir/clean.mdk"
cp "$TMP/a_nodoc_broken.mdk" "$TMP/dir/illtyped.mdk"

# g: a 2-FILE PROJECT. The import routes typecheckErrors down the analyzeProject arm
# (hasUseDecls), which cells a/f never reach. The error is a genuine type mismatch so
# the assertion exercises the type checker, not only name resolution.
mkdir -p "$TMP/proj"
cat > "$TMP/proj/sib.mdk" <<'EOF'
export helper : Int -> Int
helper x = x + 1
EOF
cat > "$TMP/proj/main.mdk" <<'EOF'
import sib.{helper}

main = println (helper "not an int")
EOF

# ── driver ───────────────────────────────────────────────────────────────────
# Exit codes are the SUBJECT here, so every invocation redirects to a file and reads
# `$?` directly. A pipe would report the LAST stage's status and a failing run would
# read as exit 0 — the exact confusion this gate exists to remove.
run_case() {
  name="$1"; target="$2"; want_code="$3"; shift 3
  out="$TMP/$name.out"
  "$MEDAKA" test "$target" > "$out" 2>&1
  got_code=$?

  if [ "$got_code" -ne "$want_code" ]; then
    printf 'FAIL %s: exit %d (expected %d)\n' "$name" "$got_code" "$want_code"
    sed 's/^/  | /' "$out"
    fail=$((fail+1)); return
  fi

  for want in "$@"; do
    if ! grep -qF -- "$want" "$out"; then
      printf 'FAIL %s: exit %d as expected, but output is missing [%s]\n' "$name" "$got_code" "$want"
      sed 's/^/  | /' "$out"
      fail=$((fail+1)); return
    fi
  done

  printf 'ok   %s (exit %d)\n' "$name" "$got_code"
  pass=$((pass+1))
}

# The inverse of run_case: every pattern must be ABSENT. Presence-only assertions
# cannot pin the announcement's SCOPE — a build that printed the note on every run
# would satisfy cells i/k and still be wrong, and the way it would be wrong (telling
# a user that a module WAS type-checked was not) is exactly the misreport this cell
# family exists to prevent.
refute_case() {
  name="$1"; target="$2"; want_code="$3"; shift 3
  out="$TMP/$name.out"
  "$MEDAKA" test "$target" > "$out" 2>&1
  got_code=$?

  if [ "$got_code" -ne "$want_code" ]; then
    printf 'FAIL %s: exit %d (expected %d)\n' "$name" "$got_code" "$want_code"
    sed 's/^/  | /' "$out"
    fail=$((fail+1)); return
  fi

  for unwanted in "$@"; do
    if grep -qF -- "$unwanted" "$out"; then
      printf 'FAIL %s: exit %d as expected, but output CONTAINS [%s] and must not\n' "$name" "$got_code" "$unwanted"
      sed 's/^/  | /' "$out"
      fail=$((fail+1)); return
    fi
  done

  printf 'ok   %s (exit %d)\n' "$name" "$got_code"
  pass=$((pass+1))
}

# A rejection must name BOTH the check-first remedy and the underlying diagnostic:
# an exit 1 with no explanation would be a different (and also bad) outcome.
run_case 'a zero-doctest ill-typed' "$TMP/a_nodoc_broken.mdk" 1 \
  'requires it to `medaka check` first' 'Unbound variable: nosuchvariable'

run_case 'b zero-doctest clean' "$TMP/b_nodoc_clean.mdk" 0 \
  '(no doctests found)'

run_case 'c doctest passing' "$TMP/c_doctest_pass.mdk" 0 \
  '1/1 passed'

run_case 'd doctest failing' "$TMP/d_doctest_wrong_expectation.mdk" 1 \
  'FAIL' '0/1 passed'

# The exemption cells assert the test/prop actually RAN AND PASSED, not merely exit 0:
# a gate that fired and swallowed its own diagnostic would also exit 0, and `1/1 passed`
# / `OK (100 tests)` are the only output a spuriously-gated run could not produce.
run_case 'e exemption preserved (hasTests)' "$TMP/e_exempt_via_testdecl.mdk" 0 \
  '  ok   ' 'sum of two' '1/1 passed'

run_case 'h exemption preserved (hasProps)' "$TMP/h_exempt_via_prop.mdk" 0 \
  'OK (100 tests)' '1 passed, 0 failed'

# ── issue #1680: the exemption ANNOUNCES itself ──────────────────────────────
# Cells e/h above pin that the exempted module still RUNS. These pin that it also
# SAYS SO. Same [W-QUIETER]-inverse caveat as cells b/c/d: this turns a path that
# printed nothing into one that prints something, so no pre-existing fixture in the
# tree can fail on a bad version of it and these are written from the intended
# semantics, not captured from the binary.
#
#   i  hasTests exemption   the note, naming the `test "…"` disjunct
#   k  hasProps exemption   the note, naming the `prop "…"` disjunct
#   l  #1680's own repro    the note PRECEDES the panic it explains
#   j  doctest + test decl  NO note (doctest presence wins; the module IS checked)
#   m  clean, no tests      NO note (the gated arm; nothing was skipped)
#
# Cells j and m are the ones that make the announcement's SCOPE observable. i/k/l
# alone are all satisfied by a build that announces unconditionally — which would
# claim every type-checked module went unchecked.
run_case 'i announcement on the hasTests exemption' "$TMP/e_exempt_via_testdecl.mdk" 0 \
  'note: typechecking was skipped for' '`test "…"` decls' 'to type-check it: medaka check' \
  '1/1 passed'

run_case 'k announcement on the hasProps exemption' "$TMP/h_exempt_via_prop.mdk" 0 \
  'note: typechecking was skipped for' '`prop "…"` decls' 'to type-check it: medaka check' \
  'OK (100 tests)'

# #1680's headline symptom is the UNEXPLAINED panic, so this cell asserts both halves
# are present in one run: the panic still happens (the exemption is intact) and the
# note that explains it does too.
run_case 'l 1680 repro: the panic is explained' "$TMP/i_1680_repro.mdk" 1 \
  'note: typechecking was skipped for' 'may therefore be an uncaught TYPE error' \
  "runtime error [E-PANIC]: unknown op '+'"

refute_case 'j doctest wins: no skip announced' "$TMP/j_doctest_beats_testdecl.mdk" 0 \
  'typechecking was skipped'

refute_case 'm gated clean module: no skip announced' "$TMP/b_nodoc_clean.mdk" 0 \
  'typechecking was skipped'

run_case 'f directory with ill-typed member' "$TMP/dir" 1 \
  'requires it to `medaka check` first'

run_case 'g import-bearing, zero doctests, ill-typed' "$TMP/proj/main.mdk" 1 \
  'requires it to `medaka check` first' 'Type mismatch: Int vs String'

# Cell a's counterpart: `medaka check` must reject the same file, or the gate is
# comparing `test` against nothing. This is the positive control for the whole matrix
# — without it, a binary whose check ALSO went silent would pass every cell above.
"$MEDAKA" check "$TMP/a_nodoc_broken.mdk" > "$TMP/a.check.out" 2>&1
check_code=$?
if [ "$check_code" -eq 0 ]; then
  printf 'FAIL control: `medaka check` exited 0 on the ill-typed fixture — the matrix above proves nothing\n'
  fail=$((fail+1))
else
  printf 'ok   control (`medaka check` rejects the same file, exit %d)\n' "$check_code"
  pass=$((pass+1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
