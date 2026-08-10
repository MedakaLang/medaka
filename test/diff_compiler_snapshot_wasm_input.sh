#!/bin/sh
# Snapshot's Wasm arm is independently stateful during X-W.H.  This verifies that
# a WASM-only render installs the method-arity table, rather than inheriting it
# from the preceding LLVM render in a combined snapshot.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
[ -x "$MEDAKA" ] || { echo "build the compiler first: make medaka"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/wasm_snapshot_input.mdk"
mkdir "$WORK/wasm-only" "$WORK/combined"

# `score = x => 7` has a zero-clause impl body but a one-argument method. The
# Wasm emitter must read the installed method arity and eta-expand it. The P+U
# program selects U, so the independently hand-derived result is 11.
printf '%s\n' \
  'interface Score a where' \
  '  score : a -> Int' \
  'data P = P' \
  'data U = U' \
  'impl Score P where' \
  '  score = x => 7' \
  'impl Score U where' \
  '  score = x => 11' \
  'main = score U' > "$SRC"

"$MEDAKA" snapshot --new --root "$ROOT" --out "$WORK/wasm-only" --stages WASM "$SRC" || exit 1
"$MEDAKA" snapshot --new --root "$ROOT" --out "$WORK/combined" --stages LLVM,WASM "$SRC" || exit 1

ONLY="$WORK/wasm-only/wasm_snapshot_input.md"
COMBINED="$WORK/combined/wasm_snapshot_input.md"
[ -f "$ONLY" ] && [ -f "$COMBINED" ] || { echo "FAIL: snapshot did not produce both outputs"; exit 1; }

# Compare only the WAT payload: META records the requested stage set by design.
extract_wasm() {
  awk '/^# WASM$/{on=1; next} on && /^# /{exit} on{print}' "$1"
}
extract_wasm "$ONLY" > "$WORK/only.wat"
extract_wasm "$COMBINED" > "$WORK/combined.wat"
diff -u "$WORK/only.wat" "$WORK/combined.wat" || {
  echo "FAIL: WASM-only snapshot differs from combined snapshot WASM section"
  exit 1
}

# The eta-expanded Score implementation takes its receiver. A missing method
# interface install leaves the short body arity and changes this WAT shape.
grep -q 'mdk_impl_.*_score' "$WORK/only.wat" || {
  echo "FAIL: snapshot WAT did not emit Score implementations"
  exit 1
}
grep -Fq '(func $mdk_impl_U_score (param' "$WORK/only.wat" || {
  echo "FAIL: snapshot WAT did not eta-expand Score to its declared receiver arity"
  exit 1
}
grep -q 'i32.const 11' "$WORK/only.wat" || {
  echo "FAIL: snapshot WAT lost the hand-derived U result (11)"
  exit 1
}

echo "snapshot Wasm input: WASM-only equals combined; Score(U) retains 11"
