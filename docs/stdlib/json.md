# json

A JSON value type with a parser and a serializer.

`parse` turns JSON text into a `Json` value and `stringify` turns a value
back into compact text. Arrays and objects are stored in arrays, so
indexing is `O(1)` and an object keeps its keys in source order. The
accessors (`get`, `at`, `asString`, and the rest) take a value apart
without pattern matching.

Integers and floats are kept apart, so `3` parses as `JInt 3` and
`3.0` as `JFloat 3.0`. Object equality is positional: two objects with the
same pairs in a different order are not equal.

## The Json type

### `Json`

```
data Json
  = JNull
  | JBool Bool
  | JInt Int
  | JFloat Float
  | JString String
  | JArray (Array Json)
  | JObject (Array (String, Json))
```

A JSON value.

`JArray` holds its elements in an array. `JObject` holds its members as
an array of key and value pairs, in source order.

Instances: [`Eq`](#eq-json), [`Debug`](#debug-json), [`Display`](#display-json)

## Construction

### `jArray`

```
jArray : List Json -> Json
jArray xs
```

A `JArray` holding the elements of a list.

```medaka
> stringify (jArray [JInt 1, JInt 2, JInt 3])
"[1,2,3]"
```

### `jObject`

```
jObject : List (String, Json) -> Json
jObject xs
```

A `JObject` holding the members of a list of key and value pairs, in
order.

```medaka
> stringify (jObject [("a", JInt 1), ("b", JBool True)])
"{\"a\":1,\"b\":true}"
```

## Serialization

### `stringify`

```
stringify : Json -> String
stringify j
```

The value as compact JSON text, with no whitespace between tokens.

Strings are escaped as JSON requires. A float always has a digit after
its decimal point, so the text parses again.

```medaka
> stringify (jObject [("a", JInt 1), ("b", JString "hi")])
"{\"a\":1,\"b\":\"hi\"}"
> stringify (JFloat 1000.0)
"1000.0"
> stringify (jObject [("a", jArray [JInt 1, jObject []]), ("b", JNull)])
"{\"a\":[1,{}],\"b\":null}"
```

## Parsing

### `parse`

```
parse : String -> Result String Json
parse s
```

The value written in JSON text, or `Err` with a message when the text
is not valid JSON.

Whitespace around the value is allowed. Anything after the value is an
error. Unicode escapes, including surrogate pairs, are decoded; a lone
surrogate is an error. A number with a leading zero and a string holding
an unescaped control character (below U+0020) are errors, as in ECMA-404.

```medaka
> parse "[1, 2, 3]"
Ok [1,2,3]
> parse "nope"
Err "invalid literal, expected 'null'"
```

## Accessors

### `get`

```
get : String -> Json -> Option Json
get key _
```

The value at `key` in a `JObject`, or `None` when the key is absent or
the value is not an object.

The lookup scans the members in order.

```medaka
> get "b" (jObject [("a", JInt 1), ("b", JInt 2)])
Some 2
> get "z" (jObject [("a", JInt 1)])
None
```

### `at`

```
at : Int -> Json -> Option Json
at k _
```

The element at index `k` of a `JArray`, or `None` when `k` is out of
range or the value is not an array.

```medaka
> at 1 (jArray [JInt 10, JInt 20, JInt 30])
Some 20
> at 5 (jArray [JInt 10])
None
```

### `asString`

```
asString : Json -> Option String
```

The string inside a `JString`, or `None` for any other value.

```medaka
> asString (JString "hi")
Some "hi"
> asString (JInt 1)
None
```

### `asInt`

```
asInt : Json -> Option Int
```

The integer inside a `JInt`, or `None` for any other value.

```medaka
> asInt (JInt 7)
Some 7
> asInt JNull
None
```

### `asFloat`

```
asFloat : Json -> Option Float
```

The float inside a `JFloat`, or `None` for any other value.

```medaka
> asFloat (JFloat 1.5)
Some 1.5
> asFloat (JInt 1)
None
```

### `asBool`

```
asBool : Json -> Option Bool
```

The boolean inside a `JBool`, or `None` for any other value.

```medaka
> asBool (JBool True)
Some True
> asBool JNull
None
```

### `asArray`

```
asArray : Json -> Option (Array Json)
```

The elements of a `JArray`, or `None` for any other value.

```medaka
> map arrayLength (asArray (jArray [JInt 1, JInt 2]))
Some 2
> asArray (JInt 1) == None
True
```

### `asObject`

```
asObject : Json -> Option (Array (String, Json))
```

The members of a `JObject` as key and value pairs, or `None` for any
other value.

```medaka
> map arrayLength (asObject (jObject [("a", JInt 1)]))
Some 1
> asObject (JInt 1) == None
True
```

## Paths and numbers

### `asNumber`

```
asNumber : Json -> Option Float
```

The float inside a `JFloat` or `JInt`, or `None` for any other value.

An integer is converted to a float.

```medaka
> asNumber (JInt 3)
Some 3.0
> asNumber (JFloat 1.5)
Some 1.5
> asNumber (JString "3")
None
```

### `atPath`

```
atPath : List String -> Json -> Result String Json
atPath steps j
```

The value reached by following `steps` from the root, or `Err` saying
which step failed.

A step means what the node it lands on says: on an object it is a key
(the first member with that name), on an array it is a decimal index.
An index has no sign and no leading zero, so `"-1"` and `"01"` are
errors. An empty path is the value itself.

The error names the path walked so far, then the failure. A step that is
empty or contains a `.` is written in quotes in that path.

```medaka
> atPath ["a", "items", "1"] (jObject [("a", jObject [("items", jArray [JInt 7, JInt 8])])])
Ok 8
> atPath ["a", "items", "5"] (jObject [("a", jObject [("items", jArray [JInt 7])])])
Err "at a.items: index 5 out of range (1 elements)"
> atPath ["a", "b"] (jObject [("a", jObject [])])
Err "at a: no key \"b\""
> atPath ["a", "b"] (jObject [("a", JString "x")])
Err "at a: expected object or array, found string"
> atPath ["a.b", "c"] (jObject [("a.b", jObject [])])
Err "at \"a.b\": no key \"c\""
> atPath ["", "c"] (jObject [("", jObject [])])
Err "at \"\": no key \"c\""
```

## Pretty printing

### `pretty`

```
pretty : Int -> Json -> String
pretty n j
```

The value as JSON text spread over lines, indented `n` spaces per level.

Members keep their stored order, `": "` separates a key from its value,
and empty arrays and objects stay on one line. The text has no trailing
newline. An `n` of 0 still breaks lines, with no indentation. A non-finite
float is written as the word inf, -inf or nan, as `stringify` writes it, and
that text is not JSON. A float of magnitude `1e12` up to but not including
`1e16` prints in exponent form (`1e+12`, `1.5e+13`) where Python prints
`1000000000000.0`; `123456789012.0` and `999999999999.0` stay plain.

```medaka
> pretty 2 (jObject [("a", jArray [JInt 1, JInt 2]), ("b", jObject [])])
"{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": {}\n}"
```

## Lines of JSON

### `parseLines`

```
parseLines : String -> List (Result String Json)
parseLines s
```

One result per non-blank line of `s`, in order: the value on that line,
or `Err` with the line number (counting from 1, blank lines included).

A line ending `\r\n` is read like one ending `\n`. A last line cut short
gives an `Err`, not a missing row.

```medaka
> parseLines "{\"a\": 1}\n\n[2,\n"
[Ok {"a":1}, Err "line 3: unexpected end of input"]
```

### `stringifyLines`

```
stringifyLines : List Json -> String
stringifyLines js
```

The values as compact JSON, each followed by a newline. The empty list
gives `""`. `parseLines` reads the text back.

```medaka
> stringifyLines [JInt 1, jArray [JNull]]
"1\n[null]\n"
```

## Instances

### `Eq Json`

```
impl Eq Json
```

Values are equal when they have the same structure. Objects compare
member by member in order, so the same members in a different order are
not equal.

```medaka
> eq (parse "[1, 2]") (Ok (jArray [JInt 1, JInt 2]))
True
```

### `Debug Json`

```
impl Debug Json
```

`debug` renders a value as compact JSON text, the same as `stringify`.

### `Display Json`

```
impl Display Json
```

`display` renders a value as compact JSON text, the same as `stringify`.

