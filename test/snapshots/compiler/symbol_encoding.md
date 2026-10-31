# META
source_lines=31
stages=DESUGAR,MARK
# SOURCE
import array.{get as arrGet}
import string.{toDigit, toUtf8}

digitChar : Int -> Char
digitChar n = optionOr '?' (toDigit n)

byteChars : Int -> (Char, Char)
byteChars b =
  let byte = bitAnd b 255
  (digitChar (shiftRight byte 4), digitChar (bitAnd byte 15))

encodeGo : Array Int -> Int -> List Char -> List Char
encodeGo bytes i acc
  | i < 0 = acc
  | otherwise = match arrGet i bytes
    None => acc
    Some b =>
      let (hi, lo) = byteChars b
      encodeGo bytes (i - 1) (hi :: lo :: acc)

export
encodeComponent : String -> String
encodeComponent s = encodeBytes (toUtf8 s)

encodeBytes : Array Int -> String
encodeBytes bytes =
  stringFromChars (arrayFromList (encodeGo bytes (arrayLength bytes - 1) []))

export
encodePair : String -> String -> String
encodePair mid name = "m\{encodeComponent mid}__\{name}"
# DESUGAR
(DUse false (UseGroup ("array") ((mem "get" false "arrGet"))))
(DUse false (UseGroup ("string") ((mem "toDigit" false) (mem "toUtf8" false))))
(DTypeSig false "digitChar" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "digitChar" ((PVar "n")) (EApp (EApp (EVar "optionOr") (ELit (LChar "?"))) (EApp (EVar "toDigit") (EVar "n"))))
(DTypeSig false "byteChars" (TyFun (TyCon "Int") (TyTuple (TyCon "Char") (TyCon "Char"))))
(DFunDef false "byteChars" ((PVar "b")) (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 255)))) (DoExpr (ETuple (EApp (EVar "digitChar") (EApp (EApp (EVar "shiftRight") (EVar "byte")) (ELit (LInt 4)))) (EApp (EVar "digitChar") (EApp (EApp (EVar "bitAnd") (EVar "byte")) (ELit (LInt 15))))))))
(DTypeSig false "encodeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "encodeGo" ((PVar "bytes") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrGet") (EVar "i")) (EVar "bytes")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "b")) () (EBlock (DoLet false false (PTuple (PVar "hi") (PVar "lo")) (EApp (EVar "byteChars") (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "hi") (EBinOp "::" (EVar "lo") (EVar "acc")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "encodeComponent" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "encodeComponent" ((PVar "s")) (EApp (EVar "encodeBytes") (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig false "encodeBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "encodeBytes" ((PVar "bytes")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bytes")) (ELit (LInt 1)))) (EListLit)))))
(DTypeSig true "encodePair" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "encodePair" ((PVar "mid") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "m")) (EApp (EVar "display") (EApp (EVar "encodeComponent") (EVar "mid")))) (ELit (LString "__"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
# MARK
(DUse false (UseGroup ("array") ((mem "get" false "arrGet"))))
(DUse false (UseGroup ("string") ((mem "toDigit" false) (mem "toUtf8" false))))
(DTypeSig false "digitChar" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "digitChar" ((PVar "n")) (EApp (EApp (EVar "optionOr") (ELit (LChar "?"))) (EApp (EVar "toDigit") (EVar "n"))))
(DTypeSig false "byteChars" (TyFun (TyCon "Int") (TyTuple (TyCon "Char") (TyCon "Char"))))
(DFunDef false "byteChars" ((PVar "b")) (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 255)))) (DoExpr (ETuple (EApp (EVar "digitChar") (EApp (EApp (EVar "shiftRight") (EVar "byte")) (ELit (LInt 4)))) (EApp (EVar "digitChar") (EApp (EApp (EVar "bitAnd") (EVar "byte")) (ELit (LInt 15))))))))
(DTypeSig false "encodeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "encodeGo" ((PVar "bytes") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrGet") (EVar "i")) (EVar "bytes")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "b")) () (EBlock (DoLet false false (PTuple (PVar "hi") (PVar "lo")) (EApp (EVar "byteChars") (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "hi") (EBinOp "::" (EVar "lo") (EVar "acc")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "encodeComponent" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "encodeComponent" ((PVar "s")) (EApp (EVar "encodeBytes") (EApp (EVar "toUtf8") (EVar "s"))))
(DTypeSig false "encodeBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "encodeBytes" ((PVar "bytes")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "encodeGo") (EVar "bytes")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "bytes")) (ELit (LInt 1)))) (EListLit)))))
(DTypeSig true "encodePair" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "encodePair" ((PVar "mid") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "m")) (EApp (EMethodRef "display") (EApp (EVar "encodeComponent") (EVar "mid")))) (ELit (LString "__"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
