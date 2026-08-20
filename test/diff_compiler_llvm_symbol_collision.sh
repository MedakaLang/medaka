#!/bin/sh
# diff_compiler_llvm_symbol_collision.sh — the emitted-symbol INJECTIVITY gate
# (X-L.H / #348 / #748; the regression home of the drained #1677 pin).
#
# WHAT IT ASSERTS. `compiler/backend/private_mangle.mangledName` is
# `"<sanitizeId mid>__<name>"`, and `sanitizeId` maps `.`, `/` and `-` all to `_`.
# That encoding is MANY-TO-ONE: a flat module `lib_plain.mdk` (id `lib_plain`) and
# a nested `lib/plain.mdk` (dotted id `lib.plain`) both sanitize to `lib_plain`, so
# an exported `g` in either mangles to the identical symbol `mdk_lib_plain__g`.
#
# Before `mangleUnits`' injectivity guard, that was SILENT: `core_ir_lower.lgGroup`'s
# bare-name merge folded the two definitions into ONE `define` with an unreachable
# second clause, the binary linked, ran the wrong one, and exited 0 with no
# diagnostic anywhere. `check` was clean and `run` (the tree-walker, which has no
# mangling pass) was CORRECT — the built binary alone was wrong. That is the S0
# shape this gate exists to keep dead: `run != build`, at exit 0.
#
# This corpus WAS test/must_fail_fixtures/1677-mangle-scheme-non-injective/, pinning
# the broken behaviour (`build-run main.mdk` -> exit 0, stdout `101`/`101`). The
# guard drained that pin, and per G-PIN-DRAIN the coverage is RE-POINTED here rather
# than deleted — same fixture bytes, inverted polarity: it now asserts the FIXED
# behaviour.
#
# ── WHY THE ASSERTION IS SHAPED THIS WAY ─────────────────────────────────────
# The drained behaviour is a REFUSAL, not a computed answer, so there is no value to
# golden (the disanalogy with the #1216 pin repoint, which had one). A refusal is
# only meaningfully pinned by all three of:
#   1. NON-ZERO EXIT.
#   2. THE DIAGNOSTIC NAMES BOTH SOURCES. `mangleUnits` refuses with both colliding
#      `(module, name)` pre-images AND the symbol they collapse onto. Asserting only
#      "it failed" would let ANY unrelated emitter crash pass this gate — the #463
#      BUILD_CRASH bug class, which launders a regression as evidence of a fix. So
#      the message text is asserted, not just the exit code.
#   3. NO BINARY IS PRODUCED. The property is "refuses BEFORE any binary is
#      produced". A refusal that still leaves an output file on disk is a weaker
#      property, and a harness doing `medaka build x -o b && ./b` would happily run
#      a stale `b`.
#
# ── AND THE CONTROL, WHICH MUST STAY GREEN ───────────────────────────────────
# control.mdk is main.mdk with exactly ONE spelling changed: the flat module is
# `libplain.mdk` (id `libplain`, no underscore) instead of `lib_plain.mdk`, so it
# does NOT collide with `lib.plain`'s sanitized id. Everything else is identical —
# same nested `lib/plain.mdk`, same two aliased imports, same bodies. It must build
# AND run, printing the hand-derived `101` then `1000`.
#
# Without it, a guard that refused EVERY multi-module program would pass the
# negative case and this gate would be the "green that proves nothing" it exists to
# prevent. With it, "you broke ordinary cross-module codegen" can never be read as
# "the collision guard works".
#
# SCOPE, so this gate is never cited as more than it is: it grades the
# MODULE-MANGLED symbol domain (`mangleUnits`' own domain — top-level functions and
# local constructors). It says nothing about emitter-MINTED symbols (gensym'd
# lambdas/etas/impls, `llvm_emit.ensureDefaultEmitted`'s dedup-on-mint), which
# `mangleUnits` never sees. Within the module-mangled domain, the guard makes the
# `(module, name) -> symbol` map injective for DISTINCT MODULE IDS ONLY — two
# distinct source units sharing ONE module id collapse invisibly (the
# `prev == pre` skip in `checkSymbolsInjective`). Uncovered, tracked: #1792.
#
# ⚠️ `medaka build`'s exit code does NOT survive a pipe (AGENTS.md [D-BUILD-PIPE]).
# Every invocation below redirects to a file and reads `$?` from the redirect.
#
# Usage:  sh test/diff_compiler_llvm_symbol_collision.sh
# Exit:   0 all assertions hold and the control is green;
#         1 any assertion fails;
#         2 ./medaka or the native emitter is missing (opt-in skip, same discipline
#           as the other llvm gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIX="$ROOT/test/symbol_collision_fixtures"

[ -x "$MEDAKA" ] || { printf 'no ./medaka at %s — build it first: make medaka\n' "$MEDAKA"; exit 2; }
[ -x "$EMITTER" ] || { printf 'no native emitter at %s — build it first: make medaka\n' "$EMITTER"; exit 2; }
[ -d "$FIX" ] || { printf 'FAIL: fixture corpus missing: %s\n' "$FIX"; exit 1; }

MEDAKA_EMITTER="$EMITTER"
export MEDAKA_EMITTER

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
checked=0

fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
ok() { printf 'ok    %s\n' "$1"; }

# ── 1. the colliding program must REFUSE ──────────────────────────────────────
checked=$((checked + 1))
BIN="$WORK/collide.bin"
LOG="$WORK/collide.log"
"$MEDAKA" build "$FIX/main.mdk" -o "$BIN" > "$LOG" 2>&1
st=$?

if [ "$st" -eq 0 ]; then
  fail "colliding program built at exit 0 — the injectivity guard did NOT fire"
  printf '      this is the #1677 S0 back: two distinct (module, name) pairs sharing\n'
  printf '      one emitted symbol, silently folded. Build output:\n'
  sed 's/^/        /' "$LOG"
else
  ok "colliding program refused (exit $st)"
fi

# The message must name BOTH pre-images and the symbol — not merely "it failed".
checked=$((checked + 1))
missing=""
for want in 'emitted-symbol collision' 'lib_plain.g' 'lib.plain.g' 'lib_plain__g'; do
  grep -q -- "$want" "$LOG" || missing="$missing '$want'"
done
if [ -n "$missing" ]; then
  fail "refusal diagnostic does not name both colliding sources; missing:$missing"
  printf '      a refusal that does not name BOTH (module, name) pre-images is not\n'
  printf '      distinguishable from an unrelated emitter failure (cf. #463). Got:\n'
  sed 's/^/        /' "$LOG"
else
  ok "refusal names both sources and the collided symbol"
fi

# It must refuse BEFORE producing anything.
checked=$((checked + 1))
if [ -e "$BIN" ]; then
  fail "a binary was produced at $BIN despite the refusal"
  printf '      the property is "refuses before any binary is produced".\n'
else
  ok "no binary produced"
fi

# ── 2. the CONTROL must stay green, build AND run ─────────────────────────────
checked=$((checked + 1))
CBIN="$WORK/control.bin"
CLOG="$WORK/control.log"
"$MEDAKA" build "$FIX/control.mdk" -o "$CBIN" > "$CLOG" 2>&1
cst=$?

if [ "$cst" -ne 0 ]; then
  fail "CONTROL FAILED TO BUILD (exit $cst) — this is NOT a guard success"
  printf '      control.mdk has NO colliding module ids. If it refuses, the guard is\n'
  printf '      too broad (or ordinary cross-module codegen broke) — either way the\n'
  printf '      negative case above proves nothing. Build output:\n'
  sed 's/^/        /' "$CLOG"
else
  ok "control builds (exit 0)"
  checked=$((checked + 1))
  COUT="$WORK/control.out"
  "$CBIN" > "$COUT" 2>&1
  rst=$?
  # Hand-derived: gFlat 1 = 1 + 100 = 101; gNested 1 = 1 + 999 = 1000. Two
  # independent modules; nothing in the language ties their results together.
  printf '101\n1000\n' > "$WORK/control.expected"
  if [ "$rst" -ne 0 ]; then
    fail "control binary exited $rst"
    sed 's/^/        /' "$COUT"
  elif ! diff -u "$WORK/control.expected" "$COUT" > "$WORK/control.diff" 2>&1; then
    fail "control binary stdout differs from the hand-derived 101/1000"
    sed 's/^/        /' "$WORK/control.diff"
  else
    ok "control runs, prints 101 then 1000"
  fi
fi

# ── 3. the CONSTRUCTOR domain — a SEPARATE pass, separate emitted namespace ──
# `symbolInjectivityGuard` checks functions and constructors as two independent
# passes (private_mangle.mdk `symbolInjectivityGuard`) because they emit into
# separate symbol namespaces (a ctor becomes `@mdk_ctorpap_<sym>_<n>`). Sections 1
# and 2 above exercise the FUNCTION pass only — `main.mdk`/`control.mdk` collide
# (or don't) on an exported top-level FUNCTION `g`. This section is the ctor-pass
# equivalent, so a future edit that disables or weakens the ctor arm of the guard
# cannot stay green here the way it could before this section existed.
#
# `ctor/main.mdk` collides on a PRIVATE constructor `Kk`, declared in both
# `ctor/lib_plain.mdk` (id `lib_plain`) and `ctor/lib/plain.mdk` (id `lib.plain`)
# — same `sanitizeId` collapse as section 1, on the ctor pre-image instead of the
# function one. Private, deliberately: the guard reads `unitLocalCtorNames`, which
# is NOT `VisPublic`-gated, so a private-only collision must still refuse.
# `ctor/control.mdk` swaps the flat module for `ctor/libplain.mdk` (id `libplain`,
# no underscore) so the two module ids no longer collide — same shape as
# section 2's control.

checked=$((checked + 1))
CTBIN="$WORK/ctor_collide.bin"
CTLOG="$WORK/ctor_collide.log"
"$MEDAKA" build "$FIX/ctor/main.mdk" -o "$CTBIN" > "$CTLOG" 2>&1
ctst=$?

if [ "$ctst" -eq 0 ]; then
  fail "colliding ctor program built at exit 0 — the ctor-domain guard did NOT fire"
  printf '      two distinct (module, name) pairs sharing one emitted constructor\n'
  printf '      symbol, silently folded. Build output:\n'
  sed 's/^/        /' "$CTLOG"
else
  ok "colliding ctor program refused (exit $ctst)"
fi

# The message must name BOTH pre-images and the symbol, and say "constructors" —
# not merely "it failed", and not the function-pass diagnostic by accident.
checked=$((checked + 1))
ctmissing=""
for want in 'emitted-symbol collision' 'constructors' 'lib_plain.Kk' 'lib.plain.Kk' 'lib_plain__Kk'; do
  grep -q -- "$want" "$CTLOG" || ctmissing="$ctmissing '$want'"
done
if [ -n "$ctmissing" ]; then
  fail "ctor refusal diagnostic does not name both colliding sources; missing:$ctmissing"
  printf '      Got:\n'
  sed 's/^/        /' "$CTLOG"
else
  ok "ctor refusal names both sources, the collided symbol, and the ctor domain"
fi

# It must refuse BEFORE producing anything.
checked=$((checked + 1))
if [ -e "$CTBIN" ]; then
  fail "a binary was produced at $CTBIN despite the ctor refusal"
  printf '      the property is "refuses before any binary is produced".\n'
else
  ok "no binary produced (ctor domain)"
fi

# ── the ctor CONTROL must stay green, build AND run ───────────────────────────
checked=$((checked + 1))
CTCBIN="$WORK/ctor_control.bin"
CTCLOG="$WORK/ctor_control.log"
"$MEDAKA" build "$FIX/ctor/control.mdk" -o "$CTCBIN" > "$CTCLOG" 2>&1
ctcst=$?

if [ "$ctcst" -ne 0 ]; then
  fail "CTOR CONTROL FAILED TO BUILD (exit $ctcst) — this is NOT a guard success"
  printf '      ctor/control.mdk has NO colliding module ids. If it refuses, the ctor\n'
  printf '      arm of the guard is too broad. Build output:\n'
  sed 's/^/        /' "$CTCLOG"
else
  ok "ctor control builds (exit 0)"
  checked=$((checked + 1))
  CTCOUT="$WORK/ctor_control.out"
  "$CTCBIN" > "$CTCOUT" 2>&1
  ctrst=$?
  # Hand-derived: runA 1 = 1 + 100 = 101; runB 1 = 1 + 999 = 1000.
  printf '101\n1000\n' > "$WORK/ctor_control.expected"
  if [ "$ctrst" -ne 0 ]; then
    fail "ctor control binary exited $ctrst"
    sed 's/^/        /' "$CTCOUT"
  elif ! diff -u "$WORK/ctor_control.expected" "$CTCOUT" > "$WORK/ctor_control.diff" 2>&1; then
    fail "ctor control binary stdout differs from the hand-derived 101/1000"
    sed 's/^/        /' "$WORK/ctor_control.diff"
  else
    ok "ctor control runs, prints 101 then 1000"
  fi
fi

printf '\nchecked %d assertions: %d failed\n' "$checked" "$fails"

# "checked nothing" must never look like "passed" — every silent-green bug in this
# repo is that sentence.
if [ "$checked" -eq 0 ]; then
  printf 'FAIL: graded zero assertions\n'
  exit 1
fi

[ "$fails" -eq 0 ]
