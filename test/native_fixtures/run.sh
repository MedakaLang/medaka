#!/bin/sh
# Native-only regression assertions for two compiler lexer/parser fixes.
# Requires ./medaka built (FORCE_EMITTER_REBUILD=1 make medaka).
#   #2  `/=` → located, helpful error (not a mislocated "Parse error").
#   #3  multiline `let` RHS (bare-INDENT block) followed by `if/then/else`
#       must `check` cleanly (oracle accepts it; the bug was compiler-parser).
# These are NATIVE-ONLY: the frozen OCaml oracle mislocates #2 and accepts #3
# (so they are deliberately NOT in test/diff_fixtures/).
#
# ── THIS GATE RAN NOWHERE UNTIL 2026-07-13 (T8) ──────────────────────────────
#
# It is a real gate — 11 assertions, `exit $fail` — but nothing invoked it. Not
# run_gates.sh (which globs only `test/diff_compiler_*.sh`), not the Makefile, not
# ci.yml. And it lives one directory DOWN from test/, so even the coverage gate that
# polices "every gate must run in CI" could not see it: that gate enumerated
# `test/*.sh` + `test/wasm/*.sh`, and this is `test/native_fixtures/run.sh`.
#
# When it was finally run, it was RED — 9 ok, 2 failing — and had been for an unknown
# length of time. One failure was a REAL COMPILER BUG (see the EXPECTED-FAILURE ledger
# below); the other was a stale assertion in this file, pinning an em-dash the
# diagnostic no longer uses (the message itself is correct, and better). That is what
# a gate nobody runs decays into: you cannot tell the regression from the rot.
#
# ── EXPECTED-FAILURE LEDGER ──────────────────────────────────────────────────
#
# A LEDGER, NOT A SKIP-LIST (see test/CHECK-REMOVED-CONSTRUCTS-LEDGER.txt for the
# canonical statement). An assertion named in XFAIL below is expected to FAIL, for the
# stated reason. The gate diffs expectation against reality in BOTH directions:
#
#   an XFAIL assertion that PASSES  -> FAIL ("accidentally fixed — delete the entry")
#   any other assertion that FAILS  -> FAIL (an ordinary regression)
#
# The first direction is the one a skip-list structurally cannot see, and it is why
# this is a ledger. Every entry needs a reason and an owning task.
#
# (empty — method_shadow_run's T-12 entry was deleted when the S2 inversion landed.)
XFAIL=''

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
M="$ROOT/medaka"
FIX="$ROOT/test/native_fixtures"
[ -x "$M" ] || { echo "build ./medaka first: FORCE_EMITTER_REBUILD=1 make medaka"; exit 2; }

fail=0
xfail_ok=0        # ledgered failures that are still failing (as expected)
xfail_fixed=""    # ledgered failures that now PASS — the ledger is stale

is_xfail() { case " $XFAIL " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ok <assertion-name> / bad <assertion-name> <detail> — route each verdict through the
# ledger so an accidental fix is as loud as a regression.
ok() {
  if is_xfail "$1"; then
    xfail_fixed="$xfail_fixed $1"
    echo "XPASS $1 — ledgered as failing, but it PASSES now"
  else
    echo "ok   $1"
  fi
}
bad() {
  if is_xfail "$1"; then
    xfail_ok=$((xfail_ok + 1))
    echo "xfail $1 (known — see the EXPECTED-FAILURE ledger in this file)"
  else
    echo "FAIL $1: $2"; fail=$((fail + 1))
  fi
}

# #2: located error at the `!=` column with the hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/bangeq_error.mdk" 2>&1)"
case "$out" in
  *":7: unexpected '!='. (Did you mean '/='?)"*)
    ok bangeq_error ;;
  *) bad bangeq_error "got [$out]" ;;
esac

# #3: multiline let RHS + if/then/else checks cleanly (exit 0).
perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/let_multiline_rhs_if.mdk" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  ok let_multiline_rhs_if
else
  bad let_multiline_rhs_if "check returned non-zero"
fi

# method-name shadow (facet 1): a user top-level fn shadowing a prelude interface
# method (`eq`/`gt`) with applied-type params must `check` cleanly (exit 0).  The
# flat single-file path used to flatten core+user and let the user scheme shadow
# the method in core's own prop/`neq` bodies → spurious "List Int vs Int".  The
# oracle accepts it (method-marks the prop ref), so this is NATIVE-only assurance.
perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/method_shadow_check.mdk" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  ok method_shadow_check
else
  bad method_shadow_check "check returned non-zero"
fi

# method-name shadow (facet 2): a DIRECT call to the user's shadowing `eq` must
# resolve to the USER's definition on the EVAL path (run), matching build + the
# oracle, even though `List Int` HAS an `Eq` impl (the eval path used to arg-stamp
# the `Eq (List a)` impl → False; the user's `eq` returns True).
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" run "$FIX/method_shadow_run.mdk" 2>&1)"
case "$out" in
  True) ok method_shadow_run ;;
  *) bad method_shadow_run "expected True, got [$out]" ;;
esac

# #62: `record` as a MODULE name (`import record.*`).  This fixture directory
# existed for months with NO assertion referencing it — it was blocked on the
# removed-keyword diagnostic firing on the bare token regardless of position,
# so wiring it up would only have pinned the bug.  Freeing the word unblocked
# it, so it is live now: the import must resolve and the program must run.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" run "$FIX/keyword_import_record/main.mdk" 2>&1)"
case "$out" in
  "hello from record module") ok keyword_import_record ;;
  *) bad keyword_import_record "expected 'hello from record module', got [$out]" ;;
esac

# inline-let missing-in: located error at the `let` keyword with a hint.
# Before the fix, native reported 2:0 ("if" line) with no hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/inline_let_missing_in.mdk" 2>&1)"
case "$out" in
  *"inline 'let' requires 'in'"*)
    ok inline_let_missing_in ;;
  *) bad inline_let_missing_in "got [$out]" ;;
esac

# arrayBlit + arraySetUnsafe in native interpreter: Vector.push triggers both.
# Before the fix: "unbound identifier: arrayBlit" on the 3rd push (first grow).
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" run "$FIX/vector_push.mdk" 2>&1)"
case "$out" in
  ok) ok vector_push ;;
  *) bad vector_push "expected 'ok', got [$out]" ;;
esac

# PARSE-ERROR-LOCATION Stage 1 (caret) + Stage 2 (foreign-syntax hints).
# Each foreign-syntax mistake is located (dodging the old `1:0` collapse) with a
# beginner-grade hint, rendered through the shared caret block (a `^` line).

# Stage 2: C-style brace block on `if` — located at the `{` (col 15) with the hint,
# AND the Stage-1 caret block (the `^` line proves the snippet renderer fired).
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/brace_block_if.mdk" 2>&1)"
case "$out" in
  *":1:15: unexpected '{'"*"Medaka has no brace blocks"*"^"*)
    ok brace_block_if ;;
  *) bad brace_block_if "got [$out]" ;;
esac

# Stage 2: `for` loop — located at the `for` keyword with the recursion hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/for_loop.mdk" 2>&1)"
case "$out" in
  *"Medaka has no 'for' loops"*) ok for_loop ;;
  *) bad for_loop "got [$out]" ;;
esac

# Stage 2: `def` function header — located at the `def` keyword with the hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/def_keyword.mdk" 2>&1)"
case "$out" in
  *":1:0: Medaka has no 'def'"*) ok def_keyword ;;
  *) bad def_keyword "got [$out]" ;;
esac

# Stage 2: `/* … */` block comment — located at the `/` with the `{- -}`/`--` hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/block_comment.mdk" 2>&1)"
case "$out" in
  *"Medaka has no '/* … */' block comments"*)
    ok block_comment ;;
  *) bad block_comment "got [$out]" ;;
esac

# Stage 2: trailing `;` statement terminator — located at the `;` with the hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/semicolon_stmt.mdk" 2>&1)"
case "$out" in
  *"Medaka has no statement terminator ';'"*)
    ok semicolon_stmt ;;
  *) bad semicolon_stmt "got [$out]" ;;
esac

# EFFECTS-SEMANTICS §8: a file extern receives the authority granted at each use,
# and that argument cannot change a value the program computes — so `run` and a
# built binary print the same thing for every shape a grant reaches a call through.
# Each case runs in its own directory, whose `cfg/a.txt` holds `granted`.
GRANTS="$FIX/authority_grants"
grant_case() {
  out_run="$(cd "$GRANTS" && perl -e 'alarm 60; exec @ARGV' -- "$M" run "$1.mdk" 2>&1)"
  bin="${TMPDIR:-/tmp}/medaka_grants_$$_$1"
  (cd "$GRANTS" && perl -e 'alarm 180; exec @ARGV' -- "$M" build "$1.mdk" -o "$bin" >/dev/null 2>&1)
  out_build="$( (cd "$GRANTS" && "$bin") 2>&1)"
  rm -f "$bin" "$bin.ll"
  if [ "$out_run" = "$2" ] && [ "$out_build" = "$2" ]; then
    ok "grants_$1"
  else
    bad "grants_$1" "expected [$2], run printed [$out_run], build printed [$out_build]"
  fi
}
grant_case open_read "Ok granted"
grant_case wrappers "Ok [granted]
Ok granted
[Ok granted]"
grant_case value_uses "Ok granted
Ok granted"
grant_case existential_delay "Ok granted
Ok granted
Ok granted"
grant_case method "Ok granted
Ok grantedgranted
Ok granted
Ok echo cfg/a.txt
Ok granted
[Ok granted]"
grant_case partial_write "Ok ()
Ok x
Ok ()"

# EFFECTS-SEMANTICS §7: the runtime refuses a path whose canonical form lies
# outside every element of its grant, the same way under `run` and in a built
# binary.  Each engine runs in a fresh copy of one tree: a granted `cfg/`, a secret
# beside it, symlinks out of and into `cfg/`, a dangling symlink whose target lies
# outside, a symlink standing for `cfg/`, and `other/cfg/` for a changed working
# directory.  After each run, nothing the refusals guard may have been created,
# moved or removed.
CONFINE="$FIX/confinement"
confine_tree() {
  rm -rf "$1"
  mkdir -p "$1/cfg/sub" "$1/outdir" "$1/other/cfg" "$1/data"
  printf 'top secret' > "$1/secret.txt"
  printf 'granted' > "$1/cfg/a.txt"
  printf 'other granted' > "$1/other/cfg/a.txt"
  ln -s ../secret.txt "$1/cfg/out"
  ln -s cfg/a.txt "$1/inlink"
  ln -s ../newsecret.txt "$1/cfg/dangling"
  ln -s cfg "$1/link"
}
confine_untouched() {
  for f in newsecret.txt new.txt pwned.txt x.txt outdir/stolen.txt cfg/stolen.txt; do
    [ -e "$1/$f" ] && { echo "$f was created"; return; }
  done
  [ -f "$1/secret.txt" ] && [ -L "$1/inlink" ] || echo "an entry outside cfg/ was removed"
}
# confine_case <fixture> <dir to run from, relative to the tree> <stdout> [panic]
# A multi-module fixture is named by its entry, `<dir>/main`.
# With `panic`, the run must exit nonzero with stderr naming the refusal of
# cfg/../secret.txt.
confine_case() {
  tree="${TMPDIR:-/tmp}/medaka_confine_$$"
  bin="${TMPDIR:-/tmp}/medaka_confine_$$_$(printf '%s' "$1" | tr / _)"
  refusal='runtime error [E-PANIC]: cfg/../secret.txt is outside the granted authority ["cfg/*"]'
  (cd "$FIX" && perl -e 'alarm 180; exec @ARGV' -- "$M" build "$CONFINE/$1.mdk" -o "$bin" >/dev/null 2>&1)
  detail=""
  for engine in run build; do
    confine_tree "$tree"
    if [ "$engine" = run ]; then
      out="$(cd "$tree/$2" && perl -e 'alarm 60; exec @ARGV' -- "$M" run "$CONFINE/$1.mdk" 2>"$tree.err")"
    else
      out="$(cd "$tree/$2" && "$bin" 2>"$tree.err")"
    fi
    status=$?
    err="$(cat "$tree.err")"
    [ "$out" = "$3" ] || detail="$detail $engine printed [$out];"
    if [ "${4:-}" = panic ]; then
      [ "$status" -ne 0 ] || detail="$detail $engine exited 0;"
      case "$err" in
        *"$refusal"*) ;;
        *) detail="$detail $engine stderr [$err];" ;;
      esac
    else
      [ "$status" -eq 0 ] || detail="$detail $engine exited $status [$err];"
    fi
    touched="$(confine_untouched "$tree")"
    [ -z "$touched" ] || detail="$detail $engine: $touched;"
  done
  rm -rf "$tree" "$tree.err" "$bin" "$bin.ll"
  if [ -z "$detail" ]; then ok "confine_$1"; else bad "confine_$1" "$detail"; fi
}
outside='is outside the granted authority'
confine_case paths . "dotdot first: Ok
dotdot middle in: Ok
dotdot middle out: Err cfg/sub/../../secret.txt $outside [\"cfg/*\"]
dotdot last out: Err cfg/../secret.txt $outside [\"cfg/*\"]
symlink out: Err cfg/out $outside [\"cfg/*\"]
symlink in: Ok
new file: Ok
new file read: Ok
new dir: Ok
new file out: Err cfg/../new.txt $outside [\"cfg/*\"]
dangling: Err cfg/dangling $outside [\"cfg/*\"]
dotdot in absent tail: Err cfg/nodir/../../x.txt $outside [\"cfg/*\"]
remove outside link: Err cfg/../inlink $outside [\"cfg/*\"]
remove inside link: Ok
rename dst out: Err cfg/../outdir/stolen.txt $outside [\"cfg/*\"]
rename src out: Err cfg/../secret.txt $outside [\"cfg/*\"]
rename inside: Ok
absolute in: Ok
absolute out: Err /dev/../etc/passwd $outside [\"/dev/*\"]
absent element in: Err No such file or directory
absent element out: Err nowhere/../secret.txt $outside [\"nowhere/*\"]
element symlink in: Ok
element symlink out: Err link/../secret.txt $outside [\"link/*\"]
element dotdot in: Ok
element dotdot out: Err cfg/sub/../../secret.txt $outside [\"cfg/sub/../*\"]"
confine_case shapes . "handle: Err cfg/../secret.txt $outside [\"cfg/*\"]
wrapper: Err cfg/../secret.txt $outside [\"cfg/*\"]
isDir: Err cfg/../outdir $outside [\"cfg/*\"]
app: Err cfg/../secret.txt $outside [\"cfg/*\"]
list: Err cfg/../secret.txt $outside [\"cfg/*\"]
ref: Err cfg/../secret.txt $outside [\"cfg/*\"]
local: Err cfg/../secret.txt $outside [\"cfg/*\"]
delay: Err cfg/../secret.txt $outside [\"cfg/*\"]
existential: Ok
method: Err cfg/../secret.txt $outside [\"cfg/*\"]
poly: Err cfg/../secret.txt $outside [\"cfg/*\"]
partial method: Err cfg/../secret.txt $outside [\"cfg/*\"]
partial write: Err cfg/../pwned.txt $outside [\"cfg/*\"]"
confine_case cwd other "Ok other granted
Err cfg/../../cfg/a.txt $outside [\"cfg/*\"]"
confine_case join . "Ok top secret
Ok granted
Err outdir/../secret.txt $outside [\"cfg/a.txt\", \"outdir/*\"]"
confine_case exists_panic . "True" panic
confine_case canonicalize_panic . "True" panic
# A binding's grants follow its identity, never its spelling: a helper named like
# an interface method or a foreign function anywhere in the graph, an instance
# head index named like a method's binder, an imported redeclaration of a file
# extern, and a method whose type ends in a function alias are each confined.
confine_case names . "append in: Ok
append out: Err cfg/../outdir/stolen.txt $outside [\"cfg/*\"]
sub in: Ok
sub out: Err cfg/../secret.txt $outside [\"cfg/*\"]
log in: Ok
log out: Err cfg/../pwned.txt $outside [\"cfg/*\"]"
confine_case dependency_method/main . "2
Ok granted
Err cfg/../secret.txt $outside [\"cfg/*\"]"
confine_case ffi_stat/main . "4
isFile in: Ok
isFile out: Err cfg/../secret.txt $outside [\"cfg/*\"]
isDir out: Err cfg/../outdir $outside [\"cfg/*\"]
fileSize out: Err cfg/../secret.txt $outside [\"cfg/*\"]"
confine_case indexed_head . "load in: Ok
load out: Err cfg/../secret.txt $outside [\"cfg/*\"]
copy in: Ok
copy src out: Err cfg/../secret.txt $outside [\"cfg/*\"]
copy dst out: Err outdir/../pwned.txt $outside [\"outdir/*\"]"
confine_case redeclared_extern/main . "Ok granted
Err cfg/../secret.txt $outside [\"cfg/*\"]"
confine_case method_named_readfile/main . "2
Ok [\"granted\"]
Err cfg/../secret.txt $outside [\"cfg/*\"]"
confine_case alias_method . "in: Ok granted
out: Err cfg/../secret.txt $outside [\"cfg/*\"]"
# A pattern-ranging binder (`Authority FileWrite*`) extended in a body is
# granted the call site's pattern, and a name climbing out of it is refused.
confine_case pattern_binder . "in: Ok
out: Err data/../pwned.txt $outside [\"data/*\"]"
# A `..` in a path's constant part is refused before any grant exists: the
# checker compares canonical paths, so a `data/*` bound does not cover a write
# under `data/../`, and the program does not check.
out="$(perl -e 'alarm 60; exec @ARGV' -- "$M" check "$CONFINE/constant_dotdot.mdk" 2>&1)"
status=$?
case "$status:$out" in
  1:*'where <FileWrite "data/*"> is allowed, but it performs <FileWrite "./*">'*)
    ok confine_constant_dotdot ;;
  *) bad confine_constant_dotdot "exit $status, got [$out]" ;;
esac

# realpath(3) fails under a working directory longer than PATH_MAX, so no path
# has a canonical form there and each engine refuses every path, granted or not,
# rather than compare the unresolved strings.  The tree is 22 directories of 200
# characters, built and entered one relative component at a time by perl, since
# the shell's `cd` keeps the whole logical path and fails past PATH_MAX.
deep_in() {
  perl -e '$t = shift; chdir $t or die "$t: $!";
    for (1 .. 22) { chdir("d" x 200) or die "$!" }
    alarm 60; exec @ARGV or die "$!"' -- "$@"
}
deep_case() {
  tree="${TMPDIR:-/tmp}/medaka_deep_$$"
  bin="${TMPDIR:-/tmp}/medaka_deep_$$_bin"
  rm -rf "$tree"
  mkdir -p "$tree"
  perl -e 'chdir shift or die "$!";
    for (1 .. 22) { mkdir("d" x 200) or die "$!"; chdir("d" x 200) or die "$!" }
    mkdir "cfg" or die "$!";
    open(my $a, ">", "cfg/a.txt") or die "$!"; print $a "granted"; close $a;
    open(my $s, ">", "secret.txt") or die "$!"; print $s "top secret"; close $s' "$tree"
  (cd "$FIX" && perl -e 'alarm 180; exec @ARGV' -- "$M" build "$CONFINE/deep_cwd.mdk" -o "$bin" >/dev/null 2>&1)
  out_run="$(deep_in "$tree" "$M" run "$CONFINE/deep_cwd.mdk" 2>&1)"
  out_build="$(deep_in "$tree" "$bin" 2>&1)"
  rm -rf "$tree" "$bin" "$bin.ll"
  if [ "$out_run" = "$1" ] && [ "$out_build" = "$1" ]; then
    ok "confine_deep_cwd"
  else
    bad "confine_deep_cwd" "expected [$1], run printed [$out_run], build printed [$out_build]"
  fi
}
deep_case "Err cfg/a.txt $outside [\"cfg/*\"]
Err cfg/../secret.txt $outside [\"cfg/*\"]"

echo

# ── The ledger bites in BOTH directions ───────────────────────────────────────
# A regression fails. An ACCIDENTAL FIX also fails — an XFAIL entry that starts
# passing means the ledger is now a lie, and a lie nobody is forced to notice is
# exactly how a skip-list rots into permanent blindness.
if [ -n "$xfail_fixed" ]; then
  echo "FAIL: these assertions are ledgered as EXPECTED-FAILING, but they now PASS:"
  for a in $xfail_fixed; do echo "       $a"; done
  echo "       They got fixed. DELETE them from XFAIL at the top of this file (and"
  echo "       close the task named in the EXPECTED-FAILURE ledger there)."
  fail=$((fail + 1))
fi

if [ "$fail" -eq 0 ]; then
  echo "native_fixtures: PASS ($xfail_ok known-failing, ledgered)"
else
  echo "native_fixtures: FAILED ($fail)"
fi
exit $fail
