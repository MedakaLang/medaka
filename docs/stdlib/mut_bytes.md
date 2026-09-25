# mut_bytes

A mutable string of bytes, fixed at its allocated length.

`MutBytes` is the mutable sibling of `bytes.Bytes` and the way to build a
byte string a byte at a time. `make` allocates `n` zero bytes,
`setInPlace` writes one, `fill` writes them all, `blit` copies a run from
one into another, and `freeze` hands back an immutable `Bytes`. `thaw`
goes the other way. Both `freeze` and `thaw` copy, so neither result
shares storage with its source.

`length` is the byte count, `get` reads one byte as an `Option`, and
`mb[i]` is the panicking form. A byte is a `U8`, as in `Bytes`, so a
write cannot be out of range; every write checks its index.

`length` is also a prelude name, and `make`, `get`, `setInPlace`, `fill`
and `blit` are also exported by `array`. Import the module qualified, as
`import mut_bytes as MB`, in a file that also imports `array`.

### `MutBytes`

```
newtype MutBytes = MutBytes ByteBlock
```

The mutable byte-string type.

The constructor is private. Build a value with `make` or `thaw`, and read
it back as a `Bytes` with `freeze`.

```medaka
> length (make 3)
3
```

Instances: [`Index`](#index-mutbytes-int-u8), [`Debug`](#debug-mutbytes)

## Allocation

### `make`

```
make : Int -> MutBytes
make n
```

A mutable byte string of `n` zero bytes.

Panics when `n` is negative.

```medaka
> get 2 (make 3) |> option (-1) U8.toInt
0
```

## Reading

### `length`

```
length : MutBytes -> Int
length mb
```

The number of bytes in `mb`, fixed when it was allocated.

```medaka
> length (make 4)
4
```

### `get`

```
get : Int -> MutBytes -> Option U8
get i mb
```

The byte at index `i` of `mb`, or `None` when `i` is out of range.

`mb[i]` is the panicking form: on the same out-of-range index, `get`
answers `None` where `mb[i]` raises an index error.

```medaka
> get 1 (make 2) |> option (-1) U8.toInt
0
> get 2 (make 2)
None
> get (-1) (make 2)
None
```

## Writing

### `setInPlace`

```
setInPlace : Int -> U8 -> MutBytes -> Unit
setInPlace i v mb
```

Replaces the byte at index `i` of `mb` with `v`.

Panics when `i` is out of range.

```medaka
> let mb = make 2 in let _ = setInPlace 0 65 mb in get 0 mb |> option (-1) U8.toInt
65
```

### `fill`

```
fill : U8 -> MutBytes -> Unit
fill v mb
```

Replaces every byte of `mb` with `v`.

```medaka
> let mb = make 3 in let _ = fill 7 mb in debug mb
"MutBytes \"070707\""
```

### `blit`

```
blit : MutBytes -> Int -> MutBytes -> Int -> Int -> Unit
blit src srcOff dst dstOff len
```

Copies `len` bytes from `src`, starting at `srcOff`, into `dst`, starting
at `dstOff`.

Panics when any argument is negative or the copy would run past the end
of either byte string.

`src` and `dst` may be the same `MutBytes` and the two runs may overlap.
Every source byte is read as it was before any byte was written.

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
freeze mb
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
thaw b
```

A mutable copy of `b`.

A write to the result does not reach `b`.

```medaka
> let b = encodeUtf8 "hi" in let mb = thaw b in let _ = setInPlace 0 65 mb in (toArray b, toArray (freeze mb))
([|104, 105|], [|65, 105|])
```

## Instances

### `Index MutBytes Int U8`

```
impl Index MutBytes Int U8
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

Renders as `MutBytes "<hex>"`, in the lowercase hex form `Debug Bytes`
uses, from the buffer's current contents.

```medaka
> debug (make 0)
"MutBytes \"\""
> let mb = make 2 in let _ = setInPlace 0 255 mb in debug mb
"MutBytes \"ff00\""
```

