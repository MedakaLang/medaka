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
#       Compare two INTENDED path lists (one repo-relative path per line) for
#       slices not yet cut: direct intersection + predicted golden/snapshot
#       artifacts + shared fixture-directory warning.
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
#     eval goldens), single-line registry chokepoints inside a shared file the
#     lists omit, and semantic collisions with no textual overlap (two green
#     branches have merged into a crashing tree here). The merge queue plus the
#     serialized-arming rule remain the backstop for those.

set -u

die() { echo "sprint-disjoint: $1" >&2; exit 2; }

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
  grep -e '^test/.*_fixtures/' -e '^test/wasm/fixtures' "$1" 2>/dev/null \
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

mode=${1:-}; shift 2>/dev/null || true
case "$mode" in
  lists)
    [ $# -eq 2 ] || die "usage: sprint-disjoint.sh lists <fileA> <fileB>"
    [ -f "$1" ] && [ -f "$2" ] || die "list file missing"
    report_pair "$1" "$2"; rc=$?
    ;;
  branches)
    [ $# -eq 2 ] || die "usage: sprint-disjoint.sh branches <refA> <refB>"
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
      echo "CONFLICTS:"; echo "$OUT"; rc=1
    fi
    rm -rf "$T"
    ;;
  *)
    die "usage: sprint-disjoint.sh branches <refA> <refB> | lists <fileA> <fileB>"
    ;;
esac

if [ "$rc" -eq 0 ]; then
  echo "== VERDICT: no collision detected (within stated scope — see header) =="
else
  echo "== VERDICT: COLLISION EVIDENCE ABOVE — not disjoint =="
fi
exit $rc
