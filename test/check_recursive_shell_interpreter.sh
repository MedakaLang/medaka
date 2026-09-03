#!/bin/sh
# shell-because: external-harness — subject is a shell/python/browser harness or live gh state; wrap gains nothing
# Reject Bash scripts that recursively invoke themselves through `sh`. The
# child then parses Bash syntax as POSIX sh, often failing far from the launcher
# and wasting a full verification turn. Pure text analysis; Linux + macOS.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="test/check_recursive_shell_interpreter.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/recursive-shell.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

scan_one() {
  file="$1"
  first=''
  IFS= read -r first <"$file" || true
  case "$first" in
    '#!'*bash*) ;;
    *) return 0 ;;
  esac

  # Ignore full-line comments. Match the common quoted and unquoted recursive
  # forms; `exec sh "$0"` is included because the match is not line-anchored.
  awk '
    /^[[:space:]]*#/ { next }
    $0 ~ /(^|[ \t;|&()])sh[ \t]+"\$0"/ ||
    $0 ~ /(^|[ \t;|&()])sh[ \t]+\$0([ \t]|$)/ {
      print FNR ":" $0
    }
  ' "$file"
}

# Fail-capable controls: prove the scanner rejects the hazardous form but does
# not ban a Bash-preserving self-invocation or a genuinely POSIX-sh script.
cat >"$WORK/bad.sh" <<'EOF'
#!/usr/bin/env bash
exec sh "$0" --worker
EOF
cat >"$WORK/good-bash.sh" <<'EOF'
#!/usr/bin/env bash
exec bash "$0" --worker
EOF
cat >"$WORK/good-sh.sh" <<'EOF'
#!/bin/sh
exec sh "$0" --worker
EOF
[ -n "$(scan_one "$WORK/bad.sh")" ] || {
  echo "FAIL: recursive-shell guard's positive control did not trigger" >&2
  exit 1
}
[ -z "$(scan_one "$WORK/good-bash.sh")" ] || {
  echo "FAIL: recursive-shell guard rejected Bash-preserving recursion" >&2
  exit 1
}
[ -z "$(scan_one "$WORK/good-sh.sh")" ] || {
  echo "FAIL: recursive-shell guard rejected a POSIX-sh script" >&2
  exit 1
}

findings="$WORK/findings"
: >"$findings"
git -C "$ROOT" ls-files '*.sh' >"$WORK/files"
while IFS= read -r rel; do
  [ "$rel" = "$SELF" ] && continue
  hits="$(scan_one "$ROOT/$rel")"
  [ -z "$hits" ] || printf '%s\n%s\n' "$rel" "$hits" >>"$findings"
done <"$WORK/files"

if [ -s "$findings" ]; then
  echo "FAIL: Bash scripts must not recursively invoke themselves through sh:" >&2
  cat "$findings" >&2
  echo "Use bash \"\$0\", or better, refactor the worker into a non-recursive function." >&2
  exit 1
fi

echo "recursive-shell-interpreter: ok"
