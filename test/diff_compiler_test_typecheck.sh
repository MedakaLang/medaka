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
# WHAT THIS GATE PINS — the four cells of the matrix plus the two boundaries that
# make the fix's SCOPE observable rather than merely asserted:
#
#   a  zero doctests, ill-typed      exit 1 + the check-first diagnostic   <- the #1229 bug
#   b  zero doctests, clean          exit 0 + "(no doctests found)"
#   c  doctests present, passing     exit 0 + "1/1 passed"
#   d  doctests present, failing     exit 1 + "FAIL" + "0/1 passed"
#   e  `test "…"` decls, ill-typed   exit 0                <- the exemption, NOT widened
#   f  directory with a zero-doctest ill-typed member      exit 1
#
# Cells b/c/d are the regression guard for the fix, and they matter more than they
# look: this change turns a path that reported NOTHING into one that reports SOMETHING,
# so every pre-existing fixture in the tree covers only the old empty case and NONE of
# them can fail on a bad version of it. Cell e is the inverse guard — it fails if the
# gate is widened to swallow the eval-regression corpus.
#
# Cell b is why the exit code stays 0 for a clean file with no tests: a source file
# with no tests is a legitimate steady state for `medaka test <dir>`, not a phantom
# skip, and it is the overwhelming majority of this tree. Derive that rather than
# trusting a number in a comment:
#   for f in $(git ls-files '*.mdk'); do grep -q -- '-- >' "$f" && continue
#     grep -qE '^ *(prop|test) "' "$f" || echo "$f"; done | wc -l
# (2808 of 2886 tracked .mdk files, measured 2026-08-09.) The substantive change is
# that REACHING exit 0 now requires type-checking clean.
#
# Fixtures are written to a temp dir rather than a committed corpus: each is 1-6 lines,
# two of them deliberately do not typecheck (so they would fight the fmt/lint/snapshot
# hooks and enrol in gates they have no business in), and a shared fixture directory is
# a shared corpus.
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
cat > "$TMP/d_doctest_fail.mdk" <<'EOF'
-- > double 3
-- 7
double : Int -> Int
double x = x * 2
EOF

# e: zero doctests but a `test "…"` decl, alongside an ill-typed binding. This is the
# shape test/ported/*.mdk has, and the gate must NOT fire on it.
cat > "$TMP/e_testdecl_broken.mdk" <<'EOF'
import test.{expectEqual}

broken = nosuchvariable

test "arithmetic" = expectEqual 2 (1 + 1)
EOF

# f: a directory whose members are a passing-doctest file and a zero-doctest ill-typed
# file. The aggregate run must be nonzero — the issue's "directory variant".
mkdir -p "$TMP/dir"
cp "$TMP/c_doctest_pass.mdk" "$TMP/dir/ok.mdk"
cp "$TMP/a_nodoc_broken.mdk" "$TMP/dir/broken.mdk"

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

# A rejection must name BOTH the check-first remedy and the underlying diagnostic:
# an exit 1 with no explanation would be a different (and also bad) outcome.
run_case 'a zero-doctest ill-typed' "$TMP/a_nodoc_broken.mdk" 1 \
  'requires it to `medaka check` first' 'Unbound variable: nosuchvariable'

run_case 'b zero-doctest clean' "$TMP/b_nodoc_clean.mdk" 0 \
  '(no doctests found)'

run_case 'c doctest passing' "$TMP/c_doctest_pass.mdk" 0 \
  '1/1 passed'

run_case 'd doctest failing' "$TMP/d_doctest_fail.mdk" 1 \
  'FAIL' '0/1 passed'

run_case 'e test-decl exemption preserved' "$TMP/e_testdecl_broken.mdk" 0 \
  'ok' 'arithmetic'

run_case 'f directory with ill-typed member' "$TMP/dir" 1 \
  'requires it to `medaka check` first'

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
