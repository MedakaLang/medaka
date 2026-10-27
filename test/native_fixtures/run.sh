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
out="$(perl -e 'alarm 30; exec @ARGV or die qq(exec: $!)' -- "$M" check "$FIX/bangeq_error.mdk" 2>&1)"
case "$out" in
  *':7: unexpected `!=`; did you mean `/=`?'*)
    ok bangeq_error ;;
  *) bad bangeq_error "got [$out]" ;;
esac

# #3: multiline let RHS + if/then/else checks cleanly (exit 0).
perl -e 'alarm 30; exec @ARGV or die qq(exec: $!)' -- "$M" check "$FIX/let_multiline_rhs_if.mdk" >/dev/null 2>&1
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
perl -e 'alarm 30; exec @ARGV or die qq(exec: $!)' -- "$M" check "$FIX/method_shadow_check.mdk" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  ok method_shadow_check
else
  bad method_shadow_check "check returned non-zero"
fi

# method-name shadow (facet 2): a DIRECT call to the user's shadowing `eq` must
# resolve to the USER's definition on the EVAL path (run), matching build + the
# oracle, even though `List Int` HAS an `Eq` impl (the eval path used to arg-stamp
# the `Eq (List a)` impl → False; the user's `eq` returns True).
out="$(perl -e 'alarm 30; exec @ARGV or die qq(exec: $!)' -- "$M" run "$FIX/method_shadow_run.mdk" 2>&1)"
case "$out" in
  True) ok method_shadow_run ;;
  *) bad method_shadow_run "expected True, got [$out]" ;;
esac

# #62: `record` as a MODULE name (`import record.*`).  This fixture directory
# existed for months with NO assertion referencing it — it was blocked on the
# removed-keyword diagnostic firing on the bare token regardless of position,
# so wiring it up would only have pinned the bug.  Freeing the word unblocked
# it, so it is live now: the import must resolve and the program must run.
out="$(perl -e 'alarm 30; exec @ARGV or die qq(exec: $!)' -- "$M" run "$FIX/keyword_import_record/main.mdk" 2>&1)"
case "$out" in
  "hello from record module") ok keyword_import_record ;;
  *) bad keyword_import_record "expected 'hello from record module', got [$out]" ;;
esac

# inline-let missing-in: located error at the `let` keyword with a hint.
# Before the fix, native reported 2:0 ("if" line) with no hint.
out="$(perl -e 'alarm 30; exec @ARGV or die qq(exec: $!)' -- "$M" check "$FIX/inline_let_missing_in.mdk" 2>&1)"
case "$out" in
  *'inline `let` requires `in`'*)
    ok inline_let_missing_in ;;
  *) bad inline_let_missing_in "got [$out]" ;;
esac

# arrayBlit + arraySetUnsafe in native interpreter: Vector.push triggers both.
# Before the fix: "unbound identifier: arrayBlit" on the 3rd push (first grow).
out="$(perl -e 'alarm 30; exec @ARGV or die qq(exec: $!)' -- "$M" run "$FIX/vector_push.mdk" 2>&1)"
case "$out" in
  ok) ok vector_push ;;
  *) bad vector_push "expected 'ok', got [$out]" ;;
esac

# PARSE-ERROR-LOCATION Stage 1 (caret) + Stage 2 (foreign-syntax hints).
# Each foreign-syntax mistake is located (dodging the old `1:0` collapse) with a
# beginner-grade hint, rendered through the shared caret block (a `^` line).

# Stage 2: C-style brace block on `if` — located at the `{` (col 15) with the hint,
# AND the Stage-1 caret block (the `^` line proves the snippet renderer fired).
out="$(perl -e 'alarm 30; exec @ARGV or die qq(exec: $!)' -- "$M" check "$FIX/brace_block_if.mdk" 2>&1)"
case "$out" in
  *':1:15: Medaka has no `{ ... }` blocks'*'^'*)
    ok brace_block_if ;;
  *) bad brace_block_if "got [$out]" ;;
esac

# Stage 2: `for` loop — located at the `for` keyword with the recursion hint.
out="$(perl -e 'alarm 30; exec @ARGV or die qq(exec: $!)' -- "$M" check "$FIX/for_loop.mdk" 2>&1)"
case "$out" in
  *'Medaka has no `for` loops'*) ok for_loop ;;
  *) bad for_loop "got [$out]" ;;
esac

# Stage 2: `def` function header — located at the `def` keyword with the hint.
out="$(perl -e 'alarm 30; exec @ARGV or die qq(exec: $!)' -- "$M" check "$FIX/def_keyword.mdk" 2>&1)"
case "$out" in
  *':1:0: Medaka has no `def`'*) ok def_keyword ;;
  *) bad def_keyword "got [$out]" ;;
esac

# Stage 2: `/* … */` block comment — located at the `/` with the `{- -}`/`--` hint.
out="$(perl -e 'alarm 30; exec @ARGV or die qq(exec: $!)' -- "$M" check "$FIX/block_comment.mdk" 2>&1)"
case "$out" in
  *'Medaka has no `/* ... */` comments'*)
    ok block_comment ;;
  *) bad block_comment "got [$out]" ;;
esac

# Stage 2: trailing `;` statement terminator — located at the `;` with the hint.
out="$(perl -e 'alarm 30; exec @ARGV or die qq(exec: $!)' -- "$M" check "$FIX/semicolon_stmt.mdk" 2>&1)"
case "$out" in
  *'Medaka has no statement terminator `;`'*)
    ok semicolon_stmt ;;
  *) bad semicolon_stmt "got [$out]" ;;
esac

# EFFECTS-SEMANTICS §8: a file extern receives the authority granted at each use,
# and that argument cannot change a value the program computes — so `run` and a
# built binary print the same thing for every shape a grant reaches a call through.
# Each case runs in its own directory, whose `cfg/a.txt` holds `granted`.
GRANTS="$FIX/authority_grants"
grant_case() {
  out_run="$(cd "$GRANTS" && perl -e 'alarm 60; exec @ARGV or die qq(exec: $!)' -- "$M" run "$1.mdk" 2>&1)"
  bin="${TMPDIR:-/tmp}/medaka_grants_$$_$1"
  (cd "$GRANTS" && perl -e 'alarm 180; exec @ARGV or die qq(exec: $!)' -- "$M" build "$1.mdk" -o "$bin" >/dev/null 2>&1)
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
Ok (echo cfg/a.txt)
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
  mkdir -p "$1/cfg/sub" "$1/outdir/sub" "$1/other/cfg" "$1/data"
  printf 'top secret' > "$1/secret.txt"
  printf 'granted' > "$1/cfg/a.txt"
  printf 'other granted' > "$1/other/cfg/a.txt"
  ln -s ../secret.txt "$1/cfg/out"
  ln -s cfg/a.txt "$1/inlink"
  ln -s ../newsecret.txt "$1/cfg/dangling"
  ln -s cfg "$1/link"
  ln -s ../outdir/sub "$1/cfg/link"
  printf 'outside' > "$1/outdir/sub/a.txt"
  # Two directories whose names are the bytes FE and FF, not UTF-8, each behind a
  # symlink in lossy/w (lossy_names).
  fe="$(printf '\376')"
  ff="$(printf '\377')"
  mkdir -p "$1/lossy/w" "$1/lossy/$fe" "$1/lossy/$ff"
  printf 'granted' > "$1/lossy/$fe/ok.txt"
  printf 'top secret' > "$1/lossy/$ff/secret.txt"
  ln -s "../$fe" "$1/lossy/w/g"
  ln -s "../$ff" "$1/lossy/w/s"
}
confine_untouched() {
  for f in newsecret.txt new.txt pwned.txt x.txt outdir/stolen.txt outdir/sub/stolen.txt cfg/stolen.txt; do
    [ -e "$1/$f" ] && { echo "$f was created"; return; }
  done
  [ -f "$1/secret.txt" ] && [ -L "$1/inlink" ] || echo "an entry outside cfg/ was removed"
}
# The wasmgc/node engine: the host confines a wasm build's file operations
# (playground/medaka_host.mjs), so every fixture whose file externs wasm lowers
# runs there too, with the same expected output.  It needs the wasm emitter
# (test/wasm/build_wasm_oracle.sh) and node; without them the arm is reported
# NOT RUN, and with MEDAKA_REQUIRE_WASM=1 that is a failure.
CONFINE_WASM=' alias_method cwd join exists_panic canonicalize_panic dependency_method/main redeclared_extern/main method_named_readfile/main bounded_recursion declared_bound_read fs_family append_file names paths make_dir remove_file remove_dir fsync file_mode write_file_mode shapes indexed_head user_file_labels pattern_binder grant_bound_joins declared_bound lossy_names '
WASM_EMIT="${MEDAKA_WASM_EMITTER:-$ROOT/test/bin/wasm_emit_modules_main}"
wasm_ok=1
if [ ! -x "$WASM_EMIT" ] || ! command -v node >/dev/null 2>&1; then
  wasm_ok=0
  if [ "${MEDAKA_REQUIRE_WASM:-}" = 1 ]; then
    bad confine_wasm_arm "no wasm emitter at $WASM_EMIT, or no node"
  else
    echo "NOT RUN confine wasm arm: no wasm emitter at $WASM_EMIT, or no node"
  fi
fi
wasm_build() {
  (cd "$FIX" && MEDAKA_WASM_EMITTER="$WASM_EMIT" perl -e 'alarm 180; exec @ARGV or die qq(exec: $!)' -- "$M" build --target wasmgc/node "$1" -o "$2" >/dev/null 2>&1)
}
# confine_case <fixture> <dir to run from, relative to the tree> <stdout> [panic]
# A multi-module fixture is named by its entry, `<dir>/main`.
# With `panic`, the run must exit nonzero with stderr naming the refusal of
# cfg/../secret.txt.
confine_case() {
  tree="${TMPDIR:-/tmp}/medaka_confine_$$"
  bin="${TMPDIR:-/tmp}/medaka_confine_$$_$(printf '%s' "$1" | tr / _)"
  refusal='runtime error [E-PANIC]: cfg/../secret.txt is outside the granted authority ["cfg/*"]'
  (cd "$FIX" && perl -e 'alarm 180; exec @ARGV or die qq(exec: $!)' -- "$M" build "$CONFINE/$1.mdk" -o "$bin" >/dev/null 2>&1)
  detail=""
  engines='run build'
  [ "${4:-}" = native ] && engines=build
  case "$CONFINE_WASM" in
    *" $1 "*) [ "$wasm_ok" -eq 1 ] && engines="$engines wasm" ;;
  esac
  case "$engines" in *wasm*) wasm_build "$CONFINE/$1.mdk" "$bin.wasm" ;; esac
  for engine in $engines; do
    confine_tree "$tree"
    if [ "$engine" = run ]; then
      out="$(cd "$tree/$2" && perl -e 'alarm 60; exec @ARGV or die qq(exec: $!)' -- "$M" run "$CONFINE/$1.mdk" 2>"$tree.err")"
    elif [ "$engine" = wasm ]; then
      out="$(cd "$tree/$2" && perl -e 'alarm 60; exec @ARGV or die qq(exec: $!)' -- node "$ROOT/test/wasm/run.js" "$bin.wasm" 2>"$tree.err")"
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
  rm -rf "$tree" "$tree.err" "$bin" "$bin.ll" "$bin.wasm"
  if [ -z "$detail" ]; then ok "confine_$1"; else bad "confine_$1" "$detail"; fi
}
outside='is outside the granted authority'
# The read-side twin of declared_bound, written with externs wasm lowers: nested
# bounds, a helper, a delayed and a stored callback, mode independence, and a
# bound re-entered by non-tail recursion.
confine_case declared_bound_read . "read: Err cfg/link/a.txt $outside [\"cfg/*\"]
helper: Err cfg/link/a.txt $outside [\"cfg/*\"]
inner: Ok
outer: Err cfg/link/a.txt $outside [\"cfg/*\"]
delay: Err cfg/link/a.txt $outside [\"cfg/*\"]
packed: Err cfg/link/a.txt $outside [\"cfg/*\"]
read under write: Ok
write under write: Err cfg/link/stolen.txt $outside [\"cfg/*\"]
write under read: Ok
3
restored: Ok"
confine_case declared_bound . "direct: Err cfg/link/stolen.txt $outside [\"cfg/*\"]
dotdot: Err cfg/link/../stolen.txt $outside [\"cfg/link/*\"]
helper: Err cfg/link/stolen.txt $outside [\"cfg/*\"]
alias: Err cfg/link/stolen.txt $outside [\"cfg/*\"]
read: Err cfg/link/a.txt $outside [\"cfg/*\"]
inside: Ok
delay: Err cfg/link/stolen.txt $outside [\"cfg/*\"]
delay alias: Err cfg/link/stolen.txt $outside [\"cfg/*\"]
packed: Err cfg/link/stolen.txt $outside [\"cfg/*\"]
method: Err cfg/link/stolen.txt $outside [\"cfg/*\"]
union: Ok
explicit link: Ok
restored: Ok"
# The wasm engine runs it too: a non-tail call at this depth overflows its stack.
confine_case bounded_recursion . "True" native
# writeFile, rename, listDir and statFile: each refuses an escape in the mode native
# confines it in (rename both paths, the source first), and a bound a wide row cannot lift.
confine_case fs_family . "list cfg: Ok [a.txt, dangling, link, out, sub]
list sub: Ok []
list up: Err cfg/../outdir $outside [\"cfg/*\"]
list link: Err cfg/link $outside [\"cfg/*\"]
list absent: Err (host)
list file: Err (host)
stat file: Ok size=7 isDir=False isFile=True
stat dir: Ok size=- isDir=True isFile=False
stat inside link: Ok size=7 isDir=False isFile=True
stat up: Err cfg/../secret.txt $outside [\"cfg/*\"]
stat link out: Err cfg/out $outside [\"cfg/*\"]
stat absent: Err (host)
write new: Ok
write inside: Ok
write up: Err cfg/../new.txt $outside [\"cfg/*\"]
write link out: Err cfg/out $outside [\"cfg/*\"]
write dangling: Err cfg/dangling $outside [\"cfg/*\"]
write dir: Err (host)
move: Ok
move back: Ok
move over: Ok
move absent: Err (host)
move dst out: Err cfg/../outdir/stolen.txt $outside [\"cfg/*\"]
move src out: Err cfg/../secret.txt $outside [\"cfg/*\"]
move both out: Err cfg/../secret.txt $outside [\"cfg/*\"]
move symlink: Ok
move across: Ok
move across back: Ok
move across wrong way: Err outdir/../secret.txt $outside [\"outdir/*\"]
after: Ok [b.txt, out]
bound move: Err cfg/link/a.txt $outside [\"cfg/*\"]
bound write: Err cfg/link/stolen.txt $outside [\"cfg/*\"]
bound list: Err cfg/link/ $outside [\"cfg/*\"]
bound stat: Err cfg/link/a.txt $outside [\"cfg/*\"]"
# appendFile: the write mode of writeFile, the bound through a wide row, and an OS error.
confine_case append_file . "inside: Ok
inside read: Ok granted+x
new: Ok
new read: Ok +x
sub: Ok
up: Err cfg/../outdir/stolen.txt $outside [\"cfg/*\"]
link out: Err cfg/out $outside [\"cfg/*\"]
dangling: Err cfg/dangling $outside [\"cfg/*\"]
dir: Err (host)
absent dir: Err (host)
bound append: Err cfg/link/stolen.txt $outside [\"cfg/*\"]"
# makeDir confines in entry mode: a link as the last component is the entry, which
# exists already, so it is never made through.
confine_case make_dir . "make new: Ok
make inside new: Ok
make new again: Err (host)
make existing: Err (host)
make file: Err (host)
make up: Err cfg/../outdir/stolen.txt $outside [\"cfg/*\"]
make link: Err (host)
make link out: Err (host)
make dangling: Err (host)
make absent parent: Err (host)
make through link: Err cfg/link/stolen.txt $outside [\"cfg/*\"]
bound make: Err cfg/link/stolen.txt $outside [\"cfg/*\"]"
# removeFile and removeDir confine in entry mode: a link as the last component is the
# entry (removed, or ENOTDIR for rmdir), and a link before it is followed.
confine_case remove_file . "remove a: Ok
remove a again: Err (host)
remove up: Err cfg/../secret.txt $outside [\"cfg/*\"]
remove link: Ok
remove dangling: Ok
remove dir: Err (host)
remove absent dir: Err (host)
remove through link: Err cfg/link/a.txt $outside [\"cfg/*\"]
bound remove: Err cfg/link/stolen.txt $outside [\"cfg/*\"]"
confine_case remove_dir . "remove sub: Ok
remove sub again: Err (host)
remove file: Err (host)
remove link: Err (host)
remove up: Err cfg/../outdir $outside [\"cfg/*\"]
remove absent: Err (host)
remove through link: Err cfg/link/sub $outside [\"cfg/*\"]
bound remove: Err cfg/link/sub $outside [\"cfg/*\"]"
# fsync follows its last component, as writeFile does, and flushes a directory too.
confine_case fsync . "flush file: Ok
flush dir: Ok
flush up: Err cfg/../secret.txt $outside [\"cfg/*\"]
flush link out: Err cfg/out $outside [\"cfg/*\"]
flush dangling: Err cfg/dangling $outside [\"cfg/*\"]
flush absent: Err (host)
flush through link: Err cfg/link/a.txt $outside [\"cfg/*\"]
bound flush: Err cfg/link/stolen.txt $outside [\"cfg/*\"]"
# fileMode follows its last component, as statFile does; the bits themselves are the
# umask's, so a success prints only that they lie in 0 to 4095.
confine_case file_mode . "mode file: Ok in range
mode dir: Ok in range
mode inside link: Ok in range
mode up: Err cfg/../secret.txt $outside [\"cfg/*\"]
mode link out: Err cfg/out $outside [\"cfg/*\"]
mode dangling: Err cfg/dangling $outside [\"cfg/*\"]
mode absent: Err (host)
mode through link: Err cfg/link/a.txt $outside [\"cfg/*\"]
bound mode: Err cfg/link/stolen.txt $outside [\"cfg/*\"]"
# writeFileMode writes as writeFile does, and leaves the file at exactly the mode given.
confine_case write_file_mode . "new: Ok
new mode: Ok 384
overwrite: Ok
overwrite mode: Ok 420
inside sub: Ok
up: Err cfg/../new2.txt $outside [\"cfg/*\"]
link out: Err cfg/out $outside [\"cfg/*\"]
dangling: Err cfg/dangling $outside [\"cfg/*\"]
dir: Err (host)
absent dir: Err (host)
through link: Err cfg/link/a.txt $outside [\"cfg/*\"]
bound write: Err cfg/link/stolen.txt $outside [\"cfg/*\"]"
confine_case user_file_labels . "Ok granted
Ok ()"
confine_case grant_bound_joins . "Ok ()
Ok ()
Ok ()"
# A container cannot acquire a new physical file bound by covariance. The
# diagnostic must reach all three production verbs before any file is opened.
for fixture in nested_value nested_widen aggregate_widen compose recursive_aggregate nested_scope polymorphic_container; do
  detail=""
  for verb in check run build; do
    tree="${TMPDIR:-/tmp}/medaka_confine_reject_$$"
    confine_tree "$tree"
    src="$CONFINE/reject_$fixture.mdk"
    out="$(cd "$tree" && "$M" "$verb" --json "$src" 2>&1)"
    status=$?
    [ "$status" -ne 0 ] || detail="$detail $verb accepted;"
    case "$out" in
      *'"code":"T-FILE-BOUND-VALUE"'*) ;;
      *) detail="$detail $verb missing container-bound diagnostic [$out];" ;;
    esac
    [ -z "$(find "$tree/outdir" -type f ! -name a.txt -print)" ] || detail="$detail $verb wrote outside cfg/;"
    rm -rf "$tree"
  done
  if [ -z "$detail" ]; then ok "confine_reject_$fixture"; else bad "confine_reject_$fixture" "$detail"; fi
done
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
absent element in: Err (host)
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
confine_case cwd other "Ok (other granted)
Err (cfg/../../cfg/a.txt $outside [\"cfg/*\"])"
confine_case join . "Ok (top secret)
Ok granted
Err (outdir/../secret.txt $outside [\"cfg/a.txt\", \"outdir/*\"])"
confine_case exists_panic . "True" panic
confine_case canonicalize_panic . "True" panic
# canonicalizePath answers the same absolute path on every engine: `.` dropped,
# `..` and a symlink resolved, and a path with no canonical form unchanged.
canon_case() {
  tree="${TMPDIR:-/tmp}/medaka_canon_$$"
  bin="${TMPDIR:-/tmp}/medaka_canon_$$_bin"
  src="$CONFINE/canonicalize_dots.mdk"
  (cd "$FIX" && perl -e 'alarm 180; exec @ARGV or die qq(exec: $!)' -- "$M" build "$src" -o "$bin" >/dev/null 2>&1)
  engines='run build'
  if [ "$wasm_ok" -eq 1 ]; then
    engines="$engines wasm"
    wasm_build "$src" "$bin.wasm"
  fi
  confine_tree "$tree"
  phys="$(cd "$tree" && pwd -P)"
  want="$phys/cfg/a.txt
$phys/cfg/a.txt
cfg/../nowhere/./x.txt"
  detail=""
  for engine in $engines; do
    case "$engine" in
      run) out="$(cd "$tree" && perl -e 'alarm 60; exec @ARGV or die qq(exec: $!)' -- "$M" run "$src" 2>&1)" ;;
      build) out="$(cd "$tree" && "$bin" 2>&1)" ;;
      wasm) out="$(cd "$tree" && perl -e 'alarm 60; exec @ARGV or die qq(exec: $!)' -- node "$ROOT/test/wasm/run.js" "$bin.wasm" 2>&1)" ;;
    esac
    [ "$out" = "$want" ] || detail="$detail $engine printed [$out];"
  done
  rm -rf "$tree" "$bin" "$bin.ll" "$bin.wasm"
  if [ -z "$detail" ]; then ok confine_canonicalize_dots; else bad confine_canonicalize_dots "$detail"; fi
}
canon_case
# Canonical paths compare as bytes: names that are not UTF-8 stay distinct.  The
# interpreter's confinePath (compiler/eval/eval.mdk) compares canonicalizePath's
# U+FFFD text instead and admits the escape, so `run` is not an engine here.
confine_case lossy_names lossy/w "inside: Ok granted
escape: Err g/../w/s/secret.txt $outside [\"g/*\"]
True
True" native
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
# A `..` in a path's constant part is refused before any grant exists: a `..`
# after a named component is never within a narrower bound, so a `data/*` bound
# does not cover a write under `data/../`, and the program does not check.
out="$(perl -e 'alarm 60; exec @ARGV or die qq(exec: $!)' -- "$M" check "$CONFINE/constant_dotdot.mdk" 2>&1)"
status=$?
case "$status:$out" in
  1:*'performs <FileWrite "data/../*"> where only <FileWrite "data/*"> is allowed'*)
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
  (cd "$FIX" && perl -e 'alarm 180; exec @ARGV or die qq(exec: $!)' -- "$M" build "$CONFINE/deep_cwd.mdk" -o "$bin" >/dev/null 2>&1)
  out_run="$(deep_in "$tree" "$M" run "$CONFINE/deep_cwd.mdk" 2>&1)"
  out_build="$(deep_in "$tree" "$bin" 2>&1)"
  out_wasm="$1"
  if [ "$wasm_ok" -eq 1 ]; then
    wasm_build "$CONFINE/deep_cwd.mdk" "$bin.wasm"
    out_wasm="$(deep_in "$tree" node "$ROOT/test/wasm/run.js" "$bin.wasm" 2>&1)"
  fi
  rm -rf "$tree" "$bin" "$bin.ll" "$bin.wasm"
  if [ "$out_run" = "$1" ] && [ "$out_build" = "$1" ] && [ "$out_wasm" = "$1" ]; then
    ok "confine_deep_cwd"
  else
    bad "confine_deep_cwd" "expected [$1], run printed [$out_run], build printed [$out_build], wasm printed [$out_wasm]"
  fi
}
deep_case "Err (cfg/a.txt $outside [\"cfg/*\"])
Err (cfg/../secret.txt $outside [\"cfg/*\"])"

# ── stdin ────────────────────────────────────────────────────────────────────
# The four readers share one buffer on native and on wasmgc/node, so the same
# stdin bytes give the same trace on both.  `readers` prints each read as it
# happens; an input is given to printf as a format, so `\r`, `\303` and the
# like are bytes.  The first input's trace is also pinned here from the readers'
# semantics (a line ends at \n only, readExactly 3 starts where the line reader
# stopped, a short readExactly is None and consumes the rest).
stdin_case() {
  bin="${TMPDIR:-/tmp}/medaka_stdin_$$"
  (cd "$FIX" && perl -e 'alarm 180; exec @ARGV or die qq(exec: $!)' -- "$M" build "$FIX/stdin/readers.mdk" -o "$bin" >/dev/null 2>&1)
  engines=build
  if [ "$wasm_ok" -eq 1 ]; then
    wasm_build "$FIX/stdin/readers.mdk" "$bin.wasm"
    engines="build wasm"
  fi
  detail=""
  for input in 'abc\ndef\nghijkl\nmn\nop\nqr\n' '' 'x' 'a\r\nb\r\nc' 'h\303\251llo\n\342\202\254uro\nxyz\n\377\n' 'BIG'; do
    printf "${input}" > "$bin.in"
    # 100 KB over 1 line, then 3000 more of 33 bytes: the host refills many times
    [ "$input" = BIG ] && perl -e 'print "q" x 100000, "\n"; print "line $_ " . "z" x 24 . "\n" for 1 .. 3000; print "tail"' > "$bin.in"
    native_out="$("$bin" < "$bin.in" 2>&1)"
    for engine in $engines; do
      [ "$engine" = build ] && continue
      wasm_out="$(perl -e 'alarm 60; exec @ARGV or die qq(exec: $!)' -- node "$ROOT/test/wasm/run.js" "$bin.wasm" < "$bin.in" 2>&1)"
      [ "$wasm_out" = "$native_out" ] || detail="$detail wasm differs on [$input]: [$wasm_out] vs native [$native_out];"
    done
    if [ "$input" = 'abc\ndef\nghijkl\nmn\nop\nqr\n' ]; then
      want='readLine 3/3/96354 "abc"
readLineOpt Some 3/3/99333 "def"
readExactly 3 Some 3/3/102312 "ghi"
readLineOpt Some 3/3/105291 "jkl"
readAll 9/9/340112 "mn\nop\nqr\n"
readExactly 2 None
readLine 0/0/0 ""
readLineOpt None
readExactly 0 Some 0/0/0 ""
readAll 0/0/0 ""'
      [ "$native_out" = "$want" ] || detail="$detail native on [$input] printed [$native_out];"
    fi
  done
  rm -rf "$bin" "$bin.ll" "$bin.wasm" "$bin.in"
  if [ -z "$detail" ]; then ok stdin_readers; else bad stdin_readers "$detail"; fi
}
stdin_case

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
