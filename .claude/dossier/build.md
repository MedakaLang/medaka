## [B-STALENESS] Staleness guard mechanics

`checkSourceStaleness` emits the warning with `ePutStrLn`, and nothing else in the tree prints it
(`grep -rn 'may be stale; rebuild' compiler/` finds exactly one call site, inside that function).

## [B-STDERR] Warning-on-stderr, both directions load-bearing

Measured on a deliberately stale `medaka run`: stdout carries the program's value alone, exit 0,
and `head -1` on stdout returns that value — never the warning. This cuts both ways: don't build a
freshness probe around stdout/exit code without `MEDAKA_STRICT=1`; do suspect staleness (not a
regression) when an empty-stderr gate goes red (#1421) or an MCP result grows `staleBinary`
(`sourceStalenessVerdict` threaded into `runMcpServer` / `attachStaleness`,
`compiler/tools/mcp.mdk`, a second graded channel for the same warning).

## [B-STRICT-TWO-ARM] PR #1645 incident

Staleness is computed against `<exeDir>/compiler`. A two-arm differential comparison shares one
compiler tree by construction, so the older arm's baked fingerprint can never match the source
sitting beside it — that's not a stale binary, it's the guard doing its job on a layout it wasn't
designed for. Measured 2026-08-15 on PR #1645: the first differential run reported total
divergence for exactly this reason before the cause was understood.

## [B-NO-EDIT-DURING-BUILD] Lost rebuild, 2026-08-14

A `.mdk` edit made after `make medaka` begins — even just a comment — produces a binary that
silently lacks the edit and whose baked stamp no longer matches the tree on disk, tripping the
staleness guard on every subsequent probe (or, without `MEDAKA_STRICT=1`, silently measuring the
stale arm). Measured 2026-08-14: one full rebuild lost to this.

## [B-BORROW-EMITTER] mtime vs provenance history

The build used to decide emitter staleness by **mtime**, which `cp` (a borrow) inverts — that
inversion is where the spurious "lagging seed" scares originated. The current mechanism checks a
separate `.medaka_emitter.srcstamp` provenance stamp beside the emitter binary; `cp` doesn't copy
it, so `build_native_medaka.sh` always reports "provenance unknown" for a borrowed emitter and
rebuilds it from current source anyway (`test/build_native_medaka.sh:212-221`, the "fresh
bootstrap, or copied in from another tree" branch covers both cases identically). A prior version
of this doc described borrowing as a "warm start" in one clause and then stated, in its very next
clause, the mechanism that defeats a warm start — a self-contradiction now corrected in the main
text.

## [B-NO-BORROW-ISOLATED] Two-agents-one-tripped, 2026-07-16

In the same 2026-07-16 session, one worktree-isolated subagent ran `cp <other-tree>/medaka_emitter
.` and tripped the auto-mode isolation classifier. The denial was stateful: it carried forward and
blocked every later `make` the agent attempted, including a clean cold-bootstrap entirely inside
its own worktree — and the agent's stated reasons for the successive denials even contradicted
each other ("you are in another agent's worktree" → "bare `make` risks the shared main checkout").
A second subagent in the same session borrowed the emitter the same way with no issue at all —
the failure is real but not reliably predictable, which is why the remedy is "never do it" rather
than "do it carefully."

Separately, the "~31s cost either way" figure in the main text used to read **~4s** until
2026-07-16 — an ~8× understatement that had propagated into new code verbatim before being
caught and re-derived.

## [B-CI-UBUNTU-ONLY] / [B-DUAL-PLATFORM] mitigation note

Since #2533, a macOS smoke (`.github/actions/macos-smoke`) runs nightly and on PRs touching
`runtime/`, the build driver, the bootstrap scripts or the release scripts — neither run is a
required check, and neither runs the gate suite. A macOS-only break outside those paths still
merges green and is caught the next night at the earliest; a manual macOS smoke test before
tagging a release remains the backstop (tracked as #549).

## [B-NO-BORROW-ISOLATED] — build-cost measurements (2026-09-08)

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

🚨 **[B-NO-BORROW-ISOLATED] In a worktree, never `cp` an emitter from another tree — just
`make -C <your-absolute-worktree-path> medaka`.** A fresh worktree has no `./medaka_emitter`
and that is FINE. Three cases, measured on this box (Debian 13, 12-core/32GB) on
2026-09-08, with both links on module-partitioned ThinLTO (#2725, #2752; see "PARALLEL
CODEGEN" in `test/build_native_medaka.sh`), each with `time sh test/build_native_medaka.sh`:
  - **cache-served fresh worktree** (no `./medaka`/`./medaka_emitter` present, cache live) —
    **1s**, the usual case: the build cache serves a binary another tree already built from
    this exact source, and only the FIRST worktree at a given source state pays a real build.
    Unaffected by the codegen path. ⚠️ That cache holds **32 entries** (`MEDAKA_BUILD_CACHE_MAX`,
    a deliberate policy sized for concurrent multi-session use, not the accidental 8 an earlier
    revision of this file described, #2781) — a session doing enough forced rebuilds can still
    evict its own emitter entry and pay a full seed bootstrap on the next "fresh worktree"
    (measured against the old cap, same session: **68s**), but a miss caused by eviction now
    reports distinguishably from a first-ever miss, so that cost is legible instead of a
    mystery 1s→90s jump.
  - **warm forced full rebuild**, `FORCE_EMITTER_REBUILD=1 MEDAKA_BUILD_CACHE_DIR=` with the
    emitter already present — **96s / 89s** on a cold `$MEDAKA_SCRATCH` ThinLTO cache, **43s**
    once that cache holds this exact source. Interleaved against the 8-partition default it
    replaced, same hour: 99s / 90s, which could not reach a warm figure at all before its
    cache keys stopped carrying the per-build `mktemp` path. Box load moves all of these
    30–40% run to run; compare arms interleaved, never across sessions.
  - **cold, cache forced off** (no `./medaka`/`./medaka_emitter` present, forcing the seed
    bootstrap) — **89s** with a warm ThinLTO cache. `test/bootstrap_from_seed.sh` still links
    the seed and `emitter2` with plain `clang -O2`, which is where that time goes.
  ⚠️ A one-module edit costs the floor (partitioning + the partition compiles) plus the edited
  partition and its importers. Measured, warm cache, one-line edits: `compiler/tools/lint.mdk`
  — **19s of stage-B link against a 14s no-edit floor, 7 of 117 ThinLTO cache entries
  rewritten**; `compiler/frontend/desugar.mdk` — 18 entries, and stage A legitimately rebuilds
  because it is in the emitter's closure. Anything per-build that reaches the LTO unit destroys
  this: the build-provenance stamps did until they moved to their own non-LTO translation unit,
  and cost every entry while they did. Keep them out.
So the worst case is a few minutes, not the stale "~31s" figure, which is off by an order of
magnitude. Cold exceeds warm-forced by the seed bootstrap, the only ordering physically
possible; a cold figure BELOW the warm-forced one means the cache or an existing emitter was
live during the measurement. Borrowing an emitter does not even save the rebuild
(only the seed step). Reading another tree can trip the isolation classifier into a denial
that blocks every later `make`. Rationale + the `[B-BORROW-EMITTER]` measurement: the
`sprint-orchestrator` skill.

## [B-ISOLATION-COMPOUND] — full rule text

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

🚨 **[B-ISOLATION-COMPOUND] `cp` is NOT the only trigger (#1148, OPEN, ~32 occurrences across 5
sprints).** In an isolated worktree the classifier also refuses ordinary compound shells that
never leave your tree — `cd X && …`, `;`-chains ending in `echo $?`, heredocs, a `for` loop,
`python3 - <<EOF`, a pipe feeding `git` its args, a redirect combined with `-C`. ⇒ **One plain
command per Bash call; multi-step work goes into a script file, with any mandatory redirect
([D-BUILD-PIPE]) INSIDE it** — "drop the redirect" is not available to you.
⚠️ **That is mitigation, not immunity: a bare, foreground, correct-cwd `make medaka` has been
denied too.** When it is, the tell is the program name, not the work — **`sh
test/build_native_medaka.sh` (the literal body of the `medaka:` target) succeeded first try in
the session where four `make medaka` forms were refused**, so reach for it before concluding
anything. EnterWorktree is a dead end (your cwd already IS the worktree). If the build is
denied every way, you are BLOCKED: stop and report. Do not degrade to source-only work — a
no-build agent's "no such site exists" is not a finding. The denial SOMETIMES carries forward
across a session and sometimes does not; it is not predictable and not testable.

## [B-RELPATH-DENY] — full rule text

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

🚨 **[B-RELPATH-DENY] `medaka fmt --write <relative/path>` / `medaka lint <relative/path>` can
be silently denied too (#1823)** — a DIFFERENT mechanism from `[B-ISOLATION-COMPOUND]` (#1148):
this fires on a single, plain, non-compound command, keyed on path *form* (relative vs.
absolute), and the denial message is generic, not the isolation-specific phrasing. The
identical command with an absolute path succeeds immediately. ⇒ Always pass absolute paths to
`fmt`/`lint`, per `[T-WORKTREE-PATHS]`'s general advice.

## [B-CI-UBUNTU-ONLY] — full rule text

*Full `AGENTS.md` text as of 2026-10-03, moved here verbatim when AGENTS.md was slimmed; AGENTS.md keeps the rule and the command.*

⚠️ **[B-CI-UBUNTU-ONLY] Every REQUIRED check runs on `ubuntu-latest`; macOS gets a smoke, never
the gate suite** (#2533). The smoke (`.github/actions/macos-smoke`: cold seed bootstrap,
`check`/`run`/`build` on inline programs, dist smoke) runs NIGHTLY (`nightly.yml` `macos-smoke`,
red files a `known-red` issue) and on a PR only when it touches `runtime/`, the build driver,
the bootstrap scripts or the release scripts (`.github/workflows/macos.yml`'s `paths:`), not
required either way. ⇒ **A macOS-only break anywhere else ships green and surfaces the next
night.** Derive the non-Linux jobs, don't trust this list:
```sh
grep -rn "runs-on" .github/workflows/*.yml | grep -v ubuntu-latest   # the macOS jobs, nothing else
```
Still smoke-test by hand on macOS before tagging a release (#549).

Two platform facts: emitted LLVM IR carries **no target triple** (seed cold-bootstraps on x86 or
arm from the same bytes); the compiler's stack comes from a **256 MB GC-aware worker pthread**
in `runtime/medaka_rt.c`, not a link flag — fine under Linux's default 8MB `ulimit -s`.
