# TESTING-ARCHITECTURE.md — the target testing architecture, and the migration to it

**Status:** PROPOSED 2026-09-03, from a two-round survey at `5397afc9c` (Val's brief:
the project is well tested but defaults to shell for checks, never dogfoods its own test
vehicle, and nobody evaluates where a test fits or what it costs). Tracked by the
testing-architecture epic #2600 (see §11). This document is the design authority for that
epic; `docs/ops/TESTING-DESIGN.md` (2026-07-13) keeps its §0–§3 as the diagnosis history
and its §4–§7 are superseded here. The per-gate survey table lives in
`docs/ops/TESTING-INVENTORY.md`.

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
a new gate's cost visible exists but is not required. Duplication is real but costs seven
seconds; what it costs is maintenance. The fix is one keystone capability — run `test`
blocks on the native engine, with the compiled probe printing and the driver judging,
exactly as `compiler/tools/native_doctest.mdk` already does for doctests — which at once
supplies the registry's declared-but-unbuilt `kind = "native"` runner, file IO and
subprocess in tests, per-file panic containment with no language change, and interpreter
speed relief. With that in place 191 of 212 migration candidates become expressible, in
three waves, each PR deleting the script it replaces.

---

## 1. What the survey measured

Seven reports, scratch-only; the load-bearing numbers, each with its source report.

| Measure | Value | Report |
|---|---|---|
| Tracked gate scripts / lines | 288 / 72,643 (256 registered, 32 ledgered tools) | A |
| Scripts sourcing any shared helper | 16 (5.6%); 191 re-implement `mktemp`, 175 `trap` | A |
| `strip_unit` definitions | 41 inline copies in **7 semantically distinct variants** under one name | A |
| Shape | GOLDEN 93 · DIFFERENTIAL 74 · RATCHET 29 · PERF 14 · CLI 14 · TRUST-ANCHOR 14 · other 50 | A |
| Subject engine | native 125 · multiple 60 · interpreter 33 · wasm 8 · none 62 | A |
| Registry `kind = "native"` entries | **0 of 256**; `gate run` has no dispatch for it (`gate_cmd.mdk:1161`) | A, I |
| New-test vehicle, last 60 days | 163 commits added a shell script vs 72 adding `test`/`prop` decls (2.3:1); 174 scripts vs 26 `*_test.mdk` files (6.7:1) | E |
| Shell-adding commits stating why shell | **1 of 163** | E |
| Measured gates / modeled cost | 222 / 5,387 s (~90 CPU-min); top-10 = 58%; 130 gates < 5 s = 3.9% | C, D |
| Merge-queue wall (run 33698130338) | 1,082 s; critical path = `build` 170 s → `gates_5` 891 s | D |
| `gates_5` contents | one gate, `diff_compiler_stage_ir_scaling` (median 648 s, range 459–782), ~4 min after the next row | D, H |
| pds share of modeled cost | 1,589 s (29.5%); all subprojects 34.8% | C, D |
| CPU saved by removing every genuine duplicate | ~7 s (0.13%); ~28 near-clone scripts, 108 redundant goldens | C |
| Gate-budget enforcement | built (3 clauses + override trailer), **not a required check** | D |
| Native vehicle real deficiencies | no IO/subprocess under eval (`testCapableExterns` = 5 names); a panic kills the run and every later file on a dir target; no derived `*_test.mdk` discovery | B |
| Native vehicle folklore that is false | takes one file (dirs and multi-target work); sibling can't see subject (it loads the graph); doesn't typecheck (it does, except under paths without a `compiler`/`stdlib` segment — all 24 pds/sqlite `_test.mdk` files) | B |
| `medaka test` on `pds/test/scalar_test.mdk` | 311–324 s for 38 decls (~77% of the 419 s `pds_test_inlang_test_oracle` gate) | B, F |
| pds native `_main.mdk` drivers kept because eval is too slow | 26 files; one measured 4 min → 4 s eval→native | F |
| Gates expressible natively today | **1** of 288 | I |
| Gates expressible once a native-kind runner exists | **191** of the 212 candidates | I |
| Gates that stay shell, with a reason | 43 (25 trust anchors, 11 instrumentation, 7 external harness) | I |
| `sources = []` in the registry | 45 gates, including every wasm gate | C |

---

## 2. Diagnosis: two problems, two levers

**Shell sprawl and CI time are not the same problem.** Removing every duplicate saves
seven seconds; migrating every migratable script to Medaka changes CI wall time by
roughly nothing (the same programs run). Conversely, the three gates that dominate the
critical path are the ones that will stay shell (Callgrind instrumentation). So:

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
| **Unit** | `test "…" = Expectation` | eval | pure library/compiler-internal computation | driver | `<module>_test.mdk` sibling |
| **Gate-test** (new rung) | `test "…" = Expectation` with IO | **native** (`medaka test --native`) | the compiler binary: a verb over fixtures, a golden, a CLI contract, a cross-engine diff | **driver** — the compiled probe only prints | `test/<area>/<name>_test.mdk`, registered `kind = "native"` |
| **Trust anchor** | shell | — | the machinery the rungs above run inside | external `diff`/`cmp` | `test/*.sh` with a `shell-because:` header line |

The gate-test rung is what the registry's `kind = "native"` was declared for and what
§1's "191 of 212" migrate to. Its contract is `native_doctest.mdk`'s, restated for
`test` decls:

- **The probe prints; the driver judges.** The synthesized `main` evaluates each `test`
  decl to an `Expectation` and prints it between sentinels; the driver (the `medaka`
  binary running `test --native`) parses and grades. A miscompiled `String ==` in the
  probe cannot mark its own homework, because the comparison it renders is a value the
  driver re-reads. This is TESTING-DESIGN §4.2's actual requirement (external verdict),
  and it is satisfied one process boundary out rather than by `diff`.
- **A panic is a dead probe, not an exception.** The probe is a child process; if it
  dies at test 9 of 64, tests 10–64 report `Errored` naming the abort, never dropped.
  This is the 2026-06-10 decision (no catch/recover primitive; tooling survives panics
  by process isolation) applied to the unit tier. Nothing is added to the language.
- **Under eval the same file stays pure.** The eval arm keeps `testCapableExterns` as it
  is. A `test` body that needs IO is a gate-test by definition and is run native; a file
  that runs under both engines is a two-engine differential of the unit tier, which is
  the compensator §4.2 claims for that tier and the binary does not provide today.
- **Where a golden is the sole oracle, the check stays shell.** `test/selfproc_goldens/legA`
  ([T-LEGA-GOLDEN]) and the bootstrap/fixpoint/seed family are the trust anchors; a
  self-hosted runner over them fails indistinguishably from its subject.

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
the deferral is what keeps 191 gates in shell and the pds suite at 311 s per file. It is
pulled forward (§7).

### 4.1 Design

- **Engine, not language.** `tools/native_doctest.mdk` already compiles a module plus
  synthesized bindings into one probe binary that prints one value per example with
  sentinels, and already has the abort rule. The `test` arm reuses the synth generator's
  seam: one synthesized `main` per file, one build per file, each `test` decl printed as
  its rendered `Expectation`. `runTestDecls` (`test_cmd.mdk:1026-1053`) gains an `Engine`
  parameter exactly as the doctest phase has; `--native`/`--engines` stop being inert for
  the `test` phase (B §2).
- **Effect row.** `test "…" = Expectation` is unified against `Expectation` only
  (`typecheck.mdk:29386`). The native arm evaluates the body inside the synthesized
  `main`, so effect-bearing bodies typecheck the way `main` does. The eval arm continues
  to reject at run time anything outside the allowlist; making that visible at
  **check** time (a `test`-body extern outside the allowlist is a diagnostic under the
  default engine, not an `E-PANIC`) is part of the same slice — the check/run mismatch
  B §5 measured is a vehicle bug regardless of engine.
- **Props** get the same arm later; the generator runs in the driver and only the
  evaluation moves, so it is a smaller follow-on, not part of the keystone.
- **Discovery and containment.** On a directory or multi-file target the driver runs
  each file's probe (native) or each file's interpreter run (eval) in a child and
  aggregates; a dead file names itself and the walk continues. `*_test.mdk` discovery is
  derived from the tree (`collectMdkFiles`), with the roster-completeness check
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
That is the mechanism behind "shell stays only with a stated reason" (#2298): a new
script cannot be enrolled without saying why it is a script.

### 4.3 The gate library (`stdlib/test.mdk` growth, plus a compiler-side helper module)

In dependency order, each small:

1. `expectOk` / `expectErr` / `expectSome` / `expectNone` / `expectNear` (#431).
2. `expectEqualText : String -> String -> Expectation` rendering a **line diff**, not
   two `debug` blobs; a normalization helper (strip trailing `()`/`0`, the one honest
   replacement for the seven `strip_unit`s).
3. Golden helpers: `expectGolden path actual`, with blessing kept **in shell** for the
   first waves (`CAPTURE=1`), so the native side needs read capability only. A
   `medaka test --promote` (TESTING-DESIGN §4.7) is a later slice with its own write
   policy.
4. `runVerb : List String -> <IO> Result … (exit, stdout, stderr)` over `runCommand`,
   with the [D-BUILD-PIPE] and [B-STDERR] disciplines baked in once.
5. Fixture-directory enumeration with the anti-vacuity floor (a corpus of zero files is
   a failure, the pds wrapper's rule).

---

## 5. Migration order

Derived from the inventory's unblock ranking (I §2): the runner alone unblocks 191; a
golden library is next (101 carry `GOLDEN-ASSERT`); probe retirement is the largest
rewrite (68 carry `ORACLE-PROBE`); 13 scripts must be split before any verdict applies;
8 inverted-polarity pins need a registry field the schema lacks.

### 5.1 Blocker vocabulary (the inventory's codes)

`TRUST-ANCHOR` never migrates · `NATIVE-KIND-RUNNER` the keystone · `GOLDEN-ASSERT`
needs §4.3 items 2–3 · `ORACLE-PROBE` drives `test/bin/*`; wrappable now, a rewrite
retires the probe · `EXTERNAL-TOOL` free under native (a module may spawn) ·
`SECTION-SPLIT` editorial split first · `INVERTED-POLARITY` a per-pin drain field ·
`TEST-IO`/`TEST-SUBPROCESS`/`PANIC-CONTAINMENT`/`NATIVE-ENGINE-TESTS` the eval-arm
walls, all dissolved by the native arm · `NOT-A-CHECK` out of the denominator.

### 5.2 Waves

| Wave | Contents | Count | Exit criterion |
|---|---|---:|---|
| **0 — keystone** | §4.1 native arm + containment + discovery + typecheck scoping; §4.2 registry seam and `migration` field; §4.3 items 1–2, 4–5; `--filter` no-match is red (#2340) | — | `medaka test --native` runs a `test` file that reads a fixture and spawns `./medaka`; a dir run survives a dead file; one `kind = "native"` gate green in CI |
| **1 — pure wraps** | the 83 gates carrying only the runner blocker: the three project `check` wrappers first (18–25 lines each), then `effect_*_domain`, then by cost (`call_arity` 185 s, `import_order` 105 s, …) | 83 | each PR deletes its script; old and new green on the same tree once, then only the new is enrolled |
| **2 — golden families as data** | the 43 `GOLDEN-ASSERT` gates plus the clone families: snapshot ×9 → one runner + 9 rows, `core_ir_X`/`eval_X` ×4 → one runner + 8 rows, lsp ×3, `_batch` ×5 folded into siblings, `cross_project` pair | 43 + ~20 | §4.3 item 3 lands first; 108 redundant goldens gone; `strip_unit` count is 0 |
| **3 — probe retirement** | the 62 `ORACLE-PROBE` rewrites: stage functions called as a library; each retires a `compiler/entries/*` probe and a `build_oracles.sh` row | 62 | `test/bin/` shrinks with each PR; `[L-PHANTOM-SKIP]` class shrinks with it |
| **walls** | split the 13 mixed scripts (`dict_semantics` 1,643 lines, `check_cli_modules` 2,926); add the inverted-polarity field and route the 8 pins through the must-fail drain protocol; decide the 4 UNSURE (`diff_compiler_test`, `vector_provenance`, `ported`, `tmc_census`) | 25 | each becomes a wave-1/2/3 row or a `shell:*` reason |

Owner's calls the waves surface rather than decide: retire the `bootstrap_*` ladder
(4 gates, 108 OCaml-era goldens, `compiler/BOOTSTRAP.md` milestones) or keep it as
executable history; whether `diff_compiler_test.sh`'s OCaml-era goldens still prove
anything.

**Parity rule for every migration PR.** The new gate and the old script run on the same
tree and both pass once; the script is deleted in that PR; the registry row flips `kind`
and `migration = "done"`. No wave lands "alongside".

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
  header line and a matching `migration = "shell:*"` value reds `gate verify`, which is
  already required.

**Cost.**
- `gate-budget` becomes a required context (D §4: built, three clauses, override
  trailer, not required). Ruleset edit is add → swap → delete with read-back
  ([W-GH-WRITE-VERIFY]). The failure message already teaches the remedy menu, so the
  tier question is asked at the moment it can be answered.
- `diff_compiler_stage_ir_scaling` runs a two-shape merge-tier proxy
  (`STAGE_IR_ONLY="match modules"`, ~168 s estimated) and the full eight-shape sweep at
  `nightly/STAGE_IR_FULL=1`; `perf_scaling`'s deterministic alloc/op arms stay merge, its
  wall-clock arm goes nightly. All arms are non-soundness-class under the §3.6 charter
  (H). Estimated queue wall saved: ~480 s, and `gates_5` stops being the pole.
- pds: after the native arm, re-measure `pds_test_inlang_test_oracle` (its 419 s is
  ~77% one interpreter-bound file); then apply N1 to whatever heavy vectors remain,
  following the `signing_parity` precedent. Not before — demoting a soundness-bearing
  crypto suite to dodge an interpreter cost the keystone removes is the wrong order.
- Nightly perf is under-triaged (#2036 H4: 5 of 8 recent runs red). The proxy keeps a
  merge-tier arm precisely so nightly is not the only backstop.

---

## 7. Standing decisions this proposes to revisit

Val, 2026-09-03: anything is on the table if it improves things. These are the ones the
evidence argues against, with what replaces them.

| Decision | Where | Evidence | Proposal |
|---|---|---|---|
| Native/wasm engines for `test`/`prop` deferred past 0.1.0 | #2299 | 191 gates blocked; pds 311 s/file; §4.2's compensator false | pull the native `test` arm forward as wave 0; wasm stays deferred |
| Migration rides #2182 opportunistically, no mass-migration sprint | #2298 | zero `kind = "native"` gates in five weeks; 174 new scripts | explicit waves, each PR deleting a script |
| `gate-budget` not required | CI-ARCHITECTURE §3.5 | the only brake on growth is off | required |
| `stage_ir_scaling` merge-tier at full band | registry | 648 s alone on the pole | proxy + nightly full |
| TESTING-DESIGN §4.2's "same assertions run on all three engines" | `docs/ops/TESTING-DESIGN.md:482-485` | false for `test`/`prop` today | amend now; true for two engines after wave 0 |

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
  never the sole thing between a miscompile and green.

---

## 9. Risks

- **A migrated suite gets quieter as it grows** unless containment (§4.1) lands with the
  arm, not after. Wave 0's exit criterion names it.
- **Build cost per gate-test file.** One `clang` build per `_test.mdk` (seconds). The
  pds precedent shows it is cheaper than the interpreter at any nontrivial size, and
  wave 1 is measured before wave 2 starts. Batch several small gate-tests per file where
  the subjects share a fixture corpus.
- **`String ==` in the probe.** Mitigated by the print-don't-judge contract and by the
  fixpoint/snapshot tiers depending on the same primitive; stated in §3.
- **Typecheck widening surfaces real errors in pds/sqlite** (B §6). Budget for it in
  wave 0; it is the point.
- **The `migration` field is a claim.** `verify` checks its shape and its pairing with
  the header line, not its truth; the truth is the inventory's method, re-run when the
  count drifts.

---

## 10. Test-framework features worth adopting

From a feature × language survey (Rust, Go, Haskell, Elm, Zig, pytest, Jest/Vitest,
OCaml, Gleam, Roc, Lean 4; report G). Three findings reframe it before the list:

- **The rich-diff blocker is one constructor.** `ExResult` already carries
  `Fail String String` (expected, actual — `doctest.mdk:51-55`), but `runOneTest` fills
  it as `Fail msg ""` (`test_runner.mdk:52`) because `Expectation`'s `Fail` is one
  opaque `String`; `--json` shows it as an empty `actual`. Every diff feature is
  downstream of widening that constructor.
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
| 1 | Structured failure payload: `Fail` carries expected and actual, not one string | `stdlib/test.mdk` + runner | — |
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
native arm is not agreement but IO, subprocess, containment, and speed — the four
things that keep 191 gates in shell — and G's own matrix does not weigh those. The
keystone stands; wasm for `test`/`prop` stays deferred as G and #2299 say.

**Snapshot and promote** (TESTING-DESIGN §4.7): adopt insta/ppx_expect's split — a
failing run writes a `foo.mdk.corrected` proposal and never mutates the source or the
golden; `git diff` is the review; CI refuses to promote (Jest's rule: a newly written
snapshot always passes, so it proves nothing — [WT-GOLDEN-ENSHRINES] with external
corroboration). No whole-suite promote verb. Where nondeterminism must be censored,
post-process the captured text in ordinary code before asserting, never with a matcher.

---

## 11. Epic and sequencing

Epic: **#2600 (testing architecture)**. Children (#2588–#2599), in order:

1. Wave 0a — native arm for `test` blocks (§4.1), `--filter` red on no match.
2. Wave 0b — runner hygiene: per-file containment, derived discovery, typecheck scoping
   widened, check-time allowlist diagnostic.
3. Wave 0c — `stdlib/test.mdk` growth + gate library (§4.3 items 1–2, 4–5).
4. Wave 0d — registry seam: `kind = "native"` dispatch, `migration` field,
   `shell-because:` ratchet, the first project `check` wrappers migrated.
5. Wave 1 — the 83 pure wraps.
6. Wave 2 — golden library (§4.3 item 3) + the 43 golden gates + clone families as data.
7. Wave 3 — probe retirement (62).
8. Walls — section splits, inverted-polarity field, the 4 UNSURE, `bootstrap_*` call.
9. Cost — `gate-budget` required; `stage_ir_scaling` proxy; pds re-measure then N1.
10. Words — AGENTS.md, `write-tests`, `sprint-packet`/`sprint-plan`, `style-review`,
    TESTING-DESIGN §4.2 amendment.
11. Registry hygiene — 45 empty `sources`, 6 undeclared corpus reads, dead headers
    (`lsp_b3`/`lsp_b4`/`resolve` cite the removed OCaml oracle), `check_build_oracles_for_consistency` cannot fail.
12. Framework features — §10's shortlist, promoted by demand.

1–4 are one sprint's slices; 5–7 are repeatable sprint shapes cut from the inventory by
cost; 9 and 10 can run in parallel with 1–4; 8, 11, 12 are follow-ups.
