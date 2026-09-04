# TESTING-ARCHITECTURE.md — the target testing architecture, and the migration to it

**Status:** PROPOSED 2026-09-03, from a two-round survey at `5397afc9c` (Val's brief:
the project is well tested but defaults to shell for checks, never dogfoods its own test
vehicle, and nobody evaluates where a test fits or what it costs), amended the same day
after an independent review (§12). Tracked by the testing-architecture epic #2600 (see
§11). This document is the design authority for that epic; `docs/ops/TESTING-DESIGN.md`
(2026-07-13) keeps its §0–§3 as the diagnosis history and its §4–§7 are superseded here.
The per-gate survey table lives in `docs/ops/TESTING-INVENTORY.md`.

The numbers in §1 are dated. Re-derive before quoting them as current; the epic's
registry slice (§5, wave 0) turns the classification into data `medaka gate verify`
checks, after which the inventory file is history.

---

## 0. One-paragraph version

The suite is 288 shell scripts (72,643 lines) because the native vehicle cannot host a
check whose subject is the compiler binary: `test`/`prop` blocks run under the interpreter
only, with no file IO and no subprocess, and one panic kills the run. Agents were right to
write shell, and the docs then taught the next agent to copy them. CI time is a separate
problem with a separate lever: one deterministic Callgrind gate sits alone on the critical
path, the pds crypto suites are 30% of modeled cost, and the budget check that would make
a new gate's cost visible exists but is not required. Duplication is real but costs about
five seconds of CPU; what it costs is maintenance. The fix is one keystone capability — run
`test` blocks on the native engine, with the compiled probe printing operands and the
driver comparing, on the pattern `compiler/tools/native_doctest.mdk` already uses for
doctests — which supplies the registry's declared-but-unbuilt `kind = "native"` runner,
file IO and subprocess in tests, and interpreter speed relief. Per-file panic containment
is the runner's, engine-independent, and lands alongside. With those in place 191 of 212
migration candidates become mechanically expressible, in three waves, each PR deleting
the script it replaces and showing the new gate red on a break the old one caught.

---

## 1. What the survey measured

Seven reports, scratch-only; the load-bearing numbers, each with its source report.
"review" marks a number the independent reviewer measured first-hand (§12).

| Measure | Value | Report |
|---|---|---|
| Tracked gate scripts / lines | 288 / 72,643 (256 registered, 32 ledgered tools) | A |
| Scripts sourcing any shared helper | 16 (5.6%); 191 re-implement `mktemp`, 175 `trap` | A |
| `strip_unit` definitions | 41 inline copies in **7 semantically distinct variants** under one name | A |
| Shape | GOLDEN 93 · DIFFERENTIAL 74 · RATCHET 29 · PERF 14 · CLI 14 · TRUST-ANCHOR 14 · other 50 | A |
| Subject engine | native 125 · multiple 60 · interpreter 33 · wasm 8 · none 62 | A |
| Registry `kind = "native"` entries | **0 of 256**; `gate run` has no dispatch for it (`gate_cmd.mdk:1161`) | A, I |
| New shell scripts, last 60 days | 174 files in 163 commits: **135 registered gates**, 16 ledgered tools, 12 censuses, 11 helpers/fixtures. Native side: 75 commits adding `test`/`prop` decls, 26 new `*_test.mdk` files. On gates alone, ~2:1 shell to native by commit | E, review |
| Shell-adding commits stating why shell | 1 of 163. This measures the absence of a convention that did not exist, against a vehicle that could not run the subject; it is not a measured cause | E |
| Measured gates / modeled cost | 222 / 5,387 s (~90 CPU-min); top-10 = 58%; 130 gates < 5 s = 3.9% | C, D |
| Merge-queue wall (run 33698130338) | 1,082 s; critical path = `build` 170 s → `gates_5` 891 s; next row `gates_6` 663 s | D |
| `gates_5` contents | one gate, `diff_compiler_stage_ir_scaling` (median 648 s over 9 CI samples, range 460–782) | D, H |
| pds share of modeled cost | 1,589 s (29.5%); all subprojects 34.8% | C, D |
| CPU saved by removing every genuine duplicate | ~5 s; ~7 s if the `bootstrap_*` ladder is retired (a decision §5.2 leaves to the owner); ~28 near-clone scripts, 108 redundant goldens | C |
| Gate-budget enforcement | built (3 clauses + override trailer), **not a required check** — left non-required as sequencing ("a separate, non-atomic ruleset edit"), not as a decision against | D |
| Native vehicle real deficiencies | no IO/subprocess under eval (`testCapableExterns` = 5 names); a panic kills the run and every later file on a dir target; no derived `*_test.mdk` discovery | B |
| Native vehicle folklore that is false | takes one file (dirs and multi-target work); sibling can't see subject (it loads the graph); doesn't typecheck (it does, except under paths without a `compiler`/`stdlib` segment — all 24 pds/sqlite `_test.mdk` files) | B |
| `medaka test` on `pds/test/scalar_test.mdk` | 311–324 s wall for 38 decls, **dev box**. Separately: the whole 15-file `pds_test_inlang_test_oracle` gate is a 419 s **CI** median. Different machines, so no share is quoted; the direction (one file dominates) is the finding | B, F |
| pds native `_main.mdk` drivers kept because eval is too slow | 26 files; one measured 4 min → 4 s eval→native | F |
| One native build of a minimal gate-shaped program | 1.6–1.9 s wall on the dev box, against 0.27 s for `mq/test/check.sh` end to end today; 109 of the 191 unblocked gates have a CI median under 5 s | review |
| Gates expressible natively today | **1** of 288 | I |
| Gates mechanically expressible once a native-kind runner exists | **191** of the 212 candidates (shape, not green) | I |
| Gates that stay shell, with a reason | 43 (25 trust anchors, 11 instrumentation, 7 external harness) | I |
| `sources = []` in the registry | 45 gates, including every wasm gate | C |

---

## 2. Diagnosis: two problems, two levers

**Shell sprawl and CI time are not the same problem.** Removing every duplicate saves a
few seconds. Migrating every migratable script to Medaka does not reduce CI time (the same
programs run) and adds one clang build per gate-test file: for the 109 unblocked gates
that run under 5 s today, that is a 30–60× multiple of the dedupe saving unless gate-tests
are batched per fixture corpus (§5.2's wave-1 cutting rule). Conversely, the three gates
that dominate the critical path are ones that will stay shell (Callgrind instrumentation).
So:

- **P1 — the vehicle.** A check whose subject is the compiler binary needs to spawn it,
  read fixtures, compare text, and survive a crash. The native vehicle offers none of
  that under the only engine that runs `test` blocks. Agents chose shell because it was
  the only vehicle that worked, then the router's "add cases to the gate matching the
  stage changed" and the sprint packet's gate-shaped acceptance vocabulary made it the
  default for the next agent (E §Part 3). Lever: build the capability, then change the
  words.
- **P2 — cost governance.** Cost is concentrated (three gates, one project) and the
  brake is switched off. Lever: a merge-tier proxy for the pole, `gate-budget` required,
  and the native arm making the pds in-language suite cheap enough to keep.
- **P3 — dedupe and placement.** Not a cost problem; a maintenance and honesty problem
  (7 `strip_unit`s, 45 empty `sources`, 6 undeclared corpus readers, clone families).
  Lever: registry data hygiene and one runner per clone family, folded into the waves.

---

## 3. Target architecture: the vehicle ladder

Every check has exactly one home. The rungs, top to bottom:

| Rung | Construct | Engine | Subject | Verdict rendered by | Lives |
|---|---|---|---|---|---|
| **Doctest** | `-- > expr` | eval + native (`--engines`) | an exported function's value, for a reader | driver compares rendered value | in the doc comment |
| **Property** | `prop "…" (x : T) = Bool` | eval (native later) | a law over generated inputs | driver | in-file |
| **Unit** | `test "…" = Expectation` | eval, and native via `--engines` | pure library/compiler-internal computation | driver | `<module>_test.mdk` sibling |
| **Gate-test** (new rung) | `test "…" = Expectation` with IO | **native** (`medaka test --native`) | the compiler binary: a verb over fixtures, a golden, a CLI contract, a cross-engine diff | driver compares the operands the probe prints | `test/<area>/<name>_test.mdk`, registered `kind = "native"` |
| **Trust anchor** | shell | — | the machinery the rungs above run inside | external `diff`/`cmp` | `test/*.sh` with a `shell-because:` header line |

Unit and gate-test are the same construct differing in engine, IO, and directory. The
inventory's T/N column is therefore an engine split, not a vehicle split: 29 of the 191
have an interpreter subject, and a gate-test that spawns `./medaka run` preserves that.
Gate-tests live under `test/<area>/`, not beside a subject, so [P-TEST-SIBLING]'s
fingerprint and snapshot subtractions do not apply to them. After migration, gate-tests
will outnumber real unit siblings roughly 7:1; that is shell rewritten in Medaka, which is
what was asked for, and it is not the same thing as more unit tests.

The gate-test rung is what the registry's `kind = "native"` was declared for and what
§1's "191 of 212" migrate to. Its contract is `native_doctest.mdk`'s, restated for
`test` decls with one correction the review forced:

- **The probe prints operands; the driver compares.** Today `Expectation` is
  `Pass | Fail String` (`stdlib/test.mdk:12`) and `expectEqual` computes `==` inside the
  probe (`:63-68`). A probe that printed `Pass` would let a miscompiled `Eq` dispatch, or
  the `if` inside `expectEqual`, mark its own homework, and the driver would re-read a
  verdict, not a value. So §4.3 item 1 (an `Expectation` carrying the rendered operands on
  BOTH outcomes) defines what the probe prints before §4.1 defines the sentinel format,
  and the driver re-runs the comparison on the renderings it reads. What this buys is
  honest but bounded: the driver is the same `medaka` binary that compiled the probe and
  that the gate-test spawns as its subject ([D-RUN-VS-BUILD], three ways over), so "one
  process boundary out" separates execution from reading and adds no independent
  observer. The independent observer is §8's floor — the differential and fixpoint tiers
  — and a migrated gate is never the sole thing between a miscompile and green.
- **A panic is a dead probe, not an exception.** The probe is a child process; if it
  dies at test 9 of 64, tests 10–64 report `Errored` naming the abort, never dropped.
  This is the 2026-06-10 decision (no catch/recover primitive; tooling survives panics
  by process isolation) applied to the unit tier. Nothing is added to the language.
- **Under eval the same file stays pure.** The eval arm keeps `testCapableExterns` as it
  is. A `test` body that needs IO is a gate-test by definition and is run native; a file
  that runs under both engines is a two-engine differential of the unit tier, which is
  the compensator TESTING-DESIGN §4.2 claims for that tier and the binary does not
  provide today. Its consumer is named, not assumed: `make test` (wave 0b) runs the unit
  siblings under `--engines eval,native`.
- **Where a golden is the sole oracle, the check stays shell.** "Sole oracle" means a
  golden whose subject has no differential or fixpoint coverage: `test/selfproc_goldens/
  legA` ([T-LEGA-GOLDEN]) and the bootstrap/fixpoint/seed family. It does not mean every
  single-computation golden: `check_json`'s and `fmt`'s goldens are backstopped by the
  snapshot suite and the fixpoint, so they migrate. That answers the tiebreak #2298's
  review left open. Its second question — does orchestration BY `medaka gate` count as
  harness dependence — is answered by GATE-REGISTRY-DESIGN §5, which already accepted
  that circularity for the driver on the condition that `verify` stays text-only and the
  generated `ci.yml` carries the full gate list statically. It does not count.

**What "native gate module" means concretely.** A `*_test.mdk` file, in Medaka, using
`stdlib/test.mdk` plus a small gate library (§4.3): enumerate a fixture directory, run a
verb (`runCommand` on `./medaka`, or a stage function directly), normalize, compare to a
golden with a line diff, and return an `Expectation` per fixture. The registry entry's
`run` field names the file; `medaka gate run` executes `medaka test --native <file>` in a
child and reads its `--json`. The shell wrapper is gone; the gate is data plus Medaka.

---

## 4. The keystone: run `test` blocks on the native engine

One capability sits under every other item in this document. Issue #2299 deferred it
past 0.1.0 as "coherent while `medaka test` stays interpreter-scoped"; the survey shows
the deferral is what keeps 191 gates in shell and the pds suite at five minutes per file.
It is pulled forward (§7).

**Two cheaper doors, and why this one.** (a) A compiled-`main` native kind — `gate run`
does `medaka build <file> && ./bin`, exit code as verdict — is what the inventory's
blocker literally names and what pds's 26 `_main.mdk` drivers already are; it unblocks
the same 191 with no test-runner work. (b) Read-only IO under eval — the six existing
`pReadFile`/`pListDir`/… bindings added to `testCapableExterns` (report B §(d)) plus
containment — makes the ~40 interpreter-subject golden gates native for S–M effort. The
`test` arm is chosen over (a) because a bare `main` has no per-test reporting, no
`--filter`/`--json`, no shared assertion vocabulary, and does not dogfood the vehicle Val
asked to dogfood; and over (b) because (b) leaves ~150 gates in shell and the five-name
allowlist is a deliberate boundary this document keeps. Neither door is closed by this
choice; (a) in particular is what the registry dispatch does under the hood.

### 4.1 Design

- **Engine, not language.** `tools/native_doctest.mdk` compiles a module plus
  synthesized bindings into one probe binary that prints one value per example between
  sentinels, with the abort rule; it is the template. It is not shared code: the eval arm
  evaluates elaborated `DTest` bodies directly (`runTestDeclsSingle`,
  `test_cmd.mdk:1082-1100`), so wave 0a writes the synth generator for `test` decls, gives
  `runTestDecls` (`:1026-1053`) an `Engine` parameter as the doctest phase has, tags the
  `test` phase's `--json` by engine, and handles the multi-module (`hasUseDecls`) path.
  `--native`/`--engines` stop being inert for the `test` phase (B §2). Sizing: medium-plus.
- **Effect row.** `test "…" = Expectation` is unified against `Expectation` only
  (`typecheck.mdk:29386`) and effects are not tracked on `DTest` bodies, which is why a
  synthesized `main` can evaluate an IO-bearing body with no typechecker change. The eval
  arm continues to reject at run time anything outside the allowlist; making that visible
  BEFORE running (a `test`-body extern outside the allowlist is a diagnostic from
  `medaka test`'s eval-arm pre-check, not an `E-PANIC` mid-run) is part of the same slice.
  Not from `medaka check`: `check` has no engine, so a check-time red would fail every
  gate-test file, the pre-commit hook included.
- **Props** get the same arm later; the generator runs in the driver and only the
  evaluation moves, so it is a smaller follow-on, not part of the keystone.
- **Discovery and containment (engine-independent; wave 0b).** On a directory or
  multi-file target the driver runs each file's probe (native) or each file's interpreter
  run (eval) in a child and aggregates; a dead file names itself and the walk continues.
  Measure the per-file prelude re-parse under eval when this lands. Per-test isolation is
  not required for gate-tests (the subject already runs in a spawned `./medaka`) and is
  loud-not-silent for unit siblings; if ever wanted it is one probe run per test, which
  the one-build-per-file scheme makes cheap. `*_test.mdk` discovery is derived from the
  tree (`collectMdkFiles`), with the roster-completeness check
  `pds/test/inlang_test_oracle.sh:37-50` already implements as the model.
- **Typecheck scoping.** `hasVehicleSegment` (`test_cmd.mdk:322-327`) restricts the
  `_test.mdk` typecheck guarantee to paths containing `compiler`/`stdlib`; it widens to
  every project's `test/` directory. Expect a batch of newly surfaced type errors in
  pds/sqlite (B §6, #2527).

### 4.2 Registry seam

`kind = "native"`, `run = "<path>_test.mdk"`. `gate run` dispatches on `kind`;
`gate verify` checks the file exists and is a `_test.mdk`; `gate explain`, preflight, and
the generator need no change because `sources`/`corpus` carry selection. Cost is measured
the same way. The `shard` remains derived ([W-SHARD-DERIVED]).

A second field records the classification the inventory derived by hand, so the
migration's own bookkeeping lives where `verify` reads it:

```toml
migration = "native-wrap"      # native-wrap | native-rewrite | shell:trust-anchor |
                               #   shell:instrumentation | shell:external-harness |
                               #   split-first | inverted-polarity | done
```

`gate verify` fails when a `kind = "exec"` entry has no `migration` value, and when a
`shell:*` entry's script lacks a `shell-because:` header line naming the same reason.
That is the mechanism behind "shell stays only with a stated reason" (#2298). **The
release valve is stated, not implied:** while the vehicle is being built, a needed
fixture-run-compare gate written in shell enrols with `migration = "native-wrap"`; that
is a debt row the waves drain, not a violation, and it needs no header. The closed
`shell:*` enum is for scripts that will never migrate.

**This field and its `verify` pairing land first, alone, before any of §4.1.** They need
nothing from the native arm, they are the only brake on the 174-scripts-per-60-days
bleed, and seeding 256 rows in one PR conflicts with every concurrent gate-adding PR, so
it must be that PR's only content. `balSplice` (`gate_cmd.mdk:4693-4702`) is
line-targeted, so the cost auto-lander will not drop the new field.

`migration` is a claim. `verify` checks its shape and its pairing with the header, not
its truth; the truth is the inventory's method, re-run when the count drifts.

### 4.3 The gate library (`stdlib/test.mdk` growth, plus a compiler-side helper module)

In dependency order, each small:

1. **Structured `Expectation`.** Today `Fail` carries one opaque `String`, so
   `runOneTest` fills `ExResult`'s `Fail expected actual` as `Fail msg ""`
   (`compiler/tools/test_runner.mdk:52`) and `--json` shows an empty `actual`. Widen it so
   the rendered operands travel on BOTH outcomes; this is what lets the probe print and
   the driver compare (§3), and every diff feature is downstream. **Precedes §4.1's
   sentinel format.**
2. `expectOk` / `expectErr` / `expectSome` / `expectNone` / `expectWithin` (#431;
   `approxEq` already exists at `stdlib/math.mdk:98`).
3. `expectEqualText : String -> String -> Expectation` rendering a **line diff**, plus a
   normalization helper (strip trailing `()`/`0`), the one honest replacement for the
   seven `strip_unit`s.
4. `runVerb : List String -> <IO> Result … (exit, stdout, stderr)` over `runCommand`,
   with the [D-BUILD-PIPE] and [B-STDERR] disciplines baked in once.
5. Fixture-directory enumeration with the anti-vacuity floor (a corpus of zero files is
   a failure, the pds wrapper's rule).
6. Golden helpers: `expectGolden path actual`, with blessing kept **in shell** for the
   first waves (`CAPTURE=1`), so the native side needs read capability only. A
   `medaka test --promote` (TESTING-DESIGN §4.7) is a later slice with its own write
   policy (§10).

---

## 5. Migration order

Derived from the inventory's unblock ranking (I §2): the runner alone unblocks 191; a
golden library is next (101 carry `GOLDEN-ASSERT`); probe retirement is the largest
rewrite (68 carry `ORACLE-PROBE`); 13 scripts must be split before any verdict applies;
8 inverted-polarity pins need a registry field the schema lacks.

### 5.1 Blocker vocabulary (the inventory's codes)

`TRUST-ANCHOR` never migrates · `NATIVE-KIND-RUNNER` the keystone · `GOLDEN-ASSERT`
needs §4.3 items 3 and 6 · `ORACLE-PROBE` drives `test/bin/*`; wrappable now, a rewrite
retires the probe · `EXTERNAL-TOOL` free under native (a module may spawn) ·
`SECTION-SPLIT` editorial split first · `INVERTED-POLARITY` a per-pin drain field ·
`TEST-IO`/`TEST-SUBPROCESS`/`NATIVE-ENGINE-TESTS` the eval-arm walls, dissolved by the
native arm · `PANIC-CONTAINMENT` dissolved by wave 0b under either engine ·
`NOT-A-CHECK` out of the denominator.

### 5.2 Waves

| Wave | Contents | Count | Exit criterion |
|---|---|---:|---|
| **0-i — the ratchet, alone** | §4.2's `migration` field seeded from the inventory, the `shell-because:` pairing in `gate verify`; nothing else in the PR | — | `verify` reds on a new `.sh` under a gate root with no pairing; `native-wrap` accepted as the debt value |
| **0 — keystone** | §4.3 item 1 (structured `Expectation`), then §4.1's native arm and sentinel format; containment + discovery + typecheck scoping; §4.3 items 2–5; `--filter` no-match red (#2340); `make test` runs unit siblings under `--engines eval,native`; `kind = "native"` dispatch | — | `medaka test --native` runs a `test` file that reads a fixture and spawns `./medaka`; a dir run survives a dead file; one `kind = "native"` gate green in CI; one gate-test build timed on a CI runner |
| **1 — pure wraps** | the 83 gates carrying only the runner blocker: the three project `check` wrappers first (18–25 lines each), then `effect_*_domain`, then by cost (`call_arity` 185 s, `import_order` 105 s, …). **Cutting rule: one `_test.mdk` per fixture corpus or area, never one per script** — 109 of the 191 targets run under 5 s today and a clang build is ~2 s (measured, dev box: a trivial one-assertion native probe floor is 1.6–1.7 s wall; `effect_set_domain`'s post-migration delta — the native run's 2.77 s minus the reconstructed pre-migration script's 1.13 s — is ~1.6 s, matching the floor alone, because both arms run the identical 5 assertions; a gate whose pre-migration cost already exceeds the floor, like `parsec/test/check` at 1.27 s median, inflates by a smaller ratio than one near-zero, like `mq/test/check` at 152 ms, which is why the three cheapest gates in the tree are the worst-case ratio, not the worst-case absolute cost) | 83 | each PR passes the parity-plus-red rule below and deletes its script |
| **2 — golden families as data** | the 43 `GOLDEN-ASSERT` gates plus the clone families: snapshot ×9 → one runner + 9 rows, `core_ir_X`/`eval_X` ×4 → one runner + 8 rows, lsp ×3, `_batch` ×5 folded into siblings, `cross_project` pair | 43 + ~20 | §4.3 item 6 lands first; 108 redundant goldens gone or explicitly kept; `strip_unit` count is 0 |
| **3 — probe retirement** | the 62 `ORACLE-PROBE` rewrites: stage functions called as a library; each retires a `compiler/entries/*` probe and a `build_oracles.sh` row | 62 | `test/bin/` shrinks with each PR; `[L-PHANTOM-SKIP]` class shrinks with it |
| **walls** | split the 13 mixed scripts (`dict_semantics` 1,643 lines, `check_cli_modules` 2,926); add the inverted-polarity field and route the 8 pins through the must-fail drain protocol; decide the 4 UNSURE (`diff_compiler_test`, `vector_provenance`, `ported`, `tmc_census`) | 25 | each becomes a wave-1/2/3 row or a `shell:*` reason |

At 5–10 gates per sprint, waves 1–3 are roughly 25–45 sprints. That total is stated so
the epic is not mistaken for a quarter's work; it competes for the same implementer
capacity as #1985's queues, none of which name testing, and none of which it blocks.

Owner's calls the waves surface rather than decide: retire the `bootstrap_*` ladder
(4 gates, 108 OCaml-era goldens, `compiler/BOOTSTRAP.md` milestones) or keep it as
executable history; whether `diff_compiler_test.sh`'s OCaml-era goldens still prove
anything.

**Parity-plus-red rule for every migration PR.** Old script and new gate-test pass on the
same tree once — and the new gate is shown RED on one deliberate break the old gate caught
(a mutated fixture, a corrupted golden, a `did_key_all_engines.sh`-style mutation row),
then green again. "Both green once" is exactly the condition under which TESTING-DESIGN
§0.0.2's gate-that-could-not-fail landed, and [WT-GOLDEN-ENSHRINES] says the same for
goldens; the demonstrated red is the only cheap proof the migration carried the
property across. Then the script is deleted in that PR, the registry row flips `kind` and
`migration = "done"`, and no wave lands "alongside".

---

## 6. Placement and cost, as mechanisms

Per the v8 reset, a process rule is proposable only for a failure that occurred and
cannot live in a gate or checklist line. Everything below is a gate, a field, or a line
that already exists.

**Author time.**
- `AGENTS.md` § Writing tests loses "add cases to the gate matching the stage changed"
  and gains the `write-tests` table's one-line default: native unless the subject needs a
  trust anchor, and a gate-test (native arm) when the subject is the binary. The
  `write-tests` row "everything under `medaka test` runs under the interpreter" is
  amended when the arm lands.
- `sprint-packet` §6 and `sprint-plan` "acceptance shape" name vehicles, not gates: the
  worked examples become `<module>_test.mdk` / a `kind = "native"` row.
- **Nearest-gate step, derived:** `medaka gate explain <path>` already lists the gates a
  path selects. The packet self-check's Q5 asks for it by name *before* the vehicle is
  chosen, and `style-review` §3 asks the same one question at review.
- **The `shell-because:` ratchet** (§4.2): a new `.sh` under a gate root without the
  header line and a matching `migration` value reds `gate verify`, which is already
  required. Its counts are reported, never targeted: a shell-adding count turned into a
  KPI is Goodhart's law in a tree that needs shell for every trust anchor.

**Cost.**
- `gate-budget` becomes a required context (D §4: built, three clauses, override
  trailer; non-required only as sequencing). Ruleset edit is add → swap → delete with
  read-back ([W-GH-WRITE-VERIFY]). **Consequence to state in the failure message:** clause
  (a) reds any schedulable gate with no baseline row (`balUncosted`,
  `gate_cmd.mdk:3295-3302`), and a brand-new gate has none until the nightly ingest, so
  every gate-adding PR carries a `Gate-Budget-Override: uncosted:<name>` trailer until
  then. That is the intended moment of acknowledgment, and it stacks with
  [W-SHARD-DERIVED]'s existing `ci-gen-drift` red; the message says both.
- `diff_compiler_stage_ir_scaling` runs a two-shape merge-tier proxy
  (`STAGE_IR_ONLY="match modules"`) and the full eight-shape sweep at
  `nightly/STAGE_IR_FULL=1`; `perf_scaling`'s deterministic alloc/op arms stay merge, its
  wall-clock arm goes nightly. All arms are non-soundness-class under the §3.6 charter
  (H), but two are ledgered regression pins whose move off pre-merge is an explicit
  decision for whoever approves: `guardwild`'s #2125 ceiling and `scoperefs`' #2172
  attribution (H item 3, the G14 call). **Savings, stated honestly:** the ~168 s proxy
  estimate is a linear extrapolation from the script's per-run costs and has never been
  run; 648 − 168 ≈ 480 s is gate CPU, not queue wall. Queue wall saved before any
  rebalance is `gates_5` 891 s − `gates_6` 663 s ≈ 4 min; after a rebalance the floor is
  bounded by total/rows ≈ 5,387/8 ≈ 673 s plus setup. The win is that `gates_5` stops
  being a single-gate pole.
- pds: after the native arm, re-measure `pds_test_inlang_test_oracle` on CI (one of its
  15 files takes five minutes on the dev box); then apply N1 to whatever heavy vectors
  remain, following the `signing_parity` precedent. Not before — demoting a
  soundness-bearing crypto suite to dodge an interpreter cost the keystone removes is
  the wrong order.
- Nightly perf is under-triaged (#2036 H4: 5 of 8 recent runs red). The proxy keeps a
  merge-tier arm precisely so nightly is not the only backstop.

---

## 7. Standing decisions this proposes to revisit

Val, 2026-09-03: anything is on the table if it improves things. These are the ones the
evidence argues against, with what replaces them and what prior reasoning is answered.

| Decision | Where | Evidence | Proposal |
|---|---|---|---|
| Native/wasm engines for `test`/`prop` deferred past 0.1.0 | #2299 | 191 gates blocked; pds five min/file and 26 hand-rolled native drivers (#2299's own "promote by demand" clause); §4.2's compensator false | pull the native `test` arm forward as wave 0; its "agreement is the engines gate's job" reason is right for wasm, which stays deferred |
| Migration rides #2182 opportunistically, no mass-migration sprint | #2298 | zero `kind = "native"` gates in five weeks; 174 new scripts; its own review's tiebreak unanswered (answered in §3) | explicit waves, each PR deleting a script |
| `gate-budget` not required | CI-ARCHITECTURE §3.5 | left non-required as "a separate, non-atomic ruleset edit, out of scope for this slice" — sequencing, not a decision against; green on main today | required, with the uncosted-trailer consequence stated |
| `stage_ir_scaling` merge-tier at full band | registry | 648 s alone on the pole; every arm deterministic; #2036's nightly-triage worry answered by keeping two shapes at merge | proxy + nightly full, with the two ledgered pins' move made explicit |
| TESTING-DESIGN §4.2's "same assertions run on all three engines" | `docs/ops/TESTING-DESIGN.md:482-485` | false for `test`/`prop` today | amended now; true for two engines after wave 0, with `make test` as the consumer |

**Kept, and relied on:** no catch/recover primitive (2026-06-10) — containment is a
process boundary; the merge queue never narrows the compiler suite (#2182); `shard` is
derived; `[G-MUST-FAIL]` inverted polarity gets a field, not a rubber stamp.

---

## 8. What deliberately does not change

- Trust anchors stay shell, with the reason in the file and in the registry.
- `[WT-GOLDEN-ENSHRINES]`: blessing is a named, scoped act; the native side reads goldens
  and shell writes them until a `--promote` policy is decided.
- Doctests stay illustration; coverage migrates to `test`/`prop` as TESTING-DESIGN §4.8
  already says.
- The differential and fixpoint tiers are the anti-circularity floor; a migrated gate is
  never the sole thing between a miscompile and green. This floor, not the probe/driver
  split, is what makes in-language verdicts acceptable.

---

## 9. Risks

- **A migrated suite gets quieter as it grows** unless containment (§4.1) lands with the
  arm, not after. Wave 0's exit criterion names it.
- **Build cost per gate-test file.** One clang build is ~2 s on the dev box, more on a
  CI runner, and 109 of the 191 targets run under 5 s today. Wave 0 times one build on CI;
  wave 1's cutting rule batches gate-tests per corpus. The budget ratchet will see the
  cost either way, because the build runs inside the measured gate; the rule is there so
  it sees a small number.
- **`Eq`/`String ==` in the probe.** Bounded by §3's print-operands contract and by the
  fixpoint/snapshot tiers depending on the same primitives; not eliminated, and §3 says
  where the residual sits.
- **Typecheck widening surfaces real errors in pds/sqlite** (B §6). Budget for it in
  wave 0; it is the point.
- **The `migration` field is a claim** (§4.2). Seeded alone, in its own PR.
- **The parity-plus-red rule is per PR, by review.** No gate checks that a migration PR
  demonstrated its red; the PR body carries the transcript, and `style-review` §3 asks
  for it.

---

## 10. Test-framework features worth adopting

From a feature × language survey (Rust, Go, Haskell, Elm, Zig, pytest, Jest/Vitest,
OCaml, Gleam, Roc, Lean 4; report G). Three findings reframe it before the list:

- **The rich-diff blocker is one constructor** — §4.3 item 1, now also the keystone's
  precondition (§3).
- **14 test-bearing files are run by nothing** (`stdlib/{math,time,validation,path,
  nonempty,base64,bits64,hex,fs,io,test}.mdk`, `compiler/support/{util,manifest}.mdk`,
  `compiler/tools/gate_cost.mdk`): neither `make test` nor `diff_compiler_test.sh`
  names them. The directory walk that fixes it exists and is unused. This is wave 0b's
  derived discovery, restated as coverage debt.
- **#431 is partly stale**: `approxEq` exists at `stdlib/math.mdk:98`; only the
  `Expectation` wrapper is missing.

**Adopt, in dependency order** (no language change in any row):

| # | Feature | Change | Depends on |
|---|---|---|---|
| 1 | Structured failure payload: `Expectation` carries expected and actual, not one string | `stdlib/test.mdk` + runner | — (§4.3 item 1) |
| 2 | Derived discovery: `medaka test <dir>` for every project's test root | runner + Makefile | — (wave 0b) |
| 3 | Rich structural diff in the runner — Elm's `equalLists`/`equalDicts` model (index and key pointers), not pytest's assertion rewriting (needs macros) | runner | 1 |
| 4 | `expectOk` / `expectErr` / `expectSome` / `expectNone` | stdlib | 1 for diffs |
| 5 | `expectWithin` over the existing `approxEq` | stdlib (~15 lines) | — |
| 6 | Structural shrinking for ADTs / records / tuples (#1316) — the greedy loop exists, only the candidate generator is missing | runner | — |
| 7 | Grouping by `/`-path in the test name, and a path-aware `--filter` (Go's "the name path is the filter grammar") | runner + convention | — |
| 8 | `Skip` / `only` markers with Elm's rule: a focused or skipped test fails the suite in CI, so neither can be committed green | stdlib + runner | 7 |

Items 1, 4, 5 are §4.3's first slice; 2 is wave 0b; 3, 6, 7, 8 are child 12 of §11.

**Deliberately not adopted:**

| Feature | Why not |
|---|---|
| Mocking / test doubles / fake clock | Purity and the effect system are the substitute; the five-entry allowlist is deliberate. The largest API surface in Jest/Vitest and the top pain point in State of JS 2025. Keep the sqlite `dbfix` pure-fixture idiom. |
| pytest-style fixtures / setup / teardown | A top-level pure binding already does every job a fixture graph does. Gleam ships none either. |
| Expected-panic assertions | Uncatchable panics are settled; `expectErr` and the must-fail tier are the spellings. |
| Line/branch coverage | Answers a less honest question than "did this run at all", which derived discovery answers. |
| A `bench` runner under the interpreter | Would measure the interpreter. Delete the dead syntax (#2291); keep `test/bench.sh`. |
| Output matchers / ellipsis in doctests | Doctest compare is exact today (`doctest.mdk:412-415`), which is the ppx_expect/dune "no matchers" rule satisfied by accident; record it as deliberate, because a wildcard makes promotion impossible. |

**One recorded disagreement.** Report G lists "`test`/`prop` on native + wasm engines"
under do-not-adopt, on the ground that cross-engine agreement is the engines gate's job.
That is the right reason for wasm and the wrong reason for native: §4's case for the
native arm is IO, subprocess, and speed, which G's row for this feature did not weigh (G
weighed interpreter-only-ness carefully on other rows, so this is a framing difference,
not a lapse). Containment is not part of the case: it is the runner's and lands under
either engine. The keystone stands; wasm for `test`/`prop` stays deferred as G and #2299
say.

**Snapshot and promote** (TESTING-DESIGN §4.7): adopt insta/ppx_expect's split — a
failing run writes a `foo.mdk.corrected` proposal and never mutates the source or the
golden; `git diff` is the review; CI refuses to promote (Jest's rule: a newly written
snapshot always passes, so it proves nothing — [WT-GOLDEN-ENSHRINES] with external
corroboration). No whole-suite promote verb. Where nondeterminism must be censored,
post-process the captured text in ordinary code before asserting, never with a matcher.

---

## 11. Epic and sequencing

Epic: **#2600 (testing architecture)**. Children (#2588–#2599), in order:

1. Wave 0-i — #2591's first PR: the `migration` field seeded from the inventory and the
   `shell-because:` pairing in `gate verify`. Alone.
2. Wave 0c, item 1 — #2590: structured `Expectation` (both operands). Precedes 0a.
3. Wave 0a — #2588: native arm for `test` blocks; sentinel format over the structured
   payload; eval-arm pre-check diagnostic for allowlist violations.
4. Wave 0b — #2589: per-file containment, derived discovery, typecheck scoping widened,
   `--filter` no-match red, `make test` running unit siblings under both engines.
5. Wave 0c, rest — #2590: assertions and the gate library.
6. Wave 0d — #2591's second PR: `kind = "native"` dispatch, the first five scripts
   migrated under the parity-plus-red rule, one gate-test build timed on CI.
7. Wave 1 — #2592: the 83 pure wraps, batched per corpus.
8. Wave 2 — #2593: golden helpers + the 43 golden gates + clone families as data.
9. Wave 3 — #2594: probe retirement (62).
10. Walls — #2595: section splits, inverted-polarity field, the 4 UNSURE, `bootstrap_*`.
11. Cost — #2596: `gate-budget` required with the trailer consequence stated;
    `stage_ir_scaling` proxy with the two-pin G14 call; pds re-measure then N1; measure
    the 34 unmeasured.
12. Words — #2597: AGENTS.md, `write-tests`, `sprint-packet`/`sprint-plan`,
    `style-review`, TESTING-DESIGN §4.2, workstream doc.
13. Registry hygiene — #2598: 45 empty `sources`, 6 undeclared corpus reads, dead
    OCaml-era headers, a gate that cannot fail.
14. Framework features — #2599: §10's shortlist, promoted by demand.

1–6 are one sprint (1 lands first as its own PR); 7–9 are repeatable sprint shapes cut
from the inventory by cost, roughly 25–45 sprints in total; 11–13 can run in parallel
with 1–6; 10 and 14 are follow-ups.

---

## 12. Review-round register (2026-09-03)

Before adoption, Val asked for an independent review of the conclusions (not the
research) by a fresh-context agent on the most capable model. Verdict: **adopt with
amendments**. All fifteen were applied above; the ones that changed a claim rather than
a wording:

- §3's "one process boundary out" claim was false as written (`Expectation` carried a
  verdict, not operands); §4.3 item 1 now precedes §4.1 and §3 names where the residual
  circularity sits.
- The parity rule became parity-plus-red (§5.2).
- "~480 s queue wall saved" was gate CPU from an unrun extrapolation; §6 now quotes the
  ~4 min pre-rebalance wall figure and the post-rebalance bound.
- "311–324 s ≈ 77% of 419 s" divided a dev-box time by a CI median; §1 quotes them
  separately.
- "Migrating changes CI wall time by roughly nothing" was false for the cheap majority;
  §2 and §5.2 carry the per-file build cost and the batching rule.
- The 60-day ratio is quoted with its composition (135 gates of 174 scripts), and "1 of
  163 stated why" is demoted from measured cause to absent convention.
- The ratchet lands first and alone; `native-wrap` is the stated release valve.
- Two cheaper doors are presented in §4 and argued against, not omitted.
- The allowlist diagnostic lives in `medaka test`'s pre-check, not `medaka check`.
- Containment came off the native arm's credit list (§0, §4, §10).

Taken on trust by the reviewer and still unverified by a run: report D's wall-clock
anatomy, H's ~168 s extrapolation and arm classification, B/F's dev-box timings, C's
duplicate accounting, A's per-row shape classification (inherited verbatim by the
inventory), G's citations. The review's probe transcripts are in the session scratchpad,
not the tree.
