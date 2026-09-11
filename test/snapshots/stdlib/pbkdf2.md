# META
source_lines=85
stages=DESUGAR,MARK
# SOURCE
{- | PBKDF2-HMAC-SHA-256 (RFC 2898 §5.2), the password-hashing key
   derivation function.

   A password, a salt and the derived key are each an `Array Int` with every
   element from `0` to `255`. The caller supplies the salt; nothing here
   draws entropy, reads a clock, or performs any I/O. -}

import array.{blit, concat, copy, make, setInPlace}
import hmac.{hmacSha256}

hashBytes : Int
hashBytes = 32

-- Big-endian 4-byte encoding of the PBKDF2 block index (RFC 2898 §5.2,
-- `INT (i)`).
int32Be : Int -> Array Int
int32Be n = [|
  bitAnd (shiftRight n 24) 255,
  bitAnd (shiftRight n 16) 255,
  bitAnd (shiftRight n 8) 255,
  bitAnd n 255,
|]

xorInto : Array Int -> Array Int -> Int -> Unit
xorInto acc u i =
  if i >= arrayLength acc then
    ()
  else
    let () = setInPlace i (bitXor acc[i] u[i]) acc
    xorInto acc u (i + 1)

-- Folds U_2 .. U_iterations into `acc` (already seeded with U_1), each
-- `Uj = HMAC(P, U_{j-1})`, XORing every one in (RFC 2898 §5.2 `F`).
foldU : Array Int -> Int -> Array Int -> Array Int -> Int -> Array Int
foldU password iterations acc prevU j =
  if j >= iterations then
    acc
  else
    let u = hmacSha256 password prevU
    let () = xorInto acc u 0
    foldU password iterations acc u (j + 1)

-- One 32-byte PBKDF2 block `T_blockIndex` (RFC 2898 §5.2 `F(P, S, c, i)`).
pbkdf2Block : Array Int -> Array Int -> Int -> Int -> Array Int
pbkdf2Block password salt iterations blockIndex =
  let u1 = hmacSha256 password (concat [|salt, int32Be blockIndex|])
  let acc = copy u1
  foldU password iterations acc u1 1

buildBlocks : Array Int ->
  Array Int ->
  Int ->
  Int ->
  Int ->
  Array Int ->
  Int ->
  Array Int
buildBlocks password salt iterations dkLen total out blockIndex =
  if blockIndex > total then
    out
  else
    let block = pbkdf2Block password salt iterations blockIndex
    let offset = (blockIndex - 1) * hashBytes
    let remaining = dkLen - offset
    let take = min remaining hashBytes
    let () = blit block 0 out offset take
    buildBlocks password salt iterations dkLen total out (blockIndex + 1)

{- | The `dkLen`-byte key derived from `password` and `salt` by RFC 2898's
   PBKDF2 with HMAC-SHA-256.

   `salt` is caller-supplied; this function never draws entropy itself.
   Panics when `iterations` or `dkLen` is less than 1, and when any element
   of `password` or `salt` is outside `0` to `255`. -}
export
pbkdf2HmacSha256 : Array Int -> Array Int -> Int -> Int -> Array Int
pbkdf2HmacSha256 password salt iterations dkLen =
  if iterations < 1 then
    panic "pbkdf2: iterations must be >= 1"
  else if dkLen < 1 then
    panic "pbkdf2: dkLen must be >= 1"
  else
    let total = (dkLen + hashBytes - 1) / hashBytes
    let out = make dkLen 0
    buildBlocks password salt iterations dkLen total out 1
# DESUGAR
(DUse false (UseGroup ("array") ((mem "blit" false) (mem "concat" false) (mem "copy" false) (mem "make" false) (mem "setInPlace" false))))
(DUse false (UseGroup ("hmac") ((mem "hmacSha256" false))))
(DTypeSig false "hashBytes" (TyCon "Int"))
(DFunDef false "hashBytes" () (ELit (LInt 32)))
(DTypeSig false "int32Be" (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "int32Be" ((PVar "n")) (EArrayLit (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 24)))) (ELit (LInt 255))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 16)))) (ELit (LInt 255))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 8)))) (ELit (LInt 255))) (EApp (EApp (EVar "bitAnd") (EVar "n")) (ELit (LInt 255)))))
(DTypeSig false "xorInto" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "xorInto" ((PVar "acc") (PVar "u") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "acc"))) (ELit LUnit) (EBlock (DoLet false false (PLit LUnit) (EApp (EApp (EApp (EVar "setInPlace") (EVar "i")) (EApp (EApp (EVar "bitXor") (EApp (EApp (EVar "index") (EVar "acc")) (EVar "i"))) (EApp (EApp (EVar "index") (EVar "u")) (EVar "i")))) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EVar "xorInto") (EVar "acc")) (EVar "u")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "foldU" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "foldU" ((PVar "password") (PVar "iterations") (PVar "acc") (PVar "prevU") (PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EVar "iterations")) (EVar "acc") (EBlock (DoLet false false (PVar "u") (EApp (EApp (EVar "hmacSha256") (EVar "password")) (EVar "prevU"))) (DoLet false false (PLit LUnit) (EApp (EApp (EApp (EVar "xorInto") (EVar "acc")) (EVar "u")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "foldU") (EVar "password")) (EVar "iterations")) (EVar "acc")) (EVar "u")) (EBinOp "+" (EVar "j") (ELit (LInt 1))))))))
(DTypeSig false "pbkdf2Block" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "pbkdf2Block" ((PVar "password") (PVar "salt") (PVar "iterations") (PVar "blockIndex")) (EBlock (DoLet false false (PVar "u1") (EApp (EApp (EVar "hmacSha256") (EVar "password")) (EApp (EVar "concat") (EArrayLit (EVar "salt") (EApp (EVar "int32Be") (EVar "blockIndex")))))) (DoLet false false (PVar "acc") (EApp (EVar "copy") (EVar "u1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "foldU") (EVar "password")) (EVar "iterations")) (EVar "acc")) (EVar "u1")) (ELit (LInt 1))))))
(DTypeSig false "buildBlocks" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int"))))))))))
(DFunDef false "buildBlocks" ((PVar "password") (PVar "salt") (PVar "iterations") (PVar "dkLen") (PVar "total") (PVar "out") (PVar "blockIndex")) (EIf (EBinOp ">" (EVar "blockIndex") (EVar "total")) (EVar "out") (EBlock (DoLet false false (PVar "block") (EApp (EApp (EApp (EApp (EVar "pbkdf2Block") (EVar "password")) (EVar "salt")) (EVar "iterations")) (EVar "blockIndex"))) (DoLet false false (PVar "offset") (EBinOp "*" (EBinOp "-" (EVar "blockIndex") (ELit (LInt 1))) (EVar "hashBytes"))) (DoLet false false (PVar "remaining") (EBinOp "-" (EVar "dkLen") (EVar "offset"))) (DoLet false false (PVar "take") (EApp (EApp (EVar "min") (EVar "remaining")) (EVar "hashBytes"))) (DoLet false false (PLit LUnit) (EApp (EApp (EApp (EApp (EApp (EVar "blit") (EVar "block")) (ELit (LInt 0))) (EVar "out")) (EVar "offset")) (EVar "take"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildBlocks") (EVar "password")) (EVar "salt")) (EVar "iterations")) (EVar "dkLen")) (EVar "total")) (EVar "out")) (EBinOp "+" (EVar "blockIndex") (ELit (LInt 1))))))))
(DTypeSig true "pbkdf2HmacSha256" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "pbkdf2HmacSha256" ((PVar "password") (PVar "salt") (PVar "iterations") (PVar "dkLen")) (EIf (EBinOp "<" (EVar "iterations") (ELit (LInt 1))) (EApp (EVar "panic") (ELit (LString "pbkdf2: iterations must be >= 1"))) (EIf (EBinOp "<" (EVar "dkLen") (ELit (LInt 1))) (EApp (EVar "panic") (ELit (LString "pbkdf2: dkLen must be >= 1"))) (EBlock (DoLet false false (PVar "total") (EBinOp "/" (EBinOp "-" (EBinOp "+" (EVar "dkLen") (EVar "hashBytes")) (ELit (LInt 1))) (EVar "hashBytes"))) (DoLet false false (PVar "out") (EApp (EApp (EVar "make") (EVar "dkLen")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildBlocks") (EVar "password")) (EVar "salt")) (EVar "iterations")) (EVar "dkLen")) (EVar "total")) (EVar "out")) (ELit (LInt 1))))))))
# MARK
(DUse false (UseGroup ("array") ((mem "blit" false) (mem "concat" false) (mem "copy" false) (mem "make" false) (mem "setInPlace" false))))
(DUse false (UseGroup ("hmac") ((mem "hmacSha256" false))))
(DTypeSig false "hashBytes" (TyCon "Int"))
(DFunDef false "hashBytes" () (ELit (LInt 32)))
(DTypeSig false "int32Be" (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "int32Be" ((PVar "n")) (EArrayLit (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 24)))) (ELit (LInt 255))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 16)))) (ELit (LInt 255))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 8)))) (ELit (LInt 255))) (EApp (EApp (EVar "bitAnd") (EVar "n")) (ELit (LInt 255)))))
(DTypeSig false "xorInto" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "xorInto" ((PVar "acc") (PVar "u") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "acc"))) (ELit LUnit) (EBlock (DoLet false false (PLit LUnit) (EApp (EApp (EApp (EVar "setInPlace") (EVar "i")) (EApp (EApp (EVar "bitXor") (EApp (EApp (EMethodRef "index") (EVar "acc")) (EVar "i"))) (EApp (EApp (EMethodRef "index") (EVar "u")) (EVar "i")))) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EVar "xorInto") (EVar "acc")) (EVar "u")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "foldU" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "foldU" ((PVar "password") (PVar "iterations") (PVar "acc") (PVar "prevU") (PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EVar "iterations")) (EVar "acc") (EBlock (DoLet false false (PVar "u") (EApp (EApp (EVar "hmacSha256") (EVar "password")) (EVar "prevU"))) (DoLet false false (PLit LUnit) (EApp (EApp (EApp (EVar "xorInto") (EVar "acc")) (EVar "u")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "foldU") (EVar "password")) (EVar "iterations")) (EVar "acc")) (EVar "u")) (EBinOp "+" (EVar "j") (ELit (LInt 1))))))))
(DTypeSig false "pbkdf2Block" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "pbkdf2Block" ((PVar "password") (PVar "salt") (PVar "iterations") (PVar "blockIndex")) (EBlock (DoLet false false (PVar "u1") (EApp (EApp (EVar "hmacSha256") (EVar "password")) (EApp (EVar "concat") (EArrayLit (EVar "salt") (EApp (EVar "int32Be") (EVar "blockIndex")))))) (DoLet false false (PVar "acc") (EApp (EVar "copy") (EVar "u1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "foldU") (EVar "password")) (EVar "iterations")) (EVar "acc")) (EVar "u1")) (ELit (LInt 1))))))
(DTypeSig false "buildBlocks" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int"))))))))))
(DFunDef false "buildBlocks" ((PVar "password") (PVar "salt") (PVar "iterations") (PVar "dkLen") (PVar "total") (PVar "out") (PVar "blockIndex")) (EIf (EBinOp ">" (EVar "blockIndex") (EVar "total")) (EVar "out") (EBlock (DoLet false false (PVar "block") (EApp (EApp (EApp (EApp (EVar "pbkdf2Block") (EVar "password")) (EVar "salt")) (EVar "iterations")) (EVar "blockIndex"))) (DoLet false false (PVar "offset") (EBinOp "*" (EBinOp "-" (EVar "blockIndex") (ELit (LInt 1))) (EVar "hashBytes"))) (DoLet false false (PVar "remaining") (EBinOp "-" (EVar "dkLen") (EVar "offset"))) (DoLet false false (PVar "take") (EApp (EApp (EMethodRef "min") (EVar "remaining")) (EVar "hashBytes"))) (DoLet false false (PLit LUnit) (EApp (EApp (EApp (EApp (EApp (EVar "blit") (EVar "block")) (ELit (LInt 0))) (EVar "out")) (EVar "offset")) (EVar "take"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildBlocks") (EVar "password")) (EVar "salt")) (EVar "iterations")) (EVar "dkLen")) (EVar "total")) (EVar "out")) (EBinOp "+" (EVar "blockIndex") (ELit (LInt 1))))))))
(DTypeSig true "pbkdf2HmacSha256" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "pbkdf2HmacSha256" ((PVar "password") (PVar "salt") (PVar "iterations") (PVar "dkLen")) (EIf (EBinOp "<" (EVar "iterations") (ELit (LInt 1))) (EApp (EVar "panic") (ELit (LString "pbkdf2: iterations must be >= 1"))) (EIf (EBinOp "<" (EVar "dkLen") (ELit (LInt 1))) (EApp (EVar "panic") (ELit (LString "pbkdf2: dkLen must be >= 1"))) (EBlock (DoLet false false (PVar "total") (EBinOp "/" (EBinOp "-" (EBinOp "+" (EVar "dkLen") (EVar "hashBytes")) (ELit (LInt 1))) (EVar "hashBytes"))) (DoLet false false (PVar "out") (EApp (EApp (EVar "make") (EVar "dkLen")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildBlocks") (EVar "password")) (EVar "salt")) (EVar "iterations")) (EVar "dkLen")) (EVar "total")) (EVar "out")) (ELit (LInt 1))))))))
