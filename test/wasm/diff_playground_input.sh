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
printf '%d checks, %d failing\n' "$checks" "$fail"
[ "$checks" -gt 0 ] && [ "$fail" -eq 0 ]
