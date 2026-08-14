#!/bin/sh
# Run one temporary one-source mutant transaction. The mutation and check are
# caller-designed; this helper owns restoration, signals, and compact receipts.
set -u

usage() {
  echo "usage: $0 --source PATH --mutate CMD --check CMD --expect REGEX [--prepare CMD] [--restore-check CMD] [--label NAME] [--receipt-dir DIR]" >&2
  exit 2
}

source_path= mutate_cmd= prepare_cmd= check_cmd= restore_check_cmd= expect_regex= label=mutation receipt_dir=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) [ "$#" -ge 2 ] || usage; source_path=$2; shift 2 ;;
    --mutate) [ "$#" -ge 2 ] || usage; mutate_cmd=$2; shift 2 ;;
    --prepare) [ "$#" -ge 2 ] || usage; prepare_cmd=$2; shift 2 ;;
    --check) [ "$#" -ge 2 ] || usage; check_cmd=$2; shift 2 ;;
    --restore-check) [ "$#" -ge 2 ] || usage; restore_check_cmd=$2; shift 2 ;;
    --expect) [ "$#" -ge 2 ] || usage; expect_regex=$2; shift 2 ;;
    --label) [ "$#" -ge 2 ] || usage; label=$2; shift 2 ;;
    --receipt-dir) [ "$#" -ge 2 ] || usage; receipt_dir=$2; shift 2 ;;
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
if [ -n "$receipt_dir" ]; then
  case "$receipt_dir" in /*) ;; *) receipt_dir="$PWD/$receipt_dir" ;; esac
  receipt_created=0
  if [ -e "$receipt_dir" ]; then
    [ -d "$receipt_dir" ] || {
      echo "transaction $label: receipt directory exists and is not empty: $receipt_dir" >&2
      rm -rf "$work"
      exit 2
    }
    ls -A "$receipt_dir" >"$work/receipt-entries" || {
      echo "transaction $label: could not inspect receipt directory: $receipt_dir" >&2
      rm -rf "$work"
      exit 2
    }
    [ ! -s "$work/receipt-entries" ] || {
      echo "transaction $label: receipt directory exists and is not empty: $receipt_dir" >&2
      rm -rf "$work"
      exit 2
    }
  else
    mkdir "$receipt_dir" || { rm -rf "$work"; exit 2; }
    receipt_created=1
  fi
  receipt_dir=$(CDPATH= cd -- "$receipt_dir" && pwd -P) || { rm -rf "$work"; exit 2; }
  case "$receipt_dir" in
    "$repo"|"$repo"/*)
      echo "transaction $label: receipt directory must be outside repository: $receipt_dir" >&2
      [ "$receipt_created" -eq 0 ] || rmdir "$receipt_dir" 2>/dev/null || true
      rm -rf "$work"
      exit 2
      ;;
  esac
  prepare_log=$receipt_dir/prepare.log
  check_log=$receipt_dir/check.log
  restore_log=$receipt_dir/restore-check.log
  : >"$prepare_log" &&
  : >"$check_log" &&
  : >"$restore_log" &&
  printf '%s\n' "$mutate_cmd" >"$receipt_dir/mutate.cmd" &&
  printf '%s\n' "$prepare_cmd" >"$receipt_dir/prepare.cmd" &&
  printf '%s\n' "$check_cmd" >"$receipt_dir/check.cmd" &&
  printf '%s\n' "$restore_check_cmd" >"$receipt_dir/restore-check.cmd" &&
  {
    printf 'label=%s\n' "$label" &&
    printf 'source=%s\n' "$rel" &&
    printf 'baseline_sha256=%s\n' "$baseline_hash" &&
    printf 'expected_red=%s\n' "$expect_regex" &&
    printf 'result=running\n'
  } >"$receipt_dir/metadata.txt" || {
    echo "transaction $label: could not initialize receipt directory: $receipt_dir" >&2
    rm -rf "$work"
    exit 2
  }
else
  check_log=$work/check.log
  prepare_log=$work/prepare.log
  restore_log=$work/restore-check.log
fi
child_pid=
check_pgid=
receipt_failed=0
restore_check_reported=0

record_result() {
  [ -n "$receipt_dir" ] || return 0
  if ! printf '%s\n' "$1" >>"$receipt_dir/metadata.txt"; then
    echo "transaction $label: could not append receipt metadata" >&2
    receipt_failed=1
    return 1
  fi
}

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
  (cd "$repo" && MUTATION_SOURCE=$source_path MUTATION_REPO=$repo MUTATION_REL=$rel sh -c "$restore_check_cmd") >"$restore_log" 2>&1
  restore_check_status=$?
  if [ "$restore_check_status" -ne 0 ] && [ "$restore_check_reported" -eq 0 ]; then
    cat "$restore_log" >&2
    restore_check_reported=1
  fi
  return "$restore_check_status"
}
validate_restored() {
  [ "$(hash_file "$source_path")" = "$baseline_hash" ] || return 1
  [ "$(git -C "$repo" status --porcelain)" = "$baseline_status" ] || return 1
}
on_exit() {
  status=$?
  trap - EXIT HUP INT TERM
  record_result "transaction_status=$status" || true
  if [ "$status" -eq 0 ]; then record_result 'result=expected-red' || true; else record_result 'result=failed' || true; fi
  stop_check || { record_result 'restoration=process-group-survived'; rm -rf "$work"; exit 125; }
  restore || { echo "transaction $label: RESTORE FAILED for $rel" >&2; record_result 'restoration=copy-failed'; rm -rf "$work"; exit 125; }
  run_restore_check || { echo "transaction $label: RESTORE CHECK FAILED for $rel" >&2; record_result 'restoration=restore-check-failed'; rm -rf "$work"; exit 125; }
  validate_restored || { echo "transaction $label: RESTORE VALIDATION FAILED for $rel" >&2; record_result 'restoration=validation-failed'; rm -rf "$work"; exit 125; }
  record_result "restored_sha256=$(hash_file "$source_path")" || true
  record_result 'restoration=proved-clean' || true
  rm -rf "$work"
  [ "$receipt_failed" -eq 0 ] || exit 125
  exit "$status"
}
on_signal() {
  sig=$1
  trap - EXIT HUP INT TERM
  record_result "signal=$sig" || true
  record_result 'result=signaled' || true
  stop_check || { record_result 'restoration=process-group-survived'; rm -rf "$work"; exit 125; }
  restore || { echo "transaction $label: RESTORE FAILED after $sig for $rel" >&2; record_result 'restoration=copy-failed' || true; rm -rf "$work"; exit 125; }
  run_restore_check || { echo "transaction $label: RESTORE CHECK FAILED after $sig for $rel" >&2; record_result 'restoration=restore-check-failed' || true; rm -rf "$work"; exit 125; }
  validate_restored || { echo "transaction $label: RESTORE VALIDATION FAILED after $sig for $rel" >&2; record_result 'restoration=validation-failed' || true; rm -rf "$work"; exit 125; }
  record_result "restored_sha256=$(hash_file "$source_path")" || true
  record_result 'restoration=proved-clean' || true
  rm -rf "$work"
  [ "$receipt_failed" -eq 0 ] || exit 125
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
  record_result "prepare_status=$prepare_status" || true
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
record_result "check_status=$check_status" || true
child_pid=
stop_check || exit 125
[ "$check_status" -ne 0 ] || { echo "transaction $label: check unexpectedly passed" >&2; exit 4; }
grep -E -- "$expect_regex" "$check_log" >/dev/null || {
  echo "transaction $label: expected-red pattern not found: $expect_regex" >&2
  cat "$check_log" >&2
  exit 4
}

decisive=$(grep -E -- "$expect_regex" "$check_log" | sed -n '1p')
record_result "decisive_evidence=$decisive" || true
restore || { echo "transaction $label: RESTORE FAILED for $rel" >&2; exit 125; }
run_restore_check || { echo "transaction $label: RESTORE CHECK FAILED for $rel" >&2; exit 125; }
validate_restored || { echo "transaction $label: RESTORE VALIDATION FAILED for $rel" >&2; exit 125; }
printf 'MUTATION-RED label=%s check_status=%s evidence=%s\n' "$label" "$check_status" "$decisive"
printf 'MUTATION-RESTORED path=%s sha256=%s\n' "$rel" "$baseline_hash"
