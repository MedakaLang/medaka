#!/usr/bin/env bash
# playground/e2e/run.sh — run the Playwright e2e harness against the CM6
# playground, driving the SYSTEM Google Chrome (no Playwright browser
# download — TLS-blocked on this machine). See README.md for the full story.
#
# Two modes:
#   bash playground/e2e/run.sh            serve the DEV tree (playground/)
#   SITE=1 bash playground/e2e/run.sh     serve the DEPLOYED tree (playground/site/)
#
# SITE=1 is the one that tests what users get: playground/site/ is what
# build_site.sh assembles and deploy_cloudflare.sh uploads — a different file set
# from the dev tree, containing the rendered guide AND the rendered stdlib
# reference. Under SITE=1 the guide-route and /stdlib-route checks in the spec
# become MANDATORY rather than skipped (E2E_EXPECT_GUIDE / E2E_EXPECT_STDLIB).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYGROUND_ROOT="$(cd "$HERE/.." && pwd)"
PORT="${PORT:-8099}"
SCREENSHOT_DIR="$HERE/screenshots"
SITE="${SITE:-}"
if [ -n "$SITE" ]; then
  SERVE_ROOT="$PLAYGROUND_ROOT/site"
  export E2E_EXPECT_GUIDE=1
  export E2E_EXPECT_STDLIB=1
else
  SERVE_ROOT="$PLAYGROUND_ROOT"
fi

# ── node v24+ required (system default may be v20, which can't run the
#    finalized-WasmGC module the playground ships). ──────────────────────────
NODE24="$HOME/.nvm/versions/node/v24.17.0/bin"
if [ -d "$NODE24" ]; then
  export PATH="$NODE24:$PATH"
fi
NODE_MAJOR="$(node -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" -lt 24 ]; then
  echo "ERROR: node v24+ required (found $(node -v 2>/dev/null || echo none))." >&2
  echo "Install/enable node v24, e.g. via nvm, then re-run." >&2
  exit 1
fi

# ── dist/ must already be built — this harness does not build the wasm.
#    Checked against the tree actually being served, so a stale-or-absent site/
#    is a loud failure here and NEVER a silent fall-back to the dev tree.
if [ ! -f "$SERVE_ROOT/dist/playground.wasm" ]; then
  echo "ERROR: $SERVE_ROOT/dist/playground.wasm is missing." >&2
  if [ -n "$SITE" ]; then
    echo "Build the deployable site first: bash $PLAYGROUND_ROOT/build_site.sh" >&2
  else
    echo "Build it first: bash $PLAYGROUND_ROOT/build_playground_wasm.sh" >&2
    echo "(or copy an already-built playground/dist/ from another checkout)." >&2
  fi
  exit 1
fi

# ── SITE=1 additionally requires the rendered guide: build_site.sh puts it in
#    site/guide/, playground/index.html links straight to it, and a site without
#    it is exactly the broken deploy this mode exists to catch.
if [ -n "$SITE" ] && [ ! -d "$SERVE_ROOT/guide" ]; then
  echo "ERROR: $SERVE_ROOT/guide is missing — site/ was assembled without the guide." >&2
  echo "Rebuild it: bash $PLAYGROUND_ROOT/build_site.sh" >&2
  exit 1
fi

# ── …and the rendered stdlib reference, for the same reason (#2384). The
#    /stdlib route is a second published doc set with the same failure mode: a
#    site assembled without it deploys clean and 404s only for readers. Failing
#    LOUD here is what keeps "site/stdlib is missing" from reading as "the
#    stdlib route tests passed" — E2E_EXPECT_STDLIB above is the spec-side half
#    of the same discipline.
if [ -n "$SITE" ] && [ ! -d "$SERVE_ROOT/stdlib" ]; then
  echo "ERROR: $SERVE_ROOT/stdlib is missing — site/ was assembled without the stdlib reference." >&2
  echo "Rebuild it: bash $PLAYGROUND_ROOT/build_site.sh" >&2
  exit 1
fi

# ── npm deps (playwright) ────────────────────────────────────────────────────
if [ ! -d "$HERE/node_modules/playwright" ]; then
  echo "Installing e2e devDependencies (playwright) ..."
  (cd "$HERE" && npm install --no-audit --no-fund)
fi

mkdir -p "$SCREENSHOT_DIR"
rm -f "$SCREENSHOT_DIR"/*.png

# ── run ───────────────────────────────────────────────────────────────────────
echo "serving: $SERVE_ROOT${SITE:+  (deployed site layout)}"
STATUS=0
node "$HERE/lib/run-server-and-tests.mjs" "$PLAYGROUND_ROOT" "$PORT" "$SCREENSHOT_DIR" "$SERVE_ROOT" || STATUS=$?

echo
if [ "$STATUS" -eq 0 ]; then
  echo "e2e harness: PASS"
else
  echo "e2e harness: FAIL (exit $STATUS)"
fi
echo "Screenshots: $SCREENSHOT_DIR"
exit "$STATUS"
