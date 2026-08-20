# PDS-ORACLE.md — running the official Bluesky PDS locally as the Phase 0/1 oracle

**Status:** IMPLEMENTED — `S-oracle-standup`, #1707, 2026-08-17; re-cut to the official
container `fix-oracle-standup-docker` (`RUN-PDS0-024 C2`), 2026-08-17. Local manual procedure
for `ws:pds`. Not verified by CI (see below); Phase 0 uses it for spot cross-checks, Phase 1's
G3 (byte-identical MST root CIDs) and G4 (CAR vs `getRepo`) are entirely oracle-diff against
this server.

---

> **This is a local manual procedure, not a gate. No CI job provisions this oracle and none
> should.** Nothing in `test/` or `.github/workflows/ci.yml` runs it — `pds/oracle/run.sh` is
> ledgered in `test/CI-COVERAGE-TOOLS.txt` (key `pds/oracle/run`) as a tool, for exactly that
> reason: it needs network access, ~350 MB of disk, and produces no compiler-relevant
> pass/fail signal.

## Route A (primary) — the official container

This runs the **published `ghcr.io/bluesky-social/pds` image itself**, pulled **by digest**,
via `docker run`. No `installer.sh`, no Caddy, no TLS, no compose file, no host-Node
substitute — the exact bytes Bluesky ships.

## Route B (fallback) — the same payload under host Node, no Docker

**Use this route when Docker is unavailable**: macOS without Docker Desktop, a CI runner, or
a locked-down box. It installs and runs the image's own `service/` payload
(`index.ts`/`package.json`/`pnpm-lock.yaml`) directly under the host's Node — no container,
no isolation. The two routes serve byte-identical application code (see "Why Route B is a
faithful substitute" under the Route B provenance table below); Route B
exists only because Route A needs Docker and this dual-platform tree cannot assume it.

---

## What Route A runs, and what it does NOT reproduce

`docker run` starts the published image unmodified: `dumb-init` as PID 1, the bundled `goat`
CLI, the image's own Alpine/Node 24.18.1 base — everything the image ships. What is
deliberately **not** part of this oracle (by design, not by gap):

- **No Caddy / no TLS front end** — the container serves plain HTTP on `localhost`, published
  directly with `-p`. Upstream's own `installer.sh` route puts Caddy + a public TLS hostname
  in front of the same image; that whole-host, public-facing setup is out of scope for a local
  oracle and is never run here.
- **No Watchtower**, no systemd units, no host package installation — `installer.sh`'s
  side effects on the box are skipped entirely; only `docker run` against the pinned digest.
- **`PDS_DEV_MODE=true` is required** for a plain-HTTP `localhost` origin (see the Node table
  and Limitations).

### What Route B does NOT reproduce (kept from the landed procedure, still true there)

- **No container runtime, no isolation** — a plain OS process, not `runc`/containerd.
- **No `dumb-init`** (the image's PID-1 signal-forwarding entrypoint) — Node runs directly.
- **No bundled `goat`** (the image's Go admin-CLI binary) — not installed here.
- **No Caddy / no TLS front end** — plain HTTP on localhost, same as Route A.
- **`PDS_DEV_MODE=true` is required**, same reason as Route A.

### 🚨 The debugging trigger

**If a Phase 1 oracle-diff ever disagrees while you are on Route B, re-run it on Route A (the
container) before concluding the Medaka implementation is wrong.** Running under the host's
Node instead of the image's pinned Alpine/Node build is a real, if narrow, deviation (see the
Node table) — treat any unexplained divergence on Route B as "substitute vs. container" first,
"Medaka vs. spec" second. Route A has no such deviation: it *is* the container.

### Node versions, side by side

| | Node version | OS |
|---|---|---|
| **Route A (the container)** | `24.18.1` (from the image's own config: `NODE_VERSION=24.18.1`) | Alpine 3.23 |
| **Route B (host)** | record what `pds/oracle/run.sh node-provenance` printed for your run (measured 2026-08-17: `v24.18.0`) | Debian 13 |

This is the ONE deviation on Route B that could plausibly reach the protocol bytes — CBOR
encoding and JS number handling are Node-implemented, and the two Node builds differ at the
patch level. On Route A this table has no entry to worry about: the pinned digest carries its
own Node build.

## Pinned versions and digests

### Route A (the container) — provenance table (`RUN-PDS0-024` condition 2)

Every number below must be one **you observed in your own run**
(`pds/oracle/run.sh provenance`) — a divergence from this table is a finding to report, not a
number to edit.

| What | Value |
|---|---|
| Image reference | `ghcr.io/bluesky-social/pds` |
| **Pinned digest (the anchor — not the tag)** | `sha256:d95725b24dbe53af9d91dc69750556931ebed6c396f2cfa42b221434db642f12` |
| Why a digest and not the `0.4` tag | a tag is a mutable label — `docker pull ghcr.io/bluesky-social/pds:0.4` can resolve to different bytes on different days; an oracle whose whole job is to be a stable answer key cannot rest on a movable label. The digest names the exact bytes, permanently. |
| `org.opencontainers.image.revision` | `374cf1d4ba782d4391bbb73e4e2d3f320d4846d6` |
| `org.opencontainers.image.created` | `2026-08-11T21:13:19.141Z` |
| Container `NODE_VERSION` | `24.18.1` |
| `docker` server version observed | record your own (measured 2026-08-17: `26.1.5+dfsg1`) |
| Date observed | record your own (measured 2026-08-17) |

### Version-string disambiguation (`RUN-PDS0-024` condition 3)

Two different, correctly-different strings appear once you have the container running — do
not confuse them:

- **`0.4.5027`** — the **distro/image** version. This is `org.opencontainers.image.version`
  on the image, and it is exactly what `GET /xrpc/_health` returns.
- **`0.5.27`** — the **`@atproto/pds` npm package** version installed inside the image.

The first is *computed from* the second, in the image's own `service/index.ts`:

```js
// matches docker tag used in compose file, may deviate from @atproto/pds version.
const DISTRO_VER = '0.4'
env.version ||= ver(DISTRO_VER, pkg.version)   // ver('0.4','0.5.27') -> '0.4.5027'
```

Upstream's own comment warns the two "may deviate" — treat them as independent numbers that
happen to share a prefix, not as one version reported two ways.

### Route B (fallback) — provenance table (landed, unchanged)

| What | Value |
|---|---|
| `bluesky-social/pds` repo revision (content-pins the `service/` payload) | `374cf1d4ba782d4391bbb73e4e2d3f320d4846d6` |
| `service/index.ts` sha256 | `69ef8c1dfdca942fece327484c410c26c8c347e3303f9d1eb11e312c9946cc8a` |
| `service/package.json` sha256 | `c0e7740808e0d6bc26a9fd773162f780a45665b0cff2137a256157f3cff77fd5` |
| `service/pnpm-lock.yaml` sha256 | `23a8c97e01dff561266a6dcf67a4b74b25e98ebc695e6fa17c60ddf964160f73` |
| `@atproto/pds` (installed) | `0.5.27` |
| pnpm | `10.34.1` |
| Host `node --version` | record your own (measured 2026-08-17: `v24.18.0`) |

**Why Route B is a faithful substitute, not just a similar-looking one:** the container's own
`/app/index.ts`, `/app/package.json` and `/app/pnpm-lock.yaml` hash to **exactly these three
pinned digests** (measured directly from the image with `docker run --rm --entrypoint sha256sum`).
Route B installs and runs the identical three files, just outside the container.

## Prerequisites

**Route A (Docker):**
- Any recent Docker engine (measured on `26.1.5+dfsg1`).
- ~352 MB for the image, plus room for the SQLite data dir and blobstore under the oracle home.
- Network access for the first `pull` (subsequent runs use the local image cache).
- **No root beyond whatever running `docker` on your box already requires, no host changes.**

**Route B (no Docker):**
- Node ≥ 24, `corepack`, `curl`, `openssl`, network access to `raw.githubusercontent.com`.
- ~250 MB free disk for `node_modules`, plus room for the SQLite data dir and blobstore.
- **No Docker, no root, no changes to the box** beyond `$PDS_ORACLE_HOME`.

Both routes: the oracle home root is derived, not a fixed literal —
**`$PDS_ORACLE_HOME` if set in your environment, otherwise
`${TMPDIR:-/var/tmp}/medaka-pds-oracle`** — so on a box whose `TMPDIR` differs from this one,
the effective path differs from the literal example shown in this document too. `run.sh`
prints the effective path it used (`oracle home: <path>`) at the start of `up`/`node-setup`;
trust that line over any literal path quoted here. This matters because an independent run
of this document follows the document only (condition 4 below) — a literal-path mismatch is
expected behavior, not a failure to report.

## The procedure

All commands are run from the repo root.

### Route A (primary)

```sh
# 1. Pull the pinned image by digest and verify it landed under that exact digest.
sh pds/oracle/run.sh pull

# 2. Start the container (DETACHED — supervised by dockerd, not your shell). The first
#    `up` also generates pds.docker.env (mode 0600) from the sample; `up` REFUSES to start
#    if PDS_DID_PLC_URL is missing or empty in that file — see Limitations item 1.
sh pds/oracle/run.sh up

# 3. Probe it.
sh pds/oracle/run.sh check

# 4. See what you're actually running.
sh pds/oracle/run.sh provenance

# 5. Stop and remove the container. Nothing is left running after this.
sh pds/oracle/run.sh down
```

Expected `pull`/`verify` output (tail): `pds/oracle/run.sh: verified — ghcr.io/bluesky-social/pds@sha256:d95725b2... is present in the local image store`.

Expected `check` output:
```
pds/oracle/run.sh: GET http://localhost:3999/xrpc/_health
  -> 200 {"version":"0.4.5027"}
pds/oracle/run.sh: GET http://localhost:3999/xrpc/com.atproto.server.describeServer
  -> 200 {"did":"did:web:localhost","availableUserDomains":[".test"],...}
pds/oracle/run.sh: check OK
```

⚠️ A healthy container logs **nothing** to `docker logs` — do not use log output as a
readiness signal; `check`'s HTTP probe (with `curl --retry --retry-connrefused`) is the only
supported one. `docker logs` IS the right tool to diagnose a container that **failed** to
start (e.g. missing data/blobs directories — `up` creates them for you before `docker run`).

### Route B (fallback)

```sh
# 1. Fetch the pinned service/ payload, verify its sha256, then install deps.
sh pds/oracle/run.sh node-setup

# 2. Start the server in the FOREGROUND (own terminal/turn; generates pds.env, mode 0600,
#    with fresh secrets on first run). `node-up` REFUSES to start if PDS_DID_PLC_URL is
#    missing or empty in that file — see Limitations item 1.
sh pds/oracle/run.sh node-up

# 3. From a SEPARATE shell, probe it (same `check` as Route A):
sh pds/oracle/run.sh check
```

To see everything the tables above need from your own live install/pull:

```sh
sh pds/oracle/run.sh provenance          # Route A (offline, local image reads)
sh pds/oracle/run.sh node-provenance     # Route B (local install reads)
```

## Stopping and cleanup

- **Route A:** `sh pds/oracle/run.sh down` — removes the container. Nothing is left running.
- **Route B:** `node-up` runs in the foreground — `Ctrl-C` (or `kill` the `node` process)
  stops the server.
- Both routes: cleanup of the oracle home is a single
  `rm -rf "${PDS_ORACLE_HOME:-${TMPDIR:-/var/tmp}/medaka-pds-oracle}"` — deliberately outside
  the repo, so this procedure can never leave the tree dirty; there is nothing under version
  control to clean up and nothing to add to `.gitignore`. (`PDS_ORACLE_HOME` is set INSIDE
  `run.sh` and is not exported to your shell, so a literal `rm -rf "$PDS_ORACLE_HOME"` — with
  no default — expands to `rm -rf ""` and cleans nothing; use the form above.)

## Limitations

1. **Both samples now SET `PDS_DID_PLC_URL=http://127.0.0.1:9`** — a dead loopback sentinel,
   not left commented out. Account creation therefore fails, by construction:
   ```
   POST /xrpc/com.atproto.server.createAccount {"handle":"alice.test",...}
     -> 502 {"error":"UpstreamFailure","message":"Unable to perform PLC operation"}
   ```
   **If the variable is unset OR empty, `@atproto/pds` resolves `plcUrl` to the PRODUCTION
   `https://plc.directory` instead**, and `createAccount` performs a real, permanent, public,
   un-withdrawable `did:plc` WRITE there. That decision has EXTERNAL SIDE EFFECTS and is
   **Val's to make**, not this document's or any implementer's — which is why `run.sh up` /
   `node-up` now **REFUSE to start** unless `PDS_DID_PLC_URL` is set to a non-empty value in
   the env file: it is a required decision, not a default. A local PLC server is the
   alternative, and is Phase 1's problem, not this slice's (`RUN-PDS0-022 D2` — now a safety
   prerequisite there). Containerizing Route A does not change this.
2. **Route B is not the container.** No container runtime, no `dumb-init`, no bundled `goat`,
   no Caddy/TLS — see "What Route B does NOT reproduce" above. Its equivalence to the
   container rests on identical `service/` bytes, identical `@atproto/pds` version, and the
   matching `0.4.5027` version string — not on ever having run the container. Route A does
   not have this limitation: it *is* the container.
3. **The `0.4` image tag is mutable.** The pinned digest above is the real anchor; the tag
   appears in this document only as human-readable context for which release line it is, and
   nothing in `run.sh` pulls by it.
4. **Nothing here is verified by CI, ever** — see the banner at the top of this document.
5. **Not run on macOS/arm64.** The pinned digest is a multi-arch OCI index (it has both amd64
   and arm64 manifests), so it is expected to work there, but nobody has executed either route
   on that platform as part of this slice.

## Provenance / G5 note

This oracle is a **tool**, not a vector corpus. Nothing it produces may be committed as a
golden without a `pds/test/VECTOR-PROVENANCE.txt` row under the sprint's provenance policy —
a self-captured golden from a locally-run oracle is exactly what G5 forbids for values that
have a published answer key.

## See also

- `pds/README.md` — points here; do not duplicate this document there.
- `test/CI-COVERAGE-TOOLS.txt` — the `pds/oracle/run` classification row.
- `pds/oracle/run.sh` / `pds/oracle/pds.docker.env.sample` (Route A) /
  `pds/oracle/pds.env.sample` (Route B) — the procedure itself.
