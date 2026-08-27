#!/bin/sh
# diff_compiler_stage_ir_scaling.sh — the DETERMINISTIC superlinearity detector for
# the BUILD-PATH stages (lower / emit / mangle / dce / trmc), measured in
# PER-STAGE Callgrind INSTRUCTION COUNTS.
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
# 3.0 per doubling, BOTH doublings, exactly as diff_compiler_ir_scaling.sh and
# diff_compiler_perf_scaling.sh. Three gates, one number; do not invent a fourth.
#     linear 2.0 | n log n ~2.1 | n^1.5 2.83 | QUADRATIC 4.0
# MEASURED margins at the shipped bands, this box, on this tree:
#     xref:lower   r1 2.097  r2 2.106      xref:emit   r1 2.127  r2 2.152
#     match:lower  r1 3.328  r2 3.640      match:emit  r1 2.110  r2 2.156
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
# x2.09). Only instruction counts see it. Whoever fixes #408 should start in
# compiler/ir/core_ir_lower.mdk, not in the emitter — and should re-read #408's own
# wall-clock table knowing that profile_main's `emit` row at N=1 already costs more
# than the whole shape-attributable cost at N=1000.
#
# ── THE LEDGER ───────────────────────────────────────────────────────────────
#
# `match:lower` is REAL, LIVE and UNFIXED at this tree, so this gate is born with a
# red reading. It ships LEDGERED, not disabled — the same self-draining contract
# perf_scaling's KNOWN_SLOW_OPS uses: green now, but FAILS if the ratio worsens past
# its ceiling AND fails demanding promotion the moment a fix drops it back to
# linear. To SEE the red this gate is pinning, run it with the ledger off:
#
#     STAGE_IR_NO_LEDGER=1 sh test/diff_compiler_stage_ir_scaling.sh
#
# ── COST ─────────────────────────────────────────────────────────────────────
#
# 8 callgrind invocations (2 shapes x (1 floor + 3 sizes)). Sequential on purpose —
# callgrind is single-threaded and a noisy neighbour would perturb nothing here, but
# fanning out would buy nothing either. Measured wall on this box: see the report
# for S-build-ir-arm; re-derive with `time sh test/diff_compiler_stage_ir_scaling.sh`.
#
# Usage:  sh test/diff_compiler_stage_ir_scaling.sh
#         STAGE_IR_MATCH_N=250 sh test/diff_compiler_stage_ir_scaling.sh
#         STAGE_IR_NO_LEDGER=1 sh test/diff_compiler_stage_ir_scaling.sh
# Exit:   0 every graded stage scales sub-quadratically (ledgered rows excepted)
#         1 a stage regressed, or a ledgered row must be promoted
#         2 skip (valgrind not on PATH) / phantom skip (oracle not built)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$ROOT/test/bin/profile_main"
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

if ! command -v valgrind >/dev/null 2>&1; then
  echo "SKIP: valgrind not on PATH — this gate measures Callgrind instruction counts."
  echo "  Debian/Ubuntu: sudo apt-get install -y valgrind"
  exit 2
fi
if ! command -v callgrind_annotate >/dev/null 2>&1; then
  echo "SKIP: callgrind_annotate not on PATH — it ships with valgrind."
  echo "  Debian/Ubuntu: sudo apt-get install -y valgrind"
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

THRESH="${STAGE_IR_THRESH:-3.0}"
IR_HEAP="${STAGE_IR_HEAP:-2147483648}"
FLOOR_N="${STAGE_IR_FLOOR_N:-1}"
MATCH_N="${STAGE_IR_MATCH_N:-125}"
XREF_N="${STAGE_IR_XREF_N:-125}"

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
# gate grades FIVE stages off one run, and a shape legitimately leaves some of them
# untouched (nothing scales `dce` on `xref`). A blanket FAIL would make it
# impossible to grade any stage without sizing the band for the smallest. The
# no-silent-green invariant is preserved instead by `graded`: a shape that grades
# ZERO stages is a hard FAIL, and so is a whole run that grades nothing.
MIN_NET_FRAC="${STAGE_IR_MIN_NET_FRAC:-0.02}"

# ── the stages, by the symbol profile_main calls to run them ─────────────────
#
# One `<stage>=<mangled symbol>` pair per word. The names on the left are the same
# names profile_main's own `[perf]` rows use, deliberately, so a reader can line the
# two up. `trmc` is `detectDispatchGroups`, which runs INSIDE emitProgram — its
# inclusive count is therefore a SUBSET of `emit`'s, not a sibling of it. That is
# intentional and it is why it is listed separately: #1029's cubic lived there and a
# 5% slice of emit is invisible in emit's own ratio.
STAGE_SYMS="lower=mdk_ir_core_ir_lower__lowerProgramEmit \
emit=mdk_backend_llvm_emit__emitProgram \
mangle=mdk_backend_private_mangle__mangleUnits \
dce=mdk_ir_dce__dceFilter \
trmc=mdk_backend_trmc_analysis__detectDispatchGroups"

# ── KNOWN SLOW — a self-draining ledger, NOT a skip list ────────────────────
#
# One `shape:stage` per line. Each row records a REAL, currently-superlinear stage
# ratio: the gate stays green, but FAILS if the ratio worsens past its ceiling and
# FAILS demanding promotion the instant a fix drops it back to linear.
#
#   match:lower — issue #408. MEASURED at this band on this tree: r1 3.328
#         r2 3.640, climbing (the quadratic signature; the pure-quadratic asymptote
#         is 4.0). Ceiling 4.00 leaves ~10% headroom and still breaks on a cubic
#         regression; FIXED 2.60 promotes the row the moment the ratio returns to
#         the ~2.1 every other stage/shape pair reads here. See the attribution
#         block above — this is a `lower` defect, and #408's title says `emit`.
KNOWN_SLOW="
match:lower
"
KNOWN_CEIL_match_lower="4.00"; KNOWN_FIXED_match_lower="2.60"

is_known() {
  [ -n "${STAGE_IR_NO_LEDGER:-}" ] && return 1
  for _k in $KNOWN_SLOW; do [ "$_k" = "$1" ] && return 0; done
  return 1
}

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

grade_shape() {
  shape="$1"; base_n="$2"
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
      printf '  %-7s SKIP — net at N=%s (%s) under the netting guard (%s of floor %s)\n' \
        "$st" "$n1" "$d1" "$min_net" "$f0"
      continue
    fi
    shape_graded=$((shape_graded + 1)); graded=$((graded + 1))
    r1="$(awk -v a="$d1" -v b="$d2" 'BEGIN{printf "%.3f", b/a}')"
    r2="$(awk -v a="$d2" -v b="$d3" 'BEGIN{printf "%.3f", b/a}')"
    over="$(awk -v x="$r1" -v y="$r2" -v t="$THRESH" 'BEGIN{print (x>t && y>t) ? "yes" : "no"}')"
    printf '  %-7s net %s -> %s -> %s\n' "$st" "$d1" "$d2" "$d3"
    if is_known "${shape}:${st}"; then
      lk="$(printf '%s_%s' "$shape" "$st" | tr -c 'a-zA-Z0-9_' '_')"
      eval "ceil=\${KNOWN_CEIL_$lk}"
      eval "fixed=\${KNOWN_FIXED_$lk}"
      worse="$(awk -v r="$r2" -v c="$ceil" 'BEGIN{print (r > c) ? 1 : 0}')"
      better="$(awk -v r="$r2" -v f="$fixed" 'BEGIN{print (r < f) ? 1 : 0}')"
      if [ "$worse" = "1" ]; then
        printf '  %-7s ** KNOWN-SLOW, AND GOT WORSE ** r1=%s r2=%s (ceiling %s)\n' "$st" "$r1" "$r2" "$ceil"
        fail=$((fail + 1))
      elif [ "$better" = "1" ]; then
        printf '  %-7s ** PROMOTE: now scales LINEARLY ** r2=%s (< %s)\n' "$st" "$r2" "$fixed"
        printf '          Remove "%s:%s" from KNOWN_SLOW — the quadratic is FIXED.\n' "$shape" "$st"
        fail=$((fail + 1))
      else
        printf '  %-7s known-slow r1=%s r2=%s (ceiling %s) — ledgered, see the header\n' "$st" "$r1" "$r2" "$ceil"
        known=$((known + 1))
      fi
    elif [ "$over" = "yes" ]; then
      printf '  %-7s ** SUPERLINEAR (stage Ir) ** r1=%s r2=%s (threshold %s, both doublings)\n' \
        "$st" "$r1" "$r2" "$THRESH"
      fail=$((fail + 1))
    else
      printf '  %-7s ok   r1=%s r2=%s (threshold %s)\n' "$st" "$r1" "$r2" "$THRESH"
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

echo "── per-stage Ir scaling (Callgrind, inclusive, net of a per-shape floor) ──"
echo "profiler: $PROFILE"
valgrind --version
echo

grade_shape match "$MATCH_N"
grade_shape xref "$XREF_N"

if [ "$graded" -eq 0 ]; then
  echo "FAIL: no stage was graded — this gate proved nothing."
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "FAIL: $graded stage-ratio(s) graded, $fail over the line."
  exit 1
fi

echo "PASS: $graded stage-ratio(s) graded ($known ledgered), all sub-quadratic in stage Ir (threshold $THRESH)."
exit 0
