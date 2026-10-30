# META
source_lines=945
stages=DESUGAR,MARK
# SOURCE
{- | Operations on `String` and `Char`.

   A string is an immutable sequence of Unicode codepoints, and a `Char` is
   one codepoint. Positions and lengths count codepoints, not bytes and not
   grapheme clusters. Character classification and case mapping are ASCII
   only: a non-ASCII character is never a letter, digit, or space to these
   functions, and passes through `toUpper` and `toLower` unchanged.

   `length s` counts codepoints; `byteLength` counts UTF-8 bytes.
   Use `s == ""` to test whether a string is empty.
   `intToString` renders an integer. -}

-- Performance posture: under the hood this module favors what the machine
-- likes, a contiguous `Array Char` with O(1) indexing and the direct string
-- externs (`stringSlice`/`stringConcat`/`stringCompare`/`stringLength`), over
-- a `List Char` of cons cells.  Three tiers, fastest first:
--   1. operate on the String directly (no char materialization): `take`/`drop`/
--      `sliceClamped`, `concat`/`join`/`repeat`, `trim*` (probe the ends one
--      character at a time, then one slice), and the host byte-level externs
--      (`stringStartsWith`/`stringEndsWith`, `stringIndexOf`/`stringLastIndexOf`/
--      `stringCountOccurrences`, `stringReverse`, `stringToInt`,
--      `stringByteLength`, `stringJoin`), with `contains`/`replace*` derived
--      from them;
--   2. decode once to `Array Char`, scan by index, rebuild via `stringFromChars`
--      or carve out `stringSlice`s: `words`, `split`/`lines`, `capitalize`;
--   3. `List Char` is avoided internally.
--
-- The collection functions (`split`/`words`/`lines`/`concat`/`join`/`unlines`/
-- `unwords`) are `List`-typed; `toChars` is the one `Array` function.  No
-- List/Array duals: `arrayFromList` and `array.toList` convert in one call.

import core.{Ordering(..), Ord, Debug, Foldable, Mappable, Option}

-- `Debug String`/`Debug Char` and the other primitive instances live in the
-- prelude (`core.mdk`), so they resolve without importing `string`.

-- # Characters

{- | Whether `c` is an ASCII decimal digit, `'0'` to `'9'`.

   > isDigit '7'
   True
   > isDigit 'x'
   False -}
export
isDigit : Char -> Bool
isDigit c = charCode c >= 48 && charCode c <= 57

-- | Whether `c` is an ASCII letter.
export
isAlpha : Char -> Bool
isAlpha c = charIsAlpha c

-- | Whether `c` is an ASCII letter or digit.
export
isAlphaNum : Char -> Bool
isAlphaNum c = charIsAlpha c || isDigit c

-- | Whether `c` is ASCII whitespace.
export
isSpace : Char -> Bool
isSpace c = charIsSpace c

-- | Whether `c` is an ASCII uppercase letter.
export
isUpper : Char -> Bool
isUpper c = charIsUpper c

-- | Whether `c` is an ASCII lowercase letter.
export
isLower : Char -> Bool
isLower c = charIsLower c

-- | Whether `c` is ASCII punctuation.
export
isPunct : Char -> Bool
isPunct c = charIsPunct c

{- | The value of a hexadecimal digit: `'0'` to `'9'` give `0` to `9`, and
   `'a'` to `'f'` or `'A'` to `'F'` give `10` to `15`. `None` for any other
   character.

   > fromDigit '7'
   Some 7
   > fromDigit 'f'
   Some 15 -}
export
fromDigit : Char -> Option Int
fromDigit c = digitVal (charCode c)

-- > fromDigit 'z'
-- None

digitVal : Int -> Option Int
digitVal n
  | n >= 48 && n <= 57 = Some (n - 48)
  | n >= 97 && n <= 102 = Some (n - 87)
  | n >= 65 && n <= 70 = Some (n - 55)
  | otherwise = None

{- | The lowercase hexadecimal digit for a value from `0` to `15`, or `None`
   outside that range. The inverse of `fromDigit`.

   > toDigit 7
   Some '7'
   > toDigit 12
   Some 'c' -}
export
toDigit : Int -> Option Char
toDigit n
  | n >= 0 && n <= 9 = charFromCode (n + 48)
  | n >= 10 && n <= 15 = charFromCode (n + 87)
  | otherwise = None

-- > toDigit 42
-- None

-- # Conversion

-- | A string holding one character.
export
fromChar : Char -> String
fromChar c = charToStr c

{- | The codepoints of a string, as an array.

   `array.toList` turns the result into a `List Char` when one is needed.

   > arrayLength (toChars "héllo→")
   6 -}
export
toChars : String -> Array Char
toChars s = stringToChars s

{- | A string built from a list of characters.

   For an `Array Char`, such as the result of `toChars`, use
   `stringFromChars`.

   > fromChars ['h', 'i']
   "hi" -}
export
fromChars : List Char -> String
fromChars cs = stringFromChars (arrayFromList cs)

{- | The UTF-8 encoding of a string, one byte (`0` to `255`) per element.

   A codepoint outside ASCII contributes several bytes; `toChars` gives the
   codepoints instead.

   > arrayLength (toUtf8 "héllo")
   6 -}
export
toUtf8 : String -> Array Int
toUtf8 s = stringToUtf8Bytes s

{- | The string encoded by an array of UTF-8 bytes.

   Only the low eight bits of each element are used. Each ill-formed sequence
   (a stray continuation byte, a truncated sequence, an overlong form, a
   surrogate, anything above U+10FFFF) becomes one U+FFFD replacement
   character per maximal subpart, as `bytes.decodeUtf8Lossy` does, so
   `fromUtf8 (toUtf8 s)` is `s` for every string, but `toUtf8 (fromUtf8 bytes)`
   is `bytes` only when `bytes` is valid UTF-8. Keep bytes that are not text in
   a `bytes.Bytes`.

   > fromUtf8 (toUtf8 "héllo→")
   "héllo→" -}
export
fromUtf8 : Array Int -> String
fromUtf8 bytes = stringFromUtf8Bytes bytes

{- | The number of Unicode codepoints in `s`.

   > length "héllo"
   5
   > length ""
   0 -}
export
length : String -> Int
length s = stringLength s

{- | The number of bytes in the string's UTF-8 encoding, an alias of
   `utf8ByteLength`.

   > byteLength "héllo"
   6 -}
export
byteLength : String -> Int
byteLength s = utf8ByteLength s

{- | The number of bytes in the string's UTF-8 encoding.

   At least the codepoint count, and larger when the string has non-ASCII
   characters.

   > utf8ByteLength "héllo"
   6 -}
export
utf8ByteLength : String -> Int
utf8ByteLength s = stringByteLength s

{- | The integer written in decimal in `s`, with an optional leading `-` or
   `+`.

   `None` when `s` is empty, contains any other character, or names a value
   outside the `Int` range.

   > toInt "42"
   Some 42
   > toInt "12x"
   None -}
export
toInt : String -> Option Int
toInt s = stringToInt s

-- > toInt "-7"
-- Some (-7)
-- > toInt "4611686018427387903"
-- Some 4611686018427387903
-- > toInt "4611686018427387904"
-- None
-- > toInt "-4611686018427387904"
-- Some (-4611686018427387904)
-- > toInt "-4611686018427387905"
-- None
-- > toInt "99999999999999999999"
-- None

{- | The floating-point number written in `s`, or `None` when `s` is not
   one.

   > toFloat "3.5"
   Some 3.5
   > toFloat "nope"
   None -}
export
toFloat : String -> Option Float
toFloat s = stringToFloat s

{- | `x` written with `digits` places after the decimal point, the digit count
   first.

   The text is rounded from the exact binary value of `x`, not from its
   shortest decimal form, and an exact tie goes to the even digit, as in C
   and Python. A negative `digits` counts as `0` and one above `100` as `100`.
   `NaN` and the infinities print as `floatToString` prints them, and a
   negative value that rounds to zero keeps its `-`.

   > toFixed 2 12.3456
   "12.35"
   > toFixed 2 2.675
   "2.67"
   > toFixed 0 2.5
   "2"
   > toFixed (-3) 7.5
   "8" -}
export
toFixed : Int -> Float -> String
toFixed digits x = floatToFixed (max 0 (min 100 digits)) x

-- # Searching

{- | Whether `s` begins with `prefix`.

   > startsWith "he" "hello"
   True
   > startsWith "lo" "hello"
   False -}
export
startsWith : String -> String -> Bool
startsWith prefix s = stringStartsWith prefix s

{- | Whether `s` ends with `suffix`.

   > endsWith "lo" "hello"
   True -}
export
endsWith : String -> String -> Bool
endsWith suffix s = stringEndsWith suffix s

{- | `s` without its leading `prefix`, or `None` when `s` does not begin
   with it.

   Unlike `drop`, the result says whether the prefix was there.

   > stripPrefix "he" "hello"
   Some "llo"
   > stripPrefix "xy" "hello"
   None -}
export
stripPrefix : String -> String -> Option String
stripPrefix prefix s =
  if startsWith prefix s then
    Some (stringSlice (stringLength prefix) (stringLength s) s)
  else
    None

-- > stripPrefix "" "hi"
-- Some "hi"
-- > stripPrefix "hello" "hello"
-- Some ""

{- | `s` without its trailing `suffix`, or `None` when `s` does not end with
   it.

   > stripSuffix "lo" "hello"
   Some "hel"
   > stripSuffix "xy" "hello"
   None -}
export
stripSuffix : String -> String -> Option String
stripSuffix suffix s =
  if endsWith suffix s then
    Some (stringSlice 0 (stringLength s - stringLength suffix) s)
  else
    None

-- > stripSuffix "" "hi"
-- Some "hi"

{- | Whether `needle` occurs anywhere in `haystack`.

   The empty string occurs in every string.

   > contains "ell" "hello"
   True
   > contains "xyz" "hello"
   False -}
export
contains : String -> String -> Bool
contains needle haystack = isSome (indexOf needle haystack)

{- | The position of the first occurrence of `needle` in `haystack`, or
   `None`.

   > indexOf "lo" "hello"
   Some 3
   > indexOf "z" "hello"
   None -}
export
indexOf : String -> String -> Option Int
indexOf needle haystack = stringIndexOf needle haystack

{- | The position of the last occurrence of `needle` in `haystack`, or
   `None`.

   Occurrences may overlap. An empty needle is found at the end of the
   string.

   > lastIndexOf "l" "hello"
   Some 3
   > lastIndexOf "z" "hello"
   None -}
export
lastIndexOf : String -> String -> Option Int
lastIndexOf needle haystack = stringLastIndexOf needle haystack

{- | The number of non-overlapping occurrences of `needle` in `haystack`.

   `0` for an empty needle.

   > countOccurrences "l" "hello"
   2
   > countOccurrences "ll" "lllll"
   2 -}
export
countOccurrences : String -> String -> Int
countOccurrences needle haystack = stringCountOccurrences needle haystack

-- # Building

{- | `pre` followed by `s`.

   > prepend "un" "do"
   "undo" -}
export
prepend : String -> String -> String
prepend pre s = pre ++ s

{- | The strings joined end to end.

   > concat ["a", "bc", "d"]
   "abcd" -}
export
concat : List String -> String
concat parts = stringConcat parts

{- | The strings joined with `sep` between each adjacent pair.

   > join ", " ["a", "b", "c"]
   "a, b, c" -}
export
join : String -> List String -> String
join sep parts = stringJoin sep parts

{- | `s` repeated `n` times.

   Empty when `n <= 0`. Safe for large `n`: the call depth grows with
   `log n`, not `n`.

   > repeat 3 "ab"
   "ababab" -}
export
repeat : Int -> String -> String
repeat n s = repeatDbl n s

-- > repeat 0 "ab"
-- ""
-- > repeat (0 - 1) "ab"
-- ""
-- > stringLength (repeat 30000 "x")
-- 30000

-- `k <= 0` bottoms out at `""`; otherwise halve `k`, double the halved
-- result, and append one more `s` when `k` is odd.  `k / 2` shrinks the
-- argument geometrically, so the call chain is `O(log k)` deep; a linear
-- version hit the evaluator's call-depth cap around n ≈ 25000.
repeatDbl : Int -> String -> String
repeatDbl k s =
  if k <= 0 then
    ""
  else
    let h = repeatDbl (k / 2) s
    if isEven k then h ++ h else h ++ h ++ s

-- # Transformation

{- | The string with its characters in reverse order.

   > reverse "abc"
   "cba" -}
export
reverse : String -> String
reverse s = stringReverse s

{- | The string without its leading whitespace.

   > trimLeft "  hi  "
   "hi  " -}
export
trimLeft : String -> String
trimLeft s =
  let n = stringLength s
  stringSlice (firstNonSpaceStr s 0 n) n s

{- | The string without its trailing whitespace.

   > trimRight "  hi  "
   "  hi" -}
export
trimRight : String -> String
trimRight s = stringSlice 0 (lastNonSpaceStr s (stringLength s - 1) 0 + 1) s

{- | The string without leading or trailing whitespace.

   > trim "  hi  "
   "hi" -}
export
trim : String -> String
trim s =
  let n = stringLength s
  let lo = firstNonSpaceStr s 0 n
  stringSlice lo (lastNonSpaceStr s (n - 1) lo + 1) s

-- Only the characters at the ends are inspected, so trimming costs the
-- length of the surrounding whitespace, not of the string.
charAtStr : String -> Int -> Char
charAtStr s i = arrayGetUnsafe 0 (toChars (stringSlice i (i + 1) s))

-- The first index in [i, n) holding a non-space, or n.
firstNonSpaceStr : String -> Int -> Int -> Int
firstNonSpaceStr s i n
  | i >= n = n
  | isSpace (charAtStr s i) = firstNonSpaceStr s (i + 1) n
  | otherwise = i

-- The last index in [lo, i] holding a non-space, or lo - 1 when there is none.
-- Callers pass lo = 0 for a whole string, or a lo that is already a non-space
-- index (or the string length), so the scan never passes a non-space at lo.
lastNonSpaceStr : String -> Int -> Int -> Int
lastNonSpaceStr s i lo
  | i < lo = lo - 1
  | isSpace (charAtStr s i) = lastNonSpaceStr s (i - 1) lo
  | otherwise = i

firstNonSpace : Array Char -> Int -> Int -> Int
firstNonSpace a i n
  | i >= n = n
  | isSpace (arrayGetUnsafe i a) = firstNonSpace a (i + 1) n
  | otherwise = i

firstSpace : Array Char -> Int -> Int -> Int
firstSpace a i n
  | i >= n = n
  | isSpace (arrayGetUnsafe i a) = i
  | otherwise = firstSpace a (i + 1) n

{- | The string with every ASCII letter in uppercase.

   Other characters are unchanged, so `ß` stays `ß`.

   > toUpper "Straße"
   "STRAßE" -}
export
toUpper : String -> String
toUpper s = stringToUpper s

{- | The string with every ASCII letter in lowercase.

   Other characters are unchanged.

   > toLower "HÉLLO"
   "hÉllo" -}
export
toLower : String -> String
toLower s = stringToLower s

{- | The string with its first character in uppercase.

   > capitalize "hello"
   "Hello" -}
export
capitalize : String -> String
capitalize s =
  if s == "" then
    ""
  else
    charToStr (charToUpper (arrayGetUnsafe 0 (toChars (stringSlice 0 1 s))))
      ++ stringSlice 1 (stringLength s) s

{- | The string with the first occurrence of `old` replaced by `new`.

   Unchanged when `old` is absent or empty.

   > replace "l" "L" "hello"
   "heLlo" -}
export
replace : String -> String -> String -> String
replace old new s = if old == "" then s else replaceFirst old new s

replaceFirst : String -> String -> String -> String
replaceFirst old new s = match indexOf old s
  None => s
  Some i => spliceAt i (stringLength old) new s

spliceAt : Int -> Int -> String -> String -> String
spliceAt i oldLen new s = stringConcat [
  stringSlice 0 i s,
  new,
  stringSlice (i + oldLen) (stringLength s) s,
]

{- | The string with `old` replaced by `new`, provided `old` occurs exactly
   once.

   `Err` when `old` occurs no times, more than once, or is empty. The
   message names the first line of `old` (cut at 60 characters) and the
   number of occurrences found. Occurrences are counted as
   `countOccurrences` counts them.

   > replaceOnce "l" "L" "help"
   Ok "heLp"
   > replaceOnce "z" "Z" "hello"
   Err "expected 1 occurrence of `z…`, found 0"
   > replaceOnce "l" "L" "hello"
   Err "expected 1 occurrence of `l…`, found 2"
   > replaceOnce "" "x" "hello"
   Err "expected 1 occurrence of `…`, found 0" -}
export
replaceOnce : String -> String -> String -> Result String String
replaceOnce old new s = match countOccurrences old s
  1 => Ok (replaceFirst old new s)
  n => Err "expected 1 occurrence of `\{take 60 (firstLine old)}…`, found \{n}"

firstLine : String -> String
firstLine s = match lines s
  [] => ""
  l :: _ => l

{- | Splits `s` at the first `start` and the first `end` after it, giving
   the text before `start`, the text between the two, and the text after
   `end`. Neither anchor appears in the result.

   `Err` names the anchor that is missing: `start` anywhere in `s`, or
   `end` after `start`.

   > cutBetween "[" "]" "a[b]c"
   Ok ("a", "b", "c")
   > cutBetween "[" "]" "a[]c"
   Ok ("a", "", "c")
   > cutBetween "[" "]" "abc"
   Err "start anchor `[` not found"
   > cutBetween "[" "]" "a]b[c"
   Err "end anchor `]` not found after start" -}
export
cutBetween : String ->
  String ->
  String ->
  Result String (String, String, String)
cutBetween start end s = match indexOf start s
  None => Err "start anchor `\{start}` not found"
  Some i =>
    let afterStart = drop (i + stringLength start) s
    match indexOf end afterStart
      None => Err "end anchor `\{end}` not found after start"
      Some j => Ok (
        take i s,
        take j afterStart,
        drop (j + stringLength end) afterStart,
      )

{- | The string with every non-overlapping occurrence of `old` replaced by
   `new`.

   Unchanged when `old` is empty.

   > replaceAll "l" "L" "hello"
   "heLLo" -}
export
replaceAll : String -> String -> String -> String
replaceAll old new s = if old == "" then s else replaceAllGo old new s

-- Collects the pieces between hits and the replacement, then joins them.
replaceAllGo : String -> String -> String -> String
replaceAllGo old new s = match indexOf old s
  None => s
  Some _ =>
    let a = toChars s
    let n = arrayLength a
    let oA = toChars old
    let ol = arrayLength oA
    stringConcat (replaceAllGoFrom a n oA ol new 0 0 [])

-- `acc` holds the pieces so far, latest first.
replaceAllGoFrom : Array Char ->
  Int ->
  Array Char ->
  Int ->
  String ->
  Int ->
  Int ->
  List String ->
  List String
replaceAllGoFrom a n oA ol new start from acc = match sepFrom a n oA ol from
  None => reverseStrings (subChars a start n :: acc)
  Some i =>
    replaceAllGoFrom
      a
      n
      oA
      ol
      new
      (i + ol)
      (i + ol)
      (new :: subChars a start i :: acc)

-- Local copy: this module imports only `core`, so `list.reverse` is out of reach.
reverseStrings : List String -> List String
reverseStrings xs = reverseStringsGo xs []

reverseStringsGo : List String -> List String -> List String
reverseStringsGo [] acc = acc
reverseStringsGo (x :: rest) acc = reverseStringsGo rest (x :: acc)

-- # Slicing and splitting

{- | The characters at positions `[lo, hi)`.

   Positions are clamped to the string, so an out-of-range slice is shorter
   rather than a panic. `s.[lo..hi]` is the panicking form.

   > sliceClamped 1 4 "hello"
   "ell" -}
export
sliceClamped : Int -> Int -> String -> String
sliceClamped lo hi s = stringSlice lo hi s

-- > sliceClamped 0 100 "abc"
-- "abc"

-- > take 100 "abc"
-- "abc"

{- | The first `n` characters, or the whole string when it is shorter.

   > take 3 "hello"
   "hel" -}
export
take : Int -> String -> String
take n s = stringSlice 0 n s

{- | Everything after the first `n` characters.

   > drop 3 "hello"
   "lo" -}
export
drop : Int -> String -> String
drop n s = stringSlice n (stringLength s) s

{- | The first `n` characters, and the rest.

   > splitAt 2 "hello"
   ("he", "llo") -}
export
splitAt : Int -> String -> (String, String)
splitAt n s = (take n s, drop n s)

{- | The pieces of `s` between occurrences of `sep`, with the separators
   removed.

   An empty separator yields the whole string as the only piece.

   > split "," "a,b,c"
   ["a", "b", "c"]
   > split "," "abc"
   ["abc"] -}
export
split : String -> String -> List String
split sep s =
  if sep == "" then
    [s]
  else
    let a = toChars s
    let sepA = toChars sep
    splitFrom a (arrayLength a) sepA (arrayLength sepA) 0

-- Decodes both operands once and carves each piece out of the array, so the
-- whole split costs O(length of s) copying rather than one whole-suffix copy
-- per separator: `stringSlice lo hi` walks the UTF-8 bytes from 0 to reach
-- `lo`, so slicing a shrinking suffix is quadratic in the number of pieces.
splitFrom : Array Char -> Int -> Array Char -> Int -> Int -> List String
splitFrom a n sepA sepLen start = match sepFrom a n sepA sepLen start
  None => [subChars a start n]
  Some i => subChars a start i :: splitFrom a n sepA sepLen (i + sepLen)

-- The first index at or after `i` where `sepA` occurs, or None.
sepFrom : Array Char -> Int -> Array Char -> Int -> Int -> Option Int
sepFrom a n sepA sepLen i
  | i + sepLen > n = None
  | sepAt a sepA sepLen i 0 = Some i
  | otherwise = sepFrom a n sepA sepLen (i + 1)

sepAt : Array Char -> Array Char -> Int -> Int -> Int -> Bool
sepAt a sepA sepLen i k
  | k >= sepLen = True
  | arrayGetUnsafe (i + k) a == arrayGetUnsafe k sepA =
    sepAt a sepA sepLen i (k + 1)
  | otherwise = False

subChars : Array Char -> Int -> Int -> String
subChars a lo hi =
  stringFromChars (arrayMakeWith (hi - lo) (i => arrayGetUnsafe (lo + i) a))

{- | The lines of `s`, split on `\n`.

   A `\r` before the `\n` is removed, so Windows line endings work too.

   > lines "a\nb\nc"
   ["a", "b", "c"] -}
export
lines : String -> List String
lines s =
  let a = toChars s
  linesFrom a (arrayLength a) 0

-- Each line is cut once: the `\r` before the `\n` is left out of the slice,
-- so no line is copied a second time to strip it.
linesFrom : Array Char -> Int -> Int -> List String
linesFrom a n start = match newlineFrom a n start
  None => [lineSlice a start n]
  Some i => lineSlice a start i :: linesFrom a n (i + 1)

newlineFrom : Array Char -> Int -> Int -> Option Int
newlineFrom a n i
  | i >= n = None
  | arrayGetUnsafe i a == '\n' = Some i
  | otherwise = newlineFrom a n (i + 1)

-- The characters `[start, hi)`, minus one trailing `\r` when present.
lineSlice : Array Char -> Int -> Int -> String
lineSlice a start hi =
  if hi > start && arrayGetUnsafe (hi - 1) a == '\r' then
    subChars a start (hi - 1)
  else
    subChars a start hi

{- | The line without one trailing `\r`.

   Unchanged when there is none.

   > stripCR "ab\r"
   "ab"
   > stripCR "ab"
   "ab" -}
export
stripCR : String -> String
stripCR line =
  if endsWith "\r" line then
    stringSlice 0 (stringLength line - 1) line
  else
    line

{- | The words of `s`: the runs of characters between whitespace.

   Leading, trailing, and repeated whitespace produce no empty words.

   > words "  hello   world "
   ["hello", "world"] -}
export
words : String -> List String
words s =
  let a = toChars s
  let n = arrayLength a
  wordsFrom a n (firstNonSpace a 0 n)

wordsFrom : Array Char -> Int -> Int -> List String
wordsFrom a n start =
  if start >= n then [] else wordsEmit a n start (firstSpace a start n)

wordsEmit : Array Char -> Int -> Int -> Int -> List String
wordsEmit a n start e =
  subChars a start e :: wordsFrom a n (firstNonSpace a e n)

{- | The lines joined with `\n`, with a newline after each one.

   > unlines ["a", "b"]
   "a\nb\n" -}
export
unlines : List String -> String
unlines parts = stringConcat (withNewlines parts)

-- Interleaves the separator between the pieces, so one concat joins them.
withNewlines : List String -> List String
withNewlines [] = []
withNewlines (p :: ps) = p :: nl :: withNewlines ps

-- A single newline.
nl : String
nl = "\n"

{- | The words joined with single spaces.

   > unwords ["a", "b", "c"]
   "a b c" -}
export
unwords : List String -> String
unwords parts = join " " parts

-- # Padding

{- | The string padded on the left with `c` to length `n`.

   Unchanged when it is already at least `n` long.

   > padLeft 5 '.' "ab"
   "...ab" -}
export
padLeft : Int -> Char -> String -> String
padLeft n c s =
  if stringLength s >= n then
    s
  else
    repeat (n - stringLength s) (charToStr c) ++ s

{- | The string padded on the right with `c` to length `n`.

   Unchanged when it is already at least `n` long.

   > padRight 5 '.' "ab"
   "ab..." -}
export
padRight : Int -> Char -> String -> String
padRight n c s =
  if stringLength s >= n then
    s
  else
    s ++ repeat (n - stringLength s) (charToStr c)

{- | The string centered in a field of width `n`, padded with `c`.

   When the padding is odd, the extra character goes on the right.
   Unchanged when the string is already at least `n` long.

   > center 5 '.' "ab"
   ".ab.." -}
export
center : Int -> Char -> String -> String
center n c s =
  if stringLength s >= n then
    s
  else
    let k = n - stringLength s
    repeat (k / 2) (charToStr c) ++ s ++ repeat (k - k / 2) (charToStr c)

-- # Cursors

{- | A position in a string, on a codepoint boundary.

   Walk a string with `nextChar` and cut pieces out with `sliceBetween`.
   The position is a UTF-8 byte offset, so a step costs the width of one
   character however long the string is. A cursor can only come from
   `startCursor` and `nextChar`, never from a number. -}
export data StrCursor = StrCursor String Int

-- | A cursor at the start of the string.
export
startCursor : String -> StrCursor
startCursor s = StrCursor s 0

{- | The character at the cursor and the cursor after it, or `None` at the
   end of the string.

   > isNone (nextChar (startCursor ""))
   True -}
export
nextChar : StrCursor -> Option (Char, StrCursor)
nextChar (StrCursor s off) =
  if off >= stringByteLength s then
    None
  else
    let (c, w) = codepointAt s off
    Some (c, StrCursor s (off + w))

-- The codepoint at byte offset `off` and its width in bytes; `off` must lie
-- inside the string. The extern packs both as `codepoint * 8 + width`.
codepointAt : String -> Int -> (Char, Int)
codepointAt s off =
  let packed = stringCodepointAtByte s off
  let cp = packed / 8
  match charFromCode cp
    Some c => (c, packed - cp * 8)
    None => panic "string.nextChar: the string holds a non-scalar codepoint"

{- | The text between two cursors, from the first up to the second.

   Both cursors must come from the same string. Cursors from different
   strings that happen to bound a valid range of this one give that slice;
   otherwise this panics, and the result is never an invalid string.

   > sliceBetween (startCursor "héllo") (startCursor "héllo")
   "" -}
export
sliceBetween : StrCursor -> StrCursor -> String
sliceBetween (StrCursor s a) (StrCursor _ b) = stringSliceBytes a b s
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Ordering" true) (mem "Ord" false) (mem "Debug" false) (mem "Foldable" false) (mem "Mappable" false) (mem "Option" false))))
(DTypeSig true "isDigit" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isDigit" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48))) (EBinOp "<=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 57)))))
(DTypeSig true "isAlpha" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isAlpha" ((PVar "c")) (EApp (EVar "charIsAlpha") (EVar "c")))
(DTypeSig true "isAlphaNum" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isAlphaNum" ((PVar "c")) (EBinOp "||" (EApp (EVar "charIsAlpha") (EVar "c")) (EApp (EVar "isDigit") (EVar "c"))))
(DTypeSig true "isSpace" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSpace" ((PVar "c")) (EApp (EVar "charIsSpace") (EVar "c")))
(DTypeSig true "isUpper" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isUpper" ((PVar "c")) (EApp (EVar "charIsUpper") (EVar "c")))
(DTypeSig true "isLower" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isLower" ((PVar "c")) (EApp (EVar "charIsLower") (EVar "c")))
(DTypeSig true "isPunct" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isPunct" ((PVar "c")) (EApp (EVar "charIsPunct") (EVar "c")))
(DTypeSig true "fromDigit" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "fromDigit" ((PVar "c")) (EApp (EVar "digitVal") (EApp (EVar "charCode") (EVar "c"))))
(DTypeSig false "digitVal" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "digitVal" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (EBinOp "<=" (EVar "n") (ELit (LInt 57)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 97))) (EBinOp "<=" (EVar "n") (ELit (LInt 102)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 87)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 65))) (EBinOp "<=" (EVar "n") (ELit (LInt 70)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 55)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "toDigit" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Char"))))
(DFunDef false "toDigit" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 0))) (EBinOp "<=" (EVar "n") (ELit (LInt 9)))) (EApp (EVar "charFromCode") (EBinOp "+" (EVar "n") (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 10))) (EBinOp "<=" (EVar "n") (ELit (LInt 15)))) (EApp (EVar "charFromCode") (EBinOp "+" (EVar "n") (ELit (LInt 87)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "fromChar" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "fromChar" ((PVar "c")) (EApp (EVar "charToStr") (EVar "c")))
(DTypeSig true "toChars" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Char"))))
(DFunDef false "toChars" ((PVar "s")) (EApp (EVar "stringToChars") (EVar "s")))
(DTypeSig true "fromChars" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "String")))
(DFunDef false "fromChars" ((PVar "cs")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EVar "cs"))))
(DTypeSig true "toUtf8" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toUtf8" ((PVar "s")) (EApp (EVar "stringToUtf8Bytes") (EVar "s")))
(DTypeSig true "fromUtf8" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "fromUtf8" ((PVar "bytes")) (EApp (EVar "stringFromUtf8Bytes") (EVar "bytes")))
(DTypeSig true "length" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "length" ((PVar "s")) (EApp (EVar "stringLength") (EVar "s")))
(DTypeSig true "byteLength" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "byteLength" ((PVar "s")) (EApp (EVar "utf8ByteLength") (EVar "s")))
(DTypeSig true "utf8ByteLength" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "utf8ByteLength" ((PVar "s")) (EApp (EVar "stringByteLength") (EVar "s")))
(DTypeSig true "toInt" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "toInt" ((PVar "s")) (EApp (EVar "stringToInt") (EVar "s")))
(DTypeSig true "toFloat" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "toFloat" ((PVar "s")) (EApp (EVar "stringToFloat") (EVar "s")))
(DTypeSig true "toFixed" (TyFun (TyCon "Int") (TyFun (TyCon "Float") (TyCon "String"))))
(DFunDef false "toFixed" ((PVar "digits") (PVar "x")) (EApp (EApp (EVar "floatToFixed") (EApp (EApp (EVar "max") (ELit (LInt 0))) (EApp (EApp (EVar "min") (ELit (LInt 100))) (EVar "digits")))) (EVar "x")))
(DTypeSig true "startsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PVar "prefix") (PVar "s")) (EApp (EApp (EVar "stringStartsWith") (EVar "prefix")) (EVar "s")))
(DTypeSig true "endsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "endsWith" ((PVar "suffix") (PVar "s")) (EApp (EApp (EVar "stringEndsWith") (EVar "suffix")) (EVar "s")))
(DTypeSig true "stripPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stripPrefix" ((PVar "prefix") (PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "s")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (EVar "None")))
(DTypeSig true "stripSuffix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stripSuffix" ((PVar "suffix") (PVar "s")) (EIf (EApp (EApp (EVar "endsWith") (EVar "suffix")) (EVar "s")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EVar "suffix")))) (EVar "s"))) (EVar "None")))
(DTypeSig true "contains" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "contains" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "indexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig true "indexOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "indexOf" ((PVar "needle") (PVar "haystack")) (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack")))
(DTypeSig true "lastIndexOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "lastIndexOf" ((PVar "needle") (PVar "haystack")) (EApp (EApp (EVar "stringLastIndexOf") (EVar "needle")) (EVar "haystack")))
(DTypeSig true "countOccurrences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "countOccurrences" ((PVar "needle") (PVar "haystack")) (EApp (EApp (EVar "stringCountOccurrences") (EVar "needle")) (EVar "haystack")))
(DTypeSig true "prepend" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "prepend" ((PVar "pre") (PVar "s")) (EBinOp "++" (EVar "pre") (EVar "s")))
(DTypeSig true "concat" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "concat" ((PVar "parts")) (EApp (EVar "stringConcat") (EVar "parts")))
(DTypeSig true "join" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "join" ((PVar "sep") (PVar "parts")) (EApp (EApp (EVar "stringJoin") (EVar "sep")) (EVar "parts")))
(DTypeSig true "repeat" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "repeat" ((PVar "n") (PVar "s")) (EApp (EApp (EVar "repeatDbl") (EVar "n")) (EVar "s")))
(DTypeSig false "repeatDbl" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "repeatDbl" ((PVar "k") (PVar "s")) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (ELit (LString "")) (EBlock (DoLet false false (PVar "h") (EApp (EApp (EVar "repeatDbl") (EBinOp "/" (EVar "k") (ELit (LInt 2)))) (EVar "s"))) (DoExpr (EIf (EApp (EVar "isEven") (EVar "k")) (EBinOp "++" (EVar "h") (EVar "h")) (EBinOp "++" (EBinOp "++" (EVar "h") (EVar "h")) (EVar "s")))))))
(DTypeSig true "reverse" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "reverse" ((PVar "s")) (EApp (EVar "stringReverse") (EVar "s")))
(DTypeSig true "trimLeft" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trimLeft" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EApp (EApp (EApp (EVar "firstNonSpaceStr") (EVar "s")) (ELit (LInt 0))) (EVar "n"))) (EVar "n")) (EVar "s")))))
(DTypeSig true "trimRight" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trimRight" ((PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "+" (EApp (EApp (EApp (EVar "lastNonSpaceStr") (EVar "s")) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 1)))) (ELit (LInt 0))) (ELit (LInt 1)))) (EVar "s")))
(DTypeSig true "trim" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trim" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoLet false false (PVar "lo") (EApp (EApp (EApp (EVar "firstNonSpaceStr") (EVar "s")) (ELit (LInt 0))) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EBinOp "+" (EApp (EApp (EApp (EVar "lastNonSpaceStr") (EVar "s")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "lo")) (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig false "charAtStr" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "charAtStr" ((PVar "s") (PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "toChars") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig false "firstNonSpaceStr" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstNonSpaceStr" ((PVar "s") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "charAtStr") (EVar "s")) (EVar "i"))) (EApp (EApp (EApp (EVar "firstNonSpaceStr") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lastNonSpaceStr" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lastNonSpaceStr" ((PVar "s") (PVar "i") (PVar "lo")) (EIf (EBinOp "<" (EVar "i") (EVar "lo")) (EBinOp "-" (EVar "lo") (ELit (LInt 1))) (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "charAtStr") (EVar "s")) (EVar "i"))) (EApp (EApp (EApp (EVar "lastNonSpaceStr") (EVar "s")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "lo")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstNonSpace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstNonSpace" ((PVar "a") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstSpace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstSpace" ((PVar "a") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstSpace") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "toUpper" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "toUpper" ((PVar "s")) (EApp (EVar "stringToUpper") (EVar "s")))
(DTypeSig true "toLower" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "toLower" ((PVar "s")) (EApp (EVar "stringToLower") (EVar "s")))
(DTypeSig true "capitalize" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "capitalize" ((PVar "s")) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EApp (EVar "charToStr") (EApp (EVar "charToUpper") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "toChars") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")))))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))
(DTypeSig true "replace" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replace" ((PVar "old") (PVar "new") (PVar "s")) (EIf (EBinOp "==" (EVar "old") (ELit (LString ""))) (EVar "s") (EApp (EApp (EApp (EVar "replaceFirst") (EVar "old")) (EVar "new")) (EVar "s"))))
(DTypeSig false "replaceFirst" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replaceFirst" ((PVar "old") (PVar "new") (PVar "s")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "old")) (EVar "s")) (arm (PCon "None") () (EVar "s")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EVar "spliceAt") (EVar "i")) (EApp (EVar "stringLength") (EVar "old"))) (EVar "new")) (EVar "s")))))
(DTypeSig false "spliceAt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "spliceAt" ((PVar "i") (PVar "oldLen") (PVar "new") (PVar "s")) (EApp (EVar "stringConcat") (EListLit (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "s")) (EVar "new") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (EVar "oldLen"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))
(DTypeSig true "replaceOnce" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "replaceOnce" ((PVar "old") (PVar "new") (PVar "s")) (EMatch (EApp (EApp (EVar "countOccurrences") (EVar "old")) (EVar "s")) (arm (PLit (LInt 1)) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "replaceFirst") (EVar "old")) (EVar "new")) (EVar "s")))) (arm (PVar "n") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected 1 occurrence of `")) (EApp (EVar "display") (EApp (EApp (EVar "take") (ELit (LInt 60))) (EApp (EVar "firstLine") (EVar "old"))))) (ELit (LString "…`, found "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))))))
(DTypeSig false "firstLine" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "firstLine" ((PVar "s")) (EMatch (EApp (EVar "lines") (EVar "s")) (arm (PList) () (ELit (LString ""))) (arm (PCons (PVar "l") PWild) () (EVar "l"))))
(DTypeSig true "cutBetween" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))))
(DFunDef false "cutBetween" ((PVar "start") (PVar "end") (PVar "s")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "start")) (EVar "s")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "start anchor `")) (EApp (EVar "display") (EVar "start"))) (ELit (LString "` not found"))))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "afterStart") (EApp (EApp (EVar "drop") (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "start")))) (EVar "s"))) (DoExpr (EMatch (EApp (EApp (EVar "indexOf") (EVar "end")) (EVar "afterStart")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "end anchor `")) (EApp (EVar "display") (EVar "end"))) (ELit (LString "` not found after start"))))) (arm (PCon "Some" (PVar "j")) () (EApp (EVar "Ok") (ETuple (EApp (EApp (EVar "take") (EVar "i")) (EVar "s")) (EApp (EApp (EVar "take") (EVar "j")) (EVar "afterStart")) (EApp (EApp (EVar "drop") (EBinOp "+" (EVar "j") (EApp (EVar "stringLength") (EVar "end")))) (EVar "afterStart")))))))))))
(DTypeSig true "replaceAll" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replaceAll" ((PVar "old") (PVar "new") (PVar "s")) (EIf (EBinOp "==" (EVar "old") (ELit (LString ""))) (EVar "s") (EApp (EApp (EApp (EVar "replaceAllGo") (EVar "old")) (EVar "new")) (EVar "s"))))
(DTypeSig false "replaceAllGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replaceAllGo" ((PVar "old") (PVar "new") (PVar "s")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "old")) (EVar "s")) (arm (PCon "None") () (EVar "s")) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "a"))) (DoLet false false (PVar "oA") (EApp (EVar "toChars") (EVar "old"))) (DoLet false false (PVar "ol") (EApp (EVar "arrayLength") (EVar "oA"))) (DoExpr (EApp (EVar "stringConcat") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "replaceAllGoFrom") (EVar "a")) (EVar "n")) (EVar "oA")) (EVar "ol")) (EVar "new")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))))))))
(DTypeSig false "replaceAllGoFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))))
(DFunDef false "replaceAllGoFrom" ((PVar "a") (PVar "n") (PVar "oA") (PVar "ol") (PVar "new") (PVar "start") (PVar "from") (PVar "acc")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "sepFrom") (EVar "a")) (EVar "n")) (EVar "oA")) (EVar "ol")) (EVar "from")) (arm (PCon "None") () (EApp (EVar "reverseStrings") (EBinOp "::" (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EVar "n")) (EVar "acc")))) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "replaceAllGoFrom") (EVar "a")) (EVar "n")) (EVar "oA")) (EVar "ol")) (EVar "new")) (EBinOp "+" (EVar "i") (EVar "ol"))) (EBinOp "+" (EVar "i") (EVar "ol"))) (EBinOp "::" (EVar "new") (EBinOp "::" (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EVar "i")) (EVar "acc")))))))
(DTypeSig false "reverseStrings" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "reverseStrings" ((PVar "xs")) (EApp (EApp (EVar "reverseStringsGo") (EVar "xs")) (EListLit)))
(DTypeSig false "reverseStringsGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reverseStringsGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseStringsGo" ((PCons (PVar "x") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "reverseStringsGo") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig true "sliceClamped" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "sliceClamped" ((PVar "lo") (PVar "hi") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EVar "hi")) (EVar "s")))
(DTypeSig true "take" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "take" ((PVar "n") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "n")) (EVar "s")))
(DTypeSig true "drop" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "drop" ((PVar "n") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "n")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig true "splitAt" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "splitAt" ((PVar "n") (PVar "s")) (ETuple (EApp (EApp (EVar "take") (EVar "n")) (EVar "s")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "s"))))
(DTypeSig true "split" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "split" ((PVar "sep") (PVar "s")) (EIf (EBinOp "==" (EVar "sep") (ELit (LString ""))) (EListLit (EVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "sepA") (EApp (EVar "toChars") (EVar "sep"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "splitFrom") (EVar "a")) (EApp (EVar "arrayLength") (EVar "a"))) (EVar "sepA")) (EApp (EVar "arrayLength") (EVar "sepA"))) (ELit (LInt 0)))))))
(DTypeSig false "splitFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitFrom" ((PVar "a") (PVar "n") (PVar "sepA") (PVar "sepLen") (PVar "start")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "sepFrom") (EVar "a")) (EVar "n")) (EVar "sepA")) (EVar "sepLen")) (EVar "start")) (arm (PCon "None") () (EListLit (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EVar "n")))) (arm (PCon "Some" (PVar "i")) () (EBinOp "::" (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EVar "splitFrom") (EVar "a")) (EVar "n")) (EVar "sepA")) (EVar "sepLen")) (EBinOp "+" (EVar "i") (EVar "sepLen")))))))
(DTypeSig false "sepFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "sepFrom" ((PVar "a") (PVar "n") (PVar "sepA") (PVar "sepLen") (PVar "i")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (EVar "sepLen")) (EVar "n")) (EVar "None") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "sepAt") (EVar "a")) (EVar "sepA")) (EVar "sepLen")) (EVar "i")) (ELit (LInt 0))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "sepFrom") (EVar "a")) (EVar "n")) (EVar "sepA")) (EVar "sepLen")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "sepAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "sepAt" ((PVar "a") (PVar "sepA") (PVar "sepLen") (PVar "i") (PVar "k")) (EIf (EBinOp ">=" (EVar "k") (EVar "sepLen")) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "k"))) (EVar "a")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "sepA"))) (EApp (EApp (EApp (EApp (EApp (EVar "sepAt") (EVar "a")) (EVar "sepA")) (EVar "sepLen")) (EVar "i")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "subChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "subChars" ((PVar "a") (PVar "lo") (PVar "hi")) (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "hi") (EVar "lo"))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "lo") (EVar "i"))) (EVar "a"))))))
(DTypeSig true "lines" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lines" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "linesFrom") (EVar "a")) (EApp (EVar "arrayLength") (EVar "a"))) (ELit (LInt 0))))))
(DTypeSig false "linesFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "linesFrom" ((PVar "a") (PVar "n") (PVar "start")) (EMatch (EApp (EApp (EApp (EVar "newlineFrom") (EVar "a")) (EVar "n")) (EVar "start")) (arm (PCon "None") () (EListLit (EApp (EApp (EApp (EVar "lineSlice") (EVar "a")) (EVar "start")) (EVar "n")))) (arm (PCon "Some" (PVar "i")) () (EBinOp "::" (EApp (EApp (EApp (EVar "lineSlice") (EVar "a")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EVar "linesFrom") (EVar "a")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "newlineFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "newlineFrom" ((PVar "a") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")) (ELit (LChar "\n"))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "newlineFrom") (EVar "a")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lineSlice" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "lineSlice" ((PVar "a") (PVar "start") (PVar "hi")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "hi") (EVar "start")) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EVar "a")) (ELit (LChar "\r")))) (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EVar "hi"))))
(DTypeSig true "stripCR" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripCR" ((PVar "line")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "\r"))) (EVar "line")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "line")) (ELit (LInt 1)))) (EVar "line")) (EVar "line")))
(DTypeSig true "words" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "words" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "a"))) (DoExpr (EApp (EApp (EApp (EVar "wordsFrom") (EVar "a")) (EVar "n")) (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (ELit (LInt 0))) (EVar "n"))))))
(DTypeSig false "wordsFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "wordsFrom" ((PVar "a") (PVar "n") (PVar "start")) (EIf (EBinOp ">=" (EVar "start") (EVar "n")) (EListLit) (EApp (EApp (EApp (EApp (EVar "wordsEmit") (EVar "a")) (EVar "n")) (EVar "start")) (EApp (EApp (EApp (EVar "firstSpace") (EVar "a")) (EVar "start")) (EVar "n")))))
(DTypeSig false "wordsEmit" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "wordsEmit" ((PVar "a") (PVar "n") (PVar "start") (PVar "e")) (EBinOp "::" (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EVar "e")) (EApp (EApp (EApp (EVar "wordsFrom") (EVar "a")) (EVar "n")) (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (EVar "e")) (EVar "n")))))
(DTypeSig true "unlines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "unlines" ((PVar "parts")) (EApp (EVar "stringConcat") (EApp (EVar "withNewlines") (EVar "parts"))))
(DTypeSig false "withNewlines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "withNewlines" ((PList)) (EListLit))
(DFunDef false "withNewlines" ((PCons (PVar "p") (PVar "ps"))) (EBinOp "::" (EVar "p") (EBinOp "::" (EVar "nl") (EApp (EVar "withNewlines") (EVar "ps")))))
(DTypeSig false "nl" (TyCon "String"))
(DFunDef false "nl" () (ELit (LString "\n")))
(DTypeSig true "unwords" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "unwords" ((PVar "parts")) (EApp (EApp (EVar "join") (ELit (LString " "))) (EVar "parts")))
(DTypeSig true "padLeft" (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "padLeft" ((PVar "n") (PVar "c") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "n")) (EVar "s") (EBinOp "++" (EApp (EApp (EVar "repeat") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s")))) (EApp (EVar "charToStr") (EVar "c"))) (EVar "s"))))
(DTypeSig true "padRight" (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "padRight" ((PVar "n") (PVar "c") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "n")) (EVar "s") (EBinOp "++" (EVar "s") (EApp (EApp (EVar "repeat") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s")))) (EApp (EVar "charToStr") (EVar "c"))))))
(DTypeSig true "center" (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "center" ((PVar "n") (PVar "c") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "n")) (EVar "s") (EBlock (DoLet false false (PVar "k") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s")))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "repeat") (EBinOp "/" (EVar "k") (ELit (LInt 2)))) (EApp (EVar "charToStr") (EVar "c"))) (EVar "s")) (EApp (EApp (EVar "repeat") (EBinOp "-" (EVar "k") (EBinOp "/" (EVar "k") (ELit (LInt 2))))) (EApp (EVar "charToStr") (EVar "c"))))))))
(DData Abstract "StrCursor" () ((variant "StrCursor" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DTypeSig true "startCursor" (TyFun (TyCon "String") (TyCon "StrCursor")))
(DFunDef false "startCursor" ((PVar "s")) (EApp (EApp (EVar "StrCursor") (EVar "s")) (ELit (LInt 0))))
(DTypeSig true "nextChar" (TyFun (TyCon "StrCursor") (TyApp (TyCon "Option") (TyTuple (TyCon "Char") (TyCon "StrCursor")))))
(DFunDef false "nextChar" ((PCon "StrCursor" (PVar "s") (PVar "off"))) (EIf (EBinOp ">=" (EVar "off") (EApp (EVar "stringByteLength") (EVar "s"))) (EVar "None") (EBlock (DoLet false false (PTuple (PVar "c") (PVar "w")) (EApp (EApp (EVar "codepointAt") (EVar "s")) (EVar "off"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "c") (EApp (EApp (EVar "StrCursor") (EVar "s")) (EBinOp "+" (EVar "off") (EVar "w")))))))))
(DTypeSig false "codepointAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyTuple (TyCon "Char") (TyCon "Int")))))
(DFunDef false "codepointAt" ((PVar "s") (PVar "off")) (EBlock (DoLet false false (PVar "packed") (EApp (EApp (EVar "stringCodepointAtByte") (EVar "s")) (EVar "off"))) (DoLet false false (PVar "cp") (EBinOp "/" (EVar "packed") (ELit (LInt 8)))) (DoExpr (EMatch (EApp (EVar "charFromCode") (EVar "cp")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "c") (EBinOp "-" (EVar "packed") (EBinOp "*" (EVar "cp") (ELit (LInt 8)))))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "string.nextChar: the string holds a non-scalar codepoint"))))))))
(DTypeSig true "sliceBetween" (TyFun (TyCon "StrCursor") (TyFun (TyCon "StrCursor") (TyCon "String"))))
(DFunDef false "sliceBetween" ((PCon "StrCursor" (PVar "s") (PVar "a")) (PCon "StrCursor" PWild (PVar "b"))) (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "a")) (EVar "b")) (EVar "s")))
# MARK
(DUse false (UseGroup ("core") ((mem "Ordering" true) (mem "Ord" false) (mem "Debug" false) (mem "Foldable" false) (mem "Mappable" false) (mem "Option" false))))
(DTypeSig true "isDigit" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isDigit" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 48))) (EBinOp "<=" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 57)))))
(DTypeSig true "isAlpha" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isAlpha" ((PVar "c")) (EApp (EVar "charIsAlpha") (EVar "c")))
(DTypeSig true "isAlphaNum" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isAlphaNum" ((PVar "c")) (EBinOp "||" (EApp (EVar "charIsAlpha") (EVar "c")) (EApp (EVar "isDigit") (EVar "c"))))
(DTypeSig true "isSpace" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isSpace" ((PVar "c")) (EApp (EVar "charIsSpace") (EVar "c")))
(DTypeSig true "isUpper" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isUpper" ((PVar "c")) (EApp (EVar "charIsUpper") (EVar "c")))
(DTypeSig true "isLower" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isLower" ((PVar "c")) (EApp (EVar "charIsLower") (EVar "c")))
(DTypeSig true "isPunct" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isPunct" ((PVar "c")) (EApp (EVar "charIsPunct") (EVar "c")))
(DTypeSig true "fromDigit" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "fromDigit" ((PVar "c")) (EApp (EVar "digitVal") (EApp (EVar "charCode") (EVar "c"))))
(DTypeSig false "digitVal" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "digitVal" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (EBinOp "<=" (EVar "n") (ELit (LInt 57)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 97))) (EBinOp "<=" (EVar "n") (ELit (LInt 102)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 87)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 65))) (EBinOp "<=" (EVar "n") (ELit (LInt 70)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 55)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "toDigit" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Char"))))
(DFunDef false "toDigit" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 0))) (EBinOp "<=" (EVar "n") (ELit (LInt 9)))) (EApp (EVar "charFromCode") (EBinOp "+" (EVar "n") (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 10))) (EBinOp "<=" (EVar "n") (ELit (LInt 15)))) (EApp (EVar "charFromCode") (EBinOp "+" (EVar "n") (ELit (LInt 87)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "fromChar" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "fromChar" ((PVar "c")) (EApp (EVar "charToStr") (EVar "c")))
(DTypeSig true "toChars" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Char"))))
(DFunDef false "toChars" ((PVar "s")) (EApp (EVar "stringToChars") (EVar "s")))
(DTypeSig true "fromChars" (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "String")))
(DFunDef false "fromChars" ((PVar "cs")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EVar "cs"))))
(DTypeSig true "toUtf8" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "toUtf8" ((PVar "s")) (EApp (EVar "stringToUtf8Bytes") (EVar "s")))
(DTypeSig true "fromUtf8" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "String")))
(DFunDef false "fromUtf8" ((PVar "bytes")) (EApp (EVar "stringFromUtf8Bytes") (EVar "bytes")))
(DTypeSig true "length#shadow" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "length#shadow" ((PVar "s")) (EApp (EVar "stringLength") (EVar "s")))
(DTypeSig true "byteLength" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "byteLength" ((PVar "s")) (EApp (EVar "utf8ByteLength") (EVar "s")))
(DTypeSig true "utf8ByteLength" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "utf8ByteLength" ((PVar "s")) (EApp (EVar "stringByteLength") (EVar "s")))
(DTypeSig true "toInt" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "toInt" ((PVar "s")) (EApp (EVar "stringToInt") (EVar "s")))
(DTypeSig true "toFloat" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Float"))))
(DFunDef false "toFloat" ((PVar "s")) (EApp (EVar "stringToFloat") (EVar "s")))
(DTypeSig true "toFixed" (TyFun (TyCon "Int") (TyFun (TyCon "Float") (TyCon "String"))))
(DFunDef false "toFixed" ((PVar "digits") (PVar "x")) (EApp (EApp (EVar "floatToFixed") (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EApp (EApp (EMethodRef "min") (ELit (LInt 100))) (EVar "digits")))) (EVar "x")))
(DTypeSig true "startsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "startsWith" ((PVar "prefix") (PVar "s")) (EApp (EApp (EVar "stringStartsWith") (EVar "prefix")) (EVar "s")))
(DTypeSig true "endsWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "endsWith" ((PVar "suffix") (PVar "s")) (EApp (EApp (EVar "stringEndsWith") (EVar "suffix")) (EVar "s")))
(DTypeSig true "stripPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stripPrefix" ((PVar "prefix") (PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "s")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (EVar "None")))
(DTypeSig true "stripSuffix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stripSuffix" ((PVar "suffix") (PVar "s")) (EIf (EApp (EApp (EVar "endsWith") (EVar "suffix")) (EVar "s")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EVar "suffix")))) (EVar "s"))) (EVar "None")))
(DTypeSig true "contains" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "contains" ((PVar "needle") (PVar "haystack")) (EApp (EVar "isSome") (EApp (EApp (EVar "indexOf") (EVar "needle")) (EVar "haystack"))))
(DTypeSig true "indexOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "indexOf" ((PVar "needle") (PVar "haystack")) (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "haystack")))
(DTypeSig true "lastIndexOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "lastIndexOf" ((PVar "needle") (PVar "haystack")) (EApp (EApp (EVar "stringLastIndexOf") (EVar "needle")) (EVar "haystack")))
(DTypeSig true "countOccurrences" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "countOccurrences" ((PVar "needle") (PVar "haystack")) (EApp (EApp (EVar "stringCountOccurrences") (EVar "needle")) (EVar "haystack")))
(DTypeSig true "prepend" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "prepend" ((PVar "pre") (PVar "s")) (EBinOp "++" (EVar "pre") (EVar "s")))
(DTypeSig true "concat" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "concat" ((PVar "parts")) (EApp (EVar "stringConcat") (EVar "parts")))
(DTypeSig true "join" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "join" ((PVar "sep") (PVar "parts")) (EApp (EApp (EVar "stringJoin") (EVar "sep")) (EVar "parts")))
(DTypeSig true "repeat" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "repeat" ((PVar "n") (PVar "s")) (EApp (EApp (EVar "repeatDbl") (EVar "n")) (EVar "s")))
(DTypeSig false "repeatDbl" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "repeatDbl" ((PVar "k") (PVar "s")) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (ELit (LString "")) (EBlock (DoLet false false (PVar "h") (EApp (EApp (EVar "repeatDbl") (EBinOp "/" (EVar "k") (ELit (LInt 2)))) (EVar "s"))) (DoExpr (EIf (EApp (EVar "isEven") (EVar "k")) (EBinOp "++" (EVar "h") (EVar "h")) (EBinOp "++" (EBinOp "++" (EVar "h") (EVar "h")) (EVar "s")))))))
(DTypeSig true "reverse" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "reverse" ((PVar "s")) (EApp (EVar "stringReverse") (EVar "s")))
(DTypeSig true "trimLeft" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trimLeft" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EApp (EApp (EApp (EVar "firstNonSpaceStr") (EVar "s")) (ELit (LInt 0))) (EVar "n"))) (EVar "n")) (EVar "s")))))
(DTypeSig true "trimRight" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trimRight" ((PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "+" (EApp (EApp (EApp (EVar "lastNonSpaceStr") (EVar "s")) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 1)))) (ELit (LInt 0))) (ELit (LInt 1)))) (EVar "s")))
(DTypeSig true "trim" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trim" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoLet false false (PVar "lo") (EApp (EApp (EApp (EVar "firstNonSpaceStr") (EVar "s")) (ELit (LInt 0))) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EBinOp "+" (EApp (EApp (EApp (EVar "lastNonSpaceStr") (EVar "s")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "lo")) (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig false "charAtStr" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "charAtStr" ((PVar "s") (PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "toChars") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig false "firstNonSpaceStr" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstNonSpaceStr" ((PVar "s") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "charAtStr") (EVar "s")) (EVar "i"))) (EApp (EApp (EApp (EVar "firstNonSpaceStr") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lastNonSpaceStr" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lastNonSpaceStr" ((PVar "s") (PVar "i") (PVar "lo")) (EIf (EBinOp "<" (EVar "i") (EVar "lo")) (EBinOp "-" (EVar "lo") (ELit (LInt 1))) (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "charAtStr") (EVar "s")) (EVar "i"))) (EApp (EApp (EApp (EVar "lastNonSpaceStr") (EVar "s")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "lo")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstNonSpace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstNonSpace" ((PVar "a") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstSpace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstSpace" ((PVar "a") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "isSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstSpace") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "toUpper" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "toUpper" ((PVar "s")) (EApp (EVar "stringToUpper") (EVar "s")))
(DTypeSig true "toLower" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "toLower" ((PVar "s")) (EApp (EVar "stringToLower") (EVar "s")))
(DTypeSig true "capitalize" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "capitalize" ((PVar "s")) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (ELit (LString "")) (EBinOp "++" (EApp (EVar "charToStr") (EApp (EVar "charToUpper") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "toChars") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")))))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))
(DTypeSig true "replace" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replace" ((PVar "old") (PVar "new") (PVar "s")) (EIf (EBinOp "==" (EVar "old") (ELit (LString ""))) (EVar "s") (EApp (EApp (EApp (EVar "replaceFirst") (EVar "old")) (EVar "new")) (EVar "s"))))
(DTypeSig false "replaceFirst" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replaceFirst" ((PVar "old") (PVar "new") (PVar "s")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "old")) (EVar "s")) (arm (PCon "None") () (EVar "s")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EVar "spliceAt") (EVar "i")) (EApp (EVar "stringLength") (EVar "old"))) (EVar "new")) (EVar "s")))))
(DTypeSig false "spliceAt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "spliceAt" ((PVar "i") (PVar "oldLen") (PVar "new") (PVar "s")) (EApp (EVar "stringConcat") (EListLit (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "s")) (EVar "new") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (EVar "oldLen"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))
(DTypeSig true "replaceOnce" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "replaceOnce" ((PVar "old") (PVar "new") (PVar "s")) (EMatch (EApp (EApp (EVar "countOccurrences") (EVar "old")) (EVar "s")) (arm (PLit (LInt 1)) () (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "replaceFirst") (EVar "old")) (EVar "new")) (EVar "s")))) (arm (PVar "n") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected 1 occurrence of `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "take") (ELit (LInt 60))) (EApp (EVar "firstLine") (EVar "old"))))) (ELit (LString "…`, found "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))))))
(DTypeSig false "firstLine" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "firstLine" ((PVar "s")) (EMatch (EApp (EVar "lines") (EVar "s")) (arm (PList) () (ELit (LString ""))) (arm (PCons (PVar "l") PWild) () (EVar "l"))))
(DTypeSig true "cutBetween" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))))
(DFunDef false "cutBetween" ((PVar "start") (PVar "end") (PVar "s")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "start")) (EVar "s")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "start anchor `")) (EApp (EMethodRef "display") (EVar "start"))) (ELit (LString "` not found"))))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "afterStart") (EApp (EApp (EVar "drop") (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (EVar "start")))) (EVar "s"))) (DoExpr (EMatch (EApp (EApp (EVar "indexOf") (EVar "end")) (EVar "afterStart")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "end anchor `")) (EApp (EMethodRef "display") (EVar "end"))) (ELit (LString "` not found after start"))))) (arm (PCon "Some" (PVar "j")) () (EApp (EVar "Ok") (ETuple (EApp (EApp (EVar "take") (EVar "i")) (EVar "s")) (EApp (EApp (EVar "take") (EVar "j")) (EVar "afterStart")) (EApp (EApp (EVar "drop") (EBinOp "+" (EVar "j") (EApp (EVar "stringLength") (EVar "end")))) (EVar "afterStart")))))))))))
(DTypeSig true "replaceAll" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replaceAll" ((PVar "old") (PVar "new") (PVar "s")) (EIf (EBinOp "==" (EVar "old") (ELit (LString ""))) (EVar "s") (EApp (EApp (EApp (EVar "replaceAllGo") (EVar "old")) (EVar "new")) (EVar "s"))))
(DTypeSig false "replaceAllGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replaceAllGo" ((PVar "old") (PVar "new") (PVar "s")) (EMatch (EApp (EApp (EVar "indexOf") (EVar "old")) (EVar "s")) (arm (PCon "None") () (EVar "s")) (arm (PCon "Some" PWild) () (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "a"))) (DoLet false false (PVar "oA") (EApp (EVar "toChars") (EVar "old"))) (DoLet false false (PVar "ol") (EApp (EVar "arrayLength") (EVar "oA"))) (DoExpr (EApp (EVar "stringConcat") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "replaceAllGoFrom") (EVar "a")) (EVar "n")) (EVar "oA")) (EVar "ol")) (EVar "new")) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))))))))
(DTypeSig false "replaceAllGoFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))))
(DFunDef false "replaceAllGoFrom" ((PVar "a") (PVar "n") (PVar "oA") (PVar "ol") (PVar "new") (PVar "start") (PVar "from") (PVar "acc")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "sepFrom") (EVar "a")) (EVar "n")) (EVar "oA")) (EVar "ol")) (EVar "from")) (arm (PCon "None") () (EApp (EVar "reverseStrings") (EBinOp "::" (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EVar "n")) (EVar "acc")))) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "replaceAllGoFrom") (EVar "a")) (EVar "n")) (EVar "oA")) (EVar "ol")) (EVar "new")) (EBinOp "+" (EVar "i") (EVar "ol"))) (EBinOp "+" (EVar "i") (EVar "ol"))) (EBinOp "::" (EVar "new") (EBinOp "::" (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EVar "i")) (EVar "acc")))))))
(DTypeSig false "reverseStrings" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "reverseStrings" ((PVar "xs")) (EApp (EApp (EVar "reverseStringsGo") (EVar "xs")) (EListLit)))
(DTypeSig false "reverseStringsGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reverseStringsGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseStringsGo" ((PCons (PVar "x") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "reverseStringsGo") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig true "sliceClamped" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "sliceClamped" ((PVar "lo") (PVar "hi") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EVar "hi")) (EVar "s")))
(DTypeSig true "take" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "take" ((PVar "n") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "n")) (EVar "s")))
(DTypeSig true "drop" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "drop" ((PVar "n") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "n")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig true "splitAt" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "splitAt" ((PVar "n") (PVar "s")) (ETuple (EApp (EApp (EVar "take") (EVar "n")) (EVar "s")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "s"))))
(DTypeSig true "split" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "split" ((PVar "sep") (PVar "s")) (EIf (EBinOp "==" (EVar "sep") (ELit (LString ""))) (EListLit (EVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "sepA") (EApp (EVar "toChars") (EVar "sep"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "splitFrom") (EVar "a")) (EApp (EVar "arrayLength") (EVar "a"))) (EVar "sepA")) (EApp (EVar "arrayLength") (EVar "sepA"))) (ELit (LInt 0)))))))
(DTypeSig false "splitFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitFrom" ((PVar "a") (PVar "n") (PVar "sepA") (PVar "sepLen") (PVar "start")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "sepFrom") (EVar "a")) (EVar "n")) (EVar "sepA")) (EVar "sepLen")) (EVar "start")) (arm (PCon "None") () (EListLit (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EVar "n")))) (arm (PCon "Some" (PVar "i")) () (EBinOp "::" (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EVar "splitFrom") (EVar "a")) (EVar "n")) (EVar "sepA")) (EVar "sepLen")) (EBinOp "+" (EVar "i") (EVar "sepLen")))))))
(DTypeSig false "sepFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "sepFrom" ((PVar "a") (PVar "n") (PVar "sepA") (PVar "sepLen") (PVar "i")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (EVar "sepLen")) (EVar "n")) (EVar "None") (EIf (EApp (EApp (EApp (EApp (EApp (EVar "sepAt") (EVar "a")) (EVar "sepA")) (EVar "sepLen")) (EVar "i")) (ELit (LInt 0))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "sepFrom") (EVar "a")) (EVar "n")) (EVar "sepA")) (EVar "sepLen")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "sepAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "sepAt" ((PVar "a") (PVar "sepA") (PVar "sepLen") (PVar "i") (PVar "k")) (EIf (EBinOp ">=" (EVar "k") (EVar "sepLen")) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "k"))) (EVar "a")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "sepA"))) (EApp (EApp (EApp (EApp (EApp (EVar "sepAt") (EVar "a")) (EVar "sepA")) (EVar "sepLen")) (EVar "i")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "subChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "subChars" ((PVar "a") (PVar "lo") (PVar "hi")) (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "hi") (EVar "lo"))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "lo") (EVar "i"))) (EVar "a"))))))
(DTypeSig true "lines" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lines" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "linesFrom") (EVar "a")) (EApp (EVar "arrayLength") (EVar "a"))) (ELit (LInt 0))))))
(DTypeSig false "linesFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "linesFrom" ((PVar "a") (PVar "n") (PVar "start")) (EMatch (EApp (EApp (EApp (EVar "newlineFrom") (EVar "a")) (EVar "n")) (EVar "start")) (arm (PCon "None") () (EListLit (EApp (EApp (EApp (EVar "lineSlice") (EVar "a")) (EVar "start")) (EVar "n")))) (arm (PCon "Some" (PVar "i")) () (EBinOp "::" (EApp (EApp (EApp (EVar "lineSlice") (EVar "a")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EVar "linesFrom") (EVar "a")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))
(DTypeSig false "newlineFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "newlineFrom" ((PVar "a") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")) (ELit (LChar "\n"))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "newlineFrom") (EVar "a")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lineSlice" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "lineSlice" ((PVar "a") (PVar "start") (PVar "hi")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "hi") (EVar "start")) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EVar "a")) (ELit (LChar "\r")))) (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EVar "hi"))))
(DTypeSig true "stripCR" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripCR" ((PVar "line")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "\r"))) (EVar "line")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "line")) (ELit (LInt 1)))) (EVar "line")) (EVar "line")))
(DTypeSig true "words" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "words" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "toChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "a"))) (DoExpr (EApp (EApp (EApp (EVar "wordsFrom") (EVar "a")) (EVar "n")) (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (ELit (LInt 0))) (EVar "n"))))))
(DTypeSig false "wordsFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "wordsFrom" ((PVar "a") (PVar "n") (PVar "start")) (EIf (EBinOp ">=" (EVar "start") (EVar "n")) (EListLit) (EApp (EApp (EApp (EApp (EVar "wordsEmit") (EVar "a")) (EVar "n")) (EVar "start")) (EApp (EApp (EApp (EVar "firstSpace") (EVar "a")) (EVar "start")) (EVar "n")))))
(DTypeSig false "wordsEmit" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "wordsEmit" ((PVar "a") (PVar "n") (PVar "start") (PVar "e")) (EBinOp "::" (EApp (EApp (EApp (EVar "subChars") (EVar "a")) (EVar "start")) (EVar "e")) (EApp (EApp (EApp (EVar "wordsFrom") (EVar "a")) (EVar "n")) (EApp (EApp (EApp (EVar "firstNonSpace") (EVar "a")) (EVar "e")) (EVar "n")))))
(DTypeSig true "unlines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "unlines" ((PVar "parts")) (EApp (EVar "stringConcat") (EApp (EVar "withNewlines") (EVar "parts"))))
(DTypeSig false "withNewlines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "withNewlines" ((PList)) (EListLit))
(DFunDef false "withNewlines" ((PCons (PVar "p") (PVar "ps"))) (EBinOp "::" (EVar "p") (EBinOp "::" (EVar "nl") (EApp (EVar "withNewlines") (EVar "ps")))))
(DTypeSig false "nl" (TyCon "String"))
(DFunDef false "nl" () (ELit (LString "\n")))
(DTypeSig true "unwords" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "unwords" ((PVar "parts")) (EApp (EApp (EVar "join") (ELit (LString " "))) (EVar "parts")))
(DTypeSig true "padLeft" (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "padLeft" ((PVar "n") (PVar "c") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "n")) (EVar "s") (EBinOp "++" (EApp (EApp (EVar "repeat") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s")))) (EApp (EVar "charToStr") (EVar "c"))) (EVar "s"))))
(DTypeSig true "padRight" (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "padRight" ((PVar "n") (PVar "c") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "n")) (EVar "s") (EBinOp "++" (EVar "s") (EApp (EApp (EVar "repeat") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s")))) (EApp (EVar "charToStr") (EVar "c"))))))
(DTypeSig true "center" (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "center" ((PVar "n") (PVar "c") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "n")) (EVar "s") (EBlock (DoLet false false (PVar "k") (EBinOp "-" (EVar "n") (EApp (EVar "stringLength") (EVar "s")))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "repeat") (EBinOp "/" (EVar "k") (ELit (LInt 2)))) (EApp (EVar "charToStr") (EVar "c"))) (EVar "s")) (EApp (EApp (EVar "repeat") (EBinOp "-" (EVar "k") (EBinOp "/" (EVar "k") (ELit (LInt 2))))) (EApp (EVar "charToStr") (EVar "c"))))))))
(DData Abstract "StrCursor" () ((variant "StrCursor" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DTypeSig true "startCursor" (TyFun (TyCon "String") (TyCon "StrCursor")))
(DFunDef false "startCursor" ((PVar "s")) (EApp (EApp (EVar "StrCursor") (EVar "s")) (ELit (LInt 0))))
(DTypeSig true "nextChar" (TyFun (TyCon "StrCursor") (TyApp (TyCon "Option") (TyTuple (TyCon "Char") (TyCon "StrCursor")))))
(DFunDef false "nextChar" ((PCon "StrCursor" (PVar "s") (PVar "off"))) (EIf (EBinOp ">=" (EVar "off") (EApp (EVar "stringByteLength") (EVar "s"))) (EVar "None") (EBlock (DoLet false false (PTuple (PVar "c") (PVar "w")) (EApp (EApp (EVar "codepointAt") (EVar "s")) (EVar "off"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "c") (EApp (EApp (EVar "StrCursor") (EVar "s")) (EBinOp "+" (EVar "off") (EVar "w")))))))))
(DTypeSig false "codepointAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyTuple (TyCon "Char") (TyCon "Int")))))
(DFunDef false "codepointAt" ((PVar "s") (PVar "off")) (EBlock (DoLet false false (PVar "packed") (EApp (EApp (EVar "stringCodepointAtByte") (EVar "s")) (EVar "off"))) (DoLet false false (PVar "cp") (EBinOp "/" (EVar "packed") (ELit (LInt 8)))) (DoExpr (EMatch (EApp (EVar "charFromCode") (EVar "cp")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "c") (EBinOp "-" (EVar "packed") (EBinOp "*" (EVar "cp") (ELit (LInt 8)))))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "string.nextChar: the string holds a non-scalar codepoint"))))))))
(DTypeSig true "sliceBetween" (TyFun (TyCon "StrCursor") (TyFun (TyCon "StrCursor") (TyCon "String"))))
(DFunDef false "sliceBetween" ((PCon "StrCursor" (PVar "s") (PVar "a")) (PCon "StrCursor" PWild (PVar "b"))) (EApp (EApp (EApp (EVar "stringSliceBytes") (EVar "a")) (EVar "b")) (EVar "s")))
