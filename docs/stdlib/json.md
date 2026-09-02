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
```

A `JArray` holding the elements of a list.

```medaka
> stringify (jArray [JInt 1, JInt 2, JInt 3])
"[1,2,3]"
```

### `jObject`

```
jObject : List (String, Json) -> Json
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
```

The value as compact JSON text, with no whitespace between tokens.

Strings are escaped as JSON requires. A float always has a digit after
its decimal point, so the text parses again.

```medaka
> stringify (jObject [("a", JInt 1), ("b", JString "hi")])
"{\"a\":1,\"b\":\"hi\"}"
> stringify (JFloat 1000.0)
"1000.0"
```

## Parsing

### `parse`

```
parse : String -> Result String Json
```

The value written in JSON text, or `Err` with a message when the text
is not valid JSON.

Whitespace around the value is allowed. Anything after the value is an
error. Unicode escapes, including surrogate pairs, are decoded; a lone
surrogate is an error.

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

