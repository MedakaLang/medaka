#!/usr/bin/env bash
# verify_stdlib_deploy.sh — prove that a LIVE origin actually serves the stdlib
# reference this repository generates (#2384).
#
#   bash playground/verify_stdlib_deploy.sh                        # https://medaka-lang.dev
#   bash playground/verify_stdlib_deploy.sh http://127.0.0.1:8123  # a local stand-in
#
# WHY THIS EXISTS. Nothing else in the tree can answer this question.
# `test/diff_compiler_guide_render.sh` (playground/guide_render_test.mjs) grades
# the RENDERER: it renders docs/stdlib into a scratch directory and checks that
# output. It says so itself, and it is structurally right to — it never reads the
# committed docs/stdlib, never reads playground/site/, and certainly never reads
# anything deployed. `playground/e2e/run.sh` drives a real browser but against a
# LOCAL server over playground/site/, and it is a nightly gate besides. So the
# one question a reader actually cares about — "does the page at
# medaka-lang.dev/stdlib/ match what this repo generates?" — had no answer at all
# before this script.
#
# ⚠️ A RETURN CODE IS NOT THE POINT. [WEB-PREVIEW-SILENT] (AGENTS.md § The
# website): a Cloudflare deploy that publishes a PREVIEW instead of production
# prints "Deployment complete", prints a url, and EXITS 0 while the production
# origin keeps serving 404. That is precisely the failure this script is pointed
# at, so it reports what DIFFERS, by name, and never asks anyone to trust an exit
# status alone. It reads the origin over HTTP and compares against THIS
# checkout's docs/stdlib — every expectation is DERIVED from the tree, never
# hardcoded here (the entry count has already moved once: 873 -> 905).
#
# WHAT IT CHECKS, in order:
#   1. the bare /stdlib/ route serves a page at all (a static host serves a
#      directory URL from index.html or not at all)
#   2. that page is the GENERATED library index — it carries exactly as many
#      entry links as docs/stdlib/index.md has entries, not the 28-item
#      synthetic chapter list that once silently replaced it
#   3. every module page docs/stdlib names is live, and the hand-written design
#      notes build_stdlib_docs.sh excludes are NOT published
#   4. EVERY entry link resolves — target page 200 AND the #anchor is a real
#      heading id on that page. The whole set, one fetch per distinct page.
#   5. the stylesheet and the "<- Playground" back link resolve
#
# Exit 0 = every check passed. Exit 1 = at least one failed, and each failure is
# named individually above the summary. Exit 2 = the origin was unreachable, or
# this checkout cannot supply expectations — told apart from a genuine mismatch
# on purpose: "I could not ask" is not "the answer was no".
set -euo pipefail

BASE="${1:-https://medaka-lang.dev}"
BASE="${BASE%/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS="$ROOT/docs/stdlib"
MAX_REPORT="${MAX_REPORT:-25}"   # per-category cap on NAMED failures; the COUNT is always exact

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not found." >&2; exit 2; }
[ -f "$DOCS/index.md" ] || { echo "ERROR: $DOCS/index.md missing — no expectations to derive." >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
fail() { fails=$((fails + 1)); echo "  FAIL  $*"; }
pass() { echo "  PASS  $*"; }

# fetch <url> <outfile> -> prints the HTTP status; never fails the script
# (000 = the origin gave no answer at all, which is not the same as a 404).
# curl's own exit status is captured explicitly rather than relying on `||`
# after a command substitution that may already have written a partial
# %{http_code} to stdout before failing — that partial output can otherwise
# concatenate with a fallback "000", producing a garbled status (e.g.
# "000000") that fails to equal the literal string "000" downstream, which
# masks a genuine network failure as a content mismatch (exit 1) instead of
# the correct "origin unreachable" (exit 2). Guard: accept the captured
# status only if curl exited 0 AND it is purely digits; otherwise "000".
fetch() {
  local status rc=0
  status="$(curl -sS -L --max-time 30 -o "$2" -w '%{http_code}' "$1" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ] && [[ "$status" =~ ^[0-9]+$ ]]; then
    echo "$status"
  else
    echo "000"
  fi
}

echo "origin: $BASE"
echo "expectations derived from: $DOCS"
echo

# -- 1. the bare /stdlib/ route ----------------------------------------------
echo "1. bare /stdlib/ route"
idx="$WORK/index.html"
status="$(fetch "$BASE/stdlib/" "$idx")"
if [ "$status" != "200" ]; then
  echo "  FAIL  $BASE/stdlib/ -> HTTP $status (expected 200)"
  if [ "$status" = "000" ]; then
    echo "ERROR: the origin did not answer at all — unreachable, not a mismatch." >&2
    exit 2
  fi
  echo
  echo "RESULT: FAIL — the /stdlib/ route serves no index; nothing further can be checked."
  echo "  If a deploy just reported success, re-read [WEB-PREVIEW-SILENT]: it may have"
  echo "  published a PREVIEW. Re-deploy with: bash playground/deploy_cloudflare.sh"
  exit 1
fi
pass "$BASE/stdlib/ -> 200"

# -- 2. it is the GENERATED index, not the synthetic chapter list -------------
echo
echo "2. the served index is the generated library index"
want_entries="$(grep -cE '^- \[' "$DOCS/index.md" || true)"
# Entry links as render_docs.mjs emits them: <li><a href="mod.html#anchor">.
grep -oE '<li><a href="[^":#]+\.html#[^"]*"' "$idx" | sed -E 's/^<li><a href="//; s/"$//' > "$WORK/links.txt" || true
got_entries="$(wc -l < "$WORK/links.txt" | tr -d ' ')"
if [ "$got_entries" = "$want_entries" ]; then
  pass "$got_entries entry links served == $want_entries entries in docs/stdlib/index.md"
else
  fail "entry-link count MISMATCH: origin serves $got_entries, docs/stdlib/index.md has $want_entries"
  if grep -q 'chapter-index' "$idx"; then
    echo "        the served page is the SYNTHETIC chapter list, not index.md's own render"
  fi
fi

# A matching COUNT is not a matching SET — a stale served page can serve the
# right number of links while pointing at the wrong mod#anchor targets (a
# count-preserving rename). Derive the WANT set directly from
# docs/stdlib/index.md's own `- [`name`](mod.md#anchor)` lines and diff it
# against the served set as multisets (sorted comparison; duplicates in
# index.md, e.g. two names sharing one anchor, are expected and must match
# on both sides, not just be deduped away).
grep -E '^- \[' "$DOCS/index.md" | grep -oE '\]\([^)]+\)' \
  | sed -E 's/^\]\(//; s/\)$//; s/\.md#/.html#/' | sort > "$WORK/want_links.txt"
sort "$WORK/links.txt" > "$WORK/got_links.txt"
added=0; missing_links=0
while IFS= read -r l; do
  [ -n "$l" ] || continue
  added=$((added + 1))
  [ "$added" -le "$MAX_REPORT" ] && fail "served link not in docs/stdlib/index.md: $l"
done < <(comm -13 "$WORK/want_links.txt" "$WORK/got_links.txt")
while IFS= read -r l; do
  [ -n "$l" ] || continue
  missing_links=$((missing_links + 1))
  [ "$missing_links" -le "$MAX_REPORT" ] && fail "docs/stdlib/index.md link not served: $l"
done < <(comm -23 "$WORK/want_links.txt" "$WORK/got_links.txt")
[ "$added" -gt "$MAX_REPORT" ] && echo "        ... and $((added - MAX_REPORT)) more added link(s) not listed"
[ "$missing_links" -gt "$MAX_REPORT" ] && echo "        ... and $((missing_links - MAX_REPORT)) more missing link(s) not listed"
if [ "$added" = 0 ] && [ "$missing_links" = 0 ]; then
  pass "served link set == docs/stdlib/index.md link set ($want_entries entries)"
else
  echo "  ----  $added added, $missing_links missing (link-set mismatch, see above)"
fi

# -- 3. the published page set -----------------------------------------------
echo
echo "3. published page set matches docs/stdlib (minus the design notes)"
# The exclusion list is READ OUT of build_stdlib_docs.sh, never restated here —
# a second copy is a second thing to go stale.
exclude="$(sed -n 's/^  --exclude \(.*\) \\$/\1/p' "$SCRIPT_DIR/build_stdlib_docs.sh")"
if [ -z "$exclude" ]; then
  echo "ERROR: could not read the --exclude list out of playground/build_stdlib_docs.sh" >&2
  exit 2
fi
echo "  (excluded by build_stdlib_docs.sh: $exclude)"
missing=0; published_notes=0; npages=0
for md in "$DOCS"/*.md; do
  b="$(basename "$md")"
  case ",$exclude," in
    *",$b,"*)
      st="$(fetch "$BASE/stdlib/${b%.md}.html" /dev/null)"
      if [ "$st" = "200" ]; then
        published_notes=$((published_notes + 1))
        fail "excluded design note ${b%.md}.html IS published (HTTP 200) — it should not be"
      fi
      ;;
    *)
      npages=$((npages + 1))
      st="$(fetch "$BASE/stdlib/${b%.md}.html" /dev/null)"
      if [ "$st" != "200" ]; then
        missing=$((missing + 1))
        [ "$missing" -le "$MAX_REPORT" ] && fail "${b%.md}.html -> HTTP $st (expected 200)"
      fi
      ;;
  esac
done
[ "$missing" = 0 ] && pass "all $npages module page(s) named by docs/stdlib are live"
[ "$missing" -gt "$MAX_REPORT" ] && echo "        ... and $((missing - MAX_REPORT)) more missing page(s) not listed"
[ "$published_notes" = 0 ] && pass "no excluded design note is published"

# -- 4. every entry link resolves: page 200 AND anchor present ----------------
echo
echo "4. every entry link resolves (page status + anchor on the target page)"
# One fetch per DISTINCT target page; the anchor set is then reused for every
# link into it — 905 links across ~28 pages, not 905 requests.
cut -d'#' -f1 "$WORK/links.txt" | sort -u > "$WORK/pages.txt"
mkdir -p "$WORK/ids"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  st="$(fetch "$BASE/stdlib/$p" "$WORK/p.html")"
  if [ "$st" != "200" ]; then
    fail "linked page $p -> HTTP $st"
    : > "$WORK/ids/$p"
    continue
  fi
  # Heading ids are what an anchor can land on: <h2 id="foo">.
  grep -oE '<h[1-6] id="[^"]*"' "$WORK/p.html" | sed -E 's/^.* id="//; s/"$//' | sort -u > "$WORK/ids/$p"
done < "$WORK/pages.txt"

total=0; dead=0
while IFS= read -r link; do
  [ -n "$link" ] || continue
  total=$((total + 1))
  page="${link%%#*}"
  frag="${link#*#}"
  if ! grep -qxF "$frag" "$WORK/ids/$page" 2>/dev/null; then
    dead=$((dead + 1))
    if [ "$dead" -le "$MAX_REPORT" ]; then
      if [ -s "$WORK/ids/$page" ]; then
        fail "dead anchor: /stdlib/$page#$frag — page is live but has no heading id \"$frag\""
      else
        fail "dead link: /stdlib/$page#$frag — target page did not serve (see above)"
      fi
    fi
  fi
done < "$WORK/links.txt"
[ "$dead" -gt "$MAX_REPORT" ] && echo "        ... and $((dead - MAX_REPORT)) more broken link(s) not listed"
npage_targets="$(wc -l < "$WORK/pages.txt" | tr -d ' ')"
if [ "$dead" = 0 ]; then
  pass "0 broken links out of $total entries (across $npage_targets target pages)"
else
  echo "  ----  $dead broken link(s) out of $total entries"
fi

# -- 5. stylesheet + back link -----------------------------------------------
echo
echo "5. stylesheet and back-to-playground link"
css="$(sed -n 's/.*<link rel="stylesheet" href="\([^"]*\)".*/\1/p' "$idx" | head -1)"
css="${css:-guide.css}"
st="$(fetch "$BASE/stdlib/$css" /dev/null)"
if [ "$st" = "200" ]; then pass "stylesheet /stdlib/$css -> 200"; else fail "stylesheet /stdlib/$css -> HTTP $st"; fi

back="$(sed -n 's/.*class="site-nav-back" href="\([^"]*\)".*/\1/p' "$idx" | head -1)"
if [ -z "$back" ]; then
  fail "the served index has no \"<- Playground\" back link"
else
  case "$back" in
    http*) burl="$back" ;;
    /*)    burl="$BASE$back" ;;
    ../*)  burl="$BASE/${back#../}" ;;
    *)     burl="$BASE/stdlib/$back" ;;
  esac
  st="$(fetch "$burl" /dev/null)"
  if [ "$st" = "200" ]; then pass "back link $back -> $burl -> 200"; else fail "back link $back -> $burl -> HTTP $st"; fi
fi

# -- verdict -----------------------------------------------------------------
echo
if [ "$fails" = 0 ]; then
  echo "RESULT: PASS — $BASE/stdlib/ matches docs/stdlib ($total entry links, 0 broken)."
  exit 0
fi
echo "RESULT: FAIL — $fails check(s) failed against $BASE (named above)."
echo "  A deploy that reported success can still have published a PREVIEW"
echo "  ([WEB-PREVIEW-SILENT]); re-deploy with: bash playground/deploy_cloudflare.sh"
exit 1
