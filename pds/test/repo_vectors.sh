#!/bin/sh
# The complete official repo transcript AND the focused-route representative,
# each run on BOTH compiled engines and differenced byte-for-byte.
#
# ── WHY THERE IS NO `medaka run` ARM HERE ANY MORE (#2208, S-2-pds-pole) ──────
#
# This gate was the single most expensive in the suite: 948.9s in
# test/gate_cost_baseline.json, 14% of the whole 6683s gate budget, and the pole
# that floored `gates (pds)` on every rebalance. Profiled arm-by-arm at that cut
# (marks around each block of the then-76-line script, all assertions removed):
#
#     arm1  medaka run … --representative   1091.56s   98.76%
#     arm2  medaka build native + run          7.45s    0.67%
#     arm3  medaka build --target wasm + node  6.31s    0.57%
#     cmp   native.out vs wasm.out             0.01s    0.00%
#
# So the cost was never "three compiles of the pds library" — those are 9.7s
# together. It was ONE `medaka run`: the tree-walking interpreter executing
# secp256k1 over the transcript. The assertions were never the expensive part;
# the ENGINE was.
#
# The `--representative` flag is a property of the DRIVER, not of the
# interpreter — the same binary arm 2 already builds takes it. Measured on the
# same box, same corpus, same driver:
#
#     medaka run  … --representative   1091.56s
#     ./native    … --representative      0.335s   (byte-identical output)
#     node run.js … --representative      1.25s    (byte-identical output)
#
# So the 43 routes the representative arm checks (6 official-atproto external +
# 27 focused rejections + 8 boundary controls + 1 malformed-bound-MST export)
# now run on TWO engines with a cross-engine differential, in ~1.6s, where they
# previously ran on ONE engine for 1091.56s. This is more coverage in the merge
# queue than before, not less.
#
# The eval interpreter's own agreement on this transcript is a breadth arm, not
# a soundness arm — the native==Wasm differential and the 19 hostile-route
# rejections both stay here in the queue — so it moved to
# pds/nightly/repo_vectors_eval_engine.sh under #2181's charter clause, in the
# shape #1962 set for pds/nightly/signing_parity. It is STRONGER there than it
# was here: it now `cmp`s the interpreter's bytes against the native binary's
# instead of grepping four counts out of them.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/repo_vectors_main.mdk"
WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-repo.XXXXXX")
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

# test/wasm/run.js appends the program's exit code as a trailing line on some
# paths and not others; strip it only when it is actually there, exactly as the
# transcript arm has always done.
strip_exit_trailer() {
  if [ "$(tail -1 "$1")" = 0 ]; then
    sed '$d' "$1" > "$2"
  else
    cp "$1" "$2"
  fi
}

[ -x "$MEDAKA" ] || fail "build medaka first (missing $MEDAKA)"
sh "$ROOT/pds/test/vector_provenance.sh" --files-for P1-D-REPO > "$WORK/vector-files"
[ "$(wc -l < "$WORK/vector-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned P1-D corpus'
CORPUS_REL=$(sed -n '1p' "$WORK/vector-files")
CORPUS="$ROOT/$CORPUS_REL"

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/native" > "$WORK/native-build.log" 2>&1; then
  cat "$WORK/native-build.log" >&2
  fail 'native driver build failed'
fi

"$WORK/native" "$CORPUS" > "$WORK/native.out" 2> "$WORK/native.err"
require_empty "$WORK/native.err" native

grep -F -q 'external: 15/15 official-atproto transcript checks' "$WORK/native.out" || fail 'native transcript count is incomplete'
grep -F -q 'hostile: 19/19 rejected on named routes' "$WORK/native.out" || fail 'native hostile count is incomplete'
grep -F -q 'REPO-IDENTITY PASS mixed lookup/create rejected state=unchanged' "$WORK/native.out" || fail 'native missed normalized repository identity control'
grep -F -q 'repository-identity: 1/1 normalized key control' "$WORK/native.out" || fail 'native repository identity count is incomplete'
[ "$(tail -1 "$WORK/native.out")" = 'TOTAL: PASS' ] || fail 'native did not end in TOTAL: PASS'

"$WORK/native" "$CORPUS" --representative > "$WORK/native-rep.out" 2> "$WORK/native-rep.err"
require_empty "$WORK/native-rep.err" 'native representative'

grep -F -q 'representative-external: 6/6 official-atproto initialization/create/CAR checks' "$WORK/native-rep.out" || fail 'native representative external count is incomplete'
grep -F -q 'focused-rejected: 27/27 named routes' "$WORK/native-rep.out" || fail 'native F1 rejection count is incomplete'
grep -F -q 'focused-controls: 8/8 valid routes' "$WORK/native-rep.out" || fail 'native F1 boundary controls are incomplete'
grep -F -q 'focused-export-boundary: 1/1 malformed bound MST route' "$WORK/native-rep.out" || fail 'native F1 export boundary is incomplete'
grep -F -q 'OP CREATE PASS' "$WORK/native-rep.out" || fail 'native missed the representative CREATE'
grep -F -q 'CREATE CAR PASS order=' "$WORK/native-rep.out" || fail 'native missed representative exact CAR bytes/order'
[ "$(tail -1 "$WORK/native-rep.out")" = 'REPRESENTATIVE: PASS' ] || fail 'native did not end in REPRESENTATIVE: PASS'

# ── P4-C: the SAME transcript, through the record-write handler layer ────────
# repo_vectors_main.mdk replays the corpus directly against lib.repo. This arm
# replays it through handleBytes — JSON request bytes in, JSON response bytes
# out — and compares every uri/cid/commit.cid/commit.rev against the same pinned
# rows, so the handler layer is graded against the official oracle rather than
# against itself. Native only, for the reason the header gives at length.
HANDLERS_DRIVER="$ROOT/pds/test/record_handlers_main.mdk"
if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$HANDLERS_DRIVER" -o "$WORK/handlers" > "$WORK/handlers-build.log" 2>&1; then
  cat "$WORK/handlers-build.log" >&2
  fail 'record-handler driver build failed'
fi

"$WORK/handlers" "$CORPUS" > "$WORK/handlers.out" 2> "$WORK/handlers.err"
require_empty "$WORK/handlers.err" 'record handlers'

grep -F -q 'transcript: 4/4 handler-layer steps matched the pinned corpus' "$WORK/handlers.out" || fail 'handler-layer transcript count is incomplete'
grep -F -q 'CELL swap-commit-mismatch PASS error=InvalidSwap' "$WORK/handlers.out" || fail 'handler layer missed the swapCommit CAS rejection'
grep -F -q 'CELL validate-true-refused PASS error=InvalidRequest' "$WORK/handlers.out" || fail 'handler layer missed the validate:true refusal'
grep -F -q 'cells: 4/4 state-preserving rejections' "$WORK/handlers.out" || fail 'handler-layer state-preservation count is incomplete'
[ "$(tail -1 "$WORK/handlers.out")" = 'TOTAL: PASS' ] || fail 'record-handler driver did not end in TOTAL: PASS'

if [ ! -x "$WASM_EMITTER" ] || ! command -v node >/dev/null 2>&1 || ! command -v wasm-tools >/dev/null 2>&1; then
  [ "${MEDAKA_REQUIRE_WASM:-0}" != 1 ] || fail 'Wasm is required but emitter/node/wasm-tools is unavailable'
  echo 'PASS: repo — full official transcript and focused representative on native; Wasm unavailable'
  exit 0
fi

if ! MEDAKA_ROOT="$ROOT" MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$DRIVER" -o "$WORK/driver.wasm" > "$WORK/wasm-build.log" 2>&1; then
  cat "$WORK/wasm-build.log" >&2
  fail 'Wasm driver build failed'
fi

MDK_ARGS="$CORPUS" node "$ROOT/test/wasm/run.js" "$WORK/driver.wasm" > "$WORK/wasm-raw.out" 2> "$WORK/wasm.err"
require_empty "$WORK/wasm.err" wasm
strip_exit_trailer "$WORK/wasm-raw.out" "$WORK/wasm.out"
cmp "$WORK/native.out" "$WORK/wasm.out" || fail 'native and Wasm normalized transcript output differ'

MDK_ARGS="$CORPUS --representative" node "$ROOT/test/wasm/run.js" "$WORK/driver.wasm" > "$WORK/wasm-rep-raw.out" 2> "$WORK/wasm-rep.err"
require_empty "$WORK/wasm-rep.err" 'wasm representative'
strip_exit_trailer "$WORK/wasm-rep-raw.out" "$WORK/wasm-rep.out"
cmp "$WORK/native-rep.out" "$WORK/wasm-rep.out" || fail 'native and Wasm normalized representative output differ'

echo 'PASS: repo — full official TIDs/records/MST/commits/signatures/CAR and the 27 focused rejection routes, native == Wasm on both; 19 hostile routes; 4 handler-layer transcript steps + 4 state-preserving rejections'
