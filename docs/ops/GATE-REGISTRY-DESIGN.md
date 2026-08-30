# GATE-REGISTRY-DESIGN.md — the gate registry format and `medaka gate` driver

**Status:** LANDED — 2026-08-29, companion to
[CI-ARCHITECTURE.md](CI-ARCHITECTURE.md) (epic #2182, this doc's working spec for
#2176, now the as-built record).

All five slices of the `gate-registry` sprint (#2176) are landed: `test/gates.toml`
holds the full 226-entry corpus, and `medaka gate list`/`run`/`verify`/`explain` are
all implemented and read it.

| Slice | What it added |
|---|---|
| S-1 | schema, reader (`stdlib/toml.mdk`), selector language, `medaka gate list` over an 8-entry pilot |
| S-2 | full enrolment: every gate in the repo (226 entries) |
| S-3 | `medaka gate run` + the driver-provided services |
| S-4 | `medaka gate verify` + `medaka gate explain` |
| S-5 | `sources`/`corpus` populated, proven equivalent to preflight's own derivation |

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
| test/diff_compiler_ci_shard_coverage.sh | ci.yml + test/CI-COVERAGE-EXCEPTIONS.txt | **DECIDED (#2177, S-4): repointed, not retired** — reads `medaka gate list --json`'s `shard` field for shard membership and no longer parses ci.yml's matrix; keeps the workflow `run:`-step scan, which nothing else does. See §8. |
| test/build_oracles.sh `--for` | greps gate scripts for `test/bin/*` | registry `oracles` field |
| test/diff_compiler_project_enrolment.sh | derives 3 legs independently | registry `project` field + drift gate |
| `sh test/run_gates.sh '<pat>'` | filesystem globs | `medaka gate run <selector>` (run_gates becomes a shim, then retires) |

## 2. Entry schema (LANDED)

This is what `test/gates.toml` actually holds and what `compiler/tools/gate_cmd.mdk`
reads. Field names are final; the pilot's eight entries all conform.

```toml
[[gate]]
name        = "diff_compiler_parse_result"      # unique; the name run_gates.sh resolves
                               #   — enforced: `gate verify` fails on a duplicate (#2199)
area        = "frontend"       # semantic identity: frontend|types|eval|backend|tools|
                               #   engines|wasm|soundness|infra|docs
shard       = "frontend"       # ci.yml `gates` matrix ROW: engines|sqlite|pds|frontend|
                               #   types|eval|backend|tools, or `other-job` for a gate
                               #   some OTHER workflow job schedules (#2177)
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

- **`area` vs. `shard`** (REVISED by S-1 of #2177 — this bullet used to say the
  shard is NOT in the registry at all): `area` is still identity (what failure
  reporting names). `shard` is now also in the entry, because #2177's generator has
  to emit a matrix and the eight row memberships lived nowhere but ci.yml's
  hand-written `pattern:` globs. What has NOT changed is that the shard is not a
  DERIVED field: today's values are hand-assigned data, transcribed from the
  current matrix and proved set-equal to it row by row, and nothing computes them.
  When the balancer (#2178) lands it becomes the writer of this field — see §7.
  `area` and `shard` are independent on purpose and already disagree for ~30
  entries (a gate is placed by measured cost, not by theme — ci.yml's own matrix
  comment says so at length).

  ⚠️ `shard = "other-job"` means "not scheduled by the `gates` matrix", NOT
  "unscheduled": 26 entries today run in `soundness`, `seed-health`, `wasm`, the
  docs jobs, `nightly` or the playground job. WHICH job is deliberately not
  modelled yet — #2177's generator only owns the `gates` matrix, and inventing a
  second, unverified job axis would have put unchecked data in the registry.
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

### 2a. The matrix rows: `[[shard]]` (S-1 of #2177)

The eight `gates` matrix rows are their own table at the bottom of
`test/gates.toml`, in matrix order — the per-ROW facts a per-GATE entry cannot
hold without 227 chances to disagree with itself:

```toml
[[shard]]
name         = "engines"
full_cores   = true                              # ci.yml's `full_cores: "1"` matrix key
wasm_arm     = true                              # ci.yml's `wasm_arm: "1"` matrix key
rationale    = "test/gate_shards/engines.txt"    # PATH to the row's placement prose
pinned_gates = ["pds/test/protocol_all_engines", "diff_compiler_engines", "diff_compiler_rejection_parity"]
```

- **Booleans, not `"1"`.** ci.yml OMITS the key when the option is off; that
  absence is the generator's encoding of `false`, not the registry's. Both keys
  are required on every row — a row that merely forgot `wasm_arm` would otherwise
  lose its Wasm toolchain and take its gates' Wasm arms down without a word.
- 🚨 **`pinned_gates` is a CLOSED ROW'S MEMBERSHIP, DECLARED — the one scheduling
  fact no cost measurement can derive.** A `full_cores` row is closed to the
  packer, which never moves a gate onto it or off it. That is right as a packing
  rule and was, on its own, a hole: the balancer seeded the row from whatever
  gates happened to name it, so the row was the last place a `shard` value was
  still hand-assignable, and a hand edit in either direction was ADOPTED by the
  next `medaka gate balance` run and reported "already balanced" ever after
  (review finding F3 of #2178, tracked as #2205). The worse half was moving the
  pinned gate OFF: a cost objective blind to the pin PREFERS that, because
  idling a whole runner and stacking the suite's heaviest gate onto a shared one
  improved the printed factor (measured: pole/median 1.005 against 1.073, under
  the metric §13 retired).

  So it is declared per row and checked against the registry in BOTH directions
  — a member not declared, and a declaration not a member — which is what makes
  it an invariant a wrong committed state can FAIL rather than a fiat under
  which whatever is committed defines itself as correct. An OPEN row declares
  `pinned_gates = []`, and a non-empty list on one is a hard error: its
  membership is the packer's output, so a declaration there is prose the tool
  would ignore, and a reader would take it for a constraint. Widening or
  narrowing a closed row is a deliberate CI-capacity decision, made in the same
  commit as the row's `test/gate_shards/<name>.txt` rationale — never a side
  effect of a baseline re-ingest. Pinned by `test/diff_compiler_gate_balance.sh`
  (the `pin_intruder`, `pin_deserter` and `pin_on_open_row` fixtures).
- **`rationale` is a path, not the prose.** Two reasons, and the first is
  decisive: the reader's TOML subset has no multi-line string (a `"""` is a hard
  parse error by design, `stdlib/toml.mdk`), so 180 lines of English would have to
  become one 8000-character line. The second is that the alternative shape —
  leaving the prose in ci.yml as hand-edited islands the generator preserves
  between markers — makes ci.yml simultaneously generated and hand-written, and
  makes generation depend on the previous ci.yml rather than on the registry
  alone. **This decision is settled; S-2 inherits it and must not re-open it.**
- **The files are `test/gate_shards/<name>.txt`**, holding the row's ci.yml
  comment block VERBATIM, one line per line, `#` and indentation stripped. The
  generator's encoding is exactly `("            # " + line).rstrip()`, which
  round-trips today's ci.yml byte-for-byte on all eight rows (blank prose lines
  come back as a bare `            #`). `.txt` and not `.md` keeps a verbatim copy
  of shell/YAML commentary out of the markdown link and symbol gates.
- **Only per-ROW prose lives here.** The matrix-level preamble above the first row
  (the "SHARDS ARE SCHEDULED BY COST" block and the quoting notes) is fixed
  template text, not per-row data: it belongs in the generator, not the registry.

## 3. The driver: `medaka gate`

In the `medaka` binary, dispatched beside `"test"`/`"snapshot"` (§7 Q2), implemented
in `compiler/tools/gate_cmd.mdk` beside `compiler/tools/test_cmd.mdk`:

- ✅ `medaka gate list [<selector>...] [--json] [--registry <path>]` — enumerate;
  machine-readable (`--json`) for the generator and preflight. LANDED (S-1).
- ✅ `medaka gate run <selector>` — runs the selection with per-gate scratch dirs,
  [G-STALE-ORACLE] refusal (with its CI-disabled arm), stderr-preserving capture, a
  cost-tier timeout, raw unnormalized exit codes, and a `--report` JSON timing
  artifact (#2180's future input). LANDED (S-3). **Sequential, not parallel** —
  `--jobs` is accepted but ignored; no fork/wait primitive exists in
  `stdlib/runtime.mdk` today, so a worker pool is future work, not this sprint's.
- ✅ `medaka gate verify` — the drift gate: every tracked `*.sh` under the gate roots
  is enrolled or explicitly listed as a non-gate tool; every entry's
  `run`/`oracles`/`corpus` targets exist; selectors resolve to ≥1 gate. Red on any
  divergence. Text-only, no build — runs everywhere, cheap. LANDED (S-4), wrapped in
  `test/diff_compiler_gate_registry.sh`.
- ✅ `medaka gate explain <path>` — the reverse lookup that didn't exist before this
  sprint: which gates does a changed path select, and why. Output uses
  `test/preflight.sh`'s own machine-readable prefixes so the two derivations diff
  line-for-line: `GATE <name> (sources:<glob> | corpus:<dir>)`, `FULL
  blast-radius:<prefix>`, `FULL unmatched-non-prose:<path>`, `UNMAPPED <path>`. LANDED
  (S-4, `sources`/`corpus` matching completed S-5).

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

- ~~**`shard` is HAND-ASSIGNED DATA AWAITING THE BALANCER, not a derived output.**~~
  **CLOSED (S-4-S-derived-assignment, #2178)** — `shard` is now a DERIVED OUTPUT.
  `medaka gate balance` (`compiler/tools/gate_cmd.mdk`) packs every schedulable
  gate onto the open rows from the per-gate costs in
  `test/gate_cost_baseline.json`, subject to each row's `wasm_arm` toolchain
  constraint and `full_cores` closure and to an enforced pole/floor budget (§13), and
  writes the `shard` values back; `make gen-ci` (`medaka gate ci`) then
  regenerates ci.yml's matrix from them. The landed rebalance moved 164 of 202
  gates and, under the SUM-of-medians model in use at the time, took the pole
  from 1143.6s to 948.9s (pole/median, then the enforced metric, 1.26 -> 1.073); that model was itself
  superseded soon after (#2207, "real-wall-shards"): CI does not run a row's
  gates one after another, `test/run_gates.sh` fans them out through an
  `xargs -P $JOBS` pool, so what CI actually pays for a row is the MAKESPAN
  over `$JOBS` workers, not their sum. `medaka gate balance` now scores each
  row by simulating that pool — an LPT bin-packing of the row's gates onto
  `$JOBS` worker buckets, the row's load being the fullest bucket — so the
  pole is whichever row's simulated makespan is largest under the CURRENT
  baseline and CURRENT assignment, and it moves with re-ingests and
  rebalances rather than sitting at a number this doc can pin. Read it live
  with `medaka gate balance --check`, which prints every row's makespan, the
  pole, the median, the FLOOR and the enforced pole/floor budget (§13); a gate
  is still indivisible, so a row holding one dominating gate still floors the
  pole at that gate's own cost — which since #2216 is a term in the metric's
  denominator rather than a red no one can repair.

  Since S-1 (#2208) each `runs[]` provenance row (`RunRecord`,
  `compiler/tools/gate_cost.mdk`) also carries the row's own `jobs` (workers
  CI actually used, consulted by `balJobsFor` to pick the worker count the
  row is modelled with — never a literal, since `$JOBS` is derived from the
  runner's core count), `parallel` (whether the fan-out actually ran
  concurrently; `jobs == 1` when it did not, regardless of the recorded
  worker count), and `rowElapsedMs` (the row's own real CI wall clock,
  spanning the whole fan-out) — the number `medaka gate balance`'s
  calibration lines report each row's makespan prediction against, so the
  model is checkable against something other than its own arithmetic. A
  fourth field, `gates` (F-2, #2178 review S2-1: the row's committed gate
  count at ingest time), lets that calibration line tell a reader whether the
  recorded run and the row's CURRENT assignment still describe the same gate
  set — a residual is only comparable while they do, which stops being true
  the moment a rebalance lands and stays false until the next ingest.

  The tier axis (`merge` | `nightly` | `ondemand`) is the other lever on the
  pole besides re-ingesting: a gate whose failure is a breadth check rather
  than a soundness one can be moved to `nightly` and stop costing the queue
  anything at all, rather than merely being packed onto a lighter row.
  `pds/nightly/repo_vectors_eval_engine.sh` (#2208, "S-2-pds-pole") is that
  mechanism in use: the interpreter's agreement with the compiled engines on
  the representative corpus used to be `pds/test/repo_vectors.sh`'s own pole
  gate at 948.9s (98.76% of that gate's own wall clock, under the SUM model
  above), so the assertion moved to nightly while native/Wasm parity on the
  same corpus — the soundness-bearing half — stayed in the queue.

  The three loose ends named here all close with it. (a) The per-row prose exists
  ONCE, in `test/gate_shards/*.txt`, emitted verbatim into the generated region —
  and it now describes the ROW (its options, its constraint) rather than any
  gate's placement, because placement is an output that moves whenever the
  baseline does. (b) Row membership is enforced, not proved once: the required
  `ci-gen-drift` context runs `medaka gate ci --check` (ci.yml == f(registry))
  AND `medaka gate balance --check` (registry == g(baseline)). (c) A hand edit
  reds. ⚠️ The first check ALONE does not catch one — edit `shard`, run
  `make gen-ci`, and the registry and the workflow agree with each other about a
  row nothing derived; the second is what closes that, and it is why S-3's
  hysteresis band no longer decides what is written (a band that keeps a
  divergent-but-close assignment makes "the derived assignment" a set, and a
  check can only police a value).

  ⚠️ ONE RESIDUAL, closed separately (#2205): closure alone left the closed row's
  membership seeded from `c.curRow`, so `engines` remained hand-assignable while
  the other seven rows were derived. It is now DECLARED in `pinned_gates` and
  checked in both directions (§2a).

  A new `[[gate]]` still needs SOME `shard` value — the schema requires the field.
  Write the row you would guess, or `other-job`; the balancer decides the real
  placement on its next run, and the required check says so before CI does.
- ~~`medaka gate verify` does NOT check that a `shard` value is one of the eight row
  names or `other-job`.~~ **CLOSED (S-4, #2177)** — but in the coverage gate, not in
  `verify`: `test/diff_compiler_ci_shard_coverage.sh` reds on a `shard` that is
  neither a `[[shard]]` row name nor `other-job`. It lives there because that gate
  already asks the neighbouring question (is `other-job` actually reachable?), and
  splitting the two would put half a verdict in each of two mechanisms — the defect
  §8 exists to remove.
- The `shard` axis is not a selector field: `medaka gate list shard:eval` is a
  `name:` glob, not a shard query. Deliberately out of S-1's scope; add it with
  the consumer that needs it.

- ~~Per-gate timing transport: committed file updated by a bot/nightly vs. fetched from
  the Actions API at balance time.~~ **CLOSED (S-1-S-cost-record, #2178)** — committed
  file, as the leaning said, and here is what was built:

  * **Producer: `test/run_gates.sh`, not `medaka gate run`.** `GATE_TIMING_JSON=<path>`
    makes a run also write a per-gate report; unset (every local invocation) it writes
    nothing and changes nothing. ⚠️ **This is a deliberate deviation from
    CI-ARCHITECTURE.md §3.3's "recorded by the driver".** The driver is not what CI
    executes — ci.yml's `Gate shard — …` step runs `sh test/run_gates.sh ${{
    steps.plan.outputs.pats }}` — and `medaka gate run` still does not reproduce
    `run_gates.sh`'s exit-code classification (the bullet below). A cost baseline has to
    be measured on the path CI actually takes, so the producer is that path. Adding
    timing there is behaviour-neutral to the classification: two `date` calls around an
    invocation that is otherwise untouched.
  * **Schema: `runReportJson`/`resultJson`'s (`compiler/tools/gate_cmd.mdk`), minus
    `stdout`/`stderr`.** A cost record has no use for a gate's output, and dropping it
    also removes the only place arbitrary gate text could sit inside the document the
    consumer scans. Envelope gains `schema` (`"gate-cost/1"`) and a `provenance` object
    (event, shard, runId, runAttempt, repo, ref, sha, date); `parallel` is `true` here,
    where the driver hardcodes `false`, because this runner really is parallel. Because
    the per-gate record is otherwise field-for-field the driver's, the day `gate run`
    becomes CI's executor the transport is unchanged.
  * **Transport: `test/gate_cost_baseline.json`, committed**, folded from N run reports
    by `test/gate_cost_ingest.sh`. Reviewability was the deciding argument and it holds:
    a rebalance diff can be read next to the numbers that caused it, the numbers are
    pinned at review time rather than re-fetched into a different answer, and the
    balancer needs no network and no token. Raw samples are retained beside each median
    so any reader can re-derive it — and so an outlier is visible in review rather than
    averaged into invisibility.
  * **Median, not mean, and the LOWER median for an even count.** One runner hiccup — a
    cold cache, a noisy neighbour, a retried step — is a single wild sample, and a mean
    lets it move a gate's placement; the median ignores it unless it is the majority
    behaviour, which is the question a balancer is actually asking. The lower median
    keeps the value integral and deterministic, so no float rounding churns the diff.
  * **Poisoning resistance is STRUCTURAL, on both sides.** `pull_request` is the one
    event ci.yml narrows (`detect`'s `plan` step), so its per-gate times are measured
    over a gate SUBSET and are not a baseline sample. `run_gates.sh` refuses to *produce*
    a report on that event at all, whatever ci.yml passes it; `gate_cost_ingest.sh`
    independently refuses to *admit* one whose recorded event is off its allowlist
    (`workflow_dispatch merge_group push schedule`) OR whose `runId`/`runAttempt`/
    `sha`/`ref` provenance fields are empty — both conditions must hold. The event
    allowlist alone stops a report tagged with a narrowed or unrecognized event string;
    it does not, by itself, stop a locally-produced report that merely CLAIMS an
    admissible event (e.g. hand-setting `GITHUB_EVENT_NAME=push` for a local run). The
    non-empty provenance check closes that gap: a real CI run of an admissible event
    always has `github.run_id`/`run_attempt`/`sha`/`ref` set by Actions, and nothing
    outside Actions sets them, so a locally-produced or replayed artifact is empty here
    by construction. Together the two checks are what stop a hand-carried, downloaded,
    or replayed artifact — or a future ci.yml edit — reaching the committed file. Both
    halves are graded by `test/diff_compiler_gate_cost.sh`, which also pins the median
    arithmetic, ingest idempotence, the "a failing gate contributes no sample" rule, and
    the committed baseline's agreement with its own samples.
  * **The balancer (S-4) now consumes this baseline** — `medaka gate balance` packs every
    schedulable gate onto its derived row from these per-gate costs. This bullet closes
    the transport question only; the consumer is described in the `shard` DERIVED OUTPUT
    section above.
- Whether preflight survives as a thin `medaka gate`-calling shim (agents' muscle
  memory, `make preflight`) — probably yes, indefinitely.
- `medaka gate run`'s worker pool: today it is sequential by construction (no
  fork/wait primitive in `stdlib/runtime.mdk`). #2177/#2178's generator can still
  read the registry for shard *composition*; a parallel `gate run` is separate
  future work, not blocking any consumer switch-over.
- `gate run` does not yet reproduce `run_gates.sh`'s exit-code CLASSIFICATION (the
  `sh -n` syntax pre-check, `LEGIT_SKIP_RE`, and the phantom-skip reclassification of
  an exit-2 whose message says an oracle was never built). It reports raw exit codes
  faithfully, which is correct for parity today, but whoever makes `gate run`
  authoritative over `run_gates.sh` must port that classifier's INTENT (not its
  regex verbatim — `run_gates.sh`'s own comment calls `LEGIT_SKIP_RE` a launderer,
  #2065).
- S-5's equivalence sweep found `sources`/`corpus` cannot be a literal
  transcription of preflight's ORDERED `case` table: case-arm precedence has no
  registry representation (the registry answers the union of all matching globs,
  which is documented to be the safe/wider direction — the one live consequence is
  #2196, a genuine preflight under-selection this sweep surfaced), and preflight's
  nearest-fixture-dir dispatch differs from `corpus`'s plain prefix containment for
  a fixture directory nested inside another one (today only
  `test/cross_project_fixtures/{goldens,twonames/goldens}`). Both gaps make the
  registry answer the SAME OR MORE than preflight, never less, over a 693-path
  swept corpus with zero narrower divergences — but a future consumer switch-over
  (#2177/#2179) inherits this shape difference and should re-check it, not assume
  it stays zero as the case table grows.
- Two real preflight bugs surfaced by the equivalence sweep, filed rather than
  fixed here (out of this sprint's behaviour-neutrality spine): #2196 (case-arm
  shadowing drops the `diff_compiler_check*` family for several
  `compiler/tools/*.mdk` files) and #2197 (an unquoted `$changed` expansion splits
  a space-bearing path into two fictional paths; no blast radius today).

## 8. The coverage authority (#2177 S-4, DECIDED)

`test/diff_compiler_ci_shard_coverage.sh` is **repointed, not retired**. It is the
**one** authority on CI reachability; `medaka gate verify` is the one authority on
enrolment; ci.yml's matrix has **no** readers left that re-derive shard membership
from it.

**What changed.** The script used to walk every workflow's
`strategy.matrix.include` for `{name, pattern}` rows and re-resolve each pattern
glob against `$ROOT/test/` and `$ROOT/` to work out which shard ran a gate. That
was a second answer to a question the registry now answers directly: the `shard`
field is on every entry (S-1), `medaka gate ci` generates the matrix from it (S-2),
and `medaka gate ci --check` proves the on-disk region still equals what
the registry generates (S-3). The script now reads `medaka gate list --json`'s
`shard` field and `medaka gate list --shards --json`'s row names, and reads **no**
matrix. Two mechanisms was the defect; two *files* was never the defect, which is
why the script survives.

**The registry-read is only sound if the matrix agrees (F-1).** Reading shard
membership from the registry says nothing about what CI runs unless ci.yml's matrix
still equals what the registry generates. `test/diff_compiler_ci_gen_drift.sh` asserts
that, and is itself REQUIRED (`ci-gen-drift` is one of the ruleset's required contexts —
derive, don't trust a list, AGENTS.md [W-REQUIRED-CHECKS]); at F-1 time it was still
advisory, so this script also runs `medaka gate ci --check` itself, as a plain
shell step ahead of its `python3` block, before it certifies anything — independent
proof at the required tier that does not depend on `ci-gen-drift`'s own tier. One mechanism
(`gate ci --check`), two callers — not a second mechanism.

**Why not retire it into `verify`.** The half nothing else in the tree can do is the
workflow scan: every `.github/workflows/*.yml` plus every
`.github/actions/*/action.yml` composite action (#1961), parsed to `run:`-step
bodies only (#1969), with `case`-arm mentions excluded. `verify` is text-over-the-
registry and reads no YAML; folding this in would make `gate_cmd.mdk` a workflow-YAML
parser — a genuinely new capability, for no gain over a `run:`-step scan that already
works.

**The division of labour.**

| Question | Authority |
|---|---|
| Is every `.sh` in the tree enrolled, or listed as a non-gate tool? | `medaka gate verify` (`test/diff_compiler_gate_registry.sh`) |
| Which shard runs a gate? | `test/gates.toml`'s `shard` field |
| Does ci.yml's matrix still equal what the registry generates? | `medaka gate ci --check` — called by `test/diff_compiler_ci_gen_drift.sh` (required) AND by `test/diff_compiler_ci_shard_coverage.sh` (required) |
| Is every registry entry actually reachable in CI? | `test/diff_compiler_ci_shard_coverage.sh` |
| Does a workflow `run:` step name a script no one enrolled? | `test/diff_compiler_ci_shard_coverage.sh` |
| Do ci.yml's and `gate_cmd.mdk`'s prose allowlists agree? | `test/diff_compiler_prose_classifier.sh` (#2200) |

**The four states are still all distinguished**, and are now *mutually exclusive*,
which they were not before. Precedence is: a `shard` naming a matrix row → in that
shard; else `other-job` and on the EXCEPTIONS ledger → EXCEPTED; else `other-job` and
named by a real `run:` step → NAMED; else UNREACHABLE (red). TOOLS entries are not
registry entries at all. The ledger now takes precedence over the `run:` scan on
purpose: `test/registry_keying_ratchet` is on the ledger *and* was being counted as
NAMED, because ci.yml mentions its path in a comment inside a `run:` body (the #1932
caveat the ledger entry itself documents) — so before S-4 the EXCEPTED state had
zero live members and nothing exercised it. Two new contradiction classes red as
well: an entry in a matrix row that is *also* on the EXCEPTIONS ledger, and a script
that is both a registry entry and a CI-COVERAGE-TOOLS.txt entry.

**Ledger formats are untouched** — same two files, same keys (repo-relative path
minus `.sh`, first whitespace token), same semantics, same staleness rule (an
EXCEPTIONS entry naming a script that no longer exists reds).

**Pattern resolution, counted (contract §4.17).** Six places re-derive run_gates'
two-glob rule (`$ROOT/test/<pat>.sh` + `$ROOT/<pat>.sh`): `test/run_gates.sh:173`,
`test/build_oracles.sh:388`, `test/preflight.sh:1134` and `:1338` (two, not one),
`test/diff_compiler_ci_shard_coverage.sh` — **removed by S-4** — and, inversely,
`gate_cmd.mdk`'s `ciCmdBody`, which emits the literal per-gate names the other five
resolve. Separately, three places re-extract `strategy.matrix.include` from workflow
YAML: this script (**removed by S-4**), `test/diff_compiler_project_enrolment.sh`'s
own inline reader, and `ciCmdBody` (which writes it). S-4 collapses one of each,
leaving five resolvers and two matrix readers; the rest belong to
`test/preflight.sh`'s and `test/build_oracles.sh`'s own switch-over, explicitly out
of this slice's scope.

## 9. The prose allowlist (#2200, ci.yml half)

`gate_cmd.mdk`'s `isProsePath` (layer 1b of `medaka gate explain`) is a hand-written
copy of the `case` block ci.yml's `detect` job runs to decide `docs_only`. Nothing
tied them together, so a `docs/` arm added to one and not the other would change what
CI skips with every gate green.

Closed with a **drift check**, not a derivation. Generating one from the other was
rejected: the shell arms live inside a `while read` loop in a hand-written job, and
`isProsePath` must stay a pure Medaka predicate the binary can answer offline — a
generator would have to own a fragment of a hand-written job and could still only be
checked by regenerating and diffing, which is what a drift check already is, at a
fraction of the machinery.

`test/diff_compiler_prose_classifier.sh` **extracts ci.yml's own `case` block**
between the whole-line markers `PROSE-ALLOWLIST:BEGIN`/`:END`, **runs it** with a stub
`nondoc`, and diffs its verdict against `medaka gate explain --prose <path>` over a
26-path probe corpus. So the left arm is ci.yml's real code, never a third copy of the
allowlist. The corpus straddles every arm boundary (`test/README.md` vs
`testfile.md`; `LICENSE.md` / `LICENSED.md` / `LICENSEE`; `docs/spec/SYNTAX.md` vs
`docs/spec/SYNTAX.md.bak`), and lives in the script rather than a fixture directory
because several probes are paths that deliberately do not exist. A missing marker is
exit 2, never a pass.

#2200's `test/preflight.sh` half — preflight's own path classification — is **not**
addressed here and stays open.

## 10. The packing statistic, and what its estimates are worth (#2222, S-2)

`medaka gate balance` packs shards from ONE number per gate: `medianMs` in
`test/gate_cost_baseline.json`, the **lower median** of that gate's retained raw
samples. Until S-2 that number was scheduled on **with no stated error** — every
figure the balancer printed was a point estimate presented as if exact, and the only
account of its accuracy was a prose claim in `balCalibLines` that the median
"systematically underestimates". Two neighbouring prose claims about the baseline's
sample state had already gone stale within two ingests.

**The statistic is RETAINED, and it is retained on a measurement.** All four families
#2222 named were compared, and the median won the axis a packer schedules on.

### The protocol, and why it is out-of-sample

An estimate scored against the samples that defined it is an in-sample residual and
is worth nothing: the median of three numbers is trivially close to those three
numbers. So: **leave one RUN out.** Each recorded run is held out in turn, every
gate's statistic is recomputed from the OTHER runs' samples only, and the sum of
those estimates is scored against the held-out run's actual total. No estimate is
ever graded against a sample that helped produce it.

Leaving out a *sample* requires knowing **which run that sample came from**, and
since FR-1 (#2222 review S0-1) that is **read, never inferred**. Each `gates[]` row
carries `sampleRuns`: one `runId` per element of `ms`, same length and same order,
empty where unknown. A gate is folded into the table below only if exactly one of its
`sampleRuns` entries matches each recorded `runId`; zero matches, ambiguous matches,
and unattributed samples all exclude it.

> ⚠️ **S-2 inferred this from a count, and the inference is unsound.** The argument
> was: a gate receives at most one sample per run, so a gate whose `samples` equals
> the number of distinct `runId`s in `runs[]` received exactly one from each, and
> `ms[i]` is run `i` in append order. The premise is true; the conclusion does not
> follow. `test/gate_cost_ingest.sh` trims `runs[]` by **row** count (`--max-runs`,
> one row per `runId:runAttempt:shard`) and each gate's `ms` by **sample** count
> (`--max-samples`), independently, per gate — nothing ties the two counters
> together. One more ingest in which a gate fails once puts that gate back at an
> equal count with the alignment wrong, and every fold then grades one run's estimate
> against a different run's measurement, at exit 0, with no warning. The pinned
> repro is `test/gate_balance_fixtures/oos_misaligned.{toml,json}`, whose `ms` arrays
> are byte-identical to `oos_attributed`'s precisely because the old computation
> could not tell the two files apart.

### The one command

```sh
medaka gate balance --check          # the block is printed in ORDINARY output
```

Reproduced by any reader from committed data, and re-derived on every run so it
cannot rot. On a baseline whose samples are attributed, it reads:

```
  out-of-sample error of the packing statistic (leave-one-run-out over the 3 runs in runs[],
  across the 2 of 3 schedulable gates carrying a run-attributed sample from every run):
    run 1             predicted      0.2s   actual      0.1s   +100.0%
    run 2             predicted      0.1s   actual      0.2s    -50.0%
    run 3             predicted      0.1s   actual      0.3s    -66.6%
    mean |error| 72.2%   systematic bias -33.3%
```

(that is `oos_attributed`, whose every fold is hand-derivable from the fixture; the
live figure is whatever the committed baseline currently supports.)

⚠️ **This is an UPPER BOUND on the production error, not an estimate of it.** Holding
out one of N samples trains the statistic at N-1, one below what the committed file
schedules from, and fewer samples is strictly worse. Read it as "no worse than this".

🚨 **On the tree as of FR-1 the block prints `not derivable`, and that is correct.**
`sampleRuns` did not exist when the committed baseline's samples were ingested, and
their provenance was never written down, so there is nothing to recover — backfilling
it by position would be the exact defect FR-1 removed. The line states the counts it
refuses on:

```
  out-of-sample error of the packing statistic: not derivable — 0 of 606 retained samples
  carry run attribution, and no schedulable gate carries an exactly attributed sample from
  each of the 3 recorded runs
```

It becomes a number again once enough attributed ingests have landed.

### Why the median won — the table

Per **row** (each row's predicted total against the held-out run's actual for that
same row), 8 rows × 3 held-out runs = 24 folds. ⚠️ Like §13's budget, this whole
table — the −12.6% included — is the **S-2 measurement as it was taken**, under the
positional attribution FR-1 retired. The choice of statistic it settled stands (the
`pds_test_repo_vectors` outlier argument below does not depend on the fold
alignment at all); the exact percentages are dated and want re-deriving from
attributed samples.

| candidate | median APE | p90 APE | folds >25% | bias |
|---|---|---|---|---|
| **median (lower, retained)** | 14.6% | **27.2%** | 5/24 | **−12.6%** |
| median (proper / even-avg) | 10.5% | 42.2% | 4/24 | −0.0% |
| upper quantile (upper median, max) | 12.8% | 48.2% | 5/24 | +12.6% |
| spread-widened (+0.25 / +0.50 / +1.00 × spread) | 11.9 / 10.5 / 12.8% | 26.4 / 42.2 / 48.2% | 4/4/5 | −6.3 / +0.0 / +12.6% |

Read that table honestly and it splits by axis. **On central tendency every
alternative beats the median** — it is systematically low, and −12.6% is the size of
that. **On the tail the median wins**, and the tail is the axis a packer schedules
on: a row's makespan is set by what it got wrong, not by what it got right on
average.

### What the whole result rests on — one gate, stated plainly

Removing a single gate inverts the table:

| candidate | median APE | p90 APE | bias | *(all 202 gates → 201, excluding `pds_test_repo_vectors`)* |
|---|---|---|---|---|
| median (lower) | 12.4% | 26.6% | −7.9% | now the WORST on every column |
| median (proper) | 9.0% | 16.3% | −0.0% | |
| upper quantile | 8.6% | 19.8% | +7.9% | |

`pds_test_repo_vectors` carries `ms = [948919, 14082, 18725]` — one sample **50.7×**
its own median, one runner hiccup among 606 committed samples (0.17%, or roughly one
per three CI runs at 202 gates a run). At the baseline's own sample count each
candidate prices that gate as:

| statistic | price | |
|---|---|---|
| **median** | **18725 ms** | the only one that is right |
| mean | 327242 ms | 17× |
| median + 0.25 × spread | 252434 ms | 13× |
| max | 948919 ms | 50× |

A 949-second misprice on one gate is enough to dominate an entire row. So the
robustness is not a nicety and the −12.6% is **the price of it**, reported rather
than corrected: any uplift factor that cancelled the bias would be a function of the
sample count it was fitted at and would over-correct at every other one.

Pinned by `test/gate_balance_fixtures/outlier_immunity.{json,toml}`, which is built
so the median and the alternatives disagree about an **assignment** and not merely a
printed value, with the mean-priced arm run as the red half.

### Consumers

`gate_cost.packStat` is the statistic as a named function; `median()` in
`test/gate_cost_ingest.sh` is its awk mirror, and the two are kept honest by
`balOosBlock` counting the committed rows where they disagree (expected 0, printed
only when not). **S-4's cost budget should cite the `systematic bias` figure the tool
prints, and cite it as a lower bound on a row's real cost** — the model predicts low,
by construction and by measurement.

## 11. Calibration staleness is a SET question, not a count (#2223, S-2)

`balCalibLine` prints each row's recorded CI wall clock against this model's
prediction. That residual only means anything while the recorded run and the
committed assignment describe **the same gate set**, and the line cannot tell on its
own: a residual reads identically whether the gate set moved or not.

F-2 closed half of it by comparing the run's recorded `gates` **count** against the
row's current count. **A count is not a set.** The commonest rebalance is a *swap* —
one gate leaves a row, another arrives — and a swap does not move a count, so the
annotation stayed silent on exactly the case it existed for (observed: a −96%
residual printing entirely clean, which reads as "the model is calibrated" when it
means "the model is being graded against a gate set that has not existed since the
rebalance").

Closed by recording a **gate-set digest** per `runs[]` row: `gatesDigest`, the sum of
a `h = h*131 + c` polynomial hash over that row's baseline keys, mod 2^31−1. A sum,
so it is order-independent — a report lists gates in pattern-resolution order and the
registry in enrolment order, and those differ. Its only consumer is an annotation, so
a collision costs a missing annotation and never a wrong assignment.

Two implementations, deliberately: `gate_cost.gateSetDigest` reads the committed side
and `_digest` in `test/gate_cost_ingest.sh` wrote the recorded side. They are pinned
against one shared constant from opposite directions —
`test/diff_compiler_gate_cost.sh` checks the awk (via `--digest`) and
`test/diff_compiler_gate_balance.sh` checks the Medaka (via `calib_staleness`'s row
`d`, which is unannotated only if the two agree).

`gatesDigest` is **optional**, like `jobs`/`parallel`/`gates` before it: a run
ingested before the field existed reads as unknown, and unknown is not stale. So the
24 rows already in the committed baseline keep exactly the count-only behaviour they
had and gain the set check at their next ingest — the fix is live for everything
ingested from here, and no digest was back-filled into a GENERATED file by inference.

## 12. Assignment stability: the incumbent is an INPUT, not a carve-out (#2218, S-3)

S-1 made cost re-ingests scheduled, so re-deriving the whole matrix went from
occasional to routine. That turned a known property of the packer into a standing
cost: the assignment is a function of noisy medians, and ordinary measurement noise
moves it. **Measured on the committed 202-gate registry**, perturbing every gate's
`medianMs` (and each of its `ms` samples) by ±2% and re-deriving:

| perturbation shape | churn before | churn after | pole before → after | pole/median before → after (§13 retired this metric; the figures are the S-3 measurement as taken) |
|---|---|---|---|---|
| index parity (even `+2%`, odd `−2%`) | 89 / 202 | **0** | 491.9s → 491.9s | 1.077 → 1.077 |
| opposite parity | 128 / 202 | **4** | 472.6s → 472.6s | 1.036 → 1.041 |
| name-hashed sign | 127 / 202 | **0** | 491.9s → 491.9s | 1.074 → 1.077 |

Method, reproducible: copy `test/gates.toml` and `test/gate_cost_baseline.json`,
scale every gate's `medianMs` and `ms` entries by `1 ± 0.02` with the sign chosen by
the shape, run `medaka gate balance --registry <copy> --baseline <perturbed>`, and
count `shard = "…"` lines that differ from the committed file. The "before" column is
the same run with the preference off, which the balancer computes on every run
anyway (see *What it costs*, below).

### The mechanism

`balPickStable` (`compiler/tools/gate_cmd.mdk`) takes the LPT pick as its baseline
and keeps the gate's **committed** row instead when all three of these hold:

1. the incumbent row is open, and
2. the incumbent row is **legal** for that gate (`wasm_arm`), and
3. the incumbent row is currently no more than `balStabPct` (5%) heavier than the
   lightest legal row.

Clause (3) compares the rows **before** the gate is added, not after. Both forms were
implemented and measured; the before-form caps the pole excess a hold can cause at 5%
of the lighter row's load, while the after-form's cap grows with the gate's own cost —
an expensive gate would earn *more* licence to sit on a heavy row, which is backwards
for an objective that is the pole. It also measured no worse (churn 0 / 4 / 0 against
the after-form's 0 / 7 / 5).

A consequence worth stating: early in the pack every row is near-empty, so the slack
is near zero and the biggest gates — the ones that set the pole's floor — are placed
by bare LPT with no preference at all. The preference only reaches the tail of small
gates, which is where the churn lives.

### Why this is not the hysteresis band that was reverted

**#2178 shipped a near-identical-looking mechanism and removed it, and the difference
is the whole reason this one is allowed to exist.** Read `balBandNote`'s doc-comment
before touching any of this.

The reverted band let the **committed assignment stand** whenever it scored within
`balMarginPct` of the derived target's pole. That made "the derived assignment" a
*set* rather than a value, and a check can only police a value: moving
`diff_compiler_source_bytes` from `tools` to `types` by hand shifted the pole by 0s,
so `medaka gate balance --check` reported *"already balanced"* and exited 0 — the
hand edit the whole `shard`-is-derived-data property exists to catch.

This is the opposite move. The incumbent is an **explicit argument** to the placement
decision, read from the committed registry (`Cand.curRow`, populated by `balCands`)
exactly like `cms` and `needsWasm`. `balTarget` is still a pure function — of
`(rows, costs, toolchains, incumbent shards)` — and still returns **one** assignment,
which `--check` re-derives from the same committed bytes and compares. Purity is a
property of the argument list, not of arguments being few. A hand edit here is
re-derived like everything else and survives only if the derivation independently
produces it, which is what "derived" means.

**Idempotence** — the property #2178 paid for — is preserved and argued in
`balPickStable`: on the balancer's own output every incumbent *is* the row the
previous run chose, so every placement repeats and the second run is byte-identical.
`test/diff_compiler_gate_balance.sh` asserts it three ways (§1's `--check` on the
committed tree, §2's `_bal_real`-twice on a scratch copy, §12's fixture run twice),
and all three perturbed registries above were verified byte-identical on a second
run.

**Legality is never traded.** Clause (2) is `balCurrentLegal`'s argument one layer
down: an illegal incumbent fails the predicate and is moved however cheap the repair
is. The `wasm_only_row` fixture is exactly that case and still passes.

### What it costs, stated on every run

The trade is churn against pole, so the balancer packs the same candidates a second
time with the preference **off** and prints both sides:

```
  stability: 89 of 202 gates held on their committed row (incumbent slack 5% of a
  row's load); pole 491.9s against 491.9s unstabilized (+0.0s), pole/floor 1.077
  against 1.077
```

(The trailing factor is `pole/floor` since §13; the numbers above are the S-3 run's,
which measured `pole/median`. The pole columns are unaffected — the metric change
moved the denominator, never the packing.)

On an unperturbed, already-balanced registry both numbers are **zero**, and that is
the healthy reading rather than a broken comparison: the committed assignment *is*
the packer's output, so every incumbent already equals the pick and the preference
never fires. It fires when the baseline moves under it, which is the only situation
it exists for.

The count is *gates held*, not *gates the two packings disagree about* — holding one
gate shifts the loads every later placement is measured against, so the two packings
can also disagree about gates that were themselves moved. `stability_preference` has
exactly one of each.

### The fixture

`test/gate_balance_fixtures/stability_preference.{toml,json}` carries the rule and its
limit in one registry, because a preference that always held would pass a fixture that
only proved holding. Two gates differ in exactly one respect — how heavy their
incumbent row had become by the time LPT reached them: `held` is placed while its row
is 2.6% heavier than the lightest and stays; `mover` is placed once its row is 7.7%
heavier and moves. The hold costs exactly 2.0s of pole (210.0s against bare LPT's
208.0s), and the gate asserts that number, so the trade cannot silently grow.

## 13. The enforced statement grades the PACKING, not the suite (#2216, S-4)

`pole / median` was the enforced target from #2178 until this. Its numerator is a
property of the packing; its **denominator is a property of the suite**, and that
mismatch made it move for reasons the balancer neither caused nor could repair —
in both directions.

**The slowdown direction.** The pole is one indivisible gate
(`diff_compiler_dict_semantics`, 482.2s). A 16–20% regression in that one gate raises
the pole and leaves the median where it is, so `medaka gate balance --check` refuses,
and `ci-gen-drift` — a REQUIRED context — goes red on every PR until someone who did
not write that gate makes it faster. No rebalance can help; the tool said so itself,
in the branch that printed *"this gate has to get FASTER"*.

**The speedup direction, which is the perverse one.** Make every non-pole gate four
times faster and `pole / median` **rises**, because the denominator falls and the
numerator does not. `test/gate_balance_fixtures/nonpole_speedup.toml` is that measured
against the pre-#2216 binary: an optimally packed seven-gate suite, refused at 3.333
against a target of 1.250, with the indivisible-gate message. A metric that reds
because the suite improved cannot be enforced; it can only be overridden.

### The floor

The replacement divides the pole by the **achievable pole** — the best pole any
assignment of this gate set onto these rows could reach. `balFloor` takes the largest
of three terms, each a bound the pole provably cannot go under:

1. **the most expensive single gate.** Gates are indivisible, so whichever row holds
   it has a makespan at least that big.
2. **the heaviest CLOSED row's makespan.** A `full_cores` row's membership is declared
   (`pinned_gates`, §7) and the packer moves nothing onto it or off it, so its load is
   fixed input.
3. **the open gates' total work over the open rows' worker SLOTS.** A row's capacity
   per unit of wall clock is its recorded `rjobs` workers, not one (`balJobsFor`,
   #2208), so `sum(rjobs) × pole >= total open work`. Counting rows instead of slots
   would inflate this term by roughly `jobs`×.

So `pole / floor >= 1.000` always, it is exactly 1.000 when the packing is optimal,
and it moves **only when the packing does**. Both perverse cases above score 1.000.

One valid term is deliberately omitted: the wasm-constrained gates' own work over the
wasm rows' slots. Leaving a valid term out makes the floor smaller and the ratio
larger — strictly stricter — so it cannot manufacture a false green.

⚠️ **The floor is a lower bound, not always an achievable makespan.** 500 + three 300s
over three rows floors at 500 and cannot finish before 600. So a miss can still be
indivisibility rather than packing, and `balEnforce` keeps two messages: when the floor
is gate-set it names that gate and says it has to get FASTER (or be split);
otherwise it blames the packing. `dominating_gate.toml` pins the first (1.200,
re-priced for this slice — a dominating gate *alone* is no longer a refusal) and
`lpt_packing_gap.toml` the second (1.222, the classic LPT worst case at three rows).

### The budget: 1.125, derived rather than chosen

The metric's optimum is 1.000 by construction, so the whole budget is packing slack
and there is no achieved-value term to leave room for. What it must absorb is
re-ingest **noise**, and §10 measured that out-of-sample rather than guessing:
leave-one-run-out over the 3 runs in `runs[]` across 202 of 202 schedulable gates,
per-run errors −21.1% / −6.1% / −9.0%, **mean |error| 12.0%, systematic bias −12.5%**.

> 🚨 **Those five numbers are one dated measurement, not a figure the tool
> re-derives.** They were taken at S-2 on the baseline as it then stood, by a
> `balOosBlock` that inferred each sample's run from its position in `ms`; FR-1
> (#2222 review S0-1) showed that inference unsound and replaced it with recorded
> per-sample attribution, so the block now reports `not derivable` for any baseline
> whose samples predate `sampleRuns` — including the one these numbers came from.
> The budget stands on the S-2 observation as history. **Re-derive it, and 1.125
> with it, once `medaka gate balance` prints a figure from attributed samples
> again** — and cite that run, not this paragraph.

    budget = 1 + max(mean |error|, |bias|) = 1 + max(0.120, 0.125) = 1.125

The larger of the two, because they are two ways of being wrong about the same
prediction. That is knowingly conservative — much of the measured error is common
mode, and a common-mode factor cancels in a ratio, so 12.5% is an upper bound on the
noise this metric can inherit rather than an estimate of it. Erring high is deliberate:
the failure mode of a too-tight budget is a red `ci-gen-drift` with no repair
available, which is the defect this section exists to remove.

It is still a real constraint. LPT's worst case is `4/3 − 1/(3m)`: 1.222 at three rows,
1.292 at the registry's eight — so a genuinely worst-case packing misses 1.125 and is
refused. Achieved on the committed registry when this landed: **1.000** (pole 482.2s =
`diff_compiler_dict_semantics` alone, which is also the floor), so the full 12.5% is
headroom.

### What the report prints

```
  pole 482.2s (sqlite)   median 453.4s   floor 482.2s   pole/floor 1.000
  floor: the achievable pole — set by 'diff_compiler_dict_semantics' alone (482.2s), which is indivisible.
         Moving the FLOOR means that gate has to get FASTER (or be split).
  ...
  budget pole/floor 1.125 — MET
```

The median is still printed and no longer enforces anything: it is the one number that
says at a glance how far the typical row sits from the pole. It is **not** a component
of the floor — a median is a property of the suite, and mixing one back in would
restore the perversity.

## 14. The budget governor: `medaka gate budget` (#2180, S-5)

Three-clause required, cheap, text-only gate (`test/diff_compiler_gate_budget.sh`,
enrolled `shard = "other-job"` for §13's own "cannot certify a number it can move"
reason). Reds when:

- **(a) uncosted.** A schedulable gate has no cost baseline entry (`balUncosted`'s
  condition). The contract's literal clause (a) — "a registry entry lacks a cost
  declaration" — cannot occur: `cost` is a REQUIRED TOML field, checked at parse time
  (`reqStr i "cost" e`), so a registry missing it never reaches this gate. `balUncosted`
  is the state that both occurs and matters: a declared class the packer still cannot
  price.
- **(b) over-class.** A gate's measured cost (`medianMs`) has eaten into the
  tolerance-adjusted timeout its declared `cost` class implies (`timeoutFor`: cheap
  300s / medium 900s / heavy 3600s). The tolerance is the SAME 1.125 as §13's budget
  (1 + max(S-2's mean |error| 12.0%, bias 12.5%) — a dated measurement, see §13's
  note) — one measured slack, used everywhere
  a noisy `medianMs` is compared to a hard line, because `medianMs` can UNDERSTATE a
  gate's true cost by that much. Concretely: a gate reds this clause once
  `medianMs > timeoutMs / 1.125`. This is not aspirational metadata — `cost` is what
  gets the gate KILLED, so "declared class no longer matches reality" is measurable
  exactly here, and nowhere is it phrased as "cheap should mean under 10 seconds"; that
  phrasing in §2's schema comment is aspirational and not what this clause enforces.
  Landing this gate found one live instance: `diff_compiler_dict_semantics` measured
  482.2s against a `cheap` (300s) declaration — re-classed to `medium` in the same
  commit that added the gate, not overridden away.
- **(c) pole/floor.** The projected `pole/floor` — the SAME number §13's
  `gate balance --check` derives, from `balCands`/`balRows`/`balTarget` — exceeds
  `balTargetMilli` (1.125). `balCands` already excludes `other-job` gates from packing
  entirely, so an `other-job` gate's (nonexistent) cost cannot move this number, this
  gate's own registry entry included — a governor able to inflate the number it grades
  by existing would be certifying the wrong thing.

### The override: a commit-message trailer, not a PR-body field

A `merge_group` run has no PR body — the queue tests a synthetic merge commit, not the
PR. The one thing it can always see is an **authored commit message** in the change
under test. So any clause may be accepted on purpose with a trailer:

```
Gate-Budget-Override: <token>  [free-text reason, never machine-checked]
```

where `<token>` is `uncosted:<gate-name>`, `over-class:<gate-name>`, or the literal
`pole-floor` — one line per violation accepted. `gate_cmd.mdk` never touches git itself
(it stays testable on plain strings via `--commit-message`). The failing gate prints the
exact trailer to paste for each unacknowledged violation, so the remedy is inline for a
reader with no other context, and every acceptance is a `grep`-able line in `git log`
forever — an auditable artifact, not silent creep.

#### 🚨 Where the trailer is read from — `git log -1` on HEAD is WRONG on CI

As landed, S-5 read the trailer with `git log -1 --pretty=%B` on the checked-out HEAD and
justified it as "ordinary git behaviour, no GitHub-specific API, so it needs no separate
verification against GitHub policy". **That reasoning was the bug** (review finding S1-2,
fixed by FR-2): it is not a GitHub *policy* question at all, it is a question about the
git state `actions/checkout@v4` actually produces. With no explicit `ref:`, checkout
resolves a **synthetic merge commit** on both events that gate a merge — `refs/pull/N/merge`
on `pull_request`, the queue's auto-merge commit on `merge_group` — and that commit's
message is GitHub-authored boilerplate, never the author's. Measured on this repo's own
history: PR #2212's queue commit `93a40382` reads `Merge pull request #2212 from ...`,
while its **second parent** `1c1b48f3` (the PR branch tip an agent wrote) carries the real
message. So the override was readable locally and via `--commit-message`, and unreadable on
every event that could ever need it — an un-overridable required governor, i.e. a deadlock.

The mechanism now has two halves:

- **`.github/workflows/ci.yml`, the `gate-budget:` job's *Resolve the authored commit
  message(s)* step** re-derives the authored range from the **event payload's** SHAs —
  `pull_request.base.sha..pull_request.head.sha`, or `merge_group.base_sha..head_sha` —
  makes those objects reachable with the same targeted `git fetch --no-tags --depth=…`
  pattern the `detect` job uses, reads `git log --pretty=%B <base>..<head>`, and exports the
  result as `GATE_BUDGET_COMMIT_MSG`. A RANGE, not one commit, so the trailer counts on any
  authored commit in the PR and on any PR batched into a multi-PR merge group — a `^2`-only
  read would miss every PR but the newest in the batch. If the range cannot be resolved it
  falls back to the head commit, or on `merge_group` to `<head>^2`. On
  `push`/`workflow_dispatch`/`schedule` — which check out the author's real commit — it
  exports nothing and behaviour is unchanged.
- **`test/diff_compiler_gate_budget.sh`** prefers `GATE_BUDGET_COMMIT_MSG` whenever it is
  **set**, and falls back to `git log -1 --pretty=%B` on HEAD only when it is entirely
  **absent** — a local or manual run, where HEAD really is the authored commit. The test is
  `+set`, not `-n`, deliberately: set-but-empty means "CI resolved the range and found no
  override text", which must stay fail-CLOSED rather than silently re-reading the synthetic
  merge commit.

The generalisable lesson: *"ordinary git behaviour" is not a reason to skip verification when
something else chose the checkout.*

### Why a job and not a `gates` matrix row

Same shape and same reason as §13's `gate-balance` job: this gate grades a number
(the projected pole/floor) that a packing bug could move if the gate itself were
packed, so it cannot be a member of the set it certifies.

### Not yet required

`ci-gen-drift` is the one context of this family actually in the required-checks
ruleset today; `gate-cost`, `gate-balance`, and this gate's `gate-budget` job are not.
Adding a required context is a separate, non-atomic `gh api` ruleset edit
(AGENTS.md [W-REQUIRED-CHECKS]) — out of scope for this slice; see its report for the
exact command.
