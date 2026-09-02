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
#   bash playground/build_guide.sh                        # docs/guide -> playground/site-guide
#   bash playground/build_guide.sh <src> <out>            # any doc set, any destination
#   bash playground/build_guide.sh <src> <out> <dist>     # …and check imports against <dist>
#
# The third argument is the directory of `.mdk` modules the playground page ships
# (playground/dist, staged by build_playground_wasm.sh). Given, the renderer will
# not put a ▶ button on a block importing a module that is not there. It is
# DELIBERATELY not defaulted to playground/dist: dist/ exists only after a wasm
# build, so defaulting it would make the rendered output depend on whether
# someone had built the wasm — the render gate would grade a different corpus in
# a fresh clone than on a warm box. The real deploy render (build_site.sh) always
# passes it, because there dist/ is a guaranteed prerequisite.
#
# The output directory is a STAGING dir. Wiring it into the deployable site is
# playground/build_site.sh's job (S-3), not this script's.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC="${1:-$REPO_ROOT/docs/guide}"
OUT="${2:-$SCRIPT_DIR/site-guide}"
DIST="${3:-}"

DIST_ARGS=()
if [ -n "$DIST" ]; then
  DIST_ARGS=(--dist "$DIST")
fi

# OUTLINE.md is the guide's planning document (chapter plan, word budgets), not a
# chapter — it is deliberately NOT published.
exec node "$SCRIPT_DIR/render_docs.mjs" \
  --src "$SRC" \
  --out "$OUT" \
  --exclude OUTLINE.md \
  --title "The Medaka Guide" \
  --repo-root "$REPO_ROOT" \
  --nav-link "Stdlib=../stdlib/index.html" \
  --nav-link "GitHub=https://github.com/MedakaLang/medaka" \
  "${DIST_ARGS[@]+"${DIST_ARGS[@]}"}"
