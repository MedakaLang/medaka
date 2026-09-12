# regex

Regular expressions, matched in linear time.

Patterns use Perl syntax restricted to the regular subset, the dialect Go
`regexp` and RE2 accept. There are no backreferences and no lookaround, and
in exchange a match costs `O(n * m)` in subject length and pattern size
with no subject that makes it blow up. When more than one match is
possible the leftmost one wins, and among the matches starting there the
one the pattern prefers: alternation order first, greedy before lazy. So
`a|ab` matches `"a"` in `"ab"`, which is what Perl and Go give and not
POSIX leftmost-longest.

Positions are codepoint offsets, as in `string.indexOf`. `.` matches any
codepoint but `\n`, and `\d`, `\w`, `\s`, `\b` and `(?i)` folding are
ASCII only, matching `string.isDigit` and `string.toUpper`.

A subject may also be a UTF-8 byte buffer rather than a `String`:
`isFullMatchBytes` and `findBytes` match over a window of an `Array Int`
with each byte a code 0..255, which is what a protocol grammar whose limits
are stated in bytes wants.

`compile` reports a bad pattern as an `Err`, and `mustCompile` panics,
which suits a pattern written as a literal. A top-level binding is
evaluated once, so `wordRe = mustCompile "\\w+"` compiles one time
however often it is used.

Every escape in a pattern needs its backslash doubled in Medaka source,
because a plain string literal accepts only `\n`, `\t`, `\r`, `\0`, `\\`,
`\"` and `\u{...}`. Write `\d` as `"\\d"` and a literal brace as `"\\{"`.

The syntax accepted is:

- `x`, `\.`, `\\`, `\n`, `\t`, `\r`, `\xHH`, `\u{HEX}`: one literal
codepoint.
- `.`: any codepoint but `\n`, or any at all under `(?s)`.
- `[abc]`, `[a-z0-9]`, `[^...]`, with `\d`, `\w`, `\s` and their
complements usable inside.
- `\d`, `\D`, `\w`, `\W`, `\s`, `\S`: ASCII digit, word
(`[A-Za-z0-9_]`), space (`[ \t\n\r]`), and complements.
- `^`, `$`: start and end of the subject, or of a line under `(?m)`.
- `\b`, `\B`: ASCII word boundary and its complement.
- `ab`, `a|b`, `(...)`, `(?:...)`: concatenation, alternation, capturing
and non-capturing group.
- `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}`: greedy repetition, and `*?`,
`+?`, `??`, `{n,m}?` for the lazy forms.
- `(?i)`, `(?m)`, `(?s)` and combinations, at the start of the pattern
only.

A `{` that does not open a valid bound is a literal `{`. Named groups,
POSIX classes, Unicode classes and inline flag scoping are rejected with
a message naming what is missing.

## Types

### `Regex`

```
data Regex
  = Regex { src : String, prog : Array Inst, ngroups : Int, multiline : Bool }
```

A compiled pattern.

Values are immutable and safe to share. `Debug` renders the source
pattern. There is no `Eq` or `Ord` instance.

Instances: `Debug`

### `RegexError`

```
data RegexError
  = RegexError { message : String, position : Int }
```

Why a pattern would not compile, and where.

`position` is the codepoint offset in the pattern at which the parser
gave up.

Instances: `Eq`, `Debug`

### `Group`

```
data Group
  = Group { start : Int, end : Int, text : String }
```

One capture group's span and text.

`start` and `end` are codepoint offsets into the subject, `end`
exclusive.

Instances: `Eq`, `Debug`

### `Match`

```
data Match
  = Match { start : Int, end : Int, text : String, groups : List (Option Group) }
```

One match: its span, its text, and its capture groups.

`groups` holds group 1 onwards in pattern order, with `None` for a group
that did not take part in the match.

Instances: `Eq`, `Debug`

## Character sets

## Pattern tree

## Parser

## Program

## Pike VM

## Compiling a pattern

### `compile`

```
compile : String -> Result RegexError Regex
```

The pattern compiled, or an `Err` naming what is wrong and where.

```medaka
> map source (compile "a+b")
Ok "a+b"
> compile "a("
Err RegexError { message = "pattern is missing a closing )", position = 2 }
```

### `mustCompile`

```
mustCompile : String -> Regex
```

The pattern compiled, panicking when it does not compile.

For a pattern written as a literal, where a failure is a mistake in the
program rather than in the data. A top-level binding is evaluated once, so
the compilation happens one time. Use `compile` for a pattern that comes
from input.

```medaka
> source (mustCompile "[0-9]+")
"[0-9]+"
```

### `source`

```
source : Regex -> String
```

The pattern the regex was compiled from.

```medaka
> source (mustCompile "^\\d+$")
"^\\d+$"
```

### `escape`

```
escape : String -> String
```

The text as a pattern matching exactly itself, every metacharacter
quoted.

This is how a literal, a glob, or a SQL `LIKE` pattern becomes a regex:
translate the wildcards and send everything else through `escape`.

```medaka
> escape "a.b*c"
"a\\.b\\*c"
> isFullMatch (mustCompile (escape "1+1=2")) "1+1=2"
True
```

## Matching

### `isMatch`

```
isMatch : Regex -> String -> Bool
```

Whether the pattern matches anywhere in the subject.

```medaka
> isMatch (mustCompile "\\d") "abc7"
True
> isMatch (mustCompile "\\d") "abc"
False
```

### `isFullMatch`

```
isFullMatch : Regex -> String -> Bool
```

Whether the pattern matches the whole subject.

The validator shape: anchored at both ends, so a pattern that would match
a prefix does not pass. Among the whole-subject matches the pattern still
picks its preferred one, so `isFullMatch` is not `isMatch` of an anchored
pattern with a shorter alternative first.

```medaka
> isFullMatch (mustCompile "[a-z]+") "abc"
True
> isFullMatch (mustCompile "[a-z]+") "abc1"
False
```

### `find`

```
find : Regex -> String -> Option Match
```

The leftmost match, or `None` when the pattern does not match.

```medaka
> find (mustCompile "\\d+") "ab123cd"
Some Match { start = 2, end = 5, text = "123", groups = [] }
> find (mustCompile "z") "ab"
None
```

### `findFrom`

```
findFrom : Int -> Regex -> String -> Option Match
```

The leftmost match that starts at or after `from`.

`from` is clamped to the subject. `^` and `$` still mean the ends of the
whole subject, not of the searched tail.

```medaka
> map (m => m.start) (findFrom 3 (mustCompile "a") "aaaaa")
Some 3
> findFrom 3 (mustCompile "^a") "aaaaa"
None
```

### `fullMatch`

```
fullMatch : Regex -> String -> Option Match
```

The match covering the whole subject, or `None`.

```medaka
> map (m => m.text) (fullMatch (mustCompile "a|ab") "ab")
Some "ab"
> fullMatch (mustCompile "a") "ab"
None
```

## Byte subjects

### `isFullMatchBytes`

```
isFullMatchBytes : Regex -> Array Int -> Int -> Int -> Bool
```

Whether the pattern matches the whole of `bytes[start..end)`, each byte
taken as a code 0..255.

The validator shape for a byte buffer, and the reason a protocol grammar
wants this door: a bound written into the pattern counts BYTES, which is
what a DNS label, a DID or an RFC 7230 token means by its limits, and the
window grades a slice of a larger buffer without copying it. `start` and
`end` are clamped to the buffer, and `^`, `$` and `\b` mean the ends of the
window.

A pattern reaching this door should name only ASCII: `[a-z]` matches the
byte 97, and a non-ASCII codepoint arrives as its two or more UTF-8 bytes,
each of them outside every ASCII class. `toUtf8 "abc"` is `[|97, 98, 99|]`.

```medaka
> isFullMatchBytes (mustCompile "[a-z]+") [|97, 98, 99|] 0 3
True
> isFullMatchBytes (mustCompile "[a-z]+") [|97, 98, 99, 46|] 0 3
True
> isFullMatchBytes (mustCompile "[a-z]+") [|97, 98, 99, 46|] 0 4
False
```

### `findBytes`

```
findBytes : Regex -> Array Int -> Int -> Int -> Option Match
```

The leftmost match in `bytes[start..end)`, or `None`.

The peer of `find` over a byte buffer. `start`, `end` and the reported
offsets are byte offsets into the whole buffer, and the match's text and
each group's text are the matched bytes decoded as UTF-8, so a span that
cuts a codepoint decodes the way `fromUtf8` decodes any malformed input.
Keeping byte patterns ASCII is what keeps that from arising.

```medaka
> map (m => m.text) (findBytes (mustCompile "[0-9]+") [|97, 49, 50, 98|] 0 4)
Some "12"
> map (m => m.start) (findBytes (mustCompile "[0-9]+") [|97, 49, 50, 98|] 0 4)
Some 1
> findBytes (mustCompile "[0-9]+") [|97, 49, 50, 98|] 0 1
None
```

### `findAll`

```
findAll : Regex -> String -> List Match
```

Every match, left to right, none of them overlapping.

An empty match is kept, except directly at the end of the previous match:
`\d*` over `"a1b"` reports the empty match before `a`, `"1"`, and the
empty match at the end.

```medaka
> map (m => m.text) (findAll (mustCompile "\\d+") "a1b22c")
["1", "22"]
> map (m => m.text) (findAll (mustCompile "\\d*") "a1b")
["", "1", ""]
```

## Groups

## Replacing and splitting

### `replace`

```
replace : Regex -> String -> String -> String
```

The subject with the first match replaced by `repl`.

In `repl`, `$0` is the whole match, `$1` to `$9` are the capture groups,
and `$$` is a literal `$`. A group that did not take part expands to the
empty string, and a `$` before anything else is itself.

```medaka
> replace (mustCompile "\\d+") "N" "a1b2"
"aNb2"
> replace (mustCompile "(\\w+)@(\\w+)") "$2/$1" "user@host"
"host/user"
```

### `replaceAll`

```
replaceAll : Regex -> String -> String -> String
```

The subject with every match replaced by `repl`.

`repl` expands as in `replace`.

```medaka
> replaceAll (mustCompile "\\s+") " " "a  b\tc"
"a b c"
> replaceAll (mustCompile "a*") "-" "abc"
"-b-c-"
```

### `replaceAllWith`

```
replaceAllWith : Regex -> (Match -> <e> String) -> String -> <e> String
```

The subject with every match replaced by `f` applied to it.

Nothing in the result is rescanned, so a replacement that looks like the
pattern is left alone.

```medaka
> replaceAllWith (mustCompile "\\d") (m => "[" ++ m.text ++ "]") "a1b2"
"a[1]b[2]"
```

### `split`

```
split : Regex -> String -> List String
```

The subject cut at every match, with the matches dropped.

A leading or trailing separator leaves an empty piece, as `string.split`
does, so joining the pieces back with a literal separator recovers the
subject. A subject with no match is returned whole.

```medaka
> split (mustCompile ",\\s*") "a, b,c"
["a", "b", "c"]
> split (mustCompile ",") ",a,"
["", "a", ""]
```

## Anchors, classes, and flags

## Linear time

## Properties

## Instances

