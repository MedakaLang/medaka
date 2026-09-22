# bytes

An immutable string of bytes.

`Bytes` holds a sequence of byte values, each `0` to `255`, that cannot
be changed once built. Use it for data that is bytes, such as a file's
contents, a hash digest, or a UTF-8 encoding, and `Array Int` for a
sequence of numbers that happen to be small. A byte string of `n` bytes
occupies `n` bytes.

`fromArray` builds a byte string from an `Array Int` and answers `None`
when an element is outside `0` to `255`, so no `Bytes` value holds
anything else. `encodeUtf8` builds one from a `String`. `toArray` and
`decodeUtf8` go the other way. `mut_bytes.MutBytes` is the mutable
sibling, for building a byte string a byte at a time.

`length` is the byte count, `get` reads one byte as an `Option`, and
`b[i]` is the panicking form. `slice`, `take`, `drop`, `indexOf`,
`startsWith` and the rest follow the shapes of `string` and `list`.
Byte strings compare lexicographically and can key a `hash_map.HashMap`
or a `hash_set.HashSet`. `b1 ++ b2` joins two.

Several names here (`length`, `isEmpty`, `fold`, `map`, `forEach`,
`any`, `all`) are also prelude names, and others are exported by `list`
(`take`, `drop`, `splitAt`, `startsWith`, `endsWith`) or by `string` and
`array` (`concat`). Import the module qualified, as `import bytes as B`,
in a file that also imports one of those modules.

Under the interpreter (`medaka run`, `medaka test`), an operation that
walks the bytes, `==` included, fails with `E-STACK-OVERFLOW` on a byte
string longer than about 25,000 bytes. Compiled programs have no such
limit.

### `Bytes`

```
newtype Bytes = Bytes ByteBlock
```

The byte-string type.

The constructor is private. Build a value with `fromArray`,
`fromArrayAssumeByteDomain` or `encodeUtf8`, and read it back with
`toArray`, `decodeUtf8` or `decodeUtf8Lossy`. The functions under Runtime interop
doors cross to and from the runtime's `ByteBlock` without a conversion.

```medaka
> option 0 length (fromArray [|1, 2, 3|])
3
```

Instances: [`Index`](#index-bytes-int-int), [`Slice`](#slice-bytes), [`Semigroup`](#semigroup-bytes), [`Monoid`](#monoid-bytes), [`Eq`](#eq-bytes), [`Ord`](#ord-bytes), [`Hashable`](#hashable-bytes), [`Debug`](#debug-bytes)

## Conversion

### `fromArray`

```
fromArray : Array Int -> Option Bytes
fromArray arr
```

The byte string holding the elements of `arr`, or `None` when any element
falls outside `0` to `255`.

```medaka
> option [||] toArray (fromArray [|104, 105|])
[|104, 105|]
> fromArray [|104, 256|]
None
> fromArray [|-1|]
None
```

### `fromArrayAssumeByteDomain`

```
fromArrayAssumeByteDomain : Array Int -> Bytes
fromArrayAssumeByteDomain arr
```

The byte string holding the elements of `arr`, keeping only the low eight
bits of each.

Nothing here checks the range. An element outside `0` to `255` is masked
rather than refused, so `-1` and `511` both store as `255`. Prefer
`fromArray` unless the elements come from a source that already
guarantees the range.

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
> toArray (encodeUtf8 "hi")
[|104, 105|]
```

## Reading

### `length`

```
length : Bytes -> Int
```

The number of bytes in `b`.

This is a plain function, not `Foldable`'s method. Named in an import
list it shadows the prelude's `length` for the whole importing module.

```medaka
> length (encodeUtf8 "héllo")
6
```

### `isEmpty`

```
isEmpty : Bytes -> Bool
```

Whether `b` holds no bytes.

```medaka
> isEmpty (fromArrayAssumeByteDomain [||])
True
> isEmpty (encodeUtf8 "hi")
False
```

### `get`

```
get : Int -> Bytes -> Option Int
get i _
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

### `sliceClamped`

```
sliceClamped : Int -> Int -> Bytes -> Bytes
sliceClamped lo hi _
```

The bytes over `[lo, hi)`, copied into a new byte string, with both
bounds clamped into the byte string.

The non-panicking form of `slice`. A range running outside `b` yields a
shorter byte string, or an empty one, where `b.[lo..hi]` raises a slice
error.

```medaka
> toArray (sliceClamped 1 3 (fromArrayAssumeByteDomain [|10, 20, 30, 40|]))
[|20, 30|]
> toArray (sliceClamped (-5) 99 (fromArrayAssumeByteDomain [|10, 20|]))
[|10, 20|]
> toArray (sliceClamped 3 1 (fromArrayAssumeByteDomain [|10, 20|]))
[||]
```

### `take`

```
take : Int -> Bytes -> Bytes
take n b
```

The first `n` bytes of `b`, or all of them when `b` is shorter. Empty
when `n <= 0`.

The result is a copy, as `slice`'s is.

```medaka
> toArray (take 2 (fromArrayAssumeByteDomain [|10, 20, 30|]))
[|10, 20|]
> toArray (take 9 (fromArrayAssumeByteDomain [|10, 20|]))
[|10, 20|]
```

### `drop`

```
drop : Int -> Bytes -> Bytes
drop n b
```

The bytes of `b` after the first `n`. Empty when `n` is at least `b`'s
length, and the whole of `b` when `n <= 0`.

The result is a copy, as `slice`'s is.

```medaka
> toArray (drop 2 (fromArrayAssumeByteDomain [|10, 20, 30|]))
[|30|]
> toArray (drop 9 (fromArrayAssumeByteDomain [|10, 20|]))
[||]
```

### `splitAt`

```
splitAt : Int -> Bytes -> (Bytes, Bytes)
splitAt n b
```

The first `n` bytes of `b`, and the rest.

`(take n b, drop n b)`, so both halves are copies and both ends of the
split clamp into `b`.

```medaka
> let (a, b) = splitAt 2 (fromArrayAssumeByteDomain [|10, 20, 30|]) in (toArray a, toArray b)
([|10, 20|], [|30|])
```

### `elemIndex`

```
elemIndex : Int -> Bytes -> Option Int
elemIndex v _
```

The index of the first byte equal to `v`, or `None` when no byte is.

The needle is a single byte; `indexOf` searches for a whole byte string.
A `v` outside `0` to `255` equals no byte, so the answer is `None`.

```medaka
> elemIndex 9 (fromArrayAssumeByteDomain [|7, 9, 8, 9|])
Some 1
> elemIndex 5 (fromArrayAssumeByteDomain [|7, 9, 8|])
None
> elemIndex 300 (fromArrayAssumeByteDomain [|7, 9, 8|])
None
```

### `elemIndexWithin`

```
elemIndexWithin : Int -> Int -> Int -> Bytes -> Option Int
elemIndexWithin lo hi v _
```

The index of the first byte equal to `v` within `[lo, hi)`, or `None`
when no byte in that range is.

`lo` and `hi` are clamped into the byte string, as in `sliceClamped`. The
answer is an index into the whole byte string, not one relative to `lo`.

```medaka
> elemIndexWithin 2 5 9 (fromArrayAssumeByteDomain [|7, 9, 8, 9, 9|])
Some 3
> elemIndexWithin 0 1 9 (fromArrayAssumeByteDomain [|7, 9, 8, 9, 9|])
None
```

### `indexOfWithin`

```
indexOfWithin : Int -> Int -> Bytes -> Bytes -> Option Int
indexOfWithin lo hi _ _
```

The index of the first occurrence of `needle` within `[lo, hi)`, or
`None`.

`lo` and `hi` are clamped into the byte string, as in `sliceClamped`. The
answer is an index into the whole byte string, not one relative to `lo`.
The empty needle occurs at `lo`.

```medaka
> indexOfWithin 0 6 (fromArrayAssumeByteDomain [|9, 8|]) (fromArrayAssumeByteDomain [|7, 9, 8, 9, 8, 7|])
Some 1
> indexOfWithin 4 6 (fromArrayAssumeByteDomain [|9, 8|]) (fromArrayAssumeByteDomain [|7, 9, 8, 9, 8, 7|])
None
> indexOfWithin 2 5 (fromArrayAssumeByteDomain [||]) (fromArrayAssumeByteDomain [|7, 9, 8, 9, 8, 7|])
Some 2
```

### `indexOf`

```
indexOf : Bytes -> Bytes -> Option Int
indexOf needle bytes
```

The index of the first occurrence of `needle` in `bytes`, or `None`.

The needle is a whole byte string; `elemIndex` searches for a single
byte. The empty needle occurs at index `0`.

```medaka
> indexOf (fromArrayAssumeByteDomain [|9, 8|]) (fromArrayAssumeByteDomain [|7, 9, 8, 9|])
Some 1
> indexOf (fromArrayAssumeByteDomain [|9, 7|]) (fromArrayAssumeByteDomain [|7, 9, 8, 9|])
None
> indexOf (fromArrayAssumeByteDomain [||]) (fromArrayAssumeByteDomain [|7, 9, 8|])
Some 0
```

### `lastIndexOf`

```
lastIndexOf : Bytes -> Bytes -> Option Int
lastIndexOf needle haystack
```

The index of the last occurrence of `needle` in `haystack`, or `None`.

Occurrences may overlap. The empty needle is found at the end of
`haystack`.

```medaka
> lastIndexOf (fromArrayAssumeByteDomain [|9, 8|]) (fromArrayAssumeByteDomain [|9, 8, 7, 9, 8|])
Some 3
> lastIndexOf (fromArrayAssumeByteDomain [|9, 7|]) (fromArrayAssumeByteDomain [|9, 8, 7|])
None
```

### `contains`

```
contains : Bytes -> Bytes -> Bool
contains needle haystack
```

Whether `needle` occurs anywhere in `haystack`. The empty needle occurs
in every byte string.

```medaka
> contains (fromArrayAssumeByteDomain [|9, 8|]) (fromArrayAssumeByteDomain [|7, 9, 8|])
True
> contains (fromArrayAssumeByteDomain [|9, 7|]) (fromArrayAssumeByteDomain [|7, 9, 8|])
False
```

### `startsWith`

```
startsWith : Bytes -> Bytes -> Bool
startsWith prefix b
```

Whether `b` begins with `prefix`. The empty prefix begins every byte
string.

```medaka
> startsWith (encodeUtf8 "he") (encodeUtf8 "hello")
True
> startsWith (encodeUtf8 "lo") (encodeUtf8 "hello")
False
```

### `endsWith`

```
endsWith : Bytes -> Bytes -> Bool
endsWith suffix b
```

Whether `b` ends with `suffix`. The empty suffix ends every byte string.

```medaka
> endsWith (encodeUtf8 "lo") (encodeUtf8 "hello")
True
> endsWith (encodeUtf8 "he") (encodeUtf8 "hello")
False
```

## Iteration

### `fold`

```
fold : (b -> Int -> <e> b) -> b -> Bytes -> <e> b
fold f init _
```

The result of applying `f` to an accumulator and each byte of `b` in
turn, starting from `init` and reading left to right.

Each byte is passed as an `Int`. This is a plain function, not
`Foldable`'s method, and named in an import list it shadows the prelude's
`fold` for the whole importing module.

```medaka
> fold (acc b => acc + b) 0 (fromArrayAssumeByteDomain [|1, 2, 3|])
6
> fold (acc b => acc + b) 0 (fromArrayAssumeByteDomain [||])
0
```

### `forEach`

```
forEach : (Int -> <e> Unit) -> Bytes -> <e> Unit
forEach f _
```

Runs `f` on each byte of `b` in order, for its effect.

```medaka
> let acc = Ref [] in let _ = forEach (x => acc := x :: !acc) (fromArrayAssumeByteDomain [|7, 8, 9|]) in !acc
[9, 8, 7]
```

### `any`

```
any : (Int -> <e> Bool) -> Bytes -> <e> Bool
any f _
```

Whether at least one byte of `b` satisfies `f`. `False` on an empty byte
string. Stops at the first byte that satisfies `f`.

```medaka
> any (x => x > 200) (fromArrayAssumeByteDomain [|1, 250, 3|])
True
> any (x => x > 200) (fromArrayAssumeByteDomain [|1, 2, 3|])
False
```

### `all`

```
all : (Int -> <e> Bool) -> Bytes -> <e> Bool
all f _
```

Whether every byte of `b` satisfies `f`. `True` on an empty byte string.
Stops at the first byte that does not satisfy `f`.

```medaka
> all (x => x < 200) (fromArrayAssumeByteDomain [|1, 2, 3|])
True
> all (x => x < 200) (fromArrayAssumeByteDomain [|1, 250, 3|])
False
```

### `map`

```
map : (Int -> <e> Int) -> Bytes -> <e> Bytes
map f _
```

The byte string of the same length holding `f` applied to each byte of
`b`.

Panics when `f` answers a value outside `0` to `255`.

```medaka
> toArray (map (x => x + 1) (fromArrayAssumeByteDomain [|7, 8, 9|]))
[|8, 9, 10|]
```

## Combining

### `concat`

```
concat : List Bytes -> Bytes
concat parts
```

The byte strings joined end to end, in one new byte string.

```medaka
> toArray (concat [fromArrayAssumeByteDomain [|1, 2|], fromArrayAssumeByteDomain [|3|]])
[|1, 2, 3|]
> decodeUtf8 (concat [encodeUtf8 "hé", encodeUtf8 "llo"])
Some "héllo"
```

## Text

### `encodeUtf8`

```
encodeUtf8 : String -> Bytes
encodeUtf8 s
```

The UTF-8 encoding of `s`.

A codepoint outside ASCII encodes to several bytes, so the byte count is
at least the codepoint count.

```medaka
> length (encodeUtf8 "héllo")
6
```

### `decodeUtf8`

```
decodeUtf8 : Bytes -> Option String
```

The string `b` encodes, read as UTF-8, or `None` when `b` is not valid
UTF-8.

Every byte sequence that is not a well-formed UTF-8 encoding of Unicode
scalar values is refused: a stray continuation byte, a truncated
sequence, an overlong form, a surrogate, and anything above U+10FFFF.
`decodeUtf8Lossy` substitutes U+FFFD for each of those instead of
refusing. `decodeUtf8 (encodeUtf8 s)` is `Some s` for every `s`.

```medaka
> decodeUtf8 (encodeUtf8 "héllo→")
Some "héllo→"
> decodeUtf8 (fromArrayAssumeByteDomain [|0xff, 0xfe, 104, 105|])
None
> decodeUtf8 (fromArrayAssumeByteDomain [|0xe2, 0x82|])
None
```

### `decodeUtf8Lossy`

```
decodeUtf8Lossy : Bytes -> String
```

The string `b` encodes, read as UTF-8, with one U+FFFD replacement
character substituted for each ill-formed sequence.

The non-failing form of `decodeUtf8`. Substitution follows the WHATWG
rule of one replacement character per maximal subpart, so a truncated
three-byte sequence becomes one U+FFFD and three stray continuation
bytes become three. The result is valid UTF-8 whatever `b` holds.

```medaka
> decodeUtf8Lossy (encodeUtf8 "héllo→")
"héllo→"
> decodeUtf8Lossy (fromArrayAssumeByteDomain [|0xff, 0xfe, 104, 105|])
"��hi"
```

## Output

### `writeStdoutBytes`

```
writeStdoutBytes : Bytes -> <Stdout> Unit
```

Writes the bytes of `b` to standard output, unchanged.

The bytes need not be valid UTF-8. Nothing decodes or re-encodes them, so
a sequence that a `String` path would reject or alter is written exactly
as it is.

## Runtime interop

### `fromByteBlockPrefix`

```
fromByteBlockPrefix : Int -> ByteBlock -> Bytes
fromByteBlockPrefix n bb
```

The first `n` bytes of `bb`, copied into a byte string.

No range check is needed: a `ByteBlock` holds one byte per element. The
result is a copy, so a later write to `bb` does not reach it. Taking a
length lets a caller freeze the live prefix of a larger buffer.

Panics when `n` is negative or greater than the block's length.

```medaka
> toArray (fromByteBlockPrefix 2 (byteBlockFromString "hip"))
[|104, 105|]
```

### `adoptByteBlockUnsafe`

```
adoptByteBlockUnsafe : ByteBlock -> Bytes
adoptByteBlockUnsafe bb
```

The byte string holding `bb` itself, with no copy.

The byte string and `bb` share storage, so a write to `bb` afterwards
changes the byte string. Adopt only a block that nothing else will write
to. The whole block becomes the byte string; for the live prefix of a
larger buffer use `fromByteBlockPrefix`.

```medaka
> toArray (adoptByteBlockUnsafe (byteBlockFromString "hi"))
[|104, 105|]
```

### `lendByteBlockUnsafe`

```
lendByteBlockUnsafe : Bytes -> ByteBlock
```

The block `b` is built on, with no copy.

The counterpart of `adoptByteBlockUnsafe`, for a caller that reads or
blits the bytes without paying for `toArray`'s copy. The block is the
byte string's own storage, so a write to it changes a value that is meant
to be immutable. Read it; do not write it.

```medaka
> byteBlockLength (lendByteBlockUnsafe (encodeUtf8 "héllo"))
6
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

The result is a copy, not a view onto `b`. Panics with a slice error when
the range runs outside the byte string, as `Slice (Array a)` does.

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

The bytes of the left operand followed by the bytes of the right, in a
new byte string.

`b1 ++ b2` reaches this instance from every position: infix, in an
operator section, in a body constrained by `Semigroup`, and bound to a
name first, as `let f = (++)` or `let f = (x y => x ++ y)`. A local
binding cannot carry the constraint, so a name bound to `++` serves one
type; used at two, it is rejected, as `let f = append` is.

```medaka
> toArray (append (fromArrayAssumeByteDomain [|1, 2|]) (fromArrayAssumeByteDomain [|3|]))
[|1, 2, 3|]
> decodeUtf8 (encodeUtf8 "hé" ++ encodeUtf8 "llo")
Some "héllo"
```

### `Monoid Bytes`

```
impl Monoid Bytes
```

The byte string of no bytes, the identity for `append` and `++`.

```medaka
> toArray (empty : Bytes)
[||]
> length (append empty (encodeUtf8 "hi"))
2
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

Byte strings compare lexicographically, as the arrays of their bytes
do: byte by byte from the front, with a prefix sorting before what
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

A byte string hashes as the `Array Int` of its bytes does, so `Bytes`
can key a `hash_map.HashMap` or a `hash_set.HashSet`. Two byte strings
that are equal under
`Eq Bytes` hash alike.

```medaka
> hash (fromArrayAssumeByteDomain [|1, 2, 3|]) == hash [|1, 2, 3|]
True
```

### `Debug Bytes`

```
impl Debug Bytes
```

Renders as `Bytes "<hex>"`: lowercase, two digits per byte, with no
separator between bytes. The rendering differs from that of the
equivalent `Array Int`, so a `debug` dump tells the two apart.

```medaka
> debug (fromArrayAssumeByteDomain [|7, 8, 9|])
"Bytes \"070809\""
> debug (fromArrayAssumeByteDomain [||])
"Bytes \"\""
```

