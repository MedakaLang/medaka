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
# The wasm host reads a path with no granted authority beside it, so every grant
# the program writes must need no check: the whole domain, or exact paths
# (`wasmGrantConfined`, compiler/backend/wasm_emit.mdk).  A library wrapper that
# forwards its caller's grant builds; a narrow grant is a located compile-time
# error where the program writes it, never an unconfined read.
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
  elif [ "$st" -ne 0 ] && printf '%s' "$out" | grep -qF "$want" &&
       printf '%s' "$out" | grep -qE "$name\\.mdk:[0-9]+:[0-9]+:"; then
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
  "file_grant_pattern_refused.mdk:2:24: \`readFile\` is given the file grant [\"cfg/*\"], but a wasm build cannot confine a file operation to a pattern"

check_grant "file_grant_wrapper_narrow_caller_refused" \
'import io.{readLines}

cfgLines : String -> <FileRead "cfg/*"> Result String (List String)
cfgLines name = readLines ("cfg/" ++ name)

main = println (cfgLines "a.txt")' \
  "file_grant_wrapper_narrow_caller_refused.mdk:4:26: \`readLines\` is given the file grant [\"cfg/*\"], but a wasm build cannot confine a file operation to a pattern"

check_grant "file_grant_wrapper_whole_domain_built" \
'import io.{readLines}

linesOf : String -> <FileRead> Result String (List String)
linesOf p = readLines p

main = println (linesOf "data.txt")' \
  ""

check_grant "file_grant_wrapper_literal_built" \
'import io.{readLines}

main = println (readLines "cfg/a.txt")' \
  ""

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

# An exact call grant cannot discharge a declared directory bound: its path
# can name a symlink whose physical target is outside that directory.
check_grant "file_declared_bound_exact_call_refused" \
'readCfg : Unit -> <FileRead "cfg/*"> Result String String
readCfg _ = readFile "cfg/link/a.txt"

main = println (readCfg ())' \
  '`declared FileRead bound` is given the file grant ["cfg/*"]'

check_grant "file_declared_bound_alias_refused" \
'helper _ = readFile "cfg/link/a.txt"

readCfg : Unit -> <FileRead "cfg/*"> Result String String
readCfg = helper

main = println (readCfg ())' \
  'but a wasm build cannot confine a file operation to a pattern'

check_grant "file_declared_bound_pure_built" \
'quiet : Unit -> <FileRead "cfg/*"> Option Int
quiet _ = Some 7

main = println (quiet ())' \
  ""

check_grant "file_declared_read_bound_write_only_built" \
'writeOnly : Unit -> <FileRead "cfg/*", FileWrite> Result String Unit
writeOnly _ = writeFileBytes "data.txt" (arrayFromList [120])

main = println (writeOnly ())' \
  ""

check_grant "file_declared_bound_newtype_built" \
'newtype Wrapper = Wrapper Int

quiet : Unit -> <FileRead "cfg/*"> Wrapper
quiet _ = Wrapper 7

main = match quiet ()
  Wrapper n => println n' \
  ""

check_grant "user_file_label_built" \
'effect FileRead Prefix

readData : Unit -> <FileRead "user/*", IO> Result String String
readData _ = readFile "data.txt"

main = println (readData ())' \
  ""

# A callback can share a spelling with a live pure global. Only the callback's
# lexical binding determines whether the declared bound needs host confinement.
check_grant "file_bound_callback_shadow_refused" \
'cb : Unit -> <IO> Result String String
cb _ = Ok "pure"

readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg cb = cb ()

main =
  let _ = cb ()
  println (readCfg (_ => readFile "data.txt"))' \
  '`declared FileRead bound` is given the file grant ["cfg/*"]'

check_grant "file_bound_callback_helper_refused" \
'cb : Unit -> <IO> Result String String
cb _ = Ok "pure"

invoke cb = cb ()
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = invoke given

main =
  let _ = cb ()
  println (readCfg (_ => readFile "data.txt"))' \
  'but a wasm build cannot confine a file operation to a pattern'

check_grant "file_bound_callback_let_refused" \
'cb : Unit -> <IO> Result String String
cb _ = Ok "pure"

invoke given =
  let cb = given
  cb ()
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = invoke given

main =
  let _ = cb ()
  println (readCfg (_ => readFile "data.txt"))' \
  'but a wasm build cannot confine a file operation to a pattern'

check_grant "file_bound_callback_lambda_refused" \
'cb : Unit -> <IO> Result String String
cb _ = Ok "pure"

invoke given = (cb => cb ()) given
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = invoke given

main =
  let _ = cb ()
  println (readCfg (_ => readFile "data.txt"))' \
  'but a wasm build cannot confine a file operation to a pattern'

check_grant "file_bound_callback_match_refused" \
'cb : Unit -> <IO> Result String String
cb _ = Ok "pure"

invoke given = match Some given
  Some cb => cb ()
  None => Ok "none"
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = invoke given

main =
  let _ = cb ()
  println (readCfg (_ => readFile "data.txt"))' \
  'but a wasm build cannot confine a file operation to a pattern'

check_grant "file_bound_callback_returned_refused" \
'cb : Unit -> <IO> Result String String
cb _ = Ok "pure"

identity cb = cb
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = (identity given) ()

main =
  let _ = cb ()
  println (readCfg (_ => readFile "data.txt"))' \
  'but a wasm build cannot confine a file operation to a pattern'

check_grant "file_bound_callback_returned_helper_refused" \
'cb : Unit -> <IO> Result String String
cb _ = Ok "pure"

identity cb = cb
invoke given = (identity given) ()
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = invoke given

main =
  let _ = cb ()
  println (readCfg (_ => readFile "data.txt"))' \
  'but a wasm build cannot confine a file operation to a pattern'

check_grant "file_bound_callback_do_refused" \
'cb : Unit -> <IO> Result String String
cb _ = Ok "pure"

invoke given = do
  cb <- Ok given
  let call = cb
  call ()
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = invoke given

main =
  let _ = cb ()
  println (readCfg (_ => readFile "data.txt"))' \
  'but a wasm build cannot confine a file operation to a pattern'

# A nested binder does not shadow an extern outside that binder's scope.
check_grant "file_bound_out_of_scope_extern_built" \
'readCfg : Unit -> <FileRead "cfg/*"> String
readCfg _ =
  let keep = (intToString => intToString)
  intToString 1

main = println (readCfg ())' \
  ""

check_grant "file_bound_constrained_returned_refused" \
'interface Tag a where
  tag : a -> Bool
impl Tag String where
  tag _ = True

returnCb : Tag a => a -> b -> b
returnCb x cb =
  let _ = tag x
  cb
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = (returnCb "tag" given) ()

main = println (readCfg (_ => readFile "data.txt"))' \
  'but a wasm build cannot confine a file operation to a pattern'

check_grant "file_bound_signed_returned_refused" \
'returnCb : (Unit -> <IO> Result String String) -> Unit -> <IO> Result String String
returnCb cb = cb
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = (returnCb given) ()

main = println (readCfg (_ => readFile "data.txt"))' \
  'but a wasm build cannot confine a file operation to a pattern'

check_grant "file_bound_relay_returned_refused" \
'returnCb cb = cb
relay cb = returnCb cb
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = (relay given) ()

main = println (readCfg (_ => readFile "data.txt"))' \
  'but a wasm build cannot confine a file operation to a pattern'

check_grant "file_bound_pointfree_method_built" \
'readCfg : Unit -> <FileRead "cfg/*"> Int
readCfg _ = length [1, 2]

main = println (readCfg ())' \
  ""

check_grant "file_bound_signed_lambda_alias_built" \
'keep : Int -> Int -> Int
keep x = y => x
keepAlias = keep
readCfg : Unit -> <FileRead "cfg/*"> Int
readCfg _ =
  let _ = keep 1 2
  keepAlias 3 4

main = println (readCfg ())' \
  ""

check_grant "file_bound_alias_callback_refused" \
'type Runner = (Unit -> <IO> Result String String) -> <IO> Result String String
runCallback : Runner
runCallback cb = cb ()
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = runCallback given

main = println (readCfg (_ => readFile "data.txt"))' \
  'but a wasm build cannot confine a file operation to a pattern'

check_grant "file_read_bound_write_callback_built" \
'callWrite : (Unit -> <FileWrite "out"> Result String Unit) -> <FileWrite "out"> Result String Unit
callWrite cb = cb ()
readCfg : Unit -> <FileRead "cfg/*", FileWrite "out"> Result String Unit
readCfg _ = callWrite (_ => writeFileBytes "out" (arrayFromList [120]))

main = println (readCfg ())' \
  ""

check_grant "file_read_bound_eager_callback_construction" \
'callWrite : (Unit -> <FileWrite "out"> Result String Unit) -> <FileWrite "out"> Result String Unit
callWrite cb = cb ()
readCfg : Unit -> <FileRead "cfg/*", FileWrite "out"> Result String Unit
readCfg _ = callWrite (let _ = readFile "cfg/link" in _ => writeFileBytes "out" (arrayFromList [120]))
main = println (readCfg ())' \
  'but a wasm build cannot confine a file operation to a pattern'

if [ "$fail" -eq 0 ]; then
  echo "32 ok, 0 failing"
  exit 0
else
  echo "diff_wasm_ffi_wall: FAILURES ABOVE"
  exit 1
fi
