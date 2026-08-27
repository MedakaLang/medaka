#!/bin/sh
# Exact native ECDSA signing and Wycheproof verification gate for #1700 step 3.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
SOURCE="$ROOT/pds/lib/secp256k1.mdk"
DRIVER="$ROOT/pds/test/ecdsa_vectors_main.mdk"
SIGNING="$ROOT/pds/test/vectors/prehashed_signing_corpus.txt"
WYCHEPROOF="$ROOT/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-ecdsa.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

[ -x "$MEDAKA" ] || { echo "build medaka first (missing $MEDAKA)"; exit 2; }
export MEDAKA_ROOT
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# The value corpus cannot distinguish an arithmetic select from a secret
# branch with the same result, so keep the accepted low-S source shape
# fail-capable here. S3-D closes the full transitive native graph.
grep -F -q 'let lowS = scSelect (scHighBit rawS) rawS (scNegateCt rawS)' "$SOURCE" || {
  echo 'FAIL: signing low-S normalization is not the accepted arithmetic scSelect shape'
  exit 1
}

MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/ecdsa-vectors" >"$WORK/build.log" 2>&1 || {
  cat "$WORK/build.log"
  exit 1
}

"$WORK/ecdsa-vectors" "$SIGNING" "$WYCHEPROOF" >"$WORK/run.out" 2>&1 || {
  cat "$WORK/run.out"
  exit 1
}

grep -E '^(PROBE|WITNESS|PUBLIC|signing:|public signing:|exceptional probes:|Wycheproof:|public verification:|Wycheproof classes:|TOTAL:)' "$WORK/run.out"
grep -F -q 'PROBE candidate-1-selection: PASS computations=2' "$WORK/run.out" || {
  echo 'FAIL: candidate-1 route did not expose both complete computations'
  exit 1
}
grep -F -q 'PROBE two-candidate-exhaustion: PASS computations=2' "$WORK/run.out" || {
  echo 'FAIL: exhaustion route did not expose both complete computations'
  exit 1
}
grep -F -q 'WITNESS high-S ' "$WORK/run.out" || {
  echo 'FAIL: no explicit high-S parser/verifier-boundary witness'
  exit 1
}
grep -F -q 'WITNESS malformed ' "$WORK/run.out" || {
  echo 'FAIL: no explicit malformed compact witness'
  exit 1
}
grep -F -q 'signing: 80/80 exact rows ok' "$WORK/run.out" || {
  echo 'FAIL: not all 80 signing rows were reproduced'
  exit 1
}
grep -F -q 'public signing: 80/80 exact rows; self-verify=80/80' "$WORK/run.out" || {
  echo 'FAIL: public signing or public self-verification totals drifted'
  exit 1
}
grep -F -q 'PUBLIC compact-boundary: PASS len63=reject len65=reject zero=reject range=reject high-S=reject' "$WORK/run.out" || {
  echo 'FAIL: public compact boundary routes were not all observed'
  exit 1
}
grep -F -q 'PUBLIC malformed-digest: PASS sign=4/4 reject verify=4/4 false' "$WORK/run.out" || {
  echo 'FAIL: public malformed digest routes were not all observed'
  exit 1
}
grep -F -q 'Wycheproof: 94 accepts / 148 rejects; 242 unique tcIds' "$WORK/run.out" || {
  echo 'FAIL: Wycheproof policy counts or tcId uniqueness drifted'
  exit 1
}
grep -F -q 'public verification: 242/242 Wycheproof rows' "$WORK/run.out" || {
  echo 'FAIL: public verification did not agree with all Wycheproof rows'
  exit 1
}
[ "$(tail -1 "$WORK/run.out")" = 'TOTAL: PASS' ] || {
  cat "$WORK/run.out"
  exit 1
}

echo 'PASS: ECDSA public/internal 80/80 signing rows and Wycheproof 94/148 over 242 unique tcIds'
