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
CELL malformed-lowercase-version PASS status=400 state=unchanged no-dispatch
CELL malformed-host PASS status=400 state=unchanged no-dispatch
CELL malformed-target PASS status=400 state=unchanged no-dispatch
CELL raw-text PASS media=text/plain bytes=exact state=unchanged
CELL raw-json PASS media=application/json bytes=exact state=unchanged
CELL raw-opaque PASS media=application/octet-stream bytes=exact state=unchanged
CELL procedure-params PASS repeated=true empty=true order=preserved state=unchanged
CELL uppercase-authority-lookup PASS returned=Com.Example.query.caseFixed state=unchanged
CELL authority-duplicate-identity PASS folded-authority=true method-case=distinct
CELL host-empty-reg-port PASS status=200 state=unchanged
CELL host-empty-ip-port PASS status=200 state=unchanged
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
  grep -F -q 'CELL malformed-lowercase-version PASS status=400 state=unchanged no-dispatch' "$output" || fail "$label missed lowercase-version cell"
  grep -F -q 'CELL malformed-host PASS status=400 state=unchanged no-dispatch' "$output" || fail "$label missed invalid-Host cell"
  grep -F -q 'CELL malformed-target PASS status=400 state=unchanged no-dispatch' "$output" || fail "$label missed invalid-target cell"
  grep -F -q 'CELL raw-text PASS media=text/plain bytes=exact state=unchanged' "$output" || fail "$label missed raw-text cell"
  grep -F -q 'CELL raw-json PASS media=application/json bytes=exact state=unchanged' "$output" || fail "$label missed raw-JSON cell"
  grep -F -q 'CELL raw-opaque PASS media=application/octet-stream bytes=exact state=unchanged' "$output" || fail "$label missed opaque-raw cell"
  grep -F -q 'CELL procedure-params PASS repeated=true empty=true order=preserved state=unchanged' "$output" || fail "$label missed procedure-params cell"
  grep -F -q 'CELL uppercase-authority-lookup PASS returned=Com.Example.query.caseFixed state=unchanged' "$output" || fail "$label missed uppercase-authority lookup cell"
  grep -F -q 'CELL authority-duplicate-identity PASS folded-authority=true method-case=distinct' "$output" || fail "$label missed authority identity cell"
  grep -F -q 'CELL host-empty-reg-port PASS status=200 state=unchanged' "$output" || fail "$label missed empty reg-name port cell"
  grep -F -q 'CELL host-empty-ip-port PASS status=200 state=unchanged' "$output" || fail "$label missed empty IP-literal port cell"
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
import re
import sys

# The anchor is matched across whitespace (`medaka fmt` may break the `&&`
# chain over lines); the mutation keeps whatever layout it found.
path = pathlib.Path(sys.argv[1])
anchor = re.compile(r'if response == expectedTextResponse 200 "OK" "fixed"(\s+)&& storeSize next == 1')
text = path.read_text()
hits = anchor.findall(text)
if len(hits) != 1:
    raise SystemExit(f'mutation anchor count is {len(hits)}, expected 1')
path.write_text(anchor.sub(lambda m: 'if response == expectedTextResponse 201 "Created" "fixed"' + m.group(1) + '&& storeSize next == 1', text))
PY

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/mutation-tree/pds/test/protocol_all_engines_main.mdk" -o "$WORK/mutated-native" > "$WORK/mutated-build.log" 2>&1 || {
  cat "$WORK/mutated-build.log" >&2
  fail 'state-update mutation failed to build'
}
if "$WORK/mutated-native" > "$WORK/mutated.out" 2>&1; then
  fail 'empty-port mutation unexpectedly passed'
fi
grep -F -q 'protocol_all_engines: empty reg-name port mismatch' "$WORK/mutated.out" || {
  cat "$WORK/mutated.out" >&2
  fail 'empty-port mutation failed for an unrelated reason'
}

cp "$ROOT/pds/test/protocol_all_engines_main.mdk" "$WORK/mutation-tree/pds/test/protocol_all_engines_main.mdk"
cmp "$ROOT/pds/test/protocol_all_engines_main.mdk" "$WORK/mutation-tree/pds/test/protocol_all_engines_main.mdk"

echo 'MUTATION empty-port-assertion PASS direct-red'
echo 'PASS: PDS protocol core — 16/16 named cells; eval == native == Wasm; direct-red mutation; bytes restored'
