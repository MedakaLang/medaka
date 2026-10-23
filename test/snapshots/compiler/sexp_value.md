# META
source_lines=158
stages=DESUGAR,MARK
# SOURCE
-- S-expression values with one canonical rendering and a fail-closed reader.
-- Offsets are UTF-8 byte offsets into the input. `sePath` is empty when the
-- reader itself fails; codecs fill it when a node has the wrong shape.
-- The renderer and the reader agree on the quoting set: an atom is bare
-- unless it is empty or holds whitespace, parens, `"`, `;` or `\`.

import array.{fromList}
import list.{reverse}

-- The two constructors coincide with `Result` by shape only; this is a value tree.
-- lint-disable-next-line rule-clone-type
public export data SExp = SAtom String | SList (List SExp) deriving (Eq, Debug)

public export data SexpError = SexpError {
  seOffset : Int,
  sePath : String,
  seWhat : String,
} deriving (Eq, Debug)

bytesOf : String -> List Int
bytesOf s = toList (stringToUtf8Bytes s)

textOf : List Int -> String
textOf bytes = stringFromUtf8Bytes (fromList bytes)

isWsByte : Int -> Bool
isWsByte b = b == 32 || b == 10 || b == 9 || b == 13

-- Bytes that end a bare atom or force quoting.
isSpecialByte : Int -> Bool
isSpecialByte b =
  isWsByte b || b == 40 || b == 41 || b == 34 || b == 59 || b == 92

needsQuote : String -> Bool
needsQuote s = s == "" || any isSpecialByte (bytesOf s)

escapeByte : Int -> List Int
escapeByte 92 = [92, 92]
escapeByte 34 = [92, 34]
escapeByte 10 = [92, 110]
escapeByte 9 = [92, 116]
escapeByte 13 = [92, 114]
escapeByte b = [b]

renderAtom : String -> String
renderAtom s
  | needsQuote s = textOf ([34] ++ flatMap escapeByte (bytesOf s) ++ [34])
  | otherwise = s

export
renderSExp : SExp -> String
renderSExp (SAtom s) = renderAtom s
renderSExp (SList items) = "(" ++ stringJoin " " (map renderSExp items) ++ ")"

failAt : Int -> String -> Result SexpError a
failAt off what = Err SexpError { seOffset = off, sePath = "", seWhat = what }

skipWs : Int -> List Int -> (Int, List Int)
skipWs off (b :: rest)
  | isWsByte b = skipWs (off + 1) rest
skipWs off bytes = (off, bytes)

-- Reads one node; returns it with the offset and bytes that follow it.
readNode : Int -> List Int -> Result SexpError (SExp, Int, List Int)
readNode off bytes = match skipWs off bytes
  (o, []) => failAt o "unexpected end of input"
  (o, 40 :: rest) => readItems o (o + 1) rest []
  (o, 41 :: _) => failAt o "unbalanced close paren"
  (o, 34 :: rest) => readQuoted o (o + 1) rest []
  (o, b :: _) if b == 59 || b == 92 =>
    failAt o "unexpected character outside a quoted atom"
  (o, rest) => readBare o rest []

readBare : Int -> List Int -> List Int -> Result SexpError (SExp, Int, List Int)
readBare off (b :: rest) acc
  | b == 34 || b == 59 || b == 92 =
    failAt off "unexpected character inside a bare atom"
  | isSpecialByte b = Ok (SAtom (textOf (reverse acc)), off, b :: rest)
  | otherwise = readBare (off + 1) rest (b :: acc)
readBare off [] acc = Ok (SAtom (textOf (reverse acc)), off, [])

readQuoted : Int ->
  Int ->
  List Int ->
  List Int ->
  Result SexpError (SExp, Int, List Int)
readQuoted start _ [] _ = failAt start "unterminated string"
readQuoted _ off (34 :: rest) acc =
  Ok (SAtom (textOf (reverse acc)), off + 1, rest)
readQuoted start off (92 :: e :: rest) acc = match unescape e
  Some b => readQuoted start (off + 2) rest (b :: acc)
  None => failAt off "bad escape"
readQuoted start _ [92] _ = failAt start "unterminated string"
readQuoted start off (b :: rest) acc =
  readQuoted start (off + 1) rest (b :: acc)

unescape : Int -> Option Int
unescape 92 = Some 92
unescape 34 = Some 34
unescape 110 = Some 10
unescape 116 = Some 9
unescape 114 = Some 13
unescape _ = None

readItems : Int ->
  Int ->
  List Int ->
  List SExp ->
  Result SexpError (SExp, Int, List Int)
readItems open off bytes acc = match skipWs off bytes
  (_, []) => failAt open "unbalanced open paren"
  (o, 41 :: rest) => Ok (SList (reverse acc), o + 1, rest)
  (o, rest) => match readNode o rest
    Err e => Err e
    Ok (item, o2, rest2) => readItems open o2 rest2 (item :: acc)

export
parseSExp : String -> Result SexpError SExp
parseSExp text = match skipWs 0 (bytesOf text)
  (o, []) => failAt o "empty input"
  (_, bytes) => match readNode 0 bytes
    Err e => Err e
    Ok (node, o, rest) => match skipWs o rest
      (_, []) => Ok node
      (o2, _) => failAt o2 "trailing text after the first node"

shapeError : String -> String -> Result SexpError a
shapeError path what =
  Err SexpError { seOffset = 0, sePath = path, seWhat = what }

export
expectAtom : String -> SExp -> Result SexpError String
expectAtom _ (SAtom s) = Ok s
expectAtom path _ = shapeError path "expected an atom"

export
atomInt : String -> SExp -> Result SexpError Int
atomInt path node = match expectAtom path node
  Err e => Err e
  Ok s => match stringToInt s
    Some n => Ok n
    None => shapeError path "expected an integer"

export
atomBool : String -> SExp -> Result SexpError Bool
atomBool path node = match expectAtom path node
  Err e => Err e
  Ok "true" => Ok True
  Ok "false" => Ok False
  Ok _ => shapeError path "expected true or false"

export
expectList : Int -> String -> SExp -> Result SexpError (List SExp)
expectList arity path (SList items)
  | length items == arity = Ok items
  | otherwise =
    shapeError path ("expected a list of " ++ intToString arity ++ " items")
expectList _ path _ = shapeError path "expected a list"
# DESUGAR
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DData Public "SExp" () ((variant "SAtom" (ConPos (TyCon "String"))) (variant "SList" (ConPos (TyApp (TyCon "List") (TyCon "SExp"))))) ())
(DImpl true "Eq" ((TyCon "SExp")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SAtom" (PVar "__a0")) (PCon "SAtom" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SList" (PVar "__a0")) (PCon "SList" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "SExp")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SAtom" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SAtom ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "SList" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SList ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DData Public "SexpError" () ((variant "SexpError" (ConNamed (field "seOffset" (TyCon "Int")) (field "sePath" (TyCon "String")) (field "seWhat" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "SexpError")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "SexpError" ((rf "seOffset" (PVar "__a0")) (rf "sePath" (PVar "__a1")) (rf "seWhat" (PVar "__a2"))) false) (PRec "SexpError" ((rf "seOffset" (PVar "__b0")) (rf "sePath" (PVar "__b1")) (rf "seWhat" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "SexpError")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "SexpError" ((rf "seOffset" (PVar "__a0")) (rf "sePath" (PVar "__a1")) (rf "seWhat" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "SexpError {")) (ELit (LString " seOffset = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", sePath = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", seWhat = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DTypeSig false "bytesOf" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "bytesOf" ((PVar "s")) (EApp (EVar "toList") (EApp (EVar "stringToUtf8Bytes") (EVar "s"))))
(DTypeSig false "textOf" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "String")))
(DFunDef false "textOf" ((PVar "bytes")) (EApp (EVar "stringFromUtf8Bytes") (EApp (EVar "fromList") (EVar "bytes"))))
(DTypeSig false "isWsByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isWsByte" ((PVar "b")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "b") (ELit (LInt 32))) (EBinOp "==" (EVar "b") (ELit (LInt 10)))) (EBinOp "==" (EVar "b") (ELit (LInt 9)))) (EBinOp "==" (EVar "b") (ELit (LInt 13)))))
(DTypeSig false "isSpecialByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isSpecialByte" ((PVar "b")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isWsByte") (EVar "b")) (EBinOp "==" (EVar "b") (ELit (LInt 40)))) (EBinOp "==" (EVar "b") (ELit (LInt 41)))) (EBinOp "==" (EVar "b") (ELit (LInt 34)))) (EBinOp "==" (EVar "b") (ELit (LInt 59)))) (EBinOp "==" (EVar "b") (ELit (LInt 92)))))
(DTypeSig false "needsQuote" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "needsQuote" ((PVar "s")) (EBinOp "||" (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EApp (EVar "any") (EVar "isSpecialByte")) (EApp (EVar "bytesOf") (EVar "s")))))
(DTypeSig false "escapeByte" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "escapeByte" ((PLit (LInt 92))) (EListLit (ELit (LInt 92)) (ELit (LInt 92))))
(DFunDef false "escapeByte" ((PLit (LInt 34))) (EListLit (ELit (LInt 92)) (ELit (LInt 34))))
(DFunDef false "escapeByte" ((PLit (LInt 10))) (EListLit (ELit (LInt 92)) (ELit (LInt 110))))
(DFunDef false "escapeByte" ((PLit (LInt 9))) (EListLit (ELit (LInt 92)) (ELit (LInt 116))))
(DFunDef false "escapeByte" ((PLit (LInt 13))) (EListLit (ELit (LInt 92)) (ELit (LInt 114))))
(DFunDef false "escapeByte" ((PVar "b")) (EListLit (EVar "b")))
(DTypeSig false "renderAtom" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "renderAtom" ((PVar "s")) (EIf (EApp (EVar "needsQuote") (EVar "s")) (EApp (EVar "textOf") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LInt 34))) (EApp (EApp (EVar "flatMap") (EVar "escapeByte")) (EApp (EVar "bytesOf") (EVar "s")))) (EListLit (ELit (LInt 34))))) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "renderSExp" (TyFun (TyCon "SExp") (TyCon "String")))
(DFunDef false "renderSExp" ((PCon "SAtom" (PVar "s"))) (EApp (EVar "renderAtom") (EVar "s")))
(DFunDef false "renderSExp" ((PCon "SList" (PVar "items"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "stringJoin") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "renderSExp")) (EVar "items")))) (ELit (LString ")"))))
(DTypeSig false "failAt" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DFunDef false "failAt" ((PVar "off") (PVar "what")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (EVar "off")) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (EVar "what"))))))
(DTypeSig false "skipWs" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "skipWs" ((PVar "off") (PCons (PVar "b") (PVar "rest"))) (EIf (EApp (EVar "isWsByte") (EVar "b")) (EApp (EApp (EVar "skipWs") (EBinOp "+" (EVar "off") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "skipWs" ((PVar "off") (PVar "bytes")) (ETuple (EVar "off") (EVar "bytes")))
(DTypeSig false "readNode" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "SExp") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "readNode" ((PVar "off") (PVar "bytes")) (EMatch (EApp (EApp (EVar "skipWs") (EVar "off")) (EVar "bytes")) (arm (PTuple (PVar "o") (PList)) () (EApp (EApp (EVar "failAt") (EVar "o")) (ELit (LString "unexpected end of input")))) (arm (PTuple (PVar "o") (PCons (PLit (LInt 40)) (PVar "rest"))) () (EApp (EApp (EApp (EApp (EVar "readItems") (EVar "o")) (EBinOp "+" (EVar "o") (ELit (LInt 1)))) (EVar "rest")) (EListLit))) (arm (PTuple (PVar "o") (PCons (PLit (LInt 41)) PWild)) () (EApp (EApp (EVar "failAt") (EVar "o")) (ELit (LString "unbalanced close paren")))) (arm (PTuple (PVar "o") (PCons (PLit (LInt 34)) (PVar "rest"))) () (EApp (EApp (EApp (EApp (EVar "readQuoted") (EVar "o")) (EBinOp "+" (EVar "o") (ELit (LInt 1)))) (EVar "rest")) (EListLit))) (arm (PTuple (PVar "o") (PCons (PVar "b") PWild)) ((GBool (EBinOp "||" (EBinOp "==" (EVar "b") (ELit (LInt 59))) (EBinOp "==" (EVar "b") (ELit (LInt 92)))))) (EApp (EApp (EVar "failAt") (EVar "o")) (ELit (LString "unexpected character outside a quoted atom")))) (arm (PTuple (PVar "o") (PVar "rest")) () (EApp (EApp (EApp (EVar "readBare") (EVar "o")) (EVar "rest")) (EListLit)))))
(DTypeSig false "readBare" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "SExp") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "readBare" ((PVar "off") (PCons (PVar "b") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "b") (ELit (LInt 34))) (EBinOp "==" (EVar "b") (ELit (LInt 59)))) (EBinOp "==" (EVar "b") (ELit (LInt 92)))) (EApp (EApp (EVar "failAt") (EVar "off")) (ELit (LString "unexpected character inside a bare atom"))) (EIf (EApp (EVar "isSpecialByte") (EVar "b")) (EApp (EVar "Ok") (ETuple (EApp (EVar "SAtom") (EApp (EVar "textOf") (EApp (EVar "reverse") (EVar "acc")))) (EVar "off") (EBinOp "::" (EVar "b") (EVar "rest")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "readBare") (EBinOp "+" (EVar "off") (ELit (LInt 1)))) (EVar "rest")) (EBinOp "::" (EVar "b") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "readBare" ((PVar "off") (PList) (PVar "acc")) (EApp (EVar "Ok") (ETuple (EApp (EVar "SAtom") (EApp (EVar "textOf") (EApp (EVar "reverse") (EVar "acc")))) (EVar "off") (EListLit))))
(DTypeSig false "readQuoted" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "SExp") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "readQuoted" ((PVar "start") PWild (PList) PWild) (EApp (EApp (EVar "failAt") (EVar "start")) (ELit (LString "unterminated string"))))
(DFunDef false "readQuoted" (PWild (PVar "off") (PCons (PLit (LInt 34)) (PVar "rest")) (PVar "acc")) (EApp (EVar "Ok") (ETuple (EApp (EVar "SAtom") (EApp (EVar "textOf") (EApp (EVar "reverse") (EVar "acc")))) (EBinOp "+" (EVar "off") (ELit (LInt 1))) (EVar "rest"))))
(DFunDef false "readQuoted" ((PVar "start") (PVar "off") (PCons (PLit (LInt 92)) (PCons (PVar "e") (PVar "rest"))) (PVar "acc")) (EMatch (EApp (EVar "unescape") (EVar "e")) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EApp (EApp (EVar "readQuoted") (EVar "start")) (EBinOp "+" (EVar "off") (ELit (LInt 2)))) (EVar "rest")) (EBinOp "::" (EVar "b") (EVar "acc")))) (arm (PCon "None") () (EApp (EApp (EVar "failAt") (EVar "off")) (ELit (LString "bad escape"))))))
(DFunDef false "readQuoted" ((PVar "start") PWild (PList (PLit (LInt 92))) PWild) (EApp (EApp (EVar "failAt") (EVar "start")) (ELit (LString "unterminated string"))))
(DFunDef false "readQuoted" ((PVar "start") (PVar "off") (PCons (PVar "b") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "readQuoted") (EVar "start")) (EBinOp "+" (EVar "off") (ELit (LInt 1)))) (EVar "rest")) (EBinOp "::" (EVar "b") (EVar "acc"))))
(DTypeSig false "unescape" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "unescape" ((PLit (LInt 92))) (EApp (EVar "Some") (ELit (LInt 92))))
(DFunDef false "unescape" ((PLit (LInt 34))) (EApp (EVar "Some") (ELit (LInt 34))))
(DFunDef false "unescape" ((PLit (LInt 110))) (EApp (EVar "Some") (ELit (LInt 10))))
(DFunDef false "unescape" ((PLit (LInt 116))) (EApp (EVar "Some") (ELit (LInt 9))))
(DFunDef false "unescape" ((PLit (LInt 114))) (EApp (EVar "Some") (ELit (LInt 13))))
(DFunDef false "unescape" (PWild) (EVar "None"))
(DTypeSig false "readItems" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "SExp") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "readItems" ((PVar "open") (PVar "off") (PVar "bytes") (PVar "acc")) (EMatch (EApp (EApp (EVar "skipWs") (EVar "off")) (EVar "bytes")) (arm (PTuple PWild (PList)) () (EApp (EApp (EVar "failAt") (EVar "open")) (ELit (LString "unbalanced open paren")))) (arm (PTuple (PVar "o") (PCons (PLit (LInt 41)) (PVar "rest"))) () (EApp (EVar "Ok") (ETuple (EApp (EVar "SList") (EApp (EVar "reverse") (EVar "acc"))) (EBinOp "+" (EVar "o") (ELit (LInt 1))) (EVar "rest")))) (arm (PTuple (PVar "o") (PVar "rest")) () (EMatch (EApp (EApp (EVar "readNode") (EVar "o")) (EVar "rest")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "item") (PVar "o2") (PVar "rest2"))) () (EApp (EApp (EApp (EApp (EVar "readItems") (EVar "open")) (EVar "o2")) (EVar "rest2")) (EBinOp "::" (EVar "item") (EVar "acc"))))))))
(DTypeSig true "parseSExp" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "SExp"))))
(DFunDef false "parseSExp" ((PVar "text")) (EMatch (EApp (EApp (EVar "skipWs") (ELit (LInt 0))) (EApp (EVar "bytesOf") (EVar "text"))) (arm (PTuple (PVar "o") (PList)) () (EApp (EApp (EVar "failAt") (EVar "o")) (ELit (LString "empty input")))) (arm (PTuple PWild (PVar "bytes")) () (EMatch (EApp (EApp (EVar "readNode") (ELit (LInt 0))) (EVar "bytes")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "node") (PVar "o") (PVar "rest"))) () (EMatch (EApp (EApp (EVar "skipWs") (EVar "o")) (EVar "rest")) (arm (PTuple PWild (PList)) () (EApp (EVar "Ok") (EVar "node"))) (arm (PTuple (PVar "o2") PWild) () (EApp (EApp (EVar "failAt") (EVar "o2")) (ELit (LString "trailing text after the first node"))))))))))
(DTypeSig false "shapeError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DFunDef false "shapeError" ((PVar "path") (PVar "what")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (EVar "path")) (fa "seWhat" (EVar "what"))))))
(DTypeSig true "expectAtom" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "String")))))
(DFunDef false "expectAtom" (PWild (PCon "SAtom" (PVar "s"))) (EApp (EVar "Ok") (EVar "s")))
(DFunDef false "expectAtom" ((PVar "path") PWild) (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected an atom"))))
(DTypeSig true "atomInt" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Int")))))
(DFunDef false "atomInt" ((PVar "path") (PVar "node")) (EMatch (EApp (EApp (EVar "expectAtom") (EVar "path")) (EVar "node")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "s")) () (EMatch (EApp (EVar "stringToInt") (EVar "s")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EVar "n"))) (arm (PCon "None") () (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected an integer"))))))))
(DTypeSig true "atomBool" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Bool")))))
(DFunDef false "atomBool" ((PVar "path") (PVar "node")) (EMatch (EApp (EApp (EVar "expectAtom") (EVar "path")) (EVar "node")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PLit (LString "true"))) () (EApp (EVar "Ok") (EVar "True"))) (arm (PCon "Ok" (PLit (LString "false"))) () (EApp (EVar "Ok") (EVar "False"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected true or false"))))))
(DTypeSig true "expectList" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyCon "SExp")))))))
(DFunDef false "expectList" ((PVar "arity") (PVar "path") (PCon "SList" (PVar "items"))) (EIf (EBinOp "==" (EApp (EVar "length") (EVar "items")) (EVar "arity")) (EApp (EVar "Ok") (EVar "items")) (EIf (EVar "otherwise") (EApp (EApp (EVar "shapeError") (EVar "path")) (EBinOp "++" (EBinOp "++" (ELit (LString "expected a list of ")) (EApp (EVar "intToString") (EVar "arity"))) (ELit (LString " items")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "expectList" (PWild (PVar "path") PWild) (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected a list"))))
# MARK
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DData Public "SExp" () ((variant "SAtom" (ConPos (TyCon "String"))) (variant "SList" (ConPos (TyApp (TyCon "List") (TyCon "SExp"))))) ())
(DImpl true "Eq" ((TyCon "SExp")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SAtom" (PVar "__a0")) (PCon "SAtom" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SList" (PVar "__a0")) (PCon "SList" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "SExp")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SAtom" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SAtom ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "SList" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SList ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DData Public "SexpError" () ((variant "SexpError" (ConNamed (field "seOffset" (TyCon "Int")) (field "sePath" (TyCon "String")) (field "seWhat" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "SexpError")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "SexpError" ((rf "seOffset" (PVar "__a0")) (rf "sePath" (PVar "__a1")) (rf "seWhat" (PVar "__a2"))) false) (PRec "SexpError" ((rf "seOffset" (PVar "__b0")) (rf "sePath" (PVar "__b1")) (rf "seWhat" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "SexpError")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "SexpError" ((rf "seOffset" (PVar "__a0")) (rf "sePath" (PVar "__a1")) (rf "seWhat" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "SexpError {")) (ELit (LString " seOffset = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", sePath = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", seWhat = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DTypeSig false "bytesOf" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "bytesOf" ((PVar "s")) (EApp (EMethodRef "toList") (EApp (EVar "stringToUtf8Bytes") (EVar "s"))))
(DTypeSig false "textOf" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "String")))
(DFunDef false "textOf" ((PVar "bytes")) (EApp (EVar "stringFromUtf8Bytes") (EApp (EVar "fromList") (EVar "bytes"))))
(DTypeSig false "isWsByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isWsByte" ((PVar "b")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "b") (ELit (LInt 32))) (EBinOp "==" (EVar "b") (ELit (LInt 10)))) (EBinOp "==" (EVar "b") (ELit (LInt 9)))) (EBinOp "==" (EVar "b") (ELit (LInt 13)))))
(DTypeSig false "isSpecialByte" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isSpecialByte" ((PVar "b")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isWsByte") (EVar "b")) (EBinOp "==" (EVar "b") (ELit (LInt 40)))) (EBinOp "==" (EVar "b") (ELit (LInt 41)))) (EBinOp "==" (EVar "b") (ELit (LInt 34)))) (EBinOp "==" (EVar "b") (ELit (LInt 59)))) (EBinOp "==" (EVar "b") (ELit (LInt 92)))))
(DTypeSig false "needsQuote" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "needsQuote" ((PVar "s")) (EBinOp "||" (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EApp (EDictApp "any") (EVar "isSpecialByte")) (EApp (EVar "bytesOf") (EVar "s")))))
(DTypeSig false "escapeByte" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "escapeByte" ((PLit (LInt 92))) (EListLit (ELit (LInt 92)) (ELit (LInt 92))))
(DFunDef false "escapeByte" ((PLit (LInt 34))) (EListLit (ELit (LInt 92)) (ELit (LInt 34))))
(DFunDef false "escapeByte" ((PLit (LInt 10))) (EListLit (ELit (LInt 92)) (ELit (LInt 110))))
(DFunDef false "escapeByte" ((PLit (LInt 9))) (EListLit (ELit (LInt 92)) (ELit (LInt 116))))
(DFunDef false "escapeByte" ((PLit (LInt 13))) (EListLit (ELit (LInt 92)) (ELit (LInt 114))))
(DFunDef false "escapeByte" ((PVar "b")) (EListLit (EVar "b")))
(DTypeSig false "renderAtom" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "renderAtom" ((PVar "s")) (EIf (EApp (EVar "needsQuote") (EVar "s")) (EApp (EVar "textOf") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LInt 34))) (EApp (EApp (EDictApp "flatMap") (EVar "escapeByte")) (EApp (EVar "bytesOf") (EVar "s")))) (EListLit (ELit (LInt 34))))) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "renderSExp" (TyFun (TyCon "SExp") (TyCon "String")))
(DFunDef false "renderSExp" ((PCon "SAtom" (PVar "s"))) (EApp (EVar "renderAtom") (EVar "s")))
(DFunDef false "renderSExp" ((PCon "SList" (PVar "items"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "stringJoin") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "renderSExp")) (EVar "items")))) (ELit (LString ")"))))
(DTypeSig false "failAt" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DFunDef false "failAt" ((PVar "off") (PVar "what")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (EVar "off")) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (EVar "what"))))))
(DTypeSig false "skipWs" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "skipWs" ((PVar "off") (PCons (PVar "b") (PVar "rest"))) (EIf (EApp (EVar "isWsByte") (EVar "b")) (EApp (EApp (EVar "skipWs") (EBinOp "+" (EVar "off") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "skipWs" ((PVar "off") (PVar "bytes")) (ETuple (EVar "off") (EVar "bytes")))
(DTypeSig false "readNode" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "SExp") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "readNode" ((PVar "off") (PVar "bytes")) (EMatch (EApp (EApp (EVar "skipWs") (EVar "off")) (EVar "bytes")) (arm (PTuple (PVar "o") (PList)) () (EApp (EApp (EVar "failAt") (EVar "o")) (ELit (LString "unexpected end of input")))) (arm (PTuple (PVar "o") (PCons (PLit (LInt 40)) (PVar "rest"))) () (EApp (EApp (EApp (EApp (EVar "readItems") (EVar "o")) (EBinOp "+" (EVar "o") (ELit (LInt 1)))) (EVar "rest")) (EListLit))) (arm (PTuple (PVar "o") (PCons (PLit (LInt 41)) PWild)) () (EApp (EApp (EVar "failAt") (EVar "o")) (ELit (LString "unbalanced close paren")))) (arm (PTuple (PVar "o") (PCons (PLit (LInt 34)) (PVar "rest"))) () (EApp (EApp (EApp (EApp (EVar "readQuoted") (EVar "o")) (EBinOp "+" (EVar "o") (ELit (LInt 1)))) (EVar "rest")) (EListLit))) (arm (PTuple (PVar "o") (PCons (PVar "b") PWild)) ((GBool (EBinOp "||" (EBinOp "==" (EVar "b") (ELit (LInt 59))) (EBinOp "==" (EVar "b") (ELit (LInt 92)))))) (EApp (EApp (EVar "failAt") (EVar "o")) (ELit (LString "unexpected character outside a quoted atom")))) (arm (PTuple (PVar "o") (PVar "rest")) () (EApp (EApp (EApp (EVar "readBare") (EVar "o")) (EVar "rest")) (EListLit)))))
(DTypeSig false "readBare" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "SExp") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "readBare" ((PVar "off") (PCons (PVar "b") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "b") (ELit (LInt 34))) (EBinOp "==" (EVar "b") (ELit (LInt 59)))) (EBinOp "==" (EVar "b") (ELit (LInt 92)))) (EApp (EApp (EVar "failAt") (EVar "off")) (ELit (LString "unexpected character inside a bare atom"))) (EIf (EApp (EVar "isSpecialByte") (EVar "b")) (EApp (EVar "Ok") (ETuple (EApp (EVar "SAtom") (EApp (EVar "textOf") (EApp (EVar "reverse") (EVar "acc")))) (EVar "off") (EBinOp "::" (EVar "b") (EVar "rest")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "readBare") (EBinOp "+" (EVar "off") (ELit (LInt 1)))) (EVar "rest")) (EBinOp "::" (EVar "b") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "readBare" ((PVar "off") (PList) (PVar "acc")) (EApp (EVar "Ok") (ETuple (EApp (EVar "SAtom") (EApp (EVar "textOf") (EApp (EVar "reverse") (EVar "acc")))) (EVar "off") (EListLit))))
(DTypeSig false "readQuoted" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "SExp") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "readQuoted" ((PVar "start") PWild (PList) PWild) (EApp (EApp (EVar "failAt") (EVar "start")) (ELit (LString "unterminated string"))))
(DFunDef false "readQuoted" (PWild (PVar "off") (PCons (PLit (LInt 34)) (PVar "rest")) (PVar "acc")) (EApp (EVar "Ok") (ETuple (EApp (EVar "SAtom") (EApp (EVar "textOf") (EApp (EVar "reverse") (EVar "acc")))) (EBinOp "+" (EVar "off") (ELit (LInt 1))) (EVar "rest"))))
(DFunDef false "readQuoted" ((PVar "start") (PVar "off") (PCons (PLit (LInt 92)) (PCons (PVar "e") (PVar "rest"))) (PVar "acc")) (EMatch (EApp (EVar "unescape") (EVar "e")) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EApp (EApp (EVar "readQuoted") (EVar "start")) (EBinOp "+" (EVar "off") (ELit (LInt 2)))) (EVar "rest")) (EBinOp "::" (EVar "b") (EVar "acc")))) (arm (PCon "None") () (EApp (EApp (EVar "failAt") (EVar "off")) (ELit (LString "bad escape"))))))
(DFunDef false "readQuoted" ((PVar "start") PWild (PList (PLit (LInt 92))) PWild) (EApp (EApp (EVar "failAt") (EVar "start")) (ELit (LString "unterminated string"))))
(DFunDef false "readQuoted" ((PVar "start") (PVar "off") (PCons (PVar "b") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "readQuoted") (EVar "start")) (EBinOp "+" (EVar "off") (ELit (LInt 1)))) (EVar "rest")) (EBinOp "::" (EVar "b") (EVar "acc"))))
(DTypeSig false "unescape" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "unescape" ((PLit (LInt 92))) (EApp (EVar "Some") (ELit (LInt 92))))
(DFunDef false "unescape" ((PLit (LInt 34))) (EApp (EVar "Some") (ELit (LInt 34))))
(DFunDef false "unescape" ((PLit (LInt 110))) (EApp (EVar "Some") (ELit (LInt 10))))
(DFunDef false "unescape" ((PLit (LInt 116))) (EApp (EVar "Some") (ELit (LInt 9))))
(DFunDef false "unescape" ((PLit (LInt 114))) (EApp (EVar "Some") (ELit (LInt 13))))
(DFunDef false "unescape" (PWild) (EVar "None"))
(DTypeSig false "readItems" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "SExp") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "readItems" ((PVar "open") (PVar "off") (PVar "bytes") (PVar "acc")) (EMatch (EApp (EApp (EVar "skipWs") (EVar "off")) (EVar "bytes")) (arm (PTuple PWild (PList)) () (EApp (EApp (EVar "failAt") (EVar "open")) (ELit (LString "unbalanced open paren")))) (arm (PTuple (PVar "o") (PCons (PLit (LInt 41)) (PVar "rest"))) () (EApp (EVar "Ok") (ETuple (EApp (EVar "SList") (EApp (EVar "reverse") (EVar "acc"))) (EBinOp "+" (EVar "o") (ELit (LInt 1))) (EVar "rest")))) (arm (PTuple (PVar "o") (PVar "rest")) () (EMatch (EApp (EApp (EVar "readNode") (EVar "o")) (EVar "rest")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "item") (PVar "o2") (PVar "rest2"))) () (EApp (EApp (EApp (EApp (EVar "readItems") (EVar "open")) (EVar "o2")) (EVar "rest2")) (EBinOp "::" (EVar "item") (EVar "acc"))))))))
(DTypeSig true "parseSExp" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "SExp"))))
(DFunDef false "parseSExp" ((PVar "text")) (EMatch (EApp (EApp (EVar "skipWs") (ELit (LInt 0))) (EApp (EVar "bytesOf") (EVar "text"))) (arm (PTuple (PVar "o") (PList)) () (EApp (EApp (EVar "failAt") (EVar "o")) (ELit (LString "empty input")))) (arm (PTuple PWild (PVar "bytes")) () (EMatch (EApp (EApp (EVar "readNode") (ELit (LInt 0))) (EVar "bytes")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "node") (PVar "o") (PVar "rest"))) () (EMatch (EApp (EApp (EVar "skipWs") (EVar "o")) (EVar "rest")) (arm (PTuple PWild (PList)) () (EApp (EVar "Ok") (EVar "node"))) (arm (PTuple (PVar "o2") PWild) () (EApp (EApp (EVar "failAt") (EVar "o2")) (ELit (LString "trailing text after the first node"))))))))))
(DTypeSig false "shapeError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DFunDef false "shapeError" ((PVar "path") (PVar "what")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (EVar "path")) (fa "seWhat" (EVar "what"))))))
(DTypeSig true "expectAtom" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "String")))))
(DFunDef false "expectAtom" (PWild (PCon "SAtom" (PVar "s"))) (EApp (EVar "Ok") (EVar "s")))
(DFunDef false "expectAtom" ((PVar "path") PWild) (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected an atom"))))
(DTypeSig true "atomInt" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Int")))))
(DFunDef false "atomInt" ((PVar "path") (PVar "node")) (EMatch (EApp (EApp (EVar "expectAtom") (EVar "path")) (EVar "node")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PVar "s")) () (EMatch (EApp (EVar "stringToInt") (EVar "s")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (EVar "n"))) (arm (PCon "None") () (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected an integer"))))))))
(DTypeSig true "atomBool" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Bool")))))
(DFunDef false "atomBool" ((PVar "path") (PVar "node")) (EMatch (EApp (EApp (EVar "expectAtom") (EVar "path")) (EVar "node")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PLit (LString "true"))) () (EApp (EVar "Ok") (EVar "True"))) (arm (PCon "Ok" (PLit (LString "false"))) () (EApp (EVar "Ok") (EVar "False"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected true or false"))))))
(DTypeSig true "expectList" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyCon "SExp")))))))
(DFunDef false "expectList" ((PVar "arity") (PVar "path") (PCon "SList" (PVar "items"))) (EIf (EBinOp "==" (EApp (EMethodRef "length") (EVar "items")) (EVar "arity")) (EApp (EVar "Ok") (EVar "items")) (EIf (EVar "otherwise") (EApp (EApp (EVar "shapeError") (EVar "path")) (EBinOp "++" (EBinOp "++" (ELit (LString "expected a list of ")) (EApp (EVar "intToString") (EVar "arity"))) (ELit (LString " items")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "expectList" (PWild (PVar "path") PWild) (EApp (EApp (EVar "shapeError") (EVar "path")) (ELit (LString "expected a list"))))
