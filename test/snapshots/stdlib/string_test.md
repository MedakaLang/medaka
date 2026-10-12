# META
source_lines=314
stages=DESUGAR,MARK
# SOURCE
-- Tests for the substring search and replace functions in `stdlib/string.mdk`.
--
-- Positions are codepoint indices, so the multibyte cases below are where a
-- byte offset would show.

import string.{
  byteLength, center, countOccurrences, drop, fromChars, indexOf, lastIndexOf,
  lines, padLeft, padRight, replace, replaceAll, splitAt, take, trim, trimLeft,
  trimRight, unlines, utf8ByteLength
}
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

test "stringSlice of a multibyte string is right in either walk direction" =
  let s = "aé日😀z"
  expectEqual
    ["a", "é", "日", "😀", "z", "😀", "日", "é", "a"]
    [
      stringSlice 0 1 s,
      stringSlice 1 2 s,
      stringSlice 2 3 s,
      stringSlice 3 4 s,
      stringSlice 4 5 s,
      stringSlice 3 4 s,
      stringSlice 2 3 s,
      stringSlice 1 2 s,
      stringSlice 0 1 s,
    ]

test "stringSlice stays right when two multibyte strings alternate" =
  let s = "éaé日"
  let t = "日éa😀"
  expectEqual
    ["日", "é", "é", "a", "日", "😀"]
    [
      stringSlice 3 4 s,
      stringSlice 1 2 t,
      stringSlice 2 3 s,
      stringSlice 2 3 t,
      stringSlice 0 1 t,
      stringSlice 3 4 t,
    ]

test "stringSlice jumps far in both directions on a multibyte string" =
  let s = "日本語日本語日本語"
  expectEqual
    ["語", "日", "語", "日本語"]
    [stringSlice 8 9 s, stringSlice 0 1 s, stringSlice 5 6 s, stringSlice 6 9 s]

test "stringSlice of the whole cell and of its ends" =
  let s = "aé日😀"
  expectEqual
    [s, "", "", s, "😀", "a"]
    [
      stringSlice 0 4 s,
      stringSlice 4 4 s,
      stringSlice 0 0 s,
      stringSlice 0 99 s,
      stringSlice 3 4 s,
      stringSlice 0 1 s,
    ]

-- # take, drop, splitAt

test "byteLength of the empty string is 0" = expectEqual 0 (byteLength "")

test "byteLength counts UTF-8 bytes, not codepoints" =
  expectEqual 6 (byteLength "héllo")

test "byteLength of a four-byte codepoint is 4" = expectEqual 4 (byteLength "😀")

test "byteLength of ASCII equals its codepoint count" =
  expectEqual 5 (byteLength "hello")

test "utf8ByteLength agrees with byteLength" =
  expectEqual (byteLength "a→b日") (utf8ByteLength "a→b日")

test "byteLength of a string that is a slice of a multibyte cell" =
  expectEqual 3 (byteLength (stringSlice 1 2 "é日本"))

test "take 0 is empty" = expectEqual "" (take 0 "héllo")

test "take a negative count is empty" = expectEqual "" (take (0 - 2) "abc")

test "take past the end is the whole string" = expectEqual "é日" (take 99 "é日")

test "take counts codepoints across multibyte text" =
  expectEqual "aé日" (take 3 "aé日😀")

test "take of an empty string is empty" = expectEqual "" (take 3 "")

test "drop 0 is the whole string" = expectEqual "héllo" (drop 0 "héllo")

test "drop a negative count is the whole string" =
  expectEqual "abc" (drop (0 - 2) "abc")

test "drop past the end is empty" = expectEqual "" (drop 99 "abc")

test "drop counts codepoints across multibyte text" =
  expectEqual "日" (drop 1 "é日")

test "drop of an empty string is empty" = expectEqual "" (drop 3 "")

test "splitAt 0 gives an empty head" = expectEqual ("", "日本") (splitAt 0 "日本")

test "splitAt a negative count gives an empty head" =
  expectEqual ("", "ab") (splitAt (0 - 1) "ab")

test "splitAt past the end gives an empty tail" =
  expectEqual ("é日", "") (splitAt 9 "é日")

test "splitAt splits between codepoints of multibyte text" =
  expectEqual ("aé", "日") (splitAt 2 "aé日")

test "splitAt of an empty string is two empty strings" =
  expectEqual ("", "") (splitAt 0 "")

test "splitAt pieces rejoin to the original" =
  let s = "aé日😀z"
  let (h, t) = splitAt 3 s
  expectEqual s (h ++ t)

-- # fromChars

test "fromChars of no characters is empty" = expectEqual "" (fromChars [])

test "fromChars encodes each codepoint once" =
  expectEqual "aé日😀" (fromChars ['a', 'é', '日', '😀'])

test "fromChars counts codepoints, not bytes" =
  expectEqual 4 (stringLength (fromChars ['a', 'é', '日', '😀']))

test "fromChars result slices by codepoint" =
  expectEqual "é日" (stringSlice 1 3 (fromChars ['a', 'é', '日', '😀']))

test "fromChars of only multibyte characters" =
  expectEqual 2 (stringLength (fromChars ['😀', '😀']))

test "padLeft fills on the left and leaves a long string alone" =
  expectEqual ("...ab", "abc") (padLeft 5 '.' "ab", padLeft 2 '.' "abc")

test "padLeft with a width at or below zero is unchanged" =
  expectEqual ("ab", "ab") (padLeft 0 '.' "ab", padLeft (0 - 3) '.' "ab")

test "padLeft of the empty string" = expectEqual "..." (padLeft 3 '.' "")

test "padLeft counts codepoints for a multibyte pad character" =
  expectEqual "日日ab" (padLeft 4 '日' "ab")

test "padRight fills on the right and leaves a long string alone" =
  expectEqual ("ab...", "abc") (padRight 5 '.' "ab", padRight 2 '.' "abc")

test "padRight with a width at or below zero is unchanged" =
  expectEqual "ab" (padRight (0 - 3) '.' "ab")

test "padRight counts codepoints for a multibyte pad character" =
  expectEqual "é→→→" (padRight 4 '→' "é")

test "center puts the odd pad character on the right" =
  expectEqual ".ab.." (center 5 '.' "ab")

test "center splits an even pad evenly" =
  expectEqual ("..ab..", ".ab.") (center 6 '.' "ab", center 4 '.' "ab")

test "center of the empty string" = expectEqual "..." (center 3 '.' "")

test "center with a width at or below the length is unchanged" =
  expectEqual ("abc", "abc") (center 2 '.' "abc", center (0 - 1) '.' "abc")

test "replace of an empty needle is unchanged" =
  expectEqual "hi" (replace "" "x" "hi")

test "replace of an absent needle is unchanged" =
  expectEqual "hello" (replace "z" "y" "hello")

test "replace touches only the first occurrence" =
  expectEqual "ba" (replace "aa" "b" "aaa")

test "replace counts codepoints around a multibyte hit" =
  expectEqual "a-b日" (replace "日" "-" "a日b日")

test "replace can delete the first occurrence" =
  expectEqual "xy" (replace "ab" "" "xaby")

test "lines of the empty string is one empty line" = expectEqual [""] (lines "")

test "lines removes one trailing carriage return per line" =
  expectEqual ["a", "b", ""] (lines "a\r\nb\r\n")

test "lines keeps a second carriage return" =
  expectEqual ["a\r", "b"] (lines "a\r\r\nb")

test "lines of a lone carriage return is one empty line" =
  expectEqual [""] (lines "\r")

test "lines does not split on a bare carriage return" =
  expectEqual ["a\rb"] (lines "a\rb")

test "lines of multibyte text with carriage returns" =
  expectEqual ["é", "日"] (lines "é\r\n日\r")

test "unlines of no lines is empty" = expectEqual "" (unlines [])

test "unlines ends every line, including empty ones" =
  expectEqual "\n\n" (unlines ["", ""])

test "unlines keeps a carriage return inside a line" =
  expectEqual "a\r\n" (unlines ["a\r"])

-- # Trimming

test "trim removes both ends" = expectEqual "hi" (trim "  hi  ")

test "trimLeft keeps the trailing whitespace" =
  expectEqual "hi  " (trimLeft "  hi  ")

test "trimRight keeps the leading whitespace" =
  expectEqual "  hi" (trimRight "  hi  ")

test "trim of the empty string is empty" =
  expectEqual ("", "", "") (trim "", trimLeft "", trimRight "")

test "trim of all-space is empty" =
  expectEqual ("", "", "") (trim "   \t", trimLeft "   \t", trimRight "   \t")

test "trim of no whitespace is the string" = expectEqual "hi" (trim "hi")

test "trim with only leading space" =
  expectEqual ("a", "a", " a") (trim " a", trimLeft " a", trimRight " a")

test "trim with only trailing space" =
  expectEqual
    ("a", "a \t", "a")
    (trim "a \t", trimLeft "a \t", trimRight "a \t")

test "trim of a multibyte body keeps its codepoints" =
  expectEqual "héllo→" (trim "  héllo→ ")

test "trimRight of a multibyte tail with spaces" =
  expectEqual "日本語" (trimRight "日本語 \n")

test "trimLeft of a multibyte head with spaces" =
  expectEqual "→ x" (trimLeft "\t→ x")

test "trim treats tab, newline, carriage return and vertical tab as space" =
  expectEqual "x" (trim "\r\n\t\u{0b}\u{0c} x \r\n")

test "trim does not remove a non-breaking space" = expectEqual " x" (trim " x")

test "trim of a single space character" =
  expectEqual ("", "", "") (trim " ", trimLeft " ", trimRight " ")

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
(DUse false (UseGroup ("string") ((mem "byteLength" false) (mem "center" false) (mem "countOccurrences" false) (mem "drop" false) (mem "fromChars" false) (mem "indexOf" false) (mem "lastIndexOf" false) (mem "lines" false) (mem "padLeft" false) (mem "padRight" false) (mem "replace" false) (mem "replaceAll" false) (mem "splitAt" false) (mem "take" false) (mem "trim" false) (mem "trimLeft" false) (mem "trimRight" false) (mem "unlines" false) (mem "utf8ByteLength" false))))
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
(DTest false "stringSlice of a multibyte string is right in either walk direction" (EBlock (DoLet false false (PVar "s") (ELit (LString "aé日😀z"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "a")) (ELit (LString "é")) (ELit (LString "日")) (ELit (LString "😀")) (ELit (LString "z")) (ELit (LString "😀")) (ELit (LString "日")) (ELit (LString "é")) (ELit (LString "a")))) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 2))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (ELit (LInt 3))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 3))) (ELit (LInt 4))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 4))) (ELit (LInt 5))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 3))) (ELit (LInt 4))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (ELit (LInt 3))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 2))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")))))))
(DTest false "stringSlice stays right when two multibyte strings alternate" (EBlock (DoLet false false (PVar "s") (ELit (LString "éaé日"))) (DoLet false false (PVar "t") (ELit (LString "日éa😀"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "日")) (ELit (LString "é")) (ELit (LString "é")) (ELit (LString "a")) (ELit (LString "日")) (ELit (LString "😀")))) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 3))) (ELit (LInt 4))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 2))) (EVar "t")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (ELit (LInt 3))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (ELit (LInt 3))) (EVar "t")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "t")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 3))) (ELit (LInt 4))) (EVar "t")))))))
(DTest false "stringSlice jumps far in both directions on a multibyte string" (EBlock (DoLet false false (PVar "s") (ELit (LString "日本語日本語日本語"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "語")) (ELit (LString "日")) (ELit (LString "語")) (ELit (LString "日本語")))) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 8))) (ELit (LInt 9))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 5))) (ELit (LInt 6))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 6))) (ELit (LInt 9))) (EVar "s")))))))
(DTest false "stringSlice of the whole cell and of its ends" (EBlock (DoLet false false (PVar "s") (ELit (LString "aé日😀"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (EVar "s") (ELit (LString "")) (ELit (LString "")) (EVar "s") (ELit (LString "😀")) (ELit (LString "a")))) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 4))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 4))) (ELit (LInt 4))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 0))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 99))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 3))) (ELit (LInt 4))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")))))))
(DTest false "byteLength of the empty string is 0" (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EApp (EVar "byteLength") (ELit (LString "")))))
(DTest false "byteLength counts UTF-8 bytes, not codepoints" (EApp (EApp (EVar "expectEqual") (ELit (LInt 6))) (EApp (EVar "byteLength") (ELit (LString "héllo")))))
(DTest false "byteLength of a four-byte codepoint is 4" (EApp (EApp (EVar "expectEqual") (ELit (LInt 4))) (EApp (EVar "byteLength") (ELit (LString "😀")))))
(DTest false "byteLength of ASCII equals its codepoint count" (EApp (EApp (EVar "expectEqual") (ELit (LInt 5))) (EApp (EVar "byteLength") (ELit (LString "hello")))))
(DTest false "utf8ByteLength agrees with byteLength" (EApp (EApp (EVar "expectEqual") (EApp (EVar "byteLength") (ELit (LString "a→b日")))) (EApp (EVar "utf8ByteLength") (ELit (LString "a→b日")))))
(DTest false "byteLength of a string that is a slice of a multibyte cell" (EApp (EApp (EVar "expectEqual") (ELit (LInt 3))) (EApp (EVar "byteLength") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 2))) (ELit (LString "é日本"))))))
(DTest false "take 0 is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EVar "take") (ELit (LInt 0))) (ELit (LString "héllo")))))
(DTest false "take a negative count is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EVar "take") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 2)))) (ELit (LString "abc")))))
(DTest false "take past the end is the whole string" (EApp (EApp (EVar "expectEqual") (ELit (LString "é日"))) (EApp (EApp (EVar "take") (ELit (LInt 99))) (ELit (LString "é日")))))
(DTest false "take counts codepoints across multibyte text" (EApp (EApp (EVar "expectEqual") (ELit (LString "aé日"))) (EApp (EApp (EVar "take") (ELit (LInt 3))) (ELit (LString "aé日😀")))))
(DTest false "take of an empty string is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EVar "take") (ELit (LInt 3))) (ELit (LString "")))))
(DTest false "drop 0 is the whole string" (EApp (EApp (EVar "expectEqual") (ELit (LString "héllo"))) (EApp (EApp (EVar "drop") (ELit (LInt 0))) (ELit (LString "héllo")))))
(DTest false "drop a negative count is the whole string" (EApp (EApp (EVar "expectEqual") (ELit (LString "abc"))) (EApp (EApp (EVar "drop") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 2)))) (ELit (LString "abc")))))
(DTest false "drop past the end is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EVar "drop") (ELit (LInt 99))) (ELit (LString "abc")))))
(DTest false "drop counts codepoints across multibyte text" (EApp (EApp (EVar "expectEqual") (ELit (LString "日"))) (EApp (EApp (EVar "drop") (ELit (LInt 1))) (ELit (LString "é日")))))
(DTest false "drop of an empty string is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EVar "drop") (ELit (LInt 3))) (ELit (LString "")))))
(DTest false "splitAt 0 gives an empty head" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "日本")))) (EApp (EApp (EVar "splitAt") (ELit (LInt 0))) (ELit (LString "日本")))))
(DTest false "splitAt a negative count gives an empty head" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "ab")))) (EApp (EApp (EVar "splitAt") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (ELit (LString "ab")))))
(DTest false "splitAt past the end gives an empty tail" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "é日")) (ELit (LString "")))) (EApp (EApp (EVar "splitAt") (ELit (LInt 9))) (ELit (LString "é日")))))
(DTest false "splitAt splits between codepoints of multibyte text" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "aé")) (ELit (LString "日")))) (EApp (EApp (EVar "splitAt") (ELit (LInt 2))) (ELit (LString "aé日")))))
(DTest false "splitAt of an empty string is two empty strings" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "")))) (EApp (EApp (EVar "splitAt") (ELit (LInt 0))) (ELit (LString "")))))
(DTest false "splitAt pieces rejoin to the original" (EBlock (DoLet false false (PVar "s") (ELit (LString "aé日😀z"))) (DoLet false false (PTuple (PVar "h") (PVar "t")) (EApp (EApp (EVar "splitAt") (ELit (LInt 3))) (EVar "s"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EVar "s")) (EBinOp "++" (EVar "h") (EVar "t"))))))
(DTest false "fromChars of no characters is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EVar "fromChars") (EListLit))))
(DTest false "fromChars encodes each codepoint once" (EApp (EApp (EVar "expectEqual") (ELit (LString "aé日😀"))) (EApp (EVar "fromChars") (EListLit (ELit (LChar "a")) (ELit (LChar "é")) (ELit (LChar "日")) (ELit (LChar "😀"))))))
(DTest false "fromChars counts codepoints, not bytes" (EApp (EApp (EVar "expectEqual") (ELit (LInt 4))) (EApp (EVar "stringLength") (EApp (EVar "fromChars") (EListLit (ELit (LChar "a")) (ELit (LChar "é")) (ELit (LChar "日")) (ELit (LChar "😀")))))))
(DTest false "fromChars result slices by codepoint" (EApp (EApp (EVar "expectEqual") (ELit (LString "é日"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 3))) (EApp (EVar "fromChars") (EListLit (ELit (LChar "a")) (ELit (LChar "é")) (ELit (LChar "日")) (ELit (LChar "😀")))))))
(DTest false "fromChars of only multibyte characters" (EApp (EApp (EVar "expectEqual") (ELit (LInt 2))) (EApp (EVar "stringLength") (EApp (EVar "fromChars") (EListLit (ELit (LChar "😀")) (ELit (LChar "😀")))))))
(DTest false "padLeft fills on the left and leaves a long string alone" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "...ab")) (ELit (LString "abc")))) (ETuple (EApp (EApp (EApp (EVar "padLeft") (ELit (LInt 5))) (ELit (LChar "."))) (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "padLeft") (ELit (LInt 2))) (ELit (LChar "."))) (ELit (LString "abc"))))))
(DTest false "padLeft with a width at or below zero is unchanged" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "ab")) (ELit (LString "ab")))) (ETuple (EApp (EApp (EApp (EVar "padLeft") (ELit (LInt 0))) (ELit (LChar "."))) (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "padLeft") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 3)))) (ELit (LChar "."))) (ELit (LString "ab"))))))
(DTest false "padLeft of the empty string" (EApp (EApp (EVar "expectEqual") (ELit (LString "..."))) (EApp (EApp (EApp (EVar "padLeft") (ELit (LInt 3))) (ELit (LChar "."))) (ELit (LString "")))))
(DTest false "padLeft counts codepoints for a multibyte pad character" (EApp (EApp (EVar "expectEqual") (ELit (LString "日日ab"))) (EApp (EApp (EApp (EVar "padLeft") (ELit (LInt 4))) (ELit (LChar "日"))) (ELit (LString "ab")))))
(DTest false "padRight fills on the right and leaves a long string alone" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "ab...")) (ELit (LString "abc")))) (ETuple (EApp (EApp (EApp (EVar "padRight") (ELit (LInt 5))) (ELit (LChar "."))) (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "padRight") (ELit (LInt 2))) (ELit (LChar "."))) (ELit (LString "abc"))))))
(DTest false "padRight with a width at or below zero is unchanged" (EApp (EApp (EVar "expectEqual") (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "padRight") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 3)))) (ELit (LChar "."))) (ELit (LString "ab")))))
(DTest false "padRight counts codepoints for a multibyte pad character" (EApp (EApp (EVar "expectEqual") (ELit (LString "é→→→"))) (EApp (EApp (EApp (EVar "padRight") (ELit (LInt 4))) (ELit (LChar "→"))) (ELit (LString "é")))))
(DTest false "center puts the odd pad character on the right" (EApp (EApp (EVar "expectEqual") (ELit (LString ".ab.."))) (EApp (EApp (EApp (EVar "center") (ELit (LInt 5))) (ELit (LChar "."))) (ELit (LString "ab")))))
(DTest false "center splits an even pad evenly" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "..ab..")) (ELit (LString ".ab.")))) (ETuple (EApp (EApp (EApp (EVar "center") (ELit (LInt 6))) (ELit (LChar "."))) (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "center") (ELit (LInt 4))) (ELit (LChar "."))) (ELit (LString "ab"))))))
(DTest false "center of the empty string" (EApp (EApp (EVar "expectEqual") (ELit (LString "..."))) (EApp (EApp (EApp (EVar "center") (ELit (LInt 3))) (ELit (LChar "."))) (ELit (LString "")))))
(DTest false "center with a width at or below the length is unchanged" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "abc")) (ELit (LString "abc")))) (ETuple (EApp (EApp (EApp (EVar "center") (ELit (LInt 2))) (ELit (LChar "."))) (ELit (LString "abc"))) (EApp (EApp (EApp (EVar "center") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (ELit (LChar "."))) (ELit (LString "abc"))))))
(DTest false "replace of an empty needle is unchanged" (EApp (EApp (EVar "expectEqual") (ELit (LString "hi"))) (EApp (EApp (EApp (EVar "replace") (ELit (LString ""))) (ELit (LString "x"))) (ELit (LString "hi")))))
(DTest false "replace of an absent needle is unchanged" (EApp (EApp (EVar "expectEqual") (ELit (LString "hello"))) (EApp (EApp (EApp (EVar "replace") (ELit (LString "z"))) (ELit (LString "y"))) (ELit (LString "hello")))))
(DTest false "replace touches only the first occurrence" (EApp (EApp (EVar "expectEqual") (ELit (LString "ba"))) (EApp (EApp (EApp (EVar "replace") (ELit (LString "aa"))) (ELit (LString "b"))) (ELit (LString "aaa")))))
(DTest false "replace counts codepoints around a multibyte hit" (EApp (EApp (EVar "expectEqual") (ELit (LString "a-b日"))) (EApp (EApp (EApp (EVar "replace") (ELit (LString "日"))) (ELit (LString "-"))) (ELit (LString "a日b日")))))
(DTest false "replace can delete the first occurrence" (EApp (EApp (EVar "expectEqual") (ELit (LString "xy"))) (EApp (EApp (EApp (EVar "replace") (ELit (LString "ab"))) (ELit (LString ""))) (ELit (LString "xaby")))))
(DTest false "lines of the empty string is one empty line" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "")))) (EApp (EVar "lines") (ELit (LString "")))))
(DTest false "lines removes one trailing carriage return per line" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "a")) (ELit (LString "b")) (ELit (LString "")))) (EApp (EVar "lines") (ELit (LString "a\r\nb\r\n")))))
(DTest false "lines keeps a second carriage return" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "a\r")) (ELit (LString "b")))) (EApp (EVar "lines") (ELit (LString "a\r\r\nb")))))
(DTest false "lines of a lone carriage return is one empty line" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "")))) (EApp (EVar "lines") (ELit (LString "\r")))))
(DTest false "lines does not split on a bare carriage return" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "a\rb")))) (EApp (EVar "lines") (ELit (LString "a\rb")))))
(DTest false "lines of multibyte text with carriage returns" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "é")) (ELit (LString "日")))) (EApp (EVar "lines") (ELit (LString "é\r\n日\r")))))
(DTest false "unlines of no lines is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EVar "unlines") (EListLit))))
(DTest false "unlines ends every line, including empty ones" (EApp (EApp (EVar "expectEqual") (ELit (LString "\n\n"))) (EApp (EVar "unlines") (EListLit (ELit (LString "")) (ELit (LString ""))))))
(DTest false "unlines keeps a carriage return inside a line" (EApp (EApp (EVar "expectEqual") (ELit (LString "a\r\n"))) (EApp (EVar "unlines") (EListLit (ELit (LString "a\r"))))))
(DTest false "trim removes both ends" (EApp (EApp (EVar "expectEqual") (ELit (LString "hi"))) (EApp (EVar "trim") (ELit (LString "  hi  ")))))
(DTest false "trimLeft keeps the trailing whitespace" (EApp (EApp (EVar "expectEqual") (ELit (LString "hi  "))) (EApp (EVar "trimLeft") (ELit (LString "  hi  ")))))
(DTest false "trimRight keeps the leading whitespace" (EApp (EApp (EVar "expectEqual") (ELit (LString "  hi"))) (EApp (EVar "trimRight") (ELit (LString "  hi  ")))))
(DTest false "trim of the empty string is empty" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "")) (ELit (LString "")))) (ETuple (EApp (EVar "trim") (ELit (LString ""))) (EApp (EVar "trimLeft") (ELit (LString ""))) (EApp (EVar "trimRight") (ELit (LString ""))))))
(DTest false "trim of all-space is empty" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "")) (ELit (LString "")))) (ETuple (EApp (EVar "trim") (ELit (LString "   \t"))) (EApp (EVar "trimLeft") (ELit (LString "   \t"))) (EApp (EVar "trimRight") (ELit (LString "   \t"))))))
(DTest false "trim of no whitespace is the string" (EApp (EApp (EVar "expectEqual") (ELit (LString "hi"))) (EApp (EVar "trim") (ELit (LString "hi")))))
(DTest false "trim with only leading space" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "a")) (ELit (LString "a")) (ELit (LString " a")))) (ETuple (EApp (EVar "trim") (ELit (LString " a"))) (EApp (EVar "trimLeft") (ELit (LString " a"))) (EApp (EVar "trimRight") (ELit (LString " a"))))))
(DTest false "trim with only trailing space" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "a")) (ELit (LString "a \t")) (ELit (LString "a")))) (ETuple (EApp (EVar "trim") (ELit (LString "a \t"))) (EApp (EVar "trimLeft") (ELit (LString "a \t"))) (EApp (EVar "trimRight") (ELit (LString "a \t"))))))
(DTest false "trim of a multibyte body keeps its codepoints" (EApp (EApp (EVar "expectEqual") (ELit (LString "héllo→"))) (EApp (EVar "trim") (ELit (LString "  héllo→ ")))))
(DTest false "trimRight of a multibyte tail with spaces" (EApp (EApp (EVar "expectEqual") (ELit (LString "日本語"))) (EApp (EVar "trimRight") (ELit (LString "日本語 \n")))))
(DTest false "trimLeft of a multibyte head with spaces" (EApp (EApp (EVar "expectEqual") (ELit (LString "→ x"))) (EApp (EVar "trimLeft") (ELit (LString "\t→ x")))))
(DTest false "trim treats tab, newline, carriage return and vertical tab as space" (EApp (EApp (EVar "expectEqual") (ELit (LString "x"))) (EApp (EVar "trim") (ELit (LString "\r\n\t\u{0b}\u{0c} x \r\n")))))
(DTest false "trim does not remove a non-breaking space" (EApp (EApp (EVar "expectEqual") (ELit (LString " x"))) (EApp (EVar "trim") (ELit (LString " x")))))
(DTest false "trim of a single space character" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "")) (ELit (LString "")))) (ETuple (EApp (EVar "trim") (ELit (LString " "))) (EApp (EVar "trimLeft") (ELit (LString " "))) (EApp (EVar "trimRight") (ELit (LString " "))))))
(DProp false "countOccurrences agrees with replaceAll on the removed length" ((pp "s" (TyCon "String"))) (EBinOp "==" (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "ab"))) (ELit (LString ""))) (EVar "s")))) (EBinOp "*" (ELit (LInt 2)) (EApp (EApp (EVar "countOccurrences") (ELit (LString "ab"))) (EVar "s")))))
(DProp false "lastIndexOf hit is an occurrence and no later one exists" ((pp "s" (TyCon "String"))) (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "ab"))) (EVar "s")) (arm (PCon "None") () (EBinOp "==" (EApp (EApp (EVar "countOccurrences") (ELit (LString "ab"))) (EVar "s")) (ELit (LInt 0)))) (arm (PCon "Some" (PVar "i")) () (EBinOp "&&" (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "s")) (ELit (LString "ab"))) (EBinOp "==" (EApp (EApp (EVar "indexOf") (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (EVar "None"))))))
# MARK
(DUse false (UseGroup ("string") ((mem "byteLength" false) (mem "center" false) (mem "countOccurrences" false) (mem "drop" false) (mem "fromChars" false) (mem "indexOf" false) (mem "lastIndexOf" false) (mem "lines" false) (mem "padLeft" false) (mem "padRight" false) (mem "replace" false) (mem "replaceAll" false) (mem "splitAt" false) (mem "take" false) (mem "trim" false) (mem "trimLeft" false) (mem "trimRight" false) (mem "unlines" false) (mem "utf8ByteLength" false))))
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
(DTest false "stringSlice of a multibyte string is right in either walk direction" (EBlock (DoLet false false (PVar "s") (ELit (LString "aé日😀z"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "a")) (ELit (LString "é")) (ELit (LString "日")) (ELit (LString "😀")) (ELit (LString "z")) (ELit (LString "😀")) (ELit (LString "日")) (ELit (LString "é")) (ELit (LString "a")))) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 2))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (ELit (LInt 3))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 3))) (ELit (LInt 4))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 4))) (ELit (LInt 5))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 3))) (ELit (LInt 4))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (ELit (LInt 3))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 2))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")))))))
(DTest false "stringSlice stays right when two multibyte strings alternate" (EBlock (DoLet false false (PVar "s") (ELit (LString "éaé日"))) (DoLet false false (PVar "t") (ELit (LString "日éa😀"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "日")) (ELit (LString "é")) (ELit (LString "é")) (ELit (LString "a")) (ELit (LString "日")) (ELit (LString "😀")))) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 3))) (ELit (LInt 4))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 2))) (EVar "t")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (ELit (LInt 3))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (ELit (LInt 3))) (EVar "t")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "t")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 3))) (ELit (LInt 4))) (EVar "t")))))))
(DTest false "stringSlice jumps far in both directions on a multibyte string" (EBlock (DoLet false false (PVar "s") (ELit (LString "日本語日本語日本語"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "語")) (ELit (LString "日")) (ELit (LString "語")) (ELit (LString "日本語")))) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 8))) (ELit (LInt 9))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 5))) (ELit (LInt 6))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 6))) (ELit (LInt 9))) (EVar "s")))))))
(DTest false "stringSlice of the whole cell and of its ends" (EBlock (DoLet false false (PVar "s") (ELit (LString "aé日😀"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EListLit (EVar "s") (ELit (LString "")) (ELit (LString "")) (EVar "s") (ELit (LString "😀")) (ELit (LString "a")))) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 4))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 4))) (ELit (LInt 4))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 0))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 99))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 3))) (ELit (LInt 4))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")))))))
(DTest false "byteLength of the empty string is 0" (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EApp (EVar "byteLength") (ELit (LString "")))))
(DTest false "byteLength counts UTF-8 bytes, not codepoints" (EApp (EApp (EVar "expectEqual") (ELit (LInt 6))) (EApp (EVar "byteLength") (ELit (LString "héllo")))))
(DTest false "byteLength of a four-byte codepoint is 4" (EApp (EApp (EVar "expectEqual") (ELit (LInt 4))) (EApp (EVar "byteLength") (ELit (LString "😀")))))
(DTest false "byteLength of ASCII equals its codepoint count" (EApp (EApp (EVar "expectEqual") (ELit (LInt 5))) (EApp (EVar "byteLength") (ELit (LString "hello")))))
(DTest false "utf8ByteLength agrees with byteLength" (EApp (EApp (EVar "expectEqual") (EApp (EVar "byteLength") (ELit (LString "a→b日")))) (EApp (EVar "utf8ByteLength") (ELit (LString "a→b日")))))
(DTest false "byteLength of a string that is a slice of a multibyte cell" (EApp (EApp (EVar "expectEqual") (ELit (LInt 3))) (EApp (EVar "byteLength") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 2))) (ELit (LString "é日本"))))))
(DTest false "take 0 is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EVar "take") (ELit (LInt 0))) (ELit (LString "héllo")))))
(DTest false "take a negative count is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EVar "take") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 2)))) (ELit (LString "abc")))))
(DTest false "take past the end is the whole string" (EApp (EApp (EVar "expectEqual") (ELit (LString "é日"))) (EApp (EApp (EVar "take") (ELit (LInt 99))) (ELit (LString "é日")))))
(DTest false "take counts codepoints across multibyte text" (EApp (EApp (EVar "expectEqual") (ELit (LString "aé日"))) (EApp (EApp (EVar "take") (ELit (LInt 3))) (ELit (LString "aé日😀")))))
(DTest false "take of an empty string is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EVar "take") (ELit (LInt 3))) (ELit (LString "")))))
(DTest false "drop 0 is the whole string" (EApp (EApp (EVar "expectEqual") (ELit (LString "héllo"))) (EApp (EApp (EVar "drop") (ELit (LInt 0))) (ELit (LString "héllo")))))
(DTest false "drop a negative count is the whole string" (EApp (EApp (EVar "expectEqual") (ELit (LString "abc"))) (EApp (EApp (EVar "drop") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 2)))) (ELit (LString "abc")))))
(DTest false "drop past the end is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EVar "drop") (ELit (LInt 99))) (ELit (LString "abc")))))
(DTest false "drop counts codepoints across multibyte text" (EApp (EApp (EVar "expectEqual") (ELit (LString "日"))) (EApp (EApp (EVar "drop") (ELit (LInt 1))) (ELit (LString "é日")))))
(DTest false "drop of an empty string is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EApp (EVar "drop") (ELit (LInt 3))) (ELit (LString "")))))
(DTest false "splitAt 0 gives an empty head" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "日本")))) (EApp (EApp (EVar "splitAt") (ELit (LInt 0))) (ELit (LString "日本")))))
(DTest false "splitAt a negative count gives an empty head" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "ab")))) (EApp (EApp (EVar "splitAt") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (ELit (LString "ab")))))
(DTest false "splitAt past the end gives an empty tail" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "é日")) (ELit (LString "")))) (EApp (EApp (EVar "splitAt") (ELit (LInt 9))) (ELit (LString "é日")))))
(DTest false "splitAt splits between codepoints of multibyte text" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "aé")) (ELit (LString "日")))) (EApp (EApp (EVar "splitAt") (ELit (LInt 2))) (ELit (LString "aé日")))))
(DTest false "splitAt of an empty string is two empty strings" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "")))) (EApp (EApp (EVar "splitAt") (ELit (LInt 0))) (ELit (LString "")))))
(DTest false "splitAt pieces rejoin to the original" (EBlock (DoLet false false (PVar "s") (ELit (LString "aé日😀z"))) (DoLet false false (PTuple (PVar "h") (PVar "t")) (EApp (EApp (EVar "splitAt") (ELit (LInt 3))) (EVar "s"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EVar "s")) (EBinOp "++" (EVar "h") (EVar "t"))))))
(DTest false "fromChars of no characters is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EVar "fromChars") (EListLit))))
(DTest false "fromChars encodes each codepoint once" (EApp (EApp (EVar "expectEqual") (ELit (LString "aé日😀"))) (EApp (EVar "fromChars") (EListLit (ELit (LChar "a")) (ELit (LChar "é")) (ELit (LChar "日")) (ELit (LChar "😀"))))))
(DTest false "fromChars counts codepoints, not bytes" (EApp (EApp (EVar "expectEqual") (ELit (LInt 4))) (EApp (EVar "stringLength") (EApp (EVar "fromChars") (EListLit (ELit (LChar "a")) (ELit (LChar "é")) (ELit (LChar "日")) (ELit (LChar "😀")))))))
(DTest false "fromChars result slices by codepoint" (EApp (EApp (EVar "expectEqual") (ELit (LString "é日"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (ELit (LInt 3))) (EApp (EVar "fromChars") (EListLit (ELit (LChar "a")) (ELit (LChar "é")) (ELit (LChar "日")) (ELit (LChar "😀")))))))
(DTest false "fromChars of only multibyte characters" (EApp (EApp (EVar "expectEqual") (ELit (LInt 2))) (EApp (EVar "stringLength") (EApp (EVar "fromChars") (EListLit (ELit (LChar "😀")) (ELit (LChar "😀")))))))
(DTest false "padLeft fills on the left and leaves a long string alone" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "...ab")) (ELit (LString "abc")))) (ETuple (EApp (EApp (EApp (EVar "padLeft") (ELit (LInt 5))) (ELit (LChar "."))) (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "padLeft") (ELit (LInt 2))) (ELit (LChar "."))) (ELit (LString "abc"))))))
(DTest false "padLeft with a width at or below zero is unchanged" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "ab")) (ELit (LString "ab")))) (ETuple (EApp (EApp (EApp (EVar "padLeft") (ELit (LInt 0))) (ELit (LChar "."))) (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "padLeft") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 3)))) (ELit (LChar "."))) (ELit (LString "ab"))))))
(DTest false "padLeft of the empty string" (EApp (EApp (EVar "expectEqual") (ELit (LString "..."))) (EApp (EApp (EApp (EVar "padLeft") (ELit (LInt 3))) (ELit (LChar "."))) (ELit (LString "")))))
(DTest false "padLeft counts codepoints for a multibyte pad character" (EApp (EApp (EVar "expectEqual") (ELit (LString "日日ab"))) (EApp (EApp (EApp (EVar "padLeft") (ELit (LInt 4))) (ELit (LChar "日"))) (ELit (LString "ab")))))
(DTest false "padRight fills on the right and leaves a long string alone" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "ab...")) (ELit (LString "abc")))) (ETuple (EApp (EApp (EApp (EVar "padRight") (ELit (LInt 5))) (ELit (LChar "."))) (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "padRight") (ELit (LInt 2))) (ELit (LChar "."))) (ELit (LString "abc"))))))
(DTest false "padRight with a width at or below zero is unchanged" (EApp (EApp (EVar "expectEqual") (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "padRight") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 3)))) (ELit (LChar "."))) (ELit (LString "ab")))))
(DTest false "padRight counts codepoints for a multibyte pad character" (EApp (EApp (EVar "expectEqual") (ELit (LString "é→→→"))) (EApp (EApp (EApp (EVar "padRight") (ELit (LInt 4))) (ELit (LChar "→"))) (ELit (LString "é")))))
(DTest false "center puts the odd pad character on the right" (EApp (EApp (EVar "expectEqual") (ELit (LString ".ab.."))) (EApp (EApp (EApp (EVar "center") (ELit (LInt 5))) (ELit (LChar "."))) (ELit (LString "ab")))))
(DTest false "center splits an even pad evenly" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "..ab..")) (ELit (LString ".ab.")))) (ETuple (EApp (EApp (EApp (EVar "center") (ELit (LInt 6))) (ELit (LChar "."))) (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "center") (ELit (LInt 4))) (ELit (LChar "."))) (ELit (LString "ab"))))))
(DTest false "center of the empty string" (EApp (EApp (EVar "expectEqual") (ELit (LString "..."))) (EApp (EApp (EApp (EVar "center") (ELit (LInt 3))) (ELit (LChar "."))) (ELit (LString "")))))
(DTest false "center with a width at or below the length is unchanged" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "abc")) (ELit (LString "abc")))) (ETuple (EApp (EApp (EApp (EVar "center") (ELit (LInt 2))) (ELit (LChar "."))) (ELit (LString "abc"))) (EApp (EApp (EApp (EVar "center") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (ELit (LChar "."))) (ELit (LString "abc"))))))
(DTest false "replace of an empty needle is unchanged" (EApp (EApp (EVar "expectEqual") (ELit (LString "hi"))) (EApp (EApp (EApp (EVar "replace") (ELit (LString ""))) (ELit (LString "x"))) (ELit (LString "hi")))))
(DTest false "replace of an absent needle is unchanged" (EApp (EApp (EVar "expectEqual") (ELit (LString "hello"))) (EApp (EApp (EApp (EVar "replace") (ELit (LString "z"))) (ELit (LString "y"))) (ELit (LString "hello")))))
(DTest false "replace touches only the first occurrence" (EApp (EApp (EVar "expectEqual") (ELit (LString "ba"))) (EApp (EApp (EApp (EVar "replace") (ELit (LString "aa"))) (ELit (LString "b"))) (ELit (LString "aaa")))))
(DTest false "replace counts codepoints around a multibyte hit" (EApp (EApp (EVar "expectEqual") (ELit (LString "a-b日"))) (EApp (EApp (EApp (EVar "replace") (ELit (LString "日"))) (ELit (LString "-"))) (ELit (LString "a日b日")))))
(DTest false "replace can delete the first occurrence" (EApp (EApp (EVar "expectEqual") (ELit (LString "xy"))) (EApp (EApp (EApp (EVar "replace") (ELit (LString "ab"))) (ELit (LString ""))) (ELit (LString "xaby")))))
(DTest false "lines of the empty string is one empty line" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "")))) (EApp (EVar "lines") (ELit (LString "")))))
(DTest false "lines removes one trailing carriage return per line" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "a")) (ELit (LString "b")) (ELit (LString "")))) (EApp (EVar "lines") (ELit (LString "a\r\nb\r\n")))))
(DTest false "lines keeps a second carriage return" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "a\r")) (ELit (LString "b")))) (EApp (EVar "lines") (ELit (LString "a\r\r\nb")))))
(DTest false "lines of a lone carriage return is one empty line" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "")))) (EApp (EVar "lines") (ELit (LString "\r")))))
(DTest false "lines does not split on a bare carriage return" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "a\rb")))) (EApp (EVar "lines") (ELit (LString "a\rb")))))
(DTest false "lines of multibyte text with carriage returns" (EApp (EApp (EVar "expectEqual") (EListLit (ELit (LString "é")) (ELit (LString "日")))) (EApp (EVar "lines") (ELit (LString "é\r\n日\r")))))
(DTest false "unlines of no lines is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EVar "unlines") (EListLit))))
(DTest false "unlines ends every line, including empty ones" (EApp (EApp (EVar "expectEqual") (ELit (LString "\n\n"))) (EApp (EVar "unlines") (EListLit (ELit (LString "")) (ELit (LString ""))))))
(DTest false "unlines keeps a carriage return inside a line" (EApp (EApp (EVar "expectEqual") (ELit (LString "a\r\n"))) (EApp (EVar "unlines") (EListLit (ELit (LString "a\r"))))))
(DTest false "trim removes both ends" (EApp (EApp (EVar "expectEqual") (ELit (LString "hi"))) (EApp (EVar "trim") (ELit (LString "  hi  ")))))
(DTest false "trimLeft keeps the trailing whitespace" (EApp (EApp (EVar "expectEqual") (ELit (LString "hi  "))) (EApp (EVar "trimLeft") (ELit (LString "  hi  ")))))
(DTest false "trimRight keeps the leading whitespace" (EApp (EApp (EVar "expectEqual") (ELit (LString "  hi"))) (EApp (EVar "trimRight") (ELit (LString "  hi  ")))))
(DTest false "trim of the empty string is empty" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "")) (ELit (LString "")))) (ETuple (EApp (EVar "trim") (ELit (LString ""))) (EApp (EVar "trimLeft") (ELit (LString ""))) (EApp (EVar "trimRight") (ELit (LString ""))))))
(DTest false "trim of all-space is empty" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "")) (ELit (LString "")))) (ETuple (EApp (EVar "trim") (ELit (LString "   \t"))) (EApp (EVar "trimLeft") (ELit (LString "   \t"))) (EApp (EVar "trimRight") (ELit (LString "   \t"))))))
(DTest false "trim of no whitespace is the string" (EApp (EApp (EVar "expectEqual") (ELit (LString "hi"))) (EApp (EVar "trim") (ELit (LString "hi")))))
(DTest false "trim with only leading space" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "a")) (ELit (LString "a")) (ELit (LString " a")))) (ETuple (EApp (EVar "trim") (ELit (LString " a"))) (EApp (EVar "trimLeft") (ELit (LString " a"))) (EApp (EVar "trimRight") (ELit (LString " a"))))))
(DTest false "trim with only trailing space" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "a")) (ELit (LString "a \t")) (ELit (LString "a")))) (ETuple (EApp (EVar "trim") (ELit (LString "a \t"))) (EApp (EVar "trimLeft") (ELit (LString "a \t"))) (EApp (EVar "trimRight") (ELit (LString "a \t"))))))
(DTest false "trim of a multibyte body keeps its codepoints" (EApp (EApp (EVar "expectEqual") (ELit (LString "héllo→"))) (EApp (EVar "trim") (ELit (LString "  héllo→ ")))))
(DTest false "trimRight of a multibyte tail with spaces" (EApp (EApp (EVar "expectEqual") (ELit (LString "日本語"))) (EApp (EVar "trimRight") (ELit (LString "日本語 \n")))))
(DTest false "trimLeft of a multibyte head with spaces" (EApp (EApp (EVar "expectEqual") (ELit (LString "→ x"))) (EApp (EVar "trimLeft") (ELit (LString "\t→ x")))))
(DTest false "trim treats tab, newline, carriage return and vertical tab as space" (EApp (EApp (EVar "expectEqual") (ELit (LString "x"))) (EApp (EVar "trim") (ELit (LString "\r\n\t\u{0b}\u{0c} x \r\n")))))
(DTest false "trim does not remove a non-breaking space" (EApp (EApp (EVar "expectEqual") (ELit (LString " x"))) (EApp (EVar "trim") (ELit (LString " x")))))
(DTest false "trim of a single space character" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "")) (ELit (LString "")))) (ETuple (EApp (EVar "trim") (ELit (LString " "))) (EApp (EVar "trimLeft") (ELit (LString " "))) (EApp (EVar "trimRight") (ELit (LString " "))))))
(DProp false "countOccurrences agrees with replaceAll on the removed length" ((pp "s" (TyCon "String"))) (EBinOp "==" (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EApp (EApp (EApp (EVar "replaceAll") (ELit (LString "ab"))) (ELit (LString ""))) (EVar "s")))) (EBinOp "*" (ELit (LInt 2)) (EApp (EApp (EVar "countOccurrences") (ELit (LString "ab"))) (EVar "s")))))
(DProp false "lastIndexOf hit is an occurrence and no later one exists" ((pp "s" (TyCon "String"))) (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "ab"))) (EVar "s")) (arm (PCon "None") () (EBinOp "==" (EApp (EApp (EVar "countOccurrences") (ELit (LString "ab"))) (EVar "s")) (ELit (LInt 0)))) (arm (PCon "Some" (PVar "i")) () (EBinOp "&&" (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "s")) (ELit (LString "ab"))) (EBinOp "==" (EApp (EApp (EVar "indexOf") (ELit (LString "ab"))) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (EVar "None"))))))
