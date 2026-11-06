# MCP authority decisions

The 2026-11-05 replays at `9a0ccbda624ee198616b965247a33eaaf303560e`
reproduced two blockers. The [ownership receipt](OWNERSHIP.md) records an
unavailable protected manager and a read-only cgroup mount. The [stdio receipt](STDIO.md)
refuses the broad runtime seal because it denies required supervisor file work.
Neither result qualifies a production authority boundary. The compact
[machine-readable summary](summary.json) points to the pinned receipts.

Run the two independent probes as described in those receipts after `make medaka`.
Each exits 77 for the measured blocked host; exit 1 denotes a failed control.
The registered `test/process_authority_test.mdk` checks the local refusal,
protocol and endpoint controls and exercises removed admission, nonexecution and
ownership guards. Its Linux stdio controls do not replace deployment qualification.
An unavailable host is not evidence of containment. Positive deployment requires
the distinct protected-host matrix and receipt described in OWNERSHIP.md.

The next owned-scope experiment needs an explicitly delegated disposable cgroup
and a protected manager able to retain launch and cleanup ownership through
caller and broker death. The next stdio experiment needs a narrower, enforced
file/resolver/output boundary that preserves supervisor work, or a separately
recut and measured protocol-owner/workspace split. The implementation handoffs
and their acceptance rules are in [PROCESS-SUPERVISION.md](../../design/PROCESS-SUPERVISION.md).
#4854, #4855 and #4856 remain open.
