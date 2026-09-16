#!/bin/sh
# pds/backup.sh — one encrypted off-box backup of a live PDS deployment.
# Run by pds-backup.service on the pds-backup.timer schedule; see
# docs/ops/PDS-DEPLOY.md § "Scheduled encrypted backups" for installation.
#
# ── WHY THIS STOPS THE SERVER ────────────────────────────────────────────────
#
# docs/ops/PDS-DEPLOY.md § "Backup and restore" fixes the consistency rule:
# a file-level copy must be taken with the server STOPPED or from an atomic
# filesystem snapshot, because `applyRequest`'s write serialization
# (pds/shell/server.mdk) is a single `liftIO` inside one cooperatively
# scheduled process, not a lock an external `tar` can take. A copy taken
# while the server runs can capture a torn write.
#
# This box has no snapshot facility to use instead: the data lives on a plain
# ext4 partition with no LVM and no btrfs. So the stop is not a preference,
# it is the only correct option available, and this script takes it.
#
# The outage is the ARCHIVE, not the upload: the server is started again as
# soon as the encrypted archive exists on local disk, and the upload to
# off-box storage happens afterwards with the server already serving.
#
# ── WHY IT CANNOT VERIFY ITS OWN BACKUPS ─────────────────────────────────────
#
# The archive is encrypted to a public key whose PRIVATE half deliberately
# never touches this box (criterion B16, docs/ops/PDS-LAUNCH-PLAN.md): that is
# what makes a box compromise unable to read the backups it produced. The
# direct consequence is that nothing here can decrypt what it just wrote, so
# "the backup is restorable" is NOT a property this script establishes. It
# checks that the archive is non-empty and that the uploaded object matches
# the local one. The restore drill (criterion D5) is a manual, periodic
# exercise on a machine that holds the private key, and it is the only thing
# that proves a backup is good.
set -eu

CONFIG=${PDS_BACKUP_CONFIG:-/etc/pds/backup.env}

log() { echo "pds-backup: $1"; }
fail() { echo "pds-backup: $1" >&2; exit 1; }

[ -r "$CONFIG" ] || fail "cannot read $CONFIG (see docs/ops/PDS-DEPLOY.md)"
# shellcheck disable=SC1090
. "$CONFIG"

: "${PDS_ROOT:?PDS_ROOT not set in $CONFIG}"
: "${PDS_UNIT:?PDS_UNIT not set in $CONFIG}"
: "${AGE_RECIPIENT:?AGE_RECIPIENT not set in $CONFIG}"
: "${RCLONE_CONFIG_PATH:?RCLONE_CONFIG_PATH not set in $CONFIG}"
: "${RCLONE_REMOTE:?RCLONE_REMOTE not set in $CONFIG}"

# Both are operator-installed and neither ships with the base system, so say
# which one is missing rather than letting a pipe fail with "not found".
command -v age >/dev/null 2>&1 || fail 'age is not installed (apt install age, or https://age-encryption.org)'
command -v rclone >/dev/null 2>&1 || fail 'rclone is not installed (apt install rclone)'

[ -d "$PDS_ROOT/data" ] || fail "no data directory at $PDS_ROOT/data"
[ -d "$PDS_ROOT/secrets" ] || fail "no secrets directory at $PDS_ROOT/secrets"

WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/pds-backup.XXXXXX")
chmod 0700 "$WORK"

# The server must come back up whatever happens next — a failed archive or a
# failed upload must not leave the deployment down until someone notices. This
# trap fires on normal exit, on `set -e`'s exit, and on a signal, and
# `systemctl start` is idempotent, so a run that never stopped the server is
# unharmed by it.
started_again=no
restore_service() {
  if [ "$started_again" = no ]; then
    started_again=yes
    systemctl start "$PDS_UNIT" || echo "pds-backup: FAILED to restart $PDS_UNIT" >&2
  fi
  rm -rf "$WORK"
}
trap restore_service EXIT HUP INT TERM

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ARCHIVE="$WORK/pds-$STAMP.tar.age"
TAR_RC="$WORK/tar.rc"

log "stopping $PDS_UNIT for the archive"
systemctl stop "$PDS_UNIT"

# `tar -p` preserves the 0600 modes on the signing key, the session-token
# secret and the credential. A backup that widened one restores into a server
# that refuses to start (`requirePrivateMode`, pds/serve.mdk).
#
# The left side of a pipe runs in a subshell, and `set -o pipefail` is not
# POSIX, so tar reports its own failure through a file. Without this, a tar
# that died halfway still feeds `age` a valid prefix, `age` exits 0, and a
# TRUNCATED archive uploads as if it were whole.
{ tar -cpf - -C "$PDS_ROOT" data secrets || printf '%s' "$?" >"$TAR_RC"; } \
  | age -r "$AGE_RECIPIENT" -o "$ARCHIVE"

if [ -s "$TAR_RC" ]; then
  fail "tar failed (exit $(cat "$TAR_RC")); the archive is incomplete and was not uploaded"
fi
[ -s "$ARCHIVE" ] || fail 'age produced an empty archive; nothing uploaded'

log "archive written, restarting $PDS_UNIT before the upload"
started_again=yes
systemctl start "$PDS_UNIT"

LOCAL_BYTES=$(wc -c <"$ARCHIVE" | tr -d ' ')
log "uploading $LOCAL_BYTES bytes to $RCLONE_REMOTE"

# `copyto` rather than `rcat`: it verifies the uploaded object against the
# local file, where a streamed `rcat` would report success for a short write.
rclone --config "$RCLONE_CONFIG_PATH" copyto "$ARCHIVE" \
  "$RCLONE_REMOTE/pds-$STAMP.tar.age" \
  || fail 'rclone upload failed; the local archive is discarded and this run made no backup'

REMOTE_BYTES=$(rclone --config "$RCLONE_CONFIG_PATH" size --json \
  "$RCLONE_REMOTE/pds-$STAMP.tar.age" 2>/dev/null \
  | tr ',' '\n' | sed -n 's/.*"bytes":[ ]*\([0-9][0-9]*\).*/\1/p' | head -1)

[ -n "$REMOTE_BYTES" ] || fail 'uploaded object could not be read back; treat this run as failed'
[ "$REMOTE_BYTES" = "$LOCAL_BYTES" ] \
  || fail "uploaded object is $REMOTE_BYTES bytes, local archive is $LOCAL_BYTES; treat this run as failed"

log "ok: pds-$STAMP.tar.age, $LOCAL_BYTES bytes, verified on the remote"
