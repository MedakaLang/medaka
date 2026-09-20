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
this document guesses now.

**A soak has TWO clocks, and only one of them is a calendar.**

- **The calendar clock** — the stated duration. It is counted from the **last
  S0/S1 fix deployed**, not from first boot, and an S2 or below does not reset
  it. Deploying during a soak is therefore permitted, and always was.
- **The uninterrupted-run clock** — time since the last restart, *any* restart,
  for any reason. It is reset by a deploy, a config change, a crash, or a
  reboot, regardless of severity.

The second clock is the one nobody wrote down, and it is the one that carries
the soak's actual value. These properties are unreachable without it, and each
has been **structurally unexercisable** up to the moment a soak begins, because
deploy cadence kept restarting the server:

| property | needs an uninterrupted run of |
|---|---|
| refresh-token rotation against a live token | **> 2h** (`accessTokenSeconds`) |
| the event-log retention sweep, and a relay reconnecting past it (#3005) | **> 72h** (`eventLogRetentionSeconds`) |
| RSS drift with a readable trend (C7) | days |

⚠️ **A soak that runs its full calendar week while being deployed to daily
proves uptime, not the three things uptime was standing in for.** So:

> **At least one window of ≥72h with no restart must fall inside the soak**
> before its gate may close. Deploys during a soak are batched rather than
> shipped one at a time, and each is recorded on #1697 with its date and the
> severities it carried.

Ruling: Val, 2026-09-17, on starting the G-QUIET soak while G-ANNOUNCE work
continues.

## 2. Acceptance criteria

Every row: an ID, the criterion (checkable, not a vibe), the gate it blocks,
the state of the tree, and the tracking issue. "exists" means a gate or
rehearsal already proves it; "partial" means the mechanism is there but the
proof or a piece is not; "missing" means nothing in the tree does it.
Every row's leaf was filed 2026-09-12; the three milestones `PDS launch: G-QUIET`,
`G-ANNOUNCE`, `G-MIGRATE` hold them, and a milestone's open count is the burndown.

> **State column re-derived 2026-09-16**, after sprints 2–9 landed. 29 of the 67
> rows had gone false. Each was re-checked **against the tree**, not against the
> tracking issue's state — a closed issue is not a met criterion, and B2 is the
> row that proves why: #2946 closed as *not reproduced*, while the depth bound
> its criterion actually names still does not exist. Re-derive the same way, and
> treat a state cell older than the last landed sprint as unverified.
>
> **Six rows re-derived again 2026-09-20** — B14, D9, E7, F4, H2, H3 — from the
> live box and the tracker, not from the tracking issues' state. Two had gone
> false in the optimistic direction (B14 said "never done" when it had been run
> on 09-18 with findings; F4 said "unverified" when `medaka lint pds` reports
> 180), and four in the pessimistic direction (D9, E7, H2, H3 all landed with
> #2972/#2959 and the row never moved). **The other sixty-one rows carry their
> 2026-09-16 state and are still unverified against today's tree.**
>
> One structural fix went with it: **B12's #2659 was in no milestone at all**,
> so a row this table calls a G-ANNOUNCE blocker was invisible to the burndown
> the paragraph above calls authoritative. A row's leaf being milestoned is
> itself a thing to check when re-deriving.

### 2.A Feature completeness

The tree serves twenty-six XRPC methods plus two well-knowns and a health
probe, forwards any unregistered `app.bsky.*`/`chat.bsky.*` method to a
configured audience, and emits `#commit`, `#identity`, `#account` and `#sync`
on the firehose. The official PDS's route registration
(`pds/test/vectors/pds_route_registration_corpus.txt`) is the answer key for
what a client and a relay expect.

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| A1 | Any `app.bsky.*` or `chat.bsky.*` method this server neither serves locally nor lists as protected is forwarded to its configured audience with a minted service token, mirroring the official catch-all. Audience stays default-deny (the configured appview DID and the chat service DID only). Header pass-through for `atproto-accept-labelers` and `accept-language`. | G-QUIET | exists — `proxyDisposition`'s `ProxyForwardable` arm forwards any unregistered `app.bsky.*`/`chat.bsky.*` NSID; audience stays default-deny; `accept-language`, `atproto-accept-labelers` and `x-bsky-topics` pass through | #2935 |
| A2 | `app.bsky.actor.getPreferences` / `putPreferences` answered from a PDS-hosted store that survives restart. | G-QUIET | exists — both registered; persistence across a restart graded by `pds/test/serve_e2e.sh` case 9 (re-read from a fresh process) | #2936 |
| A3 | `com.atproto.server.getServiceAuth` served, with `aud`, `lxm`, `exp` bound, so the app can reach the chat and video services. | G-QUIET | exists — `getServiceAuth` registered as an authenticated query | #2936 |
| A4 | Firehose emits `#identity`, `#account`, `#sync` alongside `#commit`; `sync.getRecord` and `sync.getBlocks` served. | G-QUIET | exists — `#identity`/`#account`/`#sync` frame builders in `pds/lib/sync_event.mdk`; `sync.getRecord` and `sync.getBlocks` registered | #2937 |
| A5 | `createSession` / `getSession` / `describeServer` return the fields the official app reads (`active`, `status`, `email` where applicable, `links`, `contact`). | G-QUIET | exists — `active`, `links`, `contact`, `availableUserDomains`, `inviteCodeRequired` all served | #2936 |
| A6 | CORS: a browser at `bsky.app` can complete a preflight and a credentialed request against this PDS. | G-QUIET | exists — `pds/lib/cors.mdk`; preflight and credentialed request graded in `serve_e2e.sh` | #2938 |
| A7 | `com.atproto.identity.updateHandle` changes the handle, emits `#identity`, and `resolveHandle` answers the new one. | G-ANNOUNCE | missing | #2939 |
| A8 | A written conformance walkthrough, run by hand against the live server from the official app: log in, post, upload an image, follow, reply, read notifications, send and receive a DM, log out; the relay indexes the repo; a fresh appview fetch of the profile succeeds. Each step's expected observation written before the run. | G-QUIET | drafted — [`PDS-CONFORMANCE-WALKTHROUGH.md`](PDS-CONFORMANCE-WALKTHROUGH.md) holds the steps and their expected observations; the pieces are gated individually against stubs and nothing has been run against a live deploy, so this closes only on a completed transcript | #2940 |
| A9 | Migration route surface: `server.createAccount` with an existing DID under an inbound service-auth token from the old PDS, `repo.importRepo`, `repo.listMissingBlobs`, `server.activateAccount` / `deactivateAccount` / `checkAccountStatus`, `identity.getRecommendedDidCredentials`, `identity.submitPlcOperation`. | G-MIGRATE | missing — zero of these; the inbound service-auth verifier was explicitly declined for 0.1.0 (design §4.5) and must be un-declined for this gate | #2941 |
| A10 | PLC operation signing with rotation keys held separately from the repo signing key; the isolated-PLC rehearsal and rollback checklist on #2609 run twice. | G-MIGRATE | missing | #2609 |
| A11 | `describeRepo.didDoc` resolved against the authoritative document, not synthesized. | G-MIGRATE | missing | #2904 |

Out of scope for every gate, by decision: OAuth (#2610, L2), the read-only web
view (#2607), email verification and password reset (single owner, offline
rotation), app passwords (#2658, ruled out), invite codes and admin routes,
multi-account. Lexicon validation is NOT implemented, but `validate: true` is
accepted rather than refused as of ruling **R5** below — the refusal blocked the
official app entirely.

### 2.B Security

What is strong: the crypto is graded against external oracles (G1–G5), the
pure/shell seam and secret containment are proven by `pds/test/lib_boundary_test.mdk`
with mutation controls, and `pds/test/serve_e2e.sh` attacks a running server
across ~fifty adversarial cases. SSRF, path traversal, header injection,
request smuggling, the proxy confused deputy, and MST cycles are closed by
construction. The perimeter (Caddy, systemd) and the request-path bounds were
the weak half on 2026-09-12 and are now largely closed — B1–B5, B8 and B11 all
landed in sprints 2 and 7. **What remains weak is the part no sprint can
supply: the absence of any adversary who did not also write the tests** (B14),
plus the memory bounds B6/B7 that only matter under hostile load.

Every finding marked **needs-repro** below was derived by reading, not by
executing. Reproduce before fixing; closing one as not-real is a good outcome.

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| B1 | A per-route table (auth policy × rate-limit class × size ceiling) is pinned by a gate that enumerates the registry, so a route added without a ceiling reds. | G-QUIET | exists — `pds/test/route_policy_test.mdk` joins auth policy × rate-limit classes × ceiling over `registryEndpoints`, floor-asserted by `inlang_test_oracle_test.mdk` | #2942 |
| B2 | Request-body JSON has a depth bound enforced before any credential is resolved; a 100k-deep body to `createSession` yields 400 and the server keeps answering. **needs-repro** | G-QUIET | **partial, and not for the reason this row gave** — #2946 closed NOT reproduced: the feared crash borrowed the tree-walking interpreter's call-depth ceiling, which the native server does not have. `stdlib/json.mdk` still has no depth bound, so the mechanism this criterion names does not exist; what changed is that the hazard did not reproduce | #2946 |
| B3 | Encode and decode depth agree: a record deeper than the decoder's `maxDepth` is refused at write, never committed unreadable. **needs-repro, S0 if real** | G-QUIET | exists — `maxDagCborDepth`/`checkDagCborDepth` in `pds/lib/resource_limits.mdk` gates both `emitValue` and `parseValueAt` in `pds/lib/dagcbor.mdk`, so encode and decode agree by construction | #2947 |
| B4 | `getBlob` responses carry `X-Content-Type-Options: nosniff` and `Content-Disposition: attachment`, or `text/html` is never stored under its own type. | G-QUIET | exists — `blobOkResponse` adds both headers, scoped to `getBlob` alone | #2948 |
| B5 | Caddy overwrites `X-Forwarded-For` with the remote host, and the PDS independently caps the header's length and token count before parsing, so a client-supplied 64 KiB header cannot be paid for on the single scheduler thread. | G-QUIET | exists — `pds/Caddyfile` sets `header_up X-Forwarded-For {remote_host}`; `checkXffHeaderBytes` and `checkXffTokens` cap the raw bytes and the token count before any decode or split | #2949 |
| B6 | The rate-limiter identity table is bounded (cap, TTL, or LRU); a million distinct identities do not grow RSS without bound. | G-ANNOUNCE | missing | #2950 |
| B7 | Concurrent request bodies at the 5 MiB ceiling across the 256-connection ceiling fit in the unit's `MemoryMax`; a gate holds 256 slow bodies and the process survives. | G-ANNOUNCE | missing — bodies buffer as one tagged word per byte | #2951 |
| B8 | Durability: a `kill -9` mid-commit leaves a repo that loads, or the head pointer is written after its blocks reach disk. **needs-repro, S0 if real** | G-QUIET | landed — `fsync` extern in `stdlib/runtime.mdk`; every publishing `rename` in `pds/shell/` barriers the staged file before it and the containing directory after, graded by case 12 of `pds/test/store_persistence.sh` | #2952 |
| B9 | The constant-time gates cover the token and credential comparisons in `pds/lib/credential.mdk` and `pds/lib/jwt.mdk`, not only the curve arithmetic. | G-ANNOUNCE | missing — four `constant_time_*.sh` gates, none names either file | #2953 (adjacent: #2838) |
| B10 | Sessions have an absolute lifetime and a refresh family is revoked on replay of a rotated token. | G-ANNOUNCE | missing — refresh chains renew indefinitely | #2943 |
| B11 | `<data>/credential` and `--password-file` are refused at a mode wider than `0600`, as `--key` and `--token-secret` already are. | G-QUIET | exists — `requirePrivateMode` refuses both the credential and `--password-file` at startup | #2944 |
| B12 | The KDF iteration count carries a dated re-ruling stating the residual (3000 vs OWASP 600,000) as accepted for a single-owner server, or is raised. | G-ANNOUNCE | partial — stated in the design doc, not re-ruled for launch | #2659 (ruling recorded 2026-09-12) |
| B13 | Un-framed connection admission distinguishes sources, or the shortfall is accepted for G-ANNOUNCE with a date. | G-ANNOUNCE | open, measured | #2816 |
| B14 | An adversarial review by a fresh agent against a RUNNING instance on this box, from a written attack list covering every row of #1697's exposure table plus B2–B11, with every finding filed and nothing above S2 left open. Repeated after any S0/S1 fix that changes the request path. | G-ANNOUNCE | run, not signed off — carried out 2026-09-18 against `01c98b92f`, transcript on #1697. No S0. One new S1 (#3182, since closed); six rows confirmed known open issues (#2816, #2572, #2773, #2950, #2951, #2943) and #2953's consumer-enrolment obligation was explicitly not closed; three rows (9, 14, 22) are NOT EXERCISABLE locally and need a ruling, not code. The review's own verdict is that B14 cannot be signed off while those remain, and the row repeats after any S0/S1 fix that changes the request path | #2945 |
| B15 | Every open PDS issue carries `ws:pds` and a severity label, so the exposure ledger is closed under the tracker. | G-QUIET | done 2026-09-12; re-derived 2026-09-16 and still true | done 2026-09-12 (#2572, #2904, #2816 relabeled) |
| B16 | The signing key, session secret, and credential digest are in an encrypted off-box backup with named custody; a written "assume breach" procedure says what to do when the box is compromised, for each identity kind. | G-QUIET | missing | #2962 |

**The sign-off artifact** (§3) is a dated section appended to #1697's exposure
table: one row per criterion above, each "closed by `<gate>`" or "accepted by
ruling `<date>`", plus B14's review report linked. Nothing else counts as
signed off.

### 2.C Performance

Sprint 5 built the instruments this section said were missing — a concurrent
client harness and a synthetic repo builder — and sprint 6 fixed three
quadratics they found, all of which had lived their whole life under a green
gate named "MST scaling". The single-scheduler-thread hazard is now measured
and accepted with numbers rather than feared (C4, C5). What remains is the
cost that scales with the repo rather than with the request: the listing
routes still walk the whole MST per page (C3), and the blob half still rewrites
on every upload (C6).

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| C1 | A concurrent-client harness exists: N clients against a running server, reporting p50/p99 per route, runnable in a bounded time on this box. | G-QUIET | exists — `pds/nightly/load_harness.sh` | #2954 |
| C2 | A synthetic-repo builder produces a repo of thousands of records and hundreds of blobs without going through the rate-limited HTTP write path. | G-QUIET | exists — `pds/test/synth_repo_main.mdk` builds a corpus without the HTTP write path | #2954 |
| C3 | `listRecords?limit=25` p99 at 5,000 records is within 2× its cost at 0 records. | G-ANNOUNCE | missing — the walk is O(repo) | #2773 |
| C4 | A 50 MiB `getRepo` export delays an unrelated concurrent `getRecord` by less than a stated bound; the bound is written into the design doc as accepted. | G-ANNOUNCE | accepted with a number — +586 ms on an unrelated read of an 800-record repository, stated in `docs/design/ATPROTO-PDS-DESIGN.md` §6 under `sync.getRepo` | #2955 |
| C5 | A burst of concurrent `getBlob` reads (the semi-viral-post shape) is measured; either file I/O is routed off the scheduler thread or the measured degradation is accepted with a number. | G-ANNOUNCE | accepted with a number — a 2,674/s `getBlob` burst raises an unrelated `getRecord` by +1.19 ms; measured and accepted in the design doc rather than routed off-thread | #2956 |
| C6 | Uploading the account's hundredth blob writes less than 3× that blob's size to disk. | G-ANNOUNCE | missing — every upload rewrites the whole blob half | #2692 |
| C7 | A soak of stated length under synthetic write + read + relay-subscribe load, run off-hours as an isolated job, shows RSS growth under a stated percentage. | G-ANNOUNCE | missing | #2957 |
| C8 | Outbound `getaddrinfo` no longer blocks the scheduler, or the egress proxy is dialed by literal loopback address only (it already is) and this is recorded as the mitigation. | G-ANNOUNCE | open | #2928 |
| C9 | Block-store growth without GC is bounded by a stated policy (a periodic sweep, or a documented disk budget with the alert in 2.E watching it). | G-MIGRATE | open | #2572 |

### 2.D Deployment

The build → keygen → genesis → systemd → Caddy → verify path is written in
`docs/ops/PDS-DEPLOY.md`, and backup/restore is rehearsed by `pds/test/serve_e2e.sh`
case 33. The unit and both Caddyfiles are now written and linted by
`pds/test/deploy_config_lint_test.mdk`. **The systemd and Caddy halves have still
never been run, and no live deploy has ever happened** — that is what D2's and
D5's open halves are, and it is the whole of what G-QUIET is now waiting on.

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| D1 | `pds/pds.service` creates or documents its service user, and sets `MemoryMax`, `CPUWeight`/`Nice`, `TasksMax`, `LimitNOFILE`, `StartLimitBurst`, `IPAddressDeny=any` + `IPAddressAllow=localhost`, `CapabilityBoundingSet=`, `ProtectHome`, `PrivateDevices`, `UMask=0077`, `RequiresMountsFor`. A gate lints the unit for the required directives. | G-QUIET | exists — all fourteen directives present in `pds/pds.service`; `pds/test/deploy_config_lint_test.mdk` lints for them | #2958 |
| D2 | `pds/Caddyfile` sets `header_up X-Forwarded-For {remote_host}`, HSTS, explicit timeouts, a request body limit at or above the PDS's own, and an access log; WebSocket upgrade for `subscribeRepos` verified live. A gate lints the file. | G-QUIET | missing — one `reverse_proxy` line; no gate mentions Caddy | #2959 |
| D3 | The running binary reports its build commit and source fingerprint on `--version` and in the startup line; binaries live under a versioned path with a symlink, and rollback is one documented command that has been run once. | G-QUIET | partial — `--version` and the startup banner both carry the commit (with `--stamp-build`; a plain `medaka build` reports a bare `pdsd 0.1.0`), and the versioned path plus symlink are documented — but the compiler fingerprint is deliberately omitted from the line, and "rollback run once" cannot be true before a first deploy | #2960 |
| D4 | What runs on the egress port (appview) and the relay port is specified: the software, its config, its own systemd unit, and its allow-list of destinations. | G-QUIET | exists — `pds/Caddyfile.egress` + `pds/pds-egress.service`, a second Caddy under its own unit with its own allow-list | #2961 |
| D5 | Backups run on a timer, land off-box encrypted, and a restore drill against the real deployment's backup has been run on this box (not only the CI fixture). | G-QUIET | partial — procedure rehearsed in CI; no timer, no off-box copy, no real-data drill | #2962 |
| D6 | `SIGTERM` drains: in-flight requests finish or are cut at a bound, the event log is left consistent, and the exit is logged. | G-ANNOUNCE | missing — the runtime installs no `SIGTERM` handler; stage-then-rename is the only protection | #2963 |
| D7 | A box-sharing rule is written: which gate/agent work may run beside the live service, and the service's cgroup weights make the rule survivable when it is broken. | G-QUIET | exists — `docs/ops/PDS-DEPLOY.md` § "Sharing the box" | #2958 |
| D8 | `docs/ops/PDS-DEPLOY.md` describes the tree as it stands (it still says the firehose is out of scope). | G-QUIET | current — the firehose line now reads landed; one stale paragraph (the proxy method axis, still described as default-deny after ruling R1 inverted it) found and fixed 2026-09-16 | #2970 |
| D9 | Compiler and PDS upgrades are separate procedures: rebuilding `pdsd` against a newer compiler is followed by the signing-parity and e2e gates before the swap. | G-ANNOUNCE | exists — [`PDS-RUNBOOK.md`](PDS-RUNBOOK.md) §7 is that procedure, and names both gates as required against the rebuilt binary in addition to the per-deploy set | #2972 |

### 2.E Observability

Sprint 4 closed most of this section. The running server now emits a version
banner, a config summary, the event-log recovery outcome, one line per request,
and a periodic stats line, and serves `/xrpc/_health` — all observed on a live
process 2026-09-16. **The one thing still missing is the one that matters when
Val is not looking at the terminal: nothing tells her the service is down**
(E5), and that needs her to pick a notification channel.

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| E1 | Every request produces one log line: method, route, status, duration, bytes, forwarded-for (never a token, never a body); a gate greps the log path for the secret-name list `lib_boundary_test.mdk` already enforces on strings. | G-QUIET | exists — `accessLogLine` (`pds/lib/accesslog.mdk`) with a six-field allow-list; `serve_e2e.sh` grades six line shapes and case 7b asserts no request-supplied secret reaches a line | #2964 |
| E2 | Startup logs the build commit, the config summary (did, handle, hostname, bind, port, trusted-proxy, appview), and the event-log recovery outcome (discarded / promoted / none). | G-QUIET | exists — banner, `serve: config …`, and `serve: event log recovery: …` all observed on a live process 2026-09-16 | #2964 |
| E3 | A health route (`/xrpc/_health`, as the official PDS serves) returns the version and is polled. | G-QUIET | partial — `/xrpc/_health` served and returns the version string; "and is polled" needs the deploy | #2965 |
| E4 | A periodic stats line: active connections, un-framed connections, subscribers, repo rev, blocks and blobs on disk. | G-ANNOUNCE | exists — `serve: stats active=… unframed=… subscriptions=… rev=… blocks=… blobs=…` observed on a live process 2026-09-16 | #2966 |
| E5 | A down or crash-looping service reaches Val within minutes: an `OnFailure=` unit or a probe on a timer, with the notification path named and tested by killing the service once. | G-QUIET | missing | #2967 |
| E6 | A panic in one handler is visible as such: exit code and the panic text land in journald, and the restart count is readable. | G-QUIET | exists in principle (`Restart=on-failure`, `exit(1)` on panic), unverified live | #2967 |
| E7 | Caddy's access log and certificate-renewal events are retained and readable beside the PDS log. | G-ANNOUNCE | exists — `pds/Caddyfile`'s `log { output stderr }` puts the access log in the journal, and Caddy's own `tls.obtain`/`tls.cache.maintenance` lines land there too, so `journalctl -u caddy -u pds` is one timeline. Both halves read on the live box 2026-09-20 | #2959 |

### 2.F Code quality

The library reads as carefully authored. The comment register is "why", not
"what"; constants carry their threat model; naming is consistent; the test
vehicle split is clean. The defects are small and concentrated: a few files
carry sprint names, issue numbers, and self-narration in comments, one export
is dead, the biggest files have no section index, and the repo's own slop
instruments do not look at `pds/` at all.

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| F1 | `test/comment_register_census.sh` and `test/slop_census.sh` scope `pds/*.mdk`, and report zero issue-number citations, zero emoji shouts, and zero self-narration in `pds/lib` and `pds/shell`. | G-ANNOUNCE | missing — both scripts now scope `pds/*.mdk`, but issue-number citations in `pds/lib` are reduced, not zero | #2968 |
| F2 | Register trims applied: `pds/lib/scalar.mdk`'s header keeps the numerical argument and loses the sprint-contract and "delete this comment" prose; `pds/lib/resource_limits.mdk`, `pds/lib/field.mdk`, `pds/lib/multiformats.mdk` cite constraints, not history. The dead `storeSessionCount` export removed; the raw `2^62-1` literal in `pds/lib/httpclient.mdk` named. | G-ANNOUNCE | done — all four headers rewritten, `storeSessionCount` gone, and the literal now reads `intMaxBound`. This row named `pds/lib/handlers.mdk` for that literal, which never held it | #2969 |
| F3 | Every file over ~700 lines carries a section index at the top. | G-ANNOUNCE | done — all seven files over 700 lines (`repo`, `handlers`, `httpclient`, `scalar`, `server_core`, `mst`, `shell/server`) carry one, in either the `-- ──` or `-- #` house spelling | #2969 |
| F4 | `medaka lint pds` clean under the ratcheted rule set, with every suppression carrying a reason. | G-ANNOUNCE | missing — measured 2026-09-20: 180 findings, every one `rule-duplicate-body` and every one under `pds/test/`. `pds/lib` and `pds/shell` are clean. #2969 closed without this clause being met; the live successor is #3143 | #2969 (successor #3143) |
| F5 | `docs/design/ATPROTO-PDS-DESIGN.md`'s status banner agrees with its own §7 (the firehose is landed) and a short architecture overview for a non-author exists, ordered README → `pds/serve.mdk` → `server_core` → `handlers` → `shell/server`. | G-ANNOUNCE | partial, differently — the banner now agrees with §7 on the firehose and `pds/README.md` carries the module reading order, but the banner's `#1962` sentence went stale when that gate moved to the merge tier | #2970 |
| F6 | A fresh agent, given only the docs, produces an architecture summary a maintainer grades as correct. | G-ANNOUNCE | unverified — #2970 closed with no grading recorded on it, which was its own acceptance criterion | #2970 |
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
| G4 | The nightly signing-parity run (`pds/test/signing_parity.sh` with `SIGNING_DEEP=1`) is confirmed green against the exact commit deployed, every deploy. | G-QUIET | procedural, mechanised — the merge-tier arm is now a required check (#1962 closed); `SIGNING_DEEP=1` stays nightly and `PDS-RUNBOOK.md` §3 carries the per-deploy confirmation | #1962 |

### 2.H Launch operations

| ID | Criterion | Gate | State | Issue |
|---|---|---|---|---|
| H1 | A launch runbook: the commit is tagged, the binary's provenance (D3) matches the tag, the gates that must be green are named and derived (not listed), the soak's start and its S0/S1-reset rule are written, and the rollback is the D3 command. | G-QUIET | drafted — [`PDS-RUNBOOK.md`](PDS-RUNBOOK.md); closes only once followed step by step for a real deploy | #2972 |
| H2 | The announcement text is drafted with its honest footnotes (§6) before the soak ends, and reviewed against the tree as it stands on the day. | G-ANNOUNCE | partial — the claim text and its TLS/runtime/reference-as-oracle footnotes are drafted, in §6 of this document, and [`PDS-RUNBOOK.md`](PDS-RUNBOOK.md) §8 directs the poster to use them verbatim. The second clause is undischarged by construction: it is the on-the-day re-read against the deployed commit | #2972 |
| H3 | An incident procedure: who does what when the service is down at an hour Val is asleep; the answer may be "it stays down until morning" but it is written. | G-ANNOUNCE | exists — [`PDS-RUNBOOK.md`](PDS-RUNBOOK.md) §6 answers it in the criterion's own words (single operator, no pager, it stays down until morning), with a discovery order and a roll-back-before-root-cause rule; §6a covers the breach case | #2972 |

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
`sprint-plan` cut, not a commitment to its slice list. **Struck rows have
landed** — nine sprints ran between 2026-09-12 and 2026-09-16, four of them
(crash durability and its follow-ups, cost, the G-QUIET residue) not on the
original list at all.

1. ~~**pds-the-app-can-use-us** — A1, A2, A3, A5, A6.~~ Landed.
2. ~~**pds-the-request-path-is-bounded** — B1, B2, B3, B5, B8, B11.~~ Landed.
3. ~~**pds-a-relay-can-index-us** — A4.~~ Landed.
4. ~~**pds-it-runs-on-the-box** — D1, D3, D4, D7, D8, E1, E2, E3.~~ Landed, **except the deploy itself**: this sprint was to have demonstrated it, and could not, because a deploy needs a hostname, DNS, a certificate and Val.
5. ~~**pds-we-can-see-it** — C1, C2, C4, C5, E4.~~ Landed, plus the three quadratics it uncovered.
6. **Remaining before G-QUIET closes.** #3087 (the `did:web` well-known serves no signing key — in flight), then the five that need Val or the box: D2's live half, D5/B16 custody, E5's channel, A8's transcript, H1's followed runbook. **Then the soak begins.**
7. **pds-a-stranger-can-poke-it** — B14 (the adversarial review, needs a running instance), then its fix round; B6, B7, B9, B10, D6, C7.
8. **pds-polished** — F1–F6.
9. **G-ANNOUNCE closes.** Soak begins.
10. **pds-the-real-account** — A9, A10, A11, G2, #2609's rehearsals.
11. **G-MIGRATE closes.**

⚠️ Items 7 and 8 are ordered for the *announce* gate, not the quiet one. The
four open S1s (#2773, #2950, #2951, #3048) all sit in item 7 and none of them
blocks the deploy — do not let them delay G-QUIET.

## 5. Rulings taken (Val; R1-R4 2026-09-12, R5 2026-09-16)

| # | Ruling | Where it is recorded |
|---|---|---|
| **R1** | **Proxy method policy inverts.** `pds/lib/proxy.mdk` was default-deny on the method axis by the #2912 ruling. The METHOD axis becomes default-allow for `app.bsky.*` / `chat.bsky.*` with an explicit protected list derived from the official `PROTECTED_METHODS`; the AUDIENCE axis stays default-deny (the configured appview DID and the chat service DID only). The confused-deputy defense lives on the audience axis; the method axis only ever bounded which reads the appview would answer. | #2935 |
| **R2** | **"Box lost = identity lost" is accepted for the `did:web` account** through G-QUIET and G-ANNOUNCE, given the custody criteria (D5/B16). It is the price of L1's ordering and it expires at G-MIGRATE, where off-box rotation keys invert it. | #2962, #2609 |
| **R3** | **The KDF residual is accepted.** 3000 PBKDF2 iterations stand for a single-owner server whose password never leaves its owner; the attacker who holds the credential file also holds the signing key, so a higher work factor buys nothing against the threat that reaches the file. Revisit on a second account or a custody split. | comment on #2659 |
| **R4** | **The read-derived S0/S1 candidates are filed now** at their candidate severities with `needs-repro`; the sprint that reproduces them relabels or closes. An unfiled S0 candidate is the shape #518 sat in. | #2946, #2947, #2952 |
| **R5** | **`validate: true` is ACCEPTED, not refused** (2026-09-16, taken against a live server). This tree implements no lexicon validation and the flag was refused outright, on the reasoning that accepting it would report a validation that never happened. That reasoning does not survive `writeOutput`/`batchResult`, which report `validationStatus: "unknown"` on **every** write — a client is already told the record was stored ungraded, so the refusal bought no honesty the response was not already delivering. It cost the client bar instead: the official Bluesky app sends `validate: true` on `applyWrites`, so posting and editing a profile both returned `400` from the first live deploy. **L2 makes that app the bar, so the two decisions could not both stand.** Implementing validation is the follow-up, due before G-ANNOUNCE. | #3098, `admitValidateFlag` |

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
