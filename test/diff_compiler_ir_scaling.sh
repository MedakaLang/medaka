#!/bin/sh
# diff_compiler_ir_scaling.sh — the DETERMINISTIC superlinearity detector for
# `medaka check`, measured in Cachegrind INSTRUCTION COUNTS (`Ir`).
#
# This gate is the PRIMARY superlinearity signal for the `check` pipeline.
# ⚠️ It ADDS a deterministic signal; it does NOT demote anything.
# test/diff_compiler_perf_scaling.sh is untouched by this gate's introduction:
# its allocation and op-count arms stay, and its WALL-CLOCK arm remains a HARD
# GATE there — `time_bad=1` still increments `fail` (grep `time_bad`). Ir does
# cover wall-clock's distinguishing class (a pure O(n^2) scan that allocates
# nothing) WITHOUT wall-clock's machinery — no min-of-K, no heap pinning, no
# 200 ms floor, and no box-vs-CI disagreement (#1879 / G10) — so demoting that
# arm is a plausible FUTURE change, but it is a separate, riskier one and has
# not been made. Do not read this header as having made it.
#
# ── WHY Ir (issue #2045) ──────────────────────────────────────────────────────
#
# rustc-perf, SQLite and GHC all landed on instruction counts for the same
# reason: they are repeatable to ~6-7 significant digits where wall-clock is
# scarcely repeatable to one. Measured on THIS repo's binary, `medaka check` on a
# one-line program, three identical runs:
#
#     1 904 063 101 / 1 904 075 814 / 1 904 073 182   -> spread 0.00067%
#
# ⚠️ THAT NUMBER IS THE UNPINNED ONE, AND IT UNDERSTATES THE SPREAD. Measured
# here at 5 runs rather than 3, `medaka check` on the same one-line program is
# BIMODAL with the GC heap left to grow on its own:
#
#     1 893 499 537 / 1 851 962 901 / 1 851 962 148 / 1 851 940 047 / 1 893 483 939
#
# — two tight clusters 2.2% apart, not a 0.0007% jitter. It is the GC HEAP-RESIZE
# STEP, the same artefact diff_compiler_perf_scaling.sh's rule 2 pins out of its
# wall-clock arm, and it lands squarely on the FLOOR term this gate subtracts
# (see below), where a 2.2% wobble on a ~1.9e9 floor moves a ratio by several
# percent.
#
# 🚨 SO EVERY MEASURED RUN HERE PINS THE HEAP: GC_INITIAL_HEAP_SIZE=2147483648.
# With it, `Ir` is not merely repeatable, it is essentially EXACT — measured, 5
# runs each, this box:
#
#     hello      1775966302 x4, 1775966406 x1   spread 104 Ir  = 0.0000059%
#     xref@500   3672941483 x5                  BIT-IDENTICAL
#
# That is ~9 significant digits, two to three orders better than the unpinned
# figure the adoption issue reports. AGENTS.md [G-PARALLELISM] records that this
# knob cannot change emitted IR (it is a runtime allocator setting), so pinning it
# buys determinism at no cost to what is being measured.
#
# Because a single run is exact, there is NO min-of-K here and there must not be
# one: samples would buy nothing and multiply an already 20x-slowed measurement
# by K. The threshold is still a wide RATIO band rather than an exact-count
# comparison — the residual 104-Ir wobble is real, and more importantly a
# same-source `Ir` total legitimately moves with clang version and libc, so exact
# equality against a committed number would be a permanent false-red generator.
#
# `--cache-sim=no --branch-sim=no` (the same flags rustc-perf uses) keeps the
# slowdown to ~20x native rather than the usual 50-100x, which is what makes a
# per-PR gate over small-N fixtures affordable at all.
#
# ⚠️ WHAT Ir DOES NOT SEE. It is blind to cache behaviour, branch misprediction,
# memory latency, GC pause behaviour and RSS — and to everything happening inside
# `clang`, which is where `medaka build` time actually goes. It is the right
# primary metric for `check`. It is NOT a replacement for the allocation arm of
# perf_scaling (which grades `build`-side stages), and it is not a GC-pressure
# axis (#124 / #2038 still need their own).
#
# ── THE METRIC: NET Ir, PER SHAPE ────────────────────────────────────────────
#
# 🚨 THE FIXED PRELUDE COST DILUTES EVERY RATIO AND MUST BE NETTED OUT.
# `medaka check` spends ~1.9e9 `Ir` on the prelude before it touches a single
# byte of user code. Left in, that constant drags every ratio toward 1.0 and the
# gate systematically UNDER-REPORTS: issue #2045 measured a REAL quadratic
# (#2044) reading only 1.34 -> 1.76 per doubling on RAW `Ir` while the same data
# netted reads ~4.6 -> ~3.3. A gate graded on raw `Ir` would have called that
# quadratic "linear" twice over.
#
# So every ratio here is computed on NET Ir:
#
#     net(N)  = Ir(shape at N)  -  Ir(shape at FLOOR_N)
#     r1 = net(2N)/net(N)      r2 = net(4N)/net(2N)
#
# 🚨 THE FLOOR IS THE SHAPE'S OWN GENERATOR AT A NEGLIGIBLE N — *NOT* a shared
# `main = println 1` baseline. This is not a stylistic choice; a shared baseline
# is WRONG for any corpus that does not typecheck cleanly, and wrong in the
# direction that hides bugs. Measured first-hand on this box, at the base of this
# slice, against #2044's ERR corpus (N bindings each with exactly one type
# error):
#
#     shared `main = println 1` baseline .......... 1 877 182 958 Ir
#     ERR corpus, N=100 ........................... 1 206 866 385 Ir   (LOWER!)
#     => net(100) = -670 316 573  — NEGATIVE, and every ratio meaningless
#
# A program with diagnostics SHORT-CIRCUITS downstream stages, so it does not pay
# the same fixed cost a clean program does. The "floor" is a property of the
# DIAGNOSTIC REGIME, not of the compiler. Taking the floor from the same
# generator at FLOOR_N keeps the floor inside the shape's own regime, and it fixed
# exactly that corpus (heap-pinned, per the block above):
#
#     ERR floor (same generator, N=1) ............... 888 130 068 Ir
#     ERR N=400/800/1600 net .. 1.677e9 / 5.470e9 / 19.709e9 -> r1 3.261  r2 3.603
#
# i.e. with the per-shape floor this gate FIRES on #2044, and with a shared
# baseline it does not. Those three numbers were produced by THIS FILE, by
# temporarily adding the ERR generator and grading it; that run is the gate's
# observed-red proof and is deliberately not shipped — the #2044 corpus belongs to
# whoever fixes #2044, and pinning it here would make their fix red this gate
# rather than perf's. Any slice adding a shape here MUST take its floor from its
# own generator. Do not reintroduce a shared baseline.
#
# ── THE THRESHOLD ────────────────────────────────────────────────────────────
#
# IR_THRESH = 3.0 per doubling, and a shape FAILS when r2 — the SECOND doubling,
# the one that carries the asymptote — clears it. Same NUMBER and, since #2173,
# the same RULE as every DETERMINISTIC arm of diff_compiler_perf_scaling.sh and
# both drivers of diff_compiler_stage_ir_scaling.sh. The one arm anywhere that
# still demands both doublings is perf_scaling's WALL-CLOCK `grade_time_stage`,
# and that is deliberate: two noisy samples make a sustained signal worth
# demanding, whereas on a deterministic instrument r1 < t < r2 is the signature
# of the superlinear term rather than of noise (#2063, #2100, #2173). See THE
# VERDICT RULE in grade_shape. Derive the exception rather than trusting this
# line:  grep -n "^[^#]*r1 > th && r2 > th" test/diff_compiler_perf_scaling.sh
#
# ⚠️ THIS PARAGRAPH SAID "BOTH DOUBLINGS" UNTIL 2026-08-28 (#2160 phase 2), i.e.
# for the whole life of the r2-alone rule PR #2171 shipped: the header described
# the rule the code no longer ran, and it was the paragraph a reader was pointed
# at as "this gate's public contract". Found by phase 2's sweep of this file.
#
#     linear 2.0  |  n log n ~2.1  |  n^1.5 2.83  |  QUADRATIC 4.0
#
# 3.0 admits n log n with slack and catches n^1.58 and worse. MEASURED MARGIN on
# NET Ir, this box, heap-pinned, at the bands below, on a correct compiler:
#
#     xref        r1 2.046   r2 2.040        (32% headroom under 3.0)
#     manyifaces  r1 2.043   r2 2.053        (32% headroom under 3.0)
#
# and, on the same machinery, a real filed quadratic (#2044, NOT graded here —
# see the floor block) reads r1 3.261 r2 3.603 at 400/800/1600. Roughly 32% below
# the line and 9% above it. NB the ERR arm's ratios CLIMB with N (2.920/3.261 at
# 200/400/800, 3.261/3.603 at 400/800/1600) — that climb is the signature that
# separates a quadratic from a one-off step, and it is exactly why the rule below
# grades r2 alone: on a climbing shape r1 is the reading that has not caught up
# yet, so requiring it too would excuse the shape at the very N where the term
# first becomes visible.
#
# 🚨 THE THRESHOLD AND THE NETTING METHOD ABOVE ARE THIS GATE'S PUBLIC CONTRACT.
# Cite them; do not invent a second set. If a future shape needs a different
# threshold, say so AT THAT SHAPE with its own measurement — do not move this one.
#
# ── THE SHAPES ───────────────────────────────────────────────────────────────
#
# This gate is a NEW METRIC OVER EXISTING SHAPES. `gen_xref` and `gen_manyifaces` are
# SHARED with test/diff_compiler_perf_scaling.sh via test/perf_shapes.sh — same programs,
# same structure, graded on `Ir` instead of on time/alloc/ops. (They were transcribed
# verbatim until #2066; two hand-kept copies of a shape two gates quote against each
# other is a drift hazard neither gate can see.) Deliberately NOT a new fixture corpus:
# a fixture DIRECTORY is
# shared, and adding a file to one enrols this gate in others it never named
# (AGENTS.md [T-SHARED-CORPUS]). Keep new shapes as generators in this file.
#
#   xref       — N top-level functions, each calling the previous one, `main`
#                calling the head so nothing is dead. The shape that forces
#                resolve to walk the top-level scope chain on every reference;
#                this is where #78's resolve quadratic lived.
#   manyifaces — N interface decls (method pool ~N) AND N reference sites, growing
#                TOGETHER, so a List-as-a-set scan over the method pool reads
#                O(sites x pool). The co-scaled shape from #883; several real
#                quadratics (#969/#973/#975) were found on it.
#   errs       — N bindings, each `eK : Int` / `eK = "s"`, i.e. exactly one type
#                error per binding. The REGRESSION PIN for #2044 (the diagnostic
#                -count quadratic fixed by S-diag-count): the emitter's
#                per-diagnostic source-line lookup rescanned the whole file, so
#                rendering N diagnostics read O(N x file). See the regime note.
#   noimpl     — N DISTINCT `No impl of P for List T_k` diagnostics, all routed
#                through the deduping `pushTypeErrorOnceAt`. The measurement
#                shape for #2068 (the `pushTypeErrorOnce*` dedup scan). Distinct
#                messages are the whole point: the scan only grows when no
#                earlier message matches. See gen_noimpl.
#
# xref and manyifaces are 0-DIAGNOSTIC by construction; errs, diagbucket and
# noimpl are N-DIAGNOSTIC by construction. Either is a valid regime — what
# matters is that a shape's floor
# comes from the SAME generator and therefore the SAME regime (see the floor
# block above), and that the regime is ASSERTED at every measured N so a shape
# cannot silently drift out of it. `grade_shape`'s third argument names it.
#
# ── COST ─────────────────────────────────────────────────────────────────────
#
# 4 cachegrind invocations per shape (1 floor + 3 sizes); derive the shape count
# from the `grade_shape` lines at the bottom of this file rather than trusting a
# number here.
# There is no fan-out knob: cachegrind is single-threaded and the runs are
# sequential on purpose, so the numbers cannot be perturbed by a noisy neighbour.
# The bands are sized for cost, not for a floor — `Ir` has no floor to clear.
#
# Usage:  sh test/diff_compiler_ir_scaling.sh
#         IR_XREF_N=500 sh test/diff_compiler_ir_scaling.sh
# Exit:   0 every shape scales sub-quadratically
#         1 a shape regressed
#         2 skip (valgrind not on PATH) / phantom skip (./medaka not built)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"

# ./medaka missing is INFRA ROT, not an opt-in skip. run_gates.sh reclassifies an
# exit-2 whose log does NOT match its LEGIT_SKIP_RE into a phantom-skip FAILURE,
# which is the verdict this deserves — the gate would otherwise report "skipped"
# having graded nothing. Word the valgrind message below with "not on PATH" so it
# lands on the other side of that same test.
if [ ! -x "$MEDAKA" ]; then
  echo "build the compiler first — missing $MEDAKA"
  echo "  make medaka"
  exit 2
fi

if ! command -v valgrind >/dev/null 2>&1; then
  # ── #2065: A SKIP IS ONLY LEGITIMATE OFF CI. ────────────────────────────────
  #
  # The paragraph above is still right about a dev box: not everyone has valgrind, and a
  # gate that hard-failed there would be noise. But it was ALSO true in CI, and that is
  # the hole. `.github/actions/setup-medaka` installs valgrind explicitly, so the only
  # way to reach this branch on a runner is that the install silently stopped happening —
  # a runner image change, an apt failure, a moved step. And on that day this gate would
  # have gone on printing a tidy SKIP line inside a large gate run, run_gates.sh would
  # have matched "not on PATH" against its LEGIT_SKIP_RE and recorded an opt-in skip, the
  # shard would have gone green, and `Ir` scaling would have stopped being graded with no
  # red anywhere. "A gate never observed red is indistinguishable from one that cannot go
  # red" (#880 §8) — and a gate that silently stops running is the same claim, worse.
  #
  # So: SKIP off CI, HARD FAIL on it. exit 1, not 2, so no skip-classifier anywhere can
  # reinterpret it — the verdict does not depend on run_gates.sh's regex agreeing with a
  # message string, which is the coupling that produced this hole in the first place.
  #
  # ── OBSERVED RED, 2026-08-28. Valgrind 3.24.0 IS installed on this box, so the
  #    absence had to be MANUFACTURED — a branch you cannot reach is a branch you cannot
  #    claim. Build a directory of symlinks to the tools the gate needs, omitting
  #    valgrind, and run with PATH pointed at it:
  #      mkdir -p /tmp/nopath
  #      for t in sh awk sed grep cut head sort tr find cmp mktemp rm cp mv cat \
  #               basename dirname date git python3 clang perl nm; do
  #        ln -sf "$(command -v $t)" /tmp/nopath/$t; done
  #      env -u CI PATH=/tmp/nopath sh test/diff_compiler_ir_scaling.sh   # dev box
  #      CI=true  PATH=/tmp/nopath sh test/diff_compiler_ir_scaling.sh   # a runner
  #
  #    CI UNSET  -> exit 2, "SKIP: valgrind not on PATH — …"
  #    CI=true   -> exit 1, "FAIL: valgrind is not on PATH, and this is CI."
  #    And the laundering that made this a bug, confirmed on the same run:
  #      the exit-2 message MATCHES run_gates.sh's LEGIT_SKIP_RE, so pre-fix that
  #      verdict was recorded as an opt-in SKIP (st=2) and the shard stayed GREEN
  #      having graded no `Ir` at all. exit 1 is outside that classifier entirely.
  #    (Same recipe, same two verdicts, for diff_compiler_stage_ir_scaling.sh.)
  if [ -n "${CI:-}" ]; then
    echo "FAIL: valgrind is not on PATH, and this is CI."
    echo "  This gate measures Cachegrind instruction counts; without valgrind it grades"
    echo "  NOTHING. On a dev box that is a legitimate skip. On a runner it means the"
    echo "  valgrind install in .github/actions/setup-medaka stopped happening, and the"
    echo "  Ir-scaling arm has silently gone dark (#2065). Fix the install, not this check."
    exit 1
  fi
  echo "SKIP: valgrind not on PATH — this gate measures Cachegrind instruction counts."
  echo "  (A skip is only legitimate OFF CI — see the #2065 note in this file. On CI this"
  echo "   is a hard failure.)"
  echo "  Debian/Ubuntu: sudo apt-get install -y valgrind"
  exit 2
fi

# ── freshness: assert ONCE, loudly, before measuring anything ────────────────
#
# AGENTS.md [B-STALENESS]/[B-STDERR]: a stale ./medaka exits 0 with a
# right-looking answer and only a stderr warning. Here that would be worse than
# usual — the numbers would be real instruction counts of the WRONG compiler, and
# nothing downstream could tell. MEDAKA_STRICT=1 turns it into exit 1. This is a
# single-arm gate, so [B-STRICT-TWO-ARM] does not apply; assert it here and NOT
# on the measured runs, where the extra fingerprint work would be counted.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf 'main = println 1\n' > "$WORK/freshness.mdk"
# OBSERVED RED (#2160 phase 2, this box, 2026-08-29). A fake MEDAKA_ROOT makes
# the baked-in source fingerprint unmatchable, which is exactly the state
# [B-STALENESS] describes — and note what it takes to SEE it: without
# MEDAKA_STRICT the same binary exits 0 with a right-looking answer and only a
# stderr warning ([B-STDERR]).
#
#   $ mkdir -p /tmp/fakeroot/compiler && printf 'x = 1\n' > /tmp/fakeroot/compiler/bogus.mdk
#   $ ln -s "$PWD/stdlib" /tmp/fakeroot/stdlib
#   $ MEDAKA_ROOT=/tmp/fakeroot sh test/diff_compiler_ir_scaling.sh
#   FAIL: ./medaka is stale or broken — refusing to publish instruction counts for it.
#     ... compiler source may be stale; rebuild ...
#     make medaka
#   exit=1
#
# The point of the arm is that the numbers would otherwise be REAL instruction
# counts of the WRONG compiler, and nothing downstream could tell.
if ! MEDAKA_STRICT=1 "$MEDAKA" check "$WORK/freshness.mdk" >/dev/null 2>"$WORK/fresh.err"; then
  echo "FAIL: ./medaka is stale or broken — refusing to publish instruction counts for it."
  sed 's/^/  /' "$WORK/fresh.err"
  echo "  make medaka"
  exit 1
fi

THRESH="${IR_THRESH:-3.0}"

# ── THE LEDGER: shapes with a DECLARED, measured, non-flat cost (#2100) ───────
#
# This gate had no ledger at all until 2026-08-28, which is why `scoperefs` was
# carried as a silent pass instead of a declared exception (#2100). It now has
# the same self-draining mechanism as test/diff_compiler_stage_ir_scaling.sh,
# deliberately in the same shape so the two read alike:
#
#   KNOWN_CEIL_<shape>   fail if r2 goes ABOVE it   — it got worse
#   KNOWN_FIXED_<shape>  fail if r2 goes BELOW it   — it got FIXED, demanding a
#                                                     PROMOTE out of the ledger
#
# Both halves are required. A ledger with only a ceiling is a skip-list: it can
# never notice that the thing it excuses has been repaired, so the row outlives
# the defect and the shape is never graded again.
KNOWN_SUPERLINEAR="scoperefs"

# scoperefs — LEDGERED BECAUSE IT IS A LIVE, UNFIXED QUADRATIC: #2172.
#
# 🚨 Read this before touching the band. THIS ROW EXCUSES AN OPEN DEFECT; it
# does NOT excuse a cost that is correct by construction. An earlier version of
# this comment claimed the opposite — that #1031's OrdMap-backed scan made the
# shape "O(n log n) BY CONSTRUCTION", so the creeping ratio was expected. That
# justification is FALSE and it would have told the next reader there was
# nothing here to investigate. It was refuted by measuring a fourth point:
#
#   N =  3000   net 1.20103e10
#   N =  6000   net 3.48573e10    r = 2.903
#   N = 12000   net 1.10136e11    r = 3.159    <- this gate's shipped r2
#   N = 24000   net 3.78602e11    r = 3.438    (IR_SCOPEREFS_N=6000)
#
# A clean n*log n gives 2*ln(2n)/ln(n) = 2.173 -> 2.159 -> 2.147 over that band:
# just above 2, and FALLING. Measured is 2.903 -> 3.159 -> 3.438: RISING, with
# an implied exponent log2(r) of 1.537 -> 1.660 -> 1.782, climbing toward 2.
# Fitting net = a*N + b*N^2 to the top two points gives a/b ~= 4695 and predicts
# the fourth ratio at 3.467 vs 3.438 measured (0.8% error); the n*log n model is
# off by ~60% on the same data. On that fit the N^2 term is already ~72% of net
# Ir at this gate's own N=12000. The residual is NOT the OrdMap probe — a
# quadratic term dominates the band. Tracked as #2172.
#
# ── #2172's FIRST DISCRIMINATOR HAS BEEN RUN, AND IT IS NEGATIVE (#2160 phase 2,
# 2026-08-28, this box; posted to #2172). The suspicion was that this shape emits
# its tail as ONE source line of ~7*N chars, making it the #2044 line-rescan
# family rather than #1031's scope scan. Re-generating the identical program with
# the tail SPLIT across many short lines (same tokens, same bindings, ~N extra
# lines) moves nothing:
#
#   gen_scoperefs        floor=1816309817  N=3000 net=12011775893  N=6000 net=34873473287  r=2.903
#   gen_scoperefs_split  floor=1817035195  N=3000 net=12041588253  N=6000 net=34915351133  r=2.900
#
# 0.25% apart on net Ir and 0.1% on the ratio. Line length is NOT the variable,
# so BOTH line-shaped explanations die at once and the residual is unlocalised.
# Do not re-run this discriminator; the next step is per-stage attribution, which
# needs a `scoperefs` shape in test/diff_compiler_stage_ir_scaling.sh (there is
# none today).
#
# ⚠️ CEIL IS A PER-BAND NUMBER, valid only at this gate's SCOPEREFS_N=3000. At
# IR_SCOPEREFS_N=6000 the SAME tree reads r2=3.438 and this row correctly
# reports "** KNOWN-SUPERLINEAR, AND GOT WORSE **". That is the band moving, not
# a regression — unavoidable for a shape whose ratio climbs with N. Move the N
# and you must re-derive the ceiling.
#
# The band is derived from MEASURED VARIANCE, not from the value it bounds
# (#2160 rule 3). Three back-to-back full runs of this gate on this box against
# one binary, 2026-08-28:
#
#   scoperefs net Ir at N=12000: 110133423361 / 110133008756 / 110133139932
#     -> relative spread 3.8e-6, and every r1/r2 the gate printed was identical
#        to all 3 printed decimals across all three runs (r1=2.900 r2=3.159).
#
# Run-to-run variance on this instrument is therefore ~0 and cannot set a useful
# margin on its own. The real drift source is a constant-factor shift from an
# unrelated compiler change; its scale is visible in the spread of the five FLAT
# shapes' r2 in the same runs (2.056 / 2.061 / 2.065 / 2.073 / 2.119 — 3.1%
# end to end). CEIL is set one such drift-width above the observed 3.159:
#
#   3.159 * 1.031 = 3.257  ->  3.26
#
# which still fails #2063's partial-#2044 reading (r2=3.392) and every reading
# worse than it. FIXED sits between the flat shapes' ~2.07 and the ledgered
# 3.159, far enough above the former that ordinary drift cannot trip it:
#
# ── 2026-08-31 re-derivation (sprint felt-latency #2270, packet
# F2-scoperefs-ceiling-rederive, issue #2326). The sprint's own real win —
# removing an input-size-proportional redundant reparse cost — lowered
# absolute scoperefs Ir at every N (net Ir strictly decreased end to end), but
# lowered it proportionally MORE at N=6000 than at N=12000, which mechanically
# RAISED r2 even though nothing on the scoperefs code path (#1031/#2172)
# changed: zero scoperefs-adjacent lines touched this sprint. Baselines:
#   old (pre-existing, this comment)           r2=3.159
#   pre-sprint main tip b35268c0 (fresh measure) r2=3.091  PASS (< 3.26)
#   sprint head 57e8b8dc (fresh measure, CI x2)  r2=3.300
#   this packet's own fresh re-measure           r1=3.066 r2=3.298
# Re-deriving by this file's OWN documented method (same 1.031 drift-width
# multiplier as above, unchanged): 3.300 * 1.031 = 3.4023 -> 3.41 (the
# packet's number); this packet's own fresh 3.298 gives 3.298 * 1.031 =
# 3.400 -> 3.41, identical after rounding. KNOWN_FIXED_scoperefs is
# unchanged: 2.60 still sits between the flat shapes' ~2.07 and the new
# 3.30-3.41 ledgered band, same as before.
#
# ── 🚨 2026-08-31 REVERT MEASUREMENT (sprint hold-the-gains, S-2, #2331 Case 1).
# READ THIS BEFORE YOU TRUST THIS CEILING TO CATCH ANYTHING.
#
# Every derivation above this line sets CEIL as a MARGIN OVER THE CURRENT READING
# and never once measured what the DEFECT reads. #2331 asked for that measurement.
# It has now been made, and the answer is that THIS ROW DOES NOT DISCRIMINATE A
# #1031 REINTRODUCTION AT THIS BAND.
#
# METHOD — synthetic reintroduction, not a true revert. `git apply -R` of
# 54f54bef6's resolve.mdk + typecheck.mdk hunks does not apply (four sprints of
# later work sit on both files; --3way applies only WITH CONFLICTS), so the
# pre-#1031 List-as-a-set shape was PLANTED at the two sites of that commit that
# `check` actually reaches — `ir_of` runs `medaka check`, so private_mangle /
# llvm_emit / wasm_emit and b32b083f8's emit_support fifth site are all off the
# measured path:
#   resolve.mdk    stampBindingIds's scope env OrdMap Int -> List (String, Int);
#                  lookupBindId omLookup -> lookupAssoc; insertZero omInsert ->
#                  cons-prepend (later name still wins — same shadowing).
#   typecheck.mdk  rewriteArgScoped's `bound` OrdMap Unit -> List String;
#                  boundInsert -> `ns ++ b`; the four `omHasKey n bound` probes ->
#                  `contains n bound`. rp/an/dn stay indexed (#2189, a different fix).
# Built, smoke-tested, measured, reverted. Both arms, same box, same day:
#
#   FIXED (this tree)               r1=3.066  r2=3.300
#   #1031 REINTRODUCED (synthetic)  r1=3.186  r2=3.356    <- and it PASSES at 3.41
#
# THE SEPARATION IS 1.7%. The ceiling would have to sit in 3.300 < CEIL < 3.356 to
# tell the two apart. That window is NARROWER than the 3.1% constant-factor drift
# width this very comment derives above, and narrower than the drift this row has
# actually shown across trees (3.159 -> 3.091 -> 3.300 over three sprints, ~3.3%,
# every step from an UNRELATED compiler change — felt-latency alone moved it 6.8%,
# four times the whole window). A ceiling inside it is a false-red generator that
# gets "repaired" by raising the ceiling, which is the exact drift loop #2331
# exists to stop.
#
# ⇒ 3.41 IS NOT RAISED AND NOT LOWERED, and it is now honestly labelled: it bounds
# THE LEDGERED #2172 COST GETTING WORSE, and it does NOT pin #1031. Do not read a
# green `scoperefs` as evidence that #1031 has not been reintroduced — it is not
# evidence either way, the same status test/diff_compiler_ir_scaling.sh's own
# `diagbucket` row carries for #1019.
#
# THE LEVER IS THE BAND, NOT THE CEILING. Ratios climb with N on a quadratic row,
# so a wider band separates the two arms; at IR_SCOPEREFS_N=6000 this tree already
# reads 3.438 where 3000 reads 3.30. Measuring BOTH arms at 6000/12000/24000 is ~4x
# this run and was past S-2's foreground budget. That is the follow-up, and #2331
# stays OPEN for it. Do NOT discharge #2331 by moving this number.
KNOWN_CEIL_scoperefs="${KNOWN_CEIL_scoperefs:-3.41}";  KNOWN_FIXED_scoperefs="${KNOWN_FIXED_scoperefs:-2.60}"

# Add-only deliberate-red seam. Default empty, set NOWHERE in the tree, and it
# can only ADD rows — it can never suppress a real one. It exists so the ledger
# arms above can be driven red on demand without editing this file (#2160 rule
# 1: an arm nobody has ever seen fail is not a pin). A banner is printed when it
# is used, so a run that used it can never be mistaken for a clean one.
if [ -n "${IR_LEDGER_EXTRA:-}" ]; then
  echo "!! LEDGER INJECTION ACTIVE: IR_LEDGER_EXTRA=$IR_LEDGER_EXTRA — this run is NOT a clean verdict."
fi
is_known() {
  for _k in $KNOWN_SUPERLINEAR ${IR_LEDGER_EXTRA:-}; do
    [ "$_k" = "$1" ] && return 0
  done
  return 1
}

# Run one shape only (cost control, and how the observed-red records below were
# captured). Empty = all of them; never set in CI.
IR_ONLY="${IR_ONLY:-}"

# ── OBSERVED RED (#2160 rule 1) ──────────────────────────────────────────────
#
# An arm nobody has watched fail is not a pin. Every arm added or changed here on
# 2026-08-28 was driven red first-hand on this box, on the CHEAPEST shape (xref,
# r1=2.067 r2=2.065) so the five ladders cost minutes rather than scoperefs' one.
# Verbatim, in the order the arms appear in grade_shape:
#
#   1. the plain threshold arm, now firing on r2 ALONE (#2063's rule change):
#      $ IR_ONLY=xref IR_THRESH=2.0 sh test/diff_compiler_ir_scaling.sh
#      FAIL xref: SUPERLINEAR (Ir) r1=2.067 r2=2.065  (threshold 2.0 on r2, the second doubling)
#      exit=1

#   1b. AND THE REAL ONE — #2063's own defect, reproduced on a reverted compiler
#      rather than argued from the issue's numbers. The PARTIAL #2044 revert the
#      issue names (medaka_cli.mdk:702, the single-file check arm, from
#      `ppDiagCliLines (srcLinesArr tsrc) target` back to `ppDiagCliSrc tsrc
#      target`; `spaces` and `nthLineGo` left FIXED), built and measured here
#      2026-08-28 at the SHIPPED 400/800/1600 band:
#
#        errs: floor(N=1) = 908974087 Ir  (net must exceed 45448704)
#          N=400    raw=2259572817     net=1350598730
#          N=800    raw=4890235382     net=3981261295
#          N=1600   raw=14296545279    net=13387571192
#        FAIL errs: SUPERLINEAR (Ir) r1=2.948 r2=3.363  (threshold 3.0 on r2, the second doubling)
#
#      #2063 reported 2.967 / 3.392 for this same revert; reproduced here within
#      0.7% on a different build. r1 = 2.948 is UNDER 3.0, so the old
#      both-doublings rule called this `ok` on a compiler that had genuinely
#      reintroduced #2044's dominant rider. That is the whole issue, and it is
#      fixed by the RULE — IR_ERRS_N is untouched, IR_THRESH is untouched. The
#      issue's own suggested lever (raise the N band, "the cheap lever is the N
#      band, not the threshold") turns out not to be needed at all, which also
#      spares this gate the Cachegrind cost of a wider errs band.
#
#   2. a ledger row with no ceiling/fixed pair — a skip-list caught as malformed:
#      $ IR_ONLY=xref IR_LEDGER_EXTRA=xref sh test/diff_compiler_ir_scaling.sh
#      !! LEDGER INJECTION ACTIVE: IR_LEDGER_EXTRA=xref — this run is NOT a clean verdict.
#      FAIL xref: ledgered in KNOWN_SUPERLINEAR but has no KNOWN_CEIL_xref / KNOWN_FIXED_xref pair.
#        A ledger row without both halves cannot drain itself — that is a skip-list, not a pin.
#      exit=1
#      🚨 ON THE FIRST ATTEMPT THIS ARM PRINTED NOTHING AND EXITED 2. `set -u` (:188)
#      killed the shell on `eval "ceil=\${KNOWN_CEIL_xref}"` before the check below
#      could report anything — and exit 2 is run_gates.sh's SKIP candidate, not a
#      failure. That is why both evals carry `:-`. The same latent abort was found
#      and fixed in diff_compiler_stage_ir_scaling.sh and diff_compiler_perf_scaling.sh,
#      which had copied the unguarded form.
#
#   3. ledgered AND GOT WORSE (r2 above the row's own ceiling):
#      $ IR_ONLY=xref IR_LEDGER_EXTRA=xref KNOWN_CEIL_xref=1.50 KNOWN_FIXED_xref=1.00 …
#      FAIL xref: ** KNOWN-SUPERLINEAR, AND GOT WORSE ** r1=2.067 r2=2.065 (ceiling 1.50)
#      exit=1
#
#   4. PROMOTE — the ledger draining itself when the declared cost is gone:
#      $ IR_ONLY=xref IR_LEDGER_EXTRA=xref KNOWN_CEIL_xref=9.00 KNOWN_FIXED_xref=3.00 …
#      FAIL xref: ** PROMOTE: now scales within the band ** r2=2.065 (< 3.00)
#        Remove "xref" from KNOWN_SUPERLINEAR — the declared cost is GONE.
#        It may NOT stay ledgered AND ungraded.
#      exit=1
#
#   5. and the real row, unmodified, reading as a DECLARED row rather than a
#      silent pass — which is the whole of #2100:
#      $ IR_ONLY=scoperefs sh test/diff_compiler_ir_scaling.sh
#      known scoperefs: r1=2.900 r2=3.159 (ledgered, ceiling 3.26) — see KNOWN_SUPERLINEAR
#      exit=0
#      (2026-08-31: this exact reading is HISTORICAL — sprint felt-latency
#      #2270 re-derived the ceiling to 3.41 against a new baseline r2=3.30;
#      see KNOWN_CEIL_scoperefs's own comment above for the full derivation.
#      A fresh run today reads e.g. "r1=3.066 r2=3.298 (ceiling 3.41)".)
#
# KNOWN_CEIL_scoperefs / KNOWN_FIXED_scoperefs are `:-`-defaulted for exactly arms
# 3 and 4: a band nobody can drive past is a band nobody has tested.

# The GC heap pin applied to every measured run (header, determinism block).
IR_HEAP="${IR_HEAP:-2147483648}"

# The floor size. 1 is deliberate: the point is a program in the shape's own
# diagnostic regime whose user-code cost is negligible, not a second data point.
FLOOR_N="${IR_FLOOR_N:-1}"

# Per-shape bands, chosen for COST (see the header): each is the largest band
# whose 4N run stays a few seconds under cachegrind.
XREF_N="${IR_XREF_N:-250}"
MANYIFACES_N="${IR_MANYIFACES_N:-100}"
# errs is deliberately the widest band: #2044's ratios CLIMB with N (see the
# threshold block), so a narrow band grades the quadratic at its weakest and the
# pin would be a soft one. 400/800/1600 is where the pre-fix reading was
# measured (r1 3.215 r2 3.574) and where the fix reads ~2.03/~2.03.
#
# ⚠️ #2063 ASKED FOR THIS BAND TO BE WIDENED AND IT MUST NOT BE (2026-08-31, sprint
# hold-the-gains S-2). #2063's defect is that a PARTIAL #2044 revert reads
# r1=2.967 r2=3.392 and "the gate's 'both doublings must exceed threshold' rule does
# not fire". THAT RULE NO LONGER EXISTS — e68356238 (#2160 phase 1) replaced it with
# r2 alone (see the verdict-rule block in grade_shape), so 3.392 > 3.0 FAILS today.
# `over` is a pure function of r2 and THRESH. Widening the band would triple this
# shape's cachegrind cost to repair a defect that is already repaired. Measured on
# this tree at the unchanged band: r1=2.061 r2=2.061 — flat, so the band is not the
# weak point either. #2063 is fixed-but-open, not thin-margin.
ERRS_N="${IR_ERRS_N:-400}"
# scoperefs: a deep local scope where the tail references EVERY bound name, most
# of them non-innermost — the #1031 shape (resolve/typecheck/mangle/emit each
# scan a List frame-list to answer "is this name bound"). #1031's fix backed the
# scan with an OrdMap, and the ratio still creeps with N.
#
# ⚠️ DO NOT read that creep as the tree probe. This comment used to explain it as
# "expected for a tree-backed set, not a regression"; that is FALSE — a fourth
# measured point shows a quadratic term dominating the band (#2172, and the full
# derivation at KNOWN_CEIL_scoperefs above). The shape is ledgered against a
# measured ceiling because the defect is LIVE, not because the cost is correct.
#
# Band choice, which is a separate question. Measured on this box: the
# pre-fix defect is invisible below ~N=2500 (both r1,r2 stay under 3.0 even with
# the O(depth^2) scan still present — the fixed cost of a `check` on this shape's
# giant expression dominates at smaller N) and only reads clearly red at N=3000:
#     base (pre-fix)  r1=3.118 r2=3.308  FAIL
#     head (post-fix) r1=2.895 r2=3.159
#
# ⚠️ THAT SECOND LINE WAS RECORDED HERE AS "ok", AND IT IS NOT ok ANY MORE.
# It read green only because the verdict rule then in force required BOTH
# doublings over threshold, and this comment argued that conjunct was "exactly
# what keeps this from flapping on the O(log n) creep". #2100 is that argument
# arriving as a defect report: r2=3.159 is already OVER this gate's own 3.0
# threshold, and the row was passing on the letter of a rule imported from a
# wall-clock gate. The rule is now r2 alone (see grade_shape) and this shape is
# a DECLARED ledger row in KNOWN_SUPERLINEAR, graded against its own measured
# ceiling. Re-measured on this box 2026-08-28, three runs: r1=2.900 r2=3.159,
# identical to 3 decimals every time.
#
# ⚠️ #2100 IS FIXED-BUT-OPEN, and this knob is NOT what is left of it (2026-08-31,
# sprint hold-the-gains S-2). #2100's defect was "passing only because grade_shape
# requires BOTH r1 and r2 over threshold"; e68356238 flipped that to r2 alone AND
# this shape became a declared KNOWN_SUPERLINEAR row graded against its own ceiling,
# which is both of the things the issue asked for. SCOPEREFS_N was NOT widened here.
# What IS still owed on this shape is a WIDER BAND — but for #2331, not #2100, and
# for a different reason: see the revert measurement at KNOWN_CEIL_scoperefs, which
# shows the ceiling cannot tell a #1031 reintroduction from this tree at N=3000.
SCOPEREFS_N="${IR_SCOPEREFS_N:-3000}"
# diagbucket — see gen_diagbucket below for the shape.
#
# 🚨 THIS ROW IS A LINEARITY LADDER, NOT A REGRESSION PIN. It was added as #1019's
# pin and it cannot do that job at any affordable N. #2152 reported it; this is the
# measurement that settles it. DO NOT read a green `diagbucket` as evidence that
# #1019 has not been reintroduced — it is not evidence either way.
#
# MEASURED 2026-08-28, this box, on a compiler with #1019 DELIBERATELY REVERTED
# (pushDiags's bulk `existing ++ ds` replaced by the per-element recursion, which is
# the pre-51eb8807 O(n^2) shape). Four bands, each the gate's own 1x/2x/4x ladder:
#
#     band N            r1      r2     verdict   wall clock
#      300/600/1200    2.104   2.138    ok       (#2152's reading, not re-run here)
#     1200/2400/4800   2.215   2.370    ok         48 s
#     2400/4800/9600   2.370   2.593    ok         94 s
#     5500/11000/22000 2.668   2.851    ok        291 s
#
# The ratio climbs, so the quadratic IS there and IS being measured — it is simply
# swamped. Fitting net(N) = a*N + b*N^2 to the last band (ratio(N) = (2a+4bN)/(a+bN),
# r2 = 2.851 at the 11000->22000 doubling) gives b*11000 = 0.7407a, i.e.
#
#     a/b ~= 14 850    (the linear cost of ONE diagnostic is ~14 850x the cost of one
#                       cons-copy step, ~97 Ir, that the reverted fold adds per pair)
#
# ratio hits this gate's 3.0 threshold only at x = b*N/a = 1, i.e. a MIDDLE N of
# ~14 850 — band 7400/14850/29700, and that is the MARGINAL reading r2 = 3.000. A
# decisive red (r2 >= 3.2) needs x = 1.5, i.e. band ~11000/22000/44500. Cost scales
# with Ir, and Ir at 22000 was already 8.26e10 for the 291 s band; the 44500 point
# alone is ~4x that, putting the decisive band near 20 MINUTES for ONE SHAPE.
#
# BOTH remedies #2152 offered are therefore declined, with numbers rather than by
# judgement, and rule 4 of #2160 phase 1 (state the cost, place explicitly) is why:
#   (a) "raise N until it reads red" — ~20 min. This gate is ~509 s total against a
#       600 s foreground ceiling (ci.yml, `sqlite` row), so it does not fit the PR
#       shard. It would fit `nightly.yml`, which already carries `perf_scaling DEEP
#       (the N=16000 bands ci.yml cannot afford)` — but 20 min of Cachegrind to pin
#       ONE already-fixed, confirmed-linear bulk append is not a trade worth making,
#       and saying so out loud is better than spending it quietly.
#   (b) "redesign the shape so the quadratic dominates sooner" — cannot work here.
#       Dominance is governed by a/b, and `a` is the cost of TYPECHECKING AND
#       CONSTRUCTING a diagnostic (~1.4e6 Ir each), not the cost of the 2 source
#       lines gen_diagbucket emits per diagnostic. Making the source denser moves
#       parse cost, which is not the term in the denominator. There is no
#       diagnostic-producing shape an order of magnitude cheaper per diagnostic, so
#       no redesign moves a/b enough to matter.
#
# WHAT THE ROW IS STILL WORTH KEEPING FOR, at its cheap shipped band: it is the only
# deterministic ladder over the multi-module `pushDiags` path at all, so a FUTURE
# regression with a LARGER constant (an O(n^2) with a coefficient 100x this one, or
# an accidental O(n^2) in the diagnostic CONSTRUCTION rather than the append) does
# show up here. That is a real, if narrow, use — it is just not #1019's pin.
#
# ⚠️ AND THE GENERAL FACT, which outlives this row: a per-element `++` fold over a
# diagnostic batch is NOT DETECTABLE by an Ir ladder at any reachable N, because
# producing a diagnostic costs ~15 000x what the fold's extra copy costs. #1019's
# real protection is the shape of the code and the comment above pushDiags, not a
# gate. Any future "we pinned it" claim about that function should be read against
# this paragraph.
DIAGBUCKET_N="${IR_DIAGBUCKET_N:-300}"
# noimpl: #2068's shape — see gen_noimpl below.
#
# 🚨 READ THIS BEFORE TREATING A GREEN `noimpl` AS PROOF OF ANYTHING. This band
# CANNOT go red on #2068, pre-fix or post-fix, and that is a deliberate, measured
# choice rather than an oversight. The pre-fix defect is a genuine O(N^2) with a
# SMALL quadratic coefficient: measured on this box, heap-pinned, on the pre-fix
# binary, net Ir was 5.287e9 / 1.179e10 / 2.850e10 / 7.462e10 at N =
# 1600/3200/6400/12800, i.e. per-doubling ratios 2.230 / 2.418 / 2.618 —
# monotonically climbing, and fitting net(N) = a*N + b*N^2 over 1600->6400 gives
# a = 2.92e6 Ir per diagnostic against b = 239 Ir per message pair. Since
# ratio(N) = (2a+4bN)/(a+bN), it only reaches this gate's 3.0 threshold at
# N = a/b ~= 12 000 DISTINCT diagnostics in one run, so a threshold-red band would
# need 4N ~= 50 000 bindings — hours under cachegrind, not the ~2 min this whole
# gate costs. The disposition on #2068 rests on that N^2 FIT, not on a red reading
# here. Post-fix the same fit reads a = 2.95e6, b = 165: the linear term is
# untouched (the OrdMap index costs nothing measurable) and 74 Ir per message pair
# — one String comparison — is gone.
#
# ⚠️ THE RESIDUAL b = 165 WAS A SECOND, DIFFERENT QUADRATIC, NOT #2068 LEFTOVER —
# now FIXED (#2158). `noImplHintFor` used to call `tabHasName`
# (compiler/frontend/ast.mdk:464), a linear List scan over `dataParamKindsRef`,
# once per no-impl DETECTION — O(data-types x no-impl-errors), and THIS shape
# scaled both axes together. Discriminated by measurement: the same route with
# ONE data type and N interfaces (so `dataParamKindsRef` stayed size 1) fit
# b = 79 instead of 165.
#
# #2158 replaced the scan with `dataParamNameIndexRef`, a name-keyed `OrdMap`
# built and kept in lockstep with `dataParamKindsRef` at each of its three write
# sites (freshPerRun / declEnvSeedDataUniverse / recordParamKinds), so
# `noImplHintFor` is an `omHasKey` lookup instead of a re-scan. Re-measured
# post-fix on this box: net Ir at N = 400/800/1600 was 871409915 / 1774831855 /
# 3621459149, fitting net(N) = a*N + b*N^2 over 400->1600 gives a = 2.15e6,
# b ~= 71 — down from 165 (lineage: 239 [pre-#2068] -> 165 [pre-#2158] -> ~71
# [post-#2158]). The residual b is NOT zero: this shape still walks `perRun`
# state proportional to N somewhere else (e.g. diagnostic accumulation shared
# with the `errs`/`diagbucket` bands above), so a further quadratic may remain;
# re-derive rather than trusting this number if the surrounding code moves.
#
# What this band IS for: keeping a deterministic ladder on the plain
# `pushTypeErrorOnceAt` route (the route #2068's first, invalid measurement never
# entered — see gen_noimpl), so a future regression with a LARGER constant is
# caught, and so the next agent measures this family on a shape that reaches it.
# Re-derive the settling ladder with IR_NOIMPL_N=1600 (or 3200) if you need it.
NOIMPL_N="${IR_NOIMPL_N:-400}"

# A netting-noise guard, and the `Ir` analogue of perf_scaling's TIME_FLOOR — but
# justified differently. It is NOT about a stage being too fast to time: `Ir` has
# no such problem. It is about the SUBTRACTION: if net(N) is a small difference
# between two large numbers, its ratio is computed out of the floor's own
# run-to-run wobble. Observed wobble is ~1e-5 of the floor, so 5% is ~4 orders of
# magnitude of headroom; a shape that cannot clear it is mis-sized, and saying so
# is the point. Printed, never silent.
MIN_NET_FRAC="${IR_MIN_NET_FRAC:-0.05}"

# ── the shapes ───────────────────────────────────────────────────────────────
#
# gen_xref / gen_manyifaces are SHARED with test/diff_compiler_perf_scaling.sh, and
# gen_scoperefs is additionally SHARED with test/diff_compiler_stage_ir_scaling.sh
# (per-stage #2172 attribution, S-5-scoperefs-attribution) — all sourced from
# test/perf_shapes.sh. (test/diff_compiler_perf_scaling.sh also sources this library, but
# does NOT consume its `gen_scoperefs` — it shadows the name with its own, textually
# different local `gen_scoperefs_resolve` for the unrelated #78 P-1 resolve detector; see
# perf_shapes.sh's header on that generator.) They used to be TRANSCRIBED here (#2066): two byte-different
# copies of the same two programs, with nothing comparing them, so the two gates could
# have drifted into measuring different shapes while both stayed green and their ratios
# went on being quoted side by side. Read the header of perf_shapes.sh before editing a
# generator — a change there moves every band and ledger ceiling in BOTH gates.
# `.` is a POSIX SPECIAL BUILTIN: if the file is missing, dash terminates this
# script on the spot with no line of ours on stdout — and run_gates.sh reads a
# gate that printed nothing as a skip candidate, not as a failure. A sharing
# change that moved or renamed the library would therefore go GREEN-BY-SILENCE,
# which is the exact bug class this PR exists to close. Check first.
#
# OBSERVED RED, 2026-08-28, this box (#2160 rule 1). The library was moved aside
# and BOTH gates were run whole:
#
#   $ mv test/perf_shapes.sh /tmp/hidden
#   $ sh test/diff_compiler_ir_scaling.sh;   echo "exit=$?"   -> exit=1
#   $ sh test/diff_compiler_perf_scaling.sh; echo "exit=$?"   -> exit=1
#   FAIL: cannot read <root>/test/perf_shapes.sh — the shared shape library (#2066) is missing.
#     Both scaling gates source it; without it neither can generate a single shape.
#
# Without the guard both instead die inside the `.` builtin, printing only dash's
# own "can't open" on stderr and exiting 2 — which run_gates.sh weighs against
# LEGIT_SKIP_RE rather than counting as a failure.
[ -r "$ROOT/test/perf_shapes.sh" ] || {
  echo "FAIL: cannot read $ROOT/test/perf_shapes.sh — the shared shape library (#2066) is missing."
  echo "  Both scaling gates source it; without it neither can generate a single shape."
  exit 1
}
. "$ROOT/test/perf_shapes.sh"

# The #2044 regression pin. Each binding is annotated `Int` and bound to a
# String, which is exactly one `Type mismatch` diagnostic per binding and
# nothing else — so the diagnostic COUNT scales with N while the per-diagnostic
# work is constant. That is precisely the axis #2044's quadratic lived on.
gen_errs() {
  gn=$1; gf=$2; : > "$gf"
  {
    gi=0
    while [ "$gi" -lt "$gn" ]; do
      printf 'e%s : Int\ne%s = "s"\n' "$gi" "$gi"
      gi=$((gi + 1))
    done
    printf 'main = println 1\n'
  } >> "$gf"
}

# The #1019 regression pin. `pushDiags` (compiler/driver/diagnostics.mdk) is
# reached only on a MULTI-MODULE project (`checkRoute`'s analyzeProject arm —
# a single-module `check` never calls it), so this shape is a two-file
# project: a HELPER module of N `eK : Int` / `eK = "s"` bindings (same
# one-Type-mismatch-per-binding shape as `errs`) and a trivial ENTRY module
# that imports one name from it. The helper's whole N-diagnostic batch lands
# in ONE `pushDiags` call (from the typecheck pass), which is exactly the
# call the pre-`51eb8807` code folded `pushDiag` over per element (each fold
# step an O(current-bucket-size) `existing ++ [d]` — O(n^2) over the batch).
# The now-fixed code does one bulk `existing ++ ds` instead — this shape
# confirms that reads linear.
gen_diagbucket() {
  gn=$1; gf=$2
  hbase="$(basename "$gf" .mdk)_h"
  hfile="$(dirname "$gf")/$hbase.mdk"
  : > "$hfile"
  {
    gi=0
    while [ "$gi" -lt "$gn" ]; do
      printf 'export e%s : Int\ne%s = "s"\n' "$gi" "$gi"
      gi=$((gi + 1))
    done
  } >> "$hfile"
  : > "$gf"
  printf 'import %s.{e0}\n\nmain = println e0\n' "$hbase" >> "$gf"
}

# The #2068 shape: N DISTINCT diagnostic MESSAGES, all pushed through the
# deduping `pushTypeErrorOnceAt` (compiler/types/typecheck.mdk), whose dedup test
# is `anyList (e => tcMsg e == msg) perRun.value.typeErrors.items.value` — a
# linear scan of everything accumulated so far. That scan is O(N^2) only if the
# messages are DISTINCT: with a repeated message the scan short-circuits on the
# first element and the list never grows past 1.
#
# 🚨 THAT IS WHY `errs` IS THE WRONG SHAPE FOR #2068 AND THIS ONE IS NOT.
# `errs` produces N BYTE-IDENTICAL `Type mismatch: Int vs String` messages, and
# they do not even reach a `*Once*` function — `typeMismatchReportRest`'s plain
# arm calls the non-deduping `pushTypeError`. A #2068 measurement taken on `errs`
# grades code that never runs (see #2068's corrected comment).
#
# The shape: one interface `P` with NO impls, N distinct data types, and N
# bindings each demanding `P (List T_k)`. Two properties are load-bearing:
#
#   * `List T_k` rather than a bare `T_k`. `noImplHint` offers "write an 'impl P
#     T_k'" advice only when the single argument's head tycon is a user-declared
#     data type (a `dataParamKindsRef` hit); `List` is not, so the hint is None
#     and `pushNoImplError` takes its `None` arm — the plain
#     `pushTypeErrorOnceAt` at typecheck.mdk:27300. A bare `T_k` diverts onto the
#     HINTED arm (`pushTypeErrorHelpFixAt`), which carries the same scan but is a
#     different function; keeping the two arms distinguishable is the point.
#     Verified by eye on a 2-type program: `No impl of P for T1; write an 'impl P
#     T1'.` (hinted) vs `No impl of P for List T1` (plain).
#   * the `T_k` index rides INSIDE the message, so the N messages are pairwise
#     distinct and the scan actually grows.
gen_noimpl() {
  gn=$1; gf=$2; : > "$gf"
  {
    printf 'interface P a where\n  m : a -> Int\n'
    gi=0
    while [ "$gi" -lt "$gn" ]; do
      printf 'data T%s = T%s\n' "$gi" "$gi"
      gi=$((gi + 1))
    done
    gi=0
    while [ "$gi" -lt "$gn" ]; do
      printf 'u%s : Int\nu%s = m [T%s]\n' "$gi" "$gi" "$gi"
      gi=$((gi + 1))
    done
    printf 'main = println 1\n'
  } >> "$gf"
}

# ── measurement ──────────────────────────────────────────────────────────────
#
# The `Ir` total is read from cachegrind's own stderr summary ("I refs:"), not
# from the out-file: the out-file format is versioned and the summary line is
# the documented human-facing total. `--cachegrind-out-file` still points into
# $WORK so the run leaves nothing behind for a shard's `git status --porcelain`
# drift check to trip on.
ir_of() {
  # Pin the heap on EVERY measured run — see the determinism block in the header.
  # Unpinned, the GC's own heap-growth decision makes the floor bimodal across a
  # 2.2% band and the netting wobbles with it.
  GC_INITIAL_HEAP_SIZE="$IR_HEAP"; export GC_INITIAL_HEAP_SIZE
  valgrind --tool=cachegrind --cache-sim=no --branch-sim=no \
    --cachegrind-out-file="$WORK/cg.out" \
    "$MEDAKA" check "$1" >/dev/null 2>"$WORK/vg.err"
  _ir="$(grep -a 'I refs:' "$WORK/vg.err" | sed 's/.*I refs: *//' | tr -d ' ,')"
  case "$_ir" in
    ''|*[!0-9]*)
      echo "FAIL: could not read an Ir total from cachegrind for $1" >&2
      sed 's/^/  /' "$WORK/vg.err" >&2
      return 1 ;;
  esac
  printf '%s' "$_ir"
}

# ⚠️ A `medaka check` that ERRORS here is a broken fixture, not a finding: the
# shape would silently change diagnostic regime (see the floor note in the
# header) and its floor would stop being its floor. Assert 0 diagnostics on
# EVERY measured instance — floor AND each of N/2N/4N — not just the floor:
# `ir_of` deliberately ignores `check`'s exit code, so a compiler that dies
# partway through only the LARGER fixture reads a DEPRESSED Ir and can grade
# GREEN while crashing. `MIN_NET_FRAC` catches a fully-erroring regime; it does
# not catch a partial one. Both shipped shapes are 0-diagnostic by design, so
# this is a pure tightening with nothing to opt out.
# ── OBSERVED RED: both regime asserts (#2160 phase 2, this box, 2026-08-29) ──
#
# These two say "the generated fixture is still in the regime this shape claims".
# They are reachable through the band knobs alone — a degenerate N is a legal
# value of an add-only knob, and it makes each generator emit a program in the
# OTHER regime:
#
#   $ IR_ONLY=xref IR_XREF_N=0 sh test/diff_compiler_ir_scaling.sh
#   FAIL: generated fixture does not typecheck — the shape has drifted:
#   FAIL: no shape was graded — this gate proved nothing.
#   exit=1
#
#   $ IR_ONLY=errs IR_ERRS_N=0 sh test/diff_compiler_ir_scaling.sh
#   FAIL: generated fixture typechecks CLEANLY — an N-diagnostic shape has drifted:
#   FAIL: no shape was graded — this gate proved nothing.
#   exit=1
#
# Note the SECOND line in both: the zero-graded backstop fires too, and that is
# the correct pair — an aborted shape must not leave the gate reporting success
# on the strength of the shapes that did run.
assert_clean() {
  if ! "$MEDAKA" check "$1" >"$WORK/chk.out" 2>&1; then
    echo "FAIL: generated fixture does not typecheck — the shape has drifted:"
    sed 's/^/  /' "$WORK/chk.out"
    return 1
  fi
  return 0
}

# The N-diagnostic counterpart, for a shape whose whole point is that the
# diagnostic COUNT scales. `assert_clean` is the wrong assertion for such a
# shape — but "no assertion" is worse, because the drift it guards against is
# the same one and lands the same way: a fixture that stops producing N
# diagnostics (or starts producing a different KIND) leaves the shape's floor
# in a regime the measured runs are no longer in, and the ratios become
# meaningless while the gate still grades them. So assert the count EXACTLY,
# at every measured N, floor included.
assert_diags() {
  af="$1"; an="$2"
  if "$MEDAKA" check "$af" >"$WORK/chk.out" 2>&1; then
    echo "FAIL: generated fixture typechecks CLEANLY — an N-diagnostic shape has drifted:"
    echo "  expected $an diagnostics, got a clean check."
    return 1
  fi
  got="$(grep -c '^error: ' "$WORK/chk.out")"
  # ── HOLE, reported not papered over (#2160 phase 2) — the COUNT-MISMATCH branch.
  # It is distinct from the two regime asserts above: it fires when the fixture
  # still typechecks in the right REGIME but stops producing the expected NUMBER of
  # diagnostics. `an` is the shape's own N (see the assert_regime call sites), and
  # the `errs` generator emits exactly one error per binding, so `got` tracks `an`
  # identically for every value IR_ERRS_N can take — there is no add-only knob that
  # separates them.
  #
  # The one route that could have separated them was a diagnostic CAP in the
  # compiler (emit N errors, print the first K). TESTED, 2026-08-29, and there is
  # no cap — so this branch stays undriven:
  #
  #   $ ./medaka check /tmp/cap.mdk        # 5000 bindings, one type error each
  #   $ grep -c '^error: ' out             # 5000
  #
  # It is left in place: it costs one comparison and it is correct the day the
  # generator, the compiler's error dedup, or a cap changes underneath the shape —
  # which is precisely the drift the assert exists for.
  if [ "$got" -ne "$an" ]; then
    echo "FAIL: fixture produced $got diagnostics, expected exactly $an —"
    echo "  the shape has drifted out of its diagnostic regime and its floor no"
    echo "  longer nets against the same regime."
    sed 's/^/  /' "$WORK/chk.out" | head -20
    return 1
  fi
  return 0
}

# Dispatch on the shape's declared regime (grade_shape's 3rd argument).
assert_regime() {
  case "$1" in
    clean) assert_clean "$2" ;;
    diags) assert_diags "$2" "$3" ;;
    # ⚠️ HOLE, reported not papered over (#2160 phase 2). This arm fires only on a
    # regime string that no call site passes — `grade_shape`'s 3rd argument is
    # written at six literal call sites and defaults to `clean`. There is no
    # add-only knob that reaches it, and adding one would mean a way to feed this
    # gate an unknown regime, which is a capability, not a test. It stays as a
    # structural assertion: cheap, and correct the day a seventh call site
    # mistypes its regime.
    *) echo "FAIL: unknown regime '$1' — expected 'clean' or 'diags'."; return 1 ;;
  esac
}

fail=0
graded=0

grade_shape() {
  shape="$1"; base_n="$2"; regime="${3:-clean}"
  if [ -n "$IR_ONLY" ] && [ "$IR_ONLY" != "$shape" ]; then return 0; fi

  # The floor comes from THIS shape's generator, in THIS shape's diagnostic
  # regime. See the header — a shared baseline is measurably wrong.
  "gen_$shape" "$FLOOR_N" "$WORK/${shape}_floor.mdk" || return 1
  assert_regime "$regime" "$WORK/${shape}_floor.mdk" "$FLOOR_N" || { fail=1; return 1; }
  floor="$(ir_of "$WORK/${shape}_floor.mdk")" || { fail=1; return 1; }
  # OBSERVED RED (#2160 phase 2). The netting guard refuses to grade a ratio
  # whose numerator is mostly floor — the reading would be noise wearing a
  # verdict's clothes. Driven by raising the FRACTION rather than shrinking the
  # band, so the guard moves and the measurement does not:
  #
  #   $ IR_ONLY=xref IR_XREF_N=8 IR_MIN_NET_FRAC=50 sh test/diff_compiler_ir_scaling.sh
  #   FAIL xref: net Ir at N=8 (25577470) is under the netting-noise guard (90799355800).
  #   FAIL: no shape was graded — this gate proved nothing.
  #   exit=1
  min_net="$(awk -v f="$floor" -v p="$MIN_NET_FRAC" 'BEGIN{printf "%d", f*p}')"
  printf '%s: floor(N=%s) = %s Ir  (net must exceed %s)\n' \
    "$shape" "$FLOOR_N" "$floor" "$min_net"

  n1="$base_n"; n2=$((base_n * 2)); n4=$((base_n * 4))
  nets=""
  for m in "$n1" "$n2" "$n4"; do
    "gen_$shape" "$m" "$WORK/${shape}_$m.mdk" || { fail=1; return 1; }
    assert_regime "$regime" "$WORK/${shape}_$m.mdk" "$m" || { fail=1; return 1; }
    raw="$(ir_of "$WORK/${shape}_$m.mdk")" || { fail=1; return 1; }
    net=$((raw - floor))
    printf '  N=%-6s raw=%-14s net=%s\n' "$m" "$raw" "$net"
    if [ "$net" -le "$min_net" ]; then
      printf 'FAIL %s: net Ir at N=%s (%s) is under the netting-noise guard (%s).\n' \
        "$shape" "$m" "$net" "$min_net"
      echo "  The band is mis-sized — raise IR_${shape}_N; a ratio here would be noise."
      fail=1
      return 1
    fi
    nets="$nets $net"
  done

  # shellcheck disable=SC2086
  set -- $nets
  r1="$(awk -v a="$2" -v b="$1" 'BEGIN{printf "%.3f", a/b}')"
  r2="$(awk -v a="$3" -v b="$2" 'BEGIN{printf "%.3f", a/b}')"
  graded=$((graded + 1))

  # ── THE VERDICT RULE (#2063, #2100) ─────────────────────────────────────────
  #
  # WAS, until 2026-08-28:
  #
  #   over = (r1 > THRESH && r2 > THRESH)
  #   # SUSTAINED signal only: BOTH doublings over the threshold. One reading
  #   # over is a step, not a growth rate — the same rule perf_scaling uses,
  #   # for the same reason.
  #
  # The reason it cites is real, and it is perf_scaling's, not this gate's.
  # perf_scaling grades a WALL-CLOCK arm on a shared box, where a single
  # elevated ratio genuinely can be a scheduling step and the conjunct buys
  # noise rejection. This gate is Cachegrind. Measured here, three back-to-back
  # full runs against one binary (2026-08-28): relative spread on the largest
  # net was 3.8e-6, and every r1/r2 this gate printed was identical to all three
  # printed decimals across all three runs. There is no noise to reject.
  #
  # What the conjunct rejects instead is the reading r1 < t < r2 — a ratio that
  # CLIMBS across the two doublings. That is the signature of a superlinear
  # term, not of noise; a linear shape holds its ratio flat. So the imported
  # rule is not merely unnecessary here, it is inverted: it is most likely to
  # excuse exactly the shape it exists to catch. #2063 records the consequence
  # first-hand — a genuine PARTIAL revert of #2044 (the `checkRoute` call site
  # alone) reads r1=2.967 r2=3.392, and the gate calls it ok.
  #
  # The rule is now r2 alone: the later, larger-N doubling, the one that carries
  # the asymptote. NO THRESHOLD MOVED — IR_THRESH is still 3.0, and the band for
  # every shape is unchanged. This is strictly LOUDER than what it replaces
  # (every reading the old rule failed, this one also fails), which is the only
  # direction [W-QUIETER] permits.
  #
  # ⚠️ The one shape this newly reddens is `scoperefs`, whose climb is real and
  # documented — an OPEN quadratic, #2172; see KNOWN_CEIL_scoperefs. It
  # is not silenced by softening the rule; it is declared in KNOWN_SUPERLINEAR
  # above, where it is graded against its own measured ceiling AND must drain
  # itself if it is ever fixed.
  over="$(awk -v y="$r2" -v t="$THRESH" 'BEGIN{print (y>t) ? "yes" : "no"}')"

  if is_known "$shape"; then
    eval "ceil=\${KNOWN_CEIL_$shape:-}"
    eval "fixed=\${KNOWN_FIXED_$shape:-}"
    if [ -z "${ceil:-}" ] || [ -z "${fixed:-}" ]; then
      printf 'FAIL %s: ledgered in KNOWN_SUPERLINEAR but has no KNOWN_CEIL_%s / KNOWN_FIXED_%s pair.\n' \
        "$shape" "$shape" "$shape"
      echo "  A ledger row without both halves cannot drain itself — that is a skip-list, not a pin."
      fail=1
      return 0
    fi
    worse="$(awk -v r="$r2" -v c="$ceil" 'BEGIN{print (r > c) ? 1 : 0}')"
    better="$(awk -v r="$r2" -v f="$fixed" 'BEGIN{print (r < f) ? 1 : 0}')"
    if [ "$worse" = "1" ]; then
      printf 'FAIL %s: ** KNOWN-SUPERLINEAR, AND GOT WORSE ** r1=%s r2=%s (ceiling %s)\n' \
        "$shape" "$r1" "$r2" "$ceil"
      fail=1
    elif [ "$better" = "1" ]; then
      printf 'FAIL %s: ** PROMOTE: now scales within the band ** r2=%s (< %s)\n' \
        "$shape" "$r2" "$fixed"
      printf '  Remove "%s" from KNOWN_SUPERLINEAR — the declared cost is GONE.\n' "$shape"
      echo "  It may NOT stay ledgered AND ungraded."
      fail=1
    else
      printf 'known %s: r1=%s r2=%s (ledgered, ceiling %s) — see KNOWN_SUPERLINEAR\n' \
        "$shape" "$r1" "$r2" "$ceil"
    fi
  elif [ "$over" = "yes" ]; then
    printf 'FAIL %s: SUPERLINEAR (Ir) r1=%s r2=%s  (threshold %s on r2, the second doubling)\n' \
      "$shape" "$r1" "$r2" "$THRESH"
    fail=1
  else
    printf 'ok   %s: r1=%s r2=%s  (threshold %s on r2)\n' "$shape" "$r1" "$r2" "$THRESH"
  fi
  return 0
}

echo "── Ir scaling (Cachegrind instruction counts, net of a per-shape floor) ──"
echo "medaka: $MEDAKA"
valgrind --version

grade_shape xref "$XREF_N" clean
grade_shape manyifaces "$MANYIFACES_N" clean
grade_shape errs "$ERRS_N" diags
grade_shape scoperefs "$SCOPEREFS_N" clean
grade_shape diagbucket "$DIAGBUCKET_N" diags
grade_shape noimpl "$NOIMPL_N" diags

echo
# A gate that grades nothing must never report success — the invariant
# run_gates.sh states for itself, asserted here for its own shapes too.
# OBSERVED RED (#2160 phase 2) on its own, with no other arm involved — naming a
# shape that does not exist is the cheapest way in, and it also proves IR_ONLY
# cannot silently narrow a run to nothing:
#
#   $ IR_ONLY=nosuchshape sh test/diff_compiler_ir_scaling.sh
#   FAIL: no shape was graded — this gate proved nothing.
#   exit=1
if [ "$graded" -eq 0 ]; then
  echo "FAIL: no shape was graded — this gate proved nothing."
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "FAIL: $graded shape(s) graded, at least one superlinear in Ir."
  exit 1
fi

echo "PASS: $graded shape(s) graded, all sub-quadratic in Ir (threshold $THRESH)."
exit 0
