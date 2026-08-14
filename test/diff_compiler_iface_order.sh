#!/bin/sh
# diff_compiler_iface_order.sh — the INTERFACE-DECLARATION PERMUTATION DIFFERENTIAL.
#
# G-0 of the Stage B sprint. It is a VERIFICATION INSTRUMENT, not a fix: it exists to
# be able to distinguish outcomes that every other gate in this tree collapses.
#
# ── THE AXIS, AND WHY NOTHING ELSE COVERS IT ─────────────────────────────────
# Three permutation differentials already exist here and NONE moves this axis:
#
#   * test/diff_compiler_import_order.sh  permutes the entry's IMPORT CLAUSES.
#   * test/diff_compiler_dict_semantics.sh Section 4 permutes `impl` BLOCKS.
#   * test/must_fail_fixtures/1182-two-ifaces-same-method-name-order-decides/
#     spends its control slot on the second `impl`-block ORDER.
#
# This gate permutes the `interface` DECLARATIONS THEMSELVES and leaves impls,
# imports and data declarations exactly where they are. Derive that the axis is new:
#
#   grep -rn 'interface' test/diff_compiler_import_order.sh test/diff_compiler_dict_semantics.sh
#
# ⭐ WHY THIS AXIS, SPECIFICALLY, AND WHY NOW.
# The Stage B fix (units S and Q) re-keys impl selection from an interface SPELLING to
# an interface IDENTITY. There is a trap in that: a fix that scopes by NAME drains
# #1182's existing pin -- the impl-order dependence goes away -- while merely MOVING
# the order dependence onto the interface-declaration order. The existing pins cannot
# tell those two outcomes apart, because none of them moves this axis. This gate can.
# See the FOUR-STATE TABLE below, which is the reason it was built.
#
# ── PRIOR ART; THIS GATE IS test/diff_compiler_import_order.sh, RE-AIMED ─────
# The chunk permuter, the signature shape, the escaping, the ledger-as-self-draining-
# known-bad idea, the empty-run-is-a-failure rule and the build-arm witness are all
# taken from that gate wholesale and are its design, not this one's. Two things differ:
#   * it selects IMPORT chunks; this selects INTERFACE chunks;
#   * its corpus is directories of modules because import-order defects are
#     multi-module by nature; every defect on THIS axis that is tracked today is
#     SINGLE-FILE (#1182, #1620, and the flip transcribed in compiler/types/
#     typecheck.mdk), so a case here is normally one `main.mdk`. The directory-plus-
#     `case.txt` unit is kept anyway: it is what the ledger's issue-number naming lock
#     hangs off, and it leaves room for a multi-module case later.
#
# ###################################################################
# # THE INVARIANCE CRITERION — WHAT MUST BE EQUAL ACROSS ORDERINGS  #
# ###################################################################
# Every ordering of the entry's `interface` declarations is compiled and run, and
# reduced to a one-line SIGNATURE. The signature is what must be invariant:
#
#   check=<exit>;codes=<sorted,comma>;schemes=<check stdout>;run=<exit>:<stdout>;build=<exit>/<exec-exit>:<stdout>
#
#   check=  `medaka check --json` exit code. THE VERDICT CELL. On this axis it is not
#           a formality: the flip transcribed into
#           test/iface_order_fixtures/1182-unimplemented-iface-obligation-iface-order/
#           is ACCEPT vs REJECT, not two different values.
#   codes=  every `"code":"..."` in `check --json`, SORTED, as a multiset. Sorted
#           because diagnostics come out in source order and permutation moves source
#           lines. THIS CELL IS WHAT SEPARATES STATE 3 FROM STATE 4 below — but read it
#           by CODE PREFIX, not by emptiness: a fix that REJECTS the ambiguity converges
#           on an `R-*` (resolve-stage) code; a fix that merely SELECTS deterministically
#           converges on NO code, or on a `T-*` (type-stage) one when the selected impl
#           then fails to typecheck. `check=1` alone does NOT mean state 3.
#   schemes= plain `medaka check`'s scheme dump, selected by FORMAT (`<name> : <type>`
#           at column 0) rather than by stream. ⚠️ Diagnostics are NOT reliably on
#           stderr -- import_order.sh measured resolve-stage diagnostics on stderr and
#           TYPE-stage ones on STDOUT, so a whole-stdout capture would paste this
#           harness's own mktemp path into a signature. Selecting by format is that
#           gate's fix and is inherited here unchanged. What it buys: exit 0, same
#           printed value, but a binding INFERRED AT A DIFFERENT TYPE -- which is what
#           "a different interface won" looks like when the values coincide.
#   run=    `medaka run` exit code and STDOUT (the interpreter).
#   build=  `medaka build` exit code, then the built binary's exit code and STDOUT
#           (`-` if no binary was produced). NOT redundant with `run` on this corpus:
#           #1620's reversed ordering is reported to reach `check` 0 / `build` 0 and
#           then SEGFAULT the built binary at exit 139 while the interpreter E-PANICs,
#           so the two engines genuinely disagree and the `<exec-exit>` cell is the
#           only place a 139 can be recorded at all.
#
# ── WHAT IS DELIBERATELY NOT COMPARED ────────────────────────────────────────
# A criterion comparing too little passes everything; one comparing too much turns
# correct behaviour into a false red. Excluded, each inherited with its reason from
# import_order.sh: DIAGNOSTIC MESSAGE TEXT (may enumerate declarations in source
# order on purpose); DIAGNOSTIC RANGES (permuting declarations of unequal line count
# moves every line below them, so a location diff is a pure artifact); STDERR of
# `run`/`build` (panics are not uniformly location-free and build's log embeds the
# source path); THE ORDER of diagnostics (hence the sort); THE EMITTED IR (which impl
# was selected is observed BEHAVIOURALLY; `medaka build --keep-ir` is the tool if a
# future row needs a stronger probe).
#
# ── SCOPE LIMITS, SAID OUT LOUD ──────────────────────────────────────────────
#   * Only the ENTRY module's `interface` declarations are permuted. A defect decided
#     by an IMPORTED module's interface order is NOT covered here, and nothing else
#     covers it either.
#   * Interface declarations are permuted among THEIR OWN original slots, so one never
#     moves across an `impl` or a `data`. An order sensitivity that needs an interface
#     to move past a `data` is out of scope BY CONSTRUCTION -- and that is deliberate,
#     because such a move can change whether a program parses/scopes at all, which is
#     not the cosmetic reordering this gate is about.
#   * All n! orderings are tried when n <= 4. Above that the gate falls back to
#     identity + reversal + every adjacent transposition and PRINTS `PARTIAL` on the
#     row, so a shrunken permutation set can never look like a full one.
#
# ###################################################################
# # ⭐ THE FOUR-STATE TABLE — WHAT THIS GATE READS IN EACH FUTURE   #
# ###################################################################
# This is the deliverable. A probe that only answered "same/different" would collapse
# states 2 and 3, which is precisely the confusion the Stage B fix is at risk of.
#
#   STATE 1 — TODAY (order-dependent on BOTH axes).
#     #1182's must-fail pin: RED-if-fixed, currently green (bug reproduces).
#     THIS GATE: ledgered rows report `KNOWN-BAD #NNNN, still diverging exactly as
#     pinned`, and the LEDGERED banner names them on every run.
#
#   STATE 2 — A NAME-SCOPED FIX (the shallow one; the trap).
#     #1182's must-fail pin DRAINS -- impl-block order no longer decides -- and a
#     reader with only that pin concludes #1182 is fixed and closes it.
#     THIS GATE: the ledgered rows STILL DIVERGE. If the signatures are unchanged the
#     row stays `KNOWN-BAD ... still diverging` and the LEDGERED banner keeps printing
#     it; if the divergence moved at all the row goes RED with `the divergence MOVED`,
#     forcing re-derivation. Either way the axis is still visibly live.
#     ⚠️ THIS IS THE ONE STATE IN WHICH THIS GATE DOES NOT GO RED BY ITSELF. Its
#     backstop is that the ledger rows NAME #1182, and test/must_fail_census.sh
#     (nightly, has the GitHub API) reports a ledgered issue that has been CLOSED. So
#     closing #1182 on a name-scoped fix reds the census. Do not remove that coupling.
#
#   STATE 3 — Q1 LANDED (resolve REJECTS the ambiguous occurrence).
#     THIS GATE: the case converges to ONE signature and the row goes RED as
#     `DRAINED`, printing the observed signature. That signature reads
#     `check=1;codes=<some R-* code>;...` in EVERY ordering -- a nonzero verdict WITH a
#     diagnostic code.
#
#   STATE 4 — S1 ALONE (identity-keyed selection, no resolve rejection).
#     THIS GATE: also converges to ONE signature, also RED as `DRAINED` -- but the
#     observed signature carries NO `R-*` code. Two sub-shapes, BOTH state 4:
#       * `check=0;codes=;...` with a stable value in `run=`/`build=` -- the selected
#         impl typechecks and the program runs.
#       * `check=1;codes=T-*;...` -- selection WAS deterministic, and the impl it
#         deterministically chose then failed TYPECHECK. Concretely: the
#         1182-unimplemented-iface-obligation-iface-order case declares only
#         `impl FA Blob`, so an S1-alone fix that binds `mth` to FB converges on
#         `check=1;codes=T-NO-IMPL` in every ordering. That is a type error, NOT an
#         ambiguity rejection, and it must not be read as state 3.
#     ⇒ THE DISCRIMINATOR IS THE CODE PREFIX, not the exit code and not whether
#       `codes=` is non-empty: `R-*` (resolve) => state 3; `T-*` or empty => state 4.
#       An exit-code-only criterion would not have done, and neither would a
#       merely-non-empty-`codes=` one -- see this corpus's OWN #1182 ledger row,
#       which already pins a `check=1;codes=T-NO-IMPL` signature today.
#
#   In states 3 and 4 the gate prints the converged signature in its drain note, so
#   the reader distinguishes them from the gate's own output without re-deriving.
#
# ###################################################################
# # THE LEDGER — WHY A GATE MEASURING AN OPEN DEFECT IS GREEN       #
# ###################################################################
# ⚠️ READ THIS BEFORE "FIXING" A GREEN OR A RED HERE.
#
# The cases ledgered in test/IFACE-ORDER-LEDGER.txt ARE order-dependent today; that is
# the whole point of the corpus. This gate is nonetheless GREEN on today's tree, for
# the reason test/IMPORT-ORDER-LEDGER.txt's header already gives about its own
# ledger -- "a gate that lands red breaks `main` and teaches people to ignore it. The
# rows are what keep the green honest."
#
# A row pins EVERY DISTINCT SIGNATURE its case produces and requires there to be MORE
# THAN ONE, so the green is not a claim that the defect is absent. It is a claim that
# the defect is present, IN EXACTLY THIS SHAPE, and it self-drains in four directions:
#
#   * an UNLEDGERED case that produces two signatures  -> FAIL (a new bug, or a
#                                                         control that must not move)
#   * a LEDGERED case that collapses to ONE signature  -> FAIL, naming the issue
#                                                         (states 3 and 4; the drain)
#   * a LEDGERED case whose signatures no longer match -> FAIL (the bug moved)
#   * a ledger row naming a case that does not exist   -> FAIL (rot)
#
# ⚠️ This gate is OFFLINE — it never contacts the GitHub API, because it runs on every
# dev box under preflight and in a required CI shard, where a rate limit or a fork's
# restricted token must never block a merge. So it CANNOT check that a ledgered issue
# is still OPEN. That half lives in test/must_fail_census.sh (nightly, has the API),
# and per STATE 2 above it is load-bearing here, not decorative.
#
# Usage:  sh test/diff_compiler_iface_order.sh
# Exit:   0 every case is invariant or ledgered-and-still-diverging; 1 otherwise;
#         2 infrastructure (no binary, no emitter, no corpus, no perl).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/iface_order_fixtures"
LEDGER="$ROOT/test/IFACE-ORDER-LEDGER.txt"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -d "$FIXDIR" ] || { echo "missing fixture dir: $FIXDIR"; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "perl not found (needed for the permuter)"; exit 2; }

# The `build` arm needs the native emitter. Resolved and exported explicitly, the same
# way test/diff_compiler_import_order.sh does — the CI gate-shard step does not export
# it, and a gate that relies on a default lookup is one refactor away from silently
# grading only two of its three verbs.
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
[ -x "$EMITTER" ] || { echo "missing native emitter: $EMITTER (make medaka)"; exit 2; }
export MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER"

# Every invocation is bounded. A regression that makes one ORDERING loop must surface
# as a row failure, not as a hung CI job. 120s covers a `medaka build` + clang.
#
# ⚠️ NOT `timeout`. That is coreutils and does not exist on macOS, and every script
# here must run on both platforms while all 11 CI jobs are ubuntu-latest — so a
# macOS-only break would ship with every check green. This is the portable shim from
# test/diff_compiler_engines.sh. It is NOT a drop-in: it is killed by SIGALRM, so the
# shell reports 142 (128+14) where `timeout` reports 124. Nothing here compares
# against either number — a timeout simply becomes part of the signature and shows up
# as a divergence — so the difference is recorded rather than depended on.
bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/verdicts"
: >"$TMP/builtwitness"
: >"$TMP/notes"

# ── the permuter ─────────────────────────────────────────────────────────────
# Operates on TOP-LEVEL CHUNKS, exactly as import_order.sh's and dict_semantics' do: a
# chunk starts at any line with a non-whitespace character in column 0 (the offside
# rule puts every top-level declaration there) and runs until the next such line, so
# an indented method signature or a blank line attaches to the chunk above it. That is
# what makes a whole `interface X a where / <sigs>` block move as ONE unit — which is
# the entire correctness requirement for this permuter, since an interface body is
# always indented and would otherwise be orphaned onto whatever chunk preceded it.
#
# Chunks whose FIRST line is an interface declaration are permuted across THEIR OWN
# slots; every other chunk stays exactly where it was. Prefixes are derived, not
# guessed: `grep -rhoE '^(public +)?(export +)?interface ' stdlib/ compiler/` finds
# `interface` and `export interface` in the tree today; `public export` is accepted
# too because the constructor-export qualifier documented in AGENTS.md takes that
# form and a future interface may.
#
# If a permuted file fails to PARSE where the original did, that is a permuter bug,
# not a compiler finding.
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
    my $is_iface = ($line =~ /^(?:public\s+)?(?:export\s+)?interface\s/) ? 1 : 0;
    $cur = { ifc => $is_iface, lines => [$line] };
  } else {
    $cur = { ifc => 0, lines => [] } if !$cur;
    push @{$cur->{lines}}, $line;
  }
}
push @chunks, $cur if $cur;

my @idx = grep { $chunks[$_]{ifc} } 0..$#chunks;
my $n = scalar(@idx);
die "need >=2 top-level interface declarations, found $n\n" if $n < 2;

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
# `;` (the signature's own separator) can appear in a program's stdout. The escape is
# applied to the OBSERVED output only, and the ledger stores the ESCAPED form — so the
# gate never unescapes anything, it compares escaped strings. That keeps the mapping
# injective without a parser: \ -> \\ , | -> \p , ; -> \s , newline -> \n.
esc() { perl -0777 -pe 's/\\/\\\\/g; s/\|/\\p/g; s/;/\\s/g; s/\n/\\n/g' "$1"; }

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
  # Scheme lines selected by FORMAT (`<binding> : <type>` at column 0), never by
  # stream — see the header. A diagnostic line cannot match: it begins with a path, a
  # digit or the `  |` gutter. Known limit, inherited: a scheme wrapped onto a
  # continuation line loses its tail.
  bound "$MEDAKA" check "$_work/$_entry" >"$_work/.chkout" 2>/dev/null
  grep -E "^[A-Za-z_][A-Za-z0-9_']* : " "$_work/.chkout" >"$_work/.schemes" 2>/dev/null || :
  _s="$(esc "$_work/.schemes")"
  bound "$MEDAKA" run "$_work/$_entry" >"$_work/.run.out" 2>"$_work/.run.err"
  _r=$?
  _ro="$(esc "$_work/.run.out")"
  # ⚠️ REDIRECTED, NOT PIPED. `medaka build`'s exit code does not survive a pipe — a
  # `| tail` would report tail's status and a failing build would read as exit 0.
  bound "$MEDAKA" build "$_work/$_entry" -o "$_work/.bin" >"$_work/.build.log" 2>&1
  _b=$?
  if [ "$_b" -eq 0 ] && [ -x "$_work/.bin" ]; then
    bound "$_work/.bin" >"$_work/.exec.out" 2>"$_work/.exec.err"
    _x=$?
    _bo="$(esc "$_work/.exec.out")"
    # Witness that the build arm actually built something at least once. If
    # `medaka build` were broken for every ordering of every case, every signature
    # would carry `build=1/-:` and every row would still compare EQUAL — a green gate
    # whose third verb graded nothing. The tally refuses that below.
    echo built >>"$TMP/builtwitness"
  else
    _x='-'
    _bo=''
  fi
  printf 'check=%s;codes=%s;schemes=%s;run=%s:%s;build=%s/%s:%s\n' \
    "$_c" "$_codes" "$_s" "$_r" "$_ro" "$_b" "$_x" "$_bo"
}

echo "INTERFACE-DECLARATION PERMUTATION DIFFERENTIAL — the answer must not depend on"
echo "the order in which two interfaces were declared."
echo "corpus: test/iface_order_fixtures   ledger: test/IFACE-ORDER-LEDGER.txt"
echo

for cse in $cases; do
  cdir="$FIXDIR/$cse"
  spec="$cdir/case.txt"

  if [ ! -f "$spec" ]; then
    printf 'FAIL %-56s no case.txt (a case directory must declare its entry)\n' "$cse"
    echo FAIL >>"$TMP/verdicts"; continue
  fi
  entry="$(sed -n 's/^entry:[[:space:]]*//p' "$spec" | head -1)"
  what="$(sed -n 's/^what:[[:space:]]*//p' "$spec" | head -1)"
  if [ -z "$entry" ] || [ ! -f "$cdir/$entry" ]; then
    printf 'FAIL %-56s case.txt names entry "%s", which is not a file here\n' "$cse" "$entry"
    echo FAIL >>"$TMP/verdicts"; continue
  fi

  if ! perl "$PERMPL" "$cdir/$entry" LIST >"$TMP/$cse.orders" 2>"$TMP/$cse.err"; then
    printf 'FAIL %-56s PERMUTER: %s\n' "$cse" "$(head -1 "$TMP/$cse.err")"
    echo FAIL >>"$TMP/verdicts"; continue
  fi
  head1="$(head -1 "$TMP/$cse.orders")"
  nifaces="$(printf '%s' "$head1" | sed 's/^n=\([0-9]*\).*/\1/')"
  partial="$(printf '%s' "$head1" | sed 's/.*partial=\([0-9]*\).*/\1/')"

  : >"$TMP/$cse.sigs"
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
    printf '%s\t%s\n' "$ord" "$(sig_for "$work" "$entry")" >>"$TMP/$cse.sigs"
  done

  nord="$(grep -c . "$TMP/$cse.sigs" 2>/dev/null || true)"; [ -n "$nord" ] || nord=0
  if [ "$nord" -eq 0 ]; then
    printf 'FAIL %-56s produced ZERO orderings — the permuter ran nothing\n' "$cse"
    echo FAIL >>"$TMP/verdicts"; continue
  fi
  if grep -q '^PERMUTER-WRITE-FAILED' "$TMP/$cse.sigs"; then
    printf 'FAIL %-56s PERMUTER could not write an ordering: %s\n' "$cse" "$(head -1 "$TMP/$cse.werr")"
    echo FAIL >>"$TMP/verdicts"; continue
  fi

  cut -f2 "$TMP/$cse.sigs" | sort -u >"$TMP/$cse.distinct"
  ndist="$(grep -c . "$TMP/$cse.distinct" 2>/dev/null || true)"; [ -n "$ndist" ] || ndist=0

  # ── the ledger row for this case, if any ──
  row=''
  if [ -f "$LEDGER" ]; then
    # ⚠️ Match on a COPY of field 1. Assigning to `$1` would make awk rebuild `$0` with
    # OFS (a space), so `print` would emit the row with its `|` separators replaced,
    # and every later `-F'|'` parse would see one field. That bug was real in
    # import_order.sh and reported as `issue field is ""` on a row that parsed fine
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
      printf 'ok   %-56s %d interface(s), %d ordering(s)%s — invariant\n' "$cse" "$nifaces" "$nord" "$tag"
      echo PASS >>"$TMP/verdicts"
    else
      printf 'FAIL %-56s %d ordering(s) produced %d DISTINCT signatures — the answer depends on interface-declaration order\n' \
        "$cse" "$nord" "$ndist"
      while IFS= read -r s; do printf '       %s\n' "$s"; done <"$TMP/$cse.distinct"
      {
        printf '  %s: %s\n' "$cse" "$what"
        printf '     Either FIX it, or — if it is a known OPEN bug — add a row to\n'
        printf '     test/IFACE-ORDER-LEDGER.txt. Read that file'"'"'s header first: a row is a\n'
        printf '     statement that a soundness bug is shipping, not a way to make this green.\n'
        printf '     ⚠️ If this case is one of the CONTROLS, do NOT ledger it. A control that\n'
        printf '     moves means the finding is much larger than the ledgered rows claim —\n'
        printf '     see the control'"'"'s own header comment for what it would then mean.\n'
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
      printf 'FAIL %-56s ledger row'"'"'s issue field is "%s" — it must be #<number> of an OPEN issue\n' "$cse" "$issue"
      echo FAIL >>"$TMP/verdicts"; continue ;;
  esac
  # A ledgered case must be NAMED after its issue. This is the anti-reflexive-bump
  # lock: you cannot ledger an existing green fixture without RENAMING its directory,
  # which is loud in a diff. See the ledger header.
  num="${issue#\#}"
  case "$cse" in
    "$num"-*) : ;;
    *)
      printf 'FAIL %-56s ledgered against %s but the directory is not named "%s-..."\n' "$cse" "$issue" "$num"
      echo FAIL >>"$TMP/verdicts"; continue ;;
  esac
  if [ "$npin" -lt 2 ]; then
    printf 'FAIL %-56s ledger row pins %d signature(s); a row asserts a DIVERGENCE, so it needs >=2\n' "$cse" "$npin"
    echo FAIL >>"$TMP/verdicts"; continue
  fi

  if [ "$ndist" -eq 1 ]; then
    printf 'FAIL %-56s DRAINED — %s no longer diverges under interface-declaration permutation\n' "$cse" "$issue"
    {
      printf '  %s: the ledgered divergence for %s has CONVERGED. That is the drain.\n' "$cse" "$issue"
      printf '     Observed signature: %s\n' "$(cat "$TMP/$cse.distinct")"
      printf '     ⭐ READ THE CONVERGED SIGNATURE BEFORE ACTING — it says WHICH fix landed,\n'
      printf '     and the two answers are not interchangeable (gate header, FOUR-STATE TABLE):\n'
      printf '       check=1 with an R-* code     -> the ambiguity is now REJECTED at the\n'
      printf '                                       RESOLVE stage (state 3).\n'
      printf '       check=0 with codes= EMPTY    -> selection is now deterministic and the\n'
      printf '                                       program still compiles (state 4). Confirm\n'
      printf '                                       the value in run=/build= is the one the\n'
      printf '                                       fix INTENDED, not merely a stable one.\n'
      printf '       check=1 with a T-* code      -> ALSO state 4, NOT state 3. Deterministic\n'
      printf '                                       selection that then fails TYPECHECK. The\n'
      printf '                                       1182-unimplemented-... case declares only\n'
      printf '                                       `impl FA Blob`, so an S1-alone fix binding\n'
      printf '                                       deterministically to FB converges on\n'
      printf '                                       check=1;codes=T-NO-IMPL. Reading that as\n'
      printf '                                       state 3 would credit a resolve rejection\n'
      printf '                                       that never landed.\n'
      printf '     ⇒ THE DISCRIMINATOR IS THE CODE PREFIX, NOT merely whether codes= is\n'
      printf '       non-empty: R-* (resolve) = state 3; T-* (type) or empty = state 4.\n'
      printf '     ⚠️ Convergence alone does NOT establish that %s is fully fixed. A fix scoped\n' "$issue"
      printf '     by interface NAME can drain one axis and leave another; that is why this\n'
      printf '     corpus exists alongside the impl-order pins. Check the sibling axes too:\n'
      printf '       test/must_fail_fixtures/1182-two-ifaces-same-method-name-order-decides/\n'
      printf '       test/diff_compiler_dict_semantics.sh (Section 4, impl-block permutation)\n'
      printf '     Then: 1. close %s  2. DELETE the row from test/IFACE-ORDER-LEDGER.txt\n' "$issue"
      printf '           3. KEEP the fixture — unledgered, it becomes the regression guard.\n'
    } >>"$TMP/notes"
    echo FAIL >>"$TMP/verdicts"; continue
  fi

  if cmp -s "$TMP/$cse.distinct" "$TMP/$cse.pinned"; then
    printf 'ok   %-56s %d ordering(s)%s — KNOWN-BAD %s, still diverging exactly as pinned\n' \
      "$cse" "$nord" "$tag" "$issue"
    echo PASS >>"$TMP/verdicts"
  else
    printf 'FAIL %-56s KNOWN-BAD %s: the divergence MOVED — pinned and observed signatures differ\n' "$cse" "$issue"
    {
      printf '  %s: %s pins a specific divergence and the binary now produces a different one.\n' "$cse" "$issue"
      printf '     pinned:\n';   sed 's/^/       /' "$TMP/$cse.pinned"
      printf '     observed:\n'; sed 's/^/       /' "$TMP/$cse.distinct"
      printf '     Re-derive the right answer before re-pinning. A ledger row is evidence, not a knob.\n'
      printf '     ⚠️ STILL DIVERGENT IS NOT FIXED. If a Stage B unit just landed, a MOVED (rather\n'
      printf '     than drained) divergence is the signature of a partial fix — see the gate\n'
      printf '     header, FOUR-STATE TABLE, state 2.\n'
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
      printf 'FAIL ledger names case "%s", which does not exist under test/iface_order_fixtures/\n' "$c"
      echo FAIL >>"$TMP/verdicts"
    fi
  done <"$LEDGER"
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
    echo "LEDGERED — interface-declaration-order bugs shipping on main right now:"
    grep -vE '^[[:space:]]*(#|$)' "$LEDGER" \
      | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2);
                    printf "  %-56s %s\n", $1, $2}'
    echo "  (each drains itself: when the divergence collapses, its row goes RED here)"
    echo
  fi
fi

printf '%s: %d case(s) — %d ok, %d failing\n' "$(basename "$0")" "$total" "$pass" "$fail"

# ⚠️ AN EMPTY RUN IS A FAILURE, NOT A PASS. A gate that can silently no-op will: every
# wasm gate in this tree once shelled out to an absent tool, printed "skipping" and
# exited 0, so a required tandem gate had never once run. "Green" is not "ran".
if [ "$total" -eq 0 ]; then
  echo "FAIL: graded ZERO cases — the corpus derivation found nothing. This is not a pass." >&2
  exit 1
fi
# Same rule one level down: the `build` verb must have produced at least one binary
# somewhere in the corpus. Zero means `medaka build` failed everywhere, which makes the
# build arm compare equal for every case and grade nothing — indistinguishable from a
# clean run unless it is checked.
if [ ! -s "$TMP/builtwitness" ]; then
  echo "FAIL: the BUILD arm produced no executable anywhere in the corpus — it graded" >&2
  echo "      nothing, and an arm that graded nothing must not report green." >&2
  exit 1
fi

[ "$fail" -eq 0 ]
