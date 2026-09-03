#!/bin/sh
# EMOJI-SHOUT DIFF CHECK (CI twin, #2621).
#
# `.githooks/pre-commit` check 6 rejects a commit that ADDS a new 🚨/⚠️/🔒
# line to a staged .mdk. That is the fast feedback, and it is also
# bypassable: `git commit --no-verify` skips every hook, and a hook is not
# installed at all in a fresh clone. This gate makes the same assertion
# where it cannot be skipped -- over the PR's whole diff against its
# merge-base, on every PR -- so a new shout cannot reach main by routing
# around the hook.
#
# WHAT IT PROVES: no ADDED line (a line the diff shows as `+`, excluding the
# `+++` file-header line) in a .mdk file outside test/ introduces 🚨, ⚠️, or
# 🔒. An existing shout line that is merely touched (context around an
# edit) but textually unchanged does not trigger -- only genuinely new
# shout text does.
#
# WHAT IT DOES NOT PROVE: that the existing 1,469-line census figure
# (test/comment_register_census.sh) is right, wrong, or moving -- this gate
# drains nothing; it only stops the count from growing further. `.md`
# files are out of scope entirely (this only ever looks at `.mdk`).
#
# Same include/exclude pattern the hook derives its file set with (staged
# .mdk, test/** excluded, diff-filter ACM) -- re-derived independently here
# rather than shared code, so `--no-verify` cannot bypass this by skipping
# the hook: the CI arm does not read anything the hook computed.
#
# Needs no built ./medaka -- pure git diff + grep, like the hook's check 6.
#
# Usage:  sh test/diff_compiler_comment_shout_diff.sh [<base> [<head>]]
#         base/head default to the merge-base with origin/main (falling
#         back to main) and HEAD.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

re_emoji='🚨|⚠️|🔒'

HEAD="${2:-HEAD}"
BASE="${1:-}"
if [ -z "$BASE" ]; then
  BASE="$(git merge-base origin/main "$HEAD" 2>/dev/null)"
  [ -n "$BASE" ] || BASE="$(git merge-base main "$HEAD" 2>/dev/null)"
fi
[ -n "$BASE" ] || { echo "FAIL: could not determine a merge-base with main -- pass <base> explicitly"; exit 2; }

files="$(git diff --name-only --diff-filter=ACM "$BASE" "$HEAD" -- '*.mdk' ':(exclude)test/**')"
if [ -z "$files" ]; then
  echo "-- comment shout diff: ok (no staged .mdk outside test/, $BASE..$HEAD)"
  exit 0
fi

bad=""
for f in $files; do
  hit="$(git diff -U0 "$BASE" "$HEAD" -- "$f" | grep '^+' | grep -v '^+++' | grep -E "$re_emoji")"
  if [ -n "$hit" ]; then
    bad="$bad $f"
    echo ""
    echo "  $f:"
    printf '%s\n' "$hit" | sed 's/^/      /'
  fi
done

if [ -n "$bad" ]; then
  echo ""
  echo "FAIL: new emoji-shout comment line(s) added ($re_emoji) in:$bad"
  echo "  See AGENTS.md [T-COMMENT-REGISTER] -- no new 🚨/⚠️/🔒 shout comments."
  exit 1
fi

echo "-- comment shout diff: ok ($BASE..$HEAD)"
exit 0
