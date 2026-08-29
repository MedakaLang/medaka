#!/bin/sh
# The eval interpreter's own agreement with the native binary on the focused
# representative repo transcript — the third engine, byte-for-byte.
#
# ── WHY THIS IS NIGHTLY AND NOT IN THE MERGE QUEUE (#2208, S-2-pds-pole) ──────
#
# This arm used to live inside pds/test/repo_vectors.sh, where it WAS that
# gate: profiled arm-by-arm, `medaka run … --representative` was 1091.56s of a
# 1105.3s run — 98.76%. The gate was the pole of the whole suite (948.9s in
# test/gate_cost_baseline.json, 14% of the 6683s budget) and no packing could go
# under it, because a gate is indivisible.
#
# The cost is the ENGINE, not the assertions. The same driver, same corpus, same
# box:
#
#     medaka run  … --representative   1091.56s
#     ./native    … --representative      0.335s   (byte-identical output)
#
# so the routes themselves moved to the compiled engines, where they now run on
# BOTH native and Wasm with a cross-engine `cmp` — see the header of
# pds/test/repo_vectors.sh. What is left here is the one thing that genuinely
# needs the interpreter: whether `medaka run` agrees with the compiled engines
# on this transcript.
#
# #2181's charter clause reads: "what NEVER [qualifies for nightly]: anything
# whose failure means a wrong answer shipped — soundness-class gates stay in the
# queue regardless of cost." The soundness content of the original gate — the
# native==Wasm differential over the official atproto vectors, the 19
# hostile-route rejections, and now all 43 representative routes — is still in
# the queue. What moved here is a BREADTH arm: a third engine's agreement, which
# is the shape the charter licenses to be demoted, and the shape #1962 set when
# pds/nightly/signing_parity was evicted from the `sqlite` shard for cost.
#
# It is a STRONGER check here than it was in the queue. In repo_vectors.sh the
# eval arm was graded by grepping four count lines out of its stdout; here its
# bytes are `cmp`ed against the native binary's, so any divergence anywhere in
# the 46-line transcript reds this, not just a changed count.
#
# ⚠️ This takes ~18 minutes of wall clock. That is the interpreter, not a hang.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/repo_vectors_main.mdk"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-repo-eval.XXXXXX")
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
sh "$ROOT/pds/test/vector_provenance.sh" --files-for P1-D-REPO > "$WORK/vector-files"
[ "$(wc -l < "$WORK/vector-files" | tr -d ' ')" = 1 ] || fail 'expected exactly one ledger-owned P1-D corpus'
CORPUS_REL=$(sed -n '1p' "$WORK/vector-files")
CORPUS="$ROOT/$CORPUS_REL"

# The reference arm. Cheap (~7s), and it is what the interpreter is graded
# against — grading eval against itself would prove nothing.
if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/native" > "$WORK/native-build.log" 2>&1; then
  cat "$WORK/native-build.log" >&2
  fail 'native driver build failed'
fi
"$WORK/native" "$CORPUS" --representative > "$WORK/native-rep.out" 2> "$WORK/native-rep.err"
require_empty "$WORK/native-rep.err" 'native representative'
[ "$(tail -1 "$WORK/native-rep.out")" = 'REPRESENTATIVE: PASS' ] || fail 'native did not end in REPRESENTATIVE: PASS'

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" run "$DRIVER" "$CORPUS" --representative > "$WORK/eval.out" 2> "$WORK/eval.err"; then
  cat "$WORK/eval.out" >&2
  cat "$WORK/eval.err" >&2
  fail 'eval driver failed'
fi
require_empty "$WORK/eval.err" eval

grep -F -q 'representative-external: 6/6 official-atproto initialization/create/CAR checks' "$WORK/eval.out" || fail 'eval representative external count is incomplete'
grep -F -q 'focused-rejected: 27/27 named routes' "$WORK/eval.out" || fail 'eval F1 rejection count is incomplete'
grep -F -q 'focused-controls: 8/8 valid routes' "$WORK/eval.out" || fail 'eval F1 boundary controls are incomplete'
grep -F -q 'OP CREATE PASS' "$WORK/eval.out" || fail 'eval missed the representative CREATE'
grep -F -q 'CREATE CAR PASS order=' "$WORK/eval.out" || fail 'eval missed representative exact CAR bytes/order'
[ "$(tail -1 "$WORK/eval.out")" = 'REPRESENTATIVE: PASS' ] || fail 'eval did not end in REPRESENTATIVE: PASS'

cmp "$WORK/eval.out" "$WORK/native-rep.out" || fail 'eval interpreter and native binary disagree on the representative transcript'

echo 'PASS: repo — eval interpreter == native binary, byte-for-byte, on the focused representative official transcript'
