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
# IR_THRESH = 3.0 per doubling, and a shape FAILS only when BOTH doublings clear
# it (a sustained signal, never one reading). Same number and same rule as
# diff_compiler_perf_scaling.sh, deliberately — the two gates grade the same
# question on different metrics and a reader should not have to hold two
# thresholds in their head.
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
# separates a quadratic from a one-off step, and it is why the rule below wants
# BOTH doublings rather than the larger of the two.
#
# 🚨 THE THRESHOLD AND THE NETTING METHOD ABOVE ARE THIS GATE'S PUBLIC CONTRACT.
# Cite them; do not invent a second set. If a future shape needs a different
# threshold, say so AT THAT SHAPE with its own measurement — do not move this one.
#
# ── THE SHAPES ───────────────────────────────────────────────────────────────
#
# This gate is a NEW METRIC OVER EXISTING SHAPES. Both generators below are
# transcribed verbatim from test/diff_compiler_perf_scaling.sh (gen_xref,
# gen_manyifaces) — same programs, same structure, graded on `Ir` instead of on
# time/alloc/ops. Deliberately NOT a new fixture corpus: a fixture DIRECTORY is
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
  echo "SKIP: valgrind not on PATH — this gate measures Cachegrind instruction counts."
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
if ! MEDAKA_STRICT=1 "$MEDAKA" check "$WORK/freshness.mdk" >/dev/null 2>"$WORK/fresh.err"; then
  echo "FAIL: ./medaka is stale or broken — refusing to publish instruction counts for it."
  sed 's/^/  /' "$WORK/fresh.err"
  echo "  make medaka"
  exit 1
fi

THRESH="${IR_THRESH:-3.0}"

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
ERRS_N="${IR_ERRS_N:-400}"
# scoperefs: a deep local scope where the tail references EVERY bound name, most
# of them non-innermost — the #1031 shape (resolve/typecheck/mangle/emit each
# scan a List frame-list to answer "is this name bound"). The fix backs the scan
# with an OrdMap (O(log n) per lookup, not O(1)), so its post-fix ratio creeps
# toward the threshold rather than sitting flat at ~2.0 like the other shapes —
# expected for a tree-backed set, not a regression. Measured on this box: the
# pre-fix defect is invisible below ~N=2500 (both r1,r2 stay under 3.0 even with
# the O(depth^2) scan still present — the fixed cost of a `check` on this shape's
# giant expression dominates at smaller N) and only reads clearly red at N=3000:
#     base (pre-fix)  r1=3.118 r2=3.308  FAIL (both doublings > 3.0)
#     head (post-fix) r1=2.895 r2=3.159  ok   (r1 stays under; the "both doublings"
#                                              rule is exactly what keeps this from
#                                              flapping on the O(log n) creep)
SCOPEREFS_N="${IR_SCOPEREFS_N:-3000}"
# diagbucket: #1019's regression pin — see gen_diagbucket below for the shape.
# Deliberately smaller than errs's band: #1019 (unlike #2044) is a single bulk
# `++` per module, not a per-render rescan, so there is no expectation of a
# climbing ratio to chase; the point is confirming the now-fixed bulk-append
# stays linear, not finding its weakest N.
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
# ⚠️ THE RESIDUAL b = 165 IS A SECOND, DIFFERENT QUADRATIC, NOT #2068 LEFTOVER.
# `noImplHintFor` calls `tabHasName` (compiler/frontend/ast.mdk:464), a linear
# List scan over `dataParamKindsRef`, once per no-impl DETECTION — O(data-types x
# no-impl-errors), and THIS shape scales both axes together. Discriminated by
# measurement: the same route with ONE data type and N interfaces (so
# `dataParamKindsRef` stays size 1) fits b = 79 instead of 165. Filed separately.
# If that one is fixed, the numbers above move; re-derive rather than trusting them.
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

# ── the shapes (verbatim from test/diff_compiler_perf_scaling.sh) ────────────

gen_xref() {
  gn=$1; gf=$2; : > "$gf"
  printf 'f0 : Int -> Int\nf0 x = x + 1\n' >> "$gf"
  gi=1
  while [ "$gi" -lt "$gn" ]; do
    printf 'f%s : Int -> Int\nf%s x = f%s x + %s\n' "$gi" "$gi" "$((gi - 1))" "$gi"
    gi=$((gi + 1))
  done >> "$gf"
  # `main` CALLS THE HEAD OF THE CHAIN — load-bearing. `main = println 1` roots
  # nothing, so every fN is dead and the measurement describes the prelude.
  printf 'main = println (f%s 0)\n' "$((gn - 1))" >> "$gf"
}

gen_manyifaces() {
  gn=$1; gf=$2; : > "$gf"
  gr=8
  {
    gi=0
    while [ "$gi" -lt "$gn" ]; do
      printf 'interface P%s a where\n  m%s : a -> Int\n' "$gi" "$gi"
      gi=$((gi + 1))
    done
    printf 'base : Int\nbase = 1\n'
    gi=0
    while [ "$gi" -lt "$gn" ]; do
      printf 'h%s : Int\nh%s = base' "$gi" "$gi"
      gj=1
      while [ "$gj" -lt "$gr" ]; do printf ' + base'; gj=$((gj + 1)); done
      printf '\n'
      gi=$((gi + 1))
    done
    printf 'main = println h0\n'
  } >> "$gf"
}

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

# The #1031 regression pin (local, per F3 — NOT shared with perf_scaling's
# generators). One `main` with N sequential `let` bindings (a deep local scope,
# each new binding one frame deeper than the last), whose tail expression sums
# EVERY bound name — so almost all of the N lookups are non-innermost, and each
# must walk back through the frames between its binding site and the tail. That
# is exactly the shape the four #1031 sites scan a List to resolve.
gen_scoperefs() {
  gn=$1; gf=$2; : > "$gf"
  {
    printf 'main =\n'
    gi=0
    while [ "$gi" -lt "$gn" ]; do
      printf '  let x%s = %s\n' "$gi" "$gi"
      gi=$((gi + 1))
    done
    printf '  println ('
    gi=0
    while [ "$gi" -lt "$gn" ]; do
      if [ "$gi" -gt 0 ]; then printf ' + '; fi
      printf 'x%s' "$gi"
      gi=$((gi + 1))
    done
    printf ')\n'
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
    *) echo "FAIL: unknown regime '$1' — expected 'clean' or 'diags'."; return 1 ;;
  esac
}

fail=0
graded=0

grade_shape() {
  shape="$1"; base_n="$2"; regime="${3:-clean}"

  # The floor comes from THIS shape's generator, in THIS shape's diagnostic
  # regime. See the header — a shared baseline is measurably wrong.
  "gen_$shape" "$FLOOR_N" "$WORK/${shape}_floor.mdk" || return 1
  assert_regime "$regime" "$WORK/${shape}_floor.mdk" "$FLOOR_N" || { fail=1; return 1; }
  floor="$(ir_of "$WORK/${shape}_floor.mdk")" || { fail=1; return 1; }
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

  # SUSTAINED signal only: BOTH doublings over the threshold. One reading over is
  # a step, not a growth rate — the same rule perf_scaling uses, for the same
  # reason.
  over="$(awk -v x="$r1" -v y="$r2" -v t="$THRESH" \
    'BEGIN{print (x>t && y>t) ? "yes" : "no"}')"
  if [ "$over" = "yes" ]; then
    printf 'FAIL %s: SUPERLINEAR (Ir) r1=%s r2=%s  (threshold %s, both doublings)\n' \
      "$shape" "$r1" "$r2" "$THRESH"
    fail=1
  else
    printf 'ok   %s: r1=%s r2=%s  (threshold %s)\n' "$shape" "$r1" "$r2" "$THRESH"
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
