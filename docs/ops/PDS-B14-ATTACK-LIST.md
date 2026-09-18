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
   measure the success/refusal ratio for new legitimate requests. Confirm the
   known global-gate limitation remains loud and matches open issue #2816; file
   any cheaper or broader denial separately.
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
7. **Bind, proxy, and operator refusal.** Exercise loopback spellings and unsafe
   non-loopback spellings with and without authentication and trusted-proxy
   configuration. Refusal must happen before secrets are read or generated.
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
    liveness, and distinguish the closed `readMore` copy problem from open MST
    range-cost issue #2773.
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
    expired, or retained. Treat the known missing bound (#2950) as a finding
    baseline and file any worse behavior separately.
21. **B7, concurrent request-body memory.** Hold as many near-ceiling bodies as
    the isolated box can safely sustain, sample RSS, and keep the liveness probe
    running. Extrapolate to the 256-connection ceiling and compare with the
    service `MemoryMax`; do not exhaust the host. Confirm or refine #2951.
22. **B8, kill during commit.** Repeatedly kill the isolated server at different
    write phases, restart it, and require a loadable repository whose head
    references durable blocks. Never run this against the public data directory.
23. **B9, token and credential comparison.** Exercise equal, unequal, prefix,
    suffix, and length-mismatched secrets through login and authenticated
    routes. Pair live accept/reject parity with structural/timing evidence that
    `credential.mdk` and `jwt.mdk` use the shared constant-time primitive.
24. **B10, session lifetime and replay.** Rotate a refresh token, replay the old
    token, and inspect whether the family is revoked. Advance or control time
    where the harness permits and test absolute lifetime. Confirm the known
    missing controls in #2943 without weakening the observed rejection path.
25. **B11, private input modes.** Repeat item 4 specifically for
    `<data>/credential` and `--password-file`; both widened files must refuse
    startup, while `0600` inputs must start normally.

## Request-path regression focus

The review that consumes this list must additionally attack the sprint's
changed request path: mixed-case transfer codings, conflicting or duplicate
framing fields, header/chunk/body ceilings, truncated incremental responses,
and authentication with equal-length and unequal-length secret candidates.
Every removed rejection arm is checked under the quieter-failure rule: a path
that previously returned nothing must not begin returning an ungraded value.
