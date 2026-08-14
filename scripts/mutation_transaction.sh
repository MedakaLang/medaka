#!/bin/sh
# Run one temporary one-source mutant transaction. The mutation and check are
# caller-designed; this helper owns restoration, signals, and compact receipts.
set -u

usage() {
  echo "usage: $0 --source PATH --mutate CMD --check CMD --expect REGEX [--prepare CMD] [--restore-check CMD] [--label NAME]" >&2
  exit 2
}

source_path= mutate_cmd= prepare_cmd= check_cmd= restore_check_cmd= expect_regex= label=mutation
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) [ "$#" -ge 2 ] || usage; source_path=$2; shift 2 ;;
    --mutate) [ "$#" -ge 2 ] || usage; mutate_cmd=$2; shift 2 ;;
    --prepare) [ "$#" -ge 2 ] || usage; prepare_cmd=$2; shift 2 ;;
    --check) [ "$#" -ge 2 ] || usage; check_cmd=$2; shift 2 ;;
    --restore-check) [ "$#" -ge 2 ] || usage; restore_check_cmd=$2; shift 2 ;;
    --expect) [ "$#" -ge 2 ] || usage; expect_regex=$2; shift 2 ;;
    --label) [ "$#" -ge 2 ] || usage; label=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$source_path" ] && [ -n "$mutate_cmd" ] && [ -n "$check_cmd" ] && [ -n "$expect_regex" ] || usage
[ -f "$source_path" ] || { echo "transaction $label: source not found: $source_path" >&2; exit 2; }
case "$source_path" in /*) ;; *) source_path="$PWD/$source_path" ;; esac

repo=$(git -C "$(dirname "$source_path")" rev-parse --show-toplevel) || exit 2
case "$source_path" in "$repo"/*) ;; *) echo "transaction $label: source outside repository" >&2; exit 2 ;; esac
rel=${source_path#"$repo"/}
baseline_status=$(git -C "$repo" status --porcelain)
[ -z "$baseline_status" ] || { echo "transaction $label: repository is not clean at baseline" >&2; exit 2; }

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

baseline_hash=$(hash_file "$source_path") || exit 2
work=$(mktemp -d "${TMPDIR:-/tmp}/medaka-mutation.XXXXXX") || exit 2
baseline_copy=$work/baseline
cp "$source_path" "$baseline_copy" || { rm -rf "$work"; exit 2; }
check_log=$work/check.log
prepare_log=$work/prepare.log
child_pid=
check_pgid=

group_alive() {
  process_table=$work/process-table
  ps -e -o pgid= -o stat= >"$process_table" || return 0
  while read -r pgid stat; do
    case "$stat" in Z*) continue ;; esac
    [ "$pgid" = "$check_pgid" ] && return 0
  done <"$process_table"
  return 1
}

stop_check() {
  [ -n "$check_pgid" ] || return 0
  # The check runs in a private session/process group led by child_pid. Kill the
  # group, not a racy process-tree snapshot: descendants that fork during TERM
  # remain in the group. After a short grace period, KILL any holdout before
  # restoration. A deliberately self-daemonizing check can escape any supervisor;
  # mutation commands are trusted caller-designed code in a disposable worktree.
  kill -TERM "-$check_pgid" 2>/dev/null || true
  grace=0
  while [ "$grace" -lt 20 ] && group_alive; do
    sleep 0.05
    grace=$((grace + 1))
  done
  if group_alive; then
    kill -KILL "-$check_pgid" 2>/dev/null || true
  fi
  [ -n "$child_pid" ] && wait "$child_pid" 2>/dev/null || true
  kill_grace=0
  while [ "$kill_grace" -lt 20 ] && group_alive; do
    sleep 0.05
    kill_grace=$((kill_grace + 1))
  done
  if group_alive; then
    echo "transaction $label: check process group survived termination" >&2
    return 1
  fi
  child_pid=
  check_pgid=
}

restore() {
  # Isolated worktrees may allow source writes while denying Git's shared
  # .git/worktrees/<id>/index.lock. Restoration must not need index writes.
  cp "$baseline_copy" "$source_path" || return 1
  [ "$(hash_file "$source_path")" = "$baseline_hash" ] || return 1
}
run_restore_check() {
  [ -z "$restore_check_cmd" ] && return 0
  (cd "$repo" && MUTATION_SOURCE=$source_path MUTATION_REPO=$repo MUTATION_REL=$rel sh -c "$restore_check_cmd")
}
validate_restored() {
  [ "$(hash_file "$source_path")" = "$baseline_hash" ] || return 1
  [ "$(git -C "$repo" status --porcelain)" = "$baseline_status" ] || return 1
}
on_exit() {
  status=$?
  trap - EXIT HUP INT TERM
  stop_check || { rm -rf "$work"; exit 125; }
  restore || { echo "transaction $label: RESTORE FAILED for $rel" >&2; rm -rf "$work"; exit 125; }
  run_restore_check || { echo "transaction $label: RESTORE CHECK FAILED for $rel" >&2; rm -rf "$work"; exit 125; }
  validate_restored || { echo "transaction $label: RESTORE VALIDATION FAILED for $rel" >&2; rm -rf "$work"; exit 125; }
  rm -rf "$work"
  exit "$status"
}
on_signal() {
  sig=$1
  trap - EXIT HUP INT TERM
  stop_check || { rm -rf "$work"; exit 125; }
  restore || { echo "transaction $label: RESTORE FAILED after $sig for $rel" >&2; rm -rf "$work"; exit 125; }
  run_restore_check || { echo "transaction $label: RESTORE CHECK FAILED after $sig for $rel" >&2; rm -rf "$work"; exit 125; }
  validate_restored || { echo "transaction $label: RESTORE VALIDATION FAILED after $sig for $rel" >&2; rm -rf "$work"; exit 125; }
  rm -rf "$work"
  trap - "$sig"
  kill -s "$sig" "$$"
}
trap on_exit EXIT
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

MUTATION_SOURCE=$source_path MUTATION_REPO=$repo MUTATION_REL=$rel sh -c "$mutate_cmd" || {
  echo "transaction $label: mutation command failed" >&2; exit 3;
}
after_mutation_status=$(git -C "$repo" status --porcelain)
[ "$after_mutation_status" = " M $rel" ] || {
  echo "transaction $label: mutation changed an unauthorized path or did not change $rel" >&2
  exit 3
}
[ -n "$(git -C "$repo" status --porcelain -- "$rel")" ] || {
  echo "transaction $label: mutation changed nothing" >&2; exit 3;
}

if [ -n "$prepare_cmd" ]; then
  perl -MPOSIX -e 'POSIX::setsid() >= 0 or die "setsid: $!"; exec @ARGV or die "exec: $!"' \
    sh -c "cd \"\$1\" && MUTATION_SOURCE=\"\$2\" MUTATION_REPO=\"\$1\" MUTATION_REL=\"\$3\" sh -c \"\$4\"" \
    sh "$repo" "$source_path" "$rel" "$prepare_cmd" >"$prepare_log" 2>&1 &
  child_pid=$!
  check_pgid=$child_pid
  wait "$child_pid"
  prepare_status=$?
  child_pid=
  stop_check || exit 125
  if [ "$prepare_status" -ne 0 ]; then
    echo "transaction $label: prepare command failed" >&2
    cat "$prepare_log" >&2
    exit 3
  fi
fi

# Perl/POSIX::setsid is the same portable process-control substrate used by the
# repository's macOS-safe timeout shim. exec preserves the session-leader PID.
perl -MPOSIX -e 'POSIX::setsid() >= 0 or die "setsid: $!"; exec @ARGV or die "exec: $!"' \
  sh -c "cd \"\$1\" && sh -c \"\$2\"" sh "$repo" "$check_cmd" >"$check_log" 2>&1 &
child_pid=$!
check_pgid=$child_pid
wait "$child_pid"
check_status=$?
child_pid=
stop_check || exit 125
[ "$check_status" -ne 0 ] || { echo "transaction $label: check unexpectedly passed" >&2; exit 4; }
grep -E -- "$expect_regex" "$check_log" >/dev/null || {
  echo "transaction $label: expected-red pattern not found: $expect_regex" >&2
  cat "$check_log" >&2
  exit 4
}

decisive=$(grep -E -- "$expect_regex" "$check_log" | sed -n '1p')
restore || { echo "transaction $label: RESTORE FAILED for $rel" >&2; exit 125; }
run_restore_check || { echo "transaction $label: RESTORE CHECK FAILED for $rel" >&2; exit 125; }
validate_restored || { echo "transaction $label: RESTORE VALIDATION FAILED for $rel" >&2; exit 125; }
printf 'MUTATION-RED label=%s check_status=%s evidence=%s\n' "$label" "$check_status" "$decisive"
printf 'MUTATION-RESTORED path=%s sha256=%s\n' "$rel" "$baseline_hash"
