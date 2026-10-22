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
#   pr.sh watch     --number N [WAIT OPTIONS]   # until CI is green on the head
#   pr.sh land      --number N [WAIT OPTIONS]   # arm auto-merge, until MERGED
#   pr.sh body      --number N [--issue] --file F        [--repo OWNER/REPO]
#   pr.sh receipt   (--number N | --sha SHA) --run ID
#   pr.sh enqueue   --number N [--interval S] [--timeout S]
#   pr.sh complete  --number N --sha SHA [--interval S] [--timeout S]
#
#   WAIT OPTIONS: [--interval S] [--timeout S] [--no-checks-grace S]
#                 [--required a,b,...]
#
# watch and land are the only supported way to wait on a PR. They exit on the
# first actionable event and print one `verdict:` line plus `next:` hints:
#   0 GREEN/MERGED  1 RED  2 CONFLICT  3 QUEUE_FAILED  4 HEAD_MOVED
#   5 CLOSED  6 STUCK  7 TIMEOUT  8 NOT_ON_MAIN  9 ERROR
#
# Every subcommand accepts --repo OWNER/REPO (default: $GH_REPO, else the
# origin remote of the current git repo). Tests may override the gh binary via
# $GH (default "gh") so they can substitute a mock without touching a repo.
#
# The operations are intentionally independent: a body edit must not require
# running the whole lifecycle.

set -u

die() {
  echo "pr.sh: $*" >&2
  exit "${DIE_CODE:-1}"
}

usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
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

# GitHub closes an issue on merge for a closing keyword followed by an issue
# reference ANYWHERE in a PR body, prose included — "this does not fix #508"
# closes #508 (#583). Advisory only: warn on every such reference whose line
# does not START with the keyword (after an optional list bullet), and write
# the body unchanged. A line that starts with one may not carry a second.
warn_prose_closing_keywords() {
  hits="$(awk '
    BEGIN { kw = "(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+" }
    {
      rest = tolower($0)
      sub("^[[:space:]]*([-*+][[:space:]]+)?" kw, "", rest)
      if (rest ~ ("(^|[^[:alnum:]_])" kw)) print "  line " NR ": " $0
    }' "$1")"
  [ -n "$hits" ] || return 0
  echo "pr.sh: warning: closing keyword inside prose — GitHub will close these issues on merge:" >&2
  printf '%s\n' "$hits" >&2
  echo "pr.sh: put each intended close on its own line (\"Fixes #N\"), or reword the rest." >&2
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
  [ "$kind" = pr ] && warn_prose_closing_keywords "$file"

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
# receipt — compact, exact-head CI evidence
# ---------------------------------------------------------------------------
# Produces one stable line for the workflow run followed by one line per job.
# Each job line includes every step's conclusion, so a green-but-skipped
# narrowed PR shard is visible without copying the verbose Actions UI matrix.
cmd_receipt() {
  num=''
  expected=''
  run=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --number) num="$2"; shift 2 ;;
      --sha) expected="$2"; shift 2 ;;
      --run) run="$2"; shift 2 ;;
      --repo) REPO_FLAG="$2"; shift 2 ;;
      *) die "receipt: unknown argument: $1" ;;
    esac
  done
  [ -n "$run" ] || die "receipt: --run ID is required"
  if [ -n "$num" ] && [ -n "$expected" ]; then
    die "receipt: pass exactly one of --number N or --sha SHA"
  fi
  if [ -n "$num" ]; then
    derive_repo
    expected=$($GH pr view "$num" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null) \
      || die "receipt: cannot resolve head commit for PR $num"
    expected="$(printf '%s' "$expected" | tr -d '"')"
  else
    [ -n "$expected" ] || die "receipt: pass exactly one of --number N or --sha SHA"
    derive_repo
  fi

  meta=$($GH api "repos/$REPO/actions/runs/$run" \
    --jq '[.head_sha, .event, .status, (.conclusion // "")] | @tsv' 2>/dev/null) \
    || die "receipt: cannot read workflow run $run"
  old_ifs=$IFS
  IFS="$TAB"
  set -- $meta
  IFS=$old_ifs
  actual="${1:-}"
  event="${2:-}"
  status="${3:-}"
  conclusion="${4:-}"
  [ -n "$actual" ] || die "receipt: workflow run $run returned no head SHA"
  [ "$actual" = "$expected" ] \
    || die "receipt: run $run head $actual does not match expected head $expected"

  jobs="$(mktemp "${TMPDIR:-/tmp}/pr-receipt.XXXXXX")"
  if ! $GH api "repos/$REPO/actions/runs/$run/jobs?per_page=100" --paginate \
    --jq '.jobs[] | [.name, (.conclusion // .status // ""), ([.steps[]? | (.name + "=" + (.conclusion // .status // ""))] | join(" | "))] | @tsv' \
    >"$jobs" 2>/dev/null; then
    rm -f "$jobs"
    die "receipt: cannot read jobs for workflow run $run"
  fi
  [ -s "$jobs" ] || { rm -f "$jobs"; die "receipt: workflow run $run returned no jobs"; }

  printf 'receipt\thead=%s\trun=%s\tevent=%s\tstatus=%s\tconclusion=%s\n' \
    "$actual" "$run" "$event" "$status" "$conclusion"
  while IFS="$TAB" read -r job job_conclusion steps; do
    printf 'job\t%s\t%s\t%s\n' "$job" "$job_conclusion" "$steps"
  done <"$jobs"
  rm -f "$jobs"

  [ "$status" = completed ] \
    || die "receipt: workflow run $run is not completed (status=$status)"
  [ "$conclusion" = success ] \
    || die "receipt: workflow run $run did not succeed (conclusion=${conclusion:-none})"
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
# watch / land — the one PR waiter
# ---------------------------------------------------------------------------
# Every poll is ONE GraphQL read of the whole PR: state, draft, mergeability,
# head, queue entry, auto-merge request, and every check on the head with its
# required flag. One read, because a predicate over two separately sampled
# fields (state vs isInMergeQueue) is satisfiable by a merge that lands between
# them and reports a phantom bounce.
#
# The loop exits on the FIRST actionable event, not when everything is
# terminal: a required check that already failed is reported while slower
# shards still run. Each verdict has its own exit code and a next step:
#
#   0 GREEN / MERGED   1 RED            2 CONFLICT      3 QUEUE_FAILED
#   4 HEAD_MOVED       5 CLOSED         6 STUCK         7 TIMEOUT
#   8 NOT_ON_MAIN      9 ERROR
#
# `watch` stops at GREEN (every required check passed on the current head).
# `land` arms auto-merge and stops at MERGED, after verifying the head is an
# ancestor of main. A PR that leaves the queue while OPEN is classified by its
# own merge_group run: a failed run is QUEUE_FAILED; a run that did not fail
# (or none) is a lapse, and auto-merge is re-armed a bounded number of times.

PR_QUERY='query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){pullRequest(number:$n){state isDraft mergeable mergeStateStatus headRefOid isInMergeQueue mergeQueueEntry{state enqueuedAt} autoMergeRequest{enabledAt} commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{__typename ... on CheckRun{name status conclusion isRequired(pullRequestNumber:$n) checkSuite{workflowRun{databaseId}}} ... on StatusContext{context state isRequired(pullRequestNumber:$n)}}}}}}}}}}'

# One `pr` row, then one `check` row per check:
#   pr    STATE DRAFT MERGEABLE MERGESTATE HEAD INQUEUE QUEUESTATE ENQUEUEDAT ARMED
#   check NAME STATUS CONCLUSION ISREQUIRED RUNID
PR_JQ='.data.repository.pullRequest as $p
| (["pr", $p.state, ($p.isDraft|tostring), ($p.mergeable // ""), ($p.mergeStateStatus // ""),
    $p.headRefOid, ($p.isInMergeQueue|tostring), ($p.mergeQueueEntry.state // ""),
    ($p.mergeQueueEntry.enqueuedAt // ""), (if $p.autoMergeRequest then "armed" else "" end)] | @tsv),
  (($p.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [])[]
   | if .__typename == "CheckRun"
     then ["check", .name, .status, (.conclusion // ""), (.isRequired|tostring),
           ((.checkSuite.workflowRun.databaseId // "")|tostring)]
     else ["check", .context,
           (if .state == "PENDING" or .state == "EXPECTED" then "PENDING" else "COMPLETED" end),
           (if .state == "PENDING" or .state == "EXPECTED" then "" else .state end),
           (.isRequired|tostring), ""]
     end | @tsv)'

short() { printf '%.9s' "$1"; }

# The required contexts of every active ruleset, one per line. Empty when they
# cannot be read; the caller then falls back to each check's isRequired flag.
# The list matters because a job gated on `needs:` has no check-run until its
# upstream finishes, so "every required check present is green" can hold
# before the gate shards even exist.
fetch_required() {
  if [ -n "$REQUIRED_FLAG" ]; then
    printf '%s\n' "$REQUIRED_FLAG" | tr ',' '\n' | sed '/^$/d'
    return 0
  fi
  ids=$($GH api "repos/$REPO/rulesets" --jq '.[] | select(.enforcement == "active") | .id' 2>/dev/null) || return 0
  for id in $ids; do
    $GH api "repos/$REPO/rulesets/$id" \
      --jq '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' 2>/dev/null
  done | sort -u
}

# Latest merge_group run for this PR created at or after $1:
#   ID STATUS CONCLUSION
latest_queue_run() {
  $GH api "repos/$REPO/actions/runs?event=merge_group&per_page=50" \
    --jq ".workflow_runs[] | select(.head_branch | startswith(\"gh-readonly-queue/\")) | select(.head_branch | contains(\"/pr-$num-\")) | select(.created_at >= \"$1\") | [.id, .status, (.conclusion // \"\")] | @tsv" \
    2>/dev/null | head -1
}

failed_jobs() {
  $GH api "repos/$REPO/actions/runs/$1/jobs?per_page=100" --paginate \
    --jq '.jobs[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral") | "\(.name)=\(.conclusion)"' \
    2>/dev/null | tr '\n' ' '
}

arm() {
  $GH pr merge "$num" --repo "$REPO" --auto --merge >/dev/null 2>&1 || true
}

verdict() {
  code="$1"; word="$2"; shift 2
  printf 'verdict: %s — PR %s @ %s: %s\n' "$word" "$num" "$(short "$head0")" "$1"
  shift
  for hint in "$@"; do printf '  next: %s\n' "$hint"; done
  rm -rf "$wdir"
  exit "$code"
}

cmd_wait() {
  mode="$1"; shift
  DIE_CODE=9
  num=''
  interval=30
  timeout=''
  nochecks=600
  max_rearm=3
  REQUIRED_FLAG=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --number) num="$2"; shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      --no-checks-grace) nochecks="$2"; shift 2 ;;
      --required) REQUIRED_FLAG="$2"; shift 2 ;;
      --repo) REPO_FLAG="$2"; shift 2 ;;
      *) die "$mode: unknown argument: $1" ;;
    esac
  done
  [ -n "$num" ] || die "$mode: --number N is required"
  if [ -z "$timeout" ]; then
    if [ "$mode" = land ]; then timeout=7200; else timeout=5400; fi
  fi
  derive_repo
  owner="${REPO%%/*}"
  name="${REPO#*/}"

  wdir="$(mktemp -d "${TMPDIR:-/tmp}/pr-wait.XXXXXX")"
  req="$wdir/required"
  fetch_required >"$req"
  if [ -s "$req" ]; then
    echo "$mode: PR $num — $(wc -l <"$req" | tr -d ' ') required checks"
  else
    : >"$req"
    echo "$mode: PR $num — required set unreadable; using each check's isRequired flag"
  fi
  : >"$wdir/prev"

  start_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  head0=''
  prev_pr=''
  conflict_polls=0
  errors=0
  elapsed=0
  nocheck_elapsed=0
  missing_elapsed=0
  seen_queued=0
  enq_at=''
  idle_green=0
  rearms=0
  armed_now=0
  waiting_run=''

  while :; do
    snap="$wdir/snap"
    if ! $GH api graphql -F "n=$num" -f "owner=$owner" -f "name=$name" -f "query=$PR_QUERY" \
         --jq "$PR_JQ" >"$snap" 2>"$wdir/gherr" || ! grep -q '^pr	' "$snap"; then
      errors=$((errors + 1))
      if [ "$errors" -ge 10 ]; then
        verdict 9 ERROR "10 consecutive failed reads: $(head -c 200 "$wdir/gherr")" \
          "check \`gh auth status\` and network, then re-run"
      fi
    else
      errors=0
      prline="$(grep '^pr	' "$snap" | head -1)"
      state="$(printf '%s' "$prline" | cut -f2)"
      draft="$(printf '%s' "$prline" | cut -f3)"
      mergeable="$(printf '%s' "$prline" | cut -f4)"
      mss="$(printf '%s' "$prline" | cut -f5)"
      head="$(printf '%s' "$prline" | cut -f6)"
      inqueue="$(printf '%s' "$prline" | cut -f7)"
      qstate="$(printf '%s' "$prline" | cut -f8)"
      qsince="$(printf '%s' "$prline" | cut -f9)"
      armed="$(printf '%s' "$prline" | cut -f10)"
      [ -n "$head0" ] || head0="$head"

      cur_pr="state=$state mergeable=$mergeable mergeState=$mss queue=${qstate:-no} auto=${armed:-off} draft=$draft"
      if [ "$cur_pr" != "$prev_pr" ]; then
        echo "pr $num: $cur_pr"
        prev_pr="$cur_pr"
      fi

      if [ "$state" = MERGED ]; then
        if [ "$mode" = watch ]; then
          verdict 0 MERGED "the PR is merged"
        fi
        if out="$(verify_on_main "$head0" 2>&1)"; then
          verdict 0 MERGED "$out"
        fi
        verdict 8 NOT_ON_MAIN "$out" \
          "the queue merged a different head; push the missing commit as a follow-up PR on origin/main"
      fi
      [ "$state" = CLOSED ] && verdict 5 CLOSED "closed without merging"
      if [ "$head" != "$head0" ]; then
        verdict 4 HEAD_MOVED "head is now $(short "$head") (a push landed)" \
          "re-run $mode; the verdict so far was for $(short "$head0")"
      fi

      if [ "$mergeable" = CONFLICTING ] || [ "$mss" = DIRTY ]; then
        conflict_polls=$((conflict_polls + 1))
      else
        conflict_polls=0
      fi
      if [ "$conflict_polls" -ge 2 ]; then
        verdict 2 CONFLICT "conflicts with main (mergeable=$mergeable, mergeState=$mss); a conflicting PR runs no CI" \
          "git fetch origin main && git merge origin/main; resolve, push, re-run $mode" \
          "GitHub's mergeable cache can lag a push; the local merge is the ground truth"
      fi

      checks="$wdir/checks"
      grep '^check	' "$snap" | cut -f2- >"$checks"

      # One line per check whose status or conclusion moved since last poll.
      awk -F "$TAB" 'FILENAME == ARGV[1] { prev[$1] = $2 FS $3; next }
        { if (prev[$1] != $2 FS $3) print $1 FS tolower($2) FS tolower($3) }' \
        "$wdir/prev" "$checks" | while IFS= read -r line; do
          cname="$(printf '%s' "$line" | cut -f1)"
          cstat="$(printf '%s' "$line" | cut -f2)"
          cconc="$(printf '%s' "$line" | cut -f3)"
          case "$cstat:$cconc" in
            completed:success|completed:neutral|completed:skipped) echo "check $cname: $cconc" ;;
            completed:*) echo "check $cname: FAILED ($cconc)" ;;
            *) echo "check $cname: $cstat" ;;
          esac
        done
      cp "$checks" "$wdir/prev"

      eval_out="$wdir/eval"
      awk -F "$TAB" -v reqfile="$req" '
        BEGIN { have = 0
          while ((getline l < reqfile) > 0) if (l != "") { want[l] = 1; have = 1 } }
        { r = have ? ($1 in want) : ($4 == "true")
          seen[$1] = 1; total++
          if (r) nreq++
          st = toupper($2); c = toupper($3)
          if (st != "COMPLETED") { if (r) pend++; else apend++; next }
          if (c == "SUCCESS" || c == "NEUTRAL" || c == "SKIPPED") next
          line = $1 FS tolower(c) FS $5
          if (r) bad = bad "fail" FS line "\n"; else adv = adv "adv" FS line "\n" }
        END { miss = ""
          if (have) for (n in want) if (!(n in seen)) miss = miss " " n
          printf "summary\t%d\t%d\t%d\t%d\t%d\t%s\n", total, nreq, pend, apend, have, miss
          printf "%s%s", bad, adv }' "$checks" >"$eval_out"
      sline="$(grep '^summary	' "$eval_out")"
      total="$(printf '%s' "$sline" | cut -f2)"
      nreq="$(printf '%s' "$sline" | cut -f3)"
      pend="$(printf '%s' "$sline" | cut -f4)"
      apend="$(printf '%s' "$sline" | cut -f5)"
      have_list="$(printf '%s' "$sline" | cut -f6)"
      missing="$(printf '%s' "$sline" | cut -f7 | sed 's/^ //')"

      if grep -q '^fail	' "$eval_out"; then
        names="$(grep '^fail	' "$eval_out" | awk -F "$TAB" '{ printf "%s%s (%s)", sep, $2, $3; sep = ", " }')"
        run="$(grep '^fail	' "$eval_out" | head -1 | cut -f4)"
        if grep '^fail	' "$eval_out" | cut -f3 | grep -qv '^cancelled$'; then
          verdict 1 RED "required check failed: $names" \
            "gh run view ${run:-<run>} --repo $REPO --log-failed | tail -80" \
            "gh issue list --label known-red  (a red gate is usually not your break)"
        fi
        verdict 1 RED "required check cancelled: $names (infra or superseded, not a code result)" \
          "wait for run ${run:-<run>} to read completed, then: gh run rerun ${run:-<run>} --repo $REPO --failed  (once)"
      fi

      green=0
      if [ "$total" -gt 0 ] && [ "$nreq" -gt 0 ] && [ "$pend" -eq 0 ] && [ -z "$missing" ]; then
        if [ "$have_list" = 1 ]; then
          green=1
        else
          case "$mss" in CLEAN|UNSTABLE|HAS_HOOKS) [ "$apend" -eq 0 ] && green=1 ;; esac
        fi
      fi

      if [ "$total" -eq 0 ]; then
        nocheck_elapsed=$((nocheck_elapsed + interval))
        if [ "$nocheck_elapsed" -gt "$nochecks" ] && [ "$seen_queued" = 0 ]; then
          verdict 6 STUCK "no checks registered after ${nochecks}s (mergeable=$mergeable, mergeState=$mss)" \
            "UNKNOWN/CONFLICTING mergeable means no CI: merge origin/main locally to confirm" \
            "otherwise read .github/workflows/ci.yml triggers for this diff"
        fi
      else
        nocheck_elapsed=0
      fi
      if [ -n "$missing" ] && [ "$pend" -eq 0 ] && [ "$apend" -eq 0 ]; then
        missing_elapsed=$((missing_elapsed + interval))
        if [ "$missing_elapsed" -gt "$nochecks" ]; then
          verdict 6 STUCK "every check finished but required checks never reported: $missing" \
            "a job upstream of them was skipped or failed; read the run's job list"
        fi
      else
        missing_elapsed=0
      fi

      grep '^adv	' "$eval_out" | while IFS= read -r line; do
        aname="$(printf '%s' "$line" | cut -f2)"
        grep -qxF "$aname" "$wdir/adv_seen" 2>/dev/null && continue
        printf '%s\n' "$aname" >>"$wdir/adv_seen"
        echo "note: non-required check $aname failed ($(printf '%s' "$line" | cut -f3)); it does not block merge"
      done

      if [ "$mode" = watch ]; then
        if [ "$green" = 1 ]; then
          adv="$(cat "$wdir/adv_seen" 2>/dev/null | tr '\n' ' ')"
          verdict 0 GREEN "all $nreq required checks passed (${total} checks)${adv:+; non-required failed: $adv}"
        fi
      else
        if [ "$draft" = true ]; then
          verdict 6 STUCK "PR is a draft; the queue will not take it" "gh pr ready $num, then re-run land"
        fi
        if [ "$armed_now" = 0 ]; then
          arm
          armed_now=1
        elif [ "$inqueue" = true ]; then
          if [ "$seen_queued" = 0 ]; then
            echo "pr $num: in the merge queue (since ${qsince:-?})"
          fi
          seen_queued=1
          enq_at="${qsince:-$start_iso}"
          idle_green=0
          waiting_run=''
        elif [ "$seen_queued" = 1 ]; then
          # Left the queue while OPEN. The run that tested it decides why.
          qrun="$(latest_queue_run "$enq_at")"
          qid="$(printf '%s' "$qrun" | cut -f1)"
          qst="$(printf '%s' "$qrun" | cut -f2)"
          qcon="$(printf '%s' "$qrun" | cut -f3)"
          if [ -n "$qid" ] && [ "$qst" != completed ]; then
            if [ "$waiting_run" != "$qid" ]; then
              echo "pr $num: out of the queue; its merge_group run $qid is still $qst"
              waiting_run="$qid"
            fi
          else
            case "$qcon" in
              failure|timed_out|startup_failure)
                verdict 3 QUEUE_FAILED "merge_group run $qid concluded $qcon: $(failed_jobs "$qid")" \
                  "the queue runs the FULL suite; PR CI ran a diff-narrowed subset" \
                  "gh run view $qid --repo $REPO --log-failed | tail -80; check gh issue list --label known-red before re-arming"
                ;;
            esac
            if [ "$rearms" -ge "$max_rearm" ]; then
              verdict 6 STUCK "dropped out of the queue $rearms times with no failing run (last: ${qid:-none} ${qcon:-})" \
                "read the queue: gh api graphql -f query='{repository(owner:\"$owner\",name:\"$name\"){mergeQueue(branch:\"main\"){entries(first:10){nodes{position state pullRequest{number}}}}}}'"
            fi
            rearms=$((rearms + 1))
            echo "pr $num: left the queue without a failing run (${qid:-no run} ${qcon:-}); re-arming ($rearms/$max_rearm)"
            arm
            seen_queued=0
            idle_green=0
            waiting_run=''
          fi
        elif [ "$green" = 1 ]; then
          # Green but not queued: armed while BLOCKED can fail to enqueue on
          # green, and an unarmed PR never will. Give the queue three polls.
          idle_green=$((idle_green + 1))
          if [ "$idle_green" -ge 3 ]; then
            if [ "$rearms" -ge "$max_rearm" ]; then
              verdict 6 STUCK "green but never entered the queue after $rearms re-arms" \
                "gh pr merge $num --auto --merge and read its message"
            fi
            rearms=$((rearms + 1))
            echo "pr $num: green but not queued (auto=${armed:-off}); re-arming ($rearms/$max_rearm)"
            arm
            idle_green=0
          fi
        fi
      fi
    fi

    if [ "$elapsed" -ge "$timeout" ]; then
      verdict 7 TIMEOUT "no verdict after ${timeout}s (${prev_pr:-no read})" "re-run $mode; nothing is lost"
    fi
    sleep "${PR_SH_SLEEP:-$interval}"
    elapsed=$((elapsed + interval))
  done
}

# Prints one line and returns 0 iff $1 is an ancestor of $REPO's main.
#
# Verify against the ACTUAL repo's main, not this checkout's origin: the
# helper may run in a checkout whose origin is a different repo than $REPO,
# and verifying a foreign origin would certify the wrong thing. Fetch $REPO's
# main into a throwaway ref and require the fetch to succeed — a failed fetch
# is loud, never a silent success.
verify_on_main() {
  repo_url=$($GH repo view "$REPO" --json url --jq .url 2>/dev/null | tr -d '"' || true)
  if [ -z "$repo_url" ]; then
    echo "cannot resolve a clone URL for $REPO to verify main"
    return 1
  fi
  check_ref="refs/pr-helper/main-$$"
  if ! git fetch -q "$repo_url" main:"$check_ref" 2>/dev/null; then
    echo "could not fetch $REPO main to verify — refusing to report success"
    return 1
  fi
  if git merge-base --is-ancestor "$1" "$check_ref" 2>/dev/null; then
    git update-ref -d "$check_ref" 2>/dev/null || true
    echo "ok: $1 is an ancestor of $REPO main — the PR landed your intended head"
    return 0
  fi
  git update-ref -d "$check_ref" 2>/dev/null || true
  # Distinguish "merged something else" from "sha never fetched": report the
  # actual merge commit so the caller can see what did land.
  merged_sha=$($GH pr view "$num" --repo "$REPO" --json mergeCommit --jq '.mergeCommit.oid' 2>/dev/null | tr -d '"' || true)
  echo "$1 is NOT an ancestor of $REPO main (merged_sha=${merged_sha:-unknown}) — push-after-enqueue race: the branch head the queue merged may differ from $1"
  return 1
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

  if out="$(verify_on_main "$sha")"; then
    echo "$out"
    exit 0
  fi
  die "complete: $out"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  body|receipt|enqueue|complete) "cmd_$cmd" "$@" ;;
  watch|land) cmd_wait "$cmd" "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
