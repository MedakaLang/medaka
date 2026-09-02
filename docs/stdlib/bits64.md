# bits64

## `U64`

```
data U64
  = U64 Int Int Int Int
```

Instances: `Eq`, `Debug`, `Display`, `Hashable`, `Ord`

## `zero`

```
zero : U64
```

## `one`

```
one : U64
```

## `fromIntBits`

```
fromIntBits : Int -> U64
```

Split a Medaka `Int` into `uint64` limbs, masking to the low 64 bits.

Because each 16-bit window is masked immediately, this reproduces C's
`(unsigned long long)n` for negatives too (the two's-complement bits of a
window are the same under either shift convention).

(Named `fromIntBits`, not `fromInt`, on purpose: `fromInt` is the `Num`
interface method in `core.mdk`, and a top-level binding of that name is
absorbed as a method definition and poisons inference for the whole
module.)

```medaka
> fromIntBits 1
U64 1 0 0 0
> fromIntBits 65536
U64 0 1 0 0
> fromIntBits 4294967296
U64 0 0 1 0
```

## `isZero`

```
isZero : U64 -> Bool
```

Is this `uint64` zero?

```medaka
> isZero (fromIntBits 0)
True
> isZero (fromIntBits 5)
False
```

## `cmp`

```
cmp : U64 -> U64 -> Ordering
```

Compare two `uint64` values (unsigned).  The `Ord U64` instance delegates
here, so `compare` and `cmp` can never disagree (#2311).

```medaka
> cmp (fromIntBits 1) (fromIntBits 2)
Lt
> cmp (fromIntBits 2) (fromIntBits 2)
Eq
> cmp (fromIntBits 3) (fromIntBits 2)
Gt
> cmp (U64 0 0 0 1) (U64 65535 65535 65535 0)
Gt
```

## `add`

```
add : U64 -> U64 -> U64
```

Addition mod 2^64 (wraps on overflow).

```medaka
> add (fromIntBits 1) (fromIntBits 2)
U64 3 0 0 0
> add (fromIntBits 65535) (fromIntBits 1)
U64 0 1 0 0
> add (U64 65535 65535 65535 65535) (fromIntBits 1)
U64 0 0 0 0
```

## `sub`

```
sub : U64 -> U64 -> U64
```

Subtraction mod 2^64: `a - b`, wrapping when `b > a`.

A negative limb difference masks to its low 16 bits (`+65536`), which IS
the borrow into the next limb.

```medaka
> sub (fromIntBits 5) (fromIntBits 3)
U64 2 0 0 0
> sub (fromIntBits 0) (fromIntBits 1)
U64 65535 65535 65535 65535
```

## `mulLow`

```
mulLow : U64 -> U64 -> U64
```

Low 64 bits of the product `a * b` (i.e. `a * b mod 2^64`) — schoolbook
multiply keeping only the low four limbs.

```medaka
> mulLow (fromIntBits 7) (fromIntBits 6)
U64 42 0 0 0
> mulLow (fromIntBits 65536) (fromIntBits 65536)
U64 0 0 1 0
> mulLow (U64 0 0 0 1) (U64 0 1 0 0)
U64 0 0 0 0
```

## `and`

```
and : U64 -> U64 -> U64
```

Bitwise AND.  Shadows the prelude's boolean `and` when imported
unqualified — import `bits64` qualified if you need both.

```medaka
> and (fromIntBits 12) (fromIntBits 10)
U64 8 0 0 0
```

## `or`

```
or : U64 -> U64 -> U64
```

Bitwise OR.  Shadows the prelude's boolean `or` when imported
unqualified.

```medaka
> or (fromIntBits 12) (fromIntBits 10)
U64 14 0 0 0
```

## `xor`

```
xor : U64 -> U64 -> U64
```

Bitwise XOR.  Shadows the prelude's boolean `xor` when imported
unqualified.

```medaka
> xor (fromIntBits 12) (fromIntBits 10)
U64 6 0 0 0
```

## `limbAt`

```
limbAt : Int -> U64 -> Int
```

Limb `i` of a `uint64` — its bits `[16i, 16i+15]` as an `Int` in
`[0, 2^16)`.  Out-of-range `i` (`< 0` or `> 3`) reads as `0`.

```medaka
> limbAt 2 (U64 10 20 30 40)
30
> limbAt 1 (fromIntBits 65536)
1
```

## `shr`

```
shr : Int -> U64 -> U64
```

Logical right shift by `n` bits, `n` in `[0, 63]`.  Vacated high bits are
filled with zeros (unsigned shift).

```medaka
> shr 4 (fromIntBits 256)
U64 16 0 0 0
> shr 16 (fromIntBits 65536)
U64 1 0 0 0
> shr 63 (U64 0 0 0 32768)
U64 1 0 0 0
```

## `shl`

```
shl : Int -> U64 -> U64
```

Logical left shift by `n` bits, `n` in `[0, 63]`.  Bits shifted past bit
63 are dropped (mod 2^64).

```medaka
> shl 4 (fromIntBits 1)
U64 16 0 0 0
> shl 16 (fromIntBits 1)
U64 0 1 0 0
> shl 63 (fromIntBits 1)
U64 0 0 0 32768
```

## `mod`

```
mod : U64 -> U64 -> U64
```

Exact `uint64` modulo: `dividend mod divisor`, correct for any nonzero
divisor up to 2^64 - 1 (a running-remainder shortcut would be wrong for
large divisors).  A zero divisor is a caller error and yields `dividend`.

```medaka
> mod (fromIntBits 17) (fromIntBits 5)
U64 2 0 0 0
> mod (U64 65535 65535 65535 65535) (fromIntBits 10)
U64 5 0 0 0
> mod (U64 0 0 0 32768) (fromIntBits 3)
U64 2 0 0 0
```

## Instances

