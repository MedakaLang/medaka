#!/bin/sh
# pds/oracle/run.sh — stand up the official Bluesky PDS locally as the Phase 0/1 oracle.
# NOT A GATE: this is a local manual procedure, ledgered in test/CI-COVERAGE-TOOLS.txt
# (key `pds/oracle/run`) — no CI job invokes it and none should. Procedure and rationale:
# docs/ops/PDS-ORACLE.md.
#
# TWO ROUTES, one script:
#   primary (docker):    pull | verify | up | check | down | provenance
#   fallback (no docker): node-setup | node-up | check | node-provenance
# `check` is shared by both routes.
#
# Dual-platform (AGENTS.md): POSIX sh only, no bashisms; sha256sum OR shasum -a 256;
# no `timeout` (use curl --retry --retry-connrefused instead).
set -eu

# ---- pinned identity of the service/ payload (docs/ops/PDS-ORACLE.md, "Why Route B is a
# faithful substitute" under the Route B provenance table) — fallback route ----
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

# ---- primary (docker) route identity ----
PDS_ORACLE_IMAGE_REPO="ghcr.io/bluesky-social/pds"
# The IMMUTABLE pin. Multi-arch INDEX digest (docs/ops/PDS-ORACLE.md, "Pinned digest (the
# anchor — not the tag)" under the Route A provenance table) — NOT a per-platform manifest
# digest, NOT the mutable :0.4 tag. Overridable ONLY so the digest
# check can be proven fail-capable (acceptance A3).
PDS_ORACLE_IMAGE_DIGEST="${PDS_ORACLE_IMAGE_DIGEST:-sha256:d95725b24dbe53af9d91dc69750556931ebed6c396f2cfa42b221434db642f12}"
PDS_ORACLE_CONTAINER="${PDS_ORACLE_CONTAINER:-medaka-pds-oracle}"
PDS_ORACLE_PORT="${PDS_ORACLE_PORT:-3999}"

usage() {
  cat <<'EOF'
usage: pds/oracle/run.sh <subcommand>

  primary (docker):
    pull          docker pull the pinned image by DIGEST, then verify it landed
    verify        offline: confirm the pinned digest is present in the local image
                  store (no network)
    up            create data/blobs dirs, generate pds.docker.env if absent, and
                  `docker run -d` the pinned image (detached; supervised by dockerd)
    check         probe /xrpc/_health and /xrpc/com.atproto.server.describeServer
                  (shared with the fallback route)
    down          docker rm -f the oracle container (idempotent)
    provenance    print the pinned reference, local RepoDigests, OCI labels, the
                  @atproto/pds package version, the container's Node version, and
                  the local docker server version — all local reads, no network

  fallback (no docker) — use when Docker is unavailable (macOS w/o Docker, CI,
  a locked-down box):
    node-setup      fetch the pinned service/ payload, verify its sha256 against the
                    pinned digests, then `pnpm install --production --frozen-lockfile`
                    into $PDS_ORACLE_HOME (default: ${TMPDIR:-/var/tmp}/medaka-pds-oracle)
    node-up         load/generate pds.env, then run `node --enable-source-maps index.ts`
                    in the FOREGROUND (this is a server: run it in its own turn)
    node-provenance print pinned revision, observed service/ digests, installed
                    @atproto/pds version, and host node/pnpm versions

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
    if [ "$1" = "docker" ]; then
      echo "pds/oracle/run.sh: no Docker here — use the fallback route: node-setup / node-up / check (see docs/ops/PDS-ORACLE.md)" >&2
    else
      echo "pds/oracle/run.sh: missing dependency: $1" >&2
    fi
    exit 1
  }
}

script_dir() {
  # absolute path of this script's directory, for locating the *.env.sample files
  d="$(dirname "$0")"
  ( cd "$d" && pwd )
}

require_plc_url() {
  # $1 = env file path. Refuses to let either route start a server unless
  # PDS_DID_PLC_URL is set to a NON-EMPTY value IN THE FILE.
  #
  # Deliberate property: this reads the FILE, not the ambient shell environment.
  # For Route B (node-up) an exported shell PDS_DID_PLC_URL would reach `node`
  # anyway via `set -a; . "$env_file"`, but this guard still refuses on the file's
  # own content — refuse-when-unsure, uniform across both routes. An ambient-env
  # guard (`[ -n "${PDS_DID_PLC_URL:-}" ]`) would only ever cover Route B: Route A's
  # `docker run --env-file` does not inherit the caller's shell at all.
  #
  # Unset AND present-but-empty are both refused: @atproto/common's envStr() maps
  # an empty string to `undefined`, identically to unset, so
  # `PDS_DID_PLC_URL=` (empty) resolves to the PRODUCTION https://plc.directory —
  # exactly the defect this guard exists to close. A key merely being present is
  # not enough; the value must be non-empty and non-whitespace.
  #
  # Whitespace-only (e.g. `PDS_DID_PLC_URL=" "`) checked separately (RUN-PDS0-030):
  # envStr() (@atproto/common dist/env.js:6-11) only tests `str.length === 0` — it
  # does NOT trim — so a whitespace-only value has nonzero length and is NOT mapped
  # to undefined; it would reach `new plc.Client(...)` as a literal garbage URL and
  # fail LOUDLY at connect time, not silently resolve to production. The non-empty
  # check below is therefore sufficient; this guard rejects it anyway (its regex
  # requires a non-whitespace FIRST character) as an accidental extra safety margin,
  # not because the library's behavior requires it.
  ef="$1"
  if ! grep -Eq '^PDS_DID_PLC_URL=[^[:space:]]' "$ef" 2>/dev/null; then
    echo "pds/oracle/run.sh: REFUSING to start — PDS_DID_PLC_URL is not set (or is empty) in $ef" >&2
    echo "  This is a REQUIRED safety decision, not a default. Unset or empty means the" >&2
    echo "  server resolves to the PRODUCTION https://plc.directory, and account creation" >&2
    echo "  would perform a real, permanent, un-withdrawable public did:plc WRITE there." >&2
    echo "  Safe value to paste into $ef:" >&2
    echo "    PDS_DID_PLC_URL=http://127.0.0.1:9" >&2
    echo "  Or delete $ef and re-run this subcommand to regenerate it from the updated sample." >&2
    exit 1
  fi
}

# ============================== primary (docker) route ==============================

cmd_pull() {
  need docker
  ref="${PDS_ORACLE_IMAGE_REPO}@${PDS_ORACLE_IMAGE_DIGEST}"
  echo "pds/oracle/run.sh: pulling $ref"
  docker pull "$ref"
  cmd_verify
}

cmd_verify() {
  need docker
  ref="${PDS_ORACLE_IMAGE_REPO}@${PDS_ORACLE_IMAGE_DIGEST}"
  digests="$(docker image inspect "$ref" --format='{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null)" || {
    echo "pds/oracle/run.sh: $ref — not present in the local image store under the pinned digest — run 'pull'" >&2
    exit 1
  }
  if ! printf '%s\n' "$digests" | grep -Fxq "$ref"; then
    echo "pds/oracle/run.sh: DIGEST VERIFY FAILED" >&2
    echo "  expected: $ref" >&2
    echo "  actual (RepoDigests):" >&2
    printf '%s\n' "$digests" | sed 's/^/    /' >&2
    exit 1
  fi
  echo "pds/oracle/run.sh: verified — $ref is present in the local image store"
}

cmd_up() {
  need docker
  need openssl
  mkdir -p "$PDS_ORACLE_HOME/data" "$PDS_ORACLE_HOME/blobs"
  echo "pds/oracle/run.sh: oracle home: $PDS_ORACLE_HOME"

  env_file="$PDS_ORACLE_HOME/pds.docker.env"
  if [ ! -f "$env_file" ]; then
    sample="$(script_dir)/pds.docker.env.sample"
    [ -f "$sample" ] || { echo "pds/oracle/run.sh: missing $sample" >&2; exit 1; }
    echo "pds/oracle/run.sh: generating $env_file from $sample (secrets via openssl rand)"
    jwt_secret="$(openssl rand -hex 32)"
    admin_pw="$(openssl rand -hex 16)"
    plc_key="$(openssl rand -hex 32)"
    ( umask 077; sed \
      -e "s#^PDS_JWT_SECRET=.*#PDS_JWT_SECRET=$jwt_secret#" \
      -e "s#^PDS_ADMIN_PASSWORD=.*#PDS_ADMIN_PASSWORD=$admin_pw#" \
      -e "s#^PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=.*#PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=$plc_key#" \
      -e "s#^PDS_PORT=.*#PDS_PORT=$PDS_ORACLE_PORT#" \
      "$sample" > "$env_file" )
    chmod 600 "$env_file"
    echo "pds/oracle/run.sh: wrote $env_file (never committed; oracle home is outside the repo)"
  fi

  require_plc_url "$env_file"

  docker rm -f "$PDS_ORACLE_CONTAINER" >/dev/null 2>&1 || true

  ref="${PDS_ORACLE_IMAGE_REPO}@${PDS_ORACLE_IMAGE_DIGEST}"
  cid="$(docker run -d --name "$PDS_ORACLE_CONTAINER" \
    -p "$PDS_ORACLE_PORT:$PDS_ORACLE_PORT" \
    -v "$PDS_ORACLE_HOME:/pds" \
    --env-file "$env_file" \
    "$ref")"
  echo "pds/oracle/run.sh: container: $cid"
  echo "pds/oracle/run.sh: image: $ref"
  echo "pds/oracle/run.sh: serving at http://localhost:$PDS_ORACLE_PORT (once ready — use 'check'; a healthy container logs nothing)"
}

cmd_down() {
  need docker
  if docker rm -f "$PDS_ORACLE_CONTAINER" >/dev/null 2>&1; then
    echo "pds/oracle/run.sh: removed container $PDS_ORACLE_CONTAINER"
  else
    echo "pds/oracle/run.sh: no container named $PDS_ORACLE_CONTAINER to remove"
  fi
}

cmd_provenance() {
  need docker
  ref="${PDS_ORACLE_IMAGE_REPO}@${PDS_ORACLE_IMAGE_DIGEST}"
  echo "pinned reference: $ref"
  echo "-- local RepoDigests --"
  docker inspect "$ref" --format='{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
    || echo "  (image not present locally — run 'pull')"
  echo "-- OCI labels --"
  echo "image (distro) version:       $(docker inspect "$ref" --format='{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo '?')"
  echo "image revision:                $(docker inspect "$ref" --format='{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || echo '?')"
  echo "image source:                  $(docker inspect "$ref" --format='{{index .Config.Labels "org.opencontainers.image.source"}}' 2>/dev/null || echo '?')"
  echo "image created:                 $(docker inspect "$ref" --format='{{index .Config.Labels "org.opencontainers.image.created"}}' 2>/dev/null || echo '?')"
  pkg_ver="$(docker run --rm --entrypoint node "$ref" -e "console.log(require('/app/node_modules/@atproto/pds/package.json').version)" 2>/dev/null || echo '?')"
  echo "@atproto/pds package version:  $pkg_ver"
  node_ver="$(docker inspect "$ref" --format='{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^NODE_VERSION=//p')"
  echo "container node version:        ${node_ver:-?}"
  echo "docker server version:         $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
  echo "-- disambiguation --"
  echo "the 'image (distro) version' above is what GET /xrpc/_health returns; the"
  echo "'@atproto/pds package version' is the npm package version installed inside the"
  echo "image — upstream's own comment warns they 'may deviate'. See docs/ops/PDS-ORACLE.md."
}

# ============================== shared: check ==============================

cmd_check() {
  need curl
  port="$PDS_ORACLE_PORT"
  for ef in "$PDS_ORACLE_HOME/pds.docker.env" "$PDS_ORACLE_HOME/pds.env"; do
    if [ -f "$ef" ]; then
      p="$(sed -n 's/^PDS_PORT=//p' "$ef" | tail -1)"
      [ -n "$p" ] && port="$p"
      break
    fi
  done
  base="http://localhost:${port}"
  ok=0

  echo "pds/oracle/run.sh: GET $base/xrpc/_health"
  health_rc=0
  health_out="$(curl -sS --retry 5 --retry-delay 1 --retry-connrefused -w '\n%{http_code}' "$base/xrpc/_health")" || health_rc=$?
  if [ "$health_rc" -ne 0 ]; then
    echo "  -> (curl exit $health_rc, no response)"
    ok=1
  else
    health_code="$(printf '%s' "$health_out" | tail -1)"
    health_body="$(printf '%s' "$health_out" | sed '$d')"
    echo "  -> $health_code $health_body"
    [ "$health_code" = "200" ] || ok=1
  fi

  echo "pds/oracle/run.sh: GET $base/xrpc/com.atproto.server.describeServer"
  ds_rc=0
  ds_out="$(curl -sS --retry 5 --retry-delay 1 --retry-connrefused -w '\n%{http_code}' "$base/xrpc/com.atproto.server.describeServer")" || ds_rc=$?
  if [ "$ds_rc" -ne 0 ]; then
    echo "  -> (curl exit $ds_rc, no response)"
    ok=1
  else
    ds_code="$(printf '%s' "$ds_out" | tail -1)"
    ds_body="$(printf '%s' "$ds_out" | sed '$d')"
    echo "  -> $ds_code $ds_body"
    [ "$ds_code" = "200" ] || ok=1
  fi

  if [ "$ok" -ne 0 ]; then
    echo "pds/oracle/run.sh: check FAILED (expected 200 from both endpoints)" >&2
    exit 1
  fi
  echo "pds/oracle/run.sh: check OK"
}

# ============================== fallback (no docker) route ==============================

cmd_node_setup() {
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
  # *next* `node-setup` cleanly re-fetches it — "restore by re-running node-setup").
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
      echo "pds/oracle/run.sh: removed corrupted $fname — re-run 'node-setup' to re-fetch it" >&2
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
    echo "pds/oracle/run.sh: node-setup ABORTED — digest verification failed (see above)" >&2
    exit 1
  fi

  echo "pds/oracle/run.sh: installing dependencies (pnpm@$PNPM_VERSION, production, frozen-lockfile)"
  ( cd "$PDS_ORACLE_HOME" && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack "pnpm@$PNPM_VERSION" install --production --frozen-lockfile )
  echo "pds/oracle/run.sh: node-setup complete"
}

cmd_node_up() {
  need node
  if [ ! -f "$PDS_ORACLE_HOME/index.ts" ]; then
    echo "pds/oracle/run.sh: $PDS_ORACLE_HOME/index.ts missing — run 'node-setup' first" >&2
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
    ( umask 077; sed \
      -e "s#^PDS_JWT_SECRET=.*#PDS_JWT_SECRET=$jwt_secret#" \
      -e "s#^PDS_ADMIN_PASSWORD=.*#PDS_ADMIN_PASSWORD=$admin_pw#" \
      -e "s#^PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=.*#PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=$plc_key#" \
      -e "s#^PDS_PORT=.*#PDS_PORT=$PDS_ORACLE_PORT#" \
      "$sample" > "$env_file" )
    chmod 600 "$env_file"
    echo "pds/oracle/run.sh: wrote $env_file (never committed; oracle home is outside the repo)"
  fi

  require_plc_url "$env_file"

  # shellcheck disable=SC1090
  set -a
  . "$env_file"
  set +a

  # better-sqlite3/the blobstore do not create their own directories.
  [ -n "${PDS_DATA_DIRECTORY:-}" ] && mkdir -p "$PDS_DATA_DIRECTORY"
  [ -n "${PDS_BLOBSTORE_DISK_LOCATION:-}" ] && mkdir -p "$PDS_BLOBSTORE_DISK_LOCATION"

  echo "pds/oracle/run.sh: starting PDS on port ${PDS_PORT:-3999} (data dir: ${PDS_DATA_DIRECTORY:-unset})"
  ( cd "$PDS_ORACLE_HOME" && exec node --enable-source-maps index.ts )
}

cmd_node_provenance() {
  echo "pinned revision: $PINNED_REV"
  echo "-- observed service/ digests (from \$PDS_ORACLE_HOME, if present) --"
  # shellcheck disable=SC2039
  echo "$PINNED_FILES" | while IFS="	" read -r fname expected; do
    [ -z "$fname" ] && continue
    dest="$PDS_ORACLE_HOME/$fname"
    if [ -f "$dest" ]; then
      echo "$fname: $(sha256_of "$dest")  (pinned: $expected)"
    else
      echo "$fname: NOT PRESENT (run 'node-setup' first)  (pinned: $expected)"
    fi
  done

  atp_pkg="$PDS_ORACLE_HOME/node_modules/@atproto/pds/package.json"
  if [ -f "$atp_pkg" ] && command -v node >/dev/null 2>&1; then
    echo "@atproto/pds version: $(node -e "console.log(require('$atp_pkg').version)")"
  else
    echo "@atproto/pds version: NOT INSTALLED (run 'node-setup' first)"
  fi

  if command -v node >/dev/null 2>&1; then
    echo "host node --version: $(node --version)"
  else
    echo "host node --version: node NOT FOUND"
  fi

  if command -v corepack >/dev/null 2>&1; then
    echo "pnpm version (pinned): $PNPM_VERSION"
  fi

  echo "-- (live ghcr.io tag resolution dropped here — use the primary route's offline"
  echo "    'provenance', which reads $IMAGE_TAG's pinned digest from the local image" \
    "store instead of resolving the mutable tag over the network) --"
}

# ============================== dispatch ==============================

[ $# -ge 1 ] || { usage >&2; exit 1; }

case "$1" in
  pull) cmd_pull ;;
  verify) cmd_verify ;;
  up) cmd_up ;;
  check) cmd_check ;;
  down) cmd_down ;;
  provenance) cmd_provenance ;;
  node-setup) cmd_node_setup ;;
  node-up) cmd_node_up ;;
  node-provenance) cmd_node_provenance ;;
  -h|--help) usage; exit 0 ;;
  *)
    echo "pds/oracle/run.sh: unknown subcommand: $1" >&2
    usage >&2
    exit 1
    ;;
esac
