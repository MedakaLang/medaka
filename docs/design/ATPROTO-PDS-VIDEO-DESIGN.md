# atproto PDS: accepting video uploads

**Status:** proposed design. Nothing in this document is implemented, and the
decisions in §6 are Val's to make. It extends [`ATPROTO-PDS-DESIGN.md`](ATPROTO-PDS-DESIGN.md)
§4.5 and lifts one of its stated non-goals ("no inbound verifier through 0.1.0").

## 1. The problem

Uploading a video through a Bluesky client against this PDS fails with
`aud names a service this server does not mint credentials for`. That is the
service-auth audience gate (§4.5, ruling R1) working as designed: it is the
first of three independent gates a video upload has to pass, and the second and
third are behind it.

This PDS does not transcode, and will not. The official client sends the video
to `video.bsky.app`, which transcodes it and stores the result **on the user's
PDS**. The PDS's part is to hand the client a credential for that, and then to
accept the video service's upload when it arrives.

## 2. The official flow

Verified 2026-10-21 against the Bluesky docs source
(`bluesky-social/bsky-docs`, `docs/tutorials/video.mdx`, `main`) and the
official PDS source (`bluesky-social/atproto`, `packages/pds`,
`packages/xrpc-server/src/auth.ts`, `main`):

1. Client calls **its own PDS**: `com.atproto.server.getServiceAuth` with
   `aud = did:web:<pds host>`, `lxm = com.atproto.repo.uploadBlob`,
   `exp = now + 30 min`. The audience is the PDS's own DID, not the video
   service's.
2. Client `POST`s the raw video to
   `https://video.bsky.app/xrpc/app.bsky.video.uploadVideo?did=<user did>&name=<file>`
   with `Authorization: Bearer <that token>`.
3. Client polls `app.bsky.video.getJobStatus` on `video.bsky.app` until a
   `blob` ref appears.
4. The video service, holding the token, calls the user's PDS
   `com.atproto.repo.uploadBlob` with it, and the result is the `blob` ref.

Step 4 is stated in the docs ("saves the optimised video to the PDS using the
service token") and is consistent with the official PDS source, but I did not
read the video service's own code, which is not public as far as I found. How
it locates the PDS (the DID document's `#atproto_pds` endpoint, which this
server already serves, `pds/lib/handlers.mdk:2120`) is inferred.

What the official PDS does with that token on `uploadBlob`:

- `authorizationOrUserServiceAuth` takes the service path when the token has an
  `lxm` claim, and the bearer path otherwise. A token with `lxm` is refused on
  the bearer path ("Malformed token").
- `verifyServiceJwt` requires `aud` equal to the PDS DID (or the entryway's),
  `lxm` equal to the route's NSID (a missing `lxm` is rejected when one is
  expected), `exp` in the future, `iss` a DID, and a signature that verifies
  under the `atproto` key of `iss`'s DID document, with one forced-refresh retry
  for a rotated key. There is **no `jti` or replay check**.
- The credential is `{type: 'user_service_auth', did: iss}`. The
  scope-authorize callback does not run on this path.
- The default blob limit is `5 * 1024 * 1024` (`PDS_BLOB_UPLOAD_LIMIT`),
  the same as ours. A video-hosting deployment has to raise it.

## 3. Why it fails here, three gates deep

| # | Gate | Where | Today |
|---|---|---|---|
| G1 | Mint a token for `did:web:<own host>` | `admitServiceAudience`, `pds/lib/server_core.mdk` | refused: the audience set is the proxy table only |
| G2 | Accept that token on `uploadBlob` | `resolveCredential`, `verifiedCredential` | no inbound verifier; only HS256 session tokens verify |
| G3 | Accept a video-sized body | `maxBlobBytes` (`pds/lib/resource_limits.mdk`), `http.maxRawBodyBytes` (`stdlib/http.mdk`), `maxInFlightRequestBytes` | 5 MiB per blob, and a 32 MiB in-flight budget under `MemoryMax=512M` |

The error you saw is G1. It could come from the step-1 call or from a second
call I suspect the app makes (§6, Q3); I have not seen which `aud` was sent.

## 4. Design

### D1. Mint-only audiences, an `aud` to allowed-`lxm` table

Today the set of audiences a credential may be minted for is the proxy table,
and a proxy row is all-or-none with an egress port. A video token is not a
proxied call, so it has no egress. Separate the two ideas:

- **Own DID, built in.** `did:web:<account hostname>` is admitted without any
  flag, for exactly one method: `com.atproto.repo.uploadBlob`. Nothing is
  configured, and the row cannot be turned into a confused-deputy hole because
  a token minted for this server is only spendable on this server.
- **Operator rows, opt-in.** A new repeatable flag adds an audience with the set
  of methods it may be minted for and **no egress port** (for example
  `did:web:video.bsky.app` limited to `app.bsky.video.getUploadLimits`, if Q3
  holds). Default-deny is unchanged: an audience nobody configured is refused.
- `lxm` stays mandatory on these rows. A method-less token is refused for every
  mint-only audience, which is stricter than the official 60 s method-less
  window and costs nothing (the video flow always names `lxm`).
- `exp` keeps the existing official bounds (≤ 1 hour, ≤ 60 s method-less).

The decision stays in the pure core (`admitServiceAudience` returns a value;
the shell signs what it is given), as today.

### D2. An inbound service-auth verifier, scoped to a route allowlist

A new pure module (`pds/lib/service_jwt_verify.mdk`, name open) that verifies an
ES256K service JWT against **this server's own account key**:

- It takes the account's public key, the account DID, this server's DID, the
  route's NSID and `now`, and returns a verified claim set or a typed refusal.
  No I/O and no DID resolution: this server hosts one account and holds its key,
  so the issuer's key is not a lookup. This removes the official verifier's
  rotation retry, which has nothing to retry against here.
- Checks, in the official order: three-part compact form; `alg` is exactly
  `ES256K` (never `none`, never `HS256`); `typ` is not an access, refresh or
  DPoP type; payload shape; `exp` not past; `aud` equals this server's DID,
  exactly (bare, as minted); `lxm` present and equal to the route's NSID;
  `iss` equals the account DID; then the P1363 signature over the signing input.
  Signature last, as in the official verifier, so cheap refusals do not pay for
  a verify.
- It uses only public inputs. It is outside P15's constant-time perimeter and
  must not share code with the signing path.
- **Replay.** The official verifier checks no `jti`. This design matches that
  and says so in the docs, rather than adding a cache the peer does not have.
  The bound on a leaked token is the same as upstream's: one method, ≤ 1 hour.

It plugs in at the credential seam, not beside it:

- `Credential` gains a constructor for a verified service credential that
  carries a DID and **no session fingerprint**. A service token is not a
  session: it cannot be refreshed, listed, or revoked by logout.
- Only routes on an explicit allowlist (initially `com.atproto.repo.uploadBlob`
  alone) consult the service verifier, and only for a token that carries `lxm`.
  Every other gated route keeps the bearer-only path, and a service token
  presented there is refused as `InvalidToken`, as upstream does. Because
  session-only routes (logout, refresh, getSession) take a session fingerprint,
  a service credential cannot satisfy them by construction, not by a check.
- `auth_seam_test.mdk:547` pins the access-gated route list; that pin gains one
  column (which credential kinds the route accepts), and the test fails if a
  route outside the allowlist accepts a service credential.

### D3. A per-route body cap, decoupled from the framing constant

`maxBlobBytes` already says it is distinct from `http.maxRawBodyBytes` and
"today equals the framing ceiling because nothing yet needs them to diverge".
Video is the thing that needs them to diverge.

- Replace the global `maxRawBodyBytes` with a per-endpoint input policy for the
  one route that needs more. `stdlib/http.mdk` is shared; changing its constant
  would raise the cap for every consumer, so the PDS passes its own number to
  the codec instead.
- The cap becomes an operator flag (default stays 5 MiB, so a deployment that
  does not opt in is unchanged byte for byte).
- `maxInFlightRequestBytes` (32 MiB) is smaller than one video body. A
  connection reserves the whole `Content-Length` up front
  (`readBufferTarget`), so as written a video upload would wait on the budget
  forever. The budget has to cover at least one full-cap upload plus ordinary
  traffic, and the doc must state the arithmetic.

**What this costs, measured and not.**

- *Hashing is not the problem.* Pure-Medaka SHA-256 over a 20 MiB buffer,
  including building that buffer as a 160 MB `Array Int`, took 0.44 s wall
  (0.22 s user), native build, this box, 2026-10-21. So hashing runs well above
  50 MiB/s and a 100 MiB blob stalls the single reactor thread for roughly 2 s
  at worst. That is a stall (P6 accepts these, with numbers), not a blocker. An
  isolated hash-only measurement belongs in the slice.
- *Memory is the problem.* `resource_limits.mdk` records a 32 MiB in-flight
  budget costing 88.6 MB VmRSS at saturation (about 2.8x), against
  `MemoryMax=512M`, and the egress side measures a body at "one tagged word per
  byte". A 50 MiB inbound body is therefore on the order of 140 MB live while
  it accumulates, and then a second copy when it is packed and admitted. I did
  not measure the inbound figure for a single large body. The slice measures it
  before choosing the number.
- *The `Store` keeps every blob in memory.* Blobs are read from disk once at
  startup and served from memory (`blobFileRead`, `applyGetBlob`), so resident
  memory grows with the account's blob bytes: the 100 MiB account cap (the
  `maxAccountBlobBytes` figure, "pending real storage-cost numbers") is also a
  100 MiB resident-set floor. A handful of videos reaches it.

### D4. Memory model: stay in memory first (recommended), disk-backed reads later

- **Option A (chosen, Q1): keep blobs in the `Store`, raise the caps, size
  `MemoryMax` for it.** Small change, no new seam, and it keeps P14 (the pure
  `handle` performs no I/O). The cost is stated up front: the account cap is a
  RAM budget, so an operator sizes it knowing that. It also costs a restart
  that reads every blob before binding, and an over-budget process is killed
  whole by the cgroup. It fits occasional video only.
- **Option B: a disk-backed blob read.** The `Store` holds only the index
  (CID, MIME, size) and `getBlob` reads the file. That needs the response to
  carry a lazy body or the shell to resolve one, which touches P14's seam and
  the `getBlob` all-engine story. It is the right end state if videos are the
  main use, and a much larger change. Not part of this sprint unless Val rules
  otherwise.

Either way, one existing gap gets worse and should be named in the sprint, not
silently inherited: **nothing collects an unreferenced blob (#2572)**. A video
upload the user abandons leaves its transcoded file on disk and in memory until
removed by hand, and a video is 10 to 100 times the size of an image.

### D5. Non-goals

Transcoding, serving or streaming video, HLS, captions; `did:plc` issuer
resolution (single-account `iss` equality is sufficient while one account is
hosted); a replay cache; chat or any other service-auth consumer. The inbound
verifier is built so a second route can be added to the allowlist later, but no
second route is added here.

## 5. Evidence plan: an external answer key

Following P8, the official implementation grades ours. Two directions:

- **Inbound (new).** Tokens produced by the pinned official
  `@atproto/xrpc-server` `createServiceJwt` (and a few hand-tampered variants:
  wrong `aud`, wrong `lxm`, missing `lxm`, expired, wrong `iss`, `alg: none`,
  `alg: HS256` signed with a guessable secret, a flipped signature bit) become a
  corpus; ours must accept and reject exactly the rows the official
  `verifyJwt` does. This is the mirror of `pds/tools/check_pds_service_jwt.mjs`,
  which already grades the minting direction against the official reference.
- **Outbound (extend).** The existing mint corpus gains rows for the own-DID
  audience and the `lxm` allowlist.
- **End to end.** A fake video service in the serve harness
  (`pds/test/serve_client_main.mdk`'s neighbours): `getServiceAuth` with
  `aud=did:web:<host>`, then a raw `POST` to `uploadBlob` carrying that token
  and a body above 5 MiB, then `getBlob` returns the same bytes. Plus the
  negative path: the same token on `createRecord` is refused.
- **Real client.** One manual run with an official client against a deployed
  instance, recorded in `docs/ops/PDS-CONFORMANCE-WALKTHROUGH.md`. Nothing here
  can prove the video service's behaviour (step 4 of §2) except that run.

## 6. Decisions for Val, and what I could not verify

Asked one at a time, in this order:

1. **Q1: Memory model. RESOLVED (Val, 2026-10-21): Option A.** Blobs stay in
   the `Store`. The deployment's expected use is an occasional video, which is
   what makes a RAM-sized account cap acceptable; regular video use would
   reopen this and make B the right answer. B is filed as a follow-up, not
   built here.
2. **Q2: Numbers. RESOLVED (Val, 2026-10-21): not needed for the first
   sprint.** Her videos are under 2 MB, inside today's 5 MiB per-blob cap, so
   G3 does not bite and D3 is deferred. If it is taken up later, the agreed
   starting point is a 50 MiB per-blob cap, a 250 MiB account cap and
   `MemoryMax=1G`, confirmed by the single-large-body measurement first. The
   assumption that the transcoded output stays near the source size is
   unverified: the video service re-encodes, and 5 MiB leaves about 2.5x
   headroom over a 2 MB source. The app's source limits (about 100 MB, 3
   minutes) are from memory and unchecked.
3. **Q3: The second audience. RESOLVED (Val, 2026-10-21): follow the
   evidence.** Slice 1 captures the real requests first; if a client does ask
   for `did:web:video.bsky.app`, the opt-in mint-only row (D1) is built, limited
   to the methods the capture shows, with no egress. If it does not, no row is
   added. The belief that follows is the question as it was put to her: I believe the app also calls `getServiceAuth`
   with `aud=did:web:video.bsky.app` and `lxm=app.bsky.video.getUploadLimits` before
   the upload. That is from memory and **unverified**; the tutorial above does
   not show it. If true, G1 fails on that call first, and the mint-only operator
   row in D1 is needed, not optional. Slice 1 starts by capturing the real
   requests a client sends, so this is settled by evidence.
4. **Q4: Always-on own-DID audience, or an operator flag. RESOLVED (Val,
   2026-10-21): always on, `uploadBlob` only, no flag.** It widens nothing a
   session holder could not already do.

All four questions are resolved; the design is ready to be cut into a sprint.

## 7. Proposed slices

Serial; each ends at a state that is shippable by itself. With Q1 and Q2
resolved the first sprint is slices 1, 2 and 4.

1. **Capture and mint side.** Log and pin the real client request sequence;
   own-DID audience (D1), mint-only operator rows, flags, outbound corpus rows.
   After this, a client gets a token and fails later, at `uploadBlob`.
2. **Inbound verifier.** `service_jwt_verify` (D2), the `Credential` variant,
   the route allowlist, the inbound corpus and its Node grader. After this, a
   small video-service-style upload works end to end.
3. **Body cap and budget. DEFERRED (Q2).** Per-route policy (D3), the flag,
   the in-flight budget, the measured single-large-body RSS number,
   `pds.service` memory notes. Needed only for videos above about 5 MiB; not
   in the first sprint. Slice 2's end-to-end test still uploads a body just
   under 5 MiB so the headroom claim is exercised.
4. **Docs and claims.** `pds/README.md` route table, `docs/ops/PDS-DEPLOY.md`,
   the claims page (the "no inbound verifier" statement is retired), the
   conformance walkthrough with the real-client run, #2572 cross-reference.

Slices 1 and 2 are the security-sensitive pair and should be reviewed together
against the confused-deputy argument in §4.5.
