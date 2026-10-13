# META
source_lines=214
stages=DESUGAR,MARK
# SOURCE
-- Tests for the list and array rendering and string indexing in
-- `stdlib/core.mdk`.
--
-- Elements are separated by `, `, with none before the first or after the
-- last. `debug` quotes strings and `display` does not. Indexing a string
-- counts codepoints, not bytes.

import test.{expectEqual, expectTrue, expectFalse}

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

-- # Folding and comparing lists

prop "foldMap over a List monoid agrees with the left-nested reference" (xs : List Int) =
  eq (foldMap (x => [x, x]) xs) (fold (acc x => acc ++ [x, x]) [] xs)

prop "foldMap over a String monoid agrees with the left-nested reference" (xs : List Int) =
  foldMap (x => display x) xs == fold (acc x => acc ++ display x) "" xs

test "foldMap of an empty list is the monoid identity" =
  expectEqual ([] : List Int) (foldMap (x => [x]) ([] : List Int))

test "foldMap applies the function in element order" =
  expectEqual [1, 2, 3] (foldMap (x => [x]) [1, 2, 3])

test "list compare decides on the first differing element" =
  expectEqual
    (Lt, Gt, Eq)
    (compare [1, 2, 9] [1, 3], compare [2] [1, 9], compare [4, 4] [4, 4])

prop "list compare is Eq exactly when the lists are equal" (xs : List Int) (ys : List Int) =
  compare xs ys == Eq == eq xs ys

test "foldMap over a String monoid concatenates in element order" =
  expectEqual "123" (foldMap (x => display x) [1, 2, 3])

test "foldMap over a list of lists keeps the element order" =
  expectEqual [1, 2, 3, 4] (foldMap (x => [x, x + 1]) [1, 3])

-- # Filtering lists

test "filter keeps the elements that satisfy the predicate" =
  expectEqual [2, 4] (filter (x => x % 2 == 0) [1, 2, 3, 4])

test "filter keeps the order of the surviving elements" =
  expectEqual [5, 3, 9] (filter (x => x > 2) [5, 1, 3, 0, 9])

test "filter of an empty list is empty" =
  expectEqual ([] : List Int) (filter (x => x > 0) ([] : List Int))

test "filter drops every element when none satisfies the predicate" =
  expectEqual ([] : List Int) (filter (x => x > 10) [1, 2])

-- # Exclusive or

test "xor of True and True is False" = expectFalse (xor True True)

test "xor of True and False is True" = expectTrue (xor True False)

test "xor of False and True is True" = expectTrue (xor False True)

test "xor of False and False is False" = expectFalse (xor False False)

-- # Tuple ordering

test "pair compare decides on the first field" =
  expectEqual [Lt, Gt] [compare (1, 9) (2, 0), compare (3, 0) (2, 9)]

test "pair compare falls through to the second field on a tie" =
  expectEqual
    [Lt, Gt, Eq]
    [compare (1, 2) (1, 3), compare (1, 3) (1, 2), compare (1, 2) (1, 2)]

test "triple compare decides on each field in turn" =
  expectEqual
    [Lt, Lt, Gt, Eq]
    [
      compare (1, 9, 9) (2, 0, 0),
      compare (1, 1, 9) (1, 2, 0),
      compare (1, 2, 9) (1, 2, 0),
      compare (1, 2, 3) (1, 2, 3),
    ]

test "quadruple compare decides on each field in turn" =
  expectEqual
    [Lt, Lt, Lt, Gt, Eq]
    [
      compare (1, 9, 9, 9) (2, 0, 0, 0),
      compare (1, 1, 9, 9) (1, 2, 0, 0),
      compare (1, 1, 1, 9) (1, 1, 2, 0),
      compare (1, 1, 1, 9) (1, 1, 1, 0),
      compare (1, 1, 2, 3) (1, 1, 2, 3),
    ]

test "quintuple compare decides on each field in turn" =
  expectEqual
    [Lt, Lt, Lt, Lt, Gt, Eq]
    [
      compare (1, 9, 9, 9, 9) (2, 0, 0, 0, 0),
      compare (1, 1, 9, 9, 9) (1, 2, 0, 0, 0),
      compare (1, 1, 1, 9, 9) (1, 1, 2, 0, 0),
      compare (1, 1, 1, 1, 9) (1, 1, 1, 2, 0),
      compare (1, 1, 1, 1, 9) (1, 1, 1, 1, 0),
      compare (1, 1, 1, 2, 3) (1, 1, 1, 2, 3),
    ]

test "tuple compare returns Gt from an earlier field" =
  expectEqual
    [Gt, Gt, Gt, Gt, Gt, Gt, Gt, Gt]
    [
      compare (2, 0, 0) (1, 9, 9),
      compare (1, 2, 0) (1, 1, 9),
      compare (2, 0, 0, 0) (1, 9, 9, 9),
      compare (1, 1, 2, 0) (1, 1, 1, 9),
      compare (2, 0, 0, 0, 0) (1, 9, 9, 9, 9),
      compare (1, 2, 0, 0, 0) (1, 1, 9, 9, 9),
      compare (1, 1, 2, 0, 0) (1, 1, 1, 9, 9),
      compare (1, 1, 1, 2, 0) (1, 1, 1, 1, 9),
    ]
# DESUGAR
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectTrue" false) (mem "expectFalse" false))))
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
(DProp false "foldMap over a List monoid agrees with the left-nested reference" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "foldMap") (ELam ((PVar "x")) (EListLit (EVar "x") (EVar "x")))) (EVar "xs"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "++" (EVar "acc") (EListLit (EVar "x") (EVar "x"))))) (EListLit)) (EVar "xs"))))
(DProp false "foldMap over a String monoid agrees with the left-nested reference" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EApp (EVar "foldMap") (ELam ((PVar "x")) (EApp (EVar "display") (EVar "x")))) (EVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "++" (EVar "acc") (EApp (EVar "display") (EVar "x"))))) (ELit (LString ""))) (EVar "xs"))))
(DTest false "foldMap of an empty list is the monoid identity" (EApp (EApp (EVar "expectEqual") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "foldMap") (ELam ((PVar "x")) (EListLit (EVar "x")))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int"))))))
(DTest false "foldMap applies the function in element order" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (EApp (EApp (EVar "foldMap") (ELam ((PVar "x")) (EListLit (EVar "x")))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))))
(DTest false "list compare decides on the first differing element" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "Lt") (EVar "Gt") (EVar "Eq"))) (ETuple (EApp (EApp (EVar "compare") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 9)))) (EListLit (ELit (LInt 1)) (ELit (LInt 3)))) (EApp (EApp (EVar "compare") (EListLit (ELit (LInt 2)))) (EListLit (ELit (LInt 1)) (ELit (LInt 9)))) (EApp (EApp (EVar "compare") (EListLit (ELit (LInt 4)) (ELit (LInt 4)))) (EListLit (ELit (LInt 4)) (ELit (LInt 4)))))))
(DProp false "list compare is Eq exactly when the lists are equal" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EBinOp "==" (EApp (EApp (EVar "compare") (EVar "xs")) (EVar "ys")) (EVar "Eq")) (EApp (EApp (EVar "eq") (EVar "xs")) (EVar "ys"))))
(DTest false "foldMap over a String monoid concatenates in element order" (EApp (EApp (EVar "expectEqual") (ELit (LString "123"))) (EApp (EApp (EVar "foldMap") (ELam ((PVar "x")) (EApp (EVar "display") (EVar "x")))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))))
(DTest false "foldMap over a list of lists keeps the element order" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)))) (EApp (EApp (EVar "foldMap") (ELam ((PVar "x")) (EListLit (EVar "x") (EBinOp "+" (EVar "x") (ELit (LInt 1)))))) (EListLit (ELit (LInt 1)) (ELit (LInt 3))))))
(DTest false "filter keeps the elements that satisfy the predicate" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 2)) (ELit (LInt 4)))) (EApp (EApp (EVar "filter") (ELam ((PVar "x")) (EBinOp "==" (EBinOp "%" (EVar "x") (ELit (LInt 2))) (ELit (LInt 0))))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4))))))
(DTest false "filter keeps the order of the surviving elements" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 5)) (ELit (LInt 3)) (ELit (LInt 9)))) (EApp (EApp (EVar "filter") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 2))))) (EListLit (ELit (LInt 5)) (ELit (LInt 1)) (ELit (LInt 3)) (ELit (LInt 0)) (ELit (LInt 9))))))
(DTest false "filter of an empty list is empty" (EApp (EApp (EVar "expectEqual") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "filter") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int"))))))
(DTest false "filter drops every element when none satisfies the predicate" (EApp (EApp (EVar "expectEqual") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "filter") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 10))))) (EListLit (ELit (LInt 1)) (ELit (LInt 2))))))
(DTest false "xor of True and True is False" (EApp (EVar "expectFalse") (EApp (EApp (EVar "xor") (EVar "True")) (EVar "True"))))
(DTest false "xor of True and False is True" (EApp (EVar "expectTrue") (EApp (EApp (EVar "xor") (EVar "True")) (EVar "False"))))
(DTest false "xor of False and True is True" (EApp (EVar "expectTrue") (EApp (EApp (EVar "xor") (EVar "False")) (EVar "True"))))
(DTest false "xor of False and False is False" (EApp (EVar "expectFalse") (EApp (EApp (EVar "xor") (EVar "False")) (EVar "False"))))
(DTest false "pair compare decides on the first field" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "Lt") (EVar "Gt"))) (EListLit (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 9)))) (ETuple (ELit (LInt 2)) (ELit (LInt 0)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 3)) (ELit (LInt 0)))) (ETuple (ELit (LInt 2)) (ELit (LInt 9)))))))
(DTest false "pair compare falls through to the second field on a tie" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "Lt") (EVar "Gt") (EVar "Eq"))) (EListLit (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 2)))) (ETuple (ELit (LInt 1)) (ELit (LInt 3)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 3)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 2)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)))))))
(DTest false "triple compare decides on each field in turn" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "Lt") (EVar "Lt") (EVar "Gt") (EVar "Eq"))) (EListLit (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)))) (ETuple (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))))))
(DTest false "quadruple compare decides on each field in turn" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "Lt") (EVar "Lt") (EVar "Lt") (EVar "Gt") (EVar "Eq"))) (EListLit (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)))) (ETuple (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 0)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))))))
(DTest false "quintuple compare decides on each field in turn" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "Lt") (EVar "Lt") (EVar "Lt") (EVar "Lt") (EVar "Gt") (EVar "Eq"))) (EListLit (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)))) (ETuple (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 0)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))))))
(DTest false "tuple compare returns Gt from an earlier field" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "Gt") (EVar "Gt") (EVar "Gt") (EVar "Gt") (EVar "Gt") (EVar "Gt") (EVar "Gt") (EVar "Gt"))) (EListLit (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)))) (EApp (EApp (EVar "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))))))
# MARK
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectTrue" false) (mem "expectFalse" false))))
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
(DProp false "foldMap over a List monoid agrees with the left-nested reference" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EMethodRef "foldMap") (ELam ((PVar "x")) (EListLit (EVar "x") (EVar "x")))) (EVar "xs"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "++" (EVar "acc") (EListLit (EVar "x") (EVar "x"))))) (EListLit)) (EVar "xs"))))
(DProp false "foldMap over a String monoid agrees with the left-nested reference" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EApp (EMethodRef "foldMap") (ELam ((PVar "x")) (EApp (EMethodRef "display") (EVar "x")))) (EVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "++" (EVar "acc") (EApp (EMethodRef "display") (EVar "x"))))) (ELit (LString ""))) (EVar "xs"))))
(DTest false "foldMap of an empty list is the monoid identity" (EApp (EApp (EVar "expectEqual") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "foldMap") (ELam ((PVar "x")) (EListLit (EVar "x")))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int"))))))
(DTest false "foldMap applies the function in element order" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (EApp (EApp (EMethodRef "foldMap") (ELam ((PVar "x")) (EListLit (EVar "x")))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))))
(DTest false "list compare decides on the first differing element" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "Lt") (EVar "Gt") (EVar "Eq"))) (ETuple (EApp (EApp (EMethodRef "compare") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 9)))) (EListLit (ELit (LInt 1)) (ELit (LInt 3)))) (EApp (EApp (EMethodRef "compare") (EListLit (ELit (LInt 2)))) (EListLit (ELit (LInt 1)) (ELit (LInt 9)))) (EApp (EApp (EMethodRef "compare") (EListLit (ELit (LInt 4)) (ELit (LInt 4)))) (EListLit (ELit (LInt 4)) (ELit (LInt 4)))))))
(DProp false "list compare is Eq exactly when the lists are equal" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EBinOp "==" (EApp (EApp (EMethodRef "compare") (EVar "xs")) (EVar "ys")) (EVar "Eq")) (EApp (EApp (EMethodRef "eq") (EVar "xs")) (EVar "ys"))))
(DTest false "foldMap over a String monoid concatenates in element order" (EApp (EApp (EVar "expectEqual") (ELit (LString "123"))) (EApp (EApp (EMethodRef "foldMap") (ELam ((PVar "x")) (EApp (EMethodRef "display") (EVar "x")))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))))
(DTest false "foldMap over a list of lists keeps the element order" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)))) (EApp (EApp (EMethodRef "foldMap") (ELam ((PVar "x")) (EListLit (EVar "x") (EBinOp "+" (EVar "x") (ELit (LInt 1)))))) (EListLit (ELit (LInt 1)) (ELit (LInt 3))))))
(DTest false "filter keeps the elements that satisfy the predicate" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 2)) (ELit (LInt 4)))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "x")) (EBinOp "==" (EBinOp "%" (EVar "x") (ELit (LInt 2))) (ELit (LInt 0))))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4))))))
(DTest false "filter keeps the order of the surviving elements" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 5)) (ELit (LInt 3)) (ELit (LInt 9)))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 2))))) (EListLit (ELit (LInt 5)) (ELit (LInt 1)) (ELit (LInt 3)) (ELit (LInt 0)) (ELit (LInt 9))))))
(DTest false "filter of an empty list is empty" (EApp (EApp (EVar "expectEqual") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int"))))))
(DTest false "filter drops every element when none satisfies the predicate" (EApp (EApp (EVar "expectEqual") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 10))))) (EListLit (ELit (LInt 1)) (ELit (LInt 2))))))
(DTest false "xor of True and True is False" (EApp (EVar "expectFalse") (EApp (EApp (EVar "xor") (EVar "True")) (EVar "True"))))
(DTest false "xor of True and False is True" (EApp (EVar "expectTrue") (EApp (EApp (EVar "xor") (EVar "True")) (EVar "False"))))
(DTest false "xor of False and True is True" (EApp (EVar "expectTrue") (EApp (EApp (EVar "xor") (EVar "False")) (EVar "True"))))
(DTest false "xor of False and False is False" (EApp (EVar "expectFalse") (EApp (EApp (EVar "xor") (EVar "False")) (EVar "False"))))
(DTest false "pair compare decides on the first field" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "Lt") (EVar "Gt"))) (EListLit (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 9)))) (ETuple (ELit (LInt 2)) (ELit (LInt 0)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 3)) (ELit (LInt 0)))) (ETuple (ELit (LInt 2)) (ELit (LInt 9)))))))
(DTest false "pair compare falls through to the second field on a tie" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "Lt") (EVar "Gt") (EVar "Eq"))) (EListLit (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 2)))) (ETuple (ELit (LInt 1)) (ELit (LInt 3)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 3)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 2)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)))))))
(DTest false "triple compare decides on each field in turn" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "Lt") (EVar "Lt") (EVar "Gt") (EVar "Eq"))) (EListLit (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)))) (ETuple (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))))))
(DTest false "quadruple compare decides on each field in turn" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "Lt") (EVar "Lt") (EVar "Lt") (EVar "Gt") (EVar "Eq"))) (EListLit (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)))) (ETuple (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 0)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))))))
(DTest false "quintuple compare decides on each field in turn" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "Lt") (EVar "Lt") (EVar "Lt") (EVar "Lt") (EVar "Gt") (EVar "Eq"))) (EListLit (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)))) (ETuple (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 0)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))))))
(DTest false "tuple compare returns Gt from an earlier field" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "Gt") (EVar "Gt") (EVar "Gt") (EVar "Gt") (EVar "Gt") (EVar "Gt") (EVar "Gt") (EVar "Gt"))) (EListLit (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)) (ELit (LInt 9)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 9)))) (EApp (EApp (EMethodRef "compare") (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 0)))) (ETuple (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 9)))))))
