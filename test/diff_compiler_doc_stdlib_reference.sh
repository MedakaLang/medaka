#!/bin/sh
# Freshness gate for the generated stdlib reference tree (docs/stdlib/*.md +
# index.md + inventory.json, S-reference-lands / #2249).
#
# There is no oracle to diff against here — the "correct" output IS "what
# `./medaka doc` just produced" (byte-identity is the only property under
# test), same shape as the `docs-index` / `gen-ci` Makefile targets
# (Makefile:151-172): regenerate into a scratch dir, diff against the
# committed tree, fail on any difference.
#
# The committed docs/stdlib/ directory also holds HAND-WRITTEN design docs
# that `medaka doc` does not produce and never touches (STDLIB.md,
# FP-STDLIB-DESIGN.md, P1-STDLIB-DESIGN.md, ...) — this gate only compares
# the files the generator itself just wrote, one-for-one against the
# committed file of the same name. It does not enumerate the committed
# directory looking for extras; a hand-written doc living alongside the
# generated ones is not this gate's concern.
#
# Usage:  sh test/diff_compiler_doc_stdlib_reference.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
COMMITTED="$ROOT/docs/stdlib"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cd "$ROOT" || exit 1
"$MEDAKA" doc --out "$TMPDIR" stdlib/*.mdk >/dev/null 2>&1

pass=0
fail=0
for f in "$TMPDIR"/*.md "$TMPDIR"/*.json; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  if [ ! -f "$COMMITTED/$name" ]; then
    fail=$((fail + 1))
    printf 'FAIL %s (freshly generated, but docs/stdlib/%s is not committed)\n' "$name" "$name"
    continue
  fi
  if diff -q "$f" "$COMMITTED/$name" >/dev/null 2>&1; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s (committed docs/stdlib/%s differs from a fresh regen — run: ./medaka doc --out docs/stdlib stdlib/*.mdk)\n' "$name" "$name"
  fi
done

# 0-checked must fail: a gate that iterated no output proves nothing.
if [ "$((pass + fail))" -eq 0 ]; then
  printf '\nNO GENERATED FILES PRODUCED by "%s doc --out %s stdlib/*.mdk" — 0 checked, refusing to pass\n' "$MEDAKA" "$TMPDIR"
  exit 1
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
