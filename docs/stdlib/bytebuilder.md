# bytebuilder

bytebuilder — a byte-level output builder for Medaka.

Symmetric inverse of `byteparser`: where `byteparser` DECODES byte arrays
into values, `bytebuilder` ENCODES values INTO byte arrays.  Backed by a
`Vector Int` (growable, amortised-O(1) `push`); `buildArray` freezes the
live range into a fixed-size `Array Int` in emission order — no reverse pass.

All `emit*` functions write bytes in the byte order that `byteparser`'s
matching decoder expects, so a round-trip `encode → decode` reproduces the
original value exactly.

## `Builder`

```
data Builder
  = Builder (Vector Int)
```

A byte output buffer backed by a growable `Vector Int`.
  Bytes are appended in O(1) (amortised); `buildArray` snapshots to a
  fixed-size `Array Int` in emission order.
  The constructor is not exported — use `newBuilder`/`emit*`/`buildArray`.

## `newBuilder`

```
newBuilder : Unit -> Builder
```

Create a new, empty builder.

## `emitU8`

```
emitU8 : Int -> Builder -> Unit
```

Emit one byte (masked to low 8 bits).

## `emitU16BE`

```
emitU16BE : Int -> Builder -> Unit
```

Emit a big-endian 2-byte unsigned integer.
  Inverse of `beUint 2`.

## `emitU24BE`

```
emitU24BE : Int -> Builder -> Unit
```

Emit a big-endian 3-byte unsigned integer.
  Inverse of `beUint 3`.

## `emitU32BE`

```
emitU32BE : Int -> Builder -> Unit
```

Emit a big-endian 4-byte unsigned integer.
  Inverse of `beUint 4`.

## `emitU16LE`

```
emitU16LE : Int -> Builder -> Unit
```

Emit a little-endian 2-byte unsigned integer.
  Inverse of `leUint 2`.  Byte order is the reverse of `emitU16BE`.

## `emitU24LE`

```
emitU24LE : Int -> Builder -> Unit
```

Emit a little-endian 3-byte unsigned integer.
  Inverse of `leUint 3`.  Byte order is the reverse of `emitU24BE`.

## `emitU32LE`

```
emitU32LE : Int -> Builder -> Unit
```

Emit a little-endian 4-byte unsigned integer.
  Inverse of `leUint 4`.  Byte order is the reverse of `emitU32BE`.

## `emitBytes`

```
emitBytes : List Int -> Builder -> Unit
```

Emit a list of byte values, each masked to low 8 bits.
  Inverse of `takeBytes (length xs)`.

## `emitBeSint`

```
emitBeSint : Int -> Int -> Builder -> Unit
```

Emit an `nbytes`-wide big-endian two's-complement signed integer.
  Inverse of `beSint nbytes`.

## `emitBeUint`

```
emitBeUint : Int -> Int -> Builder -> Unit
```

Emit exactly `nbytes` bytes of a non-negative integer in big-endian order.
  Inverse of `beUint nbytes`.
  The unsigned mirror of `emitBeSint`; useful when the value is always
  non-negative and you want to choose the width dynamically at runtime.

## `emitLeSint`

```
emitLeSint : Int -> Int -> Builder -> Unit
```

Emit an `nbytes`-wide little-endian two's-complement signed integer.
  Inverse of `leSint nbytes`.

## `emitLeUint`

```
emitLeUint : Int -> Int -> Builder -> Unit
```

Emit exactly `nbytes` bytes of a non-negative integer in little-endian
  order.  Inverse of `leUint nbytes`.  The unsigned mirror of `emitLeSint`.

## `buildArray`

```
buildArray : Builder -> Array Int
```

Extract the accumulated bytes as a fixed-size `Array Int`.
  Bytes are already in emission order (no reverse pass needed).

