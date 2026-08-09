#!/bin/sh
# Differential validation for the self-hosted EVAL stage (SLICE 1: engine core).
#
# Reference: the committed test/eval_fixtures/<name>.eval.golden — the pp_value of
# `main` captured (Phase 1, test/capture_goldens.sh) from dev/eval_probe.exe while
# OCaml was trusted (parse → desugar → Eval.eval_program ~prelude:false → pp_value).
# This isolates the eval ENGINE from the prelude/dispatch layer: fixtures in
# test/eval_fixtures/ are self-contained / prelude-free and aggregate their results
# into a single `main` value.
#
# ⚠️ NO TYPECHECK:  parse -> desugar -> [annotate -> lower] -> eval
#
# test/eval_fixtures/ is a TYPECHECK-FREE corpus. Not one of its five consumers
# (this gate, bootstrap_eval.sh, diff_compiler_core_ir.sh,
# diff_compiler_core_ir_roundtrip.sh, diff_compiler_snapshot_core_ir.sh) imports
# `types.typecheck` — see compiler/entries/eval_main.mdk:19,
# compiler/entries/core_ir_main.mdk:33, compiler/entries/core_ir_roundtrip_main.mdk:28
# and compiler/tools/snapshot.mdk:588 — so NO `Mono` is ever constructed for a
# fixture here, and the snapshots carry `stages=CORE_IR` with no TYPES section.
# Stated here because it was recoverable only by opening four entry files, and a
# careful author twice wrote a confident, detailed, FALSE claim that a fixture in
# this directory exercised the type checker (#1110 PR "A" review). A type-level
# assertion belongs in test/typecheck_error_fixtures/ or test/typecheck_fixtures/.
#
# OCaml-free (REROOT-PLAN.md Phase 2): the self-hosted eval runs as the pre-compiled
# native binary test/bin/eval_main (built by test/build_oracles.sh) instead of
# `main.exe run compiler/entries/eval_main.mdk`.  It must render the SAME pp_value as
# the golden.
#
# Usage:  sh test/diff_compiler_eval.sh
# Exit:   0 if every fixture matches.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/eval_main"
FIXDIR="$ROOT/test/eval_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$RUN") (missing $RUN)"; exit 2; }

# The native value entry auto-prints main's Unit return as a trailing "()" line
# (runtime/medaka_rt.c); the eval_probe golden has none — drop a sole trailing "()".
strip_unit() { sed '${/^()$/d;}'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  # ⚠️ `sh test/capture_goldens.sh` is a NO-OP for this corpus (#1241) — test/eval_fixtures/
  # is a FROZEN dev-probe family (dev/eval_probe.exe, removed with OCaml); it is not a
  # ROWS entry and has no `--frozen` tag (see test/capture_goldens.sh's "FROZEN families"
  # list). There is no regeneration script.
  [ -f "$golden" ] || { echo "no golden for $name — NO REGEN SCRIPT (FROZEN corpus); hand-derive the expected pp_value and write $golden yourself"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$("$RUN" "$f" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
