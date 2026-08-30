#!/bin/sh
# Multi-module equivalence gate for the Core IR (STAGE2-DESIGN §2.1) — the
# loader-driven analog of test/diff_compiler_core_ir.sh, broadening the §2.1
# equivalence proof to the eval_modules corpus (per-module Core-IR frames).
#
# Self-host: core_ir_modules_main.mdk loads <entry> + its transitive imports,
# desugars + annotates each, LOWERS them per-module to Core IR, and evaluates them
# in per-module frames over the shared prelude (cevalModules), printing the root
# module's `main` stdout.  Reference: the committed <dir>/main.eval.golden (captured
# from `main.exe run <entry>`, the SAME goldens diff_compiler_eval_modules.sh uses).
#
# Each fixture is a directory under test/eval_modules_fixtures/ holding a single
# `main_*.mdk` entry plus its sibling modules.  Fixtures stay on the UNTYPED path.
#
# OCaml-free (REROOT-PLAN.md Phase 2): the self-hosted Core-IR loader-eval runs as
# the pre-compiled native binary test/bin/core_ir_modules_main (build_oracles.sh).
#
# Usage:  sh test/diff_compiler_core_ir_modules.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/core_ir_modules_main"
MEDAKA="$ROOT/medaka"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_modules_fixtures"
[ -x "$SELF" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$SELF") (missing $SELF)"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }  # drop native runtime's trailing Unit auto-print

pass=0; fail=0
for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  entry="$(ls "$dir"main_*.mdk 2>/dev/null | head -1)"
  [ -n "$entry" ] || { echo "skip $(basename "$dir") (no main_*.mdk)"; continue; }
  name="$(basename "$dir")"
  golden="${dir%/}/main.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$("$SELF" "$CORE" "$entry" "${dir%/}" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  ref:  %s\n' "$ref"
    printf '  self: %s\n' "$self"
  fi
done

# #2133: AST eval and Core-IR eval must classify a reached user extern with the
# same deliberate engine wall.  A separate same-process probe runs an
# unreachable-extern program followed by a pure one, proving the mutable name
# classifier is both seeded and reset rather than leaking between evaluations.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/ffi_reached.mdk" <<'EOF'
extern ffiBlocked : Int -> <FFI> Int

main = println (ffiBlocked 1)
EOF
cat > "$TMP/ffi_unreachable.mdk" <<'EOF'
extern ffiBlocked : Int -> <FFI> Int

main = println 7
EOF
cat > "$TMP/pure.mdk" <<'EOF'
main = println 9
EOF

ast_out="$(MEDAKA_STRICT=1 "$MEDAKA" run "$TMP/ffi_reached.mdk" 2>&1)"
ast_code=$?
case "$ast_out" in
  *"user-declared FFI extern"*"tree-walking interpreter cannot make a foreign C call"*)
    if [ "$ast_code" -eq 1 ]; then
      pass=$((pass+1)); printf 'ok   ffi-engine-wall-ast (exit 1)\n'
    else
      fail=$((fail+1)); printf 'FAIL ffi-engine-wall-ast (wall but exit %d)\n' "$ast_code"
    fi ;;
  *) fail=$((fail+1)); printf 'FAIL ffi-engine-wall-ast ([%s])\n' "$ast_out" ;;
esac

core_out="$(MEDAKA_STRICT=1 "$SELF" "$CORE" "$TMP/ffi_reached.mdk" "$TMP" 2>&1)"
core_code=$?
case "$core_out" in
  *"user-declared FFI extern"*"tree-walking interpreter cannot make a foreign C call"*)
    if [ "$core_code" -eq 1 ]; then
      pass=$((pass+1)); printf 'ok   ffi-engine-wall-core-ir (exit 1)\n'
    else
      fail=$((fail+1)); printf 'FAIL ffi-engine-wall-core-ir (wall but exit %d)\n' "$core_code"
    fi ;;
  *) fail=$((fail+1)); printf 'FAIL ffi-engine-wall-core-ir ([%s])\n' "$core_out" ;;
esac

reset_out="$(MEDAKA_STRICT=1 "$SELF" "$CORE" --ffi-reset-control "$TMP/ffi_unreachable.mdk" "$TMP/pure.mdk" "$TMP" 2>&1)"
reset_code=$?
if [ "$reset_code" -eq 0 ] && [ "$reset_out" = "9" ]; then
  pass=$((pass+1)); printf 'ok   ffi-state-reset-same-process (unreachable extern -> pure)\n'
else
  fail=$((fail+1)); printf 'FAIL ffi-state-reset-same-process (exit %d: [%s])\n' "$reset_code" "$reset_out"
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
