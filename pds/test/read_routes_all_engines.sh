#!/bin/sh
# P4-D: the read/identity/well-known routes that need NO repository, on eval,
# native, and real Wasm, differenced byte-for-byte, plus a direct-red mutation.
#
# ── WHY THIS GATE IS REPOSITORY-FREE ─────────────────────────────────────────
#
# Every cell runs against `storeEmpty`, so nothing here signs. That is what
# makes an EVAL arm possible: one `repoInit` under the tree-walking interpreter
# does not complete in 600s on this box (measured in P4-C), which is why
# pds/test/repo_vectors.sh has no `medaka run` arm any more (#2208). A gate that
# built a repository here would move a seconds-long merge-queue check into the
# >10-minute band #2181 removed from this project.
#
# The repository-BEARING read routes — getRecord/listRecords/describeRepo/
# sync.getRepo/sync.getLatestCommit against a real signed repo, graded against
# the pinned Phase-1 corpus — run on the compiled engines as an arm of
# pds/test/repo_vectors.sh, next to the corpus they are graded by.
#
# What this gate covers is exactly the part of P4-D that lives in the ROUTER
# and needs no state: the two non-XRPC well-known paths as their own route
# class, every other non-XRPC path still 404ing, and every repository-bearing
# read refusing cleanly on an unconfigured server instead of answering.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
SOURCE="$ROOT/pds/test/read_routes_all_engines_main.mdk"
WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-read-routes.XXXXXX")
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

[ -x "$MEDAKA" ] || fail "build medaka first (missing $MEDAKA)"

DID='did:key:zQ3shVc2UkAfJCdc1TR8E66J85h48P43r93q8jGPkPpjF9Ef9'
DIDDOC='{"@context":["https://www.w3.org/ns/did/v1"],"id":"did:web:pds.example","service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example"}]}'

# The expected transcript is hand-authored here, not captured: each line is the
# answer the atproto route is DEFINED to give, decided before anything ran.
cat > "$WORK/expected.out" <<EOF
CELL wellknown-did-json PASS status=200 media=application/json body=$DIDDOC state=unchanged
CELL wellknown-atproto-did PASS status=200 media=text/plain; charset=utf-8 body=$DID state=unchanged
CELL wellknown-post-rejected PASS status=405 error=MethodNotAllowed state=unchanged
CELL wellknown-body-framing-rejected PASS status=400 error=InvalidRequest state=unchanged
CELL non-xrpc-still-404 PASS status=404 error=NotFound state=unchanged
CELL well-known-sibling-still-404 PASS status=404 error=NotFound state=unchanged
CELL resolve-handle PASS status=200 media=application/json body={"did":"$DID"} state=unchanged
CELL resolve-handle-unknown PASS status=400 error=HandleNotFound state=unchanged
CELL resolve-handle-repeated-param PASS status=400 error=InvalidRequest state=unchanged
CELL resolve-handle-missing-param PASS status=400 error=InvalidRequest state=unchanged
CELL get-record-unconfigured PASS status=400 error=RepoNotFound state=unchanged
CELL list-records-unconfigured PASS status=400 error=RepoNotFound state=unchanged
CELL describe-repo-unconfigured PASS status=400 error=RepoNotFound state=unchanged
CELL get-repo-unconfigured PASS status=400 error=RepoNotFound state=unchanged
CELL get-latest-commit-unconfigured PASS status=400 error=RepoNotFound state=unchanged
CELL read-route-requires-get PASS status=405 error=MethodNotAllowed state=unchanged
CELL unregistered-xrpc-still-404 PASS status=404 error=NotFound state=unchanged
cells: 17/17 repository-free routes
TOTAL: PASS
EOF

check_cells() {
  output=$1
  label=$2
  grep -F -q "CELL wellknown-did-json PASS status=200 media=application/json body=$DIDDOC" "$output" \
    || fail "$label missed the did:web document cell"
  grep -F -q "CELL wellknown-atproto-did PASS status=200 media=text/plain; charset=utf-8 body=$DID" "$output" \
    || fail "$label missed the bare-DID well-known cell"
  grep -F -q 'CELL non-xrpc-still-404 PASS status=404 error=NotFound' "$output" \
    || fail "$label missed the unrelated-non-XRPC 404 control"
  grep -F -q 'CELL wellknown-post-rejected PASS status=405 error=MethodNotAllowed' "$output" \
    || fail "$label missed the well-known method check"
  grep -F -q "CELL resolve-handle PASS status=200 media=application/json body={\"did\":\"$DID\"}" "$output" \
    || fail "$label missed the resolveHandle cell"
  grep -F -q 'CELL get-repo-unconfigured PASS status=400 error=RepoNotFound' "$output" \
    || fail "$label missed the unconfigured sync.getRepo refusal"
  grep -F -q 'cells: 17/17 repository-free routes' "$output" || fail "$label cell count is incomplete"
  cmp "$WORK/expected.out" "$output" || fail "$label output differs from the hand-authored cells"
}

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" run "$SOURCE" > "$WORK/eval.out" 2> "$WORK/eval.err"
require_empty "$WORK/eval.err" eval
check_cells "$WORK/eval.out" eval

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$SOURCE" -o "$WORK/native" > "$WORK/native-build.log" 2>&1
"$WORK/native" > "$WORK/native.out" 2> "$WORK/native.err"
require_empty "$WORK/native.err" native
check_cells "$WORK/native.out" native
cmp "$WORK/eval.out" "$WORK/native.out" || fail 'eval and native output differ'

[ -x "$WASM_EMITTER" ] || fail 'Wasm is required but the modules emitter is unavailable'
command -v node >/dev/null 2>&1 || fail 'Wasm is required but node is unavailable'
command -v wasm-tools >/dev/null 2>&1 || fail 'Wasm is required but wasm-tools is unavailable'

MEDAKA_ROOT="$ROOT" MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$SOURCE" -o "$WORK/read-routes.wasm" > "$WORK/wasm-build.log" 2>&1
node "$ROOT/test/wasm/run.js" "$WORK/read-routes.wasm" > "$WORK/wasm-raw.out" 2> "$WORK/wasm.err"
require_empty "$WORK/wasm.err" wasm
check_cells "$WORK/wasm-raw.out" wasm
cmp "$WORK/native.out" "$WORK/wasm-raw.out" || fail 'native and Wasm output differ'

# ── direct-red mutation ──────────────────────────────────────────────────────
# Swap the hostname the did:web document is expected to be keyed by. If the
# gate can be satisfied by a document that names the wrong server, it is not
# grading the document at all.
mkdir -p "$WORK/mutation-tree"
cp -R "$ROOT/pds" "$WORK/mutation-tree/pds"

python3 - "$WORK/mutation-tree/pds/test/read_routes_all_engines_main.mdk" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
old = '\\"id\\":\\"did:web:pds.example\\"'
new = '\\"id\\":\\"did:web:other.example\\"'
text = path.read_text()
if text.count(old) != 1:
    raise SystemExit(f'mutation anchor count is {text.count(old)}, expected 1')
path.write_text(text.replace(old, new))
PY

MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$WORK/mutation-tree/pds/test/read_routes_all_engines_main.mdk" -o "$WORK/mutated-native" > "$WORK/mutated-build.log" 2>&1 || {
  cat "$WORK/mutated-build.log" >&2
  fail 'did:web hostname mutation failed to build'
}
if "$WORK/mutated-native" > "$WORK/mutated.out" 2>&1; then
  fail 'did:web hostname mutation unexpectedly passed'
fi
grep -F -q 'CELL wellknown-did-json FAIL' "$WORK/mutated.out" || {
  cat "$WORK/mutated.out" >&2
  fail 'did:web hostname mutation failed for an unrelated reason'
}

cp "$ROOT/pds/test/read_routes_all_engines_main.mdk" "$WORK/mutation-tree/pds/test/read_routes_all_engines_main.mdk"
cmp "$ROOT/pds/test/read_routes_all_engines_main.mdk" "$WORK/mutation-tree/pds/test/read_routes_all_engines_main.mdk"

echo 'MUTATION did-web-hostname PASS direct-red'
echo 'PASS: PDS repository-free read routes — 17/17 named cells; eval == native == Wasm; direct-red mutation; bytes restored'
