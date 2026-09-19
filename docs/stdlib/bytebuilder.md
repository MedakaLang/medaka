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
data Builder
  = Builder (Ref ByteBlock) (Ref Int)
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
> let buf = newBuilder () in let _ = emitBytes [0, 128, 255] buf in debug (buildBytes buf)
"[|0, 128, 255|]"
> let buf = newBuilder () in let _ = emitU32BE 0x01020304 buf in debug (buildBytes buf) == debug (buildArray buf)
True
```

## Emitting

### `emitU8`

```
emitU8 : Int -> Builder -> Unit
```

Appends one byte. Only the low eight bits of the value are used.

### `emitBytes`

```
emitBytes : List Int -> Builder -> Unit
```

Appends each value in the list as one byte. The inverse of
`byteparser.takeBytes`.

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

