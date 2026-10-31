# META
source_lines=444
stages=DESUGAR,MARK
# SOURCE
-- Tests for `stdlib/diff.mdk`: the edit script, and the unified format
-- against what `diff -u` prints for the same files.

import diff.{Edit(..), editScript, unified}
import list.{take}
import string.{concat}
import test.{Expectation, expectEqual, expectEach, expectNotEqual}

row : String -> Int -> String -> String -> String -> (String, Expectation)
row label ctx a b expected =
  (label, expectEqual expected (unified ctx ("A", a) ("B", b)))

-- # The edit script

test "empty, equal and disjoint inputs" = expectEach [
  ("both empty", expectEqual [] (editScript ([] : List Int) [])),
  ("equal", expectEqual [Keep 1, Keep 2] (editScript [1, 2] [1, 2])),
  ("only deletions", expectEqual [Delete 1, Delete 2] (editScript [1, 2] [])),
  ("only insertions", expectEqual [Insert 1, Insert 2] (editScript [] [1, 2])),
  (
    "disjoint: deletions first",
    expectEqual [Delete 1, Delete 2, Insert 3] (editScript [1, 2] [3]),
  ),
]

test "a change is its deletions, then its insertions" = expectEach [
  (
    "replace",
    expectEqual
      [Keep 1, Delete 2, Insert 9, Keep 3]
      (editScript [1, 2, 3] [1, 9, 3]),
  ),
  (
    "swap",
    expectEqual [Delete 1, Keep 2, Insert 1] (editScript [1, 2] [2, 1]),
  ),
  (
    "block",
    expectEqual
      [Keep 0, Delete 1, Delete 2, Insert 7, Insert 8, Insert 9, Keep 5]
      (editScript [0, 1, 2, 5] [0, 7, 8, 9, 5]),
  ),
]

test "the script is shortest on a known case" =
  expectEqual 4 (length (editScript [1, 2, 3, 4, 5, 6] [2, 4, 6, 8]) - 3)

-- # The unified format

test "the measured cases, byte for byte as the diff tool prints them" = expectEach
  [
    row
      "empty to three lines"
      3
      ""
      "a\nb\nc\n"
      "--- A\n+++ B\n@@ -0,0 +1,3 @@\n+a\n+b\n+c\n",
    row
      "three lines to empty"
      3
      "a\nb\nc\n"
      ""
      "--- A\n+++ B\n@@ -1,3 +0,0 @@\n-a\n-b\n-c\n",
    row
      "final newline dropped on the new side"
      3
      "a\nb\nc\n"
      "a\nb\nc"
      "--- A\n+++ B\n@@ -1,3 +1,3 @@\n a\n b\n-c\n+c\n\\ No newline at end of file\n",
    row
      "insertion at the start"
      3
      "a\nb\nc\n"
      "x\na\nb\nc\n"
      "--- A\n+++ B\n@@ -1,3 +1,4 @@\n+x\n a\n b\n c\n",
    row
      "insertion at the end"
      3
      "a\nb\nc\n"
      "a\nb\nc\ny\n"
      "--- A\n+++ B\n@@ -1,3 +1,4 @@\n a\n b\n c\n+y\n",
    row
      "swapped lines, deletion first"
      3
      "a\nb\n"
      "b\na\n"
      "--- A\n+++ B\n@@ -1,2 +1,2 @@\n-a\n b\n+a\n",
    row "equal texts" 3 "a\nb\n" "a\nb\n" "",
  ]

test "a missing final newline" = expectEach [
  row
    "on the old side"
    3
    "a\nb\nc"
    "a\nb\nc\n"
    "--- A\n+++ B\n@@ -1,3 +1,3 @@\n a\n b\n-c\n\\ No newline at end of file\n+c\n",
  row
    "on the old side, last line changed"
    3
    "a\nb\nc"
    "a\nb\nd\n"
    "--- A\n+++ B\n@@ -1,3 +1,3 @@\n a\n b\n-c\n\\ No newline at end of file\n+d\n",
  row
    "on both sides, last line changed"
    3
    "a\nb\nc"
    "a\nb\nd"
    "--- A\n+++ B\n@@ -1,3 +1,3 @@\n a\n b\n-c\n\\ No newline at end of file\n+d\n\\ No newline at end of file\n",
  row "on both sides, equal" 3 "a\nb\nc" "a\nb\nc" "",
  row
    "one line each, only the newline differs"
    3
    "a"
    "a\n"
    "--- A\n+++ B\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+a\n",
  row
    "one line each, different"
    3
    "a"
    "b"
    "--- A\n+++ B\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n",
]

test "single lines and counts of one" = expectEach [
  row "one line replaced" 3 "a\n" "b\n" "--- A\n+++ B\n@@ -1 +1 @@\n-a\n+b\n",
  row
    "one line then two"
    3
    "a\n"
    "a\nb\n"
    "--- A\n+++ B\n@@ -1 +1,2 @@\n a\n+b\n",
  row
    "empty to one unterminated line"
    3
    ""
    "x"
    "--- A\n+++ B\n@@ -0,0 +1 @@\n+x\n\\ No newline at end of file\n",
  row
    "one unterminated line to empty"
    3
    "x"
    ""
    "--- A\n+++ B\n@@ -1 +0,0 @@\n-x\n\\ No newline at end of file\n",
]

test "changes in the middle" = expectEach [
  row
    "one line in the middle"
    3
    "1\n2\n3\n4\n5\n6\n7\n"
    "1\n2\n3\nX\n5\n6\n7\n"
    "--- A\n+++ B\n@@ -1,7 +1,7 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n",
  row
    "deletions then insertions"
    3
    "1\n2\n3\n4\n5\n"
    "1\nA\nB\nC\n5\n"
    "--- A\n+++ B\n@@ -1,5 +1,5 @@\n 1\n-2\n-3\n-4\n+A\n+B\n+C\n 5\n",
  row
    "more deletions than insertions"
    3
    "1\n2\n3\n4\n5\n"
    "1\nA\n5\n"
    "--- A\n+++ B\n@@ -1,5 +1,3 @@\n 1\n-2\n-3\n-4\n+A\n 5\n",
  row
    "pure insertions"
    3
    "1\n5\n"
    "1\nA\nB\nC\n5\n"
    "--- A\n+++ B\n@@ -1,2 +1,5 @@\n 1\n+A\n+B\n+C\n 5\n",
  row
    "CR is content"
    3
    "a\r\nb\r\n"
    "a\r\nc\r\n"
    "--- A\n+++ B\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+c\r\n",
]

test "two changes with a gap between them, context 0" = expectEach [
  row
    "gap 0"
    0
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\nY\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -4,2 +4,2 @@\n-4\n-5\n+X\n+Y\n",
  row
    "gap 1"
    0
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\nY\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -6 +6 @@\n-6\n+Y\n",
  row
    "gap 2"
    0
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\nY\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -7 +7 @@\n-7\n+Y\n",
  row
    "gap 3"
    0
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\nY\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -8 +8 @@\n-8\n+Y\n",
  row
    "gap 4"
    0
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\nY\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -9 +9 @@\n-9\n+Y\n",
  row
    "gap 5"
    0
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\n9\nY\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -10 +10 @@\n-10\n+Y\n",
  row
    "gap 6"
    0
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\nY\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -11 +11 @@\n-11\n+Y\n",
  row
    "gap 7"
    0
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\nY\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -12 +12 @@\n-12\n+Y\n",
  row
    "gap 8"
    0
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\n12\nY\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -13 +13 @@\n-13\n+Y\n",
]

test "two changes with a gap between them, context 1" = expectEach [
  row
    "gap 0"
    1
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\nY\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -3,4 +3,4 @@\n 3\n-4\n-5\n+X\n+Y\n 6\n",
  row
    "gap 1"
    1
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\nY\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -3,5 +3,5 @@\n 3\n-4\n+X\n 5\n-6\n+Y\n 7\n",
  row
    "gap 2"
    1
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\nY\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -3,6 +3,6 @@\n 3\n-4\n+X\n 5\n 6\n-7\n+Y\n 8\n",
  row
    "gap 3"
    1
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\nY\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -7,3 +7,3 @@\n 7\n-8\n+Y\n 9\n",
  row
    "gap 4"
    1
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\nY\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -8,3 +8,3 @@\n 8\n-9\n+Y\n 10\n",
  row
    "gap 5"
    1
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\n9\nY\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -9,3 +9,3 @@\n 9\n-10\n+Y\n 11\n",
  row
    "gap 6"
    1
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\nY\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -10,3 +10,3 @@\n 10\n-11\n+Y\n 12\n",
  row
    "gap 7"
    1
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\nY\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -11,3 +11,3 @@\n 11\n-12\n+Y\n 13\n",
  row
    "gap 8"
    1
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\n12\nY\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -12,3 +12,3 @@\n 12\n-13\n+Y\n 14\n",
]

test "two changes with a gap between them, context 3" = expectEach [
  row
    "gap 0"
    3
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\nY\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -1,8 +1,8 @@\n 1\n 2\n 3\n-4\n-5\n+X\n+Y\n 6\n 7\n 8\n",
  row
    "gap 1"
    3
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\nY\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -1,9 +1,9 @@\n 1\n 2\n 3\n-4\n+X\n 5\n-6\n+Y\n 7\n 8\n 9\n",
  row
    "gap 2"
    3
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\nY\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -1,10 +1,10 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n-7\n+Y\n 8\n 9\n 10\n",
  row
    "gap 3"
    3
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\nY\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -1,11 +1,11 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n-8\n+Y\n 9\n 10\n 11\n",
  row
    "gap 4"
    3
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\nY\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -1,12 +1,12 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n 8\n-9\n+Y\n 10\n 11\n 12\n",
  row
    "gap 5"
    3
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\n9\nY\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -1,13 +1,13 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n 8\n 9\n-10\n+Y\n 11\n 12\n 13\n",
  row
    "gap 6"
    3
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\nY\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -1,14 +1,14 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n 8\n 9\n 10\n-11\n+Y\n 12\n 13\n 14\n",
  row
    "gap 7"
    3
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\nY\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -1,7 +1,7 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n@@ -9,7 +9,7 @@\n 9\n 10\n 11\n-12\n+Y\n 13\n 14\n 15\n",
  row
    "gap 8"
    3
    "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"
    "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\n12\nY\n14\n15\n16\n17\n18\n19\n20\n"
    "--- A\n+++ B\n@@ -1,7 +1,7 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n@@ -10,7 +10,7 @@\n 10\n 11\n 12\n-13\n+Y\n 14\n 15\n 16\n",
]

test "context larger than the file" = expectEach [
  row
    "context 0"
    0
    "1\n2\n3\n4\n5\n"
    "1\n2\nX\n4\n5\n"
    "--- A\n+++ B\n@@ -3 +3 @@\n-3\n+X\n",
  row
    "context 1"
    1
    "1\n2\n3\n4\n5\n"
    "1\n2\nX\n4\n5\n"
    "--- A\n+++ B\n@@ -2,3 +2,3 @@\n 2\n-3\n+X\n 4\n",
  row
    "context 3"
    3
    "1\n2\n3\n4\n5\n"
    "1\n2\nX\n4\n5\n"
    "--- A\n+++ B\n@@ -1,5 +1,5 @@\n 1\n 2\n-3\n+X\n 4\n 5\n",
  row
    "context 100"
    100
    "1\n2\n3\n4\n5\n"
    "1\n2\nX\n4\n5\n"
    "--- A\n+++ B\n@@ -1,5 +1,5 @@\n 1\n 2\n-3\n+X\n 4\n 5\n",
]

-- # Laws

-- Small alphabets make long common subsequences likely.
small : List Int -> List Int
small xs = map (x => if x < 0 then (0 - x) % 3 else x % 3) (take 7 xs)

-- The script read forwards yields the new list, read backwards the old one.
newSide : List (Edit a) -> List a
newSide script = flatMap pickNew script

pickNew : Edit a -> List a
pickNew (Keep x) = [x]
pickNew (Insert x) = [x]
pickNew (Delete _) = []

oldSide : List (Edit a) -> List a
oldSide script = flatMap pickOld script

pickOld : Edit a -> List a
pickOld (Keep x) = [x]
pickOld (Delete x) = [x]
pickOld (Insert _) = []

keeps : List (Edit a) -> Int
keeps script = length (flatMap pickKeep script)

pickKeep : Edit a -> List a
pickKeep (Keep x) = [x]
pickKeep _ = []

-- Length of the longest common subsequence, by the defining recursion.
lcsLength : List Int -> List Int -> Int
lcsLength [] _ = 0
lcsLength _ [] = 0
lcsLength (x :: xs) (y :: ys)
  | x == y = 1 + lcsLength xs ys
  | otherwise = max (lcsLength xs (y :: ys)) (lcsLength (x :: xs) ys)

prop "the new side of the script is the second list" (xs : List Int) (ys : List Int) =
  newSide (editScript (small xs) (small ys)) == small ys

prop "the old side of the script is the first list" (xs : List Int) (ys : List Int) =
  oldSide (editScript (small xs) (small ys)) == small xs

prop "the Keeps are a longest common subsequence" (xs : List Int) (ys : List Int) =
  keeps (editScript (small xs) (small ys)) == lcsLength (small xs) (small ys)

prop "the script has no more edits than the shortest possible" (xs : List Int) (ys : List Int) =
  length (editScript (small xs) (small ys))
    == length (small xs) + length (small ys) - lcsLength (small xs) (small ys)

-- Lines for the text laws: one letter per element, each ended by LF.
textOf : List Int -> String
textOf xs = concat (map (x => "\{x}\n") (small xs))

prop "unified is empty exactly when the texts are equal" (xs : List Int) (ys : List Int) =
  unified 2 ("A", textOf xs) ("B", textOf ys) == "" == (small xs == small ys)

test "unified is empty for equal texts, including ones without a final newline" = expectEach
  [
    ("with", expectEqual "" (unified 3 ("A", "a\nb\n") ("B", "a\nb\n"))),
    ("without", expectEqual "" (unified 3 ("A", "a\nb") ("B", "a\nb"))),
    ("empty", expectEqual "" (unified 3 ("A", "") ("B", ""))),
  ]

test "texts that differ only in the final newline are not equal" =
  expectNotEqual "" (unified 3 ("A", "a") ("B", "a\n"))
# DESUGAR
(DUse false (UseGroup ("diff") ((mem "Edit" true) (mem "editScript" false) (mem "unified" false))))
(DUse false (UseGroup ("list") ((mem "take" false))))
(DUse false (UseGroup ("string") ((mem "concat" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false) (mem "expectEach" false) (mem "expectNotEqual" false))))
(DTypeSig false "row" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Expectation"))))))))
(DFunDef false "row" ((PVar "label") (PVar "ctx") (PVar "a") (PVar "b") (PVar "expected")) (ETuple (EVar "label") (EApp (EApp (EVar "expectEqual") (EVar "expected")) (EApp (EApp (EApp (EVar "unified") (EVar "ctx")) (ETuple (ELit (LString "A")) (EVar "a"))) (ETuple (ELit (LString "B")) (EVar "b"))))))
(DTest false "empty, equal and disjoint inputs" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "both empty")) (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EApp (EVar "editScript") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EListLit)))) (ETuple (ELit (LString "equal")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Keep") (ELit (LInt 1))) (EApp (EVar "Keep") (ELit (LInt 2))))) (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)))))) (ETuple (ELit (LString "only deletions")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Delete") (ELit (LInt 1))) (EApp (EVar "Delete") (ELit (LInt 2))))) (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (EListLit)))) (ETuple (ELit (LString "only insertions")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Insert") (ELit (LInt 1))) (EApp (EVar "Insert") (ELit (LInt 2))))) (EApp (EApp (EVar "editScript") (EListLit)) (EListLit (ELit (LInt 1)) (ELit (LInt 2)))))) (ETuple (ELit (LString "disjoint: deletions first")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Delete") (ELit (LInt 1))) (EApp (EVar "Delete") (ELit (LInt 2))) (EApp (EVar "Insert") (ELit (LInt 3))))) (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (EListLit (ELit (LInt 3)))))))))
(DTest false "a change is its deletions, then its insertions" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "replace")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Keep") (ELit (LInt 1))) (EApp (EVar "Delete") (ELit (LInt 2))) (EApp (EVar "Insert") (ELit (LInt 9))) (EApp (EVar "Keep") (ELit (LInt 3))))) (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (EListLit (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 3)))))) (ETuple (ELit (LString "swap")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Delete") (ELit (LInt 1))) (EApp (EVar "Keep") (ELit (LInt 2))) (EApp (EVar "Insert") (ELit (LInt 1))))) (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (EListLit (ELit (LInt 2)) (ELit (LInt 1)))))) (ETuple (ELit (LString "block")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Keep") (ELit (LInt 0))) (EApp (EVar "Delete") (ELit (LInt 1))) (EApp (EVar "Delete") (ELit (LInt 2))) (EApp (EVar "Insert") (ELit (LInt 7))) (EApp (EVar "Insert") (ELit (LInt 8))) (EApp (EVar "Insert") (ELit (LInt 9))) (EApp (EVar "Keep") (ELit (LInt 5))))) (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 0)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 5)))) (EListLit (ELit (LInt 0)) (ELit (LInt 7)) (ELit (LInt 8)) (ELit (LInt 9)) (ELit (LInt 5)))))))))
(DTest false "the script is shortest on a known case" (EApp (EApp (EVar "expectEqual") (ELit (LInt 4))) (EBinOp "-" (EApp (EVar "length") (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)))) (EListLit (ELit (LInt 2)) (ELit (LInt 4)) (ELit (LInt 6)) (ELit (LInt 8))))) (ELit (LInt 3)))))
(DTest false "the measured cases, byte for byte as the diff tool prints them" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "empty to three lines"))) (ELit (LInt 3))) (ELit (LString ""))) (ELit (LString "a\nb\nc\n"))) (ELit (LString "--- A\n+++ B\n@@ -0,0 +1,3 @@\n+a\n+b\n+c\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "three lines to empty"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc\n"))) (ELit (LString ""))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +0,0 @@\n-a\n-b\n-c\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "final newline dropped on the new side"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc\n"))) (ELit (LString "a\nb\nc"))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +1,3 @@\n a\n b\n-c\n+c\n\\ No newline at end of file\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "insertion at the start"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc\n"))) (ELit (LString "x\na\nb\nc\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +1,4 @@\n+x\n a\n b\n c\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "insertion at the end"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc\n"))) (ELit (LString "a\nb\nc\ny\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +1,4 @@\n a\n b\n c\n+y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "swapped lines, deletion first"))) (ELit (LInt 3))) (ELit (LString "a\nb\n"))) (ELit (LString "b\na\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,2 +1,2 @@\n-a\n b\n+a\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "equal texts"))) (ELit (LInt 3))) (ELit (LString "a\nb\n"))) (ELit (LString "a\nb\n"))) (ELit (LString ""))))))
(DTest false "a missing final newline" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "on the old side"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc"))) (ELit (LString "a\nb\nc\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +1,3 @@\n a\n b\n-c\n\\ No newline at end of file\n+c\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "on the old side, last line changed"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc"))) (ELit (LString "a\nb\nd\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +1,3 @@\n a\n b\n-c\n\\ No newline at end of file\n+d\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "on both sides, last line changed"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc"))) (ELit (LString "a\nb\nd"))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +1,3 @@\n a\n b\n-c\n\\ No newline at end of file\n+d\n\\ No newline at end of file\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "on both sides, equal"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc"))) (ELit (LString "a\nb\nc"))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "one line each, only the newline differs"))) (ELit (LInt 3))) (ELit (LString "a"))) (ELit (LString "a\n"))) (ELit (LString "--- A\n+++ B\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+a\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "one line each, different"))) (ELit (LInt 3))) (ELit (LString "a"))) (ELit (LString "b"))) (ELit (LString "--- A\n+++ B\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n"))))))
(DTest false "single lines and counts of one" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "one line replaced"))) (ELit (LInt 3))) (ELit (LString "a\n"))) (ELit (LString "b\n"))) (ELit (LString "--- A\n+++ B\n@@ -1 +1 @@\n-a\n+b\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "one line then two"))) (ELit (LInt 3))) (ELit (LString "a\n"))) (ELit (LString "a\nb\n"))) (ELit (LString "--- A\n+++ B\n@@ -1 +1,2 @@\n a\n+b\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "empty to one unterminated line"))) (ELit (LInt 3))) (ELit (LString ""))) (ELit (LString "x"))) (ELit (LString "--- A\n+++ B\n@@ -0,0 +1 @@\n+x\n\\ No newline at end of file\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "one unterminated line to empty"))) (ELit (LInt 3))) (ELit (LString "x"))) (ELit (LString ""))) (ELit (LString "--- A\n+++ B\n@@ -1 +0,0 @@\n-x\n\\ No newline at end of file\n"))))))
(DTest false "changes in the middle" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "one line in the middle"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,7 +1,7 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "deletions then insertions"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n"))) (ELit (LString "1\nA\nB\nC\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,5 +1,5 @@\n 1\n-2\n-3\n-4\n+A\n+B\n+C\n 5\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "more deletions than insertions"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n"))) (ELit (LString "1\nA\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,5 +1,3 @@\n 1\n-2\n-3\n-4\n+A\n 5\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "pure insertions"))) (ELit (LInt 3))) (ELit (LString "1\n5\n"))) (ELit (LString "1\nA\nB\nC\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,2 +1,5 @@\n 1\n+A\n+B\n+C\n 5\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "CR is content"))) (ELit (LInt 3))) (ELit (LString "a\r\nb\r\n"))) (ELit (LString "a\r\nc\r\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+c\r\n"))))))
(DTest false "two changes with a gap between them, context 0" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 0"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\nY\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4,2 +4,2 @@\n-4\n-5\n+X\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 1"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\nY\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -6 +6 @@\n-6\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 2"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\nY\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -7 +7 @@\n-7\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 3"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\nY\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -8 +8 @@\n-8\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 4"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\nY\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -9 +9 @@\n-9\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 5"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\nY\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -10 +10 @@\n-10\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 6"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\nY\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -11 +11 @@\n-11\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 7"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\nY\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -12 +12 @@\n-12\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 8"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\n12\nY\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -13 +13 @@\n-13\n+Y\n"))))))
(DTest false "two changes with a gap between them, context 1" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 0"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\nY\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,4 +3,4 @@\n 3\n-4\n-5\n+X\n+Y\n 6\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 1"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\nY\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,5 +3,5 @@\n 3\n-4\n+X\n 5\n-6\n+Y\n 7\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 2"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\nY\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,6 +3,6 @@\n 3\n-4\n+X\n 5\n 6\n-7\n+Y\n 8\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 3"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\nY\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -7,3 +7,3 @@\n 7\n-8\n+Y\n 9\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 4"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\nY\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -8,3 +8,3 @@\n 8\n-9\n+Y\n 10\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 5"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\nY\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -9,3 +9,3 @@\n 9\n-10\n+Y\n 11\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 6"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\nY\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -10,3 +10,3 @@\n 10\n-11\n+Y\n 12\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 7"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\nY\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -11,3 +11,3 @@\n 11\n-12\n+Y\n 13\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 8"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\n12\nY\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -12,3 +12,3 @@\n 12\n-13\n+Y\n 14\n"))))))
(DTest false "two changes with a gap between them, context 3" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 0"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\nY\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,8 +1,8 @@\n 1\n 2\n 3\n-4\n-5\n+X\n+Y\n 6\n 7\n 8\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 1"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\nY\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,9 +1,9 @@\n 1\n 2\n 3\n-4\n+X\n 5\n-6\n+Y\n 7\n 8\n 9\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 2"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\nY\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,10 +1,10 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n-7\n+Y\n 8\n 9\n 10\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 3"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\nY\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,11 +1,11 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n-8\n+Y\n 9\n 10\n 11\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 4"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\nY\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,12 +1,12 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n 8\n-9\n+Y\n 10\n 11\n 12\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 5"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\nY\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,13 +1,13 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n 8\n 9\n-10\n+Y\n 11\n 12\n 13\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 6"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\nY\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,14 +1,14 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n 8\n 9\n 10\n-11\n+Y\n 12\n 13\n 14\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 7"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\nY\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,7 +1,7 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n@@ -9,7 +9,7 @@\n 9\n 10\n 11\n-12\n+Y\n 13\n 14\n 15\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 8"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\n12\nY\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,7 +1,7 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n@@ -10,7 +10,7 @@\n 10\n 11\n 12\n-13\n+Y\n 14\n 15\n 16\n"))))))
(DTest false "context larger than the file" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "context 0"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n"))) (ELit (LString "1\n2\nX\n4\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -3 +3 @@\n-3\n+X\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "context 1"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n"))) (ELit (LString "1\n2\nX\n4\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -2,3 +2,3 @@\n 2\n-3\n+X\n 4\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "context 3"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n"))) (ELit (LString "1\n2\nX\n4\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,5 +1,5 @@\n 1\n 2\n-3\n+X\n 4\n 5\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "context 100"))) (ELit (LInt 100))) (ELit (LString "1\n2\n3\n4\n5\n"))) (ELit (LString "1\n2\nX\n4\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,5 +1,5 @@\n 1\n 2\n-3\n+X\n 4\n 5\n"))))))
(DTypeSig false "small" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "small" ((PVar "xs")) (EApp (EApp (EVar "map") (ELam ((PVar "x")) (EIf (EBinOp "<" (EVar "x") (ELit (LInt 0))) (EBinOp "%" (EBinOp "-" (ELit (LInt 0)) (EVar "x")) (ELit (LInt 3))) (EBinOp "%" (EVar "x") (ELit (LInt 3)))))) (EApp (EApp (EVar "take") (ELit (LInt 7))) (EVar "xs"))))
(DTypeSig false "newSide" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "newSide" ((PVar "script")) (EApp (EApp (EVar "flatMap") (EVar "pickNew")) (EVar "script")))
(DTypeSig false "pickNew" (TyFun (TyApp (TyCon "Edit") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "pickNew" ((PCon "Keep" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "pickNew" ((PCon "Insert" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "pickNew" ((PCon "Delete" PWild)) (EListLit))
(DTypeSig false "oldSide" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "oldSide" ((PVar "script")) (EApp (EApp (EVar "flatMap") (EVar "pickOld")) (EVar "script")))
(DTypeSig false "pickOld" (TyFun (TyApp (TyCon "Edit") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "pickOld" ((PCon "Keep" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "pickOld" ((PCon "Delete" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "pickOld" ((PCon "Insert" PWild)) (EListLit))
(DTypeSig false "keeps" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyCon "Int")))
(DFunDef false "keeps" ((PVar "script")) (EApp (EVar "length") (EApp (EApp (EVar "flatMap") (EVar "pickKeep")) (EVar "script"))))
(DTypeSig false "pickKeep" (TyFun (TyApp (TyCon "Edit") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "pickKeep" ((PCon "Keep" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "pickKeep" (PWild) (EListLit))
(DTypeSig false "lcsLength" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "lcsLength" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "lcsLength" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "lcsLength" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "lcsLength") (EVar "xs")) (EVar "ys"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "max") (EApp (EApp (EVar "lcsLength") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EApp (EApp (EVar "lcsLength") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DProp false "the new side of the script is the second list" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EVar "newSide") (EApp (EApp (EVar "editScript") (EApp (EVar "small") (EVar "xs"))) (EApp (EVar "small") (EVar "ys")))) (EApp (EVar "small") (EVar "ys"))))
(DProp false "the old side of the script is the first list" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EVar "oldSide") (EApp (EApp (EVar "editScript") (EApp (EVar "small") (EVar "xs"))) (EApp (EVar "small") (EVar "ys")))) (EApp (EVar "small") (EVar "xs"))))
(DProp false "the Keeps are a longest common subsequence" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EVar "keeps") (EApp (EApp (EVar "editScript") (EApp (EVar "small") (EVar "xs"))) (EApp (EVar "small") (EVar "ys")))) (EApp (EApp (EVar "lcsLength") (EApp (EVar "small") (EVar "xs"))) (EApp (EVar "small") (EVar "ys")))))
(DProp false "the script has no more edits than the shortest possible" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EVar "length") (EApp (EApp (EVar "editScript") (EApp (EVar "small") (EVar "xs"))) (EApp (EVar "small") (EVar "ys")))) (EBinOp "-" (EBinOp "+" (EApp (EVar "length") (EApp (EVar "small") (EVar "xs"))) (EApp (EVar "length") (EApp (EVar "small") (EVar "ys")))) (EApp (EApp (EVar "lcsLength") (EApp (EVar "small") (EVar "xs"))) (EApp (EVar "small") (EVar "ys"))))))
(DTypeSig false "textOf" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "String")))
(DFunDef false "textOf" ((PVar "xs")) (EApp (EVar "concat") (EApp (EApp (EVar "map") (ELam ((PVar "x")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "\n"))))) (EApp (EVar "small") (EVar "xs")))))
(DProp false "unified is empty exactly when the texts are equal" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EBinOp "==" (EApp (EApp (EApp (EVar "unified") (ELit (LInt 2))) (ETuple (ELit (LString "A")) (EApp (EVar "textOf") (EVar "xs")))) (ETuple (ELit (LString "B")) (EApp (EVar "textOf") (EVar "ys")))) (ELit (LString ""))) (EBinOp "==" (EApp (EVar "small") (EVar "xs")) (EApp (EVar "small") (EVar "ys")))))
(DTest false "unified is empty for equal texts, including ones without a final newline" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "with")) (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EApp (EVar "unified") (ELit (LInt 3))) (ETuple (ELit (LString "A")) (ELit (LString "a\nb\n")))) (ETuple (ELit (LString "B")) (ELit (LString "a\nb\n")))))) (ETuple (ELit (LString "without")) (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EApp (EVar "unified") (ELit (LInt 3))) (ETuple (ELit (LString "A")) (ELit (LString "a\nb")))) (ETuple (ELit (LString "B")) (ELit (LString "a\nb")))))) (ETuple (ELit (LString "empty")) (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EApp (EVar "unified") (ELit (LInt 3))) (ETuple (ELit (LString "A")) (ELit (LString "")))) (ETuple (ELit (LString "B")) (ELit (LString "")))))))))
(DTest false "texts that differ only in the final newline are not equal" (EApp (EApp (EVar "expectNotEqual") (ELit (LString ""))) (EApp (EApp (EApp (EVar "unified") (ELit (LInt 3))) (ETuple (ELit (LString "A")) (ELit (LString "a")))) (ETuple (ELit (LString "B")) (ELit (LString "a\n"))))))
# MARK
(DUse false (UseGroup ("diff") ((mem "Edit" true) (mem "editScript" false) (mem "unified" false))))
(DUse false (UseGroup ("list") ((mem "take" false))))
(DUse false (UseGroup ("string") ((mem "concat" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false) (mem "expectEach" false) (mem "expectNotEqual" false))))
(DTypeSig false "row" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Expectation"))))))))
(DFunDef false "row" ((PVar "label") (PVar "ctx") (PVar "a") (PVar "b") (PVar "expected")) (ETuple (EVar "label") (EApp (EApp (EVar "expectEqual") (EVar "expected")) (EApp (EApp (EApp (EVar "unified") (EVar "ctx")) (ETuple (ELit (LString "A")) (EVar "a"))) (ETuple (ELit (LString "B")) (EVar "b"))))))
(DTest false "empty, equal and disjoint inputs" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "both empty")) (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EApp (EVar "editScript") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))) (EListLit)))) (ETuple (ELit (LString "equal")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Keep") (ELit (LInt 1))) (EApp (EVar "Keep") (ELit (LInt 2))))) (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (EListLit (ELit (LInt 1)) (ELit (LInt 2)))))) (ETuple (ELit (LString "only deletions")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Delete") (ELit (LInt 1))) (EApp (EVar "Delete") (ELit (LInt 2))))) (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (EListLit)))) (ETuple (ELit (LString "only insertions")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Insert") (ELit (LInt 1))) (EApp (EVar "Insert") (ELit (LInt 2))))) (EApp (EApp (EVar "editScript") (EListLit)) (EListLit (ELit (LInt 1)) (ELit (LInt 2)))))) (ETuple (ELit (LString "disjoint: deletions first")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Delete") (ELit (LInt 1))) (EApp (EVar "Delete") (ELit (LInt 2))) (EApp (EVar "Insert") (ELit (LInt 3))))) (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (EListLit (ELit (LInt 3)))))))))
(DTest false "a change is its deletions, then its insertions" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "replace")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Keep") (ELit (LInt 1))) (EApp (EVar "Delete") (ELit (LInt 2))) (EApp (EVar "Insert") (ELit (LInt 9))) (EApp (EVar "Keep") (ELit (LInt 3))))) (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (EListLit (ELit (LInt 1)) (ELit (LInt 9)) (ELit (LInt 3)))))) (ETuple (ELit (LString "swap")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Delete") (ELit (LInt 1))) (EApp (EVar "Keep") (ELit (LInt 2))) (EApp (EVar "Insert") (ELit (LInt 1))))) (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (EListLit (ELit (LInt 2)) (ELit (LInt 1)))))) (ETuple (ELit (LString "block")) (EApp (EApp (EVar "expectEqual") (EListLit (EApp (EVar "Keep") (ELit (LInt 0))) (EApp (EVar "Delete") (ELit (LInt 1))) (EApp (EVar "Delete") (ELit (LInt 2))) (EApp (EVar "Insert") (ELit (LInt 7))) (EApp (EVar "Insert") (ELit (LInt 8))) (EApp (EVar "Insert") (ELit (LInt 9))) (EApp (EVar "Keep") (ELit (LInt 5))))) (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 0)) (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 5)))) (EListLit (ELit (LInt 0)) (ELit (LInt 7)) (ELit (LInt 8)) (ELit (LInt 9)) (ELit (LInt 5)))))))))
(DTest false "the script is shortest on a known case" (EApp (EApp (EVar "expectEqual") (ELit (LInt 4))) (EBinOp "-" (EApp (EMethodRef "length") (EApp (EApp (EVar "editScript") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)))) (EListLit (ELit (LInt 2)) (ELit (LInt 4)) (ELit (LInt 6)) (ELit (LInt 8))))) (ELit (LInt 3)))))
(DTest false "the measured cases, byte for byte as the diff tool prints them" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "empty to three lines"))) (ELit (LInt 3))) (ELit (LString ""))) (ELit (LString "a\nb\nc\n"))) (ELit (LString "--- A\n+++ B\n@@ -0,0 +1,3 @@\n+a\n+b\n+c\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "three lines to empty"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc\n"))) (ELit (LString ""))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +0,0 @@\n-a\n-b\n-c\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "final newline dropped on the new side"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc\n"))) (ELit (LString "a\nb\nc"))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +1,3 @@\n a\n b\n-c\n+c\n\\ No newline at end of file\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "insertion at the start"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc\n"))) (ELit (LString "x\na\nb\nc\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +1,4 @@\n+x\n a\n b\n c\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "insertion at the end"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc\n"))) (ELit (LString "a\nb\nc\ny\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +1,4 @@\n a\n b\n c\n+y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "swapped lines, deletion first"))) (ELit (LInt 3))) (ELit (LString "a\nb\n"))) (ELit (LString "b\na\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,2 +1,2 @@\n-a\n b\n+a\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "equal texts"))) (ELit (LInt 3))) (ELit (LString "a\nb\n"))) (ELit (LString "a\nb\n"))) (ELit (LString ""))))))
(DTest false "a missing final newline" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "on the old side"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc"))) (ELit (LString "a\nb\nc\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +1,3 @@\n a\n b\n-c\n\\ No newline at end of file\n+c\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "on the old side, last line changed"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc"))) (ELit (LString "a\nb\nd\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +1,3 @@\n a\n b\n-c\n\\ No newline at end of file\n+d\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "on both sides, last line changed"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc"))) (ELit (LString "a\nb\nd"))) (ELit (LString "--- A\n+++ B\n@@ -1,3 +1,3 @@\n a\n b\n-c\n\\ No newline at end of file\n+d\n\\ No newline at end of file\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "on both sides, equal"))) (ELit (LInt 3))) (ELit (LString "a\nb\nc"))) (ELit (LString "a\nb\nc"))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "one line each, only the newline differs"))) (ELit (LInt 3))) (ELit (LString "a"))) (ELit (LString "a\n"))) (ELit (LString "--- A\n+++ B\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+a\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "one line each, different"))) (ELit (LInt 3))) (ELit (LString "a"))) (ELit (LString "b"))) (ELit (LString "--- A\n+++ B\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n"))))))
(DTest false "single lines and counts of one" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "one line replaced"))) (ELit (LInt 3))) (ELit (LString "a\n"))) (ELit (LString "b\n"))) (ELit (LString "--- A\n+++ B\n@@ -1 +1 @@\n-a\n+b\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "one line then two"))) (ELit (LInt 3))) (ELit (LString "a\n"))) (ELit (LString "a\nb\n"))) (ELit (LString "--- A\n+++ B\n@@ -1 +1,2 @@\n a\n+b\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "empty to one unterminated line"))) (ELit (LInt 3))) (ELit (LString ""))) (ELit (LString "x"))) (ELit (LString "--- A\n+++ B\n@@ -0,0 +1 @@\n+x\n\\ No newline at end of file\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "one unterminated line to empty"))) (ELit (LInt 3))) (ELit (LString "x"))) (ELit (LString ""))) (ELit (LString "--- A\n+++ B\n@@ -1 +0,0 @@\n-x\n\\ No newline at end of file\n"))))))
(DTest false "changes in the middle" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "one line in the middle"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,7 +1,7 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "deletions then insertions"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n"))) (ELit (LString "1\nA\nB\nC\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,5 +1,5 @@\n 1\n-2\n-3\n-4\n+A\n+B\n+C\n 5\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "more deletions than insertions"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n"))) (ELit (LString "1\nA\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,5 +1,3 @@\n 1\n-2\n-3\n-4\n+A\n 5\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "pure insertions"))) (ELit (LInt 3))) (ELit (LString "1\n5\n"))) (ELit (LString "1\nA\nB\nC\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,2 +1,5 @@\n 1\n+A\n+B\n+C\n 5\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "CR is content"))) (ELit (LInt 3))) (ELit (LString "a\r\nb\r\n"))) (ELit (LString "a\r\nc\r\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+c\r\n"))))))
(DTest false "two changes with a gap between them, context 0" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 0"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\nY\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4,2 +4,2 @@\n-4\n-5\n+X\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 1"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\nY\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -6 +6 @@\n-6\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 2"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\nY\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -7 +7 @@\n-7\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 3"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\nY\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -8 +8 @@\n-8\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 4"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\nY\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -9 +9 @@\n-9\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 5"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\nY\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -10 +10 @@\n-10\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 6"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\nY\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -11 +11 @@\n-11\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 7"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\nY\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -12 +12 @@\n-12\n+Y\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 8"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\n12\nY\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -4 +4 @@\n-4\n+X\n@@ -13 +13 @@\n-13\n+Y\n"))))))
(DTest false "two changes with a gap between them, context 1" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 0"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\nY\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,4 +3,4 @@\n 3\n-4\n-5\n+X\n+Y\n 6\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 1"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\nY\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,5 +3,5 @@\n 3\n-4\n+X\n 5\n-6\n+Y\n 7\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 2"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\nY\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,6 +3,6 @@\n 3\n-4\n+X\n 5\n 6\n-7\n+Y\n 8\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 3"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\nY\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -7,3 +7,3 @@\n 7\n-8\n+Y\n 9\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 4"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\nY\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -8,3 +8,3 @@\n 8\n-9\n+Y\n 10\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 5"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\nY\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -9,3 +9,3 @@\n 9\n-10\n+Y\n 11\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 6"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\nY\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -10,3 +10,3 @@\n 10\n-11\n+Y\n 12\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 7"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\nY\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -11,3 +11,3 @@\n 11\n-12\n+Y\n 13\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 8"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\n12\nY\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -3,3 +3,3 @@\n 3\n-4\n+X\n 5\n@@ -12,3 +12,3 @@\n 12\n-13\n+Y\n 14\n"))))))
(DTest false "two changes with a gap between them, context 3" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 0"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\nY\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,8 +1,8 @@\n 1\n 2\n 3\n-4\n-5\n+X\n+Y\n 6\n 7\n 8\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 1"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\nY\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,9 +1,9 @@\n 1\n 2\n 3\n-4\n+X\n 5\n-6\n+Y\n 7\n 8\n 9\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 2"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\nY\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,10 +1,10 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n-7\n+Y\n 8\n 9\n 10\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 3"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\nY\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,11 +1,11 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n-8\n+Y\n 9\n 10\n 11\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 4"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\nY\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,12 +1,12 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n 8\n-9\n+Y\n 10\n 11\n 12\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 5"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\nY\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,13 +1,13 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n 8\n 9\n-10\n+Y\n 11\n 12\n 13\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 6"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\nY\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,14 +1,14 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n 8\n 9\n 10\n-11\n+Y\n 12\n 13\n 14\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 7"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\nY\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,7 +1,7 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n@@ -9,7 +9,7 @@\n 9\n 10\n 11\n-12\n+Y\n 13\n 14\n 15\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "gap 8"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "1\n2\n3\nX\n5\n6\n7\n8\n9\n10\n11\n12\nY\n14\n15\n16\n17\n18\n19\n20\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,7 +1,7 @@\n 1\n 2\n 3\n-4\n+X\n 5\n 6\n 7\n@@ -10,7 +10,7 @@\n 10\n 11\n 12\n-13\n+Y\n 14\n 15\n 16\n"))))))
(DTest false "context larger than the file" (EApp (EVar "expectEach") (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "context 0"))) (ELit (LInt 0))) (ELit (LString "1\n2\n3\n4\n5\n"))) (ELit (LString "1\n2\nX\n4\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -3 +3 @@\n-3\n+X\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "context 1"))) (ELit (LInt 1))) (ELit (LString "1\n2\n3\n4\n5\n"))) (ELit (LString "1\n2\nX\n4\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -2,3 +2,3 @@\n 2\n-3\n+X\n 4\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "context 3"))) (ELit (LInt 3))) (ELit (LString "1\n2\n3\n4\n5\n"))) (ELit (LString "1\n2\nX\n4\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,5 +1,5 @@\n 1\n 2\n-3\n+X\n 4\n 5\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "row") (ELit (LString "context 100"))) (ELit (LInt 100))) (ELit (LString "1\n2\n3\n4\n5\n"))) (ELit (LString "1\n2\nX\n4\n5\n"))) (ELit (LString "--- A\n+++ B\n@@ -1,5 +1,5 @@\n 1\n 2\n-3\n+X\n 4\n 5\n"))))))
(DTypeSig false "small" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "small" ((PVar "xs")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (EIf (EBinOp "<" (EVar "x") (ELit (LInt 0))) (EBinOp "%" (EBinOp "-" (ELit (LInt 0)) (EVar "x")) (ELit (LInt 3))) (EBinOp "%" (EVar "x") (ELit (LInt 3)))))) (EApp (EApp (EVar "take") (ELit (LInt 7))) (EVar "xs"))))
(DTypeSig false "newSide" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "newSide" ((PVar "script")) (EApp (EApp (EDictApp "flatMap") (EVar "pickNew")) (EVar "script")))
(DTypeSig false "pickNew" (TyFun (TyApp (TyCon "Edit") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "pickNew" ((PCon "Keep" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "pickNew" ((PCon "Insert" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "pickNew" ((PCon "Delete" PWild)) (EListLit))
(DTypeSig false "oldSide" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "oldSide" ((PVar "script")) (EApp (EApp (EDictApp "flatMap") (EVar "pickOld")) (EVar "script")))
(DTypeSig false "pickOld" (TyFun (TyApp (TyCon "Edit") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "pickOld" ((PCon "Keep" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "pickOld" ((PCon "Delete" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "pickOld" ((PCon "Insert" PWild)) (EListLit))
(DTypeSig false "keeps" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Edit") (TyVar "a"))) (TyCon "Int")))
(DFunDef false "keeps" ((PVar "script")) (EApp (EMethodRef "length") (EApp (EApp (EDictApp "flatMap") (EVar "pickKeep")) (EVar "script"))))
(DTypeSig false "pickKeep" (TyFun (TyApp (TyCon "Edit") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "pickKeep" ((PCon "Keep" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "pickKeep" (PWild) (EListLit))
(DTypeSig false "lcsLength" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "lcsLength" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "lcsLength" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "lcsLength" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "lcsLength") (EVar "xs")) (EVar "ys"))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "max") (EApp (EApp (EVar "lcsLength") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EApp (EApp (EVar "lcsLength") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DProp false "the new side of the script is the second list" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EVar "newSide") (EApp (EApp (EVar "editScript") (EApp (EVar "small") (EVar "xs"))) (EApp (EVar "small") (EVar "ys")))) (EApp (EVar "small") (EVar "ys"))))
(DProp false "the old side of the script is the first list" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EVar "oldSide") (EApp (EApp (EVar "editScript") (EApp (EVar "small") (EVar "xs"))) (EApp (EVar "small") (EVar "ys")))) (EApp (EVar "small") (EVar "xs"))))
(DProp false "the Keeps are a longest common subsequence" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EVar "keeps") (EApp (EApp (EVar "editScript") (EApp (EVar "small") (EVar "xs"))) (EApp (EVar "small") (EVar "ys")))) (EApp (EApp (EVar "lcsLength") (EApp (EVar "small") (EVar "xs"))) (EApp (EVar "small") (EVar "ys")))))
(DProp false "the script has no more edits than the shortest possible" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EMethodRef "length") (EApp (EApp (EVar "editScript") (EApp (EVar "small") (EVar "xs"))) (EApp (EVar "small") (EVar "ys")))) (EBinOp "-" (EBinOp "+" (EApp (EMethodRef "length") (EApp (EVar "small") (EVar "xs"))) (EApp (EMethodRef "length") (EApp (EVar "small") (EVar "ys")))) (EApp (EApp (EVar "lcsLength") (EApp (EVar "small") (EVar "xs"))) (EApp (EVar "small") (EVar "ys"))))))
(DTypeSig false "textOf" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "String")))
(DFunDef false "textOf" ((PVar "xs")) (EApp (EVar "concat") (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "\n"))))) (EApp (EVar "small") (EVar "xs")))))
(DProp false "unified is empty exactly when the texts are equal" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EBinOp "==" (EApp (EApp (EApp (EVar "unified") (ELit (LInt 2))) (ETuple (ELit (LString "A")) (EApp (EVar "textOf") (EVar "xs")))) (ETuple (ELit (LString "B")) (EApp (EVar "textOf") (EVar "ys")))) (ELit (LString ""))) (EBinOp "==" (EApp (EVar "small") (EVar "xs")) (EApp (EVar "small") (EVar "ys")))))
(DTest false "unified is empty for equal texts, including ones without a final newline" (EApp (EVar "expectEach") (EListLit (ETuple (ELit (LString "with")) (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EApp (EVar "unified") (ELit (LInt 3))) (ETuple (ELit (LString "A")) (ELit (LString "a\nb\n")))) (ETuple (ELit (LString "B")) (ELit (LString "a\nb\n")))))) (ETuple (ELit (LString "without")) (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EApp (EVar "unified") (ELit (LInt 3))) (ETuple (ELit (LString "A")) (ELit (LString "a\nb")))) (ETuple (ELit (LString "B")) (ELit (LString "a\nb")))))) (ETuple (ELit (LString "empty")) (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EApp (EVar "unified") (ELit (LInt 3))) (ETuple (ELit (LString "A")) (ELit (LString "")))) (ETuple (ELit (LString "B")) (ELit (LString "")))))))))
(DTest false "texts that differ only in the final newline are not equal" (EApp (EApp (EVar "expectNotEqual") (ELit (LString ""))) (EApp (EApp (EApp (EVar "unified") (ELit (LInt 3))) (ETuple (ELit (LString "A")) (ELit (LString "a")))) (ETuple (ELit (LString "B")) (ELit (LString "a\n"))))))
