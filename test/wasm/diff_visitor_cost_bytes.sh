#!/usr/bin/env bash
# diff_visitor_cost_bytes.sh — S4 gate (#2442, epic #2036 visitor-wait-time arm).
# Asserts an ABSOLUTE CEILING on the total byte size of the assembled
# `playground/site/` tree — i.e. what `playground/build_site.sh` (the exact
# static-host deploy tree, per its own header) produces. Neither number in
# the visitor-wait-time contract's §1 claim was gated anywhere before this
# slice (F6) — this is one of the two (the other is analyze() latency, gated
# separately at nightly tier by diff_visitor_analyze_latency.sh: a wall-clock
# number flaps on this shared box, per [G14] precedent, so it does not belong
# at PR-merge tier; total bytes is deterministic file-size arithmetic and
# does not).
#
# Deliberately NOT gated on compression (a live-CDN concern, C4/S3's own
# territory) — this is local file-size only, no origin needed. Deliberately
# the WHOLE assembled tree (guide/*.html and the lazily-fetched
# EXTRA_MODULES *.mdk included), not a curated "what a fresh visitor's
# browser eagerly requests" subset: the contract's own §4 describes this gate
# as "byte-counting the assembled tree", and curating a subset would require
# an independent judgment call about which assets are eager vs. lazy that
# this slice is not licensed to make.
#
# Shape modeled on test/wasm/diff_wasm_emitted_size.sh (S5's absolute-ceiling
# precedent): `shard = "other-job"` (this job — `wasm` in ci.yml — is
# hand-wired, not part of the generated gates_N matrix), headroom over the
# measured total so ordinary asset churn doesn't false-positive, while a
# deliberate bloat (a stray file, a regressed dependency) still reds.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SITE="$ROOT/playground/site"
DIST="$ROOT/playground/dist"

# ── measured total (S4 landing, sprint-branch base 5854e2598) 5,348,553 bytes
# — ~16% headroom so ordinary asset/guide-content growth doesn't flap.
SITE_BYTES_CEIL=6200000

NODE=node
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$major" -lt 24 ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
fi
[ "$major" -ge 24 ] || { echo "S4 SKIP  Node >= 24 required (have $($NODE --version 2>/dev/null))"; exit 2; }
command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH — skipping S4 visitor-cost-bytes gate"; exit 2; }

# build_site.sh builds dist/playground.wasm itself if missing (via
# build_playground_wasm.sh) — cheap here when a job-earlier gate
# (diff_playground_input.sh) already built it, full cost standalone.
if ! bash "$ROOT/playground/build_site.sh" >"$ROOT/.diff_visitor_cost_bytes.build.log" 2>&1; then
  echo "FAIL  playground/build_site.sh did not succeed:"
  cat "$ROOT/.diff_visitor_cost_bytes.build.log"
  rm -f "$ROOT/.diff_visitor_cost_bytes.build.log"
  exit 1
fi
rm -f "$ROOT/.diff_visitor_cost_bytes.build.log"

[ -d "$SITE" ] || { echo "FAIL  $SITE was not produced"; exit 1; }

total=$(find "$SITE" -type f -exec cat {} + | wc -c | tr -d ' ')

echo "S4 visitor-cost-bytes — playground/site/ total = $total bytes"

if [ "$total" -gt "$SITE_BYTES_CEIL" ]; then
  over=$((total - SITE_BYTES_CEIL))
  echo "FAIL  site total $total bytes exceeds ceiling $SITE_BYTES_CEIL (over by $over)"
  exit 1
fi
echo "ok    site total $total bytes (ceiling $SITE_BYTES_CEIL)"
exit 0
