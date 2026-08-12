#!/bin/sh
# Run one temporary one-source mutant transaction. The mutation and check are
# caller-designed; this helper owns restoration, signals, and compact receipts.
set -u

usage() {
  echo "usage: $0 --source PATH --mutate CMD --check CMD --expect REGEX [--label NAME]" >&2
  exit 2
}

source_path= mutate_cmd= check_cmd= expect_regex= label=mutation
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) [ "$#" -ge 2 ] || usage; source_path=$2; shift 2 ;;
    --mutate) [ "$#" -ge 2 ] || usage; mutate_cmd=$2; shift 2 ;;
    --check) [ "$#" -ge 2 ] || usage; check_cmd=$2; shift 2 ;;
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
check_log=$work/check.log

restore() {
  git -C "$repo" checkout HEAD -- "$rel" >/dev/null 2>&1 || return 1
  [ "$(hash_file "$source_path")" = "$baseline_hash" ] || return 1
  [ "$(git -C "$repo" status --porcelain)" = "$baseline_status" ] || return 1
}
on_exit() {
  status=$?
  trap - EXIT HUP INT TERM
  restore || { echo "transaction $label: RESTORE FAILED for $rel" >&2; rm -rf "$work"; exit 125; }
  rm -rf "$work"
  exit "$status"
}
on_signal() {
  sig=$1
  trap - EXIT HUP INT TERM
  restore || { echo "transaction $label: RESTORE FAILED after $sig for $rel" >&2; rm -rf "$work"; exit 125; }
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

set +e
(cd "$repo" && sh -c "$check_cmd") >"$check_log" 2>&1
check_status=$?
set -e
[ "$check_status" -ne 0 ] || { echo "transaction $label: check unexpectedly passed" >&2; exit 4; }
grep -E -- "$expect_regex" "$check_log" >/dev/null || {
  echo "transaction $label: expected-red pattern not found: $expect_regex" >&2
  cat "$check_log" >&2
  exit 4
}

decisive=$(grep -E -- "$expect_regex" "$check_log" | sed -n '1p')
restore || { echo "transaction $label: RESTORE FAILED for $rel" >&2; exit 125; }
printf 'MUTATION-RED label=%s check_status=%s evidence=%s\n' "$label" "$check_status" "$decisive"
printf 'MUTATION-RESTORED path=%s sha256=%s\n' "$rel" "$baseline_hash"
