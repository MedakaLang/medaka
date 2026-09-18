# bytes

An immutable string of bytes.

`Bytes` wraps a sequence of byte values, each meant to be `0` to `255`,
and hands out no way to change it once built. Use it for data that is
bytes, such as a file's contents, a hash digest, or a UTF-8 encoding, and
`Array Int` for a sequence of numbers that happen to be small.

At B1 the `0` to `255` domain is not enforced. `fromArray` accepts any
`Int`, and `get`, `b[i]`, `eq`, and `compare` all read an out-of-range
element back unchanged, with no masking. Some byte-consuming code
elsewhere (`hex.encodeBytes`, for one) masks to the low eight bits before
use, so the same out-of-range value can render differently depending on
which operation reads it. Masking or rejecting out-of-range elements is
left to `Bytes`'s packed B2 representation.

`fromArray` and `toArray` convert; `bytesLength` is the byte count and
`get` reads one byte. `b[i]` panics on an out-of-range index; `get` is the
`Option`-returning form. Two byte strings compare lexicographically, as the
arrays of their bytes do.

### `Bytes`

```
newtype Bytes = Bytes (Array Int)
```

The byte-string type.

The constructor is module-private, so `fromArray` and `toUtf8Bytes` are the
ways in and `toArray` and `fromUtf8Bytes` are the ways out.

```medaka
> bytesLength (fromArray [|1, 2, 3|])
3
```

Instances: [`Index`](#index-bytes-int-int), [`Eq`](#eq-bytes), [`Ord`](#ord-bytes), [`Debug`](#debug-bytes)

## Conversion

### `fromArray`

```
fromArray : Array Int -> Bytes
```

The byte string holding the elements of `arr`, in order.

Nothing here masks or rejects an element outside `0` to `255`: `get`,
`b[i]`, `eq`, and `compare` all read such an element back unchanged.

```medaka
> toArray (fromArray [|104, 105|])
[|104, 105|]
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
> get 0 (fromArray [|7, 8, 9|])
Some 7
> get 3 (fromArray [|7, 8, 9|])
None
> get (-1) (fromArray [|7, 8, 9|])
None
```

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

Only the low eight bits of each byte are used. On valid UTF-8,
`fromUtf8Bytes (toUtf8Bytes s)` is `s`.

```medaka
> fromUtf8Bytes (toUtf8Bytes "héllo→")
"héllo→"
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
> let b = fromArray [|7, 8, 9|] in b[1]
8
```

### `Eq Bytes`

```
impl Eq Bytes
```

Two byte strings are equal when they hold the same bytes in the same
order.

```medaka
> eq (fromArray [|1, 2|]) (fromArray [|1, 2|])
True
> eq (fromArray [|1, 2|]) (fromArray [|1, 2, 3|])
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
> compare (fromArray [|1, 2|]) (fromArray [|1, 3|])
Lt
> compare (fromArray [|1, 2|]) (fromArray [|1, 2, 0|])
Lt
```

### `Debug Bytes`

```
impl Debug Bytes
```

Renders as its bytes would as an `Array Int`.

```medaka
> debug (fromArray [|7, 8, 9|])
"[|7, 8, 9|]"
```

