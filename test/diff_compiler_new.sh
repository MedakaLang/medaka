#!/bin/sh
# Differential gate: compiler/entries/new_main.mdk vs the `medaka new` scaffold.
#
# OCaml-free (REROOT-PLAN §2c): native host test/bin/new_main scaffolds a project
# tree in a temp dir; the reference is a committed golden tree under
# test/new_golden/myapp captured from `main.exe new myapp`
# (test/capture_goldens.sh new).  Diffs the produced tree (file list + byte content)
# vs the golden.  Cleans up on success; leaves the temp dir on failure.
set -e
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/new_main"
GOLD="$ROOT/test/new_golden/myapp"

[ -x "$RUN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$RUN") (missing $RUN)"; exit 2; }
# ⚠️ `sh test/capture_goldens.sh new` is a NO-OP for this corpus (same trap as
# #1241) — "new" is a FROZEN family (no ROWS entry, no `--frozen` tag) whose
# comment ("new: FROZEN — scaffold tree from `medaka new` depends on current
# binary. Re-capture after Phase 3 rebuild.") is a stale one-time migration
# note, not a working recipe. There is no regeneration script; hand-write by
# running `"$RUN" myapp` in a temp dir yourself, review the produced tree, then
# copy it to `$GOLD`.
[ -d "$GOLD" ] || { echo "no golden tree $GOLD — NO REGEN SCRIPT; hand-write via $RUN myapp in a temp dir and review, see comment above"; exit 2; }

pass=0; fail=0
NAME="myapp"

TMPSELF="$(mktemp -d)"
cleanup() { rm -rf "$TMPSELF"; }
trap cleanup EXIT

# Run the native compiler scaffolder in an isolated temp dir.
(cd "$TMPSELF" && "$RUN" "$NAME" > /dev/null 2>&1) \
  || { echo "FAIL: test/bin/new_main exited non-zero"; fail=$((fail+1)); }

if [ "$fail" -eq 0 ]; then
  if diff -r "$TMPSELF/$NAME" "$GOLD" > /dev/null 2>&1; then
    pass=$((pass+1))
    printf 'ok   new/%s\n' "$NAME"
  else
    fail=$((fail+1))
    printf 'FAIL new/%s (file content differs)\n' "$NAME"
    diff -r "$TMPSELF/$NAME" "$GOLD" || true
  fi
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
