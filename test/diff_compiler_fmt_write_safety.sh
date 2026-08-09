#!/bin/sh
# test/diff_compiler_fmt_write_safety.sh — CLI-surface DX regression gate (#1348).
#
# THE BUG: bare `medaka fmt <file>` rewrote the file IN PLACE, printed NOTHING, and
# exited 0 — a destructive default indistinguishable from a no-op. It once silently
# reformatted ~500 tracked files. `medaka fmt --help` also errored with "unknown
# flag: --help" (every OTHER subcommand had the same hole), so the safe --stdout
# form was undiscoverable from the CLI itself.
#
# THE FIX: writing now REQUIRES --write. Bare `medaka fmt <path>...` is read-only
# (equivalent to --check: reports which files are not formatted, never touches
# them). --write is the only mutating mode, and it prints a one-line summary of
# what it did ("formatted N file(s)" / "already formatted"), so a write can never
# again produce zero observable output. Every `medaka <sub> --help`/`-h` now prints
# that subcommand's own flags instead of falling into its positional-arg parser.
#
# This is a differential-free BEHAVIOR gate (no golden corpus) — each check is a
# direct assertion against the real ./medaka binary: file-unchanged (checksum),
# exit code, and stdout content.
#
# Usage:  sh test/diff_compiler_fmt_write_safety.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# $MEDAKA honoured for local runs against a borrowed/pre-built binary; CI (which
# builds ./medaka before running gates) falls back to $ROOT/medaka.
MEDAKA="${MEDAKA:-$ROOT/medaka}"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

sum() {
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'
  else md5 -q "$1"; fi
}

# ── 1. bare `fmt <file>` never mutates ──────────────────────────────────────
UNFMT="$TMP/unfmt.mdk"
printf 'main    =\n  println   1\n' > "$UNFMT"
before="$(sum "$UNFMT")"
"$MEDAKA" fmt "$UNFMT" >"$TMP/bare.out" 2>"$TMP/bare.err"
bare_rc=$?
after="$(sum "$UNFMT")"
if [ "$before" = "$after" ]; then ok "bare fmt: file byte-identical"
else bad "bare fmt: file byte-identical" "checksum changed ($before -> $after) — bare fmt MUTATED the file"; fi
if [ "$bare_rc" = "1" ]; then ok "bare fmt: exit 1 on unformatted input"
else bad "bare fmt: exit 1 on unformatted input" "exit was $bare_rc"; fi

# ── 2. bare `fmt <file>` on ALREADY-formatted input: silent, exit 0, never mutates ──
FMTD="$TMP/fmtd.mdk"
printf 'main = println 1\n' > "$FMTD"
before2="$(sum "$FMTD")"
"$MEDAKA" fmt "$FMTD" >"$TMP/bare2.out" 2>"$TMP/bare2.err"
bare2_rc=$?
after2="$(sum "$FMTD")"
if [ "$before2" = "$after2" ]; then ok "bare fmt (already formatted): file byte-identical"
else bad "bare fmt (already formatted): file byte-identical" "checksum changed"; fi
if [ "$bare2_rc" = "0" ]; then ok "bare fmt (already formatted): exit 0"
else bad "bare fmt (already formatted): exit 0" "exit was $bare2_rc"; fi

# ── 3. `--write` mutates AND prints a one-line summary ──────────────────────
WR="$TMP/write.mdk"
printf 'main    =\n  println   1\n' > "$WR"
before3="$(sum "$WR")"
out3="$("$MEDAKA" fmt --write "$WR" 2>"$TMP/write.err")"
wr_rc=$?
after3="$(sum "$WR")"
if [ "$before3" != "$after3" ]; then ok "--write: file WAS rewritten"
else bad "--write: file WAS rewritten" "checksum unchanged — --write did not mutate"; fi
if [ "$wr_rc" = "0" ]; then ok "--write: exit 0 on success"
else bad "--write: exit 0 on success" "exit was $wr_rc"; fi
case "$out3" in
  *"formatted 1 file"*) ok "--write: prints a summary line" ;;
  *) bad "--write: prints a summary line" "stdout was: [$out3]" ;;
esac

# ── 4. `--write` again on the now-formatted file: no mutation, "already formatted" ──
before4="$(sum "$WR")"
out4="$("$MEDAKA" fmt --write "$WR" 2>"$TMP/write2.err")"
after4="$(sum "$WR")"
if [ "$before4" = "$after4" ]; then ok "--write (idempotent): file byte-identical on 2nd run"
else bad "--write (idempotent): file byte-identical on 2nd run" "checksum changed on a no-op write"; fi
case "$out4" in
  *"already formatted"*) ok "--write (idempotent): prints 'already formatted'" ;;
  *) bad "--write (idempotent): prints 'already formatted'" "stdout was: [$out4]" ;;
esac

# ── 5. `--help`/`-h` works for every subcommand, prints something, exits 0 ──
for sub in check fmt new build run test doc lint codemod snapshot check-policy manifest repl lsp mcp; do
  out="$("$MEDAKA" "$sub" --help 2>"$TMP/help_$sub.err")"
  rc=$?
  if [ "$rc" = "0" ] && [ -n "$out" ]; then ok "$sub --help: exit 0 with output"
  else bad "$sub --help: exit 0 with output" "exit=$rc output=[$out]"; fi
  # every subcommand's help must at minimum mention its own name, so a copy-paste
  # placeholder text is caught rather than silently accepted as "some text".
  case "$out" in
    *"$sub"*) ok "$sub --help: mentions its own subcommand name" ;;
    *) bad "$sub --help: mentions its own subcommand name" "output was: [$out]" ;;
  esac
  out_h="$("$MEDAKA" "$sub" -h 2>"$TMP/help_h_$sub.err")"
  rc_h=$?
  if [ "$rc_h" = "0" ] && [ -n "$out_h" ]; then ok "$sub -h: exit 0 with output"
  else bad "$sub -h: exit 0 with output" "exit=$rc_h output=[$out_h]"; fi
done

# ── 6. --stdout and --check remain read-only (unchanged behavior, still true) ──
STD="$TMP/std.mdk"
printf 'main    =\n  println   1\n' > "$STD"
b6="$(sum "$STD")"
"$MEDAKA" fmt --stdout "$STD" >/dev/null 2>&1
a6="$(sum "$STD")"
if [ "$b6" = "$a6" ]; then ok "--stdout: file byte-identical"
else bad "--stdout: file byte-identical" "checksum changed"; fi
"$MEDAKA" fmt --check "$STD" >/dev/null 2>&1
c6="$(sum "$STD")"
if [ "$b6" = "$c6" ]; then ok "--check: file byte-identical"
else bad "--check: file byte-identical" "checksum changed"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
