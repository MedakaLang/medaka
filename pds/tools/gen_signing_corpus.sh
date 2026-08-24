#!/bin/sh
# Reproduce the fixed S3-A corpora from two signing implementations, official PDS, and Wycheproof.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
MODE=write
if [ "${1:-}" = "--check" ]; then MODE=check; shift; fi
if [ "${1:-}" = "--oracle-control" ]; then MODE=oracle-control; shift; fi
OUT=${1:-"$ROOT/pds/test/vectors"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-signing.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

LIBSECP_COMMIT=6e2c8bc4ecdc6e71dbe7a368f360d8d453ce435d
LIBSECP_ARCHIVE_SHA=3fe9fd705f4fdf2fe90d6e04b6c1fedd7e8f244a119315886f6468f52c2dfc33
K256_COMMIT=5ac8f5d77f11399ff48d87b0554935f6eddda342
K256_ARCHIVE_SHA=2413c10980e3a2648118953a6468699670d7f03674fe4dcbffa5d3ecc835ec5f
WYCHEPROOF_COMMIT=cff6adf42662469a1871e57303a0ad1d758ed8c0
WYCHEPROOF_SHA=6508e9cc99c169c7d59a6891d939387f115491c479088ddcdcec4d137be69f34
PDS_IMAGE=ghcr.io/bluesky-social/pds@sha256:d95725b24dbe53af9d91dc69750556931ebed6c396f2cfa42b221434db642f12
PDS_REVISION=374cf1d4ba782d4391bbb73e4e2d3f320d4846d6

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
  else shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}
fetch() { curl --fail --location --silent --show-error "$1" -o "$2"; }
check_digest() {
  [ "$(sha256_file "$1")" = "$2" ] || {
    echo "gen_signing_corpus: digest mismatch for $1" >&2
    exit 1
  }
}
check_tag() {
  git ls-remote "$1" "$2" "$2^{}" | cut -f 1 | grep -q "^$3$" || {
    echo "gen_signing_corpus: tag/commit mismatch for $2" >&2
    exit 1
  }
}

record_oracle_completion() {
  label=$1 output=$2 receipt=$3
  [ -s "$output" ] || {
    echo "gen_signing_corpus: $label produced no fresh output" >&2
    exit 1
  }
  printf '%s %s\n' "$label" "$(sha256_file "$output")" >> "$receipt"
}

compare_oracle_outputs() {
  left=$1 right=$2 receipt=$3
  cmp "$left" "$right" || {
    diff -u "$left" "$right" >&2
    exit 1
  }
  left_hash=$(sha256_file "$left")
  right_hash=$(sha256_file "$right")
  [ "$left_hash" = "$right_hash" ] || {
    echo "gen_signing_corpus: compared oracle hashes differ" >&2
    exit 1
  }
  printf 'compared %s\n' "$left_hash" >> "$receipt"
}

require_oracle_completion() {
  receipt=$1
  [ "$(wc -l < "$receipt" | tr -d ' ')" -eq 3 ] || {
    echo "gen_signing_corpus: oracle completion receipt is incomplete" >&2
    exit 1
  }
  libsecp_hash=$(sed -n '1s/^libsecp256k1 //p' "$receipt")
  k256_hash=$(sed -n '2s/^k256 //p' "$receipt")
  compared_hash=$(sed -n '3s/^compared //p' "$receipt")
  [ -n "$libsecp_hash" ] && [ "$libsecp_hash" = "$k256_hash" ] && [ "$libsecp_hash" = "$compared_hash" ] || {
    echo "gen_signing_corpus: oracle run/compare completion evidence disagrees" >&2
    exit 1
  }
}

oracle_control_proof() {
  receipt="$WORK/oracle-control.receipt"
  libsecp_output="$WORK/oracle-control-libsecp.out"
  k256_output="$WORK/oracle-control-k256.out"
  rm -f "$receipt" "$libsecp_output" "$k256_output"
  sh -c 'printf "%s\n" fresh-independent-oracle-output' > "$libsecp_output"
  record_oracle_completion libsecp256k1 "$libsecp_output" "$receipt"
  sh -c 'printf "%s\n" fresh-independent-oracle-output' > "$k256_output"
  record_oracle_completion k256 "$k256_output" "$receipt"
  compare_oracle_outputs "$libsecp_output" "$k256_output" "$receipt"
  require_oracle_completion "$receipt"
  cat "$receipt"
}

if [ "$MODE" = oracle-control ]; then
  oracle_control_proof
  exit 0
fi

check_tag https://github.com/bitcoin-core/secp256k1 refs/tags/v0.8.0 "$LIBSECP_COMMIT"
check_tag https://github.com/RustCrypto/elliptic-curves refs/tags/k256/v0.13.4 "$K256_COMMIT"
check_tag https://github.com/C2SP/wycheproof refs/tags/google-wycheproof/v0.9 "$WYCHEPROOF_COMMIT"

fetch "https://github.com/bitcoin-core/secp256k1/archive/$LIBSECP_COMMIT.tar.gz" "$WORK/libsecp.tar.gz"
fetch "https://github.com/RustCrypto/elliptic-curves/archive/$K256_COMMIT.tar.gz" "$WORK/k256.tar.gz"
fetch "https://raw.githubusercontent.com/C2SP/wycheproof/$WYCHEPROOF_COMMIT/testvectors_v1/ecdsa_secp256k1_sha256_p1363_test.json" "$WORK/wycheproof.json"
check_digest "$WORK/libsecp.tar.gz" "$LIBSECP_ARCHIVE_SHA"
check_digest "$WORK/k256.tar.gz" "$K256_ARCHIVE_SHA"
check_digest "$WORK/wycheproof.json" "$WYCHEPROOF_SHA"

mkdir "$WORK/libsecp" "$WORK/k256" "$WORK/rust"
tar -xzf "$WORK/libsecp.tar.gz" -C "$WORK/libsecp" --strip-components=1
tar -xzf "$WORK/k256.tar.gz" -C "$WORK/k256" --strip-components=1
python3 "$HERE/instrument_libsecp_signing.py" "$WORK/libsecp/src/ecdsa_impl.h"

ORACLE_RECEIPT="$WORK/oracle-completion.receipt"
rm -f "$ORACLE_RECEIPT" "$WORK/libsecp.out" "$WORK/k256.out"

cc -O2 -DUSE_FORCE_WIDEMUL_INT64=1 -I"$WORK/libsecp" \
  -o "$WORK/libsecp-sign" "$HERE/signing_corpus_libsecp.c" \
  "$WORK/libsecp/src/precomputed_ecmult.c" "$WORK/libsecp/src/precomputed_ecmult_gen.c"
# ORACLE_EXECUTION: libsecp256k1
"$WORK/libsecp-sign" "$HERE/signing_inputs.txt" > "$WORK/libsecp.out"
record_oracle_completion libsecp256k1 "$WORK/libsecp.out" "$ORACLE_RECEIPT"

cp "$HERE/signing_k256/Cargo.toml" "$HERE/signing_k256/Cargo.lock" "$WORK/rust/"
cp -R "$HERE/signing_k256/src" "$WORK/rust/src"
mkdir "$WORK/rust/.cargo"
printf '[patch.crates-io]\nk256 = { path = "%s/k256" }\n' "$WORK/k256" > "$WORK/rust/.cargo/config.toml"
# ORACLE_EXECUTION: k256 + locked rfc6979 0.4.0
cargo run --quiet --locked --manifest-path "$WORK/rust/Cargo.toml" -- "$HERE/signing_inputs.txt" > "$WORK/k256.out"
record_oracle_completion k256 "$WORK/k256.out" "$ORACLE_RECEIPT"
compare_oracle_outputs "$WORK/libsecp.out" "$WORK/k256.out" "$ORACLE_RECEIPT"
require_oracle_completion "$ORACLE_RECEIPT"

[ "$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$PDS_IMAGE")" = "$PDS_REVISION" ] || {
  echo "gen_signing_corpus: official PDS service revision drifted" >&2
  exit 1
}
docker run --rm --entrypoint node \
  -v "$HERE:/medaka-tools:ro" "$PDS_IMAGE" \
  /medaka-tools/extract_pds_signatures.mjs /medaka-tools/signing_inputs.txt > "$WORK/pds.out"

python3 "$HERE/assemble_signing_corpora.py" \
  "$WORK/libsecp.out" "$WORK/pds.out" \
  "$WORK/prehashed_signing_corpus.txt" "$WORK/pds_message_signing_corpus.txt"
python3 "$HERE/normalize_wycheproof_signing.py" \
  "$WORK/wycheproof.json" "$WORK/wycheproof_secp256k1_sha256_p1363.txt"

if [ "$MODE" = check ]; then
  cmp "$WORK/prehashed_signing_corpus.txt" "$OUT/prehashed_signing_corpus.txt"
  cmp "$WORK/pds_message_signing_corpus.txt" "$OUT/pds_message_signing_corpus.txt"
  cmp "$WORK/wycheproof_secp256k1_sha256_p1363.txt" "$OUT/wycheproof_secp256k1_sha256_p1363.txt"
  echo "gen_signing_corpus: CHECK PASS — 80 prehashed, 16 PDS-message, 242 Wycheproof"
else
  mkdir -p "$OUT"
  cp "$WORK/prehashed_signing_corpus.txt" "$OUT/prehashed_signing_corpus.txt"
  cp "$WORK/pds_message_signing_corpus.txt" "$OUT/pds_message_signing_corpus.txt"
  cp "$WORK/wycheproof_secp256k1_sha256_p1363.txt" "$OUT/wycheproof_secp256k1_sha256_p1363.txt"
  echo "gen_signing_corpus: wrote 80 prehashed, 16 PDS-message, 242 Wycheproof rows"
fi
