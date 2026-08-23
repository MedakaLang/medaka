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

  run_wasm_corpus() {
    scope=$1
    driver=$2
    floor=$3
    list="$WORK/$scope-files.lst"
    MEDAKA_ROOT="$ROOT" sh "$ROOT/pds/test/vector_provenance.sh" --files-for "$scope" > "$list"
    args=
    while IFS= read -r rel; do
      [ -z "$rel" ] && continue
      args="$args $ROOT/$rel"
    done < "$list"
    args=${args# }
    wasm="$WORK/$scope.wasm"
    MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$driver" -o "$wasm" > "$WORK/$scope-build.log" 2>&1
    MDK_ARGS="$args" node "$ROOT/test/wasm/run.js" "$wasm" > "$WORK/$scope.out" 2>&1
    [ "$(tail -1 "$WORK/$scope.out")" = 'TOTAL: PASS' ] || {
      cat "$WORK/$scope.out" >&2
      echo "FAIL: $scope Wasm corpus did not end in TOTAL: PASS" >&2
      exit 1
    }
    checked=$(awk -F'[:/ ]+' '/^counted: /{ print $3 }' "$WORK/$scope.out")
    case "$checked" in ''|*[!0-9]*) echo "FAIL: $scope Wasm corpus count did not parse" >&2; exit 1 ;; esac
    [ "$checked" -ge "$floor" ] || {
      echo "FAIL: $scope Wasm corpus checked $checked rows, expected at least $floor" >&2
      exit 1
    }
    echo "PASS: $scope Wasm reference corpus — $checked rows"
  }

  run_wasm_corpus S-field "$ROOT/pds/test/field_vectors_main.mdk" 944
  run_wasm_corpus S-scalar "$ROOT/pds/test/scalar_vectors_main.mdk" 1028
  echo 'PASS: PDS constant-time reduction value parity — eval == native == Wasm (4 public rows, full Wasm corpora)'
elif [ "${MEDAKA_REQUIRE_WASM:-0}" = 1 ]; then
  echo 'FAIL: Wasm parity is required but emitter/node/wasm-tools is unavailable' >&2
  exit 1
else
  echo 'PASS: PDS constant-time reduction value parity — eval == native (4 rows); Wasm unavailable'
fi
