#!/bin/sh
# diff_compiler_import_order.sh — the IMPORT-CLAUSE PERMUTATION DIFFERENTIAL.
#
# Unit 0 of #1319 (constructor-namespace identity). It exists for one reason:
#
#   ⭐ A GOLDEN CANNOT CATCH AN OVER-WIDENING. A golden pins the output the compiler
#   produced. If a rule is too permissive, the golden records the permissive answer
#   and then DEFENDS it — it will pass, by construction, for exactly the class of
#   defect #1319 is about. The check for an order-dependence bug is a PERMUTATION
#   DIFFERENTIAL: permute the input along the suspect axis and require the answer to
#   be invariant. That needs NO ground truth, which is what makes it able to see a
#   widening nobody has written down the right answer for.
#
# The axis here is the ENTRY MODULE'S IMPORT-CLAUSE ORDER. Reordering imports is
# cosmetic — every formatter and every reviewer treats it that way — so a program
# whose meaning depends on it is wrong whatever the "right" answer turns out to be.
#
# ── PRIOR ART, AND WHAT IS NEW ───────────────────────────────────────────────
# test/diff_compiler_dict_semantics.sh Section 4 is the proven permutation
# differential in this tree (it caught #1127's order sensitivity, and #1154's shape
# is why it was built). This gate is modelled on it wholesale: the chunk permuter,
# the verdict/stdout/exit-code comparison, the KNOWN-BAD-row-as-ledger idea and the
# empty-section-is-a-failure rule are all its. Two things differ, and its own header
# names the constraint that makes them necessary — "A permutation differential is
# only order-free along the axis it actually permutes":
#   * it permutes `impl` BLOCKS; this permutes IMPORT CLAUSES;
#   * it is "scoped to files directly in test/dict_fixtures/*.mdk" — single file —
#     while every import-order defect on the tracker is MULTI-MODULE by nature, so
#     the unit here is a DIRECTORY.
#
# ── WHY THIS AXIS HAD NO GATE, AND WHAT WENT UNGRADED ────────────────────────
# test/diff_compiler_must_fail.sh grades ONE command plus a control per fixture, so
# the order half cannot be the pin there. #1284's must-fail fixture says so itself
# and keeps a `main_swapped.mdk` as an UNGRADED sibling whose output lives in a
# header comment. When #1284 is fixed that fixture is deleted, and — before this
# gate — nothing anywhere would have pinned order-invariance afterwards. Derive:
#   grep -rn 'swapped' test/must_fail_fixtures/ | head
#
# ###################################################################
# # THE INVARIANCE CRITERION — WHAT MUST BE EQUAL ACROSS ORDERINGS  #
# ###################################################################
# For each case, every ordering of the entry's import clauses is compiled and run,
# and reduced to a one-line SIGNATURE. The signature is what must be invariant:
#
#     check=<exit>;codes=<sorted,comma>;schemes=<check stdout>;run=<exit>:<stdout>;build=<exit>/<exec-exit>:<stdout>
#
#   check=  `medaka check --json` exit code. 0 vs nonzero is the verdict; the exact
#           code is kept because a change from 1 to 2 is also a change.
#   codes=  every `"code":"..."` in `check --json`, SORTED. Sorted because diagnostics
#           are emitted in source order and permutation moves source lines; a
#           multiset (not a set) because "one T-TYPE-MISMATCH" and "two" are
#           genuinely different observations — #1284 emits two, and one ordering of
#           733-ambiguous-ctor-reject-cascade-order-dependent/ emits a cascading
#           second code the other does not. An exit-code-only criterion is blind to
#           that row; a set-not-multiset one is blind to #1284's pair.
#   schemes= plain `medaka check`'s scheme dump for the user's own top-level
#           bindings, selected by FORMAT (`<name> : <type>` at column 0) rather than
#           by stream — see the measured stage-by-stage note at sig_for below, which
#           corrected an earlier wrong claim in this very header. It carries no
#           message text and no locations. It is the observable that can see "exit 0,
#           same printed value, but the binding was INFERRED AT A DIFFERENT TYPE" —
#           which is what "a different declaration won" looks like when the values
#           happen to coincide.
#   run=    `medaka run` exit code and STDOUT.
#   build=  `medaka build` exit code, then the built binary's exit code and STDOUT
#           (`-` if no binary was produced). `run` and `build` share the whole front
#           end and differ only in the engine, so they are two observations of the
#           BACKEND, not two of the type checker — and they can disagree: #1253's
#           two engines pick OPPOSITE winners for the same source (measured; that is
#           not in the issue body). Both are graded.
#
# ── WHAT IS DELIBERATELY NOT COMPARED, AND WHY ───────────────────────────────
# A criterion that compares too little passes everything; one that compares too much
# turns correct, deliberately order-sensitive behaviour into a false red. Excluded,
# each for a measured reason:
#
#   * DIAGNOSTIC MESSAGE TEXT. `R-AMBIGUOUS-CTOR` names the two colliding modules IN
#     IMPORT-CLAUSE ORDER, on purpose — the provenance-based ambiguity trigger is
#     deliberately ONE rule across all four namespaces, and the message enumerates
#     the clauses the user wrote in the order they wrote them. Measured on the binary
#     at main 0af30a78: "...brought into scope by both `amodd` and `zmod`" with one
#     clause first, "...both `zmod` and `amodd`" with the other. A text diff would
#     call that a defect. The corpus keeps that exact program as
#     control-ambiguous-ctor-reject-invariant/ so the exclusion is itself graded:
#     the row still fails if the VERDICT or the CODE ever becomes order-dependent.
#   * DIAGNOSTIC RANGES (file:line:col). Permuting clauses of unequal line count
#     moves every line below them; a location diff would be a pure artifact of the
#     permutation, with nothing to do with order sensitivity.
#   * STDERR of `run` and `build`. Medaka's runtime panics are not uniformly
#     location-free (diff_compiler_dict_semantics.sh Section 4 established this by
#     hand), and `medaka build`'s log embeds the source path. Both would diff for
#     reasons unrelated to the property.
#   * THE ORDER of diagnostics — hence the sort above.
#   * THE EMITTED IR. Which impl was selected is observed BEHAVIOURALLY here (#1253
#     prints FROM-RA vs FROM-RB). An IR-level assertion would be a stronger probe and
#     is not attempted; `medaka build --keep-ir` is the tool if a future row needs it.
#
# ###################################################################
# # THE EMITTER-VERDICT ARM — A FOURTH DRIVER, GRADED SEPARATELY     #
# ###################################################################
# RUN-XMOD-022/023 (xmod-identity sprint, packet
# L1-L2-driver-asymmetry-observation). The discovery spike measured that the RAW
# `./medaka_emitter` binary can exit 0 and emit a complete, linkable, runnable
# program for an entry that `check`/`run`/`build` all reject.
#
# ⚠️ MECHANISM (corrected F3, RUN-XMOD-041 — a prior draft of this paragraph blamed
# `main`'s TYPE; measured, that is false; the real discriminator is MODULE COUNT):
# `underivedMainDiags` (compiler/driver/main_autoprint.mdk) is the ONLY place a
# `failWith` on a typecheck diagnostic sits on this path, and its first clause
# pattern-matches a SINGLETON module list — `underivedMainDiags rt core
# [(_, entryDecls)] = …`. Every OTHER shape, including every multi-module program
# (any program with an import), falls to the wildcard clause, which returns `[]`
# unconditionally. So for any import-bearing entry — the entire corpus this gate
# permutes — that diagnostic-surfacing arm is structurally unreachable regardless
# of whether `main` is Unit-valued or not: a 2x2 measured on {single,multi} x
# {unit,non-unit} main showed `main`'s type moves NOTHING (`single-unit` and
# `single-nonunit` both `emit=1:noir`; `multi-unit` and `multi-nonunit` both
# `emit=0:ir`) while module count moves everything. This is a separate observation
# from the signature above, kept in a SEPARATE space and
# graded against a SEPARATE sidecar ledger, `test/EMITTER-VERDICT-LEDGER.txt` —
# on purpose, per RUN-XMOD-023: folding an `emit=` cell into the `check=…` printf
# above would re-cut every row already pinned in `test/IMPORT-ORDER-LEDGER.txt`,
# including #1351's, whose two signatures are the comparison the eventual drain
# depends on. `sig_for`'s printf is untouched by this arm.
#
# For each ordering already staged to run `sig_for`, `emit_verdict_for` invokes
# the raw emitter directly and observes ONLY its exit code and whether it wrote
# non-empty IR — never the IR text (moves on every compiler change) and never its
# stderr (embeds absolute mktemp paths, the exact bug this gate's own `schemes=`
# comment records catching on its first real run). Per case, the observed
# CLASSIFICATION (AGREE/DISAGREE — computed, never transcribed) is graded against
# `test/EMITTER-VERDICT-LEDGER.txt`, whose own header explains the row format and
# the grading rules. See also `test/MUST-FAIL-NOT-PINNABLE.txt`'s `1667` row,
# which names this arm as the permanent guard for #1667.
#
# ── SCOPE LIMITS, SAID OUT LOUD ──────────────────────────────────────────────
#   * Only the ENTRY module's clauses are permuted. A defect decided by an IMPORTED
#     module's clause order is NOT covered by this gate. Nothing else covers it either.
#   * Import clauses are permuted among THEIR OWN original slots, so a clause never
#     moves across a declaration. An order sensitivity that needs an import to move
#     past a `data`/`impl` is out of scope by construction.
#   * All n! orderings are tried when n <= 4. Above that the gate falls back to
#     identity + reversal + every adjacent transposition and PRINTS `PARTIAL` on the
#     row, so a shrunken permutation set can never look like a full one.
#
# ###################################################################
# # THE LEDGER — WHY THIS GATE IS GREEN ON A TREE WITH THREE OPEN   #
# # ORDER-DEPENDENCE BUGS, AND HOW IT DRAINS                        #
# ###################################################################
# Three cases in this corpus ARE order-dependent today. A gate that landed red would
# break `main` and would teach people to ignore it. So each is carried as a row in
# test/IMPORT-ORDER-LEDGER.txt naming its OPEN issue, and the row pins EVERY distinct
# signature the case produces, asserting there is MORE THAN ONE. That makes it
# self-draining in both directions:
#
#   * an UNLEDGERED case that produces two signatures        -> FAIL (a new bug)
#   * a LEDGERED case that collapses to ONE signature        -> FAIL, naming the
#                                                               issue to close (the drain)
#   * a LEDGERED case whose signatures no longer match       -> FAIL (the bug moved)
#   * a ledger row naming a case that does not exist         -> FAIL (rot)
#
# Read test/IMPORT-ORDER-LEDGER.txt's own header for what a reviewer must demand
# before accepting a NEW row. The short version: a ledger row is a statement that a
# soundness bug is shipping, and it costs a transcription of two real outputs plus a
# fixture directory named after the issue — it is deliberately not one line you can
# reflexively bump when this gate goes red.
#
# ⚠️ This gate is OFFLINE — it never contacts the GitHub API, because it runs on every
# dev box under `make gates`/preflight and in a required CI shard, where a rate limit
# or a fork's restricted token must never block a merge. So it CANNOT check that a
# ledgered issue is still OPEN. That half lives in test/must_fail_census.sh (nightly,
# has the API), exactly as the must-fail ratchet splits the same way.
#
# Usage:  sh test/diff_compiler_import_order.sh
# Exit:   0 every case is invariant or ledgered-and-still-diverging; 1 otherwise;
#         2 infrastructure (no binary, no corpus, no perl).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/import_order_fixtures"
LEDGER="$ROOT/test/IMPORT-ORDER-LEDGER.txt"
EMITTER_LEDGER="$ROOT/test/EMITTER-VERDICT-LEDGER.txt"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -d "$FIXDIR" ] || { echo "missing fixture dir: $FIXDIR"; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "perl not found (needed for the permuter)"; exit 2; }

# The `build` arm needs the native emitter. Resolved and exported explicitly, the same
# way test/diff_compiler_ir_size.sh and test/diff_compiler_dispatch_shape.sh do — the
# CI gate-shard step does not export it, and a gate that relies on a default lookup is
# one refactor away from silently grading only two of its three verbs.
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
[ -x "$EMITTER" ] || { echo "missing native emitter: $EMITTER (make medaka)"; exit 2; }
export MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER"

# Every invocation is bounded. A regression that makes one ORDERING loop must surface
# as a row failure, not as a hung CI job. 120s covers a `medaka build` + clang.
bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/verdicts"
: >"$TMP/builtwitness"
: >"$TMP/emitwitness"
: >"$TMP/notes"

# ── the permuter ─────────────────────────────────────────────────────────────
# Operates on TOP-LEVEL CHUNKS, exactly as dict_semantics' does: a chunk starts at any
# line with a non-whitespace character in column 0 (the offside rule puts every
# top-level declaration there) and runs until the next such line, so a blank or
# indented continuation line attaches to the chunk above it. That is what makes a
# multi-line `import m.{ ... }` move as one unit. Chunks whose FIRST line is an import
# clause are permuted across THEIR OWN slots; every other chunk stays exactly where it
# was. If a permuted file fails to PARSE where the original did, that is a permuter
# bug, not a compiler finding.
PERMPL="$TMP/permute.pl"
cat >"$PERMPL" <<'PERLEOF'
use strict;
use warnings;
my ($in, $mode, $spec, $out) = (@ARGV, '', '', '');

open(my $fh, "<", $in) or die "open $in: $!";
my @lines = <$fh>;
close $fh;

my (@chunks, $cur);
for my $line (@lines) {
  if ($line =~ /^\S/) {
    push @chunks, $cur if $cur;
    my $is_import = ($line =~ /^(?:export\s+)?import\s/) ? 1 : 0;
    $cur = { imp => $is_import, lines => [$line] };
  } else {
    $cur = { imp => 0, lines => [] } if !$cur;
    push @{$cur->{lines}}, $line;
  }
}
push @chunks, $cur if $cur;

my @idx = grep { $chunks[$_]{imp} } 0..$#chunks;
my $n = scalar(@idx);
die "need >=2 top-level import clauses, found $n\n" if $n < 2;

sub perms {
  my @xs = @_;
  return ([]) unless @xs;
  my @out;
  for my $i (0..$#xs) {
    my @rest = @xs; my ($p) = splice(@rest, $i, 1);
    push @out, [$p, @$_] for perms(@rest);
  }
  return @out;
}

my @orders;
my $partial = 0;
if ($n <= 4) {
  @orders = perms(0..$n-1);
} else {
  # identity + reversal + every adjacent transposition. Reported as PARTIAL.
  $partial = 1;
  push @orders, [0..$n-1];
  push @orders, [reverse 0..$n-1];
  for my $i (0..$n-2) {
    my @o = (0..$n-1);
    @o[$i, $i+1] = @o[$i+1, $i];
    push @orders, \@o;
  }
}

if ($mode eq 'LIST') {
  print "n=$n partial=$partial\n";
  print join(',', @$_), "\n" for @orders;
  exit 0;
}

my @want = split /,/, $spec;
die "spec has " . scalar(@want) . " entries, need $n\n" if scalar(@want) != $n;
my @orig = map { $chunks[$_]{lines} } @idx;
for my $k (0..$#idx) {
  $chunks[$idx[$k]]{lines} = $orig[$want[$k]];
}
open(my $ofh, ">", $out) or die "open $out: $!";
print $ofh @{$_->{lines}} for @chunks;
close $ofh;
PERLEOF

# ── signature escaping ───────────────────────────────────────────────────────
# The ledger holds signatures as ONE LINE each, and both `|` (its field separator) and
# `;` (the signature's own separator) can appear in a program's stdout — and so can a
# literal TAB, which is the OUTER ledger record's own separator (the `printf
# '%s\t%s\n'` below, split back apart with `cut -f2`). An unescaped TAB truncates the
# signature there, before comparison, letting two genuinely different signatures
# compare EQUAL and the gate silently miss a real divergence (#1634). The escape is
# applied to the OBSERVED output only, and the ledger stores the ESCAPED form — so the
# gate never unescapes anything, it compares escaped strings. That keeps the mapping
# injective without a parser: \ -> \\ , | -> \p , ; -> \s , TAB -> \t , newline -> \n.
esc() { perl -0777 -pe 's/\\/\\\\/g; s/\|/\\p/g; s/;/\\s/g; s/\t/\\t/g; s/\n/\\n/g' "$1"; }

# ── enumerate the corpus. DERIVED from the directory listing; nothing is registered ──
cases=''
for d in "$FIXDIR"/*/; do
  [ -d "$d" ] || continue
  cases="$cases $(basename "$d")"
done

# ── run one case, print one signature per ordering ───────────────────────────
sig_for() {
  _work="$1"; _entry="$2"
  bound "$MEDAKA" check --json "$_work/$_entry" >"$_work/.chk" 2>&1
  _c=$?
  _codes="$(grep -o '"code":"[^"]*"' "$_work/.chk" 2>/dev/null \
            | sed 's/"code":"//; s/"$//' | sort | tr '\n' ',' | sed 's/,$//')"
  # THE SCHEME DUMP, EXTRACTED BY FORMAT — NOT BY STREAM.
  #
  # ⚠️ An earlier draft of this took plain `check`'s whole STDOUT, on the claim that
  # "diagnostics go to stderr". THAT IS FALSE, and this gate caught it on its own
  # first real run — it pasted an absolute mktemp path into a would-be ledger
  # signature. Re-measured by hand on the binary at main 0af30a78, per stage:
  #   * RESOLVE-stage diagnostics (`R-AMBIGUOUS-CTOR`)  -> STDERR
  #   * TYPE-stage diagnostics    (`T-TYPE-MISMATCH`)   -> STDOUT
  # so the stream does not discriminate, and stdout can carry `file:line:col` plus
  # message text plus (here) the harness's own temp directory — none of which may
  # enter a signature.
  #
  # So the scheme lines are selected by their FORMAT: `<binding> : <type>`, anchored
  # at column 0. A diagnostic line cannot match (it begins with a path, a digit or
  # the `  |` gutter). What this observable buys is the case a value comparison
  # cannot see: exit 0, same printed output, but a binding INFERRED AT A DIFFERENT
  # TYPE because a different declaration won — the shape #1319's predictions are
  # about. Known limit: a scheme wrapped onto a continuation line loses its tail.
  bound "$MEDAKA" check "$_work/$_entry" >"$_work/.chkout" 2>/dev/null
  grep -E "^[A-Za-z_][A-Za-z0-9_']* : " "$_work/.chkout" >"$_work/.schemes" 2>/dev/null || :
  _s="$(esc "$_work/.schemes")"
  bound "$MEDAKA" run "$_work/$_entry" >"$_work/.run.out" 2>"$_work/.run.err"
  _r=$?
  _ro="$(esc "$_work/.run.out")"
  bound "$MEDAKA" build "$_work/$_entry" -o "$_work/.bin" >"$_work/.build.log" 2>&1
  _b=$?
  if [ "$_b" -eq 0 ] && [ -x "$_work/.bin" ]; then
    bound "$_work/.bin" >"$_work/.exec.out" 2>"$_work/.exec.err"
    _x=$?
    _bo="$(esc "$_work/.exec.out")"
    # Witness that the build arm actually built something at least once. If
    # `medaka build` were broken for every ordering of every case, every signature
    # would carry `build=1/-:` and every row would still compare EQUAL — a green
    # gate whose third verb graded nothing. The tally refuses that below.
    echo built >>"$TMP/builtwitness"
  else
    _x='-'
    _bo=''
  fi
  printf 'check=%s;codes=%s;schemes=%s;run=%s:%s;build=%s/%s:%s\n' \
    "$_c" "$_codes" "$_s" "$_r" "$_ro" "$_b" "$_x" "$_bo"
}

# ── the emitter-verdict observable (RUN-XMOD-022/023) — sibling of sig_for, NOT
#    a mirror. It must never be folded into sig_for's printf (see the header
#    section above). Only the exit code and IR-nonemptiness are observed; the IR
#    text and the emitter's stderr must never be pinned.
emit_verdict_for() {
  _work="$1"; _entry="$2"
  # The extra "$ROOT/stdlib" root gives the raw emitter the SAME root set
  # check/run/build get via MEDAKA_ROOT="$ROOT" (exported above) — without it, any
  # case importing a non-`core` stdlib module (list/map/string/...) would resolve
  # for check/run/build but exit 1 "unknown module: <m>" for the raw emitter alone,
  # misclassifying as DISAGREE for a root-set reason that has nothing to do with a
  # compiler defect (F1, correction round, RUN-XMOD-041). Measured:
  # `./medaka_emitter stdlib/runtime.mdk stdlib/core.mdk <entry> <workdir>` on a
  # program with `import list.{reverse}` -> exit 1 "unknown module: list"; the same
  # invocation with a trailing `stdlib` root -> exit 0, non-empty IR.
  bound "$EMITTER" "$ROOT/stdlib/runtime.mdk" "$ROOT/stdlib/core.mdk" \
        "$_work/$_entry" "$_work" "$ROOT/stdlib" >"$_work/.emit.ll" 2>"$_work/.emit.err"
  _e=$?
  if [ -s "$_work/.emit.ll" ]; then _ir=ir; else _ir=noir; fi
  printf 'emit=%s:%s\n' "$_e" "$_ir"
}

echo "IMPORT-CLAUSE PERMUTATION DIFFERENTIAL — the answer must not depend on import order."
echo "corpus: test/import_order_fixtures   ledger: test/IMPORT-ORDER-LEDGER.txt"
echo

for cse in $cases; do
  cdir="$FIXDIR/$cse"
  spec="$cdir/case.txt"

  if [ ! -f "$spec" ]; then
    printf 'FAIL %-52s no case.txt (a case directory must declare its entry)\n' "$cse"
    echo FAIL >>"$TMP/verdicts"; continue
  fi
  entry="$(sed -n 's/^entry:[[:space:]]*//p' "$spec" | head -1)"
  what="$(sed -n 's/^what:[[:space:]]*//p' "$spec" | head -1)"
  if [ -z "$entry" ] || [ ! -f "$cdir/$entry" ]; then
    printf 'FAIL %-52s case.txt names entry "%s", which is not a file here\n' "$cse" "$entry"
    echo FAIL >>"$TMP/verdicts"; continue
  fi

  if ! perl "$PERMPL" "$cdir/$entry" LIST >"$TMP/$cse.orders" 2>"$TMP/$cse.err"; then
    printf 'FAIL %-52s PERMUTER: %s\n' "$cse" "$(head -1 "$TMP/$cse.err")"
    echo FAIL >>"$TMP/verdicts"; continue
  fi
  head1="$(head -1 "$TMP/$cse.orders")"
  nclauses="$(printf '%s' "$head1" | sed 's/^n=\([0-9]*\).*/\1/')"
  partial="$(printf '%s' "$head1" | sed 's/.*partial=\([0-9]*\).*/\1/')"

  : >"$TMP/$cse.sigs"
  : >"$TMP/$cse.emitsigs"
  k=0
  tail -n +2 "$TMP/$cse.orders" | while IFS= read -r ord; do
    [ -n "$ord" ] || continue
    k=$((k+1))
    work="$TMP/$cse/p$k"
    mkdir -p "$work"
    for f in "$cdir"/*; do cp "$f" "$work/"; done
    if ! perl "$PERMPL" "$cdir/$entry" WRITE "$ord" "$work/$entry" 2>"$TMP/$cse.werr"; then
      printf 'PERMUTER-WRITE-FAILED %s\n' "$ord" >>"$TMP/$cse.sigs"
      continue
    fi
    _sig="$(sig_for "$work" "$entry")"
    printf '%s\t%s\n' "$ord" "$_sig" >>"$TMP/$cse.sigs"
    _chk="$(printf '%s' "$_sig" | sed 's/^\(check=[^;]*\);.*/\1/')"
    _esig="$(emit_verdict_for "$work" "$entry")"
    printf '%s;%s\n' "$_chk" "$_esig" >>"$TMP/$cse.emitsigs"
    case "$_esig" in emit=0:ir) echo emitted >>"$TMP/emitwitness" ;; esac
  done

  nord="$(grep -c . "$TMP/$cse.sigs" 2>/dev/null || true)"; [ -n "$nord" ] || nord=0
  if [ "$nord" -eq 0 ]; then
    printf 'FAIL %-52s produced ZERO orderings — the permuter ran nothing\n' "$cse"
    echo FAIL >>"$TMP/verdicts"; continue
  fi
  if grep -q '^PERMUTER-WRITE-FAILED' "$TMP/$cse.sigs"; then
    printf 'FAIL %-52s PERMUTER could not write an ordering: %s\n' "$cse" "$(head -1 "$TMP/$cse.werr")"
    echo FAIL >>"$TMP/verdicts"; continue
  fi

  cut -f2 "$TMP/$cse.sigs" | sort -u >"$TMP/$cse.distinct"
  ndist="$(grep -c . "$TMP/$cse.distinct" 2>/dev/null || true)"; [ -n "$ndist" ] || ndist=0

  # ── the emitter-verdict arm (RUN-XMOD-022/023) — a PARALLEL, independent grading
  #    path, not a mirror of the block below. It runs regardless of whether this
  #    case is ledgered on the check/run/build axis, and it contributes its own
  #    PASS/FAIL to $TMP/verdicts, so it must never `continue` out of this loop.
  if [ -s "$TMP/$cse.emitsigs" ]; then
    sort -u "$TMP/$cse.emitsigs" >"$TMP/$cse.emitdistinct"
    eclass=AGREE
    while IFS= read -r esig; do
      [ -n "$esig" ] || continue
      cexit="$(printf '%s' "$esig" | sed 's/^check=\([^;]*\);.*/\1/')"
      eexit="$(printf '%s' "$esig" | sed 's/.*emit=\([^:]*\):.*/\1/')"
      if [ "$cexit" = 0 ] && [ "$eexit" != 0 ]; then eclass=DISAGREE
      elif [ "$cexit" != 0 ] && [ "$eexit" = 0 ]; then eclass=DISAGREE
      fi
    done <"$TMP/$cse.emitdistinct"

    erow=''
    if [ -f "$EMITTER_LEDGER" ]; then
      erow="$(awk -F'|' -v c="$cse" '!/^[[:space:]]*#/ && NF>=3 {
               k = $1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", k);
               if (k == c) print }' "$EMITTER_LEDGER" | head -1)"
    fi

    if [ -z "$erow" ]; then
      if [ "$eclass" = AGREE ]; then
        : # the common, quiet case — no row needed
      else
        printf 'FAIL %-52s emitter-verdict: DISAGREE, UNLEDGERED — the raw emitter'"'"'s\n' "$cse"
        printf '       accept/reject verdict diverges from check'"'"'s and nobody has pinned it\n'
        {
          printf '  %s: emitter-verdict DISAGREE, unledgered.\n' "$cse"
          printf '     Add a row to test/EMITTER-VERDICT-LEDGER.txt. Observed signature(s):\n'
          while IFS= read -r s; do printf '       %s\n' "$s"; done <"$TMP/$cse.emitdistinct"
          printf '     Row to paste (fill in the reason):\n'
          printf '       %s | DISAGREE | <reason> | %s\n' "$cse" \
            "$(paste -sd'|' "$TMP/$cse.emitdistinct" | sed 's/|/ | /g')"
        } >>"$TMP/notes"
        echo FAIL >>"$TMP/verdicts"
      fi
    else
      erow_class="$(printf '%s' "$erow" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')"
      erow_reason="$(printf '%s' "$erow" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$3); print $3}')"
      printf '%s' "$erow" | awk -F'|' '{for (i=4;i<=NF;i++) {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i); if ($i != "") print $i}}' \
        | sort -u >"$TMP/$cse.epinned"
      if [ "$eclass" = AGREE ]; then
        printf 'FAIL %-52s emitter-verdict: DRAINED — row present but the emitter now agrees\n' "$cse"
        {
          printf '  %s: emitter-verdict has CONVERGED with check. Delete this row from\n' "$cse"
          printf '     test/EMITTER-VERDICT-LEDGER.txt. Observed signature(s):\n'
          while IFS= read -r s; do printf '       %s\n' "$s"; done <"$TMP/$cse.emitdistinct"
        } >>"$TMP/notes"
        echo FAIL >>"$TMP/verdicts"
      elif [ "$erow_class" != "DISAGREE" ]; then
        printf 'FAIL %-52s emitter-verdict: row classification says "%s" but observed is DISAGREE\n' \
          "$cse" "$erow_class"
        echo FAIL >>"$TMP/verdicts"
      elif [ -z "$erow_reason" ] || [ "$erow_reason" = "-" ]; then
        printf 'FAIL %-52s emitter-verdict: row has no reason — a row must say why\n' "$cse"
        echo FAIL >>"$TMP/verdicts"
      elif cmp -s "$TMP/$cse.emitdistinct" "$TMP/$cse.epinned"; then
        printf 'ok   %-52s emitter-verdict: KNOWN-BAD (%s)\n' "$cse" "$erow_reason"
        echo PASS >>"$TMP/verdicts"
      else
        printf 'FAIL %-52s emitter-verdict: pinned set differs from observed\n' "$cse"
        {
          printf '  %s: emitter-verdict pinned set no longer matches observed.\n' "$cse"
          printf '     pinned:\n';   sed 's/^/       /' "$TMP/$cse.epinned"
          printf '     observed:\n'; sed 's/^/       /' "$TMP/$cse.emitdistinct"
        } >>"$TMP/notes"
        echo FAIL >>"$TMP/verdicts"
      fi
    fi
  fi

  # ── the ledger row for this case, if any ──
  row=''
  if [ -f "$LEDGER" ]; then
    # ⚠️ Match on a COPY of field 1. Assigning to `$1` would make awk rebuild `$0`
    # with OFS (a space), so `print` would emit the row with its `|` separators
    # replaced — and every later `-F'|'` parse of it would see one field. That bug
    # was real here and reported as `issue field is ""` on a row that parsed fine
    # everywhere else.
    row="$(awk -F'|' -v c="$cse" '!/^[[:space:]]*#/ && NF>=3 {
             k = $1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", k);
             if (k == c) print }' "$LEDGER" | head -1)"
  fi

  tag=''
  [ "$partial" = "1" ] && tag=' PARTIAL'

  if [ -z "$row" ]; then
    # ── UNLEDGERED: must be invariant ──
    if [ "$ndist" -eq 1 ]; then
      printf 'ok   %-52s %d clause(s), %d ordering(s)%s — invariant\n' "$cse" "$nclauses" "$nord" "$tag"
      echo PASS >>"$TMP/verdicts"
    else
      printf 'FAIL %-52s %d ordering(s) produced %d DISTINCT signatures — the answer depends on import order\n' \
        "$cse" "$nord" "$ndist"
      while IFS= read -r s; do printf '       %s\n' "$s"; done <"$TMP/$cse.distinct"
      {
        printf '  %s: %s\n' "$cse" "$what"
        printf '     Either FIX it, or — if it is a known OPEN bug — add a row to\n'
        printf '     test/IMPORT-ORDER-LEDGER.txt. Read that file'"'"'s header first: a row is a\n'
        printf '     statement that a soundness bug is shipping, not a way to make this green.\n'
      } >>"$TMP/notes"
      echo FAIL >>"$TMP/verdicts"
    fi
    continue
  fi

  # ── LEDGERED: the divergence must still be exactly the pinned one ──
  issue="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')"
  printf '%s' "$row" | awk -F'|' '{for (i=3;i<=NF;i++) {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i); if ($i != "") print $i}}' \
    | sort -u >"$TMP/$cse.pinned"
  npin="$(grep -c . "$TMP/$cse.pinned" 2>/dev/null || true)"; [ -n "$npin" ] || npin=0

  case "$issue" in
    '#'[0-9]*) : ;;
    *)
      printf 'FAIL %-52s ledger row'"'"'s issue field is "%s" — it must be #<number> of an OPEN issue\n' "$cse" "$issue"
      echo FAIL >>"$TMP/verdicts"; continue ;;
  esac
  # A ledgered case must be NAMED after its issue. This is the anti-reflexive-bump
  # lock: you cannot ledger an existing green fixture without RENAMING its directory,
  # which is loud in a diff. See the ledger header.
  num="${issue#\#}"
  case "$cse" in
    "$num"-*) : ;;
    *)
      printf 'FAIL %-52s ledgered against %s but the directory is not named "%s-..."\n' "$cse" "$issue" "$num"
      echo FAIL >>"$TMP/verdicts"; continue ;;
  esac
  if [ "$npin" -lt 2 ]; then
    printf 'FAIL %-52s ledger row pins %d signature(s); a row asserts a DIVERGENCE, so it needs >=2\n' "$cse" "$npin"
    echo FAIL >>"$TMP/verdicts"; continue
  fi

  if [ "$ndist" -eq 1 ]; then
    printf 'FAIL %-52s DRAINED — %s no longer diverges under import-clause permutation\n' "$cse" "$issue"
    {
      printf '  %s: the ledgered divergence for %s has CONVERGED. That is the drain.\n' "$cse" "$issue"
      printf '     1. gh issue close %s --comment "drained: import-order permutation differential is now invariant"\n' "$issue"
      printf '     2. delete the row from test/IMPORT-ORDER-LEDGER.txt\n'
      printf '     3. KEEP the fixture — unledgered, it becomes the regression guard.\n'
      printf '     Observed signature: %s\n' "$(cat "$TMP/$cse.distinct")"
    } >>"$TMP/notes"
    echo FAIL >>"$TMP/verdicts"; continue
  fi

  if cmp -s "$TMP/$cse.distinct" "$TMP/$cse.pinned"; then
    printf 'ok   %-52s %d ordering(s)%s — KNOWN-BAD %s, still diverging exactly as pinned\n' \
      "$cse" "$nord" "$tag" "$issue"
    echo PASS >>"$TMP/verdicts"
  else
    printf 'FAIL %-52s KNOWN-BAD %s: the divergence MOVED — pinned and observed signatures differ\n' "$cse" "$issue"
    {
      printf '  %s: %s pins a specific divergence and the binary now produces a different one.\n' "$cse" "$issue"
      printf '     pinned:\n';   sed 's/^/       /' "$TMP/$cse.pinned"
      printf '     observed:\n'; sed 's/^/       /' "$TMP/$cse.distinct"
      printf '     Re-derive the right answer before re-pinning. A ledger row is evidence, not a knob.\n'
    } >>"$TMP/notes"
    echo FAIL >>"$TMP/verdicts"
  fi
done

# ── the ledger must not name a case that does not exist ──────────────────────
# A ledger entry that outlives its fixture is rot, and rot is how a ledger becomes a
# skip-list. Same rule as test/CI-COVERAGE-EXCEPTIONS.txt's stale-entry check.
if [ -f "$LEDGER" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    c="$(printf '%s' "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); print $1}')"
    [ -n "$c" ] || continue
    if [ ! -d "$FIXDIR/$c" ]; then
      printf 'FAIL ledger names case "%s", which does not exist under test/import_order_fixtures/\n' "$c"
      echo FAIL >>"$TMP/verdicts"
    fi
  done <"$LEDGER"
fi

# ── same rot check, for the emitter-verdict sidecar ledger ───────────────────
if [ -f "$EMITTER_LEDGER" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    c="$(printf '%s' "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); print $1}')"
    [ -n "$c" ] || continue
    if [ ! -d "$FIXDIR/$c" ]; then
      printf 'FAIL emitter-verdict ledger names case "%s", which does not exist under test/import_order_fixtures/\n' "$c"
      echo FAIL >>"$TMP/verdicts"
    fi
  done <"$EMITTER_LEDGER"
fi

# ── tally ────────────────────────────────────────────────────────────────────
# Verdicts go to a FILE, never a variable: the loops above run in a subshell under
# dash and a variable mutated inside one does not survive.
cnt() { c="$(grep -c "^$1\$" "$TMP/verdicts" 2>/dev/null || true)"; [ -n "$c" ] || c=0; echo "$c"; }
pass="$(cnt PASS)"; fail="$(cnt FAIL)"
total=$((pass+fail))

if [ -s "$TMP/notes" ]; then
  echo
  echo 'what each failing row means:'
  cat "$TMP/notes"
fi

echo
# A ledgered row is a soundness bug shipping on main. Print them EVERY run, named, so
# the ledger is never invisible background furniture — the state a ledger rots into.
if [ -f "$LEDGER" ]; then
  nrows="$(grep -cvE '^[[:space:]]*(#|$)' "$LEDGER" 2>/dev/null || true)"; [ -n "$nrows" ] || nrows=0
  if [ "$nrows" -gt 0 ]; then
    echo "LEDGERED — order-dependence bugs shipping on main right now:"
    grep -vE '^[[:space:]]*(#|$)' "$LEDGER" \
      | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2);
                    printf "  %-52s %s\n", $1, $2}'
    echo "  (each drains itself: when the divergence collapses, its row goes RED here)"
    echo
  fi
fi

# Same visibility rule for the emitter-verdict sidecar — a MEASURED disagreement,
# not a correctness claim (the emitter is the party this sprint has measured to be
# WRONG on at least the #1667 shape; see test/EMITTER-VERDICT-LEDGER.txt's header).
if [ -f "$EMITTER_LEDGER" ]; then
  enrows="$(grep -cvE '^[[:space:]]*(#|$)' "$EMITTER_LEDGER" 2>/dev/null || true)"; [ -n "$enrows" ] || enrows=0
  if [ "$enrows" -gt 0 ]; then
    echo "LEDGERED (emitter-verdict) — driver disagreements known and pinned right now:"
    grep -vE '^[[:space:]]*(#|$)' "$EMITTER_LEDGER" \
      | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2);
                    printf "  %-52s %s\n", $1, $2}'
    echo "  (each drains itself: when the emitter agrees again, its row goes RED here)"
    echo
  fi
fi

# F4/item 6 (correction round, RUN-XMOD-041): $total counts VERDICT lines, not
# fixture directories — the emitter-verdict arm appends its own PASS/FAIL onto
# $TMP/verdicts for every DISAGREE case (on top of the pre-existing check/run/build
# verdict every case gets), so $total now exceeds the directory count whenever any
# ledgered DISAGREE row exists. Pre-slice the two numbers coincided; print both so
# a shrunk corpus is still legible from the tally alone.
ncases=0
for _c in $cases; do ncases=$((ncases+1)); done
printf '%s: %d verdict(s) over %d case(s) — %d ok, %d failing\n' \
  "$(basename "$0")" "$total" "$ncases" "$pass" "$fail"

# ⚠️ AN EMPTY RUN IS A FAILURE, NOT A PASS. A gate that can silently no-op will:
# every wasm gate in this tree once shelled out to an absent tool, printed "skipping"
# and exited 0, so a required tandem gate had never once run. "Green" is not "ran".
if [ "$total" -eq 0 ]; then
  echo "FAIL: graded ZERO cases — the corpus derivation found nothing. This is not a pass." >&2
  exit 1
fi
# Same rule one level down: the `build` verb must have produced at least one binary
# somewhere in the corpus. Zero means `medaka build` failed everywhere, which makes
# the build arm compare equal for every case and grade nothing — indistinguishable
# from a clean run unless it is checked.
if [ ! -s "$TMP/builtwitness" ]; then
  echo "FAIL: the BUILD arm produced no executable anywhere in the corpus — it graded" >&2
  echo "      nothing, and an arm that graded nothing must not report green." >&2
  exit 1
fi
# Same rule for the emitter-verdict arm: if no ordering anywhere in the corpus ever
# produced emit=0:ir, the raw emitter never once succeeded, and every signature
# would be a same-shaped failure — indistinguishable from "the arm never ran".
if [ ! -s "$TMP/emitwitness" ]; then
  echo "FAIL: the EMITTER-VERDICT arm never observed emit=0:ir anywhere in the corpus —" >&2
  echo "      it graded nothing, and an arm that graded nothing must not report green." >&2
  exit 1
fi

[ "$fail" -eq 0 ]
