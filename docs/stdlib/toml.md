# toml

## `TomlValue`

```
data TomlValue
  = TStr String
  | TArr (List String)
  | TInt Int
  | TBool Bool
```

Instances: `Eq`, `Debug`, [`Display`](#display-tomlvalue)

## `Toml`

```
data Toml
  = Toml (List (String, TomlValue))
```

Instances: `Eq`, `Debug`, [`Display`](#display-toml)

A parsed TOML document: a flat list of (qualifiedKey, value) pairs.

## `parse`

```
parse : String -> Result String Toml
```

Parse a TOML string (supported subset) into a `Toml` document, or an
error message describing the first parse failure.

A `[package]` section — note every key is qualified by its section:

```medaka
> parse "[package]\nname = \"hello\"\nversion = \"0.1.0\"" == Ok (Toml [("package.name", TStr "hello"), ("package.version", TStr "0.1.0")])
True
```

A `[workspace]` section with a string array:

```medaka
> parse "[workspace]\nmembers = [\"pkg-a\", \"pkg-b\"]" == Ok (Toml [("workspace.members", TArr ["pkg-a", "pkg-b"])])
True
```

Integer and boolean values:

```medaka
> parse "[limits]\nretries = 3\nverbose = true\noffset = -7" == Ok (Toml [("limits.retries", TInt 3), ("limits.verbose", TBool True), ("limits.offset", TInt (0 - 7))])
True
```

Repeated `[[gate]]` headers open successive indexed entries:

```medaka
> parse "[[gate]]\nname = \"a\"\n[[gate]]\nname = \"b\"" == Ok (Toml [("gate.0.name", TStr "a"), ("gate.1.name", TStr "b")])
True
```

Comments and blank lines are ignored:

```medaka
> parse "# just a comment\n\nname = \"x\"" == Ok (Toml [("name", TStr "x")])
True
```

Inline `#` after a value is stripped:

```medaka
> parse "name = \"hello\" # a comment" == Ok (Toml [("name", TStr "hello")])
True
```

## `getString`

```
getString : String -> Toml -> Option String
```

Look up a string value by (qualified) key.  Returns `None` if the key is
absent or holds an array.

```medaka
> parseGetStr "package.name" "[package]\nname = \"medaka\"\nversion = \"1.0.0\"\nentry = \"main.mdk\""
Some "medaka"
```

Returns `None` for an array-valued key:

```medaka
> parseGetStr "workspace.members" "[workspace]\nmembers = [\"a\"]"
None
```

Returns `None` for an absent key:

```medaka
> parseGetStr "missing" "[package]\nname = \"x\""
None
```

Returns `None` when the table itself is absent:

```medaka
> parseGetStr "server.host" "[package]\nname = \"x\""
None
```

## `getArray`

```
getArray : String -> Toml -> Option (List String)
```

Look up an array-of-strings value by (qualified) key.  Returns `None` if
the key is absent or holds a string.

```medaka
> parseGetArr "workspace.members" "[workspace]\nmembers = [\"pkg-a\", \"pkg-b\"]"
Some ["pkg-a", "pkg-b"]
```

Returns `None` for a string-valued key:

```medaka
> parseGetArr "package.name" "[package]\nname = \"x\"\nversion = \"0.1.0\"\nentry = \"main.mdk\""
None
```

Returns `None` for an absent key:

```medaka
> parseGetArr "workspace.members" "[package]\nname = \"x\""
None
```

An empty array yields `Some []`:

```medaka
> parseGetArr "workspace.members" "[workspace]\nmembers = []"
Some []
```

## `getInt`

```
getInt : String -> Toml -> Option Int
```

Look up an integer value by (qualified) key.  `None` if the key is absent
or holds another type.

```medaka
> parseGetInt "limits.retries" "[limits]\nretries = 3"
Some 3
```

Negative integers parse:

```medaka
> parseGetInt "limits.offset" "[limits]\noffset = -7" == Some (0 - 7)
True
```

`None` for a string-valued key:

```medaka
> parseGetInt "package.name" "[package]\nname = \"x\""
None
```

## `getBool`

```
getBool : String -> Toml -> Option Bool
```

Look up a boolean value by (qualified) key.  `None` if the key is absent
or holds another type.

```medaka
> parseGetBool "limits.verbose" "[limits]\nverbose = true"
Some True
```

```medaka
> parseGetBool "limits.verbose" "[limits]\nverbose = false"
Some False
```

`None` for an integer-valued key:

```medaka
> parseGetBool "limits.retries" "[limits]\nretries = 3"
None
```

## `tableCount`

```
tableCount : String -> Toml -> Int
```

How many `[[name]]` entries the document contains.

```medaka
> parseTableCount "gate" "[[gate]]\nname = \"a\"\n[[gate]]\nname = \"b\""
2
```

Zero when the table is absent:

```medaka
> parseTableCount "gate" "[package]\nname = \"x\""
0
```

## `tableEntry`

```
tableEntry : String -> Int -> Toml -> Option Toml
```

The `i`-th (0-based) `[[name]]` entry, as a sub-document whose keys are
bare — so `getString`/`getArray`/`getInt`/`getBool` apply unchanged.
`None` when `i` is out of range.

`Option`, not a bare `Toml`, for the same reason `path.stripPrefix` is
(#2310's defect class): an out-of-range index used to come back as a
document in which every lookup happens to be `None`, so "no such entry" and
"an entry with no keys" were the same value.

```medaka
> parseTableEntryStr "gate" 1 "name" "[[gate]]\nname = \"a\"\n[[gate]]\nname = \"b\""
Some "b"
```

An out-of-range index is `None`:

```medaka
> parseTableEntryStr "gate" 9 "name" "[[gate]]\nname = \"a\""
None
```

## Instances

### `Display TomlValue`

```
impl Display TomlValue
```

A `TomlValue` in TOML's own scalar spelling.

```medaka
> display (TStr "hi")
"\"hi\""
> display (TInt 42)
"42"
> display (TBool True)
"true"
> display (TArr ["a", "b"])
"[\"a\", \"b\"]"
```

### `Display Toml`

```
impl Display Toml
```

A whole document as `Toml { key = value, … }` (empty -> `Toml {}`),
mirroring `Display (Map k v)`'s `Map { … }`.

```medaka
> display (Toml [("a.b", TInt 1), ("c", TBool False)])
"Toml { a.b = 1, c = false }"
> display (Toml [])
"Toml {}"
```

