# byteparser

Parser combinators over bytes.

A `ByteParser a` reads an `Array Int` of bytes from a position and
produces a value or a positioned error. Build parsers from the
primitives (`byte`, `satisfy`, `takeBytes`, `beUint`, `leSint`, and the
rest), combine them with `do` notation and the combinators (`many`,
`optional`, `choice`, `between`), and run one with `runByteParser`.

`orElse` backtracks fully: when the first parser fails, the second runs
from the same position. `bytebuilder` is the module that writes bytes.

## Types

### `BResult`

```
data BResult a
  = BOk a Int
  | BErr String Int
```

The outcome of a parse: `BOk` with the value and the position just
past what was consumed, or `BErr` with a message and the position of
the failure.

Match on it directly when a decoder needs byte-precise control of the
position.

Instances: [`Mappable`](#mappable-bresult)

### `ByteParser`

```
data ByteParser a
  = ByteParser (Array Int -> Int -> BResult a)
```

A parser: a function from the input bytes and a position to a result.

Instances: `Mappable`, `Applicative`, `Thenable`, [`Alternative`](#alternative-byteparser)

### `runBP`

```
runBP : ByteParser a -> Array Int -> Int -> BResult a
```

Runs a parser at a position in the input.

### `onOk`

```
onOk : BResult a -> (a -> Int -> BResult b) -> BResult b
```

Passes a successful result's value and position to a continuation, or
returns the error as it is.

Chains position-threading steps without repeating the error
pass-through.

## Primitives

### `failWith`

```
failWith : String -> ByteParser a
```

A parser that always fails with a message.

### `satisfy`

```
satisfy : (Int -> Bool) -> ByteParser Int
```

One byte satisfying a predicate.

```medaka
> runByteParser (satisfy (b => b == 65)) (arrayFromList [65, 66, 67])
Ok 65
> runByteParser (satisfy (b => b == 65)) (arrayFromList [99])
Err "unexpected byte at byte 0"
```

### `anyByte`

```
anyByte : ByteParser Int
```

Any one byte.

```medaka
> runByteParser anyByte (arrayFromList [42])
Ok 42
```

### `byte`

```
byte : Int -> ByteParser Int
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

The end of the input. Consumes nothing.

```medaka
> runByteParser eof (arrayFromList [])
Ok ()
> runByteParser eof (arrayFromList [1])
Err "expected end of input at byte 0"
```

### `peek`

```
peek : ByteParser Int
```

The next byte, without consuming it.

### `takeBytes`

```
takeBytes : Int -> ByteParser (List Int)
```

Exactly `n` bytes, as a list.

```medaka
> runByteParser (takeBytes 3) (arrayFromList [10, 20, 30, 40])
Ok [10, 20, 30]
```

### `takeSlice`

```
takeSlice : Int -> ByteParser (Array Int)
```

Exactly `n` bytes, as an array.

## Combinators

### `many`

```
many : ByteParser a -> ByteParser (List a)
```

Zero or more repetitions of a parser, as a list.

Stops when the parser fails or consumes nothing.

```medaka
> runByteParser (many (byte 1)) (arrayFromList [1, 1, 1, 2])
Ok [1, 1, 1]
```

### `some`

```
some : ByteParser a -> ByteParser (List a)
```

One or more repetitions of a parser, as a list.

```medaka
> runByteParser (some (byte 2)) (arrayFromList [2, 2, 3])
Ok [2, 2]
> runByteParser (some (byte 2)) (arrayFromList [3])
Err "unexpected byte at byte 0"
```

### `sepBy1`

```
sepBy1 : ByteParser a -> ByteParser b -> ByteParser (List a)
```

One or more repetitions of `p`, separated by `sep`.

### `sepBy`

```
sepBy : ByteParser a -> ByteParser b -> ByteParser (List a)
```

Zero or more repetitions of `p`, separated by `sep`.

### `optional`

```
optional : ByteParser a -> ByteParser (Option a)
```

`Some` the parser's value, or `None` when it fails, consuming nothing.

```medaka
> runByteParser (optional (byte 5)) (arrayFromList [5])
Ok Some 5
> runByteParser (optional (byte 5)) (arrayFromList [9])
Ok None
```

### `between`

```
between : ByteParser open -> ByteParser close -> ByteParser a -> ByteParser a
```

`open`, then `p`, then `close`, keeping only `p`'s value.

### `choice`

```
choice : List (ByteParser a) -> ByteParser a
```

The first parser in the list that succeeds. Fails when all of them
fail.

### `chainl1`

```
chainl1 : ByteParser a -> ByteParser (a -> a -> a) -> ByteParser a
```

One or more `p` separated by `op`, folded from the left with the
function `op` produces.

## Integers and floats

### `beUint`

```
beUint : Int -> ByteParser Int
```

An unsigned integer of `n` bytes, from 1 to 8, most significant byte
first.

```medaka
> runByteParser (beUint 2) (arrayFromList [1, 2])
Ok 258
```

### `beSint`

```
beSint : Int -> ByteParser Int
```

A two's complement signed integer of `n` bytes, from 1 to 8, most
significant byte first.

```medaka
> runByteParser (beSint 1) (arrayFromList [255])
Ok -1
> runByteParser (beSint 2) (arrayFromList [0, 1])
Ok 1
```

### `beFloat64`

```
beFloat64 : ByteParser Float
```

A 64-bit IEEE 754 float, most significant byte first.

```medaka
> runByteParser beFloat64 (arrayFromList [63, 248, 0, 0, 0, 0, 0, 0])
Ok 1.5
```

### `leUint`

```
leUint : Int -> ByteParser Int
```

An unsigned integer of `n` bytes, from 1 to 8, least significant byte
first.

```medaka
> runByteParser (leUint 2) (arrayFromList [2, 1])
Ok 258
```

### `leSint`

```
leSint : Int -> ByteParser Int
```

A two's complement signed integer of `n` bytes, from 1 to 8, least
significant byte first.

```medaka
> runByteParser (leSint 1) (arrayFromList [255])
Ok -1
> runByteParser (leSint 2) (arrayFromList [1, 0])
Ok 1
```

### `leFloat64`

```
leFloat64 : ByteParser Float
```

A 64-bit IEEE 754 float, least significant byte first.

```medaka
> runByteParser leFloat64 (arrayFromList [0, 0, 0, 0, 0, 0, 248, 63])
Ok 1.5
```

## Running a parser

### `runByteParser`

```
runByteParser : ByteParser a -> Array Int -> Result String a
```

The value a parser produces from the start of the input, or `Err` with
the message and the byte position of the failure.

```medaka
> runByteParser (byte 42) (arrayFromList [42])
Ok 42
> runByteParser (byte 42) (arrayFromList [7])
Err "unexpected byte at byte 0"
```

## Instances

### `Mappable BResult`

```
impl Mappable BResult
```

`map` transforms a successful result's value and leaves an error as it
is.

### `Alternative ByteParser`

```
impl Alternative ByteParser
```

`orElse p q` runs `p`, and when it fails runs `q` from the same
position. `noMatch` always fails.

