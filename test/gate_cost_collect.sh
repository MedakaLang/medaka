#!/bin/sh
# gate_cost_collect.sh — the AUTOMATED half of #2180's baseline auto-advance
# (S-1-baseline-autoadvance). Nothing ingested the `gate-timings-<row>`
# artifacts ci.yml already uploads on every admissible run; this script does:
#
#   1. list recent workflow runs, keep only ones whose event is on
#      test/gate_cost_ingest.sh's own admission allowlist AND whose
#      conclusion is "success" (a failed/cancelled run's timings are not a
#      representative sample of a healthy shard);
#   2. for each, download its `gate-timings-*` artifacts — SKIPPING CLEANLY
#      (not erroring) when a run has none, since ci.yml uploads them with
#      `if-no-files-found: ignore` and an old or partial run may simply lack
#      them;
#   3. hand every downloaded report to the real, unmodified
#      test/gate_cost_ingest.sh (which independently re-checks admissibility
#      and dedupes by runId:runAttempt:shard — re-collecting the same run
#      twice is a no-op, by that script's own key, not by anything here);
#   4. if the baseline file changed, re-derive the shard assignment with
#      `medaka gate balance && make gen-ci` (ALWAYS both, same commit — a
#      hand-balanced baseline with a stale ci.yml reds the required
#      `ci-gen-drift` check);
#   5. if anything changed (baseline / test/gates.toml / ci.yml), commit and
#      push to a FRESH branch — never `main`, never the sprint branch this
#      script itself might be running from — for a human or agent to review
#      and merge by hand. If nothing changed, exit 0 having pushed nothing:
#      a no-op ingest must produce no diff and no branch.
#
# WHY A BRANCH, NOT A PR: this repo's org/repo policy is "GitHub Actions is
# not permitted to create or approve pull requests" (measured directly:
# S-1-baseline-autoadvance's spike Q2, a `gh pr create` from a workflow's own
# GITHUB_TOKEN failed with exactly that GraphQL error, `pull-requests: write`
# already granted at job scope and irrelevant). That is stricter than the
# "GITHUB_TOKEN pushes don't retrigger other workflows" caveat GitHub's docs
# describe — it forecloses Actions-authored PRs outright, independent of
# per-job permissions, so a push-and-open-PR shape is not implementable here.
# The reduced human step is exactly one command (see the final log line):
#   git fetch origin <branch> && gh pr create --head <branch> --base <sprint/target branch> --fill
#
# Usage:
#   sh test/gate_cost_collect.sh [--limit N] [--branch-prefix P] [--dry-run]
#                                 [--push-remote R] [--base-branch B]
#
#   --limit N          how many recent runs of the CI workflow to consider
#                       (default 20; each run yields at most one sample per
#                       shard, so this bounds both API calls and download size)
#   --branch-prefix P  branch name prefix for the landing branch
#                       (default "cost-baseline-autoadvance")
#   --dry-run          do everything through the ingest + balance + gen-ci
#                       steps, print the diff, but never commit or push
#   --push-remote R    git remote to push to (default "origin")
#   --base-branch B    branch the new landing branch is cut FROM and the one
#                       the human-merge command above targets (default: the
#                       current branch's upstream, else "main")
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

LIMIT=20
BRANCH_PREFIX="cost-baseline-autoadvance"
DRY=0
REMOTE="origin"
BASE_BRANCH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --limit)         LIMIT="$2"; shift 2 ;;
    --branch-prefix)  BRANCH_PREFIX="$2"; shift 2 ;;
    --dry-run)        DRY=1; shift ;;
    --push-remote)    REMOTE="$2"; shift 2 ;;
    --base-branch)    BASE_BRANCH="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "gate_cost_collect: unknown argument: $1"; exit 1 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "gate_cost_collect: needs 'gh' on PATH"; exit 1; }

if [ -z "$BASE_BRANCH" ]; then
  BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$BASE_BRANCH" ] && [ "$BASE_BRANCH" != "HEAD" ] || BASE_BRANCH="main"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 1. admissible, successful recent runs ────────────────────────────────
# Same allowlist as the ingest script's own (kept in sync manually; the
# ingest script is the SOURCE OF TRUTH and re-checks this independently, so a
# drift here only costs a skipped run, never a false admission).
ALLOW_EVENTS="workflow_dispatch merge_group push schedule"

runs_json="$(gh run list --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")" \
  --limit "$LIMIT" --json databaseId,event,conclusion,headSha 2>/dev/null)"
if [ -z "$runs_json" ] || [ "$runs_json" = "null" ]; then
  # Fall back to repo-inferred form (works from inside a checked-out clone).
  runs_json="$(gh run list --limit "$LIMIT" --json databaseId,event,conclusion,headSha)"
fi

run_ids="$(printf '%s' "$runs_json" | python3 -c '
import json, sys
allow = set("'"$ALLOW_EVENTS"'".split())
runs = json.load(sys.stdin)
for r in runs:
    if r.get("event") in allow and r.get("conclusion") == "success":
        print(r["databaseId"])
')"

if [ -z "$run_ids" ]; then
  echo "gate_cost_collect: no admissible successful runs in the last $LIMIT — nothing to collect (clean skip)."
  exit 0
fi

# ── 2. download gate-timings-* artifacts, per admissible run, skipping ─────
#      cleanly when a run has none.
found_any=0
for rid in $run_ids; do
  outdir="$WORK/run-$rid"
  mkdir -p "$outdir"
  if gh run download "$rid" --dir "$outdir" -p 'gate-timings-*' >/dev/null 2>&1; then
    n="$(find "$outdir" -name '*.json' | wc -l | tr -d ' ')"
    if [ "$n" -gt 0 ]; then
      found_any=1
      echo "gate_cost_collect: run $rid — $n gate-timings artifact(s)"
    else
      echo "gate_cost_collect: run $rid — no gate-timings artifacts (skipping cleanly)"
    fi
  else
    echo "gate_cost_collect: run $rid — no artifacts reachable (skipping cleanly)"
  fi
done

if [ "$found_any" = "0" ]; then
  echo "gate_cost_collect: zero admissible runs carried gate-timings artifacts — nothing to ingest (clean skip)."
  exit 0
fi

reports="$(find "$WORK" -name '*.json')"

# ── 3. ingest (unmodified, real script; dedupes by runId:runAttempt:shard) ─
BASELINE_BEFORE="$(mktemp)"
cp "$ROOT/test/gate_cost_baseline.json" "$BASELINE_BEFORE"

# shellcheck disable=SC2086
sh "$ROOT/test/gate_cost_ingest.sh" $reports
ingest_rc=$?
if [ "$ingest_rc" != 0 ]; then
  echo "gate_cost_collect: gate_cost_ingest.sh refused (rc=$ingest_rc) — see its output above. No partial baseline written (the ingest script only writes on a fully successful run)."
  exit "$ingest_rc"
fi

# gate_cost_ingest.sh unconditionally rewrites the top-level "generated"
# timestamp on every invocation, even when it admits zero new samples (it is
# metadata about the ingest run, not about the data) — so a byte-for-byte
# `diff` here would report "changed" on every single run, permanently
# defeating "a no-op ingest must produce no diff" (measured directly while
# building this script: two back-to-back ingests of the identical report set
# differed ONLY in that one line). Compare with that one line stripped from
# both sides instead (POSIX `sh`, no process substitution).
grep -v '^  "generated": ' "$BASELINE_BEFORE" >"$WORK/before.stripped"
grep -v '^  "generated": ' "$ROOT/test/gate_cost_baseline.json" >"$WORK/after.stripped"
if diff -q "$WORK/before.stripped" "$WORK/after.stripped" >/dev/null 2>&1; then
  echo "gate_cost_collect: ingest admitted zero new samples (every candidate run was already recorded) — no-op, no diff, nothing to land."
  cp "$BASELINE_BEFORE" "$ROOT/test/gate_cost_baseline.json"
  rm -f "$BASELINE_BEFORE"
  exit 0
fi
rm -f "$BASELINE_BEFORE"

# ── 4. re-derive the assignment. ALWAYS both, same commit. ─────────────────
[ -x "$ROOT/medaka" ] || { echo "gate_cost_collect: ./medaka not built — run 'make medaka' first."; exit 1; }
"$ROOT/medaka" gate balance
bal_rc=$?
if [ "$bal_rc" != 0 ]; then
  echo "gate_cost_collect: 'medaka gate balance' failed (rc=$bal_rc) — see output above. Baseline was ingested but the assignment step failed; the working tree is left dirty for inspection, nothing is pushed."
  exit "$bal_rc"
fi
make -C "$ROOT" gen-ci
gen_rc=$?
if [ "$gen_rc" != 0 ]; then
  echo "gate_cost_collect: 'make gen-ci' failed (rc=$gen_rc) — nothing is pushed."
  exit "$gen_rc"
fi

# ── 5. land the result on a fresh branch, or report the clean no-op ────────
changed="$(git -C "$ROOT" status --porcelain -- test/gate_cost_baseline.json test/gates.toml .github/workflows/ci.yml)"
if [ -z "$changed" ]; then
  echo "gate_cost_collect: baseline advanced but the derived assignment did not move — no gates.toml/ci.yml diff, nothing to land."
  exit 0
fi

echo "gate_cost_collect: changes to land:"
git -C "$ROOT" diff --stat -- test/gate_cost_baseline.json test/gates.toml .github/workflows/ci.yml

if [ "$DRY" = "1" ]; then
  echo "gate_cost_collect: --dry-run — not committing or pushing."
  exit 0
fi

BRANCH="${BRANCH_PREFIX}-$(date -u +%Y%m%d%H%M%S)"
git -C "$ROOT" checkout -b "$BRANCH"
git -C "$ROOT" add test/gate_cost_baseline.json test/gates.toml .github/workflows/ci.yml
git -C "$ROOT" commit -m "gate cost: auto-advance baseline from CI artifacts ($(date -u +%Y-%m-%d))

Collected via test/gate_cost_collect.sh from admissible (workflow_dispatch/
merge_group/push/schedule) successful CI runs, ingested with
test/gate_cost_ingest.sh, and re-derived with 'medaka gate balance' +
'make gen-ci' (same commit, per AGENTS.md [W-SHARD-DERIVED])."

git -C "$ROOT" push "$REMOTE" "$BRANCH"
push_rc=$?
if [ "$push_rc" != 0 ]; then
  echo "gate_cost_collect: push failed (rc=$push_rc)."
  exit "$push_rc"
fi

echo ""
echo "gate_cost_collect: pushed $BRANCH. Actions cannot open the PR itself"
echo "  (repo policy: 'GitHub Actions is not permitted to create or approve"
echo "  pull requests' — measured in S-1-baseline-autoadvance's spike Q2)."
echo "  One command lands it as a reviewable diff:"
echo "    gh pr create --head $BRANCH --base $BASE_BRANCH --fill"
