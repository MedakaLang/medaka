#!/bin/sh
# Regenerate the P1-B external MST corpus using the official TypeScript
# reference implementation at one exact npm package version/integrity.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/medaka-mst-corpus.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

PACKAGE='@atproto/repo@0.10.12'
INTEGRITY='sha512-SnDSoFi1bRAfN0IcDjSPFcefknDCIIjKgJXgFsd5jvktCkopmzml8BpQEP5t2/mcZ7NvEn5onQ0kaWkXhgL+5g=='

npm install --ignore-scripts --prefix "$WORK" "$PACKAGE"
observed=$(npm view "$PACKAGE" dist.integrity)
if [ "$observed" != "$INTEGRITY" ]; then
  echo "gen_mst_corpus: npm integrity mismatch" >&2
  echo "expected: $INTEGRITY" >&2
  echo "actual:   $observed" >&2
  exit 1
fi

node "$ROOT/pds/tools/gen_mst_corpus.mjs" \
  "$WORK/node_modules" \
  "$ROOT/pds/test/vectors/mst_reference_corpus.txt"
