#!/bin/sh
# sprint-disjoint.sh — mechanical disjointness evidence for running two sprint
# writers in parallel. NOT A GATE (ledgered in test/CI-COVERAGE-TOOLS.txt).
#
# The sprint rule: a second concurrent writer requires PROVEN disjointness,
# including goldens and snapshots — disjoint source files have collided on a
# single golden before. This script produces the evidence table the planner
# puts in the packet; it does not make the call (the brain signs off).
#
#   sprint-disjoint.sh branches <refA> <refB>
#       Compare two existing branches: changed-file intersection (vs merge-base),
#       predicted golden/snapshot artifacts for both sides, and a
#       `git merge-tree` dry merge for content conflicts.
#
#   sprint-disjoint.sh lists <fileA> <fileB>
#       Compare two INTENDED path lists for slices not yet cut: direct
#       intersection + predicted golden/snapshot artifacts + shared
#       fixture-directory warning. Arguments are FILES of repo-relative paths,
#       one per line.
#
#   sprint-disjoint.sh paths "<a b c>" "<d e>"
#       Same comparison from INLINE lists (whitespace/comma separated), so a
#       short candidate set costs no scratch files — two planners lost round
#       trips to "list file missing". Separate mode on purpose: a repo-relative
#       path is itself an existing file, so auto-detecting would read a source
#       file in as a path list and report a false collision.
#
# NEVER pipe this script (`| head`, `| tail`): its exit code and its usage
# `die` do not survive a pipe. Redirect to a file and read $?.
#
# EVERY run stamps `head=<sha>` (the current checkout HEAD, or the rev given to
# --head) as its FIRST output line. A disjointness result has an EXPIRY: the
# grant rule is that a stamped head differing from the sprint head at LANE GRANT
# time is INVALID and must be re-run — both stale results on record were
# collisions against lanes that had already landed. Compare the stamp; do not
# reason about whether the move mattered.
#
# Exit 0: no collision detected within this script's scope (stated below).
# Exit 1: collisions found — printed.
# Exit 2: usage / input error.
#
# SCOPE, STATED (a sweep's scope is itself an encoded fact):
#   - Detected: same-path edits; both slices moving one predicted snapshot or
#     selfproc-legA golden; merge-tree content conflicts (branches mode);
#     both slices touching one fixture directory (a shared corpus enrolls you
#     in gates you never named).
#   - NOT detected: two slices moving the same golden via UNPREDICTED gate
#     coupling (e.g. both perturbing prelude-adjacent behavior that re-cuts
#     eval goldens); snapshot moves from test-FIXTURE .mdk edits (only the
#     compiler/ snapshot corpus is predicted — same-directory fixture edits
#     are caught by the fixture-dir check, cross-corpus ones are not);
#     single-line registry chokepoints inside a shared file the lists omit;
#     and semantic collisions with no textual overlap (two green branches
#     have merged into a crashing tree here). The merge queue plus the
#     serialized-arming rule remain the backstop for those.

set -u

die() { echo "sprint-disjoint: $1" >&2; exit 2; }

# Artifact prediction tests paths relative to the repo root; a wrong cwd would
# silently predict NOTHING and report a false clean (the permissive direction).
# Anchor on the script's own location so cwd never matters.
ROOT=$(cd "$(dirname "$0")/.." && pwd) || die "cannot resolve repo root"
cd "$ROOT" || die "cannot cd to repo root $ROOT"
[ -d test/snapshots/compiler ] || die "sanity: $ROOT/test/snapshots/compiler missing — not the medaka repo root?"

# Predict golden/snapshot artifacts a changed path can move.
# compiler/<dir>/<name>.mdk -> test/snapshots/compiler/<name>.md (snapshot corpus)
#                           -> test/selfproc_goldens/legA/<dir>.<name>.golden (if it exists)
# Only artifacts that EXIST are emitted — prediction against the current tree.
predict_artifacts() {
  # $1 = file of repo-relative paths; output: predicted artifact paths, one per line
  while IFS= read -r p; do
    case "$p" in
      compiler/*/*.mdk)
        d=$(dirname "$p"); d=${d#compiler/}
        b=$(basename "$p" .mdk)
        [ -f "test/snapshots/compiler/$b.md" ] && echo "test/snapshots/compiler/$b.md"
        [ -f "test/selfproc_goldens/legA/$d.$b.golden" ] && echo "test/selfproc_goldens/legA/$d.$b.golden"
        ;;
      stdlib/*.mdk)
        # prelude-adjacent: blast radius is potentially every golden. Flag, don't enumerate.
        echo "__STDLIB_BLAST__:$p"
        ;;
    esac
  done < "$1" | sort -u
}

# Fixture directories touched (shared corpora).
fixture_dirs() {
  grep -e '^test/.*_fixtures/' -e '^test/wasm/fixtures[_/]' "$1" 2>/dev/null \
    | while IFS= read -r p; do dirname "$p"; done | sort -u
}

intersect() { # sorted-unique files $1 $2
  comm -12 "$1" "$2"
}

report_pair() { # $1 $2 = path-list files (raw); prints findings, returns 1 if any
  T=${TMPDIR:-/tmp}/sprint-disjoint.$$
  mkdir -p "$T" || die "cannot create temp dir"
  sort -u "$1" > "$T/a"; sort -u "$2" > "$T/b"
  rc=0

  echo "== direct file intersection =="
  if intersect "$T/a" "$T/b" | grep -q .; then
    intersect "$T/a" "$T/b"; rc=1
  else
    echo "(none)"
  fi

  predict_artifacts "$T/a" > "$T/pa"; predict_artifacts "$T/b" > "$T/pb"
  echo "== predicted golden/snapshot artifacts, side A =="; cat "$T/pa"
  echo "== predicted golden/snapshot artifacts, side B =="; cat "$T/pb"
  echo "== predicted artifact collisions =="
  # a side's own source edit colliding with the other side's predicted artifact
  cat "$T/a" "$T/pa" | sort -u > "$T/ax"; cat "$T/b" "$T/pb" | sort -u > "$T/bx"
  if intersect "$T/ax" "$T/bx" | grep -v '^__STDLIB_BLAST__' | grep -q .; then
    intersect "$T/ax" "$T/bx" | grep -v '^__STDLIB_BLAST__'; rc=1
  else
    echo "(none)"
  fi
  if grep -h '^__STDLIB_BLAST__' "$T/pa" "$T/pb" 2>/dev/null | grep -q .; then
    echo "== WARNING: stdlib/prelude-adjacent edit — golden blast radius unpredictable =="
    grep -h '^__STDLIB_BLAST__' "$T/pa" "$T/pb" | sed 's/^__STDLIB_BLAST__://'
    echo "(treat as NOT disjoint unless the brain rules otherwise)"; rc=1
  fi

  echo "== shared fixture directories (shared corpora enroll shared gates) =="
  fixture_dirs "$T/a" > "$T/fa"; fixture_dirs "$T/b" > "$T/fb"
  if intersect "$T/fa" "$T/fb" | grep -q .; then
    intersect "$T/fa" "$T/fb"; rc=1
  else
    echo "(none)"
  fi

  rm -rf "$T"
  return $rc
}

# --head <rev>: the ref the caller believes this result describes (default HEAD).
# Accepted before or after the mode word.
HEAD_REV=HEAD
if [ "${1:-}" = "--head" ]; then
  [ $# -ge 2 ] || die "--head needs a rev"
  HEAD_REV=$2; shift 2
fi
mode=${1:-}; shift 2>/dev/null || true
if [ "${1:-}" = "--head" ]; then
  [ $# -ge 2 ] || die "--head needs a rev"
  HEAD_REV=$2; shift 2
fi
STAMP=$(git rev-parse "$HEAD_REV" 2>/dev/null) || die "cannot resolve $HEAD_REV"
echo "head=$STAMP"

case "$mode" in
  lists)
    [ $# -eq 2 ] || die "usage: sprint-disjoint.sh [--head <rev>] lists <fileA> <fileB>"
    [ -f "$1" ] && [ -f "$2" ] || die "list file missing (inline paths? use 'paths' mode)"
    # A TRACKED file is a repo source file, not a path list: reading one in
    # yields ~200 lines of source treated as paths and a false COLLISION — the
    # permissive direction, and the exact slip `paths` mode exists to absorb.
    for l in "$1" "$2"; do
      if git ls-files --error-unmatch "$l" >/dev/null 2>&1; then
        die "'$l' is a tracked repo file, not a path list — use 'paths' mode for inline paths"
      fi
    done
    report_pair "$1" "$2"; rc=$?
    ;;
  paths)
    # Inline form: each argument is a whitespace/comma-separated path list.
    # Deliberately a SEPARATE mode rather than overloading `lists`: a
    # repo-relative path is itself an existing file, so "file if it exists"
    # would silently read a compiler source file in as a path list and report a
    # false collision — the permissive direction.
    [ $# -eq 2 ] || die "usage: sprint-disjoint.sh [--head <rev>] paths \"<a b>\" \"<c d>\""
    TL=${TMPDIR:-/tmp}/sprint-disjoint-paths.$$
    mkdir -p "$TL" || die "cannot create temp dir"
    printf '%s\n' "$1" | tr ', \t' '\n\n\n' | grep -v '^$' > "$TL/a"
    printf '%s\n' "$2" | tr ', \t' '\n\n\n' | grep -v '^$' > "$TL/b"
    { [ -s "$TL/a" ] && [ -s "$TL/b" ]; } || { rm -rf "$TL"; die "empty path list"; }
    report_pair "$TL/a" "$TL/b"; rc=$?
    rm -rf "$TL"
    ;;
  branches)
    [ $# -eq 2 ] || die "usage: sprint-disjoint.sh [--head <rev>] branches <refA> <refB>"
    A=$1; B=$2
    MB=$(git merge-base "$A" "$B") || die "no merge base for $A $B"
    T=${TMPDIR:-/tmp}/sprint-disjoint-br.$$
    mkdir -p "$T" || die "cannot create temp dir"
    git diff --name-only "$MB" "$A" > "$T/la" || die "diff failed for $A"
    git diff --name-only "$MB" "$B" > "$T/lb" || die "diff failed for $B"
    report_pair "$T/la" "$T/lb"; rc=$?
    echo "== git merge-tree dry merge =="
    if OUT=$(git merge-tree --write-tree --name-only "$A" "$B" 2>&1); then
      echo "clean auto-merge. NOTE: a clean auto-merge is NOT proof of semantic"
      echo "disjointness — goldens three-way-merge cleanly into blends, and two"
      echo "green branches have merged into a crashing tree here."
    else
      mrc=$?
      if [ "$mrc" -eq 1 ]; then
        echo "CONFLICTS:"; echo "$OUT"; rc=1
      else
        # >1 is a git ERROR (bad object, unsupported flag), not a conflict —
        # do not paste it into a packet as conflict evidence.
        echo "GIT-ERROR (merge-tree exit $mrc, not a conflict):"; echo "$OUT"; rc=1
      fi
    fi
    rm -rf "$T"
    ;;
  *)
    die "usage: sprint-disjoint.sh [--head <rev>] branches <refA> <refB> | lists <A> <B>"
    ;;
esac

if [ "$rc" -eq 0 ]; then
  echo "== VERDICT: no collision detected at head=$STAMP (within stated scope — see header) =="
else
  echo "== VERDICT: COLLISION EVIDENCE ABOVE at head=$STAMP — not disjoint =="
fi
echo "(this result EXPIRES: re-run if the sprint head has moved since $STAMP)"
exit $rc
