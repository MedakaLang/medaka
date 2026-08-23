# pds/

The self-hosted atproto PDS (Personal Data Server) written in Medaka. This is
Phase 0 of the umbrella design (#1697) — the numeric substrate slices land
first; see `docs/design/ATPROTO-PDS-DESIGN.md` for the full design.

This slice (`S-pds-skeleton`, #1705) does nothing atproto-specific: it makes
`pds/` a real Medaka project with a working, fail-capable in-language gate
harness, and settles how every tracked `.sh` this sprint adds under `pds/`
gets classified for CI.

## Layout

- `pds/medaka.toml` — project root marker (`[package]` only; no `entry` — see
  below).
- `pds/lib/` — library modules. `skeleton.mdk` is a placeholder proving the
  `pds/test/*.mdk` -> `pds/lib/*.mdk` import wiring; delete it once a real
  module lands (see its own header for the required three-part coupled edit).
- `pds/test/` — in-language `medaka test` suites (`*_test.mdk`) plus gate
  scripts that run them (`*.sh`). **Every `.sh` placed directly in `pds/test/`
  is auto-enrolled as a CI gate** — see the classification policy below.

`pds/medaka.toml` intentionally has no `entry` key and there is no
`pds/main.mdk`: the manifest reader (`compiler/driver/loader.mdk`) never
reads `entry` — its only job is to mark the project root so `pds/test/*.mdk`
can `import lib.<mod>`.

## Running the gate locally

```sh
MEDAKA_ROOT="$(git rev-parse --show-toplevel)" MEDAKA="$MEDAKA_ROOT/medaka" \
  sh pds/test/inlang_test_oracle.sh
```

Requires a built native `medaka` binary. No oracle build needed — `medaka
test` runs the interpreter directly.

## CI classification policy

```
CI CLASSIFICATION POLICY FOR EVERY TRACKED .sh THIS SPRINT ADDS (RUN-PDS0-001 A4)

(a) SHARD GLOB. '.github/workflows/ci.yml', the `- name: sqlite` matrix entry:
    pattern: "'sqlite/test/*oracle' 'gzip/test/*oracle' 'pds/test/*'"
    Placement is by COST, not theme: two consecutive green `merge_group` runs
    (31983057792, 31979717039) put `sqlite` at 162s/203s — cheapest or
    second-cheapest of the seven shards in both runs (only `backend` at 177s
    beat it in the second run); `engines` is the pole at 385-389s both times.

(b) GATE-FILENAME CONVENTION THE GLOB IMPLIES. None — and that is the point.
    'pds/test/*' enrols every .sh DIRECTLY UNDER pds/test/ — the glob is
    ONE DIRECTORY LEVEL DEEP; `*` does not cross `/`. So a later slice may
    name its gate anything (sha256_vectors.sh, base58_vectors.sh,
    vector_provenance.sh) and needs NO ci.yml edit, AS LONG AS it lands
    directly in pds/test/. The corollary is binding in BOTH directions:
    any .sh placed DIRECTLY in pds/test/ WILL BE EXECUTED AS A CI GATE in
    the `sqlite` shard, so a non-gate must not live there; and any .sh in
    a SUBDIRECTORY of pds/test/ (e.g. pds/test/vectors/helper.sh) is
    enrolled by NOTHING and will RED the coverage gate until it gets a
    test/CI-COVERAGE-TOOLS.txt row or its own pattern. Do not put scripts
    in subdirectories of pds/test/.
    ASYMMETRY (do not conflate): the preflight `pds/*)` arm (test/preflight.sh)
    is a shell `case` pattern and matches AT ANY DEPTH (pds/oracle/run.sh
    matches it); the shard `pattern:` above is a filesystem glob and does
    NOT cross a `/`. Both are correct for their own jobs — only the pair
    reads as consistent when it is not.
    [RUN-PDS0-003(a)]

(c) TOOLS vs SHARD vs EXCEPTIONS, for the scripts this sprint will add:
    - A real gate (asserts something and can fail)  -> put it in pds/test/;
      it is auto-enrolled by (a). No ledger row.
    - A script that proves nothing about the compiler — an oracle run/compose
      script (S-oracle-standup), a corpus-extraction script (S-field/S-scalar)
      — must live OUTSIDE pds/test/ (e.g. pds/oracle/, pds/tools/) and needs a
      row in test/CI-COVERAGE-TOOLS.txt keyed by its REPO-RELATIVE PATH MINUS
      .sh (not its basename).
    - test/CI-COVERAGE-EXCEPTIONS.txt is for a real gate deliberately NOT run
      in CI, with a reason. No script in this sprint is expected to need it.
    Every tracked .sh must be in exactly one of these buckets:
    diff_compiler_ci_shard_coverage.sh enumerates them repo-wide via
    `git ls-files -z '*.sh'` and fails on any that is in none.
```

## Vector provenance (G5)

`pds/test/VECTOR-PROVENANCE.txt` is the mechanism for G5 (see
`docs/design/ATPROTO-PDS-DESIGN.md` §5): **no golden is ever captured from our
own implementation** in Phases 0–1, because on a protocol where correctness is
defined by other people's implementations, a self-captured golden is not weak
evidence but *anti*-evidence. The gate is `pds/test/vector_provenance.sh` — it
runs a six-scenario self-test in a `mktemp -d` on every invocation, then checks
the real tree, and it is auto-enrolled in the `sqlite` CI shard by the classification
policy above (it landed directly in `pds/test/`, no ci.yml edit needed).

**Enumeration rule (what needs a row):** every regular file under `pds/test/`
at ANY depth, EXCEPT `*.sh`, `*.mdk`, and the ledger itself — no allowlist, no
filename convention. **Corollary: put prose in `pds/README.md`, never under
`pds/test/`** — a `.md` dropped in `pds/test/` needs a row too, since it isn't
excluded.

**Adding a row when you add a corpus:** every vector file needs exactly one
`[vector]` stanza in `pds/test/VECTOR-PROVENANCE.txt`, added in the SAME COMMIT
as the corpus file. See that file's own header for the full schema (required
keys per provenance kind) and two worked examples.

**The two provenance kinds, one paragraph each** (full policy, including which
implementation/artifact class each consumer slice may use, is in the ledger's
own header — that copy is canonical; this is a pointer):
- **published-artifact** — the answer key is a document (e.g. FIPS PUB 180-4,
  a published base58btc vector list). The row records the artifact, its URL,
  its digest (or `UNAVAILABLE` + a note), and how the values were extracted.
- **reference-impl** — the answer key is a program (e.g. libsecp256k1 for
  `field.mdk`/`scalar.mdk`, recording design decision P10). The row names an
  `[impl]` stanza pinning repo + version + commit; the FIRST slice to extract
  writes that pin, every later slice reuses it, and the gate reds on a second
  `[impl]` stanza pinning the same id to a different commit.

**What the ledger does NOT prove:** it never fetches `source-url` and never
verifies `source-sha256` (no network in the shard) — that column is an audit
anchor for a human reviewer, not a checked one. See the ledger header's
DOES-NOT-PROVE block for the full statement, including the residual gap
(expected values as inline literals in a `_test.mdk`, or a `.mdk` data module,
are invisible to this enumeration by construction).

**Run the gate locally:**

```sh
MEDAKA_ROOT="$(git rev-parse --show-toplevel)" sh pds/test/vector_provenance.sh
```

No `medaka` binary needed — the gate only enumerates files, hashes them, and
parses text.

## Encodings (S-encodings, #1701)

`pds/lib/base58.mdk` (base58btc encode/decode) and `pds/lib/multiformats.mdk`
(unsigned-varint / LEB128, multicodec prefix constants, multibase `z`
prefixing) are graded against six published, in-family answer keys under
`pds/test/vectors/`, each with a provenance row in
`pds/test/VECTOR-PROVENANCE.txt`:

- `multibase_basic.csv`, `multibase_leading_zero.csv`,
  `multibase_two_leading_zeros.csv` — byte-verbatim from
  `multiformats/multibase`'s own `tests/*.csv` (grades `multibaseBase58btc`
  end-to-end, including 1- and 2-leading-zero-byte inputs).
- `multicodec_table.csv` — byte-verbatim from `multiformats/multicodec`'s
  `table.csv` (grades the five multicodec constants this project needs).
- `base58_draft_msporny_02.txt` — hand-transcribed from IETF
  `draft-msporny-base58-02` (the alphabet + its 3 published test vectors).
  **This file discloses a known erratum** in the draft's own third vector
  (a leading-zero-byte case): the draft's stated output is inconsistent with
  its own algorithm — see the file's own comment and
  `pds/lib/base58.mdk`'s `base58btcEncode` doc comment for the full
  cross-check. The vector driver reports that one row as `ERRATUM`, not
  `PASS`/`FAIL`.
- `unsigned_varint_examples.txt` — hand-transcribed from
  `multiformats/unsigned-varint`'s README (6 worked encodings + the one
  published non-minimal-encoding rejection case).

**Multiformats unsigned-varint is NOT `sqlite/lib/varint.mdk`.** They share a
name and nothing else — LSB-first vs. BIG-endian payload concatenation,
minimality-required vs. no minimality requirement. See
`pds/lib/multiformats.mdk`'s module header for the full contrast; never
substitute one for the other.

**16383** has no reachable published in-family vector (only 16384 does); it
is covered by a structural boundary-length + round-trip property in
`pds/test/encodings_test.mdk` instead of a transcribed answer key. The
**empty base58 input** (`base58btcEncode [||] == ""`) is likewise asserted
structurally — no in-family source publishes it.

**Run the gates locally:**

```sh
MEDAKA_ROOT="$(git rev-parse --show-toplevel)" sh pds/test/encodings_vectors.sh
MEDAKA_ROOT="$(git rev-parse --show-toplevel)" sh pds/test/inlang_test_oracle.sh
```

## secp256k1 field arithmetic (S-field, #1699)

`pds/lib/field.mdk` is arithmetic modulo `p = 2^256 - 2^32 - 977` on **10
limbs in base 2^26** (limbs 0..8 hold 26 bits, limb 9 holds 22). That layout
is design decision **P10**: it is `libsecp256k1`'s `field_10x26_impl.h`
layout, chosen so the subtlest arithmetic here is cross-checkable element by
element against an audited implementation of the identical representation.
Read the module header before changing anything in it — it carries the
headroom derivation against Medaka's silently-wrapping 63-bit `Int`, and the
reason the reference's own overflow proof does **not** transfer.

**The answer key.** `pds/test/vectors/field_reference_corpus.txt` (944 rows:
`red`/`sqr`/`neg`/`inv` over 44 inputs, `mul`/`add`/`sub` over 256 pairs) is
GENERATED from `libsecp256k1` — never captured from our own implementation
(G5). Its provenance row and the `[impl]` pin are in
`pds/test/VECTOR-PROVENANCE.txt`; that file's POLICY block is canonical and is
not restated here.

**The pin is sprint-wide.** The `[impl] libsecp256k1` stanza pins one
repo + version + commit for the whole sprint: `pds/lib/scalar.mdk` will reuse
the same `id`, and the provenance gate REDS on a second `[impl]` stanza
pinning that id to a different commit. The `commit:` value is the **peeled**
commit of the annotated tag (`git rev-parse 'v0.8.0^{commit}'`) — a bare
`rev-parse`/`ls-remote` on an annotated tag returns the tag OBJECT's sha, and
nothing downstream can tell the two apart.

**Regenerating the corpus.** `pds/tools/gen_field_corpus.sh` is a **TOOL, not
a gate** — it needs network and a C compiler, is never run in CI, and lives
outside `pds/test/` for exactly that reason (see the classification policy
above); its row is in `test/CI-COVERAGE-TOOLS.txt`. The input set and the pair
list live in committed source (`pds/tools/field_corpus_driver.c`), so the only
run-time parameter is the output path:

```sh
sh pds/tools/gen_field_corpus.sh /tmp/x
cmp /tmp/x pds/test/vectors/field_reference_corpus.txt   # must be byte-identical
```

**Run the gates locally:**

```sh
MEDAKA_ROOT="$(git rev-parse --show-toplevel)" sh pds/test/field_vectors.sh
MEDAKA_ROOT="$(git rev-parse --show-toplevel)" sh pds/test/inlang_test_oracle.sh
```

## Oracle (S-oracle-standup, #1707)

`pds/oracle/` runs the **official Bluesky PDS container image, pinned by digest**, as the
Phase 0/1 cross-check oracle, with a documented no-Docker fallback for boxes without Docker.
The full procedure lives in `docs/ops/PDS-ORACLE.md` — this is a **local manual procedure, not
a gate; no CI job provisions it**.

## secp256k1 scalar arithmetic (S-scalar, #1700)

`pds/lib/scalar.mdk` is arithmetic modulo the secp256k1 **group order**
`n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141`
(SEC 2 v2 §2.4.1) — the ring ECDSA's `k`, `r` and `s` live in. It exports
`scAdd`/`scSub`/`scMul`/`scNegate`/`scInverse`, canonical 32-byte
serialization, and `scIsHigh`.

**It deliberately shares no code with `pds/lib/field.mdk`.** The field module
mirrors `libsecp256k1`'s 10×2^26 layout because design decision P10 wants
element-by-element cross-checkability of the subtlest arithmetic in the
project. Scalar operations run a *few times per signature, not thousands*, so
this module optimises for being easy to argue about instead: **16 limbs of
2^16**, uniform width, 26 bits of headroom against Medaka's silently-wrapping
63-bit `Int`.

🚨 **The field's reduction does not transfer, and that is the reason the two
modules are separate rather than shared.** `2^256 − p` is `2^32 + 977`, ~33
bits, which is what makes the field's fixed three-round carry/fold schedule
fully reduce under its conservative raw-limb bound. `2^256 −
n = 0x14551231950b75fc4402da1732fc9bebf` is **129 bits**: one fold of a
512-bit product lands below 2^385, not below 2^256. `scalar.mdk` therefore
runs exactly **four** fold/carry rounds, including zero high halves, and then
makes one unconditional arithmetic subtract-and-select. Read the module header
before changing anything in it — it carries that argument and the headroom
derivation.

**The answer key.** `pds/test/vectors/scalar_reference_corpus.txt` (1028 rows:
`red`/`neg`/`inv`/`high`/`ovf` over 52 inputs, `mul`/`add`/`sub` over 256
pairs) is GENERATED from `libsecp256k1` — never captured from our own
implementation (G5). `ovf` rows pin the `>= n` rejection boundary
(`scFromBytes`); `high` rows pin the strict low-S predicate. Its provenance row
is in `pds/test/VECTOR-PROVENANCE.txt`.

**The pin is the SAME sprint-wide `[impl] libsecp256k1` stanza** `S-field`
wrote; this slice reuses it and adds no second `[impl]` stanza.

**Regenerating the corpus.** `pds/tools/gen_scalar_corpus.sh` is a **TOOL, not
a gate** — network + a C compiler, never run in CI, lives outside `pds/test/`
for that reason; its row is in `test/CI-COVERAGE-TOOLS.txt`. The input set and
the pair list live in committed source
(`pds/tools/scalar_corpus_driver.c`), so the only run-time parameter is the
output path:

```sh
sh pds/tools/gen_scalar_corpus.sh /tmp/x
cmp /tmp/x pds/test/vectors/scalar_reference_corpus.txt   # must be byte-identical
```

**`scIsHigh` lands WITHOUT its ECDSA consumer.** It is the low-S predicate
(`s > floor(n/2)`) that atproto requires; the *normalization* — negate-if-high
— is a signature-encoding decision needing `r`, `s` and the wire format, and
belongs to next sprint's signing slice. There is deliberately no
`scNormalizeLow` here.

The accepted signing contract's first implementation step adds separate
fixed-control building blocks without changing those public Bool helpers:
`feZeroBit`/`feEqualBit`/`feSelect`/`feNegateCt` and
`scZeroBit`/`scEqualBit`/`scSelect`/`scNegateCt`/`scHighBit`. Their arithmetic
bits, selection, and negation paths are enrolled in
`pds/test/constant_time_reductions.sh`'s closed source, emitted-IR, and linked
native controls. This certifies those helpers, not the still-unwritten point
or signing call graph.

**Run the gates locally:**

```sh
MEDAKA_ROOT="$(git rev-parse --show-toplevel)" sh pds/test/scalar_vectors.sh
MEDAKA_ROOT="$(git rev-parse --show-toplevel)" sh pds/test/inlang_test_oracle.sh
```

## secp256k1 points (S-point-core, #1700)

`pds/lib/secp256k1.mdk` introduces opaque affine and Jacobian point carriers,
the SEC 2 generator, canonical infinity `(0, 1, 0)`, and the contract's
compute-and-select complete addition/doubling formulas. Its in-language suite
checks the infinity, equal, opposite, and ordinary-generator paths while also
asserting that every infinity result uses the canonical coordinates.

```sh
MEDAKA_ROOT="$(git rev-parse --show-toplevel)" sh pds/test/inlang_test_oracle.sh
```
