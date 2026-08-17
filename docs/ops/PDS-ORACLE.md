# PDS-ORACLE.md — running the official Bluesky PDS locally as the Phase 0/1 oracle

**Status:** IMPLEMENTED — `S-oracle-standup`, #1707, 2026-08-17. Local manual procedure for
`ws:pds`. Not verified by CI (see below); Phase 0 uses it for spot cross-checks, Phase 1's
G3 (byte-identical MST root CIDs) and G4 (CAR vs `getRepo`) are entirely oracle-diff against
this server.

---

> **This is a local manual procedure, not a gate. No CI job provisions this oracle and none
> should.** Nothing in `test/` or `.github/workflows/ci.yml` runs it — `pds/oracle/run.sh` is
> ledgered in `test/CI-COVERAGE-TOOLS.txt` (key `pds/oracle/run`) as a tool, for exactly that
> reason: it needs network access, ~250 MB of disk, and produces no compiler-relevant
> pass/fail signal.

## What this runs, and how it differs from the container

The official Bluesky PDS is normally stood up via `curl -sSL
https://raw.githubusercontent.com/bluesky-social/pds/main/compose.yaml` and a Docker-based
`installer.sh` that `apt-get install`s `docker-ce`, writes `/pds`, installs systemd units, and
stands up Caddy + Watchtower against a **public hostname with TLS**. **This box has no
container runtime at all** (`docker` is absent from `PATH`, from the three standard install
locations, and from `dpkg`'s package DB — see `pds/oracle/run.sh provenance` for what this
run observed), and the installer route is a whole-host installer that is out of scope for any
implementer to run unilaterally against a dev box.

**What this document runs instead: the image's own service code, directly under the host's
Node.** The `ghcr.io/bluesky-social/pds:0.4` image's entire application payload is a 3-file
`service/` directory (`index.ts`, `package.json`, `pnpm-lock.yaml`) from the
`bluesky-social/pds` repo, installed with `pnpm install --production --frozen-lockfile` and
started with `node --enable-source-maps index.ts`. That is exactly what the image's own
`Dockerfile` does (`FROM node:24.18-alpine3.23`, `COPY ./service ./`, `pnpm install
--production --frozen-lockfile`); this procedure reproduces it outside a container. The
running server self-identifies as the same distro build: `GET /xrpc/_health` returns
`{"version":"0.4.5027"}`, byte-identical to the image's own
`org.opencontainers.image.version` label — that string is computed by `service/index.ts`'s
`ver()` from a `DISTRO_VER='0.4'` constant plus the installed `@atproto/pds` package version,
so matching it is real evidence of running the same distro build, not a coincidence.

**What is NOT reproduced, stated explicitly** (this is the honest-labeling requirement — see
also the Limitations section):
- **No container runtime, no isolation** — this is a plain OS process, not `runc`/containerd.
- **No `dumb-init`** (the image's PID-1 signal-forwarding entrypoint) — Node runs directly.
- **No bundled `goat`** (the image's Go admin-CLI binary) — not installed here.
- **No Caddy / no TLS front end** — this serves plain HTTP on localhost.
- **`PDS_DEV_MODE=true` is required** for a plain-HTTP `localhost` origin (see Node version
  table and Limitations for why this is the one deviation worth tracking).

### 🚨 The debugging trigger

**If a Phase 1 oracle-diff EVER disagrees with this substitute, the CONTAINER ROUTE is the
FIRST thing to try before concluding the Medaka implementation is wrong.** Running under the
host's Node instead of the image's pinned Alpine/Node build is a real, if narrow, deviation
(see the Node version table immediately below) — treat any unexplained divergence as
"substitute vs. container" first, "Medaka vs. spec" second.

### Node versions, side by side

| | Node version | OS |
|---|---|---|
| **This procedure (host)** | record what `pds/oracle/run.sh provenance` printed for your run (measured on 2026-08-17: `v24.18.0`) | Debian 13 |
| **The container's pinned Node** | `24.18.1` (from the image's `Dockerfile`/config: `NODE_VERSION=24.18.1`, `FROM node:24.18-alpine3.23`) | Alpine 3.23 |

This is the ONE deviation that could plausibly reach the protocol bytes — CBOR encoding and
JS number handling are Node-implemented, and the two Node builds differ at the patch level.
Documented explicitly, not folded into the general deviation list above, so a future reader
sees it without hunting.

## Pinned versions and digests

Everything below must be a number **you observed in your own run** (`pds/oracle/run.sh
provenance`) — do not transcribe this table unverified; a divergence from it is a finding to
report, not a number to silently correct.

| What | Value |
|---|---|
| `bluesky-social/pds` repo revision (content-pins the `service/` payload) | `374cf1d4ba782d4391bbb73e4e2d3f320d4846d6` |
| `service/index.ts` sha256 | `69ef8c1dfdca942fece327484c410c26c8c347e3303f9d1eb11e312c9946cc8a` |
| `service/package.json` sha256 | `c0e7740808e0d6bc26a9fd773162f780a45665b0cff2137a256157f3cff77fd5` |
| `service/pnpm-lock.yaml` sha256 | `23a8c97e01dff561266a6dcf67a4b74b25e98ebc695e6fa17c60ddf964160f73` |
| `@atproto/pds` (installed) | `0.5.27` |
| pnpm | `10.34.1` |
| Host `node --version` | record your own (measured 2026-08-17: `v24.18.0`) |
| `ghcr.io/bluesky-social/pds:0.4` index digest | resolved live by `pds/oracle/run.sh provenance` (measured 2026-08-17: `sha256:d95725b24dbe53af9d91dc69750556931ebed6c396f2cfa42b221434db642f12`) — **⚠️ `0.4` is a MUTABLE tag; this is what it resolved to on the stated date, not a permanent pin.** The real anchor is the repo revision above. |

## Prerequisites

- Node ≥ 24, `corepack`, `curl`, `openssl`, network access to `raw.githubusercontent.com` and
  (for `provenance`'s live-digest check only) `ghcr.io`.
- ~250 MB free disk for `node_modules`, plus room for the SQLite data dir and blobstore.
- **NO Docker. NO root. NO changes to the box** — this procedure writes only inside
  `$PDS_ORACLE_HOME` (default `${TMPDIR:-/var/tmp}/medaka-pds-oracle`), never inside the repo,
  never system-wide.

## The procedure

All commands are run from the repo root.

```sh
# 1. Fetch the pinned service/ payload, verify its sha256 against the digests above, then
#    install dependencies (pnpm, production, frozen-lockfile).
sh pds/oracle/run.sh setup

# 2. Start the server in the FOREGROUND (it is a long-running process — run it in its own
#    terminal/turn; generates $PDS_ORACLE_HOME/pds.env with fresh secrets on first run).
sh pds/oracle/run.sh up

# 3. From a SEPARATE shell, probe it:
sh pds/oracle/run.sh check
```

Expected `setup` output (tail): `pds/oracle/run.sh: setup complete`.

Expected `up` output (tail, before it blocks serving):
```
pds/oracle/run.sh: starting PDS on port 3999 (data dir: .../data)
```

Expected `check` output:
```
pds/oracle/run.sh: GET http://localhost:3999/xrpc/_health
  -> 200 {"version":"0.4.5027"}
pds/oracle/run.sh: GET http://localhost:3999/xrpc/com.atproto.server.describeServer
  -> 200 {"did":"did:web:localhost","availableUserDomains":[".test"],...}
pds/oracle/run.sh: check OK
```

To see everything the doc's table above needs from your own live install:

```sh
sh pds/oracle/run.sh provenance
```

## Stopping and cleanup

`up` runs in the foreground — `Ctrl-C` (or `kill` the `node` process) stops the server.
Cleanup is a single `rm -rf "$PDS_ORACLE_HOME"` (default
`${TMPDIR:-/var/tmp}/medaka-pds-oracle`) — the oracle home is **deliberately outside the
repo** so this procedure can never leave the tree dirty; there is nothing under version
control to clean up and nothing to add to `.gitignore`.

## Limitations

1. **Account creation needs a reachable PLC directory.** Without one,
   `com.atproto.server.createAccount` fails:
   ```
   POST /xrpc/com.atproto.server.createAccount {"handle":"alice.test",...}
     -> 502 {"error":"UpstreamFailure","message":"Unable to perform PLC operation"}
   ```
   The public `https://plc.directory` would satisfy this, but pointing at it publishes a
   real `did:plc` to a real network — that decision has EXTERNAL SIDE EFFECTS and is **Val's
   to make**, not this document's or any implementer's. A local PLC server is the alternative,
   and is Phase 1's problem, not this slice's.
2. **This is not the container image.** No container runtime, no `dumb-init`, no bundled
   `goat`, no Caddy/TLS — see "What this runs" above. Equivalence rests on identical
   `service/` bytes, identical `@atproto/pds` version, and the matching `0.4.5027` version
   string — not on ever having run the container itself (this box has no runtime to run it
   with).
3. **The `0.4` image tag is mutable.** The pinned repo revision
   (`374cf1d4ba782d4391bbb73e4e2d3f320d4846d6`) is the real anchor; the resolved ghcr digest
   is only evidence of what the tag pointed to on the date it was checked.
4. **Nothing here is verified by CI, ever** — see the banner at the top of this document.

## Provenance / G5 note

This oracle is a **tool**, not a vector corpus. Nothing it produces may be committed as a
golden without a `pds/test/VECTOR-PROVENANCE.txt` row under the sprint's provenance policy —
a self-captured golden from a locally-run oracle is exactly what G5 forbids for values that
have a published answer key.

## See also

- `pds/README.md` — points here; do not duplicate this document there.
- `test/CI-COVERAGE-TOOLS.txt` — the `pds/oracle/run` classification row.
- `pds/oracle/run.sh` / `pds/oracle/pds.env.sample` — the procedure itself.
