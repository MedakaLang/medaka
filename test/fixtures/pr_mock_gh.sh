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

# --- body: read back ---
if [ "$1" = api ] && printf '%s' "$*" | grep -q ' --jq .body'; then
  printf '%s\n' "${MOCK_READBACK:-}"
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
  printf '%s\n' "${MOCK_CHECKRUNS:-}"
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
