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
  improves pole/median (measured: 1.005 against 1.073).

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
  constraint and `full_cores` closure and to an enforced pole/median budget, and
  writes the `shard` values back; `make gen-ci` (`medaka gate ci`) then
  regenerates ci.yml's matrix from them. The landed rebalance moved 164 of 202
  gates and took the pole from 1143.6s to 948.9s (pole/median 1.26 -> 1.073);
  948.9s is the pole FLOOR, since gates are indivisible and one gate alone costs
  that.

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
