#!/bin/sh
# Reproduce the secp256k1 did:key corpus from the pinned official PDS image.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
MODE=write
if [ "${1:-}" = "--check" ]; then MODE=check; shift; fi
OUT=${1:-"$ROOT/pds/test/vectors"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-did-key.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

PDS_IMAGE=ghcr.io/bluesky-social/pds@sha256:d95725b24dbe53af9d91dc69750556931ebed6c396f2cfa42b221434db642f12
PDS_REVISION=374cf1d4ba782d4391bbb73e4e2d3f320d4846d6
PDS_CRYPTO_PACKAGE=@atproto/crypto@0.5.4

actual_revision=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$PDS_IMAGE")
[ "$actual_revision" = "$PDS_REVISION" ] || {
  echo "gen_did_key_corpus: official PDS service revision drifted" >&2
  exit 1
}

docker run --rm --entrypoint node \
  -v "$HERE:/medaka-tools:ro" "$PDS_IMAGE" \
  /medaka-tools/extract_pds_did_keys.mjs /medaka-tools/signing_inputs.txt \
  > "$WORK/pds_did_key_corpus.txt"

python3 "$HERE/did_key_corpus_check.py" "$ROOT" \
  --corpus "$WORK/pds_did_key_corpus.txt"

if [ "$MODE" = check ]; then
  cmp "$WORK/pds_did_key_corpus.txt" "$OUT/pds_did_key_corpus.txt"
  action='CHECK PASS'
else
  mkdir -p "$OUT"
  cp "$WORK/pds_did_key_corpus.txt" "$OUT/pds_did_key_corpus.txt"
  action=wrote
fi

echo "gen_did_key_corpus: $action — 16 rows; image=$PDS_IMAGE revision=$PDS_REVISION package=$PDS_CRYPTO_PACKAGE route=Secp256k1Keypair.did()"
