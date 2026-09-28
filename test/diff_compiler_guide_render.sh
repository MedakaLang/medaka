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
# references to playground/guide_render_test.mjs, playground/render_docs.mjs,
# playground/build_guide.sh, playground/build_advanced_docs.sh and
# playground/build_stdlib_docs.sh are what test/preflight.sh's `_consumes` scan
# reads to map a change in any of those five back to this gate. Do not demote
# those paths to prose-only mentions.
#
# THREE DOC SETS, ONE MACHINE. The renderer is doc-set-agnostic by design, and
# it has three real callers: docs/guide, docs/stdlib (#2384, rendered by
# playground/build_stdlib_docs.sh) and docs/advanced (the Advanced Topics
# section, playground/build_advanced_docs.sh). All are graded here, by the same
# assertions, because they exercise different halves of the renderer — the guide
# and the advanced set have no `index.md` (so they take the SYNTHETIC index arm)
# and no doctests (so every `medaka` fence takes the FOOTER arm), and the stdlib
# reference is the exact inverse on both. Grading only one leaves the other arm
# ungated. The three link to each other (`--sibling`), and each arm below passes
# the pairs its builder passes, read out of the builder.
#
# Node only — it grades the RENDERER, not the compiler, so it needs no ./medaka
# and no oracle binary.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TEST="$ROOT/playground/guide_render_test.mjs"
RENDERER="$ROOT/playground/render_docs.mjs"
BUILDER="$ROOT/playground/build_guide.sh"
ADVANCED_BUILDER="$ROOT/playground/build_advanced_docs.sh"
STDLIB_BUILDER="$ROOT/playground/build_stdlib_docs.sh"
MARKED="$ROOT/playground/vendor/marked/marked.js"
SRC="$ROOT/docs/guide"
ADVANCED_SRC="$ROOT/docs/advanced"
STDLIB_SRC="$ROOT/docs/stdlib"
# The three hand-written design notes docs/stdlib carries alongside the
# generated reference. Kept in step with build_stdlib_docs.sh's --exclude by
# being read back OUT of it, not by a second hand-typed copy here.
STDLIB_EXCLUDE="$(sed -n 's/^  --exclude \(.*\) \\$/\1/p' "$STDLIB_BUILDER")"

fail=0
for f in "$TEST" "$RENDERER" "$BUILDER" "$ADVANCED_BUILDER" "$STDLIB_BUILDER" "$MARKED"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing ${f#"$ROOT"/}" >&2
    fail=1
  fi
done
for d in "$SRC" "$ADVANCED_SRC" "$STDLIB_SRC"; do
  if [ ! -d "$d" ]; then
    echo "FAIL: missing ${d#"$ROOT"/}" >&2
    fail=1
  fi
done
if [ -z "$STDLIB_EXCLUDE" ]; then
  echo "FAIL: could not read the --exclude list out of playground/build_stdlib_docs.sh" >&2
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not found — this gate needs node>=24 (see test/gates.toml toolchain)" >&2
  exit 1
fi

# Each arm passes the SAME --sibling / --sibling-exclude pairs its builder passes
# to the renderer, READ OUT OF THE BUILDER (the same discipline as
# STDLIB_EXCLUDE above): a hand-typed second copy here would grade the cross-set
# links (check 14) under a rule the deploy render might no longer apply. The
# values carry no spaces, so the unquoted expansion splits into arguments.
sibling_args() {
  sed -n 's/^  \(--sibling[-a-z]*\) "\([^"]*\)" \\$/\1 \2/p' "$1" | tr '\n' ' '
}
GUIDE_SIBLINGS="$(sibling_args "$BUILDER")"
ADVANCED_SIBLINGS="$(sibling_args "$ADVANCED_BUILDER")"
STDLIB_SIBLINGS="$(sibling_args "$STDLIB_BUILDER")"
for pair in "$BUILDER:$GUIDE_SIBLINGS" "$ADVANCED_BUILDER:$ADVANCED_SIBLINGS" "$STDLIB_BUILDER:$STDLIB_SIBLINGS"; do
  case "$pair" in
    *:*--sibling*) ;;
    *) echo "FAIL: could not read any --sibling pair out of ${pair%%:*}" >&2; exit 1 ;;
  esac
done

# A builder's --sibling-exclude for a set must equal that set's OWN --exclude,
# read out of its builder: the two lists are the one fact (which source pages
# that set does not render) stated in two places, so they are compared here
# rather than trusted. The advanced set excludes nothing, so no builder may
# claim it does.
own_exclude() {
  sed -n 's/^  --exclude \(.*\) \\$/\1/p' "$1"
}
claimed_exclude() {
  sed -n "s/^  --sibling-exclude \"$2=\([^\"]*\)\" \\\\\$/\1/p" "$1"
}
for claimer in "$BUILDER" "$ADVANCED_BUILDER" "$STDLIB_BUILDER"; do
  for target in "guide:$BUILDER" "advanced:$ADVANCED_BUILDER" "stdlib:$STDLIB_BUILDER"; do
    name="${target%%:*}"
    owner="${target#*:}"
    [ "$claimer" != "$owner" ] || continue
    claimed="$(claimed_exclude "$claimer" "$name")"
    if grep -q "^  --sibling \"$name=" "$claimer"; then
      if [ "$claimed" != "$(own_exclude "$owner")" ]; then
        echo "FAIL: ${claimer#"$ROOT"/} says sibling $name excludes '$claimed', but ${owner#"$ROOT"/} excludes '$(own_exclude "$owner")'" >&2
        exit 1
      fi
    fi
  done
done
echo "-- sibling pairs read out of the builders (and their exclude lists agree)"

echo "-- guide render assertions (node playground/guide_render_test.mjs)"
# shellcheck disable=SC2086
node "$TEST" --src "$SRC" $GUIDE_SIBLINGS || exit 1

echo "-- advanced topics render assertions (same harness, docs/advanced)"
# No exclusions: docs/advanced has no planning doc, so every source page ships.
# An explicit empty --exclude overrides the harness's guide default (OUTLINE.md).
# shellcheck disable=SC2086
node "$TEST" --src "$ADVANCED_SRC" --exclude "" \
  --title "Medaka: Advanced Topics" $ADVANCED_SIBLINGS || exit 1

echo "-- stdlib reference render assertions (same harness, docs/stdlib)"
# shellcheck disable=SC2086
node "$TEST" --src "$STDLIB_SRC" --exclude "$STDLIB_EXCLUDE" \
  --title "The Medaka Standard Library" $STDLIB_SIBLINGS || exit 1

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

echo "-- build_advanced_docs.sh end-to-end into a scratch out-dir"
bash "$ADVANCED_BUILDER" "$ADVANCED_SRC" "$OUT/advanced" >/dev/null || {
  echo "FAIL: build_advanced_docs.sh exited non-zero" >&2
  exit 1
}

# Derived page set, no exclusions: every docs/advanced/*.md, plus the stylesheet.
missing=""
for m in "$ADVANCED_SRC"/*.md; do
  b="$(basename "$m")"
  [ -f "$OUT/advanced/${b%.md}.html" ] || missing="$missing ${b%.md}.html"
done
[ -f "$OUT/advanced/guide.css" ] || missing="$missing guide.css"
if [ -n "$missing" ]; then
  echo "FAIL: build_advanced_docs.sh did not emit:$missing" >&2
  exit 1
fi

advanced_pages="$(ls "$OUT/advanced"/*.html | wc -l | tr -d ' ')"
echo "-- build_advanced_docs.sh emitted $advanced_pages page(s) + guide.css"

echo "-- build_stdlib_docs.sh end-to-end into a scratch out-dir"
bash "$STDLIB_BUILDER" "$STDLIB_SRC" "$OUT/stdlib" >/dev/null || {
  echo "FAIL: build_stdlib_docs.sh exited non-zero" >&2
  exit 1
}

# Same derived-set discipline as the guide arm: docs/stdlib/*.md minus whatever
# the builder itself excludes. The excluded design notes must NOT be published —
# asserted in both directions, because "no page appeared" and "the wrong page
# appeared" are different defects.
missing=""
extra=""
for m in "$STDLIB_SRC"/*.md; do
  b="$(basename "$m")"
  case ",$STDLIB_EXCLUDE," in
    *",$b,"*)
      [ ! -f "$OUT/stdlib/${b%.md}.html" ] || extra="$extra ${b%.md}.html" ;;
    *)
      [ -f "$OUT/stdlib/${b%.md}.html" ] || missing="$missing ${b%.md}.html" ;;
  esac
done
[ -f "$OUT/stdlib/guide.css" ] || missing="$missing guide.css"
if [ -n "$missing" ]; then
  echo "FAIL: build_stdlib_docs.sh did not emit:$missing" >&2
  exit 1
fi
if [ -n "$extra" ]; then
  echo "FAIL: build_stdlib_docs.sh published excluded design note(s):$extra" >&2
  exit 1
fi

stdlib_pages="$(ls "$OUT/stdlib"/*.html | wc -l | tr -d ' ')"
echo "-- build_stdlib_docs.sh emitted $stdlib_pages page(s) + guide.css"
echo "PASS: diff_compiler_guide_render"
