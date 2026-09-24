# META
source_lines=97
stages=DESUGAR,MARK
# SOURCE
{- | PBKDF2 key derivation with HMAC-SHA-256 (RFC 2898).

   A password, a salt and the derived key are each an `Array Int` with every
   element from `0` to `255`. The caller supplies the salt. Nothing here
   draws entropy or performs any I/O. -}

import array.{blit, concat, copy, make, setInPlace}
import bytes.{fromArray, fromArrayAssumeByteDomain, toArray}
import hmac.{HmacSha256Key, hmacSha256Key, hmacSha256WithKey}

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
-- `Uj = HMAC(P, U_{j-1})`, XORing every one in (RFC 2898 §5.2 `F`). `key`
-- is `password`'s `HmacSha256Key`, built once by the caller so every
-- iteration reuses the same precomputed ipad/opad compressions.
foldU : HmacSha256Key -> Int -> Array Int -> Array Int -> Int -> Array Int
foldU key iterations acc prevU j =
  if j >= iterations then
    acc
  else
    let u = toArray (hmacSha256WithKey key (fromArrayAssumeByteDomain prevU))
    let () = xorInto acc u 0
    foldU key iterations acc u (j + 1)

-- One 32-byte PBKDF2 block `T_blockIndex` (RFC 2898 §5.2 `F(P, S, c, i)`),
-- under the same `key` `foldU` reuses for every iteration.
pbkdf2Block : HmacSha256Key -> Array Int -> Int -> Int -> Array Int
pbkdf2Block key salt iterations blockIndex =
  let msg = fromArrayAssumeByteDomain (concat [|salt, int32Be blockIndex|])
  let u1 = toArray (hmacSha256WithKey key msg)
  let acc = copy u1
  foldU key iterations acc u1 1

buildBlocks : HmacSha256Key ->
  Array Int ->
  Int ->
  Int ->
  Int ->
  Array Int ->
  Int ->
  Array Int
buildBlocks key salt iterations dkLen total out blockIndex =
  if blockIndex > total then
    out
  else
    let block = pbkdf2Block key salt iterations blockIndex
    let offset = (blockIndex - 1) * hashBytes
    let remaining = dkLen - offset
    let take = min remaining hashBytes
    let () = blit block 0 out offset take
    buildBlocks key salt iterations dkLen total out (blockIndex + 1)

{- | The `dkLen`-byte key derived from `password` and `salt` over
   `iterations` rounds.

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
    let passwordBytes =
      optionOrPanic
        "pbkdf2: every element of password must be a byte in 0..255"
        (fromArray password)
    let _ =
      optionOrPanic
        "pbkdf2: every element of salt must be a byte in 0..255"
        (fromArray salt)
    let key = hmacSha256Key passwordBytes
    let total = (dkLen + hashBytes - 1) / hashBytes
    let out = make dkLen 0
    buildBlocks key salt iterations dkLen total out 1
# DESUGAR
(DUse false (UseGroup ("array") ((mem "blit" false) (mem "concat" false) (mem "copy" false) (mem "make" false) (mem "setInPlace" false))))
(DUse false (UseGroup ("bytes") ((mem "fromArray" false) (mem "fromArrayAssumeByteDomain" false) (mem "toArray" false))))
(DUse false (UseGroup ("hmac") ((mem "HmacSha256Key" false) (mem "hmacSha256Key" false) (mem "hmacSha256WithKey" false))))
(DTypeSig false "hashBytes" (TyCon "Int"))
(DFunDef false "hashBytes" () (ELit (LInt 32)))
(DTypeSig false "int32Be" (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "int32Be" ((PVar "n")) (EArrayLit (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 24)))) (ELit (LInt 255))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 16)))) (ELit (LInt 255))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 8)))) (ELit (LInt 255))) (EApp (EApp (EVar "bitAnd") (EVar "n")) (ELit (LInt 255)))))
(DTypeSig false "xorInto" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "xorInto" ((PVar "acc") (PVar "u") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "acc"))) (ELit LUnit) (EBlock (DoLet false false (PLit LUnit) (EApp (EApp (EApp (EVar "setInPlace") (EVar "i")) (EApp (EApp (EVar "bitXor") (EApp (EApp (EVar "index") (EVar "acc")) (EVar "i"))) (EApp (EApp (EVar "index") (EVar "u")) (EVar "i")))) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EVar "xorInto") (EVar "acc")) (EVar "u")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "foldU" (TyFun (TyCon "HmacSha256Key") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "foldU" ((PVar "key") (PVar "iterations") (PVar "acc") (PVar "prevU") (PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EVar "iterations")) (EVar "acc") (EBlock (DoLet false false (PVar "u") (EApp (EVar "toArray") (EApp (EApp (EVar "hmacSha256WithKey") (EVar "key")) (EApp (EVar "fromArrayAssumeByteDomain") (EVar "prevU"))))) (DoLet false false (PLit LUnit) (EApp (EApp (EApp (EVar "xorInto") (EVar "acc")) (EVar "u")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "foldU") (EVar "key")) (EVar "iterations")) (EVar "acc")) (EVar "u")) (EBinOp "+" (EVar "j") (ELit (LInt 1))))))))
(DTypeSig false "pbkdf2Block" (TyFun (TyCon "HmacSha256Key") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "pbkdf2Block" ((PVar "key") (PVar "salt") (PVar "iterations") (PVar "blockIndex")) (EBlock (DoLet false false (PVar "msg") (EApp (EVar "fromArrayAssumeByteDomain") (EApp (EVar "concat") (EArrayLit (EVar "salt") (EApp (EVar "int32Be") (EVar "blockIndex")))))) (DoLet false false (PVar "u1") (EApp (EVar "toArray") (EApp (EApp (EVar "hmacSha256WithKey") (EVar "key")) (EVar "msg")))) (DoLet false false (PVar "acc") (EApp (EVar "copy") (EVar "u1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "foldU") (EVar "key")) (EVar "iterations")) (EVar "acc")) (EVar "u1")) (ELit (LInt 1))))))
(DTypeSig false "buildBlocks" (TyFun (TyCon "HmacSha256Key") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int"))))))))))
(DFunDef false "buildBlocks" ((PVar "key") (PVar "salt") (PVar "iterations") (PVar "dkLen") (PVar "total") (PVar "out") (PVar "blockIndex")) (EIf (EBinOp ">" (EVar "blockIndex") (EVar "total")) (EVar "out") (EBlock (DoLet false false (PVar "block") (EApp (EApp (EApp (EApp (EVar "pbkdf2Block") (EVar "key")) (EVar "salt")) (EVar "iterations")) (EVar "blockIndex"))) (DoLet false false (PVar "offset") (EBinOp "*" (EBinOp "-" (EVar "blockIndex") (ELit (LInt 1))) (EVar "hashBytes"))) (DoLet false false (PVar "remaining") (EBinOp "-" (EVar "dkLen") (EVar "offset"))) (DoLet false false (PVar "take") (EApp (EApp (EVar "min") (EVar "remaining")) (EVar "hashBytes"))) (DoLet false false (PLit LUnit) (EApp (EApp (EApp (EApp (EApp (EVar "blit") (EVar "block")) (ELit (LInt 0))) (EVar "out")) (EVar "offset")) (EVar "take"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildBlocks") (EVar "key")) (EVar "salt")) (EVar "iterations")) (EVar "dkLen")) (EVar "total")) (EVar "out")) (EBinOp "+" (EVar "blockIndex") (ELit (LInt 1))))))))
(DTypeSig true "pbkdf2HmacSha256" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "pbkdf2HmacSha256" ((PVar "password") (PVar "salt") (PVar "iterations") (PVar "dkLen")) (EIf (EBinOp "<" (EVar "iterations") (ELit (LInt 1))) (EApp (EVar "panic") (ELit (LString "pbkdf2: iterations must be >= 1"))) (EIf (EBinOp "<" (EVar "dkLen") (ELit (LInt 1))) (EApp (EVar "panic") (ELit (LString "pbkdf2: dkLen must be >= 1"))) (EBlock (DoLet false false (PVar "passwordBytes") (EApp (EApp (EVar "optionOrPanic") (ELit (LString "pbkdf2: every element of password must be a byte in 0..255"))) (EApp (EVar "fromArray") (EVar "password")))) (DoLet false false PWild (EApp (EApp (EVar "optionOrPanic") (ELit (LString "pbkdf2: every element of salt must be a byte in 0..255"))) (EApp (EVar "fromArray") (EVar "salt")))) (DoLet false false (PVar "key") (EApp (EVar "hmacSha256Key") (EVar "passwordBytes"))) (DoLet false false (PVar "total") (EBinOp "/" (EBinOp "-" (EBinOp "+" (EVar "dkLen") (EVar "hashBytes")) (ELit (LInt 1))) (EVar "hashBytes"))) (DoLet false false (PVar "out") (EApp (EApp (EVar "make") (EVar "dkLen")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildBlocks") (EVar "key")) (EVar "salt")) (EVar "iterations")) (EVar "dkLen")) (EVar "total")) (EVar "out")) (ELit (LInt 1))))))))
# MARK
(DUse false (UseGroup ("array") ((mem "blit" false) (mem "concat" false) (mem "copy" false) (mem "make" false) (mem "setInPlace" false))))
(DUse false (UseGroup ("bytes") ((mem "fromArray" false) (mem "fromArrayAssumeByteDomain" false) (mem "toArray" false))))
(DUse false (UseGroup ("hmac") ((mem "HmacSha256Key" false) (mem "hmacSha256Key" false) (mem "hmacSha256WithKey" false))))
(DTypeSig false "hashBytes" (TyCon "Int"))
(DFunDef false "hashBytes" () (ELit (LInt 32)))
(DTypeSig false "int32Be" (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "int32Be" ((PVar "n")) (EArrayLit (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 24)))) (ELit (LInt 255))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 16)))) (ELit (LInt 255))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "n")) (ELit (LInt 8)))) (ELit (LInt 255))) (EApp (EApp (EVar "bitAnd") (EVar "n")) (ELit (LInt 255)))))
(DTypeSig false "xorInto" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "xorInto" ((PVar "acc") (PVar "u") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "acc"))) (ELit LUnit) (EBlock (DoLet false false (PLit LUnit) (EApp (EApp (EApp (EVar "setInPlace") (EVar "i")) (EApp (EApp (EVar "bitXor") (EApp (EApp (EMethodRef "index") (EVar "acc")) (EVar "i"))) (EApp (EApp (EMethodRef "index") (EVar "u")) (EVar "i")))) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EVar "xorInto") (EVar "acc")) (EVar "u")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "foldU" (TyFun (TyCon "HmacSha256Key") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int"))))))))
(DFunDef false "foldU" ((PVar "key") (PVar "iterations") (PVar "acc") (PVar "prevU") (PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EVar "iterations")) (EVar "acc") (EBlock (DoLet false false (PVar "u") (EApp (EVar "toArray") (EApp (EApp (EVar "hmacSha256WithKey") (EVar "key")) (EApp (EVar "fromArrayAssumeByteDomain") (EVar "prevU"))))) (DoLet false false (PLit LUnit) (EApp (EApp (EApp (EVar "xorInto") (EVar "acc")) (EVar "u")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "foldU") (EVar "key")) (EVar "iterations")) (EVar "acc")) (EVar "u")) (EBinOp "+" (EVar "j") (ELit (LInt 1))))))))
(DTypeSig false "pbkdf2Block" (TyFun (TyCon "HmacSha256Key") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "pbkdf2Block" ((PVar "key") (PVar "salt") (PVar "iterations") (PVar "blockIndex")) (EBlock (DoLet false false (PVar "msg") (EApp (EVar "fromArrayAssumeByteDomain") (EApp (EVar "concat") (EArrayLit (EVar "salt") (EApp (EVar "int32Be") (EVar "blockIndex")))))) (DoLet false false (PVar "u1") (EApp (EVar "toArray") (EApp (EApp (EVar "hmacSha256WithKey") (EVar "key")) (EVar "msg")))) (DoLet false false (PVar "acc") (EApp (EVar "copy") (EVar "u1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "foldU") (EVar "key")) (EVar "iterations")) (EVar "acc")) (EVar "u1")) (ELit (LInt 1))))))
(DTypeSig false "buildBlocks" (TyFun (TyCon "HmacSha256Key") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int"))))))))))
(DFunDef false "buildBlocks" ((PVar "key") (PVar "salt") (PVar "iterations") (PVar "dkLen") (PVar "total") (PVar "out") (PVar "blockIndex")) (EIf (EBinOp ">" (EVar "blockIndex") (EVar "total")) (EVar "out") (EBlock (DoLet false false (PVar "block") (EApp (EApp (EApp (EApp (EVar "pbkdf2Block") (EVar "key")) (EVar "salt")) (EVar "iterations")) (EVar "blockIndex"))) (DoLet false false (PVar "offset") (EBinOp "*" (EBinOp "-" (EVar "blockIndex") (ELit (LInt 1))) (EVar "hashBytes"))) (DoLet false false (PVar "remaining") (EBinOp "-" (EVar "dkLen") (EVar "offset"))) (DoLet false false (PVar "take") (EApp (EApp (EMethodRef "min") (EVar "remaining")) (EVar "hashBytes"))) (DoLet false false (PLit LUnit) (EApp (EApp (EApp (EApp (EApp (EVar "blit") (EVar "block")) (ELit (LInt 0))) (EVar "out")) (EVar "offset")) (EVar "take"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildBlocks") (EVar "key")) (EVar "salt")) (EVar "iterations")) (EVar "dkLen")) (EVar "total")) (EVar "out")) (EBinOp "+" (EVar "blockIndex") (ELit (LInt 1))))))))
(DTypeSig true "pbkdf2HmacSha256" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "pbkdf2HmacSha256" ((PVar "password") (PVar "salt") (PVar "iterations") (PVar "dkLen")) (EIf (EBinOp "<" (EVar "iterations") (ELit (LInt 1))) (EApp (EVar "panic") (ELit (LString "pbkdf2: iterations must be >= 1"))) (EIf (EBinOp "<" (EVar "dkLen") (ELit (LInt 1))) (EApp (EVar "panic") (ELit (LString "pbkdf2: dkLen must be >= 1"))) (EBlock (DoLet false false (PVar "passwordBytes") (EApp (EApp (EVar "optionOrPanic") (ELit (LString "pbkdf2: every element of password must be a byte in 0..255"))) (EApp (EVar "fromArray") (EVar "password")))) (DoLet false false PWild (EApp (EApp (EVar "optionOrPanic") (ELit (LString "pbkdf2: every element of salt must be a byte in 0..255"))) (EApp (EVar "fromArray") (EVar "salt")))) (DoLet false false (PVar "key") (EApp (EVar "hmacSha256Key") (EVar "passwordBytes"))) (DoLet false false (PVar "total") (EBinOp "/" (EBinOp "-" (EBinOp "+" (EVar "dkLen") (EVar "hashBytes")) (ELit (LInt 1))) (EVar "hashBytes"))) (DoLet false false (PVar "out") (EApp (EApp (EVar "make") (EVar "dkLen")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildBlocks") (EVar "key")) (EVar "salt")) (EVar "iterations")) (EVar "dkLen")) (EVar "total")) (EVar "out")) (ELit (LInt 1))))))))
