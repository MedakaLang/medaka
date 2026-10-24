# META
source_lines=3537
stages=DESUGAR,MARK
# SOURCE
import backend.wasm_demand.{
  WasmDemandPlan, PlannedImport, helperOrder, hasWasmHelper, jsWireParam,
  jsWireResult, unaryF64Sig, binaryF64Sig
}
import backend.wasm_demand.{JsImport(..)}
-- WasmGC module PREAMBLE — the fixed lines that head every emitted WAT module
-- (WASMGC-DESIGN.md §3 type-section + §6 host-import seam).  Peer of
-- `backend.llvm_preamble` (the `declare @mdk_…` block): PURE DATA, identical for
-- every program, so it carries no dependency on the emitter's state.  Kept in its
-- own module to avoid a circular import (wasm_emit iterates this list).
--
-- ── W2 SCOPE (WASMGC-DESIGN §9 slice 2 — immediates + arithmetic) ────────────
--   * The value rep for the SCALAR subset is raw `i32` (the §3.2 recommendation:
--     "for monomorphic Int arithmetic keep values as raw i32").  Ints/Bools are
--     `i32`.  The i31ref/`(ref eq)` unitype + boxing (§3.1/§3.2) is exercised by
--     W3 (ADTs) — see `recGroupLines` below + the §3.4 per-type struct emission in
--     wasm_emit's `emitTypeSection`.
--
-- ── W3 SCOPE (WASMGC-DESIGN §9 slice 3 — ADTs + match) ───────────────────────
-- A program that uses NO ADTs (no `data` decl, no `match`) emits exactly the W2
-- scalar shape (raw i32, the 15 W2 fixtures stay byte-identical).  A program that
-- DOES use an ADT switches to the §8.6 uniform `(ref eq)` value rep: every value
-- slot is `(ref eq)`, scalars/Bool/Unit/nullary-ctors are `i31ref` immediates
-- (`ref.i31`), payload constructors are per-ctor `struct`s with an explicit i32
-- discriminant field 0 (§3.4 — defends against WasmGC structural-subtyping
-- collapse) under a per-datatype root struct.  The type section's `rec` group is
-- emitted DYNAMICALLY by wasm_emit (`emitTypeSection`) since it depends on the
-- program's `data` decls; this preamble carries only the FIXED header + imports.
--
-- ── Output ABI (§6 IO / §10 fork e) ──────────────────────────────────────────
-- The emitter auto-prints the scalar `main` result (the LLVM gate's value-main
-- auto-print contract, mirrored), routed by static type:
--   - `env.mdk_write_int(i32)`  — write the int as decimal + newline
--   - `env.mdk_write_bool(i32)` — write "true"/"false" + newline
-- The JS runner (`test/wasm/run.js`) does the int→decimal / bool→text + newline
-- formatting.  This is a TEMPORARY scaffold the W6 string slice replaces.  The
-- bytes it produces are exactly the native-compiled oracle's `pp_value`.
--
-- Order is load-bearing: emitted WAT is assembled by `wasm-tools parse` and the
-- program's stdout is diffed byte-for-byte against the oracle, so these lines stay
-- in EXACTLY this order.  The module is CLOSED by the emitter (it appends the type
-- section, function defs, `(start)`, and the trailing `)`), so this preamble
-- deliberately leaves the `(module` paren OPEN.

import support.util.{anyList, contains, joinWith}
import types.private_mangle.{injectiveIdent}

export
preambleHeadLines : List String
preambleHeadLines = [
  ";; Medaka WasmGC backend (Stage 2.4c) — emitted WAT.",
  ";; Value rep: WASMGC-DESIGN.md §3 / §8.6.  W2 = scalar i32; W3 = (ref eq) + i31/structs.",
  "(module",
]

-- the §6 host-import IO seam (emitted AFTER the type section, since some engines /
-- the binary format want imports grouped, but WAT order here is fine either way —
-- kept after the rec group for readability of the emitted module).
export
importLines : List String
importLines = [
  "  ;; ── §6 host-import IO seam (§10 fork e — custom import) ──",
  "  (import \"env\" \"mdk_write_int\" (func $mdk_write_int (param i32)))",
  "  (import \"env\" \"mdk_write_bool\" (func $mdk_write_bool (param i32)))",
]

-- ── W4 closure / TCO preamble (WASMGC-DESIGN §4) ─────────────────────────────
-- The closure ABI types + the universal apply runtime.  Emitted (by wasm_emit's
-- `emitTypeSection`) only when a program uses closures / higher-order application
-- (`progUseClos`).  The closure layout carries ARITY IN THE STRUCT (§11) so every
-- application site reads arity from the value — never a name-keyed side table —
-- which kills the native backend's table-miss miscompile class by construction.
--
--   $argarr  = (array (mut (ref null eq)))  — args / captured-env vector
--   $codety  = (func (param $self (ref eq)) (param $args (ref $argarr))
--                     (result (ref eq)))    — ONE uniform code signature (no
--                     per-arity funcref type; over/under/exact stay uniform)
--   $clos    = (struct $code $arity $env)   — funcref + arity + spill/env array
--
-- A lifted lambda reads its captures from `self`'s $env array and its params from
-- the $args array.  A capture-free top-level fn used as a VALUE gets a wrapper
-- closure (arity = param count, env = []).  Direct saturated top-level calls stay
-- a plain `call` (the fast path) and never touch this machinery.
export
closTypeLines : List String
closTypeLines = [
  "    ;; ── §4 closure ABI (arity-in-struct, uniform code sig) ──",
  "    (type $argarr (array (mut (ref null eq))))",
  "    (type $codety (func (param (ref eq)) (param (ref $argarr)) (result (ref eq))))",
  "    (type $clos (sub (struct (field $code (ref $codety)) (field $arity i32) (field $env (ref $argarr)))))"
]

-- the universal apply runtime (emitted once, after the function defs).  `$__mdk_apply`
-- takes a closure value + an args array and dispatches on the closure's arity:
--   exact  (argc == arity) → return_call_ref the code (guaranteed-tail);
--   under  (argc <  arity) → build a PAP closure (env = [orig, partialArgs…],
--                            code = $mdk_pap) with the REMAINING arity;
--   over   (argc >  arity) → saturate the first `arity` args (call_ref), then
--                            return_call $__mdk_apply on the result with the surplus.
-- `$mdk_pap` is the PAP code: env[0] is the original closure, env[1..] the saved
-- partial args; it concatenates saved + incoming and re-applies the original.
export
closApplyLines : List String
closApplyLines = [
  "  ;; ── §4 universal apply runtime (exact / under-PAP / over-saturate) ──",
  "  (func $mdk_pap (type $codety) (param $self (ref eq)) (param $args (ref $argarr)) (result (ref eq))",
  "    (local $c (ref $clos)) (local $env (ref $argarr)) (local $orig (ref eq))",
  "    (local $ne i32) (local $na i32) (local $total (ref $argarr)) (local $i i32)",
  "    (local.set $c (ref.cast (ref $clos) (local.get $self)))",
  "    (local.set $env (struct.get $clos $env (local.get $c)))",
  "    (local.set $orig (ref.as_non_null (array.get $argarr (local.get $env) (i32.const 0))))",
  "    (local.set $ne (i32.sub (array.len (local.get $env)) (i32.const 1)))",
  "    (local.set $na (array.len (local.get $args)))",
  "    (local.set $total (array.new $argarr (ref.null eq) (i32.add (local.get $ne) (local.get $na))))",
  "    (local.set $i (i32.const 0))",
  "    (block $pd (loop $pl",
  "      (br_if $pd (i32.ge_s (local.get $i) (local.get $ne)))",
  "      (array.set $argarr (local.get $total) (local.get $i)",
  "        (array.get $argarr (local.get $env) (i32.add (local.get $i) (i32.const 1))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $pl)))",
  "    (local.set $i (i32.const 0))",
  "    (block $pd2 (loop $pl2",
  "      (br_if $pd2 (i32.ge_s (local.get $i) (local.get $na)))",
  "      (array.set $argarr (local.get $total) (i32.add (local.get $ne) (local.get $i))",
  "        (array.get $argarr (local.get $args) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $pl2)))",
  "    (return_call $__mdk_apply (local.get $orig) (local.get $total)))",
  "  (func $__mdk_apply (param $f (ref eq)) (param $args (ref $argarr)) (result (ref eq))",
  "    (local $c (ref $clos)) (local $ar i32) (local $na i32)",
  "    (local $sat (ref $argarr)) (local $surplus (ref $argarr)) (local $i i32) (local $r (ref eq))",
  "    (local $penv (ref $argarr))",
  "    (local.set $c (ref.cast (ref $clos) (local.get $f)))",
  "    (local.set $ar (struct.get $clos $arity (local.get $c)))",
  "    (local.set $na (array.len (local.get $args)))",
  "    (if (result (ref eq)) (i32.eq (local.get $na) (local.get $ar))",
  "      (then (return_call_ref $codety (local.get $f) (local.get $args) (struct.get $clos $code (local.get $c))))",
  "      (else",
  "        (if (result (ref eq)) (i32.lt_s (local.get $na) (local.get $ar))",
  "          (then",
  "            (local.set $penv (array.new $argarr (ref.null eq) (i32.add (local.get $na) (i32.const 1))))",
  "            (array.set $argarr (local.get $penv) (i32.const 0) (local.get $f))",
  "            (local.set $i (i32.const 0))",
  "            (block $ud (loop $ul",
  "              (br_if $ud (i32.ge_s (local.get $i) (local.get $na)))",
  "              (array.set $argarr (local.get $penv) (i32.add (local.get $i) (i32.const 1))",
  "                (array.get $argarr (local.get $args) (local.get $i)))",
  "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $ul)))",
  "            (struct.new $clos (ref.func $mdk_pap) (i32.sub (local.get $ar) (local.get $na)) (local.get $penv)))",
  "          (else",
  "            (local.set $sat (array.new $argarr (ref.null eq) (local.get $ar)))",
  "            (local.set $i (i32.const 0))",
  "            (block $sd (loop $sl",
  "              (br_if $sd (i32.ge_s (local.get $i) (local.get $ar)))",
  "              (array.set $argarr (local.get $sat) (local.get $i)",
  "                (array.get $argarr (local.get $args) (local.get $i)))",
  "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $sl)))",
  "            (local.set $r (call_ref $codety (local.get $f) (local.get $sat) (struct.get $clos $code (local.get $c))))",
  "            (local.set $surplus (array.new $argarr (ref.null eq) (i32.sub (local.get $na) (local.get $ar))))",
  "            (local.set $i (i32.const 0))",
  "            (block $od (loop $ol",
  "              (br_if $od (i32.ge_s (local.get $i) (i32.sub (local.get $na) (local.get $ar))))",
  "              (array.set $argarr (local.get $surplus) (local.get $i)",
  "                (array.get $argarr (local.get $args) (i32.add (local.get $i) (local.get $ar))))",
  "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $ol)))",
  "            (return_call $__mdk_apply (local.get $r) (local.get $surplus)))))))",
]

-- the SCALAR-only preamble (no ADTs in the program): the W2 shape verbatim — an
-- empty forward-compat rec group + the imports.  Kept byte-identical to the W2
-- output so the 15 scalar fixtures do not move.
export
preambleScalarLines : List String
preambleScalarLines =
  preambleHeadLines
    ++ [
      "  ;; ── §3 type section (one rec group, iso-recursive / nominal-modulo-canon) ──",
      "  ;; This program uses no ADTs — the scalar subset computes in raw i32 and only",
      "  ;; the print boundary is reached; the unitype scaffolding is declared unused.",
      "  (rec",
      "    ;; boxed Int outside the i31 range (§3.2) — declared, unused.",
      "    (type $boxint (sub (struct (field i64))))",
      "    ;; boxed Float (§3.3) — declared, unused until a Float fixture needs it.",
      "    (type $float (sub (struct (field f64))))", "  )"
    ]
    ++ importLines

-- ── W6 byte-level IO seam (§6 / §10 fork e) ──────────────────────────────────
-- The scaffold-collapse: instead of importing `mdk_write_int`/`mdk_write_bool` (which
-- made the JS runner do the decimal / true|false / newline FORMATTING), the module
-- now produces the bytes ITSELF (real intToString/string codegen, this slice) and
-- writes them one byte at a time through ONE custom host import — the §6 stdout seam,
-- engine-portable (no GC-array↔JS interop needed).  The JS runner just accumulates
-- raw bytes and UTF-8-decodes them.
export
ioByteImportLines : List String
ioByteImportLines = [
  "  ;; ── §6 host-import IO seam (§10 fork e — byte-level custom import) ──",
  "  (import \"env\" \"mdk_write_byte\" (func $mdk_write_byte (param i32)))",
]

-- the §3.3 String aggregate types — emitted into the rec group only when a program
-- uses strings (`useStrRef`).  `$str` caches the codepoint count so `stringLength`
-- is O(1) (RUNTIME-DESIGN §7 decision 2 / §5 INTRINSIC).  `$u8arr` is the UTF-8 byte
-- backing store (mutable so `array.new_data` / `array.new` can fill it).
export
strTypeLines : List String
strTypeLines = [
  "    ;; ── §3.3 String aggregate (UTF-8 bytes + cached codepoint count) ──",
  "    (type $u8arr (array (mut i8)))",
  "    (type $str (sub (struct (field $cp_count i32) (field $bytes (ref $u8arr)))))",
]

-- the byte-write print runtime (emitted once, after the function defs, when the
-- program does any IO / value-main auto-print).  Self-contained WAT — no host help
-- beyond `$mdk_write_byte`.
--   $mdk_print_str  — write a $str's UTF-8 bytes verbatim (no newline; putStr).
--   $mdk_print_strln— write a $str's bytes + a trailing '\n' (putStrLn / String main).
--   $mdk_print_int  — render an i64 in decimal (sign + digits) and byte-write it + '\n'
--                     (matches medaka_rt.c mdk_int_to_string's "%lld" + mdk_print_int's
--                     trailing newline).
--   $mdk_print_bool — write "True"/"False" + '\n' (value-main Bool auto-print;
--                     matches native's `println`/`display` Debug rendering — the
--                     composite-main autoprint wrap renders Bool as `True`/`False`,
--                     so the WasmGC direct value-main auto-print must agree).
--   $mdk_int_to_str — render an i64 in decimal into a fresh $str (intToString; the
--                     LEAF extern).  cp_count == byte_len (all ASCII digits/sign).
export
ioRuntimeLines : List String
ioRuntimeLines = [
  "  ;; ── §2.1 Int representation seam: i31 fast path / $boxint i64 box ──",
  "  ;; layer-17 SOUNDNESS: Ints in [-2^30, 2^30) are i31ref immediates; outside that",
  "  ;; range they box into (struct (field i64)) ($boxint).  ALL Int arithmetic unboxes",
  "  ;; both operands to i64 via $mdk_unbox_int, computes in i64, and re-boxes via",
  "  ;; $mdk_box_int — so >2^30 values no longer truncate to 31 bits.",
  "  (func $mdk_unbox_int (param $v (ref eq)) (result i64)",
  "    (if (result i64) (ref.test (ref i31) (local.get $v))",
  "      (then (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $v)))))",
  "      (else (struct.get $boxint 0 (ref.cast (ref $boxint) (local.get $v))))))",
  "  ;; box an i64 Int: in [-2^30, 2^30) -> i31 immediate; else -> $boxint struct.",
  "  ;; An Int is 63-bit.  The sign-extend from bit 62 (the `(x << 1) >> 1` pair, which",
  "  ;; mirrors native's tag/untag and is a no-op on any 63-bit value) makes `every",
  "  ;; (ref eq) Int holds a 63-bit value` a representation invariant, so INT64_MIN is",
  "  ;; unreachable.  Arithmetic does not lean on it: `+ - * /` and negation are checked",
  "  ;; before they box ($mdk_int_add...).  It is the defined result only for the",
  "  ;; operations that discard high bits: shiftLeft drops the bits past bit 62, as",
  "  ;; native's retag does, and u64TruncateToInt keeps the low 63.  This is the SOLE",
  "  ;; producer of $boxint.",
  "  (func $mdk_box_int (param $n i64) (result (ref eq))",
  "    (local.set $n (i64.shr_s (i64.shl (local.get $n) (i64.const 1)) (i64.const 1)))",
  "    (if (result (ref eq))",
  "        (i32.and (i64.ge_s (local.get $n) (i64.const -1073741824))",
  "                 (i64.lt_s (local.get $n) (i64.const 1073741824)))",
  "      (then (ref.i31 (i32.wrap_i64 (local.get $n))))",
  "      (else (struct.new $boxint (local.get $n)))))",
  "  ;; ── §6 byte-write print runtime (decimal int / bool text) ──",
  "  ;; write the decimal digits of a NON-NEGATIVE i64 (most-significant first).",
  "  (func $mdk_write_digits (param $n i64)",
  "    (if (i64.ge_s (local.get $n) (i64.const 10))",
  "      (then (call $mdk_write_digits (i64.div_s (local.get $n) (i64.const 10)))))",
  "    (call $mdk_write_byte", "      (i32.add (i32.const 48)",
  "        (i32.wrap_i64 (i64.rem_s (local.get $n) (i64.const 10))))))",
  "  ;; render an i64 in decimal to stdout + a trailing newline (value-main Int).",
  "  (func $mdk_print_int (param $n i64)",
  "    (if (i64.lt_s (local.get $n) (i64.const 0))", "      (then",
  "        (call $mdk_write_byte (i32.const 45))",
  "        (call $mdk_write_digits (i64.sub (i64.const 0) (local.get $n))))",
  "      (else (call $mdk_write_digits (local.get $n))))",
  "    (call $mdk_write_byte (i32.const 10)))",
  "  (func $mdk_print_bool (param $b i32)", "    (if (local.get $b)",
  "      (then",
  "        (call $mdk_write_byte (i32.const 84)) (call $mdk_write_byte (i32.const 114))",
  "        (call $mdk_write_byte (i32.const 117)) (call $mdk_write_byte (i32.const 101)))",
  "      (else",
  "        (call $mdk_write_byte (i32.const 70)) (call $mdk_write_byte (i32.const 97))",
  "        (call $mdk_write_byte (i32.const 108)) (call $mdk_write_byte (i32.const 115))",
  "        (call $mdk_write_byte (i32.const 101))))",
  "    (call $mdk_write_byte (i32.const 10)))"
]

-- the STRING-dependent byte-write runtime (references `$str`/`$u8arr`) — emitted only
-- when the program uses strings (`useStrRef`), so a string-free module never names
-- the absent `$str` type.
--   $mdk_print_str  — write a $str's UTF-8 bytes verbatim (no newline; putStr).
--   $mdk_print_strln— write a $str's bytes + a trailing '\n' (putStrLn / String main).
--   $mdk_int_to_str — render an i64 in decimal into a fresh $str (intToString; the
--                     LEAF extern).  cp_count == byte_len (all ASCII digits/sign).
export
ioStrRuntimeLines : List String
ioStrRuntimeLines = [
  "  ;; ── §6 string byte-write runtime ($str-dependent) ──",
  "  (func $mdk_print_str (param $s (ref $str))",
  "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_write_byte (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))",
  "  (func $mdk_print_strln (param $s (ref $str))",
  "    (call $mdk_print_str (local.get $s))",
  "    (call $mdk_write_byte (i32.const 10)))",
  "  ;; intToString : render an i64 in decimal into a fresh $str (cp_count == byte len).",
  "  (func $mdk_int_to_str (param $n i64) (result (ref $str))",
  "    (local $neg i32) (local $m i64) (local $len i32) (local $i i32)",
  "    (local $buf (ref $u8arr)) (local $d i32)",
  "    (local.set $neg (i64.lt_s (local.get $n) (i64.const 0)))",
  "    (local.set $m (if (result i64) (local.get $neg)",
  "      (then (i64.sub (i64.const 0) (local.get $n))) (else (local.get $n))))",
  "    ;; count digits",
  "    (local.set $len (i32.const 1))",
  "    (block $cd (loop $cl",
  "      (br_if $cd (i64.lt_s (local.get $m) (i64.const 10)))",
  "      (local.set $len (i32.add (local.get $len) (i32.const 1)))",
  "      (local.set $m (i64.div_s (local.get $m) (i64.const 10)))",
  "      (br $cl)))",
  "    (local.set $m (if (result i64) (local.get $neg)",
  "      (then (i64.sub (i64.const 0) (local.get $n))) (else (local.get $n))))",
  "    (if (local.get $neg) (then (local.set $len (i32.add (local.get $len) (i32.const 1)))))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $len)))",
  "    ;; fill digits from least-significant (end) backward",
  "    (local.set $i (i32.sub (local.get $len) (i32.const 1)))",
  "    (block $fd (loop $fl",
  "      (array.set $u8arr (local.get $buf) (local.get $i)",
  "        (i32.add (i32.const 48) (i32.wrap_i64 (i64.rem_s (local.get $m) (i64.const 10)))))",
  "      (local.set $m (i64.div_s (local.get $m) (i64.const 10)))",
  "      (local.set $i (i32.sub (local.get $i) (i32.const 1)))",
  "      (br_if $fd (i64.eq (local.get $m) (i64.const 0)))",
  "      (br $fl)))",
  "    (if (local.get $neg) (then (array.set $u8arr (local.get $buf) (i32.const 0) (i32.const 45))))",
  "    (struct.new $str (local.get $len) (local.get $buf)))",
]

-- ── W8 stderr byte-write seam (§6 — ePutStr/ePutStrLn) ───────────────────────
-- A second host import for stderr, parallel to `mdk_write_byte`. Emitted when an
-- ePut/panic body needs the stderr runtime or a coded trap needs the byte writer.
-- The native oracle
-- (`mdk_eputstr`) writes a String's UTF-8 bytes to fd 2; the JS runner accumulates
-- these into a separate buffer it prints on `process.stderr`; focused gates assert
-- stderr directly.
export
stderrByteImportLines : List String
stderrByteImportLines = [
  "  (import \"env\" \"mdk_write_err_byte\" (func $mdk_write_err_byte (param i32)))",
]

{- | The DECIMAL half of the coded-trap stderr seam (#1787): render an i64 in
   decimal straight to stderr, no `$str` and no data segment, so a numbered trap
   works in scalar AND ref mode exactly as the fixed-text one does.  Peer of
   `$mdk_write_digits`/`$mdk_print_int` (the stdout pair in `ioRuntimeLines`),
   minus their trailing newline -- a trap line supplies its own.

   Gated on `trapIntNeeded`, which is set by emitting a numbered trap -- NOT by
   reaching one at runtime.  In the TYPED corpus (no prelude) that means a module
   without a numbered trap does not carry these two functions.  In the MODULES
   corpus it is effectively always set, because the prelude's `Index`/`IndexMut`
   impls are emitted whether or not the program indexes anything; ~15 lines of
   WAT.  Measure before assuming otherwise. -}
export
trapIntRuntimeLines : List String
trapIntRuntimeLines = [
  "  ;; -- #1787 numbered-trap decimal runtime (stderr, no newline) --",
  "  ;; write the decimal digits of a NON-NEGATIVE i64 (most-significant first).",
  "  (func $mdk_write_err_digits (param $n i64)",
  "    (if (i64.ge_s (local.get $n) (i64.const 10))",
  "      (then (call $mdk_write_err_digits (i64.div_s (local.get $n) (i64.const 10)))))",
  "    (call $mdk_write_err_byte", "      (i32.add (i32.const 48)",
  "        (i32.wrap_i64 (i64.rem_s (local.get $n) (i64.const 10))))))",
  "  ;; render an i64 in decimal to stderr, sign included, NO trailing newline.",
  "  (func $mdk_write_err_int (param $n i64)",
  "    (if (i64.lt_s (local.get $n) (i64.const 0))", "      (then",
  "        (call $mdk_write_err_byte (i32.const 45))",
  "        (call $mdk_write_err_digits (i64.sub (i64.const 0) (local.get $n))))",
  "      (else (call $mdk_write_err_digits (local.get $n)))))"
]

{- | The located half of the coded-trap stderr seam.  A located trap writes
   `<file>:<line>:<col>: ` before its own line, from one packed i64,
   `(file + 1) << 44 | line << 20 | col`, the word the native backend packs;
   0 writes nothing.  `files` holds each numbered file's path as UTF-8 bytes, in
   number order, so a program pays for each path once and a trap for one i64.
   `nonexh` adds the whole non-exhaustive-match trap as one helper, which is
   what every located match miss calls.  Needs `trapIntRuntimeLines`. -}
export
siteRuntimeLines : List (List Int) -> Bool -> List String
siteRuntimeLines files nonexh =
  [
      "  ;; -- located traps: `<file>:<line>:<col>: ` ahead of a trap line --",
      "  (func $mdk_write_err_loc (param $s i64)",
      "    (local $f i32)",
      "    (if (i64.ne (local.get $s) (i64.const 0))",
      "      (then",
      "        (local.set $f (i32.wrap_i64 (i64.shr_u (local.get $s) (i64.const 44))))",
    ]
    ++ flatMap siteFileArmW (zipFilesW files 1)
    ++ [
      "        (call $mdk_write_err_byte (i32.const 58))",
      "        (call $mdk_write_err_int (i64.and (i64.shr_u (local.get $s) (i64.const 20)) (i64.const 16777215)))",
      "        (call $mdk_write_err_byte (i32.const 58))",
      "        (call $mdk_write_err_int (i64.and (local.get $s) (i64.const 1048575)))",
      "        (call $mdk_write_err_byte (i32.const 58))",
      "        (call $mdk_write_err_byte (i32.const 32))))",
      "  )",
    ]
    ++ (if nonexh then
      [
          "  (func $mdk_trap_nonexh (param $s i64)",
          "    (call $mdk_write_err_loc (local.get $s))",
        ]
        ++ asciiTrapBytesW
          "runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match\n"
        ++ ["    unreachable)"]
    else
      [])

zipFilesW : List (List Int) -> Int -> List (Int, List Int)
zipFilesW [] _ = []
zipFilesW (f :: fs) n = (n, f) :: zipFilesW fs (n + 1)

siteFileArmW : (Int, List Int) -> List String
siteFileArmW (n, bytes) =
  [
      "        (if (i32.eq (local.get $f) (i32.const \{intToString n}))",
      "          (then",
    ]
    ++ map
      (b =>
        "            (call $mdk_write_err_byte (i32.const \{intToString b}))")
      bytes
    ++ ["          ))"]

{- | Checked `Int` arithmetic and `Int` shifts (#3377), one function per helper
   a program demands.  `used` names them: `add`, `sub`, `mul`, `div`, `neg` for
   `$mdk_int_<name>`, and `left`, `right` for `$mdk_shift_<name>`.  Operands and
   results are raw i64s; ref mode unboxes before and reboxes after.  Every helper
   traps through the stderr byte import and `trapIntRuntimeLines`, which the
   emitter demands along with it (`noteIntRt`, wasm_emit.mdk).

   `Int` is 63-bit, and an operator whose exact result falls outside
   -2^62 .. 2^62 - 1 stops the program with
   `runtime error [E-INT-OVERFLOW]: <a> <op> <b> overflows Int` (a negative
   operand parenthesized; negation prints `-<a>`), the text of native's
   `mdk_int_overflow` (runtime/medaka_rt.c).  Wasm has no overflow flag, so:

   - `+`/`-`: two 63-bit operands never overflow i64, so the i64 result is
     exact, and it is in range iff sign-extending it from bit 62 leaves it
     unchanged.
   - `*`: the i64 product can itself wrap.  It is exact and in range iff it
     fits 63 bits and, for a nonzero `a`, `p / a == b`: a wrapped product
     differs from the true one by a nonzero multiple of 2^64, which truncating
     division by `|a| <= 2^62` cannot hide.  The division cannot engine-trap:
     `p` fits 63 bits by then, so it is not INT64_MIN.
   - `/` (divisor already checked nonzero): 63-bit operands are never INT64_MIN,
     so `i64.div_s` cannot trap, and its quotient leaves the range only at
     intMinBound / -1.
   - negation leaves the range only at intMinBound.

   The shifts define every amount as native's `mdk_shift_left`/`mdk_shift_right`
   do: a negative amount panics (`E-PANIC`, the amount in the message); an amount
   of 63 or more shifts every bit out, where `i64.shl`/`i64.shr_s` alone would
   take it modulo 64; `shiftRight` is arithmetic.  `shiftLeft` never traps: the
   caller's `$mdk_box_int` drops the bits past bit 62. -}
export
intRuntimeLines : List String -> List String
intRuntimeLines used =
  let arith = filterUsedW used ["add", "sub", "mul", "div", "neg"]
  let shifts = filterUsedW used ["left", "right"]
  let core = match arith
    [] => []
    _ => intOverflowLines
  core ++ flatMap checkedIntOpW arith ++ flatMap intShiftW shifts

-- `names` in their own order, keeping those in `used`: the emitted text does not
-- depend on the order the emitter demanded them.
filterUsedW : List String -> List String -> List String
filterUsedW _ [] = []
filterUsedW used (n :: ns) =
  if memberW n used then n :: filterUsedW used ns else filterUsedW used ns

memberW : String -> List String -> Bool
memberW _ [] = False
memberW x (y :: ys) = x == y || memberW x ys

-- the E-INT-OVERFLOW writer every checked operator calls: `$op` is the
-- operator's ASCII byte, or 0 for negation.
intOverflowLines : List String
intOverflowLines =
  [
      "  ;; -- #3377 checked Int arithmetic: E-INT-OVERFLOW instead of a wrap --",
      "  (func $mdk_int_operand (param $v i64)",
      "    (if (i64.lt_s (local.get $v) (i64.const 0))",
      "      (then",
      "        (call $mdk_write_err_byte (i32.const 40))",
      "        (call $mdk_write_err_int (local.get $v))",
      "        (call $mdk_write_err_byte (i32.const 41)))",
      "      (else (call $mdk_write_err_int (local.get $v)))))",
      "  (func $mdk_int_overflow (param $op i32) (param $a i64) (param $b i64) (param $s i64)",
      "    (call $mdk_write_err_loc (local.get $s))",
    ]
    ++ asciiTrapBytesW "runtime error [E-INT-OVERFLOW]: "
    ++ [
      "    (if (i32.eqz (local.get $op))",
      "      (then",
      "        (call $mdk_write_err_byte (i32.const 45))",
      "        (call $mdk_int_operand (local.get $a)))",
      "      (else",
      "        (call $mdk_int_operand (local.get $a))",
      "        (call $mdk_write_err_byte (i32.const 32))",
      "        (call $mdk_write_err_byte (local.get $op))",
      "        (call $mdk_write_err_byte (i32.const 32))",
      "        (call $mdk_int_operand (local.get $b))))",
    ]
    ++ asciiTrapBytesW " overflows Int\n"
    ++ ["        unreachable)"]

-- `$r` does not survive a sign-extend from bit 62: it is outside the Int range.
outOfIntRangeW : String
outOfIntRangeW =
  "(i64.ne (i64.shr_s (i64.shl (local.get $r) (i64.const 1)) (i64.const 1)) (local.get $r))"

-- the call that reports `a <op> b` (op byte `code`) as an overflow.
overflowCallW : String -> String
overflowCallW code =
  "(call $mdk_int_overflow (i32.const \{code}) (local.get $a) (local.get $b) (local.get $s))"

checkedIntOpW : String -> List String
checkedIntOpW "neg" = [
  "  (func $mdk_int_neg (param $a i64) (result i64)",
  "    (local $r i64)",
  "    (local.set $r (i64.sub (i64.const 0) (local.get $a)))",
  "    (if \{outOfIntRangeW}",
  "      (then (call $mdk_int_overflow (i32.const 0) (local.get $a) (i64.const 0) (i64.const 0))))",
  "    (local.get $r))",
]
checkedIntOpW "mul" = [
  "  (func $mdk_int_mul (param $a i64) (param $b i64) (param $s i64) (result i64)",
  "    (local $r i64)",
  "    (local.set $r (i64.mul (local.get $a) (local.get $b)))",
  "    (if \{outOfIntRangeW} (then \{overflowCallW "42"}))",
  "    (if (i64.ne (local.get $a) (i64.const 0))",
  "      (then",
  "        (if (i64.ne (i64.div_s (local.get $r) (local.get $a)) (local.get $b))",
  "          (then \{overflowCallW "42"}))))",
  "    (local.get $r))",
]
checkedIntOpW "add" = checkedBinOpLinesW "add" "i64.add" "43"
checkedIntOpW "sub" = checkedBinOpLinesW "sub" "i64.sub" "45"
checkedIntOpW "div" = checkedBinOpLinesW "div" "i64.div_s" "47"
checkedIntOpW op = panic ("wasm: no checked Int operator '" ++ op ++ "'")

-- a checked operator whose i64 instruction is exact on 63-bit operands, so the
-- range test on its result is the whole check.
checkedBinOpLinesW : String -> String -> String -> List String
checkedBinOpLinesW name instr code = [
  "  (func $mdk_int_\{name} (param $a i64) (param $b i64) (param $s i64) (result i64)",
  "    (local $r i64)",
  "    (local.set $r (\{instr} (local.get $a) (local.get $b)))",
  "    (if \{outOfIntRangeW} (then \{overflowCallW code}))",
  "    (local.get $r))",
]

intShiftW : String -> List String
intShiftW "left" =
  intShiftHeadW "left" "shiftLeft"
    ++ [
      "    (select (i64.shl (local.get $x) (local.get $k)) (i64.const 0)",
      "      (i64.lt_s (local.get $k) (i64.const 63))))",
    ]
intShiftW "right" =
  intShiftHeadW "right" "shiftRight"
    ++ [
      "    (i64.shr_s (local.get $x)",
      "      (select (local.get $k) (i64.const 63) (i64.lt_s (local.get $k) (i64.const 63)))))",
    ]
intShiftW dir = panic ("wasm: no Int shift '" ++ dir ++ "'")

-- a shift helper's signature and its negative-amount panic.
intShiftHeadW : String -> String -> List String
intShiftHeadW dir name =
  [
      "  (func $mdk_shift_\{dir} (param $x i64) (param $k i64) (result i64)",
      "    (if (i64.lt_s (local.get $k) (i64.const 0))",
      "      (then",
    ]
    ++ asciiTrapBytesW "runtime error [E-PANIC]: \{name}: negative shift "
    ++ [
      "        (call $mdk_write_err_int (local.get $k))",
      "        (call $mdk_write_err_byte (i32.const 10))",
      "        unreachable))",
    ]

-- the stderr byte-write runtime ($str-dependent).  Peer of $mdk_print_str/_strln but
-- routing each byte through $mdk_write_err_byte (matches medaka_rt.c mdk_eputstr /
-- mdk_eputstrln: payload bytes verbatim, optional trailing '\n').
export
stderrRuntimeLines : List String
stderrRuntimeLines = [
  "  ;; ── W8 stderr byte-write runtime (ePutStr / ePutStrLn) ──",
  "  (func $mdk_eprint_str (param $s (ref $str))",
  "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_write_err_byte (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))",
  "  (func $mdk_eprint_strln (param $s (ref $str))",
  "    (call $mdk_eprint_str (local.get $s))",
  "    (call $mdk_write_err_byte (i32.const 10)))",
]

-- ── W8 pure-WasmGC string LEAF ops (RUNTIME-DESIGN §5 LEAF / WASMGC-DESIGN §6) ──
-- All operate over the §3.3 `$str` ($cp_count i32 + $bytes (ref $u8arr)) rep and are
-- byte-identical to medaka_rt.c.  Emitted only when the program uses strings
-- (`useStrRef`) AND a leaf string op (`useStrLeafRef`).
--   $mdk_str_append   — binary `++`: concat two $str, recompute cp_count (== sum of
--                       both cp_counts, since UTF-8 concat preserves codepoints).
--   $mdk_char_to_str  — encode one codepoint (i32) to a fresh 1..4-byte $str
--                       (mdk_utf8_encode + cp_count 1).
--   $mdk_str_slice    — codepoint-indexed [lo,hi) slice, clamped; an all-ASCII
--                       string indexes bytes directly, else a UTF-8 byte-walk
--                       (mdk_string_slice).
--   $mdk_str_upper /
--   $mdk_str_lower    — ASCII-only case map over BYTES (mdk_string_to_upper/lower).
--   $mdk_cp_count     — count codepoints in a byte range (UTF-8 non-continuation bytes).
export
strLeafRuntimeLines : List String
strLeafRuntimeLines = [
  "  ;; ── W8 string LEAF ops (byte-identical to medaka_rt.c) ──",
  "  ;; count UTF-8 codepoints in a $u8arr over [0,n): every non-continuation byte.",
  "  (func $mdk_cp_count (param $b (ref $u8arr)) (param $n i32) (result i32)",
  "    (local $i i32) (local $c i32) (local $byte i32)",
  "    (local.set $i (i32.const 0)) (local.set $c (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $byte (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      ;; a continuation byte has top bits 10xxxxxx, i.e. (byte & 0xC0) == 0x80.",
  "      (if (i32.ne (i32.and (local.get $byte) (i32.const 192)) (i32.const 128))",
  "        (then (local.set $c (i32.add (local.get $c) (i32.const 1)))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (local.get $c))",
  "  ;; codepoint index `cpi` -> byte offset into a $u8arr of byte length `n`.",
  "  (func $mdk_byte_off (param $b (ref $u8arr)) (param $n i32) (param $cpi i32) (result i32)",
  "    (local $bo i32) (local $c i32)",
  "    (local.set $bo (i32.const 0)) (local.set $c (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $bo) (local.get $n)))",
  "      (br_if $d (i32.ge_s (local.get $c) (local.get $cpi)))",
  "      (local.set $bo (i32.add (local.get $bo) (i32.const 1)))",
  "      (block $sd (loop $sl",
  "        (br_if $sd (i32.ge_s (local.get $bo) (local.get $n)))",
  "        (br_if $sd (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (local.get $bo)) (i32.const 192)) (i32.const 128)))",
  "        (local.set $bo (i32.add (local.get $bo) (i32.const 1))) (br $sl)))",
  "      (local.set $c (i32.add (local.get $c) (i32.const 1))) (br $l)))",
  "    (local.get $bo))",
  "  ;; binary string concat (`++`).  cp_count(a++b) == cp_count(a)+cp_count(b).",
  "  (func $mdk_str_append (param $a (ref $str)) (param $b (ref $str)) (result (ref $str))",
  "    (local $ab (ref $u8arr)) (local $bb (ref $u8arr)) (local $al i32) (local $bl i32)",
  "    (local $buf (ref $u8arr)) (local $cpc i32)",
  "    (local.set $ab (struct.get $str $bytes (local.get $a)))",
  "    (local.set $bb (struct.get $str $bytes (local.get $b)))",
  "    (local.set $al (array.len (local.get $ab)))",
  "    (local.set $bl (array.len (local.get $bb)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (i32.add (local.get $al) (local.get $bl))))",
  "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $ab) (i32.const 0) (local.get $al))",
  "    (array.copy $u8arr $u8arr (local.get $buf) (local.get $al) (local.get $bb) (i32.const 0) (local.get $bl))",
  "    (local.set $cpc (i32.add (struct.get $str $cp_count (local.get $a)) (struct.get $str $cp_count (local.get $b))))",
  "    (struct.new $str (local.get $cpc) (local.get $buf)))",
  "  ;; encode one Unicode codepoint to a fresh $str (1..4 UTF-8 bytes, cp_count 1).",
  "  (func $mdk_char_to_str (param $cp i32) (result (ref $str))",
  "    (local $buf (ref $u8arr))",
  "    (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 128))",
  "      (then",
  "        (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 1)))",
  "        (array.set $u8arr (local.get $buf) (i32.const 0) (local.get $cp))",
  "        (struct.new $str (i32.const 1) (local.get $buf)))",
  "      (else (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 2048))",
  "        (then",
  "          (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 2)))",
  "          (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))",
  "          (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))",
  "          (struct.new $str (i32.const 1) (local.get $buf)))",
  "        (else (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 65536))",
  "          (then",
  "            (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 3)))",
  "            (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))",
  "            (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))",
  "            (array.set $u8arr (local.get $buf) (i32.const 2) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))",
  "            (struct.new $str (i32.const 1) (local.get $buf)))",
  "          (else",
  "            (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 4)))",
  "            (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))",
  "            (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))",
  "            (array.set $u8arr (local.get $buf) (i32.const 2) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))",
  "            (array.set $u8arr (local.get $buf) (i32.const 3) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))",
  "            (struct.new $str (i32.const 1) (local.get $buf)))",
  "          )", "        )", "      )", "    )", "  ))",
  "  ;; codepoint-indexed [lo,hi) slice, clamped to [0,cp_count].",
  "  (func $mdk_str_slice (param $lo i32) (param $hi i32) (param $s (ref $str)) (result (ref $str))",
  "    (local $b (ref $u8arr)) (local $n i32) (local $cpc i32) (local $blo i32) (local $bhi i32)",
  "    (local $len i32) (local $buf (ref $u8arr))",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $cpc (struct.get $str $cp_count (local.get $s)))",
  "    (if (i32.lt_s (local.get $lo) (i32.const 0)) (then (local.set $lo (i32.const 0)))",
  "      (else (if (i32.gt_s (local.get $lo) (local.get $cpc)) (then (local.set $lo (local.get $cpc))))))",
  "    (if (i32.lt_s (local.get $hi) (local.get $lo)) (then (local.set $hi (local.get $lo)))",
  "      (else (if (i32.gt_s (local.get $hi) (local.get $cpc)) (then (local.set $hi (local.get $cpc))))))",
  "    (if (i32.eq (local.get $cpc) (local.get $n))",
  "      (then (local.set $blo (local.get $lo)) (local.set $bhi (local.get $hi)))",
  "      (else",
  "        (local.set $blo (call $mdk_byte_off (local.get $b) (local.get $n) (local.get $lo)))",
  "        (local.set $bhi (call $mdk_byte_off (local.get $b) (local.get $n) (local.get $hi)))))",
  "    (local.set $len (i32.sub (local.get $bhi) (local.get $blo)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $len)))",
  "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $b) (local.get $blo) (local.get $len))",
  "    (struct.new $str (i32.sub (local.get $hi) (local.get $lo)) (local.get $buf)))",
  "  ;; ASCII upper/lower over BYTES (non-ASCII bytes pass through unchanged).",
  "  (func $mdk_str_upper (param $s (ref $str)) (result (ref $str))",
  "    (local $b (ref $u8arr)) (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $c i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (local.set $i (i32.const 0))", "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (if (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))",
  "        (then (local.set $c (i32.sub (local.get $c) (i32.const 32)))))",
  "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $c))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))",
  "  (func $mdk_str_lower (param $s (ref $str)) (result (ref $str))",
  "    (local $b (ref $u8arr)) (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $c i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (local.set $i (i32.const 0))", "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (if (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))",
  "        (then (local.set $c (i32.add (local.get $c) (i32.const 32)))))",
  "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $c))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))",
  "  ;; ── W9 debug-literal quoting ──",
  "  ;; Map ONE source byte to its escaped form, appending into $buf at $bo; returns the",
  "  ;; next write offset.  Specials: \" / ' (whichever == $q) / \\ / \\n / \\t / \\r / NUL.",
  "  ;; All escapes are <backslash><ascii>, so 2 bytes; everything else copies verbatim.",
  "  (func $mdk_dbg_esc_byte (param $buf (ref $u8arr)) (param $bo i32) (param $c i32) (param $q i32) (result i32)",
  "    (local $r i32)",
  "    ;; $r = the char AFTER the backslash for an escaped byte, else -1 (copy verbatim).",
  "    (local.set $r (i32.const -1))",
  "    (if (i32.eq (local.get $c) (local.get $q)) (then (local.set $r (local.get $q))))",
  "    (if (i32.eq (local.get $c) (i32.const 92)) (then (local.set $r (i32.const 92))))",
  "    (if (i32.eq (local.get $c) (i32.const 10)) (then (local.set $r (i32.const 110))))",
  "    (if (i32.eq (local.get $c) (i32.const 9))  (then (local.set $r (i32.const 116))))",
  "    (if (i32.eq (local.get $c) (i32.const 13)) (then (local.set $r (i32.const 114))))",
  "    (if (i32.eq (local.get $c) (i32.const 0))  (then (local.set $r (i32.const 48))))",
  "    (if (result i32) (i32.eq (local.get $r) (i32.const -1))", "      (then",
  "        (array.set $u8arr (local.get $buf) (local.get $bo) (local.get $c))",
  "        (i32.add (local.get $bo) (i32.const 1)))", "      (else",
  "        (array.set $u8arr (local.get $buf) (local.get $bo) (i32.const 92))",
  "        (array.set $u8arr (local.get $buf) (i32.add (local.get $bo) (i32.const 1)) (local.get $r))",
  "        (i32.add (local.get $bo) (i32.const 2)))))",
  "  ;; Quote+escape a $str with quote byte $q ('\"' for String, ''' for Char).  Two-pass:",
  "  ;; count escaped output bytes, alloc exact, fill; cp_count via $mdk_cp_count.",
  "  (func $mdk_dbg_quote (param $s (ref $str)) (param $q i32) (result (ref $str))",
  "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $c i32)",
  "    (local $out i32) (local $buf (ref $u8arr)) (local $bo i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    ;; pass 1: total output bytes = 2 quotes + per-byte (2 if escaped else 1).",
  "    (local.set $out (i32.const 2)) (local.set $i (i32.const 0))",
  "    (block $d1 (loop $l1",
  "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (if (i32.or (i32.or (i32.or (i32.eq (local.get $c) (local.get $q)) (i32.eq (local.get $c) (i32.const 92)))",
  "                          (i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 9))))",
  "                  (i32.or (i32.eq (local.get $c) (i32.const 13)) (i32.eq (local.get $c) (i32.const 0))))",
  "        (then (local.set $out (i32.add (local.get $out) (i32.const 2))))",
  "        (else (local.set $out (i32.add (local.get $out) (i32.const 1)))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $out)))",
  "    ;; pass 2: opening quote, escaped bytes, closing quote.",
  "    (array.set $u8arr (local.get $buf) (i32.const 0) (local.get $q))",
  "    (local.set $bo (i32.const 1)) (local.set $i (i32.const 0))",
  "    (block $d2 (loop $l2",
  "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $bo (call $mdk_dbg_esc_byte (local.get $buf) (local.get $bo) (local.get $c) (local.get $q)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))",
  "    (array.set $u8arr (local.get $buf) (local.get $bo) (local.get $q))",
  "    (struct.new $str (call $mdk_cp_count (local.get $buf) (local.get $out)) (local.get $buf)))",
  "  ;; debugStringLit : $str -> $str, surround with double-quotes (q = 34).",
  "  (func $mdk_debug_string_lit (param $s (ref $str)) (result (ref $str))",
  "    (call $mdk_dbg_quote (local.get $s) (i32.const 34)))",
  "  ;; debugCharLit : Char (i31 codepoint) -> $str, surround with single-quotes (q = 39).",
  "  (func $mdk_debug_char_lit (param $cp i32) (result (ref $str))",
  "    (call $mdk_dbg_quote (call $mdk_char_to_str (local.get $cp)) (i32.const 39)))",
  "  ;; -- W8c byte-level prefix/suffix (byte-identical to medaka_rt.c) --",
  "  ;; $mdk_bytes_match_at: does $nb occur in $hb at byte offset $off (caller bounds it).",
  "  (func $mdk_bytes_match_at (param $nb (ref $u8arr)) (param $hb (ref $u8arr)) (param $off i32) (result i32)",
  "    (local $j i32)", "    (block $done (loop $cmp",
  "      (br_if $done (i32.ge_s (local.get $j) (array.len (local.get $nb))))",
  "      (if (i32.ne (array.get_u $u8arr (local.get $hb) (i32.add (local.get $off) (local.get $j)))",
  "                  (array.get_u $u8arr (local.get $nb) (local.get $j)))",
  "        (then (return (i32.const 0))))",
  "      (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $cmp)))",
  "    (i32.const 1))",
  "  (func $mdk_str_starts_with (param $p (ref $str)) (param $s (ref $str)) (result i32)",
  "    (local $pb (ref $u8arr)) (local $sb (ref $u8arr))",
  "    (local.set $pb (struct.get $str $bytes (local.get $p)))",
  "    (local.set $sb (struct.get $str $bytes (local.get $s)))",
  "    (if (i32.gt_s (array.len (local.get $pb)) (array.len (local.get $sb)))",
  "      (then (return (i32.const 0))))",
  "    (call $mdk_bytes_match_at (local.get $pb) (local.get $sb) (i32.const 0)))",
  "  (func $mdk_str_ends_with (param $p (ref $str)) (param $s (ref $str)) (result i32)",
  "    (local $pb (ref $u8arr)) (local $sb (ref $u8arr))",
  "    (local.set $pb (struct.get $str $bytes (local.get $p)))",
  "    (local.set $sb (struct.get $str $bytes (local.get $s)))",
  "    (if (i32.gt_s (array.len (local.get $pb)) (array.len (local.get $sb)))",
  "      (then (return (i32.const 0))))",
  "    (call $mdk_bytes_match_at (local.get $pb) (local.get $sb)",
  "      (i32.sub (array.len (local.get $sb)) (array.len (local.get $pb)))))"
]

-- ── W8 stringConcat (List String -> String) ──────────────────────────────────
-- Walks the W7 List rep ($T_List root with i32 tag 0=Nil; $C_Cons = tag,head,tail),
-- summing byte lengths then copying.  cp_count recomputed via $mdk_cp_count.  Emitted
-- only when the program uses BOTH strings AND lists (`useStrLeafRef && useListRef`),
-- so $C_Cons is in scope.  A Nil is an i31 immediate (ordinal 0); a Cons is a
-- $C_Cons struct.  We detect Nil by `ref.test (ref $C_Cons)` being false.
export
strConcatRuntimeLines : List String
strConcatRuntimeLines = [
  "  ;; ── W8 stringConcat (List String) — walk the W7 cons list ──",
  "  (func $mdk_str_concat (param $list (ref eq)) (result (ref $str))",
  "    (local $w (ref eq)) (local $cell (ref $C_Cons)) (local $s (ref $str))",
  "    (local $total i32) (local $cpc i32) (local $off i32) (local $bl i32)",
  "    (local $buf (ref $u8arr)) (local $sb (ref $u8arr))",
  "    ;; pass 1: total byte length + total codepoints.",
  "    (local.set $total (i32.const 0)) (local.set $cpc (i32.const 0))",
  "    (local.set $w (local.get $list))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))",
  "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))",
  "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))",
  "      (local.set $total (i32.add (local.get $total) (array.len (struct.get $str $bytes (local.get $s)))))",
  "      (local.set $cpc (i32.add (local.get $cpc) (struct.get $str $cp_count (local.get $s))))",
  "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l)))",
  "    ;; pass 2: copy each segment's bytes into a flat buffer.",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))",
  "    (local.set $off (i32.const 0))",
  "    (local.set $w (local.get $list))",
  "    (block $d2 (loop $l2",
  "      (br_if $d2 (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))",
  "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))",
  "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))",
  "      (local.set $sb (struct.get $str $bytes (local.get $s)))",
  "      (local.set $bl (array.len (local.get $sb)))",
  "      (array.copy $u8arr $u8arr (local.get $buf) (local.get $off) (local.get $sb) (i32.const 0) (local.get $bl))",
  "      (local.set $off (i32.add (local.get $off) (local.get $bl)))",
  "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l2)))",
  "    (struct.new $str (local.get $cpc) (local.get $buf)))",
]

-- ── W8d stringToInt (String -> Option Int) ───────────────────────────────────
-- The wasm mirror of mdk_string_to_int (medaka_rt.c): i64 magnitude kept non-positive,
-- each digit checked against the limit before the multiply and the add.  Int results
-- go through $mdk_box_int (i31 or $boxint).  Emitted only when a program demands
-- stringToInt (`useStrToInt`).
export
strToIntRuntimeLines : List String
strToIntRuntimeLines = [
  "  ;; ── W8d stringToInt (decimal, optional sign; None on any other byte) ──",
  "  (func $mdk_str_to_int (param $s (ref $str)) (result (ref eq))",
  "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $c i32)",
  "    (local $neg i32) (local $seen i32) (local $acc i64) (local $d i64)",
  "    (local $limit i64) (local $acc2 i64)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (if (i32.eqz (local.get $n)) (then (return (ref.i31 (i32.const 1)))))",
  "    (local.set $c (array.get_u $u8arr (local.get $b) (i32.const 0)))",
  "    (if (i32.eq (local.get $c) (i32.const 45))",
  "      (then (local.set $neg (i32.const 1)) (local.set $i (i32.const 1)))",
  "      (else (if (i32.eq (local.get $c) (i32.const 43)) (then (local.set $i (i32.const 1))))))",
  "    (block $done (loop $step",
  "      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (if (i32.or (i32.lt_u (local.get $c) (i32.const 48)) (i32.gt_u (local.get $c) (i32.const 57)))",
  "        (then (return (ref.i31 (i32.const 1)))))",
  "      (local.set $d (i64.extend_i32_u (i32.sub (local.get $c) (i32.const 48))))",
  "      (local.set $limit", "        (if (result i64) (local.get $neg)",
  "          (then (i64.const -4611686018427387904))",
  "          (else (i64.const -4611686018427387903))))",
  "      (if (i64.lt_s (local.get $acc) (i64.div_s (local.get $limit) (i64.const 10)))",
  "        (then (return (ref.i31 (i32.const 1)))))",
  "      (local.set $acc2 (i64.mul (local.get $acc) (i64.const 10)))",
  "      (if (i64.lt_s (local.get $acc2) (i64.add (local.get $limit) (local.get $d)))",
  "        (then (return (ref.i31 (i32.const 1)))))",
  "      (local.set $acc (i64.sub (local.get $acc2) (local.get $d)))",
  "      (local.set $seen (i32.const 1))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1)))",
  "      (br $step)))",
  "    (if (i32.eqz (local.get $seen)) (then (return (ref.i31 (i32.const 1)))))",
  "    (struct.new $C_Some (i32.const 0)", "      (call $mdk_box_int",
  "        (if (result i64) (local.get $neg)",
  "          (then (local.get $acc))",
  "          (else (i64.sub (i64.const 0) (local.get $acc)))))))"
]

-- ── W8d stringReverse (String -> String) ─────────────────────────────────────
-- Copies the UTF-8 bytes from the end: each codepoint's lead byte is found by
-- skipping continuation bytes (0b10xxxxxx), and the whole sequence is copied.  The
-- codepoint count is the operand's, unchanged.  Emitted when `useStrReverse`.
export
strReverseRuntimeLines : List String
strReverseRuntimeLines = [
  "  ;; ── W8d stringReverse — copy each UTF-8 sequence whole, last first ──",
  "  (func $mdk_str_reverse (param $s (ref $str)) (result (ref $str))",
  "    (local $b (ref $u8arr)) (local $buf (ref $u8arr)) (local $n i32)",
  "    (local $end i32) (local $start i32) (local $off i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (local.set $end (local.get $n))", "    (block $done (loop $step",
  "      (br_if $done (i32.eqz (local.get $end)))",
  "      (local.set $start (i32.sub (local.get $end) (i32.const 1)))",
  "      (block $lead (loop $back",
  "        (br_if $lead (i32.eqz (local.get $start)))",
  "        (br_if $lead (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (local.get $start)) (i32.const 192)) (i32.const 128)))",
  "        (local.set $start (i32.sub (local.get $start) (i32.const 1)))",
  "        (br $back)))",
  "      (array.copy $u8arr $u8arr (local.get $buf) (local.get $off)",
  "        (local.get $b) (local.get $start) (i32.sub (local.get $end) (local.get $start)))",
  "      (local.set $off (i32.add (local.get $off) (i32.sub (local.get $end) (local.get $start))))",
  "      (local.set $end (local.get $start))", "      (br $step)))",
  "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))"
]

-- ── W8d stringJoin (String -> List String -> String) ─────────────────────────
-- The wasm mirror of mdk_string_join: pass one sums byte and codepoint counts over the
-- W7 cons list (plus the separator between each adjacent pair), pass two copies.  A
-- Nil is an i31 immediate, so a Cons is detected by `ref.test (ref $C_Cons)`.  Emitted
-- when `useStrJoin`; the catalog row also demands the list (UseList), so $C_Cons is in
-- scope.
export
strJoinRuntimeLines : List String
strJoinRuntimeLines = [
  "  ;; ── W8d stringJoin — two passes over the cons list, separator between pieces ──",
  "  (func $mdk_str_join (param $sep (ref $str)) (param $list (ref eq)) (result (ref $str))",
  "    (local $w (ref eq)) (local $cell (ref $C_Cons)) (local $s (ref $str))",
  "    (local $sepb (ref $u8arr)) (local $sb (ref $u8arr)) (local $buf (ref $u8arr))",
  "    (local $total i32) (local $cpc i32) (local $parts i32) (local $off i32)",
  "    (local $bl i32) (local $first i32)",
  "    (local.set $sepb (struct.get $str $bytes (local.get $sep)))",
  "    (local.set $w (local.get $list))", "    (block $d (loop $l",
  "      (br_if $d (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))",
  "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))",
  "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))",
  "      (local.set $total (i32.add (local.get $total) (array.len (struct.get $str $bytes (local.get $s)))))",
  "      (local.set $cpc (i32.add (local.get $cpc) (struct.get $str $cp_count (local.get $s))))",
  "      (local.set $parts (i32.add (local.get $parts) (i32.const 1)))",
  "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l)))",
  "    (if (i32.gt_s (local.get $parts) (i32.const 1))", "      (then",
  "        (local.set $total (i32.add (local.get $total)",
  "          (i32.mul (i32.sub (local.get $parts) (i32.const 1)) (array.len (local.get $sepb)))))",
  "        (local.set $cpc (i32.add (local.get $cpc)",
  "          (i32.mul (i32.sub (local.get $parts) (i32.const 1)) (struct.get $str $cp_count (local.get $sep)))))))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))",
  "    (local.set $first (i32.const 1))",
  "    (local.set $w (local.get $list))", "    (block $d2 (loop $l2",
  "      (br_if $d2 (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))",
  "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))",
  "      (if (i32.eqz (local.get $first))", "        (then",
  "          (array.copy $u8arr $u8arr (local.get $buf) (local.get $off)",
  "            (local.get $sepb) (i32.const 0) (array.len (local.get $sepb)))",
  "          (local.set $off (i32.add (local.get $off) (array.len (local.get $sepb))))))",
  "      (local.set $first (i32.const 0))",
  "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))",
  "      (local.set $sb (struct.get $str $bytes (local.get $s)))",
  "      (local.set $bl (array.len (local.get $sb)))",
  "      (array.copy $u8arr $u8arr (local.get $buf) (local.get $off) (local.get $sb) (i32.const 0) (local.get $bl))",
  "      (local.set $off (i32.add (local.get $off) (local.get $bl)))",
  "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l2)))",
  "    (struct.new $str (local.get $cpc) (local.get $buf)))"
]

-- ── W13 runtime-dispatched `++` (append over String OR List) ─────────────────
-- Core IR is type-erased: a `CBinPrim "++"` carries no operand type, so the
-- emitter cannot statically tell a String `++` from a List `++` (mirrors the LLVM
-- backend's @mdk_append).  $mdk_append inspects the LEFT operand's runtime shape:
--   • a $str struct      → binary string concat ($mdk_str_append),
--   • a list (i31 Nil or $C_Cons) → rebuild the left spine onto `b` (list append).
-- List append walks the left list into a fixed array, then conses back-to-front
-- onto `b` so cell identity/order matches the W7 cons rep.  Gated by useStrLeafRef
-- && useListRef (both demanded by `++` in the plan's walk, `emit_plan.noteBinop`), so $str + $C_Cons are in scope.
export
appendRuntimeLines : List String
appendRuntimeLines = [
  "  ;; ── W13 runtime-dispatched `++` (String concat OR List append) ──",
  "  ;; List append is ITERATIVE (destination-passing over the mut $C_Cons tail),",
  "  ;; mirroring the native mdk_list_append: walk `a` head-first, struct.new each",
  "  ;; result cell with a placeholder i31 tail, struct.set it into the previous",
  "  ;; cell's mut tail, and after the loop point the final tail at `b`.  O(1) extra",
  "  ;; space, no self-recursion → no wasm-stack growth proportional to length(a).",
  "  (func $mdk_append (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
  "    (local $cell (ref $C_Cons))", "    (local $result (ref eq))",
  "    (local $dest (ref $C_Cons))", "    (local $new (ref $C_Cons))",
  "    ;; String `++`: left is a $str struct → byte concat.",
  "    (if (ref.test (ref $str) (local.get $a))",
  "      (then (return (call $mdk_str_append (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b))))))",
  "    ;; List `++`: a Nil (non-$C_Cons) left → b unchanged.",
  "    (if (i32.eqz (ref.test (ref $C_Cons) (local.get $a)))",
  "      (then (return (local.get $b))))",
  "    ;; First cell: copy head(a), placeholder i31 tail (overwritten before any read).",
  "    (local.set $cell (ref.cast (ref $C_Cons) (local.get $a)))",
  "    (local.set $dest (struct.new $C_Cons (i32.const 0)",
  "      (struct.get $C_Cons 1 (local.get $cell)) (ref.i31 (i32.const 0))))",
  "    (local.set $result (local.get $dest))",
  "    ;; Walk the rest of `a`, appending a fresh cell into the previous mut tail.",
  "    (block $done", "      (loop $l",
  "        ;; If tail(cell) is not a Cons (i.e. Nil), we are done.",
  "        (br_if $done (i32.eqz (ref.test (ref $C_Cons)",
  "          (struct.get $C_Cons 2 (local.get $cell)))))",
  "        (local.set $cell (ref.cast (ref $C_Cons)",
  "          (struct.get $C_Cons 2 (local.get $cell))))",
  "        (local.set $new (struct.new $C_Cons (i32.const 0)",
  "          (struct.get $C_Cons 1 (local.get $cell)) (ref.i31 (i32.const 0))))",
  "        (struct.set $C_Cons 2 (local.get $dest) (local.get $new))",
  "        (local.set $dest (local.get $new))", "        (br $l)))",
  "    ;; Final tail → b (sharing it, not copying).",
  "    (struct.set $C_Cons 2 (local.get $dest) (local.get $b))",
  "    (local.get $result))"
]

-- ── layer-9 runtime-shape-dispatched value comparison (`==`/`/=`/`<`/`>`/…) ──────
-- Core IR is type-erased: a ref-mode `CBinPrim "=="` carries no operand type, so the
-- emitter cannot statically tell a `String == String` (boxed `$str` struct) from an
-- `Int == Int` (i31 immediate).  Lowering `==` unconditionally as an
-- i31 compare (`ref.cast (ref i31)` + `i31.get_s`) traps `illegal cast` on a String
-- operand at `ref.cast (ref i31)` (e.g. parser's `coalesceStep`'s `n == name`).
-- Mirrors the LLVM backend's @mdk_value_eq / @mdk_value_cmp_raw (and the W13
-- $mdk_append precedent): discriminate on the operand's RUNTIME shape.
--   $mdk_value_eq(a,b)  : both $str → byte-equal; else `ref.eq` (i31/struct identity,
--     correct for Int/Bool/Char/Unit immediates).  Returns an i31 Bool (0/1).
--   $mdk_value_cmp(a,b) : both $str → $mdk_str_compare → -1/0/1; else compare the i31
--     signed values.  Returns a PLAIN i32 -1/0/1.  Gated by useStrRef (forces `$str`
--     in scope); only reached in ref-mode where the i31 fast path was unsafe.
--     ⚠️ #305: a 3-way cannot express NaN's unorderedness, so the emitter does NOT
--     compare this against 0 for an ordering op — it calls $mdk_value_lt/le/gt/ge,
--     which answer $float directly and use this only for the $str/int shapes.
-- ── 64-bit arms of the shape-dispatched helpers (INTEGER-TYPES-DESIGN §5.1) ───
-- A `U64` is a `$u64` cell (an i64 payload read unsigned) and an `I64` an `$i64`
-- cell (the same payload read in two's complement): two struct types distinct
-- from each other and from `$boxint` and `$float` in the rec group, so no other
-- arm's `ref.test` accepts one.  Each helper that dispatches on value shape takes
-- a `Wide64W` and splices an arm per type the program uses (`WasmEmit.useU64` /
-- `useI64`, which are also what declare the types), so a program without either
-- emits the same text.  The arm tests the LEFT operand, as the `$float` arms do:
-- both operands of a well-typed binop share a shape.
public export data Wide64W = Wide64W Bool Bool

-- the arms for the types in use, `$u64`'s first.
wideArmsW : Wide64W -> (String -> List String) -> List String
wideArmsW (Wide64W u64 i64) arm =
  (if u64 then arm "$u64" else []) ++ (if i64 then arm "$i64" else [])

boxed64GetW : String -> String -> String
boxed64GetW ty v =
  "(struct.get \{ty} 0 (ref.cast (ref \{ty}) (local.get \{v})))"

-- `==` for `$mdk_value_eq` / `$mdk_value_eq_num`: the payloads' bit equality.
wideEqArmsW : Wide64W -> List String
wideEqArmsW w = wideArmsW w eqArmW

eqArmW : String -> List String
eqArmW ty = [
  "    (if (ref.test (ref \{ty}) (local.get $a))",
  "      (then (return (ref.i31 (i64.eq \{boxed64GetW ty "$a"} \{boxed64GetW ty "$b"})))))",
]

-- the 3-way for `$mdk_value_cmp` / `$mdk_value_cmp_num`, into their `$ia`/`$ib`
-- i64 locals: unsigned for `$u64`, signed for `$i64`.  The ordering predicates
-- (`$mdk_value_lt`…) reach it through the 3-way, which is exact for an integer.
wideCmpArmsW : Wide64W -> List String
wideCmpArmsW w = wideArmsW w cmpArmW

cmpArmW : String -> List String
cmpArmW ty =
  let sfx = if ty == "$u64" then "u" else "s"
  [
    "    (if (ref.test (ref \{ty}) (local.get $a))",
    "      (then",
    "        (local.set $ia \{boxed64GetW ty "$a"})",
    "        (local.set $ib \{boxed64GetW ty "$b"})",
    "        (if (i64.lt_\{sfx} (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))",
    "        (if (i64.gt_\{sfx} (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))",
    "        (return (i32.const 0))))",
  ]

-- `+`/`-`/`*` for `$mdk_value_add`/`sub`/`mul`: the i64 op wraps modulo 2^64,
-- which is the answer read either way.
wideArithArmsW : Wide64W -> String -> List String
wideArithArmsW w instr = wideArmsW w (ty => arithArmW ty instr)

arithArmW : String -> String -> List String
arithArmW ty instr = [
  "    (if (ref.test (ref \{ty}) (local.get $a))",
  "      (then (return (struct.new \{ty} (\{instr} \{boxed64GetW ty "$a"} \{boxed64GetW ty "$b"})))))",
]

-- `/`/`%` for `$mdk_value_div`/`mod`, with the divisor guard the Int arm uses,
-- into the helper's `$vdr` local.  `uInstr` is the `$u64` operation and `sInstr`
-- the `$i64` one.
wideDivArmsW : Wide64W -> String -> String -> List String -> List String
wideDivArmsW w uInstr sInstr trap =
  wideArmsW w (ty => divArmW ty (if ty == "$u64" then uInstr else sInstr) trap)

divArmW : String -> String -> List String -> List String
divArmW ty instr trap =
  [
      "    (if (ref.test (ref \{ty}) (local.get $a))",
      "      (then",
      "        (local.set $vdr \{boxed64GetW ty "$b"})",
      "        (if (i64.eqz (local.get $vdr)) (then",
    ]
    ++ trap
    ++ [
      "        ))",
      "        (return (struct.new \{ty} (\{instr} \{boxed64GetW ty "$a"} (local.get $vdr))))))",
    ]

-- The one `I64` operation no single instruction covers.  `i64.div_s` traps on
-- `minBound / -1`, whose two's complement answer is `minBound`: a divisor of -1
-- is negation, which wraps there.  `i64.rem_s` is already 0 for that pair.  The
-- divisor is nonzero here: the caller's guard has run.
export
i64RuntimeLines : List String
i64RuntimeLines = [
  "  ;; -- I64 kernel: signed division that wraps at minBound / -1 --",
  "  (func $mdk_i64_div (param $a i64) (param $b i64) (result i64)",
  "    (if (i64.eq (local.get $b) (i64.const -1))",
  "      (then (return (i64.sub (i64.const 0) (local.get $a)))))",
  "    (i64.div_s (local.get $a) (local.get $b)))",
]

-- The `U64` kernels no single instruction covers.  A shift amount is an `Int`;
-- read unsigned, every amount outside 0..63 (a negative one included) gives 0,
-- where `i64.shl`/`i64.shr_u` alone would take it modulo 64.  `$mdk_u64_mulhi` is
-- the high half of the 128-bit product from the four 32x32 partial products,
-- each of which fits an i64: the middle column sums three values below 2^32, so
-- its carry is `mid >> 32`.
export
u64RuntimeLines : List String
u64RuntimeLines = [
  "  ;; -- U64 kernels: range-checked shifts and the high half of the product --",
  "  (func $mdk_u64_shl (param $x i64) (param $k i64) (result i64)",
  "    (select (i64.shl (local.get $x) (local.get $k)) (i64.const 0)",
  "      (i64.lt_u (local.get $k) (i64.const 64))))",
  "  (func $mdk_u64_shr (param $x i64) (param $k i64) (result i64)",
  "    (select (i64.shr_u (local.get $x) (local.get $k)) (i64.const 0)",
  "      (i64.lt_u (local.get $k) (i64.const 64))))",
  "  (func $mdk_u64_mulhi (param $a i64) (param $b i64) (result i64)",
  "    (local $al i64) (local $ah i64) (local $bl i64) (local $bh i64)",
  "    (local $lh i64) (local $hl i64) (local $mid i64)",
  "    (local.set $al (i64.and (local.get $a) (i64.const 0xFFFFFFFF)))",
  "    (local.set $ah (i64.shr_u (local.get $a) (i64.const 32)))",
  "    (local.set $bl (i64.and (local.get $b) (i64.const 0xFFFFFFFF)))",
  "    (local.set $bh (i64.shr_u (local.get $b) (i64.const 32)))",
  "    (local.set $lh (i64.mul (local.get $al) (local.get $bh)))",
  "    (local.set $hl (i64.mul (local.get $ah) (local.get $bl)))",
  "    (local.set $mid (i64.add (i64.add",
  "      (i64.shr_u (i64.mul (local.get $al) (local.get $bl)) (i64.const 32))",
  "      (i64.and (local.get $lh) (i64.const 0xFFFFFFFF)))",
  "      (i64.and (local.get $hl) (i64.const 0xFFFFFFFF))))",
  "    (i64.add (i64.add (i64.add",
  "      (i64.mul (local.get $ah) (local.get $bh))",
  "      (i64.shr_u (local.get $lh) (i64.const 32)))",
  "      (i64.shr_u (local.get $hl) (i64.const 32)))",
  "      (i64.shr_u (local.get $mid) (i64.const 32))))",
]

export
valueEqRuntimeLines : Wide64W -> List String
valueEqRuntimeLines w =
  [
      "  ;; -- layer-9 runtime-shape-dispatched `==`/`/=` (String byte-equal OR immediate identity) --",
      "  (func $mdk_value_eq (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
      "    ;; both operands are $str structs -> byte equality.",
      "    (if (i32.and (ref.test (ref $str) (local.get $a)) (ref.test (ref $str) (local.get $b)))",
      "      (then (return (ref.i31 (i32.eq",
      "        (i32.const 1)",
      "        (i31.get_u (ref.cast (ref i31) (call $mdk_str_compare (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b)))))))))) ;; Eq == ordinal 1",
    ]
    ++ wideEqArmsW w
    ++ [
      "    ;; A2 (poly-Eq-on-Float): two boxed $float cells have distinct identities, so the",
      "    ;; `ref.eq` fallback would report equal floats as unequal — compare f64 values.",
      "    (if (i32.and (ref.test (ref $float) (local.get $a)) (ref.test (ref $float) (local.get $b)))",
      "      (then (return (ref.i31 (f64.eq",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))",
      "    ;; otherwise immediate/struct identity (i31 Int/Bool/Char/Unit, or ctor cells).",
      "    ;; layer-17 §2.1: a >2^30 Int is a $boxint struct, so two equal large Ints have",
      "    ;; distinct identities — when either side is a $boxint compare the unboxed i64.",
      "    (if (i32.or (ref.test (ref $boxint) (local.get $a)) (ref.test (ref $boxint) (local.get $b)))",
      "      (then (return (ref.i31 (i64.eq (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))",
      "    (ref.i31 (i32.eqz (i32.eqz (ref.eq (local.get $a) (local.get $b))))))",
      "  ;; -- layer-9 runtime-shape-dispatched ordering (String byte-order OR i31 signed) -> i32 -1/0/1 --",
      "  (func $mdk_value_cmp (param $a (ref eq)) (param $b (ref eq)) (result i32)",
      "    (local $o i32) (local $ia i64) (local $ib i64) (local $fa f64) (local $fb f64)",
      "    (if (i32.and (ref.test (ref $str) (local.get $a)) (ref.test (ref $str) (local.get $b)))",
      "      (then",
      "        ;; $mdk_str_compare -> Ordering i31 (Lt 0 / Eq 1 / Gt 2); map to -1/0/1.",
      "        (local.set $o (i31.get_u (ref.cast (ref i31) (call $mdk_str_compare (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b))))))",
      "        (return (i32.sub (local.get $o) (i32.const 1)))))",
      "    ;; A2 (poly-Ord-on-Float): a boxed $float operand -> f64 compare -> -1/0/1.",
      "    ;; Mirrors the arith helpers' left-operand $float discriminant.  A poly `Ord`",
      "    ;; compare (`a > b` on a Num/Ord type-var param) reaches here with $float cells;",
      "    ;; without this arm $mdk_unbox_int would ref.cast the $float to $boxint -> trap.",
      "    (if (ref.test (ref $float) (local.get $a))",
      "      (then",
      "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))",
      "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))",
      "        (if (f64.lt (local.get $fa) (local.get $fb)) (then (return (i32.const -1))))",
      "        (if (f64.gt (local.get $fa) (local.get $fb)) (then (return (i32.const 1))))",
      "        (return (i32.const 0))))",
    ]
    ++ wideCmpArmsW w
    ++ [
      "    ;; layer-17 §2.1: Int compare over the i64 box/unbox seam (handles >2^30 boxed).",
      "    (local.set $ia (call $mdk_unbox_int (local.get $a)))",
      "    (local.set $ib (call $mdk_unbox_int (local.get $b)))",
      "    (if (i64.lt_s (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))",
      "    (if (i64.gt_s (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))",
      "    (i32.const 0))",
      -- #305 (S0): per-op IEEE relational predicates — the WasmGC peers of native's
      -- mdk_value_lt/le/gt/ge.  $mdk_value_cmp's 3-way -1/0/1 STRUCTURALLY CANNOT
      -- express NaN's unorderedness (its $float arm returns 0/EQ for an unordered
      -- pair), so lowering `<=` as `cmp <= 0` read `nan <= nan` as True.  These take
      -- the $float arm as a direct f64 predicate (f64.lt/le/gt/ge are IEEE — all
      -- FALSE at NaN, matching the monomorphic emitFloatBinRef path) and delegate
      -- every other shape to the 3-way, exact for $str/int.  Return an i31 Bool.
      "  ;; -- #305 per-op IEEE relational predicates (Float f64 pred; else 3-way) --",
      "  (func $mdk_value_lt (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
      "    (if (ref.test (ref $float) (local.get $a))",
      "      (then (return (ref.i31 (f64.lt",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))",
      "    (ref.i31 (i32.lt_s (call $mdk_value_cmp (local.get $a) (local.get $b)) (i32.const 0))))",
      "  (func $mdk_value_le (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
      "    (if (ref.test (ref $float) (local.get $a))",
      "      (then (return (ref.i31 (f64.le",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))",
      "    (ref.i31 (i32.le_s (call $mdk_value_cmp (local.get $a) (local.get $b)) (i32.const 0))))",
      "  (func $mdk_value_gt (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
      "    (if (ref.test (ref $float) (local.get $a))",
      "      (then (return (ref.i31 (f64.gt",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))",
      "    (ref.i31 (i32.gt_s (call $mdk_value_cmp (local.get $a) (local.get $b)) (i32.const 0))))",
      "  (func $mdk_value_ge (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
      "    (if (ref.test (ref $float) (local.get $a))",
      "      (then (return (ref.i31 (f64.ge",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))",
      "    (ref.i31 (i32.ge_s (call $mdk_value_cmp (local.get $a) (local.get $b)) (i32.const 0))))",
    ]

-- ── A0 (poly-`Num`-on-Float): runtime value-tag-dispatched arithmetic helpers ──
-- The WasmGC port of native's runtime tag-dispatched `mdk_num_add/sub/mul/div/mod`
-- (`runtime/medaka_rt.c`): a POLYMORPHIC `Num a` operand (type known only at runtime)
-- has neither a static Float scalar-tag (approach C) nor a structural Float shape, so
-- the inline int primitive (`$mdk_unbox_int` -> i64 op) TRAPS `illegal cast` on a boxed
-- `$float` operand (WASM-POLY-NUM-DESIGN §2.2).  These helpers discriminate on the LEFT
-- operand's RUNTIME shape (exactly as native tests the low tag bit): `$float` -> f64 op +
-- `struct.new $float`; else the i31/`$boxint` int path via `$mdk_unbox_int`, the checked
-- operator (`$mdk_int_add`…, intRuntimeLines) and `$mdk_box_int` — the same
-- operators the inline int fallback calls, so an Int instantiation traps the same way.
-- `div` truncates toward zero (`i64.div_s` / `f64.div`); `%` is sign-of-dividend for Int
-- (`i64.rem_s`) and fmod for Float (== `$mdk_float_rem` == LLVM `frem` ==
-- native's `mdk_num_mod`).  Emitted only when a poly-`Num` operand is routed here
-- (`useValueArithRef`); `$mdk_unbox_int`/`$mdk_box_int` are always in scope (ioRuntimeLines).
--
-- ── #371: poly-`Num` int `/`/`%` divisor-zero guard ──────────────────────────
-- $mdk_value_div/$mdk_value_mod's int arms must not be bare i64.div_s/rem_s — no
-- guard — or a poly-`Num` `/`/`%` by zero dies with a raw engine trap ("divide by
-- zero") instead of the coded [E-DIV-ZERO]/[E-MOD-ZERO] line every other engine
-- (native mdk_num_div/mdk_num_mod, runtime/medaka_rt.c; the concrete-Int wasm path
-- via emitDivZeroGuard, wasm_emit.mdk) produces. This file is pure static data with
-- no access to that dynamic per-call-site helper (the circular-import note at the
-- top of this file) — but the message here is fixed at authoring time (no
-- per-call-site code/text to thread through), so the byte-unrolled trap sequence
-- (mirroring wasmTrap's `i32.const <n>` / `call $mdk_write_err_byte` per byte — no
-- $str value, no data segment, works in scalar AND ref mode) is built by a small
-- ASCII-only local helper instead of importing wasm_emit's dynamic one.
asciiTrapBytesW : String -> List String
asciiTrapBytesW s =
  let cs = stringToChars s
  asciiTrapGoW cs (arrayLength cs) 0

asciiTrapGoW : Array Char -> Int -> Int -> List String
asciiTrapGoW cs n i =
  if i >= n then
    []
  else
    "        i32.const " ++ intToString (charCode (arrayGetUnsafe i cs))
      :: "        call $mdk_write_err_byte"
      :: asciiTrapGoW cs n (i + 1)

-- the fixed [E-DIV-ZERO]/[E-MOD-ZERO] lines, matching native's mdk_num_div/
-- mdk_num_mod message bytes exactly (runtime/medaka_rt.c:622,627).
valueDivZeroTrapW : List String
valueDivZeroTrapW =
  asciiTrapBytesW "runtime error [E-DIV-ZERO]: division by zero\n"
    ++ ["        unreachable"]

valueModZeroTrapW : List String
valueModZeroTrapW =
  asciiTrapBytesW "runtime error [E-MOD-ZERO]: modulo by zero\n"
    ++ ["        unreachable"]

-- S2/#2359: split into one list PER OPERATOR (add/sub/mul/div/mod) so a program
-- demanding only e.g. `-` (WasmEmit.useValueSub) doesn't drag in the other four
-- functions — was one flat list spliced whole on a single blanket flag
-- (useValueArith). See wasm_emit.mdk's valueAddRt/valueSubRt/valueMulRt/
-- valueDivRt/valueModRt bindings for the per-flag gating this backs.
export
valueAddRuntimeLines : Wide64W -> List String
valueAddRuntimeLines w =
  [
      "  ;; -- A0 runtime value-tag-dispatched arithmetic (poly-`Num`: Int i31/$boxint OR $float) --",
      "  (func $mdk_value_add (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
    ]
    ++ wideArithArmsW w "i64.add"
    ++ [
      "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))",
      "      (then (struct.new $float (f64.add",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))",
      "      (else (call $mdk_box_int (call $mdk_int_add (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)) (i64.const 0))))))",
    ]

export
valueSubRuntimeLines : Wide64W -> List String
valueSubRuntimeLines w =
  [
      "  (func $mdk_value_sub (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
    ]
    ++ wideArithArmsW w "i64.sub"
    ++ [
      "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))",
      "      (then (struct.new $float (f64.sub",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))",
      "      (else (call $mdk_box_int (call $mdk_int_sub (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)) (i64.const 0))))))",
    ]

export
valueMulRuntimeLines : Wide64W -> List String
valueMulRuntimeLines w =
  [
      "  (func $mdk_value_mul (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
    ]
    ++ wideArithArmsW w "i64.mul"
    ++ [
      "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))",
      "      (then (struct.new $float (f64.mul",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))",
      "      (else (call $mdk_box_int (call $mdk_int_mul (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)) (i64.const 0))))))",
    ]

export
valueDivRuntimeLines : Wide64W -> List String
valueDivRuntimeLines w =
  [
      "  ;; #371: int arm guards the divisor (mirrors emitDivZeroGuard's concrete-Int",
      "  ;; guard) — stash $b's unboxed value in $vdr, trap the coded [E-DIV-ZERO] line",
      "  ;; if zero, else the checked $mdk_int_div on the stashed value (unbox once, not twice).",
      "  (func $mdk_value_div (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
      "    (local $vdr i64)",
    ]
    ++ wideDivArmsW w "i64.div_u" "call $mdk_i64_div" valueDivZeroTrapW
    ++ [
      "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))",
      "      (then (struct.new $float (f64.div",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))",
      "      (else",
      "        (local.set $vdr (call $mdk_unbox_int (local.get $b)))",
      "        (if (i64.eqz (local.get $vdr)) (then"
    ]
    ++ valueDivZeroTrapW
    ++ [
      "        ))",
      "        (call $mdk_box_int (call $mdk_int_div (call $mdk_unbox_int (local.get $a)) (local.get $vdr) (i64.const 0))))))",
    ]

export
valueModRuntimeLines : Wide64W -> List String
valueModRuntimeLines w =
  [
      "  ;; #345 Float arm is fmod ($mdk_float_rem), NOT the old inline `a - b*trunc(a/b)`",
      "  ;; (which lost precision for large |a/b|, e.g. 1e300 % 7 -> 1e300).  Mirrors native",
      "  ;; mdk_num_mod's fmod and the monomorphic Float `%` path (emitFloatBinRef).",
      "  ;; #371: int arm guards the divisor the same way as $mdk_value_div above.",
      "  (func $mdk_value_mod (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
      "    (local $vdr i64)",
    ]
    ++ wideDivArmsW w "i64.rem_u" "i64.rem_s" valueModZeroTrapW
    ++ [
      "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))",
      "      (then (struct.new $float (call $mdk_float_rem",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))",
      "      (else",
      "        (local.set $vdr (call $mdk_unbox_int (local.get $b)))",
      "        (if (i64.eqz (local.get $vdr)) (then"
    ]
    ++ valueModZeroTrapW
    ++ [
      "        ))",
      "        (call $mdk_box_int (i64.rem_s (call $mdk_unbox_int (local.get $a)) (local.get $vdr))))))",
    ]

-- S2/#2359: the num-only poly-`Ord`/`Eq`-on-Float cmp sextet (eq_num/cmp_num/
-- lt_num/le_num/gt_num/ge_num), gated as ONE block by its own flag
-- (WasmEmit.useValueCmpNum) — independent of which arith op(s) above are
-- demanded, since the isCmpOp poly-num routing branch (wasm_emit.mdk) never
-- touches $mdk_value_add/sub/mul/div/mod.
export
valueCmpNumRuntimeLines : Wide64W -> List String
valueCmpNumRuntimeLines w =
  [
      "  ;; -- A1 poly-`Ord`/`Eq`-on-Float, NUM-ONLY (no $str): $float f64-eq/cmp else i64 --",
      "  (func $mdk_value_eq_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
    ]
    ++ wideEqArmsW w
    ++ [
      "    (if (ref.test (ref $float) (local.get $a))",
      "      (then (return (ref.i31 (f64.eq",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))",
      "    (ref.i31 (i64.eq (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))",
      "  (func $mdk_value_cmp_num (param $a (ref eq)) (param $b (ref eq)) (result i32)",
      "    (local $fa f64) (local $fb f64) (local $ia i64) (local $ib i64)",
      "    (if (ref.test (ref $float) (local.get $a))",
      "      (then",
      "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))",
      "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))",
      "        (if (f64.lt (local.get $fa) (local.get $fb)) (then (return (i32.const -1))))",
      "        (if (f64.gt (local.get $fa) (local.get $fb)) (then (return (i32.const 1))))",
      "        (return (i32.const 0))))",
    ]
    ++ wideCmpArmsW w
    ++ [
      "    (local.set $ia (call $mdk_unbox_int (local.get $a)))",
      "    (local.set $ib (call $mdk_unbox_int (local.get $b)))",
      "    (if (i64.lt_s (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))",
      "    (if (i64.gt_s (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))",
      "    (i32.const 0))",
      -- #305: the num-only peers of $mdk_value_lt/le/gt/ge (same law, no $str) —
      -- IEEE f64 predicate on a $float operand, else the exact int 3-way.
      "  (func $mdk_value_lt_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
      "    (if (ref.test (ref $float) (local.get $a))",
      "      (then (return (ref.i31 (f64.lt",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))",
      "    (ref.i31 (i32.lt_s (call $mdk_value_cmp_num (local.get $a) (local.get $b)) (i32.const 0))))",
      "  (func $mdk_value_le_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
      "    (if (ref.test (ref $float) (local.get $a))",
      "      (then (return (ref.i31 (f64.le",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))",
      "    (ref.i31 (i32.le_s (call $mdk_value_cmp_num (local.get $a) (local.get $b)) (i32.const 0))))",
      "  (func $mdk_value_gt_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
      "    (if (ref.test (ref $float) (local.get $a))",
      "      (then (return (ref.i31 (f64.gt",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))",
      "    (ref.i31 (i32.gt_s (call $mdk_value_cmp_num (local.get $a) (local.get $b)) (i32.const 0))))",
      "  (func $mdk_value_ge_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))",
      "    (if (ref.test (ref $float) (local.get $a))",
      "      (then (return (ref.i31 (f64.ge",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))",
      "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))",
      "    (ref.i31 (i32.ge_s (call $mdk_value_cmp_num (local.get $a) (local.get $b)) (i32.const 0))))",
    ]

-- ── W8 RNG — deterministic SplitMix64 (RUNTIME-DESIGN §5 RNG) ─────────────────
-- Byte-identical to medaka_rt.c's shared SplitMix64 (the same algorithm the OCaml
-- oracle runs), so seeded streams match exactly.  Seed lives in a mutable i64 global
-- (default 0).  All arithmetic is i64, all shifts LOGICAL (i64.shr_u), wrapping on
-- overflow (i64 ops wrap naturally).  Emitted when the program uses any RNG extern.
--   randomInt lo hi : INCLUSIVE [lo,hi]; randomBool : LSB; randomChar : ASCII [32,126].
-- randomFloat is DEFERRED (W8b) with the Float-formatting work.
export
rngStateGlobalLines : List String
rngStateGlobalLines = ["  (global $mdk_rng_state (mut i64) (i64.const 0))"]

export
rngRuntimeLines : List String
rngRuntimeLines = [
  "  ;; ── W8 SplitMix64 RNG (byte-identical to medaka_rt.c) ──",
  "  (func $mdk_next_u64 (result i64)", "    (local $z i64)",
  "    (global.set $mdk_rng_state (i64.add (global.get $mdk_rng_state) (i64.const 0x9E3779B97F4A7C15)))",
  "    (local.set $z (global.get $mdk_rng_state))",
  "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 30))) (i64.const 0xBF58476D1CE4E5B9)))",
  "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 27))) (i64.const 0x94D049BB133111EB)))",
  "    (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 31))))",
  "  ;; #179 randomInt lo hi : i64 lo/hi -> i64 in [lo,hi] (INCLUSIVE).  lo > hi -> lo.",
  "  ;; i64 (not i32): a range > 2^30 (e.g. randomInt 0 1000000000000000) overflows i32 —",
  "  ;; and the old ref.i31 box at the call site trapped `illegal cast` on the large draw.",
  "  ;; Byte-identical to native mdk_random_int: the span hi-lo+1 is read UNSIGNED, so",
  "  ;; the full Int range's 2^63 draws too (#3451); it is never 0 for 63-bit bounds.",
  "  (func $mdk_random_int (param $lo i64) (param $hi i64) (result i64)",
  "    (if (result i64) (i64.lt_s (local.get $hi) (local.get $lo))",
  "      (then (local.get $lo))", "      (else",
  "        (i64.add (local.get $lo)",
  "          (i64.rem_u (call $mdk_next_u64)",
  "            (i64.add (i64.sub (local.get $hi) (local.get $lo)) (i64.const 1)))))))",
  "  (func $mdk_random_bool (result i32)",
  "    (i32.wrap_i64 (i64.and (call $mdk_next_u64) (i64.const 1))))",
  "  (func $mdk_random_char (result i32)",
  "    (i32.add (i32.const 32) (i32.wrap_i64 (i64.rem_u (call $mdk_next_u64) (i64.const 95)))))"
]

-- ── W8 Hashable per-type hashers — SPECIFIED, byte-identical to medaka_rt.c ────
-- hashInt/hashChar : SplitMix64 finalizer (mix64) of the value, masked to [0,2^30).
-- hashBool : 0/1 direct.  hashString : FNV-1a over UTF-8 BYTES, masked.  hashFloat
-- is DEFERRED (W8b, Float work).  Mask 0x3FFFFFFF = 2^30-1 fits i31 (non-negative).
export
hashRuntimeLines : List String
hashRuntimeLines = [
  "  ;; ── W8 per-type hashers (byte-identical to medaka_rt.c) ──",
  "  ;; SplitMix64 finalizer as a pure mixer (no state update).",
  "  (func $mdk_hash_mix64 (param $x i64) (result i64)", "    (local $z i64)",
  "    (local.set $z (i64.add (local.get $x) (i64.const 0x9E3779B97F4A7C15)))",
  "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 30))) (i64.const 0xBF58476D1CE4E5B9)))",
  "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 27))) (i64.const 0x94D049BB133111EB)))",
  "    (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 31))))",
  "  ;; hashInt / hashChar : mix64(value) & 0x3FFFFFFF.  #199: `n` is the FULL-WIDTH i64",
  "  ;; value (hashInt unboxes via $mdk_unbox_int; hashChar sign-extends its i31 codepoint),",
  "  ;; matching medaka_rt.c's signed `tagged>>1` over the whole 63-bit int — so an Int key",
  "  ;; outside +-2^30 (e.g. a HashMap Int) hashes correctly instead of trapping the i31 cast.",
  "  (func $mdk_hash_int (param $n i64) (result i32)",
  "    (i32.wrap_i64 (i64.and (call $mdk_hash_mix64 (local.get $n)) (i64.const 0x3FFFFFFF))))",
  "  (func $mdk_hash_bool (param $b i32) (result i32)",
  "    (if (result i32) (local.get $b) (then (i32.const 1)) (else (i32.const 0))))"
]

-- the $str-dependent hasher (hashString): FNV-1a over UTF-8 BYTES, masked.  offset
-- 0xCBF29CE484222325, prime 0x100000001B3 (all i64 wrapping).  Emitted only when the
-- program uses strings (a hashInt-only program never names the absent `$str`).
export
hashStringRuntimeLines : List String
hashStringRuntimeLines = [
  "  ;; hashString : FNV-1a over UTF-8 BYTES, masked.",
  "  (func $mdk_hash_string (param $s (ref $str)) (result i32)",
  "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $h i64)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $h (i64.const 0xCBF29CE484222325))",
  "    (local.set $i (i32.const 0))", "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $h (i64.mul (i64.xor (local.get $h) (i64.extend_i32_u (array.get_u $u8arr (local.get $b) (local.get $i)))) (i64.const 0x100000001B3)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (i32.wrap_i64 (i64.and (local.get $h) (i64.const 0x3FFFFFFF))))"
]

-- ── W11b: ASCII char classification + case-mapping runtime ────────────────────
-- Byte-identical to medaka_rt.c mdk_char_is_* / mdk_char_to_* (ASCII-only).
-- Each takes an UNBOXED i32 codepoint (caller does ref.cast + i31.get_u first)
-- and returns an i32 (0/1 for predicates; codepoint for case-mappers).
-- The caller wraps the result with ref.i31.
export
charClassRuntimeLines : List String
charClassRuntimeLines = [
  "  ;; ── W11b ASCII char classification + case mapping (byte-identical to medaka_rt.c) ──",
  "  (func $mdk_char_is_alpha (param $c i32) (result i32)", "    (i32.or",
  "      (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))",
  "      (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))))",
  "  (func $mdk_char_is_space (param $c i32) (result i32)", "    (i32.or",
  "      (i32.eq (local.get $c) (i32.const 32))",
  "      (i32.and (i32.ge_u (local.get $c) (i32.const 9)) (i32.le_u (local.get $c) (i32.const 13)))))",
  "  (func $mdk_char_is_upper (param $c i32) (result i32)",
  "    (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90))))",
  "  (func $mdk_char_is_lower (param $c i32) (result i32)",
  "    (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122))))",
  "  ;; charIsPunct: exact set from medaka_rt.c switch — Unicode Pc/Pd/Pe/Pf/Pi/Po/Ps ASCII.",
  "  ;; Included: ! \" # % & ' ( ) * , - . / : ; ? @ [ \\ ] _ { }",
  "  ;; Excluded ($+<=>^`|~): those are Unicode symbols (Sm/Sc/Sk), not punctuation.",
  "  ;; Right-associative OR chain over 23 chars = 22 i32.or nodes.",
  "  (func $mdk_char_is_punct (param $c i32) (result i32)",
  "    (i32.or (i32.eq (local.get $c) (i32.const 33))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 34))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 35))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 37))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 38))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 39))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 40))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 41))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 42))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 44))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 45))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 46))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 47))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 58))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 59))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 63))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 64))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 91))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 92))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 93))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 95))",
  "    (i32.or (i32.eq (local.get $c) (i32.const 123))",
  "           (i32.eq (local.get $c) (i32.const 125))",
  "    )))))))))))))))))))))))",
  "  (func $mdk_char_to_upper (param $c i32) (result i32)",
  "    (if (result i32)",
  "      (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))",
  "      (then (i32.sub (local.get $c) (i32.const 32)))",
  "      (else (local.get $c))))",
  "  (func $mdk_char_to_lower (param $c i32) (result i32)",
  "    (if (result i32)",
  "      (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))",
  "      (then (i32.add (local.get $c) (i32.const 32)))",
  "      (else (local.get $c))))"
]

-- ── W8b Float externs (RUNTIME-DESIGN §5 Float / WASMGC-DESIGN §3.3 boxed Float) ──
-- The §3.3 boxed Float is `(struct $float (field f64))`, declared unconditionally in
-- the rec group.  A Float value is a boxed (ref eq) struct; a Float LITERAL emits
-- `(struct.new $float (f64.const <floatToString-text>))` — the SAME rendering the LLVM
-- oracle bakes into its IR const, so the parsed double is byte-identical across clang
-- and wasm-tools (verified: identical i64.reinterpret_f64 bit patterns).
--
-- floatToString is the CRUX. ⚠️ #361/#383: the algorithm described below as "%.12g" is
-- STALE — REVISED 2026-07-15 (issue #57) to SHORTEST-ROUND-TRIP (medaka_rt.c:235,
-- `mdk_float_lexeme`): digit count is the fewest significant digits whose `strtod`
-- round-trips bit-exact, so `debug (0.1 + 0.2)` renders "0.30000000000000004", not the
-- old "%.12g" truncation "0.3". What DID survive from the historical %.12g rule is only
-- the EXPONENT THRESHOLD (scientific iff decimal exponent < -4 or >= 12) and the `.0`
-- append/trailing-zero-trim shape — not the digit count. Reproducing that in pure WAT
-- means reimplementing dtoa (no printf available), so per the W8b plan's authorized
-- fallback, floatToString is a HOST IMPORT: the JS host reproduces the SAME
-- shortest-round-trip algorithm byte-for-byte via `toExponential()` (no arg — JS's own
-- shortest half-even dtoa) re-formatted through the %.12g-style exponent threshold +
-- trailing-zero trim + the `.0` rule (test/wasm/run.js, function still named `fmt12g`
-- for history but ported to shortest-round-trip together with medaka_rt.c — see its own
-- header comment). This is the ONE host-dependent formatter — a clean parallel to the
-- deferred IO/WASI host surface; a non-JS wedge target would later need the in-WAT
-- dtoa. The host caches the formatted bytes and exposes them as (length, byte-at-index)
-- so the module rebuilds a $str without GC<->JS interop.
export
floatFmtImportLines : List String
floatFmtImportLines = [
  "  ;; -- W8b floatToString host seam (shortest-round-trip since #57 — reproduced JS-side, see run.js) --",
  "  (import \"env\" \"mdk_float_fmt\" (func $mdk_float_fmt (param f64) (result i32)))",
  "  (import \"env\" \"mdk_float_fmt_byte\" (func $mdk_float_fmt_byte (param i32) (result i32)))"
]

-- One `env` import per host key of `EmitPlan.hostKeys`, in the plan's order.  A
-- key is an import some reached extern's lowering calls, at its own call site or
-- in a WAT runtime helper (`extern_catalog.wasmHostKeys`), so a module imports
-- exactly what it calls.
export
hostImportLines : List String -> List String
hostImportLines [] = []
hostImportLines (key :: rest) =
  if key == stderrByteKey then
    -- declared once, at the late trap-import site, where body emission can add
    -- the coded traps' need
    hostImportLines rest
  else
    hostImportLine key :: hostImportLines rest

-- the stderr byte writer's host key (`stderrByteImportLines`)
export
stderrByteKey : String
stderrByteKey = "mdk_write_err_byte"

hostImportLine : String -> String
hostImportLine key =
  "  (import \"env\" \"\{key}\" (func $\{key}\{hostImportSig key}))"

hostImportSig : String -> String
hostImportSig key = match hostImportSigOf key
  Some sig => sig
  None =>
    panic
      "internal error: host key \{key} has no wasm import signature in wasm_preamble.mdk"

-- the signature each host binds a key with, written after the function's name,
-- or `None` for a key it does not bind
--
-- `mdk_exit` flushes and exits, so its call site is followed by `unreachable`.
-- The clock reads are seconds as f64 and the sleep milliseconds as i64 (design
-- WA-1); a host binds a non-positive sleep to a no-op.  WasmGC has no libm, so
-- the transcendentals and pow/atan2/hypot (the `unaryF64Sig` and `binaryF64Sig`
-- rows) are host imports backed by JS `Math.*`: byte-identical to C libm on the
-- values the fixtures exercise, with any printed sub-ULP divergence ledgered as
-- native:libm-vs-jsmath-ulp (test/engine_divergence.txt).  The IEEE-exact ops
-- (sqrt/floor/ceil/trunc/round) and floatRem lower to f64 opcodes, $mdk_round
-- and $mdk_float_rem, not host imports.
export
hostImportSigOf : String -> Option String
hostImportSigOf "mdk_exit" = Some " (param i32)"
hostImportSigOf "mdk_wall_time_sec" = Some " (result f64)"
hostImportSigOf "mdk_monotonic_sec" = Some " (result f64)"
hostImportSigOf "mdk_sleep_ms" = Some " (param i64)"
hostImportSigOf "mdk_fetch_text" = Some " (result i32)"
hostImportSigOf "mdk_cbrt" = Some unaryF64Sig
hostImportSigOf "mdk_exp" = Some unaryF64Sig
hostImportSigOf "mdk_log" = Some unaryF64Sig
hostImportSigOf "mdk_log2" = Some unaryF64Sig
hostImportSigOf "mdk_log10" = Some unaryF64Sig
hostImportSigOf "mdk_sin" = Some unaryF64Sig
hostImportSigOf "mdk_cos" = Some unaryF64Sig
hostImportSigOf "mdk_tan" = Some unaryF64Sig
hostImportSigOf "mdk_asin" = Some unaryF64Sig
hostImportSigOf "mdk_acos" = Some unaryF64Sig
hostImportSigOf "mdk_atan" = Some unaryF64Sig
hostImportSigOf "mdk_sinh" = Some unaryF64Sig
hostImportSigOf "mdk_cosh" = Some unaryF64Sig
hostImportSigOf "mdk_tanh" = Some unaryF64Sig
hostImportSigOf "mdk_pow" = Some binaryF64Sig
hostImportSigOf "mdk_atan2" = Some binaryF64Sig
hostImportSigOf "mdk_hypot" = Some binaryF64Sig
hostImportSigOf "mdk_path_reset" = Some ""
hostImportSigOf "mdk_path_push" = Some " (param i32)"
hostImportSigOf "mdk_read_file" = Some " (result i32)"
hostImportSigOf "mdk_file_exists" = Some " (result i32)"
hostImportSigOf "mdk_get_env" = Some " (result i32)"
hostImportSigOf "mdk_read_line" = Some " (result i32)"
hostImportSigOf "mdk_read_all" = Some ""
hostImportSigOf "mdk_read_exactly" = Some " (param i64) (result i32)"
hostImportSigOf "mdk_os_entropy" = Some " (param i64) (result i32)"
hostImportSigOf "mdk_executable_path" = Some " (result i32)"
hostImportSigOf "mdk_args_count" = Some " (result i32)"
hostImportSigOf "mdk_arg_len" = Some " (param i32) (result i32)"
hostImportSigOf "mdk_arg_byte" = Some " (param i32) (param i32) (result i32)"
hostImportSigOf "mdk_result_len" = Some " (result i32)"
hostImportSigOf "mdk_result_byte" = Some " (param i32) (result i32)"
hostImportSigOf "mdk_write_file_reset" = Some ""
hostImportSigOf "mdk_write_file_push" = Some " (param i32)"
hostImportSigOf "mdk_write_file_commit" = Some " (result i32)"
hostImportSigOf "mdk_str_to_float" = Some " (result f64)"
hostImportSigOf "mdk_str_to_float_ok" = Some " (result i32)"
hostImportSigOf "mdk_grant_reset" = Some ""
hostImportSigOf "mdk_grant_push" = Some " (param i32)"
hostImportSigOf "mdk_canonicalize_path" = Some " (result i32)"
hostImportSigOf "mdk_write_file" = Some " (result i32)"
hostImportSigOf "mdk_append_file" = Some " (result i32)"
hostImportSigOf "mdk_make_dir" = Some " (result i32)"
hostImportSigOf "mdk_remove_file" = Some " (result i32)"
hostImportSigOf "mdk_remove_dir" = Some " (result i32)"
hostImportSigOf "mdk_fsync" = Some " (result i32)"
hostImportSigOf "mdk_file_mode" = Some " (result i32)"
hostImportSigOf "mdk_write_file_mode" = Some " (param i32) (result i32)"
hostImportSigOf "mdk_rename" = Some " (param i32) (result i32)"
hostImportSigOf "mdk_list_dir" = Some " (result i32)"
hostImportSigOf "mdk_stat_file" = Some " (result i32)"
hostImportSigOf "mdk_stat_field" = Some " (param i32) (result f64)"
hostImportSigOf "mdk_file_bound_enter" =
  Some " (param i32) (param i32) (result i32)"
hostImportSigOf "mdk_file_bound_exit" = Some ""
hostImportSigOf _ = None

-- stringToFloat host seam: the guest pushes the string's bytes via the path channel
-- (mdk_path_reset + mdk_path_push, shared with IO) then calls mdk_str_to_float, which
-- reads pathBuf as a UTF-8 string, parses it with the strtod acceptance set and returns
-- the f64; mdk_str_to_float_ok then reports whether that parse SUCCEEDED.
-- #370: two channels, not one.  `Some nan` is a legal strtod result ("nan" parses), so
-- NaN cannot double as the failure signal — the old single-f64 seam mapped every NaN to
-- None and lost it.  The host parser (test/wasm/run.js + playground/worker.js, kept
-- byte-identical per WH3) reproduces medaka_rt.c mdk_string_to_float: strtod + a full-
-- consumption endptr check + an empty-string reject. Gated on
-- the plan's `mdk_str_to_float` host key.
-- $mdk_string_to_float : (ref $str) -> (ref eq)  (= Option Float = Some(boxed $float) | None)
-- Protocol: reset the path buffer, push each UTF-8 byte of the string, call
-- mdk_str_to_float (which parses the pathBuf bytes and LATCHES an ok flag), then
-- mdk_str_to_float_ok.  ok=0 -> None (i31 ordinal 1); ok=1 -> Some(boxed f64), even
-- when that f64 is NaN.  The host sees the pushed bytes via the shared pathBuf.
-- #370: the ok channel exists because the acceptance set and the value are independent
-- — strtod("nan") SUCCEEDS with a NaN value, while strtod("") and strtod("1.5 ") fail.
-- Testing the f64 for NaN can distinguish neither.
export
floatStrRuntimeLines : List String -> List String
floatStrRuntimeLines keys = gatedOn "mdk_str_to_float" keys floatStrLines

floatStrLines : List String
floatStrLines = [
  "  ;; stringToFloat : $str -> Option Float (ref eq).",
  "  (func $mdk_string_to_float (param $s (ref $str)) (result (ref eq))",
  "    (local $b (ref $u8arr)) (local $i i32) (local $n i32) (local $d f64)",
  "    (call $mdk_path_reset)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0))", "    (block $done (loop $loop",
  "      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1)))",
  "      (br $loop)))", "    (local.set $d (call $mdk_str_to_float))",
  "    ;; #370: the host latched an ok flag during that call; ask it, rather than",
  "    ;; testing $d for NaN — strtod(\"nan\") legitimately yields Some(NaN), and",
  "    ;; strtod(\"\")/strtod(\"1.5 \") legitimately FAIL with a non-NaN value.",
  "    (if (result (ref eq)) (i32.eqz (call $mdk_str_to_float_ok))",
  "      (then (ref.i31 (i32.const 1)))",
  "      (else (struct.new $C_Some (i32.const 0) (struct.new $float (local.get $d)))))",
  "  )"
]

-- the Float runtime (RUNTIME-DESIGN §5).  intToFloat/floatToInt are INTRINSIC (the
-- §3.3 box <-> raw conversion); floatToString rebuilds a $str from the host-formatted
-- bytes.  All byte-identical to the native oracle.
-- #345 $mdk_float_rem = fmod(a, b), byte-identical to C fmod / LLVM frem; backs BOTH
-- the monomorphic `Float % Float` (emitFloatBinRef) AND the num-poly `%` runtime arm
-- ($mdk_value_mod, in valueModRuntimeLines).  Emitted separately from floatRuntimeLines
-- and gated on `useFloatRef || useValueModRef` (wasm_emit.mdk, S2/#2359: narrowed from
-- the old whole-family useValueArithRef) so an int-only program that routes `%`
-- through value-dispatch still gets the helper (was a parse-time
-- `unknown func $mdk_float_rem` regression when it lived only in floatRuntimeLines).  The
-- old one-step `a - b*trunc(a/b)` LOST PRECISION for large |a/b| (f64.div/f64.trunc round:
-- 1e300 % 7 came back 0, not 1).  This is the exact power-of-two reduction used by libm:
-- scale y=|b| up to the largest y*2^k <= x=|a|, then walk it down to y subtracting where
-- it fits.  Each subtraction is Sterbenz-exact (t <= x < 2t) and each halving of t is
-- exact, so the remainder is the exact IEEE fmod.  Guards reproduce fmod's NaN cases
-- (b==0, a inf, a/b NaN); b==inf with finite a returns a (via x<y).  No host import.
export
floatRemRuntimeLines : List String
floatRemRuntimeLines = [
  "  (func $mdk_float_rem (param $a f64) (param $b f64) (result f64)",
  "    (local $x f64) (local $y f64) (local $t f64)",
  "    (local.set $y (f64.abs (local.get $b)))", "    (if (result f64)",
  "      (i32.or (i32.or",
  "        (f64.ne (f64.sub (local.get $a) (local.get $a)) (f64.const 0))",
  "        (f64.ne (local.get $b) (local.get $b)))",
  "        (f64.eq (local.get $y) (f64.const 0)))",
  "      ;; #672: the NaN result must carry the HOST's NaN SIGN, not WAT `nan`.  WAT",
  "      ;; `(f64.const nan)` is the FIXED canonical +NaN (0x7FF8..), but eval",
  "      ;; (`floatRem`=fmod) and native (`mdk_float_rem`=fmod) yield the host's NaN",
  "      ;; -- -NaN (0xFFF8..) on x86 -- and under the sign-dependent totalOrder (N6)",
  "      ;; a +NaN sorts/compares/hashes OPPOSITELY, so a fixed +NaN here made every",
  "      ;; `%`-NaN (e.g. `x % 0.0`) disagree with the other two engines on x86.",
  "      ;; `f64.div 0/0` is computed at RUNTIME by V8 (same as the `/` path), so it",
  "      ;; yields whatever NaN this box's hardware does -- matching eval/native and",
  "      ;; the wasm `f64.div` NaN on every platform (#509-safe: host-following, not",
  "      ;; a baked sign).",
  "      (then (f64.div (f64.const 0) (f64.const 0)))", "      (else",
  "        (local.set $x (f64.abs (local.get $a)))",
  "        (local.set $t (local.get $y))", "        (block $up (loop $ul",
  "          (br_if $up (f64.gt (f64.add (local.get $t) (local.get $t)) (local.get $x)))",
  "          (local.set $t (f64.add (local.get $t) (local.get $t)))",
  "          (br $ul)))", "        (block $dn (loop $dl",
  "          (if (f64.ge (local.get $x) (local.get $t))",
  "            (then (local.set $x (f64.sub (local.get $x) (local.get $t)))))",
  "          (br_if $dn (f64.eq (local.get $t) (local.get $y)))",
  "          (local.set $t (f64.mul (local.get $t) (f64.const 0.5)))",
  "          (br $dl)))",
  "        (f64.copysign (local.get $x) (local.get $a)))))"
]

export
floatRuntimeLines : List String
floatRuntimeLines = [
  "  ;; -- W8b Float runtime (byte-identical to medaka_rt.c) --",
  "  ;; intToFloat : i64 (full-width unboxed Int) -> boxed (struct $float).  #199: reads",
  "  ;; the arg through the $mdk_unbox_int seam so Ints outside +-2^30 no longer trap the",
  "  ;; i31 cast (e.g. intToFloat 4503599627370497).",
  "  (func $mdk_int_to_float (param $n i64) (result (ref $float))",
  "    (struct.new $float (f64.convert_i64_s (local.get $n))))",
  "  ;; floatToInt : boxed $float -> i64 (truncate toward zero).  #199: the i64 result",
  "  ;; reboxes via $mdk_box_int so a large truncation (|x| > 2^30, up to 2^53) no longer",
  "  ;; overflows i32 (`float unrepresentable in integer range`) nor traps ref.i31.",
  "  ;; #346/#372 (S0): SATURATES — NaN -> 0, +inf/over -> intMaxBound, -inf/under ->",
  "  ;; intMinBound.  The old bare i64.trunc_f64_s TRAPPED on NaN/inf/out-of-range (an",
  "  ;; uncoded engine trap: `float unrepresentable in integer range`, exit 1, no E-code),",
  "  ;; where native's fptosi was silent poison — so the three engines disagreed on exactly",
  "  ;; the inputs N7 says must be pinned.  trunc_sat alone is NOT enough: it saturates to",
  "  ;; *i64* bounds (+-2^63), which are OUTSIDE Medaka's 63-bit Int domain, and $mdk_box_int",
  "  ;; would renormalize that to -1/0 rather than the bound.  So clamp to the Int bounds",
  "  ;; ([-2^62, 2^62-1]) BEFORE returning to the box seam.  Matches llvm_emit's arm.",
  "  (func $mdk_float_to_int (param $f (ref $float)) (result i64)",
  "    (local $r i64)",
  "    (local.set $r (i64.trunc_sat_f64_s (struct.get $float 0 (local.get $f))))",
  "    (if (result i64) (i64.gt_s (local.get $r) (i64.const 4611686018427387903))",
  "      (then (i64.const 4611686018427387903))",
  "      (else (if (result i64) (i64.lt_s (local.get $r) (i64.const -4611686018427387904))",
  "        (then (i64.const -4611686018427387904))",
  "        (else (local.get $r))))))",
  "  ;; #101 round : C round() — round to nearest, HALVES AWAY FROM ZERO (NOT f64.nearest,",
  "  ;; which is round-half-to-even).  Branch-based so there is NO intermediate `x+0.5`:",
  "  ;; the naive `floor(abs(x)+0.5)` double-rounds — `x+0.5` itself rounds (IEEE) before",
  "  ;; the floor, so round(0.49999999999999994)->1 (should be 0) and every odd-integer",
  "  ;; double in [2^52,2^53) (an exact `x+0.5` tie -> half-to-even picks x+1) came back",
  "  ;; off-by-one.  Here we floor/ceil FIRST, then compare the exact fractional distance",
  "  ;; to 0.5.  Byte-identical to native mdk_round (== C round(), medaka_rt.c) for all",
  "  ;; finite inputs (an already-integral x has fraction 0 < 0.5 -> returned unchanged).",
  "  (func $mdk_round (param $x f64) (result f64)", "    (local $t f64)",
  "    (if (result f64) (f64.ge (local.get $x) (f64.const 0.0))",
  "      (then (local.set $t (f64.floor (local.get $x)))",
  "        (if (result f64) (f64.ge (f64.sub (local.get $x) (local.get $t)) (f64.const 0.5))",
  "          (then (f64.add (local.get $t) (f64.const 1.0))) (else (local.get $t))))",
  "      (else (local.set $t (f64.ceil (local.get $x)))",
  "        (if (result f64) (f64.ge (f64.sub (local.get $t) (local.get $x)) (f64.const 0.5))",
  "          (then (f64.sub (local.get $t) (f64.const 1.0))) (else (local.get $t))))))",
  "  ;; floatToString : the host formats (shortest-round-trip since #57, + .0 rule)",
  "  ;; into a cache; copy the bytes into a fresh $str.  cp_count == byte_len (ASCII).",
  "  (func $mdk_float_to_str (param $d f64) (result (ref $str))",
  "    (local $n i32) (local $i i32) (local $buf (ref $u8arr))",
  "    (local.set $n (call $mdk_float_fmt (local.get $d)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (local.set $i (i32.const 0))", "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (array.set $u8arr (local.get $buf) (local.get $i) (call $mdk_float_fmt_byte (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (struct.new $str (local.get $n) (local.get $buf)))"
]

-- the float HASH ($mdk_hash_float) — bit-reinterpret f64 -> i64 then mix64 & mask.
-- Emitted only when the program uses BOTH Float and a per-type hasher (so the shared
-- $mdk_hash_mix64 from hashRuntimeLines is in scope).
export
hashFloatRuntimeLines : List String
hashFloatRuntimeLines = [
  "  ;; hashFloat (#758): normalise -0.0 -> +0.0 and every NaN -> one qNaN bit",
  "  ;; pattern, then reinterpret bits as i64 -> mix64 -> mask [0,2^30).  Matches",
  "  ;; mdk_hash_float (native) and pHashFloat (eval), or run /= build reappears.",
  "  (func $mdk_hash_float (param $f (ref $float)) (result i32)",
  "    (local $d f64) (local $bits i64)",
  "    (local.set $d (struct.get $float 0 (local.get $f)))",
  "    (if (f64.eq (local.get $d) (f64.const 0))",
  "      (then (local.set $bits (i64.const 0)))", "      (else",
  "        (if (f64.ne (local.get $d) (local.get $d))",
  "          (then (local.set $bits (i64.const 0x7FF8000000000000)))",
  "          (else (local.set $bits (i64.reinterpret_f64 (local.get $d)))))))",
  "    (i32.wrap_i64 (i64.and (call $mdk_hash_mix64 (local.get $bits)) (i64.const 0x3FFFFFFF))))"
]

-- randomFloat ($mdk_random_float) — SplitMix64 draw -> f64 in [-1,1).  Needs the W8
-- $mdk_next_u64 from rngRuntimeLines (gated on float+rng co-use).  `(next>>11)` is the
-- top 53 bits; * 2^-53 gives [0,1); * 2 - 1 gives [-1,1) — EXACTLY medaka_rt.c.
export
randomFloatRuntimeLines : List String
randomFloatRuntimeLines = [
  "  ;; randomFloat : SplitMix64 -> f64 in [-1,1) (NOTE the -1 offset — see medaka_rt.c).",
  "  (func $mdk_random_float (result (ref $float))", "    (struct.new $float",
  "      (f64.sub", "        (f64.mul",
  "          (f64.mul (f64.convert_i64_u (i64.shr_u (call $mdk_next_u64) (i64.const 11)))",
  "                   (f64.const 1.1102230246251565e-16))",
  "          (f64.const 2.0))", "        (f64.const 1.0))))"
]

-- ── W12 IO host surface (readFile / fileExists / args / getEnv) ──────────────
-- The LAST emitter-gap category: the IO externs.  GC refs ($str) cannot cross the
-- wasm import boundary, so strings are marshaled through a byte-at-a-time channel —
-- exactly the length+byte protocol the floatToString host seam uses (run.js fmt12g).
--
-- Protocol (run.js backs each import with Node fs/process behind a swappable `vfs`
-- seam so a browser playground can supply an in-memory FS with the same signatures):
--   SENDING a string TO the host (a path / env-var name): the guest calls
--     $mdk_path_reset() then loops the arg $str's bytes calling mdk_path_push(byte).
--   READING a string FROM the host (file contents / env value / arg): after the host
--     caches the result bytes, the guest reads mdk_result_len() + mdk_result_byte(i)
--     per byte and rebuilds a fresh $str ($mdk_io_result_to_str), read as UTF-8 by
--     $mdk_u8_to_str_lossy (utf8LossyRuntimeLines).
--   readFile  : push path, mdk_read_file() -> i32 (1=Ok, 0=Err); rebuild the result
--     $str and wrap Ok (struct.new $C_Ok, ord 0) / Err (struct.new $C_Err, ord 1).
--     Contents that are not UTF-8 are an Err naming the path ($mdk_str_not_utf8).
--   fileExists: push path, mdk_file_exists() -> i32 (1/0) -> Bool i31; 2 is a
--     refusal, whose message is on the result channel ($mdk_refused_panic).
--   canonicalizePath: push path, mdk_canonicalize_path() -> i32 (1=the canonical
--     path, or the path itself when it has none, on the result channel / 0=a refusal).
--   A file extern whose path is an authority pushes its grant first
--   ($mdk_push_grant): mdk_grant_reset(), then each element's bytes through
--   mdk_grant_push(byte), each element ended by mdk_grant_push(-1).  `[]` pushes
--   no element: the whole domain.  The host confines the path against that grant
--   and every enclosing declared bound of the same mode, as medaka_rt.c
--   mdk_confine_bounds does, and a refusal is an Err of the extern's result.
--   fetchText : push url, mdk_fetch_text() -> i32 (1=Ok body / 0=Err message), both on the
--     result channel; wrap as readFile does.
--   getEnv    : push name, mdk_get_env() -> i32 (1=Some / 0=None); rebuild $str and
--     wrap Some (struct.new $C_Some, ord 0) / None (i31 ord 1).
--   executablePath : mdk_executable_path() -> i32 (always 1); the path on the result channel.
--   osEntropyBytes : mdk_os_entropy(n) -> i32 (1 = n bytes on the result channel; 0 = a
--     refusal, its panic text on the channel, which the guest panics with).
--   args      : mdk_args_count(); per i build a $str from mdk_arg_len(i)/mdk_arg_byte(i,j),
--     fold a Cons chain right-to-left ending in Nil (i31 ord 1).
-- Each import is a host key of the reached externs (`EmitPlan.hostKeys`), and
-- each runtime helper below is gated on the key it calls.
-- readFile's Err suffix for contents that are not UTF-8, the text of
-- medaka_rt.c mdk_read_file's, as the WAT that builds it as a $u8arr.  ASCII,
-- so one element per character.
notUtf8SuffixWat : String
notUtf8SuffixWat =
  asciiU8arrWat ": not valid UTF-8 (use readFileBytes for raw bytes)"

-- the WAT that builds an ASCII string's bytes as a $u8arr
asciiU8arrWat : String -> String
asciiU8arrWat s =
  let cs = stringToChars s
  "(array.new_fixed $u8arr \{intToString (arrayLength cs)}\{asciiConstsW cs (arrayLength cs) 0})"

asciiConstsW : Array Char -> Int -> Int -> String
asciiConstsW cs n i =
  if i >= n then
    ""
  else
    " (i32.const \{intToString (charCode (arrayGetUnsafe i cs))})"
      ++ asciiConstsW cs n (i + 1)

-- the IO host-surface runtime: the byte-channel marshalers + the five extern bodies.
-- $str-dependent (every path/result is a $str) and $C_Ok/$C_Err/$C_Some/$T_List are
-- always declared in ref-mode, so these are always in scope when emitted.
export
ioHostRuntimeLines : List String -> List String
ioHostRuntimeLines keys =
  gatedOn "mdk_path_push" keys ioPushPathLines
    ++ gatedOn "mdk_rename" keys ioPushPathMoreLines
    ++ gatedOn "mdk_grant_push" keys ioPushGrantLines
    ++ gatedOn "mdk_rename" keys ioPushGrantMoreLines
    ++ gatedOn "mdk_result_len" keys ioResultLines
    ++ (if contains "mdk_file_exists" keys
      || contains "mdk_canonicalize_path" keys
      || contains "mdk_os_entropy" keys then
      ioRefusedPanicLines
    else
      [])
    ++ gatedOn "mdk_read_file" keys ioReadFileLines
    ++ gatedOn "mdk_fetch_text" keys ioFetchTextLines
    ++ gatedOn "mdk_file_exists" keys ioFileExistsLines
    ++ gatedOn "mdk_canonicalize_path" keys ioCanonicalizeLines
    ++ gatedOn "mdk_write_file" keys ioWriteFileLines
    ++ gatedOn "mdk_append_file" keys ioAppendFileLines
    ++ gatedOn "mdk_rename" keys ioRenameLines
    ++ gatedOn "mdk_list_dir" keys ioListDirLines
    ++ gatedOn "mdk_stat_file" keys ioStatFileLines
    ++ gatedOn "mdk_make_dir" keys ioMakeDirLines
    ++ gatedOn "mdk_remove_file" keys ioRemoveFileLines
    ++ gatedOn "mdk_remove_dir" keys ioRemoveDirLines
    ++ gatedOn "mdk_fsync" keys ioFsyncLines
    ++ gatedOn "mdk_file_mode" keys ioFileModeLines
    ++ gatedOn "mdk_write_file_mode" keys ioWriteFileModeLines
    ++ gatedOn "mdk_get_env" keys ioGetEnvLines
    ++ gatedOn "mdk_read_line" keys ioReadLineLines
    ++ gatedOn "mdk_read_all" keys ioReadAllLines
    ++ gatedOn "mdk_read_exactly" keys ioReadExactlyLines
    ++ gatedOn "mdk_executable_path" keys ioExecutablePathLines

gatedOn : String -> List String -> List String -> List String
gatedOn key keys block = if contains key keys then block else []

ioPushPathLines : List String
ioPushPathLines = [
  "  ;; push a $str's bytes to the host path buffer (reset first).",
  "  (func $mdk_push_path (param $s (ref $str))",
  "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)",
  "    (call $mdk_path_reset)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0))", "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    )"
]

-- Only rename pushes a second path; the helper is emitted for it alone.
ioPushPathMoreLines : List String
ioPushPathMoreLines = [
  "  ;; append a $str's bytes to the host path buffer (rename's second path).",
  "  (func $mdk_push_path_more (param $s (ref $str))",
  "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0))", "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    )"
]

-- A grant is the W7 cons list of $str elements; Nil is an i31.
ioPushGrantLines : List String
ioPushGrantLines = [
  "  ;; push a grant (List String) to the host grant buffer (reset first).",
  "  (func $mdk_push_grant (param $g (ref eq))",
  "    (local $cell (ref $C_Cons)) (local $b (ref $u8arr)) (local $i i32) (local $n i32)",
  "    (call $mdk_grant_reset)", "    (block $done (loop $next",
  "      (br_if $done (i32.eqz (ref.test (ref $C_Cons) (local.get $g))))",
  "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $g)))",
  "      (local.set $b (struct.get $str $bytes (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell)))))",
  "      (local.set $n (array.len (local.get $b)))",
  "      (local.set $i (i32.const 0))", "      (block $d (loop $l",
  "        (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "        (call $mdk_grant_push (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "        (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "      (call $mdk_grant_push (i32.const -1))",
  "      (local.set $g (struct.get $C_Cons 2 (local.get $cell))) (br $next)))",
  "    )"
]

-- Only rename pushes a second grant; the helper is emitted for it alone.
ioPushGrantMoreLines : List String
ioPushGrantMoreLines = [
  "  ;; append a grant to the host grant buffer (rename's second grant).",
  "  (func $mdk_push_grant_more (param $g (ref eq))",
  "    (local $cell (ref $C_Cons)) (local $b (ref $u8arr)) (local $i i32) (local $n i32)",
  "    (block $done (loop $next",
  "      (br_if $done (i32.eqz (ref.test (ref $C_Cons) (local.get $g))))",
  "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $g)))",
  "      (local.set $b (struct.get $str $bytes (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell)))))",
  "      (local.set $n (array.len (local.get $b)))",
  "      (local.set $i (i32.const 0))", "      (block $d (loop $l",
  "        (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "        (call $mdk_grant_push (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "        (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "      (call $mdk_grant_push (i32.const -1))",
  "      (local.set $g (struct.get $C_Cons 2 (local.get $cell))) (br $next)))",
  "    )"
]

-- A refusal from an extern that returns no Result panics, as medaka_rt.c
-- mdk_panic prints it: the E-PANIC banner, the message, a newline.
ioRefusedPanicLines : List String
ioRefusedPanicLines = [
  "  ;; the host's refusal message (result channel) as an E-PANIC line, then trap.",
  "  (func $mdk_refused_panic",
  "    (call $mdk_err_u8arr \{panicBannerWat})",
  "    (call $mdk_err_u8arr (call $mdk_io_result_bytes))",
  "    (call $mdk_write_err_byte (i32.const 10))",
  "    (unreachable))",
  "  (func $mdk_err_u8arr (param $b (ref $u8arr))",
  "    (local $i i32) (local $n i32)",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_write_err_byte (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    )",
]

panicBannerWat : String
panicBannerWat = asciiU8arrWat "runtime error [E-PANIC]: "

ioResultLines : List String
ioResultLines = [
  "  ;; copy the host result buffer (length + byte-at-index) into a fresh $u8arr.",
  "  (func $mdk_io_result_bytes (result (ref $u8arr))",
  "    (local $n i32) (local $i i32) (local $buf (ref $u8arr))",
  "    (local.set $n (call $mdk_result_len))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (local.set $i (i32.const 0))", "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (array.set $u8arr (local.get $buf) (local.get $i) (call $mdk_result_byte (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (local.get $buf))",
  "  ;; the host result buffer as a $str, read as UTF-8 by $mdk_u8_to_str_lossy.",
  "  (func $mdk_io_result_to_str (result (ref $str))",
  "    (call $mdk_u8_to_str_lossy (call $mdk_io_result_bytes)))"
]

-- ── user `js` bindings: the `jsffi` import module (WASM-SEMANTICS.md §3.1) ──
-- One import per reached binding, named by its JS name and its declared heads,
-- so the host reads each signature off the module.
export
jsffiImportLines : List JsImport -> List String
jsffiImportLines imps = map jsffiImportLine imps

jsffiImportLine : JsImport -> String
jsffiImportLine imp =
  let params = joinWith "" (map jsWireParam imp.params)
  "  (import \"jsffi\" \"\{jsImportField imp}\" (func $\{jsffiImportId imp.medakaName}\{params}\{jsWireResult imp.result}))"

-- The WAT identifiers of an extern's import and of its wrapper, without the
-- `$`.  The two prefixes differ, so no import can share a wrapper's identifier
-- whatever the names, and a Medaka name never holds a `.`, so no function the
-- program defines under its own name can share either.
export
jsffiImportId : String -> String
jsffiImportId name = "jsffi.import.\{injectiveIdent name}"

export
jsffiWrapperId : String -> String
jsffiWrapperId name = "jsffi.wrap.\{injectiveIdent name}"

-- `<jsName>:<P1>,...,<Pn>-><R>`, each head as declared.
export
jsImportField : JsImport -> String
jsImportField imp = "\{imp.jsName}:\{joinWith "," imp.params}->\{imp.result}"

jsWireTy : String -> String
jsWireTy "Int" = "i64"
jsWireTy "U64" = "i64"
jsWireTy "I64" = "i64"
jsWireTy "Float" = "f64"
jsWireTy _ = "i32"

isChannelHead : String -> Bool
isChannelHead head = head == "String" || head == "Array"

-- The heads section 3.1 gives a crossing to: the FFI v1 crossable set
-- (compiler/FFI-ABI.md section 1).  The wrapper's catch-all arms assume one.
export
jsCrossableHead : String -> Bool
jsCrossableHead head = contains head [
  "Int", "Float", "Bool", "Char", "String", "Array", "Unit", "U8", "U16", "U32",
  "I32", "U64", "I64"
]

-- The wrapper (`jsffiWrapperId`): Medaka values in, the import called, a Medaka
-- value out.  `intTrap` and `charTrap` stop the program for a result that is
-- not an `Int` or not a `Char`, and `copyTrap` for an `Array` element written
-- back outside `Int`'s range.  An `Array` result never reaches here: it is an
-- emitter gap, as on native.
export
jsffiWrapperLines : JsImport ->
  List String ->
  List String ->
  List String ->
  List String
jsffiWrapperLines imp intTrap charTrap copyTrap =
  let ps = zipHeads imp.params 0
  let params =
    joinWith "" (map (p => " (param $p\{intToString (snd p)} (ref eq))") ps)
  let held = jsWireResult imp.result /= ""
  let rLocal = if held then " (local $r \{jsWireTy imp.result})" else ""
  let push =
    if anyList (p => isChannelHead (fst p)) ps then
      "    (call $mdk_path_reset)" :: flatMap jsPushArg ps
    else
      []
  [
      "  (func $\{jsffiWrapperId imp.medakaName}\{params} (result (ref eq))",
      "    (local $off i32)\{rLocal}",
    ]
    ++ push
    ++ flatMap jsWireArg ps
    ++ ["    call $\{jsffiImportId imp.medakaName}"]
    ++ (if held then ["    local.set $r"] else [])
    ++ flatMap (jsCopyBack copyTrap) ps
    ++ jsUnwire imp.result intTrap charTrap
    ++ ["  )"]

zipHeads : List String -> Int -> List (String, Int)
zipHeads [] _ = []
zipHeads (h :: rest) i = (h, i) :: zipHeads rest (i + 1)

-- a `String` or `Array` argument's contents, appended to the path channel
jsPushArg : (String, Int) -> List String
jsPushArg ("String", i) = [
  "    (call $mdk_push_path_more (ref.cast (ref $str) (local.get $p\{intToString i})))",
]
jsPushArg ("Array", i) = [
  "    (call $mdk_jsffi_push_ints (ref.cast (ref $arr) (local.get $p\{intToString i})))",
]
jsPushArg _ = []

-- an argument's wasm value (`jsWireParam`)
jsWireArg : (String, Int) -> List String
jsWireArg (head, i) =
  let p = "(local.get $p\{intToString i})"
  match head
    "Unit" => []
    "Int" => ["    (call $mdk_unbox_int \{p})"]
    "Float" => ["    (struct.get $float 0 (ref.cast (ref $float) \{p}))"]
    "Bool" => ["    (i31.get_u (ref.cast (ref i31) \{p}))"]
    "Char" => ["    (i31.get_u (ref.cast (ref i31) \{p}))"]
    "U64" => ["    (struct.get $u64 0 (ref.cast (ref $u64) \{p}))"]
    "I64" => ["    (struct.get $i64 0 (ref.cast (ref $i64) \{p}))"]
    "String" =>
      ["    (array.len (struct.get $str $bytes (ref.cast (ref $str) \{p})))"]
    "Array" => ["    (array.len (ref.cast (ref $arr) \{p}))"]
    _ => ["    (i32.wrap_i64 (call $mdk_unbox_int \{p}))"]

-- an `Array` argument's copy-back from the result channel, at `$off`
jsCopyBack : List String -> (String, Int) -> List String
jsCopyBack trap ("Array", i) =
  [
      "    (local.set $off (call $mdk_jsffi_copy_back (ref.cast (ref $arr) (local.get $p\{intToString i})) (local.get $off)))",
      "    (if (i32.lt_s (local.get $off) (i32.const 0)) (then",
    ]
    ++ map ("      " ++ _) trap
    ++ ["    ))"]
jsCopyBack _ _ = []

-- the result as a Medaka value
jsUnwire : String -> List String -> List String -> List String
jsUnwire "Int" intTrap _ =
  [
      "    (if (i64.ne (i64.shr_s (i64.shl (local.get $r) (i64.const 1)) (i64.const 1)) (local.get $r)) (then",
    ]
    ++ map ("      " ++ _) intTrap
    ++ ["    ))", "    (call $mdk_box_int (local.get $r))"]
jsUnwire "Char" _ charTrap =
  [
      "    (if (i32.eqz (i32.and (i32.lt_u (local.get $r) (i32.const 1114112))",
      "        (i32.or (i32.lt_u (local.get $r) (i32.const 55296)) (i32.gt_u (local.get $r) (i32.const 57343))))) (then",
    ]
    ++ map ("      " ++ _) charTrap
    ++ ["    ))", "    (ref.i31 (local.get $r))"]
jsUnwire "Float" _ _ = ["    (struct.new $float (local.get $r))"]
jsUnwire "Bool" _ _ = ["    (ref.i31 (i32.ne (local.get $r) (i32.const 0)))"]
jsUnwire "U8" _ _ = [
  "    (call $mdk_box_int (i64.extend_i32_u (i32.and (local.get $r) (i32.const 255))))",
]
jsUnwire "U16" _ _ = [
  "    (call $mdk_box_int (i64.extend_i32_u (i32.and (local.get $r) (i32.const 65535))))",
]
jsUnwire "U32" _ _ =
  ["    (call $mdk_box_int (i64.extend_i32_u (local.get $r)))"]
jsUnwire "I32" _ _ =
  ["    (call $mdk_box_int (i64.extend_i32_s (local.get $r)))"]
jsUnwire "U64" _ _ = ["    (struct.new $u64 (local.get $r))"]
jsUnwire "I64" _ _ = ["    (struct.new $i64 (local.get $r))"]
jsUnwire "String" _ _ = ["    (call $mdk_jsffi_result_str (local.get $off))"]
jsUnwire _ _ _ = ["    (ref.i31 (i32.const 0))"]

-- The helpers the reached bindings' wrappers call, each emitted when one of
-- them needs it.  `keys` are the plan's host keys: `rename` already emits
-- `$mdk_push_path_more`.
export
jsffiRuntimeLines : List String -> List JsImport -> List String
jsffiRuntimeLines keys imps =
  let heads = flatMap (imp => imp.params) imps
  let pushMore =
    if anyList isChannelHead heads && not (contains "mdk_rename" keys) then
      ioPushPathMoreLines
    else
      []
  let arrays = if contains "Array" heads then jsffiArrayLines else []
  let strs =
    if anyList (imp => imp.result == "String") imps then
      jsffiResultStrLines
    else
      []
  pushMore ++ arrays ++ strs

-- An `Array Int` argument crosses as 8 little-endian bytes per element, and its
-- copy-back is read the same way.  `$mdk_jsffi_copy_back` checks every word
-- before it writes any, and answers -1 for a word outside `Int`'s 63 bits.
jsffiArrayLines : List String
jsffiArrayLines = [
  "  ;; push an Array Int's elements to the host path buffer, 8 LE bytes each.",
  "  (func $mdk_jsffi_push_ints (param $a (ref $arr))",
  "    (local $i i32) (local $n i32) (local $w i64) (local $k i32)",
  "    (local.set $n (array.len (local.get $a)))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $w (call $mdk_unbox_int (array.get $arr (local.get $a) (local.get $i))))",
  "      (local.set $k (i32.const 0))",
  "      (block $bd (loop $bl",
  "        (br_if $bd (i32.ge_s (local.get $k) (i32.const 8)))",
  "        (call $mdk_path_push (i32.wrap_i64 (i64.and (local.get $w) (i64.const 255))))",
  "        (local.set $w (i64.shr_u (local.get $w) (i64.const 8)))",
  "        (local.set $k (i32.add (local.get $k) (i32.const 1))) (br $bl)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    )",
  "  ;; the 8 LE bytes at $at of the host result buffer, as an i64.",
  "  (func $mdk_jsffi_result_i64 (param $at i32) (result i64)",
  "    (local $k i32) (local $w i64)",
  "    (local.set $k (i32.const 8))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.eqz (local.get $k)))",
  "      (local.set $k (i32.sub (local.get $k) (i32.const 1)))",
  "      (local.set $w (i64.or (i64.shl (local.get $w) (i64.const 8))",
  "        (i64.extend_i32_u (i32.and (call $mdk_result_byte (i32.add (local.get $at) (local.get $k))) (i32.const 255)))))",
  "      (br $l)))",
  "    (local.get $w))",
  "  ;; copy an Array Int argument back from the result buffer at $off: the next",
  "  ;; offset, or -1 with nothing written when a word is outside Int's 63 bits.",
  "  (func $mdk_jsffi_copy_back (param $a (ref $arr)) (param $off i32) (result i32)",
  "    (local $i i32) (local $n i32) (local $w i64)",
  "    (local.set $n (array.len (local.get $a)))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $w (call $mdk_jsffi_result_i64 (i32.add (local.get $off) (i32.shl (local.get $i) (i32.const 3)))))",
  "      (if (i64.ne (i64.shr_s (i64.shl (local.get $w) (i64.const 1)) (i64.const 1)) (local.get $w))",
  "        (then (return (i32.const -1))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d2 (loop $l2",
  "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))",
  "      (array.set $arr (local.get $a) (local.get $i)",
  "        (call $mdk_box_int (call $mdk_jsffi_result_i64 (i32.add (local.get $off) (i32.shl (local.get $i) (i32.const 3))))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))",
  "    (i32.add (local.get $off) (i32.shl (local.get $n) (i32.const 3))))",
]

-- A `String` result: the result buffer from `$off`, past any copy-back words,
-- read as UTF-8 by `$mdk_u8_to_str_lossy`.
jsffiResultStrLines : List String
jsffiResultStrLines = [
  "  ;; the host result buffer from $off to its end, as a $str.",
  "  (func $mdk_jsffi_result_str (param $off i32) (result (ref $str))",
  "    (local $n i32) (local $i i32) (local $buf (ref $u8arr))",
  "    (local.set $n (i32.sub (call $mdk_result_len) (local.get $off)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (array.set $u8arr (local.get $buf) (local.get $i)",
  "        (call $mdk_result_byte (i32.add (local.get $off) (local.get $i))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (call $mdk_u8_to_str_lossy (local.get $buf)))",
]

ioReadFileLines : List String
ioReadFileLines = [
  "  ;; readFile's Err for contents that are not UTF-8: the path, then a fixed ASCII",
  "  ;; suffix, byte-identical to medaka_rt.c mdk_read_file.",
  "  (func $mdk_str_not_utf8 (param $path (ref $str)) (result (ref $str))",
  "    (local $pb (ref $u8arr)) (local $pl i32) (local $sfx (ref $u8arr)) (local $out (ref $u8arr))",
  "    (local.set $pb (struct.get $str $bytes (local.get $path)))",
  "    (local.set $pl (array.len (local.get $pb)))",
  "    (local.set $sfx \{notUtf8SuffixWat})",
  "    (local.set $out (array.new $u8arr (i32.const 0) (i32.add (local.get $pl) (array.len (local.get $sfx)))))",
  "    (array.copy $u8arr $u8arr (local.get $out) (i32.const 0) (local.get $pb) (i32.const 0) (local.get $pl))",
  "    (array.copy $u8arr $u8arr (local.get $out) (local.get $pl) (local.get $sfx) (i32.const 0) (array.len (local.get $sfx)))",
  "    (struct.new $str (i32.add (struct.get $str $cp_count (local.get $path)) (array.len (local.get $sfx))) (local.get $out)))",
  "  ;; readFile : $str path -> Result String String.  1=Ok contents / 0=Err message.",
  "  ;; Contents that are not UTF-8 are an Err naming the path (medaka_rt.c mdk_read_file).",
  "  (func $mdk_read_file_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (local $st i32) (local $buf (ref $u8arr)) (local $c i32)",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (local.set $st (call $mdk_read_file))",
  "    (if (i32.eqz (local.get $st))",
  "      (then (return (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))",
  "    (local.set $buf (call $mdk_io_result_bytes))",
  "    (local.set $c (call $mdk_utf8_valid_count (local.get $buf)))",
  "    (if (result (ref eq)) (i32.ge_s (local.get $c) (i32.const 0))",
  "      (then (struct.new $C_Ok (i32.const 0) (struct.new $str (local.get $c) (local.get $buf))))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_str_not_utf8 (local.get $path))))))",
]

ioFetchTextLines : List String
ioFetchTextLines = [
  "  ;; fetchText : $str url -> Result String String.  1=Ok body / 0=Err message.",
  "  ;; The host import answers with a promise, so under JSPI the guest suspends in the call.",
  "  (func $mdk_fetch_text_io (param $url (ref $str)) (result (ref eq))",
  "    (call $mdk_push_path (local.get $url))",
  "    (if (result (ref eq)) (call $mdk_fetch_text)",
  "      (then (struct.new $C_Ok (i32.const 0) (call $mdk_io_result_to_str)))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"
]

ioFileExistsLines : List String
ioFileExistsLines = [
  "  ;; fileExists : $str path -> Bool (i31 ordinal: False=0 / True=1); 2 = refused.",
  "  (func $mdk_file_exists_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (local $r i32)", "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (local.set $r (call $mdk_file_exists))",
  "    (if (i32.eq (local.get $r) (i32.const 2)) (then (call $mdk_refused_panic)))",
  "    (ref.i31 (local.get $r)))"
]

ioCanonicalizeLines : List String
ioCanonicalizeLines = [
  "  ;; canonicalizePath : $str path -> $str.  1=the host's answer / 0=refused.",
  "  (func $mdk_canonicalize_path_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (if (i32.eqz (call $mdk_canonicalize_path)) (then (call $mdk_refused_panic)))",
  "    (call $mdk_io_result_to_str))"
]

ioWriteFileLines : List String
ioWriteFileLines = [
  "  ;; writeFile : $str path -> $str contents -> Result String Unit.  1=Ok () / 0=Err msg.",
  "  ;; The contents' bytes stream to the host's write buffer, as writeFileBytes streams its array.",
  "  (func $mdk_write_file_io (param $path (ref $str)) (param $s (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (call $mdk_write_file_reset)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0))", "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_write_file_push (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (if (result (ref eq)) (call $mdk_write_file)",
  "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"
]

ioWriteFileModeLines : List String
ioWriteFileModeLines = [
  "  ;; writeFileMode : $str path -> Int mode -> $str contents -> Result String Unit.",
  "  ;; 1=Ok () / 0=Err msg.  The contents stream to the host's write buffer; the host sets",
  "  ;; the file's mode before the first byte is written.",
  "  (func $mdk_write_file_mode_io (param $path (ref $str)) (param $mode (ref eq)) (param $s (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (call $mdk_write_file_reset)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0))", "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_write_file_push (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (if (result (ref eq)) (call $mdk_write_file_mode (i32.wrap_i64 (call $mdk_unbox_int (local.get $mode))))",
  "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"
]

ioAppendFileLines : List String
ioAppendFileLines = [
  "  ;; appendFile : $str path -> $str contents -> Result String Unit.  1=Ok () / 0=Err msg.",
  "  ;; The contents' bytes stream to the host's write buffer; the host appends them.",
  "  (func $mdk_append_file_io (param $path (ref $str)) (param $s (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (call $mdk_write_file_reset)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0))", "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_write_file_push (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (if (result (ref eq)) (call $mdk_append_file)",
  "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"
]

ioRenameLines : List String
ioRenameLines = [
  "  ;; rename : $str src -> $str dst -> src grant -> dst grant -> Result String Unit.",
  "  ;; The grants share the grant channel (-2 ends the first), the paths the path channel;",
  "  ;; the host splits the path buffer at the source's byte length.",
  "  (func $mdk_rename_io (param $src (ref $str)) (param $dst (ref $str)) (param $gs (ref eq)) (param $gd (ref eq)) (result (ref eq))",
  "    (call $mdk_push_grant (local.get $gs))",
  "    (call $mdk_grant_push (i32.const -2))",
  "    (call $mdk_push_grant_more (local.get $gd))",
  "    (call $mdk_push_path (local.get $src))",
  "    (call $mdk_push_path_more (local.get $dst))",
  "    (if (result (ref eq)) (call $mdk_rename (array.len (struct.get $str $bytes (local.get $src))))",
  "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"
]

ioListDirLines : List String
ioListDirLines = [
  "  ;; listDir : $str path -> Result String (List String).  The host answers each entry's",
  "  ;; name followed by a NUL byte; the list is built from the last entry back.",
  "  (func $mdk_list_dir_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (local $buf (ref $u8arr)) (local $name (ref $u8arr)) (local $acc (ref eq))",
  "    (local $pos i32) (local $end i32) (local $k i32)",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (if (i32.eqz (call $mdk_list_dir))",
  "      (then (return (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))",
  "    (local.set $buf (call $mdk_io_result_bytes))",
  "    (local.set $acc (ref.i31 (i32.const 1)))",
  "    (local.set $pos (array.len (local.get $buf)))", "    (block $d (loop $l",
  "      (br_if $d (i32.le_s (local.get $pos) (i32.const 0)))",
  "      (local.set $end (i32.sub (local.get $pos) (i32.const 1)))",
  "      (local.set $k (local.get $end))", "      (block $s (loop $m",
  "        (br_if $s (i32.eqz (local.get $k)))",
  "        (br_if $s (i32.eqz (array.get_u $u8arr (local.get $buf) (i32.sub (local.get $k) (i32.const 1)))))",
  "        (local.set $k (i32.sub (local.get $k) (i32.const 1))) (br $m)))",
  "      (local.set $name (array.new $u8arr (i32.const 0) (i32.sub (local.get $end) (local.get $k))))",
  "      (array.copy $u8arr $u8arr (local.get $name) (i32.const 0) (local.get $buf) (local.get $k) (i32.sub (local.get $end) (local.get $k)))",
  "      (local.set $acc (struct.new $C_Cons (i32.const 0) (call $mdk_u8_to_str_lossy (local.get $name)) (local.get $acc)))",
  "      (local.set $pos (local.get $k)) (br $l)))",
  "    (struct.new $C_Ok (i32.const 0) (local.get $acc)))"
]

ioStatFileLines : List String
ioStatFileLines = [
  "  ;; statFile : $str path -> Result String (Int, Bool, Bool, Float): size, isDir, isFile,",
  "  ;; mtime in seconds.  The host answers each field of the stat it took as an f64.",
  "  (func $mdk_stat_file_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (if (result (ref eq)) (call $mdk_stat_file)",
  "      (then (struct.new $C_Ok (i32.const 0)",
  "        (struct.new $C_Tup4 (i32.const 0)",
  "          (call $mdk_box_int (i64.trunc_f64_s (call $mdk_stat_field (i32.const 0))))",
  "          (ref.i31 (i32.trunc_f64_s (call $mdk_stat_field (i32.const 1))))",
  "          (ref.i31 (i32.trunc_f64_s (call $mdk_stat_field (i32.const 2))))",
  "          (struct.new $float (call $mdk_stat_field (i32.const 3))))))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"
]

ioMakeDirLines : List String
ioMakeDirLines = [
  "  ;; makeDir : $str path -> Result String Unit.  1=Ok () / 0=Err msg.",
  "  (func $mdk_make_dir_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (if (result (ref eq)) (call $mdk_make_dir)",
  "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"
]

ioRemoveFileLines : List String
ioRemoveFileLines = [
  "  ;; removeFile : $str path -> Result String Unit.  1=Ok () / 0=Err msg.",
  "  (func $mdk_remove_file_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (if (result (ref eq)) (call $mdk_remove_file)",
  "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"
]

ioRemoveDirLines : List String
ioRemoveDirLines = [
  "  ;; removeDir : $str path -> Result String Unit.  1=Ok () / 0=Err msg.",
  "  (func $mdk_remove_dir_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (if (result (ref eq)) (call $mdk_remove_dir)",
  "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"
]

ioFsyncLines : List String
ioFsyncLines = [
  "  ;; fsync : $str path -> Result String Unit.  1=Ok () / 0=Err msg.",
  "  (func $mdk_fsync_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (if (result (ref eq)) (call $mdk_fsync)",
  "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"
]

ioFileModeLines : List String
ioFileModeLines = [
  "  ;; fileMode : $str path -> Result String Int: the permission bits, 0 to 4095.  The host",
  "  ;; takes the stat that statFile takes and answers its mode field, field 4.",
  "  (func $mdk_file_mode_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (if (result (ref eq)) (call $mdk_file_mode)",
  "      (then (struct.new $C_Ok (i32.const 0)",
  "        (call $mdk_box_int (i64.trunc_f64_s (call $mdk_stat_field (i32.const 4))))))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"
]

ioGetEnvLines : List String
ioGetEnvLines = [
  "  ;; getEnv : $str name -> Option String.  1=Some value / 0=None.",
  "  (func $mdk_get_env_io (param $name (ref $str)) (result (ref eq))",
  "    (local $st i32)", "    (call $mdk_push_path (local.get $name))",
  "    (local.set $st (call $mdk_get_env))",
  "    (if (result (ref eq)) (local.get $st)",
  "      (then (struct.new $C_Some (i32.const 0) (call $mdk_io_result_to_str)))",
  "      (else (ref.i31 (i32.const 1)))))"
]

ioReadLineLines : List String
ioReadLineLines = [
  "  ;; readLine : Unit -> String.  The host answers 1 with a line (its newline",
  "  ;; stripped) on the result channel, or 0 at end of input, where the channel is empty.",
  "  (func $mdk_read_line_io (result (ref eq))",
  "    (drop (call $mdk_read_line))", "    (call $mdk_io_result_to_str))",
  "  ;; readLineOpt : Unit -> Option String.  0 is None.",
  "  (func $mdk_read_line_opt_io (result (ref eq))",
  "    (if (result (ref eq)) (call $mdk_read_line)",
  "      (then (struct.new $C_Some (i32.const 0) (call $mdk_io_result_to_str)))",
  "      (else (ref.i31 (i32.const 1)))))"
]

ioReadAllLines : List String
ioReadAllLines = [
  "  ;; readAll : Unit -> String.  The rest of the host's stdin buffer.",
  "  (func $mdk_read_all_io (result (ref eq))", "    (call $mdk_read_all)",
  "    (call $mdk_io_result_to_str))"
]

ioReadExactlyLines : List String
ioReadExactlyLines = [
  "  ;; readExactly : Int -> Option String.  1=Some the n bytes / 0=None (end of input",
  "  ;; or a short read, whose bytes the host has consumed).",
  "  (func $mdk_read_exactly_io (param $n i64) (result (ref eq))",
  "    (if (result (ref eq)) (call $mdk_read_exactly (local.get $n))",
  "      (then (struct.new $C_Some (i32.const 0) (call $mdk_io_result_to_str)))",
  "      (else (ref.i31 (i32.const 1)))))"
]

-- executablePath : Unit -> String.  The host's path (always 1) on the result channel.
ioExecutablePathLines : List String
ioExecutablePathLines = [
  "  (func $mdk_executable_path_io (result (ref eq))",
  "    (drop (call $mdk_executable_path))", "    (call $mdk_io_result_to_str))"
]

-- the `args` extern body — split out from ioHostRuntimeLines because it references
-- the cons-list types ($C_Cons / Nil), which are only declared when the program uses
-- a list. Gated on the `mdk_args_count` host key; the `args` extern's catalog
-- demand brings the list types with it.
export
ioArgsRuntimeLines : List String -> List String
ioArgsRuntimeLines keys = gatedOn "mdk_args_count" keys ioArgsLines

ioArgsLines : List String
ioArgsLines = [
  "  ;; build a $str from the i-th host arg (mdk_arg_len(i) + mdk_arg_byte(i,j)).",
  "  (func $mdk_arg_to_str (param $idx i32) (result (ref $str))",
  "    (local $n i32) (local $j i32) (local $buf (ref $u8arr))",
  "    (local.set $n (call $mdk_arg_len (local.get $idx)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (local.set $j (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $j) (local.get $n)))",
  "      (array.set $u8arr (local.get $buf) (local.get $j) (call $mdk_arg_byte (local.get $idx) (local.get $j)))",
  "      (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $l)))",
  "    (call $mdk_u8_to_str_lossy (local.get $buf)))",
  "  ;; args : Unit -> List String.  Fold a Cons chain right-to-left ending in Nil.",
  "  (func $mdk_args_io (result (ref eq))",
  "    (local $c i32) (local $i i32) (local $acc (ref eq))",
  "    (local.set $c (call $mdk_args_count))",
  "    (local.set $acc (ref.i31 (i32.const 1)))",  -- Nil
  "    (local.set $i (i32.sub (local.get $c) (i32.const 1)))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.lt_s (local.get $i) (i32.const 0)))",
  "      (local.set $acc (struct.new $C_Cons (i32.const 0) (call $mdk_arg_to_str (local.get $i)) (local.get $acc)))",
  "      (local.set $i (i32.sub (local.get $i) (i32.const 1))) (br $l)))",
  "    (local.get $acc))",
]

-- ── stage-D: byte-clean file I/O host surface (readFileBytes / writeFileBytes) ─
-- The FILE seam for the bytes-first sqlite lib.  readFileBytes reuses the existing
-- read byte-channel ($mdk_read_file + $mdk_result_len/$mdk_result_byte) but rebuilds
-- an $arr of i31 Int bytes (NOT a UTF-8 $str), so it needs no new host import — only
-- the runtime body ($mdk_read_file_bytes_io).  writeFileBytes is the genuinely NEW
-- direction: three new host imports stream the path (reuse $mdk_push_path) + the byte
-- array OUT to a JS write buffer, then commit a Node `fs.writeFileSync`.  Both return
-- a Result String (…) byte-identical to the native runtime (medaka_rt.c
-- mdk_read_file_bytes / mdk_write_file_bytes).  The write body is gated on the
-- `mdk_write_file_commit` key.  The read body shares its keys with readFile, so
-- it also needs `readsBytes` (the extern's `useFileBytes` demand, which brings $arr).
export
fileBytesRuntimeLines : Bool -> List String -> List String
fileBytesRuntimeLines readsBytes keys =
  gatedOn "mdk_write_file_commit" keys writeFileBytesLines
    ++ gatedOn "mdk_os_entropy" keys osEntropyLines
    ++ (if readsBytes then
      gatedOn "mdk_read_file" keys readFileBytesLines
    else
      [])

readFileBytesLines : List String
readFileBytesLines = [
  "  ;; readFileBytes : $str path -> Result String (Array Int).  1=Ok bytes / 0=Err msg.",
  "  ;; Reuses the read byte-channel but rebuilds an $arr of i31 Int bytes (0..255).",
  "  (func $mdk_read_file_bytes_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))",
  "    (local $st i32) (local $n i32) (local $i i32) (local $out (ref $arr))",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (local.set $st (call $mdk_read_file))",
  "    (if (result (ref eq)) (local.get $st)", "      (then",
  "        (local.set $n (call $mdk_result_len))",
  "        (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))",
  "        (local.set $i (i32.const 0))", "        (block $d (loop $l",
  "          (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "          (array.set $arr (local.get $out) (local.get $i) (ref.i31 (call $mdk_result_byte (local.get $i))))",
  "          (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "        (struct.new $C_Ok (i32.const 0) (local.get $out)))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"
]

-- osEntropyBytes : Int -> Array Int.  The host fills the result channel with n random
-- bytes, or refuses a negative or oversized count with its panic text on the channel,
-- which $mdk_refused_panic writes as the E-PANIC line.  Built like readFileBytes's array.
osEntropyLines : List String
osEntropyLines = [
  "  ;; osEntropyBytes : Int -> Array Int.  1=n random bytes / 0=a refusal (its text on the channel).",
  "  (func $mdk_os_entropy_io (param $n i64) (result (ref eq))",
  "    (local $len i32) (local $i i32) (local $out (ref $arr))",
  "    (if (i32.eqz (call $mdk_os_entropy (local.get $n))) (then (call $mdk_refused_panic)))",
  "    (local.set $len (call $mdk_result_len))",
  "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $len)))",
  "    (local.set $i (i32.const 0))", "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $len)))",
  "      (array.set $arr (local.get $out) (local.get $i) (ref.i31 (call $mdk_result_byte (local.get $i))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (local.get $out))"
]

writeFileBytesLines : List String
writeFileBytesLines = [
  "  ;; writeFileBytes : $str path -> $arr bytes -> Result String Unit.  1=Ok () / 0=Err msg.",
  "  ;; Stream each i31 byte (masked to 0..255) to the host, then commit fs.writeFileSync.",
  "  (func $mdk_write_file_bytes_io (param $path (ref $str)) (param $ba (ref $arr)) (param $g (ref eq)) (result (ref eq))",
  "    (local $st i32) (local $n i32) (local $i i32)",
  "    (call $mdk_push_grant (local.get $g))",
  "    (call $mdk_push_path (local.get $path))",
  "    (call $mdk_write_file_reset)",
  "    (local.set $n (array.len (local.get $ba)))",
  "    (local.set $i (i32.const 0))", "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (call $mdk_write_file_push (i32.and (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $ba) (local.get $i)))) (i32.const 255)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (local.set $st (call $mdk_write_file_commit))",
  "    (if (result (ref eq)) (local.get $st)",
  "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))",
  "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"
]

-- ── W8b string index-of / compare ($str-dependent) ───────────────────────────
-- $mdk_str_index_of(needle, hay) -> Option Int (ref eq): the first BYTE-level match's
-- codepoint index as `Some idx`, or `None` if absent (empty needle -> Some 0).  Builds
-- the reserved Option ctors directly: None = `ref.i31 1`, Some = struct.new $C_Some
-- (tag 0 + the i31 index).  ($C_Some / the Option root are emitted unconditionally in
-- ref-mode.)  $mdk_str_compare(a, b) -> Ordering (ref eq): memcmp the common prefix,
-- tie-break by length, return Lt/Eq/Gt (i31 0/1/2).  Both byte-identical to medaka_rt.c
-- (mdk_string_index_of / mdk_string_compare).  Needs $mdk_cp_count from strLeafRuntime.
export
strSearchRuntimeLines : List String
strSearchRuntimeLines = [
  "  ;; -- W8b stringIndexOf / stringCompare (byte-identical to medaka_rt.c) --",
  "  (func $mdk_str_index_of (param $needle (ref $str)) (param $hay (ref $str)) (result (ref eq))",
  "    (local $nb (ref $u8arr)) (local $hb (ref $u8arr)) (local $nl i32) (local $hl i32)",
  "    (local $b i32) (local $j i32) (local $ok i32)",
  "    (local.set $nb (struct.get $str $bytes (local.get $needle)))",
  "    (local.set $hb (struct.get $str $bytes (local.get $hay)))",
  "    (local.set $nl (array.len (local.get $nb)))",
  "    (local.set $hl (array.len (local.get $hb)))",
  "    ;; empty needle -> Some 0 (codepoint index 0).",
  "    (if (i32.eqz (local.get $nl))",
  "      (then (return (struct.new $C_Some (i32.const 0) (ref.i31 (i32.const 0))))))",
  "    (local.set $b (i32.const 0))",
  "    (block $done (loop $scan",
  "      ;; while b + nl <= hl",
  "      (br_if $done (i32.gt_s (i32.add (local.get $b) (local.get $nl)) (local.get $hl)))",
  "      (local.set $ok (i32.const 1))",
  "      (local.set $j (i32.const 0))",
  "      (block $cmpd (loop $cmpl",
  "        (br_if $cmpd (i32.ge_s (local.get $j) (local.get $nl)))",
  "        (if (i32.ne (array.get_u $u8arr (local.get $hb) (i32.add (local.get $b) (local.get $j)))",
  "                    (array.get_u $u8arr (local.get $nb) (local.get $j)))",
  "          (then (local.set $ok (i32.const 0)) (br $cmpd)))",
  "        (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $cmpl)))",
  "      (if (local.get $ok)",
  "        (then (return (struct.new $C_Some (i32.const 0)",
  "          (ref.i31 (call $mdk_cp_count (local.get $hb) (local.get $b)))))))",
  "      (local.set $b (i32.add (local.get $b) (i32.const 1))) (br $scan)))",
  "    ;; not found -> None (i31 ordinal 1).",
  "    (ref.i31 (i32.const 1)))",
  "  ;; -- W8c byte-level count / last-index (byte-identical to medaka_rt.c) --",
  "  ;; non-overlapping occurrences; 0 for an empty needle.",
  "  (func $mdk_str_count_occ (param $n (ref $str)) (param $h (ref $str)) (result i32)",
  "    (local $nb (ref $u8arr)) (local $hb (ref $u8arr)) (local $nl i32) (local $hl i32)",
  "    (local $b i32) (local $c i32)",
  "    (local.set $nb (struct.get $str $bytes (local.get $n)))",
  "    (local.set $hb (struct.get $str $bytes (local.get $h)))",
  "    (local.set $nl (array.len (local.get $nb)))",
  "    (local.set $hl (array.len (local.get $hb)))",
  "    (if (i32.eqz (local.get $nl)) (then (return (i32.const 0))))",
  "    (block $done (loop $scan",
  "      (br_if $done (i32.gt_s (i32.add (local.get $b) (local.get $nl)) (local.get $hl)))",
  "      (if (call $mdk_bytes_match_at (local.get $nb) (local.get $hb) (local.get $b))",
  "        (then",
  "          (local.set $c (i32.add (local.get $c) (i32.const 1)))",
  "          (local.set $b (i32.add (local.get $b) (local.get $nl))))",
  "        (else (local.set $b (i32.add (local.get $b) (i32.const 1)))))",
  "      (br $scan)))",
  "    (local.get $c))",
  "  ;; overlapping occurrences, the last one wins; an empty needle is at the codepoint end.",
  "  (func $mdk_str_last_index_of (param $n (ref $str)) (param $h (ref $str)) (result (ref eq))",
  "    (local $nb (ref $u8arr)) (local $hb (ref $u8arr)) (local $nl i32) (local $hl i32)",
  "    (local $b i32) (local $last i32)",
  "    (local.set $nb (struct.get $str $bytes (local.get $n)))",
  "    (local.set $hb (struct.get $str $bytes (local.get $h)))",
  "    (local.set $nl (array.len (local.get $nb)))",
  "    (local.set $hl (array.len (local.get $hb)))",
  "    (if (i32.eqz (local.get $nl))",
  "      (then (return (struct.new $C_Some (i32.const 0)",
  "        (ref.i31 (struct.get $str $cp_count (local.get $h)))))))",
  "    (local.set $last (i32.const -1))",
  "    (block $done (loop $scan",
  "      (br_if $done (i32.gt_s (i32.add (local.get $b) (local.get $nl)) (local.get $hl)))",
  "      (if (call $mdk_bytes_match_at (local.get $nb) (local.get $hb) (local.get $b))",
  "        (then (local.set $last (local.get $b))))",
  "      (local.set $b (i32.add (local.get $b) (i32.const 1)))",
  "      (br $scan)))",
  "    (if (i32.lt_s (local.get $last) (i32.const 0))",
  "      (then (return (ref.i31 (i32.const 1)))))",
  "    (struct.new $C_Some (i32.const 0)",
  "      (ref.i31 (call $mdk_cp_count (local.get $hb) (local.get $last)))))",
  "  (func $mdk_str_compare (param $a (ref $str)) (param $b (ref $str)) (result (ref eq))",
  "    (local $ab (ref $u8arr)) (local $bb (ref $u8arr)) (local $al i32) (local $bl i32)",
  "    (local $m i32) (local $i i32) (local $ca i32) (local $cb i32)",
  "    (local.set $ab (struct.get $str $bytes (local.get $a)))",
  "    (local.set $bb (struct.get $str $bytes (local.get $b)))",
  "    (local.set $al (array.len (local.get $ab)))",
  "    (local.set $bl (array.len (local.get $bb)))",
  "    (local.set $m (if (result i32) (i32.lt_s (local.get $al) (local.get $bl))",
  "      (then (local.get $al)) (else (local.get $bl))))",
  "    (local.set $i (i32.const 0))",
  "    (block $done (loop $l",
  "      (br_if $done (i32.ge_s (local.get $i) (local.get $m)))",
  "      (local.set $ca (array.get_u $u8arr (local.get $ab) (local.get $i)))",
  "      (local.set $cb (array.get_u $u8arr (local.get $bb) (local.get $i)))",
  "      ;; byte less -> Lt (i31 0); byte greater -> Gt (i31 2).",
  "      (if (i32.lt_u (local.get $ca) (local.get $cb)) (then (return (ref.i31 (i32.const 0)))))",
  "      (if (i32.gt_u (local.get $ca) (local.get $cb)) (then (return (ref.i31 (i32.const 2)))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    ;; common prefix equal: shorter < longer; equal length -> Eq.",
  "    (if (i32.lt_s (local.get $al) (local.get $bl)) (then (return (ref.i31 (i32.const 0)))))",
  "    (if (i32.gt_s (local.get $al) (local.get $bl)) (then (return (ref.i31 (i32.const 2)))))",
  "    (ref.i31 (i32.const 1)))",
]

-- ── UTF-8 validation: bytes from outside the program into a $str ─────────────
-- Every $str holds well-formed UTF-8, as every native String cell does.  These
-- are the WasmGC peers of medaka_rt.c's mdk_utf8_step / mdk_utf8_valid_count /
-- mdk_str_lossy, byte-identical on every input:
--   $mdk_utf8_step        : the width (1..4) of the well-formed sequence at $i, or
--     the negated width of its maximal ill-formed subpart.
--   $mdk_utf8_valid_count : the codepoint count of a $u8arr, or -1 when any
--     sequence in it is ill-formed.
--   $mdk_u8_to_str_lossy  : a FRESH, unaliased $u8arr as a $str; each ill-formed
--     subpart becomes U+FFFD (bytes ef bf bd), as `bytes.decodeUtf8Lossy` does.
-- Emitted whenever a producer of outside bytes is: the byte codec (useStrCodec),
-- `byteBlockToString` (useByteBlock), and the IO host surface (useIO).
export
utf8LossyRuntimeLines : List String
utf8LossyRuntimeLines = [
  "  ;; -- UTF-8 validation (byte-identical to medaka_rt.c mdk_str_lossy) --",
  "  (func $mdk_utf8_step (param $b (ref $u8arr)) (param $i i32) (param $n i32) (result i32)",
  "    (local $b0 i32) (local $b1 i32) (local $lo i32) (local $hi i32)",
  "    (local.set $b0 (array.get_u $u8arr (local.get $b) (local.get $i)))",
  "    (if (i32.lt_u (local.get $b0) (i32.const 128)) (then (return (i32.const 1))))",
  "    (if (i32.and (i32.ge_u (local.get $b0) (i32.const 194)) (i32.le_u (local.get $b0) (i32.const 223)))",
  "      (then",
  "        (if (i32.lt_s (i32.add (local.get $i) (i32.const 1)) (local.get $n))",
  "          (then (if (i32.eq (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $i) (i32.const 1))) (i32.const 192)) (i32.const 128))",
  "            (then (return (i32.const 2))))))",
  "        (return (i32.const -1))))",
  "    (if (i32.or (i32.lt_u (local.get $b0) (i32.const 224)) (i32.gt_u (local.get $b0) (i32.const 244)))",
  "      (then (return (i32.const -1))))",
  "    ;; E0 and F0 bound the second byte below (overlong), ED and F4 above.",
  "    (local.set $lo (select (i32.const 160) (select (i32.const 144) (i32.const 128) (i32.eq (local.get $b0) (i32.const 240))) (i32.eq (local.get $b0) (i32.const 224))))",
  "    (local.set $hi (select (i32.const 159) (select (i32.const 143) (i32.const 191) (i32.eq (local.get $b0) (i32.const 244))) (i32.eq (local.get $b0) (i32.const 237))))",
  "    (if (i32.ge_s (i32.add (local.get $i) (i32.const 1)) (local.get $n)) (then (return (i32.const -1))))",
  "    (local.set $b1 (array.get_u $u8arr (local.get $b) (i32.add (local.get $i) (i32.const 1))))",
  "    (if (i32.or (i32.lt_u (local.get $b1) (local.get $lo)) (i32.gt_u (local.get $b1) (local.get $hi)))",
  "      (then (return (i32.const -1))))",
  "    (if (i32.ge_s (i32.add (local.get $i) (i32.const 2)) (local.get $n)) (then (return (i32.const -2))))",
  "    (if (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $i) (i32.const 2))) (i32.const 192)) (i32.const 128))",
  "      (then (return (i32.const -2))))",
  "    (if (i32.lt_u (local.get $b0) (i32.const 240)) (then (return (i32.const 3))))",
  "    (if (i32.ge_s (i32.add (local.get $i) (i32.const 3)) (local.get $n)) (then (return (i32.const -3))))",
  "    (if (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $i) (i32.const 3))) (i32.const 192)) (i32.const 128))",
  "      (then (return (i32.const -3))))",
  "    (i32.const 4))",
  "  (func $mdk_utf8_valid_count (param $b (ref $u8arr)) (result i32)",
  "    (local $n i32) (local $i i32) (local $c i32) (local $st i32)",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $i (i32.const 0)) (local.set $c (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $st (call $mdk_utf8_step (local.get $b) (local.get $i) (local.get $n)))",
  "      (if (i32.lt_s (local.get $st) (i32.const 0)) (then (return (i32.const -1))))",
  "      (local.set $i (i32.add (local.get $i) (local.get $st)))",
  "      (local.set $c (i32.add (local.get $c) (i32.const 1))) (br $l)))",
  "    (local.get $c))",
  "  (func $mdk_u8_to_str_lossy (param $b (ref $u8arr)) (result (ref $str))",
  "    (local $n i32) (local $i i32) (local $j i32) (local $c i32) (local $st i32) (local $out i32)",
  "    (local $buf (ref $u8arr))",
  "    (local.set $c (call $mdk_utf8_valid_count (local.get $b)))",
  "    (if (i32.ge_s (local.get $c) (i32.const 0))",
  "      (then (return (struct.new $str (local.get $c) (local.get $b)))))",
  "    (local.set $n (array.len (local.get $b)))",
  "    ;; pass 1: the output length, 3 bytes per replacement.",
  "    (local.set $i (i32.const 0)) (local.set $out (i32.const 0))",
  "    (block $d1 (loop $l1",
  "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $st (call $mdk_utf8_step (local.get $b) (local.get $i) (local.get $n)))",
  "      (if (i32.gt_s (local.get $st) (i32.const 0))",
  "        (then",
  "          (local.set $out (i32.add (local.get $out) (local.get $st)))",
  "          (local.set $i (i32.add (local.get $i) (local.get $st))))",
  "        (else",
  "          (local.set $out (i32.add (local.get $out) (i32.const 3)))",
  "          (local.set $i (i32.sub (local.get $i) (local.get $st)))))",
  "      (br $l1)))",
  "    ;; pass 2: copy each well-formed sequence, U+FFFD for each subpart.",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $out)))",
  "    (local.set $i (i32.const 0)) (local.set $j (i32.const 0)) (local.set $c (i32.const 0))",
  "    (block $d2 (loop $l2",
  "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $st (call $mdk_utf8_step (local.get $b) (local.get $i) (local.get $n)))",
  "      (if (i32.gt_s (local.get $st) (i32.const 0))",
  "        (then",
  "          (array.copy $u8arr $u8arr (local.get $buf) (local.get $j) (local.get $b) (local.get $i) (local.get $st))",
  "          (local.set $j (i32.add (local.get $j) (local.get $st)))",
  "          (local.set $i (i32.add (local.get $i) (local.get $st))))",
  "        (else",
  "          (array.set $u8arr (local.get $buf) (local.get $j) (i32.const 239))",
  "          (array.set $u8arr (local.get $buf) (i32.add (local.get $j) (i32.const 1)) (i32.const 191))",
  "          (array.set $u8arr (local.get $buf) (i32.add (local.get $j) (i32.const 2)) (i32.const 189))",
  "          (local.set $j (i32.add (local.get $j) (i32.const 3)))",
  "          (local.set $i (i32.sub (local.get $i) (local.get $st)))))",
  "      (local.set $c (i32.add (local.get $c) (i32.const 1))) (br $l2)))",
  "    (struct.new $str (local.get $c) (local.get $buf)))",
]

-- ── W11b UTF-8 codec: stringToChars / stringFromChars ($str <-> Array Char) ──────
-- Byte-identical to medaka_rt.c (mdk_string_to_chars / mdk_string_from_chars +
-- mdk_utf8_decode / mdk_utf8_encode).  A Char is an i31 codepoint; an `Array Char` is
-- the §3.3 $arr = (array (mut (ref eq))) holding `cp_count` i31s.  Emitted when the
-- program uses stringToChars/stringFromChars (`WasmEmit.useStrCodec`); needs the $str rep
-- ($u8arr) AND the $arr rep (both demanded with it in the catalog).
--   $mdk_str_to_chars : decode each UTF-8 codepoint (lead byte <0x80 → 1B; <0xE0 → 2B
--     & 0x1F; <0xF0 → 3B & 0x0F; else 4B & 0x07; each continuation byte & 0x3F, shift
--     << 6 and OR), pushing `ref.i31 cp` into a fresh $arr of length cp_count.
--   $mdk_utf8_nbytes : bytes a codepoint encodes to (1..4) — the encoder's pass-1.
--   $mdk_chars_to_str : two-pass — sum encoded byte length, alloc $u8arr, encode each
--     codepoint in place (same lead/continuation masks as $mdk_char_to_str), cp_count
--     = array.len.
export
strCodecRuntimeLines : List String
strCodecRuntimeLines = [
  "  ;; -- W11b UTF-8 codec (byte-identical to medaka_rt.c) --",
  "  ;; decode a $str's UTF-8 bytes into a fresh $arr of cp_count i31 Char codepoints.",
  "  (func $mdk_str_to_chars (param $s (ref $str)) (result (ref $arr))",
  "    (local $b (ref $u8arr)) (local $n i32) (local $cpc i32) (local $out (ref $arr))",
  "    (local $bo i32) (local $oi i32) (local $lead i32) (local $cp i32) (local $k i32) (local $w i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $cpc (struct.get $str $cp_count (local.get $s)))",
  "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $cpc)))",
  "    (local.set $bo (i32.const 0)) (local.set $oi (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $bo) (local.get $n)))",
  "      ;; the output holds cp_count codepoints; never step past it.",
  "      (br_if $d (i32.ge_s (local.get $oi) (local.get $cpc)))",
  "      (local.set $lead (array.get_u $u8arr (local.get $b) (local.get $bo)))",
  "      ;; lead-byte class → codepoint seed bits + total byte width.",
  "      (if (i32.lt_u (local.get $lead) (i32.const 128))",
  "        (then (local.set $cp (local.get $lead)) (local.set $w (i32.const 1)))",
  "        (else (if (i32.lt_u (local.get $lead) (i32.const 224))",
  "          (then (local.set $cp (i32.and (local.get $lead) (i32.const 31))) (local.set $w (i32.const 2)))",
  "          (else (if (i32.lt_u (local.get $lead) (i32.const 240))",
  "            (then (local.set $cp (i32.and (local.get $lead) (i32.const 15))) (local.set $w (i32.const 3)))",
  "            (else (local.set $cp (i32.and (local.get $lead) (i32.const 7))) (local.set $w (i32.const 4))))))))",
  "      ;; a sequence never reads past the backing's end.",
  "      (if (i32.gt_s (local.get $w) (i32.sub (local.get $n) (local.get $bo)))",
  "        (then (local.set $w (i32.sub (local.get $n) (local.get $bo)))))",
  "      ;; fold in (w-1) continuation bytes: cp = (cp << 6) | (byte & 0x3F).",
  "      (local.set $k (i32.const 1))",
  "      (block $cd (loop $cl",
  "        (br_if $cd (i32.ge_s (local.get $k) (local.get $w)))",
  "        (local.set $cp (i32.or (i32.shl (local.get $cp) (i32.const 6))",
  "          (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $bo) (local.get $k))) (i32.const 63))))",
  "        (local.set $k (i32.add (local.get $k) (i32.const 1))) (br $cl)))",
  "      (array.set $arr (local.get $out) (local.get $oi) (ref.i31 (local.get $cp)))",
  "      (local.set $oi (i32.add (local.get $oi) (i32.const 1)))",
  "      (local.set $bo (i32.add (local.get $bo) (local.get $w))) (br $l)))",
  "    (local.get $out))",
  "  ;; number of UTF-8 bytes a codepoint encodes to (1..4).",
  "  (func $mdk_utf8_nbytes (param $cp i32) (result i32)",
  "    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 128)) (then (i32.const 1))",
  "      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 2048)) (then (i32.const 2))",
  "        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 65536)) (then (i32.const 3))",
  "          (else (i32.const 4))))))))",
  "  ;; encode one codepoint into $buf at offset $off; return the next offset.",
  "  (func $mdk_utf8_emit_at (param $buf (ref $u8arr)) (param $off i32) (param $cp i32) (result i32)",
  "    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 128))",
  "      (then",
  "        (array.set $u8arr (local.get $buf) (local.get $off) (local.get $cp))",
  "        (i32.add (local.get $off) (i32.const 1)))",
  "      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 2048))",
  "        (then",
  "          (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))",
  "          (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))",
  "          (i32.add (local.get $off) (i32.const 2)))",
  "        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 65536))",
  "          (then",
  "            (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))",
  "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))",
  "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 2)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))",
  "            (i32.add (local.get $off) (i32.const 3)))",
  "          (else",
  "            (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))",
  "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))",
  "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 2)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))",
  "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 3)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))",
  "            (i32.add (local.get $off) (i32.const 4))))))))",
  "  )",
  "  ;; encode an $arr of i31 Char codepoints into a fresh $str (UTF-8); cp_count = len.",
  "  (func $mdk_chars_to_str (param $a (ref $arr)) (result (ref $str))",
  "    (local $n i32) (local $i i32) (local $total i32) (local $off i32)",
  "    (local $buf (ref $u8arr)) (local $cp i32)",
  "    (local.set $n (array.len (local.get $a)))",
  "    ;; pass 1: total encoded byte length.",
  "    (local.set $i (i32.const 0)) (local.set $total (i32.const 0))",
  "    (block $d1 (loop $l1",
  "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $cp (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))))",
  "      (local.set $total (i32.add (local.get $total) (call $mdk_utf8_nbytes (local.get $cp))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))",
  "    ;; pass 2: encode into the buffer.",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))",
  "    (local.set $i (i32.const 0)) (local.set $off (i32.const 0))",
  "    (block $d2 (loop $l2",
  "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))",
  "      (local.set $cp (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))))",
  "      (local.set $off (call $mdk_utf8_emit_at (local.get $buf) (local.get $off) (local.get $cp)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))",
  "    (struct.new $str (local.get $n) (local.get $buf)))",
  "  ;; stringToUtf8Bytes: copy the $str's $u8arr backing into a fresh $arr of i31 Int bytes.",
  "  (func $mdk_str_to_utf8_bytes (param $s (ref $str)) (result (ref $arr))",
  "    (local $b (ref $u8arr)) (local $n i32) (local $out (ref $arr)) (local $i i32)",
  "    (local.set $b (struct.get $str $bytes (local.get $s)))",
  "    (local.set $n (array.len (local.get $b)))",
  "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (array.set $arr (local.get $out) (local.get $i) (ref.i31 (array.get_u $u8arr (local.get $b) (local.get $i))))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (local.get $out))",
  "  ;; stringFromUtf8Bytes: blit the low 8 bits of each i31 Int into a $u8arr, read",
  "  ;; as UTF-8 by $mdk_u8_to_str_lossy (medaka_rt.c mdk_string_from_utf8_bytes).",
  "  (func $mdk_utf8_bytes_to_str (param $a (ref $arr)) (result (ref $str))",
  "    (local $n i32) (local $buf (ref $u8arr)) (local $i i32)",
  "    (local.set $n (array.len (local.get $a)))",
  "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
  "    (local.set $i (i32.const 0))",
  "    (block $d (loop $l",
  "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
  "      (array.set $u8arr (local.get $buf) (local.get $i)",
  "        (i32.and (i31.get_u (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))) (i32.const 255)))",
  "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
  "    (call $mdk_u8_to_str_lossy (local.get $buf)))",
]

-- ── the `ByteBlock` builtin's byte-block runtime ─────────────────────────────
-- A ByteBlock IS a bare `$u8arr` — the same packed byte array that backs a $str,
-- not a second packed representation.  Where the native cell needs a [tag |
-- count | bytes] header (medaka_rt.c), WasmGC discriminates by nominal type and
-- `array.len` already carries the count, so the block needs neither: `$u8arr` is
-- to `ByteBlock` what `$arr` is to `Array`.  The element domain is 0..255 by
-- representation — an i8 slot keeps the low eight bits of any store, which is
-- what the native `(unsigned char)(v >> 1)` truncation does, and `array.get_u`
-- zero-extends, so a read is always in range.
-- Gated by `WasmEmit.useByteBlock`, which also forces useStr ($u8arr/$str) and
-- useArray ($arr), the two reps these bodies name.
export
byteBlockRuntimeLines : List String
byteBlockRuntimeLines =
  [
      "  ;; -- the `ByteBlock` builtin (peer of the mdk_byteblock_* C helpers) --",
      "  ;; byteBlockCopyUnsafe: the first $n bytes into a FRESH block.  A COPY, never a",
      "  ;; view: this is freeze's engine half, so a later write to the source must not",
      "  ;; reach the result (matching mdk_byteblock_copy's memcpy).",
      "  (func $mdk_bb_copy (param $n i32) (param $b (ref $u8arr)) (result (ref $u8arr))",
      "    (local $out (ref $u8arr))",
      "    (local.set $out (array.new $u8arr (i32.const 0) (local.get $n)))",
      "    (array.copy $u8arr $u8arr (local.get $out) (i32.const 0) (local.get $b) (i32.const 0) (local.get $n))",
      "    (local.get $out))",
      "  ;; byteBlockFromIntArray: the low eight bits of each element.  Unboxes through",
      "  ;; $mdk_unbox_int rather than the i31 fast path so an element outside the i31",
      "  ;; range (a $boxint) masks instead of trapping -- native has no boxed Int, so",
      "  ;; the i31-only route would diverge on exactly those elements.",
      "  (func $mdk_bb_from_int_array (param $a (ref $arr)) (result (ref $u8arr))",
      "    (local $n i32) (local $out (ref $u8arr)) (local $i i32)",
      "    (local.set $n (array.len (local.get $a)))",
      "    (local.set $out (array.new $u8arr (i32.const 0) (local.get $n)))",
      "    (local.set $i (i32.const 0))",
      "    (block $d (loop $l",
      "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
      "      (array.set $u8arr (local.get $out) (local.get $i)",
      "        (i32.and (i32.wrap_i64 (call $mdk_unbox_int (ref.as_non_null (array.get $arr (local.get $a) (local.get $i))))) (i32.const 255)))",
      "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
      "    (local.get $out))",
      "  ;; byteBlockToIntArray: each byte as an Int in 0..255 (array.get_u zero-extends).",
      "  (func $mdk_bb_to_int_array (param $b (ref $u8arr)) (result (ref $arr))",
      "    (local $n i32) (local $out (ref $arr)) (local $i i32)",
      "    (local.set $n (array.len (local.get $b)))",
      "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))",
      "    (local.set $i (i32.const 0))",
      "    (block $d (loop $l",
      "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
      "      (array.set $arr (local.get $out) (local.get $i) (ref.i31 (array.get_u $u8arr (local.get $b) (local.get $i))))",
      "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
      "    (local.get $out))",
      "  ;; byteBlockFromString: the string's UTF-8 bytes, COPIED.  A $str's backing is",
      "  ;; shared by every reference to that string and a block is mutable, so handing",
      "  ;; the backing back unaliased would let a write edit the string.",
      "  (func $mdk_bb_from_string (param $s (ref $str)) (result (ref $u8arr))",
      "    (local $b (ref $u8arr)) (local $n i32) (local $out (ref $u8arr))",
      "    (local.set $b (struct.get $str $bytes (local.get $s)))",
      "    (local.set $n (array.len (local.get $b)))",
      "    (local.set $out (array.new $u8arr (i32.const 0) (local.get $n)))",
      "    (array.copy $u8arr $u8arr (local.get $out) (i32.const 0) (local.get $b) (i32.const 0) (local.get $n))",
      "    (local.get $out))",
      "  ;; byteBlockToString: the block's bytes as a fresh $str.  The backing is COPIED",
      "  ;; because a block is mutable and a $str's bytes are shared by every reference to",
      "  ;; it; the copy is then read as UTF-8 by $mdk_u8_to_str_lossy, the same route as",
      "  ;; $mdk_utf8_bytes_to_str and medaka_rt.c's mdk_byteblock_to_string.",
      "  (func $mdk_bb_to_string (param $b (ref $u8arr)) (result (ref $str))",
      "    (local $n i32) (local $buf (ref $u8arr))",
      "    (local.set $n (array.len (local.get $b)))",
      "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))",
      "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $b) (i32.const 0) (local.get $n))",
      "    (call $mdk_u8_to_str_lossy (local.get $buf)))",
      "  ;; byteBlockWriteStdout: write the block's bytes to stdout byte-for-byte, no",
      "  ;; encoding assumption -- unlike $mdk_print_str, there is no $str/cp_count to",
      "  ;; read, just the raw $u8arr length.",
      "  (func $mdk_bb_write_stdout (param $b (ref $u8arr))",
      "    (local $i i32) (local $n i32)",
      "    (local.set $n (array.len (local.get $b)))",
      "    (local.set $i (i32.const 0))",
      "    (block $d (loop $l",
      "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))",
      "      (call $mdk_write_byte (array.get_u $u8arr (local.get $b) (local.get $i)))",
      "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))",
    ]
    ++ sha256RuntimeLines

-- FIPS 180-4 section 4.2.2 round constants K[0..63].
sha256K : List Int
sha256K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]

-- WasmGC has no constant table of i32 words here, so K is a `br_table` over 64
-- nested blocks: case k falls out of block $ck into `(return K[k])`.
shaLabel : Int -> String
shaLabel j = "$c\{intToString j}"

sha256KLines : List String
sha256KLines =
  ["  (func $mdk_sha_k (param $i i32) (result i32)"]
    ++ map (j => "    (block $c\{intToString (63 - j)}") [0..=63]
    ++ [
      "    (br_table "
        ++ joinWith " " (map shaLabel [0..=63])
        ++ " $c63 (local.get $i))",
    ]
    ++ flatMap
      (kc => ["    )", "    (return (i32.const \{intToString kc}))"])
      sha256K
    ++ ["  )"]

-- sha256Native (mdk_sha256 in medaka_rt.c).  State and message schedule live in
-- $u8arr scratch blocks holding little-endian 32-bit words, read and written
-- through $mdk_sha_get / $mdk_sha_set; the message itself is read big-endian.
sha256RuntimeLines : List String
sha256RuntimeLines =
  [
      "  ;; -- sha256Native (peer of medaka_rt.c mdk_sha256) --",
      "  (func $mdk_sha_get (param $a (ref $u8arr)) (param $i i32) (result i32)",
      "    (local $o i32)",
      "    (local.set $o (i32.shl (local.get $i) (i32.const 2)))",
      "    (i32.or",
      "      (i32.or (array.get_u $u8arr (local.get $a) (local.get $o))",
      "              (i32.shl (array.get_u $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 1))) (i32.const 8)))",
      "      (i32.or (i32.shl (array.get_u $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 2))) (i32.const 16))",
      "              (i32.shl (array.get_u $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 3))) (i32.const 24)))))",
      "  (func $mdk_sha_set (param $a (ref $u8arr)) (param $i i32) (param $v i32)",
      "    (local $o i32)",
      "    (local.set $o (i32.shl (local.get $i) (i32.const 2)))",
      "    (array.set $u8arr (local.get $a) (local.get $o) (local.get $v))",
      "    (array.set $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 1)) (i32.shr_u (local.get $v) (i32.const 8)))",
      "    (array.set $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 2)) (i32.shr_u (local.get $v) (i32.const 16)))",
      "    (array.set $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 3)) (i32.shr_u (local.get $v) (i32.const 24))))",
    ]
    ++ sha256KLines
    ++ [
      "  ;; One 64-byte block of $src at $off folded into the state $h; $w is the 256-byte schedule scratch.",
      "  (func $mdk_sha_block (param $h (ref $u8arr)) (param $src (ref $u8arr)) (param $off i32) (param $w (ref $u8arr))",
      "    (local $i i32) (local $p i32) (local $x i32) (local $s0 i32) (local $s1 i32)",
      "    (local $a i32) (local $b i32) (local $c i32) (local $d i32) (local $e i32) (local $f i32) (local $g i32) (local $hh i32)",
      "    (local $t1 i32) (local $t2 i32)",
      "    (local.set $i (i32.const 0))",
      "    (block $d1 (loop $l1",
      "      (br_if $d1 (i32.ge_u (local.get $i) (i32.const 16)))",
      "      (local.set $p (i32.add (local.get $off) (i32.shl (local.get $i) (i32.const 2))))",
      "      (call $mdk_sha_set (local.get $w) (local.get $i)",
      "        (i32.or",
      "          (i32.or (i32.shl (array.get_u $u8arr (local.get $src) (local.get $p)) (i32.const 24))",
      "                  (i32.shl (array.get_u $u8arr (local.get $src) (i32.add (local.get $p) (i32.const 1))) (i32.const 16)))",
      "          (i32.or (i32.shl (array.get_u $u8arr (local.get $src) (i32.add (local.get $p) (i32.const 2))) (i32.const 8))",
      "                  (array.get_u $u8arr (local.get $src) (i32.add (local.get $p) (i32.const 3))))))",
      "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))",
      "    (block $d2 (loop $l2",
      "      (br_if $d2 (i32.ge_u (local.get $i) (i32.const 64)))",
      "      (local.set $x (call $mdk_sha_get (local.get $w) (i32.sub (local.get $i) (i32.const 15))))",
      "      (local.set $s0 (i32.xor (i32.xor (i32.rotr (local.get $x) (i32.const 7)) (i32.rotr (local.get $x) (i32.const 18))) (i32.shr_u (local.get $x) (i32.const 3))))",
      "      (local.set $x (call $mdk_sha_get (local.get $w) (i32.sub (local.get $i) (i32.const 2))))",
      "      (local.set $s1 (i32.xor (i32.xor (i32.rotr (local.get $x) (i32.const 17)) (i32.rotr (local.get $x) (i32.const 19))) (i32.shr_u (local.get $x) (i32.const 10))))",
      "      (call $mdk_sha_set (local.get $w) (local.get $i)",
      "        (i32.add (i32.add (call $mdk_sha_get (local.get $w) (i32.sub (local.get $i) (i32.const 16))) (local.get $s0))",
      "                 (i32.add (call $mdk_sha_get (local.get $w) (i32.sub (local.get $i) (i32.const 7))) (local.get $s1))))",
      "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))",
      "    (local.set $a (call $mdk_sha_get (local.get $h) (i32.const 0)))",
      "    (local.set $b (call $mdk_sha_get (local.get $h) (i32.const 1)))",
      "    (local.set $c (call $mdk_sha_get (local.get $h) (i32.const 2)))",
      "    (local.set $d (call $mdk_sha_get (local.get $h) (i32.const 3)))",
      "    (local.set $e (call $mdk_sha_get (local.get $h) (i32.const 4)))",
      "    (local.set $f (call $mdk_sha_get (local.get $h) (i32.const 5)))",
      "    (local.set $g (call $mdk_sha_get (local.get $h) (i32.const 6)))",
      "    (local.set $hh (call $mdk_sha_get (local.get $h) (i32.const 7)))",
      "    (local.set $i (i32.const 0))",
      "    (block $d3 (loop $l3",
      "      (br_if $d3 (i32.ge_u (local.get $i) (i32.const 64)))",
      "      (local.set $t1",
      "        (i32.add",
      "          (i32.add (local.get $hh)",
      "            (i32.xor (i32.xor (i32.rotr (local.get $e) (i32.const 6)) (i32.rotr (local.get $e) (i32.const 11))) (i32.rotr (local.get $e) (i32.const 25))))",
      "          (i32.add",
      "            (i32.xor (i32.and (local.get $e) (local.get $f)) (i32.and (i32.xor (local.get $e) (i32.const -1)) (local.get $g)))",
      "            (i32.add (call $mdk_sha_k (local.get $i)) (call $mdk_sha_get (local.get $w) (local.get $i))))))",
      "      (local.set $t2",
      "        (i32.add",
      "          (i32.xor (i32.xor (i32.rotr (local.get $a) (i32.const 2)) (i32.rotr (local.get $a) (i32.const 13))) (i32.rotr (local.get $a) (i32.const 22)))",
      "          (i32.xor (i32.xor (i32.and (local.get $a) (local.get $b)) (i32.and (local.get $a) (local.get $c))) (i32.and (local.get $b) (local.get $c)))))",
      "      (local.set $hh (local.get $g))",
      "      (local.set $g (local.get $f))",
      "      (local.set $f (local.get $e))",
      "      (local.set $e (i32.add (local.get $d) (local.get $t1)))",
      "      (local.set $d (local.get $c))",
      "      (local.set $c (local.get $b))",
      "      (local.set $b (local.get $a))",
      "      (local.set $a (i32.add (local.get $t1) (local.get $t2)))",
      "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l3)))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 0) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 0)) (local.get $a)))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 1) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 1)) (local.get $b)))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 2) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 2)) (local.get $c)))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 3) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 3)) (local.get $d)))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 4) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 4)) (local.get $e)))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 5) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 5)) (local.get $f)))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 6) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 6)) (local.get $g)))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 7) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 7)) (local.get $hh))))",
      "  (func $mdk_sha256 (param $b (ref $u8arr)) (result (ref $u8arr))",
      "    (local $n i32) (local $full i32) (local $rem i32) (local $size i32) (local $i i32) (local $x i32)",
      "    (local $h (ref $u8arr)) (local $w (ref $u8arr)) (local $tail (ref $u8arr)) (local $out (ref $u8arr)) (local $bits i64)",
      "    (local.set $n (array.len (local.get $b)))",
      "    (local.set $h (array.new $u8arr (i32.const 0) (i32.const 32)))",
      "    (local.set $w (array.new $u8arr (i32.const 0) (i32.const 256)))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 0) (i32.const 1779033703))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 1) (i32.const -1150833019))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 2) (i32.const 1013904242))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 3) (i32.const -1521486534))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 4) (i32.const 1359893119))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 5) (i32.const -1694144372))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 6) (i32.const 528734635))",
      "    (call $mdk_sha_set (local.get $h) (i32.const 7) (i32.const 1541459225))",
      "    (local.set $full (i32.shr_u (local.get $n) (i32.const 6)))",
      "    (local.set $i (i32.const 0))",
      "    (block $d (loop $l",
      "      (br_if $d (i32.ge_u (local.get $i) (local.get $full)))",
      "      (call $mdk_sha_block (local.get $h) (local.get $b) (i32.shl (local.get $i) (i32.const 6)) (local.get $w))",
      "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))",
      "    (local.set $rem (i32.and (local.get $n) (i32.const 63)))",
      "    (local.set $size (select (i32.const 64) (i32.const 128) (i32.le_u (i32.add (local.get $rem) (i32.const 9)) (i32.const 64))))",
      "    (local.set $tail (array.new $u8arr (i32.const 0) (i32.const 128)))",
      "    (array.copy $u8arr $u8arr (local.get $tail) (i32.const 0) (local.get $b) (i32.shl (local.get $full) (i32.const 6)) (local.get $rem))",
      "    (array.set $u8arr (local.get $tail) (local.get $rem) (i32.const 128))",
      "    (local.set $bits (i64.shl (i64.extend_i32_u (local.get $n)) (i64.const 3)))",
      "    (local.set $i (i32.const 0))",
      "    (block $d4 (loop $l4",
      "      (br_if $d4 (i32.ge_u (local.get $i) (i32.const 8)))",
      "      (array.set $u8arr (local.get $tail) (i32.sub (i32.sub (local.get $size) (i32.const 1)) (local.get $i))",
      "        (i32.wrap_i64 (i64.shr_u (local.get $bits) (i64.extend_i32_u (i32.shl (local.get $i) (i32.const 3))))))",
      "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l4)))",
      "    (call $mdk_sha_block (local.get $h) (local.get $tail) (i32.const 0) (local.get $w))",
      "    (if (i32.eq (local.get $size) (i32.const 128))",
      "      (then (call $mdk_sha_block (local.get $h) (local.get $tail) (i32.const 64) (local.get $w))))",
      "    (local.set $out (array.new $u8arr (i32.const 0) (i32.const 32)))",
      "    (local.set $i (i32.const 0))",
      "    (block $d5 (loop $l5",
      "      (br_if $d5 (i32.ge_u (local.get $i) (i32.const 8)))",
      "      (local.set $x (call $mdk_sha_get (local.get $h) (local.get $i)))",
      "      (array.set $u8arr (local.get $out) (i32.shl (local.get $i) (i32.const 2)) (i32.shr_u (local.get $x) (i32.const 24)))",
      "      (array.set $u8arr (local.get $out) (i32.add (i32.shl (local.get $i) (i32.const 2)) (i32.const 1)) (i32.shr_u (local.get $x) (i32.const 16)))",
      "      (array.set $u8arr (local.get $out) (i32.add (i32.shl (local.get $i) (i32.const 2)) (i32.const 2)) (i32.shr_u (local.get $x) (i32.const 8)))",
      "      (array.set $u8arr (local.get $out) (i32.add (i32.shl (local.get $i) (i32.const 2)) (i32.const 3)) (local.get $x))",
      "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l5)))",
      "    (local.get $out))",
    ]

-- ── W11b charFromCode : Int -> Option Char ───────────────────────────────────────
-- Range-check the i32 codepoint (valid = 0..0x10FFFF EXCLUDING surrogates 0xD800..
-- 0xDFFF, byte-identical to medaka_rt.c mdk_char_from_code) → Some <char i31>
-- (struct.new $C_Some ordinal 0 + the i31 codepoint) / None (i31 ordinal 1).  The
-- reserved Option ctors ($C_Some / the Option root) are emitted unconditionally in
-- ref-mode. Gated independently by `WasmEmit.useCharFromCode` — needs no $str/$arr.
export
charFromCodeRuntimeLines : List String
charFromCodeRuntimeLines = [
  "  ;; -- W11b charFromCode (byte-identical to medaka_rt.c mdk_char_from_code) --",
  "  (func $mdk_char_from_code (param $cp i32) (result (ref eq))",
  "    ;; valid: 0 <= cp <= 0x10FFFF and not (0xD800 <= cp <= 0xDFFF).",
  "    (if (i32.and (i32.and (i32.ge_s (local.get $cp) (i32.const 0)) (i32.le_s (local.get $cp) (i32.const 1114111)))",
  "                 (i32.eqz (i32.and (i32.ge_s (local.get $cp) (i32.const 55296)) (i32.le_s (local.get $cp) (i32.const 57343)))))",
  "      (then (return (struct.new $C_Some (i32.const 0) (ref.i31 (local.get $cp))))))",
  "    (ref.i31 (i32.const 1)))",
]

export
plannedImportLines : List PlannedImport -> List String
plannedImportLines = map (imp =>
  "  (import \"\{imp.namespace}\" \"\{imp.field}\" (func $\{imp.watSymbol}\{imp.signature}))")

export
plannedHelperLines : WasmDemandPlan -> List (List Int) -> List String
plannedHelperLines plan files =
  flatMap
    (name =>
      if hasWasmHelper plan name then
        plannedHelperBlock plan files name
      else
        [])
    helperOrder

plannedHelperBlock : WasmDemandPlan -> List (List Int) -> String -> List String
plannedHelperBlock plan files "closApplyLines" = closApplyLines
plannedHelperBlock plan files "ioRuntimeLines" = ioRuntimeLines
plannedHelperBlock plan files "ioStrRuntimeLines" = ioStrRuntimeLines
plannedHelperBlock plan files "strLeafRuntimeLines" = strLeafRuntimeLines
plannedHelperBlock plan files "strConcatRuntimeLines" = strConcatRuntimeLines
plannedHelperBlock plan files "appendRuntimeLines" = appendRuntimeLines
plannedHelperBlock plan files "valueEqRuntimeLines" =
  valueEqRuntimeLines
    (Wide64W
      (hasWasmHelper plan "u64RuntimeLines")
      (hasWasmHelper plan "i64RuntimeLines"))
plannedHelperBlock plan files "valueAddRuntimeLines" =
  valueAddRuntimeLines
    (Wide64W
      (hasWasmHelper plan "u64RuntimeLines")
      (hasWasmHelper plan "i64RuntimeLines"))
plannedHelperBlock plan files "valueSubRuntimeLines" =
  valueSubRuntimeLines
    (Wide64W
      (hasWasmHelper plan "u64RuntimeLines")
      (hasWasmHelper plan "i64RuntimeLines"))
plannedHelperBlock plan files "valueMulRuntimeLines" =
  valueMulRuntimeLines
    (Wide64W
      (hasWasmHelper plan "u64RuntimeLines")
      (hasWasmHelper plan "i64RuntimeLines"))
plannedHelperBlock plan files "valueDivRuntimeLines" =
  valueDivRuntimeLines
    (Wide64W
      (hasWasmHelper plan "u64RuntimeLines")
      (hasWasmHelper plan "i64RuntimeLines"))
plannedHelperBlock plan files "valueModRuntimeLines" =
  valueModRuntimeLines
    (Wide64W
      (hasWasmHelper plan "u64RuntimeLines")
      (hasWasmHelper plan "i64RuntimeLines"))
plannedHelperBlock plan files "valueCmpNumRuntimeLines" =
  valueCmpNumRuntimeLines
    (Wide64W
      (hasWasmHelper plan "u64RuntimeLines")
      (hasWasmHelper plan "i64RuntimeLines"))
plannedHelperBlock plan files "u64RuntimeLines" = u64RuntimeLines
plannedHelperBlock plan files "i64RuntimeLines" = i64RuntimeLines
plannedHelperBlock plan files "stderrRuntimeLines" = stderrRuntimeLines
plannedHelperBlock plan files "rngRuntimeLines" = rngRuntimeLines
plannedHelperBlock plan files "hashRuntimeLines" = hashRuntimeLines
plannedHelperBlock plan files "hashStringRuntimeLines" = hashStringRuntimeLines
plannedHelperBlock plan files "floatRemRuntimeLines" = floatRemRuntimeLines
plannedHelperBlock plan files "floatRuntimeLines" = floatRuntimeLines
plannedHelperBlock plan files "hashFloatRuntimeLines" = hashFloatRuntimeLines
plannedHelperBlock plan files "randomFloatRuntimeLines" =
  randomFloatRuntimeLines
plannedHelperBlock plan files "floatStrLines" = floatStrLines
plannedHelperBlock plan files "strSearchRuntimeLines" = strSearchRuntimeLines
plannedHelperBlock plan files "strToIntRuntimeLines" = strToIntRuntimeLines
plannedHelperBlock plan files "strReverseRuntimeLines" = strReverseRuntimeLines
plannedHelperBlock plan files "strJoinRuntimeLines" = strJoinRuntimeLines
plannedHelperBlock plan files "strCodecRuntimeLines" = strCodecRuntimeLines
plannedHelperBlock plan files "byteBlockRuntimeLines" = byteBlockRuntimeLines
plannedHelperBlock plan files "charFromCodeRuntimeLines" =
  charFromCodeRuntimeLines
plannedHelperBlock plan files "charClassRuntimeLines" = charClassRuntimeLines
plannedHelperBlock plan files "ioPushPathLines" = ioPushPathLines
plannedHelperBlock plan files "ioPushPathMoreLines" = ioPushPathMoreLines
plannedHelperBlock plan files "ioPushGrantLines" = ioPushGrantLines
plannedHelperBlock plan files "ioPushGrantMoreLines" = ioPushGrantMoreLines
plannedHelperBlock plan files "ioResultLines" = ioResultLines
plannedHelperBlock plan files "ioRefusedPanicLines" = ioRefusedPanicLines
plannedHelperBlock plan files "ioReadFileLines" = ioReadFileLines
plannedHelperBlock plan files "ioFetchTextLines" = ioFetchTextLines
plannedHelperBlock plan files "ioFileExistsLines" = ioFileExistsLines
plannedHelperBlock plan files "ioCanonicalizeLines" = ioCanonicalizeLines
plannedHelperBlock plan files "ioWriteFileLines" = ioWriteFileLines
plannedHelperBlock plan files "ioAppendFileLines" = ioAppendFileLines
plannedHelperBlock plan files "ioRenameLines" = ioRenameLines
plannedHelperBlock plan files "ioListDirLines" = ioListDirLines
plannedHelperBlock plan files "ioStatFileLines" = ioStatFileLines
plannedHelperBlock plan files "ioMakeDirLines" = ioMakeDirLines
plannedHelperBlock plan files "ioRemoveFileLines" = ioRemoveFileLines
plannedHelperBlock plan files "ioRemoveDirLines" = ioRemoveDirLines
plannedHelperBlock plan files "ioFsyncLines" = ioFsyncLines
plannedHelperBlock plan files "ioFileModeLines" = ioFileModeLines
plannedHelperBlock plan files "ioWriteFileModeLines" = ioWriteFileModeLines
plannedHelperBlock plan files "ioGetEnvLines" = ioGetEnvLines
plannedHelperBlock plan files "ioReadLineLines" = ioReadLineLines
plannedHelperBlock plan files "ioReadAllLines" = ioReadAllLines
plannedHelperBlock plan files "ioReadExactlyLines" = ioReadExactlyLines
plannedHelperBlock plan files "ioExecutablePathLines" = ioExecutablePathLines
plannedHelperBlock plan files "jsffiArrayLines" = jsffiArrayLines
plannedHelperBlock plan files "jsffiResultStrLines" = jsffiResultStrLines
plannedHelperBlock plan files "ioArgsLines" = ioArgsLines
plannedHelperBlock plan files "utf8LossyRuntimeLines" = utf8LossyRuntimeLines
plannedHelperBlock plan files "writeFileBytesLines" = writeFileBytesLines
plannedHelperBlock plan files "osEntropyLines" = osEntropyLines
plannedHelperBlock plan files "readFileBytesLines" = readFileBytesLines
plannedHelperBlock plan files "trapIntRuntimeLines" = trapIntRuntimeLines
plannedHelperBlock plan files "intRuntimeLines" =
  intRuntimeLines plan.intHelpers
plannedHelperBlock plan files "siteRuntimeLines" =
  siteRuntimeLines files plan.nonexhaustiveRuntime
plannedHelperBlock _ _ name =
  panic ("internal error: unplanned-wasm-helper: " ++ name)
# DESUGAR
(DUse false (UseGroup ("backend" "wasm_demand") ((mem "WasmDemandPlan" false) (mem "PlannedImport" false) (mem "helperOrder" false) (mem "hasWasmHelper" false) (mem "jsWireParam" false) (mem "jsWireResult" false) (mem "unaryF64Sig" false) (mem "binaryF64Sig" false))))
(DUse false (UseGroup ("backend" "wasm_demand") ((mem "JsImport" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "joinWith" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "injectiveIdent" false))))
(DTypeSig true "preambleHeadLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "preambleHeadLines" () (EListLit (ELit (LString ";; Medaka WasmGC backend (Stage 2.4c) — emitted WAT.")) (ELit (LString ";; Value rep: WASMGC-DESIGN.md §3 / §8.6.  W2 = scalar i32; W3 = (ref eq) + i31/structs.")) (ELit (LString "(module"))))
(DTypeSig true "importLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "importLines" () (EListLit (ELit (LString "  ;; ── §6 host-import IO seam (§10 fork e — custom import) ──")) (ELit (LString "  (import \"env\" \"mdk_write_int\" (func $mdk_write_int (param i32)))")) (ELit (LString "  (import \"env\" \"mdk_write_bool\" (func $mdk_write_bool (param i32)))"))))
(DTypeSig true "closTypeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "closTypeLines" () (EListLit (ELit (LString "    ;; ── §4 closure ABI (arity-in-struct, uniform code sig) ──")) (ELit (LString "    (type $argarr (array (mut (ref null eq))))")) (ELit (LString "    (type $codety (func (param (ref eq)) (param (ref $argarr)) (result (ref eq))))")) (ELit (LString "    (type $clos (sub (struct (field $code (ref $codety)) (field $arity i32) (field $env (ref $argarr)))))"))))
(DTypeSig true "closApplyLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "closApplyLines" () (EListLit (ELit (LString "  ;; ── §4 universal apply runtime (exact / under-PAP / over-saturate) ──")) (ELit (LString "  (func $mdk_pap (type $codety) (param $self (ref eq)) (param $args (ref $argarr)) (result (ref eq))")) (ELit (LString "    (local $c (ref $clos)) (local $env (ref $argarr)) (local $orig (ref eq))")) (ELit (LString "    (local $ne i32) (local $na i32) (local $total (ref $argarr)) (local $i i32)")) (ELit (LString "    (local.set $c (ref.cast (ref $clos) (local.get $self)))")) (ELit (LString "    (local.set $env (struct.get $clos $env (local.get $c)))")) (ELit (LString "    (local.set $orig (ref.as_non_null (array.get $argarr (local.get $env) (i32.const 0))))")) (ELit (LString "    (local.set $ne (i32.sub (array.len (local.get $env)) (i32.const 1)))")) (ELit (LString "    (local.set $na (array.len (local.get $args)))")) (ELit (LString "    (local.set $total (array.new $argarr (ref.null eq) (i32.add (local.get $ne) (local.get $na))))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $pd (loop $pl")) (ELit (LString "      (br_if $pd (i32.ge_s (local.get $i) (local.get $ne)))")) (ELit (LString "      (array.set $argarr (local.get $total) (local.get $i)")) (ELit (LString "        (array.get $argarr (local.get $env) (i32.add (local.get $i) (i32.const 1))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $pl)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $pd2 (loop $pl2")) (ELit (LString "      (br_if $pd2 (i32.ge_s (local.get $i) (local.get $na)))")) (ELit (LString "      (array.set $argarr (local.get $total) (i32.add (local.get $ne) (local.get $i))")) (ELit (LString "        (array.get $argarr (local.get $args) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $pl2)))")) (ELit (LString "    (return_call $__mdk_apply (local.get $orig) (local.get $total)))")) (ELit (LString "  (func $__mdk_apply (param $f (ref eq)) (param $args (ref $argarr)) (result (ref eq))")) (ELit (LString "    (local $c (ref $clos)) (local $ar i32) (local $na i32)")) (ELit (LString "    (local $sat (ref $argarr)) (local $surplus (ref $argarr)) (local $i i32) (local $r (ref eq))")) (ELit (LString "    (local $penv (ref $argarr))")) (ELit (LString "    (local.set $c (ref.cast (ref $clos) (local.get $f)))")) (ELit (LString "    (local.set $ar (struct.get $clos $arity (local.get $c)))")) (ELit (LString "    (local.set $na (array.len (local.get $args)))")) (ELit (LString "    (if (result (ref eq)) (i32.eq (local.get $na) (local.get $ar))")) (ELit (LString "      (then (return_call_ref $codety (local.get $f) (local.get $args) (struct.get $clos $code (local.get $c))))")) (ELit (LString "      (else")) (ELit (LString "        (if (result (ref eq)) (i32.lt_s (local.get $na) (local.get $ar))")) (ELit (LString "          (then")) (ELit (LString "            (local.set $penv (array.new $argarr (ref.null eq) (i32.add (local.get $na) (i32.const 1))))")) (ELit (LString "            (array.set $argarr (local.get $penv) (i32.const 0) (local.get $f))")) (ELit (LString "            (local.set $i (i32.const 0))")) (ELit (LString "            (block $ud (loop $ul")) (ELit (LString "              (br_if $ud (i32.ge_s (local.get $i) (local.get $na)))")) (ELit (LString "              (array.set $argarr (local.get $penv) (i32.add (local.get $i) (i32.const 1))")) (ELit (LString "                (array.get $argarr (local.get $args) (local.get $i)))")) (ELit (LString "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $ul)))")) (ELit (LString "            (struct.new $clos (ref.func $mdk_pap) (i32.sub (local.get $ar) (local.get $na)) (local.get $penv)))")) (ELit (LString "          (else")) (ELit (LString "            (local.set $sat (array.new $argarr (ref.null eq) (local.get $ar)))")) (ELit (LString "            (local.set $i (i32.const 0))")) (ELit (LString "            (block $sd (loop $sl")) (ELit (LString "              (br_if $sd (i32.ge_s (local.get $i) (local.get $ar)))")) (ELit (LString "              (array.set $argarr (local.get $sat) (local.get $i)")) (ELit (LString "                (array.get $argarr (local.get $args) (local.get $i)))")) (ELit (LString "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $sl)))")) (ELit (LString "            (local.set $r (call_ref $codety (local.get $f) (local.get $sat) (struct.get $clos $code (local.get $c))))")) (ELit (LString "            (local.set $surplus (array.new $argarr (ref.null eq) (i32.sub (local.get $na) (local.get $ar))))")) (ELit (LString "            (local.set $i (i32.const 0))")) (ELit (LString "            (block $od (loop $ol")) (ELit (LString "              (br_if $od (i32.ge_s (local.get $i) (i32.sub (local.get $na) (local.get $ar))))")) (ELit (LString "              (array.set $argarr (local.get $surplus) (local.get $i)")) (ELit (LString "                (array.get $argarr (local.get $args) (i32.add (local.get $i) (local.get $ar))))")) (ELit (LString "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $ol)))")) (ELit (LString "            (return_call $__mdk_apply (local.get $r) (local.get $surplus)))))))"))))
(DTypeSig true "preambleScalarLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "preambleScalarLines" () (EBinOp "++" (EBinOp "++" (EVar "preambleHeadLines") (EListLit (ELit (LString "  ;; ── §3 type section (one rec group, iso-recursive / nominal-modulo-canon) ──")) (ELit (LString "  ;; This program uses no ADTs — the scalar subset computes in raw i32 and only")) (ELit (LString "  ;; the print boundary is reached; the unitype scaffolding is declared unused.")) (ELit (LString "  (rec")) (ELit (LString "    ;; boxed Int outside the i31 range (§3.2) — declared, unused.")) (ELit (LString "    (type $boxint (sub (struct (field i64))))")) (ELit (LString "    ;; boxed Float (§3.3) — declared, unused until a Float fixture needs it.")) (ELit (LString "    (type $float (sub (struct (field f64))))")) (ELit (LString "  )")))) (EVar "importLines")))
(DTypeSig true "ioByteImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioByteImportLines" () (EListLit (ELit (LString "  ;; ── §6 host-import IO seam (§10 fork e — byte-level custom import) ──")) (ELit (LString "  (import \"env\" \"mdk_write_byte\" (func $mdk_write_byte (param i32)))"))))
(DTypeSig true "strTypeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strTypeLines" () (EListLit (ELit (LString "    ;; ── §3.3 String aggregate (UTF-8 bytes + cached codepoint count) ──")) (ELit (LString "    (type $u8arr (array (mut i8)))")) (ELit (LString "    (type $str (sub (struct (field $cp_count i32) (field $bytes (ref $u8arr)))))"))))
(DTypeSig true "ioRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioRuntimeLines" () (EListLit (ELit (LString "  ;; ── §2.1 Int representation seam: i31 fast path / $boxint i64 box ──")) (ELit (LString "  ;; layer-17 SOUNDNESS: Ints in [-2^30, 2^30) are i31ref immediates; outside that")) (ELit (LString "  ;; range they box into (struct (field i64)) ($boxint).  ALL Int arithmetic unboxes")) (ELit (LString "  ;; both operands to i64 via $mdk_unbox_int, computes in i64, and re-boxes via")) (ELit (LString "  ;; $mdk_box_int — so >2^30 values no longer truncate to 31 bits.")) (ELit (LString "  (func $mdk_unbox_int (param $v (ref eq)) (result i64)")) (ELit (LString "    (if (result i64) (ref.test (ref i31) (local.get $v))")) (ELit (LString "      (then (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $v)))))")) (ELit (LString "      (else (struct.get $boxint 0 (ref.cast (ref $boxint) (local.get $v))))))")) (ELit (LString "  ;; box an i64 Int: in [-2^30, 2^30) -> i31 immediate; else -> $boxint struct.")) (ELit (LString "  ;; An Int is 63-bit.  The sign-extend from bit 62 (the `(x << 1) >> 1` pair, which")) (ELit (LString "  ;; mirrors native's tag/untag and is a no-op on any 63-bit value) makes `every")) (ELit (LString "  ;; (ref eq) Int holds a 63-bit value` a representation invariant, so INT64_MIN is")) (ELit (LString "  ;; unreachable.  Arithmetic does not lean on it: `+ - * /` and negation are checked")) (ELit (LString "  ;; before they box ($mdk_int_add...).  It is the defined result only for the")) (ELit (LString "  ;; operations that discard high bits: shiftLeft drops the bits past bit 62, as")) (ELit (LString "  ;; native's retag does, and u64TruncateToInt keeps the low 63.  This is the SOLE")) (ELit (LString "  ;; producer of $boxint.")) (ELit (LString "  (func $mdk_box_int (param $n i64) (result (ref eq))")) (ELit (LString "    (local.set $n (i64.shr_s (i64.shl (local.get $n) (i64.const 1)) (i64.const 1)))")) (ELit (LString "    (if (result (ref eq))")) (ELit (LString "        (i32.and (i64.ge_s (local.get $n) (i64.const -1073741824))")) (ELit (LString "                 (i64.lt_s (local.get $n) (i64.const 1073741824)))")) (ELit (LString "      (then (ref.i31 (i32.wrap_i64 (local.get $n))))")) (ELit (LString "      (else (struct.new $boxint (local.get $n)))))")) (ELit (LString "  ;; ── §6 byte-write print runtime (decimal int / bool text) ──")) (ELit (LString "  ;; write the decimal digits of a NON-NEGATIVE i64 (most-significant first).")) (ELit (LString "  (func $mdk_write_digits (param $n i64)")) (ELit (LString "    (if (i64.ge_s (local.get $n) (i64.const 10))")) (ELit (LString "      (then (call $mdk_write_digits (i64.div_s (local.get $n) (i64.const 10)))))")) (ELit (LString "    (call $mdk_write_byte")) (ELit (LString "      (i32.add (i32.const 48)")) (ELit (LString "        (i32.wrap_i64 (i64.rem_s (local.get $n) (i64.const 10))))))")) (ELit (LString "  ;; render an i64 in decimal to stdout + a trailing newline (value-main Int).")) (ELit (LString "  (func $mdk_print_int (param $n i64)")) (ELit (LString "    (if (i64.lt_s (local.get $n) (i64.const 0))")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_byte (i32.const 45))")) (ELit (LString "        (call $mdk_write_digits (i64.sub (i64.const 0) (local.get $n))))")) (ELit (LString "      (else (call $mdk_write_digits (local.get $n))))")) (ELit (LString "    (call $mdk_write_byte (i32.const 10)))")) (ELit (LString "  (func $mdk_print_bool (param $b i32)")) (ELit (LString "    (if (local.get $b)")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_byte (i32.const 84)) (call $mdk_write_byte (i32.const 114))")) (ELit (LString "        (call $mdk_write_byte (i32.const 117)) (call $mdk_write_byte (i32.const 101)))")) (ELit (LString "      (else")) (ELit (LString "        (call $mdk_write_byte (i32.const 70)) (call $mdk_write_byte (i32.const 97))")) (ELit (LString "        (call $mdk_write_byte (i32.const 108)) (call $mdk_write_byte (i32.const 115))")) (ELit (LString "        (call $mdk_write_byte (i32.const 101))))")) (ELit (LString "    (call $mdk_write_byte (i32.const 10)))"))))
(DTypeSig true "ioStrRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioStrRuntimeLines" () (EListLit (ELit (LString "  ;; ── §6 string byte-write runtime ($str-dependent) ──")) (ELit (LString "  (func $mdk_print_str (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))")) (ELit (LString "  (func $mdk_print_strln (param $s (ref $str))")) (ELit (LString "    (call $mdk_print_str (local.get $s))")) (ELit (LString "    (call $mdk_write_byte (i32.const 10)))")) (ELit (LString "  ;; intToString : render an i64 in decimal into a fresh $str (cp_count == byte len).")) (ELit (LString "  (func $mdk_int_to_str (param $n i64) (result (ref $str))")) (ELit (LString "    (local $neg i32) (local $m i64) (local $len i32) (local $i i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $d i32)")) (ELit (LString "    (local.set $neg (i64.lt_s (local.get $n) (i64.const 0)))")) (ELit (LString "    (local.set $m (if (result i64) (local.get $neg)")) (ELit (LString "      (then (i64.sub (i64.const 0) (local.get $n))) (else (local.get $n))))")) (ELit (LString "    ;; count digits")) (ELit (LString "    (local.set $len (i32.const 1))")) (ELit (LString "    (block $cd (loop $cl")) (ELit (LString "      (br_if $cd (i64.lt_s (local.get $m) (i64.const 10)))")) (ELit (LString "      (local.set $len (i32.add (local.get $len) (i32.const 1)))")) (ELit (LString "      (local.set $m (i64.div_s (local.get $m) (i64.const 10)))")) (ELit (LString "      (br $cl)))")) (ELit (LString "    (local.set $m (if (result i64) (local.get $neg)")) (ELit (LString "      (then (i64.sub (i64.const 0) (local.get $n))) (else (local.get $n))))")) (ELit (LString "    (if (local.get $neg) (then (local.set $len (i32.add (local.get $len) (i32.const 1)))))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $len)))")) (ELit (LString "    ;; fill digits from least-significant (end) backward")) (ELit (LString "    (local.set $i (i32.sub (local.get $len) (i32.const 1)))")) (ELit (LString "    (block $fd (loop $fl")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i)")) (ELit (LString "        (i32.add (i32.const 48) (i32.wrap_i64 (i64.rem_s (local.get $m) (i64.const 10)))))")) (ELit (LString "      (local.set $m (i64.div_s (local.get $m) (i64.const 10)))")) (ELit (LString "      (local.set $i (i32.sub (local.get $i) (i32.const 1)))")) (ELit (LString "      (br_if $fd (i64.eq (local.get $m) (i64.const 0)))")) (ELit (LString "      (br $fl)))")) (ELit (LString "    (if (local.get $neg) (then (array.set $u8arr (local.get $buf) (i32.const 0) (i32.const 45))))")) (ELit (LString "    (struct.new $str (local.get $len) (local.get $buf)))"))))
(DTypeSig true "stderrByteImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "stderrByteImportLines" () (EListLit (ELit (LString "  (import \"env\" \"mdk_write_err_byte\" (func $mdk_write_err_byte (param i32)))"))))
(DTypeSig true "trapIntRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "trapIntRuntimeLines" () (EListLit (ELit (LString "  ;; -- #1787 numbered-trap decimal runtime (stderr, no newline) --")) (ELit (LString "  ;; write the decimal digits of a NON-NEGATIVE i64 (most-significant first).")) (ELit (LString "  (func $mdk_write_err_digits (param $n i64)")) (ELit (LString "    (if (i64.ge_s (local.get $n) (i64.const 10))")) (ELit (LString "      (then (call $mdk_write_err_digits (i64.div_s (local.get $n) (i64.const 10)))))")) (ELit (LString "    (call $mdk_write_err_byte")) (ELit (LString "      (i32.add (i32.const 48)")) (ELit (LString "        (i32.wrap_i64 (i64.rem_s (local.get $n) (i64.const 10))))))")) (ELit (LString "  ;; render an i64 in decimal to stderr, sign included, NO trailing newline.")) (ELit (LString "  (func $mdk_write_err_int (param $n i64)")) (ELit (LString "    (if (i64.lt_s (local.get $n) (i64.const 0))")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 45))")) (ELit (LString "        (call $mdk_write_err_digits (i64.sub (i64.const 0) (local.get $n))))")) (ELit (LString "      (else (call $mdk_write_err_digits (local.get $n)))))"))))
(DTypeSig true "siteRuntimeLines" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "siteRuntimeLines" ((PVar "files") (PVar "nonexh")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; -- located traps: `<file>:<line>:<col>: ` ahead of a trap line --")) (ELit (LString "  (func $mdk_write_err_loc (param $s i64)")) (ELit (LString "    (local $f i32)")) (ELit (LString "    (if (i64.ne (local.get $s) (i64.const 0))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $f (i32.wrap_i64 (i64.shr_u (local.get $s) (i64.const 44))))"))) (EApp (EApp (EVar "flatMap") (EVar "siteFileArmW")) (EApp (EApp (EVar "zipFilesW") (EVar "files")) (ELit (LInt 1))))) (EListLit (ELit (LString "        (call $mdk_write_err_byte (i32.const 58))")) (ELit (LString "        (call $mdk_write_err_int (i64.and (i64.shr_u (local.get $s) (i64.const 20)) (i64.const 16777215)))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 58))")) (ELit (LString "        (call $mdk_write_err_int (i64.and (local.get $s) (i64.const 1048575)))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 58))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 32))))")) (ELit (LString "  )")))) (EIf (EVar "nonexh") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  (func $mdk_trap_nonexh (param $s i64)")) (ELit (LString "    (call $mdk_write_err_loc (local.get $s))"))) (EApp (EVar "asciiTrapBytesW") (ELit (LString "runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match\n")))) (EListLit (ELit (LString "    unreachable)")))) (EListLit))))
(DTypeSig false "zipFilesW" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "zipFilesW" ((PList) PWild) (EListLit))
(DFunDef false "zipFilesW" ((PCons (PVar "f") (PVar "fs")) (PVar "n")) (EBinOp "::" (ETuple (EVar "n") (EVar "f")) (EApp (EApp (EVar "zipFilesW") (EVar "fs")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "siteFileArmW" (TyFun (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "siteFileArmW" ((PTuple (PVar "n") (PVar "bytes"))) (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "        (if (i32.eq (local.get $f) (i32.const ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "))"))) (ELit (LString "          (then"))) (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EBinOp "++" (EBinOp "++" (ELit (LString "            (call $mdk_write_err_byte (i32.const ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "b")))) (ELit (LString "))"))))) (EVar "bytes"))) (EListLit (ELit (LString "          ))")))))
(DTypeSig true "intRuntimeLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "intRuntimeLines" ((PVar "used")) (EBlock (DoLet false false (PVar "arith") (EApp (EApp (EVar "filterUsedW") (EVar "used")) (EListLit (ELit (LString "add")) (ELit (LString "sub")) (ELit (LString "mul")) (ELit (LString "div")) (ELit (LString "neg"))))) (DoLet false false (PVar "shifts") (EApp (EApp (EVar "filterUsedW") (EVar "used")) (EListLit (ELit (LString "left")) (ELit (LString "right"))))) (DoLet false false (PVar "core") (EMatch (EVar "arith") (arm (PList) () (EListLit)) (arm PWild () (EVar "intOverflowLines")))) (DoExpr (EBinOp "++" (EBinOp "++" (EVar "core") (EApp (EApp (EVar "flatMap") (EVar "checkedIntOpW")) (EVar "arith"))) (EApp (EApp (EVar "flatMap") (EVar "intShiftW")) (EVar "shifts"))))))
(DTypeSig false "filterUsedW" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterUsedW" (PWild (PList)) (EListLit))
(DFunDef false "filterUsedW" ((PVar "used") (PCons (PVar "n") (PVar "ns"))) (EIf (EApp (EApp (EVar "memberW") (EVar "n")) (EVar "used")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "filterUsedW") (EVar "used")) (EVar "ns"))) (EApp (EApp (EVar "filterUsedW") (EVar "used")) (EVar "ns"))))
(DTypeSig false "memberW" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "memberW" (PWild (PList)) (EVar "False"))
(DFunDef false "memberW" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "memberW") (EVar "x")) (EVar "ys"))))
(DTypeSig false "intOverflowLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "intOverflowLines" () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; -- #3377 checked Int arithmetic: E-INT-OVERFLOW instead of a wrap --")) (ELit (LString "  (func $mdk_int_operand (param $v i64)")) (ELit (LString "    (if (i64.lt_s (local.get $v) (i64.const 0))")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 40))")) (ELit (LString "        (call $mdk_write_err_int (local.get $v))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 41)))")) (ELit (LString "      (else (call $mdk_write_err_int (local.get $v)))))")) (ELit (LString "  (func $mdk_int_overflow (param $op i32) (param $a i64) (param $b i64) (param $s i64)")) (ELit (LString "    (call $mdk_write_err_loc (local.get $s))"))) (EApp (EVar "asciiTrapBytesW") (ELit (LString "runtime error [E-INT-OVERFLOW]: ")))) (EListLit (ELit (LString "    (if (i32.eqz (local.get $op))")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 45))")) (ELit (LString "        (call $mdk_int_operand (local.get $a)))")) (ELit (LString "      (else")) (ELit (LString "        (call $mdk_int_operand (local.get $a))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 32))")) (ELit (LString "        (call $mdk_write_err_byte (local.get $op))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 32))")) (ELit (LString "        (call $mdk_int_operand (local.get $b))))")))) (EApp (EVar "asciiTrapBytesW") (ELit (LString " overflows Int\n")))) (EListLit (ELit (LString "        unreachable)")))))
(DTypeSig false "outOfIntRangeW" (TyCon "String"))
(DFunDef false "outOfIntRangeW" () (ELit (LString "(i64.ne (i64.shr_s (i64.shl (local.get $r) (i64.const 1)) (i64.const 1)) (local.get $r))")))
(DTypeSig false "overflowCallW" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "overflowCallW" ((PVar "code")) (EBinOp "++" (EBinOp "++" (ELit (LString "(call $mdk_int_overflow (i32.const ")) (EApp (EVar "display") (EVar "code"))) (ELit (LString ") (local.get $a) (local.get $b) (local.get $s))"))))
(DTypeSig false "checkedIntOpW" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "checkedIntOpW" ((PLit (LString "neg"))) (EListLit (ELit (LString "  (func $mdk_int_neg (param $a i64) (result i64)")) (ELit (LString "    (local $r i64)")) (ELit (LString "    (local.set $r (i64.sub (i64.const 0) (local.get $a)))")) (EBinOp "++" (EBinOp "++" (ELit (LString "    (if ")) (EApp (EVar "display") (EVar "outOfIntRangeW"))) (ELit (LString ""))) (ELit (LString "      (then (call $mdk_int_overflow (i32.const 0) (local.get $a) (i64.const 0) (i64.const 0))))")) (ELit (LString "    (local.get $r))"))))
(DFunDef false "checkedIntOpW" ((PLit (LString "mul"))) (EListLit (ELit (LString "  (func $mdk_int_mul (param $a i64) (param $b i64) (param $s i64) (result i64)")) (ELit (LString "    (local $r i64)")) (ELit (LString "    (local.set $r (i64.mul (local.get $a) (local.get $b)))")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    (if ")) (EApp (EVar "display") (EVar "outOfIntRangeW"))) (ELit (LString " (then "))) (EApp (EVar "display") (EApp (EVar "overflowCallW") (ELit (LString "42"))))) (ELit (LString "))"))) (ELit (LString "    (if (i64.ne (local.get $a) (i64.const 0))")) (ELit (LString "      (then")) (ELit (LString "        (if (i64.ne (i64.div_s (local.get $r) (local.get $a)) (local.get $b))")) (EBinOp "++" (EBinOp "++" (ELit (LString "          (then ")) (EApp (EVar "display") (EApp (EVar "overflowCallW") (ELit (LString "42"))))) (ELit (LString "))))"))) (ELit (LString "    (local.get $r))"))))
(DFunDef false "checkedIntOpW" ((PLit (LString "add"))) (EApp (EApp (EApp (EVar "checkedBinOpLinesW") (ELit (LString "add"))) (ELit (LString "i64.add"))) (ELit (LString "43"))))
(DFunDef false "checkedIntOpW" ((PLit (LString "sub"))) (EApp (EApp (EApp (EVar "checkedBinOpLinesW") (ELit (LString "sub"))) (ELit (LString "i64.sub"))) (ELit (LString "45"))))
(DFunDef false "checkedIntOpW" ((PLit (LString "div"))) (EApp (EApp (EApp (EVar "checkedBinOpLinesW") (ELit (LString "div"))) (ELit (LString "i64.div_s"))) (ELit (LString "47"))))
(DFunDef false "checkedIntOpW" ((PVar "op")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "wasm: no checked Int operator '")) (EVar "op")) (ELit (LString "'")))))
(DTypeSig false "checkedBinOpLinesW" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "checkedBinOpLinesW" ((PVar "name") (PVar "instr") (PVar "code")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  (func $mdk_int_")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " (param $a i64) (param $b i64) (param $s i64) (result i64)"))) (ELit (LString "    (local $r i64)")) (EBinOp "++" (EBinOp "++" (ELit (LString "    (local.set $r (")) (EApp (EVar "display") (EVar "instr"))) (ELit (LString " (local.get $a) (local.get $b)))"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    (if ")) (EApp (EVar "display") (EVar "outOfIntRangeW"))) (ELit (LString " (then "))) (EApp (EVar "display") (EApp (EVar "overflowCallW") (EVar "code")))) (ELit (LString "))"))) (ELit (LString "    (local.get $r))"))))
(DTypeSig false "intShiftW" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "intShiftW" ((PLit (LString "left"))) (EBinOp "++" (EApp (EApp (EVar "intShiftHeadW") (ELit (LString "left"))) (ELit (LString "shiftLeft"))) (EListLit (ELit (LString "    (select (i64.shl (local.get $x) (local.get $k)) (i64.const 0)")) (ELit (LString "      (i64.lt_s (local.get $k) (i64.const 63))))")))))
(DFunDef false "intShiftW" ((PLit (LString "right"))) (EBinOp "++" (EApp (EApp (EVar "intShiftHeadW") (ELit (LString "right"))) (ELit (LString "shiftRight"))) (EListLit (ELit (LString "    (i64.shr_s (local.get $x)")) (ELit (LString "      (select (local.get $k) (i64.const 63) (i64.lt_s (local.get $k) (i64.const 63)))))")))))
(DFunDef false "intShiftW" ((PVar "dir")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "wasm: no Int shift '")) (EVar "dir")) (ELit (LString "'")))))
(DTypeSig false "intShiftHeadW" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "intShiftHeadW" ((PVar "dir") (PVar "name")) (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  (func $mdk_shift_")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString " (param $x i64) (param $k i64) (result i64)"))) (ELit (LString "    (if (i64.lt_s (local.get $k) (i64.const 0))")) (ELit (LString "      (then"))) (EApp (EVar "asciiTrapBytesW") (EBinOp "++" (EBinOp "++" (ELit (LString "runtime error [E-PANIC]: ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ": negative shift "))))) (EListLit (ELit (LString "        (call $mdk_write_err_int (local.get $k))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 10))")) (ELit (LString "        unreachable))")))))
(DTypeSig true "stderrRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "stderrRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 stderr byte-write runtime (ePutStr / ePutStrLn) ──")) (ELit (LString "  (func $mdk_eprint_str (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_err_byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))")) (ELit (LString "  (func $mdk_eprint_strln (param $s (ref $str))")) (ELit (LString "    (call $mdk_eprint_str (local.get $s))")) (ELit (LString "    (call $mdk_write_err_byte (i32.const 10)))"))))
(DTypeSig true "strLeafRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strLeafRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 string LEAF ops (byte-identical to medaka_rt.c) ──")) (ELit (LString "  ;; count UTF-8 codepoints in a $u8arr over [0,n): every non-continuation byte.")) (ELit (LString "  (func $mdk_cp_count (param $b (ref $u8arr)) (param $n i32) (result i32)")) (ELit (LString "    (local $i i32) (local $c i32) (local $byte i32)")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $c (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      ;; a continuation byte has top bits 10xxxxxx, i.e. (byte & 0xC0) == 0x80.")) (ELit (LString "      (if (i32.ne (i32.and (local.get $byte) (i32.const 192)) (i32.const 128))")) (ELit (LString "        (then (local.set $c (i32.add (local.get $c) (i32.const 1)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $c))")) (ELit (LString "  ;; codepoint index `cpi` -> byte offset into a $u8arr of byte length `n`.")) (ELit (LString "  (func $mdk_byte_off (param $b (ref $u8arr)) (param $n i32) (param $cpi i32) (result i32)")) (ELit (LString "    (local $bo i32) (local $c i32)")) (ELit (LString "    (local.set $bo (i32.const 0)) (local.set $c (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $bo) (local.get $n)))")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $c) (local.get $cpi)))")) (ELit (LString "      (local.set $bo (i32.add (local.get $bo) (i32.const 1)))")) (ELit (LString "      (block $sd (loop $sl")) (ELit (LString "        (br_if $sd (i32.ge_s (local.get $bo) (local.get $n)))")) (ELit (LString "        (br_if $sd (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (local.get $bo)) (i32.const 192)) (i32.const 128)))")) (ELit (LString "        (local.set $bo (i32.add (local.get $bo) (i32.const 1))) (br $sl)))")) (ELit (LString "      (local.set $c (i32.add (local.get $c) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $bo))")) (ELit (LString "  ;; binary string concat (`++`).  cp_count(a++b) == cp_count(a)+cp_count(b).")) (ELit (LString "  (func $mdk_str_append (param $a (ref $str)) (param $b (ref $str)) (result (ref $str))")) (ELit (LString "    (local $ab (ref $u8arr)) (local $bb (ref $u8arr)) (local $al i32) (local $bl i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $cpc i32)")) (ELit (LString "    (local.set $ab (struct.get $str $bytes (local.get $a)))")) (ELit (LString "    (local.set $bb (struct.get $str $bytes (local.get $b)))")) (ELit (LString "    (local.set $al (array.len (local.get $ab)))")) (ELit (LString "    (local.set $bl (array.len (local.get $bb)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (i32.add (local.get $al) (local.get $bl))))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $ab) (i32.const 0) (local.get $al))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (local.get $al) (local.get $bb) (i32.const 0) (local.get $bl))")) (ELit (LString "    (local.set $cpc (i32.add (struct.get $str $cp_count (local.get $a)) (struct.get $str $cp_count (local.get $b))))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))")) (ELit (LString "  ;; encode one Unicode codepoint to a fresh $str (1..4 UTF-8 bytes, cp_count 1).")) (ELit (LString "  (func $mdk_char_to_str (param $cp i32) (result (ref $str))")) (ELit (LString "    (local $buf (ref $u8arr))")) (ELit (LString "    (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 128))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 1)))")) (ELit (LString "        (array.set $u8arr (local.get $buf) (i32.const 0) (local.get $cp))")) (ELit (LString "        (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "      (else (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 2048))")) (ELit (LString "        (then")) (ELit (LString "          (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 2)))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "          (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "        (else (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 65536))")) (ELit (LString "          (then")) (ELit (LString "            (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 3)))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 2) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "          (else")) (ELit (LString "            (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 4)))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 2) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 3) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "          )")) (ELit (LString "        )")) (ELit (LString "      )")) (ELit (LString "    )")) (ELit (LString "  ))")) (ELit (LString "  ;; codepoint-indexed [lo,hi) slice, clamped to [0,cp_count].")) (ELit (LString "  (func $mdk_str_slice (param $lo i32) (param $hi i32) (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $cpc i32) (local $blo i32) (local $bhi i32)")) (ELit (LString "    (local $len i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $cpc (struct.get $str $cp_count (local.get $s)))")) (ELit (LString "    (if (i32.lt_s (local.get $lo) (i32.const 0)) (then (local.set $lo (i32.const 0)))")) (ELit (LString "      (else (if (i32.gt_s (local.get $lo) (local.get $cpc)) (then (local.set $lo (local.get $cpc))))))")) (ELit (LString "    (if (i32.lt_s (local.get $hi) (local.get $lo)) (then (local.set $hi (local.get $lo)))")) (ELit (LString "      (else (if (i32.gt_s (local.get $hi) (local.get $cpc)) (then (local.set $hi (local.get $cpc))))))")) (ELit (LString "    (if (i32.eq (local.get $cpc) (local.get $n))")) (ELit (LString "      (then (local.set $blo (local.get $lo)) (local.set $bhi (local.get $hi)))")) (ELit (LString "      (else")) (ELit (LString "        (local.set $blo (call $mdk_byte_off (local.get $b) (local.get $n) (local.get $lo)))")) (ELit (LString "        (local.set $bhi (call $mdk_byte_off (local.get $b) (local.get $n) (local.get $hi)))))")) (ELit (LString "    (local.set $len (i32.sub (local.get $bhi) (local.get $blo)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $len)))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $b) (local.get $blo) (local.get $len))")) (ELit (LString "    (struct.new $str (i32.sub (local.get $hi) (local.get $lo)) (local.get $buf)))")) (ELit (LString "  ;; ASCII upper/lower over BYTES (non-ASCII bytes pass through unchanged).")) (ELit (LString "  (func $mdk_str_upper (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $c i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))")) (ELit (LString "        (then (local.set $c (i32.sub (local.get $c) (i32.const 32)))))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $c))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))")) (ELit (LString "  (func $mdk_str_lower (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $c i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))")) (ELit (LString "        (then (local.set $c (i32.add (local.get $c) (i32.const 32)))))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $c))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))")) (ELit (LString "  ;; ── W9 debug-literal quoting ──")) (ELit (LString "  ;; Map ONE source byte to its escaped form, appending into $buf at $bo; returns the")) (ELit (LString "  ;; next write offset.  Specials: \" / ' (whichever == $q) / \\ / \\n / \\t / \\r / NUL.")) (ELit (LString "  ;; All escapes are <backslash><ascii>, so 2 bytes; everything else copies verbatim.")) (ELit (LString "  (func $mdk_dbg_esc_byte (param $buf (ref $u8arr)) (param $bo i32) (param $c i32) (param $q i32) (result i32)")) (ELit (LString "    (local $r i32)")) (ELit (LString "    ;; $r = the char AFTER the backslash for an escaped byte, else -1 (copy verbatim).")) (ELit (LString "    (local.set $r (i32.const -1))")) (ELit (LString "    (if (i32.eq (local.get $c) (local.get $q)) (then (local.set $r (local.get $q))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 92)) (then (local.set $r (i32.const 92))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 10)) (then (local.set $r (i32.const 110))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 9))  (then (local.set $r (i32.const 116))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 13)) (then (local.set $r (i32.const 114))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 0))  (then (local.set $r (i32.const 48))))")) (ELit (LString "    (if (result i32) (i32.eq (local.get $r) (i32.const -1))")) (ELit (LString "      (then")) (ELit (LString "        (array.set $u8arr (local.get $buf) (local.get $bo) (local.get $c))")) (ELit (LString "        (i32.add (local.get $bo) (i32.const 1)))")) (ELit (LString "      (else")) (ELit (LString "        (array.set $u8arr (local.get $buf) (local.get $bo) (i32.const 92))")) (ELit (LString "        (array.set $u8arr (local.get $buf) (i32.add (local.get $bo) (i32.const 1)) (local.get $r))")) (ELit (LString "        (i32.add (local.get $bo) (i32.const 2)))))")) (ELit (LString "  ;; Quote+escape a $str with quote byte $q ('\"' for String, ''' for Char).  Two-pass:")) (ELit (LString "  ;; count escaped output bytes, alloc exact, fill; cp_count via $mdk_cp_count.")) (ELit (LString "  (func $mdk_dbg_quote (param $s (ref $str)) (param $q i32) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $c i32)")) (ELit (LString "    (local $out i32) (local $buf (ref $u8arr)) (local $bo i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    ;; pass 1: total output bytes = 2 quotes + per-byte (2 if escaped else 1).")) (ELit (LString "    (local.set $out (i32.const 2)) (local.set $i (i32.const 0))")) (ELit (LString "    (block $d1 (loop $l1")) (ELit (LString "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.or (i32.or (i32.or (i32.eq (local.get $c) (local.get $q)) (i32.eq (local.get $c) (i32.const 92)))")) (ELit (LString "                          (i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 9))))")) (ELit (LString "                  (i32.or (i32.eq (local.get $c) (i32.const 13)) (i32.eq (local.get $c) (i32.const 0))))")) (ELit (LString "        (then (local.set $out (i32.add (local.get $out) (i32.const 2))))")) (ELit (LString "        (else (local.set $out (i32.add (local.get $out) (i32.const 1)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $out)))")) (ELit (LString "    ;; pass 2: opening quote, escaped bytes, closing quote.")) (ELit (LString "    (array.set $u8arr (local.get $buf) (i32.const 0) (local.get $q))")) (ELit (LString "    (local.set $bo (i32.const 1)) (local.set $i (i32.const 0))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $bo (call $mdk_dbg_esc_byte (local.get $buf) (local.get $bo) (local.get $c) (local.get $q)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))")) (ELit (LString "    (array.set $u8arr (local.get $buf) (local.get $bo) (local.get $q))")) (ELit (LString "    (struct.new $str (call $mdk_cp_count (local.get $buf) (local.get $out)) (local.get $buf)))")) (ELit (LString "  ;; debugStringLit : $str -> $str, surround with double-quotes (q = 34).")) (ELit (LString "  (func $mdk_debug_string_lit (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (call $mdk_dbg_quote (local.get $s) (i32.const 34)))")) (ELit (LString "  ;; debugCharLit : Char (i31 codepoint) -> $str, surround with single-quotes (q = 39).")) (ELit (LString "  (func $mdk_debug_char_lit (param $cp i32) (result (ref $str))")) (ELit (LString "    (call $mdk_dbg_quote (call $mdk_char_to_str (local.get $cp)) (i32.const 39)))")) (ELit (LString "  ;; -- W8c byte-level prefix/suffix (byte-identical to medaka_rt.c) --")) (ELit (LString "  ;; $mdk_bytes_match_at: does $nb occur in $hb at byte offset $off (caller bounds it).")) (ELit (LString "  (func $mdk_bytes_match_at (param $nb (ref $u8arr)) (param $hb (ref $u8arr)) (param $off i32) (result i32)")) (ELit (LString "    (local $j i32)")) (ELit (LString "    (block $done (loop $cmp")) (ELit (LString "      (br_if $done (i32.ge_s (local.get $j) (array.len (local.get $nb))))")) (ELit (LString "      (if (i32.ne (array.get_u $u8arr (local.get $hb) (i32.add (local.get $off) (local.get $j)))")) (ELit (LString "                  (array.get_u $u8arr (local.get $nb) (local.get $j)))")) (ELit (LString "        (then (return (i32.const 0))))")) (ELit (LString "      (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $cmp)))")) (ELit (LString "    (i32.const 1))")) (ELit (LString "  (func $mdk_str_starts_with (param $p (ref $str)) (param $s (ref $str)) (result i32)")) (ELit (LString "    (local $pb (ref $u8arr)) (local $sb (ref $u8arr))")) (ELit (LString "    (local.set $pb (struct.get $str $bytes (local.get $p)))")) (ELit (LString "    (local.set $sb (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (if (i32.gt_s (array.len (local.get $pb)) (array.len (local.get $sb)))")) (ELit (LString "      (then (return (i32.const 0))))")) (ELit (LString "    (call $mdk_bytes_match_at (local.get $pb) (local.get $sb) (i32.const 0)))")) (ELit (LString "  (func $mdk_str_ends_with (param $p (ref $str)) (param $s (ref $str)) (result i32)")) (ELit (LString "    (local $pb (ref $u8arr)) (local $sb (ref $u8arr))")) (ELit (LString "    (local.set $pb (struct.get $str $bytes (local.get $p)))")) (ELit (LString "    (local.set $sb (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (if (i32.gt_s (array.len (local.get $pb)) (array.len (local.get $sb)))")) (ELit (LString "      (then (return (i32.const 0))))")) (ELit (LString "    (call $mdk_bytes_match_at (local.get $pb) (local.get $sb)")) (ELit (LString "      (i32.sub (array.len (local.get $sb)) (array.len (local.get $pb)))))"))))
(DTypeSig true "strConcatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strConcatRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 stringConcat (List String) — walk the W7 cons list ──")) (ELit (LString "  (func $mdk_str_concat (param $list (ref eq)) (result (ref $str))")) (ELit (LString "    (local $w (ref eq)) (local $cell (ref $C_Cons)) (local $s (ref $str))")) (ELit (LString "    (local $total i32) (local $cpc i32) (local $off i32) (local $bl i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $sb (ref $u8arr))")) (ELit (LString "    ;; pass 1: total byte length + total codepoints.")) (ELit (LString "    (local.set $total (i32.const 0)) (local.set $cpc (i32.const 0))")) (ELit (LString "    (local.set $w (local.get $list))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))")) (ELit (LString "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))")) (ELit (LString "      (local.set $total (i32.add (local.get $total) (array.len (struct.get $str $bytes (local.get $s)))))")) (ELit (LString "      (local.set $cpc (i32.add (local.get $cpc) (struct.get $str $cp_count (local.get $s))))")) (ELit (LString "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l)))")) (ELit (LString "    ;; pass 2: copy each segment's bytes into a flat buffer.")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))")) (ELit (LString "    (local.set $off (i32.const 0))")) (ELit (LString "    (local.set $w (local.get $list))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))")) (ELit (LString "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))")) (ELit (LString "      (local.set $sb (struct.get $str $bytes (local.get $s)))")) (ELit (LString "      (local.set $bl (array.len (local.get $sb)))")) (ELit (LString "      (array.copy $u8arr $u8arr (local.get $buf) (local.get $off) (local.get $sb) (i32.const 0) (local.get $bl))")) (ELit (LString "      (local.set $off (i32.add (local.get $off) (local.get $bl)))")) (ELit (LString "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l2)))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))"))))
(DTypeSig true "strToIntRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strToIntRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8d stringToInt (decimal, optional sign; None on any other byte) ──")) (ELit (LString "  (func $mdk_str_to_int (param $s (ref $str)) (result (ref eq))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $c i32)")) (ELit (LString "    (local $neg i32) (local $seen i32) (local $acc i64) (local $d i64)")) (ELit (LString "    (local $limit i64) (local $acc2 i64)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (if (i32.eqz (local.get $n)) (then (return (ref.i31 (i32.const 1)))))")) (ELit (LString "    (local.set $c (array.get_u $u8arr (local.get $b) (i32.const 0)))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 45))")) (ELit (LString "      (then (local.set $neg (i32.const 1)) (local.set $i (i32.const 1)))")) (ELit (LString "      (else (if (i32.eq (local.get $c) (i32.const 43)) (then (local.set $i (i32.const 1))))))")) (ELit (LString "    (block $done (loop $step")) (ELit (LString "      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.or (i32.lt_u (local.get $c) (i32.const 48)) (i32.gt_u (local.get $c) (i32.const 57)))")) (ELit (LString "        (then (return (ref.i31 (i32.const 1)))))")) (ELit (LString "      (local.set $d (i64.extend_i32_u (i32.sub (local.get $c) (i32.const 48))))")) (ELit (LString "      (local.set $limit")) (ELit (LString "        (if (result i64) (local.get $neg)")) (ELit (LString "          (then (i64.const -4611686018427387904))")) (ELit (LString "          (else (i64.const -4611686018427387903))))")) (ELit (LString "      (if (i64.lt_s (local.get $acc) (i64.div_s (local.get $limit) (i64.const 10)))")) (ELit (LString "        (then (return (ref.i31 (i32.const 1)))))")) (ELit (LString "      (local.set $acc2 (i64.mul (local.get $acc) (i64.const 10)))")) (ELit (LString "      (if (i64.lt_s (local.get $acc2) (i64.add (local.get $limit) (local.get $d)))")) (ELit (LString "        (then (return (ref.i31 (i32.const 1)))))")) (ELit (LString "      (local.set $acc (i64.sub (local.get $acc2) (local.get $d)))")) (ELit (LString "      (local.set $seen (i32.const 1))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1)))")) (ELit (LString "      (br $step)))")) (ELit (LString "    (if (i32.eqz (local.get $seen)) (then (return (ref.i31 (i32.const 1)))))")) (ELit (LString "    (struct.new $C_Some (i32.const 0)")) (ELit (LString "      (call $mdk_box_int")) (ELit (LString "        (if (result i64) (local.get $neg)")) (ELit (LString "          (then (local.get $acc))")) (ELit (LString "          (else (i64.sub (i64.const 0) (local.get $acc)))))))"))))
(DTypeSig true "strReverseRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strReverseRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8d stringReverse — copy each UTF-8 sequence whole, last first ──")) (ELit (LString "  (func $mdk_str_reverse (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $buf (ref $u8arr)) (local $n i32)")) (ELit (LString "    (local $end i32) (local $start i32) (local $off i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $end (local.get $n))")) (ELit (LString "    (block $done (loop $step")) (ELit (LString "      (br_if $done (i32.eqz (local.get $end)))")) (ELit (LString "      (local.set $start (i32.sub (local.get $end) (i32.const 1)))")) (ELit (LString "      (block $lead (loop $back")) (ELit (LString "        (br_if $lead (i32.eqz (local.get $start)))")) (ELit (LString "        (br_if $lead (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (local.get $start)) (i32.const 192)) (i32.const 128)))")) (ELit (LString "        (local.set $start (i32.sub (local.get $start) (i32.const 1)))")) (ELit (LString "        (br $back)))")) (ELit (LString "      (array.copy $u8arr $u8arr (local.get $buf) (local.get $off)")) (ELit (LString "        (local.get $b) (local.get $start) (i32.sub (local.get $end) (local.get $start)))")) (ELit (LString "      (local.set $off (i32.add (local.get $off) (i32.sub (local.get $end) (local.get $start))))")) (ELit (LString "      (local.set $end (local.get $start))")) (ELit (LString "      (br $step)))")) (ELit (LString "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))"))))
(DTypeSig true "strJoinRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strJoinRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8d stringJoin — two passes over the cons list, separator between pieces ──")) (ELit (LString "  (func $mdk_str_join (param $sep (ref $str)) (param $list (ref eq)) (result (ref $str))")) (ELit (LString "    (local $w (ref eq)) (local $cell (ref $C_Cons)) (local $s (ref $str))")) (ELit (LString "    (local $sepb (ref $u8arr)) (local $sb (ref $u8arr)) (local $buf (ref $u8arr))")) (ELit (LString "    (local $total i32) (local $cpc i32) (local $parts i32) (local $off i32)")) (ELit (LString "    (local $bl i32) (local $first i32)")) (ELit (LString "    (local.set $sepb (struct.get $str $bytes (local.get $sep)))")) (ELit (LString "    (local.set $w (local.get $list))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))")) (ELit (LString "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))")) (ELit (LString "      (local.set $total (i32.add (local.get $total) (array.len (struct.get $str $bytes (local.get $s)))))")) (ELit (LString "      (local.set $cpc (i32.add (local.get $cpc) (struct.get $str $cp_count (local.get $s))))")) (ELit (LString "      (local.set $parts (i32.add (local.get $parts) (i32.const 1)))")) (ELit (LString "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l)))")) (ELit (LString "    (if (i32.gt_s (local.get $parts) (i32.const 1))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $total (i32.add (local.get $total)")) (ELit (LString "          (i32.mul (i32.sub (local.get $parts) (i32.const 1)) (array.len (local.get $sepb)))))")) (ELit (LString "        (local.set $cpc (i32.add (local.get $cpc)")) (ELit (LString "          (i32.mul (i32.sub (local.get $parts) (i32.const 1)) (struct.get $str $cp_count (local.get $sep)))))))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))")) (ELit (LString "    (local.set $first (i32.const 1))")) (ELit (LString "    (local.set $w (local.get $list))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))")) (ELit (LString "      (if (i32.eqz (local.get $first))")) (ELit (LString "        (then")) (ELit (LString "          (array.copy $u8arr $u8arr (local.get $buf) (local.get $off)")) (ELit (LString "            (local.get $sepb) (i32.const 0) (array.len (local.get $sepb)))")) (ELit (LString "          (local.set $off (i32.add (local.get $off) (array.len (local.get $sepb))))))")) (ELit (LString "      (local.set $first (i32.const 0))")) (ELit (LString "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))")) (ELit (LString "      (local.set $sb (struct.get $str $bytes (local.get $s)))")) (ELit (LString "      (local.set $bl (array.len (local.get $sb)))")) (ELit (LString "      (array.copy $u8arr $u8arr (local.get $buf) (local.get $off) (local.get $sb) (i32.const 0) (local.get $bl))")) (ELit (LString "      (local.set $off (i32.add (local.get $off) (local.get $bl)))")) (ELit (LString "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l2)))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))"))))
(DTypeSig true "appendRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "appendRuntimeLines" () (EListLit (ELit (LString "  ;; ── W13 runtime-dispatched `++` (String concat OR List append) ──")) (ELit (LString "  ;; List append is ITERATIVE (destination-passing over the mut $C_Cons tail),")) (ELit (LString "  ;; mirroring the native mdk_list_append: walk `a` head-first, struct.new each")) (ELit (LString "  ;; result cell with a placeholder i31 tail, struct.set it into the previous")) (ELit (LString "  ;; cell's mut tail, and after the loop point the final tail at `b`.  O(1) extra")) (ELit (LString "  ;; space, no self-recursion → no wasm-stack growth proportional to length(a).")) (ELit (LString "  (func $mdk_append (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (local $cell (ref $C_Cons))")) (ELit (LString "    (local $result (ref eq))")) (ELit (LString "    (local $dest (ref $C_Cons))")) (ELit (LString "    (local $new (ref $C_Cons))")) (ELit (LString "    ;; String `++`: left is a $str struct → byte concat.")) (ELit (LString "    (if (ref.test (ref $str) (local.get $a))")) (ELit (LString "      (then (return (call $mdk_str_append (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b))))))")) (ELit (LString "    ;; List `++`: a Nil (non-$C_Cons) left → b unchanged.")) (ELit (LString "    (if (i32.eqz (ref.test (ref $C_Cons) (local.get $a)))")) (ELit (LString "      (then (return (local.get $b))))")) (ELit (LString "    ;; First cell: copy head(a), placeholder i31 tail (overwritten before any read).")) (ELit (LString "    (local.set $cell (ref.cast (ref $C_Cons) (local.get $a)))")) (ELit (LString "    (local.set $dest (struct.new $C_Cons (i32.const 0)")) (ELit (LString "      (struct.get $C_Cons 1 (local.get $cell)) (ref.i31 (i32.const 0))))")) (ELit (LString "    (local.set $result (local.get $dest))")) (ELit (LString "    ;; Walk the rest of `a`, appending a fresh cell into the previous mut tail.")) (ELit (LString "    (block $done")) (ELit (LString "      (loop $l")) (ELit (LString "        ;; If tail(cell) is not a Cons (i.e. Nil), we are done.")) (ELit (LString "        (br_if $done (i32.eqz (ref.test (ref $C_Cons)")) (ELit (LString "          (struct.get $C_Cons 2 (local.get $cell)))))")) (ELit (LString "        (local.set $cell (ref.cast (ref $C_Cons)")) (ELit (LString "          (struct.get $C_Cons 2 (local.get $cell))))")) (ELit (LString "        (local.set $new (struct.new $C_Cons (i32.const 0)")) (ELit (LString "          (struct.get $C_Cons 1 (local.get $cell)) (ref.i31 (i32.const 0))))")) (ELit (LString "        (struct.set $C_Cons 2 (local.get $dest) (local.get $new))")) (ELit (LString "        (local.set $dest (local.get $new))")) (ELit (LString "        (br $l)))")) (ELit (LString "    ;; Final tail → b (sharing it, not copying).")) (ELit (LString "    (struct.set $C_Cons 2 (local.get $dest) (local.get $b))")) (ELit (LString "    (local.get $result))"))))
(DData Public "Wide64W" () ((variant "Wide64W" (ConPos (TyCon "Bool") (TyCon "Bool")))) ())
(DTypeSig false "wideArmsW" (TyFun (TyCon "Wide64W") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "wideArmsW" ((PCon "Wide64W" (PVar "u64") (PVar "i64")) (PVar "arm")) (EBinOp "++" (EIf (EVar "u64") (EApp (EVar "arm") (ELit (LString "$u64"))) (EListLit)) (EIf (EVar "i64") (EApp (EVar "arm") (ELit (LString "$i64"))) (EListLit))))
(DTypeSig false "boxed64GetW" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "boxed64GetW" ((PVar "ty") (PVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(struct.get ")) (EApp (EVar "display") (EVar "ty"))) (ELit (LString " 0 (ref.cast (ref "))) (EApp (EVar "display") (EVar "ty"))) (ELit (LString ") (local.get "))) (EApp (EVar "display") (EVar "v"))) (ELit (LString ")))"))))
(DTypeSig false "wideEqArmsW" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "wideEqArmsW" ((PVar "w")) (EApp (EApp (EVar "wideArmsW") (EVar "w")) (EVar "eqArmW")))
(DTypeSig false "eqArmW" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eqArmW" ((PVar "ty")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (if (ref.test (ref ")) (EApp (EVar "display") (EVar "ty"))) (ELit (LString ") (local.get $a))"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "      (then (return (ref.i31 (i64.eq ")) (EApp (EVar "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$a"))))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$b"))))) (ELit (LString ")))))")))))
(DTypeSig false "wideCmpArmsW" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "wideCmpArmsW" ((PVar "w")) (EApp (EApp (EVar "wideArmsW") (EVar "w")) (EVar "cmpArmW")))
(DTypeSig false "cmpArmW" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "cmpArmW" ((PVar "ty")) (EBlock (DoLet false false (PVar "sfx") (EIf (EBinOp "==" (EVar "ty") (ELit (LString "$u64"))) (ELit (LString "u")) (ELit (LString "s")))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (if (ref.test (ref ")) (EApp (EVar "display") (EVar "ty"))) (ELit (LString ") (local.get $a))"))) (ELit (LString "      (then")) (EBinOp "++" (EBinOp "++" (ELit (LString "        (local.set $ia ")) (EApp (EVar "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$a"))))) (ELit (LString ")"))) (EBinOp "++" (EBinOp "++" (ELit (LString "        (local.set $ib ")) (EApp (EVar "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$b"))))) (ELit (LString ")"))) (EBinOp "++" (EBinOp "++" (ELit (LString "        (if (i64.lt_")) (EApp (EVar "display") (EVar "sfx"))) (ELit (LString " (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))"))) (EBinOp "++" (EBinOp "++" (ELit (LString "        (if (i64.gt_")) (EApp (EVar "display") (EVar "sfx"))) (ELit (LString " (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))"))) (ELit (LString "        (return (i32.const 0))))"))))))
(DTypeSig false "wideArithArmsW" (TyFun (TyCon "Wide64W") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "wideArithArmsW" ((PVar "w") (PVar "instr")) (EApp (EApp (EVar "wideArmsW") (EVar "w")) (ELam ((PVar "ty")) (EApp (EApp (EVar "arithArmW") (EVar "ty")) (EVar "instr")))))
(DTypeSig false "arithArmW" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "arithArmW" ((PVar "ty") (PVar "instr")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (if (ref.test (ref ")) (EApp (EVar "display") (EVar "ty"))) (ELit (LString ") (local.get $a))"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "      (then (return (struct.new ")) (EApp (EVar "display") (EVar "ty"))) (ELit (LString " ("))) (EApp (EVar "display") (EVar "instr"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$a"))))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$b"))))) (ELit (LString ")))))")))))
(DTypeSig false "wideDivArmsW" (TyFun (TyCon "Wide64W") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "wideDivArmsW" ((PVar "w") (PVar "uInstr") (PVar "sInstr") (PVar "trap")) (EApp (EApp (EVar "wideArmsW") (EVar "w")) (ELam ((PVar "ty")) (EApp (EApp (EApp (EVar "divArmW") (EVar "ty")) (EIf (EBinOp "==" (EVar "ty") (ELit (LString "$u64"))) (EVar "uInstr") (EVar "sInstr"))) (EVar "trap")))))
(DTypeSig false "divArmW" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "divArmW" ((PVar "ty") (PVar "instr") (PVar "trap")) (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (if (ref.test (ref ")) (EApp (EVar "display") (EVar "ty"))) (ELit (LString ") (local.get $a))"))) (ELit (LString "      (then")) (EBinOp "++" (EBinOp "++" (ELit (LString "        (local.set $vdr ")) (EApp (EVar "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$b"))))) (ELit (LString ")"))) (ELit (LString "        (if (i64.eqz (local.get $vdr)) (then"))) (EVar "trap")) (EListLit (ELit (LString "        ))")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "        (return (struct.new ")) (EApp (EVar "display") (EVar "ty"))) (ELit (LString " ("))) (EApp (EVar "display") (EVar "instr"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$a"))))) (ELit (LString " (local.get $vdr))))))"))))))
(DTypeSig true "i64RuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "i64RuntimeLines" () (EListLit (ELit (LString "  ;; -- I64 kernel: signed division that wraps at minBound / -1 --")) (ELit (LString "  (func $mdk_i64_div (param $a i64) (param $b i64) (result i64)")) (ELit (LString "    (if (i64.eq (local.get $b) (i64.const -1))")) (ELit (LString "      (then (return (i64.sub (i64.const 0) (local.get $a)))))")) (ELit (LString "    (i64.div_s (local.get $a) (local.get $b)))"))))
(DTypeSig true "u64RuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "u64RuntimeLines" () (EListLit (ELit (LString "  ;; -- U64 kernels: range-checked shifts and the high half of the product --")) (ELit (LString "  (func $mdk_u64_shl (param $x i64) (param $k i64) (result i64)")) (ELit (LString "    (select (i64.shl (local.get $x) (local.get $k)) (i64.const 0)")) (ELit (LString "      (i64.lt_u (local.get $k) (i64.const 64))))")) (ELit (LString "  (func $mdk_u64_shr (param $x i64) (param $k i64) (result i64)")) (ELit (LString "    (select (i64.shr_u (local.get $x) (local.get $k)) (i64.const 0)")) (ELit (LString "      (i64.lt_u (local.get $k) (i64.const 64))))")) (ELit (LString "  (func $mdk_u64_mulhi (param $a i64) (param $b i64) (result i64)")) (ELit (LString "    (local $al i64) (local $ah i64) (local $bl i64) (local $bh i64)")) (ELit (LString "    (local $lh i64) (local $hl i64) (local $mid i64)")) (ELit (LString "    (local.set $al (i64.and (local.get $a) (i64.const 0xFFFFFFFF)))")) (ELit (LString "    (local.set $ah (i64.shr_u (local.get $a) (i64.const 32)))")) (ELit (LString "    (local.set $bl (i64.and (local.get $b) (i64.const 0xFFFFFFFF)))")) (ELit (LString "    (local.set $bh (i64.shr_u (local.get $b) (i64.const 32)))")) (ELit (LString "    (local.set $lh (i64.mul (local.get $al) (local.get $bh)))")) (ELit (LString "    (local.set $hl (i64.mul (local.get $ah) (local.get $bl)))")) (ELit (LString "    (local.set $mid (i64.add (i64.add")) (ELit (LString "      (i64.shr_u (i64.mul (local.get $al) (local.get $bl)) (i64.const 32))")) (ELit (LString "      (i64.and (local.get $lh) (i64.const 0xFFFFFFFF)))")) (ELit (LString "      (i64.and (local.get $hl) (i64.const 0xFFFFFFFF))))")) (ELit (LString "    (i64.add (i64.add (i64.add")) (ELit (LString "      (i64.mul (local.get $ah) (local.get $bh))")) (ELit (LString "      (i64.shr_u (local.get $lh) (i64.const 32)))")) (ELit (LString "      (i64.shr_u (local.get $hl) (i64.const 32)))")) (ELit (LString "      (i64.shr_u (local.get $mid) (i64.const 32))))"))))
(DTypeSig true "valueEqRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueEqRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; -- layer-9 runtime-shape-dispatched `==`/`/=` (String byte-equal OR immediate identity) --")) (ELit (LString "  (func $mdk_value_eq (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    ;; both operands are $str structs -> byte equality.")) (ELit (LString "    (if (i32.and (ref.test (ref $str) (local.get $a)) (ref.test (ref $str) (local.get $b)))")) (ELit (LString "      (then (return (ref.i31 (i32.eq")) (ELit (LString "        (i32.const 1)")) (ELit (LString "        (i31.get_u (ref.cast (ref i31) (call $mdk_str_compare (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b)))))))))) ;; Eq == ordinal 1"))) (EApp (EVar "wideEqArmsW") (EVar "w"))) (EListLit (ELit (LString "    ;; A2 (poly-Eq-on-Float): two boxed $float cells have distinct identities, so the")) (ELit (LString "    ;; `ref.eq` fallback would report equal floats as unequal — compare f64 values.")) (ELit (LString "    (if (i32.and (ref.test (ref $float) (local.get $a)) (ref.test (ref $float) (local.get $b)))")) (ELit (LString "      (then (return (ref.i31 (f64.eq")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    ;; otherwise immediate/struct identity (i31 Int/Bool/Char/Unit, or ctor cells).")) (ELit (LString "    ;; layer-17 §2.1: a >2^30 Int is a $boxint struct, so two equal large Ints have")) (ELit (LString "    ;; distinct identities — when either side is a $boxint compare the unboxed i64.")) (ELit (LString "    (if (i32.or (ref.test (ref $boxint) (local.get $a)) (ref.test (ref $boxint) (local.get $b)))")) (ELit (LString "      (then (return (ref.i31 (i64.eq (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "    (ref.i31 (i32.eqz (i32.eqz (ref.eq (local.get $a) (local.get $b))))))")) (ELit (LString "  ;; -- layer-9 runtime-shape-dispatched ordering (String byte-order OR i31 signed) -> i32 -1/0/1 --")) (ELit (LString "  (func $mdk_value_cmp (param $a (ref eq)) (param $b (ref eq)) (result i32)")) (ELit (LString "    (local $o i32) (local $ia i64) (local $ib i64) (local $fa f64) (local $fb f64)")) (ELit (LString "    (if (i32.and (ref.test (ref $str) (local.get $a)) (ref.test (ref $str) (local.get $b)))")) (ELit (LString "      (then")) (ELit (LString "        ;; $mdk_str_compare -> Ordering i31 (Lt 0 / Eq 1 / Gt 2); map to -1/0/1.")) (ELit (LString "        (local.set $o (i31.get_u (ref.cast (ref i31) (call $mdk_str_compare (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b))))))")) (ELit (LString "        (return (i32.sub (local.get $o) (i32.const 1)))))")) (ELit (LString "    ;; A2 (poly-Ord-on-Float): a boxed $float operand -> f64 compare -> -1/0/1.")) (ELit (LString "    ;; Mirrors the arith helpers' left-operand $float discriminant.  A poly `Ord`")) (ELit (LString "    ;; compare (`a > b` on a Num/Ord type-var param) reaches here with $float cells;")) (ELit (LString "    ;; without this arm $mdk_unbox_int would ref.cast the $float to $boxint -> trap.")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))")) (ELit (LString "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))")) (ELit (LString "        (if (f64.lt (local.get $fa) (local.get $fb)) (then (return (i32.const -1))))")) (ELit (LString "        (if (f64.gt (local.get $fa) (local.get $fb)) (then (return (i32.const 1))))")) (ELit (LString "        (return (i32.const 0))))")))) (EApp (EVar "wideCmpArmsW") (EVar "w"))) (EListLit (ELit (LString "    ;; layer-17 §2.1: Int compare over the i64 box/unbox seam (handles >2^30 boxed).")) (ELit (LString "    (local.set $ia (call $mdk_unbox_int (local.get $a)))")) (ELit (LString "    (local.set $ib (call $mdk_unbox_int (local.get $b)))")) (ELit (LString "    (if (i64.lt_s (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))")) (ELit (LString "    (if (i64.gt_s (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))")) (ELit (LString "    (i32.const 0))")) (ELit (LString "  ;; -- #305 per-op IEEE relational predicates (Float f64 pred; else 3-way) --")) (ELit (LString "  (func $mdk_value_lt (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.lt")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.lt_s (call $mdk_value_cmp (local.get $a) (local.get $b)) (i32.const 0))))")) (ELit (LString "  (func $mdk_value_le (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.le")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.le_s (call $mdk_value_cmp (local.get $a) (local.get $b)) (i32.const 0))))")) (ELit (LString "  (func $mdk_value_gt (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.gt")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.gt_s (call $mdk_value_cmp (local.get $a) (local.get $b)) (i32.const 0))))")) (ELit (LString "  (func $mdk_value_ge (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.ge")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.ge_s (call $mdk_value_cmp (local.get $a) (local.get $b)) (i32.const 0))))")))))
(DTypeSig false "asciiTrapBytesW" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "asciiTrapBytesW" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "asciiTrapGoW") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "asciiTrapGoW" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "asciiTrapGoW" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EBinOp "::" (EBinOp "++" (ELit (LString "        i32.const ")) (EApp (EVar "intToString") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))) (EBinOp "::" (ELit (LString "        call $mdk_write_err_byte")) (EApp (EApp (EApp (EVar "asciiTrapGoW") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "valueDivZeroTrapW" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "valueDivZeroTrapW" () (EBinOp "++" (EApp (EVar "asciiTrapBytesW") (ELit (LString "runtime error [E-DIV-ZERO]: division by zero\n"))) (EListLit (ELit (LString "        unreachable")))))
(DTypeSig false "valueModZeroTrapW" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "valueModZeroTrapW" () (EBinOp "++" (EApp (EVar "asciiTrapBytesW") (ELit (LString "runtime error [E-MOD-ZERO]: modulo by zero\n"))) (EListLit (ELit (LString "        unreachable")))))
(DTypeSig true "valueAddRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueAddRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; -- A0 runtime value-tag-dispatched arithmetic (poly-`Num`: Int i31/$boxint OR $float) --")) (ELit (LString "  (func $mdk_value_add (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))"))) (EApp (EApp (EVar "wideArithArmsW") (EVar "w")) (ELit (LString "i64.add")))) (EListLit (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.add")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (call $mdk_int_add (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)) (i64.const 0))))))")))))
(DTypeSig true "valueSubRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueSubRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  (func $mdk_value_sub (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))"))) (EApp (EApp (EVar "wideArithArmsW") (EVar "w")) (ELit (LString "i64.sub")))) (EListLit (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.sub")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (call $mdk_int_sub (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)) (i64.const 0))))))")))))
(DTypeSig true "valueMulRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueMulRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  (func $mdk_value_mul (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))"))) (EApp (EApp (EVar "wideArithArmsW") (EVar "w")) (ELit (LString "i64.mul")))) (EListLit (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.mul")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (call $mdk_int_mul (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)) (i64.const 0))))))")))))
(DTypeSig true "valueDivRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueDivRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; #371: int arm guards the divisor (mirrors emitDivZeroGuard's concrete-Int")) (ELit (LString "  ;; guard) — stash $b's unboxed value in $vdr, trap the coded [E-DIV-ZERO] line")) (ELit (LString "  ;; if zero, else the checked $mdk_int_div on the stashed value (unbox once, not twice).")) (ELit (LString "  (func $mdk_value_div (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (local $vdr i64)"))) (EApp (EApp (EApp (EApp (EVar "wideDivArmsW") (EVar "w")) (ELit (LString "i64.div_u"))) (ELit (LString "call $mdk_i64_div"))) (EVar "valueDivZeroTrapW"))) (EListLit (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.div")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else")) (ELit (LString "        (local.set $vdr (call $mdk_unbox_int (local.get $b)))")) (ELit (LString "        (if (i64.eqz (local.get $vdr)) (then")))) (EVar "valueDivZeroTrapW")) (EListLit (ELit (LString "        ))")) (ELit (LString "        (call $mdk_box_int (call $mdk_int_div (call $mdk_unbox_int (local.get $a)) (local.get $vdr) (i64.const 0))))))")))))
(DTypeSig true "valueModRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueModRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; #345 Float arm is fmod ($mdk_float_rem), NOT the old inline `a - b*trunc(a/b)`")) (ELit (LString "  ;; (which lost precision for large |a/b|, e.g. 1e300 % 7 -> 1e300).  Mirrors native")) (ELit (LString "  ;; mdk_num_mod's fmod and the monomorphic Float `%` path (emitFloatBinRef).")) (ELit (LString "  ;; #371: int arm guards the divisor the same way as $mdk_value_div above.")) (ELit (LString "  (func $mdk_value_mod (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (local $vdr i64)"))) (EApp (EApp (EApp (EApp (EVar "wideDivArmsW") (EVar "w")) (ELit (LString "i64.rem_u"))) (ELit (LString "i64.rem_s"))) (EVar "valueModZeroTrapW"))) (EListLit (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (call $mdk_float_rem")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else")) (ELit (LString "        (local.set $vdr (call $mdk_unbox_int (local.get $b)))")) (ELit (LString "        (if (i64.eqz (local.get $vdr)) (then")))) (EVar "valueModZeroTrapW")) (EListLit (ELit (LString "        ))")) (ELit (LString "        (call $mdk_box_int (i64.rem_s (call $mdk_unbox_int (local.get $a)) (local.get $vdr))))))")))))
(DTypeSig true "valueCmpNumRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueCmpNumRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; -- A1 poly-`Ord`/`Eq`-on-Float, NUM-ONLY (no $str): $float f64-eq/cmp else i64 --")) (ELit (LString "  (func $mdk_value_eq_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))"))) (EApp (EVar "wideEqArmsW") (EVar "w"))) (EListLit (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.eq")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i64.eq (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))")) (ELit (LString "  (func $mdk_value_cmp_num (param $a (ref eq)) (param $b (ref eq)) (result i32)")) (ELit (LString "    (local $fa f64) (local $fb f64) (local $ia i64) (local $ib i64)")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))")) (ELit (LString "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))")) (ELit (LString "        (if (f64.lt (local.get $fa) (local.get $fb)) (then (return (i32.const -1))))")) (ELit (LString "        (if (f64.gt (local.get $fa) (local.get $fb)) (then (return (i32.const 1))))")) (ELit (LString "        (return (i32.const 0))))")))) (EApp (EVar "wideCmpArmsW") (EVar "w"))) (EListLit (ELit (LString "    (local.set $ia (call $mdk_unbox_int (local.get $a)))")) (ELit (LString "    (local.set $ib (call $mdk_unbox_int (local.get $b)))")) (ELit (LString "    (if (i64.lt_s (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))")) (ELit (LString "    (if (i64.gt_s (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))")) (ELit (LString "    (i32.const 0))")) (ELit (LString "  (func $mdk_value_lt_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.lt")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.lt_s (call $mdk_value_cmp_num (local.get $a) (local.get $b)) (i32.const 0))))")) (ELit (LString "  (func $mdk_value_le_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.le")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.le_s (call $mdk_value_cmp_num (local.get $a) (local.get $b)) (i32.const 0))))")) (ELit (LString "  (func $mdk_value_gt_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.gt")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.gt_s (call $mdk_value_cmp_num (local.get $a) (local.get $b)) (i32.const 0))))")) (ELit (LString "  (func $mdk_value_ge_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.ge")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.ge_s (call $mdk_value_cmp_num (local.get $a) (local.get $b)) (i32.const 0))))")))))
(DTypeSig true "rngStateGlobalLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "rngStateGlobalLines" () (EListLit (ELit (LString "  (global $mdk_rng_state (mut i64) (i64.const 0))"))))
(DTypeSig true "rngRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "rngRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 SplitMix64 RNG (byte-identical to medaka_rt.c) ──")) (ELit (LString "  (func $mdk_next_u64 (result i64)")) (ELit (LString "    (local $z i64)")) (ELit (LString "    (global.set $mdk_rng_state (i64.add (global.get $mdk_rng_state) (i64.const 0x9E3779B97F4A7C15)))")) (ELit (LString "    (local.set $z (global.get $mdk_rng_state))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 30))) (i64.const 0xBF58476D1CE4E5B9)))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 27))) (i64.const 0x94D049BB133111EB)))")) (ELit (LString "    (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 31))))")) (ELit (LString "  ;; #179 randomInt lo hi : i64 lo/hi -> i64 in [lo,hi] (INCLUSIVE).  lo > hi -> lo.")) (ELit (LString "  ;; i64 (not i32): a range > 2^30 (e.g. randomInt 0 1000000000000000) overflows i32 —")) (ELit (LString "  ;; and the old ref.i31 box at the call site trapped `illegal cast` on the large draw.")) (ELit (LString "  ;; Byte-identical to native mdk_random_int: the span hi-lo+1 is read UNSIGNED, so")) (ELit (LString "  ;; the full Int range's 2^63 draws too (#3451); it is never 0 for 63-bit bounds.")) (ELit (LString "  (func $mdk_random_int (param $lo i64) (param $hi i64) (result i64)")) (ELit (LString "    (if (result i64) (i64.lt_s (local.get $hi) (local.get $lo))")) (ELit (LString "      (then (local.get $lo))")) (ELit (LString "      (else")) (ELit (LString "        (i64.add (local.get $lo)")) (ELit (LString "          (i64.rem_u (call $mdk_next_u64)")) (ELit (LString "            (i64.add (i64.sub (local.get $hi) (local.get $lo)) (i64.const 1)))))))")) (ELit (LString "  (func $mdk_random_bool (result i32)")) (ELit (LString "    (i32.wrap_i64 (i64.and (call $mdk_next_u64) (i64.const 1))))")) (ELit (LString "  (func $mdk_random_char (result i32)")) (ELit (LString "    (i32.add (i32.const 32) (i32.wrap_i64 (i64.rem_u (call $mdk_next_u64) (i64.const 95)))))"))))
(DTypeSig true "hashRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hashRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 per-type hashers (byte-identical to medaka_rt.c) ──")) (ELit (LString "  ;; SplitMix64 finalizer as a pure mixer (no state update).")) (ELit (LString "  (func $mdk_hash_mix64 (param $x i64) (result i64)")) (ELit (LString "    (local $z i64)")) (ELit (LString "    (local.set $z (i64.add (local.get $x) (i64.const 0x9E3779B97F4A7C15)))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 30))) (i64.const 0xBF58476D1CE4E5B9)))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 27))) (i64.const 0x94D049BB133111EB)))")) (ELit (LString "    (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 31))))")) (ELit (LString "  ;; hashInt / hashChar : mix64(value) & 0x3FFFFFFF.  #199: `n` is the FULL-WIDTH i64")) (ELit (LString "  ;; value (hashInt unboxes via $mdk_unbox_int; hashChar sign-extends its i31 codepoint),")) (ELit (LString "  ;; matching medaka_rt.c's signed `tagged>>1` over the whole 63-bit int — so an Int key")) (ELit (LString "  ;; outside +-2^30 (e.g. a HashMap Int) hashes correctly instead of trapping the i31 cast.")) (ELit (LString "  (func $mdk_hash_int (param $n i64) (result i32)")) (ELit (LString "    (i32.wrap_i64 (i64.and (call $mdk_hash_mix64 (local.get $n)) (i64.const 0x3FFFFFFF))))")) (ELit (LString "  (func $mdk_hash_bool (param $b i32) (result i32)")) (ELit (LString "    (if (result i32) (local.get $b) (then (i32.const 1)) (else (i32.const 0))))"))))
(DTypeSig true "hashStringRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hashStringRuntimeLines" () (EListLit (ELit (LString "  ;; hashString : FNV-1a over UTF-8 BYTES, masked.")) (ELit (LString "  (func $mdk_hash_string (param $s (ref $str)) (result i32)")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $h i64)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $h (i64.const 0xCBF29CE484222325))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $h (i64.mul (i64.xor (local.get $h) (i64.extend_i32_u (array.get_u $u8arr (local.get $b) (local.get $i)))) (i64.const 0x100000001B3)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (i32.wrap_i64 (i64.and (local.get $h) (i64.const 0x3FFFFFFF))))"))))
(DTypeSig true "charClassRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "charClassRuntimeLines" () (EListLit (ELit (LString "  ;; ── W11b ASCII char classification + case mapping (byte-identical to medaka_rt.c) ──")) (ELit (LString "  (func $mdk_char_is_alpha (param $c i32) (result i32)")) (ELit (LString "    (i32.or")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))))")) (ELit (LString "  (func $mdk_char_is_space (param $c i32) (result i32)")) (ELit (LString "    (i32.or")) (ELit (LString "      (i32.eq (local.get $c) (i32.const 32))")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 9)) (i32.le_u (local.get $c) (i32.const 13)))))")) (ELit (LString "  (func $mdk_char_is_upper (param $c i32) (result i32)")) (ELit (LString "    (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90))))")) (ELit (LString "  (func $mdk_char_is_lower (param $c i32) (result i32)")) (ELit (LString "    (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122))))")) (ELit (LString "  ;; charIsPunct: exact set from medaka_rt.c switch — Unicode Pc/Pd/Pe/Pf/Pi/Po/Ps ASCII.")) (ELit (LString "  ;; Included: ! \" # % & ' ( ) * , - . / : ; ? @ [ \\ ] _ { }")) (ELit (LString "  ;; Excluded ($+<=>^`|~): those are Unicode symbols (Sm/Sc/Sk), not punctuation.")) (ELit (LString "  ;; Right-associative OR chain over 23 chars = 22 i32.or nodes.")) (ELit (LString "  (func $mdk_char_is_punct (param $c i32) (result i32)")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 33))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 34))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 35))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 37))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 38))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 39))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 40))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 41))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 42))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 44))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 45))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 46))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 47))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 58))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 59))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 63))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 64))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 91))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 92))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 93))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 95))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 123))")) (ELit (LString "           (i32.eq (local.get $c) (i32.const 125))")) (ELit (LString "    )))))))))))))))))))))))")) (ELit (LString "  (func $mdk_char_to_upper (param $c i32) (result i32)")) (ELit (LString "    (if (result i32)")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))")) (ELit (LString "      (then (i32.sub (local.get $c) (i32.const 32)))")) (ELit (LString "      (else (local.get $c))))")) (ELit (LString "  (func $mdk_char_to_lower (param $c i32) (result i32)")) (ELit (LString "    (if (result i32)")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))")) (ELit (LString "      (then (i32.add (local.get $c) (i32.const 32)))")) (ELit (LString "      (else (local.get $c))))"))))
(DTypeSig true "floatFmtImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatFmtImportLines" () (EListLit (ELit (LString "  ;; -- W8b floatToString host seam (shortest-round-trip since #57 — reproduced JS-side, see run.js) --")) (ELit (LString "  (import \"env\" \"mdk_float_fmt\" (func $mdk_float_fmt (param f64) (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_float_fmt_byte\" (func $mdk_float_fmt_byte (param i32) (result i32)))"))))
(DTypeSig true "hostImportLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "hostImportLines" ((PList)) (EListLit))
(DFunDef false "hostImportLines" ((PCons (PVar "key") (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "stderrByteKey")) (EApp (EVar "hostImportLines") (EVar "rest")) (EBinOp "::" (EApp (EVar "hostImportLine") (EVar "key")) (EApp (EVar "hostImportLines") (EVar "rest")))))
(DTypeSig true "stderrByteKey" (TyCon "String"))
(DFunDef false "stderrByteKey" () (ELit (LString "mdk_write_err_byte")))
(DTypeSig false "hostImportLine" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "hostImportLine" ((PVar "key")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  (import \"env\" \"")) (EApp (EVar "display") (EVar "key"))) (ELit (LString "\" (func $"))) (EApp (EVar "display") (EVar "key"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "hostImportSig") (EVar "key")))) (ELit (LString "))"))))
(DTypeSig false "hostImportSig" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "hostImportSig" ((PVar "key")) (EMatch (EApp (EVar "hostImportSigOf") (EVar "key")) (arm (PCon "Some" (PVar "sig")) () (EVar "sig")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: host key ")) (EApp (EVar "display") (EVar "key"))) (ELit (LString " has no wasm import signature in wasm_preamble.mdk")))))))
(DTypeSig true "hostImportSigOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_exit"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_wall_time_sec"))) (EApp (EVar "Some") (ELit (LString " (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_monotonic_sec"))) (EApp (EVar "Some") (ELit (LString " (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_sleep_ms"))) (EApp (EVar "Some") (ELit (LString " (param i64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_fetch_text"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_cbrt"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_exp"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_log"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_log2"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_log10"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_sin"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_cos"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_tan"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_asin"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_acos"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_atan"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_sinh"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_cosh"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_tanh"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_pow"))) (EApp (EVar "Some") (EVar "binaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_atan2"))) (EApp (EVar "Some") (EVar "binaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_hypot"))) (EApp (EVar "Some") (EVar "binaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_path_reset"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_path_push"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_exists"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_get_env"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_line"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_all"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_exactly"))) (EApp (EVar "Some") (ELit (LString " (param i64) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_os_entropy"))) (EApp (EVar "Some") (ELit (LString " (param i64) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_executable_path"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_args_count"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_arg_len"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_arg_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32) (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_result_len"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_result_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_reset"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_push"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_commit"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_str_to_float"))) (EApp (EVar "Some") (ELit (LString " (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_str_to_float_ok"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_grant_reset"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_grant_push"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_canonicalize_path"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_append_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_make_dir"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_remove_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_remove_dir"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_fsync"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_mode"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_mode"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_rename"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_list_dir"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_stat_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_stat_field"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_bound_enter"))) (EApp (EVar "Some") (ELit (LString " (param i32) (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_bound_exit"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" (PWild) (EVar "None"))
(DTypeSig true "floatStrRuntimeLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "floatStrRuntimeLines" ((PVar "keys")) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_str_to_float"))) (EVar "keys")) (EVar "floatStrLines")))
(DTypeSig false "floatStrLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatStrLines" () (EListLit (ELit (LString "  ;; stringToFloat : $str -> Option Float (ref eq).")) (ELit (LString "  (func $mdk_string_to_float (param $s (ref $str)) (result (ref eq))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32) (local $d f64)")) (ELit (LString "    (call $mdk_path_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $done (loop $loop")) (ELit (LString "      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1)))")) (ELit (LString "      (br $loop)))")) (ELit (LString "    (local.set $d (call $mdk_str_to_float))")) (ELit (LString "    ;; #370: the host latched an ok flag during that call; ask it, rather than")) (ELit (LString "    ;; testing $d for NaN — strtod(\"nan\") legitimately yields Some(NaN), and")) (ELit (LString "    ;; strtod(\"\")/strtod(\"1.5 \") legitimately FAIL with a non-NaN value.")) (ELit (LString "    (if (result (ref eq)) (i32.eqz (call $mdk_str_to_float_ok))")) (ELit (LString "      (then (ref.i31 (i32.const 1)))")) (ELit (LString "      (else (struct.new $C_Some (i32.const 0) (struct.new $float (local.get $d)))))")) (ELit (LString "  )"))))
(DTypeSig true "floatRemRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatRemRuntimeLines" () (EListLit (ELit (LString "  (func $mdk_float_rem (param $a f64) (param $b f64) (result f64)")) (ELit (LString "    (local $x f64) (local $y f64) (local $t f64)")) (ELit (LString "    (local.set $y (f64.abs (local.get $b)))")) (ELit (LString "    (if (result f64)")) (ELit (LString "      (i32.or (i32.or")) (ELit (LString "        (f64.ne (f64.sub (local.get $a) (local.get $a)) (f64.const 0))")) (ELit (LString "        (f64.ne (local.get $b) (local.get $b)))")) (ELit (LString "        (f64.eq (local.get $y) (f64.const 0)))")) (ELit (LString "      ;; #672: the NaN result must carry the HOST's NaN SIGN, not WAT `nan`.  WAT")) (ELit (LString "      ;; `(f64.const nan)` is the FIXED canonical +NaN (0x7FF8..), but eval")) (ELit (LString "      ;; (`floatRem`=fmod) and native (`mdk_float_rem`=fmod) yield the host's NaN")) (ELit (LString "      ;; -- -NaN (0xFFF8..) on x86 -- and under the sign-dependent totalOrder (N6)")) (ELit (LString "      ;; a +NaN sorts/compares/hashes OPPOSITELY, so a fixed +NaN here made every")) (ELit (LString "      ;; `%`-NaN (e.g. `x % 0.0`) disagree with the other two engines on x86.")) (ELit (LString "      ;; `f64.div 0/0` is computed at RUNTIME by V8 (same as the `/` path), so it")) (ELit (LString "      ;; yields whatever NaN this box's hardware does -- matching eval/native and")) (ELit (LString "      ;; the wasm `f64.div` NaN on every platform (#509-safe: host-following, not")) (ELit (LString "      ;; a baked sign).")) (ELit (LString "      (then (f64.div (f64.const 0) (f64.const 0)))")) (ELit (LString "      (else")) (ELit (LString "        (local.set $x (f64.abs (local.get $a)))")) (ELit (LString "        (local.set $t (local.get $y))")) (ELit (LString "        (block $up (loop $ul")) (ELit (LString "          (br_if $up (f64.gt (f64.add (local.get $t) (local.get $t)) (local.get $x)))")) (ELit (LString "          (local.set $t (f64.add (local.get $t) (local.get $t)))")) (ELit (LString "          (br $ul)))")) (ELit (LString "        (block $dn (loop $dl")) (ELit (LString "          (if (f64.ge (local.get $x) (local.get $t))")) (ELit (LString "            (then (local.set $x (f64.sub (local.get $x) (local.get $t)))))")) (ELit (LString "          (br_if $dn (f64.eq (local.get $t) (local.get $y)))")) (ELit (LString "          (local.set $t (f64.mul (local.get $t) (f64.const 0.5)))")) (ELit (LString "          (br $dl)))")) (ELit (LString "        (f64.copysign (local.get $x) (local.get $a)))))"))))
(DTypeSig true "floatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatRuntimeLines" () (EListLit (ELit (LString "  ;; -- W8b Float runtime (byte-identical to medaka_rt.c) --")) (ELit (LString "  ;; intToFloat : i64 (full-width unboxed Int) -> boxed (struct $float).  #199: reads")) (ELit (LString "  ;; the arg through the $mdk_unbox_int seam so Ints outside +-2^30 no longer trap the")) (ELit (LString "  ;; i31 cast (e.g. intToFloat 4503599627370497).")) (ELit (LString "  (func $mdk_int_to_float (param $n i64) (result (ref $float))")) (ELit (LString "    (struct.new $float (f64.convert_i64_s (local.get $n))))")) (ELit (LString "  ;; floatToInt : boxed $float -> i64 (truncate toward zero).  #199: the i64 result")) (ELit (LString "  ;; reboxes via $mdk_box_int so a large truncation (|x| > 2^30, up to 2^53) no longer")) (ELit (LString "  ;; overflows i32 (`float unrepresentable in integer range`) nor traps ref.i31.")) (ELit (LString "  ;; #346/#372 (S0): SATURATES — NaN -> 0, +inf/over -> intMaxBound, -inf/under ->")) (ELit (LString "  ;; intMinBound.  The old bare i64.trunc_f64_s TRAPPED on NaN/inf/out-of-range (an")) (ELit (LString "  ;; uncoded engine trap: `float unrepresentable in integer range`, exit 1, no E-code),")) (ELit (LString "  ;; where native's fptosi was silent poison — so the three engines disagreed on exactly")) (ELit (LString "  ;; the inputs N7 says must be pinned.  trunc_sat alone is NOT enough: it saturates to")) (ELit (LString "  ;; *i64* bounds (+-2^63), which are OUTSIDE Medaka's 63-bit Int domain, and $mdk_box_int")) (ELit (LString "  ;; would renormalize that to -1/0 rather than the bound.  So clamp to the Int bounds")) (ELit (LString "  ;; ([-2^62, 2^62-1]) BEFORE returning to the box seam.  Matches llvm_emit's arm.")) (ELit (LString "  (func $mdk_float_to_int (param $f (ref $float)) (result i64)")) (ELit (LString "    (local $r i64)")) (ELit (LString "    (local.set $r (i64.trunc_sat_f64_s (struct.get $float 0 (local.get $f))))")) (ELit (LString "    (if (result i64) (i64.gt_s (local.get $r) (i64.const 4611686018427387903))")) (ELit (LString "      (then (i64.const 4611686018427387903))")) (ELit (LString "      (else (if (result i64) (i64.lt_s (local.get $r) (i64.const -4611686018427387904))")) (ELit (LString "        (then (i64.const -4611686018427387904))")) (ELit (LString "        (else (local.get $r))))))")) (ELit (LString "  ;; #101 round : C round() — round to nearest, HALVES AWAY FROM ZERO (NOT f64.nearest,")) (ELit (LString "  ;; which is round-half-to-even).  Branch-based so there is NO intermediate `x+0.5`:")) (ELit (LString "  ;; the naive `floor(abs(x)+0.5)` double-rounds — `x+0.5` itself rounds (IEEE) before")) (ELit (LString "  ;; the floor, so round(0.49999999999999994)->1 (should be 0) and every odd-integer")) (ELit (LString "  ;; double in [2^52,2^53) (an exact `x+0.5` tie -> half-to-even picks x+1) came back")) (ELit (LString "  ;; off-by-one.  Here we floor/ceil FIRST, then compare the exact fractional distance")) (ELit (LString "  ;; to 0.5.  Byte-identical to native mdk_round (== C round(), medaka_rt.c) for all")) (ELit (LString "  ;; finite inputs (an already-integral x has fraction 0 < 0.5 -> returned unchanged).")) (ELit (LString "  (func $mdk_round (param $x f64) (result f64)")) (ELit (LString "    (local $t f64)")) (ELit (LString "    (if (result f64) (f64.ge (local.get $x) (f64.const 0.0))")) (ELit (LString "      (then (local.set $t (f64.floor (local.get $x)))")) (ELit (LString "        (if (result f64) (f64.ge (f64.sub (local.get $x) (local.get $t)) (f64.const 0.5))")) (ELit (LString "          (then (f64.add (local.get $t) (f64.const 1.0))) (else (local.get $t))))")) (ELit (LString "      (else (local.set $t (f64.ceil (local.get $x)))")) (ELit (LString "        (if (result f64) (f64.ge (f64.sub (local.get $t) (local.get $x)) (f64.const 0.5))")) (ELit (LString "          (then (f64.sub (local.get $t) (f64.const 1.0))) (else (local.get $t))))))")) (ELit (LString "  ;; floatToString : the host formats (shortest-round-trip since #57, + .0 rule)")) (ELit (LString "  ;; into a cache; copy the bytes into a fresh $str.  cp_count == byte_len (ASCII).")) (ELit (LString "  (func $mdk_float_to_str (param $d f64) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (call $mdk_float_fmt (local.get $d)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (call $mdk_float_fmt_byte (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (local.get $n) (local.get $buf)))"))))
(DTypeSig true "hashFloatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hashFloatRuntimeLines" () (EListLit (ELit (LString "  ;; hashFloat (#758): normalise -0.0 -> +0.0 and every NaN -> one qNaN bit")) (ELit (LString "  ;; pattern, then reinterpret bits as i64 -> mix64 -> mask [0,2^30).  Matches")) (ELit (LString "  ;; mdk_hash_float (native) and pHashFloat (eval), or run /= build reappears.")) (ELit (LString "  (func $mdk_hash_float (param $f (ref $float)) (result i32)")) (ELit (LString "    (local $d f64) (local $bits i64)")) (ELit (LString "    (local.set $d (struct.get $float 0 (local.get $f)))")) (ELit (LString "    (if (f64.eq (local.get $d) (f64.const 0))")) (ELit (LString "      (then (local.set $bits (i64.const 0)))")) (ELit (LString "      (else")) (ELit (LString "        (if (f64.ne (local.get $d) (local.get $d))")) (ELit (LString "          (then (local.set $bits (i64.const 0x7FF8000000000000)))")) (ELit (LString "          (else (local.set $bits (i64.reinterpret_f64 (local.get $d)))))))")) (ELit (LString "    (i32.wrap_i64 (i64.and (call $mdk_hash_mix64 (local.get $bits)) (i64.const 0x3FFFFFFF))))"))))
(DTypeSig true "randomFloatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "randomFloatRuntimeLines" () (EListLit (ELit (LString "  ;; randomFloat : SplitMix64 -> f64 in [-1,1) (NOTE the -1 offset — see medaka_rt.c).")) (ELit (LString "  (func $mdk_random_float (result (ref $float))")) (ELit (LString "    (struct.new $float")) (ELit (LString "      (f64.sub")) (ELit (LString "        (f64.mul")) (ELit (LString "          (f64.mul (f64.convert_i64_u (i64.shr_u (call $mdk_next_u64) (i64.const 11)))")) (ELit (LString "                   (f64.const 1.1102230246251565e-16))")) (ELit (LString "          (f64.const 2.0))")) (ELit (LString "        (f64.const 1.0))))"))))
(DTypeSig false "notUtf8SuffixWat" (TyCon "String"))
(DFunDef false "notUtf8SuffixWat" () (EApp (EVar "asciiU8arrWat") (ELit (LString ": not valid UTF-8 (use readFileBytes for raw bytes)"))))
(DTypeSig false "asciiU8arrWat" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "asciiU8arrWat" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(array.new_fixed $u8arr ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "arrayLength") (EVar "cs"))))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "asciiConstsW") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))) (ELit (LString ")"))))))
(DTypeSig false "asciiConstsW" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "asciiConstsW" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (i32.const ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")))))) (ELit (LString ")"))) (EApp (EApp (EApp (EVar "asciiConstsW") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig true "ioHostRuntimeLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ioHostRuntimeLines" ((PVar "keys")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_path_push"))) (EVar "keys")) (EVar "ioPushPathLines")) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_rename"))) (EVar "keys")) (EVar "ioPushPathMoreLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_grant_push"))) (EVar "keys")) (EVar "ioPushGrantLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_rename"))) (EVar "keys")) (EVar "ioPushGrantMoreLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_result_len"))) (EVar "keys")) (EVar "ioResultLines"))) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (ELit (LString "mdk_file_exists"))) (EVar "keys")) (EApp (EApp (EVar "contains") (ELit (LString "mdk_canonicalize_path"))) (EVar "keys"))) (EApp (EApp (EVar "contains") (ELit (LString "mdk_os_entropy"))) (EVar "keys"))) (EVar "ioRefusedPanicLines") (EListLit))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_read_file"))) (EVar "keys")) (EVar "ioReadFileLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_fetch_text"))) (EVar "keys")) (EVar "ioFetchTextLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_file_exists"))) (EVar "keys")) (EVar "ioFileExistsLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_canonicalize_path"))) (EVar "keys")) (EVar "ioCanonicalizeLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_write_file"))) (EVar "keys")) (EVar "ioWriteFileLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_append_file"))) (EVar "keys")) (EVar "ioAppendFileLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_rename"))) (EVar "keys")) (EVar "ioRenameLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_list_dir"))) (EVar "keys")) (EVar "ioListDirLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_stat_file"))) (EVar "keys")) (EVar "ioStatFileLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_make_dir"))) (EVar "keys")) (EVar "ioMakeDirLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_remove_file"))) (EVar "keys")) (EVar "ioRemoveFileLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_remove_dir"))) (EVar "keys")) (EVar "ioRemoveDirLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_fsync"))) (EVar "keys")) (EVar "ioFsyncLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_file_mode"))) (EVar "keys")) (EVar "ioFileModeLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_write_file_mode"))) (EVar "keys")) (EVar "ioWriteFileModeLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_get_env"))) (EVar "keys")) (EVar "ioGetEnvLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_read_line"))) (EVar "keys")) (EVar "ioReadLineLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_read_all"))) (EVar "keys")) (EVar "ioReadAllLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_read_exactly"))) (EVar "keys")) (EVar "ioReadExactlyLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_executable_path"))) (EVar "keys")) (EVar "ioExecutablePathLines"))))
(DTypeSig false "gatedOn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "gatedOn" ((PVar "key") (PVar "keys") (PVar "block")) (EIf (EApp (EApp (EVar "contains") (EVar "key")) (EVar "keys")) (EVar "block") (EListLit)))
(DTypeSig false "ioPushPathLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioPushPathLines" () (EListLit (ELit (LString "  ;; push a $str's bytes to the host path buffer (reset first).")) (ELit (LString "  (func $mdk_push_path (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (call $mdk_path_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    )"))))
(DTypeSig false "ioPushPathMoreLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioPushPathMoreLines" () (EListLit (ELit (LString "  ;; append a $str's bytes to the host path buffer (rename's second path).")) (ELit (LString "  (func $mdk_push_path_more (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    )"))))
(DTypeSig false "ioPushGrantLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioPushGrantLines" () (EListLit (ELit (LString "  ;; push a grant (List String) to the host grant buffer (reset first).")) (ELit (LString "  (func $mdk_push_grant (param $g (ref eq))")) (ELit (LString "    (local $cell (ref $C_Cons)) (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (call $mdk_grant_reset)")) (ELit (LString "    (block $done (loop $next")) (ELit (LString "      (br_if $done (i32.eqz (ref.test (ref $C_Cons) (local.get $g))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $g)))")) (ELit (LString "      (local.set $b (struct.get $str $bytes (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell)))))")) (ELit (LString "      (local.set $n (array.len (local.get $b)))")) (ELit (LString "      (local.set $i (i32.const 0))")) (ELit (LString "      (block $d (loop $l")) (ELit (LString "        (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "        (call $mdk_grant_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "        (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "      (call $mdk_grant_push (i32.const -1))")) (ELit (LString "      (local.set $g (struct.get $C_Cons 2 (local.get $cell))) (br $next)))")) (ELit (LString "    )"))))
(DTypeSig false "ioPushGrantMoreLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioPushGrantMoreLines" () (EListLit (ELit (LString "  ;; append a grant to the host grant buffer (rename's second grant).")) (ELit (LString "  (func $mdk_push_grant_more (param $g (ref eq))")) (ELit (LString "    (local $cell (ref $C_Cons)) (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (block $done (loop $next")) (ELit (LString "      (br_if $done (i32.eqz (ref.test (ref $C_Cons) (local.get $g))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $g)))")) (ELit (LString "      (local.set $b (struct.get $str $bytes (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell)))))")) (ELit (LString "      (local.set $n (array.len (local.get $b)))")) (ELit (LString "      (local.set $i (i32.const 0))")) (ELit (LString "      (block $d (loop $l")) (ELit (LString "        (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "        (call $mdk_grant_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "        (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "      (call $mdk_grant_push (i32.const -1))")) (ELit (LString "      (local.set $g (struct.get $C_Cons 2 (local.get $cell))) (br $next)))")) (ELit (LString "    )"))))
(DTypeSig false "ioRefusedPanicLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioRefusedPanicLines" () (EListLit (ELit (LString "  ;; the host's refusal message (result channel) as an E-PANIC line, then trap.")) (ELit (LString "  (func $mdk_refused_panic")) (EBinOp "++" (EBinOp "++" (ELit (LString "    (call $mdk_err_u8arr ")) (EApp (EVar "display") (EVar "panicBannerWat"))) (ELit (LString ")"))) (ELit (LString "    (call $mdk_err_u8arr (call $mdk_io_result_bytes))")) (ELit (LString "    (call $mdk_write_err_byte (i32.const 10))")) (ELit (LString "    (unreachable))")) (ELit (LString "  (func $mdk_err_u8arr (param $b (ref $u8arr))")) (ELit (LString "    (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_err_byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    )"))))
(DTypeSig false "panicBannerWat" (TyCon "String"))
(DFunDef false "panicBannerWat" () (EApp (EVar "asciiU8arrWat") (ELit (LString "runtime error [E-PANIC]: "))))
(DTypeSig false "ioResultLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioResultLines" () (EListLit (ELit (LString "  ;; copy the host result buffer (length + byte-at-index) into a fresh $u8arr.")) (ELit (LString "  (func $mdk_io_result_bytes (result (ref $u8arr))")) (ELit (LString "    (local $n i32) (local $i i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (call $mdk_result_len))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (call $mdk_result_byte (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $buf))")) (ELit (LString "  ;; the host result buffer as a $str, read as UTF-8 by $mdk_u8_to_str_lossy.")) (ELit (LString "  (func $mdk_io_result_to_str (result (ref $str))")) (ELit (LString "    (call $mdk_u8_to_str_lossy (call $mdk_io_result_bytes)))"))))
(DTypeSig true "jsffiImportLines" (TyFun (TyApp (TyCon "List") (TyCon "JsImport")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "jsffiImportLines" ((PVar "imps")) (EApp (EApp (EVar "map") (EVar "jsffiImportLine")) (EVar "imps")))
(DTypeSig false "jsffiImportLine" (TyFun (TyCon "JsImport") (TyCon "String")))
(DFunDef false "jsffiImportLine" ((PVar "imp")) (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (EVar "jsWireParam")) (EFieldAccess (EVar "imp") "params")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  (import \"jsffi\" \"")) (EApp (EVar "display") (EApp (EVar "jsImportField") (EVar "imp")))) (ELit (LString "\" (func $"))) (EApp (EVar "display") (EApp (EVar "jsffiImportId") (EFieldAccess (EVar "imp") "medakaName")))) (ELit (LString ""))) (EApp (EVar "display") (EVar "params"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "jsWireResult") (EFieldAccess (EVar "imp") "result")))) (ELit (LString "))"))))))
(DTypeSig true "jsffiImportId" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "jsffiImportId" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "jsffi.import.")) (EApp (EVar "display") (EApp (EVar "injectiveIdent") (EVar "name")))) (ELit (LString ""))))
(DTypeSig true "jsffiWrapperId" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "jsffiWrapperId" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "jsffi.wrap.")) (EApp (EVar "display") (EApp (EVar "injectiveIdent") (EVar "name")))) (ELit (LString ""))))
(DTypeSig true "jsImportField" (TyFun (TyCon "JsImport") (TyCon "String")))
(DFunDef false "jsImportField" ((PVar "imp")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "imp") "jsName"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EFieldAccess (EVar "imp") "params")))) (ELit (LString "->"))) (EApp (EVar "display") (EFieldAccess (EVar "imp") "result"))) (ELit (LString ""))))
(DTypeSig false "jsWireTy" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "jsWireTy" ((PLit (LString "Int"))) (ELit (LString "i64")))
(DFunDef false "jsWireTy" ((PLit (LString "U64"))) (ELit (LString "i64")))
(DFunDef false "jsWireTy" ((PLit (LString "I64"))) (ELit (LString "i64")))
(DFunDef false "jsWireTy" ((PLit (LString "Float"))) (ELit (LString "f64")))
(DFunDef false "jsWireTy" (PWild) (ELit (LString "i32")))
(DTypeSig false "isChannelHead" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isChannelHead" ((PVar "head")) (EBinOp "||" (EBinOp "==" (EVar "head") (ELit (LString "String"))) (EBinOp "==" (EVar "head") (ELit (LString "Array")))))
(DTypeSig true "jsCrossableHead" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "jsCrossableHead" ((PVar "head")) (EApp (EApp (EVar "contains") (EVar "head")) (EListLit (ELit (LString "Int")) (ELit (LString "Float")) (ELit (LString "Bool")) (ELit (LString "Char")) (ELit (LString "String")) (ELit (LString "Array")) (ELit (LString "Unit")) (ELit (LString "U8")) (ELit (LString "U16")) (ELit (LString "U32")) (ELit (LString "I32")) (ELit (LString "U64")) (ELit (LString "I64")))))
(DTypeSig true "jsffiWrapperLines" (TyFun (TyCon "JsImport") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "jsffiWrapperLines" ((PVar "imp") (PVar "intTrap") (PVar "charTrap") (PVar "copyTrap")) (EBlock (DoLet false false (PVar "ps") (EApp (EApp (EVar "zipHeads") (EFieldAccess (EVar "imp") "params")) (ELit (LInt 0)))) (DoLet false false (PVar "params") (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EBinOp "++" (EBinOp "++" (ELit (LString " (param $p")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "p"))))) (ELit (LString " (ref eq))"))))) (EVar "ps")))) (DoLet false false (PVar "held") (EBinOp "/=" (EApp (EVar "jsWireResult") (EFieldAccess (EVar "imp") "result")) (ELit (LString "")))) (DoLet false false (PVar "rLocal") (EIf (EVar "held") (EBinOp "++" (EBinOp "++" (ELit (LString " (local $r ")) (EApp (EVar "display") (EApp (EVar "jsWireTy") (EFieldAccess (EVar "imp") "result")))) (ELit (LString ")"))) (ELit (LString "")))) (DoLet false false (PVar "push") (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EApp (EVar "isChannelHead") (EApp (EVar "fst") (EVar "p"))))) (EVar "ps")) (EBinOp "::" (ELit (LString "    (call $mdk_path_reset)")) (EApp (EApp (EVar "flatMap") (EVar "jsPushArg")) (EVar "ps"))) (EListLit))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  (func $")) (EApp (EVar "display") (EApp (EVar "jsffiWrapperId") (EFieldAccess (EVar "imp") "medakaName")))) (ELit (LString ""))) (EApp (EVar "display") (EVar "params"))) (ELit (LString " (result (ref eq))"))) (EBinOp "++" (EBinOp "++" (ELit (LString "    (local $off i32)")) (EApp (EVar "display") (EVar "rLocal"))) (ELit (LString "")))) (EVar "push")) (EApp (EApp (EVar "flatMap") (EVar "jsWireArg")) (EVar "ps"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    call $")) (EApp (EVar "display") (EApp (EVar "jsffiImportId") (EFieldAccess (EVar "imp") "medakaName")))) (ELit (LString ""))))) (EIf (EVar "held") (EListLit (ELit (LString "    local.set $r"))) (EListLit))) (EApp (EApp (EVar "flatMap") (EApp (EVar "jsCopyBack") (EVar "copyTrap"))) (EVar "ps"))) (EApp (EApp (EApp (EVar "jsUnwire") (EFieldAccess (EVar "imp") "result")) (EVar "intTrap")) (EVar "charTrap"))) (EListLit (ELit (LString "  )")))))))
(DTypeSig false "zipHeads" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "zipHeads" ((PList) PWild) (EListLit))
(DFunDef false "zipHeads" ((PCons (PVar "h") (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (EVar "h") (EVar "i")) (EApp (EApp (EVar "zipHeads") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "jsPushArg" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "jsPushArg" ((PTuple (PLit (LString "String")) (PVar "i"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (call $mdk_push_path_more (ref.cast (ref $str) (local.get $p")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")))")))))
(DFunDef false "jsPushArg" ((PTuple (PLit (LString "Array")) (PVar "i"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (call $mdk_jsffi_push_ints (ref.cast (ref $arr) (local.get $p")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")))")))))
(DFunDef false "jsPushArg" (PWild) (EListLit))
(DTypeSig false "jsWireArg" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "jsWireArg" ((PTuple (PVar "head") (PVar "i"))) (EBlock (DoLet false false (PVar "p") (EBinOp "++" (EBinOp "++" (ELit (LString "(local.get $p")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")")))) (DoExpr (EMatch (EVar "head") (arm (PLit (LString "Unit")) () (EListLit)) (arm (PLit (LString "Int")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (call $mdk_unbox_int ")) (EApp (EVar "display") (EVar "p"))) (ELit (LString ")"))))) (arm (PLit (LString "Float")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (struct.get $float 0 (ref.cast (ref $float) ")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "))"))))) (arm (PLit (LString "Bool")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (i31.get_u (ref.cast (ref i31) ")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "))"))))) (arm (PLit (LString "Char")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (i31.get_u (ref.cast (ref i31) ")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "))"))))) (arm (PLit (LString "U64")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (struct.get $u64 0 (ref.cast (ref $u64) ")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "))"))))) (arm (PLit (LString "I64")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (struct.get $i64 0 (ref.cast (ref $i64) ")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "))"))))) (arm (PLit (LString "String")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (array.len (struct.get $str $bytes (ref.cast (ref $str) ")) (EApp (EVar "display") (EVar "p"))) (ELit (LString ")))"))))) (arm (PLit (LString "Array")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (array.len (ref.cast (ref $arr) ")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "))"))))) (arm PWild () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (i32.wrap_i64 (call $mdk_unbox_int ")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "))")))))))))
(DTypeSig false "jsCopyBack" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "jsCopyBack" ((PVar "trap") (PTuple (PLit (LString "Array")) (PVar "i"))) (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (local.set $off (call $mdk_jsffi_copy_back (ref.cast (ref $arr) (local.get $p")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")) (local.get $off)))"))) (ELit (LString "    (if (i32.lt_s (local.get $off) (i32.const 0)) (then"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString "      ")) (EVar "_s")))) (EVar "trap"))) (EListLit (ELit (LString "    ))")))))
(DFunDef false "jsCopyBack" (PWild PWild) (EListLit))
(DTypeSig false "jsUnwire" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "jsUnwire" ((PLit (LString "Int")) (PVar "intTrap") PWild) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "    (if (i64.ne (i64.shr_s (i64.shl (local.get $r) (i64.const 1)) (i64.const 1)) (local.get $r)) (then"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString "      ")) (EVar "_s")))) (EVar "intTrap"))) (EListLit (ELit (LString "    ))")) (ELit (LString "    (call $mdk_box_int (local.get $r))")))))
(DFunDef false "jsUnwire" ((PLit (LString "Char")) PWild (PVar "charTrap")) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "    (if (i32.eqz (i32.and (i32.lt_u (local.get $r) (i32.const 1114112))")) (ELit (LString "        (i32.or (i32.lt_u (local.get $r) (i32.const 55296)) (i32.gt_u (local.get $r) (i32.const 57343))))) (then"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString "      ")) (EVar "_s")))) (EVar "charTrap"))) (EListLit (ELit (LString "    ))")) (ELit (LString "    (ref.i31 (local.get $r))")))))
(DFunDef false "jsUnwire" ((PLit (LString "Float")) PWild PWild) (EListLit (ELit (LString "    (struct.new $float (local.get $r))"))))
(DFunDef false "jsUnwire" ((PLit (LString "Bool")) PWild PWild) (EListLit (ELit (LString "    (ref.i31 (i32.ne (local.get $r) (i32.const 0)))"))))
(DFunDef false "jsUnwire" ((PLit (LString "U8")) PWild PWild) (EListLit (ELit (LString "    (call $mdk_box_int (i64.extend_i32_u (i32.and (local.get $r) (i32.const 255))))"))))
(DFunDef false "jsUnwire" ((PLit (LString "U16")) PWild PWild) (EListLit (ELit (LString "    (call $mdk_box_int (i64.extend_i32_u (i32.and (local.get $r) (i32.const 65535))))"))))
(DFunDef false "jsUnwire" ((PLit (LString "U32")) PWild PWild) (EListLit (ELit (LString "    (call $mdk_box_int (i64.extend_i32_u (local.get $r)))"))))
(DFunDef false "jsUnwire" ((PLit (LString "I32")) PWild PWild) (EListLit (ELit (LString "    (call $mdk_box_int (i64.extend_i32_s (local.get $r)))"))))
(DFunDef false "jsUnwire" ((PLit (LString "U64")) PWild PWild) (EListLit (ELit (LString "    (struct.new $u64 (local.get $r))"))))
(DFunDef false "jsUnwire" ((PLit (LString "I64")) PWild PWild) (EListLit (ELit (LString "    (struct.new $i64 (local.get $r))"))))
(DFunDef false "jsUnwire" ((PLit (LString "String")) PWild PWild) (EListLit (ELit (LString "    (call $mdk_jsffi_result_str (local.get $off))"))))
(DFunDef false "jsUnwire" (PWild PWild PWild) (EListLit (ELit (LString "    (ref.i31 (i32.const 0))"))))
(DTypeSig true "jsffiRuntimeLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "JsImport")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "jsffiRuntimeLines" ((PVar "keys") (PVar "imps")) (EBlock (DoLet false false (PVar "heads") (EApp (EApp (EVar "flatMap") (ELam ((PVar "imp")) (EFieldAccess (EVar "imp") "params"))) (EVar "imps"))) (DoLet false false (PVar "pushMore") (EIf (EBinOp "&&" (EApp (EApp (EVar "anyList") (EVar "isChannelHead")) (EVar "heads")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (ELit (LString "mdk_rename"))) (EVar "keys")))) (EVar "ioPushPathMoreLines") (EListLit))) (DoLet false false (PVar "arrays") (EIf (EApp (EApp (EVar "contains") (ELit (LString "Array"))) (EVar "heads")) (EVar "jsffiArrayLines") (EListLit))) (DoLet false false (PVar "strs") (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "imp")) (EBinOp "==" (EFieldAccess (EVar "imp") "result") (ELit (LString "String"))))) (EVar "imps")) (EVar "jsffiResultStrLines") (EListLit))) (DoExpr (EBinOp "++" (EBinOp "++" (EVar "pushMore") (EVar "arrays")) (EVar "strs")))))
(DTypeSig false "jsffiArrayLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "jsffiArrayLines" () (EListLit (ELit (LString "  ;; push an Array Int's elements to the host path buffer, 8 LE bytes each.")) (ELit (LString "  (func $mdk_jsffi_push_ints (param $a (ref $arr))")) (ELit (LString "    (local $i i32) (local $n i32) (local $w i64) (local $k i32)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $w (call $mdk_unbox_int (array.get $arr (local.get $a) (local.get $i))))")) (ELit (LString "      (local.set $k (i32.const 0))")) (ELit (LString "      (block $bd (loop $bl")) (ELit (LString "        (br_if $bd (i32.ge_s (local.get $k) (i32.const 8)))")) (ELit (LString "        (call $mdk_path_push (i32.wrap_i64 (i64.and (local.get $w) (i64.const 255))))")) (ELit (LString "        (local.set $w (i64.shr_u (local.get $w) (i64.const 8)))")) (ELit (LString "        (local.set $k (i32.add (local.get $k) (i32.const 1))) (br $bl)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    )")) (ELit (LString "  ;; the 8 LE bytes at $at of the host result buffer, as an i64.")) (ELit (LString "  (func $mdk_jsffi_result_i64 (param $at i32) (result i64)")) (ELit (LString "    (local $k i32) (local $w i64)")) (ELit (LString "    (local.set $k (i32.const 8))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.eqz (local.get $k)))")) (ELit (LString "      (local.set $k (i32.sub (local.get $k) (i32.const 1)))")) (ELit (LString "      (local.set $w (i64.or (i64.shl (local.get $w) (i64.const 8))")) (ELit (LString "        (i64.extend_i32_u (i32.and (call $mdk_result_byte (i32.add (local.get $at) (local.get $k))) (i32.const 255)))))")) (ELit (LString "      (br $l)))")) (ELit (LString "    (local.get $w))")) (ELit (LString "  ;; copy an Array Int argument back from the result buffer at $off: the next")) (ELit (LString "  ;; offset, or -1 with nothing written when a word is outside Int's 63 bits.")) (ELit (LString "  (func $mdk_jsffi_copy_back (param $a (ref $arr)) (param $off i32) (result i32)")) (ELit (LString "    (local $i i32) (local $n i32) (local $w i64)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $w (call $mdk_jsffi_result_i64 (i32.add (local.get $off) (i32.shl (local.get $i) (i32.const 3)))))")) (ELit (LString "      (if (i64.ne (i64.shr_s (i64.shl (local.get $w) (i64.const 1)) (i64.const 1)) (local.get $w))")) (ELit (LString "        (then (return (i32.const -1))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $arr (local.get $a) (local.get $i)")) (ELit (LString "        (call $mdk_box_int (call $mdk_jsffi_result_i64 (i32.add (local.get $off) (i32.shl (local.get $i) (i32.const 3))))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))")) (ELit (LString "    (i32.add (local.get $off) (i32.shl (local.get $n) (i32.const 3))))"))))
(DTypeSig false "jsffiResultStrLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "jsffiResultStrLines" () (EListLit (ELit (LString "  ;; the host result buffer from $off to its end, as a $str.")) (ELit (LString "  (func $mdk_jsffi_result_str (param $off i32) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (i32.sub (call $mdk_result_len) (local.get $off)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i)")) (ELit (LString "        (call $mdk_result_byte (i32.add (local.get $off) (local.get $i))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (call $mdk_u8_to_str_lossy (local.get $buf)))"))))
(DTypeSig false "ioReadFileLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioReadFileLines" () (EListLit (ELit (LString "  ;; readFile's Err for contents that are not UTF-8: the path, then a fixed ASCII")) (ELit (LString "  ;; suffix, byte-identical to medaka_rt.c mdk_read_file.")) (ELit (LString "  (func $mdk_str_not_utf8 (param $path (ref $str)) (result (ref $str))")) (ELit (LString "    (local $pb (ref $u8arr)) (local $pl i32) (local $sfx (ref $u8arr)) (local $out (ref $u8arr))")) (ELit (LString "    (local.set $pb (struct.get $str $bytes (local.get $path)))")) (ELit (LString "    (local.set $pl (array.len (local.get $pb)))")) (EBinOp "++" (EBinOp "++" (ELit (LString "    (local.set $sfx ")) (EApp (EVar "display") (EVar "notUtf8SuffixWat"))) (ELit (LString ")"))) (ELit (LString "    (local.set $out (array.new $u8arr (i32.const 0) (i32.add (local.get $pl) (array.len (local.get $sfx)))))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $out) (i32.const 0) (local.get $pb) (i32.const 0) (local.get $pl))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $out) (local.get $pl) (local.get $sfx) (i32.const 0) (array.len (local.get $sfx)))")) (ELit (LString "    (struct.new $str (i32.add (struct.get $str $cp_count (local.get $path)) (array.len (local.get $sfx))) (local.get $out)))")) (ELit (LString "  ;; readFile : $str path -> Result String String.  1=Ok contents / 0=Err message.")) (ELit (LString "  ;; Contents that are not UTF-8 are an Err naming the path (medaka_rt.c mdk_read_file).")) (ELit (LString "  (func $mdk_read_file_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $st i32) (local $buf (ref $u8arr)) (local $c i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (local.set $st (call $mdk_read_file))")) (ELit (LString "    (if (i32.eqz (local.get $st))")) (ELit (LString "      (then (return (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))")) (ELit (LString "    (local.set $buf (call $mdk_io_result_bytes))")) (ELit (LString "    (local.set $c (call $mdk_utf8_valid_count (local.get $buf)))")) (ELit (LString "    (if (result (ref eq)) (i32.ge_s (local.get $c) (i32.const 0))")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (struct.new $str (local.get $c) (local.get $buf))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_str_not_utf8 (local.get $path))))))"))))
(DTypeSig false "ioFetchTextLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioFetchTextLines" () (EListLit (ELit (LString "  ;; fetchText : $str url -> Result String String.  1=Ok body / 0=Err message.")) (ELit (LString "  ;; The host import answers with a promise, so under JSPI the guest suspends in the call.")) (ELit (LString "  (func $mdk_fetch_text_io (param $url (ref $str)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_path (local.get $url))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_fetch_text)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (call $mdk_io_result_to_str)))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioFileExistsLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioFileExistsLines" () (EListLit (ELit (LString "  ;; fileExists : $str path -> Bool (i31 ordinal: False=0 / True=1); 2 = refused.")) (ELit (LString "  (func $mdk_file_exists_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $r i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (local.set $r (call $mdk_file_exists))")) (ELit (LString "    (if (i32.eq (local.get $r) (i32.const 2)) (then (call $mdk_refused_panic)))")) (ELit (LString "    (ref.i31 (local.get $r)))"))))
(DTypeSig false "ioCanonicalizeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioCanonicalizeLines" () (EListLit (ELit (LString "  ;; canonicalizePath : $str path -> $str.  1=the host's answer / 0=refused.")) (ELit (LString "  (func $mdk_canonicalize_path_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (i32.eqz (call $mdk_canonicalize_path)) (then (call $mdk_refused_panic)))")) (ELit (LString "    (call $mdk_io_result_to_str))"))))
(DTypeSig false "ioWriteFileLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioWriteFileLines" () (EListLit (ELit (LString "  ;; writeFile : $str path -> $str contents -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  ;; The contents' bytes stream to the host's write buffer, as writeFileBytes streams its array.")) (ELit (LString "  (func $mdk_write_file_io (param $path (ref $str)) (param $s (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (call $mdk_write_file_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_file_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_write_file)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioWriteFileModeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioWriteFileModeLines" () (EListLit (ELit (LString "  ;; writeFileMode : $str path -> Int mode -> $str contents -> Result String Unit.")) (ELit (LString "  ;; 1=Ok () / 0=Err msg.  The contents stream to the host's write buffer; the host sets")) (ELit (LString "  ;; the file's mode before the first byte is written.")) (ELit (LString "  (func $mdk_write_file_mode_io (param $path (ref $str)) (param $mode (ref eq)) (param $s (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (call $mdk_write_file_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_file_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_write_file_mode (i32.wrap_i64 (call $mdk_unbox_int (local.get $mode))))")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioAppendFileLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioAppendFileLines" () (EListLit (ELit (LString "  ;; appendFile : $str path -> $str contents -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  ;; The contents' bytes stream to the host's write buffer; the host appends them.")) (ELit (LString "  (func $mdk_append_file_io (param $path (ref $str)) (param $s (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (call $mdk_write_file_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_file_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_append_file)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioRenameLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioRenameLines" () (EListLit (ELit (LString "  ;; rename : $str src -> $str dst -> src grant -> dst grant -> Result String Unit.")) (ELit (LString "  ;; The grants share the grant channel (-2 ends the first), the paths the path channel;")) (ELit (LString "  ;; the host splits the path buffer at the source's byte length.")) (ELit (LString "  (func $mdk_rename_io (param $src (ref $str)) (param $dst (ref $str)) (param $gs (ref eq)) (param $gd (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $gs))")) (ELit (LString "    (call $mdk_grant_push (i32.const -2))")) (ELit (LString "    (call $mdk_push_grant_more (local.get $gd))")) (ELit (LString "    (call $mdk_push_path (local.get $src))")) (ELit (LString "    (call $mdk_push_path_more (local.get $dst))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_rename (array.len (struct.get $str $bytes (local.get $src))))")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioListDirLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioListDirLines" () (EListLit (ELit (LString "  ;; listDir : $str path -> Result String (List String).  The host answers each entry's")) (ELit (LString "  ;; name followed by a NUL byte; the list is built from the last entry back.")) (ELit (LString "  (func $mdk_list_dir_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $buf (ref $u8arr)) (local $name (ref $u8arr)) (local $acc (ref eq))")) (ELit (LString "    (local $pos i32) (local $end i32) (local $k i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (i32.eqz (call $mdk_list_dir))")) (ELit (LString "      (then (return (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))")) (ELit (LString "    (local.set $buf (call $mdk_io_result_bytes))")) (ELit (LString "    (local.set $acc (ref.i31 (i32.const 1)))")) (ELit (LString "    (local.set $pos (array.len (local.get $buf)))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.le_s (local.get $pos) (i32.const 0)))")) (ELit (LString "      (local.set $end (i32.sub (local.get $pos) (i32.const 1)))")) (ELit (LString "      (local.set $k (local.get $end))")) (ELit (LString "      (block $s (loop $m")) (ELit (LString "        (br_if $s (i32.eqz (local.get $k)))")) (ELit (LString "        (br_if $s (i32.eqz (array.get_u $u8arr (local.get $buf) (i32.sub (local.get $k) (i32.const 1)))))")) (ELit (LString "        (local.set $k (i32.sub (local.get $k) (i32.const 1))) (br $m)))")) (ELit (LString "      (local.set $name (array.new $u8arr (i32.const 0) (i32.sub (local.get $end) (local.get $k))))")) (ELit (LString "      (array.copy $u8arr $u8arr (local.get $name) (i32.const 0) (local.get $buf) (local.get $k) (i32.sub (local.get $end) (local.get $k)))")) (ELit (LString "      (local.set $acc (struct.new $C_Cons (i32.const 0) (call $mdk_u8_to_str_lossy (local.get $name)) (local.get $acc)))")) (ELit (LString "      (local.set $pos (local.get $k)) (br $l)))")) (ELit (LString "    (struct.new $C_Ok (i32.const 0) (local.get $acc)))"))))
(DTypeSig false "ioStatFileLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioStatFileLines" () (EListLit (ELit (LString "  ;; statFile : $str path -> Result String (Int, Bool, Bool, Float): size, isDir, isFile,")) (ELit (LString "  ;; mtime in seconds.  The host answers each field of the stat it took as an f64.")) (ELit (LString "  (func $mdk_stat_file_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_stat_file)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0)")) (ELit (LString "        (struct.new $C_Tup4 (i32.const 0)")) (ELit (LString "          (call $mdk_box_int (i64.trunc_f64_s (call $mdk_stat_field (i32.const 0))))")) (ELit (LString "          (ref.i31 (i32.trunc_f64_s (call $mdk_stat_field (i32.const 1))))")) (ELit (LString "          (ref.i31 (i32.trunc_f64_s (call $mdk_stat_field (i32.const 2))))")) (ELit (LString "          (struct.new $float (call $mdk_stat_field (i32.const 3))))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioMakeDirLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioMakeDirLines" () (EListLit (ELit (LString "  ;; makeDir : $str path -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  (func $mdk_make_dir_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_make_dir)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioRemoveFileLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioRemoveFileLines" () (EListLit (ELit (LString "  ;; removeFile : $str path -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  (func $mdk_remove_file_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_remove_file)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioRemoveDirLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioRemoveDirLines" () (EListLit (ELit (LString "  ;; removeDir : $str path -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  (func $mdk_remove_dir_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_remove_dir)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioFsyncLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioFsyncLines" () (EListLit (ELit (LString "  ;; fsync : $str path -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  (func $mdk_fsync_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_fsync)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioFileModeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioFileModeLines" () (EListLit (ELit (LString "  ;; fileMode : $str path -> Result String Int: the permission bits, 0 to 4095.  The host")) (ELit (LString "  ;; takes the stat that statFile takes and answers its mode field, field 4.")) (ELit (LString "  (func $mdk_file_mode_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_file_mode)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0)")) (ELit (LString "        (call $mdk_box_int (i64.trunc_f64_s (call $mdk_stat_field (i32.const 4))))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioGetEnvLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioGetEnvLines" () (EListLit (ELit (LString "  ;; getEnv : $str name -> Option String.  1=Some value / 0=None.")) (ELit (LString "  (func $mdk_get_env_io (param $name (ref $str)) (result (ref eq))")) (ELit (LString "    (local $st i32)")) (ELit (LString "    (call $mdk_push_path (local.get $name))")) (ELit (LString "    (local.set $st (call $mdk_get_env))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then (struct.new $C_Some (i32.const 0) (call $mdk_io_result_to_str)))")) (ELit (LString "      (else (ref.i31 (i32.const 1)))))"))))
(DTypeSig false "ioReadLineLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioReadLineLines" () (EListLit (ELit (LString "  ;; readLine : Unit -> String.  The host answers 1 with a line (its newline")) (ELit (LString "  ;; stripped) on the result channel, or 0 at end of input, where the channel is empty.")) (ELit (LString "  (func $mdk_read_line_io (result (ref eq))")) (ELit (LString "    (drop (call $mdk_read_line))")) (ELit (LString "    (call $mdk_io_result_to_str))")) (ELit (LString "  ;; readLineOpt : Unit -> Option String.  0 is None.")) (ELit (LString "  (func $mdk_read_line_opt_io (result (ref eq))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_read_line)")) (ELit (LString "      (then (struct.new $C_Some (i32.const 0) (call $mdk_io_result_to_str)))")) (ELit (LString "      (else (ref.i31 (i32.const 1)))))"))))
(DTypeSig false "ioReadAllLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioReadAllLines" () (EListLit (ELit (LString "  ;; readAll : Unit -> String.  The rest of the host's stdin buffer.")) (ELit (LString "  (func $mdk_read_all_io (result (ref eq))")) (ELit (LString "    (call $mdk_read_all)")) (ELit (LString "    (call $mdk_io_result_to_str))"))))
(DTypeSig false "ioReadExactlyLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioReadExactlyLines" () (EListLit (ELit (LString "  ;; readExactly : Int -> Option String.  1=Some the n bytes / 0=None (end of input")) (ELit (LString "  ;; or a short read, whose bytes the host has consumed).")) (ELit (LString "  (func $mdk_read_exactly_io (param $n i64) (result (ref eq))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_read_exactly (local.get $n))")) (ELit (LString "      (then (struct.new $C_Some (i32.const 0) (call $mdk_io_result_to_str)))")) (ELit (LString "      (else (ref.i31 (i32.const 1)))))"))))
(DTypeSig false "ioExecutablePathLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioExecutablePathLines" () (EListLit (ELit (LString "  (func $mdk_executable_path_io (result (ref eq))")) (ELit (LString "    (drop (call $mdk_executable_path))")) (ELit (LString "    (call $mdk_io_result_to_str))"))))
(DTypeSig true "ioArgsRuntimeLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ioArgsRuntimeLines" ((PVar "keys")) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_args_count"))) (EVar "keys")) (EVar "ioArgsLines")))
(DTypeSig false "ioArgsLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioArgsLines" () (EListLit (ELit (LString "  ;; build a $str from the i-th host arg (mdk_arg_len(i) + mdk_arg_byte(i,j)).")) (ELit (LString "  (func $mdk_arg_to_str (param $idx i32) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $j i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (call $mdk_arg_len (local.get $idx)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $j (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $j) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $j) (call $mdk_arg_byte (local.get $idx) (local.get $j)))")) (ELit (LString "      (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $l)))")) (ELit (LString "    (call $mdk_u8_to_str_lossy (local.get $buf)))")) (ELit (LString "  ;; args : Unit -> List String.  Fold a Cons chain right-to-left ending in Nil.")) (ELit (LString "  (func $mdk_args_io (result (ref eq))")) (ELit (LString "    (local $c i32) (local $i i32) (local $acc (ref eq))")) (ELit (LString "    (local.set $c (call $mdk_args_count))")) (ELit (LString "    (local.set $acc (ref.i31 (i32.const 1)))")) (ELit (LString "    (local.set $i (i32.sub (local.get $c) (i32.const 1)))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.lt_s (local.get $i) (i32.const 0)))")) (ELit (LString "      (local.set $acc (struct.new $C_Cons (i32.const 0) (call $mdk_arg_to_str (local.get $i)) (local.get $acc)))")) (ELit (LString "      (local.set $i (i32.sub (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $acc))"))))
(DTypeSig true "fileBytesRuntimeLines" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "fileBytesRuntimeLines" ((PVar "readsBytes") (PVar "keys")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_write_file_commit"))) (EVar "keys")) (EVar "writeFileBytesLines")) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_os_entropy"))) (EVar "keys")) (EVar "osEntropyLines"))) (EIf (EVar "readsBytes") (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_read_file"))) (EVar "keys")) (EVar "readFileBytesLines")) (EListLit))))
(DTypeSig false "readFileBytesLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "readFileBytesLines" () (EListLit (ELit (LString "  ;; readFileBytes : $str path -> Result String (Array Int).  1=Ok bytes / 0=Err msg.")) (ELit (LString "  ;; Reuses the read byte-channel but rebuilds an $arr of i31 Int bytes (0..255).")) (ELit (LString "  (func $mdk_read_file_bytes_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $st i32) (local $n i32) (local $i i32) (local $out (ref $arr))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (local.set $st (call $mdk_read_file))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then")) (ELit (LString "        (local.set $n (call $mdk_result_len))")) (ELit (LString "        (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))")) (ELit (LString "        (local.set $i (i32.const 0))")) (ELit (LString "        (block $d (loop $l")) (ELit (LString "          (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "          (array.set $arr (local.get $out) (local.get $i) (ref.i31 (call $mdk_result_byte (local.get $i))))")) (ELit (LString "          (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "        (struct.new $C_Ok (i32.const 0) (local.get $out)))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "osEntropyLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "osEntropyLines" () (EListLit (ELit (LString "  ;; osEntropyBytes : Int -> Array Int.  1=n random bytes / 0=a refusal (its text on the channel).")) (ELit (LString "  (func $mdk_os_entropy_io (param $n i64) (result (ref eq))")) (ELit (LString "    (local $len i32) (local $i i32) (local $out (ref $arr))")) (ELit (LString "    (if (i32.eqz (call $mdk_os_entropy (local.get $n))) (then (call $mdk_refused_panic)))")) (ELit (LString "    (local.set $len (call $mdk_result_len))")) (ELit (LString "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $len)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $len)))")) (ELit (LString "      (array.set $arr (local.get $out) (local.get $i) (ref.i31 (call $mdk_result_byte (local.get $i))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $out))"))))
(DTypeSig false "writeFileBytesLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "writeFileBytesLines" () (EListLit (ELit (LString "  ;; writeFileBytes : $str path -> $arr bytes -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  ;; Stream each i31 byte (masked to 0..255) to the host, then commit fs.writeFileSync.")) (ELit (LString "  (func $mdk_write_file_bytes_io (param $path (ref $str)) (param $ba (ref $arr)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $st i32) (local $n i32) (local $i i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (call $mdk_write_file_reset)")) (ELit (LString "    (local.set $n (array.len (local.get $ba)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_file_push (i32.and (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $ba) (local.get $i)))) (i32.const 255)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.set $st (call $mdk_write_file_commit))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig true "strSearchRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strSearchRuntimeLines" () (EListLit (ELit (LString "  ;; -- W8b stringIndexOf / stringCompare (byte-identical to medaka_rt.c) --")) (ELit (LString "  (func $mdk_str_index_of (param $needle (ref $str)) (param $hay (ref $str)) (result (ref eq))")) (ELit (LString "    (local $nb (ref $u8arr)) (local $hb (ref $u8arr)) (local $nl i32) (local $hl i32)")) (ELit (LString "    (local $b i32) (local $j i32) (local $ok i32)")) (ELit (LString "    (local.set $nb (struct.get $str $bytes (local.get $needle)))")) (ELit (LString "    (local.set $hb (struct.get $str $bytes (local.get $hay)))")) (ELit (LString "    (local.set $nl (array.len (local.get $nb)))")) (ELit (LString "    (local.set $hl (array.len (local.get $hb)))")) (ELit (LString "    ;; empty needle -> Some 0 (codepoint index 0).")) (ELit (LString "    (if (i32.eqz (local.get $nl))")) (ELit (LString "      (then (return (struct.new $C_Some (i32.const 0) (ref.i31 (i32.const 0))))))")) (ELit (LString "    (local.set $b (i32.const 0))")) (ELit (LString "    (block $done (loop $scan")) (ELit (LString "      ;; while b + nl <= hl")) (ELit (LString "      (br_if $done (i32.gt_s (i32.add (local.get $b) (local.get $nl)) (local.get $hl)))")) (ELit (LString "      (local.set $ok (i32.const 1))")) (ELit (LString "      (local.set $j (i32.const 0))")) (ELit (LString "      (block $cmpd (loop $cmpl")) (ELit (LString "        (br_if $cmpd (i32.ge_s (local.get $j) (local.get $nl)))")) (ELit (LString "        (if (i32.ne (array.get_u $u8arr (local.get $hb) (i32.add (local.get $b) (local.get $j)))")) (ELit (LString "                    (array.get_u $u8arr (local.get $nb) (local.get $j)))")) (ELit (LString "          (then (local.set $ok (i32.const 0)) (br $cmpd)))")) (ELit (LString "        (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $cmpl)))")) (ELit (LString "      (if (local.get $ok)")) (ELit (LString "        (then (return (struct.new $C_Some (i32.const 0)")) (ELit (LString "          (ref.i31 (call $mdk_cp_count (local.get $hb) (local.get $b)))))))")) (ELit (LString "      (local.set $b (i32.add (local.get $b) (i32.const 1))) (br $scan)))")) (ELit (LString "    ;; not found -> None (i31 ordinal 1).")) (ELit (LString "    (ref.i31 (i32.const 1)))")) (ELit (LString "  ;; -- W8c byte-level count / last-index (byte-identical to medaka_rt.c) --")) (ELit (LString "  ;; non-overlapping occurrences; 0 for an empty needle.")) (ELit (LString "  (func $mdk_str_count_occ (param $n (ref $str)) (param $h (ref $str)) (result i32)")) (ELit (LString "    (local $nb (ref $u8arr)) (local $hb (ref $u8arr)) (local $nl i32) (local $hl i32)")) (ELit (LString "    (local $b i32) (local $c i32)")) (ELit (LString "    (local.set $nb (struct.get $str $bytes (local.get $n)))")) (ELit (LString "    (local.set $hb (struct.get $str $bytes (local.get $h)))")) (ELit (LString "    (local.set $nl (array.len (local.get $nb)))")) (ELit (LString "    (local.set $hl (array.len (local.get $hb)))")) (ELit (LString "    (if (i32.eqz (local.get $nl)) (then (return (i32.const 0))))")) (ELit (LString "    (block $done (loop $scan")) (ELit (LString "      (br_if $done (i32.gt_s (i32.add (local.get $b) (local.get $nl)) (local.get $hl)))")) (ELit (LString "      (if (call $mdk_bytes_match_at (local.get $nb) (local.get $hb) (local.get $b))")) (ELit (LString "        (then")) (ELit (LString "          (local.set $c (i32.add (local.get $c) (i32.const 1)))")) (ELit (LString "          (local.set $b (i32.add (local.get $b) (local.get $nl))))")) (ELit (LString "        (else (local.set $b (i32.add (local.get $b) (i32.const 1)))))")) (ELit (LString "      (br $scan)))")) (ELit (LString "    (local.get $c))")) (ELit (LString "  ;; overlapping occurrences, the last one wins; an empty needle is at the codepoint end.")) (ELit (LString "  (func $mdk_str_last_index_of (param $n (ref $str)) (param $h (ref $str)) (result (ref eq))")) (ELit (LString "    (local $nb (ref $u8arr)) (local $hb (ref $u8arr)) (local $nl i32) (local $hl i32)")) (ELit (LString "    (local $b i32) (local $last i32)")) (ELit (LString "    (local.set $nb (struct.get $str $bytes (local.get $n)))")) (ELit (LString "    (local.set $hb (struct.get $str $bytes (local.get $h)))")) (ELit (LString "    (local.set $nl (array.len (local.get $nb)))")) (ELit (LString "    (local.set $hl (array.len (local.get $hb)))")) (ELit (LString "    (if (i32.eqz (local.get $nl))")) (ELit (LString "      (then (return (struct.new $C_Some (i32.const 0)")) (ELit (LString "        (ref.i31 (struct.get $str $cp_count (local.get $h)))))))")) (ELit (LString "    (local.set $last (i32.const -1))")) (ELit (LString "    (block $done (loop $scan")) (ELit (LString "      (br_if $done (i32.gt_s (i32.add (local.get $b) (local.get $nl)) (local.get $hl)))")) (ELit (LString "      (if (call $mdk_bytes_match_at (local.get $nb) (local.get $hb) (local.get $b))")) (ELit (LString "        (then (local.set $last (local.get $b))))")) (ELit (LString "      (local.set $b (i32.add (local.get $b) (i32.const 1)))")) (ELit (LString "      (br $scan)))")) (ELit (LString "    (if (i32.lt_s (local.get $last) (i32.const 0))")) (ELit (LString "      (then (return (ref.i31 (i32.const 1)))))")) (ELit (LString "    (struct.new $C_Some (i32.const 0)")) (ELit (LString "      (ref.i31 (call $mdk_cp_count (local.get $hb) (local.get $last)))))")) (ELit (LString "  (func $mdk_str_compare (param $a (ref $str)) (param $b (ref $str)) (result (ref eq))")) (ELit (LString "    (local $ab (ref $u8arr)) (local $bb (ref $u8arr)) (local $al i32) (local $bl i32)")) (ELit (LString "    (local $m i32) (local $i i32) (local $ca i32) (local $cb i32)")) (ELit (LString "    (local.set $ab (struct.get $str $bytes (local.get $a)))")) (ELit (LString "    (local.set $bb (struct.get $str $bytes (local.get $b)))")) (ELit (LString "    (local.set $al (array.len (local.get $ab)))")) (ELit (LString "    (local.set $bl (array.len (local.get $bb)))")) (ELit (LString "    (local.set $m (if (result i32) (i32.lt_s (local.get $al) (local.get $bl))")) (ELit (LString "      (then (local.get $al)) (else (local.get $bl))))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $done (loop $l")) (ELit (LString "      (br_if $done (i32.ge_s (local.get $i) (local.get $m)))")) (ELit (LString "      (local.set $ca (array.get_u $u8arr (local.get $ab) (local.get $i)))")) (ELit (LString "      (local.set $cb (array.get_u $u8arr (local.get $bb) (local.get $i)))")) (ELit (LString "      ;; byte less -> Lt (i31 0); byte greater -> Gt (i31 2).")) (ELit (LString "      (if (i32.lt_u (local.get $ca) (local.get $cb)) (then (return (ref.i31 (i32.const 0)))))")) (ELit (LString "      (if (i32.gt_u (local.get $ca) (local.get $cb)) (then (return (ref.i31 (i32.const 2)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    ;; common prefix equal: shorter < longer; equal length -> Eq.")) (ELit (LString "    (if (i32.lt_s (local.get $al) (local.get $bl)) (then (return (ref.i31 (i32.const 0)))))")) (ELit (LString "    (if (i32.gt_s (local.get $al) (local.get $bl)) (then (return (ref.i31 (i32.const 2)))))")) (ELit (LString "    (ref.i31 (i32.const 1)))"))))
(DTypeSig true "utf8LossyRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "utf8LossyRuntimeLines" () (EListLit (ELit (LString "  ;; -- UTF-8 validation (byte-identical to medaka_rt.c mdk_str_lossy) --")) (ELit (LString "  (func $mdk_utf8_step (param $b (ref $u8arr)) (param $i i32) (param $n i32) (result i32)")) (ELit (LString "    (local $b0 i32) (local $b1 i32) (local $lo i32) (local $hi i32)")) (ELit (LString "    (local.set $b0 (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "    (if (i32.lt_u (local.get $b0) (i32.const 128)) (then (return (i32.const 1))))")) (ELit (LString "    (if (i32.and (i32.ge_u (local.get $b0) (i32.const 194)) (i32.le_u (local.get $b0) (i32.const 223)))")) (ELit (LString "      (then")) (ELit (LString "        (if (i32.lt_s (i32.add (local.get $i) (i32.const 1)) (local.get $n))")) (ELit (LString "          (then (if (i32.eq (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $i) (i32.const 1))) (i32.const 192)) (i32.const 128))")) (ELit (LString "            (then (return (i32.const 2))))))")) (ELit (LString "        (return (i32.const -1))))")) (ELit (LString "    (if (i32.or (i32.lt_u (local.get $b0) (i32.const 224)) (i32.gt_u (local.get $b0) (i32.const 244)))")) (ELit (LString "      (then (return (i32.const -1))))")) (ELit (LString "    ;; E0 and F0 bound the second byte below (overlong), ED and F4 above.")) (ELit (LString "    (local.set $lo (select (i32.const 160) (select (i32.const 144) (i32.const 128) (i32.eq (local.get $b0) (i32.const 240))) (i32.eq (local.get $b0) (i32.const 224))))")) (ELit (LString "    (local.set $hi (select (i32.const 159) (select (i32.const 143) (i32.const 191) (i32.eq (local.get $b0) (i32.const 244))) (i32.eq (local.get $b0) (i32.const 237))))")) (ELit (LString "    (if (i32.ge_s (i32.add (local.get $i) (i32.const 1)) (local.get $n)) (then (return (i32.const -1))))")) (ELit (LString "    (local.set $b1 (array.get_u $u8arr (local.get $b) (i32.add (local.get $i) (i32.const 1))))")) (ELit (LString "    (if (i32.or (i32.lt_u (local.get $b1) (local.get $lo)) (i32.gt_u (local.get $b1) (local.get $hi)))")) (ELit (LString "      (then (return (i32.const -1))))")) (ELit (LString "    (if (i32.ge_s (i32.add (local.get $i) (i32.const 2)) (local.get $n)) (then (return (i32.const -2))))")) (ELit (LString "    (if (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $i) (i32.const 2))) (i32.const 192)) (i32.const 128))")) (ELit (LString "      (then (return (i32.const -2))))")) (ELit (LString "    (if (i32.lt_u (local.get $b0) (i32.const 240)) (then (return (i32.const 3))))")) (ELit (LString "    (if (i32.ge_s (i32.add (local.get $i) (i32.const 3)) (local.get $n)) (then (return (i32.const -3))))")) (ELit (LString "    (if (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $i) (i32.const 3))) (i32.const 192)) (i32.const 128))")) (ELit (LString "      (then (return (i32.const -3))))")) (ELit (LString "    (i32.const 4))")) (ELit (LString "  (func $mdk_utf8_valid_count (param $b (ref $u8arr)) (result i32)")) (ELit (LString "    (local $n i32) (local $i i32) (local $c i32) (local $st i32)")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $c (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $st (call $mdk_utf8_step (local.get $b) (local.get $i) (local.get $n)))")) (ELit (LString "      (if (i32.lt_s (local.get $st) (i32.const 0)) (then (return (i32.const -1))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (local.get $st)))")) (ELit (LString "      (local.set $c (i32.add (local.get $c) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $c))")) (ELit (LString "  (func $mdk_u8_to_str_lossy (param $b (ref $u8arr)) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $j i32) (local $c i32) (local $st i32) (local $out i32)")) (ELit (LString "    (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $c (call $mdk_utf8_valid_count (local.get $b)))")) (ELit (LString "    (if (i32.ge_s (local.get $c) (i32.const 0))")) (ELit (LString "      (then (return (struct.new $str (local.get $c) (local.get $b)))))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    ;; pass 1: the output length, 3 bytes per replacement.")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $out (i32.const 0))")) (ELit (LString "    (block $d1 (loop $l1")) (ELit (LString "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $st (call $mdk_utf8_step (local.get $b) (local.get $i) (local.get $n)))")) (ELit (LString "      (if (i32.gt_s (local.get $st) (i32.const 0))")) (ELit (LString "        (then")) (ELit (LString "          (local.set $out (i32.add (local.get $out) (local.get $st)))")) (ELit (LString "          (local.set $i (i32.add (local.get $i) (local.get $st))))")) (ELit (LString "        (else")) (ELit (LString "          (local.set $out (i32.add (local.get $out) (i32.const 3)))")) (ELit (LString "          (local.set $i (i32.sub (local.get $i) (local.get $st)))))")) (ELit (LString "      (br $l1)))")) (ELit (LString "    ;; pass 2: copy each well-formed sequence, U+FFFD for each subpart.")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $out)))")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $j (i32.const 0)) (local.set $c (i32.const 0))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $st (call $mdk_utf8_step (local.get $b) (local.get $i) (local.get $n)))")) (ELit (LString "      (if (i32.gt_s (local.get $st) (i32.const 0))")) (ELit (LString "        (then")) (ELit (LString "          (array.copy $u8arr $u8arr (local.get $buf) (local.get $j) (local.get $b) (local.get $i) (local.get $st))")) (ELit (LString "          (local.set $j (i32.add (local.get $j) (local.get $st)))")) (ELit (LString "          (local.set $i (i32.add (local.get $i) (local.get $st))))")) (ELit (LString "        (else")) (ELit (LString "          (array.set $u8arr (local.get $buf) (local.get $j) (i32.const 239))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.add (local.get $j) (i32.const 1)) (i32.const 191))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.add (local.get $j) (i32.const 2)) (i32.const 189))")) (ELit (LString "          (local.set $j (i32.add (local.get $j) (i32.const 3)))")) (ELit (LString "          (local.set $i (i32.sub (local.get $i) (local.get $st)))))")) (ELit (LString "      (local.set $c (i32.add (local.get $c) (i32.const 1))) (br $l2)))")) (ELit (LString "    (struct.new $str (local.get $c) (local.get $buf)))"))))
(DTypeSig true "strCodecRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strCodecRuntimeLines" () (EListLit (ELit (LString "  ;; -- W11b UTF-8 codec (byte-identical to medaka_rt.c) --")) (ELit (LString "  ;; decode a $str's UTF-8 bytes into a fresh $arr of cp_count i31 Char codepoints.")) (ELit (LString "  (func $mdk_str_to_chars (param $s (ref $str)) (result (ref $arr))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $cpc i32) (local $out (ref $arr))")) (ELit (LString "    (local $bo i32) (local $oi i32) (local $lead i32) (local $cp i32) (local $k i32) (local $w i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $cpc (struct.get $str $cp_count (local.get $s)))")) (ELit (LString "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $cpc)))")) (ELit (LString "    (local.set $bo (i32.const 0)) (local.set $oi (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $bo) (local.get $n)))")) (ELit (LString "      ;; the output holds cp_count codepoints; never step past it.")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $oi) (local.get $cpc)))")) (ELit (LString "      (local.set $lead (array.get_u $u8arr (local.get $b) (local.get $bo)))")) (ELit (LString "      ;; lead-byte class → codepoint seed bits + total byte width.")) (ELit (LString "      (if (i32.lt_u (local.get $lead) (i32.const 128))")) (ELit (LString "        (then (local.set $cp (local.get $lead)) (local.set $w (i32.const 1)))")) (ELit (LString "        (else (if (i32.lt_u (local.get $lead) (i32.const 224))")) (ELit (LString "          (then (local.set $cp (i32.and (local.get $lead) (i32.const 31))) (local.set $w (i32.const 2)))")) (ELit (LString "          (else (if (i32.lt_u (local.get $lead) (i32.const 240))")) (ELit (LString "            (then (local.set $cp (i32.and (local.get $lead) (i32.const 15))) (local.set $w (i32.const 3)))")) (ELit (LString "            (else (local.set $cp (i32.and (local.get $lead) (i32.const 7))) (local.set $w (i32.const 4))))))))")) (ELit (LString "      ;; a sequence never reads past the backing's end.")) (ELit (LString "      (if (i32.gt_s (local.get $w) (i32.sub (local.get $n) (local.get $bo)))")) (ELit (LString "        (then (local.set $w (i32.sub (local.get $n) (local.get $bo)))))")) (ELit (LString "      ;; fold in (w-1) continuation bytes: cp = (cp << 6) | (byte & 0x3F).")) (ELit (LString "      (local.set $k (i32.const 1))")) (ELit (LString "      (block $cd (loop $cl")) (ELit (LString "        (br_if $cd (i32.ge_s (local.get $k) (local.get $w)))")) (ELit (LString "        (local.set $cp (i32.or (i32.shl (local.get $cp) (i32.const 6))")) (ELit (LString "          (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $bo) (local.get $k))) (i32.const 63))))")) (ELit (LString "        (local.set $k (i32.add (local.get $k) (i32.const 1))) (br $cl)))")) (ELit (LString "      (array.set $arr (local.get $out) (local.get $oi) (ref.i31 (local.get $cp)))")) (ELit (LString "      (local.set $oi (i32.add (local.get $oi) (i32.const 1)))")) (ELit (LString "      (local.set $bo (i32.add (local.get $bo) (local.get $w))) (br $l)))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; number of UTF-8 bytes a codepoint encodes to (1..4).")) (ELit (LString "  (func $mdk_utf8_nbytes (param $cp i32) (result i32)")) (ELit (LString "    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 128)) (then (i32.const 1))")) (ELit (LString "      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 2048)) (then (i32.const 2))")) (ELit (LString "        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 65536)) (then (i32.const 3))")) (ELit (LString "          (else (i32.const 4))))))))")) (ELit (LString "  ;; encode one codepoint into $buf at offset $off; return the next offset.")) (ELit (LString "  (func $mdk_utf8_emit_at (param $buf (ref $u8arr)) (param $off i32) (param $cp i32) (result i32)")) (ELit (LString "    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 128))")) (ELit (LString "      (then")) (ELit (LString "        (array.set $u8arr (local.get $buf) (local.get $off) (local.get $cp))")) (ELit (LString "        (i32.add (local.get $off) (i32.const 1)))")) (ELit (LString "      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 2048))")) (ELit (LString "        (then")) (ELit (LString "          (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "          (i32.add (local.get $off) (i32.const 2)))")) (ELit (LString "        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 65536))")) (ELit (LString "          (then")) (ELit (LString "            (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 2)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (i32.add (local.get $off) (i32.const 3)))")) (ELit (LString "          (else")) (ELit (LString "            (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 2)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 3)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (i32.add (local.get $off) (i32.const 4))))))))")) (ELit (LString "  )")) (ELit (LString "  ;; encode an $arr of i31 Char codepoints into a fresh $str (UTF-8); cp_count = len.")) (ELit (LString "  (func $mdk_chars_to_str (param $a (ref $arr)) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $total i32) (local $off i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $cp i32)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    ;; pass 1: total encoded byte length.")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $total (i32.const 0))")) (ELit (LString "    (block $d1 (loop $l1")) (ELit (LString "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $cp (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))))")) (ELit (LString "      (local.set $total (i32.add (local.get $total) (call $mdk_utf8_nbytes (local.get $cp))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))")) (ELit (LString "    ;; pass 2: encode into the buffer.")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $off (i32.const 0))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $cp (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))))")) (ELit (LString "      (local.set $off (call $mdk_utf8_emit_at (local.get $buf) (local.get $off) (local.get $cp)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))")) (ELit (LString "    (struct.new $str (local.get $n) (local.get $buf)))")) (ELit (LString "  ;; stringToUtf8Bytes: copy the $str's $u8arr backing into a fresh $arr of i31 Int bytes.")) (ELit (LString "  (func $mdk_str_to_utf8_bytes (param $s (ref $str)) (result (ref $arr))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $out (ref $arr)) (local $i i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $arr (local.get $out) (local.get $i) (ref.i31 (array.get_u $u8arr (local.get $b) (local.get $i))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; stringFromUtf8Bytes: blit the low 8 bits of each i31 Int into a $u8arr, read")) (ELit (LString "  ;; as UTF-8 by $mdk_u8_to_str_lossy (medaka_rt.c mdk_string_from_utf8_bytes).")) (ELit (LString "  (func $mdk_utf8_bytes_to_str (param $a (ref $arr)) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $buf (ref $u8arr)) (local $i i32)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i)")) (ELit (LString "        (i32.and (i31.get_u (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))) (i32.const 255)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (call $mdk_u8_to_str_lossy (local.get $buf)))"))))
(DTypeSig true "byteBlockRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "byteBlockRuntimeLines" () (EBinOp "++" (EListLit (ELit (LString "  ;; -- the `ByteBlock` builtin (peer of the mdk_byteblock_* C helpers) --")) (ELit (LString "  ;; byteBlockCopyUnsafe: the first $n bytes into a FRESH block.  A COPY, never a")) (ELit (LString "  ;; view: this is freeze's engine half, so a later write to the source must not")) (ELit (LString "  ;; reach the result (matching mdk_byteblock_copy's memcpy).")) (ELit (LString "  (func $mdk_bb_copy (param $n i32) (param $b (ref $u8arr)) (result (ref $u8arr))")) (ELit (LString "    (local $out (ref $u8arr))")) (ELit (LString "    (local.set $out (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $out) (i32.const 0) (local.get $b) (i32.const 0) (local.get $n))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; byteBlockFromIntArray: the low eight bits of each element.  Unboxes through")) (ELit (LString "  ;; $mdk_unbox_int rather than the i31 fast path so an element outside the i31")) (ELit (LString "  ;; range (a $boxint) masks instead of trapping -- native has no boxed Int, so")) (ELit (LString "  ;; the i31-only route would diverge on exactly those elements.")) (ELit (LString "  (func $mdk_bb_from_int_array (param $a (ref $arr)) (result (ref $u8arr))")) (ELit (LString "    (local $n i32) (local $out (ref $u8arr)) (local $i i32)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    (local.set $out (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $out) (local.get $i)")) (ELit (LString "        (i32.and (i32.wrap_i64 (call $mdk_unbox_int (ref.as_non_null (array.get $arr (local.get $a) (local.get $i))))) (i32.const 255)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; byteBlockToIntArray: each byte as an Int in 0..255 (array.get_u zero-extends).")) (ELit (LString "  (func $mdk_bb_to_int_array (param $b (ref $u8arr)) (result (ref $arr))")) (ELit (LString "    (local $n i32) (local $out (ref $arr)) (local $i i32)")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $arr (local.get $out) (local.get $i) (ref.i31 (array.get_u $u8arr (local.get $b) (local.get $i))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; byteBlockFromString: the string's UTF-8 bytes, COPIED.  A $str's backing is")) (ELit (LString "  ;; shared by every reference to that string and a block is mutable, so handing")) (ELit (LString "  ;; the backing back unaliased would let a write edit the string.")) (ELit (LString "  (func $mdk_bb_from_string (param $s (ref $str)) (result (ref $u8arr))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $out (ref $u8arr))")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $out (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $out) (i32.const 0) (local.get $b) (i32.const 0) (local.get $n))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; byteBlockToString: the block's bytes as a fresh $str.  The backing is COPIED")) (ELit (LString "  ;; because a block is mutable and a $str's bytes are shared by every reference to")) (ELit (LString "  ;; it; the copy is then read as UTF-8 by $mdk_u8_to_str_lossy, the same route as")) (ELit (LString "  ;; $mdk_utf8_bytes_to_str and medaka_rt.c's mdk_byteblock_to_string.")) (ELit (LString "  (func $mdk_bb_to_string (param $b (ref $u8arr)) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $b) (i32.const 0) (local.get $n))")) (ELit (LString "    (call $mdk_u8_to_str_lossy (local.get $buf)))")) (ELit (LString "  ;; byteBlockWriteStdout: write the block's bytes to stdout byte-for-byte, no")) (ELit (LString "  ;; encoding assumption -- unlike $mdk_print_str, there is no $str/cp_count to")) (ELit (LString "  ;; read, just the raw $u8arr length.")) (ELit (LString "  (func $mdk_bb_write_stdout (param $b (ref $u8arr))")) (ELit (LString "    (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))"))) (EVar "sha256RuntimeLines")))
(DTypeSig false "sha256K" (TyApp (TyCon "List") (TyCon "Int")))
(DFunDef false "sha256K" () (EListLit (ELit (LInt 1116352408)) (ELit (LInt 1899447441)) (ELit (LInt 3049323471)) (ELit (LInt 3921009573)) (ELit (LInt 961987163)) (ELit (LInt 1508970993)) (ELit (LInt 2453635748)) (ELit (LInt 2870763221)) (ELit (LInt 3624381080)) (ELit (LInt 310598401)) (ELit (LInt 607225278)) (ELit (LInt 1426881987)) (ELit (LInt 1925078388)) (ELit (LInt 2162078206)) (ELit (LInt 2614888103)) (ELit (LInt 3248222580)) (ELit (LInt 3835390401)) (ELit (LInt 4022224774)) (ELit (LInt 264347078)) (ELit (LInt 604807628)) (ELit (LInt 770255983)) (ELit (LInt 1249150122)) (ELit (LInt 1555081692)) (ELit (LInt 1996064986)) (ELit (LInt 2554220882)) (ELit (LInt 2821834349)) (ELit (LInt 2952996808)) (ELit (LInt 3210313671)) (ELit (LInt 3336571891)) (ELit (LInt 3584528711)) (ELit (LInt 113926993)) (ELit (LInt 338241895)) (ELit (LInt 666307205)) (ELit (LInt 773529912)) (ELit (LInt 1294757372)) (ELit (LInt 1396182291)) (ELit (LInt 1695183700)) (ELit (LInt 1986661051)) (ELit (LInt 2177026350)) (ELit (LInt 2456956037)) (ELit (LInt 2730485921)) (ELit (LInt 2820302411)) (ELit (LInt 3259730800)) (ELit (LInt 3345764771)) (ELit (LInt 3516065817)) (ELit (LInt 3600352804)) (ELit (LInt 4094571909)) (ELit (LInt 275423344)) (ELit (LInt 430227734)) (ELit (LInt 506948616)) (ELit (LInt 659060556)) (ELit (LInt 883997877)) (ELit (LInt 958139571)) (ELit (LInt 1322822218)) (ELit (LInt 1537002063)) (ELit (LInt 1747873779)) (ELit (LInt 1955562222)) (ELit (LInt 2024104815)) (ELit (LInt 2227730452)) (ELit (LInt 2361852424)) (ELit (LInt 2428436474)) (ELit (LInt 2756734187)) (ELit (LInt 3204031479)) (ELit (LInt 3329325298))))
(DTypeSig false "shaLabel" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "shaLabel" ((PVar "j")) (EBinOp "++" (EBinOp "++" (ELit (LString "$c")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "j")))) (ELit (LString ""))))
(DTypeSig false "sha256KLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "sha256KLines" () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  (func $mdk_sha_k (param $i i32) (result i32)"))) (EApp (EApp (EVar "map") (ELam ((PVar "j")) (EBinOp "++" (EBinOp "++" (ELit (LString "    (block $c")) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "-" (ELit (LInt 63)) (EVar "j"))))) (ELit (LString ""))))) (ERangeList (ELit (LInt 0)) (ELit (LInt 63)) true))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (br_table ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "shaLabel")) (ERangeList (ELit (LInt 0)) (ELit (LInt 63)) true)))) (ELit (LString " $c63 (local.get $i))"))))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "kc")) (EListLit (ELit (LString "    )")) (EBinOp "++" (EBinOp "++" (ELit (LString "    (return (i32.const ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "kc")))) (ELit (LString "))")))))) (EVar "sha256K"))) (EListLit (ELit (LString "  )")))))
(DTypeSig false "sha256RuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "sha256RuntimeLines" () (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; -- sha256Native (peer of medaka_rt.c mdk_sha256) --")) (ELit (LString "  (func $mdk_sha_get (param $a (ref $u8arr)) (param $i i32) (result i32)")) (ELit (LString "    (local $o i32)")) (ELit (LString "    (local.set $o (i32.shl (local.get $i) (i32.const 2)))")) (ELit (LString "    (i32.or")) (ELit (LString "      (i32.or (array.get_u $u8arr (local.get $a) (local.get $o))")) (ELit (LString "              (i32.shl (array.get_u $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 1))) (i32.const 8)))")) (ELit (LString "      (i32.or (i32.shl (array.get_u $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 2))) (i32.const 16))")) (ELit (LString "              (i32.shl (array.get_u $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 3))) (i32.const 24)))))")) (ELit (LString "  (func $mdk_sha_set (param $a (ref $u8arr)) (param $i i32) (param $v i32)")) (ELit (LString "    (local $o i32)")) (ELit (LString "    (local.set $o (i32.shl (local.get $i) (i32.const 2)))")) (ELit (LString "    (array.set $u8arr (local.get $a) (local.get $o) (local.get $v))")) (ELit (LString "    (array.set $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 1)) (i32.shr_u (local.get $v) (i32.const 8)))")) (ELit (LString "    (array.set $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 2)) (i32.shr_u (local.get $v) (i32.const 16)))")) (ELit (LString "    (array.set $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 3)) (i32.shr_u (local.get $v) (i32.const 24))))"))) (EVar "sha256KLines")) (EListLit (ELit (LString "  ;; One 64-byte block of $src at $off folded into the state $h; $w is the 256-byte schedule scratch.")) (ELit (LString "  (func $mdk_sha_block (param $h (ref $u8arr)) (param $src (ref $u8arr)) (param $off i32) (param $w (ref $u8arr))")) (ELit (LString "    (local $i i32) (local $p i32) (local $x i32) (local $s0 i32) (local $s1 i32)")) (ELit (LString "    (local $a i32) (local $b i32) (local $c i32) (local $d i32) (local $e i32) (local $f i32) (local $g i32) (local $hh i32)")) (ELit (LString "    (local $t1 i32) (local $t2 i32)")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d1 (loop $l1")) (ELit (LString "      (br_if $d1 (i32.ge_u (local.get $i) (i32.const 16)))")) (ELit (LString "      (local.set $p (i32.add (local.get $off) (i32.shl (local.get $i) (i32.const 2))))")) (ELit (LString "      (call $mdk_sha_set (local.get $w) (local.get $i)")) (ELit (LString "        (i32.or")) (ELit (LString "          (i32.or (i32.shl (array.get_u $u8arr (local.get $src) (local.get $p)) (i32.const 24))")) (ELit (LString "                  (i32.shl (array.get_u $u8arr (local.get $src) (i32.add (local.get $p) (i32.const 1))) (i32.const 16)))")) (ELit (LString "          (i32.or (i32.shl (array.get_u $u8arr (local.get $src) (i32.add (local.get $p) (i32.const 2))) (i32.const 8))")) (ELit (LString "                  (array.get_u $u8arr (local.get $src) (i32.add (local.get $p) (i32.const 3))))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_u (local.get $i) (i32.const 64)))")) (ELit (LString "      (local.set $x (call $mdk_sha_get (local.get $w) (i32.sub (local.get $i) (i32.const 15))))")) (ELit (LString "      (local.set $s0 (i32.xor (i32.xor (i32.rotr (local.get $x) (i32.const 7)) (i32.rotr (local.get $x) (i32.const 18))) (i32.shr_u (local.get $x) (i32.const 3))))")) (ELit (LString "      (local.set $x (call $mdk_sha_get (local.get $w) (i32.sub (local.get $i) (i32.const 2))))")) (ELit (LString "      (local.set $s1 (i32.xor (i32.xor (i32.rotr (local.get $x) (i32.const 17)) (i32.rotr (local.get $x) (i32.const 19))) (i32.shr_u (local.get $x) (i32.const 10))))")) (ELit (LString "      (call $mdk_sha_set (local.get $w) (local.get $i)")) (ELit (LString "        (i32.add (i32.add (call $mdk_sha_get (local.get $w) (i32.sub (local.get $i) (i32.const 16))) (local.get $s0))")) (ELit (LString "                 (i32.add (call $mdk_sha_get (local.get $w) (i32.sub (local.get $i) (i32.const 7))) (local.get $s1))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))")) (ELit (LString "    (local.set $a (call $mdk_sha_get (local.get $h) (i32.const 0)))")) (ELit (LString "    (local.set $b (call $mdk_sha_get (local.get $h) (i32.const 1)))")) (ELit (LString "    (local.set $c (call $mdk_sha_get (local.get $h) (i32.const 2)))")) (ELit (LString "    (local.set $d (call $mdk_sha_get (local.get $h) (i32.const 3)))")) (ELit (LString "    (local.set $e (call $mdk_sha_get (local.get $h) (i32.const 4)))")) (ELit (LString "    (local.set $f (call $mdk_sha_get (local.get $h) (i32.const 5)))")) (ELit (LString "    (local.set $g (call $mdk_sha_get (local.get $h) (i32.const 6)))")) (ELit (LString "    (local.set $hh (call $mdk_sha_get (local.get $h) (i32.const 7)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d3 (loop $l3")) (ELit (LString "      (br_if $d3 (i32.ge_u (local.get $i) (i32.const 64)))")) (ELit (LString "      (local.set $t1")) (ELit (LString "        (i32.add")) (ELit (LString "          (i32.add (local.get $hh)")) (ELit (LString "            (i32.xor (i32.xor (i32.rotr (local.get $e) (i32.const 6)) (i32.rotr (local.get $e) (i32.const 11))) (i32.rotr (local.get $e) (i32.const 25))))")) (ELit (LString "          (i32.add")) (ELit (LString "            (i32.xor (i32.and (local.get $e) (local.get $f)) (i32.and (i32.xor (local.get $e) (i32.const -1)) (local.get $g)))")) (ELit (LString "            (i32.add (call $mdk_sha_k (local.get $i)) (call $mdk_sha_get (local.get $w) (local.get $i))))))")) (ELit (LString "      (local.set $t2")) (ELit (LString "        (i32.add")) (ELit (LString "          (i32.xor (i32.xor (i32.rotr (local.get $a) (i32.const 2)) (i32.rotr (local.get $a) (i32.const 13))) (i32.rotr (local.get $a) (i32.const 22)))")) (ELit (LString "          (i32.xor (i32.xor (i32.and (local.get $a) (local.get $b)) (i32.and (local.get $a) (local.get $c))) (i32.and (local.get $b) (local.get $c)))))")) (ELit (LString "      (local.set $hh (local.get $g))")) (ELit (LString "      (local.set $g (local.get $f))")) (ELit (LString "      (local.set $f (local.get $e))")) (ELit (LString "      (local.set $e (i32.add (local.get $d) (local.get $t1)))")) (ELit (LString "      (local.set $d (local.get $c))")) (ELit (LString "      (local.set $c (local.get $b))")) (ELit (LString "      (local.set $b (local.get $a))")) (ELit (LString "      (local.set $a (i32.add (local.get $t1) (local.get $t2)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l3)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 0) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 0)) (local.get $a)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 1) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 1)) (local.get $b)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 2) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 2)) (local.get $c)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 3) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 3)) (local.get $d)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 4) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 4)) (local.get $e)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 5) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 5)) (local.get $f)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 6) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 6)) (local.get $g)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 7) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 7)) (local.get $hh))))")) (ELit (LString "  (func $mdk_sha256 (param $b (ref $u8arr)) (result (ref $u8arr))")) (ELit (LString "    (local $n i32) (local $full i32) (local $rem i32) (local $size i32) (local $i i32) (local $x i32)")) (ELit (LString "    (local $h (ref $u8arr)) (local $w (ref $u8arr)) (local $tail (ref $u8arr)) (local $out (ref $u8arr)) (local $bits i64)")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $h (array.new $u8arr (i32.const 0) (i32.const 32)))")) (ELit (LString "    (local.set $w (array.new $u8arr (i32.const 0) (i32.const 256)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 0) (i32.const 1779033703))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 1) (i32.const -1150833019))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 2) (i32.const 1013904242))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 3) (i32.const -1521486534))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 4) (i32.const 1359893119))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 5) (i32.const -1694144372))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 6) (i32.const 528734635))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 7) (i32.const 1541459225))")) (ELit (LString "    (local.set $full (i32.shr_u (local.get $n) (i32.const 6)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_u (local.get $i) (local.get $full)))")) (ELit (LString "      (call $mdk_sha_block (local.get $h) (local.get $b) (i32.shl (local.get $i) (i32.const 6)) (local.get $w))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.set $rem (i32.and (local.get $n) (i32.const 63)))")) (ELit (LString "    (local.set $size (select (i32.const 64) (i32.const 128) (i32.le_u (i32.add (local.get $rem) (i32.const 9)) (i32.const 64))))")) (ELit (LString "    (local.set $tail (array.new $u8arr (i32.const 0) (i32.const 128)))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $tail) (i32.const 0) (local.get $b) (i32.shl (local.get $full) (i32.const 6)) (local.get $rem))")) (ELit (LString "    (array.set $u8arr (local.get $tail) (local.get $rem) (i32.const 128))")) (ELit (LString "    (local.set $bits (i64.shl (i64.extend_i32_u (local.get $n)) (i64.const 3)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d4 (loop $l4")) (ELit (LString "      (br_if $d4 (i32.ge_u (local.get $i) (i32.const 8)))")) (ELit (LString "      (array.set $u8arr (local.get $tail) (i32.sub (i32.sub (local.get $size) (i32.const 1)) (local.get $i))")) (ELit (LString "        (i32.wrap_i64 (i64.shr_u (local.get $bits) (i64.extend_i32_u (i32.shl (local.get $i) (i32.const 3))))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l4)))")) (ELit (LString "    (call $mdk_sha_block (local.get $h) (local.get $tail) (i32.const 0) (local.get $w))")) (ELit (LString "    (if (i32.eq (local.get $size) (i32.const 128))")) (ELit (LString "      (then (call $mdk_sha_block (local.get $h) (local.get $tail) (i32.const 64) (local.get $w))))")) (ELit (LString "    (local.set $out (array.new $u8arr (i32.const 0) (i32.const 32)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d5 (loop $l5")) (ELit (LString "      (br_if $d5 (i32.ge_u (local.get $i) (i32.const 8)))")) (ELit (LString "      (local.set $x (call $mdk_sha_get (local.get $h) (local.get $i)))")) (ELit (LString "      (array.set $u8arr (local.get $out) (i32.shl (local.get $i) (i32.const 2)) (i32.shr_u (local.get $x) (i32.const 24)))")) (ELit (LString "      (array.set $u8arr (local.get $out) (i32.add (i32.shl (local.get $i) (i32.const 2)) (i32.const 1)) (i32.shr_u (local.get $x) (i32.const 16)))")) (ELit (LString "      (array.set $u8arr (local.get $out) (i32.add (i32.shl (local.get $i) (i32.const 2)) (i32.const 2)) (i32.shr_u (local.get $x) (i32.const 8)))")) (ELit (LString "      (array.set $u8arr (local.get $out) (i32.add (i32.shl (local.get $i) (i32.const 2)) (i32.const 3)) (local.get $x))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l5)))")) (ELit (LString "    (local.get $out))")))))
(DTypeSig true "charFromCodeRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "charFromCodeRuntimeLines" () (EListLit (ELit (LString "  ;; -- W11b charFromCode (byte-identical to medaka_rt.c mdk_char_from_code) --")) (ELit (LString "  (func $mdk_char_from_code (param $cp i32) (result (ref eq))")) (ELit (LString "    ;; valid: 0 <= cp <= 0x10FFFF and not (0xD800 <= cp <= 0xDFFF).")) (ELit (LString "    (if (i32.and (i32.and (i32.ge_s (local.get $cp) (i32.const 0)) (i32.le_s (local.get $cp) (i32.const 1114111)))")) (ELit (LString "                 (i32.eqz (i32.and (i32.ge_s (local.get $cp) (i32.const 55296)) (i32.le_s (local.get $cp) (i32.const 57343)))))")) (ELit (LString "      (then (return (struct.new $C_Some (i32.const 0) (ref.i31 (local.get $cp))))))")) (ELit (LString "    (ref.i31 (i32.const 1)))"))))
(DTypeSig true "plannedImportLines" (TyFun (TyApp (TyCon "List") (TyCon "PlannedImport")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "plannedImportLines" () (EApp (EVar "map") (ELam ((PVar "imp")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  (import \"")) (EApp (EVar "display") (EFieldAccess (EVar "imp") "namespace"))) (ELit (LString "\" \""))) (EApp (EVar "display") (EFieldAccess (EVar "imp") "field"))) (ELit (LString "\" (func $"))) (EApp (EVar "display") (EFieldAccess (EVar "imp") "watSymbol"))) (ELit (LString ""))) (EApp (EVar "display") (EFieldAccess (EVar "imp") "signature"))) (ELit (LString "))"))))))
(DTypeSig true "plannedHelperLines" (TyFun (TyCon "WasmDemandPlan") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "plannedHelperLines" ((PVar "plan") (PVar "files")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "name")) (EIf (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (EVar "name")) (EApp (EApp (EApp (EVar "plannedHelperBlock") (EVar "plan")) (EVar "files")) (EVar "name")) (EListLit)))) (EVar "helperOrder")))
(DTypeSig false "plannedHelperBlock" (TyFun (TyCon "WasmDemandPlan") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "closApplyLines"))) (EVar "closApplyLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioRuntimeLines"))) (EVar "ioRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioStrRuntimeLines"))) (EVar "ioStrRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strLeafRuntimeLines"))) (EVar "strLeafRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strConcatRuntimeLines"))) (EVar "strConcatRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "appendRuntimeLines"))) (EVar "appendRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueEqRuntimeLines"))) (EApp (EVar "valueEqRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueAddRuntimeLines"))) (EApp (EVar "valueAddRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueSubRuntimeLines"))) (EApp (EVar "valueSubRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueMulRuntimeLines"))) (EApp (EVar "valueMulRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueDivRuntimeLines"))) (EApp (EVar "valueDivRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueModRuntimeLines"))) (EApp (EVar "valueModRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueCmpNumRuntimeLines"))) (EApp (EVar "valueCmpNumRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "u64RuntimeLines"))) (EVar "u64RuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "i64RuntimeLines"))) (EVar "i64RuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "stderrRuntimeLines"))) (EVar "stderrRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "rngRuntimeLines"))) (EVar "rngRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "hashRuntimeLines"))) (EVar "hashRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "hashStringRuntimeLines"))) (EVar "hashStringRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "floatRemRuntimeLines"))) (EVar "floatRemRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "floatRuntimeLines"))) (EVar "floatRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "hashFloatRuntimeLines"))) (EVar "hashFloatRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "randomFloatRuntimeLines"))) (EVar "randomFloatRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "floatStrLines"))) (EVar "floatStrLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strSearchRuntimeLines"))) (EVar "strSearchRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strToIntRuntimeLines"))) (EVar "strToIntRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strReverseRuntimeLines"))) (EVar "strReverseRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strJoinRuntimeLines"))) (EVar "strJoinRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strCodecRuntimeLines"))) (EVar "strCodecRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "byteBlockRuntimeLines"))) (EVar "byteBlockRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "charFromCodeRuntimeLines"))) (EVar "charFromCodeRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "charClassRuntimeLines"))) (EVar "charClassRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioPushPathLines"))) (EVar "ioPushPathLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioPushPathMoreLines"))) (EVar "ioPushPathMoreLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioPushGrantLines"))) (EVar "ioPushGrantLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioPushGrantMoreLines"))) (EVar "ioPushGrantMoreLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioResultLines"))) (EVar "ioResultLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioRefusedPanicLines"))) (EVar "ioRefusedPanicLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioReadFileLines"))) (EVar "ioReadFileLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioFetchTextLines"))) (EVar "ioFetchTextLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioFileExistsLines"))) (EVar "ioFileExistsLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioCanonicalizeLines"))) (EVar "ioCanonicalizeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioWriteFileLines"))) (EVar "ioWriteFileLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioAppendFileLines"))) (EVar "ioAppendFileLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioRenameLines"))) (EVar "ioRenameLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioListDirLines"))) (EVar "ioListDirLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioStatFileLines"))) (EVar "ioStatFileLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioMakeDirLines"))) (EVar "ioMakeDirLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioRemoveFileLines"))) (EVar "ioRemoveFileLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioRemoveDirLines"))) (EVar "ioRemoveDirLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioFsyncLines"))) (EVar "ioFsyncLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioFileModeLines"))) (EVar "ioFileModeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioWriteFileModeLines"))) (EVar "ioWriteFileModeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioGetEnvLines"))) (EVar "ioGetEnvLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioReadLineLines"))) (EVar "ioReadLineLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioReadAllLines"))) (EVar "ioReadAllLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioReadExactlyLines"))) (EVar "ioReadExactlyLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioExecutablePathLines"))) (EVar "ioExecutablePathLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "jsffiArrayLines"))) (EVar "jsffiArrayLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "jsffiResultStrLines"))) (EVar "jsffiResultStrLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioArgsLines"))) (EVar "ioArgsLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "utf8LossyRuntimeLines"))) (EVar "utf8LossyRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "writeFileBytesLines"))) (EVar "writeFileBytesLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "osEntropyLines"))) (EVar "osEntropyLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "readFileBytesLines"))) (EVar "readFileBytesLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "trapIntRuntimeLines"))) (EVar "trapIntRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "intRuntimeLines"))) (EApp (EVar "intRuntimeLines") (EFieldAccess (EVar "plan") "intHelpers")))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "siteRuntimeLines"))) (EApp (EApp (EVar "siteRuntimeLines") (EVar "files")) (EFieldAccess (EVar "plan") "nonexhaustiveRuntime")))
(DFunDef false "plannedHelperBlock" (PWild PWild (PVar "name")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "internal error: unplanned-wasm-helper: ")) (EVar "name"))))
# MARK
(DUse false (UseGroup ("backend" "wasm_demand") ((mem "WasmDemandPlan" false) (mem "PlannedImport" false) (mem "helperOrder" false) (mem "hasWasmHelper" false) (mem "jsWireParam" false) (mem "jsWireResult" false) (mem "unaryF64Sig" false) (mem "binaryF64Sig" false))))
(DUse false (UseGroup ("backend" "wasm_demand") ((mem "JsImport" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "joinWith" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "injectiveIdent" false))))
(DTypeSig true "preambleHeadLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "preambleHeadLines" () (EListLit (ELit (LString ";; Medaka WasmGC backend (Stage 2.4c) — emitted WAT.")) (ELit (LString ";; Value rep: WASMGC-DESIGN.md §3 / §8.6.  W2 = scalar i32; W3 = (ref eq) + i31/structs.")) (ELit (LString "(module"))))
(DTypeSig true "importLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "importLines" () (EListLit (ELit (LString "  ;; ── §6 host-import IO seam (§10 fork e — custom import) ──")) (ELit (LString "  (import \"env\" \"mdk_write_int\" (func $mdk_write_int (param i32)))")) (ELit (LString "  (import \"env\" \"mdk_write_bool\" (func $mdk_write_bool (param i32)))"))))
(DTypeSig true "closTypeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "closTypeLines" () (EListLit (ELit (LString "    ;; ── §4 closure ABI (arity-in-struct, uniform code sig) ──")) (ELit (LString "    (type $argarr (array (mut (ref null eq))))")) (ELit (LString "    (type $codety (func (param (ref eq)) (param (ref $argarr)) (result (ref eq))))")) (ELit (LString "    (type $clos (sub (struct (field $code (ref $codety)) (field $arity i32) (field $env (ref $argarr)))))"))))
(DTypeSig true "closApplyLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "closApplyLines" () (EListLit (ELit (LString "  ;; ── §4 universal apply runtime (exact / under-PAP / over-saturate) ──")) (ELit (LString "  (func $mdk_pap (type $codety) (param $self (ref eq)) (param $args (ref $argarr)) (result (ref eq))")) (ELit (LString "    (local $c (ref $clos)) (local $env (ref $argarr)) (local $orig (ref eq))")) (ELit (LString "    (local $ne i32) (local $na i32) (local $total (ref $argarr)) (local $i i32)")) (ELit (LString "    (local.set $c (ref.cast (ref $clos) (local.get $self)))")) (ELit (LString "    (local.set $env (struct.get $clos $env (local.get $c)))")) (ELit (LString "    (local.set $orig (ref.as_non_null (array.get $argarr (local.get $env) (i32.const 0))))")) (ELit (LString "    (local.set $ne (i32.sub (array.len (local.get $env)) (i32.const 1)))")) (ELit (LString "    (local.set $na (array.len (local.get $args)))")) (ELit (LString "    (local.set $total (array.new $argarr (ref.null eq) (i32.add (local.get $ne) (local.get $na))))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $pd (loop $pl")) (ELit (LString "      (br_if $pd (i32.ge_s (local.get $i) (local.get $ne)))")) (ELit (LString "      (array.set $argarr (local.get $total) (local.get $i)")) (ELit (LString "        (array.get $argarr (local.get $env) (i32.add (local.get $i) (i32.const 1))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $pl)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $pd2 (loop $pl2")) (ELit (LString "      (br_if $pd2 (i32.ge_s (local.get $i) (local.get $na)))")) (ELit (LString "      (array.set $argarr (local.get $total) (i32.add (local.get $ne) (local.get $i))")) (ELit (LString "        (array.get $argarr (local.get $args) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $pl2)))")) (ELit (LString "    (return_call $__mdk_apply (local.get $orig) (local.get $total)))")) (ELit (LString "  (func $__mdk_apply (param $f (ref eq)) (param $args (ref $argarr)) (result (ref eq))")) (ELit (LString "    (local $c (ref $clos)) (local $ar i32) (local $na i32)")) (ELit (LString "    (local $sat (ref $argarr)) (local $surplus (ref $argarr)) (local $i i32) (local $r (ref eq))")) (ELit (LString "    (local $penv (ref $argarr))")) (ELit (LString "    (local.set $c (ref.cast (ref $clos) (local.get $f)))")) (ELit (LString "    (local.set $ar (struct.get $clos $arity (local.get $c)))")) (ELit (LString "    (local.set $na (array.len (local.get $args)))")) (ELit (LString "    (if (result (ref eq)) (i32.eq (local.get $na) (local.get $ar))")) (ELit (LString "      (then (return_call_ref $codety (local.get $f) (local.get $args) (struct.get $clos $code (local.get $c))))")) (ELit (LString "      (else")) (ELit (LString "        (if (result (ref eq)) (i32.lt_s (local.get $na) (local.get $ar))")) (ELit (LString "          (then")) (ELit (LString "            (local.set $penv (array.new $argarr (ref.null eq) (i32.add (local.get $na) (i32.const 1))))")) (ELit (LString "            (array.set $argarr (local.get $penv) (i32.const 0) (local.get $f))")) (ELit (LString "            (local.set $i (i32.const 0))")) (ELit (LString "            (block $ud (loop $ul")) (ELit (LString "              (br_if $ud (i32.ge_s (local.get $i) (local.get $na)))")) (ELit (LString "              (array.set $argarr (local.get $penv) (i32.add (local.get $i) (i32.const 1))")) (ELit (LString "                (array.get $argarr (local.get $args) (local.get $i)))")) (ELit (LString "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $ul)))")) (ELit (LString "            (struct.new $clos (ref.func $mdk_pap) (i32.sub (local.get $ar) (local.get $na)) (local.get $penv)))")) (ELit (LString "          (else")) (ELit (LString "            (local.set $sat (array.new $argarr (ref.null eq) (local.get $ar)))")) (ELit (LString "            (local.set $i (i32.const 0))")) (ELit (LString "            (block $sd (loop $sl")) (ELit (LString "              (br_if $sd (i32.ge_s (local.get $i) (local.get $ar)))")) (ELit (LString "              (array.set $argarr (local.get $sat) (local.get $i)")) (ELit (LString "                (array.get $argarr (local.get $args) (local.get $i)))")) (ELit (LString "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $sl)))")) (ELit (LString "            (local.set $r (call_ref $codety (local.get $f) (local.get $sat) (struct.get $clos $code (local.get $c))))")) (ELit (LString "            (local.set $surplus (array.new $argarr (ref.null eq) (i32.sub (local.get $na) (local.get $ar))))")) (ELit (LString "            (local.set $i (i32.const 0))")) (ELit (LString "            (block $od (loop $ol")) (ELit (LString "              (br_if $od (i32.ge_s (local.get $i) (i32.sub (local.get $na) (local.get $ar))))")) (ELit (LString "              (array.set $argarr (local.get $surplus) (local.get $i)")) (ELit (LString "                (array.get $argarr (local.get $args) (i32.add (local.get $i) (local.get $ar))))")) (ELit (LString "              (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $ol)))")) (ELit (LString "            (return_call $__mdk_apply (local.get $r) (local.get $surplus)))))))"))))
(DTypeSig true "preambleScalarLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "preambleScalarLines" () (EBinOp "++" (EBinOp "++" (EVar "preambleHeadLines") (EListLit (ELit (LString "  ;; ── §3 type section (one rec group, iso-recursive / nominal-modulo-canon) ──")) (ELit (LString "  ;; This program uses no ADTs — the scalar subset computes in raw i32 and only")) (ELit (LString "  ;; the print boundary is reached; the unitype scaffolding is declared unused.")) (ELit (LString "  (rec")) (ELit (LString "    ;; boxed Int outside the i31 range (§3.2) — declared, unused.")) (ELit (LString "    (type $boxint (sub (struct (field i64))))")) (ELit (LString "    ;; boxed Float (§3.3) — declared, unused until a Float fixture needs it.")) (ELit (LString "    (type $float (sub (struct (field f64))))")) (ELit (LString "  )")))) (EVar "importLines")))
(DTypeSig true "ioByteImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioByteImportLines" () (EListLit (ELit (LString "  ;; ── §6 host-import IO seam (§10 fork e — byte-level custom import) ──")) (ELit (LString "  (import \"env\" \"mdk_write_byte\" (func $mdk_write_byte (param i32)))"))))
(DTypeSig true "strTypeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strTypeLines" () (EListLit (ELit (LString "    ;; ── §3.3 String aggregate (UTF-8 bytes + cached codepoint count) ──")) (ELit (LString "    (type $u8arr (array (mut i8)))")) (ELit (LString "    (type $str (sub (struct (field $cp_count i32) (field $bytes (ref $u8arr)))))"))))
(DTypeSig true "ioRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioRuntimeLines" () (EListLit (ELit (LString "  ;; ── §2.1 Int representation seam: i31 fast path / $boxint i64 box ──")) (ELit (LString "  ;; layer-17 SOUNDNESS: Ints in [-2^30, 2^30) are i31ref immediates; outside that")) (ELit (LString "  ;; range they box into (struct (field i64)) ($boxint).  ALL Int arithmetic unboxes")) (ELit (LString "  ;; both operands to i64 via $mdk_unbox_int, computes in i64, and re-boxes via")) (ELit (LString "  ;; $mdk_box_int — so >2^30 values no longer truncate to 31 bits.")) (ELit (LString "  (func $mdk_unbox_int (param $v (ref eq)) (result i64)")) (ELit (LString "    (if (result i64) (ref.test (ref i31) (local.get $v))")) (ELit (LString "      (then (i64.extend_i32_s (i31.get_s (ref.cast (ref i31) (local.get $v)))))")) (ELit (LString "      (else (struct.get $boxint 0 (ref.cast (ref $boxint) (local.get $v))))))")) (ELit (LString "  ;; box an i64 Int: in [-2^30, 2^30) -> i31 immediate; else -> $boxint struct.")) (ELit (LString "  ;; An Int is 63-bit.  The sign-extend from bit 62 (the `(x << 1) >> 1` pair, which")) (ELit (LString "  ;; mirrors native's tag/untag and is a no-op on any 63-bit value) makes `every")) (ELit (LString "  ;; (ref eq) Int holds a 63-bit value` a representation invariant, so INT64_MIN is")) (ELit (LString "  ;; unreachable.  Arithmetic does not lean on it: `+ - * /` and negation are checked")) (ELit (LString "  ;; before they box ($mdk_int_add...).  It is the defined result only for the")) (ELit (LString "  ;; operations that discard high bits: shiftLeft drops the bits past bit 62, as")) (ELit (LString "  ;; native's retag does, and u64TruncateToInt keeps the low 63.  This is the SOLE")) (ELit (LString "  ;; producer of $boxint.")) (ELit (LString "  (func $mdk_box_int (param $n i64) (result (ref eq))")) (ELit (LString "    (local.set $n (i64.shr_s (i64.shl (local.get $n) (i64.const 1)) (i64.const 1)))")) (ELit (LString "    (if (result (ref eq))")) (ELit (LString "        (i32.and (i64.ge_s (local.get $n) (i64.const -1073741824))")) (ELit (LString "                 (i64.lt_s (local.get $n) (i64.const 1073741824)))")) (ELit (LString "      (then (ref.i31 (i32.wrap_i64 (local.get $n))))")) (ELit (LString "      (else (struct.new $boxint (local.get $n)))))")) (ELit (LString "  ;; ── §6 byte-write print runtime (decimal int / bool text) ──")) (ELit (LString "  ;; write the decimal digits of a NON-NEGATIVE i64 (most-significant first).")) (ELit (LString "  (func $mdk_write_digits (param $n i64)")) (ELit (LString "    (if (i64.ge_s (local.get $n) (i64.const 10))")) (ELit (LString "      (then (call $mdk_write_digits (i64.div_s (local.get $n) (i64.const 10)))))")) (ELit (LString "    (call $mdk_write_byte")) (ELit (LString "      (i32.add (i32.const 48)")) (ELit (LString "        (i32.wrap_i64 (i64.rem_s (local.get $n) (i64.const 10))))))")) (ELit (LString "  ;; render an i64 in decimal to stdout + a trailing newline (value-main Int).")) (ELit (LString "  (func $mdk_print_int (param $n i64)")) (ELit (LString "    (if (i64.lt_s (local.get $n) (i64.const 0))")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_byte (i32.const 45))")) (ELit (LString "        (call $mdk_write_digits (i64.sub (i64.const 0) (local.get $n))))")) (ELit (LString "      (else (call $mdk_write_digits (local.get $n))))")) (ELit (LString "    (call $mdk_write_byte (i32.const 10)))")) (ELit (LString "  (func $mdk_print_bool (param $b i32)")) (ELit (LString "    (if (local.get $b)")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_byte (i32.const 84)) (call $mdk_write_byte (i32.const 114))")) (ELit (LString "        (call $mdk_write_byte (i32.const 117)) (call $mdk_write_byte (i32.const 101)))")) (ELit (LString "      (else")) (ELit (LString "        (call $mdk_write_byte (i32.const 70)) (call $mdk_write_byte (i32.const 97))")) (ELit (LString "        (call $mdk_write_byte (i32.const 108)) (call $mdk_write_byte (i32.const 115))")) (ELit (LString "        (call $mdk_write_byte (i32.const 101))))")) (ELit (LString "    (call $mdk_write_byte (i32.const 10)))"))))
(DTypeSig true "ioStrRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioStrRuntimeLines" () (EListLit (ELit (LString "  ;; ── §6 string byte-write runtime ($str-dependent) ──")) (ELit (LString "  (func $mdk_print_str (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))")) (ELit (LString "  (func $mdk_print_strln (param $s (ref $str))")) (ELit (LString "    (call $mdk_print_str (local.get $s))")) (ELit (LString "    (call $mdk_write_byte (i32.const 10)))")) (ELit (LString "  ;; intToString : render an i64 in decimal into a fresh $str (cp_count == byte len).")) (ELit (LString "  (func $mdk_int_to_str (param $n i64) (result (ref $str))")) (ELit (LString "    (local $neg i32) (local $m i64) (local $len i32) (local $i i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $d i32)")) (ELit (LString "    (local.set $neg (i64.lt_s (local.get $n) (i64.const 0)))")) (ELit (LString "    (local.set $m (if (result i64) (local.get $neg)")) (ELit (LString "      (then (i64.sub (i64.const 0) (local.get $n))) (else (local.get $n))))")) (ELit (LString "    ;; count digits")) (ELit (LString "    (local.set $len (i32.const 1))")) (ELit (LString "    (block $cd (loop $cl")) (ELit (LString "      (br_if $cd (i64.lt_s (local.get $m) (i64.const 10)))")) (ELit (LString "      (local.set $len (i32.add (local.get $len) (i32.const 1)))")) (ELit (LString "      (local.set $m (i64.div_s (local.get $m) (i64.const 10)))")) (ELit (LString "      (br $cl)))")) (ELit (LString "    (local.set $m (if (result i64) (local.get $neg)")) (ELit (LString "      (then (i64.sub (i64.const 0) (local.get $n))) (else (local.get $n))))")) (ELit (LString "    (if (local.get $neg) (then (local.set $len (i32.add (local.get $len) (i32.const 1)))))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $len)))")) (ELit (LString "    ;; fill digits from least-significant (end) backward")) (ELit (LString "    (local.set $i (i32.sub (local.get $len) (i32.const 1)))")) (ELit (LString "    (block $fd (loop $fl")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i)")) (ELit (LString "        (i32.add (i32.const 48) (i32.wrap_i64 (i64.rem_s (local.get $m) (i64.const 10)))))")) (ELit (LString "      (local.set $m (i64.div_s (local.get $m) (i64.const 10)))")) (ELit (LString "      (local.set $i (i32.sub (local.get $i) (i32.const 1)))")) (ELit (LString "      (br_if $fd (i64.eq (local.get $m) (i64.const 0)))")) (ELit (LString "      (br $fl)))")) (ELit (LString "    (if (local.get $neg) (then (array.set $u8arr (local.get $buf) (i32.const 0) (i32.const 45))))")) (ELit (LString "    (struct.new $str (local.get $len) (local.get $buf)))"))))
(DTypeSig true "stderrByteImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "stderrByteImportLines" () (EListLit (ELit (LString "  (import \"env\" \"mdk_write_err_byte\" (func $mdk_write_err_byte (param i32)))"))))
(DTypeSig true "trapIntRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "trapIntRuntimeLines" () (EListLit (ELit (LString "  ;; -- #1787 numbered-trap decimal runtime (stderr, no newline) --")) (ELit (LString "  ;; write the decimal digits of a NON-NEGATIVE i64 (most-significant first).")) (ELit (LString "  (func $mdk_write_err_digits (param $n i64)")) (ELit (LString "    (if (i64.ge_s (local.get $n) (i64.const 10))")) (ELit (LString "      (then (call $mdk_write_err_digits (i64.div_s (local.get $n) (i64.const 10)))))")) (ELit (LString "    (call $mdk_write_err_byte")) (ELit (LString "      (i32.add (i32.const 48)")) (ELit (LString "        (i32.wrap_i64 (i64.rem_s (local.get $n) (i64.const 10))))))")) (ELit (LString "  ;; render an i64 in decimal to stderr, sign included, NO trailing newline.")) (ELit (LString "  (func $mdk_write_err_int (param $n i64)")) (ELit (LString "    (if (i64.lt_s (local.get $n) (i64.const 0))")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 45))")) (ELit (LString "        (call $mdk_write_err_digits (i64.sub (i64.const 0) (local.get $n))))")) (ELit (LString "      (else (call $mdk_write_err_digits (local.get $n)))))"))))
(DTypeSig true "siteRuntimeLines" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "siteRuntimeLines" ((PVar "files") (PVar "nonexh")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; -- located traps: `<file>:<line>:<col>: ` ahead of a trap line --")) (ELit (LString "  (func $mdk_write_err_loc (param $s i64)")) (ELit (LString "    (local $f i32)")) (ELit (LString "    (if (i64.ne (local.get $s) (i64.const 0))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $f (i32.wrap_i64 (i64.shr_u (local.get $s) (i64.const 44))))"))) (EApp (EApp (EDictApp "flatMap") (EVar "siteFileArmW")) (EApp (EApp (EVar "zipFilesW") (EVar "files")) (ELit (LInt 1))))) (EListLit (ELit (LString "        (call $mdk_write_err_byte (i32.const 58))")) (ELit (LString "        (call $mdk_write_err_int (i64.and (i64.shr_u (local.get $s) (i64.const 20)) (i64.const 16777215)))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 58))")) (ELit (LString "        (call $mdk_write_err_int (i64.and (local.get $s) (i64.const 1048575)))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 58))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 32))))")) (ELit (LString "  )")))) (EIf (EVar "nonexh") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  (func $mdk_trap_nonexh (param $s i64)")) (ELit (LString "    (call $mdk_write_err_loc (local.get $s))"))) (EApp (EVar "asciiTrapBytesW") (ELit (LString "runtime error [E-NONEXHAUSTIVE-MATCH]: non-exhaustive match\n")))) (EListLit (ELit (LString "    unreachable)")))) (EListLit))))
(DTypeSig false "zipFilesW" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "zipFilesW" ((PList) PWild) (EListLit))
(DFunDef false "zipFilesW" ((PCons (PVar "f") (PVar "fs")) (PVar "n")) (EBinOp "::" (ETuple (EVar "n") (EVar "f")) (EApp (EApp (EVar "zipFilesW") (EVar "fs")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "siteFileArmW" (TyFun (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "siteFileArmW" ((PTuple (PVar "n") (PVar "bytes"))) (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "        (if (i32.eq (local.get $f) (i32.const ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "))"))) (ELit (LString "          (then"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EBinOp "++" (EBinOp "++" (ELit (LString "            (call $mdk_write_err_byte (i32.const ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "b")))) (ELit (LString "))"))))) (EVar "bytes"))) (EListLit (ELit (LString "          ))")))))
(DTypeSig true "intRuntimeLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "intRuntimeLines" ((PVar "used")) (EBlock (DoLet false false (PVar "arith") (EApp (EApp (EVar "filterUsedW") (EVar "used")) (EListLit (ELit (LString "add")) (ELit (LString "sub")) (ELit (LString "mul")) (ELit (LString "div")) (ELit (LString "neg"))))) (DoLet false false (PVar "shifts") (EApp (EApp (EVar "filterUsedW") (EVar "used")) (EListLit (ELit (LString "left")) (ELit (LString "right"))))) (DoLet false false (PVar "core") (EMatch (EVar "arith") (arm (PList) () (EListLit)) (arm PWild () (EVar "intOverflowLines")))) (DoExpr (EBinOp "++" (EBinOp "++" (EVar "core") (EApp (EApp (EDictApp "flatMap") (EVar "checkedIntOpW")) (EVar "arith"))) (EApp (EApp (EDictApp "flatMap") (EVar "intShiftW")) (EVar "shifts"))))))
(DTypeSig false "filterUsedW" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterUsedW" (PWild (PList)) (EListLit))
(DFunDef false "filterUsedW" ((PVar "used") (PCons (PVar "n") (PVar "ns"))) (EIf (EApp (EApp (EVar "memberW") (EVar "n")) (EVar "used")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "filterUsedW") (EVar "used")) (EVar "ns"))) (EApp (EApp (EVar "filterUsedW") (EVar "used")) (EVar "ns"))))
(DTypeSig false "memberW" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "memberW" (PWild (PList)) (EVar "False"))
(DFunDef false "memberW" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "memberW") (EVar "x")) (EVar "ys"))))
(DTypeSig false "intOverflowLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "intOverflowLines" () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; -- #3377 checked Int arithmetic: E-INT-OVERFLOW instead of a wrap --")) (ELit (LString "  (func $mdk_int_operand (param $v i64)")) (ELit (LString "    (if (i64.lt_s (local.get $v) (i64.const 0))")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 40))")) (ELit (LString "        (call $mdk_write_err_int (local.get $v))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 41)))")) (ELit (LString "      (else (call $mdk_write_err_int (local.get $v)))))")) (ELit (LString "  (func $mdk_int_overflow (param $op i32) (param $a i64) (param $b i64) (param $s i64)")) (ELit (LString "    (call $mdk_write_err_loc (local.get $s))"))) (EApp (EVar "asciiTrapBytesW") (ELit (LString "runtime error [E-INT-OVERFLOW]: ")))) (EListLit (ELit (LString "    (if (i32.eqz (local.get $op))")) (ELit (LString "      (then")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 45))")) (ELit (LString "        (call $mdk_int_operand (local.get $a)))")) (ELit (LString "      (else")) (ELit (LString "        (call $mdk_int_operand (local.get $a))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 32))")) (ELit (LString "        (call $mdk_write_err_byte (local.get $op))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 32))")) (ELit (LString "        (call $mdk_int_operand (local.get $b))))")))) (EApp (EVar "asciiTrapBytesW") (ELit (LString " overflows Int\n")))) (EListLit (ELit (LString "        unreachable)")))))
(DTypeSig false "outOfIntRangeW" (TyCon "String"))
(DFunDef false "outOfIntRangeW" () (ELit (LString "(i64.ne (i64.shr_s (i64.shl (local.get $r) (i64.const 1)) (i64.const 1)) (local.get $r))")))
(DTypeSig false "overflowCallW" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "overflowCallW" ((PVar "code")) (EBinOp "++" (EBinOp "++" (ELit (LString "(call $mdk_int_overflow (i32.const ")) (EApp (EMethodRef "display") (EVar "code"))) (ELit (LString ") (local.get $a) (local.get $b) (local.get $s))"))))
(DTypeSig false "checkedIntOpW" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "checkedIntOpW" ((PLit (LString "neg"))) (EListLit (ELit (LString "  (func $mdk_int_neg (param $a i64) (result i64)")) (ELit (LString "    (local $r i64)")) (ELit (LString "    (local.set $r (i64.sub (i64.const 0) (local.get $a)))")) (EBinOp "++" (EBinOp "++" (ELit (LString "    (if ")) (EApp (EMethodRef "display") (EVar "outOfIntRangeW"))) (ELit (LString ""))) (ELit (LString "      (then (call $mdk_int_overflow (i32.const 0) (local.get $a) (i64.const 0) (i64.const 0))))")) (ELit (LString "    (local.get $r))"))))
(DFunDef false "checkedIntOpW" ((PLit (LString "mul"))) (EListLit (ELit (LString "  (func $mdk_int_mul (param $a i64) (param $b i64) (param $s i64) (result i64)")) (ELit (LString "    (local $r i64)")) (ELit (LString "    (local.set $r (i64.mul (local.get $a) (local.get $b)))")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    (if ")) (EApp (EMethodRef "display") (EVar "outOfIntRangeW"))) (ELit (LString " (then "))) (EApp (EMethodRef "display") (EApp (EVar "overflowCallW") (ELit (LString "42"))))) (ELit (LString "))"))) (ELit (LString "    (if (i64.ne (local.get $a) (i64.const 0))")) (ELit (LString "      (then")) (ELit (LString "        (if (i64.ne (i64.div_s (local.get $r) (local.get $a)) (local.get $b))")) (EBinOp "++" (EBinOp "++" (ELit (LString "          (then ")) (EApp (EMethodRef "display") (EApp (EVar "overflowCallW") (ELit (LString "42"))))) (ELit (LString "))))"))) (ELit (LString "    (local.get $r))"))))
(DFunDef false "checkedIntOpW" ((PLit (LString "add"))) (EApp (EApp (EApp (EVar "checkedBinOpLinesW") (ELit (LString "add"))) (ELit (LString "i64.add"))) (ELit (LString "43"))))
(DFunDef false "checkedIntOpW" ((PLit (LString "sub"))) (EApp (EApp (EApp (EVar "checkedBinOpLinesW") (ELit (LString "sub"))) (ELit (LString "i64.sub"))) (ELit (LString "45"))))
(DFunDef false "checkedIntOpW" ((PLit (LString "div"))) (EApp (EApp (EApp (EVar "checkedBinOpLinesW") (ELit (LString "div"))) (ELit (LString "i64.div_s"))) (ELit (LString "47"))))
(DFunDef false "checkedIntOpW" ((PVar "op")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "wasm: no checked Int operator '")) (EVar "op")) (ELit (LString "'")))))
(DTypeSig false "checkedBinOpLinesW" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "checkedBinOpLinesW" ((PVar "name") (PVar "instr") (PVar "code")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  (func $mdk_int_")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " (param $a i64) (param $b i64) (param $s i64) (result i64)"))) (ELit (LString "    (local $r i64)")) (EBinOp "++" (EBinOp "++" (ELit (LString "    (local.set $r (")) (EApp (EMethodRef "display") (EVar "instr"))) (ELit (LString " (local.get $a) (local.get $b)))"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    (if ")) (EApp (EMethodRef "display") (EVar "outOfIntRangeW"))) (ELit (LString " (then "))) (EApp (EMethodRef "display") (EApp (EVar "overflowCallW") (EVar "code")))) (ELit (LString "))"))) (ELit (LString "    (local.get $r))"))))
(DTypeSig false "intShiftW" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "intShiftW" ((PLit (LString "left"))) (EBinOp "++" (EApp (EApp (EVar "intShiftHeadW") (ELit (LString "left"))) (ELit (LString "shiftLeft"))) (EListLit (ELit (LString "    (select (i64.shl (local.get $x) (local.get $k)) (i64.const 0)")) (ELit (LString "      (i64.lt_s (local.get $k) (i64.const 63))))")))))
(DFunDef false "intShiftW" ((PLit (LString "right"))) (EBinOp "++" (EApp (EApp (EVar "intShiftHeadW") (ELit (LString "right"))) (ELit (LString "shiftRight"))) (EListLit (ELit (LString "    (i64.shr_s (local.get $x)")) (ELit (LString "      (select (local.get $k) (i64.const 63) (i64.lt_s (local.get $k) (i64.const 63)))))")))))
(DFunDef false "intShiftW" ((PVar "dir")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "wasm: no Int shift '")) (EVar "dir")) (ELit (LString "'")))))
(DTypeSig false "intShiftHeadW" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "intShiftHeadW" ((PVar "dir") (PVar "name")) (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "  (func $mdk_shift_")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString " (param $x i64) (param $k i64) (result i64)"))) (ELit (LString "    (if (i64.lt_s (local.get $k) (i64.const 0))")) (ELit (LString "      (then"))) (EApp (EVar "asciiTrapBytesW") (EBinOp "++" (EBinOp "++" (ELit (LString "runtime error [E-PANIC]: ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ": negative shift "))))) (EListLit (ELit (LString "        (call $mdk_write_err_int (local.get $k))")) (ELit (LString "        (call $mdk_write_err_byte (i32.const 10))")) (ELit (LString "        unreachable))")))))
(DTypeSig true "stderrRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "stderrRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 stderr byte-write runtime (ePutStr / ePutStrLn) ──")) (ELit (LString "  (func $mdk_eprint_str (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_err_byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))")) (ELit (LString "  (func $mdk_eprint_strln (param $s (ref $str))")) (ELit (LString "    (call $mdk_eprint_str (local.get $s))")) (ELit (LString "    (call $mdk_write_err_byte (i32.const 10)))"))))
(DTypeSig true "strLeafRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strLeafRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 string LEAF ops (byte-identical to medaka_rt.c) ──")) (ELit (LString "  ;; count UTF-8 codepoints in a $u8arr over [0,n): every non-continuation byte.")) (ELit (LString "  (func $mdk_cp_count (param $b (ref $u8arr)) (param $n i32) (result i32)")) (ELit (LString "    (local $i i32) (local $c i32) (local $byte i32)")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $c (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      ;; a continuation byte has top bits 10xxxxxx, i.e. (byte & 0xC0) == 0x80.")) (ELit (LString "      (if (i32.ne (i32.and (local.get $byte) (i32.const 192)) (i32.const 128))")) (ELit (LString "        (then (local.set $c (i32.add (local.get $c) (i32.const 1)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $c))")) (ELit (LString "  ;; codepoint index `cpi` -> byte offset into a $u8arr of byte length `n`.")) (ELit (LString "  (func $mdk_byte_off (param $b (ref $u8arr)) (param $n i32) (param $cpi i32) (result i32)")) (ELit (LString "    (local $bo i32) (local $c i32)")) (ELit (LString "    (local.set $bo (i32.const 0)) (local.set $c (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $bo) (local.get $n)))")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $c) (local.get $cpi)))")) (ELit (LString "      (local.set $bo (i32.add (local.get $bo) (i32.const 1)))")) (ELit (LString "      (block $sd (loop $sl")) (ELit (LString "        (br_if $sd (i32.ge_s (local.get $bo) (local.get $n)))")) (ELit (LString "        (br_if $sd (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (local.get $bo)) (i32.const 192)) (i32.const 128)))")) (ELit (LString "        (local.set $bo (i32.add (local.get $bo) (i32.const 1))) (br $sl)))")) (ELit (LString "      (local.set $c (i32.add (local.get $c) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $bo))")) (ELit (LString "  ;; binary string concat (`++`).  cp_count(a++b) == cp_count(a)+cp_count(b).")) (ELit (LString "  (func $mdk_str_append (param $a (ref $str)) (param $b (ref $str)) (result (ref $str))")) (ELit (LString "    (local $ab (ref $u8arr)) (local $bb (ref $u8arr)) (local $al i32) (local $bl i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $cpc i32)")) (ELit (LString "    (local.set $ab (struct.get $str $bytes (local.get $a)))")) (ELit (LString "    (local.set $bb (struct.get $str $bytes (local.get $b)))")) (ELit (LString "    (local.set $al (array.len (local.get $ab)))")) (ELit (LString "    (local.set $bl (array.len (local.get $bb)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (i32.add (local.get $al) (local.get $bl))))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $ab) (i32.const 0) (local.get $al))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (local.get $al) (local.get $bb) (i32.const 0) (local.get $bl))")) (ELit (LString "    (local.set $cpc (i32.add (struct.get $str $cp_count (local.get $a)) (struct.get $str $cp_count (local.get $b))))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))")) (ELit (LString "  ;; encode one Unicode codepoint to a fresh $str (1..4 UTF-8 bytes, cp_count 1).")) (ELit (LString "  (func $mdk_char_to_str (param $cp i32) (result (ref $str))")) (ELit (LString "    (local $buf (ref $u8arr))")) (ELit (LString "    (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 128))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 1)))")) (ELit (LString "        (array.set $u8arr (local.get $buf) (i32.const 0) (local.get $cp))")) (ELit (LString "        (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "      (else (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 2048))")) (ELit (LString "        (then")) (ELit (LString "          (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 2)))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "          (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "        (else (if (result (ref $str)) (i32.lt_u (local.get $cp) (i32.const 65536))")) (ELit (LString "          (then")) (ELit (LString "            (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 3)))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 2) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "          (else")) (ELit (LString "            (local.set $buf (array.new $u8arr (i32.const 0) (i32.const 4)))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 0) (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 1) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 2) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.const 3) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (struct.new $str (i32.const 1) (local.get $buf)))")) (ELit (LString "          )")) (ELit (LString "        )")) (ELit (LString "      )")) (ELit (LString "    )")) (ELit (LString "  ))")) (ELit (LString "  ;; codepoint-indexed [lo,hi) slice, clamped to [0,cp_count].")) (ELit (LString "  (func $mdk_str_slice (param $lo i32) (param $hi i32) (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $cpc i32) (local $blo i32) (local $bhi i32)")) (ELit (LString "    (local $len i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $cpc (struct.get $str $cp_count (local.get $s)))")) (ELit (LString "    (if (i32.lt_s (local.get $lo) (i32.const 0)) (then (local.set $lo (i32.const 0)))")) (ELit (LString "      (else (if (i32.gt_s (local.get $lo) (local.get $cpc)) (then (local.set $lo (local.get $cpc))))))")) (ELit (LString "    (if (i32.lt_s (local.get $hi) (local.get $lo)) (then (local.set $hi (local.get $lo)))")) (ELit (LString "      (else (if (i32.gt_s (local.get $hi) (local.get $cpc)) (then (local.set $hi (local.get $cpc))))))")) (ELit (LString "    (if (i32.eq (local.get $cpc) (local.get $n))")) (ELit (LString "      (then (local.set $blo (local.get $lo)) (local.set $bhi (local.get $hi)))")) (ELit (LString "      (else")) (ELit (LString "        (local.set $blo (call $mdk_byte_off (local.get $b) (local.get $n) (local.get $lo)))")) (ELit (LString "        (local.set $bhi (call $mdk_byte_off (local.get $b) (local.get $n) (local.get $hi)))))")) (ELit (LString "    (local.set $len (i32.sub (local.get $bhi) (local.get $blo)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $len)))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $b) (local.get $blo) (local.get $len))")) (ELit (LString "    (struct.new $str (i32.sub (local.get $hi) (local.get $lo)) (local.get $buf)))")) (ELit (LString "  ;; ASCII upper/lower over BYTES (non-ASCII bytes pass through unchanged).")) (ELit (LString "  (func $mdk_str_upper (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $c i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))")) (ELit (LString "        (then (local.set $c (i32.sub (local.get $c) (i32.const 32)))))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $c))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))")) (ELit (LString "  (func $mdk_str_lower (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $buf (ref $u8arr)) (local $i i32) (local $c i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))")) (ELit (LString "        (then (local.set $c (i32.add (local.get $c) (i32.const 32)))))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (local.get $c))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))")) (ELit (LString "  ;; ── W9 debug-literal quoting ──")) (ELit (LString "  ;; Map ONE source byte to its escaped form, appending into $buf at $bo; returns the")) (ELit (LString "  ;; next write offset.  Specials: \" / ' (whichever == $q) / \\ / \\n / \\t / \\r / NUL.")) (ELit (LString "  ;; All escapes are <backslash><ascii>, so 2 bytes; everything else copies verbatim.")) (ELit (LString "  (func $mdk_dbg_esc_byte (param $buf (ref $u8arr)) (param $bo i32) (param $c i32) (param $q i32) (result i32)")) (ELit (LString "    (local $r i32)")) (ELit (LString "    ;; $r = the char AFTER the backslash for an escaped byte, else -1 (copy verbatim).")) (ELit (LString "    (local.set $r (i32.const -1))")) (ELit (LString "    (if (i32.eq (local.get $c) (local.get $q)) (then (local.set $r (local.get $q))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 92)) (then (local.set $r (i32.const 92))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 10)) (then (local.set $r (i32.const 110))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 9))  (then (local.set $r (i32.const 116))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 13)) (then (local.set $r (i32.const 114))))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 0))  (then (local.set $r (i32.const 48))))")) (ELit (LString "    (if (result i32) (i32.eq (local.get $r) (i32.const -1))")) (ELit (LString "      (then")) (ELit (LString "        (array.set $u8arr (local.get $buf) (local.get $bo) (local.get $c))")) (ELit (LString "        (i32.add (local.get $bo) (i32.const 1)))")) (ELit (LString "      (else")) (ELit (LString "        (array.set $u8arr (local.get $buf) (local.get $bo) (i32.const 92))")) (ELit (LString "        (array.set $u8arr (local.get $buf) (i32.add (local.get $bo) (i32.const 1)) (local.get $r))")) (ELit (LString "        (i32.add (local.get $bo) (i32.const 2)))))")) (ELit (LString "  ;; Quote+escape a $str with quote byte $q ('\"' for String, ''' for Char).  Two-pass:")) (ELit (LString "  ;; count escaped output bytes, alloc exact, fill; cp_count via $mdk_cp_count.")) (ELit (LString "  (func $mdk_dbg_quote (param $s (ref $str)) (param $q i32) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $c i32)")) (ELit (LString "    (local $out i32) (local $buf (ref $u8arr)) (local $bo i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    ;; pass 1: total output bytes = 2 quotes + per-byte (2 if escaped else 1).")) (ELit (LString "    (local.set $out (i32.const 2)) (local.set $i (i32.const 0))")) (ELit (LString "    (block $d1 (loop $l1")) (ELit (LString "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.or (i32.or (i32.or (i32.eq (local.get $c) (local.get $q)) (i32.eq (local.get $c) (i32.const 92)))")) (ELit (LString "                          (i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 9))))")) (ELit (LString "                  (i32.or (i32.eq (local.get $c) (i32.const 13)) (i32.eq (local.get $c) (i32.const 0))))")) (ELit (LString "        (then (local.set $out (i32.add (local.get $out) (i32.const 2))))")) (ELit (LString "        (else (local.set $out (i32.add (local.get $out) (i32.const 1)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $out)))")) (ELit (LString "    ;; pass 2: opening quote, escaped bytes, closing quote.")) (ELit (LString "    (array.set $u8arr (local.get $buf) (i32.const 0) (local.get $q))")) (ELit (LString "    (local.set $bo (i32.const 1)) (local.set $i (i32.const 0))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $bo (call $mdk_dbg_esc_byte (local.get $buf) (local.get $bo) (local.get $c) (local.get $q)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))")) (ELit (LString "    (array.set $u8arr (local.get $buf) (local.get $bo) (local.get $q))")) (ELit (LString "    (struct.new $str (call $mdk_cp_count (local.get $buf) (local.get $out)) (local.get $buf)))")) (ELit (LString "  ;; debugStringLit : $str -> $str, surround with double-quotes (q = 34).")) (ELit (LString "  (func $mdk_debug_string_lit (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (call $mdk_dbg_quote (local.get $s) (i32.const 34)))")) (ELit (LString "  ;; debugCharLit : Char (i31 codepoint) -> $str, surround with single-quotes (q = 39).")) (ELit (LString "  (func $mdk_debug_char_lit (param $cp i32) (result (ref $str))")) (ELit (LString "    (call $mdk_dbg_quote (call $mdk_char_to_str (local.get $cp)) (i32.const 39)))")) (ELit (LString "  ;; -- W8c byte-level prefix/suffix (byte-identical to medaka_rt.c) --")) (ELit (LString "  ;; $mdk_bytes_match_at: does $nb occur in $hb at byte offset $off (caller bounds it).")) (ELit (LString "  (func $mdk_bytes_match_at (param $nb (ref $u8arr)) (param $hb (ref $u8arr)) (param $off i32) (result i32)")) (ELit (LString "    (local $j i32)")) (ELit (LString "    (block $done (loop $cmp")) (ELit (LString "      (br_if $done (i32.ge_s (local.get $j) (array.len (local.get $nb))))")) (ELit (LString "      (if (i32.ne (array.get_u $u8arr (local.get $hb) (i32.add (local.get $off) (local.get $j)))")) (ELit (LString "                  (array.get_u $u8arr (local.get $nb) (local.get $j)))")) (ELit (LString "        (then (return (i32.const 0))))")) (ELit (LString "      (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $cmp)))")) (ELit (LString "    (i32.const 1))")) (ELit (LString "  (func $mdk_str_starts_with (param $p (ref $str)) (param $s (ref $str)) (result i32)")) (ELit (LString "    (local $pb (ref $u8arr)) (local $sb (ref $u8arr))")) (ELit (LString "    (local.set $pb (struct.get $str $bytes (local.get $p)))")) (ELit (LString "    (local.set $sb (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (if (i32.gt_s (array.len (local.get $pb)) (array.len (local.get $sb)))")) (ELit (LString "      (then (return (i32.const 0))))")) (ELit (LString "    (call $mdk_bytes_match_at (local.get $pb) (local.get $sb) (i32.const 0)))")) (ELit (LString "  (func $mdk_str_ends_with (param $p (ref $str)) (param $s (ref $str)) (result i32)")) (ELit (LString "    (local $pb (ref $u8arr)) (local $sb (ref $u8arr))")) (ELit (LString "    (local.set $pb (struct.get $str $bytes (local.get $p)))")) (ELit (LString "    (local.set $sb (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (if (i32.gt_s (array.len (local.get $pb)) (array.len (local.get $sb)))")) (ELit (LString "      (then (return (i32.const 0))))")) (ELit (LString "    (call $mdk_bytes_match_at (local.get $pb) (local.get $sb)")) (ELit (LString "      (i32.sub (array.len (local.get $sb)) (array.len (local.get $pb)))))"))))
(DTypeSig true "strConcatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strConcatRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 stringConcat (List String) — walk the W7 cons list ──")) (ELit (LString "  (func $mdk_str_concat (param $list (ref eq)) (result (ref $str))")) (ELit (LString "    (local $w (ref eq)) (local $cell (ref $C_Cons)) (local $s (ref $str))")) (ELit (LString "    (local $total i32) (local $cpc i32) (local $off i32) (local $bl i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $sb (ref $u8arr))")) (ELit (LString "    ;; pass 1: total byte length + total codepoints.")) (ELit (LString "    (local.set $total (i32.const 0)) (local.set $cpc (i32.const 0))")) (ELit (LString "    (local.set $w (local.get $list))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))")) (ELit (LString "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))")) (ELit (LString "      (local.set $total (i32.add (local.get $total) (array.len (struct.get $str $bytes (local.get $s)))))")) (ELit (LString "      (local.set $cpc (i32.add (local.get $cpc) (struct.get $str $cp_count (local.get $s))))")) (ELit (LString "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l)))")) (ELit (LString "    ;; pass 2: copy each segment's bytes into a flat buffer.")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))")) (ELit (LString "    (local.set $off (i32.const 0))")) (ELit (LString "    (local.set $w (local.get $list))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))")) (ELit (LString "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))")) (ELit (LString "      (local.set $sb (struct.get $str $bytes (local.get $s)))")) (ELit (LString "      (local.set $bl (array.len (local.get $sb)))")) (ELit (LString "      (array.copy $u8arr $u8arr (local.get $buf) (local.get $off) (local.get $sb) (i32.const 0) (local.get $bl))")) (ELit (LString "      (local.set $off (i32.add (local.get $off) (local.get $bl)))")) (ELit (LString "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l2)))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))"))))
(DTypeSig true "strToIntRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strToIntRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8d stringToInt (decimal, optional sign; None on any other byte) ──")) (ELit (LString "  (func $mdk_str_to_int (param $s (ref $str)) (result (ref eq))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $c i32)")) (ELit (LString "    (local $neg i32) (local $seen i32) (local $acc i64) (local $d i64)")) (ELit (LString "    (local $limit i64) (local $acc2 i64)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (if (i32.eqz (local.get $n)) (then (return (ref.i31 (i32.const 1)))))")) (ELit (LString "    (local.set $c (array.get_u $u8arr (local.get $b) (i32.const 0)))")) (ELit (LString "    (if (i32.eq (local.get $c) (i32.const 45))")) (ELit (LString "      (then (local.set $neg (i32.const 1)) (local.set $i (i32.const 1)))")) (ELit (LString "      (else (if (i32.eq (local.get $c) (i32.const 43)) (then (local.set $i (i32.const 1))))))")) (ELit (LString "    (block $done (loop $step")) (ELit (LString "      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $c (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (if (i32.or (i32.lt_u (local.get $c) (i32.const 48)) (i32.gt_u (local.get $c) (i32.const 57)))")) (ELit (LString "        (then (return (ref.i31 (i32.const 1)))))")) (ELit (LString "      (local.set $d (i64.extend_i32_u (i32.sub (local.get $c) (i32.const 48))))")) (ELit (LString "      (local.set $limit")) (ELit (LString "        (if (result i64) (local.get $neg)")) (ELit (LString "          (then (i64.const -4611686018427387904))")) (ELit (LString "          (else (i64.const -4611686018427387903))))")) (ELit (LString "      (if (i64.lt_s (local.get $acc) (i64.div_s (local.get $limit) (i64.const 10)))")) (ELit (LString "        (then (return (ref.i31 (i32.const 1)))))")) (ELit (LString "      (local.set $acc2 (i64.mul (local.get $acc) (i64.const 10)))")) (ELit (LString "      (if (i64.lt_s (local.get $acc2) (i64.add (local.get $limit) (local.get $d)))")) (ELit (LString "        (then (return (ref.i31 (i32.const 1)))))")) (ELit (LString "      (local.set $acc (i64.sub (local.get $acc2) (local.get $d)))")) (ELit (LString "      (local.set $seen (i32.const 1))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1)))")) (ELit (LString "      (br $step)))")) (ELit (LString "    (if (i32.eqz (local.get $seen)) (then (return (ref.i31 (i32.const 1)))))")) (ELit (LString "    (struct.new $C_Some (i32.const 0)")) (ELit (LString "      (call $mdk_box_int")) (ELit (LString "        (if (result i64) (local.get $neg)")) (ELit (LString "          (then (local.get $acc))")) (ELit (LString "          (else (i64.sub (i64.const 0) (local.get $acc)))))))"))))
(DTypeSig true "strReverseRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strReverseRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8d stringReverse — copy each UTF-8 sequence whole, last first ──")) (ELit (LString "  (func $mdk_str_reverse (param $s (ref $str)) (result (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $buf (ref $u8arr)) (local $n i32)")) (ELit (LString "    (local $end i32) (local $start i32) (local $off i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $end (local.get $n))")) (ELit (LString "    (block $done (loop $step")) (ELit (LString "      (br_if $done (i32.eqz (local.get $end)))")) (ELit (LString "      (local.set $start (i32.sub (local.get $end) (i32.const 1)))")) (ELit (LString "      (block $lead (loop $back")) (ELit (LString "        (br_if $lead (i32.eqz (local.get $start)))")) (ELit (LString "        (br_if $lead (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (local.get $start)) (i32.const 192)) (i32.const 128)))")) (ELit (LString "        (local.set $start (i32.sub (local.get $start) (i32.const 1)))")) (ELit (LString "        (br $back)))")) (ELit (LString "      (array.copy $u8arr $u8arr (local.get $buf) (local.get $off)")) (ELit (LString "        (local.get $b) (local.get $start) (i32.sub (local.get $end) (local.get $start)))")) (ELit (LString "      (local.set $off (i32.add (local.get $off) (i32.sub (local.get $end) (local.get $start))))")) (ELit (LString "      (local.set $end (local.get $start))")) (ELit (LString "      (br $step)))")) (ELit (LString "    (struct.new $str (struct.get $str $cp_count (local.get $s)) (local.get $buf)))"))))
(DTypeSig true "strJoinRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strJoinRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8d stringJoin — two passes over the cons list, separator between pieces ──")) (ELit (LString "  (func $mdk_str_join (param $sep (ref $str)) (param $list (ref eq)) (result (ref $str))")) (ELit (LString "    (local $w (ref eq)) (local $cell (ref $C_Cons)) (local $s (ref $str))")) (ELit (LString "    (local $sepb (ref $u8arr)) (local $sb (ref $u8arr)) (local $buf (ref $u8arr))")) (ELit (LString "    (local $total i32) (local $cpc i32) (local $parts i32) (local $off i32)")) (ELit (LString "    (local $bl i32) (local $first i32)")) (ELit (LString "    (local.set $sepb (struct.get $str $bytes (local.get $sep)))")) (ELit (LString "    (local.set $w (local.get $list))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))")) (ELit (LString "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))")) (ELit (LString "      (local.set $total (i32.add (local.get $total) (array.len (struct.get $str $bytes (local.get $s)))))")) (ELit (LString "      (local.set $cpc (i32.add (local.get $cpc) (struct.get $str $cp_count (local.get $s))))")) (ELit (LString "      (local.set $parts (i32.add (local.get $parts) (i32.const 1)))")) (ELit (LString "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l)))")) (ELit (LString "    (if (i32.gt_s (local.get $parts) (i32.const 1))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $total (i32.add (local.get $total)")) (ELit (LString "          (i32.mul (i32.sub (local.get $parts) (i32.const 1)) (array.len (local.get $sepb)))))")) (ELit (LString "        (local.set $cpc (i32.add (local.get $cpc)")) (ELit (LString "          (i32.mul (i32.sub (local.get $parts) (i32.const 1)) (struct.get $str $cp_count (local.get $sep)))))))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))")) (ELit (LString "    (local.set $first (i32.const 1))")) (ELit (LString "    (local.set $w (local.get $list))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.eqz (ref.test (ref $C_Cons) (local.get $w))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $w)))")) (ELit (LString "      (if (i32.eqz (local.get $first))")) (ELit (LString "        (then")) (ELit (LString "          (array.copy $u8arr $u8arr (local.get $buf) (local.get $off)")) (ELit (LString "            (local.get $sepb) (i32.const 0) (array.len (local.get $sepb)))")) (ELit (LString "          (local.set $off (i32.add (local.get $off) (array.len (local.get $sepb))))))")) (ELit (LString "      (local.set $first (i32.const 0))")) (ELit (LString "      (local.set $s (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell))))")) (ELit (LString "      (local.set $sb (struct.get $str $bytes (local.get $s)))")) (ELit (LString "      (local.set $bl (array.len (local.get $sb)))")) (ELit (LString "      (array.copy $u8arr $u8arr (local.get $buf) (local.get $off) (local.get $sb) (i32.const 0) (local.get $bl))")) (ELit (LString "      (local.set $off (i32.add (local.get $off) (local.get $bl)))")) (ELit (LString "      (local.set $w (struct.get $C_Cons 2 (local.get $cell))) (br $l2)))")) (ELit (LString "    (struct.new $str (local.get $cpc) (local.get $buf)))"))))
(DTypeSig true "appendRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "appendRuntimeLines" () (EListLit (ELit (LString "  ;; ── W13 runtime-dispatched `++` (String concat OR List append) ──")) (ELit (LString "  ;; List append is ITERATIVE (destination-passing over the mut $C_Cons tail),")) (ELit (LString "  ;; mirroring the native mdk_list_append: walk `a` head-first, struct.new each")) (ELit (LString "  ;; result cell with a placeholder i31 tail, struct.set it into the previous")) (ELit (LString "  ;; cell's mut tail, and after the loop point the final tail at `b`.  O(1) extra")) (ELit (LString "  ;; space, no self-recursion → no wasm-stack growth proportional to length(a).")) (ELit (LString "  (func $mdk_append (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (local $cell (ref $C_Cons))")) (ELit (LString "    (local $result (ref eq))")) (ELit (LString "    (local $dest (ref $C_Cons))")) (ELit (LString "    (local $new (ref $C_Cons))")) (ELit (LString "    ;; String `++`: left is a $str struct → byte concat.")) (ELit (LString "    (if (ref.test (ref $str) (local.get $a))")) (ELit (LString "      (then (return (call $mdk_str_append (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b))))))")) (ELit (LString "    ;; List `++`: a Nil (non-$C_Cons) left → b unchanged.")) (ELit (LString "    (if (i32.eqz (ref.test (ref $C_Cons) (local.get $a)))")) (ELit (LString "      (then (return (local.get $b))))")) (ELit (LString "    ;; First cell: copy head(a), placeholder i31 tail (overwritten before any read).")) (ELit (LString "    (local.set $cell (ref.cast (ref $C_Cons) (local.get $a)))")) (ELit (LString "    (local.set $dest (struct.new $C_Cons (i32.const 0)")) (ELit (LString "      (struct.get $C_Cons 1 (local.get $cell)) (ref.i31 (i32.const 0))))")) (ELit (LString "    (local.set $result (local.get $dest))")) (ELit (LString "    ;; Walk the rest of `a`, appending a fresh cell into the previous mut tail.")) (ELit (LString "    (block $done")) (ELit (LString "      (loop $l")) (ELit (LString "        ;; If tail(cell) is not a Cons (i.e. Nil), we are done.")) (ELit (LString "        (br_if $done (i32.eqz (ref.test (ref $C_Cons)")) (ELit (LString "          (struct.get $C_Cons 2 (local.get $cell)))))")) (ELit (LString "        (local.set $cell (ref.cast (ref $C_Cons)")) (ELit (LString "          (struct.get $C_Cons 2 (local.get $cell))))")) (ELit (LString "        (local.set $new (struct.new $C_Cons (i32.const 0)")) (ELit (LString "          (struct.get $C_Cons 1 (local.get $cell)) (ref.i31 (i32.const 0))))")) (ELit (LString "        (struct.set $C_Cons 2 (local.get $dest) (local.get $new))")) (ELit (LString "        (local.set $dest (local.get $new))")) (ELit (LString "        (br $l)))")) (ELit (LString "    ;; Final tail → b (sharing it, not copying).")) (ELit (LString "    (struct.set $C_Cons 2 (local.get $dest) (local.get $b))")) (ELit (LString "    (local.get $result))"))))
(DData Public "Wide64W" () ((variant "Wide64W" (ConPos (TyCon "Bool") (TyCon "Bool")))) ())
(DTypeSig false "wideArmsW" (TyFun (TyCon "Wide64W") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "wideArmsW" ((PCon "Wide64W" (PVar "u64") (PVar "i64")) (PVar "arm")) (EBinOp "++" (EIf (EVar "u64") (EApp (EVar "arm") (ELit (LString "$u64"))) (EListLit)) (EIf (EVar "i64") (EApp (EVar "arm") (ELit (LString "$i64"))) (EListLit))))
(DTypeSig false "boxed64GetW" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "boxed64GetW" ((PVar "ty") (PVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(struct.get ")) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString " 0 (ref.cast (ref "))) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString ") (local.get "))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ")))"))))
(DTypeSig false "wideEqArmsW" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "wideEqArmsW" ((PVar "w")) (EApp (EApp (EVar "wideArmsW") (EVar "w")) (EVar "eqArmW")))
(DTypeSig false "eqArmW" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "eqArmW" ((PVar "ty")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (if (ref.test (ref ")) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString ") (local.get $a))"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "      (then (return (ref.i31 (i64.eq ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$a"))))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$b"))))) (ELit (LString ")))))")))))
(DTypeSig false "wideCmpArmsW" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "wideCmpArmsW" ((PVar "w")) (EApp (EApp (EVar "wideArmsW") (EVar "w")) (EVar "cmpArmW")))
(DTypeSig false "cmpArmW" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "cmpArmW" ((PVar "ty")) (EBlock (DoLet false false (PVar "sfx") (EIf (EBinOp "==" (EVar "ty") (ELit (LString "$u64"))) (ELit (LString "u")) (ELit (LString "s")))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (if (ref.test (ref ")) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString ") (local.get $a))"))) (ELit (LString "      (then")) (EBinOp "++" (EBinOp "++" (ELit (LString "        (local.set $ia ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$a"))))) (ELit (LString ")"))) (EBinOp "++" (EBinOp "++" (ELit (LString "        (local.set $ib ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$b"))))) (ELit (LString ")"))) (EBinOp "++" (EBinOp "++" (ELit (LString "        (if (i64.lt_")) (EApp (EMethodRef "display") (EVar "sfx"))) (ELit (LString " (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))"))) (EBinOp "++" (EBinOp "++" (ELit (LString "        (if (i64.gt_")) (EApp (EMethodRef "display") (EVar "sfx"))) (ELit (LString " (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))"))) (ELit (LString "        (return (i32.const 0))))"))))))
(DTypeSig false "wideArithArmsW" (TyFun (TyCon "Wide64W") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "wideArithArmsW" ((PVar "w") (PVar "instr")) (EApp (EApp (EVar "wideArmsW") (EVar "w")) (ELam ((PVar "ty")) (EApp (EApp (EVar "arithArmW") (EVar "ty")) (EVar "instr")))))
(DTypeSig false "arithArmW" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "arithArmW" ((PVar "ty") (PVar "instr")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (if (ref.test (ref ")) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString ") (local.get $a))"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "      (then (return (struct.new ")) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EVar "instr"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$a"))))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$b"))))) (ELit (LString ")))))")))))
(DTypeSig false "wideDivArmsW" (TyFun (TyCon "Wide64W") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "wideDivArmsW" ((PVar "w") (PVar "uInstr") (PVar "sInstr") (PVar "trap")) (EApp (EApp (EVar "wideArmsW") (EVar "w")) (ELam ((PVar "ty")) (EApp (EApp (EApp (EVar "divArmW") (EVar "ty")) (EIf (EBinOp "==" (EVar "ty") (ELit (LString "$u64"))) (EVar "uInstr") (EVar "sInstr"))) (EVar "trap")))))
(DTypeSig false "divArmW" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "divArmW" ((PVar "ty") (PVar "instr") (PVar "trap")) (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (if (ref.test (ref ")) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString ") (local.get $a))"))) (ELit (LString "      (then")) (EBinOp "++" (EBinOp "++" (ELit (LString "        (local.set $vdr ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$b"))))) (ELit (LString ")"))) (ELit (LString "        (if (i64.eqz (local.get $vdr)) (then"))) (EVar "trap")) (EListLit (ELit (LString "        ))")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "        (return (struct.new ")) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EVar "instr"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "boxed64GetW") (EVar "ty")) (ELit (LString "$a"))))) (ELit (LString " (local.get $vdr))))))"))))))
(DTypeSig true "i64RuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "i64RuntimeLines" () (EListLit (ELit (LString "  ;; -- I64 kernel: signed division that wraps at minBound / -1 --")) (ELit (LString "  (func $mdk_i64_div (param $a i64) (param $b i64) (result i64)")) (ELit (LString "    (if (i64.eq (local.get $b) (i64.const -1))")) (ELit (LString "      (then (return (i64.sub (i64.const 0) (local.get $a)))))")) (ELit (LString "    (i64.div_s (local.get $a) (local.get $b)))"))))
(DTypeSig true "u64RuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "u64RuntimeLines" () (EListLit (ELit (LString "  ;; -- U64 kernels: range-checked shifts and the high half of the product --")) (ELit (LString "  (func $mdk_u64_shl (param $x i64) (param $k i64) (result i64)")) (ELit (LString "    (select (i64.shl (local.get $x) (local.get $k)) (i64.const 0)")) (ELit (LString "      (i64.lt_u (local.get $k) (i64.const 64))))")) (ELit (LString "  (func $mdk_u64_shr (param $x i64) (param $k i64) (result i64)")) (ELit (LString "    (select (i64.shr_u (local.get $x) (local.get $k)) (i64.const 0)")) (ELit (LString "      (i64.lt_u (local.get $k) (i64.const 64))))")) (ELit (LString "  (func $mdk_u64_mulhi (param $a i64) (param $b i64) (result i64)")) (ELit (LString "    (local $al i64) (local $ah i64) (local $bl i64) (local $bh i64)")) (ELit (LString "    (local $lh i64) (local $hl i64) (local $mid i64)")) (ELit (LString "    (local.set $al (i64.and (local.get $a) (i64.const 0xFFFFFFFF)))")) (ELit (LString "    (local.set $ah (i64.shr_u (local.get $a) (i64.const 32)))")) (ELit (LString "    (local.set $bl (i64.and (local.get $b) (i64.const 0xFFFFFFFF)))")) (ELit (LString "    (local.set $bh (i64.shr_u (local.get $b) (i64.const 32)))")) (ELit (LString "    (local.set $lh (i64.mul (local.get $al) (local.get $bh)))")) (ELit (LString "    (local.set $hl (i64.mul (local.get $ah) (local.get $bl)))")) (ELit (LString "    (local.set $mid (i64.add (i64.add")) (ELit (LString "      (i64.shr_u (i64.mul (local.get $al) (local.get $bl)) (i64.const 32))")) (ELit (LString "      (i64.and (local.get $lh) (i64.const 0xFFFFFFFF)))")) (ELit (LString "      (i64.and (local.get $hl) (i64.const 0xFFFFFFFF))))")) (ELit (LString "    (i64.add (i64.add (i64.add")) (ELit (LString "      (i64.mul (local.get $ah) (local.get $bh))")) (ELit (LString "      (i64.shr_u (local.get $lh) (i64.const 32)))")) (ELit (LString "      (i64.shr_u (local.get $hl) (i64.const 32)))")) (ELit (LString "      (i64.shr_u (local.get $mid) (i64.const 32))))"))))
(DTypeSig true "valueEqRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueEqRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; -- layer-9 runtime-shape-dispatched `==`/`/=` (String byte-equal OR immediate identity) --")) (ELit (LString "  (func $mdk_value_eq (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    ;; both operands are $str structs -> byte equality.")) (ELit (LString "    (if (i32.and (ref.test (ref $str) (local.get $a)) (ref.test (ref $str) (local.get $b)))")) (ELit (LString "      (then (return (ref.i31 (i32.eq")) (ELit (LString "        (i32.const 1)")) (ELit (LString "        (i31.get_u (ref.cast (ref i31) (call $mdk_str_compare (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b)))))))))) ;; Eq == ordinal 1"))) (EApp (EVar "wideEqArmsW") (EVar "w"))) (EListLit (ELit (LString "    ;; A2 (poly-Eq-on-Float): two boxed $float cells have distinct identities, so the")) (ELit (LString "    ;; `ref.eq` fallback would report equal floats as unequal — compare f64 values.")) (ELit (LString "    (if (i32.and (ref.test (ref $float) (local.get $a)) (ref.test (ref $float) (local.get $b)))")) (ELit (LString "      (then (return (ref.i31 (f64.eq")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    ;; otherwise immediate/struct identity (i31 Int/Bool/Char/Unit, or ctor cells).")) (ELit (LString "    ;; layer-17 §2.1: a >2^30 Int is a $boxint struct, so two equal large Ints have")) (ELit (LString "    ;; distinct identities — when either side is a $boxint compare the unboxed i64.")) (ELit (LString "    (if (i32.or (ref.test (ref $boxint) (local.get $a)) (ref.test (ref $boxint) (local.get $b)))")) (ELit (LString "      (then (return (ref.i31 (i64.eq (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))))")) (ELit (LString "    (ref.i31 (i32.eqz (i32.eqz (ref.eq (local.get $a) (local.get $b))))))")) (ELit (LString "  ;; -- layer-9 runtime-shape-dispatched ordering (String byte-order OR i31 signed) -> i32 -1/0/1 --")) (ELit (LString "  (func $mdk_value_cmp (param $a (ref eq)) (param $b (ref eq)) (result i32)")) (ELit (LString "    (local $o i32) (local $ia i64) (local $ib i64) (local $fa f64) (local $fb f64)")) (ELit (LString "    (if (i32.and (ref.test (ref $str) (local.get $a)) (ref.test (ref $str) (local.get $b)))")) (ELit (LString "      (then")) (ELit (LString "        ;; $mdk_str_compare -> Ordering i31 (Lt 0 / Eq 1 / Gt 2); map to -1/0/1.")) (ELit (LString "        (local.set $o (i31.get_u (ref.cast (ref i31) (call $mdk_str_compare (ref.cast (ref $str) (local.get $a)) (ref.cast (ref $str) (local.get $b))))))")) (ELit (LString "        (return (i32.sub (local.get $o) (i32.const 1)))))")) (ELit (LString "    ;; A2 (poly-Ord-on-Float): a boxed $float operand -> f64 compare -> -1/0/1.")) (ELit (LString "    ;; Mirrors the arith helpers' left-operand $float discriminant.  A poly `Ord`")) (ELit (LString "    ;; compare (`a > b` on a Num/Ord type-var param) reaches here with $float cells;")) (ELit (LString "    ;; without this arm $mdk_unbox_int would ref.cast the $float to $boxint -> trap.")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))")) (ELit (LString "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))")) (ELit (LString "        (if (f64.lt (local.get $fa) (local.get $fb)) (then (return (i32.const -1))))")) (ELit (LString "        (if (f64.gt (local.get $fa) (local.get $fb)) (then (return (i32.const 1))))")) (ELit (LString "        (return (i32.const 0))))")))) (EApp (EVar "wideCmpArmsW") (EVar "w"))) (EListLit (ELit (LString "    ;; layer-17 §2.1: Int compare over the i64 box/unbox seam (handles >2^30 boxed).")) (ELit (LString "    (local.set $ia (call $mdk_unbox_int (local.get $a)))")) (ELit (LString "    (local.set $ib (call $mdk_unbox_int (local.get $b)))")) (ELit (LString "    (if (i64.lt_s (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))")) (ELit (LString "    (if (i64.gt_s (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))")) (ELit (LString "    (i32.const 0))")) (ELit (LString "  ;; -- #305 per-op IEEE relational predicates (Float f64 pred; else 3-way) --")) (ELit (LString "  (func $mdk_value_lt (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.lt")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.lt_s (call $mdk_value_cmp (local.get $a) (local.get $b)) (i32.const 0))))")) (ELit (LString "  (func $mdk_value_le (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.le")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.le_s (call $mdk_value_cmp (local.get $a) (local.get $b)) (i32.const 0))))")) (ELit (LString "  (func $mdk_value_gt (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.gt")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.gt_s (call $mdk_value_cmp (local.get $a) (local.get $b)) (i32.const 0))))")) (ELit (LString "  (func $mdk_value_ge (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.ge")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.ge_s (call $mdk_value_cmp (local.get $a) (local.get $b)) (i32.const 0))))")))))
(DTypeSig false "asciiTrapBytesW" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "asciiTrapBytesW" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "asciiTrapGoW") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "asciiTrapGoW" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "asciiTrapGoW" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EBinOp "::" (EBinOp "++" (ELit (LString "        i32.const ")) (EApp (EVar "intToString") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))) (EBinOp "::" (ELit (LString "        call $mdk_write_err_byte")) (EApp (EApp (EApp (EVar "asciiTrapGoW") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "valueDivZeroTrapW" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "valueDivZeroTrapW" () (EBinOp "++" (EApp (EVar "asciiTrapBytesW") (ELit (LString "runtime error [E-DIV-ZERO]: division by zero\n"))) (EListLit (ELit (LString "        unreachable")))))
(DTypeSig false "valueModZeroTrapW" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "valueModZeroTrapW" () (EBinOp "++" (EApp (EVar "asciiTrapBytesW") (ELit (LString "runtime error [E-MOD-ZERO]: modulo by zero\n"))) (EListLit (ELit (LString "        unreachable")))))
(DTypeSig true "valueAddRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueAddRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; -- A0 runtime value-tag-dispatched arithmetic (poly-`Num`: Int i31/$boxint OR $float) --")) (ELit (LString "  (func $mdk_value_add (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))"))) (EApp (EApp (EVar "wideArithArmsW") (EVar "w")) (ELit (LString "i64.add")))) (EListLit (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.add")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (call $mdk_int_add (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)) (i64.const 0))))))")))))
(DTypeSig true "valueSubRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueSubRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  (func $mdk_value_sub (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))"))) (EApp (EApp (EVar "wideArithArmsW") (EVar "w")) (ELit (LString "i64.sub")))) (EListLit (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.sub")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (call $mdk_int_sub (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)) (i64.const 0))))))")))))
(DTypeSig true "valueMulRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueMulRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  (func $mdk_value_mul (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))"))) (EApp (EApp (EVar "wideArithArmsW") (EVar "w")) (ELit (LString "i64.mul")))) (EListLit (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.mul")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else (call $mdk_box_int (call $mdk_int_mul (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)) (i64.const 0))))))")))))
(DTypeSig true "valueDivRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueDivRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; #371: int arm guards the divisor (mirrors emitDivZeroGuard's concrete-Int")) (ELit (LString "  ;; guard) — stash $b's unboxed value in $vdr, trap the coded [E-DIV-ZERO] line")) (ELit (LString "  ;; if zero, else the checked $mdk_int_div on the stashed value (unbox once, not twice).")) (ELit (LString "  (func $mdk_value_div (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (local $vdr i64)"))) (EApp (EApp (EApp (EApp (EVar "wideDivArmsW") (EVar "w")) (ELit (LString "i64.div_u"))) (ELit (LString "call $mdk_i64_div"))) (EVar "valueDivZeroTrapW"))) (EListLit (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (f64.div")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else")) (ELit (LString "        (local.set $vdr (call $mdk_unbox_int (local.get $b)))")) (ELit (LString "        (if (i64.eqz (local.get $vdr)) (then")))) (EVar "valueDivZeroTrapW")) (EListLit (ELit (LString "        ))")) (ELit (LString "        (call $mdk_box_int (call $mdk_int_div (call $mdk_unbox_int (local.get $a)) (local.get $vdr) (i64.const 0))))))")))))
(DTypeSig true "valueModRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueModRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; #345 Float arm is fmod ($mdk_float_rem), NOT the old inline `a - b*trunc(a/b)`")) (ELit (LString "  ;; (which lost precision for large |a/b|, e.g. 1e300 % 7 -> 1e300).  Mirrors native")) (ELit (LString "  ;; mdk_num_mod's fmod and the monomorphic Float `%` path (emitFloatBinRef).")) (ELit (LString "  ;; #371: int arm guards the divisor the same way as $mdk_value_div above.")) (ELit (LString "  (func $mdk_value_mod (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (local $vdr i64)"))) (EApp (EApp (EApp (EApp (EVar "wideDivArmsW") (EVar "w")) (ELit (LString "i64.rem_u"))) (ELit (LString "i64.rem_s"))) (EVar "valueModZeroTrapW"))) (EListLit (ELit (LString "    (if (result (ref eq)) (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (struct.new $float (call $mdk_float_rem")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))")) (ELit (LString "      (else")) (ELit (LString "        (local.set $vdr (call $mdk_unbox_int (local.get $b)))")) (ELit (LString "        (if (i64.eqz (local.get $vdr)) (then")))) (EVar "valueModZeroTrapW")) (EListLit (ELit (LString "        ))")) (ELit (LString "        (call $mdk_box_int (i64.rem_s (call $mdk_unbox_int (local.get $a)) (local.get $vdr))))))")))))
(DTypeSig true "valueCmpNumRuntimeLines" (TyFun (TyCon "Wide64W") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valueCmpNumRuntimeLines" ((PVar "w")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; -- A1 poly-`Ord`/`Eq`-on-Float, NUM-ONLY (no $str): $float f64-eq/cmp else i64 --")) (ELit (LString "  (func $mdk_value_eq_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))"))) (EApp (EVar "wideEqArmsW") (EVar "w"))) (EListLit (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.eq")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i64.eq (call $mdk_unbox_int (local.get $a)) (call $mdk_unbox_int (local.get $b)))))")) (ELit (LString "  (func $mdk_value_cmp_num (param $a (ref eq)) (param $b (ref eq)) (result i32)")) (ELit (LString "    (local $fa f64) (local $fb f64) (local $ia i64) (local $ib i64)")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then")) (ELit (LString "        (local.set $fa (struct.get $float 0 (ref.cast (ref $float) (local.get $a))))")) (ELit (LString "        (local.set $fb (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))")) (ELit (LString "        (if (f64.lt (local.get $fa) (local.get $fb)) (then (return (i32.const -1))))")) (ELit (LString "        (if (f64.gt (local.get $fa) (local.get $fb)) (then (return (i32.const 1))))")) (ELit (LString "        (return (i32.const 0))))")))) (EApp (EVar "wideCmpArmsW") (EVar "w"))) (EListLit (ELit (LString "    (local.set $ia (call $mdk_unbox_int (local.get $a)))")) (ELit (LString "    (local.set $ib (call $mdk_unbox_int (local.get $b)))")) (ELit (LString "    (if (i64.lt_s (local.get $ia) (local.get $ib)) (then (return (i32.const -1))))")) (ELit (LString "    (if (i64.gt_s (local.get $ia) (local.get $ib)) (then (return (i32.const 1))))")) (ELit (LString "    (i32.const 0))")) (ELit (LString "  (func $mdk_value_lt_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.lt")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.lt_s (call $mdk_value_cmp_num (local.get $a) (local.get $b)) (i32.const 0))))")) (ELit (LString "  (func $mdk_value_le_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.le")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.le_s (call $mdk_value_cmp_num (local.get $a) (local.get $b)) (i32.const 0))))")) (ELit (LString "  (func $mdk_value_gt_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.gt")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.gt_s (call $mdk_value_cmp_num (local.get $a) (local.get $b)) (i32.const 0))))")) (ELit (LString "  (func $mdk_value_ge_num (param $a (ref eq)) (param $b (ref eq)) (result (ref eq))")) (ELit (LString "    (if (ref.test (ref $float) (local.get $a))")) (ELit (LString "      (then (return (ref.i31 (f64.ge")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $a)))")) (ELit (LString "        (struct.get $float 0 (ref.cast (ref $float) (local.get $b))))))))")) (ELit (LString "    (ref.i31 (i32.ge_s (call $mdk_value_cmp_num (local.get $a) (local.get $b)) (i32.const 0))))")))))
(DTypeSig true "rngStateGlobalLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "rngStateGlobalLines" () (EListLit (ELit (LString "  (global $mdk_rng_state (mut i64) (i64.const 0))"))))
(DTypeSig true "rngRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "rngRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 SplitMix64 RNG (byte-identical to medaka_rt.c) ──")) (ELit (LString "  (func $mdk_next_u64 (result i64)")) (ELit (LString "    (local $z i64)")) (ELit (LString "    (global.set $mdk_rng_state (i64.add (global.get $mdk_rng_state) (i64.const 0x9E3779B97F4A7C15)))")) (ELit (LString "    (local.set $z (global.get $mdk_rng_state))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 30))) (i64.const 0xBF58476D1CE4E5B9)))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 27))) (i64.const 0x94D049BB133111EB)))")) (ELit (LString "    (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 31))))")) (ELit (LString "  ;; #179 randomInt lo hi : i64 lo/hi -> i64 in [lo,hi] (INCLUSIVE).  lo > hi -> lo.")) (ELit (LString "  ;; i64 (not i32): a range > 2^30 (e.g. randomInt 0 1000000000000000) overflows i32 —")) (ELit (LString "  ;; and the old ref.i31 box at the call site trapped `illegal cast` on the large draw.")) (ELit (LString "  ;; Byte-identical to native mdk_random_int: the span hi-lo+1 is read UNSIGNED, so")) (ELit (LString "  ;; the full Int range's 2^63 draws too (#3451); it is never 0 for 63-bit bounds.")) (ELit (LString "  (func $mdk_random_int (param $lo i64) (param $hi i64) (result i64)")) (ELit (LString "    (if (result i64) (i64.lt_s (local.get $hi) (local.get $lo))")) (ELit (LString "      (then (local.get $lo))")) (ELit (LString "      (else")) (ELit (LString "        (i64.add (local.get $lo)")) (ELit (LString "          (i64.rem_u (call $mdk_next_u64)")) (ELit (LString "            (i64.add (i64.sub (local.get $hi) (local.get $lo)) (i64.const 1)))))))")) (ELit (LString "  (func $mdk_random_bool (result i32)")) (ELit (LString "    (i32.wrap_i64 (i64.and (call $mdk_next_u64) (i64.const 1))))")) (ELit (LString "  (func $mdk_random_char (result i32)")) (ELit (LString "    (i32.add (i32.const 32) (i32.wrap_i64 (i64.rem_u (call $mdk_next_u64) (i64.const 95)))))"))))
(DTypeSig true "hashRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hashRuntimeLines" () (EListLit (ELit (LString "  ;; ── W8 per-type hashers (byte-identical to medaka_rt.c) ──")) (ELit (LString "  ;; SplitMix64 finalizer as a pure mixer (no state update).")) (ELit (LString "  (func $mdk_hash_mix64 (param $x i64) (result i64)")) (ELit (LString "    (local $z i64)")) (ELit (LString "    (local.set $z (i64.add (local.get $x) (i64.const 0x9E3779B97F4A7C15)))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 30))) (i64.const 0xBF58476D1CE4E5B9)))")) (ELit (LString "    (local.set $z (i64.mul (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 27))) (i64.const 0x94D049BB133111EB)))")) (ELit (LString "    (i64.xor (local.get $z) (i64.shr_u (local.get $z) (i64.const 31))))")) (ELit (LString "  ;; hashInt / hashChar : mix64(value) & 0x3FFFFFFF.  #199: `n` is the FULL-WIDTH i64")) (ELit (LString "  ;; value (hashInt unboxes via $mdk_unbox_int; hashChar sign-extends its i31 codepoint),")) (ELit (LString "  ;; matching medaka_rt.c's signed `tagged>>1` over the whole 63-bit int — so an Int key")) (ELit (LString "  ;; outside +-2^30 (e.g. a HashMap Int) hashes correctly instead of trapping the i31 cast.")) (ELit (LString "  (func $mdk_hash_int (param $n i64) (result i32)")) (ELit (LString "    (i32.wrap_i64 (i64.and (call $mdk_hash_mix64 (local.get $n)) (i64.const 0x3FFFFFFF))))")) (ELit (LString "  (func $mdk_hash_bool (param $b i32) (result i32)")) (ELit (LString "    (if (result i32) (local.get $b) (then (i32.const 1)) (else (i32.const 0))))"))))
(DTypeSig true "hashStringRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hashStringRuntimeLines" () (EListLit (ELit (LString "  ;; hashString : FNV-1a over UTF-8 BYTES, masked.")) (ELit (LString "  (func $mdk_hash_string (param $s (ref $str)) (result i32)")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $i i32) (local $h i64)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $h (i64.const 0xCBF29CE484222325))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $h (i64.mul (i64.xor (local.get $h) (i64.extend_i32_u (array.get_u $u8arr (local.get $b) (local.get $i)))) (i64.const 0x100000001B3)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (i32.wrap_i64 (i64.and (local.get $h) (i64.const 0x3FFFFFFF))))"))))
(DTypeSig true "charClassRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "charClassRuntimeLines" () (EListLit (ELit (LString "  ;; ── W11b ASCII char classification + case mapping (byte-identical to medaka_rt.c) ──")) (ELit (LString "  (func $mdk_char_is_alpha (param $c i32) (result i32)")) (ELit (LString "    (i32.or")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))))")) (ELit (LString "  (func $mdk_char_is_space (param $c i32) (result i32)")) (ELit (LString "    (i32.or")) (ELit (LString "      (i32.eq (local.get $c) (i32.const 32))")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 9)) (i32.le_u (local.get $c) (i32.const 13)))))")) (ELit (LString "  (func $mdk_char_is_upper (param $c i32) (result i32)")) (ELit (LString "    (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90))))")) (ELit (LString "  (func $mdk_char_is_lower (param $c i32) (result i32)")) (ELit (LString "    (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122))))")) (ELit (LString "  ;; charIsPunct: exact set from medaka_rt.c switch — Unicode Pc/Pd/Pe/Pf/Pi/Po/Ps ASCII.")) (ELit (LString "  ;; Included: ! \" # % & ' ( ) * , - . / : ; ? @ [ \\ ] _ { }")) (ELit (LString "  ;; Excluded ($+<=>^`|~): those are Unicode symbols (Sm/Sc/Sk), not punctuation.")) (ELit (LString "  ;; Right-associative OR chain over 23 chars = 22 i32.or nodes.")) (ELit (LString "  (func $mdk_char_is_punct (param $c i32) (result i32)")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 33))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 34))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 35))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 37))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 38))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 39))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 40))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 41))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 42))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 44))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 45))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 46))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 47))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 58))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 59))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 63))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 64))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 91))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 92))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 93))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 95))")) (ELit (LString "    (i32.or (i32.eq (local.get $c) (i32.const 123))")) (ELit (LString "           (i32.eq (local.get $c) (i32.const 125))")) (ELit (LString "    )))))))))))))))))))))))")) (ELit (LString "  (func $mdk_char_to_upper (param $c i32) (result i32)")) (ELit (LString "    (if (result i32)")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 97)) (i32.le_u (local.get $c) (i32.const 122)))")) (ELit (LString "      (then (i32.sub (local.get $c) (i32.const 32)))")) (ELit (LString "      (else (local.get $c))))")) (ELit (LString "  (func $mdk_char_to_lower (param $c i32) (result i32)")) (ELit (LString "    (if (result i32)")) (ELit (LString "      (i32.and (i32.ge_u (local.get $c) (i32.const 65)) (i32.le_u (local.get $c) (i32.const 90)))")) (ELit (LString "      (then (i32.add (local.get $c) (i32.const 32)))")) (ELit (LString "      (else (local.get $c))))"))))
(DTypeSig true "floatFmtImportLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatFmtImportLines" () (EListLit (ELit (LString "  ;; -- W8b floatToString host seam (shortest-round-trip since #57 — reproduced JS-side, see run.js) --")) (ELit (LString "  (import \"env\" \"mdk_float_fmt\" (func $mdk_float_fmt (param f64) (result i32)))")) (ELit (LString "  (import \"env\" \"mdk_float_fmt_byte\" (func $mdk_float_fmt_byte (param i32) (result i32)))"))))
(DTypeSig true "hostImportLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "hostImportLines" ((PList)) (EListLit))
(DFunDef false "hostImportLines" ((PCons (PVar "key") (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "stderrByteKey")) (EApp (EVar "hostImportLines") (EVar "rest")) (EBinOp "::" (EApp (EVar "hostImportLine") (EVar "key")) (EApp (EVar "hostImportLines") (EVar "rest")))))
(DTypeSig true "stderrByteKey" (TyCon "String"))
(DFunDef false "stderrByteKey" () (ELit (LString "mdk_write_err_byte")))
(DTypeSig false "hostImportLine" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "hostImportLine" ((PVar "key")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  (import \"env\" \"")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString "\" (func $"))) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "hostImportSig") (EVar "key")))) (ELit (LString "))"))))
(DTypeSig false "hostImportSig" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "hostImportSig" ((PVar "key")) (EMatch (EApp (EVar "hostImportSigOf") (EVar "key")) (arm (PCon "Some" (PVar "sig")) () (EVar "sig")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: host key ")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString " has no wasm import signature in wasm_preamble.mdk")))))))
(DTypeSig true "hostImportSigOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_exit"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_wall_time_sec"))) (EApp (EVar "Some") (ELit (LString " (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_monotonic_sec"))) (EApp (EVar "Some") (ELit (LString " (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_sleep_ms"))) (EApp (EVar "Some") (ELit (LString " (param i64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_fetch_text"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_cbrt"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_exp"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_log"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_log2"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_log10"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_sin"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_cos"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_tan"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_asin"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_acos"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_atan"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_sinh"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_cosh"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_tanh"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_pow"))) (EApp (EVar "Some") (EVar "binaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_atan2"))) (EApp (EVar "Some") (EVar "binaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_hypot"))) (EApp (EVar "Some") (EVar "binaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_path_reset"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_path_push"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_exists"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_get_env"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_line"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_all"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_exactly"))) (EApp (EVar "Some") (ELit (LString " (param i64) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_os_entropy"))) (EApp (EVar "Some") (ELit (LString " (param i64) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_executable_path"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_args_count"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_arg_len"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_arg_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32) (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_result_len"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_result_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_reset"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_push"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_commit"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_str_to_float"))) (EApp (EVar "Some") (ELit (LString " (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_str_to_float_ok"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_grant_reset"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_grant_push"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_canonicalize_path"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_append_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_make_dir"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_remove_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_remove_dir"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_fsync"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_mode"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_mode"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_rename"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_list_dir"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_stat_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_stat_field"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_bound_enter"))) (EApp (EVar "Some") (ELit (LString " (param i32) (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_bound_exit"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" (PWild) (EVar "None"))
(DTypeSig true "floatStrRuntimeLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "floatStrRuntimeLines" ((PVar "keys")) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_str_to_float"))) (EVar "keys")) (EVar "floatStrLines")))
(DTypeSig false "floatStrLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatStrLines" () (EListLit (ELit (LString "  ;; stringToFloat : $str -> Option Float (ref eq).")) (ELit (LString "  (func $mdk_string_to_float (param $s (ref $str)) (result (ref eq))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32) (local $d f64)")) (ELit (LString "    (call $mdk_path_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $done (loop $loop")) (ELit (LString "      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1)))")) (ELit (LString "      (br $loop)))")) (ELit (LString "    (local.set $d (call $mdk_str_to_float))")) (ELit (LString "    ;; #370: the host latched an ok flag during that call; ask it, rather than")) (ELit (LString "    ;; testing $d for NaN — strtod(\"nan\") legitimately yields Some(NaN), and")) (ELit (LString "    ;; strtod(\"\")/strtod(\"1.5 \") legitimately FAIL with a non-NaN value.")) (ELit (LString "    (if (result (ref eq)) (i32.eqz (call $mdk_str_to_float_ok))")) (ELit (LString "      (then (ref.i31 (i32.const 1)))")) (ELit (LString "      (else (struct.new $C_Some (i32.const 0) (struct.new $float (local.get $d)))))")) (ELit (LString "  )"))))
(DTypeSig true "floatRemRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatRemRuntimeLines" () (EListLit (ELit (LString "  (func $mdk_float_rem (param $a f64) (param $b f64) (result f64)")) (ELit (LString "    (local $x f64) (local $y f64) (local $t f64)")) (ELit (LString "    (local.set $y (f64.abs (local.get $b)))")) (ELit (LString "    (if (result f64)")) (ELit (LString "      (i32.or (i32.or")) (ELit (LString "        (f64.ne (f64.sub (local.get $a) (local.get $a)) (f64.const 0))")) (ELit (LString "        (f64.ne (local.get $b) (local.get $b)))")) (ELit (LString "        (f64.eq (local.get $y) (f64.const 0)))")) (ELit (LString "      ;; #672: the NaN result must carry the HOST's NaN SIGN, not WAT `nan`.  WAT")) (ELit (LString "      ;; `(f64.const nan)` is the FIXED canonical +NaN (0x7FF8..), but eval")) (ELit (LString "      ;; (`floatRem`=fmod) and native (`mdk_float_rem`=fmod) yield the host's NaN")) (ELit (LString "      ;; -- -NaN (0xFFF8..) on x86 -- and under the sign-dependent totalOrder (N6)")) (ELit (LString "      ;; a +NaN sorts/compares/hashes OPPOSITELY, so a fixed +NaN here made every")) (ELit (LString "      ;; `%`-NaN (e.g. `x % 0.0`) disagree with the other two engines on x86.")) (ELit (LString "      ;; `f64.div 0/0` is computed at RUNTIME by V8 (same as the `/` path), so it")) (ELit (LString "      ;; yields whatever NaN this box's hardware does -- matching eval/native and")) (ELit (LString "      ;; the wasm `f64.div` NaN on every platform (#509-safe: host-following, not")) (ELit (LString "      ;; a baked sign).")) (ELit (LString "      (then (f64.div (f64.const 0) (f64.const 0)))")) (ELit (LString "      (else")) (ELit (LString "        (local.set $x (f64.abs (local.get $a)))")) (ELit (LString "        (local.set $t (local.get $y))")) (ELit (LString "        (block $up (loop $ul")) (ELit (LString "          (br_if $up (f64.gt (f64.add (local.get $t) (local.get $t)) (local.get $x)))")) (ELit (LString "          (local.set $t (f64.add (local.get $t) (local.get $t)))")) (ELit (LString "          (br $ul)))")) (ELit (LString "        (block $dn (loop $dl")) (ELit (LString "          (if (f64.ge (local.get $x) (local.get $t))")) (ELit (LString "            (then (local.set $x (f64.sub (local.get $x) (local.get $t)))))")) (ELit (LString "          (br_if $dn (f64.eq (local.get $t) (local.get $y)))")) (ELit (LString "          (local.set $t (f64.mul (local.get $t) (f64.const 0.5)))")) (ELit (LString "          (br $dl)))")) (ELit (LString "        (f64.copysign (local.get $x) (local.get $a)))))"))))
(DTypeSig true "floatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "floatRuntimeLines" () (EListLit (ELit (LString "  ;; -- W8b Float runtime (byte-identical to medaka_rt.c) --")) (ELit (LString "  ;; intToFloat : i64 (full-width unboxed Int) -> boxed (struct $float).  #199: reads")) (ELit (LString "  ;; the arg through the $mdk_unbox_int seam so Ints outside +-2^30 no longer trap the")) (ELit (LString "  ;; i31 cast (e.g. intToFloat 4503599627370497).")) (ELit (LString "  (func $mdk_int_to_float (param $n i64) (result (ref $float))")) (ELit (LString "    (struct.new $float (f64.convert_i64_s (local.get $n))))")) (ELit (LString "  ;; floatToInt : boxed $float -> i64 (truncate toward zero).  #199: the i64 result")) (ELit (LString "  ;; reboxes via $mdk_box_int so a large truncation (|x| > 2^30, up to 2^53) no longer")) (ELit (LString "  ;; overflows i32 (`float unrepresentable in integer range`) nor traps ref.i31.")) (ELit (LString "  ;; #346/#372 (S0): SATURATES — NaN -> 0, +inf/over -> intMaxBound, -inf/under ->")) (ELit (LString "  ;; intMinBound.  The old bare i64.trunc_f64_s TRAPPED on NaN/inf/out-of-range (an")) (ELit (LString "  ;; uncoded engine trap: `float unrepresentable in integer range`, exit 1, no E-code),")) (ELit (LString "  ;; where native's fptosi was silent poison — so the three engines disagreed on exactly")) (ELit (LString "  ;; the inputs N7 says must be pinned.  trunc_sat alone is NOT enough: it saturates to")) (ELit (LString "  ;; *i64* bounds (+-2^63), which are OUTSIDE Medaka's 63-bit Int domain, and $mdk_box_int")) (ELit (LString "  ;; would renormalize that to -1/0 rather than the bound.  So clamp to the Int bounds")) (ELit (LString "  ;; ([-2^62, 2^62-1]) BEFORE returning to the box seam.  Matches llvm_emit's arm.")) (ELit (LString "  (func $mdk_float_to_int (param $f (ref $float)) (result i64)")) (ELit (LString "    (local $r i64)")) (ELit (LString "    (local.set $r (i64.trunc_sat_f64_s (struct.get $float 0 (local.get $f))))")) (ELit (LString "    (if (result i64) (i64.gt_s (local.get $r) (i64.const 4611686018427387903))")) (ELit (LString "      (then (i64.const 4611686018427387903))")) (ELit (LString "      (else (if (result i64) (i64.lt_s (local.get $r) (i64.const -4611686018427387904))")) (ELit (LString "        (then (i64.const -4611686018427387904))")) (ELit (LString "        (else (local.get $r))))))")) (ELit (LString "  ;; #101 round : C round() — round to nearest, HALVES AWAY FROM ZERO (NOT f64.nearest,")) (ELit (LString "  ;; which is round-half-to-even).  Branch-based so there is NO intermediate `x+0.5`:")) (ELit (LString "  ;; the naive `floor(abs(x)+0.5)` double-rounds — `x+0.5` itself rounds (IEEE) before")) (ELit (LString "  ;; the floor, so round(0.49999999999999994)->1 (should be 0) and every odd-integer")) (ELit (LString "  ;; double in [2^52,2^53) (an exact `x+0.5` tie -> half-to-even picks x+1) came back")) (ELit (LString "  ;; off-by-one.  Here we floor/ceil FIRST, then compare the exact fractional distance")) (ELit (LString "  ;; to 0.5.  Byte-identical to native mdk_round (== C round(), medaka_rt.c) for all")) (ELit (LString "  ;; finite inputs (an already-integral x has fraction 0 < 0.5 -> returned unchanged).")) (ELit (LString "  (func $mdk_round (param $x f64) (result f64)")) (ELit (LString "    (local $t f64)")) (ELit (LString "    (if (result f64) (f64.ge (local.get $x) (f64.const 0.0))")) (ELit (LString "      (then (local.set $t (f64.floor (local.get $x)))")) (ELit (LString "        (if (result f64) (f64.ge (f64.sub (local.get $x) (local.get $t)) (f64.const 0.5))")) (ELit (LString "          (then (f64.add (local.get $t) (f64.const 1.0))) (else (local.get $t))))")) (ELit (LString "      (else (local.set $t (f64.ceil (local.get $x)))")) (ELit (LString "        (if (result f64) (f64.ge (f64.sub (local.get $t) (local.get $x)) (f64.const 0.5))")) (ELit (LString "          (then (f64.sub (local.get $t) (f64.const 1.0))) (else (local.get $t))))))")) (ELit (LString "  ;; floatToString : the host formats (shortest-round-trip since #57, + .0 rule)")) (ELit (LString "  ;; into a cache; copy the bytes into a fresh $str.  cp_count == byte_len (ASCII).")) (ELit (LString "  (func $mdk_float_to_str (param $d f64) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (call $mdk_float_fmt (local.get $d)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (call $mdk_float_fmt_byte (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (struct.new $str (local.get $n) (local.get $buf)))"))))
(DTypeSig true "hashFloatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "hashFloatRuntimeLines" () (EListLit (ELit (LString "  ;; hashFloat (#758): normalise -0.0 -> +0.0 and every NaN -> one qNaN bit")) (ELit (LString "  ;; pattern, then reinterpret bits as i64 -> mix64 -> mask [0,2^30).  Matches")) (ELit (LString "  ;; mdk_hash_float (native) and pHashFloat (eval), or run /= build reappears.")) (ELit (LString "  (func $mdk_hash_float (param $f (ref $float)) (result i32)")) (ELit (LString "    (local $d f64) (local $bits i64)")) (ELit (LString "    (local.set $d (struct.get $float 0 (local.get $f)))")) (ELit (LString "    (if (f64.eq (local.get $d) (f64.const 0))")) (ELit (LString "      (then (local.set $bits (i64.const 0)))")) (ELit (LString "      (else")) (ELit (LString "        (if (f64.ne (local.get $d) (local.get $d))")) (ELit (LString "          (then (local.set $bits (i64.const 0x7FF8000000000000)))")) (ELit (LString "          (else (local.set $bits (i64.reinterpret_f64 (local.get $d)))))))")) (ELit (LString "    (i32.wrap_i64 (i64.and (call $mdk_hash_mix64 (local.get $bits)) (i64.const 0x3FFFFFFF))))"))))
(DTypeSig true "randomFloatRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "randomFloatRuntimeLines" () (EListLit (ELit (LString "  ;; randomFloat : SplitMix64 -> f64 in [-1,1) (NOTE the -1 offset — see medaka_rt.c).")) (ELit (LString "  (func $mdk_random_float (result (ref $float))")) (ELit (LString "    (struct.new $float")) (ELit (LString "      (f64.sub")) (ELit (LString "        (f64.mul")) (ELit (LString "          (f64.mul (f64.convert_i64_u (i64.shr_u (call $mdk_next_u64) (i64.const 11)))")) (ELit (LString "                   (f64.const 1.1102230246251565e-16))")) (ELit (LString "          (f64.const 2.0))")) (ELit (LString "        (f64.const 1.0))))"))))
(DTypeSig false "notUtf8SuffixWat" (TyCon "String"))
(DFunDef false "notUtf8SuffixWat" () (EApp (EVar "asciiU8arrWat") (ELit (LString ": not valid UTF-8 (use readFileBytes for raw bytes)"))))
(DTypeSig false "asciiU8arrWat" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "asciiU8arrWat" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(array.new_fixed $u8arr ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "arrayLength") (EVar "cs"))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "asciiConstsW") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))) (ELit (LString ")"))))))
(DTypeSig false "asciiConstsW" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "asciiConstsW" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (i32.const ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")))))) (ELit (LString ")"))) (EApp (EApp (EApp (EVar "asciiConstsW") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig true "ioHostRuntimeLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ioHostRuntimeLines" ((PVar "keys")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_path_push"))) (EVar "keys")) (EVar "ioPushPathLines")) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_rename"))) (EVar "keys")) (EVar "ioPushPathMoreLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_grant_push"))) (EVar "keys")) (EVar "ioPushGrantLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_rename"))) (EVar "keys")) (EVar "ioPushGrantMoreLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_result_len"))) (EVar "keys")) (EVar "ioResultLines"))) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (ELit (LString "mdk_file_exists"))) (EVar "keys")) (EApp (EApp (EVar "contains") (ELit (LString "mdk_canonicalize_path"))) (EVar "keys"))) (EApp (EApp (EVar "contains") (ELit (LString "mdk_os_entropy"))) (EVar "keys"))) (EVar "ioRefusedPanicLines") (EListLit))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_read_file"))) (EVar "keys")) (EVar "ioReadFileLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_fetch_text"))) (EVar "keys")) (EVar "ioFetchTextLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_file_exists"))) (EVar "keys")) (EVar "ioFileExistsLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_canonicalize_path"))) (EVar "keys")) (EVar "ioCanonicalizeLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_write_file"))) (EVar "keys")) (EVar "ioWriteFileLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_append_file"))) (EVar "keys")) (EVar "ioAppendFileLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_rename"))) (EVar "keys")) (EVar "ioRenameLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_list_dir"))) (EVar "keys")) (EVar "ioListDirLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_stat_file"))) (EVar "keys")) (EVar "ioStatFileLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_make_dir"))) (EVar "keys")) (EVar "ioMakeDirLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_remove_file"))) (EVar "keys")) (EVar "ioRemoveFileLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_remove_dir"))) (EVar "keys")) (EVar "ioRemoveDirLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_fsync"))) (EVar "keys")) (EVar "ioFsyncLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_file_mode"))) (EVar "keys")) (EVar "ioFileModeLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_write_file_mode"))) (EVar "keys")) (EVar "ioWriteFileModeLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_get_env"))) (EVar "keys")) (EVar "ioGetEnvLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_read_line"))) (EVar "keys")) (EVar "ioReadLineLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_read_all"))) (EVar "keys")) (EVar "ioReadAllLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_read_exactly"))) (EVar "keys")) (EVar "ioReadExactlyLines"))) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_executable_path"))) (EVar "keys")) (EVar "ioExecutablePathLines"))))
(DTypeSig false "gatedOn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "gatedOn" ((PVar "key") (PVar "keys") (PVar "block")) (EIf (EApp (EApp (EVar "contains") (EVar "key")) (EVar "keys")) (EVar "block") (EListLit)))
(DTypeSig false "ioPushPathLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioPushPathLines" () (EListLit (ELit (LString "  ;; push a $str's bytes to the host path buffer (reset first).")) (ELit (LString "  (func $mdk_push_path (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (call $mdk_path_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    )"))))
(DTypeSig false "ioPushPathMoreLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioPushPathMoreLines" () (EListLit (ELit (LString "  ;; append a $str's bytes to the host path buffer (rename's second path).")) (ELit (LString "  (func $mdk_push_path_more (param $s (ref $str))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_path_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    )"))))
(DTypeSig false "ioPushGrantLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioPushGrantLines" () (EListLit (ELit (LString "  ;; push a grant (List String) to the host grant buffer (reset first).")) (ELit (LString "  (func $mdk_push_grant (param $g (ref eq))")) (ELit (LString "    (local $cell (ref $C_Cons)) (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (call $mdk_grant_reset)")) (ELit (LString "    (block $done (loop $next")) (ELit (LString "      (br_if $done (i32.eqz (ref.test (ref $C_Cons) (local.get $g))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $g)))")) (ELit (LString "      (local.set $b (struct.get $str $bytes (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell)))))")) (ELit (LString "      (local.set $n (array.len (local.get $b)))")) (ELit (LString "      (local.set $i (i32.const 0))")) (ELit (LString "      (block $d (loop $l")) (ELit (LString "        (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "        (call $mdk_grant_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "        (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "      (call $mdk_grant_push (i32.const -1))")) (ELit (LString "      (local.set $g (struct.get $C_Cons 2 (local.get $cell))) (br $next)))")) (ELit (LString "    )"))))
(DTypeSig false "ioPushGrantMoreLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioPushGrantMoreLines" () (EListLit (ELit (LString "  ;; append a grant to the host grant buffer (rename's second grant).")) (ELit (LString "  (func $mdk_push_grant_more (param $g (ref eq))")) (ELit (LString "    (local $cell (ref $C_Cons)) (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (block $done (loop $next")) (ELit (LString "      (br_if $done (i32.eqz (ref.test (ref $C_Cons) (local.get $g))))")) (ELit (LString "      (local.set $cell (ref.cast (ref $C_Cons) (local.get $g)))")) (ELit (LString "      (local.set $b (struct.get $str $bytes (ref.cast (ref $str) (struct.get $C_Cons 1 (local.get $cell)))))")) (ELit (LString "      (local.set $n (array.len (local.get $b)))")) (ELit (LString "      (local.set $i (i32.const 0))")) (ELit (LString "      (block $d (loop $l")) (ELit (LString "        (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "        (call $mdk_grant_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "        (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "      (call $mdk_grant_push (i32.const -1))")) (ELit (LString "      (local.set $g (struct.get $C_Cons 2 (local.get $cell))) (br $next)))")) (ELit (LString "    )"))))
(DTypeSig false "ioRefusedPanicLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioRefusedPanicLines" () (EListLit (ELit (LString "  ;; the host's refusal message (result channel) as an E-PANIC line, then trap.")) (ELit (LString "  (func $mdk_refused_panic")) (EBinOp "++" (EBinOp "++" (ELit (LString "    (call $mdk_err_u8arr ")) (EApp (EMethodRef "display") (EVar "panicBannerWat"))) (ELit (LString ")"))) (ELit (LString "    (call $mdk_err_u8arr (call $mdk_io_result_bytes))")) (ELit (LString "    (call $mdk_write_err_byte (i32.const 10))")) (ELit (LString "    (unreachable))")) (ELit (LString "  (func $mdk_err_u8arr (param $b (ref $u8arr))")) (ELit (LString "    (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_err_byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    )"))))
(DTypeSig false "panicBannerWat" (TyCon "String"))
(DFunDef false "panicBannerWat" () (EApp (EVar "asciiU8arrWat") (ELit (LString "runtime error [E-PANIC]: "))))
(DTypeSig false "ioResultLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioResultLines" () (EListLit (ELit (LString "  ;; copy the host result buffer (length + byte-at-index) into a fresh $u8arr.")) (ELit (LString "  (func $mdk_io_result_bytes (result (ref $u8arr))")) (ELit (LString "    (local $n i32) (local $i i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (call $mdk_result_len))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i) (call $mdk_result_byte (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $buf))")) (ELit (LString "  ;; the host result buffer as a $str, read as UTF-8 by $mdk_u8_to_str_lossy.")) (ELit (LString "  (func $mdk_io_result_to_str (result (ref $str))")) (ELit (LString "    (call $mdk_u8_to_str_lossy (call $mdk_io_result_bytes)))"))))
(DTypeSig true "jsffiImportLines" (TyFun (TyApp (TyCon "List") (TyCon "JsImport")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "jsffiImportLines" ((PVar "imps")) (EApp (EApp (EMethodRef "map") (EVar "jsffiImportLine")) (EVar "imps")))
(DTypeSig false "jsffiImportLine" (TyFun (TyCon "JsImport") (TyCon "String")))
(DFunDef false "jsffiImportLine" ((PVar "imp")) (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (EVar "jsWireParam")) (EFieldAccess (EVar "imp") "params")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  (import \"jsffi\" \"")) (EApp (EMethodRef "display") (EApp (EVar "jsImportField") (EVar "imp")))) (ELit (LString "\" (func $"))) (EApp (EMethodRef "display") (EApp (EVar "jsffiImportId") (EFieldAccess (EVar "imp") "medakaName")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "params"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "jsWireResult") (EFieldAccess (EVar "imp") "result")))) (ELit (LString "))"))))))
(DTypeSig true "jsffiImportId" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "jsffiImportId" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "jsffi.import.")) (EApp (EMethodRef "display") (EApp (EVar "injectiveIdent") (EVar "name")))) (ELit (LString ""))))
(DTypeSig true "jsffiWrapperId" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "jsffiWrapperId" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "jsffi.wrap.")) (EApp (EMethodRef "display") (EApp (EVar "injectiveIdent") (EVar "name")))) (ELit (LString ""))))
(DTypeSig true "jsImportField" (TyFun (TyCon "JsImport") (TyCon "String")))
(DFunDef false "jsImportField" ((PVar "imp")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "imp") "jsName"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EFieldAccess (EVar "imp") "params")))) (ELit (LString "->"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "imp") "result"))) (ELit (LString ""))))
(DTypeSig false "jsWireTy" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "jsWireTy" ((PLit (LString "Int"))) (ELit (LString "i64")))
(DFunDef false "jsWireTy" ((PLit (LString "U64"))) (ELit (LString "i64")))
(DFunDef false "jsWireTy" ((PLit (LString "I64"))) (ELit (LString "i64")))
(DFunDef false "jsWireTy" ((PLit (LString "Float"))) (ELit (LString "f64")))
(DFunDef false "jsWireTy" (PWild) (ELit (LString "i32")))
(DTypeSig false "isChannelHead" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isChannelHead" ((PVar "head")) (EBinOp "||" (EBinOp "==" (EVar "head") (ELit (LString "String"))) (EBinOp "==" (EVar "head") (ELit (LString "Array")))))
(DTypeSig true "jsCrossableHead" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "jsCrossableHead" ((PVar "head")) (EApp (EApp (EVar "contains") (EVar "head")) (EListLit (ELit (LString "Int")) (ELit (LString "Float")) (ELit (LString "Bool")) (ELit (LString "Char")) (ELit (LString "String")) (ELit (LString "Array")) (ELit (LString "Unit")) (ELit (LString "U8")) (ELit (LString "U16")) (ELit (LString "U32")) (ELit (LString "I32")) (ELit (LString "U64")) (ELit (LString "I64")))))
(DTypeSig true "jsffiWrapperLines" (TyFun (TyCon "JsImport") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "jsffiWrapperLines" ((PVar "imp") (PVar "intTrap") (PVar "charTrap") (PVar "copyTrap")) (EBlock (DoLet false false (PVar "ps") (EApp (EApp (EVar "zipHeads") (EFieldAccess (EVar "imp") "params")) (ELit (LInt 0)))) (DoLet false false (PVar "params") (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EBinOp "++" (EBinOp "++" (ELit (LString " (param $p")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "snd") (EVar "p"))))) (ELit (LString " (ref eq))"))))) (EVar "ps")))) (DoLet false false (PVar "held") (EBinOp "/=" (EApp (EVar "jsWireResult") (EFieldAccess (EVar "imp") "result")) (ELit (LString "")))) (DoLet false false (PVar "rLocal") (EIf (EVar "held") (EBinOp "++" (EBinOp "++" (ELit (LString " (local $r ")) (EApp (EMethodRef "display") (EApp (EVar "jsWireTy") (EFieldAccess (EVar "imp") "result")))) (ELit (LString ")"))) (ELit (LString "")))) (DoLet false false (PVar "push") (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EApp (EVar "isChannelHead") (EApp (EVar "fst") (EVar "p"))))) (EVar "ps")) (EBinOp "::" (ELit (LString "    (call $mdk_path_reset)")) (EApp (EApp (EDictApp "flatMap") (EVar "jsPushArg")) (EVar "ps"))) (EListLit))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  (func $")) (EApp (EMethodRef "display") (EApp (EVar "jsffiWrapperId") (EFieldAccess (EVar "imp") "medakaName")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "params"))) (ELit (LString " (result (ref eq))"))) (EBinOp "++" (EBinOp "++" (ELit (LString "    (local $off i32)")) (EApp (EMethodRef "display") (EVar "rLocal"))) (ELit (LString "")))) (EVar "push")) (EApp (EApp (EDictApp "flatMap") (EVar "jsWireArg")) (EVar "ps"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    call $")) (EApp (EMethodRef "display") (EApp (EVar "jsffiImportId") (EFieldAccess (EVar "imp") "medakaName")))) (ELit (LString ""))))) (EIf (EVar "held") (EListLit (ELit (LString "    local.set $r"))) (EListLit))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "jsCopyBack") (EVar "copyTrap"))) (EVar "ps"))) (EApp (EApp (EApp (EVar "jsUnwire") (EFieldAccess (EVar "imp") "result")) (EVar "intTrap")) (EVar "charTrap"))) (EListLit (ELit (LString "  )")))))))
(DTypeSig false "zipHeads" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "zipHeads" ((PList) PWild) (EListLit))
(DFunDef false "zipHeads" ((PCons (PVar "h") (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (EVar "h") (EVar "i")) (EApp (EApp (EVar "zipHeads") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "jsPushArg" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "jsPushArg" ((PTuple (PLit (LString "String")) (PVar "i"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (call $mdk_push_path_more (ref.cast (ref $str) (local.get $p")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")))")))))
(DFunDef false "jsPushArg" ((PTuple (PLit (LString "Array")) (PVar "i"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (call $mdk_jsffi_push_ints (ref.cast (ref $arr) (local.get $p")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")))")))))
(DFunDef false "jsPushArg" (PWild) (EListLit))
(DTypeSig false "jsWireArg" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "jsWireArg" ((PTuple (PVar "head") (PVar "i"))) (EBlock (DoLet false false (PVar "p") (EBinOp "++" (EBinOp "++" (ELit (LString "(local.get $p")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")")))) (DoExpr (EMatch (EVar "head") (arm (PLit (LString "Unit")) () (EListLit)) (arm (PLit (LString "Int")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (call $mdk_unbox_int ")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString ")"))))) (arm (PLit (LString "Float")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (struct.get $float 0 (ref.cast (ref $float) ")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "))"))))) (arm (PLit (LString "Bool")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (i31.get_u (ref.cast (ref i31) ")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "))"))))) (arm (PLit (LString "Char")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (i31.get_u (ref.cast (ref i31) ")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "))"))))) (arm (PLit (LString "U64")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (struct.get $u64 0 (ref.cast (ref $u64) ")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "))"))))) (arm (PLit (LString "I64")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (struct.get $i64 0 (ref.cast (ref $i64) ")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "))"))))) (arm (PLit (LString "String")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (array.len (struct.get $str $bytes (ref.cast (ref $str) ")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString ")))"))))) (arm (PLit (LString "Array")) () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (array.len (ref.cast (ref $arr) ")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "))"))))) (arm PWild () (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (i32.wrap_i64 (call $mdk_unbox_int ")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "))")))))))))
(DTypeSig false "jsCopyBack" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "jsCopyBack" ((PVar "trap") (PTuple (PLit (LString "Array")) (PVar "i"))) (EBinOp "++" (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (local.set $off (call $mdk_jsffi_copy_back (ref.cast (ref $arr) (local.get $p")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")) (local.get $off)))"))) (ELit (LString "    (if (i32.lt_s (local.get $off) (i32.const 0)) (then"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString "      ")) (EVar "_s")))) (EVar "trap"))) (EListLit (ELit (LString "    ))")))))
(DFunDef false "jsCopyBack" (PWild PWild) (EListLit))
(DTypeSig false "jsUnwire" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "jsUnwire" ((PLit (LString "Int")) (PVar "intTrap") PWild) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "    (if (i64.ne (i64.shr_s (i64.shl (local.get $r) (i64.const 1)) (i64.const 1)) (local.get $r)) (then"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString "      ")) (EVar "_s")))) (EVar "intTrap"))) (EListLit (ELit (LString "    ))")) (ELit (LString "    (call $mdk_box_int (local.get $r))")))))
(DFunDef false "jsUnwire" ((PLit (LString "Char")) PWild (PVar "charTrap")) (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "    (if (i32.eqz (i32.and (i32.lt_u (local.get $r) (i32.const 1114112))")) (ELit (LString "        (i32.or (i32.lt_u (local.get $r) (i32.const 55296)) (i32.gt_u (local.get $r) (i32.const 57343))))) (then"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString "      ")) (EVar "_s")))) (EVar "charTrap"))) (EListLit (ELit (LString "    ))")) (ELit (LString "    (ref.i31 (local.get $r))")))))
(DFunDef false "jsUnwire" ((PLit (LString "Float")) PWild PWild) (EListLit (ELit (LString "    (struct.new $float (local.get $r))"))))
(DFunDef false "jsUnwire" ((PLit (LString "Bool")) PWild PWild) (EListLit (ELit (LString "    (ref.i31 (i32.ne (local.get $r) (i32.const 0)))"))))
(DFunDef false "jsUnwire" ((PLit (LString "U8")) PWild PWild) (EListLit (ELit (LString "    (call $mdk_box_int (i64.extend_i32_u (i32.and (local.get $r) (i32.const 255))))"))))
(DFunDef false "jsUnwire" ((PLit (LString "U16")) PWild PWild) (EListLit (ELit (LString "    (call $mdk_box_int (i64.extend_i32_u (i32.and (local.get $r) (i32.const 65535))))"))))
(DFunDef false "jsUnwire" ((PLit (LString "U32")) PWild PWild) (EListLit (ELit (LString "    (call $mdk_box_int (i64.extend_i32_u (local.get $r)))"))))
(DFunDef false "jsUnwire" ((PLit (LString "I32")) PWild PWild) (EListLit (ELit (LString "    (call $mdk_box_int (i64.extend_i32_s (local.get $r)))"))))
(DFunDef false "jsUnwire" ((PLit (LString "U64")) PWild PWild) (EListLit (ELit (LString "    (struct.new $u64 (local.get $r))"))))
(DFunDef false "jsUnwire" ((PLit (LString "I64")) PWild PWild) (EListLit (ELit (LString "    (struct.new $i64 (local.get $r))"))))
(DFunDef false "jsUnwire" ((PLit (LString "String")) PWild PWild) (EListLit (ELit (LString "    (call $mdk_jsffi_result_str (local.get $off))"))))
(DFunDef false "jsUnwire" (PWild PWild PWild) (EListLit (ELit (LString "    (ref.i31 (i32.const 0))"))))
(DTypeSig true "jsffiRuntimeLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "JsImport")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "jsffiRuntimeLines" ((PVar "keys") (PVar "imps")) (EBlock (DoLet false false (PVar "heads") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "imp")) (EFieldAccess (EVar "imp") "params"))) (EVar "imps"))) (DoLet false false (PVar "pushMore") (EIf (EBinOp "&&" (EApp (EApp (EVar "anyList") (EVar "isChannelHead")) (EVar "heads")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (ELit (LString "mdk_rename"))) (EVar "keys")))) (EVar "ioPushPathMoreLines") (EListLit))) (DoLet false false (PVar "arrays") (EIf (EApp (EApp (EVar "contains") (ELit (LString "Array"))) (EVar "heads")) (EVar "jsffiArrayLines") (EListLit))) (DoLet false false (PVar "strs") (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "imp")) (EBinOp "==" (EFieldAccess (EVar "imp") "result") (ELit (LString "String"))))) (EVar "imps")) (EVar "jsffiResultStrLines") (EListLit))) (DoExpr (EBinOp "++" (EBinOp "++" (EVar "pushMore") (EVar "arrays")) (EVar "strs")))))
(DTypeSig false "jsffiArrayLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "jsffiArrayLines" () (EListLit (ELit (LString "  ;; push an Array Int's elements to the host path buffer, 8 LE bytes each.")) (ELit (LString "  (func $mdk_jsffi_push_ints (param $a (ref $arr))")) (ELit (LString "    (local $i i32) (local $n i32) (local $w i64) (local $k i32)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $w (call $mdk_unbox_int (array.get $arr (local.get $a) (local.get $i))))")) (ELit (LString "      (local.set $k (i32.const 0))")) (ELit (LString "      (block $bd (loop $bl")) (ELit (LString "        (br_if $bd (i32.ge_s (local.get $k) (i32.const 8)))")) (ELit (LString "        (call $mdk_path_push (i32.wrap_i64 (i64.and (local.get $w) (i64.const 255))))")) (ELit (LString "        (local.set $w (i64.shr_u (local.get $w) (i64.const 8)))")) (ELit (LString "        (local.set $k (i32.add (local.get $k) (i32.const 1))) (br $bl)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    )")) (ELit (LString "  ;; the 8 LE bytes at $at of the host result buffer, as an i64.")) (ELit (LString "  (func $mdk_jsffi_result_i64 (param $at i32) (result i64)")) (ELit (LString "    (local $k i32) (local $w i64)")) (ELit (LString "    (local.set $k (i32.const 8))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.eqz (local.get $k)))")) (ELit (LString "      (local.set $k (i32.sub (local.get $k) (i32.const 1)))")) (ELit (LString "      (local.set $w (i64.or (i64.shl (local.get $w) (i64.const 8))")) (ELit (LString "        (i64.extend_i32_u (i32.and (call $mdk_result_byte (i32.add (local.get $at) (local.get $k))) (i32.const 255)))))")) (ELit (LString "      (br $l)))")) (ELit (LString "    (local.get $w))")) (ELit (LString "  ;; copy an Array Int argument back from the result buffer at $off: the next")) (ELit (LString "  ;; offset, or -1 with nothing written when a word is outside Int's 63 bits.")) (ELit (LString "  (func $mdk_jsffi_copy_back (param $a (ref $arr)) (param $off i32) (result i32)")) (ELit (LString "    (local $i i32) (local $n i32) (local $w i64)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $w (call $mdk_jsffi_result_i64 (i32.add (local.get $off) (i32.shl (local.get $i) (i32.const 3)))))")) (ELit (LString "      (if (i64.ne (i64.shr_s (i64.shl (local.get $w) (i64.const 1)) (i64.const 1)) (local.get $w))")) (ELit (LString "        (then (return (i32.const -1))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $arr (local.get $a) (local.get $i)")) (ELit (LString "        (call $mdk_box_int (call $mdk_jsffi_result_i64 (i32.add (local.get $off) (i32.shl (local.get $i) (i32.const 3))))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))")) (ELit (LString "    (i32.add (local.get $off) (i32.shl (local.get $n) (i32.const 3))))"))))
(DTypeSig false "jsffiResultStrLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "jsffiResultStrLines" () (EListLit (ELit (LString "  ;; the host result buffer from $off to its end, as a $str.")) (ELit (LString "  (func $mdk_jsffi_result_str (param $off i32) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (i32.sub (call $mdk_result_len) (local.get $off)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i)")) (ELit (LString "        (call $mdk_result_byte (i32.add (local.get $off) (local.get $i))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (call $mdk_u8_to_str_lossy (local.get $buf)))"))))
(DTypeSig false "ioReadFileLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioReadFileLines" () (EListLit (ELit (LString "  ;; readFile's Err for contents that are not UTF-8: the path, then a fixed ASCII")) (ELit (LString "  ;; suffix, byte-identical to medaka_rt.c mdk_read_file.")) (ELit (LString "  (func $mdk_str_not_utf8 (param $path (ref $str)) (result (ref $str))")) (ELit (LString "    (local $pb (ref $u8arr)) (local $pl i32) (local $sfx (ref $u8arr)) (local $out (ref $u8arr))")) (ELit (LString "    (local.set $pb (struct.get $str $bytes (local.get $path)))")) (ELit (LString "    (local.set $pl (array.len (local.get $pb)))")) (EBinOp "++" (EBinOp "++" (ELit (LString "    (local.set $sfx ")) (EApp (EMethodRef "display") (EVar "notUtf8SuffixWat"))) (ELit (LString ")"))) (ELit (LString "    (local.set $out (array.new $u8arr (i32.const 0) (i32.add (local.get $pl) (array.len (local.get $sfx)))))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $out) (i32.const 0) (local.get $pb) (i32.const 0) (local.get $pl))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $out) (local.get $pl) (local.get $sfx) (i32.const 0) (array.len (local.get $sfx)))")) (ELit (LString "    (struct.new $str (i32.add (struct.get $str $cp_count (local.get $path)) (array.len (local.get $sfx))) (local.get $out)))")) (ELit (LString "  ;; readFile : $str path -> Result String String.  1=Ok contents / 0=Err message.")) (ELit (LString "  ;; Contents that are not UTF-8 are an Err naming the path (medaka_rt.c mdk_read_file).")) (ELit (LString "  (func $mdk_read_file_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $st i32) (local $buf (ref $u8arr)) (local $c i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (local.set $st (call $mdk_read_file))")) (ELit (LString "    (if (i32.eqz (local.get $st))")) (ELit (LString "      (then (return (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))")) (ELit (LString "    (local.set $buf (call $mdk_io_result_bytes))")) (ELit (LString "    (local.set $c (call $mdk_utf8_valid_count (local.get $buf)))")) (ELit (LString "    (if (result (ref eq)) (i32.ge_s (local.get $c) (i32.const 0))")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (struct.new $str (local.get $c) (local.get $buf))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_str_not_utf8 (local.get $path))))))"))))
(DTypeSig false "ioFetchTextLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioFetchTextLines" () (EListLit (ELit (LString "  ;; fetchText : $str url -> Result String String.  1=Ok body / 0=Err message.")) (ELit (LString "  ;; The host import answers with a promise, so under JSPI the guest suspends in the call.")) (ELit (LString "  (func $mdk_fetch_text_io (param $url (ref $str)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_path (local.get $url))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_fetch_text)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (call $mdk_io_result_to_str)))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioFileExistsLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioFileExistsLines" () (EListLit (ELit (LString "  ;; fileExists : $str path -> Bool (i31 ordinal: False=0 / True=1); 2 = refused.")) (ELit (LString "  (func $mdk_file_exists_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $r i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (local.set $r (call $mdk_file_exists))")) (ELit (LString "    (if (i32.eq (local.get $r) (i32.const 2)) (then (call $mdk_refused_panic)))")) (ELit (LString "    (ref.i31 (local.get $r)))"))))
(DTypeSig false "ioCanonicalizeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioCanonicalizeLines" () (EListLit (ELit (LString "  ;; canonicalizePath : $str path -> $str.  1=the host's answer / 0=refused.")) (ELit (LString "  (func $mdk_canonicalize_path_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (i32.eqz (call $mdk_canonicalize_path)) (then (call $mdk_refused_panic)))")) (ELit (LString "    (call $mdk_io_result_to_str))"))))
(DTypeSig false "ioWriteFileLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioWriteFileLines" () (EListLit (ELit (LString "  ;; writeFile : $str path -> $str contents -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  ;; The contents' bytes stream to the host's write buffer, as writeFileBytes streams its array.")) (ELit (LString "  (func $mdk_write_file_io (param $path (ref $str)) (param $s (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (call $mdk_write_file_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_file_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_write_file)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioWriteFileModeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioWriteFileModeLines" () (EListLit (ELit (LString "  ;; writeFileMode : $str path -> Int mode -> $str contents -> Result String Unit.")) (ELit (LString "  ;; 1=Ok () / 0=Err msg.  The contents stream to the host's write buffer; the host sets")) (ELit (LString "  ;; the file's mode before the first byte is written.")) (ELit (LString "  (func $mdk_write_file_mode_io (param $path (ref $str)) (param $mode (ref eq)) (param $s (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (call $mdk_write_file_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_file_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_write_file_mode (i32.wrap_i64 (call $mdk_unbox_int (local.get $mode))))")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioAppendFileLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioAppendFileLines" () (EListLit (ELit (LString "  ;; appendFile : $str path -> $str contents -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  ;; The contents' bytes stream to the host's write buffer; the host appends them.")) (ELit (LString "  (func $mdk_append_file_io (param $path (ref $str)) (param $s (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $b (ref $u8arr)) (local $i i32) (local $n i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (call $mdk_write_file_reset)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_file_push (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_append_file)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioRenameLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioRenameLines" () (EListLit (ELit (LString "  ;; rename : $str src -> $str dst -> src grant -> dst grant -> Result String Unit.")) (ELit (LString "  ;; The grants share the grant channel (-2 ends the first), the paths the path channel;")) (ELit (LString "  ;; the host splits the path buffer at the source's byte length.")) (ELit (LString "  (func $mdk_rename_io (param $src (ref $str)) (param $dst (ref $str)) (param $gs (ref eq)) (param $gd (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $gs))")) (ELit (LString "    (call $mdk_grant_push (i32.const -2))")) (ELit (LString "    (call $mdk_push_grant_more (local.get $gd))")) (ELit (LString "    (call $mdk_push_path (local.get $src))")) (ELit (LString "    (call $mdk_push_path_more (local.get $dst))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_rename (array.len (struct.get $str $bytes (local.get $src))))")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioListDirLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioListDirLines" () (EListLit (ELit (LString "  ;; listDir : $str path -> Result String (List String).  The host answers each entry's")) (ELit (LString "  ;; name followed by a NUL byte; the list is built from the last entry back.")) (ELit (LString "  (func $mdk_list_dir_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $buf (ref $u8arr)) (local $name (ref $u8arr)) (local $acc (ref eq))")) (ELit (LString "    (local $pos i32) (local $end i32) (local $k i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (i32.eqz (call $mdk_list_dir))")) (ELit (LString "      (then (return (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))")) (ELit (LString "    (local.set $buf (call $mdk_io_result_bytes))")) (ELit (LString "    (local.set $acc (ref.i31 (i32.const 1)))")) (ELit (LString "    (local.set $pos (array.len (local.get $buf)))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.le_s (local.get $pos) (i32.const 0)))")) (ELit (LString "      (local.set $end (i32.sub (local.get $pos) (i32.const 1)))")) (ELit (LString "      (local.set $k (local.get $end))")) (ELit (LString "      (block $s (loop $m")) (ELit (LString "        (br_if $s (i32.eqz (local.get $k)))")) (ELit (LString "        (br_if $s (i32.eqz (array.get_u $u8arr (local.get $buf) (i32.sub (local.get $k) (i32.const 1)))))")) (ELit (LString "        (local.set $k (i32.sub (local.get $k) (i32.const 1))) (br $m)))")) (ELit (LString "      (local.set $name (array.new $u8arr (i32.const 0) (i32.sub (local.get $end) (local.get $k))))")) (ELit (LString "      (array.copy $u8arr $u8arr (local.get $name) (i32.const 0) (local.get $buf) (local.get $k) (i32.sub (local.get $end) (local.get $k)))")) (ELit (LString "      (local.set $acc (struct.new $C_Cons (i32.const 0) (call $mdk_u8_to_str_lossy (local.get $name)) (local.get $acc)))")) (ELit (LString "      (local.set $pos (local.get $k)) (br $l)))")) (ELit (LString "    (struct.new $C_Ok (i32.const 0) (local.get $acc)))"))))
(DTypeSig false "ioStatFileLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioStatFileLines" () (EListLit (ELit (LString "  ;; statFile : $str path -> Result String (Int, Bool, Bool, Float): size, isDir, isFile,")) (ELit (LString "  ;; mtime in seconds.  The host answers each field of the stat it took as an f64.")) (ELit (LString "  (func $mdk_stat_file_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_stat_file)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0)")) (ELit (LString "        (struct.new $C_Tup4 (i32.const 0)")) (ELit (LString "          (call $mdk_box_int (i64.trunc_f64_s (call $mdk_stat_field (i32.const 0))))")) (ELit (LString "          (ref.i31 (i32.trunc_f64_s (call $mdk_stat_field (i32.const 1))))")) (ELit (LString "          (ref.i31 (i32.trunc_f64_s (call $mdk_stat_field (i32.const 2))))")) (ELit (LString "          (struct.new $float (call $mdk_stat_field (i32.const 3))))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioMakeDirLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioMakeDirLines" () (EListLit (ELit (LString "  ;; makeDir : $str path -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  (func $mdk_make_dir_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_make_dir)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioRemoveFileLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioRemoveFileLines" () (EListLit (ELit (LString "  ;; removeFile : $str path -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  (func $mdk_remove_file_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_remove_file)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioRemoveDirLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioRemoveDirLines" () (EListLit (ELit (LString "  ;; removeDir : $str path -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  (func $mdk_remove_dir_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_remove_dir)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioFsyncLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioFsyncLines" () (EListLit (ELit (LString "  ;; fsync : $str path -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  (func $mdk_fsync_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_fsync)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioFileModeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioFileModeLines" () (EListLit (ELit (LString "  ;; fileMode : $str path -> Result String Int: the permission bits, 0 to 4095.  The host")) (ELit (LString "  ;; takes the stat that statFile takes and answers its mode field, field 4.")) (ELit (LString "  (func $mdk_file_mode_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_file_mode)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0)")) (ELit (LString "        (call $mdk_box_int (i64.trunc_f64_s (call $mdk_stat_field (i32.const 4))))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "ioGetEnvLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioGetEnvLines" () (EListLit (ELit (LString "  ;; getEnv : $str name -> Option String.  1=Some value / 0=None.")) (ELit (LString "  (func $mdk_get_env_io (param $name (ref $str)) (result (ref eq))")) (ELit (LString "    (local $st i32)")) (ELit (LString "    (call $mdk_push_path (local.get $name))")) (ELit (LString "    (local.set $st (call $mdk_get_env))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then (struct.new $C_Some (i32.const 0) (call $mdk_io_result_to_str)))")) (ELit (LString "      (else (ref.i31 (i32.const 1)))))"))))
(DTypeSig false "ioReadLineLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioReadLineLines" () (EListLit (ELit (LString "  ;; readLine : Unit -> String.  The host answers 1 with a line (its newline")) (ELit (LString "  ;; stripped) on the result channel, or 0 at end of input, where the channel is empty.")) (ELit (LString "  (func $mdk_read_line_io (result (ref eq))")) (ELit (LString "    (drop (call $mdk_read_line))")) (ELit (LString "    (call $mdk_io_result_to_str))")) (ELit (LString "  ;; readLineOpt : Unit -> Option String.  0 is None.")) (ELit (LString "  (func $mdk_read_line_opt_io (result (ref eq))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_read_line)")) (ELit (LString "      (then (struct.new $C_Some (i32.const 0) (call $mdk_io_result_to_str)))")) (ELit (LString "      (else (ref.i31 (i32.const 1)))))"))))
(DTypeSig false "ioReadAllLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioReadAllLines" () (EListLit (ELit (LString "  ;; readAll : Unit -> String.  The rest of the host's stdin buffer.")) (ELit (LString "  (func $mdk_read_all_io (result (ref eq))")) (ELit (LString "    (call $mdk_read_all)")) (ELit (LString "    (call $mdk_io_result_to_str))"))))
(DTypeSig false "ioReadExactlyLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioReadExactlyLines" () (EListLit (ELit (LString "  ;; readExactly : Int -> Option String.  1=Some the n bytes / 0=None (end of input")) (ELit (LString "  ;; or a short read, whose bytes the host has consumed).")) (ELit (LString "  (func $mdk_read_exactly_io (param $n i64) (result (ref eq))")) (ELit (LString "    (if (result (ref eq)) (call $mdk_read_exactly (local.get $n))")) (ELit (LString "      (then (struct.new $C_Some (i32.const 0) (call $mdk_io_result_to_str)))")) (ELit (LString "      (else (ref.i31 (i32.const 1)))))"))))
(DTypeSig false "ioExecutablePathLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioExecutablePathLines" () (EListLit (ELit (LString "  (func $mdk_executable_path_io (result (ref eq))")) (ELit (LString "    (drop (call $mdk_executable_path))")) (ELit (LString "    (call $mdk_io_result_to_str))"))))
(DTypeSig true "ioArgsRuntimeLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ioArgsRuntimeLines" ((PVar "keys")) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_args_count"))) (EVar "keys")) (EVar "ioArgsLines")))
(DTypeSig false "ioArgsLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ioArgsLines" () (EListLit (ELit (LString "  ;; build a $str from the i-th host arg (mdk_arg_len(i) + mdk_arg_byte(i,j)).")) (ELit (LString "  (func $mdk_arg_to_str (param $idx i32) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $j i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (call $mdk_arg_len (local.get $idx)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $j (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $j) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $j) (call $mdk_arg_byte (local.get $idx) (local.get $j)))")) (ELit (LString "      (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $l)))")) (ELit (LString "    (call $mdk_u8_to_str_lossy (local.get $buf)))")) (ELit (LString "  ;; args : Unit -> List String.  Fold a Cons chain right-to-left ending in Nil.")) (ELit (LString "  (func $mdk_args_io (result (ref eq))")) (ELit (LString "    (local $c i32) (local $i i32) (local $acc (ref eq))")) (ELit (LString "    (local.set $c (call $mdk_args_count))")) (ELit (LString "    (local.set $acc (ref.i31 (i32.const 1)))")) (ELit (LString "    (local.set $i (i32.sub (local.get $c) (i32.const 1)))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.lt_s (local.get $i) (i32.const 0)))")) (ELit (LString "      (local.set $acc (struct.new $C_Cons (i32.const 0) (call $mdk_arg_to_str (local.get $i)) (local.get $acc)))")) (ELit (LString "      (local.set $i (i32.sub (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $acc))"))))
(DTypeSig true "fileBytesRuntimeLines" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "fileBytesRuntimeLines" ((PVar "readsBytes") (PVar "keys")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_write_file_commit"))) (EVar "keys")) (EVar "writeFileBytesLines")) (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_os_entropy"))) (EVar "keys")) (EVar "osEntropyLines"))) (EIf (EVar "readsBytes") (EApp (EApp (EApp (EVar "gatedOn") (ELit (LString "mdk_read_file"))) (EVar "keys")) (EVar "readFileBytesLines")) (EListLit))))
(DTypeSig false "readFileBytesLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "readFileBytesLines" () (EListLit (ELit (LString "  ;; readFileBytes : $str path -> Result String (Array Int).  1=Ok bytes / 0=Err msg.")) (ELit (LString "  ;; Reuses the read byte-channel but rebuilds an $arr of i31 Int bytes (0..255).")) (ELit (LString "  (func $mdk_read_file_bytes_io (param $path (ref $str)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $st i32) (local $n i32) (local $i i32) (local $out (ref $arr))")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (local.set $st (call $mdk_read_file))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then")) (ELit (LString "        (local.set $n (call $mdk_result_len))")) (ELit (LString "        (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))")) (ELit (LString "        (local.set $i (i32.const 0))")) (ELit (LString "        (block $d (loop $l")) (ELit (LString "          (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "          (array.set $arr (local.get $out) (local.get $i) (ref.i31 (call $mdk_result_byte (local.get $i))))")) (ELit (LString "          (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "        (struct.new $C_Ok (i32.const 0) (local.get $out)))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig false "osEntropyLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "osEntropyLines" () (EListLit (ELit (LString "  ;; osEntropyBytes : Int -> Array Int.  1=n random bytes / 0=a refusal (its text on the channel).")) (ELit (LString "  (func $mdk_os_entropy_io (param $n i64) (result (ref eq))")) (ELit (LString "    (local $len i32) (local $i i32) (local $out (ref $arr))")) (ELit (LString "    (if (i32.eqz (call $mdk_os_entropy (local.get $n))) (then (call $mdk_refused_panic)))")) (ELit (LString "    (local.set $len (call $mdk_result_len))")) (ELit (LString "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $len)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $len)))")) (ELit (LString "      (array.set $arr (local.get $out) (local.get $i) (ref.i31 (call $mdk_result_byte (local.get $i))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $out))"))))
(DTypeSig false "writeFileBytesLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "writeFileBytesLines" () (EListLit (ELit (LString "  ;; writeFileBytes : $str path -> $arr bytes -> Result String Unit.  1=Ok () / 0=Err msg.")) (ELit (LString "  ;; Stream each i31 byte (masked to 0..255) to the host, then commit fs.writeFileSync.")) (ELit (LString "  (func $mdk_write_file_bytes_io (param $path (ref $str)) (param $ba (ref $arr)) (param $g (ref eq)) (result (ref eq))")) (ELit (LString "    (local $st i32) (local $n i32) (local $i i32)")) (ELit (LString "    (call $mdk_push_grant (local.get $g))")) (ELit (LString "    (call $mdk_push_path (local.get $path))")) (ELit (LString "    (call $mdk_write_file_reset)")) (ELit (LString "    (local.set $n (array.len (local.get $ba)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_file_push (i32.and (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $ba) (local.get $i)))) (i32.const 255)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.set $st (call $mdk_write_file_commit))")) (ELit (LString "    (if (result (ref eq)) (local.get $st)")) (ELit (LString "      (then (struct.new $C_Ok (i32.const 0) (ref.i31 (i32.const 0))))")) (ELit (LString "      (else (struct.new $C_Err (i32.const 1) (call $mdk_io_result_to_str)))))"))))
(DTypeSig true "strSearchRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strSearchRuntimeLines" () (EListLit (ELit (LString "  ;; -- W8b stringIndexOf / stringCompare (byte-identical to medaka_rt.c) --")) (ELit (LString "  (func $mdk_str_index_of (param $needle (ref $str)) (param $hay (ref $str)) (result (ref eq))")) (ELit (LString "    (local $nb (ref $u8arr)) (local $hb (ref $u8arr)) (local $nl i32) (local $hl i32)")) (ELit (LString "    (local $b i32) (local $j i32) (local $ok i32)")) (ELit (LString "    (local.set $nb (struct.get $str $bytes (local.get $needle)))")) (ELit (LString "    (local.set $hb (struct.get $str $bytes (local.get $hay)))")) (ELit (LString "    (local.set $nl (array.len (local.get $nb)))")) (ELit (LString "    (local.set $hl (array.len (local.get $hb)))")) (ELit (LString "    ;; empty needle -> Some 0 (codepoint index 0).")) (ELit (LString "    (if (i32.eqz (local.get $nl))")) (ELit (LString "      (then (return (struct.new $C_Some (i32.const 0) (ref.i31 (i32.const 0))))))")) (ELit (LString "    (local.set $b (i32.const 0))")) (ELit (LString "    (block $done (loop $scan")) (ELit (LString "      ;; while b + nl <= hl")) (ELit (LString "      (br_if $done (i32.gt_s (i32.add (local.get $b) (local.get $nl)) (local.get $hl)))")) (ELit (LString "      (local.set $ok (i32.const 1))")) (ELit (LString "      (local.set $j (i32.const 0))")) (ELit (LString "      (block $cmpd (loop $cmpl")) (ELit (LString "        (br_if $cmpd (i32.ge_s (local.get $j) (local.get $nl)))")) (ELit (LString "        (if (i32.ne (array.get_u $u8arr (local.get $hb) (i32.add (local.get $b) (local.get $j)))")) (ELit (LString "                    (array.get_u $u8arr (local.get $nb) (local.get $j)))")) (ELit (LString "          (then (local.set $ok (i32.const 0)) (br $cmpd)))")) (ELit (LString "        (local.set $j (i32.add (local.get $j) (i32.const 1))) (br $cmpl)))")) (ELit (LString "      (if (local.get $ok)")) (ELit (LString "        (then (return (struct.new $C_Some (i32.const 0)")) (ELit (LString "          (ref.i31 (call $mdk_cp_count (local.get $hb) (local.get $b)))))))")) (ELit (LString "      (local.set $b (i32.add (local.get $b) (i32.const 1))) (br $scan)))")) (ELit (LString "    ;; not found -> None (i31 ordinal 1).")) (ELit (LString "    (ref.i31 (i32.const 1)))")) (ELit (LString "  ;; -- W8c byte-level count / last-index (byte-identical to medaka_rt.c) --")) (ELit (LString "  ;; non-overlapping occurrences; 0 for an empty needle.")) (ELit (LString "  (func $mdk_str_count_occ (param $n (ref $str)) (param $h (ref $str)) (result i32)")) (ELit (LString "    (local $nb (ref $u8arr)) (local $hb (ref $u8arr)) (local $nl i32) (local $hl i32)")) (ELit (LString "    (local $b i32) (local $c i32)")) (ELit (LString "    (local.set $nb (struct.get $str $bytes (local.get $n)))")) (ELit (LString "    (local.set $hb (struct.get $str $bytes (local.get $h)))")) (ELit (LString "    (local.set $nl (array.len (local.get $nb)))")) (ELit (LString "    (local.set $hl (array.len (local.get $hb)))")) (ELit (LString "    (if (i32.eqz (local.get $nl)) (then (return (i32.const 0))))")) (ELit (LString "    (block $done (loop $scan")) (ELit (LString "      (br_if $done (i32.gt_s (i32.add (local.get $b) (local.get $nl)) (local.get $hl)))")) (ELit (LString "      (if (call $mdk_bytes_match_at (local.get $nb) (local.get $hb) (local.get $b))")) (ELit (LString "        (then")) (ELit (LString "          (local.set $c (i32.add (local.get $c) (i32.const 1)))")) (ELit (LString "          (local.set $b (i32.add (local.get $b) (local.get $nl))))")) (ELit (LString "        (else (local.set $b (i32.add (local.get $b) (i32.const 1)))))")) (ELit (LString "      (br $scan)))")) (ELit (LString "    (local.get $c))")) (ELit (LString "  ;; overlapping occurrences, the last one wins; an empty needle is at the codepoint end.")) (ELit (LString "  (func $mdk_str_last_index_of (param $n (ref $str)) (param $h (ref $str)) (result (ref eq))")) (ELit (LString "    (local $nb (ref $u8arr)) (local $hb (ref $u8arr)) (local $nl i32) (local $hl i32)")) (ELit (LString "    (local $b i32) (local $last i32)")) (ELit (LString "    (local.set $nb (struct.get $str $bytes (local.get $n)))")) (ELit (LString "    (local.set $hb (struct.get $str $bytes (local.get $h)))")) (ELit (LString "    (local.set $nl (array.len (local.get $nb)))")) (ELit (LString "    (local.set $hl (array.len (local.get $hb)))")) (ELit (LString "    (if (i32.eqz (local.get $nl))")) (ELit (LString "      (then (return (struct.new $C_Some (i32.const 0)")) (ELit (LString "        (ref.i31 (struct.get $str $cp_count (local.get $h)))))))")) (ELit (LString "    (local.set $last (i32.const -1))")) (ELit (LString "    (block $done (loop $scan")) (ELit (LString "      (br_if $done (i32.gt_s (i32.add (local.get $b) (local.get $nl)) (local.get $hl)))")) (ELit (LString "      (if (call $mdk_bytes_match_at (local.get $nb) (local.get $hb) (local.get $b))")) (ELit (LString "        (then (local.set $last (local.get $b))))")) (ELit (LString "      (local.set $b (i32.add (local.get $b) (i32.const 1)))")) (ELit (LString "      (br $scan)))")) (ELit (LString "    (if (i32.lt_s (local.get $last) (i32.const 0))")) (ELit (LString "      (then (return (ref.i31 (i32.const 1)))))")) (ELit (LString "    (struct.new $C_Some (i32.const 0)")) (ELit (LString "      (ref.i31 (call $mdk_cp_count (local.get $hb) (local.get $last)))))")) (ELit (LString "  (func $mdk_str_compare (param $a (ref $str)) (param $b (ref $str)) (result (ref eq))")) (ELit (LString "    (local $ab (ref $u8arr)) (local $bb (ref $u8arr)) (local $al i32) (local $bl i32)")) (ELit (LString "    (local $m i32) (local $i i32) (local $ca i32) (local $cb i32)")) (ELit (LString "    (local.set $ab (struct.get $str $bytes (local.get $a)))")) (ELit (LString "    (local.set $bb (struct.get $str $bytes (local.get $b)))")) (ELit (LString "    (local.set $al (array.len (local.get $ab)))")) (ELit (LString "    (local.set $bl (array.len (local.get $bb)))")) (ELit (LString "    (local.set $m (if (result i32) (i32.lt_s (local.get $al) (local.get $bl))")) (ELit (LString "      (then (local.get $al)) (else (local.get $bl))))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $done (loop $l")) (ELit (LString "      (br_if $done (i32.ge_s (local.get $i) (local.get $m)))")) (ELit (LString "      (local.set $ca (array.get_u $u8arr (local.get $ab) (local.get $i)))")) (ELit (LString "      (local.set $cb (array.get_u $u8arr (local.get $bb) (local.get $i)))")) (ELit (LString "      ;; byte less -> Lt (i31 0); byte greater -> Gt (i31 2).")) (ELit (LString "      (if (i32.lt_u (local.get $ca) (local.get $cb)) (then (return (ref.i31 (i32.const 0)))))")) (ELit (LString "      (if (i32.gt_u (local.get $ca) (local.get $cb)) (then (return (ref.i31 (i32.const 2)))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    ;; common prefix equal: shorter < longer; equal length -> Eq.")) (ELit (LString "    (if (i32.lt_s (local.get $al) (local.get $bl)) (then (return (ref.i31 (i32.const 0)))))")) (ELit (LString "    (if (i32.gt_s (local.get $al) (local.get $bl)) (then (return (ref.i31 (i32.const 2)))))")) (ELit (LString "    (ref.i31 (i32.const 1)))"))))
(DTypeSig true "utf8LossyRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "utf8LossyRuntimeLines" () (EListLit (ELit (LString "  ;; -- UTF-8 validation (byte-identical to medaka_rt.c mdk_str_lossy) --")) (ELit (LString "  (func $mdk_utf8_step (param $b (ref $u8arr)) (param $i i32) (param $n i32) (result i32)")) (ELit (LString "    (local $b0 i32) (local $b1 i32) (local $lo i32) (local $hi i32)")) (ELit (LString "    (local.set $b0 (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "    (if (i32.lt_u (local.get $b0) (i32.const 128)) (then (return (i32.const 1))))")) (ELit (LString "    (if (i32.and (i32.ge_u (local.get $b0) (i32.const 194)) (i32.le_u (local.get $b0) (i32.const 223)))")) (ELit (LString "      (then")) (ELit (LString "        (if (i32.lt_s (i32.add (local.get $i) (i32.const 1)) (local.get $n))")) (ELit (LString "          (then (if (i32.eq (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $i) (i32.const 1))) (i32.const 192)) (i32.const 128))")) (ELit (LString "            (then (return (i32.const 2))))))")) (ELit (LString "        (return (i32.const -1))))")) (ELit (LString "    (if (i32.or (i32.lt_u (local.get $b0) (i32.const 224)) (i32.gt_u (local.get $b0) (i32.const 244)))")) (ELit (LString "      (then (return (i32.const -1))))")) (ELit (LString "    ;; E0 and F0 bound the second byte below (overlong), ED and F4 above.")) (ELit (LString "    (local.set $lo (select (i32.const 160) (select (i32.const 144) (i32.const 128) (i32.eq (local.get $b0) (i32.const 240))) (i32.eq (local.get $b0) (i32.const 224))))")) (ELit (LString "    (local.set $hi (select (i32.const 159) (select (i32.const 143) (i32.const 191) (i32.eq (local.get $b0) (i32.const 244))) (i32.eq (local.get $b0) (i32.const 237))))")) (ELit (LString "    (if (i32.ge_s (i32.add (local.get $i) (i32.const 1)) (local.get $n)) (then (return (i32.const -1))))")) (ELit (LString "    (local.set $b1 (array.get_u $u8arr (local.get $b) (i32.add (local.get $i) (i32.const 1))))")) (ELit (LString "    (if (i32.or (i32.lt_u (local.get $b1) (local.get $lo)) (i32.gt_u (local.get $b1) (local.get $hi)))")) (ELit (LString "      (then (return (i32.const -1))))")) (ELit (LString "    (if (i32.ge_s (i32.add (local.get $i) (i32.const 2)) (local.get $n)) (then (return (i32.const -2))))")) (ELit (LString "    (if (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $i) (i32.const 2))) (i32.const 192)) (i32.const 128))")) (ELit (LString "      (then (return (i32.const -2))))")) (ELit (LString "    (if (i32.lt_u (local.get $b0) (i32.const 240)) (then (return (i32.const 3))))")) (ELit (LString "    (if (i32.ge_s (i32.add (local.get $i) (i32.const 3)) (local.get $n)) (then (return (i32.const -3))))")) (ELit (LString "    (if (i32.ne (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $i) (i32.const 3))) (i32.const 192)) (i32.const 128))")) (ELit (LString "      (then (return (i32.const -3))))")) (ELit (LString "    (i32.const 4))")) (ELit (LString "  (func $mdk_utf8_valid_count (param $b (ref $u8arr)) (result i32)")) (ELit (LString "    (local $n i32) (local $i i32) (local $c i32) (local $st i32)")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $c (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $st (call $mdk_utf8_step (local.get $b) (local.get $i) (local.get $n)))")) (ELit (LString "      (if (i32.lt_s (local.get $st) (i32.const 0)) (then (return (i32.const -1))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (local.get $st)))")) (ELit (LString "      (local.set $c (i32.add (local.get $c) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $c))")) (ELit (LString "  (func $mdk_u8_to_str_lossy (param $b (ref $u8arr)) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $j i32) (local $c i32) (local $st i32) (local $out i32)")) (ELit (LString "    (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $c (call $mdk_utf8_valid_count (local.get $b)))")) (ELit (LString "    (if (i32.ge_s (local.get $c) (i32.const 0))")) (ELit (LString "      (then (return (struct.new $str (local.get $c) (local.get $b)))))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    ;; pass 1: the output length, 3 bytes per replacement.")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $out (i32.const 0))")) (ELit (LString "    (block $d1 (loop $l1")) (ELit (LString "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $st (call $mdk_utf8_step (local.get $b) (local.get $i) (local.get $n)))")) (ELit (LString "      (if (i32.gt_s (local.get $st) (i32.const 0))")) (ELit (LString "        (then")) (ELit (LString "          (local.set $out (i32.add (local.get $out) (local.get $st)))")) (ELit (LString "          (local.set $i (i32.add (local.get $i) (local.get $st))))")) (ELit (LString "        (else")) (ELit (LString "          (local.set $out (i32.add (local.get $out) (i32.const 3)))")) (ELit (LString "          (local.set $i (i32.sub (local.get $i) (local.get $st)))))")) (ELit (LString "      (br $l1)))")) (ELit (LString "    ;; pass 2: copy each well-formed sequence, U+FFFD for each subpart.")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $out)))")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $j (i32.const 0)) (local.set $c (i32.const 0))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $st (call $mdk_utf8_step (local.get $b) (local.get $i) (local.get $n)))")) (ELit (LString "      (if (i32.gt_s (local.get $st) (i32.const 0))")) (ELit (LString "        (then")) (ELit (LString "          (array.copy $u8arr $u8arr (local.get $buf) (local.get $j) (local.get $b) (local.get $i) (local.get $st))")) (ELit (LString "          (local.set $j (i32.add (local.get $j) (local.get $st)))")) (ELit (LString "          (local.set $i (i32.add (local.get $i) (local.get $st))))")) (ELit (LString "        (else")) (ELit (LString "          (array.set $u8arr (local.get $buf) (local.get $j) (i32.const 239))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.add (local.get $j) (i32.const 1)) (i32.const 191))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.add (local.get $j) (i32.const 2)) (i32.const 189))")) (ELit (LString "          (local.set $j (i32.add (local.get $j) (i32.const 3)))")) (ELit (LString "          (local.set $i (i32.sub (local.get $i) (local.get $st)))))")) (ELit (LString "      (local.set $c (i32.add (local.get $c) (i32.const 1))) (br $l2)))")) (ELit (LString "    (struct.new $str (local.get $c) (local.get $buf)))"))))
(DTypeSig true "strCodecRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "strCodecRuntimeLines" () (EListLit (ELit (LString "  ;; -- W11b UTF-8 codec (byte-identical to medaka_rt.c) --")) (ELit (LString "  ;; decode a $str's UTF-8 bytes into a fresh $arr of cp_count i31 Char codepoints.")) (ELit (LString "  (func $mdk_str_to_chars (param $s (ref $str)) (result (ref $arr))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $cpc i32) (local $out (ref $arr))")) (ELit (LString "    (local $bo i32) (local $oi i32) (local $lead i32) (local $cp i32) (local $k i32) (local $w i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $cpc (struct.get $str $cp_count (local.get $s)))")) (ELit (LString "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $cpc)))")) (ELit (LString "    (local.set $bo (i32.const 0)) (local.set $oi (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $bo) (local.get $n)))")) (ELit (LString "      ;; the output holds cp_count codepoints; never step past it.")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $oi) (local.get $cpc)))")) (ELit (LString "      (local.set $lead (array.get_u $u8arr (local.get $b) (local.get $bo)))")) (ELit (LString "      ;; lead-byte class → codepoint seed bits + total byte width.")) (ELit (LString "      (if (i32.lt_u (local.get $lead) (i32.const 128))")) (ELit (LString "        (then (local.set $cp (local.get $lead)) (local.set $w (i32.const 1)))")) (ELit (LString "        (else (if (i32.lt_u (local.get $lead) (i32.const 224))")) (ELit (LString "          (then (local.set $cp (i32.and (local.get $lead) (i32.const 31))) (local.set $w (i32.const 2)))")) (ELit (LString "          (else (if (i32.lt_u (local.get $lead) (i32.const 240))")) (ELit (LString "            (then (local.set $cp (i32.and (local.get $lead) (i32.const 15))) (local.set $w (i32.const 3)))")) (ELit (LString "            (else (local.set $cp (i32.and (local.get $lead) (i32.const 7))) (local.set $w (i32.const 4))))))))")) (ELit (LString "      ;; a sequence never reads past the backing's end.")) (ELit (LString "      (if (i32.gt_s (local.get $w) (i32.sub (local.get $n) (local.get $bo)))")) (ELit (LString "        (then (local.set $w (i32.sub (local.get $n) (local.get $bo)))))")) (ELit (LString "      ;; fold in (w-1) continuation bytes: cp = (cp << 6) | (byte & 0x3F).")) (ELit (LString "      (local.set $k (i32.const 1))")) (ELit (LString "      (block $cd (loop $cl")) (ELit (LString "        (br_if $cd (i32.ge_s (local.get $k) (local.get $w)))")) (ELit (LString "        (local.set $cp (i32.or (i32.shl (local.get $cp) (i32.const 6))")) (ELit (LString "          (i32.and (array.get_u $u8arr (local.get $b) (i32.add (local.get $bo) (local.get $k))) (i32.const 63))))")) (ELit (LString "        (local.set $k (i32.add (local.get $k) (i32.const 1))) (br $cl)))")) (ELit (LString "      (array.set $arr (local.get $out) (local.get $oi) (ref.i31 (local.get $cp)))")) (ELit (LString "      (local.set $oi (i32.add (local.get $oi) (i32.const 1)))")) (ELit (LString "      (local.set $bo (i32.add (local.get $bo) (local.get $w))) (br $l)))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; number of UTF-8 bytes a codepoint encodes to (1..4).")) (ELit (LString "  (func $mdk_utf8_nbytes (param $cp i32) (result i32)")) (ELit (LString "    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 128)) (then (i32.const 1))")) (ELit (LString "      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 2048)) (then (i32.const 2))")) (ELit (LString "        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 65536)) (then (i32.const 3))")) (ELit (LString "          (else (i32.const 4))))))))")) (ELit (LString "  ;; encode one codepoint into $buf at offset $off; return the next offset.")) (ELit (LString "  (func $mdk_utf8_emit_at (param $buf (ref $u8arr)) (param $off i32) (param $cp i32) (result i32)")) (ELit (LString "    (if (result i32) (i32.lt_u (local.get $cp) (i32.const 128))")) (ELit (LString "      (then")) (ELit (LString "        (array.set $u8arr (local.get $buf) (local.get $off) (local.get $cp))")) (ELit (LString "        (i32.add (local.get $off) (i32.const 1)))")) (ELit (LString "      (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 2048))")) (ELit (LString "        (then")) (ELit (LString "          (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 192) (i32.shr_u (local.get $cp) (i32.const 6))))")) (ELit (LString "          (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "          (i32.add (local.get $off) (i32.const 2)))")) (ELit (LString "        (else (if (result i32) (i32.lt_u (local.get $cp) (i32.const 65536))")) (ELit (LString "          (then")) (ELit (LString "            (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 224) (i32.shr_u (local.get $cp) (i32.const 12))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 2)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (i32.add (local.get $off) (i32.const 3)))")) (ELit (LString "          (else")) (ELit (LString "            (array.set $u8arr (local.get $buf) (local.get $off) (i32.or (i32.const 240) (i32.shr_u (local.get $cp) (i32.const 18))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 1)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 12)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 2)) (i32.or (i32.const 128) (i32.and (i32.shr_u (local.get $cp) (i32.const 6)) (i32.const 63))))")) (ELit (LString "            (array.set $u8arr (local.get $buf) (i32.add (local.get $off) (i32.const 3)) (i32.or (i32.const 128) (i32.and (local.get $cp) (i32.const 63))))")) (ELit (LString "            (i32.add (local.get $off) (i32.const 4))))))))")) (ELit (LString "  )")) (ELit (LString "  ;; encode an $arr of i31 Char codepoints into a fresh $str (UTF-8); cp_count = len.")) (ELit (LString "  (func $mdk_chars_to_str (param $a (ref $arr)) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $i i32) (local $total i32) (local $off i32)")) (ELit (LString "    (local $buf (ref $u8arr)) (local $cp i32)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    ;; pass 1: total encoded byte length.")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $total (i32.const 0))")) (ELit (LString "    (block $d1 (loop $l1")) (ELit (LString "      (br_if $d1 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $cp (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))))")) (ELit (LString "      (local.set $total (i32.add (local.get $total) (call $mdk_utf8_nbytes (local.get $cp))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))")) (ELit (LString "    ;; pass 2: encode into the buffer.")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $total)))")) (ELit (LString "    (local.set $i (i32.const 0)) (local.set $off (i32.const 0))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (local.set $cp (i31.get_s (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))))")) (ELit (LString "      (local.set $off (call $mdk_utf8_emit_at (local.get $buf) (local.get $off) (local.get $cp)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))")) (ELit (LString "    (struct.new $str (local.get $n) (local.get $buf)))")) (ELit (LString "  ;; stringToUtf8Bytes: copy the $str's $u8arr backing into a fresh $arr of i31 Int bytes.")) (ELit (LString "  (func $mdk_str_to_utf8_bytes (param $s (ref $str)) (result (ref $arr))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $out (ref $arr)) (local $i i32)")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $arr (local.get $out) (local.get $i) (ref.i31 (array.get_u $u8arr (local.get $b) (local.get $i))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; stringFromUtf8Bytes: blit the low 8 bits of each i31 Int into a $u8arr, read")) (ELit (LString "  ;; as UTF-8 by $mdk_u8_to_str_lossy (medaka_rt.c mdk_string_from_utf8_bytes).")) (ELit (LString "  (func $mdk_utf8_bytes_to_str (param $a (ref $arr)) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $buf (ref $u8arr)) (local $i i32)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $buf) (local.get $i)")) (ELit (LString "        (i32.and (i31.get_u (ref.cast (ref i31) (array.get $arr (local.get $a) (local.get $i)))) (i32.const 255)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (call $mdk_u8_to_str_lossy (local.get $buf)))"))))
(DTypeSig true "byteBlockRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "byteBlockRuntimeLines" () (EBinOp "++" (EListLit (ELit (LString "  ;; -- the `ByteBlock` builtin (peer of the mdk_byteblock_* C helpers) --")) (ELit (LString "  ;; byteBlockCopyUnsafe: the first $n bytes into a FRESH block.  A COPY, never a")) (ELit (LString "  ;; view: this is freeze's engine half, so a later write to the source must not")) (ELit (LString "  ;; reach the result (matching mdk_byteblock_copy's memcpy).")) (ELit (LString "  (func $mdk_bb_copy (param $n i32) (param $b (ref $u8arr)) (result (ref $u8arr))")) (ELit (LString "    (local $out (ref $u8arr))")) (ELit (LString "    (local.set $out (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $out) (i32.const 0) (local.get $b) (i32.const 0) (local.get $n))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; byteBlockFromIntArray: the low eight bits of each element.  Unboxes through")) (ELit (LString "  ;; $mdk_unbox_int rather than the i31 fast path so an element outside the i31")) (ELit (LString "  ;; range (a $boxint) masks instead of trapping -- native has no boxed Int, so")) (ELit (LString "  ;; the i31-only route would diverge on exactly those elements.")) (ELit (LString "  (func $mdk_bb_from_int_array (param $a (ref $arr)) (result (ref $u8arr))")) (ELit (LString "    (local $n i32) (local $out (ref $u8arr)) (local $i i32)")) (ELit (LString "    (local.set $n (array.len (local.get $a)))")) (ELit (LString "    (local.set $out (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $u8arr (local.get $out) (local.get $i)")) (ELit (LString "        (i32.and (i32.wrap_i64 (call $mdk_unbox_int (ref.as_non_null (array.get $arr (local.get $a) (local.get $i))))) (i32.const 255)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; byteBlockToIntArray: each byte as an Int in 0..255 (array.get_u zero-extends).")) (ELit (LString "  (func $mdk_bb_to_int_array (param $b (ref $u8arr)) (result (ref $arr))")) (ELit (LString "    (local $n i32) (local $out (ref $arr)) (local $i i32)")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $out (array.new $arr (ref.i31 (i32.const 0)) (local.get $n)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (array.set $arr (local.get $out) (local.get $i) (ref.i31 (array.get_u $u8arr (local.get $b) (local.get $i))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; byteBlockFromString: the string's UTF-8 bytes, COPIED.  A $str's backing is")) (ELit (LString "  ;; shared by every reference to that string and a block is mutable, so handing")) (ELit (LString "  ;; the backing back unaliased would let a write edit the string.")) (ELit (LString "  (func $mdk_bb_from_string (param $s (ref $str)) (result (ref $u8arr))")) (ELit (LString "    (local $b (ref $u8arr)) (local $n i32) (local $out (ref $u8arr))")) (ELit (LString "    (local.set $b (struct.get $str $bytes (local.get $s)))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $out (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $out) (i32.const 0) (local.get $b) (i32.const 0) (local.get $n))")) (ELit (LString "    (local.get $out))")) (ELit (LString "  ;; byteBlockToString: the block's bytes as a fresh $str.  The backing is COPIED")) (ELit (LString "  ;; because a block is mutable and a $str's bytes are shared by every reference to")) (ELit (LString "  ;; it; the copy is then read as UTF-8 by $mdk_u8_to_str_lossy, the same route as")) (ELit (LString "  ;; $mdk_utf8_bytes_to_str and medaka_rt.c's mdk_byteblock_to_string.")) (ELit (LString "  (func $mdk_bb_to_string (param $b (ref $u8arr)) (result (ref $str))")) (ELit (LString "    (local $n i32) (local $buf (ref $u8arr))")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $buf (array.new $u8arr (i32.const 0) (local.get $n)))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $buf) (i32.const 0) (local.get $b) (i32.const 0) (local.get $n))")) (ELit (LString "    (call $mdk_u8_to_str_lossy (local.get $buf)))")) (ELit (LString "  ;; byteBlockWriteStdout: write the block's bytes to stdout byte-for-byte, no")) (ELit (LString "  ;; encoding assumption -- unlike $mdk_print_str, there is no $str/cp_count to")) (ELit (LString "  ;; read, just the raw $u8arr length.")) (ELit (LString "  (func $mdk_bb_write_stdout (param $b (ref $u8arr))")) (ELit (LString "    (local $i i32) (local $n i32)")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_s (local.get $i) (local.get $n)))")) (ELit (LString "      (call $mdk_write_byte (array.get_u $u8arr (local.get $b) (local.get $i)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))))"))) (EVar "sha256RuntimeLines")))
(DTypeSig false "sha256K" (TyApp (TyCon "List") (TyCon "Int")))
(DFunDef false "sha256K" () (EListLit (ELit (LInt 1116352408)) (ELit (LInt 1899447441)) (ELit (LInt 3049323471)) (ELit (LInt 3921009573)) (ELit (LInt 961987163)) (ELit (LInt 1508970993)) (ELit (LInt 2453635748)) (ELit (LInt 2870763221)) (ELit (LInt 3624381080)) (ELit (LInt 310598401)) (ELit (LInt 607225278)) (ELit (LInt 1426881987)) (ELit (LInt 1925078388)) (ELit (LInt 2162078206)) (ELit (LInt 2614888103)) (ELit (LInt 3248222580)) (ELit (LInt 3835390401)) (ELit (LInt 4022224774)) (ELit (LInt 264347078)) (ELit (LInt 604807628)) (ELit (LInt 770255983)) (ELit (LInt 1249150122)) (ELit (LInt 1555081692)) (ELit (LInt 1996064986)) (ELit (LInt 2554220882)) (ELit (LInt 2821834349)) (ELit (LInt 2952996808)) (ELit (LInt 3210313671)) (ELit (LInt 3336571891)) (ELit (LInt 3584528711)) (ELit (LInt 113926993)) (ELit (LInt 338241895)) (ELit (LInt 666307205)) (ELit (LInt 773529912)) (ELit (LInt 1294757372)) (ELit (LInt 1396182291)) (ELit (LInt 1695183700)) (ELit (LInt 1986661051)) (ELit (LInt 2177026350)) (ELit (LInt 2456956037)) (ELit (LInt 2730485921)) (ELit (LInt 2820302411)) (ELit (LInt 3259730800)) (ELit (LInt 3345764771)) (ELit (LInt 3516065817)) (ELit (LInt 3600352804)) (ELit (LInt 4094571909)) (ELit (LInt 275423344)) (ELit (LInt 430227734)) (ELit (LInt 506948616)) (ELit (LInt 659060556)) (ELit (LInt 883997877)) (ELit (LInt 958139571)) (ELit (LInt 1322822218)) (ELit (LInt 1537002063)) (ELit (LInt 1747873779)) (ELit (LInt 1955562222)) (ELit (LInt 2024104815)) (ELit (LInt 2227730452)) (ELit (LInt 2361852424)) (ELit (LInt 2428436474)) (ELit (LInt 2756734187)) (ELit (LInt 3204031479)) (ELit (LInt 3329325298))))
(DTypeSig false "shaLabel" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "shaLabel" ((PVar "j")) (EBinOp "++" (EBinOp "++" (ELit (LString "$c")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "j")))) (ELit (LString ""))))
(DTypeSig false "sha256KLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "sha256KLines" () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  (func $mdk_sha_k (param $i i32) (result i32)"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "j")) (EBinOp "++" (EBinOp "++" (ELit (LString "    (block $c")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "-" (ELit (LInt 63)) (EVar "j"))))) (ELit (LString ""))))) (ERangeList (ELit (LInt 0)) (ELit (LInt 63)) true))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "    (br_table ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "shaLabel")) (ERangeList (ELit (LInt 0)) (ELit (LInt 63)) true)))) (ELit (LString " $c63 (local.get $i))"))))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "kc")) (EListLit (ELit (LString "    )")) (EBinOp "++" (EBinOp "++" (ELit (LString "    (return (i32.const ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "kc")))) (ELit (LString "))")))))) (EVar "sha256K"))) (EListLit (ELit (LString "  )")))))
(DTypeSig false "sha256RuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "sha256RuntimeLines" () (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "  ;; -- sha256Native (peer of medaka_rt.c mdk_sha256) --")) (ELit (LString "  (func $mdk_sha_get (param $a (ref $u8arr)) (param $i i32) (result i32)")) (ELit (LString "    (local $o i32)")) (ELit (LString "    (local.set $o (i32.shl (local.get $i) (i32.const 2)))")) (ELit (LString "    (i32.or")) (ELit (LString "      (i32.or (array.get_u $u8arr (local.get $a) (local.get $o))")) (ELit (LString "              (i32.shl (array.get_u $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 1))) (i32.const 8)))")) (ELit (LString "      (i32.or (i32.shl (array.get_u $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 2))) (i32.const 16))")) (ELit (LString "              (i32.shl (array.get_u $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 3))) (i32.const 24)))))")) (ELit (LString "  (func $mdk_sha_set (param $a (ref $u8arr)) (param $i i32) (param $v i32)")) (ELit (LString "    (local $o i32)")) (ELit (LString "    (local.set $o (i32.shl (local.get $i) (i32.const 2)))")) (ELit (LString "    (array.set $u8arr (local.get $a) (local.get $o) (local.get $v))")) (ELit (LString "    (array.set $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 1)) (i32.shr_u (local.get $v) (i32.const 8)))")) (ELit (LString "    (array.set $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 2)) (i32.shr_u (local.get $v) (i32.const 16)))")) (ELit (LString "    (array.set $u8arr (local.get $a) (i32.add (local.get $o) (i32.const 3)) (i32.shr_u (local.get $v) (i32.const 24))))"))) (EVar "sha256KLines")) (EListLit (ELit (LString "  ;; One 64-byte block of $src at $off folded into the state $h; $w is the 256-byte schedule scratch.")) (ELit (LString "  (func $mdk_sha_block (param $h (ref $u8arr)) (param $src (ref $u8arr)) (param $off i32) (param $w (ref $u8arr))")) (ELit (LString "    (local $i i32) (local $p i32) (local $x i32) (local $s0 i32) (local $s1 i32)")) (ELit (LString "    (local $a i32) (local $b i32) (local $c i32) (local $d i32) (local $e i32) (local $f i32) (local $g i32) (local $hh i32)")) (ELit (LString "    (local $t1 i32) (local $t2 i32)")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d1 (loop $l1")) (ELit (LString "      (br_if $d1 (i32.ge_u (local.get $i) (i32.const 16)))")) (ELit (LString "      (local.set $p (i32.add (local.get $off) (i32.shl (local.get $i) (i32.const 2))))")) (ELit (LString "      (call $mdk_sha_set (local.get $w) (local.get $i)")) (ELit (LString "        (i32.or")) (ELit (LString "          (i32.or (i32.shl (array.get_u $u8arr (local.get $src) (local.get $p)) (i32.const 24))")) (ELit (LString "                  (i32.shl (array.get_u $u8arr (local.get $src) (i32.add (local.get $p) (i32.const 1))) (i32.const 16)))")) (ELit (LString "          (i32.or (i32.shl (array.get_u $u8arr (local.get $src) (i32.add (local.get $p) (i32.const 2))) (i32.const 8))")) (ELit (LString "                  (array.get_u $u8arr (local.get $src) (i32.add (local.get $p) (i32.const 3))))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l1)))")) (ELit (LString "    (block $d2 (loop $l2")) (ELit (LString "      (br_if $d2 (i32.ge_u (local.get $i) (i32.const 64)))")) (ELit (LString "      (local.set $x (call $mdk_sha_get (local.get $w) (i32.sub (local.get $i) (i32.const 15))))")) (ELit (LString "      (local.set $s0 (i32.xor (i32.xor (i32.rotr (local.get $x) (i32.const 7)) (i32.rotr (local.get $x) (i32.const 18))) (i32.shr_u (local.get $x) (i32.const 3))))")) (ELit (LString "      (local.set $x (call $mdk_sha_get (local.get $w) (i32.sub (local.get $i) (i32.const 2))))")) (ELit (LString "      (local.set $s1 (i32.xor (i32.xor (i32.rotr (local.get $x) (i32.const 17)) (i32.rotr (local.get $x) (i32.const 19))) (i32.shr_u (local.get $x) (i32.const 10))))")) (ELit (LString "      (call $mdk_sha_set (local.get $w) (local.get $i)")) (ELit (LString "        (i32.add (i32.add (call $mdk_sha_get (local.get $w) (i32.sub (local.get $i) (i32.const 16))) (local.get $s0))")) (ELit (LString "                 (i32.add (call $mdk_sha_get (local.get $w) (i32.sub (local.get $i) (i32.const 7))) (local.get $s1))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l2)))")) (ELit (LString "    (local.set $a (call $mdk_sha_get (local.get $h) (i32.const 0)))")) (ELit (LString "    (local.set $b (call $mdk_sha_get (local.get $h) (i32.const 1)))")) (ELit (LString "    (local.set $c (call $mdk_sha_get (local.get $h) (i32.const 2)))")) (ELit (LString "    (local.set $d (call $mdk_sha_get (local.get $h) (i32.const 3)))")) (ELit (LString "    (local.set $e (call $mdk_sha_get (local.get $h) (i32.const 4)))")) (ELit (LString "    (local.set $f (call $mdk_sha_get (local.get $h) (i32.const 5)))")) (ELit (LString "    (local.set $g (call $mdk_sha_get (local.get $h) (i32.const 6)))")) (ELit (LString "    (local.set $hh (call $mdk_sha_get (local.get $h) (i32.const 7)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d3 (loop $l3")) (ELit (LString "      (br_if $d3 (i32.ge_u (local.get $i) (i32.const 64)))")) (ELit (LString "      (local.set $t1")) (ELit (LString "        (i32.add")) (ELit (LString "          (i32.add (local.get $hh)")) (ELit (LString "            (i32.xor (i32.xor (i32.rotr (local.get $e) (i32.const 6)) (i32.rotr (local.get $e) (i32.const 11))) (i32.rotr (local.get $e) (i32.const 25))))")) (ELit (LString "          (i32.add")) (ELit (LString "            (i32.xor (i32.and (local.get $e) (local.get $f)) (i32.and (i32.xor (local.get $e) (i32.const -1)) (local.get $g)))")) (ELit (LString "            (i32.add (call $mdk_sha_k (local.get $i)) (call $mdk_sha_get (local.get $w) (local.get $i))))))")) (ELit (LString "      (local.set $t2")) (ELit (LString "        (i32.add")) (ELit (LString "          (i32.xor (i32.xor (i32.rotr (local.get $a) (i32.const 2)) (i32.rotr (local.get $a) (i32.const 13))) (i32.rotr (local.get $a) (i32.const 22)))")) (ELit (LString "          (i32.xor (i32.xor (i32.and (local.get $a) (local.get $b)) (i32.and (local.get $a) (local.get $c))) (i32.and (local.get $b) (local.get $c)))))")) (ELit (LString "      (local.set $hh (local.get $g))")) (ELit (LString "      (local.set $g (local.get $f))")) (ELit (LString "      (local.set $f (local.get $e))")) (ELit (LString "      (local.set $e (i32.add (local.get $d) (local.get $t1)))")) (ELit (LString "      (local.set $d (local.get $c))")) (ELit (LString "      (local.set $c (local.get $b))")) (ELit (LString "      (local.set $b (local.get $a))")) (ELit (LString "      (local.set $a (i32.add (local.get $t1) (local.get $t2)))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l3)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 0) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 0)) (local.get $a)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 1) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 1)) (local.get $b)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 2) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 2)) (local.get $c)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 3) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 3)) (local.get $d)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 4) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 4)) (local.get $e)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 5) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 5)) (local.get $f)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 6) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 6)) (local.get $g)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 7) (i32.add (call $mdk_sha_get (local.get $h) (i32.const 7)) (local.get $hh))))")) (ELit (LString "  (func $mdk_sha256 (param $b (ref $u8arr)) (result (ref $u8arr))")) (ELit (LString "    (local $n i32) (local $full i32) (local $rem i32) (local $size i32) (local $i i32) (local $x i32)")) (ELit (LString "    (local $h (ref $u8arr)) (local $w (ref $u8arr)) (local $tail (ref $u8arr)) (local $out (ref $u8arr)) (local $bits i64)")) (ELit (LString "    (local.set $n (array.len (local.get $b)))")) (ELit (LString "    (local.set $h (array.new $u8arr (i32.const 0) (i32.const 32)))")) (ELit (LString "    (local.set $w (array.new $u8arr (i32.const 0) (i32.const 256)))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 0) (i32.const 1779033703))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 1) (i32.const -1150833019))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 2) (i32.const 1013904242))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 3) (i32.const -1521486534))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 4) (i32.const 1359893119))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 5) (i32.const -1694144372))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 6) (i32.const 528734635))")) (ELit (LString "    (call $mdk_sha_set (local.get $h) (i32.const 7) (i32.const 1541459225))")) (ELit (LString "    (local.set $full (i32.shr_u (local.get $n) (i32.const 6)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d (loop $l")) (ELit (LString "      (br_if $d (i32.ge_u (local.get $i) (local.get $full)))")) (ELit (LString "      (call $mdk_sha_block (local.get $h) (local.get $b) (i32.shl (local.get $i) (i32.const 6)) (local.get $w))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))")) (ELit (LString "    (local.set $rem (i32.and (local.get $n) (i32.const 63)))")) (ELit (LString "    (local.set $size (select (i32.const 64) (i32.const 128) (i32.le_u (i32.add (local.get $rem) (i32.const 9)) (i32.const 64))))")) (ELit (LString "    (local.set $tail (array.new $u8arr (i32.const 0) (i32.const 128)))")) (ELit (LString "    (array.copy $u8arr $u8arr (local.get $tail) (i32.const 0) (local.get $b) (i32.shl (local.get $full) (i32.const 6)) (local.get $rem))")) (ELit (LString "    (array.set $u8arr (local.get $tail) (local.get $rem) (i32.const 128))")) (ELit (LString "    (local.set $bits (i64.shl (i64.extend_i32_u (local.get $n)) (i64.const 3)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d4 (loop $l4")) (ELit (LString "      (br_if $d4 (i32.ge_u (local.get $i) (i32.const 8)))")) (ELit (LString "      (array.set $u8arr (local.get $tail) (i32.sub (i32.sub (local.get $size) (i32.const 1)) (local.get $i))")) (ELit (LString "        (i32.wrap_i64 (i64.shr_u (local.get $bits) (i64.extend_i32_u (i32.shl (local.get $i) (i32.const 3))))))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l4)))")) (ELit (LString "    (call $mdk_sha_block (local.get $h) (local.get $tail) (i32.const 0) (local.get $w))")) (ELit (LString "    (if (i32.eq (local.get $size) (i32.const 128))")) (ELit (LString "      (then (call $mdk_sha_block (local.get $h) (local.get $tail) (i32.const 64) (local.get $w))))")) (ELit (LString "    (local.set $out (array.new $u8arr (i32.const 0) (i32.const 32)))")) (ELit (LString "    (local.set $i (i32.const 0))")) (ELit (LString "    (block $d5 (loop $l5")) (ELit (LString "      (br_if $d5 (i32.ge_u (local.get $i) (i32.const 8)))")) (ELit (LString "      (local.set $x (call $mdk_sha_get (local.get $h) (local.get $i)))")) (ELit (LString "      (array.set $u8arr (local.get $out) (i32.shl (local.get $i) (i32.const 2)) (i32.shr_u (local.get $x) (i32.const 24)))")) (ELit (LString "      (array.set $u8arr (local.get $out) (i32.add (i32.shl (local.get $i) (i32.const 2)) (i32.const 1)) (i32.shr_u (local.get $x) (i32.const 16)))")) (ELit (LString "      (array.set $u8arr (local.get $out) (i32.add (i32.shl (local.get $i) (i32.const 2)) (i32.const 2)) (i32.shr_u (local.get $x) (i32.const 8)))")) (ELit (LString "      (array.set $u8arr (local.get $out) (i32.add (i32.shl (local.get $i) (i32.const 2)) (i32.const 3)) (local.get $x))")) (ELit (LString "      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l5)))")) (ELit (LString "    (local.get $out))")))))
(DTypeSig true "charFromCodeRuntimeLines" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "charFromCodeRuntimeLines" () (EListLit (ELit (LString "  ;; -- W11b charFromCode (byte-identical to medaka_rt.c mdk_char_from_code) --")) (ELit (LString "  (func $mdk_char_from_code (param $cp i32) (result (ref eq))")) (ELit (LString "    ;; valid: 0 <= cp <= 0x10FFFF and not (0xD800 <= cp <= 0xDFFF).")) (ELit (LString "    (if (i32.and (i32.and (i32.ge_s (local.get $cp) (i32.const 0)) (i32.le_s (local.get $cp) (i32.const 1114111)))")) (ELit (LString "                 (i32.eqz (i32.and (i32.ge_s (local.get $cp) (i32.const 55296)) (i32.le_s (local.get $cp) (i32.const 57343)))))")) (ELit (LString "      (then (return (struct.new $C_Some (i32.const 0) (ref.i31 (local.get $cp))))))")) (ELit (LString "    (ref.i31 (i32.const 1)))"))))
(DTypeSig true "plannedImportLines" (TyFun (TyApp (TyCon "List") (TyCon "PlannedImport")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "plannedImportLines" () (EApp (EMethodRef "map") (ELam ((PVar "imp")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  (import \"")) (EApp (EMethodRef "display") (EFieldAccess (EVar "imp") "namespace"))) (ELit (LString "\" \""))) (EApp (EMethodRef "display") (EFieldAccess (EVar "imp") "field"))) (ELit (LString "\" (func $"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "imp") "watSymbol"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EFieldAccess (EVar "imp") "signature"))) (ELit (LString "))"))))))
(DTypeSig true "plannedHelperLines" (TyFun (TyCon "WasmDemandPlan") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "plannedHelperLines" ((PVar "plan") (PVar "files")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "name")) (EIf (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (EVar "name")) (EApp (EApp (EApp (EVar "plannedHelperBlock") (EVar "plan")) (EVar "files")) (EVar "name")) (EListLit)))) (EVar "helperOrder")))
(DTypeSig false "plannedHelperBlock" (TyFun (TyCon "WasmDemandPlan") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "closApplyLines"))) (EVar "closApplyLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioRuntimeLines"))) (EVar "ioRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioStrRuntimeLines"))) (EVar "ioStrRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strLeafRuntimeLines"))) (EVar "strLeafRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strConcatRuntimeLines"))) (EVar "strConcatRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "appendRuntimeLines"))) (EVar "appendRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueEqRuntimeLines"))) (EApp (EVar "valueEqRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueAddRuntimeLines"))) (EApp (EVar "valueAddRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueSubRuntimeLines"))) (EApp (EVar "valueSubRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueMulRuntimeLines"))) (EApp (EVar "valueMulRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueDivRuntimeLines"))) (EApp (EVar "valueDivRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueModRuntimeLines"))) (EApp (EVar "valueModRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "valueCmpNumRuntimeLines"))) (EApp (EVar "valueCmpNumRuntimeLines") (EApp (EApp (EVar "Wide64W") (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "u64RuntimeLines")))) (EApp (EApp (EVar "hasWasmHelper") (EVar "plan")) (ELit (LString "i64RuntimeLines"))))))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "u64RuntimeLines"))) (EVar "u64RuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "i64RuntimeLines"))) (EVar "i64RuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "stderrRuntimeLines"))) (EVar "stderrRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "rngRuntimeLines"))) (EVar "rngRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "hashRuntimeLines"))) (EVar "hashRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "hashStringRuntimeLines"))) (EVar "hashStringRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "floatRemRuntimeLines"))) (EVar "floatRemRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "floatRuntimeLines"))) (EVar "floatRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "hashFloatRuntimeLines"))) (EVar "hashFloatRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "randomFloatRuntimeLines"))) (EVar "randomFloatRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "floatStrLines"))) (EVar "floatStrLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strSearchRuntimeLines"))) (EVar "strSearchRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strToIntRuntimeLines"))) (EVar "strToIntRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strReverseRuntimeLines"))) (EVar "strReverseRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strJoinRuntimeLines"))) (EVar "strJoinRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "strCodecRuntimeLines"))) (EVar "strCodecRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "byteBlockRuntimeLines"))) (EVar "byteBlockRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "charFromCodeRuntimeLines"))) (EVar "charFromCodeRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "charClassRuntimeLines"))) (EVar "charClassRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioPushPathLines"))) (EVar "ioPushPathLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioPushPathMoreLines"))) (EVar "ioPushPathMoreLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioPushGrantLines"))) (EVar "ioPushGrantLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioPushGrantMoreLines"))) (EVar "ioPushGrantMoreLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioResultLines"))) (EVar "ioResultLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioRefusedPanicLines"))) (EVar "ioRefusedPanicLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioReadFileLines"))) (EVar "ioReadFileLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioFetchTextLines"))) (EVar "ioFetchTextLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioFileExistsLines"))) (EVar "ioFileExistsLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioCanonicalizeLines"))) (EVar "ioCanonicalizeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioWriteFileLines"))) (EVar "ioWriteFileLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioAppendFileLines"))) (EVar "ioAppendFileLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioRenameLines"))) (EVar "ioRenameLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioListDirLines"))) (EVar "ioListDirLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioStatFileLines"))) (EVar "ioStatFileLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioMakeDirLines"))) (EVar "ioMakeDirLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioRemoveFileLines"))) (EVar "ioRemoveFileLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioRemoveDirLines"))) (EVar "ioRemoveDirLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioFsyncLines"))) (EVar "ioFsyncLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioFileModeLines"))) (EVar "ioFileModeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioWriteFileModeLines"))) (EVar "ioWriteFileModeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioGetEnvLines"))) (EVar "ioGetEnvLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioReadLineLines"))) (EVar "ioReadLineLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioReadAllLines"))) (EVar "ioReadAllLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioReadExactlyLines"))) (EVar "ioReadExactlyLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioExecutablePathLines"))) (EVar "ioExecutablePathLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "jsffiArrayLines"))) (EVar "jsffiArrayLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "jsffiResultStrLines"))) (EVar "jsffiResultStrLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "ioArgsLines"))) (EVar "ioArgsLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "utf8LossyRuntimeLines"))) (EVar "utf8LossyRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "writeFileBytesLines"))) (EVar "writeFileBytesLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "osEntropyLines"))) (EVar "osEntropyLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "readFileBytesLines"))) (EVar "readFileBytesLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "trapIntRuntimeLines"))) (EVar "trapIntRuntimeLines"))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "intRuntimeLines"))) (EApp (EVar "intRuntimeLines") (EFieldAccess (EVar "plan") "intHelpers")))
(DFunDef false "plannedHelperBlock" ((PVar "plan") (PVar "files") (PLit (LString "siteRuntimeLines"))) (EApp (EApp (EVar "siteRuntimeLines") (EVar "files")) (EFieldAccess (EVar "plan") "nonexhaustiveRuntime")))
(DFunDef false "plannedHelperBlock" (PWild PWild (PVar "name")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "internal error: unplanned-wasm-helper: ")) (EVar "name"))))
