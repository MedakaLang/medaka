# test/perf_shapes.sh — SHAPE GENERATORS SHARED BY THE SCALING GATES (#2066)
#
# NOT A GATE. This file is `.`-sourced; it runs nothing and exits nothing. It is listed
# in test/CI-COVERAGE-EXCEPTIONS.txt for exactly that reason (every `.sh` in the tree is
# enumerated by test/diff_compiler_ci_shard_coverage.sh, which cannot tell a library from
# a gate by looking at it).
#
# ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────────
#
# `gen_xref` and `gen_manyifaces` were TRANSCRIBED, not shared, into
# test/diff_compiler_ir_scaling.sh when that gate was written (#2045, PR #2051) — two
# byte-different copies of the same two programs, one graded on allocation and op counts
# (test/diff_compiler_perf_scaling.sh), the other on Cachegrind `Ir`. Nothing compared
# them. That is a silent-drift hazard of a specific and nasty kind: the two gates would
# still both be green while measuring DIFFERENT PROGRAMS, and their numbers would be
# quoted side by side as if they described one shape. Ratios are only comparable across
# arms if the input is identical, which is the whole reason both gates use these shapes.
#
# ── THE RULE FOR ANYTHING THAT LANDS HERE ────────────────────────────────────
#
# A generator in this file is a PUBLIC CONTRACT between at least two gates. Changing the
# emitted program changes every band, every ledger ceiling and every recorded ratio that
# was calibrated against it, in BOTH gates at once. So: re-derive the affected bands and
# re-read the ledger rows in every consumer before changing a generator here, and never
# "simplify" one on the strength of one gate staying green.
#
# Derive the consumer set — do not trust a list in a comment:
#   grep -rln 'perf_shapes.sh' test/
#
# ── CALLING CONVENTION ───────────────────────────────────────────────────────
#
#   gen_<shape> <N> <output-file>
#
# Every internal variable is `gn`/`gf`/`gi`/... — the ir_scaling naming, not
# perf_scaling's `n`/`f`/`i` — because a sourced generator shares the caller's variable
# namespace and this file must never clobber a loop variable in a gate it knows nothing
# about. Keep that prefix for anything added here.

# gen_xref — THE CROSS-REFERENCE CHAIN (issue #78).
#
# N top-level functions, each REFERENCING the previous one (f0 is the base case). This is
# the shape #78's resolve quadratic actually needed: every `fN x = f(N-1) x + N` forces
# `lookupValue` to fall through the local-scope check and walk the top-level env for
# `f(N-1)` — a shape whose bodies do not reference each other never triggers that scan.
#
# ⚠️ `main` CALLS THE HEAD OF THE CHAIN, and that is load-bearing — do not "simplify" it
# to `println 1`. An emit-able program needs a `main` at all (emitProgram panics without
# one), but a `main` that reaches NOTHING is worse than useless: both consumers run
# `dceFilter` exactly as the real build driver does, rooted at `main` plus impl/interface
# bodies. With `main = println 1` every f0..fN is DEAD, is pruned before lowering, and the
# backend stages time THE PRELUDE AND NOTHING ELSE — a ratio describing a scenario no real
# build performs. `f%s` calls `f%s-1`, so calling the LAST one transitively retains the
# whole chain through DCE, which is what makes `xref:emit` a claim about `medaka build`
# rather than about the harness.
# NB: `$((gn - 1))`, not the loop's last `gi - 1` — that leaves the loop at n-2 and would
# strand the last function as the one dead decl.
gen_xref() {
  gn=$1; gf=$2; : > "$gf"
  printf 'f0 : Int -> Int\nf0 x = x + 1\n' >> "$gf"
  gi=1
  while [ "$gi" -lt "$gn" ]; do
    printf 'f%s : Int -> Int\nf%s x = f%s x + %s\n' "$gi" "$gi" "$((gi - 1))" "$gi"
    gi=$((gi + 1))
  done >> "$gf"
  printf 'main = println (f%s 0)\n' "$((gn - 1))" >> "$gf"
}

# gen_manyifaces — THE CO-SCALED MARK QUADRATIC (issue #883 §5 hole 8).
#
# N interfaces AND N reference sites scaled together: the only shape that co-scales the
# interface-method table with the number of sites consulting it, which is what
# `manyifaces:mark` (#953, `contains x methods` as a List-as-set) and the independent
# `manyifaces:resolve` (#954) both need. `gr=8` `+ base` terms per h-decl give the `+`
# operator nodes enough reference sites to matter without inflating typecheck.
#
# mark/resolve/typecheck all run BEFORE DCE and see every decl; `main` reaches only h0
# (the rest are pruned before the backend, which this front-end shape does not grade —
# `xref` above carries the backend).
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
