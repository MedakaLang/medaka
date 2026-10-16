#!/usr/bin/env bash
# diff_wasm_ffi_wall.sh — #2129 regression gate: `build --target wasm` must refuse
# an FFI extern with the SAME located capability-gap message regardless of how the
# extern is referenced — a saturated call, a value-position reference (passed to a
# HOF / returned point-free), or a bare top-level reference never applied — instead
# of a generic "unbound variable" panic for the value-position/bare-reference shapes.
#
# The binding refusal for a c-only extern (`T-TARGET-NO-BINDING`: saturated call,
# value-position reference, bare reference) is pinned by test/target_fixtures_test.mdk
# (`wall_*` rows).  The emitter's own FFI arms (`emitFfiAppW`/`emitFfiEtaW`,
# compiler/backend/wasm_emit.mdk) lower a `js`-bound extern to a `jsffi` import
# (test/wasm_jsffi_test.mdk); a c-only extern reaches them only in a child
# started without a profile, where it is a gap naming the missing `js` binding.
#
# No real C linkage needed: `build --target wasm` must refuse BEFORE attempting to
# emit/validate/link anything, so the wall fixtures never reach Node.  The
# file-grant cases run under Node (test/wasm/run.js) and as native builds.
# The wasm emitter is the wasm_emit_modules_main oracle binary (`sh
# test/wasm/build_wasm_oracle.sh --modules-only`).
#
# The file-grant cases at the bottom are no wall: the wasm host confines a file
# operation as the native runtime does, so each builds, and a case whose
# operation leaves its grant or a declared bound is refused when it runs, with
# the native build's output.  The runtime-extern cases are a wall: a runtime
# extern the catalog gives wasm no lowering for.
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

fail=0

# Expect `build --target wasm` to exit nonzero with a message containing $3.
# An optional $4 is the source of a module `gaplib`, written beside the program.
check_refused() {
  name="$1"; src="$2"; want="$3"; lib="${4:-}"
  f="$WORK/$name.mdk"
  printf '%s\n' "$src" > "$f"
  if [ -n "$lib" ]; then printf "%s\n" "$lib" > "$WORK/gaplib.mdk"; fi
  out="$(MEDAKA_WASM_EMITTER="$EMITBIN" "$MEDAKA" build --target wasm "$f" -o "$WORK/$name.out" 2>&1)"
  st=$?
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

# ── The runtime-extern wall (compiler/backend/core_validate.mdk) ────────────
# A program reaching a runtime extern whose catalog row gives wasm no lowering
# is refused before any WAT is emitted, naming the extern, the gap kind and
# the row's reason.  The two cases at the end of this file show what it does
# not refuse.  An extern behind a label the profile does not grant (`Net`
# here) never gets that far: the target check refuses the program first.
RUNTIME_EXPECT="wasm: runtime extern '%s' is not available on the wasm backend (%s: "

check_refused "net_extern_refused" \
'import net.{resolve}

main = match resolve "localhost"
  Ok _ => println "resolved"
  Err e => println e' \
  "\`main\` performs <Net \"localhost\">, and the target \`wasmgc/node\` does not grant Net"

check_refused "wasm_gap_extern_refused" \
'main = println (allocBytes ())' \
  "$(printf "$RUNTIME_EXPECT" allocBytes WASM-GAP)"

# The same refusal under the profile `build` checked: `wasmgc/node` grants
# `FileWrite`, so the program passed the check and the lowering is owed.
check_refused "wasm_gap_extern_owed" \
'main = println (allocBytes ())' \
  "\`wasmgc/node\` grants its labels, so this is a lowering still owed (#3666)"

# A gap extern reached through an imported module is refused the same way: no stdlib
# module reaches one now, so the module is a local one.
check_refused "module_extern_reached_refused" \
'import gaplib.{reach}

main = println (reach ())' \
  "$(printf "$RUNTIME_EXPECT" allocBytes WASM-GAP)" \
'export reach : Unit -> <IO> Float
reach () = allocBytes ()'
rm -f "$WORK/gaplib.mdk"

# ── File grants (EFFECTS-SEMANTICS §7) ──────────────────────────────────────
# Every grant builds: the host confines each file operation against the grant
# its call was given and every enclosing declared bound of its mode
# (playground/medaka_host.mjs).  `check_grant <name> <src> run-refused` also
# runs the wasm build and a native build of the same program, each in a fresh
# copy of one tree (a granted `cfg/`, `data.txt` beside it, and a symlink
# `cfg/link` to `outdir/`), and requires the same stdout and exit status, with
# the native run refusing a path.  The expected output is native's.
grant_tree() {
  rm -rf "$1"
  mkdir -p "$1/cfg" "$1/outdir"
  printf 'granted' > "$1/cfg/a.txt"
  printf 'data' > "$1/data.txt"
  printf 'outside' > "$1/outdir/a.txt"
  ln -s ../outdir "$1/cfg/link"
}
check_grant() {
  name="$1"; src="$2"; want="$3"
  f="$WORK/$name.mdk"
  printf '%s\n' "$src" > "$f"
  out="$(MEDAKA_WASM_EMITTER="$EMITBIN" "$MEDAKA" build --target wasm "$f" -o "$WORK/$name.wasm" 2>&1)"
  st=$?
  if [ "$st" -ne 0 ]; then
    echo "FAIL $name: expected a build, got exit $st:"
    echo "$out" | sed 's/^/  /'
    fail=1
    return
  fi
  if [ -z "$want" ]; then echo "ok   $name"; return; fi
  if ! "$MEDAKA" build "$f" -o "$WORK/$name.bin" >"$WORK/$name.nlog" 2>&1; then
    echo "FAIL $name: the native build failed:"
    sed 's/^/  /' "$WORK/$name.nlog"
    fail=1
    return
  fi
  grant_tree "$WORK/tree"
  n_out="$(cd "$WORK/tree" && "$WORK/$name.bin" 2>"$WORK/$name.nerr")"
  n_st=$?
  grant_tree "$WORK/tree"
  w_out="$(cd "$WORK/tree" && node "$ROOT/test/wasm/run.js" "$WORK/$name.wasm" 2>"$WORK/$name.werr")"
  w_st=$?
  if ! printf '%s\n' "$n_out" | cat - "$WORK/$name.nerr" | grep -qF 'is outside the granted authority'; then
    echo "FAIL $name: the native run refused no path:"
    printf '%s\n' "$n_out" | sed 's/^/  /'
    fail=1
  elif [ "$n_out" != "$w_out" ] || [ "$n_st" -ne "$w_st" ]; then
    echo "FAIL $name: native exit $n_st printed [$n_out], wasm exit $w_st printed [$w_out]"
    sed 's/^/  wasm stderr: /' "$WORK/$name.werr"
    fail=1
  else
    echo "ok   $name"
  fi
}

check_grant "file_grant_pattern_refused" \
'readCfg : String -> <FileRead "cfg/*"> Result String String
readCfg name = readFile ("cfg/" ++ name)

main = println (readCfg "../secret.txt")' \
  run-refused

check_grant "file_grant_wrapper_narrow_caller_refused" \
'import io.{readLines}

cfgLines : String -> <FileRead "cfg/*"> Result String (List String)
cfgLines name = readLines ("cfg/" ++ name)

main = println (cfgLines "../data.txt")' \
  run-refused

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
  run-refused

check_grant "file_declared_bound_alias_refused" \
'helper _ = readFile "cfg/link/a.txt"

readCfg : Unit -> <FileRead "cfg/*"> Result String String
readCfg = helper

main = println (readCfg ())' \
  run-refused

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

# A callback can share a spelling with a live pure global: the declared bound
# confines the file operation of the callback the program passes.
check_grant "file_bound_callback_shadow_refused" \
'cb : Unit -> <IO> Result String String
cb _ = Ok "pure"

readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg cb = cb ()

main =
  let _ = cb ()
  println (readCfg (_ => readFile "data.txt"))' \
  run-refused

check_grant "file_bound_callback_helper_refused" \
'cb : Unit -> <IO> Result String String
cb _ = Ok "pure"

invoke cb = cb ()
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = invoke given

main =
  let _ = cb ()
  println (readCfg (_ => readFile "data.txt"))' \
  run-refused

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
  run-refused

check_grant "file_bound_callback_lambda_refused" \
'cb : Unit -> <IO> Result String String
cb _ = Ok "pure"

invoke given = (cb => cb ()) given
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = invoke given

main =
  let _ = cb ()
  println (readCfg (_ => readFile "data.txt"))' \
  run-refused

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
  run-refused

check_grant "file_bound_callback_returned_refused" \
'cb : Unit -> <IO> Result String String
cb _ = Ok "pure"

identity cb = cb
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = (identity given) ()

main =
  let _ = cb ()
  println (readCfg (_ => readFile "data.txt"))' \
  run-refused

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
  run-refused

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
  run-refused

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
  run-refused

check_grant "file_bound_signed_returned_refused" \
'returnCb : (Unit -> <IO> Result String String) -> Unit -> <IO> Result String String
returnCb cb = cb
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = (returnCb given) ()

main = println (readCfg (_ => readFile "data.txt"))' \
  run-refused

check_grant "file_bound_relay_returned_refused" \
'returnCb cb = cb
relay cb = returnCb cb
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = (relay given) ()

main = println (readCfg (_ => readFile "data.txt"))' \
  run-refused

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
  run-refused

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
said : Result String String -> String
said (Ok _) = "Ok"
said (Err e) = "Err \{e}"
readCfg : Unit -> <FileRead "cfg/*", FileWrite "out", Stdout> Result String Unit
readCfg _ = callWrite (let _ = println (said (readFile "cfg/link")) in _ => writeFileBytes "out" (arrayFromList [120]))
main = println (readCfg ())' \
  run-refused

check_grant "file_bound_pure_local_function_built" \
'readCfg : Unit -> <FileRead "cfg/*"> Int
readCfg _ =
  let count xs = length xs
  count [1, 2]
main = println (readCfg ())' \
  ""

check_grant "file_bound_local_capture_refused" \
'readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given =
  let call _ = given ()
  let given = _ => Ok "pure"
  call ()
main = println (readCfg (_ => readFile "data.txt"))' \
  run-refused

check_grant "file_bound_local_returned_callback_refused" \
'readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given =
  let identity cb = cb
  identity given ()
main = println (readCfg (_ => readFile "data.txt"))' \
  run-refused

check_grant "file_bound_method_returned_callback_refused" \
'interface Return s where
  returnCb : s -> (Unit -> <IO> Result String String) -> Unit -> <IO> Result String String
data Box = Box
impl Return Box where
  returnCb _ cb = cb
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = returnCb Box given ()
main = println (readCfg (_ => readFile "data.txt"))' \
  run-refused

check_grant "file_bound_standalone_shadow_returned_callback_refused" \
'data Box = Box
sub : Box -> (Unit -> <IO> Result String String) -> Unit -> <IO> Result String String
sub _ cb = cb
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg given = sub Box given ()
main = println (readCfg (_ => readFile "data.txt"))' \
  run-refused

# The runtime-extern wall refuses only a reference the program reaches: an
# imported module whose externs go unreached builds, and so does a program
# binding that merely shares an extern's name.
check_grant "fs_import_unreached_built" \
'import fs.{isFile}

main = println "offline"' \
  ""

check_grant "toplevel_named_like_net_extern_built" \
'netSend : Int -> Int
netSend x = x + 1

main = println (netSend 1)' \
  ""

if [ "$fail" -eq 0 ]; then
  echo "40 ok, 0 failing"
  exit 0
else
  echo "diff_wasm_ffi_wall: FAILURES ABOVE"
  exit 1
fi
