#!/bin/sh
# Regenerate the P1-B external MST corpus using the official TypeScript
# reference implementation from the committed exact dependency graph.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/medaka-mst-corpus.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
REFERENCE="$ROOT/pds/tools/atproto_reference"

cp "$REFERENCE/package.json" "$REFERENCE/package-lock.json" "$WORK/"
npm ci --ignore-scripts --prefix "$WORK"
[ "$(node -p 'require(process.argv[1]).version' "$WORK/node_modules/@atproto/repo/package.json")" = 0.10.12 ] || {
  echo 'gen_mst_corpus: @atproto/repo version mismatch' >&2
  exit 1
}

node "$ROOT/pds/tools/gen_mst_corpus.mjs" \
  "$WORK/node_modules" \
  "$ROOT/pds/test/vectors/mst_reference_corpus.txt"
