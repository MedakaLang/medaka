# bytes

An immutable string of bytes.

`Bytes` wraps a sequence of byte values, each `0` to `255`, and hands out
no way to change it once built. Use it for data that is bytes, such as a
file's contents, a hash digest, or a UTF-8 encoding, and `Array Int` for a
sequence of numbers that happen to be small.

The bytes are packed one per byte rather than one per machine word, so a
byte string of `n` bytes occupies `n` bytes.

The `0` to `255` domain is enforced at the way in. `fromArray` answers
`None` on an element outside it, so no `Bytes` value holds anything else,
and `get`, `b[i]`, `eq`, and `compare` all read a byte back.
`fromArrayAssumeByteDomain` is the unchecked way in, for a caller that has
already established the range.

`fromArray` and `toArray` convert; `bytesLength` is the byte count and
`get` reads one byte. `b[i]` panics on an out-of-range index; `get` is the
`Option`-returning form. `slice` copies out a sub-range and panics on a
range that runs outside the byte string, and `indexOf` finds the first
byte equal to a given value. Two byte strings compare lexicographically,
as the arrays of their bytes do, and hash as the arrays of their bytes do,
so `Bytes` is a `HashMap`/`HashSet` key.

`append` joins two byte strings, and `b1 ++ b2` reaches it: `++` is
`Semigroup`'s `append`, so it dispatches on `Bytes` and allocates the
joined length once. No `++` between byte strings falls through to the
runtime's untyped concatenation, which has no byte-buffer case.

`MutBytes` is the mutable, fixed-length sibling, and the way to build a
byte string a byte at a time: `mutBytesMake` allocates `n` zero bytes,
`mutBytesSet` writes one, and `freeze` hands back a `Bytes`. The freeze
copies, so a write after it never reaches the byte string it produced.

### `Bytes`

```
newtype Bytes = Bytes ByteBlock
```

The byte-string type.

The constructor is module-private, so `fromArray`,
`fromArrayAssumeByteDomain` and `toUtf8Bytes` are the ways in and `toArray`
and `fromUtf8Bytes` are the ways out.

```medaka
> map bytesLength (fromArray [|1, 2, 3|])
Some 3
```

Instances: [`Index`](#index-bytes-int-int), [`Slice`](#slice-bytes), [`Semigroup`](#semigroup-bytes), [`Eq`](#eq-bytes), [`Ord`](#ord-bytes), [`Hashable`](#hashable-bytes), [`Debug`](#debug-bytes)

## Conversion

### `fromArray`

```
fromArray : Array Int -> Option Bytes
```

The byte string holding the elements of `arr`, or `None` when any element
falls outside `0` to `255`.

```medaka
> map toArray (fromArray [|104, 105|])
Some [|104, 105|]
> fromArray [|104, 256|]
None
> fromArray [|-1|]
None
```

### `fromArrayAssumeByteDomain`

```
fromArrayAssumeByteDomain : Array Int -> Bytes
```

The byte string holding the elements of `arr`, keeping only the low eight
bits of each.

Every element of `arr` must already be in `0` to `255`. Nothing here checks
that, and an element outside the range is silently masked rather than
refused, so `-1` and `511` both store as `255`. Prefer `fromArray` unless
the elements come from a source that already guarantees the range.

This is transitional. It exists so that callers holding bytes by
construction move to `Bytes` without paying a scan, and it is removed once
the domain-checked door is the only one, alongside `toUtf8`/`fromUtf8`.

```medaka
> toArray (fromArrayAssumeByteDomain [|104, 105|])
[|104, 105|]
> toArray (fromArrayAssumeByteDomain [|300, -1|])
[|44, 255|]
```

### `toArray`

```
toArray : Bytes -> Array Int
```

The bytes of `b` as an array, in order.

```medaka
> toArray (toUtf8Bytes "hi")
[|104, 105|]
```

## Reading

### `bytesLength`

```
bytesLength : Bytes -> Int
```

The number of bytes in `b`.

The name is not `length`: that one is `Foldable`'s method, which the
prelude exports, and `Bytes` cannot implement `Foldable`. The interface
ranges over a container of some element type, and `Bytes` has no element
parameter.

```medaka
> bytesLength (toUtf8Bytes "héllo")
6
```

### `get`

```
get : Int -> Bytes -> Option Int
```

The byte at index `i`, or `None` when `i` is out of range.

`b[i]` is the panicking form: on the same out-of-range index, `get`
answers `None` where `b[i]` raises an index error.

```medaka
> get 0 (fromArrayAssumeByteDomain [|7, 8, 9|])
Some 7
> get 3 (fromArrayAssumeByteDomain [|7, 8, 9|])
None
> get (-1) (fromArrayAssumeByteDomain [|7, 8, 9|])
None
```

### `indexOf`

```
indexOf : Int -> Bytes -> Option Int
```

The index of the first byte equal to `v`, or `None` when no byte is.

The needle is one byte, where `string.indexOf` takes a whole substring:
`Bytes` is a sequence of byte values, and this is the search for one of
them, as `list.elemIndex` is for a list element. A `v` outside `0` to
`255` equals no byte, so the answer is `None`.

```medaka
> indexOf 9 (fromArrayAssumeByteDomain [|7, 9, 8, 9|])
Some 1
> indexOf 5 (fromArrayAssumeByteDomain [|7, 9, 8|])
None
> indexOf 300 (fromArrayAssumeByteDomain [|7, 9, 8|])
None
```

## Combining

## Comparison

## Text

### `toUtf8Bytes`

```
toUtf8Bytes : String -> Bytes
```

The UTF-8 encoding of `s`.

A codepoint outside ASCII contributes several bytes, so the byte count is
at least the codepoint count and often larger.

```medaka
> bytesLength (toUtf8Bytes "héllo")
6
```

### `fromUtf8Bytes`

```
fromUtf8Bytes : Bytes -> String
```

The string encoded by `b`, read as UTF-8.

On valid UTF-8, `fromUtf8Bytes (toUtf8Bytes s)` is `s`.

```medaka
> fromUtf8Bytes (toUtf8Bytes "héllo→")
"héllo→"
```

## Mutation

### `MutBytes`

```
newtype MutBytes = MutBytes ByteBlock
```

A mutable string of bytes, fixed at its allocated length.

The constructor is module-private, so `mutBytesMake` is the way in and
`freeze` the way out, and nothing observes the buffer except through the
functions below.

Reach for it to build a byte string a byte at a time. The alternative --
filling an `Array Int` and handing it to `fromArray` -- boxes a machine
word per byte before packing them, which is the cost `Bytes` exists to
avoid.

```medaka
> mutBytesLength (mutBytesMake 3)
3
```

### `mutBytesMake`

```
mutBytesMake : Int -> MutBytes
```

A mutable byte string of `n` zero bytes.

Panics when `n` is negative.

```medaka
> mutBytesGet 2 (mutBytesMake 3)
Some 0
```

### `mutBytesLength`

```
mutBytesLength : MutBytes -> Int
```

The number of bytes in `mb`, fixed when it was allocated.

```medaka
> mutBytesLength (mutBytesMake 4)
4
```

### `mutBytesGet`

```
mutBytesGet : Int -> MutBytes -> Option Int
```

The byte at index `i` of `mb`, or `None` when `i` is out of range.

```medaka
> mutBytesGet 1 (mutBytesMake 2)
Some 0
> mutBytesGet 2 (mutBytesMake 2)
None
> mutBytesGet (-1) (mutBytesMake 2)
None
```

### `mutBytesSet`

```
mutBytesSet : Int -> Int -> MutBytes -> Unit
```

Replaces the byte at index `i` of `mb` with `v`.

Panics when `i` is out of range, as `array.setInPlace` does, and panics
when `v` falls outside `0` to `255` rather than keeping its low eight
bits. A masked write would put a byte into a `Bytes` that no caller asked
for, and this is the door every byte written here goes through.

```medaka
> let mb = mutBytesMake 2 in let _ = mutBytesSet 0 65 mb in mutBytesGet 0 mb
Some 65
```

### `freeze`

```
freeze : MutBytes -> Bytes
```

The bytes of `mb` as an immutable `Bytes`.

The result is a copy, so a write to `mb` afterwards does not reach it.

```medaka
> let mb = mutBytesMake 2 in let _ = mutBytesSet 1 9 mb in toArray (freeze mb)
[|0, 9|]
> let m = mutBytesMake 1 in let b = freeze m in let _ = mutBytesSet 0 7 m in toArray b
[|0|]
```

## Instances

### `Index Bytes Int Int`

```
impl Index Bytes Int Int
```

`b[i]` reads the byte at `i` in `O(1)`.

Panics with an index error when `i` is out of range; `get` is the
`Option`-returning form.

```medaka
> let b = fromArrayAssumeByteDomain [|7, 8, 9|] in b[1]
8
```

### `Slice Bytes`

```
impl Slice Bytes
```

The bytes over `[lo, hi)`, copied into a new byte string. The
`b.[lo..hi]` and `b.[lo..=hi]` syntax dispatches here.

The result is a copy, not a view onto `b`: a byte string is `n` bytes and
nothing more, so there is no offset and length to share one with.

Panics with a slice error when the range runs outside the byte string,
exactly as `Slice (Array a)` does.

```medaka
> toArray (slice (fromArrayAssumeByteDomain [|10, 20, 30, 40, 50|]) 1 3)
[|20, 30|]
> toArray (slice (fromArrayAssumeByteDomain [|10, 20|]) 1 1)
[||]
```

### `Semigroup Bytes`

```
impl Semigroup Bytes
```

The bytes of `b1` followed by the bytes of `b2`, in a new byte string.
Backs `++`.

```medaka
> toArray (append (fromArrayAssumeByteDomain [|1, 2|]) (fromArrayAssumeByteDomain [|3|]))
[|1, 2, 3|]
> fromUtf8Bytes (toUtf8Bytes "hé" ++ toUtf8Bytes "llo")
"héllo"
```

### `Eq Bytes`

```
impl Eq Bytes
```

Two byte strings are equal when they hold the same bytes in the same
order.

```medaka
> eq (fromArrayAssumeByteDomain [|1, 2|]) (fromArrayAssumeByteDomain [|1, 2|])
True
> eq (fromArrayAssumeByteDomain [|1, 2|]) (fromArrayAssumeByteDomain [|1, 2, 3|])
False
```

### `Ord Bytes`

```
impl Ord Bytes
```

Byte strings compare lexicographically, exactly as the arrays of their
bytes do: byte by byte from the front, and a prefix sorts before what
extends it.

```medaka
> compare (fromArrayAssumeByteDomain [|1, 2|]) (fromArrayAssumeByteDomain [|1, 3|])
Lt
> compare (fromArrayAssumeByteDomain [|1, 2|]) (fromArrayAssumeByteDomain [|1, 2, 0|])
Lt
```

### `Hashable Bytes`

```
impl Hashable Bytes
```

The `acc * 33 + hash byte` fold `Hashable (Array a)` runs over elements,
from `0` and left to right, so a byte string hashes as the `Array Int` or
`List Int` of its bytes does. `hashInt` is what `Hashable Int` would
contribute for each byte. Agrees with `Eq Bytes`, which walks the same
bytes in the same order.

```medaka
> let m = fromList [(toUtf8Bytes "one", 1), (toUtf8Bytes "two", 2)] in m[toUtf8Bytes "two"]
2
> hash (fromArrayAssumeByteDomain [|1, 2, 3|]) == hash [|1, 2, 3|]
True
```

### `Debug Bytes`

```
impl Debug Bytes
```

Renders as its bytes would as an `Array Int`.

```medaka
> debug (fromArrayAssumeByteDomain [|7, 8, 9|])
"[|7, 8, 9|]"
> debug (fromArrayAssumeByteDomain [||])
"[||]"
```

