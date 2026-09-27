# META
source_lines=617
stages=DESUGAR,MARK
# SOURCE
{- | Parser combinators over `Bytes`.

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
   encodings. -}

import array.{reverse as arrayReverse}
import bytes.{Bytes, fromU8Array, length as bytesLength, toArray}
import list.{reverse}
import u8 as U8
import u16 as U16
import u32 as U32
import u64 as U64

-- # Results and parsers

{- | The outcome of running a parser from a position.

   `BOk` carries the value and the position just past the bytes consumed.
   `BErr` carries a message and the position where parsing failed. Match on
   these directly when a decoder needs position-level control beyond what
   the combinators give. -}
public export data BResult a = BOk a Int | BErr String Int

-- The type stores its function rather than applying it, so the container is
-- indexed by the row the stored arrow performs (the `Deferred*` family). An
-- eager application would perform `<e>` at construction and is rejected
-- (`T-EFFECT-INDEX-EAGER`). Decoding bytes performs nothing, so the exported
-- `ByteParser` alias pins the index to `<>`.
--
-- The wrapped function's third argument is the exclusive end of the range it
-- may read, and every base-level read checks against `end` rather than
-- against `input`'s own length. `runBP` takes that bound from its caller
-- rather than defaulting to `length input`, so a primitive that delegates
-- through `runBP` inherits whatever bound its own caller was given —
-- `runByteParser` passes `length input`, `runByteParserWithin` passes its
-- own `end`. Every combinator that calls into another parser threads the
-- SAME `end` through unchanged.
{- | A parser indexed by the effect row `e` its steps may perform.

   The wrapped function takes the input, a start position and an exclusive
   end position, and returns a `BResult`. `ByteParser` fixes `e` to the empty
   row, and every parser in this module has that type. -}
public export data ByteParserE (e : Effect) a =
  | ByteParserE (Bytes -> Int -> Int -> <e> BResult a)

-- | A parser whose steps perform no effects. Every parser this module
-- exports has this type.
export type ByteParser a = ByteParserE <> a

{- | Runs `p` on `input` from position `pos`, bounded to `[pos, end)`, and
   returns the raw `BResult`.

   A primitive that delegates to another parser (rather than composing with
   the combinators above) must call `runBP` with the SAME `end` it was
   itself handed, never `length input` — otherwise it escapes a bound set by
   `runByteParserWithin`. `runByteParser`/`runByteParserWithin` are the forms
   that supply `end` themselves and return a `Result`.

   > runByteParserWithin 0 1 (ByteParserE (input pos end => runBP (takeBytes 2) input pos end)) (fromU8Array [|1, 2, 3|])
   Err "unexpected end of input at byte 1" -}
export
runBP : ByteParserE e a -> Bytes -> Int -> Int -> <e> BResult a
runBP (ByteParserE f) input pos end = f input pos end

-- Higher-kinded impl over the bare head `BResult`.
export impl Mappable BResult where
  map f (BOk a p) = BOk (f a) p
  map _ (BErr m p) = BErr m p

{- | Continues from a successful result.

   Applies `k` to the value and position of a `BOk`, and passes a `BErr`
   through unchanged. -}
export
onOk : BResult a -> (a -> Int -> <e> BResult b) -> <e> BResult b
onOk (BErr m ep) _ = BErr m ep
onOk (BOk a pos) k = k a pos

-- Higher-kinded impls use the bare constructor head `ByteParserE`. Every body
-- stores its callback inside the `ByteParserE` arrow rather than applying it,
-- which is what lets the callback's row ride the index.

export impl DeferredMappable ByteParserE where
  deferMap g p = ByteParserE (input pos end => onOk (runBP
    p
    input
    pos
    end) (a p2 =>
    BOk (g a) p2))

export impl DeferredApplicative ByteParserE where
  deferPure a = ByteParserE (_ pos _ => BOk a pos)
  deferAp pf pa = ByteParserE (input pos end => onOk (runBP
    pf
    input
    pos
    end) (f p2 => onOk (runBP pa input p2 end) (a p3 => BOk (f a) p3)))

export impl DeferredThenable ByteParserE where
  deferThen p k = ByteParserE (input pos end => onOk (runBP
    p
    input
    pos
    end) (a p2 =>
    runBP (k a) input p2 end))

-- # Alternatives

-- `noMatch` and `orElse` are plain functions rather than an `Alternative`
-- impl: that interface `requires Applicative f` at kind `Type -> Type`, which
-- `ByteParserE : Effect -> Type -> Type` cannot satisfy.

-- | A parser that always fails, consuming nothing.
export
noMatch : ByteParserE e a
noMatch = ByteParserE (_ pos _ => BErr "noMatch" pos)

{- | Tries `p`, and when it fails, runs `q` from the same starting position.

   > runByteParser (orElse (byte 1) (byte 2)) (fromU8Array [|2|])
   Ok 2 -}
export
orElse : ByteParserE e a -> ByteParserE e a -> ByteParserE e a
orElse p q = ByteParserE (input pos end => match runBP p input pos end
  BOk a pos2 => BOk a pos2
  BErr _ _ => runBP q input pos end)

-- # Primitives

-- | A parser that always fails with `msg`, consuming nothing.
export
failWith : String -> ByteParser a
failWith msg = ByteParserE (_ pos _ => BErr msg pos)

{- | One byte that satisfies `pred`.

   > runByteParser (satisfy (b => b == 65)) (fromU8Array [|65, 66, 67|])
   Ok 65
   > runByteParser (satisfy (b => b == 65)) (fromU8Array [|99|])
   Err "unexpected byte at byte 0" -}
export
satisfy : (U8 -> Bool) -> ByteParser U8
satisfy pred = ByteParserE (satisfyStep pred)

satisfyStep : (U8 -> Bool) -> Bytes -> Int -> Int -> BResult U8
satisfyStep pred input pos end
  | pos >= end = BErr "unexpected end of input" pos
  | otherwise =
    let b = input[pos]
    if pred b then BOk b (pos + 1) else BErr "unexpected byte" pos

{- | Any one byte.

   > runByteParser anyByte (fromU8Array [|42|])
   Ok 42 -}
export
anyByte : ByteParser U8
anyByte = satisfy (_ => True)

{- | Exactly the byte `b`.

   > runByteParser (byte 0xFF) (fromU8Array [|255, 0|])
   Ok 255
   > runByteParser (byte 0x00) (fromU8Array [|1|])
   Err "unexpected byte at byte 0" -}
export
byte : U8 -> ByteParser U8
byte b = satisfy (== b)

{- | Succeeds at the end of the input, consuming nothing.

   > runByteParser eof (fromU8Array [||])
   Ok ()
   > runByteParser eof (fromU8Array [|1|])
   Err "expected end of input at byte 0" -}
export
eof : ByteParser Unit
eof = ByteParserE eofStep

eofStep : Bytes -> Int -> Int -> BResult Unit
eofStep _ pos end
  | pos >= end = BOk () pos
  | otherwise = BErr "expected end of input" pos

-- | The byte at the current position, without consuming it. Fails at the
-- end of the input.
export
peek : ByteParser U8
peek = ByteParserE (input pos end =>
  if pos >= end then BErr "unexpected end of input" pos else BOk input[pos] pos)

-- # Combinators

{- | Zero or more `p`, until it fails.

   Also stops when `p` succeeds without consuming anything, so `many` of
   such a parser terminates.

   > runByteParser (many (byte 1)) (fromU8Array [|1, 1, 1, 2|])
   Ok [1, 1, 1] -}
export
many : ByteParser a -> ByteParser (List a)
many p = ByteParserE (input pos end => manyGo p input pos end [])

manyGo : ByteParser a -> Bytes -> Int -> Int -> List a -> BResult (List a)
manyGo p input pos end acc = match runBP p input pos end
  BErr _ _ => BOk (reverse acc) pos
  BOk a pos2 =>
    if pos2 == pos then
      BOk (reverse acc) pos2  -- no progress: stop to avoid infinite loop
    else
      manyGo p input pos2 end (a :: acc)

{- | One or more `p`.

   > runByteParser (some (byte 2)) (fromU8Array [|2, 2, 3|])
   Ok [2, 2]
   > runByteParser (some (byte 2)) (fromU8Array [|3|])
   Err "unexpected byte at byte 0" -}
export
some : ByteParser a -> ByteParser (List a)
some p = defer
  x <- p
  xs <- many p
  deferPure (x :: xs)

-- | One or more `p`, separated by `sep`.
export
sepBy1 : ByteParser a -> ByteParser b -> ByteParser (List a)
sepBy1 p sep = defer
  x <- p
  xs <- many (defer
    _ <- sep
    p)
  deferPure (x :: xs)

-- | Zero or more `p`, separated by `sep`.
export
sepBy : ByteParser a -> ByteParser b -> ByteParser (List a)
sepBy p sep = orElse (sepBy1 p sep) (deferPure [])

{- | `Some` the result of `p`, or `None` when `p` fails, consuming nothing.

   > runByteParser (optional (byte 5)) (fromU8Array [|5|])
   Ok Some 5
   > runByteParser (optional (byte 5)) (fromU8Array [|9|])
   Ok None -}
export
optional : ByteParser a -> ByteParser (Option a)
optional p = orElse (deferMap Some p) (deferPure None)

-- | The result of `p` parsed between `open` and `close`.
export
between : ByteParser open -> ByteParser close -> ByteParser a -> ByteParser a
between open close p = defer
  _ <- open
  x <- p
  _ <- close
  deferPure x

-- | The result of the first parser in the list that succeeds. Fails when
-- the list is empty or every parser fails.
export
choice : List (ByteParser a) -> ByteParser a
choice [] = failWith "choice: no alternatives"
choice (q :: rest) = orElse q (choice rest)

{- | One or more `p` separated by `op`, combined from the left.

   `op` yields a binary function, and each one is applied to the value so
   far and the next `p`. -}
export
chainl1 : ByteParser a -> ByteParser (a -> a -> a) -> ByteParser a
-- Structurally identical to compiler/frontend/parser.mdk's chainl1. Both
-- containers are `DeferredThenable`, but the loop tail also needs `orElse`,
-- which each provides as a plain function rather than through a shared
-- interface, so a single generic version has nothing to abstract over.
-- lint-disable-next-line rule-duplicate-body
chainl1 p op = defer
  x <- p
  chainl1Rest p op x

chainl1Rest : ByteParser a -> ByteParser (a -> a -> a) -> a -> ByteParser a
chainl1Rest p op acc =
  orElse
    (defer
      f <- op
      y <- p
      chainl1Rest p op (f acc y))
    (deferPure acc)

{- | Exactly `n` bytes, as a `Bytes`.

   Fails when fewer than `n` bytes remain, even when `n` is far larger than
   any real input could hold — the bound check never overflows.

   > runByteParser (takeBytes 3) (fromU8Array [|10, 20, 30, 40|])
   Ok Bytes "0a141e"
   > runByteParser (deferThen anyByte (_ => takeBytes 4611686018427387903)) (fromU8Array [|10, 20, 30, 40|])
   Err "unexpected end of input at byte 4" -}
export
takeBytes : Int -> ByteParser Bytes
takeBytes n = ByteParserE (takeBytesStep n)

takeBytesStep : Int -> Bytes -> Int -> Int -> BResult Bytes
takeBytesStep n input pos end
  | n <= 0 = BOk (slice input pos pos) pos
  -- `end - pos` rather than `pos + n`: `n` can be an arbitrary caller-given
  -- Int (huge, even negative-looking after wraparound), and `pos + n` traps
  -- E-INT-OVERFLOW where the base once returned `Err`. The failure position
  -- is `end`, matching where the input actually ran out.
  | n > end - pos = BErr "unexpected end of input" end
  | otherwise = BOk (slice input pos (pos + n)) (pos + n)

-- # Integers and floats

{- | An unsigned integer of `n` bytes, most significant byte first.

   Fails when fewer than `n` bytes remain, and when the value is larger than
   `Int` holds, which needs eight bytes or more; `beU64` reads any eight.

   > runByteParser (beUint 2) (fromU8Array [|1, 2|])
   Ok 258
   > runByteParser (beUint 1) (fromU8Array [|255|])
   Ok 255
   > runByteParser (beUint 4) (fromU8Array [|0, 0, 1, 0|])
   Ok 256
   > runByteParser (beUint 8) (fromU8Array [|64, 0, 0, 0, 0, 0, 0, 0|])
   Err "integer does not fit Int (read a U64 with beU64 or leU64) at byte 7" -}
export
beUint : Int -> ByteParser Int
beUint n = ByteParserE (beUintGo n 0)

-- Before each step the value so far must be below 2^54, or the next byte would
-- carry it past `Int`'s largest value, 2^62 - 1.
beUintGo : Int -> Int -> Bytes -> Int -> Int -> BResult Int
beUintGo n acc input pos end
  | n <= 0 = BOk acc pos
  | pos >= end = BErr "unexpected end of input" pos
  | acc >= 18014398509481984 = BErr intRangeMessage pos
  | otherwise =
    beUintGo (n - 1) (acc * 256 + U8.toInt input[pos]) input (pos + 1) end

intRangeMessage : String
intRangeMessage = "integer does not fit Int (read a U64 with beU64 or leU64)"

{- | A signed two's-complement integer of `n` bytes, most significant byte
   first.

   > runByteParser (beSint 1) (fromU8Array [|255|])
   Ok -1
   > runByteParser (beSint 1) (fromU8Array [|127|])
   Ok 127
   > runByteParser (beSint 2) (fromU8Array [|255, 255|])
   Ok -1
   > runByteParser (beSint 2) (fromU8Array [|0, 1|])
   Ok 1
   > runByteParser (beSint 9) (fromU8Array [|255, 255, 255, 255, 255, 255, 255, 255, 254|])
   Ok -2 -}
export
beSint : Int -> ByteParser Int
beSint n
  | n <= 0 = deferPure 0
  | n >= 8 = defer
    fill <- takeBytes (n - 8)
    x <- beU64
    signedFrom64 fill x
  | otherwise = defer
    u <- beUint n
    let threshold = pow2 (8 * n - 1)
    deferPure (if u >= threshold then u - threshold * 2 else u)

-- A two's-complement value of eight bytes or more, as its low eight bytes read
-- as a `U64` and the bytes above them. It fits `Int` when bits 63 and 62 agree
-- and every byte above repeats the sign, and is then exactly the low 63 bits.
signedFrom64 : Bytes -> U64 -> ByteParser Int
signedFrom64 fill x =
  let signByte = if x >= 0x8000000000000000 then 255 else 0
  if (x < 0x4000000000000000 || x >= 0xC000000000000000)
    && allEqual signByte (toArray fill) 0 then
    deferPure (U64.toIntTruncating x)
  else
    failWith intRangeMessage

allEqual : Int -> Array Int -> Int -> Bool
allEqual b arr i = i >= arrayLength arr || arr[i] == b && allEqual b arr (i + 1)

-- 2^n by left shift; valid for n in 0..62 on a 63-bit Int.
pow2 : Int -> Int
pow2 n = shiftLeft 1 n

{- | A 64-bit IEEE 754 float from eight bytes, most significant byte first.

   > runByteParser beFloat64 (fromU8Array [|63, 248, 0, 0, 0, 0, 0, 0|])
   Ok 1.5
   > runByteParser beFloat64 (fromU8Array [|192, 0, 0, 0, 0, 0, 0, 0|])
   Ok -2.0 -}
export
beFloat64 : ByteParser Float
beFloat64 = defer
  bs <- takeBytes 8
  deferPure (bytesToFloat64 (toArray bs) 0)

{- | An unsigned integer of `n` bytes, least significant byte first.

   Fails when fewer than `n` bytes remain, and when the value is larger than
   `Int` holds, which needs eight bytes or more; `leU64` reads any eight.

   > runByteParser (leUint 2) (fromU8Array [|2, 1|])
   Ok 258
   > runByteParser (leUint 1) (fromU8Array [|255|])
   Ok 255
   > runByteParser (leUint 4) (fromU8Array [|0, 1, 0, 0|])
   Ok 256 -}
export
leUint : Int -> ByteParser Int
leUint n = ByteParserE (leUintGo n 0 0)

-- The byte at bit [shift] fits `Int` when it is below 2^(62 - shift): any byte
-- below bit 56, a byte under 64 at bit 56, and only a zero byte from bit 64 on.
leUintGo : Int -> Int -> Int -> Bytes -> Int -> Int -> BResult Int
leUintGo n shift acc input pos end
  | n <= 0 = BOk acc pos
  | pos >= end = BErr "unexpected end of input" pos
  | otherwise =
    let b = U8.toInt input[pos]
    if shift < 56 || shift == 56 && b < 64 then
      leUintGo (n - 1) (shift + 8) (acc + b * pow2 shift) input (pos + 1) end
    else if b == 0 then
      leUintGo (n - 1) (shift + 8) acc input (pos + 1) end
    else
      BErr intRangeMessage pos

{- | A signed two's-complement integer of `n` bytes, least significant byte
   first.

   > runByteParser (leSint 1) (fromU8Array [|255|])
   Ok -1
   > runByteParser (leSint 1) (fromU8Array [|127|])
   Ok 127
   > runByteParser (leSint 2) (fromU8Array [|255, 255|])
   Ok -1
   > runByteParser (leSint 2) (fromU8Array [|1, 0|])
   Ok 1 -}
export
leSint : Int -> ByteParser Int
leSint n
  | n <= 0 = deferPure 0
  | n >= 8 = defer
    x <- leU64
    fill <- takeBytes (n - 8)
    signedFrom64 fill x
  | otherwise = defer
    u <- leUint n
    let threshold = pow2 (8 * n - 1)
    deferPure (if u >= threshold then u - threshold * 2 else u)

{- | A 64-bit IEEE 754 float from eight bytes, least significant byte first.

   > runByteParser leFloat64 (fromU8Array [|0, 0, 0, 0, 0, 0, 248, 63|])
   Ok 1.5
   > runByteParser leFloat64 (fromU8Array [|0, 0, 0, 0, 0, 0, 0, 192|])
   Ok -2.0 -}
export
leFloat64 : ByteParser Float
leFloat64 = defer
  bytes <- takeBytes 8
  deferPure (bytesToFloat64 (arrayReverse (toArray bytes)) 0)

-- # Fixed-width unsigned readers

{- | A `U16` from two bytes, most significant byte first. The inverse of
   `bytebuilder.emitU16BE`.

   > runByteParser beU16 (fromU8Array [|1, 2|])
   Ok 258 -}
export
beU16 : ByteParser U16
beU16 = defer
  n <- beUint 2
  deferPure (U16.truncate n)

{- | A `U32` from four bytes, most significant byte first. The inverse of
   `bytebuilder.emitU32BE`.

   > runByteParser beU32 (fromU8Array [|255, 255, 255, 255|])
   Ok 4294967295 -}
export
beU32 : ByteParser U32
beU32 = defer
  n <- beUint 4
  deferPure (U32.truncate n)

{- | A `U64` from eight bytes, most significant byte first. The inverse of
   `bytebuilder.emitU64BE`. Every eight-byte value fits, so this never
   fails for want of range.

   > runByteParser beU64 (fromU8Array [|255, 255, 255, 255, 255, 255, 255, 255|])
   Ok 18446744073709551615 -}
export
beU64 : ByteParser U64
beU64 = ByteParserE (beU64Go 8 0)

beU64Go : Int -> U64 -> Bytes -> Int -> Int -> BResult U64
beU64Go n acc input pos end
  | n <= 0 = BOk acc pos
  | pos >= end = BErr "unexpected end of input" pos
  | otherwise =
    beU64Go (n - 1) (acc * 256 + U64.fromU8 input[pos]) input (pos + 1) end

{- | A `U16` from two bytes, least significant byte first. The inverse of
   `bytebuilder.emitU16LE`.

   > runByteParser leU16 (fromU8Array [|2, 1|])
   Ok 258 -}
export
leU16 : ByteParser U16
leU16 = defer
  n <- leUint 2
  deferPure (U16.truncate n)

{- | A `U32` from four bytes, least significant byte first. The inverse of
   `bytebuilder.emitU32LE`.

   > runByteParser leU32 (fromU8Array [|4, 3, 2, 1|])
   Ok 16909060 -}
export
leU32 : ByteParser U32
leU32 = defer
  n <- leUint 4
  deferPure (U32.truncate n)

{- | A `U64` from eight bytes, least significant byte first. The inverse of
   `bytebuilder.emitU64LE`.

   > runByteParser leU64 (fromU8Array [|21, 124, 74, 127, 185, 121, 55, 158|])
   Ok 11400714819323198485 -}
export
leU64 : ByteParser U64
leU64 = ByteParserE (leU64Go 8 0 0)

leU64Go : Int -> Int -> U64 -> Bytes -> Int -> Int -> BResult U64
leU64Go n shift acc input pos end
  | n <= 0 = BOk acc pos
  | pos >= end = BErr "unexpected end of input" pos
  | otherwise =
    let b = U64.fromU8 input[pos]
    leU64Go
      (n - 1)
      (shift + 8)
      (U64.bitOr acc (U64.shiftLeft b shift))
      input
      (pos + 1)
      end

-- # Running a parser

{- | The result of running `p` on `bytes` from position `0`.

   `Err` carries the failure message and the byte position where it
   happened. Bytes left over after `p` succeeds are not an error; sequence
   `p` with `eof` to require that the whole input is consumed.

   > runByteParser (byte 42) (fromU8Array [|42|])
   Ok 42
   > runByteParser (byte 42) (fromU8Array [|7|])
   Err "unexpected byte at byte 0" -}
export
runByteParser : ByteParser a -> Bytes -> Result String a
runByteParser p bytes = match runBP p bytes 0 (bytesLength bytes)
  BOk a _ => Ok a
  BErr m pos => Err "\{m} at byte \{pos}"

{- | The result of running `p` on the half-open sub-range `[start, end)` of
   `bytes`, without copying it.

   Behaves as running `p` on `bytes.[start..end]` would, but every length
   check inside `p` sees `end` rather than `bytes`' own length, so a parser
   that reads to the end of its input stops at `end`, not at the end of the
   larger `bytes` value it was carved from. A position in a returned `Err`
   is always an absolute offset into `bytes` itself, never relative to
   `start`. `start < 0`, `end < start` or `end > length bytes` is a
   malformed range and fails without running `p` at all, rather than
   parsing an empty or truncated input.

   > runByteParserWithin 1 3 (many anyByte) (fromU8Array [|10, 20, 30, 40|])
   Ok [20, 30]
   > runByteParserWithin 0 1 beU16 (fromU8Array [|1, 2|])
   Err "unexpected end of input at byte 1"
   > runByteParserWithin 2 1 anyByte (fromU8Array [|1, 2, 3|])
   Err "invalid range [2, 1) for input of length 3" -}
export
runByteParserWithin : Int -> Int -> ByteParser a -> Bytes -> Result String a
runByteParserWithin start end p bytes
  | start < 0 || end < start || end > bytesLength bytes =
    Err
      "invalid range [\{start}, \{end}) for input of length \{bytesLength bytes}"
  | otherwise = match runBP p bytes start end
    BOk a _ => Ok a
    BErr m pos => Err "\{m} at byte \{pos}"
# DESUGAR
(DUse false (UseGroup ("array") ((mem "reverse" false "arrayReverse"))))
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "fromU8Array" false) (mem "length" false "bytesLength") (mem "toArray" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseAlias ("u8") "U8"))
(DUse false (UseAlias ("u16") "U16"))
(DUse false (UseAlias ("u32") "U32"))
(DUse false (UseAlias ("u64") "U64"))
(DData Public "BResult" ("a") ((variant "BOk" (ConPos (TyVar "a") (TyCon "Int"))) (variant "BErr" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DData Public "ByteParserE" ("e" "a") ((variant "ByteParserE" (ConPos (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "a"))))))))) ())
(DTypeAlias true "ByteParser" ("a") (TyApp (TyApp (TyCon "ByteParserE") (TyRow () None)) (TyVar "a")))
(DTypeSig true "runBP" (TyFun (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "a"))))))))
(DFunDef false "runBP" ((PCon "ByteParserE" (PVar "f")) (PVar "input") (PVar "pos") (PVar "end")) (EApp (EApp (EApp (EVar "f") (EVar "input")) (EVar "pos")) (EVar "end")))
(DImpl true "Mappable" ((TyCon "BResult")) () ((im "map" ((PVar "f") (PCon "BOk" (PVar "a") (PVar "p"))) (EApp (EApp (EVar "BOk") (EApp (EVar "f") (EVar "a"))) (EVar "p"))) (im "map" (PWild (PCon "BErr" (PVar "m") (PVar "p"))) (EApp (EApp (EVar "BErr") (EVar "m")) (EVar "p")))))
(DTypeSig true "onOk" (TyFun (TyApp (TyCon "BResult") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "b"))))) (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "b"))))))
(DFunDef false "onOk" ((PCon "BErr" (PVar "m") (PVar "ep")) PWild) (EApp (EApp (EVar "BErr") (EVar "m")) (EVar "ep")))
(DFunDef false "onOk" ((PCon "BOk" (PVar "a") (PVar "pos")) (PVar "k")) (EApp (EApp (EVar "k") (EVar "a")) (EVar "pos")))
(DImpl true "DeferredMappable" ((TyCon "ByteParserE")) () ((im "deferMap" ((PVar "g") (PVar "p")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos") (PVar "end")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (EVar "end"))) (ELam ((PVar "a") (PVar "p2")) (EApp (EApp (EVar "BOk") (EApp (EVar "g") (EVar "a"))) (EVar "p2")))))))))
(DImpl true "DeferredApplicative" ((TyCon "ByteParserE")) () ((im "deferPure" ((PVar "a")) (EApp (EVar "ByteParserE") (ELam (PWild (PVar "pos") PWild) (EApp (EApp (EVar "BOk") (EVar "a")) (EVar "pos"))))) (im "deferAp" ((PVar "pf") (PVar "pa")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos") (PVar "end")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "pf")) (EVar "input")) (EVar "pos")) (EVar "end"))) (ELam ((PVar "f") (PVar "p2")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "pa")) (EVar "input")) (EVar "p2")) (EVar "end"))) (ELam ((PVar "a") (PVar "p3")) (EApp (EApp (EVar "BOk") (EApp (EVar "f") (EVar "a"))) (EVar "p3")))))))))))
(DImpl true "DeferredThenable" ((TyCon "ByteParserE")) () ((im "deferThen" ((PVar "p") (PVar "k")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos") (PVar "end")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (EVar "end"))) (ELam ((PVar "a") (PVar "p2")) (EApp (EApp (EApp (EApp (EVar "runBP") (EApp (EVar "k") (EVar "a"))) (EVar "input")) (EVar "p2")) (EVar "end")))))))))
(DTypeSig true "noMatch" (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")))
(DFunDef false "noMatch" () (EApp (EVar "ByteParserE") (ELam (PWild (PVar "pos") PWild) (EApp (EApp (EVar "BErr") (ELit (LString "noMatch"))) (EVar "pos")))))
(DTypeSig true "orElse" (TyFun (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")))))
(DFunDef false "orElse" ((PVar "p") (PVar "q")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos") (PVar "end")) (EMatch (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (EVar "end")) (arm (PCon "BOk" (PVar "a") (PVar "pos2")) () (EApp (EApp (EVar "BOk") (EVar "a")) (EVar "pos2"))) (arm (PCon "BErr" PWild PWild) () (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "q")) (EVar "input")) (EVar "pos")) (EVar "end")))))))
(DTypeSig true "failWith" (TyFun (TyCon "String") (TyApp (TyCon "ByteParser") (TyVar "a"))))
(DFunDef false "failWith" ((PVar "msg")) (EApp (EVar "ByteParserE") (ELam (PWild (PVar "pos") PWild) (EApp (EApp (EVar "BErr") (EVar "msg")) (EVar "pos")))))
(DTypeSig true "satisfy" (TyFun (TyFun (TyCon "U8") (TyCon "Bool")) (TyApp (TyCon "ByteParser") (TyCon "U8"))))
(DFunDef false "satisfy" ((PVar "pred")) (EApp (EVar "ByteParserE") (EApp (EVar "satisfyStep") (EVar "pred"))))
(DTypeSig false "satisfyStep" (TyFun (TyFun (TyCon "U8") (TyCon "Bool")) (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "U8")))))))
(DFunDef false "satisfyStep" ((PVar "pred") (PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "b") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (DoExpr (EIf (EApp (EVar "pred") (EVar "b")) (EApp (EApp (EVar "BOk") (EVar "b")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected byte"))) (EVar "pos"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "anyByte" (TyApp (TyCon "ByteParser") (TyCon "U8")))
(DFunDef false "anyByte" () (EApp (EVar "satisfy") (ELam (PWild) (EVar "True"))))
(DTypeSig true "byte" (TyFun (TyCon "U8") (TyApp (TyCon "ByteParser") (TyCon "U8"))))
(DFunDef false "byte" ((PVar "b")) (EApp (EVar "satisfy") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "b")))))
(DTypeSig true "eof" (TyApp (TyCon "ByteParser") (TyCon "Unit")))
(DFunDef false "eof" () (EApp (EVar "ByteParserE") (EVar "eofStep")))
(DTypeSig false "eofStep" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Unit"))))))
(DFunDef false "eofStep" (PWild (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BOk") (ELit LUnit)) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EVar "BErr") (ELit (LString "expected end of input"))) (EVar "pos")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "peek" (TyApp (TyCon "ByteParser") (TyCon "U8")))
(DFunDef false "peek" () (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EApp (EApp (EVar "BOk") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (EVar "pos"))))))
(DTypeSig true "many" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "many" ((PVar "p")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos") (PVar "end")) (EApp (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "input")) (EVar "pos")) (EVar "end")) (EListLit)))))
(DTypeSig false "manyGo" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "BResult") (TyApp (TyCon "List") (TyVar "a")))))))))
(DFunDef false "manyGo" ((PVar "p") (PVar "input") (PVar "pos") (PVar "end") (PVar "acc")) (EMatch (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (EVar "end")) (arm (PCon "BErr" PWild PWild) () (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos"))) (arm (PCon "BOk" (PVar "a") (PVar "pos2")) () (EIf (EBinOp "==" (EVar "pos2") (EVar "pos")) (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos2")) (EApp (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "input")) (EVar "pos2")) (EVar "end")) (EBinOp "::" (EVar "a") (EVar "acc")))))))
(DTypeSig true "some" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "some" ((PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "p"))) (ELam ((PVar "xs")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "x") (EVar "xs"))))))))
(DTypeSig true "sepBy1" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "b")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sepBy1" ((PVar "p") (PVar "sep")) (EApp (EApp (EVar "deferThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EApp (EApp (EVar "deferThen") (EVar "sep")) (ELam (PWild) (EVar "p"))))) (ELam ((PVar "xs")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "x") (EVar "xs"))))))))
(DTypeSig true "sepBy" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "b")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sepBy" ((PVar "p") (PVar "sep")) (EApp (EApp (EVar "orElse") (EApp (EApp (EVar "sepBy1") (EVar "p")) (EVar "sep"))) (EApp (EVar "deferPure") (EListLit))))
(DTypeSig true "optional" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "optional" ((PVar "p")) (EApp (EApp (EVar "orElse") (EApp (EApp (EVar "deferMap") (EVar "Some")) (EVar "p"))) (EApp (EVar "deferPure") (EVar "None"))))
(DTypeSig true "between" (TyFun (TyApp (TyCon "ByteParser") (TyVar "open")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "close")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyVar "a"))))))
(DFunDef false "between" ((PVar "open") (PVar "close") (PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "open")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EVar "deferThen") (EVar "close")) (ELam (PWild) (EApp (EVar "deferPure") (EVar "x")))))))))
(DTypeSig true "choice" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "ByteParser") (TyVar "a"))) (TyApp (TyCon "ByteParser") (TyVar "a"))))
(DFunDef false "choice" ((PList)) (EApp (EVar "failWith") (ELit (LString "choice: no alternatives"))))
(DFunDef false "choice" ((PCons (PVar "q") (PVar "rest"))) (EApp (EApp (EVar "orElse") (EVar "q")) (EApp (EVar "choice") (EVar "rest"))))
(DTypeSig true "chainl1" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyApp (TyCon "ByteParser") (TyVar "a")))))
(DFunDef false "chainl1" ((PVar "p") (PVar "op")) (EApp (EApp (EVar "deferThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EApp (EVar "chainl1Rest") (EVar "p")) (EVar "op")) (EVar "x")))))
(DTypeSig false "chainl1Rest" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyFun (TyVar "a") (TyApp (TyCon "ByteParser") (TyVar "a"))))))
(DFunDef false "chainl1Rest" ((PVar "p") (PVar "op") (PVar "acc")) (EApp (EApp (EVar "orElse") (EApp (EApp (EVar "deferThen") (EVar "op")) (ELam ((PVar "f")) (EApp (EApp (EVar "deferThen") (EVar "p")) (ELam ((PVar "y")) (EApp (EApp (EApp (EVar "chainl1Rest") (EVar "p")) (EVar "op")) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "y")))))))) (EApp (EVar "deferPure") (EVar "acc"))))
(DTypeSig true "takeBytes" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Bytes"))))
(DFunDef false "takeBytes" ((PVar "n")) (EApp (EVar "ByteParserE") (EApp (EVar "takeBytesStep") (EVar "n"))))
(DTypeSig false "takeBytesStep" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Bytes")))))))
(DFunDef false "takeBytesStep" ((PVar "n") (PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EVar "pos")) (EVar "pos"))) (EVar "pos")) (EIf (EBinOp ">" (EVar "n") (EBinOp "-" (EVar "end") (EVar "pos"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "end")) (EIf (EVar "otherwise") (EApp (EApp (EVar "BOk") (EApp (EApp (EApp (EVar "slice") (EVar "input")) (EVar "pos")) (EBinOp "+" (EVar "pos") (EVar "n")))) (EBinOp "+" (EVar "pos") (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "beUint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "beUint" ((PVar "n")) (EApp (EVar "ByteParserE") (EApp (EApp (EVar "beUintGo") (EVar "n")) (ELit (LInt 0)))))
(DTypeSig false "beUintGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int"))))))))
(DFunDef false "beUintGo" ((PVar "n") (PVar "acc") (PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EBinOp ">=" (EVar "acc") (ELit (LInt 18014398509481984))) (EApp (EApp (EVar "BErr") (EVar "intRangeMessage")) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "beUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 256))) (EApp (EVar "U8.toInt") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "intRangeMessage" (TyCon "String"))
(DFunDef false "intRangeMessage" () (ELit (LString "integer does not fit Int (read a U64 with beU64 or leU64)")))
(DTypeSig true "beSint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "beSint" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "deferPure") (ELit (LInt 0))) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 8))) (EApp (EApp (EVar "deferThen") (EApp (EVar "takeBytes") (EBinOp "-" (EVar "n") (ELit (LInt 8))))) (ELam ((PVar "fill")) (EApp (EApp (EVar "deferThen") (EVar "beU64")) (ELam ((PVar "x")) (EApp (EApp (EVar "signedFrom64") (EVar "fill")) (EVar "x")))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "deferThen") (EApp (EVar "beUint") (EVar "n"))) (ELam ((PVar "u")) (ELet false (PVar "threshold") (EApp (EVar "pow2") (EBinOp "-" (EBinOp "*" (ELit (LInt 8)) (EVar "n")) (ELit (LInt 1)))) (EApp (EVar "deferPure") (EIf (EBinOp ">=" (EVar "u") (EVar "threshold")) (EBinOp "-" (EVar "u") (EBinOp "*" (EVar "threshold") (ELit (LInt 2)))) (EVar "u")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "signedFrom64" (TyFun (TyCon "Bytes") (TyFun (TyCon "U64") (TyApp (TyCon "ByteParser") (TyCon "Int")))))
(DFunDef false "signedFrom64" ((PVar "fill") (PVar "x")) (EBlock (DoLet false false (PVar "signByte") (EIf (EBinOp ">=" (EVar "x") (ELit (LU64 2147483648 0))) (ELit (LInt 255)) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "<" (EVar "x") (ELit (LU64 1073741824 0))) (EBinOp ">=" (EVar "x") (ELit (LU64 3221225472 0)))) (EApp (EApp (EApp (EVar "allEqual") (EVar "signByte")) (EApp (EVar "toArray") (EVar "fill"))) (ELit (LInt 0)))) (EApp (EVar "deferPure") (EApp (EVar "U64.toIntTruncating") (EVar "x"))) (EApp (EVar "failWith") (EVar "intRangeMessage"))))))
(DTypeSig false "allEqual" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allEqual" ((PVar "b") (PVar "arr") (PVar "i")) (EBinOp "||" (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "index") (EVar "arr")) (EVar "i")) (EVar "b")) (EApp (EApp (EApp (EVar "allEqual") (EVar "b")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "pow2" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "pow2" ((PVar "n")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "n")))
(DTypeSig true "beFloat64" (TyApp (TyCon "ByteParser") (TyCon "Float")))
(DFunDef false "beFloat64" () (EApp (EApp (EVar "deferThen") (EApp (EVar "takeBytes") (ELit (LInt 8)))) (ELam ((PVar "bs")) (EApp (EVar "deferPure") (EApp (EApp (EVar "bytesToFloat64") (EApp (EVar "toArray") (EVar "bs"))) (ELit (LInt 0)))))))
(DTypeSig true "leUint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "leUint" ((PVar "n")) (EApp (EVar "ByteParserE") (EApp (EApp (EApp (EVar "leUintGo") (EVar "n")) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "leUintGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int")))))))))
(DFunDef false "leUintGo" ((PVar "n") (PVar "shift") (PVar "acc") (PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "b") (EApp (EVar "U8.toInt") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "shift") (ELit (LInt 56))) (EBinOp "&&" (EBinOp "==" (EVar "shift") (ELit (LInt 56))) (EBinOp "<" (EVar "b") (ELit (LInt 64))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "leUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "shift") (ELit (LInt 8)))) (EBinOp "+" (EVar "acc") (EBinOp "*" (EVar "b") (EApp (EVar "pow2") (EVar "shift"))))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EIf (EBinOp "==" (EVar "b") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "leUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "shift") (ELit (LInt 8)))) (EVar "acc")) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EApp (EApp (EVar "BErr") (EVar "intRangeMessage")) (EVar "pos")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "leSint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "leSint" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "deferPure") (ELit (LInt 0))) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 8))) (EApp (EApp (EVar "deferThen") (EVar "leU64")) (ELam ((PVar "x")) (EApp (EApp (EVar "deferThen") (EApp (EVar "takeBytes") (EBinOp "-" (EVar "n") (ELit (LInt 8))))) (ELam ((PVar "fill")) (EApp (EApp (EVar "signedFrom64") (EVar "fill")) (EVar "x")))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "deferThen") (EApp (EVar "leUint") (EVar "n"))) (ELam ((PVar "u")) (ELet false (PVar "threshold") (EApp (EVar "pow2") (EBinOp "-" (EBinOp "*" (ELit (LInt 8)) (EVar "n")) (ELit (LInt 1)))) (EApp (EVar "deferPure") (EIf (EBinOp ">=" (EVar "u") (EVar "threshold")) (EBinOp "-" (EVar "u") (EBinOp "*" (EVar "threshold") (ELit (LInt 2)))) (EVar "u")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "leFloat64" (TyApp (TyCon "ByteParser") (TyCon "Float")))
(DFunDef false "leFloat64" () (EApp (EApp (EVar "deferThen") (EApp (EVar "takeBytes") (ELit (LInt 8)))) (ELam ((PVar "bytes")) (EApp (EVar "deferPure") (EApp (EApp (EVar "bytesToFloat64") (EApp (EVar "arrayReverse") (EApp (EVar "toArray") (EVar "bytes")))) (ELit (LInt 0)))))))
(DTypeSig true "beU16" (TyApp (TyCon "ByteParser") (TyCon "U16")))
(DFunDef false "beU16" () (EApp (EApp (EVar "deferThen") (EApp (EVar "beUint") (ELit (LInt 2)))) (ELam ((PVar "n")) (EApp (EVar "deferPure") (EApp (EVar "U16.truncate") (EVar "n"))))))
(DTypeSig true "beU32" (TyApp (TyCon "ByteParser") (TyCon "U32")))
(DFunDef false "beU32" () (EApp (EApp (EVar "deferThen") (EApp (EVar "beUint") (ELit (LInt 4)))) (ELam ((PVar "n")) (EApp (EVar "deferPure") (EApp (EVar "U32.truncate") (EVar "n"))))))
(DTypeSig true "beU64" (TyApp (TyCon "ByteParser") (TyCon "U64")))
(DFunDef false "beU64" () (EApp (EVar "ByteParserE") (EApp (EApp (EVar "beU64Go") (ELit (LInt 8))) (ELit (LInt 0)))))
(DTypeSig false "beU64Go" (TyFun (TyCon "Int") (TyFun (TyCon "U64") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "U64"))))))))
(DFunDef false "beU64Go" ((PVar "n") (PVar "acc") (PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "beU64Go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 256))) (EApp (EVar "U64.fromU8") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "leU16" (TyApp (TyCon "ByteParser") (TyCon "U16")))
(DFunDef false "leU16" () (EApp (EApp (EVar "deferThen") (EApp (EVar "leUint") (ELit (LInt 2)))) (ELam ((PVar "n")) (EApp (EVar "deferPure") (EApp (EVar "U16.truncate") (EVar "n"))))))
(DTypeSig true "leU32" (TyApp (TyCon "ByteParser") (TyCon "U32")))
(DFunDef false "leU32" () (EApp (EApp (EVar "deferThen") (EApp (EVar "leUint") (ELit (LInt 4)))) (ELam ((PVar "n")) (EApp (EVar "deferPure") (EApp (EVar "U32.truncate") (EVar "n"))))))
(DTypeSig true "leU64" (TyApp (TyCon "ByteParser") (TyCon "U64")))
(DFunDef false "leU64" () (EApp (EVar "ByteParserE") (EApp (EApp (EApp (EVar "leU64Go") (ELit (LInt 8))) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "leU64Go" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "U64") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "U64")))))))))
(DFunDef false "leU64Go" ((PVar "n") (PVar "shift") (PVar "acc") (PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "b") (EApp (EVar "U64.fromU8") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "leU64Go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "shift") (ELit (LInt 8)))) (EApp (EApp (EVar "U64.bitOr") (EVar "acc")) (EApp (EApp (EVar "U64.shiftLeft") (EVar "b")) (EVar "shift")))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "runByteParser" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))
(DFunDef false "runByteParser" ((PVar "p") (PVar "bytes")) (EMatch (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "bytes")) (ELit (LInt 0))) (EApp (EVar "bytesLength") (EVar "bytes"))) (arm (PCon "BOk" (PVar "a") PWild) () (EApp (EVar "Ok") (EVar "a"))) (arm (PCon "BErr" (PVar "m") (PVar "pos")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString " at byte "))) (EApp (EVar "display") (EVar "pos"))) (ELit (LString "")))))))
(DTypeSig true "runByteParserWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))))
(DFunDef false "runByteParserWithin" ((PVar "start") (PVar "end") (PVar "p") (PVar "bytes")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "start") (ELit (LInt 0))) (EBinOp "<" (EVar "end") (EVar "start"))) (EBinOp ">" (EVar "end") (EApp (EVar "bytesLength") (EVar "bytes")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "invalid range [")) (EApp (EVar "display") (EVar "start"))) (ELit (LString ", "))) (EApp (EVar "display") (EVar "end"))) (ELit (LString ") for input of length "))) (EApp (EVar "display") (EApp (EVar "bytesLength") (EVar "bytes")))) (ELit (LString "")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "bytes")) (EVar "start")) (EVar "end")) (arm (PCon "BOk" (PVar "a") PWild) () (EApp (EVar "Ok") (EVar "a"))) (arm (PCon "BErr" (PVar "m") (PVar "pos")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString " at byte "))) (EApp (EVar "display") (EVar "pos"))) (ELit (LString "")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("array") ((mem "reverse" false "arrayReverse"))))
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "fromU8Array" false) (mem "length" false "bytesLength") (mem "toArray" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseAlias ("u8") "U8"))
(DUse false (UseAlias ("u16") "U16"))
(DUse false (UseAlias ("u32") "U32"))
(DUse false (UseAlias ("u64") "U64"))
(DData Public "BResult" ("a") ((variant "BOk" (ConPos (TyVar "a") (TyCon "Int"))) (variant "BErr" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DData Public "ByteParserE" ("e" "a") ((variant "ByteParserE" (ConPos (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "a"))))))))) ())
(DTypeAlias true "ByteParser" ("a") (TyApp (TyApp (TyCon "ByteParserE") (TyRow () None)) (TyVar "a")))
(DTypeSig true "runBP" (TyFun (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "a"))))))))
(DFunDef false "runBP" ((PCon "ByteParserE" (PVar "f")) (PVar "input") (PVar "pos") (PVar "end")) (EApp (EApp (EApp (EVar "f") (EVar "input")) (EVar "pos")) (EVar "end")))
(DImpl true "Mappable" ((TyCon "BResult")) () ((im "map" ((PVar "f") (PCon "BOk" (PVar "a") (PVar "p"))) (EApp (EApp (EVar "BOk") (EApp (EVar "f") (EVar "a"))) (EVar "p"))) (im "map" (PWild (PCon "BErr" (PVar "m") (PVar "p"))) (EApp (EApp (EVar "BErr") (EVar "m")) (EVar "p")))))
(DTypeSig true "onOk" (TyFun (TyApp (TyCon "BResult") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "b"))))) (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "b"))))))
(DFunDef false "onOk" ((PCon "BErr" (PVar "m") (PVar "ep")) PWild) (EApp (EApp (EVar "BErr") (EVar "m")) (EVar "ep")))
(DFunDef false "onOk" ((PCon "BOk" (PVar "a") (PVar "pos")) (PVar "k")) (EApp (EApp (EVar "k") (EVar "a")) (EVar "pos")))
(DImpl true "DeferredMappable" ((TyCon "ByteParserE")) () ((im "deferMap" ((PVar "g") (PVar "p")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos") (PVar "end")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (EVar "end"))) (ELam ((PVar "a") (PVar "p2")) (EApp (EApp (EVar "BOk") (EApp (EVar "g") (EVar "a"))) (EVar "p2")))))))))
(DImpl true "DeferredApplicative" ((TyCon "ByteParserE")) () ((im "deferPure" ((PVar "a")) (EApp (EVar "ByteParserE") (ELam (PWild (PVar "pos") PWild) (EApp (EApp (EVar "BOk") (EVar "a")) (EVar "pos"))))) (im "deferAp" ((PVar "pf") (PVar "pa")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos") (PVar "end")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "pf")) (EVar "input")) (EVar "pos")) (EVar "end"))) (ELam ((PVar "f") (PVar "p2")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "pa")) (EVar "input")) (EVar "p2")) (EVar "end"))) (ELam ((PVar "a") (PVar "p3")) (EApp (EApp (EVar "BOk") (EApp (EVar "f") (EVar "a"))) (EVar "p3")))))))))))
(DImpl true "DeferredThenable" ((TyCon "ByteParserE")) () ((im "deferThen" ((PVar "p") (PVar "k")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos") (PVar "end")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (EVar "end"))) (ELam ((PVar "a") (PVar "p2")) (EApp (EApp (EApp (EApp (EVar "runBP") (EApp (EVar "k") (EVar "a"))) (EVar "input")) (EVar "p2")) (EVar "end")))))))))
(DTypeSig true "noMatch#shadow" (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")))
(DFunDef false "noMatch#shadow" () (EApp (EVar "ByteParserE") (ELam (PWild (PVar "pos") PWild) (EApp (EApp (EVar "BErr") (ELit (LString "noMatch"))) (EVar "pos")))))
(DTypeSig true "orElse#shadow" (TyFun (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")))))
(DFunDef false "orElse#shadow" ((PVar "p") (PVar "q")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos") (PVar "end")) (EMatch (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (EVar "end")) (arm (PCon "BOk" (PVar "a") (PVar "pos2")) () (EApp (EApp (EVar "BOk") (EVar "a")) (EVar "pos2"))) (arm (PCon "BErr" PWild PWild) () (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "q")) (EVar "input")) (EVar "pos")) (EVar "end")))))))
(DTypeSig true "failWith" (TyFun (TyCon "String") (TyApp (TyCon "ByteParser") (TyVar "a"))))
(DFunDef false "failWith" ((PVar "msg")) (EApp (EVar "ByteParserE") (ELam (PWild (PVar "pos") PWild) (EApp (EApp (EVar "BErr") (EVar "msg")) (EVar "pos")))))
(DTypeSig true "satisfy" (TyFun (TyFun (TyCon "U8") (TyCon "Bool")) (TyApp (TyCon "ByteParser") (TyCon "U8"))))
(DFunDef false "satisfy" ((PVar "pred")) (EApp (EVar "ByteParserE") (EApp (EVar "satisfyStep") (EVar "pred"))))
(DTypeSig false "satisfyStep" (TyFun (TyFun (TyCon "U8") (TyCon "Bool")) (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "U8")))))))
(DFunDef false "satisfyStep" ((PVar "pred") (PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "b") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (DoExpr (EIf (EApp (EVar "pred") (EVar "b")) (EApp (EApp (EVar "BOk") (EVar "b")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected byte"))) (EVar "pos"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "anyByte" (TyApp (TyCon "ByteParser") (TyCon "U8")))
(DFunDef false "anyByte" () (EApp (EVar "satisfy") (ELam (PWild) (EVar "True"))))
(DTypeSig true "byte" (TyFun (TyCon "U8") (TyApp (TyCon "ByteParser") (TyCon "U8"))))
(DFunDef false "byte" ((PVar "b")) (EApp (EVar "satisfy") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "b")))))
(DTypeSig true "eof" (TyApp (TyCon "ByteParser") (TyCon "Unit")))
(DFunDef false "eof" () (EApp (EVar "ByteParserE") (EVar "eofStep")))
(DTypeSig false "eofStep" (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Unit"))))))
(DFunDef false "eofStep" (PWild (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BOk") (ELit LUnit)) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EVar "BErr") (ELit (LString "expected end of input"))) (EVar "pos")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "peek" (TyApp (TyCon "ByteParser") (TyCon "U8")))
(DFunDef false "peek" () (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EApp (EApp (EVar "BOk") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (EVar "pos"))))))
(DTypeSig true "many" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "many" ((PVar "p")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos") (PVar "end")) (EApp (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "input")) (EVar "pos")) (EVar "end")) (EListLit)))))
(DTypeSig false "manyGo" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "BResult") (TyApp (TyCon "List") (TyVar "a")))))))))
(DFunDef false "manyGo" ((PVar "p") (PVar "input") (PVar "pos") (PVar "end") (PVar "acc")) (EMatch (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (EVar "end")) (arm (PCon "BErr" PWild PWild) () (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos"))) (arm (PCon "BOk" (PVar "a") (PVar "pos2")) () (EIf (EBinOp "==" (EVar "pos2") (EVar "pos")) (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos2")) (EApp (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "input")) (EVar "pos2")) (EVar "end")) (EBinOp "::" (EVar "a") (EVar "acc")))))))
(DTypeSig true "some" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "some" ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "p"))) (ELam ((PVar "xs")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "x") (EVar "xs"))))))))
(DTypeSig true "sepBy1" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "b")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sepBy1" ((PVar "p") (PVar "sep")) (EApp (EApp (EMethodRef "deferThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EApp (EApp (EMethodRef "deferThen") (EVar "sep")) (ELam (PWild) (EVar "p"))))) (ELam ((PVar "xs")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "x") (EVar "xs"))))))))
(DTypeSig true "sepBy" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "b")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sepBy" ((PVar "p") (PVar "sep")) (EApp (EApp (EVar "orElse#shadow") (EApp (EApp (EVar "sepBy1") (EVar "p")) (EVar "sep"))) (EApp (EMethodRef "deferPure") (EListLit))))
(DTypeSig true "optional" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "optional" ((PVar "p")) (EApp (EApp (EVar "orElse#shadow") (EApp (EApp (EMethodRef "deferMap") (EVar "Some")) (EVar "p"))) (EApp (EMethodRef "deferPure") (EVar "None"))))
(DTypeSig true "between" (TyFun (TyApp (TyCon "ByteParser") (TyVar "open")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "close")) (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyVar "a"))))))
(DFunDef false "between" ((PVar "open") (PVar "close") (PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "open")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EVar "close")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "x")))))))))
(DTypeSig true "choice" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "ByteParser") (TyVar "a"))) (TyApp (TyCon "ByteParser") (TyVar "a"))))
(DFunDef false "choice" ((PList)) (EApp (EVar "failWith") (ELit (LString "choice: no alternatives"))))
(DFunDef false "choice" ((PCons (PVar "q") (PVar "rest"))) (EApp (EApp (EVar "orElse#shadow") (EVar "q")) (EApp (EVar "choice") (EVar "rest"))))
(DTypeSig true "chainl1" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyApp (TyCon "ByteParser") (TyVar "a")))))
(DFunDef false "chainl1" ((PVar "p") (PVar "op")) (EApp (EApp (EMethodRef "deferThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EApp (EVar "chainl1Rest") (EVar "p")) (EVar "op")) (EVar "x")))))
(DTypeSig false "chainl1Rest" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "ByteParser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyFun (TyVar "a") (TyApp (TyCon "ByteParser") (TyVar "a"))))))
(DFunDef false "chainl1Rest" ((PVar "p") (PVar "op") (PVar "acc")) (EApp (EApp (EVar "orElse#shadow") (EApp (EApp (EMethodRef "deferThen") (EVar "op")) (ELam ((PVar "f")) (EApp (EApp (EMethodRef "deferThen") (EVar "p")) (ELam ((PVar "y")) (EApp (EApp (EApp (EVar "chainl1Rest") (EVar "p")) (EVar "op")) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "y")))))))) (EApp (EMethodRef "deferPure") (EVar "acc"))))
(DTypeSig true "takeBytes" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Bytes"))))
(DFunDef false "takeBytes" ((PVar "n")) (EApp (EVar "ByteParserE") (EApp (EVar "takeBytesStep") (EVar "n"))))
(DTypeSig false "takeBytesStep" (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Bytes")))))))
(DFunDef false "takeBytesStep" ((PVar "n") (PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EVar "pos")) (EVar "pos"))) (EVar "pos")) (EIf (EBinOp ">" (EVar "n") (EBinOp "-" (EVar "end") (EVar "pos"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "end")) (EIf (EVar "otherwise") (EApp (EApp (EVar "BOk") (EApp (EApp (EApp (EMethodRef "slice") (EVar "input")) (EVar "pos")) (EBinOp "+" (EVar "pos") (EVar "n")))) (EBinOp "+" (EVar "pos") (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "beUint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "beUint" ((PVar "n")) (EApp (EVar "ByteParserE") (EApp (EApp (EVar "beUintGo") (EVar "n")) (ELit (LInt 0)))))
(DTypeSig false "beUintGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int"))))))))
(DFunDef false "beUintGo" ((PVar "n") (PVar "acc") (PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EBinOp ">=" (EVar "acc") (ELit (LInt 18014398509481984))) (EApp (EApp (EVar "BErr") (EVar "intRangeMessage")) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "beUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 256))) (EApp (EVar "U8.toInt") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "intRangeMessage" (TyCon "String"))
(DFunDef false "intRangeMessage" () (ELit (LString "integer does not fit Int (read a U64 with beU64 or leU64)")))
(DTypeSig true "beSint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "beSint" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EMethodRef "deferPure") (ELit (LInt 0))) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 8))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "takeBytes") (EBinOp "-" (EVar "n") (ELit (LInt 8))))) (ELam ((PVar "fill")) (EApp (EApp (EMethodRef "deferThen") (EVar "beU64")) (ELam ((PVar "x")) (EApp (EApp (EVar "signedFrom64") (EVar "fill")) (EVar "x")))))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "beUint") (EVar "n"))) (ELam ((PVar "u")) (ELet false (PVar "threshold") (EApp (EVar "pow2") (EBinOp "-" (EBinOp "*" (ELit (LInt 8)) (EVar "n")) (ELit (LInt 1)))) (EApp (EMethodRef "deferPure") (EIf (EBinOp ">=" (EVar "u") (EVar "threshold")) (EBinOp "-" (EVar "u") (EBinOp "*" (EVar "threshold") (ELit (LInt 2)))) (EVar "u")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "signedFrom64" (TyFun (TyCon "Bytes") (TyFun (TyCon "U64") (TyApp (TyCon "ByteParser") (TyCon "Int")))))
(DFunDef false "signedFrom64" ((PVar "fill") (PVar "x")) (EBlock (DoLet false false (PVar "signByte") (EIf (EBinOp ">=" (EVar "x") (ELit (LU64 2147483648 0))) (ELit (LInt 255)) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "<" (EVar "x") (ELit (LU64 1073741824 0))) (EBinOp ">=" (EVar "x") (ELit (LU64 3221225472 0)))) (EApp (EApp (EApp (EVar "allEqual") (EVar "signByte")) (EApp (EVar "toArray") (EVar "fill"))) (ELit (LInt 0)))) (EApp (EMethodRef "deferPure") (EApp (EVar "U64.toIntTruncating") (EVar "x"))) (EApp (EVar "failWith") (EVar "intRangeMessage"))))))
(DTypeSig false "allEqual" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allEqual" ((PVar "b") (PVar "arr") (PVar "i")) (EBinOp "||" (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EMethodRef "index") (EVar "arr")) (EVar "i")) (EVar "b")) (EApp (EApp (EApp (EVar "allEqual") (EVar "b")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "pow2" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "pow2" ((PVar "n")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "n")))
(DTypeSig true "beFloat64" (TyApp (TyCon "ByteParser") (TyCon "Float")))
(DFunDef false "beFloat64" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "takeBytes") (ELit (LInt 8)))) (ELam ((PVar "bs")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "bytesToFloat64") (EApp (EVar "toArray") (EVar "bs"))) (ELit (LInt 0)))))))
(DTypeSig true "leUint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "leUint" ((PVar "n")) (EApp (EVar "ByteParserE") (EApp (EApp (EApp (EVar "leUintGo") (EVar "n")) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "leUintGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int")))))))))
(DFunDef false "leUintGo" ((PVar "n") (PVar "shift") (PVar "acc") (PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "b") (EApp (EVar "U8.toInt") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "shift") (ELit (LInt 56))) (EBinOp "&&" (EBinOp "==" (EVar "shift") (ELit (LInt 56))) (EBinOp "<" (EVar "b") (ELit (LInt 64))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "leUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "shift") (ELit (LInt 8)))) (EBinOp "+" (EVar "acc") (EBinOp "*" (EVar "b") (EApp (EVar "pow2") (EVar "shift"))))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EIf (EBinOp "==" (EVar "b") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "leUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "shift") (ELit (LInt 8)))) (EVar "acc")) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EApp (EApp (EVar "BErr") (EVar "intRangeMessage")) (EVar "pos")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "leSint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "leSint" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EMethodRef "deferPure") (ELit (LInt 0))) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 8))) (EApp (EApp (EMethodRef "deferThen") (EVar "leU64")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "takeBytes") (EBinOp "-" (EVar "n") (ELit (LInt 8))))) (ELam ((PVar "fill")) (EApp (EApp (EVar "signedFrom64") (EVar "fill")) (EVar "x")))))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "leUint") (EVar "n"))) (ELam ((PVar "u")) (ELet false (PVar "threshold") (EApp (EVar "pow2") (EBinOp "-" (EBinOp "*" (ELit (LInt 8)) (EVar "n")) (ELit (LInt 1)))) (EApp (EMethodRef "deferPure") (EIf (EBinOp ">=" (EVar "u") (EVar "threshold")) (EBinOp "-" (EVar "u") (EBinOp "*" (EVar "threshold") (ELit (LInt 2)))) (EVar "u")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "leFloat64" (TyApp (TyCon "ByteParser") (TyCon "Float")))
(DFunDef false "leFloat64" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "takeBytes") (ELit (LInt 8)))) (ELam ((PVar "bytes")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "bytesToFloat64") (EApp (EVar "arrayReverse") (EApp (EVar "toArray") (EVar "bytes")))) (ELit (LInt 0)))))))
(DTypeSig true "beU16" (TyApp (TyCon "ByteParser") (TyCon "U16")))
(DFunDef false "beU16" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "beUint") (ELit (LInt 2)))) (ELam ((PVar "n")) (EApp (EMethodRef "deferPure") (EApp (EVar "U16.truncate") (EVar "n"))))))
(DTypeSig true "beU32" (TyApp (TyCon "ByteParser") (TyCon "U32")))
(DFunDef false "beU32" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "beUint") (ELit (LInt 4)))) (ELam ((PVar "n")) (EApp (EMethodRef "deferPure") (EApp (EVar "U32.truncate") (EVar "n"))))))
(DTypeSig true "beU64" (TyApp (TyCon "ByteParser") (TyCon "U64")))
(DFunDef false "beU64" () (EApp (EVar "ByteParserE") (EApp (EApp (EVar "beU64Go") (ELit (LInt 8))) (ELit (LInt 0)))))
(DTypeSig false "beU64Go" (TyFun (TyCon "Int") (TyFun (TyCon "U64") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "U64"))))))))
(DFunDef false "beU64Go" ((PVar "n") (PVar "acc") (PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "beU64Go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 256))) (EApp (EVar "U64.fromU8") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "leU16" (TyApp (TyCon "ByteParser") (TyCon "U16")))
(DFunDef false "leU16" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "leUint") (ELit (LInt 2)))) (ELam ((PVar "n")) (EApp (EMethodRef "deferPure") (EApp (EVar "U16.truncate") (EVar "n"))))))
(DTypeSig true "leU32" (TyApp (TyCon "ByteParser") (TyCon "U32")))
(DFunDef false "leU32" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "leUint") (ELit (LInt 4)))) (ELam ((PVar "n")) (EApp (EMethodRef "deferPure") (EApp (EVar "U32.truncate") (EVar "n"))))))
(DTypeSig true "leU64" (TyApp (TyCon "ByteParser") (TyCon "U64")))
(DFunDef false "leU64" () (EApp (EVar "ByteParserE") (EApp (EApp (EApp (EVar "leU64Go") (ELit (LInt 8))) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "leU64Go" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "U64") (TyFun (TyCon "Bytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "U64")))))))))
(DFunDef false "leU64Go" ((PVar "n") (PVar "shift") (PVar "acc") (PVar "input") (PVar "pos") (PVar "end")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EVar "end")) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "b") (EApp (EVar "U64.fromU8") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "leU64Go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "shift") (ELit (LInt 8)))) (EApp (EApp (EVar "U64.bitOr") (EVar "acc")) (EApp (EApp (EVar "U64.shiftLeft") (EVar "b")) (EVar "shift")))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "end")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "runByteParser" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))
(DFunDef false "runByteParser" ((PVar "p") (PVar "bytes")) (EMatch (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "bytes")) (ELit (LInt 0))) (EApp (EVar "bytesLength") (EVar "bytes"))) (arm (PCon "BOk" (PVar "a") PWild) () (EApp (EVar "Ok") (EVar "a"))) (arm (PCon "BErr" (PVar "m") (PVar "pos")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString " at byte "))) (EApp (EMethodRef "display") (EVar "pos"))) (ELit (LString "")))))))
(DTypeSig true "runByteParserWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyCon "Bytes") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))))
(DFunDef false "runByteParserWithin" ((PVar "start") (PVar "end") (PVar "p") (PVar "bytes")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "start") (ELit (LInt 0))) (EBinOp "<" (EVar "end") (EVar "start"))) (EBinOp ">" (EVar "end") (EApp (EVar "bytesLength") (EVar "bytes")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "invalid range [")) (EApp (EMethodRef "display") (EVar "start"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EVar "end"))) (ELit (LString ") for input of length "))) (EApp (EMethodRef "display") (EApp (EVar "bytesLength") (EVar "bytes")))) (ELit (LString "")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "bytes")) (EVar "start")) (EVar "end")) (arm (PCon "BOk" (PVar "a") PWild) () (EApp (EVar "Ok") (EVar "a"))) (arm (PCon "BErr" (PVar "m") (PVar "pos")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString " at byte "))) (EApp (EMethodRef "display") (EVar "pos"))) (ELit (LString "")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
