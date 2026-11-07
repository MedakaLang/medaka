#!/bin/sh
# shell-because: external-harness — scripts/emit_identity.sh drives two emitter processes per run and compares their output bytes
# emit_identity_selftest.sh: proves scripts/emit_identity.sh can go green AND red.
#
# On a two-entry corpus of tiny fixtures (test/llvm_fixtures/char_lit.mdk, char_code.mdk):
#   1. the same tree as both arms                       -> exit 0 (IDENTICAL)
#   2. the same tree reached through a symlink as head  -> exit 0 (tree-path normalised)
#   3. the same tree with --plant                       -> exit 1 (DIFFER)
# Needs the repo's built medaka_emitter (make medaka).
# Usage: sh test/emit_identity_selftest.sh
# Exit: 0 all three hold, 1 one failed, 2 no built emitter.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
[ -x "$ROOT/medaka_emitter" ] || { printf '%s\n' "emit_identity_selftest: no built medaka_emitter in $ROOT (make medaka)" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/emit_identity_selftest.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir "$TMP/corpus"
cp "$ROOT/test/llvm_fixtures/char_lit.mdk" "$ROOT/test/llvm_fixtures/char_code.mdk" "$TMP/corpus/"
ln -s "$ROOT" "$TMP/link"

TOOL="$ROOT/scripts/emit_identity.sh"
fail=0

check() {
  label="$1"; want="$2"; shift 2
  sh "$TOOL" "$@" > "$TMP/out.txt" 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    printf '%s\n' "ok   $label (exit $got)"
  else
    printf '%s\n' "FAIL $label: want exit $want, got $got" >&2
    cat "$TMP/out.txt" >&2
    fail=1
  fi
}

check "same tree both arms" 0 "$ROOT" "$ROOT" "$TMP/o1" --llvm "$TMP/corpus"
check "same tree through a symlink" 0 "$ROOT" "$TMP/link" "$TMP/o2" --llvm "$TMP/corpus"
check "planted byte is caught" 1 "$ROOT" "$ROOT" "$TMP/o3" --llvm --plant "$TMP/corpus"

exit "$fail"
