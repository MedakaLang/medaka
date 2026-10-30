# META
source_lines=243
stages=DESUGAR,MARK
# SOURCE
-- Tests for the path, pretty-printing and line readers in `stdlib/json.mdk`,
-- and for the strict number and string grammar of `parse`.

import json.{
  Json(..),
  atPath,
  asNumber,
  jArray,
  jObject,
  parse,
  parseLines,
  pretty,
  stringify,
  stringifyLines,
}
import string.{join}
import test.{
  Expectation,
  expectAll,
  expectEqual,
  expectEqualText,
  expectErrContains,
  expectOkThen,
}

sample : Json
sample = jObject [
  (
    "a",
    jObject [("items", jArray [JInt 10, JInt 20, JInt 30]), ("s", JString "x")],
  ),
  ("7", JBool True),
  ("n", JNull),
  ("i", JInt 1),
  ("f", JFloat 1.5),
  ("b", JBool False),
]

pathErr : List String -> Result String Json
pathErr steps = atPath steps sample

test "atPath of an empty path is the root" =
  expectEqual (Ok sample) (atPath [] sample)

test "atPath follows keys and indexes" =
  expectEqual (Ok (JInt 20)) (atPath ["a", "items", "1"] sample)

test "atPath takes a digit key on an object as a key" =
  expectEqual (Ok (JBool True)) (atPath ["7"] sample)

test "atPath names a missing key" =
  expectEqual (Err "at a: no key \"b\"") (pathErr ["a", "b"])

test "atPath names an index out of range" =
  expectEqual
    (Err "at a.items: index 5 out of range (3 elements)")
    (pathErr ["a", "items", "5"])

test "atPath names a step into a string" =
  expectEqual
    (Err "at a.s: expected object or array, found string")
    (pathErr ["a", "s", "z"])

test "atPath names a step into each scalar" = expectAll [
  expectEqual
    (Err "at n: expected object or array, found null")
    (pathErr ["n", "z"]),
  expectEqual
    (Err "at b: expected object or array, found bool")
    (pathErr ["b", "z"]),
  expectEqual
    (Err "at i: expected object or array, found int")
    (pathErr ["i", "z"]),
  expectEqual
    (Err "at f: expected object or array, found float")
    (pathErr ["f", "z"]),
]

test "atPath names the root when the first step fails" = expectAll [
  expectEqual (Err "at <root>: no key \"zz\"") (pathErr ["zz"]),
  expectEqual
    (Err "at <root>: expected object or array, found int")
    (atPath ["x"] (JInt 1)),
]

test "atPath refuses a signed or zero-padded index" = expectAll [
  expectErrContains
    "at a.items: invalid array index \"-1\""
    (pathErr ["a", "items", "-1"]),
  expectErrContains
    "at a.items: invalid array index \"01\""
    (pathErr ["a", "items", "01"]),
  expectErrContains
    "at a.items: invalid array index \"\""
    (pathErr ["a", "items", ""]),
  expectErrContains
    "at a.items: invalid array index \"x\""
    (pathErr ["a", "items", "x"]),
]

test "atPath accepts index zero" =
  expectEqual (Ok (JInt 10)) (atPath ["a", "items", "0"] sample)

test "asNumber converts an int and keeps a float" = expectAll [
  expectEqual (Some 1.0) (asNumber (JInt 1)),
  expectEqual (Some 1.5) (asNumber (JFloat 1.5)),
  expectEqual None (asNumber (JString "1")),
  expectEqual None (asNumber JNull),
]

-- The expected texts below are the output of Python's
-- `json.dumps(v, indent=n, ensure_ascii=False)` for the same document.
prettySource : String
prettySource =
  "{\"name\":\"caf\\u00e9 \\u65e5\\u672c\",\"empty_a\":[],\"empty_o\":{},\"nested\":[[],{\"k\":[1,null,true,false]},-5],\"floats\":[1.0,0.1,1e20,-0.0,1.5e-7,0.0001],\"ctl\":\"a\\nb\\t\\\"q\\\"\\\\ \\u0001 \\u001f\",\"k\":{\"x\":{\"y\":[]}}}"

withDoc : (Json -> Expectation) -> Expectation
withDoc k = expectOkThen k (parse prettySource)

test "pretty 2 matches Python indent=2" = withDoc (j =>
  expectEqualText
    (join "\n" [
      "{", "  \"name\": \"café 日本\",", "  \"empty_a\": [],",
      "  \"empty_o\": {},", "  \"nested\": [", "    [],", "    {",
      "      \"k\": [", "        1,", "        null,", "        true,",
      "        false", "      ]", "    },", "    -5", "  ],", "  \"floats\": [",
      "    1.0,", "    0.1,", "    1e+20,", "    -0.0,", "    1.5e-07,",
      "    0.0001", "  ],",
      "  \"ctl\": \"a\\nb\\t\\\"q\\\"\\\\ \\u0001 \\u001f\",", "  \"k\": {",
      "    \"x\": {", "      \"y\": []", "    }", "  }", "}"
    ])
    (pretty 2 j))

test "pretty 4 matches Python indent=4" = withDoc (j =>
  expectEqualText
    (join "\n" [
      "{", "    \"name\": \"café 日本\",", "    \"empty_a\": [],",
      "    \"empty_o\": {},", "    \"nested\": [", "        [],", "        {",
      "            \"k\": [", "                1,", "                null,",
      "                true,", "                false", "            ]",
      "        },", "        -5", "    ],", "    \"floats\": [", "        1.0,",
      "        0.1,", "        1e+20,", "        -0.0,", "        1.5e-07,",
      "        0.0001", "    ],",
      "    \"ctl\": \"a\\nb\\t\\\"q\\\"\\\\ \\u0001 \\u001f\",", "    \"k\": {",
      "        \"x\": {", "            \"y\": []", "        }", "    }", "}"
    ])
    (pretty 4 j))

test "pretty 0 breaks lines without indentation, as Python indent=0" = withDoc
  (j =>
    expectEqualText
      (join "\n" [
        "{", "\"name\": \"café 日本\",", "\"empty_a\": [],", "\"empty_o\": {},",
        "\"nested\": [", "[],", "{", "\"k\": [", "1,", "null,", "true,",
        "false", "]", "},", "-5", "],", "\"floats\": [", "1.0,", "0.1,",
        "1e+20,", "-0.0,", "1.5e-07,", "0.0001", "],",
        "\"ctl\": \"a\\nb\\t\\\"q\\\"\\\\ \\u0001 \\u001f\",", "\"k\": {",
        "\"x\": {", "\"y\": []", "}", "}", "}"
      ])
      (pretty 0 j))

test "pretty keeps empty containers inline and ends without a newline" = expectAll
  [
    expectEqual "[]" (pretty 2 (jArray [])),
    expectEqual "{}" (pretty 2 (jObject [])),
    expectEqual "[\n  1\n]" (pretty 2 (jArray [JInt 1])),
  ]

test "parse reads back what pretty writes" = withDoc (j => expectAll [
  expectEqual (Ok j) (parse (pretty 2 j)),
  expectEqual (Ok j) (parse (pretty 0 j)),
  expectEqual (Ok j) (parse (pretty 8 j)),
])

test "parseLines numbers lines over the input, blank lines included" =
  expectEqual
    [Ok (JInt 1), Ok (JInt 2), Err "line 5: unexpected end of input"]
    (parseLines "1\n\n  \n2\n[3,")

test "parseLines reads CRLF lines" =
  expectEqual
    [Ok (jObject [("a", JInt 1)]), Ok (jArray [JInt 2])]
    (parseLines "{\"a\":1}\r\n\r\n[2]\r\n")

test "parseLines returns a bad line as an Err and goes on" =
  expectEqual
    [Err "line 1: unexpected character 'x'", Ok (JInt 2)]
    (parseLines "x\n2\n")

test "parseLines of nothing is empty" = expectAll [
  expectEqual [] (parseLines ""),
  expectEqual [] (parseLines "\n \n\n"),
]

test "parseLines keeps a last line without a newline" =
  expectEqual [Ok (JInt 1), Ok (JInt 2)] (parseLines "1\n2")

test "stringifyLines ends each value with a newline" = expectAll [
  expectEqual "" (stringifyLines []),
  expectEqual "1\n\"a\"\n" (stringifyLines [JInt 1, JString "a"]),
]

test "stringifyLines round-trips through parseLines" =
  let js = [
    JNull,
    JInt 3,
    JString "a\nb",
    jArray [JBool True],
    jObject [("k", JFloat 2.5)],
  ]
  expectEqual (map Ok js) (parseLines (stringifyLines js))

test "parse rejects a leading zero before a digit" = expectAll [
  expectErrContains "leading zero" (parse "01"),
  expectErrContains "leading zero" (parse "-01"),
  expectErrContains "leading zero" (parse "00"),
  expectErrContains "leading zero" (parse "01.5"),
  expectErrContains "leading zero" (parse "[1, 007]"),
  expectErrContains "leading zero" (parse "{\"a\": 01700000060}"),
]

test "parse still reads zero in its valid forms" = expectAll [
  expectEqual (Ok (JInt 0)) (parse "0"),
  expectEqual (Ok (JInt 0)) (parse "-0"),
  expectEqual (Ok (JFloat 0.5)) (parse "0.5"),
  expectEqual (Ok (JFloat 0.0)) (parse "0e1"),
  expectEqual (Ok (JFloat (-0.5))) (parse "-0.5"),
]

test "parse rejects an unescaped control character in a string" = expectAll [
  expectErrContains "control character" (parse "\"a\tb\""),
  expectErrContains "control character" (parse "\"a\nb\""),
  expectErrContains "control character" (parse "\"a\rb\""),
  expectErrContains "control character" (parse "\"a\0b\""),
  expectErrContains "control character" (parse "\"a\u{1f}b\""),
  expectErrContains "control character" (parse "{\"k\t\": 1}"),
]

test "parse still reads escaped control characters and a space" = expectAll [
  expectEqual (Ok (JString "a\tb")) (parse "\"a\\tb\""),
  expectEqual (Ok (JString "a\u{01}b")) (parse "\"a\\u0001b\""),
  expectEqual (Ok (JString "a b")) (parse "\"a b\""),
]
# DESUGAR
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "atPath" false) (mem "asNumber" false) (mem "jArray" false) (mem "jObject" false) (mem "parse" false) (mem "parseLines" false) (mem "pretty" false) (mem "stringify" false) (mem "stringifyLines" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectAll" false) (mem "expectEqual" false) (mem "expectEqualText" false) (mem "expectErrContains" false) (mem "expectOkThen" false))))
(DTypeSig false "sample" (TyCon "Json"))
(DFunDef false "sample" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "a")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "items")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JInt") (ELit (LInt 10))) (EApp (EVar "JInt") (ELit (LInt 20))) (EApp (EVar "JInt") (ELit (LInt 30)))))) (ETuple (ELit (LString "s")) (EApp (EVar "JString") (ELit (LString "x"))))))) (ETuple (ELit (LString "7")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "n")) (EVar "JNull")) (ETuple (ELit (LString "i")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "f")) (EApp (EVar "JFloat") (ELit (LFloat 1.5)))) (ETuple (ELit (LString "b")) (EApp (EVar "JBool") (EVar "False"))))))
(DTypeSig false "pathErr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Json"))))
(DFunDef false "pathErr" ((PVar "steps")) (EApp (EApp (EVar "atPath") (EVar "steps")) (EVar "sample")))
(DTest false "atPath of an empty path is the root" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EVar "sample"))) (EApp (EApp (EVar "atPath") (EListLit)) (EVar "sample"))))
(DTest false "atPath follows keys and indexes" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 20))))) (EApp (EApp (EVar "atPath") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString "1")))) (EVar "sample"))))
(DTest false "atPath takes a digit key on an object as a key" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JBool") (EVar "True")))) (EApp (EApp (EVar "atPath") (EListLit (ELit (LString "7")))) (EVar "sample"))))
(DTest false "atPath names a missing key" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at a: no key \"b\"")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "b"))))))
(DTest false "atPath names an index out of range" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at a.items: index 5 out of range (3 elements)")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString "5"))))))
(DTest false "atPath names a step into a string" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at a.s: expected object or array, found string")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "s")) (ELit (LString "z"))))))
(DTest false "atPath names a step into each scalar" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at n: expected object or array, found null")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "n")) (ELit (LString "z"))))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at b: expected object or array, found bool")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "b")) (ELit (LString "z"))))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at i: expected object or array, found int")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "i")) (ELit (LString "z"))))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at f: expected object or array, found float")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "f")) (ELit (LString "z"))))))))
(DTest false "atPath names the root when the first step fails" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at <root>: no key \"zz\"")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "zz"))))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at <root>: expected object or array, found int")))) (EApp (EApp (EVar "atPath") (EListLit (ELit (LString "x")))) (EApp (EVar "JInt") (ELit (LInt 1))))))))
(DTest false "atPath refuses a signed or zero-padded index" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectErrContains") (ELit (LString "at a.items: invalid array index \"-1\""))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString "-1"))))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "at a.items: invalid array index \"01\""))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString "01"))))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "at a.items: invalid array index \"\""))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString ""))))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "at a.items: invalid array index \"x\""))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString "x"))))))))
(DTest false "atPath accepts index zero" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 10))))) (EApp (EApp (EVar "atPath") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString "0")))) (EVar "sample"))))
(DTest false "asNumber converts an int and keeps a float" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 1.0)))) (EApp (EVar "asNumber") (EApp (EVar "JInt") (ELit (LInt 1))))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 1.5)))) (EApp (EVar "asNumber") (EApp (EVar "JFloat") (ELit (LFloat 1.5))))) (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EVar "asNumber") (EApp (EVar "JString") (ELit (LString "1"))))) (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EVar "asNumber") (EVar "JNull"))))))
(DTypeSig false "prettySource" (TyCon "String"))
(DFunDef false "prettySource" () (ELit (LString "{\"name\":\"caf\\u00e9 \\u65e5\\u672c\",\"empty_a\":[],\"empty_o\":{},\"nested\":[[],{\"k\":[1,null,true,false]},-5],\"floats\":[1.0,0.1,1e20,-0.0,1.5e-7,0.0001],\"ctl\":\"a\\nb\\t\\\"q\\\"\\\\ \\u0001 \\u001f\",\"k\":{\"x\":{\"y\":[]}}}")))
(DTypeSig false "withDoc" (TyFun (TyFun (TyCon "Json") (TyCon "Expectation")) (TyCon "Expectation")))
(DFunDef false "withDoc" ((PVar "k")) (EApp (EApp (EVar "expectOkThen") (EVar "k")) (EApp (EVar "parse") (EVar "prettySource"))))
(DTest false "pretty 2 matches Python indent=2" (EApp (EVar "withDoc") (ELam ((PVar "j")) (EApp (EApp (EVar "expectEqualText") (EApp (EApp (EVar "join") (ELit (LString "\n"))) (EListLit (ELit (LString "{")) (ELit (LString "  \"name\": \"café 日本\",")) (ELit (LString "  \"empty_a\": [],")) (ELit (LString "  \"empty_o\": {},")) (ELit (LString "  \"nested\": [")) (ELit (LString "    [],")) (ELit (LString "    {")) (ELit (LString "      \"k\": [")) (ELit (LString "        1,")) (ELit (LString "        null,")) (ELit (LString "        true,")) (ELit (LString "        false")) (ELit (LString "      ]")) (ELit (LString "    },")) (ELit (LString "    -5")) (ELit (LString "  ],")) (ELit (LString "  \"floats\": [")) (ELit (LString "    1.0,")) (ELit (LString "    0.1,")) (ELit (LString "    1e+20,")) (ELit (LString "    -0.0,")) (ELit (LString "    1.5e-07,")) (ELit (LString "    0.0001")) (ELit (LString "  ],")) (ELit (LString "  \"ctl\": \"a\\nb\\t\\\"q\\\"\\\\ \\u0001 \\u001f\",")) (ELit (LString "  \"k\": {")) (ELit (LString "    \"x\": {")) (ELit (LString "      \"y\": []")) (ELit (LString "    }")) (ELit (LString "  }")) (ELit (LString "}"))))) (EApp (EApp (EVar "pretty") (ELit (LInt 2))) (EVar "j"))))))
(DTest false "pretty 4 matches Python indent=4" (EApp (EVar "withDoc") (ELam ((PVar "j")) (EApp (EApp (EVar "expectEqualText") (EApp (EApp (EVar "join") (ELit (LString "\n"))) (EListLit (ELit (LString "{")) (ELit (LString "    \"name\": \"café 日本\",")) (ELit (LString "    \"empty_a\": [],")) (ELit (LString "    \"empty_o\": {},")) (ELit (LString "    \"nested\": [")) (ELit (LString "        [],")) (ELit (LString "        {")) (ELit (LString "            \"k\": [")) (ELit (LString "                1,")) (ELit (LString "                null,")) (ELit (LString "                true,")) (ELit (LString "                false")) (ELit (LString "            ]")) (ELit (LString "        },")) (ELit (LString "        -5")) (ELit (LString "    ],")) (ELit (LString "    \"floats\": [")) (ELit (LString "        1.0,")) (ELit (LString "        0.1,")) (ELit (LString "        1e+20,")) (ELit (LString "        -0.0,")) (ELit (LString "        1.5e-07,")) (ELit (LString "        0.0001")) (ELit (LString "    ],")) (ELit (LString "    \"ctl\": \"a\\nb\\t\\\"q\\\"\\\\ \\u0001 \\u001f\",")) (ELit (LString "    \"k\": {")) (ELit (LString "        \"x\": {")) (ELit (LString "            \"y\": []")) (ELit (LString "        }")) (ELit (LString "    }")) (ELit (LString "}"))))) (EApp (EApp (EVar "pretty") (ELit (LInt 4))) (EVar "j"))))))
(DTest false "pretty 0 breaks lines without indentation, as Python indent=0" (EApp (EVar "withDoc") (ELam ((PVar "j")) (EApp (EApp (EVar "expectEqualText") (EApp (EApp (EVar "join") (ELit (LString "\n"))) (EListLit (ELit (LString "{")) (ELit (LString "\"name\": \"café 日本\",")) (ELit (LString "\"empty_a\": [],")) (ELit (LString "\"empty_o\": {},")) (ELit (LString "\"nested\": [")) (ELit (LString "[],")) (ELit (LString "{")) (ELit (LString "\"k\": [")) (ELit (LString "1,")) (ELit (LString "null,")) (ELit (LString "true,")) (ELit (LString "false")) (ELit (LString "]")) (ELit (LString "},")) (ELit (LString "-5")) (ELit (LString "],")) (ELit (LString "\"floats\": [")) (ELit (LString "1.0,")) (ELit (LString "0.1,")) (ELit (LString "1e+20,")) (ELit (LString "-0.0,")) (ELit (LString "1.5e-07,")) (ELit (LString "0.0001")) (ELit (LString "],")) (ELit (LString "\"ctl\": \"a\\nb\\t\\\"q\\\"\\\\ \\u0001 \\u001f\",")) (ELit (LString "\"k\": {")) (ELit (LString "\"x\": {")) (ELit (LString "\"y\": []")) (ELit (LString "}")) (ELit (LString "}")) (ELit (LString "}"))))) (EApp (EApp (EVar "pretty") (ELit (LInt 0))) (EVar "j"))))))
(DTest false "pretty keeps empty containers inline and ends without a newline" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (ELit (LString "[]"))) (EApp (EApp (EVar "pretty") (ELit (LInt 2))) (EApp (EVar "jArray") (EListLit)))) (EApp (EApp (EVar "expectEqual") (ELit (LString "{}"))) (EApp (EApp (EVar "pretty") (ELit (LInt 2))) (EApp (EVar "jObject") (EListLit)))) (EApp (EApp (EVar "expectEqual") (ELit (LString "[\n  1\n]"))) (EApp (EApp (EVar "pretty") (ELit (LInt 2))) (EApp (EVar "jArray") (EListLit (EApp (EVar "JInt") (ELit (LInt 1))))))))))
(DTest false "parse reads back what pretty writes" (EApp (EVar "withDoc") (ELam ((PVar "j")) (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EVar "j"))) (EApp (EVar "parse") (EApp (EApp (EVar "pretty") (ELit (LInt 2))) (EVar "j")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EVar "j"))) (EApp (EVar "parse") (EApp (EApp (EVar "pretty") (ELit (LInt 0))) (EVar "j")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EVar "j"))) (EApp (EVar "parse") (EApp (EApp (EVar "pretty") (ELit (LInt 8))) (EVar "j")))))))))
(DTest false "parseLines numbers lines over the input, blank lines included" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 1)))) (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 2)))) (EApp (EVar "Err") (ELit (LString "line 5: unexpected end of input"))))) (EApp (EVar "parseLines") (ELit (LString "1\n\n  \n2\n[3,")))))
(DTest false "parseLines reads CRLF lines" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Ok") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "a")) (EApp (EVar "JInt") (ELit (LInt 1))))))) (EApp (EVar "Ok") (EApp (EVar "jArray") (EListLit (EApp (EVar "JInt") (ELit (LInt 2)))))))) (EApp (EVar "parseLines") (ELit (LString "{\"a\":1}\r\n\r\n[2]\r\n")))))
(DTest false "parseLines returns a bad line as an Err and goes on" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Err") (ELit (LString "line 1: unexpected character 'x'"))) (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 2)))))) (EApp (EVar "parseLines") (ELit (LString "x\n2\n")))))
(DTest false "parseLines of nothing is empty" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EVar "parseLines") (ELit (LString "")))) (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EVar "parseLines") (ELit (LString "\n \n\n")))))))
(DTest false "parseLines keeps a last line without a newline" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 1)))) (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 2)))))) (EApp (EVar "parseLines") (ELit (LString "1\n2")))))
(DTest false "stringifyLines ends each value with a newline" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EVar "stringifyLines") (EListLit))) (EApp (EApp (EVar "expectEqual") (ELit (LString "1\n\"a\"\n"))) (EApp (EVar "stringifyLines") (EListLit (EApp (EVar "JInt") (ELit (LInt 1))) (EApp (EVar "JString") (ELit (LString "a")))))))))
(DTest false "stringifyLines round-trips through parseLines" (EBlock (DoLet false false (PVar "js") (EListLit (EVar "JNull") (EApp (EVar "JInt") (ELit (LInt 3))) (EApp (EVar "JString") (ELit (LString "a\nb"))) (EApp (EVar "jArray") (EListLit (EApp (EVar "JBool") (EVar "True")))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "k")) (EApp (EVar "JFloat") (ELit (LFloat 2.5)))))))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "map") (EVar "Ok")) (EVar "js"))) (EApp (EVar "parseLines") (EApp (EVar "stringifyLines") (EVar "js")))))))
(DTest false "parse rejects a leading zero before a digit" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectErrContains") (ELit (LString "leading zero"))) (EApp (EVar "parse") (ELit (LString "01")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "leading zero"))) (EApp (EVar "parse") (ELit (LString "-01")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "leading zero"))) (EApp (EVar "parse") (ELit (LString "00")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "leading zero"))) (EApp (EVar "parse") (ELit (LString "01.5")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "leading zero"))) (EApp (EVar "parse") (ELit (LString "[1, 007]")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "leading zero"))) (EApp (EVar "parse") (ELit (LString "{\"a\": 01700000060}")))))))
(DTest false "parse still reads zero in its valid forms" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 0))))) (EApp (EVar "parse") (ELit (LString "0")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 0))))) (EApp (EVar "parse") (ELit (LString "-0")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JFloat") (ELit (LFloat 0.5))))) (EApp (EVar "parse") (ELit (LString "0.5")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JFloat") (ELit (LFloat 0.0))))) (EApp (EVar "parse") (ELit (LString "0e1")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JFloat") (EUnOp "-" (ELit (LFloat 0.5)))))) (EApp (EVar "parse") (ELit (LString "-0.5")))))))
(DTest false "parse rejects an unescaped control character in a string" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectErrContains") (ELit (LString "control character"))) (EApp (EVar "parse") (ELit (LString "\"a\tb\"")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "control character"))) (EApp (EVar "parse") (ELit (LString "\"a\nb\"")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "control character"))) (EApp (EVar "parse") (ELit (LString "\"a\rb\"")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "control character"))) (EApp (EVar "parse") (ELit (LString "\"a\0b\"")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "control character"))) (EApp (EVar "parse") (ELit (LString "\"a\u{1f}b\"")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "control character"))) (EApp (EVar "parse") (ELit (LString "{\"k\t\": 1}")))))))
(DTest false "parse still reads escaped control characters and a space" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JString") (ELit (LString "a\tb"))))) (EApp (EVar "parse") (ELit (LString "\"a\\tb\"")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JString") (ELit (LString "a\u{01}b"))))) (EApp (EVar "parse") (ELit (LString "\"a\\u0001b\"")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JString") (ELit (LString "a b"))))) (EApp (EVar "parse") (ELit (LString "\"a b\"")))))))
# MARK
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "atPath" false) (mem "asNumber" false) (mem "jArray" false) (mem "jObject" false) (mem "parse" false) (mem "parseLines" false) (mem "pretty" false) (mem "stringify" false) (mem "stringifyLines" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectAll" false) (mem "expectEqual" false) (mem "expectEqualText" false) (mem "expectErrContains" false) (mem "expectOkThen" false))))
(DTypeSig false "sample" (TyCon "Json"))
(DFunDef false "sample" () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "a")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "items")) (EApp (EVar "jArray") (EListLit (EApp (EVar "JInt") (ELit (LInt 10))) (EApp (EVar "JInt") (ELit (LInt 20))) (EApp (EVar "JInt") (ELit (LInt 30)))))) (ETuple (ELit (LString "s")) (EApp (EVar "JString") (ELit (LString "x"))))))) (ETuple (ELit (LString "7")) (EApp (EVar "JBool") (EVar "True"))) (ETuple (ELit (LString "n")) (EVar "JNull")) (ETuple (ELit (LString "i")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "f")) (EApp (EVar "JFloat") (ELit (LFloat 1.5)))) (ETuple (ELit (LString "b")) (EApp (EVar "JBool") (EVar "False"))))))
(DTypeSig false "pathErr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Json"))))
(DFunDef false "pathErr" ((PVar "steps")) (EApp (EApp (EVar "atPath") (EVar "steps")) (EVar "sample")))
(DTest false "atPath of an empty path is the root" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EVar "sample"))) (EApp (EApp (EVar "atPath") (EListLit)) (EVar "sample"))))
(DTest false "atPath follows keys and indexes" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 20))))) (EApp (EApp (EVar "atPath") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString "1")))) (EVar "sample"))))
(DTest false "atPath takes a digit key on an object as a key" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JBool") (EVar "True")))) (EApp (EApp (EVar "atPath") (EListLit (ELit (LString "7")))) (EVar "sample"))))
(DTest false "atPath names a missing key" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at a: no key \"b\"")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "b"))))))
(DTest false "atPath names an index out of range" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at a.items: index 5 out of range (3 elements)")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString "5"))))))
(DTest false "atPath names a step into a string" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at a.s: expected object or array, found string")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "s")) (ELit (LString "z"))))))
(DTest false "atPath names a step into each scalar" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at n: expected object or array, found null")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "n")) (ELit (LString "z"))))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at b: expected object or array, found bool")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "b")) (ELit (LString "z"))))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at i: expected object or array, found int")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "i")) (ELit (LString "z"))))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at f: expected object or array, found float")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "f")) (ELit (LString "z"))))))))
(DTest false "atPath names the root when the first step fails" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at <root>: no key \"zz\"")))) (EApp (EVar "pathErr") (EListLit (ELit (LString "zz"))))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Err") (ELit (LString "at <root>: expected object or array, found int")))) (EApp (EApp (EVar "atPath") (EListLit (ELit (LString "x")))) (EApp (EVar "JInt") (ELit (LInt 1))))))))
(DTest false "atPath refuses a signed or zero-padded index" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectErrContains") (ELit (LString "at a.items: invalid array index \"-1\""))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString "-1"))))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "at a.items: invalid array index \"01\""))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString "01"))))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "at a.items: invalid array index \"\""))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString ""))))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "at a.items: invalid array index \"x\""))) (EApp (EVar "pathErr") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString "x"))))))))
(DTest false "atPath accepts index zero" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 10))))) (EApp (EApp (EVar "atPath") (EListLit (ELit (LString "a")) (ELit (LString "items")) (ELit (LString "0")))) (EVar "sample"))))
(DTest false "asNumber converts an int and keeps a float" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 1.0)))) (EApp (EVar "asNumber") (EApp (EVar "JInt") (ELit (LInt 1))))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 1.5)))) (EApp (EVar "asNumber") (EApp (EVar "JFloat") (ELit (LFloat 1.5))))) (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EVar "asNumber") (EApp (EVar "JString") (ELit (LString "1"))))) (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EVar "asNumber") (EVar "JNull"))))))
(DTypeSig false "prettySource" (TyCon "String"))
(DFunDef false "prettySource" () (ELit (LString "{\"name\":\"caf\\u00e9 \\u65e5\\u672c\",\"empty_a\":[],\"empty_o\":{},\"nested\":[[],{\"k\":[1,null,true,false]},-5],\"floats\":[1.0,0.1,1e20,-0.0,1.5e-7,0.0001],\"ctl\":\"a\\nb\\t\\\"q\\\"\\\\ \\u0001 \\u001f\",\"k\":{\"x\":{\"y\":[]}}}")))
(DTypeSig false "withDoc" (TyFun (TyFun (TyCon "Json") (TyCon "Expectation")) (TyCon "Expectation")))
(DFunDef false "withDoc" ((PVar "k")) (EApp (EApp (EVar "expectOkThen") (EVar "k")) (EApp (EVar "parse") (EVar "prettySource"))))
(DTest false "pretty 2 matches Python indent=2" (EApp (EVar "withDoc") (ELam ((PVar "j")) (EApp (EApp (EVar "expectEqualText") (EApp (EApp (EVar "join") (ELit (LString "\n"))) (EListLit (ELit (LString "{")) (ELit (LString "  \"name\": \"café 日本\",")) (ELit (LString "  \"empty_a\": [],")) (ELit (LString "  \"empty_o\": {},")) (ELit (LString "  \"nested\": [")) (ELit (LString "    [],")) (ELit (LString "    {")) (ELit (LString "      \"k\": [")) (ELit (LString "        1,")) (ELit (LString "        null,")) (ELit (LString "        true,")) (ELit (LString "        false")) (ELit (LString "      ]")) (ELit (LString "    },")) (ELit (LString "    -5")) (ELit (LString "  ],")) (ELit (LString "  \"floats\": [")) (ELit (LString "    1.0,")) (ELit (LString "    0.1,")) (ELit (LString "    1e+20,")) (ELit (LString "    -0.0,")) (ELit (LString "    1.5e-07,")) (ELit (LString "    0.0001")) (ELit (LString "  ],")) (ELit (LString "  \"ctl\": \"a\\nb\\t\\\"q\\\"\\\\ \\u0001 \\u001f\",")) (ELit (LString "  \"k\": {")) (ELit (LString "    \"x\": {")) (ELit (LString "      \"y\": []")) (ELit (LString "    }")) (ELit (LString "  }")) (ELit (LString "}"))))) (EApp (EApp (EVar "pretty") (ELit (LInt 2))) (EVar "j"))))))
(DTest false "pretty 4 matches Python indent=4" (EApp (EVar "withDoc") (ELam ((PVar "j")) (EApp (EApp (EVar "expectEqualText") (EApp (EApp (EVar "join") (ELit (LString "\n"))) (EListLit (ELit (LString "{")) (ELit (LString "    \"name\": \"café 日本\",")) (ELit (LString "    \"empty_a\": [],")) (ELit (LString "    \"empty_o\": {},")) (ELit (LString "    \"nested\": [")) (ELit (LString "        [],")) (ELit (LString "        {")) (ELit (LString "            \"k\": [")) (ELit (LString "                1,")) (ELit (LString "                null,")) (ELit (LString "                true,")) (ELit (LString "                false")) (ELit (LString "            ]")) (ELit (LString "        },")) (ELit (LString "        -5")) (ELit (LString "    ],")) (ELit (LString "    \"floats\": [")) (ELit (LString "        1.0,")) (ELit (LString "        0.1,")) (ELit (LString "        1e+20,")) (ELit (LString "        -0.0,")) (ELit (LString "        1.5e-07,")) (ELit (LString "        0.0001")) (ELit (LString "    ],")) (ELit (LString "    \"ctl\": \"a\\nb\\t\\\"q\\\"\\\\ \\u0001 \\u001f\",")) (ELit (LString "    \"k\": {")) (ELit (LString "        \"x\": {")) (ELit (LString "            \"y\": []")) (ELit (LString "        }")) (ELit (LString "    }")) (ELit (LString "}"))))) (EApp (EApp (EVar "pretty") (ELit (LInt 4))) (EVar "j"))))))
(DTest false "pretty 0 breaks lines without indentation, as Python indent=0" (EApp (EVar "withDoc") (ELam ((PVar "j")) (EApp (EApp (EVar "expectEqualText") (EApp (EApp (EVar "join") (ELit (LString "\n"))) (EListLit (ELit (LString "{")) (ELit (LString "\"name\": \"café 日本\",")) (ELit (LString "\"empty_a\": [],")) (ELit (LString "\"empty_o\": {},")) (ELit (LString "\"nested\": [")) (ELit (LString "[],")) (ELit (LString "{")) (ELit (LString "\"k\": [")) (ELit (LString "1,")) (ELit (LString "null,")) (ELit (LString "true,")) (ELit (LString "false")) (ELit (LString "]")) (ELit (LString "},")) (ELit (LString "-5")) (ELit (LString "],")) (ELit (LString "\"floats\": [")) (ELit (LString "1.0,")) (ELit (LString "0.1,")) (ELit (LString "1e+20,")) (ELit (LString "-0.0,")) (ELit (LString "1.5e-07,")) (ELit (LString "0.0001")) (ELit (LString "],")) (ELit (LString "\"ctl\": \"a\\nb\\t\\\"q\\\"\\\\ \\u0001 \\u001f\",")) (ELit (LString "\"k\": {")) (ELit (LString "\"x\": {")) (ELit (LString "\"y\": []")) (ELit (LString "}")) (ELit (LString "}")) (ELit (LString "}"))))) (EApp (EApp (EVar "pretty") (ELit (LInt 0))) (EVar "j"))))))
(DTest false "pretty keeps empty containers inline and ends without a newline" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (ELit (LString "[]"))) (EApp (EApp (EVar "pretty") (ELit (LInt 2))) (EApp (EVar "jArray") (EListLit)))) (EApp (EApp (EVar "expectEqual") (ELit (LString "{}"))) (EApp (EApp (EVar "pretty") (ELit (LInt 2))) (EApp (EVar "jObject") (EListLit)))) (EApp (EApp (EVar "expectEqual") (ELit (LString "[\n  1\n]"))) (EApp (EApp (EVar "pretty") (ELit (LInt 2))) (EApp (EVar "jArray") (EListLit (EApp (EVar "JInt") (ELit (LInt 1))))))))))
(DTest false "parse reads back what pretty writes" (EApp (EVar "withDoc") (ELam ((PVar "j")) (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EVar "j"))) (EApp (EVar "parse") (EApp (EApp (EVar "pretty") (ELit (LInt 2))) (EVar "j")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EVar "j"))) (EApp (EVar "parse") (EApp (EApp (EVar "pretty") (ELit (LInt 0))) (EVar "j")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EVar "j"))) (EApp (EVar "parse") (EApp (EApp (EVar "pretty") (ELit (LInt 8))) (EVar "j")))))))))
(DTest false "parseLines numbers lines over the input, blank lines included" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 1)))) (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 2)))) (EApp (EVar "Err") (ELit (LString "line 5: unexpected end of input"))))) (EApp (EVar "parseLines") (ELit (LString "1\n\n  \n2\n[3,")))))
(DTest false "parseLines reads CRLF lines" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Ok") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "a")) (EApp (EVar "JInt") (ELit (LInt 1))))))) (EApp (EVar "Ok") (EApp (EVar "jArray") (EListLit (EApp (EVar "JInt") (ELit (LInt 2)))))))) (EApp (EVar "parseLines") (ELit (LString "{\"a\":1}\r\n\r\n[2]\r\n")))))
(DTest false "parseLines returns a bad line as an Err and goes on" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Err") (ELit (LString "line 1: unexpected character 'x'"))) (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 2)))))) (EApp (EVar "parseLines") (ELit (LString "x\n2\n")))))
(DTest false "parseLines of nothing is empty" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EVar "parseLines") (ELit (LString "")))) (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EVar "parseLines") (ELit (LString "\n \n\n")))))))
(DTest false "parseLines keeps a last line without a newline" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 1)))) (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 2)))))) (EApp (EVar "parseLines") (ELit (LString "1\n2")))))
(DTest false "stringifyLines ends each value with a newline" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EVar "stringifyLines") (EListLit))) (EApp (EApp (EVar "expectEqual") (ELit (LString "1\n\"a\"\n"))) (EApp (EVar "stringifyLines") (EListLit (EApp (EVar "JInt") (ELit (LInt 1))) (EApp (EVar "JString") (ELit (LString "a")))))))))
(DTest false "stringifyLines round-trips through parseLines" (EBlock (DoLet false false (PVar "js") (EListLit (EVar "JNull") (EApp (EVar "JInt") (ELit (LInt 3))) (EApp (EVar "JString") (ELit (LString "a\nb"))) (EApp (EVar "jArray") (EListLit (EApp (EVar "JBool") (EVar "True")))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "k")) (EApp (EVar "JFloat") (ELit (LFloat 2.5)))))))) (DoExpr (EApp (EApp (EVar "expectEqual") (EApp (EApp (EMethodRef "map") (EVar "Ok")) (EVar "js"))) (EApp (EVar "parseLines") (EApp (EVar "stringifyLines") (EVar "js")))))))
(DTest false "parse rejects a leading zero before a digit" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectErrContains") (ELit (LString "leading zero"))) (EApp (EVar "parse") (ELit (LString "01")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "leading zero"))) (EApp (EVar "parse") (ELit (LString "-01")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "leading zero"))) (EApp (EVar "parse") (ELit (LString "00")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "leading zero"))) (EApp (EVar "parse") (ELit (LString "01.5")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "leading zero"))) (EApp (EVar "parse") (ELit (LString "[1, 007]")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "leading zero"))) (EApp (EVar "parse") (ELit (LString "{\"a\": 01700000060}")))))))
(DTest false "parse still reads zero in its valid forms" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 0))))) (EApp (EVar "parse") (ELit (LString "0")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JInt") (ELit (LInt 0))))) (EApp (EVar "parse") (ELit (LString "-0")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JFloat") (ELit (LFloat 0.5))))) (EApp (EVar "parse") (ELit (LString "0.5")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JFloat") (ELit (LFloat 0.0))))) (EApp (EVar "parse") (ELit (LString "0e1")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JFloat") (EUnOp "-" (ELit (LFloat 0.5)))))) (EApp (EVar "parse") (ELit (LString "-0.5")))))))
(DTest false "parse rejects an unescaped control character in a string" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectErrContains") (ELit (LString "control character"))) (EApp (EVar "parse") (ELit (LString "\"a\tb\"")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "control character"))) (EApp (EVar "parse") (ELit (LString "\"a\nb\"")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "control character"))) (EApp (EVar "parse") (ELit (LString "\"a\rb\"")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "control character"))) (EApp (EVar "parse") (ELit (LString "\"a\0b\"")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "control character"))) (EApp (EVar "parse") (ELit (LString "\"a\u{1f}b\"")))) (EApp (EApp (EVar "expectErrContains") (ELit (LString "control character"))) (EApp (EVar "parse") (ELit (LString "{\"k\t\": 1}")))))))
(DTest false "parse still reads escaped control characters and a space" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JString") (ELit (LString "a\tb"))))) (EApp (EVar "parse") (ELit (LString "\"a\\tb\"")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JString") (ELit (LString "a\u{01}b"))))) (EApp (EVar "parse") (ELit (LString "\"a\\u0001b\"")))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Ok") (EApp (EVar "JString") (ELit (LString "a b"))))) (EApp (EVar "parse") (ELit (LString "\"a b\"")))))))
