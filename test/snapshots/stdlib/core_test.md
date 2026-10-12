# META
source_lines=105
stages=DESUGAR,MARK
# SOURCE
-- Tests for the list and array rendering and string indexing in
-- `stdlib/core.mdk`.
--
-- Elements are separated by `, `, with none before the first or after the
-- last. `debug` quotes strings and `display` does not. Indexing a string
-- counts codepoints, not bytes.

import test.{expectEqual}

-- # Debug and Display of lists

test "debug of an empty list" = expectEqual "[]" (debug ([] : List Int))

test "debug of a one-element list has no separator" =
  expectEqual "[1]" (debug [1])

test "debug of a list separates elements with a comma and a space" =
  expectEqual "[1, 2, 3]" (debug [1, 2, 3])

test "debug of a list of strings quotes them" =
  expectEqual "[\"a\", \"b\"]" (debug ["a", "b"])

test "debug of nested lists" =
  expectEqual "[[1, 2], [], [3]]" (debug [[1, 2], [], [3]])

test "display of an empty list" = expectEqual "[]" (display ([] : List Int))

test "display of a one-element list has no separator" =
  expectEqual "[1]" (display [1])

test "display of a list of strings leaves them unquoted" =
  expectEqual "[a, b]" (display ["a", "b"])

test "display of nested lists" =
  expectEqual "[[1, 2], [], [3]]" (display [[1, 2], [], [3]])

-- # Debug and Display of arrays

test "debug of an empty array" = expectEqual "[||]" (debug ([||] : Array Int))

test "debug of a one-element array has no separator" =
  expectEqual "[|1|]" (debug [|1|])

test "debug of an array separates elements with a comma and a space" =
  expectEqual "[|1, 2, 3|]" (debug [|1, 2, 3|])

test "debug of an array of strings quotes them" =
  expectEqual "[|\"a\", \"b\"|]" (debug [|"a", "b"|])

test "display of an empty array" =
  expectEqual "[||]" (display ([||] : Array Int))

test "display of an array of strings leaves them unquoted" =
  expectEqual "[|a, b|]" (display [|"a", "b"|])

-- # Nested and structured elements

data Shape = Circle Int | Rect Int Int | Empty deriving (Debug)

test "debug of a list of options" =
  expectEqual "[Some 1, None]" (debug [Some 1, None])

test "display of a list of options" =
  expectEqual "[Some 1, None]" (display [Some 1, None])

test "debug of a list of tuples quotes the strings" =
  expectEqual "[(1, \"x\"), (2, \"y\")]" (debug [(1, "x"), (2, "y")])

test "display of a list of tuples leaves the strings unquoted" =
  expectEqual "[(1, x), (2, y)]" (display [(1, "x"), (2, "y")])

test "debug of three levels of nesting" =
  expectEqual
    "[[Some 1], [], [None, Some 2]]"
    (debug [[Some 1], [], [None, Some 2]])

test "debug of an array of tuples" =
  expectEqual "[|(1, 'a'), (2, 'b')|]" (debug [|(1, 'a'), (2, 'b')|])

test "display of an array of options" =
  expectEqual "[|Some 1, None|]" (display [|Some 1, None|])

test "debug of a list of a derived type" =
  expectEqual "[Circle 3, Rect 1 2, Empty]" (debug [Circle 3, Rect 1 2, Empty])

test "debug of an array of a derived type" =
  expectEqual
    "[|Circle 3, Rect 1 2, Empty|]"
    (debug [|Circle 3, Rect 1 2, Empty|])

test "debug of an array of arrays" =
  expectEqual "[[|1, 2|], [||]]" (debug [[|1, 2|], [||]])

-- # Indexing a string

test "indexing a string reads a codepoint" = expectEqual 'é' "héllo"[1]

test "indexing past a multibyte codepoint counts codepoints" =
  expectEqual 'o' "héllo"[4]

test "indexing the last codepoint of a wide-character string" =
  expectEqual '語' "日本語"[2]

test "indexing an ASCII string reads the first and last character" =
  expectEqual ('a', 'f') ("abcdef"[0], "abcdef"[5])
# DESUGAR
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTest false "debug of an empty list" (EApp (EApp (EVar "expectEqual") (ELit (LString "[]"))) (EApp (EVar "debug") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int"))))))
(DTest false "debug of a one-element list has no separator" (EApp (EApp (EVar "expectEqual") (ELit (LString "[1]"))) (EApp (EVar "debug") (EListLit (ELit (LInt 1))))))
(DTest false "debug of a list separates elements with a comma and a space" (EApp (EApp (EVar "expectEqual") (ELit (LString "[1, 2, 3]"))) (EApp (EVar "debug") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))))
(DTest false "debug of a list of strings quotes them" (EApp (EApp (EVar "expectEqual") (ELit (LString "[\"a\", \"b\"]"))) (EApp (EVar "debug") (EListLit (ELit (LString "a")) (ELit (LString "b"))))))
(DTest false "debug of nested lists" (EApp (EApp (EVar "expectEqual") (ELit (LString "[[1, 2], [], [3]]"))) (EApp (EVar "debug") (EListLit (EListLit (ELit (LInt 1)) (ELit (LInt 2))) (EListLit) (EListLit (ELit (LInt 3)))))))
(DTest false "display of an empty list" (EApp (EApp (EVar "expectEqual") (ELit (LString "[]"))) (EApp (EVar "display") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int"))))))
(DTest false "display of a one-element list has no separator" (EApp (EApp (EVar "expectEqual") (ELit (LString "[1]"))) (EApp (EVar "display") (EListLit (ELit (LInt 1))))))
(DTest false "display of a list of strings leaves them unquoted" (EApp (EApp (EVar "expectEqual") (ELit (LString "[a, b]"))) (EApp (EVar "display") (EListLit (ELit (LString "a")) (ELit (LString "b"))))))
(DTest false "display of nested lists" (EApp (EApp (EVar "expectEqual") (ELit (LString "[[1, 2], [], [3]]"))) (EApp (EVar "display") (EListLit (EListLit (ELit (LInt 1)) (ELit (LInt 2))) (EListLit) (EListLit (ELit (LInt 3)))))))
(DTest false "debug of an empty array" (EApp (EApp (EVar "expectEqual") (ELit (LString "[||]"))) (EApp (EVar "debug") (EAnnot (EArrayLit) (TyApp (TyCon "Array") (TyCon "Int"))))))
(DTest false "debug of a one-element array has no separator" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|1|]"))) (EApp (EVar "debug") (EArrayLit (ELit (LInt 1))))))
(DTest false "debug of an array separates elements with a comma and a space" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|1, 2, 3|]"))) (EApp (EVar "debug") (EArrayLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))))
(DTest false "debug of an array of strings quotes them" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|\"a\", \"b\"|]"))) (EApp (EVar "debug") (EArrayLit (ELit (LString "a")) (ELit (LString "b"))))))
(DTest false "display of an empty array" (EApp (EApp (EVar "expectEqual") (ELit (LString "[||]"))) (EApp (EVar "display") (EAnnot (EArrayLit) (TyApp (TyCon "Array") (TyCon "Int"))))))
(DTest false "display of an array of strings leaves them unquoted" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|a, b|]"))) (EApp (EVar "display") (EArrayLit (ELit (LString "a")) (ELit (LString "b"))))))
(DData Private "Shape" () ((variant "Circle" (ConPos (TyCon "Int"))) (variant "Rect" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "Empty" (ConPos))) ())
(DImpl true "Debug" ((TyCon "Shape")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Circle" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Circle ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "Rect" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Rect ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1"))))) (arm (PCon "Empty") () (ELit (LString "Empty")))))))
(DTest false "debug of a list of options" (EApp (EApp (EVar "expectEqual") (ELit (LString "[Some 1, None]"))) (EApp (EVar "debug") (EListLit (EApp (EVar "Some") (ELit (LInt 1))) (EVar "None")))))
(DTest false "display of a list of options" (EApp (EApp (EVar "expectEqual") (ELit (LString "[Some 1, None]"))) (EApp (EVar "display") (EListLit (EApp (EVar "Some") (ELit (LInt 1))) (EVar "None")))))
(DTest false "debug of a list of tuples quotes the strings" (EApp (EApp (EVar "expectEqual") (ELit (LString "[(1, \"x\"), (2, \"y\")]"))) (EApp (EVar "debug") (EListLit (ETuple (ELit (LInt 1)) (ELit (LString "x"))) (ETuple (ELit (LInt 2)) (ELit (LString "y")))))))
(DTest false "display of a list of tuples leaves the strings unquoted" (EApp (EApp (EVar "expectEqual") (ELit (LString "[(1, x), (2, y)]"))) (EApp (EVar "display") (EListLit (ETuple (ELit (LInt 1)) (ELit (LString "x"))) (ETuple (ELit (LInt 2)) (ELit (LString "y")))))))
(DTest false "debug of three levels of nesting" (EApp (EApp (EVar "expectEqual") (ELit (LString "[[Some 1], [], [None, Some 2]]"))) (EApp (EVar "debug") (EListLit (EListLit (EApp (EVar "Some") (ELit (LInt 1)))) (EListLit) (EListLit (EVar "None") (EApp (EVar "Some") (ELit (LInt 2))))))))
(DTest false "debug of an array of tuples" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|(1, 'a'), (2, 'b')|]"))) (EApp (EVar "debug") (EArrayLit (ETuple (ELit (LInt 1)) (ELit (LChar "a"))) (ETuple (ELit (LInt 2)) (ELit (LChar "b")))))))
(DTest false "display of an array of options" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|Some 1, None|]"))) (EApp (EVar "display") (EArrayLit (EApp (EVar "Some") (ELit (LInt 1))) (EVar "None")))))
(DTest false "debug of a list of a derived type" (EApp (EApp (EVar "expectEqual") (ELit (LString "[Circle 3, Rect 1 2, Empty]"))) (EApp (EVar "debug") (EListLit (EApp (EVar "Circle") (ELit (LInt 3))) (EApp (EApp (EVar "Rect") (ELit (LInt 1))) (ELit (LInt 2))) (EVar "Empty")))))
(DTest false "debug of an array of a derived type" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|Circle 3, Rect 1 2, Empty|]"))) (EApp (EVar "debug") (EArrayLit (EApp (EVar "Circle") (ELit (LInt 3))) (EApp (EApp (EVar "Rect") (ELit (LInt 1))) (ELit (LInt 2))) (EVar "Empty")))))
(DTest false "debug of an array of arrays" (EApp (EApp (EVar "expectEqual") (ELit (LString "[[|1, 2|], [||]]"))) (EApp (EVar "debug") (EListLit (EArrayLit (ELit (LInt 1)) (ELit (LInt 2))) (EArrayLit)))))
(DTest false "indexing a string reads a codepoint" (EApp (EApp (EVar "expectEqual") (ELit (LChar "é"))) (EApp (EApp (EVar "index") (ELit (LString "héllo"))) (ELit (LInt 1)))))
(DTest false "indexing past a multibyte codepoint counts codepoints" (EApp (EApp (EVar "expectEqual") (ELit (LChar "o"))) (EApp (EApp (EVar "index") (ELit (LString "héllo"))) (ELit (LInt 4)))))
(DTest false "indexing the last codepoint of a wide-character string" (EApp (EApp (EVar "expectEqual") (ELit (LChar "語"))) (EApp (EApp (EVar "index") (ELit (LString "日本語"))) (ELit (LInt 2)))))
(DTest false "indexing an ASCII string reads the first and last character" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LChar "a")) (ELit (LChar "f")))) (ETuple (EApp (EApp (EVar "index") (ELit (LString "abcdef"))) (ELit (LInt 0))) (EApp (EApp (EVar "index") (ELit (LString "abcdef"))) (ELit (LInt 5))))))
# MARK
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTest false "debug of an empty list" (EApp (EApp (EVar "expectEqual") (ELit (LString "[]"))) (EApp (EMethodRef "debug") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int"))))))
(DTest false "debug of a one-element list has no separator" (EApp (EApp (EVar "expectEqual") (ELit (LString "[1]"))) (EApp (EMethodRef "debug") (EListLit (ELit (LInt 1))))))
(DTest false "debug of a list separates elements with a comma and a space" (EApp (EApp (EVar "expectEqual") (ELit (LString "[1, 2, 3]"))) (EApp (EMethodRef "debug") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))))
(DTest false "debug of a list of strings quotes them" (EApp (EApp (EVar "expectEqual") (ELit (LString "[\"a\", \"b\"]"))) (EApp (EMethodRef "debug") (EListLit (ELit (LString "a")) (ELit (LString "b"))))))
(DTest false "debug of nested lists" (EApp (EApp (EVar "expectEqual") (ELit (LString "[[1, 2], [], [3]]"))) (EApp (EMethodRef "debug") (EListLit (EListLit (ELit (LInt 1)) (ELit (LInt 2))) (EListLit) (EListLit (ELit (LInt 3)))))))
(DTest false "display of an empty list" (EApp (EApp (EVar "expectEqual") (ELit (LString "[]"))) (EApp (EMethodRef "display") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int"))))))
(DTest false "display of a one-element list has no separator" (EApp (EApp (EVar "expectEqual") (ELit (LString "[1]"))) (EApp (EMethodRef "display") (EListLit (ELit (LInt 1))))))
(DTest false "display of a list of strings leaves them unquoted" (EApp (EApp (EVar "expectEqual") (ELit (LString "[a, b]"))) (EApp (EMethodRef "display") (EListLit (ELit (LString "a")) (ELit (LString "b"))))))
(DTest false "display of nested lists" (EApp (EApp (EVar "expectEqual") (ELit (LString "[[1, 2], [], [3]]"))) (EApp (EMethodRef "display") (EListLit (EListLit (ELit (LInt 1)) (ELit (LInt 2))) (EListLit) (EListLit (ELit (LInt 3)))))))
(DTest false "debug of an empty array" (EApp (EApp (EVar "expectEqual") (ELit (LString "[||]"))) (EApp (EMethodRef "debug") (EAnnot (EArrayLit) (TyApp (TyCon "Array") (TyCon "Int"))))))
(DTest false "debug of a one-element array has no separator" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|1|]"))) (EApp (EMethodRef "debug") (EArrayLit (ELit (LInt 1))))))
(DTest false "debug of an array separates elements with a comma and a space" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|1, 2, 3|]"))) (EApp (EMethodRef "debug") (EArrayLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))))
(DTest false "debug of an array of strings quotes them" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|\"a\", \"b\"|]"))) (EApp (EMethodRef "debug") (EArrayLit (ELit (LString "a")) (ELit (LString "b"))))))
(DTest false "display of an empty array" (EApp (EApp (EVar "expectEqual") (ELit (LString "[||]"))) (EApp (EMethodRef "display") (EAnnot (EArrayLit) (TyApp (TyCon "Array") (TyCon "Int"))))))
(DTest false "display of an array of strings leaves them unquoted" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|a, b|]"))) (EApp (EMethodRef "display") (EArrayLit (ELit (LString "a")) (ELit (LString "b"))))))
(DData Private "Shape" () ((variant "Circle" (ConPos (TyCon "Int"))) (variant "Rect" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "Empty" (ConPos))) ())
(DImpl true "Debug" ((TyCon "Shape")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Circle" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Circle ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "Rect" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Rect ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1"))))) (arm (PCon "Empty") () (ELit (LString "Empty")))))))
(DTest false "debug of a list of options" (EApp (EApp (EVar "expectEqual") (ELit (LString "[Some 1, None]"))) (EApp (EMethodRef "debug") (EListLit (EApp (EVar "Some") (ELit (LInt 1))) (EVar "None")))))
(DTest false "display of a list of options" (EApp (EApp (EVar "expectEqual") (ELit (LString "[Some 1, None]"))) (EApp (EMethodRef "display") (EListLit (EApp (EVar "Some") (ELit (LInt 1))) (EVar "None")))))
(DTest false "debug of a list of tuples quotes the strings" (EApp (EApp (EVar "expectEqual") (ELit (LString "[(1, \"x\"), (2, \"y\")]"))) (EApp (EMethodRef "debug") (EListLit (ETuple (ELit (LInt 1)) (ELit (LString "x"))) (ETuple (ELit (LInt 2)) (ELit (LString "y")))))))
(DTest false "display of a list of tuples leaves the strings unquoted" (EApp (EApp (EVar "expectEqual") (ELit (LString "[(1, x), (2, y)]"))) (EApp (EMethodRef "display") (EListLit (ETuple (ELit (LInt 1)) (ELit (LString "x"))) (ETuple (ELit (LInt 2)) (ELit (LString "y")))))))
(DTest false "debug of three levels of nesting" (EApp (EApp (EVar "expectEqual") (ELit (LString "[[Some 1], [], [None, Some 2]]"))) (EApp (EMethodRef "debug") (EListLit (EListLit (EApp (EVar "Some") (ELit (LInt 1)))) (EListLit) (EListLit (EVar "None") (EApp (EVar "Some") (ELit (LInt 2))))))))
(DTest false "debug of an array of tuples" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|(1, 'a'), (2, 'b')|]"))) (EApp (EMethodRef "debug") (EArrayLit (ETuple (ELit (LInt 1)) (ELit (LChar "a"))) (ETuple (ELit (LInt 2)) (ELit (LChar "b")))))))
(DTest false "display of an array of options" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|Some 1, None|]"))) (EApp (EMethodRef "display") (EArrayLit (EApp (EVar "Some") (ELit (LInt 1))) (EVar "None")))))
(DTest false "debug of a list of a derived type" (EApp (EApp (EVar "expectEqual") (ELit (LString "[Circle 3, Rect 1 2, Empty]"))) (EApp (EMethodRef "debug") (EListLit (EApp (EVar "Circle") (ELit (LInt 3))) (EApp (EApp (EVar "Rect") (ELit (LInt 1))) (ELit (LInt 2))) (EVar "Empty")))))
(DTest false "debug of an array of a derived type" (EApp (EApp (EVar "expectEqual") (ELit (LString "[|Circle 3, Rect 1 2, Empty|]"))) (EApp (EMethodRef "debug") (EArrayLit (EApp (EVar "Circle") (ELit (LInt 3))) (EApp (EApp (EVar "Rect") (ELit (LInt 1))) (ELit (LInt 2))) (EVar "Empty")))))
(DTest false "debug of an array of arrays" (EApp (EApp (EVar "expectEqual") (ELit (LString "[[|1, 2|], [||]]"))) (EApp (EMethodRef "debug") (EListLit (EArrayLit (ELit (LInt 1)) (ELit (LInt 2))) (EArrayLit)))))
(DTest false "indexing a string reads a codepoint" (EApp (EApp (EVar "expectEqual") (ELit (LChar "é"))) (EApp (EApp (EMethodRef "index") (ELit (LString "héllo"))) (ELit (LInt 1)))))
(DTest false "indexing past a multibyte codepoint counts codepoints" (EApp (EApp (EVar "expectEqual") (ELit (LChar "o"))) (EApp (EApp (EMethodRef "index") (ELit (LString "héllo"))) (ELit (LInt 4)))))
(DTest false "indexing the last codepoint of a wide-character string" (EApp (EApp (EVar "expectEqual") (ELit (LChar "語"))) (EApp (EApp (EMethodRef "index") (ELit (LString "日本語"))) (ELit (LInt 2)))))
(DTest false "indexing an ASCII string reads the first and last character" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LChar "a")) (ELit (LChar "f")))) (ETuple (EApp (EApp (EMethodRef "index") (ELit (LString "abcdef"))) (ELit (LInt 0))) (EApp (EApp (EMethodRef "index") (ELit (LString "abcdef"))) (ELit (LInt 5))))))
