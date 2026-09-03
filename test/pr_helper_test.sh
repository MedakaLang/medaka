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

# All green single snapshot -> one line per transition + summary, exit 0.
snap="gateA	completed	success
gateB	completed	success"
MOCK_CHECKRUNS="$snap" run_contains "watch all green ok" 0 "all 2 checks done, all succeeded" \
  watch --number 7 --interval 1 --timeout 2 --repo MedakaLang/medaka

# A failure -> nonzero, names the failing check.
snap="gateA	completed	success
gateB	completed	failure"
MOCK_CHECKRUNS="$snap" run_contains "watch failure fails" 1 "gateB: FAILED" \
  watch --number 7 --interval 1 --timeout 2 --repo MedakaLang/medaka

# Genuine transitions across polls: queued -> in_progress -> completed. Each
# mock pop consumes one snapshot, so a single run exercises the multi-poll path
# and must print exactly one line per transition plus a final summary, all green.
printf 'gateA\tqueued\t\ngateA\tin_progress\t\ngateA\tcompleted\tsuccess\n' >"$WORK/q"
set +e
tout="$(MOCK_CHECKRUNS_QUEUE="$WORK/q" "$PR" watch --number 7 --interval 1 --timeout 3 --repo MedakaLang/medaka 2>&1)"
trc=$?
set -e
if [ "$trc" -eq 0 ] && printf '%s' "$tout" | grep -qF "check gateA: queued" \
   && printf '%s' "$tout" | grep -qF "check gateA: in_progress" \
   && printf '%s' "$tout" | grep -qF "check gateA: completed (success)" \
   && printf '%s' "$tout" | grep -qF "all 1 checks done, all succeeded"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: watch multi-poll transitions" >&2
  echo "  rc=$trc output:" >&2
  printf '%s\n' "$tout" | sed 's/^/    /' >&2
fi

# A non-completed pending state (e.g. "waiting") must NOT read as done: the
# helper keeps polling and finally times out (exit 1) rather than claiming
# success. Only `completed` is terminal.
MOCK_CHECKRUNS="gateA	waiting	" run_contains \
  "watch never reports success on pending (waiting) state" 1 "still running after" \
  watch --number 7 --interval 1 --timeout 2 --repo MedakaLang/medaka

# An empty check set (no runs registered yet) must not report success either.
MOCK_CHECKRUNS="" run_contains \
  "watch never reports success on empty check set" 1 "still running after" \
  watch --number 7 --interval 1 --timeout 2 --repo MedakaLang/medaka

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
echo "pr_helper_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
