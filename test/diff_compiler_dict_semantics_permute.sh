#!/bin/sh
# DICT-SEMANTICS section 4 -- DECLARATION-ORDER PERMUTATION
# (docs/spec/DICT-SEMANTICS.md).
#
# Sections 1-3 all pin ONE declaration order per fixture and pass BY
# CONSTRUCTION for an ACCEPTANCE WIDENING -- every golden covers the order it
# was captured at. For any fixture with >=2 `impl` blocks of one interface, this
# reverses exactly those blocks and asserts that `check`'s verdict, `run`'s
# stdout and `build`'s stdout are all unchanged. It needs no ground truth (DICT
# §3: selection is never "a function of search order, declaration order, or
# resolution position"), which is what makes it the one section that can catch
# "the winner is decided by order" without knowing the right answer -- #1154's
# exact shape.
#
# The corpus, the discipline every row pins under, the KNOWN-DIVERGENCE ledger
# and the NOT-YET-COVERED punch-list are shared with the two other gates that
# read `test/dict_fixtures`, and live in `test/dict_fixtures/README.md`. Read it
# before adding, re-pinning or draining a row here -- in particular the entry
# recording that this section permutes `impl` BLOCKS and not the PREDICATE ORDER
# IN A SIGNATURE, so its green says nothing about that axis (#1177). The section
# numbering it records is the numbering this file is section 4 of.
#
# The registry entry says `migration = "native-rewrite"`: that is where this
# check is going, not something it could do today. The port needs a precedented
# native source transform that reverses the top-level blocks of a `.mdk` file,
# and no test module in this tree has one. Building that seam here rather than
# in the test library is the shape epic #2600 exists to stop, so the rewrite
# waits for the first module that needs it for its own sake.
#
# Usage:  sh test/diff_compiler_dict_semantics_permute.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/dict_fixtures"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -d "$FIXDIR" ] || { echo "missing fixture dir: $FIXDIR"; exit 2; }

# Every invocation is bounded: DICT-SEMANTICS W1/W2 are DECIDABILITY conditions,
# so a regression to a looping `super`-search or a diverging instance context
# must surface as a row FAILURE, not as a hung CI job.
bound() { perl -e 'alarm 60; exec @ARGV' "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/v4"

# ── Section 4: declaration-order permutation differential ────────────────────
# DICT §3 makes selection ORDER-FREE ("never a function of search order,
# declaration order, or resolution position"). For any fixture with >=2 `impl`
# blocks of the SAME interface, this reverses the order of exactly those
# blocks -- nothing else in the source moves -- and asserts `check`'s verdict,
# `run`'s stdout and `build`'s stdout are all unchanged. #1154 (S0 verified,
# now FIXED) is the shape this exists to catch: swapping two disjoint
# `impl Ix Int _` blocks changed a program's answer from 111 to 222 with
# `check --json` clean on both engines.
#
# ⚠️ #1154's must-fail pin (test/must_fail_fixtures/1154-no-unique-min-decl-
# order-decides/) DRAINED when the fix landed and was deleted in that same
# commit, per its own header's instruction. The shape now lives in this gate
# instead, as `s3-nary-requires-goal-vector.mdk` -- graded on its VALUE by
# Section 1 and on its ORDER-FREEDOM here. That is not the double-count the
# deleted header warned about: a must-fail row asserts the bug STILL
# REPRODUCES and cannot coexist with a row asserting it is fixed.
#
# ⚠️ CORRECTED 2026-07-31 (F-3a-ii). This paragraph used to say #1161 -- the same
# defect on the top-level `=>`-constrained-call leg
# (`useIx : Ix a Char => a -> Int`) -- "has no goal vector to thread because the
# dict slots there are shattered one per tyvar", and was therefore unpinnable
# here. BOTH HALVES WERE WRONG, and the claim was load-bearing for anyone
# scoping the fix:
#   * There IS a goal vector. It is built from the SIGNATURE at registration
#     (`Ix a Char` at `a := Int` is `[Int, Char]`); what the old code did was
#     DISCARD every constraint argument that was not a bare type variable
#     before the dict slot was recorded, not fail to have one.
#   * Recording it does NOT require unshattering the dict slots. Storing the
#     vector in a table SLOT-PARALLEL to `funConstraintsRef` (rather than inside
#     it) widens only the GOAL each slot is selected with, leaving emitted dict
#     arity untouched -- so the shape is an ordinary dict-semantics row, graded
#     on its value, not a must-fail row.
# #1161's ROUTING half is now FIXED and lives here as
# `s3-nary-sig-constraint-goal-vector.mdk` (plus its structured sibling),
# graded on value by Section 1, on arity-neutrality by Section 3 and on
# order-freedom here. Its OBLIGATION half -- an unsatisfiable `Ix a Bool =>`
# accepted at exit 0, and the context dropped from the displayed scheme -- is a
# different channel (`declaredSchemeOblsFor` -> `declaredOblOne` ->
# `constraintArgMonos`, whose payload is ids-only) and is STILL OPEN, pinned at
# test/must_fail_fixtures/1161-sig-constraint-unsatisfiable-accepted/.
echo
echo '=== 4. declaration-order permutation (DICT §3 order-freedom; #1154/#1155) ==='

# The permuter operates on TOP-LEVEL CHUNKS: a chunk starts at any line with a
# non-whitespace character in column 0 (the offside rule puts every top-level
# declaration there) and runs until the next such line; a blank/indented line
# attaches to the chunk above it. Reversing the chunks tagged with the target
# interface swaps their CONTENTS across their original slots, so every other
# declaration -- `data`, `interface`, unrelated `impl`s, `main` -- stays at its
# original position. This is a source-level reordering, not a rewrite: if a
# permuted file fails to PARSE where the original did, that is a permuter bug,
# not a compiler finding (see AGENTS.md STOP guardrail for this gate).
PERMPL="$TMP/permute.pl"
cat >"$PERMPL" <<'PERLEOF'
use strict;
use warnings;
my ($in, $iface, $out) = @ARGV;
open(my $fh, "<", $in) or die "open $in: $!";
my @lines = <$fh>;
close $fh;
my @chunks;
my $cur;
for my $line (@lines) {
  if ($line =~ /^\S/) {
    push @chunks, $cur if $cur;
    my $ifacename;
    $ifacename = $1 if $line =~ /^(?:export\s+)?impl\s+(\w+)/;
    $cur = { iface => $ifacename, lines => [$line] };
  } else {
    $cur = { iface => undef, lines => [] } if !$cur;
    push @{$cur->{lines}}, $line;
  }
}
push @chunks, $cur if $cur;
my @idx;
for my $i (0..$#chunks) {
  push @idx, $i if defined $chunks[$i]{iface} && $chunks[$i]{iface} eq $iface;
}
die "need >=2 impl blocks of $iface, found " . scalar(@idx) . "\n" if scalar(@idx) < 2;
my @orig = map { $chunks[$_]{lines} } @idx;
for my $k (0..$#idx) {
  $chunks[$idx[$k]]{lines} = $orig[$#idx - $k];
}
open(my $ofh, ">", $out) or die "open $out: $!";
print $ofh @{$_->{lines}} for @chunks;
close $ofh;
PERLEOF

# The qualifying (fixture, interface) set is DERIVED every run, never hand-
# listed -- so a fixture added to the corpus tomorrow with >=2 impls of one
# interface is automatically exercised, with no second place to remember to
# wire it in. Scoped to files directly in FIXDIR (`*.mdk`, no recursion): a
# directory doesn't match that glob at all, which is how multi-file fixtures
# are excluded WITHOUT a name-prefix hazard (AGENTS.md's word-boundary trap
# does not apply here -- this is a glob over one directory's own entries, not
# a grep that could bleed into a sibling corpus).
PAIRS="$(cd "$FIXDIR" && for f in *.mdk; do
  [ -f "$f" ] || continue
  grep -oE '^(export )?impl [A-Za-z_][A-Za-z0-9_]*' "$f" 2>/dev/null | awk '{print $NF}' \
    | sort | uniq -c | awk -v f="$f" '$1>=2{print f"|"$2}'
done)"

# KNOWN-BAD LEDGER for this section, same convention as the top-of-file ledger:
# a pair already covered by an OPEN issue is pinned with BOTH observed values
# and asserted to DIFFER, so the row reds the day they converge (the drain)
# instead of silently passing or silently being skipped.
#   entry | iface | orig-build-value | perm-build-value | issue
KNOWNBAD_PERM='s6-2-t4-open-goal-deferred.mdk|Sh|1|2|#1183'

# THE SAME LEDGER FOR THE **RUN** ARM. ⚠️ It exists because the build-arm ledger
# above is NOT a general escape hatch: `RUN-DIFF` had no known-bad branch at all,
# so a pair whose divergence shows on BOTH engines could only be recorded by
# excluding it -- and an exclusion is a skip-list, which cannot notice when the
# thing it excuses is fixed. #1127 happens to diverge on `build` alone, which is
# why one arm sufficed until F-3d.
#   entry | iface | orig-run-value | perm-run-value | issue
KNOWNBAD_PERM_RUN='s6-2-t4-open-goal-deferred.mdk|Sh|1|2|#1183'

printf '%s\n' "$PAIRS" | while IFS='|' read -r entry iface; do
  [ -z "$entry" ] && continue
  entrypath="$FIXDIR/$entry"
  base="$(printf '%s' "$entry" | tr '/.' '__')__${iface}"
  permfile="$TMP/${base}_perm.mdk"

  if ! perl "$PERMPL" "$entrypath" "$iface" "$permfile" 2>"$TMP/$base.permerr"; then
    printf 'FAIL perm    %-40s [%-8s] PERMUTER ERROR: %s\n' "$entry" "$iface" "$(cat "$TMP/$base.permerr")"
    echo "FAIL" >>"$TMP/v4"
    continue
  fi

  bound "$MEDAKA" check --json "$entrypath" >"$TMP/$base.o.chk.json" 2>&1
  o_chk=$?
  o_code="$(grep -o '"code":"[^"]*"' "$TMP/$base.o.chk.json" | head -1)"
  bound "$MEDAKA" check --json "$permfile" >"$TMP/$base.p.chk.json" 2>&1
  p_chk=$?
  p_code="$(grep -o '"code":"[^"]*"' "$TMP/$base.p.chk.json" | head -1)"

  row_ok=1
  reason=''
  if [ "$o_chk" -eq 0 ] && [ "$p_chk" -eq 0 ]; then
    verdict='ACCEPT/ACCEPT'
  elif [ "$o_chk" -ne 0 ] && [ "$p_chk" -ne 0 ]; then
    verdict='REJECT/REJECT'
    if [ "$o_code" != "$p_code" ]; then
      row_ok=0
      reason="reject code changed under permutation: $o_code -> $p_code"
    fi
  else
    verdict="DIVERGED($o_chk/$p_chk)"
    row_ok=0
    reason='check verdict itself flipped under permutation'
  fi

  kb_line="$(printf '%s\n' "$KNOWNBAD_PERM" | awk -F'|' -v e="$entry" -v i="$iface" '$1==e && $2==i {print}')"
  kbr_line="$(printf '%s\n' "$KNOWNBAD_PERM_RUN" | awk -F'|' -v e="$entry" -v i="$iface" '$1==e && $2==i {print}')"
  runbuild='n/a'
  if [ "$o_chk" -eq 0 ] && [ "$p_chk" -eq 0 ]; then
    bound "$MEDAKA" run "$entrypath" >"$TMP/$base.o.run.out" 2>"$TMP/$base.o.run.err"
    o_run=$?
    bound "$MEDAKA" run "$permfile" >"$TMP/$base.p.run.out" 2>"$TMP/$base.p.run.err"
    p_run=$?
    # Three-way split, not a 0/0-vs-everything-else guard: an ASYMMETRIC pair
    # (one ordering runs, the other doesn't) is the LOUDEST form of the
    # property this section exists to catch -- declaration order deciding
    # whether the program runs at all -- and must FAIL the row, never read as
    # a benign skip. A SYMMETRIC failure (both orderings fail) still owes an
    # assertion: DICT §3 order-freedom binds there too, so the two orderings
    # must fail the SAME way. The level graded is the EXIT CODE, not stderr
    # TEXT: verified by hand that medaka's runtime panics are not uniformly
    # location-free (`E-DIV-ZERO` prints `file:L:C: runtime error [...]`,
    # while the `E-PANIC` this very corpus's s3-nested-obligation-two-levels.mdk
    # hits prints no location at all) -- and permutation deterministically
    # shifts every line number below the reordered blocks, so a byte-diff of
    # stderr would FAIL a program panicking for the IDENTICAL reason purely
    # because the panic's line moved: a false positive with nothing to do with
    # order-sensitivity. This mirrors why Section 1's REJECT rows compare
    # `check --json`'s diagnostic CODE, never message text -- `run` has no
    # such structured code (#1130), so exit code is the coarsest thing that is
    # both meaningful and immune to location drift.
    if [ "$o_run" -eq 0 ] && [ "$p_run" -eq 0 ]; then
      if [ -n "$kbr_line" ]; then
        # KNOWN-BAD run divergence: assert BOTH pinned values AND that they still
        # DIFFER, so the row reds on convergence (the drain) rather than absorbing
        # the fix.  Same shape as the build arm below.
        kbr_o="$(printf '%s' "$kbr_line" | cut -d'|' -f3)"
        kbr_p="$(printf '%s' "$kbr_line" | cut -d'|' -f4)"
        kbr_issue="$(printf '%s' "$kbr_line" | cut -d'|' -f5)"
        printf '%b\n' "$kbr_o" >"$TMP/$base.kbr.o.expected"
        printf '%b\n' "$kbr_p" >"$TMP/$base.kbr.p.expected"
        if cmp -s "$TMP/$base.o.run.out" "$TMP/$base.p.run.out"; then
          run_v='CONVERGED-FIXED'
          row_ok=0
          reason="${reason:+$reason; }KNOWN-BAD $kbr_issue run divergence has CONVERGED -- re-pin or drop this ledger row"
        elif cmp -s "$TMP/$base.o.run.out" "$TMP/$base.kbr.o.expected" && cmp -s "$TMP/$base.p.run.out" "$TMP/$base.kbr.p.expected"; then
          run_v="ok(known-bad $kbr_issue)"
        else
          run_v='WRONG-KNOWNBAD-VALUE'
          row_ok=0
          reason="${reason:+$reason; }KNOWN-BAD $kbr_issue row's pinned run values no longer match observed output"
        fi
      elif cmp -s "$TMP/$base.o.run.out" "$TMP/$base.p.run.out"; then
        run_v='ok'
      else
        run_v='RUN-DIFF'
        row_ok=0
        reason="${reason:+$reason; }run stdout differs under permutation"
      fi
    elif [ "$o_run" -ne 0 ] && [ "$p_run" -ne 0 ]; then
      if [ "$o_run" -eq "$p_run" ]; then
        run_v="ok(fails-both, exit $o_run)"
      else
        run_v="FAIL-DIFF-EXIT($o_run/$p_run)"
        row_ok=0
        reason="${reason:+$reason; }run fails on both orderings but with DIFFERENT exit codes: orig=$o_run perm=$p_run"
      fi
    else
      run_v="FAIL-ASYMMETRIC($o_run/$p_run)"
      row_ok=0
      reason="${reason:+$reason; }run exit code diverges under permutation: orig=$o_run perm=$p_run (order changed whether the program runs at all)"
    fi

    bound "$MEDAKA" build "$entrypath" -o "$TMP/$base.o.bin" >"$TMP/$base.o.build.log" 2>&1
    o_build=$?
    bound "$MEDAKA" build "$permfile" -o "$TMP/$base.p.bin" >"$TMP/$base.p.build.log" 2>&1
    p_build=$?
    # "Effective success" folds the -x check into the same 0/1 the run arm
    # grades on, so a build that exits 0 but somehow emits no executable is
    # treated as a failure rather than silently matching the success branch.
    o_build_ok=0; [ "$o_build" -eq 0 ] && [ -x "$TMP/$base.o.bin" ] && o_build_ok=1
    p_build_ok=0; [ "$p_build" -eq 0 ] && [ -x "$TMP/$base.p.bin" ] && p_build_ok=1
    if [ "$o_build_ok" -eq 1 ] && [ "$p_build_ok" -eq 1 ]; then
      bound "$TMP/$base.o.bin" >"$TMP/$base.o.exec.out" 2>"$TMP/$base.o.exec.err"
      bound "$TMP/$base.p.bin" >"$TMP/$base.p.exec.out" 2>"$TMP/$base.p.exec.err"
      if [ -n "$kb_line" ]; then
        kb_o="$(printf '%s' "$kb_line" | cut -d'|' -f3)"
        kb_p="$(printf '%s' "$kb_line" | cut -d'|' -f4)"
        kb_issue="$(printf '%s' "$kb_line" | cut -d'|' -f5)"
        printf '%b\n' "$kb_o" >"$TMP/$base.kb.o.expected"
        printf '%b\n' "$kb_p" >"$TMP/$base.kb.p.expected"
        if cmp -s "$TMP/$base.o.exec.out" "$TMP/$base.p.exec.out"; then
          build_v='CONVERGED-FIXED'
          row_ok=0
          reason="${reason:+$reason; }KNOWN-BAD $kb_issue build divergence has CONVERGED -- re-pin or drop this ledger row"
        elif cmp -s "$TMP/$base.o.exec.out" "$TMP/$base.kb.o.expected" && cmp -s "$TMP/$base.p.exec.out" "$TMP/$base.kb.p.expected"; then
          build_v="ok(known-bad $kb_issue)"
        else
          build_v='WRONG-KNOWNBAD-VALUE'
          row_ok=0
          reason="${reason:+$reason; }KNOWN-BAD $kb_issue row's pinned values no longer match observed output"
        fi
      else
        if cmp -s "$TMP/$base.o.exec.out" "$TMP/$base.p.exec.out"; then
          build_v='ok'
        else
          build_v='BUILD-DIFF'
          row_ok=0
          reason="${reason:+$reason; }build stdout differs under permutation"
        fi
      fi
    elif [ "$o_build_ok" -eq 0 ] && [ "$p_build_ok" -eq 0 ]; then
      # Same reasoning as the run arm's symmetric-failure branch: compare exit
      # codes, not build-log TEXT. `medaka build`'s own diagnostics can embed
      # the source path, which differs between entrypath and permfile by
      # construction (different filenames), so a textual diff would flag
      # cosmetic noise as a finding.
      if [ "$o_build" -eq "$p_build" ]; then
        build_v="ok(fails-both, exit $o_build)"
      else
        build_v="FAIL-DIFF-EXIT($o_build/$p_build)"
        row_ok=0
        reason="${reason:+$reason; }build fails on both orderings but with DIFFERENT exit codes: orig=$o_build perm=$p_build"
      fi
    else
      build_v="FAIL-ASYMMETRIC($o_build/$p_build)"
      row_ok=0
      reason="${reason:+$reason; }build exit code (or missing binary) diverges under permutation: orig=$o_build(ok=$o_build_ok) perm=$p_build(ok=$p_build_ok)"
    fi
    runbuild="run=$run_v build=$build_v"
  fi

  if [ "$row_ok" -eq 1 ]; then
    result='PASS'
    echo "PASS" >>"$TMP/v4"
  else
    result='FAIL'
    echo "FAIL" >>"$TMP/v4"
  fi
  printf '%-4s perm %-40s [%-8s] %-14s %-40s %s\n' "$result" "$entry" "$iface" "$verdict" "$runbuild" "$reason"
done

# ⚠️ N == 0 here means the DERIVATION found no qualifying fixture, not that
# permutation-sensitivity was checked and found absent -- see the empty-section
# check at the bottom of this file, which fails the whole gate on that.

# ── Tally ────────────────────────────────────────────────────────────────────
# The `printf | while read` loop above runs in a SUBSHELL under dash/ash (POSIX
# permits it and dash does fork the last pipeline stage), so shell variables
# mutated inside it do not survive. Every verdict is therefore appended to a
# FILE, which does, and the totals are derived from that -- never from a
# variable, and never from an exit code.
cnt() { c="$(grep -c "^$2\$" "$TMP/$1" 2>/dev/null || true)"; [ -n "$c" ] || c=0; echo "$c"; }
p4="$(cnt v4 PASS)"; f4="$(cnt v4 FAIL)"
n4=$((p4+f4))

echo
printf '%s: checked %d assertions -- %d passed, %d failed\n' "$(basename "$0")" "$n4" "$p4" "$f4"
printf '  decl-order-perm %d\n' "$n4"

# ⚠️ AN EMPTY SECTION IS A FAILURE, NOT A PASS. Three gates in this tree once
# shelled out to a tool that was not installed, printed `skipping`, and exited 0
# -- so a required tandem gate had never once executed on that machine. "Green"
# is not "ran", and a gate that can silently no-op will. That applies to this
# section's DERIVED set exactly as it does to a hand-written table: if the
# derivation ever finds zero qualifying fixtures (a bad edit to the grep/awk
# pipeline, or every qualifying fixture being deleted), that is n4 == 0, and it
# fails the gate -- a self-no-op is not distinguishable from "nothing to check"
# and must not be treated as one.
[ "$n4" -eq 0 ] && { echo "FAIL: section 4 (decl-order-perm) made ZERO assertions -- the derived qualifying set was empty." >&2; exit 1; }

[ "$f4" -eq 0 ]
