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

## Upgrade note: pre-existing secrets at a wider mode

A secret file written before the KDF-and-keygen slice (`#2659`'s
`readHexBytes` hardening) may be world- or group-readable. `pds serve` now
refuses to start on any hex secret file (`--key`, `--token-secret`) wider
than `0600`, and on `<data>/session-secret` the same way. The remedy is
`chmod 0600 <path>` — or regeneration, since a secret that was ever
world-readable is a leaked secret, not merely a permission bug.

## What this procedure does not cover, and why

- **`#2613` (backup/restore)** — Phase 6 scope, not this slice's. Nothing
  here backs up `--data`.
- **`#2572` (a blocking operation can occupy the scheduler past its
  budget)** — an open perf/correctness issue, not a deploy-blocking one for
  a single-operator server.
- **`#2773`/`#2774` (perf)** — open, tracked separately.
- **`#2608` (firehose, Phase 5)** — out of scope; this PDS does not publish
  `com.atproto.sync.subscribeRepos`.
- **`#1962` (signing-parity oracle is nightly-only)** — confirm that nightly
  job is green immediately before a real deploy; this procedure does not
  re-run it.
