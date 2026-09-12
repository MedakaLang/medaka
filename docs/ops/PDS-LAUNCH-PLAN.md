# PDS-LAUNCH-PLAN.md — the road to "this account runs on a PDS written in Medaka"

**Status:** OPEN — live launch hub for the atproto PDS (`ws:pds`, tracker #1697).
Cut 2026-09-12 from five first-hand surveys of the tree; every criterion below
names the launch gate it blocks and the issue that tracks it. The phase table
and the public-exposure ledger stay on #1697; this document is the release
plan on top of them.

> **What this is.** Val wants to post, from her own account, "this account is
> running on a PDS written entirely in Medaka." This document says what has to
> be true before that post is honest and safe, in checkable terms, and in what
> order. It is the sibling of [`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md)
> for the PDS: the language release and the PDS launch are separate moments
> with separate bars.

Companion docs: [`ATPROTO-PDS-DESIGN.md`](../design/ATPROTO-PDS-DESIGN.md)
(decisions P1–P16, the pure/shell seam, the proxy disposition rationale),
[`PDS-DEPLOY.md`](./PDS-DEPLOY.md) (the deploy procedure),
[`ATPROTO-PDS-SIGNING-CONTRACT.md`](../design/ATPROTO-PDS-SIGNING-CONTRACT.md)
(oracle pins), [`pds/README.md`](../../pds/README.md) (what the tree serves today).

---

## 0. The four decisions this plan rests on (Val, 2026-09-12)

| # | Decision | Consequence |
|---|---|---|
| **L1** | **Two identities, in order: a fresh `did:web` account first, the real `did:plc` account migrated later.** | The irreversible step (a PLC operation) is the LAST gate, taken on evidence from a live instance. The fresh account is not a rehearsal, it is used for real during the soak. |
| **L2** | **The official Bluesky app is the client bar. OAuth (#2610) is post-launch.** | Password login via `createSession` is the auth surface signed off. Third-party clients that need OAuth are a later milestone, not a footnote in this one. |
| **L3** | **It runs on the dev box, isolated.** | A dedicated service user, systemd resource weights and sandboxing, and a written rule for what gate/agent work may run beside a live service. The box also runs the compiler's CI-like gates; contention is a named risk, not an accident. |
| **L4** | **Quiet go-live, then announce.** | A period with only Val and friends knowing the handle, so the first bugs are found by friendly traffic. The announcement is its own gate and carries the hostile-poke bar: strangers will probe the server the day it is posted. |

## 1. Three gates, not one launch

| Gate | Statement that must be true | Bar |
|---|---|---|
| **G-QUIET** — quiet go-live | The fresh `did:web` account is live on this box behind Caddy, usable daily from the official app (post, image, follow, reply, notifications, DMs), indexed by the relay, visible on the appview. Nobody but Val and friends knows the handle. | Works end to end. Nothing on fire. Every S0/S1 in the request path either fixed or explicitly accepted with a date. |
| **G-ANNOUNCE** — public announcement | The soak on G-QUIET has run its stated duration with the observability in place to have seen a problem. Security sign-off is written. The claim in the post is footnoted honestly (§6). | Hostile-poke: a stranger who reads the post and tries to break the server within the hour finds a bounded, logged, recoverable failure or nothing at all. |
| **G-MIGRATE** — the real account | The announced instance has held up. The migration surface exists and has been rehearsed twice against an isolated PLC with a rehearsed rollback. Rotation-key custody is off-box. | The one irreversible step, taken last, with the way back rehearsed before the way forward is taken. |

The soak duration between G-QUIET and G-ANNOUNCE, and between G-ANNOUNCE and
G-MIGRATE, is a number Val sets when each earlier gate closes, not a number
this document guesses now. The plan's only rule is that a soak is counted from
the last S0/S1 fix deployed, not from first boot.

## 2. Acceptance criteria

Every row: an ID, the criterion (checkable, not a vibe), the gate it blocks,
the state of the tree on 2026-09-12, and the tracking issue. "exists" means a
gate or rehearsal already proves it; "partial" means the mechanism is there but
the proof or a piece is not; "missing" means nothing in the tree does it.
Every row's leaf was filed 2026-09-12; the three milestones `PDS launch: G-QUIET`,
`G-ANNOUNCE`, `G-MIGRATE` hold them, and a milestone's open count is the burndown.

### 2.A Feature completeness

The tree serves twenty-one XRPC methods plus two well-knowns, forwards six
`app.bsky.*` reads to the appview, and emits `#commit` on the firehose. The
official PDS's route registration (`pds/test/vectors/pds_route_registration_corpus.txt`)
is the answer key for what a client and a relay expect.

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| A1 | Any `app.bsky.*` or `chat.bsky.*` method this server neither serves locally nor lists as protected is forwarded to its configured audience with a minted service token, mirroring the official catch-all. Audience stays default-deny (the configured appview DID and the chat service DID only). Header pass-through for `atproto-accept-labelers` and `accept-language`. | G-QUIET | missing — `pds/lib/proxy.mdk` forwards six methods and refuses the rest by design (#2912); the official app calls dozens | #2935 |
| A2 | `app.bsky.actor.getPreferences` / `putPreferences` answered from a PDS-hosted store that survives restart. | G-QUIET | missing — 404 today | #2936 |
| A3 | `com.atproto.server.getServiceAuth` served, with `aud`, `lxm`, `exp` bound, so the app can reach the chat and video services. | G-QUIET | missing — 404 today | #2936 |
| A4 | Firehose emits `#identity`, `#account`, `#sync` alongside `#commit`; `sync.getRecord` and `sync.getBlocks` served. | G-QUIET | partial — `#commit` and `#info` only | #2937 |
| A5 | `createSession` / `getSession` / `describeServer` return the fields the official app reads (`active`, `status`, `email` where applicable, `links`, `contact`). | G-QUIET | partial — minimal field sets | #2936 |
| A6 | CORS: a browser at `bsky.app` can complete a preflight and a credentialed request against this PDS. | G-QUIET | missing — no `Access-Control-*` anywhere, OPTIONS answers 405 | #2938 |
| A7 | `com.atproto.identity.updateHandle` changes the handle, emits `#identity`, and `resolveHandle` answers the new one. | G-ANNOUNCE | missing | #2939 |
| A8 | A written conformance walkthrough, run by hand against the live server from the official app: log in, post, upload an image, follow, reply, read notifications, send and receive a DM, log out; the relay indexes the repo; a fresh appview fetch of the profile succeeds. Each step's expected observation written before the run. | G-QUIET | missing — the pieces are gated individually against stubs; nothing has been run against a live deploy | #2940 |
| A9 | Migration route surface: `server.createAccount` with an existing DID under an inbound service-auth token from the old PDS, `repo.importRepo`, `repo.listMissingBlobs`, `server.activateAccount` / `deactivateAccount` / `checkAccountStatus`, `identity.getRecommendedDidCredentials`, `identity.submitPlcOperation`. | G-MIGRATE | missing — zero of these; the inbound service-auth verifier was explicitly declined for 0.1.0 (design §4.5) and must be un-declined for this gate | #2941 |
| A10 | PLC operation signing with rotation keys held separately from the repo signing key; the isolated-PLC rehearsal and rollback checklist on #2609 run twice. | G-MIGRATE | missing | #2609 |
| A11 | `describeRepo.didDoc` resolved against the authoritative document, not synthesized. | G-MIGRATE | missing | #2904 |

Out of scope for every gate, by decision: OAuth (#2610, L2), the read-only web
view (#2607), email verification and password reset (single owner, offline
rotation), app passwords (#2658, ruled out), invite codes and admin routes,
multi-account, lexicon validation (`validate: true` refused, deliberate).

### 2.B Security

What is strong: the crypto is graded against external oracles (G1–G5), the
pure/shell seam and secret containment are proven by `pds/test/lib_boundary.sh`
with mutation controls, and `pds/test/serve_e2e.sh` attacks a running server
across ~fifty adversarial cases. SSRF, path traversal, header injection,
request smuggling, the proxy confused deputy, and MST cycles are closed by
construction. What is weak: the perimeter (Caddy, systemd), a handful of
request-path bounds nobody has written down, and the absence of any adversary
who did not also write the tests.

Every finding marked **needs-repro** below was derived by reading, not by
executing. Reproduce before fixing; closing one as not-real is a good outcome.

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| B1 | A per-route table (auth policy × rate-limit class × size ceiling) is pinned by a gate that enumerates the registry, so a route added without a ceiling reds. | G-QUIET | partial — every route takes an explicit `AuthPolicy`; nothing pins the triple | #2942 |
| B2 | Request-body JSON has a depth bound enforced before any credential is resolved; a 100k-deep body to `createSession` yields 400 and the server keeps answering. **needs-repro** | G-QUIET | missing — `stdlib/json.mdk` has no depth limit; the decode precedes auth resolution | #2946 |
| B3 | Encode and decode depth agree: a record deeper than the decoder's `maxDepth` is refused at write, never committed unreadable. **needs-repro, S0 if real** | G-QUIET | missing — `pds/lib/dagcbor.mdk` bounds decode only | #2947 |
| B4 | `getBlob` responses carry `X-Content-Type-Options: nosniff` and `Content-Disposition: attachment`, or `text/html` is never stored under its own type. | G-QUIET | missing | #2948 |
| B5 | Caddy overwrites `X-Forwarded-For` with the remote host, and the PDS independently caps the header's length and token count before parsing, so a client-supplied 64 KiB header cannot be paid for on the single scheduler thread. | G-QUIET | missing — `pds/Caddyfile` appends; `pds/lib/ratelimit.mdk` splits unbounded | #2949 |
| B6 | The rate-limiter identity table is bounded (cap, TTL, or LRU); a million distinct identities do not grow RSS without bound. | G-ANNOUNCE | missing | #2950 |
| B7 | Concurrent request bodies at the 5 MiB ceiling across the 256-connection ceiling fit in the unit's `MemoryMax`; a gate holds 256 slow bodies and the process survives. | G-ANNOUNCE | missing — bodies buffer as one tagged word per byte | #2951 |
| B8 | Durability: a `kill -9` mid-commit leaves a repo that loads, or the head pointer is written after its blocks reach disk. **needs-repro, S0 if real** | G-QUIET | missing — no `fsync` in `stdlib/` or `runtime/`; `pds/shell/persist.mdk` documents the ordering hole | #2952 |
| B9 | The constant-time gates cover the token and credential comparisons in `pds/lib/credential.mdk` and `pds/lib/jwt.mdk`, not only the curve arithmetic. | G-ANNOUNCE | missing — four `constant_time_*.sh` gates, none names either file | #2953 (adjacent: #2838) |
| B10 | Sessions have an absolute lifetime and a refresh family is revoked on replay of a rotated token. | G-ANNOUNCE | missing — refresh chains renew indefinitely | #2943 |
| B11 | `<data>/credential` and `--password-file` are refused at a mode wider than `0600`, as `--key` and `--token-secret` already are. | G-QUIET | missing | #2944 |
| B12 | The KDF iteration count carries a dated re-ruling stating the residual (3000 vs OWASP 600,000) as accepted for a single-owner server, or is raised. | G-ANNOUNCE | partial — stated in the design doc, not re-ruled for launch | #2659 (ruling recorded 2026-09-12) |
| B13 | Un-framed connection admission distinguishes sources, or the shortfall is accepted for G-ANNOUNCE with a date. | G-ANNOUNCE | open, measured | #2816 |
| B14 | An adversarial review by a fresh agent against a RUNNING instance on this box, from a written attack list covering every row of #1697's exposure table plus B2–B11, with every finding filed and nothing above S2 left open. Repeated after any S0/S1 fix that changes the request path. | G-ANNOUNCE | missing — never done; every existing attack case was written by the authors | #2945 |
| B15 | Every open PDS issue carries `ws:pds` and a severity label, so the exposure ledger is closed under the tracker. | G-QUIET | partial — #2572 and #2904 are labeled off-workstream; most pds leaves carry no severity | done 2026-09-12 (#2572, #2904, #2816 relabeled) |
| B16 | The signing key, session secret, and credential digest are in an encrypted off-box backup with named custody; a written "assume breach" procedure says what to do when the box is compromised, for each identity kind. | G-QUIET | missing | #2962 |

**The sign-off artifact** (§3) is a dated section appended to #1697's exposure
table: one row per criterion above, each "closed by `<gate>`" or "accepted by
ruling `<date>`", plus B14's review report linked. Nothing else counts as
signed off.

### 2.C Performance

Nothing in the tree measures latency under concurrency, memory over time, or
cost at a realistic repo size. What exists asserts admission boundaries and
cost-independence; the largest measured repo is 660 records. One-account
real-world load is small, but two hazards scale with legitimate traffic: every
file read blocks the single scheduler thread, and the listing routes walk the
whole MST per page.

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| C1 | A concurrent-client harness exists: N clients against a running server, reporting p50/p99 per route, runnable in a bounded time on this box. | G-QUIET | missing | #2954 |
| C2 | A synthetic-repo builder produces a repo of thousands of records and hundreds of blobs without going through the rate-limited HTTP write path. | G-QUIET | missing | #2954 |
| C3 | `listRecords?limit=25` p99 at 5,000 records is within 2× its cost at 0 records. | G-ANNOUNCE | missing — the walk is O(repo) | #2773 |
| C4 | A 50 MiB `getRepo` export delays an unrelated concurrent `getRecord` by less than a stated bound; the bound is written into the design doc as accepted. | G-ANNOUNCE | missing — the export is fully buffered by the seam's design | #2955 |
| C5 | A burst of concurrent `getBlob` reads (the semi-viral-post shape) is measured; either file I/O is routed off the scheduler thread or the measured degradation is accepted with a number. | G-ANNOUNCE | missing — file externs are synchronous libc calls | #2956 |
| C6 | Uploading the account's hundredth blob writes less than 3× that blob's size to disk. | G-ANNOUNCE | missing — every upload rewrites the whole blob half | #2692 |
| C7 | A soak of stated length under synthetic write + read + relay-subscribe load, run off-hours as an isolated job, shows RSS growth under a stated percentage. | G-ANNOUNCE | missing | #2957 |
| C8 | Outbound `getaddrinfo` no longer blocks the scheduler, or the egress proxy is dialed by literal loopback address only (it already is) and this is recorded as the mitigation. | G-ANNOUNCE | open | #2928 |
| C9 | Block-store growth without GC is bounded by a stated policy (a periodic sweep, or a documented disk budget with the alert in 2.E watching it). | G-MIGRATE | open | #2572 |

### 2.D Deployment

The build → keygen → genesis → systemd → Caddy → verify path is written in
`docs/ops/PDS-DEPLOY.md`, and backup/restore is rehearsed by `pds/test/serve_e2e.sh`
case 33. The systemd and Caddy halves have never been run, and no live deploy
has ever happened.

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| D1 | `pds/pds.service` creates or documents its service user, and sets `MemoryMax`, `CPUWeight`/`Nice`, `TasksMax`, `LimitNOFILE`, `StartLimitBurst`, `IPAddressDeny=any` + `IPAddressAllow=localhost`, `CapabilityBoundingSet=`, `ProtectHome`, `PrivateDevices`, `UMask=0077`, `RequiresMountsFor`. A gate lints the unit for the required directives. | G-QUIET | partial — four hardening directives present, the rest absent | #2958 |
| D2 | `pds/Caddyfile` sets `header_up X-Forwarded-For {remote_host}`, HSTS, explicit timeouts, a request body limit at or above the PDS's own, and an access log; WebSocket upgrade for `subscribeRepos` verified live. A gate lints the file. | G-QUIET | missing — one `reverse_proxy` line; no gate mentions Caddy | #2959 |
| D3 | The running binary reports its build commit and source fingerprint on `--version` and in the startup line; binaries live under a versioned path with a symlink, and rollback is one documented command that has been run once. | G-QUIET | missing — `buildCommit`/`buildFingerprint` externs exist in `stdlib/runtime.mdk`, never called from `pds/` | #2960 |
| D4 | What runs on the egress port (appview) and the relay port is specified: the software, its config, its own systemd unit, and its allow-list of destinations. | G-QUIET | missing — the ports are named, nothing is proposed to listen on them | #2961 |
| D5 | Backups run on a timer, land off-box encrypted, and a restore drill against the real deployment's backup has been run on this box (not only the CI fixture). | G-QUIET | partial — procedure rehearsed in CI; no timer, no off-box copy, no real-data drill | #2962 |
| D6 | `SIGTERM` drains: in-flight requests finish or are cut at a bound, the event log is left consistent, and the exit is logged. | G-ANNOUNCE | missing — the runtime installs no `SIGTERM` handler; stage-then-rename is the only protection | #2963 |
| D7 | A box-sharing rule is written: which gate/agent work may run beside the live service, and the service's cgroup weights make the rule survivable when it is broken. | G-QUIET | missing | #2958 |
| D8 | `docs/ops/PDS-DEPLOY.md` describes the tree as it stands (it still says the firehose is out of scope). | G-QUIET | stale | #2970 |
| D9 | Compiler and PDS upgrades are separate procedures: rebuilding `pdsd` against a newer compiler is followed by the signing-parity and e2e gates before the swap. | G-ANNOUNCE | missing | #2972 |

### 2.E Observability

The running server emits one readiness line, one persist-failure line, and
one relay-announce failure line. There is no request log, no health route, no
version stamp, no stats, and nothing that tells Val the service is down.

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| E1 | Every request produces one log line: method, route, status, duration, bytes, forwarded-for (never a token, never a body); a gate greps the log path for the secret-name list `lib_boundary.sh` already enforces on strings. | G-QUIET | missing | #2964 |
| E2 | Startup logs the build commit, the config summary (did, handle, hostname, bind, port, trusted-proxy, appview), and the event-log recovery outcome (discarded / promoted / none). | G-QUIET | missing | #2964 |
| E3 | A health route (`/xrpc/_health`, as the official PDS serves) returns the version and is polled. | G-QUIET | missing | #2965 |
| E4 | A periodic stats line: active connections, un-framed connections, subscribers, repo rev, blocks and blobs on disk. | G-ANNOUNCE | missing — the counters exist in memory | #2966 |
| E5 | A down or crash-looping service reaches Val within minutes: an `OnFailure=` unit or a probe on a timer, with the notification path named and tested by killing the service once. | G-QUIET | missing | #2967 |
| E6 | A panic in one handler is visible as such: exit code and the panic text land in journald, and the restart count is readable. | G-QUIET | exists in principle (`Restart=on-failure`, `exit(1)` on panic), unverified live | #2967 |
| E7 | Caddy's access log and certificate-renewal events are retained and readable beside the PDS log. | G-ANNOUNCE | missing | #2959 |

### 2.F Code quality

The library reads as carefully authored. The comment register is "why", not
"what"; constants carry their threat model; naming is consistent; the test
vehicle split is clean. The defects are small and concentrated: a few files
carry sprint names, issue numbers, and self-narration in comments, one export
is dead, the biggest files have no section index, and the repo's own slop
instruments do not look at `pds/` at all.

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| F1 | `test/comment_register_census.sh` and `test/slop_census.sh` scope `pds/*.mdk`, and report zero issue-number citations, zero emoji shouts, and zero self-narration in `pds/lib` and `pds/shell`. | G-ANNOUNCE | missing — both scripts are hardwired to `compiler/` and `stdlib/` | #2968 |
| F2 | Register trims applied: `pds/lib/scalar.mdk`'s header keeps the numerical argument and loses the sprint-contract and "delete this comment" prose; `pds/lib/resource_limits.mdk`, `pds/lib/field.mdk`, `pds/lib/multiformats.mdk` cite constraints, not history. The dead `storeSessionCount` export removed; the raw `2^62-1` literal in `pds/lib/handlers.mdk` named. | G-ANNOUNCE | missing | #2969 |
| F3 | Every file over ~700 lines carries a section index at the top. | G-ANNOUNCE | missing | #2969 |
| F4 | `medaka lint pds` clean under the ratcheted rule set, with every suppression carrying a reason. | G-ANNOUNCE | unverified | #2969 |
| F5 | `docs/design/ATPROTO-PDS-DESIGN.md`'s status banner agrees with its own §7 (the firehose is landed) and a short architecture overview for a non-author exists, ordered README → `pds/serve.mdk` → `server_core` → `handlers` → `shell/server`. | G-ANNOUNCE | partial — README is accurate; banner stale; no short overview | #2970 |
| F6 | A fresh agent, given only the docs, produces an architecture summary a maintainer grades as correct. | G-ANNOUNCE | missing | #2970 |
| F7 | Stdlib graduation decided per module under P11: `base58` and `multiformats` moved or explicitly kept; `field`/`scalar`/`secp256k1` decided once G1 has been stable across the soak. | G-MIGRATE | partial — hashes, base32, HTTP codec, ReadBuffer already moved | #2971 |

### 2.G Identity and data custody

The area Val's list did not name. `did:web` puts the DID document on the box,
so whoever owns the box owns the identity and there is no offline recovery
path; `did:plc` inverts that with rotation keys. This is why L1 orders the
identities as it does, and why custody is a gate criterion rather than an ops
note.

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| G1 | For the `did:web` account: the consequence "box lost = identity lost" is written and accepted for G-QUIET, with the mitigations D5 and B16 in place before the first real post. | G-QUIET | missing | #2962 |
| G2 | For the `did:plc` account: rotation keys generated and held off-box before any PLC operation; a rehearsed procedure re-points the DID back to bsky.social or to a restored instance, run against an isolated PLC. | G-MIGRATE | missing | #2609 |
| G3 | Handle verification for the real account (`_atproto` DNS TXT or `/.well-known/atproto-did`) rehearsed on the fresh account first. | G-QUIET | partial — the well-known is served; never resolved by a real relay | #2940 |
| G4 | The nightly signing-parity gate (`pds/nightly/signing_parity.sh`) is confirmed green against the exact commit deployed, every deploy. | G-QUIET | procedural | #1962 |

### 2.H Launch operations

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| H1 | A launch runbook: the commit is tagged, the binary's provenance (D3) matches the tag, the gates that must be green are named and derived (not listed), the soak's start and its S0/S1-reset rule are written, and the rollback is the D3 command. | G-QUIET | missing | #2972 |
| H2 | The announcement text is drafted with its honest footnotes (§6) before the soak ends, and reviewed against the tree as it stands on the day. | G-ANNOUNCE | missing | #2972 |
| H3 | An incident procedure: who does what when the service is down at an hour Val is asleep; the answer may be "it stays down until morning" but it is written. | G-ANNOUNCE | missing | #2972 |

## 3. The sign-off standard

Each area has a named artifact; "signed off" means the artifact exists at the
gate and Val has read it.

| Area | Artifact | Where |
|---|---|---|
| Feature | The A8 walkthrough transcript, one line per step, observed vs. expected. | Comment on #1697 |
| Security | The dated criteria section (2.B) appended to the exposure table, plus B14's review report. | #1697 body, review report linked |
| Performance | The C1/C7 harness output for the deployed commit, with each accepted bound stated beside its measured value. | Comment on #1697 |
| Deployment | The D1/D2 lint gates green on the deployed files, plus the D5 restore-drill log. | Gate results, comment on #1697 |
| Observability | One real request's log line, one real startup banner, and the E5 test's notification, pasted. | Comment on #1697 |
| Code quality | The F1 census output for `pds/` at the tagged commit. | Comment on #1697 |
| Identity | B16's custody statement and, for G-MIGRATE, the #2609 rehearsal log. | #2609 |

## 4. Sequencing

Sprints, in the order that unblocks the next gate soonest. Each is a
`sprint-plan` cut, not a commitment to its slice list.

1. **pds-the-app-can-use-us** — A1, A2, A3, A5, A6 (the official app logs in and works). Highest value per line; A1 needs the §5 decision first.
2. **pds-the-request-path-is-bounded** — B2, B3, B5, B8, B11 (the needs-repro S0/S1 candidates, reproduced then fixed or closed), B1 (the per-route table gate).
3. **pds-a-relay-can-index-us** — A4 (the three missing event types, `getRecord`/`getBlocks`).
4. **pds-it-runs-on-the-box** — D1, D2, D3, D4, E1, E2, E3, E5, D8 (the first real deploy is this sprint's demonstration, on a test hostname; it becomes G-QUIET's instance).
5. **pds-we-can-see-it** — C1, C2, C4, C5, E4 (measure before the announcement, accept or fix).
6. **G-QUIET closes.** Soak begins.
7. **pds-a-stranger-can-poke-it** — B14 (the adversarial review), then its fix round; B6, B7, B9, B10, D6, C7.
8. **pds-polished** — F1–F6.
9. **G-ANNOUNCE closes.** Soak begins.
10. **pds-the-real-account** — A9, A10, A11, G2, #2609's rehearsals.
11. **G-MIGRATE closes.**

## 5. Rulings taken (Val, 2026-09-12)

| # | Ruling | Where it is recorded |
|---|---|---|
| **R1** | **Proxy method policy inverts.** `pds/lib/proxy.mdk` was default-deny on the method axis by the #2912 ruling. The METHOD axis becomes default-allow for `app.bsky.*` / `chat.bsky.*` with an explicit protected list derived from the official `PROTECTED_METHODS`; the AUDIENCE axis stays default-deny (the configured appview DID and the chat service DID only). The confused-deputy defense lives on the audience axis; the method axis only ever bounded which reads the appview would answer. | #2935 |
| **R2** | **"Box lost = identity lost" is accepted for the `did:web` account** through G-QUIET and G-ANNOUNCE, given the custody criteria (D5/B16). It is the price of L1's ordering and it expires at G-MIGRATE, where off-box rotation keys invert it. | #2962, #2609 |
| **R3** | **The KDF residual is accepted.** 3000 PBKDF2 iterations stand for a single-owner server whose password never leaves its owner; the attacker who holds the credential file also holds the signing key, so a higher work factor buys nothing against the threat that reaches the file. Revisit on a second account or a custody split. | comment on #2659 |
| **R4** | **The read-derived S0/S1 candidates are filed now** at their candidate severities with `needs-repro`; the sprint that reproduces them relabels or closes. An unfiled S0 candidate is the shape #518 sat in. | #2946, #2947, #2952 |

## 6. What "written entirely in Medaka" will mean, honestly

The claim is defensible if the footnotes are written before the post: the PDS,
its HTTP/1.1 and WebSocket codecs, DAG-CBOR, CIDs, the MST, CAR, and all of the
cryptography (SHA-256, HMAC, PBKDF2, secp256k1, ECDSA) are Medaka. TLS is
Caddy. The language runtime is C with the Boehm collector. The reference
implementation was the oracle for every corpus, never a dependency. A reader
who checks will find exactly that, which is the point.

## 7. Out of scope for this plan

OAuth (#2610). The web view (#2607). Multi-account. Email. Lexicon validation.
Moving the deployment to another host (the restore drill is the mechanism if
it ever happens). The language's own 0.1.0 preview, which has its own plan.
