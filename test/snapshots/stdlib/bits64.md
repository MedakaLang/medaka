# META
source_lines=342
stages=DESUGAR,MARK
# SOURCE
{- bits64.mdk — 64-bit-unsigned arithmetic over the 63-bit `Int` fixnum.

   Medaka's `Int` is a 63-bit fixnum that WRAPS on overflow, so it cannot hold
   a `uint64` value (let alone a `uint64` product mod 2^64).  This module
   emulates a `uint64` as four 16-bit limbs `U64 l0 l1 l2 l3`,
   least-significant first — exactly the representation the compiler itself
   hand-rolled in `compiler/eval/eval.mdk` to reproduce SplitMix64 / FNV-1a
   faithfully while fixing issue #98.  The algorithms here mirror that proven
   implementation.

   Why a `data` type and not a tuple alias (#2311): a transparent
   `type U64 = (Int, Int, Int, Int)` alias let the prelude's generic tuple
   `Ord` reach the limbs in the WRONG order — `compare` ordered by `l0` first
   and silently disagreed with `cmp` on the same values, with no diagnostic.
   The nullary-constructor newtype carries its own `Eq`/`Ord`/`Debug`/
   `Display`/`Hashable`, and its `Ord` delegates to `cmp`, so the prelude and
   this module can no longer answer differently.

   Every intermediate stays well under the 63-bit range: a limb < 2^16, a
   16×16 partial product < 2^32, and a column sum of four such products plus a
   carry < 2^35 — so no native op ever overflows during a computation.

   Use it for hashing, PRNGs, checksums, and binary/wire formats — anything
   that needs the C `unsigned long long` overflow / bit semantics.  All ops are
   modulo 2^64 (they wrap), matching C's unsigned arithmetic.

   Operations are fn-first/data-last and carry no `64` suffix — the module is
   already called `bits64`.  Import qualified (`import bits64 as B`) if you
   also want the prelude's boolean `and`/`or`/`xor`, or the `Num` interface's
   `add`/`sub`, in the same scope. -}

-- The SplitMix64/FNV-1a limb helpers the interpreter's RNG/hash externs are
-- built on (issue #98) now live HERE: `compiler/eval/eval.mdk` imports this
-- module instead of hand-rolling its own copy (issue #223), so the two share
-- one proven implementation.

import core.{Ordering}

-- A `uint64` as four 16-bit limbs, least-significant first: the value is
-- `l0 + l1*2^16 + l2*2^32 + l3*2^48`, each limb in `[0, 2^16)`.
public export data U64 =
  | U64 Int Int Int Int
deriving (Eq, Debug, Display, Hashable)

-- ── Construction ────────────────────────────────────────────────────────

-- The all-zero `uint64`.
export
zero : U64
zero = U64 0 0 0 0

-- The `uint64` value 1.
export
one : U64
one = U64 1 0 0 0

{- | Split a Medaka `Int` into `uint64` limbs, masking to the low 64 bits.

   Because each 16-bit window is masked immediately, this reproduces C's
   `(unsigned long long)n` for negatives too (the two's-complement bits of a
   window are the same under either shift convention).

   (Named `fromIntBits`, not `fromInt`, on purpose: `fromInt` is the `Num`
   interface method in `core.mdk`, and a top-level binding of that name is
   absorbed as a method definition and poisons inference for the whole
   module.)

   > fromIntBits 1
   U64 1 0 0 0
   > fromIntBits 65536
   U64 0 1 0 0
   > fromIntBits 4294967296
   U64 0 0 1 0 -}
export
fromIntBits : Int -> U64
fromIntBits n =
  U64
    (bitAnd n 65535)
    (bitAnd (shiftRight n 16) 65535)
    (bitAnd (shiftRight n 32) 65535)
    (bitAnd (shiftRight n 48) 65535)

-- ── Predicates ──────────────────────────────────────────────────────────

{- | Is this `uint64` zero?

   > isZero (fromIntBits 0)
   True
   > isZero (fromIntBits 5)
   False -}
export
isZero : U64 -> Bool
isZero (U64 a0 a1 a2 a3) = a0 == 0 && a1 == 0 && a2 == 0 && a3 == 0

{- | Compare two `uint64` values (unsigned).  The `Ord U64` instance delegates
   here, so `compare` and `cmp` can never disagree (#2311).

   > cmp (fromIntBits 1) (fromIntBits 2)
   Lt
   > cmp (fromIntBits 2) (fromIntBits 2)
   Eq
   > cmp (fromIntBits 3) (fromIntBits 2)
   Gt
   > cmp (U64 0 0 0 1) (U64 65535 65535 65535 0)
   Gt -}
export
cmp : U64 -> U64 -> Ordering
cmp (U64 a0 a1 a2 a3) (U64 b0 b1 b2 b3) =
  if a3 /= b3 then
    if a3 > b3 then Gt else Lt
  else if a2 /= b2 then
    if a2 > b2 then Gt else Lt
  else if a1 /= b1 then
    if a1 > b1 then Gt else Lt
  else if a0 /= b0 then
    if a0 > b0 then Gt else Lt
  else
    Eq

-- Unsigned ordering, NOT the limb-lexicographic order a derived `Ord` would
-- produce: the limbs are least-significant FIRST, so the derived instance
-- would compare `l0` before `l3` and order values wrongly (#2311).
export impl Ord U64 where
  compare a b = cmp a b

-- ── Arithmetic ──────────────────────────────────────────────────────────

{- | Addition mod 2^64 (wraps on overflow).

   > add (fromIntBits 1) (fromIntBits 2)
   U64 3 0 0 0
   > add (fromIntBits 65535) (fromIntBits 1)
   U64 0 1 0 0
   > add (U64 65535 65535 65535 65535) (fromIntBits 1)
   U64 0 0 0 0 -}
export
add : U64 -> U64 -> U64
add (U64 a0 a1 a2 a3) (U64 b0 b1 b2 b3) =
  let s0 = a0 + b0
  let s1 = a1 + b1 + shiftRight s0 16
  let s2 = a2 + b2 + shiftRight s1 16
  let s3 = a3 + b3 + shiftRight s2 16
  U64 (bitAnd s0 65535) (bitAnd s1 65535) (bitAnd s2 65535) (bitAnd s3 65535)

{- | Subtraction mod 2^64: `a - b`, wrapping when `b > a`.

   A negative limb difference masks to its low 16 bits (`+65536`), which IS
   the borrow into the next limb.

   > sub (fromIntBits 5) (fromIntBits 3)
   U64 2 0 0 0
   > sub (fromIntBits 0) (fromIntBits 1)
   U64 65535 65535 65535 65535 -}
export
sub : U64 -> U64 -> U64
sub (U64 a0 a1 a2 a3) (U64 b0 b1 b2 b3) =
  let d0 = a0 - b0
  let d1 = a1 - b1 - (if d0 < 0 then 1 else 0)
  let d2 = a2 - b2 - (if d1 < 0 then 1 else 0)
  let d3 = a3 - b3 - (if d2 < 0 then 1 else 0)
  U64 (bitAnd d0 65535) (bitAnd d1 65535) (bitAnd d2 65535) (bitAnd d3 65535)

{- | Low 64 bits of the product `a * b` (i.e. `a * b mod 2^64`) — schoolbook
   multiply keeping only the low four limbs.

   > mulLow (fromIntBits 7) (fromIntBits 6)
   U64 42 0 0 0
   > mulLow (fromIntBits 65536) (fromIntBits 65536)
   U64 0 0 1 0
   > mulLow (U64 0 0 0 1) (U64 0 1 0 0)
   U64 0 0 0 0 -}
export
mulLow : U64 -> U64 -> U64
mulLow (U64 a0 a1 a2 a3) (U64 b0 b1 b2 b3) =
  let c0 = a0 * b0
  let c1 = a0 * b1 + a1 * b0 + shiftRight c0 16
  let c2 = a0 * b2 + a1 * b1 + a2 * b0 + shiftRight c1 16
  let c3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0 + shiftRight c2 16
  U64 (bitAnd c0 65535) (bitAnd c1 65535) (bitAnd c2 65535) (bitAnd c3 65535)

-- ── Bitwise ─────────────────────────────────────────────────────────────

{- | Bitwise AND.  Shadows the prelude's boolean `and` when imported
   unqualified — import `bits64` qualified if you need both.

   > and (fromIntBits 12) (fromIntBits 10)
   U64 8 0 0 0 -}
export
and : U64 -> U64 -> U64
and (U64 a0 a1 a2 a3) (U64 b0 b1 b2 b3) =
  U64 (bitAnd a0 b0) (bitAnd a1 b1) (bitAnd a2 b2) (bitAnd a3 b3)

{- | Bitwise OR.  Shadows the prelude's boolean `or` when imported
   unqualified.

   > or (fromIntBits 12) (fromIntBits 10)
   U64 14 0 0 0 -}
export
or : U64 -> U64 -> U64
or (U64 a0 a1 a2 a3) (U64 b0 b1 b2 b3) =
  U64 (bitOr a0 b0) (bitOr a1 b1) (bitOr a2 b2) (bitOr a3 b3)

{- | Bitwise XOR.  Shadows the prelude's boolean `xor` when imported
   unqualified.

   > xor (fromIntBits 12) (fromIntBits 10)
   U64 6 0 0 0 -}
export
xor : U64 -> U64 -> U64
xor (U64 a0 a1 a2 a3) (U64 b0 b1 b2 b3) =
  U64 (bitXor a0 b0) (bitXor a1 b1) (bitXor a2 b2) (bitXor a3 b3)

{- | Limb `i` of a `uint64` — its bits `[16i, 16i+15]` as an `Int` in
   `[0, 2^16)`.  Out-of-range `i` (`< 0` or `> 3`) reads as `0`.

   > limbAt 2 (U64 10 20 30 40)
   30
   > limbAt 1 (fromIntBits 65536)
   1 -}
export
limbAt : Int -> U64 -> Int
limbAt i (U64 a0 a1 a2 a3) =
  if i == 0 then
    a0
  else if i == 1 then
    a1
  else if i == 2 then
    a2
  else if i == 3 then
    a3
  else
    0

-- Whole-limb offset for a shift of `n` bits (n in [0, 63]).
shiftWords : Int -> Int
shiftWords n =
  if n >= 48 then
    3
  else if n >= 32 then
    2
  else if n >= 16 then
    1
  else
    0

-- One output limb of a logical right shift: low bits of limb `(i+ws)` plus the
-- carried-in low bits of limb `(i+ws+1)`.
shrLimb : U64 -> Int -> Int -> Int -> Int
shrLimb u ws bs i =
  bitAnd
    (bitOr
      (shiftRight (limbAt (i + ws) u) bs)
      (shiftLeft (limbAt (i + ws + 1) u) (16 - bs)))
    65535

{- | Logical right shift by `n` bits, `n` in `[0, 63]`.  Vacated high bits are
   filled with zeros (unsigned shift).

   > shr 4 (fromIntBits 256)
   U64 16 0 0 0
   > shr 16 (fromIntBits 65536)
   U64 1 0 0 0
   > shr 63 (U64 0 0 0 32768)
   U64 1 0 0 0 -}
export
shr : Int -> U64 -> U64
shr n u =
  let ws = shiftWords n
  let bs = n - ws * 16
  U64
    (shrLimb u ws bs 0)
    (shrLimb u ws bs 1)
    (shrLimb u ws bs 2)
    (shrLimb u ws bs 3)

-- One output limb of a left shift: high bits of limb `(i-ws)` plus the
-- carried-in high bits of limb `(i-ws-1)`.
shlLimb : U64 -> Int -> Int -> Int -> Int
shlLimb u ws bs i =
  bitAnd
    (bitOr
      (shiftLeft (limbAt (i - ws) u) bs)
      (shiftRight (limbAt (i - ws - 1) u) (16 - bs)))
    65535

{- | Logical left shift by `n` bits, `n` in `[0, 63]`.  Bits shifted past bit
   63 are dropped (mod 2^64).

   > shl 4 (fromIntBits 1)
   U64 16 0 0 0
   > shl 16 (fromIntBits 1)
   U64 0 1 0 0
   > shl 63 (fromIntBits 1)
   U64 0 0 0 32768 -}
export
shl : Int -> U64 -> U64
shl n u =
  let ws = shiftWords n
  let bs = n - ws * 16
  U64
    (shlLimb u ws bs 0)
    (shlLimb u ws bs 1)
    (shlLimb u ws bs 2)
    (shlLimb u ws bs 3)

-- ── Division ────────────────────────────────────────────────────────────

-- Bit `i` (0 = LSB) of a `uint64`.
bitAt : U64 -> Int -> Int
bitAt u i = bitAnd (limbAt 0 (shr i u)) 1

-- Schoolbook bit-by-bit long division, MSB first, kept entirely inside the
-- limb rep so nothing overflows a bare 63-bit Int.  Accumulates the remainder.
modGo : U64 -> U64 -> U64 -> Int -> U64
modGo dividend divisor rem i =
  if i < 0 then rem
  else
    let shifted = add rem rem
    let bit = bitAt dividend i
    let rem2 = U64 (bitOr (limbAt 0 shifted) bit) (limbAt 1 shifted) (limbAt 2 shifted) (limbAt 3 shifted)
    let rem3 = match cmp rem2 divisor
      Lt => rem2
      _ => sub rem2 divisor
    modGo dividend divisor rem3 (i - 1)

{- | Exact `uint64` modulo: `dividend mod divisor`, correct for any nonzero
   divisor up to 2^64 - 1 (a running-remainder shortcut would be wrong for
   large divisors).  A zero divisor is a caller error and yields `dividend`.

   > mod (fromIntBits 17) (fromIntBits 5)
   U64 2 0 0 0
   > mod (U64 65535 65535 65535 65535) (fromIntBits 10)
   U64 5 0 0 0
   > mod (U64 0 0 0 32768) (fromIntBits 3)
   U64 2 0 0 0 -}
export
mod : U64 -> U64 -> U64
mod dividend divisor =
  if isZero divisor then
    dividend
  else
    modGo dividend divisor zero 63
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Ordering" false))))
(DData Public "U64" () ((variant "U64" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "U64")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "U64" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) (PCon "U64" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "U64")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "U64" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "U64 ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a3")))))))))
(DImpl true "Display" ((TyCon "U64")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "U64" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "U64 ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a3")))))))))
(DImpl true "Hashable" ((TyCon "U64")) () ((im "hash" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "U64" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (ELit (LInt 0)) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "__a0"))) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "__a1"))) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "__a2"))) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "__a3"))))))))
(DTypeSig true "zero" (TyCon "U64"))
(DFunDef false "zero" () (EApp (EApp (EApp (EApp (EVar "U64") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig true "one" (TyCon "U64"))
(DFunDef false "one" () (EApp (EApp (EApp (EApp (EVar "U64") (ELit (LInt 1))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig true "fromIntBits" (TyFun (TyCon "Int") (TyCon "U64")))
(DFunDef false "fromIntBits" ((PVar "n")) (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitAnd") (EVar "n")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 16)))) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 32)))) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 48)))) (ELit (LInt 65535)))))
(DTypeSig true "isZero" (TyFun (TyCon "U64") (TyCon "Bool")))
(DFunDef false "isZero" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "a0") (ELit (LInt 0))) (EBinOp "==" (EVar "a1") (ELit (LInt 0)))) (EBinOp "==" (EVar "a2") (ELit (LInt 0)))) (EBinOp "==" (EVar "a3") (ELit (LInt 0)))))
(DTypeSig true "cmp" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "Ordering"))))
(DFunDef false "cmp" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EIf (EBinOp "/=" (EVar "a3") (EVar "b3")) (EIf (EBinOp ">" (EVar "a3") (EVar "b3")) (EVar "Gt") (EVar "Lt")) (EIf (EBinOp "/=" (EVar "a2") (EVar "b2")) (EIf (EBinOp ">" (EVar "a2") (EVar "b2")) (EVar "Gt") (EVar "Lt")) (EIf (EBinOp "/=" (EVar "a1") (EVar "b1")) (EIf (EBinOp ">" (EVar "a1") (EVar "b1")) (EVar "Gt") (EVar "Lt")) (EIf (EBinOp "/=" (EVar "a0") (EVar "b0")) (EIf (EBinOp ">" (EVar "a0") (EVar "b0")) (EVar "Gt") (EVar "Lt")) (EVar "Eq"))))))
(DImpl true "Ord" ((TyCon "U64")) () ((im "compare" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "cmp") (EVar "a")) (EVar "b")))))
(DTypeSig true "add" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "add" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EBlock (DoLet false false (PVar "s0") (EBinOp "+" (EVar "a0") (EVar "b0"))) (DoLet false false (PVar "s1") (EBinOp "+" (EBinOp "+" (EVar "a1") (EVar "b1")) (EApp (EApp (EVar "shiftRight") (EVar "s0")) (ELit (LInt 16))))) (DoLet false false (PVar "s2") (EBinOp "+" (EBinOp "+" (EVar "a2") (EVar "b2")) (EApp (EApp (EVar "shiftRight") (EVar "s1")) (ELit (LInt 16))))) (DoLet false false (PVar "s3") (EBinOp "+" (EBinOp "+" (EVar "a3") (EVar "b3")) (EApp (EApp (EVar "shiftRight") (EVar "s2")) (ELit (LInt 16))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitAnd") (EVar "s0")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "s1")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "s2")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "s3")) (ELit (LInt 65535)))))))
(DTypeSig true "sub" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "sub" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EBlock (DoLet false false (PVar "d0") (EBinOp "-" (EVar "a0") (EVar "b0"))) (DoLet false false (PVar "d1") (EBinOp "-" (EBinOp "-" (EVar "a1") (EVar "b1")) (EIf (EBinOp "<" (EVar "d0") (ELit (LInt 0))) (ELit (LInt 1)) (ELit (LInt 0))))) (DoLet false false (PVar "d2") (EBinOp "-" (EBinOp "-" (EVar "a2") (EVar "b2")) (EIf (EBinOp "<" (EVar "d1") (ELit (LInt 0))) (ELit (LInt 1)) (ELit (LInt 0))))) (DoLet false false (PVar "d3") (EBinOp "-" (EBinOp "-" (EVar "a3") (EVar "b3")) (EIf (EBinOp "<" (EVar "d2") (ELit (LInt 0))) (ELit (LInt 1)) (ELit (LInt 0))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitAnd") (EVar "d0")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "d1")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "d2")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "d3")) (ELit (LInt 65535)))))))
(DTypeSig true "mulLow" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "mulLow" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EBlock (DoLet false false (PVar "c0") (EBinOp "*" (EVar "a0") (EVar "b0"))) (DoLet false false (PVar "c1") (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "a0") (EVar "b1")) (EBinOp "*" (EVar "a1") (EVar "b0"))) (EApp (EApp (EVar "shiftRight") (EVar "c0")) (ELit (LInt 16))))) (DoLet false false (PVar "c2") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "a0") (EVar "b2")) (EBinOp "*" (EVar "a1") (EVar "b1"))) (EBinOp "*" (EVar "a2") (EVar "b0"))) (EApp (EApp (EVar "shiftRight") (EVar "c1")) (ELit (LInt 16))))) (DoLet false false (PVar "c3") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "a0") (EVar "b3")) (EBinOp "*" (EVar "a1") (EVar "b2"))) (EBinOp "*" (EVar "a2") (EVar "b1"))) (EBinOp "*" (EVar "a3") (EVar "b0"))) (EApp (EApp (EVar "shiftRight") (EVar "c2")) (ELit (LInt 16))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitAnd") (EVar "c0")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "c1")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "c2")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "c3")) (ELit (LInt 65535)))))))
(DTypeSig true "and" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "and" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitAnd") (EVar "a0")) (EVar "b0"))) (EApp (EApp (EVar "bitAnd") (EVar "a1")) (EVar "b1"))) (EApp (EApp (EVar "bitAnd") (EVar "a2")) (EVar "b2"))) (EApp (EApp (EVar "bitAnd") (EVar "a3")) (EVar "b3"))))
(DTypeSig true "or" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "or" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitOr") (EVar "a0")) (EVar "b0"))) (EApp (EApp (EVar "bitOr") (EVar "a1")) (EVar "b1"))) (EApp (EApp (EVar "bitOr") (EVar "a2")) (EVar "b2"))) (EApp (EApp (EVar "bitOr") (EVar "a3")) (EVar "b3"))))
(DTypeSig true "xor" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "xor" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitXor") (EVar "a0")) (EVar "b0"))) (EApp (EApp (EVar "bitXor") (EVar "a1")) (EVar "b1"))) (EApp (EApp (EVar "bitXor") (EVar "a2")) (EVar "b2"))) (EApp (EApp (EVar "bitXor") (EVar "a3")) (EVar "b3"))))
(DTypeSig true "limbAt" (TyFun (TyCon "Int") (TyFun (TyCon "U64") (TyCon "Int"))))
(DFunDef false "limbAt" ((PVar "i") (PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EVar "a0") (EIf (EBinOp "==" (EVar "i") (ELit (LInt 1))) (EVar "a1") (EIf (EBinOp "==" (EVar "i") (ELit (LInt 2))) (EVar "a2") (EIf (EBinOp "==" (EVar "i") (ELit (LInt 3))) (EVar "a3") (ELit (LInt 0)))))))
(DTypeSig false "shiftWords" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "shiftWords" ((PVar "n")) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (ELit (LInt 3)) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 32))) (ELit (LInt 2)) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 16))) (ELit (LInt 1)) (ELit (LInt 0))))))
(DTypeSig false "shrLimb" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "shrLimb" ((PVar "u") (PVar "ws") (PVar "bs") (PVar "i")) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftRight") (EApp (EApp (EVar "limbAt") (EBinOp "+" (EVar "i") (EVar "ws"))) (EVar "u"))) (EVar "bs"))) (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "limbAt") (EBinOp "+" (EBinOp "+" (EVar "i") (EVar "ws")) (ELit (LInt 1)))) (EVar "u"))) (EBinOp "-" (ELit (LInt 16)) (EVar "bs"))))) (ELit (LInt 65535))))
(DTypeSig true "shr" (TyFun (TyCon "Int") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "shr" ((PVar "n") (PVar "u")) (EBlock (DoLet false false (PVar "ws") (EApp (EVar "shiftWords") (EVar "n"))) (DoLet false false (PVar "bs") (EBinOp "-" (EVar "n") (EBinOp "*" (EVar "ws") (ELit (LInt 16))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 3)))))))
(DTypeSig false "shlLimb" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "shlLimb" ((PVar "u") (PVar "ws") (PVar "bs") (PVar "i")) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "limbAt") (EBinOp "-" (EVar "i") (EVar "ws"))) (EVar "u"))) (EVar "bs"))) (EApp (EApp (EVar "shiftRight") (EApp (EApp (EVar "limbAt") (EBinOp "-" (EBinOp "-" (EVar "i") (EVar "ws")) (ELit (LInt 1)))) (EVar "u"))) (EBinOp "-" (ELit (LInt 16)) (EVar "bs"))))) (ELit (LInt 65535))))
(DTypeSig true "shl" (TyFun (TyCon "Int") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "shl" ((PVar "n") (PVar "u")) (EBlock (DoLet false false (PVar "ws") (EApp (EVar "shiftWords") (EVar "n"))) (DoLet false false (PVar "bs") (EBinOp "-" (EVar "n") (EBinOp "*" (EVar "ws") (ELit (LInt 16))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 3)))))))
(DTypeSig false "bitAt" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "bitAt" ((PVar "u") (PVar "i")) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "limbAt") (ELit (LInt 0))) (EApp (EApp (EVar "shr") (EVar "i")) (EVar "u")))) (ELit (LInt 1))))
(DTypeSig false "modGo" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "U64"))))))
(DFunDef false "modGo" ((PVar "dividend") (PVar "divisor") (PVar "rem") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "rem") (EBlock (DoLet false false (PVar "shifted") (EApp (EApp (EVar "add") (EVar "rem")) (EVar "rem"))) (DoLet false false (PVar "bit") (EApp (EApp (EVar "bitAt") (EVar "dividend")) (EVar "i"))) (DoLet false false (PVar "rem2") (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "limbAt") (ELit (LInt 0))) (EVar "shifted"))) (EVar "bit"))) (EApp (EApp (EVar "limbAt") (ELit (LInt 1))) (EVar "shifted"))) (EApp (EApp (EVar "limbAt") (ELit (LInt 2))) (EVar "shifted"))) (EApp (EApp (EVar "limbAt") (ELit (LInt 3))) (EVar "shifted")))) (DoLet false false (PVar "rem3") (EMatch (EApp (EApp (EVar "cmp") (EVar "rem2")) (EVar "divisor")) (arm (PCon "Lt") () (EVar "rem2")) (arm PWild () (EApp (EApp (EVar "sub") (EVar "rem2")) (EVar "divisor"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "modGo") (EVar "dividend")) (EVar "divisor")) (EVar "rem3")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig true "mod" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "mod" ((PVar "dividend") (PVar "divisor")) (EIf (EApp (EVar "isZero") (EVar "divisor")) (EVar "dividend") (EApp (EApp (EApp (EApp (EVar "modGo") (EVar "dividend")) (EVar "divisor")) (EVar "zero")) (ELit (LInt 63)))))
# MARK
(DUse false (UseGroup ("core") ((mem "Ordering" false))))
(DData Public "U64" () ((variant "U64" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "U64")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "U64" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) (PCon "U64" (PVar "__b0") (PVar "__b1") (PVar "__b2") (PVar "__b3"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "U64")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "U64" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "U64 ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a3")))))))))
(DImpl true "Display" ((TyCon "U64")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "U64" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "U64 ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a2")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a3")))))))))
(DImpl true "Hashable" ((TyCon "U64")) () ((im "hash" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "U64" (PVar "__a0") (PVar "__a1") (PVar "__a2") (PVar "__a3")) () (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (ELit (LInt 0)) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "__a0"))) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "__a1"))) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "__a2"))) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "__a3"))))))))
(DTypeSig true "zero" (TyCon "U64"))
(DFunDef false "zero" () (EApp (EApp (EApp (EApp (EVar "U64") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig true "one" (TyCon "U64"))
(DFunDef false "one" () (EApp (EApp (EApp (EApp (EVar "U64") (ELit (LInt 1))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig true "fromIntBits" (TyFun (TyCon "Int") (TyCon "U64")))
(DFunDef false "fromIntBits" ((PVar "n")) (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitAnd") (EVar "n")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 16)))) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 32)))) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 48)))) (ELit (LInt 65535)))))
(DTypeSig true "isZero" (TyFun (TyCon "U64") (TyCon "Bool")))
(DFunDef false "isZero" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "a0") (ELit (LInt 0))) (EBinOp "==" (EVar "a1") (ELit (LInt 0)))) (EBinOp "==" (EVar "a2") (ELit (LInt 0)))) (EBinOp "==" (EVar "a3") (ELit (LInt 0)))))
(DTypeSig true "cmp" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "Ordering"))))
(DFunDef false "cmp" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EIf (EBinOp "/=" (EVar "a3") (EVar "b3")) (EIf (EBinOp ">" (EVar "a3") (EVar "b3")) (EVar "Gt") (EVar "Lt")) (EIf (EBinOp "/=" (EVar "a2") (EVar "b2")) (EIf (EBinOp ">" (EVar "a2") (EVar "b2")) (EVar "Gt") (EVar "Lt")) (EIf (EBinOp "/=" (EVar "a1") (EVar "b1")) (EIf (EBinOp ">" (EVar "a1") (EVar "b1")) (EVar "Gt") (EVar "Lt")) (EIf (EBinOp "/=" (EVar "a0") (EVar "b0")) (EIf (EBinOp ">" (EVar "a0") (EVar "b0")) (EVar "Gt") (EVar "Lt")) (EVar "Eq"))))))
(DImpl true "Ord" ((TyCon "U64")) () ((im "compare" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "cmp") (EVar "a")) (EVar "b")))))
(DTypeSig true "add#shadow" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "add#shadow" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EBlock (DoLet false false (PVar "s0") (EBinOp "+" (EVar "a0") (EVar "b0"))) (DoLet false false (PVar "s1") (EBinOp "+" (EBinOp "+" (EVar "a1") (EVar "b1")) (EApp (EApp (EVar "shiftRight") (EVar "s0")) (ELit (LInt 16))))) (DoLet false false (PVar "s2") (EBinOp "+" (EBinOp "+" (EVar "a2") (EVar "b2")) (EApp (EApp (EVar "shiftRight") (EVar "s1")) (ELit (LInt 16))))) (DoLet false false (PVar "s3") (EBinOp "+" (EBinOp "+" (EVar "a3") (EVar "b3")) (EApp (EApp (EVar "shiftRight") (EVar "s2")) (ELit (LInt 16))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitAnd") (EVar "s0")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "s1")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "s2")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "s3")) (ELit (LInt 65535)))))))
(DTypeSig true "sub#shadow" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "sub#shadow" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EBlock (DoLet false false (PVar "d0") (EBinOp "-" (EVar "a0") (EVar "b0"))) (DoLet false false (PVar "d1") (EBinOp "-" (EBinOp "-" (EVar "a1") (EVar "b1")) (EIf (EBinOp "<" (EVar "d0") (ELit (LInt 0))) (ELit (LInt 1)) (ELit (LInt 0))))) (DoLet false false (PVar "d2") (EBinOp "-" (EBinOp "-" (EVar "a2") (EVar "b2")) (EIf (EBinOp "<" (EVar "d1") (ELit (LInt 0))) (ELit (LInt 1)) (ELit (LInt 0))))) (DoLet false false (PVar "d3") (EBinOp "-" (EBinOp "-" (EVar "a3") (EVar "b3")) (EIf (EBinOp "<" (EVar "d2") (ELit (LInt 0))) (ELit (LInt 1)) (ELit (LInt 0))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitAnd") (EVar "d0")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "d1")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "d2")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "d3")) (ELit (LInt 65535)))))))
(DTypeSig true "mulLow" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "mulLow" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EBlock (DoLet false false (PVar "c0") (EBinOp "*" (EVar "a0") (EVar "b0"))) (DoLet false false (PVar "c1") (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "a0") (EVar "b1")) (EBinOp "*" (EVar "a1") (EVar "b0"))) (EApp (EApp (EVar "shiftRight") (EVar "c0")) (ELit (LInt 16))))) (DoLet false false (PVar "c2") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "a0") (EVar "b2")) (EBinOp "*" (EVar "a1") (EVar "b1"))) (EBinOp "*" (EVar "a2") (EVar "b0"))) (EApp (EApp (EVar "shiftRight") (EVar "c1")) (ELit (LInt 16))))) (DoLet false false (PVar "c3") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EVar "a0") (EVar "b3")) (EBinOp "*" (EVar "a1") (EVar "b2"))) (EBinOp "*" (EVar "a2") (EVar "b1"))) (EBinOp "*" (EVar "a3") (EVar "b0"))) (EApp (EApp (EVar "shiftRight") (EVar "c2")) (ELit (LInt 16))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitAnd") (EVar "c0")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "c1")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "c2")) (ELit (LInt 65535)))) (EApp (EApp (EVar "bitAnd") (EVar "c3")) (ELit (LInt 65535)))))))
(DTypeSig true "and" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "and" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitAnd") (EVar "a0")) (EVar "b0"))) (EApp (EApp (EVar "bitAnd") (EVar "a1")) (EVar "b1"))) (EApp (EApp (EVar "bitAnd") (EVar "a2")) (EVar "b2"))) (EApp (EApp (EVar "bitAnd") (EVar "a3")) (EVar "b3"))))
(DTypeSig true "or" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "or" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitOr") (EVar "a0")) (EVar "b0"))) (EApp (EApp (EVar "bitOr") (EVar "a1")) (EVar "b1"))) (EApp (EApp (EVar "bitOr") (EVar "a2")) (EVar "b2"))) (EApp (EApp (EVar "bitOr") (EVar "a3")) (EVar "b3"))))
(DTypeSig true "xor" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "xor" ((PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3")) (PCon "U64" (PVar "b0") (PVar "b1") (PVar "b2") (PVar "b3"))) (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitXor") (EVar "a0")) (EVar "b0"))) (EApp (EApp (EVar "bitXor") (EVar "a1")) (EVar "b1"))) (EApp (EApp (EVar "bitXor") (EVar "a2")) (EVar "b2"))) (EApp (EApp (EVar "bitXor") (EVar "a3")) (EVar "b3"))))
(DTypeSig true "limbAt" (TyFun (TyCon "Int") (TyFun (TyCon "U64") (TyCon "Int"))))
(DFunDef false "limbAt" ((PVar "i") (PCon "U64" (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EVar "a0") (EIf (EBinOp "==" (EVar "i") (ELit (LInt 1))) (EVar "a1") (EIf (EBinOp "==" (EVar "i") (ELit (LInt 2))) (EVar "a2") (EIf (EBinOp "==" (EVar "i") (ELit (LInt 3))) (EVar "a3") (ELit (LInt 0)))))))
(DTypeSig false "shiftWords" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "shiftWords" ((PVar "n")) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (ELit (LInt 3)) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 32))) (ELit (LInt 2)) (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 16))) (ELit (LInt 1)) (ELit (LInt 0))))))
(DTypeSig false "shrLimb" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "shrLimb" ((PVar "u") (PVar "ws") (PVar "bs") (PVar "i")) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftRight") (EApp (EApp (EVar "limbAt") (EBinOp "+" (EVar "i") (EVar "ws"))) (EVar "u"))) (EVar "bs"))) (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "limbAt") (EBinOp "+" (EBinOp "+" (EVar "i") (EVar "ws")) (ELit (LInt 1)))) (EVar "u"))) (EBinOp "-" (ELit (LInt 16)) (EVar "bs"))))) (ELit (LInt 65535))))
(DTypeSig true "shr" (TyFun (TyCon "Int") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "shr" ((PVar "n") (PVar "u")) (EBlock (DoLet false false (PVar "ws") (EApp (EVar "shiftWords") (EVar "n"))) (DoLet false false (PVar "bs") (EBinOp "-" (EVar "n") (EBinOp "*" (EVar "ws") (ELit (LInt 16))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EVar "shrLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 3)))))))
(DTypeSig false "shlLimb" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "shlLimb" ((PVar "u") (PVar "ws") (PVar "bs") (PVar "i")) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "limbAt") (EBinOp "-" (EVar "i") (EVar "ws"))) (EVar "u"))) (EVar "bs"))) (EApp (EApp (EVar "shiftRight") (EApp (EApp (EVar "limbAt") (EBinOp "-" (EBinOp "-" (EVar "i") (EVar "ws")) (ELit (LInt 1)))) (EVar "u"))) (EBinOp "-" (ELit (LInt 16)) (EVar "bs"))))) (ELit (LInt 65535))))
(DTypeSig true "shl" (TyFun (TyCon "Int") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "shl" ((PVar "n") (PVar "u")) (EBlock (DoLet false false (PVar "ws") (EApp (EVar "shiftWords") (EVar "n"))) (DoLet false false (PVar "bs") (EBinOp "-" (EVar "n") (EBinOp "*" (EVar "ws") (ELit (LInt 16))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 2)))) (EApp (EApp (EApp (EApp (EVar "shlLimb") (EVar "u")) (EVar "ws")) (EVar "bs")) (ELit (LInt 3)))))))
(DTypeSig false "bitAt" (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "bitAt" ((PVar "u") (PVar "i")) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "limbAt") (ELit (LInt 0))) (EApp (EApp (EVar "shr") (EVar "i")) (EVar "u")))) (ELit (LInt 1))))
(DTypeSig false "modGo" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyFun (TyCon "Int") (TyCon "U64"))))))
(DFunDef false "modGo" ((PVar "dividend") (PVar "divisor") (PVar "rem") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "rem") (EBlock (DoLet false false (PVar "shifted") (EApp (EApp (EVar "add#shadow") (EVar "rem")) (EVar "rem"))) (DoLet false false (PVar "bit") (EApp (EApp (EVar "bitAt") (EVar "dividend")) (EVar "i"))) (DoLet false false (PVar "rem2") (EApp (EApp (EApp (EApp (EVar "U64") (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "limbAt") (ELit (LInt 0))) (EVar "shifted"))) (EVar "bit"))) (EApp (EApp (EVar "limbAt") (ELit (LInt 1))) (EVar "shifted"))) (EApp (EApp (EVar "limbAt") (ELit (LInt 2))) (EVar "shifted"))) (EApp (EApp (EVar "limbAt") (ELit (LInt 3))) (EVar "shifted")))) (DoLet false false (PVar "rem3") (EMatch (EApp (EApp (EVar "cmp") (EVar "rem2")) (EVar "divisor")) (arm (PCon "Lt") () (EVar "rem2")) (arm PWild () (EApp (EApp (EVar "sub#shadow") (EVar "rem2")) (EVar "divisor"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "modGo") (EVar "dividend")) (EVar "divisor")) (EVar "rem3")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig true "mod" (TyFun (TyCon "U64") (TyFun (TyCon "U64") (TyCon "U64"))))
(DFunDef false "mod" ((PVar "dividend") (PVar "divisor")) (EIf (EApp (EVar "isZero") (EVar "divisor")) (EVar "dividend") (EApp (EApp (EApp (EApp (EVar "modGo") (EVar "dividend")) (EVar "divisor")) (EVar "zero")) (ELit (LInt 63)))))
