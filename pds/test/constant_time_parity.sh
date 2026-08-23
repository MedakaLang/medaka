#!/bin/sh
# Live eval/native/Wasm value differential for #1724's PDS reducers.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
SOURCE="$ROOT/pds/test/constant_time_parity_main.mdk"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/medaka-ct-parity.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

MEDAKA_STRICT=1 "$MEDAKA" run "$SOURCE" > "$WORK/eval.out" 2> "$WORK/eval.err"
MEDAKA_STRICT=1 "$MEDAKA" build "$SOURCE" -o "$WORK/native" > "$WORK/native-build.log" 2>&1
"$WORK/native" > "$WORK/native.out" 2> "$WORK/native.err"

[ "$(wc -l < "$WORK/eval.out")" -eq 4 ] || {
  echo 'FAIL: eval parity probe did not emit four rows' >&2
  exit 1
}
cmp "$WORK/eval.out" "$WORK/native.out" || {
  echo 'FAIL: PDS reduction values differ between eval and native' >&2
  exit 1
}

WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
if [ -x "$WASM_EMITTER" ] && command -v node >/dev/null 2>&1 && command -v wasm-tools >/dev/null 2>&1; then
  MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$SOURCE" -o "$WORK/probe.wasm" > "$WORK/wasm-build.log" 2>&1
  node "$ROOT/test/wasm/run.js" "$WORK/probe.wasm" > "$WORK/wasm.out" 2> "$WORK/wasm.err"
  cmp "$WORK/native.out" "$WORK/wasm.out" || {
    echo 'FAIL: PDS reduction values differ between native and Wasm' >&2
    exit 1
  }
  echo 'PASS: PDS constant-time reduction value parity — eval == native == Wasm (4 rows)'
elif [ "${MEDAKA_REQUIRE_WASM:-0}" = 1 ]; then
  echo 'FAIL: Wasm parity is required but emitter/node/wasm-tools is unavailable' >&2
  exit 1
else
  echo 'PASS: PDS constant-time reduction value parity — eval == native (4 rows); Wasm unavailable'
fi
