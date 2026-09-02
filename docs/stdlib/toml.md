# toml

A reader for a subset of TOML.

`parse` reads a document with `[section]` and `[[table]]` headers and
keys whose values are double-quoted strings, arrays of strings,
integers, or booleans, with `#` comments. Anything else (floats, dates,
multi-line strings, inline tables, dotted keys, and escape sequences) is
an error, never silently dropped.

The parsed `Toml` is a flat list of keys and values, with every key
qualified by its section: `name` under `[package]` is `"package.name"`,
and a key under the `i`-th `[[gate]]` header is `"gate.i.name"`. The
`get` functions look a value up by that qualified key; `tableCount` and
`tableEntry` work with array-of-table entries. There is no writer.

## The document

### `TomlValue`

```
data TomlValue
  = TStr String
  | TArr (List String)
  | TInt Int
  | TBool Bool
```

A value: a string, an array of strings, an integer, or a boolean.

Instances: `Eq`, `Debug`, [`Display`](#display-tomlvalue)

### `Toml`

```
data Toml
  = Toml (List (String, TomlValue))
```

A parsed document: its keys, qualified by section, with their values.

Instances: `Eq`, `Debug`, [`Display`](#display-toml)

## Parsing

### `parse`

```
parse : String -> Result String Toml
```

The document written in a TOML string, or `Err` with a message for
the first line that could not be read.

Keys are qualified by their section. Comments and blank lines are
ignored.

```medaka
> parse "[package]\nname = \"hello\"\nversion = \"0.1.0\""
Ok Toml [("package.name", TStr "hello"), ("package.version", TStr "0.1.0")]
> parse "[[gate]]\nname = \"a\"\n[[gate]]\nname = \"b\""
Ok Toml [("gate.0.name", TStr "a"), ("gate.1.name", TStr "b")]
```

## Accessors

### `getString`

```
getString : String -> Toml -> Option String
```

The string at a qualified key, or `None` when the key is absent or
holds another kind of value.

```medaka
> parseGetStr "package.name" "[package]\nname = \"medaka\"\nversion = \"1.0.0\"\nentry = \"main.mdk\""
Some "medaka"
> parseGetStr "missing" "[package]\nname = \"x\""
None
```

### `getArray`

```
getArray : String -> Toml -> Option (List String)
```

The array of strings at a qualified key, or `None` when the key is
absent or holds another kind of value.

```medaka
> parseGetArr "workspace.members" "[workspace]\nmembers = [\"pkg-a\", \"pkg-b\"]"
Some ["pkg-a", "pkg-b"]
> parseGetArr "workspace.members" "[workspace]\nmembers = []"
Some []
```

### `getInt`

```
getInt : String -> Toml -> Option Int
```

The integer at a qualified key, or `None` when the key is absent or
holds another kind of value.

```medaka
> parseGetInt "limits.retries" "[limits]\nretries = 3"
Some 3
> parseGetInt "package.name" "[package]\nname = \"x\""
None
```

### `getBool`

```
getBool : String -> Toml -> Option Bool
```

The boolean at a qualified key, or `None` when the key is absent or
holds another kind of value.

```medaka
> parseGetBool "limits.verbose" "[limits]\nverbose = true"
Some True
> parseGetBool "limits.retries" "[limits]\nretries = 3"
None
```

## Arrays of tables

### `tableCount`

```
tableCount : String -> Toml -> Int
```

The number of `[[name]]` entries in the document.

```medaka
> parseTableCount "gate" "[[gate]]\nname = \"a\"\n[[gate]]\nname = \"b\""
2
> parseTableCount "gate" "[package]\nname = \"x\""
0
```

### `tableEntry`

```
tableEntry : String -> Int -> Toml -> Option Toml
```

The `i`-th `[[name]]` entry, counting from `0`, as a document of its
own, or `None` when `i` is out of range.

The entry's keys are unqualified, so the `get` functions apply to it
directly.

```medaka
> parseTableEntryStr "gate" 1 "name" "[[gate]]\nname = \"a\"\n[[gate]]\nname = \"b\""
Some "b"
> parseTableEntryStr "gate" 9 "name" "[[gate]]\nname = \"a\""
None
```

## Instances

### `Display TomlValue`

```
impl Display TomlValue
```

`display` renders a value in TOML's own spelling: a string quoted, a
boolean as `true` or `false`.

```medaka
> display (TStr "hi")
"\"hi\""
> display (TBool True)
"true"
```

### `Display Toml`

```
impl Display Toml
```

`display` renders a document as `Toml { key = value, ... }`.

This is not TOML text; `parse` cannot read it back.

```medaka
> display (Toml [("a.b", TInt 1), ("c", TBool False)])
"Toml { a.b = 1, c = false }"
> display (Toml [])
"Toml {}"
```

