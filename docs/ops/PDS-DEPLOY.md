# PDS-DEPLOY.md — deploying `pds serve` behind Caddy under systemd

**Status:** IMPLEMENTED, not yet DEPLOYED. The bind, the refusal, and the
artifacts below are landed (`#2606`, `#2757`, sprint `pds-leaves-loopback`),
but no live deploy has happened — pointing a real domain at a real key is a
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

1. **Build the binary.**

   ```sh
   ./medaka build pds/serve.mdk -o pdsd
   ```

2. **Generate the secrets, with `pds keygen`** (`shell/keygen.mdk`) — not by
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

3. **Write the account password to a file, never an argument** — an
   argument is visible in `ps` output to every account on the box:

   ```sh
   umask 077 && printf '%s\n' 'the account password' > secrets/password
   ```

4. **Genesis run**, on the loopback default, to create the repository and
   bootstrap the credential (`--init`, `--password-file`):

   ```sh
   ./pdsd --did <did> --handle <handle> --hostname <hostname> \
     --key secrets/key.hex --token-secret secrets/token.hex \
     --password-file secrets/password --data data --port 8080 --init
   ```

   Stop it once it reports readiness (`serve: listening on 127.0.0.1:8080`).
   Every subsequent run omits `--init` and `--password-file`: the data
   directory now holds both the repository and the credential.

5. **Install the systemd unit** (`pds/pds.service`) — copy it to
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

6. **Install the Caddyfile** (`pds/Caddyfile`) — replace `pds.example.com`
   with the real hostname (the same one `--hostname` above names) and the
   port with the one `--port` bound, then reload Caddy. Caddy obtains and
   renews the certificate on its own (P5).

7. **Verify against the live origin, never an exit code**
   (`[WEB-PREVIEW-SILENT]`, `AGENTS.md`):

   ```sh
   curl -sS https://<hostname>/.well-known/atproto-did
   curl -sS https://<hostname>/xrpc/com.atproto.server.describeServer
   ```

## Appview proxying (optional, off by default)

A client can ask this PDS to forward a read to an appview by sending an
`atproto-proxy` header. **Nothing is ever forwarded unless both flags below
are given** — with neither, such a header is refused `400 InvalidRequest` and
no credential is minted.

```
--appview-did  did:web:api.bsky.app      # the ONE service a header may name
--egress-port  3128                      # loopback port of the egress proxy
```

Each requires the other; giving one alone is refused before the bind, naming
this file. `--appview-did` must be a **bare** DID with no `#service`
fragment — a header may name a service OF it (`did:web:api.bsky.app#bsky_appview`)
and the fragment is stripped from the credential's `aud`, because a peer checks
`aud` against its own DID.

Two operator-visible consequences:

- **The outbound call is a plain loopback HTTP connection to
  `127.0.0.1:<egress-port>`.** This process never dials the internet itself
  and does no TLS outbound; reaching the real appview is the egress proxy's
  job, exactly as reaching the internet inbound is Caddy's. The unit can
  therefore keep egress confined to that one port.
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
- **`#2608` (firehose, Phase 5)** — out of scope; this PDS does not publish
  `com.atproto.sync.subscribeRepos`.
- **`#1962` (signing-parity oracle is nightly-only)** — confirm that nightly
  job is green immediately before a real deploy; this procedure does not
  re-run it.
