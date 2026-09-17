# pds/ — build log

The phase-by-phase record of how this project was built: what each phase and
slice delivered, under which issue, and which claims this project used to make
that have since been retired.

This file is not the place to check what holds now — `pds/README.md`, organized
by subject, is that place. When the two disagree, the README is the one that
is wrong, and fixing the README is the work. This file exists so that the
README does not have to carry a chronology in order to keep the provenance.

The design that the phases implement is
`docs/design/ATPROTO-PDS-DESIGN.md` (its §0 holds the locked decisions the
`P<n>` and `G<n>` references below name).

## Phase 0 — provenance discipline and the cryptographic primitives

Phase 0 established the rule before it established any code: **G5 — no golden
is ever captured from our own implementation in Phases 0–1.** Capturing a
golden records what the engine did, not what is correct; on a protocol where
correctness is defined by other people's implementations, a self-captured
golden is not weak evidence but *anti*-evidence. The design states G5 has no
mechanical enforcement and names `pds/test/VECTOR-PROVENANCE.txt` as the
remedy, gated by `pds/test/vector_provenance.sh`.

Then the primitives, slice by slice, each against an answer key it did not
write:

| Slice | Issue | Delivered |
|---|---|---|
| `S-encodings` | #1701 | `pds/lib/base58.mdk` and `pds/lib/multiformats.mdk`, graded against six published in-family answer keys |
| `S-field` | #1699 | `pds/lib/field.mdk` on libsecp256k1's 10×2^26 layout (P10), and the 944-row generated corpus |
| `S-scalar` | #1700 | `pds/lib/scalar.mdk` on 16 limbs of 2^16, and the 1028-row generated corpus |
| `S-point-core` | #1700 | `pds/lib/secp256k1.mdk`'s point carriers and complete addition/doubling |
| `S-public-key` | #1700 step 2 | `pds/lib/sign.mdk`'s opaque `SecretKey`/`PublicKey` boundary and the fixed 256-round ladder |
| `S-signing-contract` | #1700 step 4 | the same boundary's opaque `Signature`, RFC 6979 signing, and verification |
| did:key | #1701 | `pds/lib/did_key.mdk`, graded against the pinned official-PDS `Secp256k1Keypair.did()` |

`S-field` wrote the `[impl] libsecp256k1` stanza that pins one repo + version +
commit for the whole sprint; `S-scalar` reused that same `id` and added no
second stanza, which is what the provenance gate's one-answer-key-per-`id` rule
was built to enforce.

Two things were deliberately deferred rather than shipped early, and the
deferral is why the modules look the way they do:

- **`scIsHigh` landed WITHOUT its ECDSA consumer.** It is the low-S predicate
  (`s > floor(n/2)`) that atproto requires; the *normalization* — negate-if-high
  — is a signature-encoding decision needing `r`, `s` and the wire format, and
  belonged to the signing slice. There was deliberately no `scNormalizeLow` in
  `scalar.mdk`, and there still is not.
- **The fixed-control building blocks preceded their call graph.** When
  `S-scalar` landed `feZeroBit`/`feEqualBit`/`feSelect`/`feNegateCt` and
  `scZeroBit`/`scEqualBit`/`scSelect`/`scNegateCt`/`scHighBit`,
  `pds/test/constant_time_reductions.sh` certified those helpers and nothing
  else — the point and signing call graphs were still unwritten.
  `pds/test/constant_time_signing.sh` arrived with `S-signing-contract` and
  audits them now.

## Phase 1 — the data model, and the oracle standup

**Data model (#2136).** DAG-CBOR/CID, the atproto MST, CAR, and signed
repository transitions, with four vector gates grading external answer corpora
across eval, native, and Wasm. Repository signing was split across engines to
fit required CI rather than graded identically on all three.

**Oracle standup (`S-oracle-standup`, #1707).** The reproducible **library**
routes that answer for the data model — the committed lockfile under
`pds/tools/atproto_reference/`, and `pds/tools/check_pds_phase1_image.sh`
running Node inside the official Bluesky PDS image pinned by digest — plus
`pds/oracle/`, the separate live-service harness. Its safety guard deliberately
disables account creation against the public PLC directory, because that would
make a permanent `did:plc` write, so a true live-service repo transcript was
never claimed by Phase 1.

The appview-proxying answer key (`Proxy answer key` in the README) and the
service-auth interop check joined the same set of library routes, taking the
count to four.

## Phase 2 — the protocol core (#2192)

Bounded HTTP/1.1 framing with strict duplicate-aware parsing and typed
malformed-versus-resource-excess failure classes, deterministic response
serialization, structural XRPC routing, the canonical JSON error envelope, and
the opaque immutable `Store` / `Server` composition seam
(`handle : Server -> Store -> Request -> (Store, Response)`). `pds/lib/store.mdk`
at this point wrapped the verified `BlockStore` alone; Phase 4 added the
configured account's repository beside it.

The framer and its framing/body ceilings later moved to `stdlib/http.mdk`,
leaving only the atproto-specific XRPC routing in `pds/lib/xrpc.mdk`.

## Phase 3 — the socket shell (#2481, #2525)

`pds/serve.mdk` and `pds/shell/server.mdk`: the accept loop, the
per-connection HTTP/1.1 lifecycle, and the one `Ref Store` every connection
task shares. `pds/test/serve_e2e.sh` grades it end to end and
`pds/test/lib_boundary.sh` proves the `pds/lib` ⇄ `pds/shell` boundary holds.

## Phase 4 — the endpoints (#1697)

The umbrella design's Phase 4, landed in three parts:

- **Record writes** — `createRecord`, `putRecord`, `deleteRecord`, and
  `applyWrites` as one signed commit, with `swapCommit`/`swapRecord`
  compare-and-swap preconditions. `pds/lib/server_core.mdk` gained its
  `Account` here, admitted by `pds/lib/atsyntax.mdk`'s validators;
  `Handler`, `handle`, and `handleBytes` kept their Phase-2 shapes, because the
  account is configuration on the `Server` rather than a new argument on the
  composition seam.
- **Reads, sync, identity, and the two well-knowns** — the six read routes,
  structurally incapable of transitioning the `Store`, plus the `WellKnown`
  route class.
- **Blob routes and persistence (#2605)** — `uploadBlob`, `sync.getBlob`,
  `sync.listBlobs`, `pds/lib/blob.mdk`'s single `admitBlob` admission point,
  and `pds/shell/blobfile.mdk`'s stage-then-rename persistence beside the block
  store.

## After Phase 4

- **Rate limiting and `--trusted-proxy` (#2612).** Five independent per-window
  allowances in `pds/lib/resource_limits.mdk`, refused with `429` and the three
  IETF `RateLimit-*` headers.
- **The bind refusal (#2757).** `requireTrustedBind` refuses a direct,
  unproxied non-loopback bind outright, because this runtime cannot obtain a
  TCP peer's address and therefore cannot identify an unproxied caller. #2757
  closed as accepted-risk on that basis.
- **The shipped Caddyfile's header line (#2949).**
  `header_up X-Forwarded-For {remote_host}` in `pds/Caddyfile`, plus the two
  ceilings on the header itself.

## Retired claims

Claims this project's own documentation used to make, and no longer does. They
are recorded here rather than deleted, because a reader who met the old wording
elsewhere needs to know it was withdrawn on purpose.

- **The CI classification policy was duplicated, and the copy had gone stale.**
  The README used to restate `AGENTS.md`'s [W-PROJECT-BY-MANIFEST] policy
  rather than point at it, and the copy named the `sqlite` shard as pds's only
  home — while `pds/test/*` had since been split across four shards by cost
  (#1929). The README now points; the policy lives in one place.
- **"Shard globs do not cross `/`" is retired.** The policy used to say that a
  script in a subdirectory of `pds/test/` was enrolled by nothing, because the
  `'pds/test/*'` shard glob did not reach it. That is no longer how enrolment
  works (re-derived 2026-09-01 against the current tree, per P4-D): since the
  #2178 CI re-architecture there are no shard globs at all — `ci.yml` names
  gates one by one, and `test/diff_compiler_ci_shard_coverage.sh` classifies a
  gate by the repo-relative stem of its `test/gates.toml` `run` field, at any
  depth. What enrols a script is a `[[gate]]` row with a valid `shard`.
- **Two eval arms were demoted off the PR path, on measured cost.**
  `pds/test/signing_parity.sh` kept its arm in place behind `SIGNING_DEEP=1`
  (#1962); `pds/test/repo_vectors.sh`'s 1091.56s eval arm moved out entirely
  and became `pds/nightly/repo_vectors_eval_engine.sh` (#2208). Both shapes are
  written up in the README's "CI classification policy" as the precedent for
  the next expensive gate.
