# META
source_lines=95
stages=DESUGAR,MARK
# SOURCE
-- Tests for `crypto.sha256.sha256`, which hashes in the runtime, against the
-- FIPS 180-4 vectors and against the Medaka implementation behind
-- `sha256AssumeByteDomainFrom` (the HMAC resume path), which is kept in
-- Medaka. The two are independent implementations, so their agreeing at each
-- padding boundary says something about the runtime's digest.

import array.{makeWith}
import bytes as B
import bytes.{Bytes, encodeUtf8, fromArrayAssumeByteDomain}
import crypto.sha256.{sha256, sha256AssumeByteDomainFrom}
import hex as Hex
import test.{expectEqual}

digestHex : String -> String
digestHex s = Hex.encode (sha256 (encodeUtf8 s))

-- A message of `n` bytes, each a different function of its position.
patterned : Int -> Bytes
patterned n = fromArrayAssumeByteDomain (makeWith n (i => (i * 7 + 3) % 256))

reference : Bytes -> Bytes
reference msg =
  sha256AssumeByteDomainFrom
    (
      0x6a09e667,
      0xbb67ae85,
      0x3c6ef372,
      0xa54ff53a,
      0x510e527f,
      0x9b05688c,
      0x1f83d9ab,
      0x5be0cd19,
    )
    0
    msg

-- The padding boundaries: the last block before the 0x80 marker no longer
-- fits (55 to 56), a full block (63 to 65), and the two-block cases past it.
boundaryLengths : List Int
boundaryLengths = [
  0,
  1,
  54,
  55,
  56,
  57,
  62,
  63,
  64,
  65,
  119,
  120,
  121,
  127,
  128,
  129,
  191,
  200,
]

test "sha256 of the empty message" =
  expectEqual
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    (digestHex "")

test "sha256 of abc" =
  expectEqual
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    (digestHex "abc")

test "sha256 of the 448-bit two-block message" =
  expectEqual
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    (digestHex "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")

test "sha256 of the 896-bit message" =
  expectEqual
    "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
    (digestHex
      "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")

test "sha256 digests are 32 bytes whatever the message" =
  expectEqual
    (map (_ => 32) boundaryLengths)
    (map (n => B.length (sha256 (patterned n))) boundaryLengths)

test "sha256 agrees with the Medaka implementation at every padding boundary" =
  expectEqual
    (map (n => Hex.encode (reference (patterned n))) boundaryLengths)
    (map (n => Hex.encode (sha256 (patterned n))) boundaryLengths)

test "sha256 agrees with the Medaka implementation on a long message" =
  expectEqual
    (Hex.encode (reference (patterned 5000)))
    (Hex.encode (sha256 (patterned 5000)))
# DESUGAR
(DUse false (UseGroup ("array") ((mem "makeWith" false))))
(DUse false (UseAlias ("bytes") "B"))
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "encodeUtf8" false) (mem "fromArrayAssumeByteDomain" false))))
(DUse false (UseGroup ("crypto" "sha256") ((mem "sha256" false) (mem "sha256AssumeByteDomainFrom" false))))
(DUse false (UseAlias ("hex") "Hex"))
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTypeSig false "digestHex" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "digestHex" ((PVar "s")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256") (EApp (EVar "encodeUtf8") (EVar "s")))))
(DTypeSig false "patterned" (TyFun (TyCon "Int") (TyCon "Bytes")))
(DFunDef false "patterned" ((PVar "n")) (EApp (EVar "fromArrayAssumeByteDomain") (EApp (EApp (EVar "makeWith") (EVar "n")) (ELam ((PVar "i")) (EBinOp "%" (EBinOp "+" (EBinOp "*" (EVar "i") (ELit (LInt 7))) (ELit (LInt 3))) (ELit (LInt 256)))))))
(DTypeSig false "reference" (TyFun (TyCon "Bytes") (TyCon "Bytes")))
(DFunDef false "reference" ((PVar "msg")) (EApp (EApp (EApp (EVar "sha256AssumeByteDomainFrom") (ETuple (ELit (LInt 1779033703)) (ELit (LInt 3144134277)) (ELit (LInt 1013904242)) (ELit (LInt 2773480762)) (ELit (LInt 1359893119)) (ELit (LInt 2600822924)) (ELit (LInt 528734635)) (ELit (LInt 1541459225)))) (ELit (LInt 0))) (EVar "msg")))
(DTypeSig false "boundaryLengths" (TyApp (TyCon "List") (TyCon "Int")))
(DFunDef false "boundaryLengths" () (EListLit (ELit (LInt 0)) (ELit (LInt 1)) (ELit (LInt 54)) (ELit (LInt 55)) (ELit (LInt 56)) (ELit (LInt 57)) (ELit (LInt 62)) (ELit (LInt 63)) (ELit (LInt 64)) (ELit (LInt 65)) (ELit (LInt 119)) (ELit (LInt 120)) (ELit (LInt 121)) (ELit (LInt 127)) (ELit (LInt 128)) (ELit (LInt 129)) (ELit (LInt 191)) (ELit (LInt 200))))
(DTest false "sha256 of the empty message" (EApp (EApp (EVar "expectEqual") (ELit (LString "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))) (EApp (EVar "digestHex") (ELit (LString "")))))
(DTest false "sha256 of abc" (EApp (EApp (EVar "expectEqual") (ELit (LString "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))) (EApp (EVar "digestHex") (ELit (LString "abc")))))
(DTest false "sha256 of the 448-bit two-block message" (EApp (EApp (EVar "expectEqual") (ELit (LString "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"))) (EApp (EVar "digestHex") (ELit (LString "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")))))
(DTest false "sha256 of the 896-bit message" (EApp (EApp (EVar "expectEqual") (ELit (LString "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"))) (EApp (EVar "digestHex") (ELit (LString "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")))))
(DTest false "sha256 digests are 32 bytes whatever the message" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "map") (ELam (PWild) (ELit (LInt 32)))) (EVar "boundaryLengths"))) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EVar "B.length") (EApp (EVar "sha256") (EApp (EVar "patterned") (EVar "n")))))) (EVar "boundaryLengths"))))
(DTest false "sha256 agrees with the Medaka implementation at every padding boundary" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EVar "Hex.encode") (EApp (EVar "reference") (EApp (EVar "patterned") (EVar "n")))))) (EVar "boundaryLengths"))) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256") (EApp (EVar "patterned") (EVar "n")))))) (EVar "boundaryLengths"))))
(DTest false "sha256 agrees with the Medaka implementation on a long message" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Hex.encode") (EApp (EVar "reference") (EApp (EVar "patterned") (ELit (LInt 5000)))))) (EApp (EVar "Hex.encode") (EApp (EVar "sha256") (EApp (EVar "patterned") (ELit (LInt 5000)))))))
# MARK
(DUse false (UseGroup ("array") ((mem "makeWith" false))))
(DUse false (UseAlias ("bytes") "B"))
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "encodeUtf8" false) (mem "fromArrayAssumeByteDomain" false))))
(DUse false (UseGroup ("crypto" "sha256") ((mem "sha256" false) (mem "sha256AssumeByteDomainFrom" false))))
(DUse false (UseAlias ("hex") "Hex"))
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTypeSig false "digestHex" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "digestHex" ((PVar "s")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256") (EApp (EVar "encodeUtf8") (EVar "s")))))
(DTypeSig false "patterned" (TyFun (TyCon "Int") (TyCon "Bytes")))
(DFunDef false "patterned" ((PVar "n")) (EApp (EVar "fromArrayAssumeByteDomain") (EApp (EApp (EVar "makeWith") (EVar "n")) (ELam ((PVar "i")) (EBinOp "%" (EBinOp "+" (EBinOp "*" (EVar "i") (ELit (LInt 7))) (ELit (LInt 3))) (ELit (LInt 256)))))))
(DTypeSig false "reference" (TyFun (TyCon "Bytes") (TyCon "Bytes")))
(DFunDef false "reference" ((PVar "msg")) (EApp (EApp (EApp (EVar "sha256AssumeByteDomainFrom") (ETuple (ELit (LInt 1779033703)) (ELit (LInt 3144134277)) (ELit (LInt 1013904242)) (ELit (LInt 2773480762)) (ELit (LInt 1359893119)) (ELit (LInt 2600822924)) (ELit (LInt 528734635)) (ELit (LInt 1541459225)))) (ELit (LInt 0))) (EVar "msg")))
(DTypeSig false "boundaryLengths" (TyApp (TyCon "List") (TyCon "Int")))
(DFunDef false "boundaryLengths" () (EListLit (ELit (LInt 0)) (ELit (LInt 1)) (ELit (LInt 54)) (ELit (LInt 55)) (ELit (LInt 56)) (ELit (LInt 57)) (ELit (LInt 62)) (ELit (LInt 63)) (ELit (LInt 64)) (ELit (LInt 65)) (ELit (LInt 119)) (ELit (LInt 120)) (ELit (LInt 121)) (ELit (LInt 127)) (ELit (LInt 128)) (ELit (LInt 129)) (ELit (LInt 191)) (ELit (LInt 200))))
(DTest false "sha256 of the empty message" (EApp (EApp (EVar "expectEqual") (ELit (LString "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))) (EApp (EVar "digestHex") (ELit (LString "")))))
(DTest false "sha256 of abc" (EApp (EApp (EVar "expectEqual") (ELit (LString "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))) (EApp (EVar "digestHex") (ELit (LString "abc")))))
(DTest false "sha256 of the 448-bit two-block message" (EApp (EApp (EVar "expectEqual") (ELit (LString "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"))) (EApp (EVar "digestHex") (ELit (LString "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")))))
(DTest false "sha256 of the 896-bit message" (EApp (EApp (EVar "expectEqual") (ELit (LString "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"))) (EApp (EVar "digestHex") (ELit (LString "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")))))
(DTest false "sha256 digests are 32 bytes whatever the message" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EMethodRef "map") (ELam (PWild) (ELit (LInt 32)))) (EVar "boundaryLengths"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EVar "B.length") (EApp (EVar "sha256") (EApp (EVar "patterned") (EVar "n")))))) (EVar "boundaryLengths"))))
(DTest false "sha256 agrees with the Medaka implementation at every padding boundary" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EVar "Hex.encode") (EApp (EVar "reference") (EApp (EVar "patterned") (EVar "n")))))) (EVar "boundaryLengths"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256") (EApp (EVar "patterned") (EVar "n")))))) (EVar "boundaryLengths"))))
(DTest false "sha256 agrees with the Medaka implementation on a long message" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Hex.encode") (EApp (EVar "reference") (EApp (EVar "patterned") (ELit (LInt 5000)))))) (EApp (EVar "Hex.encode") (EApp (EVar "sha256") (EApp (EVar "patterned") (ELit (LInt 5000)))))))
