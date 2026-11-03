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

# ── 5. dictionary headers that hash alike ───────────────────────────────────────
# A dictionary's header word (`private_mangle.hashName`, a non-injective djb2 hash)
# is identity only: a call loads a method-table slot and nothing compares the
# header, so two instances whose keys hash alike must build and answer as `run`
# does. The positive control is an unrelated-method collision with a prelude impl;
# the same-method and inherited-default shapes are the ones a tag-comparing
# dispatcher answered wrongly.

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

# builds_and_prints <fixture> <tag> <want> : native build, run, compare stdout
builds_and_prints() {
  checked=$((checked + 1))
  bp_bin="$WORK/$2.bin"
  bp_log="$WORK/$2.log"
  "$MEDAKA" build "$FIX/dict_witness/$1" -o "$bp_bin" > "$bp_log" 2>&1
  bp_st=$?
  if [ "$bp_st" -ne 0 ]; then
    fail "$2 failed to build (exit $bp_st); colliding dictionary headers must not refuse"
    sed 's/^/        /' "$bp_log"
    return
  fi
  checked=$((checked + 1))
  printf '%s\n' "$3" > "$WORK/$2.expected"
  "$bp_bin" > "$WORK/$2.out" 2>&1
  bp_rst=$?
  if [ "$bp_rst" -ne 0 ] || ! diff -u "$WORK/$2.expected" "$WORK/$2.out" > "$WORK/$2.diff" 2>&1; then
    fail "$2 binary did not print the hand-derived $3 (exit $bp_rst)"
    sed 's/^/        /' "$WORK/$2.diff"
  else
    ok "$2 builds and prints $3"
  fi
}

# two impls of ONE method name at keys with equal hashes, dispatched through one dict
builds_and_prints negative.mdk dict_witness_same_method 'mzone|nyone'

# supplied at Mzone, inherited at NYone
builds_and_prints default_negative.mdk dict_witness_default 'mzone|default'

# ── 6. the WasmGC emitter accepts the same programs ─────────────────────────────
# The wasm header is the 30-bit `dictTag`; `wasm_only.mdk` collides only there and
# the others collide in the full width. None may be refused.

# wasm_emit <fixture> <tag> : run the wasm emitter, WAT to $tag.wat, set $wst
wasm_emit() {
  "$WASMEMIT" "$ROOT/stdlib/runtime.mdk" "$ROOT/stdlib/core.mdk" "$1" "$(dirname "$1")" "$ROOT/stdlib" > "$WORK/$2.wat" 2> "$WORK/$2.log"
  wst=$?
}

# wasm_accepts <tag> : the emitter exited 0 and wrote WAT
wasm_accepts() {
  checked=$((checked + 1))
  if [ "$wst" -eq 0 ] && [ -s "$WORK/$1.wat" ]; then
    ok "$1 emitted by the wasm emitter"
  else
    fail "$1 refused by the wasm emitter (exit $wst)"
    sed 's/^/        /' "$WORK/$1.log"
  fi
}

builds_and_prints wasm_only.mdk dict_witness_wasm_only 'd|l'

wasm_emit "$FIX/dict_witness/wasm_only.mdk" wasm_only_wasm
wasm_accepts wasm_only_wasm

wasm_emit "$FIX/dict_witness/negative.mdk" negative_wasm
wasm_accepts negative_wasm

wasm_emit "$FIX/dict_witness/default_negative.mdk" default_negative_wasm
wasm_accepts default_negative_wasm

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
