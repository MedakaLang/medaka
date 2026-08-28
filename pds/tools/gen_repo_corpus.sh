#!/bin/sh
# Regenerate P1-D with the exact official repository and crypto packages.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/medaka-repo-corpus.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

REPO_PACKAGE='@atproto/repo@0.10.12'
REPO_INTEGRITY='sha512-SnDSoFi1bRAfN0IcDjSPFcefknDCIIjKgJXgFsd5jvktCkopmzml8BpQEP5t2/mcZ7NvEn5onQ0kaWkXhgL+5g=='
CRYPTO_PACKAGE='@atproto/crypto@0.5.4'
CRYPTO_INTEGRITY='sha512-UR0BkuYNYuFtw+dA+y/oPPxzX0SWRnGJ+1Cfh/jGP1BvjRUyezK3omjpeLms5fYrXbM9vnfX+ckJFJqkBgLOdw=='

npm install --ignore-scripts --prefix "$WORK" "$REPO_PACKAGE" "$CRYPTO_PACKAGE"
[ "$(npm view "$REPO_PACKAGE" dist.integrity)" = "$REPO_INTEGRITY" ] || {
  echo 'gen_repo_corpus: @atproto/repo integrity mismatch' >&2
  exit 1
}
[ "$(npm view "$CRYPTO_PACKAGE" dist.integrity)" = "$CRYPTO_INTEGRITY" ] || {
  echo 'gen_repo_corpus: @atproto/crypto integrity mismatch' >&2
  exit 1
}

node "$ROOT/pds/tools/gen_repo_corpus.mjs" \
  "$WORK/node_modules" \
  "$ROOT/pds/test/vectors/repo_reference_corpus.txt"
