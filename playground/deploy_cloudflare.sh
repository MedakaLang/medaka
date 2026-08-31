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
if [ ! -f "$SITE/index.html" ] || [ ! -f "$SITE/dist/playground.wasm" ]; then
  echo "[deploy] site/ not built — running build_site.sh ..."
  bash "$SCRIPT_DIR/build_site.sh" >/dev/null
fi

# build_site.sh already verifies every asset main.js fetches; re-assert the
# count here so a hand-edited site/ cannot be published half-populated.
mdk_count=$(find "$SITE/dist" -name '*.mdk' | wc -l | tr -d ' ')
if [ "$mdk_count" -lt 22 ]; then
  echo "FAIL: site/dist has $mdk_count .mdk files, expected >=22. Re-run build_site.sh." >&2
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
