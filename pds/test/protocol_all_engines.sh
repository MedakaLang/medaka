#!/bin/sh
# Hand-authored RFC 9112/XRPC cells across eval, native, and real Wasm.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
SOURCE="$ROOT/pds/test/protocol_all_engines_main.mdk"
WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-protocol.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

require_empty() {
  [ ! -s "$1" ] || {
    cat "$1" >&2
    fail "$2 emitted stderr"
  }
}

cat > "$WORK/expected.out" <<'EOF'
CELL fixed-query PASS status=200 state=unchanged
CELL chunked-update PASS status=201 state=1->2 body=abc
CELL malformed-unchanged PASS status=400 state=unchanged
CELL unknown-unchanged PASS status=404 state=unchanged
CELL resource-unchanged PASS status=413 state=unchanged
TOTAL: PASS
EOF

check_cells() {
  output=$1
  label=$2
  grep -F -q 'CELL fixed-query PASS status=200 state=unchanged' "$output" || fail "$label missed fixed-query cell"
  grep -F -q 'CELL chunked-update PASS status=201 state=1->2 body=abc' "$output" || fail "$label missed chunked-update cell"
  grep -F -q 'CELL malformed-unchanged PASS status=400 state=unchanged' "$output" || fail "$label missed malformed cell"
  grep -F -q 'CELL unknown-unchanged PASS status=404 state=unchanged' "$output" || fail "$label missed unknown-route cell"
  grep -F -q 'CELL resource-unchanged PASS status=413 state=unchanged' "$output" || fail "$label missed resource cell"
  cmp "$WORK/expected.out" "$output" || fail "$label output differs from hand-authored cells"
}

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" run "$SOURCE" > "$WORK/eval.out" 2> "$WORK/eval.err"
require_empty "$WORK/eval.err" eval
check_cells "$WORK/eval.out" eval

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$SOURCE" -o "$WORK/native" > "$WORK/native-build.log" 2>&1
"$WORK/native" > "$WORK/native.out" 2> "$WORK/native.err"
require_empty "$WORK/native.err" native
check_cells "$WORK/native.out" native
cmp "$WORK/eval.out" "$WORK/native.out" || fail 'eval and native normalized output differ'

[ -x "$WASM_EMITTER" ] || fail 'Wasm is required but the modules emitter is unavailable'
command -v node >/dev/null 2>&1 || fail 'Wasm is required but node is unavailable'
command -v wasm-tools >/dev/null 2>&1 || fail 'Wasm is required but wasm-tools is unavailable'

MEDAKA_ROOT="$ROOT" MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$SOURCE" -o "$WORK/protocol.wasm" > "$WORK/wasm-build.log" 2>&1
node "$ROOT/test/wasm/run.js" "$WORK/protocol.wasm" > "$WORK/wasm-raw.out" 2> "$WORK/wasm.err"
require_empty "$WORK/wasm.err" wasm
# The current runner writes only guest stdout; a nonzero guest exit is the node
# process status above. Its raw output is therefore already normalized.
check_cells "$WORK/wasm-raw.out" wasm
cmp "$WORK/native.out" "$WORK/wasm-raw.out" || fail 'native and Wasm normalized output differ'

mkdir -p "$WORK/mutation-tree"
cp -R "$ROOT/pds" "$WORK/mutation-tree/pds"

python3 - "$WORK/mutation-tree/pds/test/protocol_all_engines_main.mdk" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
old = 'if storeSize next == 2 && seedPreserved'
new = 'if storeSize next == 1 && seedPreserved'
text = path.read_text()
if text.count(old) != 1:
    raise SystemExit(f'mutation anchor count is {text.count(old)}, expected 1')
path.write_text(text.replace(old, new))
PY

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/mutation-tree/pds/test/protocol_all_engines_main.mdk" -o "$WORK/mutated-native" > "$WORK/mutated-build.log" 2>&1 || {
  cat "$WORK/mutated-build.log" >&2
  fail 'state-update mutation failed to build'
}
if "$WORK/mutated-native" > "$WORK/mutated.out" 2>&1; then
  fail 'state-update mutation unexpectedly passed'
fi
grep -F -q 'protocol_all_engines: chunked-update state mismatch' "$WORK/mutated.out" || {
  cat "$WORK/mutated.out" >&2
  fail 'state-update mutation failed for an unrelated reason'
}

cp "$ROOT/pds/test/protocol_all_engines_main.mdk" "$WORK/mutation-tree/pds/test/protocol_all_engines_main.mdk"
cmp "$ROOT/pds/test/protocol_all_engines_main.mdk" "$WORK/mutation-tree/pds/test/protocol_all_engines_main.mdk"

echo 'MUTATION state-update-assertion PASS direct-red'
echo 'PASS: PDS protocol core — 5/5 named cells; eval == native == Wasm; direct-red mutation; bytes restored'
