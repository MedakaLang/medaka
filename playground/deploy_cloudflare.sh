#!/usr/bin/env bash
# deploy_cloudflare.sh — publish playground/site/ to Cloudflare Pages.
#
# Credentials are read from a file OUTSIDE the repo so the token never lands in
# git, in a command line (where `ps` could see it), or in a transcript:
#
#   read -rsp 'token: ' T && printf 'CLOUDFLARE_API_TOKEN=%s\n' "$T" > ~/.cf-medaka.env && unset T
#   echo 'CLOUDFLARE_ACCOUNT_ID=<account id>' >> ~/.cf-medaka.env
#   chmod 600 ~/.cf-medaka.env
#
# Usage:
#   bash playground/deploy_cloudflare.sh            # deploy
#   bash playground/deploy_cloudflare.sh --create   # create the project first
#
# The token needs exactly one permission: Account · Cloudflare Pages · Edit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SITE="$SCRIPT_DIR/site"
ENV_FILE="${CF_ENV_FILE:-$HOME/.cf-medaka.env}"
PROJECT="${CF_PAGES_PROJECT:-medaka}"

[ -f "$ENV_FILE" ] || { echo "FAIL: no credentials at $ENV_FILE (see header)" >&2; exit 1; }

# Refuse a world-readable secret rather than quietly using it.
perms=$(stat -c %a "$ENV_FILE" 2>/dev/null || stat -f %Lp "$ENV_FILE")
case "$perms" in
  600|400) ;;
  *) echo "FAIL: $ENV_FILE is mode $perms; run: chmod 600 $ENV_FILE" >&2; exit 1 ;;
esac

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${CLOUDFLARE_API_TOKEN:?missing CLOUDFLARE_API_TOKEN in $ENV_FILE}"
: "${CLOUDFLARE_ACCOUNT_ID:?missing CLOUDFLARE_ACCOUNT_ID in $ENV_FILE}"

# Never let the token reach stdout/stderr, even on a wrangler crash.
redact() { sed -e "s/${CLOUDFLARE_API_TOKEN}/***REDACTED***/g"; }

# ── The site must be built, and complete ────────────────────────────────────
# `site/guide` and `site/stdlib` join the trigger deliberately: a site/
# assembled before either was wired in (#2386 guide / #2384 stdlib) has
# index.html and playground.wasm and would otherwise have sailed straight past
# this into a deploy missing one of them — and with playground/index.html's
# nav links to it 404ing.
if [ ! -f "$SITE/index.html" ] || [ ! -f "$SITE/dist/playground.wasm" ] || [ ! -d "$SITE/guide" ] || [ ! -d "$SITE/stdlib" ]; then
  echo "[deploy] site/ not built — running build_site.sh ..."
  bash "$SCRIPT_DIR/build_site.sh" >/dev/null
fi

# build_site.sh already verifies every asset main.js fetches; re-assert the
# count here so a hand-edited site/ cannot be published half-populated. DERIVED
# from main.js's own EXTRA_MODULES list rather than a hand-picked number: that
# list moves independently of this script, and a hardcoded floor silently goes
# stale (and falsely FAILS a correctly-built site/) the moment it does — a
# hardcoded `22` here went stale the moment EXTRA_MODULES' own count last
# moved (e.g. the mut_array->vector rename) and silently blocked every deploy
# with a FAIL that had nothing to do with a half-populated site.
mdk_expected=$(( 2 + $(sed -n '/^const EXTRA_MODULES = \[/,/\];/p' "$SCRIPT_DIR/main.js" \
                    | grep -o "'[a-z_0-9]*'" | tr -d "'" | wc -l | tr -d ' ') ))
mdk_count=$(find "$SITE/dist" -name '*.mdk' | wc -l | tr -d ' ')
if [ "$mdk_count" -lt "$mdk_expected" ]; then
  echo "FAIL: site/dist has $mdk_count .mdk files, expected >=$mdk_expected (runtime.mdk + core.mdk + main.js's EXTRA_MODULES). Re-run build_site.sh." >&2
  exit 1
fi

# Same re-assert for the guide, also DERIVED rather than hand-typed: the
# guide's page count is exactly "docs/guide/*.md minus OUTLINE.md", which is
# knowable here. A chapter added to the repo and missing from site/ is a stale
# build, not a smaller guide.
guide_expected=$(find "$ROOT/docs/guide" -maxdepth 1 -name '*.md' ! -name 'OUTLINE.md' | wc -l | tr -d ' ')
guide_count=$(find "$SITE/guide" -maxdepth 1 -name '*.html' | wc -l | tr -d ' ')
if [ "$guide_count" -lt "$guide_expected" ]; then
  echo "FAIL: site/guide has $guide_count pages, docs/guide names $guide_expected. Re-run build_site.sh." >&2
  exit 1
fi

# Same re-assert, same reason, for the stdlib reference (#2384). Expected count
# is DERIVED from docs/stdlib/*.md minus build_stdlib_docs.sh's own --exclude
# list, read back out of that script rather than restated here — one copy of
# the exclusion set, the same discipline playground/verify_stdlib_deploy.sh
# and build_site.sh's own stdlib check already use.
stdlib_exclude="$(sed -n 's/^  --exclude \(.*\) \\$/\1/p' "$SCRIPT_DIR/build_stdlib_docs.sh")"
if [ -z "$stdlib_exclude" ]; then
  echo "FAIL: could not read the --exclude list out of playground/build_stdlib_docs.sh" >&2
  exit 1
fi
stdlib_expected=0
for m in "$ROOT"/docs/stdlib/*.md; do
  b="$(basename "$m")"
  case ",$stdlib_exclude," in
    *",$b,"*) ;;
    *) stdlib_expected=$((stdlib_expected + 1)) ;;
  esac
done
stdlib_count=$(find "$SITE/stdlib" -maxdepth 1 -name '*.html' | wc -l | tr -d ' ')
if [ "$stdlib_count" -lt "$stdlib_expected" ]; then
  echo "FAIL: site/stdlib has $stdlib_count pages, docs/stdlib names $stdlib_expected (minus $stdlib_exclude). Re-run build_site.sh." >&2
  exit 1
fi

echo "[deploy] publishing $SITE ($(du -sh "$SITE" | cut -f1)) to Pages project '$PROJECT'"

if [ "${1:-}" = "--create" ]; then
  npx --yes wrangler pages project create "$PROJECT" \
      --production-branch main 2>&1 | redact
fi

# --branch is explicit and defaults to the production branch. Without it wrangler
# infers the branch from git, so deploying from a topic branch silently publishes
# a PREVIEW: the deploy "succeeds", prints a url, and the production origin keeps
# serving 404. Pass CF_PAGES_BRANCH=<name> to publish a preview on purpose.
npx --yes wrangler pages deploy "$SITE" \
    --project-name "$PROJECT" \
    --branch "${CF_PAGES_BRANCH:-main}" \
    --commit-dirty=true 2>&1 | redact
