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

[ "$(wc -l < "$WORK/eval.out")" -eq 5 ] || {
  echo 'FAIL: eval parity probe did not emit five rows' >&2
  exit 1
}
cmp "$WORK/eval.out" "$WORK/native.out" || {
  echo 'FAIL: PDS reduction values differ between eval and native' >&2
  exit 1
}

WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
if [ -x "$WASM_EMITTER" ] && command -v node >/dev/null 2>&1 && command -v wasm-tools >/dev/null 2>&1; then
  MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$SOURCE" -o "$WORK/probe.wasm" > "$WORK/wasm-build.log" 2>&1
  node "$ROOT/test/wasm/run.js" "$WORK/probe.wasm" > "$WORK/wasm-raw.out" 2> "$WORK/wasm.err"
  # A Unit main prints nothing on Wasm (the trailing `0` this once expected was
  # #2424, the emitter auto-printing a Unit result as an Int): the runner's
  # stdout IS the program's output, five rows and nothing else.
  [ "$(wc -l < "$WORK/wasm-raw.out")" -eq 5 ] || {
    echo 'FAIL: Wasm parity probe did not emit exactly five rows' >&2
    exit 1
  }
  cp "$WORK/wasm-raw.out" "$WORK/wasm.out"
  cmp "$WORK/native.out" "$WORK/wasm.out" || {
    echo 'FAIL: PDS reduction values differ between native and Wasm' >&2
    exit 1
  }
  echo 'PASS: PDS constant-time reduction/key value parity — eval == native == Wasm (5 public rows)'
elif [ "${MEDAKA_REQUIRE_WASM:-0}" = 1 ]; then
  echo 'FAIL: Wasm parity is required but emitter/node/wasm-tools is unavailable' >&2
  exit 1
else
  echo 'PASS: PDS constant-time reduction/key value parity — eval == native (5 rows); Wasm unavailable'
fi
