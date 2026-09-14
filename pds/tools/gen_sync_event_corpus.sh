#!/bin/sh
# Reproduce the #identity/#account/#sync event bodies and sync.getRecord/
# sync.getBlocks CAR-shape corpora from the pinned official PDS image.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
MODE=write
if [ "${1:-}" = "--check" ]; then MODE=check; shift; fi
OUT=${1:-"$ROOT/pds/test/vectors"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-sync-event.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

PDS_IMAGE=ghcr.io/bluesky-social/pds@sha256:d95725b24dbe53af9d91dc69750556931ebed6c396f2cfa42b221434db642f12
PDS_REVISION=374cf1d4ba782d4391bbb73e4e2d3f320d4846d6

actual_revision=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$PDS_IMAGE")
[ "$actual_revision" = "$PDS_REVISION" ] || {
  echo "gen_sync_event_corpus: official PDS service revision drifted" >&2
  exit 1
}

# The mjs writes to its own argument path -- give it a separate writable
# mount (the tools dir itself stays read-only).
docker run --rm --entrypoint node \
  -v "$HERE:/medaka-tools:ro" \
  -v "$WORK:/medaka-out" \
  "$PDS_IMAGE" \
  /medaka-tools/gen_sync_event_corpus.mjs /medaka-out

if [ "$MODE" = check ]; then
  cmp "$WORK/pds_sync_event_bodies_corpus.txt" "$OUT/pds_sync_event_bodies_corpus.txt"
  cmp "$WORK/pds_sync_car_shapes_corpus.txt" "$OUT/pds_sync_car_shapes_corpus.txt"
  action='CHECK PASS'
else
  mkdir -p "$OUT"
  cp "$WORK/pds_sync_event_bodies_corpus.txt" "$OUT/pds_sync_event_bodies_corpus.txt"
  cp "$WORK/pds_sync_car_shapes_corpus.txt" "$OUT/pds_sync_car_shapes_corpus.txt"
  action=wrote
fi

echo "gen_sync_event_corpus: $action — image=$PDS_IMAGE revision=$PDS_REVISION"
