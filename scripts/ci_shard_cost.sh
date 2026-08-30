#!/bin/sh
# ci_shard_cost.sh — derive ci.yml's current per-job wall-clock table from recent green
# `merge_group` runs, via `gh`. Replaces the four hand-run `gh run view` one-liners that
# used to be copy-pasted into `.github/workflows/ci.yml` comments (each rotting the moment
# it was pasted — see `.claude/dossier/ci.md` for the history). Nothing in `ci.yml` should
# ever contain a hand-written performance number again; run this instead.
#
# A TOOL, not a gate — it asserts nothing about the compiler and is registered in
# test/CI-COVERAGE-TOOLS.txt, not run by any `diff_compiler_*` shard.
#
# Usage:
#   sh scripts/ci_shard_cost.sh              # human-readable table on stdout
#   sh scripts/ci_shard_cost.sh --runs N      # average over N runs instead of the default 5
#
# Requires `gh` authenticated against this repo. Uses the porcelain `gh run list` / `gh run
# view` subcommands (not raw `gh api`) — the same commands this repo's own dossier/AGENTS.md
# notes tell a human to run by hand, so this is that, scripted once instead of copy-pasted.
#
# Exits 2 (not 1) when it cannot reach the API or finds no qualifying runs — an INFRA
# failure, distinguished from a real finding the same way must_fail_census.sh does: grep the
# `cost-status:` marker line, never the exit code alone, for the findings-vs-clean signal.
#
# ── WHY merge_group runs, never pull_request runs ────────────────────────────────────
# A `pull_request` run can be NARROWED (T-15, see the dossier) — a shard that matched no
# gate for that diff reports in seconds, and averaging that in would silently understate
# every shard's real cost. `merge_group` always runs every shard's full pattern, so it is
# the only event whose job durations mean what this table claims they mean.

set -u

REPO="${GH_REPO:-MedakaLang/medaka}"
RUNS=5

while [ $# -gt 0 ]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --runs=*) RUNS="${1#--runs=}"; shift ;;
    *) echo "usage: $0 [--runs N]" >&2; exit 2 ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "::error::gh CLI not found — cannot derive shard cost." >&2
  echo "cost-status: infra"
  exit 2
fi

run_ids="$(gh run list --repo "$REPO" --workflow=ci.yml --event=merge_group \
  --status=success --json databaseId --limit "$RUNS" --jq '.[].databaseId' 2>/dev/null)"

if [ -z "$run_ids" ]; then
  echo "::error::no green merge_group runs of ci.yml found via gh run list." >&2
  echo "cost-status: infra"
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

n=0
for id in $run_ids; do
  # `gates (…)` aliases are EXCLUDED. During the #2178 context migration the eight
  # retired `gates (<theme>)` contexts are produced by no-op alias jobs that only
  # mirror the `gates` roll-up (see ci.yml). They cost seconds, so leaving them in
  # would drag the MEDIAN down and make the nightly "1.5x the median" drift filer
  # report crossings that are an artefact of the migration rather than a cost
  # change. They disappear with the aliases; the filter is harmless afterwards.
  if gh run view "$id" --repo "$REPO" --json jobs \
       --jq '.jobs[] | select(.conclusion == "success") | select(.name | startswith("gates (") | not) | "\(.name)\t\(((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601)))"' \
       >> "$tmp/durations.tsv" 2>/dev/null; then
    n=$((n + 1))
  fi
done

if [ ! -s "$tmp/durations.tsv" ]; then
  echo "::error::gh run view returned no job durations for the runs queried." >&2
  echo "cost-status: infra"
  exit 2
fi

# Average wall-seconds per job name across the queried runs.
awk -F'\t' '
  { sum[$1] += $2; count[$1]++ }
  END { for (name in sum) printf "%s\t%d\n", name, sum[name] / count[name] }
' "$tmp/durations.tsv" | sort -t "$(printf '\t')" -k2 -rn > "$tmp/table.tsv"

echo "── ci.yml per-job wall-clock, averaged over $n green merge_group run(s) of $REPO ──"
echo
awk -F'\t' '{printf "  %-40s %6ds\n", $1, $2}' "$tmp/table.tsv"
echo

# Median of the averaged per-job times, for the >1.5x-median flag.
median="$(awk -F'\t' '{print $2}' "$tmp/table.tsv" | sort -n | awk '
  { a[NR] = $1 }
  END {
    if (NR == 0) { print 0; exit }
    if (NR % 2) { print a[(NR+1)/2] }
    else { print (a[NR/2] + a[NR/2+1]) / 2 }
  }
')"

pole_name="$(head -1 "$tmp/table.tsv" | cut -f1)"
pole_wall="$(head -1 "$tmp/table.tsv" | cut -f2)"

echo "median job wall: ${median}s"
echo "pole: $pole_name (${pole_wall}s)"
echo "pole-name: $pole_name"

findings=0
if [ "${median:-0}" != "0" ]; then
  awk -F'\t' -v med="$median" '
    { threshold = med * 1.5; if ($2 > threshold) printf "  %-40s %6ds  (> 1.5x median %ds)\n", $1, $2, med }
  ' "$tmp/table.tsv" > "$tmp/hot.txt"
  if [ -s "$tmp/hot.txt" ]; then
    echo
    echo "jobs over 1.5x the median:"
    cat "$tmp/hot.txt"
    findings=1
  fi
fi

if [ "$findings" = "1" ]; then
  echo "cost-status: findings"
else
  echo "cost-status: clean"
fi
exit 0
