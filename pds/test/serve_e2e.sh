#!/bin/sh
# Gate A (#2481, #2525): drive `pds/serve.mdk` end to end over its real
# loopback socket with a plain synchronous client (`pds/test/
# serve_client_main.mdk`, over `stdlib/net` — not `net_async`, which is the
# server's own scheduler and has no business inside a test client). Every
# case below is graded by that client's PASS/FAIL last line, exactly the
# convention `pds/test/store_persistence_main.mdk` already uses.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
SERVE_SRC="$ROOT/pds/serve.mdk"
CLIENT_SRC="$ROOT/pds/test/serve_client_main.mdk"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-serve-e2e.XXXXXX")
SERVER_PID=""

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

require_empty() {
  [ ! -s "$1" ] || {
    cat "$1" >&2
    fail "$2 emitted stderr"
  }
}

[ -x "$MEDAKA" ] || fail "build medaka first (missing $MEDAKA)"

# ── build both native drivers up front ──────────────────────────────────────
# Both `serve.mdk` (Async, Net) and the test client (Net) are native-only:
# `stdlib/net` is unbound in the interpreter and rejected by Wasm.

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$SERVE_SRC" -o "$WORK/pdsd" \
  > "$WORK/build_serve.log" 2>&1
then
  cat "$WORK/build_serve.log" >&2
  fail 'native serve.mdk build failed'
fi

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$CLIENT_SRC" -o "$WORK/client" \
  > "$WORK/build_client.log" 2>&1
then
  cat "$WORK/build_client.log" >&2
  fail 'native serve_client_main.mdk build failed'
fi

# ── fixed fixture identity, mirroring store_persistence_main's convention ──
DID='did:plc:servee2egatefixture00001'
HANDLE='alice.test'
HOSTNAME='pds.test'
# Any valid secp256k1 scalar; the same one store_persistence_main.mdk uses.
SECRET_HEX='c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721'
COLLECTION='app.bsky.feed.post'
RKEY='e2egatefixture'
RECORD_TEXT='pds serve_e2e gate fixture record'

# The session-token secret, which is NOT the repository signing key: the two
# are separate secrets by design, and this gate proves the server accepts a
# token minted from the one it was handed at `--token-secret`.
TOKEN_SECRET_HEX='7f1c0a6d2b93e45880ac31f6d5e27b04913ca8e6f27d4b51a03c8e19d6b4720f'

DATA="$WORK/data"
mkdir -p "$DATA"
printf '%s\n' "$SECRET_HEX" > "$WORK/key.hex"
printf '%s\n' "$TOKEN_SECRET_HEX" > "$WORK/token.hex"

# Prints the readiness port once `pattern` (readiness line) appears in
# `logfile`, or fails after ~10s. `pattern` is matched with grep -F.
wait_for_port() {
  logfile=$1
  i=0
  while [ "$i" -lt 100 ]; do
    if grep -F 'serve: listening on 127.0.0.1:' "$logfile" >/dev/null 2>&1; then
      sed -n 's/.*listening on 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$logfile" | head -1
      return 0
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      return 1
    fi
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

start_server() {
  extra=$1
  outfile=$2
  errfile=$3
  # shellcheck disable=SC2086 # $extra is a single optional flag, no quoting needed
  "$WORK/pdsd" \
    --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
    --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
    --data "$DATA" --port 0 $extra \
    >"$outfile" 2>"$errfile" &
  SERVER_PID=$!
}

client() {
  "$WORK/client" "$@"
}

# ── first instance: genesis, then cases 1-8 ─────────────────────────────────

start_server --init "$WORK/serve1.out" "$WORK/serve1.err"
PORT1=$(wait_for_port "$WORK/serve1.out") || {
  cat "$WORK/serve1.err" >&2
  fail 'server did not report readiness'
}
require_empty "$WORK/serve1.err" 'server startup'

# One session token for every write case below. The three record-write
# procedures are gated at the composition seam (#2604), so a write that
# presents no token is refused 401 before its handler runs.
TOKEN=$(client mint-token "$TOKEN_SECRET_HEX" "$DID" "$HOSTNAME") \
  || fail 'could not mint a session token'
[ -n "$TOKEN" ] || fail 'minted session token was empty'

# 1. a well-formed query gets a correct response
client query "$PORT1" "$DID" || fail 'case 1: well-formed query'

# 2. pipelined pair, both correct, in order
client pipeline "$PORT1" || fail 'case 2: pipelined pair'

# 3. keep-alive reuse
client keepalive "$PORT1" || fail 'case 3: keep-alive reuse'

# 4. chunked write procedure succeeds — this ALSO plants the record that
#    case 9 (restart-and-resume) reads back after the process boundary.
client chunked "$PORT1" "$TOKEN" "$DID" "$COLLECTION" "$RKEY" "$RECORD_TEXT" \
  || fail 'case 4: chunked write'

# 5. every remaining route: the six XRPC NSIDs no other case drives, plus
#    /.well-known/did.json. With cases 1, 4, and 9 that is all nine NSIDs and
#    both well-knowns proven by this gate rather than by reading the registry.
client endpoints "$PORT1" "$TOKEN" "$DID" "$HANDLE" "$COLLECTION" "$RKEY" \
  || fail 'case 5: remaining endpoint coverage'

# 5b. the same write with NO token is refused 401 by the seam, over the real
#    socket — the in-process test proves the seam refuses, this proves the
#    running server does.
client unauthorized "$PORT1" "$DID" "$COLLECTION" "$RKEY" \
  || fail 'case 5b: unauthenticated write refused'

# 6. malformed request -> 400, error path not a hang or crash
client malformed "$PORT1" || fail 'case 6: malformed request'

# 7. over-cap body -> rejected (413), not truncated or hung
client overcap "$PORT1" || fail 'case 7: over-cap body'

# 8. idle connection closed after ~30s (idleTimeout) — costs real wall time.
client idle "$PORT1" || fail 'case 8: idle timeout'

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve1.err" 'server (post-run)'

# ── second instance: same --data, no --init, must resume prior state ───────

start_server "" "$WORK/serve2.out" "$WORK/serve2.err"
PORT2=$(wait_for_port "$WORK/serve2.out") || {
  cat "$WORK/serve2.err" >&2
  fail 'resumed server did not report readiness'
}
require_empty "$WORK/serve2.err" 'resumed server startup'

# 9. restart-and-resume: the record written before the restart is readable
#    from the fresh process over the same --data directory.
client resume "$PORT2" "$DID" "$COLLECTION" "$RKEY" "$RECORD_TEXT" \
  || fail 'case 9: restart-and-resume'

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve2.err" 'resumed server (post-run)'

# ── third, independent --data dir: --init overwrite refusal (#2481) ────────

# 10. `--init` against a directory that already holds a repository must
#    refuse rather than silently overwriting `head` — even when the second
#    `--init` is given a different (but still valid) --key, the exact
#    misconfiguration #2481 showed used to be discriminated by whether
#    `loadRepo` happened to succeed rather than by whether a head file
#    exists. A second genesis under the wrong key must exit nonzero AND
#    leave the first genesis's `head` file byte-identical.
DATA10="$WORK/data10"
mkdir -p "$DATA10"
KEY10A_HEX='c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721'
# A different, still-valid (64-hex-digit) secp256k1 scalar than KEY10A_HEX.
KEY10B_HEX='29988895eae3bb77b1ec1be453a7168eba4422c3897bc846a168a1495a67fa99'
printf '%s\n' "$KEY10A_HEX" > "$WORK/key10a.hex"
printf '%s\n' "$KEY10B_HEX" > "$WORK/key10b.hex"

"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key10a.hex" --data "$DATA10" --port 0 --init \
  >"$WORK/serve10a.out" 2>"$WORK/serve10a.err" &
SERVER_PID=$!
PORT10A=$(wait_for_port "$WORK/serve10a.out") || {
  cat "$WORK/serve10a.err" >&2
  fail 'case 10: genesis server did not report readiness'
}
require_empty "$WORK/serve10a.err" 'case 10 genesis startup'
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

[ -f "$DATA10/head" ] || fail 'case 10: genesis did not persist a head file'
HEAD_BEFORE=$(cksum "$DATA10/head")

# A pre-fix binary does not error out here at all: it silently treats the
# unreadable-under-this-key head as "no repo yet" and starts a second,
# real server. A plain synchronous invocation would then hang forever
# rather than fail, so this bounds the wait the same way wait_for_port
# does — refusing (fast exit) is the only outcome that must happen within
# it, not "eventually exits or listens".
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key10b.hex" --data "$DATA10" --port 0 --init \
  >"$WORK/serve10b.out" 2>"$WORK/serve10b.err" &
SERVER_PID=$!
i=0
while [ "$i" -lt 100 ]; do
  kill -0 "$SERVER_PID" 2>/dev/null || break
  i=$((i + 1))
  sleep 0.1
done
if kill -0 "$SERVER_PID" 2>/dev/null; then
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
  fail 'case 10: second --init with a different key did not exit (still running — likely bound and serving)'
fi
RC10B=0
wait "$SERVER_PID" 2>/dev/null || RC10B=$?
SERVER_PID=""
[ "$RC10B" -ne 0 ] || fail 'case 10: second --init with a different key exited 0'

HEAD_AFTER=$(cksum "$DATA10/head")
[ "$HEAD_BEFORE" = "$HEAD_AFTER" ] \
  || fail 'case 10: second --init with a different key modified the existing head file'

echo 'PASS: serve_e2e — query, pipeline, keep-alive, chunked write, every remaining route, malformed, over-cap, idle timeout, restart-and-resume, init-overwrite-refusal'
