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
SUBSCRIBE_SRC="$ROOT/pds/test/serve_subscribe_main.mdk"
STUB_SRC="$ROOT/pds/test/appview_stub_main.mdk"
CRAWL_STUB_SRC="$ROOT/pds/test/crawl_stub_main.mdk"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-serve-e2e.XXXXXX")
SERVER_PID=""
# The stub appviews the proxy cases forward to. They outlive individual servers
# (one stub serves several cases), so they are cleaned up here rather than case
# by case, and an abandoned one would hold a port for the rest of the run.
STUB_PIDS=""

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  for pid in $STUB_PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# The server's stderr must be EMPTY. It carried an exception while a file this
# program created was necessarily 0644; now that every secret it writes lands
# 0600 there is nothing left to warn about, so any stderr line at all is a
# failure again.
require_empty() {
  [ ! -s "$1" ] || {
    cat "$1" >&2
    fail "$2 emitted stderr"
  }
}

# A path's permission bits as three octal digits. Both arms are live: CI is
# Linux, and this gate must still run on macOS.
file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# Every file the server creates holding a secret is owner-only. A gate that
# asserted only that the file EXISTS would pass on a world-readable one.
require_owner_only() {
  got=$(file_mode "$1")
  [ "$got" = "600" ] || fail "$2: $1 is mode $got, expected 600"
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

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$SUBSCRIBE_SRC" \
  -o "$WORK/subclient" > "$WORK/build_subclient.log" 2>&1
then
  cat "$WORK/build_subclient.log" >&2
  fail 'native serve_subscribe_main.mdk build failed'
fi

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$STUB_SRC" \
  -o "$WORK/appview" > "$WORK/build_appview.log" 2>&1
then
  cat "$WORK/build_appview.log" >&2
  fail 'native appview_stub_main.mdk build failed'
fi

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$CRAWL_STUB_SRC" \
  -o "$WORK/crawlstub" > "$WORK/build_crawlstub.log" 2>&1
then
  cat "$WORK/build_crawlstub.log" >&2
  fail 'native crawl_stub_main.mdk build failed'
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
# The blob case 14 uploads before the restart and reads back after it. Its
# declared media type is deliberately NOT the default an unknown blob would be
# served as (`application/octet-stream`), so a restart that recovered the bytes
# and lost the declared type fails rather than passing by coincidence.
BLOB_TEXT='pds serve_e2e gate fixture blob bytes'
BLOB_MIME='text/plain'
# A SECOND blob, so the residue cases (15-18) can assert that skipping one
# damaged blob still loads every other blob in the same data directory. Its
# declared type is distinct from the first's, which is what lets the sidecar
# of the first be found on disk by content rather than by CID-hex file name.
BLOB2_TEXT='pds serve_e2e gate fixture blob bytes, the second'
BLOB2_MIME='application/x-e2e-second'
# A THIRD declared type, for case 4d's dribbled blob. It must differ from the
# first two for the same reason they differ from each other: `blob1_sidecar`
# finds a sidecar on disk by its declared type, and two blobs sharing one type
# would make that lookup pick either of them.
SLOW_MIME='application/x-e2e-slow'

# The session-token secret, which is NOT the repository signing key: the two
# are separate secrets by design, and this gate proves the server accepts a
# token minted from the one it was handed at `--token-secret`.
TOKEN_SECRET_HEX='7f1c0a6d2b93e45880ac31f6d5e27b04913ca8e6f27d4b51a03c8e19d6b4720f'

# The account password. It reaches the server in a FILE and never as an
# argument value: an argument is visible in `ps` output to every user on the
# box, which is why `pds/serve.mdk` takes `--password-file` and no
# `--password`. The trailing newline is deliberate — it is what every editor
# and `printf %s\n` leaves, and the server strips exactly one.
PASSWORD='s-sessions e2e gate password'

# The ONE service an `atproto-proxy` header may name on the proxy servers below,
# and a second DID no server here is configured for: the confused-deputy case is
# entirely about the difference between them.
APPVIEW_DID='did:web:appview.test'
ATTACKER_DID='did:web:attacker.example'
# The stub answers 203 rather than 200 deliberately. The status a proxied read
# returns must be the APPVIEW's, so a PDS that composed its own 200 around a
# forwarded body would pass a case expecting 200 and fails this one.
STUB_STATUS=203
TIMELINE='/xrpc/app.bsky.feed.getTimeline?limit=2'

DATA="$WORK/data"
mkdir -p "$DATA"
printf '%s\n' "$SECRET_HEX" > "$WORK/key.hex"
printf '%s\n' "$TOKEN_SECRET_HEX" > "$WORK/token.hex"
printf '%s\n' "$PASSWORD" > "$WORK/password"
# The server refuses a group- or world-readable signing key or session-token
# secret before it binds (case 25 below proves the refusal), so every hex
# secret this gate hands it is owner-only. `mktemp -d` already made $WORK 0700;
# these are the files inside it the server actually grades.
chmod 600 "$WORK/key.hex" "$WORK/token.hex"

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

# The same readiness contract as `wait_for_port`, for a stub appview: it binds
# port 0 and names the port the kernel gave it, so no case has to guess a free
# one. `$1` is the log of its stdout, `$2` the pid to watch.
wait_for_stub_port() {
  logfile=$1
  pid=$2
  i=0
  while [ "$i" -lt 100 ]; do
    if grep -F 'appview-stub: listening on 127.0.0.1:' "$logfile" >/dev/null 2>&1
    then
      sed -n 's/.*listening on 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$logfile" | head -1
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

# The same readiness contract, for the stub relay: `$1` is the log of its
# stdout, `$2` the pid to watch.
wait_for_crawl_stub_port() {
  logfile=$1
  pid=$2
  i=0
  while [ "$i" -lt 100 ]; do
    if grep -F 'crawl-stub: listening on 127.0.0.1:' "$logfile" >/dev/null 2>&1
    then
      sed -n 's/.*listening on 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$logfile" | head -1
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

# How many calls a stub appview has logged. The confused-deputy case turns on
# this count NOT moving, so it is read the same way before and after.
stub_calls() {
  if [ -f "$1" ]; then
    grep -c '^call ' "$1" || true
  else
    echo 0
  fi
}

start_server() {
  extra=$1
  outfile=$2
  errfile=$3
  # --password-file is only passed on genesis (--init): a resumed run finds
  # an existing credential, and passing --password-file against one now
  # gets refused (F1, #2604) rather than silently keeping the old password.
  pwflag=""
  if [ "$extra" = "--init" ]; then
    pwflag="--password-file $WORK/password"
  fi
  # shellcheck disable=SC2086 # $extra/$pwflag are single optional flags, no quoting needed
  "$WORK/pdsd" \
    --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
    --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
    $pwflag \
    --data "$DATA" --port 0 $extra \
    >"$outfile" 2>"$errfile" &
  SERVER_PID=$!
}

client() {
  "$WORK/client" "$@"
}

# The event-stream driver. A separate binary rather than more subcommands on
# `client`: nothing it does is an HTTP request/response exchange, so it shares
# neither that driver's response reader nor its request builders.
subclient() {
  "$WORK/subclient" "$@"
}

# ── first instance: genesis, then cases 1-8 ─────────────────────────────────

start_server --init "$WORK/serve1.out" "$WORK/serve1.err"
PORT1=$(wait_for_port "$WORK/serve1.out") || {
  cat "$WORK/serve1.err" >&2
  fail 'server did not report readiness'
}
require_empty "$WORK/serve1.err" 'server startup'

# One session for every write case below. The three record-write procedures
# are gated at the composition seam (#2604), so a write that presents no token
# is refused 401 before its handler runs.
#
# The token comes from `com.atproto.server.createSession` — the real login,
# against the password bootstrapped above — and no longer from a token minted
# beside the server. That is not a stylistic change: the seam now requires the
# token's SESSION to be open as well as its signature to verify, so a token
# this gate minted for itself would be refused, and rightly.
LOGIN=$(client login "$PORT1" "$HANDLE" "$PASSWORD") \
  || fail 'could not log in with the bootstrapped password'
TOKEN=${LOGIN%% *}
REFRESH=${LOGIN##* }
[ -n "$TOKEN" ] || fail 'createSession issued an empty access token'
[ -n "$REFRESH" ] || fail 'createSession issued an empty refresh token'
[ "$TOKEN" != "$REFRESH" ] \
  || fail 'createSession issued the same string as both tokens'

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

# 4b. a blob upload over the real socket, whose CID case 14 asks for back
#    from a FRESH process. This is what makes the blob half durable rather
#    than merely present: before this slice the transition moved nothing to
#    disk, because `persistTransition` looked only at the repository half.
BLOB_CID=$(client upload-blob "$PORT1" "$TOKEN" "$BLOB_MIME" "$BLOB_TEXT") \
  || fail 'case 4b: uploadBlob'
[ -n "$BLOB_CID" ] || fail 'case 4b: uploadBlob returned an empty CID'
client get-blob "$PORT1" "$DID" "$BLOB_CID" "$BLOB_MIME" "$BLOB_TEXT" \
  || fail 'case 4b: getBlob before the restart'

BLOB2_CID=$(client upload-blob "$PORT1" "$TOKEN" "$BLOB2_MIME" "$BLOB2_TEXT") \
  || fail 'case 4c: second uploadBlob'
[ -n "$BLOB2_CID" ] || fail 'case 4c: second uploadBlob returned an empty CID'
[ "$BLOB2_CID" != "$BLOB_CID" ] \
  || fail 'case 4c: the two blob fixtures content-addressed to one CID'

# 4d. a legitimately SLOW but progressing 5 MB upload still completes (#2815).
#    Case 7 (over-cap body) proves an over-cap body is REJECTED, which is a
#    different claim: this body is under every size cap, and it arrives over
#    several times the body phase's no-progress budget in pieces whose gaps each
#    stay inside it. So it fails against a body-phase bound that is a fixed
#    deadline rather than a progress budget, and it is what stops case 8c's
#    defense from being bought by narrowing what an upload is allowed to do.
#    The client grades the CID itself, against the bytes it meant to send, so a
#    body truncated at one of the gaps cannot pass by answering 200 to a shorter
#    blob. Costs real wall time: the gaps are the point.
client slow-upload "$PORT1" "$TOKEN" "$SLOW_MIME" \
  || fail 'case 4d: a slow but progressing upload did not complete'

# 5. every remaining route: the eight XRPC NSIDs no other case drives
#    (including listRepos/getRepoStatus, whose repo-bearing shape only exists
#    once case 4 has committed a write), plus /.well-known/did.json. With
#    cases 1, 4, and 9 that is all eleven NSIDs and both well-knowns proven
#    by this gate rather than by reading the registry.
client endpoints "$PORT1" "$TOKEN" "$DID" "$HANDLE" "$COLLECTION" "$RKEY" \
  || fail 'case 5: remaining endpoint coverage'

# 5b. the same write with NO token is refused 401 by the seam, over the real
#    socket — the in-process test proves the seam refuses, this proves the
#    running server does.
client unauthorized "$PORT1" "$DID" "$COLLECTION" "$RKEY" \
  || fail 'case 5b: unauthenticated write refused'

# 5c. the access token names its own account back.
client get-session "$PORT1" "$TOKEN" "$DID" || fail 'case 5c: getSession'

# 5d. a login with the wrong password is refused with atproto's own code, and
#    over the real socket. The in-process cells grade the refusal's shape;
#    this proves the running server produces it.
client login-refused "$PORT1" "$HANDLE" 'not the password' \
  || fail 'case 5d: wrong password refused'

# 11. the session lifecycle, end to end and over the socket: log in, write,
#    log out, and find the SAME access token refused afterwards. Its signature
#    is still good and its two-hour window is still open, so a server that
#    verified tokens statelessly would still accept it — this is the case that
#    tells a revocation apart from a promise of one.
LOGIN2=$(client login "$PORT1" "$HANDLE" "$PASSWORD") \
  || fail 'case 11: second login'
ACCESS2=${LOGIN2%% *}
REFRESH2=${LOGIN2##* }
client write "$PORT1" "$ACCESS2" "$DID" "$COLLECTION" 's-sessions-live-1' 200 \
  || fail 'case 11: write with a freshly issued access token'
client logout "$PORT1" "$REFRESH2" || fail 'case 11: deleteSession'
client write "$PORT1" "$ACCESS2" "$DID" "$COLLECTION" 's-sessions-live-2' 401 \
  || fail 'case 11: access token still accepted after deleteSession'

# 12. rotation, and the reuse of what it consumed. The refresh token that was
#    exchanged is refused from then on; the pair that replaced it works.
LOGIN3=$(client login "$PORT1" "$HANDLE" "$PASSWORD") \
  || fail 'case 12: third login'
REFRESH3=${LOGIN3##* }
ROTATED=$(client refresh "$PORT1" "$REFRESH3") || fail 'case 12: refreshSession'
ACCESS4=${ROTATED%% *}
REFRESH4=${ROTATED##* }
[ "$REFRESH4" != "$REFRESH3" ] \
  || fail 'case 12: refreshSession returned the token it was given'
client refresh-refused "$PORT1" "$REFRESH3" \
  || fail 'case 12: the consumed refresh token was accepted again'
client write "$PORT1" "$ACCESS4" "$DID" "$COLLECTION" 's-sessions-live-3' 200 \
  || fail 'case 12: write with the rotated access token'
client logout "$PORT1" "$REFRESH4" || fail 'case 12: logout of the rotated session'

# 6. malformed request -> 400, error path not a hang or crash
client malformed "$PORT1" || fail 'case 6: malformed request'

# 7. over-cap body -> rejected (413), not truncated or hung
client overcap "$PORT1" || fail 'case 7: over-cap body'

# 8. a connection that says nothing at all is closed by the server rather
#    than held. It is closed on the HEADER budget, not on idleTimeout: a peer
#    that has sent no bytes has not terminated a header section, and that is
#    the shorter of the two budgets it is under. Costs real wall time.
client idle "$PORT1" || fail 'case 8: idle timeout'

# 8b. #2772: 300 connections, one identity, headers never terminated and
#    never a byte more — and an unrelated caller is still ANSWERED. The
#    budget below is what makes this a test rather than a tautology: it sits
#    above the header budget an un-framed connection now gets and well below
#    the read and request budgets it used to get, so a server that charges
#    the un-framed state to nobody cannot pass it. The un-framed sockets are
#    held open for the whole of the attempt, and released only when the
#    client exits.
client unframed-flood "$PORT1" 300 15 \
  || fail 'case 8b: an unrelated caller went unanswered under an un-framed flood'

# 8c. #2815: the same claim as 8b one phase further on. 300 connections that
#    TERMINATE their headers and declare a large Content-Length leave the
#    un-framed census entirely, so the census 8b exercises defends nothing
#    here; what frees their slots is bodyProgressTimeout (5 s), the body
#    phase's no-progress budget. An unrelated caller must still be ANSWERED.
#    The 12 s budget is the discriminator: above the body progress budget and
#    far below the requestTimeout (60 s) a declared-but-unsent body used to be
#    granted, so a server that bounds the body phase only by the whole
#    request's budget cannot pass it. Case 4d is the other half — the same
#    budget must not close a body that keeps arriving.
client body-stall-flood "$PORT1" 300 12 \
  || fail 'case 8c: an unrelated caller went unanswered under a stalled-body flood'

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

# 14. the blob written before the restart is served, byte for byte and under
#    its DECLARED media type, by the fresh process over the same --data dir.
client get-blob "$PORT2" "$DID" "$BLOB_CID" "$BLOB_MIME" "$BLOB_TEXT" \
  || fail 'case 14: blob did not survive the restart'
client get-blob "$PORT2" "$DID" "$BLOB2_CID" "$BLOB2_MIME" "$BLOB2_TEXT" \
  || fail 'case 14: second blob did not survive the restart'

# The blob is on disk beside the repository's blocks, not inside them: a blob
# is not part of the signed block graph and must never reach `repoFromBlocks`.
[ -d "$DATA/blobs" ] || fail 'case 14: no blobs directory beneath --data'

# 33a. the ONLINE half of the backup/restore rehearsal (#2613), taken while this
#    server is still up: the repository serialized through the server's own
#    request path, which IS the path every write is serialized against. The
#    digest recorded here is what the restored copy below has to reproduce.
ORIGINAL_REPO=$(client repo-digest "$PORT2" "$DID") \
  || fail 'case 33: sync.getRepo against the original server'
[ -n "$ORIGINAL_REPO" ] \
  || fail 'case 33: the original server exported an empty getRepo digest'

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve2.err" 'resumed server (post-run)'

# ── residue on disk: a damaged blob is skipped, never a refused startup ────
# Cases 15-18 each start a server over a COPY of the resumed data directory
# with one kind of residue introduced by hand. The claim in all four is the
# same: the server starts, the damaged blob is absent rather than
# half-recovered, and the OTHER blob in the same directory is served intact.

# The first fixture's MIME sidecar on disk, found by its declared type (the
# two fixtures declare different ones) rather than by its CID-hex file name.
blob1_sidecar() {
  grep -l -F -x "$BLOB_MIME" "$1"/blobs/*/*.mime 2>/dev/null | head -1
}

# start_resume_with <data> <key file> <token-secret file> <out> <err>: a resumed
# run (no --init) over that data directory, on those two secret files. Case 33
# runs one on RESTORED copies of all three, so neither secret can be the
# original by default.
start_resume_with() {
  "$WORK/pdsd" \
    --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
    --key "$2" --token-secret "$3" \
    --data "$1" --port 0 \
    >"$4" 2>"$5" &
  SERVER_PID=$!
}

start_resume_at() {
  start_resume_with "$1" "$WORK/key.hex" "$WORK/token.hex" "$2" "$3"
}

# residue_case <label> <data dir> <served|skipped>: start over that directory,
# grade the first blob as still served or as skipped, and require the second
# blob to be served either way.
residue_case() {
  label=$1
  data=$2
  first=$3
  start_resume_at "$data" "$WORK/$label.out" "$WORK/$label.err"
  rport=$(wait_for_port "$WORK/$label.out") || {
    cat "$WORK/$label.err" >&2
    fail "$label: server did not start over a data directory holding residue"
  }
  require_empty "$WORK/$label.err" "$label startup"
  if [ "$first" = served ]; then
    client get-blob "$rport" "$DID" "$BLOB_CID" "$BLOB_MIME" "$BLOB_TEXT" \
      || fail "$label: the intact first blob was not served"
  else
    client get-blob-missing "$rport" "$DID" "$BLOB_CID" \
      || fail "$label: the damaged first blob was not skipped"
  fi
  client get-blob "$rport" "$DID" "$BLOB2_CID" "$BLOB2_MIME" "$BLOB2_TEXT" \
    || fail "$label: the undamaged second blob was not served"
  # Serving the requests above needs a live process, but say so explicitly:
  # the panic this guards against (an unvalidated sidecar reaching a response
  # header) kills the process rather than answering an error.
  kill -0 "$SERVER_PID" 2>/dev/null \
    || fail "$label: the server died while answering (a panic, not a refusal)"
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
  require_empty "$WORK/$label.err" "$label (post-run)"
  echo "$label: started over residue, damaged blob $first, other blob intact"
}

# 15. a stray NON-DIRECTORY entry directly under `<data>/blobs` — an editor
#    swapfile, a `.DS_Store` — is residue outside this module's business, not
#    an unreadable shard directory that must kill the startup (#2572).
DATA15="$WORK/data15"
cp -R "$DATA" "$DATA15"
touch "$DATA15/blobs/.DS_Store"
residue_case case15 "$DATA15" served

# 16. the REVERSE torn write: a blob's bytes were promoted and its sidecar was
#    not, so the declared type the bytes need is gone. That one blob is
#    skipped; it does not brick every restart from then on.
DATA16="$WORK/data16"
cp -R "$DATA" "$DATA16"
SIDECAR16=$(blob1_sidecar "$DATA16")
[ -n "$SIDECAR16" ] || fail 'case 16: could not find the first blob sidecar'
rm "$SIDECAR16"
residue_case case16 "$DATA16" skipped

# 17. a sidecar whose text is not a MIME type at all — a raw control byte,
#    which `makeHeader` refuses and which must never reach the `Store` to be
#    refused there. Reachable only by tampering with the disk directly; the
#    upload path admits no such value.
DATA17="$WORK/data17"
cp -R "$DATA" "$DATA17"
SIDECAR17=$(blob1_sidecar "$DATA17")
[ -n "$SIDECAR17" ] || fail 'case 17: could not find the first blob sidecar'
printf 'text/pl\001ain' > "$SIDECAR17"
residue_case case17 "$DATA17" skipped

# 18. the FORWARD torn write, unchanged by any of the above: a sidecar with no
#    bytes file names no blob, so it is skipped exactly as it always was.
DATA18="$WORK/data18"
cp -R "$DATA" "$DATA18"
SIDECAR18=$(blob1_sidecar "$DATA18")
[ -n "$SIDECAR18" ] || fail 'case 18: could not find the first blob sidecar'
rm "${SIDECAR18%.mime}"
residue_case case18 "$DATA18" skipped

# ── a RESTORED --data dir: the backup/restore rehearsal (#2613) ────────────
# 33. A backup is taken, a SEPARATE data directory is restored from it, and a
#    server is started on the restored copy. What that server exports from
#    `com.atproto.sync.getRepo` must byte-match what the original exported
#    (33a, captured above while the original was still running), both blobs
#    must come back under their declared types, and the restored copy must be
#    a LIVE server rather than a readable museum piece.
#
#    The copy is taken with the process DOWN, which is the procedure
#    `docs/ops/PDS-DEPLOY.md` § "Backup and restore" documents and the answer
#    this tree gives to the torn-copy question: `applyRequest`'s write
#    serialization is a single `liftIO` in a cooperatively scheduled process,
#    not a lock an external `cp` can take.
BACKUP="$WORK/backup"
mkdir -p "$BACKUP"
cp -R "$DATA" "$BACKUP/data"
cp "$WORK/key.hex" "$BACKUP/key.hex"
cp "$WORK/token.hex" "$BACKUP/token.hex"

# The restore is a THIRD location, not the backup read in place: restoring over
# the backup would leave the rehearsal with nothing to fall back to, and it is
# the restored copy's own files this case grades.
RESTORED="$WORK/restored"
RESTORED_KEY="$WORK/restored-key.hex"
RESTORED_TOKEN="$WORK/restored-token.hex"
cp -R "$BACKUP/data" "$RESTORED"
cp "$BACKUP/key.hex" "$RESTORED_KEY"
cp "$BACKUP/token.hex" "$RESTORED_TOKEN"
# A restore has to reproduce the MODES as well as the bytes: `pds serve` refuses
# a hex secret file any other account can read, so a restore that widened one
# does not start at all. `cp -R` is not `cp -a`; the procedure in the ops doc
# preserves modes, and this re-asserts them rather than assuming the copy did.
chmod 600 "$RESTORED_KEY" "$RESTORED_TOKEN"
if [ -f "$RESTORED/credential" ]; then
  chmod 600 "$RESTORED/credential"
fi
if [ -f "$RESTORED/session-secret" ]; then
  chmod 600 "$RESTORED/session-secret"
fi

# The original directory must come out of this untouched — the restored server
# is a second server over its own files, not a second handle on these.
ORIGINAL_HEAD=$(cksum "$DATA/head")

start_resume_with "$RESTORED" "$RESTORED_KEY" "$RESTORED_TOKEN" \
  "$WORK/serve33.out" "$WORK/serve33.err"
PORT33=$(wait_for_port "$WORK/serve33.out") || {
  cat "$WORK/serve33.err" >&2
  fail 'case 33: the restored server did not report readiness'
}
require_empty "$WORK/serve33.err" 'case 33 restored server startup'

RESTORED_REPO=$(client repo-digest "$PORT33" "$DID") \
  || fail 'case 33: sync.getRepo against the restored server'
[ "$RESTORED_REPO" = "$ORIGINAL_REPO" ] \
  || fail "case 33: the restored server's getRepo export is '$RESTORED_REPO', the original's was '$ORIGINAL_REPO'"

# Blobs are not in the CAR — they live beside the block graph — so the export
# match above says nothing about them. Both, byte for byte, under their
# DECLARED types, from the restored copy.
client get-blob "$PORT33" "$DID" "$BLOB_CID" "$BLOB_MIME" "$BLOB_TEXT" \
  || fail 'case 33: the first blob did not survive the restore'
client get-blob "$PORT33" "$DID" "$BLOB2_CID" "$BLOB2_MIME" "$BLOB2_TEXT" \
  || fail 'case 33: the second blob did not survive the restore'

# The restored copy is a working server, not just a readable one: the account
# password still logs in (the credential was part of the backup) and a new
# signed commit is accepted on the restored signing key. That write also makes
# the digest comparison above non-vacuous — the export is a function of the
# repository's contents, so it MUST move when a record is added.
RESTORED_LOGIN=$(client login "$PORT33" "$HANDLE" "$PASSWORD") \
  || fail 'case 33: the account password does not log in against the restored copy'
RESTORED_ACCESS=${RESTORED_LOGIN%% *}
client write "$PORT33" "$RESTORED_ACCESS" "$DID" "$COLLECTION" 'restored-1' 200 \
  || fail 'case 33: the restored copy refused a new write'
AFTER_WRITE_REPO=$(client repo-digest "$PORT33" "$DID") \
  || fail 'case 33: sync.getRepo after the write to the restored copy'
[ "$AFTER_WRITE_REPO" != "$RESTORED_REPO" ] \
  || fail 'case 33: a new record did not change the export digest (the match above proves nothing)'

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve33.err" 'case 33 restored server (post-run)'

[ "$(cksum "$DATA/head")" = "$ORIGINAL_HEAD" ] \
  || fail 'case 33: the restored server wrote into the ORIGINAL data directory'
echo "case 33: restored from backup, getRepo export byte-identical ($RESTORED_REPO), both blobs intact, restored copy writable"

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
chmod 600 "$WORK/key10a.hex" "$WORK/key10b.hex"

"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key10a.hex" --password-file "$WORK/password" \
  --data "$DATA10" --port 0 --init \
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

# 13. first-run bootstrap, observed on the one server this gate starts with
#    no --token-secret: it generates its own session secret and keeps it in
#    the data directory, alongside the credential it derived from the password
#    file. BOTH are owner-only, 0600 — that is the property, not the mere
#    existence of the files, and the umask this gate happens to run under must
#    not be able to widen either of them.
[ -f "$DATA10/session-secret" ] \
  || fail 'case 13: first run did not generate a session secret'
[ -f "$DATA10/credential" ] \
  || fail 'case 13: first run did not store an account credential'
require_owner_only "$DATA10/session-secret" 'case 13: generated session secret'
require_owner_only "$DATA10/credential" 'case 13: stored credential'
GENERATED_SECRET=$(cat "$DATA10/session-secret")
if grep -F "$GENERATED_SECRET" "$WORK/serve10a.err" >/dev/null 2>&1; then
  fail 'case 13: the generated secret reached the server output'
fi
if grep -F "$PASSWORD" "$WORK/serve10a.err" "$WORK/serve10a.out" >/dev/null 2>&1
then
  fail 'case 13: the account password reached the server output'
fi
# The generated secret is 32 bytes as hex, and it is not the fixed one this
# gate hands the other server: a "generated" secret that was a constant would
# pass every other check here.
[ ${#GENERATED_SECRET} -eq 64 ] \
  || fail 'case 13: the generated session secret is not 32 bytes of hex'
[ "$GENERATED_SECRET" != "$TOKEN_SECRET_HEX" ] \
  || fail 'case 13: the generated session secret is a hardcoded constant'

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
  --key "$WORK/key10b.hex" --password-file "$WORK/password" \
  --data "$DATA10" --port 0 --init \
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

# ── fifth and sixth --data dirs: secrets at rest (#2611, #2659 item 4) ─────

# Runs pdsd to completion (it must NOT bind) with the flags given, and stores
# the exit code in RC. A refusal that instead started serving would hang a
# plain synchronous run, so this bounds the wait the way case 10 does.
run_until_exit() {
  outfile=$1
  errfile=$2
  shift 2
  "$WORK/pdsd" "$@" >"$outfile" 2>"$errfile" &
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
    fail 'a run that had to refuse is still running — it bound and is serving'
  fi
  RC=0
  wait "$SERVER_PID" 2>/dev/null || RC=$?
  SERVER_PID=""
}

# 25. a --key file any other account on the box can read is refused BEFORE the
#    listener binds. The exit status alone would also be produced by a
#    malformed DID or an unreadable file, so this asserts the refusal's own
#    identity — its message — and that the readiness line never appeared.
DATA25="$WORK/data25"
mkdir -p "$DATA25"
cp "$WORK/key.hex" "$WORK/key25.hex"
chmod 644 "$WORK/key25.hex"
run_until_exit "$WORK/serve25.out" "$WORK/serve25.err" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key25.hex" --password-file "$WORK/password" \
  --data "$DATA25" --port 0 --init
[ "$RC" -ne 0 ] || fail 'case 25: a 0644 signing key was accepted'
grep -F "signing key $WORK/key25.hex is mode 0644, readable by accounts other than its owner" \
  "$WORK/serve25.err" >/dev/null \
  || fail 'case 25: the refusal did not name the mode and the path'
if grep -F 'serve: listening on' "$WORK/serve25.out" >/dev/null 2>&1; then
  fail 'case 25: the listener bound before the key was graded'
fi
if grep -F "$SECRET_HEX" "$WORK/serve25.err" >/dev/null 2>&1; then
  fail 'case 25: the refusal printed the signing key itself'
fi

# 26. a configuration rejected for a bad SUPPLIED secret leaves no GENERATED
#    one on disk (#2659 item 4). The password file is empty, so the run is
#    refused; before the fix the session secret had already been generated and
#    written by then, and the next run would have adopted a secret nobody
#    asked for from a directory the operator believes is unconfigured.
DATA26="$WORK/data26"
mkdir -p "$DATA26"
: > "$WORK/password26"
run_until_exit "$WORK/serve26.out" "$WORK/serve26.err" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --password-file "$WORK/password26" \
  --data "$DATA26" --port 0 --init
[ "$RC" -ne 0 ] || fail 'case 26: an empty password file was accepted'
[ ! -e "$DATA26/session-secret" ] \
  || fail 'case 26: a failed configuration left a generated session secret behind'
[ ! -e "$DATA26/credential" ] \
  || fail 'case 26: a failed configuration left a credential behind'

# 27. a --token-secret with no entropy in it is refused before the bind.
#    Thirty-two zero bytes is a well-formed 32-byte hex secret at mode 0600,
#    so every check that came before this one passes it; what refuses it is
#    that every session token the server issued would be forgeable from a
#    public constant. The exit status alone is also what a malformed DID
#    produces, so this asserts the refusal's own message.
DATA27="$WORK/data27"
mkdir -p "$DATA27"
ZERO_SECRET_HEX='0000000000000000000000000000000000000000000000000000000000000000'
printf '%s\n' "$ZERO_SECRET_HEX" > "$WORK/token27.hex"
chmod 600 "$WORK/token27.hex"
run_until_exit "$WORK/serve27.out" "$WORK/serve27.err" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token27.hex" \
  --password-file "$WORK/password" --data "$DATA27" --port 0 --init
[ "$RC" -ne 0 ] || fail 'case 27: a 32-zero-byte session-token secret was accepted'
grep -F "session-token secret $WORK/token27.hex is a constant or near-constant value" \
  "$WORK/serve27.err" >/dev/null \
  || fail 'case 27: the refusal did not name the constant session-token secret'
if grep -F 'serve: listening on' "$WORK/serve27.out" >/dev/null 2>&1; then
  fail 'case 27: the listener bound before the session-token secret was graded'
fi
[ ! -e "$DATA27/session-secret" ] \
  || fail 'case 27: the refused run left a generated session secret behind'

# 28. `pds keygen` writes the secrets `serve` will not generate, at a mode
#    `serve` will read back. A key written any wider would be refused by case
#    25's own check on the next start, so the mode is asserted here directly.
KEYGEN_DIR="$WORK/keygen"
mkdir -p "$KEYGEN_DIR"
"$WORK/pdsd" keygen --key "$KEYGEN_DIR/key.hex" \
  --token-secret "$KEYGEN_DIR/token.hex" \
  > "$WORK/keygen.out" 2> "$WORK/keygen.err" \
  || {
    cat "$WORK/keygen.err" >&2
    fail 'case 28: keygen exited nonzero'
  }
require_empty "$WORK/keygen.err" 'case 28 keygen'
require_owner_only "$KEYGEN_DIR/key.hex" 'case 28: generated signing key'
require_owner_only "$KEYGEN_DIR/token.hex" 'case 28: generated session-token secret'
grep -E -q '^keygen: did:key did:key:zQ3s[1-9A-HJ-NP-Za-km-z]+$' "$WORK/keygen.out" \
  || fail 'case 28: keygen did not report a secp256k1 did:key'
grep -E -q '^keygen: public key 0[23][0-9a-f]{64}$' "$WORK/keygen.out" \
  || fail 'case 28: keygen did not report a compressed public key'
# The scalar reaches its file and nothing else: what keygen printed must not
# contain the bytes it wrote.
KEYGEN_SECRET=$(tr -d '\n' < "$KEYGEN_DIR/key.hex")
if grep -F "$KEYGEN_SECRET" "$WORK/keygen.out" "$WORK/keygen.err" >/dev/null 2>&1; then
  fail 'case 28: keygen printed the signing key it generated'
fi
# A second run over the same path must refuse rather than destroy the key.
"$WORK/pdsd" keygen --key "$KEYGEN_DIR/key.hex" \
  > "$WORK/keygen2.out" 2> "$WORK/keygen2.err" \
  && fail 'case 28: keygen overwrote an existing signing key'
# Exactly one `keygen:` prefix: the wrapper in `pds/serve.mdk` adds it, so a
# message that also carries its own reads `keygen: keygen refuses ...`.
grep -F "keygen: refusing $KEYGEN_DIR/key.hex" "$WORK/keygen2.err" >/dev/null \
  || fail 'case 28: the overwrite refusal did not name the path'
grep -E -q '^keygen: keygen' "$WORK/keygen2.err" \
  && fail 'case 28: the refusal carries a doubled keygen: prefix'
[ "$(tr -d '\n' < "$KEYGEN_DIR/key.hex")" = "$KEYGEN_SECRET" ] \
  || fail 'case 28: the refused second keygen changed the key on disk'
# A run that names one new destination and one that already exists must write
# NEITHER. Refusing after the first write would leave a valid 0600 signing key
# on disk under a failure exit code, and the operator has no way to tell that
# half-finished state from a run that wrote nothing.
"$WORK/pdsd" keygen --key "$KEYGEN_DIR/fresh.hex" \
  --token-secret "$KEYGEN_DIR/token.hex" \
  > "$WORK/keygen3.out" 2> "$WORK/keygen3.err" \
  && fail 'case 28: keygen accepted an existing --token-secret destination'
[ ! -e "$KEYGEN_DIR/fresh.hex" ] \
  || fail 'case 28: keygen left a signing key behind after refusing the run'
# 28b. and what keygen wrote is what serve accepts: a whole genesis server
#    stands up on the generated key and the generated token secret, which is
#    the only proof that keygen and serve agree on the file format and mode.
DATA28="$WORK/data28"
mkdir -p "$DATA28"
"$WORK/pdsd" --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$KEYGEN_DIR/key.hex" --token-secret "$KEYGEN_DIR/token.hex" \
  --password-file "$WORK/password" --data "$DATA28" --port 0 --init \
  > "$WORK/serve28.out" 2> "$WORK/serve28.err" &
SERVER_PID=$!
PORT28=$(wait_for_port "$WORK/serve28.out") \
  || fail 'case 28b: a server on the generated key did not report readiness'
require_empty "$WORK/serve28.err" 'case 28b startup'
client login "$PORT28" "$HANDLE" "$PASSWORD" >/dev/null \
  || fail 'case 28b: login against a server on the generated key'
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# 29. the login rehash (#2659 item 2): a credential written at an older
#    iteration count is re-derived onto today's on ONE SUCCESSFUL login, and a
#    FAILED login leaves the record exactly as it was. The stored record's
#    first line is its iteration count, so the file itself is the assertion.
#
#    The old-count record cannot be forged by editing that first line — the
#    derived key is a function of the count — so the client derives a real one
#    at a lower count (`credential-at`), which is the state a data directory
#    bootstrapped before the count moved is in.
DATA29="$WORK/data29"
mkdir -p "$DATA29"
"$WORK/pdsd" --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --password-file "$WORK/password" --data "$DATA29" --port 0 --init \
  > "$WORK/serve29a.out" 2> "$WORK/serve29a.err" &
SERVER_PID=$!
wait_for_port "$WORK/serve29a.out" >/dev/null \
  || fail 'case 29: the bootstrap server did not report readiness'
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
SHIPPED_ITERATIONS=$(head -1 "$DATA29/credential")
OLD_ITERATIONS=$((SHIPPED_ITERATIONS / 2))
[ "$OLD_ITERATIONS" -ge 1 ] || fail 'case 29: the shipped iteration count is too low to halve'
client credential-at "$OLD_ITERATIONS" "$PASSWORD" > "$WORK/credential29.old" \
  || fail 'case 29: the client could not derive an old-count credential'
[ "$(head -1 "$WORK/credential29.old")" = "$OLD_ITERATIONS" ] \
  || fail 'case 29: the derived credential does not name the old count'
cp "$WORK/credential29.old" "$DATA29/credential"
chmod 600 "$DATA29/credential"
"$WORK/pdsd" --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATA29" --port 0 \
  > "$WORK/serve29b.out" 2> "$WORK/serve29b.err" &
SERVER_PID=$!
PORT29B=$(wait_for_port "$WORK/serve29b.out") \
  || fail 'case 29: the resumed server did not report readiness'
client login-refused "$PORT29B" "$HANDLE" 'not the account password' \
  || fail 'case 29: a wrong password was not refused'
cmp "$WORK/credential29.old" "$DATA29/credential" \
  || fail 'case 29: a FAILED login rewrote the stored credential'
client login "$PORT29B" "$HANDLE" "$PASSWORD" >/dev/null \
  || fail 'case 29: the login that should migrate the credential failed'
[ "$(head -1 "$DATA29/credential")" = "$SHIPPED_ITERATIONS" ] \
  || fail 'case 29: one successful login did not re-derive at the shipped count'
require_owner_only "$DATA29/credential" 'case 29: the re-derived credential'
client login "$PORT29B" "$HANDLE" "$PASSWORD" >/dev/null \
  || fail 'case 29: the migrated credential does not verify the same password'
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve29b.err" 'case 29 resumed server'

# ── fourth, independent --data dirs: the bind refusal (#2606, #2757) ───────
# `--bind` other than the loopback default is refused unless
# `--trusted-proxy` is also given: this process cannot verify a peer's
# identity on its own (no getpeername-equivalent extern), so the flag is an
# operator assertion the refusal makes mandatory rather than optional.

# 30. non-loopback with NO auth: --trusted-proxy IS set, so the bind check
#    passes, and what actually refuses the run is the ALREADY-unconditional
#    credential requirement (A1: no --password-file and no existing
#    credential in a fresh --data dir) — this asserts THAT diagnostic, not
#    an invented bind-specific one, and that the bind-specific message did
#    NOT fire instead.
DATA30="$WORK/data30"
mkdir -p "$DATA30"
run_until_exit "$WORK/serve30.out" "$WORK/serve30.err" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATA30" --port 0 --bind 0.0.0.0 --trusted-proxy --init
[ "$RC" -ne 0 ] \
  || fail 'case 30: a non-loopback bind with no account credential was accepted'
grep -F 'no account credential' "$WORK/serve30.err" >/dev/null \
  || fail 'case 30: the refusal was not the existing missing-credential diagnostic'
if grep -F 'trusted-proxy' "$WORK/serve30.err" >/dev/null 2>&1; then
  fail 'case 30: the bind-specific refusal fired instead of the credential one'
fi
if grep -F 'serve: listening on' "$WORK/serve30.out" >/dev/null 2>&1; then
  fail 'case 30: the listener bound before the credential was graded'
fi

# 31. non-loopback WITH auth (a --password-file is given, bootstrapping a
#    credential) but no --trusted-proxy: refused by the NEW bind-specific
#    diagnostic, before the credential or session secret reach disk.
DATA31="$WORK/data31"
mkdir -p "$DATA31"
run_until_exit "$WORK/serve31.out" "$WORK/serve31.err" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --password-file "$WORK/password" --data "$DATA31" --port 0 \
  --bind 0.0.0.0 --init
[ "$RC" -ne 0 ] \
  || fail 'case 31: a non-loopback bind with no --trusted-proxy was accepted'
grep -F 'refusing to bind 0.0.0.0: a non-loopback bind requires --trusted-proxy' \
  "$WORK/serve31.err" >/dev/null \
  || fail 'case 31: the refusal did not name the bind address and the remedy'
if grep -F 'serve: listening on' "$WORK/serve31.out" >/dev/null 2>&1; then
  fail 'case 31: the listener bound before the bind was graded'
fi
[ ! -e "$DATA31/session-secret" ] \
  || fail 'case 31: a refused non-loopback bind left a generated session secret behind'
[ ! -e "$DATA31/credential" ] \
  || fail 'case 31: a refused non-loopback bind left a generated credential behind'

# 32. the accepted combination: non-loopback bind + --trusted-proxy + a real
#    credential actually binds and serves. The client still connects over
#    127.0.0.1 (its only address), which 0.0.0.0 accepts along with every
#    other interface, so this proves the bind took rather than merely that
#    the refusal didn't fire.
DATA32="$WORK/data32"
mkdir -p "$DATA32"
"$WORK/pdsd" --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --password-file "$WORK/password" --data "$DATA32" --port 0 \
  --bind 0.0.0.0 --trusted-proxy --init \
  >"$WORK/serve32.out" 2>"$WORK/serve32.err" &
SERVER_PID=$!
i=0
while [ "$i" -lt 100 ]; do
  if grep -F 'serve: listening on 0.0.0.0:' "$WORK/serve32.out" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$WORK/serve32.err" >&2
    fail 'case 32: the accepted combination did not report readiness'
  fi
  i=$((i + 1))
  sleep 0.1
done
require_empty "$WORK/serve32.err" 'case 32 startup'
PORT32=$(sed -n 's/.*listening on 0\.0\.0\.0:\([0-9]*\).*/\1/p' "$WORK/serve32.out" | head -1)
[ -n "$PORT32" ] || fail 'case 32: could not read the bound port'
client login "$PORT32" "$HANDLE" "$PASSWORD" >/dev/null \
  || fail 'case 32: login against the non-loopback bind failed'
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve32.err" 'case 32 (post-run)'

# ── a dedicated --data dir: the event stream (#2891, #1697) ───────────────
# `com.atproto.sync.subscribeRepos` gets a server of its own rather than
# riding on the first instance, for two reasons that are both about isolation
# rather than tidiness: the ceiling case below holds 32 connections open at
# once and would otherwise spend the first instance's per-identity connection
# budget, and every cursor case is graded against exact SEQUENCE NUMBERS, so
# it needs an event log nothing else has written to.

DATASUB="$WORK/data-subscribe"
mkdir -p "$DATASUB"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --password-file "$WORK/password" \
  --data "$DATASUB" --port 0 --init \
  >"$WORK/servesub.out" 2>"$WORK/servesub.err" &
SERVER_PID=$!
PORTSUB=$(wait_for_port "$WORK/servesub.out") || {
  cat "$WORK/servesub.err" >&2
  fail 'subscription server did not report readiness'
}
require_empty "$WORK/servesub.err" 'subscription server startup'

SUBLOGIN=$(client login "$PORTSUB" "$HANDLE" "$PASSWORD") \
  || fail 'case 34: login against the subscription server'
SUBACCESS=${SUBLOGIN%% *}

# 34. the live stream: a subscription opened with no cursor receives the
#    events of writes made AFTER it opened, in order. Two writes, not one —
#    a stream that delivered its first event and then stopped tailing would
#    pass a one-event case, and the consecutive sequence numbers are what
#    show the second arrived as a new event rather than as a replay.
#    This also plants events 1 and 2, which every cursor case below is
#    graded against.
subclient live "$PORTSUB" "$SUBACCESS" "$DID" "$COLLECTION" sublive \
  || fail 'case 34: live event delivery'

# 35. a cursor naming an event this server has never emitted is REFUSED, by
#    atproto's own name for it. Silence and a replay of something else are
#    both wrong answers that a status-only assertion would accept.
subclient future-cursor "$PORTSUB" 9999 \
  || fail 'case 35: a future cursor was not refused'

# 36. a cursor at exactly the newest delivered event replays NOTHING and then
#    receives the next live event once: no duplicate of what the cursor
#    named, no gap over what followed it. The silence is graded BEFORE the
#    write, so a duplicate cannot hide behind the live event. Plants event 3.
subclient exact-cursor "$PORTSUB" 2 "$SUBACCESS" "$DID" "$COLLECTION" subexact \
  || fail 'case 36: a cursor at the newest delivered event'

# 37. a cursor whose next events have left the retention window is answered
#    `#info` `OutdatedCursor` and then replayed from what the log still
#    holds — the subscriber learns it has a gap rather than inferring one.
#    The window is emptied by hand, the way cases 15-18 introduce blob
#    residue by hand: `eventLogSweep` drops entries by AGE, so no drivable
#    sequence of requests can put a log this young into that state.
rm "$DATASUB"/events/entries/0000000000000001-* \
  || fail 'case 37: could not find the first event entry'
rm "$DATASUB"/events/entries/0000000000000002-* \
  || fail 'case 37: could not find the second event entry'
subclient outdated-cursor "$PORTSUB" 0 \
  || fail 'case 37: an outdated cursor was not told it has a gap'

# 38. #2816 one shape further on: a subscription is held open by design and
#    is reaped by no timeout, so without a ceiling of its own it is a denial
#    strictly cheaper than the un-framed flood case 8b already defends
#    against. Open `maxConcurrentSubscriptions` of them from one identity,
#    hold them silent, and require BOTH halves: the next attempt refused
#    cheaply (an ordinary HTTP error, never a completed upgrade) and an
#    ordinary route still ANSWERED on a fresh connection. The second half is
#    the claim that matters — a ceiling that shut the server down instead of
#    the attempt that crossed it would pass the first half alone.
subclient ceiling "$PORTSUB" 32 "$DID" \
  || fail 'case 38: the subscription ceiling did not bound one identity cheaply'

# 39. a subscriber silent for longer than `requestTimeout` (60s) is still
#    there afterwards. The 70s hold is the discriminator and is why this
#    case costs real wall time: a subscription still governed by the request
#    lifecycle is reaped during it, and the write afterwards then reaches
#    nobody. `writeTimeout` is unaffected and still bounds every event write.
subclient hold "$PORTSUB" 70 "$SUBACCESS" "$DID" "$COLLECTION" subhold \
  || fail 'case 39: a long-held subscriber was reaped'

# 40. RFC 6455 §5.4: a data message split across continuation frames is
#    REASSEMBLED. A completed message is still ignored — a subscriber has
#    nothing this lexicon can read — so the observable is that the connection
#    is neither closed nor wedged behind the fragments, which the ping after
#    them grades.
subclient fragment "$PORTSUB" \
  || fail 'case 40: a fragmented client message was not reassembled'

# 41. §5.4's two orderings that are protocol VIOLATIONS, each 1002. They are
#    invisible to a reader that handles one frame at a time and forgets it,
#    which is what makes them the discriminator for case 40's state: a server
#    that merely ignored every data frame would pass case 40 and neither of
#    these.
subclient stray-continuation "$PORTSUB" \
  || fail 'case 41a: a continuation frame with nothing open was not refused'
subclient overlapped-message "$PORTSUB" \
  || fail 'case 41b: a data frame inside an open message was not refused'

# 42. The ceiling reassembly needs and a per-FRAME bound cannot supply: every
#    frame here is inside `maxClientFrameBytes` and the message they build is
#    not, which is the shape that grows a buffer without bound. 1009.
subclient oversize-message "$PORTSUB" \
  || fail 'case 42: an unbounded reassembled message was not refused'

# 43. §5.5.1's close handshake: the code the peer sent is the code it is
#    answered with (3000, an application code the wire permits), and a close
#    payload that does not parse is 1002 — not a normal close, and not the
#    unparsable value echoed back.
subclient close-echo "$PORTSUB" 3000 \
  || fail 'case 43a: the client close code was not echoed'
subclient close-malformed "$PORTSUB" \
  || fail 'case 43b: a malformed close payload was not answered 1002'

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/servesub.err" 'subscription server (post-run)'

# ── fifth, independent --data dir: rate limiting (#2612) ───────────────────
# `--trusted-proxy` is also on here — every case in that block above the
# rate-limit one runs the untrusted, single-bucket identity path, and this
# is the one place that needs two DISTINCT identities to prove a limit
# refuses one without refusing the other.

DATARL="$WORK/data-ratelimit"
mkdir -p "$DATARL"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --password-file "$WORK/password" \
  --data "$DATARL" --port 0 --init --trusted-proxy \
  >"$WORK/serverl.out" 2>"$WORK/serverl.err" &
SERVER_PID=$!
PORTRL=$(wait_for_port "$WORK/serverl.out") || {
  cat "$WORK/serverl.err" >&2
  fail 'rate-limit server did not report readiness'
}
require_empty "$WORK/serverl.err" 'rate-limit server startup'

RLLOGIN=$(client login "$PORTRL" "$HANDLE" "$PASSWORD") || fail 'case 19: rate-limit login'
RLACCESS=${RLLOGIN%% *}

# Every class below is windowed by the ABSOLUTE Unix-epoch minute
# (`now / rateLimitWindowSeconds`, `pds/lib/ratelimit.mdk`), not by when
# this gate happened to start driving it — a flood begun near a window
# boundary can cross it mid-flight and silently observe a fresh budget
# instead of the ceiling, which reads as "the ceiling does not refuse".
# Called before each group of cases below, not once for all of them: a group
# that starts 50s into the window is the hazard, whichever group it is.
wait_for_window_room() {
  i=0
  while [ "$(($(date +%s) % 60))" -gt 20 ] && [ "$i" -lt 600 ]; do
    i=$((i + 1))
    sleep 0.1
  done
}

wait_for_window_room

# 19. connections class: one identity opens one connection past its ceiling
#    and is refused 429 carrying the RateLimit-* headers and RateLimitExceeded;
#    a SECOND identity, still under budget in the same window, is served
#    normally right afterward — proving the ceiling is per-identity, not a
#    blanket refusal (the check that actually matters here).
client rl-conn "$PORTRL" 203.0.113.1 121 429 \
  || fail 'case 19: connections class did not refuse at its ceiling'
client rl-conn "$PORTRL" 203.0.113.2 1 200 \
  || fail "case 19: a second identity was refused by the first one's ceiling"

# 20. requests class, same shape, one connection per identity reused across
#    every request sent on it.
client rl-req "$PORTRL" 203.0.113.11 3001 429 \
  || fail 'case 20: requests class did not refuse at its ceiling'
client rl-req "$PORTRL" 203.0.113.12 1 200 \
  || fail "case 20: a second identity was refused by the first one's ceiling"

# 21. writes class: createRecord is rate-limited independently of the plain
#    requests ceiling above it. The ceiling driven here is the shipped
#    `maxWritesPerWindow`, not a gate-scoped override — there is none. It is
#    low enough that a real signed write's cost (MST update, commit signing,
#    disk persistence) fits many multiples of the ceiling inside one window,
#    which is also what makes this case drivable: a ceiling whose flood
#    outlasts the window can never be reached, since the count resets
#    mid-flood (measured: 301 writes take ~72s against a 60s window).
client rl-write "$PORTRL" 203.0.113.21 61 429 "$RLACCESS" "$DID" "$COLLECTION" rl-a \
  || fail 'case 21: writes class did not refuse at its ceiling'
client rl-write "$PORTRL" 203.0.113.22 1 200 "$RLACCESS" "$DID" "$COLLECTION" rl-b \
  || fail "case 21: a second identity was refused by the first one's ceiling"

# 22. createSession class: login itself is rate-limited, independent of
#    every other class.
client rl-session "$PORTRL" 203.0.113.31 31 429 "$HANDLE" "$PASSWORD" \
  || fail 'case 22: createSession class did not refuse at its ceiling'
client rl-session "$PORTRL" 203.0.113.32 1 200 "$HANDLE" "$PASSWORD" \
  || fail "case 22: a second identity was refused by the first one's ceiling"

# 23. repo-export class: `com.atproto.sync.getRepo` serializes the whole
#    repository, so its cost is bounded by `maxCarBytes` per call and not by
#    any count of requests — it therefore has a ceiling of its own. Driven
#    over ONE connection (the connections class is charged once per
#    connection, so a connection-per-request flood would observe THAT ceiling
#    instead), and followed by a plain read from the SAME identity: the class
#    has to be independent, not merely a lower global number.
wait_for_window_room
client rl-repo "$PORTRL" 203.0.113.41 101 429 "$DID" \
  || fail 'case 23: repo-export class did not refuse at its ceiling'
client rl-req "$PORTRL" 203.0.113.41 1 200 \
  || fail 'case 23: a plain read was refused by the repo-export ceiling'
client rl-repo "$PORTRL" 203.0.113.42 1 200 "$DID" \
  || fail "case 23: a second identity was refused by the first one's ceiling"

# 24. requests the server answers 400 are charged too, in both shapes: one
#    that frames and fails to parse, and one no framer can complete. Neither
#    can be attributed to a client, so both are charged to the shared `direct`
#    identity — the same bucket every request without a trusted
#    `X-Forwarded-For` already uses. Before this, either shape was an
#    unmetered channel: 300 of them cost their sender nothing and left its
#    budget whole.
#
#    These run LAST because they exhaust `direct` for the rest of the window,
#    and the two shapes share that one bucket: the first flood proves the
#    shape it drives is CHARGED (400 up to the ceiling, 429 past it), and the
#    single request after it proves the other shape reads the SAME bucket
#    rather than a second free one.
wait_for_window_room
client rl-malformed "$PORTRL" framed 150 429 \
  || fail 'case 24: an unparseable request was not charged'
client rl-malformed "$PORTRL" unframed 1 429 \
  || fail 'case 24: an unframeable request was not charged against the same bucket'
# ...and a well-formed request from an identified client is still served, so
# metering garbage did not become a self-inflicted outage.
client rl-req "$PORTRL" 203.0.113.51 1 200 \
  || fail 'case 24: an identified client was refused by the malformed-traffic ceiling'

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serverl.err" 'rate-limit server (post-run)'

# ── sixth and seventh --data dirs: the appview proxy (#2912) ────────────────
# A proxied read is the first thing this server does that makes an OUTBOUND call
# and the first thing that signs with the account's repo key for an audience a
# CLIENT named. Both halves are graded: what a forwarded call carries and what it
# cost (cases 44, 45, 47), and what a silent upstream can do to everything else
# the process is in the middle of (case 46).
#
# Two stubs and two servers, because one stub must never answer and a server's
# egress port is fixed when it starts.

"$WORK/appview" answer 0 "$WORK/stub.log" "$STUB_STATUS" \
  >"$WORK/stub.out" 2>"$WORK/stub.err" &
STUB_ANSWER_PID=$!
STUB_PIDS="$STUB_PIDS $STUB_ANSWER_PID"
STUBPORT=$(wait_for_stub_port "$WORK/stub.out" "$STUB_ANSWER_PID") || {
  cat "$WORK/stub.err" >&2
  fail 'the stub appview did not report readiness'
}

DATAPX="$WORK/data-proxy"
mkdir -p "$DATAPX"
# `--trusted-proxy` is on for case 47 alone, which needs two distinct client
# identities to show the proxied-read ceiling refuses one without refusing the
# other. Cases 44-46 send no `X-Forwarded-For` and so share the one `direct`
# bucket, exactly as they would on a server without the flag.
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --password-file "$WORK/password" \
  --data "$DATAPX" --port 0 --init --trusted-proxy \
  --appview-did "$APPVIEW_DID" --egress-port "$STUBPORT" \
  >"$WORK/servepx.out" 2>"$WORK/servepx.err" &
SERVER_PID=$!
PORTPX=$(wait_for_port "$WORK/servepx.out") || {
  cat "$WORK/servepx.err" >&2
  fail 'proxy server did not report readiness'
}
require_empty "$WORK/servepx.err" 'proxy server startup'

# One session for every proxy case below. A forward is made on behalf of the
# logged-in account and carries the ACCOUNT's own signature, so a proxied read is
# an `AuthenticatedRoute` like any write: the caller must present an access
# token of its own, and case 44d is the one case here that presents none.
PXLOGIN=$(client login "$PORTPX" "$HANDLE" "$PASSWORD") \
  || fail 'case 44: login against the proxy server'
PXACCESS=${PXLOGIN%% *}
[ -n "$PXACCESS" ] || fail 'case 44: createSession issued an empty access token'

# 44. a proxied read end to end: the answer a client gets back is the stub
#    appview's own — its status code, not a 200 this server composed — and the
#    credential it was reached with names the configured audience and the
#    requested method. The `aud`/`lxm` assertion is made TWICE over, on two
#    sides: in the stub's log, which is what the appview saw, and in the body
#    the stub echoed them into, which is what the client saw. A PDS that
#    answered a proxied read out of its own state would fail both.
client proxy-read "$PORTPX" "$PXACCESS" "$APPVIEW_DID" "$TIMELINE" \
  "$STUB_STATUS" '"lxm":"app.bsky.feed.getTimeline"' \
  || fail 'case 44: a proxied read did not return the appview answer'
grep -F -q "call aud=$APPVIEW_DID lxm=app.bsky.feed.getTimeline iss=$DID" \
  "$WORK/stub.log" || {
  cat "$WORK/stub.log" >&2
  fail 'case 44: the credential the appview received did not name the configured audience and the requested method'
}
grep -F -q "target=$TIMELINE" "$WORK/stub.log" \
  || fail 'case 44: the forwarded target was not the client'"'"'s own'

# 44b. a header naming a SERVICE OF the configured DID (`did:web:x#bsky_appview`)
#    is proxied, and the credential's audience is the BARE DID: `aud` is a DID,
#    and the service id is not part of it. A peer checking `aud` against its own
#    DID would refuse a token carrying the fragment, so this is the difference
#    between a proxied read that works against a real appview and one that 401s.
client proxy-read "$PORTPX" "$PXACCESS" "$APPVIEW_DID#bsky_appview" \
  "$TIMELINE" "$STUB_STATUS" '"appview":"stub"' \
  || fail 'case 44b: a header naming a service of the configured DID was not proxied'
if grep -F -q '#bsky_appview' "$WORK/stub.log"; then
  cat "$WORK/stub.log" >&2
  fail 'case 44b: the service fragment reached the credential the appview was handed'
fi

# 44c. every credential has its own `jti`, 32 hex characters of it. A constant
#    one is a replayable credential, and a gate that only asserted the claim was
#    PRESENT would accept one.
JTI1=$(sed -n 's/^call .* jti=\([0-9a-f]*\) .*/\1/p' "$WORK/stub.log" | sed -n 1p)
JTI2=$(sed -n 's/^call .* jti=\([0-9a-f]*\) .*/\1/p' "$WORK/stub.log" | sed -n 2p)
[ "${#JTI1}" -eq 32 ] \
  || fail "case 44c: jti is ${#JTI1} characters wide, expected 32"
[ "$JTI1" != "$JTI2" ] \
  || fail 'case 44c: two proxied reads were signed with the same jti'

# 44d. AN ANONYMOUS CALLER. The header is correctly audienced, the method is
#    forwardable, the verb is GET — everything case 44 sends — and the one thing
#    missing is the caller's own access token. A server that forwarded this would
#    be signing with the ACCOUNT's repo key on behalf of whoever asked, which is
#    the confused deputy with the deputy's own identity lent out wholesale. The
#    live oracle answers 401 `AuthenticationRequired` to exactly this request.
#
#    Graded on the error CODE and not just the status, and on the stub's call log
#    being unmoved: "refused" and "refused before anything was minted or sent"
#    are different claims, and only the second one is the defense.
CALLS_PRE_ANON=$(stub_calls "$WORK/stub.log")
client proxy-read "$PORTPX" '' "$APPVIEW_DID" "$TIMELINE" 401 \
  'AuthenticationRequired' \
  || fail 'case 44d: an unauthenticated proxied read was not refused 401'
CALLS_POST_ANON=$(stub_calls "$WORK/stub.log")
[ "$CALLS_PRE_ANON" = "$CALLS_POST_ANON" ] || {
  cat "$WORK/stub.log" >&2
  fail "case 44d: an unauthenticated proxied read still reached the appview ($CALLS_PRE_ANON -> $CALLS_POST_ANON calls)"
}

# 44e. the same request WITH a credential still forwards, sent immediately after
#    44d so the 401 above is the credential's absence and not a server that
#    stopped proxying. Its `lxm` is the CANONICAL spelling of the method and
#    not the client's: the authority half of an NSID is compared
#    case-insensitively (`lib.nsid`'s `canonicalNsid`), so `App.Bsky.Feed.`
#    names the same method, and a claim signed for the client's bytes would name
#    a value this server never graded.
client proxy-read "$PORTPX" "$PXACCESS" "$APPVIEW_DID" \
  '/xrpc/App.Bsky.Feed.getTimeline?limit=2' "$STUB_STATUS" \
  '"lxm":"app.bsky.feed.getTimeline"' \
  || fail 'case 44e: a proxied read spelled with an upper-case nsid authority was not forwarded'
grep -F -q "call aud=$APPVIEW_DID lxm=app.bsky.feed.getTimeline iss=$DID" \
  "$WORK/stub.log" || {
  cat "$WORK/stub.log" >&2
  fail 'case 44e: the credential did not carry the canonical method name'
}
if grep -F -q 'lxm=App.Bsky.Feed.getTimeline' "$WORK/stub.log"; then
  cat "$WORK/stub.log" >&2
  fail "case 44e: the credential carried the CLIENT's spelling of the method"
fi

# 45. THE CONFUSED DEPUTY (#2912's S0). `atproto-proxy` is client-controlled and
#    it names the audience a credential is minted for, so both refusals here
#    must carry NOTHING SIGNED: a service this server does not proxy to, and a
#    method it neither serves nor forwards. Each is graded on the refusal's own
#    MESSAGE and not just its status — both are 400 InvalidRequest, so a
#    status-only assertion could not tell which defense fired, or whether any
#    did.
#
#    The third request is the ruling-R1 arm and is NOT a refusal: a method this
#    server REGISTERS is answered by this server, and the header asking for it
#    to be proxied does not override that. It sits in this block because it
#    makes the same claim the other two do — nothing was minted, nothing left
#    the box — by a different route, and because the call count below covers all
#    three together.
#
#    "Nothing was signed" is asserted structurally by the pure cells
#    (`pds/test/read_routes_all_engines.sh`: a refusal carries no claim set, and
#    the `proxy-foreign-audience` mutation proves that cell discriminates). What
#    is added here is that no call LEFT this box — and the final read is what
#    makes that absence mean something: it proves the stub's log was live and
#    writable at that moment, so the three missing lines are three calls that
#    were never made rather than three lines that could not be written.
CALLS_BEFORE=$(stub_calls "$WORK/stub.log")
client proxy-read "$PORTPX" "$PXACCESS" "$ATTACKER_DID" "$TIMELINE" 400 \
  'atproto-proxy names a service this server does not proxy to' \
  || fail 'case 45: a header naming another service was not refused'
client proxy-read "$PORTPX" "$PXACCESS" "$APPVIEW_DID" \
  '/xrpc/com.atproto.server.getSession' 200 "$DID" \
  || fail 'case 45: a method this server registers was not served locally under an atproto-proxy header'
client proxy-read "$PORTPX" "$PXACCESS" "$APPVIEW_DID" \
  '/xrpc/com.atproto.admin.deleteAccount' 400 \
  'No service configured for com.atproto.admin.deleteAccount' \
  || fail 'case 45: a method this server neither serves nor forwards was not refused'
CALLS_AFTER=$(stub_calls "$WORK/stub.log")
[ "$CALLS_BEFORE" = "$CALLS_AFTER" ] || {
  cat "$WORK/stub.log" >&2
  fail "case 45: a refused request still reached the appview ($CALLS_BEFORE -> $CALLS_AFTER calls)"
}
client proxy-read "$PORTPX" "$PXACCESS" "$APPVIEW_DID" "$TIMELINE" \
  "$STUB_STATUS" '"appview":"stub"' \
  || fail 'case 45: the proxy stopped working after a refusal'
CALLS_LIVE=$(stub_calls "$WORK/stub.log")
[ "$CALLS_LIVE" -eq $((CALLS_AFTER + 1)) ] \
  || fail 'case 45: the stub log did not record the call that immediately followed the refusals, so its silence during them proves nothing'

# 52. A PROXIED WRITE (ruling R1). A POST to a method this server does not
#    register, carrying a body and the inbound fields a forward relays for one.
#    Three of the four claims here are invisible to every GET case: the body
#    reached the upstream, the `content-type` that describes it went with it,
#    and `accept-language` — content negotiation the CLIENT chose — did too. A
#    forward that dropped any of them would still answer this client with the
#    upstream's own reply, so all three are read off the stub's log, which is
#    what the appview actually saw.
#
#    The fourth claim runs the other way: `atproto-repo-rev` is a response field
#    only the upstream sets, so a client that sees it saw the upstream's own
#    fields relayed back rather than a response this server composed.
CALLS_PRE_WRITE=$(stub_calls "$WORK/stub.log")
client proxy-write "$PORTPX" "$PXACCESS" "$APPVIEW_DID" \
  '/xrpc/app.bsky.notification.updateSeen' \
  '{"seenAt":"2026-09-12T00:00:00.000Z"}' "$STUB_STATUS" '"appview":"stub"' \
  'atproto-repo-rev: 3lstubrev0000' \
  || fail 'case 52: a proxied write did not return the appview answer with the upstream response field relayed back'
grep -F -q 'verb=POST content-type=application/json accept-language=de-DE body={"seenAt":"2026-09-12T00:00:00.000Z"}' \
  "$WORK/stub.log" || {
  cat "$WORK/stub.log" >&2
  fail 'case 52: the appview did not receive the POST body, its content-type and the client'"'"'s accept-language'
}
CALLS_POST_WRITE=$(stub_calls "$WORK/stub.log")
[ "$CALLS_POST_WRITE" -eq $((CALLS_PRE_WRITE + 1)) ] \
  || fail 'case 52: the proxied write did not reach the appview exactly once'

# 53. the header-ABSENT arm: the same read case 44 sends, with no
#    `atproto-proxy` field at all, forwarded to the appview this operator
#    configured. That is the catch-all the official implementation takes when
#    `parseProxyInfo` finds no header, and it is what makes an app that never
#    sends one usable against this server.
CALLS_PRE_DEFAULT=$(stub_calls "$WORK/stub.log")
client proxy-read "$PORTPX" "$PXACCESS" '' "$TIMELINE" "$STUB_STATUS" \
  '"lxm":"app.bsky.feed.getTimeline"' \
  || fail 'case 53: a read with no atproto-proxy header was not forwarded to the configured appview'
CALLS_POST_DEFAULT=$(stub_calls "$WORK/stub.log")
[ "$CALLS_POST_DEFAULT" -eq $((CALLS_PRE_DEFAULT + 1)) ] \
  || fail 'case 53: the header-absent read did not reach the appview exactly once'

# 47. the proxied-read class: one inbound request became one outbound call, so
#    the amplification is metered. Driven over ONE connection (the connections
#    class is charged per connection and its ceiling is lower, so a
#    connection-per-request flood would observe that one instead), followed by a
#    plain read from the SAME identity and a proxied read from a SECOND one —
#    the class has to be independent and per-identity, not merely a lower global
#    number.
wait_for_window_room
client rl-proxy "$PORTPX" 203.0.113.61 "$PXACCESS" "$APPVIEW_DID" \
  "$TIMELINE" 61 429 \
  || fail 'case 47: the proxied-read class did not refuse at its ceiling'
client rl-req "$PORTPX" 203.0.113.61 1 200 \
  || fail 'case 47: a plain read was refused by the proxied-read ceiling'
client rl-proxy "$PORTPX" 203.0.113.62 "$PXACCESS" "$APPVIEW_DID" \
  "$TIMELINE" 1 "$STUB_STATUS" \
  || fail "case 47: a second identity was refused by the first one's ceiling"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/servepx.err" 'proxy server (post-run)'
require_empty "$WORK/stub.err" 'stub appview'

# 46. HEAD-OF-LINE BLOCKING. The outbound call runs on the same cooperative
#    scheduler as the accept loop, so an upstream that accepts and never answers
#    is a denial of service against everything else in flight unless every wait
#    on that call parks. Three things must keep working while one connection is
#    stuck on a silent appview: an open `subscribeRepos` subscription (which must
#    still receive live events, so the writes that produce them must also still
#    be accepted and persisted), an unrelated plain read, and the stalled call
#    itself, which is owed its own answer — a 502 — rather than being held
#    forever.
#
#    The discriminator is the `kill -0`: the unrelated work is required to have
#    completed WHILE the proxied call was still outstanding. A server that
#    serialized them would finish the stalled call first, and that check is what
#    this case would otherwise be unable to distinguish.
"$WORK/appview" stall 0 >"$WORK/stall.out" 2>"$WORK/stall.err" &
STUB_STALL_PID=$!
STUB_PIDS="$STUB_PIDS $STUB_STALL_PID"
STALLPORT=$(wait_for_stub_port "$WORK/stall.out" "$STUB_STALL_PID") || {
  cat "$WORK/stall.err" >&2
  fail 'case 46: the stalling stub appview did not report readiness'
}

DATAHOL="$WORK/data-proxy-stall"
mkdir -p "$DATAHOL"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --password-file "$WORK/password" \
  --data "$DATAHOL" --port 0 --init \
  --appview-did "$APPVIEW_DID" --egress-port "$STALLPORT" \
  >"$WORK/servehol.out" 2>"$WORK/servehol.err" &
SERVER_PID=$!
PORTHOL=$(wait_for_port "$WORK/servehol.out") || {
  cat "$WORK/servehol.err" >&2
  fail 'case 46: the stalled-upstream server did not report readiness'
}
require_empty "$WORK/servehol.err" 'case 46 startup'

HOLLOGIN=$(client login "$PORTHOL" "$HANDLE" "$PASSWORD") \
  || fail 'case 46: login against the stalled-upstream server'
HOLACCESS=${HOLLOGIN%% *}

client proxy-read "$PORTHOL" "$HOLACCESS" "$APPVIEW_DID" "$TIMELINE" 502 '' \
  >"$WORK/stalled.out" 2>&1 &
STALLED_PID=$!
# Long enough for the request to have been received and the outbound connection
# dialed, and far short of the outbound call's own budget.
sleep 0.5

subclient live "$PORTHOL" "$HOLACCESS" "$DID" "$COLLECTION" pxlive \
  || fail 'case 46: a subscription stopped receiving live events while a proxied call was stalled'
client query "$PORTHOL" "$DID" \
  || fail 'case 46: an unrelated read was not answered while a proxied call was stalled'

kill -0 "$STALLED_PID" 2>/dev/null || {
  cat "$WORK/stalled.out" >&2
  fail 'case 46: the stalled proxied call had already finished, so nothing was proven about what runs alongside one — either the server serialized them, or the unrelated work took longer than the outbound silence budget'
}
wait "$STALLED_PID" || {
  cat "$WORK/stalled.out" >&2
  fail 'case 46: a stalled upstream was not answered 502'
}
# Its own graded line, which went to a file rather than this transcript because
# it was driven in the background. Printed here so the run reads in order.
cat "$WORK/stalled.out"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/servehol.err" 'case 46 (post-run)'

# ── eighth --data dir: a proxy that cannot be reached at all (F3) ───────────
# Case 46's upstream ACCEPTS and then says nothing, so the PDS's own connect
# completed and only its reads had to park. The dial itself is the other half,
# and a worse one: a loopback listener whose accept queue is FULL does not
# refuse a dial - the kernel drops the handshake and `connect(2)` waits on SYN
# retries for minutes - so a blocking connect wedges the one thread this
# scheduler has, taking every unrelated request and every open subscription
# with it. The `deaf` stub mode manufactures exactly that state and says so on
# stdout once it holds.
"$WORK/appview" deaf 0 >"$WORK/deaf.out" 2>"$WORK/deaf.err" &
STUB_DEAF_PID=$!
STUB_PIDS="$STUB_PIDS $STUB_DEAF_PID"
DEAFPORT=$(wait_for_stub_port "$WORK/deaf.out" "$STUB_DEAF_PID") || {
  cat "$WORK/deaf.err" >&2
  fail 'case 50: the deaf stub appview did not report readiness'
}
# Readiness is the LISTEN; the queue is full a moment later. Pointing a server
# at the port before that line appears would grade a dial that completed.
i=0
while [ "$i" -lt 200 ]; do
  if grep -F 'appview-stub: accept queue full' "$WORK/deaf.out" >/dev/null 2>&1
  then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
grep -F -q 'appview-stub: accept queue full' "$WORK/deaf.out" || {
  cat "$WORK/deaf.out" "$WORK/deaf.err" >&2
  fail 'case 50: the deaf stub never filled its own accept queue'
}

DATADEAF="$WORK/data-proxy-deaf"
mkdir -p "$DATADEAF"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --password-file "$WORK/password" \
  --data "$DATADEAF" --port 0 --init \
  --appview-did "$APPVIEW_DID" --egress-port "$DEAFPORT" \
  >"$WORK/servedeaf.out" 2>"$WORK/servedeaf.err" &
SERVER_PID=$!
PORTDEAF=$(wait_for_port "$WORK/servedeaf.out") || {
  cat "$WORK/servedeaf.err" >&2
  fail 'case 50: the unreachable-proxy server did not report readiness'
}
require_empty "$WORK/servedeaf.err" 'case 50 startup'

DEAFLOGIN=$(client login "$PORTDEAF" "$HANDLE" "$PASSWORD") \
  || fail 'case 50: login against the unreachable-proxy server'
DEAFACCESS=${DEAFLOGIN%% *}

# 50. THE CONNECT PARKS. One proxied read is left stuck mid-handshake while an
#    unrelated plain read is asked for and answered, and the stuck call is then
#    owed its own answer - a 502 once its connect budget runs out, not a
#    connection held until the inbound lifecycle gives up.
#
#    The `kill -0` is the discriminator, as in case 46: the unrelated read has
#    to have been answered WHILE the dial was still outstanding. A server whose
#    connect blocked the thread would answer it only after the dial finished,
#    and nothing else here could tell the two apart.
client proxy-read "$PORTDEAF" "$DEAFACCESS" "$APPVIEW_DID" "$TIMELINE" 502 '' \
  >"$WORK/deafstalled.out" 2>&1 &
DEAF_STALLED_PID=$!
# Long enough for the request to have been received and the dial started, and
# far short of the outbound connect budget.
sleep 0.5

client query "$PORTDEAF" "$DID" \
  || fail 'case 50: an unrelated read was not answered while a proxied call was stuck connecting'

kill -0 "$DEAF_STALLED_PID" 2>/dev/null || {
  cat "$WORK/deafstalled.out" >&2
  fail 'case 50: the stuck proxied call had already finished, so nothing was proven about what runs alongside one - either the server serialized them, or the unrelated read took longer than the outbound connect budget'
}
wait "$DEAF_STALLED_PID" || {
  cat "$WORK/deafstalled.out" >&2
  fail 'case 50: a proxied call to an unreachable proxy was not answered 502'
}
# Its own graded line, which went to a file rather than this transcript because
# it was driven in the background. Printed here so the run reads in order.
cat "$WORK/deafstalled.out"

# 51. THE AMPLIFICATION CEILING. One in-flight proxied call accumulates its
#    upstream response in a `Vector Int` - a tagged word per logical byte - so
#    `maxHttpClientWireBytes` bounds one call's buffer at about six megabytes
#    of logical bytes and an order of magnitude more of resident memory. What
#    bounds the NUMBER of them is `maxConcurrentProxiedCalls`
#    (`pds/shell/server.mdk`), which this case reads as the literal 8 below:
#    eight dials are left stuck against the deaf proxy, and the ninth must be
#    refused rather than admitted.
#
#    Graded on the error CODE and not just the status: 503 is also what the
#    subscription ceiling answers, and a status-only assertion could not tell
#    which ceiling fired. An ordinary read is asked for alongside it, because a
#    ceiling on proxied calls that refused unrelated traffic would be an outage
#    rather than a bound.
PROXY_CEILING=8
i=1
CEILING_PIDS=""
while [ "$i" -le "$PROXY_CEILING" ]; do
  client proxy-read "$PORTDEAF" "$DEAFACCESS" "$APPVIEW_DID" "$TIMELINE" 502 '' \
    >"$WORK/ceiling.$i.out" 2>&1 &
  CEILING_PIDS="$CEILING_PIDS $!"
  i=$((i + 1))
done
# Every one of the eight has to be IN FLIGHT before the ninth is sent - each
# holds its slot for the whole of its connect budget, so a second is ample.
sleep 1

client proxy-read "$PORTDEAF" "$DEAFACCESS" "$APPVIEW_DID" "$TIMELINE" 503 \
  ProxyLimitExceeded \
  || fail 'case 51: a proxied read past the concurrency ceiling was not refused 503 ProxyLimitExceeded'
client query "$PORTDEAF" "$DID" \
  || fail 'case 51: an ordinary read was refused by the proxied-call ceiling'

for pid in $CEILING_PIDS; do
  wait "$pid" || {
    cat "$WORK"/ceiling.*.out >&2
    fail 'case 51: one of the eight in-flight proxied calls was not answered 502'
  }
done
# The eight graded lines, driven in the background like case 50's.
cat "$WORK"/ceiling.*.out

# The slots the eight held are given back, so the ceiling bounds what is in
# flight and not what has ever been sent: a call made after they finish is
# forwarded like any other and answered 502 by the same deaf proxy.
client proxy-read "$PORTDEAF" "$DEAFACCESS" "$APPVIEW_DID" "$TIMELINE" 502 '' \
  || fail 'case 51: the ceiling did not give its slots back - a later proxied call was still refused'

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/servedeaf.err" 'case 50/51 (post-run)'
require_empty "$WORK/deaf.err" 'deaf stub appview'
kill "$STUB_DEAF_PID" 2>/dev/null || true
wait "$STUB_DEAF_PID" 2>/dev/null || true

# ── eighth and ninth --data dirs: requestCrawl (S-crawl-routes) ─────────────
# The outbound half of discovery: an unauthenticated POST announcing this
# server's own hostname to a configured relay, fired once at startup,
# best-effort. Case 48 proves what it sends when the relay is there; case 49
# proves startup and ordinary service survive when it isn't.

"$WORK/crawlstub" 0 "$WORK/crawl.log" 200 \
  >"$WORK/crawl.out" 2>"$WORK/crawl.err" &
CRAWL_STUB_PID=$!
STUB_PIDS="$STUB_PIDS $CRAWL_STUB_PID"
CRAWLPORT=$(wait_for_crawl_stub_port "$WORK/crawl.out" "$CRAWL_STUB_PID") || {
  cat "$WORK/crawl.err" >&2
  fail 'the stub relay did not report readiness'
}

DATACRAWL="$WORK/data-crawl"
mkdir -p "$DATACRAWL"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --password-file "$WORK/password" \
  --data "$DATACRAWL" --port 0 --init --relay-port "$CRAWLPORT" \
  >"$WORK/servecrawl.out" 2>"$WORK/servecrawl.err" &
SERVER_PID=$!
PORTCRAWL=$(wait_for_port "$WORK/servecrawl.out") || {
  cat "$WORK/servecrawl.err" >&2
  fail 'case 48: the crawl-announcing server did not report readiness'
}
require_empty "$WORK/servecrawl.err" 'case 48 startup'

# 48. the announce itself: a POST to requestCrawl naming this server's own
#    hostname, with NO authorization header — the reference implementation
#    sends this call unauthenticated, and the stub relay sees it as such. The
#    announce is fired in the background at startup, so give it a moment to
#    land before grading the stub's log.
i=0
while [ "$i" -lt 100 ]; do
  if grep -F -q 'call method=POST target=/xrpc/com.atproto.sync.requestCrawl' \
    "$WORK/crawl.log" 2>/dev/null
  then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
grep -F -q "call method=POST target=/xrpc/com.atproto.sync.requestCrawl hostname=$HOSTNAME authorization=absent" \
  "$WORK/crawl.log" || {
  cat "$WORK/crawl.log" >&2
  fail "case 48: the stub relay did not see an unauthenticated requestCrawl naming this server's own hostname"
}
client query "$PORTCRAWL" "$DID" \
  || fail 'case 48: the server did not still answer an ordinary request'

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/servecrawl.err" 'case 48 (post-run)'
kill "$CRAWL_STUB_PID" 2>/dev/null || true
wait "$CRAWL_STUB_PID" 2>/dev/null || true

# 49. the relay is unreachable: startup still succeeds and the server still
#    answers ordinary requests. A throwaway stub reserves a port and exits,
#    exactly the shape `crawl_stub_main.mdk`'s own header describes — no
#    driver mode is needed for "unreachable", only a port nothing is
#    listening on when the announce dials it.
"$WORK/crawlstub" 0 "$WORK/crawl_dead.log" 200 \
  >"$WORK/crawl_dead.out" 2>"$WORK/crawl_dead.err" &
DEAD_STUB_PID=$!
DEADPORT=$(wait_for_crawl_stub_port "$WORK/crawl_dead.out" "$DEAD_STUB_PID") || {
  cat "$WORK/crawl_dead.err" >&2
  fail 'the throwaway stub relay did not report readiness'
}
kill "$DEAD_STUB_PID" 2>/dev/null || true
wait "$DEAD_STUB_PID" 2>/dev/null || true

DATANOCRAWL="$WORK/data-crawl-unreachable"
mkdir -p "$DATANOCRAWL"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --password-file "$WORK/password" \
  --data "$DATANOCRAWL" --port 0 --init --relay-port "$DEADPORT" \
  >"$WORK/servenocrawl.out" 2>"$WORK/servenocrawl.err" &
SERVER_PID=$!
PORTNOCRAWL=$(wait_for_port "$WORK/servenocrawl.out") || {
  cat "$WORK/servenocrawl.err" >&2
  fail 'case 49: startup with an unreachable relay did not succeed'
}
client query "$PORTNOCRAWL" "$DID" \
  || fail 'case 49: the server did not still answer an ordinary request with the relay unreachable'

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/stall.err" 'stalling stub appview'

echo 'PASS: serve_e2e — query, pipeline, keep-alive, chunked write, every remaining route, login, getSession, wrong-password refusal, session lifecycle, refresh rotation and reuse, malformed, over-cap, idle timeout, un-framed connection flood answered rather than shutting other callers out, a PIN on #2772'"'"'s still-open body phase (a stalled-body flood DOES shut other callers out — asserted as the current bad behavior, red when fixed), restart-and-resume, a subscribeRepos subscription receiving live events in order, a future cursor refused and an outdated one told it has a gap before its replay, a cursor at the newest delivered event replaying nothing and then receiving the next event once, the subscription ceiling refusing a 33rd attempt without completing an upgrade while an ordinary route is still answered, a subscriber silent past requestTimeout not reaped, blob upload and cross-restart fetch, blob residue skipped rather than refusing startup, a backup restored into a SEPARATE data directory whose server exports a byte-identical repository, serves both blobs under their declared types, and accepts a new signed write, init-overwrite-refusal, first-run bootstrap, rate limiting refuses one identity per class while a second identity is still served, repository export bounded by its own class, 400-answered traffic charged rather than free, every secret the server writes owner-only, a world-readable signing key refused before the bind, a rejected configuration leaving no generated secret behind, a constant session-token secret refused before the bind, keygen writing an owner-only key and token secret that serve then runs on, keygen refusing to overwrite, a credential re-derived at the shipped iteration count by one successful login and left untouched by a failed one, a non-loopback bind with no credential refused by the existing missing-credential diagnostic rather than an invented one, a non-loopback bind with no --trusted-proxy refused before any secret reaches disk, the accepted non-loopback-plus-trusted-proxy combination actually binding and serving, a proxied read returning a stub appview'"'"'s own status and body under a credential whose aud and lxm the appview itself logged, a header naming a service OF the configured DID proxied with the fragment stripped from aud, a fresh 32-hex jti per call, an unauthenticated proxied read refused 401 without the appview being called at all and the same request with a credential still forwarded, an upper-case nsid authority forwarded under the canonical spelling of the method rather than the client'"'"'s, a confused-deputy refusal for an unconfigured audience and for a method this server neither serves nor forwards — neither reaching the appview, proven live by the call that immediately followed — while a method this server registers is answered locally under the same header, a proxied POST whose body, content-type and accept-language all reached the appview and whose atproto-repo-rev response field came back to the client, a read carrying NO atproto-proxy header forwarded to the configured appview, an appview that accepts and never answers blocking neither an open subscribeRepos subscription nor an unrelated read while still being owed its own 502, the proxied-call class refusing one identity without refusing that identity'"'"'s plain reads or a second identity, a proxy whose accept queue is full leaving a dial stuck without blocking an unrelated read and still being owed its own 502, a ninth concurrent proxied call refused 503 ProxyLimitExceeded while eight are stuck dialling and ordinary reads are still answered, the slots those eight held given back, an unauthenticated requestCrawl announcing this server'"'"'s own hostname to a configured relay, and startup and ordinary service surviving a relay that is unreachable'
