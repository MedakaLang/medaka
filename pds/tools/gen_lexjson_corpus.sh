#!/bin/sh
# Regenerate the P4-B lexicon-JSON<->DAG-CBOR corpus using the official
# TypeScript @atproto/lex-cbor + @atproto/lex-json + @atproto/lex-data
# reference implementations from the committed exact dependency graph.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/medaka-lexjson-corpus.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
REFERENCE="$ROOT/pds/tools/atproto_reference"

cp "$REFERENCE/package.json" "$REFERENCE/package-lock.json" "$WORK/"
npm ci --ignore-scripts --prefix "$WORK"
[ "$(node -p 'require(process.argv[1]).version' "$WORK/node_modules/@atproto/lex-json/package.json")" = 0.1.6 ] || {
  echo 'gen_lexjson_corpus: @atproto/lex-json version mismatch' >&2
  exit 1
}
[ "$(node -p 'require(process.argv[1]).version' "$WORK/node_modules/@atproto/lex-data/package.json")" = 0.1.7 ] || {
  echo 'gen_lexjson_corpus: @atproto/lex-data version mismatch' >&2
  exit 1
}
[ "$(node -p 'require(process.argv[1]).version' "$WORK/node_modules/@atproto/lex-cbor/package.json")" = 0.1.6 ] || {
  echo 'gen_lexjson_corpus: @atproto/lex-cbor version mismatch' >&2
  exit 1
}

node "$ROOT/pds/tools/gen_lexjson_corpus.mjs" \
  "$WORK/node_modules" \
  "$ROOT/pds/test/vectors/lexjson_reference_corpus.txt"
