#!/usr/bin/env bash
# build_site.sh — assemble a deployable static site folder for the Medaka playground.
#
# Produces playground/site/ containing exactly what a static CDN needs:
#   index.html
#   favicon.svg  og-card.png
#   main.js
#   editor.js  medaka_lang.js  medaka_tokenizer.js  diagnostics_map.js
#   language-worker.js
#   compile.mjs
#   compiler-worker.js
#   worker.js
#   vendor/wat2wasm/wat2wasm.js
#   vendor/wat2wasm/wat2wasm_bg.wasm
#   vendor/wat2wasm/wat2wasm.d.ts   (if present)
#   vendor/codemirror/codemirror.js
#   dist/playground.wasm
#   dist/runtime.mdk  dist/core.mdk
#   dist/<m>.mdk      for every EXTRA_MODULES entry in main.js (array, list, …)
#   guide/<chapter>.html  one page per docs/guide/*.md (OUTLINE.md excluded)
#   guide/guide.css
#   advanced/<chapter>.html  one page per docs/advanced/*.md
#   advanced/guide.css
#   stdlib/<module>.html  one page per docs/stdlib/*.md (the three design notes
#                         build_stdlib_docs.sh excludes are not published)
#   stdlib/guide.css
#   _headers          Cloudflare Pages header rules (compresses /dist/*.mdk)
#
# Runs build_playground_wasm.sh first if dist/playground.wasm is missing.
# Runs build_guide.sh to render the guide straight into site/guide/,
# build_advanced_docs.sh to render the advanced topics into site/advanced/, and
# build_stdlib_docs.sh to render the stdlib reference into site/stdlib/.
# playground/site/ is gitignored — do NOT commit it.
#
# Deploy: upload playground/site/ to any static host (GitHub Pages, Cloudflare
# Pages, Netlify, etc.) with no server-side logic needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SITE="$SCRIPT_DIR/site"
DIST="$SCRIPT_DIR/dist"

# ── Build dist artifacts if missing ─────────────────────────────────────────
if [ ! -f "$DIST/playground.wasm" ]; then
  echo "[build_site] dist/playground.wasm not found — running build_playground_wasm.sh ..."
  bash "$SCRIPT_DIR/build_playground_wasm.sh"
fi

[ -f "$DIST/playground.wasm" ] || { echo "FAIL: dist/playground.wasm still missing after build"; exit 1; }
[ -f "$DIST/runtime.mdk" ]     || { echo "FAIL: dist/runtime.mdk missing"; exit 1; }
[ -f "$DIST/core.mdk" ]        || { echo "FAIL: dist/core.mdk missing"; exit 1; }

# ── Assemble site/ ───────────────────────────────────────────────────────────
echo "[build_site] assembling $SITE ..."
rm -rf "$SITE"
mkdir -p "$SITE/vendor/wat2wasm" "$SITE/vendor/codemirror" "$SITE/dist"

# Static page + JS glue (editor modules included)
cp "$SCRIPT_DIR/index.html"          "$SITE/"
cp "$SCRIPT_DIR/404.html"            "$SITE/"
cp "$SCRIPT_DIR/favicon.svg"         "$SITE/"
cp "$SCRIPT_DIR/og-card.png"         "$SITE/"
cp "$SCRIPT_DIR/main.js"             "$SITE/"
cp "$SCRIPT_DIR/editor.js"           "$SITE/"
cp "$SCRIPT_DIR/medaka_lang.js"      "$SITE/"
cp "$SCRIPT_DIR/medaka_tokenizer.js" "$SITE/"
cp "$SCRIPT_DIR/diagnostics_map.js"  "$SITE/"
cp "$SCRIPT_DIR/language-worker.js"  "$SITE/"
cp "$SCRIPT_DIR/compile.mjs"         "$SITE/"
cp "$SCRIPT_DIR/compiler-worker.js"  "$SITE/"
cp "$SCRIPT_DIR/worker.js"           "$SITE/"

# Committed wat2wasm assembler blob
cp "$SCRIPT_DIR/vendor/wat2wasm/wat2wasm.js"      "$SITE/vendor/wat2wasm/"
cp "$SCRIPT_DIR/vendor/wat2wasm/wat2wasm_bg.wasm" "$SITE/vendor/wat2wasm/"
[ -f "$SCRIPT_DIR/vendor/wat2wasm/wat2wasm.d.ts" ] && \
  cp "$SCRIPT_DIR/vendor/wat2wasm/wat2wasm.d.ts" "$SITE/vendor/wat2wasm/"

# Committed CodeMirror 6 single-ESM bundle (see build_editor.sh)
cp "$SCRIPT_DIR/vendor/codemirror/codemirror.js" "$SITE/vendor/codemirror/"

# Compiler wasm + stdlib sources.
#
# Copy EVERY .mdk build_playground_wasm.sh staged, not a hardcoded subset: the
# page fetches runtime.mdk + core.mdk *and* the ~20 EXTRA_MODULES it lists in
# main.js, so `import array` in a user program needs dist/array.mdk present. A
# hand-maintained list here silently drops modules added to main.js later —
# which is exactly how dist/array.mdk went missing and every `import` 404'd at
# Run time.
cp "$DIST/playground.wasm" "$SITE/dist/"
cp "$DIST"/*.mdk           "$SITE/dist/"

# Cloudflare Pages `_headers` file — see the file itself for why this exists
# (routes /dist/*.mdk through Cloudflare's compressible-content-type list).
cp "$SCRIPT_DIR/_headers" "$SITE/"

# ── The guide (docs/guide/*.md -> site/guide/*.html) ─────────────────────────
#
# Rendered STRAIGHT INTO the deploy tree rather than into the playground/site-guide
# staging dir and copied: one output location means there is no second copy to go
# stale, and the renderer's default --playground-url ("../index.html") is already
# correct for this layout — site/guide/x.html reaching site/index.html.
#
# build_guide.sh (and render_docs.mjs under it) needs only `node` and the
# committed marked bundle; no network, no npm install.
#
# $DIST is passed as the third argument so the renderer can withhold the ▶ button
# from a block importing a module this site does not ship — the page fetches each
# import as dist/<id>.mdk, so an unshipped one is a 404 at Run time no matter how
# well the block compiles natively. Safe to pass unconditionally here: dist/ is a
# hard prerequisite checked above.
echo "[build_site] rendering docs/guide -> $SITE/guide ..."
bash "$SCRIPT_DIR/build_guide.sh" "$ROOT/docs/guide" "$SITE/guide" "$SITE/dist"

# ── The advanced topics (docs/advanced/*.md -> site/advanced/*.html) ─────────
#
# Same shape as the guide block above, same reasons: rendered straight into the
# deploy tree, one directory below site/index.html so the renderer's default
# --playground-url is already right, $DIST passed for the ▶-button check.
echo "[build_site] rendering docs/advanced -> $SITE/advanced ..."
bash "$SCRIPT_DIR/build_advanced_docs.sh" "$ROOT/docs/advanced" "$SITE/advanced" "$SITE/dist"

# ── The stdlib reference (docs/stdlib/*.md -> site/stdlib/*.html) ────────────
#
# Same shape as the guide block above, same reasons: rendered straight into the
# deploy tree (no staging copy to go stale), $DIST passed unconditionally for the
# ▶-button unshipped-import check.
#
# site/stdlib/*.html sits exactly one directory below site/index.html, the same
# depth as site/guide/*.html, so render_docs.mjs's default --playground-url
# ("../index.html") is already correct here and is deliberately not overridden —
# the pages' "← Playground" nav resolves to this site's own index.html.
#
# The published set is the GENERATED reference (docs/stdlib/index.md and its
# per-module pages). build_stdlib_docs.sh excludes the three hand-written design
# notes that share the directory; that exclusion list lives there, and the check
# below reads it back out rather than restating it.
echo "[build_site] rendering docs/stdlib -> $SITE/stdlib ..."
bash "$SCRIPT_DIR/build_stdlib_docs.sh" "$ROOT/docs/stdlib" "$SITE/stdlib" "$SITE/dist"

# ── The blog (docs/blog/*.md -> site/blog/*.html) ────────────────────────────
#
# The same renderer, called directly rather than through a build_*.sh wrapper:
# a new .sh under playground/ is a gate candidate to test/preflight.sh. Posts are
# prose whose code is illustration, so --no-run-links drops the ▶ footers, and
# they are not read in sequence, so --no-pager drops the previous/next links and
# --no-toc the "On this page" box;
# docs/blog/index.md is the authored post list. A post's link-card image lives in
# playground/blog-cards/ (named by the post's `<!-- og-image: … -->` comment) and
# is copied verbatim beside the rendered post.
echo "[build_site] rendering docs/blog -> $SITE/blog ..."
node "$SCRIPT_DIR/render_docs.mjs" \
  --src "$ROOT/docs/blog" \
  --out "$SITE/blog" \
  --title "The Medaka Blog" \
  --repo-root "$ROOT" \
  --no-run-links \
  --no-pager \
  --no-toc \
  --nav-link "Guide=../guide/index.html" \
  --nav-link "Advanced=../advanced/index.html" \
  --nav-link "Stdlib=../stdlib/index.html" \
  --nav-link "GitHub=https://github.com/MedakaLang/medaka" \
  --site-url "https://medaka-lang.dev/blog" \
  --og-image "https://medaka-lang.dev/og-card.png" \
  --og-image-alt "Medaka, a practical functional language."
cp "$SCRIPT_DIR"/blog-cards/* "$SITE/blog/"

# ── Verify the site can actually serve what the page asks for ───────────────
# Derived from main.js, so this check cannot drift from the page's real needs.
missing=""
for m in $(sed -n '/^const EXTRA_MODULES = \[/,/\];/p' "$SCRIPT_DIR/main.js" \
             | grep -o "'[a-z_0-9]*'" | tr -d "'"); do
  [ -f "$SITE/dist/$m.mdk" ] || missing="$missing $m.mdk"
done
for f in runtime.mdk core.mdk; do
  [ -f "$SITE/dist/$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
  echo "FAIL: main.js fetches these at runtime but they are not in site/dist:$missing" >&2
  exit 1
fi

# Import closure: a shipped module may only import modules that are shipped
# too, else `import <mod>` dies in the browser with "unknown module: <dep>".
# Reads the `import` lines of the .mdk files actually in site/dist.
unshipped=""
for f in "$SITE"/dist/*.mdk; do
  for dep in $(sed -n 's/^import \([a-z_0-9]*\).*/\1/p' "$f" | sort -u); do
    [ -f "$SITE/dist/$dep.mdk" ] || unshipped="$unshipped $(basename "$f" .mdk)->$dep"
  done
done
if [ -n "$unshipped" ]; then
  echo "FAIL: shipped modules import modules that are not shipped (add to EXTRA_MODULES in main.js and build_playground_wasm.sh):$unshipped" >&2
  exit 1
fi

# Same shape, same reason, for the guide: the expected page set is DERIVED from
# docs/guide/ (minus OUTLINE.md, the guide's planning doc — build_guide.sh
# excludes it, so this must too), never a hardcoded chapter list. A chapter added
# to docs/guide/ that the renderer somehow failed to emit is a loud failure here
# rather than a page that is quietly absent from the deploy.
missing_guide=""
for m in "$ROOT"/docs/guide/*.md; do
  b="$(basename "$m")"
  if [ "$b" != "OUTLINE.md" ] && [ ! -f "$SITE/guide/${b%.md}.html" ]; then
    missing_guide="$missing_guide ${b%.md}.html"
  fi
done
[ -f "$SITE/guide/guide.css" ] || missing_guide="$missing_guide guide.css"
if [ -n "$missing_guide" ]; then
  echo "FAIL: docs/guide names these but they are not in site/guide:$missing_guide" >&2
  exit 1
fi

# Same derived-set check for the advanced topics: every docs/advanced/*.md must
# have rendered (the set has no exclusions), plus the stylesheet.
missing_advanced=""
for m in "$ROOT"/docs/advanced/*.md; do
  b="$(basename "$m")"
  [ -f "$SITE/advanced/${b%.md}.html" ] || missing_advanced="$missing_advanced ${b%.md}.html"
done
[ -f "$SITE/advanced/guide.css" ] || missing_advanced="$missing_advanced guide.css"
if [ -n "$missing_advanced" ]; then
  echo "FAIL: docs/advanced names these but they are not in site/advanced:$missing_advanced" >&2
  exit 1
fi

# Fourth instance of the same shape, for the stdlib reference. The expected page
# set is DERIVED from docs/stdlib/ minus build_stdlib_docs.sh's OWN --exclude
# list, read back out of that script — one copy of the exclusion set, not two.
# (test/diff_compiler_guide_render.sh derives it the same way, for the same
# reason: a hand-typed second copy drifts silently the moment either side moves.)
stdlib_exclude="$(sed -n 's/^  --exclude \(.*\) \\$/\1/p' "$SCRIPT_DIR/build_stdlib_docs.sh")"
if [ -z "$stdlib_exclude" ]; then
  echo "FAIL: could not read the --exclude list out of playground/build_stdlib_docs.sh" >&2
  exit 1
fi
missing_stdlib=""
for m in "$ROOT"/docs/stdlib/*.md; do
  b="$(basename "$m")"
  case ",$stdlib_exclude," in
    *",$b,"*) ;;
    *) [ -f "$SITE/stdlib/${b%.md}.html" ] || missing_stdlib="$missing_stdlib ${b%.md}.html" ;;
  esac
done
[ -f "$SITE/stdlib/guide.css" ] || missing_stdlib="$missing_stdlib guide.css"
if [ -n "$missing_stdlib" ]; then
  echo "FAIL: docs/stdlib names these but they are not in site/stdlib:$missing_stdlib" >&2
  exit 1
fi

# Fifth instance, for the blog: every docs/blog/*.md rendered (index.md is the
# authored index, so it renders to index.html like any other page), plus the
# stylesheet and every playground/blog-cards/ image.
missing_blog=""
for m in "$ROOT"/docs/blog/*.md "$SCRIPT_DIR"/blog-cards/*; do
  b="$(basename "$m")"
  case "$b" in
    *.md) [ -f "$SITE/blog/${b%.md}.html" ] || missing_blog="$missing_blog ${b%.md}.html" ;;
    *) [ -f "$SITE/blog/$b" ] || missing_blog="$missing_blog $b" ;;
  esac
done
[ -f "$SITE/blog/guide.css" ] || missing_blog="$missing_blog guide.css"
if [ -n "$missing_blog" ]; then
  echo "FAIL: docs/blog and playground/blog-cards name these but they are not in site/blog:$missing_blog" >&2
  exit 1
fi

# ── Report ───────────────────────────────────────────────────────────────────
echo
echo "site contents:"
find "$SITE" -type f | sort | while read -r f; do
  size=$(wc -c < "$f" | tr -d ' ')
  printf '  %-55s %10d bytes\n' "${f#$SITE/}" "$size"
done
echo
TOTAL=$(find "$SITE" -type f -exec wc -c {} + 2>/dev/null | tail -1 | awk '{print $1}')
echo "total: $TOTAL bytes ($(( TOTAL / 1024 )) KB)"
echo
echo "deploy: upload playground/site/ to any static host (GitHub Pages, Cloudflare Pages, Netlify, etc.)"
