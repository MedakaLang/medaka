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
# instead of the named native-only refusal (#2129's message, which the
# modules emitter gives when it is started without a profile) — and compile.mjs
# dropped the guest's stderr on the trap path, so the browser showed a bare
# "compiler trap: unreachable" either way.  Both products must refuse, and refuse
# by name; the second grep is the fall-through control.  The playground compiles
# for wasmgc/browser-worker, so its refusal is the target check's, which names
# the label and the extern the entry reaches it through, before the emitter runs.
cat > "$WORK/input.mdk" <<'EOF2'
extern cNegate : Int -> <FFI "c/x"> Int

main : <FFI "c*"> Int
main = cNegate 5
EOF2
check_ffi_wall() {
  label="$1"; outf="$2"; errf="$3"; want="$4"; checks=$((checks + 1))
  if grep -qF "$want" "$outf" "$errf"; then :; else bad "$label did not refuse the FFI extern by name"; cat "$outf" "$errf"; fi
  if grep -qi "unbound variable" "$outf" "$errf"; then bad "$label fell through to the generic unbound-variable panic"; fi
}
if [ -x "$MODULES" ]; then
  "$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" >"$WORK/modules-ffi.out" 2>"$WORK/modules-ffi.err" && bad "modules emitter accepted an FFI extern"
  check_ffi_wall modules-ffi "$WORK/modules-ffi.out" "$WORK/modules-ffi.err" "FFI extern 'cNegate' is native-only"
else bad "modules emitter missing for the FFI-wall case"; fi
if [ -f "$PLAYGROUND" ]; then
  node "$ROOT/playground/dev_compile_node.mjs" "$PLAYGROUND" "$RUNTIME" "$CORE" "$WORK/input.mdk" >"$WORK/playground-ffi.out" 2>"$WORK/playground-ffi.err" && bad "playground compiler accepted an FFI extern"
  check_ffi_wall playground-ffi "$WORK/playground-ffi.out" "$WORK/playground-ffi.err" 'via `main → cNegate`, and the target `wasmgc/browser-worker` does not grant FFI'
else bad "playground compiler missing for the FFI-wall case"; fi
# A declared bound builds in both products and is enforced when the program
# runs: the host refuses the callback's read outside `cfg/*`, with the native
# runtime's text.  The formal callback shadows a live pure global.
cat > "$WORK/input.mdk" <<'EOF2'
cb _ = "pure"
readCfg : (Unit -> <IO> Result String String) -> <FileRead "cfg/*", IO> Result String String
readCfg cb = cb ()
main =
  println (cb ())
  println (readCfg (_ => readFile "data.txt"))
EOF2
printf '%s\n' pure 'Err (data.txt is outside the granted authority ["cfg/*"])' > "$WORK/expected"
if "$MODULES" "$RUNTIME" "$CORE" "$WORK/input.mdk" "$WORK" >"$WORK/modules-file.wat" 2>"$WORK/modules-file.err"; then check_wat modules-file "$WORK/modules-file.wat"; else bad "modules refused a declared bound"; cat "$WORK/modules-file.err"; fi
if node "$ROOT/playground/dev_compile_node.mjs" "$PLAYGROUND" "$RUNTIME" "$CORE" "$WORK/input.mdk" >"$WORK/playground-file.wat" 2>"$WORK/playground-file.err"; then check_wat playground-file "$WORK/playground-file.wat"; else bad "playground refused a declared bound"; cat "$WORK/playground-file.err"; fi
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
# same extra modules the live page ships, read from the list main.js fetches
# (playground/dist/stdlib_modules.json, generated by build_playground_wasm.sh).
cat > "$WORK/pg_compile_extra.mjs" <<'EOF2'
import fs from 'node:fs';
import path from 'node:path';
const [root, userPath] = process.argv.slice(2);
const ids = JSON.parse(fs.readFileSync(path.join(root, 'playground/dist/stdlib_modules.json'), 'utf8'));
if (!ids.length) { console.error('playground/dist/stdlib_modules.json lists no module'); process.exit(2); }
const extra = {};
for (const id of ids) extra[id] = fs.readFileSync(path.join(root, 'stdlib', id.replace(/\./g, '/') + '.mdk'), 'utf8');
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
# The playground compiles for wasmgc/browser-worker: a program performing a label
# that profile withholds gets, in compile AND analyze mode, the diagnostics native
# `medaka check --json --target wasmgc/browser-worker` gives (#3669). Each side is
# reduced to `code file line:col message` lines; the file is the basename (the
# playground's entry is ./main.mdk, so each probe is a main.mdk of its own).
cat > "$WORK/diag_lines.mjs" <<'EOF2'
import fs from 'node:fs';
import path from 'node:path';
const [root, mode, userPath, ...siblings] = process.argv.slice(2);
const lines = (diag) => diag.files.flatMap((f) => f.diagnostics.map((d) =>
  [d.code, path.basename(f.file), d.range.start.line + ':' + d.range.start.character, d.message].join(' ')));
if (mode === 'native') {
  process.stdout.write(lines(JSON.parse(fs.readFileSync(userPath, 'utf8'))).join('\n') + '\n');
  process.exit(0);
}
const dist = path.join(root, 'playground/dist');
const ids = JSON.parse(fs.readFileSync(path.join(dist, 'stdlib_modules.json'), 'utf8'));
const extra = {};
for (const id of ids) extra[id] = fs.readFileSync(path.join(dist, id + '.mdk'), 'utf8');
for (const s of siblings) extra[path.basename(s, '.mdk')] = fs.readFileSync(s, 'utf8');
const pg = await import(path.join(root, 'playground/compile.mjs'));
const wasm = await pg.loadCompiler(path.join(dist, 'playground.wasm'));
const stdlib = {
  runtime: fs.readFileSync(path.join(dist, 'runtime.mdk'), 'utf8'),
  core: fs.readFileSync(path.join(dist, 'core.mdk'), 'utf8'),
  extra,
};
const r = await pg[mode](fs.readFileSync(userPath, 'utf8'), { wasm, stdlib });
process.stdout.write(lines(r.diagnostics || { files: [] }).join('\n') + '\n');
EOF2
check_target_refusal() {
  name="$1"; want="$2"; dir="$WORK/target-$name"; shift 2
  checks=$((checks + 1))
  "$ROOT/medaka" check --json --target wasmgc/browser-worker "$dir/main.mdk" >"$dir/native.json" 2>"$dir/native.err"
  node "$WORK/diag_lines.mjs" "$ROOT" native "$dir/native.json" >"$dir/native.lines" 2>>"$dir/native.err" || { bad "$name native check output did not parse"; return; }
  grep -qF "$want" "$dir/native.lines" || { bad "$name native check did not report: $want"; cat "$dir/native.lines"; return; }
  for mode in compile analyze; do
    node "$WORK/diag_lines.mjs" "$ROOT" "$mode" "$dir/main.mdk" "$@" >"$dir/$mode.lines" 2>"$dir/$mode.err" || { bad "$name playground $mode failed"; cat "$dir/$mode.err"; continue; }
    cmp -s "$dir/native.lines" "$dir/$mode.lines" || { bad "$name playground $mode differs from native check --target"; diff "$dir/native.lines" "$dir/$mode.lines"; }
  done
}
mkdir -p "$WORK/target-io-exec" "$WORK/target-exec" "$WORK/target-net-via"
cat > "$WORK/target-io-exec/main.mdk" <<'EOF2'
main : <IO> Unit
main = match runCommand "ls" []
  Ok _ => println "ran"
  Err e => println e
EOF2
check_target_refusal io-exec 'T-EFFECT-LEAK main.mdk 1:29 performs <Exec "ls"> where only <IO> is allowed'
cat > "$WORK/target-exec/main.mdk" <<'EOF2'
main : <Exec, Stdout> Unit
main = match runCommand "ls" []
  Ok _ => println "ran"
  Err e => println e
EOF2
check_target_refusal exec 'T-TARGET-CAPABILITY main.mdk 0:0 `main` performs <Exec>, and the target `wasmgc/browser-worker` does not grant Exec'
cat > "$WORK/target-net-via/netmod.mdk" <<'EOF2'
export
lookup : String -> <Net> Unit
lookup h = match netResolve h
  Ok _ => ()
  Err _ => ()
EOF2
cat > "$WORK/target-net-via/main.mdk" <<'EOF2'
import netmod.{lookup}

fetchIt : String -> <Net> Unit
fetchIt h = lookup h

main =
  let _ = fetchIt "example.com"
  println "done"
EOF2
check_target_refusal net-via 'T-TARGET-CAPABILITY main.mdk 5:0 `main` performs <Net> via `main → fetchIt`, and the target `wasmgc/browser-worker` does not grant Net' "$WORK/target-net-via/netmod.mdk"
# The compiler wasm's first run in a browser is baseline-tier (Liftoff), whose frames are
# several times larger than optimized ones, and a browser worker gives ~1 MB of stack. A
# program that imports `async` once overflowed it (types.typecheck.sealMethodReturnGoals
# recursed once per goal). --liftoff-only pins that tier so the retry in compile.mjs cannot
# tier up and hide a regression; 400 KB is 4x what the compiler needs today and half what
# it needed before the fix.
check_liftoff_stack() {
  label="$1"; prog="$2"; want="$3"; need="$4"; checks=$((checks + 1))
  node --liftoff-only --stack-size=400 "$WORK/pg_compile_extra.mjs" "$ROOT" "$prog" >"$WORK/stack-$label.out" 2>"$WORK/stack-$label.err"
  rc=$?
  if grep -qi 'call stack' "$WORK/stack-$label.out" "$WORK/stack-$label.err"; then bad "$label overflowed the 400 KB baseline-tier stack"; return; fi
  [ "$rc" -eq "$want" ] || { bad "$label exited $rc, expected $want"; head -c 400 "$WORK/stack-$label.out"; return; }
  [ -z "$need" ] || grep -q "$need" "$WORK/stack-$label.out" || bad "$label lost its diagnostic $need"
}
check_liftoff_stack async-overlap "$ROOT/test/async_fixtures/overlap_sleeps.mdk" 0 ""
check_liftoff_stack async-defer "$ROOT/test/visitor_battery/64_async_defer.mdk" 0 ""
check_liftoff_stack async-do "$ROOT/test/visitor_battery/49_async.mdk" 1 T-DO-NOT-MONAD
check_liftoff_stack async-do-panic "$ROOT/test/visitor_battery/65_async_do_panic.mdk" 1 T-NO-IMPL
printf '%d checks, %d failing\n' "$checks" "$fail"
[ "$checks" -gt 0 ] && [ "$fail" -eq 0 ]
