# GATE-REGISTRY-DESIGN.md — the gate registry format and `medaka gate` driver

**Status:** PARTLY LANDED — 2026-08-29, companion to
[CI-ARCHITECTURE.md](CI-ARCHITECTURE.md) (epic #2182, working spec for #2176).

§2's schema and §7's first two questions are no longer proposals: `test/gates.toml`
exists and `medaka gate list` reads it. What has landed is the FORMAT and the read
path over a **hand-written pilot of eight entries** — everything else in this doc is
still design. The remaining work is the rest of the same sprint, not separate
projects:

| Slice | What it adds | Sections still design until then |
|---|---|---|
| S-2 | full enrolment: every gate in the repo | §1's "single source of truth" claim |
| S-3 | `medaka gate run` + the driver-provided services | §3 `run`, §4, §6 rules 1–2 |
| S-4 | `medaka gate verify` + `medaka gate explain` | §3 `verify`/`explain`, §6 rule 4 |
| S-5 | `sources`/`corpus` populated | — LANDED |

⚠️ **Nothing reads `test/gates.toml` except `medaka gate list`/`run`/`verify`/
`explain`.** `ci.yml`, `test/preflight.sh`, `test/build_oracles.sh` and
`test/run_gates.sh` are unchanged and remain authoritative; the registry is not yet a
second source of truth, it is a not-yet-consumed one. S-5 populated `sources`/`corpus`
and PROVED the registry answers preflight's own question, but it deliberately did NOT
switch preflight over — that is #2177/#2179's consumer-by-consumer migration (§6 rule
3).

**S-5's equivalence measurement, so the next reader need not re-derive it.** Over 693
path queries — 669 DERIVED (the first tracked file in every directory in the repo:
`git ls-files | awk -F/ '{d="";for(i=1;i<NF;i++)d=d $i "/"; if(!(d in seen)){seen[d]=1;print}}'`)
plus 24 required by hand, covering every project, each blast-radius prefix, prose, and
the three known-gap issues — `medaka gate explain <path>` and
`PREFLIGHT_DRY=1 PREFLIGHT_CHANGED_FILE=<path> sh test/preflight.sh` agree on the gate
set for every path **except 20 instances in 5 classes, all of them the registry
selecting MORE, none of them the registry selecting less.** The five:

1. `compiler/backend/*` → `selfcompile_fixpoint`. preflight runs it out-of-band via
   its `need_fixpoint` flag, so it never appears on a `GATE` line; the registry records
   it as the path trigger it is.
2. `sqlite/**` → `wasm/diff_sqlite` and 3. `gzip/**` → `wasm/diff_gzip`: the #2179
   reverse edge, which preflight does not have at all. This is the edge the registry
   exists to make legible.
4. `compiler/tools/fmt.mdk`, `printer.mdk`, `lsp.mdk`, `snapshot.mdk`, `repl.mdk`,
   `lint*.mdk`, `gate_cmd.mdk`, `*test*` → `diff_compiler_check*`. preflight's `case`
   is first-match-wins, so its specific `compiler/tools/<file>` arms SHADOW the
   `compiler/tools/*)` arm that adds the `check*` family. The registry has no arm
   order, so it selects both. Believed to be a real preflight under-selection.
5. A path under a fixture directory NESTED inside another fixture directory (only
   `test/cross_project_fixtures/{,twonames/}goldens/*` today). preflight dispatches on
   the NEAREST `*fixtures*`/`*goldens*` ancestor and climbs only when that has no
   consumer; `corpus` is prefix-containment and cannot express "nearest". The
   difference is the safe direction and is the reason `corpus` keeps the ANCESTOR dir
   when a gate references both.

---

## 1. What the registry is

One declarative manifest — `test/gates.toml`, TOML because `medaka.toml` already sets
the precedent and the compiler already parses it — that is (once S-2 enrols every
gate) the **single source of truth** for every gate in the repo. Every current consumer of
"which gates exist, what do they need, who runs them" becomes a reader:

| Consumer today | Reads today | Reads after |
|---|---|---|
| ci.yml shard matrix | hand-written `pattern:` globs | generated from registry (#2177) |
| test/preflight.sh | hand-written path→gate case arms | registry `sources`/`corpus` fields |
| test/diff_compiler_ci_shard_coverage.sh | ci.yml + test/CI-COVERAGE-EXCEPTIONS.txt | subsumed by the registry drift gate (or retired — decided in #2177) |
| test/build_oracles.sh `--for` | greps gate scripts for `test/bin/*` | registry `oracles` field |
| test/diff_compiler_project_enrolment.sh | derives 3 legs independently | registry `project` field + drift gate |
| `sh test/run_gates.sh '<pat>'` | filesystem globs | `medaka gate run <selector>` (run_gates becomes a shim, then retires) |

## 2. Entry schema (LANDED)

This is what `test/gates.toml` actually holds and what `compiler/tools/gate_cmd.mdk`
reads. Field names are final; the pilot's eight entries all conform.

```toml
[[gate]]
name        = "diff_compiler_parse_result"      # unique; the name run_gates.sh resolves
area        = "frontend"       # semantic identity: frontend|types|eval|backend|tools|
                               #   engines|wasm|soundness|infra|docs
project     = "compiler"       # compiler | sqlite | gzip | pds | mq | parsec | byteparser
tier        = "merge"          # merge | nightly | ondemand
cost        = "cheap"          # cheap(<10s) | medium(<60s) | heavy(<300s) | budgeted(explicit)
kind        = "exec"           # exec (wrap a script) | native (a medaka gate module)
run         = "test/diff_compiler_parse_result.sh"   # exec: the script; native: module path
oracles     = ["parse_result_main"]   # test/bin/* names this gate reads (drives oracle builds)
sources     = ["compiler/frontend/parser.mdk"]   # what SELECTS this gate (preflight/
                               #   queue scoping). GLOBS: `*` (crosses `/`), `?`.
                               #   `["*"]` means WHOLE-TREE and never counts as a
                               #   targeted mapping — see below.
corpus      = ["test/parse_error_fixtures"]      # fixture DIRECTORIES read (literal
                               #   paths, never globs; a changed path is in one when it
                               #   IS the dir or lives under it) — ALSO reverse edges: a
                               #   project dir here binds that project to this gate for
                               #   queue scoping (#2179).
toolchain   = []               # e.g. ["clang"] ["wasm-tools","node>=24"] ["sqlite3"] ["valgrind"]
```

Three rules the reader enforces, each because the alternative fails quietly:

- **Every field is required on every entry, list fields included.** An absent
  `sources` is a read error, not an empty list — "not yet populated" and "this gate
  reads nothing" are different facts and a defaulting reader would erase the
  difference exactly where S-5 has to tell them apart.
- **`name` is the name `test/run_gates.sh` resolves**, not the script's basename.
  run_gates globs a pattern against BOTH `test/<pat>.sh` and `<pat>.sh` from the repo
  root (`test/run_gates.sh:172-181`), which is why the pilot's sqlite entry is
  `sqlite/test/select_oracle` and its wasm entry is `wasm/diff_wasm`. A basename-only
  key could not name the 24 sqlite gates at all.
- **The schema carries no pass/fail polarity.** `diff_compiler_must_fail` is in the
  pilot for this reason: its fixtures pin OPEN bugs, so RED is its healthy state
  ([G-MUST-FAIL]), and no field in an entry claims otherwise. Whatever runs a gate
  keeps owning what its exit code means.

Notes on the load-bearing fields:

- **`area` vs. shard**: area is identity (what failure reporting names); the executor
  shard a gate runs in is NOT in the registry — it is the balancer's derived,
  committed output (#2178), a separate generated file. Nothing in an entry says
  "where"; that is the whole point.
- **`cost`**: a *declaration* checked against queue-measured reality by the ratchet
  (#2180). `budgeted` carries an explicit seconds figure for the rare
  deliberately-heavy merge-tier gate.
- **`sources` + `corpus` replace preflight's case arms**: preflight's derivation
  ("changed path → gate set") becomes a registry query, `medaka gate explain <path>`.
  The existing fail-open rules transfer verbatim: unmatched non-prose path → FULL;
  blast-radius paths (`stdlib/`, `runtime/`, `compiler/support/`, `compiler/entries/`)
  → FULL, expressed as registry-level policy, not per-gate.

  ⚠️ **Both rules are a SEPARATE code path in `gate_cmd.mdk`, deliberately, and must
  stay one.** The tempting shortcut — give every entry a `stdlib/*` source so a stdlib
  change "matches everything" — encodes policy as data, makes every entry's `sources`
  a lie about what that gate reads, and leaves nothing able to answer "is this path
  mapped at all?". `test/preflight.sh` draws the same line: `mark_full` is its own
  function, not another `add` case arm.

  ⚠️ **`sources = ["*"]` is a WHOLE-TREE source** (today only
  `diff_compiler_source_bytes`, which re-scans every tracked file whatever changed).
  It matches every path by construction, so `explain` does NOT let it establish that a
  path is MAPPED — otherwise the fail-open rule could never fire again and an unmapped
  path would quietly select one whole-tree gate instead of the suite. preflight's
  unconditional `add 'diff_compiler_source_bytes'` sits outside its case table for the
  same reason.

  **`sources = []` AND `corpus = []`** on an entry means nothing in preflight's
  path→gate map selects that gate today — it runs because a `ci.yml` shard pattern
  names it. As of S-5 that is 15 entries, and it is recorded rather than papered over.
- **`corpus` doubles as the reverse-edge ledger** for #2179: `wasm/diff_sqlite` listing
  `corpus = ["sqlite"]` is exactly the fact that makes a sqlite-touching queue entry
  run that compiler gate. Before S-5 those edges lived in nobody's head but the
  audit's; they are now the ONE thing in the registry `test/preflight.sh` has no
  equivalent for at all.

## 3. The driver: `medaka gate`

In the `medaka` binary, dispatched beside `"test"`/`"snapshot"` (§7 Q2), implemented
in `compiler/tools/gate_cmd.mdk` beside `compiler/tools/test_cmd.mdk`:

- ✅ `medaka gate list [<selector>...] [--json] [--registry <path>]` — enumerate;
  machine-readable (`--json`) for the generator and preflight. LANDED.
- `medaka gate run <selector>` (S-3) — run the selection with a worker pool; per-gate
  timing recorded to a machine-readable report (the ratchet's and balancer's input).
- `medaka gate verify` (S-4) — the drift gate: every tracked `*.sh` under the gate
  roots is enrolled or explicitly listed as a non-gate tool; every entry's
  `run`/`oracles`/`corpus` targets exist; selectors resolve to ≥1 gate. Red on any
  divergence. Text-only, no build — runs everywhere, cheap.
- `medaka gate explain <path>` (S-4, completed S-5) — the reverse lookup that doesn't
  exist today: which gates does a changed path select, and why. Output uses
  `test/preflight.sh`'s own machine-readable prefixes so the two derivations diff
  line-for-line: `GATE <name> (sources:<glob> | corpus:<dir>)`, `FULL
  blast-radius:<prefix>`, `FULL unmatched-non-prose:<path>`, `UNMAPPED <path>`. A bare
  token that is also a field value gets `TOKEN` lines (the S-4 behaviour, kept).

The three unimplemented subcommands are named explicitly in the dispatcher and exit
nonzero saying they are not here yet, rather than falling into a generic "unknown
subcommand".

**Selector language (LANDED).** Boring, as designed: a selector is `field:pattern`
where `field` ∈ `name`/`area`/`project`/`tier` and `pattern` is a glob (`*`, `?`); a
bare token is sugar for `name:<token>`; several selectors on one line are a
conjunction. No general query language. Source-path matching is NOT part of the
selector language and is not meant to be: it is `gate explain <path>`'s job, because a
path query has to carry the fail-open policy a selector has no place for.
Two rejections are deliberate and both are loud:

- **A selector matching zero gates exits nonzero**, never a green empty list —
  mirroring `test/run_gates.sh:181`. A mistyped pattern that silently selects nothing
  is precisely how a shard certifies coverage of a gate that never ran.
- **An unrecognized `field:` prefix is an error, not a fall-through to `name:`.**
  `aria:backend` treated as a name glob would report "matched no gates" and send the
  reader hunting for a missing gate instead of a typo'd field.

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

## 7. Questions

### Resolved in #2176

**Q1 — one file or one file per gate? ONE FILE: `test/gates.toml`.** Greppability
wins, and the merge-conflict argument for per-gate files does not survive contact
with what actually conflicts: entries are append-only `[[gate]]` blocks that do not
share lines, so two agents enrolling different gates conflict no more than they would
in separate files, while every consumer (the generator, preflight, the balancer, the
drift gate) would otherwise have to walk and merge a directory before it could answer
a single question. One file also makes "the registry is complete" a diffable fact.

**Q2 — in-binary or separate entry point? IN-BINARY**, dispatched in
`compiler/driver/medaka_cli.mdk` beside `"test"`/`"snapshot"`, implemented in
`compiler/tools/gate_cmd.mdk`. The `medaka test` precedent decides it; a separate
entry point would need its own build, its own staleness check ([B-STALENESS]) and its
own place in the bootstrap, for no gain — §5's circularity is unchanged either way.

### Still open

- Per-gate timing transport: committed file updated by a bot/nightly (GHC pushes git
  notes from CI) vs. fetched from the Actions API at balance time (no tree writes,
  but a network dependency in the balancer). Leaning committed-file for
  reviewability.
- Whether preflight survives as a thin `medaka gate`-calling shim (agents' muscle
  memory, `make preflight`) — probably yes, indefinitely.
