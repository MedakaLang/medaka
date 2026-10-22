#!/bin/sh
# shell-because: external-harness — subject is a shell/python/browser harness or live gh state; wrap gains nothing
# pr_helper_test.sh — exercises scripts/pr.sh by mocking `gh` (never touches a
# real repository) plus one local throwaway git repo for the `complete` command.
# POSIX sh, runs on Linux and macOS.
#
# Run:  sh test/pr_helper_test.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PR="$ROOT/scripts/pr.sh"
MOCK="$ROOT/test/fixtures/pr_mock_gh.sh"

[ -f "$PR" ] || { echo "FAIL: $PR missing" >&2; exit 1; }
[ -f "$MOCK" ] || { echo "FAIL: $MOCK missing" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pr-helper-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# run <name> <expect_exit> <args...>
run_expect() {
  name="$1"; expect="$2"; shift 2
  set +e
  out="$("$PR" "$@" 2>"$WORK/err")"
  rc=$?
  set -e
  if [ "$rc" -eq "$expect" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $name — expected exit $expect, got $rc" >&2
    echo "  stdout: $out" >&2
    echo "  stderr: $(cat "$WORK/err")" >&2
  fi
}

# run_contains <name> <expect_exit> <needle> <args...>
run_contains() {
  name="$1"; expect="$2"; needle="$3"; shift 3
  set +e
  out="$("$PR" "$@" 2>"$WORK/err")"
  rc=$?
  err="$(cat "$WORK/err")"
  both="$out
$err"
  set -e
  if [ "$rc" -eq "$expect" ] && printf '%s' "$both" | grep -qF "$needle"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $name — rc=$rc (want $expect); missing needle '$needle'" >&2
    echo "  stdout: $out" >&2
    echo "  stderr: $err" >&2
  fi
}

export GH="$MOCK"
export GH_REPO="MedakaLang/medaka"
export MOCK_LOG="$WORK/mock.log"
: >"$MOCK_LOG"

# ---------------------------------------------------------------------------
# body
# ---------------------------------------------------------------------------

# Body with backticks, $(), quotes, leading @, blank lines, non-ASCII: must
# round-trip byte-identical.
cat >"$WORK/body.md" <<'EOF'
# Title

A `tick` and a $(sub) and "quotes" and 'single' and a trailing @.

non-ASCII: café — 日本語 — 🐟

@leading-at

last line
EOF

MOCK_READBACK_FILE="$WORK/body.md" run_expect "body round-trip ok" 0 \
  body --number 7 --file "$WORK/body.md" --repo MedakaLang/medaka

# The write must have used -F ... body=@file (file expansion), never -f.
if grep -q ' -F body=@' "$MOCK_LOG"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: body did not use -F body=@file (file expansion)" >&2
fi
if grep -q ' -f body=@' "$MOCK_LOG"; then
  fail=$((fail + 1)); echo "FAIL: body used -f (would write literal @file)" >&2
else
  pass=$((pass + 1))
fi

# Mismatched readback -> nonzero, names the operation.
MOCK_READBACK="something else entirely" run_contains \
  "body readback mismatch fails" 1 "does not match" \
  body --number 7 --file "$WORK/body.md" --repo MedakaLang/medaka

# A body WITHOUT a trailing newline must round-trip byte-identical (the
# --template readback must not inject or swallow a final LF).
printf 'no trailing newline' >"$WORK/body-nolf.md"
MOCK_READBACK_FILE="$WORK/body-nolf.md" run_contains \
  "body no-trailing-LF round-trip ok" 0 "updated and verified" \
  body --number 7 --file "$WORK/body-nolf.md" --repo MedakaLang/medaka
# ...and a body with MULTIPLE trailing newlines round-trips too.
printf 'two trailing\n\n\n' >"$WORK/body-multilf.md"
MOCK_READBACK_FILE="$WORK/body-multilf.md" run_contains \
  "body multi-trailing-LF round-trip ok" 0 "updated and verified" \
  body --number 7 --file "$WORK/body-multilf.md" --repo MedakaLang/medaka

# The PATCH exit code is deliberately NOT trusted: a PATCH that exits nonzero
# but whose readback matches must report success (the write did land), and a
# PATCH that exits 0 with a mismatched readback must fail (covered by the
# "readback mismatch" test above). Read the state back, never the return code.
MOCK_PATCH_FAIL=yes MOCK_READBACK_FILE="$WORK/body.md" run_contains \
  "body ignores meaningless PATCH exit code when readback matches" 0 "updated and verified" \
  body --number 7 --file "$WORK/body.md" --repo MedakaLang/medaka

# Issue variant targets the issues/ resource, not pulls/.
: >"$MOCK_LOG"
MOCK_READBACK_FILE="$WORK/body.md" run_expect "body issue ok" 0 \
  body --number 13 --issue --file "$WORK/body.md" --repo MedakaLang/medaka
if grep -q 'issues/13' "$MOCK_LOG"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: body issue did not target issues/13" >&2
fi
if grep -q 'pulls/13' "$MOCK_LOG"; then
  fail=$((fail + 1)); echo "FAIL: body issue wrongly targeted pulls/13" >&2
else
  pass=$((pass + 1))
fi

# A closing keyword in prose warns (#583) but still writes; a dedicated
# closing line, a bulleted one, and an issue body do not warn.
cat >"$WORK/body-kw.md" <<'EOF'
Fixes #12
- Closes: MedakaLang/medaka#13

This does not fix #508 yet; the prefix #9 and suffix #9 are not keywords.
Resolves #4, and also closes #77.
EOF
MOCK_READBACK_FILE="$WORK/body-kw.md" run_contains \
  "body warns on prose closing keyword" 0 "line 4:" \
  body --number 7 --file "$WORK/body-kw.md" --repo MedakaLang/medaka
if grep -qF 'line 5:' "$WORK/err"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: body missed a second keyword on a closing line" >&2
fi
for n in 'line 1:' 'line 2:'; do
  if grep -qF "$n" "$WORK/err"; then
    fail=$((fail + 1)); echo "FAIL: body warned on dedicated closing line ($n)" >&2
  else
    pass=$((pass + 1))
  fi
done
MOCK_READBACK_FILE="$WORK/body-kw.md" run_expect "body issue does not warn" 0 \
  body --number 13 --issue --file "$WORK/body-kw.md" --repo MedakaLang/medaka
if grep -q 'closing keyword' "$WORK/err"; then
  fail=$((fail + 1)); echo "FAIL: body --issue warned about closing keywords" >&2
else
  pass=$((pass + 1))
fi
MOCK_READBACK_FILE="$WORK/body.md" run_expect "body without keywords" 0 \
  body --number 7 --file "$WORK/body.md" --repo MedakaLang/medaka
if grep -q 'closing keyword' "$WORK/err"; then
  fail=$((fail + 1)); echo "FAIL: body warned with no closing keyword present" >&2
else
  pass=$((pass + 1))
fi

# ---------------------------------------------------------------------------
# enqueue
# ---------------------------------------------------------------------------

# Queued -> ok.
MOCK_GRAPHQL='{"isInMergeQueue":true,"state":"OPEN"}' run_contains \
  "enqueue queued ok" 0 "is in the merge queue" \
  enqueue --number 7 --interval 1 --timeout 2 --repo MedakaLang/medaka

# Merged before observable -> ok (race handling).
MOCK_GRAPHQL='{"isInMergeQueue":false,"state":"MERGED"}' run_contains \
  "enqueue already merged ok" 0 "already MERGED" \
  enqueue --number 7 --interval 1 --timeout 2 --repo MedakaLang/medaka

# Never queued nor merged -> nonzero after timeout.
MOCK_GRAPHQL='{"isInMergeQueue":false,"state":"OPEN"}' run_contains \
  "enqueue never queued fails" 1 "did not join the merge queue" \
  enqueue --number 7 --interval 1 --timeout 2 --repo MedakaLang/medaka

# GraphQL query must carry isInMergeQueue and state (command construction).
: >"$MOCK_LOG"
MOCK_GRAPHQL='{"isInMergeQueue":true,"state":"OPEN"}' run_expect \
  "enqueue constructs graphql" 0 \
  enqueue --number 9 --interval 1 --timeout 2 --repo MedakaLang/medaka
if grep -qF 'isInMergeQueue state' "$MOCK_LOG"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: enqueue GraphQL query missing isInMergeQueue/state" >&2
fi
# The auto-merge request itself must have been issued (command construction).
if grep -q 'pr merge 9 --repo MedakaLang/medaka --auto --merge' "$MOCK_LOG"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: enqueue did not issue gh pr merge --auto --merge" >&2
fi

# ---------------------------------------------------------------------------
# watch
# ---------------------------------------------------------------------------

# The waiter's mock serves one post-jq snapshot per poll from $MOCK_SNAPS
# (snapshots separated by `--`). PR_SH_SLEEP=0 makes each poll instant while
# --interval 1 still counts polls toward --timeout and the grace windows.
export PR_SH_SLEEP=0
W="--interval 1 --timeout 30 --repo MedakaLang/medaka"

# prrow STATE MERGEABLE MERGESTATE HEAD INQUEUE QUEUESTATE ARMED [DRAFT]
prrow() {
  printf 'pr\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "${8:-false}" "$2" "$3" "$4" \
    "$5" "$6" "${6:+2026-10-22T00:00:00Z}" "$7"
}
# ck NAME STATUS CONCLUSION [ISREQUIRED]
ck() { printf 'check\t%s\t%s\t%s\t%s\t555\n' "$1" "$2" "$3" "${4:-true}"; }
open_row() { prrow OPEN MERGEABLE BLOCKED h1 false '' ''; }

{ open_row; ck a COMPLETED SUCCESS; ck b COMPLETED SUCCESS; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "watch all required green" 0 "verdict: GREEN" \
  watch --number 7 --required a,b $W

# First fail wins: a required check that already failed is reported while
# another is still running.
{ open_row; ck a COMPLETED FAILURE; ck b IN_PROGRESS ''; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "watch reports first required failure" 1 "required check failed: a (failure)" \
  watch --number 7 --required a,b $W

# A required check with no check-run yet (a `needs:` job) blocks GREEN even
# when everything visible is green; transitions print once each.
{ open_row; ck a COMPLETED SUCCESS; echo --
  open_row; ck a COMPLETED SUCCESS; ck c QUEUED ''; echo --
  open_row; ck a COMPLETED SUCCESS; ck c COMPLETED SUCCESS; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "watch waits for a not-yet-created required check" 0 "all 2 required checks passed" \
  watch --number 7 --required a,c $W
for needle in "check c: queued" "check c: success"; do
  if printf '%s' "$out" | grep -qF "$needle"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: watch transitions missing '$needle'" >&2
  fi
done
if [ "$(printf '%s\n' "$out" | grep -c '^check a:')" -eq 1 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: watch reprinted an unchanged check" >&2
fi

# A conflict that appears mid-run ends the wait even though checks still run.
{ open_row; ck a IN_PROGRESS ''; echo --
  prrow OPEN CONFLICTING DIRTY h1 false '' ''; ck a IN_PROGRESS ''; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "watch reports a mid-run conflict" 2 "verdict: CONFLICT" \
  watch --number 7 --required a $W

# One CONFLICTING read alone is GitHub's stale mergeable cache, not a verdict.
{ prrow OPEN CONFLICTING DIRTY h1 false '' ''; ck a IN_PROGRESS ''; echo --
  open_row; ck a COMPLETED SUCCESS; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "watch ignores a single CONFLICTING read" 0 "verdict: GREEN" \
  watch --number 7 --required a $W

{ open_row; ck a IN_PROGRESS ''; echo --
  prrow OPEN MERGEABLE BLOCKED h2 false '' ''; ck a QUEUED ''; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "watch reports a moved head" 4 "head is now h2" \
  watch --number 7 --required a $W

{ open_row; ck a COMPLETED CANCELLED; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "watch reads cancelled as infra, with a rerun hint" 1 "gh run rerun 555" \
  watch --number 7 --required a $W

# A failed non-required check is reported but does not block GREEN.
{ open_row; ck a COMPLETED SUCCESS; ck adv COMPLETED FAILURE false; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "watch notes but does not fail on a non-required check" 0 "non-required check adv failed" \
  watch --number 7 --required a $W

{ open_row; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "watch reports a PR that never gets checks" 6 "no checks registered" \
  watch --number 7 --required a --no-checks-grace 2 $W

{ open_row; ck a IN_PROGRESS ''; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "watch times out without claiming success" 7 "verdict: TIMEOUT" \
  watch --number 7 --required a --interval 1 --timeout 2 --repo MedakaLang/medaka

{ prrow CLOSED MERGEABLE BLOCKED h1 false '' ''; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "watch reports a closed PR" 5 "verdict: CLOSED" \
  watch --number 7 --required a $W

rm -f "$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "watch gives up after repeated failed reads" 9 "verdict: ERROR" \
  watch --number 7 --required a $W

# Without --required the set comes from the active rulesets.
{ open_row; ck a COMPLETED SUCCESS false; ck b COMPLETED SUCCESS false; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" MOCK_RULESET_IDS=1 MOCK_REQUIRED=a,b run_contains \
  "watch reads the required set from rulesets" 0 "2 required checks" watch --number 7 $W
# ...and with no readable ruleset, from each check's isRequired flag, which
# alone may not certify GREEN while GitHub still reads BLOCKED.
{ open_row; ck a COMPLETED SUCCESS; echo --
  prrow OPEN MERGEABLE CLEAN h1 false '' ''; ck a COMPLETED SUCCESS; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "watch isRequired fallback waits for CLEAN" 0 "mergeState=CLEAN" \
  watch --number 7 $W

# ---------------------------------------------------------------------------
# receipt
# ---------------------------------------------------------------------------

jobs="gates (types)	success	Plan this shard=success | Build medaka=success | Gate shard — types=success
gates (engines)	success	Plan this shard=success | Build medaka=skipped | Gate shard — engines=skipped"
MOCK_HEAD=deadbeef MOCK_RUN_META="deadbeef	pull_request	completed	success" MOCK_JOBS="$jobs" run_contains \
  "receipt reports exact head and skipped steps" 0 "Build medaka=skipped" \
  receipt --number 7 --run 123 --repo MedakaLang/medaka

MOCK_RUN_META="cafebabe	pull_request	completed	success" MOCK_JOBS="$jobs" run_contains \
  "receipt rejects run for another head" 1 "does not match expected head" \
  receipt --number 7 --run 123 --repo MedakaLang/medaka

MOCK_RUN_META="deadbeef	pull_request	completed	failure" MOCK_JOBS="$jobs" run_contains \
  "receipt rejects failed run after printing evidence" 1 "did not succeed" \
  receipt --sha deadbeef --run 123 --repo MedakaLang/medaka

: >"$MOCK_LOG"
MOCK_RUN_META="deadbeef	merge_group	completed	success" MOCK_JOBS="$jobs" run_expect \
  "receipt accepts explicit merge-group sha" 0 \
  receipt --sha deadbeef --run 456 --repo MedakaLang/medaka
if grep -q 'actions/runs/456/jobs?per_page=100 --paginate' "$MOCK_LOG"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: receipt did not paginate the selected run's jobs" >&2
fi

# ---------------------------------------------------------------------------
# complete
# ---------------------------------------------------------------------------

# Build a throwaway bare repo + clone so the git ancestry logic is real.
BARE="$WORK/bare.git"
CLONE="$WORK/work-repo"
{
  mkdir -p "$CLONE"
  cd "$CLONE"
  git init -q
  git config user.email t@t && git config user.name t
  git commit -q --allow-empty -m init
  git branch -M main
}
git init -q --bare "$BARE"
git -C "$BARE" symbolic-ref HEAD refs/heads/main
git -C "$CLONE" remote add origin "$BARE"
git -C "$CLONE" push -q -u origin main
C1="$(git -C "$CLONE" rev-parse HEAD)"
git clone -q "$BARE" "$WORK/complete-work"

cd "$WORK/complete-work"

# Ancestor head -> ok. MOCK_REPO_URL points the helper's authoritative fetch
# at the throwaway bare repo (not this checkout's "origin").
MOCK_STATE=MERGED MOCK_REPO_URL="$BARE" run_contains \
  "complete ok when sha on main" 0 "is an ancestor of MedakaLang/medaka main" \
  complete --number 7 --sha "$C1" --interval 1 --timeout 2 --repo MedakaLang/medaka

# Non-ancestor head -> nonzero, mentions the race / merged sha.
MOCK_STATE=MERGED MOCK_REPO_URL="$BARE" MOCK_MERGED_SHA="$C1" run_contains \
  "complete fails when sha not on main" 1 "push-after-enqueue race" \
  complete --number 7 --sha 0000000000000000000000000000000000000000 \
    --interval 1 --timeout 2 --repo MedakaLang/medaka

# Resolving a clone URL for the repo fails -> nonzero (refuse, never guess).
MOCK_STATE=MERGED MOCK_REPO_URL="" run_contains \
  "complete refuses when repo URL unresolvable" 1 "cannot resolve a clone URL" \
  complete --number 7 --sha "$C1" --interval 1 --timeout 2 --repo MedakaLang/medaka

# PR never merges -> nonzero.
MOCK_STATE=OPEN run_contains "complete times out waiting for MERGED" 1 "did not reach MERGED" \
  complete --number 7 --sha "$C1" --interval 1 --timeout 2 --repo MedakaLang/medaka

# ---------------------------------------------------------------------------
# land (runs in the throwaway clone: a MERGED verdict checks real ancestry)
# ---------------------------------------------------------------------------

q_row() { prrow OPEN MERGEABLE CLEAN "$C1" true AWAITING_CHECKS ''; }
green_row() { prrow OPEN MERGEABLE CLEAN "$C1" false '' "${1:-armed}"; }
merged_row() { prrow MERGED UNKNOWN UNKNOWN "$C1" false '' ''; }

: >"$MOCK_LOG"
{ green_row; ck a COMPLETED SUCCESS; echo --
  q_row; ck a COMPLETED SUCCESS; echo --
  merged_row; ck a COMPLETED SUCCESS; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" MOCK_REPO_URL="$BARE" run_contains "land arms, queues, merges, verifies ancestry" 0 \
  "is an ancestor of MedakaLang/medaka main" land --number 7 --required a $W
if grep -q 'pr merge 7 --repo MedakaLang/medaka --auto --merge' "$MOCK_LOG"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: land did not arm auto-merge" >&2
fi

{ prrow MERGED UNKNOWN UNKNOWN 0000000000000000000000000000000000000000 false '' ''; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" MOCK_REPO_URL="$BARE" run_contains "land reports a merged head missing from main" 8 \
  "push-after-enqueue race" land --number 7 --required a $W

# Out of the queue while OPEN, with a failed merge_group run: QUEUE_FAILED.
{ green_row; ck a COMPLETED SUCCESS; echo --
  q_row; ck a COMPLETED SUCCESS; echo --
  green_row ''; ck a COMPLETED SUCCESS; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" MOCK_QUEUE_RUN="901	completed	failure" MOCK_JOBS="gates_3=failure" run_contains \
  "land reports a failed merge-queue run" 3 "merge_group run 901 concluded failure: gates_3=failure" \
  land --number 7 --required a $W

# Out of the queue with a run still finishing: keep waiting, do not re-arm.
{ green_row; ck a COMPLETED SUCCESS; echo --
  q_row; ck a COMPLETED SUCCESS; echo --
  green_row ''; ck a COMPLETED SUCCESS; echo --
  prrow CLOSED MERGEABLE CLEAN "$C1" false '' ''; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" MOCK_QUEUE_RUN="902	in_progress	" run_contains \
  "land waits on an unfinished merge-queue run" 5 "run 902 is still in_progress" \
  land --number 7 --required a $W

# Out of the queue with no failing run: a lapse; re-arm and keep going.
: >"$MOCK_LOG"
{ green_row; ck a COMPLETED SUCCESS; echo --
  q_row; ck a COMPLETED SUCCESS; echo --
  green_row ''; ck a COMPLETED SUCCESS; echo --
  q_row; ck a COMPLETED SUCCESS; echo --
  merged_row; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" MOCK_REPO_URL="$BARE" MOCK_QUEUE_RUN="903	completed	cancelled" run_contains \
  "land re-arms after a lapse" 0 "re-arming (1/3)" land --number 7 --required a $W
if [ "$(grep -c 'pr merge 7' "$MOCK_LOG")" -eq 2 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: land did not re-arm exactly once after a lapse" >&2
fi

# Green and armed but never queued: re-arm after three idle polls, bounded.
{ green_row; ck a COMPLETED SUCCESS; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "land gives up on a PR the queue never takes" 6 \
  "never entered the queue after 3 re-arms" land --number 7 --required a $W

{ prrow OPEN MERGEABLE DRAFT "$C1" false '' '' true; ck a COMPLETED SUCCESS; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "land refuses a draft" 6 "gh pr ready 7" \
  land --number 7 --required a $W

# A red PR check ends land too, before any queue logic.
{ green_row; ck a COMPLETED FAILURE; } >"$WORK/s"
MOCK_SNAPS="$WORK/s" run_contains "land reports red PR CI" 1 "verdict: RED" \
  land --number 7 --required a $W

# ---------------------------------------------------------------------------
# .claude/hooks/pr-wait-guard.py — routes PR polls to watch/land
# ---------------------------------------------------------------------------

# guard <D|A> <tool> <command>: D = the hook must deny, A = it must allow.
GUARD="$ROOT/.claude/hooks/pr-wait-guard.py"
guard() {
  want="$1"
  got="$(python3 -c 'import json, sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"command": sys.argv[2]}}))' "$2" "$3" | python3 "$GUARD")"
  case "$got" in *'"deny"'*) got=D ;; *) got=A ;; esac
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: pr-wait-guard want $want got $got: [$2] $3" >&2
  fi
}
guard D Bash 'while true; do gh pr checks 12; sleep 30; done'
guard D Bash 'until [ "$(gh pr view 12 --json state --jq .state)" = MERGED ]; do sleep 60; done'
guard D Bash 'gh pr checks 12 --watch'
guard D Bash 'for i in $(seq 30); do gh api graphql -f query="{...isInMergeQueue...}"; sleep 20; done'
guard D Bash 'sleep 300; gh pr view 12 --json statusCheckRollup'
guard D Monitor 'gh pr view 12 --json state,statusCheckRollup'
guard A Bash 'gh pr view 12 --json state,mergeStateStatus'
guard A Bash 'for n in 1 2 3; do gh pr view $n --json state; done'
guard A Bash 'sh scripts/pr.sh watch --number 12'
guard A Bash 'while read l; do echo $l; done < f'
guard A Bash 'gh run watch 123456'
guard A Bash 'PR_WAIT_OK=1 sh -c "while true; do gh pr view 1; sleep 5; done"'
guard A Bash 'make medaka'

# ---------------------------------------------------------------------------
echo "pr_helper_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
