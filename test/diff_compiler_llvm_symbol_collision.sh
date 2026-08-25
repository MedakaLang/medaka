#!/bin/sh
# diff_compiler_llvm_symbol_collision.sh — the emitted-symbol INJECTIVITY gate
# (X-L.H / #348 / #748; the regression home of the drained #1677 and #1950 pins).
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
# SCOPE, so this gate is never cited as more than it is. Sections 1–3 grade the
# MODULE-MANGLED symbol domain (`mangleUnits`' own domain — top-level functions and
# local constructors). Within it, the guard makes the `(module, name) -> symbol`
# map injective for DISTINCT MODULE IDS ONLY — two distinct source units sharing
# ONE module id collapse invisibly (the `prev == pre` skip in
# `checkSymbolsInjective`). Uncovered, tracked: #1792.
#
# Section 4 grades part — not all — of the emitter-MINTED domain `mangleUnits`
# never sees: the C7 impl symbols `mdk_impl_<symTag>_<method>` and the per-instance
# `$memo_<selector>_<method>` CAFs, both spelled through
# `private_mangle.injectiveIdent` (#1950). It is silent about the REST of that
# domain — gensym'd lambdas/etas, `llvm_emit.ensureDefaultEmitted`'s dedup-on-mint,
# and `mdk_default_*` — and about the WasmGC peers of the two families it does
# cover (this is an LLVM gate; `test/wasm/` owns that backend).
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

# ── 4. the emitter-MINTED impl-symbol domain (#1950), POSITIVE polarity ──────
# Sections 1–3 grade the MODULE-MANGLED domain, which the header's SCOPE note says
# is all `mangleUnits` ever sees. This section grades the OTHER half of the
# emitted-symbol space: the symbols the backends MINT — `mdk_impl_<symTag>_<method>`
# (TYPECHECK-AUDIT C7) and the per-instance `$memo_<selector>_<method>` CAFs.
#
# It is test/must_fail_fixtures/1950-impl-key-sanitize-collision/, DRAINED and
# repointed here per [G-PIN-DRAIN] — the same move #1677's pin made into sections
# 1–2, and for the same reason: the coverage outlives the bug. Polarity is
# INVERTED relative to sections 1–3. Those grade a REFUSAL, because the
# module-mangled encoding is still many-to-one and a collision there can only be
# refused. Here the encoding itself was fixed: `private_mangle.injectiveIdent`
# replaced the lossy `[^A-Za-z0-9_] -> _` collapse, so the colliding program is
# now simply CORRECT and there is nothing left to refuse. The assertion is
# therefore "builds, and the two impls get DIFFERENT symbols" — asserting only
# "it built" would go green again the moment a future encoder re-collapsed the two
# keys onto one symbol AND something else masked the redefinition.
#
# memo.mdk is the second symbol family. It was never reachable while the pin
# existed: the `mdk_impl_*` collision of the same program masked it (S-2's guard
# fired first). It has NO guard of its own — `implSymbolCollisionGuard`'s SCOPE is
# `mdk_impl_*` — so the encoder is the only thing keeping its two CAFs apart, and
# its two effect lines double as the memo-SHARING assertion.

checked=$((checked + 1))
IKBIN="$WORK/impl_key.bin"
IKLOG="$WORK/impl_key.log"
"$MEDAKA" build "$FIX/impl_key/main.mdk" -o "$IKBIN" --keep-ir > "$IKLOG" 2>&1
ikst=$?

if [ "$ikst" -ne 0 ]; then
  fail "the #1950 impl-key program failed to build (exit $ikst)"
  printf '      two well-typed, unambiguous impls of one method at one head must\n'
  printf '      build. A refusal here means the emitted-symbol encoding went\n'
  printf '      many-to-one again (#1950), or the C7 arm broke. Build output:\n'
  sed 's/^/        /' "$IKLOG"
else
  ok "the #1950 impl-key program builds (exit 0)"

  checked=$((checked + 1))
  IKOUT="$WORK/impl_key.out"
  "$IKBIN" > "$IKOUT" 2>&1
  ikrst=$?
  # Hand-derived: size (MkQ MkA_B MkC) selects impl Sz (Q A_B C) = 1;
  #               size (MkQ MkA MkB_C) selects impl Sz (Q A B_C) = 2.
  printf '1|2\n' > "$WORK/impl_key.expected"
  if [ "$ikrst" -ne 0 ]; then
    fail "the #1950 impl-key binary exited $ikrst"
    sed 's/^/        /' "$IKOUT"
  elif ! diff -u "$WORK/impl_key.expected" "$IKOUT" > "$WORK/impl_key.diff" 2>&1; then
    fail "the #1950 impl-key binary stdout differs from the hand-derived 1|2"
    printf '      run != build at exit 0 is the S0 shape this whole gate exists for.\n'
    sed 's/^/        /' "$WORK/impl_key.diff"
  else
    ok "the #1950 impl-key binary runs, prints 1|2"
  fi

  # The two impls must reach the IR under DISTINCT symbols. "It built" alone is
  # not the property: a re-collapsed encoding could build again if the second
  # definition were dropped rather than redefined, which is the SILENT half of
  # this bug class.
  checked=$((checked + 1))
  nsym=$(grep -o 'mdk_impl_[A-Za-z0-9_]*_size' "$IKBIN.ll" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  if [ "$nsym" != "2" ]; then
    fail "expected 2 distinct mdk_impl_*_size symbols in the emitted IR, found $nsym"
    printf '      the two impls collapsed onto one symbol (or the IR was not kept).\n'
    grep -o 'mdk_impl_[A-Za-z0-9_]*_size' "$IKBIN.ll" 2>/dev/null | sort -u | sed 's/^/        /'
  else
    ok "the two impls are emitted under 2 distinct mdk_impl_*_size symbols"
  fi
fi

# the `$memo_` CAF family — same colliding key pair, unguarded symbol domain
checked=$((checked + 1))
MEMOBIN="$WORK/impl_key_memo.bin"
MEMOLOG="$WORK/impl_key_memo.log"
"$MEDAKA" build "$FIX/impl_key/memo.mdk" -o "$MEMOBIN" --keep-ir > "$MEMOLOG" 2>&1
mmst=$?

if [ "$mmst" -ne 0 ]; then
  fail "the #1950 \$memo_ program failed to build (exit $mmst)"
  printf '      core_ir_lower.memoBindName minted both instances one CAF; nothing\n'
  printf '      guards that family, so this surfaces as a raw clang redefinition.\n'
  sed 's/^/        /' "$MEMOLOG"
else
  ok "the #1950 \$memo_ program builds (exit 0)"

  checked=$((checked + 1))
  MEMOOUT="$WORK/impl_key_memo.out"
  "$MEMOBIN" > "$MEMOOUT" 2>&1
  mmrst=$?
  # Hand-derived: `banner` is a per-instance CAF, so each impl's effect fires
  # ONCE however many times it is forced (twice at Q A_B C, once at Q A B_C).
  printf 'eff-one\neff-two\n1|2|1\n' > "$WORK/impl_key_memo.expected"
  if [ "$mmrst" -ne 0 ]; then
    fail "the #1950 \$memo_ binary exited $mmrst"
    sed 's/^/        /' "$MEMOOUT"
  elif ! diff -u "$WORK/impl_key_memo.expected" "$MEMOOUT" > "$WORK/impl_key_memo.diff" 2>&1; then
    fail "the #1950 \$memo_ binary stdout differs from the hand-derived eff-one/eff-two/1|2|1"
    printf '      a DUPLICATED effect line means the per-instance CAF degraded into\n'
    printf '      per-call re-evaluation — the other way this fix could go wrong.\n'
    sed 's/^/        /' "$WORK/impl_key_memo.diff"
  else
    ok "the #1950 \$memo_ binary runs, prints eff-one/eff-two/1|2|1 (memo sharing intact)"
  fi

  checked=$((checked + 1))
  nmemo=$(grep -o '\$memo_[A-Za-z0-9_]*_banner' "$MEMOBIN.ll" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  if [ "$nmemo" != "2" ]; then
    fail "expected 2 distinct \$memo_*_banner globals in the emitted IR, found $nmemo"
    grep -o '\$memo_[A-Za-z0-9_]*_banner' "$MEMOBIN.ll" 2>/dev/null | sort -u | sed 's/^/        /'
  else
    ok "the two instances get 2 distinct \$memo_*_banner CAF globals"
  fi
fi

# ── the impl-key CONTROL: ordinary same-head C7 dispatch must stay green ──────
checked=$((checked + 1))
IKCBIN="$WORK/impl_key_control.bin"
IKCLOG="$WORK/impl_key_control.log"
"$MEDAKA" build "$FIX/impl_key/control.mdk" -o "$IKCBIN" > "$IKCLOG" 2>&1
ikcst=$?

if [ "$ikcst" -ne 0 ]; then
  fail "IMPL-KEY CONTROL FAILED TO BUILD (exit $ikcst)"
  printf '      control.mdk is the same C7 shape with no key on the underscore-vs-\n'
  printf '      space seam. If it breaks, ordinary same-head dispatch broke and the\n'
  printf '      positive case above proves nothing. Build output:\n'
  sed 's/^/        /' "$IKCLOG"
else
  ok "impl-key control builds (exit 0)"
  checked=$((checked + 1))
  IKCOUT="$WORK/impl_key_control.out"
  "$IKCBIN" > "$IKCOUT" 2>&1
  ikcrst=$?
  printf '1|2\n' > "$WORK/impl_key_control.expected"
  if [ "$ikcrst" -ne 0 ]; then
    fail "impl-key control binary exited $ikcrst"
    sed 's/^/        /' "$IKCOUT"
  elif ! diff -u "$WORK/impl_key_control.expected" "$IKCOUT" > "$WORK/impl_key_control.diff" 2>&1; then
    fail "impl-key control binary stdout differs from the hand-derived 1|2"
    sed 's/^/        /' "$WORK/impl_key_control.diff"
  else
    ok "impl-key control runs, prints 1|2"
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
