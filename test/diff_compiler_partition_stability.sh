#!/bin/sh
# shell-because: trust-anchor — circular: checks the machinery a native gate would run inside
# diff_compiler_partition_stability.sh — pins the ThinLTO partitioning property
# that the whole PARALLEL CODEGEN scheme (#2681, #2725, #2752) rests on: a
# one-module SOURCE edit changes only that module's own partition(s), so the
# ThinLTO cache serves every other partition unchanged (#2780).
#
# TEXT-ONLY: no clang, no link, no oracle. It sources pcg_partition() from
# test/lib/pcg_partition.sh — the same code test/build_native_medaka.sh runs —
# and drives it over small synthetic LLVM-IR-shaped fixtures built inline
# below, never real emitted IR. That is deliberate: the property under test is
# a property of the AWK TEXT TRANSFORM's own partitioning rule, not of any one
# compile, so a hand-built fixture that exercises the rule is strictly more
# targeted than a real .ll dump would be, and needs no build to run.
#
# Two things are checked:
#
#   1. THE STABILITY PROPERTY ITSELF, on three structurally different one-line
#      source edits, each partitioned before and after and diffed by partition
#      FILE CONTENT (never by index-name alone, so a partition that keeps its
#      number but changes its bytes still counts):
#        (a) a LEAF module (no cross-references)        -> expect 1 differing
#        (b) a MID-GRAPH module that owns a shared constant cell referenced
#            from another partition (compiler/frontend/desugar.mdk-shaped)
#            -> expect 1 differing: the referencing partition's DECLARATION
#            of the constant is just "external hidden <type>", so a change to
#            the constant's VALUE never touches it
#        (c) a TOP-LEVEL-BINDING edit — a module gains a new entity, and the
#            `program` scope's @mdk_program_main gains the matching reference,
#            exactly as the real emitter's initializer concatenation would
#            -> expect 2 differing (the module's own partition, AND program's)
#      Ratcheted on the actual differing-partition COUNT per case, never on
#      equality to one — (c) is supposed to touch two partitions by
#      construction (see the pcg_partition header comment on @mdk_program_main
#      in test/lib/pcg_partition.sh).
#
#   2. Four invariants pcg_partition's contract states but nothing had run:
#        - a fully-marked fixture partitions cleanly, every entity landing in
#          exactly the partition its marker names (no leak into a neighbor);
#        - no symbol is DEFINED in two partition files (a decl-only mention in
#          an importer is fine; a second `define`/non-external global is not);
#        - marker-less input degrades to one partition, byte-identical to the
#          input, printing "1 nomark";
#        - a corrupt top-level marker (`; mdk-module` with no scope name)
#          exits nonzero.
#
# Usage: sh test/diff_compiler_partition_stability.sh
# Exit:  0 if every case and every invariant holds, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/test/lib/pcg_partition.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0

# ---- fixtures -------------------------------------------------------------

base_ir() {
  cat <<'EOF'
; mdk-module leaf_module
define void @leaf_fn(i32 %x) {
  %y = add i32 %x, 1
  ret void
}

; mdk-module midgraph_module
@shared_const = private constant [8 x i8] c"original"
define i32 @midgraph_fn() {
  ret i32 0
}

; mdk-module consumer_module
define i32 @consumer_fn() {
  %v = load i8, i8* @shared_const
  ret i32 %v
}

; mdk-module program
define void @mdk_program_main() {
  call void @leaf_fn(i32 0)
  call i32 @midgraph_fn()
  call i32 @consumer_fn()
  ret void
}
EOF
}

# (a) leaf edit: one instruction inside leaf_module's own body.
edit_leaf_ir() { base_ir | sed 's/%y = add i32 %x, 1/%y = add i32 %x, 2/'; }

# (b) mid-graph edit: the VALUE of a shared constant cell midgraph_module owns
# and consumer_module references cross-partition. Type/signature unchanged.
edit_midgraph_ir() { base_ir | sed 's/c"original"/c"modified"/'; }

# (c) top-level-binding edit: leaf_module gains a new global, and program's
# @mdk_program_main gains the matching reference — the initializer-
# concatenation behavior the pcg_partition header describes.
edit_topbinding_ir() {
  cat <<'EOF'
; mdk-module leaf_module
define void @leaf_fn(i32 %x) {
  %y = add i32 %x, 1
  ret void
}
@leaf_flag = private constant [1 x i8] c"1"

; mdk-module midgraph_module
@shared_const = private constant [8 x i8] c"original"
define i32 @midgraph_fn() {
  ret i32 0
}

; mdk-module consumer_module
define i32 @consumer_fn() {
  %v = load i8, i8* @shared_const
  ret i32 %v
}

; mdk-module program
define void @mdk_program_main() {
  call void @leaf_fn(i32 0)
  call i32 @midgraph_fn()
  call i32 @consumer_fn()
  %f = load i8, i8* @leaf_flag
  ret void
}
EOF
}

# ---- helpers ---------------------------------------------------------------

# count_diff <dir1> <dir2> [<nparts>] -> prints the number of partition files
# (p0..p<n-1>) whose CONTENT differs between the two directories.
count_diff() {
  d1="$1"; d2="$2"; n="$3"
  i=0
  diffcount=0
  while [ "$i" -lt "$n" ]; do
    if ! cmp -s "$d1/p$i" "$d2/p$i"; then diffcount=$((diffcount + 1)); fi
    i=$((i + 1))
  done
  echo "$diffcount"
}

# nparts_of <pcg_partition stdout line, "<k> mod"/"<k> nomark"> -> k
nparts_of() { echo "${1%% *}"; }

run_case() {
  case_name="$1"; edit_fn="$2"; expect="$3"
  before="$WORK/$case_name.before.ll"
  after="$WORK/$case_name.after.ll"
  before_out="$WORK/$case_name.before.out"; mkdir -p "$before_out"
  after_out="$WORK/$case_name.after.out"; mkdir -p "$after_out"
  base_ir > "$before"
  "$edit_fn" > "$after"

  before_info="$(pcg_partition "$before" "$before_out" "" 2>"$WORK/$case_name.before.err")"
  before_rc=$?
  after_info="$(pcg_partition "$after" "$after_out" "" 2>"$WORK/$case_name.after.err")"
  after_rc=$?
  if [ "$before_rc" -ne 0 ] || [ "$after_rc" -ne 0 ]; then
    printf 'FAIL %-16s partitioning itself failed (before rc=%s, after rc=%s): %s %s\n' \
      "$case_name" "$before_rc" "$after_rc" "$(cat "$WORK/$case_name.before.err")" "$(cat "$WORK/$case_name.after.err")"
    fail=$((fail + 1))
    return
  fi

  n_before="$(nparts_of "$before_info")"
  n_after="$(nparts_of "$after_info")"
  if [ "$n_before" != "$n_after" ]; then
    printf 'FAIL %-16s partition count moved (%s -> %s), expected it fixed for this case\n' \
      "$case_name" "$n_before" "$n_after"
    fail=$((fail + 1))
    return
  fi

  diffcount="$(count_diff "$before_out" "$after_out" "$n_before")"
  if [ "$diffcount" = "$expect" ]; then
    printf 'ok   %-16s %s differing partition(s) of %s (before: %s, after: %s)\n' \
      "$case_name" "$diffcount" "$n_before" "$before_info" "$after_info"
  else
    printf 'FAIL %-16s expected %s differing partition(s), got %s (before: %s, after: %s)\n' \
      "$case_name" "$expect" "$diffcount" "$before_info" "$after_info"
    fail=$((fail + 1))
  fi
}

run_case leaf_edit       edit_leaf_ir       1
run_case midgraph_edit   edit_midgraph_ir   1
run_case topbinding_edit edit_topbinding_ir 2

# ---- invariant 1: a fully-marked fixture lands every entity in ITS OWN
# partition, none leaking into a neighbor. -----------------------------------

inv1_out="$WORK/inv1.out"; mkdir -p "$inv1_out"
inv1_info="$(base_ir > "$WORK/inv1.ll"; pcg_partition "$WORK/inv1.ll" "$inv1_out" "" 2>"$WORK/inv1.err")"
inv1_rc=$?
if [ "$inv1_rc" -ne 0 ]; then
  printf 'FAIL %-16s well-formed fixture failed to partition: %s\n' inv1_no_leak "$(cat "$WORK/inv1.err")"
  fail=$((fail + 1))
elif grep -Eq '^define [^{]*@leaf_fn\(' "$inv1_out/p1" "$inv1_out/p2" "$inv1_out/p3" 2>/dev/null \
  || grep -Eq '^define [^{]*@midgraph_fn\(' "$inv1_out/p0" "$inv1_out/p2" "$inv1_out/p3" 2>/dev/null \
  || grep -Eq '^define [^{]*@consumer_fn\(' "$inv1_out/p0" "$inv1_out/p1" "$inv1_out/p3" 2>/dev/null; then
  printf 'FAIL %-16s a definition leaked into a neighboring partition\n' inv1_no_leak
  fail=$((fail + 1))
else
  printf 'ok   %-16s every definition stayed in its own marked partition (%s)\n' inv1_no_leak "$inv1_info"
fi

# ---- invariant 2: no symbol is DEFINED (not merely declared) in two
# partitions. A "declare"/"external" line for the same symbol elsewhere is
# fine; a second real definition is not. -------------------------------------

dup=0
for sym in leaf_fn midgraph_fn consumer_fn mdk_program_main shared_const; do
  defcount=0
  for p in "$inv1_out"/p*; do
    [ -f "$p" ] || continue
    if grep -Eq "^define [^{]*@${sym}\\(|^@${sym} = (private|internal) " "$p"; then
      defcount=$((defcount + 1))
    fi
  done
  if [ "$defcount" -gt 1 ]; then
    printf 'FAIL %-16s @%s is DEFINED in %s partitions\n' inv2_no_dup_def "$sym" "$defcount"
    dup=1
  fi
done
if [ "$dup" -eq 0 ]; then
  printf 'ok   %-16s no symbol defined in more than one partition\n' inv2_no_dup_def
else
  fail=$((fail + 1))
fi

# ---- invariant 3: marker-less input degrades to one verbatim partition,
# printing "1 nomark". --------------------------------------------------------

printf 'define void @plain() {\n  ret void\n}\n' > "$WORK/inv3.ll"
inv3_out="$WORK/inv3.out"; mkdir -p "$inv3_out"
inv3_info="$(pcg_partition "$WORK/inv3.ll" "$inv3_out" "" 2>"$WORK/inv3.err")"
inv3_rc=$?
if [ "$inv3_rc" -ne 0 ] || [ "$inv3_info" != "1 nomark" ]; then
  printf 'FAIL %-16s expected "1 nomark" exit 0, got rc=%s info=(%s)\n' inv3_nomark_degrade "$inv3_rc" "$inv3_info"
  fail=$((fail + 1))
elif ! cmp -s "$WORK/inv3.ll" "$inv3_out/p0"; then
  printf 'FAIL %-16s degraded p0 is not byte-identical to the input\n' inv3_nomark_degrade
  fail=$((fail + 1))
else
  printf 'ok   %-16s marker-less input degrades to a verbatim single p0 ("%s")\n' inv3_nomark_degrade "$inv3_info"
fi

# ---- invariant 4: a corrupt top-level marker (no scope name) exits nonzero. -

printf '; mdk-module\ndefine void @plain() {\n  ret void\n}\n' > "$WORK/inv4.ll"
inv4_out="$WORK/inv4.out"; mkdir -p "$inv4_out"
pcg_partition "$WORK/inv4.ll" "$inv4_out" "" >"$WORK/inv4.out.txt" 2>"$WORK/inv4.err"
inv4_rc=$?
if [ "$inv4_rc" -eq 0 ]; then
  printf 'FAIL %-16s corrupt marker exited 0, expected nonzero\n' inv4_corrupt_marker
  fail=$((fail + 1))
elif ! grep -q 'corrupt' "$WORK/inv4.err"; then
  printf 'FAIL %-16s exited nonzero but stderr does not name it corrupt: %s\n' inv4_corrupt_marker "$(cat "$WORK/inv4.err")"
  fail=$((fail + 1))
else
  printf 'ok   %-16s corrupt top-level marker exits nonzero ("%s")\n' inv4_corrupt_marker "$(cat "$WORK/inv4.err")"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "all partition-stability cases and invariants held"
else
  echo "$fail check(s) FAILED"
fi
[ "$fail" -eq 0 ]
