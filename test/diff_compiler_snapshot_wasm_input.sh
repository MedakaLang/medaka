#!/bin/sh
# Snapshot's Wasm arm must construct its own explicit input. This verifies that a
# WASM-only render receives the method-arity table rather than inheriting state
# from the preceding LLVM render in a combined snapshot.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
[ -x "$MEDAKA" ] || { echo "build the compiler first: make medaka"; exit 2; }

WASM_EMIT="$ROOT/compiler/backend/wasm_emit.mdk"
EMIT_SUPPORT="$ROOT/compiler/backend/emit_support.mdk"
# `export` a value/function signature now formats split — its own line above
# the signature (#1804) — so a single-line `grep -F 'export <sig>'` is a false
# negative against correctly-formatted source. Check that a specific NAME's
# declaration line is directly preceded by an `export` keyword, whether split
# (a lone `export` line immediately above) or collapsed (`export <name> ...`
# on one line) — never that `export` and the name merely occur SOMEWHERE in
# the file (that would also pass on a private definition, or on the name
# appearing only inside a comment).  $2, if non-empty, is additionally
# required as a substring of that same declaration line (the signature).
export_decl_present() {
  name="$1" sig="$2"
  awk -v n="$name" -v s="$sig" '
    {
      cand = ""
      if (pending) { cand = $0; pending = 0 }
      else if ($0 ~ /^export[ \t]*$/) { pending = 1; next }
      else if ($0 ~ /^export /) { cand = substr($0, 8) }
      if (cand != "" && cand ~ ("^" n "([ :(]|$)") && (s == "" || index(cand, s) > 0)) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$WASM_EMIT"
}
export_decl_present makeWasmEmitInput '' \
  && export_decl_present emitProgram 'emitProgram : WasmEmitInput -> CProgram -> String' \
  && export_decl_present emitProgramGaps 'emitProgramGaps : WasmEmitInput -> CProgram -> List String' \
  || { echo "FAIL: WasmEmitInput API is incomplete"; exit 1; }
for legacy in installMethodIface installDeclRetTypes installCtorFloatFields installMainIsFloatHint installRecFieldOrders methodIfaceTableRef methodIfaceIndexRef setMethodIfaceTable methodIfaceOf methodArityOf mainIsFloatHintRef declRetTypesRef declRetTypesMapW ctorFloatFieldsRef declRecFieldsRef recFieldTableW; do
  if grep -Eq "^(export )?$legacy([ :]|$)" "$WASM_EMIT" "$EMIT_SUPPORT"; then
    echo "FAIL: legacy Wasm semantic hook remains: $legacy"
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/wasm_snapshot_input.mdk"
mkdir "$WORK/wasm-only" "$WORK/combined"

# `score = x => 7` has a zero-clause impl body but a one-argument method. The
# Wasm emitter must read the explicit method arity and eta-expand it.
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
echo "snapshot Wasm input: WASM-only equals combined; Score impl receiver arity is explicit"
