# META
source_lines=241
stages=DESUGAR,MARK
# SOURCE
-- Tests for the array-of-tables readers in `stdlib/toml.mdk`.

import toml.{
  Toml(..), TomlValue(..), parse, tableCount, tableEntry, tableEntries,
  getString
}
import test.{expectEach, expectEqual, expectErrContains, expectOkThen}

multi : String
multi =
  "[package]\nname = \"p\"\n[[gate]]\nname = \"a\"\nshard = 1\n[[other]]\nname = \"x\"\n[[gate]]\nname = \"b\"\n[[other]]\nname = \"y\"\n[[gate]]\nname = \"c\"\nshard = 3\n"

load : String -> Toml
load src = match parse src
  Ok doc => doc
  Err e => panic e

entriesByIndex : String -> Toml -> List (Option Toml)
entriesByIndex name doc =
  map (i => tableEntry name i doc) [0..tableCount name doc]

test "tableEntries equals tableEntry at every index, on a multi-table document" =
  let doc = load multi
  expectOkThen
    (es => expectEqual (map Some es) (entriesByIndex "gate" doc))
    (tableEntries "gate" doc)

test "tableEntries agrees with tableEntry for a second table in the same document" =
  let doc = load multi
  expectOkThen
    (es => expectEqual (map Some es) (entriesByIndex "other" doc))
    (tableEntries "other" doc)

test "tableEntries keeps document order" =
  expectOkThen
    (es =>
      expectEqual [Some "a", Some "b", Some "c"] (map (getString "name") es))
    (tableEntries "gate" (load multi))

test "tableEntries entries carry unqualified keys" =
  expectOkThen
    (es => expectEqual [Some "1"] (map (getString "name") es))
    (tableEntries "gate" (load "[[gate]]\nname = \"1\""))

test "tableEntries is empty when there are no entries" =
  expectOkThen
    (es => expectEqual 0 (length es))
    (tableEntries "gate" (load "[package]\nname = \"p\""))

test "tableEntries does not take a longer table name for a prefix" =
  expectOkThen
    (es => expectEqual 1 (length es))
    (tableEntries
      "gate"
      (load "[[gate]]\nname = \"a\"\n[[gates]]\nname = \"b\""))

test "tableEntries refuses an index past the limit, naming the table and the index" =
  expectEqual
    (Err "too many [[gate]] entries: index 5000000 is past the limit of 100000")
    (tableEntries "gate" (load "[gate.5000000]\nname = \"x\""))

test "tableEntries refuses the first index past the limit" =
  expectEqual
    (Err "too many [[gate]] entries: index 100000 is past the limit of 100000")
    (tableEntries "gate" (load "[gate.100000]\nname = \"x\""))

test "tableEntries refuses the largest index an Int holds" =
  expectEqual
    (Err
      "too many [[gate]] entries: index 4611686018427387903 is past the limit of 100000")
    (tableEntries "gate" (load "[gate.4611686018427387903]\nname = \"x\""))

test "tableCount of the largest index an Int holds does not overflow" =
  expectEqual
    4611686018427387903
    (tableCount "gate" (load "[gate.4611686018427387903]\nname = \"x\""))

test "tableEntry of the largest index an Int holds is present" =
  expectEqual
    (Some (Toml [("name", TString "x")]))
    (tableEntry
      "gate"
      4611686018427387903
      (load "[gate.4611686018427387903]\nname = \"x\""))

test "tableEntry of a negative index is None" =
  expectEqual None (tableEntry "gate" (0 - 1) (load multi))

test "tableEntry one past the last entry is None" =
  expectEqual None (tableEntry "gate" 3 (load multi))

test "tableEntry of the last entry is present" =
  expectEqual
    (Some "c")
    (tableEntry "gate" 2 (load multi) |> flatMap (getString "name"))

test "a key followed by a no-break space keeps it in the key" =
  expectEqual (Ok (Toml [("key ", TInt 1)])) (parse "key = 1\n")

test "a table header with a no-break space inside the brackets keeps it" =
  expectEqual (Ok (Toml [("a .k", TString "v")])) (parse "[a ]\nk = \"v\"\n")

-- ── Basic-string escapes ─────────────────────────────────────────────────────

-- The one-character string for a code point.
codeStr : Int -> String
codeStr n = match charFromCode n
  Some c => charToStr c
  None => ""

str : String -> Result String Toml
str v = Ok (Toml [("k", TString v)])

test "each TOML escape decodes" = expectEach [
  ("\\b", expectEqual (str (codeStr 8)) (parse "k = \"\\b\"")),
  ("\\t", expectEqual (str (codeStr 9)) (parse "k = \"\\t\"")),
  ("\\n", expectEqual (str (codeStr 10)) (parse "k = \"\\n\"")),
  ("\\f", expectEqual (str (codeStr 12)) (parse "k = \"\\f\"")),
  ("\\r", expectEqual (str (codeStr 13)) (parse "k = \"\\r\"")),
  ("\\\"", expectEqual (str "\"") (parse "k = \"\\\"\"")),
  ("\\\\", expectEqual (str "\\") (parse "k = \"\\\\\"")),
  ("\\u00e9", expectEqual (str "é") (parse "k = \"\\u00e9\"")),
  ("\\u00E9", expectEqual (str "é") (parse "k = \"\\u00E9\"")),
  (
    "\\U0001F600",
    expectEqual (str (codeStr 128512)) (parse "k = \"\\U0001F600\""),
  ),
  ("mixed", expectEqual (str "a\nb\"c") (parse "k = \"a\\nb\\\"c\"")),
  (
    "a raw tab",
    expectEqual (str (codeStr 9)) (parse ("k = \"" ++ codeStr 9 ++ "\"")),
  ),
]

test "an invalid string is an Err naming the key and the character" = expectEach
  [
    (
      "unknown escape",
      expectErrContains "key 'k': unknown escape '\\q'" (parse "k = \"a\\qb\""),
    ),
    (
      "surrogate",
      expectErrContains
        "key 'k': U+d800 is not a Unicode scalar value"
        (parse "k = \"\\uD800\""),
    ),
    (
      "past U+10FFFF",
      expectErrContains
        "U+110000 is not a Unicode scalar value"
        (parse "k = \"\\U00110000\""),
    ),
    (
      "short \\u",
      expectErrContains
        "key 'k': \\u needs 4 hex digits"
        (parse "k = \"\\u12\""),
    ),
    (
      "short \\U",
      expectErrContains
        "key 'k': \\U needs 8 hex digits"
        (parse "k = \"\\U0001F60\""),
    ),
    (
      "raw LF",
      expectErrContains
        "key 'k': unterminated string"
        (parse ("k = \"a" ++ codeStr 10 ++ "b\"")),
    ),
    (
      "missing closing quote",
      expectErrContains
        "key 'k': unterminated string (a string must close on the same line"
        (parse "k = \"abc"),
    ),
    (
      "escape of a control character",
      expectErrContains
        "key 'k': unknown escape U+0001"
        (parse ("k = \"a\\" ++ codeStr 1 ++ "b\"")),
    ),
    (
      "raw U+0001",
      expectErrContains
        "key 'k': raw control character U+0001"
        (parse ("k = \"" ++ codeStr 1 ++ "\"")),
    ),
    (
      "raw DEL",
      expectErrContains
        "key 'k': raw control character U+007f"
        (parse ("k = \"" ++ codeStr 127 ++ "\"")),
    ),
    (
      "in an array",
      expectErrContains
        "key 'xs': unknown escape '\\q'"
        (parse "xs = [\"ok\", \"\\q\"]"),
    ),
  ]

test "an escaped quote does not end a string or start a comment" = expectEach [
  ("quote then hash", expectEqual (str "a\"#b") (parse "k = \"a\\\"#b\" # c")),
  (
    "escaped backslash closes",
    expectEqual (str "a\\") (parse "k = \"a\\\\\" # c"),
  ),
  (
    "backslash outside a string is not special",
    expectEqual (Ok (Toml [("k", TInt 1)])) (parse "k = 1 # \\"),
  ),
]

test "an array of strings with escapes parses" =
  expectEqual
    (Ok (Toml [("xs", TArray ["a\"b", "c\\d", "e\nf"])]))
    (parse "xs = [\"a\\\"b\", \"c\\\\d\", \"e\\nf\"] # note")

test "display spells escapes the way parse reads them" = expectEach [
  (
    "quote and backslash",
    expectEqual "\"a\\\"\\\\\"" (display (TString "a\"\\")),
  ),
  ("newline", expectEqual "\"\\n\"" (display (TString "\n"))),
  ("control", expectEqual "\"\\u0001\"" (display (TString (codeStr 1)))),
  ("array", expectEqual "[\"x\\\"y\", \"z\"]" (display (TArray ["x\"y", "z"]))),
]

-- A string built from arbitrary code points below U+012C: quotes, backslashes,
-- newlines and every other control character all occur.
stringOfCodes : List Int -> String
stringOfCodes ns = stringConcat (map (n => codeStr ((n % 300 + 300) % 300)) ns)

prop "parse reads back what display writes for a string" (ns : List Int) =
  let s = stringOfCodes ns
  parse ("k = " ++ display (TString s)) == str s

prop "parse reads back what display writes for an array of strings" (ns : List Int) (ms : List Int) =
  let xs = [stringOfCodes ns, stringOfCodes ms]
  parse ("xs = " ++ display (TArray xs)) == Ok (Toml [("xs", TArray xs)])
# DESUGAR
(DUse false (UseGroup ("toml") ((mem "Toml" true) (mem "TomlValue" true) (mem "parse" false) (mem "tableCount" false) (mem "tableEntry" false) (mem "tableEntries" false) (mem "getString" false))))
(DUse false (UseGroup ("test") ((mem "expectEach" false) (mem "expectEqual" false) (mem "expectErrContains" false) (mem "expectOkThen" false))))
(DTypeSig false "multi" (TyCon "String"))
(DFunDef false "multi" () (ELit (LString "[package]\nname = \"p\"\n[[gate]]\nname = \"a\"\nshard = 1\n[[other]]\nname = \"x\"\n[[gate]]\nname = \"b\"\n[[other]]\nname = \"y\"\n[[gate]]\nname = \"c\"\nshard = 3\n")))
(DTypeSig false "load" (TyFun (TyCon "String") (TyCon "Toml")))
(DFunDef false "load" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Ok" (PVar "doc")) () (EVar "doc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EVar "e")))))
(DTypeSig false "entriesByIndex" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Toml"))))))
(DFunDef false "entriesByIndex" ((PVar "name") (PVar "doc")) (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "tableEntry") (EVar "name")) (EVar "i")) (EVar "doc")))) (ERangeList (ELit (LInt 0)) (EApp (EApp (EVar "tableCount") (EVar "name")) (EVar "doc")) false)))
(DTest false "tableEntries equals tableEntry at every index, on a multi-table document" (EBlock (DoLet false false (PVar "doc") (EApp (EVar "load") (EVar "multi"))) (DoExpr (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "map") (EVar "Some")) (EVar "es"))) (EApp (EApp (EVar "entriesByIndex") (ELit (LString "gate"))) (EVar "doc"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EVar "doc"))))))
(DTest false "tableEntries agrees with tableEntry for a second table in the same document" (EBlock (DoLet false false (PVar "doc") (EApp (EVar "load") (EVar "multi"))) (DoExpr (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "map") (EVar "Some")) (EVar "es"))) (EApp (EApp (EVar "entriesByIndex") (ELit (LString "other"))) (EVar "doc"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "other"))) (EVar "doc"))))))
(DTest false "tableEntries keeps document order" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Some") (ELit (LString "a"))) (EApp (EVar "Some") (ELit (LString "b"))) (EApp (EVar "Some") (ELit (LString "c"))))) (EApp (EApp (EVar "map") (EApp (EVar "getString") (ELit (LString "name")))) (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntries entries carry unqualified keys" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Some") (ELit (LString "1"))))) (EApp (EApp (EVar "map") (EApp (EVar "getString") (ELit (LString "name")))) (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[[gate]]\nname = \"1\""))))))
(DTest false "tableEntries is empty when there are no entries" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EApp (EVar "length") (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[package]\nname = \"p\""))))))
(DTest false "tableEntries does not take a longer table name for a prefix" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 1))) (EApp (EVar "length") (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[[gate]]\nname = \"a\"\n[[gates]]\nname = \"b\""))))))
(DTest false "tableEntries refuses an index past the limit, naming the table and the index" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "too many [[gate]] entries: index 5000000 is past the limit of 100000")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[gate.5000000]\nname = \"x\""))))))
(DTest false "tableEntries refuses the first index past the limit" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "too many [[gate]] entries: index 100000 is past the limit of 100000")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[gate.100000]\nname = \"x\""))))))
(DTest false "tableEntries refuses the largest index an Int holds" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "too many [[gate]] entries: index 4611686018427387903 is past the limit of 100000")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[gate.4611686018427387903]\nname = \"x\""))))))
(DTest false "tableCount of the largest index an Int holds does not overflow" (EApp (EApp (EVar "expectEqual") (ELit (LInt 4611686018427387903))) (EApp (EApp (EVar "tableCount") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[gate.4611686018427387903]\nname = \"x\""))))))
(DTest false "tableEntry of the largest index an Int holds is present" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "TString") (ELit (LString "x")))))))) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 4611686018427387903))) (EApp (EVar "load") (ELit (LString "[gate.4611686018427387903]\nname = \"x\""))))))
(DTest false "tableEntry of a negative index is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntry one past the last entry is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 3))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntry of the last entry is present" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "c")))) (EBinOp "|>" (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 2))) (EApp (EVar "load") (EVar "multi"))) (EApp (EVar "flatMap") (EApp (EVar "getString") (ELit (LString "name")))))))
(DTest false "a key followed by a no-break space keeps it in the key" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "key ")) (EApp (EVar "TInt") (ELit (LInt 1)))))))) (EApp (EVar "parse") (ELit (LString "key = 1\n")))))
(DTest false "a table header with a no-break space inside the brackets keeps it" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "a .k")) (EApp (EVar "TString") (ELit (LString "v")))))))) (EApp (EVar "parse") (ELit (LString "[a ]\nk = \"v\"\n")))))
(DTypeSig false "codeStr" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "codeStr" ((PVar "n")) (EMatch (EApp (EVar "charFromCode") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "charToStr") (EVar "c"))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "str" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Toml"))))
(DFunDef false "str" ((PVar "v")) (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "k")) (EApp (EVar "TString") (EVar "v")))))))
(DTest false "each TOML escape decodes" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "\\b")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 8))))) (EApp (EVar "parse") (ELit (LString "k = \"\\b\""))))) (ETuple (ELit (LString "\\t")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 9))))) (EApp (EVar "parse") (ELit (LString "k = \"\\t\""))))) (ETuple (ELit (LString "\\n")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 10))))) (EApp (EVar "parse") (ELit (LString "k = \"\\n\""))))) (ETuple (ELit (LString "\\f")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 12))))) (EApp (EVar "parse") (ELit (LString "k = \"\\f\""))))) (ETuple (ELit (LString "\\r")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 13))))) (EApp (EVar "parse") (ELit (LString "k = \"\\r\""))))) (ETuple (ELit (LString "\\\"")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "\"")))) (EApp (EVar "parse") (ELit (LString "k = \"\\\"\""))))) (ETuple (ELit (LString "\\\\")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "\\")))) (EApp (EVar "parse") (ELit (LString "k = \"\\\\\""))))) (ETuple (ELit (LString "\\u00e9")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "é")))) (EApp (EVar "parse") (ELit (LString "k = \"\\u00e9\""))))) (ETuple (ELit (LString "\\u00E9")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "é")))) (EApp (EVar "parse") (ELit (LString "k = \"\\u00E9\""))))) (ETuple (ELit (LString "\\U0001F600")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 128512))))) (EApp (EVar "parse") (ELit (LString "k = \"\\U0001F600\""))))) (ETuple (ELit (LString "mixed")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "a\nb\"c")))) (EApp (EVar "parse") (ELit (LString "k = \"a\\nb\\\"c\""))))) (ETuple (ELit (LString "a raw tab")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 9))))) (EApp (EVar "parse") (EBinOp "++" (EBinOp "++" (ELit (LString "k = \"")) (EApp (EVar "codeStr") (ELit (LInt 9)))) (ELit (LString "\"")))))))))
(DTest false "an invalid string is an Err naming the key and the character" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "unknown escape")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': unknown escape '\\q'"))) (EApp (EVar "parse") (ELit (LString "k = \"a\\qb\""))))) (ETuple (ELit (LString "surrogate")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': U+d800 is not a Unicode scalar value"))) (EApp (EVar "parse") (ELit (LString "k = \"\\uD800\""))))) (ETuple (ELit (LString "past U+10FFFF")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "U+110000 is not a Unicode scalar value"))) (EApp (EVar "parse") (ELit (LString "k = \"\\U00110000\""))))) (ETuple (ELit (LString "short \\u")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': \\u needs 4 hex digits"))) (EApp (EVar "parse") (ELit (LString "k = \"\\u12\""))))) (ETuple (ELit (LString "short \\U")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': \\U needs 8 hex digits"))) (EApp (EVar "parse") (ELit (LString "k = \"\\U0001F60\""))))) (ETuple (ELit (LString "raw LF")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': unterminated string"))) (EApp (EVar "parse") (EBinOp "++" (EBinOp "++" (ELit (LString "k = \"a")) (EApp (EVar "codeStr") (ELit (LInt 10)))) (ELit (LString "b\"")))))) (ETuple (ELit (LString "missing closing quote")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': unterminated string (a string must close on the same line"))) (EApp (EVar "parse") (ELit (LString "k = \"abc"))))) (ETuple (ELit (LString "escape of a control character")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': unknown escape U+0001"))) (EApp (EVar "parse") (EBinOp "++" (EBinOp "++" (ELit (LString "k = \"a\\")) (EApp (EVar "codeStr") (ELit (LInt 1)))) (ELit (LString "b\"")))))) (ETuple (ELit (LString "raw U+0001")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': raw control character U+0001"))) (EApp (EVar "parse") (EBinOp "++" (EBinOp "++" (ELit (LString "k = \"")) (EApp (EVar "codeStr") (ELit (LInt 1)))) (ELit (LString "\"")))))) (ETuple (ELit (LString "raw DEL")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': raw control character U+007f"))) (EApp (EVar "parse") (EBinOp "++" (EBinOp "++" (ELit (LString "k = \"")) (EApp (EVar "codeStr") (ELit (LInt 127)))) (ELit (LString "\"")))))) (ETuple (ELit (LString "in an array")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'xs': unknown escape '\\q'"))) (EApp (EVar "parse") (ELit (LString "xs = [\"ok\", \"\\q\"]"))))))))
(DTest false "an escaped quote does not end a string or start a comment" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "quote then hash")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "a\"#b")))) (EApp (EVar "parse") (ELit (LString "k = \"a\\\"#b\" # c"))))) (ETuple (ELit (LString "escaped backslash closes")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "a\\")))) (EApp (EVar "parse") (ELit (LString "k = \"a\\\\\" # c"))))) (ETuple (ELit (LString "backslash outside a string is not special")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "k")) (EApp (EVar "TInt") (ELit (LInt 1)))))))) (EApp (EVar "parse") (ELit (LString "k = 1 # \\"))))))))
(DTest false "an array of strings with escapes parses" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "xs")) (EApp (EVar "TArray") (EListLit (ELit (LString "a\"b")) (ELit (LString "c\\d")) (ELit (LString "e\nf"))))))))) (EApp (EVar "parse") (ELit (LString "xs = [\"a\\\"b\", \"c\\\\d\", \"e\\nf\"] # note")))))
(DTest false "display spells escapes the way parse reads them" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "quote and backslash")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"a\\\"\\\\\""))) (EApp (EVar "display") (EApp (EVar "TString") (ELit (LString "a\"\\")))))) (ETuple (ELit (LString "newline")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"\\n\""))) (EApp (EVar "display") (EApp (EVar "TString") (ELit (LString "\n")))))) (ETuple (ELit (LString "control")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"\\u0001\""))) (EApp (EVar "display") (EApp (EVar "TString") (EApp (EVar "codeStr") (ELit (LInt 1))))))) (ETuple (ELit (LString "array")) (EApp (EApp (EVar "expectEqual") (ELit (LString "[\"x\\\"y\", \"z\"]"))) (EApp (EVar "display") (EApp (EVar "TArray") (EListLit (ELit (LString "x\"y")) (ELit (LString "z"))))))))))
(DTypeSig false "stringOfCodes" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "String")))
(DFunDef false "stringOfCodes" ((PVar "ns")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EVar "codeStr") (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (ELit (LInt 300))) (ELit (LInt 300))) (ELit (LInt 300)))))) (EVar "ns"))))
(DProp false "parse reads back what display writes for a string" ((pp "ns" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "stringOfCodes") (EVar "ns"))) (DoExpr (EBinOp "==" (EApp (EVar "parse") (EBinOp "++" (ELit (LString "k = ")) (EApp (EVar "display") (EApp (EVar "TString") (EVar "s"))))) (EApp (EVar "str") (EVar "s"))))))
(DProp false "parse reads back what display writes for an array of strings" ((pp "ns" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ms" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "xs") (EListLit (EApp (EVar "stringOfCodes") (EVar "ns")) (EApp (EVar "stringOfCodes") (EVar "ms")))) (DoExpr (EBinOp "==" (EApp (EVar "parse") (EBinOp "++" (ELit (LString "xs = ")) (EApp (EVar "display") (EApp (EVar "TArray") (EVar "xs"))))) (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "xs")) (EApp (EVar "TArray") (EVar "xs"))))))))))
# MARK
(DUse false (UseGroup ("toml") ((mem "Toml" true) (mem "TomlValue" true) (mem "parse" false) (mem "tableCount" false) (mem "tableEntry" false) (mem "tableEntries" false) (mem "getString" false))))
(DUse false (UseGroup ("test") ((mem "expectEach" false) (mem "expectEqual" false) (mem "expectErrContains" false) (mem "expectOkThen" false))))
(DTypeSig false "multi" (TyCon "String"))
(DFunDef false "multi" () (ELit (LString "[package]\nname = \"p\"\n[[gate]]\nname = \"a\"\nshard = 1\n[[other]]\nname = \"x\"\n[[gate]]\nname = \"b\"\n[[other]]\nname = \"y\"\n[[gate]]\nname = \"c\"\nshard = 3\n")))
(DTypeSig false "load" (TyFun (TyCon "String") (TyCon "Toml")))
(DFunDef false "load" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Ok" (PVar "doc")) () (EVar "doc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EVar "e")))))
(DTypeSig false "entriesByIndex" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Toml"))))))
(DFunDef false "entriesByIndex" ((PVar "name") (PVar "doc")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "tableEntry") (EVar "name")) (EVar "i")) (EVar "doc")))) (ERangeList (ELit (LInt 0)) (EApp (EApp (EVar "tableCount") (EVar "name")) (EVar "doc")) false)))
(DTest false "tableEntries equals tableEntry at every index, on a multi-table document" (EBlock (DoLet false false (PVar "doc") (EApp (EVar "load") (EVar "multi"))) (DoExpr (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EMethodRef "map") (EVar "Some")) (EVar "es"))) (EApp (EApp (EVar "entriesByIndex") (ELit (LString "gate"))) (EVar "doc"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EVar "doc"))))))
(DTest false "tableEntries agrees with tableEntry for a second table in the same document" (EBlock (DoLet false false (PVar "doc") (EApp (EVar "load") (EVar "multi"))) (DoExpr (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EApp (EApp (EMethodRef "map") (EVar "Some")) (EVar "es"))) (EApp (EApp (EVar "entriesByIndex") (ELit (LString "other"))) (EVar "doc"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "other"))) (EVar "doc"))))))
(DTest false "tableEntries keeps document order" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Some") (ELit (LString "a"))) (EApp (EVar "Some") (ELit (LString "b"))) (EApp (EVar "Some") (ELit (LString "c"))))) (EApp (EApp (EMethodRef "map") (EApp (EVar "getString") (ELit (LString "name")))) (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntries entries carry unqualified keys" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Some") (ELit (LString "1"))))) (EApp (EApp (EMethodRef "map") (EApp (EVar "getString") (ELit (LString "name")))) (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[[gate]]\nname = \"1\""))))))
(DTest false "tableEntries is empty when there are no entries" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EApp (EMethodRef "length") (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[package]\nname = \"p\""))))))
(DTest false "tableEntries does not take a longer table name for a prefix" (EApp (EApp (EVar "expectOkThen") (ELam ((PVar "es")) (EApp (EApp (EVar "expectEqual") (ELit (LInt 1))) (EApp (EMethodRef "length") (EVar "es"))))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[[gate]]\nname = \"a\"\n[[gates]]\nname = \"b\""))))))
(DTest false "tableEntries refuses an index past the limit, naming the table and the index" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "too many [[gate]] entries: index 5000000 is past the limit of 100000")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[gate.5000000]\nname = \"x\""))))))
(DTest false "tableEntries refuses the first index past the limit" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "too many [[gate]] entries: index 100000 is past the limit of 100000")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[gate.100000]\nname = \"x\""))))))
(DTest false "tableEntries refuses the largest index an Int holds" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "too many [[gate]] entries: index 4611686018427387903 is past the limit of 100000")))) (EApp (EApp (EVar "tableEntries") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[gate.4611686018427387903]\nname = \"x\""))))))
(DTest false "tableCount of the largest index an Int holds does not overflow" (EApp (EApp (EVar "expectEqual") (ELit (LInt 4611686018427387903))) (EApp (EApp (EVar "tableCount") (ELit (LString "gate"))) (EApp (EVar "load") (ELit (LString "[gate.4611686018427387903]\nname = \"x\""))))))
(DTest false "tableEntry of the largest index an Int holds is present" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "TString") (ELit (LString "x")))))))) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 4611686018427387903))) (EApp (EVar "load") (ELit (LString "[gate.4611686018427387903]\nname = \"x\""))))))
(DTest false "tableEntry of a negative index is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntry one past the last entry is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 3))) (EApp (EVar "load") (EVar "multi")))))
(DTest false "tableEntry of the last entry is present" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "c")))) (EBinOp "|>" (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (ELit (LInt 2))) (EApp (EVar "load") (EVar "multi"))) (EApp (EDictApp "flatMap") (EApp (EVar "getString") (ELit (LString "name")))))))
(DTest false "a key followed by a no-break space keeps it in the key" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "key ")) (EApp (EVar "TInt") (ELit (LInt 1)))))))) (EApp (EVar "parse") (ELit (LString "key = 1\n")))))
(DTest false "a table header with a no-break space inside the brackets keeps it" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "a .k")) (EApp (EVar "TString") (ELit (LString "v")))))))) (EApp (EVar "parse") (ELit (LString "[a ]\nk = \"v\"\n")))))
(DTypeSig false "codeStr" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "codeStr" ((PVar "n")) (EMatch (EApp (EVar "charFromCode") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "charToStr") (EVar "c"))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "str" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Toml"))))
(DFunDef false "str" ((PVar "v")) (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "k")) (EApp (EVar "TString") (EVar "v")))))))
(DTest false "each TOML escape decodes" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "\\b")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 8))))) (EApp (EVar "parse") (ELit (LString "k = \"\\b\""))))) (ETuple (ELit (LString "\\t")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 9))))) (EApp (EVar "parse") (ELit (LString "k = \"\\t\""))))) (ETuple (ELit (LString "\\n")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 10))))) (EApp (EVar "parse") (ELit (LString "k = \"\\n\""))))) (ETuple (ELit (LString "\\f")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 12))))) (EApp (EVar "parse") (ELit (LString "k = \"\\f\""))))) (ETuple (ELit (LString "\\r")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 13))))) (EApp (EVar "parse") (ELit (LString "k = \"\\r\""))))) (ETuple (ELit (LString "\\\"")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "\"")))) (EApp (EVar "parse") (ELit (LString "k = \"\\\"\""))))) (ETuple (ELit (LString "\\\\")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "\\")))) (EApp (EVar "parse") (ELit (LString "k = \"\\\\\""))))) (ETuple (ELit (LString "\\u00e9")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "é")))) (EApp (EVar "parse") (ELit (LString "k = \"\\u00e9\""))))) (ETuple (ELit (LString "\\u00E9")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "é")))) (EApp (EVar "parse") (ELit (LString "k = \"\\u00E9\""))))) (ETuple (ELit (LString "\\U0001F600")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 128512))))) (EApp (EVar "parse") (ELit (LString "k = \"\\U0001F600\""))))) (ETuple (ELit (LString "mixed")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "a\nb\"c")))) (EApp (EVar "parse") (ELit (LString "k = \"a\\nb\\\"c\""))))) (ETuple (ELit (LString "a raw tab")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (EApp (EVar "codeStr") (ELit (LInt 9))))) (EApp (EVar "parse") (EBinOp "++" (EBinOp "++" (ELit (LString "k = \"")) (EApp (EVar "codeStr") (ELit (LInt 9)))) (ELit (LString "\"")))))))))
(DTest false "an invalid string is an Err naming the key and the character" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "unknown escape")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': unknown escape '\\q'"))) (EApp (EVar "parse") (ELit (LString "k = \"a\\qb\""))))) (ETuple (ELit (LString "surrogate")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': U+d800 is not a Unicode scalar value"))) (EApp (EVar "parse") (ELit (LString "k = \"\\uD800\""))))) (ETuple (ELit (LString "past U+10FFFF")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "U+110000 is not a Unicode scalar value"))) (EApp (EVar "parse") (ELit (LString "k = \"\\U00110000\""))))) (ETuple (ELit (LString "short \\u")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': \\u needs 4 hex digits"))) (EApp (EVar "parse") (ELit (LString "k = \"\\u12\""))))) (ETuple (ELit (LString "short \\U")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': \\U needs 8 hex digits"))) (EApp (EVar "parse") (ELit (LString "k = \"\\U0001F60\""))))) (ETuple (ELit (LString "raw LF")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': unterminated string"))) (EApp (EVar "parse") (EBinOp "++" (EBinOp "++" (ELit (LString "k = \"a")) (EApp (EVar "codeStr") (ELit (LInt 10)))) (ELit (LString "b\"")))))) (ETuple (ELit (LString "missing closing quote")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': unterminated string (a string must close on the same line"))) (EApp (EVar "parse") (ELit (LString "k = \"abc"))))) (ETuple (ELit (LString "escape of a control character")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': unknown escape U+0001"))) (EApp (EVar "parse") (EBinOp "++" (EBinOp "++" (ELit (LString "k = \"a\\")) (EApp (EVar "codeStr") (ELit (LInt 1)))) (ELit (LString "b\"")))))) (ETuple (ELit (LString "raw U+0001")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': raw control character U+0001"))) (EApp (EVar "parse") (EBinOp "++" (EBinOp "++" (ELit (LString "k = \"")) (EApp (EVar "codeStr") (ELit (LInt 1)))) (ELit (LString "\"")))))) (ETuple (ELit (LString "raw DEL")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'k': raw control character U+007f"))) (EApp (EVar "parse") (EBinOp "++" (EBinOp "++" (ELit (LString "k = \"")) (EApp (EVar "codeStr") (ELit (LInt 127)))) (ELit (LString "\"")))))) (ETuple (ELit (LString "in an array")) (EApp (EApp (EVar "expectErrContains") (ELit (LString "key 'xs': unknown escape '\\q'"))) (EApp (EVar "parse") (ELit (LString "xs = [\"ok\", \"\\q\"]"))))))))
(DTest false "an escaped quote does not end a string or start a comment" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "quote then hash")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "a\"#b")))) (EApp (EVar "parse") (ELit (LString "k = \"a\\\"#b\" # c"))))) (ETuple (ELit (LString "escaped backslash closes")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "str") (ELit (LString "a\\")))) (EApp (EVar "parse") (ELit (LString "k = \"a\\\\\" # c"))))) (ETuple (ELit (LString "backslash outside a string is not special")) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "k")) (EApp (EVar "TInt") (ELit (LInt 1)))))))) (EApp (EVar "parse") (ELit (LString "k = 1 # \\"))))))))
(DTest false "an array of strings with escapes parses" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "xs")) (EApp (EVar "TArray") (EListLit (ELit (LString "a\"b")) (ELit (LString "c\\d")) (ELit (LString "e\nf"))))))))) (EApp (EVar "parse") (ELit (LString "xs = [\"a\\\"b\", \"c\\\\d\", \"e\\nf\"] # note")))))
(DTest false "display spells escapes the way parse reads them" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "quote and backslash")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"a\\\"\\\\\""))) (EApp (EMethodRef "display") (EApp (EVar "TString") (ELit (LString "a\"\\")))))) (ETuple (ELit (LString "newline")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"\\n\""))) (EApp (EMethodRef "display") (EApp (EVar "TString") (ELit (LString "\n")))))) (ETuple (ELit (LString "control")) (EApp (EApp (EVar "expectEqual") (ELit (LString "\"\\u0001\""))) (EApp (EMethodRef "display") (EApp (EVar "TString") (EApp (EVar "codeStr") (ELit (LInt 1))))))) (ETuple (ELit (LString "array")) (EApp (EApp (EVar "expectEqual") (ELit (LString "[\"x\\\"y\", \"z\"]"))) (EApp (EMethodRef "display") (EApp (EVar "TArray") (EListLit (ELit (LString "x\"y")) (ELit (LString "z"))))))))))
(DTypeSig false "stringOfCodes" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "String")))
(DFunDef false "stringOfCodes" ((PVar "ns")) (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EVar "codeStr") (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (ELit (LInt 300))) (ELit (LInt 300))) (ELit (LInt 300)))))) (EVar "ns"))))
(DProp false "parse reads back what display writes for a string" ((pp "ns" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "stringOfCodes") (EVar "ns"))) (DoExpr (EBinOp "==" (EApp (EVar "parse") (EBinOp "++" (ELit (LString "k = ")) (EApp (EMethodRef "display") (EApp (EVar "TString") (EVar "s"))))) (EApp (EVar "str") (EVar "s"))))))
(DProp false "parse reads back what display writes for an array of strings" ((pp "ns" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ms" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "xs") (EListLit (EApp (EVar "stringOfCodes") (EVar "ns")) (EApp (EVar "stringOfCodes") (EVar "ms")))) (DoExpr (EBinOp "==" (EApp (EVar "parse") (EBinOp "++" (ELit (LString "xs = ")) (EApp (EMethodRef "display") (EApp (EVar "TArray") (EVar "xs"))))) (EApp (EVar "Ok") (EApp (EVar "Toml") (EListLit (ETuple (ELit (LString "xs")) (EApp (EVar "TArray") (EVar "xs"))))))))))
