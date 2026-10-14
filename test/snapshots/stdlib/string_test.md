# META
source_lines=785
stages=DESUGAR,MARK
# SOURCE
-- Tests for the substring search and replace functions in `stdlib/string.mdk`.
--
-- Positions are codepoint indices, so the multibyte cases below are where a
-- byte offset would show.

import string.{
  byteLength, center, countOccurrences, drop, endsWith, fromChars, indexOf,
  join, lastIndexOf, lines, padLeft, padRight, replace, replaceAll, reverse,
  splitAt, startsWith, stripPrefix, stripSuffix, take, toInt, trim, trimLeft,
  trimRight, unlines, unwords, utf8ByteLength
}
import test.{expectEqual, expectFalse, expectTrue}

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

-- # Native byte-level searches

test "startsWith the empty prefix is True" = expectTrue (startsWith "" "")

test "startsWith a prefix longer than the string is False" =
  expectFalse (startsWith "hello!" "hello")

test "startsWith compares whole codepoints of multibyte text" =
  expectEqual (True, False) (startsWith "日" "日本", startsWith "日本" "日")

test "endsWith the empty suffix is True" = expectTrue (endsWith "" "")

test "endsWith a suffix longer than the string is False" =
  expectFalse (endsWith "xhello" "hello")

test "endsWith of a multibyte suffix" =
  expectEqual (True, False) (endsWith "語" "日本語", endsWith "本" "日本語")

test "stripPrefix and stripSuffix on multibyte text" =
  expectEqual
    (Some "本語", Some "日本")
    (stripPrefix "日" "日本語", stripSuffix "語" "日本語")

test "countOccurrences of an empty needle is 0" =
  expectEqual 0 (countOccurrences "" "héllo")

test "countOccurrences does not count overlapping matches in multibyte text" =
  expectEqual 2 (countOccurrences "éé" "ééé é ééé")

test "countOccurrences finds multibyte needles" =
  expectEqual 3 (countOccurrences "日" "日a日日")

test "lastIndexOf of a needle longer than the haystack is None" =
  expectEqual None (lastIndexOf "hello!" "hello")

test "lastIndexOf keeps the last overlapping match in a run" =
  expectEqual (Some 3) (lastIndexOf "aa" "aaaaa")

test "lastIndexOf returns the codepoint index past a multibyte prefix" =
  expectEqual (Some 3) (lastIndexOf "日" "日本語日")

-- Reference semantics for countOccurrences and lastIndexOf, compared
-- codepoint by codepoint.  They are the definitions the native externs
-- replaced, so the differential below pins the new behaviour to them.

refStartsWith : String -> String -> Bool
-- Oracle: the codepoint definition the native extern replaced, kept on purpose.
-- lint-disable-next-line rule-stdlib-reimpl
refStartsWith p s = stringSlice 0 (stringLength p) s == p

refEndsWith : String -> String -> Bool
-- Oracle: the codepoint definition the native extern replaced, kept on purpose.
-- lint-disable-next-line rule-stdlib-reimpl
refEndsWith p s =
  stringSlice (stringLength s - stringLength p) (stringLength s) s == p

refCountOccurrences : String -> String -> Int
-- Oracle: the codepoint definition the native extern replaced, kept on purpose.
-- lint-disable-next-line rule-stdlib-reimpl
refCountOccurrences needle hay
  | needle == "" = 0
  | otherwise = refCountGo needle hay 0 0

refCountGo : String -> String -> Int -> Int -> Int
refCountGo needle hay i acc
  | i + stringLength needle > stringLength hay = acc
  | stringSlice i (i + stringLength needle) hay == needle =
    refCountGo needle hay (i + stringLength needle) (acc + 1)
  | otherwise = refCountGo needle hay (i + 1) acc

refLastIndexOf : String -> String -> Option Int
-- Oracle: the codepoint definition the native extern replaced, kept on purpose.
-- lint-disable-next-line rule-stdlib-reimpl
refLastIndexOf needle hay
  | needle == "" = Some (stringLength hay)
  | otherwise = refLastGo needle hay 0 None

refLastGo : String -> String -> Int -> Option Int -> Option Int
refLastGo needle hay i acc
  | i + stringLength needle > stringLength hay = acc
  | stringSlice i (i + stringLength needle) hay == needle =
    refLastGo needle hay (i + 1) (Some i)
  | otherwise = refLastGo needle hay (i + 1) acc

edgePairs : List (String, String)
edgePairs = [
  ("", ""),
  ("", "abc"),
  ("a", ""),
  ("aa", "aaaa"),
  ("aa", "aaa"),
  ("aa", "a"),
  ("aba", "ababa"),
  ("ab", "xabab"),
  ("x", "xxxxx"),
  ("ll", "lllll"),
  ("z", "hello"),
  ("é", "éaé"),
  ("é", "ééé"),
  ("éé", "ééé"),
  ("日本", "日本語日本"),
  ("日", "a日日b"),
  ("😀", "a😀😀b"),
  ("ééé", "éé"),
  ("abc", "ab"),
  ("é", ""),
]

refPairs : (String -> String -> a) -> List (String, String) -> List a
refPairs _ [] = []
refPairs f ((n, h) :: rest) = f n h :: refPairs f rest

test "startsWith agrees with the codepoint reference on edge inputs" =
  expectEqual (refPairs refStartsWith edgePairs) (refPairs startsWith edgePairs)

test "endsWith agrees with the codepoint reference on edge inputs" =
  expectEqual (refPairs refEndsWith edgePairs) (refPairs endsWith edgePairs)

test "countOccurrences agrees with the codepoint reference on edge inputs" =
  expectEqual
    (refPairs refCountOccurrences edgePairs)
    (refPairs countOccurrences edgePairs)

test "lastIndexOf agrees with the codepoint reference on edge inputs" =
  expectEqual
    (refPairs refLastIndexOf edgePairs)
    (refPairs lastIndexOf edgePairs)

-- # Native toInt, reverse and join

test "toInt reads a signed decimal" =
  expectEqual (Some 42, Some (-7), Some 7) (toInt "42", toInt "-7", toInt "+7")

test "toInt of an empty or sign-only string is None" =
  expectEqual (None, None, None) (toInt "", toInt "-", toInt "+")

test "toInt rejects trailing and leading junk" =
  expectEqual
    (None, None, None, None)
    (toInt "12x", toInt "x12", toInt "--1", toInt " 1")

test "toInt rejects a non-ASCII digit" =
  expectEqual (None, None) (toInt "1é", toInt "٣")

test "toInt accepts leading zeros and negative zero" =
  expectEqual (Some 7, Some 0, Some 0) (toInt "007", toInt "-0", toInt "+0")

test "toInt holds the Int bounds" =
  expectEqual
    (Some 4611686018427387903, Some -4611686018427387904)
    (toInt "4611686018427387903", toInt "-4611686018427387904")

test "toInt rejects one past either Int bound" =
  expectEqual
    (None, None)
    (toInt "4611686018427387904", toInt "-4611686018427387905")

test "toInt rejects a value far outside the Int range" =
  expectEqual
    (None, None, None)
    (
      toInt "99999999999999999999",
      toInt "-99999999999999999999",
      toInt "9223372036854775807",
    )

test "reverse keeps multibyte codepoints whole" =
  expectEqual ("óH", "本日", "b😀a") (reverse "Hó", reverse "日本", reverse "a😀b")

test "reverse of the empty string is empty" = expectEqual "" (reverse "")

test "join puts the separator between each adjacent pair" =
  expectEqual
    ("a, b, c", "", "a-b")
    (join ", " ["a", "b", "c"], join "" ["", ""], join "-" ["a", "b"])

test "join of nothing and of one part" =
  expectEqual ("", "x") (join ", " [], join ", " ["x"])

test "unwords joins with single spaces" =
  expectEqual "a b  c" (unwords ["a", "b", "", "c"])

-- Reference definitions for toInt, reverse and join: the Medaka code the
-- native externs replaced, kept so the differential below pins the new
-- behaviour to it.  They walk Arrays of Char, one codepoint at a time.

refIsDigit : Char -> Bool
-- Oracle: the digit test the Medaka parser used, kept on purpose.
-- lint-disable-next-line rule-stdlib-reimpl
refIsDigit c = c >= '0' && c <= '9'

refToInt : String -> Option Int
-- Oracle: the Medaka parser the native stringToInt replaced, kept on purpose.
-- lint-disable-next-line rule-stdlib-reimpl
refToInt s =
  let a = stringToChars s
  refParseInt a (arrayLength a)

refParseInt : Array Char -> Int -> Option Int
refParseInt a n = if n == 0 then None else refParseSign a n (arrayGetUnsafe 0 a)

refParseSign : Array Char -> Int -> Char -> Option Int
refParseSign a n c
  | c == '-' = refParseDigits a n 1 0 False True
  | c == '+' = refParseDigits a n 1 0 False False
  | otherwise = refParseDigits a n 0 0 False False

refParseDigits : Array Char -> Int -> Int -> Int -> Bool -> Bool -> Option Int
refParseDigits a n i acc seen negative
  | i >= n = refFinishInt seen acc negative
  | otherwise = refParseDigitStep a n i acc seen negative (arrayGetUnsafe i a)

refParseDigitStep : Array Char ->
  Int ->
  Int ->
  Int ->
  Bool ->
  Bool ->
  Char ->
  Option Int
refParseDigitStep a n i acc seen negative c =
  if refIsDigit c then
    let d = charCode c - 48
    let limit = if negative then intMinBound else 0 - intMaxBound
    let multMin = limit / 10
    if acc < multMin then
      None
    else
      let acc2 = acc * 10
      if acc2 < limit + d then
        None
      else
        refParseDigits a n (i + 1) (acc2 - d) True negative
  else
    None

refFinishInt : Bool -> Int -> Bool -> Option Int
refFinishInt seen acc negative =
  if not seen then None else if negative then Some acc else Some (0 - acc)

refReverse : String -> String
-- Oracle: the codepoint reversal the native stringReverse replaced.
-- lint-disable-next-line rule-stdlib-reimpl
refReverse s =
  let a = stringToChars s
  let n = arrayLength a
  stringFromChars (arrayMakeWith n (i => arrayGetUnsafe (n - 1 - i) a))

refIntersperse : a -> List a -> List a
-- Oracle: the separator walk the Medaka join used, kept on purpose.
-- lint-disable-next-line rule-stdlib-reimpl
refIntersperse _ [] = []
refIntersperse _ (x :: []) = [x]
refIntersperse sep (x :: xs) = x :: sep :: refIntersperse sep xs

refJoin : String -> List String -> String
-- Oracle: the intersperse-then-concat definition the native stringJoin replaced.
-- lint-disable-next-line rule-stdlib-reimpl
refJoin sep parts = stringConcat (refIntersperse sep parts)

intTextEdges : List String
intTextEdges = [
  "",
  "-",
  "+",
  "0",
  "-0",
  "+0",
  "007",
  "-7",
  "+7",
  "42",
  "12x",
  "x12",
  "--1",
  "+-1",
  "-+1",
  " 1",
  "1 ",
  "1é",
  "é1",
  "٣",
  "1\n",
  "00000000000000000000001",
  "4611686018427387903",
  "4611686018427387904",
  "-4611686018427387904",
  "-4611686018427387905",
  "461168601842738790",
  "-461168601842738790",
  "4611686018427387900",
  "9223372036854775807",
  "-9223372036854775808",
  "99999999999999999999",
  "-99999999999999999999",
  "1234567890",
]

reverseEdges : List String
reverseEdges = [
  "",
  "a",
  "ab",
  "abc",
  "héllo",
  "日本語",
  "a😀b",
  "é",
  "👍🏽x",
  "ééé",
  "a\nb",
  "日a本",
]

joinEdges : List (String, List String)
joinEdges = [
  (", ", []),
  (", ", ["a"]),
  ("", ["a", "b"]),
  (", ", ["a", "b", "c"]),
  ("é", ["日", "本"]),
  ("日本", ["", "x", ""]),
  ("-", ["", ""]),
  (" ", ["a😀", "b"]),
  ("", []),
  ("", [""]),
]

test "toInt agrees with the Medaka reference on edge inputs" =
  expectEqual (refPairs2 refToInt intTextEdges) (refPairs2 toInt intTextEdges)

test "reverse agrees with the codepoint reference on edge inputs" =
  expectEqual
    (refPairs2 refReverse reverseEdges)
    (refPairs2 reverse reverseEdges)

test "join agrees with the intersperse reference on edge inputs" =
  expectEqual (refJoinPairs refJoin joinEdges) (refJoinPairs join joinEdges)

refPairs2 : (String -> a) -> List String -> List a
refPairs2 f xs = map f xs

refJoinPairs : (String -> List String -> String) ->
  List (String, List String) ->
  List String
refJoinPairs _ [] = []
refJoinPairs f ((sep, parts) :: rest) = f sep parts :: refJoinPairs f rest

prop "toInt reads back every decimal Int" (n : Int) =
  toInt (intToString n) == Some n

prop "reverse is an involution" (s : String) = reverse (reverse s) == s

prop "join with the empty separator is concat" (s : String) =
  join "" [s, s] == s ++ s

test "join keeps an exact codepoint length on multibyte text" =
  expectEqual 7 (stringLength (join "→" ["é", "日本", "", "x"]))

test "join with an empty separator keeps an exact codepoint length" =
  expectEqual 2 (stringLength (join "" ["é", "日"]))

test "reverse keeps an exact codepoint length on multibyte text" =
  expectEqual 4 (stringLength (reverse "é日→😀"))

-- # Native searches over haystacks longer than one 8-byte block

alphabet36 : String
alphabet36 = "abcdefghijklmnopqrstuvwxyz0123456789"

test "indexOf finds a needle at the start of a long string" =
  expectEqual (Some 0) (indexOf "abc" alphabet36)

test "indexOf finds a needle in the middle of a long string" =
  expectEqual (Some 12) (indexOf "mno" alphabet36)

test "indexOf finds a needle at the end of a long string" =
  expectEqual (Some 33) (indexOf "789" alphabet36)

test "indexOf misses a needle absent from a long string" =
  expectEqual None (indexOf "9a" alphabet36)

test "lastIndexOf and countOccurrences find one hit at the end" =
  expectEqual
    (Some 33, 1)
    (lastIndexOf "789" alphabet36, countOccurrences "789" alphabet36)

test "an empty needle on a long string is at 0, at the end, and counts 0" =
  expectEqual
    (Some 0, Some 36, 0)
    (
      indexOf "" alphabet36,
      lastIndexOf "" alphabet36,
      countOccurrences "" alphabet36,
    )

test "a needle equal to a long haystack hits once at 0" =
  expectEqual
    (Some 0, Some 0, 1, True)
    (
      indexOf alphabet36 alphabet36,
      lastIndexOf alphabet36 alphabet36,
      countOccurrences alphabet36 alphabet36,
      startsWith alphabet36 alphabet36,
    )

test "a needle longer than a long haystack misses everywhere" =
  let longer = alphabet36 ++ "!"
  expectEqual
    (None, None, 0, False, False)
    (
      indexOf longer alphabet36,
      lastIndexOf longer alphabet36,
      countOccurrences longer alphabet36,
      startsWith longer alphabet36,
      endsWith longer alphabet36,
    )

test "countOccurrences of an overlapping run takes non-overlapping matches" =
  let run = "aaaaaaaaaaaaaaaaaaaaa"
  expectEqual
    (Some 0, Some (stringLength run - 3), stringLength run / 3)
    (
      indexOf "aaa" run,
      lastIndexOf "aaa" run,
      countOccurrences "aaa" run,
    )

test "lastIndexOf finds the end hit across a block boundary" =
  let s = "abxxxxxxxxxxxxxxxxxxxxxxxxab"
  expectEqual
    (Some 0, Some (stringLength s - 2), 2)
    (indexOf "ab" s, lastIndexOf "ab" s, countOccurrences "ab" s)

test "a window whose first and last bytes match but whose middle does not" =
  let hay = "aYbaYbaXb" ++ "qqqqqqqqqq"
  expectEqual (Some 6, 1) (indexOf "aXb" hay, countOccurrences "aXb" hay)

test "indexOf of a multibyte needle past a block returns a codepoint index" =
  let s = "abcdefgé日xyz"
  expectEqual
    (Some 8, Some 9, Some 7)
    (indexOf "日" s, indexOf "xyz" s, lastIndexOf "é" s)

test "multibyte needles on a long multibyte string" =
  let t = "日本語日本語日本語日本語"
  expectEqual
    (Some 2, Some 8, 3)
    (indexOf "語日" t, lastIndexOf "語日" t, countOccurrences "語日" t)

test "startsWith and endsWith on a long string" =
  expectEqual
    (True, True, False, False)
    (
      startsWith "abcdefghi" alphabet36,
      endsWith "6789" alphabet36,
      startsWith "bcd" alphabet36,
      endsWith "abc" alphabet36,
    )

prop "indexOf of a prefix is 0" (s : String) =
  indexOf (stringSlice 0 3 s) s == Some 0

prop "lastIndexOf of a two-codepoint suffix ends at the end" (s : String) =
  if stringLength s < 2 then
    True
  else
    lastIndexOf (stringSlice (stringLength s - 2) (stringLength s) s) s
      == Some (stringLength s - 2)
# DESUGAR
(DUse false (UseGroup ("string") ((mem "byteLength" false) (mem "center" false) (mem "countOccurrences" false) (mem "drop" false) (mem "endsWith" false) (mem "fromChars" false) (mem "indexOf" false) (mem "join" false) (mem "lastIndexOf" false) (mem "lines" false) (mem "padLeft" false) (mem "padRight" false) (mem "replace" false) (mem "replaceAll" false) (mem "reverse" false) (mem "splitAt" false) (mem "startsWith" false) (mem "stripPrefix" false) (mem "stripSuffix" false) (mem "take" false) (mem "toInt" false) (mem "trim" false) (mem "trimLeft" false) (mem "trimRight" false) (mem "unlines" false) (mem "unwords" false) (mem "utf8ByteLength" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectFalse" false) (mem "expectTrue" false))))
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
(DTest false "startsWith the empty prefix is True" (EApp (EVar "expectTrue") (EApp (EApp (EVar "startsWith") (ELit (LString ""))) (ELit (LString "")))))
(DTest false "startsWith a prefix longer than the string is False" (EApp (EVar "expectFalse") (EApp (EApp (EVar "startsWith") (ELit (LString "hello!"))) (ELit (LString "hello")))))
(DTest false "startsWith compares whole codepoints of multibyte text" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "True") (EVar "False"))) (ETuple (EApp (EApp (EVar "startsWith") (ELit (LString "日"))) (ELit (LString "日本"))) (EApp (EApp (EVar "startsWith") (ELit (LString "日本"))) (ELit (LString "日"))))))
(DTest false "endsWith the empty suffix is True" (EApp (EVar "expectTrue") (EApp (EApp (EVar "endsWith") (ELit (LString ""))) (ELit (LString "")))))
(DTest false "endsWith a suffix longer than the string is False" (EApp (EVar "expectFalse") (EApp (EApp (EVar "endsWith") (ELit (LString "xhello"))) (ELit (LString "hello")))))
(DTest false "endsWith of a multibyte suffix" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "True") (EVar "False"))) (ETuple (EApp (EApp (EVar "endsWith") (ELit (LString "語"))) (ELit (LString "日本語"))) (EApp (EApp (EVar "endsWith") (ELit (LString "本"))) (ELit (LString "日本語"))))))
(DTest false "stripPrefix and stripSuffix on multibyte text" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LString "本語"))) (EApp (EVar "Some") (ELit (LString "日本"))))) (ETuple (EApp (EApp (EVar "stripPrefix") (ELit (LString "日"))) (ELit (LString "日本語"))) (EApp (EApp (EVar "stripSuffix") (ELit (LString "語"))) (ELit (LString "日本語"))))))
(DTest false "countOccurrences of an empty needle is 0" (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EApp (EApp (EVar "countOccurrences") (ELit (LString ""))) (ELit (LString "héllo")))))
(DTest false "countOccurrences does not count overlapping matches in multibyte text" (EApp (EApp (EVar "expectEqual") (ELit (LInt 2))) (EApp (EApp (EVar "countOccurrences") (ELit (LString "éé"))) (ELit (LString "ééé é ééé")))))
(DTest false "countOccurrences finds multibyte needles" (EApp (EApp (EVar "expectEqual") (ELit (LInt 3))) (EApp (EApp (EVar "countOccurrences") (ELit (LString "日"))) (ELit (LString "日a日日")))))
(DTest false "lastIndexOf of a needle longer than the haystack is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "hello!"))) (ELit (LString "hello")))))
(DTest false "lastIndexOf keeps the last overlapping match in a run" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 3)))) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "aa"))) (ELit (LString "aaaaa")))))
(DTest false "lastIndexOf returns the codepoint index past a multibyte prefix" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 3)))) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "日"))) (ELit (LString "日本語日")))))
(DTypeSig false "refStartsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "refStartsWith" ((PVar "p") (PVar "s")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "p"))) (EVar "s")) (EVar "p")))
(DTypeSig false "refEndsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "refEndsWith" ((PVar "p") (PVar "s")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EVar "p")))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "p")))
(DTypeSig false "refCountOccurrences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "refCountOccurrences" ((PVar "needle") (PVar "hay")) (EIf (EBinOp "==" (EVar "needle") (ELit (LString ""))) (ELit (LInt 0)) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "refCountGo") (EVar "needle")) (EVar "hay")) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refCountGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "refCountGo" ((PVar "needle") (PVar "hay") (PVar "i") (PVar "acc")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "needle"))) (EApp (EVar "stringLength") (EVar "hay"))) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "needle")))) (EVar "hay")) (EVar "needle")) (EApp (EApp (EApp (EApp (EVar "refCountGo") (EVar "needle")) (EVar "hay")) (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "needle")))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "refCountGo") (EVar "needle")) (EVar "hay")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "refLastIndexOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "refLastIndexOf" ((PVar "needle") (PVar "hay")) (EIf (EBinOp "==" (EVar "needle") (ELit (LString ""))) (EApp (EVar "Some") (EApp (EVar "stringLength") (EVar "hay"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "refLastGo") (EVar "needle")) (EVar "hay")) (ELit (LInt 0))) (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refLastGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "refLastGo" ((PVar "needle") (PVar "hay") (PVar "i") (PVar "acc")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "needle"))) (EApp (EVar "stringLength") (EVar "hay"))) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "needle")))) (EVar "hay")) (EVar "needle")) (EApp (EApp (EApp (EApp (EVar "refLastGo") (EVar "needle")) (EVar "hay")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "Some") (EVar "i"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "refLastGo") (EVar "needle")) (EVar "hay")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "edgePairs" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "edgePairs" () (EListLit (ETuple (ELit (LString "")) (ELit (LString ""))) (ETuple (ELit (LString "")) (ELit (LString "abc"))) (ETuple (ELit (LString "a")) (ELit (LString ""))) (ETuple (ELit (LString "aa")) (ELit (LString "aaaa"))) (ETuple (ELit (LString "aa")) (ELit (LString "aaa"))) (ETuple (ELit (LString "aa")) (ELit (LString "a"))) (ETuple (ELit (LString "aba")) (ELit (LString "ababa"))) (ETuple (ELit (LString "ab")) (ELit (LString "xabab"))) (ETuple (ELit (LString "x")) (ELit (LString "xxxxx"))) (ETuple (ELit (LString "ll")) (ELit (LString "lllll"))) (ETuple (ELit (LString "z")) (ELit (LString "hello"))) (ETuple (ELit (LString "é")) (ELit (LString "éaé"))) (ETuple (ELit (LString "é")) (ELit (LString "ééé"))) (ETuple (ELit (LString "éé")) (ELit (LString "ééé"))) (ETuple (ELit (LString "日本")) (ELit (LString "日本語日本"))) (ETuple (ELit (LString "日")) (ELit (LString "a日日b"))) (ETuple (ELit (LString "😀")) (ELit (LString "a😀😀b"))) (ETuple (ELit (LString "ééé")) (ELit (LString "éé"))) (ETuple (ELit (LString "abc")) (ELit (LString "ab"))) (ETuple (ELit (LString "é")) (ELit (LString "")))))
(DTypeSig false "refPairs" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "refPairs" (PWild (PList)) (EListLit))
(DFunDef false "refPairs" ((PVar "f") (PCons (PTuple (PVar "n") (PVar "h")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "f") (EVar "n")) (EVar "h")) (EApp (EApp (EVar "refPairs") (EVar "f")) (EVar "rest"))))
(DTest false "startsWith agrees with the codepoint reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refPairs") (EVar "refStartsWith")) (EVar "edgePairs"))) (EApp (EApp (EVar "refPairs") (EVar "startsWith")) (EVar "edgePairs"))))
(DTest false "endsWith agrees with the codepoint reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refPairs") (EVar "refEndsWith")) (EVar "edgePairs"))) (EApp (EApp (EVar "refPairs") (EVar "endsWith")) (EVar "edgePairs"))))
(DTest false "countOccurrences agrees with the codepoint reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refPairs") (EVar "refCountOccurrences")) (EVar "edgePairs"))) (EApp (EApp (EVar "refPairs") (EVar "countOccurrences")) (EVar "edgePairs"))))
(DTest false "lastIndexOf agrees with the codepoint reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refPairs") (EVar "refLastIndexOf")) (EVar "edgePairs"))) (EApp (EApp (EVar "refPairs") (EVar "lastIndexOf")) (EVar "edgePairs"))))
(DTest false "toInt reads a signed decimal" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 42))) (EApp (EVar "Some") (EUnOp "-" (ELit (LInt 7)))) (EApp (EVar "Some") (ELit (LInt 7))))) (ETuple (EApp (EVar "toInt") (ELit (LString "42"))) (EApp (EVar "toInt") (ELit (LString "-7"))) (EApp (EVar "toInt") (ELit (LString "+7"))))))
(DTest false "toInt of an empty or sign-only string is None" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "None") (EVar "None") (EVar "None"))) (ETuple (EApp (EVar "toInt") (ELit (LString ""))) (EApp (EVar "toInt") (ELit (LString "-"))) (EApp (EVar "toInt") (ELit (LString "+"))))))
(DTest false "toInt rejects trailing and leading junk" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "None") (EVar "None") (EVar "None") (EVar "None"))) (ETuple (EApp (EVar "toInt") (ELit (LString "12x"))) (EApp (EVar "toInt") (ELit (LString "x12"))) (EApp (EVar "toInt") (ELit (LString "--1"))) (EApp (EVar "toInt") (ELit (LString " 1"))))))
(DTest false "toInt rejects a non-ASCII digit" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "None") (EVar "None"))) (ETuple (EApp (EVar "toInt") (ELit (LString "1é"))) (EApp (EVar "toInt") (ELit (LString "٣"))))))
(DTest false "toInt accepts leading zeros and negative zero" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 7))) (EApp (EVar "Some") (ELit (LInt 0))) (EApp (EVar "Some") (ELit (LInt 0))))) (ETuple (EApp (EVar "toInt") (ELit (LString "007"))) (EApp (EVar "toInt") (ELit (LString "-0"))) (EApp (EVar "toInt") (ELit (LString "+0"))))))
(DTest false "toInt holds the Int bounds" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 4611686018427387903))) (EApp (EVar "Some") (ELit (LInt -4611686018427387904))))) (ETuple (EApp (EVar "toInt") (ELit (LString "4611686018427387903"))) (EApp (EVar "toInt") (ELit (LString "-4611686018427387904"))))))
(DTest false "toInt rejects one past either Int bound" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "None") (EVar "None"))) (ETuple (EApp (EVar "toInt") (ELit (LString "4611686018427387904"))) (EApp (EVar "toInt") (ELit (LString "-4611686018427387905"))))))
(DTest false "toInt rejects a value far outside the Int range" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "None") (EVar "None") (EVar "None"))) (ETuple (EApp (EVar "toInt") (ELit (LString "99999999999999999999"))) (EApp (EVar "toInt") (ELit (LString "-99999999999999999999"))) (EApp (EVar "toInt") (ELit (LString "9223372036854775807"))))))
(DTest false "reverse keeps multibyte codepoints whole" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "óH")) (ELit (LString "本日")) (ELit (LString "b😀a")))) (ETuple (EApp (EVar "reverse") (ELit (LString "Hó"))) (EApp (EVar "reverse") (ELit (LString "日本"))) (EApp (EVar "reverse") (ELit (LString "a😀b"))))))
(DTest false "reverse of the empty string is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EVar "reverse") (ELit (LString "")))))
(DTest false "join puts the separator between each adjacent pair" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "a, b, c")) (ELit (LString "")) (ELit (LString "a-b")))) (ETuple (EApp (EApp (EVar "join") (ELit (LString ", "))) (EListLit (ELit (LString "a")) (ELit (LString "b")) (ELit (LString "c")))) (EApp (EApp (EVar "join") (ELit (LString ""))) (EListLit (ELit (LString "")) (ELit (LString "")))) (EApp (EApp (EVar "join") (ELit (LString "-"))) (EListLit (ELit (LString "a")) (ELit (LString "b")))))))
(DTest false "join of nothing and of one part" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "x")))) (ETuple (EApp (EApp (EVar "join") (ELit (LString ", "))) (EListLit)) (EApp (EApp (EVar "join") (ELit (LString ", "))) (EListLit (ELit (LString "x")))))))
(DTest false "unwords joins with single spaces" (EApp (EApp (EVar "expectEqual") (ELit (LString "a b  c"))) (EApp (EVar "unwords") (EListLit (ELit (LString "a")) (ELit (LString "b")) (ELit (LString "")) (ELit (LString "c"))))))
(DTypeSig false "refIsDigit" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "refIsDigit" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9")))))
(DTypeSig false "refToInt" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "refToInt" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EVar "refParseInt") (EVar "a")) (EApp (EVar "arrayLength") (EVar "a"))))))
(DTypeSig false "refParseInt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "refParseInt" ((PVar "a") (PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "None") (EApp (EApp (EApp (EVar "refParseSign") (EVar "a")) (EVar "n")) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "a")))))
(DTypeSig false "refParseSign" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "refParseSign" ((PVar "a") (PVar "n") (PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "refParseDigits") (EVar "a")) (EVar "n")) (ELit (LInt 1))) (ELit (LInt 0))) (EVar "False")) (EVar "True")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "+"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "refParseDigits") (EVar "a")) (EVar "n")) (ELit (LInt 1))) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "refParseDigits") (EVar "a")) (EVar "n")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "refParseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "refParseDigits" ((PVar "a") (PVar "n") (PVar "i") (PVar "acc") (PVar "seen") (PVar "negative")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EApp (EApp (EVar "refFinishInt") (EVar "seen")) (EVar "acc")) (EVar "negative")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "refParseDigitStep") (EVar "a")) (EVar "n")) (EVar "i")) (EVar "acc")) (EVar "seen")) (EVar "negative")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refParseDigitStep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "refParseDigitStep" ((PVar "a") (PVar "n") (PVar "i") (PVar "acc") (PVar "seen") (PVar "negative") (PVar "c")) (EIf (EApp (EVar "refIsDigit") (EVar "c")) (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48)))) (DoLet false false (PVar "limit") (EIf (EVar "negative") (EVar "intMinBound") (EBinOp "-" (ELit (LInt 0)) (EVar "intMaxBound")))) (DoLet false false (PVar "multMin") (EBinOp "/" (EVar "limit") (ELit (LInt 10)))) (DoExpr (EIf (EBinOp "<" (EVar "acc") (EVar "multMin")) (EVar "None") (EBlock (DoLet false false (PVar "acc2") (EBinOp "*" (EVar "acc") (ELit (LInt 10)))) (DoExpr (EIf (EBinOp "<" (EVar "acc2") (EBinOp "+" (EVar "limit") (EVar "d"))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "refParseDigits") (EVar "a")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "acc2") (EVar "d"))) (EVar "True")) (EVar "negative")))))))) (EVar "None")))
(DTypeSig false "refFinishInt" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "refFinishInt" ((PVar "seen") (PVar "acc") (PVar "negative")) (EIf (EApp (EVar "not") (EVar "seen")) (EVar "None") (EIf (EVar "negative") (EApp (EVar "Some") (EVar "acc")) (EApp (EVar "Some") (EBinOp "-" (ELit (LInt 0)) (EVar "acc"))))))
(DTypeSig false "refReverse" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "refReverse" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "a"))) (DoExpr (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EBinOp "-" (EVar "n") (ELit (LInt 1))) (EVar "i"))) (EVar "a"))))))))
(DTypeSig false "refIntersperse" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "refIntersperse" (PWild (PList)) (EListLit))
(DFunDef false "refIntersperse" (PWild (PCons (PVar "x") (PList))) (EListLit (EVar "x")))
(DFunDef false "refIntersperse" ((PVar "sep") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "sep") (EApp (EApp (EVar "refIntersperse") (EVar "sep")) (EVar "xs")))))
(DTypeSig false "refJoin" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "refJoin" ((PVar "sep") (PVar "parts")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "refIntersperse") (EVar "sep")) (EVar "parts"))))
(DTypeSig false "intTextEdges" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "intTextEdges" () (EListLit (ELit (LString "")) (ELit (LString "-")) (ELit (LString "+")) (ELit (LString "0")) (ELit (LString "-0")) (ELit (LString "+0")) (ELit (LString "007")) (ELit (LString "-7")) (ELit (LString "+7")) (ELit (LString "42")) (ELit (LString "12x")) (ELit (LString "x12")) (ELit (LString "--1")) (ELit (LString "+-1")) (ELit (LString "-+1")) (ELit (LString " 1")) (ELit (LString "1 ")) (ELit (LString "1é")) (ELit (LString "é1")) (ELit (LString "٣")) (ELit (LString "1\n")) (ELit (LString "00000000000000000000001")) (ELit (LString "4611686018427387903")) (ELit (LString "4611686018427387904")) (ELit (LString "-4611686018427387904")) (ELit (LString "-4611686018427387905")) (ELit (LString "461168601842738790")) (ELit (LString "-461168601842738790")) (ELit (LString "4611686018427387900")) (ELit (LString "9223372036854775807")) (ELit (LString "-9223372036854775808")) (ELit (LString "99999999999999999999")) (ELit (LString "-99999999999999999999")) (ELit (LString "1234567890"))))
(DTypeSig false "reverseEdges" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "reverseEdges" () (EListLit (ELit (LString "")) (ELit (LString "a")) (ELit (LString "ab")) (ELit (LString "abc")) (ELit (LString "héllo")) (ELit (LString "日本語")) (ELit (LString "a😀b")) (ELit (LString "é")) (ELit (LString "👍🏽x")) (ELit (LString "ééé")) (ELit (LString "a\nb")) (ELit (LString "日a本"))))
(DTypeSig false "joinEdges" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "joinEdges" () (EListLit (ETuple (ELit (LString ", ")) (EListLit)) (ETuple (ELit (LString ", ")) (EListLit (ELit (LString "a")))) (ETuple (ELit (LString "")) (EListLit (ELit (LString "a")) (ELit (LString "b")))) (ETuple (ELit (LString ", ")) (EListLit (ELit (LString "a")) (ELit (LString "b")) (ELit (LString "c")))) (ETuple (ELit (LString "é")) (EListLit (ELit (LString "日")) (ELit (LString "本")))) (ETuple (ELit (LString "日本")) (EListLit (ELit (LString "")) (ELit (LString "x")) (ELit (LString "")))) (ETuple (ELit (LString "-")) (EListLit (ELit (LString "")) (ELit (LString "")))) (ETuple (ELit (LString " ")) (EListLit (ELit (LString "a😀")) (ELit (LString "b")))) (ETuple (ELit (LString "")) (EListLit)) (ETuple (ELit (LString "")) (EListLit (ELit (LString ""))))))
(DTest false "toInt agrees with the Medaka reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refPairs2") (EVar "refToInt")) (EVar "intTextEdges"))) (EApp (EApp (EVar "refPairs2") (EVar "toInt")) (EVar "intTextEdges"))))
(DTest false "reverse agrees with the codepoint reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refPairs2") (EVar "refReverse")) (EVar "reverseEdges"))) (EApp (EApp (EVar "refPairs2") (EVar "reverse")) (EVar "reverseEdges"))))
(DTest false "join agrees with the intersperse reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refJoinPairs") (EVar "refJoin")) (EVar "joinEdges"))) (EApp (EApp (EVar "refJoinPairs") (EVar "join")) (EVar "joinEdges"))))
(DTypeSig false "refPairs2" (TyFun (TyFun (TyCon "String") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "refPairs2" ((PVar "f") (PVar "xs")) (EApp (EApp (EVar "map") (EVar "f")) (EVar "xs")))
(DTypeSig false "refJoinPairs" (TyFun (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "refJoinPairs" (PWild (PList)) (EListLit))
(DFunDef false "refJoinPairs" ((PVar "f") (PCons (PTuple (PVar "sep") (PVar "parts")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "f") (EVar "sep")) (EVar "parts")) (EApp (EApp (EVar "refJoinPairs") (EVar "f")) (EVar "rest"))))
(DProp false "toInt reads back every decimal Int" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "toInt") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "Some") (EVar "n"))))
(DProp false "reverse is an involution" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EVar "reverse") (EApp (EVar "reverse") (EVar "s"))) (EVar "s")))
(DProp false "join with the empty separator is concat" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EApp (EVar "join") (ELit (LString ""))) (EListLit (EVar "s") (EVar "s"))) (EBinOp "++" (EVar "s") (EVar "s"))))
(DTest false "join keeps an exact codepoint length on multibyte text" (EApp (EApp (EVar "expectEqual") (ELit (LInt 7))) (EApp (EVar "stringLength") (EApp (EApp (EVar "join") (ELit (LString "→"))) (EListLit (ELit (LString "é")) (ELit (LString "日本")) (ELit (LString "")) (ELit (LString "x")))))))
(DTest false "join with an empty separator keeps an exact codepoint length" (EApp (EApp (EVar "expectEqual") (ELit (LInt 2))) (EApp (EVar "stringLength") (EApp (EApp (EVar "join") (ELit (LString ""))) (EListLit (ELit (LString "é")) (ELit (LString "日")))))))
(DTest false "reverse keeps an exact codepoint length on multibyte text" (EApp (EApp (EVar "expectEqual") (ELit (LInt 4))) (EApp (EVar "stringLength") (EApp (EVar "reverse") (ELit (LString "é日→😀"))))))
(DTypeSig false "alphabet36" (TyCon "String"))
(DFunDef false "alphabet36" () (ELit (LString "abcdefghijklmnopqrstuvwxyz0123456789")))
(DTest false "indexOf finds a needle at the start of a long string" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 0)))) (EApp (EApp (EVar "indexOf") (ELit (LString "abc"))) (EVar "alphabet36"))))
(DTest false "indexOf finds a needle in the middle of a long string" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 12)))) (EApp (EApp (EVar "indexOf") (ELit (LString "mno"))) (EVar "alphabet36"))))
(DTest false "indexOf finds a needle at the end of a long string" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 33)))) (EApp (EApp (EVar "indexOf") (ELit (LString "789"))) (EVar "alphabet36"))))
(DTest false "indexOf misses a needle absent from a long string" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EVar "indexOf") (ELit (LString "9a"))) (EVar "alphabet36"))))
(DTest false "lastIndexOf and countOccurrences find one hit at the end" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 33))) (ELit (LInt 1)))) (ETuple (EApp (EApp (EVar "lastIndexOf") (ELit (LString "789"))) (EVar "alphabet36")) (EApp (EApp (EVar "countOccurrences") (ELit (LString "789"))) (EVar "alphabet36")))))
(DTest false "an empty needle on a long string is at 0, at the end, and counts 0" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 0))) (EApp (EVar "Some") (ELit (LInt 36))) (ELit (LInt 0)))) (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString ""))) (EVar "alphabet36")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString ""))) (EVar "alphabet36")) (EApp (EApp (EVar "countOccurrences") (ELit (LString ""))) (EVar "alphabet36")))))
(DTest false "a needle equal to a long haystack hits once at 0" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 0))) (EApp (EVar "Some") (ELit (LInt 0))) (ELit (LInt 1)) (EVar "True"))) (ETuple (EApp (EApp (EVar "indexOf") (EVar "alphabet36")) (EVar "alphabet36")) (EApp (EApp (EVar "lastIndexOf") (EVar "alphabet36")) (EVar "alphabet36")) (EApp (EApp (EVar "countOccurrences") (EVar "alphabet36")) (EVar "alphabet36")) (EApp (EApp (EVar "startsWith") (EVar "alphabet36")) (EVar "alphabet36")))))
(DTest false "a needle longer than a long haystack misses everywhere" (EBlock (DoLet false false (PVar "longer") (EBinOp "++" (EVar "alphabet36") (ELit (LString "!")))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EVar "None") (EVar "None") (ELit (LInt 0)) (EVar "False") (EVar "False"))) (ETuple (EApp (EApp (EVar "indexOf") (EVar "longer")) (EVar "alphabet36")) (EApp (EApp (EVar "lastIndexOf") (EVar "longer")) (EVar "alphabet36")) (EApp (EApp (EVar "countOccurrences") (EVar "longer")) (EVar "alphabet36")) (EApp (EApp (EVar "startsWith") (EVar "longer")) (EVar "alphabet36")) (EApp (EApp (EVar "endsWith") (EVar "longer")) (EVar "alphabet36")))))))
(DTest false "countOccurrences of an overlapping run takes non-overlapping matches" (EBlock (DoLet false false (PVar "run") (ELit (LString "aaaaaaaaaaaaaaaaaaaaa"))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 0))) (EApp (EVar "Some") (EBinOp "-" (EApp (EVar "stringLength") (EVar "run")) (ELit (LInt 3)))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "run")) (ELit (LInt 3))))) (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString "aaa"))) (EVar "run")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "aaa"))) (EVar "run")) (EApp (EApp (EVar "countOccurrences") (ELit (LString "aaa"))) (EVar "run")))))))
(DTest false "lastIndexOf finds the end hit across a block boundary" (EBlock (DoLet false false (PVar "s") (ELit (LString "abxxxxxxxxxxxxxxxxxxxxxxxxab"))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 0))) (EApp (EVar "Some") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2)))) (ELit (LInt 2)))) (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString "ab"))) (EVar "s")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "ab"))) (EVar "s")) (EApp (EApp (EVar "countOccurrences") (ELit (LString "ab"))) (EVar "s")))))))
(DTest false "a window whose first and last bytes match but whose middle does not" (EBlock (DoLet false false (PVar "hay") (EBinOp "++" (ELit (LString "aYbaYbaXb")) (ELit (LString "qqqqqqqqqq")))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 6))) (ELit (LInt 1)))) (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString "aXb"))) (EVar "hay")) (EApp (EApp (EVar "countOccurrences") (ELit (LString "aXb"))) (EVar "hay")))))))
(DTest false "indexOf of a multibyte needle past a block returns a codepoint index" (EBlock (DoLet false false (PVar "s") (ELit (LString "abcdefgé日xyz"))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 8))) (EApp (EVar "Some") (ELit (LInt 9))) (EApp (EVar "Some") (ELit (LInt 7))))) (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString "日"))) (EVar "s")) (EApp (EApp (EVar "indexOf") (ELit (LString "xyz"))) (EVar "s")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "é"))) (EVar "s")))))))
(DTest false "multibyte needles on a long multibyte string" (EBlock (DoLet false false (PVar "t") (ELit (LString "日本語日本語日本語日本語"))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 2))) (EApp (EVar "Some") (ELit (LInt 8))) (ELit (LInt 3)))) (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString "語日"))) (EVar "t")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "語日"))) (EVar "t")) (EApp (EApp (EVar "countOccurrences") (ELit (LString "語日"))) (EVar "t")))))))
(DTest false "startsWith and endsWith on a long string" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "True") (EVar "True") (EVar "False") (EVar "False"))) (ETuple (EApp (EApp (EVar "startsWith") (ELit (LString "abcdefghi"))) (EVar "alphabet36")) (EApp (EApp (EVar "endsWith") (ELit (LString "6789"))) (EVar "alphabet36")) (EApp (EApp (EVar "startsWith") (ELit (LString "bcd"))) (EVar "alphabet36")) (EApp (EApp (EVar "endsWith") (ELit (LString "abc"))) (EVar "alphabet36")))))
(DProp false "indexOf of a prefix is 0" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EApp (EVar "indexOf") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 3))) (EVar "s"))) (EVar "s")) (EApp (EVar "Some") (ELit (LInt 0)))))
(DProp false "lastIndexOf of a two-codepoint suffix ends at the end" ((pp "s" (TyCon "String"))) (EIf (EBinOp "<" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2))) (EVar "True") (EBinOp "==" (EApp (EApp (EVar "lastIndexOf") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (EVar "s")) (EApp (EVar "Some") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2)))))))
# MARK
(DUse false (UseGroup ("string") ((mem "byteLength" false) (mem "center" false) (mem "countOccurrences" false) (mem "drop" false) (mem "endsWith" false) (mem "fromChars" false) (mem "indexOf" false) (mem "join" false) (mem "lastIndexOf" false) (mem "lines" false) (mem "padLeft" false) (mem "padRight" false) (mem "replace" false) (mem "replaceAll" false) (mem "reverse" false) (mem "splitAt" false) (mem "startsWith" false) (mem "stripPrefix" false) (mem "stripSuffix" false) (mem "take" false) (mem "toInt" false) (mem "trim" false) (mem "trimLeft" false) (mem "trimRight" false) (mem "unlines" false) (mem "unwords" false) (mem "utf8ByteLength" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false) (mem "expectFalse" false) (mem "expectTrue" false))))
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
(DTest false "startsWith the empty prefix is True" (EApp (EVar "expectTrue") (EApp (EApp (EVar "startsWith") (ELit (LString ""))) (ELit (LString "")))))
(DTest false "startsWith a prefix longer than the string is False" (EApp (EVar "expectFalse") (EApp (EApp (EVar "startsWith") (ELit (LString "hello!"))) (ELit (LString "hello")))))
(DTest false "startsWith compares whole codepoints of multibyte text" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "True") (EVar "False"))) (ETuple (EApp (EApp (EVar "startsWith") (ELit (LString "日"))) (ELit (LString "日本"))) (EApp (EApp (EVar "startsWith") (ELit (LString "日本"))) (ELit (LString "日"))))))
(DTest false "endsWith the empty suffix is True" (EApp (EVar "expectTrue") (EApp (EApp (EVar "endsWith") (ELit (LString ""))) (ELit (LString "")))))
(DTest false "endsWith a suffix longer than the string is False" (EApp (EVar "expectFalse") (EApp (EApp (EVar "endsWith") (ELit (LString "xhello"))) (ELit (LString "hello")))))
(DTest false "endsWith of a multibyte suffix" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "True") (EVar "False"))) (ETuple (EApp (EApp (EVar "endsWith") (ELit (LString "語"))) (ELit (LString "日本語"))) (EApp (EApp (EVar "endsWith") (ELit (LString "本"))) (ELit (LString "日本語"))))))
(DTest false "stripPrefix and stripSuffix on multibyte text" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LString "本語"))) (EApp (EVar "Some") (ELit (LString "日本"))))) (ETuple (EApp (EApp (EVar "stripPrefix") (ELit (LString "日"))) (ELit (LString "日本語"))) (EApp (EApp (EVar "stripSuffix") (ELit (LString "語"))) (ELit (LString "日本語"))))))
(DTest false "countOccurrences of an empty needle is 0" (EApp (EApp (EVar "expectEqual") (ELit (LInt 0))) (EApp (EApp (EVar "countOccurrences") (ELit (LString ""))) (ELit (LString "héllo")))))
(DTest false "countOccurrences does not count overlapping matches in multibyte text" (EApp (EApp (EVar "expectEqual") (ELit (LInt 2))) (EApp (EApp (EVar "countOccurrences") (ELit (LString "éé"))) (ELit (LString "ééé é ééé")))))
(DTest false "countOccurrences finds multibyte needles" (EApp (EApp (EVar "expectEqual") (ELit (LInt 3))) (EApp (EApp (EVar "countOccurrences") (ELit (LString "日"))) (ELit (LString "日a日日")))))
(DTest false "lastIndexOf of a needle longer than the haystack is None" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "hello!"))) (ELit (LString "hello")))))
(DTest false "lastIndexOf keeps the last overlapping match in a run" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 3)))) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "aa"))) (ELit (LString "aaaaa")))))
(DTest false "lastIndexOf returns the codepoint index past a multibyte prefix" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 3)))) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "日"))) (ELit (LString "日本語日")))))
(DTypeSig false "refStartsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "refStartsWith" ((PVar "p") (PVar "s")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "p"))) (EVar "s")) (EVar "p")))
(DTypeSig false "refEndsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "refEndsWith" ((PVar "p") (PVar "s")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EVar "p")))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "p")))
(DTypeSig false "refCountOccurrences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "refCountOccurrences" ((PVar "needle") (PVar "hay")) (EIf (EBinOp "==" (EVar "needle") (ELit (LString ""))) (ELit (LInt 0)) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "refCountGo") (EVar "needle")) (EVar "hay")) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refCountGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "refCountGo" ((PVar "needle") (PVar "hay") (PVar "i") (PVar "acc")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "needle"))) (EApp (EVar "stringLength") (EVar "hay"))) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "needle")))) (EVar "hay")) (EVar "needle")) (EApp (EApp (EApp (EApp (EVar "refCountGo") (EVar "needle")) (EVar "hay")) (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "needle")))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "refCountGo") (EVar "needle")) (EVar "hay")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "refLastIndexOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "refLastIndexOf" ((PVar "needle") (PVar "hay")) (EIf (EBinOp "==" (EVar "needle") (ELit (LString ""))) (EApp (EVar "Some") (EApp (EVar "stringLength") (EVar "hay"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "refLastGo") (EVar "needle")) (EVar "hay")) (ELit (LInt 0))) (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refLastGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "refLastGo" ((PVar "needle") (PVar "hay") (PVar "i") (PVar "acc")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "needle"))) (EApp (EVar "stringLength") (EVar "hay"))) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "needle")))) (EVar "hay")) (EVar "needle")) (EApp (EApp (EApp (EApp (EVar "refLastGo") (EVar "needle")) (EVar "hay")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "Some") (EVar "i"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "refLastGo") (EVar "needle")) (EVar "hay")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "edgePairs" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "edgePairs" () (EListLit (ETuple (ELit (LString "")) (ELit (LString ""))) (ETuple (ELit (LString "")) (ELit (LString "abc"))) (ETuple (ELit (LString "a")) (ELit (LString ""))) (ETuple (ELit (LString "aa")) (ELit (LString "aaaa"))) (ETuple (ELit (LString "aa")) (ELit (LString "aaa"))) (ETuple (ELit (LString "aa")) (ELit (LString "a"))) (ETuple (ELit (LString "aba")) (ELit (LString "ababa"))) (ETuple (ELit (LString "ab")) (ELit (LString "xabab"))) (ETuple (ELit (LString "x")) (ELit (LString "xxxxx"))) (ETuple (ELit (LString "ll")) (ELit (LString "lllll"))) (ETuple (ELit (LString "z")) (ELit (LString "hello"))) (ETuple (ELit (LString "é")) (ELit (LString "éaé"))) (ETuple (ELit (LString "é")) (ELit (LString "ééé"))) (ETuple (ELit (LString "éé")) (ELit (LString "ééé"))) (ETuple (ELit (LString "日本")) (ELit (LString "日本語日本"))) (ETuple (ELit (LString "日")) (ELit (LString "a日日b"))) (ETuple (ELit (LString "😀")) (ELit (LString "a😀😀b"))) (ETuple (ELit (LString "ééé")) (ELit (LString "éé"))) (ETuple (ELit (LString "abc")) (ELit (LString "ab"))) (ETuple (ELit (LString "é")) (ELit (LString "")))))
(DTypeSig false "refPairs" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "refPairs" (PWild (PList)) (EListLit))
(DFunDef false "refPairs" ((PVar "f") (PCons (PTuple (PVar "n") (PVar "h")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "f") (EVar "n")) (EVar "h")) (EApp (EApp (EVar "refPairs") (EVar "f")) (EVar "rest"))))
(DTest false "startsWith agrees with the codepoint reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refPairs") (EVar "refStartsWith")) (EVar "edgePairs"))) (EApp (EApp (EVar "refPairs") (EVar "startsWith")) (EVar "edgePairs"))))
(DTest false "endsWith agrees with the codepoint reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refPairs") (EVar "refEndsWith")) (EVar "edgePairs"))) (EApp (EApp (EVar "refPairs") (EVar "endsWith")) (EVar "edgePairs"))))
(DTest false "countOccurrences agrees with the codepoint reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refPairs") (EVar "refCountOccurrences")) (EVar "edgePairs"))) (EApp (EApp (EVar "refPairs") (EVar "countOccurrences")) (EVar "edgePairs"))))
(DTest false "lastIndexOf agrees with the codepoint reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refPairs") (EVar "refLastIndexOf")) (EVar "edgePairs"))) (EApp (EApp (EVar "refPairs") (EVar "lastIndexOf")) (EVar "edgePairs"))))
(DTest false "toInt reads a signed decimal" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 42))) (EApp (EVar "Some") (EUnOp "-" (ELit (LInt 7)))) (EApp (EVar "Some") (ELit (LInt 7))))) (ETuple (EApp (EVar "toInt") (ELit (LString "42"))) (EApp (EVar "toInt") (ELit (LString "-7"))) (EApp (EVar "toInt") (ELit (LString "+7"))))))
(DTest false "toInt of an empty or sign-only string is None" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "None") (EVar "None") (EVar "None"))) (ETuple (EApp (EVar "toInt") (ELit (LString ""))) (EApp (EVar "toInt") (ELit (LString "-"))) (EApp (EVar "toInt") (ELit (LString "+"))))))
(DTest false "toInt rejects trailing and leading junk" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "None") (EVar "None") (EVar "None") (EVar "None"))) (ETuple (EApp (EVar "toInt") (ELit (LString "12x"))) (EApp (EVar "toInt") (ELit (LString "x12"))) (EApp (EVar "toInt") (ELit (LString "--1"))) (EApp (EVar "toInt") (ELit (LString " 1"))))))
(DTest false "toInt rejects a non-ASCII digit" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "None") (EVar "None"))) (ETuple (EApp (EVar "toInt") (ELit (LString "1é"))) (EApp (EVar "toInt") (ELit (LString "٣"))))))
(DTest false "toInt accepts leading zeros and negative zero" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 7))) (EApp (EVar "Some") (ELit (LInt 0))) (EApp (EVar "Some") (ELit (LInt 0))))) (ETuple (EApp (EVar "toInt") (ELit (LString "007"))) (EApp (EVar "toInt") (ELit (LString "-0"))) (EApp (EVar "toInt") (ELit (LString "+0"))))))
(DTest false "toInt holds the Int bounds" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 4611686018427387903))) (EApp (EVar "Some") (ELit (LInt -4611686018427387904))))) (ETuple (EApp (EVar "toInt") (ELit (LString "4611686018427387903"))) (EApp (EVar "toInt") (ELit (LString "-4611686018427387904"))))))
(DTest false "toInt rejects one past either Int bound" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "None") (EVar "None"))) (ETuple (EApp (EVar "toInt") (ELit (LString "4611686018427387904"))) (EApp (EVar "toInt") (ELit (LString "-4611686018427387905"))))))
(DTest false "toInt rejects a value far outside the Int range" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "None") (EVar "None") (EVar "None"))) (ETuple (EApp (EVar "toInt") (ELit (LString "99999999999999999999"))) (EApp (EVar "toInt") (ELit (LString "-99999999999999999999"))) (EApp (EVar "toInt") (ELit (LString "9223372036854775807"))))))
(DTest false "reverse keeps multibyte codepoints whole" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "óH")) (ELit (LString "本日")) (ELit (LString "b😀a")))) (ETuple (EApp (EVar "reverse") (ELit (LString "Hó"))) (EApp (EVar "reverse") (ELit (LString "日本"))) (EApp (EVar "reverse") (ELit (LString "a😀b"))))))
(DTest false "reverse of the empty string is empty" (EApp (EApp (EVar "expectEqual") (ELit (LString ""))) (EApp (EVar "reverse") (ELit (LString "")))))
(DTest false "join puts the separator between each adjacent pair" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "a, b, c")) (ELit (LString "")) (ELit (LString "a-b")))) (ETuple (EApp (EApp (EVar "join") (ELit (LString ", "))) (EListLit (ELit (LString "a")) (ELit (LString "b")) (ELit (LString "c")))) (EApp (EApp (EVar "join") (ELit (LString ""))) (EListLit (ELit (LString "")) (ELit (LString "")))) (EApp (EApp (EVar "join") (ELit (LString "-"))) (EListLit (ELit (LString "a")) (ELit (LString "b")))))))
(DTest false "join of nothing and of one part" (EApp (EApp (EVar "expectEqual") (ETuple (ELit (LString "")) (ELit (LString "x")))) (ETuple (EApp (EApp (EVar "join") (ELit (LString ", "))) (EListLit)) (EApp (EApp (EVar "join") (ELit (LString ", "))) (EListLit (ELit (LString "x")))))))
(DTest false "unwords joins with single spaces" (EApp (EApp (EVar "expectEqual") (ELit (LString "a b  c"))) (EApp (EVar "unwords") (EListLit (ELit (LString "a")) (ELit (LString "b")) (ELit (LString "")) (ELit (LString "c"))))))
(DTypeSig false "refIsDigit" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "refIsDigit" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9")))))
(DTypeSig false "refToInt" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "refToInt" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EVar "refParseInt") (EVar "a")) (EApp (EVar "arrayLength") (EVar "a"))))))
(DTypeSig false "refParseInt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "refParseInt" ((PVar "a") (PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "None") (EApp (EApp (EApp (EVar "refParseSign") (EVar "a")) (EVar "n")) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "a")))))
(DTypeSig false "refParseSign" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "refParseSign" ((PVar "a") (PVar "n") (PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "-"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "refParseDigits") (EVar "a")) (EVar "n")) (ELit (LInt 1))) (ELit (LInt 0))) (EVar "False")) (EVar "True")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "+"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "refParseDigits") (EVar "a")) (EVar "n")) (ELit (LInt 1))) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "refParseDigits") (EVar "a")) (EVar "n")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "refParseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "refParseDigits" ((PVar "a") (PVar "n") (PVar "i") (PVar "acc") (PVar "seen") (PVar "negative")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EApp (EApp (EVar "refFinishInt") (EVar "seen")) (EVar "acc")) (EVar "negative")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "refParseDigitStep") (EVar "a")) (EVar "n")) (EVar "i")) (EVar "acc")) (EVar "seen")) (EVar "negative")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refParseDigitStep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "refParseDigitStep" ((PVar "a") (PVar "n") (PVar "i") (PVar "acc") (PVar "seen") (PVar "negative") (PVar "c")) (EIf (EApp (EVar "refIsDigit") (EVar "c")) (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48)))) (DoLet false false (PVar "limit") (EIf (EVar "negative") (EVar "intMinBound") (EBinOp "-" (ELit (LInt 0)) (EVar "intMaxBound")))) (DoLet false false (PVar "multMin") (EBinOp "/" (EVar "limit") (ELit (LInt 10)))) (DoExpr (EIf (EBinOp "<" (EVar "acc") (EVar "multMin")) (EVar "None") (EBlock (DoLet false false (PVar "acc2") (EBinOp "*" (EVar "acc") (ELit (LInt 10)))) (DoExpr (EIf (EBinOp "<" (EVar "acc2") (EBinOp "+" (EVar "limit") (EVar "d"))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "refParseDigits") (EVar "a")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "acc2") (EVar "d"))) (EVar "True")) (EVar "negative")))))))) (EVar "None")))
(DTypeSig false "refFinishInt" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "refFinishInt" ((PVar "seen") (PVar "acc") (PVar "negative")) (EIf (EApp (EVar "not") (EVar "seen")) (EVar "None") (EIf (EVar "negative") (EApp (EVar "Some") (EVar "acc")) (EApp (EVar "Some") (EBinOp "-" (ELit (LInt 0)) (EVar "acc"))))))
(DTypeSig false "refReverse" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "refReverse" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "a"))) (DoExpr (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EBinOp "-" (EVar "n") (ELit (LInt 1))) (EVar "i"))) (EVar "a"))))))))
(DTypeSig false "refIntersperse" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "refIntersperse" (PWild (PList)) (EListLit))
(DFunDef false "refIntersperse" (PWild (PCons (PVar "x") (PList))) (EListLit (EVar "x")))
(DFunDef false "refIntersperse" ((PVar "sep") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "sep") (EApp (EApp (EVar "refIntersperse") (EVar "sep")) (EVar "xs")))))
(DTypeSig false "refJoin" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "refJoin" ((PVar "sep") (PVar "parts")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "refIntersperse") (EVar "sep")) (EVar "parts"))))
(DTypeSig false "intTextEdges" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "intTextEdges" () (EListLit (ELit (LString "")) (ELit (LString "-")) (ELit (LString "+")) (ELit (LString "0")) (ELit (LString "-0")) (ELit (LString "+0")) (ELit (LString "007")) (ELit (LString "-7")) (ELit (LString "+7")) (ELit (LString "42")) (ELit (LString "12x")) (ELit (LString "x12")) (ELit (LString "--1")) (ELit (LString "+-1")) (ELit (LString "-+1")) (ELit (LString " 1")) (ELit (LString "1 ")) (ELit (LString "1é")) (ELit (LString "é1")) (ELit (LString "٣")) (ELit (LString "1\n")) (ELit (LString "00000000000000000000001")) (ELit (LString "4611686018427387903")) (ELit (LString "4611686018427387904")) (ELit (LString "-4611686018427387904")) (ELit (LString "-4611686018427387905")) (ELit (LString "461168601842738790")) (ELit (LString "-461168601842738790")) (ELit (LString "4611686018427387900")) (ELit (LString "9223372036854775807")) (ELit (LString "-9223372036854775808")) (ELit (LString "99999999999999999999")) (ELit (LString "-99999999999999999999")) (ELit (LString "1234567890"))))
(DTypeSig false "reverseEdges" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "reverseEdges" () (EListLit (ELit (LString "")) (ELit (LString "a")) (ELit (LString "ab")) (ELit (LString "abc")) (ELit (LString "héllo")) (ELit (LString "日本語")) (ELit (LString "a😀b")) (ELit (LString "é")) (ELit (LString "👍🏽x")) (ELit (LString "ééé")) (ELit (LString "a\nb")) (ELit (LString "日a本"))))
(DTypeSig false "joinEdges" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "joinEdges" () (EListLit (ETuple (ELit (LString ", ")) (EListLit)) (ETuple (ELit (LString ", ")) (EListLit (ELit (LString "a")))) (ETuple (ELit (LString "")) (EListLit (ELit (LString "a")) (ELit (LString "b")))) (ETuple (ELit (LString ", ")) (EListLit (ELit (LString "a")) (ELit (LString "b")) (ELit (LString "c")))) (ETuple (ELit (LString "é")) (EListLit (ELit (LString "日")) (ELit (LString "本")))) (ETuple (ELit (LString "日本")) (EListLit (ELit (LString "")) (ELit (LString "x")) (ELit (LString "")))) (ETuple (ELit (LString "-")) (EListLit (ELit (LString "")) (ELit (LString "")))) (ETuple (ELit (LString " ")) (EListLit (ELit (LString "a😀")) (ELit (LString "b")))) (ETuple (ELit (LString "")) (EListLit)) (ETuple (ELit (LString "")) (EListLit (ELit (LString ""))))))
(DTest false "toInt agrees with the Medaka reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refPairs2") (EVar "refToInt")) (EVar "intTextEdges"))) (EApp (EApp (EVar "refPairs2") (EVar "toInt")) (EVar "intTextEdges"))))
(DTest false "reverse agrees with the codepoint reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refPairs2") (EVar "refReverse")) (EVar "reverseEdges"))) (EApp (EApp (EVar "refPairs2") (EVar "reverse")) (EVar "reverseEdges"))))
(DTest false "join agrees with the intersperse reference on edge inputs" (EApp (EApp (EVar "expectEqual") (EApp (EApp (EVar "refJoinPairs") (EVar "refJoin")) (EVar "joinEdges"))) (EApp (EApp (EVar "refJoinPairs") (EVar "join")) (EVar "joinEdges"))))
(DTypeSig false "refPairs2" (TyFun (TyFun (TyCon "String") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "refPairs2" ((PVar "f") (PVar "xs")) (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "xs")))
(DTypeSig false "refJoinPairs" (TyFun (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "refJoinPairs" (PWild (PList)) (EListLit))
(DFunDef false "refJoinPairs" ((PVar "f") (PCons (PTuple (PVar "sep") (PVar "parts")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "f") (EVar "sep")) (EVar "parts")) (EApp (EApp (EVar "refJoinPairs") (EVar "f")) (EVar "rest"))))
(DProp false "toInt reads back every decimal Int" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "toInt") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "Some") (EVar "n"))))
(DProp false "reverse is an involution" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EVar "reverse") (EApp (EVar "reverse") (EVar "s"))) (EVar "s")))
(DProp false "join with the empty separator is concat" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EApp (EVar "join") (ELit (LString ""))) (EListLit (EVar "s") (EVar "s"))) (EBinOp "++" (EVar "s") (EVar "s"))))
(DTest false "join keeps an exact codepoint length on multibyte text" (EApp (EApp (EVar "expectEqual") (ELit (LInt 7))) (EApp (EVar "stringLength") (EApp (EApp (EVar "join") (ELit (LString "→"))) (EListLit (ELit (LString "é")) (ELit (LString "日本")) (ELit (LString "")) (ELit (LString "x")))))))
(DTest false "join with an empty separator keeps an exact codepoint length" (EApp (EApp (EVar "expectEqual") (ELit (LInt 2))) (EApp (EVar "stringLength") (EApp (EApp (EVar "join") (ELit (LString ""))) (EListLit (ELit (LString "é")) (ELit (LString "日")))))))
(DTest false "reverse keeps an exact codepoint length on multibyte text" (EApp (EApp (EVar "expectEqual") (ELit (LInt 4))) (EApp (EVar "stringLength") (EApp (EVar "reverse") (ELit (LString "é日→😀"))))))
(DTypeSig false "alphabet36" (TyCon "String"))
(DFunDef false "alphabet36" () (ELit (LString "abcdefghijklmnopqrstuvwxyz0123456789")))
(DTest false "indexOf finds a needle at the start of a long string" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 0)))) (EApp (EApp (EVar "indexOf") (ELit (LString "abc"))) (EVar "alphabet36"))))
(DTest false "indexOf finds a needle in the middle of a long string" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 12)))) (EApp (EApp (EVar "indexOf") (ELit (LString "mno"))) (EVar "alphabet36"))))
(DTest false "indexOf finds a needle at the end of a long string" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LInt 33)))) (EApp (EApp (EVar "indexOf") (ELit (LString "789"))) (EVar "alphabet36"))))
(DTest false "indexOf misses a needle absent from a long string" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EVar "indexOf") (ELit (LString "9a"))) (EVar "alphabet36"))))
(DTest false "lastIndexOf and countOccurrences find one hit at the end" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 33))) (ELit (LInt 1)))) (ETuple (EApp (EApp (EVar "lastIndexOf") (ELit (LString "789"))) (EVar "alphabet36")) (EApp (EApp (EVar "countOccurrences") (ELit (LString "789"))) (EVar "alphabet36")))))
(DTest false "an empty needle on a long string is at 0, at the end, and counts 0" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 0))) (EApp (EVar "Some") (ELit (LInt 36))) (ELit (LInt 0)))) (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString ""))) (EVar "alphabet36")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString ""))) (EVar "alphabet36")) (EApp (EApp (EVar "countOccurrences") (ELit (LString ""))) (EVar "alphabet36")))))
(DTest false "a needle equal to a long haystack hits once at 0" (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 0))) (EApp (EVar "Some") (ELit (LInt 0))) (ELit (LInt 1)) (EVar "True"))) (ETuple (EApp (EApp (EVar "indexOf") (EVar "alphabet36")) (EVar "alphabet36")) (EApp (EApp (EVar "lastIndexOf") (EVar "alphabet36")) (EVar "alphabet36")) (EApp (EApp (EVar "countOccurrences") (EVar "alphabet36")) (EVar "alphabet36")) (EApp (EApp (EVar "startsWith") (EVar "alphabet36")) (EVar "alphabet36")))))
(DTest false "a needle longer than a long haystack misses everywhere" (EBlock (DoLet false false (PVar "longer") (EBinOp "++" (EVar "alphabet36") (ELit (LString "!")))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EVar "None") (EVar "None") (ELit (LInt 0)) (EVar "False") (EVar "False"))) (ETuple (EApp (EApp (EVar "indexOf") (EVar "longer")) (EVar "alphabet36")) (EApp (EApp (EVar "lastIndexOf") (EVar "longer")) (EVar "alphabet36")) (EApp (EApp (EVar "countOccurrences") (EVar "longer")) (EVar "alphabet36")) (EApp (EApp (EVar "startsWith") (EVar "longer")) (EVar "alphabet36")) (EApp (EApp (EVar "endsWith") (EVar "longer")) (EVar "alphabet36")))))))
(DTest false "countOccurrences of an overlapping run takes non-overlapping matches" (EBlock (DoLet false false (PVar "run") (ELit (LString "aaaaaaaaaaaaaaaaaaaaa"))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 0))) (EApp (EVar "Some") (EBinOp "-" (EApp (EVar "stringLength") (EVar "run")) (ELit (LInt 3)))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "run")) (ELit (LInt 3))))) (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString "aaa"))) (EVar "run")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "aaa"))) (EVar "run")) (EApp (EApp (EVar "countOccurrences") (ELit (LString "aaa"))) (EVar "run")))))))
(DTest false "lastIndexOf finds the end hit across a block boundary" (EBlock (DoLet false false (PVar "s") (ELit (LString "abxxxxxxxxxxxxxxxxxxxxxxxxab"))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 0))) (EApp (EVar "Some") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2)))) (ELit (LInt 2)))) (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString "ab"))) (EVar "s")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "ab"))) (EVar "s")) (EApp (EApp (EVar "countOccurrences") (ELit (LString "ab"))) (EVar "s")))))))
(DTest false "a window whose first and last bytes match but whose middle does not" (EBlock (DoLet false false (PVar "hay") (EBinOp "++" (ELit (LString "aYbaYbaXb")) (ELit (LString "qqqqqqqqqq")))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 6))) (ELit (LInt 1)))) (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString "aXb"))) (EVar "hay")) (EApp (EApp (EVar "countOccurrences") (ELit (LString "aXb"))) (EVar "hay")))))))
(DTest false "indexOf of a multibyte needle past a block returns a codepoint index" (EBlock (DoLet false false (PVar "s") (ELit (LString "abcdefgé日xyz"))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 8))) (EApp (EVar "Some") (ELit (LInt 9))) (EApp (EVar "Some") (ELit (LInt 7))))) (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString "日"))) (EVar "s")) (EApp (EApp (EVar "indexOf") (ELit (LString "xyz"))) (EVar "s")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "é"))) (EVar "s")))))))
(DTest false "multibyte needles on a long multibyte string" (EBlock (DoLet false false (PVar "t") (ELit (LString "日本語日本語日本語日本語"))) (DoExpr (EApp (EApp (EVar "expectEqual") (ETuple (EApp (EVar "Some") (ELit (LInt 2))) (EApp (EVar "Some") (ELit (LInt 8))) (ELit (LInt 3)))) (ETuple (EApp (EApp (EVar "indexOf") (ELit (LString "語日"))) (EVar "t")) (EApp (EApp (EVar "lastIndexOf") (ELit (LString "語日"))) (EVar "t")) (EApp (EApp (EVar "countOccurrences") (ELit (LString "語日"))) (EVar "t")))))))
(DTest false "startsWith and endsWith on a long string" (EApp (EApp (EVar "expectEqual") (ETuple (EVar "True") (EVar "True") (EVar "False") (EVar "False"))) (ETuple (EApp (EApp (EVar "startsWith") (ELit (LString "abcdefghi"))) (EVar "alphabet36")) (EApp (EApp (EVar "endsWith") (ELit (LString "6789"))) (EVar "alphabet36")) (EApp (EApp (EVar "startsWith") (ELit (LString "bcd"))) (EVar "alphabet36")) (EApp (EApp (EVar "endsWith") (ELit (LString "abc"))) (EVar "alphabet36")))))
(DProp false "indexOf of a prefix is 0" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EApp (EVar "indexOf") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 3))) (EVar "s"))) (EVar "s")) (EApp (EVar "Some") (ELit (LInt 0)))))
(DProp false "lastIndexOf of a two-codepoint suffix ends at the end" ((pp "s" (TyCon "String"))) (EIf (EBinOp "<" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2))) (EVar "True") (EBinOp "==" (EApp (EApp (EVar "lastIndexOf") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (EVar "s")) (EApp (EVar "Some") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2)))))))
