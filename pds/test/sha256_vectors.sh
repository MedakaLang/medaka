#!/bin/sh
# Vector-corpus gate for pds/lib/sha256.mdk (S-sha256, #1698).
#
# Grades the pure-Medaka SHA-256 against an externally-sourced NIST/CAVS
# corpus (pds/test/vectors/*) — never against a self-captured golden (G5,
# docs/design/ATPROTO-PDS-DESIGN.md §5). Expected digests are ledgered in
# pds/test/VECTOR-PROVENANCE.txt (see pds/test/sha256_vector_driver.mdk's
# comment for the file grammar).
#
# Two engines:
#   Phase A (eval)   — bounded (--max-bytes 64) so the interpreter arm stays
#                       fast; the ~210KB SHA256LongMsg.rsp records are
#                       skipped here and picked up by phase B.
#   Phase B (native) — the FULL ledger-owned corpus, no bound.
#
# Auto-enrolled in the `sqlite` CI shard by the `'pds/test/*'` glob
# (pds/README.md "CI classification policy", RUN-PDS0-001 A4 /
# RUN-PDS0-003(a)) — this script lands directly under pds/test/, so no
# ci.yml edit is needed.
#
# Requires a built native `medaka` + `medaka_emitter` ($MEDAKA_ROOT /
# $MEDAKA / $MEDAKA_EMITTER).
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
[ -x "$MEDAKA" ] || { echo "build medaka first (missing $MEDAKA)"; exit 2; }
export MEDAKA_ROOT
export MEDAKA_EMITTER="$ROOT/medaka_emitter"

DRIVER="$ROOT/pds/test/sha256_vector_driver.mdk"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

VECTOR_LIST="$WORK/vector-files.lst"
if ! sh "$ROOT/pds/test/vector_provenance.sh" --files-for S-sha256 > "$VECTOR_LIST"; then
  echo "FAIL: could not derive SHA-256 vector files from the provenance ledger"
  exit 1
fi
set --
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  set -- "$@" "$ROOT/$rel"
done < "$VECTOR_LIST"
vector_count=$#
if [ "$vector_count" -eq 0 ]; then
  echo "FAIL: provenance ledger names no S-sha256 vector files"
  exit 1
fi

# ── Phase A — eval engine, bounded ──────────────────────────────────────
echo "phase A: eval engine (--max-bytes 64)"
EVAL_OUT="$WORK/eval.out"
"$MEDAKA" run "$DRIVER" --max-bytes 64 "$@" >"$EVAL_OUT" 2>&1
eval_rc=$?
cat "$EVAL_OUT"
if [ "$eval_rc" -ne 0 ]; then
  echo "FAIL: eval-engine phase exited $eval_rc"
  exit 1
fi
eval_checked=$(awk -F'[: ]+' '/ ok,/ { s += $2 } END { print s+0 }' "$EVAL_OUT")

# ── Phase B — native engine, full corpus ────────────────────────────────
echo "phase B: native engine (full corpus)"
DRIVER_BIN="$WORK/sha256_driver"
BUILD_LOG="$WORK/build.log"
"$MEDAKA" build "$DRIVER" -o "$DRIVER_BIN" >"$BUILD_LOG" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: could not build $DRIVER"
  cat "$BUILD_LOG"
  exit 1
fi

NATIVE_OUT="$WORK/native.out"
"$DRIVER_BIN" "$@" >"$NATIVE_OUT" 2>&1
native_rc=$?
cat "$NATIVE_OUT"
if [ "$native_rc" -ne 0 ]; then
  echo "FAIL: native-engine phase exited $native_rc"
  exit 1
fi
native_checked=$(awk -F'[: ]+' '/ ok,/ { s += $2 } END { print s+0 }' "$NATIVE_OUT")

# ── Assertion floor (anti-rot) ──────────────────────────────────────────
# 65 (ShortMsg) + 64 (LongMsg) + 3 (worked examples) — raise this when
# vectors are added.
FLOOR=132
EVAL_FLOOR=67
# A non-numeric count makes `[` ERROR rather than compare, and with `set -e`
# off control falls through to the PASS branch — so the floor guard could
# never fail on the one thing it exists to catch (RUN-PDS0-040, F20). Check
# numeric-ness first.
case "$native_checked" in
  ''|*[!0-9]*)
    echo "FAIL: native record count is not a number ('$native_checked') — the driver's summary line did not parse; the anti-rot floor could not be graded."
    exit 1 ;;
esac
case "$eval_checked" in
  ''|*[!0-9]*)
    echo "FAIL: eval record count is not a number ('$eval_checked') — the driver's summary line did not parse; the anti-rot floor could not be graded."
    exit 1 ;;
esac
if [ "$eval_checked" -lt "$EVAL_FLOOR" ]; then
  echo "FAIL: only $eval_checked records checked (eval), expected >= $EVAL_FLOOR"
  exit 1
fi
if [ "$native_checked" -lt "$FLOOR" ]; then
  echo "FAIL: only $native_checked records checked (native), expected >= $FLOOR"
  exit 1
fi

echo "PASS: sha256 vectors — $native_checked records across $vector_count files (eval: $eval_checked, native: $native_checked)"
exit 0
