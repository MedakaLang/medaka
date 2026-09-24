#!/bin/sh
# Eval/native/Wasm value parity for #1700 step 3. Native timing is audited by
# constant_time_signing.sh; this gate makes no Wasm timing claim.
#
# TWO TIERS, SPLIT ON THE ENGINE (#1962). Profiled arm-by-arm on the dev box,
# ~1430s total:
#
#     sampled   medaka run (eval interpreter)       1171s   82%
#     sampled   build native + run                     3s
#     sampled   build --target wasm + node             4s
#     full      build native + run (322 rows)         24s
#     full      build --target wasm + node (322)     228s   16%
#
# The cost is the ENGINE, not the corpus. 82% of this gate is ONE `medaka run`
# of the sampled driver, and the interpreted WasmGC pass over the 322 rows is
# most of the rest; the 322-row corpus costs 24s natively, all of it. So the two
# interpreted arms — eval on the sample, WasmGC on the full corpus — run only
# under SIGNING_DEEP=1, which .github/workflows/nightly.yml's
# `pds-signing-parity` job sets. Everything else runs on the merge tier for
# ~31s: sampled native==Wasm value parity with all four witnesses, plus the
# whole 322-row corpus natively.
#
# Same axis and same finding as pds/test/repo_vectors.sh (#2208), whose eval arm
# runs nightly as pds/nightly/repo_vectors_eval_engine.sh.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
DEEP=${SIGNING_DEEP:-0}
SAMPLE="$ROOT/pds/test/constant_time_signing_main.mdk"
FULL_DRIVER="$ROOT/pds/test/ecdsa_vectors_main.mdk"
SIGNING="$ROOT/pds/test/vectors/prehashed_signing_corpus.txt"
WYCHEPROOF="$ROOT/pds/test/vectors/wycheproof_secp256k1_sha256_p1363.txt"
BITCOIN="$ROOT/pds/test/vectors/wycheproof_secp256k1_sha256_bitcoin.txt"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-signing-parity.XXXXXX")
cleanup() {
  if [ "${KEEP_WORK:-0}" = 1 ]; then printf 'kept work directory: %s\n' "$WORK" >&2; else rm -rf "$WORK"; fi
}
trap cleanup EXIT HUP INT TERM

# Both tiers need the wasm toolchain — the sampled Wasm arm is merge-tier.
[ -x "$MEDAKA" ] || { echo "FAIL: build medaka first" >&2; exit 2; }
[ -x "$WASM_EMITTER" ] || { echo "FAIL: build test/bin/wasm_emit_modules_main first" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node is required" >&2; exit 2; }
command -v wasm-tools >/dev/null 2>&1 || { echo "FAIL: wasm-tools is required" >&2; exit 2; }
export MEDAKA_ROOT
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

# ── merge tier: sampled native == Wasm, and all four witnesses ────────────────

MEDAKA_STRICT=1 "$MEDAKA" build "$SAMPLE" -o "$WORK/native-sample" > "$WORK/native-sample-build.log" 2>&1
"$WORK/native-sample" > "$WORK/native-sample.out" 2> "$WORK/native-sample.err"

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
echo 'PASS: sampled native/Wasm signing values, complete candidate-1/exhaustion, verifier high-S, and malformed compact'

# ── merge tier: the whole 322-row corpus, natively ────────────────────────────

MEDAKA_STRICT=1 "$MEDAKA" build "$FULL_DRIVER" -o "$WORK/native-full" > "$WORK/native-full-build.log" 2>&1
"$WORK/native-full" "$SIGNING" "$WYCHEPROOF" "$BITCOIN" > "$WORK/native-full.out" 2>&1
grep -F -q 'PROBE candidate-1-selection: PASS computations=2' "$WORK/native-full.out"
grep -F -q 'PROBE two-candidate-exhaustion: PASS computations=2' "$WORK/native-full.out"
grep -F -q 'WITNESS high-S ' "$WORK/native-full.out"
grep -F -q 'WITNESS malformed ' "$WORK/native-full.out"
[ "$(tail -1 "$WORK/native-full.out")" = 'TOTAL: PASS' ] || {
  cat "$WORK/native-full.out" >&2
  echo 'FAIL: full native corpus did not end in TOTAL: PASS' >&2
  exit 1
}
echo 'PASS: full native ECDSA corpus — 80 signing and 245 verification rows'

# ── SIGNING_DEEP: the two interpreted arms, ~23 minutes ───────────────────────

if [ "$DEEP" != 1 ]; then
  echo 'SKIP: interpreted arms (sampled eval, full-corpus WasmGC) — set SIGNING_DEEP=1 (nightly tier)'
  exit 0
fi

MEDAKA_STRICT=1 "$MEDAKA" run "$SAMPLE" > "$WORK/eval.out" 2> "$WORK/eval.err"
cmp "$WORK/eval.out" "$WORK/native-sample.out" || {
  echo 'FAIL: sampled signing values differ between eval and native' >&2
  exit 1
}
echo 'PASS: sampled eval signing values agree with native'

MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$FULL_DRIVER" -o "$WORK/full.wasm" > "$WORK/full-wasm-build.log" 2>&1
set +e
MDK_ARGS="$SIGNING $WYCHEPROOF $BITCOIN" node "$ROOT/test/wasm/run.js" "$WORK/full.wasm" > "$WORK/full-wasm-raw.out" 2>&1
full_wasm_status=$?
set -e
[ "$full_wasm_status" -eq 0 ] || {
  cat "$WORK/full-wasm-raw.out" >&2
  echo "FAIL: full Wasm runner exited $full_wasm_status" >&2
  exit 1
}
# A Unit main prints nothing on Wasm (the trailing `0` this once expected was
# #2424, the emitter auto-printing a Unit result as an Int): the corpus's own
# `TOTAL: PASS` is the last line, and the runner's stdout is the program's output.
[ "$(tail -1 "$WORK/full-wasm-raw.out")" = 'TOTAL: PASS' ] || {
  cat "$WORK/full-wasm-raw.out" >&2
  echo 'FAIL: full Wasm corpus did not end in TOTAL: PASS' >&2
  exit 1
}
cp "$WORK/full-wasm-raw.out" "$WORK/full-wasm.out"
cmp "$WORK/native-full.out" "$WORK/full-wasm.out" || {
  echo 'FAIL: full ECDSA corpus output differs between native and Wasm' >&2
  exit 1
}
echo 'PASS: full native/Wasm ECDSA corpus parity — 80 signing and 245 verification rows'
