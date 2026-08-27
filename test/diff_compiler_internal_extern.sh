#!/bin/sh
# Internal-extern access gate: a module that is NOT part of the standard library
# may not reference the internal-only array-kernel externs (arrayGetUnsafe,
# arraySetUnsafe, arrayBlit, arrayFill, arraySortInPlaceBy) unless the compile
# passes `--allow-internal`.  The trust signal is the loader's owning-root
# (stdlib modules are always trusted) plus the `--allow-internal` opt-in for the
# entry project's own modules.
#
# Legs (all on the real ./medaka CLI; never rebuilds it — see the diff_native_cli
# stale-binary footgun):
#   1. check-reject:   user file using arrayGetUnsafe → InternalExternAccess, exit 1.
#   2. check-allow:    same file with --allow-internal → clean (exit 0).
#   3. run-allow:      `run --allow-internal` evaluates it (prints the value).
#   4. run-reject:     `run` (no flag) → InternalExternAccess, exit 1.
#   5. build-reject:   `build` (no flag) → rejected, no binary emitted.
#   6. build-allow:    `build --allow-internal` → succeeds, runs.
#   7. stdlib-trust:   a user program importing `array` (whose body uses the
#                      externs) resolves clean WITHOUT the flag — no false positive.
#   8. fallthrough-ok: a user program with guard fallthrough (desugar emits
#                      `__fallthrough__`) is NOT flagged.
#   9. self-check-rel: `medaka check` on a REAL stdlib file, by its RELATIVE
#                      path from the repo root (e.g. `stdlib/array.mdk`, no
#                      non-core imports ⇒ the single-module route), resolves
#                      clean WITHOUT `--allow-internal` — a check-usability
#                      papercut fix (was: the single-module CLI route ignored
#                      the already-computed owning-root trust list, AND that
#                      list's root comparison broke on a relative-path root).
#  10. self-check-abs: same file, by its ABSOLUTE path — also clean.
#  11. project-reject:     a multi-module project with a plain `medaka.toml` and
#                          no flag → REJECTED.  #1713's fail-open cell: having a
#                          manifest at all used to grant the whole entry project
#                          the privilege, silently, exit 0.
#  12. project-allow-flag: the same project with `--allow-internal` → clean.
#                          Proves the flag is not a no-op on the project route.
#  13. project-optin:      the same project whose manifest declares
#                          `allow-internal = true`, no flag → clean.  The
#                          load-bearing leg: the discriminator is the KEY.
#  14. dep-name-not-optin: a `[dependencies]` entry named `allow-internal` is a
#                          dep, not the opt-in → still REJECTED.
#  15. compiler-self-check: `medaka check compiler/support/util.mdk` (11 real
#                          arrayGetUnsafe call sites) with no flag → clean.
#                          #42's cell, bought by `compiler/medaka.toml`'s key.
#
# Usage:  sh test/diff_compiler_internal_extern.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
. "$ROOT/test/lib_stale_warning.sh"

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# A user file that references an internal-only extern directly.
cat > "$TMP/u.mdk" <<'EOF'
main = println (arrayGetUnsafe 0 (arrayFromList [1, 2, 3]))
EOF

# 1. check-reject: no flag → InternalExternAccess error + exit 1.
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/u.mdk" 2>&1)"
code=$?
clean="$(mdk_strip_stale "$out")"
case "$clean" in
  *"internal-only primitive"*) if [ "$code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   check-reject (InternalExternAccess, exit 1)\n'
                  else fail=$((fail+1)); printf 'FAIL check-reject (flagged but exit %d)%s\n' "$code" "$(mdk_stale_suffix "$out")"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL check-reject (not flagged: [%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
esac

# 2. check-allow: --allow-internal → clean (exit 0, no internal-only diagnostic).
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check --allow-internal "$TMP/u.mdk" 2>&1)"
code=$?
clean="$(mdk_strip_stale "$out")"
case "$clean" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL check-allow (still flagged: [%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
  *) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   check-allow (suppressed, exit 0)\n'
     else fail=$((fail+1)); printf 'FAIL check-allow (exit %d: [%s])%s\n' "$code" "$out" "$(mdk_stale_suffix "$out")"; fi ;;
esac

# 3. run-allow: --allow-internal evaluates it (prints 1).
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run --allow-internal "$TMP/u.mdk" 2>&1)"
code=$?
clean="$(mdk_strip_stale "$out")"
case "$clean" in
  1*) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   run-allow (prints 1)%s\n' "$(mdk_stale_suffix "$out")"
      else fail=$((fail+1)); printf 'FAIL run-allow (printed but exit %d)%s\n' "$code" "$(mdk_stale_suffix "$out")"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL run-allow ([%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
esac

# 4. run-reject: run (no flag) → InternalExternAccess + exit 1.
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/u.mdk" 2>&1)"
code=$?
clean="$(mdk_strip_stale "$out")"
case "$clean" in
  *"internal-only primitive"*) if [ "$code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   run-reject (InternalExternAccess, exit 1)\n'
                  else fail=$((fail+1)); printf 'FAIL run-reject (flagged but exit %d)%s\n' "$code" "$(mdk_stale_suffix "$out")"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL run-reject (not flagged: [%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
esac

# 5. build-reject: build (no flag) → rejected, no binary emitted.
rm -f "$TMP/u.out"
MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$ROOT/medaka_emitter" bound "$MEDAKA" build "$TMP/u.mdk" -o "$TMP/u.out" >/dev/null 2>&1
code=$?
if [ "$code" -ne 0 ] && [ ! -x "$TMP/u.out" ]; then
  pass=$((pass+1)); printf 'ok   build-reject (no binary, exit %d)\n' "$code"
else
  fail=$((fail+1)); printf 'FAIL build-reject (exit %d, binary present=%s)\n' "$code" "$([ -x "$TMP/u.out" ] && echo yes || echo no)"
fi

# 6. build-allow: build --allow-internal → succeeds, runs and prints 1.
rm -f "$TMP/u.out"
MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$ROOT/medaka_emitter" bound "$MEDAKA" build --allow-internal "$TMP/u.mdk" -o "$TMP/u.out" >/dev/null 2>&1
code=$?
if [ "$code" -eq 0 ] && [ -x "$TMP/u.out" ]; then
  rout="$("$TMP/u.out" 2>&1)"
  case "$rout" in
    1*) pass=$((pass+1)); printf 'ok   build-allow (binary runs, prints 1)\n' ;;
    *) fail=$((fail+1)); printf 'FAIL build-allow (binary ran: [%s])\n' "$rout" ;;
  esac
else
  fail=$((fail+1)); printf 'FAIL build-allow (exit %d, binary present=%s)\n' "$code" "$([ -x "$TMP/u.out" ] && echo yes || echo no)"
fi

# 7. stdlib-trust: a user file importing `array` (whose body uses the internal
#    externs) resolves clean WITHOUT --allow-internal — array.mdk is stdlib-owned
#    so it is always trusted; only the USER module is restricted.
cat > "$TMP/usearr.mdk" <<'EOF'
import array

main = println (arrayLength (arrayFromList [1, 2, 3]))
EOF
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/usearr.mdk" 2>&1)"
code=$?
clean="$(mdk_strip_stale "$out")"
case "$clean" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL stdlib-trust (false positive on array.mdk: [%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
  3*) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   stdlib-trust (array import resolves clean)%s\n' "$(mdk_stale_suffix "$out")"
      else fail=$((fail+1)); printf 'FAIL stdlib-trust (printed but exit %d)%s\n' "$code" "$(mdk_stale_suffix "$out")"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL stdlib-trust ([%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
esac

# 8. fallthrough-ok: a program with guard fallthrough (desugar emits the
#    compiler-generated `__fallthrough__` name) must NOT be flagged — it is
#    deliberately excluded from the internal-extern set.
cat > "$TMP/guard.mdk" <<'EOF'
classify : Int -> String
classify n
  | n > 0 = "pos"
  | n < 0 = "neg"
  | otherwise = "zero"

main = println (classify 5)
EOF
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/guard.mdk" 2>&1)"
code=$?
clean="$(mdk_strip_stale "$out")"
case "$clean" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL fallthrough-ok (false positive on __fallthrough__: [%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
  pos*) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   fallthrough-ok (guard fallthrough not flagged)%s\n' "$(mdk_stale_suffix "$out")"
        else fail=$((fail+1)); printf 'FAIL fallthrough-ok (printed but exit %d)%s\n' "$code" "$(mdk_stale_suffix "$out")"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL fallthrough-ok ([%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
esac

# 9. self-check-rel: `medaka check stdlib/array.mdk` (relative path, run with
#    cwd=$ROOT) — a genuine stdlib file that itself calls arrayGetUnsafe —
#    must resolve clean with NO flag.
out="$(cd "$ROOT" && MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check stdlib/array.mdk 2>&1)"
code=$?
clean="$(mdk_strip_stale "$out")"
case "$clean" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL self-check-rel (false positive on stdlib/array.mdk: [%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
  *) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   self-check-rel (stdlib/array.mdk clean, relative path, no flag)%s\n' "$(mdk_stale_suffix "$out")"
     else fail=$((fail+1)); printf 'FAIL self-check-rel (exit %d: [%s])%s\n' "$code" "$out" "$(mdk_stale_suffix "$out")"; fi ;;
esac

# 10. self-check-abs: same file, absolute path — also clean with no flag.
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$ROOT/stdlib/array.mdk" 2>&1)"
code=$?
clean="$(mdk_strip_stale "$out")"
case "$clean" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL self-check-abs (false positive on stdlib/array.mdk: [%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
  *) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   self-check-abs (stdlib/array.mdk clean, absolute path, no flag)%s\n' "$(mdk_stale_suffix "$out")"
     else fail=$((fail+1)); printf 'FAIL self-check-abs (exit %d: [%s])%s\n' "$code" "$out" "$(mdk_stale_suffix "$out")"; fi ;;
esac

# ── #1713: a `medaka.toml` is not itself a grant of privilege ────────────────
# Legs 11–15 pin the manifest OPT-IN.  Before #1713 was fixed, merely having a
# `medaka.toml` made every module of the entry project trusted, so the guard
# evaporated the moment a scratch file graduated into a real project and
# `--allow-internal` became a documented no-op on that entire path.  The rule is
# now: stdlib always, plus an entry project whose manifest SAYS `allow-internal
# = true`.  Leg 13 is the load-bearing one — without it, leg 11 could be passing
# for any reason at all (a broken project route, a bad path comparison) rather
# than because the key is absent.
mkdir -p "$TMP/proj"
cat > "$TMP/proj/helper.mdk" <<'EOF'
import array.*

export
peek : String -> String
peek s = charToStr (arrayGetUnsafe 0 (stringToChars s))
EOF
cat > "$TMP/proj/main.mdk" <<'EOF'
import helper.{peek}

main = println (peek "hi")
EOF

# 11. project-reject: a multi-module project, NO manifest opt-in, NO flag →
#     rejected.  This is #1713's cell 3; it silently ACCEPTED (exit 0) before.
printf 'name = "probe"\nversion = "0.0.1"\n' > "$TMP/proj/medaka.toml"
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/proj/main.mdk" 2>&1)"
code=$?
clean="$(mdk_strip_stale "$out")"
case "$clean" in
  *"internal-only primitive"*) if [ "$code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   project-reject (manifest alone grants nothing, exit 1)\n'
                  else fail=$((fail+1)); printf 'FAIL project-reject (flagged but exit %d)%s\n' "$code" "$(mdk_stale_suffix "$out")"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL project-reject (not flagged — #1713 fail-open: [%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
esac

# 12. project-allow-flag: the SAME project with --allow-internal → accepted.
#     Proves the flag is not a no-op on the project route (it was, before).
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check --allow-internal "$TMP/proj/main.mdk" 2>&1)"
code=$?
clean="$(mdk_strip_stale "$out")"
case "$clean" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL project-allow-flag (still flagged: [%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
  *) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   project-allow-flag (flag is non-no-op on a project, exit 0)\n'
     else fail=$((fail+1)); printf 'FAIL project-allow-flag (exit %d: [%s])%s\n' "$code" "$out" "$(mdk_stale_suffix "$out")"; fi ;;
esac

# 13. project-optin: the SAME project whose manifest declares the privilege, NO
#     flag → accepted.  The discriminator is the KEY, not anything incidental.
printf 'name = "probe"\nversion = "0.0.1"\nallow-internal = true\n' > "$TMP/proj/medaka.toml"
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/proj/main.mdk" 2>&1)"
code=$?
clean="$(mdk_strip_stale "$out")"
case "$clean" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL project-optin (opt-in ignored: [%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
  *) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   project-optin (allow-internal = true grants it, exit 0)\n'
     else fail=$((fail+1)); printf 'FAIL project-optin (exit %d: [%s])%s\n' "$code" "$out" "$(mdk_stale_suffix "$out")"; fi ;;
esac

# 14. dep-name-not-optin: a DEPENDENCY literally named `allow-internal` is a
#     `name = "path"` line, not the opt-in.  Pins the scanner's [dependencies]
#     skip; without it the key check would fire on any dep of that name.
printf 'name = "probe"\nversion = "0.0.1"\n\n[dependencies]\nallow-internal = "true"\n' > "$TMP/proj/medaka.toml"
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/proj/main.mdk" 2>&1)"
code=$?
clean="$(mdk_strip_stale "$out")"
case "$clean" in
  *"internal-only primitive"*) pass=$((pass+1)); printf 'ok   dep-name-not-optin (a dep named allow-internal grants nothing)\n' ;;
  *) fail=$((fail+1)); printf 'FAIL dep-name-not-optin (a [dependencies] entry read as the opt-in: exit %d [%s])%s\n' "$code" "$out" "$(mdk_stale_suffix "$out")" ;;
esac

# 15. compiler-self-check: #42's cell.  `medaka check` on a compiler-project file
#     that really does call the kernels (compiler/support/util.mdk has 11
#     arrayGetUnsafe call sites) must stay clean with NO flag — that is what
#     `compiler/medaka.toml`'s own `allow-internal = true` buys, and it is the
#     regression a stdlib-only rule would cause.
out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$ROOT/compiler/support/util.mdk" 2>&1)"
code=$?
clean="$(mdk_strip_stale "$out")"
case "$clean" in
  *"internal-only primitive"*) fail=$((fail+1)); printf 'FAIL compiler-self-check (#42 regression: [%s])%s\n' "$out" "$(mdk_stale_suffix "$out")" ;;
  *) if [ "$code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   compiler-self-check (compiler/support/util.mdk clean, no flag)%s\n' "$(mdk_stale_suffix "$out")"
     else fail=$((fail+1)); printf 'FAIL compiler-self-check (exit %d: [%s])%s\n' "$code" "$out" "$(mdk_stale_suffix "$out")"; fi ;;
esac

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
