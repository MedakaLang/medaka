#!/bin/sh
# diff_compiler_guide_render.sh — CI entry point for the docs render machine.
#
# The assertions themselves live in playground/guide_render_test.mjs (S-1,
# #2386): it renders docs/guide into a scratch directory and grades the
# properties the deployed site depends on — one page per source chapter, no
# surviving relative `.md` href, every internal link naming an emitted page,
# unique heading ids with a resolving TOC, non-empty articles, one known-lang
# codeblock per source fence, and an unknown fence label REFUSED rather than
# rendered as prose.
#
# This wrapper exists because nothing in CI can run a bare `.mjs`: a gate is a
# `.sh` (test/gates.toml `run =`, test/run_gates.sh's two-glob name resolution,
# test/preflight.sh's `_gate_candidates`). Keeping the assertions in the .mjs and
# the enrolment here means the renderer's own test stays runnable standalone
# (`node playground/guide_render_test.mjs`) while still being something CI
# actually executes.
#
# It also makes the renderer's inputs DERIVABLE by preflight: this file's live
# references to playground/guide_render_test.mjs, playground/render_docs.mjs and
# playground/build_guide.sh are what test/preflight.sh's `_consumes` scan reads
# to map a change in any of those three back to this gate. Do not demote those
# paths to prose-only mentions.
#
# Node only — it grades the RENDERER, not the compiler, so it needs no ./medaka
# and no oracle binary.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TEST="$ROOT/playground/guide_render_test.mjs"
RENDERER="$ROOT/playground/render_docs.mjs"
BUILDER="$ROOT/playground/build_guide.sh"
MARKED="$ROOT/playground/vendor/marked/marked.js"
SRC="$ROOT/docs/guide"

fail=0
for f in "$TEST" "$RENDERER" "$BUILDER" "$MARKED"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing ${f#"$ROOT"/}" >&2
    fail=1
  fi
done
if [ ! -d "$SRC" ]; then
  echo "FAIL: missing docs/guide" >&2
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not found — this gate needs node>=24 (see test/gates.toml toolchain)" >&2
  exit 1
fi

echo "-- guide render assertions (node playground/guide_render_test.mjs)"
node "$TEST" --src "$SRC" || exit 1

# The renderer is doc-set-agnostic on purpose (build_guide.sh is a thin entry
# point over it, and the stdlib reference is meant to reuse the same machine,
# #2384). Prove the conventional entry point still works end-to-end into a
# scratch destination — the exact call build_site.sh makes, minus the deploy tree.
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
echo "-- build_guide.sh end-to-end into a scratch out-dir"
# bash, not sh: build_guide.sh is a bash script (it uses BASH_SOURCE to locate
# itself), exactly as build_site.sh invokes it. This gate's own body stays
# POSIX/dash-clean.
bash "$BUILDER" "$SRC" "$OUT/guide" >/dev/null || {
  echo "FAIL: build_guide.sh exited non-zero" >&2
  exit 1
}

# Fails closed on the same DERIVED page set build_site.sh checks: docs/guide/*.md
# minus OUTLINE.md (the guide's planning doc, deliberately unpublished). A
# hardcoded chapter list here would be the drift both checks exist to prevent.
missing=""
for m in "$SRC"/*.md; do
  b="$(basename "$m")"
  if [ "$b" != "OUTLINE.md" ] && [ ! -f "$OUT/guide/${b%.md}.html" ]; then
    missing="$missing ${b%.md}.html"
  fi
done
[ -f "$OUT/guide/guide.css" ] || missing="$missing guide.css"
if [ -n "$missing" ]; then
  echo "FAIL: build_guide.sh did not emit:$missing" >&2
  exit 1
fi

pages="$(ls "$OUT/guide"/*.html | wc -l | tr -d ' ')"
echo "-- build_guide.sh emitted $pages page(s) + guide.css"
echo "PASS: diff_compiler_guide_render"
