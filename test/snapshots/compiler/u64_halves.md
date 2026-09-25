# META
source_lines=182
stages=DESUGAR,MARK
# SOURCE
-- The interpreter's `U64` arithmetic (`docs/design/INTEGER-TYPES-DESIGN.md` §6.2).
-- The interpreter is a Medaka program compiled with a 63-bit `Int`, so it carries a
-- `U64` as two `Int` halves, `(hi, lo)`, each in `0 .. 2^32 - 1`, and does every
-- operation here with no intermediate above 2^62.  A product of two 32-bit halves
-- can reach 2^64, so multiplication splits each half again into 16-bit pieces.
--
-- Every function is total and agrees bit for bit with the native 64-bit operations
-- the emitters lower to: wrap modulo 2^64, unsigned order, logical right shift, and
-- a shift of 64 or more (or a negative one) giving 0.  Division by zero is the
-- caller's to refuse; `divMod` assumes a nonzero divisor.

-- 2^32, one half's modulus.
half : Int
half = 4294967296

-- 2^16, the multiplication piece.
piece : Int
piece = 65536

-- `n` reduced into `0 .. 2^32 - 1`, for a value that may have gone negative or
-- past one half's range by a few multiples of 2^32.
wrapHalf : Int -> Int
wrapHalf n = (n % half + half) % half

-- 2^k, for `k` in `0 .. 32`.
pow2 : Int -> Int
pow2 k = shiftLeft 1 k

-- The low [k] bits of a half.
lowBits : Int -> Int -> Int
lowBits n k = n % pow2 k

-- An `Int` as a `U64`, modulo 2^64.  A negative `Int` is its two's-complement bit
-- pattern sign-extended to 64 bits, which is its value modulo 2^64.
export
fromInt : Int -> (Int, Int)
fromInt n =
  let lo = wrapHalf n
  (wrapHalf ((n - lo) / half), lo)

-- The low 63 bits, as an `Int`: bit 63 is dropped and bit 62 is the sign.
export
truncateToInt : (Int, Int) -> Int
truncateToInt (hi, lo) =
  let h = hi % 2147483648
  if h >= 1073741824 then (h - 2147483648) * half + lo else h * half + lo

export
add : (Int, Int) -> (Int, Int) -> (Int, Int)
add (ah, al) (bh, bl) =
  let lo = al + bl
  (wrapHalf (ah + bh + lo / half), lo % half)

export
sub : (Int, Int) -> (Int, Int) -> (Int, Int)
sub (ah, al) (bh, bl) =
  let lo = al - bl
  if lo < 0 then
    (wrapHalf (ah - bh - 1), lo + half)
  else
    (wrapHalf (ah - bh), lo)

-- The full 64-bit product of two halves, as `(hi, lo)`.
mulHalves : Int -> Int -> (Int, Int)
mulHalves x y =
  let x1 = x / piece
  let x0 = x % piece
  let y1 = y / piece
  let y0 = y % piece
  let mid = x1 * y0 + x0 * y1
  let low = x0 * y0 + mid % piece * piece
  (x1 * y1 + mid / piece + low / half, low % half)

-- The product modulo 2^64: `al*bl` in full, plus the low halves of the two cross
-- products shifted up one half (`ah*bh` lies wholly above bit 63).
export
mul : (Int, Int) -> (Int, Int) -> (Int, Int)
mul (ah, al) (bh, bl) =
  let (ph, pl) = mulHalves al bl
  let cross = snd (mulHalves ah bl) + snd (mulHalves al bh)
  (wrapHalf (ph + cross), pl)

-- The high 64 bits of the 128-bit product: the four half-products summed by
-- 32-bit column, `al*bl` in columns 0-1, the cross products in 1-2, `ah*bh` in 2-3.
export
mulHigh : (Int, Int) -> (Int, Int) -> (Int, Int)
mulHigh (ah, al) (bh, bl) =
  let (llh, _) = mulHalves al bl
  let (hlh, hll) = mulHalves ah bl
  let (lhh, lhl) = mulHalves al bh
  let (hhh, hhl) = mulHalves ah bh
  let col1 = llh + hll + lhl
  let col2 = hhl + hlh + lhh + col1 / half
  (wrapHalf (hhh + col2 / half), col2 % half)

export
compareU64 : (Int, Int) -> (Int, Int) -> Ordering
compareU64 (ah, al) (bh, bl) = match compare ah bh
  Eq => compare al bl
  o => o

export
isZero : (Int, Int) -> Bool
isZero (hi, lo) = hi == 0 && lo == 0

-- Unsigned quotient and remainder; the divisor is not zero.  When both operands
-- fit 62 bits this is `Int` division; otherwise restoring long division, one bit
-- at a time from the top.
export
divMod : (Int, Int) -> (Int, Int) -> ((Int, Int), (Int, Int))
divMod (ah, al) (bh, bl)
  | ah < 1073741824 && bh < 1073741824 =
    let a = ah * half + al
    let b = bh * half + bl
    (fromInt (a / b), fromInt (a % b))
  | otherwise = divModGo 63 (ah, al) (bh, bl) (0, 0) (0, 0)

divModGo : Int ->
  (Int, Int) ->
  (Int, Int) ->
  (Int, Int) ->
  (Int, Int) ->
  ((Int, Int), (Int, Int))
divModGo bit a b q r
  | bit < 0 = (q, r)
  | otherwise =
    let r1 = bitOrU64 (shiftLeft64 r 1) (0, bitAt a bit)
    if compareU64 r1 b == Lt then
      divModGo (bit - 1) a b q r1
    else
      divModGo (bit - 1) a b (bitOrU64 q (shiftLeft64 (0, 1) bit)) (sub r1 b)

bitAt : (Int, Int) -> Int -> Int
bitAt (hi, lo) k
  | k >= 32 = bitAnd (shiftRight hi (k - 32)) 1
  | otherwise = bitAnd (shiftRight lo k) 1

export
bitAndU64 : (Int, Int) -> (Int, Int) -> (Int, Int)
bitAndU64 (ah, al) (bh, bl) = (bitAnd ah bh, bitAnd al bl)

export
bitOrU64 : (Int, Int) -> (Int, Int) -> (Int, Int)
bitOrU64 (ah, al) (bh, bl) = (bitOr ah bh, bitOr al bl)

export
bitXorU64 : (Int, Int) -> (Int, Int) -> (Int, Int)
bitXorU64 (ah, al) (bh, bl) = (bitXor ah bh, bitXor al bl)

-- Each half is masked to the bits that stay inside 64 before it is moved up, so
-- no intermediate passes 2^32.
export
shiftLeft64 : (Int, Int) -> Int -> (Int, Int)
shiftLeft64 (hi, lo) k
  | k < 0 || k >= 64 = (0, 0)
  | k == 0 = (hi, lo)
  | k >= 32 = (lowBits lo (64 - k) * pow2 (k - 32), 0)
  | otherwise = (
    lowBits hi (32 - k) * pow2 k + shiftRight lo (32 - k),
    lowBits lo (32 - k) * pow2 k,
  )

export
shiftRight64 : (Int, Int) -> Int -> (Int, Int)
shiftRight64 (hi, lo) k
  | k < 0 || k >= 64 = (0, 0)
  | k == 0 = (hi, lo)
  | k >= 32 = (0, shiftRight hi (k - 32))
  | otherwise =
    (shiftRight hi k, shiftRight lo k + lowBits hi k * pow2 (32 - k))

-- Decimal, as the interpreter prints a `U64`.
export
toDecimal : (Int, Int) -> String
toDecimal (0, lo) = intToString lo
toDecimal v = toDecimalGo v ""

toDecimalGo : (Int, Int) -> String -> String
toDecimalGo (0, 0) acc = acc
toDecimalGo (hi, lo) acc =
  let t = hi % 10 * half + lo
  toDecimalGo (hi / 10, t / 10) (intToString (t % 10) ++ acc)
# DESUGAR
(DTypeSig false "half" (TyCon "Int"))
(DFunDef false "half" () (ELit (LInt 4294967296)))
(DTypeSig false "piece" (TyCon "Int"))
(DFunDef false "piece" () (ELit (LInt 65536)))
(DTypeSig false "wrapHalf" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "wrapHalf" ((PVar "n")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (EVar "half")) (EVar "half")) (EVar "half")))
(DTypeSig false "pow2" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "pow2" ((PVar "k")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "k")))
(DTypeSig false "lowBits" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lowBits" ((PVar "n") (PVar "k")) (EBinOp "%" (EVar "n") (EApp (EVar "pow2") (EVar "k"))))
(DTypeSig true "fromInt" (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "fromInt" ((PVar "n")) (EBlock (DoLet false false (PVar "lo") (EApp (EVar "wrapHalf") (EVar "n"))) (DoExpr (ETuple (EApp (EVar "wrapHalf") (EBinOp "/" (EBinOp "-" (EVar "n") (EVar "lo")) (EVar "half"))) (EVar "lo")))))
(DTypeSig true "truncateToInt" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "truncateToInt" ((PTuple (PVar "hi") (PVar "lo"))) (EBlock (DoLet false false (PVar "h") (EBinOp "%" (EVar "hi") (ELit (LInt 2147483648)))) (DoExpr (EIf (EBinOp ">=" (EVar "h") (ELit (LInt 1073741824))) (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "h") (ELit (LInt 2147483648))) (EVar "half")) (EVar "lo")) (EBinOp "+" (EBinOp "*" (EVar "h") (EVar "half")) (EVar "lo"))))))
(DTypeSig true "add" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "add" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (EBlock (DoLet false false (PVar "lo") (EBinOp "+" (EVar "al") (EVar "bl"))) (DoExpr (ETuple (EApp (EVar "wrapHalf") (EBinOp "+" (EBinOp "+" (EVar "ah") (EVar "bh")) (EBinOp "/" (EVar "lo") (EVar "half")))) (EBinOp "%" (EVar "lo") (EVar "half"))))))
(DTypeSig true "sub" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "sub" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (EBlock (DoLet false false (PVar "lo") (EBinOp "-" (EVar "al") (EVar "bl"))) (DoExpr (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ETuple (EApp (EVar "wrapHalf") (EBinOp "-" (EBinOp "-" (EVar "ah") (EVar "bh")) (ELit (LInt 1)))) (EBinOp "+" (EVar "lo") (EVar "half"))) (ETuple (EApp (EVar "wrapHalf") (EBinOp "-" (EVar "ah") (EVar "bh"))) (EVar "lo"))))))
(DTypeSig false "mulHalves" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "mulHalves" ((PVar "x") (PVar "y")) (EBlock (DoLet false false (PVar "x1") (EBinOp "/" (EVar "x") (EVar "piece"))) (DoLet false false (PVar "x0") (EBinOp "%" (EVar "x") (EVar "piece"))) (DoLet false false (PVar "y1") (EBinOp "/" (EVar "y") (EVar "piece"))) (DoLet false false (PVar "y0") (EBinOp "%" (EVar "y") (EVar "piece"))) (DoLet false false (PVar "mid") (EBinOp "+" (EBinOp "*" (EVar "x1") (EVar "y0")) (EBinOp "*" (EVar "x0") (EVar "y1")))) (DoLet false false (PVar "low") (EBinOp "+" (EBinOp "*" (EVar "x0") (EVar "y0")) (EBinOp "*" (EBinOp "%" (EVar "mid") (EVar "piece")) (EVar "piece")))) (DoExpr (ETuple (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "x1") (EVar "y1")) (EBinOp "/" (EVar "mid") (EVar "piece"))) (EBinOp "/" (EVar "low") (EVar "half"))) (EBinOp "%" (EVar "low") (EVar "half"))))))
(DTypeSig true "mul" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "mul" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (EBlock (DoLet false false (PTuple (PVar "ph") (PVar "pl")) (EApp (EApp (EVar "mulHalves") (EVar "al")) (EVar "bl"))) (DoLet false false (PVar "cross") (EBinOp "+" (EApp (EVar "snd") (EApp (EApp (EVar "mulHalves") (EVar "ah")) (EVar "bl"))) (EApp (EVar "snd") (EApp (EApp (EVar "mulHalves") (EVar "al")) (EVar "bh"))))) (DoExpr (ETuple (EApp (EVar "wrapHalf") (EBinOp "+" (EVar "ph") (EVar "cross"))) (EVar "pl")))))
(DTypeSig true "mulHigh" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "mulHigh" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (EBlock (DoLet false false (PTuple (PVar "llh") PWild) (EApp (EApp (EVar "mulHalves") (EVar "al")) (EVar "bl"))) (DoLet false false (PTuple (PVar "hlh") (PVar "hll")) (EApp (EApp (EVar "mulHalves") (EVar "ah")) (EVar "bl"))) (DoLet false false (PTuple (PVar "lhh") (PVar "lhl")) (EApp (EApp (EVar "mulHalves") (EVar "al")) (EVar "bh"))) (DoLet false false (PTuple (PVar "hhh") (PVar "hhl")) (EApp (EApp (EVar "mulHalves") (EVar "ah")) (EVar "bh"))) (DoLet false false (PVar "col1") (EBinOp "+" (EBinOp "+" (EVar "llh") (EVar "hll")) (EVar "lhl"))) (DoLet false false (PVar "col2") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EVar "hhl") (EVar "hlh")) (EVar "lhh")) (EBinOp "/" (EVar "col1") (EVar "half")))) (DoExpr (ETuple (EApp (EVar "wrapHalf") (EBinOp "+" (EVar "hhh") (EBinOp "/" (EVar "col2") (EVar "half")))) (EBinOp "%" (EVar "col2") (EVar "half"))))))
(DTypeSig true "compareU64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Ordering"))))
(DFunDef false "compareU64" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (EMatch (EApp (EApp (EVar "compare") (EVar "ah")) (EVar "bh")) (arm (PCon "Eq") () (EApp (EApp (EVar "compare") (EVar "al")) (EVar "bl"))) (arm (PVar "o") () (EVar "o"))))
(DTypeSig true "isZero" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "isZero" ((PTuple (PVar "hi") (PVar "lo"))) (EBinOp "&&" (EBinOp "==" (EVar "hi") (ELit (LInt 0))) (EBinOp "==" (EVar "lo") (ELit (LInt 0)))))
(DTypeSig true "divMod" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "divMod" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "ah") (ELit (LInt 1073741824))) (EBinOp "<" (EVar "bh") (ELit (LInt 1073741824)))) (EBlock (DoLet false false (PVar "a") (EBinOp "+" (EBinOp "*" (EVar "ah") (EVar "half")) (EVar "al"))) (DoLet false false (PVar "b") (EBinOp "+" (EBinOp "*" (EVar "bh") (EVar "half")) (EVar "bl"))) (DoExpr (ETuple (EApp (EVar "fromInt") (EBinOp "/" (EVar "a") (EVar "b"))) (EApp (EVar "fromInt") (EBinOp "%" (EVar "a") (EVar "b")))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "divModGo") (ELit (LInt 63))) (ETuple (EVar "ah") (EVar "al"))) (ETuple (EVar "bh") (EVar "bl"))) (ETuple (ELit (LInt 0)) (ELit (LInt 0)))) (ETuple (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "divModGo" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "divModGo" ((PVar "bit") (PVar "a") (PVar "b") (PVar "q") (PVar "r")) (EIf (EBinOp "<" (EVar "bit") (ELit (LInt 0))) (ETuple (EVar "q") (EVar "r")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "r1") (EApp (EApp (EVar "bitOrU64") (EApp (EApp (EVar "shiftLeft64") (EVar "r")) (ELit (LInt 1)))) (ETuple (ELit (LInt 0)) (EApp (EApp (EVar "bitAt") (EVar "a")) (EVar "bit"))))) (DoExpr (EIf (EBinOp "==" (EApp (EApp (EVar "compareU64") (EVar "r1")) (EVar "b")) (EVar "Lt")) (EApp (EApp (EApp (EApp (EApp (EVar "divModGo") (EBinOp "-" (EVar "bit") (ELit (LInt 1)))) (EVar "a")) (EVar "b")) (EVar "q")) (EVar "r1")) (EApp (EApp (EApp (EApp (EApp (EVar "divModGo") (EBinOp "-" (EVar "bit") (ELit (LInt 1)))) (EVar "a")) (EVar "b")) (EApp (EApp (EVar "bitOrU64") (EVar "q")) (EApp (EApp (EVar "shiftLeft64") (ETuple (ELit (LInt 0)) (ELit (LInt 1)))) (EVar "bit")))) (EApp (EApp (EVar "sub") (EVar "r1")) (EVar "b")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bitAt" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "bitAt" ((PTuple (PVar "hi") (PVar "lo")) (PVar "k")) (EIf (EBinOp ">=" (EVar "k") (ELit (LInt 32))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "hi")) (EBinOp "-" (EVar "k") (ELit (LInt 32))))) (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "lo")) (EVar "k"))) (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "bitAndU64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "bitAndU64" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (ETuple (EApp (EApp (EVar "bitAnd") (EVar "ah")) (EVar "bh")) (EApp (EApp (EVar "bitAnd") (EVar "al")) (EVar "bl"))))
(DTypeSig true "bitOrU64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "bitOrU64" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (ETuple (EApp (EApp (EVar "bitOr") (EVar "ah")) (EVar "bh")) (EApp (EApp (EVar "bitOr") (EVar "al")) (EVar "bl"))))
(DTypeSig true "bitXorU64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "bitXorU64" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (ETuple (EApp (EApp (EVar "bitXor") (EVar "ah")) (EVar "bh")) (EApp (EApp (EVar "bitXor") (EVar "al")) (EVar "bl"))))
(DTypeSig true "shiftLeft64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "shiftLeft64" ((PTuple (PVar "hi") (PVar "lo")) (PVar "k")) (EIf (EBinOp "||" (EBinOp "<" (EVar "k") (ELit (LInt 0))) (EBinOp ">=" (EVar "k") (ELit (LInt 64)))) (ETuple (ELit (LInt 0)) (ELit (LInt 0))) (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (ETuple (EVar "hi") (EVar "lo")) (EIf (EBinOp ">=" (EVar "k") (ELit (LInt 32))) (ETuple (EBinOp "*" (EApp (EApp (EVar "lowBits") (EVar "lo")) (EBinOp "-" (ELit (LInt 64)) (EVar "k"))) (EApp (EVar "pow2") (EBinOp "-" (EVar "k") (ELit (LInt 32))))) (ELit (LInt 0))) (EIf (EVar "otherwise") (ETuple (EBinOp "+" (EBinOp "*" (EApp (EApp (EVar "lowBits") (EVar "hi")) (EBinOp "-" (ELit (LInt 32)) (EVar "k"))) (EApp (EVar "pow2") (EVar "k"))) (EApp (EApp (EVar "shiftRight") (EVar "lo")) (EBinOp "-" (ELit (LInt 32)) (EVar "k")))) (EBinOp "*" (EApp (EApp (EVar "lowBits") (EVar "lo")) (EBinOp "-" (ELit (LInt 32)) (EVar "k"))) (EApp (EVar "pow2") (EVar "k")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "shiftRight64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "shiftRight64" ((PTuple (PVar "hi") (PVar "lo")) (PVar "k")) (EIf (EBinOp "||" (EBinOp "<" (EVar "k") (ELit (LInt 0))) (EBinOp ">=" (EVar "k") (ELit (LInt 64)))) (ETuple (ELit (LInt 0)) (ELit (LInt 0))) (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (ETuple (EVar "hi") (EVar "lo")) (EIf (EBinOp ">=" (EVar "k") (ELit (LInt 32))) (ETuple (ELit (LInt 0)) (EApp (EApp (EVar "shiftRight") (EVar "hi")) (EBinOp "-" (EVar "k") (ELit (LInt 32))))) (EIf (EVar "otherwise") (ETuple (EApp (EApp (EVar "shiftRight") (EVar "hi")) (EVar "k")) (EBinOp "+" (EApp (EApp (EVar "shiftRight") (EVar "lo")) (EVar "k")) (EBinOp "*" (EApp (EApp (EVar "lowBits") (EVar "hi")) (EVar "k")) (EApp (EVar "pow2") (EBinOp "-" (ELit (LInt 32)) (EVar "k")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "toDecimal" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))
(DFunDef false "toDecimal" ((PTuple (PLit (LInt 0)) (PVar "lo"))) (EApp (EVar "intToString") (EVar "lo")))
(DFunDef false "toDecimal" ((PVar "v")) (EApp (EApp (EVar "toDecimalGo") (EVar "v")) (ELit (LString ""))))
(DTypeSig false "toDecimalGo" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "toDecimalGo" ((PTuple (PLit (LInt 0)) (PLit (LInt 0))) (PVar "acc")) (EVar "acc"))
(DFunDef false "toDecimalGo" ((PTuple (PVar "hi") (PVar "lo")) (PVar "acc")) (EBlock (DoLet false false (PVar "t") (EBinOp "+" (EBinOp "*" (EBinOp "%" (EVar "hi") (ELit (LInt 10))) (EVar "half")) (EVar "lo"))) (DoExpr (EApp (EApp (EVar "toDecimalGo") (ETuple (EBinOp "/" (EVar "hi") (ELit (LInt 10))) (EBinOp "/" (EVar "t") (ELit (LInt 10))))) (EBinOp "++" (EApp (EVar "intToString") (EBinOp "%" (EVar "t") (ELit (LInt 10)))) (EVar "acc"))))))
# MARK
(DTypeSig false "half" (TyCon "Int"))
(DFunDef false "half" () (ELit (LInt 4294967296)))
(DTypeSig false "piece" (TyCon "Int"))
(DFunDef false "piece" () (ELit (LInt 65536)))
(DTypeSig false "wrapHalf" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "wrapHalf" ((PVar "n")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (EVar "half")) (EVar "half")) (EVar "half")))
(DTypeSig false "pow2" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "pow2" ((PVar "k")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EVar "k")))
(DTypeSig false "lowBits" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lowBits" ((PVar "n") (PVar "k")) (EBinOp "%" (EVar "n") (EApp (EVar "pow2") (EVar "k"))))
(DTypeSig true "fromInt#shadow" (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "fromInt#shadow" ((PVar "n")) (EBlock (DoLet false false (PVar "lo") (EApp (EVar "wrapHalf") (EVar "n"))) (DoExpr (ETuple (EApp (EVar "wrapHalf") (EBinOp "/" (EBinOp "-" (EVar "n") (EVar "lo")) (EVar "half"))) (EVar "lo")))))
(DTypeSig true "truncateToInt" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "truncateToInt" ((PTuple (PVar "hi") (PVar "lo"))) (EBlock (DoLet false false (PVar "h") (EBinOp "%" (EVar "hi") (ELit (LInt 2147483648)))) (DoExpr (EIf (EBinOp ">=" (EVar "h") (ELit (LInt 1073741824))) (EBinOp "+" (EBinOp "*" (EBinOp "-" (EVar "h") (ELit (LInt 2147483648))) (EVar "half")) (EVar "lo")) (EBinOp "+" (EBinOp "*" (EVar "h") (EVar "half")) (EVar "lo"))))))
(DTypeSig true "add#shadow" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "add#shadow" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (EBlock (DoLet false false (PVar "lo") (EBinOp "+" (EVar "al") (EVar "bl"))) (DoExpr (ETuple (EApp (EVar "wrapHalf") (EBinOp "+" (EBinOp "+" (EVar "ah") (EVar "bh")) (EBinOp "/" (EVar "lo") (EVar "half")))) (EBinOp "%" (EVar "lo") (EVar "half"))))))
(DTypeSig true "sub#shadow" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "sub#shadow" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (EBlock (DoLet false false (PVar "lo") (EBinOp "-" (EVar "al") (EVar "bl"))) (DoExpr (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ETuple (EApp (EVar "wrapHalf") (EBinOp "-" (EBinOp "-" (EVar "ah") (EVar "bh")) (ELit (LInt 1)))) (EBinOp "+" (EVar "lo") (EVar "half"))) (ETuple (EApp (EVar "wrapHalf") (EBinOp "-" (EVar "ah") (EVar "bh"))) (EVar "lo"))))))
(DTypeSig false "mulHalves" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "mulHalves" ((PVar "x") (PVar "y")) (EBlock (DoLet false false (PVar "x1") (EBinOp "/" (EVar "x") (EVar "piece"))) (DoLet false false (PVar "x0") (EBinOp "%" (EVar "x") (EVar "piece"))) (DoLet false false (PVar "y1") (EBinOp "/" (EVar "y") (EVar "piece"))) (DoLet false false (PVar "y0") (EBinOp "%" (EVar "y") (EVar "piece"))) (DoLet false false (PVar "mid") (EBinOp "+" (EBinOp "*" (EVar "x1") (EVar "y0")) (EBinOp "*" (EVar "x0") (EVar "y1")))) (DoLet false false (PVar "low") (EBinOp "+" (EBinOp "*" (EVar "x0") (EVar "y0")) (EBinOp "*" (EBinOp "%" (EVar "mid") (EVar "piece")) (EVar "piece")))) (DoExpr (ETuple (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "x1") (EVar "y1")) (EBinOp "/" (EVar "mid") (EVar "piece"))) (EBinOp "/" (EVar "low") (EVar "half"))) (EBinOp "%" (EVar "low") (EVar "half"))))))
(DTypeSig true "mul#shadow" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "mul#shadow" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (EBlock (DoLet false false (PTuple (PVar "ph") (PVar "pl")) (EApp (EApp (EVar "mulHalves") (EVar "al")) (EVar "bl"))) (DoLet false false (PVar "cross") (EBinOp "+" (EApp (EVar "snd") (EApp (EApp (EVar "mulHalves") (EVar "ah")) (EVar "bl"))) (EApp (EVar "snd") (EApp (EApp (EVar "mulHalves") (EVar "al")) (EVar "bh"))))) (DoExpr (ETuple (EApp (EVar "wrapHalf") (EBinOp "+" (EVar "ph") (EVar "cross"))) (EVar "pl")))))
(DTypeSig true "mulHigh" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "mulHigh" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (EBlock (DoLet false false (PTuple (PVar "llh") PWild) (EApp (EApp (EVar "mulHalves") (EVar "al")) (EVar "bl"))) (DoLet false false (PTuple (PVar "hlh") (PVar "hll")) (EApp (EApp (EVar "mulHalves") (EVar "ah")) (EVar "bl"))) (DoLet false false (PTuple (PVar "lhh") (PVar "lhl")) (EApp (EApp (EVar "mulHalves") (EVar "al")) (EVar "bh"))) (DoLet false false (PTuple (PVar "hhh") (PVar "hhl")) (EApp (EApp (EVar "mulHalves") (EVar "ah")) (EVar "bh"))) (DoLet false false (PVar "col1") (EBinOp "+" (EBinOp "+" (EVar "llh") (EVar "hll")) (EVar "lhl"))) (DoLet false false (PVar "col2") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EVar "hhl") (EVar "hlh")) (EVar "lhh")) (EBinOp "/" (EVar "col1") (EVar "half")))) (DoExpr (ETuple (EApp (EVar "wrapHalf") (EBinOp "+" (EVar "hhh") (EBinOp "/" (EVar "col2") (EVar "half")))) (EBinOp "%" (EVar "col2") (EVar "half"))))))
(DTypeSig true "compareU64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Ordering"))))
(DFunDef false "compareU64" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "ah")) (EVar "bh")) (arm (PCon "Eq") () (EApp (EApp (EMethodRef "compare") (EVar "al")) (EVar "bl"))) (arm (PVar "o") () (EVar "o"))))
(DTypeSig true "isZero" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "isZero" ((PTuple (PVar "hi") (PVar "lo"))) (EBinOp "&&" (EBinOp "==" (EVar "hi") (ELit (LInt 0))) (EBinOp "==" (EVar "lo") (ELit (LInt 0)))))
(DTypeSig true "divMod" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "divMod" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "ah") (ELit (LInt 1073741824))) (EBinOp "<" (EVar "bh") (ELit (LInt 1073741824)))) (EBlock (DoLet false false (PVar "a") (EBinOp "+" (EBinOp "*" (EVar "ah") (EVar "half")) (EVar "al"))) (DoLet false false (PVar "b") (EBinOp "+" (EBinOp "*" (EVar "bh") (EVar "half")) (EVar "bl"))) (DoExpr (ETuple (EApp (EVar "fromInt#shadow") (EBinOp "/" (EVar "a") (EVar "b"))) (EApp (EVar "fromInt#shadow") (EBinOp "%" (EVar "a") (EVar "b")))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "divModGo") (ELit (LInt 63))) (ETuple (EVar "ah") (EVar "al"))) (ETuple (EVar "bh") (EVar "bl"))) (ETuple (ELit (LInt 0)) (ELit (LInt 0)))) (ETuple (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "divModGo" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "divModGo" ((PVar "bit") (PVar "a") (PVar "b") (PVar "q") (PVar "r")) (EIf (EBinOp "<" (EVar "bit") (ELit (LInt 0))) (ETuple (EVar "q") (EVar "r")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "r1") (EApp (EApp (EVar "bitOrU64") (EApp (EApp (EVar "shiftLeft64") (EVar "r")) (ELit (LInt 1)))) (ETuple (ELit (LInt 0)) (EApp (EApp (EVar "bitAt") (EVar "a")) (EVar "bit"))))) (DoExpr (EIf (EBinOp "==" (EApp (EApp (EVar "compareU64") (EVar "r1")) (EVar "b")) (EVar "Lt")) (EApp (EApp (EApp (EApp (EApp (EVar "divModGo") (EBinOp "-" (EVar "bit") (ELit (LInt 1)))) (EVar "a")) (EVar "b")) (EVar "q")) (EVar "r1")) (EApp (EApp (EApp (EApp (EApp (EVar "divModGo") (EBinOp "-" (EVar "bit") (ELit (LInt 1)))) (EVar "a")) (EVar "b")) (EApp (EApp (EVar "bitOrU64") (EVar "q")) (EApp (EApp (EVar "shiftLeft64") (ETuple (ELit (LInt 0)) (ELit (LInt 1)))) (EVar "bit")))) (EApp (EApp (EVar "sub#shadow") (EVar "r1")) (EVar "b")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bitAt" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "bitAt" ((PTuple (PVar "hi") (PVar "lo")) (PVar "k")) (EIf (EBinOp ">=" (EVar "k") (ELit (LInt 32))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "hi")) (EBinOp "-" (EVar "k") (ELit (LInt 32))))) (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "lo")) (EVar "k"))) (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "bitAndU64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "bitAndU64" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (ETuple (EApp (EApp (EVar "bitAnd") (EVar "ah")) (EVar "bh")) (EApp (EApp (EVar "bitAnd") (EVar "al")) (EVar "bl"))))
(DTypeSig true "bitOrU64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "bitOrU64" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (ETuple (EApp (EApp (EVar "bitOr") (EVar "ah")) (EVar "bh")) (EApp (EApp (EVar "bitOr") (EVar "al")) (EVar "bl"))))
(DTypeSig true "bitXorU64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "bitXorU64" ((PTuple (PVar "ah") (PVar "al")) (PTuple (PVar "bh") (PVar "bl"))) (ETuple (EApp (EApp (EVar "bitXor") (EVar "ah")) (EVar "bh")) (EApp (EApp (EVar "bitXor") (EVar "al")) (EVar "bl"))))
(DTypeSig true "shiftLeft64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "shiftLeft64" ((PTuple (PVar "hi") (PVar "lo")) (PVar "k")) (EIf (EBinOp "||" (EBinOp "<" (EVar "k") (ELit (LInt 0))) (EBinOp ">=" (EVar "k") (ELit (LInt 64)))) (ETuple (ELit (LInt 0)) (ELit (LInt 0))) (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (ETuple (EVar "hi") (EVar "lo")) (EIf (EBinOp ">=" (EVar "k") (ELit (LInt 32))) (ETuple (EBinOp "*" (EApp (EApp (EVar "lowBits") (EVar "lo")) (EBinOp "-" (ELit (LInt 64)) (EVar "k"))) (EApp (EVar "pow2") (EBinOp "-" (EVar "k") (ELit (LInt 32))))) (ELit (LInt 0))) (EIf (EVar "otherwise") (ETuple (EBinOp "+" (EBinOp "*" (EApp (EApp (EVar "lowBits") (EVar "hi")) (EBinOp "-" (ELit (LInt 32)) (EVar "k"))) (EApp (EVar "pow2") (EVar "k"))) (EApp (EApp (EVar "shiftRight") (EVar "lo")) (EBinOp "-" (ELit (LInt 32)) (EVar "k")))) (EBinOp "*" (EApp (EApp (EVar "lowBits") (EVar "lo")) (EBinOp "-" (ELit (LInt 32)) (EVar "k"))) (EApp (EVar "pow2") (EVar "k")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "shiftRight64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "shiftRight64" ((PTuple (PVar "hi") (PVar "lo")) (PVar "k")) (EIf (EBinOp "||" (EBinOp "<" (EVar "k") (ELit (LInt 0))) (EBinOp ">=" (EVar "k") (ELit (LInt 64)))) (ETuple (ELit (LInt 0)) (ELit (LInt 0))) (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (ETuple (EVar "hi") (EVar "lo")) (EIf (EBinOp ">=" (EVar "k") (ELit (LInt 32))) (ETuple (ELit (LInt 0)) (EApp (EApp (EVar "shiftRight") (EVar "hi")) (EBinOp "-" (EVar "k") (ELit (LInt 32))))) (EIf (EVar "otherwise") (ETuple (EApp (EApp (EVar "shiftRight") (EVar "hi")) (EVar "k")) (EBinOp "+" (EApp (EApp (EVar "shiftRight") (EVar "lo")) (EVar "k")) (EBinOp "*" (EApp (EApp (EVar "lowBits") (EVar "hi")) (EVar "k")) (EApp (EVar "pow2") (EBinOp "-" (ELit (LInt 32)) (EVar "k")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "toDecimal" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "String")))
(DFunDef false "toDecimal" ((PTuple (PLit (LInt 0)) (PVar "lo"))) (EApp (EVar "intToString") (EVar "lo")))
(DFunDef false "toDecimal" ((PVar "v")) (EApp (EApp (EVar "toDecimalGo") (EVar "v")) (ELit (LString ""))))
(DTypeSig false "toDecimalGo" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "toDecimalGo" ((PTuple (PLit (LInt 0)) (PLit (LInt 0))) (PVar "acc")) (EVar "acc"))
(DFunDef false "toDecimalGo" ((PTuple (PVar "hi") (PVar "lo")) (PVar "acc")) (EBlock (DoLet false false (PVar "t") (EBinOp "+" (EBinOp "*" (EBinOp "%" (EVar "hi") (ELit (LInt 10))) (EVar "half")) (EVar "lo"))) (DoExpr (EApp (EApp (EVar "toDecimalGo") (ETuple (EBinOp "/" (EVar "hi") (ELit (LInt 10))) (EBinOp "/" (EVar "t") (ELit (LInt 10))))) (EBinOp "++" (EApp (EVar "intToString") (EBinOp "%" (EVar "t") (ELit (LInt 10)))) (EVar "acc"))))))
