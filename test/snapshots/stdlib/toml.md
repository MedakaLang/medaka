# META
source_lines=878
stages=DESUGAR,MARK
# SOURCE
{- | A reader for a subset of TOML.

   `parse` reads a document with `[section]` and `[[table]]` headers and
   keys whose values are double-quoted strings, arrays of strings,
   integers, or booleans, with `#` comments. Anything else (floats, dates,
   multi-line strings, inline tables, dotted keys, and escape sequences) is
   an error, never silently dropped.

   The parsed `Toml` is a flat list of keys and values, with every key
   qualified by its section: `name` under `[package]` is `"package.name"`,
   and a key under the `i`-th `[[gate]]` header is `"gate.i.name"`.
   `getString`, `getInt`, `getBool` and `getArray` look a value up by that
   qualified key; `tableCount` and
   `tableEntry` work with array-of-table entries. There is no writer. -}

-- This module is the general TOML reader: it knows nothing about
-- `medaka.toml`'s schema.  The `[package]`/`[workspace]` accessors live in
-- `compiler/support/manifest.mdk`.

import list.{reverse}
import map.{Map(..), get, insertWith}
import string.{lines, toInt, startsWith, drop, indexOf, contains}
import core.{Display}
import regex.{Regex, mustCompile, find as reFind}

-- # The document

-- | A value: a string, an array of strings, an integer, or a boolean.
public export data TomlValue =
  | TString String
  | TArray (List String)
  | TInt Int
  | TBool Bool

-- | A parsed document: its keys, qualified by section, with their values.
public export data Toml = Toml (List (String, TomlValue))

-- ── Comment stripping ────────────────────────────────────────────────────────

-- Strip a `#` comment from a line, respecting double-quoted strings so
-- `entry = "foo#bar"` is preserved.
stripComment : String -> String
stripComment s =
  let arr = stringToChars s
  let n = arrayLength arr
  stripCommentGo arr 0 n False []

stripCommentGo : Array Char -> Int -> Int -> Bool -> List Char -> String
stripCommentGo arr i n inStr acc
  | i >= n = stringFromChars (arrayFromList (reverse acc))
  | otherwise = stripCommentStep arr i n inStr acc (arrayGetUnsafe i arr)

stripCommentStep : Array Char ->
  Int ->
  Int ->
  Bool ->
  List Char ->
  Char ->
  String
stripCommentStep arr i n inStr acc c
  | charCode c == 34 = stripCommentGo arr (i + 1) n (not inStr) (c :: acc)
  | charCode c == 35 && not inStr =
    stringFromChars (arrayFromList (reverse acc))
  | otherwise = stripCommentGo arr (i + 1) n inStr (c :: acc)

-- ── String value parser ──────────────────────────────────────────────────────

-- Parse a double-quoted string from an Array Char starting at position i.
-- Returns Ok (value, nextIndex) or Err message.
parseQuotedStr : Array Char -> Int -> Result String (String, Int)
parseQuotedStr arr i
  | i >= arrayLength arr = Err "unexpected end of input"
  | arrayGetUnsafe i arr == '"' = parseQuotedBody arr (i + 1) []
  | otherwise = Err "expected '\"'"

parseQuotedBody : Array Char -> Int -> List Char -> Result String (String, Int)
parseQuotedBody arr i acc
  | i >= arrayLength arr = Err "unterminated string"
  | arrayGetUnsafe i arr == '"' =
    Ok (stringFromChars (arrayFromList (reverse acc)), i + 1)
  | otherwise = parseQuotedBody arr (i + 1) (arrayGetUnsafe i arr :: acc)

-- ── Array value parser ───────────────────────────────────────────────────────

-- Parse a `["str1", "str2"]` array starting at position `i` (must point at `[`).
parseArrayValue : Array Char -> Int -> Result String (List String, Int)
parseArrayValue arr i
  | i >= arrayLength arr = Err "unexpected end of input"
  | arrayGetUnsafe i arr == '[' = parseArrayItems arr (i + 1) []
  | otherwise = Err "expected '['"

-- Skip spaces and parse a string item, or close on `]`.  Called at the start
-- of the array and again after each comma, i.e. wherever an item (or the
-- close) is expected next.
parseArrayItems : Array Char ->
  Int ->
  List String ->
  Result String (List String, Int)
parseArrayItems arr i acc
  | i >= arrayLength arr = Err "unterminated array"
  | arrayGetUnsafe i arr == ']' = Ok (reverse acc, i + 1)
  | arrayGetUnsafe i arr == ' ' = parseArrayItems arr (i + 1) acc
  | arrayGetUnsafe i arr == '\t' = parseArrayItems arr (i + 1) acc
  | arrayGetUnsafe i arr == '"' = parseArrayItemStr arr i acc
  | otherwise =
    Err
      (stringConcat [
        "unexpected char in array: '",
        charToStr (arrayGetUnsafe i arr),
        "'",
      ])

parseArrayItemStr : Array Char ->
  Int ->
  List String ->
  Result String (List String, Int)
parseArrayItemStr arr i acc = match parseQuotedStr arr i
  Err e => Err e
  Ok (s, j) => parseArraySep arr j (s :: acc)

-- After a parsed item: only a `,` (another item may follow, a trailing comma
-- before `]` is fine) or `]` (close) is valid next.  Anything else, most
-- commonly another quoted item with no comma between, `["x" "y"]`, is a
-- malformed array and must be rejected loudly rather than silently accepted
-- as two adjacent items.
parseArraySep : Array Char ->
  Int ->
  List String ->
  Result String (List String, Int)
parseArraySep arr i acc
  | i >= arrayLength arr = Err "unterminated array"
  | arrayGetUnsafe i arr == ' ' = parseArraySep arr (i + 1) acc
  | arrayGetUnsafe i arr == '\t' = parseArraySep arr (i + 1) acc
  | arrayGetUnsafe i arr == ',' = parseArrayItems arr (i + 1) acc
  | arrayGetUnsafe i arr == ']' = Ok (reverse acc, i + 1)
  | otherwise =
    Err
      (stringConcat [
        "expected ',' or ']' in array, found: '",
        charToStr (arrayGetUnsafe i arr),
        "'",
      ])

-- ── Key-value line parser ────────────────────────────────────────────────────

skipSpaces : Array Char -> Int -> Int -> Int
skipSpaces arr i n
  | i >= n = n
  | arrayGetUnsafe i arr == ' ' = skipSpaces arr (i + 1) n
  | arrayGetUnsafe i arr == '\t' = skipSpaces arr (i + 1) n
  | otherwise = i

-- Parse `key = value` where value is a quoted string or array.
parseKv : String -> Result String (String, TomlValue)
parseKv line =
  let arr = stringToChars line
  let n = arrayLength arr
  findEq arr n 0

findEq : Array Char -> Int -> Int -> Result String (String, TomlValue)
findEq arr n i
  | i >= n = Err (stringConcat ["expected '=' in: ", stringFromChars arr])
  | arrayGetUnsafe i arr == '=' = parseKvAfterEq arr n i
  | otherwise = findEq arr n (i + 1)

parseKvAfterEq : Array Char -> Int -> Int -> Result String (String, TomlValue)
parseKvAfterEq arr n eq =
  let keyRaw = stringFromChars (arrayMakeWith eq (k => arrayGetUnsafe k arr))
  let key = asciiTrim keyRaw
  -- Dotted keys (`foo.bar = "zzz"`) are unsupported; reject loudly rather
  -- than silently accepting a dot as an ordinary key character.
  if contains "." key then
    Err
      (stringConcat [
        "dotted key '", key, "' is not supported: use table headers instead"
      ])
  else
    let valStart = skipSpaces arr (eq + 1) n
    parseKvValue arr n valStart key

parseKvValue : Array Char ->
  Int ->
  Int ->
  String ->
  Result String (String, TomlValue)
parseKvValue arr n i key
  | i >= n = Err (stringConcat ["missing value for key: ", key])
  | arrayGetUnsafe i arr == '"' = parseKvStr arr i key
  | arrayGetUnsafe i arr == '[' = parseKvArr arr i key
  | otherwise = parseKvScalar (restOfLine arr n i) key

-- After a value parser hands back `nextIndex`, the rest of the line must be
-- empty (once trimmed); comments are already stripped upstream
-- (`stripComment`, called in `parseLinesAcc` before `parseKv` ever runs).
-- Anything left over is trailing garbage: `name = "abc" this is garbage`, a
-- missing comma between array items (`["x" "y"]`), or, the same root cause,
-- a triple-quoted string, whose second `"` of the opening `"""` reads as the
-- closing quote and leaves `"x"""` unconsumed.
checkLineConsumed : Array Char -> Int -> String -> Result String Unit
checkLineConsumed arr j key =
  let trailing = restOfLine arr (arrayLength arr) j
  if trailing == "" then
    Ok ()
  else
    Err
      (stringConcat [
        "trailing content after value for key '", key, "': ", trailing
      ])

parseKvStr : Array Char -> Int -> String -> Result String (String, TomlValue)
parseKvStr arr i key = match parseQuotedStr arr i
  Err e => Err e
  Ok (s, j) => map (_ => (key, TString s)) (checkLineConsumed arr j key)

parseKvArr : Array Char -> Int -> String -> Result String (String, TomlValue)
parseKvArr arr i key = match parseArrayValue arr i
  Err e => Err e
  Ok (xs, j) => map (_ => (key, TArray xs)) (checkLineConsumed arr j key)

-- The remaining characters of the line from `i`, trimmed.  Used for the
-- unquoted scalar forms (integer / boolean), which run to end-of-line.
restOfLine : Array Char -> Int -> Int -> String
restOfLine arr n i =
  asciiTrim
    (stringFromChars (arrayMakeWith (n - i) (j => arrayGetUnsafe (i + j) arr)))

-- Unquoted scalar: `true`/`false`, or an integer.  Anything else (an inline
-- table `{k = v}`, a float, a datetime, a bare word) is an error, never a
-- silent drop: the whole point of this reader is that an unmodelled
-- construct is loud.
parseKvScalar : String -> String -> Result String (String, TomlValue)
parseKvScalar tok key
  | tok == "true" = Ok (key, TBool True)
  | tok == "false" = Ok (key, TBool False)
  | otherwise = match toInt tok
    Some n => Ok (key, TInt n)
    None =>
      Err
        (stringConcat [
          "unsupported value for key '", key, "': ", tok,
          " (expected a quoted string, a string array, an integer, or true/false)"
        ])

-- ── Document parser ──────────────────────────────────────────────────────────

-- A header line: `[name]` opens a plain table, `[[name]]` opens the next
-- element of an array of tables.
-- lint-disable-next-line rule-clone-type
data Header = HTable String | HArrayTable String

arrayTableRe : Regex
arrayTableRe = mustCompile "^\\[\\[(.+)\\]\\]$"

tableRe : Regex
tableRe = mustCompile "^\\[(.+)\\]$"

-- Detect a section header and classify it, or return None.
-- `[[t]]` is checked first: it also satisfies the `[t]` shape.
parseHeader : String -> Option Header
parseHeader s = match reFind arrayTableRe s
  Some m => match m.groups
    (Some g) :: [] => Some (HArrayTable (asciiTrim g.text))
    _ => None
  None => match reFind tableRe s
    Some m => match m.groups
      (Some g) :: [] => Some (HTable (asciiTrim g.text))
      _ => None
    None => None

-- Qualify a key relative to the current section.  Every section qualifies;
-- `[package]` is not special.
qualifyKey : String -> String -> String
qualifyKey section key
  | section == "" = key
  | otherwise = stringConcat [section, ".", key]

-- How many `[[name]]` elements have been opened so far, per table name.
seenCount : String -> List (String, Int) -> Int
seenCount _ [] = 0
seenCount name ((k, c) :: rest)
  | k == name = c
  | otherwise = seenCount name rest

bumpCount : String -> List (String, Int) -> List (String, Int)
bumpCount name [] = [(name, 1)]
bumpCount name ((k, c) :: rest)
  | k == name = (k, c + 1) :: rest
  | otherwise = (k, c) :: bumpCount name rest

parseLinesAcc : List String ->
  String ->
  List (String, Int) ->
  List (String, TomlValue) ->
  Result String (List (String, TomlValue))
parseLinesAcc [] _ _ acc = Ok (reverse acc)
parseLinesAcc (l :: ls) section counts acc =
  let trimmed = asciiTrim (stripComment l)
  if trimmed == "" then
    parseLinesAcc ls section counts acc
  else match parseHeader trimmed
    Some (HTable hdr) => parseLinesAcc ls hdr counts acc
    Some (HArrayTable hdr) =>
      let idx = seenCount hdr counts
      parseLinesAcc
        ls
        (stringConcat [hdr, ".", intToString idx])
        (bumpCount hdr counts)
        acc
    None => match parseKv trimmed
      Err e => Err e
      Ok (k, v) =>
        parseLinesAcc ls section counts ((qualifyKey section k, v) :: acc)

-- # Parsing

{- | The document written in a TOML string, or `Err` with a message for
   the first line that could not be read.

   Keys are qualified by their section. Comments and blank lines are
   ignored.

   > parse "[package]\nname = \"hello\"\nversion = \"0.1.0\""
   Ok (Toml [("package.name", TString "hello"), ("package.version", TString "0.1.0")])
   > parse "[[gate]]\nname = \"a\"\n[[gate]]\nname = \"b\""
   Ok (Toml [("gate.0.name", TString "a"), ("gate.1.name", TString "b")]) -}
export
parse : String -> Result String Toml
parse s = map Toml (parseLinesAcc (lines s) "" [] [])

-- > parse "[workspace]\nmembers = [\"pkg-a\", \"pkg-b\"]" == Ok (Toml [("workspace.members", TArray ["pkg-a", "pkg-b"])])
-- True
-- > parse "[limits]\nretries = 3\nverbose = true\noffset = -7" == Ok (Toml [("limits.retries", TInt 3), ("limits.verbose", TBool True), ("limits.offset", TInt (0 - 7))])
-- True
-- > parse "# just a comment\n\nname = \"x\"" == Ok (Toml [("name", TString "x")])
-- True
-- > parse "name = \"hello\" # a comment" == Ok (Toml [("name", TString "hello")])
-- True

-- Parse-error cases.  An unmodelled construct is an `Err`, not a silent
-- drop: a line with no `=`, a bare unquoted word, and an inline table each
-- fail.

{- > parse "bad line no equals"
   Err "expected '=' in: bad line no equals"

   > parse "[package]\nname = unterminated"
   Err "unsupported value for key 'name': unterminated (expected a quoted string, a string array, an integer, or true/false)"

   An inline table is rejected loudly rather than dropped:

   > parse "[server]\naddr = {host = \"h\", port = 1}"
   Err "unsupported value for key 'addr': {host = \"h\", port = 1} (expected a quoted string, a string array, an integer, or true/false)"

   Trailing garbage after a closed string value is rejected loudly, not
   silently dropped:

   > parse "name = \"abc\" this is garbage"
   Err "trailing content after value for key 'name': this is garbage"

   A well-formed string on its own line still parses correctly (no
   regression):

   > parse "name = \"abc\""
   Ok (Toml [("name", TString "abc")])

   Trailing garbage after a closed array value is rejected loudly:

   > parse "oracles = [\"x\"] junk"
   Err "trailing content after value for key 'oracles': junk"

   A missing comma between array items is rejected loudly, not silently
   accepted as two adjacent strings:

   > parse "oracles = [\"x\" \"y\"]"
   Err "expected ',' or ']' in array, found: '\"'"

   A well-formed array on its own line still parses correctly (no
   regression):

   > parse "oracles = [\"x\", \"y\"]"
   Ok (Toml [("oracles", TArray ["x", "y"])])

   A triple-quoted (multiline) string is rejected loudly rather than
   mis-parsing to a wrong value; this is the same "line fully consumed" check
   as the two trailing-garbage cases above:

   > parse "name = \"\"\"x\"\"\""
   Err "trailing content after value for key 'name': \"x\"\"\""

   A dotted key is rejected loudly:

   > parse "foo.bar = \"zzz\""
   Err "dotted key 'foo.bar' is not supported: use table headers instead"

   A well-formed key under a table header still parses correctly (no
   regression):

   > parse "[foo]\nbar = \"zzz\""
   Ok (Toml [("foo.bar", TString "zzz")]) -}

-- # Accessors

lookupKvs : String -> List (String, TomlValue) -> Option TomlValue
lookupKvs _ [] = None
lookupKvs key ((k, v) :: rest)
  | k == key = Some v
  | otherwise = lookupKvs key rest

-- Private helpers: parse a TOML string and look up one field (used in doctests).
parseGetStr : String -> String -> Option String
parseGetStr field src = match parse src
  Err _ => None
  Ok doc => getString field doc

parseGetArr : String -> String -> Option (List String)
parseGetArr field src = match parse src
  Err _ => None
  Ok doc => getArray field doc

parseGetInt : String -> String -> Option Int
parseGetInt field src = match parse src
  Err _ => None
  Ok doc => getInt field doc

parseGetBool : String -> String -> Option Bool
parseGetBool field src = match parse src
  Err _ => None
  Ok doc => getBool field doc

parseTableCount : String -> String -> Int
parseTableCount name src = match parse src
  Err _ => 0
  Ok doc => tableCount name doc

parseTableEntryStr : String -> Int -> String -> String -> Option String
parseTableEntryStr name i field src = match parse src
  Err _ => None
  Ok doc => match tableEntry name i doc
    None => None
    Some e => getString field e

{- | The string at a qualified key, or `None` when the key is absent or
   holds another kind of value.

   > parseGetStr "package.name" "[package]\nname = \"medaka\"\nversion = \"1.0.0\"\nentry = \"main.mdk\""
   Some "medaka"
   > parseGetStr "missing" "[package]\nname = \"x\""
   None -}
export
getString : String -> Toml -> Option String
getString key (Toml kvs) = match lookupKvs key kvs
  Some (TString s) => Some s
  _ => None

-- > parseGetStr "workspace.members" "[workspace]\nmembers = [\"a\"]"
-- None
-- > parseGetStr "server.host" "[package]\nname = \"x\""
-- None

{- | The array of strings at a qualified key, or `None` when the key is
   absent or holds another kind of value.

   > parseGetArr "workspace.members" "[workspace]\nmembers = [\"pkg-a\", \"pkg-b\"]"
   Some ["pkg-a", "pkg-b"]
   > parseGetArr "workspace.members" "[workspace]\nmembers = []"
   Some [] -}
export
getArray : String -> Toml -> Option (List String)
getArray key (Toml kvs) = match lookupKvs key kvs
  Some (TArray xs) => Some xs
  _ => None

-- > parseGetArr "package.name" "[package]\nname = \"x\"\nversion = \"0.1.0\"\nentry = \"main.mdk\""
-- None
-- > parseGetArr "workspace.members" "[package]\nname = \"x\""
-- None

{- | The integer at a qualified key, or `None` when the key is absent or
   holds another kind of value.

   > parseGetInt "limits.retries" "[limits]\nretries = 3"
   Some 3
   > parseGetInt "package.name" "[package]\nname = \"x\""
   None -}
export
getInt : String -> Toml -> Option Int
getInt key (Toml kvs) = match lookupKvs key kvs
  Some (TInt n) => Some n
  _ => None

-- > parseGetInt "limits.offset" "[limits]\noffset = -7" == Some (0 - 7)
-- True

{- | The boolean at a qualified key, or `None` when the key is absent or
   holds another kind of value.

   > parseGetBool "limits.verbose" "[limits]\nverbose = true"
   Some True
   > parseGetBool "limits.retries" "[limits]\nretries = 3"
   None -}
export
getBool : String -> Toml -> Option Bool
getBool key (Toml kvs) = match lookupKvs key kvs
  Some (TBool b) => Some b
  _ => None

-- > parseGetBool "limits.verbose" "[limits]\nverbose = false"
-- Some False

-- # Arrays of tables

-- The 0-based index in a key of the shape `<name>.<idx>.<field>`, or None.
tableIdxOf : String -> String -> Option Int
tableIdxOf prefix key =
  if not (startsWith prefix key) then
    None
  else
    let rest = drop (stringLength prefix) key
    match indexOf "." rest
      None => None
      Some d => toInt (stringSlice 0 d rest)

tableCountGo : String -> List (String, TomlValue) -> Int -> Int
tableCountGo _ [] best = best
tableCountGo prefix ((k, _) :: rest) best = match tableIdxOf prefix k
  None => tableCountGo prefix rest best
  Some i => tableCountGo prefix rest (max (i + 1) best)

{- | The number of `[[name]]` entries in the document.

   > parseTableCount "gate" "[[gate]]\nname = \"a\"\n[[gate]]\nname = \"b\""
   2
   > parseTableCount "gate" "[package]\nname = \"x\""
   0 -}
export
tableCount : String -> Toml -> Int
tableCount name (Toml kvs) = tableCountGo (stringConcat [name, "."]) kvs 0

-- One scan of `kvs` for entry `i`: the entry's pairs with the prefix removed
-- (reversed) and the largest index + 1 seen over all keys, as `tableCount`
-- counts it, so an out-of-range `i` is told apart from an entry with no keys.
tableEntryGo : String ->
  String ->
  List (String, TomlValue) ->
  Int ->
  List (String, TomlValue) ->
  (Int, List (String, TomlValue))
tableEntryGo _ _ [] best acc = (best, acc)
tableEntryGo prefix entryPrefix ((k, v) :: rest) best acc =
  let best2 = match tableIdxOf prefix k
    None => best
    Some j => max (j + 1) best
  if startsWith entryPrefix k then
    tableEntryGo
      prefix
      entryPrefix
      rest
      best2
      ((drop (stringLength entryPrefix) k, v) :: acc)
  else
    tableEntryGo prefix entryPrefix rest best2 acc

{- | The `i`-th `[[name]]` entry, counting from `0`, as a document of its
   own, or `None` when `i` is out of range.

   The entry's keys are unqualified, so `getString` and its siblings apply
   to it directly.

   > parseTableEntryStr "gate" 1 "name" "[[gate]]\nname = \"a\"\n[[gate]]\nname = \"b\""
   Some "b"
   > parseTableEntryStr "gate" 9 "name" "[[gate]]\nname = \"a\""
   None -}
export
tableEntry : String -> Int -> Toml -> Option Toml
tableEntry name i (Toml kvs)
  | i < 0 = None
  | otherwise =
    let entryPrefix = stringConcat [name, ".", intToString i, "."]
    let (count, entry) =
      tableEntryGo (stringConcat [name, "."]) entryPrefix kvs 0 []
    if i >= count then None else Some (Toml (reverse entry))

-- The entry index and unqualified key of `k` when it belongs to an entry of
-- `prefix`, spelled the way `tableEntry` spells it.
entryKeyOf : String -> String -> Option (Int, String)
entryKeyOf prefix k = match tableIdxOf prefix k
  Some i if i >= 0 =>
    let entryPrefix = stringConcat [prefix, intToString i, "."]
    if startsWith entryPrefix k then
      Some (i, drop (stringLength entryPrefix) k)
    else
      None
  _ => None

-- Groups the pairs of `kvs` by entry index, document order within an entry.
-- Folds from the right so each cons lands in front of the later pairs.
groupEntries : String ->
  List (String, TomlValue) ->
  Map Int (List (String, TomlValue))
groupEntries _ [] = Tip
groupEntries prefix ((k, v) :: rest) =
  let groups = groupEntries prefix rest
  match entryKeyOf prefix k
    None => groups
    Some (i, key) => insertWith (++) i [(key, v)] groups

-- The most entries `tableEntries` will read. It fills a gap with one empty entry
-- per index below the largest, so an unchecked index would build a list as long
-- as that index.
tableEntryLimit : Int
tableEntryLimit = 100000

{- | Every `[[name]]` entry in the document, in document order.

   Entry `i` is what `tableEntry name i` returns, but the document is read
   once for all of them. The list is empty when there are no entries. The
   result is an `Err` when the largest entry index is 100000 or more, so a
   document holds at most 100000 entries. The message names the table and
   that index.

   > map (map (getString "name")) (tableEntries "gate" (Toml [("gate.0.name", TString "a"), ("gate.1.name", TString "b")]))
   Ok [Some "a", Some "b"]
   > tableEntries "gate" (Toml [("package.name", TString "x")])
   Ok []
   > tableEntries "gate" (Toml [("gate.100000.name", TString "x")])
   Err "too many [[gate]] entries: index 100000 is past the limit of 100000" -}
export
tableEntries : String -> Toml -> Result String (List Toml)
tableEntries name (Toml kvs) =
  let prefix = stringConcat [name, "."]
  let count = tableCountGo prefix kvs 0
  let groups = groupEntries prefix kvs
  match count > tableEntryLimit
    True =>
      Err
        "too many [[\{name}]] entries: index \{count - 1} is past the limit of \{tableEntryLimit}"
    False => Ok (map (i => Toml (optionOr [] (get i groups))) [0..count])

-- ── Eq and Debug instances ──────────────────────────────────────────────────

{- Structural equality on `TomlValue`.

   > eqTomlValue (TString "a") (TString "a")
   True

   > eqTomlValue (TArray ["a", "b"]) (TArray ["a", "b"])
   True

   Different constructors never compare equal:

   > eqTomlValue (TString "a") (TArray ["a"])
   False -}
eqTomlValue : TomlValue -> TomlValue -> Bool
eqTomlValue (TString a) (TString b) = a == b
eqTomlValue (TArray a) (TArray b) = eqStrLists a b
eqTomlValue (TInt a) (TInt b) = a == b
eqTomlValue (TBool a) (TBool b) = a == b
eqTomlValue _ _ = False

eqStrLists : List String -> List String -> Bool
eqStrLists [] [] = True
eqStrLists (x :: xs) (y :: ys) = x == y && eqStrLists xs ys
eqStrLists _ _ = False

eqKvList : List (String, TomlValue) -> List (String, TomlValue) -> Bool
eqKvList [] [] = True
eqKvList ((k1, v1) :: rest1) ((k2, v2) :: rest2) =
  k1 == k2 && eqTomlValue v1 v2 && eqKvList rest1 rest2
eqKvList _ _ = False

export impl Eq TomlValue where
  eq = eqTomlValue

export impl Eq Toml where
  eq (Toml a) (Toml b) = eqKvList a b

{- Render a `TomlValue` for debugging.

   > debugTomlValue (TString "hi")
   "TString \"hi\""

   > debugTomlValue (TArray ["a", "b"])
   "TArray [\"a\", \"b\"]"

   > debugTomlValue (TInt 42)
   "TInt 42"

   > debugTomlValue (TBool True)
   "TBool True" -}
debugTomlValue : TomlValue -> String
debugTomlValue (TString s) = stringConcat ["TString ", debug s]
debugTomlValue (TArray xs) = stringConcat ["TArray ", debugStrList xs]
debugTomlValue (TInt n) = stringConcat ["TInt ", intToString n]
debugTomlValue (TBool b) =
  stringConcat ["TBool ", if b then "True" else "False"]

debugStrList : List String -> String
debugStrList xs = stringConcat ["[", joinDebugStrs xs, "]"]

joinDebugStrs : List String -> String
joinDebugStrs [] = ""
joinDebugStrs (x :: []) = debug x
joinDebugStrs (x :: xs) = stringConcat [debug x, ", ", joinDebugStrs xs]

debugKvPair : (String, TomlValue) -> String
debugKvPair (k, v) = stringConcat ["(", debug k, ", ", debugTomlValue v, ")"]

debugKvList : List (String, TomlValue) -> String
debugKvList [] = ""
debugKvList (p :: []) = debugKvPair p
debugKvList (p :: ps) = stringConcat [debugKvPair p, ", ", debugKvList ps]

export impl Debug TomlValue where
  debug = debugTomlValue

export impl Debug Toml where
  debug (Toml kvs) = stringConcat ["Toml [", debugKvList kvs, "]"]

-- `Display` is not a TOML renderer.  Emitting a document `parse` could read
-- back is deferred behind #2240 (the `toml`-onto-`parsec` consolidation);
-- shipping one here under the `Display` name would be that deferred work
-- wearing a disguise.  What `Display` owes is a stable, legible rendering of
-- the value, in the same `T { … }` shape `Display (Map k v)` and
-- `Display (Set a)` use.  Values keep TOML's own spelling for their scalars
-- (a string is quoted, a bool is `true`/`false`) so that the four variants
-- stay distinguishable: an unquoted `TString "1"` would render exactly like
-- `TInt 1`.  That injectivity is the law under test.

displayTomlValue : TomlValue -> String
displayTomlValue (TString s) = debug s
displayTomlValue (TArray xs) = debugStrList xs
displayTomlValue (TInt n) = intToString n
displayTomlValue (TBool b) = if b then "true" else "false"

displayKvPair : (String, TomlValue) -> String
displayKvPair (k, v) = stringConcat [k, " = ", displayTomlValue v]

displayKvList : List (String, TomlValue) -> String
displayKvList [] = ""
displayKvList (p :: []) = displayKvPair p
displayKvList (p :: ps) = stringConcat [displayKvPair p, ", ", displayKvList ps]

{- | `display` renders a value in TOML's own spelling: a string quoted, a
   boolean as `true` or `false`.

   > display (TString "hi")
   "\"hi\""
   > display (TBool True)
   "true" -}
export impl Display TomlValue where
  display = displayTomlValue

-- > display (TInt 42)
-- "42"
-- > display (TArray ["a", "b"])
-- "[\"a\", \"b\"]"

{- | `display` renders a document as `Toml { key = value, ... }`.

   This is not TOML text; `parse` cannot read it back.

   > display (Toml [("a.b", TInt 1), ("c", TBool False)])
   "Toml { a.b = 1, c = false }"
   > display (Toml [])
   "Toml {}" -}
export impl Display Toml where
  display (Toml []) = "Toml {}"
  display (Toml kvs) = stringConcat ["Toml { ", displayKvList kvs, " }"]

-- ── Property tests ───────────────────────────────────────────────────────────

-- Build a `[package]` document whose `version` is the given (safely-quotable)
-- string.  Used by the round-trip properties below.
mkPackage : String -> String
mkPackage v = stringConcat ["[package]\nname = \"demo\"\nversion = \"", v, "\""]

-- `intToString n` only ever yields characters in `[-0-9]`, none of which are
-- TOML-significant, so embedding it in a quoted value is safe.

prop "a section key round-trips an Int-derived value" (n : Int) =
  parseGetStr "package.version" (mkPackage (intToString n))
    == Some (intToString n)

prop "a sibling key is stable regardless of the varying value" (n : Int) =
  parseGetStr "package.name" (mkPackage (intToString n)) == Some "demo"

prop "parse is deterministic" (n : Int) =
  parse (mkPackage (intToString n)) == parse (mkPackage (intToString n))

-- An unquoted integer round-trips through `TInt` for any Int, sign included.
mkInt : Int -> String
mkInt n = stringConcat ["[limits]\nretries = ", intToString n]

prop "an unquoted integer round-trips as TInt" (n : Int) =
  parseGetInt "limits.retries" (mkInt n) == Some n

-- `[[gate]]` indexing: the i-th entry's `name` is the i-th generated name, so
-- entries never blend into one another however many are present.
mkGates : Int -> String
mkGates k = stringConcat [
  "[[gate]]\nname = \"g",
  intToString k,
  "\"\n[[gate]]\nname = \"h",
  intToString k,
  "\"\n",
]

prop "array-of-tables entries stay separate" (k : Int) =
  parseTableCount "gate" (mkGates k) == 2
    && parseTableEntryStr "gate" 0 "name" (mkGates k)
      == Some ("g" ++ intToString k)
    && parseTableEntryStr "gate" 1 "name" (mkGates k)
      == Some ("h" ++ intToString k)

-- ── Instance laws ───────────────────────────────────────────────────────

-- LAW: `Display TomlValue` is INJECTIVE across the four variants -- a
-- rendering that cannot tell a quoted `TString "1"` from an `TInt 1` is not a
-- rendering of the value.  This is the clause that pins the TOML scalar
-- spelling (quotes, lowercase bools) rather than the prelude's.
prop "Display TomlValue separates the four variants" (n : Int) (b : Bool) =
  let s = intToString n
  let vs = [TString s, TArray [s], TInt n, TBool b]
  allDistinct (map display vs)

allDistinct : List String -> Bool
allDistinct [] = True
allDistinct (x :: rest) = all (x /= _) rest && allDistinct rest

-- LAW: `Display Toml` agrees with `Eq Toml` -- equal documents render
-- identically, and documents differing in any entry render differently, so
-- the text is a faithful stand-in for the value in a test failure.
prop "Display Toml agrees with Eq Toml" (k : String) (n : Int) =
  let a = Toml [(k, TInt n)]
  let b = Toml [(k, TInt n)]
  let c = Toml [(k, TInt (n + 1))]
  let d = Toml [(k ++ "x", TInt n)]
  display a == display b
    && eq a b
    && display a /= display c
    && display a /= display d

-- LAW: every key and every value reaches the output (nothing is silently
-- dropped as the entry list grows).
prop "Display Toml renders every entry" (k : String) (n : Int) =
  let one = display (Toml [(k, TInt n)])
  let two = display (Toml [(k, TInt n), (k ++ "2", TInt n)])
  stringLength two > stringLength one
    && contains (displayTomlValue (TInt n)) two

-- Trims ASCII whitespace only. TOML whitespace is tab and space (TOML v1.0.0, "Spec").
-- A non-ASCII space such as U+00A0 is data here, so `string.trim` (which strips
-- it) would be wrong.
asciiTrim : String -> String
-- The same few lines live in each package that needs a spec-bound trim; the
-- packages share no module that could host them, and string must not export it.
-- lint-disable-next-line rule-stdlib-reimpl, rule-duplicate-body
asciiTrim s =
  let chars = stringToChars s
  let n = arrayLength chars
  let lo = asciiTrimFront chars 0 n
  stringSlice lo (asciiTrimBack chars (n - 1) lo + 1) s

asciiTrimFront : Array Char -> Int -> Int -> Int
-- Part of asciiTrim, duplicated with it for the same reason.
-- lint-disable-next-line rule-duplicate-body
asciiTrimFront chars i n
  | i >= n = n
  | charIsSpace (arrayGetUnsafe i chars) = asciiTrimFront chars (i + 1) n
  | otherwise = i

asciiTrimBack : Array Char -> Int -> Int -> Int
-- Part of asciiTrim, duplicated with it for the same reason.
-- lint-disable-next-line rule-duplicate-body
asciiTrimBack chars i lo
  | i < lo = lo - 1
  | charIsSpace (arrayGetUnsafe i chars) = asciiTrimBack chars (i - 1) lo
  | otherwise = i
# DESUGAR
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("map") ((mem "Map" true) (mem "get" false) (mem "insertWith" false))))
(DUse false (UseGroup ("string") ((mem "lines" false) (mem "toInt" false) (mem "startsWith" false) (mem "drop" false) (mem "indexOf" false) (mem "contains" false))))
(DUse false (UseGroup ("core") ((mem "Display" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "mustCompile" false) (mem "find" false "reFind"))))
(DData Public "TomlValue" () ((variant "TString" (ConPos (TyCon "String"))) (variant "TArray" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "TInt" (ConPos (TyCon "Int"))) (variant "TBool" (ConPos (TyCon "Bool")))) ())
(DData Public "Toml" () ((variant "Toml" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))))) ())
(DTypeSig false "stripComment" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripComment" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (ELit (LInt 0))) (EVar "n")) (EVar "False")) (EListLit)))))
(DTypeSig false "stripCommentGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "String")))))))
(DFunDef false "stripCommentGo" ((PVar "arr") (PVar "i") (PVar "n") (PVar "inStr") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentStep") (EVar "arr")) (EVar "i")) (EVar "n")) (EVar "inStr")) (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stripCommentStep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Char") (TyCon "String"))))))))
(DFunDef false "stripCommentStep" ((PVar "arr") (PVar "i") (PVar "n") (PVar "inStr") (PVar "acc") (PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "not") (EVar "inStr"))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 35))) (EApp (EVar "not") (EVar "inStr"))) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "inStr")) (EBinOp "::" (EVar "c") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseQuotedStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "parseQuotedStr" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseQuotedBody") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected '\"'"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseQuotedBody" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "parseQuotedBody" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated string"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EVar "Ok") (ETuple (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "acc")))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "parseQuotedBody") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseArrayValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "parseArrayValue" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected '['"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseArrayItems" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArrayItems" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated array"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "]"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverse") (EVar "acc")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseArrayItemStr") (EVar "arr")) (EVar "i")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unexpected char in array: '")) (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "parseArrayItemStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArrayItemStr" ((PVar "arr") (PVar "i") (PVar "acc")) (EMatch (EApp (EApp (EVar "parseQuotedStr") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "s") (PVar "j"))) () (EApp (EApp (EApp (EVar "parseArraySep") (EVar "arr")) (EVar "j")) (EBinOp "::" (EVar "s") (EVar "acc"))))))
(DTypeSig false "parseArraySep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArraySep" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated array"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "parseArraySep") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "parseArraySep") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar ","))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "]"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverse") (EVar "acc")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "expected ',' or ']' in array, found: '")) (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "skipSpaces" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipSpaces" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseKv" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))
(DFunDef false "parseKv" ((PVar "line")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "line"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "findEq") (EVar "arr")) (EVar "n")) (ELit (LInt 0))))))
(DTypeSig false "findEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "findEq" ((PVar "arr") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "expected '=' in: ")) (EApp (EVar "stringFromChars") (EVar "arr"))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "="))) (EApp (EApp (EApp (EVar "parseKvAfterEq") (EVar "arr")) (EVar "n")) (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "findEq") (EVar "arr")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseKvAfterEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvAfterEq" ((PVar "arr") (PVar "n") (PVar "eq")) (EBlock (DoLet false false (PVar "keyRaw") (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EVar "eq")) (ELam ((PVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr")))))) (DoLet false false (PVar "key") (EApp (EVar "asciiTrim") (EVar "keyRaw"))) (DoExpr (EIf (EApp (EApp (EVar "contains") (ELit (LString "."))) (EVar "key")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "dotted key '")) (EVar "key") (ELit (LString "' is not supported: use table headers instead"))))) (EBlock (DoLet false false (PVar "valStart") (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "eq") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseKvValue") (EVar "arr")) (EVar "n")) (EVar "valStart")) (EVar "key"))))))))
(DTypeSig false "parseKvValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue"))))))))
(DFunDef false "parseKvValue" ((PVar "arr") (PVar "n") (PVar "i") (PVar "key")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "missing value for key: ")) (EVar "key")))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseKvStr") (EVar "arr")) (EVar "i")) (EVar "key")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "parseKvArr") (EVar "arr")) (EVar "i")) (EVar "key")) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseKvScalar") (EApp (EApp (EApp (EVar "restOfLine") (EVar "arr")) (EVar "n")) (EVar "i"))) (EVar "key")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "checkLineConsumed" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "checkLineConsumed" ((PVar "arr") (PVar "j") (PVar "key")) (EBlock (DoLet false false (PVar "trailing") (EApp (EApp (EApp (EVar "restOfLine") (EVar "arr")) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "j"))) (DoExpr (EIf (EBinOp "==" (EVar "trailing") (ELit (LString ""))) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "trailing content after value for key '")) (EVar "key") (ELit (LString "': ")) (EVar "trailing"))))))))
(DTypeSig false "parseKvStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvStr" ((PVar "arr") (PVar "i") (PVar "key")) (EMatch (EApp (EApp (EVar "parseQuotedStr") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "s") (PVar "j"))) () (EApp (EApp (EVar "map") (ELam (PWild) (ETuple (EVar "key") (EApp (EVar "TString") (EVar "s"))))) (EApp (EApp (EApp (EVar "checkLineConsumed") (EVar "arr")) (EVar "j")) (EVar "key"))))))
(DTypeSig false "parseKvArr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvArr" ((PVar "arr") (PVar "i") (PVar "key")) (EMatch (EApp (EApp (EVar "parseArrayValue") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "xs") (PVar "j"))) () (EApp (EApp (EVar "map") (ELam (PWild) (ETuple (EVar "key") (EApp (EVar "TArray") (EVar "xs"))))) (EApp (EApp (EApp (EVar "checkLineConsumed") (EVar "arr")) (EVar "j")) (EVar "key"))))))
(DTypeSig false "restOfLine" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "restOfLine" ((PVar "arr") (PVar "n") (PVar "i")) (EApp (EVar "asciiTrim") (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "n") (EVar "i"))) (ELam ((PVar "j")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "arr")))))))
(DTypeSig false "parseKvScalar" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue"))))))
(DFunDef false "parseKvScalar" ((PVar "tok") (PVar "key")) (EIf (EBinOp "==" (EVar "tok") (ELit (LString "true"))) (EApp (EVar "Ok") (ETuple (EVar "key") (EApp (EVar "TBool") (EVar "True")))) (EIf (EBinOp "==" (EVar "tok") (ELit (LString "false"))) (EApp (EVar "Ok") (ETuple (EVar "key") (EApp (EVar "TBool") (EVar "False")))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "toInt") (EVar "tok")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (ETuple (EVar "key") (EApp (EVar "TInt") (EVar "n"))))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unsupported value for key '")) (EVar "key") (ELit (LString "': ")) (EVar "tok") (ELit (LString " (expected a quoted string, a string array, an integer, or true/false)"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DData Private "Header" () ((variant "HTable" (ConPos (TyCon "String"))) (variant "HArrayTable" (ConPos (TyCon "String")))) ())
(DTypeSig false "arrayTableRe" (TyCon "Regex"))
(DFunDef false "arrayTableRe" () (EApp (EVar "mustCompile") (ELit (LString "^\\[\\[(.+)\\]\\]$"))))
(DTypeSig false "tableRe" (TyCon "Regex"))
(DFunDef false "tableRe" () (EApp (EVar "mustCompile") (ELit (LString "^\\[(.+)\\]$"))))
(DTypeSig false "parseHeader" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Header"))))
(DFunDef false "parseHeader" ((PVar "s")) (EMatch (EApp (EApp (EVar "reFind") (EVar "arrayTableRe")) (EVar "s")) (arm (PCon "Some" (PVar "m")) () (EMatch (EFieldAccess (EVar "m") "groups") (arm (PCons (PCon "Some" (PVar "g")) (PList)) () (EApp (EVar "Some") (EApp (EVar "HArrayTable") (EApp (EVar "asciiTrim") (EFieldAccess (EVar "g") "text"))))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "reFind") (EVar "tableRe")) (EVar "s")) (arm (PCon "Some" (PVar "m")) () (EMatch (EFieldAccess (EVar "m") "groups") (arm (PCons (PCon "Some" (PVar "g")) (PList)) () (EApp (EVar "Some") (EApp (EVar "HTable") (EApp (EVar "asciiTrim") (EFieldAccess (EVar "g") "text"))))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "qualifyKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "qualifyKey" ((PVar "section") (PVar "key")) (EIf (EBinOp "==" (EVar "section") (ELit (LString ""))) (EVar "key") (EIf (EVar "otherwise") (EApp (EVar "stringConcat") (EListLit (EVar "section") (ELit (LString ".")) (EVar "key"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "seenCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Int"))))
(DFunDef false "seenCount" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "seenCount" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "name")) (EVar "c") (EIf (EVar "otherwise") (EApp (EApp (EVar "seenCount") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bumpCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "bumpCount" ((PVar "name") (PList)) (EListLit (ETuple (EVar "name") (ELit (LInt 1)))))
(DFunDef false "bumpCount" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "name")) (EBinOp "::" (ETuple (EVar "k") (EBinOp "+" (EVar "c") (ELit (LInt 1)))) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "c")) (EApp (EApp (EVar "bumpCount") (EVar "name")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseLinesAcc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))))))))
(DFunDef false "parseLinesAcc" ((PList) PWild PWild (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverse") (EVar "acc"))))
(DFunDef false "parseLinesAcc" ((PCons (PVar "l") (PVar "ls")) (PVar "section") (PVar "counts") (PVar "acc")) (EBlock (DoLet false false (PVar "trimmed") (EApp (EVar "asciiTrim") (EApp (EVar "stripComment") (EVar "l")))) (DoExpr (EIf (EBinOp "==" (EVar "trimmed") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "section")) (EVar "counts")) (EVar "acc")) (EMatch (EApp (EVar "parseHeader") (EVar "trimmed")) (arm (PCon "Some" (PCon "HTable" (PVar "hdr"))) () (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "hdr")) (EVar "counts")) (EVar "acc"))) (arm (PCon "Some" (PCon "HArrayTable" (PVar "hdr"))) () (EBlock (DoLet false false (PVar "idx") (EApp (EApp (EVar "seenCount") (EVar "hdr")) (EVar "counts"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EApp (EVar "stringConcat") (EListLit (EVar "hdr") (ELit (LString ".")) (EApp (EVar "intToString") (EVar "idx"))))) (EApp (EApp (EVar "bumpCount") (EVar "hdr")) (EVar "counts"))) (EVar "acc"))))) (arm (PCon "None") () (EMatch (EApp (EVar "parseKv") (EVar "trimmed")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "k") (PVar "v"))) () (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "section")) (EVar "counts")) (EBinOp "::" (ETuple (EApp (EApp (EVar "qualifyKey") (EVar "section")) (EVar "k")) (EVar "v")) (EVar "acc")))))))))))
(DTypeSig true "parse" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Toml"))))
(DFunDef false "parse" ((PVar "s")) (EApp (EApp (EVar "map") (EVar "Toml")) (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EApp (EVar "lines") (EVar "s"))) (ELit (LString ""))) (EListLit)) (EListLit))))
(DTypeSig false "lookupKvs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyCon "Option") (TyCon "TomlValue")))))
(DFunDef false "lookupKvs" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupKvs" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "key")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseGetStr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "parseGetStr" ((PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "getString") (EVar "field")) (EVar "doc")))))
(DTypeSig false "parseGetArr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "parseGetArr" ((PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "doc")))))
(DTypeSig false "parseGetInt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "parseGetInt" ((PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "getInt") (EVar "field")) (EVar "doc")))))
(DTypeSig false "parseGetBool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Bool")))))
(DFunDef false "parseGetBool" ((PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "getBool") (EVar "field")) (EVar "doc")))))
(DTypeSig false "parseTableCount" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "parseTableCount" ((PVar "name") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (ELit (LInt 0))) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "tableCount") (EVar "name")) (EVar "doc")))))
(DTypeSig false "parseTableEntryStr" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "parseTableEntryStr" ((PVar "name") (PVar "i") (PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EMatch (EApp (EApp (EApp (EVar "tableEntry") (EVar "name")) (EVar "i")) (EVar "doc")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EVar "getString") (EVar "field")) (EVar "e")))))))
(DTypeSig true "getString" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "getString" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "Some" (PCon "TString" (PVar "s"))) () (EApp (EVar "Some") (EVar "s"))) (arm PWild () (EVar "None"))))
(DTypeSig true "getArray" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "getArray" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "Some" (PCon "TArray" (PVar "xs"))) () (EApp (EVar "Some") (EVar "xs"))) (arm PWild () (EVar "None"))))
(DTypeSig true "getInt" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "getInt" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "Some" (PCon "TInt" (PVar "n"))) () (EApp (EVar "Some") (EVar "n"))) (arm PWild () (EVar "None"))))
(DTypeSig true "getBool" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "Bool")))))
(DFunDef false "getBool" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "Some" (PCon "TBool" (PVar "b"))) () (EApp (EVar "Some") (EVar "b"))) (arm PWild () (EVar "None"))))
(DTypeSig false "tableIdxOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "tableIdxOf" ((PVar "prefix") (PVar "key")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "key"))) (EVar "None") (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "drop") (EApp (EVar "stringLength") (EVar "prefix"))) (EVar "key"))) (DoExpr (EMatch (EApp (EApp (EVar "indexOf") (ELit (LString "."))) (EVar "rest")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "d")) (EVar "rest")))))))))
(DTypeSig false "tableCountGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "tableCountGo" (PWild (PList) (PVar "best")) (EVar "best"))
(DFunDef false "tableCountGo" ((PVar "prefix") (PCons (PTuple (PVar "k") PWild) (PVar "rest")) (PVar "best")) (EMatch (EApp (EApp (EVar "tableIdxOf") (EVar "prefix")) (EVar "k")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "tableCountGo") (EVar "prefix")) (EVar "rest")) (EVar "best"))) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "tableCountGo") (EVar "prefix")) (EVar "rest")) (EApp (EApp (EVar "max") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "best"))))))
(DTypeSig true "tableCount" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyCon "Int"))))
(DFunDef false "tableCount" ((PVar "name") (PCon "Toml" (PVar "kvs"))) (EApp (EApp (EApp (EVar "tableCountGo") (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString "."))))) (EVar "kvs")) (ELit (LInt 0))))
(DTypeSig false "tableEntryGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))))))))))
(DFunDef false "tableEntryGo" (PWild PWild (PList) (PVar "best") (PVar "acc")) (ETuple (EVar "best") (EVar "acc")))
(DFunDef false "tableEntryGo" ((PVar "prefix") (PVar "entryPrefix") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "best") (PVar "acc")) (EBlock (DoLet false false (PVar "best2") (EMatch (EApp (EApp (EVar "tableIdxOf") (EVar "prefix")) (EVar "k")) (arm (PCon "None") () (EVar "best")) (arm (PCon "Some" (PVar "j")) () (EApp (EApp (EVar "max") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "best"))))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "entryPrefix")) (EVar "k")) (EApp (EApp (EApp (EApp (EApp (EVar "tableEntryGo") (EVar "prefix")) (EVar "entryPrefix")) (EVar "rest")) (EVar "best2")) (EBinOp "::" (ETuple (EApp (EApp (EVar "drop") (EApp (EVar "stringLength") (EVar "entryPrefix"))) (EVar "k")) (EVar "v")) (EVar "acc"))) (EApp (EApp (EApp (EApp (EApp (EVar "tableEntryGo") (EVar "prefix")) (EVar "entryPrefix")) (EVar "rest")) (EVar "best2")) (EVar "acc"))))))
(DTypeSig true "tableEntry" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "Toml"))))))
(DFunDef false "tableEntry" ((PVar "name") (PVar "i") (PCon "Toml" (PVar "kvs"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "entryPrefix") (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString ".")) (EApp (EVar "intToString") (EVar "i")) (ELit (LString "."))))) (DoLet false false (PTuple (PVar "count") (PVar "entry")) (EApp (EApp (EApp (EApp (EApp (EVar "tableEntryGo") (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString "."))))) (EVar "entryPrefix")) (EVar "kvs")) (ELit (LInt 0))) (EListLit))) (DoExpr (EIf (EBinOp ">=" (EVar "i") (EVar "count")) (EVar "None") (EApp (EVar "Some") (EApp (EVar "Toml") (EApp (EVar "reverse") (EVar "entry"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "entryKeyOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "String"))))))
(DFunDef false "entryKeyOf" ((PVar "prefix") (PVar "k")) (EMatch (EApp (EApp (EVar "tableIdxOf") (EVar "prefix")) (EVar "k")) (arm (PCon "Some" (PVar "i")) ((GBool (EBinOp ">=" (EVar "i") (ELit (LInt 0))))) (EBlock (DoLet false false (PVar "entryPrefix") (EApp (EVar "stringConcat") (EListLit (EVar "prefix") (EApp (EVar "intToString") (EVar "i")) (ELit (LString "."))))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "entryPrefix")) (EVar "k")) (EApp (EVar "Some") (ETuple (EVar "i") (EApp (EApp (EVar "drop") (EApp (EVar "stringLength") (EVar "entryPrefix"))) (EVar "k")))) (EVar "None"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "groupEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "groupEntries" (PWild (PList)) (EVar "Tip"))
(DFunDef false "groupEntries" ((PVar "prefix") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false (PVar "groups") (EApp (EApp (EVar "groupEntries") (EVar "prefix")) (EVar "rest"))) (DoExpr (EMatch (EApp (EApp (EVar "entryKeyOf") (EVar "prefix")) (EVar "k")) (arm (PCon "None") () (EVar "groups")) (arm (PCon "Some" (PTuple (PVar "i") (PVar "key"))) () (EApp (EApp (EApp (EApp (EVar "insertWith") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "++" (EVar "_a") (EVar "_b")))) (EVar "i")) (EListLit (ETuple (EVar "key") (EVar "v")))) (EVar "groups")))))))
(DTypeSig false "tableEntryLimit" (TyCon "Int"))
(DFunDef false "tableEntryLimit" () (ELit (LInt 100000)))
(DTypeSig true "tableEntries" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Toml"))))))
(DFunDef false "tableEntries" ((PVar "name") (PCon "Toml" (PVar "kvs"))) (EBlock (DoLet false false (PVar "prefix") (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString "."))))) (DoLet false false (PVar "count") (EApp (EApp (EApp (EVar "tableCountGo") (EVar "prefix")) (EVar "kvs")) (ELit (LInt 0)))) (DoLet false false (PVar "groups") (EApp (EApp (EVar "groupEntries") (EVar "prefix")) (EVar "kvs"))) (DoExpr (EMatch (EBinOp ">" (EVar "count") (EVar "tableEntryLimit")) (arm (PCon "True") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "too many [[")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "]] entries: index "))) (EApp (EVar "display") (EBinOp "-" (EVar "count") (ELit (LInt 1))))) (ELit (LString " is past the limit of "))) (EApp (EVar "display") (EVar "tableEntryLimit"))) (ELit (LString ""))))) (arm (PCon "False") () (EApp (EVar "Ok") (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EVar "Toml") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "get") (EVar "i")) (EVar "groups")))))) (ERangeList (ELit (LInt 0)) (EVar "count") false))))))))
(DTypeSig false "eqTomlValue" (TyFun (TyCon "TomlValue") (TyFun (TyCon "TomlValue") (TyCon "Bool"))))
(DFunDef false "eqTomlValue" ((PCon "TString" (PVar "a")) (PCon "TString" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "eqTomlValue" ((PCon "TArray" (PVar "a")) (PCon "TArray" (PVar "b"))) (EApp (EApp (EVar "eqStrLists") (EVar "a")) (EVar "b")))
(DFunDef false "eqTomlValue" ((PCon "TInt" (PVar "a")) (PCon "TInt" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "eqTomlValue" ((PCon "TBool" (PVar "a")) (PCon "TBool" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "eqTomlValue" (PWild PWild) (EVar "False"))
(DTypeSig false "eqStrLists" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "eqStrLists" ((PList) (PList)) (EVar "True"))
(DFunDef false "eqStrLists" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "&&" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "eqStrLists") (EVar "xs")) (EVar "ys"))))
(DFunDef false "eqStrLists" (PWild PWild) (EVar "False"))
(DTypeSig false "eqKvList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyCon "Bool"))))
(DFunDef false "eqKvList" ((PList) (PList)) (EVar "True"))
(DFunDef false "eqKvList" ((PCons (PTuple (PVar "k1") (PVar "v1")) (PVar "rest1")) (PCons (PTuple (PVar "k2") (PVar "v2")) (PVar "rest2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "k1") (EVar "k2")) (EApp (EApp (EVar "eqTomlValue") (EVar "v1")) (EVar "v2"))) (EApp (EApp (EVar "eqKvList") (EVar "rest1")) (EVar "rest2"))))
(DFunDef false "eqKvList" (PWild PWild) (EVar "False"))
(DImpl true "Eq" ((TyCon "TomlValue")) () ((im "eq" () (EVar "eqTomlValue"))))
(DImpl true "Eq" ((TyCon "Toml")) () ((im "eq" ((PCon "Toml" (PVar "a")) (PCon "Toml" (PVar "b"))) (EApp (EApp (EVar "eqKvList") (EVar "a")) (EVar "b")))))
(DTypeSig false "debugTomlValue" (TyFun (TyCon "TomlValue") (TyCon "String")))
(DFunDef false "debugTomlValue" ((PCon "TString" (PVar "s"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TString ")) (EApp (EVar "debug") (EVar "s")))))
(DFunDef false "debugTomlValue" ((PCon "TArray" (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TArray ")) (EApp (EVar "debugStrList") (EVar "xs")))))
(DFunDef false "debugTomlValue" ((PCon "TInt" (PVar "n"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TInt ")) (EApp (EVar "intToString") (EVar "n")))))
(DFunDef false "debugTomlValue" ((PCon "TBool" (PVar "b"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TBool ")) (EIf (EVar "b") (ELit (LString "True")) (ELit (LString "False"))))))
(DTypeSig false "debugStrList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "debugStrList" ((PVar "xs")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[")) (EApp (EVar "joinDebugStrs") (EVar "xs")) (ELit (LString "]")))))
(DTypeSig false "joinDebugStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinDebugStrs" ((PList)) (ELit (LString "")))
(DFunDef false "joinDebugStrs" ((PCons (PVar "x") (PList))) (EApp (EVar "debug") (EVar "x")))
(DFunDef false "joinDebugStrs" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "debug") (EVar "x")) (ELit (LString ", ")) (EApp (EVar "joinDebugStrs") (EVar "xs")))))
(DTypeSig false "debugKvPair" (TyFun (TyTuple (TyCon "String") (TyCon "TomlValue")) (TyCon "String")))
(DFunDef false "debugKvPair" ((PTuple (PVar "k") (PVar "v"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "(")) (EApp (EVar "debug") (EVar "k")) (ELit (LString ", ")) (EApp (EVar "debugTomlValue") (EVar "v")) (ELit (LString ")")))))
(DTypeSig false "debugKvList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyCon "String")))
(DFunDef false "debugKvList" ((PList)) (ELit (LString "")))
(DFunDef false "debugKvList" ((PCons (PVar "p") (PList))) (EApp (EVar "debugKvPair") (EVar "p")))
(DFunDef false "debugKvList" ((PCons (PVar "p") (PVar "ps"))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "debugKvPair") (EVar "p")) (ELit (LString ", ")) (EApp (EVar "debugKvList") (EVar "ps")))))
(DImpl true "Debug" ((TyCon "TomlValue")) () ((im "debug" () (EVar "debugTomlValue"))))
(DImpl true "Debug" ((TyCon "Toml")) () ((im "debug" ((PCon "Toml" (PVar "kvs"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Toml [")) (EApp (EVar "debugKvList") (EVar "kvs")) (ELit (LString "]")))))))
(DTypeSig false "displayTomlValue" (TyFun (TyCon "TomlValue") (TyCon "String")))
(DFunDef false "displayTomlValue" ((PCon "TString" (PVar "s"))) (EApp (EVar "debug") (EVar "s")))
(DFunDef false "displayTomlValue" ((PCon "TArray" (PVar "xs"))) (EApp (EVar "debugStrList") (EVar "xs")))
(DFunDef false "displayTomlValue" ((PCon "TInt" (PVar "n"))) (EApp (EVar "intToString") (EVar "n")))
(DFunDef false "displayTomlValue" ((PCon "TBool" (PVar "b"))) (EIf (EVar "b") (ELit (LString "true")) (ELit (LString "false"))))
(DTypeSig false "displayKvPair" (TyFun (TyTuple (TyCon "String") (TyCon "TomlValue")) (TyCon "String")))
(DFunDef false "displayKvPair" ((PTuple (PVar "k") (PVar "v"))) (EApp (EVar "stringConcat") (EListLit (EVar "k") (ELit (LString " = ")) (EApp (EVar "displayTomlValue") (EVar "v")))))
(DTypeSig false "displayKvList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyCon "String")))
(DFunDef false "displayKvList" ((PList)) (ELit (LString "")))
(DFunDef false "displayKvList" ((PCons (PVar "p") (PList))) (EApp (EVar "displayKvPair") (EVar "p")))
(DFunDef false "displayKvList" ((PCons (PVar "p") (PVar "ps"))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "displayKvPair") (EVar "p")) (ELit (LString ", ")) (EApp (EVar "displayKvList") (EVar "ps")))))
(DImpl true "Display" ((TyCon "TomlValue")) () ((im "display" () (EVar "displayTomlValue"))))
(DImpl true "Display" ((TyCon "Toml")) () ((im "display" ((PCon "Toml" (PList))) (ELit (LString "Toml {}"))) (im "display" ((PCon "Toml" (PVar "kvs"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Toml { ")) (EApp (EVar "displayKvList") (EVar "kvs")) (ELit (LString " }")))))))
(DTypeSig false "mkPackage" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "mkPackage" ((PVar "v")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[package]\nname = \"demo\"\nversion = \"")) (EVar "v") (ELit (LString "\"")))))
(DProp false "a section key round-trips an Int-derived value" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "parseGetStr") (ELit (LString "package.version"))) (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "Some") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "a sibling key is stable regardless of the varying value" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "parseGetStr") (ELit (LString "package.name"))) (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "Some") (ELit (LString "demo")))))
(DProp false "parse is deterministic" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parse") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n"))))))
(DTypeSig false "mkInt" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "mkInt" ((PVar "n")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[limits]\nretries = ")) (EApp (EVar "intToString") (EVar "n")))))
(DProp false "an unquoted integer round-trips as TInt" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "parseGetInt") (ELit (LString "limits.retries"))) (EApp (EVar "mkInt") (EVar "n"))) (EApp (EVar "Some") (EVar "n"))))
(DTypeSig false "mkGates" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "mkGates" ((PVar "k")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[[gate]]\nname = \"g")) (EApp (EVar "intToString") (EVar "k")) (ELit (LString "\"\n[[gate]]\nname = \"h")) (EApp (EVar "intToString") (EVar "k")) (ELit (LString "\"\n")))))
(DProp false "array-of-tables entries stay separate" ((pp "k" (TyCon "Int"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "parseTableCount") (ELit (LString "gate"))) (EApp (EVar "mkGates") (EVar "k"))) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EApp (EVar "parseTableEntryStr") (ELit (LString "gate"))) (ELit (LInt 0))) (ELit (LString "name"))) (EApp (EVar "mkGates") (EVar "k"))) (EApp (EVar "Some") (EBinOp "++" (ELit (LString "g")) (EApp (EVar "intToString") (EVar "k")))))) (EBinOp "==" (EApp (EApp (EApp (EApp (EVar "parseTableEntryStr") (ELit (LString "gate"))) (ELit (LInt 1))) (ELit (LString "name"))) (EApp (EVar "mkGates") (EVar "k"))) (EApp (EVar "Some") (EBinOp "++" (ELit (LString "h")) (EApp (EVar "intToString") (EVar "k")))))))
(DProp false "Display TomlValue separates the four variants" ((pp "n" (TyCon "Int")) (pp "b" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "intToString") (EVar "n"))) (DoLet false false (PVar "vs") (EListLit (EApp (EVar "TString") (EVar "s")) (EApp (EVar "TArray") (EListLit (EVar "s"))) (EApp (EVar "TInt") (EVar "n")) (EApp (EVar "TBool") (EVar "b")))) (DoExpr (EApp (EVar "allDistinct") (EApp (EApp (EVar "map") (EVar "display")) (EVar "vs"))))))
(DTypeSig false "allDistinct" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "allDistinct" ((PList)) (EVar "True"))
(DFunDef false "allDistinct" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "all") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "x") (EVar "_s")))) (EVar "rest")) (EApp (EVar "allDistinct") (EVar "rest"))))
(DProp false "Display Toml agrees with Eq Toml" ((pp "k" (TyCon "String")) (pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n")))))) (DoLet false false (PVar "b") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n")))))) (DoLet false false (PVar "c") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EBinOp "+" (EVar "n") (ELit (LInt 1)))))))) (DoLet false false (PVar "d") (EApp (EVar "Toml") (EListLit (ETuple (EBinOp "++" (EVar "k") (ELit (LString "x"))) (EApp (EVar "TInt") (EVar "n")))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "display") (EVar "a")) (EApp (EVar "display") (EVar "b"))) (EApp (EApp (EVar "eq") (EVar "a")) (EVar "b"))) (EBinOp "/=" (EApp (EVar "display") (EVar "a")) (EApp (EVar "display") (EVar "c")))) (EBinOp "/=" (EApp (EVar "display") (EVar "a")) (EApp (EVar "display") (EVar "d")))))))
(DProp false "Display Toml renders every entry" ((pp "k" (TyCon "String")) (pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "one") (EApp (EVar "display") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n"))))))) (DoLet false false (PVar "two") (EApp (EVar "display") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n"))) (ETuple (EBinOp "++" (EVar "k") (ELit (LString "2"))) (EApp (EVar "TInt") (EVar "n"))))))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "two")) (EApp (EVar "stringLength") (EVar "one"))) (EApp (EApp (EVar "contains") (EApp (EVar "displayTomlValue") (EApp (EVar "TInt") (EVar "n")))) (EVar "two"))))))
(DTypeSig false "asciiTrim" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "asciiTrim" ((PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "chars"))) (DoLet false false (PVar "lo") (EApp (EApp (EApp (EVar "asciiTrimFront") (EVar "chars")) (ELit (LInt 0))) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EBinOp "+" (EApp (EApp (EApp (EVar "asciiTrimBack") (EVar "chars")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "lo")) (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig false "asciiTrimFront" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "asciiTrimFront" ((PVar "chars") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "charIsSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars"))) (EApp (EApp (EApp (EVar "asciiTrimFront") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "asciiTrimBack" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "asciiTrimBack" ((PVar "chars") (PVar "i") (PVar "lo")) (EIf (EBinOp "<" (EVar "i") (EVar "lo")) (EBinOp "-" (EVar "lo") (ELit (LInt 1))) (EIf (EApp (EVar "charIsSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars"))) (EApp (EApp (EApp (EVar "asciiTrimBack") (EVar "chars")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "lo")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
# MARK
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseGroup ("map") ((mem "Map" true) (mem "get" false) (mem "insertWith" false))))
(DUse false (UseGroup ("string") ((mem "lines" false) (mem "toInt" false) (mem "startsWith" false) (mem "drop" false) (mem "indexOf" false) (mem "contains" false))))
(DUse false (UseGroup ("core") ((mem "Display" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "mustCompile" false) (mem "find" false "reFind"))))
(DData Public "TomlValue" () ((variant "TString" (ConPos (TyCon "String"))) (variant "TArray" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "TInt" (ConPos (TyCon "Int"))) (variant "TBool" (ConPos (TyCon "Bool")))) ())
(DData Public "Toml" () ((variant "Toml" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))))) ())
(DTypeSig false "stripComment" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripComment" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (ELit (LInt 0))) (EVar "n")) (EVar "False")) (EListLit)))))
(DTypeSig false "stripCommentGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "String")))))))
(DFunDef false "stripCommentGo" ((PVar "arr") (PVar "i") (PVar "n") (PVar "inStr") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentStep") (EVar "arr")) (EVar "i")) (EVar "n")) (EVar "inStr")) (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stripCommentStep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Char") (TyCon "String"))))))))
(DFunDef false "stripCommentStep" ((PVar "arr") (PVar "i") (PVar "n") (PVar "inStr") (PVar "acc") (PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "not") (EVar "inStr"))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 35))) (EApp (EVar "not") (EVar "inStr"))) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "inStr")) (EBinOp "::" (EVar "c") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseQuotedStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "parseQuotedStr" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseQuotedBody") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected '\"'"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseQuotedBody" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "parseQuotedBody" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated string"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EVar "Ok") (ETuple (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "reverse") (EVar "acc")))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "parseQuotedBody") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseArrayValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "parseArrayValue" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected '['"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseArrayItems" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArrayItems" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated array"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "]"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverse") (EVar "acc")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseArrayItemStr") (EVar "arr")) (EVar "i")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unexpected char in array: '")) (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "parseArrayItemStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArrayItemStr" ((PVar "arr") (PVar "i") (PVar "acc")) (EMatch (EApp (EApp (EVar "parseQuotedStr") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "s") (PVar "j"))) () (EApp (EApp (EApp (EVar "parseArraySep") (EVar "arr")) (EVar "j")) (EBinOp "::" (EVar "s") (EVar "acc"))))))
(DTypeSig false "parseArraySep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArraySep" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated array"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "parseArraySep") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "parseArraySep") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar ","))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "]"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverse") (EVar "acc")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "expected ',' or ']' in array, found: '")) (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "skipSpaces" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipSpaces" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseKv" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))
(DFunDef false "parseKv" ((PVar "line")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "line"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "findEq") (EVar "arr")) (EVar "n")) (ELit (LInt 0))))))
(DTypeSig false "findEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "findEq" ((PVar "arr") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "expected '=' in: ")) (EApp (EVar "stringFromChars") (EVar "arr"))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "="))) (EApp (EApp (EApp (EVar "parseKvAfterEq") (EVar "arr")) (EVar "n")) (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "findEq") (EVar "arr")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseKvAfterEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvAfterEq" ((PVar "arr") (PVar "n") (PVar "eq")) (EBlock (DoLet false false (PVar "keyRaw") (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EMethodRef "eq")) (ELam ((PVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr")))))) (DoLet false false (PVar "key") (EApp (EVar "asciiTrim") (EVar "keyRaw"))) (DoExpr (EIf (EApp (EApp (EVar "contains") (ELit (LString "."))) (EVar "key")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "dotted key '")) (EVar "key") (ELit (LString "' is not supported: use table headers instead"))))) (EBlock (DoLet false false (PVar "valStart") (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EMethodRef "eq") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseKvValue") (EVar "arr")) (EVar "n")) (EVar "valStart")) (EVar "key"))))))))
(DTypeSig false "parseKvValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue"))))))))
(DFunDef false "parseKvValue" ((PVar "arr") (PVar "n") (PVar "i") (PVar "key")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "missing value for key: ")) (EVar "key")))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseKvStr") (EVar "arr")) (EVar "i")) (EVar "key")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "parseKvArr") (EVar "arr")) (EVar "i")) (EVar "key")) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseKvScalar") (EApp (EApp (EApp (EVar "restOfLine") (EVar "arr")) (EVar "n")) (EVar "i"))) (EVar "key")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "checkLineConsumed" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "checkLineConsumed" ((PVar "arr") (PVar "j") (PVar "key")) (EBlock (DoLet false false (PVar "trailing") (EApp (EApp (EApp (EVar "restOfLine") (EVar "arr")) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "j"))) (DoExpr (EIf (EBinOp "==" (EVar "trailing") (ELit (LString ""))) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "trailing content after value for key '")) (EVar "key") (ELit (LString "': ")) (EVar "trailing"))))))))
(DTypeSig false "parseKvStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvStr" ((PVar "arr") (PVar "i") (PVar "key")) (EMatch (EApp (EApp (EVar "parseQuotedStr") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "s") (PVar "j"))) () (EApp (EApp (EMethodRef "map") (ELam (PWild) (ETuple (EVar "key") (EApp (EVar "TString") (EVar "s"))))) (EApp (EApp (EApp (EVar "checkLineConsumed") (EVar "arr")) (EVar "j")) (EVar "key"))))))
(DTypeSig false "parseKvArr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvArr" ((PVar "arr") (PVar "i") (PVar "key")) (EMatch (EApp (EApp (EVar "parseArrayValue") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "xs") (PVar "j"))) () (EApp (EApp (EMethodRef "map") (ELam (PWild) (ETuple (EVar "key") (EApp (EVar "TArray") (EVar "xs"))))) (EApp (EApp (EApp (EVar "checkLineConsumed") (EVar "arr")) (EVar "j")) (EVar "key"))))))
(DTypeSig false "restOfLine" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "restOfLine" ((PVar "arr") (PVar "n") (PVar "i")) (EApp (EVar "asciiTrim") (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "n") (EVar "i"))) (ELam ((PVar "j")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "arr")))))))
(DTypeSig false "parseKvScalar" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue"))))))
(DFunDef false "parseKvScalar" ((PVar "tok") (PVar "key")) (EIf (EBinOp "==" (EVar "tok") (ELit (LString "true"))) (EApp (EVar "Ok") (ETuple (EVar "key") (EApp (EVar "TBool") (EVar "True")))) (EIf (EBinOp "==" (EVar "tok") (ELit (LString "false"))) (EApp (EVar "Ok") (ETuple (EVar "key") (EApp (EVar "TBool") (EVar "False")))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "toInt") (EVar "tok")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (ETuple (EVar "key") (EApp (EVar "TInt") (EVar "n"))))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unsupported value for key '")) (EVar "key") (ELit (LString "': ")) (EVar "tok") (ELit (LString " (expected a quoted string, a string array, an integer, or true/false)"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DData Private "Header" () ((variant "HTable" (ConPos (TyCon "String"))) (variant "HArrayTable" (ConPos (TyCon "String")))) ())
(DTypeSig false "arrayTableRe" (TyCon "Regex"))
(DFunDef false "arrayTableRe" () (EApp (EVar "mustCompile") (ELit (LString "^\\[\\[(.+)\\]\\]$"))))
(DTypeSig false "tableRe" (TyCon "Regex"))
(DFunDef false "tableRe" () (EApp (EVar "mustCompile") (ELit (LString "^\\[(.+)\\]$"))))
(DTypeSig false "parseHeader" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Header"))))
(DFunDef false "parseHeader" ((PVar "s")) (EMatch (EApp (EApp (EVar "reFind") (EVar "arrayTableRe")) (EVar "s")) (arm (PCon "Some" (PVar "m")) () (EMatch (EFieldAccess (EVar "m") "groups") (arm (PCons (PCon "Some" (PVar "g")) (PList)) () (EApp (EVar "Some") (EApp (EVar "HArrayTable") (EApp (EVar "asciiTrim") (EFieldAccess (EVar "g") "text"))))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "reFind") (EVar "tableRe")) (EVar "s")) (arm (PCon "Some" (PVar "m")) () (EMatch (EFieldAccess (EVar "m") "groups") (arm (PCons (PCon "Some" (PVar "g")) (PList)) () (EApp (EVar "Some") (EApp (EVar "HTable") (EApp (EVar "asciiTrim") (EFieldAccess (EVar "g") "text"))))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "qualifyKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "qualifyKey" ((PVar "section") (PVar "key")) (EIf (EBinOp "==" (EVar "section") (ELit (LString ""))) (EVar "key") (EIf (EVar "otherwise") (EApp (EVar "stringConcat") (EListLit (EVar "section") (ELit (LString ".")) (EVar "key"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "seenCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Int"))))
(DFunDef false "seenCount" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "seenCount" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "name")) (EVar "c") (EIf (EVar "otherwise") (EApp (EApp (EVar "seenCount") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bumpCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "bumpCount" ((PVar "name") (PList)) (EListLit (ETuple (EVar "name") (ELit (LInt 1)))))
(DFunDef false "bumpCount" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "name")) (EBinOp "::" (ETuple (EVar "k") (EBinOp "+" (EVar "c") (ELit (LInt 1)))) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "c")) (EApp (EApp (EVar "bumpCount") (EVar "name")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseLinesAcc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))))))))
(DFunDef false "parseLinesAcc" ((PList) PWild PWild (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverse") (EVar "acc"))))
(DFunDef false "parseLinesAcc" ((PCons (PVar "l") (PVar "ls")) (PVar "section") (PVar "counts") (PVar "acc")) (EBlock (DoLet false false (PVar "trimmed") (EApp (EVar "asciiTrim") (EApp (EVar "stripComment") (EVar "l")))) (DoExpr (EIf (EBinOp "==" (EVar "trimmed") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "section")) (EVar "counts")) (EVar "acc")) (EMatch (EApp (EVar "parseHeader") (EVar "trimmed")) (arm (PCon "Some" (PCon "HTable" (PVar "hdr"))) () (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "hdr")) (EVar "counts")) (EVar "acc"))) (arm (PCon "Some" (PCon "HArrayTable" (PVar "hdr"))) () (EBlock (DoLet false false (PVar "idx") (EApp (EApp (EVar "seenCount") (EVar "hdr")) (EVar "counts"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EApp (EVar "stringConcat") (EListLit (EVar "hdr") (ELit (LString ".")) (EApp (EVar "intToString") (EVar "idx"))))) (EApp (EApp (EVar "bumpCount") (EVar "hdr")) (EVar "counts"))) (EVar "acc"))))) (arm (PCon "None") () (EMatch (EApp (EVar "parseKv") (EVar "trimmed")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "k") (PVar "v"))) () (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "section")) (EVar "counts")) (EBinOp "::" (ETuple (EApp (EApp (EVar "qualifyKey") (EVar "section")) (EVar "k")) (EVar "v")) (EVar "acc")))))))))))
(DTypeSig true "parse" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Toml"))))
(DFunDef false "parse" ((PVar "s")) (EApp (EApp (EMethodRef "map") (EVar "Toml")) (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EApp (EVar "lines") (EVar "s"))) (ELit (LString ""))) (EListLit)) (EListLit))))
(DTypeSig false "lookupKvs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyCon "Option") (TyCon "TomlValue")))))
(DFunDef false "lookupKvs" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupKvs" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "key")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseGetStr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "parseGetStr" ((PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "getString") (EVar "field")) (EVar "doc")))))
(DTypeSig false "parseGetArr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "parseGetArr" ((PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "doc")))))
(DTypeSig false "parseGetInt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "parseGetInt" ((PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "getInt") (EVar "field")) (EVar "doc")))))
(DTypeSig false "parseGetBool" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Bool")))))
(DFunDef false "parseGetBool" ((PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "getBool") (EVar "field")) (EVar "doc")))))
(DTypeSig false "parseTableCount" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "parseTableCount" ((PVar "name") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (ELit (LInt 0))) (arm (PCon "Ok" (PVar "doc")) () (EApp (EApp (EVar "tableCount") (EVar "name")) (EVar "doc")))))
(DTypeSig false "parseTableEntryStr" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "parseTableEntryStr" ((PVar "name") (PVar "i") (PVar "field") (PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "doc")) () (EMatch (EApp (EApp (EApp (EVar "tableEntry") (EVar "name")) (EVar "i")) (EVar "doc")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EVar "getString") (EVar "field")) (EVar "e")))))))
(DTypeSig true "getString" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "getString" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "Some" (PCon "TString" (PVar "s"))) () (EApp (EVar "Some") (EVar "s"))) (arm PWild () (EVar "None"))))
(DTypeSig true "getArray" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "getArray" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "Some" (PCon "TArray" (PVar "xs"))) () (EApp (EVar "Some") (EVar "xs"))) (arm PWild () (EVar "None"))))
(DTypeSig true "getInt" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "getInt" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "Some" (PCon "TInt" (PVar "n"))) () (EApp (EVar "Some") (EVar "n"))) (arm PWild () (EVar "None"))))
(DTypeSig true "getBool" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "Bool")))))
(DFunDef false "getBool" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "Some" (PCon "TBool" (PVar "b"))) () (EApp (EVar "Some") (EVar "b"))) (arm PWild () (EVar "None"))))
(DTypeSig false "tableIdxOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "tableIdxOf" ((PVar "prefix") (PVar "key")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "key"))) (EVar "None") (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "drop") (EApp (EVar "stringLength") (EVar "prefix"))) (EVar "key"))) (DoExpr (EMatch (EApp (EApp (EVar "indexOf") (ELit (LString "."))) (EVar "rest")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "d")) () (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "d")) (EVar "rest")))))))))
(DTypeSig false "tableCountGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "tableCountGo" (PWild (PList) (PVar "best")) (EVar "best"))
(DFunDef false "tableCountGo" ((PVar "prefix") (PCons (PTuple (PVar "k") PWild) (PVar "rest")) (PVar "best")) (EMatch (EApp (EApp (EVar "tableIdxOf") (EVar "prefix")) (EVar "k")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "tableCountGo") (EVar "prefix")) (EVar "rest")) (EVar "best"))) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "tableCountGo") (EVar "prefix")) (EVar "rest")) (EApp (EApp (EMethodRef "max") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "best"))))))
(DTypeSig true "tableCount" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyCon "Int"))))
(DFunDef false "tableCount" ((PVar "name") (PCon "Toml" (PVar "kvs"))) (EApp (EApp (EApp (EVar "tableCountGo") (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString "."))))) (EVar "kvs")) (ELit (LInt 0))))
(DTypeSig false "tableEntryGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))))))))))
(DFunDef false "tableEntryGo" (PWild PWild (PList) (PVar "best") (PVar "acc")) (ETuple (EVar "best") (EVar "acc")))
(DFunDef false "tableEntryGo" ((PVar "prefix") (PVar "entryPrefix") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "best") (PVar "acc")) (EBlock (DoLet false false (PVar "best2") (EMatch (EApp (EApp (EVar "tableIdxOf") (EVar "prefix")) (EVar "k")) (arm (PCon "None") () (EVar "best")) (arm (PCon "Some" (PVar "j")) () (EApp (EApp (EMethodRef "max") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "best"))))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "entryPrefix")) (EVar "k")) (EApp (EApp (EApp (EApp (EApp (EVar "tableEntryGo") (EVar "prefix")) (EVar "entryPrefix")) (EVar "rest")) (EVar "best2")) (EBinOp "::" (ETuple (EApp (EApp (EVar "drop") (EApp (EVar "stringLength") (EVar "entryPrefix"))) (EVar "k")) (EVar "v")) (EVar "acc"))) (EApp (EApp (EApp (EApp (EApp (EVar "tableEntryGo") (EVar "prefix")) (EVar "entryPrefix")) (EVar "rest")) (EVar "best2")) (EVar "acc"))))))
(DTypeSig true "tableEntry" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "Toml"))))))
(DFunDef false "tableEntry" ((PVar "name") (PVar "i") (PCon "Toml" (PVar "kvs"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "entryPrefix") (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString ".")) (EApp (EVar "intToString") (EVar "i")) (ELit (LString "."))))) (DoLet false false (PTuple (PVar "count") (PVar "entry")) (EApp (EApp (EApp (EApp (EApp (EVar "tableEntryGo") (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString "."))))) (EVar "entryPrefix")) (EVar "kvs")) (ELit (LInt 0))) (EListLit))) (DoExpr (EIf (EBinOp ">=" (EVar "i") (EDictApp "count")) (EVar "None") (EApp (EVar "Some") (EApp (EVar "Toml") (EApp (EVar "reverse") (EVar "entry"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "entryKeyOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "String"))))))
(DFunDef false "entryKeyOf" ((PVar "prefix") (PVar "k")) (EMatch (EApp (EApp (EVar "tableIdxOf") (EVar "prefix")) (EVar "k")) (arm (PCon "Some" (PVar "i")) ((GBool (EBinOp ">=" (EVar "i") (ELit (LInt 0))))) (EBlock (DoLet false false (PVar "entryPrefix") (EApp (EVar "stringConcat") (EListLit (EVar "prefix") (EApp (EVar "intToString") (EVar "i")) (ELit (LString "."))))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "entryPrefix")) (EVar "k")) (EApp (EVar "Some") (ETuple (EVar "i") (EApp (EApp (EVar "drop") (EApp (EVar "stringLength") (EVar "entryPrefix"))) (EVar "k")))) (EVar "None"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "groupEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "groupEntries" (PWild (PList)) (EVar "Tip"))
(DFunDef false "groupEntries" ((PVar "prefix") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false (PVar "groups") (EApp (EApp (EVar "groupEntries") (EVar "prefix")) (EVar "rest"))) (DoExpr (EMatch (EApp (EApp (EVar "entryKeyOf") (EVar "prefix")) (EVar "k")) (arm (PCon "None") () (EVar "groups")) (arm (PCon "Some" (PTuple (PVar "i") (PVar "key"))) () (EApp (EApp (EApp (EApp (EVar "insertWith") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "++" (EVar "_a") (EVar "_b")))) (EVar "i")) (EListLit (ETuple (EVar "key") (EVar "v")))) (EVar "groups")))))))
(DTypeSig false "tableEntryLimit" (TyCon "Int"))
(DFunDef false "tableEntryLimit" () (ELit (LInt 100000)))
(DTypeSig true "tableEntries" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Toml"))))))
(DFunDef false "tableEntries" ((PVar "name") (PCon "Toml" (PVar "kvs"))) (EBlock (DoLet false false (PVar "prefix") (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString "."))))) (DoLet false false (PVar "count") (EApp (EApp (EApp (EVar "tableCountGo") (EVar "prefix")) (EVar "kvs")) (ELit (LInt 0)))) (DoLet false false (PVar "groups") (EApp (EApp (EVar "groupEntries") (EVar "prefix")) (EVar "kvs"))) (DoExpr (EMatch (EBinOp ">" (EDictApp "count") (EVar "tableEntryLimit")) (arm (PCon "True") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "too many [[")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "]] entries: index "))) (EApp (EMethodRef "display") (EBinOp "-" (EDictApp "count") (ELit (LInt 1))))) (ELit (LString " is past the limit of "))) (EApp (EMethodRef "display") (EVar "tableEntryLimit"))) (ELit (LString ""))))) (arm (PCon "False") () (EApp (EVar "Ok") (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EVar "Toml") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "get") (EVar "i")) (EVar "groups")))))) (ERangeList (ELit (LInt 0)) (EDictApp "count") false))))))))
(DTypeSig false "eqTomlValue" (TyFun (TyCon "TomlValue") (TyFun (TyCon "TomlValue") (TyCon "Bool"))))
(DFunDef false "eqTomlValue" ((PCon "TString" (PVar "a")) (PCon "TString" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "eqTomlValue" ((PCon "TArray" (PVar "a")) (PCon "TArray" (PVar "b"))) (EApp (EApp (EVar "eqStrLists") (EVar "a")) (EVar "b")))
(DFunDef false "eqTomlValue" ((PCon "TInt" (PVar "a")) (PCon "TInt" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "eqTomlValue" ((PCon "TBool" (PVar "a")) (PCon "TBool" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "eqTomlValue" (PWild PWild) (EVar "False"))
(DTypeSig false "eqStrLists" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "eqStrLists" ((PList) (PList)) (EVar "True"))
(DFunDef false "eqStrLists" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "&&" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "eqStrLists") (EVar "xs")) (EVar "ys"))))
(DFunDef false "eqStrLists" (PWild PWild) (EVar "False"))
(DTypeSig false "eqKvList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyCon "Bool"))))
(DFunDef false "eqKvList" ((PList) (PList)) (EVar "True"))
(DFunDef false "eqKvList" ((PCons (PTuple (PVar "k1") (PVar "v1")) (PVar "rest1")) (PCons (PTuple (PVar "k2") (PVar "v2")) (PVar "rest2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "k1") (EVar "k2")) (EApp (EApp (EVar "eqTomlValue") (EVar "v1")) (EVar "v2"))) (EApp (EApp (EVar "eqKvList") (EVar "rest1")) (EVar "rest2"))))
(DFunDef false "eqKvList" (PWild PWild) (EVar "False"))
(DImpl true "Eq" ((TyCon "TomlValue")) () ((im "eq" () (EVar "eqTomlValue"))))
(DImpl true "Eq" ((TyCon "Toml")) () ((im "eq" ((PCon "Toml" (PVar "a")) (PCon "Toml" (PVar "b"))) (EApp (EApp (EVar "eqKvList") (EVar "a")) (EVar "b")))))
(DTypeSig false "debugTomlValue" (TyFun (TyCon "TomlValue") (TyCon "String")))
(DFunDef false "debugTomlValue" ((PCon "TString" (PVar "s"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TString ")) (EApp (EMethodRef "debug") (EVar "s")))))
(DFunDef false "debugTomlValue" ((PCon "TArray" (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TArray ")) (EApp (EVar "debugStrList") (EVar "xs")))))
(DFunDef false "debugTomlValue" ((PCon "TInt" (PVar "n"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TInt ")) (EApp (EVar "intToString") (EVar "n")))))
(DFunDef false "debugTomlValue" ((PCon "TBool" (PVar "b"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TBool ")) (EIf (EVar "b") (ELit (LString "True")) (ELit (LString "False"))))))
(DTypeSig false "debugStrList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "debugStrList" ((PVar "xs")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[")) (EApp (EVar "joinDebugStrs") (EVar "xs")) (ELit (LString "]")))))
(DTypeSig false "joinDebugStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinDebugStrs" ((PList)) (ELit (LString "")))
(DFunDef false "joinDebugStrs" ((PCons (PVar "x") (PList))) (EApp (EMethodRef "debug") (EVar "x")))
(DFunDef false "joinDebugStrs" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (EApp (EMethodRef "debug") (EVar "x")) (ELit (LString ", ")) (EApp (EVar "joinDebugStrs") (EVar "xs")))))
(DTypeSig false "debugKvPair" (TyFun (TyTuple (TyCon "String") (TyCon "TomlValue")) (TyCon "String")))
(DFunDef false "debugKvPair" ((PTuple (PVar "k") (PVar "v"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "(")) (EApp (EMethodRef "debug") (EVar "k")) (ELit (LString ", ")) (EApp (EVar "debugTomlValue") (EVar "v")) (ELit (LString ")")))))
(DTypeSig false "debugKvList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyCon "String")))
(DFunDef false "debugKvList" ((PList)) (ELit (LString "")))
(DFunDef false "debugKvList" ((PCons (PVar "p") (PList))) (EApp (EVar "debugKvPair") (EVar "p")))
(DFunDef false "debugKvList" ((PCons (PVar "p") (PVar "ps"))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "debugKvPair") (EVar "p")) (ELit (LString ", ")) (EApp (EVar "debugKvList") (EVar "ps")))))
(DImpl true "Debug" ((TyCon "TomlValue")) () ((im "debug" () (EVar "debugTomlValue"))))
(DImpl true "Debug" ((TyCon "Toml")) () ((im "debug" ((PCon "Toml" (PVar "kvs"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Toml [")) (EApp (EVar "debugKvList") (EVar "kvs")) (ELit (LString "]")))))))
(DTypeSig false "displayTomlValue" (TyFun (TyCon "TomlValue") (TyCon "String")))
(DFunDef false "displayTomlValue" ((PCon "TString" (PVar "s"))) (EApp (EMethodRef "debug") (EVar "s")))
(DFunDef false "displayTomlValue" ((PCon "TArray" (PVar "xs"))) (EApp (EVar "debugStrList") (EVar "xs")))
(DFunDef false "displayTomlValue" ((PCon "TInt" (PVar "n"))) (EApp (EVar "intToString") (EVar "n")))
(DFunDef false "displayTomlValue" ((PCon "TBool" (PVar "b"))) (EIf (EVar "b") (ELit (LString "true")) (ELit (LString "false"))))
(DTypeSig false "displayKvPair" (TyFun (TyTuple (TyCon "String") (TyCon "TomlValue")) (TyCon "String")))
(DFunDef false "displayKvPair" ((PTuple (PVar "k") (PVar "v"))) (EApp (EVar "stringConcat") (EListLit (EVar "k") (ELit (LString " = ")) (EApp (EVar "displayTomlValue") (EVar "v")))))
(DTypeSig false "displayKvList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyCon "String")))
(DFunDef false "displayKvList" ((PList)) (ELit (LString "")))
(DFunDef false "displayKvList" ((PCons (PVar "p") (PList))) (EApp (EVar "displayKvPair") (EVar "p")))
(DFunDef false "displayKvList" ((PCons (PVar "p") (PVar "ps"))) (EApp (EVar "stringConcat") (EListLit (EApp (EVar "displayKvPair") (EVar "p")) (ELit (LString ", ")) (EApp (EVar "displayKvList") (EVar "ps")))))
(DImpl true "Display" ((TyCon "TomlValue")) () ((im "display" () (EVar "displayTomlValue"))))
(DImpl true "Display" ((TyCon "Toml")) () ((im "display" ((PCon "Toml" (PList))) (ELit (LString "Toml {}"))) (im "display" ((PCon "Toml" (PVar "kvs"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "Toml { ")) (EApp (EVar "displayKvList") (EVar "kvs")) (ELit (LString " }")))))))
(DTypeSig false "mkPackage" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "mkPackage" ((PVar "v")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[package]\nname = \"demo\"\nversion = \"")) (EVar "v") (ELit (LString "\"")))))
(DProp false "a section key round-trips an Int-derived value" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "parseGetStr") (ELit (LString "package.version"))) (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "Some") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "a sibling key is stable regardless of the varying value" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "parseGetStr") (ELit (LString "package.name"))) (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "Some") (ELit (LString "demo")))))
(DProp false "parse is deterministic" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parse") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parse") (EApp (EVar "mkPackage") (EApp (EVar "intToString") (EVar "n"))))))
(DTypeSig false "mkInt" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "mkInt" ((PVar "n")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[limits]\nretries = ")) (EApp (EVar "intToString") (EVar "n")))))
(DProp false "an unquoted integer round-trips as TInt" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "parseGetInt") (ELit (LString "limits.retries"))) (EApp (EVar "mkInt") (EVar "n"))) (EApp (EVar "Some") (EVar "n"))))
(DTypeSig false "mkGates" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "mkGates" ((PVar "k")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "[[gate]]\nname = \"g")) (EApp (EVar "intToString") (EVar "k")) (ELit (LString "\"\n[[gate]]\nname = \"h")) (EApp (EVar "intToString") (EVar "k")) (ELit (LString "\"\n")))))
(DProp false "array-of-tables entries stay separate" ((pp "k" (TyCon "Int"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "parseTableCount") (ELit (LString "gate"))) (EApp (EVar "mkGates") (EVar "k"))) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EApp (EVar "parseTableEntryStr") (ELit (LString "gate"))) (ELit (LInt 0))) (ELit (LString "name"))) (EApp (EVar "mkGates") (EVar "k"))) (EApp (EVar "Some") (EBinOp "++" (ELit (LString "g")) (EApp (EVar "intToString") (EVar "k")))))) (EBinOp "==" (EApp (EApp (EApp (EApp (EVar "parseTableEntryStr") (ELit (LString "gate"))) (ELit (LInt 1))) (ELit (LString "name"))) (EApp (EVar "mkGates") (EVar "k"))) (EApp (EVar "Some") (EBinOp "++" (ELit (LString "h")) (EApp (EVar "intToString") (EVar "k")))))))
(DProp false "Display TomlValue separates the four variants" ((pp "n" (TyCon "Int")) (pp "b" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "intToString") (EVar "n"))) (DoLet false false (PVar "vs") (EListLit (EApp (EVar "TString") (EVar "s")) (EApp (EVar "TArray") (EListLit (EVar "s"))) (EApp (EVar "TInt") (EVar "n")) (EApp (EVar "TBool") (EVar "b")))) (DoExpr (EApp (EVar "allDistinct") (EApp (EApp (EMethodRef "map") (EMethodRef "display")) (EVar "vs"))))))
(DTypeSig false "allDistinct" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "allDistinct" ((PList)) (EVar "True"))
(DFunDef false "allDistinct" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EDictApp "all") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "x") (EVar "_s")))) (EVar "rest")) (EApp (EVar "allDistinct") (EVar "rest"))))
(DProp false "Display Toml agrees with Eq Toml" ((pp "k" (TyCon "String")) (pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n")))))) (DoLet false false (PVar "b") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n")))))) (DoLet false false (PVar "c") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EBinOp "+" (EVar "n") (ELit (LInt 1)))))))) (DoLet false false (PVar "d") (EApp (EVar "Toml") (EListLit (ETuple (EBinOp "++" (EVar "k") (ELit (LString "x"))) (EApp (EVar "TInt") (EVar "n")))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EMethodRef "display") (EVar "a")) (EApp (EMethodRef "display") (EVar "b"))) (EApp (EApp (EMethodRef "eq") (EVar "a")) (EVar "b"))) (EBinOp "/=" (EApp (EMethodRef "display") (EVar "a")) (EApp (EMethodRef "display") (EVar "c")))) (EBinOp "/=" (EApp (EMethodRef "display") (EVar "a")) (EApp (EMethodRef "display") (EVar "d")))))))
(DProp false "Display Toml renders every entry" ((pp "k" (TyCon "String")) (pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "one") (EApp (EMethodRef "display") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n"))))))) (DoLet false false (PVar "two") (EApp (EMethodRef "display") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n"))) (ETuple (EBinOp "++" (EVar "k") (ELit (LString "2"))) (EApp (EVar "TInt") (EVar "n"))))))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "two")) (EApp (EVar "stringLength") (EVar "one"))) (EApp (EApp (EVar "contains") (EApp (EVar "displayTomlValue") (EApp (EVar "TInt") (EVar "n")))) (EVar "two"))))))
(DTypeSig false "asciiTrim" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "asciiTrim" ((PVar "s")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "chars"))) (DoLet false false (PVar "lo") (EApp (EApp (EApp (EVar "asciiTrimFront") (EVar "chars")) (ELit (LInt 0))) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EBinOp "+" (EApp (EApp (EApp (EVar "asciiTrimBack") (EVar "chars")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "lo")) (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig false "asciiTrimFront" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "asciiTrimFront" ((PVar "chars") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EApp (EVar "charIsSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars"))) (EApp (EApp (EApp (EVar "asciiTrimFront") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "asciiTrimBack" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "asciiTrimBack" ((PVar "chars") (PVar "i") (PVar "lo")) (EIf (EBinOp "<" (EVar "i") (EVar "lo")) (EBinOp "-" (EVar "lo") (ELit (LInt 1))) (EIf (EApp (EVar "charIsSpace") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars"))) (EApp (EApp (EApp (EVar "asciiTrimBack") (EVar "chars")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "lo")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
