# META
source_lines=178
stages=DESUGAR,MARK
# SOURCE
{- | Reading and writing delimiter-separated text: CSV, and TSV by choosing a
   tab as the delimiter.

   A table is a `List (List String)`: one inner list per row, one `String`
   per field. `parse` and `parseWith` read RFC 4180 quoting: a field may be
   wrapped in double quotes, a doubled quote inside it stands for one quote,
   and a quoted field may contain the delimiter and line breaks. LF and CRLF
   both end a row, and a final line break does not add an empty row. An empty
   line is the row `[]`, and the empty string has no rows.

   `render` and `renderWith` write a table back, quoting a field only when it
   has to be, and ending every row with LF, never CRLF. A row holding a single
   empty field is written as `""`, so that it does not read back as the empty
   row: `parse (render rows)` is `Ok rows` for any table.

   Reading is lenient in the way Python's csv reader is. Whitespace around a
   field is kept. A quote inside an unquoted field is an ordinary character.
   Text after the closing quote of a quoted field joins the field, so a quoted
   "a" followed directly by b reads as the one field "ab". A lone CR is an
   ordinary character, except a CR that ends the input, which ends the
   row as it does in Python. The one error is a quoted field that never
   closes. -}

import core.{Result(..), Option(..)}
import list.{reverse}
import string.{
  split, fromChar, startsWith, drop, contains, replaceAll, join, concat, stripCR
}

-- # Reading

{- | Reads comma-separated text into rows of fields.

   > parse "a,b\r\n1,2\r\n"
   Ok [["a", "b"], ["1", "2"]]
   > parse "name,note\nann,\"hello, world\"\n"
   Ok [["name", "note"], ["ann", "hello, world"]]
   > parse "a,\"b"
   Err "line 1: unterminated quoted field" -}
export
parse : String -> Result String (List (List String))
parse = parseWith ','

{- | Reads delimiter-separated text with the given delimiter, with the same
   quoting rules as `parse`. A tab reads TSV.

   The delimiter may not be a double quote, LF or CR: those give an `Err`.
   An unterminated quote gives `Err "line N: unterminated quoted field"`,
   where `N` is the 1-based line holding that field's opening quote.

   > parseWith '\t' "a\tb\n\"x\ty\"\tz\n"
   Ok [["a", "b"], ["x\ty", "z"]] -}
export
parseWith : Char -> String -> Result String (List (List String))
parseWith d text
  | d == '"' = Err "delimiter cannot be a double quote"
  | d == '\n' = Err "delimiter cannot be a line feed"
  | d == '\r' = Err "delimiter cannot be a carriage return"
  | otherwise = parseRows (fromChar d) (dropLastEmpty (split "\n" text))

-- Lines are cut on LF alone (a CR stays in the line); the empty piece after a
-- final LF is not a line.
dropLastEmpty : List String -> List String
dropLastEmpty [] = []
dropLastEmpty [""] = []
dropLastEmpty (x :: xs) = x :: dropLastEmpty xs

-- The reader state: finished rows (newest first), the fields of the current
-- row (newest first), the open quoted field if there is one, as its raw text
-- so far (joiner included) and the line its quote opened on, and the number of
-- lines read.
data St = St (List (List String)) (List String) (Option (String, Int)) Int

parseRows : String -> List String -> Result String (List (List String))
parseRows dl ls = match fold (stepLine dl) (St [] [] None 0) ls
  St rows _ None _ => Ok (reverse rows)
  St _ _ (Some (_, n)) _ => Err "line \{n}: unterminated quoted field"

stepLine : String -> St -> String -> St
stepLine dl (St rows fs pend n) line = match pend
  None =>
    if stripCR line == "" then
      St ([] :: rows) [] None (n + 1)
    else
      finishLine dl rows [] None (n + 1) line
  Some _ => finishLine dl rows fs pend (n + 1) line

finishLine : String ->
  List (List String) ->
  List String ->
  Option (String, Int) ->
  Int ->
  String ->
  St
finishLine dl rows fs pend n line = match scan dl n fs pend (split dl line)
  (fs2, None) => St (reverse fs2 :: rows) [] None n
  (fs2, p) => St rows fs2 p n

-- Walks the delimiter-separated pieces of one line. A piece that opens a
-- quoted field which does not close on it is carried forward, with the
-- delimiter (between pieces) or LF (at the end of the line) that was cut.
scan : String ->
  Int ->
  List String ->
  Option (String, Int) ->
  List String ->
  (List String, Option (String, Int))
scan _ _ fs pend [] = (fs, pend)
scan dl n fs pend (p :: rest) =
  let raw = match pend
    None => p
    Some (r, _) => r ++ p
  let opened = match pend
    None => n
    Some (_, m) => m
  let last = rest == []
  let shown = if last then stripCR raw else raw
  match field shown
    Some v => scan dl n (v :: fs) None rest
    None =>
      if last then
        (fs, Some (raw ++ "\n", opened))
      else
        scan dl n fs (Some (raw ++ dl, opened)) rest

-- The value of a complete field, or None when it opens a quote that is still
-- open. An unquoted field is its own value.
field : String -> Option String
field raw =
  if startsWith "\"" raw then quoted (split "\"" (drop 1 raw)) "" else Some raw

-- The pieces of a quoted field's body cut at every quote. The first piece is
-- inside the quotes. A quote followed by an empty piece and then more is a
-- doubled quote; any other quote closes the field and the rest is literal.
quoted : List String -> String -> Option String
quoted [] _ = None
quoted [_] _ = None
quoted (s :: "" :: more@(_ :: _)) acc = quoted more "\{acc}\{s}\""
quoted (s :: tail) acc = Some (acc ++ s ++ join "\"" tail)

-- # Writing

{- | Writes rows as comma-separated text, one LF-terminated line per row.

   A field is quoted when it contains a comma, a double quote, CR or LF, and
   its inner quotes are doubled. Every row ends in LF, not CRLF, so that the
   output compares cleanly with Unix tools. A row with one empty field is
   written as `""`, because an empty line reads back as the empty row.

   > render [["a", "b"], ["x,y", "say \"hi\""]]
   "a,b\n\"x,y\",\"say \"\"hi\"\"\"\n"
   > render [[""], []]
   "\"\"\n\n" -}
export
render : List (List String) -> String
render = renderWith ','

{- | Writes rows with the given delimiter. A tab writes TSV.

   A double quote, LF or CR as the delimiter gives output that does not read
   back; this is unspecified.

   > renderWith '\t' [["a", "b c"], ["x\ty", "z"]]
   "a\tb c\n\"x\ty\"\tz\n" -}
export
renderWith : Char -> List (List String) -> String
renderWith d rows = concat (map (renderRow (fromChar d)) rows)

renderRow : String -> List String -> String
renderRow _ [""] = "\"\"\n"
renderRow dl row = join dl (map (quoteField dl) row) ++ "\n"

quoteField : String -> String -> String
quoteField dl f =
  if contains dl f || contains "\"" f || contains "\r" f || contains "\n" f then
    "\"" ++ replaceAll "\"" "\"\"" f ++ "\""
  else
    f
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Result" true) (mem "Option" true))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "fromChar" false) (mem "startsWith" false) (mem "drop" false) (mem "contains" false) (mem "replaceAll" false) (mem "join" false) (mem "concat" false) (mem "stripCR" false))))
(DTypeSig true "parse" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "parse" () (EApp (EVar "parseWith") (ELit (LChar ","))))
(DTypeSig true "parseWith" (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "parseWith" ((PVar "d") (PVar "text")) (EIf (EBinOp "==" (EVar "d") (ELit (LChar "\""))) (EApp (EVar "Err") (ELit (LString "delimiter cannot be a double quote"))) (EIf (EBinOp "==" (EVar "d") (ELit (LChar "\n"))) (EApp (EVar "Err") (ELit (LString "delimiter cannot be a line feed"))) (EIf (EBinOp "==" (EVar "d") (ELit (LChar "\r"))) (EApp (EVar "Err") (ELit (LString "delimiter cannot be a carriage return"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseRows") (EApp (EVar "fromChar") (EVar "d"))) (EApp (EVar "dropLastEmpty") (EApp (EApp (EVar "split") (ELit (LString "\n"))) (EVar "text")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "dropLastEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropLastEmpty" ((PList)) (EListLit))
(DFunDef false "dropLastEmpty" ((PList (PLit (LString "")))) (EListLit))
(DFunDef false "dropLastEmpty" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropLastEmpty") (EVar "xs"))))
(DData Private "St" () ((variant "St" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Int")))) ())
(DTypeSig false "parseRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "parseRows" ((PVar "dl") (PVar "ls")) (EMatch (EApp (EApp (EApp (EVar "fold") (EApp (EVar "stepLine") (EVar "dl"))) (EApp (EApp (EApp (EApp (EVar "St") (EListLit)) (EListLit)) (EVar "None")) (ELit (LInt 0)))) (EVar "ls")) (arm (PCon "St" (PVar "rows") PWild (PCon "None") PWild) () (EApp (EVar "Ok") (EApp (EVar "reverse") (EVar "rows")))) (arm (PCon "St" PWild PWild (PCon "Some" (PTuple PWild (PVar "n"))) PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ": unterminated quoted field")))))))
(DTypeSig false "stepLine" (TyFun (TyCon "String") (TyFun (TyCon "St") (TyFun (TyCon "String") (TyCon "St")))))
(DFunDef false "stepLine" ((PVar "dl") (PCon "St" (PVar "rows") (PVar "fs") (PVar "pend") (PVar "n")) (PVar "line")) (EMatch (EVar "pend") (arm (PCon "None") () (EIf (EBinOp "==" (EApp (EVar "stripCR") (EVar "line")) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "St") (EBinOp "::" (EListLit) (EVar "rows"))) (EListLit)) (EVar "None")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "finishLine") (EVar "dl")) (EVar "rows")) (EListLit)) (EVar "None")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "line")))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "finishLine") (EVar "dl")) (EVar "rows")) (EVar "fs")) (EVar "pend")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "line")))))
(DTypeSig false "finishLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "St"))))))))
(DFunDef false "finishLine" ((PVar "dl") (PVar "rows") (PVar "fs") (PVar "pend") (PVar "n") (PVar "line")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "dl")) (EVar "n")) (EVar "fs")) (EVar "pend")) (EApp (EApp (EVar "split") (EVar "dl")) (EVar "line"))) (arm (PTuple (PVar "fs2") (PCon "None")) () (EApp (EApp (EApp (EApp (EVar "St") (EBinOp "::" (EApp (EVar "reverse") (EVar "fs2")) (EVar "rows"))) (EListLit)) (EVar "None")) (EVar "n"))) (arm (PTuple (PVar "fs2") (PVar "p")) () (EApp (EApp (EApp (EApp (EVar "St") (EVar "rows")) (EVar "fs2")) (EVar "p")) (EVar "n")))))
(DTypeSig false "scan" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))))))))))
(DFunDef false "scan" (PWild PWild (PVar "fs") (PVar "pend") (PList)) (ETuple (EVar "fs") (EVar "pend")))
(DFunDef false "scan" ((PVar "dl") (PVar "n") (PVar "fs") (PVar "pend") (PCons (PVar "p") (PVar "rest"))) (EBlock (DoLet false false (PVar "raw") (EMatch (EVar "pend") (arm (PCon "None") () (EVar "p")) (arm (PCon "Some" (PTuple (PVar "r") PWild)) () (EBinOp "++" (EVar "r") (EVar "p"))))) (DoLet false false (PVar "opened") (EMatch (EVar "pend") (arm (PCon "None") () (EVar "n")) (arm (PCon "Some" (PTuple PWild (PVar "m"))) () (EVar "m")))) (DoLet false false (PVar "last") (EBinOp "==" (EVar "rest") (EListLit))) (DoLet false false (PVar "shown") (EIf (EVar "last") (EApp (EVar "stripCR") (EVar "raw")) (EVar "raw"))) (DoExpr (EMatch (EApp (EVar "field") (EVar "shown")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "dl")) (EVar "n")) (EBinOp "::" (EVar "v") (EVar "fs"))) (EVar "None")) (EVar "rest"))) (arm (PCon "None") () (EIf (EVar "last") (ETuple (EVar "fs") (EApp (EVar "Some") (ETuple (EBinOp "++" (EVar "raw") (ELit (LString "\n"))) (EVar "opened")))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "dl")) (EVar "n")) (EVar "fs")) (EApp (EVar "Some") (ETuple (EBinOp "++" (EVar "raw") (EVar "dl")) (EVar "opened")))) (EVar "rest"))))))))
(DTypeSig false "field" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "field" ((PVar "raw")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "\""))) (EVar "raw")) (EApp (EApp (EVar "quoted") (EApp (EApp (EVar "split") (ELit (LString "\""))) (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EVar "raw")))) (ELit (LString ""))) (EApp (EVar "Some") (EVar "raw"))))
(DTypeSig false "quoted" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "quoted" ((PList) PWild) (EVar "None"))
(DFunDef false "quoted" ((PList PWild) PWild) (EVar "None"))
(DFunDef false "quoted" ((PCons (PVar "s") (PCons (PLit (LString "")) (PAs "more" (PCons PWild PWild)))) (PVar "acc")) (EApp (EApp (EVar "quoted") (EVar "more")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "acc"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "s"))) (ELit (LString "\"")))))
(DFunDef false "quoted" ((PCons (PVar "s") (PVar "tail")) (PVar "acc")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EVar "acc") (EVar "s")) (EApp (EApp (EVar "join") (ELit (LString "\""))) (EVar "tail")))))
(DTypeSig true "render" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "String")))
(DFunDef false "render" () (EApp (EVar "renderWith") (ELit (LChar ","))))
(DTypeSig true "renderWith" (TyFun (TyCon "Char") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "renderWith" ((PVar "d") (PVar "rows")) (EApp (EVar "concat") (EApp (EApp (EVar "map") (EApp (EVar "renderRow") (EApp (EVar "fromChar") (EVar "d")))) (EVar "rows"))))
(DTypeSig false "renderRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "renderRow" (PWild (PList (PLit (LString "")))) (ELit (LString "\"\"\n")))
(DFunDef false "renderRow" ((PVar "dl") (PVar "row")) (EBinOp "++" (EApp (EApp (EVar "join") (EVar "dl")) (EApp (EApp (EVar "map") (EApp (EVar "quoteField") (EVar "dl"))) (EVar "row"))) (ELit (LString "\n"))))
(DTypeSig false "quoteField" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "quoteField" ((PVar "dl") (PVar "f")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "dl")) (EVar "f")) (EApp (EApp (EVar "contains") (ELit (LString "\""))) (EVar "f"))) (EApp (EApp (EVar "contains") (ELit (LString "\r"))) (EVar "f"))) (EApp (EApp (EVar "contains") (ELit (LString "\n"))) (EVar "f"))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "\""))) (ELit (LString "\"\""))) (EVar "f"))) (ELit (LString "\""))) (EVar "f")))
# MARK
(DUse false (UseGroup ("core") ((mem "Result" true) (mem "Option" true))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "fromChar" false) (mem "startsWith" false) (mem "drop" false) (mem "contains" false) (mem "replaceAll" false) (mem "join" false) (mem "concat" false) (mem "stripCR" false))))
(DTypeSig true "parse" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "parse" () (EApp (EVar "parseWith") (ELit (LChar ","))))
(DTypeSig true "parseWith" (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "parseWith" ((PVar "d") (PVar "text")) (EIf (EBinOp "==" (EVar "d") (ELit (LChar "\""))) (EApp (EVar "Err") (ELit (LString "delimiter cannot be a double quote"))) (EIf (EBinOp "==" (EVar "d") (ELit (LChar "\n"))) (EApp (EVar "Err") (ELit (LString "delimiter cannot be a line feed"))) (EIf (EBinOp "==" (EVar "d") (ELit (LChar "\r"))) (EApp (EVar "Err") (ELit (LString "delimiter cannot be a carriage return"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseRows") (EApp (EVar "fromChar") (EVar "d"))) (EApp (EVar "dropLastEmpty") (EApp (EApp (EVar "split") (ELit (LString "\n"))) (EVar "text")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "dropLastEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropLastEmpty" ((PList)) (EListLit))
(DFunDef false "dropLastEmpty" ((PList (PLit (LString "")))) (EListLit))
(DFunDef false "dropLastEmpty" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropLastEmpty") (EVar "xs"))))
(DData Private "St" () ((variant "St" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Int")))) ())
(DTypeSig false "parseRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "parseRows" ((PVar "dl") (PVar "ls")) (EMatch (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "stepLine") (EVar "dl"))) (EApp (EApp (EApp (EApp (EVar "St") (EListLit)) (EListLit)) (EVar "None")) (ELit (LInt 0)))) (EVar "ls")) (arm (PCon "St" (PVar "rows") PWild (PCon "None") PWild) () (EApp (EVar "Ok") (EApp (EVar "reverse") (EVar "rows")))) (arm (PCon "St" PWild PWild (PCon "Some" (PTuple PWild (PVar "n"))) PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "line ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ": unterminated quoted field")))))))
(DTypeSig false "stepLine" (TyFun (TyCon "String") (TyFun (TyCon "St") (TyFun (TyCon "String") (TyCon "St")))))
(DFunDef false "stepLine" ((PVar "dl") (PCon "St" (PVar "rows") (PVar "fs") (PVar "pend") (PVar "n")) (PVar "line")) (EMatch (EVar "pend") (arm (PCon "None") () (EIf (EBinOp "==" (EApp (EVar "stripCR") (EVar "line")) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "St") (EBinOp "::" (EListLit) (EVar "rows"))) (EListLit)) (EVar "None")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "finishLine") (EVar "dl")) (EVar "rows")) (EListLit)) (EVar "None")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "line")))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "finishLine") (EVar "dl")) (EVar "rows")) (EVar "fs")) (EVar "pend")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "line")))))
(DTypeSig false "finishLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "St"))))))))
(DFunDef false "finishLine" ((PVar "dl") (PVar "rows") (PVar "fs") (PVar "pend") (PVar "n") (PVar "line")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "dl")) (EVar "n")) (EVar "fs")) (EVar "pend")) (EApp (EApp (EVar "split") (EVar "dl")) (EVar "line"))) (arm (PTuple (PVar "fs2") (PCon "None")) () (EApp (EApp (EApp (EApp (EVar "St") (EBinOp "::" (EApp (EVar "reverse") (EVar "fs2")) (EVar "rows"))) (EListLit)) (EVar "None")) (EVar "n"))) (arm (PTuple (PVar "fs2") (PVar "p")) () (EApp (EApp (EApp (EApp (EVar "St") (EVar "rows")) (EVar "fs2")) (EVar "p")) (EVar "n")))))
(DTypeSig false "scan" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))))))))))
(DFunDef false "scan" (PWild PWild (PVar "fs") (PVar "pend") (PList)) (ETuple (EVar "fs") (EVar "pend")))
(DFunDef false "scan" ((PVar "dl") (PVar "n") (PVar "fs") (PVar "pend") (PCons (PVar "p") (PVar "rest"))) (EBlock (DoLet false false (PVar "raw") (EMatch (EVar "pend") (arm (PCon "None") () (EVar "p")) (arm (PCon "Some" (PTuple (PVar "r") PWild)) () (EBinOp "++" (EVar "r") (EVar "p"))))) (DoLet false false (PVar "opened") (EMatch (EVar "pend") (arm (PCon "None") () (EVar "n")) (arm (PCon "Some" (PTuple PWild (PVar "m"))) () (EVar "m")))) (DoLet false false (PVar "last") (EBinOp "==" (EVar "rest") (EListLit))) (DoLet false false (PVar "shown") (EIf (EVar "last") (EApp (EVar "stripCR") (EVar "raw")) (EVar "raw"))) (DoExpr (EMatch (EApp (EVar "field") (EVar "shown")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "dl")) (EVar "n")) (EBinOp "::" (EVar "v") (EVar "fs"))) (EVar "None")) (EVar "rest"))) (arm (PCon "None") () (EIf (EVar "last") (ETuple (EVar "fs") (EApp (EVar "Some") (ETuple (EBinOp "++" (EVar "raw") (ELit (LString "\n"))) (EVar "opened")))) (EApp (EApp (EApp (EApp (EApp (EVar "scan") (EVar "dl")) (EVar "n")) (EVar "fs")) (EApp (EVar "Some") (ETuple (EBinOp "++" (EVar "raw") (EVar "dl")) (EVar "opened")))) (EVar "rest"))))))))
(DTypeSig false "field" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "field" ((PVar "raw")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "\""))) (EVar "raw")) (EApp (EApp (EVar "quoted") (EApp (EApp (EVar "split") (ELit (LString "\""))) (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EVar "raw")))) (ELit (LString ""))) (EApp (EVar "Some") (EVar "raw"))))
(DTypeSig false "quoted" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "quoted" ((PList) PWild) (EVar "None"))
(DFunDef false "quoted" ((PList PWild) PWild) (EVar "None"))
(DFunDef false "quoted" ((PCons (PVar "s") (PCons (PLit (LString "")) (PAs "more" (PCons PWild PWild)))) (PVar "acc")) (EApp (EApp (EVar "quoted") (EVar "more")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "acc"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "\"")))))
(DFunDef false "quoted" ((PCons (PVar "s") (PVar "tail")) (PVar "acc")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EVar "acc") (EVar "s")) (EApp (EApp (EVar "join") (ELit (LString "\""))) (EVar "tail")))))
(DTypeSig true "render" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "String")))
(DFunDef false "render" () (EApp (EVar "renderWith") (ELit (LChar ","))))
(DTypeSig true "renderWith" (TyFun (TyCon "Char") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "renderWith" ((PVar "d") (PVar "rows")) (EApp (EVar "concat") (EApp (EApp (EMethodRef "map") (EApp (EVar "renderRow") (EApp (EVar "fromChar") (EVar "d")))) (EVar "rows"))))
(DTypeSig false "renderRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "renderRow" (PWild (PList (PLit (LString "")))) (ELit (LString "\"\"\n")))
(DFunDef false "renderRow" ((PVar "dl") (PVar "row")) (EBinOp "++" (EApp (EApp (EVar "join") (EVar "dl")) (EApp (EApp (EMethodRef "map") (EApp (EVar "quoteField") (EVar "dl"))) (EVar "row"))) (ELit (LString "\n"))))
(DTypeSig false "quoteField" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "quoteField" ((PVar "dl") (PVar "f")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "dl")) (EVar "f")) (EApp (EApp (EVar "contains") (ELit (LString "\""))) (EVar "f"))) (EApp (EApp (EVar "contains") (ELit (LString "\r"))) (EVar "f"))) (EApp (EApp (EVar "contains") (ELit (LString "\n"))) (EVar "f"))) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "\""))) (ELit (LString "\"\""))) (EVar "f"))) (ELit (LString "\""))) (EVar "f")))
