# `ci.yml` — incident narrative and measurement history

`.github/workflows/ci.yml` itself now carries only short, imperative, number-free invariant
statements. This file holds the post-mortems, measurements, and dated-run-ID paragraphs that used
to live inline as comments — moved here verbatim in substance (not deleted) because each one was
paid for by an incident. When editing `ci.yml`, read the relevant section here for *why* before
changing *what*.

## Oracles-per-shard vs. binary-once (#1928)

Measured on a hosted runner: installing the toolchain took ~13s, `make medaka` (cold, from seed)
took ~80s (shared — see the `build:` job), and `FORCE=1 build_oracles.sh` took 18+ minutes — 93%
of the job, and climbing.

Sharing the ORACLES across shards would be wrong: `build_oracles.sh` compiles 54 probe binaries
(54 × `medaka build` + clang). On the 12-core dev box that is ~34s; on a small hosted runner it
dominates everything and blows the timeout. Caching it would only help when the compiler is
untouched — which is exactly never, for compiler work. The fix: no gate needs all 54. A gate
names its oracle as `test/bin/<name>`, so `build_oracles.sh --for '<gate-pattern>'` derives the
set straight from the gate scripts, and each shard builds only its own handful concurrently with
the others. `test/preflight.sh` uses the same derivation, so an agent touching the parser builds
9 oracles locally instead of 54.

Sharing the BINARY, by contrast, is right (#1928): `make medaka` is a pure function of the
checkout — one SHA, byte-identical output — and it was being recomputed in TEN jobs, ~27% of all
CI job-seconds. It now runs exactly once, in the `build:` job, and the ten consumers download it.
The 18-minute item that made "build once, fan out" untenable was the ORACLE line, never the
binary line.

## Why the drift check lives inside each shard

It cannot be a separate job: a fresh checkout in a fresh VM would never see drift caused by gates
that ran somewhere else. It has to run in the same working tree, right after the gates.

## Self-hosted runner removed before going public

This repo previously used a self-hosted runner on the dev box. It was removed before going public
— a fork PR on a public repo with a self-hosted runner is arbitrary code execution on the runner
host. Do not reintroduce one.

## Why the Medaka binary is not cached (#111)

`./medaka` and `./medaka_emitter` depend on the compiler, stdlib, runtime, and build scripts.
Those are exactly the files changed by every non-docs compiler PR, while docs-only PRs skip these
jobs. An exact, correctness-safe cache key therefore cannot hit on the runs that need the
binaries; the former cache only added restore/save work. A seed-only cache is not useful either:
measured on the dev box, compiling the immutable seed is 1.6s of a 30.1s cold bootstrap; the
remaining 28.3s depends on current source.

That is about CACHING — a cross-run, keyed restore — and it is still true. It is NOT about the
`build:` job (#1928), which is intra-run transport at a FIXED SHA: no key to mis-hit, no
cross-SHA restore, and the consumer asserts the emitter's provenance stamp against its own
checkout before using it.

Per-shard `test/bin/*` oracle caches remain. Their exact keys are useful on repeated runs and
must cover every artifact input; never add a partial `restore-keys` fallback, which would turn
stale oracles into plausible greens.

## PR run narrowed, merge_group run not (T-15, 2026-07-14)

Every PR used to pay for the whole suite TWICE — once on `pull_request`, once on the
`merge_group` branch when the queue tests it merged onto main. GitHub's queue creates one temp
branch per entry and cannot combine builds, so the merge_group run is a fixed cost. We are
runner-bound (jobs wait 40-105s for a runner; 20 concurrent, ~11 per run), so the duplicate is
what saturates us. The PR half is the half that can shrink:

- `pull_request` — each `gates (…)` shard runs only the intersection of its pattern with the gate
  set `detect` derives from the diff (via `PREFLIGHT_DRY=1 test/preflight.sh` — the same
  derivation agents run locally, not a second copy of it).
- `merge_group` — every shard runs its full pattern. Unchanged. Always.
- `push` to main — ditto.

Three times in one day, two independently-green branches auto-merged with zero git conflicts
into a broken tree (a derivation scanning a universe the other branch had widened; a gate
comparing basenames against files the other had re-keyed to paths; a classifier skipping the
suite on a file the other had moved). No per-PR check can see any of those — only the full suite
on the merged tree can. And `soundness` is the backstop for a different hole entirely: all the
gate shards pass on an ill-typed compiler (`make medaka` does not gate on type errors), which is
exactly how a compiler with unbound constructors once shipped to main with every gate green. It
is 171s (as measured 2026-07-14 — re-derive before trusting). It stays full, on every event,
forever.

A PR that passes its narrowed subset and then fails in the queue is simply bounced from the
queue. That is correct and expected — it is how bors always worked. Preflight is a filter, not
an authority; CI on the merged tree is the authority.

The narrowing fails safe in every direction: preflight erroring, preflight reporting whole-suite
blast radius (stdlib/, runtime/, compiler/support/, compiler/entries/, a fixture dir with no
discoverable consumer), or preflight having no opinion about a changed non-prose path — each one
widens the run back to everything.

## `push: main` removed — the queue already covers it (#1927)

Before the merge queue existed, `push: main` was how a merge got tested at all. Now every commit
reaching `main` was already tested by a `merge_group` run at that exact SHA (the queue only
merges what went green there) — so the `push: main` run was a byte-for-byte duplicate full suite,
paid twice per merge for zero new signal. `schedule` is the safety net for anything that could
still land outside the queue (it can't today — bypass_actors is empty and the ruleset covers
deletion/non-fast-forward too — but the net stays cheap insurance against a future ruleset edit).

The `schedule` trigger's `oracle_key` is `'full'` (same as the old push run's), same hashFiles
key, so it becomes the daily producer of the cache a `merge_group` run restores from the default
branch. A `merge_group` between refreshes just rebuilds on a cache miss — ~17s/shard per #1927's
own measurement, the same cost any cache miss already pays today. This is mitigation (b) for
#1927's oracle-cache offset.

## T-4b: the docs-only fast path

A change that touches ONLY prose (top-level `*.md`, `docs/**`, `LICENSE`) used to still run the
full 40+ minute gate suite. The `detect` job classifies the PR's changed files and every heavy
job (gates/soundness/seed-health/inlang) reads its output to skip their EXPENSIVE STEPS, not to
skip THEMSELVES — because branch protection requires the ruleset's named status checks (derive
them: `gh api repos/MedakaLang/medaka/rulesets/18885875 --jq '.rules[]|select(.type==
"required_status_checks")|.parameters.required_status_checks[].context'`) with zero approvals
(the checks ARE the merge gate), and a job skipped by a job-level `if:`, or a workflow
that never runs because of a `paths-ignore:` trigger filter, means GitHub never receives a status
for that context: it sits at "Expected — waiting for status" forever and the PR becomes
permanently unmergeable.

`test/` is never docs even though it holds 175 `.md` files: 167 are snapshot goldens
(`test/snapshots/**/*.md`), plus `test/CAPABILITY-MATRIX.md`, `test/ENGINE-DIVERGENCE.md` and
`test/error_quality_fixtures/{INVENTORY,GRADING}.md`. A naive `**.md` filter would classify a
blessed golden re-cut as docs-only and skip every gate that exists to catch exactly that
regression — a silent-green bug, which is the one thing this test suite is built to prevent. So
the `test/*` arm comes first in the classifier's case block and must stay there.

`docs/spec/SYNTAX.md` is likewise never docs — it is an executable spec. AGENTS.md designates it
the ground truth for what the binary accepts, and `test/check_syntax_examples.sh` runs every one
of its examples through `medaka check`. That gate needs a built compiler, so it lives in a gate
shard — and shards are skipped when `docs_only=true`. Classifying a SYNTAX.md edit as docs-only
would therefore skip the one gate that exists to check it, on the one change that needs it. This
is not hypothetical: SYNTAX.md shipped for months documenting FIVE REMOVED CONSTRUCTS as live
syntax (backtick infix, let-else, named impls, default impl, `@Name`) because nothing ever
executed it — the same silent-green shape as the `test/` case.

Everything else that ends in `.md` is prose and takes the fast path: the ~50 top-level docs,
`compiler/**`'s ~47 design docs, `.claude/**`'s playbooks, `sqlite/`, `archive/`,
`stdlib/README.md`, `docs/**`, `LICENSE`. Verified: nothing in the build, in any gate, or in any
workflow reads a `.md` outside `test/` at runtime. Scoped to the `.md` extension on purpose —
`.claude/` also holds `hooks/skill-triage.py` and `settings.json`, `compiler/` holds `.mdk`
source, and `runtime/` holds C; those fall through to the catch-all as not docs.

Conservative in the direction that matters: any unrecognized path routes to the full suite. A
false "docs-only" is a shipped bug; a false "not docs-only" costs some CI minutes, which are free
on a public repo. Only meaningful for `pull_request` (there IS a base/head diff to classify) —
every other trigger defaults `docs_only=false`.

## T-15: the gate-set derivation is `test/preflight.sh`, never reimplemented

`preflight` already maps a diff to a gate set (source file → gates; fixture corpus → the gates
that actually read it, derived by scanning every tracked `.sh`). A second, subtly-different copy
of "which gates does this diff touch" is exactly the drift-prone duplication this repo keeps
finding and killing. So CI runs preflight in `PREFLIGHT_DRY=1` mode, which prints the derivation
and builds nothing, and feeds it the changed-file list the classify step already resolved (a
shallow checkout of the PR's merge ref has no `main` to diff against, so preflight's own git
derivation cannot run here — `PREFLIGHT_CHANGED_FILE` parameterizes the INPUT only, never the
derivation).

Three ways this refuses to narrow, all failing safe (= run everything): (1) preflight exits
nonzero — a stale glob in its map, or a bug; (2) preflight prints `FULL <reason>` — the diff has
whole-suite blast radius; (3) preflight prints `UNMAPPED <p>` — its map has no opinion about path
`<p>`. An unmapped path is only tolerable if it is prose, decided by the same docs allowlist
(`nondocs.txt`) rather than a second list. A gate wrongly included costs CI minutes, which are
free on a public repo. A gate wrongly excluded is a bug that reaches the queue. Bias accordingly,
always.

## #1928: build ./medaka once, not ten times

`make medaka` is a pure function of the checkout: at one SHA it produces byte-identical binaries
no matter which job runs it. It used to run in TEN jobs (the 7 `gates` shards + `soundness` +
`inlang` + `wasm`) — ~27% of all CI job-seconds spent recomputing the same answer. Now it runs in
the `build:` job, once, and those ten take `binary: artifact` on the same setup action.

The `build:` job is NOT one of the required contexts (derive them: `gh api …`, see T-4b above),
and must not become one — that would
need a ruleset edit, which is not atomic with a commit. It is also `needs: detect` with a
conditional *step*, never a conditional job — same shape as every heavy job in this file, and for
the same reason: a required consumer that `needs:` a job which can itself be skipped can dead-end.
This job always runs and always reports; on a docs-only PR its steps no-op in seconds and it still
reports success, so `needs: [detect, build]` downstream is always satisfiable.

Wall clock is roughly neutral (one ~90s serial hop replaces ten parallel ones), a real win under
runner contention — we are runner-bound at 20 concurrent jobs, so ten fewer cold builds is ten
fewer jobs holding a runner. The banked win is job-SECONDS. See #1928's own honest-tradeoff
section for the full accounting.

This is NOT a cache — see "Why the Medaka binary is not cached (#111)" above. It is intra-run
artifact transport at a FIXED SHA, which that note explicitly is not about: no key to mis-hit, no
cross-SHA restore.

`seed-health` deliberately does NOT consume this artifact. It asks a different question ("can the
committed seed still bootstrap a working emitter?") and must keep answering it from the seed
itself.

## Shards are scheduled by cost, not by theme (2026-07-14)

The shard NAMES are thematic and that is fine — they make a failure legible. The SCHEDULE is not:
jobs run in parallel, so total CI wall-clock is the SLOWEST shard, and grouping by subsystem once
stacked the three most expensive gates in the repo onto one runner while five others idled for
four minutes.

⚠️ Every number below is a HISTORICAL SNAPSHOT and has since rotted — do not plan against any of
it. `ci.yml` no longer carries hand-written performance numbers at all; the current numbers come
from `scripts/ci_shard_cost.sh`, derived live from recent green `merge_group` runs. This section
exists only so the reasoning that shaped the shard layout is not lost.

Measured per-gate CPU seconds (2026-07-14, wasm-tools absent = what a hosted runner saw then; a
shard's wall ≈ setup + Σcpu / 2, since run_gates' outer pool is JOBS=2 on a 4-core hosted runner):

```
diff_compiler_engines  ..  834   <- then-346 fixtures x (medaka build + clang)
build_construct_coverage   282   <- 144 fixtures x (medaka build + clang)
sqlite/test/*oracle (22)   188   <- 22 gates, 3-15s each
backend (12 gates)         298
tools  (27 gates)          114
types  (20 gates)           36
eval   (27 gates)           27
frontend (15 gates)         12
```

The old `engines` shard held 834+282+188 = 1304 of the suite's ~1790 CPU-s. It measured 517s wall
while `frontend` measured 138s — i.e. ONE shard was the critical path and the other five were
noise. So: `diff_compiler_engines` got its own runner (it cannot go below Σcpu/ncores, and
`full_cores` gives it the whole box rather than the gate's own `ENGINE_JOBS=NCPU/2` default hedge
— at 2 workers it was ~420s, at 4, ~210s); the 22 sqlite oracles got their own shard (22
independent gates, embarrassingly parallel, which is what `CI-COVERAGE-EXCEPTIONS.txt` had been
claiming all along — "Now in the `sqlite` shard" — there wasn't one); `build_construct_coverage`
moved to `frontend`, the cheapest shard (12 CPU-s of gates behind a 14-oracle build) — a backend
gate sitting in a shard named frontend, deliberately, because it is placed where there is idle
runner, not where its name says. It was also SERIAL — 282s of wall on any machine — and got fanned
out (298s -> 111s at run_gates' JOBS=3), which is what made it fit anywhere at all.

Two of the numbers above were provably stale even before this section moved here: the `engines`
corpus was 346 fixtures and later became 435, and "wasm-tools absent" stopped being true of the
`engines` shard once it started installing it and running a third engine (#597). `engines` also
stopped being the sole critical path — `types` became the pole at various points below. GitHub
gives this repo 20 concurrent jobs and it uses ~11. More, smaller shards are nearly free; a long
pole is not.

### Per-gate cost placements, as measured at the time each was made (all rotted, keep for context)

**`engines` shard**: `wasm_arm` (#597) installs wasm-tools + Node and builds the Wasm oracle, so
`diff_compiler_engines` can actually run its T2 (native == wasm) and T3 (all three agree) tiers.
Without it the gate honestly degrades to a two-engine differential and the required check goes
green having never compared the backends. `MEDAKA_REQUIRE_WASM=1` (set with `wasm_arm`) makes
that degradation a hard fail here, so the wiring can never silently rot back.
`diff_compiler_rejection_parity` (#709) rides along here, not as new weight: its 26 fixtures were
removed from `diff_compiler_engines`' value differential (they made zero cross-engine comparison
— both backends reject them identically), so this shard's total build count dropped. The gate
re-asserts the property they actually carry (both backends reject), and it needs this shard's
toolchain: wasm-tools + Node 24 + the wasm oracle + `MEDAKA_REQUIRE_WASM=1`. It is ~3s (rejections
fail at the front end, before clang/wasm-tools), so it adds nothing measurable to the shard that
already owns the wasm arm. Measured on the 12-core dev box at `ENGINE_JOBS=4` (the closest
available proxy for a 4-core runner): degraded two-engine 60.9s → full three-engine 110.0s, i.e.
the wasm arm is +49s wall / x1.94 CPU, plus ~20s of oracle build and ~4s of toolchain setup. A
hosted runner will be slower in absolute terms; the ratio is the transferable part.

**`sqlite` shard**: THE 22 differential gates that diff the pure-Medaka SQLite library against the
real sqlite3 CLI (T8). They had never run in CI — not because anyone excluded them, but because
no pattern could reach them: `run_gates.sh` globbed `$ROOT/test/<pat>.sh` and these live in
`sqlite/test/`. `run_gates.sh`, `build_oracles.sh --for`, and the coverage gate now all resolve a
pattern against both `$ROOT/test/` and `$ROOT/`, so a shard can name a gate anywhere in the tree.
22 independent gates, 188 CPU-s total, longest single gate 15s — the most shardable work in the
repo, and it had landed in the already-longest shard. Its own runner costs nothing (11 of 20
concurrent jobs used) and took ~95s off the critical path. `CI-COVERAGE-EXCEPTIONS.txt` already
described this shard as existing; then it actually did. NOTE the glob is `'*oracle'`, not
`'*_oracle'`: 21 of them are `<name>_oracle.sh` but the 22nd is plain `oracle.sh` —
`'*_oracle'` silently left it out, and the coverage gate caught that immediately on its first run
after being widened.

`gzip/test/*oracle` joined for the same two reasons: same kind of gate (a project oracle that
drives `./medaka` directly and reads no `test/bin` oracle), and this shard had the most room.
Derived from merge_group run 30971754103: types 472s, engines 465s, backend 395s, tools 357s,
frontend 352s, eval 313s, sqlite 246s.

`pds/test/*` (S-pds-skeleton, #1705) joined by cost, not theme: two consecutive green merge_group
runs (31983057792, 31979717039) put `sqlite` at 162s/203s — cheapest or second-cheapest of the
seven shards in both runs (only `backend` at 177s beat it in the second run); `engines` was the
pole at 385-389s both times. The glob is `'pds/test/*'`, not `'pds/test/*oracle'`: deliberately
ONE directory level deep so any future `pds/` in-language gate auto-enrolls with no `ci.yml` edit,
as long as it lands directly in `pds/test/`. `constant_time_parity` is covered by the PDS glob and
requires the Wasm arm; enabling it here spends the toolchain/oracle setup on this shard while
keeping the gate enrolled exactly once.

**`frontend` shard**: `native_fixtures/run` (T8) — 11 native-only regression assertions
(parse-error location + foreign-syntax hints + one eval dispatch check). It sat one directory
below `test/`, so even the coverage gate's `test/*.sh` glob could not see it; it was RED. Its one
real failure (compiler bug T-12) is now an XFAIL in the gate's own expected-failure ledger.
`build_construct_coverage` (T-3, backend gate, 144 construct fixtures through the native `medaka
build`, stdout diffed against committed goldens) is parked here for cost — frontend's own 15 gates
were 12 CPU-s combined. `diff_compiler_wasm_shim_parity` (#370, a text diff of the two JS hosts,
WASM-SEMANTICS WH3) needs no compiler, oracle, or wasm toolchain and costs ~0 CPU-s wherever it
lands; it sits in a required shard because a free gate belongs in whichever required shard has
room (originally justified because `wasm:` was advisory — that premise is now false, `wasm` has
been required since 2026-07-15, but the placement stands on its own).
`diff_compiler_preflight_base` (#560) is pure git (builds its own synthetic repo with `git init`),
needs no compiler/oracle/checkout, and costs ~0 CPU-s; it pins the base-ref derivation in
preflight.sh, the agent loop and the input to CI's own narrowing — a stale base invents phantom
changed files, enrols gates the diff never touched, and can trip the #492 blast-radius carve-out
into the ~84-gate run — so it belongs in a required shard on purpose. `diff_compiler_dict_semantics` (#616, the DICT-SEMANTICS.md conformance gate)
would naturally sit in `types` alongside `diff_compiler_shadow_semantics`, but `types` was the
pole in both merge_group runs measured on 2026-07-29 (429s/376s) while `frontend` was cheapest
(182s/228s); it costs ~43s wall and reads no oracle.

**`types` shard**: `diff_compiler_shadow_semantics` (the SHADOW-SEMANTICS.md decision matrix)
lives here rather than in `tools` (with its closest sibling,
`diff_compiler_run_check_agreement`) because every stage it exercises is in
`compiler/types/typecheck.mdk`. It drives check+run+build per fixture but reads no `test/bin`
oracle, so it adds no oracle-build cost.

**`eval` shard**: the 4 `bootstrap_*` stage gates ran in NO CI job until 2026-07-13, found by the
coverage gate once it was taught to look past the `diff_compiler_*` family — all 4 green, ~2s.
Named individually, not globbed as `bootstrap_*`, because that glob also catches
`bootstrap_from_seed.sh`, the 80s cold bootstrap `seed-health` already owns.
`diff_compiler_dispatch_shape` (a backend gate, ~3s, two `medaka build --keep-ir` of tiny probes)
sits here deliberately because `backend` is one of the heaviest shards and this one has room.
`diff_compiler_prelude_obj` (39s, the soundness gate for the `MEDAKA_PRELUDE_OBJ` fast path,
proving the inline and prebuilt link paths produce identical program output across 24 fixtures at
both opt levels) is the exact analogue of `diff_compiler_rt_obj` (which lives in `backend`), moved
here for room. `diff_compiler_slice_oob` (#550, 9.3s) is here for the same cost reason — its
nearest sibling by shape, `diff_compiler_let_refute`, lives in `backend`, which had no room; it
needs `./medaka` + the emitter, already provided here. `diff_compiler_ir_size` (#885, ~20s, four
`medaka build --keep-ir` + clang) is the size bound for emitted IR, the clang-bound analogue of
`dispatch_shape`'s shape pin, guarding the same #129/#131 prelude-bloat class — parked next to its
two siblings for the same cost reason.

`diff_compiler_origin_agreement` (#1110) is a frontend/types gate here for cost, fourth time over
— measured on the 2026-08-02 full merge-queue run 30725382057 (engines 448s, types 422s, backend
382s, frontend 348s, tools 310s, eval 292s, sqlite 237s), both its thematic homes (`frontend`,
which owns `diff_compiler_resolve*`, and `types`) were poles and this was the cheapest shard that
already built a large oracle set (19). `diff_compiler_import_order` (#1319 unit 0, the import-
clause permutation differential) is here for cost, fifth time over — derived from three
merge_group runs on 2026-08-05 (31022994812 / 30983572270 / 30981872310: engines 324/334/473s,
types 299/300/454s, tools 185/178/332s, backend 166/152/387s, frontend 223/165/299s, sqlite
108/123/199s, eval 92/83/246s), both thematic homes were at or near the pole and this was
cheapest on every one of the three. It reads no oracle; needs only `./medaka` + the emitter,
already built here for `dispatch_shape`/`prelude_obj`/`slice_oob`/`ir_size`. It drives
check+run+build+exec once per ordering — every n! ordering of each case's import clauses —
measured 25s wall on the dev box at the corpus it landed with. Case count derives from
`ls -d test/import_order_fixtures/*/ | wc -l`.

`diff_compiler_test_native` (#81 Stage 4) is CI's gate for `medaka test --native` /
`--engines eval,native`, placed here by cost — measured 2026-08-05, merge_group run 31043828993,
`eval` 215s was cheapest after excluding `tools`/`engines`; `types` 472s was the pole. It reads no
oracle, only `./medaka` + clang, and lands beside `diff_compiler_origin_agreement`, which also
probes `test_cmd.mdk`'s elaboration path; measured ~6s. `diff_compiler_draft_semantic` (#1399
X-0D) and `diff_compiler_anf_identity` (#1400 X-A) are lightweight compiled-probe gates parked
here for the same reason — this shard already builds the adjacent Core/elaboration probes, so
their marginal build joins the existing parallel oracle batch rather than becoming a serial
oracle.

`diff_compiler_flat_vs_onemodule` (ARCH B-2.1-a, Stage B sprint) is a typecheck gate here for cost,
fifth time over. Its thematic home, `types`, was the second-heaviest shard. Derived 2026-08-13
from two consecutive green merge_group runs (31655422530 and 31653614351): eval 149/151s, backend
165/160s, sqlite 185/191s, tools 202/213s, frontend 289/291s, types 322/324s, engines 373/364s —
`eval` cheapest on both, `engines` the pole, the opposite of what an earlier brief had assumed. It
also lands beside its nearest sibling by shape, `diff_compiler_import_order`. It reads no oracle
and needs no clang/emitter — only `./medaka`, 9 check/run invocations over generated tmp
fixtures, measured 5.0s wall.

`diff_compiler_core_ir_typed_modules` (#1608) needed no new pattern — the existing
`diff_compiler_core_ir*` glob already matched it, and this shard was where it belonged anyway on
both cost and oracle overlap. Cost re-derived 2026-08-14/15 from three consecutive green
merge_group runs (31846695129, 31836577116, 31835386721; the previous paragraph's numbers were
already 2x off one month earlier): eval 301/304/312s, sqlite 318/201/314s, tools 378/174/369s,
backend 402/294/401s, frontend 491/360/393s, types 510/393/499s, engines 398/396/510s — `eval`
cheapest by mean AND lowest variance; `types` and `engines` were the poles. Oracle overlap was the
stronger reason: the gate reads `test/bin/core_ir_typed_modules_main` (new),
`core_ir_modules_main` and `eval_modules_main` — this shard already built the latter two for
`diff_compiler_core_ir_modules` and `diff_compiler_eval_modules`, so the true marginal cost was
one extra oracle build plus ~6 tiny programs; in any other shard it would have been three oracle
builds.

**`backend` shard**: `build_cmd` (T8) is the end-to-end gate for the shipping `medaka build` CLI —
14 real programs built through the actual CLI, each binary's stdout diffed against a committed
golden. It was misfiled in `CI-COVERAGE-TOOLS.txt` as a "build helper" (a claim that running it
proves nothing about the compiler, which was false — filing it there made the coverage gate
subtract it from its own scope and then certify full coverage). Nothing had invoked it in an
unknown length of time. It is the gate that would have caught a session's `diff_compiler_llvm`
bug (201/201 green against goldens no `medaka build` binary could produce — it was grading its
own probe). 14 ok / 0 failing, reads no oracle, needs only `./medaka` + the emitter.
`diff_compiler_index_oob` (#1787, 9.6s) lands here on cost. Its nearest sibling by shape,
`diff_compiler_slice_oob`, sits in `eval` because when it was filed "backend has no room" — that
inverted: derived from run 32336605670, backend 277s was the cheapest of the seven (eval 326s,
tools 323s, engines 408s, sqlite 436s, types 468s, frontend 530s). It needs `./medaka` + the
emitter (6 real `medaka build` + clang), already provided here for `diff_compiler_build` and
`build_cmd`.

**`tools` shard**: `diff_compiler_mcp` (#253, golden JSON-RPC transcript gate for `medaka mcp`) is
the same shape as its nearest sibling, `diff_compiler_lsp*` — placed by cost too: it reads no
oracle and the T1 handshake fixture is a handful of tiny `./medaka mcp` invocations (<1s), while
`engines`/`backend` (the two heaviest) have none to spare. `diff_compiler_entry_exit_codes` (#440,
pins that `compiler/entries/entry_support.mdk` exits non-zero on error) is parked here for cost —
one oracle and six cheap invocations (~2s), and `tools` had room (114 CPU-s vs. `engines`' 834,
the heaviest shard, which must never grow — it is NOT, despite an earlier note, the critical
path). `diff_compiler_test_typecheck` (#1229) is named explicitly, because the neighbouring
`diff_compiler_test` entry is an exact name, not a glob — a new sibling would silently never run
in CI, the exact hazard `diff_compiler_ci_shard_coverage` exists to catch. It reads no oracle and
is six `./medaka test` invocations over tmp fixtures (~2s).

### Re-deriving current numbers

Every number above is historical and rotted the day it was written. Current per-shard wall time
comes from `scripts/ci_shard_cost.sh`, which derives the table live from recent green
`merge_group` runs (the same `gh run view --json jobs` query these paragraphs used by hand,
scripted once instead of copy-pasted four times). When you add a heavy gate, run the script and
put it where there is room; do not hand-write a number into `ci.yml`.

#### By-job table (S-ledger-close, 2026-08-26, base `ec8670fa`)

`sh scripts/ci_shard_cost.sh --runs 4`, N derived fresh: `gh run list --workflow=ci.yml
--event=merge_group --status=success --json databaseId,createdAt --limit 50`, filtered to
`createdAt` after `4a636b0f`'s merge commit time (`2026-08-25T08:48:53Z`) — 4 qualifying runs
(`32900786425 32895999437 32838345858 32828602825`), same count the contract's own table used,
independently re-derived rather than reused:

```
gates (backend)                             543s
gates (frontend)                            525s
wasm                                        476s
gates (tools)                               469s
gates (eval)                                459s
gates (types)                               419s
gates (engines)                             398s
gates (sqlite)                              389s
compiler-soundness                          374s
build medaka once                           149s
seed-health                                  58s
inlang                                       32s
soundness                                    21s
detect docs-only change                       7s

median job wall: 393.5s
pole: gates (backend) (543s)
cost-status: clean
```

Pole moved: `gates (backend)` (543s) is now the pole, not `gates (sqlite)` — the #1968 nightly
report's 899s/1586s `sqlite` figures (see below) are from a different, unnarrowed event and do
not carry over to this `merge_group` table.

`ci.yml` hand-written-number check (§5, `grep -n '[0-9]\+s' .github/workflows/ci.yml`): the only
hits are matrix/timeout-unrelated comments (lines 609/614/616/627) citing prior
`scripts/ci_shard_cost.sh` runs by name ("confirmed... by this slice's own
`scripts/ci_shard_cost.sh` run") — every number present is provenance-attributed to the script,
none is a bare hand-typed figure the script doesn't trace to. #1935's pin holds.

#### By-event table (S-ledger-close, 2026-08-26)

#1926's original method: count runs of `ci.yml` per triggering `event` over a window, report the
split. Original window: 13 `push` / 32 `pull_request` / 15 `merge_group` (60 total). Per the
contract's own ⚠️, the honest window starts at #1942's merge (`19f60b28`, `2026-08-25T04:34:53Z`)
— pre-#1942 runs predate `push:main`'s removal and would blend two different CI shapes.

`gh run list --workflow=ci.yml --status=success --json databaseId,createdAt,event --limit 100`,
filtered to `createdAt` after `2026-08-25T04:34:53Z`: **25 runs** — `pull_request` 16 (64%),
`merge_group` 7 (28%), `schedule` 1 (4%), `push` 1 (4%).

⚠️ **The one `push` run is a stale-target artifact, not a live push-to-main.** Its `createdAt`
(`2026-08-25T05:10:08Z`) is after #1942 merged, but its `headSha` (`29b4c386`) is a commit that
landed on `main` at `04:33:46Z` — one minute *before* #1942 (`04:34:53Z`) — via a workflow queued
before #1927's `push:[main]` removal reached that commit's ancestry
(`git merge-base --is-ancestor 3b4cea93 29b4c386` → not an ancestor: #1927's commit `3b4cea93`
had not yet landed on the line `29b4c386` was built from). `gh run list --event=push --limit 5`
confirms **zero** `push` runs of `ci.yml` since `2026-08-25T05:10:08Z` — #1927's pin is holding
in practice, not just in the `on:` block.

n=25 is smaller than the original window's 60 — report the share as directional, not as a
stable long-run number; re-run after more post-#1942 history accumulates before treating the
64/28/4/4 split as settled.

## No-op shard visibility (#450, #570, #576)

A "gates (X) — pass" check on the PR's Checks UI is, by text alone, indistinguishable from a shard
that ran every gate and they all passed — and that ambiguity misled a reviewer into retiring a
correct instruction on an S0 fix (#570), then reappeared verbatim on #576's 7-shard no-op run
(#450 comment) filed before #570 landed.

#450's own analysis: the only sound fix is conclusion granularity (`neutral`/`skipped`), and that
touches the merge-queue's required-status-check contract (a required check reporting non-success
can block the queue) — unverified from a worktree with no live PR to test against, so deliberately
not attempted. Same reasoning rules out renaming the job itself: `name: gates (${{ matrix.name
}})` IS the required context the ruleset matches, so making it conditional would leave the "real"
required context permanently "Expected" on every no-op run.

So the conclusion and context stay untouched; what moves is the WORDING at every surface a
human/agent looks at without opening a log line-by-line — the annotation title and the job summary
heading, phrased as the self-evident no-op line itself, not a generic "ran 0 gates" label.

## Oracle cache keying is not obvious

Hashing the WHOLE `ci.yml` rather than just the shard's pattern: a pattern contains quotes, spaces
and `*`, none of which are legal in a cache key, and Actions has no hash-a-string function. A
comment-only edit to `ci.yml` therefore also busts the oracle cache — deliberately the safe
direction to be wrong in, the same trade the `compiler/**` glob in the key makes.

The pattern is load-bearing in the key too, and easy to miss: which oracles a shard builds is
derived FROM the pattern (`build_oracles.sh --for <pattern>`), so changing the pattern changes the
contents of `test/bin`. Without the pattern in the key, a `test/bin` cached before the pattern
changed would restore, the build step would be skipped, and the newly-needed oracles would simply
be absent. This went live the moment the `eval` shard gained the `bootstrap_*` gates — it fails
loudly (`run_gates.sh` reclassifies a missing oracle as FAIL*, phantom skip, never SKIP) rather
than silently, but it would have read as a baffling CI failure on an unrelated commit.

A narrowed `pull_request` run also builds only the oracles its subset of gates reads — a different
`test/bin` than the full run's, under a key that would otherwise be identical. `detect`'s
`oracle_key` output is `'full'` on merge_group/push and a hash of the derived gate set on a
narrowed PR, so the two can never collide.

## The tree-must-not-drift review gate

Roc's model: regeneration is the DEFAULT action and `git diff --exit-code` forces every
regenerated byte into review. That guard is what makes a frictionless `--bless` safe. GHC and
OCaml, lacking it, deliberately cripple blessing instead. This repo had NEITHER guard — the
dangerous quadrant — until this step landed. Today it catches gates that write into the tree;
after the snapshot migration lands `medaka snapshot --bless`, it becomes the real guard, and it
had to be load-bearing before blessing gets easy, not after.

## `seed-health`: the trust anchor (added 2026-07-13)

This job did not exist at all until 2026-07-13, and the seed was silently stale on main. The hole
was subtle: `make medaka` asks "CAN I build from the seed?" (and passed) while this gate asks
"does the seed still WORK, and how far has it DRIFTED?" — different questions. A stale seed still
cold-bootstraps fine (proven: it did, seven times over, while C3a was failing), so the cold build
passing told you nothing about currency, and nobody was asking the second question.

Policy (see `test/bootstrap_from_seed.sh`'s SEED POLICY note): the seed only has to WORK.
Byte-currency (C3a) is a drift detector, not a requirement — demanding it forced a re-mint on
every emitter change, which produced 41 re-mints, 86 MB, 40% of the repo's entire git history
before the policy was fixed. So here drift WARNS and a seed that can no longer do its job FAILS.
Re-mint at checkpoints (`make bootstrap` is strict).

## `soundness`: two gates documented but never enforced, until a10c2705

AGENTS.md had always said: for a compiler `.mdk` change, run the self-compile fixpoint and
`typecheck_compiler_source.sh`. Neither ran in CI. They ran when an agent remembered — a habit,
not a gate. It cost us: `snapshot.mdk` declared `export data SnapMode` (which exports a type
abstractly), `medaka_cli.mdk` imported `SnapMode(..)`, and every `SnapCheck`/`SnapNew`/
`SnapBless` in the CLI was an unbound variable. It shipped to main and every gate stayed green —
because the emitter's ctor table is global, so the ill-typed source still emitted a working
binary, and `make medaka` does not gate on `hadTypeErrors()`. Fixed in a10c2705. The bug was not
that it broke; it was that it couldn't be seen.

`typecheck` asks "is the compiler source well-typed?" (the build does not ask). `fixpoint` asks
"does the emitter reproduce itself?" (C3a/C3b byte-identical). `gates` runs the compiler; it
never typechecks it. `seed-health` proves the seed works; it never proves the current source is
well-typed, nor that emission has reached a fixpoint.

## The doc-gate incidents (soundness job)

**Fabricated symbols**: a repo-wide review found ~44 false concrete claims in the
`.claude/skills/*/SKILL.md` playbooks agents execute (a `pushTypeError` taught at the wrong arity,
a `Show` typeclass that never existed, a 20-name "grep these" index that was 19/20 fictional) —
~30 the same mechanical shape: a backticked symbol resolving nowhere in source.

**Spec clause labels**: `docs/spec/SHADOW-SEMANTICS.md` declares a numbered clause set (S1, S2,
...); commit 9c6dcee5 rewrote one clause in a 173-line hunk and silently carried three sibling
clauses (S6, S7, S8) out with it — its own commit message cites S7 twice as a live clause in the
commit that deleted S7's text. Nobody noticed for three weeks: every gate stayed green, because
neither the doc-links nor the fabricated-symbols gate checks this.

**Banned oracle command (#478/#527)**: ~54 gate scripts printed `sh test/build_oracles.sh` as
their remediation advice — the command AGENTS.md documents as spawning an `xargs -P` pool that
"outlives the agent's turn and gets RESPAWNED by the harness — it has killed several agents" — at
exactly the moment a reader is most likely to obey, right after a gate failed. #478 fixed 52
scripts and MISSED two — one of them `diff_compiler_engines.sh`, on the CI critical path —
because #478 scoped itself with a grep keyed on a fixed English phrase, and those two worded the
hazard differently. The fix was 52/52 complete against a set that was itself wrong: a sweep's
scope is an encoded fact too, and a wording-keyed grep confirms itself.
`test/check_no_banned_oracle_cmd.sh` keys on BEHAVIOR (does a message print the untargeted
command?) and derives its file set from `git ls-files`, so a new script is covered the moment it
is added. It found 2 further live instances (`capture_goldens.sh`, `tmc_census.sh`) that #527's
own hand-grep had missed.

**Keyword sync (#1451)**: the lexer's reserved-word list (`keywordOrIdent`,
`compiler/frontend/lexer.mdk`) is hand-duplicated into the vscode syntax grammar and the
playground tokenizer, and nothing diffed those literals against it — a word added to or removed
from the lexer left both copies silently wrong.

**Docs index**: `docs/README.md` is generated from the docs' `**Status:**` banners, because a
hand-maintained index rots — AGENTS.md's own doc-index table once sat mislabelling a doc as "IN
PROGRESS" that the doc itself called COMPLETE, and nothing noticed for weeks. A generator nothing
checks is just a suggestion, so the gate regenerates it and fails if it differs.

## Fingerprint mirror parity (#267, PR #263)

`test/build_native_medaka.sh`'s `src_fingerprint_compiler()` (shell/cat-based) and
`compiler/driver/medaka_cli.mdk`'s `liveSourceFingerprint` (perl-based) are two hand-synced
reimplementations of the same hashing algorithm — one bakes `-DMEDAKA_SRC_FP` into `./medaka` at
build time, the other recomputes it live on every invocation and hard-fails a mismatch under
`MEDAKA_STRICT=1`. #182's first attempt broke exactly this mirror and only human review (PR #263)
caught it — no gate proved the two still agreed. `test/check_fingerprint_parity.sh` re-exercises
the just-built `./medaka`'s own staleness self-check, under `MEDAKA_STRICT=1`, on the exact tree
it was built from, and asserts it reports "not stale". Still true after #1928 moved the build into
its own job: the binary arrives by artifact rather than by `make medaka`, but from the same SHA's
checkout, so "the exact tree it was built from" is unchanged.

## Must-fail suite location (#547)

Every `test/must_fail_fixtures/*` asserts an OPEN issue's bug still reproduces. When a fix lands,
the pin stops holding, the gate goes RED, and the message says to close the issue — the same
ratchet the doc gates already run under, applied to the last un-drained ledger in the repo. Six
entries were already dead when the backlog was re-derived on 2026-07-14 — two labelled "silent
build miscompile" — with nothing to notice.

It lives in `soundness`, not in a gate shard, and that is load-bearing: shards are NARROWED on
`pull_request` by `test/preflight.sh`'s path map, and a fix to `compiler/frontend/parser.mdk`
derives `'diff_compiler_parse*'` but would NOT derive this gate — the drain would fire only in the
merge queue, bouncing the PR after review. The alternative (adding it to preflight's `add` arms)
would be a hand-maintained map of which-bug-lives-in-which-file, the encoded-fact disease this
gate exists to cure. `soundness` runs full on every event, is already required, and already built
`./medaka`.

## Typecheck + fixpoint overlap, and why must-fail is excluded from it

`selfcompile_fixpoint.sh` asserts both C3a and C3b (`c3a && c3b`), the right bar for a checkpoint
re-mint but the wrong bar for CI: C3b (IR1 == IR2, the compiled compiler reproduces its own
output) is soundness, independent of the seed, and must hard fail; C3a (IR1 == the
seed-bootstrapped reference) is a drift detector, saying the checked-in seed is byte-current, not
that anything is broken. Blocking on C3a would turn CI red on every emitter change until someone
re-mints the seed — precisely the churn that produced 41 re-mints / 86 MB / 40% of the repo's git
history before the policy was fixed. So C3b errors, C3a warns; assert on the verdict lines, never
the script's raw exit status (and `| tee` would mask that status anyway).

Typechecking and fixpoint emission are independent, read-only consumers of the compiler tree and
use separate scratch paths, so they run overlapped. Recent hosted runs spent ~2.7m and ~0.8m on
them serially; overlapping caps typecheck's entry-worker pool at three so the fixpoint process
retains one of the four hosted-runner cores.

The overlap does NOT extend to the must-fail suite: its fixtures contain fail-capable 60-second
alarms. The first experiment correctly went red when CPU contention changed a pinned
stack-overflow exit 134 into timeout exit 142.

## T25: the WasmGC backend gates (added as one job, not six more shards)

The WasmGC backend is one of Medaka's two production backends and the engine the playground (the
0.1.0 front door) runs on — yet until this job its Wasm gates ran in NO CI job at all. A stock
`ubuntu-latest` runner has neither wasm-tools nor a WasmGC-capable node>=22, and the gates skip
(exit 2) when the toolchain is absent, so nothing was watching. That is exactly how two silent
wasm miscompiles (a `round` divergence, `intToFloat` #199) reached main. See
`CI-COVERAGE-EXCEPTIONS.txt`'s history for the ledger these five rows lived in until T25.

One job, not six more gate shards, on purpose: only these gates need wasm-tools + a WasmGC node.
Adding that toolchain to every `gates` shard would tax all seven for a tool one job needs — the
same reasoning `CI-COVERAGE-EXCEPTIONS.txt` already spelled out for `build_wasm_cmd`.

These five gates are not sharded (they contribute no matrix `pattern:`) — they are "named" gates,
each invoked by its literal repo-relative path, the same mechanism the `soundness` job uses for
the fixpoint + typecheck gates. Their `CI-COVERAGE-EXCEPTIONS.txt` rows were deleted when this job
landed.

The "required check" status was verified live on 2026-07-17 after a comment block had gone stale
saying "NOT YET A REQUIRED CHECK ... advisory-but-visible" — stale, and load-bearing, because it
was cited by #597 and by `docs/spec/WASM-SEMANTICS.md` as the reason wasm parity blocked nothing.
`wasm` is in fact in the required set and has been since 2026-07-15. Note WHERE the requirement
lives: a repository RULESET, not classic branch protection — the classic endpoint
(`…/branches/main/protection`) answers 404 "Branch not protected", which reads exactly like
"nothing is required here" and is how the earlier comment rotted; that same 404 is why pushes to
main fail with `GH013: Repository rule violations` rather than the classic protection error.

## Rotted claim census (fixed in S-ci-derive-cost, #1935)

Two counts in this file had rotted and were fixed by deriving rather than restating:

- "TEN required checks" was restated once as a fixed cardinal here — and a new required
  context (`compiler-soundness`) joined the ruleset ~24h later, breaking the restatement
  (#1967). Updating the number only resets the rot clock; the fix is to never write the
  cardinal down at all. Verify live, every time: `gh api
  repos/MedakaLang/medaka/rulesets/<id> --jq
  '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context'`
  — never hand-count, and never cite a count from this file.
- The `wasm` job's gates, once called "these FIVE" in its own comments → **seven**
  (`diff_wasm.sh`, `diff_wasm_typed.sh`, `diff_playground_input.sh`, `diff_wasm_modules.sh`,
  `diff_sqlite.sh`, `diff_gzip.sh`, `build_wasm_cmd.sh`). Re-derive by grepping the job's own
  `run:` step, never hand-count.
