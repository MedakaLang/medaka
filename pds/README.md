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
