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
# The file-grant cases at the bottom are the same kind of wall: a file operation
# the wasm host cannot confine is refused with a located message.
#
# Exit: 0 if every shape walls (or builds) as expected; 1 on any divergence;
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

# ── The file-grant wall (EFFECTS-SEMANTICS §7) ──────────────────────────────
# The wasm host reads a path with no granted authority beside it, so a file
# operation is built only when the host needs no check: its grant is the whole
# domain, or its path is a string literal the grant names exactly
# (`wasmGrantConfined`, compiler/backend/wasm_emit.mdk).  Any other grant is a
# located compile-time error, never an unconfined read.
check_grant() {
  name="$1"; src="$2"; want="$3"
  f="$WORK/$name.mdk"
  printf '%s\n' "$src" > "$f"
  out="$(MEDAKA_WASM_EMITTER="$EMITBIN" "$MEDAKA" build --target wasm "$f" -o "$WORK/$name.out" 2>&1)"
  st=$?
  if [ -z "$want" ]; then
    if [ "$st" -eq 0 ]; then echo "ok   $name"; else
      echo "FAIL $name: expected a build, got exit $st:"
      echo "$out" | sed 's/^/  /'
      fail=1
    fi
  elif [ "$st" -ne 0 ] && printf '%s' "$out" | grep -qF "$want"; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected exit != 0 and a message containing:"
    echo "  $want"
    echo "  got exit $st:"
    echo "$out" | sed 's/^/  /'
    fail=1
  fi
}

check_grant "file_grant_pattern_refused" \
'readCfg : String -> <FileRead "cfg/*"> Result String String
readCfg name = readFile ("cfg/" ++ name)

main = println (readCfg "../secret.txt")' \
  "file_grant_pattern_refused.mdk:2:24: \`readFile\` is given the file grant [\"cfg/*\"], but a wasm build cannot confine a file operation to a grant"

check_grant "file_grant_wrapper_refused" \
'import io.{readLines}

main = println (readLines "cfg/a.txt")' \
  "io.mdk:75:42: \`readFile\` is given a file grant its caller supplies, but a wasm build cannot confine a file operation to a grant"

check_grant "file_grant_literal_element_built" \
'readData : Unit -> <FileRead "data.txt"> Result String String
readData _ = readFile "data.txt"

main = println (readData ())' \
  ""

check_grant "file_grant_whole_domain_built" \
'readAny : String -> <FileRead> Result String String
readAny p = readFile p

main = println (readAny "data.txt")' \
  ""

if [ "$fail" -eq 0 ]; then
  echo "7 ok, 0 failing"
  exit 0
else
  echo "diff_wasm_ffi_wall: FAILURES ABOVE"
  exit 1
fi
