#!/usr/bin/env bash
# build_guide.sh — render docs/guide/*.md into a staging directory of HTML pages.
#
# A thin, conventional entry point over the general renderer
# playground/render_docs.mjs, which is doc-set-agnostic (it takes --src/--out) so
# the same machine renders the stdlib reference later (#2384) without a second
# implementation.
#
# Standalone: needs only node and the COMMITTED marked bundle at
# playground/vendor/marked/marked.js. No network, no npm install.
#
#   bash playground/build_guide.sh                 # docs/guide -> playground/site-guide
#   bash playground/build_guide.sh <src> <out>     # any doc set, any destination
#
# The output directory is a STAGING dir. Wiring it into the deployable site is
# playground/build_site.sh's job (S-3), not this script's.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC="${1:-$REPO_ROOT/docs/guide}"
OUT="${2:-$SCRIPT_DIR/site-guide}"

# OUTLINE.md is the guide's planning document (chapter plan, word budgets), not a
# chapter — it is deliberately NOT published.
exec node "$SCRIPT_DIR/render_docs.mjs" \
  --src "$SRC" \
  --out "$OUT" \
  --exclude OUTLINE.md \
  --title "The Medaka Guide" \
  --repo-root "$REPO_ROOT"
