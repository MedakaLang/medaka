# mut_bytes

A mutable string of bytes, fixed at its allocated length.

`MutBytes` is `bytes`'s mutable sibling and the way to build a byte string
a byte at a time. `make` allocates `n` zero bytes, `setInPlace` writes one,
`fill` writes them all, `blit` copies a run from one into another, and
`freeze` hands back an immutable `Bytes`. `thaw` goes the other way. Both
`freeze` and `thaw` copy, so neither result shares storage with its
source.

The alternative -- filling an `Array Int` and handing it to
`bytes.fromArray` -- boxes a machine word per byte before packing them,
which is the cost `Bytes` exists to avoid.

`length` is the byte count, `get` reads one byte as an `Option`, and
`mb[i]` panics on an out-of-range index instead. Every write checks both
the index and the `0` to `255` domain.

`length` is also the prelude's `Foldable` method, and `make`, `get`,
`setInPlace`, `fill` and `blit` are also `array`'s, so import this module
selectively rather than with `*`. `length` named in an import list shadows
the prelude's method for the whole importing module, so reach it through
an alias -- `import mut_bytes as MB`, then `MB.length` -- from a module
that uses both.

### `MutBytes`

```
newtype MutBytes = MutBytes ByteBlock
```

The mutable byte-string type.

The constructor is module-private, so `make` and `thaw` are the ways in
and `freeze` the way out, and nothing observes the buffer except through
the functions below.

```medaka
> length (make 3)
3
```

Instances: [`Index`](#index-mutbytes-int-int), [`Debug`](#debug-mutbytes)

## Allocation

### `make`

```
make : Int -> MutBytes
```

A mutable byte string of `n` zero bytes.

Panics when `n` is negative.

```medaka
> get 2 (make 3)
Some 0
```

## Reading

### `length`

```
length : MutBytes -> Int
```

The number of bytes in `mb`, fixed when it was allocated.

```medaka
> length (make 4)
4
```

### `get`

```
get : Int -> MutBytes -> Option Int
```

The byte at index `i` of `mb`, or `None` when `i` is out of range.

`mb[i]` is the panicking form: on the same out-of-range index, `get`
answers `None` where `mb[i]` raises an index error.

```medaka
> get 1 (make 2)
Some 0
> get 2 (make 2)
None
> get (-1) (make 2)
None
```

## Writing

### `setInPlace`

```
setInPlace : Int -> Int -> MutBytes -> Unit
```

Replaces the byte at index `i` of `mb` with `v`.

Panics when `i` is out of range, as `array.setInPlace` does, and panics
when `v` falls outside `0` to `255` rather than keeping its low eight
bits. A masked write would put a byte into a `Bytes` that no caller asked
for, and this is the door every byte written here goes through.

```medaka
> let mb = make 2 in let _ = setInPlace 0 65 mb in get 0 mb
Some 65
```

### `fill`

```
fill : Int -> MutBytes -> Unit
```

Replaces every byte of `mb` with `v`.

`array.fill`'s counterpart. Panics when `v` falls outside `0` to `255`,
for the reason `setInPlace` does.

```medaka
> let mb = make 3 in let _ = fill 7 mb in debug mb
"MutBytes \"070707\""
```

### `blit`

```
blit : MutBytes -> Int -> MutBytes -> Int -> Int -> Unit
```

Copies `len` bytes from `src`, starting at `srcOff`, into `dst`, starting
at `dstOff`.

Panics when any argument is negative or the copy would run past either
byte string's end, as `array.blit` does.

`src` and `dst` may be the same `MutBytes` and the two runs may overlap:
every source byte is read as it was before any of them was written.

```medaka
> let src = make 2 in let _ = fill 9 src in let dst = make 4 in let _ = blit src 0 dst 1 2 in debug dst
"MutBytes \"00090900\""
> let mb = make 4 in let _ = setInPlace 0 1 mb in let _ = setInPlace 1 2 mb in let _ = blit mb 0 mb 1 2 in debug mb
"MutBytes \"01010200\""
```

## Crossing to `Bytes`

### `freeze`

```
freeze : MutBytes -> Bytes
```

The bytes of `mb` as an immutable `Bytes`.

The result is a copy, so a write to `mb` afterwards does not reach it.

```medaka
> let mb = make 2 in let _ = setInPlace 1 9 mb in toArray (freeze mb)
[|0, 9|]
> let m = make 1 in let b = freeze m in let _ = setInPlace 0 7 m in toArray b
[|0|]
```

### `thaw`

```
thaw : Bytes -> MutBytes
```

A mutable copy of `b`.

`freeze`'s mirror, and a copy for the same reason: a write to the result
does not reach `b`, which hands out no way to change it.

```medaka
> let b = encodeUtf8 "hi" in let mb = thaw b in let _ = setInPlace 0 65 mb in (toArray b, toArray (freeze mb))
([|104, 105|], [|65, 105|])
```

## Instances

### `Index MutBytes Int Int`

```
impl Index MutBytes Int Int
```

`mb[i]` reads the byte at `i` in `O(1)`.

Panics with an index error when `i` is out of range; `get` is the
`Option`-returning form.

```medaka
> let mb = make 3 in let _ = setInPlace 1 8 mb in mb[1]
8
```

### `Debug MutBytes`

```
impl Debug MutBytes
```

Renders as `MutBytes "<hex>"`, in the same lowercase hex shape
`Debug Bytes` uses -- read from the live buffer, not a `freeze`d copy.

```medaka
> debug (make 0)
"MutBytes \"\""
> let mb = make 2 in let _ = setInPlace 0 255 mb in debug mb
"MutBytes \"ff00\""
```

