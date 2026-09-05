#!/bin/sh
# Regenerate P1-D with the exact official repository and crypto packages.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/medaka-repo-corpus.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
REFERENCE="$ROOT/pds/tools/atproto_reference"

cp "$REFERENCE/package.json" "$REFERENCE/package-lock.json" "$WORK/"
npm ci --ignore-scripts --prefix "$WORK"
[ "$(node -p 'require(process.argv[1]).version' "$WORK/node_modules/@atproto/repo/package.json")" = 0.10.12 ] || {
  echo 'gen_repo_corpus: @atproto/repo version mismatch' >&2
  exit 1
}
[ "$(node -p 'require(process.argv[1]).version' "$WORK/node_modules/@atproto/crypto/package.json")" = 0.5.4 ] || {
  echo 'gen_repo_corpus: @atproto/crypto version mismatch' >&2
  exit 1
}

node "$ROOT/pds/tools/gen_repo_corpus.mjs" \
  "$WORK/node_modules" \
  "$ROOT/pds/test/vectors/repo_reference_corpus.txt" \
  "$ROOT/pds/test/vectors/repo_batch_reference_corpus.txt"
