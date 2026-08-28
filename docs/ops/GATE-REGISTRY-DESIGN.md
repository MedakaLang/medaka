# GATE-REGISTRY-DESIGN.md — the gate registry format and `medaka gate` driver

**Status:** DRAFT — 2026-08-28, companion to [CI-ARCHITECTURE.md](CI-ARCHITECTURE.md)
(epic #2182; this doc is the working spec for #2176 and is expected to be revised by
that issue's implementation — treat field names below as proposals until the registry
exists in the tree).

---

## 1. What the registry is

One declarative manifest (proposed: `gates.toml` under `test/`; TOML because
`medaka.toml` already sets the precedent and the compiler already parses it) that is
the **single source of truth** for every gate in the repo. Every current consumer of
"which gates exist, what do they need, who runs them" becomes a reader:

| Consumer today | Reads today | Reads after |
|---|---|---|
| ci.yml shard matrix | hand-written `pattern:` globs | generated from registry (#2177) |
| test/preflight.sh | hand-written path→gate case arms | registry `sources`/`corpus` fields |
| test/diff_compiler_ci_shard_coverage.sh | ci.yml + test/CI-COVERAGE-EXCEPTIONS.txt | subsumed by the registry drift gate (or retired — decided in #2177) |
| test/build_oracles.sh `--for` | greps gate scripts for `test/bin/*` | registry `oracles` field |
| test/diff_compiler_project_enrolment.sh | derives 3 legs independently | registry `project` field + drift gate |
| `sh test/run_gates.sh '<pat>'` | filesystem globs | `medaka gate run <selector>` (run_gates becomes a shim, then retires) |

## 2. Entry schema (proposal)

```toml
[[gate]]
name        = "diff_compiler_parse_result"      # unique; today's script basename
area        = "frontend"       # semantic identity: frontend|types|eval|backend|tools|
                               #   engines|wasm|soundness|infra|docs
project     = "compiler"       # compiler | sqlite | gzip | pds | mq | parsec | byteparser
tier        = "merge"          # merge | nightly | ondemand
cost        = "cheap"          # cheap(<10s) | medium(<60s) | heavy(<300s) | budgeted(explicit)
kind        = "exec"           # exec (wrap a script) | native (a medaka gate module)
run         = "test/diff_compiler_parse_result.sh"   # exec: the script; native: module path
oracles     = ["parse_result_main"]   # test/bin/* names this gate reads (drives oracle builds)
sources     = ["compiler/frontend/parser.mdk"]       # what SELECTS this gate (preflight/queue
                                                     #   scoping); globs allowed
corpus      = ["test/parse_error_fixtures/"]         # fixture dirs read — ALSO reverse edges:
                                                     #   a project dir here binds that project
                                                     #   to this gate for queue scoping (#2179)
toolchain   = []               # e.g. ["clang"] ["wasm-tools","node>=24"] ["sqlite3"] ["valgrind"]
```

Notes on the load-bearing fields:

- **`area` vs. shard**: area is identity (what failure reporting names); the executor
  shard a gate runs in is NOT in the registry — it is the balancer's derived,
  committed output (#2178), a separate generated file. Nothing in an entry says
  "where"; that is the whole point.
- **`cost`**: a *declaration* checked against queue-measured reality by the ratchet
  (#2180). `budgeted` carries an explicit seconds figure for the rare
  deliberately-heavy merge-tier gate.
- **`sources` + `corpus` replace preflight's case arms**: preflight's derivation
  ("changed path → gate set") becomes a registry query. The existing fail-open rules
  transfer verbatim: unmatched non-prose path → FULL; blast-radius paths (`stdlib/`,
  `compiler/support/`, `compiler/entries/`) → FULL, expressed as registry-level
  policy, not per-gate.
- **`corpus` doubles as the reverse-edge ledger** for #2179: `diff_sqlite` (wasm)
  listing a corpus under `sqlite/` is exactly the fact that makes a sqlite-touching
  queue entry run that compiler gate. Today those edges live in nobody's head but the
  audit's.

## 3. The driver: `medaka gate`

Subcommands (sibling of `medaka test`, living beside compiler/tools/test_cmd.mdk):

- `medaka gate list [<selector>]` — enumerate; machine-readable (`--json`) for the
  generator and preflight.
- `medaka gate run <selector>` — run the selection with a worker pool; per-gate
  timing recorded to a machine-readable report (the ratchet's and balancer's input).
- `medaka gate verify` — the drift gate: every tracked `*.sh` under the gate roots is
  enrolled or explicitly listed as a non-gate tool; every entry's `run`/`oracles`/
  `corpus` targets exist; selectors resolve to ≥1 gate. Red on any divergence.
  Text-only, no build — runs everywhere, cheap.
- `medaka gate explain <path>` — the reverse lookup that doesn't exist today: which
  gates does a changed path select, and why (which field matched).

Selector language: keep it boring — `name:foo*`, `area:backend`, `project:pds`,
`tier:nightly`, source-path matches; conjunctions only. No general query language.

Driver-provided services (what every shell gate currently reimplements): scratch dirs
(per-gate mktemp, cleaned), stale-oracle refusal ([G-STALE-ORACLE] semantics),
stderr-preserving output capture ([B-STDERR]), timeouts, the ok/failing summary
format, and JOBS-style parallelism. Exec-kind gates get these from the harness
wrapper; native-kind gates get them as library calls.

## 4. What stays shell forever (and that's fine)

Inherently exec-kind: oracle-binary differentials (probe entries + clang), the
sqlite3-CLI diffs, git-based ratchets (doc links, banned-command checks), cachegrind/
valgrind instrumentation, seed bootstrap. The registry's value for these is metadata
and uniform invocation, not rewriting. Candidates for native-kind rewrite, in order:
the three project `check` wrappers (mq/parsec/byteparser), fixture run-and-compare
gates where both arms are `./medaka`, then snapshot plumbing (the `medaka snapshot`
subcommand already exists; its 9 shell wrappers are bless/golden plumbing the driver
can absorb).

## 5. Bootstrap circularity, stated plainly

`medaka gate` is compiled by the compiler the gates test. This is the same
circularity `medaka test` already lives with, and the same discipline applies: the
driver must be buildable from the current tree before gates run (CI's build-once job
provides it), a driver bug is a CI outage rather than a silent skip **only if**
`gate verify` + fail-open selection are independent of the driver's own correctness —
so `verify` stays text-only, and the generated ci.yml carries the full gate list
statically (a broken selector degrades to "run everything", not "run nothing").
[B-STALENESS] applies to the driver binary like any `./medaka`: CI asserts
freshness via the existing fingerprint check before trusting a `gate run`.

## 6. Migration invariants (#2176's acceptance, restated as rules)

1. Enrolment is behavior-neutral: wrapping never changes what a gate does, only how
   it is invoked. No slice mixes enrolment with a gate-logic change.
2. Green-tree parity: `medaka gate run` over the full registry and today's
   `sh test/run_gates.sh` agree gate-for-gate before any consumer switches.
3. Consumers switch one at a time (generator first, preflight second, oracle
   derivation third), each behind its own PR with the old path deleted only after the
   new one is required.
4. The drift gate lands before the second consumer switches — from that point,
   registry rot is loud.

## 7. Open questions (to resolve in #2176, not silently)

- TOML vs. one-file-per-gate under a directory (merge-conflict ergonomics for
  parallel agent sprints favor per-gate files; a single file favors greppability).
- Whether `medaka gate` lives in the `medaka` binary or a separate entry point
  (binary bloat vs. one-tool coherence; `medaka test` precedent says in-binary).
- Per-gate timing transport: committed file updated by a bot/nightly (GHC pushes git
  notes from CI) vs. fetched from the Actions API at balance time (no tree writes,
  but a network dependency in the balancer). Leaning committed-file for
  reviewability.
- Whether preflight survives as a thin `medaka gate`-calling shim (agents' muscle
  memory, `make preflight`) — probably yes, indefinitely.
