#!/bin/sh
# Exact RFC 6979 candidate gate for #1700 signing step 3. The committed
# candidate-0 answers are dual-oracle S3-A rows; Python's stdlib HMAC supplies
# an independent runtime check of row 0's post-rejection candidate 1.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/rfc6979_vectors_main.mdk"
CORPUS="$ROOT/pds/test/vectors/prehashed_signing_corpus.txt"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-rfc6979.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

[ -x "$MEDAKA" ] || { echo "build medaka first (missing $MEDAKA)"; exit 2; }
export MEDAKA_ROOT
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

EXPECTED_CANDIDATE1=$(python3 - "$CORPUS" <<'PY'
import hashlib
import hmac
import sys

n = int("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141", 16)
with open(sys.argv[1], encoding="ascii") as corpus:
    fields = corpus.readline().split()
x = bytes.fromhex(fields[2])
h1 = bytes.fromhex(fields[3])
bits2octets = (int.from_bytes(h1, "big") % n).to_bytes(32, "big")

def h(key, message):
    return hmac.new(key, message, hashlib.sha256).digest()

k = bytes(32)
v = bytes([1]) * 32
k = h(k, v + b"\x00" + x + bits2octets)
v = h(k, v)
k = h(k, v + b"\x01" + x + bits2octets)
v = h(k, v)
candidate0 = h(k, v)
k = h(k, candidate0 + b"\x00")
v = h(k, candidate0)
candidate1 = h(k, v)
print(candidate1.hex())
PY
)

MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/rfc6979-vectors" >"$WORK/build.log" 2>&1 || {
  cat "$WORK/build.log"
  exit 1
}

"$WORK/rfc6979-vectors" "$CORPUS" >"$WORK/run.out" 2>&1 || {
  cat "$WORK/run.out"
  exit 1
}

tail -4 "$WORK/run.out"
grep -F -q "CANDIDATE1 row=0 k=$EXPECTED_CANDIDATE1" "$WORK/run.out" || {
  echo "FAIL: candidate 1 did not match the independent post-rejection HMAC schedule"
  grep '^CANDIDATE1 ' "$WORK/run.out" || true
  exit 1
}
grep -F -q 'PROBE candidate-1-selection: PASS schedule=2 aggregate=1' "$WORK/run.out" || {
  echo "FAIL: injected candidate-1 primitive did not execute"
  exit 1
}
grep -F -q 'PROBE two-candidate-exhaustion: PASS schedule=2 aggregate=0' "$WORK/run.out" || {
  echo "FAIL: injected exhaustion primitive did not execute"
  exit 1
}
grep -F -q 'counted: 80/80 rows ok' "$WORK/run.out" || {
  echo "FAIL: not all 80 candidate-0 rows were graded"
  exit 1
}
[ "$(tail -1 "$WORK/run.out")" = 'TOTAL: PASS' ] || {
  cat "$WORK/run.out"
  exit 1
}

echo 'PASS: RFC 6979 candidate-0 80/80; candidate 1 and exhaustion probes executed after schedule=2'
