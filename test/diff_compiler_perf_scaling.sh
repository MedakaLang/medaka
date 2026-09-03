#!/bin/sh
# shell-because: instrumentation — valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing
# diff_compiler_perf_scaling.sh — the O(n²) detector.
#
# PROBLEM: agents keep introducing quadratic algorithms into the compiler. Three
# have been found and fixed in a single night (resolve's contigGo, five sites in
# typecheck, and a third in the check driver). Nothing was watching.
#
# WHY THIS IS NOT A WALL-CLOCK GATE
# ---------------------------------
# The obvious design — "fail if the build takes >N seconds" — is WRONG here, and
# would have been worse than nothing:
#
#   * CI runs on SHARED HOSTED RUNNERS that vary 2-3x run to run. A wall-clock
#     threshold is either too loose to catch anything real, or it flaps constantly
#     and gets ignored. A gate people ignore is a gate that does not exist.
#   * A constant-factor slowdown and an ALGORITHMIC blowup are different bugs. Only
#     the second gets catastrophically worse as the codebase grows, and it is the
#     one actually being introduced.
#
# WHAT THIS MEASURES INSTEAD: **SCALING**.
#
# Feed the same operation inputs of size N, 2N, 4N and check the GROWTH RATIO per
# doubling. Runner speed CANCELS OUT of a ratio:
#
#     linear      O(n)        -> ~2.0x per doubling
#     n log n                 -> ~2.1x
#     QUADRATIC   O(n^2)      -> ~4.0x     <-- what we are hunting
#
# PRIMARY METRIC IS ALLOCATION, but it is NOT the only one (issue #110).
#
# GC-allocated bytes are DETERMINISTIC — they do not depend on runner speed, cache
# state, or load at all. So an allocation-ratio gate is simultaneously
# machine-independent AND noise-free, which no timing gate can be. It stays the
# PRIMARY verdict, unchanged.
#
# But allocation is BLIND to a real bug class: a pure O(n^2) TRAVERSAL — scan a
# List / linear-search a scope once per lookup — costs TIME quadratically while
# allocating almost NOTHING extra per scan. The resolve quadratic fixed in #78
# (P-1) was exactly this: time ratios 2.63x/3.56x (quadratic) against allocation
# ratios of only 2.09x/2.11x ("ok"). An allocation-only gate could not have caught
# it, and (separately) the `bindings` fixture never even exercised the buggy path
# — every body referenced only its own local `x`, so `lookupValue`'s short-circuit
# `||` chain never fell through to scan `env.values`. See the `xref` shape below.
#
# So TIME is now ALSO graded — PER STAGE, as a self-normalizing RATIO, never an
# absolute wall-clock ceiling (a hosted runner is too noisy for that). Four rules
# make a ratio-based time gate trustworthy; all four are load-bearing:
#
#   1. PER-STAGE, NEVER A SUM. An earlier draft of this gate summed several
#      stages' times and graded the sum. That is strictly worse than useless: a
#      sum can only BLUR signals together. It read 2.7-2.9x on a CORRECT
#      compiler purely because it was adding a small stage's artifact (below)
#      into resolve's clean signal. Grading each stage separately gives each a
#      clean ratio AND names which stage regressed.
#
#   2. PIN THE HEAP: GC_INITIAL_HEAP_SIZE=2147483648 on every timing run.
#      Wall-clock carries a GC HEAP-RESIZE STEP that allocation does not. Left
#      unpinned, `exhaust-guards` reads 3.25x and `desugar` 2.72x ON A CORRECT
#      COMPILER at the sizes we sample — and then COLLAPSES back to ~2.07x /
#      ~2.16x one doubling later. A real quadratic HOLDS near 4.0x; a step does
#      not. Pinning the heap removes it (exhaust-guards 3.25 -> 2.17). An
#      unpinned time gate is a FALSE-RED GENERATOR. (Per AGENTS.md this knob
#      cannot change emitted IR, so it is safe. It is applied to the TIMING runs
#      ONLY — the allocation runs stay unpinned and their numbers are unmoved,
#      because allocation is the primary verdict and must not shift.)
#
#   3. MIN-OF-K (K>=5) per measurement. Runner noise is ONE-SIDED — a scheduling
#      stall can only make a run SLOWER, never spuriously faster — so the minimum
#      over K samples converges on the true cost FROM ABOVE (same principle as
#      PERF-RESULTS.md's "min-of-10, quiet machine").
#
#   4. A PER-STAGE FLOOR (TIME_FLOOR, 200ms). A stage whose absolute time at the
#      LARGEST N is under the floor is too small to time reliably; its ratio is
#      computed out of noise and MUST NOT gate. Such a stage is SKIPPED — and the
#      skip is PRINTED, with the measured time, so it can never be read as a
#      pass. This is what disqualifies desugar/exhaust-guards/mark (10-70ms):
#      they are exactly where the borderline readings came from.
#
# The verdict rule is NOT uniform across this file's arms, and saying so here is
# the point of this paragraph — a stale statement of the rule in the file that
# defines it is worse than no statement (#2173, applied 2026-08-28):
#
#   * WALL-CLOCK TIME arm  -> SUSTAINED signal: BOTH doublings (r1 AND r2) over
#     threshold. A noisy instrument, where a second confirming sample is what
#     separates a trend from a spike. `grade_time_stage` is the ONLY conjunct
#     left in this file; derive, don't trust this line:
#       grep -n "^[^#]*r1 > th && r2 > th" test/diff_compiler_perf_scaling.sh
#
#   * DETERMINISTIC arms (op counts, and the netted ALLOC verdicts) -> r2 ALONE.
#     An op count is a pure function of the program; there is no noise for a
#     second doubling to filter, and the reading the conjunct rejects
#     (r1 < T < r2) is a CLIMBING ratio — the signature of a superlinear term,
#     not of a sample. See the full argument at grade_op_stage.
#
# The timing verdict can ONLY make a shape FAIL that allocation called "ok" — it
# is an added detector, not a replacement. It never overrides or downgrades an
# allocation failure.
#
# THIRD ARM: OP COUNT (issue #884). TIME's four rules above exist BECAUSE time is
# noisy. A deterministic per-stage OPERATION counter (List-scan steps in
# util.contains/util.lookupAssoc, threaded through profile_main's [perf] line as a
# tab-delimited 5th column) has NONE of that noise — so it needs no heap-pin, no
# min-of-K, and crucially no 200ms floor. Its unique payoff is the SMALL front-end
# stages: `mark` (and desugar/exhaust-guards) sit under the floor on EVERY shape, so
# the TIME arm grades them NOWHERE, while OP grades them from a single run — in fact
# from the SAME deterministic wasm-off run the alloc arm already makes each size, so it
# adds ZERO profiler invocations (see profile_run/ops_from). Graded on r2 ALONE
# (#2173 — this arm is deterministic; see the header and grade_op_stage) but the
# same promote-an-alloc-ok-to-fail-never-downgrade discipline (the
# SUPERLINEAR (OPS) branch sits after the alloc and time failures). See grade_op_stage,
# ops_from, OP_STAGES, the KNOWN_SLOW_OPS ledger, and the `marksweep` money-shot (an
# OP-ONLY shape — its TIME min-of-K arm is skipped).
#
# MEASURED MARGIN (this box, 3 independent batches, pinned, min-of-5), the
# `xref` shape's gated stages on a CORRECT compiler:
#     parse      r <= 2.01      resolve  r <= 2.34      typecheck  r <= 2.14
# and on a compiler with the pre-#78 (quadratic) resolve restored:
#     resolve    r1=3.56 r2=3.89
# Against the 3.0 threshold that is ~22% headroom below and ~19% above.
#
# Usage:  sh test/diff_compiler_perf_scaling.sh
#         PERF_N=250 sh test/diff_compiler_perf_scaling.sh   # base size
# Exit:   0 all shapes scale sub-quadratically; 1 a shape regressed; 2 opt-in skip.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --list-units DERIVES the unit set from this file (#2160 rule 5) rather than
# restating it in a header comment, which is the form that rots. Two sources,
# because there are two kinds of unit: the shapes-loop entries live in the SHAPES
# assignments, and each standalone row carries its own `if want ...` marker.
#
# ⚠️ IT MUST STAY ABOVE THE ORACLE-PRESENCE CHECK BELOW. It reads only `$0`, but
# it USED TO sit after that check, so on a fresh worktree the one command that
# tells you what PERF_ONLY accepts answered "build oracles first" and exited 2 —
# which run_gates.sh reads as a skip candidate. A derive-don't-encode entry point
# that needs a 30-minute build first is one nobody uses.
if [ "${1:-}" = "--list-units" ]; then
  echo "shape units (entries of the SHAPES loop; the DEEP-only ones are marked there):"
  grep -n 'SHAPES=' "$0" | grep -v 'PERF_ONLY' | sed 's/^/  /'
  echo "row units (the standalone blocks that follow the loop):"
  grep -o '^if want [a-z-]*' "$0" | awk '{print "  " $3}'
  echo
  echo "PERF_ONLY takes a space-separated list of the names above."
  exit 0
fi


# Shape generators SHARED with test/diff_compiler_ir_scaling.sh: gen_xref,
# gen_manyifaces (#2066). Every other generator in this file is single-consumer and
# stays here. Read perf_shapes.sh's header before editing one — a change there moves
# every band and ledger ceiling in BOTH gates at once.
# `.` is a POSIX SPECIAL BUILTIN: a missing file terminates this script on the
# spot with nothing of ours on stdout, and run_gates.sh reads a gate that printed
# nothing as a skip candidate rather than a failure. Sharing these generators
# (#2066) therefore ADDED a green-by-silence path; this closes it.
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

# ── PERF_PROFILE: the DELIBERATE-RED SEAM for the harness guards (#2160 phase 2) ──
#
# This file carries a dozen "the profiler produced no figure" guards, one per row,
# all of the same shape:
#
#   case "$a1$a2$a3" in *[!0-9.]*|"") echo "FAIL ...(harness bug)"; fail=...;; esac
#
# They exist because a DEAD PROFILER must never read as a clean gate, and until
# this seam not one of them had ever been watched fire: `PROFILE` was a hardcoded
# path, so the only way in was to move test/bin/profile_main aside — which trips
# the BASELINE guard (`could not measure the baseline allocation`) and exits
# before any row is reached. An arm nobody has driven is not a pin (#2160 rule 1).
#
# PERF_PROFILE substitutes the profiler binary. It cannot quiet anything: every
# guard it reaches is a FAILURE branch, so a substituted profiler can only ADD
# reds. Default is the real binary, it is set NOWHERE in the tree (derive:
# `grep -rn PERF_PROFILE .github test Makefile`), and it prints a banner.
#
# The wrapper that reaches the PER-ROW guards rather than only the baseline one
# lives in scratch, not in test/ — a `.sh` added anywhere under the tree enrols
# itself in shard coverage ([T-SHARED-CORPUS]). It is three lines:
#
#   #!/bin/sh
#   # real output for the baseline fixture, silence for every measured one
#   case "$3" in *base*) exec /abs/path/test/bin/profile_main "$@" ;; esac
#   exit 0
#
# See the OBSERVED RED records at each guard for the transcripts.
PROFILE="${PERF_PROFILE:-$ROOT/test/bin/profile_main}"
if [ -n "${PERF_PROFILE:-}" ]; then
  echo "############################################################################"
  echo "## PERF_PROFILE=[$PERF_PROFILE] — SUBSTITUTED PROFILER. NOT a grading run. ##"
  echo "## Only for driving the dead-profiler harness guards red.                  ##"
  echo "############################################################################"
fi
# The MULTI-MODULE profiler (issue #153). The single-file PROFILE above cannot see
# the O(modules^2) family (checkModuleFullImpl / elabModuleStamp) because it never
# runs the multi-module driver — a gate must run where the bug lands. This one is
# profile_modules_main: loadProgram -> desugar -> markModules -> checkModules,
# emitting the SAME `[perf] <stage> <t>s <mb>MB` line protocol as PROFILE.
# Same add-only deliberate-red seam as PERF_PROFILE above, for the OTHER driver.
# It is a second knob rather than a reuse of PERF_PROFILE because the two binaries
# take different argument shapes, so one substitute cannot stand in for both — and
# without it the multi-module row's own "profiler produced no figure" guard is
# unreachable, i.e. exactly the unpinned arm this sweep exists to eliminate.
# Set nowhere in the tree; prints its own banner; can only ADD reds. The
# transcript it produced is recorded at the `modules` unit's OBSERVED RED header
# below, next to the two guards it reaches.
PROFILE_MODULES="${PERF_PROFILE_MODULES:-$ROOT/test/bin/profile_modules_main}"
if [ -n "${PERF_PROFILE_MODULES:-}" ]; then
  echo "############################################################################"
  echo "## PERF_PROFILE_MODULES SUBSTITUTED — NOT a grading run.                   ##"
  echo "############################################################################"
fi
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

# Collect ALL missing oracles before failing — naming only the first costs a
# round-trip per oracle in a fresh worktree (#398 — this gate is the issue's own
# example: it needs BOTH profile_main and profile_modules_main).
_missing=""
[ -x "$PROFILE" ] || _missing="$_missing $PROFILE"
[ -x "$PROFILE_MODULES" ] || _missing="$_missing $PROFILE_MODULES"
if [ -n "$_missing" ]; then
  echo "build oracles first — missing:"
  for _m in $_missing; do
    echo "  FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$_m")  (missing $_m)"
  done
  exit 2
fi

# FAIL threshold, per doubling.
#   linear 2.0 | n log n ~2.1 | n^1.5 = 2.83 | QUADRATIC 4.0
# 3.0 comfortably admits n log n (plus slack) and comfortably catches n^2. It also
# catches n^1.58 and worse. Deliberately NOT tighter: a gate that fires on noise is
# a gate that gets disabled.
THRESH="${PERF_THRESH:-3.0}"
N="${PERF_N:-250}"

# `xref` samples at a LARGER N than the other four shapes. This is FORCED, not a
# preference: the stage we must be able to see (`resolve`) only reaches 0.29s at
# N=16000. At a 2000/4000/8000 range its largest-N time is 0.137s — UNDER the
# 200ms floor — so the floor would (correctly) refuse to grade it and the gate
# could not see the very bug it exists to catch. The alternative, lowering the
# floor to 100ms, weakens the one guard that keeps a ratio from being computed
# out of noise. So: raise N, keep the floor honest.
# ── QUICK (default, per-PR) vs DEEP (nightly) ────────────────────────────────
#
# PERF_DEEP=0 (default) drops the two shapes whose N band exists ONLY to lift a single
# slow-to-clear stage over the 200ms floor, and which together were ~80% of this gate:
#
#     xref @ 4000/8000/16000   sized for `resolve` (0.29 s at 16000)   ~376 s
#     manydefs @ 4000/8000/16000  sized for `lint` (0.62 s at 16000)   ~100 s
#
# QUICK still runs `xref`, at 2000/4000/8000 — it does NOT drop the shape, and that is
# the point of the split. The BACKEND rows survive: `emit` reads 2.74 s and `wasm-emit`
# 10.4 s at 8000, both far over the floor and both still ledgered and graded, so
# backend_graded stays 1 and #359's arm keeps running on every PR. Only `resolve` falls
# under the floor (~0.145 s at 8000) and SKIPs — loudly — so the #78 resolve detector is
# what DEEP is really for.
#
# ⚠️ WHY THIS SPLIT AND NOT "MOVE perf_scaling TO NIGHTLY": jobs run in parallel, so CI
# wall-clock is the SLOWEST shard. At 12 min this gate WAS `gates (types)` and was the
# critical path, 3x `gates (engines)` (3.7 min) — the shard the ci.yml header still
# names as the pole. Deleting the gate from PRs would fix the clock and cost all per-PR
# perf coverage; this keeps the arm that catches emitter quadratics where the bug lands
# and banishes only the two N=16000 bands, which no amount of restructuring can afford:
# at K=5 they are irreducible. (Measured: routing every stage to its own band still only
# reaches ~400 s. You cannot hold N=16000 at K=5 and get under 4 min.)
#
# DEEP is not optional coverage — nightly.yml runs it, and the skips print loudly rather
# than silently narrowing the gate. Run it locally with PERF_DEEP=1.
PERF_DEEP="${PERF_DEEP:-0}"

# xref's band follows the mode: DEEP keeps resolve's 4000 (-> 16000 at 4N), QUICK uses
# 2000 (-> 8000), which is also XREF_WASM_N — so in QUICK the wasm row rides the main
# pass and costs no extra invocation at all (see grade_wasm_row).
if [ "$PERF_DEEP" = "1" ]; then XREF_N="${PERF_XREF_N:-4000}"; else XREF_N="${PERF_XREF_N:-2000}"; fi

# `comments` samples at its own N so the `fmt` stage clears the 200ms TIME_FLOOR at
# the largest size (4N): at base 1000 → 4000, fmt is ~0.46s on a correct compiler,
# comfortably gradeable. Smaller and the floor would (correctly) refuse to grade
# it, blinding the gate to the formatter/comment quadratic it exists to catch.
COMMENTS_N="${PERF_COMMENTS_N:-1000}"

# `manydefs` samples at its own N for the same reason `xref` does: the stage it
# must be able to see (`lint`) only reaches ~0.62s at N=16000 (4N of 4000). At a
# 2000-base range its largest-N lint time is 0.28s — barely over the 200ms floor,
# so a faster runner could drop it UNDER and the floor would silently SKIP the one
# stage this shape exists to grade. Sized for ~3x floor headroom instead.
MANYDEFS_N="${PERF_MANYDEFS_N:-4000}"

# `matchlits` (issue #988) is DEEP-only and graded in its own block below, on the
# TYPECHECK-STAGE net allocation (where exhaust runs) — NOT the total-alloc arm,
# which the wide match's large LINEAR emit cost dilutes below the ceiling (measured:
# even at 4000 the total r2 is only ~2.5 while the typecheck-STAGE net r2 is ~3.65).
# The band is sized so the fixed (linear) state reads a clean r≈2.0 and the reverted
# (quadratic) state clears the 3.0 ceiling with margin: net typecheck alloc, base
# ~7 MB subtracted, FIXED 6.6→13.1→26.1 (r1 1.99 r2 2.00), REVERTED 21.8→74.1→270.2
# (r1 3.40 r2 3.65). Alloc is deterministic, so ONE run per size suffices.
MATCHLITS_N="${PERF_MATCHLITS_N:-1000}"

# `manyifaces` / `widerecords` (issue #883) run at the DEFAULT N band (250/500/1000).
# Both are OP-ONLY (deterministic, no min-of-K), so the band is chosen for the OP arm,
# not a TIME floor: at 250/500/1000 `manyifaces` clears mark op r1>3 (3.07/3.54) with R=8
# co-scaling, and `widerecords`'s resolve op is graded as a DETERMINISTIC RATIO in its
# dedicated block below. Since #984 (ownersOf indexed + `opBump`-counted) its counted
# resolve signal is the record-resolution `contains owner owners` (3N) PLUS one op per
# `ownersOf` probe (2N) = 5N+1 = 1251 at N=250 — now OVER OP_FLOOR (was 751/UNDER, when
# ownersOf was a hand-rolled uncounted scan). Knobs reserved for DEEP/tuning; defaults
# match the ledgered bands.
MANYIFACES_N="${PERF_MANYIFACES_N:-$N}"
WIDERECORDS_N="${PERF_WIDERECORDS_N:-$N}"

# `consfam` (issue #1029) samples at 200/400/800 rather than the default 250/500/1000.
# Its cost is driven by the BACKEND, not the front end, and pre-fix it was near-cubic in
# N — so the band is chosen from the ALLOC arm's side: 200/400/800 is where the defect was
# reproduced (net alloc r1 3.30, r2 4.82 — clear of the 3.0 ceiling, and the emit TIME row
# goes red there too) while keeping the largest sample at 800 functions, comparable to the
# other shapes' 1000. See gen_consfam.
CONSFAM_N="${PERF_CONSFAM_N:-200}"

# `conlocal` (issue #2030) samples at 400/800/1600, NOT the default 250/500/1000, and
# the band is FORCED by the defect's own curve rather than by a floor. MEASURED op
# counts for typecheck on this box (deterministic, single run):
#     100/200/400    20 491 ->   37 741 ->   102 241   r1 1.84 r2 2.71  — MISSES it
#     400/800/1600  102 241 ->  351 241 -> 1 329 241   r1 3.44 r2 3.78  — RED
# i.e. at the default band the rule in force when this band was chosen
# (both doublings) would have read `ok` and this shape would pin nothing. Since
# #2173 the op arm grades r2 alone, so 100/200/400's r2=2.71 would STILL read `ok`
# and the band choice below is unchanged by the flip — it is now the smallest base
# that reddens r2 with margin rather than the smallest that reddens both. 400 is
# chosen deliberately over 800 (which reads 3.78/3.92) because
# cost scales with the band: 400/800/1600 costs ~13 s of native profiler time here
# (1.4 + 3.0 + 9.1 s), 800/1600/3200 costs ~55 s. Do not raise it without re-pricing.
#
# ⚠️ THE CEILINGS BELOW ARE BAND-SPECIFIC. A ratio measured at 400/800/1600 does not
# transfer — moving this knob invalidates KNOWN_OCEIL_conlocal_typecheck /
# KNOWN_OCEIL_conlocal_mark and both must be re-derived, not scaled.
CONLOCAL_N="${PERF_CONLOCAL_N:-400}"

# `guardwild` (issues #2333, #2125) samples at 100/200/400, NOT the default
# 250/500/1000, and the band is FORCED from BOTH sides. It is the only shape here
# whose PROGRAM SIZE is linear in N while its lowered decision TREE is quadratic in
# N (see gen_guardwild): branch `Ci` legitimately carries the `i` guarded wildcard
# rows that precede it, so the tree has sum(i) = Θ(N²) nodes and `emit` renders
# every one of them. MEASURED total profiler wall/alloc on this box (single
# deterministic run, wasm off):
#     N= 50   0.33 s   195 MB
#     N=100   0.44 s   274 MB
#     N=200   0.97 s   526 MB
#     N=400   2.86 s  1415 MB
#
# CEILING SIDE — cost. 100/200/400 costs ~4.3 s per shared run; 200/400/800 would
# cost ~25 s and ~5 GB of peak allocation for the same verdict. Do not raise it
# without re-pricing.
#
# FLOOR SIDE — the smaller band DILUTES THE SIGNAL PAST THE VERDICT LINE, and this
# is why 50 was rejected rather than merely un-preferred. MEASURED, same tree,
# same box, net alloc after BASE_ALLOC subtraction:
#     50/100/200    48.2 -> 127.2 ->  380.0 MB   r1 2.64  r2 2.99   reads "ok"
#    100/200/400   127.1 -> 380.0 -> 1268.3 MB   r1 2.99  r2 3.34   ** SUPERLINEAR
# The 50-band's r2=2.99 against a 3.0 threshold is not a linear reading, it is the
# SAME quadratic one hundredth under the line — a band that certifies the defect as
# fine and flaps red on any unrelated allocation drift. 100 is the smallest base
# that states the verdict with margin.
#
# ⚠️ THE CEILINGS BELOW ARE BAND-SPECIFIC: moving this knob invalidates
# KNOWN_CEIL_guardwild / KNOWN_FIXED_guardwild, which must then be re-derived, not
# scaled (the two rows above are the same curve resampled — 50's r2 IS 100's r1).
GUARDWILD_N="${PERF_GUARDWILD_N:-100}"

# `nestedparens` (#164, S-4) samples at 4000/8000/16000 — S-3's own per-stage
# isolation band (`profile_main`, no CLI redundancy). Sized to match the exact
# depths S-3 measured the substrate at, not the default 250/500/1000: `parse`
# only shows its superlinear signature once single calls run into multiple
# seconds (0.31s -> 1.03s -> 4.8s here), and a smaller band dilutes into the
# fixed-prelude/startup constant the way `xref`'s note above warns about.
# DEEP-only (nightly) — see the SHAPES/PERF_DEEP gate below and its cost note.
NESTEDPARENS_N="${PERF_NESTEDPARENS_N:-4000}"

# `xref` samples the WASM arm at its OWN, SMALLER band — 2000/4000/8000 rather than
# the shape's 4000/8000/16000. This is a COST fix and it is the reason this gate is
# not the CI critical path. The band is deliberate — a ratio measured here does not
# transfer to another band (see the XREF_WASM_N note below and grade_wasm_row's xref
# arm before changing it).
#
# Why the band can move at all: xref's N is sized for `resolve`, the only stage that
# needs N=16000 to clear the 200ms floor. wasm_emit is ~10x llvm_emit and was being
# dragged to resolve's N — 42 s per run, x K=5 = ~211 s of one CI shard for ONE row.
# At 8000 it still reads ~10 s, 50x the floor, and still reads r2=3.82. The signal
# does not need N=16000; only `resolve` did.
XREF_WASM_N="${PERF_XREF_WASM_N:-2000}"

# min-of-K sample count for the TIME signal. K>=5 required (see file header);
# allocation needs no such thing — it is deterministic, one run suffices.
PERF_K="${PERF_K:-5}"

# A stage whose absolute time at the LARGEST N is below this is too small to
# time-gate — its ratio would be noise. It is SKIPPED, loudly. See rule 4.
TIME_FLOOR="${PERF_TIME_FLOOR:-0.2}"

# Pin the GC heap for TIMING runs only — see rule 2. Without this the gate emits
# false reds from a heap-resize step on a perfectly correct compiler.
TIME_HEAP="${PERF_TIME_HEAP:-2147483648}"

# ── KNOWN SUPERLINEAR (a ledger, NOT a skip-list) ────────────────────────────
#
# A shape listed here is ALREADY superlinear — a real, filed bug. It is recorded
# rather than skipped, following the same model as diff_compiler_engines.sh's
# ledger, CAPABILITY-EXCEPTIONS.txt, and rustc's tests/crashes. Each entry asserts
# the CURRENT, WRONG behavior, so that:
#
#   (a) the bug cannot get any worse silently — a listed shape still FAILS if it
#       exceeds its recorded ceiling; and
#   (b) an ACCIDENTAL FIX is DETECTED — if a listed shape drops back to linear, this
#       gate FAILS and demands promotion.
#
# (b) is the whole point and is why this is not a skip-list. A skip-list cannot
# notice when a bug is fixed, so it ROTS — which is precisely how test/ported/ died
# (nothing ran it for months) and how diff_compiler_lint_multi sat "skipped" while
# also failing. Do not "simplify" this into a skip.
#
# CURRENT ENTRIES:
#
#   modules — the O(modules^2) family (issue #153), measured through the
#           multi-module driver (profile_modules_main -> checkModules). N import-
#           chained modules, K=8 impls each; the accumulated decl universe that
#           checkModuleFullImpl rescans per module and elabModuleStamp rebuilds via
#           buildKeyTable(accAll ++ prog) grows O(modules), rescanned per module =
#           O(modules^2). This is a REAL, UNFIXED quadratic filed as #154/#150 —
#           NOT a shape that should be green. It is ledgered (not shipped red)
#           BECAUSE those fixes have not landed: the ledger asserts the current bad
#           net-total-allocation ratio so the gate is green now, FAILS if the ratio
#           worsens (KNOWN_CEIL_modules), and FAILS demanding promotion the moment
#           #154/#150 drop it back to linear (KNOWN_FIXED_modules) — which is the
#           measurement those Phase-2 fixes were asked to turn green. The fixture
#           TYPECHECKS 0-DIAGNOSTIC (proven with `medaka check`) — see gen_modules;
#           a resolve-broken fixture would measure a DIFFERENT module-count-scaling
#           mechanism (per-module rebinding of unresolved names), not this one.
#           MEASURED (this box, deterministic net-total alloc, N=100/200/400, K=8):
#             net-N 286 MB -> net-2N 927 MB -> net-4N 3313 MB   r1=3.24 r2=3.57
#           and the typecheck stage in isolation (where the bug lives) r1=3.50
#           r2=3.78. The ratio CLIMBS toward the pure-quadratic 4.0 as N grows
#           (typecheck alloc 3.78 -> 3.91 at N=400/800), so it is a quadratic, not a
#           heap-resize step. TIME is separately ledgered in KNOWN_SLOW_TIME.
#
# HISTORY — entries that were fixed and promoted OUT of this ledger:
#
#   match — exhaustiveness checking (compiler/frontend/exhaust.mdk + the
#           `check_match` driver in compiler/types/typecheck.mdk) over an
#           N-constructor data decl with an N-arm match. Filed as T17, ratio
#           CLIMBING with N (2.48x -> 2.75x -> 3.10x per doubling; 274 MB net
#           allocation at N=1000). FIXED 2026-07-13: it was FOUR quadratics
#           stacked, all of the same "re-scan the whole thing once per element"
#           shape — `usefulCovered` called `specializeCon` (a full matrix scan)
#           once per signature constructor, `allCovered` did an O(#ctors x #rows)
#           list-membership scan, the constructor oracle's four tables were assoc
#           LISTS so every arity/type lookup was O(#ctors), and the redundant-arm
#           fold re-ran the whole Maranget recursion against every preceding arm.
#           Now: rows are bucketed by head constructor in ONE pass, the oracle is
#           an OrdMap, and the redundancy fold skips arms that provably cannot be
#           unreachable. 3.10x -> 2.18x; 274 MB -> 118 MB at N=1000.
#   modules — MULTI-MODULE typecheck (issue #153/#154). The whole O(modules^2) family.
#           #154 PR-A eliminated registerAllData's per-module public-data re-registration
#           (the DOMINANT concat, ~11x coefficient cut; r2 ~4.0 -> ~2.27); PR-B made
#           argDispatchIndices/registerAllData incremental; PR-C (this) removed the LAST
#           quadratic — the `accAll ++ prog` / `accData ++ publicDataDecls` concats in
#           foldModules, which copied a GROWING left operand every iteration. The perf-gate
#           `checkModules` path reads NEITHER accumulator (checkBodyImpl binds accData as a
#           dead `Module _ _ _` field; cmCheckWorker ignores accAll), so PR-C threads them
#           UNCHANGED there via per-worker wantData/wantAll signals — O(N) total. MEASURED
#           net-alloc, FLAT and linear to N=1600 (r2 2.02 @ 100/200/400, 2.02 @ 200/400/800,
#           2.04 @ 400/800/1600; 91 -> 183 -> 370 -> 748 -> 1528 MB), and typecheck TIME
#           dropped under the 200ms floor. PROMOTED OUT 2026-07-16 — now a HARD linear gate.
#   guardwild — LOWERING a match that interleaves constructor arms with GUARDED
#           column-0 wildcard arms (issue #2125, the residual of #408's fix). The
#           entry is LIVE, and unlike every drained row above it is not a claim
#           that someone forgot to fix a scan: `conBranch`
#           (compiler/ir/core_ir_lower.mdk) hands every constructor branch its own
#           copy of the column-0 wildcard rows via `map (padWildRow a) wilds`, and
#           at this shape both the head count and the wildcard-row count are Θ(N),
#           so the work — AND THE LOWERED TREE ITSELF — is Θ(N²). Branch `Ci`
#           genuinely has to test the `i` guards that precede it, so a linear
#           reading here would mean the tree stopped being built correctly, not
#           that the cost was optimised away. That is why the ceiling is
#           QUADRATIC-AWARE rather than a 3.0-ish "nearly fixed" number, exactly as
#           KNOWN_ACEIL_reexports_resolve is (see its note: same reasoning, alloc
#           arm, intrinsic O(N²) corpus). MEASURED on this box, net alloc after
#           BASE_ALLOC subtraction, N=100/200/400:
#               127.1 -> 380.0 -> 1268.3 MB   r1 2.99  r2 3.34
#           OBSERVED RED before ledgering, verbatim:
#               $ PERF_ONLY=guardwild PERF_GUARDWILD_N=100 sh test/diff_compiler_perf_scaling.sh
#               guardwild  100  127.1 MB  380.0 MB  1268.3 MB  2.99  3.34 \
#                 ** SUPERLINEAR (ALLOC) ** (r2 > 3.0x)
#           CEILING 3.68 = the measured r2 (3.34) + 10% (S-2's headroom convention),
#           and it is capped well below the 4.0 a pure quadratic converges to, so a
#           CUBIC regression — the thing that would mean `wilds` started being
#           re-derived per branch instead of once — still reds this row. FIXED 2.60
#           is the file-wide convention and sits under the linear-ish readings the
#           50-band produces, so a band shrink cannot false-PROMOTE it.
#           ⚠️ DRAINING THIS ROW IS NOT A MATTER OF MAKING A SCAN FASTER. #2125 is
#           discharged only by a lowering that stops materialising one branch per
#           head with the full wildcard tail (e.g. sharing the guard chain), which
#           is a codegen change, not a data-structure swap.
KNOWN_SUPERLINEAR="
guardwild
"
KNOWN_CEIL_guardwild="${KNOWN_CEIL_guardwild:-3.68}";  KNOWN_FIXED_guardwild="${KNOWN_FIXED_guardwild:-2.60}"

# ── PERF_LEDGER_EXTRA: the DELIBERATE-RED SEAM for the ledger branches (#2150) ──
#
# The ledger branches are the hardest code in this file to observe red, because they
# only run when a row is BOTH ledgered AND doing something the ledger did not predict.
# When these knobs were built KNOWN_SUPERLINEAR was EMPTY (every entry had drained); it
# now carries exactly one live row (`guardwild`, #2125), which is still not a way to
# observe the MALFORMED / GOT-WORSE / PROMOTE branches without editing the ledger. An
# unobservable branch is exactly what #2160 exists to stop shipping, so there has to be
# a way in.
#
# These three variables APPEND to the three ledgers. They are:
#   * ADD-ONLY — nothing can remove a real ledger entry through them, so they cannot be
#     used to quiet a live row;
#   * default-empty, and never set by CI or by any script in this tree (derive:
#     `grep -rn PERF_LEDGER_EXTRA .github test Makefile`);
#   * announced with a LOUD BANNER on every run that sets one (below), so a run under an
#     injected ledger can never be mistaken for a graded one.
# They exist for the observe-red record kept beside each branch, and for the next person
# who has to re-observe it.
PERF_LEDGER_EXTRA="${PERF_LEDGER_EXTRA:-}"
PERF_LEDGER_EXTRA_TIME="${PERF_LEDGER_EXTRA_TIME:-}"
PERF_LEDGER_EXTRA_OPS="${PERF_LEDGER_EXTRA_OPS:-}"
if [ -n "$PERF_LEDGER_EXTRA$PERF_LEDGER_EXTRA_TIME$PERF_LEDGER_EXTRA_OPS" ]; then
  echo "############################################################################"
  echo "## LEDGER INJECTION ACTIVE — this run's verdicts are NOT a grading result. ##"
  echo "##   alloc += [$PERF_LEDGER_EXTRA]  time += [$PERF_LEDGER_EXTRA_TIME]  ops += [$PERF_LEDGER_EXTRA_OPS]"
  echo "## Only for observing the ledger branches red. Never set this in CI.       ##"
  echo "############################################################################"
fi

is_known() {
  for k in $KNOWN_SUPERLINEAR $PERF_LEDGER_EXTRA; do [ "$k" = "$1" ] && return 0; done
  return 1
}

# ── THE CLIMBING CLAUSE'S CONSTANTS, AND WHY THEY ARE NOW REACHABLE ──────────
#
# Eight verdict `awk`s in this file carry the same second clause:
#
#   climbing = (r2 > r1 * 1.15 && r2 > 2.45)
#
# — a ratio that CLIMBS across the two doublings while staying under the
# threshold, which is a quadratic showing itself early rather than a step.
#
# 🚨 PHASE 1 REPORTED THIS CLAUSE AS A PERMANENT HOLE: "THE CLIMBING CLAUSE HAS
# NO SUCH RECORD, AND CANNOT HAVE ONE HERE... no knob reaches it." That is TRUE of
# the knobs phase 1 had and FALSE as a statement about the clause. Two ways in
# were found by phase 2's sweep:
#
#   1. It is ALREADY REACHABLE with no new knob at all, on the `modules` TIME
#      row, whose r1/r2 sit in the window where climbing fires and threshold does
#      not. Observed on this box, 2026-08-28, from an unmodified gate:
#
#        $ PERF_ONLY=modules sh test/diff_compiler_perf_scaling.sh
#        modules  100  397.2 MB  853.8 MB  1943.8 MB  2.15  2.28  ok
#          time typecheck: ** SUPERLINEAR (TIME) ** 0.2433...s -> 0.5229...s -> 1.4189...s
#              r1=2.15 r2=2.71 (climbing: r2 > r1 x 1.15 AND r2 > 2.45)
#        exit=1
#
#      (That row is #1879's known wall-clock flake — which is exactly why it is
#      the one row that lands in the window. It proves the CLAUSE fires and names
#      itself correctly, which is what phase 1 said could not be shown.)
#
#   2. For every OTHER copy of the clause, PERF_CLIMB_R / PERF_CLIMB_MIN below.
#
# ⚠️ THESE TWO KNOBS ARE CLAMPED SO THEY CAN ONLY MAKE THE CLAUSE LOUDER. A value
# ABOVE the shipped default would narrow the window and quiet a live row, which is
# [W-QUIETER] wearing a debugging hat; it is refused with a hard exit rather than
# silently ignored, because a refused-but-ignored knob is how a "narrowed" run
# gets mistaken for a graded one. Loosening the clause is a source edit with a
# measurement attached, not an env var.
PERF_CLIMB_R="${PERF_CLIMB_R:-1.15}"
PERF_CLIMB_MIN="${PERF_CLIMB_MIN:-2.45}"
if [ "$(awk -v a="$PERF_CLIMB_R" 'BEGIN{print (a+0 > 1.15) ? 1 : 0}')" = "1" ] \
   || [ "$(awk -v a="$PERF_CLIMB_MIN" 'BEGIN{print (a+0 > 2.45) ? 1 : 0}')" = "1" ]; then
  echo "FAIL: PERF_CLIMB_R/PERF_CLIMB_MIN may only be LOWERED (defaults 1.15 / 2.45)."
  echo "  Got R=$PERF_CLIMB_R MIN=$PERF_CLIMB_MIN. Raising either NARROWS the climbing"
  echo "  clause, i.e. quiets a live row — [W-QUIETER]. Loosening this clause is a"
  echo "  source change with a measurement attached, not an environment variable."
  exit 1
fi
if [ "$PERF_CLIMB_R" != "1.15" ] || [ "$PERF_CLIMB_MIN" != "2.45" ]; then
  echo "############################################################################"
  echo "## CLIMBING CLAUSE SENSITISED: R=$PERF_CLIMB_R MIN=$PERF_CLIMB_MIN (defaults 1.15 / 2.45)."
  echo "## This run is STRICTLY LOUDER than a graded one, and is NOT a verdict.     ##"
  echo "############################################################################"
fi

# ── PERF_ONLY: run ONE unit of this gate (#2160 phase 2) ─────────────────────
#
# This gate has no per-unit selector, and that cost phase 1 real time: every
# observed-red record it kept had to be produced by a WHOLE run (~7 min QUICK),
# because there was no way to say "just the bindings shape" or "just the
# emittables row". test/diff_compiler_ir_scaling.sh has had IR_ONLY since it was
# written and the difference in per-arm cost is the reason this exists.
#
# A UNIT is either a shape name from $SHAPES or one of the standalone row blocks
# that follow the shapes loop. Derive the full set — never trust a list in a
# comment:
#
#   sh test/diff_compiler_perf_scaling.sh --list-units
#
# PERF_ONLY takes a SPACE-SEPARATED list, so a sweep can drive two related units
# in one run. Empty (the default, and the only value in CI: derive with
# `grep -rn PERF_ONLY .github test Makefile`) runs everything and behaves exactly
# as before — `want` is the only thing that reads it.
#
# 🚨 A NARROWED RUN IS NOT A VERDICT, and this gate has three end-of-run guards
# whose whole job is to notice that an arm graded nothing (ops_graded==0,
# backend_graded==0, and the measured-nothing check). Under PERF_ONLY those
# guards would fire on scope rather than on breakage, so they are SKIPPED and the
# skip is printed. That is safe in exactly one direction: with PERF_ONLY unset
# they are untouched, so this knob can never make a real run quieter
# ([W-QUIETER]). The banner says the same thing at the top of the output.
PERF_ONLY="${PERF_ONLY:-}"
if [ -n "$PERF_ONLY" ]; then
  echo "############################################################################"
  echo "## PERF_ONLY=[$PERF_ONLY] — NARROWED RUN. This is NOT a grading result:  ##"
  echo "## unnamed units did not run, and the end-of-run coverage guards are off.  ##"
  echo "############################################################################"
fi

# want <unit> — true when the unit should run. The ONLY reader of PERF_ONLY.
want() {
  [ -z "$PERF_ONLY" ] && return 0
  for _w in $PERF_ONLY; do [ "$_w" = "$1" ] && return 0; done
  return 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── The shapes ───────────────────────────────────────────────────────────────
# Each stresses a DIFFERENT structure, because O(n^2) hides in specific ones and a
# single generator would miss whole classes. (A quadratic in exhaustiveness checking
# is invisible to a program with no `match`.)
#
#   bindings — symbol table, scope threading, letrec grouping, generalization.
#              THIS IS WHERE ALL THREE QUADRATICS FOUND SO FAR LIVED. But see the
#              WARNING below — this shape's bodies do not actually reference each
#              other, so it does NOT exercise cross-reference name lookup.
#   match    — exhaustiveness (Maranget's pattern-matrix algorithm is a classic
#              O(n^2) risk) and constructor tables.
#   listlit  — parser/lexer recursion and Core-IR lowering over a wide literal.
#   nesting  — deep recursion in the tree-walking passes.
#   xref     — CROSS-REFERENCING top-level bindings (each fN's body calls
#              f(N-1)). `bindings` above generates N functions whose bodies
#              reference only their own local parameter `x` — `lookupValue` is a
#              short-circuiting `||` chain that hits the local on element 1 and
#              NEVER scans `env.values`, so a bug in that scan is invisible to
#              it. Real code cross-references constantly; this shape is what
#              actually walks the scope chain, which is where #78's resolve
#              quadratic lived. Graded on TIME (see file header), not
#              allocation — the #78 bug was a pure scan, near-zero extra alloc.
#   comments — the COMMENT side-channel + the FORMATTER. N functions each with a
#              leading + two trailing comments, so comment count scales with N.
#              The ONLY shape that exercises `fmt` (profile_main runs formatSource):
#              lexer.collectComments/posLineColFrom and fmt.formatProgram. Both
#              historical quadratics here were pure scans (offset→line rescanned
#              from 0 per comment; remaining-comment-tail rescanned per decl), so
#              like #78/#115 they are graded on TIME — allocation is blind to them.
#              See gen_comments and the fmt entry in TIME_STAGES.
#   manydefs — the LINTER's per-file tier. N signed tiny private defs + one export.
#              The other shapes are blind to it: `bindings` has no signatures (so
#              ruleMissingSignature's set stays empty) and its defs are too few to
#              separate the O(defs^2) term from the rule's heavy linear term. Both
#              of this rule's fixed quadratics were List-as-a-SET (dead-code's
#              assoc-list ref map + `contains`-over-visited; missing-signature's
#              `contains` over signed names) — the same shape as #78/#115 — and
#              BOTH are invisible to the alloc verdict (see the `lint` note in
#              TIME_STAGES), so this shape is graded on lint TIME.
#   manyifaces — CO-SCALED interfaces x call sites (issue #883). N interface decls
#              (methods pool ~N) AND N reference sites, growing TOGETHER, so mark's
#              `contains x methods` List-as-set read O(N^2). OP-ONLY (mark is under the
#              TIME floor); FIXED both quadratics it surfaced (manyifaces:mark #953,
#              manyifaces:resolve #954) — no longer ledgered. See gen_manyifaces.
#   widerecords — the RECORD shape (issue #883). One record type with N fields + N tiny
#              accessor/updater decls. Exercises resolve's ownersOf/lookupRecordByName —
#              but those are HAND-ROLLED (uncounted), so op reads LINEAR: an `ok` guard,
#              not an ownersOf detector (the real O(N^2) is TIME-only, N>=~4000). OP-ONLY.
#              See gen_widerecords.
#   conlocal — the CONSTRAINED-BINDING shape (issue #2030). N constrained top-level fns,
#              each with exactly ONE local. Co-scales the two dimensions typecheck's
#              local-pin bookkeeping multiplies (constrained top-level bindings x local
#              bindings), which no other shape does: `bindings`/`xref` have no
#              constraints at all, `manyifaces` grows the METHOD POOL against a fixed
#              site count, and `marksweep` does the same. OP-ONLY. Ledgers
#              conlocal:typecheck (#2030, mechanism known: localPinPairs).
#              conlocal:mark (#2143) was a second quadratic this shape surfaced —
#              FIXED as a side effect of slice 5's #1017 marker.mdk fix; de-ledgered.
#              See gen_conlocal.
#   consfam  — the BACKEND shape (issue #1029). N mutually cons-tail-recursive fns — the
#              only thing in this corpus that reaches trmc_analysis's dispatch-TMC group
#              GROWTH WALK, which runs unconditionally in both backends' emitProgram.
#              `xref` chains N fns but with no cons tail, so the walk's consTargets
#              pre-gate rejects every root and xref reads clean linear. Graded on the
#              ALLOC arm; pre-fix it read NEAR-CUBIC. See gen_consfam.
#   modules  — MULTI-MODULE (issue #153). The five shapes above are single-file,
#              so they run only the single-file driver and are STRUCTURALLY BLIND
#              to the O(modules^2) family in checkModuleFullImpl / elabModuleStamp.
#              This shape runs the multi-module driver (profile_modules_main) over
#              N import-chained modules — see gen_modules and the dedicated block
#              after the single-file loop. It is a LEDGERED, currently-UNFIXED
#              quadratic (#154/#150); see KNOWN_SUPERLINEAR / KNOWN_SLOW_TIME.
gen_bindings() {
  n=$1; f=$2; : > "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    printf 'f%s : Int -> Int\nf%s x = x + %s\n' "$i" "$i" "$i"
    i=$((i+1))
  done >> "$f"
  # An `emit`-able program MUST have a `main` — emitProgram panics "no `main`
  # binding" without one, which aborted the WHOLE profiler (issue #359 wiring).
  # It matches the _baseline.mdk fixture, so it subtracts straight back out.
  printf 'main = println 1\n' >> "$f"
}

gen_match() {
  n=$1; f=$2; : > "$f"
  # one data decl with N constructors, and one match with N arms over it
  printf 'data T%s =\n' "$n" >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    if [ "$i" -eq 0 ]; then printf '  C%s\n' "$i"; else printf '  | C%s\n' "$i"; fi
    i=$((i+1))
  done >> "$f"
  printf 'toInt : T%s -> Int\ntoInt v = match v\n' "$n" >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf '  C%s => %s\n' "$i" "$i"; i=$((i+1)); done >> "$f"
  # ⚠️ `main` CALLS `toInt`, and that is load-bearing — do not "simplify" it.
  #
  # This shape is the OPPOSITE of xref and the more dangerous one: its whole cost is
  # concentrated in a SINGLE decl (`toInt`, N arms over N ctors) rather than spread
  # across N decls. `main = println 1` roots nothing, so dceFilter prunes `toInt`
  # outright and the backend stages time an empty program — this shape read a
  # meaningless 22 ms at N=1000 and SKIPped, i.e. it silently graded NOTHING.
  # Rooting `toInt` puts that one big decl on the live path, where DCE cannot touch
  # it, which is exactly where a per-decl blowup in the emitter would show.
  printf 'main = println (toInt C0)\n' >> "$f"
}

gen_matchlits() {
  n=$1; f=$2; : > "$f"
  # The LITERAL sibling of gen_match (issue #988). One match with N arms over N
  # distinct INTEGER LITERALS (0..N-1) + a wildcard default (an Int-literal match
  # needs one to be exhaustive). Where gen_match drives exhaust's CONSTRUCTOR
  # matrix (specializeCon), this drives the LITERAL matrix — specializeLit /
  # specLitRow in compiler/frontend/exhaust.mdk. specLitRow compared literals with
  # the derived `Eq Lit`, which ALLOCATES per call, so exhaustiveness-checking this
  # shape ran O(arms^2) ALLOCATION in the typecheck stage (#970/#978 was the same
  # root cause in core_ir_lower's LOWERING path; this is the EXHAUST path, ungated
  # until now — the untyped eval_scaling bigmatch_lits never runs typecheck/exhaust).
  # #988 replaced it with an alloc-free `litEq` (identical Bool as `Eq Lit`).
  printf 'classify : Int -> Int\nclassify v = match v\n' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf '  %s => %s\n' "$i" "$i"; i=$((i+1)); done >> "$f"
  printf '  _ => 0\n' >> "$f"
  # main CALLS classify — same reason gen_match roots toInt: `main = println 1`
  # roots nothing, so DCE prunes classify and the exhaust work never runs.
  printf 'main = println (classify 0)\n' >> "$f"
}

gen_guardwild() {
  n=$1; f=$2; : > "$f"
  # The GUARDED-WILDCARD sibling of gen_match (issues #2333, #2125). One data decl
  # with N constructors and ONE match that INTERLEAVES, N times, a constructor arm
  # `Ci => i` with a guarded catch-all arm `_ if k == i => i`.
  #
  # ⚠️ THE INTERLEAVING IS THE WHOLE SHAPE — a block of guarded `_` arms FOLLOWED
  # by the constructor arms measures nothing, and this was MEASURED, not reasoned:
  # `compileRows` (compiler/ir/core_ir_lower.mdk) tests `allWild pats` on the FIRST
  # row before it ever reaches `buildConSwitch`, so a leading run of guarded `_`
  # rows is peeled off one row at a time into a CTGuard chain and the con-switch
  # never sees a single wildcard row. That variant reads DEAD LINEAR: lower's net
  # alloc 4.35 -> 17.1 -> 66.6 MB is the INTERLEAVED shape at N=100/200/400
  # (r1 3.93, r2 3.89), against 0.85 -> 1.69 -> 3.50 MB (r ~2.0) for the
  # block-then-ctors variant at the same N.
  #
  # What the interleaving reaches is #2125 — the residual of #408's fix. #408
  # stopped `buildConSwitch` from re-filtering the whole matrix once per head;
  # `conBuckets` now buckets in one pass. But `wildTailRows` collects the
  # column-0 wildcard rows ONCE and `conBranch` hands EVERY branch its own
  # `map (padWildRow a) wilds` merge — Θ(wildcards) per branch. With both the
  # head count and the wildcard-row count growing as Θ(N) that is Θ(N²), which is
  # what the ledger row below records. The guards are load-bearing twice over: an
  # UNguarded `_` arm would make every later arm unreachable, so only a guarded
  # catch-all can sit ahead of a constructor arm at all.
  #
  # ⚠️ That does NOT make every row in the generated program reachable. The FINAL
  # guarded wildcard, `_ if k == (N-1)`, IS flagged unreachable by `medaka check`
  # regardless of its guard — verified first-hand on the N=5 shape (`unreachable
  # match arm. This pattern is already covered by an earlier arm`, on that last
  # row). The cause is exhaustiveness, not the guard mechanism: every constructor
  # of `T` is already matched by an earlier `Ci => i` arm by the time the match
  # reaches the trailing row, so nothing can still reach it, guarded or not. Every
  # EARLIER guarded wildcard row is genuinely reachable (that is what the guard
  # buys — see above); only the last is dead, harmlessly (`check`-only diagnostic;
  # lowering still compiles the row exactly as generated).
  #
  # ⚠️ It does NOT lift the `exhaust-guards` stage (#2333) — see the waiver in
  # test/PERF-STAGE-WAIVERS.txt for the measurement and why no shape can.
  printf 'data T =\n' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    if [ "$i" -eq 0 ]; then printf '  C%s\n' "$i"; else printf '  | C%s\n' "$i"; fi
    i=$((i+1))
  done >> "$f"
  printf 'toInt : T -> Int -> Int\ntoInt v k = match v\n' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    printf '  C%s => %s\n' "$i" "$i"
    printf '  _ if k == %s => %s\n' "$i" "$i"
    i=$((i+1))
  done >> "$f"
  # ⚠️ `main` CALLS `toInt` — same load-bearing reason as gen_match/gen_matchlits:
  # `main = println 1` roots nothing, dceFilter prunes `toInt`, and the backend
  # stages would time an empty program (i.e. grade NOTHING) while still looking ok.
  printf 'main = println (toInt C0 0)\n' >> "$f"
}

gen_listlit() {
  n=$1; f=$2; : > "$f"
  printf 'xs : List Int\nxs = [' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    [ "$i" -gt 0 ] && printf ', '
    printf '%s' "$i"
    i=$((i+1))
  done >> "$f"
  printf ']\n' >> "$f"
  # An `emit`-able program MUST have a `main` — emitProgram panics "no `main`
  # binding" without one, which aborted the WHOLE profiler (issue #359 wiring).
  # It matches the _baseline.mdk fixture, so it subtracts straight back out.
  printf 'main = println 1\n' >> "$f"
}

gen_wasm_listlit() {
  # LIVE peer of gen_listlit, for the wasm-listlit ALLOC row below. gen_listlit's `xs`
  # is DEAD (`main = println 1`), so DCE prunes it before the backend and the cons spine
  # is NEVER emitted — fine for the front-end signal that shape grades, but it means
  # wasm_emit.emitListRef is never reached. Here `main` REFERENCES `xs`, so DCE keeps the
  # binding and wasm-emit renders the full N-wide list literal through emitListRef (the
  # #522 site). Used ONLY by the dedicated wasm-ON alloc row.
  n=$1; f=$2; : > "$f"
  printf 'xs : List Int\nxs = [' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    [ "$i" -gt 0 ] && printf ', '
    printf '%s' "$i"
    i=$((i+1))
  done >> "$f"
  printf ']\nmain = println (length xs)\n' >> "$f"
}

gen_wasm_dispatch() {
  # DISPATCH-HEAVY shape for the wasm-dispatch ALLOC row below (#382, the #349/#350 twins).
  # N interfaces each with ONE method + ONE impl for a distinct type, and `total` sums the
  # N method results through a LIST-LITERAL fold. Two properties matter:
  #   * every `shI CI` element is a distinct RKey/RDict dispatch site, so the number of
  #     dispatch sites AND the number of impls both grow with N. wasm_emit inlines a
  #     dispatch chain per call site (llvm outlines one), and each site scanned the WHOLE
  #     `progImpls` list (implForW / methodImpls / implArityFor / gatherImplGroup) → the
  #     per-site scan is O(impls) ⇒ O(N^2) allocation as those flatMaps rebuild per site;
  #   * the results are combined by a LIST LITERAL + fold, NOT an N-wide `+` chain — so
  #     emitBinRef / the arithmetic-chain path does NOT confound the dispatch signal
  #     (emitListRef is linear post-#522). `main` REFERENCES `total`, so DCE keeps it all
  #     and wasm-emit actually renders every dispatch site.
  n=$1; f=$2; : > "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    printf 'data T%s = C%s\n' "$i" "$i"
    printf 'interface Sh%s a where\n  sh%s : a -> Int\n' "$i" "$i"
    printf 'impl Sh%s T%s where\n  sh%s _ = %s\n' "$i" "$i" "$i" "$i"
    i=$((i+1))
  done >> "$f"
  printf 'sumL : List Int -> Int\nsumL xs = fold (a b => a + b) 0 xs\n' >> "$f"
  printf 'total : Int\ntotal = sumL [' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    [ "$i" -gt 0 ] && printf ', '
    printf 'sh%s C%s' "$i" "$i"
    i=$((i+1))
  done >> "$f"
  printf ']\nmain = println total\n' >> "$f"
}

gen_nesting() {
  n=$1; f=$2; : > "$f"
  # N-deep let nesting: stresses recursion depth in every tree-walking pass
  printf 'deep : Int\ndeep =\n' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf '  let v%s = %s\n' "$i" "$i" >> "$f"; i=$((i+1)); done
  printf '  v0\n' >> "$f"
  # An `emit`-able program MUST have a `main` — emitProgram panics "no `main`
  # binding" without one, which aborted the WHOLE profiler (issue #359 wiring).
  # It matches the _baseline.mdk fixture, so it subtracts straight back out.
  printf 'main = println 1\n' >> "$f"
}

gen_nestedparens() {
  n=$1; f=$2; : > "$f"
  # N-deep PAREN nesting: #164's exact repro shape, `main = ((...N...1...))` —
  # NOT `gen_nesting`'s flat let-chain (S-3 confirmed: that shape stresses
  # resolve/typecheck environment depth, this one stresses the parser's
  # atom/expr precedence-cascade combinators; every downstream tree-walking
  # pass is negligible on THIS shape, per S-3's per-stage isolation).
  printf 'main = ' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf '(' >> "$f"; i=$((i+1)); done
  printf '1' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf ')' >> "$f"; i=$((i+1)); done
  printf '\n' >> "$f"
}

gen_manydefs() {
  n=$1; f=$2; : > "$f"
  # N SIGNED, private, tiny top-level defs + one exported `main`. Two shapes in one:
  #   * many defs  -> the dead-code rule's ref-map/closure (reachableNames) and the
  #     exported/reachable membership tests scale with the DEF COUNT;
  #   * one signature per def -> ruleMissingSignature's signed-name set scales too.
  # Bodies are deliberately TINY: the rule's honest linear term (declToString +
  # identTokens per decl) is proportional to body size, so small bodies keep it from
  # diluting the O(defs^2) term. With real bodies the pre-fix ratio only reached
  # 3.05 (under the 3.0 gate) at 3200 defs; with tiny ones it hits 3.32/3.59 (alloc)
  # and 3.45/4.47 (time) — an unmistakable signal.
  printf 'export main : Int\nmain = p0 + p1\n' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    printf 'p%s : Int\np%s = %s\n' "$i" "$i" "$i"
    i=$((i+1))
  done >> "$f"
}

gen_comments() {
  n=$1; f=$2; : > "$f"
  # N functions, each carrying a LEADING comment line + a TRAILING comment on both
  # its signature and its body. This is the ONLY shape that populates the comment
  # side-channel, and the comment count scales with N — the input a formatter
  # quadratic needs. It exercises `fmt` (profile_main runs `formatSource`):
  #   * lexer.collectComments/rawToComments/posLineColFrom — offset→(line,col) for
  #     every comment (was rescanned from offset 0 per comment → O(comments×bytes));
  #   * fmt.formatProgram — the per-decl comment interleaving (was a full remaining-
  #     tail rescan per decl → O(decls×comments)).
  # BOTH are pure scans that allocate ~nothing, so this shape is graded on fmt TIME
  # (the alloc verdict is blind to it — the issue #110 class). Sized (COMMENTS_N)
  # so fmt time at 4N clears the 200ms floor; see the base_n case in the loop.
  i=0; while [ "$i" -lt "$n" ]; do
    printf -- '-- leading comment %s describing the function defined just below it\n' "$i"
    printf 'f%s : Int -> Int  -- trailing comment on the signature of f%s\n' "$i" "$i"
    printf 'f%s x = x + %s  -- trailing comment on the body of f%s\n' "$i" "$i" "$i"
    i=$((i+1))
  done >> "$f"
  # An `emit`-able program MUST have a `main` — emitProgram panics "no `main`
  # binding" without one, which aborted the WHOLE profiler (issue #359 wiring).
  # It matches the _baseline.mdk fixture, so it subtracts straight back out.
  printf 'main = println 1\n' >> "$f"
}

# gen_xref lives in test/perf_shapes.sh, SHARED with test/diff_compiler_ir_scaling.sh
# (sourced at the top of this file). It was transcribed into that gate by hand until
# #2066; two copies of a shape whose ratios the two gates quote against each other is a
# drift hazard neither gate can see. Its full rationale — the #78 lookupValue scan, and
# why `main` must call the head of the chain — moved there with it.

# gen_scoperefs_resolve — THE #78 P-1 resolve SCOPE-scan detector. `xref` above no longer
# catches #78: its quadratic was the env.values LIST scan, and env.values became an
# OrdMap set (#954/#973), so `xref:resolve` is now linear. The *residual* #78 quadratic
# is the LOCAL scope: resolve membership-tests `scope` on EVERY variable reference, and a
# reference to a NON-local name scans the whole local scope to completion before falling
# through to env.values. So a body with a LARGE local scope that makes MANY non-local
# references is O(references × scope-size) — which no other shape builds.
#
# This shape is exactly that: one big function whose body is preceded by N `let`s (the
# scope grows to N) and then references the top-level `base` N times. Each of the N
# `base` refs scans the N-deep scope => O(N^2) `contains` steps, all COUNTED (util.contains
# bumps the op counter). Pre-fix that read ~4*N^2 resolve ops (640002 at N=400); the fix
# (scope backed by an OrdMap membership set — `omHasKey`, uncounted) DRAINS it to ~0
# (2 at any N). So this is graded like `reexports`: an OP-REGRESSION ASSERTION, not a
# ratio — resolve op MUST stay under OP_FLOOR; a reintroduced scope scan lifts it into
# the hundreds of thousands. See the dedicated block after the starimports/reexports loop.
#
# NOTE this shape ALSO drives coupled (separate, still-open) typecheck/mangle quadratics
# of the same List-as-set class — which is exactly why it is graded resolve-ONLY (its own
# typecheck op serves only as the profiler-liveness witness), NOT through the per-stage
# OP_STAGES loop that would fail on those unrelated rows.
gen_scoperefs_resolve() {
  n=$1; f=$2; : > "$f"
  printf 'base : Int\nbase = 1\n' >> "$f"
  printf 'big : Int\nbig =\n' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf '  let v%s = 0\n' "$i"; i=$((i+1)); done >> "$f"
  # body: reference the non-local `base` N times (each ref scans the full N-deep scope)
  printf '  base' >> "$f"
  i=1; while [ "$i" -lt "$n" ]; do printf ' + base'; i=$((i+1)); done >> "$f"
  printf '\n' >> "$f"
  printf 'main = println big\n' >> "$f"
}

# gen_marksweep — THE MONEY-SHOT for the op arm (issue #884). It drives marker's
# `contains x methods` scan directly, against a METHOD POOL THAT GROWS WITH N.
#
# ONE interface with N methods => the marker's `methods` pool has size ~N (cheap: one
# decl with N signatures, not N interface decls, so parse/fmt/lint stay small). Then a
# CONSTANT number of value bindings, each a chain of references to a non-method
# top-level `base`, forces a full `contains _ methods` scan of that growing pool at
# each of a FIXED number of sites. Constant sites x O(N) pool = O(N) op work => LINEAR
# (op-ratio ~2.0, once the fixed prelude-marking op constant is out-scaled), which is
# exactly why it reads "ok" on a correct compiler.
#
# WHY IT IS THE MONEY-SHOT: `mark`'s absolute time is ~30-95 ms here — FAR under the
# 200ms TIME_FLOOR at every N — so the TIME arm would SKIP `mark` and provide ZERO
# coverage of it; the deterministic OP arm grades it (r2 ~1.8) from a single run. This
# shape is therefore run OP-ONLY (its TIME min-of-K arm is skipped in the loop — it
# would grade nothing but cost ~K runs per size), so its op grade rides the shared
# deterministic run. And because the pool GROWS with N, a marker quadratic (e.g. a
# regression making `contains` scan the tail redundantly) turns each scan into
# O(pool^2) => the op ratio jumps toward 4.0 and the OP arm FAILs on a stage the TIME
# arm structurally cannot grade at these sizes.
#
# Sites (S) and refs-per-site (R) are sized so S*R (~4000) out-scales the ~125k fixed
# prelude-marking op constant enough for a clean linear read, while keeping `mark` time
# well under the floor. R is FIXED (independent of N), so per-decl typecheck cost does
# NOT grow with N — this shape does not re-trigger the listlit:typecheck size-of-one-
# decl blowup; only the method POOL scales.
gen_marksweep() {
  n=$1; f=$2; : > "$f"
  s=40; r=100
  printf 'interface Pool a where\n' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf '  m%s : a -> Int\n' "$i"; i=$((i+1)); done >> "$f"
  printf 'base : Int\nbase = 1\n' >> "$f"
  k=0; while [ "$k" -lt "$s" ]; do
    printf 'h%s : Int\nh%s = base' "$k" "$k"
    j=1; while [ "$j" -lt "$r" ]; do printf ' + base'; j=$((j+1)); done
    printf '\n'
    k=$((k+1))
  done >> "$f"
  # `main` reaches only h0 -> base, so DCE prunes the rest — but mark/resolve/typecheck
  # run BEFORE DCE and see the whole file, which is all this shape needs (it is a
  # front-end shape; its backend stages are not graded and xref carries backend).
  printf 'main = println h0\n' >> "$f"
}

# gen_manyifaces — THE CO-SCALED MARK QUADRATIC (issue #883, §5 hole 8). It is the
# marksweep money-shot's QUADRATIC counterpart: where marksweep grows ONLY the method
# pool (fixed sites => LINEAR), this grows BOTH the pool AND the reference-site count
# together, so mark's `contains x methods` scan (marker.mdk markVar/markInfix — a
# List-as-set walked for EVERY var/op node, `methods` = every interface-method name)
# reads O(sites x pool) = O(N^2). This is the §5 "co-scale the two dimensions that
# multiply" rule: the N->2N doubling of a single axis sees only a linear slice of an
# O(a x b) blow-up (marksweep's fixed-site read is exactly that linear slice, on
# purpose — the two shapes are a matched pair).
#
#   N interface decls, each ONE method  => `methods` pool ~N (base names m0..m{N-1}).
#   N reference sites (h0..h{N-1}), each R=8 refs to the NON-method value `base`.
# `base` is not in `methods`, so each of the R*N `base` var nodes forces a FULL
# `contains base methods` scan of the O(N) pool => R*N * O(N) = O(N^2) counted ops.
# R is a small FIXED constant so it out-scales the ~125k fixed prelude-marking op
# constant enough for a clean read at the default N band (mark op r1=3.07 r2=3.54 at
# 250/500/1000 — climbing; ledgered `manyifaces:mark`). The `+` operator nodes hit
# markInfix's `contains op methods` too, but `+` IS a prelude method and `methods`
# prepends `preludeMethods`, so that scan stops in the O(1) prelude prefix — it does
# not add to the quadratic (only the non-method `base` refs do).
#
# GRADED OP-ONLY (like marksweep): these stages sit FAR under the 200ms TIME_FLOOR here
# (~40-200 ms), so the TIME arm grades them NOWHERE; the deterministic OP arm does. The
# shared run surfaces the SAME O(interfaces^2) interface-registration/duplicate-checking
# class (scanning the growing ifaceMethods/interfaces lists once per interface — #954)
# across several stages, most now fixed:
#   * mark — FIXED (#975); was `manyifaces:mark`.
#   * resolve — FIXED (#969, findDups -> OrdMap); was `manyifaces:resolve` (r1=3.68 r2=3.83).
#   * typecheck — FIXED (#973, three flat-path List-as-set scans -> OrdMap: buildDefinerShadows,
#     dropSchemesNamed, checkInterfaceCycles' `done`); was `manyifaces:typecheck` (r1=3.27 r2=3.60,
#     now r1=1.58 r2=1.74 LINEAR). It had read `ok` on main (r1=2.65) only because the #907
#     stampBindingIds op-quadratic (typecheck's checkBodyImpl) DILUTED it; fixing #907 removed that
#     masking term and surfaced the true ratio, exactly the "future source change lifting r1 over 3
#     forces a ledger decision" this note predicted — then #973 drained it.
#   * elaborate — FIXED (#2189). Was `manyifaces:elaborate` (op r1=2.52 r2=3.04 at
#     250/500/1000). A THIRD instance of the same class, in `elaborateDict`'s AST
#     prepass rather than in interface registration: `rewriteRPDictArg` /
#     `rewriteArgScoped` (typecheck.mdk) probed `rpNames`/`argNames`/`dictNames` with
#     `util.contains` at EVERY `EVar` node, and this shape's `argNames` IS the
#     O(N) arg-dispatch method pool — so the R*N non-method `base` refs each walked
#     it in full, exactly the O(sites x pool) read #975 drained out of the marker.
#     Indexing the three sets to OrdMaps (plus the same treatment for `dictPass`'s
#     `names`) drops it to op r1=1.49 r2=1.66 (109378 -> 162628 -> 269128) — LINEAR.
#     De-ledgered.
# gen_manyifaces lives in test/perf_shapes.sh, SHARED with
# test/diff_compiler_ir_scaling.sh — same #2066 reasoning as gen_xref above.

# gen_widerecords — THE WIDE-RECORD SHAPE (issue #883, §5 hole 9). The ONLY shape that
# declares a record: a data decl with N fields, plus N tiny accessor decls (`gI r =
# r.fI`) and N tiny updater decls (`uI r = { r | fI = I }`), each ONE field mention.
# In resolve every field mention routes through `ownersOf fname env.fieldOwnersIdx`
# (resolve.mdk). Tiny per-decl bodies (one field mention each) avoid the
# one-big-expression typecheck/emit blow-up a single N-wide `r.f0 + ... + r.fN` sum or
# an N-deep nested `{ ... | fN = N }` update would trigger (measured: the wide-expr cut
# spent 2 s in `emit` at N=500 alone).
#
# HISTORY (#883 -> #984). Until #984 `ownersOf` was a HAND-ROLLED linear scan of the
# (field,owner) multimap (N long), so the 2N field mentions cost O(N^2) — visible ONLY on
# resolve TIME (~180 ms at N=2000, UNDER the 200ms floor; barely allocates, so alloc was
# blind, and the scan called neither util.contains nor util.lookupAssoc so the OP counter
# was structurally blind too). #984 indexed `fieldOwners` by field name (O(log N) probe,
# resolve TIME now LINEAR) AND routes each probe through `opBump`, so `ownersOf` is now
# COUNTED: resolve op = 5N+1 (was 3N+1), a flat r~2.0 that now clears OP_FLOOR at N=250
# (1251 > 1000). So this shape's resolve-op grade is a GENUINE ownersOf regression
# detector: a reintroduced per-mention scan (counted per pair) lifts the resolve-op ratio
# to ~4x and the dedicated block below goes red (proven: reverting #984's index turns
# resolve op superlinear).
#
# GRADED OP-ONLY (cheap, deterministic). The SHAPES loop carries a DEDICATED widerecords
# resolve-op block (see the "widerecords resolve-op grade" block after the OP arm) that
# grades the resolve-op RATIO unconditionally and fails on a 0/missing reading (dead
# profiler), so a band retune can never silent-green it. (The generic loop does NOT
# self-guard this — only the rshape and this explicit check do.)
gen_widerecords() {
  n=$1; f=$2; : > "$f"
  {
    printf 'data R = R { '
    i=0; while [ "$i" -lt "$n" ]; do [ "$i" -gt 0 ] && printf ', '; printf 'f%s : Int' "$i"; i=$((i+1)); done
    printf ' }\n'
    printf 'mk : R\nmk = R { '
    i=0; while [ "$i" -lt "$n" ]; do [ "$i" -gt 0 ] && printf ', '; printf 'f%s = %s' "$i" "$i"; i=$((i+1)); done
    printf ' }\n'
    i=0; while [ "$i" -lt "$n" ]; do
      printf 'g%s : R -> Int\ng%s r = r.f%s\n' "$i" "$i" "$i"
      printf 'u%s : R -> R\nu%s r = { r | f%s = %s }\n' "$i" "$i" "$i" "$i"
      i=$((i+1))
    done
    # main roots only g0/u0/mk; resolve/typecheck (the graded stages) run pre-DCE over
    # every decl. The tiny reached set keeps the backend stages small.
    printf 'main = println (g0 (u0 mk))\n'
  } >> "$f"
}

# gen_emittables — THE EMITTER-TABLE SHAPE (issue #352). The only shape that grows
# the LLVM emitter's per-program lookup TABLES: N distinct record types, N distinct
# single-ctor data types, and N exported top-level fns, with every one of them LIVE.
#
# Each `sI` does, in one tiny body: a record CREATE, a record UPDATE, two field
# ACCESSes, a ctor ALLOC and a ctor PATTERN bind — i.e. one hit on every table #352
# named — and tail-calls `s(I+1)`, so `main = println (s0 1)` roots the whole chain
# and DCE keeps all N (the mistake gen_match's comment warns about). Bodies stay O(1)
# so the shape cannot accidentally grade the one-big-expression typeOf/staticIsFloat
# walk instead. `export` on every `sI` is what puts private_mangle's `pubFnNames` on
# the map — no other shape exports anything, so the `mangle` op arm saw it nowhere.
#
# GRADED OP-ONLY, on the emit + mangle stages, in the dedicated block near the bottom
# (not via the SHAPES loop): the emit-stage OP ratio is not in OP_STAGES, and the
# TIME arm cannot see these at all — they are PURE SCANS that allocate almost nothing
# per step, exactly the class THE SECOND RULE in compiler/AGENTS.md is about.
gen_emittables() {
  n=$1; f=$2; : > "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    printf 'data R%s = R%s { a%s : Int, b%s : Int }\n' "$i" "$i" "$i" "$i"
    printf 'data T%s = K%s Int\n' "$i" "$i"
    printf 'export s%s : Int -> Int\n' "$i"
    printf 's%s x =\n' "$i"
    printf '  let v = R%s { a%s = x, b%s = x }\n' "$i" "$i" "$i"
    printf '  let w = { v | b%s = 1 }\n' "$i"
    printf '  match K%s (w.a%s + w.b%s)\n' "$i" "$i" "$i"
    if [ "$i" -eq $((n-1)) ]; then
      printf '    K%s y => y\n' "$i"
    else
      printf '    K%s y => s%s y\n' "$i" "$((i+1))"
    fi
    i=$((i+1))
  done >> "$f"
  printf 'main = println (s0 1)\n' >> "$f"
}

# gen_consfam — THE DISPATCH-TMC GROUP-GROWTH SHAPE (issue #1029). N mutually
# cons-tail-recursive functions: `c_i k = if k <= 0 then c_{i-1} 1 else i :: c_i (k - 1)`.
# It is the ONLY shape that reaches backend/trmc_analysis.mdk's (b') dispatch-group
# growth walk at all — and `detectDispatchGroups` runs UNCONDITIONALLY in BOTH backends'
# emitProgram, i.e. on every `medaka build`.
#
# WHY NO OTHER SHAPE SEES IT, and why that is a property of the SHAPE and not the band:
# the walk is pre-gated on `consTargets` — a candidate root must be the bottom callee of
# some peeled tail-position spine cons. `xref` chains N functions but with PLAIN tail
# calls, so consTargets is empty, every root is rejected before the walk starts, and xref
# reads clean linear (alloc x2.10). The cons TAIL is the load-bearing detail; without one
# this whole subsystem is unreachable from the corpus.
#
# Every c_i is a cons target here, so every c_i is a candidate root, and growing from c_k
# walks the whole c_k..c_0 family. Pre-#1029 each step of that walk did `contains n acc`
# (List-as-set), `acc ++ toAdd` and `rest ++ toAdd` (`++` is O(left), INSIDE the fold),
# and a `dispFindBind` linear scan of every bind — O(P) work inside two nested loops.
#
# SEEN RED, at this band, on the pre-fix binary (87d4842f) — the rows this gate printed,
# BOTH arms firing:
#   consfam 200  290.8 MB  959.1 MB  4623.9 MB  r1=3.30 r2=4.82  ** SUPERLINEAR (ALLOC) **
#   time emit: 0.310s -> 1.957s -> 13.365s     r1=6.31 r2=6.83   ** SUPERLINEAR (TIME) **
# and GREEN with the fix, same tree, same band:
#   consfam 200  218.6 MB  462.2 MB  1017.7 MB  r1=2.11 r2=2.20  ok
# (per-stage `emit` allocation is the sharpest view: 84.0 -> 521.6 -> 3656.9 MB, x6.21 x7.01
# before; 11.9 -> 24.6 -> 50.7 MB, x2.07 x2.06 after. Emit ops 352.4M -> 130k at N=800.)
# GRADED BY THE ALLOC ARM, which rides the shared deterministic run — this shape adds NO
# new profiler invocation beyond the three every shape makes.
#
# ⚠️ The fixture must actually FORM the group, or this measures a parse error. Re-derive:
#   medaka build --keep-ir -o /tmp/cf /tmp/consfam.mdk && grep -c '^; tmc: .* group:' /tmp/cf.ll
# must print a nonzero count (the accepted group's non-root members). A degenerate fixture
# also trips the alloc arm's TOOSMALL branch, which is a FAIL, not a pass.
gen_consfam() {
  n=$1; f=$2; : > "$f"
  {
    printf 'c0 : Int -> List Int\nc0 k = if k <= 0 then [] else 0 :: c0 (k - 1)\n'
    i=1; while [ "$i" -lt "$n" ]; do
      printf 'c%s : Int -> List Int\nc%s k = if k <= 0 then c%s 1 else %s :: c%s (k - 1)\n' \
        "$i" "$i" "$((i-1))" "$i" "$i"
      i=$((i+1))
    done
    # `main` REFERENCES the last member, so DCE keeps the whole family and the backend
    # actually runs the detection over it (a dead family is pruned before emit).
    printf 'main = println (length (c%s 3))\n' "$((n-1))"
  } >> "$f"
}

# gen_conlocal — THE CONSTRAINED-BINDING SHAPE (issue #2030). N constrained top-level
# functions, each with exactly ONE local:
#
#     f0 : Display a => a -> String
#     f0 x =
#       let d v = display v
#       d x
#     ... (N of them)
#     main = println (f0 1)
#
# WHY NO OTHER SHAPE SEES IT, and why that is a property of the SHAPE, not the band:
# the cost is in typecheck's local-pin bookkeeping (`localPinPairs`), which multiplies
# CONSTRAINED TOP-LEVEL BINDINGS by LOCAL BINDINGS. Nothing else in this corpus
# co-scales those two. `bindings`/`xref` generate N top-level fns with NO constraint
# and no local, so the pin table stays empty; `manyifaces` and `marksweep` grow the
# METHOD POOL against a FIXED number of sites — the opposite axis. One constraint per
# fn plus one local per fn is the minimum shape that grows both together.
#
# ⚠️ IT IS 0-DIAGNOSTIC, and that is load-bearing. A resolve-broken fixture measures a
# different mechanism entirely (the same trap gen_modules and gen_typos carry). The
# `Display a =>` constraint and the `display v` body must both stay: drop the
# constraint and the binding is unconstrained, so the pin table it stresses is never
# populated. Re-derive with:
#     ./medaka check /tmp/conlocal.mdk    # must print "N declaration(s) checked, 0 errors"
#
# GRADED BY THE OP ARM, on the shared deterministic runs — this shape adds NO profiler
# invocation beyond the three every shape makes, and it is OP-ONLY (the TIME min-of-K
# arm is skipped; see the OP-ONLY case in the shapes loop). Its band is its own,
# CONLOCAL_N=400 -> 1600; see that knob for why the default band misses the defect.
gen_conlocal() {
  n=$1; f=$2; : > "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    printf 'f%s : Display a => a -> String\nf%s x =\n  let d v = display v\n  d x\n' "$i" "$i"
    i=$((i+1))
  done >> "$f"
  # `main` CALLS f0 — same rooting rule as every other shape here, same reason.
  printf 'main = println (f0 1)\n' >> "$f"
}

# gen_modules — the only multi-module generator that declares any DATA TYPE (issue #153).
# ⚠️ IT IS NOT THE ONLY MULTI-MODULE GENERATOR, and this line said so until #1319 unit 2.
# There are three — derive them, do not trust a count:
#     grep -n '^gen_[a-z_]*() {' test/diff_compiler_perf_scaling.sh
# `gen_starimports` and `gen_reexports` are equally multi-module and declare VALUES only, so
# record/field coverage exists in exactly ONE of the three multi-module shapes. The wrong
# version of this sentence is the one a future agent uses to answer "is multi-module
# covered?", check one generator, and stop. Writes N separate
# .mdk files into DIR, chained by import (m0 <- m1 <- ... <- m{N-1} <- entry), each
# module defining K data types + K impls of a shared interface `Widget`,
# re-exporting `Widget(..)` and its method `wval` down the chain, and EXERCISING
# every one of its K impls in a local `useI` value. Unlike the five single-file
# shapes, this one is DIRECTORY-shaped: the modules block below feeds `entry.mdk` +
# DIR to profile_modules_main so loadProgram walks the whole chain and checkModules
# runs over the accumulated decl universe — which is exactly what the O(modules^2)
# family (checkModuleFullImpl's per-module rescan, elabModuleStamp's
# buildKeyTable(accAll ++ prog)) scales with.
#
# ⚠️ THE FIXTURE MUST RESOLVE CLEANLY, or the gate measures the WRONG quadratic.
# profile_modules_main drives markModules/checkModules, which do NOT run
# frontend.resolve and DISCARD its result — so a resolve-BROKEN fixture still prints
# growing MB, but that growth can be the compiler re-failing to bind the same
# unresolved names once per module (a different module-count-scaling mechanism),
# NOT the checkModuleFullImpl/elabModuleStamp rescan #154/#150 are about. An earlier
# cut of this generator was resolve-broken exactly this way (bare `import m.{Widget}`
# does not re-export; plain `export data` is VisAbstract so the constructor is not
# exported; the interface method `wval` was never imported). The three fixes below
# are load-bearing and each was reproduced with `medaka check`:
#   * `export import` — re-export Widget+wval down the chain (plain import does not).
#   * `public export data` — export the CONSTRUCTOR (plain `export data` is abstract).
#   * import `Widget(..), wval` — bring the interface's METHOD into scope to dispatch.
# The corrected fixture typechecks 0-diagnostic AND still exhibits O(modules^2) in
# typecheck (r2: net alloc 3.57, typecheck alloc 3.78, typecheck time 4.12 at
# N=100/200/400, K=8) — STRONGER than the broken one, confirming the quadratic is
# the real accumulated-universe rescan, not a binding-failure artifact.
#
# WHY K>1 and WHY IMPLS. A plain function chain (each module one `fN x = ...`)
# scales LINEARLY here (measured typecheck alloc 1.72x/1.84x/1.91x) — the
# accumulated universe those passes rescan is IMPL/interface/data decls, not plain
# bindings, so plain functions never populate it. K impls per module do, and K is a
# linear multiplier on the quadratic coefficient, so a modest constant K keeps the
# module COUNT (and thus the file count and the gate's wall time) small while the
# quadratic still dominates by N=100. "Constant decls per module, scale the module
# count" — issue #153's fix shape.
#
# 🚨 EVERY MODULE ALSO DECLARES `MOD_R` RECORDS OVER `MOD_F` SHARED FIELD NAMES.  Added
# by #1111 A-2.12 (#1319 unit 2) after adversarial review established that NO multi-module
# generator in this file declared a single record or field: this one emitted nullary
# `data T0_j = T0_j`, and the other two declare VALUES only.  (Do not trust that sentence
# either — derive the set: `grep -n '^gen_[a-z_]*() {' test/diff_compiler_perf_scaling.sh`.)
# ⚠️ RECORDS WERE NOT ABSENT FROM THE FILE — `gen_widerecords` declares one, with N fields.
# It writes a SINGLE FILE, so `fieldOwnersRef` never accumulates owners across modules and
# `recordByNameRef` never sees two modules competing for a key.  "The corpus has records"
# and "the corpus can see a cross-module record defect" are different claims, and only the
# second one is what this block is about.
# Every code path keyed on `recordByNameRef` / `fieldOwnersRef` therefore short-circuited on
# an empty list: a per-module walk over the field→owners multimap that measured **5.6x net
# allocation at 240 modules (r3 = 6.47 against a hard 3.0)** on a hand-rolled corpus was
# reported by this gate as `r2 = 2.06 ok`.  The quadratic was not missed by a bad threshold;
# it was invisible by construction.
#
# ⚠️ MOD_R AND MOD_F ARE THE MULTIPLIER, AND A FIRST CUT AT 1x1 WAS NOT ENOUGH.  With one
# record and one field name per module the shape reddened only the TIME arm (r2 = 2.60 against
# 2.47) and left ALLOCATION — the verdict this file calls primary *because* it is
# deterministic — at `ok` (r2 = 2.38).  A gate that can only redden through the signal the
# repo says not to trust is coverage wearing a gate's clothes.  Same reasoning as `K` for the
# interface half one paragraph up: the per-module walk costs O(collided field names x owners
# per name), so MOD_F multiplies the number of walks and MOD_R multiplies the owners in each.
# 4x4 is the ratio the review's own corpus was measured at.
#
# VERIFIED BY CONSTRUCTION, not asserted: this generator was run at MOD_N/MOD_K through a
# binary carrying the removed field-owner narrowing, and the ALLOCATION arm goes RED.  If you
# change MOD_R / MOD_F, redo that — a coverage claim for a defect class is only worth the
# counterfactual behind it.
#
# The properties are deliberate and a future edit must keep all three:
#   * SHARED FIELD NAMES across modules, so each `fieldOwnersRef[f<j>]` grows to N*MOD_R
#     owners — that multimap is what any scoping of the field namespace has to walk;
#   * MOD_R records per module, so the owner lists grow with the module count AND the
#     per-module constant;
#   * SHORT-FORM records with UNIQUE names (`R<i>_<j>`), which keeps the fixture
#     0-diagnostic.  Named-field variants sharing a field name would NOT be: a concrete
#     receiver whose head tycon is not a registry key falls to `resolveFieldAmbiguous`,
#     which picks `headL owners` — right for exactly one of them and a `Type mismatch` for
#     the rest.  (That gap is real and unfixed; it is pinned behaviourally by
#     `test/llvm_fixtures_modules/field_owner_no_narrowing/`, not here, because this
#     generator must stay 0-diagnostic — see the trap above.)
MOD_R=4
MOD_F=4

# one module's record block: MOD_R short-form records over the SAME MOD_F field names,
# plus a concrete-receiver projection so the read path is exercised too.
gen_mod_records() {
  _i=$1
  _j=0
  while [ "$_j" -lt "$MOD_R" ]; do
    printf 'public export data R%s_%s = {' "$_i" "$_j"
    _f=0
    while [ "$_f" -lt "$MOD_F" ]; do
      [ "$_f" -gt 0 ] && printf ','
      printf ' f%s : Int' "$_f"
      _f=$((_f+1))
    done
    printf ' }\n'
    _j=$((_j+1))
  done
  printf 'export mkr%s : R%s_0\nmkr%s = R%s_0 {' "$_i" "$_i" "$_i" "$_i"
  _f=0
  while [ "$_f" -lt "$MOD_F" ]; do
    [ "$_f" -gt 0 ] && printf ','
    printf ' f%s = 0' "$_f"
    _f=$((_f+1))
  done
  printf ' }\nexport rv%s : Int\nrv%s = mkr%s.f0\n' "$_i" "$_i" "$_i"
}
gen_modules() {
  n=$1; dir=$2; k=$3
  rm -rf "$dir"; mkdir -p "$dir"
  {
    printf 'export interface Widget a where\n  wval : a -> Int\n\n'
    j=0; while [ "$j" -lt "$k" ]; do
      printf 'public export data T0_%s = T0_%s\nexport impl Widget T0_%s where\n  wval _ = %s\n' "$j" "$j" "$j" "$j"
      j=$((j+1))
    done
    gen_mod_records 0
    printf 'export use0 : Int\nuse0 = '
    j=0; while [ "$j" -lt "$k" ]; do [ "$j" -gt 0 ] && printf ' + '; printf 'wval T0_%s' "$j"; j=$((j+1)); done
    printf '\n'
  } > "$dir/m0.mdk"
  i=1
  while [ "$i" -lt "$n" ]; do
    prev=$((i - 1))
    {
      printf 'export import m%s.{Widget(..), wval}\n' "$prev"
      j=0; while [ "$j" -lt "$k" ]; do
        printf 'public export data T%s_%s = T%s_%s\nexport impl Widget T%s_%s where\n  wval _ = %s\n' \
          "$i" "$j" "$i" "$j" "$i" "$j" "$j"
        j=$((j+1))
      done
      gen_mod_records "$i"
      printf 'export use%s : Int\nuse%s = ' "$i" "$i"
      j=0; while [ "$j" -lt "$k" ]; do [ "$j" -gt 0 ] && printf ' + '; printf 'wval T%s_%s' "$i" "$j"; j=$((j+1)); done
      printf '\n'
    } > "$dir/m$i.mdk"
    i=$((i+1))
  done
  top=$((n - 1))
  printf 'import m%s.{Widget(..), wval, T%s_0(..)}\nmain = println (wval T%s_0)\n' "$top" "$top" "$top" > "$dir/entry.mdk"
}

# gen_starimports — the STAR import fan-in (issue #881). N leaf modules, each
# exporting one value, and ONE entry module importing ALL of them and referencing
# every imported symbol (so no import is unused). This is the multi-module RESOLVE
# analogue of `xref`: production's resolveModulesErrorsG threads `known` and resolves
# each of the entry's N imports via findExports — a LINEAR scan of the N-long known
# list — so the entry alone is O(N^2) in findExports COMPARISONS.
#
# ⚠️ MEASURED FINDING: on this shape resolve is EFFECTIVELY LINEAR on every arm. The
# findExports scan WAS O(N^2) (#926) but is now a Map lookup (O(N log N)); it never
# reached the OP counter anyway (a hand-rolled scan, now `omLookup` — both uncounted),
# and its alloc is dwarfed by the ~linear buildEnvMM term. The op-count this shape DOES
# read is ~6*N — `isPubExp`'s `contains` per resolved `import m.{v}` member. ⚠️ THIS
# SAID ~3*N until 2026-08-29 and was wrong by a factor of two; the gate's own
# transcript reads 2400 at N=400. The conclusion is unaffected (6*N clears the floor
# by more, not less) but the constant is load-bearing for the STAR_N choice below,
# so it is corrected rather than left. (it was 5*N
# before #925 turned realImport/importValueNames' membership into OrdMap sets). Linear, so
# this shape is a LINEAR regression guard on the counted import-membership path, NOT a
# quadratic detector; it reads `ok`. STAR_N=400 keeps op1 = 6*400 = 2400 over OP_FLOOR
# (1000) with 2.4x of headroom — measured, not derived from the constant.
gen_starimports() {
  n=$1; dir=$2
  rm -rf "$dir"; mkdir -p "$dir"
  i=0
  while [ "$i" -lt "$n" ]; do
    printf 'export v%s : Int\nv%s = %s\n' "$i" "$i" "$i" > "$dir/m$i.mdk"
    i=$((i+1))
  done
  {
    i=0
    while [ "$i" -lt "$n" ]; do printf 'import m%s.{v%s}\n' "$i" "$i"; i=$((i+1)); done
    # Reference EVERY imported name so none is unused (a 0-diagnostic fixture — the
    # gen_modules trap: a resolve-broken fixture measures a different mechanism).
    printf 'main = println ('
    i=0
    while [ "$i" -lt "$n" ]; do [ "$i" -gt 0 ] && printf ' + '; printf 'v%s' "$i"; i=$((i+1)); done
    printf ')\n'
  } > "$dir/entry.mdk"
}

# gen_reexports — the N-deep `export import` RE-EXPORT fan-out (issue #881). m0 exports
# v0; each m_i does `export import m{i-1}.*` (re-exporting the whole accumulated set) AND
# exports its own v_i; the entry imports the top module's `.*` and references the shallow
# and deep ends. This CUMULATIVE fan-out makes the exports total sum(i)=O(N^2) name
# entries — resolve must allocate O(N^2) no matter the algorithm (the intrinsic floor).
#
# ⚠️ WAS a clean 2^3 OP cubic (r2=7.92): `contains` re-checked the growing export set at
# three sites per module. #925/#926 FIXED it (OrdMap-set membership + Map findExports/
# provenance); the counted op is now a deterministic 0. So this shape is GRADED ON ALLOC
# now (quadratic-aware ceiling), NOT op — see the resolve-shapes block and the reexports
# note by KNOWN_ACEIL_reexports_resolve. Resolves 0-DIAGNOSTIC (proven with `medaka
# check`): `export import m.*` re-exports, and the entry's `import m.*` binds.
gen_reexports() {
  n=$1; dir=$2
  rm -rf "$dir"; mkdir -p "$dir"
  printf 'export v0 : Int\nv0 = 0\n' > "$dir/m0.mdk"
  i=1
  while [ "$i" -lt "$n" ]; do
    prev=$((i - 1))
    {
      printf 'export import m%s.*\n' "$prev"
      printf 'export v%s : Int\nv%s = %s\n' "$i" "$i" "$i"
    } > "$dir/m$i.mdk"
    i=$((i+1))
  done
  top=$((n - 1))
  printf 'import m%s.*\nmain = println (v0 + v%s)\n' "$top" "$top" > "$dir/entry.mdk"
}

# gen_typos — THE DIAGNOSTICS-PATH detector (issue #1016). Until this shape, EVERY
# fixture in this file typechecked 0-DIAGNOSTIC by design, so the error path was
# measured NOWHERE — which is exactly how resolve's did-you-mean search stayed
# O(unbound names x in-scope names) unnoticed, on the path `medaka check` and the LSP
# (lsp.mdk's analyzeLocated, recomputed on every document change) both run. A
# half-typed buffer is the single most common input an editor ever sends, and a
# half-typed buffer IS "many unbound names".
#
# CO-SCALED, the same "co-scale the two dimensions that multiply" rule the
# marksweep/manyifaces pair follows: N defined bindings (the candidate POOL) AND N
# bindings that each reference an undefined one-character typo of one (the DIAGNOSTIC
# count). Pre-#1016 that was N x O(pool) ALLOCATING Levenshtein DPs. Measured by THIS
# shape at its own band, N=250->500->1000 (2N+1 decls), before and after the fix:
#
#   before  total alloc  915.8 -> 2921.3 -> 10217.6 MB  r1=3.19 r2=3.50  ** SUPERLINEAR (ALLOC) **
#   after   total alloc  124.5 ->  254.8 ->   530.3 MB  r1=2.05 r2=2.08   ok
#
# and the resolve stage alone, heap-pinned (deterministic bytes, not wall-clock):
#   before  resolve alloc  799.3 -> 2686.3 -> 9741.8 MB   r1=3.36 r2=3.63
#   after   resolve alloc    8.19 ->   19.90 ->   54.63 MB  r1=2.43 r2=2.74
# i.e. 9741.8 MB -> 54.6 MB at N=1000, a 178x drop in the allocation this shape exists
# to grade.
#
# Those "before" rows are a REAL RUN of this shape with the fix reverted and the gate
# kept, not an estimate — the shape has been SEEN RED, and only this shape regressed in
# that run.
#
# The ALLOC arm is what catches it: the per-unbound-name Levenshtein DP over the whole
# pool is where all the allocation was. The OP arm (`scoreCand`'s opBump — one per
# Levenshtein scoring) is a POST-fix regression guard rather than a pre-fix red: before
# #1016 there was no counted op on this path at all, so a revert makes the op reading
# DISAPPEAR rather than climb. MEASURED, in the very same seen-red run: pre-fix resolve
# op reads 12250 -> 24500 -> 49000, i.e. dead LINEAR (r=2.00/2.00) while allocation is
# screaming 3.19/3.50 — a textbook case of one arm being blind to what the other sees. That is what the "did the search actually run" assertion
# below is for — it turns a vanished reading into a loud harness failure instead of a
# silent skip.
#
# GRADED OP-ONLY (like marksweep/manyifaces): resolve sits under the 200ms TIME_FLOOR
# here once fixed, so the TIME arm would grade it nowhere while costing ~K runs per
# size. Its coverage is the deterministic OP arm (`scoreCand` bumps once per
# Levenshtein scoring — the expensive, allocating step) plus the shared ALLOC arm.
# ⚠️ What NEITHER arm sees: the surviving O(unbound x pool) PREFILTER scan, ~4 machine
# ops per pair, allocating nothing. That is the accepted residual, not an oversight —
# see resolve.mdk's `SugCand` note for why a sub-linear index was rejected. What the
# arms DO catch is the whole regression surface that matters: re-materializing the pool
# per call (alloc), and any weakening of the prefilters (op).
#
# NAME SHAPES ARE LOAD-BEARING — do not "simplify" the generator:
#   * lengths vary (6..13), so the length prefilter (|len a - len b| <= ed a b) is
#     exercised rather than vacuously true;
#   * letters are spread by a deterministic LCG kept to a SMALL modulus so awk's
#     doubles stay exact on every awk, Linux and macOS — a 32-bit multiplier here
#     silently diverges between gawk and mawk and the fixture stops being a fixture.
#   A degenerate corpus (one length, three letters) defeats both prefilters, looks
#   like no real program, and would grade a worst case the fix does not claim.
#
# ⚠️ RESERVED WORDS. A generated name that happens to BE a keyword makes the file a
# PARSE error, which short-circuits before resolve and silently measures NOTHING while
# still reading as a clean run. `default`/`deriving`/`effect`/`export`/`extern` are all
# reachable at these lengths, so the generator ASSERTS none is emitted — and the driver
# separately asserts the fuzzy search actually RAN (see the typos block in the loop).
gen_typos() {
  n=$1; f=$2
  awk -v n="$n" 'BEGIN {
    L = "abcdefghijklmnopqrstuvwxyz";
    split("default deriving effect export extern", kw, " ");
    for (k in kw) RESV[kw[k]] = 1;
    bad = "";
    for (i = 0; i < n; i++) {
      len = 5 + (i % 8); s = ""; v = i + 1;
      for (p = 0; p < len; p++) {
        v = (v * 75 + 74) % 65537;
        s = s substr(L, (int(v / 251) % 26) + 1, 1);
      }
      if (("d" s) in RESV || ("e" s) in RESV) bad = s;
      printf "d%s : Int\nd%s = %d\n", s, s, i;
      printf "e%s : Int\ne%s = x%s\n", s, s, s;
    }
    printf "main = println 1\n";
    if (bad != "") {
      printf "gen_typos: generated suffix %s collides with a RESERVED WORD\n", bad > "/dev/stderr";
      exit 1;
    }
  }' > "$f" || { echo "FAIL typos: generator assertion tripped (reserved-word collision)"; exit 1; }
}

# ── Measure ──────────────────────────────────────────────────────────────────
# ⚠️ THE ALLOCATION RUNS DO NOT RUN wasm-emit (env -u MEDAKA_PERF_WASM), and that is
# deliberate — it RESTORES this column to what it was calibrated on. #481 added the
# wasm stage to this driver, which silently folded wasm's ~242 MB prelude constant (and
# on rooted shapes its 519->1353 MB scaling term) into every `total` this column reads.
# It cost nothing to remove because ALLOC WAS ALREADY BLIND TO IT: #481's own finding
# was that this column reads a flat 2.02x "ok" for a wasm stage taking 38 SECONDS. So
# the wasm arm's coverage is, and always was, the TIME signal alone (grade_wasm_row) —
# excluding it here loses no signal, un-dilutes the numbers, and drops 3 wasm runs per
# shape. `env -u` because an empty-but-SET var reads as present (see stage_times_min).
#
# Returns TOTAL allocated MB for one fixture. Allocation is deterministic, so ONE
# run suffices — no min-of-K needed, and no noise to average away.
alloc_of() {
  env -u MEDAKA_PERF_WASM MEDAKA_PERF=1 "$PROFILE" "$RUNTIME" "$CORE" "$1" 2>&1 \
    | awk '/^\[perf\] total/ { gsub(/MB/,"",$4); print $4; exit }'
}

# Same, but through the MULTI-MODULE driver (issue #153). Args: <entry.mdk> <root>.
alloc_of_modules() {
  MEDAKA_PERF=1 "$PROFILE_MODULES" "$RUNTIME" "$CORE" "$1" "$2" 2>&1 \
    | awk '/^\[perf\] total/ { gsub(/MB/,"",$4); print $4; exit }'
}

# ── ONE run, TWO deterministic arms (alloc + op) — the shared per-shape run ────
#
# The ALLOC and OP arms are BOTH deterministic and BOTH read the SAME wasm-off
# `MEDAKA_PERF=1` profiler run: allocation from the `total` line, op-counts from every
# stage line's tab-delimited 5th column (emitPhaseAO). So the loop runs the profiler
# ONCE per size, captures the full [perf] output, and derives both from it — the op
# arm costs ZERO extra invocations (it used to call a separate `stage_ops` run 3× per
# shape). `env -u MEDAKA_PERF_WASM` is identical to alloc_of's command, so the alloc
# numbers are byte-unchanged by this sharing.
#
# profile_run: emit the full [perf] output of one wasm-off run to stdout.
profile_run() {
  env -u MEDAKA_PERF_WASM MEDAKA_PERF=1 "$PROFILE" "$RUNTIME" "$CORE" "$1" 2>&1
}

# alloc_from: total allocated MB, from a saved profile_run output. Same awk as alloc_of.
alloc_from() {
  awk '/^\[perf\] total/ { gsub(/MB/,"",$4); print $4; exit }' "$1"
}

# ops_from: one "<stage> <opDelta>" line per stage, from a saved profile_run output.
# ⚠️ PARSE WITH awk -F'\t' AND READ FIELD 5. The profiler line is
#     [perf] <label>\t<t>s\t<MB>MB\t<ops>\t<opDelta>
# and the <ops> field (tab-field 4) is FREE-FORM with embedded spaces ("N decls"), so a
# whitespace split lands inside it and reads garbage. See support/timer.mdk:emitPhaseAO.
ops_from() {
  awk -F'\t' '/^\[perf\] / { split($1, a, " "); print a[2], $5 }' "$1"
}

# tc_alloc_from: the TYPECHECK-STAGE allocated MB, from a saved profile_run output.
# The exhaustiveness pass (checkMatchExhaustive) runs INSIDE typecheck, so this is
# where a literal-pattern-matrix quadratic shows (issue #988 — the `matchlits` block).
# Per-stage lines are tab-delimited; field 3 is "<MB>MB" (see ops_from's field-4 warning).
tc_alloc_from() {
  awk -F'\t' '/^\[perf\] typecheck\t/ { gsub(/MB/,"",$3); print $3; exit }' "$1"
}

# ⚠️ THE BASELINE MUST BE SUBTRACTED, OR THIS GATE IS BLIND.
#
# Every run pays a FIXED cost that has nothing to do with N: parsing and checking
# runtime.mdk + core.mdk allocates ~80 MB before the fixture is even looked at. At
# N=250 that constant DOMINATES, and the measured ratios come out at 1.2-1.5x —
# i.e. SUBLINEAR — which reads as "fine" while a genuine quadratic hides inside it.
#
# This is the same trap as the wall-clock measurement: raw `medaka check` ratios
# read 1.56 / 2.52 / 3.63, but with the 0.43s startup subtracted they read
# 1.86 / 2.95 / 3.88 — and only THEN is the quadratic unmistakable.
#
# So: measure an EMPTY fixture, subtract that constant, and compute the ratio on
# what the input actually costs. A gate that cannot see the bug it was built for is
# worse than no gate, because it certifies the bug as absent.
BASE_FIX="$WORK/_baseline.mdk"
printf 'main = println 1\n' > "$BASE_FIX"
BASE_ALLOC="$(alloc_of "$BASE_FIX")"
case "$BASE_ALLOC" in
  ''|*[!0-9.]*) echo "FAIL: could not measure the baseline allocation (harness bug)"; exit 1 ;;
esac
# ── TIME grading, PER STAGE (issue #110) ─────────────────────────────────────
#
# One profile_main run emits a `[perf] <stage> <time>s <alloc>MB` line per stage,
# so ONE run yields every stage's time. stage_times_min runs the profiler K times
# with the heap PINNED and keeps, per stage, the MINIMUM observed time.
#
# Output: one "<stage> <min-seconds>" line per stage, on stdout.
# Arg 3 (`wasm`, 0/1) sets MEDAKA_PERF_WASM, which makes profile_main RUN the
# wasm-emit stage at all — it is opt-in there, not merely unprinted. At 0 the profiler
# emits no `wasm-emit` line and does no WAT rendering; the caller must not then ask for
# that row (grade_time_stage would correctly call the absence a harness bug).
#
# ⚠️ OFF MUST *UNSET* THE VAR, NOT SET IT EMPTY. `getEnv` is C `getenv` and an empty
# var is still SET, so `MEDAKA_PERF_WASM=` reads as present. Spelling `off` as
# `MEDAKA_PERF_WASM="$wenv"` with an empty $wenv therefore leaves the stage ON, this
# gate silently pays the ~277 s it exists to save, and NOTHING fails — the rows still
# print, the shard is just slow again. (Measured; timer.mdk's perfWasmEnabled now also
# reads empty as OFF, so this is belt-and-braces. Keep both: the two halves fail open
# independently.) `env -u` also strips an AMBIENT value from the caller's shell, which
# is what stops a developer's exported MEDAKA_PERF_WASM from quietly re-pricing CI.
stage_times_min() {
  fixture="$1"; k="$2"; wasm="${3:-0}"
  i=0
  while [ "$i" -lt "$k" ]; do
    if [ "$wasm" = "1" ]; then
      GC_INITIAL_HEAP_SIZE="$TIME_HEAP" MEDAKA_PERF=1 MEDAKA_PERF_WASM=1 \
        "$PROFILE" "$RUNTIME" "$CORE" "$fixture" 2>&1
    else
      env -u MEDAKA_PERF_WASM \
        GC_INITIAL_HEAP_SIZE="$TIME_HEAP" MEDAKA_PERF=1 \
        "$PROFILE" "$RUNTIME" "$CORE" "$fixture" 2>&1
    fi | awk '/^\[perf\] / { t = $3; gsub(/s$/, "", t); printf "%s %s\n", $2, t }'
    i=$((i+1))
  done | awk '
      { if (!($1 in m) || $2 + 0 < m[$1] + 0) m[$1] = $2 }
      END { for (st in m) printf "%s %s\n", st, m[st] }
    '
}

# Same, but through the MULTI-MODULE driver. Args: <entry.mdk> <root> <k>.
stage_times_min_modules() {
  entry="$1"; root="$2"; k="$3"
  i=0
  while [ "$i" -lt "$k" ]; do
    GC_INITIAL_HEAP_SIZE="$TIME_HEAP" MEDAKA_PERF=1 \
      "$PROFILE_MODULES" "$RUNTIME" "$CORE" "$entry" "$root" 2>&1 \
      | awk '/^\[perf\] / { t = $3; gsub(/s$/, "", t); printf "%s %s\n", $2, t }'
    i=$((i+1))
  done | awk '
      { if (!($1 in m) || $2 + 0 < m[$1] + 0) m[$1] = $2 }
      END { for (st in m) printf "%s %s\n", st, m[st] }
    '
}

# ── OP-COUNT sampling (issue #884) ───────────────────────────────────────────
#
# The deterministic per-stage OPERATION counter (List-scan steps in util.contains /
# util.lookupAssoc, threaded through the profiler's emitPhaseAO 5th column). Unlike
# TIME this needs NO min-of-K, NO heap pin, and NO floor: GC-free integer counts are
# byte-for-byte reproducible, so ONE run yields the true per-stage op delta. That is
# the whole point — a deterministic signal grades the small stages (`mark` above all)
# that TIME physically cannot, because it is never contaminated by runner noise and so
# needs no 200ms floor to protect it. (`exhaust-guards` was named here too until #2333
# measured it: it can reach NO counted op at all, so it is waived rather than graded —
# see the OP_STAGES note below.)
#
# The per-stage op deltas are extracted (ops_from) from the SAME wasm-off run the ALLOC
# arm already makes each size — see the profile_run/alloc_from/ops_from block above.
# There is deliberately no separate op-sampling invocation: both arms are deterministic
# and share one run, so op-grading adds ZERO profiler invocations per shape.

# Stages to grade. `parse-prelude` is the FIXED one-time cost of runtime+core and
# does not scale with N, so grading it is meaningless; `total` is a sum and rule 1
# says never grade a sum.
#
# `fmt` is the comment-preserving format pass (profile_main runs `formatSource` on
# the target: collectComments + parseWithPositions + formatProgram). It is a pure
# scan — its two historical quadratics (lexer.posLineColFrom rescanned from offset
# 0 per comment; formatProgram rescanned the whole remaining comment tail per decl)
# allocated almost NOTHING, so allocation was blind to them and only the `comments`
# shape's TIME signal catches the class. On every OTHER shape fmt is under the
# 200ms floor and SKIPs (loud, harmless); the `comments` shape is sized so its fmt
# time clears the floor and is graded.
#
# `lint` is the PER-FILE lint tier (profile_main runs lintProgram over allRules on
# the raw AST). Graded on TIME, and the `manydefs` shape is sized so it clears the
# floor: its two historical quadratics were BOTH invisible to the alloc verdict —
# one (mergeRefs' assoc-list ref map) allocates quadratically but is only ~11% of
# `total`, so the total-alloc ratio DILUTES it to 2.24/2.53 ("ok") while the lint
# stage itself read 3.32/3.59; the other (missingSigPair's `contains` over the
# signed-name list) is a PURE SCAN that allocates nothing at all. Per-stage time is
# the only signal that sees both.
#
# `lower` and `emit` are the BACKEND arm (issue #359). Until 2026-07-16 this list
# stopped at typecheck, so the O(n^2) detector graded NOTHING downstream of the front
# end and every emitter quadratic was structurally invisible to it — the same blind
# spot that let a quadratic hide in `exhaust-guards`, one pipeline half later. The
# 2026-07-16 emitter audit (#349-#352) filed findings that sit entirely behind it, and
# most are PURE SCANS, so they need exactly this TIME arm: allocation cannot see them.
#
# ⚠️ THE BACKEND STAGES RUN BEHIND DCE, AND THAT DECIDES WHICH SHAPES CAN GRADE THEM.
# profile_main runs `dceFilter` before lowering, exactly as the real build driver does
# (llvm_emit_modules_main.mdk, half == 0). Its roots are `main` + impl/interface
# bodies, so a shape whose synthetic decls `main` never calls has them ALL pruned
# before the backend sees them: its `lower`/`emit` then time the prelude alone, come
# in far under TIME_FLOOR, and SKIP.
#
# That is CORRECT, not a malfunction — it is what `medaka build` does to those
# programs — and it is why only `xref` threads its decls into `main` (its chain makes
# one call retain all N). bindings/match/listlit/nesting/comments keep an unreachable
# `main = println 1`: they are FRONT-END shapes (DCE runs after typecheck, so parse/
# resolve/typecheck/fmt still see every decl and their rows are unaffected), and their
# backend stages were already under the floor even before DCE existed here.
#
# So do NOT read "lower/emit: SKIP" on those shapes as backend coverage. Backend
# coverage is `xref`, and the backend_graded counter below is what enforces that it
# did not silently become zero.
#
# ⚠️ These two stages carry a LARGE FIXED PRELUDE COST that the front-end stages do
# not: `lower`/`emit` run over `livePrelude ++ target`, so core.mdk is lowered and
# emitted on EVERY run (~13 MB / ~28 ms at N=1). The per-stage TIME arm does NOT
# subtract a baseline, so that constant DILUTES the ratio toward 1.0 — a quadratic in
# the target reads smaller here than it would in isolation. Read a `lower`/`emit`
# ratio as a LOWER BOUND on the true exponent: over-threshold is real, under-threshold
# is not proof of linearity.
#
# `wasm-emit` is the WASM ARM of the same issue (#359). `emit` above grades ONLY
# llvm_emit; wasm_emit is a separate ~10k-line backend and was equally unprofiled.
#
# ⚠️ ONE `emit` ROW CANNOT STAND IN FOR BOTH BACKENDS — this is measured, not assumed.
# #381 was a CUBIC in WasmGC ctor-switch emission (O(ctors x branches x table)) that did
# NOT reproduce on llvm_emit: `ctorOrdinal`'s whole-table scan is SHARED, but only wasm
# nested it inside a (slot, branch) loop. #401 fixed it (53x at N=400). The `match` shape
# is that exact shape and now reads r2=1.09 — the fix holds, and this row is what keeps
# it holding.
#
# ⚠️ THE PRELUDE CONSTANT IS FAR HEAVIER HERE THAN ON `emit`, and it changes how two
# rows must be read. wasm_emit renders the whole live prelude to WAT at ~0.215 s / ~240 MB
# no matter how small the target (llvm_emit: ~0.021 s / ~10 MB — 10x cheaper). Two
# consequences, both real:
#
#   * On the DEAD-`main` shapes (bindings/listlit/nesting/comments) DCE prunes the
#     synthetic decls, so this stage times THE PRELUDE AND NOTHING ELSE — but unlike
#     `lower`/`emit`, which fall under TIME_FLOOR and SKIP loudly, that constant is
#     ~0.215-0.25 s and generally CLEARS the 0.2 s floor. Those rows therefore print a
#     flat `ok r1≈1.0 r2≈1.0` (measured: 0.90/1.08, 1.09/1.21, 1.08/0.94). THAT "ok" IS
#     NOT BACKEND COVERAGE — it is the prelude constant being constant. Do not read it
#     as one, and do not let it satisfy backend_graded (see the counter below, which
#     deliberately excludes this stage).
#
#     ⚠️ THE CONSTANT IS NOT UNIVERSAL AND THE ROW COUNT IS LOAD-DEPENDENT — do not
#     build on either. `manydefs` SKIPs outright (156-174 ms): its `main = p0 + p1` is
#     `Int`-typed, not a `println`, so DCE keeps no Display/String prelude and there is
#     less WAT to render. `comments` sits ON the floor and flips: 220 ms (graded "ok")
#     on a loaded box, 198 ms (SKIP) on a quiet one. So "wasm-emit always clears the
#     floor" is FALSE, and so is any fixed count of rows it grades — both were asserted
#     by earlier drafts of this comment and both were falsified by the next full run.
#     Only ONE wasm row is guaranteed: `xref:wasm-emit`, and only because the ledger
#     forces it (a KNOWN_SLOW_TIME stage may not SKIP).
#   * On the ROOTED shapes (xref/match) the same constant DILUTES the ratio downward
#     harder than it does `emit`: at match N=1000 it is 79% of the reading. Under-
#     threshold here is even weaker evidence of linearity than it is for `emit`.
#
# ⚠️ `wasm-emit` IS NOT IN THIS LIST — it is graded by grade_wasm_row instead, on the
# shapes and the N band where it means something. It is NOT ungraded, and removing it
# from here does not weaken the deletion guard: grade_wasm_row routes through the same
# grade_time_stage, so a profiler that stops emitting the row still hard-fails with
# "NO MEASUREMENT". This list is "stages graded at the shape's own band"; wasm-emit is
# the one stage that is not, because it cannot afford resolve's N.
# ⚠️ `exhaust-guards` IS DELIBERATELY ABSENT FROM BOTH THIS LIST AND OP_STAGES, and
# it is WAIVED in test/PERF-STAGE-WAIVERS.txt rather than graded here. It is not an
# oversight and it is not a coverage gap — see that waiver for the measurement. The
# short version, because a reader who does not know it will "fix" this line: the
# stage's counted-op total is STRUCTURALLY ZERO (`compiler/frontend/exhaust.mdk`
# reaches `util.contains` from exactly one place, `firstMissing`, on the missing-
# CONSTRUCTOR-witness path, which no guard shape enters), and its wall time is 0.3-2.6
# ms on every shape measured, three orders under the ${TIME_FLOOR}s floor. Both arms
# printed SKIP on every shape for as long as the rows existed. It IS graded, per stage,
# by test/diff_compiler_stage_ir_scaling.sh's callgrind Ir arm, which reads it 2.13-2.25
# across match/xref/vchain — the `load` waiver's precedent exactly.
TIME_STAGES="parse desugar resolve mark typecheck elaborate dce mangle fmt lint lower emit"

# ── KNOWN SLOW (TIME) — a ledger, NOT a skip-list ────────────────────────────
#
# Same contract as KNOWN_SUPERLINEAR above, for the TIME signal: each entry
# records a REAL, CURRENTLY-UNFIXED superlinearity, so that it cannot get worse
# silently AND an accidental fix is detected and must be promoted out.
#
#   match:typecheck / listlit:typecheck — FOUND BY THIS GATE, the moment it could
#     see time at all (2026-07-14). Typecheck is superquadratic in the size of a
#     SINGLE declaration, and ALLOCATION IS BLIND TO IT — which is the entire
#     thesis of issue #110, demonstrated on a live bug:
#
#         match, typecheck stage      TIME              ALLOC
#           N=250                     0.024s            7.2 MB
#           N=500                     0.072s  (3.05x)   9.6 MB  (1.33x)
#           N=1000                    0.234s  (3.28x)  14.6 MB  (1.52x)
#           N=2000                    1.059s  (4.52x)  25.0 MB  (1.72x)
#           N=4000                    6.950s  (6.56x)  46.8 MB  (1.87x)
#
#     The ratio CLIMBS past 4.0 — it is worse than quadratic at these sizes — so
#     it is not a heap-resize step (a step collapses one doubling later; this does
#     not). A 4000-arm match spends SEVEN SECONDS in typecheck.
#
#     It is NOT about the number of declarations: `xref` has 16000 of them and
#     typechecks linearly (2.03x / 2.10x). It is about the size of ONE decl —
#     `listlit` is a single wide list literal containing NO `match` at all, and
#     blows up identically (2.75 -> 3.55 -> 3.93 -> 5.86). So the two entries are
#     very likely ONE root cause in HM inference / constraint solving over a large
#     expression, not two.
#
#     NOTE the T17 entry in KNOWN_SUPERLINEAR's history above says the `match`
#     quadratic was "FIXED 2026-07-13 ... 3.10x -> 2.18x". That was the ALLOCATION
#     ratio. The time-side blowup survived it untouched, and nothing in CI could
#     see it. That is exactly the blind spot this change closes.
#
# Ceilings gate r2. They are set with real headroom over the observed spread
# (match r2 3.23-3.36, listlit r2 3.39-3.55 across 3 batches) because a ratio at
# these small absolute times is the least stable number this gate computes.
# modules:typecheck — the TIME side of the O(modules^2) family (issue #153), the
# axis allocation is weakest on for a scan-heavy quadratic. Measured through the
# multi-module driver (min-of-K, heap pinned, N=100/200/400, K=8) on the
# resolve-CLEAN fixture, typecheck at N=400 is ~4.5s (well over the 200ms floor),
# r1=3.89 r2=4.12 — the ratio EXCEEDS the pure-quadratic 4.0 in this pre-asymptotic
# regime (constant/linear terms already negligible), as match:typecheck did before
# #115 (it reached 6.56 at N=4000). Observed r2 spread 4.1-4.3 across runs; ceiling
# 5.6 gives listlit-precedent headroom over that band plus time noise, still
# catching a genuine worsening. Same
# self-draining contract as the alloc entry: promoted out when #154/#150 land (the
# fix drops typecheck under the 200ms floor at the largest N, tripping the "too FAST
# to time-gate" promotion branch).
# #154 PR-A/PR-B/PR-C drained modules:typecheck: PR-C removed the last foldModules-concat
# O(N^2) (see KNOWN_SUPERLINEAR note) and the row was PROMOTED OUT 2026-07-16.
#
# 🚨 THE REST OF THIS ENTRY AS IT STOOD IS FALSIFIED, AND BOTH HALVES OF IT ARE. It claimed
# typecheck TIME "fell UNDER the 200ms floor at the gate's N (190ms @ N=400)", so that the
# modules block would SKIP the TIME grade; and it hedged that a run "under enough concurrent
# box load" could push mt3 back over the floor and take the hard-gate branch, reading as a
# regression rather than noise (#2018). MEASURED on this tree, min-of-5, heap pinned, N=400:
# **1942 ms** — 10.2x the 190 ms sample and 9.7x the floor. The SKIP branch has not been
# reachable at this band; every run takes the GRADING branch, which is what #1879 saw. And
# the load hedge is falsified with it: box load does not multiply a min-of-5 heap-pinned
# reading by ten, so the 190 ms sample was stale or mis-taken, not a scheduling artefact.
# (Its neighbour at the SKIP message's own parenthetical — "linear since #154 PR-C" — is
# falsified too; see the TIME verdict block below for what actually replaced it.)
#
# 🚦 TIME IS NO LONGER THE ARM OF RECORD FOR THIS ISSUE. #1879's flap is a REAL
# sub-threshold O(modules^2) term measured on three independent channels, and the arm that
# pins it is now the DETERMINISTIC one: `test/diff_compiler_stage_ir_scaling.sh`'s
# `modules:typecheck` KNOWN_SLOW row (see its KNOWN_SLOW block for the ceiling/fixed pair and
# the four attributed sites). This TIME grade STAYS LIVE as a coarse second opinion — it is
# not widened, retired, or floored away, because making a loud defect quieter is a severity
# increase — but a red here is now read against that Ir row, not treated as a novel finding.
#   xref:emit — ✅ PROMOTED OUT 2026-07-17 (PR #554). The gate FOUND this quadratic
#     the moment it could see the backend (2026-07-16, issue #359) and has now
#     watched it DIE: r2=1.98 (< 2.60) — the emit stage scales LINEARLY. The row is
#     deleted from KNOWN_SLOW_TIME; the stage is hard-gated like any other, so if it
#     ever climbs back this gate fails on it rather than excusing it.
#
#     THE CAUSE, for the record — it is the thesis below, confirmed: the emitter was
#     QUADRATIC IN THE NUMBER OF TOP-LEVEL DECLARATIONS because the threaded `sigs`
#     table (size = |fns|, i.e. it GROWS with the program) was `lookupAssoc`-scanned
#     LINEARLY once per param-use site — O(decls x decls). #554 indexed it into an
#     `OrdMap`; emitted IR is byte-identical, so only the scan changed.
#
#     ⚠️ AND IT IS THE PROOF OF THIS GATE'S OWN TIME ARM: allocation read a clean,
#     flat, LINEAR 2.03x throughout and was BLIND to the whole bug — a pure scan
#     allocates nothing. Had this gate graded allocation only (as it did before
#     issue #359 added the TIME arm), this quadratic would still be here today, and
#     the emitter would still take TEN SECONDS to emit 16000 functions.
#
#     The historical measurement that caught it is kept below, deliberately: it is
#     what a real find looks like, and it is the calibration for the next one.
#
#         xref, emit stage            TIME              ALLOC (whole-run net)
#           N=4000                    0.643s            1528.8 MB
#           N=8000                    2.392s  (3.72x)   3099.5 MB  (2.03x)
#           N=16000                   9.917s  (4.15x)   6289.6 MB  (2.03x)
#
#     Allocation reads a clean, flat, LINEAR 2.04x/2.04x — "ok" — while emit takes
#     TEN SECONDS to emit 16000 functions. Heap pinned, min-of-5, quiet box (load
#     <4). It is NOT a GC heap-resize step: a step COLLAPSES one doubling later, and
#     this ratio CLIMBS (3.72 -> 4.15) to/past the pure-quadratic 4.0 with the heap
#     pinned at 2 GB. Observed r2 band across FOUR DCE-realistic quiet-box batches:
#     3.85 / 4.01 / 4.11 / 4.15 (r1 3.62-3.82). The ~4.0 reading is the stable one;
#     treat the band, not any single batch, as the measurement.
#
#     ⚠️ THESE ARE THE *DCE-REALISTIC* NUMBERS, and that distinction is the whole
#     reason to trust them. The first cut of this entry measured a fixture whose
#     `main = println 1` rooted NONE of the N functions — work `dceFilter` (which the
#     real build driver runs, and which profile_main now runs too) would have pruned
#     entirely. That ratio described a scenario no real build performs. With `main`
#     rooting the chain the quadratic SURVIVES DCE essentially unmoved (r2 3.96 ->
#     4.11/4.15), so this is now a claim about `medaka build`, not about the harness.
#
#     This is the EMPIRICAL CONFIRMATION of the 2026-07-16 emitter perf audit
#     (#349/#350/#352), which found the quadratics by reading the source. #349
#     (dedupS conses) allocates and should show on the alloc arm; #350/#352 are pure
#     scans over accumulated per-decl state, which is what a flat alloc ratio beside
#     a 3.96x time ratio looks like. Fix those and this entry PROMOTES OUT.
#
#     THE OTHER ROOTED SHAPE, AND WHY IT IS NOT LEDGERED (measured 2026-07-16):
#     `xref` spreads its cost over N decls; `match` concentrates it in ONE rooted
#     decl (`toInt`, N arms). Both are now DCE-reachable, so "pruned" and "survived"
#     are distinguishable outcomes rather than one ambiguous number. Rooted
#     `match:emit`, net of the ~0.028s prelude constant, on a quiet box (load 1.9):
#
#           N=1000   0.099s      N=2000  0.366s (3.71x)     N=4000  1.366s (3.73x)
#
#     So the native LLVM emitter is QUADRATIC on this shape too (~3.7x), NOT cubic.
#     Worth stating plainly because the ws:wasm workstream measured ~7.9-8.4x per
#     doubling (≈2^3, CUBIC) on the SAME shape through `wasm_emit_modules_main` (#381).
#     That was a wasm_emit finding; it did NOT reproduce on llvm_emit. Do not carry the
#     cubic claim across backends.
#
#     It is NOT in KNOWN_SLOW_TIME because at this gate's match sizes (250/500/1000)
#     emit peaks at 122 ms — under TIME_FLOOR, so it SKIPs and there is nothing to
#     ledger. Grading it would need its own base-N knob (~1000, where emit is 1.4s);
#     that is a deliberate follow-up, not an oversight — raising match's N also moves
#     its alloc rows and the T17 alloc ledger, which must be re-derived, not assumed.
#
#     UPDATE 2026-07-16 (#359 wasm arm) — THE WASM CUBIC ABOVE IS FIXED, AND NOW
#     MEASURED. #401 fixed #381 (53x at N=400), and the `match:wasm-emit` row now checks
#     that rather than trusting it: 0.245s / 0.250s / 0.272s at N=250/500/1000, r1=1.02
#     r2=1.09 on a quiet box (load 0.6); this gate's own min-of-5 runs read r2=1.05/1.06.
#     So the band is r2 1.05-1.09 — the cubic is gone, and this row stops it returning.
#     Read that with the prelude caveat: at N=1000 the ~0.215s wasm prelude constant is
#     79% of the reading, so it is a WEAK linearity claim but a STRONG not-cubic one,
#     which is exactly what #401 is about. Unlike `match:emit`, this row is gradeable at
#     the gate's existing match sizes (the constant carries it over the floor), so the
#     wasm cubic needs no new base-N knob to stay regressed.
#
#     ⚠️ 4.15x is a LOWER BOUND on the true exponent, not an estimate of it. Unlike
#     the front-end stages, `emit` pays a large FIXED prelude cost (core.mdk is
#     emitted on every run, ~0.03s/~13 MB) that the per-stage TIME arm does not
#     subtract, so the constant term DILUTES the measured ratio downward.
#
#   xref:wasm-emit — THE WASM PEER OF THE ROW ABOVE, AND A SEPARATE MEASUREMENT.
#
#     wasm_emit is quadratic in the top-level declaration count too, and it is NOT a
#     restatement of `xref:emit`: it is a different ~10k-line backend, measured
#     independently. Rooted `xref`, quiet box (load 0.5), heap pinned at 2 GB:
#
#         xref, wasm-emit stage       TIME              ALLOC (this stage's delta)
#           N=4000                    2.439s            519.2 MB
#           N=8000                    9.317s  (3.82x)   796.9 MB   (1.53x)
#           N=16000                  38.128s  (4.09x)  1352.9 MB   (1.70x)
#
#     ⚠️ STATE THE N BAND WITH THE RATIO — A SCALING RATIO IS NOT A CONSTANT. These are
#     r1/r2 at N=4000 -> 8000 -> 16000, the band this gate's XREF_N fixes. The ceiling
#     below is only meaningful against THAT band: the same curve sampled at a different
#     N reads a different number, and both readings are correct. (This is exactly how
#     the ws:emitter and ws:wasm workstreams reported 3.71/3.73 and 2.27/2.87 for one
#     curve and briefly appeared to disagree.)
#
#     OBSERVED r2 BAND, same N, FIVE batches: 3.87 / 3.88 / 3.92 / 4.09 / 4.15
#     (r1 3.60-3.82). 4.09 is the quiet-box (load 0.5, min-of-2) reading above; 3.88 and
#     3.87 are this gate's own min-of-5 runs (the 3.87 on the tree merged with #468,
#     which reworked wasm_emit — it did not move this row); 3.92/4.15 are min-of-1
#     falsification runs. Treat the BAND as the measurement, not any single batch — and
#     note the QUIETER box read HIGHER, so a busy CI runner biases this row toward
#     false-green, never toward false-red.
#
#     ALLOCATION IS BLIND HERE TOO, AND HARDER THAN IT IS FOR `emit`. Two ways to see
#     it, both from the run above:
#       * this stage's OWN alloc delta reads 1.53x / 1.70x — not merely "linear (ok)"
#         but SUBLINEAR, because the ~240 MB fixed wasm prelude dominates the numerator;
#       * the gate's WHOLE-RUN net alloc column — the only alloc signal it actually
#         grades — reads a flat 2.02x / 2.02x and prints `ok` for this very row.
#     So a gate reading only allocation would call a stage taking 38 SECONDS to emit
#     16000 functions its healthiest row on the board. That is the #110/#115 thesis on a
#     second backend: these are PURE SCANS, and only the TIME arm can see them.
#
#     Mechanism note: this tracks `xref:emit` closely (3.97/4.08 in the same batch), so
#     the likely shared cause is `ctorOrdinal`/#352-class whole-table scans over
#     accumulated per-decl state, which both backends inherit. It is ~3.7x SLOWER in
#     absolute terms than llvm_emit on identical input. Fix the shared scans and BOTH
#     entries PROMOTE OUT — independently, which is the point of ledgering them apart.
#
#     ⚠️ 4.09x is a LOWER BOUND on the true exponent (the ~0.215s prelude constant is
#     not subtracted), and it is a WEAKER bound than `emit`'s: wasm's constant is ~10x
#     llvm's, so it dilutes harder.
#
# manydefs:lint (TIME) — the per-file lint tier is mildly SUPERLINEAR in TIME on the
# `manydefs` shape (DEEP-only; QUICK skips manydefs, so this entry is inert per-PR).
# Measured on a QUIET box (min-of-5, GC heap pinned, load ~1.5) at N=4000->8000->16000:
# r1=2.82 r2=3.37 — r2 comfortably over the 3.0 threshold and strengthening (an
# under-LOAD DEEP run read 3.04/3.31, the same signal). It is REAL, not a flap: TIME is
# the only arm that sees it (lint's alloc dilutes to ~2.0; the `manydefs:typecheck` OP
# quadratic that used to be its SEPARATE op-arm sibling was fixed by #907). Pre-existing —
# unrelated to #883's shapes. Ledgered self-drainingly: ceiling 4.3
# clears the observed r2=3.37 by ~28% (op counts... n/a here, TIME, so this absorbs
# runner noise too — hence the wider margin), TFIXED 2.60 (file convention). Tracked in
# #956 (the TIME-arm fragility issue); self-drains when the lint cost is made linear.
# One entry per line so draining a single row is a conflict-free one-line deletion
# (see #880 follow-up; the vars are word-split by `for k in $VAR`, newlines are IFS).
#
# nestedparens:parse / nestedparens:fmt / nestedparens:lint (TIME) — #164, S-4. The
# deep-paren-nesting shape (`main = ((...N...1...))`, NOT `gen_nesting`'s flat
# let-chain — S-3 confirmed the two shapes hit different substrates) is
# `Ir`/alloc-INVISIBLE the same way `modules:typecheck` (#1879) is: allocation
# grows exactly linearly (2.0x/doubling, S-3 per-stage isolation) while wall time
# does not. Three stages share this AST's deep-`ELoc` walk and are ALL
# superlinear on it, per S-3's per-stage isolation table and confirmed here
# (min-of-2, unpinned heap, this box, N=4000->8000->16000):
#     parse   0.311s -> 1.025s -> 4.802s   r1=3.30  r2=4.69
#     fmt     0.250s -> 1.132s -> 5.401s   r1=4.53  r2=4.77
#     lint    0.193s -> 1.400s -> 9.070s   r1=7.25  r2=6.48
# `desugar`/`resolve`/`mark`/`typecheck`/`elaborate`/`lower`/`emit` stay
# negligible at this band (S-3: every downstream tree-walking pass is
# constant-time on this shape even at depth 16,000) — only the three rows above
# are ledgered; every other stage grades normally (`ok` or SKIP-below-floor).
# `parse` is the row this slice exists for (#164's own substrate, un-pinned no
# further than S-3 already pinned it — see its report for the undischarged
# root-symbol lead); `fmt`/`lint` are the SAME walk over the SAME AST shape, not
# independent findings, so they are ledgered together rather than as a surprise
# later. None of these three is anywhere near the 3.0 threshold the way
# `modules:typecheck` straddles it — every r2 above clears 3.0 by 55%+ — so
# there is no flap here to special-case; TFIXED uses the file's 2.60 convention.
# Ceilings, each margin quoted over that stage's OWN observed top r2 across the
# four samples in S-4's report (parse 4.15/4.45/4.69/4.79, fmt
# 4.77/4.95/4.96/5.23, lint 4.59/4.76/6.48/7.25): `parse` 7.0 clears 4.79 by
# ~46%; `fmt` 6.5 clears 5.23 by ~24%; `lint` 9.5 clears 7.25 by ~31% (in the
# range of `xref:emit`'s ~35%-over-top margin convention).  ⚠️ The `parse` and
# `fmt` figures here previously read 5.61 and 4.95: 5.61 matches NO `parse`
# sample in S-4's report nor 60d400868's own commit message (it is a
# transplanted load-vs-check wall ratio from elsewhere in the epic), and 4.95
# was a middle `fmt` sample rather than that stage's top.  Neither ceiling
# constant moves — only the prose justifying it. DEEP-only/nightly placement
# ([G14]): a single N=16000 run alone costs ~26s and K=5 timing runs at three
# sizes cost roughly 3 more minutes total, the same order as `xref`'s DEEP band
# — a flappy-cost arm like this does not belong gating a PR merge.
# One entry per line so draining a single row is a conflict-free one-line deletion
# (see #880 follow-up; the vars are word-split by `for k in $VAR`, newlines are IFS).
# modules:typecheck (TIME) — the multi-module typecheck stage is SUPERLINEAR in TIME on
# the `modules` shape, in BOTH environments. It is #1879 (OPEN, `verified`), it is NOT
# fixed by this entry, and the DETERMINISTIC pin of record is and stays
# `test/diff_compiler_stage_ir_scaling.sh`'s `modules:typecheck` KNOWN_SLOW row
# (KNOWN_CEIL 2.45 / KNOWN_FIXED 2.10, Ir instruction counts). What is ledgered here is
# the WALL-CLOCK RESTATEMENT of that same curve, which flaps across its trip point.
#
# 🚨 THIS ROW IS LEDGERED BECAUSE A PARAGRAPH IN THIS FILE WAS FALSIFIED, not because the
# box got noisier. That paragraph (at the modules TIME verdict, now corrected) said the
# arm was "a property of this box ... while CI passes on the same commit", and told the
# reader to re-run. CI does not pass on it. PR #2245 hit it in all three of its
# merge-queue attempts, on a commit touching nothing near typecheck, and PR #2260 was
# bounced by the same row hours later. "Re-run or re-enqueue" was advice to play a
# lottery with the merge queue, and two PRs paid for it.
#
# THE BAND — seven samples, two environments, TIME-only:
#     this box (min-of-K, heap pinned, load ~1.6-2.1), N=100->200->400, three batches:
#       0.2077 -> 0.4548 -> 1.2272   r1=2.19 r2=2.70   (climbing clause)
#       0.2427 -> 0.4579 -> 1.4195   r1=1.89 r2=3.10   (threshold clause)
#       0.2346 -> 0.4878 -> 1.5108   r1=2.08 r2=3.10   (threshold clause)
#     CI merge queue (PR #2245 job 99250452312; the PR #2260 bounce):   r2=2.77, 3.21
#     #1879's own two original samples:                                 r2=2.86, 2.88
#     the verdict block's own record of the flap, and three runs under this ledger:
#                                                   r2=2.43, 2.67, 2.50, 2.49, 2.22
#   ⇒ combined r2 band 2.22 - 3.21, straddling the 3.0 THRESHOLD clause — which is why the
#   same row reports under two different clause names run to run, and why its LOW end, not
#   its median, is what sets TFIXED. Two clauses, one bug.
#
# THAT ANSWERS #1879'S OWN OPEN DISCRIMINATOR: "if CI's r2 is also ~2.87, the bug is in
# how the verdict reaches run_gates.sh's exit code; if CI's r2 is ~2.0, the curve
# genuinely differs by environment." Neither. CI reads 2.77/3.21 — the SAME band as the
# box. There is no reporting bug and no environment split.
#
# ALLOCATION IS BLIND TO IT: flat 2.03x / 2.06x on all three batches, printing `ok` for
# this very row while the same run's TIME arm read 3.10x. Nor is it a floor artifact —
# 1.23-1.51 s at N=400 against this arm's 200 ms floor.
#
# ⚠️ WHY LEDGERING IS NOT A WIDENING HERE ([W-QUIETER]). The bound is not relaxed, it is
# made two-sided and self-draining: over 4.2 this arm reds on WORSENING, under 2.00 it
# reds DEMANDING PROMOTION, and the Ir arm's hard 2.45 ceiling on the same curve is
# untouched. What stops is a flapping duplicate blocking unrelated PRs. Ceiling 4.2
# clears the observed top (3.21) by ~31%, the margin the other TIME rows here carry
# (manydefs:lint 4.3 over 3.37, ~28%; xref:emit 5.6 over 4.15, ~35%).
#
# One entry per line so draining a single row is a conflict-free one-line deletion
# (see #880 follow-up; the vars are word-split by `for k in $VAR`, newlines are IFS).
KNOWN_SLOW_TIME="
manydefs:lint
modules:typecheck
nestedparens:parse
nestedparens:fmt
nestedparens:lint
"
KNOWN_TCEIL_match_typecheck="4.6";    KNOWN_TFIXED_match_typecheck="2.60"
KNOWN_TCEIL_listlit_typecheck="4.8";  KNOWN_TFIXED_listlit_typecheck="2.60"
# manydefs:lint (TIME) — see the block above KNOWN_SLOW_TIME. Ceiling 4.3 clears the
# quiet-box r2=3.37 by ~28% (TIME is noisy, so the margin is wider than an op-arm ceiling);
# TFIXED 2.60 (file convention) sits well under the observed band so a quiet runner cannot
# false-PROMOTE it. Promotes out (#956) when the lint per-file cost is made linear.
KNOWN_TCEIL_manydefs_lint="4.3";      KNOWN_TFIXED_manydefs_lint="2.60"
# ⚠️ THIS ROW IS MEASURED AT TWO DIFFERENT BANDS depending on PERF_DEEP, and the entry
# below has to hold for BOTH:
#     DEEP  (nightly)  xref @ 4000->8000->16000   observed r2 3.85-4.15  (r1 3.57-3.82)
#     QUICK (per-PR)   xref @ 2000->4000->8000    observed r2 3.64       (r1 3.05), min-of-5
# They are not in tension: QUICK's r2 IS DEEP's r1 — the same 4000->8000 doubling of the
# same curve — which is why one ceiling covers both, and is also the cross-check that the
# quick band resamples the curve rather than losing it. It holds on the numbers: QUICK's
# r2=3.64 against DEEP's r1=3.57 (same tree, same day). (Same relation as xref:wasm-emit;
# see its note.) Ceiling 5.6 clears DEEP's top (4.15) by 1.45 and QUICK's (3.64) by 1.54;
# TFIXED 2.60 sits 1.40 under QUICK's r2. If you re-derive either number, state WHICH
# BAND you measured — a bare ratio here is unfalsifiable.
#
# Observed r2 3.85-4.15 across four DCE-realistic batches (incl. the merged tree with
# the `lint` stage present, which does not perturb emit). Ceiling 5.6 matches the
# modules:typecheck precedent, whose observed band (4.1-4.3) is the same one, rather
# than the tighter match/listlit ceilings set on a ~3.3 band; it clears the top of
# this band by 1.45, comparable to that precedent's 1.3. TFIXED 2.60 (the
# file-wide convention): drop under it and #349/#350/#352 are fixed and this entry
# must be promoted out.
KNOWN_TCEIL_xref_emit="5.6";          KNOWN_TFIXED_xref_emit="2.60"
# modules:typecheck (TIME) — see the block above KNOWN_SLOW_TIME for the sample band.
# Ceiling 4.2 clears its top (3.21) by ~31%.
#
# ⚠️ TFIXED IS 2.00, NOT the 2.60 file convention, AND THAT IS THE WHOLE POINT OF THIS ROW.
# This is the flappiest arm in the file. Ten samples of the SAME live quadratic, same
# band, same tree, span r2 = 2.22 to 3.21 — the two lowest (2.22, 2.43) came from runs
# whose neighbours read 2.50 and 2.67. A 2.60 TFIXED would therefore FALSE-PROMOTE about
# half the time: red the gate with "the bug is FIXED — remove the row" while
# `stage_ir_scaling` is still counting the quadratic on the same curve. That is a worse
# failure than the one this entry exists to stop, because it reads as a fix.
#
# 2.00 is chosen against the observed FLOOR (2.22), not the median, with ~10% of margin,
# and it still drains: a linearised stage reads AT OR UNDER 2.0 on this arm, because the
# per-run fixed overhead dilutes the ratio downward (the same argument this file makes for
# `emit`'s constant). ⚠️ But the drain of record is not here — it is `stage_ir_scaling`'s
# KNOWN_FIXED_modules_typecheck = 2.10, on deterministic instruction counts. This arm's
# job is to catch WORSENING and to stop lying; the deterministic arm decides "fixed".
#
# OBSERVED RED, both arms, this box, 2026-08-30 (#2160 rule 1 — an arm nobody has watched
# fail is not a pin). Driven by editing the pair, because this file assigns its ledger
# constants unconditionally and so cannot be driven from the environment:
#
#   $ KNOWN_TCEIL_modules_typecheck="1.00" KNOWN_TFIXED_modules_typecheck="0.50"  (in-file)
#   $ PERF_ONLY=modules sh test/diff_compiler_perf_scaling.sh
#              time typecheck: ** KNOWN-SLOW, AND GOT WORSE ** r1=1.97 r2=2.49 \
#                  (ceiling 1.00, N=100->200->400)
#   exit=1
#
#   $ KNOWN_TCEIL_modules_typecheck="9.00" KNOWN_TFIXED_modules_typecheck="3.00"  (in-file)
#              time typecheck: ** PROMOTE: now scales LINEARLY ** r2=2.22 (< 3.00, N=100->200->400)
#                      Remove "modules:typecheck" from KNOWN_SLOW_TIME — the bug is FIXED.
#   exit=1
#
# ⚠️ That second run is also where the 2.22 floor came from — the arm that proved the
# PROMOTE branch works is the same one that proved 2.60 would have fired it spuriously.
KNOWN_TCEIL_modules_typecheck="4.2";  KNOWN_TFIXED_modules_typecheck="2.00"
# nestedparens:{parse,fmt,lint} (TIME) — see the block above KNOWN_SLOW_TIME for the
# sample band and the margin/placement rationale. TFIXED uses the file's 2.60
# convention on all three (none straddles the 3.0 threshold the way
# modules:typecheck does).
KNOWN_TCEIL_nestedparens_parse="7.0"; KNOWN_TFIXED_nestedparens_parse="2.60"
KNOWN_TCEIL_nestedparens_fmt="6.5";   KNOWN_TFIXED_nestedparens_fmt="2.60"
KNOWN_TCEIL_nestedparens_lint="9.5";  KNOWN_TFIXED_nestedparens_lint="2.60"

is_known_time() {
  # PERF_LEDGER_EXTRA_TIME: add-only deliberate-red seam — see PERF_LEDGER_EXTRA.
  for k in $KNOWN_SLOW_TIME $PERF_LEDGER_EXTRA_TIME; do [ "$k" = "$1" ] && return 0; done
  return 1
}

# ── OP-COUNT grading, PER STAGE (issue #884) ─────────────────────────────────
#
# The deterministic third arm. It grades the SAME per-stage ratio idea as TIME, but
# on the noise-free op counter, so it needs none of TIME's four crutches (min-of-K,
# heap pin, 200ms floor, larger N). Its unique coverage is the SMALL front-end stages
# whose absolute time never clears the 200ms floor on ANY shape — `mark` above all —
# so TIME grades NOTHING there while OP grades them from a single run.
#
# `desugar` is in the list for completeness: it currently does ZERO counted ops (it
# calls neither util.contains nor util.lookupAssoc), so it always self-skips below
# OP_FLOOR — but the plumbing is here the day it starts scanning.
#
# ⚠️ `exhaust-guards` USED TO SIT BESIDE IT ON THAT ARGUMENT AND NO LONGER DOES (#2333).
# "The plumbing is here the day it starts scanning" is a claim about a stage that COULD
# start scanning. `exhaust-guards` cannot on any guard-bearing input: `exhaust.mdk` calls
# `util.contains` from exactly one site (`firstMissing`, reached only from
# `missingCtorPat` on the missing-CONSTRUCTOR-witness path) and `util.lookupAssoc` from
# none, while the guard-totality path — `checkGroup` -> `checkGroupCovered` -> `useful` —
# touches neither. MEASURED, three separate guard constructs, N=200, this box:
#     match-arm `if` guards       (N guarded `_` arms + catch-all)   ops 0
#     equation guards             (one clause, N `| cond = e` arms)  ops 0
#     N guarded-partial groups    (N functions, 2 guard arms each)   ops 0
# The row was therefore not "waiting for plumbing", it was unreachable, and a stage
# that prints SKIP on every shape forever is grading nothing while reading as covered.
# It is now WAIVED in test/PERF-STAGE-WAIVERS.txt and graded on the callgrind Ir arm
# instead; see the note above TIME_STAGES.
OP_STAGES="desugar resolve mark typecheck elaborate dce mangle"

# TOOSMALL guard (mirrors the alloc arm's d1<1.0, NOT TIME's noise floor — op counts
# are deterministic, so this is an ABSOLUTE-count guard, not a noise guard). A stage
# whose smallest-N op delta is under this is doing too little counted work to yield a
# meaningful ratio (desugar/exhaust-guards = 0; a constant handful like marksweep's
# resolve = 64). Grades everything above it.
OP_FLOOR="${PERF_OP_FLOOR:-1000}"

# ── KNOWN SLOW (OPS) — a ledger, NOT a skip-list ─────────────────────────────
#
# Same self-draining contract as KNOWN_SLOW_TIME / KNOWN_SUPERLINEAR: each entry
# records a REAL, currently-superlinear per-stage OP ratio, so the gate is green now
# yet (a) FAILS if the ratio worsens past its ceiling and (b) FAILS demanding
# promotion the instant a fix drops it back to linear. Because op counts are
# DETERMINISTIC, these ratios are exact and reproducible — the ceilings carry only the
# modest headroom needed to absorb drift from unrelated compiler-source changes, not
# runner noise.
#
# ⚠️ #884's design proposed shipping this EMPTY. That premise did not survive first
# contact: the moment the op arm graded resolve+typecheck across the existing shapes
# it surfaced two real superlinear op-signals that the current TIME and ALLOC arms do
# NOT grade — which is precisely the coverage this metric was built to add. They are
# ledgered (not shipped red) because they are pre-existing and out of #884's wiring
# scope; each is a candidate follow-up for the #880 epic.
#
# CURRENT ENTRIES (measured on this box, deterministic single run):
#
#   match:resolve — FIXED (#906, #969). Was resolve's `findDups ctorSeed (ctorNames
#         prog)` — O(N^2) in the CONSTRUCTOR count on the `match` shape (a data decl
#         with N ctors + an N-arm match), run once per ctor reference. MEASURED (pre-fix)
#         N=250/500/1000: 35644 -> 133769 -> 517519, r1=3.75 r2=3.87 (climbing toward the
#         pure-quadratic 4.0). `findDups` keyed into an OrdMap (op r2 -> 1.00, effectively
#         constant). De-ledgered.
#
#   xref:typecheck — FIXED (#907). Was typecheck's O(decls^2) assoc-list bookkeeping: the
#         binding-id stamp (stampBindingIds/lookupBindId, run in typecheck's checkBodyImpl)
#         scanned the O(decls) top-level frame once per EVar. Now an OrdMap (op r1/r2 ~1.95
#         at N=2000/4000/8000; TIME also promoted linear, r2=2.11). De-ledgered on both arms.
#
# NOT LEDGERED: `comments:typecheck`. ⚠️ THIS NOTE USED TO READ "r1=2.62 r2=3.00 at
# N=1000/2000/4000 — genuinely climbing", and it was WRONG — badly enough to matter,
# because a claimed r2 of exactly 3.00 sits one tick under the threshold and looked
# like a counterexample to the #2173 enumeration below. RE-MEASURED 2026-08-29 on
# this box at the shipped band:
#
#   $ PERF_ONLY=comments sh test/diff_compiler_perf_scaling.sh
#   ops typecheck: ok  r1=1.50 r2=1.66
#
# Not climbing, not near anything. The row is un-ledgered because it is LINEAR, not
# because a rule excused it. A ledger entry asserts a stage is ALREADY over
# threshold; this one is nowhere near.
#
#   reexports:resolve — FIXED (#925/#926). It WAS a clean 2^3 op cubic: on an N-deep
#         `export import m.*` chain, resolve re-checked an export set that GROWS with depth
#         via `util.contains` at three sites (realImport/importValueNames/localsExportedFrom)
#         — MEASURED 65025 -> 510050 -> 4040100, r1=7.84 r2=7.92 (N=50/100/200). #925 made
#         those three membership tests OrdMap-set lookups (uncounted `omHasKey`), #926 made
#         `findExports` a Map (O(log n), was the O(N^2) star scan) and the ambiguity
#         `addProvenance` a Map (was an O(names^2)/module assoc rebuild → cubic ALLOC). The
#         COUNTED op is now a deterministic 0, so this row LEFT KNOWN_SLOW_OPS. Its guard
#         MOVED to ALLOCATION (KNOWN_ACEIL_reexports_resolve) because the residual cost is an
#         INTRINSIC O(N^2): gen_reexports is cumulative, sum(i)=O(N^2) exported bindings, so
#         alloc can never be linear — it is graded with a quadratic-aware ceiling that a
#         cubic regression breaks, and the op arm rides along as a near-free "op-held-at-0"
#         regression assertion. See the resolve-shapes block. (The STAR dual, `starimports`,
#         stays op-graded — its imports route through the counted isPubExp path; see
#         gen_starimports.)
#
#   xref:elaborate — FIXED (#907). The elaborate stage runs elaborateDict, which re-checks
#         the program via checkProgramSeeded -> checkBodyImpl -> stampBindingIds — so it hit
#         the SAME O(decls^2) binding-id-stamp quadratic as xref:typecheck (the earlier
#         "elaborateDict reference-walking dict-routing" attribution was wrong; the cost was
#         stampBindingIds). Indexing the top frame drained it: op r1/r2 ~1.9 at both the
#         QUICK (2000/4000/8000) and DEEP (4000/8000/16000) bands. De-ledgered.
#   manyifaces:mark — FIXED (#953, #975). Was THE HEADLINE #883 FIND: mark's
#         `contains x methods` (marker.mdk markVar/markInfix — a List-as-set walked for
#         EVERY var/op node, `methods` = every interface-method name) was O(sites x
#         pool). No other shape stressed it: `marksweep` (#884) grows only the pool
#         with FIXED sites, so it reads LINEAR on purpose; `modules` has ONE interface
#         with ONE method. `manyifaces` co-scales N interfaces AND N reference sites
#         (§5's "co-scale the two multiplying dimensions" rule), so the scan read
#         O(N^2). MEASURED (pre-fix, this box, deterministic single run, R=8,
#         N=250/500/1000): 818999 -> 2512749 -> 8900249, r1=3.07 r2=3.54. `methods`
#         indexed to a set — op-ratio drops to linear. De-ledgered.
#
#   manyifaces:resolve — FIXED (#954, #969). Was a SECOND, INDEPENDENT quadratic the
#         same shape surfaced, a DIFFERENT mechanism from match:resolve (O(ctors^2)):
#         resolve's `findDups ifaceSeed (interfaceList prog)` was O(interfaces^2)
#         INDEPENDENT of the reference-site count R (the op-count was identical at R=4
#         and R=8) — interface-method duplicate-checking scanning the growing
#         interfaceList once per interface (resolve.mdk `findDups`). MEASURED (pre-fix)
#         N=250/500/1000: 37126 -> 136751 -> 523501, r1=3.68 r2=3.83 (climbing toward
#         the pure-quadratic 4.0). `findDups` keyed into an OrdMap (same fix as
#         match:resolve, one function, both rows drained together). De-ledgered.
#         (typecheck r1=2.65 r2=3.09 and elaborate r1=2.52 r2=3.04 also climbed on
#         this shape — the #907/#882 decl-count classes. Both were read `ok` by the
#         both-doublings rule because r1 < 3; since #2173 flipped this arm to r2
#         alone, `manyifaces:elaborate` went over the line and WAS ledgered as
#         #2189. This is what the flip was for — and #2189 has since been localised
#         and FIXED, so the row is drained; see the elaborate bullet above.)
#   conlocal:typecheck — issue #2030, and the MECHANISM IS KNOWN: `localPinPairs`
#         (compiler/types/typecheck.mdk) is O(constrained top-level bindings x locals),
#         so a program of N constrained fns each holding one local walks it O(N^2)
#         times. The `conlocal` shape co-scales exactly those two dimensions — see
#         gen_conlocal for why nothing else in this corpus does. MEASURED on this box
#         (deterministic single run, N=400/800/1600): 102 241 -> 351 241 -> 1 329 241,
#         r1=3.44 r2=3.78, both doublings over the 3.0 threshold. TIME does grade
#         typecheck on this shape (0.20/0.52/1.45 s) but reads r1 2.56 r2 2.78 — UNDER
#         threshold, because the band is sized for the op curve, not the time curve;
#         and total ALLOC reads r1 2.57 r2 2.89, also under. So the op arm is the only
#         arm that pins this at an affordable band. Ledgered (not shipped red) because
#         #2030 is OPEN and unfixed; it self-drains — the row PROMOTES and fails
#         demanding removal the moment the pin bookkeeping is indexed and r2 drops
#         under 2.60.
#         ⚠️ The Ir arm (diff_compiler_stage_ir_scaling.sh) reddens on the identical
#         shape at the identical band — and costs 415 s of callgrind to do it, on the
#         shard ci.yml already names as the CI pole, against ~13 s of native runtime
#         here. That is why this pin lives on this gate and not that one. Do not
#         "improve coverage" by duplicating it there.
#
#   conlocal:mark — FIXED (#2143). Was NOT attributed to #2030's `localPinPairs`
#         (that term is typecheck-only and says nothing about the marker), but
#         `markWithPrelude` reddened on the same shape at the same band via a
#         DIFFERENT mechanism: marker's own `contains x constrained` List-as-set
#         scan — the same site `frontend-breadth` slice 5's #1017 fix (marker.mdk's
#         `constrained` List->OrdMap) indexed, draining this row as a side effect
#         since both bugs were the same site. MEASURED (pre-fix) N=400/800/1600:
#         685 805 -> 2 207 005 -> 8 129 405, r1=3.22 r2=3.68; MEASURED (post-fix,
#         this row's promotion) 164 961 -> 205 361 -> 286 161, r1=1.245 r2=1.393 —
#         linear. De-ledgered.
#
#   conlocal:elaborate — issue #2030, and it is STILL LEDGERED, in KNOWN_SLOW_OPS
#         below — but for a DIFFERENT reason than when it was first written, and the
#         residual is now LOCALISED.
#         ⚠️ THE OWNING ISSUE MOVED, AND THIS LINE USED TO NAME THE OLD ONE. It read
#         "issue #2189" until 2026-08-31 (#2331 item 4, sprint hold-the-gains S-2).
#         #2189 is CLOSED: its bulk — the `elaborateDict` AST prepass probing
#         `rpNames`/`argNames`/`dictNames` with `util.contains` — was fixed and is
#         gone, as the paragraph below already says. What is left is `localPinPairs`,
#         which is #2030's term and #2030 is OPEN. A row whose only citation is a
#         CLOSED issue reads as a stale skip-list entry to the next reader; the drain
#         condition below is #2030's, so the citation is #2030's too. #2189 still
#         appears below in its HISTORICAL role, which is correct.
#         History: the row was first ledgered at
#         3 162 359 -> 8 788 559 -> 28 200 959 (r1=2.78 r2=3.21) when #2173 flipped
#         this arm to grade r2 alone.
#         ⚠️ THIS NOTE ALSO USED TO SAY THE OPPOSITE — "NOT LEDGERED, but WATCH … a
#         ledger entry asserts a row is ALREADY over threshold on both doublings, and
#         this one is not" — a live instruction to DELETE the row a few lines below,
#         which would have turned a real quadratic silent again.
#         #2189's SITE was then localised by sub-bracketing `elaborateDict`'s op
#         counter (S-3): 83% of the count was the AST prepass
#         (`prePassDict`/`prePassDictArg` -> `rewriteRPDict`/`rewriteArgScoped`)
#         probing `rpNames`/`argNames`/`dictNames` with `util.contains` at every
#         `EVar`, with `dictNames` = the N `=>`-constrained top-level names this
#         shape generates. That term is FIXED (OrdMap sets) and is gone: the row now
#         reads 373 231 -> 1 010 431 -> 3 244 831, r1=2.71 r2=3.21.
#         ⚠️ THE RATIO BARELY MOVED (3.209 -> 3.212) BECAUSE THE FIX REMOVED A
#         QUADRATIC TERM, NOT A LINEAR ONE — the row is 88% smaller in absolute ops
#         but the same shape. What is left is 94% the TWO `checkProgramSeeded` calls
#         inside `elaborateDict` (1 531 210 + 1 530 741 of 3 244 831 at N=1600), i.e.
#         `localPinPairs` — the SAME term as conlocal:typecheck, issue #2030. So the
#         old "plausibly rides the same localPinPairs term" guess is now MEASURED and
#         TRUE OF THE RESIDUAL (it was false of the bulk). This row drains with
#         #2030, not before it. Total ALLOC on this
# shape is the other near-miss: r1 2.57 r2 2.89 against a 3.0 ceiling (and against the
# `climbing` heuristic's 2.96 trip point), which is why the shape is not additionally
# ledgered on the alloc arm — it is under, deterministically, at this band.
# One entry per line so draining a single row is a conflict-free one-line deletion
# (see #880 follow-up; the var is word-split by `for k in $VAR`, newlines are IFS).
KNOWN_SLOW_OPS="
conlocal:typecheck
conlocal:elaborate
"
# Ceilings follow this file's op-arm convention (the drained manyifaces:mark /
# match:resolve / manydefs:typecheck / conlocal:mark entries all used the same pair):
# OCEIL 4.3 — ~14% over the measured r2 of 3.78 and above the pure-quadratic asymptote
# of 4.0, so unrelated compiler-source drift cannot flap it while a CUBIC regression
# (r2 ~8) trips it immediately; OFIXED 2.60 — the file-wide "this is linear again,
# promote me" mark, 1.2 under the measured band, so no drift can false-PROMOTE either
# row. Op counts are DETERMINISTIC, so these absorb source drift only, never runner
# noise. Tied to CONLOCAL_N=400 — see that knob before moving the band.
KNOWN_OCEIL_conlocal_typecheck="4.3"; KNOWN_OFIXED_conlocal_typecheck="2.60"
#
# ── #2189: elaborate was quadratic on two independent shapes; ONE ROW LEFT ────
#
# HISTORY. Both rows are what the #2173 verdict flip (r2 alone, not r1 && r2)
# newly turned red, and they were REAL superlinearity, not bands chosen under the
# old rule. Established by extending each shape's ladder past the gate's own band
# — the direction of the ratio, not one number:
#
#   gen_conlocal   elaborate  400 ->  3162359    800 ->  8788559   r=2.779
#                             1600 -> 28200959   3200 -> 99665759  r=3.209 / 3.534
#   gen_manyifaces elaborate  250 ->  1420288    500 ->  3584288   r=2.524
#                             1000 -> 10912288   2000 -> 37568288  r=3.044 / 3.443
#                             4000 -> 138880288                    r=3.697
#
# A linear stage holds 2.0. A ratio climbing monotonically toward 4.0 is a
# quadratic term that has not yet swamped the linear one. Two shapes with no
# shared generator code did it, so the property was elaborate's, not a fixture's.
#
# THE SITE, LOCALISED (S-3). The op counter was sub-bracketed inside
# `elaborateDict` (types/typecheck.mdk) with a throw-away per-region counter, so
# each of its steps was priced separately. One family carried the bulk on BOTH
# shapes: the EVar prepass — `prePassDict`/`prePassDictArg` ->
# `rewriteRPDict`/`rewriteRPDictArg`/`rewriteArgScoped` — probed the three name
# sets (`rpNames`, `argNames`, `dictNames`) with `util.contains`, a List-as-set,
# once per `EVar` node, plus `dictPass`'s `contains n names` once per decl. Each
# set grows with the program, so both reads are O(nodes x names). The thirteenth
# and fourteenth instances of this file's one recurring shape. (It is NOT in
# `ir/core_ir_lower.mdk`, which #2189's body guessed, and it is NOT the
# `:527` wildcard-row residual from #2125 — a different pass and a different
# mechanism.) Measured share of the pre-fix count, at each row's own top rung:
#   conlocal N=1600:   prepass 23 532 136 of 28 200 959  = 83%
#   manyifaces N=1000: prepass 10 165 053 of 10 912 288  = 93%
# FIX: index all four sets to OrdMaps (`omFromNames` / `omHasKey`), exactly the
# treatment `bound` in the same function already had from #1031. Membership
# semantics are unchanged, so the rewrite is parity (verified run == native build
# on a fixture exercising the rp / arg / dict / method-shadowing-local arms).
#
#   manyifaces:elaborate  109378 -> 162628 -> 269128   r1=1.487 r2=1.655  LINEAR
#                         => PROMOTEs, DRAINED, row and ceilings deleted.
#   conlocal:elaborate    373231 -> 1010431 -> 3244831 r1=2.707 r2=3.212  STAYS.
#
# ⚠️ WHY conlocal's RATIO DID NOT MOVE (3.209 -> 3.212) THOUGH THE ROW SHRANK 88%.
# The prepass term was itself quadratic, so removing it removed numerator and
# denominator together. What remains is a SECOND quadratic, and it is now fully
# attributed: 3 061 951 of the residual 3 244 831 at N=1600 (94%) is the two
# `checkProgramSeeded` calls inside `elaborateDict` — i.e. `localPinPairs`, the
# SAME term as conlocal:typecheck, issue #2030. The pre-existing "elaborate
# re-checks the program through checkProgramSeeded, so it plausibly rides the
# same localPinPairs term" note was therefore FALSE OF THE BULK and TRUE OF THE
# RESIDUAL. This row drains WITH #2030 and cannot drain before it.
#
# ⚠️ THE CEILING ARITHMETIC (#2160 rule 3: derive the margin, do not fit it to
# the number it bounds, and show the work).
#
# Step 1 — what is the variance? ZERO. These are the deterministic op counts of
# `MEDAKA_PERF=1` (field 5), a pure function of the input program: two
# independent recordings of the pre-fix conlocal:elaborate, weeks apart, agreed
# to the byte (3162359 / 8788559 / 28200959). Measured drift 0.00%. So the margin
# CANNOT be derived from noise, and any margin here is a stated policy about how
# much coefficient growth is tolerated before the gate shouts.
#
# Step 2 — state the policy in the units that matter. Fit net = a*N + b*N^2 at
# the row's own band and ask what multiplier k on the quadratic coefficient b
# pushes r2 over a candidate ceiling. POST-FIX conlocal, from N=800/1600
# (1010431, 3244831): a=498.058125, b=0.95622578125.
#
#       k=0.50 -> r2=2.8688   k=1.00 -> 3.2113   k=1.25 -> 3.3150
#       k=1.50 -> 3.3947      k=2.00 -> 3.5088
#
# Recompute rather than trusting the table (the k=0.5 and conlocal k=2 cells were
# WRONG in the first version of this block, and an independent review of the PR
# caught it):
#
#   python3 -c 'f=lambda a,b,k,N: a*N+k*b*N*N; \
#     print(f(498.058125,0.95622578125,1.25,1600)/f(498.058125,0.95622578125,1.25,800))'
#
# The policy adopted, unchanged: FAIL once the quadratic coefficient grows by a
# quarter. k=1.25 gives 3.3150, so the file's 2-dp convention keeps OCEIL 3.31 —
# it now trips at k >= ~1.236 (was ~1.245 against the pre-fix coefficients: a
# slightly TIGHTER gate, from rounding down, which is the safe direction). THE
# CEILING IS THEREFORE UNCHANGED AT 3.31 — re-derived, not carried over, and not
# fitted to the 3.212 it bounds. Note how flat r2 is in k: this is exactly why a
# ceiling on an ALREADY-quadratic row has to sit close. The file's usual 4.3
# convention is ABOVE the pure-quadratic asymptote of 4.0 and therefore could
# never catch an already-quadratic row getting worse at all; 4.3 is right for a
# row whose measured r2 is 3.78 and whose failure mode is CUBIC, and is the wrong
# instrument here.
#
# OFIXED 2.60, the file-wide promote mark. Check it discriminates: draining #2030
# drives r2 -> ~2.0 and PROMOTEs (correct); merely halving what is left gives
# k=0.5 -> r2=2.8688, which stays ledgered (correct — a half-fix is not a fix).
# The margin above the promote mark is 0.27, so no source drift can false-PROMOTE
# this row, and a genuine #2030 fix cannot fail to.
#
# 🚨 THE CEILING IS PER-BAND. It is derived at CONLOCAL_N=400 and is meaningless
# at any other N — r2 itself is a function of the band on a quadratic row (the
# pre-fix manyifaces row read 3.044 at 250 and 3.443 at 1000). Moving the knob
# invalidates the ceiling: RE-DERIVE from a fresh ladder, do not scale. This is
# the #2172 lesson (KNOWN_CEIL_scoperefs=3.26 is a 3000-only number; at 6000 the
# same tree reads 3.438) written down before it bites again.
#
# ── 2026-08-31, sprint hold-the-gains S-2 (#2331): THE SPRINT-WIDE HEADROOM
# CONVENTION WAS DELIBERATELY NOT APPLIED HERE. That convention is "10% over a
# freshly measured r2, capped below the measured reading of the defect the row
# guards" (see NOTES.md; S-3 and S-4 apply it). It is a FALLBACK for rows with no
# cost model. THIS row has one — the coefficient-growth derivation above — and the
# paragraph above already states why a flat percentage is the wrong instrument for
# an already-quadratic row. 3.31 stands, re-derived and unchanged. Do not "unify"
# it with the flat-percentage rows; that would loosen it from 3.31 toward 3.5+.
KNOWN_OCEIL_conlocal_elaborate="3.31";   KNOWN_OFIXED_conlocal_elaborate="2.60"
# reexports:resolve was HERE (op ceiling 8.9) — the cubic (r2=7.92) counted `util.contains`
# scans over a re-export export list that grows with depth. #925/#926 FIXED it: the three
# scans are OrdMap-set membership now (uncounted) and `findExports`/provenance are Maps, so
# the shape's COUNTED op is deterministically 0 — op-invisible, cannot be graded (would trip
# the rshape TOOSMALL guard). Its guard MOVED to ALLOCATION (KNOWN_ACEIL below), because the
# shape's residual cost is an INTRINSIC O(N^2): gen_reexports is CUMULATIVE (m_i does
# `export import m{i-1}.*` PLUS its own v_i), so the exports across N modules total sum(i) =
# O(N^2) name entries — resolve MUST allocate O(N^2) regardless of algorithm. So alloc can
# never read "linear"; it is graded with a QUADRATIC-AWARE ceiling that a super-quadratic
# (cubic) regression breaks. The op arm still runs as a cheap regression ASSERTION (a
# reintroduced counted-scan cubic would lift op off 0 — see the rshape loop).
#
# ── alloc self-draining ledger (the alloc analogue of KNOWN_OCEIL/OFIXED) ──
# ACEIL 4.0: the resolve-STAGE alloc ratio at the FIXED band N=100->200->400 is a
# deterministic r2=3.10 (intrinsic-quadratic, converging to 4.0 from below as N grows; at
# this fixed finite band it is 3.10, ~29% under 4.0). A cubic-ALLOC regression reads r2=4.41
# at this same band (MEASURED by reverting the provenance-map fix), 10% over — caught. AFIXED
# 2.30: if the export representation is ever made sub-quadratic (e.g. shared/lazy exports) the
# ratio drops under 2.30 and this row PROMOTES (retire the quadratic allowance). Deterministic
# (GC bytes), so this absorbs only compiler-source drift, not runner noise.
KNOWN_ACEIL_reexports_resolve="4.0"; KNOWN_AFIXED_reexports_resolve="2.30"
# widerecords:typecheck was HERE (op ceiling 4.3) — an O(record-fields x field-accesses)
# quadratic in typecheck's record-field inference: inferFieldOfRecord re-`instantiateRecord`d
# ALL N fields and `lookupAssoc`-scanned the N-field assoc list per access, and
# inferRecordUpdatePicked/-With did the same per update (the typecheck sibling of resolve's
# `ownersOf` record scan this shape was built to stress). #980 FIXED it: RecordInfo
# now carries an O(log N) name→Mono field INDEX built once at registration, the access/update
# paths instantiate ONLY the result + the accessed field (via the shared param subst) instead
# of rebuilding all N, and the field lookup is an uncounted `omLookup`. So the counted-op work
# on these paths is gone and typecheck reads LINEAR on this shape — byte-identical inference
# (same schemes, same error set + order; verified against the fixpoint + typecheck_compiler_
# source). Row drained; the widerecords shape still runs as a linear regression guard.

is_known_ops() {
  # PERF_LEDGER_EXTRA_OPS: add-only deliberate-red seam — see PERF_LEDGER_EXTRA.
  for k in $KNOWN_SLOW_OPS $PERF_LEDGER_EXTRA_OPS; do [ "$k" = "$1" ] && return 0; done
  return 1
}

fail=0
known=0
pass=0

# How many stage OP-ratios were actually graded. Mirrors backend_graded: "green" must
# never mean "graded nothing". If every OP_STAGES reading fell under OP_FLOOR (e.g. the
# profiler stopped emitting the 5th column, so every field-5 read was empty→0) this
# would be 0 and the arm would be silently dead. Asserted non-zero at the bottom.
ops_graded=0

# How many times a NATIVE backend stage (lower/emit) actually produced a graded ratio.
# "Green" must never mean "did not run": if these two always SKIP under the TIME_FLOOR
# the gate silently reverts to issue #359's blind spot — grading no backend stage at
# all — while still exiting 0. Asserted non-zero at the bottom of this file.
#
# ⚠️ `wasm-emit` IS DELIBERATELY NOT COUNTED HERE, and the reason is the whole point of
# the counter. Its ~0.215-0.25 s prelude constant clears the 0.2 s floor on most shapes
# (4-5 of 7, load-dependent) — including the dead-`main` ones where DCE has pruned
# everything and it is timing the prelude alone. Counting it would peg this counter at
# 5-6 on every run: it would never be zero again, so it could never fail, and the llvm
# arm's floor-skip regression (the ONLY thing it detects) would sail through behind wasm
# rows that measured nothing but the prelude. A guard that cannot fail is not a guard.
# (Measured: with wasm-emit excluded this counter still reads 1, the same as before this
# stage existed — so the llvm guard is provably undiluted.)
#
# The wasm arm does not need this counter, because it is guarded twice over and more
# tightly:
#   * a stage in TIME_STAGES that the profiler stops emitting at all is already a hard
#     FAIL ("NO MEASUREMENT from the profiler") in the loop below — that covers deletion;
#   * `xref:wasm-emit` is LEDGERED in KNOWN_SLOW_TIME, and a ledgered stage MAY NOT SKIP:
#     dropping under the floor fires PROMOTE and FAILS. So the one row that carries the
#     wasm arm's real coverage is provably graded on every green run, or the gate is red.
backend_graded=0

# Grade ONE stage's three timings. Args: shape st s1 s2 s3 n1 n2 n3.
#
# Extracted from the shape loop so the WASM row can be graded on a DIFFERENT N BAND
# from the rest of its shape (see grade_wasm_row). That is the whole reason this is a
# function: the band is an argument, not the ambient $n1/$n2/$n3, because
# `xref:wasm-emit` is measured at 2000/4000/8000 while `xref:resolve` needs
# 4000/8000/16000.
#
# ⚠️ THE BAND IS PRINTED WITH EVERY RATIO, and that is not decoration. The ledger's
# ceilings are calibrated per-band ("a scaling ratio is not a constant"), and two
# workstreams once appeared to disagree about one curve purely because each quoted a
# ratio without its band. A row that states
# r2=3.82 and not the N it came from is unfalsifiable.
#
# Mutates the caller's fail/known/backend_graded/time_bad/time_lines. Must be called
# directly, NEVER in a subshell or a pipe — the counters would vanish and every verdict
# would silently read zero.
grade_time_stage() {
  shape="$1"; st="$2"; s1="$3"; s2="$4"; s3="$5"; gn1="$6"; gn2="$7"; gn3="$8"
  band="N=${gn1}->${gn2}->${gn3}"

  # A stage the profiler never emitted is a HARNESS bug, not a pass.
  if [ -z "$s1" ] || [ -z "$s2" ] || [ -z "$s3" ]; then
    time_lines="${time_lines}           time ${st}: NO MEASUREMENT from the profiler (harness bug)
"
    fail=$((fail+1))
    return
  fi

  # RULE 4 — the per-stage floor. Under it, the ratio is noise: SKIP, loudly.
  #
  # ⚠️ BUT A LEDGERED STAGE MAY NOT SKIP. Dropping below the floor is not an
  # absence of signal for a KNOWN_SLOW_TIME entry — it IS the signal: the stage
  # got so fast it is no longer measurable, which is exactly what "fixed" looks
  # like. Skipping here would let a stale ledger entry rot behind a green gate,
  # and "a ledger that cannot notice the bug is fixed" is a skip-list — the very
  # thing this ratchet exists to not be. (Caught for real: #115's fix took
  # `match:typecheck` from 6.0 s to 75 ms, under the floor, and the first cut of
  # this gate reported "0 known-superlinear, 0 regressed" and exited 0.)
  below="$(awk -v v="$s3" -v f="$TIME_FLOOR" 'BEGIN{print (v + 0 < f + 0) ? 1 : 0}')"
  if [ "$below" = "1" ]; then
    ms3="$(awk -v v="$s3" 'BEGIN{printf "%.0f", v*1000}')"
    msf="$(awk -v f="$TIME_FLOOR" 'BEGIN{printf "%.0f", f*1000}')"
    if is_known_time "${shape}:${st}"; then
      fail=$((fail+1))
      time_lines="${time_lines}           time ${st}: ** PROMOTE: now too FAST to time-gate ** ${ms3} ms at N=${gn3} < ${msf} ms floor
           Remove \"${shape}:${st}\" from KNOWN_SLOW_TIME — the bug is FIXED.
"
      return
    fi
    time_lines="${time_lines}           time ${st}: SKIP — too small to time-gate: ${ms3} ms at N=${gn3} < ${msf} ms floor
"
    return
  fi

  # Past the floor: this stage gets a real ratio. Record that the backend arm ran.
  case "$st" in lower|emit) backend_graded=$((backend_graded+1)) ;; esac

  tr1="$(awk -v a="$s1" -v b="$s2" 'BEGIN{printf "%.2f", b/a}')"
  tr2="$(awk -v a="$s2" -v b="$s3" 'BEGIN{printf "%.2f", b/a}')"
  # SUSTAINED signal only: both doublings over threshold.
  bad="$(awk -v r1="$tr1" -v r2="$tr2" -v th="$THRESH" 'BEGIN{print (r1 > th && r2 > th) ? 1 : 0}')"

  if is_known_time "${shape}:${st}"; then
    lk="$(printf '%s_%s' "$shape" "$st" | tr -c 'a-zA-Z0-9_' '_')"
    # `:-` under `set -u` (:109) — see the ALLOC arm's note. Without it an unset
    # ceiling KILLS THE GATE mid-run with exit 2 and nothing this file wrote, and
    # exit 2 is run_gates.sh's skip candidate. PERF_LEDGER_EXTRA_TIME routes
    # straight into this branch, so the hazard is live, not theoretical.
    #
    # OBSERVED RED, 2026-08-28, this box, verbatim (#2160 rule 1 — an arm nobody
    # has watched fail is not a pin). First the hazard the `:-` removes:
    #
    #   $ /bin/sh -c 'set -u; eval "x=${KNOWN_OCEIL_foo_bar}"; echo unreachable'
    #   /bin/sh: 1: KNOWN_OCEIL_foo_bar: parameter not set
    #   exit=2                      <- no output of ours, and 2 is the skip code
    #
    # then this branch, reached through the add-only injection seam:
    #
    #   $ PERF_LEDGER_EXTRA_TIME="xref:typecheck" sh test/diff_compiler_perf_scaling.sh
    #   ## LEDGER INJECTION ACTIVE — this run's verdicts are NOT a grading result. ##
    #              time typecheck: ** MALFORMED LEDGER ROW ** no KNOWN_TCEIL_xref_typecheck / KNOWN_TFIXED_xref_typecheck pair.
    #              A ledger row without both halves cannot drain itself — that is a skip-list, not a pin.
    #   exit=1
    eval "tceil=\${KNOWN_TCEIL_$lk:-}"
    eval "tfixed=\${KNOWN_TFIXED_$lk:-}"
    if [ -z "$tceil" ] || [ -z "$tfixed" ]; then
      fail=$((fail+1))
      time_lines="${time_lines}           time ${st}: ** MALFORMED LEDGER ROW ** no KNOWN_TCEIL_${lk} / KNOWN_TFIXED_${lk} pair.
           A ledger row without both halves cannot drain itself — that is a skip-list, not a pin.
"
      return
    fi
    tworse="$(awk -v r="$tr2" -v c="$tceil" 'BEGIN{print (r > c) ? 1 : 0}')"
    tbetter="$(awk -v r="$tr2" -v f="$tfixed" 'BEGIN{print (r < f) ? 1 : 0}')"
    # OBSERVED RED, the TIME ledger's ceiling and promote arms (#2160 phase 2).
    #
    # 🚨 THE FIRST ATTEMPT REPORTED SUCCESS AND PROVED NOTHING, which is worth
    # more than the transcript. Moving an EXISTING ledger row's ceiling from the
    # environment does not work here:
    #
    #   $ PERF_ONLY=match KNOWN_TCEIL_match_typecheck=1.00 \
    #       KNOWN_TFIXED_match_typecheck=0.50 sh test/diff_compiler_perf_scaling.sh
    #   exit=0                      <- the arm was never entered
    #
    # because this file assigns its ledger constants UNCONDITIONALLY
    # (`KNOWN_TCEIL_match_typecheck="4.6"`), so the env value is overwritten
    # before it is read. ⚠️ That is an asymmetry with
    # test/diff_compiler_ir_scaling.sh, whose one pair IS `${...:-}`-defaulted.
    # It is left as-is deliberately: a `:-` default on every ceiling here would
    # be a way to WIDEN a live bound from the environment, and this gate has 8
    # of them. The injection seam reaches the identical code path without adding
    # that surface — the only requirement is a stage above TIME_FLOOR, which
    # `bindings:typecheck` (139 ms) is not and `xref:typecheck` is:
    #
    #   $ PERF_ONLY=xref PERF_LEDGER_EXTRA_TIME=xref:typecheck \
    #       KNOWN_TCEIL_xref_typecheck=1.00 KNOWN_TFIXED_xref_typecheck=0.50 sh ...
    #   time typecheck: ** KNOWN-SLOW, AND GOT WORSE ** r1=2.05 r2=2.10 \
    #       (ceiling 1.00, N=2000->4000->8000)
    #   exit=1
    #
    #   $ ... KNOWN_TCEIL_xref_typecheck=9.00 KNOWN_TFIXED_xref_typecheck=3.00 sh ...
    #   time typecheck: ** PROMOTE: now scales LINEARLY ** r2=2.07 (< 3.00, N=2000->4000->8000)
    #           Remove "xref:typecheck" from KNOWN_SLOW_TIME — the bug is FIXED.
    #   exit=1
    if [ "$tworse" = "1" ]; then
      fail=$((fail+1))
      time_lines="${time_lines}           time ${st}: ** KNOWN-SLOW, AND GOT WORSE ** r1=${tr1} r2=${tr2} (ceiling ${tceil}, ${band})
"
    elif [ "$tbetter" = "1" ]; then
      fail=$((fail+1))
      time_lines="${time_lines}           time ${st}: ** PROMOTE: now scales LINEARLY ** r2=${tr2} (< ${tfixed}, ${band})
           Remove \"${shape}:${st}\" from KNOWN_SLOW_TIME — the bug is FIXED.
"
    else
      known=$((known+1))
      time_lines="${time_lines}           time ${st}: known-slow (TIME) r1=${tr1} r2=${tr2} ${band} — ledgered, alloc is blind to it
"
    fi
  elif [ "$bad" = "1" ]; then
    time_bad=1
    time_lines="${time_lines}           time ${st}: ** SUPERLINEAR (TIME) ** ${s1}s -> ${s2}s -> ${s3}s  r1=${tr1} r2=${tr2} (> ${THRESH}x, ${band})
"
  else
    time_lines="${time_lines}           time ${st}: ok  r1=${tr1} r2=${tr2} ${band} (min-of-${PERF_K}, heap pinned)
"
  fi
}

# Grade ONE stage's three OP-COUNT deltas (issue #884). Args: shape st o1 o2 o3 n1 n2 n3.
#
# Structurally MIRRORS grade_time_stage, with two deliberate differences that follow
# from the counter being deterministic:
#   * NO min-of-K / heap-pin — the caller passes a single run's numbers.
#   * NO 200ms noise floor — replaced by an ABSOLUTE-count TOOSMALL guard (OP_FLOOR),
#     the op analogue of the alloc arm's d1<1.0. A stage under it is doing too little
#     counted work to grade (not "too noisy to grade").
#
# Grades on r2 ALONE — NOT the sustained both-doublings signal TIME uses (#2173;
# the argument is in the block inside this function). Sets the
# caller's fail/known/ops_graded/op_bad/op_lines. Must be called DIRECTLY, never in a
# subshell/pipe, or the counters vanish (same rule as grade_time_stage).
grade_op_stage() {
  shape="$1"; st="$2"; o1="$3"; o2="$4"; o3="$5"; gn1="$6"; gn2="$7"; gn3="$8"
  band="N=${gn1}->${gn2}->${gn3}"

  # A stage the profiler never emitted a 5th column for is a HARNESS bug, not a pass.
  if [ -z "$o1" ] || [ -z "$o2" ] || [ -z "$o3" ]; then
    op_lines="${op_lines}           ops  ${st}: NO MEASUREMENT from the profiler (harness bug — missing op column)
"
    fail=$((fail+1))
    return
  fi

  # TOOSMALL — too few counted ops to grade (deterministic, so this is about the WORK
  # being negligible, not the reading being noisy). desugar/exhaust-guards do zero;
  # a constant handful (marksweep's resolve = 64) also lands here.
  small="$(awk -v v="$o1" -v f="$OP_FLOOR" 'BEGIN{print (v + 0 < f + 0) ? 1 : 0}')"
  if [ "$small" = "1" ]; then
    # ⚠️ BUT A LEDGERED STAGE MAY NOT SKIP (#2150). Identical in force to the rule
    # grade_time_stage already applies at its own floor, and it was MISSING here.
    # Dropping under OP_FLOOR is not an absence of signal for a KNOWN_SLOW_OPS entry —
    # it IS the signal, and the strongest form of it: the ledger asserts this row is
    # superlinear, so "too little counted work to grade" CONTRADICTS the ledger. The
    # commonest way to get here is the ledgered bug being FIXED — every #1031/#352/#242-
    # class fix converts a counted `List` scan into an uncounted OrdMap probe and drives
    # the count toward ZERO by construction — and a silent SKIP means nobody is ever told
    # to drain the row. It then sits in the ledger forever, unfalsifiable, behind a green
    # gate: a ledger that cannot notice its own bug is fixed is a skip-list, which is the
    # one thing this ratchet must not become. Caught as a NEAR-MISS in `frontend-breadth`:
    # #1017 cut `conlocal:mark` far enough to trip PROMOTE, and a slightly larger cut
    # would have landed under the floor and drained in silence instead.
    #
    # OBSERVED RED, 2026-08-28, this box, verbatim (an arm nobody has seen fail is
    # not a pin — #2160 rule 1). The ledgered row `conlocal:typecheck` was forced
    # under the floor by raising the floor, which is the only knob that reaches
    # this branch without editing the ledger:
    #
    #   $ PERF_OP_FLOOR=999999999 sh test/diff_compiler_perf_scaling.sh
    #   exit=1
    #              ops  typecheck: ** PROMOTE: now too FEW ops to grade ** 1329241 \
    #                  at N=1600 (< 999999999, N=400->800->1600)
    #              Remove "conlocal:typecheck" from KNOWN_SLOW_OPS — the counted scan is GONE.
    #
    # Before this branch existed the same run printed
    #   ops typecheck: SKIP — too few ops to grade: ...
    # and the gate exited 0.
    if is_known_ops "${shape}:${st}"; then
      fail=$((fail+1))
      op_lines="${op_lines}           ops  ${st}: ** PROMOTE: now too FEW ops to grade ** ${o3} at N=${gn3} (< ${OP_FLOOR}, ${band})
           Remove \"${shape}:${st}\" from KNOWN_SLOW_OPS — the counted scan is GONE.
           (If the scan merely moved to an UNCOUNTED primitive, the row must move to a
            different arm, not stay ledgered here where nothing can grade it.)
"
      return
    fi
    op_lines="${op_lines}           ops  ${st}: SKIP — too few ops to grade: ${o3} at N=${gn3} (< ${OP_FLOOR})
"
    return
  fi

  # A stage past the floor is genuinely graded. Record it (green must not mean "graded
  # nothing" — see ops_graded).
  ops_graded=$((ops_graded+1))

  or1="$(awk -v a="$o1" -v b="$o2" 'BEGIN{printf "%.2f", b/a}')"
  or2="$(awk -v a="$o2" -v b="$o3" 'BEGIN{printf "%.2f", b/a}')"
  # ── THE DETERMINISTIC-ARM VERDICT RULE (#2173) ───────────────────────────────
  #
  # WAS, until 2026-08-28:  bad = (r1 > T && r2 > T)
  # IS:                     bad = (r2 > T)
  #
  # The conjunct is correct on a NOISY instrument, which is where it came from: two
  # independent samples both over the line is a sustained signal, and one is not.
  # This arm is not that. Op counts come from `opBump` at exactly two primitives and
  # are a pure function of the program — a single over-threshold doubling here is a
  # FACT, not a sample. Worse, what the conjunct actually rejects is the reading
  # r1 < T < r2, a ratio that CLIMBS across the two doublings, which is the
  # signature of a superlinear term rather than of noise; a linear shape holds its
  # ratio flat. The rule was most likely to excuse exactly the shape it exists to
  # catch. Same argument, same resolution as #2100/#2063 on the Cachegrind gate,
  # which PR #2171 fixed there and not here.
  #
  # 🚨 THE TIME ARM AT grade_time_stage KEEPS THE CONJUNCT, DELIBERATELY. Wall-clock
  # on a shared box is the one arm here where a lone high ratio really can be a
  # scheduling step. Do not "unify" the two — the instruments differ, so the rules
  # differ.
  #
  # WHAT THIS NEWLY REDDENS, MEASURED — not argued. Every graded row of every unit
  # was harvested from a per-unit run of THIS gate on this box, 2026-08-28
  # (`PERF_ONLY=<unit>`, QUICK and DEEP). Exactly TWO rows have r2 > 3.0 with
  # r1 <= 3.0, and both are `elaborate`:
  #
  # manyifaces:elaborate   r1=2.52  r2=3.04   (N=250->500->1000)
  # conlocal:elaborate     r1=2.78  r2=3.21   (N=400->800->1600)
  #
  # Every other graded op row in the file reads r2 <= 2.20 except the already
  # ledgered conlocal:typecheck (r1=3.44 r2=3.78, #2030). Both new rows were ledgered
  # below against measured ceilings — see KNOWN_SLOW_OPS.
  #
  # ⚠️ THAT IS A 2026-08-28 SNAPSHOT, NOT THE CURRENT LEDGER. #2189 has since been
  # localised and half-drained: `manyifaces:elaborate` is FIXED and its row is gone
  # (r2=1.66), `conlocal:elaborate` remains, now attributed to #2030's localPinPairs.
  # Derive the live set from KNOWN_SLOW_OPS below, never from this paragraph.
  bad="$(awk -v r2="$or2" -v th="$THRESH" 'BEGIN{print (r2 > th) ? 1 : 0}')"

  if is_known_ops "${shape}:${st}"; then
    lk="$(printf '%s_%s' "$shape" "$st" | tr -c 'a-zA-Z0-9_' '_')"
    # `:-` under `set -u` (:109) — same hazard as the TIME arm above, reached by
    # PERF_LEDGER_EXTRA_OPS and by the ordinary mistake of adding a
    # KNOWN_SLOW_OPS row without its ceiling pair.
    #
    # OBSERVED RED, 2026-08-28, this box, verbatim (#2160 rule 1):
    #
    #   $ PERF_LEDGER_EXTRA_OPS="xref:typecheck" sh test/diff_compiler_perf_scaling.sh
    #   ## LEDGER INJECTION ACTIVE — this run's verdicts are NOT a grading result. ##
    #              ops  typecheck: ** MALFORMED LEDGER ROW ** no KNOWN_OCEIL_xref_typecheck / KNOWN_OFIXED_xref_typecheck pair.
    #              A ledger row without both halves cannot drain itself — that is a skip-list, not a pin.
    #   exit=1
    #
    # ⚠️ These two branches were UNGUARDED in the first draft of this PR, whose
    # commit message claimed "all eval sites now use `:-`". They were found by an
    # independent review, not by me, and not by CI — CI was 15/15 green with the
    # hole open, because nothing in the tree sets the injection seams. That is the
    # argument for rule 1 in miniature: a green suite says nothing about an arm no
    # one has driven.
    # OBSERVED RED, the other two OPS-ledger arms (#2160 phase 2, this box):
    #
    #   $ PERF_ONLY=bindings PERF_LEDGER_EXTRA_OPS=bindings:typecheck \
    #       KNOWN_OCEIL_bindings_typecheck=1.00 KNOWN_OFIXED_bindings_typecheck=0.50 sh ...
    #   ops typecheck: ** KNOWN-SLOW (OPS), AND GOT WORSE ** r1=1.20 r2=1.33 \
    #       (ceiling 1.00, N=250->500->1000)
    #   exit=1
    #
    #   $ ... KNOWN_OCEIL_bindings_typecheck=9.00 KNOWN_OFIXED_bindings_typecheck=3.00 sh ...
    #   ops typecheck: ** PROMOTE: now scales LINEARLY ** r2=1.33 (< 3.00, N=250->500->1000)
    #           Remove "bindings:typecheck" from KNOWN_SLOW_OPS — the op quadratic is FIXED.
    #   exit=1
    eval "oceil=\${KNOWN_OCEIL_$lk:-}"
    eval "ofixed=\${KNOWN_OFIXED_$lk:-}"
    if [ -z "$oceil" ] || [ -z "$ofixed" ]; then
      fail=$((fail+1))
      op_lines="${op_lines}           ops  ${st}: ** MALFORMED LEDGER ROW ** no KNOWN_OCEIL_${lk} / KNOWN_OFIXED_${lk} pair.
           A ledger row without both halves cannot drain itself — that is a skip-list, not a pin.
"
      return
    fi
    oworse="$(awk -v r="$or2" -v c="$oceil" 'BEGIN{print (r > c) ? 1 : 0}')"
    obetter="$(awk -v r="$or2" -v f="$ofixed" 'BEGIN{print (r < f) ? 1 : 0}')"
    if [ "$oworse" = "1" ]; then
      fail=$((fail+1))
      op_lines="${op_lines}           ops  ${st}: ** KNOWN-SLOW (OPS), AND GOT WORSE ** r1=${or1} r2=${or2} (ceiling ${oceil}, ${band})
"
    elif [ "$obetter" = "1" ]; then
      fail=$((fail+1))
      op_lines="${op_lines}           ops  ${st}: ** PROMOTE: now scales LINEARLY ** r2=${or2} (< ${ofixed}, ${band})
           Remove \"${shape}:${st}\" from KNOWN_SLOW_OPS — the op quadratic is FIXED.
"
    else
      known=$((known+1))
      op_lines="${op_lines}           ops  ${st}: known-slow (OPS) r1=${or1} r2=${or2} ${band} — ledgered; TIME+ALLOC are blind to it
"
    fi
  elif [ "$bad" = "1" ]; then
    op_bad=1
    op_lines="${op_lines}           ops  ${st}: ** SUPERLINEAR (OPS) ** ${o1} -> ${o2} -> ${o3}  r1=${or1} r2=${or2} (> ${THRESH}x, ${band})
"
  else
    op_lines="${op_lines}           ops  ${st}: ok  r1=${or1} r2=${or2} ${band} (deterministic, single run — no floor/min-of-K/heap-pin)
"
  fi
}

# Grade the `wasm-emit` row for the shapes where it MEANS something, and only those.
# Args: shape n1 n2 n3 (the shape's own band, for the shapes that ride the main pass).
#
# ⚠️ WHICH SHAPES, AND WHY IT IS NOT "ALL OF THEM": wasm_emit renders the whole live
# prelude to WAT at ~0.24 s / ~242 MB no matter how small the target. On the dead-`main`
# shapes (bindings/listlit/nesting/comments/manydefs) DCE prunes every synthetic decl, so
# the stage times THE PRELUDE AND NOTHING ELSE and prints a flat `ok r1≈1.0 r2≈1.0` —
# measured 1.09/1.01, 0.98/1.17, 1.01/0.96. THAT "ok" IS NOT BACKEND COVERAGE; it is a
# constant being constant, and it cost 27% of every run's wall and 38% of its allocation
# to learn nothing. Those shapes now never run the stage at all (MEDAKA_PERF_WASM unset).
#
# The two that carry real signal:
#   match — the #381 CUBIC's exact shape (ctor-switch emission). #401 fixed it 53x; this
#           row reading r2≈1.05-1.09 is what keeps the fix fixed. Rides the main pass:
#           its band IS the shape's band, and at N<=1000 the stage is ~0.3 s.
#   xref  — the ledgered quadratic, on its OWN SMALLER BAND. See below.
grade_wasm_row() {
  shape="$1"; n1="$2"; n2="$3"; n3="$4"
  case "$shape" in
    match)
      # Rode the main pass (main_wasm=1), so the rows are already in TF1/TF2/TF3.
      grade_time_stage "$shape" wasm-emit \
        "$(awk '$1=="wasm-emit"{print $2}' "$TF1")" \
        "$(awk '$1=="wasm-emit"{print $2}' "$TF2")" \
        "$(awk '$1=="wasm-emit"{print $2}' "$TF3")" \
        "$n1" "$n2" "$n3"
      ;;
    xref)
      # QUICK: the shape's band already IS the wasm band, so the row rode the main pass
      # (main_wasm=1) and there is nothing extra to run. This is why QUICK is cheap: the
      # dedicated pass below exists only to spare DEEP the N=16000 wasm sample.
      if [ "$XREF_N" = "$XREF_WASM_N" ]; then
        grade_time_stage "$shape" wasm-emit \
          "$(awk '$1=="wasm-emit"{print $2}' "$TF1")" \
          "$(awk '$1=="wasm-emit"{print $2}' "$TF2")" \
          "$(awk '$1=="wasm-emit"{print $2}' "$TF3")" \
          "$n1" "$n2" "$n3"
        return
      fi
      # DEEP: A DEDICATED PASS AT A SMALLER BAND — the single biggest cost lever here.
      #
      # xref's band is sized for `resolve`, which only clears the 200ms floor at
      # N=16000. wasm_emit is ~10x llvm_emit, so riding that band cost 42 s per run x
      # K=5 = ~211 s for ONE row, and made `gates (types)` the CI critical path at 12
      # min against engines' 3.7. At 2000/4000/8000 the same curve reads ~1.0/2.8/10.4 s
      # — the largest still 50x the floor — for ~14 s per round instead of ~55 s.
      #
      # ⚠️ THE LEDGER'S CEILING BELONGS TO THIS BAND. r2 here is the OLD band's r1 (both
      # are the 4000->8000 doubling), which is why the recorded band moved 3.87-4.15 ->
      # ~3.7-3.8 rather than collapsing: it is the same curve, resampled. Re-derive
      # KNOWN_TCEIL/TFIXED_xref_wasm_emit against THIS band if you move XREF_WASM_N, and
      # do not compare a number from here to one from the old band.
      wn1="$XREF_WASM_N"; wn2=$((wn1 * 2)); wn3=$((wn1 * 4))
      wf1="$WORK/${shape}_$wn1.mdk"; wf2="$WORK/${shape}_$wn2.mdk"; wf3="$WORK/${shape}_$wn3.mdk"
      # 4000/8000 already exist from the main pass (same generator, same deterministic
      # name); only the 2000 fixture is new. Regenerating is harmless, just wasted.
      [ -f "$wf1" ] || "gen_$shape" "$wn1" "$wf1"
      [ -f "$wf2" ] || "gen_$shape" "$wn2" "$wf2"
      [ -f "$wf3" ] || "gen_$shape" "$wn3" "$wf3"
      WW1="$WORK/${shape}_w1"; WW2="$WORK/${shape}_w2"; WW3="$WORK/${shape}_w3"
      stage_times_min "$wf1" "$PERF_K" 1 | sort > "$WW1"
      stage_times_min "$wf2" "$PERF_K" 1 | sort > "$WW2"
      stage_times_min "$wf3" "$PERF_K" 1 | sort > "$WW3"
      grade_time_stage "$shape" wasm-emit \
        "$(awk '$1=="wasm-emit"{print $2}' "$WW1")" \
        "$(awk '$1=="wasm-emit"{print $2}' "$WW2")" \
        "$(awk '$1=="wasm-emit"{print $2}' "$WW3")" \
        "$wn1" "$wn2" "$wn3"
      ;;
  esac
}

printf '%-10s %8s %10s %10s %10s  %6s %6s  %s\n' \
  shape N 'net-N' 'net-2N' 'net-4N' 'r1' 'r2' verdict
printf -- '-------------------------------------------------------------------------------\n'

# ⚠️ MEASURE THREE SIZES, NOT TWO — a single doubling is not enough.
#
# This gate originally sampled N and 2N and gated on that one ratio. It would have
# MISSED the very bug it later found. At N=250 the (then-quadratic) `match` shape read
# 2.76x — UNDER the 3.0 threshold — and would have passed. It was only caught because
# someone hand-probed three doublings and saw the ratio CLIMB:
#
#     N=125->250  2.48x        N=250->500  2.75x        N=500->1000  3.10x
#
# THE SIGNAL FOR A QUADRATIC IS THE RATIO CLIMBING, not any single ratio. At small N a
# quadratic is still diluted by linear terms and constant factors; a single sample near
# the noise floor cannot distinguish n^1.4 from n^2.
#
# So: sample N, 2N, 4N. Gate on **r2** (the 2N->4N doubling) — it is the least
# contaminated by the constant term. Also flag a CLIMBING trend (r2 meaningfully above
# r1) even when r2 is still under the ceiling, because that is a quadratic caught early,
# while it is small.
#
# ── clause_of: NAME THE CLAUSE THAT FIRED (#1879 -> #2151) ────────────────────
#
# Every `QUADRATIC` verdict in this file is the SAME DISJUNCTION — `r2 > THRESH` OR
# `climbing` — so the failure text must say which half tripped or it is a label rather
# than a measurement. #1879 failed on the CLIMBING clause at r1~2.1 r2~2.67, comfortably
# BELOW 3.0, and the message told its reader it had exceeded 3.0x; they went looking for
# a 3x regression that did not exist. Two sites were corrected in place by #1879's own
# sprint and SIX carried the bare message until #2151; this helper exists so there is ONE
# copy of the wording and the next site cannot drift from it.
#
# Every awk verdict below emits a trailing `why` field ("threshold" / "climbing" / "-");
# this maps it to the human clause. It is deliberately total: an unrecognised why (only
# reachable if a verdict block forgets the field) reads as the climbing clause's text
# rather than crashing, and the ratios printed alongside always disambiguate.
#
# Args: <why> [threshold]. The threshold defaults to $THRESH but MUST be passed at the
# rows that grade against their own ceiling (WD_THRESH, LD_THRESH) — printing the shared
# 3.0 next to a row graded at 2.6 would be the same lie in a new place.
clause_of() {
  if [ "${1:-}" = "threshold" ]; then
    printf 'r2 > %sx' "${2:-$THRESH}"
  else
    printf 'climbing: r2 > r1 x %s AND r2 > %s' "$PERF_CLIMB_R" "$PERF_CLIMB_MIN"
  fi
}

# ── SELF-CHECK, and why the CLIMBING arm needs one ────────────────────────────
#
# The threshold arm is observable end-to-end from outside: drop PERF_THRESH and every
# shape trips it (the record below).
#
# The CLIMBING arm USED to have no such knob — it fires only when `r2 > r1*1.15 AND
# r2 > 2.45 AND r2 <= THRESH`, and until #2160 phase 2 no environment variable moved
# those two constants, so it could not be DRIVEN. PERF_CLIMB_R / PERF_CLIMB_MIN now
# move them, CLAMPED so they may only be LOWERED (raising either exits 1 — widening a
# threshold to reach green is [W-QUIETER], and a deliberate-red knob that can also
# hide a real red is not a debugging aid, it is a loophole).
#
# This self-check still exists, and still costs microseconds: it asserts that the
# clause TEXT names the clause and the two live values, so an edit that loses either
# fails the gate at startup rather than at some unknown later red. It compares against
# the knobs rather than against literals — see the sweep record below for why: the
# printf used to transcribe 1.15/2.45 unconditionally and so LIED about the rule it
# had just applied whenever the knobs were set.
#
# ⚠️ AN EARLIER DRAFT OF THIS COMMENT SAID THE CLIMBING ARM WAS UNREACHABLE AND
# THEREFORE UNGRADED — "a hole reported". THAT WAS WRONG, and the correction came from
# running the gate rather than reading it. It cannot be driven ON DEMAND; it is reached
# in normal operation, by the `modules` shape's per-stage TIME arm, whose wall-clock
# ratios are not pinned to ~2.0 the way the deterministic arms are. Observed here
# 2026-08-28 in an ordinary `make preflight`, verbatim:
#
#   time typecheck: ** SUPERLINEAR (TIME) ** 0.272676944732666s -> 0.5733699798583984s
#       -> 1.5150041580200195s  r1=2.10 r2=2.64 (climbing: r2 > r1 x 1.15 AND r2 > 2.45)
#
# That IS #2151, closed on its own terms and by the exact case that motivated it: this
# row is #1879, and before this change the same failure printed a bare "** SUPERLINEAR
# (TIME) **" whose reader was left to infer a 3.0x threshold breach that never happened
# (r2 = 2.64). The clause is now named in the line that reports it.
#
# 🚨 THE SENTENCE THAT USED TO STAND HERE WAS FALSE, and it cost two PRs. It said #1879
# was "a property of this box ... while CI passes on the same commit", and told you to
# re-run or re-enqueue. CI does NOT pass on it: the merge queue reads r2 = 2.77 and 3.21,
# the same band this box reads, and bounced PR #2245 three times and PR #2260 once. That
# row is now LEDGERED (KNOWN_SLOW_TIME, "modules:typecheck") against a measured band, so
# it no longer reds in-band and no longer hides worsening either. The fix is still
# #1879's, not yours.
_cc_t="$(clause_of threshold 3.0)"; _cc_c="$(clause_of climbing)"
case "$_cc_t" in
  *'r2 > 3.0x'*) ;;
  *) echo "FAIL: clause_of lost the THRESHOLD clause wording — got [$_cc_t]"; exit 1 ;;
esac
case "$_cc_c" in
  *climbing*"$PERF_CLIMB_R"*"$PERF_CLIMB_MIN"*) ;;
  *) echo "FAIL: clause_of lost the CLIMBING clause wording — got [$_cc_c]"; exit 1 ;;
esac
[ "$_cc_t" != "$_cc_c" ] || { echo "FAIL: clause_of returns the same text for both clauses"; exit 1; }
unset _cc_t _cc_c

# ── OBSERVED RED, 2026-08-28, this box (#2160 rule 1) ────────────────────────
#
# The threshold clause, end to end, through every one of the six printfs that
# previously emitted a bare "** SUPERLINEAR **" with no clause. Verbatim excerpt:
#
#   $ PERF_THRESH=1.2 sh test/diff_compiler_perf_scaling.sh
#   exit=1
#   bindings  250  121.0 MB  245.0 MB  495.6 MB  2.03  2.02  ** SUPERLINEAR (ALLOC) ** (r2 > 1.2x)
#              time elaborate: ** SUPERLINEAR (TIME) ** 0.145…s -> 0.195…s -> 0.294…s \
#                  r1=1.34 r2=1.50 (> 1.2x, N=250->500->1000)
#              ops  elaborate: ** SUPERLINEAR (OPS) ** 349274 -> 442524 -> 629024 \
#                  r1=1.27 r2=1.42 (> 1.2x, N=250->500->1000)
#   match     250   69.9 MB  144.5 MB  307.1 MB  2.07  2.13  ** SUPERLINEAR (ALLOC) ** (r2 > 1.2x)
#   xref     2000 1182.4 MB 2408.1 MB 4901.0 MB  2.04  2.04  ** SUPERLINEAR (ALLOC) ** (r2 > 1.2x)
#
# Before this change every one of those lines ended at "** SUPERLINEAR (ALLOC) **"
# and the reader had to re-derive which half of the disjunction had fired.
#
# ── OBSERVED RED: THE CLIMBING CLAUSE, ON DEMAND (#2160 phase 2) ─────────────
#
# The paragraph that stood here said this clause "HAS NO SUCH RECORD, AND CANNOT
# HAVE ONE HERE". Both halves are now false, and both were falsified by running
# the gate rather than by reading it.
#
# Not-cannot, part 1 — it is reached in ORDINARY operation, no knobs at all, by
# the `modules` shape's TIME arm (that is the transcript in the self-check block
# above, and it is #1879, an OPEN issue about this box; do not read it as a
# regression).
#
# Not-cannot, part 2 — it is now drivable ON DEMAND on the ALLOC arm too, with the
# lower-only knobs, so the clause can be exercised against a shape whose ratios are
# deterministic instead of waiting for a flaky wall-clock row:
#
#   $ PERF_ONLY=nesting PERF_THRESH=9 PERF_CLIMB_R=1.00 PERF_CLIMB_MIN=0.10 \
#       sh test/diff_compiler_perf_scaling.sh
#   nesting  250  58.1 MB  120.1 MB  256.8 MB  2.07  2.14  ** SUPERLINEAR (ALLOC) ** \
#       (climbing: r2 > r1 x 1.00 AND r2 > 0.10)
#   exit=1
#
# ⚠️ Note what PERF_THRESH=9 is doing: it RAISES the threshold arm out of the way so
# the disjunction's OTHER half is the one observed. That is the only way to prove the
# climbing arm fires by itself, and it is safe here precisely because it makes the
# gate laxer only for this narrowed, deliberately-red run — never in CI, where the
# variable is unset (`grep -rn PERF_THRESH .github Makefile` finds nothing).
#
# 🚨 AND THE SWEEP FOUND A DEFECT DOING IT. The first run of the above printed
# "(climbing: r2 > r1 x 1.15 AND r2 > 2.45)" — the DEFAULTS — while having actually
# applied 1.00/0.10. clause_of transcribed literals. A verdict line that misreports
# the rule it applied is the exact failure class #2160 exists for, so it is fixed
# above rather than noted: the printf now interpolates the live knobs, and the
# startup self-check compares against those knobs too.
# `manydefs` is DEEP-only: its band exists solely to lift `lint` over the floor (0.62 s
# at 16000), and nothing else in the shape needs 16000. QUICK announces the omission
# rather than quietly running a smaller set — a gate that narrows its own scope in
# silence reads as full coverage, which is the failure this suite is built against.
# `marksweep` (issue #884) is the op arm's money-shot: it grades `mark`, which every
# other shape leaves under the 200ms TIME_FLOOR so the TIME arm never grades it. It runs
# at the default N and is OP-ONLY — its TIME min-of-K arm is skipped (it exists FOR the
# op arm, and `mark` is under the floor on every shape anyway), so per-PR it costs only
# the 3 shared deterministic runs. That every other shape's rows show `time mark: SKIP`
# is the standing proof that TIME grades `mark` nowhere.
# `manyifaces` / `widerecords` (issue #883) are OP-ONLY single-file shapes, run at the
# default N band. `manyifaces` co-scales N interfaces AND N reference sites to catch
# mark's `contains x methods` List-as-set quadratic (manyifaces:mark #953) and the
# independent manyifaces:resolve (#954) it surfaced — both FIXED, no longer ledgered;
# `widerecords` is the record shape — a LINEAR resolve-op regression guard whose
# `ownersOf` target is now COUNTED and O(log N) indexed (#984), so a reintroduced
# per-mention scan turns it superlinear (see gen_widerecords).
# `conlocal` (issue #2030 / #2143) is the third OP-ONLY single-file shape, at its OWN
# band (400/1600 — see CONLOCAL_N). It remains the op arm's money-shot for `typecheck`
# (#2030, still open — graded by NO other arm at an affordable band on this shape: TIME
# reads 2.56/2.78 and total alloc reads 2.57/2.89). `mark` (#2143) was ALSO pinned here
# until this same slice's #1017 marker.mdk fix drained it as a side effect (now watch-
# only, reads linear). Its ~13 s is the whole reason #2030's pin is here and not on the
# callgrind Ir gate, which needs 415 s for the same verdict.
SHAPES="bindings match listlit nesting xref comments marksweep manyifaces widerecords typos consfam conlocal guardwild"
if [ "$PERF_DEEP" = "1" ]; then
  SHAPES="$SHAPES manydefs nestedparens"
else
  echo "NOTE: QUICK mode (PERF_DEEP=0). Reduced scope, on purpose:"
  echo "  * manydefs SKIPPED entirely — the per-file lint tier's O(defs^2) detector."
  echo "  * nestedparens SKIPPED entirely — #164's parse-superlinearity detector, ~3 min"
  echo "      of K=5 runs at N=16000 (see NESTEDPARENS_N); DEEP/nightly only, [G14]."
  echo "  * xref at N=${XREF_N} (-> $((XREF_N * 4))) instead of 4000 (-> 16000):"
  echo "      emit + wasm-emit still graded and ledgered (both >> the floor at 4N);"
  echo "      resolve drops under the 200ms floor and SKIPs — the #78 detector."
  echo "  These run in nightly.yml. Locally: PERF_DEEP=1 sh test/diff_compiler_perf_scaling.sh"
fi

for shape in $SHAPES; do
  want "$shape" || continue   # PERF_ONLY unit: one per shape
  case "$shape" in
    xref)       base_n="$XREF_N" ;;
    comments)   base_n="$COMMENTS_N" ;;
    manydefs)   base_n="$MANYDEFS_N" ;;
    manyifaces) base_n="$MANYIFACES_N" ;;
    widerecords) base_n="$WIDERECORDS_N" ;;
    consfam)    base_n="$CONSFAM_N" ;;
    conlocal)   base_n="$CONLOCAL_N" ;;
    guardwild)  base_n="$GUARDWILD_N" ;;
    nestedparens) base_n="$NESTEDPARENS_N" ;;
    *)          base_n="$N" ;;
  esac
  n1="$base_n"; n2=$((base_n * 2)); n3=$((base_n * 4))
  f1="$WORK/${shape}_$n1.mdk"; f2="$WORK/${shape}_$n2.mdk"; f3="$WORK/${shape}_$n3.mdk"
  "gen_$shape" "$n1" "$f1"
  "gen_$shape" "$n2" "$f2"
  "gen_$shape" "$n3" "$f3"

  # ONE deterministic wasm-off run per size, saved whole — it feeds BOTH the alloc arm
  # (total line) and the op arm (per-stage 5th column). The op arm makes NO run of its
  # own (issue #884 cost fix); the command is identical to alloc_of's, so the alloc
  # numbers below are byte-unchanged by the sharing.
  R1="$WORK/${shape}_run1"; R2="$WORK/${shape}_run2"; R3="$WORK/${shape}_run3"
  profile_run "$f1" > "$R1"; profile_run "$f2" > "$R2"; profile_run "$f3" > "$R3"
  a1="$(alloc_from "$R1")"; a2="$(alloc_from "$R2")"; a3="$(alloc_from "$R3")"

  # A shape that produces no measurement is a HARNESS failure, not a pass. Never
  # let "I could not measure it" read as "it is fine" — that is the silent-green
  # bug class this whole suite was hardened against.
  case "$a1$a2$a3" in
    *[!0-9.]*|"") echo "FAIL $shape: profiler produced no allocation figure (harness bug)"; fail=$((fail+1)); continue ;;
  esac

  # ── TIME verdict: PER STAGE, heap-pinned, min-of-K, floor-guarded ──────────
  # Computed BEFORE the allocation branch below so it can promote an allocation
  # "ok" to a failure — never the reverse.
  time_bad=0
  time_lines=""
  # ⚠️ OP-ONLY shapes skip the TIME min-of-K arm (issue #884 cost fix). `marksweep`
  # (#884) and `manyifaces`/`widerecords` (#883) all grade a stage — `mark`/`resolve` —
  # that sits UNDER the 200ms floor at their bands, so the TIME arm would grade nothing
  # while paying ~K timing runs per size. Their op grading rides the 3 shared
  # deterministic runs above, so each costs 3 runs, not 3 + 3*K. Every OTHER shape still
  # runs the full TIME arm.
  #
  # ⚠️ `conlocal` (#2030) is OP-ONLY for a DIFFERENT reason, and the difference matters
  # if anyone reconsiders it: one of its two pinned stages (`mark`) is under the floor
  # as usual, but the other (`typecheck`) is comfortably OVER it — 1.45 s at N=1600 —
  # and TIME still grades it 2.56/2.78, i.e. UNDER threshold. So the TIME arm here would
  # not be blind, it would be WRONG-BANDED: it would cost ~13 s x K and certify as `ok`
  # the very row the op arm ledgers. Sizing the band for TIME instead means N>=3200,
  # where one profiler run alone is 43 s. OP-ONLY is the cheap AND the correct answer.
  case "$shape" in
    marksweep|manyifaces|widerecords|typos)
    time_lines="           time: (OP-ONLY shape — TIME min-of-K arm skipped, #883/#884 cost fix. its graded stage is under the ${TIME_FLOOR}s floor at this band, so TIME grades it nowhere; the op arm below is its coverage.)
"
    ;;
    conlocal)
    time_lines="           time: (OP-ONLY shape — TIME min-of-K arm skipped, #2030. \`mark\` is under the ${TIME_FLOOR}s floor as usual; \`typecheck\` is OVER it here yet still reads r1 2.56 r2 2.78 at this band, i.e. TIME would certify as ok the row the op arm ledgers. The op arm below is this shape's only correct arm.)
"
    ;;
    guardwild)
    # ⚠️ ALLOC-ONLY, and for a THIRD reason again — neither #883/#884's "the graded
    # stage is under the floor" nor #2030's "TIME is over the floor but wrong-banded".
    # Here the TIME arm is over the floor on exactly ONE stage and it is REDUNDANT AND
    # UNSTABLE. MEASURED at the shipped band (min-of-5, heap pinned), every other stage
    # SKIPs under the 200ms floor and `emit` reads r1=2.73 r2=4.19 — which the TIME
    # rule (`r1 > 3.0 && r2 > 3.0`, both doublings) reports as `ok`. So the arm costs
    # 3 x ${PERF_K} profiler runs (~22 s at this band, five times the shape's whole
    # ALLOC cost) to print one number that (a) grades a quadratic as fine today and (b)
    # flips the shape red with no ledger row the moment `emit`'s r1 drifts past 3.0.
    # The SAME Θ(N²) is graded deterministically by the ALLOC ledger row below
    # (KNOWN_CEIL_guardwild) and per-stage, on `lower` itself, by
    # test/diff_compiler_stage_ir_scaling.sh's callgrind Ir arm (`guardwild:lower`).
    # Two correct arms already hold this shape; a third that is wrong-ruled is a flap
    # source, not coverage.
    time_lines="           time: (ALLOC-ONLY shape — TIME min-of-K arm skipped, #2125. Every stage but \`emit\` is under the ${TIME_FLOOR}s floor at this band, and \`emit\`'s r1=2.73 r2=4.19 reads \`ok\` under the both-doublings TIME rule while the ALLOC ledger row and stage_ir_scaling's \`guardwild:lower\` Ir row both grade the same quadratic. See the case arm in this file for the full reasoning.)
"
    ;;
    *)
    # These are written to files rather than shell vars because there is one line
    # per stage per size and sh has no arrays.
    TF1="$WORK/${shape}_t1"; TF2="$WORK/${shape}_t2"; TF3="$WORK/${shape}_t3"
    # `match` is the ONLY shape whose wasm row rides the main pass — its band is the
    # shape's band and the stage is ~0.3 s there. Every other shape runs the main pass
    # with wasm OFF: xref grades it on its own smaller band (grade_wasm_row), and the
    # rest do not grade it at all because on them it only ever times the prelude.
    # A shape's wasm row rides the main pass when its own band IS the wasm band —
    # `match` always (250/500/1000), and `xref` in QUICK, where XREF_N == XREF_WASM_N.
    # In DEEP, xref's band is resolve's, so its wasm row needs the separate smaller-band
    # pass instead (grade_wasm_row).
    case "$shape" in
      match) main_wasm=1 ;;
      xref)  [ "$XREF_N" = "$XREF_WASM_N" ] && main_wasm=1 || main_wasm=0 ;;
      *)     main_wasm=0 ;;
    esac
    stage_times_min "$f1" "$PERF_K" "$main_wasm" | sort > "$TF1"
    stage_times_min "$f2" "$PERF_K" "$main_wasm" | sort > "$TF2"
    stage_times_min "$f3" "$PERF_K" "$main_wasm" | sort > "$TF3"
    for st in $TIME_STAGES; do
      grade_time_stage "$shape" "$st" \
        "$(awk -v s="$st" '$1==s{print $2}' "$TF1")" \
        "$(awk -v s="$st" '$1==s{print $2}' "$TF2")" \
        "$(awk -v s="$st" '$1==s{print $2}' "$TF3")" \
        "$n1" "$n2" "$n3"
    done
    grade_wasm_row "$shape" "$n1" "$n2" "$n3"
    ;;
  esac

  # ── OP verdict: PER STAGE, deterministic — reads the op column of the shared runs
  # (issue #884). No min-of-K, no heap pin, no floor (the op counter is noise-free).
  # Computed alongside TIME so it, too, can only PROMOTE an allocation "ok" to a
  # failure, never downgrade one (the SUPERLINEAR (OPS) branch below sits after the
  # alloc and time failures).
  OF1="$WORK/${shape}_op1"; OF2="$WORK/${shape}_op2"; OF3="$WORK/${shape}_op3"
  ops_from "$R1" | sort > "$OF1"
  ops_from "$R2" | sort > "$OF2"
  ops_from "$R3" | sort > "$OF3"
  op_bad=0
  op_lines=""
  for st in $OP_STAGES; do
    grade_op_stage "$shape" "$st" \
      "$(awk -v s="$st" '$1==s{print $2}' "$OF1")" \
      "$(awk -v s="$st" '$1==s{print $2}' "$OF2")" \
      "$(awk -v s="$st" '$1==s{print $2}' "$OF3")" \
      "$n1" "$n2" "$n3"
  done

  # ── typos: assert the did-you-mean search actually RAN (#1016) ───────────────
  # This is the only shape here whose signal comes from a DIAGNOSTIC, and a diagnostic
  # is exactly what a fixture can silently stop producing: ONE generated name colliding
  # with a reserved word makes the file a parse error, resolve never reaches the fuzzy
  # search, and every ratio above reads a clean and meaningless "ok". `scoreCand` bumps
  # the op counter once per Levenshtein scoring, and each of the N typos is one edit
  # from BOTH its `d` and its `e` twin, so a run that really produced N diagnostics
  # cannot come in under (the ~2N-decl walk baseline) + N. Under that is a HARNESS
  # FAILURE, never a pass — the same "a gate that measured nothing must not read green"
  # rule as the alloc-figure guard above.
  if [ "$shape" = "typos" ]; then
    ty_o1="$(awk '$1=="resolve"{print $2}' "$OF1")"
    ty_min=$((3 * n1))
    if [ "$(awk -v v="${ty_o1:-0}" -v m="$ty_min" 'BEGIN{print (v + 0 < m + 0) ? 1 : 0}')" = "1" ]; then
      echo "FAIL typos: resolve op ${ty_o1:-<none>} at N=${n1} is under 3N (${ty_min}) — the"
      echo "     did-you-mean search did not run, so the ratios above measured NOTHING."
      echo "     Most likely the fixture is a parse error (reserved-word collision): see gen_typos."
      fail=$((fail+1))
      continue
    fi
  fi

  # ── widerecords resolve-op grade (#883 PR review; #78 P-1 rework; #984) ───────
  # widerecords is a `resolve` op regression-guard, and that reading is the ONLY thing
  # it grades. Its counted resolve signal since #984 is the record-resolution
  # `contains owner owners` (fieldVerdict, 3N) PLUS one `opBump` per `ownersOf` index
  # probe (2N) = 5N+1, LINEAR — 1251 at N=250, now OVER OP_FLOOR (grade_op_stage above
  # ALSO grades it now; this dedicated block is the resolve-specific ratio guard + the
  # dead-profiler check). Before #984 `ownersOf` was a hand-rolled uncounted scan and the
  # signal was just 3N+1 = 751 (UNDER the floor, graded only here); it was even higher
  # pre-#78 (~2783, of which ~2032 was the incidental local-scope `contains n scope` this
  # same walk ran per reference, drained by #78 P-1 to O(log n) `omHasKey`).
  #
  # This is a GENUINE ownersOf quadratic detector: #984 both indexed the lookup (O(log N),
  # resolve TIME now linear) and made the probe COUNTED, so a regression back to a
  # per-mention scan of the (field,owner) multimap — counted per pair — lifts resolve op
  # to O(N^2) and the ratio below trips (verified: reverting #984's index reads r~4.0).
  # A regression where `ownersOf` returns a superlinear owners list also trips it.
  #
  # Grade the resolve op as a DETERMINISTIC RATIO here. On the LINEAR (pass) path we fall
  # through to the ALLOC arm exactly as before; we only `continue` (skip alloc) on a fail.
  # Narrow: widerecords' resolve reading only.
  if [ "$shape" = "widerecords" ]; then
    wr_ro1="$(awk '$1=="resolve"{print $2}' "$OF1")"
    wr_ro2="$(awk '$1=="resolve"{print $2}' "$OF2")"
    wr_ro3="$(awk '$1=="resolve"{print $2}' "$OF3")"
    if [ -z "$wr_ro1" ] || [ -z "$wr_ro2" ] || [ -z "$wr_ro3" ] \
       || [ "$(awk -v v="${wr_ro1:-0}" 'BEGIN{print (v+0 <= 0)?1:0}')" = "1" ]; then
      # zero / missing = nothing measured (dead profiler), never "linear"
      fail=$((fail+1))
      printf '%-10s %8s  ** NO RESOLVE-OP MEASUREMENT (0 or missing — harness/profiler bug) **\n' \
        "$shape" "$n1"
      continue
    fi
    wr_r1="$(awk -v a="$wr_ro1" -v b="$wr_ro2" 'BEGIN{printf "%.2f", b/a}')"
    wr_r2="$(awk -v a="$wr_ro2" -v b="$wr_ro3" 'BEGIN{printf "%.2f", b/a}')"
    # r2 alone — the deterministic-arm rule (#2173); see grade_op_stage.
    # ⚠️ #2173's enumeration named three sites (grade_op_stage and what it called
    # "the two grade_emittables_stage ALLOC verdicts"). It was wrong twice: there
    # are FOUR conjuncts on deterministic instruments in this file, this
    # widerecords resolve-op ratio being the one it missed, and neither of the
    # other two grades ALLOCATION — both are emit-stage OP counts. Fixed as a set,
    # since half a flip is a rule a reader cannot state.
    if [ "$(awk -v r2="$wr_r2" -v th="$THRESH" 'BEGIN{print (r2>th)?1:0}')" = "1" ]; then
      fail=$((fail+1))
      printf '%-10s %8s  ** SUPERLINEAR (OPS) record-resolution path ** resolve-op %s -> %s -> %s  r1=%s r2=%s (> %sx, band N=%s->%s->%s)\n' \
        "$shape" "$n1" "$wr_ro1" "$wr_ro2" "$wr_ro3" "$wr_r1" "$wr_r2" "$THRESH" "$n1" "$n2" "$n3"
      continue
    fi
    ops_graded=$((ops_graded+1))
    printf '%-10s %8s  resolve-ops %s -> %s -> %s  r1=%s r2=%s  (LINEAR — ownersOf indexed+counted (#984) + record-resolution `contains owner owners` held, band N=%s->%s->%s)\n' \
      "$shape" "$n1" "$wr_ro1" "$wr_ro2" "$wr_ro3" "$wr_r1" "$wr_r2" "$n1" "$n2" "$n3"
  fi

  # Subtract the fixed prelude cost — see the BASELINE note above. Without this the
  # gate is blind.
  verdict="$(awk -v a1="$a1" -v a2="$a2" -v a3="$a3" -v b="$BASE_ALLOC" -v th="$THRESH" -v cr="$PERF_CLIMB_R" -v cm="$PERF_CLIMB_MIN" 'BEGIN {
    d1 = a1 - b; d2 = a2 - b; d3 = a3 - b
    # If the input costs less than the noise floor, N is too small to say anything.
    # Report that honestly instead of certifying it as "ok".
    if (d1 < 1.0) { printf "0 0 TOOSMALL"; exit }
    r1 = d2 / d1
    r2 = d3 / d2
    # Gate on r2 (least constant-factor contamination). Also catch a CLIMBING ratio
    # even below the ceiling — that is a quadratic showing itself early.
    climbing = (r2 > r1 * cr && r2 > cm)
    # 4th field = WHICH CLAUSE FIRED (#2151). The verdict is a DISJUNCTION, so a bare
    # "** SUPERLINEAR (ALLOC) **" leaves the reader to guess which half tripped — and
    # the modules TIME twin used to guess WRONG IN PRINT (#1879 tripped the climbing
    # clause at r2~2.67 and was told it had exceeded 3.0x).
    why = (r2 > th) ? "threshold" : (climbing ? "climbing" : "-")
    printf "%.2f %.2f %s %s", r1, r2, ((r2 > th || climbing) ? "QUADRATIC" : "ok"), why
  }')"
  r1="$(echo "$verdict" | cut -d' ' -f1)"
  ratio="$(echo "$verdict" | cut -d' ' -f2)"
  word="$(echo "$verdict" | cut -d' ' -f3)"
  why="$(echo "$verdict" | cut -d' ' -f4)"
  clause="$(clause_of "$why")"

  d1="$(awk -v a="$a1" -v b="$BASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
  d2="$(awk -v a="$a2" -v b="$BASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
  d3="$(awk -v a="$a3" -v b="$BASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"

  if [ "$word" = "TOOSMALL" ] && is_known "$shape"; then
    # A LEDGERED shape under the floor is not "raise PERF_N" — it is a DRAIN CLAIM, and
    # the reader must be told the right thing to do (#2150). The generic branch below is
    # already loud, so this is not a silent-skip repair; it is a WRONG-INSTRUCTION one.
    # A KNOWN_SUPERLINEAR entry asserts this shape allocates quadratically; if its net
    # allocation has collapsed under the noise floor, the far likelier reading is that
    # the bug is fixed, and "raise PERF_N" sends the reader to enlarge a band instead of
    # draining a stale ledger row.
    #
    # OBSERVED RED, 2026-08-28, this box, verbatim (#2160 rule 1) — the add-only
    # PERF_LEDGER_EXTRA seam puts a real shape in the ledger, PERF_N drives it
    # under the 1.0 MB floor:
    #
    #   $ PERF_LEDGER_EXTRA=bindings PERF_N=2 sh test/diff_compiler_perf_scaling.sh
    #   exit=1
    #   ## LEDGER INJECTION ACTIVE — this run's verdicts are NOT a grading result. ##
    #   bindings   2   0.9 MB   1.8 MB   3.7 MB   -   -  ** PROMOTE: ledgered, but now too SMALL to grade **
    #
    # Before this branch existed the same run reached the generic arm below and
    # told the reader to "raise PERF_N" — loud, and pointing the wrong way.
    fail=$((fail+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** PROMOTE: ledgered, but now too SMALL to grade **\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "-" "-"
    printf '           Net alloc fell under the 1.0 MB floor. Either the quadratic is FIXED —\n'
    printf '           then remove "%s" from KNOWN_SUPERLINEAR — or the band shrank; raise PERF_N.\n' "$shape"
    printf '           It may NOT stay ledgered AND ungraded.\n'

  # ── OBSERVED RED: the generic TOOSMALL arm and all three ALLOC-ledger arms ──
  #
  # #2160 phase 2, this box, 2026-08-28/29. Every one through an add-only knob;
  # the ledger below was not edited and no threshold was widened.
  #
  # generic TOOSMALL (this branch) — PERF_N drives the shape under the 1.0 MB floor:
  #   $ PERF_ONLY=bindings PERF_N=2 sh test/diff_compiler_perf_scaling.sh
  #   bindings   2   0.9 MB   1.8 MB   3.7 MB   -   -  ** N TOO SMALL — raise PERF_N **
  #   exit=1
  #
  # MALFORMED LEDGER ROW — a ledger entry with no ceiling pair:
  #   $ PERF_ONLY=bindings PERF_LEDGER_EXTRA=bindings sh ...
  #   bindings   ** MALFORMED LEDGER ROW ** no KNOWN_CEIL_bindings / KNOWN_FIXED_bindings pair.
  #              A ledger row without both halves cannot drain itself — that is a
  #              skip-list, not a pin.
  #   exit=1
  #
  # KNOWN-BAD, AND GOT WORSE — ceiling below the measured ratio:
  #   $ ... PERF_LEDGER_EXTRA=bindings KNOWN_CEIL_bindings=1.00 KNOWN_FIXED_bindings=0.50 sh ...
  #   bindings  250  121.0 MB  245.0 MB  2.02  ** KNOWN-BAD, AND GOT WORSE (ceiling 1.00) **
  #   exit=1
  #
  # PROMOTE: now scales LINEARLY — the self-draining half, ceiling above and
  # FIXED above the measured ratio:
  #   $ ... PERF_LEDGER_EXTRA=bindings KNOWN_CEIL_bindings=9.00 KNOWN_FIXED_bindings=3.00 sh ...
  #   bindings  250  121.0 MB  245.0 MB  2.02  ** PROMOTE: now scales LINEARLY **
  #              The underlying bug is FIXED. Remove "bindings" from KNOWN_SUPERLINEAR in \
  #              diff_compiler_perf_scaling.sh
  #   exit=1
  #
  # ⇒ the ALLOC ledger cannot go quiet in EITHER direction: a row that worsens
  #   fails, a row that is fixed fails demanding its own removal, and a row with
  #   only one half fails as malformed. That is the whole contract, observed
  #   rather than asserted.
  elif [ "$word" = "TOOSMALL" ]; then
    # NOT a pass.
    # NOT a pass. An unmeasurable shape is a harness problem, and silently counting
    # it as fine is exactly how a suite starts lying about what it covers.
    fail=$((fail+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** N TOO SMALL — raise PERF_N **\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "-" "-"

  elif is_known "$shape"; then
    # A KNOWN-superlinear shape. Two ways this must still fail:
    # `:-` is load-bearing under `set -u` (:109): without it an unset ceiling
    # ABORTS the whole gate mid-run instead of reporting the malformed row, and
    # the abort exits 2 — which run_gates.sh reads as a skip candidate, not a
    # failure. Observed first-hand on ir_scaling's twin of this block while
    # driving its ledger arms red on 2026-08-28. The explicit check below is the
    # report; the `:-` only stops the shell dying before it can be made.
    eval "ceil=\${KNOWN_CEIL_$shape:-}"
    eval "fixed=\${KNOWN_FIXED_$shape:-}"
    if [ -z "$ceil" ] || [ -z "$fixed" ]; then
      fail=$((fail+1))
      printf '%-10s ** MALFORMED LEDGER ROW ** no KNOWN_CEIL_%s / KNOWN_FIXED_%s pair.\n' \
        "$shape" "$shape" "$shape"
      printf '           A ledger row without both halves cannot drain itself — that is a\n'
      printf '           skip-list, not a pin.\n'
      continue
    fi
    worse="$(awk -v r="$ratio" -v c="$ceil" 'BEGIN{print (r > c) ? "1" : "0"}')"
    better="$(awk -v r="$ratio" -v f="$fixed" 'BEGIN{print (r < f) ? "1" : "0"}')"
    if [ "$worse" = "1" ]; then
      fail=$((fail+1))
      printf '%-10s %8s %9s MB %9s MB %8s  ** KNOWN-BAD, AND GOT WORSE (ceiling %s) **\n' \
        "$shape" "$n1" "$d1" "$d2" "$ratio" "$ceil"
    elif [ "$better" = "1" ]; then
      # ACCIDENTAL FIX. Fail loudly and demand promotion — an un-promoted entry
      # silently degrades into a skip, and then it rots.
      fail=$((fail+1))
      printf '%-10s %8s %9s MB %9s MB %8s  ** PROMOTE: now scales LINEARLY **\n' \
        "$shape" "$n1" "$d1" "$d2" "$ratio"
      printf '           The underlying bug is FIXED. Remove "%s" from KNOWN_SUPERLINEAR in %s\n' \
        "$shape" "$(basename "$0")"
    else
      known=$((known+1))
      printf '%-10s %8s %9s MB %9s MB %8s  known-superlinear (T17; ceiling %s)\n' \
        "$shape" "$n1" "$d1" "$d2" "$ratio" "$ceil"
    fi

  elif [ "$word" = "QUADRATIC" ]; then
    fail=$((fail+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** SUPERLINEAR (ALLOC) ** (%s)\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "$r1" "$ratio" "$clause"
    printf '%s' "$time_lines"
    printf '%s' "$op_lines"

  elif [ "$time_bad" = "1" ]; then
    # Allocation alone said "ok" — this is the blind spot #110 exists to close. A
    # pure O(n^2) scan (the resolve bug in #78) allocates almost nothing extra per
    # element, so allocation cannot see it; TIME can, and just did.
    fail=$((fail+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** SUPERLINEAR (TIME) **\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "$r1" "$ratio"
    printf '           alloc looked fine (r1=%s r2=%s) — the regression is in TIME:\n' "$r1" "$ratio"
    printf '%s' "$time_lines"
    printf '%s' "$op_lines"

  elif [ "$op_bad" = "1" ]; then
    # Allocation AND time both said "ok" — the #884 blind spot. A stage under the
    # 200ms TIME_FLOOR on every shape (e.g. `mark`) is graded by NOTHING on time, and a
    # pure scan allocates nothing — so only the deterministic op arm sees this, and
    # just did. This branch sits AFTER the alloc/time failures so it can only PROMOTE
    # an "ok" to a FAIL, never downgrade one.
    fail=$((fail+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** SUPERLINEAR (OPS) **\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "$r1" "$ratio"
    printf '           alloc AND time looked fine — the regression is in OP COUNT (a pure scan TIME cannot floor-grade):\n'
    printf '%s' "$time_lines"
    printf '%s' "$op_lines"

  else
    pass=$((pass+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ok\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "$r1" "$ratio"
    printf '%s' "$time_lines"
    printf '%s' "$op_lines"
  fi
done

# ── ROW: wasm-listlit — WASM-EMIT ALLOCATION over a wide list literal (#522/#382) ──
#
# THE HOLE THIS CLOSES: the ALLOC arm above strips wasm (`env -u MEDAKA_PERF_WASM`,
# deliberately — see that note), and the wasm TIME arm (grade_wasm_row) only grades the
# `xref`/`match` shapes, whose live decls hold NO wide list literal. So
# wasm_emit.emitListRef — the list-literal cons-spine emitter — was graded by NOTHING,
# and #522's O(n^2) right-append (`tl ++ ["struct.new $C_Cons"]` copied the growing
# accumulator at each of N cons levels) hid there while the LLVM peer (emitList /
# emitRtList, which prepends via `::`) stayed linear.
#
# A DEDICATED wasm-ON alloc row, ISOLATED so it perturbs no other shape's numbers. It
# reads the `wasm-emit` STAGE allocation (per-stage MB, NOT `total`: that keeps the fixed
# ~253 MB wasm-prelude-emit constant out of the ratio and pins the signal to emitListRef)
# from a fresh MEDAKA_PERF_WASM=1 run. DETERMINISTIC ⇒ ONE run per size — no min-of-K, no
# heap-pin, no floor (allocation is noise-free, same contract as the alloc arm above).
# Cost: 3 wasm-ON single-file compiles at N=1500/3000/6000 (+1 wasm-ON baseline), ~5 s
# total on this box — per-PR-cheap. NO time-based shape is added (a wasm TIME row would
# need min-of-K + a heap pin; alloc needs neither and catches this class outright).
# gen_wasm_listlit ROOTS the list (`main = println (length xs)`) so DCE keeps it and
# wasm-emit actually renders it — gen_listlit's `xs` is dead and never reaches emitListRef.
# Graded exactly like the single-file / modules alloc arm: net = stage - wasm baseline,
# then r2 > THRESH (or a CLIMBING ratio) FAILS as SUPERLINEAR; a too-small net is a
# harness failure, never a silent pass. Self-drains the instant emitListRef regresses.
# MEASURED (this box): with the #522 fix net = 21.9 -> 43.6 -> 87.1 MB (r1 1.99, r2 2.00,
# ok); reverting it to the right-append net = 236 -> 901 -> 3519 MB (r1 3.82, r2 3.90,
# SUPERLINEAR) — so this row is proven to go RED on the regression it guards.
WL_N="${PERF_WASM_LISTLIT_N:-1500}"
wln1="$WL_N"; wln2=$((WL_N * 2)); wln3=$((WL_N * 4))
wlf1="$WORK/wasm_listlit_$wln1.mdk"; wlf2="$WORK/wasm_listlit_$wln2.mdk"; wlf3="$WORK/wasm_listlit_$wln3.mdk"
gen_wasm_listlit "$wln1" "$wlf1"
gen_wasm_listlit "$wln2" "$wlf2"
gen_wasm_listlit "$wln3" "$wlf3"

# wasm-emit STAGE allocation (MB), wasm ON. Field 4 is the per-stage MB — the SAME
# column alloc_of reads on the `total` line (`[perf] wasm-emit  <t>s  <MB>MB  <ops>...`).
wasm_emit_alloc_of() {
  MEDAKA_PERF=1 MEDAKA_PERF_WASM=1 "$PROFILE" "$RUNTIME" "$CORE" "$1" 2>&1 \
    | awk '$1=="[perf]" && $2=="wasm-emit" { gsub(/MB/,"",$4); print $4; exit }'
}

# The whole tab-delimited `[perf] wasm-emit` line from ONE wasm-ON run — so a single
# invocation feeds BOTH the wasm-emit ALLOC arm (field 4 MB, #382) and the wasm-emit
# OP-COUNT arm (tab field 5 opDelta, #986) on the wasm-dispatch shape below. Capturing the
# line once (rather than one run per metric) keeps the op coverage at ZERO extra profiler
# invocations. alloc_of_wline / ops_of_wline pick the two fields back out; alloc_of_wline
# reproduces wasm_emit_alloc_of's whitespace-split field-4 read exactly.
wasm_emit_line_of() {
  MEDAKA_PERF=1 MEDAKA_PERF_WASM=1 "$PROFILE" "$RUNTIME" "$CORE" "$1" 2>&1 \
    | awk '$1=="[perf]" && $2=="wasm-emit" { print; exit }'
}
alloc_of_wline() { printf '%s\n' "$1" | awk '{ gsub(/MB/,"",$4); print $4 }'; }
ops_of_wline()   { printf '%s\n' "$1" | awk -F'\t' '{ print $5 }'; }

# ── OBSERVED RED: the `wasm-listlit` unit (#2160 phase 2, rule 1) ──
#
#   $ PERF_ONLY=wasm-listlit PERF_THRESH=1.2 \
#       sh test/diff_compiler_perf_scaling.sh
#   ## PERF_ONLY=[wasm-listlit] — NARROWED RUN, NOT a grading result. ##
#   wasm-listlit     1500      7.5 MB     14.7 MB     29.3 MB    1.96   1.99  ** SUPERLINEAR (WASM-EMIT ALLOC) — emitListRef, #522/#382 ** (r2 > 1.2x)
#   exit=1
#
# The threshold is LOWERED, never the measurement changed: the shape's real
# ratios are the ~2.0 shown, and the run is red only because the bar was put
# under them. That is what proves the arm can report; it says nothing about
# this shape's scaling, and the shipped threshold is unchanged.

if want wasm-listlit; then   # PERF_ONLY unit: wasm-listlit
# Own baseline: the wasm-emit stage's FIXED prelude-emit cost (main = println 1, no list).
WLBASE_ALLOC="$(wasm_emit_alloc_of "$BASE_FIX")"
wla1="$(wasm_emit_alloc_of "$wlf1")"
wla2="$(wasm_emit_alloc_of "$wlf2")"
wla3="$(wasm_emit_alloc_of "$wlf3")"

# A shape that cannot be measured is a HARNESS failure, never a silent pass. An empty
# reading here means MEDAKA_PERF_WASM is not wiring the stage on, or the wasm-emit
# [perf] line vanished — either way the row is DEAD and must fail loudly, not exit 0.
case "$WLBASE_ALLOC$wla1$wla2$wla3" in
  *[!0-9.]*|"")
    echo "FAIL wasm-listlit: profiler produced no wasm-emit allocation figure (harness bug — MEDAKA_PERF_WASM not wiring the stage on, or the [perf] wasm-emit line is gone)"
    fail=$((fail+1)) ;;
  *)
    wlnet1="$(awk -v a="$wla1" -v b="$WLBASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
    wlnet2="$(awk -v a="$wla2" -v b="$WLBASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
    wlnet3="$(awk -v a="$wla3" -v b="$WLBASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
    wlverdict="$(awk -v n1="$wlnet1" -v n2="$wlnet2" -v n3="$wlnet3" -v th="$THRESH" -v cr="$PERF_CLIMB_R" -v cm="$PERF_CLIMB_MIN" 'BEGIN {
      if (n1 + 0 < 1.0) { printf "0 0 TOOSMALL"; exit }
      r1 = n2 / n1; r2 = n3 / n2
      climbing = (r2 > r1 * cr && r2 > cm)
      why = (r2 > th) ? "threshold" : (climbing ? "climbing" : "-")
      printf "%.2f %.2f %s %s", r1, r2, ((r2 > th || climbing) ? "QUADRATIC" : "ok"), why
    }')"
    wlr1="$(echo "$wlverdict" | cut -d' ' -f1)"
    wlr2="$(echo "$wlverdict" | cut -d' ' -f2)"
    wlword="$(echo "$wlverdict" | cut -d' ' -f3)"
    wlclause="$(clause_of "$(echo "$wlverdict" | cut -d' ' -f4)")"
    if [ "$wlword" = "TOOSMALL" ]; then
      fail=$((fail+1))
      printf '%-12s %8s %8s MB %8s MB %8s MB  %6s %6s  ** N TOO SMALL — raise PERF_WASM_LISTLIT_N **\n' \
        "wasm-listlit" "$wln1" "$wlnet1" "$wlnet2" "$wlnet3" "-" "-"
    elif [ "$wlword" = "QUADRATIC" ]; then
      fail=$((fail+1))
      printf '%-12s %8s %8s MB %8s MB %8s MB  %6s %6s  ** SUPERLINEAR (WASM-EMIT ALLOC) — emitListRef, #522/#382 ** (%s)\n' \
        "wasm-listlit" "$wln1" "$wlnet1" "$wlnet2" "$wlnet3" "$wlr1" "$wlr2" "$wlclause"
    else
      pass=$((pass+1))
      printf '%-12s %8s %8s MB %8s MB %8s MB  %6s %6s  ok  (wasm-emit stage alloc)\n' \
        "wasm-listlit" "$wln1" "$wlnet1" "$wlnet2" "$wlnet3" "$wlr1" "$wlr2"
    fi ;;
esac

fi   # end PERF_ONLY unit: wasm-listlit
# ── ROW: wasm-dispatch — WASM-EMIT ALLOCATION over a dispatch-heavy program (#382) ──
#
# THE HOLE THIS CLOSES: wasm_emit inlines a typeclass dispatch chain PER call site (the
# LLVM backend outlines one dispatcher per method), and each site scanned the WHOLE flat
# `progImpls` list — implForW / methodImpls / implArityFor / gatherImplGroup all
# `flatMap`/`findByTagW` over every impl entry per RKey/RDict site. On code with many
# interfaces × many dispatch sites that is O(sites · impls) ⇒ O(N^2), and the flatMaps
# REBUILD an O(impls) list per site ⇒ superlinear wasm-emit ALLOCATION. The ALLOC arm
# above strips wasm (`env -u MEDAKA_PERF_WASM`) and the wasm TIME arm grades only the
# xref/match shapes (whose live decls declare NO impls), so this dispatch-scan allocation
# was graded by NOTHING (#382, the #349/#350 twins — peers of the native audit).
#
# A DEDICATED wasm-ON alloc row, ISOLATED so it perturbs no other shape. It reads the
# `wasm-emit` STAGE allocation (per-stage MB, field 4 — NOT `total`, so the fixed
# ~235 MB wasm-prelude-emit constant stays out of the ratio and the signal is pinned to
# the dispatch scans) from a fresh MEDAKA_PERF_WASM=1 run. DETERMINISTIC ⇒ ONE run per
# size, no min-of-K / heap-pin / floor (same contract as wasm-listlit and the alloc arm).
# Cost: 3 wasm-ON single-file compiles at N=400/800/1600 (+ the shared wasm baseline),
# ~4 s on this box — per-PR-cheap. NO time-based shape is added.
# gen_wasm_dispatch sums the N dispatch results through a LIST-LITERAL fold (NOT an N-wide
# `+` chain), so emitBinRef / the arithmetic-chain allocation does not confound the signal.
#
# ⚠️ WHY A DEDICATED 2.4 THRESHOLD (not the global 3.0): the per-site impl scan is a
# TIME quadratic that allocates only WEAKLY — findByTagW / methodImpls traverse O(impls)
# per site but allocate O(1) (only the matching entry), so the alloc ratio saturates
# toward the quadratic 4.0 SLOWLY and, at the cheap per-PR N, PLATEAUS around 2.6 without
# the fix rather than blowing past 3.0 (it only clears 3.0 at N>=~1000, too costly per
# PR — that band runs under PERF_DEEP below). ALLOCATION IS DETERMINISTIC (byte-exact GC
# counts, zero run-to-run variance), so a tight threshold is SAFE here in a way no TIME
# gate could be, and the shape is dedicated (its wasm-emit alloc is driven ONLY by the
# dispatch-scan + linear list/fold/impl-fn emission), so a reading over 2.4 on THIS shape
# is a genuine dispatch-scan regression, never noise. Graded like the other alloc rows:
# net = stage - wasm baseline, then r2 > WD_THRESH (or a CLIMBING ratio) FAILS as
# SUPERLINEAR; a too-small net is a harness failure, never a silent pass.
# MEASURED (this box), QUICK N=400/800/1600:
#   WITH the impl-index memo:  net = 27.9 -> 56.0 -> 113.2 MB   (r1 2.01, r2 2.02, ok)
#   WITHOUT it (installImplIndexW removed ⇒ methodEntriesW falls back to the full
#              progImpls list per site): net = 77.8 -> 185.1 -> 488.3 MB (r1 2.38, r2 2.64,
#              SUPERLINEAR, > 2.4) — so this row is PROVEN to go RED on the regression it
#              guards, and green with it, both at the cheap per-PR band.
#   PERF_DEEP N=1000/2000/4000 without the memo: net = 249.9 -> 684.1 -> 2103.9 MB
#              (r1 2.74, r2 3.08) — the same regression, past even the global 3.0 at the
#              nightly band. Self-drains the instant the per-site impl scans regress.
WD_THRESH="${PERF_WASM_DISPATCH_THRESH:-2.4}"
if [ "$PERF_DEEP" = "1" ]; then WD_N="${PERF_WASM_DISPATCH_N:-1000}"; else WD_N="${PERF_WASM_DISPATCH_N:-400}"; fi
wdn1="$WD_N"; wdn2=$((WD_N * 2)); wdn3=$((WD_N * 4))
wdf1="$WORK/wasm_dispatch_$wdn1.mdk"; wdf2="$WORK/wasm_dispatch_$wdn2.mdk"; wdf3="$WORK/wasm_dispatch_$wdn3.mdk"
gen_wasm_dispatch "$wdn1" "$wdf1"
gen_wasm_dispatch "$wdn2" "$wdf2"
gen_wasm_dispatch "$wdn3" "$wdf3"

# Own baseline: reuse the wasm-emit stage's FIXED prelude-emit cost (main = println 1).
# ONE wasm-ON run per size (captured whole), then the ALLOC arm (#382, field 4) and the
# OP-COUNT arm (#986, tab field 5) both read it — the op coverage costs no extra run.
# ── OBSERVED RED: the `wasm-dispatch` unit (#2160 phase 2, rule 1) ──
#
#   $ PERF_ONLY=wasm-dispatch PERF_WASM_DISPATCH_THRESH=1.2 \
#       sh test/diff_compiler_perf_scaling.sh
#   ## PERF_ONLY=[wasm-dispatch] — NARROWED RUN, NOT a grading result. ##
#   wasm-dispatch      400     28.6 MB     57.6 MB    116.2 MB    2.01   2.02  ** SUPERLINEAR (WASM-EMIT ALLOC) — per-site impl scan, #382 ** (r2 > 1.2x)
#   wasm-disp/op      400  67728.0 op 134528.0 op 268128.0 op    1.99   1.99  ** SUPERLINEAR (WASM-EMIT OPS) — methodArityOf/methodIfaceOf iface scan, #986 ** (r2 > 1.2x)
#   exit=1
#
# The threshold is LOWERED, never the measurement changed: the shape's real
# ratios are the ~2.0 shown, and the run is red only because the bar was put
# under them. That is what proves the arm can report; it says nothing about
# this shape's scaling, and the shipped threshold is unchanged.

if want wasm-dispatch; then   # PERF_ONLY unit: wasm-dispatch
WDBASE_LINE="$(wasm_emit_line_of "$BASE_FIX")"
wdln1="$(wasm_emit_line_of "$wdf1")"
wdln2="$(wasm_emit_line_of "$wdf2")"
wdln3="$(wasm_emit_line_of "$wdf3")"
WDBASE_ALLOC="$(alloc_of_wline "$WDBASE_LINE")"
wda1="$(alloc_of_wline "$wdln1")"
wda2="$(alloc_of_wline "$wdln2")"
wda3="$(alloc_of_wline "$wdln3")"
WDBASE_OPS="$(ops_of_wline "$WDBASE_LINE")"
wdo1="$(ops_of_wline "$wdln1")"
wdo2="$(ops_of_wline "$wdln2")"
wdo3="$(ops_of_wline "$wdln3")"

case "$WDBASE_ALLOC$wda1$wda2$wda3" in
  *[!0-9.]*|"")
    echo "FAIL wasm-dispatch: profiler produced no wasm-emit allocation figure (harness bug — MEDAKA_PERF_WASM not wiring the stage on, or the [perf] wasm-emit line is gone)"
    fail=$((fail+1)) ;;
  *)
    wdnet1="$(awk -v a="$wda1" -v b="$WDBASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
    wdnet2="$(awk -v a="$wda2" -v b="$WDBASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
    wdnet3="$(awk -v a="$wda3" -v b="$WDBASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
    wdverdict="$(awk -v n1="$wdnet1" -v n2="$wdnet2" -v n3="$wdnet3" -v th="$WD_THRESH" -v cr="$PERF_CLIMB_R" -v cm="$PERF_CLIMB_MIN" 'BEGIN {
      if (n1 + 0 < 1.0) { printf "0 0 TOOSMALL"; exit }
      r1 = n2 / n1; r2 = n3 / n2
      climbing = (r2 > r1 * cr && r2 > cm)
      why = (r2 > th) ? "threshold" : (climbing ? "climbing" : "-")
      printf "%.2f %.2f %s %s", r1, r2, ((r2 > th || climbing) ? "QUADRATIC" : "ok"), why
    }')"
    wdr1="$(echo "$wdverdict" | cut -d' ' -f1)"
    wdr2="$(echo "$wdverdict" | cut -d' ' -f2)"
    wdword="$(echo "$wdverdict" | cut -d' ' -f3)"
    wdclause="$(clause_of "$(echo "$wdverdict" | cut -d' ' -f4)" "$WD_THRESH")"
    if [ "$wdword" = "TOOSMALL" ]; then
      fail=$((fail+1))
      printf '%-12s %8s %8s MB %8s MB %8s MB  %6s %6s  ** N TOO SMALL — raise PERF_WASM_DISPATCH_N **\n' \
        "wasm-dispatch" "$wdn1" "$wdnet1" "$wdnet2" "$wdnet3" "-" "-"
    elif [ "$wdword" = "QUADRATIC" ]; then
      fail=$((fail+1))
      printf '%-12s %8s %8s MB %8s MB %8s MB  %6s %6s  ** SUPERLINEAR (WASM-EMIT ALLOC) — per-site impl scan, #382 ** (%s)\n' \
        "wasm-dispatch" "$wdn1" "$wdnet1" "$wdnet2" "$wdnet3" "$wdr1" "$wdr2" "$wdclause"
    else
      pass=$((pass+1))
      printf '%-12s %8s %8s MB %8s MB %8s MB  %6s %6s  ok  (wasm-emit stage alloc)\n' \
        "wasm-dispatch" "$wdn1" "$wdnet1" "$wdnet2" "$wdnet3" "$wdr1" "$wdr2"
    fi ;;
esac

# ── ROW: wasm-dispatch (OP-COUNT) — the methodArityOf/methodIfaceOf scan (#986) ──
#
# THE HOLE THIS CLOSES: `emit_support.methodArityOf`/`methodIfaceOf` (shared by BOTH
# backends) `lookupAssoc`'d the program-growing iface-method table on EVERY dispatch call
# site → O(sites · methods).  It is a PURE SCAN that allocates NOTHING, so the ALLOC arm
# above (which caught the #382 impl-scan, a REBUILDING scan) is structurally BLIND to it.
# Only the deterministic OP-COUNT sees it: `lookupAssoc` `opBump`s once per scan step, so
# the wasm-emit op-delta carries the O(N^2) growth that no allocation figure does.
#
# WHY THIS IS THE WASM-EMIT STAGE AND NOT `emit` (LLVM): #985 already indexed the wasm
# impl-scan (implsByMethodW), so post-#985 methodArityOf is the DOMINANT remaining op
# quadratic on wasm-emit — a clean, isolated signal.  The LLVM `emit` stage is still
# swamped by its own UN-indexed impl-scan (the #382 LLVM residual, ~4x on this shape either
# way), which would drown methodArityOf's delta and gate an unrelated bug — so gating `emit`
# ops here would be neither clean nor a #986 signal.  methodArityOf is ONE shared
# emit_support reader, though, so this wasm-emit op row catches ANY regression of it
# regardless of which backend's call sites trip it — there is no LLVM-only copy to miss.
#
# Rides the SAME wasm-ON runs the ALLOC arm already made (ops_of_wline off the captured
# line) ⇒ ZERO extra profiler invocations.  DETERMINISTIC (op counts are exact, no
# run-to-run variance), so it needs no min-of-K / heap-pin / floor and shares WD_THRESH.
# Net = stage op-delta − wasm baseline op-delta (the fixed prelude-emit constant), then
# r2 > WD_THRESH (or a CLIMBING ratio) FAILS as SUPERLINEAR; a too-small net (< OP_FLOOR)
# is a harness failure, never a silent pass.
# MEASURED (this box), QUICK N=400/800/1600, baseline op-delta 175189:
#   WITH the index memo (omLookup): net = 67329 -> 133729 -> 266529 (r1 1.99, r2 1.99, ok)
#   WITHOUT it (methodArityOf/methodIfaceOf fall back to the linear lookupAssoc): net =
#              184579 -> 511179 -> 1644379 (r1 2.77, r2 3.22, SUPERLINEAR, > 2.4) — so this
#              row is PROVEN to go RED on the regression it guards and green with it, both
#              at the cheap per-PR band.  Self-drains the instant the per-site iface scan
#              regresses.
case "$WDBASE_OPS$wdo1$wdo2$wdo3" in
  *[!0-9.]*|"")
    echo "FAIL wasm-dispatch (ops): profiler produced no wasm-emit op-delta figure (harness bug — MEDAKA_PERF_WASM not wiring the stage on, or the [perf] wasm-emit op column is gone)"
    fail=$((fail+1)) ;;
  *)
    wdonet1="$(awk -v a="$wdo1" -v b="$WDBASE_OPS" 'BEGIN{printf "%.1f", a-b}')"
    wdonet2="$(awk -v a="$wdo2" -v b="$WDBASE_OPS" 'BEGIN{printf "%.1f", a-b}')"
    wdonet3="$(awk -v a="$wdo3" -v b="$WDBASE_OPS" 'BEGIN{printf "%.1f", a-b}')"
    wdoverdict="$(awk -v n1="$wdonet1" -v n2="$wdonet2" -v n3="$wdonet3" -v th="$WD_THRESH" -v fl="$OP_FLOOR" -v cr="$PERF_CLIMB_R" -v cm="$PERF_CLIMB_MIN" 'BEGIN {
      if (n1 + 0 < fl + 0) { printf "0 0 TOOSMALL"; exit }
      r1 = n2 / n1; r2 = n3 / n2
      climbing = (r2 > r1 * cr && r2 > cm)
      why = (r2 > th) ? "threshold" : (climbing ? "climbing" : "-")
      printf "%.2f %.2f %s %s", r1, r2, ((r2 > th || climbing) ? "QUADRATIC" : "ok"), why
    }')"
    wdor1="$(echo "$wdoverdict" | cut -d' ' -f1)"
    wdor2="$(echo "$wdoverdict" | cut -d' ' -f2)"
    wdoword="$(echo "$wdoverdict" | cut -d' ' -f3)"
    wdoclause="$(clause_of "$(echo "$wdoverdict" | cut -d' ' -f4)" "$WD_THRESH")"
    if [ "$wdoword" = "TOOSMALL" ]; then
      fail=$((fail+1))
      printf '%-12s %8s %8s op %8s op %8s op  %6s %6s  ** N TOO SMALL — raise PERF_WASM_DISPATCH_N **\n' \
        "wasm-disp/op" "$wdn1" "$wdonet1" "$wdonet2" "$wdonet3" "-" "-"
    elif [ "$wdoword" = "QUADRATIC" ]; then
      ops_graded=$((ops_graded+1))
      fail=$((fail+1))
      printf '%-12s %8s %8s op %8s op %8s op  %6s %6s  ** SUPERLINEAR (WASM-EMIT OPS) — methodArityOf/methodIfaceOf iface scan, #986 ** (%s)\n' \
        "wasm-disp/op" "$wdn1" "$wdonet1" "$wdonet2" "$wdonet3" "$wdor1" "$wdor2" "$wdoclause"
    else
      ops_graded=$((ops_graded+1))
      pass=$((pass+1))
      printf '%-12s %8s %8s op %8s op %8s op  %6s %6s  ok  (wasm-emit stage ops)\n' \
        "wasm-disp/op" "$wdn1" "$wdonet1" "$wdonet2" "$wdonet3" "$wdor1" "$wdor2"
    fi ;;
esac

fi   # end PERF_ONLY unit: wasm-dispatch
# ── ROW: llvm-dispatch (OP-COUNT) — the LLVM `emit` residual scan (#990) ──────────
#
# THE HOLE THIS CLOSES: the #986 wasm-disp/op row above deliberately gated wasm-emit and
# NOT the LLVM `emit` stage, noting the LLVM residual (~4x on this shape either way) would
# have drowned methodArityOf's signal. THIS row closes that residual. Post-#986 the LLVM
# `emit` op-count on the SAME dispatch shape was still ~3.77x/doubling (SUPERLINEAR) from
# per-emit scans that NEITHER the alloc arm (they allocate O(1)) NOR the wasm arm (LLVM-only
# call sites) grade:
#   • `implMethodNames` — an O(N^2) `dedupS` of every tagged impl's method name, rebuilt per
#     `isImplMethod` (emitVar/emitApp) call site — the LLVM twin of the #382 impl scan;
#   • `nubStr`/`distinctTypeNames` — a one-time O(types^2) ctor->type nub;
#   • `cellTag`'s `ctorTypeId`/`ctorOrdinal` — an O(types) ctor->type `lookupAssoc` per ctor.
# #990 indexes each into an OrdMap memo built ONCE (implMethodSetRef / ctorTypeMapRef /
# nubStr's OrdMap seen-set). A pure SCAN that allocates nothing but `opBump`s once per step,
# so ONLY the deterministic OP-COUNT sees it — exactly the axis #986 established for its twin.
#
# Reads the LLVM `emit` op-delta (tab-field 5) from a fresh wasm-OFF profile_run over the
# SAME gen_wasm_dispatch fixtures the wasm rows already generated (wdf1/wdf2/wdf3) ⇒ only 4
# extra single-file profiler invocations (3 + the BASE_FIX prelude constant), ~3 s, per-PR
# cheap. DETERMINISTIC (exact op counts, no run-to-run variance) ⇒ no min-of-K / heap-pin /
# floor; a dedicated 2.5 threshold is SAFE where no time gate could be. Net = emit op-delta -
# baseline prelude op-delta, then r2 > LD_THRESH (or a CLIMBING ratio) FAILS as SUPERLINEAR.
# MEASURED (this box), QUICK N=400/800/1600, baseline emit op-delta ~20841:
#   WITH the #990 indexes:  net = 6692 -> 13092 -> 25892 op   (r1 1.96, r2 1.98, LINEAR, ok)
#   WITHOUT them (origin/main + #986, impl/ctor/nub scans un-indexed): net =
#              766653 -> 2807053 -> 10727853 op (r1 3.66, r2 3.82, SUPERLINEAR, > 2.5) — so
#              this row is PROVEN RED on the regression it guards, GREEN with the fix, both at
#              the cheap per-PR band. Self-drains the instant a per-site LLVM emit scan regresses.
LD_THRESH="${PERF_LLVM_DISPATCH_THRESH:-2.5}"
# ── OBSERVED RED: the `llvm-dispatch` unit (#2160 phase 2, rule 1) ──
#
#   $ PERF_ONLY=llvm-dispatch PERF_LLVM_DISPATCH_THRESH=1.2 \
#       sh test/diff_compiler_perf_scaling.sh
#   ## PERF_ONLY=[llvm-dispatch] — NARROWED RUN, NOT a grading result. ##
#   llvm-disp/op      400   2681.0 op   5081.0 op   9881.0 op    1.90   1.94  ** SUPERLINEAR (LLVM-EMIT OPS) — impl/ctor/nub scan, #990 ** (r2 > 1.2x)
#   exit=1
#
# The threshold is LOWERED, never the measurement changed: the shape's real
# ratios are the ~2.0 shown, and the run is red only because the bar was put
# under them. That is what proves the arm can report; it says nothing about
# this shape's scaling, and the shipped threshold is unchanged.

if want llvm-dispatch; then   # PERF_ONLY unit: llvm-dispatch
LDBASE_OP="$(profile_run "$BASE_FIX" | awk -F'\t' '$1=="[perf] emit"{print $5; exit}')"
ldo1="$(profile_run "$wdf1" | awk -F'\t' '$1=="[perf] emit"{print $5; exit}')"
ldo2="$(profile_run "$wdf2" | awk -F'\t' '$1=="[perf] emit"{print $5; exit}')"
ldo3="$(profile_run "$wdf3" | awk -F'\t' '$1=="[perf] emit"{print $5; exit}')"

case "$LDBASE_OP$ldo1$ldo2$ldo3" in
  *[!0-9.]*|"")
    echo "FAIL llvm-dispatch (ops): profiler produced no LLVM emit op-delta figure (harness bug — the [perf] emit op column is gone)"
    fail=$((fail+1)) ;;
  *)
    ldonet1="$(awk -v a="$ldo1" -v b="$LDBASE_OP" 'BEGIN{printf "%.1f", a-b}')"
    ldonet2="$(awk -v a="$ldo2" -v b="$LDBASE_OP" 'BEGIN{printf "%.1f", a-b}')"
    ldonet3="$(awk -v a="$ldo3" -v b="$LDBASE_OP" 'BEGIN{printf "%.1f", a-b}')"
    ldoverdict="$(awk -v n1="$ldonet1" -v n2="$ldonet2" -v n3="$ldonet3" -v th="$LD_THRESH" -v fl="$OP_FLOOR" -v cr="$PERF_CLIMB_R" -v cm="$PERF_CLIMB_MIN" 'BEGIN {
      if (n1 + 0 < fl + 0) { printf "0 0 TOOSMALL"; exit }
      r1 = n2 / n1; r2 = n3 / n2
      climbing = (r2 > r1 * cr && r2 > cm)
      why = (r2 > th) ? "threshold" : (climbing ? "climbing" : "-")
      printf "%.2f %.2f %s %s", r1, r2, ((r2 > th || climbing) ? "QUADRATIC" : "ok"), why
    }')"
    ldor1="$(echo "$ldoverdict" | cut -d' ' -f1)"
    ldor2="$(echo "$ldoverdict" | cut -d' ' -f2)"
    ldoword="$(echo "$ldoverdict" | cut -d' ' -f3)"
    ldoclause="$(clause_of "$(echo "$ldoverdict" | cut -d' ' -f4)" "$LD_THRESH")"
    if [ "$ldoword" = "TOOSMALL" ]; then
      fail=$((fail+1))
      printf '%-12s %8s %8s op %8s op %8s op  %6s %6s  ** N TOO SMALL — raise PERF_WASM_DISPATCH_N **\n' \
        "llvm-disp/op" "$wdn1" "$ldonet1" "$ldonet2" "$ldonet3" "-" "-"
    elif [ "$ldoword" = "QUADRATIC" ]; then
      ops_graded=$((ops_graded+1))
      fail=$((fail+1))
      printf '%-12s %8s %8s op %8s op %8s op  %6s %6s  ** SUPERLINEAR (LLVM-EMIT OPS) — impl/ctor/nub scan, #990 ** (%s)\n' \
        "llvm-disp/op" "$wdn1" "$ldonet1" "$ldonet2" "$ldonet3" "$ldor1" "$ldor2" "$ldoclause"
    else
      ops_graded=$((ops_graded+1))
      pass=$((pass+1))
      printf '%-12s %8s %8s op %8s op %8s op  %6s %6s  ok  (llvm-emit stage ops)\n' \
        "llvm-disp/op" "$wdn1" "$ldonet1" "$ldonet2" "$ldonet3" "$ldor1" "$ldor2"
    fi ;;
esac

fi   # end PERF_ONLY unit: llvm-dispatch
# ── SHAPE: modules — the O(modules^2) family (issue #153) ─────────────────────
#
# This is the WHOLE POINT of #153: the five shapes above are single-file, so they
# run only the single-file driver and are STRUCTURALLY BLIND to the multi-module
# passes (checkModuleFullImpl, elabModuleStamp) where the module-count quadratics
# live. This shape runs the MULTI-MODULE driver (profile_modules_main:
# loadProgram -> markModules -> checkModules) over N import-chained modules so the
# accumulated-decl rescans actually execute. It is graded on BOTH net-total
# allocation (its own baseline, subtracted like the single-file shapes) AND, since
# the scan-heavy part is time-dominant, the per-stage `typecheck` TIME.
#
# ⚠️ IT IS NOT A LEDGERED ENTRY, and this header used to say it was ("a LEDGERED entry
# (KNOWN_SUPERLINEAR + KNOWN_SLOW_TIME)"). #154 PR-C drained both rows in 2026-07-16 and
# neither was re-added. It could not be re-added here anyway: this shape is NOT in the
# SHAPES loop, so `is_known`/`is_known_time` are never consulted for it — its ALLOC and
# ALLOC verdict below is open-coded with no ledger arm. ⚠️ THE TIME VERDICT NO LONGER IS:
# it grew one (KNOWN_SLOW_TIME / KNOWN_TCEIL_modules_typecheck), because #1879 kept
# bouncing unrelated PRs out of the merge queue and an open-coded arm has no honest way
# to hold a known defect — only "red forever" or "widened away". The DETERMINISTIC pin
# for that quadratic still lives on `test/diff_compiler_stage_ir_scaling.sh`'s
# `modules:typecheck` KNOWN_SLOW row, whose measure is instruction counts rather than
# wall-clock; this arm's ledger is the wall-clock restatement of the same curve.
# Do not "fix" a red here by widening a threshold or flooring the stage out — see the
# TIME verdict block below.
MOD_N="${PERF_MOD_N:-100}"
MOD_K="${PERF_MOD_K:-8}"
mn1="$MOD_N"; mn2=$((MOD_N * 2)); mn3=$((MOD_N * 4))
md1="$WORK/modules_$mn1"; md2="$WORK/modules_$mn2"; md3="$WORK/modules_$mn3"
gen_modules "$mn1" "$md1" "$MOD_K"
gen_modules "$mn2" "$md2" "$MOD_K"
gen_modules "$mn3" "$md3" "$MOD_K"

# ── OBSERVED RED: the `modules` unit (#2160 phase 2, rule 1) ──
#
#   $ PERF_ONLY=modules PERF_THRESH=1.2 \
#       sh test/diff_compiler_perf_scaling.sh
#   ## PERF_ONLY=[modules] — NARROWED RUN, NOT a grading result. ##
#   modules         100   397.2 MB   853.8 MB  1943.8 MB    2.15   2.28  ** SUPERLINEAR (ALLOC) ** (r2 > 1.2x)
#              time typecheck: ** SUPERLINEAR (TIME) ** 0.234…s -> 0.514…s -> 1.392…s  r1=2.20 r2=2.71 (r2 > 1.2x)
#   exit=1
#
# The threshold is LOWERED, never the measurement changed: the shape's real
# ratios are the ~2.0 shown, and the run is red only because the bar was put
# under them. That is what proves the arm can report; it says nothing about
# this shape's scaling, and the shipped threshold is unchanged.
#
# ── OBSERVED RED: this unit's TWO HARNESS GUARDS, via PERF_PROFILE_MODULES ──
#
# The unit has two guards that no threshold knob can reach, because they fire on
# a DEAD INSTRUMENT rather than on a number: the ALLOC "profiler produced no
# allocation figure" case below, and the TIME "NO MEASUREMENT from the profiler"
# branch further down. PERF_PROFILE_MODULES is the seam that reaches them (its
# rationale is at the PROFILE_MODULES assignment near the top of this file).
#
#   $ cat /tmp/deadmod.sh                    # scratch, NOT test/ ([T-SHARED-CORPUS])
#   #!/bin/sh
#   case "$4" in *base*) exec /abs/path/test/bin/profile_modules_main "$@" ;; esac
#   exit 0
#   $ PERF_PROFILE_MODULES=/tmp/deadmod.sh PERF_MOD_N=100 PERF_ONLY=modules \
#       sh test/diff_compiler_perf_scaling.sh
#   ## PERF_PROFILE_MODULES SUBSTITUTED — NOT a grading run. ##
#   modules  100  -70.4 MB  -70.4 MB  -70.4 MB   -   -  ** NEGATIVE NET ALLOC — profiler/baseline mismatch (harness bug) **
#              time typecheck: NO MEASUREMENT from the profiler (harness bug)
#   exit=1
#
# ⚠️ The ALLOC guard's `*[!0-9.]*|""` case does NOT fire on the wrapper above — a
# SILENT profiler yields the string "0", which is numeric, so the run falls through
# to the netting and lands on the NEGATIVE arm instead. THIS NOTE BRIEFLY RECORDED
# THAT AS A HOLE ("nothing add-only in this file produces non-numeric junk"), and
# that was wrong: an independent review of this PR pointed out that the very seam
# eleven lines up is such a knob, and the arm takes a THREE-LINE wrapper. Do not
# repeat the mistake of declaring a hole one variable short of the answer.
#
#   $ cat /tmp/junkmod.sh
#   #!/bin/sh
#   printf '[perf] total\t0.1s\t0.1s\tNaNMB\t0\n'
#   exit 0
#   $ PERF_PROFILE_MODULES=/tmp/junkmod.sh PERF_MOD_N=2 PERF_ONLY=modules \
#       sh test/diff_compiler_perf_scaling.sh
#   FAIL modules: profiler produced no allocation figure (harness bug)
#   exit=1
#
# So BOTH the dead-instrument arms of this row are observed: a silent profiler
# lands on NEGATIVE, a junk-emitting one lands here.

if want modules; then   # PERF_ONLY unit: modules
# Own baseline: this driver's fixed prelude cost differs from the single-file one.
MBASE_DIR="$WORK/modules_base"; mkdir -p "$MBASE_DIR"
printf 'main = println 1\n' > "$MBASE_DIR/entry.mdk"
MBASE_ALLOC="$(alloc_of_modules "$MBASE_DIR/entry.mdk" "$MBASE_DIR")"

ma1="$(alloc_of_modules "$md1/entry.mdk" "$md1")"
ma2="$(alloc_of_modules "$md2/entry.mdk" "$md2")"
ma3="$(alloc_of_modules "$md3/entry.mdk" "$md3")"

# A shape that cannot be measured is a HARNESS failure, never a silent pass — same
# contract as the single-file loop.
case "$MBASE_ALLOC$ma1$ma2$ma3" in
  *[!0-9.]*|"")
    echo "FAIL modules: profiler produced no allocation figure (harness bug)"
    fail=$((fail+1)) ;;
  *)
    # typecheck-stage TIME, min-of-K, heap pinned (rule 2/3). The other stages
    # (load/mark/desugar) scale linearly and sit under the 200ms floor at these N,
    # so typecheck is the one time signal worth grading — and the one the ledger
    # names.
    mt1="$(stage_times_min_modules "$md1/entry.mdk" "$md1" "$PERF_K" | awk '$1=="typecheck"{print $2}')"
    mt2="$(stage_times_min_modules "$md2/entry.mdk" "$md2" "$PERF_K" | awk '$1=="typecheck"{print $2}')"
    mt3="$(stage_times_min_modules "$md3/entry.mdk" "$md3" "$PERF_K" | awk '$1=="typecheck"{print $2}')"

    mnet1="$(awk -v a="$ma1" -v b="$MBASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
    mnet2="$(awk -v a="$ma2" -v b="$MBASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
    mnet3="$(awk -v a="$ma3" -v b="$MBASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"

    # ── ALLOC verdict: HARD LINEAR GATE (#154 PR-C promoted `modules` OUT of the ledger
    # 2026-07-16).  The foldModules-concat O(modules^2) is gone.  Graded exactly like the
    # single-file shapes: r2 > THRESH (or a CLIMBING ratio) FAILS as SUPERLINEAR; a
    # too-small measurement is a harness failure, never a silent pass. ──
    #
    # ⚠️ "net-alloc r2 is FLAT ~2.0 to N=1600" USED TO STAND HERE AND IS NOT TRUE.  Measured
    # at N=100/200/400, K=8, heap pinned: 399.1 / 857.6 / 1951.6 MB, r1=2.15 r2=2.28 — which
    # fits the same a*N + b*N^2 model the Ir and TIME arms fit, with a quadratic term worth
    # 24.3% of the N=400 total.  ALLOC is not FLAT here, it is SUB-THRESHOLD: it sees the
    # least of the same defect the other two arms see.  Do not cite this arm's green as
    # evidence that a `modules:typecheck` regression "costs time without costing allocation";
    # it costs both, just under both gates' thresholds.  The pin is stage_ir_scaling's
    # `modules:typecheck` KNOWN_SLOW row.
    # ⚠️ THE FOURTH FIELD IS THE CLAUSE THAT FIRED, AND IT IS NOT COSMETIC.  The
    # verdict is a DISJUNCTION (`r2 > th` OR `climbing`), so a bare "** SUPERLINEAR
    # (ALLOC) **" leaves the reader to guess which half tripped — and the TIME twin
    # below used to guess WRONG IN PRINT, telling #1879 it had exceeded 3.0x when it
    # had actually tripped the climbing clause at r2≈2.67.  Naming the clause is what
    # makes the failure text a measurement rather than a label.
    averdict="$(awk -v n1="$mnet1" -v n2="$mnet2" -v n3="$mnet3" -v th="$THRESH" -v cr="$PERF_CLIMB_R" -v cm="$PERF_CLIMB_MIN" 'BEGIN {
      if (n1 + 0 < 0 || n2 + 0 < 0 || n3 + 0 < 0) { printf "0 0 NEGATIVE -"; exit }
      if (n1 + 0 < 1.0) { printf "0 0 TOOSMALL -"; exit }
      r1 = n2 / n1; r2 = n3 / n2
      climbing = (r2 > r1 * cr && r2 > cm)
      why = (r2 > th) ? "threshold" : (climbing ? "climbing" : "-")
      printf "%.2f %.2f %s %s", r1, r2, ((r2 > th || climbing) ? "QUADRATIC" : "ok"), why
    }')"
    mar1="$(echo "$averdict" | cut -d' ' -f1)"
    mar2="$(echo "$averdict" | cut -d' ' -f2)"
    aword="$(echo "$averdict" | cut -d' ' -f3)"
    awhy="$(echo "$averdict" | cut -d' ' -f4)"
    aclause="$(clause_of "$awhy")"
    # ── OBSERVED RED — the NEGATIVE arm (added by this sweep, #2160 phase 2) ──
    #
    # A net allocation cannot be below zero: it is a measured figure minus a baseline
    # measured by the SAME profiler on a SMALLER program.  Before this arm existed, a
    # dead multi-module profiler produced exactly that and the gate reported it as a
    # BAND problem, sending the reader to enlarge N when the instrument was the thing
    # that was broken.  Transcript, PERF_PROFILE_MODULES pointed at a wrapper that
    # answers for the baseline fixture and exits 0 silently for every measured one:
    #
    #   $ cat /tmp/deadmod.sh
    #   #!/bin/sh
    #   case "$4" in *base*) exec .../test/bin/profile_modules_main "$@" ;; esac
    #   exit 0
    #   $ PERF_PROFILE_MODULES=/tmp/deadmod.sh PERF_MOD_N=100 PERF_ONLY=modules \
    #       sh test/diff_compiler_perf_scaling.sh
    #
    #   BEFORE this arm (the discovery run, PERF_MOD_N=100 whole-gate):
    #   modules  100  -168.9 MB  -168.9 MB  -168.9 MB   -   -  ** N TOO SMALL — raise PERF_MOD_N **
    #   AFTER  this arm (the PERF_ONLY=modules repro above, exit 1):
    #   modules  100   -70.4 MB   -70.4 MB   -70.4 MB   -   -  ** NEGATIVE NET ALLOC — profiler/baseline mismatch (harness bug) **
    #
    # (The two magnitudes differ because the baseline is the only figure the dead
    # wrapper still answers for and it is measured live; only its SIGN is stable, and
    # the sign is the whole signal.)
    #
    # "raise PERF_MOD_N" is the wrong instruction — the same wrong-instruction class the
    # #2150 repair already removed from this file.  With the arm in place the same run now
    # reads `** NEGATIVE NET ALLOC — profiler/baseline mismatch (harness bug) **`, which
    # names the instrument.  The arm is add-only: it can only turn a run that was already
    # failing (TOOSMALL) into a differently-worded failure, and can never quiet one, so it
    # is inside rule 2 ([W-QUIETER]).
    if [ "$aword" = "NEGATIVE" ]; then
      fail=$((fail+1))
      printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** NEGATIVE NET ALLOC — profiler/baseline mismatch (harness bug) **\n' \
        "modules" "$mn1" "$mnet1" "$mnet2" "$mnet3" "-" "-"
    elif [ "$aword" = "TOOSMALL" ]; then
      fail=$((fail+1))
      printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** N TOO SMALL — raise PERF_MOD_N **\n' \
        "modules" "$mn1" "$mnet1" "$mnet2" "$mnet3" "-" "-"
    elif [ "$aword" = "QUADRATIC" ]; then
      fail=$((fail+1))
      printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** SUPERLINEAR (ALLOC) ** (%s)\n' \
        "modules" "$mn1" "$mnet1" "$mnet2" "$mnet3" "$mar1" "$mar2" "$aclause"
    else
      pass=$((pass+1))
      printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ok\n' \
        "modules" "$mn1" "$mnet1" "$mnet2" "$mnet3" "$mar1" "$mar2"
    fi

    # ── TIME verdict: no longer ledgered (#154 PR-C), hard-gated like any un-ledgered stage:
    # r2 > THRESH (or climbing) = SUPERLINEAR, with a rule-4 SKIP below TIME_FLOOR. ──
    #
    # 🚨 THE SKIP BRANCH IS NOT REACHED AT THIS BAND, and the comment that used to stand here
    # said it was ("typecheck TIME is now UNDER the 200ms floor at the gate's N").  MEASURED,
    # min-of-5, heap pinned, N=400: 1942 ms — 9.7x the floor.  The `below` check stays because
    # it is re-decided every run from the live number, but do not read it as a description of
    # what happens: every run at PERF_MOD_N=100 grades.
    #
    # 🚦 THE ARM OF RECORD FOR #1879 IS NOT THIS ONE.  What this grade sees is real — a live
    # O(modules^2) term, confirmed on three independent channels (Ir, heap-pinned ALLOC,
    # min-of-5 TIME) — but it sits so close to the climbing clause's trip point that the
    # verdict FLAPS run to run (r2=2.43 passing by 0.02 one run, 2.67 failing the next).
    # The pin of record is `test/diff_compiler_stage_ir_scaling.sh`'s `modules:typecheck`
    # KNOWN_SLOW row: same curve, deterministic instruction counts, a ceiling that fails on
    # worsening and a fixed point that fails demanding promotion.
    #
    # ⚠️ THIS BLOCK USED TO SAY THE TIME GRADE WAS "deliberately LEFT LIVE and UNWIDENED",
    # on the [W-QUIETER] argument.  That held only while the flapping was believed local to
    # this box.  It is not: the merge queue reads the same band (r2 = 2.77, 3.21) and bounced
    # PR #2245 three times and PR #2260 once, none of which touched typecheck.  So this arm
    # is now LEDGERED instead — see KNOWN_SLOW_TIME's `modules:typecheck` block for the
    # seven-sample band and for why that is two-sided rather than a widening: over the 4.2
    # ceiling it reds on WORSENING, under TFIXED it reds DEMANDING PROMOTION, and the Ir
    # arm's hard 2.45 ceiling on the same curve is untouched.  Still do not "fix" a red here
    # by raising THRESH or flooring the stage out.
    if [ -z "$mt1" ] || [ -z "$mt2" ] || [ -z "$mt3" ]; then
      echo "           time typecheck: NO MEASUREMENT from the profiler (harness bug)"
      fail=$((fail+1))
    else
      # ⚠️ A LEDGERED STAGE MAY NOT SKIP — same contract as grade_time_stage: dropping under
      # the floor is not an absence of signal for a KNOWN_SLOW_TIME row, it IS the signal
      # that the stage got too fast to measure, which is what "fixed" looks like.
      mledger=0
      is_known_time "modules:typecheck" && mledger=1
      below="$(awk -v v="$mt3" -v f="$TIME_FLOOR" 'BEGIN{print (v + 0 < f + 0) ? 1 : 0}')"
      if [ "$below" = "1" ] && [ "$mledger" = "1" ]; then
        ms3="$(awk -v v="$mt3" 'BEGIN{printf "%.0f", v*1000}')"
        fail=$((fail+1))
        printf '           time typecheck: ** PROMOTE: now under the time floor ** %s ms at N=%s\n' "$ms3" "$mn3"
        printf '           Remove "modules:typecheck" from KNOWN_SLOW_TIME — this arm can no longer see the bug.\n'
      elif [ "$below" = "1" ]; then
        ms3="$(awk -v v="$mt3" 'BEGIN{printf "%.0f", v*1000}')"
        msf="$(awk -v f="$TIME_FLOOR" 'BEGIN{printf "%.0f", f*1000}')"
        # ⚠️ NOT "(linear since #154 PR-C)", which is what this line used to assert: the Ir
        # arm measures a live quadratic term here (stage_ir_scaling's `modules:typecheck`
        # KNOWN_SLOW row).  Below the floor this arm declines to grade; it does not certify.
        printf '           time typecheck: SKIP — too small to time-gate: %s ms at N=%s < %s ms floor (NOT a linearity claim — see stage_ir_scaling modules:typecheck)\n' "$ms3" "$mn3" "$msf"
      else
        mtr1="$(awk -v a="$mt1" -v b="$mt2" 'BEGIN{printf "%.2f", b/a}')"
        mtr2="$(awk -v a="$mt2" -v b="$mt3" 'BEGIN{printf "%.2f", b/a}')"
        # 🚨 THE FAILURE TEXT MUST NAME THE CLAUSE THAT FIRED.  It used to print
        # "(> ${THRESH}x)" unconditionally, so #1879 — which failed on the CLIMBING
        # clause at r1≈2.1 r2≈2.67, comfortably BELOW 3.0 — was told it had exceeded
        # 3.0x.  Anyone reading that line went looking for a 3x regression that did not
        # exist.  Same disjunction, same two clauses, as the ALLOC arm above.
        tverdict="$(awk -v r1="$mtr1" -v r2="$mtr2" -v th="$THRESH" -v cr="$PERF_CLIMB_R" -v cm="$PERF_CLIMB_MIN" 'BEGIN{
          climbing = (r2 > r1 * cr && r2 > cm)
          bad = (r2 > th || climbing)
          printf "%d %s", bad, ((r2 > th) ? "threshold" : (climbing ? "climbing" : "-"))
        }')"
        tbad="$(echo "$tverdict" | cut -d' ' -f1)"
        twhy="$(echo "$tverdict" | cut -d' ' -f2)"
        tclause="$(clause_of "$twhy")"
        if [ "$mledger" = "1" ]; then
          # `:-` under `set -u` (:109) — an unset ceiling would kill the gate mid-run with
          # exit 2, which run_gates.sh reads as a skip candidate. Same hazard, same guard,
          # as grade_time_stage's ledger arm.
          eval "mtceil=\${KNOWN_TCEIL_modules_typecheck:-}"
          eval "mtfixed=\${KNOWN_TFIXED_modules_typecheck:-}"
          if [ -z "$mtceil" ] || [ -z "$mtfixed" ]; then
            fail=$((fail+1))
            printf '           time typecheck: ** MALFORMED LEDGER ROW ** no KNOWN_TCEIL_modules_typecheck / KNOWN_TFIXED_modules_typecheck pair.\n'
            printf '           A ledger row without both halves cannot drain itself — that is a skip-list, not a pin.\n'
          elif [ "$(awk -v r="$mtr2" -v c="$mtceil" 'BEGIN{print (r > c) ? 1 : 0}')" = "1" ]; then
            fail=$((fail+1))
            printf '           time typecheck: ** KNOWN-SLOW, AND GOT WORSE ** r1=%s r2=%s (ceiling %s, N=%s->%s->%s)\n' \
              "$mtr1" "$mtr2" "$mtceil" "$mn1" "$mn2" "$mn3"
          elif [ "$(awk -v r="$mtr2" -v f="$mtfixed" 'BEGIN{print (r < f) ? 1 : 0}')" = "1" ]; then
            fail=$((fail+1))
            printf '           time typecheck: ** PROMOTE: now scales LINEARLY ** r2=%s (< %s, N=%s->%s->%s)\n' \
              "$mtr2" "$mtfixed" "$mn1" "$mn2" "$mn3"
            printf '           Remove "modules:typecheck" from KNOWN_SLOW_TIME — the bug is FIXED.\n'
          else
            known=$((known+1))
            printf '           time typecheck: known-slow (TIME) r1=%s r2=%s N=%s->%s->%s — ledgered (#1879), alloc is blind to it\n' \
              "$mtr1" "$mtr2" "$mn1" "$mn2" "$mn3"
          fi
        elif [ "$tbad" = "1" ]; then
          fail=$((fail+1))
          printf '           time typecheck: ** SUPERLINEAR (TIME) ** %ss -> %ss -> %ss  r1=%s r2=%s (%s)\n' \
            "$mt1" "$mt2" "$mt3" "$mtr1" "$mtr2" "$tclause"
        else
          printf '           time typecheck: ok  %ss -> %ss -> %ss  r1=%s r2=%s (min-of-%s, heap pinned)\n' \
            "$mt1" "$mt2" "$mt3" "$mtr1" "$mtr2" "$PERF_K"
        fi
      fi
    fi ;;
esac

fi   # end PERF_ONLY unit: modules
# ── OBSERVED RED: the `starimports` unit (#2160 phase 2, rule 1) ──
#
#   $ PERF_ONLY=starimports PERF_THRESH=1.2 \
#       sh test/diff_compiler_perf_scaling.sh
#   ## PERF_ONLY=[starimports] — NARROWED RUN, NOT a grading result. ##
#   starimports    400  resolve-ops 2400 -> 4800 -> 9600  (band N=400->800->1600)
#              ops  resolve: ** SUPERLINEAR (OPS) ** 2400 -> 4800 -> 9600  r1=2.00 r2=2.00 (> 1.2x, N=400->800->1600)
#   reexports      100  known-quadratic (ALLOC, intrinsic O(N^2) output) resolve-alloc
#                       103.685 MB -> 277.792 MB -> 851.383 MB  r1=2.68 r2=3.06
#                       (ceiling 4.0, band N=100->200->400) — op held at 0 (fixed)
#   exit=1
#
# The threshold is LOWERED, never the measurement changed: the shape's real
# ratios are the ~2.0 shown, and the run is red only because the bar was put
# under them. That is what proves the arm can report; it says nothing about
# this shape's scaling, and the shipped threshold is unchanged.
#
# ⚠️ THE FULL OUTPUT IS QUOTED ABOVE ON PURPOSE, AND THE `reexports` LINE IS WHY.
# This `if want starimports` block wraps `for rshape in starimports reexports`, so
# the unit named `starimports` grades TWO shapes and `reexports` has no name of its
# own: it is absent from --list-units and `PERF_ONLY=reexports` matches nothing
# (which is now a hard FAIL rather than a silent exit 0 — see the narrowing guard
# at the foot of this file). An earlier version of this record quoted only the
# middle line, which read as though the unit graded one shape. A transcript that
# elides the surprising line is worse than no transcript; if you re-record this,
# paste the whole thing.

if want starimports; then   # PERF_ONLY unit: starimports
# ── SHAPES: starimports / reexports — multi-module RESOLVE (issue #881) ────────
#
# THE HOLE #881 CLOSES: until now the multi-module driver (profile_modules_main) ran
# load -> desugar -> mark -> typecheck and DISCARDED resolve — it did not even import
# it. So resolveModulesErrorsG (frontend.resolve), a whole PRODUCTION pass with a
# known-superlinear shape (it threads `known` and resolves each import via a linear
# findExports scan; a star or a re-export fan-out is O(modules^2) in ONE module), was
# entirely off the CI map. The single-file `xref` shape covers single-file resolve; the
# `modules` shape above runs the multi-module driver but only grades typecheck. This
# adds the resolve stage to that driver and two shapes that drive resolve specifically.
#
# TWO shapes, graded on DIFFERENT metrics — and the split is the whole #925/#926 story:
#
#   starimports  — GRADED ON OP-COUNT (deterministic, one run per size, no floor/min-of-K).
#         Its resolve op-count is ~6*N (`isPubExp`'s contains per `import m.{v}` member;
#         it was 5*N before #925 converted realImport/importValueNames' membership to
#         OrdMap sets). Linear regression guard on the counted import-membership path; its
#         real findExports cost is now O(N log N) after #926's Map (was O(N^2), uncounted).
#         STAR_N=400 so op1 = 6*400 = 2400 clears the OP_FLOOR (1000) with 2.4x of
#         headroom (measured; this read "3*N ... 1200" until 2026-08-29).
#
#   reexports    — GRADED ON ALLOCATION, plus a cheap OP-REGRESSION ASSERTION. WHY NOT OP:
#         #925/#926 drained this shape's counted op to a deterministic 0 (the three cubic
#         `contains` scans became uncounted OrdMap-set membership; findExports/provenance
#         are Maps). Op-invisible => cannot be RATIO-graded (would trip the TOOSMALL guard).
#         The shape's RESIDUAL cost is an INTRINSIC O(N^2): gen_reexports is CUMULATIVE
#         (each m_i re-exports the whole accumulated set via `export import m{i-1}.*`), so
#         the exports total sum(i)=O(N^2) name entries — resolve MUST allocate O(N^2). Alloc
#         therefore can never be "linear"; it is graded with a QUADRATIC-AWARE ceiling
#         (KNOWN_ACEIL_reexports_resolve=4.0) that a super-quadratic (cubic-alloc) regression
#         breaks. Graded on the RESOLVE-STAGE alloc column ($3), not total, so the linear
#         load/desugar/mark/typecheck terms don't dilute the signal. The op arm still runs as
#         a near-free ASSERTION: a reintroduced counted-scan cubic (the exact #925 mechanism)
#         would lift resolve op OFF 0 and past the floor — caught, even though op can't be
#         ratio-graded. (Profiler-break safety: a dead profiler emits op=0 for BOTH shapes,
#         and starimports' op1<FLOOR trips its own TOOSMALL=fail — so reexports op=0 can only
#         mean "fixed", never "profiler broke".)
#
# ⚠️ ADDITIVE: the resolve stage discards its `List ResError` and does NOT transform the
# module list, so the `modules` block above (mark/typecheck) is byte-unchanged by it.
STAR_N="${PERF_STAR_N:-400}"
REEXP_N="${PERF_REEXP_N:-100}"

for rshape in starimports reexports; do
  case "$rshape" in
    starimports) rbase="$STAR_N" ;;
    reexports)   rbase="$REEXP_N" ;;
  esac
  rn1="$rbase"; rn2=$((rbase * 2)); rn3=$((rbase * 4))
  rd1="$WORK/${rshape}_$rn1"; rd2="$WORK/${rshape}_$rn2"; rd3="$WORK/${rshape}_$rn3"
  "gen_$rshape" "$rn1" "$rd1"
  "gen_$rshape" "$rn2" "$rd2"
  "gen_$rshape" "$rn3" "$rd3"

  # ONE deterministic run per size — no min-of-K, heap-pin, or floor (both arms are
  # deterministic: GC bytes and op counts). profile_modules_main does not run wasm.
  RR1="$WORK/${rshape}_rr1"; RR2="$WORK/${rshape}_rr2"; RR3="$WORK/${rshape}_rr3"
  MEDAKA_PERF=1 "$PROFILE_MODULES" "$RUNTIME" "$CORE" "$rd1/entry.mdk" "$rd1" > "$RR1" 2>&1
  MEDAKA_PERF=1 "$PROFILE_MODULES" "$RUNTIME" "$CORE" "$rd2/entry.mdk" "$rd2" > "$RR2" 2>&1
  MEDAKA_PERF=1 "$PROFILE_MODULES" "$RUNTIME" "$CORE" "$rd3/entry.mdk" "$rd3" > "$RR3" 2>&1
  ro1="$(awk -F'\t' '/^\[perf\] resolve/{print $5; exit}' "$RR1")"
  ro2="$(awk -F'\t' '/^\[perf\] resolve/{print $5; exit}' "$RR2")"
  ro3="$(awk -F'\t' '/^\[perf\] resolve/{print $5; exit}' "$RR3")"

  if [ "$rshape" = "starimports" ]; then
    op_bad=0; op_lines=""
    # An UNMEASURABLE op shape is a harness problem, never a pass. grade_op_stage SKIPs a
    # reading under OP_FLOOR WITHOUT setting op_bad, so without this guard starimports would
    # fall through to pass++ having graded NOTHING — the silent-green this suite forbids.
    rsmall="$(awk -v v="$ro1" -v f="$OP_FLOOR" 'BEGIN{print (v+0 < f+0) ? 1 : 0}')"
    if [ "$rsmall" = "1" ]; then
      fail=$((fail+1))
      printf '%-12s %8s  resolve-ops %s -> %s -> %s  ** N TOO SMALL (op1 < OP_FLOOR %s) — raise STAR_N **\n' \
        "$rshape" "$rn1" "$ro1" "$ro2" "$ro3" "$OP_FLOOR"
      continue
    fi
    grade_op_stage "$rshape" resolve "$ro1" "$ro2" "$ro3" "$rn1" "$rn2" "$rn3"
    if [ "$op_bad" = "1" ]; then
      fail=$((fail+1))
    else
      pass=$((pass+1))
    fi
    printf '%-12s %8s  resolve-ops %s -> %s -> %s  (band N=%s->%s->%s)\n' \
      "$rshape" "$rn1" "$ro1" "$ro2" "$ro3" "$rn1" "$rn2" "$rn3"
    printf '%s' "$op_lines"
    continue
  fi

  # ── reexports: OP-REGRESSION ASSERTION + ALLOCATION grade ──────────────────
  # (1) Op assertion: the #925 counted cubic drained to 0. A reintroduced counted-scan
  # cubic lifts op1 far past the floor (it was 65025 at N=50). Empty op = harness bug.
  if [ -z "$ro1" ] || [ -z "$ro2" ] || [ -z "$ro3" ]; then
    fail=$((fail+1))
    printf '%-12s %8s  ** NO OP MEASUREMENT from the profiler (harness bug — missing op column) **\n' "$rshape" "$rn1"
    continue
  fi
  opback="$(awk -v v="$ro1" -v f="$OP_FLOOR" 'BEGIN{print (v+0 >= f+0) ? 1 : 0}')"
  if [ "$opback" = "1" ]; then
    fail=$((fail+1))
    printf '%-12s %8s  ** COUNTED-SCAN CUBIC IS BACK (#925) ** resolve op %s -> %s -> %s (>= OP_FLOOR %s; the fixed state is ~0) **\n' \
      "$rshape" "$rn1" "$ro1" "$ro2" "$ro3" "$OP_FLOOR"
    continue
  fi

  # (2) Allocation grade on the RESOLVE STAGE ($3, MB). Deterministic; no floor (alloc is
  # tens-to-hundreds of MB here). Ratios vs the KNOWN_ACEIL/AFIXED alloc ledger.
  ra1="$(awk -F'\t' '/^\[perf\] resolve/{gsub(/MB/,"",$3); print $3; exit}' "$RR1")"
  ra2="$(awk -F'\t' '/^\[perf\] resolve/{gsub(/MB/,"",$3); print $3; exit}' "$RR2")"
  ra3="$(awk -F'\t' '/^\[perf\] resolve/{gsub(/MB/,"",$3); print $3; exit}' "$RR3")"
  if [ -z "$ra1" ] || [ -z "$ra2" ] || [ -z "$ra3" ]; then
    fail=$((fail+1))
    printf '%-12s %8s  ** NO RESOLVE-ALLOC MEASUREMENT (harness bug — missing $3 MB column) **\n' "$rshape" "$rn1"
    continue
  fi
  ar1="$(awk -v a="$ra1" -v b="$ra2" 'BEGIN{printf "%.2f", b/a}')"
  ar2="$(awk -v a="$ra2" -v b="$ra3" 'BEGIN{printf "%.2f", b/a}')"
  aceil="$KNOWN_ACEIL_reexports_resolve"; afixed="$KNOWN_AFIXED_reexports_resolve"
  aworse="$(awk -v r="$ar2" -v c="$aceil" 'BEGIN{print (r > c) ? 1 : 0}')"
  abetter="$(awk -v r="$ar2" -v f="$afixed" 'BEGIN{print (r < f) ? 1 : 0}')"
  if [ "$aworse" = "1" ]; then
    fail=$((fail+1))
    printf '%-12s %8s  ** SUPERLINEAR (ALLOC), re-export resolve regressed ** resolve-alloc %sMB -> %sMB -> %sMB  r1=%s r2=%s (ceiling %s, band N=%s->%s->%s)\n' \
      "$rshape" "$rn1" "$ra1" "$ra2" "$ra3" "$ar1" "$ar2" "$aceil" "$rn1" "$rn2" "$rn3"
  elif [ "$abetter" = "1" ]; then
    fail=$((fail+1))
    printf '%-12s %8s  ** PROMOTE: re-export resolve alloc now sub-quadratic ** r2=%s (< AFIXED %s) — retire the quadratic allowance (KNOWN_ACEIL_reexports_resolve)\n' \
      "$rshape" "$rn1" "$ar2" "$afixed"
  else
    known=$((known+1))
    printf '%-12s %8s  known-quadratic (ALLOC, intrinsic O(N^2) output) resolve-alloc %sMB -> %sMB -> %sMB  r1=%s r2=%s (ceiling %s, band N=%s->%s->%s) — op held at %s (fixed)\n' \
      "$rshape" "$rn1" "$ra1" "$ra2" "$ra3" "$ar1" "$ar2" "$aceil" "$rn1" "$rn2" "$rn3" "$ro1"
  fi
done

fi   # end PERF_ONLY unit: starimports
# ── OBSERVED RED: the `scoperefs` unit (#2160 phase 2, rule 1) ──
#
#   $ PERF_ONLY=scoperefs PERF_THRESH=1.2 PERF_OP_FLOOR=1 \
#       sh test/diff_compiler_perf_scaling.sh
#   ## PERF_ONLY=[scoperefs] — NARROWED RUN, NOT a grading result. ##
#   scoperefs         300  ** #78 SCOPE-SCAN QUADRATIC IS BACK ** resolve op 2 -> 2 (>= OP_FLOOR 1; the fixed state is a flat ~2). resolve.mdk scope reverted to a List `contains` **
#   scoperefs         300  ** SUPERLINEAR (EMIT-OPS) ** net 38229 -> 76329 -> 152529  r1=2.00 r2=2.00 (>= 1.2, band N=300->600->1200)
#   exit=1
#
# The threshold is LOWERED, never the measurement changed: the shape's real
# ratios are the ~2.0 shown, and the run is red only because the bar was put
# under them. That is what proves the arm can report; it says nothing about
# this shape's scaling, and the shipped threshold is unchanged.

if want scoperefs; then   # PERF_ONLY unit: scoperefs
# ── SHAPE: scoperefs — single-file RESOLVE scope-scan regression assertion (#78 P-1) ──
#
# Same "drained to ~0" contract as `reexports` above, for the residual #78 quadratic: the
# LOCAL scope membership scan (`contains n scope`). The fix backs `scope` with an OrdMap
# set (resolve.mdk's `Scope`/`scopeMem`), so the counted scan drops to a constant ~2
# resolve ops at ANY N. A reintroduced List-as-set scope makes each of the N `base` refs
# scan the N-deep scope: ~4*N^2 counted ops (640002 at N=400). So this is an ABSOLUTE
# assertion — resolve op MUST stay under OP_FLOOR — NOT a ratio (the fixed value is a flat
# constant, unratioable). Graded resolve-ONLY (gen_scoperefs_resolve drives coupled but SEPARATE
# typecheck/mangle quadratics; running it through the OP_STAGES loop would fail on those).
#
# Profiler-liveness: a dead profiler emits op=0 for every stage, which would FALSE-PASS an
# "op < FLOOR" assertion. So we witness on this shape's OWN typecheck op (huge here, and >
# FLOOR even if its coupled quadratic is someday fixed — a ~17k prelude-marking constant
# floors it): if THAT is under FLOOR the profiler produced nothing for this run and we fail
# harness, never green. (The global ops_graded==0 guard is the whole-gate backstop.)
SCOPEREFS_N="${PERF_SCOPEREFS_N:-300}"
scn1="$SCOPEREFS_N"; scn2=$((SCOPEREFS_N * 2))
scd1="$WORK/scoperefs_$scn1.mdk"; scd2="$WORK/scoperefs_$scn2.mdk"
gen_scoperefs_resolve "$scn1" "$scd1"
gen_scoperefs_resolve "$scn2" "$scd2"
SCR1="$WORK/scoperefs_r1"; SCR2="$WORK/scoperefs_r2"
MEDAKA_PERF=1 "$PROFILE" "$RUNTIME" "$CORE" "$scd1" > "$SCR1" 2>&1
MEDAKA_PERF=1 "$PROFILE" "$RUNTIME" "$CORE" "$scd2" > "$SCR2" 2>&1
scro1="$(awk -F'\t' '/^\[perf\] resolve/{print $5; exit}' "$SCR1")"
scro2="$(awk -F'\t' '/^\[perf\] resolve/{print $5; exit}' "$SCR2")"
sctc1="$(awk -F'\t' '/^\[perf\] typecheck/{print $5; exit}' "$SCR1")"
if [ -z "$scro1" ] || [ -z "$scro2" ] || [ -z "$sctc1" ]; then
  fail=$((fail+1))
  printf '%-12s %8s  ** NO OP MEASUREMENT from the profiler (harness bug — missing op column) **\n' scoperefs "$scn1"
elif [ "$(awk -v v="$sctc1" -v f="$OP_FLOOR" 'BEGIN{print (v+0 < f+0)?1:0}')" = "1" ]; then
  # liveness witness under floor => profiler produced nothing for this run
  fail=$((fail+1))
  printf '%-12s %8s  ** PROFILER LIVENESS FAILED: typecheck op %s < OP_FLOOR %s — op arm dead for this run **\n' \
    scoperefs "$scn1" "$sctc1" "$OP_FLOOR"
elif [ "$(awk -v a="$scro1" -v b="$scro2" -v f="$OP_FLOOR" 'BEGIN{print (a+0 >= f+0 || b+0 >= f+0)?1:0}')" = "1" ]; then
  fail=$((fail+1))
  printf '%-12s %8s  ** #78 SCOPE-SCAN QUADRATIC IS BACK ** resolve op %s -> %s (>= OP_FLOOR %s; the fixed state is a flat ~2). resolve.mdk scope reverted to a List `contains` **\n' \
    scoperefs "$scn1" "$scro1" "$scro2" "$OP_FLOOR"
else
  pass=$((pass+1))
  printf '%-12s %8s  resolve-ops %s -> %s  (drained; < OP_FLOOR %s — #78 scope set held; band N=%s->%s)\n' \
    scoperefs "$scn1" "$scro1" "$scro2" "$OP_FLOOR" "$scn1" "$scn2"
fi

# ── SHAPE: scoperefs — the EMIT-STAGE scope-scan grade (#1031 residual, F2) ───
#
# 🚨 WHY THIS ROW EXISTS AT ALL. #1031 ("linearize deep-scope lookup") was closed on the
# claim that all FOUR compile stages that answer "is this name bound in the local scope?"
# — resolve, typecheck, mangle, emit — had been converted from a `List`-as-a-set scan to
# an OrdMap. The pin it shipped with (`scoperefs` in test/diff_compiler_ir_scaling.sh)
# grades `medaka check` only, and `mangle`/`emit` run under `medaka build`, so TWO of the
# four claimed-fixed stages had NO grading arm anywhere and the closure rested on trust.
# It was wrong: the emit stage stayed quadratic (1,457,967 ops at N=1200, doubling ratios
# 3.57/3.88 — above threshold at BOTH doublings) because a FIFTH site,
# `emit_support.eagerVars`' bound-name accumulator, was never converted. This row is that
# stage's missing arm. A stage nobody grades is a stage whose fix nobody can check.
#
# The shape is the one already generated above (gen_scoperefs_resolve: an N-deep local scope, then
# N references to the NON-local `base`). It drives `eagerVars` exactly the way it drives
# resolve's scope test: every one of the N `base` refs misses in the local scope and so
# scans it to completion. Pre-fix that is O(N^2) counted `contains` steps inside the
# `emit` timer; post-fix `eagerVars` probes an OrdMap set (`omHasKey`, uncounted) and only
# the LINEAR per-reference emitter work remains.
#
# Graded as a baseline-netted RATIO, not an absolute "< OP_FLOOR" assertion like the
# resolve row above: emit's residual is genuinely linear-in-N (~127 counted ops per
# reference), not drained to a constant, so there is no flat value to assert. The prelude
# constant is subtracted for the reason the `emittables` block states — `emit` pays ~13.7k
# counted ops rendering core.mdk before the fixture is looked at, and left in it drags
# every ratio toward 1.0.
#
# SEEN RED — measured on this box at base ee59dec6, band N=300->600->1200, net of the
# baseline (the state this row must fail in, and does):
#     emit-ops net  218229 -> 796329 -> 3032529   r1=3.65 r2=3.81   ** QUADRATIC **
# and with emit_support.eagerVars' accumulator backed by an OrdMap set:
#     emit-ops net   38229 ->  76329 ->  152529   r1=2.00 r2=2.00   LINEAR
# The post-fix ratios are EXACTLY 2.00 (op counts are deterministic, not sampled), so the
# 3.0 threshold has 50% headroom below and the pre-fix state 22-27% above.
# (The raw emit-op figures were 232596/810696/3046896 pre-fix against a 14367 prelude
# baseline, and 51950/90050/166250 post-fix against a 13721 one — the baseline itself
# moves slightly because the prelude's own bodies pay the same scan.)
#
# Cost: two extra profiler runs (the 4N size and the baseline); N/2N are the runs the
# resolve row above already made.
scn3=$((SCOPEREFS_N * 4))
scd3="$WORK/scoperefs_$scn3.mdk"
gen_scoperefs_resolve "$scn3" "$scd3"
SCR3="$WORK/scoperefs_r3"; SCRB="$WORK/scoperefs_rb"
profile_run "$scd3" > "$SCR3"
profile_run "$BASE_FIX" > "$SCRB"
sceb="$(awk -F'\t' '$1=="[perf] emit"{print $5; exit}' "$SCRB")"
sce1="$(awk -F'\t' '$1=="[perf] emit"{print $5; exit}' "$SCR1")"
sce2="$(awk -F'\t' '$1=="[perf] emit"{print $5; exit}' "$SCR2")"
sce3="$(awk -F'\t' '$1=="[perf] emit"{print $5; exit}' "$SCR3")"
sce_bad=0
for _v in "$sceb" "$sce1" "$sce2" "$sce3"; do
  case "$_v" in ''|*[!0-9]*) sce_bad=1 ;; esac
done
if [ "$sce_bad" = "1" ]; then
  # A missing column is a HARNESS failure, never a silent pass.
  fail=$((fail+1))
  printf '%-12s %8s  ** NO EMIT-OP MEASUREMENT from the profiler (harness bug — base=%s N=%s 2N=%s 4N=%s) **\n' \
    scoperefs "$scn1" "$sceb" "$sce1" "$sce2" "$sce3"
else
  sce_verdict="$(awk -v b="$sceb" -v o1="$sce1" -v o2="$sce2" -v o3="$sce3" -v th="$THRESH" -v fl="$OP_FLOOR" 'BEGIN{
    d1=o1-b; d2=o2-b; d3=o3-b
    if (d1 < fl) { printf "%d %d %d - - TOOSMALL", d1, d2, d3; exit }
    r1=d2/d1; r2=d3/d2
    # r2 alone — the deterministic-arm rule (#2173); see grade_op_stage.
    printf "%d %d %d %.2f %.2f %s", d1, d2, d3, r1, r2, ((r2 > th) ? "QUADRATIC" : "ok") }')"
  # cut, not `set --`: this block runs at TOP LEVEL (the emittables twin is inside a
  # function), and `set --` here would clobber the script's own positional args.
  scd1n="$(printf '%s' "$sce_verdict" | cut -d' ' -f1)"
  scd2n="$(printf '%s' "$sce_verdict" | cut -d' ' -f2)"
  scd3n="$(printf '%s' "$sce_verdict" | cut -d' ' -f3)"
  scer1="$(printf '%s' "$sce_verdict" | cut -d' ' -f4)"
  scer2="$(printf '%s' "$sce_verdict" | cut -d' ' -f5)"
  sceword="$(printf '%s' "$sce_verdict" | cut -d' ' -f6)"
  if [ "$sceword" = "TOOSMALL" ]; then
    fail=$((fail+1))
    printf '%-12s %8s  ** N TOO SMALL — raise PERF_SCOPEREFS_N (net emit-op %s < OP_FLOOR %s) **\n' \
      scoperefs "$scn1" "$scd1n" "$OP_FLOOR"
  elif [ "$sceword" = "QUADRATIC" ]; then
    fail=$((fail+1))
    printf '%-12s %8s  ** SUPERLINEAR (EMIT-OPS) ** net %s -> %s -> %s  r1=%s r2=%s (>= %s, band N=%s->%s->%s)\n' \
      scoperefs "$scn1" "$scd1n" "$scd2n" "$scd3n" "$scer1" "$scer2" "$THRESH" "$scn1" "$scn2" "$scn3"
    printf '             the EMIT-stage local-scope membership test went back to a List scan.\n'
    printf '             See compiler/backend/emit_support.mdk eagerVars (the `b` accumulator must\n'
    printf '             stay an OrdMap set) — the #1031 site the original fix missed.\n'
  else
    pass=$((pass+1))
    printf '%-12s %8s  emit-ops net %s -> %s -> %s  r1=%s r2=%s  (LINEAR — #1031 emit scope set held; band N=%s->%s->%s)\n' \
      scoperefs "$scn1" "$scd1n" "$scd2n" "$scd3n" "$scer1" "$scer2" "$scn1" "$scn2" "$scn3"
  fi
fi

fi   # end PERF_ONLY unit: scoperefs
# ── OBSERVED RED: the `emittables` unit (#2160 phase 2, rule 1) ──
#
#   $ PERF_ONLY=emittables PERF_THRESH=1.2 \
#       sh test/diff_compiler_perf_scaling.sh
#   ## PERF_ONLY=[emittables] — NARROWED RUN, NOT a grading result. ##
#   emittables        250  ** SUPERLINEAR (emit-OPS) ** net 74738 -> 149488 -> 298988  r1=2.00 r2=2.00 (>= 1.2, band N=250->500->1000)
#   exit=1
#
# The threshold is LOWERED, never the measurement changed: the shape's real
# ratios are the ~2.0 shown, and the run is red only because the bar was put
# under them. That is what proves the arm can report; it says nothing about
# this shape's scaling, and the shipped threshold is unchanged.

if want emittables; then   # PERF_ONLY unit: emittables
# ── emittables — the EMITTER-TABLE op grade (issue #352) ─────────────────────
#
# Five per-program tables in the LLVM emitter (+ one in private_mangle) were `List`s
# scanned once per SITE. Every one is a PURE scan, so the TIME arm is diluted by the
# fixed prelude cost and the ALLOC arm is near-blind (compiler/AGENTS.md, THE SECOND
# RULE) — but they all run through util.lookupAssoc/util.contains, so the DETERMINISTIC
# op counter sees them exactly. This block grades the emit-stage and mangle-stage op
# ratios on the one shape that grows those tables (gen_emittables).
#
# THE PRELUDE OP CONSTANT IS SUBTRACTED HERE, and that is this file's OWN established
# rule applied to the op arm — see "⚠️ THE BASELINE MUST BE SUBTRACTED, OR THIS GATE IS
# BLIND" above (the note beside BASE_ALLOC), which is why the alloc arm has subtracted a
# baseline all along. Concretely for these two stages: `emit` pays ~20k counted ops
# rendering core.mdk before the fixture is looked at, so at N=250 that constant pulls
# THIS shape's genuine 3.5x down to 3.43 and its 3.9x down to 3.36 — raw, r1 would sit
# UNDER the 3.0 threshold. Under the both-doublings rule in force when this was
# written that alone read the bug "ok"; since #2173 the arm grades r2, so netting
# now matters for keeping r2 itself honest rather than for rescuing r1 — the
# constant depresses BOTH ratios, so the reason to subtract it is unchanged.
# (A statement about THIS shape's constant only; it says nothing about the calibration
# of any other shape or row.)
#
# SEEN RED — measured on this box against the pre-#352 emitter, band N=250->500->1000,
# net of the baseline (this is the state the block must fail in, and does):
#     emit-ops    446101 -> 1579726 -> 5909476   r1=3.54 r2=3.74   ** QUADRATIC **
#     mangle-ops   34621 ->  131746 ->  513496   r1=3.81 r2=3.90   ** QUADRATIC **
# and after indexing the tables:
#     emit-ops     85476 ->  170976 ->  341976   r1=2.00 r2=2.00   LINEAR
#     mangle-ops    3246 ->    6496 ->   12996   r1=2.00 r2=2.00   LINEAR
# The post-fix ratios are EXACTLY 2.00 (op counts are deterministic, not sampled), so
# the 3.0 threshold has 50% headroom below and the pre-fix state 18-30% above.
# (The `mangle-ops` figures above are HISTORY — that arm was retired; see the
# RETIRED note below `grade_emittables_stage emit`. Only the `emit` arm still runs.)
#
# Not folded into OP_STAGES/SHAPES on purpose: `emit` is not an OP_STAGES entry (adding
# it would grade every other shape's emit-op ratio too, which is a different change),
# and this shape is the only one whose numbers mean anything for these tables.
EMITTABLES_N="${PERF_EMITTABLES_N:-250}"
emn1="$EMITTABLES_N"; emn2=$((EMITTABLES_N * 2)); emn3=$((EMITTABLES_N * 4))
emf1="$WORK/emittables_$emn1.mdk"; emf2="$WORK/emittables_$emn2.mdk"; emf3="$WORK/emittables_$emn3.mdk"
gen_emittables "$emn1" "$emf1"; gen_emittables "$emn2" "$emf2"; gen_emittables "$emn3" "$emf3"
EMR1="$WORK/emittables_r1"; EMR2="$WORK/emittables_r2"; EMR3="$WORK/emittables_r3"
EMRB="$WORK/emittables_rb"
profile_run "$emf1" > "$EMR1"; profile_run "$emf2" > "$EMR2"; profile_run "$emf3" > "$EMR3"
profile_run "$BASE_FIX" > "$EMRB"
# One stage's net-op ratios, graded. Mutates the caller's fail/pass counters.
grade_emittables_stage() {
  _st="$1"
  _b="$(awk -F'\t' -v s="[perf] $_st" '$1==s{print $5; exit}' "$EMRB")"
  _o1="$(awk -F'\t' -v s="[perf] $_st" '$1==s{print $5; exit}' "$EMR1")"
  _o2="$(awk -F'\t' -v s="[perf] $_st" '$1==s{print $5; exit}' "$EMR2")"
  _o3="$(awk -F'\t' -v s="[perf] $_st" '$1==s{print $5; exit}' "$EMR3")"
  # A missing column is a HARNESS failure, never a silent pass.
  for _v in "$_b" "$_o1" "$_o2" "$_o3"; do
    case "$_v" in
      ''|*[!0-9]*)
        fail=$((fail+1))
        printf '%-12s %8s  ** NO %s-OP MEASUREMENT from the profiler (harness bug — base=%s N=%s 2N=%s 4N=%s) **\n' \
          emittables "$emn1" "$_st" "$_b" "$_o1" "$_o2" "$_o3"
        return ;;
    esac
  done
  _verdict="$(awk -v b="$_b" -v o1="$_o1" -v o2="$_o2" -v o3="$_o3" -v th="$THRESH" -v fl="$OP_FLOOR" 'BEGIN{
    d1=o1-b; d2=o2-b; d3=o3-b
    if (d1 < fl) { printf "%d %d %d - - TOOSMALL", d1, d2, d3; exit }
    r1=d2/d1; r2=d3/d2
    # r2 alone — the deterministic-arm rule (#2173); see grade_op_stage.
    printf "%d %d %d %.2f %.2f %s", d1, d2, d3, r1, r2, ((r2 > th) ? "QUADRATIC" : "ok") }')"
  set -- $_verdict
  if [ "$6" = "TOOSMALL" ]; then
    fail=$((fail+1))
    printf '%-12s %8s  ** N TOO SMALL — raise PERF_EMITTABLES_N (net %s-op %s < OP_FLOOR %s) **\n' \
      emittables "$emn1" "$_st" "$1" "$OP_FLOOR"
  elif [ "$6" = "QUADRATIC" ]; then
    fail=$((fail+1))
    printf '%-12s %8s  ** SUPERLINEAR (%s-OPS) ** net %s -> %s -> %s  r1=%s r2=%s (>= %s, band N=%s->%s->%s)\n' \
      emittables "$emn1" "$_st" "$1" "$2" "$3" "$4" "$5" "$THRESH" "$emn1" "$emn2" "$emn3"
    printf '             an emitter lookup TABLE went back to a List scan — recFields / ctorType /\n'
    printf '             ctorFieldTypes / ctorsOfType / pubFnNames (issue #352). See llvm_emit.mdk\n'
    printf '             installCtorTypeMap + installRecFieldIndex, private_mangle.mdk pubFnNames.\n'
  else
    pass=$((pass+1))
    printf '%-12s %8s  %s-ops net %s -> %s -> %s  r1=%s r2=%s  (LINEAR — #352 tables indexed; band N=%s->%s->%s)\n' \
      emittables "$emn1" "$_st" "$1" "$2" "$3" "$4" "$5" "$emn1" "$emn2" "$emn3"
  fi
}
grade_emittables_stage emit
# ── RETIRED 2026-08-27: `grade_emittables_stage mangle` ──────────────────────
#
# There used to be a second call here grading the MANGLE stage's net op ratio on
# this same shape. It was retired because its counted-op total on `gen_emittables`
# is now STRUCTURALLY ZERO at every N — not small-but-below-OP_FLOOR. Measured on
# this box at sprint/depth-linearity b32b083f, with the gate's own gen_emittables
# and profile_run: mangle net-ops = 0 at N=250, 500, 1000 AND 4000 (16x the default
# band). No value of PERF_EMITTABLES_N can clear OP_FLOOR against an exact 0.
#
# WHY it went to zero, and why that is a MEASUREMENT gap and not a regression:
# `[perf] mangle` is an opSnap() delta around mangleUnits (entries/profile_main.mdk),
# and `opBump` (support/opcount.mdk) fires at exactly two primitives — util.contains
# and util.lookupAssoc. private_mangle.mdk imports only frontend.ast, support.util
# and support.ordmap; neither ast nor ordmap imports support.opcount at all, and
# private_mangle imports `contains` but not `lookupAssoc`. #1031's slice
# (54f54bef) converted renameScoped's `bound` accumulator from `List String` +
# `contains n bound` to `OrdMap Unit` + `omHasKey n bound`, and omHasKey is
# UNCOUNTED. That removed the only counted call the mangle stage made on this shape.
# The one surviving `contains` in private_mangle (bareCtorMemberEntry) fires only on
# `DUse` import decls naming constructors, and gen_emittables emits no imports.
#
# 🚨 THE TABLE THIS ROW WATCHED IS NOT UNFIXED. private_mangle's `pubFnNames` is
# still OrdMap-indexed (omHasKey) — in fact it ALREADY was before #1031, which means
# the pre-#1031 "mangle-ops 3246 -> 6496 -> 12996 LINEAR" reading was never measuring
# pubFnNames either: the whole 3246 was renameScoped's per-function-params `contains`
# scan (~13 counted steps per generated `sI`) that this row was incidentally
# piggy-backing on. What is lost by retiring the row is a mangle-stage op grade that
# never actually existed; what is NOT lost is any live coverage of a real quadratic.
#
# REPLACEMENT COVERAGE WAS OWED WHEN THIS WAS WRITTEN. IT HAS SINCE LANDED, in a
# different gate and on a different instrument — #2099's headline ("the mangle stage
# is now graded by nothing") is TRUE OF THIS FILE and FALSE OF THE TREE, and the tree
# wins. `test/diff_compiler_stage_ir_scaling.sh` grades
# `mangle=mdk_backend_private_mangle__mangleUnits` as a first-class row in STAGE_SYMS
# (added by sprint backend-breadth, slice S-build-ir-arm, 7d644eff). Re-derived on
# this box 2026-08-28 by running that gate whole — it grades mangle on EVERY
# single-module shape, with real net Ir, not a SKIP under its netting guard:
#
#   match       mangle  net  8431969 -> 18587297 ->  40424584   r1=2.204 r2=2.175
#   xref        mangle  net 11067307 -> 24316786 ->  52531899   r1=2.197 r2=2.160
#   vchain      mangle  net 10754970 -> 23595360 ->  51072163   r1=2.194 r2=2.165
#   constrained mangle  net 29643478 -> 63853290 -> 136927375   r1=2.154 r2=2.144
#   wideiface   mangle  net  1480470 ->  3331209 ->   7325993   r1=2.250 r2=2.199
#   PASS: 60 stage-ratio(s) graded (1 ledgered) ...
#
# ⚠️ Those RAW NETS are readings, not constants. Callgrind is deterministic PER
# BINARY, not across builds: any unrelated compiler change shifts every net by a
# constant factor, and re-deriving this table after a rebuild will not reproduce
# the digits. The RATIOS are what is stable (they held to 3 decimals across three
# back-to-back runs on one binary). Compare ratios; treat a net that moved as
# expected unless its ratio moved with it.
#
# Callgrind counts EVERY instruction the stage executes, so it does not care whether
# the scan runs through a counted `util.contains` or an uncounted `omHasKey` — which
# is precisely the failure mode that killed the op row. A `pubFnNames` revert to a
# List-as-a-set would show up there as a ratio, with no `opBump`
# in `support/ordmap.mdk` required. That compiler-source change is therefore NOT owed for
# coverage OF THAT TABLE; it would only be worth doing to give the OP arm back a general
# ability it has structurally lost.
#
# ⚠️ THE CLAIM STOPS AT `pubFnNames`, AND THE REMAINDER IS A REAL HOLE. It holds because
# `pubFnNames` is keyed on the number of EXPORTED FUNCTIONS, which is exactly the quantity
# all five stage_ir shapes scale. It does NOT extend to `renameScoped`'s per-scope `bound`
# scan: those five shapes scale TOP-LEVEL DECLARATIONS with 0-1 locals apiece, so that scan
# is O(1) per function however large N grows, and a List revert there reads LINEAR. The one
# shape that scales a single scope's depth is `scoperefs` — and it lives in
# diff_compiler_ir_scaling.sh, which measures `medaka check`, a verb that never runs mangle.
# So `renameScoped`'s deep-scope path has NO mangle-stage grade on ANY shape either gate
# runs. Smaller than #2099's headline (which said the whole stage was ungraded), but not
# nothing: do not read a green mangle row as covering it.
#
# ⚠️ WHAT REMAINS TRUE IN #2099, and is a property of the op arm rather than of this
# row: `opBump` fires at exactly two primitives, so the op arm counts List-scan steps
# and only those, and EVERY #1031/#352/#242-class fix drives its count toward zero.
# The op arm's coverage of a path dies exactly when that path is fixed. Read a green
# op row accordingly; `support/util.mdk`'s own `dedupBy` comment says the same thing
# from the other side.

fi   # end PERF_ONLY unit: emittables
# ── OBSERVED RED: the `matchlits` unit (#2160 phase 2, rule 1) ──
#
#   $ PERF_ONLY=matchlits PERF_DEEP=1 PERF_THRESH=1.2 \
#       sh test/diff_compiler_perf_scaling.sh
#   ## PERF_ONLY=[matchlits] — NARROWED RUN, NOT a grading result. ##
#   matchlits        1000  ** SUPERLINEAR (typecheck-alloc) ** net 18.4 -> 36.7 -> 73.3 MB  r1=2.00 r2=2.00 (r2 > 1.2x) — exhaust literal-matrix quadratic (specLitRow `Eq Lit`? see #988)
#   exit=1
#
# The threshold is LOWERED, never the measurement changed: the shape's real
# ratios are the ~2.0 shown, and the run is red only because the bar was put
# under them. That is what proves the arm can report; it says nothing about
# this shape's scaling, and the shipped threshold is unchanged.

if want matchlits; then   # PERF_ONLY unit: matchlits
# ── matchlits — EXHAUSTIVENESS over a wide LITERAL match (issue #988) ─────────
# The literal sibling of the main-loop `match` shape. It grades the TYPECHECK-STAGE
# net allocation, NOT the total-alloc arm: exhaust's literal-pattern-matrix rescan
# (specializeLit/specLitRow) allocated O(arms^2) via the derived `Eq Lit`, but the
# wide match's LINEAR emit cost dilutes that quadratic below the total-alloc ceiling
# (measured: total r2 ~2.5 even at N=4000, while the typecheck-STAGE net r2 is ~3.65).
# So this block reads the typecheck stage's own [perf] alloc figure and grades ITS
# ratio — the same per-stage discipline as the eval_scaling gate, applied to the
# stage exhaust actually runs in. #970/#978 fixed the identical root cause in the
# Core-IR LOWERING path (core_ir_lower); the untyped eval_scaling `bigmatch_lits`
# shape drives that lowering but NEVER runs typecheck/exhaust, so this path was
# ungated until now.
#
# DEEP-only (like manydefs): it costs three full-pipeline runs at 1000/2000/4000 and
# adds no per-PR cost. Alloc is deterministic, so one run per size suffices (no
# min-of-K / heap-pin / floor). Reverting #988's `litEq` to `l2 == l` reddens it
# (net typecheck r1 3.40 r2 3.65 >= 3.0); the fixed state reads r1 1.99 r2 2.00.
if [ "$PERF_DEEP" = "1" ]; then
  mln1="$MATCHLITS_N"; mln2=$((MATCHLITS_N * 2)); mln3=$((MATCHLITS_N * 4))
  mlf1="$WORK/matchlits_$mln1.mdk"; mlf2="$WORK/matchlits_$mln2.mdk"; mlf3="$WORK/matchlits_$mln3.mdk"
  gen_matchlits "$mln1" "$mlf1"; gen_matchlits "$mln2" "$mlf2"; gen_matchlits "$mln3" "$mlf3"
  MLR1="$WORK/matchlits_r1"; MLR2="$WORK/matchlits_r2"; MLR3="$WORK/matchlits_r3"
  profile_run "$mlf1" > "$MLR1"; profile_run "$mlf2" > "$MLR2"; profile_run "$mlf3" > "$MLR3"
  # baseline typecheck-stage alloc: the fixed prelude-typecheck constant (~7 MB), which
  # dominates the raw figure at small N. Same BASE_FIX ("main = println 1") the total
  # arm uses; subtracting it is what makes the exhaust quadratic legible (see the
  # baseline note above).
  BASE_TC="$WORK/_baseline_tc"; profile_run "$BASE_FIX" > "$BASE_TC"
  mlb="$(tc_alloc_from "$BASE_TC")"
  mla1="$(tc_alloc_from "$MLR1")"; mla2="$(tc_alloc_from "$MLR2")"; mla3="$(tc_alloc_from "$MLR3")"
  # A missing figure is a HARNESS failure, never a silent pass (the silent-green class
  # this suite is built against). Check each value individually.
  ml_bad=0
  for _v in "$mlb" "$mla1" "$mla2" "$mla3"; do
    case "$_v" in ''|*[!0-9.]*) ml_bad=1 ;; esac
  done
  if [ "$ml_bad" = "1" ]; then
    fail=$((fail+1))
    printf '%-12s %8s  ** NO TYPECHECK-ALLOC MEASUREMENT from the profiler (harness bug — base=%s N=%s 2N=%s 4N=%s) **\n' \
      matchlits "$mln1" "$mlb" "$mla1" "$mla2" "$mla3"
  else
    ml_verdict="$(awk -v a1="$mla1" -v a2="$mla2" -v a3="$mla3" -v b="$mlb" -v th="$THRESH" -v cr="$PERF_CLIMB_R" -v cm="$PERF_CLIMB_MIN" 'BEGIN{
      d1=a1-b; d2=a2-b; d3=a3-b
      if (d1 < 1.0) { printf "%.1f %.1f %.1f - - TOOSMALL", d1, d2, d3; exit }
      r1=d2/d1; r2=d3/d2
      climbing=(r2 > r1 * cr && r2 > cm)
      why = (r2 > th) ? "threshold" : (climbing ? "climbing" : "-")
      printf "%.1f %.1f %.1f %.2f %.2f %s %s", d1, d2, d3, r1, r2, ((r2 > th || climbing) ? "QUADRATIC" : "ok"), why }')"
    md1="$(printf '%s' "$ml_verdict" | cut -d' ' -f1)"; md2="$(printf '%s' "$ml_verdict" | cut -d' ' -f2)"
    md3="$(printf '%s' "$ml_verdict" | cut -d' ' -f3)"; mr1="$(printf '%s' "$ml_verdict" | cut -d' ' -f4)"
    mr2="$(printf '%s' "$ml_verdict" | cut -d' ' -f5)"; mword="$(printf '%s' "$ml_verdict" | cut -d' ' -f6)"
    mlclause="$(clause_of "$(printf '%s' "$ml_verdict" | cut -d' ' -f7)")"
    if [ "$mword" = "TOOSMALL" ]; then
      fail=$((fail+1))
      printf '%-12s %8s  ** N TOO SMALL — raise PERF_MATCHLITS_N (net typecheck-alloc %s MB < 1.0) **\n' matchlits "$mln1" "$md1"
    elif [ "$mword" = "QUADRATIC" ]; then
      fail=$((fail+1))
      printf '%-12s %8s  ** SUPERLINEAR (typecheck-alloc) ** net %s -> %s -> %s MB  r1=%s r2=%s (%s) — exhaust literal-matrix quadratic (specLitRow `Eq Lit`? see #988)\n' \
        matchlits "$mln1" "$md1" "$md2" "$md3" "$mr1" "$mr2" "$mlclause"
    else
      pass=$((pass+1))
      printf '%-12s %8s  typecheck-alloc net %s -> %s -> %s MB  r1=%s r2=%s  (LINEAR — exhaust litEq alloc-free, #988; band N=%s->%s->%s)\n' \
        matchlits "$mln1" "$md1" "$md2" "$md3" "$mr1" "$mr2" "$mln1" "$mln2" "$mln3"
    fi
  fi
else
  echo "NOTE: QUICK mode — matchlits SKIPPED (DEEP-only, #988 exhaust literal-matrix alloc detector). Runs in nightly.yml."
fi

fi   # end PERF_ONLY unit: matchlits
printf -- '---------------------------------------------------------------------\n'
printf '%d ok, %d known-superlinear (ledgered), %d regressed (threshold %sx per doubling)\n' "$pass" "$known" "$fail" "$THRESH"

printf 'backend TIME arm (issue #359): %d native lower/emit stage-ratios graded\n' "$backend_graded"
# The wasm arm is NOT counted by backend_graded (see that counter's note: wasm-emit
# clears the floor on most shapes, so counting it would make the counter unfailable).
# Its coverage guarantee is the KNOWN_SLOW_TIME ledger instead — `xref:wasm-emit` is
# graded on every green run or the gate is red — so report it rather than leaving the
# arm unmentioned.
printf 'backend TIME arm (issue #359): wasm graded via the xref:wasm-emit ledger row\n'
printf 'OP-COUNT arm (issue #884): %d per-stage op-ratios graded (deterministic, no floor)\n' "$ops_graded"

# Never exit 0 having measured nothing.
#
# ⚠️ THE NEXT THREE GUARDS ASSERT SCOPE, NOT HEALTH. Each says "an arm graded
# nothing, therefore it is dead" — true for a whole run, false for a run that was
# deliberately narrowed, where an ungraded arm is the point. Under PERF_ONLY they
# would report breakage on a scope decision the operator just made, so they are
# skipped and the skip is printed. PERF_ONLY unset leaves all three exactly as
# they were, so the knob cannot make a real run quieter ([W-QUIETER]).
if [ -n "$PERF_ONLY" ]; then
  # ⚠️ THE THREE SCOPE GUARDS ARE SKIPPED UNDER NARROWING, BUT "GRADED NOTHING AT
  # ALL" IS NOT A SCOPE DECISION — it is a typo, or a unit that no longer exists,
  # and it USED TO EXIT 0. `PERF_ONLY=bogus` printed "0 ok, 0 known-superlinear, 0
  # regressed" and returned success, which is a green that proved nothing: the
  # exact failure mode this gate's own #2160 sweep exists to remove. The sibling
  # knob in test/diff_compiler_ir_scaling.sh (IR_ONLY) has always failed here and
  # is the correct model. There is no legitimate narrowed run that matches no unit.
  #
  # OBSERVED RED (#2160 phase 2, this box):
  #   $ PERF_ONLY=bogus sh test/diff_compiler_perf_scaling.sh
  #   FAIL: PERF_ONLY=[bogus] matched no unit — this run graded nothing.
  #   exit=1
  if [ $((pass + known + fail)) -eq 0 ]; then
    echo "FAIL: PERF_ONLY=[$PERF_ONLY] matched no unit — this run graded nothing."
    echo "      Check the names against: sh $0 --list-units"
    exit 1
  fi
  echo "NOTE: PERF_ONLY=[$PERF_ONLY] — the measured-nothing / op-arm-dead / backend-arm-dead"
  echo "      coverage guards were SKIPPED. This run graded only the named units."
else
# ── #2160 phase 2 swept all three of these. Two are OBSERVED RED; one is a HOLE
# and is reported as one rather than papered over.
#
# 1. measured-nothing (the line directly below) — A HOLE. No add-only knob can
#    empty SHAPES, and every shape in it produces a row, so `pass+known+fail` can
#    never reach 0 from the outside. Reaching it would mean editing the gate,
#    which is the one thing the sweep is not allowed to do (widening or gutting a
#    gate to watch it fail proves nothing about the shipped gate). It stays as a
#    structural assertion: cheap, and correct if the shapes list is ever emptied
#    by an edit. Do NOT "fix" this by adding a SHAPES override knob — that would
#    be a way to make a real run measure nothing, i.e. [W-QUIETER] with extra
#    steps.
#
# 2. ops_graded == 0 — OBSERVED RED, and it took TWO knobs, which is itself the
#    finding. Raising the op floor alone is NOT enough:
#
#      $ PERF_OP_FLOOR=999999999 sh test/diff_compiler_perf_scaling.sh
#      OP-COUNT arm (issue #884): 1 per-stage op-ratios graded    <- not 0
#
#    ⚠️ The stray 1 is the `widerecords` resolve-op arm, which increments
#    ops_graded WITHOUT consulting OP_FLOOR (see its block). So this guard —
#    whose stated contract is "0 means the arm broke" — cannot read 0 while that
#    arm reports, no matter how dead every floor-checked reading is. Driving
#    widerecords red as well makes it `continue` before the increment, which is
#    the only route to 0 that does not edit the gate:
#
#      $ PERF_OP_FLOOR=999999999 PERF_THRESH=1.2 sh test/diff_compiler_perf_scaling.sh
#      OP-COUNT arm (issue #884): 0 per-stage op-ratios graded
#      FAIL: no stage was graded on OP COUNT — the #884 op arm is dead.
#      exit=1
#
#    The guard itself is sound and is now observed. The narrowness above is
#    recorded here rather than "fixed": counting widerecords is CORRECT (it is a
#    graded op ratio), and giving it a floor check is a change to what the gate
#    measures, not to what it reports — out of scope for an honesty sweep, and
#    worth its own decision.
#
# 3. backend_graded == 0 — OBSERVED RED, one knob:
#
#      $ PERF_TIME_FLOOR=999 sh test/diff_compiler_perf_scaling.sh
#      backend TIME arm (issue #359): 0 native lower/emit stage-ratios graded
#      FAIL: no backend stage (lower/emit) was graded on TIME — the #359 blind spot is back.
#            Every lower/emit reading fell under the 999s TIME_FLOOR. ...
#            Do NOT 'fix' this by lowering the floor: raise N until the stage is timeable.
#      exit=1
[ $((pass + known + fail)) -gt 0 ] || { echo "FAIL: the gate measured no shapes at all"; exit 1; }

# Never exit 0 having graded no OP stage — the #884 analogue of the backend guard. If
# every OP_STAGES reading fell under OP_FLOOR (or the profiler stopped emitting the 5th
# column, so every field-5 read was empty), the op arm is silently dead while the gate
# still exits 0. `mark` alone guarantees a non-zero count on the `marksweep` money-shot,
# so 0 means the arm broke, not that the shapes are clean.
if [ "$ops_graded" -eq 0 ]; then
  echo "FAIL: no stage was graded on OP COUNT — the #884 op arm is dead."
  echo "      Every OP_STAGES reading fell under OP_FLOOR (${OP_FLOOR}). Either the profiler"
  echo "      stopped emitting the tab-delimited op column (timer.mdk:emitPhaseAO /"
  echo "      opcount.mdk), setOpCounting is not being called, or the shapes shrank."
  exit 1
fi

# Never exit 0 having graded no BACKEND stage — that is precisely issue #359, and it
# would come back SILENTLY (every lower/emit dropping under TIME_FLOOR reads as a
# loud-but-harmless SKIP per stage, yet in aggregate it means the O(n^2) detector is
# once again blind to the entire second half of the pipeline). N==0 is a FAILURE.
if [ "$backend_graded" -eq 0 ]; then
  echo "FAIL: no backend stage (lower/emit) was graded on TIME — the #359 blind spot is back."
  echo "      Every lower/emit reading fell under the ${TIME_FLOOR}s TIME_FLOOR. Either the"
  echo "      profiler stopped emitting [perf] lower / [perf] emit, or the shapes shrank."
  echo "      Do NOT 'fix' this by lowering the floor: raise N until the stage is timeable."
  exit 1
fi
fi   # end of the PERF_ONLY coverage-guard skip

if [ "$fail" -gt 0 ]; then
  cat <<EOF

A shape grew faster than ${THRESH}x per doubling of input size, in ALLOCATION, in
per-stage TIME, or in per-stage OP COUNT. That is the signature of a SUPERLINEAR
(probably QUADRATIC) algorithm.

If the failure says SUPERLINEAR (TIME) or SUPERLINEAR (OPS) while allocation reads
"ok", that is not a contradiction — it is the point. A pure O(n^2) TRAVERSAL (scan a
list / linear-search a scope once per lookup) costs time and op-count quadratically
while allocating nothing extra, so allocation cannot see it. SUPERLINEAR (OPS) further
catches it on the SMALL stages (mark, and desugar the day it starts scanning) whose absolute time never
clears the 200ms floor, where the TIME arm grades nothing at all. All three signals are
real; none subsumes the others.

  linear      ~2.0x      n log n  ~2.1x      QUADRATIC  ~4.0x

The pattern found every time so far: a List being scanned / elem-checked /
lookup-ed / rebuilt ONCE PER ELEMENT. Note that \`xs ++ [x]\` inside a fold is
O(n^2) all by itself (list append is O(n)).

To localize it:
  MEDAKA_PERF=1 test/bin/profile_main stdlib/runtime.mdk stdlib/core.mdk <fixture>
gives per-STAGE time and allocation. Then \`perf\` (apt-get install linux-perf) to
name the hot symbol. USE DWARF CALL GRAPHS -- \`perf record --call-graph dwarf,16384\`
-- the emitted LLVM carries CFI, so unwinding produces clean stacks. (This message
used to say call graphs were "unusable" and to use flat counts only. That was WRONG:
it described frame-pointer unwinding, and it cost an agent a wrong turn. Flat counts
are still the right axis for a NON-allocating quadratic -- a hot symbol that allocates
nothing is not a false positive, it is the bug class allocation profiling cannot see.)

WARNING: \`whenL False (expensiveCall ...)\` is NOT a stub -- Medaka is strict, so
the argument still evaluates. To stub something out, actually remove the call.
EOF
  exit 1
fi
exit 0
