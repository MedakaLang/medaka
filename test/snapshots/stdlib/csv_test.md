# META
source_lines=165
stages=DESUGAR,MARK
# SOURCE
-- Tests for `stdlib/csv.mdk`: the reading rules, the writing rules, and the
-- round trip between them.

import csv.{parse, parseWith, render, renderWith}
import string.{concat, repeat, take, contains}
import test.{expectEqual, expectErrContains, expectTrue, expectEach}

-- # Reading

test "plain rows" =
  expectEqual (Ok [["a", "b"], ["1", "2"]]) (parse "a,b\n1,2\n")

test "empty fields are kept" = expectEach [
  ("middle", expectEqual (Ok [["a", "", "b"]]) (parse "a,,b\n")),
  ("only a delimiter", expectEqual (Ok [["", ""]]) (parse ",\n")),
  ("trailing delimiter", expectEqual (Ok [["a", ""]]) (parse "a,\n")),
]

test "quoted fields hold the delimiter, doubled quotes and line breaks" = expectEach
  [
    ("delimiter", expectEqual (Ok [["a,b", "c"]]) (parse "\"a,b\",c\n")),
    (
      "doubled quote",
      expectEqual (Ok [["say \"hi\""]]) (parse "\"say \"\"hi\"\"\"\n"),
    ),
    ("LF kept", expectEqual (Ok [["a\nb", "c"]]) (parse "\"a\nb\",c\n")),
    (
      "CRLF kept",
      expectEqual (Ok [["a\r\nb", "c"]]) (parse "\"a\r\nb\",c\r\n"),
    ),
    ("empty line inside", expectEqual (Ok [["a\n\nb"]]) (parse "\"a\n\nb\"\n")),
  ]

test "both line endings end a row, and a final one adds no row" = expectEach [
  ("LF", expectEqual (Ok [["a"], ["b"]]) (parse "a\nb\n")),
  ("CRLF", expectEqual (Ok [["a"], ["b"]]) (parse "a\r\nb\r\n")),
  ("no final break", expectEqual (Ok [["a"], ["b"]]) (parse "a\nb")),
  ("empty input", expectEqual (Ok []) (parse "")),
  (
    "empty line is the empty row",
    expectEqual (Ok [["a"], [], ["b"]]) (parse "a\n\nb\n"),
  ),
]

test "whitespace and stray quotes in unquoted fields are kept" = expectEach [
  ("spaces", expectEqual (Ok [[" a ", " b "]]) (parse " a , b \n")),
  ("quote inside", expectEqual (Ok [["ab\"c", "d"]]) (parse "ab\"c,d\n")),
  ("quote after a space", expectEqual (Ok [[" \"b\""]]) (parse " \"b\"\n")),
]

test "text after a closing quote joins the field" = expectEach [
  ("letter", expectEqual (Ok [["ab", "c"]]) (parse "\"a\"b,c\n")),
  (
    "later quote is literal",
    expectEqual (Ok [["ab\"c\"", "d"]]) (parse "\"a\"b\"c\",d\n"),
  ),
]

test "a lone CR is an ordinary character" =
  expectEqual (Ok [["a\rb", "c"]]) (parse "a\rb,c\n")

test "TSV reads quoting too" = expectEach [
  ("plain", expectEqual (Ok [["a", "b"]]) (parseWith '\t' "a\tb\n")),
  (
    "quoted tab",
    expectEqual (Ok [["x\ty", "z"]]) (parseWith '\t' "\"x\ty\"\tz\n"),
  ),
  ("comma is data", expectEqual (Ok [["a,b", "c"]]) (parseWith '\t' "a,b\tc\n")),
]

test "an unterminated quote names the line it opened on" = expectEach [
  (
    "line 1",
    expectEqual (Err "line 1: unterminated quoted field") (parse "a,\"b"),
  ),
  (
    "line 2",
    expectEqual
      (Err "line 2: unterminated quoted field")
      (parse "x\ny,\"b\nc\n"),
  ),
  (
    "opened earlier",
    expectEqual (Err "line 1: unterminated quoted field") (parse "\"a\nb\nc\n"),
  ),
  (
    "lone quote",
    expectEqual (Err "line 1: unterminated quoted field") (parse "\""),
  ),
  (
    "doubled quote at end",
    expectEqual (Err "line 1: unterminated quoted field") (parse "\"a\"\""),
  ),
]

test "a delimiter that is a quote, LF or CR is refused" = expectEach [
  ("quote", expectErrContains "double quote" (parseWith '"' "a")),
  ("LF", expectErrContains "line feed" (parseWith '\n' "a")),
  ("CR", expectErrContains "carriage return" (parseWith '\r' "a")),
]

-- # Writing

test "a field is quoted only when it has to be" = expectEach [
  ("plain", expectEqual "a,b c\n" (render [["a", "b c"]])),
  ("delimiter", expectEqual "\"a,b\",\n" (render [["a,b", ""]])),
  ("quote", expectEqual "\"say \"\"hi\"\"\"\n" (render [["say \"hi\""]])),
  ("LF", expectEqual "\"a\nb\",c\n" (render [["a\nb", "c"]])),
  ("CR", expectEqual "\"a\rb\"\n" (render [["a\rb"]])),
  ("tab is plain for CSV", expectEqual "a\tb\n" (render [["a\tb"]])),
]

test "TSV quotes the tab, not the comma" =
  expectEqual "a,b\t\"x\ty\"\n" (renderWith '\t' [["a,b", "x\ty"]])

test "every row ends in LF, never CRLF" =
  expectEqual "a\nb\n" (render [["a"], ["b"]])

test "a row of one empty field is written quoted, the empty row is not" = expectEach
  [
    ("single empty field", expectEqual "\"\"\n" (render [[""]])),
    ("empty row", expectEqual "\n" (render [[]])),
    ("single empty field reads back", expectEqual (Ok [[""]]) (parse "\"\"\n")),
    ("empty row reads back", expectEqual (Ok [[]]) (parse "\n")),
    ("two empty fields", expectEqual ",\n" (render [["", ""]])),
  ]

-- # Round trips

fragment : Int -> String
fragment i = match (i % 8 + 8) % 8
  0 => "a"
  1 => ","
  2 => "\""
  3 => "\r"
  4 => "\n"
  5 => ""
  6 => " "
  _ => "\t"

tableOf : List (List (List Int)) -> List (List String)
tableOf rows = map (row => map (f => concat (map fragment f)) row) rows

prop "parse undoes render, for fields holding delimiters, quotes, CR and LF" (rows : List (List (List Int))) =
  parse (render (tableOf rows)) == Ok (tableOf rows)

prop "parseWith undoes renderWith for tabs" (rows : List (List (List Int))) =
  parseWith '\t' (renderWith '\t' (tableOf rows)) == Ok (tableOf rows)

test "the round trip holds on the awkward rows named outright" =
  let rows = [[], [""], ["", ""], ["\""], ["a,\"b\"\r\nc"], ["\n"], []]
  expectEqual (Ok rows) (parse (render rows))

-- # Totality

mixed : String
mixed = take 200 (repeat 30 "a,\"b\"\"\r\n ,")

prefixOk : Int -> Bool
prefixOk k = match parse (take k mixed)
  Ok _ => True
  Err e => contains "unterminated quoted field" e

test "every prefix of a 200-character mixed input reads or is unterminated" =
  expectTrue (all prefixOk [0..=200])
# DESUGAR
(DUse false (UseGroup ("csv") ((mem "parse" false) (mem "parseWith" false) (mem "render" false) (mem "renderWith" false))))
(DUse false (UseGroup ("string") ((mem "concat" false) (mem "repeat" false) (mem "take" false) (mem "contains" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectErrContains" false) (mem "expectTrue" false) (mem "expectEach" false))))
(DTest false "plain rows" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a")) (ELit (LString "b"))) (EListLit (ELit (LString "1")) (ELit (LString "2")))))) (EApp (EVar "parse") (ELit (LString "a,b\n1,2\n")))))
(DTest false "empty fields are kept" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "middle")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a")) (ELit (LString "")) (ELit (LString "b")))))) (EApp (EVar "parse") (ELit (LString "a,,b\n"))))) (ETuple (ELit (LString "only a delimiter")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "")) (ELit (LString "")))))) (EApp (EVar "parse") (ELit (LString ",\n"))))) (ETuple (ELit (LString "trailing delimiter")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a")) (ELit (LString "")))))) (EApp (EVar "parse") (ELit (LString "a,\n"))))))))
(DTest false "quoted fields hold the delimiter, doubled quotes and line breaks" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "delimiter")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a,b")) (ELit (LString "c")))))) (EApp (EVar "parse") (ELit (LString "\"a,b\",c\n"))))) (ETuple (ELit (LString "doubled quote")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "say \"hi\"")))))) (EApp (EVar "parse") (ELit (LString "\"say \"\"hi\"\"\"\n"))))) (ETuple (ELit (LString "LF kept")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a\nb")) (ELit (LString "c")))))) (EApp (EVar "parse") (ELit (LString "\"a\nb\",c\n"))))) (ETuple (ELit (LString "CRLF kept")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a\r\nb")) (ELit (LString "c")))))) (EApp (EVar "parse") (ELit (LString "\"a\r\nb\",c\r\n"))))) (ETuple (ELit (LString "empty line inside")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a\n\nb")))))) (EApp (EVar "parse") (ELit (LString "\"a\n\nb\"\n"))))))))
(DTest false "both line endings end a row, and a final one adds no row" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "LF")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a"))) (EListLit (ELit (LString "b")))))) (EApp (EVar "parse") (ELit (LString "a\nb\n"))))) (ETuple (ELit (LString "CRLF")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a"))) (EListLit (ELit (LString "b")))))) (EApp (EVar "parse") (ELit (LString "a\r\nb\r\n"))))) (ETuple (ELit (LString "no final break")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a"))) (EListLit (ELit (LString "b")))))) (EApp (EVar "parse") (ELit (LString "a\nb"))))) (ETuple (ELit (LString "empty input")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit))) (EApp (EVar "parse") (ELit (LString ""))))) (ETuple (ELit (LString "empty line is the empty row")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a"))) (EListLit) (EListLit (ELit (LString "b")))))) (EApp (EVar "parse") (ELit (LString "a\n\nb\n"))))))))
(DTest false "whitespace and stray quotes in unquoted fields are kept" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "spaces")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString " a ")) (ELit (LString " b ")))))) (EApp (EVar "parse") (ELit (LString " a , b \n"))))) (ETuple (ELit (LString "quote inside")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "ab\"c")) (ELit (LString "d")))))) (EApp (EVar "parse") (ELit (LString "ab\"c,d\n"))))) (ETuple (ELit (LString "quote after a space")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString " \"b\"")))))) (EApp (EVar "parse") (ELit (LString " \"b\"\n"))))))))
(DTest false "text after a closing quote joins the field" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "letter")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "ab")) (ELit (LString "c")))))) (EApp (EVar "parse") (ELit (LString "\"a\"b,c\n"))))) (ETuple (ELit (LString "later quote is literal")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "ab\"c\"")) (ELit (LString "d")))))) (EApp (EVar "parse") (ELit (LString "\"a\"b\"c\",d\n"))))))))
(DTest false "a lone CR is an ordinary character" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a\rb")) (ELit (LString "c")))))) (EApp (EVar "parse") (ELit (LString "a\rb,c\n")))))
(DTest false "TSV reads quoting too" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "plain")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a")) (ELit (LString "b")))))) (EApp (EApp (EVar "parseWith") (ELit (LChar "\t"))) (ELit (LString "a\tb\n"))))) (ETuple (ELit (LString "quoted tab")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "x\ty")) (ELit (LString "z")))))) (EApp (EApp (EVar "parseWith") (ELit (LChar "\t"))) (ELit (LString "\"x\ty\"\tz\n"))))) (ETuple (ELit (LString "comma is data")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a,b")) (ELit (LString "c")))))) (EApp (EApp (EVar "parseWith") (ELit (LChar "\t"))) (ELit (LString "a,b\tc\n"))))))))
(DTest false "an unterminated quote names the line it opened on" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "line 1")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "line 1: unterminated quoted field")))) (EApp (EVar "parse") (ELit (LString "a,\"b"))))) (ETuple (ELit (LString "line 2")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "line 2: unterminated quoted field")))) (EApp (EVar "parse") (ELit (LString "x\ny,\"b\nc\n"))))) (ETuple (ELit (LString "opened earlier")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "line 1: unterminated quoted field")))) (EApp (EVar "parse") (ELit (LString "\"a\nb\nc\n"))))) (ETuple (ELit (LString "lone quote")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "line 1: unterminated quoted field")))) (EApp (EVar "parse") (ELit (LString "\""))))) (ETuple (ELit (LString "doubled quote at end")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "line 1: unterminated quoted field")))) (EApp (EVar "parse") (ELit (LString "\"a\"\""))))))))
(DTest false "a delimiter that is a quote, LF or CR is refused" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "quote")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "double quote"))) (EApp (EApp (EVar "parseWith") (ELit (LChar "\""))) (ELit (LString "a"))))) (ETuple (ELit (LString "LF")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "line feed"))) (EApp (EApp (EVar "parseWith") (ELit (LChar "\n"))) (ELit (LString "a"))))) (ETuple (ELit (LString "CR")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "carriage return"))) (EApp (EApp (EVar "parseWith") (ELit (LChar "\r"))) (ELit (LString "a"))))))))
(DTest false "a field is quoted only when it has to be" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "plain")) (EApp (EApp (EVar "expectEqual") (ELit (LString "a,b c\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "a")) (ELit (LString "b c"))))))) (ETuple (ELit (LString "delimiter")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"a,b\",\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "a,b")) (ELit (LString ""))))))) (ETuple (ELit (LString "quote")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"say \"\"hi\"\"\"\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "say \"hi\""))))))) (ETuple (ELit (LString "LF")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"a\nb\",c\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "a\nb")) (ELit (LString "c"))))))) (ETuple (ELit (LString "CR")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"a\rb\"\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "a\rb"))))))) (ETuple (ELit (LString "tab is plain for CSV")) (EApp (EApp (EVar "expectEqual") (ELit (LString "a\tb\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "a\tb"))))))))))
(DTest false "TSV quotes the tab, not the comma" (EApp (EApp (EVar "expectEqual") (ELit (LString "a,b\t\"x\ty\"\n"))) (EApp (EApp (EVar "renderWith") (ELit (LChar "\t"))) (EListLit (EListLit (ELit (LString "a,b")) (ELit (LString "x\ty")))))))
(DTest false "every row ends in LF, never CRLF" (EApp (EApp (EVar "expectEqual") (ELit (LString "a\nb\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "a"))) (EListLit (ELit (LString "b")))))))
(DTest false "a row of one empty field is written quoted, the empty row is not" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "single empty field")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"\"\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString ""))))))) (ETuple (ELit (LString "empty row")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\n"))) (EApp (EVar "render") (EListLit (EListLit))))) (ETuple (ELit (LString "single empty field reads back")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "")))))) (EApp (EVar "parse") (ELit (LString "\"\"\n"))))) (ETuple (ELit (LString "empty row reads back")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit)))) (EApp (EVar "parse") (ELit (LString "\n"))))) (ETuple (ELit (LString "two empty fields")) (EApp (EApp (EVar "expectEqual") (ELit (LString ",\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "")) (ELit (LString ""))))))))))
(DTypeSig false "fragment" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "fragment" ((PVar "i")) (EMatch (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "i") (ELit (LInt 8))) (ELit (LInt 8))) (ELit (LInt 8))) (arm (PLit (LInt 0)) () (ELit (LString "a"))) (arm (PLit (LInt 1)) () (ELit (LString ","))) (arm (PLit (LInt 2)) () (ELit (LString "\""))) (arm (PLit (LInt 3)) () (ELit (LString "\r"))) (arm (PLit (LInt 4)) () (ELit (LString "\n"))) (arm (PLit (LInt 5)) () (ELit (LString ""))) (arm (PLit (LInt 6)) () (ELit (LString " "))) (arm PWild () (ELit (LString "\t")))))
(DTypeSig false "tableOf" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tableOf" ((PVar "rows")) (EApp (EApp (EVar "map") (ELam ((PVar "row")) (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EApp (EVar "concat") (EApp (EApp (EVar "map") (EVar "fragment")) (EVar "f"))))) (EVar "row")))) (EVar "rows")))
(DProp false "parse undoes render, for fields holding delimiters, quotes, CR and LF" ((pp "rows" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))) (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "render") (EApp (EVar "tableOf") (EVar "rows")))) (EApp (EVar "Ok") (EApp (EVar "tableOf") (EVar "rows")))))
(DProp false "parseWith undoes renderWith for tabs" ((pp "rows" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))) (EBinOp "==" (EApp (EApp (EVar "parseWith") (ELit (LChar "\t"))) (EApp (EApp (EVar "renderWith") (ELit (LChar "\t"))) (EApp (EVar "tableOf") (EVar "rows")))) (EApp (EVar "Ok") (EApp (EVar "tableOf") (EVar "rows")))))
(DTest false "the round trip holds on the awkward rows named outright" (EBlock (DoLet false false (PVar "rows") (EListLit (EListLit) (EListLit (ELit (LString ""))) (EListLit (ELit (LString "")) (ELit (LString ""))) (EListLit (ELit (LString "\""))) (EListLit (ELit (LString "a,\"b\"\r\nc"))) (EListLit (ELit (LString "\n"))) (EListLit))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EVar "rows"))) (EApp (EVar "parse") (EApp (EVar "render") (EVar "rows")))))))
(DTypeSig false "mixed" (TyCon "String"))
(DFunDef false "mixed" () (EApp (EApp (EVar "take") (ELit (LInt 200))) (EApp (EApp (EVar "repeat") (ELit (LInt 30))) (ELit (LString "a,\"b\"\"\r\n ,")))))
(DTypeSig false "prefixOk" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "prefixOk" ((PVar "k")) (EMatch (EApp (EVar "parse") (EApp (EApp (EVar "take") (EVar "k")) (EVar "mixed"))) (arm (PCon "Ok" PWild) () (EVar "True")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EVar "contains") (ELit (LString "unterminated quoted field"))) (EVar "e")))))
(DTest false "every prefix of a 200-character mixed input reads or is unterminated" (EApp (EVar "expectTrue") (EApp (EApp (EVar "all") (EVar "prefixOk")) (ERangeList (ELit (LInt 0)) (ELit (LInt 200)) true))))
# MARK
(DUse false (UseGroup ("csv") ((mem "parse" false) (mem "parseWith" false) (mem "render" false) (mem "renderWith" false))))
(DUse false (UseGroup ("string") ((mem "concat" false) (mem "repeat" false) (mem "take" false) (mem "contains" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectErrContains" false) (mem "expectTrue" false) (mem "expectEach" false))))
(DTest false "plain rows" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a")) (ELit (LString "b"))) (EListLit (ELit (LString "1")) (ELit (LString "2")))))) (EApp (EVar "parse") (ELit (LString "a,b\n1,2\n")))))
(DTest false "empty fields are kept" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "middle")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a")) (ELit (LString "")) (ELit (LString "b")))))) (EApp (EVar "parse") (ELit (LString "a,,b\n"))))) (ETuple (ELit (LString "only a delimiter")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "")) (ELit (LString "")))))) (EApp (EVar "parse") (ELit (LString ",\n"))))) (ETuple (ELit (LString "trailing delimiter")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a")) (ELit (LString "")))))) (EApp (EVar "parse") (ELit (LString "a,\n"))))))))
(DTest false "quoted fields hold the delimiter, doubled quotes and line breaks" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "delimiter")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a,b")) (ELit (LString "c")))))) (EApp (EVar "parse") (ELit (LString "\"a,b\",c\n"))))) (ETuple (ELit (LString "doubled quote")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "say \"hi\"")))))) (EApp (EVar "parse") (ELit (LString "\"say \"\"hi\"\"\"\n"))))) (ETuple (ELit (LString "LF kept")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a\nb")) (ELit (LString "c")))))) (EApp (EVar "parse") (ELit (LString "\"a\nb\",c\n"))))) (ETuple (ELit (LString "CRLF kept")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a\r\nb")) (ELit (LString "c")))))) (EApp (EVar "parse") (ELit (LString "\"a\r\nb\",c\r\n"))))) (ETuple (ELit (LString "empty line inside")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a\n\nb")))))) (EApp (EVar "parse") (ELit (LString "\"a\n\nb\"\n"))))))))
(DTest false "both line endings end a row, and a final one adds no row" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "LF")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a"))) (EListLit (ELit (LString "b")))))) (EApp (EVar "parse") (ELit (LString "a\nb\n"))))) (ETuple (ELit (LString "CRLF")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a"))) (EListLit (ELit (LString "b")))))) (EApp (EVar "parse") (ELit (LString "a\r\nb\r\n"))))) (ETuple (ELit (LString "no final break")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a"))) (EListLit (ELit (LString "b")))))) (EApp (EVar "parse") (ELit (LString "a\nb"))))) (ETuple (ELit (LString "empty input")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit))) (EApp (EVar "parse") (ELit (LString ""))))) (ETuple (ELit (LString "empty line is the empty row")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a"))) (EListLit) (EListLit (ELit (LString "b")))))) (EApp (EVar "parse") (ELit (LString "a\n\nb\n"))))))))
(DTest false "whitespace and stray quotes in unquoted fields are kept" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "spaces")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString " a ")) (ELit (LString " b ")))))) (EApp (EVar "parse") (ELit (LString " a , b \n"))))) (ETuple (ELit (LString "quote inside")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "ab\"c")) (ELit (LString "d")))))) (EApp (EVar "parse") (ELit (LString "ab\"c,d\n"))))) (ETuple (ELit (LString "quote after a space")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString " \"b\"")))))) (EApp (EVar "parse") (ELit (LString " \"b\"\n"))))))))
(DTest false "text after a closing quote joins the field" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "letter")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "ab")) (ELit (LString "c")))))) (EApp (EVar "parse") (ELit (LString "\"a\"b,c\n"))))) (ETuple (ELit (LString "later quote is literal")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "ab\"c\"")) (ELit (LString "d")))))) (EApp (EVar "parse") (ELit (LString "\"a\"b\"c\",d\n"))))))))
(DTest false "a lone CR is an ordinary character" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a\rb")) (ELit (LString "c")))))) (EApp (EVar "parse") (ELit (LString "a\rb,c\n")))))
(DTest false "TSV reads quoting too" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "plain")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a")) (ELit (LString "b")))))) (EApp (EApp (EVar "parseWith") (ELit (LChar "\t"))) (ELit (LString "a\tb\n"))))) (ETuple (ELit (LString "quoted tab")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "x\ty")) (ELit (LString "z")))))) (EApp (EApp (EVar "parseWith") (ELit (LChar "\t"))) (ELit (LString "\"x\ty\"\tz\n"))))) (ETuple (ELit (LString "comma is data")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "a,b")) (ELit (LString "c")))))) (EApp (EApp (EVar "parseWith") (ELit (LChar "\t"))) (ELit (LString "a,b\tc\n"))))))))
(DTest false "an unterminated quote names the line it opened on" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "line 1")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "line 1: unterminated quoted field")))) (EApp (EVar "parse") (ELit (LString "a,\"b"))))) (ETuple (ELit (LString "line 2")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "line 2: unterminated quoted field")))) (EApp (EVar "parse") (ELit (LString "x\ny,\"b\nc\n"))))) (ETuple (ELit (LString "opened earlier")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "line 1: unterminated quoted field")))) (EApp (EVar "parse") (ELit (LString "\"a\nb\nc\n"))))) (ETuple (ELit (LString "lone quote")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "line 1: unterminated quoted field")))) (EApp (EVar "parse") (ELit (LString "\""))))) (ETuple (ELit (LString "doubled quote at end")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "line 1: unterminated quoted field")))) (EApp (EVar "parse") (ELit (LString "\"a\"\""))))))))
(DTest false "a delimiter that is a quote, LF or CR is refused" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "quote")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "double quote"))) (EApp (EApp (EVar "parseWith") (ELit (LChar "\""))) (ELit (LString "a"))))) (ETuple (ELit (LString "LF")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "line feed"))) (EApp (EApp (EVar "parseWith") (ELit (LChar "\n"))) (ELit (LString "a"))))) (ETuple (ELit (LString "CR")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "carriage return"))) (EApp (EApp (EVar "parseWith") (ELit (LChar "\r"))) (ELit (LString "a"))))))))
(DTest false "a field is quoted only when it has to be" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "plain")) (EApp (EApp (EVar "expectEqual") (ELit (LString "a,b c\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "a")) (ELit (LString "b c"))))))) (ETuple (ELit (LString "delimiter")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"a,b\",\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "a,b")) (ELit (LString ""))))))) (ETuple (ELit (LString "quote")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"say \"\"hi\"\"\"\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "say \"hi\""))))))) (ETuple (ELit (LString "LF")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"a\nb\",c\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "a\nb")) (ELit (LString "c"))))))) (ETuple (ELit (LString "CR")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"a\rb\"\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "a\rb"))))))) (ETuple (ELit (LString "tab is plain for CSV")) (EApp (EApp (EVar "expectEqual") (ELit (LString "a\tb\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "a\tb"))))))))))
(DTest false "TSV quotes the tab, not the comma" (EApp (EApp (EVar "expectEqual") (ELit (LString "a,b\t\"x\ty\"\n"))) (EApp (EApp (EVar "renderWith") (ELit (LChar "\t"))) (EListLit (EListLit (ELit (LString "a,b")) (ELit (LString "x\ty")))))))
(DTest false "every row ends in LF, never CRLF" (EApp (EApp (EVar "expectEqual") (ELit (LString "a\nb\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "a"))) (EListLit (ELit (LString "b")))))))
(DTest false "a row of one empty field is written quoted, the empty row is not" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "single empty field")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"\"\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString ""))))))) (ETuple (ELit (LString "empty row")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\n"))) (EApp (EVar "render") (EListLit (EListLit))))) (ETuple (ELit (LString "single empty field reads back")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit (ELit (LString "")))))) (EApp (EVar "parse") (ELit (LString "\"\"\n"))))) (ETuple (ELit (LString "empty row reads back")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EListLit (EListLit)))) (EApp (EVar "parse") (ELit (LString "\n"))))) (ETuple (ELit (LString "two empty fields")) (EApp (EApp (EVar "expectEqual") (ELit (LString ",\n"))) (EApp (EVar "render") (EListLit (EListLit (ELit (LString "")) (ELit (LString ""))))))))))
(DTypeSig false "fragment" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "fragment" ((PVar "i")) (EMatch (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "i") (ELit (LInt 8))) (ELit (LInt 8))) (ELit (LInt 8))) (arm (PLit (LInt 0)) () (ELit (LString "a"))) (arm (PLit (LInt 1)) () (ELit (LString ","))) (arm (PLit (LInt 2)) () (ELit (LString "\""))) (arm (PLit (LInt 3)) () (ELit (LString "\r"))) (arm (PLit (LInt 4)) () (ELit (LString "\n"))) (arm (PLit (LInt 5)) () (ELit (LString ""))) (arm (PLit (LInt 6)) () (ELit (LString " "))) (arm PWild () (ELit (LString "\t")))))
(DTypeSig false "tableOf" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tableOf" ((PVar "rows")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EApp (EVar "concat") (EApp (EApp (EMethodRef "map") (EVar "fragment")) (EVar "f"))))) (EVar "row")))) (EVar "rows")))
(DProp false "parse undoes render, for fields holding delimiters, quotes, CR and LF" ((pp "rows" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))) (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "render") (EApp (EVar "tableOf") (EVar "rows")))) (EApp (EVar "Ok") (EApp (EVar "tableOf") (EVar "rows")))))
(DProp false "parseWith undoes renderWith for tabs" ((pp "rows" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))) (EBinOp "==" (EApp (EApp (EVar "parseWith") (ELit (LChar "\t"))) (EApp (EApp (EVar "renderWith") (ELit (LChar "\t"))) (EApp (EVar "tableOf") (EVar "rows")))) (EApp (EVar "Ok") (EApp (EVar "tableOf") (EVar "rows")))))
(DTest false "the round trip holds on the awkward rows named outright" (EBlock (DoLet false false (PVar "rows") (EListLit (EListLit) (EListLit (ELit (LString ""))) (EListLit (ELit (LString "")) (ELit (LString ""))) (EListLit (ELit (LString "\""))) (EListLit (ELit (LString "a,\"b\"\r\nc"))) (EListLit (ELit (LString "\n"))) (EListLit))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EVar "rows"))) (EApp (EVar "parse") (EApp (EVar "render") (EVar "rows")))))))
(DTypeSig false "mixed" (TyCon "String"))
(DFunDef false "mixed" () (EApp (EApp (EVar "take") (ELit (LInt 200))) (EApp (EApp (EVar "repeat") (ELit (LInt 30))) (ELit (LString "a,\"b\"\"\r\n ,")))))
(DTypeSig false "prefixOk" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "prefixOk" ((PVar "k")) (EMatch (EApp (EVar "parse") (EApp (EApp (EVar "take") (EVar "k")) (EVar "mixed"))) (arm (PCon "Ok" PWild) () (EVar "True")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EVar "contains") (ELit (LString "unterminated quoted field"))) (EVar "e")))))
(DTest false "every prefix of a 200-character mixed input reads or is unterminated" (EApp (EVar "expectTrue") (EApp (EApp (EDictApp "all") (EVar "prefixOk")) (ERangeList (ELit (LInt 0)) (ELit (LInt 200)) true))))
