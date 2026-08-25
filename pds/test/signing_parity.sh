#!/bin/sh
# Eval/native/Wasm value parity for #1700 step 3. Native timing is audited by
# constant_time_signing.sh; this gate makes no Wasm timing claim.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
SAMPLE="$ROOT/pds/test/constant_time_signing_main.mdk"
FULL_DRIVER="$ROOT/pds/test/ecdsa_vectors_main.mdk"
SIGNING="$ROOT/pds/test/vectors/prehashed_signing_corpus.txt"
WYCHEPROOF="$ROOT/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-signing-parity.XXXXXX")
cleanup() {
  if [ "${KEEP_WORK:-0}" = 1 ]; then printf 'kept work directory: %s\n' "$WORK" >&2; else rm -rf "$WORK"; fi
}
trap cleanup EXIT HUP INT TERM

[ -x "$MEDAKA" ] || { echo "FAIL: build medaka first" >&2; exit 2; }
[ -x "$WASM_EMITTER" ] || { echo "FAIL: build test/bin/wasm_emit_modules_main first" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node is required" >&2; exit 2; }
command -v wasm-tools >/dev/null 2>&1 || { echo "FAIL: wasm-tools is required" >&2; exit 2; }
export MEDAKA_ROOT
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

MEDAKA_STRICT=1 "$MEDAKA" run "$SAMPLE" > "$WORK/eval.out" 2> "$WORK/eval.err"
MEDAKA_STRICT=1 "$MEDAKA" build "$SAMPLE" -o "$WORK/native-sample" > "$WORK/native-sample-build.log" 2>&1
"$WORK/native-sample" > "$WORK/native-sample.out" 2> "$WORK/native-sample.err"
cmp "$WORK/eval.out" "$WORK/native-sample.out" || {
  echo 'FAIL: sampled signing values differ between eval and native' >&2
  exit 1
}

MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$SAMPLE" -o "$WORK/sample.wasm" > "$WORK/sample-wasm-build.log" 2>&1
set +e
node "$ROOT/test/wasm/run.js" "$WORK/sample.wasm" > "$WORK/sample-wasm-raw.out" 2> "$WORK/sample-wasm.err"
sample_wasm_status=$?
set -e
[ "$sample_wasm_status" -eq 0 ] || {
  cat "$WORK/sample-wasm-raw.out" >&2
  cat "$WORK/sample-wasm.err" >&2
  echo "FAIL: sampled Wasm runner exited $sample_wasm_status" >&2
  exit 1
}
cp "$WORK/sample-wasm-raw.out" "$WORK/sample-wasm.out"
cmp "$WORK/native-sample.out" "$WORK/sample-wasm.out" || {
  echo 'FAIL: sampled signing values differ between native and Wasm' >&2
  exit 1
}
grep -F -q 'candidate-1:computations=2:c0.valid=0:' "$WORK/sample-wasm.out"
grep -F -q 'exhaustion:computations=2:c0.valid=0:' "$WORK/sample-wasm.out"
grep -F -q 'high-s:compact=reject:verify:reject' "$WORK/sample-wasm.out"
grep -F -q 'malformed:reject' "$WORK/sample-wasm.out"
echo 'PASS: sampled eval/native/Wasm signing values, complete candidate-1/exhaustion, verifier high-S, and malformed compact'

MEDAKA_STRICT=1 "$MEDAKA" build "$FULL_DRIVER" -o "$WORK/native-full" > "$WORK/native-full-build.log" 2>&1
"$WORK/native-full" "$SIGNING" "$WYCHEPROOF" > "$WORK/native-full.out" 2>&1
MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$FULL_DRIVER" -o "$WORK/full.wasm" > "$WORK/full-wasm-build.log" 2>&1
set +e
MDK_ARGS="$SIGNING $WYCHEPROOF" node "$ROOT/test/wasm/run.js" "$WORK/full.wasm" > "$WORK/full-wasm-raw.out" 2>&1
full_wasm_status=$?
set -e
[ "$full_wasm_status" -eq 0 ] || {
  cat "$WORK/full-wasm-raw.out" >&2
  echo "FAIL: full Wasm runner exited $full_wasm_status" >&2
  exit 1
}
[ "$(tail -1 "$WORK/full-wasm-raw.out")" = 0 ] || {
  cat "$WORK/full-wasm-raw.out" >&2
  echo 'FAIL: full Wasm driver did not emit its expected autoprint result' >&2
  exit 1
}
[ "$(tail -2 "$WORK/full-wasm-raw.out" | sed -n '1p')" = 'TOTAL: PASS' ] || {
  cat "$WORK/full-wasm-raw.out" >&2
  echo 'FAIL: full Wasm corpus did not finish before its autoprint result' >&2
  exit 1
}
sed '$d' "$WORK/full-wasm-raw.out" > "$WORK/full-wasm.out"
cmp "$WORK/native-full.out" "$WORK/full-wasm.out" || {
  echo 'FAIL: full ECDSA corpus output differs between native and Wasm' >&2
  exit 1
}
grep -F -q 'PROBE candidate-1-selection: PASS computations=2' "$WORK/full-wasm.out"
grep -F -q 'PROBE two-candidate-exhaustion: PASS computations=2' "$WORK/full-wasm.out"
grep -F -q 'WITNESS high-S ' "$WORK/full-wasm.out"
grep -F -q 'WITNESS malformed ' "$WORK/full-wasm.out"
[ "$(tail -1 "$WORK/full-wasm.out")" = 'TOTAL: PASS' ]
echo 'PASS: full native/Wasm ECDSA corpus parity — 80 signing and 242 verification rows'
