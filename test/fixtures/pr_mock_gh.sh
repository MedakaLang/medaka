#!/bin/sh
# Mock `gh` for pr.sh tests. Replaces the real gh binary so the tests exercise
# command construction and state interpretation WITHOUT touching a real
# repository. Responses are driven entirely by env vars (see test body); every
# invocation is logged to $MOCK_LOG so tests can assert the exact argv that was
# constructed.

: "${MOCK_LOG:=/dev/null}"
echo "MOCK $*" >>"$MOCK_LOG"

# --- body: PATCH write ---
if [ "$1" = api ] && printf '%s' "$*" | grep -q -- ' -X PATCH '; then
  case "${MOCK_PATCH_FAIL:-}" in
    yes) exit 1 ;;
  esac
  exit 0
fi

# --- body: read back (--template, no added trailing newline) ---
if [ "$1" = api ] && printf '%s' "$*" | grep -q '{{.body}}'; then
  if [ -n "${MOCK_READBACK_FILE:-}" ]; then
    cat "$MOCK_READBACK_FILE"          # byte-exact, trailing newlines preserved
  else
    printf '%s' "${MOCK_READBACK:-}"
  fi
  exit 0
fi

# --- watch/land: one whole-PR snapshot per poll (already post-jq TSV) ---
# $MOCK_SNAPS is a file of snapshots separated by `--` lines; each call pops
# one, and the last one repeats. Unset or empty means a failed read.
if [ "$1" = api ] && printf '%s' "$*" | grep -q statusCheckRollup; then
  f="${MOCK_SNAPS:-}"
  [ -n "$f" ] && [ -s "$f" ] || exit 1
  if grep -q '^--$' "$f"; then
    sed '/^--$/q' "$f" | sed '/^--$/d'
    sed '1,/^--$/d' "$f" >"$f.rest"
    mv "$f.rest" "$f"
  else
    cat "$f"
  fi
  exit 0
fi

# --- watch/land: required contexts from rulesets ---
if [ "$1" = api ] && printf '%s' "$*" | grep -q 'rulesets/'; then
  [ -n "${MOCK_REQUIRED:-}" ] && printf '%s\n' "$MOCK_REQUIRED" | tr ',' '\n'
  exit 0
fi
if [ "$1" = api ] && printf '%s' "$*" | grep -q 'rulesets'; then
  [ -n "${MOCK_RULESET_IDS:-}" ] && printf '%s\n' "$MOCK_RULESET_IDS"
  exit 0
fi

# --- land: this PR's latest merge_group run (ID STATUS CONCLUSION) ---
if [ "$1" = api ] && printf '%s' "$*" | grep -q 'event=merge_group'; then
  [ -n "${MOCK_QUEUE_RUN:-}" ] && printf '%s\n' "$MOCK_QUEUE_RUN"
  exit 0
fi

# --- enqueue: GraphQL queue/state ---
if [ "$1" = api ] && printf '%s' "$*" | grep -q graphql; then
  printf '%s\n' "${MOCK_GRAPHQL:-{\"isInMergeQueue\":true,\"state\":\"OPEN\"}}"
  exit 0
fi

# --- watch: check-runs TSV (already post-jq) ---
if [ "$1" = api ] && printf '%s' "$*" | grep -q 'check-runs'; then
  # Optional per-poll queue: each call pops one snapshot from the file, so the
  # helper sees genuine state transitions across polls.
  if [ -n "${MOCK_CHECKRUNS_QUEUE:-}" ] && [ -s "$MOCK_CHECKRUNS_QUEUE" ]; then
    line="$(head -1 "$MOCK_CHECKRUNS_QUEUE")"
    rest="$(tail -n +2 "$MOCK_CHECKRUNS_QUEUE")"
    printf '%s\n' "$rest" >"$MOCK_CHECKRUNS_QUEUE"
    printf '%s\n' "$line"
    exit 0
  fi
  # Zero bytes when no snapshot given — never a spurious blank "check".
  [ -n "${MOCK_CHECKRUNS:-}" ] && printf '%s\n' "$MOCK_CHECKRUNS"
  exit 0
fi

# --- receipt: workflow metadata and jobs TSV (already post-jq) ---
if [ "$1" = api ] && printf '%s' "$*" | grep -q 'actions/runs/.*/jobs'; then
  [ -n "${MOCK_JOBS:-}" ] && printf '%s\n' "$MOCK_JOBS"
  exit 0
fi
if [ "$1" = api ] && printf '%s' "$*" | grep -q 'actions/runs/'; then
  printf '%s\n' "${MOCK_RUN_META:-deadbeef	pull_request	completed	success}"
  exit 0
fi

# --- complete: resolve clone URL for $REPO ---
if [ "$1" = repo ] && [ "$2" = view ]; then
  printf '%s' "${MOCK_REPO_URL:-}"
  exit 0
fi

# --- pr view ... state ---
if [ "$1" = pr ] && [ "$2" = view ] && printf '%s' "$*" | grep -q ' --json state '; then
  printf '%s\n' "${MOCK_STATE:-MERGED}"
  exit 0
fi

# --- pr view ... headRefOid ---
if [ "$1" = pr ] && [ "$2" = view ] && printf '%s' "$*" | grep -q headRefOid; then
  printf '%s\n' "${MOCK_HEAD:-deadbeef}"
  exit 0
fi

# --- pr view ... mergeCommit ---
if [ "$1" = pr ] && [ "$2" = view ] && printf '%s' "$*" | grep -q mergeCommit; then
  printf '%s\n' "${MOCK_MERGED_SHA:-}"
  exit 0
fi

# --- enqueue: pr merge (exit code deliberately ignored by helper) ---
if [ "$1" = pr ] && [ "$2" = merge ]; then
  exit 0
fi

echo "MOCK: unhandled invocation: $*" >&2
exit 1
