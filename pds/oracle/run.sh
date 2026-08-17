#!/bin/sh
# pds/oracle/run.sh — stand up the official Bluesky PDS service payload locally as the
# Phase 0/1 oracle. NOT A GATE: this is a local manual procedure, ledgered in
# test/CI-COVERAGE-TOOLS.txt (key `pds/oracle/run`) — no CI job invokes it and none
# should. Procedure and rationale: docs/ops/PDS-ORACLE.md.
#
# Subcommands: setup | up | check | provenance
#
# Dual-platform (AGENTS.md): POSIX sh only, no bashisms; sha256sum OR shasum -a 256;
# no `timeout` (use curl --retry --retry-connrefused instead).
set -eu

# ---- pinned identity of the service/ payload (docs/ops/PDS-ORACLE.md, F-5) ----
PINNED_REV="374cf1d4ba782d4391bbb73e4e2d3f320d4846d6"
RAW_BASE="https://raw.githubusercontent.com/bluesky-social/pds/${PINNED_REV}/service"

# file<TAB>expected-sha256, one per line
PINNED_FILES='
index.ts	69ef8c1dfdca942fece327484c410c26c8c347e3303f9d1eb11e312c9946cc8a
package.json	c0e7740808e0d6bc26a9fd773162f780a45665b0cff2137a256157f3cff77fd5
pnpm-lock.yaml	23a8c97e01dff561266a6dcf67a4b74b25e98ebc695e6fa17c60ddf964160f73
'

# ---- oracle home: deliberately OUTSIDE the repo, never dirties the tree ----
PDS_ORACLE_HOME="${PDS_ORACLE_HOME:-${TMPDIR:-/var/tmp}/medaka-pds-oracle}"

PNPM_VERSION="10.34.1"
IMAGE_TAG="ghcr.io/bluesky-social/pds:0.4"

usage() {
  cat <<'EOF'
usage: pds/oracle/run.sh <subcommand>

  setup       fetch the pinned service/ payload, verify its sha256 against the
              pinned digests, then `pnpm install --production --frozen-lockfile`
              into $PDS_ORACLE_HOME (default: ${TMPDIR:-/var/tmp}/medaka-pds-oracle)
  up          load/generate pds.env, then run `node --enable-source-maps index.ts`
              in the FOREGROUND (this is a server: run it in its own turn)
  check       probe /xrpc/_health and /xrpc/com.atproto.server.describeServer
  provenance  print pinned revision, observed digests, installed @atproto/pds
              version, node/pnpm versions, and (network permitting) the live
              ghcr.io/bluesky-social/pds:0.4 digest

See docs/ops/PDS-ORACLE.md for the full procedure and its limitations.
EOF
}

sha256_of() {
  # $1 = file path; prints the hex digest only
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "pds/oracle/run.sh: no sha256sum or shasum found" >&2
    exit 1
  fi
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "pds/oracle/run.sh: missing dependency: $1" >&2
    exit 1
  }
}

cmd_setup() {
  need curl
  need corepack
  mkdir -p "$PDS_ORACLE_HOME"
  echo "pds/oracle/run.sh: oracle home: $PDS_ORACLE_HOME"
  echo "pds/oracle/run.sh: verifying/fetching service/ payload at revision $PINNED_REV"

  rm -f "$PDS_ORACLE_HOME/.setup_failed"
  # shellcheck disable=SC2039
  # NOTE: an existing file is verified IN PLACE first (idempotent — no needless re-fetch,
  # and this is what makes the digest check fail-capable: a corrupted file already sitting
  # in the oracle home is caught here, named with expected-vs-actual, then removed so the
  # *next* `setup` cleanly re-fetches it — "restore by re-running setup", per acceptance A3).
  echo "$PINNED_FILES" | while IFS="	" read -r fname expected; do
    [ -z "$fname" ] && continue
    dest="$PDS_ORACLE_HOME/$fname"
    if [ -f "$dest" ]; then
      actual="$(sha256_of "$dest")"
      if [ "$actual" = "$expected" ]; then
        echo "pds/oracle/run.sh: $fname already present and verified ($actual)"
        continue
      fi
      echo "pds/oracle/run.sh: DIGEST MISMATCH for existing $fname" >&2
      echo "  expected: $expected" >&2
      echo "  actual:   $actual" >&2
      rm -f "$dest"
      echo "pds/oracle/run.sh: removed corrupted $fname — re-run 'setup' to re-fetch it" >&2
      echo 1 > "$PDS_ORACLE_HOME/.setup_failed"
      continue
    fi
    curl -sSL --retry 3 --retry-delay 1 -o "$dest" "$RAW_BASE/$fname"
    actual="$(sha256_of "$dest")"
    if [ "$actual" != "$expected" ]; then
      echo "pds/oracle/run.sh: DIGEST MISMATCH for freshly fetched $fname" >&2
      echo "  expected: $expected" >&2
      echo "  actual:   $actual" >&2
      rm -f "$dest"
      echo 1 > "$PDS_ORACLE_HOME/.setup_failed"
    else
      echo "pds/oracle/run.sh: $fname OK ($actual)"
    fi
  done

  if [ -f "$PDS_ORACLE_HOME/.setup_failed" ]; then
    rm -f "$PDS_ORACLE_HOME/.setup_failed"
    echo "pds/oracle/run.sh: setup ABORTED — digest verification failed (see above)" >&2
    exit 1
  fi

  echo "pds/oracle/run.sh: installing dependencies (pnpm@$PNPM_VERSION, production, frozen-lockfile)"
  ( cd "$PDS_ORACLE_HOME" && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack "pnpm@$PNPM_VERSION" install --production --frozen-lockfile )
  echo "pds/oracle/run.sh: setup complete"
}

script_dir() {
  # absolute path of this script's directory, for locating pds.env.sample
  d="$(dirname "$0")"
  ( cd "$d" && pwd )
}

cmd_up() {
  need node
  if [ ! -f "$PDS_ORACLE_HOME/index.ts" ]; then
    echo "pds/oracle/run.sh: $PDS_ORACLE_HOME/index.ts missing — run 'setup' first" >&2
    exit 1
  fi

  env_file="$PDS_ORACLE_HOME/pds.env"
  if [ ! -f "$env_file" ]; then
    sample="$(script_dir)/pds.env.sample"
    [ -f "$sample" ] || { echo "pds/oracle/run.sh: missing $sample" >&2; exit 1; }
    echo "pds/oracle/run.sh: generating $env_file from $sample (secrets via openssl rand)"
    need openssl
    jwt_secret="$(openssl rand -hex 32)"
    admin_pw="$(openssl rand -hex 16)"
    plc_key="$(openssl rand -hex 32)"
    sed \
      -e "s#^PDS_JWT_SECRET=.*#PDS_JWT_SECRET=$jwt_secret#" \
      -e "s#^PDS_ADMIN_PASSWORD=.*#PDS_ADMIN_PASSWORD=$admin_pw#" \
      -e "s#^PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=.*#PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=$plc_key#" \
      "$sample" > "$env_file"
    echo "pds/oracle/run.sh: wrote $env_file (never committed; oracle home is outside the repo)"
  fi

  # shellcheck disable=SC1090
  set -a
  . "$env_file"
  set +a

  # better-sqlite3/the blobstore do not create their own directories.
  [ -n "${PDS_DATA_DIRECTORY:-}" ] && mkdir -p "$PDS_DATA_DIRECTORY"
  [ -n "${PDS_BLOBSTORE_DISK_LOCATION:-}" ] && mkdir -p "$PDS_BLOBSTORE_DISK_LOCATION"

  echo "pds/oracle/run.sh: starting PDS on port ${PDS_PORT:-3000} (data dir: ${PDS_DATA_DIRECTORY:-unset})"
  ( cd "$PDS_ORACLE_HOME" && exec node --enable-source-maps index.ts )
}

cmd_check() {
  need curl
  env_file="$PDS_ORACLE_HOME/pds.env"
  port="3000"
  if [ -f "$env_file" ]; then
    port="$(sed -n 's/^PDS_PORT=//p' "$env_file" | tail -1)"
    [ -z "$port" ] && port="3000"
  fi
  base="http://localhost:${port}"
  ok=0

  echo "pds/oracle/run.sh: GET $base/xrpc/_health"
  health_out="$(curl -sS --retry 5 --retry-delay 1 --retry-connrefused -w '\n%{http_code}' "$base/xrpc/_health")"
  health_code="$(printf '%s' "$health_out" | tail -1)"
  health_body="$(printf '%s' "$health_out" | sed '$d')"
  echo "  -> $health_code $health_body"
  [ "$health_code" = "200" ] || ok=1

  echo "pds/oracle/run.sh: GET $base/xrpc/com.atproto.server.describeServer"
  ds_out="$(curl -sS --retry 5 --retry-delay 1 --retry-connrefused -w '\n%{http_code}' "$base/xrpc/com.atproto.server.describeServer")"
  ds_code="$(printf '%s' "$ds_out" | tail -1)"
  ds_body="$(printf '%s' "$ds_out" | sed '$d')"
  echo "  -> $ds_code $ds_body"
  [ "$ds_code" = "200" ] || ok=1

  if [ "$ok" -ne 0 ]; then
    echo "pds/oracle/run.sh: check FAILED (expected 200 from both endpoints)" >&2
    exit 1
  fi
  echo "pds/oracle/run.sh: check OK"
}

cmd_provenance() {
  echo "pinned revision: $PINNED_REV"
  echo "-- observed service/ digests (from \$PDS_ORACLE_HOME, if present) --"
  # shellcheck disable=SC2039
  echo "$PINNED_FILES" | while IFS="	" read -r fname expected; do
    [ -z "$fname" ] && continue
    dest="$PDS_ORACLE_HOME/$fname"
    if [ -f "$dest" ]; then
      echo "$fname: $(sha256_of "$dest")  (pinned: $expected)"
    else
      echo "$fname: NOT PRESENT (run 'setup' first)  (pinned: $expected)"
    fi
  done

  atp_pkg="$PDS_ORACLE_HOME/node_modules/@atproto/pds/package.json"
  if [ -f "$atp_pkg" ] && command -v node >/dev/null 2>&1; then
    echo "@atproto/pds version: $(node -e "console.log(require('$atp_pkg').version)")"
  else
    echo "@atproto/pds version: NOT INSTALLED (run 'setup' first)"
  fi

  if command -v node >/dev/null 2>&1; then
    echo "host node --version: $(node --version)"
  else
    echo "host node --version: node NOT FOUND"
  fi

  if command -v corepack >/dev/null 2>&1; then
    echo "pnpm version (pinned): $PNPM_VERSION"
  fi

  echo "-- live ghcr.io/bluesky-social/pds:0.4 digest (network permitting) --"
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "  skipped: curl or jq not available"
    return 0
  fi
  token="$(curl -sS -m 15 "https://ghcr.io/token?scope=repository:bluesky-social/pds:pull" 2>/dev/null | jq -r '.token // empty')"
  if [ -z "$token" ]; then
    echo "  skipped: could not obtain anonymous ghcr token (network unavailable?)"
    return 0
  fi
  idx="$(curl -sS -m 15 -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
    -D - -o /dev/null "https://ghcr.io/v2/bluesky-social/pds/manifests/0.4" 2>/dev/null \
    | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: //p')"
  if [ -z "$idx" ]; then
    echo "  skipped: could not resolve $IMAGE_TAG digest (network unavailable?)"
    return 0
  fi
  echo "  $IMAGE_TAG index digest (resolved today): $idx"
  echo "  NOTE: 0.4 is a MUTABLE tag — this is what it resolved to at run time, not a pin."
}

[ $# -ge 1 ] || { usage >&2; exit 1; }

case "$1" in
  setup) cmd_setup ;;
  up) cmd_up ;;
  check) cmd_check ;;
  provenance) cmd_provenance ;;
  -h|--help) usage; exit 0 ;;
  *)
    echo "pds/oracle/run.sh: unknown subcommand: $1" >&2
    usage >&2
    exit 1
    ;;
esac
