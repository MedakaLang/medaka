# META
source_lines=18
stages=CORE_IR
# SOURCE
-- extern kernel: int/string/char/array primitives, value-boundary marshalling
shout s = stringToUpper s
firstChar s = arrayGetUnsafe 0 (stringToChars s)
charAt s i = arrayGetUnsafe i (stringToChars s)
nChars s = arrayLength (stringToChars s)
joinAll parts = stringConcat parts
codeOf c = charCode c
main =
  let greeting = joinAll ["he", "ll", "o"]
  ( intToString 42
  , greeting
  , shout greeting
  , stringLength greeting
  , nChars "héllo"
  , codeOf (charAt "ABC" 1)
  , stringToChars "ab"
  , intToString (stringLength "abc") ++ "!"
  )
# CORE_IR
(CProgram ((CBind "shout" (CClause ((PVar "s")) (CApp (CVar "stringToUpper" AGlobal) ((CVar "s" (ALocal 0 0))) CallDynamic true)))
(CBind "firstChar" (CClause ((PVar "s")) (CApp (CVar "arrayGetUnsafe" AGlobal) ((CLit (LInt 0)) (CApp (CVar "stringToChars" AGlobal) ((CVar "s" (ALocal 0 0))) CallDynamic false)) CallDynamic true)))
(CBind "charAt" (CClause ((PVar "s") (PVar "i")) (CApp (CVar "arrayGetUnsafe" AGlobal) ((CVar "i" (ALocal 0 0)) (CApp (CVar "stringToChars" AGlobal) ((CVar "s" (ALocal 1 0))) CallDynamic false)) CallDynamic true)))
(CBind "nChars" (CClause ((PVar "s")) (CApp (CVar "arrayLength" AGlobal) ((CApp (CVar "stringToChars" AGlobal) ((CVar "s" (ALocal 0 0))) CallDynamic false)) CallDynamic true)))
(CBind "joinAll" (CClause ((PVar "parts")) (CApp (CVar "stringConcat" AGlobal) ((CVar "parts" (ALocal 0 0))) CallDynamic true)))
(CBind "codeOf" (CClause ((PVar "c")) (CApp (CVar "charCode" AGlobal) ((CVar "c" (ALocal 0 0))) CallDynamic true)))
(CBind "main" (CClause () (CBlock (CSLet false (PVar "greeting") (CApp (CVar "joinAll" AGlobal) ((CList (CLit (LString "he")) (CLit (LString "ll")) (CLit (LString "o")))) CallExact false)) (CSExpr (CTuple (CApp (CVar "intToString" AGlobal) ((CLit (LInt 42))) CallDynamic false) (CVar "greeting" (ALocal 0 0)) (CApp (CVar "shout" AGlobal) ((CVar "greeting" (ALocal 0 0))) CallExact false) (CApp (CVar "stringLength" AGlobal) ((CVar "greeting" (ALocal 0 0))) CallDynamic false) (CApp (CVar "nChars" AGlobal) ((CLit (LString "héllo"))) CallExact false) (CApp (CVar "codeOf" AGlobal) ((CApp (CVar "charAt" AGlobal) ((CLit (LString "ABC")) (CLit (LInt 1))) CallExact false)) CallExact false) (CApp (CVar "stringToChars" AGlobal) ((CLit (LString "ab"))) CallDynamic false) (CBinPrim "++" (CApp (CVar "intToString" AGlobal) ((CApp (CVar "stringLength" AGlobal) ((CLit (LString "abc"))) CallDynamic false)) CallDynamic false) (CLit (LString "!"))))))))) () () () () (facts () () () none (externs) (manifests) (origins ((function "charAt" (single "charAt")) (function "codeOf" (single "codeOf")) (function "firstChar" (single "firstChar")) (function "joinAll" (single "joinAll")) (function "main" (single "main")) (function "nChars" (single "nChars")) (function "shout" (single "shout"))) ())) (binder-types
(b 0 "" "s" RTValue)
(b 1 "" "s" RTValue)
(b 2 "" "s" RTValue)
(b 3 "" "i" RTValue)
(b 4 "" "s" RTValue)
(b 5 "" "parts" RTValue)
(b 6 "" "c" RTValue)
(b 7 "" "greeting" RTValue)
(b 8 "" "shout" RTValue RTValue)
(b 9 "" "firstChar" RTValue RTValue)
(b 10 "" "charAt" RTValue RTValue)
(b 11 "" "nChars" RTValue RTValue)
(b 12 "" "joinAll" RTValue RTValue)
(b 13 "" "codeOf" RTValue RTValue)
(b 14 "" "main" RTValue RTValue)))
