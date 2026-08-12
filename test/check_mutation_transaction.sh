#!/bin/sh
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

fail() { echo "FAIL mutation transaction helper: $*" >&2; exit 1; }
clean() {
  [ "$(hash_file "$SOURCE")" = "$BASE_HASH" ] || fail "source hash not restored"
  [ -z "$(git -C "$REPO" status --porcelain)" ] || fail "source not restored"
}

MUTATE='python3 -c '\''import os, pathlib; p=pathlib.Path(os.environ["MUTATION_SOURCE"]); p.write_text(p.read_text().replace("# Medaka OpenCode Workflows", "# MUTANT OpenCode Workflows", 1))'\'''
CHECK='grep -q "^# MUTANT OpenCode Workflows$" source.txt && { echo TXN-EXPECTED-RED; exit 17; }'

"$HELPER" --source "$SOURCE" --mutate "$MUTATE" --check "$CHECK" \
  --expect '^TXN-EXPECTED-RED$' --label focused >"$WORK/focused.out" 2>"$WORK/focused.err" || fail "focused transaction"
grep -F 'MUTATION-RED label=focused check_status=17 evidence=TXN-EXPECTED-RED' "$WORK/focused.out" >/dev/null || fail "focused red receipt"
grep -F 'MUTATION-RESTORED path=source.txt sha256=' "$WORK/focused.out" >/dev/null || fail "focused restoration receipt"
clean

if "$HELPER" --source "$SOURCE" --mutate "$MUTATE" --check 'echo WRONG-RED; exit 19' \
  --expect '^RIGHT-RED$' --label mismatch >"$WORK/mismatch.out" 2>"$WORK/mismatch.err"; then
  fail "mismatched expected-red accepted"
fi
grep -F 'expected-red pattern not found' "$WORK/mismatch.err" >/dev/null || fail "mismatch diagnostic"
clean

"$HELPER" --source "$SOURCE" --mutate "$MUTATE" \
  --check "touch '$WORK/check.started'; sleep 5; exit 23" --expect '^NEVER$' --label signal \
  >"$WORK/signal.out" 2>"$WORK/signal.err" &
pid=$!
i=0
while [ "$i" -lt 100 ] && [ ! -f "$WORK/check.started" ]; do
  sleep 0.05
  i=$((i + 1))
done
[ "$i" -lt 100 ] || { kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "signal setup did not reach check"; }
kill -TERM "$pid" || fail "could not signal helper"
set +e
wait "$pid"
signal_status=$?
set -e
[ "$signal_status" -eq 143 ] || fail "TERM status was $signal_status, expected 143"
clean

echo "PASS: mutation transaction helper restores on expected red, mismatch, and TERM"
