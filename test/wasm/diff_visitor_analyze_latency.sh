#!/usr/bin/env bash
# shell-because: instrumentation — valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing
# diff_visitor_analyze_latency.sh — S4 gate (#2442, epic #2036 visitor-wait-time
# arm). Asserts an ABSOLUTE CEILING on `analyze()` (playground/compile.mjs,
# landed by S1) latency for a fixed clean program, driven the SAME way
# playground/language-worker.js drives it — per the sprint contract's §3
# shared decision, not a fresh notion of "analyze".
#
# NIGHTLY tier, not merge — the contract's §4 note is explicit: the SAME
# program's `compile` arm alone varied 683-789ms across two consecutive runs
# on this shared box (14% swing) with nothing else changing. A tight
# PR-blocking wall-clock ceiling WILL flap. Precedent for this exact
# tradeoff: test/diff_compiler_perf_scaling.sh's [G14] — a flappy-cost arm
# does not belong gating a PR merge, and that suite keeps its
# expensive/noisy timing rows nightly-only. So this ceiling is
# ORDER-OF-MAGNITUDE loose (~20x the measured min, not a percentage) —
# tight enough to catch a real regression (an accidental re-introduced
# doEmit-style re-elaboration, an infinite/quadratic blowup), loose enough
# that ordinary box noise never trips it.
#
# The byte-ceiling half of this instrument (deterministic, no box noise) is
# the SEPARATE merge-tier gate diff_visitor_cost_bytes.sh.
#
# Fix-2-latency-ceiling (review round F3, #2442): the original 5000ms ceiling
# was ~20x too loose to catch the regression it exists to catch — a full
# revert of the sprint (analyze() mode never existing, falling back to the
# pre-sprint compile() path's full codegen cost) still measures ~558ms,
# comfortably under 5000ms. Re-measured `analyze()` min on this worktree's
# freshly built playground.wasm across 4 runs: 235/259/267/281ms (min range),
# med up to 331ms — consistent with landing's 217-238ms plus visible box
# noise. Ceiling retightened to 400ms: ~120-165ms (30-40%) headroom above the
# fresh measured min range, and ~158ms (28%) margin below the ~558ms
# full-revert baseline — tight enough that a reintroduced full-codegen
# regression fails with real margin, loose enough for ordinary box noise.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="$ROOT/playground/dist"
PROBE="$ROOT/test/wasm/visitor_analyze_latency.mjs"

# ── measured min (Fix-2-latency-ceiling, this worktree's freshly built
# playground.wasm, 4 runs) 235-281ms — ceiling set at 400ms: real margin
# above measured min and real margin below the ~558ms full-revert baseline.
ANALYZE_MS_CEIL=400

NODE=node
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$major" -lt 24 ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
fi
[ "$major" -ge 24 ] || { echo "S4 SKIP  Node >= 24 required (have $($NODE --version 2>/dev/null))"; exit 2; }

if [ ! -f "$DIST/playground.wasm" ]; then
  echo "S4 visitor-cost-latency: dist/playground.wasm missing — building it ..."
  bash "$ROOT/playground/build_playground_wasm.sh" || { echo "FAIL  build_playground_wasm.sh did not succeed"; exit 1; }
fi
[ -f "$DIST/playground.wasm" ] || { echo "FAIL  $DIST/playground.wasm still missing after build"; exit 1; }
[ -f "$DIST/runtime.mdk" ]     || { echo "FAIL  $DIST/runtime.mdk missing"; exit 1; }
[ -f "$DIST/core.mdk" ]        || { echo "FAIL  $DIST/core.mdk missing"; exit 1; }

node "$PROBE" "$ANALYZE_MS_CEIL"
exit $?
