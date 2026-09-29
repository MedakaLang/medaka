#!/bin/sh
# Reproduce the Lexicon record-validation answer key (schemas + verdict rows)
# from the pinned official PDS image, over the committed inputs in
# pds/test/vectors/lexicon_cases.jsonl.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
MODE=write
if [ "${1:-}" = "--check" ]; then MODE=check; shift; fi
OUT=${1:-"$ROOT/pds/test/vectors"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-lexicon.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

PDS_DIGEST=sha256:d95725b24dbe53af9d91dc69750556931ebed6c396f2cfa42b221434db642f12
PDS_IMAGE=ghcr.io/bluesky-social/pds@$PDS_DIGEST
PDS_REVISION=374cf1d4ba782d4391bbb73e4e2d3f320d4846d6

actual_revision=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$PDS_IMAGE")
[ "$actual_revision" = "$PDS_REVISION" ] || {
  echo "gen_lexicon_corpus: official PDS service revision drifted" >&2
  exit 1
}

docker run --rm --entrypoint node \
  -e PDS_IMAGE_DIGEST="$PDS_DIGEST" \
  -v "$HERE:/medaka-tools:ro" \
  -v "$OUT:/medaka-vectors:ro" \
  -v "$WORK:/medaka-out" \
  "$PDS_IMAGE" \
  /medaka-tools/gen_lexicon_corpus.mjs /medaka-vectors /medaka-out

if [ "$MODE" = check ]; then
  cmp "$WORK/lexicon_schemas.json" "$OUT/lexicon_schemas.json"
  cmp "$WORK/lexicon_record_corpus.jsonl" "$OUT/lexicon_record_corpus.jsonl"
  cmp "$WORK/lexicon_corpus.meta" "$OUT/lexicon_corpus.meta"
  action='CHECK PASS'
else
  cp "$WORK/lexicon_schemas.json" "$OUT/lexicon_schemas.json"
  cp "$WORK/lexicon_record_corpus.jsonl" "$OUT/lexicon_record_corpus.jsonl"
  cp "$WORK/lexicon_corpus.meta" "$OUT/lexicon_corpus.meta"
  action=wrote
fi

echo "gen_lexicon_corpus: $action — image=$PDS_IMAGE revision=$PDS_REVISION"
