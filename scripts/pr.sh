#!/bin/sh
# pr.sh — verified, non-interactive GitHub PR lifecycle helper (see AGENTS.md
# "How work lands" and docs/ops/PR-HELPER.md).
#
# Every subcommand follows the standing rule from AGENTS.md: *read the state
# back, never the return code.* `gh`'s write exit codes carry no signal here
# (#1212, #1213), so none of these subcommands trusts an exit code as success;
# each verifies the resulting state and exits nonzero when the intended change
# did not land.
#
# POSIX sh only (runs on Linux and macOS). No external deps beyond `gh`, `git`,
# and coreutils.
#
# Usage:
#   pr.sh body      --number N [--issue] --file F        [--repo OWNER/REPO]
#   pr.sh watch     --number N [--interval S] [--timeout S]
#   pr.sh enqueue   --number N [--interval S] [--timeout S]
#   pr.sh complete  --number N --sha SHA [--interval S] [--timeout S]
#
# Every subcommand accepts --repo OWNER/REPO (default: $GH_REPO, else the
# origin remote of the current git repo). Tests may override the gh binary via
# $GH (default "gh") so they can substitute a mock without touching a repo.
#
# The four operations are intentionally independent: a body edit must not
# require running the whole lifecycle.

set -u

die() {
  echo "pr.sh: $*" >&2
  exit 1
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
}

# ---------------------------------------------------------------------------
# Shared plumbing
# ---------------------------------------------------------------------------

: "${GH:=gh}"
TAB="$(printf '\t')"

# Resolve OWNER/REPO. Precedence: --repo flag, then $GH_REPO, then the origin
# remote of the current repo. Accepts "OWNER/REPO", "git@host:OWNER/REPO.git",
# and "https://host/OWNER/REPO.git".
derive_repo() {
  if [ -n "${REPO_FLAG:-}" ]; then
    REPO="$REPO_FLAG"
    return 0
  fi
  if [ -n "${GH_REPO:-}" ]; then
    REPO="$GH_REPO"
    return 0
  fi
  url="$(git config --get remote.origin.url 2>/dev/null || true)"
  case "$url" in
    *github.com:*)
      REPO="${url##*github.com:}"
      ;;
    *github.com/*)
      REPO="${url##*github.com/}"
      ;;
    *)
      die "cannot derive OWNER/REPO (no --repo, \$GH_REPO, or github origin); set --repo"
      ;;
  esac
  REPO="${REPO%.git}"
  [ -n "$REPO" ] || die "cannot derive OWNER/REPO"
}

# ---------------------------------------------------------------------------
# body — safe body write with verified readback
# ---------------------------------------------------------------------------
cmd_body() {
  num=''
  kind='pr'
  file=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --number) num="$2"; shift 2 ;;
      --issue) kind=issue; shift ;;
      --file) file="$2"; shift 2 ;;
      --repo) REPO_FLAG="$2"; shift 2 ;;
      *) die "body: unknown argument: $1" ;;
    esac
  done
  [ -n "$num" ] || die "body: --number N is required"
  [ -n "$file" ] || die "body: --file F is required"
  [ -f "$file" ] || die "body: --file F must be an existing file"
  derive_repo

  resource="pulls"; [ "$kind" = issue ] && resource="issues"

  # PATCH with -F (not -f): -F expands the leading @ as a file read; -f writes
  # the literal four characters "@file" (#1212 item 2). We deliberately do NOT
  # gate on the PATCH's exit code (#1212: gh can no-op while exiting 0, or
  # report an error after the server applied the write) — the readback below is
  # the sole signal, per "read the state back, never the return code".
  $GH api -X PATCH "repos/$REPO/$resource/$num" -F "body=@$file" >/dev/null 2>&1 || true

  # Read back and byte-compare. --template (not --jq) so the readback carries
  # no trailing newline a JSON pipe would append: byte fidelity both ways, so a
  # stored body with or without a final LF round-trips unchanged. A no-op'ing
  # write (--body-file) or a literal @file (mistakenly using -f) is caught here.
  tmp="$(mktemp "${TMPDIR:-/tmp}/pr-body.XXXXXX")"
  if ! $GH api "repos/$REPO/$resource/$num" --template '{{.body}}' >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "body: could not read back $kind $num body to verify write"
  fi
  if ! cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    die "body: $kind $num body readback does not match $file — write did not land"
  fi
  rm -f "$tmp"
  bytes="$(wc -c <"$file" | tr -d ' ')"
  echo "ok: body of $kind $num updated and verified ($bytes bytes)"
}

# ---------------------------------------------------------------------------
# enqueue — verified auto-merge request
# ---------------------------------------------------------------------------
# `gh pr merge --auto --merge`'s exit code and banner carry no signal (#1212
# item 3); autoMergeRequest reads null while queued. The only reliable signal
# is isInMergeQueue via GraphQL — but a PR can be green and merge so fast that
# isInMergeQueue is never observed true (state is already MERGED). So we accept
# either isInMergeQueue==true OR state==MERGED.
cmd_enqueue() {
  num=''
  interval=30
  timeout=900
  while [ $# -gt 0 ]; do
    case "$1" in
      --number) num="$2"; shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      --repo) REPO_FLAG="$2"; shift 2 ;;
      *) die "enqueue: unknown argument: $1" ;;
    esac
  done
  [ -n "$num" ] || die "enqueue: --number N is required"
  derive_repo

  # Request the merge; deliberately ignore the exit code and banner.
  $GH pr merge "$num" --repo "$REPO" --auto --merge >/dev/null 2>&1 || true

  owner="${REPO%%/*}"
  name="${REPO#*/}"
  # GraphQL is the only reliable signal (#1212 item 3); autoMergeRequest reads
  # null while queued. Query order {isInMergeQueue state} matches the server's
  # field order, so both sed extracts below work on a single raw object.
  q=""
  q="{repository(owner:\"$owner\",name:\"$name\"){pullRequest(number:$num){isInMergeQueue state}}}"

  elapsed=0
  state=
  while [ "$elapsed" -lt "$timeout" ]; do
    raw=$($GH api graphql -f "query=$q" --jq '.data.repository.pullRequest' 2>/dev/null) || raw=
    state="$(printf '%s' "$raw" | sed -n 's/.*"state": *"\([A-Z]*\)".*/\1/p')"
    inqueue="$(printf '%s' "$raw" | sed -n 's/.*"isInMergeQueue": *\([a-z]*\).*/\1/p')"
    if [ "$inqueue" = true ]; then
      echo "ok: PR $num is in the merge queue (state=$state)"
      return 0
    fi
    if [ "$state" = MERGED ]; then
      echo "ok: PR $num already MERGED (merged before queue membership was observable)"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  die "enqueue: PR $num did not join the merge queue or merge within ${timeout}s (state=$state)"
}

# ---------------------------------------------------------------------------
# watch — concise check watching
# ---------------------------------------------------------------------------
# Polls check-runs for the PR's head commit and prints ONE line per state
# transition plus a final summary, instead of the full unchanged matrix every
# poll. The exit status is derived from the checks' final conclusions, not from
# the fact that the loop ended. A stale check-run (#1213) is indistinguishable
# by name alone from a fresh one; its started_at column carries no transition,
# so a stale run stays silent unless it changes — the started_at discriminator
# is documented in docs/ops/PR-HELPER.md.
cmd_watch() {
  num=''
  interval=30
  timeout=3600
  while [ $# -gt 0 ]; do
    case "$1" in
      --number) num="$2"; shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      --repo) REPO_FLAG="$2"; shift 2 ;;
      *) die "watch: unknown argument: $1" ;;
    esac
  done
  [ -n "$num" ] || die "watch: --number N is required"
  derive_repo

  head=$($GH pr view "$num" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null) \
    || die "watch: cannot resolve head commit for PR $num"
  head="$(printf '%s' "$head" | tr -d '"')"
  [ -n "$head" ] || die "watch: empty headRefOid for PR $num"

  prevdir="$(mktemp -d "${TMPDIR:-/tmp}/pr-watch.XXXXXX")"
  prev="$prevdir/prev"
  : >"$prev"

  elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    # Per check-run: NAME<TAB>STATUS<TAB>CONCLUSION(, empty while running).
    # per_page=100 so a PR with more than the default 30 check-runs still has
    # every run counted — an omitted running/failing check must not read as done.
    cur="$prevdir/cur"
    $GH api "repos/$REPO/commits/$head/check-runs?per_page=100" \
      --jq '.check_runs[] | [.name, .status, (.conclusion // "")] | @tsv' >"$cur" 2>/dev/null

    running=0
    : >"$prevdir/head"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      name="$(printf '%s' "$line" | cut -f1)"
      status="$(printf '%s' "$line" | cut -f2)"
      conclusion="$(printf '%s' "$line" | cut -f3)"

      # Only `completed` is terminal. queued/in_progress/waiting/requested/
      # pending all mean "still going" — a check in any other state must keep
      # us polling, or a not-yet-completed run would be read as success.
      if [ "$status" != completed ]; then
        running=1
      fi

      # Exact first-field match against the previous snapshot (awk, not grep
      # substring): `bar` must never match a stored `foo-bar` row.
      prevline="$(awk -F "$TAB" -v n="$name" '$1 == n { print; exit }' "$prev" 2>/dev/null || true)"
      prevstatus="$(printf '%s' "$prevline" | cut -f2)"
      prevconcl="$(printf '%s' "$prevline" | cut -f3)"

      if [ "$prevstatus" != "$status" ] || [ "$prevconcl" != "$conclusion" ]; then
        if [ "$status" = completed ]; then
          case "$conclusion" in
            success|neutral|skipped) printf 'check %s: completed (%s)\n' "$name" "$conclusion" ;;
            *) printf 'check %s: FAILED (%s)\n' "$name" "$conclusion" >&2 ;;
          esac
        else
          printf 'check %s: %s\n' "$name" "$status"
        fi
      fi
      printf '%s%s%s%s%s\n' "$name" "$TAB" "$status" "$TAB" "$conclusion" >>"$prevdir/head"
    done <"$cur"
    mv "$prevdir/head" "$prev"

    n="$(wc -l <"$cur" | tr -d ' ')"
    # Final status is derived from the checks, not from the loop ending. We
    # only declare "done" once at least one check-run exists: an empty set
    # means the runs may not have registered yet, so keep polling.
    if [ "$running" -eq 0 ] && [ "$n" -gt 0 ]; then
      bad="$(cut -f3 "$cur" | grep -E '^(failure|cancelled|timed_out|action_required|stale)$' || true)"
      if [ -n "$bad" ]; then
        echo "watch: $n checks done, at least one FAILED/CANCELLED" >&2
        rm -rf "$prevdir"
        exit 1
      fi
      echo "watch: all $n checks done, all succeeded"
      rm -rf "$prevdir"
      exit 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  rm -rf "$prevdir"
  die "watch: checks still running after ${timeout}s"
}

# ---------------------------------------------------------------------------
# complete — verified completion (head SHA is an ancestor of origin/main)
# ---------------------------------------------------------------------------
# Proves the intended head commit actually reached main after the PR closes,
# covering the push-after-enqueue race (#1213): a commit pushed to an enqueued
# PR's branch can be merged as-it-stood and the later push left behind.
cmd_complete() {
  num=''
  sha=''
  interval=30
  timeout=3600
  while [ $# -gt 0 ]; do
    case "$1" in
      --number) num="$2"; shift 2 ;;
      --sha) sha="$2"; shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      --repo) REPO_FLAG="$2"; shift 2 ;;
      *) die "complete: unknown argument: $1" ;;
    esac
  done
  [ -n "$num" ] || die "complete: --number N is required"
  [ -n "$sha" ] || die "complete: --sha SHA is required"
  derive_repo

  # Wait for the PR to reach MERGED.
  elapsed=0
  state=
  while [ "$elapsed" -lt "$timeout" ]; do
    state=$($GH pr view "$num" --repo "$REPO" --json state --jq .state 2>/dev/null) || state=
    state="$(printf '%s' "$state" | tr -d '"')"
    [ "$state" = MERGED ] && break
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  [ "$state" = MERGED ] || die "complete: PR $num did not reach MERGED within ${timeout}s"

  # Verify against the ACTUAL repo's main, not this checkout's origin: the
  # helper may run in a checkout whose origin is a different repo than $REPO,
  # and verifying a foreign origin would certify the wrong thing. Fetch $REPO's
  # main into a throwaway ref and require the fetch to succeed — a failed fetch
  # is loud, never a silent success.
  repo_url=$($GH repo view "$REPO" --json url --jq .url 2>/dev/null | tr -d '"' || true)
  [ -n "$repo_url" ] || die "complete: cannot resolve a clone URL for $REPO to verify main"
  check_ref="refs/pr-helper/main-$$"
  if ! git fetch -q "$repo_url" main:"$check_ref" 2>/dev/null; then
    die "complete: could not fetch $REPO main to verify — refusing to report success"
  fi
  trap 'git update-ref -d "$check_ref" 2>/dev/null || true' 0 1 2 3 15
  if git merge-base --is-ancestor "$sha" "$check_ref" 2>/dev/null; then
    echo "ok: $sha is an ancestor of $REPO main — the PR landed your intended head"
    exit 0
  fi
  # Distinguish "merged something else" from "sha never fetched": report the
  # actual merge commit so the caller can see what did land.
  merged_sha=$($GH pr view "$num" --repo "$REPO" --json mergeCommit --jq '.mergeCommit.oid' 2>/dev/null | tr -d '"' || true)
  die "complete: $sha is NOT an ancestor of $REPO main (merged_sha=${merged_sha:-unknown}) — push-after-enqueue race: the branch head the queue merged may differ from $sha"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  body|watch|enqueue|complete) "cmd_$cmd" "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
