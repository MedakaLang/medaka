# META
source_lines=196
stages=DESUGAR,MARK
# SOURCE
import array.{fromList}
import list.{reverse}
import string.{toChars, StrCursor, startCursor, nextChar}

sourceEndGo : StrCursor -> Int -> Int -> Bool -> (Int, Int)
sourceEndGo cursor line col afterCR = match nextChar cursor
  None => (line, col)
  Some (c, next) =>
    if c == '\r' then
      sourceEndGo next (line + 1) 0 True
    else if c == '\n' then
      sourceEndGo next (if afterCR then line else line + 1) 0 False
    else
      sourceEndGo next line (col + (if charCode c > 65535 then 2 else 1)) False

export
sourceEndUtf16Position : String -> (Int, Int)
sourceEndUtf16Position source = sourceEndGo (startCursor source) 0 0 False

export data SourceIndex = SourceIndex (Array Int) (Array Int) (Array Int)

-- Starts and ends exclude newline codepoints; prefixes count UTF-16 units.
data ScanState = ScanState { offset : Int, lineStart : Int, units : Int }

indexGo : Array Char ->
  ScanState ->
  List Int ->
  List Int ->
  List Int ->
  SourceIndex
indexGo chars state starts ends prefixes =
  let i = state.offset
  let start = state.lineStart
  let units = state.units
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
        ScanState { offset = i + 2, lineStart = i + 2, units = units + 2 }
        (start :: starts)
        (i :: ends)
        (units + 1 :: units :: prefixes)
    else if c == '\r' || c == '\n' then
      indexGo
        chars
        ScanState { offset = i + 1, lineStart = i + 1, units = units + 1 }
        (start :: starts)
        (i :: ends)
        (units :: prefixes)
    else
      indexGo
        chars
        ScanState {
          offset = i + 1,
          lineStart = start,
          units = units + (if charCode c > 65535 then 2 else 1),
        }
        starts
        ends
        (units :: prefixes)

export
indexSource : String -> SourceIndex
indexSource source =
  indexGo
    (toChars source)
    ScanState { offset = 0, lineStart = 0, units = 0 }
    []
    []
    []

-- First index in [lo, hi) whose value exceeds target, or hi.
upperBound : Array Int -> Int -> Int -> Int -> Int
upperBound values target lo hi =
  if lo >= hi then
    lo
  else
    let mid = (lo + hi) / 2
    if arrayGetUnsafe mid values <= target then
      upperBound values target (mid + 1) hi
    else
      upperBound values target lo mid

export
offsetToSourcePosition : SourceIndex -> Int -> Option (Int, Int)
offsetToSourcePosition (SourceIndex starts ends _) offset =
  let upper = upperBound starts offset 0 (arrayLength starts)
  let line = upper - 1
  if upper == 0 || offset > arrayGetUnsafe line ends then
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
  SourceIndex starts _ prefixes => do
    (line, _) <- offsetToSourcePosition index offset
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
    let upper = upperBound prefixes target start (end + 1)
    let offset = upper - 1
    if upper == start || arrayGetUnsafe offset prefixes /= target then
      None
    else
      Some offset

-- Precompute the sorted array of line-start char offsets for a source string:
-- offset 0, plus the offset after each LF, CRLF, or lone CR. One O(N) scan. Fed to
-- `offsetToLineColFast` so the located-parse pass can resolve each offset in
-- O(log N) instead of re-walking from 0 (which made `locOfSpan` O(N²)).
export
lineStartsOf : String -> Array Int
lineStartsOf s =
  let src = stringToChars s
  let len = arrayLength src
  arrayFromList (0 :: lineStartsGo src len 0)

lineStartsGo : Array Char -> Int -> Int -> List Int
lineStartsGo src len i
  | i >= len = []
  | arrayGetUnsafe i src == '\r'
    && i + 1 < len
    && arrayGetUnsafe (i + 1) src == '\n' =
    i + 2 :: lineStartsGo src len (i + 2)
  | arrayGetUnsafe i src == '\r' = i + 1 :: lineStartsGo src len (i + 1)
  | arrayGetUnsafe i src == '\n' = i + 1 :: lineStartsGo src len (i + 1)
  | otherwise = lineStartsGo src len (i + 1)

-- Resolve a 0-based char offset to a (1-based line, 0-based column) pair using a
-- precomputed line-starts array (`lineStartsOf`), by binary search.  This is
-- The line is one plus the index of the last start at or before `off`;
-- the column is `off` minus that start.
export
offsetToLineColFast : Array Int -> Int -> (Int, Int)
offsetToLineColFast lineStarts off =
  let idx = lineStartIndex lineStarts off
  (idx + 1, off - arrayGetUnsafe idx lineStarts)

-- Rightmost index `idx` in [lo, hi] with `lineStarts[idx] <= off`.
-- `lineStarts[0]` is 0 and `off >= 0`, so such an index always exists in range.
lineStartSearch : Array Int -> Int -> Int -> Int -> Int
lineStartSearch arr off lo hi
  | lo >= hi = lo
  | otherwise =
    let mid = (lo + hi + 1) / 2
    if arrayGetUnsafe mid arr <= off then
      lineStartSearch arr off mid hi
    else
      lineStartSearch arr off lo (mid - 1)

export
lineStartIndex : Array Int -> Int -> Int
lineStartIndex lineStarts off =
  lineStartSearch lineStarts off 0 (arrayLength lineStarts - 1)
# DESUGAR
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "toChars" false) (mem "StrCursor" false) (mem "startCursor" false) (mem "nextChar" false))))
(DTypeSig false "sourceEndGo" (TyFun (TyCon "StrCursor") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "sourceEndGo" ((PVar "cursor") (PVar "line") (PVar "col") (PVar "afterCR")) (EMatch (EApp (EVar "nextChar") (EVar "cursor")) (arm (PCon "None") () (ETuple (EVar "line") (EVar "col"))) (arm (PCon "Some" (PTuple (PVar "c") (PVar "next"))) () (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (EApp (EApp (EApp (EApp (EVar "sourceEndGo") (EVar "next")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (ELit (LInt 0))) (EVar "True")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EVar "sourceEndGo") (EVar "next")) (EIf (EVar "afterCR") (EVar "line") (EBinOp "+" (EVar "line") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "False")) (EApp (EApp (EApp (EApp (EVar "sourceEndGo") (EVar "next")) (EVar "line")) (EBinOp "+" (EVar "col") (EIf (EBinOp ">" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 65535))) (ELit (LInt 2)) (ELit (LInt 1))))) (EVar "False")))))))
(DTypeSig true "sourceEndUtf16Position" (TyFun (TyCon "String") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "sourceEndUtf16Position" ((PVar "source")) (EApp (EApp (EApp (EApp (EVar "sourceEndGo") (EApp (EVar "startCursor") (EVar "source"))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "False")))
(DData Abstract "SourceIndex" () ((variant "SourceIndex" (ConPos (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int"))))) ())
(DData Private "ScanState" () ((variant "ScanState" (ConNamed (field "offset" (TyCon "Int")) (field "lineStart" (TyCon "Int")) (field "units" (TyCon "Int"))))) ())
(DTypeSig false "indexGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "ScanState") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "SourceIndex")))))))
(DFunDef false "indexGo" ((PVar "chars") (PVar "state") (PVar "starts") (PVar "ends") (PVar "prefixes")) (EBlock (DoLet false false (PVar "i") (EFieldAccess (EVar "state") "offset")) (DoLet false false (PVar "start") (EFieldAccess (EVar "state") "lineStart")) (DoLet false false (PVar "units") (EFieldAccess (EVar "state") "units")) (DoExpr (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "chars"))) (EApp (EApp (EApp (EVar "SourceIndex") (EApp (EVar "fromList") (EApp (EVar "reverse") (EBinOp "::" (EVar "start") (EVar "starts"))))) (EApp (EVar "fromList") (EApp (EVar "reverse") (EBinOp "::" (EVar "i") (EVar "ends"))))) (EApp (EVar "fromList") (EApp (EVar "reverse") (EBinOp "::" (EVar "units") (EVar "prefixes"))))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "chars")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "chars")) (ELit (LChar "\n")))) (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EVar "chars")) (ERecordCreate "ScanState" ((fa "offset" (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (fa "lineStart" (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (fa "units" (EBinOp "+" (EVar "units") (ELit (LInt 2))))))) (EBinOp "::" (EVar "start") (EVar "starts"))) (EBinOp "::" (EVar "i") (EVar "ends"))) (EBinOp "::" (EBinOp "+" (EVar "units") (ELit (LInt 1))) (EBinOp "::" (EVar "units") (EVar "prefixes")))) (EIf (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (EBinOp "==" (EVar "c") (ELit (LChar "\n")))) (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EVar "chars")) (ERecordCreate "ScanState" ((fa "offset" (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (fa "lineStart" (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (fa "units" (EBinOp "+" (EVar "units") (ELit (LInt 1))))))) (EBinOp "::" (EVar "start") (EVar "starts"))) (EBinOp "::" (EVar "i") (EVar "ends"))) (EBinOp "::" (EVar "units") (EVar "prefixes"))) (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EVar "chars")) (ERecordCreate "ScanState" ((fa "offset" (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (fa "lineStart" (EVar "start")) (fa "units" (EBinOp "+" (EVar "units") (EIf (EBinOp ">" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 65535))) (ELit (LInt 2)) (ELit (LInt 1)))))))) (EVar "starts")) (EVar "ends")) (EBinOp "::" (EVar "units") (EVar "prefixes")))))))))))
(DTypeSig true "indexSource" (TyFun (TyCon "String") (TyCon "SourceIndex")))
(DFunDef false "indexSource" ((PVar "source")) (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EApp (EVar "toChars") (EVar "source"))) (ERecordCreate "ScanState" ((fa "offset" (ELit (LInt 0))) (fa "lineStart" (ELit (LInt 0))) (fa "units" (ELit (LInt 0)))))) (EListLit)) (EListLit)) (EListLit)))
(DTypeSig false "upperBound" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "upperBound" ((PVar "values") (PVar "target") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "lo") (EVar "hi")) (EVar "lo") (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EVar "lo") (EVar "hi")) (ELit (LInt 2)))) (DoExpr (EIf (EBinOp "<=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "mid")) (EVar "values")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "upperBound") (EVar "values")) (EVar "target")) (EBinOp "+" (EVar "mid") (ELit (LInt 1)))) (EVar "hi")) (EApp (EApp (EApp (EApp (EVar "upperBound") (EVar "values")) (EVar "target")) (EVar "lo")) (EVar "mid")))))))
(DTypeSig true "offsetToSourcePosition" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "offsetToSourcePosition" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") PWild) (PVar "offset")) (EBlock (DoLet false false (PVar "upper") (EApp (EApp (EApp (EApp (EVar "upperBound") (EVar "starts")) (EVar "offset")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "starts")))) (DoLet false false (PVar "line") (EBinOp "-" (EVar "upper") (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "upper") (ELit (LInt 0))) (EBinOp ">" (EVar "offset") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "ends")))) (EVar "None") (EApp (EVar "Some") (ETuple (EBinOp "+" (EVar "line") (ELit (LInt 1))) (EBinOp "-" (EVar "offset") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "starts")))))))))
(DTypeSig true "sourcePositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "sourcePositionToOffset" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") PWild) (PVar "line") (PVar "column")) (EBlock (DoLet false false (PVar "i") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "starts")))) (EBinOp "<" (EVar "column") (ELit (LInt 0)))) (EVar "None") (EBlock (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "starts"))) (DoExpr (EIf (EBinOp ">" (EVar "column") (EBinOp "-" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "ends")) (EVar "start"))) (EVar "None") (EApp (EVar "Some") (EBinOp "+" (EVar "start") (EVar "column"))))))))))
(DTypeSig true "clampSourcePositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "clampSourcePositionToOffset" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") PWild) (PVar "line") (PVar "column")) (EBlock (DoLet false false (PVar "i") (EApp (EApp (EVar "max") (ELit (LInt 0))) (EApp (EApp (EVar "min") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "starts")) (ELit (LInt 1)))) (EBinOp "-" (EVar "line") (ELit (LInt 1)))))) (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "starts"))) (DoExpr (EBinOp "+" (EVar "start") (EApp (EApp (EVar "max") (ELit (LInt 0))) (EApp (EApp (EVar "min") (EBinOp "-" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "ends")) (EVar "start"))) (EVar "column")))))))
(DTypeSig true "offsetToUtf16Position" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "offsetToUtf16Position" ((PVar "index") (PVar "offset")) (EMatch (EVar "index") (arm (PCon "SourceIndex" (PVar "starts") PWild (PVar "prefixes")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "offsetToSourcePosition") (EVar "index")) (EVar "offset"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "line") PWild) () (ELet false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EVar "starts")) (EApp (EVar "Some") (ETuple (EBinOp "-" (EVar "line") (ELit (LInt 1))) (EBinOp "-" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "offset")) (EVar "prefixes")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "start")) (EVar "prefixes")))))))))))))
(DTypeSig true "utf16PositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "utf16PositionToOffset" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") (PVar "prefixes")) (PVar "line") (PVar "column")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "line") (ELit (LInt 0))) (EBinOp ">=" (EVar "line") (EApp (EVar "arrayLength") (EVar "starts")))) (EBinOp "<" (EVar "column") (ELit (LInt 0)))) (EVar "None") (EBlock (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "starts"))) (DoLet false false (PVar "end") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "ends"))) (DoLet false false (PVar "target") (EBinOp "+" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "start")) (EVar "prefixes")) (EVar "column"))) (DoLet false false (PVar "upper") (EApp (EApp (EApp (EApp (EVar "upperBound") (EVar "prefixes")) (EVar "target")) (EVar "start")) (EBinOp "+" (EVar "end") (ELit (LInt 1))))) (DoLet false false (PVar "offset") (EBinOp "-" (EVar "upper") (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "upper") (EVar "start")) (EBinOp "/=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "offset")) (EVar "prefixes")) (EVar "target"))) (EVar "None") (EApp (EVar "Some") (EVar "offset")))))))
(DTypeSig true "lineStartsOf" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "lineStartsOf" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoExpr (EApp (EVar "arrayFromList") (EBinOp "::" (ELit (LInt 0)) (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (ELit (LInt 0))))))))
(DTypeSig false "lineStartsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "lineStartsGo" ((PVar "src") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EListLit) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")) (ELit (LChar "\r"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "src")) (ELit (LChar "\n")))) (EBinOp "::" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")) (ELit (LChar "\r"))) (EBinOp "::" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")) (ELit (LChar "\n"))) (EBinOp "::" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig true "offsetToLineColFast" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offsetToLineColFast" ((PVar "lineStarts") (PVar "off")) (EBlock (DoLet false false (PVar "idx") (EApp (EApp (EVar "lineStartIndex") (EVar "lineStarts")) (EVar "off"))) (DoExpr (ETuple (EBinOp "+" (EVar "idx") (ELit (LInt 1))) (EBinOp "-" (EVar "off") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "lineStarts")))))))
(DTypeSig false "lineStartSearch" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "lineStartSearch" ((PVar "arr") (PVar "off") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "lo") (EVar "hi")) (EVar "lo") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EBinOp "+" (EVar "lo") (EVar "hi")) (ELit (LInt 1))) (ELit (LInt 2)))) (DoExpr (EIf (EBinOp "<=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "mid")) (EVar "arr")) (EVar "off")) (EApp (EApp (EApp (EApp (EVar "lineStartSearch") (EVar "arr")) (EVar "off")) (EVar "mid")) (EVar "hi")) (EApp (EApp (EApp (EApp (EVar "lineStartSearch") (EVar "arr")) (EVar "off")) (EVar "lo")) (EBinOp "-" (EVar "mid") (ELit (LInt 1))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "lineStartIndex" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lineStartIndex" ((PVar "lineStarts") (PVar "off")) (EApp (EApp (EApp (EApp (EVar "lineStartSearch") (EVar "lineStarts")) (EVar "off")) (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "lineStarts")) (ELit (LInt 1)))))
# MARK
(DUse false (UseGroup ("array") ((mem "fromList" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "toChars" false) (mem "StrCursor" false) (mem "startCursor" false) (mem "nextChar" false))))
(DTypeSig false "sourceEndGo" (TyFun (TyCon "StrCursor") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "sourceEndGo" ((PVar "cursor") (PVar "line") (PVar "col") (PVar "afterCR")) (EMatch (EApp (EVar "nextChar") (EVar "cursor")) (arm (PCon "None") () (ETuple (EVar "line") (EVar "col"))) (arm (PCon "Some" (PTuple (PVar "c") (PVar "next"))) () (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (EApp (EApp (EApp (EApp (EVar "sourceEndGo") (EVar "next")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (ELit (LInt 0))) (EVar "True")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\n"))) (EApp (EApp (EApp (EApp (EVar "sourceEndGo") (EVar "next")) (EIf (EVar "afterCR") (EVar "line") (EBinOp "+" (EVar "line") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "False")) (EApp (EApp (EApp (EApp (EVar "sourceEndGo") (EVar "next")) (EVar "line")) (EBinOp "+" (EVar "col") (EIf (EBinOp ">" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 65535))) (ELit (LInt 2)) (ELit (LInt 1))))) (EVar "False")))))))
(DTypeSig true "sourceEndUtf16Position" (TyFun (TyCon "String") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "sourceEndUtf16Position" ((PVar "source")) (EApp (EApp (EApp (EApp (EVar "sourceEndGo") (EApp (EVar "startCursor") (EVar "source"))) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "False")))
(DData Abstract "SourceIndex" () ((variant "SourceIndex" (ConPos (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Array") (TyCon "Int"))))) ())
(DData Private "ScanState" () ((variant "ScanState" (ConNamed (field "offset" (TyCon "Int")) (field "lineStart" (TyCon "Int")) (field "units" (TyCon "Int"))))) ())
(DTypeSig false "indexGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "ScanState") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "SourceIndex")))))))
(DFunDef false "indexGo" ((PVar "chars") (PVar "state") (PVar "starts") (PVar "ends") (PVar "prefixes")) (EBlock (DoLet false false (PVar "i") (EFieldAccess (EVar "state") "offset")) (DoLet false false (PVar "start") (EFieldAccess (EVar "state") "lineStart")) (DoLet false false (PVar "units") (EFieldAccess (EVar "state") "units")) (DoExpr (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "chars"))) (EApp (EApp (EApp (EVar "SourceIndex") (EApp (EVar "fromList") (EApp (EVar "reverse") (EBinOp "::" (EVar "start") (EVar "starts"))))) (EApp (EVar "fromList") (EApp (EVar "reverse") (EBinOp "::" (EVar "i") (EVar "ends"))))) (EApp (EVar "fromList") (EApp (EVar "reverse") (EBinOp "::" (EVar "units") (EVar "prefixes"))))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "chars")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "chars")) (ELit (LChar "\n")))) (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EVar "chars")) (ERecordCreate "ScanState" ((fa "offset" (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (fa "lineStart" (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (fa "units" (EBinOp "+" (EVar "units") (ELit (LInt 2))))))) (EBinOp "::" (EVar "start") (EVar "starts"))) (EBinOp "::" (EVar "i") (EVar "ends"))) (EBinOp "::" (EBinOp "+" (EVar "units") (ELit (LInt 1))) (EBinOp "::" (EVar "units") (EVar "prefixes")))) (EIf (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (EBinOp "==" (EVar "c") (ELit (LChar "\n")))) (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EVar "chars")) (ERecordCreate "ScanState" ((fa "offset" (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (fa "lineStart" (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (fa "units" (EBinOp "+" (EVar "units") (ELit (LInt 1))))))) (EBinOp "::" (EVar "start") (EVar "starts"))) (EBinOp "::" (EVar "i") (EVar "ends"))) (EBinOp "::" (EVar "units") (EVar "prefixes"))) (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EVar "chars")) (ERecordCreate "ScanState" ((fa "offset" (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (fa "lineStart" (EVar "start")) (fa "units" (EBinOp "+" (EVar "units") (EIf (EBinOp ">" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 65535))) (ELit (LInt 2)) (ELit (LInt 1)))))))) (EVar "starts")) (EVar "ends")) (EBinOp "::" (EVar "units") (EVar "prefixes")))))))))))
(DTypeSig true "indexSource" (TyFun (TyCon "String") (TyCon "SourceIndex")))
(DFunDef false "indexSource" ((PVar "source")) (EApp (EApp (EApp (EApp (EApp (EVar "indexGo") (EApp (EVar "toChars") (EVar "source"))) (ERecordCreate "ScanState" ((fa "offset" (ELit (LInt 0))) (fa "lineStart" (ELit (LInt 0))) (fa "units" (ELit (LInt 0)))))) (EListLit)) (EListLit)) (EListLit)))
(DTypeSig false "upperBound" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "upperBound" ((PVar "values") (PVar "target") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "lo") (EVar "hi")) (EVar "lo") (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EVar "lo") (EVar "hi")) (ELit (LInt 2)))) (DoExpr (EIf (EBinOp "<=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "mid")) (EVar "values")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "upperBound") (EVar "values")) (EVar "target")) (EBinOp "+" (EVar "mid") (ELit (LInt 1)))) (EVar "hi")) (EApp (EApp (EApp (EApp (EVar "upperBound") (EVar "values")) (EVar "target")) (EVar "lo")) (EVar "mid")))))))
(DTypeSig true "offsetToSourcePosition" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "offsetToSourcePosition" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") PWild) (PVar "offset")) (EBlock (DoLet false false (PVar "upper") (EApp (EApp (EApp (EApp (EVar "upperBound") (EVar "starts")) (EVar "offset")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "starts")))) (DoLet false false (PVar "line") (EBinOp "-" (EVar "upper") (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "upper") (ELit (LInt 0))) (EBinOp ">" (EVar "offset") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "ends")))) (EVar "None") (EApp (EVar "Some") (ETuple (EBinOp "+" (EVar "line") (ELit (LInt 1))) (EBinOp "-" (EVar "offset") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "starts")))))))))
(DTypeSig true "sourcePositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "sourcePositionToOffset" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") PWild) (PVar "line") (PVar "column")) (EBlock (DoLet false false (PVar "i") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "starts")))) (EBinOp "<" (EVar "column") (ELit (LInt 0)))) (EVar "None") (EBlock (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "starts"))) (DoExpr (EIf (EBinOp ">" (EVar "column") (EBinOp "-" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "ends")) (EVar "start"))) (EVar "None") (EApp (EVar "Some") (EBinOp "+" (EVar "start") (EVar "column"))))))))))
(DTypeSig true "clampSourcePositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "clampSourcePositionToOffset" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") PWild) (PVar "line") (PVar "column")) (EBlock (DoLet false false (PVar "i") (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EApp (EApp (EMethodRef "min") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "starts")) (ELit (LInt 1)))) (EBinOp "-" (EVar "line") (ELit (LInt 1)))))) (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "starts"))) (DoExpr (EBinOp "+" (EVar "start") (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EApp (EApp (EMethodRef "min") (EBinOp "-" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "ends")) (EVar "start"))) (EVar "column")))))))
(DTypeSig true "offsetToUtf16Position" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "offsetToUtf16Position" ((PVar "index") (PVar "offset")) (EMatch (EMethodRef "index") (arm (PCon "SourceIndex" (PVar "starts") PWild (PVar "prefixes")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "offsetToSourcePosition") (EMethodRef "index")) (EVar "offset"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "line") PWild) () (ELet false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EVar "starts")) (EApp (EVar "Some") (ETuple (EBinOp "-" (EVar "line") (ELit (LInt 1))) (EBinOp "-" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "offset")) (EVar "prefixes")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "start")) (EVar "prefixes")))))))))))))
(DTypeSig true "utf16PositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "utf16PositionToOffset" ((PCon "SourceIndex" (PVar "starts") (PVar "ends") (PVar "prefixes")) (PVar "line") (PVar "column")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "line") (ELit (LInt 0))) (EBinOp ">=" (EVar "line") (EApp (EVar "arrayLength") (EVar "starts")))) (EBinOp "<" (EVar "column") (ELit (LInt 0)))) (EVar "None") (EBlock (DoLet false false (PVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "starts"))) (DoLet false false (PVar "end") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "line")) (EVar "ends"))) (DoLet false false (PVar "target") (EBinOp "+" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "start")) (EVar "prefixes")) (EVar "column"))) (DoLet false false (PVar "upper") (EApp (EApp (EApp (EApp (EVar "upperBound") (EVar "prefixes")) (EVar "target")) (EVar "start")) (EBinOp "+" (EVar "end") (ELit (LInt 1))))) (DoLet false false (PVar "offset") (EBinOp "-" (EVar "upper") (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "upper") (EVar "start")) (EBinOp "/=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "offset")) (EVar "prefixes")) (EVar "target"))) (EVar "None") (EApp (EVar "Some") (EVar "offset")))))))
(DTypeSig true "lineStartsOf" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "lineStartsOf" ((PVar "s")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "src"))) (DoExpr (EApp (EVar "arrayFromList") (EBinOp "::" (ELit (LInt 0)) (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (ELit (LInt 0))))))))
(DTypeSig false "lineStartsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "lineStartsGo" ((PVar "src") (PVar "len") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EListLit) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")) (ELit (LChar "\r"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "len"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "src")) (ELit (LChar "\n")))) (EBinOp "::" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")) (ELit (LChar "\r"))) (EBinOp "::" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "src")) (ELit (LChar "\n"))) (EBinOp "::" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lineStartsGo") (EVar "src")) (EVar "len")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig true "offsetToLineColFast" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offsetToLineColFast" ((PVar "lineStarts") (PVar "off")) (EBlock (DoLet false false (PVar "idx") (EApp (EApp (EVar "lineStartIndex") (EVar "lineStarts")) (EVar "off"))) (DoExpr (ETuple (EBinOp "+" (EVar "idx") (ELit (LInt 1))) (EBinOp "-" (EVar "off") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "lineStarts")))))))
(DTypeSig false "lineStartSearch" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "lineStartSearch" ((PVar "arr") (PVar "off") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "lo") (EVar "hi")) (EVar "lo") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EBinOp "+" (EVar "lo") (EVar "hi")) (ELit (LInt 1))) (ELit (LInt 2)))) (DoExpr (EIf (EBinOp "<=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "mid")) (EVar "arr")) (EVar "off")) (EApp (EApp (EApp (EApp (EVar "lineStartSearch") (EVar "arr")) (EVar "off")) (EVar "mid")) (EVar "hi")) (EApp (EApp (EApp (EApp (EVar "lineStartSearch") (EVar "arr")) (EVar "off")) (EVar "lo")) (EBinOp "-" (EVar "mid") (ELit (LInt 1))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "lineStartIndex" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lineStartIndex" ((PVar "lineStarts") (PVar "off")) (EApp (EApp (EApp (EApp (EVar "lineStartSearch") (EVar "lineStarts")) (EVar "off")) (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "lineStarts")) (ELit (LInt 1)))))
