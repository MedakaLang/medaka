# META
source_lines=77
stages=DESUGAR,MARK
# SOURCE
-- Tests for the statistics functions in `stdlib/math.mdk`.

import math.{mean, median, percentile, stdev}
import string.{toFixed}
import test.{expectAll, expectEqual, expectNone, expectWithin, fail}

test "mean of an empty list is None" = expectNone (mean [])

test "mean averages the elements" =
  expectEqual (Some 3.0) (mean [1.0, 2.0, 3.0, 6.0])

test "median of an empty list is None" = expectNone (median [])

test "median of an odd length is the middle value" =
  expectEqual (Some 3.0) (median [9.0, 1.0, 3.0])

test "median of an even length averages the middle two" =
  expectEqual (Some 2.5) (median [4.0, 1.0, 3.0, 2.0])

test "stdev of one element is None" = expectNone (stdev [5.0])

test "stdev of an empty list is None" = expectNone (stdev [])

test "stdev is the sample deviation" =
  match stdev [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
    Some s => expectWithin 2.138089935299395 s 1e-09
    None => expectEqual 0.0 1.0

test "percentile 0 and 100 are the extremes" =
  expectEqual
    (Some 1.0, Some 9.0)
    (percentile 0.0 [9.0, 1.0, 4.0], percentile 100.0 [9.0, 1.0, 4.0])

test "percentile 50 equals median for odd lengths and None for empty" =
  expectEqual
    [median [], median [7.0], median [5.0, 1.0, 3.0, 8.0, 2.0]]
    (map (xs => percentile 50.0 xs) [[], [7.0], [5.0, 1.0, 3.0, 8.0, 2.0]])

test "percentile 50 matches median for an even length within rounding" = match (
  percentile 50.0 [76.38, 25.51],
  median [76.38, 25.51],
)
  (Some a, Some b) => expectWithin b a 1e-12
  _ => fail "expected both to be Some"

test "median of an exact middle does not read an infinite neighbour" =
  expectEqual (Some 2.0) (median [1.0, 2.0, 1.0 / 0.0])

test "median of an odd length ignores overflowing extremes" =
  expectEqual (Some (-1.7e+308)) (median [-1.7e+308, -1.7e+308, 1.7e+308])

test "median of two floats is their mean, not an interpolation" = expectAll [
  expectEqual (mean [76.38, 25.51]) (median [76.38, 25.51]),
  expectEqual (Some "50.95") (map (toFixed 2) (median [76.38, 25.51])),
]

test "percentile at an exact rank does not read the next element" =
  expectEqual
    (Some 1.0, Some (1.0 / 0.0))
    (percentile 0.0 [1.0, 1.0 / 0.0], percentile 100.0 [1.0, 1.0 / 0.0])

test "percentile interpolates between ranks" =
  expectEqual (Some 3.25) (percentile 75.0 [1.0, 2.0, 3.0, 4.0])

test "percentile of a single element is that element" =
  expectEqual (Some 4.0) (percentile 37.0 [4.0])

test "percentile outside 0 to 100 is None" =
  expectEqual
    [None, None, None]
    [
      percentile 101.0 [1.0],
      percentile (0.0 - 1.0) [1.0],
      percentile (0.0 / 0.0) [1.0],
    ]

test "percentile of an empty list is None" = expectNone (percentile 50.0 [])
# DESUGAR
(DUse false (UseGroup ("math") ((mem "mean" false) (mem "median" false) (mem "percentile" false) (mem "stdev" false))))
(DUse false (UseGroup ("string") ((mem "toFixed" false))))
(DUse false (UseGroup ("test") ((mem "expectAll" false) (mem "expectEqual" false) (mem "expectNone" false) (mem "expectWithin" false) (mem "fail" false))))
(DTest false "mean of an empty list is None" (EApp (EVar "expectNone") (EApp (EVar "mean") (EListLit))))
(DTest false "mean averages the elements" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 3.0)))) (EApp (EVar "mean") (EListLit (ELit (LFloat 1.0)) (ELit (LFloat 2.0)) (ELit (LFloat 3.0)) (ELit (LFloat 6.0))))))
(DTest false "median of an empty list is None" (EApp (EVar "expectNone") (EApp (EVar "median") (EListLit))))
(DTest false "median of an odd length is the middle value" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 3.0)))) (EApp (EVar "median") (EListLit (ELit (LFloat 9.0)) (ELit (LFloat 1.0)) (ELit (LFloat 3.0))))))
(DTest false "median of an even length averages the middle two" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 2.5)))) (EApp (EVar "median") (EListLit (ELit (LFloat 4.0)) (ELit (LFloat 1.0)) (ELit (LFloat 3.0)) (ELit (LFloat 2.0))))))
(DTest false "stdev of one element is None" (EApp (EVar "expectNone") (EApp (EVar "stdev") (EListLit (ELit (LFloat 5.0))))))
(DTest false "stdev of an empty list is None" (EApp (EVar "expectNone") (EApp (EVar "stdev") (EListLit))))
(DTest false "stdev is the sample deviation" (EMatch (EApp (EVar "stdev") (EListLit (ELit (LFloat 2.0)) (ELit (LFloat 4.0)) (ELit (LFloat 4.0)) (ELit (LFloat 4.0)) (ELit (LFloat 5.0)) (ELit (LFloat 5.0)) (ELit (LFloat 7.0)) (ELit (LFloat 9.0)))) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EVar "expectWithin") (ELit (LFloat 2.138089935299395))) (EVar "s")) (ELit (LFloat 1e-09)))) (arm (PCon "None") () (EApp (EApp (EVar "expectEqual") (ELit (LFloat 0.0))) (ELit (LFloat 1.0))))))
(DTest false "percentile 0 and 100 are the extremes" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LFloat 1.0))) (EApp (EVar "Some") (ELit (LFloat 9.0))))) (ETuple (EApp (EApp (EVar "percentile") (ELit (LFloat 0.0))) (EListLit (ELit (LFloat 9.0)) (ELit (LFloat 1.0)) (ELit (LFloat 4.0)))) (EApp (EApp (EVar "percentile") (ELit (LFloat 100.0))) (EListLit (ELit (LFloat 9.0)) (ELit (LFloat 1.0)) (ELit (LFloat 4.0)))))))
(DTest false "percentile 50 equals median for odd lengths and None for empty" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "median") (EListLit)) (EApp (EVar "median") (EListLit (ELit (LFloat 7.0)))) (EApp (EVar "median") (EListLit (ELit (LFloat 5.0)) (ELit (LFloat 1.0)) (ELit (LFloat 3.0)) (ELit (LFloat 8.0)) (ELit (LFloat 2.0)))))) (EApp (EApp (EVar "map") (ELam ((PVar "xs")) (EApp (EApp (EVar "percentile") (ELit (LFloat 50.0))) (EVar "xs")))) (EListLit (EListLit) (EListLit (ELit (LFloat 7.0))) (EListLit (ELit (LFloat 5.0)) (ELit (LFloat 1.0)) (ELit (LFloat 3.0)) (ELit (LFloat 8.0)) (ELit (LFloat 2.0)))))))
(DTest false "percentile 50 matches median for an even length within rounding" (EMatch (ETuple (EApp (EApp (EVar "percentile") (ELit (LFloat 50.0))) (EListLit (ELit (LFloat 76.38)) (ELit (LFloat 25.51)))) (EApp (EVar "median") (EListLit (ELit (LFloat 76.38)) (ELit (LFloat 25.51))))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EApp (EApp (EVar "expectWithin") (EVar "b")) (EVar "a")) (ELit (LFloat 1e-12)))) (arm PWild () (EApp (EVar "fail") (ELit (LString "expected both to be Some"))))))
(DTest false "median of an exact middle does not read an infinite neighbour" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 2.0)))) (EApp (EVar "median") (EListLit (ELit (LFloat 1.0)) (ELit (LFloat 2.0)) (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 0.0)))))))
(DTest false "median of an odd length ignores overflowing extremes" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (EUnOp "-" (ELit (LFloat 1.7e+308))))) (EApp (EVar "median") (EListLit (EUnOp "-" (ELit (LFloat 1.7e+308))) (EUnOp "-" (ELit (LFloat 1.7e+308))) (ELit (LFloat 1.7e+308))))))
(DTest false "median of two floats is their mean, not an interpolation" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "mean") (EListLit (ELit (LFloat 76.38)) (ELit (LFloat 25.51))))) (EApp (EVar "median") (EListLit (ELit (LFloat 76.38)) (ELit (LFloat 25.51))))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "50.95")))) (EApp (EApp (EVar "map") (EApp (EVar "toFixed") (ELit (LInt 2)))) (EApp (EVar "median") (EListLit (ELit (LFloat 76.38)) (ELit (LFloat 25.51)))))))))
(DTest false "percentile at an exact rank does not read the next element" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LFloat 1.0))) (EApp (EVar "Some") (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 0.0)))))) (ETuple (EApp (EApp (EVar "percentile") (ELit (LFloat 0.0))) (EListLit (ELit (LFloat 1.0)) (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 0.0))))) (EApp (EApp (EVar "percentile") (ELit (LFloat 100.0))) (EListLit (ELit (LFloat 1.0)) (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 0.0))))))))
(DTest false "percentile interpolates between ranks" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 3.25)))) (EApp (EApp (EVar "percentile") (ELit (LFloat 75.0))) (EListLit (ELit (LFloat 1.0)) (ELit (LFloat 2.0)) (ELit (LFloat 3.0)) (ELit (LFloat 4.0))))))
(DTest false "percentile of a single element is that element" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 4.0)))) (EApp (EApp (EVar "percentile") (ELit (LFloat 37.0))) (EListLit (ELit (LFloat 4.0))))))
(DTest false "percentile outside 0 to 100 is None" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "None") (EVar "None") (EVar "None"))) (EListLit (EApp (EApp (EVar "percentile") (ELit (LFloat 101.0))) (EListLit (ELit (LFloat 1.0)))) (EApp (EApp (EVar "percentile") (EBinOp "-" (ELit (LFloat 0.0)) (ELit (LFloat 1.0)))) (EListLit (ELit (LFloat 1.0)))) (EApp (EApp (EVar "percentile") (EBinOp "/" (ELit (LFloat 0.0)) (ELit (LFloat 0.0)))) (EListLit (ELit (LFloat 1.0)))))))
(DTest false "percentile of an empty list is None" (EApp (EVar "expectNone") (EApp (EApp (EVar "percentile") (ELit (LFloat 50.0))) (EListLit))))
# MARK
(DUse false (UseGroup ("math") ((mem "mean" false) (mem "median" false) (mem "percentile" false) (mem "stdev" false))))
(DUse false (UseGroup ("string") ((mem "toFixed" false))))
(DUse false (UseGroup ("test") ((mem "expectAll" false) (mem "expectEqual" false) (mem "expectNone" false) (mem "expectWithin" false) (mem "fail" false))))
(DTest false "mean of an empty list is None" (EApp (EVar "expectNone") (EApp (EVar "mean") (EListLit))))
(DTest false "mean averages the elements" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 3.0)))) (EApp (EVar "mean") (EListLit (ELit (LFloat 1.0)) (ELit (LFloat 2.0)) (ELit (LFloat 3.0)) (ELit (LFloat 6.0))))))
(DTest false "median of an empty list is None" (EApp (EVar "expectNone") (EApp (EVar "median") (EListLit))))
(DTest false "median of an odd length is the middle value" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 3.0)))) (EApp (EVar "median") (EListLit (ELit (LFloat 9.0)) (ELit (LFloat 1.0)) (ELit (LFloat 3.0))))))
(DTest false "median of an even length averages the middle two" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 2.5)))) (EApp (EVar "median") (EListLit (ELit (LFloat 4.0)) (ELit (LFloat 1.0)) (ELit (LFloat 3.0)) (ELit (LFloat 2.0))))))
(DTest false "stdev of one element is None" (EApp (EVar "expectNone") (EApp (EVar "stdev") (EListLit (ELit (LFloat 5.0))))))
(DTest false "stdev of an empty list is None" (EApp (EVar "expectNone") (EApp (EVar "stdev") (EListLit))))
(DTest false "stdev is the sample deviation" (EMatch (EApp (EVar "stdev") (EListLit (ELit (LFloat 2.0)) (ELit (LFloat 4.0)) (ELit (LFloat 4.0)) (ELit (LFloat 4.0)) (ELit (LFloat 5.0)) (ELit (LFloat 5.0)) (ELit (LFloat 7.0)) (ELit (LFloat 9.0)))) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EVar "expectWithin") (ELit (LFloat 2.138089935299395))) (EVar "s")) (ELit (LFloat 1e-09)))) (arm (PCon "None") () (EApp (EApp (EVar "expectEqual") (ELit (LFloat 0.0))) (ELit (LFloat 1.0))))))
(DTest false "percentile 0 and 100 are the extremes" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LFloat 1.0))) (EApp (EVar "Some") (ELit (LFloat 9.0))))) (ETuple (EApp (EApp (EVar "percentile") (ELit (LFloat 0.0))) (EListLit (ELit (LFloat 9.0)) (ELit (LFloat 1.0)) (ELit (LFloat 4.0)))) (EApp (EApp (EVar "percentile") (ELit (LFloat 100.0))) (EListLit (ELit (LFloat 9.0)) (ELit (LFloat 1.0)) (ELit (LFloat 4.0)))))))
(DTest false "percentile 50 equals median for odd lengths and None for empty" (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "median") (EListLit)) (EApp (EVar "median") (EListLit (ELit (LFloat 7.0)))) (EApp (EVar "median") (EListLit (ELit (LFloat 5.0)) (ELit (LFloat 1.0)) (ELit (LFloat 3.0)) (ELit (LFloat 8.0)) (ELit (LFloat 2.0)))))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "xs")) (EApp (EApp (EVar "percentile") (ELit (LFloat 50.0))) (EVar "xs")))) (EListLit (EListLit) (EListLit (ELit (LFloat 7.0))) (EListLit (ELit (LFloat 5.0)) (ELit (LFloat 1.0)) (ELit (LFloat 3.0)) (ELit (LFloat 8.0)) (ELit (LFloat 2.0)))))))
(DTest false "percentile 50 matches median for an even length within rounding" (EMatch (ETuple (EApp (EApp (EVar "percentile") (ELit (LFloat 50.0))) (EListLit (ELit (LFloat 76.38)) (ELit (LFloat 25.51)))) (EApp (EVar "median") (EListLit (ELit (LFloat 76.38)) (ELit (LFloat 25.51))))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EApp (EApp (EVar "expectWithin") (EVar "b")) (EVar "a")) (ELit (LFloat 1e-12)))) (arm PWild () (EApp (EVar "fail") (ELit (LString "expected both to be Some"))))))
(DTest false "median of an exact middle does not read an infinite neighbour" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 2.0)))) (EApp (EVar "median") (EListLit (ELit (LFloat 1.0)) (ELit (LFloat 2.0)) (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 0.0)))))))
(DTest false "median of an odd length ignores overflowing extremes" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (EUnOp "-" (ELit (LFloat 1.7e+308))))) (EApp (EVar "median") (EListLit (EUnOp "-" (ELit (LFloat 1.7e+308))) (EUnOp "-" (ELit (LFloat 1.7e+308))) (ELit (LFloat 1.7e+308))))))
(DTest false "median of two floats is their mean, not an interpolation" (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectEqual") (EApp (EVar "mean") (EListLit (ELit (LFloat 76.38)) (ELit (LFloat 25.51))))) (EApp (EVar "median") (EListLit (ELit (LFloat 76.38)) (ELit (LFloat 25.51))))) (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "50.95")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "toFixed") (ELit (LInt 2)))) (EApp (EVar "median") (EListLit (ELit (LFloat 76.38)) (ELit (LFloat 25.51)))))))))
(DTest false "percentile at an exact rank does not read the next element" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LFloat 1.0))) (EApp (EVar "Some") (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 0.0)))))) (ETuple (EApp (EApp (EVar "percentile") (ELit (LFloat 0.0))) (EListLit (ELit (LFloat 1.0)) (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 0.0))))) (EApp (EApp (EVar "percentile") (ELit (LFloat 100.0))) (EListLit (ELit (LFloat 1.0)) (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 0.0))))))))
(DTest false "percentile interpolates between ranks" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 3.25)))) (EApp (EApp (EVar "percentile") (ELit (LFloat 75.0))) (EListLit (ELit (LFloat 1.0)) (ELit (LFloat 2.0)) (ELit (LFloat 3.0)) (ELit (LFloat 4.0))))))
(DTest false "percentile of a single element is that element" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LFloat 4.0)))) (EApp (EApp (EVar "percentile") (ELit (LFloat 37.0))) (EListLit (ELit (LFloat 4.0))))))
(DTest false "percentile outside 0 to 100 is None" (EApp (EApp (EVar "expectEqual") (EListLit (EVar "None") (EVar "None") (EVar "None"))) (EListLit (EApp (EApp (EVar "percentile") (ELit (LFloat 101.0))) (EListLit (ELit (LFloat 1.0)))) (EApp (EApp (EVar "percentile") (EBinOp "-" (ELit (LFloat 0.0)) (ELit (LFloat 1.0)))) (EListLit (ELit (LFloat 1.0)))) (EApp (EApp (EVar "percentile") (EBinOp "/" (ELit (LFloat 0.0)) (ELit (LFloat 0.0)))) (EListLit (ELit (LFloat 1.0)))))))
(DTest false "percentile of an empty list is None" (EApp (EVar "expectNone") (EApp (EApp (EVar "percentile") (ELit (LFloat 50.0))) (EListLit))))
