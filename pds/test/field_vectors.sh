#!/bin/sh
# Reference-corpus gate for pds/lib/field.mdk (S-field, #1699 field 10x2^26
# limbs).
#
# Grades the pure-Medaka secp256k1 field arithmetic against a corpus
# generated from libsecp256k1 at the pinned commit (pds/test/vectors/) —
# never against a self-captured golden (G5,
# docs/design/ATPROTO-PDS-DESIGN.md §5). The pin and the extraction procedure
# are ledgered in pds/test/VECTOR-PROVENANCE.txt; the generator is
# pds/tools/gen_field_corpus.sh (a TOOL, not a gate: it needs network).
#
# Two engines:
#   Phase A (eval)   — bounded (--stride 7, ~135 of the 944 rows, all seven
#                      ops represented) so the interpreter arm stays fast.
#                      Measured: stride 1 is ~83 s under eval, stride 7 ~14 s.
#   Phase B (native) — the FULL corpus, all 944 rows, no bound (~0.3 s).
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

DRIVER="$ROOT/pds/test/field_vectors_main.mdk"
CORPUS="${FIELD_CORPUS:-$ROOT/pds/test/vectors/field_reference_corpus.txt}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# Rows the corpus commits today: 44 each of red/sqr/neg/inv + 256 each of
# mul/add/sub. RAISE THIS when rows are added to the corpus.
FLOOR=944

# ── Phase A — eval engine, bounded ──────────────────────────────────────
echo "phase A: eval engine (--stride 7)"
EVAL_OUT="$WORK/eval.out"
"$MEDAKA" run "$DRIVER" --stride 7 "$CORPUS" >"$EVAL_OUT" 2>&1
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

# ── Phase B — native engine, full corpus ────────────────────────────────
echo "phase B: native engine (full corpus)"
DRIVER_BIN="$WORK/field_driver"
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
if [ "$native_checked" -lt "$FLOOR" ]; then
  echo "FAIL: only $native_checked rows checked (native), expected >= $FLOOR"
  exit 1
fi

echo "PASS: field vectors — $native_checked rows (eval: $eval_checked at stride 7, native: $native_checked)"
exit 0
