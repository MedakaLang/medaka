#!/bin/sh
# Native assertion gate for the fixed-ladder public-key boundary and for
# `pds keygen`'s derivation on top of it. The assertions take twenty-odd full
# 256-round ladders, so keep them out of the generic interpreter roster and
# grade the existing native driver directly. The two corpora are passed in
# rather than found by the driver: keygen is graded against official external
# values, never against this tree's own output.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/secp256k1_public_key_main.mdk"
POINT_CORPUS="$ROOT/pds/test/vectors/point_public_key_corpus.txt"
DID_CORPUS="$ROOT/pds/test/vectors/pds_did_key_corpus.txt"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-public-key-gate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/public-key" > "$WORK/build.log" 2>&1 || {
  cat "$WORK/build.log"
  exit 1
}
"$WORK/public-key" "$POINT_CORPUS" "$DID_CORPUS" > "$WORK/run.out" 2>&1 || {
  cat "$WORK/run.out"
  exit 1
}

passed=$(awk '/^PASS/{ n += 1 } END { print n + 0 }' "$WORK/run.out")
[ "$passed" -eq 10 ] || {
  cat "$WORK/run.out"
  echo "FAIL: public-key driver reported $passed passing assertions, expected exactly 10" >&2
  exit 1
}
[ "$(tail -1 "$WORK/run.out")" = 'ASSERTIONS: 10/10' ] || {
  cat "$WORK/run.out"
  echo 'FAIL: public-key driver did not finish with ASSERTIONS: 10/10' >&2
  exit 1
}
# Named one by one, so a driver that silently stopped emitting a cell is a
# failure rather than a smaller number that still sums.
for cell in compressed-G-2G-3G derived-G-2G-3G derived-leading-zero-scalar \
  both-parity-prefixes reject-length-prefix-infinity reject-x-at-or-above-p \
  reject-known-nonsquare-rhs keygen-derivation-vs-official-corpora \
  keygen-admits-d-only-in-1-to-n-minus-1 keygen-fresh-key-round-trips
do
  grep -q "^PASS	$cell$" "$WORK/run.out" || {
    cat "$WORK/run.out"
    echo "FAIL: public-key driver did not report cell $cell" >&2
    exit 1
  }
done
echo 'PASS: secp256k1 public-key native assertions — 10/10, keygen graded against both official corpora'
