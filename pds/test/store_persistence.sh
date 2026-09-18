#!/bin/sh
# P7 durable store: a repository persisted by one process is resumed, byte for
# byte, by a SEPARATE process; a tampered block file is rejected rather than
# served; and no file the adapter wrote contains the signing key. The same
# three claims are then made for the BLOB half, which persists beside the
# repository under `<data>/blobs` — plus a fourth, that a blob the pure layer
# refuses never reaches a file at all.
#
# Cases 7-11 grade the HALF-WRITTEN directories a process crash can leave: each
# of the three write paths promotes with `rename` after writing what the
# promotion points at, so the reachable interrupted states are a finite set and
# each is built directly rather than raced. Barriers do not change that set: an
# `fsync` decides WHEN a write reaches the platter, never which file a `rename`
# publishes, so every state those cases build stays reachable and each must
# still serve the previous value or refuse. Case 11b is that same claim for a
# creation interrupted partway through the four events it emits: the state is
# built by winding a finished log back, and the next start has to finish it —
# except for the one wound-back state no crash can produce, a lost
# last-promoted pointer over entries that remain, where the next start has to
# refuse.
# Case 11c grades the residue those same crash points leave behind under
# `.staging`: swept at startup rather than mistaken for corruption (#2572
# part 2, #3052). Case 11d widens that to every OTHER directory the three
# stores list, and to entries no crash produced at all — what an editor, a
# backup tool or an operator leaves behind (#3055). Case 12 grades the
# barriers themselves, which is the one claim building a directory by hand
# cannot make — it needs the syscall ORDER, not the resulting tree (#2952).
# Cases 12a, 12b and 12c read the same traces for three orders that rule is
# deliberately blind to, each within ONE process: which half of a transition
# reached the disk first (#3057), whether a commit's shard-directory
# barriers came after its block promotes or in between them (#3058), and
# whether the blob area's own dentry is barriered on a write that runs no repo
# half, where the concatenated trace lets another process pay for it.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
DRIVER="$ROOT/pds/test/store_persistence_main.mdk"
# Must match `secretHex` in the driver.
SECRET_HEX=c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-persist.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

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

# Every byte of every file below `$1`, as one lowercase hex string. Reading the
# tree as hex catches the key whether it was written raw or as hex text.
tree_hex() {
  find "$1" -type f -exec cat {} + | od -An -v -tx1 | tr -d ' \n'
}

[ -x "$MEDAKA" ] || fail "build medaka first (missing $MEDAKA)"

# The adapter is native-only: every file extern it uses is unimplemented in the
# interpreter and permanently rejected by Wasm (design row P9), so this gate
# grades the native engine alone.
if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$DRIVER" -o "$WORK/driver" \
  > "$WORK/build.log" 2>&1
then
  cat "$WORK/build.log" >&2
  fail 'native driver build failed'
fi

DATA="$WORK/data"

# ── 1. save, in one process ─────────────────────────────────────────────────
"$WORK/driver" save "$DATA" > "$WORK/save.out" 2> "$WORK/save.err"
require_empty "$WORK/save.err" save
[ "$(tail -1 "$WORK/save.out")" = 'SAVE: PASS' ] || fail 'save route did not pass'
grep -q '^SAVE records 3$' "$WORK/save.out" || fail 'save did not write three records'

# ── 2. load, in a SEPARATE process invocation ───────────────────────────────
"$WORK/driver" load "$DATA" > "$WORK/load.out" 2> "$WORK/load.err"
require_empty "$WORK/load.err" load
[ "$(tail -1 "$WORK/load.out")" = 'LOAD: PASS' ] || fail 'load route did not pass'

sed -n 's/^SAVE /STATE /p' "$WORK/save.out" > "$WORK/save.state"
sed -n 's/^LOAD /STATE /p' "$WORK/load.out" > "$WORK/load.state"
[ -s "$WORK/save.state" ] || fail 'save produced no state summary'
cmp "$WORK/save.state" "$WORK/load.state" \
  || fail 'reloaded head commit CID / record count / getRepo CAR differ'
grep -q '^STATE car .* decodes$' "$WORK/save.state" || fail 'exported CAR did not decode'
echo "resumed $(sed -n 's/^STATE head //p' "$WORK/save.state")"

# ── 2b. the blob half saves and reloads across a process boundary ──────────
# Written into the SAME $DATA directory the repository uses, so the key check
# below covers every blob file this gate wrote without a second sweep.
"$WORK/driver" blob-save "$DATA" > "$WORK/blobsave.out" 2> "$WORK/blobsave.err"
require_empty "$WORK/blobsave.err" blob-save
[ "$(tail -1 "$WORK/blobsave.out")" = 'BLOB-SAVE: PASS' ] \
  || fail 'blob save route did not pass'

"$WORK/driver" blob-load "$DATA" > "$WORK/blobload.out" 2> "$WORK/blobload.err"
require_empty "$WORK/blobload.err" blob-load
[ "$(tail -1 "$WORK/blobload.out")" = 'BLOB-LOAD: PASS' ] \
  || fail 'blob load route did not pass'

sed -n 's/^BLOBSAVE /BLOBSTATE /p' "$WORK/blobsave.out" > "$WORK/blobsave.state"
sed -n 's/^BLOBLOAD /BLOBSTATE /p' "$WORK/blobload.out" > "$WORK/blobload.state"
[ -s "$WORK/blobsave.state" ] || fail 'blob save produced no state summary'
cmp "$WORK/blobsave.state" "$WORK/blobload.state" \
  || fail 'reloaded blob CID / declared MIME type / bytes differ'
echo "resumed $(grep -c '^BLOBSTATE blob ' "$WORK/blobsave.state") blob(s)"

# The declared MIME type is the part content addressing does NOT carry, so a
# reload that recovered the bytes and lost the type would still be a loss.
grep -q '^BLOBSTATE blob .* text/plain ' "$WORK/blobload.state" \
  || fail 'the reloaded blob lost its declared MIME type'

# ── 2c. the preferences half saves and reloads across a process boundary ───
# Written into the SAME $DATA directory the repository and blob halves use,
# so the key check below (case 3) covers the preferences file too.
"$WORK/driver" prefs-save "$DATA" > "$WORK/prefssave.out" 2> "$WORK/prefssave.err"
require_empty "$WORK/prefssave.err" prefs-save
[ "$(tail -1 "$WORK/prefssave.out")" = 'PREFS SAVE: PASS' ] \
  || fail 'preferences save route did not pass'

"$WORK/driver" prefs-load "$DATA" > "$WORK/prefsload.out" 2> "$WORK/prefsload.err"
require_empty "$WORK/prefsload.err" prefs-load
[ "$(tail -1 "$WORK/prefsload.out")" = 'PREFS LOAD: PASS' ] \
  || fail 'preferences load route did not pass'

# ── 2d. the session half saves and reloads across a process boundary ────
# This is what makes a restart not a logout: the rows a previous process held
# are readmitted by the next one. Written into the SAME $DATA directory, so
# case 3's key sweep covers the sessions file too.
"$WORK/driver" sessions-save "$DATA" > "$WORK/sesssave.out" 2> "$WORK/sesssave.err"
require_empty "$WORK/sesssave.err" sessions-save
[ "$(tail -1 "$WORK/sesssave.out")" = 'SESSIONS SAVE: PASS' ] \
  || fail 'sessions save route did not pass'

"$WORK/driver" sessions-load "$DATA" > "$WORK/sessload.out" 2> "$WORK/sessload.err"
require_empty "$WORK/sessload.err" sessions-load
[ "$(tail -1 "$WORK/sessload.out")" = 'SESSIONS LOAD: PASS' ] \
  || fail 'sessions load route did not pass'

# The session set is security-relevant state and `pds serve` refuses to read it
# back at a wider mode, so the writer owes 0600 from the first byte.
SESSIONS_MODE=$(stat -c %a "$DATA/sessions" 2>/dev/null || stat -f %Lp "$DATA/sessions")
[ "$SESSIONS_MODE" = "600" ] \
  || fail "sessions file is mode $SESSIONS_MODE, expected 600"

# ── 3. no persisted file carries the signing key ────────────────────────────
# `tree_hex` sweeps `$DATA` whole, so the blob half is inside its scope by
# construction — but only if blob files are actually there, which is asserted
# rather than assumed: two blobs, each a byte file plus its MIME sidecar.
BLOB_FILES=$(find "$DATA/blobs" -type f | wc -l | tr -d ' ')
[ "$BLOB_FILES" -eq 4 ] \
  || fail "expected 4 blob files under $DATA/blobs, found $BLOB_FILES"
FILES=$(find "$DATA" -type f | wc -l | tr -d ' ')
[ "$FILES" -ge 2 ] || fail "expected persisted files, found $FILES"
tree_hex "$DATA" > "$WORK/data.hex"
if grep -q -F "$SECRET_HEX" "$WORK/data.hex"; then
  fail 'a persisted file contains the raw signing-key bytes'
fi
# The same key spelled as hex text is those ASCII digits, i.e. hex-of-hex.
KEY_AS_TEXT=$(printf '%s' "$SECRET_HEX" | od -An -v -tx1 | tr -d ' \n')
if grep -q -F "$KEY_AS_TEXT" "$WORK/data.hex"; then
  fail 'a persisted file contains the signing key as hex text'
fi
echo "key absent from $FILES persisted files ($BLOB_FILES of them blob files; raw bytes and hex text)"

# ── 4. a tampered block file is rejected, not served ────────────────────────
cp -R "$DATA" "$WORK/tampered"
VICTIM=$(find "$WORK/tampered/blocks" -type f | sort | sed -n '1p')
[ -n "$VICTIM" ] || fail 'no persisted block file to tamper with'
cp "$VICTIM" "$WORK/victim.orig"
# Same file name, same length, different bytes: only the content moved.
printf '\000' | dd of="$VICTIM" bs=1 count=1 conv=notrunc 2>/dev/null
if cmp -s "$VICTIM" "$WORK/victim.orig"; then
  printf '\001' | dd of="$VICTIM" bs=1 count=1 conv=notrunc 2>/dev/null
fi
cmp -s "$VICTIM" "$WORK/victim.orig" && fail 'tamper did not change the block file'
[ "$(wc -c < "$VICTIM")" = "$(wc -c < "$WORK/victim.orig")" ] \
  || fail 'tamper changed the block length; the test wants a pure content change'

"$WORK/driver" reject "$WORK/tampered" > "$WORK/reject.out" 2> "$WORK/reject.err"
require_empty "$WORK/reject.err" reject
grep -q '^REJECT: PASS ' "$WORK/reject.out" || {
  cat "$WORK/reject.out" >&2
  fail 'tampered block file was not rejected'
}
sed -n 's/^REJECT: PASS /rejected: /p' "$WORK/reject.out"

# ── 5. a tampered BLOB file is rejected, not served ────────────────────────
cp -R "$DATA" "$WORK/blobtampered"
BLOB_VICTIM=$(find "$WORK/blobtampered/blobs" -type f ! -name '*.mime' | sort \
  | sed -n '1p')
[ -n "$BLOB_VICTIM" ] || fail 'no persisted blob file to tamper with'
cp "$BLOB_VICTIM" "$WORK/blobvictim.orig"
printf '\000' | dd of="$BLOB_VICTIM" bs=1 count=1 conv=notrunc 2>/dev/null
if cmp -s "$BLOB_VICTIM" "$WORK/blobvictim.orig"; then
  printf '\001' | dd of="$BLOB_VICTIM" bs=1 count=1 conv=notrunc 2>/dev/null
fi
cmp -s "$BLOB_VICTIM" "$WORK/blobvictim.orig" \
  && fail 'tamper did not change the blob file'
[ "$(wc -c < "$BLOB_VICTIM")" = "$(wc -c < "$WORK/blobvictim.orig")" ] \
  || fail 'tamper changed the blob length; the test wants a pure content change'

"$WORK/driver" blob-reject "$WORK/blobtampered" > "$WORK/blobreject.out" \
  2> "$WORK/blobreject.err"
require_empty "$WORK/blobreject.err" blob-reject
grep -q '^BLOB-REJECT: PASS ' "$WORK/blobreject.out" || {
  cat "$WORK/blobreject.out" >&2
  fail 'tampered blob file was not rejected'
}
sed -n 's/^BLOB-REJECT: PASS /blob rejected: /p' "$WORK/blobreject.out"

# ── 6. an oversize blob is refused BEFORE any bytes reach the disk ─────────
# A fresh directory, so "no blob file exists" is an assertion about this
# upload and not about a directory that was already empty of other blobs.
OVERSIZE="$WORK/oversize"
mkdir -p "$OVERSIZE"
"$WORK/driver" blob-oversize "$OVERSIZE" > "$WORK/oversize.out" \
  2> "$WORK/oversize.err"
require_empty "$WORK/oversize.err" blob-oversize
[ "$(tail -1 "$WORK/oversize.out")" = 'BLOB-OVERSIZE: PASS nothing was written' ] \
  || {
    cat "$WORK/oversize.out" >&2
    fail 'an oversize blob was not refused before writing'
  }
sed -n 's/^BLOB-OVERSIZE refused /oversize refused: /p' "$WORK/oversize.out"
OVERSIZE_FILES=$(find "$OVERSIZE" -type f | wc -l | tr -d ' ')
[ "$OVERSIZE_FILES" = '0' ] \
  || fail "an oversize blob left $OVERSIZE_FILES file(s) on disk"

# ── 7. a crash between the last block write and the head `rename` ──────────
# None of cases 7-10 races a process kill. Every write path here promotes with
# `rename`, so the states a crash can leave are a finite set with fixed
# contents, and building each one directly is both exhaustive where a kill
# would be a sample and deterministic where a kill would be flaky.
#
# `persistSave` writes the blocks and promotes the head last, so the state a
# crash in between leaves is the NEWER generation's blocks on disk under a head
# file still naming the older one. The claim is not merely that this loads: it
# is that it loads as the previous repository EXACTLY, blocks it cannot reach
# notwithstanding.
CRASH="$WORK/crash-blocks-ahead"
"$WORK/driver" crash-save-old "$CRASH" > "$WORK/old.out" 2> "$WORK/old.err"
require_empty "$WORK/old.err" crash-save-old
[ "$(tail -1 "$WORK/old.out")" = 'CRASH-SAVE-OLD: PASS' ] \
  || fail 'old-generation save route did not pass'
cp "$CRASH/head" "$WORK/head.old"
"$WORK/driver" save "$CRASH" > "$WORK/crashsave.out" 2> "$WORK/crashsave.err"
require_empty "$WORK/crashsave.err" save
# The head `rename` is the step that never ran.
cp "$WORK/head.old" "$CRASH/head"
"$WORK/driver" load "$CRASH" > "$WORK/crashload.out" 2> "$WORK/crashload.err"
require_empty "$WORK/crashload.err" load
[ "$(tail -1 "$WORK/crashload.out")" = 'LOAD: PASS' ] \
  || fail 'an unpromoted head did not reload at all'
sed -n 's/^OLD /STATE /p' "$WORK/old.out" > "$WORK/old.state"
sed -n 's/^LOAD /STATE /p' "$WORK/crashload.out" > "$WORK/crashload.state"
[ -s "$WORK/old.state" ] || fail 'old-generation save produced no state summary'
cmp "$WORK/old.state" "$WORK/crashload.state" \
  || fail 'an unpromoted head served a repository that is not the previous one'
echo "unpromoted head resumed $(sed -n 's/^STATE head //p' "$WORK/old.state")"

# The same crash on a FIRST save leaves blocks with no head at all, which must
# be refused rather than answered from whatever the block directory holds.
FIRST="$WORK/crash-first-save"
"$WORK/driver" save "$FIRST" > "$WORK/first.out" 2> "$WORK/first.err"
require_empty "$WORK/first.err" save
rm "$FIRST/head"
"$WORK/driver" reject "$FIRST" > "$WORK/firstreject.out" 2> "$WORK/firstreject.err"
require_empty "$WORK/firstreject.err" reject
grep -q '^REJECT: PASS ' "$WORK/firstreject.out" || {
  cat "$WORK/firstreject.out" >&2
  fail 'a block directory with no head file was loaded anyway'
}
sed -n 's/^REJECT: PASS /headless directory refused: /p' "$WORK/firstreject.out"

# ── 8. the inverse: a head promoted over a graph that is not all there ─────
# Every persisted block in turn rather than one sample: a single tolerated
# absence is a repository served with records silently missing, and which
# block would be tolerated is exactly what a sample cannot say.
BLOCKS_TRIED=0
for VICTIM_REL in $(find "$DATA/blocks" -type f | sed "s|^$DATA/||" | sort); do
  rm -rf "$WORK/headahead"
  cp -R "$DATA" "$WORK/headahead"
  rm "$WORK/headahead/$VICTIM_REL"
  "$WORK/driver" reject "$WORK/headahead" > "$WORK/headahead.out" \
    2> "$WORK/headahead.err"
  require_empty "$WORK/headahead.err" reject
  grep -q '^REJECT: PASS ' "$WORK/headahead.out" || {
    cat "$WORK/headahead.out" >&2
    fail "a head over a graph missing $VICTIM_REL was served anyway"
  }
  BLOCKS_TRIED=$((BLOCKS_TRIED + 1))
done
[ "$BLOCKS_TRIED" -ge 4 ] \
  || fail "expected several persisted blocks to remove, found $BLOCKS_TRIED"
echo "head over an incomplete graph refused, each of $BLOCKS_TRIED block(s) removed in turn"

# ── 9. the blob half, interrupted in BOTH promote orders ───────────────────
# `blobfile.mdk` promotes the MIME sidecar first and the bytes last, so a crash
# between them leaves a sidecar naming no bytes. The reverse state is built
# too: that ordering is a preference the code states it cannot guarantee, so
# the half it does not expect has to be graded as well as the half it does.
# Both must lose exactly the one blob they belong to — never the read.
BYTES_VICTIM=$(find "$DATA/blobs" -type f ! -name '*.mime' | sort | sed -n '1p')
[ -n "$BYTES_VICTIM" ] || fail 'no persisted blob to interrupt'
BLOB_REL=${BYTES_VICTIM#"$DATA/"}

rm -rf "$WORK/sidecar-only"
cp -R "$DATA" "$WORK/sidecar-only"
rm "$WORK/sidecar-only/$BLOB_REL"
"$WORK/driver" blob-survey "$WORK/sidecar-only" > "$WORK/sidecaronly.out" \
  2> "$WORK/sidecaronly.err"
require_empty "$WORK/sidecaronly.err" blob-survey
[ "$(tail -1 "$WORK/sidecaronly.out")" = 'BLOB-SURVEY: OK 1' ] || {
  cat "$WORK/sidecaronly.out" >&2
  fail 'a sidecar promoted without its bytes did not cost exactly its own blob'
}
sed -n 's/^BLOB-SURVEY: /sidecar without bytes: /p' "$WORK/sidecaronly.out"

rm -rf "$WORK/bytes-only"
cp -R "$DATA" "$WORK/bytes-only"
rm "$WORK/bytes-only/$BLOB_REL.mime"
"$WORK/driver" blob-survey "$WORK/bytes-only" > "$WORK/bytesonly.out" \
  2> "$WORK/bytesonly.err"
require_empty "$WORK/bytesonly.err" blob-survey
[ "$(tail -1 "$WORK/bytesonly.out")" = 'BLOB-SURVEY: OK 1' ] || {
  cat "$WORK/bytesonly.out" >&2
  fail 'bytes promoted without their sidecar did not cost exactly their own blob'
}
sed -n 's/^BLOB-SURVEY: /bytes without sidecar: /p' "$WORK/bytesonly.out"

# ── 10. the event log's two crash points, against a REAL persisted head ────
# `pds/test/event_log_test.mdk` already grades the recovery rule over CID
# strings it supplies itself. What it cannot reach is the discriminator the
# server actually hands it — `persistLoad`'s head — so these two cases stage an
# entry over a genuinely persisted repository and let the file on disk decide.
# Both directions, because a recovery that discarded everything would satisfy
# the orphan case alone.
EVENTOWED="$WORK/event-owed"
"$WORK/driver" event-recover-owed "$EVENTOWED" > "$WORK/eventowed.out" \
  2> "$WORK/eventowed.err"
require_empty "$WORK/eventowed.err" event-recover-owed
grep -q '^EVENTBEFORE staged .* entries 0$' "$WORK/eventowed.out" \
  || fail 'the owed case did not stage an entry to recover'
grep -q '^EVENTAFTER staged none entries 1$' "$WORK/eventowed.out" || {
  cat "$WORK/eventowed.out" >&2
  fail 'an entry naming the persisted head was not finished'
}

EVENTORPHAN="$WORK/event-orphan"
"$WORK/driver" event-recover-orphan "$EVENTORPHAN" > "$WORK/eventorphan.out" \
  2> "$WORK/eventorphan.err"
require_empty "$WORK/eventorphan.err" event-recover-orphan
grep -q '^EVENTBEFORE staged .* entries 0$' "$WORK/eventorphan.out" \
  || fail 'the orphan case did not stage an entry to recover'
grep -q '^EVENTAFTER staged none entries 0$' "$WORK/eventorphan.out" || {
  cat "$WORK/eventorphan.out" >&2
  fail 'an entry naming no persisted head was not discarded'
}
echo 'staged event finished when the head is on disk, discarded when it is not'

# ── 11. an event that announces no repository mutation, same crash point ───
# The arm case 10's two cannot reach: an entry anchored to NOTHING, left
# pending by the same stage-then-die. No head can contradict it, so it is owed
# whatever `persistLoad` answers — and the head this case hands recovery is a
# real one that the entry does not name, which under the old commit-CID rule
# was precisely a discard. The survey line between the two halves is the #2906
# claim on the same run: PLANNING leaves the pending entry and the promoted
# count exactly where the stage left them, so `configure` can take the decision
# before its refusals and perform it after the last of them.
EVENTFREE="$WORK/event-unanchored"
"$WORK/driver" event-recover-unanchored "$EVENTFREE" > "$WORK/eventfree.out" \
  2> "$WORK/eventfree.err"
require_empty "$WORK/eventfree.err" event-recover-unanchored
grep -q '^EVENTBEFORE staged unanchored entries 0$' "$WORK/eventfree.out" \
  || fail 'the unanchored case did not stage an entry to recover'
grep -q '^EVENTPLANNED staged unanchored entries 0$' "$WORK/eventfree.out" || {
  cat "$WORK/eventfree.out" >&2
  fail 'planning recovery wrote to the log instead of only deciding'
}
grep -q '^EVENTAFTER staged none entries 1$' "$WORK/eventfree.out" || {
  cat "$WORK/eventfree.out" >&2
  fail 'an entry anchored to no commit was not finished'
}
echo 'staged event anchored to no commit finished, and planning wrote nothing'

# ── 11b. a creation interrupted partway through the genesis quartet ────────
# The four events `com.atproto.sync.subscribeRepos` opens a stream with are
# emitted by the run that CREATES the repository, and `--init` refuses a
# directory that already holds one — so a process that died between two of them
# has exactly one chance left to finish the sequence: an ordinary start over
# that data directory (#3006).
#
# Built rather than raced, like every other state here. An uninterrupted
# creation runs first; the log is then wound back to the crash point (every
# entry past the Nth unlinked, and the last-promoted pointer — the only record
# of how far the sequence got — set back to N); and a plain start runs over it.
# What that start leaves must be the log the uninterrupted creation left, BYTE
# for byte, which is a claim about which four events and in what order rather
# than about how many. N=0 is the crash between persisting the genesis commit
# and promoting the first event, where the pointer does not exist at all.
GENREF="$WORK/genesis-ref"
"$WORK/driver" genesis-init "$GENREF" > "$WORK/genesis-ref.out" \
  2> "$WORK/genesis-ref.err"
require_empty "$WORK/genesis-ref.err" genesis-init
grep -q '^GENESIS count 4$' "$WORK/genesis-ref.out" \
  || fail 'a repository creation did not emit the four genesis events'

for N in 0 1 2 3; do
  GENDIR="$WORK/genesis-$N"
  "$WORK/driver" genesis-init "$GENDIR" > "$WORK/genesis-$N.init" \
    2> "$WORK/genesis-$N.err"
  require_empty "$WORK/genesis-$N.err" "genesis-init (N=$N)"
  cmp "$WORK/genesis-ref.out" "$WORK/genesis-$N.init" \
    || fail "case 11b: two uninterrupted creations left different logs"

  K=$((N + 1))
  while [ "$K" -le 4 ]; do
    rm -f "$GENDIR"/events/entries/000000000000000"$K"-*
    K=$((K + 1))
  done
  if [ "$N" -eq 0 ]; then
    rm -f "$GENDIR/events/.last"
  else
    printf '%s' "$N" > "$GENDIR/events/.last"
  fi
  REMAIN=$(ls "$GENDIR/events/entries" | wc -l | tr -d ' ')
  [ "$REMAIN" = "$N" ] \
    || fail "case 11b: winding the log back to $N left $REMAIN entries"

  "$WORK/driver" genesis-resume "$GENDIR" > "$WORK/genesis-$N.resumed" \
    2> "$WORK/genesis-$N.err"
  require_empty "$WORK/genesis-$N.err" "genesis-resume (N=$N)"
  cmp "$WORK/genesis-ref.out" "$WORK/genesis-$N.resumed" || {
    diff "$WORK/genesis-ref.out" "$WORK/genesis-$N.resumed" >&2 || true
    fail "case 11b: a start over a log holding $N of the 4 did not finish it"
  }

  # The same start once more: a finished quartet must not grow a fifth event,
  # and the sequence counter must not move.
  LASTAFTER=$(cat "$GENDIR/events/.last")
  "$WORK/driver" genesis-resume "$GENDIR" > "$WORK/genesis-$N.again" \
    2> "$WORK/genesis-$N.err"
  require_empty "$WORK/genesis-$N.err" "genesis-resume repeat (N=$N)"
  cmp "$WORK/genesis-$N.resumed" "$WORK/genesis-$N.again" \
    || fail "case 11b: a start after the quartet was finished emitted more"
  [ "$(cat "$GENDIR/events/.last")" = "$LASTAFTER" ] \
    || fail "case 11b: a start after the quartet was finished moved the counter"
done
echo 'genesis quartet finished from 0, 1, 2 and 3 promoted events, and adds nothing once whole'

# The other shape those same two files can take, which is NOT a crash point
# and must not be resumed as one: the last-promoted pointer gone while the
# entries it indexed remain. No sequence this tree writes reaches it — a
# promotion writes the entry first and the pointer second, and leaves the
# staged copy behind so the pair runs again — so it means the pointer alone
# was lost, and the entries are real history. Resuming there reads "nothing
# was ever promoted" and re-mints the whole quartet beside the original one,
# which is a stream serving two #identity, #account, #commit and #sync events
# a subscriber cannot reconcile. N=0 above is the shape this must NOT fire on:
# no pointer AND no entries is an ordinary fresh creation, and it still
# completes the quartet.
GENLOST="$WORK/genesis-lost-pointer"
"$WORK/driver" genesis-init "$GENLOST" > "$WORK/genesis-lost.init" \
  2> "$WORK/genesis-lost.err"
require_empty "$WORK/genesis-lost.err" 'genesis-init (lost pointer)'
cmp "$WORK/genesis-ref.out" "$WORK/genesis-lost.init" \
  || fail 'case 11b: two uninterrupted creations left different logs'
rm -f "$GENLOST/events/.last"
"$WORK/driver" genesis-guard "$GENLOST" > "$WORK/genesis-lost.out" \
  2> "$WORK/genesis-lost.err"
require_empty "$WORK/genesis-lost.err" 'genesis-guard (lost pointer)'
grep -q '^GENESIS-GUARD: ERR ' "$WORK/genesis-lost.out" || {
  cat "$WORK/genesis-lost.out" >&2
  fail 'a lost last-promoted pointer over surviving entries was resumed instead of refused'
}
REMAIN=$(ls "$GENLOST/events/entries" | wc -l | tr -d ' ')
[ "$REMAIN" = 4 ] \
  || fail "case 11b: the refused start left $REMAIN entries where it found 4"
[ ! -e "$GENLOST/events/.last" ] \
  || fail 'case 11b: the refused start wrote the pointer it refused over'
sed -n 's/^GENESIS-GUARD: ERR /lost pointer refused: /p' "$WORK/genesis-lost.out"

# ── 11c. `.staging` residue is swept at startup, never treated as corruption ──
# A crash between `writeFileBytes staged`/`writeFile staged` and its `rename`
# leaves a file behind in one of the three `.staging` directories, and nothing
# else in the tree ever removes one. The `sweep-staging` route plants exactly
# that residue beside content it ALSO persists legitimately (a repository, two
# blobs, one promoted event entry), then runs the same three sweeps
# `pds/serve.mdk`'s `configure` runs before the listener binds (#2572 part 2,
# #3052). It also plants a stray SUBDIRECTORY (with a file of its own inside)
# under each `.staging` — residue an operator or an external process left
# behind, which this process never wrote and must not fail to sweep over
# (F5). The claim is three-sided: every planted plain-file residue is gone
# afterward, every stray subdirectory (and its inner file) is untouched, and
# the legitimate content it all sat beside is not.
"$WORK/driver" sweep-staging "$WORK/sweep-staging" \
  > "$WORK/sweep-staging.out" 2> "$WORK/sweep-staging.err"
require_empty "$WORK/sweep-staging.err" sweep-staging
[ "$(tail -1 "$WORK/sweep-staging.out")" = 'SWEEP-STAGING: PASS' ] \
  || fail 'case 11c: sweep-staging route did not pass'
grep -q '^SWEEP residue-block absent$' "$WORK/sweep-staging.out" \
  || fail 'case 11c: staged block residue survived the sweep'
grep -q '^SWEEP residue-blob absent$' "$WORK/sweep-staging.out" \
  || fail 'case 11c: staged blob residue survived the sweep'
grep -q '^SWEEP residue-event absent$' "$WORK/sweep-staging.out" \
  || fail 'case 11c: staged event residue survived the sweep'
grep -q '^SWEEP stray-block present$' "$WORK/sweep-staging.out" \
  || fail 'case 11c: a stray blocks/.staging subdirectory did not survive the sweep'
grep -q '^SWEEP stray-blob present$' "$WORK/sweep-staging.out" \
  || fail 'case 11c: a stray blobs/.staging subdirectory did not survive the sweep'
grep -q '^SWEEP stray-event present$' "$WORK/sweep-staging.out" \
  || fail 'case 11c: a stray events/.staging subdirectory did not survive the sweep'
grep -q '^SWEEP records 3$' "$WORK/sweep-staging.out" \
  || fail 'case 11c: the sweep disturbed the legitimately persisted repository'
grep -q '^SWEEP blobs 2$' "$WORK/sweep-staging.out" \
  || fail 'case 11c: the sweep disturbed a legitimately persisted blob'
grep -q '^SWEEP entries 1$' "$WORK/sweep-staging.out" \
  || fail 'case 11c: the sweep disturbed the legitimately promoted event entry'
# Every `.staging` directory the sweeps touched must itself still be there —
# swept means the plain-file residue emptied out, not the directory removed —
# and the only thing left inside is the stray subdirectory the sweep must not
# have touched.
for HALF in blocks blobs events; do
  [ -d "$WORK/sweep-staging/$HALF/.staging" ] \
    || fail "case 11c: the sweep removed the $HALF/.staging directory itself"
  LEFT=$(ls -A "$WORK/sweep-staging/$HALF/.staging")
  [ "$LEFT" = 'stray-dir' ] \
    || fail "case 11c: $HALF/.staging holds '$LEFT' after the sweep, expected only stray-dir"
  [ -d "$WORK/sweep-staging/$HALF/.staging/stray-dir" ] \
    || fail "case 11c: $HALF/.staging/stray-dir is no longer a directory after the sweep"
  [ -f "$WORK/sweep-staging/$HALF/.staging/stray-dir/inner" ] \
    || fail "case 11c: $HALF/.staging/stray-dir/inner did not survive the sweep"
done
echo 'case 11c: crash residue swept from all three .staging directories; a stray subdirectory and legitimate content both untouched'

# ── 11d. an entry no store wrote, at every level any of them lists ─────────
# Case 11c grades `.staging`, the one directory whose whole contents are
# residue by construction. This grades every OTHER directory the three stores
# list: the blocks and blobs shard trees at both their levels, and the event
# log's entry directory (#3055).
#
# Each case builds its own legitimate data directory — the repository, two
# blobs, one promoted entry — plants exactly ONE entry no write path in this
# tree can produce, and reports what all four readers then answer. Three
# shapes at each level, because the stores grade an entry on two axes: a plain
# FILE, a DIRECTORY whose name is not one the store could have produced, and a
# DIRECTORY whose name is one it could have — the third being the shape a
# name-only rule cannot tell apart from the store's own data.
#
# Every case reports every reader, not only the one the planted entry sits
# under, so a disposition that also moved a store the entry never touched
# fails here rather than somewhere downstream. And where the answer is a
# refusal, the MESSAGE is graded too: #3055's actual defect is not that a
# stray entry passes unnoticed but that the refusal it causes gets attributed
# to something else.
STRAY="$WORK/stray"
"$WORK/driver" stray-entries "$STRAY" > "$WORK/stray.out" 2> "$WORK/stray.err"
require_empty "$WORK/stray.err" stray-entries
[ "$(tail -1 "$WORK/stray.out")" = 'STRAY-ENTRIES: PASS' ] \
  || fail 'case 11d: stray-entries route did not pass'

stray_row() {
  sed -n "s/^STRAY $1 //p" "$WORK/stray.out"
}

# Every expected row below is built from the row for the case that plants
# NOTHING, rather than written down: how many blocks the fixture repository
# holds is its own business, and a hand-typed count would pin it here too.
BASE_ROW=$(stray_row none)
[ -n "$BASE_ROW" ] || fail 'case 11d: no baseline survey row'
# shellcheck disable=SC2086 # the row IS eight space-separated fields; splitting is the read
set -- $BASE_ROW
[ "$#" = 8 ] || fail "case 11d: baseline row has $# fields, expected 8: $BASE_ROW"
BLOCKS_OK=$2
BLOBS_OK=$4
COUNT_OK=$6
EVENTS_OK=$8
case "$BASE_ROW" in
  *refused*)
    fail "case 11d: the unplanted baseline did not read cleanly: $BASE_ROW" ;;
esac
# The count and the read must already agree before anything is planted, or the
# blobs-leaf-cid case below proves nothing.
[ "$BLOBS_OK" = "$COUNT_OK" ] \
  || fail "case 11d: blobFileRead and blobFileCount disagree unplanted: $BASE_ROW"

INTACT="blocks $BLOCKS_OK blobs $BLOBS_OK count $COUNT_OK events $EVENTS_OK"
BLOCKS_REFUSED="blocks refused blobs $BLOBS_OK count $COUNT_OK events $EVENTS_OK"
BLOBS_REFUSED="blocks $BLOCKS_OK blobs refused count $COUNT_OK events $EVENTS_OK"
EVENTS_REFUSED="blocks $BLOCKS_OK blobs $BLOBS_OK count $COUNT_OK events refused"

expect_stray() {
  _got=$(stray_row "$1")
  [ -n "$_got" ] || fail "case 11d: no survey row for $1"
  [ "$_got" = "$2" ] || fail "case 11d: $1 answered '$_got', expected '$2'"
}

expect_named() {
  _path=$(sed -n "s/^STRAYPLANT $1 //p" "$WORK/stray.out")
  [ -n "$_path" ] || fail "case 11d: $1 planted nothing"
  grep "^STRAYMSG $1 $2 " "$WORK/stray.out" | grep -qF "$_path" \
    || fail "case 11d: $1's refusal does not name $_path"
}

# The blocks half. A shard is a directory named by two lowercase hex digits
# and a block is a file inside one named by a CID, so: anything under
# `blocks/` that is not a directory, and any directory there not named like a
# shard, is skipped; anything under a shard that is not a file is skipped; and
# a FILE under a shard whose name does not spell a CID is refused. A directory
# named exactly like a shard IS a shard as far as this store can tell, so it
# is graded as one — which is why planting one with a file inside refuses.
expect_stray blocks-top-file "$INTACT"
expect_stray blocks-top-dir "$INTACT"
expect_stray blocks-top-shard "$BLOCKS_REFUSED"
expect_named blocks-top-shard blocks
expect_stray blocks-leaf-file "$BLOCKS_REFUSED"
expect_named blocks-leaf-file blocks
expect_stray blocks-leaf-dir "$INTACT"
expect_stray blocks-leaf-cid "$INTACT"

# The blobs half, same layout and therefore the same rule. `blobs-leaf-cid` is
# the one the two blob readers used to disagree about: a DIRECTORY named like
# a blob's bytes, beside a sidecar of its own, which `blobFileCount` counted by
# name arithmetic while `blobFileRead` could never serve it. Both must now pass
# it over, which is what comparing `count` against `blobs` here asserts.
expect_stray blobs-top-file "$INTACT"
expect_stray blobs-top-dir "$INTACT"
expect_stray blobs-top-shard "$BLOBS_REFUSED"
expect_named blobs-top-shard blobs
expect_stray blobs-leaf-file "$BLOBS_REFUSED"
expect_named blobs-leaf-file blobs
expect_stray blobs-leaf-dir "$INTACT"
expect_stray blobs-leaf-cid "$INTACT"

# The event log takes the opposite stance, deliberately. Its directory listing
# IS its index — a subscriber's cursor is answered from the entry names — so
# an entry routed around is a hole in a stream nobody can detect, where a
# skipped block or blob is caught downstream by the content address it is
# stored under. All three shapes are therefore refused, including the
# directory whose name spells a valid seq-time pair, which is refused when it
# is opened rather than when it is listed.
expect_stray events-file "$EVENTS_REFUSED"
expect_named events-file events
expect_stray events-dir "$EVENTS_REFUSED"
expect_named events-dir events
expect_stray events-name "$EVENTS_REFUSED"
expect_named events-name events
echo 'case 11d: 15 entries no store wrote, one per level and shape; each skipped or refused as its module states, each refusal naming its own path, and no other store disturbed'

# ── 12. every promote is barriered, staged file first and directory after ──
# The only case here that reads the syscall STREAM rather than the resulting
# tree, because that is where the claim lives: after a power loss what survives
# is decided by the order writes reached the platter, and a directory built by
# hand cannot say which `rename` outran the bytes it publishes. Two rules over
# every `rename` the driver performs, checked in trace order:
#
#   - the syscall immediately BEFORE it is an `fsync` of exactly the path it
#     renames, so the promotion cannot become visible before its own contents;
#   - an `fsync` of the directory it renames INTO follows it, and follows every
#     later `rename` into that same directory, so the promotion itself is
#     durable.
#
# A third rule over every `mkdir` that SUCCEEDS: an `fsync` of the directory it
# created the entry in follows it. A directory is a promotion too — `mkdir`
# publishes a name in its parent — and a shard whose own entry a power loss
# takes is every block under it gone, however durable each block's bytes and
# each block's entry already are (#3056). A `mkdir` that fails EEXIST wrote no
# entry and owes nothing, which is why the rule reads the return value: the
# stores create a directory only when it is absent, so the steady-state cost of
# this is zero and the trace says so.
#
# Where that barrier comes from is not required to be the module that created
# the directory, and two of them deliberately are not: `<data>/blocks` and
# `<data>/blobs` are created by the two stores and barriered by the `fsync` of
# the data directory that `shell.persist` performs afterwards. The rule grades
# that coupling instead of assuming it — reorder the calls and the barrier
# stops following the creation, and this reports it.
#
# The second rule tolerates a writer that promotes a batch and then barriers the
# distinct directories it touched, which `blockfile.mdk` does: a directory's
# barrier may be deferred past promotes into other directories. What it does not
# tolerate is a barrier that never arrives, so the deferral is bounded — once a
# directory barrier is issued, every directory owed one must be barriered before
# the next `rename` starts a new batch. An owed barrier that outlives its batch,
# or the whole trace, is a rename published with nothing on the platter naming
# it.
#
# Universal over renames rather than a list of expected paths: a promote path
# added later is graded the day it is written, and cannot be forgotten here.
# The per-path coverage counts below are the other half — they fail if a
# promote path stopped being EXERCISED, which a universal rule alone reads as
# silence.
if ! command -v strace >/dev/null 2>&1; then
  # A SKIP IS ONLY LEGITIMATE OFF CI — `test/diff_compiler_ir_scaling.sh`'s
  # valgrind branch, same reasoning: on a dev box not everyone has strace, and a
  # hard failure there is noise. On a runner it means the install stopped
  # happening and the barrier claim has silently gone dark, which is the one
  # outcome a gate must never produce quietly. exit 1, not 2, so no
  # skip-classifier can reinterpret the verdict.
  if [ -n "${CI:-}" ]; then
    echo "FAIL: strace is not on PATH, and this is CI." >&2
    echo "  Case 12 reads the syscall order of the promote paths; without strace it" >&2
    echo "  grades NOTHING. Add strace to .github/actions/setup-medaka rather than" >&2
    echo "  deleting the case." >&2
    echo "  Debian/Ubuntu: sudo apt-get install -y strace" >&2
    exit 1
  fi
  echo "SKIP: strace not on PATH — case 12 reads the promote paths' syscall order."
  echo "  (A skip is only legitimate OFF CI; on CI this is a hard failure.)"
  echo "  Debian/Ubuntu: sudo apt-get install -y strace"
  exit 2
fi

# strace -y resolves an fd to its CANONICAL path, while `rename` reports the
# literal arguments, so the two only compare if the directory handed to the
# driver has no symlink in it.
PHYS=$(cd "$WORK" && pwd -P)

# One normalized event per line, in trace order: `F <path>` per fsync, `R <src>
# <dst>` per rename, `M <path>` per mkdir that actually created something.
# Everything else in the trace — the Boehm collector's SIGPWR/SIGXCPU pair
# above all — is dropped here rather than by an strace filter, so a syscall the
# filter forgot shows up as a missing line and not as a wrong verdict.
#
# `mkdirAll` walks a path from the root down and lets every component that is
# already there fail EEXIST, so only the `= 0` return is a created directory;
# the two spellings are matched because which of them glibc issues is its
# choice and not this tree's.
normalize_trace() {
  sed -n \
    -e 's/^[0-9][0-9]*  *//' \
    -e 's/^fsync([0-9][0-9]*<\(.*\)>) *= 0$/F \1/p' \
    -e 's/^rename("\([^"]*\)", "\([^"]*\)") *= 0$/R \1 \2/p' \
    -e 's/^mkdir("\([^"]*\)", [^)]*) *= 0$/M \1/p' \
    -e 's/^mkdirat([^,]*, "\([^"]*\)", [^)]*) *= 0$/M \1/p' \
    "$1"
}

# The driver runs under strace with threads followed: the compiler's runtime
# does its work on a GC-aware worker pthread, so an unfollowed trace records
# none of these calls at all.
trace_route() {
  _route=$1
  _dir=$2
  if ! strace -f -y -qq -e signal=none \
    -e trace=fsync,rename,renameat,renameat2,mkdir,mkdirat \
    -o "$WORK/trace.$_route" "$WORK/driver" "$_route" "$_dir" \
    > "$WORK/trace.$_route.out" 2> "$WORK/trace.$_route.err"
  then
    cat "$WORK/trace.$_route.err" >&2
    cat "$WORK/trace.$_route.out" >&2
    fail "traced $_route route failed"
  fi
  require_empty "$WORK/trace.$_route.err" "traced $_route"
  # Kept per route as well as concatenated: an ORDER claim about two writes
  # only holds inside ONE process, and `$WORK/promotes` interleaves five.
  normalize_trace "$WORK/trace.$_route" > "$WORK/events.$_route"
  cat "$WORK/events.$_route" >> "$WORK/promotes"
}

# The line number of the first or last normalized event in file $2 matching the
# regex $3, or the empty string when nothing matches. Line numbers ARE trace
# order, which is what every order assertion below compares.
trace_index() {
  case $1 in
    first) grep -n -E -- "$3" "$2" | head -1 | cut -d: -f1 ;;
    last) grep -n -E -- "$3" "$2" | tail -1 | cut -d: -f1 ;;
    *) fail "trace_index: $1 is not first or last" ;;
  esac
}

trace_count() {
  grep -c -E -- "$2" "$1" || true
}

: > "$WORK/promotes"
TRACED="$PHYS/traced"
mkdir -p "$TRACED"
trace_route save "$TRACED/repo"
trace_route blob-save "$TRACED/repo"
trace_route prefs-save "$TRACED/repo"
trace_route credential-save "$TRACED/repo"
trace_route event-recover-owed "$TRACED/events"

# The earlier generation is persisted BEFORE tracing starts, so the transition
# route's own trace holds `persistTransition` and nothing else — which is what
# lets 12a compare two writes without first having to say where the setup ended.
"$WORK/driver" crash-save-old "$TRACED/transition" > "$WORK/transition.setup" \
  2> "$WORK/transition.setup.err"
require_empty "$WORK/transition.setup.err" 'crash-save-old (transition setup)'
trace_route transition "$TRACED/transition"
[ "$(tail -1 "$WORK/trace.transition.out")" = 'TRANSITION: PASS' ] \
  || fail 'the traced transition route did not pass'

[ -s "$WORK/promotes" ] || fail 'the traced routes performed no promote at all'

# ── 12a. the two halves of one transition, in the order a crash needs ──────
# `persistTransition` runs the BLOB half before the repo half, and nothing in
# the resulting tree records which ran first: both halves succeed, so only the
# syscall order can say. The claim is the crash-safety one — a record may name
# blob bytes and never the reverse — so every blob promote must precede the
# `head` promote that publishes the commit able to name them. Swap the two
# calls in `persistTransition` and this is what notices (#3057).
#
# Read out of the transition route's OWN trace. `$WORK/promotes` concatenates
# five processes, and "before" across a process boundary is not this claim.
#
# Both order assertions run BEFORE the universal rule below, because a swap
# also strands `blobs/`'s dentry and the universal rule would otherwise fail
# first, reporting the consequence instead of the cause.
TRANS="$WORK/events.transition"
BLOB_PROMOTED=$(trace_count "$TRANS" '^R [^ ]* [^ ]*/blobs/[0-9a-f][0-9a-f]/')
[ "$BLOB_PROMOTED" -ge 1 ] \
  || fail 'case 12a: the transition promoted no blob, so the half order is ungraded'
LAST_BLOB_AT=$(trace_index last "$TRANS" '^R [^ ]* [^ ]*/blobs/[0-9a-f][0-9a-f]/')
FIRST_HEAD_AT=$(trace_index first "$TRANS" '^R [^ ]* [^ ]*/head$')
[ -n "$FIRST_HEAD_AT" ] \
  || fail 'case 12a: the transition promoted no head, so the half order is ungraded'
[ "$LAST_BLOB_AT" -lt "$FIRST_HEAD_AT" ] || {
  sed -n "${FIRST_HEAD_AT}p;${LAST_BLOB_AT}p" "$TRANS" >&2
  fail "case 12a: the commit was promoted at event $FIRST_HEAD_AT, the last blob at event $LAST_BLOB_AT; a crash between the halves can leave a committed record naming bytes that are not on disk"
}
echo "case 12a: $BLOB_PROMOTED blob promote(s), all before the commit's head promote"

# ── 12b. one directory barrier per batch, not one per block ────────────────
# `blockfile.mdk` promotes every block of a commit and then barriers the
# DISTINCT shard directories it touched, instead of barriering after each
# block. The universal rule below tolerates both — an extra fsync breaks
# nothing it states — so the batching was in fact ungraded, and the
# pre-batching code passes that rule unchanged (#3058).
#
# The discriminator is ORDER, not count. Under batching every block promote
# precedes every shard-directory barrier within one route; under a per-block
# barrier the two interleave from the second block onward. A count would not
# discriminate: a shard name is one digest byte, this fixture holds a handful
# of blocks, so distinct shards and blocks are equal with high probability and
# a per-block regression passes any count of them.
SAVED="$WORK/events.save"
SAVED_BLOCKS=$(trace_count "$SAVED" '^R [^ ]* [^ ]*/blocks/[0-9a-f][0-9a-f]/')
[ "$SAVED_BLOCKS" -ge 2 ] \
  || fail "case 12b: the save route promoted $SAVED_BLOCKS block(s); two are needed for an interleaving to be possible at all"
LAST_BLOCK_AT=$(trace_index last "$SAVED" '^R [^ ]* [^ ]*/blocks/[0-9a-f][0-9a-f]/')
FIRST_SHARD_AT=$(trace_index first "$SAVED" '^F [^ ]*/blocks/[0-9a-f][0-9a-f]$')
[ -n "$FIRST_SHARD_AT" ] || fail 'case 12b: no shard directory was barriered at all'
[ "$FIRST_SHARD_AT" -gt "$LAST_BLOCK_AT" ] || {
  sed -n "${FIRST_SHARD_AT}p;${LAST_BLOCK_AT}p" "$SAVED" >&2
  fail "case 12b: a shard directory was barriered at event $FIRST_SHARD_AT, before the last block promote at event $LAST_BLOCK_AT; the barriers are per block, not per batch"
}
echo "case 12b: $SAVED_BLOCKS block promote(s), all before the first shard-directory barrier"

# ── 12c. the blob area's own dentry, on a write that runs no repo half ─────
# `blobs/` is created by `blobfile.mdk`, and its dentry sits one level up, in
# the data directory. The universal rule below accepts a barrier from anywhere
# in `$WORK/promotes`, which concatenates five processes — so a data-directory
# `fsync` some OTHER route performed discharges this creation there, and the
# route that writes blobs and nothing else goes ungraded across the boundary
# that a crash actually respects. Read out of the blob-save route's OWN trace
# for that reason, like 12a.
#
# The route is the one `com.atproto.repo.uploadBlob` takes: it moves blobs and
# advances no repository, so `persistTransition`'s repo half is skipped and
# NOTHING outside `blobfile.mdk` barriers anything on it. The barrier has to be
# there before the blobs the run goes on to publish, or a crash after the
# client's 200 takes the whole subtree those blobs are under.
BLOBSAVE="$WORK/events.blob-save"
MKBLOBS_AT=$(trace_index first "$BLOBSAVE" "^M $TRACED/repo/blobs\$")
[ -n "$MKBLOBS_AT" ] \
  || fail 'case 12c: the blob-save route created no blob area, so its dentry is ungraded here'
DATA_FSYNC_AT=$(trace_index first "$BLOBSAVE" "^F $TRACED/repo\$")
[ -n "$DATA_FSYNC_AT" ] || {
  cat "$BLOBSAVE" >&2
  fail "case 12c: the blob-save route created $TRACED/repo/blobs and never barriered $TRACED/repo; a crash after this write loses the whole blobs subtree, however durable each blob beneath it is"
}
[ "$DATA_FSYNC_AT" -gt "$MKBLOBS_AT" ] || {
  sed -n "${DATA_FSYNC_AT}p;${MKBLOBS_AT}p" "$BLOBSAVE" >&2
  fail "case 12c: $TRACED/repo was barriered at event $DATA_FSYNC_AT, before the blob area was created at event $MKBLOBS_AT; that barrier carries no dentry that did not exist yet"
}
FIRST_PROMOTE_AT=$(trace_index first "$BLOBSAVE" '^R ')
[ -n "$FIRST_PROMOTE_AT" ] \
  || fail 'case 12c: the blob-save route promoted nothing, so the ordering is ungraded'
[ "$DATA_FSYNC_AT" -lt "$FIRST_PROMOTE_AT" ] || {
  sed -n "${DATA_FSYNC_AT}p;${FIRST_PROMOTE_AT}p" "$BLOBSAVE" >&2
  fail "case 12c: the first blob was promoted at event $FIRST_PROMOTE_AT, before $TRACED/repo was barriered at event $DATA_FSYNC_AT"
}
echo "case 12c: blob area created at event $MKBLOBS_AT and barriered into the data directory at event $DATA_FSYNC_AT, before the first promote at event $FIRST_PROMOTE_AT, with no repo half on the route"

awk '
  { ev[++n] = $0 }
  END {
    for (i = 1; i <= n; i++) {
      if (substr(ev[i], 1, 2) == "M ") {
        mk++
        mkpath[mk] = substr(ev[i], 3)
        mkpar[mk] = mkpath[mk]
        sub(/\/[^\/]*$/, "", mkpar[mk])
        continue
      }
      if (substr(ev[i], 1, 2) == "F ") {
        path = substr(ev[i], 3)
        # A staged-file barrier is the one whose own rename comes next; every
        # other fsync is a directory barrier and discharges what that directory
        # is owed.
        if (i < n && substr(ev[i + 1], 1, length(path) + 3) == "R " path " ")
          continue
        served = 0
        for (k = 1; k <= mk; k++)
          if (!mkdone[k] && mkpar[k] == path) { mkdone[k] = 1; served = 1 }
        if (path in owed) { delete owed[path]; nowed--; flushed = 1; continue }
        # A barrier that only discharges a directory CREATION is not the start
        # of a promote batch, and must not make the next `rename` look like one
        # that abandoned an owed directory.
        if (!served) flushed = 1
        continue
      }
      if (substr(ev[i], 1, 2) != "R ") continue
      renames++
      split(ev[i], a, " ")
      src = a[2]; dst = a[3]
      if (i == 1 || ev[i - 1] != "F " src) {
        printf "UNBARRIERED PROMOTE: %s\n  preceded by: %s\n", ev[i],
          (i > 1 ? ev[i - 1] : "<nothing>")
        bad++
        continue
      }
      if (flushed && nowed > 0) {
        for (d in owed) {
          printf "ABANDONED DIRECTORY: %s\n  %s was still owed a barrier when %s began\n",
            owed[d], d, ev[i]
          bad++
          delete owed[d]
        }
        nowed = 0
      }
      dir = dst
      sub(/\/[^\/]*$/, "", dir)
      if (!(dir in owed)) nowed++
      owed[dir] = ev[i]
      flushed = 0
    }
    for (d in owed) {
      printf "UNBARRIERED DIRECTORY: %s\n  no fsync of %s follows it\n", owed[d], d
      bad++
    }
    for (k = 1; k <= mk; k++) {
      if (mkdone[k]) continue
      printf "UNBARRIERED DIRECTORY CREATION: M %s\n  no fsync of %s follows it\n",
        mkpath[k], mkpar[k]
      bad++
    }
    printf "graded %d rename(s) and %d directory creation(s), %d unbarriered\n",
      renames, mk, bad
    exit (bad > 0)
  }
' "$WORK/promotes" > "$WORK/promotes.verdict" || {
  cat "$WORK/promotes.verdict" >&2
  fail 'a rename or a mkdir published a name no barrier had put on disk'
}
cat "$WORK/promotes.verdict"

# Per promote path: the universal rule above is silent about a path that
# stopped running, so each is counted by the shape of what it renames INTO.
promote_count() {
  grep -c "^R .* $1\$" "$WORK/promotes" || true
}
BLOCK_PROMOTES=$(promote_count '.*/blocks/[0-9a-f][0-9a-f]/[0-9a-f]*')
BLOB_MIME_PROMOTES=$(promote_count '.*/blobs/[0-9a-f][0-9a-f]/[0-9a-f]*\.mime')
BLOB_BYTE_PROMOTES=$(promote_count '.*/blobs/[0-9a-f][0-9a-f]/[0-9a-f]*')
ENTRY_PROMOTES=$(promote_count '.*/events/entries/.*')
POINTER_PROMOTES=$(promote_count '.*/events/\..*')
HEAD_PROMOTES=$(promote_count '.*/head')
PREFS_PROMOTES=$(promote_count '.*/preferences')
CREDENTIAL_PROMOTES=$(promote_count '.*/credential')
for PAIR in "blockfile:$BLOCK_PROMOTES" "blobfile sidecar:$BLOB_MIME_PROMOTES" \
  "blobfile bytes:$BLOB_BYTE_PROMOTES" "eventlog entry:$ENTRY_PROMOTES" \
  "eventlog pointer:$POINTER_PROMOTES" "persist head:$HEAD_PROMOTES" \
  "persist preferences:$PREFS_PROMOTES" "persist credential:$CREDENTIAL_PROMOTES"
do
  [ "${PAIR#*:}" -ge 1 ] \
    || fail "no ${PAIR%:*} promote was traced; that path is no longer graded"
done
echo "barriered promotes: blocks $BLOCK_PROMOTES, blob sidecars $BLOB_MIME_PROMOTES, blob bytes $BLOB_BYTE_PROMOTES, log entries $ENTRY_PROMOTES, log pointers $POINTER_PROMOTES, head $HEAD_PROMOTES, preferences $PREFS_PROMOTES, credential $CREDENTIAL_PROMOTES"

# The same floor for the directory-creation rule. The stores create a directory
# only when it is absent, so a traced run over a data directory that already
# had one would grade the rule against nothing at all and still pass it; these
# are what say the traced routes really did start from a directory with none of
# this in it.
mkdir_count() {
  grep -c "^M $1\$" "$WORK/promotes" || true
}
BLOCK_SHARD_DIRS=$(mkdir_count '.*/blocks/[0-9a-f][0-9a-f]')
BLOB_SHARD_DIRS=$(mkdir_count '.*/blobs/[0-9a-f][0-9a-f]')
ENTRY_DIRS=$(mkdir_count '.*/events/entries')
STAGING_DIRS=$(mkdir_count '.*/\.staging')
for PAIR in "blockfile shard:$BLOCK_SHARD_DIRS" "blobfile shard:$BLOB_SHARD_DIRS" \
  "eventlog entry:$ENTRY_DIRS" "staging:$STAGING_DIRS"
do
  [ "${PAIR#*:}" -ge 1 ] \
    || fail "no ${PAIR%:*} directory was created under trace; that creation path is no longer graded"
done
echo "barriered directory creations: block shards $BLOCK_SHARD_DIRS, blob shards $BLOB_SHARD_DIRS, entry directories $ENTRY_DIRS, staging directories $STAGING_DIRS"


echo 'PASS: store persistence — cross-process resume (repository and blobs); tamper rejected in both halves; oversize blob refused before any write; every constructed half-written state served the previous value or refused; a staged event anchored to no commit finished while planning wrote nothing; a genesis quartet interrupted at any of its four points finished on the next start and not again, while a lost last-promoted pointer over surviving entries was refused rather than re-minted; every entry no store wrote skipped or refused as its module states, at every listed level; every promote barriered before and after, and every directory a store created barriered into the directory it named it in, with the blob half of one transition promoted before the commit that can name it and every shard barrier of one commit taken after all of its block promotes; key absent'
