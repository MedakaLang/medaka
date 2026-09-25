# byteparser

Parser combinators over byte arrays.

A `ByteParser a` reads an `Array Int` of bytes, each `0` to `255`, from a
position and produces a value or a positioned error. The single-byte
primitives hand out a `U8`, and an element outside `0` to `255` is a
parse error there rather than a byte. Build a parser from the
primitives (`byte`, `satisfy`, `takeBytes`, the integer and float
readers) and the combinators (`many`, `orElse`, `choice`, `between`),
sequence parsers with `defer` notation, and run the result with
`runByteParser`.

Parsers backtrack: a failed parser never advances the position, and
`orElse p q` runs `q` from the position where `p` started. The integer
readers name their byte order and width, as in `beUint 4` for a four-byte
big-endian unsigned integer and `leSint 2` for a two-byte little-endian
signed one. `bytebuilder`'s emit functions write the same encodings.

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
  = ByteParserE (Array Int -> Int -> <e> BResult a)
```

A parser indexed by the effect row `e` its steps may perform.

The wrapped function takes the input and a start position and returns a
`BResult`. `ByteParser` fixes `e` to the empty row, and every parser in
this module has that type.

Instances: `DeferredMappable`, `DeferredApplicative`, `DeferredThenable`

### `ByteParser`

```
type ByteParser a = ByteParserE <> a
```

A parser whose steps perform no effects. Every parser this module
exports has this type.

### `runBP`

```
runBP : ByteParserE e a -> Array Int -> Int -> <e> BResult a
runBP _ input pos
```

Runs `p` on `input` from position `pos` and returns the raw `BResult`.

`runByteParser` is the form that starts at `0` and returns a `Result`.

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
> runByteParser (orElse (byte 1) (byte 2)) (arrayFromList [2])
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

Fails without consuming anything when the element at the position is
outside `0` to `255`, whatever `pred` would say.

```medaka
> runByteParser (satisfy (b => b == 65)) (arrayFromList [65, 66, 67])
Ok 65
> runByteParser (satisfy (b => b == 65)) (arrayFromList [99])
Err "unexpected byte at byte 0"
> runByteParser (satisfy (_ => True)) (arrayFromList [300])
Err "not a byte at byte 0"
```

### `anyByte`

```
anyByte : ByteParser U8
```

Any one byte.

```medaka
> runByteParser anyByte (arrayFromList [42])
Ok 42
```

### `byte`

```
byte : U8 -> ByteParser U8
byte b
```

Exactly the byte `b`.

```medaka
> runByteParser (byte 0xFF) (arrayFromList [255, 0])
Ok 255
> runByteParser (byte 0x00) (arrayFromList [1])
Err "unexpected byte at byte 0"
```

### `eof`

```
eof : ByteParser Unit
```

Succeeds at the end of the input, consuming nothing.

```medaka
> runByteParser eof (arrayFromList [])
Ok ()
> runByteParser eof (arrayFromList [1])
Err "expected end of input at byte 0"
```

### `peek`

```
peek : ByteParser U8
```

The byte at the current position, without consuming it. Fails at the
end of the input, and on an element outside `0` to `255`.

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
> runByteParser (many (byte 1)) (arrayFromList [1, 1, 1, 2])
Ok [1, 1, 1]
```

### `some`

```
some : ByteParser a -> ByteParser (List a)
some p
```

One or more `p`.

```medaka
> runByteParser (some (byte 2)) (arrayFromList [2, 2, 3])
Ok [2, 2]
> runByteParser (some (byte 2)) (arrayFromList [3])
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
> runByteParser (optional (byte 5)) (arrayFromList [5])
Ok Some 5
> runByteParser (optional (byte 5)) (arrayFromList [9])
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

Fails when fewer than `n` bytes remain.

```medaka
> runByteParser (takeBytes 3) (arrayFromList [10, 20, 30, 40])
Ok Bytes "0a141e"
```

### `takeSlice`

```
takeSlice : Int -> ByteParser (Array Int)
takeSlice n
```

Exactly `n` bytes, as an `Array Int`.

## Integers and floats

### `beUint`

```
beUint : Int -> ByteParser Int
beUint n
```

An unsigned integer of `n` bytes, most significant byte first.

Fails when fewer than `n` bytes remain.

```medaka
> runByteParser (beUint 2) (arrayFromList [1, 2])
Ok 258
> runByteParser (beUint 1) (arrayFromList [255])
Ok 255
> runByteParser (beUint 4) (arrayFromList [0, 0, 1, 0])
Ok 256
```

### `beSint`

```
beSint : Int -> ByteParser Int
beSint n
```

A signed two's-complement integer of `n` bytes, most significant byte
first.

```medaka
> runByteParser (beSint 1) (arrayFromList [255])
Ok -1
> runByteParser (beSint 1) (arrayFromList [127])
Ok 127
> runByteParser (beSint 2) (arrayFromList [255, 255])
Ok -1
> runByteParser (beSint 2) (arrayFromList [0, 1])
Ok 1
```

### `beFloat64`

```
beFloat64 : ByteParser Float
```

A 64-bit IEEE 754 float from eight bytes, most significant byte first.

```medaka
> runByteParser beFloat64 (arrayFromList [63, 248, 0, 0, 0, 0, 0, 0])
Ok 1.5
> runByteParser beFloat64 (arrayFromList [192, 0, 0, 0, 0, 0, 0, 0])
Ok -2.0
```

### `leUint`

```
leUint : Int -> ByteParser Int
leUint n
```

An unsigned integer of `n` bytes, least significant byte first.

Fails when fewer than `n` bytes remain.

```medaka
> runByteParser (leUint 2) (arrayFromList [2, 1])
Ok 258
> runByteParser (leUint 1) (arrayFromList [255])
Ok 255
> runByteParser (leUint 4) (arrayFromList [0, 1, 0, 0])
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
> runByteParser (leSint 1) (arrayFromList [255])
Ok -1
> runByteParser (leSint 1) (arrayFromList [127])
Ok 127
> runByteParser (leSint 2) (arrayFromList [255, 255])
Ok -1
> runByteParser (leSint 2) (arrayFromList [1, 0])
Ok 1
```

### `leFloat64`

```
leFloat64 : ByteParser Float
```

A 64-bit IEEE 754 float from eight bytes, least significant byte first.

```medaka
> runByteParser leFloat64 (arrayFromList [0, 0, 0, 0, 0, 0, 248, 63])
Ok 1.5
> runByteParser leFloat64 (arrayFromList [0, 0, 0, 0, 0, 0, 0, 192])
Ok -2.0
```

## Running a parser

### `runByteParser`

```
runByteParser : ByteParser a -> Array Int -> Result String a
runByteParser p bytes
```

The result of running `p` on `bytes` from position `0`.

`Err` carries the failure message and the byte position where it
happened. Bytes left over after `p` succeeds are not an error; sequence
`p` with `eof` to require that the whole input is consumed.

```medaka
> runByteParser (byte 42) (arrayFromList [42])
Ok 42
> runByteParser (byte 42) (arrayFromList [7])
Err "unexpected byte at byte 0"
```

