#!/bin/sh
# sprint-resync.sh — merge origin/main into a sprint branch and re-derive every
# artifact the merge invalidates. NOT A GATE (ledgered in
# test/CI-COVERAGE-TOOLS.txt).
#
#   sprint-resync.sh <sprint-branch> [--push]
#
# The sprint rule ([W-MERGE-QUEUE]): a sprint branch is NEVER required to be
# current with main, so this runs on a trigger, not a schedule — a formatter or
# syntax change landed, a slice needs something that landed, main touched a
# shared record/table the sprint also extends, or land time / CONFLICTING.
# `sprint-orchestrator`'s per-slice loop step 2 owns that decision; this script
# only executes it once the call is made.
#
# It exists because the hand-run sequence produced three orchestrator git slips
# in the sprint record: a bare merge pushed without its blessed goldens, a
# `git checkout <stale-sha> --` over an already-verified bless (a full
# rebuild+rebless+preflight redo), and a merge into the wrong branch. Each step
# below is one of those slips, mechanized.
#
# NEVER pipe this script: its exit code does not survive a pipe. Redirect to a
# file and read $?.

set -e

die() { printf '%s\n' "sprint-resync: $*" >&2; exit 2; }

BRANCH="$1"
PUSH="$2"
[ -n "$BRANCH" ] || die "usage: sprint-resync.sh <sprint-branch> [--push]"

ROOT=$(git rev-parse --show-toplevel) || die "not in a git worktree"
cd "$ROOT"

# 1. Refuse to run anywhere but on the named branch. The wrong-branch merge was
#    a real incident; a shared .git makes it a cheap mistake to make.
CUR=$(git rev-parse --abbrev-ref HEAD)
[ "$CUR" = "$BRANCH" ] || die "on '$CUR', not '$BRANCH' — checkout the sprint branch first"

# 2. Refuse to run dirty. A resync that merges over uncommitted work loses it
#    with no diagnostic.
[ -z "$(git status --porcelain)" ] || die "working tree not clean — commit or set aside first"

git fetch origin main

BEFORE=$(git rev-parse HEAD)
if git merge-base --is-ancestor origin/main HEAD; then
  printf 'sprint-resync: already contains origin/main (%s) — nothing to do\n' \
    "$(git rev-parse --short origin/main)"
  exit 0
fi

printf 'sprint-resync: merging origin/main (%s) into %s (%s)\n' \
  "$(git rev-parse --short origin/main)" "$BRANCH" "$(git rev-parse --short HEAD)"

# 3. Merge. A conflict in a GENERATED artifact is expected and is resolved by
#    re-deriving below, never by hand ([T-LEGA-REBASE]); a conflict in source is
#    a human call, so stop and say so rather than guessing.
if ! git merge --no-edit origin/main; then
  CONFLICTED=$(git diff --name-only --diff-filter=U)
  SRC=$(printf '%s\n' "$CONFLICTED" | grep -v '^test/snapshots/' | grep -v '^test/selfproc_goldens/' || true)
  if [ -n "$SRC" ]; then
    printf 'sprint-resync: SOURCE conflict — resolve by hand, then re-run:\n%s\n' "$SRC" >&2
    exit 3
  fi
  # Generated-only: take ours as a placeholder, then re-derive from scratch.
  printf '%s\n' "$CONFLICTED" | while read -r f; do
    [ -n "$f" ] && git checkout --ours -- "$f" && git add -- "$f"
  done
  git commit --no-edit
fi

# 4. Rebuild BEFORE blessing anything. Capture has no staleness guard, so a
#    stale oracle blesses a wrong golden permanently ([G-GOLDEN-CAPTURE-UNGUARDED]).
printf 'sprint-resync: rebuilding\n'
make -C "$ROOT" medaka

# 5. Re-derive the two generated families the merge invalidates, via the gates'
#    own capture paths — never `git checkout` of an old SHA.
printf 'sprint-resync: re-deriving LEG A goldens\n'
sh test/capture_goldens.sh --frozen selfproc_legA

printf 'sprint-resync: snapshot check\n'
make -C "$ROOT" snapshot-check || printf 'sprint-resync: snapshots moved — bless per file with test/diff_compiler_snapshot_frontend.sh --bless <path>\n' >&2

# 6. Report what is owed. The bare-merge-without-goldens slip was exactly this
#    state going unnoticed, so make it loud rather than exiting 0 silently.
if [ -n "$(git status --porcelain)" ]; then
  printf '\nsprint-resync: RE-DERIVED ARTIFACTS ARE UNCOMMITTED:\n' >&2
  git status --short >&2
  printf 'sprint-resync: review, git add BY PATH, commit, then re-run with --push\n' >&2
  exit 4
fi

printf 'sprint-resync: clean at %s (was %s)\n' "$(git rev-parse --short HEAD)" "$(git rev-parse --short "$BEFORE")"

if [ "$PUSH" = "--push" ]; then
  git push origin "HEAD:refs/heads/$BRANCH"
  printf 'sprint-resync: pushed %s\n' "$BRANCH"
else
  printf 'sprint-resync: NOT pushed (pass --push)\n'
fi
