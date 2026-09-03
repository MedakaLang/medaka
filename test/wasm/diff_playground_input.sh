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
printf '%d checks, %d failing\n' "$checks" "$fail"
[ "$checks" -gt 0 ] && [ "$fail" -eq 0 ]
