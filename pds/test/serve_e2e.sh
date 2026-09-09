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

start_resume_at() {
  "$WORK/pdsd" \
    --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
    --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
    --data "$1" --port 0 \
    >"$2" 2>"$3" &
  SERVER_PID=$!
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
grep -F "keygen refuses $KEYGEN_DIR/key.hex" "$WORK/keygen2.err" >/dev/null \
  || fail 'case 28: the overwrite refusal did not name the path'
[ "$(tr -d '\n' < "$KEYGEN_DIR/key.hex")" = "$KEYGEN_SECRET" ] \
  || fail 'case 28: the refused second keygen changed the key on disk'
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

# ── fourth, independent --data dir: rate limiting (#2612) ──────────────────
# `--trusted-proxy` is on here and nowhere else in this gate — every other
# case above runs the untrusted, single-bucket identity path, and this is
# the one place that needs two DISTINCT identities to prove a limit refuses
# one without refusing the other.

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

echo 'PASS: serve_e2e — query, pipeline, keep-alive, chunked write, every remaining route, login, getSession, wrong-password refusal, session lifecycle, refresh rotation and reuse, malformed, over-cap, idle timeout, un-framed connection flood answered rather than shutting other callers out, restart-and-resume, blob upload and cross-restart fetch, blob residue skipped rather than refusing startup, init-overwrite-refusal, first-run bootstrap, rate limiting refuses one identity per class while a second identity is still served, repository export bounded by its own class, 400-answered traffic charged rather than free, every secret the server writes owner-only, a world-readable signing key refused before the bind, a rejected configuration leaving no generated secret behind, a constant session-token secret refused before the bind, keygen writing an owner-only key and token secret that serve then runs on, keygen refusing to overwrite, and a credential re-derived at the shipped iteration count by one successful login and left untouched by a failed one'
