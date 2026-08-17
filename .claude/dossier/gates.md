## [L-PREFLIGHT] The agent loop

No incident narrative beyond the rule itself: run targeted gates, push, let CI run the rest
across six parallel hosted runners. The "order the cheap checks first" formatter/linter
sequencing note (fmt --write, lint, rebuild, re-check after formatter/linter-affecting changes)
is procedural, not incident-backed — kept in full in AGENTS.md.

## [L-DERIVE-ONLY] `--for '<pattern>' --list` ordering trap

`test/build_oracles.sh`'s derive-only mode is a positional test on the first two args:
`[ "$1" = "--for" ] && [ "$2" = "--list" ]`. Write the pattern before `--list`
(`--for '<pattern>' --list`) and that test is false — `--list` is consumed as *another gate
pattern*, resolves to no gate, contributes nothing, and the real pattern still resolves. The
script proceeds to compile the whole derived oracle set while the caller is waiting for a list.
There is no diagnostic, because nothing is malformed — this is what makes it a trap rather than
an error.

## [L-FOREGROUND-CEILING] The 10-minute foreground ceiling

`make preflight` on a `compiler/backend/*` diff forces the self-compile fixpoint; the loop can
exceed the 10-minute foreground tool ceiling and gets killed at 600s with `exit 143` (SIGTERM).
That is the harness's ceiling firing, not the change hanging — don't debug a phantom.

Measured timings: `test/diff_compiler_perf_scaling.sh` directly, 654-748s (~11-12 min) — one of
the slowest gates in the tree, just as foreground-unsafe as a single blocking call.
`test/diff_compiler_engines.sh` (3-engine differential): its own `ENGINE_JOBS` table reads
`JOBS=3 ~5min`; `MEDAKA_REQUIRE_WASM=1` (the CI wasm arm) pushes it to ~7min.

Knobs, each independently settable (not just measurements): `PERF_N=<n>` (default 250, shrinks
perf_scaling's input for faster local iteration; quick mode is the default scope, `PERF_DEEP=1`
restores the full nightly scope); `ENGINE_JOBS=<n>` (throttle fan-out on a shared/loaded box);
`ONLY=<glob>` (scope engines to a subset, #723).

`PREFLIGHT_DRY=1` and its sibling `PREFLIGHT_CHANGED_FILE=<path>` (hands preflight a changed-file
list directly instead of deriving one from `git diff`) are the recommended first step before
committing to a long run. Caveat (#520, #540): `PREFLIGHT_DRY` does NOT surface a forced
fixpoint — that decision fires *after* the DRY exit — so a short dry-run gate list does not by
itself mean the real run will finish inside the ceiling.

## [L-SHARED-BOX] Shared-box cost

Several agents share this box. One agent running the whole suite + a full oracle build takes the
load average past 10 and turns a 30-second gate run into several minutes for everyone else.
Worse: bare `FORCE=1 build_oracles.sh` spawns an `xargs -P` pool that outlives the agent's turn
and gets RESPAWNED by the harness — it has killed several agents. This is a real cost, not an
aesthetic preference — use the targeted forms.

## [L-PREFLIGHT-IS-FILTER] preflight is a filter, not an authority

`preflight` runs a subset and prints what it skipped. The merge queue (W-MERGE-QUEUE) is the
authority — not a green `pull_request` check — and nothing merges on a green preflight.

Mechanism: `ci.yml`'s "Plan this shard" step (`.github/workflows/ci.yml`, the `gates (…)` job)
NARROWS each shard on a `pull_request` event to the intersection of that shard's patterns with
the diff-derived gate set (`merge_group` runs ALL of them) — its own `why=` string says so
verbatim: *"pull_request — narrowed to the gates this diff touches (merge_group runs ALL of
them)"*. A shard whose intersection is empty still reports SUCCESS having run nothing.

This is explicitly NOT a hole: the planner fails closed (`::error::` + `exit 1`, same step) if a
shard's *pattern* matches no gates in the whole tree — that's the actual "a gate silently never
runs" hazard that `diff_compiler_ci_shard_coverage.sh` exists to catch. An empty per-PR
*intersection* is the designed-for common case, not that failure. Real coverage for a
narrowed-away gate runs later, in the merge queue's `merge_group` run, which is unnarrowed and
tests the PR merged onto `main`.

Measured instance: PR #1289 (a `compiler/frontend/resolve.mdk` change) reported all 12 required
checks green, but `gates (engines)`, `gates (sqlite)` and `gates (tools)` each had BOTH their
`Build medaka` and `Gate shard — …` steps `skipped` — `engines` went green in 7 seconds having
run nothing.

Related: "CI green" is not corroboration of a PR-body claim about a specific gate's numbers.
Reading a green rollup as proof that a cited gate ran with the cited result is an invalid
inference — made, and caught only in review, during the 2026-08-05 A-2 session.

## [L-BLAST-RADIUS] Blast-radius carve-out (#492)

For `stdlib/*`, `compiler/support/*`, `compiler/entries/*` and friends, preflight's own
`mark_full` adds the `diff_compiler_*` catch-all, so "the loop" silently becomes the ~84-gate
run that L-FOREGROUND-CEILING forbids running in the foreground. The widening is judged CORRECT
— a prelude change moves essentially every golden, and a narrow preflight would report green
having run only lexer + snapshot + doctests.

**Two agents were killed for obeying `make preflight` here** before it announced this loudly.
If you took the loop at its word on a prelude change, that was the tooling's bug, not yours. An
instruction that silently expands into what another instruction forbids is worse than either
alone: the one who obeys pays. (This is why preflight now announces the widening loudly before
spending the box, and prints the exact `run_gates.sh` line it's about to become.)

`PREFLIGHT_NO_FULL=1 sh test/preflight.sh` declines the widening and runs NOTHING — deliberately
not a narrower subset, because a green that tested less than it appears to is exactly the hazard
this whole suite exists to prevent.

## [L-NO-FULL-NOT-FIXPOINT] PREFLIGHT_NO_FULL doesn't reach the fixpoint case

`PREFLIGHT_NO_FULL` only guards `full_suite` (L-BLAST-RADIUS). A `compiler/backend/*` diff
instead sets a separate `need_fixpoint` flag (`grep -n need_fixpoint test/preflight.sh`), which
prints no banner and has no opt-out — the fixpoint runs unconditionally regardless of
`PREFLIGHT_NO_FULL`. If the 10-minute ceiling is what you're trying to dodge, background the
run; `PREFLIGHT_NO_FULL` will not skip the fixpoint for you (#520, #545).

## [L-PHANTOM-SKIP] Phantom skip is not a regression

If `run_gates.sh` reports gates FAILED with *"phantom skip: oracle/binary not built"* — that is
not a regression, you just have no oracles. They count as FAILED, not skipped, on purpose: a
gate that ran nothing must never report green.

## [L-SELFPROC-CARVEOUT] The one carve-out to L-PHANTOM-SKIP

A phantom-skipped `diff_compiler_selfproc` on a compiler-source change is NOT dismissible — this
has bitten twice. `test/preflight.sh` *correctly* selects `diff_compiler_selfproc` for any
`compiler/*/*.mdk` diff, but in a fresh worktree it has no `test/bin/check_all_main`, so it exits
2, becomes `FAIL* (phantom skip)`, and L-PHANTOM-SKIP's general rule tells you to ignore it. "A
correct gate plus a correct-in-general dismissal rule = shipping the break." That gate is the
*only* local signal for the moved selfproc LEG A scheme golden (T-LEGA-GOLDEN) and it reds in the
CI `backend` shard when you skip it. Two PRs have burned a CI round-trip this way; on #1005 the
deterministic red was then misread as a shared-runner flake and blind-retried.

## [G-LIST] Gate table

No separate narrative; each row's rationale is kept inline in AGENTS.md. The `make check-self`
addition is a fast first-line alternative to `typecheck_compiler_source.sh` — sub-minute (~20s),
runs `./medaka check` over the already-built binary's own `medaka_cli.mdk` closure;
`typecheck_compiler_source.sh` remains the fuller authority (also covers `compiler/entries/*.mdk`).

## [G-MUST-FAIL] Must-fail suite framing

Kept in full in AGENTS.md — it's a short, self-contained rule with no separable incident.

## [G-PIN-DRAIN] Prefer re-pointing over deleting a drained pin

On 2026-08-14 both #1617 and #1618 drained while **#1630** — the same arm, one type constructor
over — stayed live, demonstrating that a drained fixture is not a drained *class*. Re-pointing
also tends to *recover* coverage: the must-fail harness runs one `cmd:` plus one `control:`, so
any second dimension a fixture carried (a permutation twin, a build-vs-run cell) was sitting
there ungraded; moved into a differential gate it starts executing.

## [G-DRAIN-INVISIBLE] Drains are invisible locally

`test/preflight.sh` does not map `soundness` at all (`grep -n must_fail test/preflight.sh`
returns nothing), so neither `make preflight` nor `PREFLIGHT_DRY=1` will tell you a pin is about
to flip — it surfaces only in CI. When the must-fail step fails, the steps AFTER it in that job
are `skipped`, including `typecheck_compiler_source.sh` and the C3b fixpoint — i.e. the two
checks that catch an ill-typed compiler and a broken emitter. A red `soundness` "explained" as a
licensed drain is therefore also a `soundness` that ran neither of them.

## [G-STALE-ORACLE] Stale-oracle guard in run_gates.sh

`run_gates.sh` derives which `test/bin/*` probes the selected gates read, compares mtimes
against source, and refuses to run rather than report a false pass/fail. `diff_native_cli` and
the bootstrap suites are especially stale-prone when invoked outside `run_gates.sh` (e.g. bare
`sh test/diff_native_cli.sh`).

## [G-GOLDEN-CAPTURE-UNGUARDED] Golden capture has no staleness guard

Measured 2026-08-15 on PR #1640: after merging `main`, the LEG A golden was re-derived against
an oracle built **before** the merge — the gate read `16 ok, 0 failing` and the bless looked
clean. Rebuilding the oracles and re-deriving from scratch produced a byte-identical golden, "so
the artifact was right and the evidence for it was not." A wrong gate verdict is loud on the
next run; a wrong golden becomes the expected output — that asymmetry is why this is a 🚨 and not
a ⚠️.

## [G-PARALLELISM] Parallelism and opt-level knobs

No separate incident; see `compiler/PERF-RESULTS.md` for the measured detail behind "opt-level
knobs preserve byte-identical emitted IR."

## [G-BUILD-RACE] Concurrent build safety, and its limits

**`medaka build` scratch-path safety.** Until 2026-07-13 the IR path was keyed on the OUTPUT
BASENAME in global `/tmp`, so two concurrent builds writing `-o <somedir>/out` from different
worktrees/repos clobbered each other's IR and produced a stable-looking WRONG binary — measured
19/20 iterations. Anything that "keys the temp file on something distinctive" is a trap; only a
per-process `mktemp -d` is correct.

**`make medaka` was NOT covered by that guarantee (#1141).** `test/build_native_medaka.sh` used
to write `./medaka_emitter` and `./medaka` directly to their final paths with no lock, so a
reader could reasonably (and wrongly) generalize the scratch-path safety to the whole build path.
Fixed the same way the codebase already fixed `EMITTER` in stage A: every output is now built
under a `*.new.$$` name beside its own final path (not under `$WORK`/`mktemp -d`, which can be a
different filesystem — e.g. tmpfs `/tmp` vs the repo's real disk — making `mv` a non-atomic EXDEV
copy) and promoted with a same-filesystem `mv`.
