#!/usr/bin/env bash
# build_advanced_docs.sh — render docs/advanced/*.md into a staging directory of
# HTML pages: the published "Advanced Topics" section.
#
# The third thin entry point over playground/render_docs.mjs, beside
# build_guide.sh (docs/guide) and build_stdlib_docs.sh (docs/stdlib). Not a
# fork: the doc sets differ only in their arguments — this one has a different
# title, no exclusions, and no index.md of its own (so it takes the renderer's
# synthetic chapter-list index, like the guide).
#
#   bash playground/build_advanced_docs.sh                     # docs/advanced -> playground/site-advanced
#   bash playground/build_advanced_docs.sh <src> <out>         # any doc set, any destination
#   bash playground/build_advanced_docs.sh <src> <out> <dist>  # …and check imports against <dist>
#
# The third argument is the directory of `.mdk` modules the playground page ships
# (playground/dist). Deliberately not defaulted, for the reason build_guide.sh
# gives: dist/ exists only after a wasm build, so defaulting it would make the
# rendered output depend on whether someone had built the wasm.
#
# The output directory is a STAGING dir. Wiring it into the deployable site is
# playground/build_site.sh's job, not this script's.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC="${1:-$REPO_ROOT/docs/advanced}"
OUT="${2:-$SCRIPT_DIR/site-advanced}"
DIST="${3:-}"

DIST_ARGS=()
if [ -n "$DIST" ]; then
  DIST_ARGS=(--dist "$DIST")
fi

exec node "$SCRIPT_DIR/render_docs.mjs" \
  --src "$SRC" \
  --out "$OUT" \
  --title "Medaka: Advanced Topics" \
  --repo-root "$REPO_ROOT" \
  --nav-link "Guide=../guide/index.html" \
  --nav-link "Stdlib=../stdlib/index.html" \
  --nav-link "GitHub=https://github.com/MedakaLang/medaka" \
  --sibling "guide=../guide" \
  --sibling "stdlib=../stdlib" \
  "${DIST_ARGS[@]+"${DIST_ARGS[@]}"}"
