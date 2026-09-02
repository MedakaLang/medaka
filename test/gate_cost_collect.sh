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
#      `medaka gate balance`, then run `make gen-ci` to PROVE generation
#      succeeds — and restore ci.yml, which this job cannot push (see the
#      block at step 4 in the body: `workflows` is not a grantable Actions
#      permission). Regenerating it is the one manual step, and the required
#      `ci-gen-drift` check reds until it happens;
#   5. if anything changed (baseline / test/gates.toml — never ci.yml), commit and
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
# The remaining steps (regenerate ci.yml, open the PR, enqueue) are taken by
# scripts/cost_baseline_land.sh from cron on the build box, which holds a
# real `gh` login; by hand they are (see the final log line):
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
#   --stale-threshold N  file-count delta above which an already-pushed,
#                       still-unmerged "${BRANCH_PREFIX}-*" branch is judged
#                       too stale to land (default 20). See STALENESS GUARD
#                       below.
#
# STALENESS GUARD (S-autoadvance-notify, #2181 deliverable 2): if nobody has
# merged the most recent previously-pushed "${BRANCH_PREFIX}-*" branch and
# --base-branch has since drifted more than --stale-threshold files away from
# it, this script refuses to push ANOTHER advance branch on top and says so —
# rather than silently compounding an already-stale, unreviewed pile (F3: a
# 2026-08-30 branch sat unmerged after its own job's report step got skipped
# by a failure, and by the time anyone looked it was 179 files / +2659/-15239
# against main — landing it then would have reverted unrelated work). 20 is
# comfortably above the routine per-run touch (at most 3 generated files:
# gate_cost_baseline.json, gates.toml, ci.yml) and comfortably below F3's
# magnitude. The guard applies only to a prior branch that has an OPEN PR:
# a prior branch with no PR was never engaged by anyone, is a strict subset
# of what this run will cut, and is deleted rather than piled on. Without
# that distinction the guard deadlocked the loop (2026-09-02: an unopened
# 01:03 branch drifted 672 files by the 12:07 run, which then refused).
#
# THE OTHER HALF — opening the PR and regenerating ci.yml — is
# scripts/cost_baseline_land.sh, run from cron on the build box (see
# docs/ops/CI-ARCHITECTURE.md §3.5). GitHub Actions can do neither on this
# repo, so a pushed branch is this script's ceiling.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

LIMIT=20
BRANCH_PREFIX="cost-baseline-autoadvance"
DRY=0
REMOTE="origin"
BASE_BRANCH=""
STALE_THRESHOLD=20

while [ "$#" -gt 0 ]; do
  case "$1" in
    --limit)         LIMIT="$2"; shift 2 ;;
    --branch-prefix)  BRANCH_PREFIX="$2"; shift 2 ;;
    --dry-run)        DRY=1; shift ;;
    --push-remote)    REMOTE="$2"; shift 2 ;;
    --base-branch)    BASE_BRANCH="$2"; shift 2 ;;
    --stale-threshold) STALE_THRESHOLD="$2"; shift 2 ;;
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

# `--workflow` scopes the candidate set to THIS repo's CI workflow
# (.github/workflows/ci.yml) specifically — without it, `gh run list` admits
# runs of ANY workflow in the repo (e.g. nightly.yml), diluting the baseline
# with timing data from a different schedule (FR-5, review finding S3-3).
WORKFLOW_FILE="ci.yml"

runs_json="$(gh run list --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")" \
  --workflow "$WORKFLOW_FILE" \
  --limit "$LIMIT" --json databaseId,event,conclusion,headSha 2>/dev/null)"
if [ -z "$runs_json" ] || [ "$runs_json" = "null" ]; then
  # Fall back to repo-inferred form (works from inside a checked-out clone).
  runs_json="$(gh run list --workflow "$WORKFLOW_FILE" --limit "$LIMIT" --json databaseId,event,conclusion,headSha)"
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

# ── ci.yml is REGENERATED to check it can be, then RESTORED. Never landed. ──
#
# GITHUB_TOKEN cannot push a change to a file under .github/workflows/. This is
# not a permissions oversight that a job-level grant can fix: `workflows` is NOT
# a valid key in an Actions `permissions:` block (the set is actions,
# artifact-metadata, attestations, checks, code-quality, contents, deployments,
# discussions, id-token, issues, packages, pages, pull-requests,
# security-events, statuses, vulnerability-alerts). The nightly job therefore
# failed every time the schedule moved, with:
#
#   ! [remote rejected] cost-baseline-autoadvance-... (refusing to allow a
#     GitHub App to create or update workflow `.github/workflows/ci.yml`
#     without `workflows` permission)
#
# The only ways to push ci.yml from CI are a PAT or App token carrying the
# `workflow` scope, stored as a repo secret — a long-lived credential able to
# rewrite the file that defines this repo's merge authority. Not worth it for a
# nightly convenience.
#
# So the job lands only the two DATA files. ci.yml is a pure function of
# test/gates.toml, and regenerating it is one command that the person opening
# the PR runs anyway (GitHub Actions may not open PRs on this repo either, so a
# human is always in this loop). Running gen-ci above and discarding the result
# is deliberate: it proves generation SUCCEEDS before we land a gates.toml that
# would otherwise strand `ci-gen-drift` red with no diagnosis.
ci_yml_moved=""
if [ -n "$(git -C "$ROOT" status --porcelain -- .github/workflows/ci.yml)" ]; then
  ci_yml_moved=1
fi
git -C "$ROOT" checkout -- .github/workflows/ci.yml

# ── 5. land the result on a fresh branch, or report the clean no-op ────────
#
# By this point step 3 has already returned early on "zero new samples", so
# test/gate_cost_baseline.json HAS changed — a status check on it here can
# never come back empty, and the old single combined check (baseline +
# schedule together) could therefore never take its "nothing moved" branch
# (FR-5, review finding S3-4: dead/misleading branch). What genuinely varies
# is whether the derived SCHEDULE (test/gates.toml / ci.yml) moved along with
# it, so the two are checked independently:
#
#   baseline changed, schedule changed   -> land both (today's behavior)
#   baseline changed, schedule unchanged -> land the baseline-only advance,
#                                            so the sample isn't discarded on
#                                            an ephemeral runner (previously
#                                            silently dropped by this dead
#                                            branch — the fix this item makes)
#   baseline unchanged                   -> unreachable here (step 3 already
#                                            exited); if it somehow occurs,
#                                            fall through and land whatever
#                                            did change, rather than assume it
#                                            can't happen
baseline_changed="$(git -C "$ROOT" status --porcelain -- test/gate_cost_baseline.json)"
# gates.toml ALONE — ci.yml was restored above and is never landed by this job.
# `$ci_yml_moved` records whether it would have moved, for the report only.
schedule_changed="$(git -C "$ROOT" status --porcelain -- test/gates.toml)"

if [ -z "$baseline_changed" ] && [ -z "$schedule_changed" ]; then
  echo "gate_cost_collect: nothing changed after ingest + re-derive — no-op, nothing to land."
  exit 0
fi

to_land=""
[ -n "$baseline_changed" ] && to_land="$to_land test/gate_cost_baseline.json"
[ -n "$schedule_changed" ] && to_land="$to_land test/gates.toml"

if [ -n "$baseline_changed" ] && [ -z "$schedule_changed" ]; then
  echo "gate_cost_collect: baseline advanced but the derived assignment did not move — landing the baseline-only advance."
elif [ -n "$baseline_changed" ] && [ -n "$schedule_changed" ]; then
  echo "gate_cost_collect: baseline advanced and the derived assignment moved — landing both."
else
  echo "gate_cost_collect: schedule changed with no baseline diff — landing the schedule change (unexpected shape; investigate)."
fi

echo "gate_cost_collect: changes to land:"
# shellcheck disable=SC2086
git -C "$ROOT" diff --stat -- $to_land

# ── staleness guard: refuse to push another advance while an existing, ─────
#    unmerged "${BRANCH_PREFIX}-*" branch has already drifted too far from
#    BASE_BRANCH to land cleanly. See the STALENESS GUARD header comment.
# shellcheck disable=SC2086
prior_branch="$(git -C "$ROOT" ls-remote --heads "$REMOTE" "${BRANCH_PREFIX}-*" 2>/dev/null \
  | awk '{print $2}' | sed 's#^refs/heads/##' | sort | tail -1)"
prior_pr=""
if [ -n "$prior_branch" ]; then
  prior_pr="$(gh pr list --head "$prior_branch" --state open --json number --jq '.[0].number' 2>/dev/null)"
fi
if [ -n "$prior_branch" ] && [ -z "$prior_pr" ]; then
  # A prior branch that nobody opened a PR from is superseded by the one this
  # run is about to cut: every advance branch is cut fresh from BASE_BRANCH
  # and carries only regenerated files, so the newer one contains everything
  # the older one did. Delete it and go on; the staleness guard below is for
  # a branch a human (or scripts/cost_baseline_land.sh) has already engaged.
  echo "gate_cost_collect: '$prior_branch' has no open PR — superseded; deleting it and cutting a fresh advance."
  git -C "$ROOT" push "$REMOTE" --delete "$prior_branch" >/dev/null 2>&1 \
    || echo "gate_cost_collect: could not delete '$prior_branch' (continuing; it will be re-judged next run)."
elif [ -n "$prior_branch" ]; then
  if git -C "$ROOT" fetch --depth=1 "$REMOTE" "$prior_branch" >/dev/null 2>&1; then
    prior_sha="$(git -C "$ROOT" rev-parse FETCH_HEAD)"
    if git -C "$ROOT" fetch --depth=1 "$REMOTE" "$BASE_BRANCH" >/dev/null 2>&1; then
      base_sha="$(git -C "$ROOT" rev-parse FETCH_HEAD)"
      stale_files="$(git -C "$ROOT" diff --numstat "$prior_sha" "$base_sha" 2>/dev/null | wc -l | tr -d ' ')"
      if [ -z "$stale_files" ]; then stale_files=0; fi
      if [ "$stale_files" -gt "$STALE_THRESHOLD" ]; then
        echo "gate_cost_collect: refusing to push a new advance branch — '$prior_branch' has PR #$prior_pr open and has drifted $stale_files files from '$BASE_BRANCH' (threshold $STALE_THRESHOLD files). CI has not let it land; a human needs to land or close PR #$prior_pr before this job can safely push another advance on top of it."
        exit 1
      fi
      echo "gate_cost_collect: staleness check — '$prior_branch' (PR #$prior_pr) is $stale_files file(s) from '$BASE_BRANCH' (threshold $STALE_THRESHOLD) — OK to push another advance."
    else
      echo "gate_cost_collect: staleness check — could not fetch '$BASE_BRANCH' from '$REMOTE' to compare; proceeding without the guard."
    fi
  else
    echo "gate_cost_collect: staleness check — could not fetch prior branch '$prior_branch' from '$REMOTE' to compare; proceeding without the guard."
  fi
fi

if [ "$DRY" = "1" ]; then
  echo "gate_cost_collect: --dry-run — not committing or pushing."
  exit 0
fi

BRANCH="${BRANCH_PREFIX}-$(date -u +%Y%m%d%H%M%S)"
git -C "$ROOT" checkout -b "$BRANCH"
# shellcheck disable=SC2086
git -C "$ROOT" add $to_land
git -C "$ROOT" commit -m "gate cost: auto-advance baseline from CI artifacts ($(date -u +%Y-%m-%d))

Collected via test/gate_cost_collect.sh from admissible (workflow_dispatch/
merge_group/push/schedule) successful CI runs, ingested with
test/gate_cost_ingest.sh, and re-derived with 'medaka gate balance'.

DATA ONLY — .github/workflows/ci.yml is deliberately NOT in this commit:
GITHUB_TOKEN cannot push a workflow file, and 'workflows' is not a grantable
Actions permission. Regeneration is one command and it is REQUIRED before
this branch can go green:

    make gen-ci && git commit -a --amend --no-edit

Until that runs, the required 'ci-gen-drift' check reds by construction and
its own error message names this exact fix."

git -C "$ROOT" push "$REMOTE" "$BRANCH"
push_rc=$?
if [ "$push_rc" != 0 ]; then
  echo "gate_cost_collect: push failed (rc=$push_rc)."
  exit "$push_rc"
fi

echo ""
echo "gate_cost_collect: pushed $BRANCH. Actions cannot open the PR itself"
echo "  (repo policy: 'GitHub Actions is not permitted to create or approve"
echo "  pull requests' — measured in S-1-baseline-autoadvance's spike Q2),"
echo "  and cannot push ci.yml at all (no grantable 'workflows' permission)."
if [ -n "$ci_yml_moved" ]; then
  echo "  ⚠️ The derived assignment MOVED, so ci.yml must be regenerated —"
  echo "  'ci-gen-drift' reds until it is."
else
  echo "  The derived assignment did not move, but regenerate anyway so the"
  echo "  branch is verified against its own generator."
fi
echo "  scripts/cost_baseline_land.sh (cron on the build box) does both and"
echo "  opens + enqueues the PR. By hand, the same three commands are:"
echo "    git fetch origin $BRANCH && git checkout $BRANCH"
echo "    make gen-ci && git commit -a --amend --no-edit && git push -f"
echo "    gh pr create --head $BRANCH --base $BASE_BRANCH --fill"
