# META
source_lines=434
stages=DESUGAR,MARK
# SOURCE
{- | Parser combinators over byte arrays.

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
   signed one. `bytebuilder`'s emit functions write the same encodings. -}

import array.{reverse as arrayReverse}
import bytes.{Bytes, fromArray, toArray}
import list.{reverse}
import u8 as U8

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
{- | A parser indexed by the effect row `e` its steps may perform.

   The wrapped function takes the input and a start position and returns a
   `BResult`. `ByteParser` fixes `e` to the empty row, and every parser in
   this module has that type. -}
public export data ByteParserE (e : Effect) a =
  | ByteParserE (Array Int -> Int -> <e> BResult a)

-- | A parser whose steps perform no effects. Every parser this module
-- exports has this type.
export type ByteParser a = ByteParserE <> a

{- | Runs `p` on `input` from position `pos` and returns the raw `BResult`.

   `runByteParser` is the form that starts at `0` and returns a `Result`. -}
export
runBP : ByteParserE e a -> Array Int -> Int -> <e> BResult a
runBP (ByteParserE f) input pos = f input pos

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
  deferMap g p =
    ByteParserE (input pos => onOk (runBP p input pos) (a p2 => BOk (g a) p2))

export impl DeferredApplicative ByteParserE where
  deferPure a = ByteParserE (_ pos => BOk a pos)
  deferAp pf pa = ByteParserE (input pos => onOk (runBP
    pf
    input
    pos) (f p2 => onOk (runBP pa input p2) (a p3 => BOk (f a) p3)))

export impl DeferredThenable ByteParserE where
  deferThen p k = ByteParserE (input pos => onOk (runBP p input pos) (a p2 =>
    runBP (k a) input p2))

-- # Alternatives

-- `noMatch` and `orElse` are plain functions rather than an `Alternative`
-- impl: that interface `requires Applicative f` at kind `Type -> Type`, which
-- `ByteParserE : Effect -> Type -> Type` cannot satisfy.

-- | A parser that always fails, consuming nothing.
export
noMatch : ByteParserE e a
noMatch = ByteParserE (_ pos => BErr "noMatch" pos)

{- | Tries `p`, and when it fails, runs `q` from the same starting position.

   > runByteParser (orElse (byte 1) (byte 2)) (arrayFromList [2])
   Ok 2 -}
export
orElse : ByteParserE e a -> ByteParserE e a -> ByteParserE e a
orElse p q = ByteParserE (input pos => match runBP p input pos
  BOk a pos2 => BOk a pos2
  BErr _ _ => runBP q input pos)

-- # Primitives

-- | A parser that always fails with `msg`, consuming nothing.
export
failWith : String -> ByteParser a
failWith msg = ByteParserE (_ pos => BErr msg pos)

{- | One byte that satisfies `pred`.

   Fails without consuming anything when the element at the position is
   outside `0` to `255`, whatever `pred` would say.

   > runByteParser (satisfy (b => b == 65)) (arrayFromList [65, 66, 67])
   Ok 65
   > runByteParser (satisfy (b => b == 65)) (arrayFromList [99])
   Err "unexpected byte at byte 0"
   > runByteParser (satisfy (_ => True)) (arrayFromList [300])
   Err "not a byte at byte 0" -}
export
satisfy : (U8 -> Bool) -> ByteParser U8
satisfy pred = ByteParserE (satisfyStep pred)

satisfyStep : (U8 -> Bool) -> Array Int -> Int -> BResult U8
satisfyStep pred input pos
  | pos >= arrayLength input = BErr "unexpected end of input" pos
  | otherwise = match U8.tryFromInt input[pos]
    None => BErr "not a byte" pos
    Some b => if pred b then BOk b (pos + 1) else BErr "unexpected byte" pos

{- | Any one byte.

   > runByteParser anyByte (arrayFromList [42])
   Ok 42 -}
export
anyByte : ByteParser U8
anyByte = satisfy (_ => True)

{- | Exactly the byte `b`.

   > runByteParser (byte 0xFF) (arrayFromList [255, 0])
   Ok 255
   > runByteParser (byte 0x00) (arrayFromList [1])
   Err "unexpected byte at byte 0" -}
export
byte : U8 -> ByteParser U8
byte b = satisfy (== b)

{- | Succeeds at the end of the input, consuming nothing.

   > runByteParser eof (arrayFromList [])
   Ok ()
   > runByteParser eof (arrayFromList [1])
   Err "expected end of input at byte 0" -}
export
eof : ByteParser Unit
eof = ByteParserE eofStep

eofStep : Array Int -> Int -> BResult Unit
eofStep input pos
  | pos >= arrayLength input = BOk () pos
  | otherwise = BErr "expected end of input" pos

-- | The byte at the current position, without consuming it. Fails at the
-- end of the input, and on an element outside `0` to `255`.
export
peek : ByteParser U8
peek = ByteParserE (input pos =>
  if pos >= arrayLength input then
    BErr "unexpected end of input" pos
  else match U8.tryFromInt input[pos]
    None => BErr "not a byte" pos
    Some b => BOk b pos)

-- # Combinators

{- | Zero or more `p`, until it fails.

   Also stops when `p` succeeds without consuming anything, so `many` of
   such a parser terminates.

   > runByteParser (many (byte 1)) (arrayFromList [1, 1, 1, 2])
   Ok [1, 1, 1] -}
export
many : ByteParser a -> ByteParser (List a)
many p = ByteParserE (input pos => manyGo p input pos [])

manyGo : ByteParser a -> Array Int -> Int -> List a -> BResult (List a)
manyGo p input pos acc = match runBP p input pos
  BErr _ _ => BOk (reverse acc) pos
  BOk a pos2 =>
    if pos2 == pos then
      BOk (reverse acc) pos2  -- no progress: stop to avoid infinite loop
    else
      manyGo p input pos2 (a :: acc)

{- | One or more `p`.

   > runByteParser (some (byte 2)) (arrayFromList [2, 2, 3])
   Ok [2, 2]
   > runByteParser (some (byte 2)) (arrayFromList [3])
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

   > runByteParser (optional (byte 5)) (arrayFromList [5])
   Ok Some 5
   > runByteParser (optional (byte 5)) (arrayFromList [9])
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

   Fails when fewer than `n` bytes remain.

   > runByteParser (takeBytes 3) (arrayFromList [10, 20, 30, 40])
   Ok Bytes "0a141e" -}
export
takeBytes : Int -> ByteParser Bytes
takeBytes n =
  deferMap
    (xs =>
      optionOrPanic
        "takeBytes: every element must be a byte in 0..255"
        (fromArray (arrayFromList xs)))
    (ByteParserE (takeBytesGo n []))

takeBytesGo : Int -> List Int -> Array Int -> Int -> BResult (List Int)
takeBytesGo n acc input pos
  | n <= 0 = BOk (reverse acc) pos
  | pos >= arrayLength input = BErr "unexpected end of input" pos
  | otherwise = takeBytesGo (n - 1) (input[pos] :: acc) input (pos + 1)

-- | Exactly `n` bytes, as an `Array Int`.
export
takeSlice : Int -> ByteParser (Array Int)
takeSlice n = deferMap toArray (takeBytes n)

-- # Integers and floats

{- | An unsigned integer of `n` bytes, most significant byte first.

   Fails when fewer than `n` bytes remain.

   > runByteParser (beUint 2) (arrayFromList [1, 2])
   Ok 258
   > runByteParser (beUint 1) (arrayFromList [255])
   Ok 255
   > runByteParser (beUint 4) (arrayFromList [0, 0, 1, 0])
   Ok 256 -}
export
beUint : Int -> ByteParser Int
beUint n = ByteParserE (beUintGo n 0)

beUintGo : Int -> Int -> Array Int -> Int -> BResult Int
beUintGo n acc input pos
  | n <= 0 = BOk acc pos
  | pos >= arrayLength input = BErr "unexpected end of input" pos
  | otherwise = beUintGo (n - 1) (acc * 256 + input[pos]) input (pos + 1)

{- | A signed two's-complement integer of `n` bytes, most significant byte
   first.

   > runByteParser (beSint 1) (arrayFromList [255])
   Ok -1
   > runByteParser (beSint 1) (arrayFromList [127])
   Ok 127
   > runByteParser (beSint 2) (arrayFromList [255, 255])
   Ok -1
   > runByteParser (beSint 2) (arrayFromList [0, 1])
   Ok 1 -}
export
beSint : Int -> ByteParser Int
beSint n = defer
  u <- beUint n
  let threshold = pow2 (8 * n - 1)
  deferPure (if u >= threshold then u - threshold * 2 else u)

-- 2^n by left shift; valid for n in 0..62 on a 63-bit Int.
pow2 : Int -> Int
pow2 n = shiftLeft 1 n

{- | A 64-bit IEEE 754 float from eight bytes, most significant byte first.

   > runByteParser beFloat64 (arrayFromList [63, 248, 0, 0, 0, 0, 0, 0])
   Ok 1.5
   > runByteParser beFloat64 (arrayFromList [192, 0, 0, 0, 0, 0, 0, 0])
   Ok -2.0 -}
export
beFloat64 : ByteParser Float
beFloat64 = defer
  arr <- takeSlice 8
  deferPure (bytesToFloat64 arr 0)

{- | An unsigned integer of `n` bytes, least significant byte first.

   Fails when fewer than `n` bytes remain.

   > runByteParser (leUint 2) (arrayFromList [2, 1])
   Ok 258
   > runByteParser (leUint 1) (arrayFromList [255])
   Ok 255
   > runByteParser (leUint 4) (arrayFromList [0, 1, 0, 0])
   Ok 256 -}
export
leUint : Int -> ByteParser Int
leUint n = ByteParserE (leUintGo n 0 0)

leUintGo : Int -> Int -> Int -> Array Int -> Int -> BResult Int
leUintGo n shift acc input pos
  | n <= 0 = BOk acc pos
  | pos >= arrayLength input = BErr "unexpected end of input" pos
  | otherwise =
    leUintGo (n - 1) (shift + 8) (acc + input[pos] * pow2 shift) input (pos + 1)

{- | A signed two's-complement integer of `n` bytes, least significant byte
   first.

   > runByteParser (leSint 1) (arrayFromList [255])
   Ok -1
   > runByteParser (leSint 1) (arrayFromList [127])
   Ok 127
   > runByteParser (leSint 2) (arrayFromList [255, 255])
   Ok -1
   > runByteParser (leSint 2) (arrayFromList [1, 0])
   Ok 1 -}
export
leSint : Int -> ByteParser Int
leSint n = defer
  u <- leUint n
  let threshold = pow2 (8 * n - 1)
  deferPure (if u >= threshold then u - threshold * 2 else u)

{- | A 64-bit IEEE 754 float from eight bytes, least significant byte first.

   > runByteParser leFloat64 (arrayFromList [0, 0, 0, 0, 0, 0, 248, 63])
   Ok 1.5
   > runByteParser leFloat64 (arrayFromList [0, 0, 0, 0, 0, 0, 0, 192])
   Ok -2.0 -}
export
leFloat64 : ByteParser Float
leFloat64 = defer
  bytes <- takeBytes 8
  deferPure (bytesToFloat64 (arrayReverse (toArray bytes)) 0)

-- # Running a parser

{- | The result of running `p` on `bytes` from position `0`.

   `Err` carries the failure message and the byte position where it
   happened. Bytes left over after `p` succeeds are not an error; sequence
   `p` with `eof` to require that the whole input is consumed.

   > runByteParser (byte 42) (arrayFromList [42])
   Ok 42
   > runByteParser (byte 42) (arrayFromList [7])
   Err "unexpected byte at byte 0" -}
export
runByteParser : ByteParser a -> Array Int -> Result String a
runByteParser p bytes = match runBP p bytes 0
  BOk a _ => Ok a
  BErr m pos => Err "\{m} at byte \{pos}"
# DESUGAR
(DUse false (UseGroup ("array") ((mem "reverse" false "arrayReverse"))))
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "fromArray" false) (mem "toArray" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseAlias ("u8") "U8"))
(DData Public "BResult" ("a") ((variant "BOk" (ConPos (TyVar "a") (TyCon "Int"))) (variant "BErr" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DData Public "ByteParserE" ("e" "a") ((variant "ByteParserE" (ConPos (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "a")))))))) ())
(DTypeAlias true "ByteParser" ("a") (TyApp (TyApp (TyCon "ByteParserE") (TyRow () None)) (TyVar "a")))
(DTypeSig true "runBP" (TyFun (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "a")))))))
(DFunDef false "runBP" ((PCon "ByteParserE" (PVar "f")) (PVar "input") (PVar "pos")) (EApp (EApp (EVar "f") (EVar "input")) (EVar "pos")))
(DImpl true "Mappable" ((TyCon "BResult")) () ((im "map" ((PVar "f") (PCon "BOk" (PVar "a") (PVar "p"))) (EApp (EApp (EVar "BOk") (EApp (EVar "f") (EVar "a"))) (EVar "p"))) (im "map" (PWild (PCon "BErr" (PVar "m") (PVar "p"))) (EApp (EApp (EVar "BErr") (EVar "m")) (EVar "p")))))
(DTypeSig true "onOk" (TyFun (TyApp (TyCon "BResult") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "b"))))) (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "b"))))))
(DFunDef false "onOk" ((PCon "BErr" (PVar "m") (PVar "ep")) PWild) (EApp (EApp (EVar "BErr") (EVar "m")) (EVar "ep")))
(DFunDef false "onOk" ((PCon "BOk" (PVar "a") (PVar "pos")) (PVar "k")) (EApp (EApp (EVar "k") (EVar "a")) (EVar "pos")))
(DImpl true "DeferredMappable" ((TyCon "ByteParserE")) () ((im "deferMap" ((PVar "g") (PVar "p")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos"))) (ELam ((PVar "a") (PVar "p2")) (EApp (EApp (EVar "BOk") (EApp (EVar "g") (EVar "a"))) (EVar "p2")))))))))
(DImpl true "DeferredApplicative" ((TyCon "ByteParserE")) () ((im "deferPure" ((PVar "a")) (EApp (EVar "ByteParserE") (ELam (PWild (PVar "pos")) (EApp (EApp (EVar "BOk") (EVar "a")) (EVar "pos"))))) (im "deferAp" ((PVar "pf") (PVar "pa")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "pf")) (EVar "input")) (EVar "pos"))) (ELam ((PVar "f") (PVar "p2")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "pa")) (EVar "input")) (EVar "p2"))) (ELam ((PVar "a") (PVar "p3")) (EApp (EApp (EVar "BOk") (EApp (EVar "f") (EVar "a"))) (EVar "p3")))))))))))
(DImpl true "DeferredThenable" ((TyCon "ByteParserE")) () ((im "deferThen" ((PVar "p") (PVar "k")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos"))) (ELam ((PVar "a") (PVar "p2")) (EApp (EApp (EApp (EVar "runBP") (EApp (EVar "k") (EVar "a"))) (EVar "input")) (EVar "p2")))))))))
(DTypeSig true "noMatch" (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")))
(DFunDef false "noMatch" () (EApp (EVar "ByteParserE") (ELam (PWild (PVar "pos")) (EApp (EApp (EVar "BErr") (ELit (LString "noMatch"))) (EVar "pos")))))
(DTypeSig true "orElse" (TyFun (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")))))
(DFunDef false "orElse" ((PVar "p") (PVar "q")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (arm (PCon "BOk" (PVar "a") (PVar "pos2")) () (EApp (EApp (EVar "BOk") (EVar "a")) (EVar "pos2"))) (arm (PCon "BErr" PWild PWild) () (EApp (EApp (EApp (EVar "runBP") (EVar "q")) (EVar "input")) (EVar "pos")))))))
(DTypeSig true "failWith" (TyFun (TyCon "String") (TyApp (TyCon "ByteParser") (TyVar "a"))))
(DFunDef false "failWith" ((PVar "msg")) (EApp (EVar "ByteParserE") (ELam (PWild (PVar "pos")) (EApp (EApp (EVar "BErr") (EVar "msg")) (EVar "pos")))))
(DTypeSig true "satisfy" (TyFun (TyFun (TyCon "U8") (TyCon "Bool")) (TyApp (TyCon "ByteParser") (TyCon "U8"))))
(DFunDef false "satisfy" ((PVar "pred")) (EApp (EVar "ByteParserE") (EApp (EVar "satisfyStep") (EVar "pred"))))
(DTypeSig false "satisfyStep" (TyFun (TyFun (TyCon "U8") (TyCon "Bool")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "U8"))))))
(DFunDef false "satisfyStep" ((PVar "pred") (PVar "input") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "U8.tryFromInt") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (arm (PCon "None") () (EApp (EApp (EVar "BErr") (ELit (LString "not a byte"))) (EVar "pos"))) (arm (PCon "Some" (PVar "b")) () (EIf (EApp (EVar "pred") (EVar "b")) (EApp (EApp (EVar "BOk") (EVar "b")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected byte"))) (EVar "pos"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "anyByte" (TyApp (TyCon "ByteParser") (TyCon "U8")))
(DFunDef false "anyByte" () (EApp (EVar "satisfy") (ELam (PWild) (EVar "True"))))
(DTypeSig true "byte" (TyFun (TyCon "U8") (TyApp (TyCon "ByteParser") (TyCon "U8"))))
(DFunDef false "byte" ((PVar "b")) (EApp (EVar "satisfy") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "b")))))
(DTypeSig true "eof" (TyApp (TyCon "ByteParser") (TyCon "Unit")))
(DFunDef false "eof" () (EApp (EVar "ByteParserE") (EVar "eofStep")))
(DTypeSig false "eofStep" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Unit")))))
(DFunDef false "eofStep" ((PVar "input") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BOk") (ELit LUnit)) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EVar "BErr") (ELit (LString "expected end of input"))) (EVar "pos")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "peek" (TyApp (TyCon "ByteParser") (TyCon "U8")))
(DFunDef false "peek" () (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EMatch (EApp (EVar "U8.tryFromInt") (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos"))) (arm (PCon "None") () (EApp (EApp (EVar "BErr") (ELit (LString "not a byte"))) (EVar "pos"))) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "BOk") (EVar "b")) (EVar "pos"))))))))
(DTypeSig true "many" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "many" ((PVar "p")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "input")) (EVar "pos")) (EListLit)))))
(DTypeSig false "manyGo" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "BResult") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "manyGo" ((PVar "p") (PVar "input") (PVar "pos") (PVar "acc")) (EMatch (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (arm (PCon "BErr" PWild PWild) () (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos"))) (arm (PCon "BOk" (PVar "a") (PVar "pos2")) () (EIf (EBinOp "==" (EVar "pos2") (EVar "pos")) (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos2")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "input")) (EVar "pos2")) (EBinOp "::" (EVar "a") (EVar "acc")))))))
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
(DFunDef false "takeBytes" ((PVar "n")) (EApp (EApp (EVar "deferMap") (ELam ((PVar "xs")) (EApp (EApp (EVar "optionOrPanic") (ELit (LString "takeBytes: every element must be a byte in 0..255"))) (EApp (EVar "fromArray") (EApp (EVar "arrayFromList") (EVar "xs")))))) (EApp (EVar "ByteParserE") (EApp (EApp (EVar "takeBytesGo") (EVar "n")) (EListLit)))))
(DTypeSig false "takeBytesGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "takeBytesGo" ((PVar "n") (PVar "acc") (PVar "input") (PVar "pos")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "takeBytesGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (EVar "acc"))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "takeSlice" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "takeSlice" ((PVar "n")) (EApp (EApp (EVar "deferMap") (EVar "toArray")) (EApp (EVar "takeBytes") (EVar "n"))))
(DTypeSig true "beUint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "beUint" ((PVar "n")) (EApp (EVar "ByteParserE") (EApp (EApp (EVar "beUintGo") (EVar "n")) (ELit (LInt 0)))))
(DTypeSig false "beUintGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int")))))))
(DFunDef false "beUintGo" ((PVar "n") (PVar "acc") (PVar "input") (PVar "pos")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "beUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 256))) (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "beSint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "beSint" ((PVar "n")) (EApp (EApp (EVar "deferThen") (EApp (EVar "beUint") (EVar "n"))) (ELam ((PVar "u")) (ELet false (PVar "threshold") (EApp (EVar "pow2") (EBinOp "-" (EBinOp "*" (ELit (LInt 8)) (EVar "n")) (ELit (LInt 1)))) (EApp (EVar "deferPure") (EIf (EBinOp ">=" (EVar "u") (EVar "threshold")) (EBinOp "-" (EVar "u") (EBinOp "*" (EVar "threshold") (ELit (LInt 2)))) (EVar "u")))))))
(DTypeSig false "pow2" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "pow2" ((PVar "n")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "n")))
(DTypeSig true "beFloat64" (TyApp (TyCon "ByteParser") (TyCon "Float")))
(DFunDef false "beFloat64" () (EApp (EApp (EVar "deferThen") (EApp (EVar "takeSlice") (ELit (LInt 8)))) (ELam ((PVar "arr")) (EApp (EVar "deferPure") (EApp (EApp (EVar "bytesToFloat64") (EVar "arr")) (ELit (LInt 0)))))))
(DTypeSig true "leUint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "leUint" ((PVar "n")) (EApp (EVar "ByteParserE") (EApp (EApp (EApp (EVar "leUintGo") (EVar "n")) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "leUintGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int"))))))))
(DFunDef false "leUintGo" ((PVar "n") (PVar "shift") (PVar "acc") (PVar "input") (PVar "pos")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "leUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "shift") (ELit (LInt 8)))) (EBinOp "+" (EVar "acc") (EBinOp "*" (EApp (EApp (EVar "index") (EVar "input")) (EVar "pos")) (EApp (EVar "pow2") (EVar "shift"))))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "leSint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "leSint" ((PVar "n")) (EApp (EApp (EVar "deferThen") (EApp (EVar "leUint") (EVar "n"))) (ELam ((PVar "u")) (ELet false (PVar "threshold") (EApp (EVar "pow2") (EBinOp "-" (EBinOp "*" (ELit (LInt 8)) (EVar "n")) (ELit (LInt 1)))) (EApp (EVar "deferPure") (EIf (EBinOp ">=" (EVar "u") (EVar "threshold")) (EBinOp "-" (EVar "u") (EBinOp "*" (EVar "threshold") (ELit (LInt 2)))) (EVar "u")))))))
(DTypeSig true "leFloat64" (TyApp (TyCon "ByteParser") (TyCon "Float")))
(DFunDef false "leFloat64" () (EApp (EApp (EVar "deferThen") (EApp (EVar "takeBytes") (ELit (LInt 8)))) (ELam ((PVar "bytes")) (EApp (EVar "deferPure") (EApp (EApp (EVar "bytesToFloat64") (EApp (EVar "arrayReverse") (EApp (EVar "toArray") (EVar "bytes")))) (ELit (LInt 0)))))))
(DTypeSig true "runByteParser" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))
(DFunDef false "runByteParser" ((PVar "p") (PVar "bytes")) (EMatch (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "bytes")) (ELit (LInt 0))) (arm (PCon "BOk" (PVar "a") PWild) () (EApp (EVar "Ok") (EVar "a"))) (arm (PCon "BErr" (PVar "m") (PVar "pos")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString " at byte "))) (EApp (EVar "display") (EVar "pos"))) (ELit (LString "")))))))
# MARK
(DUse false (UseGroup ("array") ((mem "reverse" false "arrayReverse"))))
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "fromArray" false) (mem "toArray" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseAlias ("u8") "U8"))
(DData Public "BResult" ("a") ((variant "BOk" (ConPos (TyVar "a") (TyCon "Int"))) (variant "BErr" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DData Public "ByteParserE" ("e" "a") ((variant "ByteParserE" (ConPos (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "a")))))))) ())
(DTypeAlias true "ByteParser" ("a") (TyApp (TyApp (TyCon "ByteParserE") (TyRow () None)) (TyVar "a")))
(DTypeSig true "runBP" (TyFun (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "a")))))))
(DFunDef false "runBP" ((PCon "ByteParserE" (PVar "f")) (PVar "input") (PVar "pos")) (EApp (EApp (EVar "f") (EVar "input")) (EVar "pos")))
(DImpl true "Mappable" ((TyCon "BResult")) () ((im "map" ((PVar "f") (PCon "BOk" (PVar "a") (PVar "p"))) (EApp (EApp (EVar "BOk") (EApp (EVar "f") (EVar "a"))) (EVar "p"))) (im "map" (PWild (PCon "BErr" (PVar "m") (PVar "p"))) (EApp (EApp (EVar "BErr") (EVar "m")) (EVar "p")))))
(DTypeSig true "onOk" (TyFun (TyApp (TyCon "BResult") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "b"))))) (TyEffect () (Some "e") (TyApp (TyCon "BResult") (TyVar "b"))))))
(DFunDef false "onOk" ((PCon "BErr" (PVar "m") (PVar "ep")) PWild) (EApp (EApp (EVar "BErr") (EVar "m")) (EVar "ep")))
(DFunDef false "onOk" ((PCon "BOk" (PVar "a") (PVar "pos")) (PVar "k")) (EApp (EApp (EVar "k") (EVar "a")) (EVar "pos")))
(DImpl true "DeferredMappable" ((TyCon "ByteParserE")) () ((im "deferMap" ((PVar "g") (PVar "p")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos"))) (ELam ((PVar "a") (PVar "p2")) (EApp (EApp (EVar "BOk") (EApp (EVar "g") (EVar "a"))) (EVar "p2")))))))))
(DImpl true "DeferredApplicative" ((TyCon "ByteParserE")) () ((im "deferPure" ((PVar "a")) (EApp (EVar "ByteParserE") (ELam (PWild (PVar "pos")) (EApp (EApp (EVar "BOk") (EVar "a")) (EVar "pos"))))) (im "deferAp" ((PVar "pf") (PVar "pa")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "pf")) (EVar "input")) (EVar "pos"))) (ELam ((PVar "f") (PVar "p2")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "pa")) (EVar "input")) (EVar "p2"))) (ELam ((PVar "a") (PVar "p3")) (EApp (EApp (EVar "BOk") (EApp (EVar "f") (EVar "a"))) (EVar "p3")))))))))))
(DImpl true "DeferredThenable" ((TyCon "ByteParserE")) () ((im "deferThen" ((PVar "p") (PVar "k")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EVar "onOk") (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos"))) (ELam ((PVar "a") (PVar "p2")) (EApp (EApp (EApp (EVar "runBP") (EApp (EVar "k") (EVar "a"))) (EVar "input")) (EVar "p2")))))))))
(DTypeSig true "noMatch#shadow" (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")))
(DFunDef false "noMatch#shadow" () (EApp (EVar "ByteParserE") (ELam (PWild (PVar "pos")) (EApp (EApp (EVar "BErr") (ELit (LString "noMatch"))) (EVar "pos")))))
(DTypeSig true "orElse#shadow" (TyFun (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")) (TyFun (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "ByteParserE") (TyVar "e")) (TyVar "a")))))
(DFunDef false "orElse#shadow" ((PVar "p") (PVar "q")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (arm (PCon "BOk" (PVar "a") (PVar "pos2")) () (EApp (EApp (EVar "BOk") (EVar "a")) (EVar "pos2"))) (arm (PCon "BErr" PWild PWild) () (EApp (EApp (EApp (EVar "runBP") (EVar "q")) (EVar "input")) (EVar "pos")))))))
(DTypeSig true "failWith" (TyFun (TyCon "String") (TyApp (TyCon "ByteParser") (TyVar "a"))))
(DFunDef false "failWith" ((PVar "msg")) (EApp (EVar "ByteParserE") (ELam (PWild (PVar "pos")) (EApp (EApp (EVar "BErr") (EVar "msg")) (EVar "pos")))))
(DTypeSig true "satisfy" (TyFun (TyFun (TyCon "U8") (TyCon "Bool")) (TyApp (TyCon "ByteParser") (TyCon "U8"))))
(DFunDef false "satisfy" ((PVar "pred")) (EApp (EVar "ByteParserE") (EApp (EVar "satisfyStep") (EVar "pred"))))
(DTypeSig false "satisfyStep" (TyFun (TyFun (TyCon "U8") (TyCon "Bool")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "U8"))))))
(DFunDef false "satisfyStep" ((PVar "pred") (PVar "input") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "U8.tryFromInt") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (arm (PCon "None") () (EApp (EApp (EVar "BErr") (ELit (LString "not a byte"))) (EVar "pos"))) (arm (PCon "Some" (PVar "b")) () (EIf (EApp (EVar "pred") (EVar "b")) (EApp (EApp (EVar "BOk") (EVar "b")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected byte"))) (EVar "pos"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "anyByte" (TyApp (TyCon "ByteParser") (TyCon "U8")))
(DFunDef false "anyByte" () (EApp (EVar "satisfy") (ELam (PWild) (EVar "True"))))
(DTypeSig true "byte" (TyFun (TyCon "U8") (TyApp (TyCon "ByteParser") (TyCon "U8"))))
(DFunDef false "byte" ((PVar "b")) (EApp (EVar "satisfy") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "b")))))
(DTypeSig true "eof" (TyApp (TyCon "ByteParser") (TyCon "Unit")))
(DFunDef false "eof" () (EApp (EVar "ByteParserE") (EVar "eofStep")))
(DTypeSig false "eofStep" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Unit")))))
(DFunDef false "eofStep" ((PVar "input") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BOk") (ELit LUnit)) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EVar "BErr") (ELit (LString "expected end of input"))) (EVar "pos")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "peek" (TyApp (TyCon "ByteParser") (TyCon "U8")))
(DFunDef false "peek" () (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EMatch (EApp (EVar "U8.tryFromInt") (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos"))) (arm (PCon "None") () (EApp (EApp (EVar "BErr") (ELit (LString "not a byte"))) (EVar "pos"))) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "BOk") (EVar "b")) (EVar "pos"))))))))
(DTypeSig true "many" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyApp (TyCon "ByteParser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "many" ((PVar "p")) (EApp (EVar "ByteParserE") (ELam ((PVar "input") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "input")) (EVar "pos")) (EListLit)))))
(DTypeSig false "manyGo" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "BResult") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "manyGo" ((PVar "p") (PVar "input") (PVar "pos") (PVar "acc")) (EMatch (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "input")) (EVar "pos")) (arm (PCon "BErr" PWild PWild) () (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos"))) (arm (PCon "BOk" (PVar "a") (PVar "pos2")) () (EIf (EBinOp "==" (EVar "pos2") (EVar "pos")) (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos2")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "input")) (EVar "pos2")) (EBinOp "::" (EVar "a") (EVar "acc")))))))
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
(DFunDef false "takeBytes" ((PVar "n")) (EApp (EApp (EMethodRef "deferMap") (ELam ((PVar "xs")) (EApp (EApp (EVar "optionOrPanic") (ELit (LString "takeBytes: every element must be a byte in 0..255"))) (EApp (EVar "fromArray") (EApp (EVar "arrayFromList") (EVar "xs")))))) (EApp (EVar "ByteParserE") (EApp (EApp (EVar "takeBytesGo") (EVar "n")) (EListLit)))))
(DTypeSig false "takeBytesGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "takeBytesGo" ((PVar "n") (PVar "acc") (PVar "input") (PVar "pos")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EApp (EVar "reverse") (EVar "acc"))) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "takeBytesGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (EVar "acc"))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "takeSlice" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "takeSlice" ((PVar "n")) (EApp (EApp (EMethodRef "deferMap") (EVar "toArray")) (EApp (EVar "takeBytes") (EVar "n"))))
(DTypeSig true "beUint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "beUint" ((PVar "n")) (EApp (EVar "ByteParserE") (EApp (EApp (EVar "beUintGo") (EVar "n")) (ELit (LInt 0)))))
(DTypeSig false "beUintGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int")))))))
(DFunDef false "beUintGo" ((PVar "n") (PVar "acc") (PVar "input") (PVar "pos")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "beUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 256))) (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "beSint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "beSint" ((PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "beUint") (EVar "n"))) (ELam ((PVar "u")) (ELet false (PVar "threshold") (EApp (EVar "pow2") (EBinOp "-" (EBinOp "*" (ELit (LInt 8)) (EVar "n")) (ELit (LInt 1)))) (EApp (EMethodRef "deferPure") (EIf (EBinOp ">=" (EVar "u") (EVar "threshold")) (EBinOp "-" (EVar "u") (EBinOp "*" (EVar "threshold") (ELit (LInt 2)))) (EVar "u")))))))
(DTypeSig false "pow2" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "pow2" ((PVar "n")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "n")))
(DTypeSig true "beFloat64" (TyApp (TyCon "ByteParser") (TyCon "Float")))
(DFunDef false "beFloat64" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "takeSlice") (ELit (LInt 8)))) (ELam ((PVar "arr")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "bytesToFloat64") (EVar "arr")) (ELit (LInt 0)))))))
(DTypeSig true "leUint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "leUint" ((PVar "n")) (EApp (EVar "ByteParserE") (EApp (EApp (EApp (EVar "leUintGo") (EVar "n")) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "leUintGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "BResult") (TyCon "Int"))))))))
(DFunDef false "leUintGo" ((PVar "n") (PVar "shift") (PVar "acc") (PVar "input") (PVar "pos")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EVar "BOk") (EVar "acc")) (EVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "input"))) (EApp (EApp (EVar "BErr") (ELit (LString "unexpected end of input"))) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "leUintGo") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "shift") (ELit (LInt 8)))) (EBinOp "+" (EVar "acc") (EBinOp "*" (EApp (EApp (EMethodRef "index") (EVar "input")) (EVar "pos")) (EApp (EVar "pow2") (EVar "shift"))))) (EVar "input")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "leSint" (TyFun (TyCon "Int") (TyApp (TyCon "ByteParser") (TyCon "Int"))))
(DFunDef false "leSint" ((PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "leUint") (EVar "n"))) (ELam ((PVar "u")) (ELet false (PVar "threshold") (EApp (EVar "pow2") (EBinOp "-" (EBinOp "*" (ELit (LInt 8)) (EVar "n")) (ELit (LInt 1)))) (EApp (EMethodRef "deferPure") (EIf (EBinOp ">=" (EVar "u") (EVar "threshold")) (EBinOp "-" (EVar "u") (EBinOp "*" (EVar "threshold") (ELit (LInt 2)))) (EVar "u")))))))
(DTypeSig true "leFloat64" (TyApp (TyCon "ByteParser") (TyCon "Float")))
(DFunDef false "leFloat64" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "takeBytes") (ELit (LInt 8)))) (ELam ((PVar "bytes")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "bytesToFloat64") (EApp (EVar "arrayReverse") (EApp (EVar "toArray") (EVar "bytes")))) (ELit (LInt 0)))))))
(DTypeSig true "runByteParser" (TyFun (TyApp (TyCon "ByteParser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")))))
(DFunDef false "runByteParser" ((PVar "p") (PVar "bytes")) (EMatch (EApp (EApp (EApp (EVar "runBP") (EVar "p")) (EVar "bytes")) (ELit (LInt 0))) (arm (PCon "BOk" (PVar "a") PWild) () (EApp (EVar "Ok") (EVar "a"))) (arm (PCon "BErr" (PVar "m") (PVar "pos")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString " at byte "))) (EApp (EMethodRef "display") (EVar "pos"))) (ELit (LString "")))))))
