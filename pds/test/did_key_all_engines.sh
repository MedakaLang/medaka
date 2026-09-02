#!/bin/sh
# Official-PDS secp256k1 did:key values plus eval/native/Wasm parity.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/did_key_all_engines_main.mdk"
CORPUS="$ROOT/pds/test/vectors/pds_did_key_corpus.txt"
WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-did-key.XXXXXX")
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

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" run "$DRIVER" "$CORPUS" > "$WORK/eval.out" 2> "$WORK/eval.err"
require_empty "$WORK/eval.err" eval
grep -F -q 'external: 16/16 official-PDS rows' "$WORK/eval.out" || fail 'eval did not grade 16 external rows'
grep -F -q 'malformed: 14/14 rejected' "$WORK/eval.out" || fail 'eval malformed count is incomplete'
[ "$(tail -1 "$WORK/eval.out")" = 'TOTAL: PASS' ] || fail 'eval did not end in TOTAL: PASS'

for label in wrong-method wrong-method-case missing-multibase invalid-multibase invalid-base58 wrong-codec nonminimal-codec empty-payload short-payload long-payload trailing-payload invalid-sec1-prefix invalid-sec1-x invalid-sec1-nonsquare
do
  grep -F -q "MALFORMED $label PASS" "$WORK/eval.out" || fail "eval missed malformed cell $label"
done

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/native" > "$WORK/native-build.log" 2>&1
"$WORK/native" "$CORPUS" > "$WORK/native.out" 2> "$WORK/native.err"
require_empty "$WORK/native.err" native
cmp "$WORK/eval.out" "$WORK/native.out" || fail 'eval and native normalized output differ'

if [ ! -x "$WASM_EMITTER" ] || ! command -v node >/dev/null 2>&1 || ! command -v wasm-tools >/dev/null 2>&1; then
  [ "${MEDAKA_REQUIRE_WASM:-0}" != 1 ] || fail 'Wasm is required but emitter/node/wasm-tools is unavailable'
  echo 'PASS: did:key — eval == native; Wasm unavailable'
  exit 0
fi

MEDAKA_ROOT="$ROOT" MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$DRIVER" -o "$WORK/driver.wasm" > "$WORK/wasm-build.log" 2>&1
MDK_ARGS="$CORPUS" node "$ROOT/test/wasm/run.js" "$WORK/driver.wasm" > "$WORK/wasm-raw.out" 2> "$WORK/wasm.err"
require_empty "$WORK/wasm.err" wasm
# A Unit main prints nothing on Wasm (the trailing `0` this once expected was
# #2424): the runner's stdout is the program's output, byte for byte.
cp "$WORK/wasm-raw.out" "$WORK/wasm.out"
cmp "$WORK/native.out" "$WORK/wasm.out" || fail 'native and Wasm normalized output differ'

mkdir -p "$WORK/mutation-tree"
cp -R "$ROOT/pds" "$WORK/mutation-tree/pds"

restore_mutation_tree() {
  cp "$ROOT/pds/lib/did_key.mdk" "$WORK/mutation-tree/pds/lib/did_key.mdk"
  cp "$ROOT/pds/test/did_key_all_engines_main.mdk" "$WORK/mutation-tree/pds/test/did_key_all_engines_main.mdk"
  cmp "$ROOT/pds/lib/did_key.mdk" "$WORK/mutation-tree/pds/lib/did_key.mdk"
  cmp "$ROOT/pds/test/did_key_all_engines_main.mdk" "$WORK/mutation-tree/pds/test/did_key_all_engines_main.mdk"
}

replace_once() {
  file=$1
  old=$2
  new=$3
  python3 - "$file" "$old" "$new" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
old = sys.argv[2]
new = sys.argv[3]
text = path.read_text()
if text.count(old) != 1:
    raise SystemExit(f"mutation anchor count is {text.count(old)}, expected 1: {old}")
path.write_text(text.replace(old, new))
PY
}

expect_mutation_red() {
  id=$1
  file=$2
  old=$3
  new=$4
  witness=$5
  replace_once "$file" "$old" "$new"
  # Native, not eval: these mutations are value/boolean-condition edits only,
  # never type-changing, so a build failure would itself be the finding. Using
  # the compiled binary instead of the tree-walking interpreter cuts each
  # full-corpus secp256k1 mutation check from ~4 minutes to ~4 seconds
  # (measured) — run/build share the typechecker and differ only in engine
  # ([D-RUN-VS-BUILD]), so this witnesses the same panic just as validly.
  MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/mutation-tree/pds/test/did_key_all_engines_main.mdk" -o "$WORK/$id.bin" > "$WORK/$id-build.log" 2>&1 || {
    cat "$WORK/$id-build.log" >&2
    fail "$id failed to build (mutation should only change runtime behavior)"
  }
  if "$WORK/$id.bin" "$CORPUS" > "$WORK/$id.out" 2>&1; then
    fail "$id unexpectedly passed"
  fi
  grep -F -q "$witness" "$WORK/$id.out" || {
    cat "$WORK/$id.out" >&2
    fail "$id failed for an unrelated reason"
  }
  echo "MUTATION $id PASS direct-red"
  restore_mutation_tree
}

restore_mutation_tree
expect_mutation_red wrong-codec-prefix "$WORK/mutation-tree/pds/lib/did_key.mdk" 'secp256k1Prefix = multicodecPrefix multicodecSecp256k1Pub' 'secp256k1Prefix = multicodecPrefix 0x1200' 'row 0 value mismatch'
expect_mutation_red omitted-did-key "$WORK/mutation-tree/pds/lib/did_key.mdk" '"did:key:" ++ multibaseBase58btc payload' 'multibaseBase58btc payload' 'row 0 value mismatch'
expect_mutation_red removed-codec-equality "$WORK/mutation-tree/pds/lib/did_key.mdk" 'if codec /= multicodecSecp256k1Pub then' 'if False then' 'MALFORMED wrong-codec FAIL accepted'
expect_mutation_red short-payload-accepted "$WORK/mutation-tree/pds/lib/did_key.mdk" 'publicKeyFromCompressed keyBytes' 'if arrayLength keyBytes == 32 then publicKeyFromCompressed (keyBytes ++ [|0x98|]) else publicKeyFromCompressed keyBytes' 'MALFORMED short-payload FAIL accepted'
expect_mutation_red disconnected-corpus "$WORK/mutation-tree/pds/test/did_key_all_engines_main.mdk" 'let rowCount = runRows rows 0' 'let rowCount = runRows [] 0' 'external row count expected 16, got 0'

cmp "$ROOT/pds/lib/did_key.mdk" "$WORK/mutation-tree/pds/lib/did_key.mdk"
cmp "$ROOT/pds/test/did_key_all_engines_main.mdk" "$WORK/mutation-tree/pds/test/did_key_all_engines_main.mdk"
echo 'PASS: did:key — 16/16 external rows; 14/14 malformed cells; eval == native == Wasm; 5/5 direct-red mutations; bytes restored'
