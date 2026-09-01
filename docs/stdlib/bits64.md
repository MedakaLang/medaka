# bits64

bits64.mdk — 64-bit-unsigned arithmetic over the 63-bit `Int` fixnum.

Medaka's `Int` is a 63-bit fixnum that WRAPS on overflow, so it cannot hold
a `uint64` value (let alone a `uint64` product mod 2^64).  This module
emulates a `uint64` as a 4-tuple of 16-bit limbs `(l0, l1, l2, l3)`,
least-significant first — exactly the representation the compiler itself
hand-rolled in `compiler/eval/eval.mdk` to reproduce SplitMix64 / FNV-1a
faithfully while fixing issue #98.  The algorithms here mirror that proven
implementation.

Why a tuple and not a fresh `data` type: tuple instances (`Eq`, `Debug`, …)
already live in the prelude (`core.mdk`), so this module drags no new
instance surface and imports near-free (see `docs/stdlib/STDLIB.md`).

Every intermediate stays well under the 63-bit range: a limb < 2^16, a
16×16 partial product < 2^32, and a column sum of four such products plus a
carry < 2^35 — so no native op ever overflows during a computation.

Use it for hashing, PRNGs, checksums, and binary/wire formats — anything
that needs the C `unsigned long long` overflow / bit semantics.  All ops are
modulo 2^64 (they wrap), matching C's unsigned arithmetic.

## `U64`

```
type U64 = (Int, Int, Int, Int)
```

A `uint64` as four 16-bit limbs, least-significant first: the value is
`l0 + l1*2^16 + l2*2^32 + l3*2^48`, each limb in `[0, 2^16)`.

## `zero`

```
zero : (Int, Int, Int, Int)
```

The all-zero `uint64`.

## `one`

```
one : (Int, Int, Int, Int)
```

The `uint64` value 1.

## `ofInt`

```
ofInt : Int -> (Int, Int, Int, Int)
```

Split a Medaka `Int` into `uint64` limbs, masking to the low 64 bits.

Because each 16-bit window is masked immediately, this reproduces C's
`(unsigned long long)n` for negatives too (the two's-complement bits of a
window are the same under either shift convention).

(Named `ofInt`, not `fromInt`, on purpose: `fromInt` is the `Num` interface
method in `core.mdk`, and a top-level binding of that name is absorbed as a
method definition and poisons inference for the whole module.)


*(doctest — run by `medaka test`)*

```medaka
> ofInt 1
(1, 0, 0, 0)
> ofInt 65536
(0, 1, 0, 0)
> ofInt 4294967296
(0, 0, 1, 0)
```

## `isZero`

```
isZero : (Int, Int, Int, Int) -> Bool
```

Is this `uint64` zero?


*(doctest — run by `medaka test`)*

```medaka
> isZero (ofInt 0)
True
> isZero (ofInt 5)
False
```

## `cmp64`

```
cmp64 : (Int, Int, Int, Int) -> (Int, Int, Int, Int) -> Ordering
```

Compare two `uint64` values (unsigned).


*(doctest — run by `medaka test`)*

```medaka
> cmp64 (ofInt 1) (ofInt 2)
Lt
> cmp64 (ofInt 2) (ofInt 2)
Eq
> cmp64 (ofInt 3) (ofInt 2)
Gt
> cmp64 (0, 0, 0, 1) (65535, 65535, 65535, 0)
Gt
```

## `add64`

```
add64 : (Int, Int, Int, Int) -> (Int, Int, Int, Int) -> (Int, Int, Int, Int)
```

Addition mod 2^64 (wraps on overflow).


*(doctest — run by `medaka test`)*

```medaka
> add64 (ofInt 1) (ofInt 2)
(3, 0, 0, 0)
> add64 (ofInt 65535) (ofInt 1)
(0, 1, 0, 0)
> add64 (65535, 65535, 65535, 65535) (ofInt 1)
(0, 0, 0, 0)
```

## `sub64`

```
sub64 : (Int, Int, Int, Int) -> (Int, Int, Int, Int) -> (Int, Int, Int, Int)
```

Subtraction mod 2^64: `a - b`, wrapping when `b > a`.

A negative limb difference masks to its low 16 bits (`+65536`), which IS
the borrow into the next limb.


*(doctest — run by `medaka test`)*

```medaka
> sub64 (ofInt 5) (ofInt 3)
(2, 0, 0, 0)
> sub64 (ofInt 0) (ofInt 1)
(65535, 65535, 65535, 65535)
```

## `mulLow64`

```
mulLow64 : (Int, Int, Int, Int) -> (Int, Int, Int, Int) -> (Int, Int, Int, Int)
```

Low 64 bits of the product `a * b` (i.e. `a * b mod 2^64`) — schoolbook
multiply keeping only the low four limbs.


*(doctest — run by `medaka test`)*

```medaka
> mulLow64 (ofInt 7) (ofInt 6)
(42, 0, 0, 0)
> mulLow64 (ofInt 65536) (ofInt 65536)
(0, 0, 1, 0)
> mulLow64 (0, 0, 0, 1) (0, 1, 0, 0)
(0, 0, 0, 0)
```

## `and64`

```
and64 : (Int, Int, Int, Int) -> (Int, Int, Int, Int) -> (Int, Int, Int, Int)
```

Bitwise AND.


*(doctest — run by `medaka test`)*

```medaka
> and64 (ofInt 12) (ofInt 10)
(8, 0, 0, 0)
```

## `or64`

```
or64 : (Int, Int, Int, Int) -> (Int, Int, Int, Int) -> (Int, Int, Int, Int)
```

Bitwise OR.


*(doctest — run by `medaka test`)*

```medaka
> or64 (ofInt 12) (ofInt 10)
(14, 0, 0, 0)
```

## `xor64`

```
xor64 : (Int, Int, Int, Int) -> (Int, Int, Int, Int) -> (Int, Int, Int, Int)
```

Bitwise XOR.


*(doctest — run by `medaka test`)*

```medaka
> xor64 (ofInt 12) (ofInt 10)
(6, 0, 0, 0)
```

## `limbAt`

```
limbAt : (Int, Int, Int, Int) -> Int -> Int
```

Limb `i` of a `uint64` — its bits `[16i, 16i+15]` as an `Int` in
`[0, 2^16)`.  Out-of-range `i` (`< 0` or `> 3`) reads as `0`.


*(doctest — run by `medaka test`)*

```medaka
> limbAt (10, 20, 30, 40) 2
30
> limbAt (ofInt 65536) 1
1
```

## `shr64`

```
shr64 : (Int, Int, Int, Int) -> Int -> (Int, Int, Int, Int)
```

Logical right shift by `n` bits, `n` in `[0, 63]`.  Vacated high bits are
filled with zeros (unsigned shift).


*(doctest — run by `medaka test`)*

```medaka
> shr64 (ofInt 256) 4
(16, 0, 0, 0)
> shr64 (ofInt 65536) 16
(1, 0, 0, 0)
> shr64 (0, 0, 0, 32768) 63
(1, 0, 0, 0)
```

## `shl64`

```
shl64 : (Int, Int, Int, Int) -> Int -> (Int, Int, Int, Int)
```

Logical left shift by `n` bits, `n` in `[0, 63]`.  Bits shifted past bit
63 are dropped (mod 2^64).


*(doctest — run by `medaka test`)*

```medaka
> shl64 (ofInt 1) 4
(16, 0, 0, 0)
> shl64 (ofInt 1) 16
(0, 1, 0, 0)
> shl64 (ofInt 1) 63
(0, 0, 0, 32768)
```

## `mod64`

```
mod64 : (Int, Int, Int, Int) -> (Int, Int, Int, Int) -> (Int, Int, Int, Int)
```

Exact `uint64` modulo: `dividend mod divisor`, correct for any nonzero
divisor up to 2^64 - 1 (a running-remainder shortcut would be wrong for
large divisors).  A zero divisor is a caller error and yields `dividend`.


*(doctest — run by `medaka test`)*

```medaka
> mod64 (ofInt 17) (ofInt 5)
(2, 0, 0, 0)
> mod64 (65535, 65535, 65535, 65535) (ofInt 10)
(5, 0, 0, 0)
> mod64 (0, 0, 0, 32768) (ofInt 3)
(2, 0, 0, 0)
```

