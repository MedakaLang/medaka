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

Until a macOS CI job exists, the only mitigation for a macOS-only break shipping through 100%-green
required checks is a manual macOS smoke test before tagging a release (tracked as #549).
