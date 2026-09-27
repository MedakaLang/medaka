# The integer stack

Status: N1 BUILT (the tagged tier: `U8`/`U16`/`U32`, their modules, the literal
range check and literal patterns). N2 BUILT (a byte is a `U8` in `bytes`,
`mut_bytes`, `bytebuilder` and `byteparser`; SHA-256, HMAC, the PBKDF2 block
index, CRC-32 and the property runner's `fmix32` on `U32`). N3 BUILT (boxed
`U64` on all three engines, wide literals, the `u64` module with `mulWide`,
`addCarry` and `subBorrow`, `bits64` retired, the multi-byte codecs typed).
N4 BUILT (the `Hashable` folds and field/scalar on `U64`, `checkedAdd`,
`checkedSub` and `checkedMul`, and `Int` overflow trapping on all three
engines). N5 BUILT (on the LLVM backend, `U64` and `U32` cross `let`,
parameter and result in registers, `U32` is computed as native `i32`, and
field/scalar are re-limbed). N6 BUILT (`I32` and `I64` on all three
engines with the `i32` and `i64` modules, every fixed-width type crossing the
FFI as its C twin, and `sqlite/` reading SQLite's full 64-bit `INTEGER`).
Epic #3417; milestones N1–N6.
Every ruling in this document was taken by Val on 2026-09-24. Child issues
cite its sections rather than restating them.

## 1. Why now

Medaka has one integer type. `Int` is a 63-bit tagged immediate
(`runtime/medaka_rt.c` tags it as `(n << 1) | 1`; `docs/spec/SYNTAX.md`
documents the range), and its arithmetic wraps. Three lines of work have
hit that wall in the same month:

- **Bytes.** The Bytes epic (#3134) types a byte string but hands out `Int`
  for a byte, so five doors into the byte domain each re-check `0..255`
  and `elemIndex 300 b` is a silent `None`. Val ruled on 2026-09-24 that a
  byte is a `U8` (#3415), a member of a fixed-width family this document
  defines.
- **Crypto.** `stdlib/crypto/sha256.mdk` simulates 32-bit words with a mask
  after every operation; the `bits64` stdlib module (retired in N3)
  simulated a 64-bit word with four 16-bit limbs in a heap cell; `pds/lib/scalar.mdk` multiplies 16
  limbs of 16 bits because a 63-bit `Int` has no widening multiply. The
  KDF work (#3373) measured what real 32-bit lowering buys: about 1.3× on
  the SHA-256 round, with larger wins expected from 64-bit limbs.
- **Overflow.** #3377 reverses the 2026-07-15 "`Int` wraps by design"
  ruling: `Int` will trap. The code that legitimately wants modular
  arithmetic (hashes, RNGs, binary formats) needs a home first, or the
  flip breaks it.

One design answers all three, and the dependencies fix the order: the
tagged types first, `U64` second, the trap last.

## 2. The stack

| Type | Width | Runtime representation | Arithmetic | Milestone |
|---|---|---|---|---|
| `Int` | 63, signed | tagged immediate, unchanged | **traps** (N4; it wrapped before) | N4 |
| `U8` `U16` `U32` | 8 / 16 / 32, unsigned | tagged immediate, distinct static type; no runtime or GC change | **wraps** modulo 2^n | N1 |
| `U64` | 64, unsigned | boxed cell, the `Float` shape; on the LLVM backend a raw register across `let`, parameter and result where the static type is known (N5) | wraps | N3, N5 |
| `I32` `I64` | 32 / 64, signed | `I32` as `U32` (tagged, held sign-extended); `I64` as `U64` (boxed, its own header) | wraps | N6 |
| bignum | arbitrary | non-goal | | |

**The rule.** `Int` is the *arithmetic* type and traps. The `U` types are
the *bit-pattern* types and wrap. Crossing *into* a `U` type never wraps
silently: a ground literal out of range is a compile error, `fromInt`
panics at runtime, and `truncate` is the only masking door and is named
for it.

`Int` stays 63-bit. The docs say in one line that it is neither `I64` nor
`U64`.

### 2.1 Why the whole family wraps, including `U8`

The alternative is Swift's: every type traps and wrapping is spelled per
operation (`&+`). That makes the U types a second trapping family with a
per-operation opt-out, and the customers here (a hash round, a limb
multiply) would write the opt-out on every operation. The type is already
the opt-out. A mixed table (`U8` traps, `U32` wraps) is one nobody
memorises, and the argument that byte arithmetic rarely wants `255 + 1 ==
0` applies equally to `U32` outside crypto. One rule for the family.

### 2.2 Why unsigned first

Every customer in section 1 is unsigned. The signed types have one named
motivation, FFI `int32_t`/`int64_t`, and two latent ones (`sqlite/`
stores SQLite's int64 `INTEGER` in 63 bits; `stdlib/json.mdk` parses
integers with no overflow check). None has a caller today. The names are
reserved so nothing else takes them; the semantics are the U family's with
a sign.

## 3. Literals and `Num`

This is the load-bearing section. The family must not break the literal
route, and the literal route must not become a silent-wrap door.

### 3.1 What exists

Every integer literal is modelled as `fromInt n` with a `Num a` obligation
(`compiler/types/typecheck.mdk`, the `ENumLit` arm; the route is described
in the comment above `setNumlitFloats`). After inference, a literal whose
type variable grounded to `Int` becomes a plain `Int` literal, one grounded
to `Float` becomes a float literal, and one still polymorphic keeps its
`fromInt` route through the enclosing `Num` dictionary (this is how
`sum`'s `fromInt 0` works). An ambiguous literal defaults to `Int`.

Probed on 2026-09-24 at `d0f98e709` with a user `newtype W = W Int` and an
`impl Num W`: `f 5` where `f : W -> Int`, `-2`, `w + 1`, and `sum [1, 2,
3]` all resolve to `W`. An integer literal also lands in `Float` position
(`half 5` where `half : Float -> Float`).

Pattern literals are not polymorphic: `inferPat` gives a literal pattern
`litType`, which is `Int` for an integer literal, so `match w` with an arm
`10 =>` on `W` is `Type mismatch: Int vs W` (probed).

The literal-overflow check is in the lexer (`compiler/frontend/lexer.mdk`,
magnitude at most 2^62, `L-INT-OVERFLOW`), and the AST's `LInt` carries a
Medaka `Int`. The compiler is itself 63-bit, so `LInt` physically cannot
hold a 64-bit literal.

The arithmetic operators are builtin for `Int` and `Float` only; on every
other type `+` dispatches to `Num.add` (`stdlib/core.mdk`, the `Num`
interface's doc comment). That is a call per operation.

### 3.2 What changes

1. **The model does not change.** A literal stays `fromInt n : Num a => a`.
   Each U type gets a `Num` impl, so `emitU8 65`, `x + 1 : U32` and
   `sum ws : U64` compile exactly as they would for a user newtype today.
   No literal suffixes, no new literal syntax for the tagged tier.

2. **A compile-time range check** hooks the existing post-inference
   grounding pass, where the literal's ground type is known. A literal
   grounded to `U8` whose value is outside `0..255` is an `L-INT-OVERFLOW`
   error naming the type and its range:

   ```medaka-nocheck: illustrates the diagnostic a U8 literal out of range produces; U8 does not exist yet
   x : U8
   x = 300
   -- error: integer literal 300 does not fit U8 (0..255)  [L-INT-OVERFLOW]
   ```

   `-2` in `U8` position hits the same check: the parser already fuses an
   adjacent `-` and digits into one negative literal (`docs/spec/SYNTAX.md`).

3. **A polymorphic literal at runtime** (`fromInt 0` inside `sum`, or any
   `fromInt` on a computed value) cannot be checked statically. So `Num
   U*.fromInt` is a *checked narrowing*: it panics out of range, and the
   message names the value and the type. `emitU8 300` is refused today; it
   stays refused on both paths, which is the W-QUIETER guarantee #3415
   demands.

4. **Wide literals** are N3 work. A `U64` program needs to write
   `0x9E3779B97F4A7C15`, and neither the lexer's cap nor `LInt` can carry
   it. The lexer keeps the digit text it already has and mints a
   wide-literal form that only a `U64` (later `I64`) ground type accepts;
   grounded to `Int` it is rejected exactly as today. This is a new AST
   constructor, so every `_ =>` arm over literals is audited as a set
   (`AGENTS.md`, `[T-GLOBAL-TABLE]`).

   As built: the lexer mints a wide token for a magnitude from `2^62 + 1` to
   `2^64 - 1` and refuses anything larger; the parser builds `EWideLit` (the
   value's two 32-bit halves and the lexeme), and a positive `2^62` in an
   expression, which the lexer admits as an `Int` so that `-2^62` stays
   writable, becomes the wide literal it spells. The typechecker infers a
   wide literal exactly as an ordinary one and accepts it only where its type
   grounded to `U64` (`checkWideLiterals`); every other ground type, a type
   still polymorphic at the module's end, and a negated wide literal are
   `L-INT-OVERFLOW`. A literal grounded to `U64`, wide or not, is rewritten
   to the constant `LU64 hi lo`, which is all the engines see.

5. **Pattern literals** become typed by the scrutinee among the *builtin*
   integer heads only (`Int`, `U8`, `U16`, `U32`, `U64`). A literal
   pattern on a builtin integer is a constant compare and needs no `Eq`
   dispatch; with no scrutinee information it defaults to `Int`. The same
   range check applies, so an arm `300 =>` on a `U8` is a compile error,
   not a dead arm. Exhaustiveness treats a fixed-width literal as it treats
   an `Int` literal today. User `Num` newtypes still do not get literal
   patterns; that is a separate feature with a different mechanism.

   As built, `U64` is the exception: no engine's matcher compares a boxed
   cell against a constant, so a literal pattern whose scrutinee is a `U64`
   is refused at compile time (`a literal pattern cannot match a U64`, with
   a guard as the fix) rather than compiled to an arm that never matches.

6. **The operators join the builtin set** for the U types. The typechecker
   already records which builtin operation an operator resolved to (`Int`
   or `Float`); the family extends that set, and the emitter lowers each
   directly and branch-free. `Num U32` delegates to the builtins exactly as
   `Num Int` does. This is what makes `U32` in a SHA-256 round the measured
   1.3× rather than a dictionary call per operation.

7. **Defaulting does not change.** An ambiguous literal is an `Int`.

## 4. Semantics per type

For a U type of width n, with values in `0 .. 2^n - 1`:

| Operation | Result |
|---|---|
| `+` `-` `*` | modulo 2^n, no diagnostic |
| `/` `%` | unsigned truncating division and remainder; divisor 0 panics, as `Int` |
| `negate x` | `2^n - x` modulo 2^n (two's complement); `negate 0 == 0` |
| `abs x`, `signum x` | `x`, and `0` or `1`; they exist because `Num` has them |
| `shiftLeft x k`, `shiftRight x k` | `k >= n` gives 0 (Go's rule, one branch-free select); `k < 0` panics |
| `rotateLeft x k`, `rotateRight x k` | `k` taken modulo n |
| `bitNot x` | complement within n bits |
| `compare`, `==` | unsigned order; `Ord` and `Eq` agree with each other and with `Hashable` |
| `minBound`, `maxBound` | `0` and `2^n - 1` |
| `Display`, `Debug` | decimal; hex is an explicit conversion |

For `I32` and `I64`, with values in `-2^(n-1) .. 2^(n-1) - 1` (N6; Val,
2026-09-26):

| Operation | Result |
|---|---|
| `+` `-` `*` | modulo 2^n in two's complement, no diagnostic |
| `/` `%` | truncating toward zero, as C and `Int` do (`-7 / 2 == -3`, `-7 % 2 == -1`); `minBound / -1 == minBound` and `minBound % -1 == 0`; divisor 0 panics, as `Int` |
| `negate x`, `abs x` | wrap: `negate minBound == abs minBound == minBound` |
| `signum x` | `-1`, `0` or `1` |
| `shiftLeft x k` | `k >= n` gives 0; the bits shifted past the sign bit are discarded; `k < 0` panics |
| `shiftRight x k` | arithmetic (copies the sign); `k >= n` gives 0 or `-1`; `k < 0` panics |
| `compare`, `==` | signed order; `Ord`, `Eq` and `Hashable` agree |
| `minBound`, `maxBound` | `-2^(n-1)` and `2^(n-1) - 1` |
| `Display`, `Debug` | decimal with a `-` |

`Int`'s `intMinBound / -1` traps (N4) where `I32`'s and `I64`'s wrap: the
signed fixed-width types are bit-pattern types like the U family, and the rule
of §2 is that the family wraps.

Shifting by the width gives 0 rather than masking the amount because a
masked amount is silent wrongness (`shiftLeft x 40` on a `U32` would mean
`shiftLeft x 8`), and the select it costs is one instruction that folds
away on a constant amount, which is every amount a hash round uses.

`Int`'s own shifts were C-undefined for an amount of 64 or more. N4 defines
them: an amount of 63 or more shifts every bit out (`shiftLeft` gives `0`,
`shiftRight` gives `0` or, for a negative value, `-1`), a negative amount
panics as it does for the U types, `shiftLeft` discards the bits shifted past
bit 62 rather than trapping, and `shiftRight` is arithmetic on every engine
(Wasm's was logical, so the engines disagreed on a negative operand).

## 5. The surface

Each type is a builtin head, registered where `Int` and `ByteBlock` are
(`primitiveTypes` in `compiler/frontend/resolve.mdk`), because the
typechecker's range check, the pattern-literal rule and the emitter all
need to recognise it by name. Its operations and impls live in a stdlib
module named for it: `u8`, `u16`, `u32`, `u64`, imported as `import u32 as
U32`. This is the stdlib's module-per-type convention (`map`, `set`,
`vector`, `bytes`), and it gives every operation a short qualified name
without a width suffix.

Impls reach an importer transitively (probed 2026-09-24: `main` imports
only `B`; `B` imports `A`, which defines the type and its impls; `a + b`
and `a == b` in `main` dispatch). So `bytes` importing `u8` is enough for
every `Bytes` user; nothing goes in the prelude.

The vocabulary is the same in every module. For `U32`:

```medaka-nocheck: a signature listing for a module that does not exist yet
-- Num method: checked narrowing, panics out of range (section 3.2, item 3)
fromInt      : Int -> U32
-- the refusing door
tryFromInt   : Int -> Option U32
-- the masking door: the ONLY silent narrowing, branch-free
truncate     : Int -> U32
-- widening, total (U64.toInt is the exception, section 5.1)
toInt        : U32 -> Int
-- within the family: widening is total, narrowing is spelled truncate
fromU8       : U8 -> U32
fromU16      : U16 -> U32
truncateU64  : U64 -> U32
-- bit operations, the prelude's spellings for Int
bitAnd bitOr bitXor : U32 -> U32 -> U32
bitNot       : U32 -> U32
shiftLeft shiftRight rotateLeft rotateRight : U32 -> Int -> U32
popCount leadingZeros trailingZeros : U32 -> Int
-- bytes
toBytesBE toBytesLE : U32 -> Bytes
fromBytesBE fromBytesLE : Bytes -> Option U32
-- rendering
toHex        : U32 -> String
```

with impls `Eq`, `Ord`, `Num`, `Bounded`, `Hashable`, `Display`, `Debug`. `fromInt`
is the `Num` method rather than a module function, so it is written `fromInt n`
(checked at the type the context gives it), never `U32.fromInt n`.

### 5.0 The signed modules (N6)

`i32` and `i64` (`import i64 as I64`) keep §5's vocabulary where a sign changes
nothing and leave out what belongs to bit patterns: rotations, bit counts, byte
codecs, `toHex` and `mulWide` stay on the U types, reached through `fromBits`
and `toBits`, which keep the bits and change how they are read (Val,
2026-09-26).

```medaka-nocheck: a signature listing
-- i32
tryFromInt   : Int -> Option I32
truncate     : Int -> I32         -- the masking door, low 32 bits
toInt        : I32 -> Int         -- total
fromU8       : U8 -> I32
fromU16      : U16 -> I32
truncateI64  : I64 -> I32
fromBits     : U32 -> I32
toBits       : I32 -> U32
bitAnd bitOr bitXor : I32 -> I32 -> I32
bitNot       : I32 -> I32
shiftLeft shiftRight : I32 -> Int -> I32
-- i64
toInt        : I64 -> Option Int  -- narrowing, as U64.toInt
fromU8 fromU16 fromU32 fromI32 : … -> I64
fromBits     : U64 -> I64
toBits       : I64 -> U64
bitAnd bitOr bitXor : I64 -> I64 -> I64
bitNot       : I64 -> I64
shiftLeft shiftRight : I64 -> Int -> I64
```

with impls `Eq`, `Ord`, `Num`, `Bounded`, `Hashable`, `Display`, `Debug` in the
modules themselves: nothing in the prelude uses a signed type, so unlike `Num
U64` none of them is in `core.mdk`. Every `Int` fits an `I64`, so `I64` has no
`tryFromInt` or `truncate` and its `fromInt` never panics. `Hashable I32` is
the hash of `toInt`, and `Hashable I64` the hash of `toBits`, so a signed value
in `Int`'s range hashes as that `Int` does. `I64.toIntTruncating` was left out:
nothing calls it.

The literal route is §3's. A literal grounded to `I32` is range-checked and is
its word; `-2147483648` folds to the constant. A wide literal is accepted at
`I64` up to `2^63 - 1`, and `-` applied to one down to `-2^63`:
`-9223372036854775808` is two tokens the parser reads as the negation of the
wide literal 2^63, whose `I64` bit pattern negates, wrapping, to `minBound`. A
literal pattern is typed by an `I32` scrutinee (a negative literal arm does not
parse for any integer type, `I32` included); on an `I64` it is refused as on a
`U64`, and #3455 stays open for both.

### 5.1 `U64`'s asymmetry

`U64 -> Int` is a narrowing, since `Int` holds 63 bits. `U64.toInt` is
therefore `U64 -> Option Int`, and the masking form is `U64.toIntTruncating`,
which keeps the low 63 bits (bit 62 becomes the sign). This was the one
conversion name this document left for the N3 packet to confirm; the earlier
draft's `truncateToInt` has the `xToY` shape that stdlib rule 8 reserves for
`runtime.mdk` primitives, and Val confirmed `toIntTruncating` on 2026-09-25.

`U64` also carries the limb vocabulary, which is what lets
`pds/lib/scalar.mdk` go from 16 limbs to 4:

```medaka-nocheck: a signature listing for a module that does not exist yet
mulWide   : U64 -> U64 -> (U64, U64)     -- (high, low)
addCarry  : U64 -> U64 -> Bool -> (U64, Bool)
subBorrow : U64 -> U64 -> Bool -> (U64, Bool)
```

`U32.mulWide : U32 -> U32 -> U64` exists for the same reason.

### 5.2 What `Int` gains

`checkedAdd`, `checkedSub`, `checkedMul : Int -> Int -> Option Int`, for
input validation (a declared frame length, #2905). `Int` does **not** gain
`wrappingAdd` and friends: the U types are the opt-out, and the two wrap
dependents the trapping census found are 32- and 64-bit code that belongs
on them.

### 5.3 Declined

- **A `Bits` interface in tier 1.** The hot paths are monomorphic and want
  direct lowering; an interface method is a dictionary call unless the
  call site resolves statically, and whether it does is an open question
  in #3377. Per-type functions first. An interface can be layered on top
  when a polymorphic consumer appears, with the per-type functions as its
  impl bodies.
- **Literal suffixes** (`5u32`). The `fromInt` route already types a
  literal by context.
- **A bespoke `Byte`.** Ruled out in #3415.
- **Bignum.** A different design with a different customer (#435 lists it).

## 6. Representation per engine

### 6.1 `U8`, `U16`, `U32`

Tagged immediates, the same word as an `Int`. The static type is the only
difference. The interpreter needs no new `Value` constructor; the
typechecker's operator stamp tells each engine which width to wrap at. On
the LLVM backend an operation is the `Int` untag/op/retag sequence plus a
mask, or, once the emitter reads scalar types from Core IR (#353), a native
`i32` operation with `llvm.fshl`/`llvm.fshr` for the rotates. On Wasm the
same, with the caveat that #2360's boxing applies and a `U32` above 2^30
does not fit an `i31`.

As built (N5), on the LLVM backend: a `U32` stays Int's tagged word at every
uniform boundary (a closure, an array slot, a polymorphic call), and inside
code whose type is known it is an `i32`.  An expression computes on `i32`
registers, so `+`, `-` and `*` wrap by themselves and need no mask; a `let`
keeps the `i32`; an annotated function whose signature names `U32` passes it
as an `i32` to and from its raw worker (see §6.2); and a saturated call of a
small non-recursive `U32` function, which covers the `u32` module's
operations, is inlined where it is emitted, so a rotate by a constant amount
reaches LLVM as the shift pair it turns into one rotate instruction.  The
word is truncated once where it enters and zero-extended and retagged once
where it leaves.  Wasm is unchanged: #2360 stays its own issue, since Wasm
treats representation as a whole-program property (Val, 2026-09-26).

### 6.2 `U64`

A 64-bit value does not fit a tagged word. N3 lands it **boxed**, in the
cell shape `Float` already uses on both native and Wasm, with the same
emitter paths that unbox a `Float` for arithmetic. That is correct and
already faster than a five-word `data U64` cell plus sixteen multiplies.
Unboxing in monomorphic code is N5; it is a performance step, not a
correctness one, and `U64` does not wait for it.

The interpreter, `compiler/eval/eval.mdk`, is a Medaka program compiled
with a 63-bit `Int`, so it cannot hold a native `U64` until the emitter
that compiles it supports one. It carries a `U64` as two `Int` halves
until then, and can do so indefinitely; interpreter speed is not this
epic's goal.

As built: the native cell is `{ header, payload }` with the reserved
composite header `MDK_TAG(5, 0)` (the byte block's is slot 4), so the
runtime's type-lost equality and ordering tell it from a `Float`; the
interpreter's value is `VU64 hi lo` with its arithmetic in
`compiler/eval/u64_halves.mdk`. Arithmetic and comparisons at `U64` are
builtin operators stamped `RScalar "U64"`; the rest of the `u64` module is
Medaka over eight kernel externs (`u64Truncate`, `u64TruncateToInt`, the
three bitwise operations, the two shifts and `u64MulHigh`). The compiler's own source adopts `U64` only after emitter
support has landed and the seed has been re-minted twice, the ratchet B2
used for `ByteBlock` (`docs/design/BYTES-DESIGN.md`).

As built (N5), on the LLVM backend, and as the scalar slice of #353 rather
than all of it (Val, 2026-09-26): `Float` keeps its own heuristics, and the
backend-neutral runtime-type stamps #353 describes remain its scope.

- A `let` whose value is statically `U64` holds the raw 64-bit payload, and
  is boxed where it escapes (printed, stored, captured, passed to a
  polymorphic function).  A value that would be boxed more than once in its
  scope is boxed once at the binding instead.
- An annotated single-clause function whose declared signature names `U64`
  or `U32` gets a raw worker, `@mdk_<f>__rw`: those parameters and that
  result cross the call as payloads (`U32` as `i32`), and a tail self-call is
  a loop on registers.  A `U64` parameter is raw only where no occurrence in
  the body would box it, so a value that only passes through stays a cell.  A
  result is raw only where every tail call stays one: a self-call through
  `if`, `let`, a block or a two-arm literal `match`, or a call of a worker
  with the same raw result.  A self-call in any other `match` arm, or a tail
  call of an ordinary function, keeps a word result, emitted as the uniform
  define is, so a deep recursion loops exactly where it did before.
  `@mdk_<f>` remains the uniform entry for closures and partial application,
  a wrapper around the worker.  The positions come from the declared
  signature, which the typechecker checked, never from a guess.
- `let (h, l) = U64.mulWide a b`, and a destructuring `let` of any small
  single-clause function whose body ends in a tuple, is inlined: the
  components are bound in registers and no tuple is allocated.
- Multi-clause functions, lambdas and dictionary-polymorphic functions still
  box a `U64` at their boundary, and a `U64` in an array, tuple, list or
  record is a cell.  That is why field/scalar store limbs as `Int` (§9).

### 6.3 The FFI

`ffiCrossableTy` in `compiler/types/typecheck.mdk` admits `Int`, `Float`,
`Bool`, `Char`, `String`, `Unit` and `Array Int`. The U types cross as
`uint8_t`, `uint16_t`, `uint32_t`, `uint64_t` in N6, with `I32`/`I64` as
`int32_t`/`int64_t`; `Array Int` stays the crossable sequence type.

As built (N6): the contract is `compiler/FFI-ABI.md` §2.1b. A narrow argument
is truncated to its C width with the extension written as LLVM's
`zeroext`/`signext` attribute, a narrow result is read at its width and extended
in the emitted code, and `U64`/`I64` cross as their payloads. No check is needed
at the boundary in either direction: the declared type is the range. The same
work closed #3477: an `int64_t` returned into `Int` outside 63 bits used to lose
its top bit at exit 0, and now stops the program, naming `I64` as the
declaration that receives it. Wasm refuses user foreign declarations, as before.

### 6.4 `I32` and `I64` (N6)

`I32` is `U32`'s representation with a sign: `Int`'s tagged word holding the
value sign-extended, so the word compare is its order, `toInt` is the identity
and an in-range literal is a plain `Int` literal. An arithmetic result is
sign-extended from bit 31. `I64` is `U64`'s cell with its own header, so nothing
type-lost (the runtime's polymorphic equality, ordering, printing and `Num`
paths, Wasm's `$i64`, the interpreter's `VI64`) can read one as the other; the
interpreter keeps `U64`'s two halves and reads the top bit as the sign.

## 7. Constant time

The wrapping operations are branch-free by construction. That is the
reason secret-bearing arithmetic must move to the U types **before** `Int`
traps: a trapping add is an add plus a branch on the overflow flag, and on
a secret-derived operand that branch is a secret-dependent jump, which
#3361's taint check and the IR-level gates would flag.

Two rules join `docs/design/ATPROTO-PDS-CONSTANT-TIME.md` in N4:

- A secret-derived value narrows through `truncate`, never through
  `fromInt` or `tryFromInt`: the checked doors are branches.
- A shift amount is never secret-derived. This already holds; the `k >= n`
  select makes it a rule.

## 8. Interaction with the `Int` trap (#3377)

#3377's own plan is steps 2–5 of this epic's N4. Its step 1, "fixed-width
wrapping types, design doc first", is this document. Its open decisions
are closed here: unsigned first with signed reserved (2.2); shift by the
width gives 0 (4); per-type functions rather than a `Bits` interface (5.3);
no wrapping operations on `Int` (5.2).

As built: `+`, `-`, `*`, negation and `/` (only `intMinBound / -1`) whose
result is outside `Int`'s range stop the program with `runtime error
[E-INT-OVERFLOW]: 4611686018427387903 + 1 overflows Int`, located on `medaka
run`. The LLVM backend checks the tagged words with the
`llvm.s*.with.overflow` intrinsics (the add of `2a+1` and `2b` overflows
exactly when `a+b` does, and its result is already tagged); Wasm compares
against the bounds; both interpreters check before the host arithmetic, which
traps too. The prelude's polymorphic `Num Int` path traps the same way in the
runtime (`mdk_num_*`). `%` never overflows. There is no compile-time constant
folding of `Int` arithmetic in Core IR, so no folder can produce a wrapped
constant.

## 9. Milestones

| Milestone | Exit |
|---|---|
| **N1 (the tagged tier)** | `U8`/`U16`/`U32` exist on all three engines; the literal range check, builtin operators, pattern literals and the three modules ship; the W-QUIETER probe (`emitU8 300`, `setInPlace 0 256`, computed `fromInt 300`) is a gated test |
| **N2 (the first consumers)** | `U8` is the element type of `Bytes`/`MutBytes`/`bytebuilder`/`byteparser` (#3415); `U32` carries sha256/hmac/pbkdf2/crc32 and the property-runner RNG; the round is re-measured against the figures on #3377 |
| **N3 (U64)** | boxed `U64`, wide literals, `mulWide`/`addCarry`/`subBorrow`, the multi-byte codecs typed, the `bits64` module deleted with #2311 and #432 closed, SplitMix/FNV moved, the seed re-minted twice |
| **N4 (Int traps)** | every wrap dependent moved (the `Hashable` folds, field/scalar), the census repeated over the emitter child and `pdsd`, the cost measured, `Int` overflow panics on all three engines, `checkedAdd` family shipped, spec updated |
| **N5 (unboxed and lowered)** | #353's scalar slice (U64/U32 raw across `let`, parameter and result, LLVM), `i32` lowering with rotates as rotates, `mulWide` bound in registers, field on 5x52 and scalar on 8x32 limbs (Val, 2026-09-26); #2360 stays its own issue |
| **N6 (signed and the FFI)** | `I32`/`I64`, C-twin crossing; opened for `sqlite/`'s full 64-bit `INTEGER` (#3456, Val 2026-09-26) |

N2's measurement (2026-09-25, shared box, interleaved, both arms built by
one binary): SHA-256 on `U32` runs about 3% fewer instructions per block
(13.4 G against 13.85 G for the workload) than the `Int`-and-mask version,
and the wall-time difference is inside the noise: 2.07–2.98 µs per block
against 2.26–2.75 µs at the minimum across two load levels and two
workloads, where #3377 gives 1.63–1.89 µs for the flat-state variant and
1.24–1.35 µs for hand-written `i32` IR. The round is about a fifth of
the profile; the rest is the per-round state tuple allocation (#3369) and
the collector. `U32` lowers today as the tagged 64-bit operation plus a mask,
with each bit operation a helper that ThinLTO inlines: no `i32` arithmetic and
no rotate instruction. That gap is N5's budget. Two folds #3431 lists stay
on `Int`: `hmac`'s `ctEqAccum` and `pbkdf2`'s xor fold combine bytes with
`bitOr`/`bitXor`, never leave `0` to `255`, and so never wrap or trap.

N5's measurement (2026-09-26, shared box, instructions:u, each arm built by
its own tree's compiler, main at `c57f74898`): SHA-256 over 16,448 blocks
drops from 451M to 198M instructions (0.44), about 1.0 µs per block with setup
on a quiet box against 3.1 µs, which is under #3377's 1.24–1.35 µs for
hand-written `i32` IR; the rotates are `rol`/`ror`.  A KDF round of 20k keyed
HMACs drops to 0.47, 20k field multiplications to 0.15 (126.5M to 18.4M),
50 scalar inversions to 0.033 (1.049G to 34.8M), one ECDSA signature to 0.18
(244.7M to 45.2M), and the pdsd export/rehydrate/MST-insert workloads to
0.64/0.59/0.82.  The hashing workload and the interpreter's per-step cost
are unchanged; `medaka check` of the compiler is +1.7%, all of it the larger
source (cross-loaded, the two binaries check the same source in the same
instructions).  On SHA-256 the steps were: the `i32` lowering alone, with the
round state still a tuple (#3369's shape), 4% fewer instructions; the state
carried as eight parameters on top of it, 50%; those parameters passed as
`i32` to the raw worker, 56%.

N1 precedes N2 because the family's conversion names must be fixed before
`U8` ships (#3415, point 1). N2 precedes N3 so the tagged mechanism is
measured before the boxed one is built. N3 precedes N4 because the
`Hashable` fold and the RNGs move to `U64`. N5 and N6 are independent of
each other and of everything after N3.

The Bytes B5 waves do not pause for N1: literals overload, so a migrated
site keeps compiling, and the sites that break under `U8` (arithmetic on a
read byte) are loud and mechanical, so N2 absorbs that pass.

## 10. What must hold throughout

- `emitU8 300`, `setInPlace 0 256 mb`, and a computed `fromInt 300 : U8`
  are each refused, at compile time or at runtime, and never stored. Every
  N1 and N2 packet carries the probe.
- The guarantee covers the CROSSING into a U type, not arithmetic inside
  one. `emitU8 (200 + 100)` adds two in-range `U8` literals, wraps by §2.1,
  and stores `44`; before N2 the same call panicked, because `emitU8` took an
  `Int`. Likewise `Bytes.fold (+) 0 b` now sums in `U8`. This is the wrap
  ruling applied to bytes, and no tree code relies on it (N2's review traced
  every fixed-width `+ - *` site). Val confirmed on 2026-09-25 that this is
  the intended semantics: the whole U family wraps, so no guard or lint.
- A new AST constructor (the wide literal) is audited across every
  wildcard arm as a set, and the fixture asserts about code that never
  touches it (`[T-GLOBAL-TABLE]`).
- Both interpreters (`compiler/eval/eval.mdk`, `compiler/ir/core_ir_eval.mdk`)
  change in lockstep with the two emitters; a semantic that differs across
  engines is a `run`/`build` disagreement, and the engines gate proves it.
- Nothing in `stdlib/` gains a name this document does not list without a
  proposal first.
