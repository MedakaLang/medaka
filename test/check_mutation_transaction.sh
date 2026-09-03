#!/bin/sh
# shell-because: external-harness — subject is a shell/python/browser harness or live gh state; wrap gains nothing
# Focused behavior and interruption checks for scripts/mutation_transaction.sh.
set -u

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
HELPER=$ROOT/scripts/mutation_transaction.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutation-helper-test.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

REPO=$WORK/repo
mkdir "$REPO" || exit 1
git -C "$REPO" init -q || exit 1
SOURCE=$REPO/source.txt
printf '# Medaka OpenCode Workflows\n' > "$SOURCE"
git -C "$REPO" add source.txt && git -C "$REPO" -c user.name=test -c user.email=test@example.invalid commit -qm baseline || exit 1
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}
BASE_HASH=$(hash_file "$SOURCE")
REAL_PS=$(command -v ps)
mkdir "$WORK/bin" || exit 1
cat > "$WORK/bin/ps" <<'EOF'
#!/bin/sh
"$REAL_PS" "$@" || exit $?
# An unrelated final zombie row catches group-liveness code that mistakes the
# loop's incidental final status for a matching live process group.
case " $* " in *" -e "*) printf '999999 Z\n' ;; esac
EOF
chmod +x "$WORK/bin/ps"
export REAL_PS PATH="$WORK/bin:$PATH"

fail() { echo "FAIL mutation transaction helper: $*" >&2; exit 1; }
clean() {
  [ "$(hash_file "$SOURCE")" = "$BASE_HASH" ] || fail "source hash not restored"
  [ -z "$(git -C "$REPO" status --porcelain)" ] || fail "source not restored"
}
process_alive() {
  stat=$(ps -p "$1" -o stat= 2>/dev/null || true)
  case "$stat" in ""|Z*) return 1 ;; *) return 0 ;; esac
}

MUTATE='printf "# MUTANT OpenCode Workflows\n" > "$MUTATION_SOURCE"'
CHECK='grep -q "^# MUTANT OpenCode Workflows$" source.txt && { echo TXN-EXPECTED-RED; exit 17; }'

"$HELPER" --source "$SOURCE" --mutate "$MUTATE" --check "$CHECK" \
  --expect '^TXN-EXPECTED-RED$' --label focused >"$WORK/focused.out" 2>"$WORK/focused.err" || fail "focused transaction"
grep -F 'MUTATION-RED label=focused check_status=17 evidence=TXN-EXPECTED-RED' "$WORK/focused.out" >/dev/null || fail "focused red receipt"
grep -F 'MUTATION-RESTORED path=source.txt sha256=' "$WORK/focused.out" >/dev/null || fail "focused restoration receipt"
clean

RECEIPT=$WORK/receipt-success
"$HELPER" --source "$SOURCE" --mutate "$MUTATE" --prepare 'echo PREPARED-LOG' --check "$CHECK" \
  --expect '^TXN-EXPECTED-RED$' --label retained --receipt-dir "$RECEIPT" \
  >"$WORK/retained.out" 2>"$WORK/retained.err" || fail "retained receipt transaction"
grep -Fx "$MUTATE" "$RECEIPT/mutate.cmd" >/dev/null || fail "mutation command not retained"
grep -Fx "$CHECK" "$RECEIPT/check.cmd" >/dev/null || fail "check command not retained"
grep -F 'PREPARED-LOG' "$RECEIPT/prepare.log" >/dev/null || fail "prepare log not retained"
grep -F 'TXN-EXPECTED-RED' "$RECEIPT/check.log" >/dev/null || fail "check log not retained"
grep -F "baseline_sha256=$BASE_HASH" "$RECEIPT/metadata.txt" >/dev/null || fail "baseline hash not retained"
grep -F 'check_status=17' "$RECEIPT/metadata.txt" >/dev/null || fail "check status not retained"
grep -F 'decisive_evidence=TXN-EXPECTED-RED' "$RECEIPT/metadata.txt" >/dev/null || fail "decisive evidence not retained"
grep -F "restored_sha256=$BASE_HASH" "$RECEIPT/metadata.txt" >/dev/null || fail "restored hash not retained"
grep -F 'restoration=proved-clean' "$RECEIPT/metadata.txt" >/dev/null || fail "restoration proof not retained"
clean

UNREADABLE_RECEIPT=$WORK/receipt-list-failure
mkdir "$UNREADABLE_RECEIPT" || fail "create list-failure receipt"
printf 'OLD-EVIDENCE\n' >"$UNREADABLE_RECEIPT/metadata.txt"
mkdir "$WORK/fail-ls" || fail "create failing ls shim directory"
cat >"$WORK/fail-ls/ls" <<'EOF'
#!/bin/sh
exit 9
EOF
chmod +x "$WORK/fail-ls/ls"
if PATH="$WORK/fail-ls:$PATH" "$HELPER" --source "$SOURCE" --mutate "$MUTATE" --check "$CHECK" \
  --expect '^TXN-EXPECTED-RED$' --label list-failure --receipt-dir "$UNREADABLE_RECEIPT" \
  >"$WORK/list-failure.out" 2>"$WORK/list-failure.err"; then
  fail "failed receipt listing accepted"
fi
grep -F 'could not inspect receipt directory' "$WORK/list-failure.err" >/dev/null || fail "failed receipt listing diagnostic"
grep -Fx 'OLD-EVIDENCE' "$UNREADABLE_RECEIPT/metadata.txt" >/dev/null || fail "failed listing overwrote existing evidence"
clean

NEWLINE_RECEIPT=$WORK/receipt-newline-name
mkdir "$NEWLINE_RECEIPT" || fail "create newline-name receipt"
perl -e 'open my $fh, ">", "$ARGV[0]/\n" or die $!' "$NEWLINE_RECEIPT" || fail "create newline-only filename"
if "$HELPER" --source "$SOURCE" --mutate "$MUTATE" --check "$CHECK" \
  --expect '^TXN-EXPECTED-RED$' --label newline-name --receipt-dir "$NEWLINE_RECEIPT" \
  >"$WORK/newline-name.out" 2>"$WORK/newline-name.err"; then
  fail "newline-only receipt entry accepted"
fi
grep -F 'receipt directory exists and is not empty' "$WORK/newline-name.err" >/dev/null || fail "newline-only receipt diagnostic"
clean

BROKEN_RECEIPT=$WORK/receipt-write-failure
set +e
"$HELPER" --source "$SOURCE" --mutate "$MUTATE" \
  --prepare "rm '$BROKEN_RECEIPT/metadata.txt' && ln -s /dev/full '$BROKEN_RECEIPT/metadata.txt'" \
  --check "$CHECK" --expect '^TXN-EXPECTED-RED$' --label receipt-write-failure \
  --receipt-dir "$BROKEN_RECEIPT" >"$WORK/receipt-write-failure.out" 2>"$WORK/receipt-write-failure.err"
receipt_write_status=$?
set -e
[ "$receipt_write_status" -eq 125 ] || fail "receipt write failure status was $receipt_write_status, expected 125"
grep -F 'could not append receipt metadata' "$WORK/receipt-write-failure.err" >/dev/null || fail "receipt write failure diagnostic"
clean

if "$HELPER" --source "$SOURCE" --mutate "$MUTATE" --check "$CHECK" \
  --expect '^TXN-EXPECTED-RED$' --receipt-dir "$REPO/in-repo-receipt" \
  >"$WORK/in-repo.out" 2>"$WORK/in-repo.err"; then
  fail "in-repository receipt directory accepted"
fi
grep -F 'receipt directory must be outside repository' "$WORK/in-repo.err" >/dev/null || fail "in-repository receipt diagnostic"
[ ! -e "$REPO/in-repo-receipt" ] || fail "rejected receipt directory left behind"
clean

set +e
"$HELPER" --source "$SOURCE" --mutate "$MUTATE" --check "$CHECK" \
  --restore-check 'echo RESTORE-DETAIL; exit 9' --expect '^TXN-EXPECTED-RED$' \
  --label restore-check-failure >"$WORK/restore-failure.out" 2>"$WORK/restore-failure.err"
restore_failure_status=$?
set -e
[ "$restore_failure_status" -eq 125 ] || fail "restore-check failure status was $restore_failure_status, expected 125"
[ "$(grep -F -c 'RESTORE-DETAIL' "$WORK/restore-failure.err")" -eq 1 ] || fail "restore-check detail not replayed exactly once"
grep -F 'RESTORE CHECK FAILED' "$WORK/restore-failure.err" >/dev/null || fail "restore-check failure diagnostic"
clean

PREPARE='grep -q "^# MUTANT" "$MUTATION_SOURCE" && printf prepared > prepared.txt'
RESTORE_CHECK='grep -q "^# Medaka" "$MUTATION_SOURCE" && rm -f prepared.txt'
"$HELPER" --source "$SOURCE" --mutate "$MUTATE" --prepare "$PREPARE" --check "$CHECK" \
  --restore-check "$RESTORE_CHECK" --expect '^TXN-EXPECTED-RED$' --label prepared \
  >"$WORK/prepared.out" 2>"$WORK/prepared.err" || fail "prepared transaction"
grep -F 'MUTATION-RED label=prepared' "$WORK/prepared.out" >/dev/null || fail "prepared red receipt"
[ ! -e "$REPO/prepared.txt" ] || fail "restore check did not run"
clean

# Reproduce isolated-worktree metadata restrictions: read-only Git queries work,
# but any legacy checkout-based restoration would fail.
REAL_GIT=$(command -v git)
cat > "$WORK/bin/git" <<'EOF'
#!/bin/sh
case " $* " in
  *" checkout "*) echo "index.lock: Read-only file system" >&2; exit 128 ;;
esac
exec "$REAL_GIT" "$@"
EOF
chmod +x "$WORK/bin/git"
export REAL_GIT
"$HELPER" --source "$SOURCE" --mutate "$MUTATE" --check "$CHECK" \
  --expect '^TXN-EXPECTED-RED$' --label no-index >"$WORK/no-index.out" 2>"$WORK/no-index.err" || fail "no-index transaction"
grep -F 'MUTATION-RESTORED path=source.txt' "$WORK/no-index.out" >/dev/null || fail "no-index restoration receipt"
clean

# Prepare uses the same supervised process-group lifecycle as check. TERM must
# reap a resistant descendant and restore without waiting for prepare to finish.
"$HELPER" --source "$SOURCE" --mutate "$MUTATE" \
  --prepare "echo \$\$ > '$WORK/prepare.pid'; (trap '' TERM; touch '$WORK/prepare.started'; sleep 30; touch '$WORK/prepare-delayed.write') & leaf=\$!; echo \$leaf > '$WORK/prepare-leaf.pid'; wait" \
  --check "$CHECK" --expect '^TXN-EXPECTED-RED$' --label prepare-signal \
  >"$WORK/prepare-signal.out" 2>"$WORK/prepare-signal.err" &
prepare_helper_pid=$!
i=0
while [ "$i" -lt 100 ] && [ ! -f "$WORK/prepare.started" ]; do
  sleep 0.05
  i=$((i + 1))
done
[ "$i" -lt 100 ] || { kill -TERM "$prepare_helper_pid" 2>/dev/null || true; wait "$prepare_helper_pid" 2>/dev/null || true; fail "prepare signal setup did not start"; }
kill -TERM "$prepare_helper_pid" || fail "could not signal helper during prepare"
set +e
wait "$prepare_helper_pid"
prepare_signal_status=$?
set -e
[ "$prepare_signal_status" -eq 143 ] || fail "prepare TERM status was $prepare_signal_status, expected 143"
prepare_pid=$(cat "$WORK/prepare.pid")
process_alive "$prepare_pid" && fail "prepare process survived TERM"
prepare_leaf=$(cat "$WORK/prepare-leaf.pid")
process_alive "$prepare_leaf" && fail "prepare descendant survived TERM"
sleep 0.2
[ ! -e "$WORK/prepare-delayed.write" ] || fail "prepare wrote after restoration"
clean

"$HELPER" --source "$SOURCE" --mutate "$MUTATE" \
  --check "(trap '' TERM; sleep 30; touch '$WORK/ordinary-delayed.write') & leaf=\$!; echo \$leaf > '$WORK/ordinary-leaf.pid'; echo TXN-EXPECTED-RED; exit 17" \
  --expect '^TXN-EXPECTED-RED$' --label ordinary-child >"$WORK/ordinary.out" 2>"$WORK/ordinary.err" || fail "ordinary child transaction"
ordinary_leaf=$(cat "$WORK/ordinary-leaf.pid")
process_alive "$ordinary_leaf" && fail "ordinary-check descendant survived completion"
sleep 0.2
[ ! -e "$WORK/ordinary-delayed.write" ] || fail "ordinary-check descendant wrote after restoration"
clean

if "$HELPER" --source "$SOURCE" --mutate "$MUTATE" --check 'echo WRONG-RED; exit 19' \
  --expect '^RIGHT-RED$' --label mismatch --receipt-dir "$WORK/receipt-mismatch" >"$WORK/mismatch.out" 2>"$WORK/mismatch.err"; then
  fail "mismatched expected-red accepted"
fi
grep -F 'expected-red pattern not found' "$WORK/mismatch.err" >/dev/null || fail "mismatch diagnostic"
grep -F 'WRONG-RED' "$WORK/receipt-mismatch/check.log" >/dev/null || fail "mismatch log not retained"
grep -F 'transaction_status=4' "$WORK/receipt-mismatch/metadata.txt" >/dev/null || fail "mismatch status not retained"
grep -F 'restoration=proved-clean' "$WORK/receipt-mismatch/metadata.txt" >/dev/null || fail "mismatch restoration not retained"
clean

"$HELPER" --source "$SOURCE" --mutate "$MUTATE" \
  --check "echo \$\$ > '$WORK/check.pid'; (trap '' TERM; touch '$WORK/check.started'; sleep 30; touch '$WORK/delayed.write') & leaf=\$!; echo \$leaf > '$WORK/leaf.pid'; wait" --expect '^NEVER$' --label signal \
  >"$WORK/signal.out" 2>"$WORK/signal.err" &
pid=$!
i=0
while [ "$i" -lt 100 ] && [ ! -f "$WORK/check.started" ]; do
  sleep 0.05
  i=$((i + 1))
done
[ "$i" -lt 100 ] || { kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "signal setup did not reach check"; }
kill -TERM "$pid" || fail "could not signal helper"
signal_start=$(date +%s)
set +e
wait "$pid"
signal_status=$?
set -e
signal_elapsed=$(($(date +%s) - signal_start))
[ "$signal_status" -eq 143 ] || fail "TERM status was $signal_status, expected 143"
[ "$signal_elapsed" -lt 3 ] || fail "TERM restoration took ${signal_elapsed}s"
check_pid=$(cat "$WORK/check.pid")
process_alive "$check_pid" && fail "check process survived TERM"
leaf_pid=$(cat "$WORK/leaf.pid")
process_alive "$leaf_pid" && fail "TERM-ignoring descendant survived KILL escalation"
sleep 0.2
[ ! -e "$WORK/delayed.write" ] || fail "check wrote after TERM restoration"
clean

echo "PASS: mutation transaction helper prepares, restores without Git index writes, and reaps descendants"
