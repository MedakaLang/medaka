# META
source_lines=124
stages=DESUGAR,MARK
# SOURCE
import array.{fromList}
import list.{reverse}
import string.{toChars}

export data SourceIndex = SourceIndex (Array Int) (Array Int) (Array Int)

-- Starts and ends exclude newline codepoints; prefixes count UTF-16 units.
indexGo : Array Char ->
  Int ->
  Int ->
  Int ->
  List Int ->
  List Int ->
  List Int ->
  SourceIndex
indexGo chars i start units starts ends prefixes =
  if i >= arrayLength chars then
    SourceIndex
      (fromList (reverse (start :: starts)))
      (fromList (reverse (i :: ends)))
      (fromList (reverse (units :: prefixes)))
  else
    let c = arrayGetUnsafe i chars
    if c == '\r'
      && i + 1 < arrayLength chars
      && arrayGetUnsafe (i + 1) chars == '\n' then
      indexGo
        chars
        (i + 2)
        (i + 2)
        (units + 2)
        (start :: starts)
        (i :: ends)
        (units + 1 :: units :: prefixes)
    else if c == '\r' || c == '\n' then
      indexGo
        chars
        (i + 1)
        (i + 1)
        (units + 1)
        (start :: starts)
        (i :: ends)
        (units :: prefixes)
    else
      indexGo
        chars
        (i + 1)
        start
        (units + (if charCode c > 65535 then 2 else 1))
        starts
        ends
        (units :: prefixes)

export
indexSource : String -> SourceIndex
indexSource source = indexGo (toChars source) 0 0 0 [] [] []

-- Last index whose value is at most target, or -1 if none.
floorIndex : Array Int -> Int -> Int -> Int -> Int
floorIndex values target lo hi =
  if lo >= hi then
    lo - 1
  else
    let mid = (lo + hi) / 2
    if arrayGetUnsafe mid values <= target then
      floorIndex values target (mid + 1) hi
    else
      floorIndex values target lo mid

export
offsetToSourcePosition : SourceIndex -> Int -> Option (Int, Int)
offsetToSourcePosition (SourceIndex starts ends _) offset =
  let line = floorIndex starts offset 0 (arrayLength starts)
  if line < 0 || offset > arrayGetUnsafe line ends then
    None
  else
    Some (line + 1, offset - arrayGetUnsafe line starts)

export
sourcePositionToOffset : SourceIndex -> Int -> Int -> Option Int
sourcePositionToOffset (SourceIndex starts ends _) line column =
  let i = line - 1
  if i < 0 || i >= arrayLength starts || column < 0 then
    None
  else
    let start = arrayGetUnsafe i starts
    if column > arrayGetUnsafe i ends - start then
      None
    else
      Some (start + column)

export
clampSourcePositionToOffset : SourceIndex -> Int -> Int -> Int
clampSourcePositionToOffset (SourceIndex starts ends _) line column =
  let i = max 0 (min (arrayLength starts - 1) (line - 1))
  let start = arrayGetUnsafe i starts
  start + max 0 (min (arrayGetUnsafe i ends - start) column)

export
offsetToUtf16Position : SourceIndex -> Int -> Option (Int, Int)
offsetToUtf16Position index offset = match index
  SourceIndex starts _ prefixes => match offsetToSourcePosition index offset
    None => None
    Some (line, _) =>
      let start = arrayGetUnsafe (line - 1) starts
      Some (
        line - 1,
        arrayGetUnsafe offset prefixes - arrayGetUnsafe start prefixes,
      )

export
utf16PositionToOffset : SourceIndex -> Int -> Int -> Option Int
utf16PositionToOffset (SourceIndex starts ends prefixes) line column =
  if line < 0 || line >= arrayLength starts || column < 0 then
    None
  else
    let start = arrayGetUnsafe line starts
    let end = arrayGetUnsafe line ends
    let target = arrayGetUnsafe start prefixes + column
    let offset = floorIndex prefixes target start (end + 1)
    if offset < start || arrayGetUnsafe offset prefixes /= target then
      None
    else
      Some offset
# DESUGAR
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "toChars" false))))
(DData Abstract "SourceIndex" () ((variant "SourceIndex" (ConPos (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int"))))) ())
(DTypeSig false "indexGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "SourceIndex")))))))))
(DFunDef false "indexGo" ((PVar "chars") (PVar "i") (PVar "start") (PVar "units") (PVar "starts") (PVar "ends") (PVar "prefixes")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "chars"))) (EApp (EApp (EApp (EVar "SourceIndex") (EApp (EVar "fromList") (EApp (EVar "reverse") (EBinOp "::" (EVar "start") (EVar "starts"))))) (EApp (EVar "fromList") (EApp (EVar "reverse") (EBinOp "::" (EVar "i") (EVar "ends"))))) (EApp (EVar "fromList") (EApp (EVar "reverse") (EBinOp "::" (EVar "units") (EVar "prefixes"))))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "chars")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "chars")) (ELit (LChar "\n")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EBinOp "+" (EVar "units") (ELit (LInt 2)))) (EBinOp "::" (EVar "start") (EVar "starts"))) (EBinOp "::" (EVar "i") (EVar "ends"))) (EBinOp "::" (EBinOp "+" (EVar "units") (ELit (LInt 1))) (EBinOp "::" (EVar "units") (EVar "prefixes")))) (EIf (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (EBinOp "==" (EVar "c") (ELit (LChar "\n")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "units") (ELit (LInt 1)))) (EBinOp "::" (EVar "start") (EVar "starts"))) (EBinOp "::" (EVar "i") (EVar "ends"))) (EBinOp "::" (EVar "units") (EVar "prefixes"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "start")) (EBinOp "+" (EVar "units") (EIf (EBinOp ">" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 65535))) (ELit (LInt 2)) (ELit (LInt 1))))) (EVar "starts")) (EVar "ends")) (EBinOp "::" (EVar "units") (EVar "prefixes")))))))))
(DTypeSig true "indexSource" (TyFun (TyCon "String") (TyCon "SourceIndex")))
(DFunDef false "indexSource" ((PVar "source")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EApp (EVar "toChars") (EVar "source"))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EListLit)) (EListLit)))
(DTypeSig false "floorIndex" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "floorIndex" ((PVar "values") (PVar "target") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "lo") (EVar "hi")) (EBinOp "-" (EVar "lo") (ELit (LInt 1))) (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EVar "lo") (EVar "hi")) (ELit (LInt 2)))) (DoExpr (EIf (EBinOp "<=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "mid")) (EVar "values")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "floorIndex") (EVar "values")) (EVar "target")) (EBinOp "+" (EVar "mid") (ELit (LInt 1)))) (EVar "hi")) (EApp (EApp (EApp (EApp (EVar "floorIndex") (EVar "values")) (EVar "target")) (EVar "lo")) (EVar "mid")))))))
(DTypeSig true "offsetToSourcePosition" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "offsetToSourcePosition" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") PWild) (PVar "offset")) (EBlock (DoLet false false (PVar "line") (EApp (EApp (EApp (EApp (EVar "floorIndex") (EVar "starts")) (EVar "offset")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "starts")))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "line") (ELit (LInt 0))) (EBinOp ">" (EVar "offset") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "ends")))) (EVar "None") (EApp (EVar "Some") (ETuple (EBinOp "+" (EVar "line") (ELit (LInt 1))) (EBinOp "-" (EVar "offset") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "starts")))))))))
(DTypeSig true "sourcePositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "sourcePositionToOffset" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") PWild) (PVar "line") (PVar "column")) (EBlock (DoLet false false (PVar "i") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "starts")))) (EBinOp "<" (EVar "column") (ELit (LInt 0)))) (EVar "None") (EBlock (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "starts"))) (DoExpr (EIf (EBinOp ">" (EVar "column") (EBinOp "-" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "ends")) (EVar "start"))) (EVar "None") (EApp (EVar "Some") (EBinOp "+" (EVar "start") (EVar "column"))))))))))
(DTypeSig true "clampSourcePositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "clampSourcePositionToOffset" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") PWild) (PVar "line") (PVar "column")) (EBlock (DoLet false false (PVar "i") (EApp (EApp (EVar "max") (ELit (LInt 0))) (EApp (EApp (EVar "min") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "starts")) (ELit (LInt 1)))) (EBinOp "-" (EVar "line") (ELit (LInt 1)))))) (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "starts"))) (DoExpr (EBinOp "+" (EVar "start") (EApp (EApp (EVar "max") (ELit (LInt 0))) (EApp (EApp (EVar "min") (EBinOp "-" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "ends")) (EVar "start"))) (EVar "column")))))))
(DTypeSig true "offsetToUtf16Position" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "offsetToUtf16Position" ((PVar "index") (PVar "offset")) (EMatch (EVar "index") (arm (PCon "SourceIndex" (PVar "starts") PWild (PVar "prefixes")) () (EMatch (EApp (EApp (EVar "offsetToSourcePosition") (EVar "index")) (EVar "offset")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "line") PWild)) () (EBlock (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EVar "starts"))) (DoExpr (EApp (EVar "Some") (ETuple (EBinOp "-" (EVar "line") (ELit (LInt 1))) (EBinOp "-" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "offset")) (EVar "prefixes")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "start")) (EVar "prefixes"))))))))))))
(DTypeSig true "utf16PositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "utf16PositionToOffset" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") (PVar "prefixes")) (PVar "line") (PVar "column")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "line") (ELit (LInt 0))) (EBinOp ">=" (EVar "line") (EApp (EVar "arrayLength") (EVar "starts")))) (EBinOp "<" (EVar "column") (ELit (LInt 0)))) (EVar "None") (EBlock (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "starts"))) (DoLet false false (PVar "end") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "ends"))) (DoLet false false (PVar "target") (EBinOp "+" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "start")) (EVar "prefixes")) (EVar "column"))) (DoLet false false (PVar "offset") (EApp (EApp (EApp (EApp (EVar "floorIndex") (EVar "prefixes")) (EVar "target")) (EVar "start")) (EBinOp "+" (EVar "end") (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "offset") (EVar "start")) (EBinOp "/=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "offset")) (EVar "prefixes")) (EVar "target"))) (EVar "None") (EApp (EVar "Some") (EVar "offset")))))))
# MARK
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "toChars" false))))
(DData Abstract "SourceIndex" () ((variant "SourceIndex" (ConPos (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int"))))) ())
(DTypeSig false "indexGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "SourceIndex")))))))))
(DFunDef false "indexGo" ((PVar "chars") (PVar "i") (PVar "start") (PVar "units") (PVar "starts") (PVar "ends") (PVar "prefixes")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "chars"))) (EApp (EApp (EApp (EVar "SourceIndex") (EApp (EVar "fromList") (EApp (EVar "reverse") (EBinOp "::" (EVar "start") (EVar "starts"))))) (EApp (EVar "fromList") (EApp (EVar "reverse") (EBinOp "::" (EVar "i") (EVar "ends"))))) (EApp (EVar "fromList") (EApp (EVar "reverse") (EBinOp "::" (EVar "units") (EVar "prefixes"))))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "chars")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "chars")) (ELit (LChar "\n")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EBinOp "+" (EVar "units") (ELit (LInt 2)))) (EBinOp "::" (EVar "start") (EVar "starts"))) (EBinOp "::" (EVar "i") (EVar "ends"))) (EBinOp "::" (EBinOp "+" (EVar "units") (ELit (LInt 1))) (EBinOp "::" (EVar "units") (EVar "prefixes")))) (EIf (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (EBinOp "==" (EVar "c") (ELit (LChar "\n")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "units") (ELit (LInt 1)))) (EBinOp "::" (EVar "start") (EVar "starts"))) (EBinOp "::" (EVar "i") (EVar "ends"))) (EBinOp "::" (EVar "units") (EVar "prefixes"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "start")) (EBinOp "+" (EVar "units") (EIf (EBinOp ">" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 65535))) (ELit (LInt 2)) (ELit (LInt 1))))) (EVar "starts")) (EVar "ends")) (EBinOp "::" (EVar "units") (EVar "prefixes")))))))))
(DTypeSig true "indexSource" (TyFun (TyCon "String") (TyCon "SourceIndex")))
(DFunDef false "indexSource" ((PVar "source")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EApp (EVar "toChars") (EVar "source"))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)) (EListLit)) (EListLit)))
(DTypeSig false "floorIndex" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "floorIndex" ((PVar "values") (PVar "target") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "lo") (EVar "hi")) (EBinOp "-" (EVar "lo") (ELit (LInt 1))) (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EVar "lo") (EVar "hi")) (ELit (LInt 2)))) (DoExpr (EIf (EBinOp "<=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "mid")) (EVar "values")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "floorIndex") (EVar "values")) (EVar "target")) (EBinOp "+" (EVar "mid") (ELit (LInt 1)))) (EVar "hi")) (EApp (EApp (EApp (EApp (EVar "floorIndex") (EVar "values")) (EVar "target")) (EVar "lo")) (EVar "mid")))))))
(DTypeSig true "offsetToSourcePosition" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "offsetToSourcePosition" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") PWild) (PVar "offset")) (EBlock (DoLet false false (PVar "line") (EApp (EApp (EApp (EApp (EVar "floorIndex") (EVar "starts")) (EVar "offset")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "starts")))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "line") (ELit (LInt 0))) (EBinOp ">" (EVar "offset") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "ends")))) (EVar "None") (EApp (EVar "Some") (ETuple (EBinOp "+" (EVar "line") (ELit (LInt 1))) (EBinOp "-" (EVar "offset") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "starts")))))))))
(DTypeSig true "sourcePositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "sourcePositionToOffset" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") PWild) (PVar "line") (PVar "column")) (EBlock (DoLet false false (PVar "i") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "starts")))) (EBinOp "<" (EVar "column") (ELit (LInt 0)))) (EVar "None") (EBlock (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "starts"))) (DoExpr (EIf (EBinOp ">" (EVar "column") (EBinOp "-" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "ends")) (EVar "start"))) (EVar "None") (EApp (EVar "Some") (EBinOp "+" (EVar "start") (EVar "column"))))))))))
(DTypeSig true "clampSourcePositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "clampSourcePositionToOffset" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") PWild) (PVar "line") (PVar "column")) (EBlock (DoLet false false (PVar "i") (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EApp (EApp (EMethodRef "min") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "starts")) (ELit (LInt 1)))) (EBinOp "-" (EVar "line") (ELit (LInt 1)))))) (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "starts"))) (DoExpr (EBinOp "+" (EVar "start") (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EApp (EApp (EMethodRef "min") (EBinOp "-" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "ends")) (EVar "start"))) (EVar "column")))))))
(DTypeSig true "offsetToUtf16Position" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "offsetToUtf16Position" ((PVar "index") (PVar "offset")) (EMatch (EMethodRef "index") (arm (PCon "SourceIndex" (PVar "starts") PWild (PVar "prefixes")) () (EMatch (EApp (EApp (EVar "offsetToSourcePosition") (EMethodRef "index")) (EVar "offset")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "line") PWild)) () (EBlock (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EVar "starts"))) (DoExpr (EApp (EVar "Some") (ETuple (EBinOp "-" (EVar "line") (ELit (LInt 1))) (EBinOp "-" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "offset")) (EVar "prefixes")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "start")) (EVar "prefixes"))))))))))))
(DTypeSig true "utf16PositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "utf16PositionToOffset" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") (PVar "prefixes")) (PVar "line") (PVar "column")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "line") (ELit (LInt 0))) (EBinOp ">=" (EVar "line") (EApp (EVar "arrayLength") (EVar "starts")))) (EBinOp "<" (EVar "column") (ELit (LInt 0)))) (EVar "None") (EBlock (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "starts"))) (DoLet false false (PVar "end") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "ends"))) (DoLet false false (PVar "target") (EBinOp "+" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "start")) (EVar "prefixes")) (EVar "column"))) (DoLet false false (PVar "offset") (EApp (EApp (EApp (EApp (EVar "floorIndex") (EVar "prefixes")) (EVar "target")) (EVar "start")) (EBinOp "+" (EVar "end") (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "offset") (EVar "start")) (EBinOp "/=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "offset")) (EVar "prefixes")) (EVar "target"))) (EVar "None") (EApp (EVar "Some") (EVar "offset")))))))
