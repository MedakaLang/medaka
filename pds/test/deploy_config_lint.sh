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
EGRESS_SERVICE="$ROOT/pds/pds-egress.service"
EGRESS_CADDYFILE="$ROOT/pds/Caddyfile.egress"
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

# The egress unit needs the same hardening class as pds.service (D1), plus
# the network-layer SSRF guard its header comment describes: systemd's
# IPAddress* filter matches addresses and never hostnames, so this roster
# pins the private/link-local/CGNAT ranges the unit must deny, not a list
# of upstream hosts (those live in Caddyfile.egress's fixed port-to-host
# mapping, below). The one allow entry is 127.0.0.1, narrower than the
# `IPAddressDeny=localhost` beside it because an allow match wins outright.
EGRESS_SERVICE_DIRECTIVES='
NoNewPrivileges:^NoNewPrivileges=true
ProtectSystem:^ProtectSystem=strict
PrivateTmp:^PrivateTmp=true
MemoryMax:^MemoryMax=
CPUWeight-or-Nice:^(CPUWeight|Nice)=
TasksMax:^TasksMax=
LimitNOFILE:^LimitNOFILE=
StartLimitBurst:^StartLimitBurst=
IPAddressAllow-loopback:^IPAddressAllow=127\.0\.0\.1$
IPAddressDeny-loopback-rest:^IPAddressDeny=localhost$
IPAddressDeny-private-10:^IPAddressDeny=10\.0\.0\.0/8$
IPAddressDeny-private-172:^IPAddressDeny=172\.16\.0\.0/12$
IPAddressDeny-private-192:^IPAddressDeny=192\.168\.0\.0/16$
IPAddressDeny-link-local:^IPAddressDeny=169\.254\.0\.0/16$
IPAddressDeny-cgnat:^IPAddressDeny=100\.64\.0\.0/10$
IPAddressDeny-unique-local-v6:^IPAddressDeny=fc00::/7$
IPAddressDeny-link-local-v6:^IPAddressDeny=fe80::/10$
CapabilityBoundingSet:^CapabilityBoundingSet=
ProtectHome:^ProtectHome=
PrivateDevices:^PrivateDevices=true
UMask:^UMask=
RequiresMountsFor:^RequiresMountsFor=
'

# The other half of that guard, and the reason it is a forbidden-construct
# check rather than a required directive: systemd consults the allow list
# first and an allow match wins outright, so a single `IPAddressAllow=any`
# would match every packet and leave every deny line above dead while the
# roster check still passed.
EGRESS_SERVICE_FORBIDDEN='
blanket-allow:^IPAddressAllow=any$
'

# Each egress site block must reverse-proxy to a fixed real-world host, on
# the loopback port that host's `pds serve` flag names — see §4 of
# docs/ops/PDS-DEPLOY.md for the port roster (3128 appview, 3129 relay,
# 3130 chat, all reused unchanged here).
EGRESS_CADDY_DIRECTIVES='
listen-appview:^http://127\.0\.0\.1:3128[ \t]*\{
listen-relay:^http://127\.0\.0\.1:3129[ \t]*\{
listen-chat:^http://127\.0\.0\.1:3130[ \t]*\{
upstream-appview:reverse_proxy https://api\.bsky\.app
upstream-relay:reverse_proxy https://relay\.example\.com
upstream-chat:reverse_proxy https://api\.bsky\.chat
timeout:(read_timeout|write_timeout|dial_timeout|timeouts)
log:^[ \t]*log[ \t]*\{
'

# The allow-list property, not a directive roster: a `reverse_proxy` whose
# target is a placeholder (no fixed host between the directive and its
# block, or a Caddy variable / header interpolated into the target) is
# exactly the dynamic-upstream shape this file must never have — the fixed
# 1:1 port-to-host mapping IS the allow-list, so nothing here may pick an
# upstream at request time.
EGRESS_CADDY_FORBIDDEN='
dynamic-upstream-empty:reverse_proxy[ \t]*\{
dynamic-upstream-variable:reverse_proxy.*\{(http\.|\$)
'

# Prints one violation line per matched forbidden pattern; exit 0 with no
# output when none of $2's patterns (a newline-separated "label:pattern"
# list) match in file $1. The mirror image of check_directives: there, a
# MISS is a violation; here, a HIT is.
check_forbidden() {
  file=$1
  patterns=$2
  echo "$patterns" | while IFS=: read -r label pattern; do
    [ -z "$label" ] && continue
    if grep -Eq "$pattern" "$file"; then
      echo "$file: forbidden construct present: $label (pattern: $pattern)"
    fi
  done
}

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

egress_service_hits=$(check_directives "$EGRESS_SERVICE" "$EGRESS_SERVICE_DIRECTIVES")
if [ -n "$egress_service_hits" ]; then
  echo "$egress_service_hits" >&2
  fail 'pds/pds-egress.service is missing a required hardening directive'
fi

egress_service_forbidden=$(check_forbidden "$EGRESS_SERVICE" "$EGRESS_SERVICE_FORBIDDEN")
if [ -n "$egress_service_forbidden" ]; then
  echo "$egress_service_forbidden" >&2
  fail 'pds/pds-egress.service has a blanket IPAddressAllow that voids its deny list'
fi

egress_caddy_hits=$(check_directives "$EGRESS_CADDYFILE" "$EGRESS_CADDY_DIRECTIVES")
if [ -n "$egress_caddy_hits" ]; then
  echo "$egress_caddy_hits" >&2
  fail 'pds/Caddyfile.egress is missing a required hardening directive'
fi

egress_caddy_forbidden=$(check_forbidden "$EGRESS_CADDYFILE" "$EGRESS_CADDY_FORBIDDEN")
if [ -n "$egress_caddy_forbidden" ]; then
  echo "$egress_caddy_forbidden" >&2
  fail 'pds/Caddyfile.egress has a dynamic/header-driven upstream'
fi

echo 'deploy config clean: pds.service, Caddyfile, pds-egress.service, and Caddyfile.egress carry every required hardening directive'

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

# Violation 5: drop a single denied range (172.16.0.0/12) from an otherwise
# correct copy of the egress unit — the smallest hole someone can open in
# the SSRF guard, and one that leaves every other directive intact.
SCRATCH_EGRESS_SERVICE="$WORK/pds-egress.service"
grep -v '^IPAddressDeny=172\.16\.0\.0/12$' "$EGRESS_SERVICE" >"$SCRATCH_EGRESS_SERVICE"
if hits=$(check_directives "$SCRATCH_EGRESS_SERVICE" "$EGRESS_SERVICE_DIRECTIVES") \
  && [ -z "$hits" ]; then
  fail 'mutation control: a dropped egress IPAddressDeny range (172.16.0.0/12) was not caught'
fi
echo 'mutation control: a dropped egress IPAddressDeny range (172.16.0.0/12) correctly caught'
rm -f "$SCRATCH_EGRESS_SERVICE"

# Violation 6: add a blanket IPAddressAllow to an otherwise correct copy of
# the egress unit. The directive roster still passes on this copy — every
# deny line is still present — which is why the forbidden-direction check
# exists and is what this control proves.
SCRATCH_EGRESS_SERVICE="$WORK/pds-egress.service"
cp "$EGRESS_SERVICE" "$SCRATCH_EGRESS_SERVICE"
printf 'IPAddressAllow=any\n' >>"$SCRATCH_EGRESS_SERVICE"
if hits=$(check_forbidden "$SCRATCH_EGRESS_SERVICE" "$EGRESS_SERVICE_FORBIDDEN") \
  && [ -z "$hits" ]; then
  fail 'mutation control: a blanket egress IPAddressAllow (any) was not caught'
fi
if roster=$(check_directives "$SCRATCH_EGRESS_SERVICE" "$EGRESS_SERVICE_DIRECTIVES") \
  && [ -n "$roster" ]; then
  fail 'mutation control: the blanket-allow copy was expected to pass the directive roster'
fi
echo 'mutation control: a blanket egress IPAddressAllow (any) correctly caught'
rm -f "$SCRATCH_EGRESS_SERVICE"

# Violation 7: replace one fixed egress upstream with a dynamic,
# header-driven target — the allow-list-by-fixed-mapping property itself.
SCRATCH_EGRESS_CADDY="$WORK/Caddyfile.egress"
sed 's#reverse_proxy https://api\.bsky\.app#reverse_proxy {http.request.header.X-Upstream}#' \
  "$EGRESS_CADDYFILE" >"$SCRATCH_EGRESS_CADDY"
if hits=$(check_forbidden "$SCRATCH_EGRESS_CADDY" "$EGRESS_CADDY_FORBIDDEN") \
  && [ -z "$hits" ]; then
  fail 'mutation control: a dynamic/header-driven egress upstream was not caught'
fi
echo 'mutation control: a dynamic/header-driven egress upstream correctly caught'
rm -f "$SCRATCH_EGRESS_CADDY"

# Violation 8: strip a required egress site block's fixed-host directive
# (chat), to show the directive check is not accidentally satisfied by the
# appview/relay blocks alone.
SCRATCH_EGRESS_CADDY="$WORK/Caddyfile.egress"
grep -v 'reverse_proxy https://api\.bsky\.chat' "$EGRESS_CADDYFILE" >"$SCRATCH_EGRESS_CADDY"
if hits=$(check_directives "$SCRATCH_EGRESS_CADDY" "$EGRESS_CADDY_DIRECTIVES") \
  && [ -z "$hits" ]; then
  fail 'mutation control: a stripped egress upstream (chat) was not caught'
fi
echo 'mutation control: a stripped egress upstream (chat) correctly caught'
rm -f "$SCRATCH_EGRESS_CADDY"

# Confirm the real tree is untouched and still green after every mutation.
service_hits=$(check_directives "$SERVICE" "$SERVICE_DIRECTIVES")
caddy_hits=$(check_directives "$CADDYFILE" "$CADDY_DIRECTIVES")
egress_service_hits=$(check_directives "$EGRESS_SERVICE" "$EGRESS_SERVICE_DIRECTIVES")
egress_service_forbidden=$(check_forbidden "$EGRESS_SERVICE" "$EGRESS_SERVICE_FORBIDDEN")
egress_caddy_hits=$(check_directives "$EGRESS_CADDYFILE" "$EGRESS_CADDY_DIRECTIVES")
egress_caddy_forbidden=$(check_forbidden "$EGRESS_CADDYFILE" "$EGRESS_CADDY_FORBIDDEN")
if [ -n "$service_hits" ] || [ -n "$caddy_hits" ] || [ -n "$egress_service_hits" ] \
  || [ -n "$egress_service_forbidden" ] \
  || [ -n "$egress_caddy_hits" ] || [ -n "$egress_caddy_forbidden" ]; then
  fail 'the real tree is no longer clean after the mutation control'
fi
echo 'real tree confirmed unaffected by the mutation control'
