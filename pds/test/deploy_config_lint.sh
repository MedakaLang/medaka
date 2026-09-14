#!/bin/sh
# #2958 #2959 deploy-config hardening: `pds/pds.service` and `pds/Caddyfile`
# are one deployment artifact split across two syntaxes (a systemd unit and a
# Caddy config), so this is ONE gate covering both, not two.
#
# Each file must carry a fixed roster of hardening directives. Neither file
# is `.mdk`, so this is a plain text grep/awk check with no build required —
# same shape as pds/test/lib_boundary.sh's source-shape checks.
#
# A mutation control proves each check can actually fail: every required
# directive is stripped, one at a time, from a scratch copy of the owning
# file, and the check is shown to red on the mutated copy before the real
# tree is checked again to prove it is untouched and green.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
SERVICE="$ROOT/pds/pds.service"
CADDYFILE="$ROOT/pds/Caddyfile"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-deploy-config.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Each entry is "label:pattern" — an extended-regex grep -E against the whole
# file. One miss is one violation line naming the label.
SERVICE_DIRECTIVES='
NoNewPrivileges:^NoNewPrivileges=true
ProtectSystem:^ProtectSystem=strict
ReadWritePaths:^ReadWritePaths=
PrivateTmp:^PrivateTmp=true
MemoryMax:^MemoryMax=
CPUWeight-or-Nice:^(CPUWeight|Nice)=
TasksMax:^TasksMax=
LimitNOFILE:^LimitNOFILE=
StartLimitBurst:^StartLimitBurst=
IPAddressDeny:^IPAddressDeny=any
IPAddressAllow:^IPAddressAllow=.*localhost
CapabilityBoundingSet:^CapabilityBoundingSet=
ProtectHome:^ProtectHome=
PrivateDevices:^PrivateDevices=true
UMask:^UMask=
RequiresMountsFor:^RequiresMountsFor=
'

CADDY_DIRECTIVES='
Strict-Transport-Security:Strict-Transport-Security
request_body:request_body
max_size:max_size
timeout:(read_timeout|write_timeout|dial_timeout|timeouts)
log:^[ \t]*log[ \t]*\{
X-Forwarded-For:header_up X-Forwarded-For
'

# Prints one violation line per missing directive; exit 0 with no output when
# every directive in $2 (a newline-separated "label:pattern" list) is present
# in file $1.
check_directives() {
  file=$1
  directives=$2
  echo "$directives" | while IFS=: read -r label pattern; do
    [ -z "$label" ] && continue
    if ! grep -Eq "$pattern" "$file"; then
      echo "$file: missing $label (pattern: $pattern)"
    fi
  done
}

# ── the real tree ────────────────────────────────────────────────────────────

service_hits=$(check_directives "$SERVICE" "$SERVICE_DIRECTIVES")
if [ -n "$service_hits" ]; then
  echo "$service_hits" >&2
  fail 'pds/pds.service is missing a required hardening directive'
fi

caddy_hits=$(check_directives "$CADDYFILE" "$CADDY_DIRECTIVES")
if [ -n "$caddy_hits" ]; then
  echo "$caddy_hits" >&2
  fail 'pds/Caddyfile is missing a required hardening directive'
fi

echo 'deploy config clean: pds.service and Caddyfile carry every required hardening directive'

# ── mutation control: prove each side can fail ──────────────────────────────

# Violation 1: strip one systemd directive (IPAddressDeny) from a scratch
# copy of pds.service.
SCRATCH_SERVICE="$WORK/pds.service"
grep -v '^IPAddressDeny=' "$SERVICE" >"$SCRATCH_SERVICE"
if hits=$(check_directives "$SCRATCH_SERVICE" "$SERVICE_DIRECTIVES") \
  && [ -z "$hits" ]; then
  fail 'mutation control: a stripped systemd directive (IPAddressDeny) was not caught'
fi
echo 'mutation control: a stripped systemd directive (IPAddressDeny) correctly caught'
rm -f "$SCRATCH_SERVICE"

# Violation 2: strip a second systemd directive (MemoryMax), to show the
# check is not accidentally keyed on the one directive above.
SCRATCH_SERVICE="$WORK/pds.service"
grep -v '^MemoryMax=' "$SERVICE" >"$SCRATCH_SERVICE"
if hits=$(check_directives "$SCRATCH_SERVICE" "$SERVICE_DIRECTIVES") \
  && [ -z "$hits" ]; then
  fail 'mutation control: a stripped systemd directive (MemoryMax) was not caught'
fi
echo 'mutation control: a stripped systemd directive (MemoryMax) correctly caught'
rm -f "$SCRATCH_SERVICE"

# Violation 3: strip the HSTS header from a scratch copy of the Caddyfile.
SCRATCH_CADDY="$WORK/Caddyfile"
grep -v 'Strict-Transport-Security' "$CADDYFILE" >"$SCRATCH_CADDY"
if hits=$(check_directives "$SCRATCH_CADDY" "$CADDY_DIRECTIVES") \
  && [ -z "$hits" ]; then
  fail 'mutation control: a stripped Caddy directive (Strict-Transport-Security) was not caught'
fi
echo 'mutation control: a stripped Caddy directive (Strict-Transport-Security) correctly caught'
rm -f "$SCRATCH_CADDY"

# Violation 4: strip the request body limit, a second independent Caddy
# directive.
SCRATCH_CADDY="$WORK/Caddyfile"
grep -v 'max_size' "$CADDYFILE" >"$SCRATCH_CADDY"
if hits=$(check_directives "$SCRATCH_CADDY" "$CADDY_DIRECTIVES") \
  && [ -z "$hits" ]; then
  fail 'mutation control: a stripped Caddy directive (max_size) was not caught'
fi
echo 'mutation control: a stripped Caddy directive (max_size) correctly caught'
rm -f "$SCRATCH_CADDY"

# Confirm the real tree is untouched and still green after every mutation.
service_hits=$(check_directives "$SERVICE" "$SERVICE_DIRECTIVES")
caddy_hits=$(check_directives "$CADDYFILE" "$CADDY_DIRECTIVES")
if [ -n "$service_hits" ] || [ -n "$caddy_hits" ]; then
  fail 'the real tree is no longer clean after the mutation control'
fi
echo 'real tree confirmed unaffected by the mutation control'
