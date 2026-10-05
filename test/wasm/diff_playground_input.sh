#!/bin/sh
# Product parity: Float record-field and constructor-pattern paths compile through both Wasm products.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
MODULES="$ROOT/test/bin/wasm_emit_modules_main"; PLAYGROUND="$ROOT/playground/dist/playground.wasm"
WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cat > "$WORK/input.mdk" <<'EOF'
data R = R { u : Float }

negR : R -> Float
negR r = -r.u

main = println (negR (R { u = 1.5 }) < 0.0)
EOF
printf '%s\n' True > "$WORK/expected"
fail=0; checks=0
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
check_wat() {
  label="$1"; wat="$2"; wasm="$WORK/$label.wasm"; checks=$((checks + 1))
  [ -s "$wat" ] || { bad "$label emitted empty WAT"; return; }
  wasm-tools parse "$wat" -o "$wasm" >"$WORK/$label.parse.out" 2>"$WORK/$label.parse.err" || { bad "$label WAT did not parse"; return; }
  wasm-tools validate --features=all "$wasm" >"$WORK/$label.validate.out" 2>"$WORK/$label.validate.err" || { bad "$label Wasm did not validate"; return; }
  node "$ROOT/test/wasm/run.js" "$wasm" >"$WORK/$label.out" 2>"$WORK/$label.err" || { bad "$label Wasm run exited nonzero"; return; }
  [ ! -s "$WORK/$label.err" ] || { bad "$label Wasm wrote stderr"; return; }
  cmp -s "$WORK/expected" "$WORK/$label.out" || bad "$label stdout differed"
}
command -v wasm-tools >/dev/null 2>&1 || bad "wasm-tools unavailable"
command -v node >/dev/null 2>&1 || bad "node unavailable"
bash "$ROOT/playground/build_playground_wasm.sh" >"$WORK/build.out" 2>"$WORK/build.err" || bad "fresh playground build failed"
if [ -x "$MODULES" ] && "$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" >"$WORK/modules.wat" 2>"$WORK/modules.emit.err"; then check_wat modules "$WORK/modules.wat"; else bad "modules emitter failed"; cat "$WORK/modules.emit.err"; fi
if [ -f "$PLAYGROUND" ] && node "$ROOT/playground/dev_compile_node.mjs" "$PLAYGROUND" "$RUNTIME" "$CORE" "$WORK/input.mdk" >"$WORK/playground.wat" 2>"$WORK/playground.emit.err"; then check_wat playground "$WORK/playground.wat"; else bad "playground compiler failed"; cat "$WORK/playground.emit.err"; fi
cat > "$WORK/input.mdk" <<'EOF'
data Box = Box Float

negBox : Box -> Float
negBox b = match b
  Box f => -f

main = println (negBox (Box 2.5) < 0.0)
EOF
if [ -x "$MODULES" ] && "$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" >"$WORK/modules-p2.wat" 2>"$WORK/modules-p2.emit.err"; then check_wat modules-p2 "$WORK/modules-p2.wat"; else bad "P2 modules emitter failed"; cat "$WORK/modules-p2.emit.err"; fi
if [ -f "$PLAYGROUND" ] && node "$ROOT/playground/dev_compile_node.mjs" "$PLAYGROUND" "$RUNTIME" "$CORE" "$WORK/input.mdk" >"$WORK/playground-p2.wat" 2>"$WORK/playground-p2.emit.err"; then check_wat playground-p2 "$WORK/playground-p2.wat"; else bad "P2 playground compiler failed"; cat "$WORK/playground-p2.emit.err"; fi
cat > "$WORK/input.mdk" <<'EOF'
myId : a -> a
myId x = x

main = myId 6.0
EOF
printf '%s\n' 6.0 > "$WORK/expected"
if [ -x "$MODULES" ] && "$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" >"$WORK/modules-main-float.wat" 2>"$WORK/modules-main-float.emit.err"; then check_wat modules-main-float "$WORK/modules-main-float.wat"; else bad "Float-main modules emitter failed"; cat "$WORK/modules-main-float.emit.err"; fi
if [ -f "$PLAYGROUND" ] && node "$ROOT/playground/dev_compile_node.mjs" "$PLAYGROUND" "$RUNTIME" "$CORE" "$WORK/input.mdk" >"$WORK/playground-main-float.wat" 2>"$WORK/playground-main-float.emit.err"; then check_wat playground-main-float "$WORK/playground-main-float.wat"; else bad "Float-main playground compiler failed"; cat "$WORK/playground-main-float.emit.err"; fi
cp "$ROOT/test/engine_fixtures/record_field_order_unscanned_ctor.mdk" "$WORK/input.mdk"
cp "$ROOT/test/engine_value_pins/engine/record_field_order_unscanned_ctor.pin" "$WORK/expected"
if [ -x "$MODULES" ] && "$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" >"$WORK/modules-record-order.wat" 2>"$WORK/modules-record-order.emit.err"; then check_wat modules-record-order "$WORK/modules-record-order.wat"; else bad "Record-order modules emitter failed"; cat "$WORK/modules-record-order.emit.err"; fi
if [ -f "$PLAYGROUND" ] && node "$ROOT/playground/dev_compile_node.mjs" "$PLAYGROUND" "$RUNTIME" "$CORE" "$WORK/input.mdk" >"$WORK/playground-record-order.wat" 2>"$WORK/playground-record-order.emit.err"; then check_wat playground-record-order "$WORK/playground-record-order.wat"; else bad "Record-order playground compiler failed"; cat "$WORK/playground-record-order.emit.err"; fi
cat > "$WORK/input.mdk" <<'EOF'
main = 42
EOF
printf '%s\n' 42 > "$WORK/expected"
if [ -x "$MODULES" ] && "$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" >"$WORK/modules-int-control.wat" 2>"$WORK/modules-int-control.emit.err"; then check_wat modules-int-control "$WORK/modules-int-control.wat"; else bad "Int-control modules emitter failed"; cat "$WORK/modules-int-control.emit.err"; fi
if [ -f "$PLAYGROUND" ] && node "$ROOT/playground/dev_compile_node.mjs" "$PLAYGROUND" "$RUNTIME" "$CORE" "$WORK/input.mdk" >"$WORK/playground-int-control.wat" 2>"$WORK/playground-int-control.emit.err"; then check_wat playground-int-control "$WORK/playground-int-control.wat"; else bad "Int-control playground compiler failed"; cat "$WORK/playground-int-control.emit.err"; fi
# A Unit main is the one program shape with NO output: nothing in the user's code
# forces the $str rep, so the string types are gated off while the prelude's
# `impl Monoid String where empty = ""` is still emitted naming $u8arr.  The
# module then fails to ASSEMBLE, which the playground reports as a compiler
# failure.  Expected stdout is empty and the wasm must parse + validate.
cat > "$WORK/input.mdk" <<'EOF'
main : <IO> Unit
main = ()
EOF
: > "$WORK/expected"
if [ -x "$MODULES" ] && "$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" >"$WORK/modules-unit-main.wat" 2>"$WORK/modules-unit-main.emit.err"; then check_wat modules-unit-main "$WORK/modules-unit-main.wat"; else bad "Unit-main modules emitter failed"; cat "$WORK/modules-unit-main.emit.err"; fi
if [ -f "$PLAYGROUND" ] && node "$ROOT/playground/dev_compile_node.mjs" "$PLAYGROUND" "$RUNTIME" "$CORE" "$WORK/input.mdk" >"$WORK/playground-unit-main.wat" 2>"$WORK/playground-unit-main.emit.err"; then check_wat playground-unit-main "$WORK/playground-unit-main.wat"; else bad "Unit-main playground compiler failed"; cat "$WORK/playground-unit-main.emit.err"; fi
# #2424: a Unit-returning call BELOW main's top-level head (here under an else-less
# `if`) was routed to the Int printer, so `b` was followed by a spurious `0`.
cat > "$WORK/input.mdk" <<'EOF'
main = if True then println "b"
EOF
printf '%s\n' b > "$WORK/expected"
if [ -x "$MODULES" ] && "$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" >"$WORK/modules-elseless-if.wat" 2>"$WORK/modules-elseless-if.emit.err"; then check_wat modules-elseless-if "$WORK/modules-elseless-if.wat"; else bad "Else-less-if modules emitter failed"; cat "$WORK/modules-elseless-if.emit.err"; fi
if [ -f "$PLAYGROUND" ] && node "$ROOT/playground/dev_compile_node.mjs" "$PLAYGROUND" "$RUNTIME" "$CORE" "$WORK/input.mdk" >"$WORK/playground-elseless-if.wat" 2>"$WORK/playground-elseless-if.emit.err"; then check_wat playground-elseless-if "$WORK/playground-elseless-if.wat"; else bad "Else-less-if playground compiler failed"; cat "$WORK/playground-elseless-if.emit.err"; fi
# #2424's second face: a main DECLARED Unit whose first match arm is `panic`.
# The structural kind walk reads a match's first arm, so this printed a trailing
# `0` even after the else-less-if fix; the declared type must win.
cat > "$WORK/input.mdk" <<'EOF'
main : <IO> Unit
main = match [1]
  [] => panic "empty"
  x :: _ => println (debug x)
EOF
printf '%s\n' 1 > "$WORK/expected"
if [ -x "$MODULES" ] && "$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" >"$WORK/modules-declared-unit-panic.wat" 2>"$WORK/modules-declared-unit-panic.emit.err"; then check_wat modules-declared-unit-panic "$WORK/modules-declared-unit-panic.wat"; else bad "Declared-Unit-panic modules emitter failed"; cat "$WORK/modules-declared-unit-panic.emit.err"; fi
if [ -f "$PLAYGROUND" ] && node "$ROOT/playground/dev_compile_node.mjs" "$PLAYGROUND" "$RUNTIME" "$CORE" "$WORK/input.mdk" >"$WORK/playground-declared-unit-panic.wat" 2>"$WORK/playground-declared-unit-panic.emit.err"; then check_wat playground-declared-unit-panic "$WORK/playground-declared-unit-panic.wat"; else bad "Declared-Unit-panic playground compiler failed"; cat "$WORK/playground-declared-unit-panic.emit.err"; fi
# Product-input parity, FFI extern table: the modules entry passes the validated
# FFI extern table into WasmEmitInput; the playground entry passed `[]` until
# 2026-09-03, so the emitter fell through to its generic unbound-variable gap
# instead of the named native-only refusal (#2129's message, which
# test/wasm/diff_wasm_ffi_wall.sh pins on the modules path) — and compile.mjs
# dropped the guest's stderr on the trap path, so the browser showed a bare
# "compiler trap: unreachable" either way.  Both products must refuse, and refuse
# by name; the second grep is the fall-through control.
cat > "$WORK/input.mdk" <<'EOF2'
extern cNegate : Int -> <FFI "x"> Int

main : <FFI> Int
main = cNegate 5
EOF2
FFI_WANT="FFI extern 'cNegate' is native-only"
check_ffi_wall() {
  label="$1"; outf="$2"; errf="$3"; checks=$((checks + 1))
  if grep -qF "$FFI_WANT" "$outf" "$errf"; then :; else bad "$label did not refuse the FFI extern by name"; cat "$outf" "$errf"; fi
  if grep -qi "unbound variable" "$outf" "$errf"; then bad "$label fell through to the generic unbound-variable panic"; fi
}
if [ -x "$MODULES" ]; then
  "$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" >"$WORK/modules-ffi.out" 2>"$WORK/modules-ffi.err" && bad "modules emitter accepted an FFI extern"
  check_ffi_wall modules-ffi "$WORK/modules-ffi.out" "$WORK/modules-ffi.err"
else bad "modules emitter missing for the FFI-wall case"; fi
if [ -f "$PLAYGROUND" ]; then
  node "$ROOT/playground/dev_compile_node.mjs" "$PLAYGROUND" "$RUNTIME" "$CORE" "$WORK/input.mdk" >"$WORK/playground-ffi.out" 2>"$WORK/playground-ffi.err" && bad "playground compiler accepted an FFI extern"
  check_ffi_wall playground-ffi "$WORK/playground-ffi.out" "$WORK/playground-ffi.err"
else bad "playground compiler missing for the FFI-wall case"; fi
# Declared bounds must be checked before either product emits WAT. The formal
# callback shadows a live pure global, so name-only reachability is insufficient.
cat > "$WORK/input.mdk" <<'EOF2'
cb _ = "pure"
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg cb = cb ()
main =
  println (cb ())
  println (readCfg (_ => readFile "data.txt"))
EOF2
check_file_wall() {
  label="$1"; outf="$2"; errf="$3"; checks=$((checks + 1))
  grep -qF 'declared FileRead bound' "$outf" "$errf" || bad "$label lost the named file-grant refusal"
  grep -qF 'cfg/*' "$outf" "$errf" || bad "$label lost the declared bound"
  if grep -qF '(module' "$outf"; then bad "$label emitted partial WAT"; fi
}
"$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" >"$WORK/modules-file.out" 2>"$WORK/modules-file.err" && bad "modules accepted a narrow callback bound"
check_file_wall modules-file "$WORK/modules-file.out" "$WORK/modules-file.err"
node "$ROOT/playground/dev_compile_node.mjs" "$PLAYGROUND" "$RUNTIME" "$CORE" "$WORK/input.mdk" >"$WORK/playground-file.out" 2>"$WORK/playground-file.err" && bad "playground accepted a narrow callback bound"
check_file_wall playground-file "$WORK/playground-file.out" "$WORK/playground-file.err"
node -e 'const fs=require("node:fs"); const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); const hit=d.files.flatMap(f=>f.diagnostics).find(x=>x.code==="T-WASM-FILE-GRANT"); if(!hit || !hit.range || hit.range.start.line!==2) process.exit(1)' "$WORK/playground-file.out" || bad "playground file refusal lost its code or source range"
# A pure function using a point-free prelude helper needs no host confinement.
cat > "$WORK/input.mdk" <<'EOF2'
readCfg : Unit -> <FileRead "cfg/*"> Int
readCfg _ = length [1, 2]
main = println (readCfg ())
EOF2
printf '%s\n' 2 > "$WORK/expected"
if "$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" >"$WORK/modules-pure-bound.wat" 2>"$WORK/modules-pure-bound.err"; then check_wat modules-pure-bound "$WORK/modules-pure-bound.wat"; else bad "modules refused a pure bound"; fi
if node "$ROOT/playground/dev_compile_node.mjs" "$PLAYGROUND" "$RUNTIME" "$CORE" "$WORK/input.mdk" >"$WORK/playground-pure-bound.wat" 2>"$WORK/playground-pure-bound.err"; then check_wat playground-pure-bound "$WORK/playground-pure-bound.wat"; else bad "playground refused a pure bound"; fi
# Ordinary programs importing stdlib modules (#3688). The wasm-compiled compiler
# must compile them the way the native one does: the same source compiled natively
# is the oracle for every expected file below. The playground arm registers the
# same extra modules the live page ships, read from EXTRA_MODULES in main.js.
cat > "$WORK/pg_compile_extra.mjs" <<'EOF2'
import fs from 'node:fs';
import path from 'node:path';
const [root, userPath] = process.argv.slice(2);
const mainJs = fs.readFileSync(path.join(root, 'playground/main.js'), 'utf8');
const m = mainJs.match(/const EXTRA_MODULES = \[([\s\S]*?)\];/);
if (!m) { console.error('EXTRA_MODULES not found in playground/main.js'); process.exit(2); }
const extra = {};
for (const x of m[1].matchAll(/'([a-z0-9_]+)'/g)) extra[x[1]] = fs.readFileSync(path.join(root, 'stdlib', x[1] + '.mdk'), 'utf8');
const { loadCompiler, compile } = await import(path.join(root, 'playground/compile.mjs'));
const wasm = await loadCompiler(path.join(root, 'playground/dist/playground.wasm'));
const stdlib = {
  runtime: fs.readFileSync(path.join(root, 'stdlib/runtime.mdk'), 'utf8'),
  core: fs.readFileSync(path.join(root, 'stdlib/core.mdk'), 'utf8'),
  extra,
};
const r = await compile(fs.readFileSync(userPath, 'utf8'), { wasm, stdlib });
if (r.ok) { process.stdout.write(r.wat); process.exit(0); }
process.stdout.write(JSON.stringify(r.diagnostics, null, 2) + '\n');
process.exit(1);
EOF2
check_imports_program() {
  prog="$1"
  if "$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" "$ROOT/stdlib" >"$WORK/modules-$prog.wat" 2>"$WORK/modules-$prog.emit.err"; then check_wat "modules-$prog" "$WORK/modules-$prog.wat"; else bad "$prog modules emitter failed"; cat "$WORK/modules-$prog.emit.err"; fi
  if node "$WORK/pg_compile_extra.mjs" "$ROOT" "$WORK/input.mdk" >"$WORK/playground-$prog.wat" 2>"$WORK/playground-$prog.emit.err"; then check_wat "playground-$prog" "$WORK/playground-$prog.wat"; else bad "$prog playground compiler failed"; head -c 600 "$WORK/playground-$prog.wat" "$WORK/playground-$prog.emit.err"; fi
}
cat > "$WORK/input.mdk" <<'EOF2'
import string.{toInt}

safeDiv : Int -> Int -> Option Int
safeDiv _ 0 = None
safeDiv a b = Some (a / b)

parseAndHalve : String -> Result String Int
parseAndHalve s = match toInt s
  Some n => Ok (n / 2)
  None => Err "not a number: \{s}"

main =
  println (safeDiv 10 2)
  println (safeDiv 10 0)
  println (parseAndHalve "42")
  println (parseAndHalve "forty")
  println (optionOr 0 (safeDiv 1 0))
EOF2
printf '%s\n' 'Some 5' 'None' 'Ok 21' 'Err (not a number: forty)' '0' > "$WORK/expected"
check_imports_program option-result
cat > "$WORK/input.mdk" <<'EOF2'
import json.{parse, stringify, get, asInt, asString}

main =
  match parse "{\"name\": \"medaka\", \"stars\": 3, \"tags\": [\"fp\", \"effects\"]}"
    Err e => println "parse error: \{e}"
    Ok j =>
      println (stringify j)
      println (get "name" j |> flatMap asString)
      println (get "stars" j |> flatMap asInt)
EOF2
printf '%s\n' '{"name":"medaka","stars":3,"tags":["fp","effects"]}' 'Some medaka' 'Some 3' > "$WORK/expected"
check_imports_program json
cat > "$WORK/input.mdk" <<'EOF2'
import array as A
import vector as V

main =
  let arr = A.fromList [3, 1, 2]
  arr[0] := 99
  println arr
  println arr[1]
  A.sortInPlace arr
  println arr
  let v = V.new ()
  V.push "a" v
  V.push "b" v
  println (length v)
  println (V.pop v)
EOF2
printf '%s\n' '[|99, 1, 2|]' '1' '[|1, 2, 99|]' '2' 'Some b' > "$WORK/expected"
check_imports_program arrays-vectors
cat > "$WORK/input.mdk" <<'EOF2'
import string.{toInt, toFloat}

main =
  println (toInt "42")
  println (toInt "-17")
  println (toInt "abc")
  println (toInt " 42 ")
  println (toFloat "3.5")
EOF2
printf '%s\n' 'Some 42' 'Some (-17)' 'None' 'None' 'Some 3.5' > "$WORK/expected"
check_imports_program string-to-int
printf '%d checks, %d failing\n' "$checks" "$fail"
[ "$checks" -gt 0 ] && [ "$fail" -eq 0 ]
