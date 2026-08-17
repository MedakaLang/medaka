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
