#!/bin/sh
# shell-because: trust-anchor — circular: checks the machinery a native gate would run inside
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
#   (d) a baseline row names no gate the registry currently declares — the
#       reverse of (a): a gate deleted from test/gates.toml left its cost
#       history behind, and nothing else looks the other way (sprint
#       cost-governor-on S1, F6: `pds_test_unit_suite`, deleted in #2723,
#       sat in the committed baseline through 11 clean `gate verify` runs).
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
# ── Fixture self-test (FR-4, review finding S2-2 against S-5) ────────────────
#
# S-5's own header formerly argued a second harness would have to track
# `gate_cmd.mdk`'s schema forever, and demonstrated all three clauses plus the
# override mechanism by hand, against scratch-mutated registry/baseline
# copies, recorded in its own report. Nothing preserved those demonstrations
# as a regression: a change to the budget logic that silently broke one of
# them would not be caught until the next hand run. The review round judged
# that tradeoff wrong for a brand-new REQUIRED governor with zero coverage.
#
# `_budget` below runs `medaka gate budget` directly against a fixture pair
# under test/gate_balance_fixtures/ — the tool reads `--registry`/`--baseline`
# and never writes either, so (unlike diff_compiler_gate_balance.sh) no
# scratch copy is needed.
#
#   - `budget_uncosted.{toml,json}` pins clause (a) ALONE: one schedulable
#     gate with no baseline entry.
#   - `budget_over_class.{toml,json}` pins clause (b) ALONE: one costed gate
#     measured OVER its class's tolerance-adjusted ceiling but UNDER the raw
#     kill timeout — proving the comparison is against the tolerance-adjusted
#     number, not the bare timeout.
#   - `lpt_packing_gap.{toml,json}` (test/gate_balance_fixtures, already
#     documenting a real pole/floor 1.222 > 1.125 gap, S-5's own clause (c)
#     demonstration reused verbatim) pins clause (c).
#   - `budget_orphan.{toml,json}` pins clause (d) ALONE: one costed gate
#     matching the registry exactly, plus a second baseline row naming a
#     gate the registry does not declare.
#   - `budget_clean.{toml,json}` is a well-formed registry with zero
#     violations.
#
# Each violating fixture is run once plain (red) and once with the EXACT
# `Gate-Budget-Override:` token the tool's own red output printed, captured
# from that output rather than hand-typed — so a wording change in the
# remedy message breaks this fixture instead of silently drifting from what
# the tool actually prints. A separate run with a wrong/truncated token proves
# the match is EXACT, not substring/prefix.
#
# Usage:  sh test/diff_compiler_gate_budget.sh
# Exit:   0 zero unacknowledged violations against the real tree AND all
#         fixture checks pass; 1 at least one real violation or fixture
#         check failed; 2 no native medaka binary to run it with.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
FIX="$ROOT/test/gate_balance_fixtures"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

echo "── gate budget governor fixtures (#2180) ───────────────────────────────"

# Run the budget gate against a fixture pair. $1 = fixture stem, $2 = output
# file, rest = extra flags (e.g. --commit-message).
_budget() {
  _stem="$1"; _out="$2"; shift 2
  MEDAKA_ROOT="$ROOT" "$MEDAKA" gate budget \
    --registry "$FIX/$_stem.toml" \
    --baseline "$FIX/$_stem.json" \
    "$@" >"$_out" 2>&1
}

# ── clause (a): a schedulable gate with no baseline entry ───────────────────
out_a_red="$TMP/a_red.txt"; out_a_green="$TMP/a_green.txt"
if _budget budget_uncosted "$out_a_red"; then
  bad "clause (a) fixture was accepted with no override (should red)"
  sed -e 's/^/        /' "$out_a_red"
else
  if grep -q 'no cost baseline entry (clause a): 1' "$out_a_red" \
     && grep -q "^  lonely (baseline key 'lonely') — remedy:" "$out_a_red"; then
    ok "clause (a) alone reds: an uncosted schedulable gate, named WITH the baseline key it was looked up under"
  else
    bad "clause (a) fixture refused, but not for the uncosted reason"
    sed -e 's/^/        /' "$out_a_red"
  fi
  # The `ci-gen-drift` half of the message (review S4). A clause-(a) red on a
  # brand-new gate is never alone — the balancer refuses the same commit — and
  # an author who reads only the first sentence discharges half the problem.
  # Assert the stacking sentence and the rename cause it must not crowd out.
  if grep -q 'ci-gen-drift` runs `medaka gate balance --check`' "$out_a_red" \
     && grep -q 'hard-refuses to run in the same commit' "$out_a_red" \
     && grep -q 'whose `run` path was renamed' "$out_a_red"; then
    ok "clause (a) names both the ci-gen-drift stacking and the run-rename cause"
  else
    bad "clause (a) message dropped the ci-gen-drift half or the run-rename cause"
    sed -e 's/^/        /' "$out_a_red"
  fi
fi
tok_a="$(grep -o 'Gate-Budget-Override: [^[:space:]]*' "$out_a_red" | head -1 | sed 's/^Gate-Budget-Override: //')"
if [ "$tok_a" = "uncosted:lonely" ]; then
  ok "clause (a) prints the expected override token"
else
  bad "clause (a) override token captured as '$tok_a', expected 'uncosted:lonely'"
fi
msg_a="$(printf 'fix: clause (a) fixture\n\nGate-Budget-Override: %s\n' "$tok_a")"
if _budget budget_uncosted "$out_a_green" --commit-message "$msg_a"; then
  if grep -q '\[ACKNOWLEDGED\]' "$out_a_green" \
     && grep -q '1 violation(s), all acknowledged by commit-message trailer — OK' "$out_a_green"; then
    ok "clause (a) goes green with the tool's own printed override token"
  else
    bad "clause (a) exited 0 but did not report the acknowledgment shape"
    sed -e 's/^/        /' "$out_a_green"
  fi
else
  bad "clause (a) with its own override token still reds"
  sed -e 's/^/        /' "$out_a_green"
fi

# ── clause (b): a costed gate over its class's tolerance-adjusted ceiling ───
out_b_red="$TMP/b_red.txt"; out_b_green="$TMP/b_green.txt"
if _budget budget_over_class "$out_b_red"; then
  bad "clause (b) fixture was accepted with no override (should red)"
  sed -e 's/^/        /' "$out_b_red"
else
  if grep -q 'over declared class, tolerance-adjusted (clause b): 1' "$out_b_red" \
     && grep -q 'sluggish (cheap, measured 280.0s, tolerance-adjusted ceiling 266.6s of a 300s timeout)' "$out_b_red"; then
    ok "clause (b) alone reds: a costed gate over its tolerance-adjusted ceiling, named with its numbers"
  else
    bad "clause (b) fixture refused, but not for the over-class reason"
    sed -e 's/^/        /' "$out_b_red"
  fi
fi
tok_b="$(grep -o 'Gate-Budget-Override: [^[:space:]]*' "$out_b_red" | head -1 | sed 's/^Gate-Budget-Override: //')"
if [ "$tok_b" = "over-class:sluggish" ]; then
  ok "clause (b) prints the expected override token"
else
  bad "clause (b) override token captured as '$tok_b', expected 'over-class:sluggish'"
fi
msg_b="$(printf 'fix: clause (b) fixture\n\nGate-Budget-Override: %s\n' "$tok_b")"
if _budget budget_over_class "$out_b_green" --commit-message "$msg_b"; then
  if grep -q '\[ACKNOWLEDGED\]' "$out_b_green" \
     && grep -q '1 violation(s), all acknowledged by commit-message trailer — OK' "$out_b_green"; then
    ok "clause (b) goes green with the tool's own printed override token"
  else
    bad "clause (b) exited 0 but did not report the acknowledgment shape"
    sed -e 's/^/        /' "$out_b_green"
  fi
else
  bad "clause (b) with its own override token still reds"
  sed -e 's/^/        /' "$out_b_green"
fi

# ── clause (c): projected pole/floor over budget ─────────────────────────────
#
# Reuses test/gate_balance_fixtures/lpt_packing_gap.{toml,json}, which already
# documents a real pole/floor 1.222 > 1.125 gap — S-5's own report reused it
# verbatim by hand; this pins the same pair as a regression fixture.
out_c_red="$TMP/c_red.txt"; out_c_green="$TMP/c_green.txt"
if _budget lpt_packing_gap "$out_c_red"; then
  bad "clause (c) fixture was accepted with no override (should red)"
  sed -e 's/^/        /' "$out_c_red"
else
  if grep -q 'projected pole/floor over budget (clause c): 1' "$out_c_red" \
     && grep -q 'projected pole/floor 1.222 exceeds the budget 1.125 (S-4)' "$out_c_red"; then
    ok "clause (c) alone reds: a projected pole/floor over budget, with both numbers"
  else
    bad "clause (c) fixture refused, but not for the pole/floor reason"
    sed -e 's/^/        /' "$out_c_red"
  fi
fi
tok_c="$(grep -o 'Gate-Budget-Override: [^[:space:]]*' "$out_c_red" | head -1 | sed 's/^Gate-Budget-Override: //')"
if [ "$tok_c" = "pole-floor" ]; then
  ok "clause (c) prints the expected override token"
else
  bad "clause (c) override token captured as '$tok_c', expected 'pole-floor'"
fi
msg_c="$(printf 'fix: clause (c) fixture\n\nGate-Budget-Override: %s\n' "$tok_c")"
if _budget lpt_packing_gap "$out_c_green" --commit-message "$msg_c"; then
  if grep -q '\[ACKNOWLEDGED\]' "$out_c_green" \
     && grep -q '1 violation(s), all acknowledged by commit-message trailer — OK' "$out_c_green"; then
    ok "clause (c) goes green with the tool's own printed override token"
  else
    bad "clause (c) exited 0 but did not report the acknowledgment shape"
    sed -e 's/^/        /' "$out_c_green"
  fi
else
  bad "clause (c) with its own override token still reds"
  sed -e 's/^/        /' "$out_c_green"
fi

# ── clause (d): a baseline row names no registry gate ───────────────────────
out_d_red="$TMP/d_red.txt"; out_d_green="$TMP/d_green.txt"
if _budget budget_orphan "$out_d_red"; then
  bad "clause (d) fixture was accepted with no override (should red)"
  sed -e 's/^/        /' "$out_d_red"
else
  if grep -q 'baseline row names no registry gate (clause d): 1' "$out_d_red" \
     && grep -q '^  ghost — a cost baseline row for a gate the registry no longer declares' "$out_d_red"; then
    ok "clause (d) alone reds: an orphaned baseline row, named"
  else
    bad "clause (d) fixture refused, but not for the orphan reason"
    sed -e 's/^/        /' "$out_d_red"
  fi
  # The remedy must stay the one that WORKS: #2770 gave test/gate_cost_ingest.sh
  # a `--registry` prune mode, so the remedy now names that pass over a hand
  # edit. Pin the pass-based command and the issue that explains it.
  if grep -q 'sh test/gate_cost_ingest.sh --baseline test/gate_cost_baseline.json --registry test/gates.toml' "$out_d_red" \
     && grep -q '#2770' "$out_d_red"; then
    ok "clause (d) names a remedy that works today and cites #2770"
  else
    bad "clause (d) remedy no longer names the registry-prune pass or #2770"
    sed -e 's/^/        /' "$out_d_red"
  fi
fi
tok_d="$(grep -o 'Gate-Budget-Override: [^[:space:]]*' "$out_d_red" | head -1 | sed 's/^Gate-Budget-Override: //')"
if [ "$tok_d" = "orphan:ghost" ]; then
  ok "clause (d) prints the expected override token"
else
  bad "clause (d) override token captured as '$tok_d', expected 'orphan:ghost'"
fi
msg_d="$(printf 'fix: clause (d) fixture\n\nGate-Budget-Override: %s\n' "$tok_d")"
if _budget budget_orphan "$out_d_green" --commit-message "$msg_d"; then
  if grep -q '\[ACKNOWLEDGED\]' "$out_d_green" \
     && grep -q '1 violation(s), all acknowledged by commit-message trailer — OK' "$out_d_green"; then
    ok "clause (d) goes green with the tool's own printed override token"
  else
    bad "clause (d) exited 0 but did not report the acknowledgment shape"
    sed -e 's/^/        /' "$out_d_green"
  fi
else
  bad "clause (d) with its own override token still reds"
  sed -e 's/^/        /' "$out_d_green"
fi

# ── the override match is EXACT, not substring/prefix ───────────────────────
#
# A truncated token ("uncosted:lone" instead of "uncosted:lonely") must NOT
# silence the real clause (a) violation.
out_wrong="$TMP/wrong.txt"
msg_wrong="$(printf 'fix: wrong token\n\nGate-Budget-Override: uncosted:lone\n')"
if _budget budget_uncosted "$out_wrong" --commit-message "$msg_wrong"; then
  bad "a truncated/wrong override token silenced a real violation"
  sed -e 's/^/        /' "$out_wrong"
else
  if grep -q 'no cost baseline entry (clause a): 1' "$out_wrong" \
     && ! grep -q '\[ACKNOWLEDGED\]' "$out_wrong"; then
    ok "a truncated/unrelated override token does not silence the real violation"
  else
    bad "the wrong-token fixture reds, but not cleanly (or was partially acknowledged)"
    sed -e 's/^/        /' "$out_wrong"
  fi
fi

# ── the clean case: a well-formed registry passes with zero violations ──────
out_clean="$TMP/clean.txt"
if _budget budget_clean "$out_clean"; then
  if grep -q '^medaka gate budget: OK — 0 violations.$' "$out_clean"; then
    ok "a well-formed registry passes with zero violations"
  else
    bad "the clean fixture exited 0 but did not print the zero-violation line"
    sed -e 's/^/        /' "$out_clean"
  fi
else
  bad "the clean fixture reported a violation"
  sed -e 's/^/        /' "$out_clean"
fi

echo "── real tree ────────────────────────────────────────────────────────────"

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

if [ "$fail" -ne 0 ]; then
  echo "-- gate budget: $fail fixture check(s) failed"
  exit 1
fi

MEDAKA_ROOT="$ROOT" "$MEDAKA" gate budget --commit-message "$MSG"
