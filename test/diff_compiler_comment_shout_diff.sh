#!/bin/sh
# SHOUT DIFF CHECK (CI twin, #2621; widened #3032).
#
# `.githooks/pre-commit` check 6 rejects a commit that ADDS a new shout
# line to a staged .mdk. That is the fast feedback, and it is also
# bypassable: `git commit --no-verify` skips every hook, and a hook is not
# installed at all in a fresh clone. This gate makes the same assertion
# where it cannot be skipped -- over the PR's whole diff against its
# merge-base, on every PR -- so a new shout cannot reach main by routing
# around the hook.
#
# WHAT IT PROVES: no ADDED line (a line the diff shows as `+`, excluding the
# `+++` file-header line) in a .mdk file outside test/ introduces 🚨/⚠️/🔒,
# nor the sigil-free shout register (census class 10: 3+ consecutive
# ALL-CAPS words) on a comment-scope line. Comment scope is both of
# Medaka's comment forms -- a `--` line comment and the interior of a
# nestable `{- ... -}` block -- as
# `test/comment_register_census.sh --comment-scope` classifies them, over
# the post-image of the file; a shout written into a block comment is the
# evasion the `^[ \t]*--` test alone let through. Membership is by exact
# line text rather than by line number, which is enough at this check's
# precision and far less code than correlating diff hunks. The sigil check
# is not comment-scoped -- a sigil is rare enough outside comments that
# this was never an issue for it; the sigil-free regex IS scoped, because
# it also matches ALL-CAPS code and string literals (CLI help, error text)
# and would false-positive on those unscoped. An existing shout line that
# is merely touched (context around an edit) but textually unchanged does
# not trigger -- only genuinely new shout text does.
#
# WHAT IT DOES NOT PROVE: that the existing census figures
# (test/comment_register_census.sh) are right, wrong, or moving -- this gate
# drains nothing; it only stops the count from growing further. `.md`
# files are out of scope entirely (this only ever looks at `.mdk`).
#
# SECOND ASSERTION (#3034): the comment-register count
# baseline ratchet, tree-wide, over test/comment_register_baseline.toml --
# the CI twin of .githooks/pre-commit check 6b (per staged file). Unlike the
# diff check above, this is not scoped to the PR's added lines -- it reads
# the CURRENT count for every (file, class) in the tree and compares against
# the pinned baseline, so it catches a moved/duplicated existing line the
# diff check would miss, and it does not depend on anything the hook wrote
# (so `--no-verify` cannot smuggle a rise past it either). Runs FIRST and
# unconditionally, ahead of the diff check's own early-exit (no .mdk in the
# diff is not the same as no tree-wide violation).
#
# Same include/exclude pattern the hook derives its file set with (staged
# .mdk, test/** excluded, diff-filter ACM) -- re-derived independently here
# rather than shared code, so `--no-verify` cannot bypass this by skipping
# the hook: the CI arm does not read anything the hook computed.
#
# re_emoji/re_shout must stay byte-identical to the same-named literals in
# .githooks/pre-commit and test/comment_register_census.sh. Rather than
# sharing code (which would reintroduce the coupling the paragraph above
# avoids), this script asserts the three copies agree, on every run, by
# comparing the literal `name='...'` source lines textually.
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
re_shout='([A-Z][A-Z]+[,.:;)]? ){2,}[A-Z][A-Z]+'

# Emits the comment-scope subset of the `+`-prefixed diff lines on stdin,
# with the `+` stripped. $1 is the rev-spec of the file's post-image
# (`<rev>:<path>`), whose comment scope the census script classifies. A `--`
# line comment is matched directly, so a failure to read the post-image
# degrades to the pre-widening behavior rather than to no check at all.
# Output may repeat a line; callers dedupe.
scoped_added_lines() {
  sal_added="$(sed 's/^+//')"
  sal_scope="$(mktemp)"
  git show "$1" 2>/dev/null |
    sh "$ROOT/test/comment_register_census.sh" --comment-scope - >"$sal_scope" 2>/dev/null
  printf '%s\n' "$sal_added" | grep -E '^[ \t]*--'
  printf '%s\n' "$sal_added" | grep -Fxf "$sal_scope"
  rm -f "$sal_scope"
}

this_re_emoji="re_emoji='$re_emoji'"
this_re_shout="re_shout='$re_shout'"
for pair in "$ROOT/.githooks/pre-commit" "$ROOT/test/comment_register_census.sh"; do
  other_re_emoji="$(grep -m1 "^re_emoji=" "$pair")"
  other_re_shout="$(grep -m1 "^re_shout=" "$pair")"
  if [ "$other_re_emoji" != "$this_re_emoji" ]; then
    echo "FAIL: re_emoji diverges between $pair ($other_re_emoji) and this script ($this_re_emoji)"
    exit 1
  fi
  if [ "$other_re_shout" != "$this_re_shout" ]; then
    echo "FAIL: re_shout diverges between $pair ($other_re_shout) and this script ($this_re_shout)"
    exit 1
  fi
done

HEAD="${2:-HEAD}"
BASE="${1:-}"
if [ -z "$BASE" ]; then
  # actions/checkout@v4's default shallow checkout fetches depth=1 of only the
  # triggering ref -- origin/main is unresolvable, AND HEAD itself has no
  # parent history for merge-base to walk, without both of these. Without
  # them the gate phantom-skips (exit 2, misread as "oracle not built") on
  # every real CI run, never actually enforcing anything (found at
  # S-gate-cost-discharge time, #2621).
  git rev-parse --verify --quiet origin/main >/dev/null 2>&1 ||
    git fetch --quiet --depth=50 origin refs/heads/main:refs/remotes/origin/main 2>/dev/null
  # Resolve locally: the remote's HEAD names main, not the CI merge commit.
  # Fetch its history at an absolute depth so a shallow merge tip is included.
  git merge-base origin/main "$HEAD" >/dev/null 2>&1 ||
    git fetch --quiet --depth=50 origin "$(git rev-parse "$HEAD")" 2>/dev/null
  BASE="$(git merge-base origin/main "$HEAD" 2>/dev/null)"
  [ -n "$BASE" ] || BASE="$(git merge-base main "$HEAD" 2>/dev/null)"
fi
[ -n "$BASE" ] || { echo "FAIL: could not determine a merge-base with main -- pass <base> explicitly"; exit 2; }

# ── second assertion: comment-register baseline ratchet, tree-wide ─────────
# Runs FIRST and unconditionally -- it is not diff-scoped like the first
# assertion below, so it must not sit behind that assertion's early-exit
# when the diff between $BASE and $HEAD happens to touch no .mdk file (e.g.
# this gate run alone, with no other .mdk change in the PR).
baseline_out="$(sh "$ROOT/test/comment_register_census.sh" --check "$ROOT/test/comment_register_baseline.toml")"
baseline_status=$?
if [ "$baseline_status" -ne 0 ]; then
  echo ""
  echo "FAIL: comment-register baseline ratchet violated:"
  echo ""
  printf '%s\n' "$baseline_out" | sed 's/^/  /'
  exit 1
fi
echo "-- comment register baseline: ok"

files="$(git diff --name-only --diff-filter=ACM "$BASE" "$HEAD" -- '*.mdk' ':(exclude)test/**')"
if [ -z "$files" ]; then
  echo "-- comment shout diff: ok (no staged .mdk outside test/, $BASE..$HEAD)"
  exit 0
fi

bad=""
for f in $files; do
  added="$(git diff -U0 "$BASE" "$HEAD" -- "$f" | grep '^+' | grep -v '^+++')"
  [ -z "$added" ] && continue
  sigil_hit="$(printf '%s\n' "$added" | grep -E "$re_emoji")"
  comment_added="$(printf '%s\n' "$added" | scoped_added_lines "$HEAD:$f" | sed '/^$/d' | sort -u)"
  shout_hit=""
  [ -n "$comment_added" ] && shout_hit="$(printf '%s\n' "$comment_added" | grep -E "$re_shout")"
  if [ -n "$sigil_hit" ] || [ -n "$shout_hit" ]; then
    bad="$bad $f"
    echo ""
    echo "  $f:"
    [ -n "$sigil_hit" ] && printf '%s\n' "$sigil_hit" | sed 's/^/      /'
    [ -n "$shout_hit" ] && printf '%s\n' "$shout_hit" | sed 's/^/      /'
  fi
done

if [ -n "$bad" ]; then
  echo ""
  echo "FAIL: new shout comment line(s) added (🚨/⚠️/🔒 or sigil-free ALL-CAPS) in:$bad"
  echo "  See AGENTS.md [T-COMMENT-REGISTER] -- no new shout comments."
  exit 1
fi

echo "-- comment shout diff: ok ($BASE..$HEAD)"
exit 0
