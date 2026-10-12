# META
source_lines=71
stages=DESUGAR,MARK
# SOURCE
-- Tests for the substring search and replace functions in `stdlib/string.mdk`.
--
-- Positions are codepoint indices, so the multibyte cases below are where a
-- byte offset would show.

import string.{countOccurrences, indexOf, lastIndexOf, replaceAll}
import test.{expectEqual}

-- # Fixed cases

test "lastIndexOf finds overlapping occurrences" =
  expectEqual (Some 1) (lastIndexOf "aa" "aaa")

test "lastIndexOf counts codepoints, not bytes" =
  expectEqual (Some 2) (lastIndexOf "é" "éaé")

test "lastIndexOf of an empty needle is the end of the string" =
  expectEqual (Some 5) (lastIndexOf "" "héllo")

test "lastIndexOf of an absent needle is None" =
  expectEqual None (lastIndexOf "z" "hello")

test "countOccurrences does not count overlaps" =
  expectEqual 2 (countOccurrences "aa" "aaaaa")

test "countOccurrences of an absent needle is 0" =
  expectEqual 0 (countOccurrences "z" "hello")

test "replaceAll replaces non-overlapping occurrences left to right" =
  expectEqual "bba" (replaceAll "aa" "b" "aaaaa")

test "replaceAll handles multibyte needles" =
  expectEqual "-a-" (replaceAll "日" "-" "日a日")

test "replaceAll with an absent needle leaves the string alone" =
  expectEqual "hello" (replaceAll "z" "y" "hello")

test "replaceAll can delete" = expectEqual "hllo" (replaceAll "e" "" "hello")

-- # Slicing

test "stringSlice takes the codepoints in a half-open range" =
  expectEqual "cd" (stringSlice 2 4 "abcdef")

test "stringSlice counts codepoints, not bytes" =
  expectEqual "él" (stringSlice 1 3 "héllo")

test "stringSlice of a wide-character tail" =
  expectEqual "本語" (stringSlice 1 3 "日本語")

test "stringSlice clamps both ends to the string" =
  expectEqual "ab" (stringSlice (0 - 2) 2 "abc")

test "stringSlice past the end is empty" =
  expectEqual "" (stringSlice 4 99 "abc")

test "stringSlice with the end before the start is empty" =
  expectEqual "" (stringSlice 2 1 "abc")

-- # Properties

prop "countOccurrences agrees with replaceAll on the removed length" (s : String) =
  stringLength s - stringLength (replaceAll "ab" "" s)
    == 2 * countOccurrences "ab" s

prop "lastIndexOf hit is an occurrence and no later one exists" (s : String) =
  match lastIndexOf "ab" s
    None => countOccurrences "ab" s == 0
    Some i =>
      stringSlice i (i + 2) s == "ab"
        && indexOf "ab" (stringSlice (i + 1) (stringLength s) s) == None
# DESUGAR
(DUse false (UseGroup ("string") ((mem "countOccurrences" false) (mem "indexOf" false) (mem "lastIndexOf" false) (mem "replaceAll" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTest false "lastIndexOf finds overlapping occurrences" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 1)))) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "aa"))) (ELit (LString "aaa")))))
(DTest false "lastIndexOf counts codepoints, not bytes" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 2)))) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "é"))) (ELit (LString "éaé")))))
(DTest false "lastIndexOf of an empty needle is the end of the string" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 5)))) (EApp (EApp (EVar "lastIndexOf") (ELit (LString ""))) (ELit (LString "héllo")))))
(DTest false "lastIndexOf of an absent needle is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "z"))) (ELit (LString "hello")))))
(DTest false "countOccurrences does not count overlaps" (EApp (EApp (EVar "expectEqual") (ELit (LInt 2))) (EApp (EApp (EVar "countOccurrences") (ELit (LString "aa"))) (ELit (LString "aaaaa")))))
(DTest false "countOccurrences of an absent needle is 0" (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EApp (EApp (EVar "countOccurrences") (ELit (LString "z"))) (ELit (LString "hello")))))
(DTest false "replaceAll replaces non-overlapping occurrences left to right" (EApp (EApp (EVar "expectEqual") (ELit (LString "bba"))) (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "aa"))) (ELit (LString "b"))) (ELit (LString "aaaaa")))))
(DTest false "replaceAll handles multibyte needles" (EApp (EApp (EVar "expectEqual") (ELit (LString "-a-"))) (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "日"))) (ELit (LString "-"))) (ELit (LString "日a日")))))
(DTest false "replaceAll with an absent needle leaves the string alone" (EApp (EApp (EVar "expectEqual") (ELit (LString "hello"))) (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "z"))) (ELit (LString "y"))) (ELit (LString "hello")))))
(DTest false "replaceAll can delete" (EApp (EApp (EVar "expectEqual") (ELit (LString "hllo"))) (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "e"))) (ELit (LString ""))) (ELit (LString "hello")))))
(DTest false "stringSlice takes the codepoints in a half-open range" (EApp (EApp (EVar "expectEqual") (ELit (LString "cd"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (ELit (LInt 4))) (ELit (LString "abcdef")))))
(DTest false "stringSlice counts codepoints, not bytes" (EApp (EApp (EVar "expectEqual") (ELit (LString "él"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 3))) (ELit (LString "héllo")))))
(DTest false "stringSlice of a wide-character tail" (EApp (EApp (EVar "expectEqual") (ELit (LString "本語"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 3))) (ELit (LString "日本語")))))
(DTest false "stringSlice clamps both ends to the string" (EApp (EApp (EVar "expectEqual") (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 2)))) (ELit (LInt 2))) (ELit (LString "abc")))))
(DTest false "stringSlice past the end is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 4))) (ELit (LInt 99))) (ELit (LString "abc")))))
(DTest false "stringSlice with the end before the start is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (ELit (LInt 1))) (ELit (LString "abc")))))
(DProp false "countOccurrences agrees with replaceAll on the removed length" ((pp "s" (TyCon "String"))) (EBinOp "==" (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "ab"))) (ELit (LString ""))) (EVar "s")))) (EBinOp "*" (ELit (LInt 2)) (EApp (EApp (EVar "countOccurrences") (ELit (LString "ab"))) (EVar "s")))))
(DProp false "lastIndexOf hit is an occurrence and no later one exists" ((pp "s" (TyCon "String"))) (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "ab"))) (EVar "s")) (arm (PCon "None") () (EBinOp "==" (EApp (EApp (EVar "countOccurrences") (ELit (LString "ab"))) (EVar "s")) (ELit (LInt 0)))) (arm (PCon "Some" (PVar "i")) () (EBinOp "&&" (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "s")) (ELit (LString "ab"))) (EBinOp "==" (EApp (EApp (EVar "indexOf") (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (EVar "None"))))))
# MARK
(DUse false (UseGroup ("string") ((mem "countOccurrences" false) (mem "indexOf" false) (mem "lastIndexOf" false) (mem "replaceAll" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTest false "lastIndexOf finds overlapping occurrences" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 1)))) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "aa"))) (ELit (LString "aaa")))))
(DTest false "lastIndexOf counts codepoints, not bytes" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 2)))) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "é"))) (ELit (LString "éaé")))))
(DTest false "lastIndexOf of an empty needle is the end of the string" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 5)))) (EApp (EApp (EVar "lastIndexOf") (ELit (LString ""))) (ELit (LString "héllo")))))
(DTest false "lastIndexOf of an absent needle is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "z"))) (ELit (LString "hello")))))
(DTest false "countOccurrences does not count overlaps" (EApp (EApp (EVar "expectEqual") (ELit (LInt 2))) (EApp (EApp (EVar "countOccurrences") (ELit (LString "aa"))) (ELit (LString "aaaaa")))))
(DTest false "countOccurrences of an absent needle is 0" (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EApp (EApp (EVar "countOccurrences") (ELit (LString "z"))) (ELit (LString "hello")))))
(DTest false "replaceAll replaces non-overlapping occurrences left to right" (EApp (EApp (EVar "expectEqual") (ELit (LString "bba"))) (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "aa"))) (ELit (LString "b"))) (ELit (LString "aaaaa")))))
(DTest false "replaceAll handles multibyte needles" (EApp (EApp (EVar "expectEqual") (ELit (LString "-a-"))) (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "日"))) (ELit (LString "-"))) (ELit (LString "日a日")))))
(DTest false "replaceAll with an absent needle leaves the string alone" (EApp (EApp (EVar "expectEqual") (ELit (LString "hello"))) (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "z"))) (ELit (LString "y"))) (ELit (LString "hello")))))
(DTest false "replaceAll can delete" (EApp (EApp (EVar "expectEqual") (ELit (LString "hllo"))) (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "e"))) (ELit (LString ""))) (ELit (LString "hello")))))
(DTest false "stringSlice takes the codepoints in a half-open range" (EApp (EApp (EVar "expectEqual") (ELit (LString "cd"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (ELit (LInt 4))) (ELit (LString "abcdef")))))
(DTest false "stringSlice counts codepoints, not bytes" (EApp (EApp (EVar "expectEqual") (ELit (LString "él"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 3))) (ELit (LString "héllo")))))
(DTest false "stringSlice of a wide-character tail" (EApp (EApp (EVar "expectEqual") (ELit (LString "本語"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 3))) (ELit (LString "日本語")))))
(DTest false "stringSlice clamps both ends to the string" (EApp (EApp (EVar "expectEqual") (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 2)))) (ELit (LInt 2))) (ELit (LString "abc")))))
(DTest false "stringSlice past the end is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 4))) (ELit (LInt 99))) (ELit (LString "abc")))))
(DTest false "stringSlice with the end before the start is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (ELit (LInt 1))) (ELit (LString "abc")))))
(DProp false "countOccurrences agrees with replaceAll on the removed length" ((pp "s" (TyCon "String"))) (EBinOp "==" (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "ab"))) (ELit (LString ""))) (EVar "s")))) (EBinOp "*" (ELit (LInt 2)) (EApp (EApp (EVar "countOccurrences") (ELit (LString "ab"))) (EVar "s")))))
(DProp false "lastIndexOf hit is an occurrence and no later one exists" ((pp "s" (TyCon "String"))) (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "ab"))) (EVar "s")) (arm (PCon "None") () (EBinOp "==" (EApp (EApp (EVar "countOccurrences") (ELit (LString "ab"))) (EVar "s")) (ELit (LInt 0)))) (arm (PCon "Some" (PVar "i")) () (EBinOp "&&" (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "s")) (ELit (LString "ab"))) (EBinOp "==" (EApp (EApp (EVar "indexOf") (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (EVar "None"))))))
