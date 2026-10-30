# META
source_lines=436
stages=DESUGAR,MARK
# SOURCE
-- Tests for the list and array rendering and string indexing in
-- `stdlib/core.mdk`.
--
-- Elements are separated by `, `, with none before the first or after the
-- last. `debug` quotes strings and `display` does not. Indexing a string
-- counts codepoints, not bytes.

import test.{expectEqual, expectTrue, expectFalse, expectAll, Expectation}
import map.{Map}

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
  expectEqual [2, 4] (filter (x => isEven x) [1, 2, 3, 4])

test "filter keeps the order of the surviving elements" =
  expectEqual [5, 3, 9] (filter (> 2) [5, 1, 3, 0, 9])

test "filter of an empty list is empty" =
  expectEqual ([] : List Int) (filter (> 0) ([] : List Int))

test "filter drops every element when none satisfies the predicate" =
  expectEqual ([] : List Int) (filter (> 10) [1, 2])

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

-- # intToString and floatToString

test "intToString renders zero, single digits, carries and negatives" =
  expectEqual
    ["0", "1", "-1", "9", "10", "99", "100", "-100"]
    [
      intToString 0,
      intToString 1,
      intToString (-1),
      intToString 9,
      intToString 10,
      intToString 99,
      intToString 100,
      intToString (-100),
    ]

test "intToString renders the Int bounds and a large value exactly" =
  expectEqual
    ["4611686018427387903", "-4611686018427387904", "1234567890123"]
    [
      intToString 4611686018427387903,
      intToString -4611686018427387904,
      intToString 1234567890123,
    ]

test "intToString cell reports its byte length as its codepoint count" =
  expectEqual
    [1, 20, 3]
    [
      stringLength (intToString 7),
      stringLength (intToString -4611686018427387904),
      stringLength (intToString (-1) ++ "x"),
    ]

test "floatToString renders the canonical lexeme" =
  expectEqual
    ["0.5", "100.0", "-2.5", "1e-07", "1e+20"]
    [
      floatToString 0.5,
      floatToString 100.0,
      floatToString (-2.5),
      floatToString 1e-07,
      floatToString 1e+20,
    ]

-- # Lazy fallbacks
--
-- The fallback panics if it runs on the hit path, and bumps a counter on the
-- miss path so "exactly once" is observable.

test "optionOrElse does not call the fallback for Some" =
  expectEqual 1 (optionOrElse (u => panic "fallback ran") (Some 1))

test "optionOrElse calls the fallback once for None" =
  let calls = Ref 0
  let v = optionOrElse (u => (calls := !calls + 1) |> (x => 7)) None
  expectEqual (7, 1) (v, !calls)

test "resultOrElse does not call the fallback for Ok" =
  expectEqual
    1
    (resultOrElse (e => panic "fallback ran") (Ok 1 : Result String Int))

test "resultOrElse calls the fallback once with the error for Err" =
  let calls = Ref 0
  let v =
    resultOrElse
      (e => (calls := !calls + 1) |> (x => stringLength e))
      (Err "boom")
  expectEqual (4, 1) (v, !calls)

test "orElseWith on Some does not call the fallback" =
  expectEqual (Some 1) (orElseWith (Some 1) (u => panic "fallback ran"))

test "orElseWith on None calls the fallback once" =
  let calls = Ref 0
  let v =
    orElseWith (None : Option Int) (u => (calls := !calls + 1) |> (x => Some 7))
  expectEqual (Some 7, 1) (v, !calls)

test "orElseWith on List appends the fallback" =
  expectEqual [1, 2, 3] (orElseWith [1, 2] (u => [3]))

-- # Short-circuiting folds

-- Each probe returns the answer and how many times the predicate ran.
countedAny : Foldable t => Int -> t Int -> (Bool, Int)
countedAny target xs =
  let calls = Ref 0
  let r = any (x => (calls := !calls + 1) |> (u => x == target)) xs
  (r, !calls)

countedAll : Foldable t => Int -> t Int -> (Bool, Int)
countedAll limit xs =
  let calls = Ref 0
  let r = all (x => (calls := !calls + 1) |> (u => x < limit)) xs
  (r, !calls)

countedFind : Foldable t => Int -> t Int -> (Option Int, Int)
countedFind target xs =
  let calls = Ref 0
  let r = find (x => (calls := !calls + 1) |> (u => x == target)) xs
  (r, !calls)

tenList : List Int
tenList = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

tenArray : Array Int
tenArray = [|1, 2, 3, 4, 5, 6, 7, 8, 9, 10|]

-- Early hit, middle hit, late hit, miss.
probeTargets : List Int
probeTargets = [1, 5, 10, 99]

-- The same expected answers must hold for the `List` and the `Array`.
expectOnBoth : (Eq r, Debug r) => List r -> List r -> List r -> Expectation
expectOnBoth expected viaList viaArray =
  expectAll [expectEqual expected viaList, expectEqual expected viaArray]

test "any stops at the hit and runs n times on a miss" =
  expectOnBoth
    [(True, 1), (True, 5), (True, 10), (False, 10)]
    (map (n => countedAny n tenList) probeTargets)
    (map (n => countedAny n tenArray) probeTargets)

test "all stops at the first failure and runs n times on success" =
  expectOnBoth
    [(False, 1), (False, 5), (False, 10), (True, 10)]
    (map (n => countedAll n tenList) probeTargets)
    (map (n => countedAll n tenArray) probeTargets)

test "find returns the first hit and stops there" =
  expectOnBoth
    [(Some 1, 1), (Some 5, 5), (Some 10, 10), (None, 10)]
    (map (n => countedFind n tenList) probeTargets)
    (map (n => countedFind n tenArray) probeTargets)

test "find returns the first of several matches" =
  expectEqual (Some 4) (find (> 3) [1, 4, 9])

test "elem on a list finds early, middle, late and misses" =
  let xs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
  expectEqual
    [True, True, True, False]
    [elem 1 xs, elem 5 xs, elem 10 xs, elem 99 xs]

test "elem on an array finds early, middle, late and misses" =
  let xs = [|1, 2, 3, 4, 5, 6, 7, 8, 9, 10|]
  expectEqual
    [True, True, True, False]
    [elem 1 xs, elem 5 xs, elem 10 xs, elem 99 xs]

test "any, all, elem and find on empty containers" =
  expectEqual
    (False, True, False, None)
    (
      any (> 0) ([] : List Int),
      all (> 0) ([||] : Array Int),
      elem 1 ([] : List Int),
      find (> 0) ([||] : Array Int),
    )

test "foldUntil on a list breaks with the payload and skips the rest" =
  let calls = Ref 0
  let step =
    acc x =>
      (calls := !calls + 1)
        |> (u => if x > 2 then Break (acc * 100) else Continue (acc + x))
  expectEqual (300, 3) (foldUntil step 0 [1, 2, 3, 4, 5], !calls)

test "foldUntil on an array that never breaks folds everything" =
  expectEqual 10 (foldUntil (acc x => Continue (acc + x)) 0 [|1, 2, 3, 4|])

test "foldUntil default on Option and Result" =
  expectEqual
    (7, 3, 0)
    (
      foldUntil (acc x => Continue (acc + x)) 0 (Some 7),
      foldUntil (acc x => Break (acc + x)) 0 (Ok 3 : Result String Int),
      foldUntil (acc x => Continue (acc + x)) 0 (Err "e" : Result String Int),
    )

test "foldUntil default on a Map stops early" =
  let m : Map Int Int = Map { 1 => 10, 2 => 20, 3 => 30 }
  expectEqual
    30
    (foldUntil
      (acc x => if acc + x >= 30 then Break (acc + x) else Continue (acc + x))
      0
      m)

-- # List andThen

test "List andThen concatenates in order" =
  expectEqual
    ([1, 10, 2, 20, 3, 30], [] : List Int, [1, 3], [7, 8])
    (
      andThen [1, 2, 3] (x => [x, x * 10]),
      andThen ([] : List Int) (x => [x]),
      andThen [1, 2, 3, 4] (x => if isEven x then [] else [x]),
      andThen [1, 2] (x => if x == 1 then [7, 8] else []),
    )

test "List andThen calls f once per element, left to right" =
  let log : Ref (List Int) = Ref []
  let out = andThen [1, 2, 3] (x => (log := x :: !log) |> (u => [x, x]))
  expectEqual ([1, 1, 2, 2, 3, 3], [3, 2, 1]) (out, !log)

test "ControlFlow compares, renders and hashes by constructor and payload" = expectAll
  [
    expectEqual (Continue 1) (Continue 1),
    expectEqual Lt (compare (Continue 9) (Break 0)),
    expectEqual "Break 2" (debug (Break 2)),
    expectEqual (hash (Continue 3)) (hash (Continue 3)),
  ]

test "bestEffort discards an Err and an Ok alike" = expectAll [
  expectEqual () (bestEffort "gone already" (Err "ENOENT" : Result String Int)),
  expectEqual () (bestEffort "unused" (Ok 1 : Result String Int)),
]
# DESUGAR
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectTrue" false) (mem "expectFalse" false) (mem "expectAll" false) (mem "Expectation" false))))
(DUse false (UseGroup ("map") ((mem "Map" false))))
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
(DTest false "filter keeps the elements that satisfy the predicate" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 2)) (ELit (LInt 4)))) (EApp (EApp (EVar "filter") (ELam ((PVar "x")) (EApp (EVar "isEven") (EVar "x")))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4))))))
(DTest false "filter keeps the order of the surviving elements" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 5)) (ELit (LInt 3)) (ELit (LInt 9)))) (EApp (EApp (EVar "filter") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 2))))) (EListLit (ELit (LInt 5)) (ELit (LInt 1)) (ELit (LInt 3)) (ELit (LInt 0)) (ELit (LInt 9))))))
(DTest false "filter of an empty list is empty" (EApp (EApp (EVar "expectEqual") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "filter") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 0))))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int"))))))
(DTest false "filter drops every element when none satisfies the predicate" (EApp (EApp (EVar "expectEqual") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "filter") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 10))))) (EListLit (ELit (LInt 1)) (ELit (LInt 2))))))
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
(DTest false "intToString renders zero, single digits, carries and negatives" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "0")) (ELit (LString "1")) (ELit (LString "-1")) (ELit (LString "9")) (ELit (LString "10")) (ELit (LString "99")) (ELit (LString "100")) (ELit (LString "-100")))) (EListLit (EApp (EVar "intToString") (ELit (LInt 0))) (EApp (EVar "intToString") (ELit (LInt 1))) (EApp (EVar "intToString") (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "intToString") (ELit (LInt 9))) (EApp (EVar "intToString") (ELit (LInt 10))) (EApp (EVar "intToString") (ELit (LInt 99))) (EApp (EVar "intToString") (ELit (LInt 100))) (EApp (EVar "intToString") (EUnOp "-" (ELit (LInt 100)))))))
(DTest false "intToString renders the Int bounds and a large value exactly" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "4611686018427387903")) (ELit (LString "-4611686018427387904")) (ELit (LString "1234567890123")))) (EListLit (EApp (EVar "intToString") (ELit (LInt 4611686018427387903))) (EApp (EVar "intToString") (ELit (LInt -4611686018427387904))) (EApp (EVar "intToString") (ELit (LInt 1234567890123))))))
(DTest false "intToString cell reports its byte length as its codepoint count" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 20)) (ELit (LInt 3)))) (EListLit (EApp (EVar "stringLength") (EApp (EVar "intToString") (ELit (LInt 7)))) (EApp (EVar "stringLength") (EApp (EVar "intToString") (ELit (LInt -4611686018427387904)))) (EApp (EVar "stringLength") (EBinOp "++" (EApp (EVar "intToString") (EUnOp "-" (ELit (LInt 1)))) (ELit (LString "x")))))))
(DTest false "floatToString renders the canonical lexeme" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "0.5")) (ELit (LString "100.0")) (ELit (LString "-2.5")) (ELit (LString "1e-07")) (ELit (LString "1e+20")))) (EListLit (EApp (EVar "floatToString") (ELit (LFloat 0.5))) (EApp (EVar "floatToString") (ELit (LFloat 100.0))) (EApp (EVar "floatToString") (EUnOp "-" (ELit (LFloat 2.5)))) (EApp (EVar "floatToString") (ELit (LFloat 1e-07))) (EApp (EVar "floatToString") (ELit (LFloat 1e+20))))))
(DTest false "optionOrElse does not call the fallback for Some" (EApp (EApp (EVar "expectEqual") (ELit (LInt 1))) (EApp (EApp (EVar "optionOrElse") (ELam ((PVar "u")) (EApp (EVar "panic") (ELit (LString "fallback ran"))))) (EApp (EVar "Some") (ELit (LInt 1))))))
(DTest false "optionOrElse calls the fallback once for None" (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "v") (EApp (EApp (EVar "optionOrElse") (ELam ((PVar "u")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "x")) (ELit (LInt 7)))))) (EVar "None"))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LInt 7)) (ELit (LInt 1)))) (ETuple (EVar "v") (EUnOp "!" (EVar "calls")))))))
(DTest false "resultOrElse does not call the fallback for Ok" (EApp (EApp (EVar "expectEqual") (ELit (LInt 1))) (EApp (EApp (EVar "resultOrElse") (ELam ((PVar "e")) (EApp (EVar "panic") (ELit (LString "fallback ran"))))) (EAnnot (EApp (EVar "Ok") (ELit (LInt 1))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DTest false "resultOrElse calls the fallback once with the error for Err" (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "v") (EApp (EApp (EVar "resultOrElse") (ELam ((PVar "e")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "x")) (EApp (EVar "stringLength") (EVar "e")))))) (EApp (EVar "Err") (ELit (LString "boom"))))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LInt 4)) (ELit (LInt 1)))) (ETuple (EVar "v") (EUnOp "!" (EVar "calls")))))))
(DTest false "orElseWith on Some does not call the fallback" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 1)))) (EApp (EApp (EVar "orElseWith") (EApp (EVar "Some") (ELit (LInt 1)))) (ELam ((PVar "u")) (EApp (EVar "panic") (ELit (LString "fallback ran")))))))
(DTest false "orElseWith on None calls the fallback once" (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "v") (EApp (EApp (EVar "orElseWith") (EAnnot (EVar "None") (TyApp (TyCon "Option") (TyCon "Int")))) (ELam ((PVar "u")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "x")) (EApp (EVar "Some") (ELit (LInt 7)))))))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 7))) (ELit (LInt 1)))) (ETuple (EVar "v") (EUnOp "!" (EVar "calls")))))))
(DTest false "orElseWith on List appends the fallback" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (EApp (EApp (EVar "orElseWith") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (ELam ((PVar "u")) (EListLit (ELit (LInt 3)))))))
(DTypeSig false "countedAny" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyVar "t") (TyCon "Int")) (TyTuple (TyCon "Bool") (TyCon "Int"))))))
(DFunDef false "countedAny" ((PVar "target") (PVar "xs")) (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "r") (EApp (EApp (EVar "any") (ELam ((PVar "x")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "u")) (EBinOp "==" (EVar "x") (EVar "target")))))) (EVar "xs"))) (DoExpr (ETuple (EVar "r") (EUnOp "!" (EVar "calls"))))))
(DTypeSig false "countedAll" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyVar "t") (TyCon "Int")) (TyTuple (TyCon "Bool") (TyCon "Int"))))))
(DFunDef false "countedAll" ((PVar "limit") (PVar "xs")) (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "r") (EApp (EApp (EVar "all") (ELam ((PVar "x")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "u")) (EBinOp "<" (EVar "x") (EVar "limit")))))) (EVar "xs"))) (DoExpr (ETuple (EVar "r") (EUnOp "!" (EVar "calls"))))))
(DTypeSig false "countedFind" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyVar "t") (TyCon "Int")) (TyTuple (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "Int"))))))
(DFunDef false "countedFind" ((PVar "target") (PVar "xs")) (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "r") (EApp (EApp (EVar "find") (ELam ((PVar "x")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "u")) (EBinOp "==" (EVar "x") (EVar "target")))))) (EVar "xs"))) (DoExpr (ETuple (EVar "r") (EUnOp "!" (EVar "calls"))))))
(DTypeSig false "tenList" (TyApp (TyCon "List") (TyCon "Int")))
(DFunDef false "tenList" () (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)) (ELit (LInt 7)) (ELit (LInt 8)) (ELit (LInt 9)) (ELit (LInt 10))))
(DTypeSig false "tenArray" (TyApp (TyCon "Array") (TyCon "Int")))
(DFunDef false "tenArray" () (EArrayLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)) (ELit (LInt 7)) (ELit (LInt 8)) (ELit (LInt 9)) (ELit (LInt 10))))
(DTypeSig false "probeTargets" (TyApp (TyCon "List") (TyCon "Int")))
(DFunDef false "probeTargets" () (EListLit (ELit (LInt 1)) (ELit (LInt 5)) (ELit (LInt 10)) (ELit (LInt 99))))
(DTypeSig false "expectOnBoth" (TyConstrained ((cstr "Eq" (TyVar "r")) (cstr "Debug" (TyVar "r"))) (TyFun (TyApp (TyCon "List") (TyVar "r")) (TyFun (TyApp (TyCon "List") (TyVar "r")) (TyFun (TyApp (TyCon "List") (TyVar "r")) (TyCon "Expectation"))))))
(DFunDef false "expectOnBoth" ((PVar "expected") (PVar "viaList") (PVar "viaArray")) (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EVar "expected")) (EVar "viaList")) (EApp (EApp (EVar "expectEqual") (EVar "expected")) (EVar "viaArray")))))
(DTest false "any stops at the hit and runs n times on a miss" (EApp (EApp (EApp (EVar "expectOnBoth") (EListLit (ETuple (EVar "True") (ELit (LInt 1))) (ETuple (EVar "True") (ELit (LInt 5))) (ETuple (EVar "True") (ELit (LInt 10))) (ETuple (EVar "False") (ELit (LInt 10))))) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EVar "countedAny") (EVar "n")) (EVar "tenList")))) (EVar "probeTargets"))) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EVar "countedAny") (EVar "n")) (EVar "tenArray")))) (EVar "probeTargets"))))
(DTest false "all stops at the first failure and runs n times on success" (EApp (EApp (EApp (EVar "expectOnBoth") (EListLit (ETuple (EVar "False") (ELit (LInt 1))) (ETuple (EVar "False") (ELit (LInt 5))) (ETuple (EVar "False") (ELit (LInt 10))) (ETuple (EVar "True") (ELit (LInt 10))))) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EVar "countedAll") (EVar "n")) (EVar "tenList")))) (EVar "probeTargets"))) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EVar "countedAll") (EVar "n")) (EVar "tenArray")))) (EVar "probeTargets"))))
(DTest false "find returns the first hit and stops there" (EApp (EApp (EApp (EVar "expectOnBoth") (EListLit (ETuple (EApp (EVar "Some") (ELit (LInt 1))) (ELit (LInt 1))) (ETuple (EApp (EVar "Some") (ELit (LInt 5))) (ELit (LInt 5))) (ETuple (EApp (EVar "Some") (ELit (LInt 10))) (ELit (LInt 10))) (ETuple (EVar "None") (ELit (LInt 10))))) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EVar "countedFind") (EVar "n")) (EVar "tenList")))) (EVar "probeTargets"))) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EVar "countedFind") (EVar "n")) (EVar "tenArray")))) (EVar "probeTargets"))))
(DTest false "find returns the first of several matches" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 4)))) (EApp (EApp (EVar "find") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 3))))) (EListLit (ELit (LInt 1)) (ELit (LInt 4)) (ELit (LInt 9))))))
(DTest false "elem on a list finds early, middle, late and misses" (EBlock (DoLet false false (PVar "xs") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)) (ELit (LInt 7)) (ELit (LInt 8)) (ELit (LInt 9)) (ELit (LInt 10)))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (EVar "True") (EVar "True") (EVar "True") (EVar "False"))) (EListLit (EApp (EApp (EVar "elem") (ELit (LInt 1))) (EVar "xs")) (EApp (EApp (EVar "elem") (ELit (LInt 5))) (EVar "xs")) (EApp (EApp (EVar "elem") (ELit (LInt 10))) (EVar "xs")) (EApp (EApp (EVar "elem") (ELit (LInt 99))) (EVar "xs")))))))
(DTest false "elem on an array finds early, middle, late and misses" (EBlock (DoLet false false (PVar "xs") (EArrayLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)) (ELit (LInt 7)) (ELit (LInt 8)) (ELit (LInt 9)) (ELit (LInt 10)))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (EVar "True") (EVar "True") (EVar "True") (EVar "False"))) (EListLit (EApp (EApp (EVar "elem") (ELit (LInt 1))) (EVar "xs")) (EApp (EApp (EVar "elem") (ELit (LInt 5))) (EVar "xs")) (EApp (EApp (EVar "elem") (ELit (LInt 10))) (EVar "xs")) (EApp (EApp (EVar "elem") (ELit (LInt 99))) (EVar "xs")))))))
(DTest false "any, all, elem and find on empty containers" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "False") (EVar "True") (EVar "False") (EVar "None"))) (ETuple (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 0))))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "all") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 0))))) (EAnnot (EArrayLit) (TyApp (TyCon "Array") (TyCon "Int")))) (EApp (EApp (EVar "elem") (ELit (LInt 1))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "find") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 0))))) (EAnnot (EArrayLit) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DTest false "foldUntil on a list breaks with the payload and skips the rest" (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "step") (ELam ((PVar "acc") (PVar "x")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "u")) (EIf (EBinOp ">" (EVar "x") (ELit (LInt 2))) (EApp (EVar "Break") (EBinOp "*" (EVar "acc") (ELit (LInt 100)))) (EApp (EVar "Continue") (EBinOp "+" (EVar "acc") (EVar "x")))))))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LInt 300)) (ELit (LInt 3)))) (ETuple (EApp (EApp (EApp (EVar "foldUntil") (EVar "step")) (ELit (LInt 0))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)))) (EUnOp "!" (EVar "calls")))))))
(DTest false "foldUntil on an array that never breaks folds everything" (EApp (EApp (EVar "expectEqual") (ELit (LInt 10))) (EApp (EApp (EApp (EVar "foldUntil") (ELam ((PVar "acc") (PVar "x")) (EApp (EVar "Continue") (EBinOp "+" (EVar "acc") (EVar "x"))))) (ELit (LInt 0))) (EArrayLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4))))))
(DTest false "foldUntil default on Option and Result" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LInt 7)) (ELit (LInt 3)) (ELit (LInt 0)))) (ETuple (EApp (EApp (EApp (EVar "foldUntil") (ELam ((PVar "acc") (PVar "x")) (EApp (EVar "Continue") (EBinOp "+" (EVar "acc") (EVar "x"))))) (ELit (LInt 0))) (EApp (EVar "Some") (ELit (LInt 7)))) (EApp (EApp (EApp (EVar "foldUntil") (ELam ((PVar "acc") (PVar "x")) (EApp (EVar "Break") (EBinOp "+" (EVar "acc") (EVar "x"))))) (ELit (LInt 0))) (EAnnot (EApp (EVar "Ok") (ELit (LInt 3))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))) (EApp (EApp (EApp (EVar "foldUntil") (ELam ((PVar "acc") (PVar "x")) (EApp (EVar "Continue") (EBinOp "+" (EVar "acc") (EVar "x"))))) (ELit (LInt 0))) (EAnnot (EApp (EVar "Err") (ELit (LString "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))))
(DTest false "foldUntil default on a Map stops early" (EBlock (DoLet false false (PVar "m") (EAnnot (EHeadAnnot (EApp (EVar "fromEntries") (EListLit (ETuple (ELit (LInt 1)) (ELit (LInt 10))) (ETuple (ELit (LInt 2)) (ELit (LInt 20))) (ETuple (ELit (LInt 3)) (ELit (LInt 30))))) (TyApp (TyApp (TyCon "Map") (TyVar "_k")) (TyVar "_v"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")))) (DoExpr (EApp (EApp (EVar "expectEqual") (ELit (LInt 30))) (EApp (EApp (EApp (EVar "foldUntil") (ELam ((PVar "acc") (PVar "x")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "acc") (EVar "x")) (ELit (LInt 30))) (EApp (EVar "Break") (EBinOp "+" (EVar "acc") (EVar "x"))) (EApp (EVar "Continue") (EBinOp "+" (EVar "acc") (EVar "x")))))) (ELit (LInt 0))) (EVar "m"))))))
(DTest false "List andThen concatenates in order" (EApp (EApp (EVar "expectEqual") (ETuple (EListLit (ELit (LInt 1)) (ELit (LInt 10)) (ELit (LInt 2)) (ELit (LInt 20)) (ELit (LInt 3)) (ELit (LInt 30))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int"))) (EListLit (ELit (LInt 1)) (ELit (LInt 3))) (EListLit (ELit (LInt 7)) (ELit (LInt 8))))) (ETuple (EApp (EApp (EVar "andThen") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (ELam ((PVar "x")) (EListLit (EVar "x") (EBinOp "*" (EVar "x") (ELit (LInt 10)))))) (EApp (EApp (EVar "andThen") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (ELam ((PVar "x")) (EListLit (EVar "x")))) (EApp (EApp (EVar "andThen") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)))) (ELam ((PVar "x")) (EIf (EApp (EVar "isEven") (EVar "x")) (EListLit) (EListLit (EVar "x"))))) (EApp (EApp (EVar "andThen") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (ELam ((PVar "x")) (EIf (EBinOp "==" (EVar "x") (ELit (LInt 1))) (EListLit (ELit (LInt 7)) (ELit (LInt 8))) (EListLit)))))))
(DTest false "List andThen calls f once per element, left to right" (EBlock (DoLet false false (PVar "log") (EAnnot (EApp (EVar "Ref") (EListLit)) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Int"))))) (DoLet false false (PVar "out") (EApp (EApp (EVar "andThen") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (ELam ((PVar "x")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "log")) (EBinOp "::" (EVar "x") (EUnOp "!" (EVar "log")))) (ELam ((PVar "u")) (EListLit (EVar "x") (EVar "x"))))))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EListLit (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 3))) (EListLit (ELit (LInt 3)) (ELit (LInt 2)) (ELit (LInt 1))))) (ETuple (EVar "out") (EUnOp "!" (EVar "log")))))))
(DTest false "ControlFlow compares, renders and hashes by constructor and payload" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Continue") (ELit (LInt 1)))) (EApp (EVar "Continue") (ELit (LInt 1)))) (EApp (EApp (EVar "expectEqual") (EVar "Lt")) (EApp (EApp (EVar "compare") (EApp (EVar "Continue") (ELit (LInt 9)))) (EApp (EVar "Break") (ELit (LInt 0))))) (EApp (EApp (EVar "expectEqual") (ELit (LString "Break 2"))) (EApp (EVar "debug") (EApp (EVar "Break") (ELit (LInt 2))))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "hash") (EApp (EVar "Continue") (ELit (LInt 3))))) (EApp (EVar "hash") (EApp (EVar "Continue") (ELit (LInt 3))))))))
(DTest false "bestEffort discards an Err and an Ok alike" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (ELit LUnit)) (EApp (EApp (EVar "bestEffort") (ELit (LString "gone already"))) (EAnnot (EApp (EVar "Err") (ELit (LString "ENOENT"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))) (EApp (EApp (EVar "expectEqual") (ELit LUnit)) (EApp (EApp (EVar "bestEffort") (ELit (LString "unused"))) (EAnnot (EApp (EVar "Ok") (ELit (LInt 1))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))))
# MARK
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectTrue" false) (mem "expectFalse" false) (mem "expectAll" false) (mem "Expectation" false))))
(DUse false (UseGroup ("map") ((mem "Map" false))))
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
(DTest false "filter keeps the elements that satisfy the predicate" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 2)) (ELit (LInt 4)))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "x")) (EApp (EVar "isEven") (EVar "x")))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4))))))
(DTest false "filter keeps the order of the surviving elements" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 5)) (ELit (LInt 3)) (ELit (LInt 9)))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 2))))) (EListLit (ELit (LInt 5)) (ELit (LInt 1)) (ELit (LInt 3)) (ELit (LInt 0)) (ELit (LInt 9))))))
(DTest false "filter of an empty list is empty" (EApp (EApp (EVar "expectEqual") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 0))))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int"))))))
(DTest false "filter drops every element when none satisfies the predicate" (EApp (EApp (EVar "expectEqual") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 10))))) (EListLit (ELit (LInt 1)) (ELit (LInt 2))))))
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
(DTest false "intToString renders zero, single digits, carries and negatives" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "0")) (ELit (LString "1")) (ELit (LString "-1")) (ELit (LString "9")) (ELit (LString "10")) (ELit (LString "99")) (ELit (LString "100")) (ELit (LString "-100")))) (EListLit (EApp (EVar "intToString") (ELit (LInt 0))) (EApp (EVar "intToString") (ELit (LInt 1))) (EApp (EVar "intToString") (EUnOp "-" (ELit (LInt 1)))) (EApp (EVar "intToString") (ELit (LInt 9))) (EApp (EVar "intToString") (ELit (LInt 10))) (EApp (EVar "intToString") (ELit (LInt 99))) (EApp (EVar "intToString") (ELit (LInt 100))) (EApp (EVar "intToString") (EUnOp "-" (ELit (LInt 100)))))))
(DTest false "intToString renders the Int bounds and a large value exactly" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "4611686018427387903")) (ELit (LString "-4611686018427387904")) (ELit (LString "1234567890123")))) (EListLit (EApp (EVar "intToString") (ELit (LInt 4611686018427387903))) (EApp (EVar "intToString") (ELit (LInt -4611686018427387904))) (EApp (EVar "intToString") (ELit (LInt 1234567890123))))))
(DTest false "intToString cell reports its byte length as its codepoint count" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 20)) (ELit (LInt 3)))) (EListLit (EApp (EVar "stringLength") (EApp (EVar "intToString") (ELit (LInt 7)))) (EApp (EVar "stringLength") (EApp (EVar "intToString") (ELit (LInt -4611686018427387904)))) (EApp (EVar "stringLength") (EBinOp "++" (EApp (EVar "intToString") (EUnOp "-" (ELit (LInt 1)))) (ELit (LString "x")))))))
(DTest false "floatToString renders the canonical lexeme" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "0.5")) (ELit (LString "100.0")) (ELit (LString "-2.5")) (ELit (LString "1e-07")) (ELit (LString "1e+20")))) (EListLit (EApp (EVar "floatToString") (ELit (LFloat 0.5))) (EApp (EVar "floatToString") (ELit (LFloat 100.0))) (EApp (EVar "floatToString") (EUnOp "-" (ELit (LFloat 2.5)))) (EApp (EVar "floatToString") (ELit (LFloat 1e-07))) (EApp (EVar "floatToString") (ELit (LFloat 1e+20))))))
(DTest false "optionOrElse does not call the fallback for Some" (EApp (EApp (EVar "expectEqual") (ELit (LInt 1))) (EApp (EApp (EVar "optionOrElse") (ELam ((PVar "u")) (EApp (EVar "panic") (ELit (LString "fallback ran"))))) (EApp (EVar "Some") (ELit (LInt 1))))))
(DTest false "optionOrElse calls the fallback once for None" (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "v") (EApp (EApp (EVar "optionOrElse") (ELam ((PVar "u")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "x")) (ELit (LInt 7)))))) (EVar "None"))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LInt 7)) (ELit (LInt 1)))) (ETuple (EVar "v") (EUnOp "!" (EVar "calls")))))))
(DTest false "resultOrElse does not call the fallback for Ok" (EApp (EApp (EVar "expectEqual") (ELit (LInt 1))) (EApp (EApp (EVar "resultOrElse") (ELam ((PVar "e")) (EApp (EVar "panic") (ELit (LString "fallback ran"))))) (EAnnot (EApp (EVar "Ok") (ELit (LInt 1))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))
(DTest false "resultOrElse calls the fallback once with the error for Err" (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "v") (EApp (EApp (EVar "resultOrElse") (ELam ((PVar "e")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "x")) (EApp (EVar "stringLength") (EVar "e")))))) (EApp (EVar "Err") (ELit (LString "boom"))))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LInt 4)) (ELit (LInt 1)))) (ETuple (EVar "v") (EUnOp "!" (EVar "calls")))))))
(DTest false "orElseWith on Some does not call the fallback" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 1)))) (EApp (EApp (EMethodRef "orElseWith") (EApp (EVar "Some") (ELit (LInt 1)))) (ELam ((PVar "u")) (EApp (EVar "panic") (ELit (LString "fallback ran")))))))
(DTest false "orElseWith on None calls the fallback once" (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "v") (EApp (EApp (EMethodRef "orElseWith") (EAnnot (EVar "None") (TyApp (TyCon "Option") (TyCon "Int")))) (ELam ((PVar "u")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "x")) (EApp (EVar "Some") (ELit (LInt 7)))))))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 7))) (ELit (LInt 1)))) (ETuple (EVar "v") (EUnOp "!" (EVar "calls")))))))
(DTest false "orElseWith on List appends the fallback" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (EApp (EApp (EMethodRef "orElseWith") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (ELam ((PVar "u")) (EListLit (ELit (LInt 3)))))))
(DTypeSig false "countedAny" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyVar "t") (TyCon "Int")) (TyTuple (TyCon "Bool") (TyCon "Int"))))))
(DFunDef false "countedAny" ((PVar "target") (PVar "xs")) (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "r") (EApp (EApp (EDictApp "any") (ELam ((PVar "x")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "u")) (EBinOp "==" (EVar "x") (EVar "target")))))) (EVar "xs"))) (DoExpr (ETuple (EVar "r") (EUnOp "!" (EVar "calls"))))))
(DTypeSig false "countedAll" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyVar "t") (TyCon "Int")) (TyTuple (TyCon "Bool") (TyCon "Int"))))))
(DFunDef false "countedAll" ((PVar "limit") (PVar "xs")) (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "r") (EApp (EApp (EDictApp "all") (ELam ((PVar "x")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "u")) (EBinOp "<" (EVar "x") (EVar "limit")))))) (EVar "xs"))) (DoExpr (ETuple (EVar "r") (EUnOp "!" (EVar "calls"))))))
(DTypeSig false "countedFind" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyVar "t") (TyCon "Int")) (TyTuple (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "Int"))))))
(DFunDef false "countedFind" ((PVar "target") (PVar "xs")) (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "r") (EApp (EApp (EDictApp "find") (ELam ((PVar "x")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "u")) (EBinOp "==" (EVar "x") (EVar "target")))))) (EVar "xs"))) (DoExpr (ETuple (EVar "r") (EUnOp "!" (EVar "calls"))))))
(DTypeSig false "tenList" (TyApp (TyCon "List") (TyCon "Int")))
(DFunDef false "tenList" () (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)) (ELit (LInt 7)) (ELit (LInt 8)) (ELit (LInt 9)) (ELit (LInt 10))))
(DTypeSig false "tenArray" (TyApp (TyCon "Array") (TyCon "Int")))
(DFunDef false "tenArray" () (EArrayLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)) (ELit (LInt 7)) (ELit (LInt 8)) (ELit (LInt 9)) (ELit (LInt 10))))
(DTypeSig false "probeTargets" (TyApp (TyCon "List") (TyCon "Int")))
(DFunDef false "probeTargets" () (EListLit (ELit (LInt 1)) (ELit (LInt 5)) (ELit (LInt 10)) (ELit (LInt 99))))
(DTypeSig false "expectOnBoth" (TyConstrained ((cstr "Eq" (TyVar "r")) (cstr "Debug" (TyVar "r"))) (TyFun (TyApp (TyCon "List") (TyVar "r")) (TyFun (TyApp (TyCon "List") (TyVar "r")) (TyFun (TyApp (TyCon "List") (TyVar "r")) (TyCon "Expectation"))))))
(DFunDef false "expectOnBoth" ((PVar "expected") (PVar "viaList") (PVar "viaArray")) (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EVar "expected")) (EVar "viaList")) (EApp (EApp (EVar "expectEqual") (EVar "expected")) (EVar "viaArray")))))
(DTest false "any stops at the hit and runs n times on a miss" (EApp (EApp (EApp (EDictApp "expectOnBoth") (EListLit (ETuple (EVar "True") (ELit (LInt 1))) (ETuple (EVar "True") (ELit (LInt 5))) (ETuple (EVar "True") (ELit (LInt 10))) (ETuple (EVar "False") (ELit (LInt 10))))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EDictApp "countedAny") (EVar "n")) (EVar "tenList")))) (EVar "probeTargets"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EDictApp "countedAny") (EVar "n")) (EVar "tenArray")))) (EVar "probeTargets"))))
(DTest false "all stops at the first failure and runs n times on success" (EApp (EApp (EApp (EDictApp "expectOnBoth") (EListLit (ETuple (EVar "False") (ELit (LInt 1))) (ETuple (EVar "False") (ELit (LInt 5))) (ETuple (EVar "False") (ELit (LInt 10))) (ETuple (EVar "True") (ELit (LInt 10))))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EDictApp "countedAll") (EVar "n")) (EVar "tenList")))) (EVar "probeTargets"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EDictApp "countedAll") (EVar "n")) (EVar "tenArray")))) (EVar "probeTargets"))))
(DTest false "find returns the first hit and stops there" (EApp (EApp (EApp (EDictApp "expectOnBoth") (EListLit (ETuple (EApp (EVar "Some") (ELit (LInt 1))) (ELit (LInt 1))) (ETuple (EApp (EVar "Some") (ELit (LInt 5))) (ELit (LInt 5))) (ETuple (EApp (EVar "Some") (ELit (LInt 10))) (ELit (LInt 10))) (ETuple (EVar "None") (ELit (LInt 10))))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EDictApp "countedFind") (EVar "n")) (EVar "tenList")))) (EVar "probeTargets"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EDictApp "countedFind") (EVar "n")) (EVar "tenArray")))) (EVar "probeTargets"))))
(DTest false "find returns the first of several matches" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 4)))) (EApp (EApp (EDictApp "find") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 3))))) (EListLit (ELit (LInt 1)) (ELit (LInt 4)) (ELit (LInt 9))))))
(DTest false "elem on a list finds early, middle, late and misses" (EBlock (DoLet false false (PVar "xs") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)) (ELit (LInt 7)) (ELit (LInt 8)) (ELit (LInt 9)) (ELit (LInt 10)))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (EVar "True") (EVar "True") (EVar "True") (EVar "False"))) (EListLit (EApp (EApp (EDictApp "elem") (ELit (LInt 1))) (EVar "xs")) (EApp (EApp (EDictApp "elem") (ELit (LInt 5))) (EVar "xs")) (EApp (EApp (EDictApp "elem") (ELit (LInt 10))) (EVar "xs")) (EApp (EApp (EDictApp "elem") (ELit (LInt 99))) (EVar "xs")))))))
(DTest false "elem on an array finds early, middle, late and misses" (EBlock (DoLet false false (PVar "xs") (EArrayLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)) (ELit (LInt 7)) (ELit (LInt 8)) (ELit (LInt 9)) (ELit (LInt 10)))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (EVar "True") (EVar "True") (EVar "True") (EVar "False"))) (EListLit (EApp (EApp (EDictApp "elem") (ELit (LInt 1))) (EVar "xs")) (EApp (EApp (EDictApp "elem") (ELit (LInt 5))) (EVar "xs")) (EApp (EApp (EDictApp "elem") (ELit (LInt 10))) (EVar "xs")) (EApp (EApp (EDictApp "elem") (ELit (LInt 99))) (EVar "xs")))))))
(DTest false "any, all, elem and find on empty containers" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "False") (EVar "True") (EVar "False") (EVar "None"))) (ETuple (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 0))))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EDictApp "all") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 0))))) (EAnnot (EArrayLit) (TyApp (TyCon "Array") (TyCon "Int")))) (EApp (EApp (EDictApp "elem") (ELit (LInt 1))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EDictApp "find") (ELam ((PVar "_s")) (EBinOp ">" (EVar "_s") (ELit (LInt 0))))) (EAnnot (EArrayLit) (TyApp (TyCon "Array") (TyCon "Int")))))))
(DTest false "foldUntil on a list breaks with the payload and skips the rest" (EBlock (DoLet false false (PVar "calls") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "step") (ELam ((PVar "acc") (PVar "x")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "calls")) (EBinOp "+" (EUnOp "!" (EVar "calls")) (ELit (LInt 1)))) (ELam ((PVar "u")) (EIf (EBinOp ">" (EVar "x") (ELit (LInt 2))) (EApp (EVar "Break") (EBinOp "*" (EVar "acc") (ELit (LInt 100)))) (EApp (EVar "Continue") (EBinOp "+" (EVar "acc") (EVar "x")))))))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LInt 300)) (ELit (LInt 3)))) (ETuple (EApp (EApp (EApp (EMethodRef "foldUntil") (EVar "step")) (ELit (LInt 0))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)))) (EUnOp "!" (EVar "calls")))))))
(DTest false "foldUntil on an array that never breaks folds everything" (EApp (EApp (EVar "expectEqual") (ELit (LInt 10))) (EApp (EApp (EApp (EMethodRef "foldUntil") (ELam ((PVar "acc") (PVar "x")) (EApp (EVar "Continue") (EBinOp "+" (EVar "acc") (EVar "x"))))) (ELit (LInt 0))) (EArrayLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4))))))
(DTest false "foldUntil default on Option and Result" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LInt 7)) (ELit (LInt 3)) (ELit (LInt 0)))) (ETuple (EApp (EApp (EApp (EMethodRef "foldUntil") (ELam ((PVar "acc") (PVar "x")) (EApp (EVar "Continue") (EBinOp "+" (EVar "acc") (EVar "x"))))) (ELit (LInt 0))) (EApp (EVar "Some") (ELit (LInt 7)))) (EApp (EApp (EApp (EMethodRef "foldUntil") (ELam ((PVar "acc") (PVar "x")) (EApp (EVar "Break") (EBinOp "+" (EVar "acc") (EVar "x"))))) (ELit (LInt 0))) (EAnnot (EApp (EVar "Ok") (ELit (LInt 3))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))) (EApp (EApp (EApp (EMethodRef "foldUntil") (ELam ((PVar "acc") (PVar "x")) (EApp (EVar "Continue") (EBinOp "+" (EVar "acc") (EVar "x"))))) (ELit (LInt 0))) (EAnnot (EApp (EVar "Err") (ELit (LString "e"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))))
(DTest false "foldUntil default on a Map stops early" (EBlock (DoLet false false (PVar "m") (EAnnot (EHeadAnnot (EApp (EMethodRef "fromEntries") (EListLit (ETuple (ELit (LInt 1)) (ELit (LInt 10))) (ETuple (ELit (LInt 2)) (ELit (LInt 20))) (ETuple (ELit (LInt 3)) (ELit (LInt 30))))) (TyApp (TyApp (TyCon "Map") (TyVar "_k")) (TyVar "_v"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Int")))) (DoExpr (EApp (EApp (EVar "expectEqual") (ELit (LInt 30))) (EApp (EApp (EApp (EMethodRef "foldUntil") (ELam ((PVar "acc") (PVar "x")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "acc") (EVar "x")) (ELit (LInt 30))) (EApp (EVar "Break") (EBinOp "+" (EVar "acc") (EVar "x"))) (EApp (EVar "Continue") (EBinOp "+" (EVar "acc") (EVar "x")))))) (ELit (LInt 0))) (EVar "m"))))))
(DTest false "List andThen concatenates in order" (EApp (EApp (EVar "expectEqual") (ETuple (EListLit (ELit (LInt 1)) (ELit (LInt 10)) (ELit (LInt 2)) (ELit (LInt 20)) (ELit (LInt 3)) (ELit (LInt 30))) (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int"))) (EListLit (ELit (LInt 1)) (ELit (LInt 3))) (EListLit (ELit (LInt 7)) (ELit (LInt 8))))) (ETuple (EApp (EApp (EMethodRef "andThen") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (ELam ((PVar "x")) (EListLit (EVar "x") (EBinOp "*" (EVar "x") (ELit (LInt 10)))))) (EApp (EApp (EMethodRef "andThen") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (ELam ((PVar "x")) (EListLit (EVar "x")))) (EApp (EApp (EMethodRef "andThen") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)))) (ELam ((PVar "x")) (EIf (EApp (EVar "isEven") (EVar "x")) (EListLit) (EListLit (EVar "x"))))) (EApp (EApp (EMethodRef "andThen") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (ELam ((PVar "x")) (EIf (EBinOp "==" (EVar "x") (ELit (LInt 1))) (EListLit (ELit (LInt 7)) (ELit (LInt 8))) (EListLit)))))))
(DTest false "List andThen calls f once per element, left to right" (EBlock (DoLet false false (PVar "log") (EAnnot (EApp (EVar "Ref") (EListLit)) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Int"))))) (DoLet false false (PVar "out") (EApp (EApp (EMethodRef "andThen") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (ELam ((PVar "x")) (EBinOp "|>" (EApp (EApp (EVar "setRef") (EVar "log")) (EBinOp "::" (EVar "x") (EUnOp "!" (EVar "log")))) (ELam ((PVar "u")) (EListLit (EVar "x") (EVar "x"))))))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EListLit (ELit (LInt 1)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 3))) (EListLit (ELit (LInt 3)) (ELit (LInt 2)) (ELit (LInt 1))))) (ETuple (EVar "out") (EUnOp "!" (EVar "log")))))))
(DTest false "ControlFlow compares, renders and hashes by constructor and payload" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "Continue") (ELit (LInt 1)))) (EApp (EVar "Continue") (ELit (LInt 1)))) (EApp (EApp (EVar "expectEqual") (EVar "Lt")) (EApp (EApp (EMethodRef "compare") (EApp (EVar "Continue") (ELit (LInt 9)))) (EApp (EVar "Break") (ELit (LInt 0))))) (EApp (EApp (EVar "expectEqual") (ELit (LString "Break 2"))) (EApp (EMethodRef "debug") (EApp (EVar "Break") (ELit (LInt 2))))) (EApp (EApp (EVar "expectEqual") (EApp (EMethodRef "hash") (EApp (EVar "Continue") (ELit (LInt 3))))) (EApp (EMethodRef "hash") (EApp (EVar "Continue") (ELit (LInt 3))))))))
(DTest false "bestEffort discards an Err and an Ok alike" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (ELit LUnit)) (EApp (EApp (EVar "bestEffort") (ELit (LString "gone already"))) (EAnnot (EApp (EVar "Err") (ELit (LString "ENOENT"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))) (EApp (EApp (EVar "expectEqual") (ELit LUnit)) (EApp (EApp (EVar "bestEffort") (ELit (LString "unused"))) (EAnnot (EApp (EVar "Ok") (ELit (LInt 1))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int"))))))))
