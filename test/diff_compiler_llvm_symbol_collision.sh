#!/bin/sh
# diff_compiler_llvm_symbol_collision.sh — the emitted-symbol INJECTIVITY gate
# (X-L.H / #348 / #748; the regression home of the drained #1677 and #1950 pins).
#
# The function and constructor witnesses exercise distinct module origins whose
# former sanitized names collided. Both must build and print 101 then 1000.
# The rest of this gate checks independent impl and dictionary symbol protections.
#
# Usage: sh test/diff_compiler_llvm_symbol_collision.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
WASMEMIT="${MEDAKA_WASM_EMITTER:-$ROOT/test/bin/wasm_emit_modules_main}"
FIX="$ROOT/test/symbol_collision_fixtures"

[ -x "$MEDAKA" ] || { printf 'no ./medaka at %s — build it first: make medaka\n' "$MEDAKA"; exit 2; }
[ -x "$EMITTER" ] || { printf 'no native emitter at %s — build it first: make medaka\n' "$EMITTER"; exit 2; }
[ -x "$WASMEMIT" ] || { printf 'no wasm emitter at %s — build it first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one wasm_emit_modules_main\n' "$WASMEMIT"; exit 2; }
[ -d "$FIX" ] || { printf 'FAIL: fixture corpus missing: %s\n' "$FIX"; exit 1; }

MEDAKA_EMITTER="$EMITTER"
MEDAKA_WASM_EMITTER="$WASMEMIT"
export MEDAKA_EMITTER MEDAKA_WASM_EMITTER

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
checked=0

fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
ok() { printf 'ok    %s\n' "$1"; }

# ── 1. function collision witness ────────────────────────────────────────────
checked=$((checked + 1))
BIN="$WORK/collide.bin"
LOG="$WORK/collide.log"
"$MEDAKA" build "$FIX/main.mdk" -o "$BIN" > "$LOG" 2>&1
st=$?
if [ "$st" -ne 0 ]; then
  fail "function collision witness failed to build (exit $st)"
  sed 's/^/        /' "$LOG"
else
  ok "function collision witness builds"
  checked=$((checked + 1))
  "$BIN" > "$WORK/collide.out" 2>&1
  rst=$?
  printf '101\n1000\n' > "$WORK/collide.expected"
  if [ "$rst" -ne 0 ] || ! diff -u "$WORK/collide.expected" "$WORK/collide.out"; then
    fail "function collision witness must print 101 then 1000 (exit $rst)"
  else
    ok "function collision witness prints 101 then 1000"
  fi
fi

# ── 2. the CONTROL must stay green, build AND run ─────────────────────────────
checked=$((checked + 1))
CBIN="$WORK/control.bin"
CLOG="$WORK/control.log"
"$MEDAKA" build "$FIX/control.mdk" -o "$CBIN" > "$CLOG" 2>&1
cst=$?

if [ "$cst" -ne 0 ]; then
  fail "function control failed to build (exit $cst)"
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

# ── 3. constructor collision witness ─────────────────────────────────────────
checked=$((checked + 1))
CTBIN="$WORK/ctor_collide.bin"
CTLOG="$WORK/ctor_collide.log"
"$MEDAKA" build "$FIX/ctor/main.mdk" -o "$CTBIN" > "$CTLOG" 2>&1
ctst=$?
if [ "$ctst" -ne 0 ]; then
  fail "constructor collision witness failed to build (exit $ctst)"
  sed 's/^/        /' "$CTLOG"
else
  ok "constructor collision witness builds"
  checked=$((checked + 1))
  "$CTBIN" > "$WORK/ctor_collide.out" 2>&1
  ctrst=$?
  printf '101\n1000\n' > "$WORK/ctor_collide.expected"
  if [ "$ctrst" -ne 0 ] || ! diff -u "$WORK/ctor_collide.expected" "$WORK/ctor_collide.out"; then
    fail "constructor collision witness must print 101 then 1000 (exit $ctrst)"
  else
    ok "constructor collision witness prints 101 then 1000"
  fi
fi

# ── the ctor CONTROL must stay green, build AND run ───────────────────────────
checked=$((checked + 1))
CTCBIN="$WORK/ctor_control.bin"
CTCLOG="$WORK/ctor_control.log"
"$MEDAKA" build "$FIX/ctor/control.mdk" -o "$CTCBIN" > "$CTCLOG" 2>&1
ctcst=$?

if [ "$ctcst" -ne 0 ]; then
  fail "constructor control failed to build (exit $ctcst)"
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
# This section checks the emitter-minted impl and memo symbol families.

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
  nsym=$(grep -o 'mdk[.]impl[.][0-9a-f]*[.]73697a65' "$IKBIN.ll" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  if [ "$nsym" != "2" ]; then
    fail "expected 2 distinct mdk_impl_*_size symbols in the emitted IR, found $nsym"
    printf '      the two impls collapsed onto one symbol (or the IR was not kept).\n'
    grep -o 'mdk[.]impl[.][0-9a-f]*[.]73697a65' "$IKBIN.ll" 2>/dev/null | sort -u | sed 's/^/        /'
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
  nmemo=$(grep -o 'mdk[.]global[.]246d656d6f5f[0-9a-f]*5f62616e6e6572' "$MEMOBIN.ll" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  if [ "$nmemo" != "2" ]; then
    fail "expected 2 distinct \$memo_*_banner globals in the emitted IR, found $nmemo"
    grep -o 'mdk[.]global[.]246d656d6f5f[0-9a-f]*5f62616e6e6572' "$MEMOBIN.ll" 2>/dev/null | sort -u | sed 's/^/        /'
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

# ── 5. the DICT-WITNESS TAG domain (FR-1, #348/#377) — scope-narrowing coverage ──
# `core_validate.validateDictTags` checks a SEPARATE space from sections 1-4's
# emitted-symbol domain: the dict-witness/route-word tag a shared dispatcher
# compares at runtime (`private_mangle.hashName`, a non-injective djb2 hash — see
# its own comment for the constructible-collision mechanism). FR-1 fixed the guard
# to partition its population by METHOD NAME, the same grouping key the emitted
# dispatcher itself uses (`llvm_emit.implsOf`/`dispFnName` — a method-name lookup),
# because a collision between two UNRELATED methods' route words is never actually
# compared at runtime and refusing it was a false positive (F-1/F-2 review
# findings). This section is the missing regression coverage those findings named.

# positive control: an unrelated-method collision (this program's `JMt` vs the
# prelude's `Int`) must now BUILD and RUN.
checked=$((checked + 1))
DWBIN="$WORK/dict_witness_positive.bin"
DWLOG="$WORK/dict_witness_positive.log"
"$MEDAKA" build "$FIX/dict_witness/positive.mdk" -o "$DWBIN" > "$DWLOG" 2>&1
dwst=$?

if [ "$dwst" -ne 0 ]; then
  fail "the dict-witness positive control failed to build (exit $dwst)"
  printf '      an unrelated-method route-word collision (this program'"'"'s route word\n'
  printf '      vs a prelude impl'"'"'s, for a DIFFERENT method) must not refuse: the two\n'
  printf '      words are never compared by any real dispatch chain. Build output:\n'
  sed 's/^/        /' "$DWLOG"
else
  ok "the dict-witness positive control builds (exit 0)"

  checked=$((checked + 1))
  DWOUT="$WORK/dict_witness_positive.out"
  "$DWBIN" > "$DWOUT" 2>&1
  dwrst=$?
  printf 'jmt\n' > "$WORK/dict_witness_positive.expected"
  if [ "$dwrst" -ne 0 ]; then
    fail "the dict-witness positive control binary exited $dwrst"
    sed 's/^/        /' "$DWOUT"
  elif ! diff -u "$WORK/dict_witness_positive.expected" "$DWOUT" > "$WORK/dict_witness_positive.diff" 2>&1; then
    fail "the dict-witness positive control stdout differs from the hand-derived jmt"
    sed 's/^/        /' "$WORK/dict_witness_positive.diff"
  else
    ok "the dict-witness positive control runs, prints jmt"
  fi
fi

# negative control: a SAME-method-name collision (Mzone/NYone, S-4's construction,
# dispatched through one dict parameter) must still REFUSE.
checked=$((checked + 1))
DWNBIN="$WORK/dict_witness_negative.bin"
DWNLOG="$WORK/dict_witness_negative.log"
"$MEDAKA" build "$FIX/dict_witness/negative.mdk" -o "$DWNBIN" > "$DWNLOG" 2>&1
dwnst=$?

if [ "$dwnst" -eq 0 ]; then
  fail "the dict-witness negative control built at exit 0 — the guard did NOT fire"
  printf '      two impls of ONE method name (zn) with colliding route words ARE\n'
  printf '      compared by that method'"'"'s shared dispatcher; this must still refuse.\n'
  printf '      Build output:\n'
  sed 's/^/        /' "$DWNLOG"
else
  ok "the dict-witness negative control refused (exit $dwnst)"
fi

# The message must name both route words -- not merely "it failed".
checked=$((checked + 1))
dwnmissing=""
for want in 'emitted dict-witness tag collision' 'method `zn`' 'Mzone' 'NYone'; do
  grep -q -- "$want" "$DWNLOG" || dwnmissing="$dwnmissing '$want'"
done
if [ -n "$dwnmissing" ]; then
  fail "dict-witness negative-control diagnostic does not name both route words; missing:$dwnmissing"
  sed 's/^/        /' "$DWNLOG"
else
  ok "dict-witness negative-control refusal names both route words and the method"
fi

# It must refuse BEFORE producing anything.
checked=$((checked + 1))
if [ -e "$DWNBIN" ]; then
  fail "a binary was produced at $DWNBIN despite the dict-witness refusal"
  printf '      the property is "refuses before any binary is produced".\n'
else
  ok "no binary produced (dict-witness domain)"
fi

# the inherited-default shape: `zn` supplied at Mzone, inherited at NYone. Both
# are arms of `zn`'s one dispatcher, so the colliding pair must still REFUSE.
checked=$((checked + 1))
DWDBIN="$WORK/dict_witness_default.bin"
DWDLOG="$WORK/dict_witness_default.log"
"$MEDAKA" build "$FIX/dict_witness/default_negative.mdk" -o "$DWDBIN" > "$DWDLOG" 2>&1
dwdst=$?

if [ "$dwdst" -eq 0 ]; then
  fail "the inherited-default collision built at exit 0 — the guard skipped the default entry"
  printf '      a supplied impl and an inherited default of ONE method share its\n'
  printf '      dispatcher; with colliding words the binary answers default|default.\n'
  sed 's/^/        /' "$DWDLOG"
else
  ok "the inherited-default collision refused (exit $dwdst)"
fi

checked=$((checked + 1))
dwdmissing=""
for want in 'emitted dict-witness tag collision' 'method `zn`' 'Mzone' 'NYone'; do
  grep -q -- "$want" "$DWDLOG" || dwdmissing="$dwdmissing '$want'"
done
if [ -n "$dwdmissing" ]; then
  fail "inherited-default refusal does not name both route words; missing:$dwdmissing"
  sed 's/^/        /' "$DWDLOG"
else
  ok "inherited-default refusal names both route words and the method"
fi

checked=$((checked + 1))
if [ -e "$DWDBIN" ]; then
  fail "a binary was produced at $DWDBIN despite the inherited-default refusal"
else
  ok "no binary produced (inherited-default shape)"
fi

# ── 6. the WasmGC emitter's own dict-tag arm (#377) ─────────────────────────────
# Each emitter refuses at its own width. `wasm_only.mdk` collides only in the
# 30-bit wasm `dictTag`: it must build and run natively, and the wasm emitter must
# refuse it. `negative.mdk` collides in the full width, which the wasm emitter
# checks too.

# wasm_emit <fixture> <tag> : run the wasm emitter, WAT to $tag.wat, set $wst
wasm_emit() {
  "$WASMEMIT" "$ROOT/stdlib/runtime.mdk" "$ROOT/stdlib/core.mdk" "$1" "$(dirname "$1")" "$ROOT/stdlib" > "$WORK/$2.wat" 2> "$WORK/$2.log"
  wst=$?
}

# wasm_refuses <tag> <want>... : assert $wst, the message lines, and no WAT written
wasm_refuses() {
  tag=$1
  shift
  checked=$((checked + 1))
  if [ "$wst" -eq 0 ]; then
    fail "$tag emitted at exit 0 — the wasm emitter's dict-tag arm did NOT fire"
    sed 's/^/        /' "$WORK/$tag.log"
  else
    ok "$tag refused by the wasm emitter (exit $wst)"
  fi
  checked=$((checked + 1))
  wmissing=""
  for want in "$@"; do
    grep -q -- "$want" "$WORK/$tag.log" || wmissing="$wmissing '$want'"
  done
  if [ -n "$wmissing" ]; then
    fail "$tag wasm refusal does not name the space and both route words; missing:$wmissing"
    sed 's/^/        /' "$WORK/$tag.log"
  else
    ok "$tag wasm refusal names the tag space and both route words"
  fi
  checked=$((checked + 1))
  if [ -s "$WORK/$tag.wat" ]; then
    fail "the wasm emitter wrote WAT for $tag despite the refusal"
  else
    ok "no WAT written ($tag)"
  fi
}

checked=$((checked + 1))
WOBIN="$WORK/wasm_only.bin"
"$MEDAKA" build "$FIX/dict_witness/wasm_only.mdk" -o "$WOBIN" > "$WORK/wasm_only_native.log" 2>&1
wost=$?
if [ "$wost" -ne 0 ]; then
  fail "the wasm-only collision failed to build natively (exit $wost)"
  printf '      its full i64 tags are distinct, so the native dispatcher is correct\n'
  printf '      and the native emitter must not refuse. Build output:\n'
  sed 's/^/        /' "$WORK/wasm_only_native.log"
else
  ok "the wasm-only collision builds natively (exit 0)"
  checked=$((checked + 1))
  "$WOBIN" > "$WORK/wasm_only.out" 2>&1
  worst=$?
  printf 'd|l\n' > "$WORK/wasm_only.expected"
  if [ "$worst" -ne 0 ] || ! diff -u "$WORK/wasm_only.expected" "$WORK/wasm_only.out" > "$WORK/wasm_only.diff" 2>&1; then
    fail "the wasm-only collision's native binary did not print the hand-derived d|l (exit $worst)"
    sed 's/^/        /' "$WORK/wasm_only.out"
  else
    ok "the wasm-only collision's native binary prints d|l"
  fi
fi

wasm_emit "$FIX/dict_witness/wasm_only.mdk" wasm_only_wasm
wasm_refuses wasm_only_wasm 'emitted dict-witness tag collision' 'tag space: wasm (WasmGC) 30-bit' 'Dbnfbcp' 'Llzhriz'

wasm_emit "$FIX/dict_witness/negative.mdk" negative_wasm
wasm_refuses negative_wasm 'emitted dict-witness tag collision' 'tag space: native (LLVM) i64' 'Mzone' 'NYone'

wasm_emit "$FIX/dict_witness/default_negative.mdk" default_negative_wasm
wasm_refuses default_negative_wasm 'emitted dict-witness tag collision' 'tag space: native (LLVM) i64' 'Mzone' 'NYone'

# A primed top-level name and its unprimed control both compute 3 + 10.
printf "%s\n" 13 > "$WORK/primed.expected"
for fixture in main control; do
  for engine in eval native wasm; do
    rm -f "$WORK/primed.bin" "$WORK/primed.wasm" "$WORK/primed.log"
    checked=$((checked + 1))
    case "$engine" in
      eval)
        MEDAKA_STRICT=1 "$MEDAKA" run "$FIX/primed/$fixture.mdk" > "$WORK/primed.out" 2> "$WORK/primed.err"
        result=$?
        ;;
      native)
        MEDAKA_STRICT=1 "$MEDAKA" build "$FIX/primed/$fixture.mdk" -o "$WORK/primed.bin" > "$WORK/primed.log" 2>&1 && [ -s "$WORK/primed.bin" ] && "$WORK/primed.bin" > "$WORK/primed.out" 2> "$WORK/primed.err"
        result=$?
        ;;
      wasm)
        MEDAKA_STRICT=1 "$MEDAKA" build --target wasm "$FIX/primed/$fixture.mdk" -o "$WORK/primed.wasm" > "$WORK/primed.log" 2>&1 && [ -s "$WORK/primed.wasm" ] && node "$ROOT/test/wasm/run.js" "$WORK/primed.wasm" > "$WORK/primed.out" 2> "$WORK/primed.err"
        result=$?
        ;;
    esac
    if [ "$result" -eq 0 ] && diff -u "$WORK/primed.expected" "$WORK/primed.out"; then
      ok "primed $fixture $engine prints 13"
    else
      fail "primed $fixture $engine failed (exit $result)"
      cat "$WORK/primed.log" "$WORK/primed.err" 2>/dev/null
    fi
  done
done

# Physical function and global names must remain distinct across modules.
mkdir -p "$WORK/physical"
printf 'export x : Int\nexport x = 5 * 21\n' > "$WORK/physical/m.mdk"
printf 'export x : Int -> Int\nexport x y = y + 1000\n' > "$WORK/physical/g_m.mdk"
printf 'import m as A\nimport g_m as B\nmain =\n  println A.x\n  println (B.x 1)\n' > "$WORK/physical/main.mdk"
printf '105\n1001\n' > "$WORK/physical/expected"
checked=$((checked + 1))
if "$MEDAKA" run "$WORK/physical/main.mdk" > "$WORK/physical/eval.out" 2> "$WORK/physical/eval.err" && diff -u "$WORK/physical/expected" "$WORK/physical/eval.out"; then
  ok "physical collision witness evaluates correctly"
else
  fail "physical collision witness failed eval"
fi
checked=$((checked + 1))
if "$MEDAKA" build "$WORK/physical/main.mdk" -o "$WORK/physical/native" > "$WORK/physical/build.log" 2>&1 && [ -s "$WORK/physical/native" ] && "$WORK/physical/native" > "$WORK/physical/native.out" 2> "$WORK/physical/native.err" && diff -u "$WORK/physical/expected" "$WORK/physical/native.out"; then
  ok "physical collision witness builds and runs correctly"
else
  fail "physical collision witness failed native build or run"
fi

printf '\nchecked %d assertions: %d failed\n' "$checked" "$fails"

# "checked nothing" must never look like "passed" — every silent-green bug in this
# repo is that sentence.
if [ "$checked" -eq 0 ]; then
  printf 'FAIL: graded zero assertions\n'
  exit 1
fi

[ "$fails" -eq 0 ]
