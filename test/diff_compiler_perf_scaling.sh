#!/bin/sh
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
# So TIME is now ALSO graded — as a self-normalizing RATIO, never an absolute
# wall-clock ceiling (a hosted runner is too noisy for that). Two things make a
# ratio-based time gate non-flaky:
#
#   * MIN-OF-K (K>=5) per measurement. Runner noise is ONE-SIDED — a scheduling
#     stall can only make a run SLOWER, never spuriously faster — so the minimum
#     over K samples converges on the true cost FROM ABOVE (same principle as
#     PERF-RESULTS.md's "min-of-10, quiet machine").
#   * A floor: at N too small, absolute time is noise, and a ratio computed on
#     noise is meaningless. Below the floor the timing verdict SKIPS (loudly —
#     it is printed, and a skip can never be read as a pass); it does not affect
#     pass/fail.
#
# The timing verdict can ONLY make a shape FAIL that allocation called "ok" — it
# is an added detector, not a replacement, and it never overrides an allocation
# failure or downgrades one.
#
# ⚠️ TIME-GATING IS SCOPED TO `xref` ONLY (TIME_GATED below), not all five
# shapes. Measured trying it on `match` at N=250: the SUM-of-stages metric came
# in at r1≈2.9/r2≈3.1-3.2 across repeated min-of-5 samples — dangerously close
# to the 3.0 threshold, on a shape whose allocation ratio is a clean 2.02/2.03
# (genuinely linear). That is not runner noise (min-of-K already suppresses
# that) — it is CONSTANT-FACTOR DILUTION at small N in `parse`/`typecheck`
# (the same trap the allocation baseline-subtraction above exists to avoid),
# and unlike `xref` nobody has done the work to isolate a clean per-shape focus
# stage set and larger N for it. Gating on an under-conditioned metric is worse
# than not gating — it is exactly the flakiness this whole redesign exists to
# avoid. `xref`'s focus set + N=2000 base WAS validated this way (fixed-resolve
# max observed r2 ≈2.78; broken-resolve min observed r1 ≈3.13 — a real margin
# on both sides); the other four shapes are not, so their TIME line stays
# informational-only (min-of-K computed and printed, but never fails).
#
# Usage:  sh test/diff_compiler_perf_scaling.sh
#         PERF_N=250 sh test/diff_compiler_perf_scaling.sh   # base size
# Exit:   0 all shapes scale sub-quadratically; 1 a shape regressed; 2 opt-in skip.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$ROOT/test/bin/profile_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$PROFILE" ] || {
  echo "build oracles first: sh test/build_oracles.sh --build-one profile_main (missing $PROFILE)"
  exit 2
}

# FAIL threshold, per doubling.
#   linear 2.0 | n log n ~2.1 | n^1.5 = 2.83 | QUADRATIC 4.0
# 3.0 comfortably admits n log n (plus slack) and comfortably catches n^2. It also
# catches n^1.58 and worse. Deliberately NOT tighter: a gate that fires on noise is
# a gate that gets disabled.
THRESH="${PERF_THRESH:-3.0}"
N="${PERF_N:-250}"

# `xref` needs a bigger base N than the other four shapes to clear the timing
# floor (see TIME_FLOOR below) — it is timed on a narrow per-stage sum, not the
# padded `total`, and that sum is genuinely small at N=250. Kept as its own knob
# so the other shapes' (cheap, N=250) fixtures are untouched.
XREF_N="${PERF_XREF_N:-2000}"

# min-of-K sample count for the TIME signal. K>=5 required (see file header);
# allocation needs no such thing — it is deterministic, one run suffices.
PERF_K="${PERF_K:-5}"

# Below this absolute time (seconds) at the largest N, a time ratio is noise,
# not signal — SKIP rather than gate on it. ~200ms per the task brief.
TIME_FLOOR="${PERF_TIME_FLOOR:-0.2}"

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
# (Currently EMPTY — every shape scales sub-quadratically. Long may it last.)
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
KNOWN_SUPERLINEAR=""

is_known() {
  for k in $KNOWN_SUPERLINEAR; do [ "$k" = "$1" ] && return 0; done
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
gen_bindings() {
  n=$1; f=$2; : > "$f"
  i=0; while [ "$i" -lt "$n" ]; do
    printf 'f%s : Int -> Int\nf%s x = x + %s\n' "$i" "$i" "$i"
    i=$((i+1))
  done >> "$f"
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
}

gen_nesting() {
  n=$1; f=$2; : > "$f"
  # N-deep let nesting: stresses recursion depth in every tree-walking pass
  printf 'deep : Int\ndeep =\n' >> "$f"
  i=0; while [ "$i" -lt "$n" ]; do printf '  let v%s = %s\n' "$i" "$i" >> "$f"; i=$((i+1)); done
  printf '  v0\n' >> "$f"
}

gen_xref() {
  n=$1; f=$2; : > "$f"
  # N top-level functions, each REFERENCING the previous one (f0 is the base
  # case). This is the shape #78's resolve quadratic actually needed: every
  # `fN x = f(N-1) x + N` forces `lookupValue` to fall through the local-scope
  # check and walk the top-level env for `f(N-1)` — the scan `bindings` above
  # never triggers.
  printf 'f0 : Int -> Int\nf0 x = x + 1\n' >> "$f"
  i=1; while [ "$i" -lt "$n" ]; do
    prev=$((i - 1))
    printf 'f%s : Int -> Int\nf%s x = f%s x + %s\n' "$i" "$i" "$prev" "$i"
    i=$((i+1))
  done >> "$f"
}

# ── Measure ──────────────────────────────────────────────────────────────────
# Returns TOTAL allocated MB for one fixture. Allocation is deterministic, so ONE
# run suffices — no min-of-K needed, and no noise to average away.
alloc_of() {
  MEDAKA_PERF=1 "$PROFILE" "$RUNTIME" "$CORE" "$1" 2>&1 \
    | awk '/^\[perf\] total/ { gsub(/MB/,"",$4); print $4; exit }'
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
time_of() {
  MEDAKA_PERF=1 "$PROFILE" "$RUNTIME" "$CORE" "$1" 2>&1 \
    | awk '/^\[perf\] total/ { gsub(/s$/,"",$3); print $3; exit }'
}

# ── TIME grading (issue #110) ────────────────────────────────────────────────
#
# `total` (used above by time_of, informationally) is the WRONG metric to gate
# on: it is dominated by `parse` and `typecheck`, which scale roughly linearly
# and DILUTE a quadratic living in a smaller stage. Measured on #78's resolve
# bug, `total`'s ratio at N=2000/4000/8000 (xref shape) was only 2.34x/2.48x —
# UNDER threshold, i.e. STILL BLIND — while the `resolve` stage alone (or the
# name-binding stages summed below) was unmistakably quadratic, 3.13x/3.48x.
#
# So the TIME signal sums a per-shape FOCUS set of profile_main's per-stage
# lines, not `total`. Default focus is every N-scaling stage (i.e. total minus
# the fixed one-time `parse-prelude` cost) — a reasonable default for a shape
# with no narrower hypothesis. `xref` overrides it to the four name-binding
# stages (exhaust-guards, desugar, resolve, mark) — deliberately EXCLUDING
# `parse` and `typecheck`, the two stages large enough to swamp the signal.
time_stages_for() {
  case "$1" in
    xref) printf 'exhaust-guards desugar resolve mark' ;;
    *)    printf 'parse exhaust-guards desugar resolve mark typecheck' ;;
  esac
}

# Shapes whose TIME ratio can actually FAIL the gate. See the file-header
# warning above for why this is not all five shapes yet.
TIME_GATED="xref"
is_time_gated() {
  for s in $TIME_GATED; do [ "$s" = "$1" ] && return 0; done
  return 1
}

# Sum the wall-clock time (seconds) of the given PERF stage names, for ONE
# profile_main run. $2 is a space-separated stage-name list (matched literally
# against profile_main's `[perf] <stage> ...` lines).
stagesum_of() {
  fixture="$1"; stages="$2"
  MEDAKA_PERF=1 "$PROFILE" "$RUNTIME" "$CORE" "$fixture" 2>&1 \
    | awk -v want="$stages" '
        BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) keep[w[i]] = 1; sum = 0 }
        /^\[perf\] / { if ($2 in keep) { t = $3; gsub(/s$/, "", t); sum += t } }
        END { printf "%.6f", sum }
      '
}

# min-of-K stagesum (K = PERF_K, >=5). Runner noise is ONE-SIDED — see the file
# header — so the minimum over K runs converges on the true cost from above.
min_stagesum_of() {
  fixture="$1"; stages="$2"; k="$3"
  best=""
  i=0
  while [ "$i" -lt "$k" ]; do
    v="$(stagesum_of "$fixture" "$stages")"
    if [ -z "$best" ]; then
      best="$v"
    else
      best="$(awk -v a="$best" -v b="$v" 'BEGIN { print (b + 0 < a + 0) ? b : a }')"
    fi
    i=$((i+1))
  done
  printf '%s' "$best"
}

fail=0
known=0
pass=0

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
for shape in bindings match listlit nesting xref; do
  case "$shape" in
    xref) base_n="$XREF_N" ;;
    *)    base_n="$N" ;;
  esac
  n1="$base_n"; n2=$((base_n * 2)); n3=$((base_n * 4))
  f1="$WORK/${shape}_$n1.mdk"; f2="$WORK/${shape}_$n2.mdk"; f3="$WORK/${shape}_$n3.mdk"
  "gen_$shape" "$n1" "$f1"
  "gen_$shape" "$n2" "$f2"
  "gen_$shape" "$n3" "$f3"

  a1="$(alloc_of "$f1")"; a2="$(alloc_of "$f2")"; a3="$(alloc_of "$f3")"
  t1="$(time_of  "$f1")"; t2="$(time_of  "$f3")"

  # A shape that produces no measurement is a HARNESS failure, not a pass. Never
  # let "I could not measure it" read as "it is fine" — that is the silent-green
  # bug class this whole suite was hardened against.
  case "$a1$a2$a3" in
    *[!0-9.]*|"") echo "FAIL $shape: profiler produced no allocation figure (harness bug)"; fail=$((fail+1)); continue ;;
  esac

  # ── TIME verdict (min-of-K, see helpers above) ──────────────────────────────
  # Computed unconditionally BEFORE the allocation branch below — so it can
  # promote an allocation "ok" to a failure, but never the reverse (an
  # allocation failure/TOOSMALL/known-superlinear verdict is untouched) — but
  # ONLY for a TIME_GATED shape. For everything else, min-of-K x 3 sizes is a
  # real cost (15 extra profiler invocations) for a number that — see the
  # header warning — is not well-conditioned enough to act on, so skip the
  # work entirely rather than spend time computing a figure nobody should
  # trust and this gate does not need.
  time_bad=0
  if is_time_gated "$shape"; then
    focus="$(time_stages_for "$shape")"
    mt1="$(min_stagesum_of "$f1" "$focus" "$PERF_K")"
    mt2="$(min_stagesum_of "$f2" "$focus" "$PERF_K")"
    mt3="$(min_stagesum_of "$f3" "$focus" "$PERF_K")"
    tverdict="$(awk -v t1="$mt1" -v t2="$mt2" -v t3="$mt3" -v floor="$TIME_FLOOR" -v th="$THRESH" 'BEGIN {
      if (t3 + 0 < floor + 0) { printf "SKIP 0 0"; exit }
      r1 = t2 / t1; r2 = t3 / t2
      # Fail only on a SUSTAINED signal — both doublings over threshold — never
      # one bad sample. No "climbing" heuristic here (unlike allocation): the
      # min-of-K already suppresses one-sided noise, so a plain double-threshold
      # is enough and keeps the rule easy to reason about.
      bad = (r1 > th && r2 > th) ? 1 : 0
      printf "%s %.2f %.2f", (bad ? "QUADRATIC" : "ok"), r1, r2
    }')"
    tword="$(echo "$tverdict" | cut -d' ' -f1)"
    trr1="$(echo "$tverdict" | cut -d' ' -f2)"
    trr2="$(echo "$tverdict" | cut -d' ' -f3)"
    [ "$tword" = "QUADRATIC" ] && time_bad=1
  else
    tword="NOTGATED"
  fi

  # Subtract the fixed prelude cost — see the BASELINE note above. Without this the
  # gate is blind.
  verdict="$(awk -v a1="$a1" -v a2="$a2" -v a3="$a3" -v b="$BASE_ALLOC" -v th="$THRESH" 'BEGIN {
    d1 = a1 - b; d2 = a2 - b; d3 = a3 - b
    # If the input costs less than the noise floor, N is too small to say anything.
    # Report that honestly instead of certifying it as "ok".
    if (d1 < 1.0) { printf "0 0 TOOSMALL"; exit }
    r1 = d2 / d1
    r2 = d3 / d2
    # Gate on r2 (least constant-factor contamination). Also catch a CLIMBING ratio
    # even below the ceiling — that is a quadratic showing itself early.
    climbing = (r2 > r1 * 1.15 && r2 > 2.45)
    printf "%.2f %.2f %s", r1, r2, ((r2 > th || climbing) ? "QUADRATIC" : "ok")
  }')"
  r1="$(echo "$verdict" | cut -d' ' -f1)"
  ratio="$(echo "$verdict" | cut -d' ' -f2)"
  word="$(echo "$verdict" | cut -d' ' -f3)"

  d1="$(awk -v a="$a1" -v b="$BASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
  d2="$(awk -v a="$a2" -v b="$BASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"
  d3="$(awk -v a="$a3" -v b="$BASE_ALLOC" 'BEGIN{printf "%.1f", a-b}')"

  if [ "$word" = "TOOSMALL" ]; then
    # NOT a pass. An unmeasurable shape is a harness problem, and silently counting
    # it as fine is exactly how a suite starts lying about what it covers.
    fail=$((fail+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** N TOO SMALL — raise PERF_N **\n' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "-" "-"

  elif is_known "$shape"; then
    # A KNOWN-superlinear shape. Two ways this must still fail:
    eval "ceil=\${KNOWN_CEIL_$shape}"
    eval "fixed=\${KNOWN_FIXED_$shape}"
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
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** SUPERLINEAR (ALLOC) **
' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "$r1" "$ratio"
    printf '           time: %ss -> %ss\n' "$t1" "$t2"
    if [ "$tword" = "QUADRATIC" ]; then
      printf '           TIME is ALSO quadratic: stages [%s] min-of-%s r1=%s r2=%s (> %sx)\n' \
        "$focus" "$PERF_K" "$trr1" "$trr2" "$THRESH"
    fi

  elif [ "$time_bad" = "1" ]; then
    # Allocation alone said "ok" — this is the blind spot #110 exists to close.
    # A pure O(n^2) scan (the resolve bug in #78) allocates almost nothing extra
    # per element, so allocation cannot see it; TIME can, and just did.
    fail=$((fail+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ** SUPERLINEAR (TIME) **
' \
      "$shape" "$n1" "$d1" "$d2" "$d3" "$r1" "$ratio"
    printf '           alloc looked fine (r1=%s r2=%s) but min-of-%s TIME on stages [%s]\n' \
      "$r1" "$ratio" "$PERF_K" "$focus"
    printf '           is quadratic: N=%s %ss -> N=%s %ss -> N=%s %ss  (r1=%s r2=%s, > %sx)\n' \
      "$n1" "$mt1" "$n2" "$mt2" "$n3" "$mt3" "$trr1" "$trr2" "$THRESH"

  else
    pass=$((pass+1))
    printf '%-10s %8s %7s MB %7s MB %7s MB  %6s %6s  ok
' "$shape" "$n1" "$d1" "$d2" "$d3" "$r1" "$ratio"
    if [ "$tword" = "SKIP" ]; then
      printf '           time: skip (largest-N %ss < %ss floor, no signal)\n' "$mt3" "$TIME_FLOOR"
    elif [ "$tword" != "NOTGATED" ]; then
      printf '           time: min-of-%s r1=%s r2=%s ok (stages: %s)\n' "$PERF_K" "$trr1" "$trr2" "$focus"
    fi
  fi
done

printf -- '---------------------------------------------------------------------\n'
printf '%d ok, %d known-superlinear, %d regressed (threshold %sx per doubling)\n' "$pass" "$known" "$fail" "$THRESH"

# Never exit 0 having measured nothing.
[ $((pass + known + fail)) -gt 0 ] || { echo "FAIL: the gate measured no shapes at all"; exit 1; }

if [ "$fail" -gt 0 ]; then
  cat <<EOF

A shape grew faster than ${THRESH}x per doubling of input size. That is the
signature of a SUPERLINEAR (probably QUADRATIC) algorithm.

  linear      ~2.0x      n log n  ~2.1x      QUADRATIC  ~4.0x

The pattern found every time so far: a List being scanned / elem-checked /
lookup-ed / rebuilt ONCE PER ELEMENT. Note that \`xs ++ [x]\` inside a fold is
O(n^2) all by itself (list append is O(n)).

To localize it:
  MEDAKA_PERF=1 test/bin/profile_main stdlib/runtime.mdk stdlib/core.mdk <fixture>
gives per-STAGE time and allocation. Then \`perf\` (apt-get install linux-perf) to
name the hot symbol -- but note call graphs are unusable in these binaries (tail
calls, no frame pointers); use FLAT symbol counts only.

WARNING: \`whenL False (expensiveCall ...)\` is NOT a stub -- Medaka is strict, so
the argument still evaluates. To stub something out, actually remove the call.
EOF
  exit 1
fi
exit 0
