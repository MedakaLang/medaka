# PDS-DEPLOY.md — deploying `pds serve` behind Caddy under systemd

**Status:** IMPLEMENTED, not yet DEPLOYED. The bind, the refusal, and the
artifacts below are landed (`#2606`, `#2757`, sprint `pds-leaves-loopback`),
and sprint `pds-it-runs-on-the-box` (#2960, #2965, #2964, #2958, #2959, #2970)
landed build provenance (`--stamp-build`, `--version`), a health probe
(`GET /xrpc/_health`), one access-log line per request, and a hardened
`pds.service`/`Caddyfile` linted by their own gate — see "Versioned releases
and rollback" and "Observability: version, health, and the access log" below.
But no live deploy has happened — pointing a real domain at a real key is a
manual, deliberate act for whoever runs this procedure, and this document
describes how, not a completed deployment.

---

## What this deploys

`pds serve` (`pds/serve.mdk`) binds **loopback only by default** — `--bind`
defaults to `127.0.0.1`, and a non-loopback bind is refused before anything
is read or written unless `--trusted-proxy` is also given
(`requireTrustedBind`, `docs/design/ATPROTO-PDS-DESIGN.md` § "Loopback by
default"). This deployment keeps the default: `pds serve` binds loopback,
and Caddy (`pds/Caddyfile`) is the only thing that terminates TLS and is
reachable from the public internet, reverse-proxying to the loopback port.

**A direct, unproxied non-loopback bind is unsupported** (`#2757`): this
process cannot verify that its peer really is a reverse proxy — there is no
`getpeername`-equivalent in the runtime — so `--trusted-proxy` is an
operator assertion about the deployment, not a checked fact. This procedure
never sets it against anything but Caddy on the same box.

## Procedure

1. **Create the service user.** `pds/pds.service` runs as `User=pds`/
   `Group=pds`, and a unit file cannot create that account itself:

   ```sh
   useradd --system --no-create-home --shell /usr/sbin/nologin pds
   ```

   (Or the `systemd-sysusers` equivalent, if the box already manages system
   accounts that way.) Do this once, before the first `systemctl enable
   --now pds`.

2. **Build the binary.** For a one-off run, a plain build is enough; for a
   running deployment, use the versioned-path layout in "Versioned releases
   and rollback" below instead so a bad build is one command from reverting.

   ```sh
   ./medaka build pds/serve.mdk -o pdsd
   ```

3. **Generate the secrets, with `pds keygen`** (`shell/keygen.mdk`) — not by
   hand and not with `chmod`-and-hope. It writes both files at mode `0600`
   and prints the `did:key` the signing key corresponds to:

   ```sh
   ./pdsd keygen --key secrets/key.hex --token-secret secrets/token.hex
   ```

   The printed `did:key` names the signing key itself; it is not the
   account DID this deployment serves. `did:web` is the identity method
   this tree implements (P2, `docs/design/ATPROTO-PDS-DESIGN.md`) — the
   account's `--did` is `did:web:<hostname>` (percent-encoded per the
   spec if the hostname carries a port), and `--hostname` is what serves
   `/.well-known/did.json` for it.

4. **Write the account password to a file, never an argument** — an
   argument is visible in `ps` output to every account on the box:

   ```sh
   umask 077 && printf '%s\n' 'the account password' > secrets/password
   ```

5. **Genesis run**, on the loopback default, to create the repository and
   bootstrap the credential (`--init`, `--password-file`):

   ```sh
   ./pdsd --did <did> --handle <handle> --hostname <hostname> \
     --key secrets/key.hex --token-secret secrets/token.hex \
     --password-file secrets/password --data data --port 8080 --init
   ```

   Stop it once it reports readiness (`serve: listening on 127.0.0.1:8080`).
   Every subsequent run omits `--init` and `--password-file`: the data
   directory now holds both the repository and the credential.

6. **Install the systemd unit** (`pds/pds.service`) — copy it to
   `/etc/systemd/system/pds.service`, replace its placeholders (paths,
   `--did`/`--handle`/`--hostname`, the service user), then:

   ```sh
   systemctl daemon-reload && systemctl enable --now pds
   ```

   The template passes `--trusted-proxy` deliberately: Caddy, on the same
   box, forwards `X-Forwarded-For`, and per-identity rate limiting
   (`docs/design/ATPROTO-PDS-DESIGN.md` § "Rate limiting") needs that header
   to tell callers apart. The bind stays loopback, so this is not the
   `#2757` refusal's non-loopback case — it is the operator's own choice to
   make the per-identity limiter meaningful in front of a reverse proxy that
   really is Caddy.

7. **Install the Caddyfile** (`pds/Caddyfile`) — replace `pds.example.com`
   with the real hostname (the same one `--hostname` above names) and the
   port with the one `--port` bound, then reload Caddy. Caddy obtains and
   renews the certificate on its own (P5).

8. **Verify against the live origin, never an exit code**
   (`[WEB-PREVIEW-SILENT]`, `AGENTS.md`):

   ```sh
   curl -sS https://<hostname>/.well-known/atproto-did
   curl -sS https://<hostname>/xrpc/com.atproto.server.describeServer
   ```

## Versioned releases and rollback

Step 2 above (`./medaka build pds/serve.mdk -o pdsd`) produces one binary.
For a running deployment, keep each build under its own stamped path instead
of overwriting the previous one in place, so a bad release is one command
away from reverting:

```sh
STAMP=$(git rev-parse --short=9 HEAD)
./medaka build pds/serve.mdk -o /opt/pds/releases/$STAMP/pdsd --stamp-build
ln -sfn /opt/pds/releases/$STAMP /opt/pds/current
```

Point `pds.service`'s `ExecStart` at `/opt/pds/current/pdsd` rather than at a
stamp-specific path, so promoting or rolling back a release never edits the
unit file. `--stamp-build` bakes the commit into the binary
(`compiler/driver/build_cmd.mdk`, #2960), so `pdsd --version` on the running
binary and `readlink /opt/pds/current` should always name the same commit —
a mismatch means the symlink was moved without a restart.

**Rollback**, once a known-good stamp exists under `/opt/pds/releases/`:

```sh
ln -sfn /opt/pds/releases/<previous-stamp> /opt/pds/current
systemctl restart pds
```

One command repoints the symlink; the restart is what makes systemd re-exec
against it. Nothing under `/opt/pds/releases/` needs deleting to roll back —
old stamps stay on disk as the rollback targets until an operator prunes them.

## Observability: version, health, and the access log

Three things this server now reports on its own, none of them requiring a
live deploy to exercise:

- **`pdsd --version`** prints `pdsd 0.1.0 (<commit>, built <date>)` when built
  with `--stamp-build` as above, degrading field-by-field (bare `pdsd 0.1.0`)
  when the flag was omitted. The same startup line the process logs on boot
  (`serve: config did=… …`) is followed by `serve: event log recovery: …`,
  naming what recovery did to the on-disk firehose log at startup.
- **`GET /xrpc/_health`** is a public, unauthenticated, cheaply-rate-limited
  route outside the NSID registry (`healthPath`, `pds/lib/xrpc.mdk`) that
  answers with the same version stamp `--version` reports. Use it as the
  systemd/Caddy liveness check:

  ```sh
  curl -sS http://127.0.0.1:8080/xrpc/_health
  ```
- **The access log** is one `serve: access …` line per request — successes
  and refusals alike — naming method, path (query string dropped), status,
  response size, duration, and client, all field-length-capped
  (`accessLogLine`, `pds/lib/accesslog.mdk`). It goes to the same stream as
  the startup banner, so under the systemd unit both land in the journal:

  ```sh
  journalctl -u pds -f
  ```

## Sharing the box

`pds.service` (`pds/pds.service`) sets `CPUWeight=20` — a fifth of the
systemd default of 100 — precisely so this rule has teeth: under
contention, the kernel's CPU controller starves `pds.service` in favor of
anything running at the default weight before it starves that other work,
rather than the two competing as equals.

**Do not run `make preflight`, a full gate suite (`make gates`), or an
oracle build (`test/build_oracles.sh`) on the same box while `pds.service`
is active, without first lowering that work's own priority to below the
service's** (`nice`/`ionice`, or a cgroup slice with a `CPUWeight` above
20 so the comparison still favors the service):

```sh
nice -n 15 sh test/run_gates.sh 'pattern*'
```

`CPUWeight` only arbitrates CPU time under contention — it does not cap
memory or I/O — so a `make medaka` cold bootstrap or a `build_oracles.sh`
run can still starve `pds.service` on memory or disk bandwidth even at a
lower CPU weight. Prefer running such work on a different box, or during a
maintenance window, when the deploy is not merely "sharing a core" but
sharing all of it.

## Appview proxying (optional, off by default)

A client can ask this PDS to forward a read to an appview by sending an
`atproto-proxy` header. **Nothing is ever forwarded unless both flags below
are given** — with neither, such a header is refused `400 InvalidRequest` and
no credential is minted.

```
--appview-did  did:web:api.bsky.app      # the DEFAULT service, used when no
                                         #   atproto-proxy header is sent
--egress-port  3128                      # loopback port of its egress proxy
```

Each requires the other; giving one alone is refused before the bind, naming
this file. `--appview-did` must be a **bare** DID with no `#service`
fragment — a header may name a service OF it (`did:web:api.bsky.app#bsky_appview`)
and the fragment is stripped from the credential's `aud`, because a peer checks
`aud` against its own DID.

### More than one service

A header may name any service in a configured **set**, and each one gets its
own egress port. Additional services are configured a row at a time with a
repeatable flag; the pair above is always the first row, and the first row is
the default the header-absent reads go to.

```
--proxy-audience  did:web:api.bsky.chat=3130    # repeat for each further service
```

Which DIDs belong in the set is entirely yours: this server knows no service
name of its own, so a deployment that wants Bluesky's chat service reachable
puts `did:web:api.bsky.chat` in the set, and one that wants something else
puts that instead. Each row takes the same **bare** DID as `--appview-did`,
and a header naming a service OF a configured DID still has its fragment
stripped from `aud`.

Three refusals, all before the bind:

- a row missing either half (`--proxy-audience did:web:api.bsky.chat`, or
  `--proxy-audience =3130`) — the same all-or-none rule `--appview-did` and
  `--egress-port` already answer to;
- `--proxy-audience` with no `--appview-did`/`--egress-port` pair: a
  header-absent read has to go somewhere, and which of your services receives
  it is not this program's choice to make;
- the same DID twice. Two ports for one DID are two upstreams a credential
  minted for that DID could reach, and picking between them is exactly the
  routing choice this server refuses to guess at.

**Each row needs its own egress proxy**, on the port that row names — one
more `reverse_proxy`-equivalent hop beside the one `--egress-port` already
needs, forwarding `127.0.0.1:3130` to the real chat service. A header naming a
DID in no row is still refused `400 InvalidRequest` with no credential minted,
exactly as it is with a single service configured.

Two operator-visible consequences:

- **The outbound call is a plain loopback HTTP connection to
  `127.0.0.1:<port of the service the header named>`.** This process never
  dials the internet itself and does no TLS outbound; reaching the real
  service is the egress proxy's job, exactly as reaching the internet inbound
  is Caddy's. The unit can therefore keep egress confined to the configured
  ports.
- **A forwarded read is metered as its own rate-limit class**
  (`maxProxiedCallsPerWindow`, `docs/design/ATPROTO-PDS-DESIGN.md` § "Rate
  limiting"), because one inbound request becomes one outbound request. The
  shared request allowance does not bound it.

Which methods a header may name is not configurable: it is derived from the
official PDS's own route registration and is **default-deny** — see
`docs/design/ATPROTO-PDS-DESIGN.md` § 4.5, "What a header is allowed to ask
for". A method this server answers itself is answered, not forwarded, even
when a header asks for it.

## Discovery: announcing to a relay (optional, off by default)

`com.atproto.sync.listRepos` and `com.atproto.sync.getRepoStatus` are pure
reads this PDS always serves, so a relay that already knows about this server
can find and check on its one hosted repository with no configuration at all.
`--relay-port` covers the other half: telling a relay that has **never**
heard of this server that it exists.

```
--relay-port  3129    # loopback port of a reverse proxy fronting the relay
```

With the flag given, this server sends one `com.atproto.sync.requestCrawl`
call — `{"hostname": "<this server's --hostname>"}`, **no authorization
header** — to `127.0.0.1:<relay-port>` once at startup. As with
`--egress-port` above, this process never dials the internet itself; reaching
the real relay is the reverse proxy's job. The call is best-effort: a relay
that refuses the connection, times out, or answers with an error is logged to
stderr and otherwise ignored — it neither blocks startup nor prevents this
server from answering any other request.

## Backup and restore

**Consistency, in one sentence:** take a file-level backup with the server
**stopped** (or from an atomic filesystem/volume snapshot), because
`applyRequest`'s write serialization (`pds/shell/server.mdk`) is a single
`liftIO` inside one cooperatively scheduled process and not a lock an external
`cp` can take, so a copy made while the server is running can capture a torn
write; the online alternative, if you cannot stop it, is to snapshot the
repository through the server's own request path — `com.atproto.sync.getRepo`,
which IS serialized against writes — rather than by copying files.

What has to be in a backup, and why `getRepo` alone is not one: the repository
blocks (`<data>/blocks`), the blobs (`<data>/blobs` — not in the CAR; a blob is
not part of the signed block graph), the head pointer (`<data>/head`), the
account credential (`<data>/credential`), the session-token secret (whichever of
`--token-secret` or `<data>/session-secret` this deployment uses), and **the
signing key** (`--key`). Losing the signing key loses the ability to sign any
future commit for this DID; it is the one file no later work can reconstruct.

**Backup.**

```sh
systemctl stop pds
tar -cpf /backup/pds-$(date +%Y%m%dT%H%M%S).tar -C /srv/pds data secrets
systemctl start pds
```

`tar -p` (and `cp -a`, if you copy rather than archive) preserves the `0600`
modes. That matters: `pds serve` refuses to start on a hex secret file any
other account can read (see the upgrade note below), so a backup that widened
one restores into a server that will not start.

For an online snapshot of the repository half, with the server running — a
consistent CAR, and the portable format `#2613` names:

```sh
curl -sS "http://127.0.0.1:8080/xrpc/com.atproto.sync.getRepo?did=<did>" \
  > /backup/repo-$(date +%Y%m%dT%H%M%S).car
```

**Restore.** Restore into a directory of its own, never over a live one, and
bring the secrets back with it:

```sh
systemctl stop pds
mkdir -p /srv/pds-restored
tar -xpf /backup/pds-<stamp>.tar -C /srv/pds-restored
chmod 0600 /srv/pds-restored/secrets/key.hex \
  /srv/pds-restored/secrets/token.hex /srv/pds-restored/data/credential
```

Then start `pds serve` against the restored paths (`--data`, `--key`,
`--token-secret`) **without `--init`** — the restored directory already holds a
repository, and a second genesis against one is refused (`#2481`). Verify the
restore rather than assuming it:

```sh
curl -sS "http://127.0.0.1:<port>/xrpc/com.atproto.sync.getRepo?did=<did>" \
  | cmp - /backup/repo-<stamp>.car       # identical bytes, or the restore is wrong
curl -sS -D - -o /dev/null "http://127.0.0.1:<port>/xrpc/com.atproto.sync.getBlob?did=<did>&cid=<a known blob CID>"
```

This procedure is rehearsed by a gate, not only written down: case 33 of
`pds/test/serve_e2e.sh` takes a backup of a stopped server, restores it into a
separate `--data` directory, starts a server on the restored copy, and requires
that server's `getRepo` export to byte-match the original's, both blobs to come
back under their declared media types, and a new signed write to be accepted.

## Upgrade note: pre-existing secrets at a wider mode

A secret file written before the KDF-and-keygen slice (`#2659`'s
`readHexBytes` hardening) may be world- or group-readable. `pds serve` now
refuses to start on any hex secret file (`--key`, `--token-secret`) wider
than `0600`, and on `<data>/session-secret` the same way. The remedy is
`chmod 0600 <path>` — or regeneration, since a secret that was ever
world-readable is a leaked secret, not merely a permission bug.

## What this procedure does not cover, and why

- **`#2572` (the block store never collects unreferenced blocks, and a stray
  non-directory file under the store directory hard-fails startup —
  `blockFileRead`, `pds/shell/blockfile.mdk`)** — an open issue, not a
  deploy-blocking one for a single-operator server. The same residue under
  `<data>/blobs` is skipped rather than fatal (`pds/test/serve_e2e.sh` cases
  15-18); the block half still refuses.
- **`#2773`/`#2774` (perf)** — open, tracked separately.
- **`#2608` (firehose, Phase 5)** — landed (sprint `pds-a-relay-can-index-us`):
  `com.atproto.sync.subscribeRepos` is a real event stream, backed by the
  bounded on-disk event log (P12). Nothing further for this procedure to do
  beyond what "Discovery: announcing to a relay" above already covers.
- **`#1962` (signing-parity oracle is nightly-only)** — confirm that nightly
  job is green immediately before a real deploy; this procedure does not
  re-run it.
