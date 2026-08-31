#!/bin/sh
# diff_compiler_stage_ir_scaling.sh — the DETERMINISTIC superlinearity detector for
# the BUILD-PATH stages (lower / emit / mangle / dce / trmc), the single-file
# FRONTEND stages (parse / exhaust / desugar / resolve / mark / typecheck), and the
# MULTI-MODULE frontend stages (parse / load / desugar / resolve / mark /
# typecheck), measured in PER-STAGE Callgrind INSTRUCTION COUNTS.
#
# The single-file frontend rows ride the SAME runs the backend rows already pay for
# — see "THE FRONTEND STAGES, AND WHY THEY ARE FREE" below before adding a frontend
# SHAPE. The multi-module rows do NOT: they are a second DRIVER
# (profile_modules_main) over a directory corpus and cost 4 more callgrind runs —
# see "THE MULTI-MODULE ARM", which also carries a silent-false-pass trap on the
# multi-module `parse` symbol that a future editor must not undo.
#
# ⚠️ READ THIS FIRST: WHY THIS IS NOT diff_compiler_ir_scaling.sh WITH A `build` ARM.
#
# The obvious cheap move — run `medaka build` under cachegrind and net a floor out,
# exactly as diff_compiler_ir_scaling.sh does for `medaka check` — was BUILT AND
# MEASURED, and it does not work. Whole-process `Ir` on a build is dominated by a
# large FIXED cost (typecheck + the ~1.9 s prelude emit), and that constant dilutes
# any stage-local ratio below the affordable N band. Measured on this box, on the
# `match` shape at issue #408's OWN band (1000/2000/4000), through the same netting
# and the same 3.0 threshold this file uses:
#
#     whole-process `medaka build` Ir ....... r1=2.028  r2=2.026   — DEAD LINEAR
#     stage-local `lower` Ir, same shape .... r1=3.328  r2=3.640   — RED
#
# (Those are the readings from the tree this gate was born on, BEFORE #408 was
# fixed. They are kept verbatim because they are the measurement that justifies
# the gate's shape; `lower` on `match` now reads r1 2.302 r2 2.240.)
#
# The defect is the same defect in both rows. One metric sees it; the other cannot.
# A synthetic O(table) scan planted in llvm_emit's `ctorTypeOf` moved the
# whole-process total by ~6 000 Ir out of 5.8e9 — i.e. the whole-process arm's
# sensitivity floor is ~18x past the largest N a per-PR gate can afford. So:
#
# 🚨 DO NOT "SIMPLIFY" THIS GATE INTO A `build` MODE ON ir_scaling.sh. That shape was
# tried, measured, and refused. The dilution is a property of the metric, not of the
# band or of the shapes.
#
# ── THE METRIC: INCLUSIVE Ir OF A NAMED STAGE-ENTRY SYMBOL ───────────────────
#
# One `callgrind` run of test/bin/profile_main per (shape, N) yields, for EVERY
# stage at once, that stage's own INCLUSIVE instruction count — read out of
# `callgrind_annotate --inclusive=yes` by the Medaka-mangled symbol of the function
# the profiler calls to run that stage (STAGE_SYMS below). Cross-validated against
# the alternative shape, `callgrind --collect-atstart=no --toggle-collect=<symbol>`,
# on `match` at N=1000: toggle-collect read 584 813 946 and the inclusive-annotate
# read 584 813 919 — 27 Ir apart out of 5.8e8. Annotate is used because ONE run
# grades every stage, where toggle-collect needs one run per stage.
#
# Both of the risks the shape was flagged with are answered by measurement, not by
# argument:
#   * The mangled symbol scheme (`mdk_<module_path>__<name>`,
#     compiler/backend/private_mangle.mdk) is stable and readable from `nm`; and a
#     symbol that STOPS resolving is a HARD FAIL here (see `stage_ir`), never a
#     silent green — that is the whole reason a missing reading is not treated as 0.
#   * Collection survives the 256 MB GC worker pthread the runtime runs the whole
#     program on (`GC_pthread_create`, runtime/medaka_rt.c). Both readings above
#     were taken on that thread.
#
# ⚠️ THE PROFILER IS NOT `medaka build`. profile_main is single-file: no loader, no
# multi-module link, no clang. It DOES run dceFilter exactly as the real build
# driver does, so what reaches the backend is what a real build's backend sees, and
# these stage entry points are the same functions the emit drivers call. Read a
# ratio here as a statement about the STAGE, not about end-to-end build wall time.
#
# ── DETERMINISM ──────────────────────────────────────────────────────────────
#
# Measured here, 3 identical runs, `match` at N=250, heap pinned:
#     lower  96 578 910 / 96 580 677 / 96 578 919   spread 1 767 Ir = 1.8e-5
#     emit  626 652 386 / 626 657 388 / 626 652 458  spread 5 002 Ir = 8.0e-6
# ~5 significant digits — four orders below the signal a 3.0 threshold grades. So
# there is NO min-of-K here and there must not be one.
#
# 🚨 EVERY MEASURED RUN PINS THE GC HEAP: GC_INITIAL_HEAP_SIZE=2147483648, the same
# pin diff_compiler_ir_scaling.sh applies for the same reason (the GC's heap-resize
# step is bimodal and lands on the floor term this gate subtracts).
#
# ── NETTING ──────────────────────────────────────────────────────────────────
#
# `lowerProgramEmit`/`emitProgram` process the PRELUDE as well as the target, so a
# stage's raw count carries a large fixed term (emit's floor is 5.9e8 Ir — bigger
# than the whole shape-attributable cost at N=1000). Netting is therefore still
# required, per stage:
#
#     net(N) = stage_Ir(shape at N) - stage_Ir(shape at FLOOR_N)
#     r1 = net(2N)/net(N)      r2 = net(4N)/net(2N)
#
# 🚨 THE FLOOR COMES FROM THE SHAPE'S OWN GENERATOR at a negligible N — never a
# shared baseline. Same rule, and the same reasoning, as
# diff_compiler_ir_scaling.sh's floor block; do not reintroduce a shared baseline.
#
# ── THE THRESHOLD ────────────────────────────────────────────────────────────
#
# 3.0 per doubling, graded on r2 ALONE, exactly as diff_compiler_ir_scaling.sh
# and (since #2173) diff_compiler_perf_scaling.sh's DETERMINISTIC arms. Three
# gates, one number and one rule; do not invent a fourth.
#
# ⚠️ THIS PARAGRAPH USED TO SAY "BOTH doublings, exactly as" those two gates —
# and by 2026-08-29 that sentence was false on BOTH halves: this gate did require
# both, and neither of the other two did any more. It is corrected here rather
# than footnoted, because a stale statement of the rule in the file that DEFINES
# the rule is worse than none. The conjunct is wrong on a deterministic
# instrument for the reason spelled out at the `over=` expression in grade_shape,
# and the enumeration that made the change safe is recorded there too.
#
# ⚠️ perf_scaling's WALL-CLOCK arm still requires both doublings, legitimately —
# that arm is noisy and the second doubling is its confirmation. Do not "unify"
# it with this rule.
#     linear 2.0 | n log n ~2.1 | n^1.5 2.83 | QUADRATIC 4.0
# MEASURED margins at the shipped bands, this box, on this tree:
#     xref:lower   r1 2.095  r2 2.106      xref:emit   r1 2.128  r2 2.152
#     match:lower  r1 2.302  r2 2.240      match:emit  r1 2.108  r2 2.156
#     vchain:lower r1 2.109  r2 2.111      vchain:emit r1 2.155  r2 2.150
#
# ── THE SHAPES ───────────────────────────────────────────────────────────────
#
# Generators are transcribed verbatim from test/diff_compiler_perf_scaling.sh and
# live in this file, NOT in a fixture directory — a fixture dir is a shared corpus
# and adding to one enrols this gate in others it never named (AGENTS.md
# [T-SHARED-CORPUS]).
#
#   match — one data decl with N constructors and one N-arm match over it, ROOTED by
#           `main` so DCE keeps it. Issue #408's own shape. THE PIN.
#   xref  — N chained functions, `main` calling the head. The DISCRIMINATOR: the
#           same stages, the same machinery, a shape with no backend quadratic in
#           it, so a gate that always fired would be caught here.
#   vchain— N chained nullary VALUE globals (`g_i = g_{i-1} + 1`), rooted by `main`.
#           Issue #1030's shape, and NEITHER of the two above reaches it: `match`
#           roots one value global and `xref` roots none, so the value-init
#           reachability closure (`emit_support.eagerReachMap`) folds an empty
#           graph on both. Here reach(g_i) = {g_0..g_{i-1}}, so the reach sets grow
#           linearly and the fold that builds them is the graded term.
#           ⚠️ The GRADED stage for this shape is `emit` — `eagerReachMap` is called
#           from `orderedValBinds` inside `emitProgram`, on BOTH backends.
#
#   modules — N import-chained MODULE FILES (m0 <- ... <- m{N-1} <- entry), K=8
#           `Widget` impls + 4x4 records per module, driven by the MULTI-MODULE
#           profiler. The ONLY shape here that is not a single file and not
#           profile_main: it is the second DRIVER, not a fourth shape on the
#           first one. Its band is 25/50/100 with a 2-module floor, not 125/250/500
#           — a module is a file, so it prices differently. See "THE MULTI-MODULE
#           ARM" by MOD_SYMS for what it covers, what it costs, and the
#           `parse`-vs-`parseResult` silent-false-pass trap it carries.
#
# ── WHAT THIS GATE FOUND, AND THE #408 ATTRIBUTION CORRECTION ────────────────
#
# #408 records `match:emit` at r1 3.71 r2 3.73 (N=1000/2000/4000), measured
# 2026-07-16 from profile_main's WALL-CLOCK column. On instruction counts, at this
# gate's band, the superlinearity is in `lower`, NOT in `emit`:
#
#     match:lower  net 11 453 346 -> 38 124 218 -> 138 768 611   r1 3.328 r2 3.640
#     match:emit   net 17 374 761 -> 36 658 058 ->  79 051 070   r1 2.110 r2 2.156
#
# and `lower` is invisible to BOTH existing deterministic arms on this shape: its
# counted-op delta is a CONSTANT 5591 at every N (it calls neither util.contains nor
# util.lookupAssoc), and its allocation is linear (3.95 -> 8.27 -> 17.28 MB, x2.09
# x2.09). Only instruction counts see it. Anyone re-reading #408's own wall-clock
# table should know that profile_main's `emit` row at N=1 already costs more than
# the whole shape-attributable cost at N=1000.
#
# FIXED, in compiler/ir/core_ir_lower.mdk — NOT in the emitter, exactly as the
# attribution said. There were TWO independent alloc-free quadratics stacked on
# this one row, and the ratio only came back to ~2.2 once both were gone:
#   1. `buildConSwitch`/`buildLitSwitch` called `specializeCon`/`specializeLit`
#      once per distinct head, each re-scanning the WHOLE row matrix. Replaced by
#      one bucketing pass read once per branch. Alone: r1 2.560 r2 2.651 — better,
#      but still over this gate's own promotion bar.
#   2. `leafOrGuard` looked its arm's guard flag up in a `List Bool` BY INDEX
#      (`nthBool`), O(i) per leaf and O(N^2) over N leaves. Measured on its own,
#      inclusive Ir at 125/250/500: 1 256 062 -> 4 955 062 -> 19 759 312, i.e.
#      x3.945 x3.988 — textbook quadratic, and after fix (1) it was ALL of the
#      residual. Replaced by an `OrdMap Unit` index set built once per entry.
# The lesson for the next reader: one red row can hide more than one defect, and
# a stage that drops from 3.6 to 2.65 has not necessarily been made linear.
#
# ⚠️ SCOPE OF THE FIX: this confirms `lower` is linear on the shipped `gen_match`
# shape (an N-arm match with NO wildcard arms — every arm tests a distinct
# constructor). It does not close the quadratic class in general: both fixes
# above are keyed off column-0's CONSTRUCTOR-row count, so a match whose
# column-0 WILDCARD-row count itself scales as Theta(N) is still Theta(N^2).
# That residual is untested by this gate and is tracked separately as #2125 —
# do not read this row's green as covering it.
#
# ── THE LEDGER ───────────────────────────────────────────────────────────────
#
# The ledger (`KNOWN_SLOW`, below) is the same self-draining contract
# perf_scaling's KNOWN_SLOW_OPS uses: a ledgered row is green now, but FAILS if the
# ratio worsens past its ceiling AND fails demanding promotion the moment a fix
# drops it back to linear. This gate was BORN with one row, `match:lower` (#408),
# because that defect was real, live and unfixed at the tree the gate landed on;
# the row DRAINED — the fix, the promotion and the removal all happened as the
# contract intends. `KNOWN_SLOW` is empty today. `STAGE_IR_NO_LEDGER=1` turns the
# ledger off entirely and is how you see what a ledgered row is hiding:
#
#     STAGE_IR_NO_LEDGER=1 sh test/diff_compiler_stage_ir_scaling.sh
#
# ── WHAT THIS GATE FOUND, ROUND 2: #1030, on `vchain` ────────────────────────
#
# `vchain` was added by S-emit-reach-set to grade #1030, and it was RED on arrival —
# the first shape in this file to reach the value-init reachability closure at all.
# Measured on this box, at the shipped band (125/250/500), BEFORE the fix:
#
#     vchain:emit   net 111 116 200 -> 399 931 105 -> 1 590 944 747  r1 3.599 r2 3.978
#
# with `emit_support.foldReachSCCs` alone accounting for 1 371 623 301 of the 1.59e9
# (86%) and scaling x4.69 x4.61 on its own. The defect: the per-SCC union was
# `dedup (dvals ++ unionLookup direct acc)`, which COPIES every callee's reach list
# and rebuilds a fresh O(|reach|) `seen` tree over the copy, once per SCC.
# FIXED in compiler/backend/emit_support.mdk by carrying each reach set as a
# (list, OrdMap Unit) pair through the fold so the last callee's list can be SHARED
# as the result's tail; after: `vchain:emit` r1 2.155 r2 2.150, and foldReachSCCs
# net 3.26M -> 7.51M -> 17.00M (x2.31 x2.26). Element order is unchanged, so the
# emitted IR is byte-identical.
#
# ⚠️ WHAT THE FIX DOES NOT DO: on this shape Sum_v |reach(v)| is Theta(V^2) BY
# CONSTRUCTION (reach(g_i) has i members), so the reach TABLE cannot be built in
# sub-quadratic SPACE while `eagerReachMap`'s published type is
# `OrdMap (List String)`. What the fix removed is the log factor and the per-element
# tree ALLOCATION — an ~80x constant at N=500 — not the Theta(V^2) term. Should this
# row ever go red again at a larger band, the next move is the seam, not the fold:
# the two topo sorts consume TRANSITIVE reach where per-node adjacency would do.
#
# ── COST ─────────────────────────────────────────────────────────────────────
#
# 16 callgrind invocations: 12 single-file (3 shapes x (1 floor + 3 sizes)) plus 4
# multi-module (1 floor + 3 sizes). The multi-module four are the ONLY additional
# machine time this gate's frontend coverage costs — the six single-file frontend
# rows are free (they ride annotate listings the backend rows already paid for);
# the multi-module six are not, because they are a second driver over a second
# corpus. Measured on this box: ~75 s wall for the four, against ~276 s for the
# twelve. Sequential on purpose —
# callgrind is single-threaded and a noisy neighbour would perturb nothing here, but
# fanning out would buy nothing either. Measured wall on this box: see the report
# for S-build-ir-arm; re-derive with `time sh test/diff_compiler_stage_ir_scaling.sh`.
#
# Usage:  sh test/diff_compiler_stage_ir_scaling.sh
#         STAGE_IR_MATCH_N=250 sh test/diff_compiler_stage_ir_scaling.sh
#         STAGE_IR_VCHAIN_N=250 sh test/diff_compiler_stage_ir_scaling.sh
#         STAGE_IR_MOD_N=50 sh test/diff_compiler_stage_ir_scaling.sh
#         STAGE_IR_NO_LEDGER=1 sh test/diff_compiler_stage_ir_scaling.sh
# Exit:   0 every graded stage scales sub-quadratically (ledgered rows excepted)
#         1 a stage regressed, or a ledgered row must be promoted
#         2 skip (valgrind not on PATH) / phantom skip (oracle not built)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$ROOT/test/bin/profile_main"
# The MULTI-MODULE profiler, for the `modules` shape below. Same [perf] protocol as
# PROFILE, same netting, same annotate read — but a DIFFERENT DRIVER
# (loadProgram -> desugar -> resolveModulesToLines -> markModules -> checkModules)
# over a DIRECTORY of modules rather than one file, so it exercises stage entry
# points PROFILE never calls. See "THE MULTI-MODULE ARM" below.
PROFILE_MODULES="$ROOT/test/bin/profile_modules_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

# A missing oracle is INFRA ROT, not an opt-in skip: run_gates.sh reclassifies an
# exit-2 whose log does not match its LEGIT_SKIP_RE into a phantom-skip FAILURE,
# which is the right verdict for a gate that graded nothing. Word the valgrind
# message below with "not on PATH" so it lands on the other side of that test.
if [ ! -x "$PROFILE" ]; then
  echo "build oracles first — missing $PROFILE"
  echo "  FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one profile_main"
  exit 2
fi

if [ ! -x "$PROFILE_MODULES" ]; then
  echo "build oracles first — missing $PROFILE_MODULES"
  echo "  FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one profile_modules_main"
  exit 2
fi

# ── #2065: A TOOLCHAIN SKIP IS ONLY LEGITIMATE OFF CI. ──────────────────────
# Identical in force to the guard in test/diff_compiler_ir_scaling.sh — read the long
# note there. In short: the setup action installs valgrind, so reaching this branch on a
# runner means the install stopped happening, and the SKIP would be laundered into an
# opt-in skip by run_gates.sh's LEGIT_SKIP_RE, greening a shard that graded nothing.
# exit 1 (not 2) so no skip classifier can reinterpret the verdict.
# OBSERVED RED, 2026-08-28, both arms, via a PATH stripped of valgrind — the full recipe
# and the verbatim outputs are recorded once, in diff_compiler_ir_scaling.sh's copy of
# this guard. Here: CI unset -> exit 2 SKIP; CI=true -> exit 1 FAIL, for BOTH valgrind
# and callgrind_annotate.
need_valgrind() {   # $1 = tool name, $2 = what it measures
  command -v "$1" >/dev/null 2>&1 && return 0
  if [ -n "${CI:-}" ]; then
    echo "FAIL: $1 is not on PATH, and this is CI."
    echo "  This gate measures $2; without $1 it grades NOTHING. On a dev box that is a"
    echo "  legitimate skip; on a runner it means the valgrind install in"
    echo "  .github/actions/setup-medaka stopped happening and this arm has silently gone"
    echo "  dark (#2065). Fix the install, not this check."
    exit 1
  fi
  echo "SKIP: $1 not on PATH — this gate measures $2."
  echo "  (A skip is only legitimate OFF CI — see the #2065 note in this file.)"
  echo "  Debian/Ubuntu: sudo apt-get install -y valgrind"
  exit 2
}
need_valgrind valgrind "Callgrind instruction counts"
need_valgrind callgrind_annotate "Callgrind instruction counts (it ships with valgrind)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

THRESH="${STAGE_IR_THRESH:-3.0}"
IR_HEAP="${STAGE_IR_HEAP:-2147483648}"
FLOOR_N="${STAGE_IR_FLOOR_N:-1}"
MATCH_N="${STAGE_IR_MATCH_N:-125}"
XREF_N="${STAGE_IR_XREF_N:-125}"
VCHAIN_N="${STAGE_IR_VCHAIN_N:-125}"
CONSTR_N="${STAGE_IR_CONSTR_N:-300}"
WIDEIFACE_N="${STAGE_IR_WIDEIFACE_N:-125}"
# `guardwild` (#2125) is banded LOWER than its siblings, and the reason is a property
# no other shape here has: its lowered decision tree is Θ(N²) NODES for a Θ(N) source
# file, so `emit` renders a quadratic program and the wall cost of a single profile
# grows as N² even before Callgrind's multiplier. See GUARDWILD_N in
# diff_compiler_perf_scaling.sh for the measured native cost curve (0.33 s at N=50,
# 2.86 s at N=400). The band below is derived, not inherited — see the OBSERVED
# margins and the band-choice note beside KNOWN_CEIL_guardwild_lower. ⚠️ It is also
# NOT the band perf_scaling.sh's twin uses (PERF_GUARDWILD_N=100): each gate's band is
# sized against its own instrument's cost, and the ceilings on both sides are
# band-specific, so the two knobs move independently and neither number transfers.
GUARDWILD_N="${STAGE_IR_GUARDWILD_N:-25}"
# S-5-scoperefs-attribution (#2172): per-stage attribution, NOT a re-grade of
# ir_scaling.sh's module-level scoperefs row (KNOWN_CEIL_scoperefs=3.26 at
# IR_SCOPEREFS_N=3000 — a different gate, different cost budget). Callgrind here
# already costs ~1 min per shape at N=35/70/140 (measured, this box), so the band
# is picked for the smallest N that shows a CLEARLY superlinear stage without
# crossing this gate's own THRESH=3.0 (attribution only — landing an over-3.0
# verdict here would fail the gate on an #2172 fix this slice is explicitly not
# making). At 35/70/140 (this box): dce r1=2.929 r2=2.649, trmc r1=2.723
# r2=2.886 — both visibly above the ~2.0-2.3 baseline every other stage reads at
# this band, confirmed genuinely quadratic (not band noise) by a spot-check at
# 250/500/1000 where both cross 3.0 (dce r2=3.632, trmc r2=3.526). See
# S-5-scoperefs-attribution's report for the full derivation table.
#
# PLACEMENT DECISION (per [W-SHARD-DERIVED]/contract §7.3): this shape rides the gate's
# existing per-PR cadence — test/gates.toml's `diff_compiler_stage_ir_scaling` entry is
# `tier = "merge"` (every PR/merge-queue run, same as its five sibling shapes in this
# file), not `nightly` or `ondemand`. No special-case override was needed or added; the
# ~1 min/shape callgrind cost at this band was accepted as part of that existing tier.
SCOPEREFS_N="${STAGE_IR_SCOPEREFS_N:-35}"

# ── the multi-module band ────────────────────────────────────────────────────
#
# 25/50/100 modules with a 2-module floor, K=8 impls per module. DELIBERATELY an
# order of magnitude below the three single-file bands, and below
# perf_scaling's own MOD_N=100/200/400, because a module here is a FILE: the
# driver parses, loads, resolves, marks and typechecks all N of them, so cost
# grows with N far faster per unit than a single file with N decls in it. At
# 25/50/100 the four callgrind runs cost ~75 s wall on this box (measured; see
# the COST block at the end of the header) against a `types` shard ci.yml already
# documents as the CI pole. A band big enough to reach the #153/#154
# module-count family (perf_scaling's 100/200/400) costs several times that and
# does NOT belong here — perf_scaling already grades that band on TIME/ALLOC/OPS
# for a fraction of the machine time.
#
# ⚠️ AND THE SMALL BAND IS STILL ENOUGH TO PIN #1879 — do not raise MOD_N to "see it
# better". The `modules:typecheck` KNOWN_SLOW row below is graded at THIS default
# band, where the live O(modules^2) term shows as r2=2.217 against its siblings'
# 2.04. That 8% signal is usable only because Ir is DETERMINISTIC; the same 8% on
# perf_scaling's TIME arm is what flaps. Raising the band would buy a bigger ratio
# for several times the machine time and would invalidate the row's measured
# ceiling/fixed pair, which are stated for 25/50/100.
MOD_N="${STAGE_IR_MOD_N:-25}"
MOD_FLOOR_N="${STAGE_IR_MOD_FLOOR_N:-2}"
# K, R and F are the per-module CONSTANTS, transcribed with their values from
# test/diff_compiler_perf_scaling.sh's gen_modules block. Read that block before
# changing any of them: K>1 and impls (not plain bindings) are what populate the
# accumulated decl universe at all, and MOD_R x MOD_F = 4x4 is the field-owner
# multiplier a 1x1 cut was measured to be too weak for. This gate scales the
# MODULE COUNT against those fixed constants — issue #153's fix shape.
MOD_K="${STAGE_IR_MOD_K:-8}"
MOD_R=4
MOD_F=4

# The netting-noise guard, as a fraction of the STAGE's own floor. Unlike
# ir_scaling's 5% this is 2%, and the difference is justified by measurement rather
# than inherited: the observed run-to-run wobble above is ~2e-5 of a reading, so 2%
# is three orders of magnitude of headroom. It has to be lower than ir_scaling's
# because `emit`'s floor is genuinely enormous (5.9e8 Ir of prelude) and a 5% guard
# would refuse to grade `emit` at any band a per-PR gate can afford — which would
# silently drop the #1061/#1030 stage from coverage.
#
# ⚠️ Under-the-guard is a printed SKIP here, not a FAIL as in ir_scaling. That is
# forced by the shape of the arm: ir_scaling grades ONE number per shape, so a
# too-small net means the band is mis-sized and saying so is the whole point. This
# gate grades ELEVEN stages off one run, and a shape legitimately leaves some of them
# untouched (nothing scales `dce` on `xref`; `mark` nets under the guard on `match`).
# A blanket FAIL would make it
# impossible to grade any stage without sizing the band for the smallest. The
# no-silent-green invariant is preserved instead by `graded`: a shape that grades
# ZERO stages is a hard FAIL, and so is a whole run that grades nothing.
MIN_NET_FRAC="${STAGE_IR_MIN_NET_FRAC:-0.02}"

# ── the stages, by the symbol profile_main calls to run them ─────────────────
#
# One `<stage>=<mangled symbol>` pair per word. The names on the left are the same
# names profile_main's own `[perf]` rows use, deliberately, so a reader can line the
# two up (one deliberate exception: `exhaust`, whose `[perf]` row is spelled
# `exhaust-guards`; the short name is used here because it is also a ledger key and
# `<shape>:exhaust-guards` reads badly in one). `trmc` is `detectDispatchGroups`,
# which runs INSIDE emitProgram — its inclusive count is therefore a SUBSET of
# `emit`'s, not a sibling of it. That is intentional and it is why it is listed
# separately: #1029's cubic lived there and a 5% slice of emit is invisible in emit's
# own ratio. The same containment holds across the frontend rows below: `exhaust`
# runs INSIDE typecheck ([P-EXHAUST-IN-TYPECHECK]), so its count is a subset of
# `typecheck`'s, for the same reason and to the same purpose.
#
# ── THE FRONTEND STAGES, AND WHY THEY ARE FREE ───────────────────────────────
#
# The six frontend rows (`parse`..`typecheck`) were added by S-frontend-ir-arm.
# They cost ZERO additional callgrind invocations and ZERO additional seconds: ONE
# annotate listing per (shape, N) already carries every symbol in the process, so
# reading six more out of the listings the backend rows already paid for is free.
# That is the whole reason they are here rather than on a shape of their own — a
# `conlocal`-style frontend shape sized to redden costs 415-1204 s of callgrind on a
# shard ci.yml already documents as the CI pole, and the same defect grades on
# diff_compiler_perf_scaling.sh's deterministic OP arm for ~13 s of native runtime
# (see the `conlocal` block there). Read that trade before adding a frontend SHAPE.
#
# MEASURED margins at the shipped bands, this box, on the tree this arm landed on
# (netted per the rule above; N=125/250/500 with the N=1 floor):
#     xref :  parse 2.014/2.007   exhaust 2.230/2.179   desugar 2.019/2.007
#             resolve 2.222/2.164 mark    2.006/2.004   typecheck 2.131/2.116
#     match:  parse 2.015/2.007   exhaust 2.128/2.226   desugar 2.029/2.014
#             resolve 2.229/2.189 mark    (SKIP)        typecheck 2.082/2.080
#     vchain: parse 2.013/2.006   exhaust 2.254/2.192   desugar 2.007/2.009
#             resolve 2.220/2.210 mark    2.007/2.006   typecheck 2.148/2.126
#
# Every one of those seventeen graded rows is 2.0-2.26 — dead linear with 25%+ of
# headroom under the 3.0 threshold — so no frontend row is ledgered (see KNOWN_SLOW).
#
# ⚠️ `mark` SKIPs ON `match`, BY DESIGN — it is not breakage. Its netted delta there
# is 1.45% of its own floor, UNDER the 2% MIN_NET_FRAC guard, so the row prints SKIP
# rather than a ratio (the analogue of `dce` never being scaled by `xref`; see the
# MIN_NET_FRAC block above for why under-the-guard is a SKIP here and not a FAIL).
# `mark` grades fine on `xref` at 20.6% of floor, so the stage is covered. The next
# narrowest row is `desugar` on `match` at 5.88%.
#
# ⚠️ `parse`'s inclusive count is NOT polluted by the profiler's `fmt`/`lint` stages,
# which also parse. Checked first-hand rather than assumed: both go through
# `parseWithPositions`, which callgrind reports as its own separate symbol
# (`mdk_frontend_parser__parseWithPositions`, 775 797 037 Ir at xref N=500, alongside
# `parse`'s 681 584 196). A future refactor that routes fmt/lint back through `parse`
# would silently fold a second linear term into this row — re-derive with
# `nm $PROFILE | grep parse` if this row's margins ever move without a source cause.
STAGE_SYMS="parse=mdk_frontend_parser__parse \
exhaust=mdk_frontend_exhaust__checkGuardExhaustivenessWith \
desugar=mdk_frontend_desugar__desugar \
resolve=mdk_frontend_resolve__resolveToLines \
mark=mdk_frontend_marker__markWithPrelude \
typecheck=mdk_types_typecheck__checkOneToLinesWithRuntime \
lower=mdk_ir_core_ir_lower__lowerProgramEmit \
emit=mdk_backend_llvm_emit__emitProgram \
mangle=mdk_backend_private_mangle__mangleUnits \
dce=mdk_ir_dce__dceFilter \
trmc=mdk_backend_trmc_analysis__detectDispatchGroups"

# ── THE MULTI-MODULE ARM ─────────────────────────────────────────────────────
#
# Added by S-frontend-ir-arm part 1b. Everything above this line runs ONE driver
# (profile_main) over ONE file. The frontend stage entry points a multi-module
# compile actually calls are DIFFERENT FUNCTIONS — `resolveModulesToLines` not
# `resolveToLines`, `checkModules` not `checkOneToLinesWithRuntime`, `markModules`
# not `markWithPrelude` — and `loadProgram` has no single-file counterpart at all.
# So the single-file rows above are not "the frontend, covered": they are one of
# two drivers, and the O(modules^2) family (#153/#154) lands on stages ONLY this
# arm can name.
#
# ⚠️ THE PARENTHETICAL THAT USED TO NAME THE SITES — "checkModuleFullImpl's
# per-module rescan, elabModuleStamp's buildKeyTable over the accumulated universe" —
# IS REFUTED BY MEASUREMENT, not merely unverified. Callgrind per-symbol attribution
# at N=200 -> N=800 (see the `modules:typecheck` KNOWN_SLOW entry below for the full
# table) puts the residual quadratic in `declEnvReachIndex`, `buildDataEnv`'s
# `addFieldOwnerIdents`, the `importedCtorTypeDeclsLastWins` -> `overlayScanRows`
# chain, and `ieAddRows` — three of which are whole-graph PREAMBLE work
# (`checkModulesPreamble` -> `buildDeclEnvs`, reading 8.87x/9.89x against a linear
# 4.00x) that did not exist when #153/#154 were written. `checkModuleFullImpl` itself
# reads 5.02x, i.e. it CONTAINS the overlay term but is not itself the rescan the old
# parenthetical describes, and `elabModuleStamp`/`buildKeyTable` do not appear on this
# driver's profile at all (`checkModules`, not `elaborateModules`, is what runs here).
#
# Unlike the frontend rows above, this arm is NOT free: it is a second driver over
# a second corpus, so it costs 4 additional callgrind runs. See the MOD_N block
# for why the band is small.
#
# 🚨 `parse` HERE IS `parseResult`, NOT `parse`, AND THE DIFFERENCE IS A SILENT
#    FALSE PASS — NOT A TYPO.
#
# `mdk_frontend_parser__parse` RESOLVES in profile_modules_main, so the hard-fail
# guard in `stage_ir` does NOT catch it. But under this driver it covers only the
# profiler's own two PRELUDE parses (runtime.mdk, core.mdk) and nothing else:
# measured at 394 045 616 Ir at N=25, at N=50 and at N=100 — BIT-IDENTICAL, netting
# to exactly 0. A `parse=mdk_frontend_parser__parse` row would therefore print SKIP
# under MIN_NET_FRAC at every N forever, while `graded` stayed nonzero from the
# other five rows — i.e. the arm would report a cheerful PASS with its parse row
# proving nothing, which is the exact failure mode `stage_ir`'s hard-fail exists to
# prevent, arriving through the one door that guard does not watch.
#
# The per-module parse work is under `parseResult`: loadProgram parses each module
# through `parseResult`/`parseLocatedResult` (compiler/driver/loader.mdk:1043,1063,
# 1102), which callgrind reports as its own symbol. That row is kept SEPARATE from
# `load` even though loadProgram contains it, for the same reason `trmc` is listed
# separately from `emit` and `exhaust` separately from `typecheck`: a contained
# stage's own ratio is invisible inside its container's.
# If this row's margins ever move without a source cause, re-derive with
#   nm $PROFILE_MODULES | grep parse
#
# Second correction, benign but equally easy to get wrong: the multi-module mark
# symbol lives in types.typecheck, NOT frontend.marker — profile_modules_main
# imports `markModules` from `types.typecheck`.
#
# MEASURED margins at the shipped band, this box, on the tree this arm landed on
# (N=25/50/100, K=8, netted against the same generator at N=2):
#     modules: parse   2.088/2.042   load    2.089/2.044   desugar 2.087/2.041
#              resolve 2.089/2.043   mark    2.086/2.044   typecheck 2.190/2.217
#
# Every one of those six rows GRADES — none falls under the netting guard, and the
# narrowest margin is `desugar`'s at 46% of its own floor, i.e. 23x the 2% guard.
# (Contrast the `parse` row a `mdk_frontend_parser__parse` symbol would have
# produced: net 0, SKIP, forever. The corrected row nets 3.0e8 at N=25.)
#
# ⚠️ "Dead linear at this band, as expected: there is no known multi-module defect
# that reddens at 25/50/100 ... This arm is a REGRESSION GUARD and a DRIVER-PARITY
# claim, not a live pin" USED TO STAND HERE AND IS RETIRED. `typecheck`'s 2.190/2.217
# above is NOT its five siblings' 2.04-2.09; it is the visible tail of a live
# O(modules^2) term (#1879), and this arm is now that defect's LIVE PIN — see the
# `modules:typecheck` entry in KNOWN_SLOW below for the four attributed sites and the
# ceiling/fixed pair. The other five MOD_SYMS rows remain a regression guard and a
# driver-parity claim, as written.
#
# DELIBERATE RED — negative control, or lack of one (F-fixround-3, §7.1): NO
# pre-fix-red-then-fixed observation exists for the multi-module driver itself.
# When this arm landed (S-frontend-ir-arm part 1b), all six MOD_SYMS rows read
# "ok" and dead-linear on first measurement — see that slice's report §6.1,
# which nets byte-identical to the "MEASURED margins" table above. The driver
# was never seen red and then fixed; it has only ever been observed passing.
# The one live non-linear reading this arm carries — `modules:typecheck`
# 2.190/2.217 above #1879 — is NOT a pre-fix-red-then-fixed case either: it is
# a currently OPEN, accepted-under-ceiling defect (see KNOWN_SLOW below), not a
# closed one, so it cannot stand in as this arm's deliberate-red record. No
# fresh negative-control shape was constructed here (constructing one cheap and
# honest would mean re-breaking a known-fixed multi-module quadratic on
# purpose, which risks miscalibrating the ceiling/threshold this arm now
# relies on) — this paragraph is the honest statement of the gap, not a fix
# for it.
MOD_SYMS="parse=mdk_frontend_parser__parseResult \
load=mdk_driver_loader__loadProgram \
desugar=mdk_frontend_desugar__desugar \
resolve=mdk_frontend_resolve__resolveModulesToLines \
mark=mdk_types_typecheck__markModules \
typecheck=mdk_types_typecheck__checkModules"

# ── KNOWN SLOW — a self-draining ledger, NOT a skip list ────────────────────
#
# One `shape:stage` per line. Each row records a REAL, currently-superlinear stage
# ratio: the gate stays green, but FAILS if the ratio worsens past its ceiling and
# FAILS demanding promotion the instant a fix drops it back to linear.
#
# THE LEDGER HOLDS EXACTLY ONE ROW: `modules:typecheck` (#1879). `match:lower` was
# the previous entry (issue #408, ledgered at ceiling 4.00 / fixed 2.60 against a
# measured r1 3.328 r2 3.640); it PROMOTED and was removed when the two
# `core_ir_lower.mdk` quadratics behind it were fixed for the shipped `gen_match`
# shape — see the block above (and its scope caveat: the wildcard-row-scaling case
# is #2125, not fixed here). Re-adding a row means
# re-adding its `KNOWN_CEIL_<shape>_<stage>` / `KNOWN_FIXED_<shape>_<stage>` pair
# alongside it, and saying in a comment here what issue it pins and at what band
# it was measured.
#
# NO FRONTEND ROW IS LEDGERED EITHER, and that is a measurement, not an omission:
# none of the six frontend stages reddens on `xref`, `match` or `vchain` at the
# shipped bands (margins in the STAGE_SYMS block above). The frontend quadratic this
# arm was scoped around (#2030, `localPinPairs`) needs a shape none of the three
# carries; it is pinned on diff_compiler_perf_scaling.sh's OP arm instead
# (`conlocal:typecheck` / `conlocal:mark`), for 33x less machine time on the same
# band. Do not add it here without re-reading the cost note in STAGE_SYMS.
#
# ── modules:typecheck — #1879, LEDGERED 2026-08-28. THE ARM OF RECORD FOR IT. ──
#
# ⚠️ THIS BLOCK USED TO SAY "NO MULTI-MODULE ROW IS LEDGERED, and that too is a
# measurement: every stage in MOD_SYMS reads 2.0-2.22 ... The module-count quadratic
# family (#153/#154) does not reach at that band". The first clause is still true as a
# reading and FALSE as a conclusion, and that gap is the whole of #1879: `typecheck`'s
# 2.190/2.217 is not the same shape as its five siblings' 2.04-2.09 in the SAME run.
# It is a real, LIVE O(modules^2) term whose LINEAR part still dominates at this band,
# so the ratio-of-ratios detector is structurally mis-shaped for it rather than merely
# mis-tuned: a mixed a*N + b*N^2 curve creeps toward r2=4 asymptotically and may cross
# `r2 > r1*1.15 && r2 > 2.45` only in a narrow window of N, if ever.
#
# THE MEASUREMENT (this box, this tree, deterministic Ir, N=25/50/100 K=8):
#     typecheck net 398091174 -> 871828884 -> 1932587912    r1=2.190 r2=2.217
#     every other MOD_SYMS stage in the same run: r1 2.086-2.089, r2 2.041-2.044
#
# THE ATTRIBUTION, which is why this is a LEDGER and not a fix. Callgrind inclusive Ir
# per symbol, module count x4 (N=200 -> N=800, same generator, K=8; LINEAR reads 4.00,
# QUADRATIC reads 16.00). `checkModules` itself reads 6.93, and its quadratic EXCESS
# over linear (33.399e9 - 4x4.821e9 = 14.115e9 Ir) decomposes into FOUR INDEPENDENT
# sites, none a majority:
#
#   declEnvReachIndex               23.47x   4.606e9 excess  33%  compiler/types/typecheck.mdk
#   buildDataEnv/addFieldOwnerIdents 16.11x  4.027e9 excess  29%
#   importedCtorTypeDeclsLastWins    15.47x  3.652e9 excess  26%   -> findOverlayDecl -> overlayScanRows
#   ieAddRows (in buildImplEnv)       7.39x  2.746e9 excess  19%
#
# Cross-validated on an INDEPENDENT channel (invocation counts out of the callgrind
# `calls=` records), which discriminates two distinct mechanisms rather than merely
# re-reading the first: `overlayScan` and the `declEnvReach*` walk have QUADRATIC CALL
# COUNTS (15.85x / 15.82x) — a per-module scan of a whole-graph list; while
# `addFieldOwnerIdents` (4.00x calls) and `ieInsertRow` (3.80x calls) have LINEAR call
# counts and quadratic COST PER CALL — the house `existing ++ [new]` append onto a list
# that grows with the module count.
#
# Two of the four are one-line fixes their own headers already record as OWED
# (`ieInsertRow`'s header names the remedy verbatim: "cons and `reverseL` once in
# `buildImplEnv`"), and two are quadratic BY CONSTRUCTION on an import chain
# (`declEnvReachIndex`'s own header: "the index's own SIZE is already quadratic on a
# chain ... so no build can be cheaper"; `findOverlayDecl`'s: "`pool` is the WHOLE
# accumulated universe and this runs once per UseGroup member of every module"). So no
# single fix drops this row's slope, which is exactly why it is ledgered rather than
# left as a threshold to be widened later.
#
# CEILING 2.45 clears the measured r2=2.217 by ~10%, the same margin convention
# `match:lower` used (4.00 against 3.640). Ir is deterministic, so the margin absorbs
# source drift, not run noise. FIXED 2.10 sits above the 2.041-2.044 the five sibling
# stages read in the SAME run — i.e. above where a genuinely linear `typecheck` lands —
# and clearly below the observed 2.217, so it can neither false-promote nor fail to
# promote a real fix.
#
# 🚦 THIS ROW REPLACES `test/diff_compiler_perf_scaling.sh`'s `modules` typecheck TIME
# verdict as the arm of record for #1879. That arm sees the SAME curve (r1=2.21 r2=2.43
# one run, r1~2.1 r2~2.67 the next) but sits on its climbing clause's trip point, so it
# FLAPS; and that file's `modules` shape is outside the SHAPES loop and has no ledger
# arm at all, so the only things available to it are widening or flooring, both of which
# [W-QUIETER] forbids. It stays live and unwidened as a coarse second opinion; a red
# there is diagnosed against THIS row.
KNOWN_SLOW="
modules:typecheck
guardwild:lower
guardwild:emit
"
#
# ── 🚨 2026-08-31, sprint hold-the-gains S-2 (#2331 Case 2): THIS CEILING DOES NOT
# CATCH A #2146/#2147 REVERT, AND THAT IS NOW MEASURED RATHER THAN SUSPECTED.
#
# The 2.217 above is the CALIBRATION reading, and the calibration run CONTAINED both
# defects: it was taken in 869d85483 (2026-08-28 05:19) and the #2146/#2147 fix
# landed in b6b61ed8d (2026-08-29 21:36).
#   Derive: git log --format='%h %ci' -L 630,630:test/diff_compiler_stage_ir_scaling.sh
# So "CEILING 2.45 clears the measured r2=2.217 by ~10%" above is clearing the
# DEFECT'S OWN READING by 10% — a full revert lands at ~2.217, under 2.45, GREEN.
#
# Re-measured post-fix on this box, this tree (STAGE_IR_ONLY=modules):
#
#   typecheck net 325911341 -> 707869343 -> 1537319318   r1=2.172  r2=2.172
#
# FIXED reads 2.172; the DEFECT reads 2.217.
#
# ⚠️ THE TWO ARE NOT EQUAL-STRENGTH EVIDENCE, and the separation below must be read
# with that in mind (2026-08-31, F-1, end-of-sprint review finding S2-2). 2.172 is
# a FRESH, SAME-TREE, SAME-BOX reading taken for this comment. 2.217 is a RELAYED
# CROSS-TREE number: it is the 869d85483 calibration reading (2026-08-28), three
# days and an unrelated sprint of compiler change earlier, and it is quoted here
# WITHOUT re-measurement. Using it that way is licensed — the dates alone establish
# that the calibration run contained both defects, which is the only property the
# argument below needs, and the sprint contract's F4 rule permits a relayed reading
# for exactly that kind of use — but a 2.1% "separation" computed across two trees
# is not the same object as a 2.1% separation measured within one. A same-tree
# two-arm revert of #2146/#2147 has NOT been run; it is part of what #2331 stays
# open for.
#
# The separation is 2.1%, so the ceiling
# would have to sit in 2.172 < CEIL < 2.217 to tell them apart. The sprint's own
# headroom convention (10% over a freshly measured r2) gives 2.39; the tree's other
# convention (20%) gives 2.61; BOTH are above 2.217 and so is the shipped 2.45.
# No percentage headroom rule discharges this. A ceiling inside a 2.1% window on a
# row whose siblings spread 2.041-2.089 in the same run is a false-red generator.
#
# ⇒ 2.45 IS NOT RAISED AND NOT LOWERED. Raising is [W-QUIETER]; lowering into the
# window trades a silent miss for a flap that gets "repaired" by raising it again.
# What this row honestly bounds is THE LEDGERED FOUR-SITE COST GETTING WORSE (the
# attribution above), not a #2146/#2147 reintroduction. Do not read it as the
# latter, and do not discharge #2331 by moving this number — the lever is the band
# (N=25/50/100, K=8), which needs a fresh two-arm ladder nobody has paid for yet.
KNOWN_CEIL_modules_typecheck="2.45";  KNOWN_FIXED_modules_typecheck="2.10"

# ── guardwild:lower / guardwild:emit — #2125, the residual of #408's fix ──────
#
# WHAT THESE ROWS PIN. #408 was `buildConSwitch` calling `specializeCon c a rows` once
# per distinct head, each call scanning the whole matrix. Its fix buckets the rows in
# ONE pass (`conBuckets`) — but the wildcard rows cannot be bucketed, because a
# column-0 wildcard belongs to EVERY branch. `wildTailRows` collects them once and
# `conBranch` then merges `map (padWildRow a) wilds` into each branch, which is Θ(W)
# per head. #2125 is the observation that this leaves the fix Θ(N) per branch whenever
# W itself scales, and `gen_guardwild` is the first shape in the tree where it does:
# interleaving `Ci => i` with `_ if k == i => i` makes both the head count and the
# wildcard-row count Θ(N).
#
# ⚠️ READ THESE AS QUADRATIC-AWARE CEILINGS, NOT AS "NEARLY FIXED" NUMBERS. Branch
# `Ci` genuinely must test the `i` guards ordered ahead of it, so the LOWERED TREE has
# sum(i) = Θ(N²) nodes and `emit` renders every one. A ~2.0 reading on either row would
# mean the tree stopped being built, not that the cost was optimised away — which is
# exactly why both rows carry a KNOWN_FIXED that a real linearisation must cross rather
# than a threshold-adjacent ceiling. Draining #2125 means a lowering that stops
# materialising one full copy of the guard chain per head (sharing it, or compiling the
# guard column separately), i.e. a codegen change; it is NOT a data-structure swap of
# the kind that drained #408, #906, #970 and the other rows in this file's history.
#
# MEASURED, this box, at the shipped band (N=25/50/100, Callgrind Ir is deterministic
# so these are exact, not min-of-K):
#     lower  net 4348134 -> 14817404 ->  54546012   r1 3.408  r2 3.681
#     emit   net 34342774 -> 129609545 -> 512033423 r1 3.774  r2 3.951
# OBSERVED RED before ledgering, verbatim:
#     $ STAGE_IR_ONLY=guardwild STAGE_IR_GUARDWILD_N=25 sh test/diff_compiler_stage_ir_scaling.sh
#       lower     ** SUPERLINEAR (stage Ir) ** r1=3.408 r2=3.681 (threshold 3.0, r2 alone)
#       emit      ** SUPERLINEAR (stage Ir) ** r1=3.774 r2=3.951 (threshold 3.0, r2 alone)
#     FAIL: 10 stage-ratio(s) graded, 2 over the line.
#
# CEILINGS are S-2's convention — 10% over the freshly measured r2 (3.681 -> 4.05,
# 3.951 -> 4.35) — and both stay well under the ~8 a CUBIC would read, so the regression
# these rows actually bound (wilds being re-derived per branch, i.e. #408 coming back on
# top of #2125) still reds them. FIXED 2.60 sits above the ~2.0-2.2 every linear row in
# this file reads and far below the observed 3.68/3.95, so neither a band wobble nor an
# unrelated compiler change can false-PROMOTE them.
#
# ⚠️ BAND CHOICE, STATED PLAINLY BECAUSE IT LOOKS LIKE BAND-SHOPPING AND IS NOT. At
# 25/50/100 this shape costs 57 s of Callgrind (measured, `time` on the narrowed run) —
# the ~1 min/shape budget SCOPEREFS_N was also sized to. At 50/100/200 it costs ~4 min,
# and a THIRD row crosses the line there: `typecheck` reads r1=2.725 r2=3.262 (against
# 2.401/2.726 at the shipped band). That row is the SAME intrinsic Θ(N²) one stage
# earlier — exhaust's `useful` over a matrix carrying Θ(N) wildcard rows AND Θ(N)
# constructor rows — not a separate defect, and it is deliberately left UNLEDGERED and
# UNGRADED-as-red here rather than quietly floored: the band was chosen for cost, the
# consequence is recorded on this line, and raising STAGE_IR_GUARDWILD_N to 50 is
# expected to red `typecheck` and to need a third row at ceiling ~3.59.
KNOWN_CEIL_guardwild_lower="${KNOWN_CEIL_guardwild_lower:-4.05}";  KNOWN_FIXED_guardwild_lower="${KNOWN_FIXED_guardwild_lower:-2.60}"
KNOWN_CEIL_guardwild_emit="${KNOWN_CEIL_guardwild_emit:-4.35}";   KNOWN_FIXED_guardwild_emit="${KNOWN_FIXED_guardwild_emit:-2.60}"

# ── OBSERVED RED (#2160 rule 1) ──────────────────────────────────────────────
#
# #2150's defect here: a LEDGERED row that falls under the netting guard used to
# print `SKIP` and `continue` BEFORE the ledger was consulted, so a ledger row
# whose quadratic had been fixed drained in silence behind a green gate. The
# ledger check now runs first in BOTH grade_shape and grade_modules (they are a
# lockstep pair — see grade_modules' header).
#
# Driven red on this box, 2026-08-28, via the add-only STAGE_IR_LEDGER_EXTRA seam
# plus a netting guard raised until a real row falls under it. Verbatim:
#
#   $ STAGE_IR_MIN_NET_FRAC=0.99 STAGE_IR_LEDGER_EXTRA="xref:emit" \
#       sh test/diff_compiler_stage_ir_scaling.sh
#   ## LEDGER INJECTION ACTIVE (+[xref:emit]) — this run's verdicts …
#   emit  ** PROMOTE: ledgered, but now under the netting guard ** \
#         net 56368320 at N=125 (<= 584439189 of floor 590342616)
#   FAIL: 13 stage-ratio(s) graded, 2 over the line.
#   injected exit=1
#
# Before the fix the same row printed
#   emit  SKIP — net at N=125 (56368320) under the netting guard (…)
# and contributed nothing to the exit code.
#
# ⚠️ THE LIMIT OF THAT RECORD WAS: it exercises grade_shape, and the grade_modules
# twin had never been observed red. That is now DISCHARGED — #2160 phase 2, this
# box, 2026-08-28. The reason 0.99 did not reach it was arithmetic, not structure:
# the guard compares the row's net against a fraction of its OWN floor, and
# modules:typecheck's floor Ir is 331 664 118, so 0.99 of it (328 347 476) sits
# just BELOW that row's net of 392 703 519. The frac has to clear net/floor = 1.18.
# At 5:
#
#   $ STAGE_IR_ONLY=modules STAGE_IR_MIN_NET_FRAC=5 sh test/diff_compiler_stage_ir_scaling.sh
#   ## STAGE_IR_ONLY=[modules] — NARROWED RUN, NOT a grading result.   ##
#   ── modules (N=2 floor, 25/50/100 modules, K=8 impls each) ──
#     parse     ok   r1=2.088 r2=2.042 (threshold 3.0)
#     load      ok   r1=2.089 r2=2.044 (threshold 3.0)
#     desugar   SKIP — net at N=25 (6165041) under the netting guard (67291660 of floor 13458332)
#     resolve   ok   r1=2.089 r2=2.043 (threshold 3.0)
#     mark      SKIP — net at N=25 (1893351) under the netting guard (26032070 of floor 5206414)
#     typecheck ** PROMOTE: ledgered, but now under the netting guard ** net 392703519 \
#               at N=25 (<= 1658320590 of floor 331664118)
#             Remove "modules:typecheck" from KNOWN_SLOW — the quadratic is FIXED — or raise the band.
#             It may NOT stay ledgered AND ungraded.
#   FAIL: 3 stage-ratio(s) graded, 1 over the line.
#   exit=1
#
# Note what the SAME run shows about the unledgered rows: `desugar` and `mark`
# fell under the identical guard and printed a plain SKIP contributing nothing to
# the exit code, which is the correct behaviour for a row that asserts nothing —
# and it is exactly the shape the ledgered row used to have. The two verdicts
# side by side in one transcript are the #2150 fix stated as a difference rather
# than as a claim.
#
# ⚠️ WHY THE FRAC AND NOT A SMALLER BAND: STAGE_IR_MOD_N is the honest lever for
# cost, but shrinking the band moves the very net the guard is comparing, so a
# red obtained that way would not be evidence about THIS row. The frac moves only
# the guard.

# STAGE_IR_LEDGER_EXTRA: the add-only DELIBERATE-RED SEAM (#2150), the mirror of the
# existing STAGE_IR_NO_LEDGER. The netting-guard PROMOTE branches below only run when a
# row is BOTH ledgered AND under the guard, and KNOWN_SLOW holds exactly one row — in
# grade_modules, none in the SHAPES loop — so grade_shape's half is otherwise
# unobservable. Add-only (it cannot silence a real row), default-empty, set nowhere in
# this tree (derive: `grep -rn STAGE_IR_LEDGER_EXTRA .github test Makefile`), and
# announced loudly on any run that uses it.
STAGE_IR_LEDGER_EXTRA="${STAGE_IR_LEDGER_EXTRA:-}"
if [ -n "$STAGE_IR_LEDGER_EXTRA" ]; then
  echo "############################################################################"
  echo "## LEDGER INJECTION ACTIVE (+[$STAGE_IR_LEDGER_EXTRA]) — this run's verdicts"
  echo "## are NOT a grading result. Only for observing the ledger branches red.   ##"
  echo "############################################################################"
fi

is_known() {
  [ -n "${STAGE_IR_NO_LEDGER:-}" ] && return 1
  for _k in $KNOWN_SLOW $STAGE_IR_LEDGER_EXTRA; do [ "$_k" = "$1" ] && return 0; done
  return 1
}

# ── STAGE_IR_ONLY: run ONE shape of this gate (#2160 phase 2) ────────────────
#
# This gate is the most expensive of the three scaling gates — every shape costs
# 4 Callgrind profiles, and a whole run is ~10 min. Driving a single arm red
# should not cost a whole run, and until this knob it did. Same shape as
# ir_scaling's IR_ONLY and perf_scaling's PERF_ONLY.
#
# Values are the shape names passed to grade_shape below, plus `modules` for the
# multi-module twin. Derive the set, do not trust this comment:
#
#   grep -n '^grade_shape \|^grade_modules$' test/diff_compiler_stage_ir_scaling.sh
#
# Space-separated list. Empty (the default, and the only value in CI — derive
# with `grep -rn STAGE_IR_ONLY .github test Makefile`) runs everything and behaves
# exactly as before, so this knob cannot make a real run quieter ([W-QUIETER]).
# 🚨 A narrowed run is NOT a verdict: the `graded == 0` guard below asserts SCOPE,
# not health, so under STAGE_IR_ONLY it is skipped and the skip is printed.
# ⚠️ ONE EXCEPTION, and it is not a scope question: a narrowing that grades NOTHING
# AT ALL is a typo or a dead unit name, and it FAILS. See the guard at the foot of
# this file for why that changed.
STAGE_IR_ONLY="${STAGE_IR_ONLY:-}"
if [ -n "$STAGE_IR_ONLY" ]; then
  echo "############################################################################"
  echo "## STAGE_IR_ONLY=[$STAGE_IR_ONLY] — NARROWED RUN, NOT a grading result.   ##"
  echo "## Unnamed shapes did not run; the zero-graded coverage guard is off.     ##"
  echo "############################################################################"
fi

# want <shape> — the ONLY reader of STAGE_IR_ONLY.
want() {
  [ -z "$STAGE_IR_ONLY" ] && return 0
  for _w in $STAGE_IR_ONLY; do [ "$_w" = "$1" ] && return 0; done
  return 1
}

# gen_scoperefs is SHARED with test/diff_compiler_ir_scaling.sh (#2172 attribution,
# S-5-scoperefs-attribution), sourced from test/perf_shapes.sh — unlike the shapes
# below, which are local transcriptions from perf_scaling.sh (#2066's charter names
# a generator a public contract only where a change to it must move ANOTHER gate's
# ledgered ceiling in lockstep; here it must move ir_scaling.sh's KNOWN_CEIL_scoperefs
# in lockstep, which is exactly that case). Same missing-library guard as
# ir_scaling.sh: `.` is a POSIX special builtin, so a moved/renamed library would
# otherwise die silently inside the `.` with no line of ours on stdout.
# (perf_scaling.sh ALSO sources this library, for gen_xref/gen_manyifaces, but is not a
# third consumer of this shape — it shadows the bare name `gen_scoperefs` with its own,
# unrelated local `gen_scoperefs_resolve`; see perf_shapes.sh's header on that generator.)
[ -r "$ROOT/test/perf_shapes.sh" ] || {
  echo "FAIL: cannot read $ROOT/test/perf_shapes.sh — the shared shape library (#2066) is missing."
  echo "  Both scoperefs consumers source it; without it neither can generate the shape."
  exit 1
}
. "$ROOT/test/perf_shapes.sh"

# ── the shapes (verbatim from test/diff_compiler_perf_scaling.sh) ────────────

gen_match() {
  gn=$1; gf=$2; : > "$gf"
  printf 'data T%s =\n' "$gn" >> "$gf"
  gi=0; while [ "$gi" -lt "$gn" ]; do
    if [ "$gi" -eq 0 ]; then printf '  C%s\n' "$gi"; else printf '  | C%s\n' "$gi"; fi
    gi=$((gi + 1))
  done >> "$gf"
  printf 'toInt : T%s -> Int\ntoInt v = match v\n' "$gn" >> "$gf"
  gi=0; while [ "$gi" -lt "$gn" ]; do printf '  C%s => %s\n' "$gi" "$gi"; gi=$((gi + 1)); done >> "$gf"
  # `main` CALLS `toInt` — load-bearing. `main = println 1` roots nothing, dceFilter
  # prunes `toInt` outright, and every backend stage then times an empty program.
  printf 'main = println (toInt C0)\n' >> "$gf"
}

# gen_match's GUARDED-WILDCARD sibling (issue #2125, the residual of #408's fix).
# The match INTERLEAVES a constructor arm `Ci => i` with a guarded catch-all arm
# `_ if k == i => i`, N times.
#
# ⚠️ THE INTERLEAVING IS THE SHAPE. A block of guarded `_` arms followed by the
# constructor arms measures nothing: `compileRows` tests `allWild pats` on the FIRST
# row before `buildConSwitch` is ever reached, so a leading run of guarded wildcards
# is peeled one row at a time and the con-switch sees no wildcard row at all. What
# this shape reaches instead is `conBranch`, which hands EVERY head its own
# `map (padWildRow a) wilds` merge of the column-0 wildcard rows — Θ(wildcards) per
# branch, and here both counts are Θ(N). The guards are load-bearing: an UNguarded
# `_` ahead of a constructor arm would make that arm unreachable.
#
# ⚠️ One arm in the actual generated program IS flagged unreachable regardless: the
# FINAL guarded wildcard, `_ if k == (N-1)`. Verified first-hand with `medaka check`
# on the N=5 shape — `unreachable match arm. This pattern is already covered by an
# earlier arm`, pointing at that last `_ if k == 4 => 4` row. The reason has nothing
# to do with the guard itself: by the time the match reaches that row every
# constructor of `T` has already been matched by an earlier `Ci => i` arm, so the
# type is exhausted and no value can still reach a trailing row, guarded or not.
# Every EARLIER guarded wildcard row IS reachable (the guard is what keeps it from
# swallowing the constructor arms below it, per the paragraph above) — only the last
# one is dead, as a consequence of exhaustiveness, not of the guard mechanism this
# shape exists to exercise. Harmless to what this generator measures: it is a
# `check`-only diagnostic, and `compileRows`/lowering still compile the row exactly
# as generated (no shape change from this comment fix).
#
# The perf_scaling.sh twin grades the same curve on NET ALLOCATION (ledger row
# KNOWN_CEIL_guardwild); this gate is the one that grades `lower` ITSELF, which is
# where #408 was found and where its residual lives — #408 was invisible to both the
# op and the alloc arm because a bucket miss is an alloc-free `c2 == c`.
gen_guardwild() {
  gn=$1; gf=$2; : > "$gf"
  printf 'data T =\n' >> "$gf"
  gi=0; while [ "$gi" -lt "$gn" ]; do
    if [ "$gi" -eq 0 ]; then printf '  C%s\n' "$gi"; else printf '  | C%s\n' "$gi"; fi
    gi=$((gi + 1))
  done >> "$gf"
  printf 'toInt : T -> Int -> Int\ntoInt v k = match v\n' >> "$gf"
  gi=0; while [ "$gi" -lt "$gn" ]; do
    printf '  C%s => %s\n' "$gi" "$gi"
    printf '  _ if k == %s => %s\n' "$gi" "$gi"
    gi=$((gi + 1))
  done >> "$gf"
  # Same rooting rule as gen_match, same reason.
  printf 'main = println (toInt C0 0)\n' >> "$gf"
}

gen_xref() {
  gn=$1; gf=$2; : > "$gf"
  printf 'f0 : Int -> Int\nf0 x = x + 1\n' >> "$gf"
  gi=1
  while [ "$gi" -lt "$gn" ]; do
    printf 'f%s : Int -> Int\nf%s x = f%s x + %s\n' "$gi" "$gi" "$((gi - 1))" "$gi"
    gi=$((gi + 1))
  done >> "$gf"
  # Same rooting rule as gen_match, same reason.
  printf 'main = println (f%s 0)\n' "$((gn - 1))" >> "$gf"
}

# #1030's shape: a chain of N nullary VALUE globals, each reading the previous one,
# rooted by `main`. Rooting is load-bearing twice over here — dceFilter prunes an
# unrooted chain, AND a value global that is never read is not a node the init-order
# sort has to place.
gen_vchain() {
  gn=$1; gf=$2; : > "$gf"
  printf 'g0 : Int\ng0 = 1\n' >> "$gf"
  gi=1
  while [ "$gi" -lt "$gn" ]; do
    printf 'g%s : Int\ng%s = g%s + 1\n' "$gi" "$gi" "$((gi - 1))"
    gi=$((gi + 1))
  done >> "$gf"
  printf 'main = println g%s\n' "$((gn - 1))" >> "$gf"
}

# gen_constrained — #1017's own shape, new for this slice. `markVar`/`markInfix`
# fall through to `contains x constrained`, a List-as-set scan against the pool of
# constrained-signature function names (`Eq a => …`). N constrained functions,
# each a EVar reference to the previous one (a chain, mirroring gen_xref), forces
# a full `constrained`-pool scan at each of N call sites: pool grows with N AND
# site count grows with N => O(N^2) pre-fix, O(N) (OrdMap membership) post-fix.
# `x == x` in f0's body also exercises the (already OrdMap-backed, #953) `methods`
# scan — inert here, kept only so f0 typechecks against `Eq`.
#
# DELIBERATE RED, observed pre-fix (S-frontend-list-as-set report §6.1, this
# generator, this band): `mark` at N=300/600/1200 read
# `** SUPERLINEAR (stage Ir) ** r1=3.337 r2=3.558 (threshold 3.0, both doublings)` —
# (verbatim from the run that produced it; the gate prints "r2 alone" since
# the #2173 flip, and BOTH ratios in this reading are over 3.0 either way) —
# i.e. this shape genuinely failed the gate before the fix. Fixed by commit
# `6df20241` (S-frontend-list-as-set: converted marker's `constrained` from a
# List-as-set scan to an `OrdMap Unit` membership set), after which the row reads
# linear (see the S-frontend-list-as-set report's §6.2 post-fix table).
gen_constrained() {
  gn=$1; gf=$2; : > "$gf"
  printf 'f0 : Eq a => a -> Bool\nf0 x = x == x\n' >> "$gf"
  gi=1
  while [ "$gi" -lt "$gn" ]; do
    printf 'f%s : Eq a => a -> Bool\nf%s x = f%s x\n' "$gi" "$gi" "$((gi - 1))"
    gi=$((gi + 1))
  done >> "$gf"
  printf 'main = println (if f%s 0 then 1 else 0)\n' "$((gn - 1))" >> "$gf"
}

# gen_wideiface — #1018's own shape, new for this slice. ONE interface with N
# methods, each written as the parser's SPLIT entry pair (a signature line, `f :
# T`, then a separate default-clause line, `f p = body`) — the exact shape
# `mergeIfaceDefaults`/`mergeIfaceMethods`/`foldlMethods` coalesce back into one
# `IfaceMethod` per name. Pre-fix, `insertMethod`'s `containsMethod` linear scan
# (a miss on the signature-line insert, a hit-then-`mergeInto`-scan on the
# default-line insert) is O(current acc size) per insert => O(N^2) over N
# methods. This is DELIBERATELY not `gen_marksweep` (signature-only methods, no
# split/default lines — never exercises `mergeInto`) — see the packet's own
# note that `gen_marksweep` triple-blinds #1018 on the OLD (TIME/ALLOC/OP) arms
# without ever reaching this merge path with a duplicate-name insert.
#
# DELIBERATE RED, observed pre-fix (S-frontend-list-as-set report §6.1, this
# generator, this band): `desugar` at N=125/250/500 read
# `** SUPERLINEAR (stage Ir) ** r1=3.680 r2=3.973 (threshold 3.0, both doublings)` —
# (verbatim from the run that produced it; the gate prints "r2 alone" since
# the #2173 flip, and BOTH ratios in this reading are over 3.0 either way) —
# this shape genuinely failed the gate before the fix. Fixed by commit `6df20241`
# (S-frontend-list-as-set: converted `mergeIfaceDefaults`/`mergeIfaceMethods`'s
# `insertMethod`/`containsMethod` linear scan off List-as-set), after which the
# row reads linear (see the S-frontend-list-as-set report's §6.2 post-fix table).
gen_wideiface() {
  gn=$1; gf=$2; : > "$gf"
  printf 'interface Wide a where\n' >> "$gf"
  gi=0
  while [ "$gi" -lt "$gn" ]; do
    printf '  m%s : a -> a\n  m%s x = x\n' "$gi" "$gi"
    gi=$((gi + 1))
  done >> "$gf"
  printf 'main = println 1\n' >> "$gf"
}

# gen_modules / gen_mod_records — the DIRECTORY-shaped shape, transcribed verbatim
# from test/diff_compiler_perf_scaling.sh (same [T-SHARED-CORPUS] rule as the three
# above: a gate's generators live in the gate, never in a shared fixture dir, and
# never `source`d out of another gate). N modules chained by `export import`
# (m0 <- m1 <- ... <- m{N-1} <- entry), each declaring MOD_K data types + MOD_K
# impls of a re-exported interface `Widget`, MOD_R short-form records over MOD_F
# SHARED field names, and exercising every one of its impls in a local `use` value.
#
# ⚠️ THE FIXTURE MUST RESOLVE 0-DIAGNOSTIC, or this arm measures a different
# mechanism. markModules/checkModules do not run frontend.resolve's result, so a
# resolve-BROKEN corpus still grows with N — but that growth can be the compiler
# re-failing to bind the same unresolved names once per module, NOT the accumulated-
# universe rescan. Three properties are load-bearing and were each reproduced with
# `medaka check` when perf_scaling's copy was written: `export import` (a plain
# import does not re-export), `public export data` (a plain `export data` is
# abstract, so the CONSTRUCTOR is not exported), and importing the interface METHOD
# `wval` so dispatch has something to dispatch on. Change any of them and re-verify
# 0 diagnostics before trusting a single ratio below.
#
# Why K>1 and why IMPLS: a plain function chain scales LINEARLY here — the
# accumulated universe these passes rescan is impl/interface/data decls, not plain
# bindings. Why MOD_R x MOD_F: every module sharing FIELD NAMES is what makes
# fieldOwnersRef[f<j>] grow to N*MOD_R owners; without records that whole path
# short-circuits on an empty list and a real 5.6x defect reads as `ok`.
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

# ── measurement ──────────────────────────────────────────────────────────────

# Run the profiler once under callgrind and cache the annotate output for this
# (shape, N). MEDAKA_PERF=1 is what makes profile_main run at all (without it the
# driver exits silently). MEDAKA_PERF_WASM is explicitly UNSET, not set to "": the
# driver's `perfWasmEnabled` reads the variable's PRESENCE, so an exported empty
# string would switch the ~10x wasm backend on and re-price this gate out of its
# shard behind a developer's back.
run_profile() {
  _out="$WORK/cg_$1.out"
  unset MEDAKA_PERF_WASM
  MEDAKA_PERF=1 GC_INITIAL_HEAP_SIZE="$IR_HEAP" \
  valgrind --tool=callgrind --cache-sim=no --branch-sim=no \
    --callgrind-out-file="$_out" \
    "$PROFILE" "$RUNTIME" "$CORE" "$2" >"$WORK/prof.out" 2>"$WORK/prof.err"
  _rc=$?
  # ⚠️ A profiler that DIED partway reads a DEPRESSED count at the larger N and can
  # grade GREEN while crashing — exactly the failure ir_scaling's assert_clean
  # exists to stop. profile_main's own `[perf] total` row is the completion
  # receipt: it is emitted last, after every stage.
  if [ "$_rc" -ne 0 ] || ! grep -q '^\[perf\] total' "$WORK/prof.err"; then
    echo "FAIL: profile_main did not complete on $2 (exit $_rc, no [perf] total row)."
    sed 's/^/  /' "$WORK/prof.err" | tail -20
    return 1
  fi
  callgrind_annotate --inclusive=yes --threshold=100 "$_out" > "$WORK/ann_$1.txt" 2>/dev/null || {
    echo "FAIL: callgrind_annotate produced nothing for $2."
    return 1
  }
  return 0
}

# The DIRECTORY-shaped sibling of run_profile. It is a sibling and not a flag on
# run_profile deliberately: profile_modules_main takes FOUR positional arguments
# (runtime, core, ENTRY FILE, ROOT DIR) where profile_main takes three, and the
# whole `gen_$shape N FILE` / `run_profile TAG FILE` calling convention above is
# file-shaped. Parameterising it would mean a driver-dispatch refactor of
# grade_shape for one caller; two small functions that each say what they do are
# cheaper to read and cannot silently pass a directory where a file was meant.
# The argv shape is the same one diff_compiler_perf_scaling.sh:1183,1289 already
# uses. Everything else — the heap pin, the unset MEDAKA_PERF_WASM, the
# `[perf] total` completion receipt, the annotate invocation — is IDENTICAL to
# run_profile and must stay that way; see those blocks for why each is there.
run_profile_modules() {
  _out="$WORK/cg_$1.out"
  unset MEDAKA_PERF_WASM
  MEDAKA_PERF=1 GC_INITIAL_HEAP_SIZE="$IR_HEAP" \
  valgrind --tool=callgrind --cache-sim=no --branch-sim=no \
    --callgrind-out-file="$_out" \
    "$PROFILE_MODULES" "$RUNTIME" "$CORE" "$2/entry.mdk" "$2" \
    >"$WORK/prof.out" 2>"$WORK/prof.err"
  _rc=$?
  if [ "$_rc" -ne 0 ] || ! grep -q '^\[perf\] total' "$WORK/prof.err"; then
    echo "FAIL: profile_modules_main did not complete on $2 (exit $_rc, no [perf] total row)."
    sed 's/^/  /' "$WORK/prof.err" | tail -20
    return 1
  fi
  callgrind_annotate --inclusive=yes --threshold=100 "$_out" > "$WORK/ann_$1.txt" 2>/dev/null || {
    echo "FAIL: callgrind_annotate produced nothing for $2."
    return 1
  }
  return 0
}

# Read one stage's inclusive Ir out of a cached annotate listing.
# 🚨 A symbol that does not resolve is a HARD FAIL, never 0. If the emitter's name
# mangling changes, or a stage entry point is renamed or inlined away, this gate
# would otherwise read every net as 0, SKIP every stage under the netting guard,
# and report a cheerful green having graded nothing.
stage_ir() {
  _v="$(grep -F "$2 [" "$WORK/ann_$1.txt" | head -1 | sed 's/[^0-9,]*\([0-9,]*\).*/\1/' | tr -d ',')"
  case "$_v" in
    ''|*[!0-9]*)
      echo "FAIL: no inclusive Ir for symbol '$2' in the $1 profile." >&2
      echo "  The stage entry point was renamed, inlined, or never ran — this gate" >&2
      echo "  cannot grade it and must not pretend it graded 0. Re-derive with:" >&2
      echo "    nm $PROFILE | grep $2" >&2
      return 1 ;;
  esac
  printf '%s' "$_v"
}

fail=0
known=0
graded=0

# ── OBSERVED RED: every verdict branch of grade_shape (#2160 phase 2, rule 1) ──
#
# All five recorded on this box, 2026-08-28/29, with the add-only knobs only —
# the function below was NOT edited to force any of them. Band `xref` at
# STAGE_IR_XREF_N=20 (20/40/80) throughout: these are BRANCH observations, and a
# small band keeps the Callgrind cost bounded. The ratios in them are therefore
# NOT evidence about xref's real scaling; the shipped band is XREF_N=125.
#
# 1. SUPERLINEAR (the threshold arm, line ~1047)
#    $ STAGE_IR_ONLY=xref STAGE_IR_XREF_N=20 STAGE_IR_THRESH=1.5 sh test/diff_compiler_stage_ir_scaling.sh
#      parse     ** SUPERLINEAR (stage Ir) ** r1=2.053 r2=2.028 (threshold 1.5, r2 alone)
#      ... (9 of 9 graded stages, exhaust/desugar/resolve/mark/typecheck/mangle/dce/trmc alike)
#    FAIL: 9 stage-ratio(s) graded, 9 over the line.        exit=1
#
# 2. MALFORMED LEDGER ROW (a ledger entry with no CEIL/FIXED pair, line ~1029)
#    $ STAGE_IR_ONLY=xref STAGE_IR_XREF_N=20 STAGE_IR_LEDGER_EXTRA=xref:parse sh ...
#      parse     ** MALFORMED LEDGER ROW ** "xref:parse" has no KNOWN_CEIL/KNOWN_FIXED pair.
#              A ledger row without both halves cannot drain itself — that is a skip-list, not a pin.
#    FAIL: 9 stage-ratio(s) graded, 1 over the line.        exit=1
#
# 3. KNOWN-SLOW, AND GOT WORSE (the ceiling half, line ~1036)
#    $ ... STAGE_IR_LEDGER_EXTRA=xref:parse KNOWN_CEIL_xref_parse=1.20 KNOWN_FIXED_xref_parse=1.00 sh ...
#      parse     ** KNOWN-SLOW, AND GOT WORSE ** r1=2.053 r2=2.028 (ceiling 1.20)
#    FAIL: 9 stage-ratio(s) graded, 1 over the line.        exit=1
#
# 4. PROMOTE: now scales LINEARLY (the self-draining half, line ~1039)
#    $ ... STAGE_IR_LEDGER_EXTRA=xref:parse KNOWN_CEIL_xref_parse=9.00 KNOWN_FIXED_xref_parse=3.00 sh ...
#      parse     ** PROMOTE: now scales LINEARLY ** r2=2.028 (< 3.00)
#              Remove "xref:parse" from KNOWN_SLOW — the quadratic is FIXED.
#    FAIL: 9 stage-ratio(s) graded, 1 over the line.        exit=1
#    ⇒ the ledger drains itself. A row kept past its fix FAILS; it cannot go quiet.
#
# 5. graded ZERO stages (the band-is-mis-sized guard, line ~1058)
#    $ STAGE_IR_ONLY=xref STAGE_IR_XREF_N=20 STAGE_IR_MIN_NET_FRAC=50 sh ...
#      (every stage SKIPs under the netting guard)
#      FAIL xref: graded ZERO stages — the band is mis-sized and this shape proved nothing.
#    FAIL: 0 stage-ratio(s) graded, 1 over the line.        exit=1
#    ⇒ note this is the PER-SHAPE guard, which stays live under STAGE_IR_ONLY; the
#      whole-gate `graded == 0` guard is the one the narrowing deliberately skips,
#      and the same transcript prints that NOTE two lines further down.
#
grade_shape() {
  shape="$1"; base_n="$2"
  want "$shape" || return 0
  n1="$base_n"; n2=$((base_n * 2)); n4=$((base_n * 4))
  shape_graded=0

  echo "── $shape (N=$FLOOR_N floor, $n1/$n2/$n4) ──"
  for m in "$FLOOR_N" "$n1" "$n2" "$n4"; do
    "gen_$shape" "$m" "$WORK/${shape}_$m.mdk" || { fail=$((fail + 1)); return 1; }
    run_profile "${shape}_$m" "$WORK/${shape}_$m.mdk" || { fail=$((fail + 1)); return 1; }
  done

  for pair in $STAGE_SYMS; do
    st="${pair%%=*}"; sym="${pair#*=}"
    f0="$(stage_ir "${shape}_$FLOOR_N" "$sym")" || { fail=$((fail + 1)); return 1; }
    v1="$(stage_ir "${shape}_$n1" "$sym")" || { fail=$((fail + 1)); return 1; }
    v2="$(stage_ir "${shape}_$n2" "$sym")" || { fail=$((fail + 1)); return 1; }
    v3="$(stage_ir "${shape}_$n4" "$sym")" || { fail=$((fail + 1)); return 1; }
    d1=$((v1 - f0)); d2=$((v2 - f0)); d3=$((v3 - f0))
    min_net="$(awk -v f="$f0" -v p="$MIN_NET_FRAC" 'BEGIN{printf "%d", f*p}')"
    if [ "$d1" -le "$min_net" ]; then
      # ⚠️ A LEDGERED ROW MAY NOT SKIP HERE (#2150). For an unledgered row the netting
      # guard is right: the shape is doing too little work at this N to yield a ratio, so
      # decline. But a KNOWN_SLOW entry ASSERTS this row is superlinear, and "too small to
      # net" contradicts that assertion — the likeliest cause is the ledgered quadratic
      # having been fixed. Skipping silently means nobody is ever told to drain the row,
      # so it rots in the ledger forever behind a green gate. Loud, or it is a skip-list.
      if is_known "${shape}:${st}"; then
        printf '  %-9s ** PROMOTE: ledgered, but now under the netting guard ** net %s at N=%s (<= %s of floor %s)\n' \
          "$st" "$d1" "$n1" "$min_net" "$f0"
        printf '          Remove "%s:%s" from KNOWN_SLOW — the quadratic is FIXED — or raise the band.\n' "$shape" "$st"
        printf '          It may NOT stay ledgered AND ungraded.\n'
        fail=$((fail + 1))
        continue
      fi
      printf '  %-9s SKIP — net at N=%s (%s) under the netting guard (%s of floor %s)\n' \
        "$st" "$n1" "$d1" "$min_net" "$f0"
      continue
    fi
    shape_graded=$((shape_graded + 1)); graded=$((graded + 1))
    r1="$(awk -v a="$d1" -v b="$d2" 'BEGIN{printf "%.3f", b/a}')"
    r2="$(awk -v a="$d2" -v b="$d3" 'BEGIN{printf "%.3f", b/a}')"
    # ── THE DETERMINISTIC-ARM VERDICT RULE (#2173, applied here by #2160 phase 2) ──
    #
    # r2 ALONE, not `r1 && r2`. Callgrind `Ir` is a deterministic instrument: the
    # count is a pure function of the input program, so there is no run-to-run
    # noise for a second confirming doubling to filter out. The conjunct was
    # borrowed from the WALL-CLOCK arm of perf_scaling, where it earns its keep,
    # and #2100 removed it from ir_scaling for exactly this reason. It survived
    # here because the header claimed parity with two gates that had already
    # stopped doing it.
    #
    # ⚠️ It is also WRONG in a specific, reachable way, not merely redundant: a
    # quadratic whose linear term still dominates at the first doubling produces
    # r1 < 3.0 < r2 and is dropped on the floor. That is not hypothetical — it is
    # how #2189 (`elaborate`, two shapes, ratios climbing 2.52 -> 3.04 -> 3.44)
    # hid inside perf_scaling's op arm until the same flip was applied there.
    #
    # ENUMERATED BEFORE FLIPPING (#2173's own instruction, and #2160 rule 2 —
    # a flip must not be shipped on the argument alone). One full run of this
    # gate at the SHIPPED bands, this box, 2026-08-29, before the change:
    #
    #   60 stage-ratios graded across match / xref / vchain / constrained /
    #   wideiface / modules. The LARGEST r2 anywhere is 2.755
    #   (constrained:typecheck, r1=2.545), and the only ledgered row reads
    #   modules:typecheck r1=2.192 r2=2.219 against its 2.45 ceiling.
    #
    # So NO row sits between the threshold and the conjunct: the flip turns
    # nothing red today, and the nearest row has 8.9% of headroom to 3.0. This
    # tightens the gate for free. It is not a band change and no threshold moved.
    over="$(awk -v y="$r2" -v t="$THRESH" 'BEGIN{print (y>t) ? "yes" : "no"}')"
    printf '  %-9s net %s -> %s -> %s\n' "$st" "$d1" "$d2" "$d3"
    if is_known "${shape}:${st}"; then
      lk="$(printf '%s_%s' "$shape" "$st" | tr -c 'a-zA-Z0-9_' '_')"
      eval "ceil=\${KNOWN_CEIL_$lk:-}"
      eval "fixed=\${KNOWN_FIXED_$lk:-}"
      if [ -z "$ceil" ] || [ -z "$fixed" ]; then
        printf '  %-9s ** MALFORMED LEDGER ROW ** "%s" has no KNOWN_CEIL/KNOWN_FIXED pair.\n' "$st" "${shape}:${st}"
        echo "          A ledger row without both halves cannot drain itself — that is a skip-list, not a pin."
        fail=$((fail + 1)); continue
      fi
      worse="$(awk -v r="$r2" -v c="$ceil" 'BEGIN{print (r > c) ? 1 : 0}')"
      better="$(awk -v r="$r2" -v f="$fixed" 'BEGIN{print (r < f) ? 1 : 0}')"
      if [ "$worse" = "1" ]; then
        printf '  %-9s ** KNOWN-SLOW, AND GOT WORSE ** r1=%s r2=%s (ceiling %s)\n' "$st" "$r1" "$r2" "$ceil"
        fail=$((fail + 1))
      elif [ "$better" = "1" ]; then
        printf '  %-9s ** PROMOTE: now scales LINEARLY ** r2=%s (< %s)\n' "$st" "$r2" "$fixed"
        printf '          Remove "%s:%s" from KNOWN_SLOW — the quadratic is FIXED.\n' "$shape" "$st"
        fail=$((fail + 1))
      else
        printf '  %-9s known-slow r1=%s r2=%s (ceiling %s) — ledgered, see the header\n' "$st" "$r1" "$r2" "$ceil"
        known=$((known + 1))
      fi
    elif [ "$over" = "yes" ]; then
      printf '  %-9s ** SUPERLINEAR (stage Ir) ** r1=%s r2=%s (threshold %s, r2 alone)\n' \
        "$st" "$r1" "$r2" "$THRESH"
      fail=$((fail + 1))
    else
      printf '  %-9s ok   r1=%s r2=%s (threshold %s)\n' "$st" "$r1" "$r2" "$THRESH"
    fi
  done

  # A shape that graded NO stage proved nothing about itself — the band is
  # mis-sized or the profiler stopped running the backend at all.
  if [ "$shape_graded" -eq 0 ]; then
    printf 'FAIL %s: graded ZERO stages — the band is mis-sized and this shape proved nothing.\n' "$shape"
    fail=$((fail + 1))
  fi
  echo
  return 0
}

# ── OBSERVED RED: every verdict branch of grade_modules (#2160 phase 2, rule 1) ──
#
# The twin's branches, all five, same day, same rules. Band STAGE_IR_MOD_N=3
# STAGE_IR_MOD_K=2 (3/6/12 modules) — again a BRANCH observation, not a
# measurement. ⚠️ At that band the fixed per-module cost dominates and r1 reads
# ~4.0 on every stage; that is the tiny band, NOT a finding about the multi-module
# driver. The shipped band is MOD_N=25/K=8, where the same rows read r1≈2.09.
#
# 1. SUPERLINEAR (line ~1135)
#    $ STAGE_IR_ONLY=modules STAGE_IR_MOD_N=3 STAGE_IR_MOD_K=2 STAGE_IR_THRESH=1.5 sh ...
#      parse     ** SUPERLINEAR (stage Ir) ** r1=4.007 r2=2.502 (threshold 1.5, r2 alone)
#      load      ** SUPERLINEAR (stage Ir) ** r1=4.006 r2=2.502 (threshold 1.5, r2 alone)
#      resolve   ** SUPERLINEAR (stage Ir) ** r1=4.003 r2=2.502 (threshold 1.5, r2 alone)
#      typecheck ** KNOWN-SLOW, AND GOT WORSE ** r1=4.068 r2=2.537 (ceiling 2.45)
#    FAIL: 4 stage-ratio(s) graded, 4 over the line.        exit=1
#
# 2. MALFORMED LEDGER ROW (line ~1117)
#    $ ... STAGE_IR_LEDGER_EXTRA=modules:parse sh ...
#      parse     ** MALFORMED LEDGER ROW ** "modules:parse" has no KNOWN_CEIL/KNOWN_FIXED pair.
#    FAIL: 4 stage-ratio(s) graded, 2 over the line.        exit=1
#
# 3. KNOWN-SLOW, AND GOT WORSE (line ~1124)
#    $ ... STAGE_IR_LEDGER_EXTRA=modules:parse KNOWN_CEIL_modules_parse=1.20 \
#          KNOWN_FIXED_modules_parse=1.00 sh ...
#      parse     ** KNOWN-SLOW, AND GOT WORSE ** r1=4.007 r2=2.502 (ceiling 1.20)
#    FAIL: 4 stage-ratio(s) graded, 2 over the line.        exit=1
#
# 4. PROMOTE: now scales LINEARLY (line ~1127)
#    $ ... STAGE_IR_LEDGER_EXTRA=modules:parse KNOWN_CEIL_modules_parse=9.00 \
#          KNOWN_FIXED_modules_parse=3.00 sh ...
#      parse     ** PROMOTE: now scales LINEARLY ** r2=2.502 (< 3.00)
#              Remove "modules:parse" from KNOWN_SLOW — the quadratic is FIXED.
#    FAIL: 4 stage-ratio(s) graded, 2 over the line.        exit=1
#
# 5. graded ZERO stages (line ~1144)
#    $ ... STAGE_IR_MIN_NET_FRAC=50 sh ...
#      FAIL modules: graded ZERO stages — the band is mis-sized and this shape proved nothing.
#    FAIL: 0 stage-ratio(s) graded, 2 over the line.        exit=1
#
# The fifth branch of the netting guard — PROMOTE: ledgered, but now under the
# netting guard (line ~1096) — is recorded separately above, at STAGE_IR_MIN_NET_FRAC=5
# on the SHIPPED band; see the block by KNOWN_SLOW. That is the one the phase-1
# header called never-observed, and it is the reason this whole set was run.
#
# grade_modules — grade_shape's multi-module twin. Same netting rule, same
# MIN_NET_FRAC guard, same 3.0 threshold, same ledger, same `graded`/`fail`
# counters, same zero-graded hard FAIL. It is a separate function rather than a
# mode on grade_shape because the two calling conventions genuinely differ (see
# run_profile_modules) — NOT because the grading differs. If you change the
# grading rule in one, change it in the other; they are a lockstep pair.
grade_modules() {
  want modules || return 0
  mdn1="$MOD_N"; mdn2=$((MOD_N * 2)); mdn4=$((MOD_N * 4))
  mod_graded=0

  echo "── modules (N=$MOD_FLOOR_N floor, $mdn1/$mdn2/$mdn4 modules, K=$MOD_K impls each) ──"
  for mdm in "$MOD_FLOOR_N" "$mdn1" "$mdn2" "$mdn4"; do
    gen_modules "$mdm" "$WORK/modules_$mdm" "$MOD_K" || { fail=$((fail + 1)); return 1; }
    run_profile_modules "modules_$mdm" "$WORK/modules_$mdm" || { fail=$((fail + 1)); return 1; }
  done

  for mdpair in $MOD_SYMS; do
    mdst="${mdpair%%=*}"; mdsym="${mdpair#*=}"
    mdf0="$(stage_ir "modules_$MOD_FLOOR_N" "$mdsym")" || { fail=$((fail + 1)); return 1; }
    mdv1="$(stage_ir "modules_$mdn1" "$mdsym")" || { fail=$((fail + 1)); return 1; }
    mdv2="$(stage_ir "modules_$mdn2" "$mdsym")" || { fail=$((fail + 1)); return 1; }
    mdv3="$(stage_ir "modules_$mdn4" "$mdsym")" || { fail=$((fail + 1)); return 1; }
    mdd1=$((mdv1 - mdf0)); mdd2=$((mdv2 - mdf0)); mdd3=$((mdv3 - mdf0))
    mdmin="$(awk -v f="$mdf0" -v p="$MIN_NET_FRAC" 'BEGIN{printf "%d", f*p}')"
    if [ "$mdd1" -le "$mdmin" ]; then
      # LOCKSTEP with grade_shape's netting guard above — see the #2150 note there.
      # A ledgered row that falls under the guard is a DRAIN CLAIM, not an absence of
      # signal, and must be loud. These two functions are a lockstep pair by contract
      # (see grade_modules' header): change the rule in one, change it in the other.
      if is_known "modules:${mdst}"; then
        printf '  %-9s ** PROMOTE: ledgered, but now under the netting guard ** net %s at N=%s (<= %s of floor %s)\n' \
          "$mdst" "$mdd1" "$mdn1" "$mdmin" "$mdf0"
        printf '          Remove "modules:%s" from KNOWN_SLOW — the quadratic is FIXED — or raise the band.\n' "$mdst"
        printf '          It may NOT stay ledgered AND ungraded.\n'
        fail=$((fail + 1))
        continue
      fi
      printf '  %-9s SKIP — net at N=%s (%s) under the netting guard (%s of floor %s)\n' \
        "$mdst" "$mdn1" "$mdd1" "$mdmin" "$mdf0"
      continue
    fi
    mod_graded=$((mod_graded + 1)); graded=$((graded + 1))
    mdr1="$(awk -v a="$mdd1" -v b="$mdd2" 'BEGIN{printf "%.3f", b/a}')"
    mdr2="$(awk -v a="$mdd2" -v b="$mdd3" 'BEGIN{printf "%.3f", b/a}')"
    # r2 ALONE — see the note in grade_shape above. These two functions are a
    # lockstep pair and the rule must be identical in both.
    mdover="$(awk -v y="$mdr2" -v t="$THRESH" 'BEGIN{print (y>t) ? "yes" : "no"}')"
    printf '  %-9s net %s -> %s -> %s\n' "$mdst" "$mdd1" "$mdd2" "$mdd3"
    if is_known "modules:${mdst}"; then
      mdlk="$(printf 'modules_%s' "$mdst" | tr -c 'a-zA-Z0-9_' '_')"
      eval "ceil=\${KNOWN_CEIL_$mdlk:-}"
      eval "fixed=\${KNOWN_FIXED_$mdlk:-}"
      if [ -z "$ceil" ] || [ -z "$fixed" ]; then
        printf '  %-9s ** MALFORMED LEDGER ROW ** "%s" has no KNOWN_CEIL/KNOWN_FIXED pair.\n' "$mdst" "modules:${mdst}"
        echo "          A ledger row without both halves cannot drain itself — that is a skip-list, not a pin."
        fail=$((fail + 1)); continue
      fi
      mdworse="$(awk -v r="$mdr2" -v c="$ceil" 'BEGIN{print (r > c) ? 1 : 0}')"
      mdbetter="$(awk -v r="$mdr2" -v f="$fixed" 'BEGIN{print (r < f) ? 1 : 0}')"
      if [ "$mdworse" = "1" ]; then
        printf '  %-9s ** KNOWN-SLOW, AND GOT WORSE ** r1=%s r2=%s (ceiling %s)\n' "$mdst" "$mdr1" "$mdr2" "$ceil"
        fail=$((fail + 1))
      elif [ "$mdbetter" = "1" ]; then
        printf '  %-9s ** PROMOTE: now scales LINEARLY ** r2=%s (< %s)\n' "$mdst" "$mdr2" "$fixed"
        printf '          Remove "modules:%s" from KNOWN_SLOW — the quadratic is FIXED.\n' "$mdst"
        fail=$((fail + 1))
      else
        printf '  %-9s known-slow r1=%s r2=%s (ceiling %s) — ledgered, see the header\n' "$mdst" "$mdr1" "$mdr2" "$ceil"
        known=$((known + 1))
      fi
    elif [ "$mdover" = "yes" ]; then
      printf '  %-9s ** SUPERLINEAR (stage Ir) ** r1=%s r2=%s (threshold %s, r2 alone)\n' \
        "$mdst" "$mdr1" "$mdr2" "$THRESH"
      fail=$((fail + 1))
    else
      printf '  %-9s ok   r1=%s r2=%s (threshold %s)\n' "$mdst" "$mdr1" "$mdr2" "$THRESH"
    fi
  done

  if [ "$mod_graded" -eq 0 ]; then
    printf 'FAIL modules: graded ZERO stages — the band is mis-sized and this shape proved nothing.\n'
    fail=$((fail + 1))
  fi
  echo
  return 0
}

echo "── per-stage Ir scaling (Callgrind, inclusive, net of a per-shape floor) ──"
echo "profiler: $PROFILE"
echo "profiler (multi-module): $PROFILE_MODULES"
valgrind --version
echo

grade_shape match "$MATCH_N"
grade_shape xref "$XREF_N"
grade_shape vchain "$VCHAIN_N"
grade_shape constrained "$CONSTR_N"
grade_shape wideiface "$WIDEIFACE_N"
grade_shape guardwild "$GUARDWILD_N"
grade_shape scoperefs "$SCOPEREFS_N"
grade_modules

# ⚠️ ZERO GRADED IS A FAILURE UNDER NARROWING TOO. This guard USED TO be SKIPPED
# when STAGE_IR_ONLY was set, on the reasoning that grading nothing is "scope, not
# health" when the narrowing was deliberate. That was wrong in the one direction
# this gate cannot afford: it let `STAGE_IR_ONLY=<typo>` print the word PASS and
# exit 0 having measured nothing at all. A green that proved nothing is exactly the
# failure mode #2160 exists to remove, and the sibling knob in
# test/diff_compiler_ir_scaling.sh (IR_ONLY) had it right all along — it fails.
# There is no legitimate use for a narrowed run that matches no unit: the name is
# either a typo or a unit that no longer exists, and both deserve a red.
#
# OBSERVED RED (#2160 phase 2, this box):
#   $ STAGE_IR_ONLY=bogus sh test/diff_compiler_stage_ir_scaling.sh
#   FAIL: STAGE_IR_ONLY=[bogus] matched no unit — this run graded nothing.
#   exit=1
if [ "$graded" -eq 0 ] && [ -n "$STAGE_IR_ONLY" ]; then
  echo "FAIL: STAGE_IR_ONLY=[$STAGE_IR_ONLY] matched no unit — this run graded nothing."
  echo "      Valid units: match xref vchain constrained wideiface modules"
  echo "      (derive:  grep -n '^grade_shape \\|^grade_modules$' $0 )"
  exit 1
elif [ "$graded" -eq 0 ]; then
  echo "FAIL: no stage was graded — this gate proved nothing."
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "FAIL: $graded stage-ratio(s) graded, $fail over the line."
  exit 1
fi

if [ -n "$STAGE_IR_ONLY" ]; then
  echo "NARROWED OK (NOT a gate result): $graded stage-ratio(s) graded ($known ledgered) under STAGE_IR_ONLY=[$STAGE_IR_ONLY]."
else
  echo "PASS: $graded stage-ratio(s) graded ($known ledgered), all sub-quadratic in stage Ir (threshold $THRESH)."
fi
exit 0
