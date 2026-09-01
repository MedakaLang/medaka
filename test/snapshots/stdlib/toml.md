# META
source_lines=806
stages=DESUGAR,MARK
# SOURCE
{- toml.mdk — a minimal TOML subset sufficient to parse `medaka.toml` and
   `test/gates.toml` (the gate registry, #2176).

   **Supported subset:**
   - Top-level `[section]` headers (not nested tables or inline tables)
   - Array-of-tables headers `[[section]]` (repeated; each occurrence opens a
     new indexed entry — see *Value model* below)
   - `key = "string"` values (double-quoted; backslash is passed through as-is)
   - `key = ["array", "of", "strings"]` values
   - `key = 42` / `key = -7` integer values
   - `key = true` / `key = false` boolean values
   - `#` line comments (stripped before parsing, respecting quoted strings)
   - Blank lines ignored

   **Not supported** — and rejected LOUDLY with an `Err`, never silently
   dropped:
   - Float and datetime values
   - Multiline strings (`"""…"""` / `'''…'''`)
   - Inline tables (`{k = v}`)
   - Dotted keys (`a.b = v`) — use table headers instead
   - String escape sequences (backslash is literal)

   **Value model.**
   ```
   data TomlValue = TStr String | TArr (List String) | TInt Int | TBool Bool
   ```
   The parsed document is a flat association list of `(qualifiedKey, value)`
   pairs.  EVERY key is qualified by its section: a key `k` under `[s]` is
   stored as `"s.k"` (so `[package] name` is `"package.name"`, and
   `[workspace] members` is `"workspace.members"`).  Keys before any header
   stay bare.

   A key `k` under the *i*-th (0-based) `[[t]]` header is stored as
   `"t.<i>.k"`.  `tableCount` and `tableEntry` are the accessors for that
   shape; `tableEntry` hands back `Some` sub-document whose keys are bare (so
   the ordinary accessors work on it unchanged), or `None` for an index that
   is out of range.

   This module is the GENERAL TOML reader: it knows nothing about
   `medaka.toml`'s schema.  The `[package]`/`[workspace]` accessors that used
   to live here are the compiler's business and now live in
   `compiler/support/manifest.mdk` (I-1). -}

import string.{trim, lines, toInt, startsWith, drop, indexOf, contains}
import core.{Display}

-- ── Value type ──────────────────────────────────────────────────────────────

public export data TomlValue =
  | TStr String
  | TArr (List String)
  | TInt Int
  | TBool Bool

-- | A parsed TOML document: a flat list of (qualifiedKey, value) pairs.
public export data Toml = Toml (List (String, TomlValue))

-- ── Helpers ──────────────────────────────────────────────────────────────────

listReverse : List a -> List a
listReverse = listRevGo []

listRevGo : List a -> List a -> List a
listRevGo acc [] = acc
listRevGo acc (x::xs) = listRevGo (x::acc) xs

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
  | i >= n = stringFromChars (arrayFromList (listReverse acc))
  | otherwise = stripCommentStep arr i n inStr acc (arrayGetUnsafe i arr)

stripCommentStep : Array Char -> Int -> Int -> Bool -> List Char -> Char -> String
stripCommentStep arr i n inStr acc c
  | charCode c == 34 = stripCommentGo arr (i + 1) n (not inStr) (c::acc)
  | charCode c == 35 && not inStr =
    stringFromChars (arrayFromList (listReverse acc))
  | otherwise = stripCommentGo arr (i + 1) n inStr (c::acc)

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
    Ok (stringFromChars (arrayFromList (listReverse acc)), i + 1)
  | otherwise = parseQuotedBody arr (i + 1) (arrayGetUnsafe i arr :: acc)

-- ── Array value parser ───────────────────────────────────────────────────────

-- Parse a `["str1", "str2"]` array starting at position `i` (must point at `[`).
parseArrayValue : Array Char -> Int -> Result String (List String, Int)
parseArrayValue arr i
  | i >= arrayLength arr = Err "unexpected end of input"
  | arrayGetUnsafe i arr == '[' = parseArrayItems arr (i + 1) []
  | otherwise = Err "expected '['"

-- Skip spaces and parse a string item, or close on `]`.  Called at the start
-- of the array and again after each comma — i.e. wherever an item (or the
-- close) is expected next.
parseArrayItems : Array Char -> Int -> List String -> Result String (List String, Int)
parseArrayItems arr i acc
  | i >= arrayLength arr = Err "unterminated array"
  | arrayGetUnsafe i arr == ']' = Ok (listReverse acc, i + 1)
  | arrayGetUnsafe i arr == ' ' = parseArrayItems arr (i + 1) acc
  | arrayGetUnsafe i arr == '\t' = parseArrayItems arr (i + 1) acc
  | arrayGetUnsafe i arr == '"' = parseArrayItemStr arr i acc
  | otherwise = Err (stringConcat ["unexpected char in array: '", charToStr (arrayGetUnsafe i arr), "'"])

parseArrayItemStr : Array Char -> Int -> List String -> Result String (List String, Int)
parseArrayItemStr arr i acc = match parseQuotedStr arr i
  Err e => Err e
  Ok (s, j) => parseArraySep arr j (s::acc)

-- After a parsed item: only a `,` (another item may follow, a trailing comma
-- before `]` is fine) or `]` (close) is valid next.  Anything else — most
-- commonly another quoted item with no comma between, `["x" "y"]` — is a
-- malformed array and must be rejected loudly rather than silently accepted
-- as two adjacent items.
parseArraySep : Array Char -> Int -> List String -> Result String (List String, Int)
parseArraySep arr i acc
  | i >= arrayLength arr = Err "unterminated array"
  | arrayGetUnsafe i arr == ' ' = parseArraySep arr (i + 1) acc
  | arrayGetUnsafe i arr == '\t' = parseArraySep arr (i + 1) acc
  | arrayGetUnsafe i arr == ',' = parseArrayItems arr (i + 1) acc
  | arrayGetUnsafe i arr == ']' = Ok (listReverse acc, i + 1)
  | otherwise = Err (stringConcat [
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
  let key = trim keyRaw
  -- Dotted keys (`foo.bar = "zzz"`) are unsupported — the module's header says
  -- so explicitly ("use table headers instead"); reject loudly rather than
  -- silently accepting a dot as an ordinary key character.
  if contains "." key then
    Err (stringConcat ["dotted key '", key, "' is not supported: use table headers instead"])
  else
    let valStart = skipSpaces arr (eq + 1) n
    parseKvValue arr n valStart key

parseKvValue : Array Char -> Int -> Int -> String -> Result String (String, TomlValue)
parseKvValue arr n i key
  | i >= n = Err (stringConcat ["missing value for key: ", key])
  | arrayGetUnsafe i arr == '"' = parseKvStr arr i key
  | arrayGetUnsafe i arr == '[' = parseKvArr arr i key
  | otherwise = parseKvScalar (restOfLine arr n i) key

-- After a value parser hands back `nextIndex`, the rest of the line must be
-- empty (once trimmed) — comments are already stripped upstream
-- (`stripComment`, called in `parseLinesAcc` before `parseKv` ever runs).
-- Anything left over is trailing garbage: `name = "abc" this is garbage`, a
-- missing comma between array items (`["x" "y"]`), or — the same root cause —
-- a triple-quoted string, whose second `"` of the opening `"""` reads as the
-- closing quote and leaves `"x"""` unconsumed.
checkLineConsumed : Array Char -> Int -> String -> Result String Unit
checkLineConsumed arr j key =
  let trailing = restOfLine arr (arrayLength arr) j
  if trailing == "" then
    Ok ()
  else
    Err (stringConcat ["trailing content after value for key '", key, "': ", trailing])

parseKvStr : Array Char -> Int -> String -> Result String (String, TomlValue)
parseKvStr arr i key = match parseQuotedStr arr i
  Err e => Err e
  Ok (s, j) => map (_ => (key, TStr s)) (checkLineConsumed arr j key)

parseKvArr : Array Char -> Int -> String -> Result String (String, TomlValue)
parseKvArr arr i key = match parseArrayValue arr i
  Err e => Err e
  Ok (xs, j) => map (_ => (key, TArr xs)) (checkLineConsumed arr j key)

-- The remaining characters of the line from `i`, trimmed.  Used for the
-- unquoted scalar forms (integer / boolean), which run to end-of-line.
restOfLine : Array Char -> Int -> Int -> String
restOfLine arr n i = trim (stringFromChars (arrayMakeWith
  (n - i)
  (j => arrayGetUnsafe (i + j) arr)))

-- Unquoted scalar: `true`/`false`, or an integer.  ANYTHING else — an inline
-- table `{k = v}`, a float, a datetime, a bare word — is an ERROR, never a
-- silent drop: the whole point of this reader is that an unmodelled construct
-- is loud.
parseKvScalar : String -> String -> Result String (String, TomlValue)
parseKvScalar tok key
  | tok == "true" = Ok (key, TBool True)
  | tok == "false" = Ok (key, TBool False)
  | otherwise = match toInt tok
    Some n => Ok (key, TInt n)
    None => Err (stringConcat [
      "unsupported value for key '",
      key,
      "': ",
      tok,
      " (expected a quoted string, a string array, an integer, or true/false)",
    ])

-- ── Document parser ──────────────────────────────────────────────────────────

-- A header line: `[name]` opens a plain table, `[[name]]` opens the next
-- element of an array of tables.
data Header = HTable String | HArrayTable String

-- Detect a section header and classify it, or return None.
-- `[[t]]` is checked first: it also satisfies the `[t]` shape.
parseHeader : String -> Option Header
parseHeader s =
  let n = stringLength s
  if n >= 4 && stringSlice 0 2 s == "[[" && stringSlice (n - 2) n s == "]]" then
    Some (HArrayTable (trim (stringSlice 2 (n - 2) s)))
  else if n >= 2 && stringSlice 0 1 s == "[" && stringSlice (n - 1) n s == "]" then
    Some (HTable (trim (stringSlice 1 (n - 1) s)))
  else
    None

-- Qualify a key relative to the current section.  Every section qualifies —
-- `[package]` is not special (it used to be, mirroring the removed
-- `lib/project_config.ml`; that asymmetry made `package` the one table whose
-- keys could collide with a pre-header bare key).
qualifyKey : String -> String -> String
qualifyKey section key
  | section == "" = key
  | otherwise = stringConcat [section, ".", key]

-- How many `[[name]]` elements have been opened so far, per table name.
seenCount : String -> List (String, Int) -> Int
seenCount _ [] = 0
seenCount name ((k, c)::rest)
  | k == name = c
  | otherwise = seenCount name rest

bumpCount : String -> List (String, Int) -> List (String, Int)
bumpCount name [] = [(name, 1)]
bumpCount name ((k, c)::rest)
  | k == name = (k, c + 1)::rest
  | otherwise = (k, c) :: bumpCount name rest

parseLinesAcc : List String -> String -> List (String, Int) -> List (String, TomlValue) -> Result String (List (String, TomlValue))
parseLinesAcc [] _ _ acc = Ok (listReverse acc)
parseLinesAcc (l::ls) section counts acc =
  let trimmed = trim (stripComment l)
  if trimmed == "" then parseLinesAcc ls section counts acc
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
        parseLinesAcc ls section counts ((qualifyKey section k, v)::acc)

{- | Parse a TOML string (supported subset) into a `Toml` document, or an
   error message describing the first parse failure.

   A `[package]` section — note every key is qualified by its section:

   > parse "[package]\nname = \"hello\"\nversion = \"0.1.0\"" == Ok (Toml [("package.name", TStr "hello"), ("package.version", TStr "0.1.0")])
   True

   A `[workspace]` section with a string array:

   > parse "[workspace]\nmembers = [\"pkg-a\", \"pkg-b\"]" == Ok (Toml [("workspace.members", TArr ["pkg-a", "pkg-b"])])
   True

   Integer and boolean values:

   > parse "[limits]\nretries = 3\nverbose = true\noffset = -7" == Ok (Toml [("limits.retries", TInt 3), ("limits.verbose", TBool True), ("limits.offset", TInt (0 - 7))])
   True

   Repeated `[[gate]]` headers open successive indexed entries:

   > parse "[[gate]]\nname = \"a\"\n[[gate]]\nname = \"b\"" == Ok (Toml [("gate.0.name", TStr "a"), ("gate.1.name", TStr "b")])
   True

   Comments and blank lines are ignored:

   > parse "# just a comment\n\nname = \"x\"" == Ok (Toml [("name", TStr "x")])
   True

   Inline `#` after a value is stripped:

   > parse "name = \"hello\" # a comment" == Ok (Toml [("name", TStr "hello")])
   True -}
export
parse : String -> Result String Toml
parse s = map Toml (parseLinesAcc (lines s) "" [] [])

-- Parse-error cases.  An unmodelled construct is an `Err`, NOT a silent drop:
-- a line with no `=`, a bare unquoted word, and an inline table each fail.

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
   Ok Toml [("name", TStr "abc")]

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
   Ok Toml [("oracles", TArr ["x", "y"])]

   A triple-quoted (multiline) string is rejected loudly rather than
   mis-parsing to a wrong value — the header lists multiline strings as
   unsupported, and this is the same "line fully consumed" check as the two
   trailing-garbage cases above:

   > parse "name = \"\"\"x\"\"\""
   Err "trailing content after value for key 'name': \"x\"\"\""

   A dotted key is rejected loudly — the header says to use table headers
   instead:

   > parse "foo.bar = \"zzz\""
   Err "dotted key 'foo.bar' is not supported: use table headers instead"

   A well-formed key under a table header still parses correctly (no
   regression):

   > parse "[foo]\nbar = \"zzz\""
   Ok Toml [("foo.bar", TStr "zzz")] -}

-- ── Accessors ────────────────────────────────────────────────────────────────

lookupKvs : String -> List (String, TomlValue) -> Option TomlValue
lookupKvs _ [] = None
lookupKvs key ((k, v)::rest)
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

{- | Look up a string value by (qualified) key.  Returns `None` if the key is
   absent or holds an array.

   > parseGetStr "package.name" "[package]\nname = \"medaka\"\nversion = \"1.0.0\"\nentry = \"main.mdk\""
   Some "medaka"

   Returns `None` for an array-valued key:

   > parseGetStr "workspace.members" "[workspace]\nmembers = [\"a\"]"
   None

   Returns `None` for an absent key:

   > parseGetStr "missing" "[package]\nname = \"x\""
   None

   Returns `None` when the table itself is absent:

   > parseGetStr "server.host" "[package]\nname = \"x\""
   None -}
export
getString : String -> Toml -> Option String
getString key (Toml kvs) = match lookupKvs key kvs
  Some (TStr s) => Some s
  _ => None

{- | Look up an array-of-strings value by (qualified) key.  Returns `None` if
   the key is absent or holds a string.

   > parseGetArr "workspace.members" "[workspace]\nmembers = [\"pkg-a\", \"pkg-b\"]"
   Some ["pkg-a", "pkg-b"]

   Returns `None` for a string-valued key:

   > parseGetArr "package.name" "[package]\nname = \"x\"\nversion = \"0.1.0\"\nentry = \"main.mdk\""
   None

   Returns `None` for an absent key:

   > parseGetArr "workspace.members" "[package]\nname = \"x\""
   None

   An empty array yields `Some []`:

   > parseGetArr "workspace.members" "[workspace]\nmembers = []"
   Some [] -}
export
getArray : String -> Toml -> Option (List String)
getArray key (Toml kvs) = match lookupKvs key kvs
  Some (TArr xs) => Some xs
  _ => None

{- | Look up an integer value by (qualified) key.  `None` if the key is absent
   or holds another type.

   > parseGetInt "limits.retries" "[limits]\nretries = 3"
   Some 3

   Negative integers parse:

   > parseGetInt "limits.offset" "[limits]\noffset = -7" == Some (0 - 7)
   True

   `None` for a string-valued key:

   > parseGetInt "package.name" "[package]\nname = \"x\""
   None -}
export
getInt : String -> Toml -> Option Int
getInt key (Toml kvs) = match lookupKvs key kvs
  Some (TInt n) => Some n
  _ => None

{- | Look up a boolean value by (qualified) key.  `None` if the key is absent
   or holds another type.

   > parseGetBool "limits.verbose" "[limits]\nverbose = true"
   Some True

   > parseGetBool "limits.verbose" "[limits]\nverbose = false"
   Some False

   `None` for an integer-valued key:

   > parseGetBool "limits.retries" "[limits]\nretries = 3"
   None -}
export
getBool : String -> Toml -> Option Bool
getBool key (Toml kvs) = match lookupKvs key kvs
  Some (TBool b) => Some b
  _ => None

-- ── Array-of-tables accessors ───────────────────────────────────────────────

-- The 0-based index in a key of the shape `<name>.<idx>.<field>`, or None.
tableIdxOf : String -> String -> Option Int
tableIdxOf prefix key =
  if not (startsWith prefix key) then None
  else
    let rest = drop (stringLength prefix) key
    match indexOf "." rest
      None => None
      Some d => toInt (stringSlice 0 d rest)

tableCountGo : String -> List (String, TomlValue) -> Int -> Int
tableCountGo _ [] best = best
tableCountGo prefix ((k, _)::rest) best = match tableIdxOf prefix k
  None => tableCountGo prefix rest best
  Some i => tableCountGo prefix rest (max (i + 1) best)

{- | How many `[[name]]` entries the document contains.

   > parseTableCount "gate" "[[gate]]\nname = \"a\"\n[[gate]]\nname = \"b\""
   2

   Zero when the table is absent:

   > parseTableCount "gate" "[package]\nname = \"x\""
   0 -}
export
tableCount : String -> Toml -> Int
tableCount name (Toml kvs) = tableCountGo (stringConcat [name, "."]) kvs 0

stripTablePrefix : String -> List (String, TomlValue) -> List (String, TomlValue)
stripTablePrefix _ [] = []
stripTablePrefix prefix ((k, v)::rest)
  | startsWith prefix k =
    (drop (stringLength prefix) k, v) :: stripTablePrefix prefix rest
  | otherwise = stripTablePrefix prefix rest

{- | The `i`-th (0-based) `[[name]]` entry, as a sub-document whose keys are
   bare — so `getString`/`getArray`/`getInt`/`getBool` apply unchanged.
   `None` when `i` is out of range.

   `Option`, not a bare `Toml`, for the same reason `path.stripPrefix` is
   (#2310's defect class): an out-of-range index used to come back as a
   document in which every lookup happens to be `None`, so "no such entry" and
   "an entry with no keys" were the same value.

   > parseTableEntryStr "gate" 1 "name" "[[gate]]\nname = \"a\"\n[[gate]]\nname = \"b\""
   Some "b"

   An out-of-range index is `None`:

   > parseTableEntryStr "gate" 9 "name" "[[gate]]\nname = \"a\""
   None -}
export
tableEntry : String -> Int -> Toml -> Option Toml
tableEntry name i (Toml kvs) =
  if i < 0 || i >= tableCount name (Toml kvs) then
    None
  else
    Some (Toml (stripTablePrefix (stringConcat [name, ".", intToString i, "."]) kvs))

-- ── Eq and Debug instances ──────────────────────────────────────────────────

{- | Structural equality on `TomlValue`.

   > eqTomlValue (TStr "a") (TStr "a")
   True

   > eqTomlValue (TArr ["a", "b"]) (TArr ["a", "b"])
   True

   Different constructors never compare equal:

   > eqTomlValue (TStr "a") (TArr ["a"])
   False -}
eqTomlValue : TomlValue -> TomlValue -> Bool
eqTomlValue (TStr a) (TStr b) = a == b
eqTomlValue (TArr a) (TArr b) = eqStrLists a b
eqTomlValue (TInt a) (TInt b) = a == b
eqTomlValue (TBool a) (TBool b) = a == b
eqTomlValue _ _ = False

eqStrLists : List String -> List String -> Bool
eqStrLists [] [] = True
eqStrLists (x::xs) (y::ys) = x == y && eqStrLists xs ys
eqStrLists _ _ = False

eqKvList : List (String, TomlValue) -> List (String, TomlValue) -> Bool
eqKvList [] [] = True
eqKvList ((k1, v1)::rest1) ((k2, v2)::rest2) = k1 == k2
  && eqTomlValue v1 v2
  && eqKvList rest1 rest2
eqKvList _ _ = False

export impl Eq TomlValue where
  eq = eqTomlValue

export impl Eq Toml where
  eq (Toml a) (Toml b) = eqKvList a b

{- | Render a `TomlValue` for debugging.

   > debugTomlValue (TStr "hi")
   "TStr \"hi\""

   > debugTomlValue (TArr ["a", "b"])
   "TArr [\"a\", \"b\"]"

   > debugTomlValue (TInt 42)
   "TInt 42"

   > debugTomlValue (TBool True)
   "TBool True" -}
debugTomlValue : TomlValue -> String
debugTomlValue (TStr s) = stringConcat ["TStr ", debug s]
debugTomlValue (TArr xs) = stringConcat ["TArr ", debugStrList xs]
debugTomlValue (TInt n) = stringConcat ["TInt ", intToString n]
debugTomlValue (TBool b) =
  stringConcat ["TBool ", if b then "True" else "False"]

debugStrList : List String -> String
debugStrList xs = stringConcat ["[", joinDebugStrs xs, "]"]

joinDebugStrs : List String -> String
joinDebugStrs [] = ""
joinDebugStrs (x::[]) = debug x
joinDebugStrs (x::xs) = stringConcat [debug x, ", ", joinDebugStrs xs]

debugKvPair : (String, TomlValue) -> String
debugKvPair (k, v) = stringConcat ["(", debug k, ", ", debugTomlValue v, ")"]

debugKvList : List (String, TomlValue) -> String
debugKvList [] = ""
debugKvList (p::[]) = debugKvPair p
debugKvList (p::ps) = stringConcat [debugKvPair p, ", ", debugKvList ps]

export impl Debug TomlValue where
  debug = debugTomlValue

export impl Debug Toml where
  debug (Toml kvs) = stringConcat ["Toml [", debugKvList kvs, "]"]

{- ── Display (sheet row A-5) ──────────────────────────────────────────────

   ⚠️ This is NOT a TOML renderer.  Emitting a document `parse` could read
   back is row H-4, which is DEFERRED behind #2240 (the `toml`-onto-`parsec`
   consolidation); shipping one here under the `Display` name would be that
   deferred work wearing a disguise.  What `Display` owes is a stable,
   legible rendering of the VALUE, in the same `T { … }` shape `Display (Map
   k v)` and `Display (Set a)` use.

   Values keep TOML's own spelling for their SCALARS (a string is quoted, a
   bool is `true`/`false`) so that the four variants stay distinguishable --
   an unquoted `TStr "1"` would render exactly like `TInt 1`, and a `Display`
   that collapses two distinct values into one text is not a rendering of the
   value.  That injectivity is the law under test. -}

displayTomlValue : TomlValue -> String
displayTomlValue (TStr s) = debug s
displayTomlValue (TArr xs) = debugStrList xs
displayTomlValue (TInt n) = intToString n
displayTomlValue (TBool b) = if b then "true" else "false"

displayKvPair : (String, TomlValue) -> String
displayKvPair (k, v) = stringConcat [k, " = ", displayTomlValue v]

displayKvList : List (String, TomlValue) -> String
displayKvList [] = ""
displayKvList (p::[]) = displayKvPair p
displayKvList (p::ps) = stringConcat [displayKvPair p, ", ", displayKvList ps]

{- | A `TomlValue` in TOML's own scalar spelling.

   > display (TStr "hi")
   "\"hi\""
   > display (TInt 42)
   "42"
   > display (TBool True)
   "true"
   > display (TArr ["a", "b"])
   "[\"a\", \"b\"]" -}
export impl Display TomlValue where
  display = displayTomlValue

{- | A whole document as `Toml { key = value, … }` (empty -> `Toml {}`),
   mirroring `Display (Map k v)`'s `Map { … }`.

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
  parseGetStr "package.version" (mkPackage (intToString n)) ==
    Some (intToString n)

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
mkGates k = stringConcat
  [
    "[[gate]]\nname = \"g",
    intToString k,
    "\"\n[[gate]]\nname = \"h",
    intToString k,
    "\"\n",
  ]

prop "array-of-tables entries stay separate" (k : Int) = parseTableCount "gate" (mkGates k) == 2
  && parseTableEntryStr "gate" 0 "name" (mkGates k) == Some ("g" ++ intToString k)
  && parseTableEntryStr "gate" 1 "name" (mkGates k) == Some ("h" ++ intToString k)

-- ── Instance laws (sheet row A-5) ───────────────────────────────────────

-- LAW: `Display TomlValue` is INJECTIVE across the four variants -- a
-- rendering that cannot tell a quoted `TStr "1"` from an `TInt 1` is not a
-- rendering of the value.  This is the clause that pins the TOML scalar
-- spelling (quotes, lowercase bools) rather than the prelude's.
prop "Display TomlValue separates the four variants" (n : Int) (b : Bool) =
  let s = intToString n
  let vs = [TStr s, TArr [s], TInt n, TBool b]
  allDistinct (map display vs)

allDistinct : List String -> Bool
allDistinct [] = True
allDistinct (x::rest) = all (x /= _) rest && allDistinct rest

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
    && not (display a == display c)
    && not (display a == display d)

-- LAW: every key and every value reaches the output (nothing is silently
-- dropped as the entry list grows).
prop "Display Toml renders every entry" (k : String) (n : Int) =
  let one = display (Toml [(k, TInt n)])
  let two = display (Toml [(k, TInt n), (k ++ "2", TInt n)])
  stringLength two > stringLength one
    && contains (displayTomlValue (TInt n)) two
# DESUGAR
(DUse false (UseGroup ("string") ((mem "trim" false) (mem "lines" false) (mem "toInt" false) (mem "startsWith" false) (mem "drop" false) (mem "indexOf" false) (mem "contains" false))))
(DUse false (UseGroup ("core") ((mem "Display" false))))
(DData Public "TomlValue" () ((variant "TStr" (ConPos (TyCon "String"))) (variant "TArr" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "TInt" (ConPos (TyCon "Int"))) (variant "TBool" (ConPos (TyCon "Bool")))) ())
(DData Public "Toml" () ((variant "Toml" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))))) ())
(DTypeSig false "listReverse" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "listReverse" () (EApp (EVar "listRevGo") (EListLit)))
(DTypeSig false "listRevGo" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "listRevGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "listRevGo" ((PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "listRevGo") (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "xs")))
(DTypeSig false "stripComment" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripComment" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (ELit (LInt 0))) (EVar "n")) (EVar "False")) (EListLit)))))
(DTypeSig false "stripCommentGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "String")))))))
(DFunDef false "stripCommentGo" ((PVar "arr") (PVar "i") (PVar "n") (PVar "inStr") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "listReverse") (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentStep") (EVar "arr")) (EVar "i")) (EVar "n")) (EVar "inStr")) (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stripCommentStep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Char") (TyCon "String"))))))))
(DFunDef false "stripCommentStep" ((PVar "arr") (PVar "i") (PVar "n") (PVar "inStr") (PVar "acc") (PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "not") (EVar "inStr"))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 35))) (EApp (EVar "not") (EVar "inStr"))) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "listReverse") (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "inStr")) (EBinOp "::" (EVar "c") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseQuotedStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "parseQuotedStr" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseQuotedBody") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected '\"'"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseQuotedBody" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "parseQuotedBody" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated string"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EVar "Ok") (ETuple (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "listReverse") (EVar "acc")))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "parseQuotedBody") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseArrayValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "parseArrayValue" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected '['"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseArrayItems" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArrayItems" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated array"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "]"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "listReverse") (EVar "acc")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseArrayItemStr") (EVar "arr")) (EVar "i")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unexpected char in array: '")) (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "parseArrayItemStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArrayItemStr" ((PVar "arr") (PVar "i") (PVar "acc")) (EMatch (EApp (EApp (EVar "parseQuotedStr") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "s") (PVar "j"))) () (EApp (EApp (EApp (EVar "parseArraySep") (EVar "arr")) (EVar "j")) (EBinOp "::" (EVar "s") (EVar "acc"))))))
(DTypeSig false "parseArraySep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArraySep" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated array"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "parseArraySep") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "parseArraySep") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar ","))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "]"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "listReverse") (EVar "acc")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "expected ',' or ']' in array, found: '")) (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "skipSpaces" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipSpaces" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseKv" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))
(DFunDef false "parseKv" ((PVar "line")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "line"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "findEq") (EVar "arr")) (EVar "n")) (ELit (LInt 0))))))
(DTypeSig false "findEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "findEq" ((PVar "arr") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "expected '=' in: ")) (EApp (EVar "stringFromChars") (EVar "arr"))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "="))) (EApp (EApp (EApp (EVar "parseKvAfterEq") (EVar "arr")) (EVar "n")) (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "findEq") (EVar "arr")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseKvAfterEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvAfterEq" ((PVar "arr") (PVar "n") (PVar "eq")) (EBlock (DoLet false false (PVar "keyRaw") (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EVar "eq")) (ELam ((PVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr")))))) (DoLet false false (PVar "key") (EApp (EVar "trim") (EVar "keyRaw"))) (DoExpr (EIf (EApp (EApp (EVar "contains") (ELit (LString "."))) (EVar "key")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "dotted key '")) (EVar "key") (ELit (LString "' is not supported: use table headers instead"))))) (EBlock (DoLet false false (PVar "valStart") (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "eq") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseKvValue") (EVar "arr")) (EVar "n")) (EVar "valStart")) (EVar "key"))))))))
(DTypeSig false "parseKvValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue"))))))))
(DFunDef false "parseKvValue" ((PVar "arr") (PVar "n") (PVar "i") (PVar "key")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "missing value for key: ")) (EVar "key")))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseKvStr") (EVar "arr")) (EVar "i")) (EVar "key")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "parseKvArr") (EVar "arr")) (EVar "i")) (EVar "key")) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseKvScalar") (EApp (EApp (EApp (EVar "restOfLine") (EVar "arr")) (EVar "n")) (EVar "i"))) (EVar "key")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "checkLineConsumed" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "checkLineConsumed" ((PVar "arr") (PVar "j") (PVar "key")) (EBlock (DoLet false false (PVar "trailing") (EApp (EApp (EApp (EVar "restOfLine") (EVar "arr")) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "j"))) (DoExpr (EIf (EBinOp "==" (EVar "trailing") (ELit (LString ""))) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "trailing content after value for key '")) (EVar "key") (ELit (LString "': ")) (EVar "trailing"))))))))
(DTypeSig false "parseKvStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvStr" ((PVar "arr") (PVar "i") (PVar "key")) (EMatch (EApp (EApp (EVar "parseQuotedStr") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "s") (PVar "j"))) () (EApp (EApp (EVar "map") (ELam (PWild) (ETuple (EVar "key") (EApp (EVar "TStr") (EVar "s"))))) (EApp (EApp (EApp (EVar "checkLineConsumed") (EVar "arr")) (EVar "j")) (EVar "key"))))))
(DTypeSig false "parseKvArr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvArr" ((PVar "arr") (PVar "i") (PVar "key")) (EMatch (EApp (EApp (EVar "parseArrayValue") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "xs") (PVar "j"))) () (EApp (EApp (EVar "map") (ELam (PWild) (ETuple (EVar "key") (EApp (EVar "TArr") (EVar "xs"))))) (EApp (EApp (EApp (EVar "checkLineConsumed") (EVar "arr")) (EVar "j")) (EVar "key"))))))
(DTypeSig false "restOfLine" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "restOfLine" ((PVar "arr") (PVar "n") (PVar "i")) (EApp (EVar "trim") (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "n") (EVar "i"))) (ELam ((PVar "j")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "arr")))))))
(DTypeSig false "parseKvScalar" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue"))))))
(DFunDef false "parseKvScalar" ((PVar "tok") (PVar "key")) (EIf (EBinOp "==" (EVar "tok") (ELit (LString "true"))) (EApp (EVar "Ok") (ETuple (EVar "key") (EApp (EVar "TBool") (EVar "True")))) (EIf (EBinOp "==" (EVar "tok") (ELit (LString "false"))) (EApp (EVar "Ok") (ETuple (EVar "key") (EApp (EVar "TBool") (EVar "False")))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "toInt") (EVar "tok")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (ETuple (EVar "key") (EApp (EVar "TInt") (EVar "n"))))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unsupported value for key '")) (EVar "key") (ELit (LString "': ")) (EVar "tok") (ELit (LString " (expected a quoted string, a string array, an integer, or true/false)"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DData Private "Header" () ((variant "HTable" (ConPos (TyCon "String"))) (variant "HArrayTable" (ConPos (TyCon "String")))) ())
(DTypeSig false "parseHeader" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Header"))))
(DFunDef false "parseHeader" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "s")) (ELit (LString "[[")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "n")) (EVar "s")) (ELit (LString "]]")))) (EApp (EVar "Some") (EApp (EVar "HArrayTable") (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "s"))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "[")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "]")))) (EApp (EVar "Some") (EApp (EVar "HTable") (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s"))))) (EVar "None"))))))
(DTypeSig false "qualifyKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "qualifyKey" ((PVar "section") (PVar "key")) (EIf (EBinOp "==" (EVar "section") (ELit (LString ""))) (EVar "key") (EIf (EVar "otherwise") (EApp (EVar "stringConcat") (EListLit (EVar "section") (ELit (LString ".")) (EVar "key"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "seenCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Int"))))
(DFunDef false "seenCount" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "seenCount" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "name")) (EVar "c") (EIf (EVar "otherwise") (EApp (EApp (EVar "seenCount") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bumpCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "bumpCount" ((PVar "name") (PList)) (EListLit (ETuple (EVar "name") (ELit (LInt 1)))))
(DFunDef false "bumpCount" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "name")) (EBinOp "::" (ETuple (EVar "k") (EBinOp "+" (EVar "c") (ELit (LInt 1)))) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "c")) (EApp (EApp (EVar "bumpCount") (EVar "name")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseLinesAcc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))))))))
(DFunDef false "parseLinesAcc" ((PList) PWild PWild (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "listReverse") (EVar "acc"))))
(DFunDef false "parseLinesAcc" ((PCons (PVar "l") (PVar "ls")) (PVar "section") (PVar "counts") (PVar "acc")) (EBlock (DoLet false false (PVar "trimmed") (EApp (EVar "trim") (EApp (EVar "stripComment") (EVar "l")))) (DoExpr (EIf (EBinOp "==" (EVar "trimmed") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "section")) (EVar "counts")) (EVar "acc")) (EMatch (EApp (EVar "parseHeader") (EVar "trimmed")) (arm (PCon "Some" (PCon "HTable" (PVar "hdr"))) () (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "hdr")) (EVar "counts")) (EVar "acc"))) (arm (PCon "Some" (PCon "HArrayTable" (PVar "hdr"))) () (EBlock (DoLet false false (PVar "idx") (EApp (EApp (EVar "seenCount") (EVar "hdr")) (EVar "counts"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EApp (EVar "stringConcat") (EListLit (EVar "hdr") (ELit (LString ".")) (EApp (EVar "intToString") (EVar "idx"))))) (EApp (EApp (EVar "bumpCount") (EVar "hdr")) (EVar "counts"))) (EVar "acc"))))) (arm (PCon "None") () (EMatch (EApp (EVar "parseKv") (EVar "trimmed")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "k") (PVar "v"))) () (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "section")) (EVar "counts")) (EBinOp "::" (ETuple (EApp (EApp (EVar "qualifyKey") (EVar "section")) (EVar "k")) (EVar "v")) (EVar "acc")))))))))))
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
(DFunDef false "getString" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "Some" (PCon "TStr" (PVar "s"))) () (EApp (EVar "Some") (EVar "s"))) (arm PWild () (EVar "None"))))
(DTypeSig true "getArray" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "getArray" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "Some" (PCon "TArr" (PVar "xs"))) () (EApp (EVar "Some") (EVar "xs"))) (arm PWild () (EVar "None"))))
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
(DTypeSig false "stripTablePrefix" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))))))
(DFunDef false "stripTablePrefix" (PWild (PList)) (EListLit))
(DFunDef false "stripTablePrefix" ((PVar "prefix") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "k")) (EBinOp "::" (ETuple (EApp (EApp (EVar "drop") (EApp (EVar "stringLength") (EVar "prefix"))) (EVar "k")) (EVar "v")) (EApp (EApp (EVar "stripTablePrefix") (EVar "prefix")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "stripTablePrefix") (EVar "prefix")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "tableEntry" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "Toml"))))))
(DFunDef false "tableEntry" ((PVar "name") (PVar "i") (PCon "Toml" (PVar "kvs"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EApp (EVar "tableCount") (EVar "name")) (EApp (EVar "Toml") (EVar "kvs"))))) (EVar "None") (EApp (EVar "Some") (EApp (EVar "Toml") (EApp (EApp (EVar "stripTablePrefix") (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString ".")) (EApp (EVar "intToString") (EVar "i")) (ELit (LString "."))))) (EVar "kvs"))))))
(DTypeSig false "eqTomlValue" (TyFun (TyCon "TomlValue") (TyFun (TyCon "TomlValue") (TyCon "Bool"))))
(DFunDef false "eqTomlValue" ((PCon "TStr" (PVar "a")) (PCon "TStr" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "eqTomlValue" ((PCon "TArr" (PVar "a")) (PCon "TArr" (PVar "b"))) (EApp (EApp (EVar "eqStrLists") (EVar "a")) (EVar "b")))
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
(DFunDef false "debugTomlValue" ((PCon "TStr" (PVar "s"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TStr ")) (EApp (EVar "debug") (EVar "s")))))
(DFunDef false "debugTomlValue" ((PCon "TArr" (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TArr ")) (EApp (EVar "debugStrList") (EVar "xs")))))
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
(DFunDef false "displayTomlValue" ((PCon "TStr" (PVar "s"))) (EApp (EVar "debug") (EVar "s")))
(DFunDef false "displayTomlValue" ((PCon "TArr" (PVar "xs"))) (EApp (EVar "debugStrList") (EVar "xs")))
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
(DProp false "Display TomlValue separates the four variants" ((pp "n" (TyCon "Int")) (pp "b" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "intToString") (EVar "n"))) (DoLet false false (PVar "vs") (EListLit (EApp (EVar "TStr") (EVar "s")) (EApp (EVar "TArr") (EListLit (EVar "s"))) (EApp (EVar "TInt") (EVar "n")) (EApp (EVar "TBool") (EVar "b")))) (DoExpr (EApp (EVar "allDistinct") (EApp (EApp (EVar "map") (EVar "display")) (EVar "vs"))))))
(DTypeSig false "allDistinct" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "allDistinct" ((PList)) (EVar "True"))
(DFunDef false "allDistinct" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "all") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "x") (EVar "_s")))) (EVar "rest")) (EApp (EVar "allDistinct") (EVar "rest"))))
(DProp false "Display Toml agrees with Eq Toml" ((pp "k" (TyCon "String")) (pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n")))))) (DoLet false false (PVar "b") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n")))))) (DoLet false false (PVar "c") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EBinOp "+" (EVar "n") (ELit (LInt 1)))))))) (DoLet false false (PVar "d") (EApp (EVar "Toml") (EListLit (ETuple (EBinOp "++" (EVar "k") (ELit (LString "x"))) (EApp (EVar "TInt") (EVar "n")))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "display") (EVar "a")) (EApp (EVar "display") (EVar "b"))) (EApp (EApp (EVar "eq") (EVar "a")) (EVar "b"))) (EApp (EVar "not") (EBinOp "==" (EApp (EVar "display") (EVar "a")) (EApp (EVar "display") (EVar "c"))))) (EApp (EVar "not") (EBinOp "==" (EApp (EVar "display") (EVar "a")) (EApp (EVar "display") (EVar "d"))))))))
(DProp false "Display Toml renders every entry" ((pp "k" (TyCon "String")) (pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "one") (EApp (EVar "display") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n"))))))) (DoLet false false (PVar "two") (EApp (EVar "display") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n"))) (ETuple (EBinOp "++" (EVar "k") (ELit (LString "2"))) (EApp (EVar "TInt") (EVar "n"))))))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "two")) (EApp (EVar "stringLength") (EVar "one"))) (EApp (EApp (EVar "contains") (EApp (EVar "displayTomlValue") (EApp (EVar "TInt") (EVar "n")))) (EVar "two"))))))
# MARK
(DUse false (UseGroup ("string") ((mem "trim" false) (mem "lines" false) (mem "toInt" false) (mem "startsWith" false) (mem "drop" false) (mem "indexOf" false) (mem "contains" false))))
(DUse false (UseGroup ("core") ((mem "Display" false))))
(DData Public "TomlValue" () ((variant "TStr" (ConPos (TyCon "String"))) (variant "TArr" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "TInt" (ConPos (TyCon "Int"))) (variant "TBool" (ConPos (TyCon "Bool")))) ())
(DData Public "Toml" () ((variant "Toml" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))))) ())
(DTypeSig false "listReverse" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "listReverse" () (EApp (EVar "listRevGo") (EListLit)))
(DTypeSig false "listRevGo" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "listRevGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "listRevGo" ((PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "listRevGo") (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "xs")))
(DTypeSig false "stripComment" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripComment" ((PVar "s")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (ELit (LInt 0))) (EVar "n")) (EVar "False")) (EListLit)))))
(DTypeSig false "stripCommentGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyCon "String")))))))
(DFunDef false "stripCommentGo" ((PVar "arr") (PVar "i") (PVar "n") (PVar "inStr") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "listReverse") (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentStep") (EVar "arr")) (EVar "i")) (EVar "n")) (EVar "inStr")) (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stripCommentStep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyFun (TyCon "Char") (TyCon "String"))))))))
(DFunDef false "stripCommentStep" ((PVar "arr") (PVar "i") (PVar "n") (PVar "inStr") (PVar "acc") (PVar "c")) (EIf (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 34))) (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "not") (EVar "inStr"))) (EBinOp "::" (EVar "c") (EVar "acc"))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 35))) (EApp (EVar "not") (EVar "inStr"))) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "listReverse") (EVar "acc")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "stripCommentGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "inStr")) (EBinOp "::" (EVar "c") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseQuotedStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "parseQuotedStr" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseQuotedBody") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected '\"'"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseQuotedBody" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "parseQuotedBody" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated string"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EVar "Ok") (ETuple (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "listReverse") (EVar "acc")))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "parseQuotedBody") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseArrayValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "parseArrayValue" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unexpected end of input"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "Err") (ELit (LString "expected '['"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseArrayItems" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArrayItems" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated array"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "]"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "listReverse") (EVar "acc")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseArrayItemStr") (EVar "arr")) (EVar "i")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unexpected char in array: '")) (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "parseArrayItemStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArrayItemStr" ((PVar "arr") (PVar "i") (PVar "acc")) (EMatch (EApp (EApp (EVar "parseQuotedStr") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "s") (PVar "j"))) () (EApp (EApp (EApp (EVar "parseArraySep") (EVar "arr")) (EVar "j")) (EBinOp "::" (EVar "s") (EVar "acc"))))))
(DTypeSig false "parseArraySep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "parseArraySep" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EVar "Err") (ELit (LString "unterminated array"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "parseArraySep") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "parseArraySep") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar ","))) (EApp (EApp (EApp (EVar "parseArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "]"))) (EApp (EVar "Ok") (ETuple (EApp (EVar "listReverse") (EVar "acc")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "expected ',' or ']' in array, found: '")) (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (ELit (LString "'"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "skipSpaces" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipSpaces" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "n") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar " "))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\t"))) (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "parseKv" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))
(DFunDef false "parseKv" ((PVar "line")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "stringToChars") (EVar "line"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "findEq") (EVar "arr")) (EVar "n")) (ELit (LInt 0))))))
(DTypeSig false "findEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "findEq" ((PVar "arr") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "expected '=' in: ")) (EApp (EVar "stringFromChars") (EVar "arr"))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "="))) (EApp (EApp (EApp (EVar "parseKvAfterEq") (EVar "arr")) (EVar "n")) (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "findEq") (EVar "arr")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "parseKvAfterEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvAfterEq" ((PVar "arr") (PVar "n") (PVar "eq")) (EBlock (DoLet false false (PVar "keyRaw") (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EMethodRef "eq")) (ELam ((PVar "k")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr")))))) (DoLet false false (PVar "key") (EApp (EVar "trim") (EVar "keyRaw"))) (DoExpr (EIf (EApp (EApp (EVar "contains") (ELit (LString "."))) (EVar "key")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "dotted key '")) (EVar "key") (ELit (LString "' is not supported: use table headers instead"))))) (EBlock (DoLet false false (PVar "valStart") (EApp (EApp (EApp (EVar "skipSpaces") (EVar "arr")) (EBinOp "+" (EMethodRef "eq") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseKvValue") (EVar "arr")) (EVar "n")) (EVar "valStart")) (EVar "key"))))))))
(DTypeSig false "parseKvValue" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue"))))))))
(DFunDef false "parseKvValue" ((PVar "arr") (PVar "n") (PVar "i") (PVar "key")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "missing value for key: ")) (EVar "key")))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\""))) (EApp (EApp (EApp (EVar "parseKvStr") (EVar "arr")) (EVar "i")) (EVar "key")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "parseKvArr") (EVar "arr")) (EVar "i")) (EVar "key")) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseKvScalar") (EApp (EApp (EApp (EVar "restOfLine") (EVar "arr")) (EVar "n")) (EVar "i"))) (EVar "key")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "checkLineConsumed" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "checkLineConsumed" ((PVar "arr") (PVar "j") (PVar "key")) (EBlock (DoLet false false (PVar "trailing") (EApp (EApp (EApp (EVar "restOfLine") (EVar "arr")) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "j"))) (DoExpr (EIf (EBinOp "==" (EVar "trailing") (ELit (LString ""))) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "trailing content after value for key '")) (EVar "key") (ELit (LString "': ")) (EVar "trailing"))))))))
(DTypeSig false "parseKvStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvStr" ((PVar "arr") (PVar "i") (PVar "key")) (EMatch (EApp (EApp (EVar "parseQuotedStr") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "s") (PVar "j"))) () (EApp (EApp (EMethodRef "map") (ELam (PWild) (ETuple (EVar "key") (EApp (EVar "TStr") (EVar "s"))))) (EApp (EApp (EApp (EVar "checkLineConsumed") (EVar "arr")) (EVar "j")) (EVar "key"))))))
(DTypeSig false "parseKvArr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue")))))))
(DFunDef false "parseKvArr" ((PVar "arr") (PVar "i") (PVar "key")) (EMatch (EApp (EApp (EVar "parseArrayValue") (EVar "arr")) (EVar "i")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "xs") (PVar "j"))) () (EApp (EApp (EMethodRef "map") (ELam (PWild) (ETuple (EVar "key") (EApp (EVar "TArr") (EVar "xs"))))) (EApp (EApp (EApp (EVar "checkLineConsumed") (EVar "arr")) (EVar "j")) (EVar "key"))))))
(DTypeSig false "restOfLine" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "restOfLine" ((PVar "arr") (PVar "n") (PVar "i")) (EApp (EVar "trim") (EApp (EVar "stringFromChars") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "n") (EVar "i"))) (ELam ((PVar "j")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "arr")))))))
(DTypeSig false "parseKvScalar" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TomlValue"))))))
(DFunDef false "parseKvScalar" ((PVar "tok") (PVar "key")) (EIf (EBinOp "==" (EVar "tok") (ELit (LString "true"))) (EApp (EVar "Ok") (ETuple (EVar "key") (EApp (EVar "TBool") (EVar "True")))) (EIf (EBinOp "==" (EVar "tok") (ELit (LString "false"))) (EApp (EVar "Ok") (ETuple (EVar "key") (EApp (EVar "TBool") (EVar "False")))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "toInt") (EVar "tok")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Ok") (ETuple (EVar "key") (EApp (EVar "TInt") (EVar "n"))))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (ELit (LString "unsupported value for key '")) (EVar "key") (ELit (LString "': ")) (EVar "tok") (ELit (LString " (expected a quoted string, a string array, an integer, or true/false)"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DData Private "Header" () ((variant "HTable" (ConPos (TyCon "String"))) (variant "HArrayTable" (ConPos (TyCon "String")))) ())
(DTypeSig false "parseHeader" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Header"))))
(DFunDef false "parseHeader" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "s")) (ELit (LString "[[")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "n")) (EVar "s")) (ELit (LString "]]")))) (EApp (EVar "Some") (EApp (EVar "HArrayTable") (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "s"))))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "[")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "]")))) (EApp (EVar "Some") (EApp (EVar "HTable") (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s"))))) (EVar "None"))))))
(DTypeSig false "qualifyKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "qualifyKey" ((PVar "section") (PVar "key")) (EIf (EBinOp "==" (EVar "section") (ELit (LString ""))) (EVar "key") (EIf (EVar "otherwise") (EApp (EVar "stringConcat") (EListLit (EVar "section") (ELit (LString ".")) (EVar "key"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "seenCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Int"))))
(DFunDef false "seenCount" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "seenCount" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "name")) (EVar "c") (EIf (EVar "otherwise") (EApp (EApp (EVar "seenCount") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bumpCount" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "bumpCount" ((PVar "name") (PList)) (EListLit (ETuple (EVar "name") (ELit (LInt 1)))))
(DFunDef false "bumpCount" ((PVar "name") (PCons (PTuple (PVar "k") (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "name")) (EBinOp "::" (ETuple (EVar "k") (EBinOp "+" (EVar "c") (ELit (LInt 1)))) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "c")) (EApp (EApp (EVar "bumpCount") (EVar "name")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseLinesAcc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue")))))))))
(DFunDef false "parseLinesAcc" ((PList) PWild PWild (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "listReverse") (EVar "acc"))))
(DFunDef false "parseLinesAcc" ((PCons (PVar "l") (PVar "ls")) (PVar "section") (PVar "counts") (PVar "acc")) (EBlock (DoLet false false (PVar "trimmed") (EApp (EVar "trim") (EApp (EVar "stripComment") (EVar "l")))) (DoExpr (EIf (EBinOp "==" (EVar "trimmed") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "section")) (EVar "counts")) (EVar "acc")) (EMatch (EApp (EVar "parseHeader") (EVar "trimmed")) (arm (PCon "Some" (PCon "HTable" (PVar "hdr"))) () (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "hdr")) (EVar "counts")) (EVar "acc"))) (arm (PCon "Some" (PCon "HArrayTable" (PVar "hdr"))) () (EBlock (DoLet false false (PVar "idx") (EApp (EApp (EVar "seenCount") (EVar "hdr")) (EVar "counts"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EApp (EVar "stringConcat") (EListLit (EVar "hdr") (ELit (LString ".")) (EApp (EVar "intToString") (EVar "idx"))))) (EApp (EApp (EVar "bumpCount") (EVar "hdr")) (EVar "counts"))) (EVar "acc"))))) (arm (PCon "None") () (EMatch (EApp (EVar "parseKv") (EVar "trimmed")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PVar "k") (PVar "v"))) () (EApp (EApp (EApp (EApp (EVar "parseLinesAcc") (EVar "ls")) (EVar "section")) (EVar "counts")) (EBinOp "::" (ETuple (EApp (EApp (EVar "qualifyKey") (EVar "section")) (EVar "k")) (EVar "v")) (EVar "acc")))))))))))
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
(DFunDef false "getString" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "Some" (PCon "TStr" (PVar "s"))) () (EApp (EVar "Some") (EVar "s"))) (arm PWild () (EVar "None"))))
(DTypeSig true "getArray" (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "getArray" ((PVar "key") (PCon "Toml" (PVar "kvs"))) (EMatch (EApp (EApp (EVar "lookupKvs") (EVar "key")) (EVar "kvs")) (arm (PCon "Some" (PCon "TArr" (PVar "xs"))) () (EApp (EVar "Some") (EVar "xs"))) (arm PWild () (EVar "None"))))
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
(DTypeSig false "stripTablePrefix" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TomlValue"))))))
(DFunDef false "stripTablePrefix" (PWild (PList)) (EListLit))
(DFunDef false "stripTablePrefix" ((PVar "prefix") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "k")) (EBinOp "::" (ETuple (EApp (EApp (EVar "drop") (EApp (EVar "stringLength") (EVar "prefix"))) (EVar "k")) (EVar "v")) (EApp (EApp (EVar "stripTablePrefix") (EVar "prefix")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "stripTablePrefix") (EVar "prefix")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "tableEntry" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Toml") (TyApp (TyCon "Option") (TyCon "Toml"))))))
(DFunDef false "tableEntry" ((PVar "name") (PVar "i") (PCon "Toml" (PVar "kvs"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EApp (EVar "tableCount") (EVar "name")) (EApp (EVar "Toml") (EVar "kvs"))))) (EVar "None") (EApp (EVar "Some") (EApp (EVar "Toml") (EApp (EApp (EVar "stripTablePrefix") (EApp (EVar "stringConcat") (EListLit (EVar "name") (ELit (LString ".")) (EApp (EVar "intToString") (EVar "i")) (ELit (LString "."))))) (EVar "kvs"))))))
(DTypeSig false "eqTomlValue" (TyFun (TyCon "TomlValue") (TyFun (TyCon "TomlValue") (TyCon "Bool"))))
(DFunDef false "eqTomlValue" ((PCon "TStr" (PVar "a")) (PCon "TStr" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "eqTomlValue" ((PCon "TArr" (PVar "a")) (PCon "TArr" (PVar "b"))) (EApp (EApp (EVar "eqStrLists") (EVar "a")) (EVar "b")))
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
(DFunDef false "debugTomlValue" ((PCon "TStr" (PVar "s"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TStr ")) (EApp (EMethodRef "debug") (EVar "s")))))
(DFunDef false "debugTomlValue" ((PCon "TArr" (PVar "xs"))) (EApp (EVar "stringConcat") (EListLit (ELit (LString "TArr ")) (EApp (EVar "debugStrList") (EVar "xs")))))
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
(DFunDef false "displayTomlValue" ((PCon "TStr" (PVar "s"))) (EApp (EMethodRef "debug") (EVar "s")))
(DFunDef false "displayTomlValue" ((PCon "TArr" (PVar "xs"))) (EApp (EVar "debugStrList") (EVar "xs")))
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
(DProp false "Display TomlValue separates the four variants" ((pp "n" (TyCon "Int")) (pp "b" (TyCon "Bool"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "intToString") (EVar "n"))) (DoLet false false (PVar "vs") (EListLit (EApp (EVar "TStr") (EVar "s")) (EApp (EVar "TArr") (EListLit (EVar "s"))) (EApp (EVar "TInt") (EVar "n")) (EApp (EVar "TBool") (EVar "b")))) (DoExpr (EApp (EVar "allDistinct") (EApp (EApp (EMethodRef "map") (EMethodRef "display")) (EVar "vs"))))))
(DTypeSig false "allDistinct" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "allDistinct" ((PList)) (EVar "True"))
(DFunDef false "allDistinct" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EDictApp "all") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "x") (EVar "_s")))) (EVar "rest")) (EApp (EVar "allDistinct") (EVar "rest"))))
(DProp false "Display Toml agrees with Eq Toml" ((pp "k" (TyCon "String")) (pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n")))))) (DoLet false false (PVar "b") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n")))))) (DoLet false false (PVar "c") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EBinOp "+" (EVar "n") (ELit (LInt 1)))))))) (DoLet false false (PVar "d") (EApp (EVar "Toml") (EListLit (ETuple (EBinOp "++" (EVar "k") (ELit (LString "x"))) (EApp (EVar "TInt") (EVar "n")))))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EMethodRef "display") (EVar "a")) (EApp (EMethodRef "display") (EVar "b"))) (EApp (EApp (EMethodRef "eq") (EVar "a")) (EVar "b"))) (EApp (EVar "not") (EBinOp "==" (EApp (EMethodRef "display") (EVar "a")) (EApp (EMethodRef "display") (EVar "c"))))) (EApp (EVar "not") (EBinOp "==" (EApp (EMethodRef "display") (EVar "a")) (EApp (EMethodRef "display") (EVar "d"))))))))
(DProp false "Display Toml renders every entry" ((pp "k" (TyCon "String")) (pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "one") (EApp (EMethodRef "display") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n"))))))) (DoLet false false (PVar "two") (EApp (EMethodRef "display") (EApp (EVar "Toml") (EListLit (ETuple (EVar "k") (EApp (EVar "TInt") (EVar "n"))) (ETuple (EBinOp "++" (EVar "k") (ELit (LString "2"))) (EApp (EVar "TInt") (EVar "n"))))))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "two")) (EApp (EVar "stringLength") (EVar "one"))) (EApp (EApp (EVar "contains") (EApp (EVar "displayTomlValue") (EApp (EVar "TInt") (EVar "n")))) (EVar "two"))))))
