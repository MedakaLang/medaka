# bytebuilder

A buffer for building byte arrays.

A `Builder` collects bytes in emission order. Create one with
`newBuilder`, append with the `emit` functions, and take the result with
`buildArray` or `buildBytes`. Each `emit` function writes the byte order
that `byteparser`'s matching reader expects, so a value written here and
read there comes back unchanged.

## The builder

### `Builder`

```
data Builder  -- abstract: the constructors are not exported
```

A byte buffer. Build one with `newBuilder`.

### `newBuilder`

```
newBuilder : Unit -> Builder
```

A new, empty builder. The backing block grows on the first `emit`.

### `buildArray`

```
buildArray : Builder -> Array Int
```

The bytes emitted so far, as an array.

### `buildBytes`

```
buildBytes : Builder -> Bytes
```

The bytes emitted so far, as a `Bytes`.

The packed counterpart of `buildArray`: the same bytes in the same order,
one byte each rather than one boxed machine word each. The result is a
copy, so emitting more afterwards does not reach it.

```medaka
> let buf = newBuilder () in let _ = emitBytes (fromArrayAssumeByteDomain [|0, 128, 255|]) buf in debug (buildBytes buf)
"Bytes \"0080ff\""
```

## Emitting

### `emitU8`

```
emitU8 : Int -> Builder -> Unit
```

Appends one byte. Panics when `b` falls outside `0` to `255`.

### `emitBytes`

```
emitBytes : Bytes -> Builder -> Unit
```

Appends every byte of `src`, in order.

The backing block grows at most once per call, so appending `n` bytes
costs `O(n)` whatever the builder's current capacity.

```medaka
> let buf = newBuilder () in let _ = emitBytes (encodeUtf8 "hi") buf in let _ = emitBytes (encodeUtf8 "!") buf in debug (buildBytes buf)
"Bytes \"686921\""
> let buf = newBuilder () in let _ = emitBytes (encodeUtf8 "") buf in debug (buildBytes buf)
"Bytes \"\""
```

### `builderParts`

```
builderParts : Builder -> (Bytes, Int)
```

The builder's backing block as a `Bytes`, and the number of bytes
emitted so far, without copying.

The byte string is the builder's own block, so it may be longer than the
count, and bytes at or past the count are unwritten scratch. A later
`emit` writes into that block or replaces it, so read the first `len`
bytes before emitting again. `buildBytes` is the copying form.

```medaka
> let buf = newBuilder () in let _ = emitBytes (encodeUtf8 "hey") buf in let (_, n) = builderParts buf in n
3
```

### `emitU16BE`

```
emitU16BE : Int -> Builder -> Unit
```

Appends a two-byte unsigned integer, most significant byte first. The
inverse of `beUint 2`.

### `emitU24BE`

```
emitU24BE : Int -> Builder -> Unit
```

Appends a three-byte unsigned integer, most significant byte first.
The inverse of `beUint 3`.

### `emitU32BE`

```
emitU32BE : Int -> Builder -> Unit
```

Appends a four-byte unsigned integer, most significant byte first. The
inverse of `beUint 4`.

### `emitU16LE`

```
emitU16LE : Int -> Builder -> Unit
```

Appends a two-byte unsigned integer, least significant byte first. The
inverse of `leUint 2`.

### `emitU24LE`

```
emitU24LE : Int -> Builder -> Unit
```

Appends a three-byte unsigned integer, least significant byte first.
The inverse of `leUint 3`.

### `emitU32LE`

```
emitU32LE : Int -> Builder -> Unit
```

Appends a four-byte unsigned integer, least significant byte first. The
inverse of `leUint 4`.

### `emitBeSint`

```
emitBeSint : Int -> Int -> Builder -> Unit
```

Appends a signed integer as `nbytes` bytes in two's complement, most
significant byte first. The inverse of `beSint nbytes`.

### `emitBeUint`

```
emitBeUint : Int -> Int -> Builder -> Unit
```

Appends a non-negative integer as `nbytes` bytes, most significant
byte first. The inverse of `beUint nbytes`.

### `emitLeSint`

```
emitLeSint : Int -> Int -> Builder -> Unit
```

Appends a signed integer as `nbytes` bytes in two's complement, least
significant byte first. The inverse of `leSint nbytes`.

### `emitLeUint`

```
emitLeUint : Int -> Int -> Builder -> Unit
```

Appends a non-negative integer as `nbytes` bytes, least significant
byte first. The inverse of `leUint nbytes`.

