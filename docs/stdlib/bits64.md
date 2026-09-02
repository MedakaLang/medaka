# bits64

Unsigned 64-bit arithmetic.

`Int` is a 63-bit integer, so it cannot hold a 64-bit unsigned value.
`U64` represents one as four 16-bit limbs and provides the operations
with C's unsigned semantics: every result wraps modulo 2^64. Use it for
hashes, random number generators, checksums, and binary formats.

The names `and`, `or`, `xor`, `add`, and `sub` shadow prelude names, so
import the module qualified: `import bits64 as B`.

### `U64`

```
data U64
  = U64 Int Int Int Int
```

An unsigned 64-bit value as four 16-bit limbs, least significant
first: `U64 l0 l1 l2 l3` is `l0 + l1 * 2^16 + l2 * 2^32 + l3 * 2^48`.

Instances: `Eq`, `Debug`, `Display`, `Hashable`, [`Ord`](#ord-u64)

## Construction

### `zero`

```
zero : U64
```

The value `0`.

### `one`

```
one : U64
```

The value `1`.

### `fromIntBits`

```
fromIntBits : Int -> U64
```

The low 64 bits of an `Int`.

A negative `Int` gives the same bits C's `(unsigned long long)` cast
would.

```medaka
> fromIntBits 65536
U64 0 1 0 0
```

## Comparison

### `isZero`

```
isZero : U64 -> Bool
```

Whether the value is `0`.

```medaka
> isZero (fromIntBits 0)
True
> isZero (fromIntBits 5)
False
```

### `cmp`

```
cmp : U64 -> U64 -> Ordering
```

The unsigned ordering of two values. `compare` on `U64` is the same.

```medaka
> cmp (fromIntBits 1) (fromIntBits 2)
Lt
> cmp (U64 0 0 0 1) (U64 65535 65535 65535 0)
Gt
```

## Arithmetic

### `add`

```
add : U64 -> U64 -> U64
```

The sum modulo 2^64.

```medaka
> add (fromIntBits 1) (fromIntBits 2)
U64 3 0 0 0
> add (U64 65535 65535 65535 65535) (fromIntBits 1)
U64 0 0 0 0
```

### `sub`

```
sub : U64 -> U64 -> U64
```

The difference `a - b` modulo 2^64, wrapping when `b > a`.

```medaka
> sub (fromIntBits 5) (fromIntBits 3)
U64 2 0 0 0
> sub (fromIntBits 0) (fromIntBits 1)
U64 65535 65535 65535 65535
```

### `mulLow`

```
mulLow : U64 -> U64 -> U64
```

The low 64 bits of the product.

```medaka
> mulLow (fromIntBits 7) (fromIntBits 6)
U64 42 0 0 0
> mulLow (fromIntBits 65536) (fromIntBits 65536)
U64 0 0 1 0
```

## Bitwise operations

### `and`

```
and : U64 -> U64 -> U64
```

Bitwise and.

```medaka
> and (fromIntBits 12) (fromIntBits 10)
U64 8 0 0 0
```

### `or`

```
or : U64 -> U64 -> U64
```

Bitwise or.

```medaka
> or (fromIntBits 12) (fromIntBits 10)
U64 14 0 0 0
```

### `xor`

```
xor : U64 -> U64 -> U64
```

Bitwise exclusive or.

```medaka
> xor (fromIntBits 12) (fromIntBits 10)
U64 6 0 0 0
```

### `limbAt`

```
limbAt : Int -> U64 -> Int
```

Limb `i` of a value: bits `16i` to `16i + 15`, as an `Int` below
2^16.

`0` when `i` is outside `0` to `3`.

```medaka
> limbAt 2 (U64 10 20 30 40)
30
```

### `shr`

```
shr : Int -> U64 -> U64
```

The value shifted right by `n` bits, from `0` to `63`, filling with
zeros.

```medaka
> shr 4 (fromIntBits 256)
U64 16 0 0 0
> shr 63 (U64 0 0 0 32768)
U64 1 0 0 0
```

### `shl`

```
shl : Int -> U64 -> U64
```

The value shifted left by `n` bits, from `0` to `63`. Bits shifted
past bit 63 are dropped.

```medaka
> shl 4 (fromIntBits 1)
U64 16 0 0 0
> shl 63 (fromIntBits 1)
U64 0 0 0 32768
```

## Division

### `mod`

```
mod : U64 -> U64 -> U64
```

The remainder of `dividend` divided by `divisor`.

Exact for every non-zero divisor. A zero divisor gives back `dividend`.

```medaka
> mod (fromIntBits 17) (fromIntBits 5)
U64 2 0 0 0
> mod (U64 65535 65535 65535 65535) (fromIntBits 10)
U64 5 0 0 0
```

## Instances

### `Ord U64`

```
impl Ord U64
```

Values compare as unsigned integers, through `cmp`.

