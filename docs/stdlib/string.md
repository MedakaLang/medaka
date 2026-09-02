# string

Operations on `String` and `Char`.

A string is an immutable sequence of Unicode codepoints, and a `Char` is
one codepoint. Positions and lengths count codepoints, not bytes and not
grapheme clusters. Character classification and case mapping are ASCII
only: a non-ASCII character is never a letter, digit, or space to these
functions, and passes through `toUpper` and `toLower` unchanged.

`length` and `isEmpty` are not defined here, to leave the `Foldable`
methods of those names unshadowed. Use `stringLength s` and `s == ""`.
`intToString` renders an integer.

## Characters

### `isDigit`

```
isDigit : Char -> Bool
```

Whether `c` is an ASCII decimal digit, `'0'` to `'9'`.

```medaka
> isDigit '7'
True
> isDigit 'x'
False
```

### `isAlpha`

```
isAlpha : Char -> Bool
```

Whether `c` is an ASCII letter.

### `isAlphaNum`

```
isAlphaNum : Char -> Bool
```

Whether `c` is an ASCII letter or digit.

### `isSpace`

```
isSpace : Char -> Bool
```

Whether `c` is ASCII whitespace.

### `isUpper`

```
isUpper : Char -> Bool
```

Whether `c` is an ASCII uppercase letter.

### `isLower`

```
isLower : Char -> Bool
```

Whether `c` is an ASCII lowercase letter.

### `isPunct`

```
isPunct : Char -> Bool
```

Whether `c` is ASCII punctuation.

### `fromDigit`

```
fromDigit : Char -> Option Int
```

The value of a hexadecimal digit: `'0'` to `'9'` give `0` to `9`, and
`'a'` to `'f'` or `'A'` to `'F'` give `10` to `15`. `None` for any other
character.

```medaka
> fromDigit '7'
Some 7
> fromDigit 'f'
Some 15
```

### `toDigit`

```
toDigit : Int -> Option Char
```

The lowercase hexadecimal digit for a value from `0` to `15`, or `None`
outside that range. The inverse of `fromDigit`.

```medaka
> toDigit 7
Some '7'
> toDigit 12
Some 'c'
```

## Conversion

### `fromChar`

```
fromChar : Char -> String
```

A string holding one character.

### `toChars`

```
toChars : String -> Array Char
```

The codepoints of a string, as an array.

`array.toList` turns the result into a `List Char` when one is needed.

```medaka
> arrayLength (toChars "héllo→")
6
```

### `fromChars`

```
fromChars : List Char -> String
```

A string built from a list of characters.

For an `Array Char`, such as the result of `toChars`, use
`stringFromChars`.

```medaka
> fromChars ['h', 'i']
"hi"
```

### `toUtf8`

```
toUtf8 : String -> Array Int
```

The UTF-8 encoding of a string, one byte (`0` to `255`) per element.

A codepoint outside ASCII contributes several bytes; `toChars` gives the
codepoints instead.

```medaka
> arrayLength (toUtf8 "héllo")
6
```

### `fromUtf8`

```
fromUtf8 : Array Int -> String
```

The string encoded by an array of UTF-8 bytes.

Only the low eight bits of each element are used. On valid UTF-8,
`fromUtf8 (toUtf8 s)` is `s`.

```medaka
> fromUtf8 (toUtf8 "héllo→")
"héllo→"
```

### `utf8ByteLength`

```
utf8ByteLength : String -> Int
```

The number of bytes in the string's UTF-8 encoding.

At least the codepoint count, and larger when the string has non-ASCII
characters.

```medaka
> utf8ByteLength "héllo"
6
```

### `toInt`

```
toInt : String -> Option Int
```

The integer written in decimal in `s`, with an optional leading `-` or
`+`.

`None` when `s` is empty, contains any other character, or names a value
outside the `Int` range.

```medaka
> toInt "42"
Some 42
> toInt "12x"
None
```

### `toFloat`

```
toFloat : String -> Option Float
```

The floating-point number written in `s`, or `None` when `s` is not
one.

```medaka
> toFloat "3.5"
Some 3.5
> toFloat "nope"
None
```

## Searching

### `startsWith`

```
startsWith : String -> String -> Bool
```

Whether `s` begins with `prefix`.

```medaka
> startsWith "he" "hello"
True
> startsWith "lo" "hello"
False
```

### `endsWith`

```
endsWith : String -> String -> Bool
```

Whether `s` ends with `suffix`.

```medaka
> endsWith "lo" "hello"
True
```

### `stripPrefix`

```
stripPrefix : String -> String -> Option String
```

`s` without its leading `prefix`, or `None` when `s` does not begin
with it.

Unlike `drop`, the result says whether the prefix was there.

```medaka
> stripPrefix "he" "hello"
Some "llo"
> stripPrefix "xy" "hello"
None
```

### `stripSuffix`

```
stripSuffix : String -> String -> Option String
```

`s` without its trailing `suffix`, or `None` when `s` does not end with
it.

```medaka
> stripSuffix "lo" "hello"
Some "hel"
> stripSuffix "xy" "hello"
None
```

### `contains`

```
contains : String -> String -> Bool
```

Whether `needle` occurs anywhere in `haystack`.

The empty string occurs in every string.

```medaka
> contains "ell" "hello"
True
> contains "xyz" "hello"
False
```

### `indexOf`

```
indexOf : String -> String -> Option Int
```

The position of the first occurrence of `needle` in `haystack`, or
`None`.

```medaka
> indexOf "lo" "hello"
Some 3
> indexOf "z" "hello"
None
```

### `lastIndexOf`

```
lastIndexOf : String -> String -> Option Int
```

The position of the last occurrence of `needle` in `haystack`, or
`None`.

Occurrences may overlap. An empty needle is found at the end of the
string.

```medaka
> lastIndexOf "l" "hello"
Some 3
> lastIndexOf "z" "hello"
None
```

### `countOccurrences`

```
countOccurrences : String -> String -> Int
```

The number of non-overlapping occurrences of `needle` in `haystack`.

`0` for an empty needle.

```medaka
> countOccurrences "l" "hello"
2
> countOccurrences "ll" "lllll"
2
```

## Building

### `prepend`

```
prepend : String -> String -> String
```

`pre` followed by `s`.

```medaka
> prepend "un" "do"
"undo"
```

### `concat`

```
concat : List String -> String
```

The strings joined end to end.

```medaka
> concat ["a", "bc", "d"]
"abcd"
```

### `join`

```
join : String -> List String -> String
```

The strings joined with `sep` between each adjacent pair.

```medaka
> join ", " ["a", "b", "c"]
"a, b, c"
```

### `repeat`

```
repeat : Int -> String -> String
```

`s` repeated `n` times.

Empty when `n <= 0`. Safe for large `n`: the call depth grows with
`log n`, not `n`.

```medaka
> repeat 3 "ab"
"ababab"
```

## Transformation

### `reverse`

```
reverse : String -> String
```

The string with its characters in reverse order.

```medaka
> reverse "abc"
"cba"
```

### `trimLeft`

```
trimLeft : String -> String
```

The string without its leading whitespace.

```medaka
> trimLeft "  hi  "
"hi  "
```

### `trimRight`

```
trimRight : String -> String
```

The string without its trailing whitespace.

```medaka
> trimRight "  hi  "
"  hi"
```

### `trim`

```
trim : String -> String
```

The string without leading or trailing whitespace.

```medaka
> trim "  hi  "
"hi"
```

### `toUpper`

```
toUpper : String -> String
```

The string with every ASCII letter in uppercase.

Other characters are unchanged, so `ß` stays `ß`.

```medaka
> toUpper "Straße"
"STRAßE"
```

### `toLower`

```
toLower : String -> String
```

The string with every ASCII letter in lowercase.

Other characters are unchanged.

```medaka
> toLower "HÉLLO"
"hÉllo"
```

### `capitalize`

```
capitalize : String -> String
```

The string with its first character in uppercase.

```medaka
> capitalize "hello"
"Hello"
```

### `replace`

```
replace : String -> String -> String -> String
```

The string with the first occurrence of `old` replaced by `new`.

Unchanged when `old` is absent or empty.

```medaka
> replace "l" "L" "hello"
"heLlo"
```

### `replaceAll`

```
replaceAll : String -> String -> String -> String
```

The string with every non-overlapping occurrence of `old` replaced by
`new`.

Unchanged when `old` is empty.

```medaka
> replaceAll "l" "L" "hello"
"heLLo"
```

## Slicing and splitting

### `sliceClamped`

```
sliceClamped : Int -> Int -> String -> String
```

The characters at positions `[lo, hi)`.

Positions are clamped to the string, so an out-of-range slice is shorter
rather than a panic. `s.[lo..hi]` is the panicking form.

```medaka
> sliceClamped 1 4 "hello"
"ell"
```

### `take`

```
take : Int -> String -> String
```

The first `n` characters, or the whole string when it is shorter.

```medaka
> take 3 "hello"
"hel"
```

### `drop`

```
drop : Int -> String -> String
```

Everything after the first `n` characters.

```medaka
> drop 3 "hello"
"lo"
```

### `splitAt`

```
splitAt : Int -> String -> (String, String)
```

The first `n` characters, and the rest.

```medaka
> splitAt 2 "hello"
("he", "llo")
```

### `split`

```
split : String -> String -> List String
```

The pieces of `s` between occurrences of `sep`, with the separators
removed.

An empty separator yields the whole string as the only piece.

```medaka
> split "," "a,b,c"
["a", "b", "c"]
> split "," "abc"
["abc"]
```

### `lines`

```
lines : String -> List String
```

The lines of `s`, split on `\n`.

A `\r` before the `\n` is removed, so Windows line endings work too.

```medaka
> lines "a\nb\nc"
["a", "b", "c"]
```

### `stripCR`

```
stripCR : String -> String
```

The line without one trailing `\r`.

Unchanged when there is none.

```medaka
> stripCR "ab\r"
"ab"
> stripCR "ab"
"ab"
```

### `words`

```
words : String -> List String
```

The words of `s`: the runs of characters between whitespace.

Leading, trailing, and repeated whitespace produce no empty words.

```medaka
> words "  hello   world "
["hello", "world"]
```

### `unlines`

```
unlines : List String -> String
```

The lines joined with `\n`, with a newline after each one.

```medaka
> unlines ["a", "b"]
"a\nb\n"
```

### `unwords`

```
unwords : List String -> String
```

The words joined with single spaces.

```medaka
> unwords ["a", "b", "c"]
"a b c"
```

## Padding

### `padLeft`

```
padLeft : Int -> Char -> String -> String
```

The string padded on the left with `c` to length `n`.

Unchanged when it is already at least `n` long.

```medaka
> padLeft 5 '.' "ab"
"...ab"
```

### `padRight`

```
padRight : Int -> Char -> String -> String
```

The string padded on the right with `c` to length `n`.

Unchanged when it is already at least `n` long.

```medaka
> padRight 5 '.' "ab"
"ab..."
```

### `center`

```
center : Int -> Char -> String -> String
```

The string centered in a field of width `n`, padded with `c`.

When the padding is odd, the extra character goes on the right.
Unchanged when the string is already at least `n` long.

```medaka
> center 5 '.' "ab"
".ab.."
```

## Instances

- `String`: `Eq`, `Semigroup`, `Monoid`, `Ord`, `Debug`, `Display`, `Hashable`, [`Index`](#index-string-int-char), [`Slice`](#slice-string), `Arbitrary`, `Generic`

### `Index String Int Char`

```
impl Index String Int Char
```

`s[i]` is the character at codepoint position `i`.

Panics with an index error when `i` is out of range. Positions count
codepoints, matching `string.toChars`.

### `Slice String`

```
impl Slice String
```

The substring over codepoint positions `[lo, hi)`.

Out-of-range bounds are clamped to the string.

```medaka
> slice "hello" 1 4
"ell"
```

