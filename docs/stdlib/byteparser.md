# byteparser

Parser combinators over `Bytes`.

A `ByteParser a` reads a `Bytes` value from a position and produces a
value or a positioned error. The single-byte primitives hand out a `U8`;
every element of `Bytes` is a byte by construction, so there is nothing
for a single-byte read to reject. Build a parser from the
primitives (`byte`, `satisfy`, `takeBytes`, the integer and float
readers) and the combinators (`many`, `orElse`, `choice`, `between`),
sequence parsers with `defer` notation, and run the result with
`runByteParser`, or `runByteParserWithin` to parse a sub-range
`[start, end)` of a larger `Bytes` value without copying it.

Parsers backtrack: a failed parser never advances the position, and
`orElse p q` runs `q` from the position where `p` started. The integer
readers name their byte order and width, as in `beUint 4` for a four-byte
big-endian unsigned integer and `leSint 2` for a two-byte little-endian
signed one. An `Int` reader fails rather than wrap when the value does not
fit `Int`, which only an eight-byte value can do. `beU16`, `beU32`,
`beU64`, `leU16`, `leU32` and `leU64` read a fixed-width unsigned value as
its own type, `U64` included. `bytebuilder`'s emit functions write the same
encodings.

## Results and parsers

### `BResult`

```
data BResult a
  = BOk a Int
  | BErr String Int
```

The outcome of running a parser from a position.

`BOk` carries the value and the position just past the bytes consumed.
`BErr` carries a message and the position where parsing failed. Match on
these directly when a decoder needs position-level control beyond what
the combinators give.

Instances: `Mappable`

### `ByteParserE`

```
data ByteParserE (e : Effect) a
  = ByteParserE (Bytes -> Int -> Int -> <e> BResult a)
```

A parser indexed by the effect row `e` its steps may perform.

The wrapped function takes the input, a start position and an exclusive
end position, and returns a `BResult`. `ByteParser` fixes `e` to the empty
row, and every parser in this module has that type.

Instances: `DeferredMappable`, `DeferredApplicative`, `DeferredThenable`

### `ByteParser`

```
type ByteParser a = ByteParserE <> a
```

A parser whose steps perform no effects. Every parser this module
exports has this type.

### `runBP`

```
runBP : ByteParserE e a -> Bytes -> Int -> Int -> <e> BResult a
runBP _ input pos end
```

Runs `p` on `input` from position `pos`, bounded to `[pos, end)`, and
returns the raw `BResult`.

A primitive that delegates to another parser (rather than composing with
the combinators above) must call `runBP` with the SAME `end` it was
itself handed, never `length input` — otherwise it escapes a bound set by
`runByteParserWithin`. `runByteParser`/`runByteParserWithin` are the forms
that supply `end` themselves and return a `Result`.

```medaka
> runByteParserWithin 0 1 (ByteParserE (input pos end => runBP (takeBytes 2) input pos end)) (fromU8Array [|1, 2, 3|])
Err "unexpected end of input at byte 1"
```

### `onOk`

```
onOk : BResult a -> (a -> Int -> <e> BResult b) -> <e> BResult b
onOk _ k
```

Continues from a successful result.

Applies `k` to the value and position of a `BOk`, and passes a `BErr`
through unchanged.

## Alternatives

### `noMatch`

```
noMatch : ByteParserE e a
```

A parser that always fails, consuming nothing.

### `orElse`

```
orElse : ByteParserE e a -> ByteParserE e a -> ByteParserE e a
orElse p q
```

Tries `p`, and when it fails, runs `q` from the same starting position.

```medaka
> runByteParser (orElse (byte 1) (byte 2)) (fromU8Array [|2|])
Ok 2
```

## Primitives

### `failWith`

```
failWith : String -> ByteParser a
failWith msg
```

A parser that always fails with `msg`, consuming nothing.

### `satisfy`

```
satisfy : (U8 -> Bool) -> ByteParser U8
satisfy pred
```

One byte that satisfies `pred`.

```medaka
> runByteParser (satisfy (b => b == 65)) (fromU8Array [|65, 66, 67|])
Ok 65
> runByteParser (satisfy (b => b == 65)) (fromU8Array [|99|])
Err "unexpected byte at byte 0"
```

### `anyByte`

```
anyByte : ByteParser U8
```

Any one byte.

```medaka
> runByteParser anyByte (fromU8Array [|42|])
Ok 42
```

### `byte`

```
byte : U8 -> ByteParser U8
byte b
```

Exactly the byte `b`.

```medaka
> runByteParser (byte 0xFF) (fromU8Array [|255, 0|])
Ok 255
> runByteParser (byte 0x00) (fromU8Array [|1|])
Err "unexpected byte at byte 0"
```

### `eof`

```
eof : ByteParser Unit
```

Succeeds at the end of the input, consuming nothing.

```medaka
> runByteParser eof (fromU8Array [||])
Ok ()
> runByteParser eof (fromU8Array [|1|])
Err "expected end of input at byte 0"
```

### `peek`

```
peek : ByteParser U8
```

The byte at the current position, without consuming it. Fails at the
end of the input.

## Combinators

### `many`

```
many : ByteParser a -> ByteParser (List a)
many p
```

Zero or more `p`, until it fails.

Also stops when `p` succeeds without consuming anything, so `many` of
such a parser terminates.

```medaka
> runByteParser (many (byte 1)) (fromU8Array [|1, 1, 1, 2|])
Ok [1, 1, 1]
```

### `some`

```
some : ByteParser a -> ByteParser (List a)
some p
```

One or more `p`.

```medaka
> runByteParser (some (byte 2)) (fromU8Array [|2, 2, 3|])
Ok [2, 2]
> runByteParser (some (byte 2)) (fromU8Array [|3|])
Err "unexpected byte at byte 0"
```

### `sepBy1`

```
sepBy1 : ByteParser a -> ByteParser b -> ByteParser (List a)
sepBy1 p sep
```

One or more `p`, separated by `sep`.

### `sepBy`

```
sepBy : ByteParser a -> ByteParser b -> ByteParser (List a)
sepBy p sep
```

Zero or more `p`, separated by `sep`.

### `optional`

```
optional : ByteParser a -> ByteParser (Option a)
optional p
```

`Some` the result of `p`, or `None` when `p` fails, consuming nothing.

```medaka
> runByteParser (optional (byte 5)) (fromU8Array [|5|])
Ok Some 5
> runByteParser (optional (byte 5)) (fromU8Array [|9|])
Ok None
```

### `between`

```
between : ByteParser open -> ByteParser close -> ByteParser a -> ByteParser a
between open close p
```

The result of `p` parsed between `open` and `close`.

### `choice`

```
choice : List (ByteParser a) -> ByteParser a
```

The result of the first parser in the list that succeeds. Fails when
the list is empty or every parser fails.

### `chainl1`

```
chainl1 : ByteParser a -> ByteParser (a -> a -> a) -> ByteParser a
chainl1 p op
```

One or more `p` separated by `op`, combined from the left.

`op` yields a binary function, and each one is applied to the value so
far and the next `p`.

### `takeBytes`

```
takeBytes : Int -> ByteParser Bytes
takeBytes n
```

Exactly `n` bytes, as a `Bytes`.

Fails when fewer than `n` bytes remain, even when `n` is far larger than
any real input could hold — the bound check never overflows.

```medaka
> runByteParser (takeBytes 3) (fromU8Array [|10, 20, 30, 40|])
Ok Bytes "0a141e"
> runByteParser (deferThen anyByte (_ => takeBytes 4611686018427387903)) (fromU8Array [|10, 20, 30, 40|])
Err "unexpected end of input at byte 4"
```

## Integers and floats

### `beUint`

```
beUint : Int -> ByteParser Int
beUint n
```

An unsigned integer of `n` bytes, most significant byte first.

Fails when fewer than `n` bytes remain, and when the value is larger than
`Int` holds, which needs eight bytes or more; `beU64` reads any eight.

```medaka
> runByteParser (beUint 2) (fromU8Array [|1, 2|])
Ok 258
> runByteParser (beUint 1) (fromU8Array [|255|])
Ok 255
> runByteParser (beUint 4) (fromU8Array [|0, 0, 1, 0|])
Ok 256
> runByteParser (beUint 8) (fromU8Array [|64, 0, 0, 0, 0, 0, 0, 0|])
Err "integer does not fit Int (read a U64 with beU64 or leU64) at byte 7"
```

### `beSint`

```
beSint : Int -> ByteParser Int
beSint n
```

A signed two's-complement integer of `n` bytes, most significant byte
first.

```medaka
> runByteParser (beSint 1) (fromU8Array [|255|])
Ok -1
> runByteParser (beSint 1) (fromU8Array [|127|])
Ok 127
> runByteParser (beSint 2) (fromU8Array [|255, 255|])
Ok -1
> runByteParser (beSint 2) (fromU8Array [|0, 1|])
Ok 1
> runByteParser (beSint 9) (fromU8Array [|255, 255, 255, 255, 255, 255, 255, 255, 254|])
Ok -2
```

### `beFloat64`

```
beFloat64 : ByteParser Float
```

A 64-bit IEEE 754 float from eight bytes, most significant byte first.

```medaka
> runByteParser beFloat64 (fromU8Array [|63, 248, 0, 0, 0, 0, 0, 0|])
Ok 1.5
> runByteParser beFloat64 (fromU8Array [|192, 0, 0, 0, 0, 0, 0, 0|])
Ok -2.0
```

### `leUint`

```
leUint : Int -> ByteParser Int
leUint n
```

An unsigned integer of `n` bytes, least significant byte first.

Fails when fewer than `n` bytes remain, and when the value is larger than
`Int` holds, which needs eight bytes or more; `leU64` reads any eight.

```medaka
> runByteParser (leUint 2) (fromU8Array [|2, 1|])
Ok 258
> runByteParser (leUint 1) (fromU8Array [|255|])
Ok 255
> runByteParser (leUint 4) (fromU8Array [|0, 1, 0, 0|])
Ok 256
```

### `leSint`

```
leSint : Int -> ByteParser Int
leSint n
```

A signed two's-complement integer of `n` bytes, least significant byte
first.

```medaka
> runByteParser (leSint 1) (fromU8Array [|255|])
Ok -1
> runByteParser (leSint 1) (fromU8Array [|127|])
Ok 127
> runByteParser (leSint 2) (fromU8Array [|255, 255|])
Ok -1
> runByteParser (leSint 2) (fromU8Array [|1, 0|])
Ok 1
```

### `leFloat64`

```
leFloat64 : ByteParser Float
```

A 64-bit IEEE 754 float from eight bytes, least significant byte first.

```medaka
> runByteParser leFloat64 (fromU8Array [|0, 0, 0, 0, 0, 0, 248, 63|])
Ok 1.5
> runByteParser leFloat64 (fromU8Array [|0, 0, 0, 0, 0, 0, 0, 192|])
Ok -2.0
```

## Fixed-width unsigned readers

### `beU16`

```
beU16 : ByteParser U16
```

A `U16` from two bytes, most significant byte first. The inverse of
`bytebuilder.emitU16BE`.

```medaka
> runByteParser beU16 (fromU8Array [|1, 2|])
Ok 258
```

### `beU32`

```
beU32 : ByteParser U32
```

A `U32` from four bytes, most significant byte first. The inverse of
`bytebuilder.emitU32BE`.

```medaka
> runByteParser beU32 (fromU8Array [|255, 255, 255, 255|])
Ok 4294967295
```

### `beU64`

```
beU64 : ByteParser U64
```

A `U64` from eight bytes, most significant byte first. The inverse of
`bytebuilder.emitU64BE`. Every eight-byte value fits, so this never
fails for want of range.

```medaka
> runByteParser beU64 (fromU8Array [|255, 255, 255, 255, 255, 255, 255, 255|])
Ok 18446744073709551615
```

### `leU16`

```
leU16 : ByteParser U16
```

A `U16` from two bytes, least significant byte first. The inverse of
`bytebuilder.emitU16LE`.

```medaka
> runByteParser leU16 (fromU8Array [|2, 1|])
Ok 258
```

### `leU32`

```
leU32 : ByteParser U32
```

A `U32` from four bytes, least significant byte first. The inverse of
`bytebuilder.emitU32LE`.

```medaka
> runByteParser leU32 (fromU8Array [|4, 3, 2, 1|])
Ok 16909060
```

### `leU64`

```
leU64 : ByteParser U64
```

A `U64` from eight bytes, least significant byte first. The inverse of
`bytebuilder.emitU64LE`.

```medaka
> runByteParser leU64 (fromU8Array [|21, 124, 74, 127, 185, 121, 55, 158|])
Ok 11400714819323198485
```

## Running a parser

### `runByteParser`

```
runByteParser : ByteParser a -> Bytes -> Result String a
runByteParser p bytes
```

The result of running `p` on `bytes` from position `0`.

`Err` carries the failure message and the byte position where it
happened. Bytes left over after `p` succeeds are not an error; sequence
`p` with `eof` to require that the whole input is consumed.

```medaka
> runByteParser (byte 42) (fromU8Array [|42|])
Ok 42
> runByteParser (byte 42) (fromU8Array [|7|])
Err "unexpected byte at byte 0"
```

### `runByteParserWithin`

```
runByteParserWithin : Int -> Int -> ByteParser a -> Bytes -> Result String a
runByteParserWithin start end p bytes
```

The result of running `p` on the half-open sub-range `[start, end)` of
`bytes`, without copying it.

Behaves as running `p` on `bytes.[start..end]` would, but every length
check inside `p` sees `end` rather than `bytes`' own length, so a parser
that reads to the end of its input stops at `end`, not at the end of the
larger `bytes` value it was carved from. A position in a returned `Err`
is always an absolute offset into `bytes` itself, never relative to
`start`. `start < 0`, `end < start` or `end > length bytes` is a
malformed range and fails without running `p` at all, rather than
parsing an empty or truncated input.

```medaka
> runByteParserWithin 1 3 (many anyByte) (fromU8Array [|10, 20, 30, 40|])
Ok [20, 30]
> runByteParserWithin 0 1 beU16 (fromU8Array [|1, 2|])
Err "unexpected end of input at byte 1"
> runByteParserWithin 2 1 anyByte (fromU8Array [|1, 2, 3|])
Err "invalid range [2, 1) for input of length 3"
```

