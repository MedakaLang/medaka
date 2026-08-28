#!/bin/sh
# Regenerate the P1-C external CAR corpus using the official TypeScript
# atproto repository implementation from the committed exact dependency graph.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/medaka-car-corpus.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
REFERENCE="$ROOT/pds/tools/atproto_reference"

cp "$REFERENCE/package.json" "$REFERENCE/package-lock.json" "$WORK/"
npm ci --ignore-scripts --prefix "$WORK"
[ "$(node -p 'require(process.argv[1]).version' "$WORK/node_modules/@atproto/repo/package.json")" = 0.10.12 ] || {
  echo 'gen_car_corpus: @atproto/repo version mismatch' >&2
  exit 1
}

node "$ROOT/pds/tools/gen_car_corpus.mjs" \
  "$WORK/node_modules" \
  "$ROOT/pds/test/vectors/car_reference_corpus.txt"
