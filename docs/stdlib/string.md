# string

string.mdk — operations on String and Char
See STDLIB.md (Module 3) for the full implementation plan.

Design notes
────────────
String is an immutable sequence of Unicode codepoints (scalar values),
UTF-8 backed; Char is one codepoint.  This module is a thin Medaka layer
over the kernel externs in stdlib/runtime.mdk.

Performance posture (Medaka is a *practical* functional language): under the
hood we favour what the machine likes — contiguous `Array Char` with O(1)
indexing and the direct string externs (`stringSlice`/`stringConcat`/
`stringCompare`/`stringLength`) — over a `List Char` of cons cells.  Three
tiers, fastest first:
  1. operate on the String directly (no char materialization): `take`/`drop`/
     `sliceClamped`, `startsWith`/`endsWith` (slice + `==`), `concat`/`join`/`repeat`,
     and substring search via the host `stringIndexOf` — `indexOf`, and
     `contains`/`split`/`replace*` derived from it;
  2. decode once to `Array Char`, scan by index, rebuild via `stringFromChars`
     or carve out `stringSlice`s: `trim*`, `words`, `reverse`, `capitalize`,
     `toInt`;
  3. `List Char` is avoided internally.
The user-facing signatures stay conventional; the array/index machinery is an
implementation detail.

Naming choices (this file holds *both* Char and String utilities, so some
short names would collide):
  • `toUpper`/`toLower` here are the *String* versions — ASCII-only
    byte-wise case mapping (issue #417): "Straße" → "STRAßE", not
    "STRASSE".  For a single Char, call the kernel externs
    `charToUpper`/`charToLower` (Char → Char, also ASCII-only — identity on
    any non-ASCII codepoint).
  • `length`/`isEmpty` are *not* defined: they'd clash with the `Foldable`
    methods of the same name.  Use the global `stringLength`, or `s == ""`.
  • Integer rendering is the global `intToString` (clashes with `Num.fromInt`
    otherwise); `toInt`/`toFloat` parse, `stringToFloat` is the float extern.

Containers: the collection functions (`split`/`words`/`lines`/`concat`/
`join`/`unlines`/`unwords`) are `List`-typed — the conventional, pattern-
matchable form.  `toChars` is the one `Array` function (element decomposition,
where indexing/perf matter).  No List/Array duals: `List → Array` is the
global `arrayFromList` (no import) and `Array → List` is `Array.toList`, so a
caller who prefers the other container converts in one call rather than us
doubling the API surface.

## `isDigit`

```
isDigit : Char -> Bool
```

True for the ASCII decimal digits `'0'`..`'9'`.


*(doctest — run by `medaka test`)*

```medaka
> isDigit '7'
True
> isDigit 'x'
False
```

## `isAlpha`

```
isAlpha : Char -> Bool
```

True for any Unicode letter.

## `isAlphaNum`

```
isAlphaNum : Char -> Bool
```

True for a Unicode letter or an ASCII digit.

## `isSpace`

```
isSpace : Char -> Bool
```

True for any Unicode whitespace.

## `isUpper`

```
isUpper : Char -> Bool
```

True for an uppercase letter.

## `isLower`

```
isLower : Char -> Bool
```

True for a lowercase letter.

## `isPunct`

```
isPunct : Char -> Bool
```

True for a Unicode punctuation character.

## `digitToInt`

```
digitToInt : Char -> Option Int
```

`'0'`..`'9'` → `Some 0`..`Some 9`, `'a'`..`'f'`/`'A'`..`'F'` →
`Some 10`..`Some 15`, anything else `None`.


*(doctest — run by `medaka test`)*

```medaka
> digitToInt '7'
Some 7
> digitToInt 'f'
Some 15
> digitToInt 'z'
None
```

## `intToDigit`

```
intToDigit : Int -> Option Char
```

Inverse of `digitToInt` for `0`..`15` (lowercase hex); `None` otherwise.


*(doctest — run by `medaka test`)*

```medaka
> intToDigit 7
Some '7'
> intToDigit 12
Some 'c'
> intToDigit 42
None
```

## `fromChar`

```
fromChar : Char -> String
```

A one-character string.

## `toChars`

```
toChars : String -> Array Char
```

The codepoints of a string as an array (not grapheme clusters).  Returns
the native `Array Char` — call `Array.toList` if you want a `List Char`, so
the list conversion is opt-in rather than forced.


*(doctest — run by `medaka test`)*

```medaka
> arrayLength (toChars "héllo→")
6
```

## `fromChars`

```
fromChars : List Char -> String
```

Build a string from a `List Char`.  For an `Array Char` (e.g. the result
of `toChars`), use the kernel `stringFromChars` directly.


*(doctest — run by `medaka test`)*

```medaka
> fromChars ['h', 'i']
"hi"
```

## `toUtf8`

```
toUtf8 : String -> Array Int
```

The raw UTF-8 bytes of a string as an `Array Int` (each 0..255), in order.
This is the encoded byte stream, NOT the codepoints — a multi-byte codepoint
contributes several bytes (`toChars` gives codepoints instead).


*(doctest — run by `medaka test`)*

```medaka
> arrayLength (toUtf8 "héllo")
6
```

## `fromUtf8`

```
fromUtf8 : Array Int -> String
```

Rebuild a string from a UTF-8 `Array Int` byte stream (low 8 bits of each).
The inverse of `toUtf8` on valid UTF-8: `fromUtf8 (toUtf8 s) == s`.


*(doctest — run by `medaka test`)*

```medaka
> fromUtf8 (toUtf8 "héllo→")
"héllo→"
```

## `utf8ByteLength`

```
utf8ByteLength : String -> Int
```

The number of UTF-8 bytes a string encodes to (>= its codepoint count).


*(doctest — run by `medaka test`)*

```medaka
> utf8ByteLength "héllo"
6
```

## `toInt`

```
toInt : String -> Option Int
```

Parse a decimal integer, an optional leading `-`/`+` allowed; `None` on
any other character, the empty string, or a magnitude outside the `Int`
range (`intMinBound`..`intMaxBound`) — out-of-range input is rejected
rather than silently wrapping.


*(doctest — run by `medaka test`)*

```medaka
> toInt "42"
Some 42
> toInt "-7"
Some -7
> toInt "12x"
None
> toInt "4611686018427387903"
Some 4611686018427387903
> toInt "4611686018427387904"
None
> toInt "-4611686018427387904"
Some -4611686018427387904
> toInt "-4611686018427387905"
None
> toInt "99999999999999999999"
None
```

## `toFloat`

```
toFloat : String -> Option Float
```

Parse a decimal float; `None` on failure.


*(doctest — run by `medaka test`)*

```medaka
> toFloat "3.5"
Some 3.5
> toFloat "nope"
None
```

## `startsWith`

```
startsWith : String -> String -> Bool
```

True when `s` begins with `prefix`.  Tier 1: a slice + compare, no char
decoding.


*(doctest — run by `medaka test`)*

```medaka
> startsWith "he" "hello"
True
> startsWith "lo" "hello"
False
```

## `endsWith`

```
endsWith : String -> String -> Bool
```

True when `s` ends with `suffix`.


*(doctest — run by `medaka test`)*

```medaka
> endsWith "lo" "hello"
True
```

## `stripPrefix`

```
stripPrefix : String -> String -> Option String
```

Remove `prefix` from the front of `s`, or `None` when `s` doesn't start
with it.  The `Option` is the point: unlike `drop (length prefix)` it tells
you whether the prefix was actually there.


*(doctest — run by `medaka test`)*

```medaka
> stripPrefix "he" "hello"
Some "llo"
> stripPrefix "xy" "hello"
None
> stripPrefix "" "hi"
Some "hi"
> stripPrefix "hello" "hello"
Some ""
```

## `stripSuffix`

```
stripSuffix : String -> String -> Option String
```

Remove `suffix` from the end of `s`, or `None` when `s` doesn't end with
it.


*(doctest — run by `medaka test`)*

```medaka
> stripSuffix "lo" "hello"
Some "hel"
> stripSuffix "xy" "hello"
None
> stripSuffix "" "hi"
Some "hi"
```

## `contains`

```
contains : String -> String -> Bool
```

True when `needle` occurs anywhere in `haystack` (the empty string is
contained in everything).


*(doctest — run by `medaka test`)*

```medaka
> contains "ell" "hello"
True
> contains "xyz" "hello"
False
```

## `indexOf`

```
indexOf : String -> String -> Option Int
```

Codepoint index of the first occurrence of `needle` in `haystack`, or
`None`.  Host-backed byte search (`stringIndexOf`) reported as a codepoint
index — no interpreted per-char scan.


*(doctest — run by `medaka test`)*

```medaka
> indexOf "lo" "hello"
Some 3
> indexOf "z" "hello"
None
```

## `lastIndexOf`

```
lastIndexOf : String -> String -> Option Int
```

Codepoint index of the *last* occurrence of `needle` in `haystack`, or
`None`.  Walks forward from each hit (advancing one codepoint so overlapping
matches still count), keeping the latest.


*(doctest — run by `medaka test`)*

```medaka
> lastIndexOf "l" "hello"
Some 3
> lastIndexOf "z" "hello"
None
```

## `countOccurrences`

```
countOccurrences : String -> String -> Int
```

Number of non-overlapping occurrences of `needle` in `haystack` (`0` for
the empty needle).


*(doctest — run by `medaka test`)*

```medaka
> countOccurrences "l" "hello"
2
> countOccurrences "ll" "lllll"
2
```

## `prepend`

```
prepend : String -> String -> String
```

Prepend a prefix; `flip` of `Semigroup.append`.

## `concat`

```
concat : List String -> String
```

Concatenate all strings in order.


*(doctest — run by `medaka test`)*

```medaka
> concat ["a", "bc", "d"]
"abcd"
```

## `join`

```
join : String -> List String -> String
```

Concatenate with `sep` between each adjacent pair.


*(doctest — run by `medaka test`)*

```medaka
> join ", " ["a", "b", "c"]
"a, b, c"
```

## `repeat`

```
repeat : Int -> String -> String
```

Repeat the string `n` times (empty when `n <= 0`).

Built by doubling (`repeatDbl`) rather than one recursive call per copy,
so the interpreted call depth is `O(log n)` instead of `O(n)` — a
linear-depth version hits the evaluator's call-depth cap around n ≈ 25000
(#1728).


*(doctest — run by `medaka test`)*

```medaka
> repeat 3 "ab"
"ababab"
```

*(doctest — run by `medaka test`)*

```medaka
> repeat 0 "ab"
""
```

*(doctest — run by `medaka test`)*

```medaka
> repeat (0 - 1) "ab"
""
```

*(doctest — run by `medaka test`)*

```medaka
> stringLength (repeat 30000 "x")
30000
```

## `reverse`

```
reverse : String -> String
```

Reverse the codepoints of a string.


*(doctest — run by `medaka test`)*

```medaka
> reverse "abc"
"cba"
```

## `trimLeft`

```
trimLeft : String -> String
```

Strip leading whitespace.  Finds the first non-space codepoint index, then
slices — no rebuild.

## `trimRight`

```
trimRight : String -> String
```

Strip trailing whitespace.

## `trim`

```
trim : String -> String
```

Strip whitespace from both ends.


*(doctest — run by `medaka test`)*

```medaka
> trim "  hi  "
"hi"
```

## `toUpper`

```
toUpper : String -> String
```

Uppercase every character. **ASCII-only** (issue #417): a non-ASCII byte
passes through unchanged, so this is byte-wise `'a'..'z'` mapping, not
Unicode case folding — it never expands 1→N (`ß` stays `ß`, not `SS`).


*(doctest — run by `medaka test`)*

```medaka
> toUpper "Straße"
"STRAßE"
```

## `toLower`

```
toLower : String -> String
```

Lowercase every character. **ASCII-only** (issue #417): a non-ASCII byte
passes through unchanged.


*(doctest — run by `medaka test`)*

```medaka
> toLower "HÉLLO"
"hÉllo"
```

## `capitalize`

```
capitalize : String -> String
```

Uppercase the first character, leave the rest alone.


*(doctest — run by `medaka test`)*

```medaka
> capitalize "hello"
"Hello"
```

## `replace`

```
replace : String -> String -> String -> String
```

Replace the first occurrence of `old` with `new`; unchanged if absent or
if `old` is empty.


*(doctest — run by `medaka test`)*

```medaka
> replace "l" "L" "hello"
"heLlo"
```

## `replaceAll`

```
replaceAll : String -> String -> String -> String
```

Replace every non-overlapping occurrence of `old` with `new`.


*(doctest — run by `medaka test`)*

```medaka
> replaceAll "l" "L" "hello"
"heLLo"
```

## `sliceClamped`

```
sliceClamped : Int -> Int -> String -> String
```

Substring `[lo, hi)` by codepoint, clamped to the string bounds (never
panics; use `s.[lo..hi]` to panic on OOB instead).


*(doctest — run by `medaka test`)*

```medaka
> sliceClamped 1 4 "hello"
"ell"
```

## `take`

```
take : Int -> String -> String
```

First `n` codepoints (fewer if shorter).


*(doctest — run by `medaka test`)*

```medaka
> take 3 "hello"
"hel"
```

## `drop`

```
drop : Int -> String -> String
```

Drop the first `n` codepoints.


*(doctest — run by `medaka test`)*

```medaka
> drop 3 "hello"
"lo"
```

## `splitAt`

```
splitAt : Int -> String -> (String, String)
```

`(take n s, drop n s)`.


*(doctest — run by `medaka test`)*

```medaka
> splitAt 2 "hello"
("he", "llo")
```

## `split`

```
split : String -> String -> List String
```

Split on `sep`, dropping the separators.  An empty `sep` yields `[s]`.


*(doctest — run by `medaka test`)*

```medaka
> split "," "a,b,c"
["a", "b", "c"]
> split "," "abc"
["abc"]
```

## `lines`

```
lines : String -> List String
```

Split into lines on `\n`, also stripping a trailing `\r` (so `\r\n` works).


*(doctest — run by `medaka test`)*

```medaka
> lines "a\nb\nc"
["a", "b", "c"]
```

## `words`

```
words : String -> List String
```

Split on runs of whitespace, dropping empty fields.  Each word is a
`stringSlice` of the original — no per-char rebuild.


*(doctest — run by `medaka test`)*

```medaka
> words "  hello   world "
["hello", "world"]
```

## `unlines`

```
unlines : List String -> String
```

Join with `\n` and append a trailing newline.


*(doctest — run by `medaka test`)*

```medaka
> unlines ["a", "b"]
"a\nb\n"
```

## `unwords`

```
unwords : List String -> String
```

Join with single spaces.


*(doctest — run by `medaka test`)*

```medaka
> unwords ["a", "b", "c"]
"a b c"
```

## `padLeft`

```
padLeft : Int -> Char -> String -> String
```

Left-pad with `c` up to total length `n` (unchanged if already `>= n`).


*(doctest — run by `medaka test`)*

```medaka
> padLeft 5 '.' "ab"
"...ab"
```

## `padRight`

```
padRight : Int -> Char -> String -> String
```

Right-pad with `c` up to total length `n`.


*(doctest — run by `medaka test`)*

```medaka
> padRight 5 '.' "ab"
"ab..."
```

## `center`

```
center : Int -> Char -> String -> String
```

Center the string in width `n`, padding with `c`; any odd extra goes on
the right.


*(doctest — run by `medaka test`)*

```medaka
> center 5 '.' "ab"
".ab.."
```

## `Eq String`

```
impl Eq String
```

## `Semigroup String`

```
impl Semigroup String
```

## `Monoid String`

```
impl Monoid String
```

## `Ord String`

```
impl Ord String
```

## `Debug String`

```
impl Debug String
```

`Debug String`/`Debug Char` render a *quoted, escaped literal* (`debug "hi"` is
`"hi"`, `debug 'a'` is `'a'`) via the `debugStringLit`/`debugCharLit` externs —
round-trippable, matching Haskell, and distinct from `println`'s raw output.
They live here in the prelude (not `string.mdk`) so that `debug`-ing a String
or Char — the most common doctest result type — resolves without importing
`string`, alongside the other primitive `Debug` impls (Phase 92).

## `Display String`

```
impl Display String
```

## `Hashable String`

```
impl Hashable String
```

## `Index String Int Char`

```
impl Index String Int Char
```

`index s i` is the codepoint `Char` of `s` at position `i` (`s[i]` sugar
dispatches here; codepoints, not grapheme clusters -- matches `toChars`).
Raises the coded `indexError` (E-INDEX-OOB) when `i` is out of range.  No
`IndexMut` impl: `String` is immutable.

## `Slice String`

```
impl Slice String
```

`slice s lo hi` is the substring of `s` over `[lo, hi)` (codepoints).
Out-of-range bounds are clamped by the underlying `stringSlice`, matching
stdlib `String.sliceClamped`.


*(doctest — run by `medaka test`)*

```medaka
> slice "hello" 1 4
"ell"
```

## `Arbitrary String`

```
impl Arbitrary String
```

## `Generic String`

```
impl Generic String
```

