#!/bin/sh
# Reference-corpus gate for pds/lib/scalar.mdk (S-scalar, #1700 secp256k1
# group ops + RFC 6979 + low-S).
#
# Grades the pure-Medaka secp256k1 SCALAR arithmetic (mod the group order n)
# against a corpus generated from libsecp256k1 at the pinned commit
# (pds/test/vectors/) — never against a self-captured golden (G5,
# docs/design/ATPROTO-PDS-DESIGN.md §5). The pin and the extraction procedure
# are ledgered in pds/test/VECTOR-PROVENANCE.txt; the generator is
# pds/tools/gen_scalar_corpus.sh (a TOOL, not a gate: it needs network).
#
# Two engines:
#   Phase A (eval)   — bounded (--stride 26, 40 of the 1028 rows, with at
#                      least 2 rows for EVERY one of the eight ops) so the
#                      interpreter arm stays fast.
#                      Measured on this box (wall-clock, shared machine):
#                      stride 26 ~19 s, stride 52 ~6.5 s.  The whole cost is
#                      `inv`: one inv row is ~451 scalar multiplies under the
#                      tree-walking interpreter (~11-12 s), and the other 19
#                      rows of a stride-26 run together take about 1 s.  Do
#                      NOT drop `inv` to lower the stride — it is the op the
#                      corpus most needs to grade.
#   Phase B (native) — the FULL corpus, all 1028 rows, no bound (~0.6 s).
#
# The corpus path is spelled out here rather than enumerated, matching the
# in-tree precedent (pds/test/sha256_vectors.sh names V1/V2/V3 explicitly).
# Recorded as a known divergence from the ledger's dynamic enumeration —
# see this slice's DEBT.md row.
#
# Auto-enrolled in the `sqlite` CI shard by the `'pds/test/*'` glob
# (pds/README.md "CI classification policy"), so no ci.yml edit is needed.
#
# Requires a built native `medaka` + `medaka_emitter` ($MEDAKA_ROOT /
# $MEDAKA / $MEDAKA_EMITTER).
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
[ -x "$MEDAKA" ] || { echo "build medaka first (missing $MEDAKA)"; exit 2; }
export MEDAKA_ROOT
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

DRIVER="$ROOT/pds/test/scalar_vectors_main.mdk"
CORPUS="${SCALAR_CORPUS:-$ROOT/pds/test/vectors/scalar_reference_corpus.txt}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# Rows the corpus commits today: 52 each of red/neg/inv/high/ovf + 256 each of
# mul/add/sub. RAISE THIS when rows are added to the corpus.
FLOOR=1028

STRIDE=26

# ── Phase A — eval engine, bounded ──────────────────────────────────────
echo "phase A: eval engine (--stride $STRIDE)"
EVAL_OUT="$WORK/eval.out"
"$MEDAKA" run "$DRIVER" --stride "$STRIDE" "$CORPUS" >"$EVAL_OUT" 2>&1
eval_rc=$?
grep -v '^PASS' "$EVAL_OUT"
if [ "$eval_rc" -ne 0 ]; then
  echo "FAIL: eval-engine phase exited $eval_rc"
  exit 1
fi
if [ "$(tail -1 "$EVAL_OUT")" != "TOTAL: PASS" ]; then
  echo "FAIL: eval-engine phase did not end in TOTAL: PASS"
  exit 1
fi
eval_checked=$(awk -F'[:/ ]+' '/^counted: /{ print $3 }' "$EVAL_OUT")

# Every op must actually be exercised by the strided subset: an op that
# reaches 0 means the stride has walked past a whole block, which would make
# this phase silently narrower than its header claims.
if grep -q '^op .*: 0 ok' "$EVAL_OUT"; then
  echo "FAIL: stride $STRIDE leaves an op with 0 rows in the eval phase"
  exit 1
fi

# ── Phase B — native engine, full corpus ────────────────────────────────
echo "phase B: native engine (full corpus)"
DRIVER_BIN="$WORK/scalar_driver"
BUILD_LOG="$WORK/build.log"
# Redirect, never pipe: `medaka build`'s exit code does not survive a pipe.
"$MEDAKA" build "$DRIVER" -o "$DRIVER_BIN" >"$BUILD_LOG" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: could not build $DRIVER"
  cat "$BUILD_LOG"
  exit 1
fi

NATIVE_OUT="$WORK/native.out"
"$DRIVER_BIN" "$CORPUS" >"$NATIVE_OUT" 2>&1
native_rc=$?
grep -v '^PASS' "$NATIVE_OUT"
if [ "$native_rc" -ne 0 ]; then
  echo "FAIL: native-engine phase exited $native_rc"
  exit 1
fi
if [ "$(tail -1 "$NATIVE_OUT")" != "TOTAL: PASS" ]; then
  echo "FAIL: native-engine phase did not end in TOTAL: PASS"
  exit 1
fi
native_checked=$(awk -F'[:/ ]+' '/^counted: /{ print $3 }' "$NATIVE_OUT")

# ── Assertion floor (anti-rot) ──────────────────────────────────────────
# A non-numeric count makes `[` ERROR rather than compare, and with `set -e`
# off control falls through to the PASS branch — so the floor guard could
# never fail on the one thing it exists to catch (RUN-PDS0-040, F20). Check
# numeric-ness first.
case "$native_checked" in
  ''|*[!0-9]*)
    echo "FAIL: native row count is not a number ('$native_checked') — the driver's summary line did not parse; the anti-rot floor could not be graded."
    exit 1 ;;
esac
if [ "$native_checked" -lt "$FLOOR" ]; then
  echo "FAIL: only $native_checked rows checked (native), expected >= $FLOOR"
  exit 1
fi

echo "PASS: scalar vectors — $native_checked rows (eval: $eval_checked at stride $STRIDE, native: $native_checked)"
exit 0
