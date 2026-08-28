#!/usr/bin/env bash
# diff_wasm_ffi_wall.sh — #2129 regression gate: `build --target wasm` must refuse
# an FFI extern with the SAME located capability-gap message regardless of how the
# extern is referenced — a saturated call, a value-position reference (passed to a
# HOF / returned point-free), or a bare top-level reference never applied — instead
# of a generic "unbound variable" panic for the value-position/bare-reference shapes.
#
# The saturated-call shape was already correct before #2129's fix (emitAppRef /
# emitAppTail's isFfiExternW arms); the value-position and bare-reference shapes
# both fell through emitVarRefPlain's ladder to the generic gapUnboundLP fallback
# until this gate's companion fix added an isFfiExternW arm there too (mirrors the
# LLVM emitter's own emitExternEtaClosure treatment of value-position externs).
#
# No real C linkage needed: `build --target wasm` must refuse BEFORE attempting to
# emit/validate/link anything, so these fixtures never reach wasm-tools or Node —
# this gate needs only the wasm_emit_modules_main oracle binary (`sh
# test/wasm/build_wasm_oracle.sh --modules-only`), not the full wasm toolchain.
#
# Exit: 0 if all three shapes wall with the expected message; 1 on any divergence;
# 2 if the oracle binary isn't built (toolchain-skip, mirroring the other wasm
# gates' opt-in-skip convention).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITBIN="${MEDAKA_WASM_EMITTER:-$ROOT/test/bin/wasm_emit_modules_main}"

if ! [ -x "$EMITBIN" ]; then
  echo "SKIP diff_wasm_ffi_wall: $EMITBIN not built (sh test/wasm/build_wasm_oracle.sh --modules-only)"
  exit 2
fi
if ! [ -x "$MEDAKA" ]; then
  echo "SKIP diff_wasm_ffi_wall: $MEDAKA not built (make medaka)"
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

EXPECT="wasm: FFI extern '%s' is native-only — foreign C calls have no WasmGC equivalent. Build for a native target instead."

fail=0

check_one() {
  name="$1"; src="$2"; extern_name="$3"
  f="$WORK/$name.mdk"
  printf '%s\n' "$src" > "$f"
  out="$(MEDAKA_WASM_EMITTER="$EMITBIN" "$MEDAKA" build --target wasm "$f" -o "$WORK/$name.out" 2>&1)"
  st=$?
  want="$(printf "$EXPECT" "$extern_name")"
  if [ "$st" -eq 0 ]; then
    echo "FAIL $name: expected refusal (exit != 0), got exit 0"
    fail=1
  elif ! printf '%s' "$out" | grep -qF "$want"; then
    echo "FAIL $name: expected message containing:"
    echo "  $want"
    echo "  got:"
    echo "$out" | sed 's/^/  /'
    fail=1
  else
    echo "ok   $name"
  fi
}

# regression floor: the saturated-call shape was already correct pre-#2129.
check_one "saturated" \
'extern cNegate : Int -> <FFI "x"> Int

main : <FFI> Int
main = cNegate 5' \
  "cNegate"

# #2129 b6_hof: an FFI extern referenced in value position (passed to a HOF).
check_one "value_position_hof" \
'extern cNegate : Int -> <FFI "x"> Int

main : <FFI> List Int
main = map cNegate [1, 2, 3]' \
  "cNegate"

# #2129 b1_nullary: an FFI extern referenced by bare name, never applied. A
# genuinely-nullary `extern k : Int` is itself rejected by typecheck (T-FFI-NULLARY,
# compiler/FFI-ABI.md), so this fixture mirrors the *reference* shape instead: the
# extern's own type has an arrow, but the reference to it (`gNullary`, inside
# `useIt`) is a bare name that is never called.
check_one "bare_toplevel_reference" \
'extern gNullary : Unit -> <FFI "x"> Int

useIt : Unit -> Unit -> <FFI "x"> Int
useIt _ = gNullary

main : <FFI> Int
main = (useIt ()) ()' \
  "gNullary"

if [ "$fail" -eq 0 ]; then
  echo "3 ok, 0 failing"
  exit 0
else
  echo "diff_wasm_ffi_wall: FAILURES ABOVE"
  exit 1
fi
