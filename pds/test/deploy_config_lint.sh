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
BACKUP_SERVICE="$ROOT/pds/pds-backup.service"
BACKUP_TIMER="$ROOT/pds/pds-backup.timer"
HEALTHPING_SERVICE="$ROOT/pds/pds-healthping.service"
HEALTHPING_TIMER="$ROOT/pds/pds-healthping.timer"
ALERT_SERVICE="$ROOT/pds/pds-alert@.service"
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
OnFailure-alert:^OnFailure=pds-alert@%n\.service$
'

# The three observability/custody units (#2967 E5/E6, #2962 D5/B16) reach the
# public internet by design, so none of them can carry pds.service's
# `IPAddressDeny=any`. What they CAN carry is the egress-by-allow-list
# narrowing pds-egress.service already uses: deny the private, link-local and
# CGNAT ranges an SSRF would aim at, and leave the public internet reachable.
# This roster is the shared floor for all three.
OUTBOUND_UNIT_DIRECTIVES='
NoNewPrivileges:^NoNewPrivileges=true
ProtectSystem:^ProtectSystem=strict
ProtectHome:^ProtectHome=
PrivateDevices:^PrivateDevices=true
PrivateTmp:^PrivateTmp=true
UMask:^UMask=
MemoryMax:^MemoryMax=
TasksMax:^TasksMax=
LimitNOFILE:^LimitNOFILE=
CPUWeight-or-Nice:^(CPUWeight|Nice)=
IPAddressAllow-loopback:^IPAddressAllow=127\.0\.0\.1$
IPAddressDeny-loopback-rest:^IPAddressDeny=localhost$
IPAddressDeny-private-10:^IPAddressDeny=10\.0\.0\.0/8$
IPAddressDeny-private-172:^IPAddressDeny=172\.16\.0\.0/12$
IPAddressDeny-private-192:^IPAddressDeny=192\.168\.0\.0/16$
IPAddressDeny-link-local:^IPAddressDeny=169\.254\.0\.0/16$
IPAddressDeny-cgnat:^IPAddressDeny=100\.64\.0\.0/10$
IPAddressDeny-unique-local-v6:^IPAddressDeny=fc00::/7$
IPAddressDeny-link-local-v6:^IPAddressDeny=fe80::/10$
'

# Same reason as EGRESS_SERVICE_FORBIDDEN: systemd consults the allow list
# first and an allow match wins outright, so one `IPAddressAllow=any` leaves
# every deny line above dead while the roster check still passes.
OUTBOUND_UNIT_FORBIDDEN='
blanket-allow:^IPAddressAllow=any$
'

# The backup unit's own additions on top of that floor. TimeoutStartSec is
# required because a wedged backup holds nothing useful and must yield to the
# next timer; OnFailure is required because a backup that quietly stops running
# is the exact failure this unit exists to prevent.
BACKUP_SERVICE_DIRECTIVES='
Type-oneshot:^Type=oneshot
ExecStart-script:^ExecStart=/opt/pds/backup\.sh$
TimeoutStartSec:^TimeoutStartSec=
OnFailure-alert:^OnFailure=pds-alert@%n\.service$
'

# Persistent= on the backup timer and its ABSENCE on the healthping timer are
# both load-bearing and opposite, so each is pinned in its own direction: a
# missed backup must run late, a missed liveness ping must never be replayed
# (replaying one reports health for a window the box spent switched off).
BACKUP_TIMER_DIRECTIVES='
OnCalendar:^OnCalendar=
Persistent:^Persistent=true$
RandomizedDelay:^RandomizedDelaySec=
WantedBy:^WantedBy=timers\.target$
'

HEALTHPING_TIMER_DIRECTIVES='
OnUnitActiveSec:^OnUnitActiveSec=
OnBootSec:^OnBootSec=
WantedBy:^WantedBy=timers\.target$
'

HEALTHPING_TIMER_FORBIDDEN='
persistent-replay:^Persistent=true$
'

# `curl -f` is what makes the ping conditional on a HEALTHY answer rather than
# on a reachable socket: without it a 500 is still an exit-0 fetch and the
# dead-man'"'"'s switch would be fed by a server failing every request.
HEALTHPING_SERVICE_DIRECTIVES='
Type-oneshot:^Type=oneshot
EnvironmentFile:^EnvironmentFile=/etc/pds/alert\.env$
health-route-probed:/xrpc/_health
curl-fail-on-http-error:curl -fsS
'

# The alert unit must not carry OnFailure= — it IS the OnFailure target, and a
# self-referential one would loop.
ALERT_SERVICE_DIRECTIVES='
Type-oneshot:^Type=oneshot
EnvironmentFile:^EnvironmentFile=/etc/pds/alert\.env$
curl-fail-on-http-error:curl -fsS
'

ALERT_SERVICE_FORBIDDEN='
self-referential-onfailure:^OnFailure=
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
admin-off:^\tadmin off$
bind-loopback-appview:^\tbind 127\.0\.0\.1$
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

# ── the three outbound units (#2967 E5/E6, #2962 D5/B16) ───────────────────

for _unit_path in "$BACKUP_SERVICE" "$HEALTHPING_SERVICE" "$ALERT_SERVICE"; do
  _hits=$(check_directives "$_unit_path" "$OUTBOUND_UNIT_DIRECTIVES")
  if [ -n "$_hits" ]; then
    echo "$_hits" >&2
    fail "$(basename "$_unit_path") is missing a required hardening directive"
  fi
  _forbidden=$(check_forbidden "$_unit_path" "$OUTBOUND_UNIT_FORBIDDEN")
  if [ -n "$_forbidden" ]; then
    echo "$_forbidden" >&2
    fail "$(basename "$_unit_path") has a blanket IPAddressAllow that voids its deny list"
  fi
done

backup_hits=$(check_directives "$BACKUP_SERVICE" "$BACKUP_SERVICE_DIRECTIVES")
if [ -n "$backup_hits" ]; then
  echo "$backup_hits" >&2
  fail 'pds/pds-backup.service is missing a required directive'
fi

backup_timer_hits=$(check_directives "$BACKUP_TIMER" "$BACKUP_TIMER_DIRECTIVES")
if [ -n "$backup_timer_hits" ]; then
  echo "$backup_timer_hits" >&2
  fail 'pds/pds-backup.timer is missing a required directive'
fi

healthping_hits=$(check_directives "$HEALTHPING_SERVICE" "$HEALTHPING_SERVICE_DIRECTIVES")
if [ -n "$healthping_hits" ]; then
  echo "$healthping_hits" >&2
  fail 'pds/pds-healthping.service is missing a required directive'
fi

healthping_timer_hits=$(check_directives "$HEALTHPING_TIMER" "$HEALTHPING_TIMER_DIRECTIVES")
if [ -n "$healthping_timer_hits" ]; then
  echo "$healthping_timer_hits" >&2
  fail 'pds/pds-healthping.timer is missing a required directive'
fi

healthping_timer_forbidden=$(check_forbidden "$HEALTHPING_TIMER" "$HEALTHPING_TIMER_FORBIDDEN")
if [ -n "$healthping_timer_forbidden" ]; then
  echo "$healthping_timer_forbidden" >&2
  fail 'pds/pds-healthping.timer replays missed pings, which reports health for an outage'
fi

alert_hits=$(check_directives "$ALERT_SERVICE" "$ALERT_SERVICE_DIRECTIVES")
if [ -n "$alert_hits" ]; then
  echo "$alert_hits" >&2
  fail 'pds/pds-alert@.service is missing a required directive'
fi

alert_forbidden=$(check_forbidden "$ALERT_SERVICE" "$ALERT_SERVICE_FORBIDDEN")
if [ -n "$alert_forbidden" ]; then
  echo "$alert_forbidden" >&2
  fail 'pds/pds-alert@.service has a self-referential OnFailure'
fi

echo 'deploy config clean: pds.service, Caddyfile, pds-egress.service, Caddyfile.egress, and the backup/healthping/alert units carry every required hardening directive'

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

# Violation 9: drop a denied range from the backup unit. The three outbound
# units share one roster, so this also proves that roster is wired to them.
SCRATCH_BACKUP="$WORK/pds-backup.service"
grep -v '^IPAddressDeny=169\.254\.0\.0/16$' "$BACKUP_SERVICE" >"$SCRATCH_BACKUP"
if hits=$(check_directives "$SCRATCH_BACKUP" "$OUTBOUND_UNIT_DIRECTIVES") \
  && [ -z "$hits" ]; then
  fail 'mutation control: a dropped backup IPAddressDeny range (169.254.0.0/16) was not caught'
fi
echo 'mutation control: a dropped backup IPAddressDeny range (169.254.0.0/16) correctly caught'
rm -f "$SCRATCH_BACKUP"

# Violation 10: add Persistent=true to the healthping timer. The directive
# roster still passes on this copy — nothing was removed — which is exactly
# why the forbidden-direction check exists. A replayed liveness ping reports
# health for a window the box spent switched off.
SCRATCH_HEALTHPING_TIMER="$WORK/pds-healthping.timer"
cp "$HEALTHPING_TIMER" "$SCRATCH_HEALTHPING_TIMER"
printf 'Persistent=true\n' >>"$SCRATCH_HEALTHPING_TIMER"
if hits=$(check_forbidden "$SCRATCH_HEALTHPING_TIMER" "$HEALTHPING_TIMER_FORBIDDEN") \
  && [ -z "$hits" ]; then
  fail 'mutation control: a replaying healthping timer (Persistent=true) was not caught'
fi
if roster=$(check_directives "$SCRATCH_HEALTHPING_TIMER" "$HEALTHPING_TIMER_DIRECTIVES") \
  && [ -n "$roster" ]; then
  fail 'mutation control: the Persistent=true copy was expected to pass the directive roster'
fi
echo 'mutation control: a replaying healthping timer (Persistent=true) correctly caught'
rm -f "$SCRATCH_HEALTHPING_TIMER"

# Violation 11: drop `-f` from the healthping probe. The unit still runs and
# still pings; it just starts feeding the dead-man's switch from a server that
# is answering every request with an error.
SCRATCH_HEALTHPING="$WORK/pds-healthping.service"
sed 's/curl -fsS/curl -sS/g' "$HEALTHPING_SERVICE" >"$SCRATCH_HEALTHPING"
if hits=$(check_directives "$SCRATCH_HEALTHPING" "$HEALTHPING_SERVICE_DIRECTIVES") \
  && [ -z "$hits" ]; then
  fail 'mutation control: a healthping probe that ignores HTTP errors was not caught'
fi
echo 'mutation control: a healthping probe that ignores HTTP errors correctly caught'
rm -f "$SCRATCH_HEALTHPING"

# Violation 12: strip OnFailure from pds.service. Nothing else about the unit
# changes, and the service still runs — the only thing lost is the alert, which
# is the failure mode this whole pair of units exists to close.
SCRATCH_SERVICE="$WORK/pds.service"
grep -v '^OnFailure=' "$SERVICE" >"$SCRATCH_SERVICE"
if hits=$(check_directives "$SCRATCH_SERVICE" "$SERVICE_DIRECTIVES") \
  && [ -z "$hits" ]; then
  fail 'mutation control: a stripped OnFailure= on pds.service was not caught'
fi
echo 'mutation control: a stripped OnFailure= on pds.service correctly caught'
rm -f "$SCRATCH_SERVICE"

# Violation 9: strip `bind 127.0.0.1` from the egress Caddyfile. This is the
# one that shipped: without it Caddy binds the WILDCARD interface, and the
# three fixed upstreams become a relay to Bluesky's hosts that anyone on the
# internet can drive from this box's IP. Measured on the first real deploy —
# `curl http://<public-ip>:3128/` answered 200 until the directive was added.
SCRATCH_EGRESS_CADDY="$WORK/Caddyfile.egress"
grep -v '^	bind 127\.0\.0\.1$' "$EGRESS_CADDYFILE" >"$SCRATCH_EGRESS_CADDY"
if hits=$(check_directives "$SCRATCH_EGRESS_CADDY" "$EGRESS_CADDY_DIRECTIVES") \
  && [ -z "$hits" ]; then
  fail 'mutation control: a wildcard-bound egress listener was not caught'
fi
echo 'mutation control: a wildcard-bound egress listener correctly caught'
rm -f "$SCRATCH_EGRESS_CADDY"

# Violation 10: strip `admin off`. Caddy then claims 127.0.0.1:2019, which the
# inbound Caddy already holds, and this unit restart-loops on every start.
SCRATCH_EGRESS_CADDY="$WORK/Caddyfile.egress"
grep -v '^	admin off$' "$EGRESS_CADDYFILE" >"$SCRATCH_EGRESS_CADDY"
if hits=$(check_directives "$SCRATCH_EGRESS_CADDY" "$EGRESS_CADDY_DIRECTIVES") \
  && [ -z "$hits" ]; then
  fail 'mutation control: an egress config without `admin off` was not caught'
fi
echo 'mutation control: an egress config without `admin off` correctly caught'
rm -f "$SCRATCH_EGRESS_CADDY"

# Confirm the real tree is untouched and still green after every mutation.
service_hits=$(check_directives "$SERVICE" "$SERVICE_DIRECTIVES")
caddy_hits=$(check_directives "$CADDYFILE" "$CADDY_DIRECTIVES")
egress_service_hits=$(check_directives "$EGRESS_SERVICE" "$EGRESS_SERVICE_DIRECTIVES")
egress_service_forbidden=$(check_forbidden "$EGRESS_SERVICE" "$EGRESS_SERVICE_FORBIDDEN")
egress_caddy_hits=$(check_directives "$EGRESS_CADDYFILE" "$EGRESS_CADDY_DIRECTIVES")
egress_caddy_forbidden=$(check_forbidden "$EGRESS_CADDYFILE" "$EGRESS_CADDY_FORBIDDEN")
backup_hits=$(check_directives "$BACKUP_SERVICE" "$OUTBOUND_UNIT_DIRECTIVES")
healthping_timer_forbidden=$(check_forbidden "$HEALTHPING_TIMER" "$HEALTHPING_TIMER_FORBIDDEN")
healthping_hits=$(check_directives "$HEALTHPING_SERVICE" "$HEALTHPING_SERVICE_DIRECTIVES")
if [ -n "$service_hits" ] || [ -n "$caddy_hits" ] || [ -n "$egress_service_hits" ] \
  || [ -n "$egress_service_forbidden" ] \
  || [ -n "$egress_caddy_hits" ] || [ -n "$egress_caddy_forbidden" ] \
  || [ -n "$backup_hits" ] || [ -n "$healthping_timer_forbidden" ] \
  || [ -n "$healthping_hits" ]; then
  fail 'the real tree is no longer clean after the mutation control'
fi
echo 'real tree confirmed unaffected by the mutation control'
