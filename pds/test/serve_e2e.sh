#!/bin/sh
# blocked-because: detached-process — the server and its stub appviews must keep running while the client talks to them, then be killed by pid
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
RACE_SRC="$ROOT/pds/test/dirlock_race_main.mdk"

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

# `--stamp-build` bakes the commit, the compiler fingerprint and the build date
# into the binary, which is how a deployed pdsd is built and therefore how this
# gate builds one; case 59 reads them back off `--version`. Every other case
# below exercises that same stamped binary rather than a variant of it.
if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$SERVE_SRC" -o "$WORK/pdsd" \
  --stamp-build > "$WORK/build_serve.log" 2>&1
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

if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$RACE_SRC" \
  -o "$WORK/race" > "$WORK/build_race.log" 2>&1
then
  cat "$WORK/build_race.log" >&2
  fail 'native dirlock_race_main.mdk build failed'
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
# A blob declared `text/html` (#2948) — the MIME type a browser navigating
# straight to the blob URL would otherwise render as this origin's own live
# document rather than download.
HTML_BLOB_TEXT='<script>pds serve_e2e gate fixture html blob</script>'
HTML_BLOB_MIME='text/html'

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

# The services an `atproto-proxy` header may name on the proxy servers below,
# and a DID no server here is configured for: the confused-deputy case is
# entirely about the difference between a configured audience and that one.
#
# The chat DID is the SECOND configured audience, given its own egress proxy on
# its own port. Nothing in the server knows either of these names — they are
# values this gate puts in the configured set, exactly as an operator would.
APPVIEW_DID='did:web:appview.test'
CHAT_DID='did:web:chat.test'
ATTACKER_DID='did:web:attacker.example'
LISTCONVOS='/xrpc/chat.bsky.convo.listConvos'
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
chmod 600 "$WORK/key.hex" "$WORK/token.hex" "$WORK/password"

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
  # --password-file is only passed on a genesis (--init) run over a directory
  # that holds no credential yet: a resumed run, or a genesis run over a
  # directory `seed_credential` already wrote one into, finds an existing
  # credential, and passing --password-file against one gets refused (F1,
  # #2604) rather than silently keeping the old password.
  pwflag=""
  if [ "$extra" = "--init" ] && [ ! -e "$DATA/credential" ]; then
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

# seed_credential <data dir>: write a credential for $PASSWORD, derived at a
# count of 4, into that directory, in the three lines the server keeps there.
# A server started over it loads that record instead of deriving one at the
# shipped count, which is a cost this gate would otherwise pay once per data
# directory and pay more of with every raise of `defaultIterations`. The first
# successful login still re-derives the record at the shipped count, once.
# Only the cases about the bootstrap itself start without one: they pass
# --password-file, and a server given both refuses to start.
seed_credential() {
  client credential-at 4 "$PASSWORD" > "$1/credential" \
    || fail "could not seed a credential into $1"
  chmod 600 "$1/credential"
}

# The event-stream driver. A separate binary rather than more subcommands on
# `client`: nothing it does is an HTTP request/response exchange, so it shares
# neither that driver's response reader nor its request builders.
subclient() {
  "$WORK/subclient" "$@"
}

# ── first instance: genesis, then cases 1-8 ─────────────────────────────────

seed_credential "$DATA"
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

# 1b. GET /xrpc/_health with no Authorization header: 200, and a body
#    carrying this build's own version-string shape (S-health-route, #2965).
#    `_health` fails NSID syntax and is deliberately absent from the
#    endpoint registry (see pds/test/route_policy_test.mdk), so it is proven
#    here rather than by that registry-derived table.
client health "$PORT1" || fail 'case 1b: GET /xrpc/_health'

# 2. pipelined pair, both correct, in order
client pipeline "$PORT1" || fail 'case 2: pipelined pair'

# 3. keep-alive reuse
client keepalive "$PORT1" || fail 'case 3: keep-alive reuse'

# 3b. a fresh account, before any putPreferences call, answers getPreferences
#    with an empty list.
client get-preferences "$PORT1" "$TOKEN" empty \
  || fail 'case 3b: getPreferences on a fresh account'

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

# 4b-html. a blob declared `text/html` (#2948) must not come back as a live
#    document: `getBlob` must refuse to serve it renderable under this
#    origin, and the server must keep answering the next request afterward.
HTML_BLOB_CID=$(
  client upload-blob "$PORT1" "$TOKEN" "$HTML_BLOB_MIME" "$HTML_BLOB_TEXT"
) || fail 'case 4b-html: uploadBlob of a text/html blob'
[ -n "$HTML_BLOB_CID" ] \
  || fail 'case 4b-html: uploadBlob returned an empty CID'
client get-blob-not-live "$PORT1" "$DID" "$HTML_BLOB_CID" \
  || fail 'case 4b-html: getBlob served a text/html blob as a live document'
client query "$PORT1" "$DID" \
  || fail 'case 4b-html: server stopped answering after the html blob fetch'

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

# 4e. putPreferences replaces the whole app.bsky namespace's preference set,
#    and a $type-less item or one outside app.bsky is refused 400 rather than
#    written. The write's survival across the restart is case 9's job below.
client put-preferences-invalid "$PORT1" "$TOKEN" missing-type \
  || fail 'case 4e: putPreferences refuses an item with no $type'
client put-preferences-invalid "$PORT1" "$TOKEN" wrong-namespace \
  || fail 'case 4e: putPreferences refuses an item outside app.bsky'
client put-preferences "$PORT1" "$TOKEN" 200 \
  || fail 'case 4e: putPreferences with a well-formed app.bsky item'
client get-preferences "$PORT1" "$TOKEN" fixture \
  || fail 'case 4e: getPreferences reads back the item just written'

# 4f. the persist-failure 500 path (S-cors, #2938): `persistPreferences`
#    stages its write at "<data>/preferences.tmp" before renaming it onto the
#    real file, so putting a DIRECTORY at that exact path forces the write to
#    fail regardless of who this process runs as — root ignores permission
#    bits, which a chmod-based failure would not survive. This is the ONE
#    response `pds/shell/server.mdk`'s `persistFailureBytes` builds, which
#    bypasses `lib.server_core`'s `handle` entirely, so it is graded on the
#    allow-origin header rather than on the body.
#
#    Run against a DEDICATED server instance, not $PORT1: `persistFailureBytes`
#    logs the failure to stderr (`ePutStrLn`), which every other case in this
#    gate treats as a failure in its own right (`require_empty`) — this is the
#    one case that must SEE that line and grades it directly instead.
#    `$SERVER_PID` is saved and restored around it so the later `kill
#    "$SERVER_PID"` for $PORT1 still targets the right process.
MAIN_SERVER_PID="$SERVER_PID"
DATACORS="$WORK/data-cors"
mkdir -p "$DATACORS"
seed_credential "$DATACORS"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATACORS" --port 0 --init \
  >"$WORK/servecors.out" 2>"$WORK/servecors.err" &
SERVER_PID=$!
PORTCORS=$(wait_for_port "$WORK/servecors.out") || {
  cat "$WORK/servecors.err" >&2
  fail 'case 4f: dedicated CORS server did not report readiness'
}
require_empty "$WORK/servecors.err" 'case 4f startup'
CORSLOGIN=$(client login "$PORTCORS" "$HANDLE" "$PASSWORD") \
  || fail 'case 4f: could not log in to the dedicated CORS server'
CORSTOKEN=${CORSLOGIN%% *}
mkdir "$DATACORS/preferences.tmp"
client put-preferences-cors "$PORTCORS" "$CORSTOKEN" 500 \
  || fail 'case 4f: a persist failure did not answer 500 with the allow-origin header'
grep -F -q 'persist failed, state not advanced: Is a directory' "$WORK/servecors.err" \
  || fail 'case 4f: the persist failure was not logged as expected'
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID="$MAIN_SERVER_PID"

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

# 5e. a record nested deeper than the DAG-CBOR codec can read back is refused
#    at WRITE time (#2947), and the collection is still readable afterwards.
#    Case 5's LISTRECORDS is the before-picture: until the encoder carried the
#    decoder's own 128-level bound, this write was COMMITTED with a 200 and
#    every later listRecords for the WHOLE collection — not merely getRecord
#    for this one key — answered 400 from then on. The second half of the case
#    is the one that proves the poisoning is gone rather than moved.
client deep-record "$PORT1" "$TOKEN" "$DID" "$COLLECTION" e2edeeprecord 129 \
  || fail 'case 5e: an over-deep record was accepted, or poisoned the collection'

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

# 12. rotation, and a replay of what it consumed inside the grace window. A
#    client that refreshes twice in a burst presents one refresh token twice;
#    within two hours of the rotation the second presentation is answered with
#    a working pair of its own, and the pair the first one issued keeps
#    working beside it. A replay past the window revokes the family, which no
#    wall-clock gate can wait for: `pds/test/session_routes_test.mdk` places
#    requests at chosen instants and grades that half.
LOGIN3=$(client login "$PORT1" "$HANDLE" "$PASSWORD") \
  || fail 'case 12: third login'
REFRESH3=${LOGIN3##* }
ROTATED=$(client refresh "$PORT1" "$REFRESH3") || fail 'case 12: refreshSession'
ACCESS4=${ROTATED%% *}
REFRESH4=${ROTATED##* }
[ "$REFRESH4" != "$REFRESH3" ] \
  || fail 'case 12: refreshSession returned the token it was given'
REPLAYED=$(client refresh-grace-replay "$PORT1" "$REFRESH3" "$ACCESS4") \
  || fail 'case 12: a replay inside the grace window was not answered with a pair of its own'
ACCESS5=${REPLAYED%% *}
client write "$PORT1" "$ACCESS5" "$DID" "$COLLECTION" 's-sessions-live-grace' 200 \
  || fail 'case 12: write with the grace replay'"'"'s access token'
client write "$PORT1" "$ACCESS4" "$DID" "$COLLECTION" 's-sessions-live-3' 200 \
  || fail 'case 12: write with the rotated access token'
client logout "$PORT1" "$REFRESH4" || fail 'case 12: logout of the rotated session'

# 6. malformed request -> 400, error path not a hang or crash
client malformed "$PORT1" || fail 'case 6: malformed request'

# 7. over-cap body -> rejected (413), not truncated or hung
client overcap "$PORT1" || fail 'case 7: over-cap body'

# 7b. THE ACCESS LOG (#2964): one line per request, REFUSALS INCLUDED.
#
#    The refusal half is the load-bearing one and is asserted first. A log
#    that covers only requests the server answered is worse than no log at
#    all: the traffic an operator most needs to see is the traffic that was
#    turned away, and a count of instrumented call sites establishes nothing
#    about it.
#
#    Three refusals, because they leave the server by three different exits
#    and a funnel that covered two of them would look identical here to one
#    that covered all three: a routed 401 from the auth seam, a framed buffer
#    that no parse can rescue (case 6, logged with `-` for the method and
#    target it never supplied), and a buffer the FRAMER refused outright
#    (case 7's over-cap body), which leaves through `rejectBufferAt` and never
#    reaches the send funnel the other two share.
client unauthorized "$PORT1" "$DID" "$COLLECTION" 's-accesslog-refused' \
  || fail 'case 7b: unauthenticated write refused'
grep -Eq '^serve: access method=POST path=/xrpc/com\.atproto\.repo\.createRecord status=401 bytes=[0-9]+ ms=[0-9]+ client=direct$' \
  "$WORK/serve1.out" \
  || fail 'case 7b: a refused (401) request produced no access log line'
grep -Eq '^serve: access method=- path=- status=400 bytes=[0-9]+ ms=[0-9]+ client=direct$' \
  "$WORK/serve1.out" \
  || fail "case 7b: case 6's unparsable buffer produced no access log line"
grep -Eq '^serve: access method=- path=- status=413 bytes=[0-9]+ ms=[0-9]+ client=direct$' \
  "$WORK/serve1.out" \
  || fail "case 7b: case 7's over-cap body produced no access log line"

#    The served half: a request this case issues itself, answered 200.
client query "$PORT1" "$DID" || fail 'case 7b: served query'
grep -Eq '^serve: access method=GET path=/\.well-known/atproto-did status=200 bytes=[0-9]+ ms=[0-9]+ client=direct$' \
  "$WORK/serve1.out" \
  || fail 'case 7b: a served request produced no access log line'

#    And the query string that must NOT be in a line. Case 5's LISTRECORDS
#    sent `listRecords?repo=…&collection=…`; a query value is where a
#    credential rides when one rides in a target at all, so the line carries
#    the route and stops at the `?` — asserted for that route by name, and
#    then for every line in the log at once.
grep -Eq '^serve: access method=GET path=/xrpc/com\.atproto\.repo\.listRecords status=200 bytes=[0-9]+ ms=[0-9]+ client=direct$' \
  "$WORK/serve1.out" \
  || fail "case 7b: case 5's query-bearing route logged no stripped line"
if grep -F 'serve: access' "$WORK/serve1.out" | grep -Fq '?'; then
  fail 'case 7b: an access log line carries a query string'
fi

#    And nothing a request supplied in confidence reaches a line. Both secrets
#    below are live in this server's history by now: case 4 logged in with the
#    account password in a request body, and case 5b's token has been sent in
#    an Authorization header since.
for leaked in "$PASSWORD" "$TOKEN"; do
  if grep -F 'serve: access' "$WORK/serve1.out" | grep -Fq "$leaked"; then
    fail 'case 7b: an access log line carries a secret the request supplied'
  fi
done

#    Finally the startup lines, which say what this process was configured to
#    do and what it found in the event log — the two facts an operator reading
#    an incident cannot reconstruct from the request lines.
grep -Eq '^serve: config did=.* handle=.* hostname=.* data=.* bind=127\.0\.0\.1 trusted-proxy=no appview=no relay=no$' \
  "$WORK/serve1.out" \
  || fail '7b: startup logged no configuration summary'
grep -Eq '^serve: event log recovery: (settled|promoted|discarded)$' \
  "$WORK/serve1.out" \
  || fail '7b: startup logged no event-log recovery outcome'

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

# 9g (first half). A session opened on this instance and deliberately left
#    open across the restart below. Every other login above has been logged
#    out or rotated away by now, so this is the one whose survival case 9g
#    can be about.
LOGIN_SURVIVE=$(client login "$PORT1" "$HANDLE" "$PASSWORD") \
  || fail 'case 9g: login before the restart'
SURVIVE_ACCESS=${LOGIN_SURVIVE%% *}
SURVIVE_REFRESH=${LOGIN_SURVIVE##* }

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

# 9c-9f. the two sync VERIFICATION reads over a live socket, against the
#    repository this server actually holds. The CAR bytes are graded
#    byte-for-byte against the oracle's own answer key in
#    pds/test/repo_vectors.sh; what these four cases add is that the routes
#    answer that way over the wire, under the media type a relay reads them
#    by, on a repository built by this gate's own writes rather than by a
#    fixture.
#
# 9c. a key the repository HOLDS: 200, a rooted CAR, the record block in it.
client sync-get-record "$PORT2" "$DID" "$COLLECTION" "$RKEY" "$RECORD_TEXT" \
  || fail 'case 9c: sync.getRecord did not serve the record it holds'

# 9d. a key it does NOT hold: still 200 and still a rooted CAR — a proof of
#    ABSENCE, not an error — and the present record must not be in it.
client sync-get-record-absent "$PORT2" "$DID" "$COLLECTION" \
  'e2egatefixture-absent' "$RECORD_TEXT" \
  || fail 'case 9d: sync.getRecord did not prove absence'

# 9e. one block the store holds: a CAR whose roots list is EMPTY, carrying
#    that block and nothing else.
client sync-get-blocks "$PORT2" "$DID" "$RECORD_TEXT" \
  || fail 'case 9e: sync.getBlocks did not serve a rootless CAR of the asked-for block'

# 9f. a set the store holds only part of: refused whole, naming BOTH absent
#    CIDs. The two absent ones are the blob CIDs — content-addressed, but
#    never blocks of the signed graph.
client sync-get-blocks-missing "$PORT2" "$DID" "$BLOB_CID" "$BLOB2_CID" \
  || fail 'case 9f: sync.getBlocks did not refuse a partly-missing set by name'

# 9b. the preference item written before the restart (case 4e) is read back
#    by the fresh process — the preferences half survives the process
#    boundary the same way the repository and blob halves do. This logs in
#    again rather than reusing case 9g's surviving token, so that 9b grades
#    the preferences half alone and fails for one reason only.
LOGIN9=$(client login "$PORT2" "$HANDLE" "$PASSWORD") \
  || fail 'case 9b: could not log in to the resumed server'
TOKEN9=${LOGIN9%% *}
[ -n "$TOKEN9" ] || fail 'case 9b: resumed server issued an empty access token'
client get-preferences "$PORT2" "$TOKEN9" fixture \
  || fail 'case 9b: getPreferences survived the restart'

# 9g. the session half survives the restart: a restart is not a logout. Both
#    tokens issued before it are still good on the fresh process — the access
#    token authenticates a write, and the refresh token still rotates. An
#    unpersisted session set refuses both, and refuses the refresh token
#    especially, which leaves a client nothing to recover with short of the
#    password.
client write "$PORT2" "$SURVIVE_ACCESS" "$DID" "$COLLECTION" 's-survives-restart' 200 \
  || fail 'case 9g: access token issued before the restart was refused after it'
SURVIVE_ROTATED=$(client refresh "$PORT2" "$SURVIVE_REFRESH") \
  || fail 'case 9g: refresh token issued before the restart was refused after it'
SURVIVE_ACCESS2=${SURVIVE_ROTATED%% *}
[ -n "$SURVIVE_ACCESS2" ] \
  || fail 'case 9g: rotation across the restart issued an empty access token'
client write "$PORT2" "$SURVIVE_ACCESS2" "$DID" "$COLLECTION" 's-survives-restart-2' 200 \
  || fail 'case 9g: the token rotated after the restart was refused'

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

# 15b. the blocks-half mirror of case 15: a stray NON-DIRECTORY entry directly
#    under `<data>/blocks` — an editor swapfile, a `.DS_Store` — is residue
#    outside `blockfile.mdk`'s business too, not an unreadable shard directory
#    that must brick the startup (#2572 part 2, #3052). Unlike the blob half,
#    nothing here is damaged, so the check is that the repository the blocks
#    back and the blobs beside it are both still served intact.
DATA15B="$WORK/data15b"
cp -R "$DATA" "$DATA15B"
touch "$DATA15B/blocks/.DS_Store"
start_resume_at "$DATA15B" "$WORK/case15b.out" "$WORK/case15b.err"
PORT15B=$(wait_for_port "$WORK/case15b.out") || {
  cat "$WORK/case15b.err" >&2
  fail 'case 15b: server did not start over a blocks directory holding residue'
}
require_empty "$WORK/case15b.err" 'case 15b startup'
client sync-get-record "$PORT15B" "$DID" "$COLLECTION" "$RKEY" "$RECORD_TEXT" \
  || fail 'case 15b: repository record did not survive stray blocks/ residue'
client get-blob "$PORT15B" "$DID" "$BLOB_CID" "$BLOB_MIME" "$BLOB_TEXT" \
  || fail 'case 15b: blob did not survive stray blocks/ residue'
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/case15b.err" 'case 15b (post-run)'
echo 'case 15b: started over stray blocks/ residue, repository and blob intact'

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

# 25a. a --password-file any other account on the box can read is refused
#    BEFORE the listener binds, the same way case 25's signing key is.
DATA25A="$WORK/data25a"
mkdir -p "$DATA25A"
cp "$WORK/password" "$WORK/password25a"
chmod 644 "$WORK/password25a"
run_until_exit "$WORK/serve25a.out" "$WORK/serve25a.err" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --password-file "$WORK/password25a" \
  --data "$DATA25A" --port 0 --init
[ "$RC" -ne 0 ] || fail 'case 25a: a 0644 password file was accepted'
grep -F "password file $WORK/password25a is mode 0644, readable by accounts other than its owner" \
  "$WORK/serve25a.err" >/dev/null \
  || fail 'case 25a: the refusal did not name the mode and the path'
if grep -F 'serve: listening on' "$WORK/serve25a.out" >/dev/null 2>&1; then
  fail 'case 25a: the listener bound before the password file was graded'
fi
[ ! -e "$DATA25A/credential" ] \
  || fail 'case 25a: a refused password file still produced a credential'

# 25b. a --data/credential any other account on the box can read is refused
#    BEFORE the listener binds, on a RESUME (no --password-file): first
#    bootstrap a real credential, then widen its mode and start again.
DATA25B="$WORK/data25b"
mkdir -p "$DATA25B"
"$WORK/pdsd" --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --password-file "$WORK/password" \
  --data "$DATA25B" --port 0 --init \
  > "$WORK/serve25b_bootstrap.out" 2> "$WORK/serve25b_bootstrap.err" &
SERVER_PID=$!
wait_for_port "$WORK/serve25b_bootstrap.out" >/dev/null \
  || fail 'case 25b: the bootstrap server did not report readiness'
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
chmod 644 "$DATA25B/credential"
run_until_exit "$WORK/serve25b.out" "$WORK/serve25b.err" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --data "$DATA25B" --port 0
[ "$RC" -ne 0 ] || fail 'case 25b: a 0644 credential file was accepted'
grep -F "credential $DATA25B/credential is mode 0644, readable by accounts other than its owner" \
  "$WORK/serve25b.err" >/dev/null \
  || fail 'case 25b: the refusal did not name the mode and the path'
if grep -F 'serve: listening on' "$WORK/serve25b.out" >/dev/null 2>&1; then
  fail 'case 25b: the listener bound before the credential file was graded'
fi

# 25c. a --did did:web that names this server's own --hostname in different
#    case is refused BEFORE the listener binds (#3091): `wellKnownDidJson`'s
#    fallback arm would otherwise keep serving the SERVER document forever,
#    with no signing key and no `alsoKnownAs`, which no relay or appview can
#    use to verify this account.
DATA25C="$WORK/data25c"
mkdir -p "$DATA25C"
run_until_exit "$WORK/serve25c.out" "$WORK/serve25c.err" \
  --did "did:web:PDS.Test" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --password-file "$WORK/password" \
  --data "$DATA25C" --port 0 --init
[ "$RC" -ne 0 ] || fail 'case 25c: a case-mismatched did:web was accepted'
grep -F -e "did:web:PDS.Test and --hostname $HOSTNAME name the same did:web host in different case" \
  "$WORK/serve25c.err" >/dev/null \
  || fail 'case 25c: the refusal did not name the mismatch'
grep -F -e "e.g. --did did:web:$HOSTNAME" "$WORK/serve25c.err" >/dev/null \
  || fail 'case 25c: the refusal did not name the remedy'
if grep -F 'serve: listening on' "$WORK/serve25c.out" >/dev/null 2>&1; then
  fail 'case 25c: the listener bound before the did:web hostname case was graded'
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
KEYGEN_TOKEN_SECRET=$(tr -d '\n' < "$KEYGEN_DIR/token.hex")
if grep -F "$KEYGEN_SECRET" "$WORK/keygen.out" "$WORK/keygen.err" >/dev/null 2>&1 \
  || grep -F "$KEYGEN_TOKEN_SECRET" "$WORK/keygen.out" "$WORK/keygen.err" >/dev/null 2>&1
then
  fail 'case 28: keygen printed a secret it generated'
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
# A destination can pass the existence precheck and still fail to be written.
# The first write is then cleaned up, and no success summary is published.
"$WORK/pdsd" keygen --key "$KEYGEN_DIR/fresh-write-failure.hex" \
  --token-secret "$KEYGEN_DIR/missing-parent/token.hex" \
  > "$WORK/keygen4.out" 2> "$WORK/keygen4.err" \
  && fail 'case 28: keygen accepted an unwritable --token-secret destination'
[ ! -e "$KEYGEN_DIR/fresh-write-failure.hex" ] \
  || fail 'case 28: a second-write failure left the signing key behind'
[ ! -e "$KEYGEN_DIR/missing-parent/token.hex" ] \
  || fail 'case 28: a second-write failure left the token secret behind'
grep -F "unwritable session-token secret $KEYGEN_DIR/missing-parent/token.hex" \
  "$WORK/keygen4.err" >/dev/null \
  || fail 'case 28: the second-write failure did not name the token path'
if grep -E 'keygen: (wrote|public key|did:key)' \
  "$WORK/keygen4.out" "$WORK/keygen4.err" >/dev/null 2>&1
then
  fail 'case 28: a failed paired write published a success summary'
fi
# 28b. and what keygen wrote is what serve accepts: a whole genesis server
#    stands up on the generated key and the generated token secret, which is
#    the only proof that keygen and serve agree on the file format and mode.
DATA28="$WORK/data28"
mkdir -p "$DATA28"
seed_credential "$DATA28"
"$WORK/pdsd" --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$KEYGEN_DIR/key.hex" --token-secret "$KEYGEN_DIR/token.hex" \
  --data "$DATA28" --port 0 --init \
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
seed_credential "$DATA32"
"$WORK/pdsd" --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATA32" --port 0 \
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
seed_credential "$DATASUB"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATASUB" --port 0 --init \
  >"$WORK/servesub.out" 2>"$WORK/servesub.err" &
SERVER_PID=$!
PORTSUB=$(wait_for_port "$WORK/servesub.out") || {
  cat "$WORK/servesub.err" >&2
  fail 'subscription server did not report readiness'
}
require_empty "$WORK/servesub.err" 'subscription server startup'

# 33d. (#2937) the repository's CREATION announces itself. This server's
#    --data directory was created by the run that is now serving it, and a
#    subscriber attached at cursor 0 before any write has happened receives
#    exactly the four events com.atproto.sync.subscribeRepos opens a
#    repository with — #identity, #account, #commit, #sync — numbered 1
#    through 4, with the #sync CAR rooted at and holding only the genesis
#    commit the #commit event named. Without them a relay's stream begins
#    mid-story: a #commit whose `since` is null, for a DID it was never told
#    about.
#
#    The genesis #commit's OWN blocks CAR is opened as well, and has to hold
#    two blocks: the commit and the MST node the commit names as its data
#    root. A CAR of the commit alone announces a repository whose data root
#    the subscriber has no block for, which the reference's own verifyRepo
#    refuses — the #sync CAR passing is no evidence either way, because that
#    one is the commit alone by design.
#
#    This runs before case 34's login, which is the atomicity claim and not
#    just tidiness: the four are staged inside `configure`, before the
#    listener binds, so the first connection this server can possibly accept
#    already sees all four promoted. The driver's silence probe after the
#    fourth is what turns "four events" into "these four and nothing else".
subclient genesis "$PORTSUB" \
  || fail 'case 33d: a fresh repository did not announce its creation'

SUBLOGIN=$(client login "$PORTSUB" "$HANDLE" "$PASSWORD") \
  || fail 'case 34: login against the subscription server'
SUBACCESS=${SUBLOGIN%% *}

# 34. the live stream: a subscription opened with no cursor receives the
#    events of writes made AFTER it opened, in order. Two writes, not one —
#    a stream that delivered its first event and then stopped tailing would
#    pass a one-event case, and the consecutive sequence numbers are what
#    show the second arrived as a new event rather than as a replay.
#    This also plants events 5 and 6, which every cursor case below is
#    graded against — 5 and 6 rather than 1 and 2 because case 33d's four
#    creation events already hold 1 through 4.
subclient live "$PORTSUB" "$SUBACCESS" "$DID" "$COLLECTION" sublive \
  || fail 'case 34: live event delivery'

# 35. a cursor naming an event this server has never emitted is REFUSED, by
#    atproto's own name for it. Silence and a replay of something else are
#    both wrong answers that a status-only assertion would accept.
subclient future-cursor "$PORTSUB" 9999 \
  || fail 'case 35: a future cursor was not refused'

# 35b. #2907: a NEGATIVE cursor is refused by the handshake rather than
#    carried into arithmetic that has no meaning below zero — `toInt` accepts
#    "-5" happily, and a future cursor is caught by a comparison this one
#    passes. Refused with a 400 and never upgraded, which is a different shape
#    from case 35's error FRAME over a completed subscription.
subclient refused-cursor "$PORTSUB" -5 'must not be negative' \
  || fail 'case 35b: a negative cursor was not refused'

# 35c. and the refusal is DISTINGUISHABLE from the one a syntactically bad
#    cursor already got. Both are 400s on the same parameter, so a single
#    wording for the two would tell a client with an arithmetic bug and a
#    client with a serialization bug the same untrue thing. This asserts the
#    other message against the other input, which is what makes 35b's
#    assertion mean the pair differ rather than merely that some text matched.
subclient refused-cursor "$PORTSUB" notanumber 'is not a sequence number' \
  || fail 'case 35c: an unparsable cursor lost its own refusal wording'

# 36. a cursor at exactly the newest delivered event replays NOTHING and then
#    receives the next live event once: no duplicate of what the cursor
#    named, no gap over what followed it. The silence is graded BEFORE the
#    write, so a duplicate cannot hide behind the live event. Plants event 7.
subclient exact-cursor "$PORTSUB" 6 "$SUBACCESS" "$DID" "$COLLECTION" subexact \
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
seed_credential "$DATARL"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATARL" --port 0 --init --trusted-proxy \
  >"$WORK/serverl.out" 2>"$WORK/serverl.err" &
SERVER_PID=$!
PORTRL=$(wait_for_port "$WORK/serverl.out") || {
  cat "$WORK/serverl.err" >&2
  fail 'rate-limit server did not report readiness'
}
require_empty "$WORK/serverl.err" 'rate-limit server startup'

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

# 22. createSession class: login itself is rate-limited, independent of
#    every other class. It runs before any other login here, and its flood
#    presents a WRONG password: the class is charged when a request routes to
#    createSession, before the password is graded, so a refused login spends
#    the budget exactly as an accepted one does. That keeps every login in the
#    flood graded against the count-4 record this directory was seeded with.
#    The second identity's login is the first right-password one, and it is
#    what re-derives that record at the shipped count.
client rl-session "$PORTRL" 203.0.113.31 31 429 "$HANDLE" 'not the account password' \
  || fail 'case 22: createSession class did not refuse at its ceiling'
client rl-session "$PORTRL" 203.0.113.32 1 200 "$HANDLE" "$PASSWORD" \
  || fail "case 22: a second identity was refused by the first one's ceiling"

RLLOGIN=$(client login "$PORTRL" "$HANDLE" "$PASSWORD") || fail 'case 19: rate-limit login'
RLACCESS=${RLLOGIN%% *}

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

# ── sixth --data dir: the X-Forwarded-For byte/token caps (#2949) ──────────
# `--trusted-proxy` is on, matching the identity path this exercises: the
# byte-length and token-count caps in `lastHopToken` (`pds/lib/ratelimit.mdk`)
# REFUSE the request — 400 InvalidRequest — rather than demoting it to the
# shared `direct` identity, and the server goes on serving everyone else
# rather than wedging on the oversized value.
DATAXFF="$WORK/data-xff"
mkdir -p "$DATAXFF"
seed_credential "$DATAXFF"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATAXFF" --port 0 --init --trusted-proxy \
  >"$WORK/servexff.out" 2>"$WORK/servexff.err" &
SERVER_PID=$!
PORTXFF=$(wait_for_port "$WORK/servexff.out") || {
  cat "$WORK/servexff.err" >&2
  fail 'x-forwarded-for cap server did not report readiness'
}
require_empty "$WORK/servexff.err" 'x-forwarded-for cap server startup'

# 24a. an over-cap X-Forwarded-For is REFUSED, not demoted to the shared
#    bucket. Driven as the escape hatch itself, because a status-only "it was
#    answered" assertion passes just as well against a check that does
#    nothing: demotion answered 200 out of a bucket the sender had never
#    touched, which is a fresh allowance handed to whoever asks.
#
#    The setup is what makes the two outcomes tell apart. One identity spends
#    its OWN connections allowance (120 per window, the cheapest class to
#    reach), leaving `direct` on this freshly-started server untouched. That
#    same identity then sends its address behind an over-cap pad: demotion
#    lands it on the fresh `direct` bucket and is served, while a refusal is
#    400 InvalidRequest whatever any bucket says. Asserting 400 exactly — not
#    "some 4xx" — is also what keeps a coincidental 429 from passing this.
#
#    Both ceilings are driven, since either alone leaves the other's arm
#    unexercised: 8192 bytes of padding for `maxXffHeaderBytes`, and 64 short
#    hops ahead of the address for `maxXffTokens` (141 bytes, well under the
#    byte ceiling, so it can only be the token one that refuses it).
XFFCLIENT=203.0.113.202
XFFPAD=$(head -c 8192 /dev/zero | tr '\0' 'a')
XFFHOPS=$(head -c 64 /dev/zero | tr '\0' '1' | sed 's/./&,/g')
wait_for_window_room
client rl-conn "$PORTXFF" "$XFFCLIENT" 121 429 \
  || fail "case 24a: the client's own connections class did not refuse at its ceiling"
client rl-req "$PORTXFF" "${XFFPAD},${XFFCLIENT}" 1 400 \
  || fail 'case 24a: an over-cap X-Forwarded-For escaped to the shared bucket'
client rl-req "$PORTXFF" "${XFFHOPS}${XFFCLIENT}" 1 400 \
  || fail 'case 24a: an over-token X-Forwarded-For escaped to the shared bucket'
# ...and a different, honest client is still served, so refusing the padded
# header is not a server-wide outage.
client rl-req "$PORTXFF" 203.0.113.201 1 200 \
  || fail 'case 24a: the request after an over-cap X-Forwarded-For was refused'

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/servexff.err" 'x-forwarded-for cap server (post-run)'

# ── seventh and eighth --data dirs: the appview proxy (#2912) ───────────────
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

# The SECOND audience's egress proxy, on its own port and with its own log.
# Two separate logs are the whole apparatus for cases 54-57: "the chat call
# reached the chat service" and "the appview never saw it" are two claims, and
# one shared log could not carry the second.
"$WORK/appview" answer 0 "$WORK/chatstub.log" "$STUB_STATUS" \
  >"$WORK/chatstub.out" 2>"$WORK/chatstub.err" &
STUB_CHAT_PID=$!
STUB_PIDS="$STUB_PIDS $STUB_CHAT_PID"
CHATPORT=$(wait_for_stub_port "$WORK/chatstub.out" "$STUB_CHAT_PID") || {
  cat "$WORK/chatstub.err" >&2
  fail 'the stub chat service did not report readiness'
}

# 58. ALL OR NONE, PER ROW. An additional audience is a DID and a port, and a
#    row carrying only one of them is a startup refusal, exactly as
#    `--appview-did` without `--egress-port` already was. An operator who
#    believes a second service is configured and is wrong learns it here rather
#    than from a 400 on a header they expected to be honored.
#
#    Each refusal names the flag and the shape it wants, and none of them binds:
#    the same ordering every other configuration refusal keeps (#2659 item 4).
DATA58="$WORK/data58"
mkdir -p "$DATA58"
for BADROW in "$CHAT_DID" "$CHAT_DID=" "=3129"; do
  run_until_exit "$WORK/serve58.out" "$WORK/serve58.err" \
    --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
    --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
    --password-file "$WORK/password" --data "$DATA58" --port 0 --init \
    --appview-did "$APPVIEW_DID" --egress-port 3128 \
    --proxy-audience "$BADROW"
  [ "$RC" -ne 0 ] \
    || fail "case 58: --proxy-audience '$BADROW' was accepted"
  grep -F 'DID=PORT' "$WORK/serve58.err" >/dev/null \
    || fail "case 58: the refusal of '$BADROW' did not name the shape it wants"
  if grep -F 'serve: listening on' "$WORK/serve58.out" >/dev/null 2>&1; then
    fail "case 58: the listener bound before --proxy-audience '$BADROW' was graded"
  fi
done

# 58b. an additional audience with no DEFAULT pair is refused rather than
#    promoted to the default: a header-absent read has to go somewhere, and
#    which of an operator's audiences receives it is not this program's choice.
run_until_exit "$WORK/serve58b.out" "$WORK/serve58b.err" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --password-file "$WORK/password" --data "$DATA58" --port 0 --init \
  --proxy-audience "$CHAT_DID=3129"
[ "$RC" -ne 0 ] \
  || fail 'case 58b: --proxy-audience with no default audience was accepted'
grep -F -- '--proxy-audience requires --appview-did and --egress-port' \
  "$WORK/serve58b.err" >/dev/null \
  || fail 'case 58b: the refusal did not name the flags it requires'

# 58c. the same audience twice is refused. Two rows for one DID are two ports a
#    token minted for it could be sent to, and picking between them is picking
#    which upstream an operator's credential reaches.
run_until_exit "$WORK/serve58c.out" "$WORK/serve58c.err" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --password-file "$WORK/password" --data "$DATA58" --port 0 --init \
  --appview-did "$APPVIEW_DID" --egress-port 3128 \
  --proxy-audience "$APPVIEW_DID=3129"
[ "$RC" -ne 0 ] \
  || fail 'case 58c: one DID configured as two audiences was accepted'
grep -F "$APPVIEW_DID is configured as an audience twice" "$WORK/serve58c.err" \
  >/dev/null \
  || fail 'case 58c: the refusal did not name the repeated audience'

DATAPX="$WORK/data-proxy"
mkdir -p "$DATAPX"
seed_credential "$DATAPX"
# `--trusted-proxy` is on for case 47 alone, which needs two distinct client
# identities to show the proxied-read ceiling refuses one without refusing the
# other. Cases 44-46 send no `X-Forwarded-For` and so share the one `direct`
# bucket, exactly as they would on a server without the flag.
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATAPX" --port 0 --init --trusted-proxy \
  --appview-did "$APPVIEW_DID" --egress-port "$STUBPORT" \
  --proxy-audience "$CHAT_DID=$CHATPORT" \
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

# 44a. the allow-origin header (S-cors, #2938) reaches a PROXIED response too —
#    `lib.proxy`'s `proxyUpstreamResponse` builds this one, and it never
#    reaches `lib.server_core`'s `handle`, so nothing puts the header on it for
#    free.
client proxy-read-cors "$PORTPX" "$PXACCESS" "$APPVIEW_DID" "$TIMELINE" \
  "$STUB_STATUS" \
  || fail 'case 44a: a proxied response did not carry the allow-origin header'

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

# 54. THE SECOND AUDIENCE, END TO END. A `chat.bsky.*` read with a header naming
#    the chat DID reaches the CHAT egress proxy and not the appview's, and the
#    credential it arrives with is audienced for the chat service. Both stubs
#    are live and identical apart from their port, so what distinguishes them is
#    the routing and nothing else.
#
#    The appview's call count must not move. That is the half no assertion about
#    the claim set can make: a credential minted for the chat service and handed
#    to the appview's proxy carries a perfectly correct `aud`, so "the right
#    service was named" and "the right service received it" are different
#    claims, and only the second is the confused-deputy defense on this axis.
CALLS_PRE_CHAT=$(stub_calls "$WORK/stub.log")
CHAT_PRE=$(stub_calls "$WORK/chatstub.log")
client proxy-read "$PORTPX" "$PXACCESS" "$CHAT_DID" "$LISTCONVOS" \
  "$STUB_STATUS" '"lxm":"chat.bsky.convo.listConvos"' \
  || fail 'case 54: a read audienced for the second configured service was not proxied'
grep -F -q "call aud=$CHAT_DID lxm=chat.bsky.convo.listConvos iss=$DID" \
  "$WORK/chatstub.log" || {
  cat "$WORK/chatstub.log" >&2
  fail 'case 54: the chat service did not receive a credential naming itself and the requested method'
}
CHAT_POST=$(stub_calls "$WORK/chatstub.log")
[ "$CHAT_POST" -eq $((CHAT_PRE + 1)) ] \
  || fail 'case 54: the chat read did not reach the chat egress proxy exactly once'
CALLS_POST_CHAT=$(stub_calls "$WORK/stub.log")
[ "$CALLS_PRE_CHAT" = "$CALLS_POST_CHAT" ] || {
  cat "$WORK/stub.log" >&2
  fail "case 54: the chat read also reached the APPVIEW ($CALLS_PRE_CHAT -> $CALLS_POST_CHAT calls)"
}

# 55. THE CONVERSE. A timeline read audienced for the appview reaches only the
#    appview. Without it case 54 would be satisfied by a server that sent every
#    forward to the chat proxy, which is the same defect pointing the other way.
CHAT_PRE_TL=$(stub_calls "$WORK/chatstub.log")
CALLS_PRE_TL=$(stub_calls "$WORK/stub.log")
client proxy-read "$PORTPX" "$PXACCESS" "$APPVIEW_DID" "$TIMELINE" \
  "$STUB_STATUS" '"lxm":"app.bsky.feed.getTimeline"' \
  || fail 'case 55: a read audienced for the default service was not proxied'
CALLS_POST_TL=$(stub_calls "$WORK/stub.log")
[ "$CALLS_POST_TL" -eq $((CALLS_PRE_TL + 1)) ] \
  || fail 'case 55: the appview read did not reach the appview exactly once'
CHAT_POST_TL=$(stub_calls "$WORK/chatstub.log")
[ "$CHAT_PRE_TL" = "$CHAT_POST_TL" ] || {
  cat "$WORK/chatstub.log" >&2
  fail "case 55: the appview read also reached the CHAT service ($CHAT_PRE_TL -> $CHAT_POST_TL calls)"
}

# 56. A `chat.bsky.*` method with the header naming the APPVIEW goes to the
#    appview. The two axes are independent: the namespace decides whether a
#    method may be forwarded at all and the header decides to whom, so a server
#    that routed on the method's namespace would send this to the chat proxy.
CHAT_PRE_X=$(stub_calls "$WORK/chatstub.log")
CALLS_PRE_X=$(stub_calls "$WORK/stub.log")
client proxy-read "$PORTPX" "$PXACCESS" "$APPVIEW_DID" "$LISTCONVOS" \
  "$STUB_STATUS" '"aud":"'"$APPVIEW_DID"'"' \
  || fail 'case 56: a chat.bsky.* method audienced for the appview was not proxied'
CALLS_POST_X=$(stub_calls "$WORK/stub.log")
[ "$CALLS_POST_X" -eq $((CALLS_PRE_X + 1)) ] \
  || fail 'case 56: the appview-audienced chat method did not reach the appview'
CHAT_POST_X=$(stub_calls "$WORK/chatstub.log")
[ "$CHAT_PRE_X" = "$CHAT_POST_X" ] || {
  cat "$WORK/chatstub.log" >&2
  fail "case 56: a chat.bsky.* method was routed by its NAMESPACE rather than by the audience the header named"
}

# 57. an audience NEITHER row holds is still refused with nothing signed, and
#    neither stub is reached. The set grew; it did not stop being a set.
CHAT_PRE_F=$(stub_calls "$WORK/chatstub.log")
CALLS_PRE_F=$(stub_calls "$WORK/stub.log")
client proxy-read "$PORTPX" "$PXACCESS" "$ATTACKER_DID" "$LISTCONVOS" 400 \
  'atproto-proxy names a service this server does not proxy to' \
  || fail 'case 57: a header naming an unconfigured service was not refused'
[ "$CHAT_PRE_F" = "$(stub_calls "$WORK/chatstub.log")" ] \
  || fail 'case 57: a refused request still reached the chat service'
[ "$CALLS_PRE_F" = "$(stub_calls "$WORK/stub.log")" ] \
  || fail 'case 57: a refused request still reached the appview'

# 58. THE CREDENTIAL ITSELF. `com.atproto.server.getServiceAuth` is the same
#    seam pointed the other way: the client asks for the token rather than for
#    a call made with one, and keeps it. The audience asked for is the SECOND
#    configured one, so the answer also says the route grades against the
#    configured SET and not against the default row alone.
#
#    What makes this more than a 200 is the second half: the client spends the
#    token on the chat service directly, and the stub decodes the bearer it was
#    handed and echoes the `aud` and `lxm` it found. Those two values therefore
#    come from the credential's own bytes, read by the party the credential
#    names — which is the only reading of it that is not this implementation
#    grading itself.
#
#    The last assertion is the one the pure cells cannot make: the minted
#    credential must not appear in this server's OWN output. A bearer token in a
#    log is a bearer token anyone who can read the log may spend, and the text
#    to look for is only knowable from the client's side.
CHAT_PRE_SA=$(stub_calls "$WORK/chatstub.log")
SA_OUT=$(client service-auth "$PORTPX" "$PXACCESS" "$CHAT_DID" \
  'chat.bsky.convo.listConvos' "$CHATPORT") \
  || fail 'case 58: getServiceAuth did not yield a credential the chat service could read'
SA_TOKEN=${SA_OUT##*token=}
[ -n "$SA_TOKEN" ] || fail 'case 58: the client reported no minted credential'
case "$SA_TOKEN" in
  *.*.*) ;;
  *) fail 'case 58: what came back is not a compact JWS' ;;
esac
grep -F -q "call aud=$CHAT_DID lxm=chat.bsky.convo.listConvos iss=$DID" \
  "$WORK/chatstub.log" || {
  cat "$WORK/chatstub.log" >&2
  fail 'case 58: the chat service did not read the minted credential as naming itself and the requested method'
}
CHAT_POST_SA=$(stub_calls "$WORK/chatstub.log")
[ "$CHAT_POST_SA" -eq $((CHAT_PRE_SA + 1)) ] \
  || fail 'case 58: the minted credential was not spent on the chat service exactly once'
if grep -F -q "$SA_TOKEN" "$WORK/servepx.err" "$WORK/servepx.out"; then
  fail 'case 58: the minted credential appears in the server'"'"'s own output'
fi
# Reported without the credential in it, for the reason the case exists: this
# transcript is a log too.
echo "SERVICEAUTH: PASS the chat service read back the minted credential's own aud and lxm; ${#SA_TOKEN} characters, absent from the server's output"

# 58a. A REAL BROWSER PREFLIGHT on a proxied route (S-cors-fix, #2938). A
#    browser sends `OPTIONS` with no `Authorization` header before every
#    non-simple call, so this is the exact shape every proxied `app.bsky.*` /
#    `chat.bsky.*` call from the web arrives as. It must be answered 204 with
#    the five CORS headers, and it must not be forwarded.
#
#    It is driven HERE, over the live socket, and not as a `read_routes_
#    all_engines` cell: those call `lib.server_core`'s `handleBytes` directly,
#    which sits BELOW the three shell classifications (`upgradeDecision`,
#    `proxyDecisionFor`, `serviceAuthDecisionFor`) whose ordering is what this
#    fix changed. `proxyDecisionFor` resolves a credential before it looks at
#    the verb, so before the fix this exact request was answered 401 by
#    `admitForwardable` and `handleBytes` was never reached at all — a cell
#    below that seam cannot tell the two behaviors apart.
CALLS_PRE_PF=$(stub_calls "$WORK/stub.log")
CHAT_PRE_PF=$(stub_calls "$WORK/chatstub.log")
client preflight "$PORTPX" '/xrpc/app.bsky.feed.getTimeline' authorization \
  204 authorization \
  || fail 'case 58a: an unauthenticated preflight on a proxied app.bsky route was not answered 204'
client preflight "$PORTPX" '/xrpc/chat.bsky.convo.listConvos' authorization \
  204 authorization \
  || fail 'case 58a: an unauthenticated preflight on a proxied chat.bsky route was not answered 204'
[ "$CALLS_PRE_PF" = "$(stub_calls "$WORK/stub.log")" ] \
  || fail 'case 58a: a preflight was forwarded to the appview'
[ "$CHAT_PRE_PF" = "$(stub_calls "$WORK/chatstub.log")" ] \
  || fail 'case 58a: a preflight was forwarded to the chat service'

# 58b. THE PREFLIGHT VALUE IS CLIENT BYTES. `Access-Control-Request-Headers`
#    reaches this server through `http`'s inbound `validFieldValue`, which
#    admits TAB and every byte above 127; the outbound `validResponseValue`
#    admits only `32..126`. Before this fix the gap was a `panic` in
#    `lib.cors`'s `preflightResponse` — a single TAB byte from an
#    unauthenticated client killed the whole server process, and every
#    subsequent case on that server got nothing at all.
#
#    Both shapes must answer 204 with an EMPTY allow-headers value: the value
#    is dropped whole rather than echoed or stripped, so the answer allows no
#    extra request headers and the browser refuses the real call. The status is
#    asserted together with the value, because a 204 that echoed the bytes back
#    would satisfy a status-only check and is the shape that crashed.
#
#    The case AFTER each is the point: an ordinary request on the SAME server,
#    proving the process is still alive.
client preflight "$PORTPX" '/' tab 204 - \
  || fail 'case 58b: a TAB-bearing preflight was not answered 204 with an empty allow-headers'
client cors-get PREFLIGHTSURVIVEDTAB "$PORTPX" '' '/.well-known/atproto-did' \
  200 || fail 'case 58b: the server did not survive a TAB-bearing preflight'
client preflight "$PORTPX" '/' high 204 - \
  || fail 'case 58b: a high-byte preflight was not answered 204 with an empty allow-headers'
client cors-get PREFLIGHTSURVIVEDHIGH "$PORTPX" '' '/.well-known/atproto-did' \
  200 || fail 'case 58b: the server did not survive a high-byte preflight'
client preflight "$PORTPX" '/' none 204 - \
  || fail 'case 58b: a preflight asking for no headers was not answered 204'

# 58c. ALLOW-ORIGIN ON THE SHELL'S OWN EXITS (S-cors-fix, #2938). Eleven shell
#    responses are built and serialized without ever passing through
#    `lib.server_core`'s `handle`, which is the only thing that appends the
#    header for free. Two of them are graded here: `getServiceAuth`'s 200,
#    this sprint's own new browser-facing route, whose bytes come from
#    `mintedTokenBytes`; and the `ServiceAuthRefused` exit the same route takes
#    with no `Authorization` header. Neither may carry
#    `Access-Control-Allow-Credentials` — that header and `origin: *` are
#    mutually exclusive, and this server never issues the credentialed form.
client cors-get SERVICEAUTHCORS "$PORTPX" "$PXACCESS" \
  "/xrpc/com.atproto.server.getServiceAuth?aud=$CHAT_DID&lxm=chat.bsky.convo.listConvos" \
  200 \
  || fail 'case 58c: the getServiceAuth 200 did not carry the allow-origin header'
client cors-get SERVICEAUTHREFUSEDCORS "$PORTPX" '' \
  "/xrpc/com.atproto.server.getServiceAuth?aud=$CHAT_DID&lxm=chat.bsky.convo.listConvos" \
  401 \
  || fail 'case 58c: the getServiceAuth refusal did not carry the allow-origin header'

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
require_empty "$WORK/chatstub.err" 'stub chat service'

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
seed_credential "$DATAHOL"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
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

# 46a. AN UPSTREAM THAT ANSWERS AND DOES NOT CLOSE (#3097). Case 46's upstream
#    never answers and its 502 is correct. This one answers COMPLETELY and then
#    holds the socket open, which is what the first live deployment's egress
#    proxy did on roughly one proxied read in three hundred. A reader whose only
#    terminator is the peer's close cannot tell those two upstreams apart: it
#    spends the whole outbound silence budget waiting on a response already in
#    its own buffer, and the client is answered 502 over an appview answer that
#    arrived seconds earlier.
#
#    Graded on the STATUS the client sees — the stub's own, not a 502 — so no
#    timing threshold has to be chosen for a box under unknown load.
"$WORK/appview" linger 0 "$WORK/linger.log" "$STUB_STATUS" \
  >"$WORK/linger.out" 2>"$WORK/linger.err" &
STUB_LINGER_PID=$!
STUB_PIDS="$STUB_PIDS $STUB_LINGER_PID"
LINGERPORT=$(wait_for_stub_port "$WORK/linger.out" "$STUB_LINGER_PID") || {
  cat "$WORK/linger.err" >&2
  fail 'case 46a: the lingering stub appview did not report readiness'
}

DATALNG="$WORK/data-proxy-linger"
mkdir -p "$DATALNG"
seed_credential "$DATALNG"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATALNG" --port 0 --init \
  --appview-did "$APPVIEW_DID" --egress-port "$LINGERPORT" \
  >"$WORK/servelng.out" 2>"$WORK/servelng.err" &
SERVER_PID=$!
PORTLNG=$(wait_for_port "$WORK/servelng.out") || {
  cat "$WORK/servelng.err" >&2
  fail 'case 46a: the lingering-upstream server did not report readiness'
}
require_empty "$WORK/servelng.err" 'case 46a startup'

LNGLOGIN=$(client login "$PORTLNG" "$HANDLE" "$PASSWORD") \
  || fail 'case 46a: login against the lingering-upstream server'
LNGACCESS=${LNGLOGIN%% *}

client proxy-read "$PORTLNG" "$LNGACCESS" "$APPVIEW_DID" "$TIMELINE" \
  "$STUB_STATUS" '"appview":"stub"' \
  || fail 'case 46a: an upstream that answered and did not close was not relayed to the client'
grep -F -q "call aud=$APPVIEW_DID lxm=app.bsky.feed.getTimeline iss=$DID" \
  "$WORK/linger.log" || {
  cat "$WORK/linger.log" >&2
  fail 'case 46a: the lingering upstream never saw the forwarded call'
}

# A SECOND call over a second connection: a reader that stops at a response's
# end must leave nothing behind it, and a first call that succeeded by
# abandoning its connection would be this same defect wearing a success.
client proxy-read "$PORTLNG" "$LNGACCESS" "$APPVIEW_DID" "$TIMELINE" \
  "$STUB_STATUS" '"appview":"stub"' \
  || fail 'case 46a: a second proxied read against the same lingering upstream was not relayed'

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/servelng.err" 'case 46a (post-run)'

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
seed_credential "$DATADEAF"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
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
#    eight dials are left stuck against the deaf proxy, so no ninth call can be
#    admitted while they hold their slots.
#
#    What the ninth gets is the ADMISSION QUEUE's answer, not the ceiling's
#    (#3100): it waits, and it is refused only because these eight hold their
#    slots for the whole of a connect budget that outlasts `proxyQueueWait`.
#    That is why this case proves the ceiling and case 51c proves the refusal -
#    a call refused HERE has spent the queue's deadline first, and this case
#    cannot tell a queue that refuses promptly from one that never admits.
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

# 51c. OVERLOAD IS STILL REFUSED, AND REFUSED PROMPTLY (#3100). The admission
#    queue turns a legitimate burst into latency; it must NOT turn genuine
#    overload into latency too, or the 503 has been moved rather than removed.
#    `proxy-overload` leaves the ceiling AND the whole queue outstanding - 8 in
#    flight and 16 waiting, all of them against this same deaf proxy - and then
#    asks for three more reads, one at a time, timing each.
#
#    The 300ms budget is the discriminator and is the whole case. A call
#    refused past a FULL queue costs nothing but the decision, while a call
#    that got INTO the queue waits `proxyQueueWait` - 2s - before being
#    refused, and the two are indistinguishable on status and error code alike.
#    A change that simply admitted everything would pass case 51b and fail
#    here; a queue that made every refusal wait out its deadline would pass
#    every status assertion in this file and fail here too.
client proxy-overload "$PORTDEAF" "$DEAFACCESS" "$APPVIEW_DID" "$TIMELINE" \
  24 3 300 \
  || fail 'case 51c: a proxied read past the ceiling AND a full admission queue was not refused 503 ProxyLimitExceeded promptly'
client query "$PORTDEAF" "$DID" \
  || fail 'case 51c: an ordinary read was refused while the admission queue was full'
# The 24 calls 51c left outstanding are still spending their own budgets: the
# queued ones until `proxyQueueWait`, the dialling ones until the connect
# budget. Let them all land before this server is taken down, so that what its
# stderr is graded on below is a server that finished its work rather than one
# interrupted in the middle of it.
sleep 6

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/servedeaf.err" 'case 50/51 (post-run)'
require_empty "$WORK/deaf.err" 'deaf stub appview'
kill "$STUB_DEAF_PID" 2>/dev/null || true
wait "$STUB_DEAF_PID" 2>/dev/null || true

# ── a dedicated --data dir: the egress byte budget (#3264) ──────────────────
# Case 51 bounds how MANY proxied calls are in flight; this one bounds how many
# BYTES of upstream answer they hold between them. A call is charged a whole
# `maxInFlightEgressBytes` (`pds/lib/resource_limits.mdk`) once its answer
# passes `maxUnchargedEgressBytes` (256 KiB), so the budget holds ONE large
# answer at a time. The stub runs in `bulk` mode: it holds two calls, sends
# each 272 KiB of a 384 KiB answer - past the allowance, so both must be
# charged - the first a moment before the second, and then keeps both open a
# byte at a time for seven seconds before finishing them.
"$WORK/appview" bulk 0 "$WORK/bulk.log" "$STUB_STATUS" 2 393216 278528 7000 \
  >"$WORK/bulk.out" 2>"$WORK/bulk.err" &
STUB_BULK_PID=$!
STUB_PIDS="$STUB_PIDS $STUB_BULK_PID"
BULKPORT=$(wait_for_stub_port "$WORK/bulk.out" "$STUB_BULK_PID") || {
  cat "$WORK/bulk.err" >&2
  fail 'case 51d: the bulk stub appview did not report readiness'
}

DATABULK="$WORK/data-proxy-bulk"
mkdir -p "$DATABULK"
seed_credential "$DATABULK"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATABULK" --port 0 --init \
  --appview-did "$APPVIEW_DID" --egress-port "$BULKPORT" \
  >"$WORK/servebulk.out" 2>"$WORK/servebulk.err" &
SERVER_PID=$!
PORTBULK=$(wait_for_port "$WORK/servebulk.out") || {
  cat "$WORK/servebulk.err" >&2
  fail 'case 51d: the egress-budget server did not report readiness'
}
require_empty "$WORK/servebulk.err" 'case 51d startup'

BULKLOGIN=$(client login "$PORTBULK" "$HANDLE" "$PASSWORD") \
  || fail 'case 51d: login against the egress-budget server'
BULKACCESS=${BULKLOGIN%% *}

# 51d. THE EGRESS BYTE BUDGET. Two large answers are in flight together and
#    only one fits: the first call is charged and relayed in full, and the
#    second waits `egressQueueWait` (5s) for headroom that the first never
#    gives back in time, so it is refused `503 ProxyEgressLimitExceeded`. An
#    ordinary read is answered while both are held, and a large call made after
#    the first has finished is charged and relayed like any other.
#
#    The timing is what makes the refusal the budget's. The stub keeps the
#    first answer arriving a byte every half second, so it is never silent
#    long enough for the PDS's own read budgets to end it, and holds it for
#    seven seconds - two past the second call's wait and two short of the
#    first call's ten-second upstream deadline. A PDS that charged nothing
#    would read both answers to the end and relay the second as 203; one that
#    refused on the call COUNT would answer `ProxyLimitExceeded`, which is why
#    the code is graded and not only the status. The `kill -0` proves the first
#    call still held its charge when the second was refused: had it already
#    finished, the second would have been owed headroom and not a refusal.
#
#    The later call is the release. It is charged exactly as the first was, so
#    a charge the first call never gave back would leave it no headroom and it
#    would be refused after its own wait instead of relayed.
client proxy-read "$PORTBULK" "$BULKACCESS" "$APPVIEW_DID" "$TIMELINE" \
  "$STUB_STATUS" '' >"$WORK/bulkfirst.out" 2>&1 &
BULK_FIRST_PID=$!
# The stub holds its first call until the second arrives, so the first has to
# have been forwarded - and its dial made - before the second is sent.
sleep 0.5
client proxy-read "$PORTBULK" "$BULKACCESS" "$APPVIEW_DID" "$TIMELINE" 503 \
  ProxyEgressLimitExceeded >"$WORK/bulksecond.out" 2>&1 &
BULK_SECOND_PID=$!
# Long enough for both prefixes to have been sent and read, and far short of
# the second call's wait.
sleep 1

client query "$PORTBULK" "$DID" \
  || fail 'case 51d: an ordinary read was not answered while two large proxied answers were in flight'

wait "$BULK_SECOND_PID" || {
  cat "$WORK/bulksecond.out" >&2
  fail 'case 51d: a second large proxied answer past the egress budget was not refused 503 ProxyEgressLimitExceeded'
}
kill -0 "$BULK_FIRST_PID" 2>/dev/null || {
  cat "$WORK/bulkfirst.out" >&2
  fail 'case 51d: the first large proxied call had already finished when the second was refused, so the refusal was not the budget holding one answer in flight'
}
wait "$BULK_FIRST_PID" || {
  cat "$WORK/bulkfirst.out" >&2
  fail 'case 51d: the large proxied answer that held the egress budget was not relayed'
}
cat "$WORK/bulkfirst.out" "$WORK/bulksecond.out"

client proxy-read "$PORTBULK" "$BULKACCESS" "$APPVIEW_DID" "$TIMELINE" \
  "$STUB_STATUS" '' \
  || fail 'case 51d: the egress budget was not given back - a later large proxied answer was refused'

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/servebulk.err" 'case 51d (post-run)'
require_empty "$WORK/bulk.err" 'bulk stub appview'
kill "$STUB_BULK_PID" 2>/dev/null || true
wait "$STUB_BULK_PID" 2>/dev/null || true

# ── tenth --data dir: the admission queue (#3100) ───────────────────────────
# The client this server exists for fans out more proxied reads on a cold start
# than the in-flight ceiling admits - ten measured against a ceiling of eight -
# so a ceiling that refused the excess outright rendered part of a healthy
# app's first screen as an error. Case 51b is that fan-out.
#
# The stub runs in `batch` mode with the ceiling as its count: it answers none
# of the first eight calls until all eight have arrived. That is what makes the
# concurrency this case's own rather than the scheduler's - an upstream that
# answered as it went would let the server finish one call before the next was
# made, and twelve reads could be served with three ever outstanding, which
# looks identical from the client and proves nothing about a ceiling of eight.
"$WORK/appview" batch 0 "$WORK/queue.log" "$STUB_STATUS" 8 \
  >"$WORK/queue.out" 2>"$WORK/queue.err" &
STUB_QUEUE_PID=$!
STUB_PIDS="$STUB_PIDS $STUB_QUEUE_PID"
QUEUEPORT=$(wait_for_stub_port "$WORK/queue.out" "$STUB_QUEUE_PID") || {
  cat "$WORK/queue.err" >&2
  fail 'case 51b: the batching stub appview did not report readiness'
}

DATAQUEUE="$WORK/data-proxy-queue"
mkdir -p "$DATAQUEUE"
seed_credential "$DATAQUEUE"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATAQUEUE" --port 0 --init \
  --appview-did "$APPVIEW_DID" --egress-port "$QUEUEPORT" \
  >"$WORK/servequeue.out" 2>"$WORK/servequeue.err" &
SERVER_PID=$!
PORTQUEUE=$(wait_for_port "$WORK/servequeue.out") || {
  cat "$WORK/servequeue.err" >&2
  fail 'case 51b: the admission-queue server did not report readiness'
}
require_empty "$WORK/servequeue.err" 'case 51b startup'

QUEUELOGIN=$(client login "$PORTQUEUE" "$HANDLE" "$PASSWORD") \
  || fail 'case 51b: login against the admission-queue server'
QUEUEACCESS=${QUEUELOGIN%% *}

# 51b. TWELVE AT ONCE, ALL OF THEM SERVED. Every request is sent before any
#    answer is read, so the server holds all twelve and its own admission
#    decision - not this client's pacing - settles how many are served. Four of
#    them are past the ceiling and must wait for a slot rather than be refused.
#
#    Graded on the UPSTREAM's status (203) and not on 200, so a server that
#    composed an answer of its own around a forwarded body is not counted as
#    having served the call. Before the queue existed this case read
#    `203=8 503=4`.
client proxy-fanout "$PORTQUEUE" "$QUEUEACCESS" "$APPVIEW_DID" "$TIMELINE" \
  12 "$STUB_STATUS" 12 \
  || fail 'case 51b: a twelve-call fan-out was not served in full - a burst past the in-flight ceiling was refused instead of queued'
client query "$PORTQUEUE" "$DID" \
  || fail 'case 51b: an ordinary read was refused after the fan-out'

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/servequeue.err" 'case 51b (post-run)'
require_empty "$WORK/queue.err" 'batching stub appview'
kill "$STUB_QUEUE_PID" 2>/dev/null || true
wait "$STUB_QUEUE_PID" 2>/dev/null || true

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
seed_credential "$DATACRAWL"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
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
seed_credential "$DATANOCRAWL"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
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

# 59. `pdsd --version` reports the build it is running. The build above passed
#    --stamp-build, so the three provenance externs read real strings and the
#    version line carries them; without the flag the same binary reports the
#    bare `pdsd 0.1.0`, which is what makes this a test of the stamp rather
#    than of the version constant. The date half is asserted by shape (it is
#    always derivable); the commit half is asserted against THIS checkout's own
#    short hash, and only when git can name one, so a tree with no usable `.git`
#    still grades the rest rather than reddening on its own environment.
VERSION_LINE=$("$WORK/pdsd" --version) \
  || fail 'case 59: pdsd --version exited nonzero'
printf '%s\n' "$VERSION_LINE" \
  | grep -Eq '^pdsd 0\.1\.0 \(.*built [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$' \
  || fail "case 59: pdsd --version carries no build stamp: $VERSION_LINE"
STAMP_COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)
if [ -n "$STAMP_COMMIT" ]; then
  # Substring, not equality: a modified tree stamps `<short>-dirty`.
  printf '%s\n' "$VERSION_LINE" | grep -Fq "$STAMP_COMMIT" \
    || fail "case 59: pdsd --version names no commit ($STAMP_COMMIT): $VERSION_LINE"
fi

# 60. the periodic stats line (S-stats-line, #2966): active/un-framed
#    connections, open subscriptions, the account repo's revision, and
#    blocks/blobs already on disk. `--stats-interval-ms` shortens the
#    interval so this case does not wait the 60s default.
DATASTATS="$WORK/data-stats"
mkdir -p "$DATASTATS"
seed_credential "$DATASTATS"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATASTATS" --port 0 --init --stats-interval-ms 200 \
  >"$WORK/servestats.out" 2>"$WORK/servestats.err" &
SERVER_PID=$!
PORTSTATS=$(wait_for_port "$WORK/servestats.out") || {
  cat "$WORK/servestats.err" >&2
  fail 'case 60: the stats-line server did not report readiness'
}
require_empty "$WORK/servestats.err" 'case 60 startup'
client query "$PORTSTATS" "$DID" \
  || fail 'case 60: the stats-line server did not answer an ordinary request'

# A freshly-`--init`ed server has zero blobs on disk, which exercises
# `blobFileCount`'s walk only on an empty directory. Uploading a couple of
# blobs here — through the real socket, the same path case 4b uses — drives
# that walk over actual shards and leaves, including its `Err _ => ()`
# drop-the-line arm, before the stats line is read below.
STATSLOGIN=$(client login "$PORTSTATS" "$HANDLE" "$PASSWORD") \
  || fail 'case 60: login on the stats-line server'
STATSTOKEN=${STATSLOGIN%% *}
STATS_BLOB_CID=$(
  client upload-blob "$PORTSTATS" "$STATSTOKEN" "$BLOB_MIME" "$BLOB_TEXT"
) || fail 'case 60: uploadBlob on the stats-line server'
[ -n "$STATS_BLOB_CID" ] \
  || fail 'case 60: uploadBlob on the stats-line server returned an empty CID'
STATS_BLOB2_CID=$(
  client upload-blob "$PORTSTATS" "$STATSTOKEN" "$BLOB2_MIME" "$BLOB2_TEXT"
) || fail 'case 60: second uploadBlob on the stats-line server'
[ -n "$STATS_BLOB2_CID" ] \
  || fail 'case 60: second uploadBlob on the stats-line server returned an empty CID'

# Waits for a line with a NONZERO blobs field specifically, not merely a
# well-shaped one: the very first tick fires before the two uploads above
# necessarily land, so a shape-only wait can break on that earlier line and
# read it back as "no stats line yet" instead of "blobs not caught up yet".
i=0
while [ "$i" -lt 100 ]; do
  if grep -Eq '^serve: stats active=[0-9]+ unframed=[0-9]+ subscriptions=[0-9]+ rev=\S+ blocks=[0-9]+ blobs=[1-9][0-9]*$' \
    "$WORK/servestats.out"
  then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
STATS_LINE=$(grep -E '^serve: stats ' "$WORK/servestats.out" | tail -1)
[ -n "$STATS_LINE" ] || {
  cat "$WORK/servestats.out" >&2
  fail 'case 60: no stats line was emitted within 10s'
}
printf '%s\n' "$STATS_LINE" \
  | grep -Eq '^serve: stats active=[0-9]+ unframed=[0-9]+ subscriptions=[0-9]+ rev=\S+ blocks=[0-9]+ blobs=[0-9]+$' \
  || fail "case 60: stats line missing an expected field: $STATS_LINE"
printf '%s\n' "$STATS_LINE" | grep -Fq ' rev=- ' \
  && fail "case 60: a configured account repo's stats line carries no revision: $STATS_LINE"
printf '%s\n' "$STATS_LINE" | grep -Eq ' blocks=0 ' \
  && fail "case 60: a freshly initialized repository's stats line reports zero blocks: $STATS_LINE"
printf '%s\n' "$STATS_LINE" | grep -Eq ' blobs=0$' \
  && fail "case 60: a repo with two uploaded blobs on disk reports zero blobs: $STATS_LINE"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/servestats.err" 'case 60 (post-run)'

# ── a dedicated --data dir: one writer per directory (#3059) ────────────────
# Two servers over one --data directory delete each other's work: each start
# sweeps every file under `.staging`, and a file there means residue from a
# prior crash only while no OTHER process is between a write and its `rename`.
# `pds/shell/dirlock.mdk` is what makes that window exclusive, and these four
# cases grade the three states it can be in — held, abandoned, and abandoned
# with a half-finished event-log append still owed.

DATALOCK="$WORK/data-lock"
mkdir -p "$DATALOCK"
seed_credential "$DATALOCK"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATALOCK" --port 0 --init \
  >"$WORK/servelock.out" 2>"$WORK/servelock.err" &
SERVER_PID=$!
PORTLOCK=$(wait_for_port "$WORK/servelock.out") || {
  cat "$WORK/servelock.err" >&2
  fail 'case 61: the lock-holding server did not report readiness'
}
require_empty "$WORK/servelock.err" 'case 61 startup'
grep -Fq 'serve: data directory lock: acquired' "$WORK/servelock.out" \
  || fail 'case 61: the holder did not report taking the lock'
client query "$PORTLOCK" "$DID" \
  || fail 'case 61: the lock-holding server did not answer an ordinary request'

# 61. a second process against a LIVE data directory is refused, and refused
#    BEFORE the sweep that would destroy what it was refused for. The file
#    planted below is what a promotion the live server has in flight looks
#    like on disk; that it is STILL THERE afterwards is the ordering claim,
#    which the exit status on its own would not make.
mkdir -p "$DATALOCK/blocks/.staging"
printf 'in-flight\n' > "$DATALOCK/blocks/.staging/inflight"
# `run_until_exit` binds $SERVER_PID to the process it runs, so the live
# holder's pid is saved across it the way case 4f saves the main instance's.
LOCK_HOLDER_PID="$SERVER_PID"
run_until_exit "$WORK/serve61.out" "$WORK/serve61.err" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATALOCK" --port 0
SERVER_PID="$LOCK_HOLDER_PID"
[ "$RC" -ne 0 ] \
  || fail 'case 61: a second process over a live data directory was accepted'
grep -Fq 'is already locked by a running server' "$WORK/serve61.err" \
  || fail 'case 61: the refusal did not name the lock'
grep -Fq -e '--force-lock' "$WORK/serve61.err" \
  || fail 'case 61: the refusal did not name the remedy'
[ -f "$DATALOCK/blocks/.staging/inflight" ] \
  || fail "case 61: the refused process swept the live holder's staged file"
if grep -F 'serve: listening on' "$WORK/serve61.out" >/dev/null 2>&1; then
  fail 'case 61: the refused process bound a listener'
fi
# The live holder is still serving, which is what makes the refusal above a
# refusal of the SECOND process rather than of both.
client query "$PORTLOCK" "$DID" \
  || fail 'case 61: the lock holder stopped answering after refusing a rival'
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/servelock.err" 'case 61 (post-run)'

# 62. a `mkdir` lock is not released by a process that is killed, so the lock
#    the holder above left behind is still there and still freshly beaten.
#    `--force-lock` is the documented remedy for an operator who knows it is
#    gone: it takes the lock without waiting the stale window out. The residue
#    planted in case 61 is gone afterwards, which is how this case proves the
#    run went PAST the sweep rather than merely past the lock.
[ -d "$DATALOCK/.lock" ] \
  || fail 'case 62: a killed holder released its lock, so nothing is being tested'
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATALOCK" --port 0 --force-lock \
  >"$WORK/serve62.out" 2>"$WORK/serve62.err" &
SERVER_PID=$!
PORT62=$(wait_for_port "$WORK/serve62.out") || {
  cat "$WORK/serve62.err" >&2
  fail 'case 62: --force-lock did not get past a lock its holder had left behind'
}
require_empty "$WORK/serve62.err" 'case 62 startup'
grep -Fq 'serve: data directory lock: taken with --force-lock' "$WORK/serve62.out" \
  || fail 'case 62: the run did not report forcing the lock'
[ ! -e "$DATALOCK/blocks/.staging/inflight" ] \
  || fail 'case 62: the run that took the lock never reached the sweep'
client query "$PORT62" "$DID" \
  || fail 'case 62: the server that forced the lock did not answer a request'
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve62.err" 'case 62 (post-run)'

# 63. and with NO flag at all: a lock whose heartbeat has stopped is reclaimed
#    on its own. This is the ordinary restart — a supervisor that had to pass
#    a flag after every kill would be an operator trained to always pass it,
#    which is a lock nobody has.
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATALOCK" --port 0 \
  >"$WORK/serve63.out" 2>"$WORK/serve63.err" &
SERVER_PID=$!
PORT63=$(wait_for_port "$WORK/serve63.out") || {
  cat "$WORK/serve63.err" >&2
  fail 'case 63: a restart over a lock left by a killed process never started'
}
require_empty "$WORK/serve63.err" 'case 63 startup'
grep -Fq 'serve: data directory lock: reclaimed after' "$WORK/serve63.out" \
  || fail 'case 63: the restart did not report reclaiming an abandoned lock'
client query "$PORT63" "$DID" \
  || fail 'case 63: the server that reclaimed the lock did not answer a request'
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve63.err" 'case 63 (post-run)'

# 64. the startup ORDER the genesis guard depends on, graded rather than
#    documented (F5). A process that died between promoting an event's own
#    file and moving the last-promoted pointer leaves the staged copy behind
#    and the pointer where it stood — here, reconstructed by hand from the log
#    this directory already holds. `configure` applies the event-log recovery
#    BEFORE it completes the genesis quartet, and only in that order is this a
#    start rather than a refusal: read first, the pointer says nothing was
#    ever promoted over an entry directory that is not empty, which
#    `refuseLostPointer` refuses. Swap those two calls and this case reds.
LOCK_LAST_ENTRY=$(ls -1 "$DATALOCK/events/entries" | tail -1)
[ -n "$LOCK_LAST_ENTRY" ] \
  || fail 'case 64: the event log holds no promoted entry to interrupt'
LOCK_ENTRIES_BEFORE=$(ls -1 "$DATALOCK/events/entries" | wc -l)
cp "$DATALOCK/events/entries/$LOCK_LAST_ENTRY" "$DATALOCK/events/.staged"
rm -f "$DATALOCK/events/.last"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATALOCK" --port 0 --force-lock \
  >"$WORK/serve64.out" 2>"$WORK/serve64.err" &
SERVER_PID=$!
PORT64=$(wait_for_port "$WORK/serve64.out") || {
  cat "$WORK/serve64.err" >&2
  fail 'case 64: a lost pointer over a recoverable staged entry refused the start'
}
require_empty "$WORK/serve64.err" 'case 64 startup'
grep -Fq 'serve: event log recovery: promoted' "$WORK/serve64.out" \
  || fail 'case 64: the owed entry was not promoted'
[ "$(cat "$DATALOCK/events/.last")" = "$(ls -1 "$DATALOCK/events/entries" | tail -1 | sed 's/^0*\([0-9]*\)-.*/\1/')" ] \
  || fail 'case 64: the recovered pointer does not name the last promoted entry'
[ ! -e "$DATALOCK/events/.staged" ] \
  || fail 'case 64: the pending entry survived its own recovery'
# The quartet was NOT re-minted over the history that already holds it, which
# is the damage `refuseLostPointer` exists to prevent and which a recovery run
# in the wrong order would either cause or falsely refuse.
[ "$(ls -1 "$DATALOCK/events/entries" | wc -l)" = "$LOCK_ENTRIES_BEFORE" ] \
  || fail 'case 64: the genesis quartet was emitted a second time'
client query "$PORT64" "$DID" \
  || fail 'case 64: the recovered server did not answer a request'
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve64.err" 'case 64 (post-run)'

# 65. a CROWD of servers started at once over a directory whose holder is gone.
#    Exactly one may come away holding it: two is the corruption the lock
#    exists to prevent, and zero is a directory no restart can recover — and
#    both were reachable before the lock claimed a fresh generation instead of
#    moving the old one aside, because a shared quarantine name every
#    contender's cleanup could remove made one contender's success depend on
#    another's not having run yet. The contenders are
#    `pds/test/dirlock_race_main.mdk` rather than whole servers: a round of
#    eight `pdsd`s would grade this through several seconds of repository
#    startup that has nothing to do with the lock.
RACEDIR="$WORK/data-race"
ROUND=1
while [ "$ROUND" -le 5 ]; do
  RD="$RACEDIR/round$ROUND"
  # An abandoned holder: a heartbeat far enough in the past that every
  # contender grades it stale, which is the state a killed server leaves.
  mkdir -p "$RD/.lock/gen.0"
  printf '1000000000\n' > "$RD/.lock/gen.0/owner"
  C=1
  RACE_PIDS=""
  while [ "$C" -le 8 ]; do
    "$WORK/race" "$RD" wait 600 > "$RD/out.$C" 2>&1 &
    RACE_PIDS="$RACE_PIDS $!"
    C=$((C + 1))
  done
  # Each contender by pid, never a bare `wait`: the stub appviews this script
  # started for the proxy cases are still running, and a bare one would wait
  # for those too and never return.
  for pid in $RACE_PIDS; do
    wait "$pid" 2>/dev/null || true
  done
  HELD=$(cat "$RD"/out.* | grep -c '^HELD' || true)
  [ "$HELD" -eq 1 ] \
    || fail "case 65: round $ROUND left $HELD holders of $RD/.lock, expected exactly 1"
  # The winner must still hold at the end of its own run: a contender that
  # took the lock and had it taken back is the same two-writer window seen
  # from the other side.
  ! grep -lq '^LOST' "$RD"/out.* 2>/dev/null \
    || fail "case 65: round $ROUND had the lock taken back from its winner"
  ROUND=$((ROUND + 1))
done

# 66. a `.lock` an editor, a backup or an rsync left behind. The lock is a
#    DIRECTORY holding one generation per claim, so foreign content beside
#    those generations is ignored rather than refused — a lock whose whole job
#    is to be recoverable must not be wedged by residue it did not write. What
#    cannot be ignored is something that is not a directory at that path, and
#    that is the one case `--force-lock` is about residue rather than about a
#    holder.
WEDGE="$WORK/data-wedge-dir"
mkdir -p "$WEDGE/.lock"
printf 'left by something that is not a server\n' > "$WEDGE/.lock/README"
seed_credential "$WEDGE"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$WEDGE" --port 0 --init \
  >"$WORK/serve66a.out" 2>"$WORK/serve66a.err" &
SERVER_PID=$!
PORT66=$(wait_for_port "$WORK/serve66a.out") || {
  cat "$WORK/serve66a.err" >&2
  fail 'case 66: a stray file beside the lock refused a start'
}
require_empty "$WORK/serve66a.err" 'case 66 (stray entry) startup'
[ -f "$WEDGE/.lock/README" ] \
  || fail 'case 66: the server deleted a file under .lock it did not write'
client query "$PORT66" "$DID" \
  || fail 'case 66: the server that started beside a stray entry did not answer'
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# and the other shape: `.lock` is a plain FILE. No generation can be created
# inside one, so no start ever gets past it — the refusal must name the path
# and the remedy, and `--force-lock` must actually be that remedy.
FWEDGE="$WORK/data-wedge-file"
mkdir -p "$FWEDGE"
printf 'not a lock\n' > "$FWEDGE/.lock"
run_until_exit "$WORK/serve66b.out" "$WORK/serve66b.err" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --password-file "$WORK/password" \
  --data "$FWEDGE" --port 0 --init
[ "$RC" -ne 0 ] \
  || fail 'case 66: a start over a .lock that is a plain file was accepted'
grep -Fq "$FWEDGE/.lock" "$WORK/serve66b.err" \
  || fail 'case 66: the refusal did not name the path it is about'
grep -Fq -e '--force-lock' "$WORK/serve66b.err" \
  || fail 'case 66: the refusal did not name the remedy'
[ -f "$FWEDGE/.lock" ] \
  || fail 'case 66: the refused run removed the file it refused over'
seed_credential "$FWEDGE"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$FWEDGE" --port 0 --init --force-lock \
  >"$WORK/serve66c.out" 2>"$WORK/serve66c.err" &
SERVER_PID=$!
PORT66C=$(wait_for_port "$WORK/serve66c.out") || {
  cat "$WORK/serve66c.err" >&2
  fail 'case 66: --force-lock did not get past a .lock that is a plain file'
}
require_empty "$WORK/serve66c.err" 'case 66 (forced) startup'
[ -d "$FWEDGE/.lock" ] \
  || fail 'case 66: --force-lock did not replace the file with a lock directory'
client query "$PORT66C" "$DID" \
  || fail 'case 66: the server that forced past the stray file did not answer'
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# 67. a holder whose lock is taken from it STOPS. `--force-lock` is an
#    operator asserting the recorded holder is gone; when it is not gone, the
#    two servers that assertion creates are exactly the pair this whole module
#    exists to prevent, so the one that lost the directory ends its run rather
#    than going on writing beneath it. This is also what bounds a startup too
#    slow to beat: a lock reclaimed under a still-starting process is noticed
#    at its next beat instead of being written through.
LOSER="$WORK/data-loser"
mkdir -p "$LOSER"
seed_credential "$LOSER"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$LOSER" --port 0 --init \
  >"$WORK/serve67a.out" 2>"$WORK/serve67a.err" &
SERVER_PID=$!
wait_for_port "$WORK/serve67a.out" >/dev/null || {
  cat "$WORK/serve67a.err" >&2
  fail 'case 67: the first server never started'
}
# Saved across the second start the way case 61 saves the live holder's pid:
# `SERVER_PID` is what the exit trap reaps, and the second server is the one
# that needs reaping from here on.
LOSER_PID="$SERVER_PID"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$LOSER" --port 0 --force-lock \
  >"$WORK/serve67b.out" 2>"$WORK/serve67b.err" &
SERVER_PID=$!
wait_for_port "$WORK/serve67b.out" >/dev/null || {
  cat "$WORK/serve67b.err" >&2
  fail 'case 67: the forcing server never started'
}
i=0
while [ "$i" -lt 60 ]; do
  kill -0 "$LOSER_PID" 2>/dev/null || break
  i=$((i + 1))
  sleep 0.1
done
if kill -0 "$LOSER_PID" 2>/dev/null; then
  kill "$LOSER_PID" 2>/dev/null || true
  wait "$LOSER_PID" 2>/dev/null || true
  fail 'case 67: the server whose lock was forced away is still serving'
fi
wait "$LOSER_PID" 2>/dev/null || true
grep -Fq 'lock' "$WORK/serve67a.err" \
  || fail 'case 67: the displaced server ended without saying why'
grep -Fq "$LOSER" "$WORK/serve67a.err" \
  || fail 'case 67: the displaced server did not name the directory it lost'
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve67b.err" 'case 67 (post-run)'

# 68. The idle server must wake out of the scheduler's otherwise indefinite
# listener poll, close its listener, log the drain and exit well before its
# 95-second forced-stop budget. Use a fresh directory so this test can tell a
# clean stop from a restart made safe by an earlier case's crash recovery.
DATA="$WORK/data-term-idle"
mkdir -p "$DATA"
seed_credential "$DATA"
start_server --init "$WORK/serve68.out" "$WORK/serve68.err"
PORT68=$(wait_for_port "$WORK/serve68.out") || fail 'case 68: idle server did not start'
kill -TERM "$SERVER_PID" || fail 'case 68: SIGTERM could not be sent'
i=0
while kill -0 "$SERVER_PID" 2>/dev/null && [ "$i" -lt 100 ]; do
  i=$((i + 1))
  sleep 0.1
done
[ "$i" -lt 100 ] || fail 'case 68: idle server did not exit within 10s'
wait "$SERVER_PID" || fail 'case 68: idle SIGTERM exited nonzero'
SERVER_PID=""
grep -Fq 'serve: SIGTERM received; admission stopped; draining connections' "$WORK/serve68.out" \
  || fail 'case 68: no admission-stop log'
grep -Fq 'serve: shutdown complete; connections drained' "$WORK/serve68.out" \
  || fail 'case 68: no drained-exit log'
require_empty "$WORK/serve68.err" 'case 68 idle shutdown'

# 69. Keep a subscriber open and send all but the last bytes of a signed
# createRecord request. The client sends SIGTERM itself only after both
# sockets have been admitted; it then completes the in-flight write. A
# response 200, a subscriber 1000 Close frame and a post-restart CAR that
# contains the acknowledged record together rule out dropping work on stop.
DATA="$WORK/data-term-active"
mkdir -p "$DATA"
seed_credential "$DATA"
start_server --init "$WORK/serve69.out" "$WORK/serve69.err"
PORT69=$(wait_for_port "$WORK/serve69.out") || fail 'case 69: active server did not start'
LOGIN69=$(client login "$PORT69" "$HANDLE" "$PASSWORD") \
  || fail 'case 69: login failed'
TOKEN69=${LOGIN69%% *}
python3 - "$PORT69" "$SERVER_PID" "$TOKEN69" "$DID" "$COLLECTION" "$RECORD_TEXT" <<'PY' \
  || fail 'case 69: in-flight write or subscriber close failed'
import json, os, socket, struct, sys, time
port, pid, token, did, collection, text = sys.argv[1:]
port, pid = int(port), int(pid)

def connect():
    s = socket.create_connection(('127.0.0.1', port), timeout=10)
    s.settimeout(10)
    return s

def exact(s, n):
    out = b''
    while len(out) < n:
        part = s.recv(n - len(out))
        if not part:
            raise AssertionError('subscriber disconnected without a close frame')
        out += part
    return out

sub = connect()
sub.sendall(b'GET /xrpc/com.atproto.sync.subscribeRepos HTTP/1.1\r\n'
            b'Host: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
            b'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
            b'Sec-WebSocket-Version: 13\r\n\r\n')
head = b''
while b'\r\n\r\n' not in head:
    head += sub.recv(4096)
assert head.startswith(b'HTTP/1.1 101'), head[:100]
assert head.endswith(b'\r\n\r\n'), 'unexpected initial event during handshake'
body = json.dumps({'repo': did, 'collection': collection,
                   'rkey': 'term-ack',
                   'record': {'$type': 'app.bsky.feed.post', 'text': text,
                              'createdAt': '2026-09-02T00:00:00.000Z'}}).encode()
write = connect()
write.sendall((f'POST /xrpc/com.atproto.repo.createRecord HTTP/1.1\r\n'
               f'Host: 127.0.0.1\r\nAuthorization: Bearer {token}\r\n'
               f'Content-Type: application/json\r\nContent-Length: {len(body)}\r\n'
               f'Connection: close\r\n\r\n').encode() + body[:-2])
time.sleep(0.2)  # the server has time to park on this admitted body
os.kill(pid, 15)
write.sendall(body[-2:])
response = b''
while True:
    part = write.recv(4096)
    if not part:
        break
    response += part
assert response.startswith(b'HTTP/1.1 200'), response[:200]
write.close()
# A commit event may precede the close frame; do not mistake that frame for
# the close handshake. Read frames through the RFC 6455 length encoding.
for _ in range(10):
    hdr = exact(sub, 2)
    size = hdr[1] & 127
    if size == 126:
        size = struct.unpack('!H', exact(sub, 2))[0]
    elif size == 127:
        size = struct.unpack('!Q', exact(sub, 8))[0]
    assert size < 16777216
    payload = exact(sub, size)
    if hdr[0] & 15 == 8:
        assert payload[:2] == b'\x03\xe8', payload
        break
else:
    raise AssertionError('subscriber never received a normal Close frame')
sub.close()
PY
i=0
while kill -0 "$SERVER_PID" 2>/dev/null && [ "$i" -lt 100 ]; do
  i=$((i + 1))
  sleep 0.1
done
[ "$i" -lt 100 ] || fail 'case 69: active server did not drain within 10s'
wait "$SERVER_PID" || fail 'case 69: active SIGTERM exited nonzero'
SERVER_PID=""
grep -Fq 'serve: SIGTERM received; admission stopped; draining connections' "$WORK/serve69.out" \
  || fail 'case 69: no admission-stop log'
grep -Fq 'serve: shutdown complete; connections drained' "$WORK/serve69.out" \
  || fail 'case 69: no drained-exit log'
require_empty "$WORK/serve69.err" 'case 69 active shutdown'
start_server '' "$WORK/serve69restart.out" "$WORK/serve69restart.err"
PORT69R=$(wait_for_port "$WORK/serve69restart.out") \
  || fail 'case 69: restart of acknowledged write did not start'
client sync-get-record "$PORT69R" "$DID" "$COLLECTION" term-ack "$RECORD_TEXT" \
  || fail 'case 69: acknowledged write absent after restart'
kill -TERM "$SERVER_PID"
wait "$SERVER_PID" || fail 'case 69: restarted server did not stop cleanly'
SERVER_PID=""
require_empty "$WORK/serve69restart.err" 'case 69 restart'

# 70. A native binary that never calls pdsSignalStart keeps the ordinary
# SIGTERM disposition (status 128+15), rather than silently intercepting it.
"$WORK/appview" stall 0 >"$WORK/serve70.out" 2>"$WORK/serve70.err" &
CONTROL_PID=$!
wait_for_stub_port "$WORK/serve70.out" "$CONTROL_PID" >/dev/null \
  || fail 'case 70: non-PDS control did not start'
kill -TERM "$CONTROL_PID" || fail 'case 70: control SIGTERM failed'
CONTROL_RC=0
wait "$CONTROL_PID" || CONTROL_RC=$?
[ "$CONTROL_RC" -eq 143 ] \
  || fail "case 70: non-PDS SIGTERM status $CONTROL_RC, expected 143"

# ── a dedicated --data dir: login derivations off the store transition (#3372)
# The account's credential is re-derived at a count above the shipped one, so
# one derivation takes long enough (~0.7 s here) to be measured against:
# a request that has to wait out a whole derivation cannot pass for one that
# waited a slice of it. A record is written first, while the shipped-count
# credential is still the one on disk, so there is something to read.
DATA="$WORK/data-kdf"
mkdir -p "$DATA"
start_server --init "$WORK/serve71a.out" "$WORK/serve71a.err"
PORT71A=$(wait_for_port "$WORK/serve71a.out") || fail 'case 71: server did not start'
LOGIN71=$(client login "$PORT71A" "$HANDLE" "$PASSWORD") \
  || fail 'case 71: login failed'
client write "$PORT71A" "${LOGIN71%% *}" "$DID" "$COLLECTION" 'kdf-read' 200 \
  || fail 'case 71: the record to read could not be written'
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve71a.err" 'case 71 bootstrap server'
SHIPPED71=$(head -1 "$DATA/credential")
SLOW_ITERATIONS=100000
client credential-at "$SLOW_ITERATIONS" "$PASSWORD" > "$WORK/credential71.slow" \
  || fail 'case 71: the client could not derive a high-count credential'
cp "$WORK/credential71.slow" "$DATA/credential"
chmod 600 "$DATA/credential"
start_server '' "$WORK/serve71.out" "$WORK/serve71.err"
PORT71=$(wait_for_port "$WORK/serve71.out") \
  || fail 'case 71: the high-count server did not start'

# 71. An unrelated getRecord sent while a wrong-password login is deriving is
#    answered in under a tenth of the login's own time.
client kdf-yield "$PORT71" "$HANDLE" 'not the account password' \
  "$DID" "$COLLECTION" 'kdf-read' \
  || fail 'case 71: a read waited out a login derivation'

# 72. Eight wrong-password logins at once: four derive and are refused 401,
#    four are refused 429 RateLimitExceeded at the derivation ceiling without
#    deriving, and a read sent meanwhile is still answered promptly.
client kdf-flood "$PORT71" "$HANDLE" 'not the account password' 8 \
  "$DID" "$COLLECTION" 'kdf-read' \
  || fail 'case 72: a login flood past the derivation ceiling'

# 73. Two right-password logins against the high-count record, sent together:
#    both are graded against that record, the first verdict to land re-derives
#    it at the shipped count, and the second, computed against the record that
#    replaced, is refused. The slots the flood above took are free again, or
#    neither would have derived.
client login-race "$PORT71" "$HANDLE" "$PASSWORD" \
  || fail 'case 73: two logins graded against one record'
[ "$(head -1 "$DATA/credential")" = "$SHIPPED71" ] \
  || fail 'case 73: the winning login did not re-derive at the shipped count'
client login "$PORT71" "$HANDLE" "$PASSWORD" >/dev/null \
  || fail 'case 73: the re-derived credential does not verify the password'
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve71.err" 'cases 71-73'

# ── a --trusted-proxy --data dir: the per-identity derivation cap (#3399) ──
# Same high-count credential as cases 71-73, so a wrong-password flood still
# takes long enough to overlap a concurrent login. `--trusted-proxy` is on
# this time, so the flood's forwarded-for address and the legitimate login's
# are two DISTINCT identities rather than both folding into the shared
# `direct` bucket.
DATA74="$WORK/data-kdf-xff"
mkdir -p "$DATA74"
DATA="$DATA74"
start_server --init "$WORK/serve74a.out" "$WORK/serve74a.err"
wait_for_port "$WORK/serve74a.out" >/dev/null \
  || fail 'case 74: bootstrap server did not start'
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve74a.err" 'case 74 bootstrap server'
client credential-at "$SLOW_ITERATIONS" "$PASSWORD" > "$WORK/credential74.slow" \
  || fail 'case 74: the client could not derive a high-count credential'
cp "$WORK/credential74.slow" "$DATA74/credential"
chmod 600 "$DATA74/credential"
"$WORK/pdsd" \
  --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
  --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
  --data "$DATA74" --port 0 --trusted-proxy \
  >"$WORK/serve74.out" 2>"$WORK/serve74.err" &
SERVER_PID=$!
PORT74=$(wait_for_port "$WORK/serve74.out") \
  || fail 'case 74: the trusted-proxy server did not start'
require_empty "$WORK/serve74.err" 'case 74 trusted-proxy server startup'

# 74. Eight wrong-password logins flooded from one forwarded-for identity are
#    capped at the PER-identity ceiling (2 derive and are refused 401, 6 are
#    refused 429 without deriving) — never the whole-server one — leaving a
#    DIFFERENT identity's own login, sent while the flood is in flight, to
#    succeed rather than be locked out behind the attacker's share.
client kdf-flood-xff "$PORT74" 203.0.113.210 "$HANDLE" 'not the account password' 8 \
  203.0.113.211 "$PASSWORD" \
  || fail 'case 74: an attacker flood locked out a different identity'
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
require_empty "$WORK/serve74.err" 'case 74'

echo 'PASS: serve_e2e — query, pipeline, keep-alive, chunked write, every remaining route, login, getSession, wrong-password refusal, session lifecycle, refresh rotation and a grace-window replay, malformed, over-cap, idle timeout, un-framed connection flood answered rather than shutting other callers out, a stalled-body flood (#2815, the body-phase half of #2772) answered rather than shutting other callers out, restart-and-resume, sync.getRecord answering a rooted CAR carrying a record the repository holds and a same-status proof of ABSENCE for a key it does not, sync.getBlocks answering a CAR with an EMPTY roots list carrying exactly the block asked for, and a partly-missing block set refused whole with every absent CID named, a freshly created repository announcing itself with #identity, #account, #commit and #sync at seq 1-4 and nothing else before its first write, a subscribeRepos subscription receiving live events in order, a future cursor refused, a negative and an unparsable one each refused at the handshake under their own distinct wording, and an outdated one told it has a gap before its replay, a cursor at the newest delivered event replaying nothing and then receiving the next event once, the subscription ceiling refusing a 33rd attempt without completing an upgrade while an ordinary route is still answered, a subscriber silent past requestTimeout not reaped, blob upload and cross-restart fetch, blob residue skipped rather than refusing startup, a backup restored into a SEPARATE data directory whose server exports a byte-identical repository, serves both blobs under their declared types, and accepts a new signed write, init-overwrite-refusal, first-run bootstrap, rate limiting refuses one identity per class while a second identity is still served, repository export bounded by its own class, 400-answered traffic charged rather than free, every secret the server writes owner-only, a world-readable signing key refused before the bind, a rejected configuration leaving no generated secret behind, a constant session-token secret refused before the bind, keygen writing an owner-only key and token secret that serve then runs on, keygen refusing to overwrite, a credential re-derived at the shipped iteration count by one successful login and left untouched by a failed one, a non-loopback bind with no credential refused by the existing missing-credential diagnostic rather than an invented one, a non-loopback bind with no --trusted-proxy refused before any secret reaches disk, the accepted non-loopback-plus-trusted-proxy combination actually binding and serving, a proxied read returning a stub appview'"'"'s own status and body under a credential whose aud and lxm the appview itself logged, a header naming a service OF the configured DID proxied with the fragment stripped from aud, a fresh 32-hex jti per call, an unauthenticated proxied read refused 401 without the appview being called at all and the same request with a credential still forwarded, an upper-case nsid authority forwarded under the canonical spelling of the method rather than the client'"'"'s, a confused-deputy refusal for an unconfigured audience and for a method this server neither serves nor forwards — neither reaching the appview, proven live by the call that immediately followed — while a method this server registers is answered locally under the same header, a proxied POST whose body, content-type and accept-language all reached the appview and whose atproto-repo-rev response field came back to the client, a read carrying NO atproto-proxy header forwarded to the configured appview, an appview that accepts and never answers blocking neither an open subscribeRepos subscription nor an unrelated read while still being owed its own 502, the proxied-call class refusing one identity without refusing that identity'"'"'s plain reads or a second identity, a proxy whose accept queue is full leaving a dial stuck without blocking an unrelated read and still being owed its own 502, a ninth concurrent proxied call refused 503 ProxyLimitExceeded once its wait runs out while eight are stuck dialling and ordinary reads are still answered, the slots those eight held given back, a twelve-call fan-out against an upstream that answers none of the first eight until all eight have arrived served in full rather than four of it refused, and a read past the in-flight ceiling AND a full admission queue refused 503 ProxyLimitExceeded within 300ms rather than after the queue'"'"'s own two-second deadline, a second large proxied answer refused 503 ProxyEgressLimitExceeded while a first holds the egress byte budget, with an ordinary read still answered and the budget given back once the first is relayed, an unauthenticated requestCrawl announcing this server'"'"'s own hostname to a configured relay, and startup and ordinary service surviving a relay that is unreachable, a SECOND configured audience on its own egress port receiving the reads a header audiences for it while the appview sees none of them and the converse also holding, a chat.bsky.* method routed by the audience the header named rather than by its own namespace, an audience in neither row still refused with neither proxy reached, and an additional audience row missing either half, given without a default pair, or repeating a DID already configured refused before the bind, and a client asking for the credential ITSELF handed one the chat service reads as naming that service and the requested method, which appears nowhere in this server'"'"'s own output, and a stamped build reporting its own commit and build date on --version, and one access-log line per request — a routed 401, an unparsable buffer and a framer-refused over-cap body each logged as surely as a served read, with the query string stripped and neither the account password nor an access token anywhere in the log — under a startup that reports its configuration and its event-log recovery outcome, and a periodic stats line carrying active/un-framed connections, open subscriptions, the account repo'"'"'s revision, and blocks and blobs on disk, at an operator-configurable interval, and a second server over a LIVE data directory refused before its sweep could delete the staged file the live one had in flight while that live one kept answering, a lock its killed holder left behind taken by --force-lock and reclaimed with no flag at all once its heartbeat stopped, and a lost last-promoted pointer over a still-owed staged entry recovered into a clean start rather than refused, which is the startup order the genesis guard depends on, eight servers started at once over a directory whose holder is gone leaving exactly one of them holding it five rounds running, a stray file beside the lock ignored rather than wedging the directory while a .lock that is not a directory at all is refused by a message naming the path and the remedy and then cured by that remedy, and a holder whose lock is forced away under it ending its run rather than going on writing beneath the directory, and a read answered in a fraction of the time a concurrent login spends deriving, a login flood past the derivation ceiling refused 429 without deriving while reads are still answered, and of two logins graded against one credential record only the first let in once that record was replaced, and a wrong-password flood from one forwarded-for identity capped at its own per-identity derivation ceiling while a different identity'"'"'s legitimate login still succeeds'
