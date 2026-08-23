#!/bin/sh
# Native assertion gate for the fixed-ladder public-key boundary. The seven
# assertions take four full 256-round ladders, so keep them out of the generic
# interpreter roster and grade the existing native driver directly.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/secp256k1_public_key_main.mdk"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-public-key-gate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/public-key" > "$WORK/build.log" 2>&1 || {
  cat "$WORK/build.log"
  exit 1
}
"$WORK/public-key" > "$WORK/run.out" 2>&1 || {
  cat "$WORK/run.out"
  exit 1
}

passed=$(awk '/^PASS/{ n += 1 } END { print n + 0 }' "$WORK/run.out")
[ "$passed" -eq 7 ] || {
  cat "$WORK/run.out"
  echo "FAIL: public-key driver reported $passed passing assertions, expected exactly 7" >&2
  exit 1
}
[ "$(tail -1 "$WORK/run.out")" = 'ASSERTIONS: 7/7' ] || {
  cat "$WORK/run.out"
  echo 'FAIL: public-key driver did not finish with ASSERTIONS: 7/7' >&2
  exit 1
}
echo 'PASS: secp256k1 public-key native assertions — 7/7'
