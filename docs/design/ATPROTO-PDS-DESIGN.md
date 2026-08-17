# A self-hosted atproto PDS in Medaka

**Status:** DESIGN (2026-08-17, collaborative) — nothing built. Phases 0–2 are
unblocked **today**; Phase 3 onward is gated on the Async v2 runtime arc (#500)
and the graded-interfaces arc (#820). No tracking issues filed yet.

A Personal Data Server for the AT Protocol, written in Medaka, hosted on the
dev box behind Caddy. This is simultaneously the most demanding Medaka program
yet attempted — it stresses effects, the async runtime, `byteparser`/`bytebuilder`,
and numeric code in ways self-hosting the compiler does not — and a system holding
a real social identity, so the correctness bar is higher than the compiler's.

---

## 0. Locked decisions

| # | Decision | Rationale |
|---|---|---|
| **P1** | **Own top-level project `pds/`**, with its own `medaka.toml`, mirroring `sqlite/` and `gzip/`. Not stdlib. | Those two are the precedent for a substantial Medaka subproject that consumes stdlib without joining it. Keeps the prelude blast radius at zero (a `stdlib/` change forces seed re-mint + fixpoint re-validation; a `pds/` change forces nothing). Graduation of individual modules to `stdlib/` is a later question — see §7 Q1. |
| **P2** | **`did:web` first; `did:plc` migration deferred to Phase 6.** | `did:web` is a static JSON document at `/.well-known/did.json` — no PLC directory, no genesis operation, no rotation-key management. It cuts an entire crypto+protocol subsystem out of the critical path. The existing `did:plc:…` profile is **not** migratable to `did:web`, so Phase 6 remains genuinely necessary to reach the real handle; it is deferred, not cancelled. |
| **P3** | **Standalone repo first; firehose (`com.atproto.sync.subscribeRepos`) deferred to Phase 5.** | Full network participation is a strict superset of a correct repo, and it is additive: WebSocket framing and event emission bolt onto a repo layer that already produces correct CIDs. Sequencing it second means the highest-risk work (MST, DAG-CBOR determinism) gets validated against an oracle before anything depends on it being right. |
| **P4** | **Crypto is pure Medaka — SHA-256 and secp256k1 both.** Field arithmetic on 10 × 26-bit limbs (P10). | Chosen for the dogfooding, not merely accepted despite the cost: this is the most numerically demanding code anyone would have written in Medaka, and it arrives with an external oracle that says immediately when the *compiler* is wrong (§4.1). Made tractable by one property: **atproto requires deterministic signing behaviour and low-S normalization, and RFC 6979 makes ECDSA output byte-reproducible** — so signing is gradeable by *golden diff against published vectors*, not by a probabilistic property test. That converts the scariest part of this project into precisely the kind of differential gate this repo is built around. See §4. |
| **P5** | **TLS is never implemented in Medaka. Caddy terminates.** | Caddy obtains and renews the Let's Encrypt certificate automatically and reverse-proxies plaintext HTTP to the Medaka process on localhost — which is what the official self-hosting guidance recommends regardless of implementation language. Cost to us: approximately zero. Writing TLS would be a larger and far more dangerous project than the entire rest of this document. |
| **P6** | **Do NOT build a bespoke event loop. The PDS is a *consumer* of the #500 arc, not a fork of it.** | `docs/design/ASYNC-RUNTIME-DESIGN.md` already specifies the reactor, and its A2 extern set (`ioPoll` over `poll(2)`, `netSetNonblock`, `netTry{Accept,Recv,Send}`) is exactly and only what a server needs. Duplicating it inside `pds/` would produce a second scheduler with none of the guarantees G1–G9 that design carries, and would make the PDS the reason the real one can never land. |
| **P7** | **Block store is flat sharded files on disk**, CID → bytes, not `sqlite/`. | A block store is a pure key/value map with content-addressed immutable keys — the one workload where a filesystem is already the right database. Pressing the in-tree SQLite engine into service would add a large dependency, a write-path risk, and a schema, in exchange for nothing. |
| **P8** | **The official `bluesky-social/pds` runs alongside as an ORACLE.** Every CID, every CAR byte, every signature is diffed against it. | This is the repo's own differential-gate methodology applied to a protocol instead of a compiler. It is also the only defence that works against the failure mode that actually matters here (§5). |
| **P9** | **Native-only.** The server does not run under `medaka run` or wasm. | The interpreter implements zero net externs (the T7 family in `test/CAPABILITY-EXCEPTIONS.txt`) and wasm rejects net as PERMANENT. This costs less than it sounds: see the §3 split — the entire correctness-critical core is engine-portable and doctestable, and only the socket shell is native-bound. |
| **P10** | **Field arithmetic uses 10 limbs of 26 bits — `libsecp256k1`'s 32-bit field layout.** | Resolved from §7 Q2. Decided on *reviewability against a published reference*, not on speed: it is the layout a widely-audited implementation uses, so the reduction modulo `p = 2^256 - 2^32 - 977` and its magnitude analysis can be followed rather than derived from scratch — which is the part of this project where inventing something is least defensible. It also happens to need ~2.5× fewer partial products than a 16-bit layout, with ~6 bits of headroom under the 63-bit fixnum ceiling. See §4. |
| **P11** | **The crypto modules graduate to `stdlib/` once proven, not before.** | Val's call. SHA-256 and base58 are plainly general-purpose. But anything the compiler imports forces a seed re-mint and fixpoint re-validation on every change, and these modules will churn heavily while being written. Graduation criteria, so "proven" is not a vibe: the full vector suites of G1 pass, the API has been stable across a release, and a deliberate decision has been taken about which of `field`/`scalar` stay private to `pds/`. |
| **P12** | **Firehose events are persisted to a bounded append-only log with a ~72-hour retention window** (Phase 5). | Resolved from §7 Q3 by looking at what the ecosystem actually does rather than deciding a priori: the relay backfill window has always been ~72 hours, and `getRepo` covers full resynchronization independently of it. For a single-user PDS, 72 hours is a few hundred events — small enough that the interesting question is durability, not size. On-disk rather than in-memory specifically so a process restart does not invalidate a connected relay's cursor and force a full resync. |
| **P13** | **Phase 4.5 ships a read-only web view of the repo**, served from the same process. | Val's call. Cheap on top of Phase 2 (the router and the repo reader already exist; it adds templates and no new protocol), and it makes the system inspectable in a browser during the long stretch when Phase 5 is unbuilt and no Bluesky client can see it. Also the natural place to surface health and the block-store state. |

---

## 1. What the tree already provides

Better than a from-scratch estimate would suggest. Nothing below needs to be written:

| Need | Have |
|---|---|
| TCP sockets — listen/accept/send/recv/timeouts | `stdlib/net.mdk` over 9 externs in `stdlib/runtime.mdk` |
| Binary decode / encode combinators | `stdlib/byteparser.mdk` + `stdlib/bytebuilder.mdk` — a symmetric pair, exactly the shape DAG-CBOR and CAR want |
| Multi-precision arithmetic *pattern* | `stdlib/bits64.mdk` — limbs over the wrapping 63-bit fixnum, with the overflow-headroom argument worked out explicitly and proven in `compiler/eval/eval.mdk`. The **method** carries over; the 256-bit field uses its own limb width (P10), not this module |
| JSON | `stdlib/json.mdk` |
| base64, hex, deflate | `stdlib/base64.mdk`, `stdlib/hex.mdk`, `gzip/lib/deflate.mdk` |
| Time, ISO-8601, epoch, monotonic | `stdlib/time.mdk` |
| Byte-clean file I/O, paths | `readFileBytes`/`writeFileBytes` in `stdlib/runtime.mdk`, `stdlib/fs.mdk`, `stdlib/path.mdk` |
| Cooperative concurrency type + laws + `do` DX | `stdlib/async.mdk` (v1) |

Genuinely missing, and specified below: SHA-256, secp256k1, base58btc, unsigned-LEB128
varints, DAG-CBOR, CIDs, the MST, CAR, HTTP/1.1, and the readiness externs (#497).

---

## 2. The two dependencies, and why only one of them blocks what people assume

**#500 (Async runtime v2) is the capability dependency.** Every I/O extern blocks
today, so `concurrent [a, b]` interleaves *semantically* with zero wall-clock overlap
and a server cannot service two connections at once. That is a hard blocker for a
server shell and for nothing else.

**#823/#824 (graded interfaces) is the surface dependency, and it is the expensive
one to get wrong.** Every request handler is a `do` block over `Async`. #824 decides
how `do` routes over graded binds; #823 migrates `stdlib/async.mdk` itself and retires
the #817 W3 carve-out. Writing the server's I/O layer against plain `Thenable Async`
and migrating afterward is a rewrite of every handler — which is the precise reason to
sequence around it rather than through it.

**But the majority of this project is not concurrency-shaped at all.** SHA-256,
secp256k1, DAG-CBOR, CIDs, the MST, CAR, the commit/repo layer, and the HTTP/1.1
*parser* are pure, synchronous, bytes-in/bytes-out code with no `Async` in any
signature. That is most of the line count **and all of the correctness risk**. It is
blocked on neither arc, it runs on all three engines, and it is doctestable today.

The phase order below follows directly from that split.

---

## 3. Architecture: a pure core with a thin native shell

The organising principle, and the reason P9 costs little:

```
                    ┌─────────────────────────────────────────┐
   native-only,     │  socket shell — accept, read, write     │  Phase 3
   thin, ~400 loc   │  over #500's async net surface          │  GATED
                    └──────────────────┬──────────────────────┘
                                       │  Array Int  ⇄  Array Int
                    ┌──────────────────┴──────────────────────┐
                    │  handle : Request -> <Fs> Response      │
   pure, portable,  │  XRPC routing · repo · MST · DAG-CBOR   │  Phases 0-2
   all-engine,      │  CID · CAR · SHA-256 · secp256k1        │  UNBLOCKED
   doctestable      │  HTTP/1.1 parse + serialize             │
                    └─────────────────────────────────────────┘
```

The HTTP layer is a **function from bytes to bytes**, not a server. `parseRequest :
Array Int -> Result String Request` and `serializeResponse : Response -> Array Int`
are pure; so is the router beneath them. Only storage effects (`<FileRead>`/`<FileWrite>`)
and, eventually, clock reach into the handler.

This buys three things at once: the correctness-critical code is gradeable by golden
diff with no sockets involved; it runs under `medaka run` and wasm so doctests and the
engine differential cover it; and Phase 3 shrinks to wiring — an accept loop and a
request lifecycle, with no protocol logic in it.

---

## 4. Pure-Medaka crypto (Phase 0)

The schedule and correctness risk of the whole project, so it goes first, fully
gated, before anything depends on it.

**Substrate.** `Int` is a 63-bit fixnum that wraps, so every intermediate must be kept
provably under the ceiling by construction. `stdlib/bits64.mdk` establishes the pattern
and the style of argument for 64 bits — four 16-bit limbs, least-significant first,
with the headroom stated explicitly in its header: a limb < 2^16, a 16×16 partial
product < 2^32, a column sum of four such plus carry < 2^35.

**Field representation: 10 limbs of 26 bits** (see §7 Q2 for the decision and the
alternatives weighed). This is deliberately *the same layout `libsecp256k1` uses for
its 32-bit field implementation*, which is the point: the reduction algorithm modulo
`p = 2^256 - 2^32 - 977` and its magnitude bookkeeping can be followed from a
battle-tested reference rather than invented. Headroom: a 26×26 partial product is
52 bits, a ten-way column sum is ~55.4 bits, and carries bring the worst case to ~56
— roughly 6 bits under the ceiling.

One simplification against the reference: `libsecp256k1` permits field elements to
carry a *magnitude* above 1 and defers normalization, which is where most of its
subtlety lives. We **normalize eagerly** instead — a real constant-factor cost, in
exchange for an invariant that is one sentence long and locally checkable at every
call. That is the right trade for a first implementation, and it is reversible later
against a vector suite that will already be in place.

**Modules.**

- `pds/lib/field.mdk` — arithmetic modulo the secp256k1 prime `p`: add/sub/mul/square/
  inverse/negate over the 10 × 26-bit representation, with fast reduction exploiting
  the binary structure of `p`. The hot module; essentially all of the cost lives here.
- `pds/lib/scalar.mdk` — arithmetic modulo the group order `n`. Separate from `field`
  on purpose: it runs a few times per signature rather than thousands, so it takes the
  simpler, slower representation and shares no code.
- `pds/lib/sha256.mdk` — straightforward 32-bit-word FIPS 180-4. The easiest module
  in this document and the one with the best-published vectors.
- `pds/lib/secp256k1.mdk` — field arithmetic, point add/double in Jacobian
  coordinates, scalar multiplication, **RFC 6979 deterministic `k`**, low-S
  normalization, and compressed point encoding.
- `pds/lib/base58.mdk` — base58btc, needed only for `did:key`.
- `pds/lib/multiformats.mdk` — unsigned LEB128 varints and the multicodec prefixes.
  Note this is *not* `sqlite/lib/varint.mdk`'s encoding, which is SQLite's own
  big-endian scheme; they are different formats and must not be shared.

**Why this is gradeable rather than hoped-at.** ECDSA with a random nonce produces a
different signature every run and can only be property-tested. **RFC 6979 derives the
nonce deterministically from the key and message**, so a correct implementation emits
*specific bytes* for a given input — and atproto requires low-S normalization, which
removes the last degree of freedom. Signing therefore becomes a golden-diff gate against
published vectors, with no oracle of our own construction anywhere in the loop.

**Volume context.** A signature costs on the order of 2,000 field multiplications —
about 200k partial products at 10×26. A personal PDS signs once per record write, tens
of times a day. Even a slow implementation is irrelevant to this workload, which is why
§7 Q2 resolves on *reviewability against a reference*, not on speed. Do not tune
further without measuring, and note that `diff_compiler_perf_scaling` grades a growth
*ratio* and is structurally blind to a constant factor of this kind.

**The seam.** Every consumer depends on `pds/lib/sign.mdk`'s interface, never on
`secp256k1.mdk` directly. Ordinary layering, kept because a stable API boundary is
right regardless — not as a hedge against the choice in P4.

### 4.1 What the dogfooding actually buys

This is a first-class goal of the project, not a consolation for the schedule.

Self-hosting the compiler is an *allocation- and control-flow*-heavy workload: lists,
maps, pattern matching, deep recursion. It barely touches arithmetic. Nothing in
`compiler/` runs a tight numeric inner loop millions of times, mutates an `Array Int`
in anger, or leans on `bitAnd`/`bitXor`/`shiftLeft` and wrapping-fixnum semantics for
its correctness. Field arithmetic does all four, continuously.

That makes Phase 0 an unusually sharp instrument for finding *compiler* bugs, for a
reason specific to it: **it is self-checking against an external answer key.** Most
performance or codegen defects in this tree surface as a slow stage or a plausible
wrong answer nobody notices. Here, a miscompiled shift or a wrongly-wrapped multiply
produces a signature that does not match RFC 6979's published bytes — a loud,
immediate, unambiguous failure pointing at a specific operation. The workload the
compiler has never been exercised on is exactly the workload that reports its own
defects most precisely.

Concrete things it is likely to surface, based on what this substrate has not yet
been asked to do: the cost of `Array Int` bounds-checked access in a hot loop; whether
tuple-returning limb helpers allocate per call or get unboxed; whether TRMC fires on
the accumulator loops; and the constant-factor gap between `medaka build -O2` and the
interpreter on numeric code, which nothing currently measures. Any of these becoming
a filed `ws:perf` or `ws:emitter` issue is a return on the phase independent of the
PDS ever shipping.

---

## 5. The failure mode that matters, and the apparatus against it

A wrong MST layer computation or a non-deterministic CBOR encoder produces a repo
whose CIDs do not match what every other implementation computes. Nothing crashes.
Records save. The server returns 200. Relays simply decline to accept the repo — or
worse, accept it and fail to verify it later. **This is silent wrongness in a system
holding a real identity**, which puts it at the top of this repo's own severity ladder.

Neither self-consistency nor engine agreement can see it: our encoder and our decoder
agreeing proves only that they are inverse, and eval/native/wasm agreeing proves only
that they are the same code. Both are exactly the "all three engines equally wrong"
shape AGENTS.md warns about.

So the gates for Phases 0–1 are, without exception, **external**:

- **G1** — No module is depended upon before it passes published vectors. SHA-256
  against FIPS 180-4 and the standard corpus; ECDSA against RFC 6979's own worked
  examples and the Wycheproof suite, including its edge and malleability cases.
- **G2** — DAG-CBOR gated on the official atproto interop test files, plus a
  round-trip property over generated values. Determinism is the property under test,
  not merely correctness: canonical ordering, shortest-form integers, no indefinite-length
  encodings.
- **G3** — MST gated by building an identical record set in the official PDS and
  requiring **byte-identical root CIDs**, over a corpus deliberately chosen to exercise
  the layer boundaries (keys whose SHA-256 has 0, 2, 4, 6 leading zero bits — depth is
  leading zero *bits* divided by two, giving fanout 4) and prefix-compression edges.
- **G4** — CAR export byte-compared against the oracle's `getRepo` for the same repo.
- **G5** — **No golden is ever captured from our own implementation** in Phases 0–1.
  Capturing a golden records what the engine did, not what is correct; on a protocol
  where correctness is defined by other people's implementations, a self-captured
  golden is not weak evidence but *anti*-evidence, since it converts a bug into the
  defended expected output.

---

## 6. Phases

**Phase 0 — crypto core.** `field`, `scalar`, `sha256`, `secp256k1`, `base58`,
`multiformats`. Gated by G1. *Unblocked today. All-engine.*

**Phase 1 — data model.** `dagcbor` (deterministic encode/decode over
`byteparser`/`bytebuilder`), `cid` (CIDv1: multibase, multicodec, SHA-256 multihash),
`mst` (depth from leading zero bits of the key hash ÷ 2, fanout 4; nodes serialized as
`l` plus entries of `p`/`k`/`v`/`t`), `car` (v1 read/write), `blockstore` (flat sharded
files), `repo` (commit objects — `did`, `version: 3`, `data`, `rev` as TID, `prev`,
`sig`; TID generation and monotonicity). Gated by G2–G5. *Unblocked today. All-engine.
The highest-risk phase in the project.*

**Phase 2 — protocol logic, still pure.** HTTP/1.1 request parse and response
serialize (request line, headers, chunked transfer, keep-alive semantics as data,
multipart bodies for `uploadBlob`); the XRPC router; `handle : Request -> <Fs> Response`.
*Unblocked today. All-engine, doctestable, golden-diffable with no sockets.*

**Phase 3 — the socket shell.** ⛔ **GATED on #500 (A1 #496 + A2 #497)** for real I/O
overlap, and on **#823/#824** for the `do` surface every handler is written in. An
accept loop over the async net surface, the request lifecycle, connection lifetime and
timeouts. Small by construction — Phase 2 left it nothing but wiring.

**Phase 4 — a standalone PDS.** `did:web` identity document, account bootstrap,
`createSession`/`refreshSession` and JWT signing (reusing Phase 0), record CRUD
(`createRecord`/`putRecord`/`deleteRecord`/`getRecord`/`listRecords`/`applyWrites`),
blob upload and retrieval, `com.atproto.sync.getRepo`/`getLatestCommit`/`listBlobs`,
`resolveHandle`, and the well-knowns. Deployed behind Caddy under systemd. **This is
the first phase with a running, useful artifact.**

**Phase 4.5 — read-only web view** (P13). Repo, collections, and individual records
rendered as HTML from the same process and router. No new protocol surface; makes the
system inspectable in a browser during the stretch before any client can see it.

**Phase 5 — network participation.** RFC 6455 WebSocket framing,
`com.atproto.sync.subscribeRepos` over the bounded on-disk event log (P12), and
outbound HTTP for appview proxying (the app sends
reads through the PDS via the `atproto-proxy` header, which is an outbound HTTPS call —
so either `runCommand` to `curl` or a local egress proxy, since P5 means no TLS of our
own). At the end of this phase relays index the repo and posts reach the network.

**Phase 6 — `did:plc` migration.** PLC genesis and signed `updateOperation`, rotation
keys, and the account-migration sequence, to move the real handle onto this server.
Deliberately last: it is the only irreversible step in the project, and by this point
every primitive it depends on has been validated against an external oracle for five
phases.

**Phase 7 — OAuth.** DPoP, PAR, JWKS, authorization-server metadata. App passwords and
`createSession` remain functional throughout; OAuth is required for *third-party*
clients in production, which is a Phase 7 concern by construction.

---

## 7. Questions, resolved and open

**Q1 — Does the crypto graduate to `stdlib/`? RESOLVED → P11.** Yes, eventually,
gated on the criteria in that row rather than on a feeling that it looks finished.

**Q2 — What limb width? RESOLVED → P10: 10 × 26 bits.** Val delegated this one, so
the reasoning is recorded in full.

Three layouts were live. **16 × 16-bit** inherits `stdlib/bits64.mdk`'s exact headroom
argument and leaves ~25 bits spare, but needs 256 partial products per multiply.
**10 × 28-bit** is the fewest limbs that fit and needs 100, but its worst-case column
sum lands near 2^60 — roughly two bits under the ceiling, which is too thin to reason
about comfortably once reduction adds terms. **10 × 26-bit** needs the same 100 partial
products as 28 while keeping ~6 bits of headroom.

The tiebreaker is not arithmetic, though. 10 × 26 is precisely the representation
`libsecp256k1` uses on 32-bit platforms, where products land in a 64-bit accumulator —
almost exactly our constraint. Adopting it means the modular reduction and its
magnitude analysis, the subtlest code in the project, can be checked against a
widely-audited reference implementing the identical layout, instead of being derived
independently and hoped at. On a project whose whole risk profile is *silent* numerical
wrongness, "there is a reference to check this against" outranks both provenance with
`bits64.mdk` and a 2.5× constant factor that §4 shows this workload does not notice.

The instinct toward fewer partial products was right; it just isn't what settles it.

**Q3 — Durable firehose event storage? RESOLVED → P12** by observation rather than
decision: the ecosystem's relay backfill window is ~72 hours and `getRepo` handles full
resync independently, so a bounded on-disk log is both sufficient and small. Revisit at
Phase 5 against a real relay — this is empirical, and the number could move.

**Q4 — A read-only web view? RESOLVED → P13.** In, at Phase 4.5.

### Still open

- **Q5 — Does Phase 2's HTTP layer need streaming request bodies?** `uploadBlob` can
  carry several megabytes. Buffering whole requests keeps the Phase 2 core pure and
  synchronous, which is the property §3 is built on; streaming would push chunk
  handling across the socket boundary and complicate the seam. Probably: buffer, with
  a size cap, and revisit only if real blob sizes justify it. Wants a number.
- **Q6 — Where does the signing key live at rest?** Encrypted with a passphrase
  supplied at startup, or plaintext on a locked-down filesystem? The first needs a KDF
  and a symmetric cipher — more pure-Medaka crypto, none of which has a protocol-level
  answer key the way §5's gates do, which makes it a materially different risk from
  everything in Phase 0. Deferred to Phase 4, flagged now because it is the one piece
  of crypto in this document that G1 cannot grade.

---

## 8. Relationship to other work

This project is a **consumer** of the #500 and #820 arcs and must not fork either.
It is, however, an unusually good forcing function for both: a real server is the
first program that will exercise the async runtime's parking and readiness paths
under load, and a few thousand lines of `do`-over-`Async` is the largest test the
graded `do` routing (#824) will get. If sequencing allows, Phase 3 starting shortly
after #500 lands would surface runtime gaps while that context is still warm.

Beyond the async arcs it touches nothing: `pds/` imports stdlib, exports nothing back,
and moves no goldens.
