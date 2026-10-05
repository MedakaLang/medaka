# PDS B14 running-instance attack list

This is the written attack list required by `PDS-LAUNCH-PLAN.md` criterion B14.
It is an execution checklist, not a claim that the listed properties pass. A
fresh reviewer must run it against an isolated PDS instance on this box at the
exact commit named in the report. The reviewer did not write the request-path
change under review.

The instance must use a fresh temporary data directory, temporary credentials,
loopback bind, and an ephemeral port. Destructive, resource-exhaustion, and
secret-mode probes target only that instance. Do not probe the public service,
its account, or its data. Keep one unrelated authenticated read available as a
liveness probe during every denial-of-service test.

For every numbered item, the report records the exact request or command, the
observed response and post-probe liveness, and one of `PASS`, `FINDING`, or
`NOT EXERCISABLE`. `NOT EXERCISABLE` requires concrete evidence and is not a
pass. Every finding needs a GitHub issue with `ws:pds` and a severity label, or
an explicit dated ruling linked from the report. Nothing above S2 may remain
open when B14 is signed off.

For every S0 or S1 finding, the report states whether an unauthenticated
client can reach it, with the evidence. Under the soak ruling R7 on #1697, a
defect a stranger can reach restarts the one-week soak clock, and one only
the account owner can reach does not.

## Rulings on rows 9, 14 and 22

The 2026-09-18 run marked these three `NOT EXERCISABLE`. Val ruled on them on
2026-09-29 (#2945):

- **Row 9, independent signature verification: accepted by ruling.** The
  Bluesky relay consumes this PDS's commits, and its head is byte-identical to
  ours. The reviewer records the relay's current head for the account beside
  the live server's, on the day, and does not re-derive signatures. The other
  firehose attacks in row 9 still run.
- **Row 14, signing parity: exercisable.** `PDS-RUNBOOK.md` §3 requires the
  `SIGNING_DEEP=1` nightly to be green on the exact deployed commit. The
  reviewer links that run. If there is none, that is a `FINDING` against the
  deploy.
- **Row 22, kill during commit: accepted by ruling.** Random termination
  cannot target a commit phase, and a phase-injection hook in the production
  binary is declined. The row rests on `pds/test/store_persistence_test.mdk`
  and the stage-then-rename recovery tests. The reviewer confirms those are
  green at the reviewed commit.

## Exposure-ledger attacks

These rows mirror the public-exposure table in issue #1697.

1. **Header-phase accounting.** Hold more than `maxUnframedConnections`
   partial headers open, then send a complete health/read request. Check that
   the server remains live, stalled sockets retire on the header timeout, and
   the observed refusal boundary matches the documented global admission gate.
2. **Body-phase accounting.** Hold framed requests open while dribbling or
   stopping their bodies. Mix stalled and legitimately slow bodies. Check that
   no-progress bodies retire, a progressing upload completes, and unrelated
   reads keep answering.
3. **Cost of the cap.** From one source, fill the unframed admission gate and
   measure the success/refusal ratio for new legitimate requests. #2816 (the
   global gate as a cheap accept-time denial) is closed as fixed: confirm the
   fix holds, and file any cheaper or broader denial as a finding.
4. **Secret file modes.** Start with each signing key, token secret, credential,
   and password file widened beyond `0600`; startup must refuse before serving.
   Start with private inputs and inspect every secret the server creates.
5. **KDF, rehash, and token-secret admission.** Try a wrong password, an old
   iteration-count credential, low-diversity token secrets, and a 32-byte
   high-diversity secret. A failed login must not rewrite the credential; a
   successful old-cost login must rehash; weak admission must fail loudly.
6. **Key generation and at-rest handling.** Run key generation into fresh paths
   and into a configuration with one invalid destination. Check all-or-nothing
   behavior, `0600` secrets, and that stdout contains only destination/mode
   confirmations plus the public key and DID, never secret bytes.
7. **Loopback-only listener and removed flags.** The listen address is fixed at
   `127.0.0.1` and is not a flag. Confirm the listener binds nowhere else, and
   that `--bind`, `--data`, `--key`, `--token-secret` and `--password-file`
   are refused as unknown flags before any secret is read or generated. Check
   any other listener the instance opens the same way, rather than trusting
   its configuration's intent (#3096).
8. **Unproxied peer identity.** Confirm that an untrusted loopback deployment
   does not pretend to distinguish callers. Attack the shared rate bucket and
   compare the observed process-wide behavior with the accepted-risk ruling in
   #2757.
9. **Firehose.** Subscribe with a raw WebSocket client; provoke fragmentation,
   invalid close codes, oversized messages, more than 200 operations, and more
   than the subscription ceiling. Verify valid commit signatures independently
   and ensure malformed peers cannot stall unrelated HTTP traffic.
10. **Appview proxying.** Probe unauthenticated forwarding, protected and
    unprotected methods, mixed-case method spellings, unapproved audiences,
    response framing, slow/unreachable egress, and more than the proxy census.
    No service token may be minted for an unauthenticated caller, and an egress
    stall must not wedge unrelated requests.
11. **Backup and restore.** Stop the isolated instance after a live export,
    copy its data and temporary secrets, restore to a second directory, and
    start a second instance. Compare repository bytes, blobs and MIME types;
    authenticate and make a new signed write on the restored copy.
12. **Block-store growth.** Create and replace records and blobs, observe
    unreferenced block growth, and confirm it is the known loud residual in
    #2572. Unknown top-level residue must be preserved; recognized shard/leaf
    structural collisions must refuse startup rather than discard data.
13. **MST range and incremental reads.** Read a large synthetic repository in
    small chunks and request narrow record pages. Check byte identity and
    liveness. #2773 (listing walked every MST path per page) is closed as
    fixed: a narrow page must not cost in proportion to the repository. MST
    mutation cost is still O(n) (#3581, open).
14. **Signing-parity oracle.** Verify the latest externally graded signing
    parity result required before deployment. If it cannot be rerun in this
    review, record the exact run and age; do not substitute a self-generated
    signature corpus.
15. **App-password revocability.** Confirm the current account-password-only
    surface and the existing ruling that app-password revocation is outside
    this exposure gate. File any reachable app-password behavior as a finding.

## Launch-plan B2--B11 attacks

Rows already exercised above still get an explicit result here; cross-reference
the evidence rather than silently merging criteria.

16. **B2, JSON depth.** Send increasingly deep JSON, including the largest
    practical body below the request ceiling, to `createSession` and an
    authenticated JSON route. The server must answer or refuse and remain live;
    characterize the actual native limit rather than assuming an interpreter
    limit.
17. **B3, encode/decode depth parity.** Attempt to write records immediately
    below and above the DAG-CBOR depth limit. A refused record must not advance
    the repo; every accepted record must be readable after restart.
18. **B4, blob response hardening.** Store benign bytes as `text/html`, fetch
    them, and require both `X-Content-Type-Options: nosniff` and
    `Content-Disposition: attachment` without corrupting the body.
19. **B5, forwarded-client bounds.** Send duplicate, malformed, many-token, and
    near/over-limit `X-Forwarded-For` headers directly to the trusted-proxy
    listener. Also inspect the Caddy rule that overwrites the client value. An
    over-limit header must be rejected before expensive splitting or decoding.
20. **B6, rate-table bound.** Present many distinct forwarded identities and
    sample RSS plus response latency. Determine whether entries are capped,
    expired, or retained. #2950 is closed as fixed with a per-window identity
    cap: confirm the cap holds and that exceeding it does not refuse the owner.
21. **B7, concurrent request-body memory.** Hold as many near-ceiling bodies as
    the isolated box can safely sustain, sample RSS, and keep the liveness probe
    running. Extrapolate to the 256-connection ceiling and compare with the
    service `MemoryMax`; do not exhaust the host. #2951 (a tagged word per
    body byte) is closed as fixed; #3605 (upload-burst memory) is open,
    needs-repro.
22. **B8, kill during commit.** Repeatedly kill the isolated server at different
    write phases, restart it, and require a loadable repository whose head
    references durable blocks. Never run this against the public data directory.
23. **B9, token and credential comparison.** Exercise equal, unequal, prefix,
    suffix, and length-mismatched secrets through login and authenticated
    routes. Pair live accept/reject parity with structural/timing evidence that
    `credential.mdk` and `jwt.mdk` use the shared constant-time primitive.
24. **B10, session lifetime and replay.** Rotate a refresh token, replay the old
    token, and inspect whether the family is revoked. Advance or control time
    where the harness permits and test absolute lifetime. #2943 (no absolute
    session lifetime) is closed as fixed: confirm a refresh chain now ends.
25. **B11, private input modes.** Repeat item 4 specifically for
    `<data>/credential` and `secrets/password`; both widened files must refuse
    startup, while `0600` inputs must start normally.

## Changes since the 2026-09-18 run

The last full run reviewed `01c98b92f`. The review that consumes this list
also attacks what changed since then. Every removed rejection arm is checked
under the quieter-failure rule: a path that previously returned nothing must
not begin returning an ungraded value.

26. **The write path (#3577).** `prepareRefusal` ordering, body-level
    `__proto__` refusal in `decodeProcedure`, the held-blob check, the
    MST-diff commit event, the linear lexjson duplicate-key check, and
    `updateHandle` with its response marker and its per-DID limit (#3578,
    fixed). Known open divergences are #3579–#3582.
27. **Diff-based block persistence (#3596).** A commit writes only the blocks
    it adds. Interrupt, fail, and repeat writes on the isolated instance, then
    restart: the head must reference durable blocks, and a failed persist must
    never publish a store that later diffs against unwritten blocks.
28. **WebSocket strictness (#3536, fixed).** Repeat row 9's malformed-frame
    attacks, including a negative offset, against the stricter parser.
29. **Proxied-call allowance (#3611).** The per-window allowance for proxied
    calls is 300 and only an authenticated caller can spend it. Confirm an
    unauthenticated caller cannot charge it, and that exhausting it does not
    affect unrelated routes.
30. **Per-request memory (#3619).** Flood unauthenticated reads and refused
    requests (400, 404, 429) and sample RSS. It must level off. Before #3619
    every request grew memory by about its access-log line.
31. **Fixed data and secrets layout (#3650).** The server reads `secrets/`
    and serves `data/` under its working directory. Start it with a
    `secrets/password` beside an existing `data/credential` (must refuse),
    with no credential and no password (must refuse), and with symlinked or
    missing `secrets/` entries. #3645 (a symlink inside `data/` is followed)
    and #3647 (a dangling symlink probed by `fileExists` panics) are known.
32. **The effects manifest (#3650).** `medaka manifest pds/serve.mdk --fn
    serve` at the reviewed commit must match `pds/capabilities/serve.toml`.
    Look for anything the running server does that the manifest does not
    name: another address, a write outside `data/`, a signature other than a
    commit or a service-auth token, a minted token other than access or
    refresh.
33. **Login cost and lockout.** Concurrent wrong-password logins against the
    derivation cap (#3398). #3399 (four wrong logins could fill the cap and
    lock the owner out) is closed as fixed: confirm a stranger cannot lock the
    owner out, and measure for how long any refusal lasts.
