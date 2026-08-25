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
LIBSECP_CONTROL_RUNNER_EXPECTED_SHA=28e2b0e12360e48226c4f4751cee04de517de3899d58cdafca850b465605220d
K256_CONTROL_RUNNER_EXPECTED_SHA=ac4622acf3549cb1b2bbaead2edcc98ef7a79b66cab1469ddfa65fedf846f308
CONTROL_CARGO_EXPECTED_SHA=9b00184f675120eb89bfeb637b10f140c3611b96b03ddbb708d9629dcf381c9f
K256_WRAPPER_EXPECTED_SHA=d6688538deb92f1818904a6cc1b937a8fb167ecd80623263f029b7613e5b3554

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
  else shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}
sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d ' ' -f 1
  else printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1
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

resolved_runner_path() {
  runner=$1
  runner_dir=$(CDPATH= cd -- "$(dirname -- "$runner")" && pwd -P)
  printf '%s/%s\n' "$runner_dir" "$(basename -- "$runner")"
}

canonical_executable_path() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

absolute_executable_path() {
  python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$1"
}

resolve_command_executable() {
  command_path=$(command -v "$1") || {
    echo "gen_signing_corpus: required executable not found: $1" >&2
    exit 1
  }
  absolute_executable_path "$command_path"
}

runner_file_identity() {
  if identity=$(stat -Lc '%d:%i' "$1" 2>/dev/null); then printf '%s\n' "$identity"
  elif identity=$(stat -Lf '%d:%i' "$1" 2>/dev/null); then printf '%s\n' "$identity"
  else printf '%s\n' unavailable
  fi
}

capture_cargo_identity() {
  CARGO_EXECUTABLE=$(absolute_executable_path "$1")
  [ -x "$CARGO_EXECUTABLE" ] || {
    echo "gen_signing_corpus: resolved cargo executable is not executable" >&2
    exit 1
  }
  # Invoke the absolute command path so argv[0]-dispatching tools such as
  # rustup's cargo symlink retain cargo semantics; attest its canonical target.
  CARGO_EXPECTED_PATH=$(canonical_executable_path "$CARGO_EXECUTABLE")
  CARGO_EXPECTED_FILE_ID=$(runner_file_identity "$CARGO_EXECUTABLE")
  CARGO_EXPECTED_CONTENT_SHA=$(sha256_file "$CARGO_EXECUTABLE")
}

attest_oracle_runners() {
  libsecp_runner=$1 k256_runner=$2
  libsecp_expected_sha=$3 k256_expected_sha=$4
  cargo_executable=$5 cargo_expected_path=$6 cargo_expected_file_id=$7
  cargo_expected_content_sha=$8 receipt=$9
  [ -x "$libsecp_runner" ] && [ -x "$k256_runner" ] || {
    echo "gen_signing_corpus: oracle runner is not executable" >&2
    exit 1
  }
  libsecp_path=$(resolved_runner_path "$libsecp_runner")
  k256_path=$(resolved_runner_path "$k256_runner")
  [ "$libsecp_path" != "$k256_path" ] || {
    echo "gen_signing_corpus: oracle runners resolve to the same path" >&2
    exit 1
  }
  LIBSECP_RUNNER_PATH_SHA=$(sha256_text "$libsecp_path")
  K256_RUNNER_PATH_SHA=$(sha256_text "$k256_path")
  LIBSECP_RUNNER_FILE_ID=$(runner_file_identity "$libsecp_runner")
  K256_RUNNER_FILE_ID=$(runner_file_identity "$k256_runner")
  if [ "$LIBSECP_RUNNER_FILE_ID" != unavailable ] && [ "$K256_RUNNER_FILE_ID" != unavailable ]; then
    [ "$LIBSECP_RUNNER_FILE_ID" != "$K256_RUNNER_FILE_ID" ] || {
      echo "gen_signing_corpus: oracle runners have the same file identity" >&2
      exit 1
    }
  fi
  LIBSECP_RUNNER_CONTENT_SHA=$(sha256_file "$libsecp_runner")
  K256_RUNNER_CONTENT_SHA=$(sha256_file "$k256_runner")
  [ "$LIBSECP_RUNNER_CONTENT_SHA" = "$libsecp_expected_sha" ] || {
    echo "gen_signing_corpus: libsecp runner content differs from its expected implementation" >&2
    exit 1
  }
  [ "$K256_RUNNER_CONTENT_SHA" = "$k256_expected_sha" ] || {
    echo "gen_signing_corpus: k256 runner content differs from its expected implementation" >&2
    exit 1
  }
  [ "$LIBSECP_RUNNER_CONTENT_SHA" != "$K256_RUNNER_CONTENT_SHA" ] || {
    echo "gen_signing_corpus: oracle runners have identical content" >&2
    exit 1
  }
  CARGO_EXECUTABLE=$(absolute_executable_path "$cargo_executable")
  CARGO_CANONICAL_PATH=$(canonical_executable_path "$CARGO_EXECUTABLE")
  [ "$CARGO_CANONICAL_PATH" = "$cargo_expected_path" ] || {
    echo "gen_signing_corpus: cargo executable canonical path drifted" >&2
    exit 1
  }
  CARGO_PATH_SHA=$(sha256_text "$CARGO_CANONICAL_PATH")
  CARGO_FILE_ID=$(runner_file_identity "$CARGO_EXECUTABLE")
  CARGO_CONTENT_SHA=$(sha256_file "$CARGO_EXECUTABLE")
  [ "$CARGO_FILE_ID" = "$cargo_expected_file_id" ] && \
    [ "$CARGO_CONTENT_SHA" = "$cargo_expected_content_sha" ] || {
    echo "gen_signing_corpus: cargo executable identity/content drifted" >&2
    exit 1
  }
  LIBSECP_RUNNER_EXPECTED_SHA=$libsecp_expected_sha
  K256_RUNNER_EXPECTED_SHA=$k256_expected_sha
  printf 'runner libsecp256k1 %s %s %s %s\n' \
    "$LIBSECP_RUNNER_PATH_SHA" "$LIBSECP_RUNNER_FILE_ID" \
    "$LIBSECP_RUNNER_EXPECTED_SHA" "$LIBSECP_RUNNER_CONTENT_SHA" >> "$receipt"
  printf 'runner k256 %s %s %s %s\n' \
    "$K256_RUNNER_PATH_SHA" "$K256_RUNNER_FILE_ID" \
    "$K256_RUNNER_EXPECTED_SHA" "$K256_RUNNER_CONTENT_SHA" >> "$receipt"
  printf 'cargo k256 %s %s %s\n' \
    "$CARGO_PATH_SHA" "$CARGO_FILE_ID" "$CARGO_CONTENT_SHA" >> "$receipt"
}

record_oracle_completion() {
  label=$1 runner_path_sha=$2 runner_file_id=$3 runner_expected_sha=$4
  runner_content_sha=$5 cargo_path_sha=$6 cargo_file_id=$7 cargo_content_sha=$8
  output=$9 receipt=${10}
  [ -s "$output" ] || {
    echo "gen_signing_corpus: $label produced no fresh output" >&2
    exit 1
  }
  printf 'output %s %s %s %s %s %s %s %s %s\n' \
    "$label" "$runner_path_sha" "$runner_file_id" "$runner_expected_sha" "$runner_content_sha" \
    "$cargo_path_sha" "$cargo_file_id" "$cargo_content_sha" \
    "$(sha256_file "$output")" >> "$receipt"
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
  [ "$(wc -l < "$receipt" | tr -d ' ')" -eq 6 ] || {
    echo "gen_signing_corpus: oracle completion receipt is incomplete" >&2
    exit 1
  }
  libsecp_runner_line=$(sed -n '1p' "$receipt")
  k256_runner_line=$(sed -n '2p' "$receipt")
  expected_libsecp_runner_line="runner libsecp256k1 $LIBSECP_RUNNER_PATH_SHA $LIBSECP_RUNNER_FILE_ID $LIBSECP_RUNNER_EXPECTED_SHA $LIBSECP_RUNNER_CONTENT_SHA"
  expected_k256_runner_line="runner k256 $K256_RUNNER_PATH_SHA $K256_RUNNER_FILE_ID $K256_RUNNER_EXPECTED_SHA $K256_RUNNER_CONTENT_SHA"
  [ "$libsecp_runner_line" = "$expected_libsecp_runner_line" ] && \
    [ "$k256_runner_line" = "$expected_k256_runner_line" ] || {
    echo "gen_signing_corpus: oracle runner identity receipt disagrees" >&2
    exit 1
  }
  cargo_line=$(sed -n '3p' "$receipt")
  expected_cargo_line="cargo k256 $CARGO_PATH_SHA $CARGO_FILE_ID $CARGO_CONTENT_SHA"
  [ "$cargo_line" = "$expected_cargo_line" ] || {
    echo "gen_signing_corpus: cargo executable receipt disagrees" >&2
    exit 1
  }
  libsecp_hash=$(sed -n "4s/^output libsecp256k1 $LIBSECP_RUNNER_PATH_SHA $LIBSECP_RUNNER_FILE_ID $LIBSECP_RUNNER_EXPECTED_SHA $LIBSECP_RUNNER_CONTENT_SHA direct direct direct //p" "$receipt")
  k256_hash=$(sed -n "5s/^output k256 $K256_RUNNER_PATH_SHA $K256_RUNNER_FILE_ID $K256_RUNNER_EXPECTED_SHA $K256_RUNNER_CONTENT_SHA $CARGO_PATH_SHA $CARGO_FILE_ID $CARGO_CONTENT_SHA //p" "$receipt")
  compared_hash=$(sed -n '6s/^compared //p' "$receipt")
  [ -n "$libsecp_hash" ] && [ "$libsecp_hash" = "$k256_hash" ] && \
    [ "$libsecp_hash" = "$compared_hash" ] || {
    echo "gen_signing_corpus: oracle run/compare completion evidence disagrees" >&2
    exit 1
  }
}

run_oracle_pair() {
  libsecp_runner=$1 k256_runner=$2
  libsecp_expected_sha=$3 k256_expected_sha=$4 cargo_executable=$5
  cargo_expected_path=$6 cargo_expected_file_id=$7 cargo_expected_content_sha=$8
  input=$9 libsecp_output=${10} k256_output=${11} receipt=${12}
  rm -f "$receipt" "$libsecp_output" "$k256_output"
  [ ! -e "$receipt" ] && [ ! -e "$libsecp_output" ] && [ ! -e "$k256_output" ] || {
    echo "gen_signing_corpus: oracle output cleanup did not establish freshness" >&2
    exit 1
  }
  attest_oracle_runners \
    "$libsecp_runner" "$k256_runner" "$libsecp_expected_sha" "$k256_expected_sha" \
    "$cargo_executable" "$cargo_expected_path" "$cargo_expected_file_id" \
    "$cargo_expected_content_sha" "$receipt"
  ORACLE_WORK="$WORK" "$libsecp_runner" "$input" > "$libsecp_output"
  record_oracle_completion libsecp256k1 \
    "$LIBSECP_RUNNER_PATH_SHA" "$LIBSECP_RUNNER_FILE_ID" \
    "$LIBSECP_RUNNER_EXPECTED_SHA" "$LIBSECP_RUNNER_CONTENT_SHA" \
    direct direct direct \
    "$libsecp_output" "$receipt"
  ORACLE_CARGO="$CARGO_EXECUTABLE" ORACLE_WORK="$WORK" "$k256_runner" "$input" > "$k256_output"
  record_oracle_completion k256 \
    "$K256_RUNNER_PATH_SHA" "$K256_RUNNER_FILE_ID" \
    "$K256_RUNNER_EXPECTED_SHA" "$K256_RUNNER_CONTENT_SHA" \
    "$CARGO_PATH_SHA" "$CARGO_FILE_ID" "$CARGO_CONTENT_SHA" \
    "$k256_output" "$receipt"
  compare_oracle_outputs "$libsecp_output" "$k256_output" "$receipt"
  require_oracle_completion "$receipt"
}

if [ "$MODE" = oracle-control ]; then
  cat > "$WORK/libsecp-control-runner" <<'EOF'
#!/bin/sh
printf '%s\n' fresh-independent-oracle-output
EOF
  cat > "$WORK/k256-control-runner" <<'EOF'
#!/bin/sh
exec "$ORACLE_CARGO" "$1"
EOF
  cat > "$WORK/control-cargo" <<'EOF'
#!/bin/sh
cargo_output=fresh-independent-oracle-output
printf '%s\n' "$cargo_output"
EOF
  chmod +x "$WORK/libsecp-control-runner" "$WORK/k256-control-runner" "$WORK/control-cargo"
  LIBSECP_RUNNER="$WORK/libsecp-control-runner"
  K256_RUNNER="$WORK/k256-control-runner"
  LIBSECP_EXPECTED_SHA=$LIBSECP_CONTROL_RUNNER_EXPECTED_SHA
  K256_EXPECTED_SHA=$K256_CONTROL_RUNNER_EXPECTED_SHA
  [ "$(sha256_file "$WORK/control-cargo")" = "$CONTROL_CARGO_EXPECTED_SHA" ] || {
    echo "gen_signing_corpus: control cargo implementation digest drifted" >&2
    exit 1
  }
  capture_cargo_identity "$WORK/control-cargo"
  ORACLE_RECEIPT="$WORK/oracle-control.receipt"
  LIBSECP_OUTPUT="$WORK/oracle-control-libsecp.out"
  K256_OUTPUT="$WORK/oracle-control-k256.out"
  printf '%s\n' stale-pre-existing-output > "$LIBSECP_OUTPUT"
  printf '%s\n' stale-pre-existing-output > "$K256_OUTPUT"
else
  capture_cargo_identity "$(resolve_command_executable cargo)"
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

  cc -O2 -DUSE_FORCE_WIDEMUL_INT64=1 -I"$WORK/libsecp" \
    -o "$WORK/libsecp-sign" "$HERE/signing_corpus_libsecp.c" \
    "$WORK/libsecp/src/precomputed_ecmult.c" "$WORK/libsecp/src/precomputed_ecmult_gen.c"
  # ORACLE_EXECUTION: libsecp256k1
  LIBSECP_RUNNER="$WORK/libsecp-sign"
  LIBSECP_EXPECTED_SHA=$(sha256_file "$WORK/libsecp-sign")

  cp "$HERE/signing_k256/Cargo.toml" "$HERE/signing_k256/Cargo.lock" "$WORK/rust/"
  cp -R "$HERE/signing_k256/src" "$WORK/rust/src"
  mkdir "$WORK/rust/.cargo"
  printf '[patch.crates-io]\nk256 = { path = "%s/k256" }\n' "$WORK/k256" > "$WORK/rust/.cargo/config.toml"
  cat > "$WORK/k256-runner" <<'EOF'
#!/bin/sh
# ORACLE_EXECUTION: k256 + locked rfc6979 0.4.0
exec "$ORACLE_CARGO" run --quiet --locked --manifest-path "$ORACLE_WORK/rust/Cargo.toml" -- "$1"
EOF
  chmod +x "$WORK/k256-runner"
  K256_RUNNER="$WORK/k256-runner"
  K256_EXPECTED_SHA=$K256_WRAPPER_EXPECTED_SHA
  ORACLE_RECEIPT="$WORK/oracle-completion.receipt"
  LIBSECP_OUTPUT="$WORK/libsecp.out"
  K256_OUTPUT="$WORK/k256.out"
fi

# ORACLE_MODE_SETUP_COMPLETE
run_oracle_pair "$LIBSECP_RUNNER" "$K256_RUNNER" \
  "$LIBSECP_EXPECTED_SHA" "$K256_EXPECTED_SHA" "$CARGO_EXECUTABLE" \
  "$CARGO_EXPECTED_PATH" "$CARGO_EXPECTED_FILE_ID" "$CARGO_EXPECTED_CONTENT_SHA" \
  "$HERE/signing_inputs.txt" \
  "$LIBSECP_OUTPUT" "$K256_OUTPUT" "$ORACLE_RECEIPT"
cat "$ORACLE_RECEIPT"

if [ "$MODE" = oracle-control ]; then
  exit 0
fi

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
