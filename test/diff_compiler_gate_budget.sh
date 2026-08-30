#!/bin/sh
# diff_compiler_gate_budget.sh — #2180's governor (S-5, epic #2182).
#
# Wraps `medaka gate budget` (compiler/tools/gate_cmd.mdk), which reds when:
#
#   (a) a schedulable gate has no cost baseline entry (`balUncosted`'s
#       condition — every registry entry MUST declare `cost`, since it is a
#       required TOML field checked at parse time, so this is the state that
#       can actually occur: a declared class the packer still cannot price).
#   (b) a gate's measured cost has eaten into the tolerance-adjusted timeout
#       its declared `cost` class implies (`timeoutFor`: cheap 300s / medium
#       900s / heavy 3600s) — the class is not free-floating metadata, it is
#       what kills the gate.
#   (c) the projected pole/floor (the SAME number `medaka gate balance
#       --check` derives, S-4's metric) exceeds the enforced budget
#       (`balTargetMilli`, 1.125).
#
# Any violation may be accepted on purpose with a structured, greppable
# acknowledgment: a `Gate-Budget-Override: <token>` trailer on an AUTHORED
# commit message in the change under test. There is no PR body in a
# `merge_group` run, so an authored commit message is the one thing the queue
# can always see.
#
# ⚠️ "AUTHORED" is load-bearing and was got WRONG when this gate landed (S-5;
# fixed by FR-2, review finding S1-2). `git log -1 --pretty=%B` on the
# CHECKED-OUT HEAD is correct locally and on `push`/`workflow_dispatch`, and
# is PROVABLY WRONG on both CI events that actually gate a merge:
# `actions/checkout@v4` with no `ref:` checks out a SYNTHETIC MERGE COMMIT on
# `pull_request` (`refs/pull/N/merge`) and on `merge_group`, and that commit's
# message is GitHub-authored boilerplate ("Merge pull request #N from ...")
# — never the text a human or agent pasted the trailer into. Measured on this
# repo's own history: PR #2212's queue commit 93a40382 reads "Merge pull
# request #2212 from ..."; its SECOND PARENT 1c1b48f3 carries the real
# authored message.
#
# So on CI the workflow resolves the authored message(s) itself — from the
# event payload's real base/head SHAs — and hands them over in
# GATE_BUDGET_COMMIT_MSG (`.github/workflows/ci.yml`, the `gate-budget:` job).
# This script prefers that variable whenever it is SET, and only falls back to
# HEAD's own message when it is entirely ABSENT, i.e. a local or manual run
# where HEAD really is the authored commit.
#
# TEXT-ONLY, NO BUILD beyond `./medaka` itself already existing — no clang, no
# oracle probe. `gate budget` reads test/gates.toml and
# test/gate_cost_baseline.json directly, exactly as `gate balance --check`
# does for its projection.
#
# A fixture-driven self-test of the three violation classes was considered
# and rejected for the same reason `diff_compiler_gate_registry.sh` rejects
# one (see its header): each class was reproduced by hand against a
# temp-copied, mutated registry/baseline pair and confirmed to red with the
# right violation and paste-able remedy, then to go green once the printed
# `Gate-Budget-Override:` trailer was supplied as `--commit-message`, and the
# tree was restored — recorded in this slice's report
# (/var/tmp/medaka-sprints/cost-enforcement/reports/S-5-budget-gate.md).
# Shipping a second "how to construct a violating registry" harness in this
# gate would have to track `gate_cmd.mdk`'s schema forever; running `budget`
# on the real tree is what CI actually needs protected.
#
# Usage:  sh test/diff_compiler_gate_budget.sh
# Exit:   0 zero unacknowledged violations; 1 at least one; 2 no native medaka
#         binary to run it with.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

# The override channel — see the header for why the CI arm cannot be
# `git log -1` on HEAD.
#
# The test is `+set`, NOT `-n`: a SET-BUT-EMPTY GATE_BUDGET_COMMIT_MSG means
# "CI resolved the authored message and there was no override text in it",
# and must NOT silently fall back to the synthetic merge commit — that
# fallback is the very bug FR-2 fixes. Falling through with an empty message
# is the fail-CLOSED direction anyway: a violation that exists still reds, it
# just cannot be silenced by an override this run cannot see. The same is
# true of the fallback's `git log` failing (shallow clone with no history, or
# no repo at all), which degrades to "no message".
if [ -n "${GATE_BUDGET_COMMIT_MSG+set}" ]; then
  MSG="$GATE_BUDGET_COMMIT_MSG"
else
  MSG="$(cd "$ROOT" && git log -1 --pretty=%B 2>/dev/null || true)"
fi

MEDAKA_ROOT="$ROOT" "$MEDAKA" gate budget --commit-message "$MSG"
