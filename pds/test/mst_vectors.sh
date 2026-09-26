#!/bin/sh
# P1-B deterministic atproto MST: official-reference roots/node bytes and
# strict hostile validation on eval, native, and Wasm.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/mst_vectors_main.mdk"
PERF_DRIVER="$ROOT/pds/test/performance_resource_main.mdk"
COST_CURVE_DRIVER="$ROOT/pds/test/cost_curve_main.mdk"
SYNTH_REPO_DRIVER="$ROOT/pds/test/synth_repo_main.mdk"
WASM_EMITTER=${MEDAKA_WASM_EMITTER:-"$ROOT/test/bin/wasm_emit_modules_main"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-mst.XXXXXX")
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

sh "$ROOT/pds/test/vector_provenance.sh" --files-for P1-B-MST > "$WORK/vector-files"
[ "$(wc -l < "$WORK/vector-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned P1-B corpus'
CORPUS_REL=$(sed -n '1p' "$WORK/vector-files")
CORPUS="$ROOT/$CORPUS_REL"

sh "$ROOT/pds/test/vector_provenance.sh" --files-for P1-B-MST-PROOF > "$WORK/proof-files"
[ "$(wc -l < "$WORK/proof-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned covering-proof corpus'
PROOF_CORPUS="$ROOT/$(sed -n '1p' "$WORK/proof-files")"

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" run "$DRIVER" "$CORPUS" "$PROOF_CORPUS" > "$WORK/eval.out" 2> "$WORK/eval.err"; then
  cat "$WORK/eval.out" >&2
  cat "$WORK/eval.err" >&2
  fail 'eval driver failed'
fi
require_empty "$WORK/eval.err" eval
grep -F -q 'external: 11/11 official-reference cases' "$WORK/eval.out" || fail 'eval did not grade all external cases'
grep -F -q 'covering proofs: 17/17 official-reference rows' "$WORK/eval.out" || fail 'eval did not grade all covering-proof rows'
grep -F -q 'narrower than the whole tree: 13/17 proof rows' "$WORK/eval.out" || fail 'covering proofs did not stay narrower than the full node set'
grep -F -q 'hostile: 14/14 rejected on named routes' "$WORK/eval.out" || fail 'eval hostile route count is incomplete'
grep -F -q 'controls: 3/3 valid lexical neighbors' "$WORK/eval.out" || fail 'eval lexical controls are incomplete'
[ "$(tail -1 "$WORK/eval.out")" = 'TOTAL: PASS' ] || fail 'eval did not end in TOTAL: PASS'

for name in \
  empty leading-zero-bits-0 leading-zero-bits-2 leading-zero-bits-4 \
  leading-zero-bits-6 prefix-compression permutation-forward \
  permutation-reverse replace delete delete-to-empty
do
  grep -F -q "CASE $name PASS " "$WORK/eval.out" || fail "eval missed external case $name"
done

for label in empty-key duplicates depth order prefix undercompressed misplaced-left \
  misplaced-between misplaced-right misplaced-transitive malformed-links truncation \
  unreachable invalid-node
do
  grep -F -q "HOSTILE $label PASS route=" "$WORK/eval.out" || fail "eval missed exceptional route $label"
done

for name in proof-single-node proof-two-layer proof-three-layer
do
  grep -F -q "PROOFCASE $name " "$WORK/eval.out" || fail "eval missed covering-proof case $name"
done

for label in left-neighbor between-neighbor right-neighbor
do
  grep -F -q "MST CONTROL $label PASS" "$WORK/eval.out" || fail "eval missed lexical control $label"
done

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/native" > "$WORK/native-build.log" 2>&1; then
  cat "$WORK/native-build.log" >&2
  fail 'native driver build failed'
fi
"$WORK/native" "$CORPUS" "$PROOF_CORPUS" > "$WORK/native.out" 2> "$WORK/native.err"
require_empty "$WORK/native.err" native
cmp "$WORK/eval.out" "$WORK/native.out" || fail 'eval and native normalized output differ'

if [ ! -x "$WASM_EMITTER" ] || ! command -v node >/dev/null 2>&1 || ! command -v wasm-tools >/dev/null 2>&1; then
  [ "${MEDAKA_REQUIRE_WASM:-0}" != 1 ] || fail 'Wasm is required but emitter/node/wasm-tools is unavailable'
  ENGINE_GRADE='eval == native; Wasm unavailable'
else
  if ! MEDAKA_ROOT="$ROOT" MEDAKA_WASM_EMITTER="$WASM_EMITTER" MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$DRIVER" -o "$WORK/driver.wasm" > "$WORK/wasm-build.log" 2>&1; then
    cat "$WORK/wasm-build.log" >&2
    fail 'Wasm driver build failed'
  fi
  MDK_ARGS="$CORPUS $PROOF_CORPUS" node "$ROOT/test/wasm/run.js" "$WORK/driver.wasm" > "$WORK/wasm-raw.out" 2> "$WORK/wasm.err"
  require_empty "$WORK/wasm.err" wasm
  # A Unit main prints nothing on Wasm (the trailing `0` this once expected was
  # #2424): the runner's stdout is the program's output, byte for byte.
  cp "$WORK/wasm-raw.out" "$WORK/wasm.out"
  cmp "$WORK/native.out" "$WORK/wasm.out" || fail 'native and Wasm normalized output differ'
  ENGINE_GRADE='eval == native == Wasm'
fi

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$PERF_DRIVER" -o "$WORK/perf-native" > "$WORK/perf-build.log" 2>&1; then
  cat "$WORK/perf-build.log" >&2
  fail 'MST scaling driver build failed'
fi

measure_mst() {
  label=$1
  size=$2
  start=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  "$WORK/perf-native" mst "$size" > "$WORK/$label.out"
  finish=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  grep -F -q "MST $size UNREACHABLE" "$WORK/$label.out" || fail "MST scaling route failed at $size rows"
  awk -v start="$start" -v finish="$finish" 'BEGIN { printf "%.6f", finish - start }'
}

MST_SMALL=$(measure_mst mst-1000 1000)
MST_LARGE=$(measure_mst mst-2000 2000)
if ! awk -v small="$MST_SMALL" -v large="$MST_LARGE" 'BEGIN {
  ratio = large / small
  exit ! (large <= 3.5 && ratio <= 3.2)
}'; then
  fail "MST scaling exceeded bounds: 1000=$MST_SMALL s 2000=$MST_LARGE s"
fi
echo "MST scaling: 1000=$MST_SMALL s 2000=$MST_LARGE s"

# The assertion above times `mstValidateBlocks` REJECTING a hostile
# UNREACHABLE corpus — never the write path (`mstInsert`), the export path
# (`repoExportGraph`), or the startup path (`repoFromBlocks`/`rehydrate`).
# All three quadratics this sprint fixed lived under this one green gate;
# these three routes exercise those paths directly so a regression in any of
# them reds here instead of hiding behind an unrelated assertion again.

measure_mst_insert() {
  label=$1
  size=$2
  start=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  "$WORK/perf-native" mst-insert "$size" > "$WORK/$label.out"
  finish=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  grep -F -q "MSTINSERT $size $size" "$WORK/$label.out" || fail "MST insert route failed at $size rows"
  awk -v start="$start" -v finish="$finish" 'BEGIN { printf "%.6f", finish - start }'
}

MSTINSERT_SMALL=$(measure_mst_insert mst-insert-1000 1000)
MSTINSERT_LARGE=$(measure_mst_insert mst-insert-2000 2000)
if ! awk -v small="$MSTINSERT_SMALL" -v large="$MSTINSERT_LARGE" 'BEGIN {
  ratio = large / small
  exit ! (large <= 3.5 && ratio <= 3.5)
}'; then
  fail "MST insert scaling exceeded bounds: 1000=$MSTINSERT_SMALL s 2000=$MSTINSERT_LARGE s"
fi
echo "MST insert scaling: 1000=$MSTINSERT_SMALL s 2000=$MSTINSERT_LARGE s"

measure_export() {
  label=$1
  size=$2
  start=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  "$WORK/perf-native" export "$size" > "$WORK/$label.out"
  finish=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  grep -F -q "EXPORT $size " "$WORK/$label.out" || fail "export route failed at $size rows"
  awk -v start="$start" -v finish="$finish" 'BEGIN { printf "%.6f", finish - start }'
}

# Export and rehydrate each sign or verify a commit, a fixed cost per run that
# does not grow with the row count: about 0.3-0.5 s since the secp256k1 field and
# scalar limbs became boxed `U64` (#3427; unboxing is N5, #3428).  The ratio bound
# is what catches a quadratic; the absolute one allows for that fixed cost.
EXPORT_SMALL=$(measure_export export-1000 1000)
EXPORT_LARGE=$(measure_export export-2000 2000)
if ! awk -v small="$EXPORT_SMALL" -v large="$EXPORT_LARGE" 'BEGIN {
  ratio = large / small
  exit ! (large <= 3.0 && ratio <= 2.5)
}'; then
  fail "export scaling exceeded bounds: 1000=$EXPORT_SMALL s 2000=$EXPORT_LARGE s"
fi
# Pinned against this fixed synthetic corpus — a graph walk that silently
# dropped or duplicated reachable nodes would still print "EXPORT $size "
# but with a different block count.
grep -F -q "EXPORT 1000 1278" "$WORK/export-1000.out" || fail 'export block count drifted at 1000 rows'
grep -F -q "EXPORT 2000 2535" "$WORK/export-2000.out" || fail 'export block count drifted at 2000 rows'
echo "export scaling: 1000=$EXPORT_SMALL s 2000=$EXPORT_LARGE s"

measure_rehydrate() {
  label=$1
  size=$2
  start=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  "$WORK/perf-native" rehydrate "$size" > "$WORK/$label.out"
  finish=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  grep -F -q "REHYDRATE $size OK" "$WORK/$label.out" || fail "rehydrate route failed at $size rows"
  awk -v start="$start" -v finish="$finish" 'BEGIN { printf "%.6f", finish - start }'
}

REHYDRATE_SMALL=$(measure_rehydrate rehydrate-1000 1000)
REHYDRATE_LARGE=$(measure_rehydrate rehydrate-2000 2000)
if ! awk -v small="$REHYDRATE_SMALL" -v large="$REHYDRATE_LARGE" 'BEGIN {
  ratio = large / small
  exit ! (large <= 3.0 && ratio <= 2.5)
}'; then
  fail "rehydrate scaling exceeded bounds: 1000=$REHYDRATE_SMALL s 2000=$REHYDRATE_LARGE s"
fi
# Pinned against this fixed synthetic corpus — the driver itself already
# panics if the recovered commit's data CID disagrees with the CID it
# built the graph from, and this pins the specific root so a rehydrate
# that landed on a different-but-still-self-consistent root also reds.
grep -F -q "REHYDRATE 1000 OK root=bafyreicxu3nelkrlk4qshzzfhw5elx74sunybhcasxknazig2n7foegsyu" \
  "$WORK/rehydrate-1000.out" || fail 'rehydrate root CID drifted at 1000 rows'
grep -F -q "REHYDRATE 2000 OK root=bafyreicw3pzj4d4qkmxvx5vhtvfpyn5byiqbd4arsyufrvfk7ycjmoxe5y" \
  "$WORK/rehydrate-2000.out" || fail 'rehydrate root CID drifted at 2000 rows'
echo "rehydrate scaling: 1000=$REHYDRATE_SMALL s 2000=$REHYDRATE_LARGE s"

# #3210 (a-byte-costs-a-byte, S1): allocation footprint of the inbound HTTP
# request path (`lib.server_core.handleBytes`), pinned against a stable
# small workload so a future ReadBuffer/parsing change that blows up
# per-request allocation reds here rather than only in a hand-run probe.
# Measured 2,390,496-2,390,928 bytes across four repeated runs at
# N=4/bodyBytes=256 on this box; the threshold below gives >3x headroom.
INBOUND_ALLOC_THRESHOLD=8000000

measure_inbound_alloc() {
  n=$1
  body_bytes=$2
  "$WORK/perf-native" inbound-alloc "$n" "$body_bytes" > "$WORK/inbound-alloc.out" 2> "$WORK/inbound-alloc.err"
  require_empty "$WORK/inbound-alloc.err" inbound-alloc
  grep -F -q 'status=HTTP/1.1 200 OK' "$WORK/inbound-alloc.out" ||
    fail 'inbound-alloc route did not answer 200'
  alloc_line=$(grep '^INBOUNDALLOC allocBytes=' "$WORK/inbound-alloc.out") ||
    fail 'inbound-alloc probe printed no allocBytes line'
  rest="${alloc_line#INBOUNDALLOC allocBytes=}"
  echo "${rest%% *}"
}

INBOUND_ALLOC=$(measure_inbound_alloc 4 256)
if [ "$INBOUND_ALLOC" -ge "$INBOUND_ALLOC_THRESHOLD" ]; then
  fail "inbound-alloc footprint regressed: allocBytes=$INBOUND_ALLOC (>= $INBOUND_ALLOC_THRESHOLD)"
fi
echo "inbound-alloc: N=4 bodyBytes=256 allocBytes=$INBOUND_ALLOC (< $INBOUND_ALLOC_THRESHOLD)"

# #3309 (a-page-costs-a-page): `listRecords`, `listBlobs`, and the
# `persistTransition` seam's `blobsMoved` decision each used to cost the
# repository's size rather than the page/request asked for (#2773, #3262,
# #3263). `pds/test/cost_curve_main.mdk` already reports a per-request
# microsecond figure for each named route against a `synth_repo_main.mdk`
# corpus; these three arms grade that figure's doubling ratio the same way
# the four arms above grade `performance_resource_main.mdk`'s.
if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$COST_CURVE_DRIVER" -o "$WORK/cost-curve-native" > "$WORK/cost-curve-build.log" 2>&1; then
  cat "$WORK/cost-curve-build.log" >&2
  fail 'cost curve driver build failed'
fi

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$SYNTH_REPO_DRIVER" -o "$WORK/synth-repo-native" > "$WORK/synth-repo-build.log" 2>&1; then
  cat "$WORK/synth-repo-build.log" >&2
  fail 'synth repo corpus builder build failed'
fi

mkdir -p "$WORK/cost-corpus-small" "$WORK/cost-corpus-large"
"$WORK/synth-repo-native" build one-collection "$WORK/cost-corpus-small" 1000 200 1 \
  > "$WORK/cost-corpus-small.log" 2>&1 || fail 'small cost-curve corpus build failed'
"$WORK/synth-repo-native" build one-collection "$WORK/cost-corpus-large" 10000 12800 1 \
  > "$WORK/cost-corpus-large.log" 2>&1 || fail 'large cost-curve corpus build failed'

# Pulls one route's `us=` figure out of `cost_curve_main.mdk`'s fixed-format
# output line, the same way `measure_inbound_alloc` pulls `allocBytes=`.
route_us() {
  route=$1
  file=$2
  prefix="$route us="
  line=$(grep "^$prefix" "$file") || fail "cost-curve output missing a $route line"
  rest=${line#"$prefix"}
  echo "${rest%% *}"
}

# Runs `cost-curve-native` with whatever arguments the caller gives it after
# the result label, and fails on any stderr output.
run_cost_curve() {
  label=$1
  shift
  MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$WORK/cost-curve-native" "$@" \
    > "$WORK/$label.out" 2> "$WORK/$label.err"
  require_empty "$WORK/$label.err" "cost-curve ($label)"
}

measure_list_records() {
  label=$1
  dir=$2
  run_cost_curve "$label" "$dir" bulk.synth.record 50
  route_us listRecords "$WORK/$label.out"
}

LISTRECORDS_SMALL=$(measure_list_records list-records-small "$WORK/cost-corpus-small")
LISTRECORDS_LARGE=$(measure_list_records list-records-large "$WORK/cost-corpus-large")
if ! awk -v small="$LISTRECORDS_SMALL" -v large="$LISTRECORDS_LARGE" 'BEGIN {
  ratio = large / small
  exit ! (large <= 6000 && ratio <= 3.0)
}'; then
  fail "listRecords scaling exceeded bounds: 1000-record=${LISTRECORDS_SMALL}us 10000-record=${LISTRECORDS_LARGE}us"
fi
echo "listRecords scaling: 1000-record=${LISTRECORDS_SMALL}us 10000-record=${LISTRECORDS_LARGE}us"

measure_list_blobs() {
  label=$1
  dir=$2
  run_cost_curve "$label" "$dir" bulk.synth.record 50
  route_us listBlobs "$WORK/$label.out"
}

LISTBLOBS_SMALL=$(measure_list_blobs list-blobs-small "$WORK/cost-corpus-small")
LISTBLOBS_LARGE=$(measure_list_blobs list-blobs-large "$WORK/cost-corpus-large")
if ! awk -v small="$LISTBLOBS_SMALL" -v large="$LISTBLOBS_LARGE" 'BEGIN {
  ratio = large / small
  exit ! (large <= 400 && ratio <= 3.0)
}'; then
  fail "listBlobs scaling exceeded bounds: 200-blob=${LISTBLOBS_SMALL}us 12800-blob=${LISTBLOBS_LARGE}us"
fi
echo "listBlobs scaling: 200-blob=${LISTBLOBS_SMALL}us 12800-blob=${LISTBLOBS_LARGE}us"

# `persist <dir> <reps>` times the real `persistTransition` seam with the
# same store on both sides of the comparison, so no half persists and only
# the decision — `blobsMoved` included — is measured; see the mode's own
# doc comment in `cost_curve_main.mdk`.
measure_blobs_moved() {
  label=$1
  dir=$2
  run_cost_curve "$label" persist "$dir" 1000
  route_us persistTransition "$WORK/$label.out"
}

BLOBSMOVED_SMALL=$(measure_blobs_moved blobs-moved-small "$WORK/cost-corpus-small")
BLOBSMOVED_LARGE=$(measure_blobs_moved blobs-moved-large "$WORK/cost-corpus-large")
if ! awk -v small="$BLOBSMOVED_SMALL" -v large="$BLOBSMOVED_LARGE" 'BEGIN {
  ratio = large / small
  exit ! (large <= 60 && ratio <= 4.0)
}'; then
  fail "blobsMoved scaling exceeded bounds: 200-blob=${BLOBSMOVED_SMALL}us 12800-blob=${BLOBSMOVED_LARGE}us"
fi
echo "blobsMoved scaling: 200-blob=${BLOBSMOVED_SMALL}us 12800-blob=${BLOBSMOVED_LARGE}us"

echo "PASS: MST — 11 official-reference cases; 17 covering-proof rows (13 narrower than the whole tree); 14 hostile routes; 3 lexical controls; $ENGINE_GRADE"
