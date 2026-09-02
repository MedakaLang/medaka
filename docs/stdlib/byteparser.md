# byteparser

byteparser — a binary parser-combinator library for Medaka.

A structural transcription of `parsec/lib/parser.mdk` with `Array Char`
replaced by `Array Int` (bytes), `Char` replaced by `Int`, and
char-specific helpers replaced by byte/binary-specific primitives.

A `ByteParser a` wraps a function from (byte array + position) to a
`BResult a`, which is either success (value + new position) or failure
(message + position).  Position threading is EXPLICIT — there is no hidden
state monad; every primitive returns the position it consumed up to.

The type is given `DeferredMappable` / `DeferredApplicative` /
`DeferredThenable` instances so that
`defer`-notation sequences parsers, and a plain `orElse`/`noMatch` pair whose
`orElse` is LEFT-BIASED with FULL BACKTRACKING: `orElse p q` tries `p` at
the current position; if `p` fails it runs `q` at the SAME position (the
input is immutable and we never mutate the position on failure, so
backtracking is automatic).

Binary-specific primitives:
  `beUint n`  — big-endian unsigned n-byte integer
  `beSint n`  — big-endian signed n-byte integer (two's-complement)
  `beFloat64` — 64-bit IEEE 754 big-endian float
  `leUint n`  — little-endian unsigned n-byte integer
  `leSint n`  — little-endian signed n-byte integer (two's-complement)
  `leFloat64` — 64-bit IEEE 754 little-endian float

## `BResult`

```
data BResult a
  = BOk a Int
  | BErr String Int
```

Parse result: success carries the value and the position just past what
  was consumed; failure carries an error message and the failure position.
  `public export` so downstream modules (e.g. a SQLite record decoder) can
  pattern-match `BOk`/`BErr` directly when they need byte-precise position
  control beyond what the monadic combinators give.

Instances: [`Mappable`](#mappable-bresult)

## `ByteParserE`

```
data ByteParserE (e : Effect) a
  = ByteParserE (Array Int -> Int -> <e> BResult a)
```

A byte-level parser is a function from (byte array, position) to BResult.
  It STORES that function rather than running it, so the type indexes the
  container by the row the stored arrow performs (`Deferred*`, core.mdk /
  #825).  Charging a callback's row on the combinator's own arrow — what the
  plain `Mappable`/`Applicative`/`Thenable` family does — would force the
  stored arrow pure and run an effectful callback inside a value typed `<>`.
  Decoding bytes performs nothing, so the exported `ByteParser a` alias pins
  the index to `<>` and every existing signature keeps its meaning.

Instances: `DeferredMappable`, `DeferredApplicative`, `DeferredThenable`

## `ByteParser`

```
type ByteParser a = ByteParserE <> a
```

## `runBP`

```
runBP : ByteParserE e a -> Array Int -> Int -> <e> BResult a
```

Run the wrapped function directly.

## `onOk`

```
onOk : BResult a -> (a -> Int -> <e> BResult b) -> <e> BResult b
```

Position-threading bind for BResult.  On success, passes the value and
  the new position to the continuation; on failure, short-circuits.

  Lets callers chain position-threading steps without repeating the
  `BErr m ep => BErr m ep` pass-through boilerplate.

## `noMatch`

```
noMatch : ByteParserE e a
```

Left-biased, full-backtracking alternative.  Plain functions rather than an
  `Alternative` impl: that interface `requires Applicative f` at kind
  `Type -> Type`, which `ByteParserE : Effect -> Type -> Type` cannot satisfy.
  `noMatch` always fails; `orElse p q` tries `p`, and on failure re-runs
  `q` from the ORIGINAL position.

## `orElse`

```
orElse : ByteParserE e a -> ByteParserE e a -> ByteParserE e a
```

## `failWith`

```
failWith : String -> ByteParser a
```

Fail unconditionally with a message.

## `satisfy`

```
satisfy : (Int -> Bool) -> ByteParser Int
```

Consume one byte if it satisfies the predicate.

```medaka
> runByteParser (satisfy (b => b == 65)) (arrayFromList [65, 66, 67])
Ok 65
> runByteParser (satisfy (b => b == 65)) (arrayFromList [99])
Err "unexpected byte at byte 0"
```

## `anyByte`

```
anyByte : ByteParser Int
```

Consume any single byte.

```medaka
> runByteParser anyByte (arrayFromList [42])
Ok 42
```

## `byte`

```
byte : Int -> ByteParser Int
```

Consume exactly the given byte value.

```medaka
> runByteParser (byte 0xFF) (arrayFromList [255, 0])
Ok 255
> runByteParser (byte 0x00) (arrayFromList [1])
Err "unexpected byte at byte 0"
```

## `eof`

```
eof : ByteParser Unit
```

Match the end of input.  Yields Unit; consumes nothing.

```medaka
> runByteParser eof (arrayFromList [])
Ok ()
> runByteParser eof (arrayFromList [1])
Err "expected end of input at byte 0"
```

## `peek`

```
peek : ByteParser Int
```

Peek at the current byte without consuming it.

## `many`

```
many : ByteParser a -> ByteParser (List a)
```

Zero-or-more.  Uses explicit position threading (a loop), since `many`
  of a parser that consumes nothing must terminate.

```medaka
> runByteParser (many (byte 1)) (arrayFromList [1, 1, 1, 2])
Ok [1, 1, 1]
```

## `some`

```
some : ByteParser a -> ByteParser (List a)
```

One-or-more.

```medaka
> runByteParser (some (byte 2)) (arrayFromList [2, 2, 3])
Ok [2, 2]
> runByteParser (some (byte 2)) (arrayFromList [3])
Err "unexpected byte at byte 0"
```

## `sepBy1`

```
sepBy1 : ByteParser a -> ByteParser b -> ByteParser (List a)
```

One-or-more `p` separated by `sep`.

## `sepBy`

```
sepBy : ByteParser a -> ByteParser b -> ByteParser (List a)
```

Zero-or-more `p` separated by `sep`.

## `optional`

```
optional : ByteParser a -> ByteParser (Option a)
```

Try `p`; produce `Some` on success, `None` (consuming nothing) on failure.

```medaka
> runByteParser (optional (byte 5)) (arrayFromList [5])
Ok Some 5
> runByteParser (optional (byte 5)) (arrayFromList [9])
Ok None
```

## `between`

```
between : ByteParser open -> ByteParser close -> ByteParser a -> ByteParser a
```

`between open close p` parses `open`, then `p`, then `close`, yielding `p`.

## `choice`

```
choice : List (ByteParser a) -> ByteParser a
```

First successful parser in the list; fails if all fail.

## `chainl1`

```
chainl1 : ByteParser a -> ByteParser (a -> a -> a) -> ByteParser a
```

Left-associative chaining of `p` separated by operator parser `op`
  whose value is a binary function.
Structurally identical to compiler/frontend/parser.mdk's chainl1.  Both
containers are `DeferredThenable` now, but the loop tail also needs `orElse`,
which each provides as a plain function rather than through a shared
interface (`Alternative` requires `Applicative` at kind `Type -> Type`, which
an `Effect`-indexed container cannot satisfy) — so a single generic version
still has nothing to abstract over.

## `takeBytes`

```
takeBytes : Int -> ByteParser (List Int)
```

Read exactly N bytes, returning them as a List Int.

```medaka
> runByteParser (takeBytes 3) (arrayFromList [10, 20, 30, 40])
Ok [10, 20, 30]
```

## `takeSlice`

```
takeSlice : Int -> ByteParser (Array Int)
```

Read exactly N bytes, returning them as an Array Int slice.

## `beUint`

```
beUint : Int -> ByteParser Int
```

Read a big-endian unsigned integer of exactly N bytes (N in 1..8).

Examples (big-endian 2-byte: [0x01, 0x02] → 258):

```medaka
> runByteParser (beUint 2) (arrayFromList [1, 2])
Ok 258
> runByteParser (beUint 1) (arrayFromList [255])
Ok 255
> runByteParser (beUint 4) (arrayFromList [0, 0, 1, 0])
Ok 256
```

## `beSint`

```
beSint : Int -> ByteParser Int
```

Read a big-endian SIGNED integer of exactly N bytes (N in 1..8),
  two's-complement.

The sign bit is the MSB of the first byte.  For an N-byte integer the sign
threshold is 128 * 256^(N-1) = 2^(8*N-1).

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

## `beFloat64`

```
beFloat64 : ByteParser Float
```

Read a 64-bit IEEE 754 big-endian float as a Medaka Float.
Consumes exactly 8 bytes in big-endian order and reinterprets their bit
pattern as an IEEE 754 double via `bytesToFloat64`.

```medaka
> runByteParser beFloat64 (arrayFromList [63, 248, 0, 0, 0, 0, 0, 0])
Ok 1.5
> runByteParser beFloat64 (arrayFromList [192, 0, 0, 0, 0, 0, 0, 0])
Ok -2.0
```

## `leUint`

```
leUint : Int -> ByteParser Int
```

Read a little-endian unsigned integer of exactly N bytes (N in 1..8).
  Least-significant byte first (mirror of `beUint`).

Examples (little-endian 2-byte: [0x02, 0x01] → 258):

```medaka
> runByteParser (leUint 2) (arrayFromList [2, 1])
Ok 258
> runByteParser (leUint 1) (arrayFromList [255])
Ok 255
> runByteParser (leUint 4) (arrayFromList [0, 1, 0, 0])
Ok 256
```

## `leSint`

```
leSint : Int -> ByteParser Int
```

Read a little-endian SIGNED integer of exactly N bytes (N in 1..8),
  two's-complement.  Mirror of `beSint`: least-significant byte first,
  with the sign bit in the MSB of the LAST byte.

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

## `leFloat64`

```
leFloat64 : ByteParser Float
```

Read a 64-bit IEEE 754 little-endian float as a Medaka Float.
  Consumes exactly 8 bytes in little-endian order; reverses them before
  reinterpreting the bit pattern via `bytesToFloat64` (which expects
  big-endian byte order).

```medaka
> runByteParser leFloat64 (arrayFromList [0, 0, 0, 0, 0, 0, 248, 63])
Ok 1.5
> runByteParser leFloat64 (arrayFromList [0, 0, 0, 0, 0, 0, 0, 192])
Ok -2.0
```

## `runByteParser`

```
runByteParser : ByteParser a -> Array Int -> Result String a
```

Run a `ByteParser` over the full byte array starting at position 0.
  Reports the success value or a positioned error message.

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

Mappable instance for BResult: map over the success value; pass errors
  through unchanged.  Higher-kinded impl uses the BARE head `BResult`.

