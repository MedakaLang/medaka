# json

json.mdk — a JSON value type with a parser and serializer.

A from-scratch recursive-descent JSON implementation, written to exercise a
wide cross-section of the stdlib: a recursive ADT, `Array`-backed storage,
`Char`/`String` kernel handling, `Thenable`/`do`-notation error threading,
and the `Eq`/`Debug`/`Display` interfaces.

**Value model.**
```
data Json = JNull | JBool Bool | JInt Int | JFloat Float | JString String
| JArray (Array Json) | JObject (Array (String, Json))
```
Numbers split into `JInt`/`JFloat` so `3` round-trips as `3` (not `3.0`) and
the parser must classify int-vs-float. Arrays and objects are **`Array`-backed**
(not `List`): JSON payloads are often large, and a contiguous `Array` gives
O(1) indexing and compact, cache-friendly storage where a cons-list would cost
O(n) access and per-cell overhead. Objects are an `Array` of `(key, value)`
pairs — assoc-style (no `Map` dependency), so insertion order is preserved and
round-trips exactly; key lookup is linear.

**Parsing** uses `Thenable (Result e)` and `do` notation to thread the
`(value, position)` pair through each parse step — `do { (v, j) <- step ;
next v j }` desugars to the `andThen` short-circuit on `Err` automatically.

Built on the stdlib it exists to exercise: `list.reverse`, `string.join`/
`fromChars`/`isDigit`/`toInt`, the `Thenable` monad interface, `do`
notation, plus the global `array*`/`string*`/`char*` externs. Equality is
hand-rolled element-wise (so the `Json` `Eq` recurses
through the `Array` fields without an `Eq (Array a)` dependency) and is
**positional** for objects (two objects with the same pairs in a different
order compare unequal — fine for round-tripping, which preserves order).

**Not handled (v1):** strict leading-zero / number-grammar rejection (the
number scan is lenient). `\uXXXX` surrogate pairs (astral codepoints) ARE
handled: a valid high/low pair decodes to its astral scalar value, and a
lone (unpaired) surrogate is a parse error, not silent corruption.

## `Json`

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

## `jArray`

```
jArray : List Json -> Json
```

Build a `JArray` from a list (stored as a contiguous `Array`).


*(doctest — run by `medaka test`)*

```medaka
> stringify (jArray [JInt 1, JInt 2, JInt 3]) == "[1,2,3]"
True
> stringify (jArray []) == "[]"
True
```

## `jObject`

```
jObject : List (String, Json) -> Json
```

Build a `JObject` from a list of key/value pairs (order preserved).


*(doctest — run by `medaka test`)*

```medaka
> stringify (jObject [("a", JInt 1), ("b", JBool True)]) == "{\"a\":1,\"b\":true}"
True
> stringify (jObject []) == "{}"
True
```

## `stringify`

```
stringify : Json -> String
```

Serialize a `Json` to compact JSON text (no insignificant whitespace).


*(doctest — run by `medaka test`)*

```medaka
> stringify JNull == "null"
True
> stringify (JArray (arrayFromList [JInt 1, JBool True])) == "[1,true]"
True
> stringify (jObject [("a", JInt 1), ("b", JString "hi")]) == "{\"a\":1,\"b\":\"hi\"}"
True
> stringify (JFloat 1000.0) == "1000.0"
True
```

## `parse`

```
parse : String -> Result String Json
```

Parse JSON text into a `Json`, or an error message.


*(doctest — run by `medaka test`)*

```medaka
> parse "null" == Ok JNull
True
> parse "[1, 2, 3]" == Ok (jArray [JInt 1, JInt 2, JInt 3])
True
> parse "  {\"k\": true}  " == Ok (jObject [("k", JBool True)])
True
> parse "nope"
Err "invalid literal, expected 'null'"
> parse "\"a\\u0041b\"" == Ok (JString "aAb")
True
> parse "\"\\uD834\\uDD1E\"" == Ok (JString "𝄞")
True
> parse "\"\\uD834\""
Err "invalid \\u escape"
> parse "\"\\uDC00\""
Err "invalid \\u escape"
> parse "1e+5" == Ok (JFloat 100000.0)
True
> parse "6.022e+23" == Ok (JFloat 6.022e23)
True
> parse (stringify (JFloat 1000000000000.0)) == Ok (JFloat 1000000000000.0)
True
> parse "1e+"
Err "invalid number"
> parse "1e"
Err "invalid number"
```

## `lookup`

```
lookup : String -> Json -> Option Json
```

Value at a key in a `JObject` (linear scan), or `None`.


*(doctest — run by `medaka test`)*

```medaka
> lookup "b" (jObject [("a", JInt 1), ("b", JInt 2)]) == Some (JInt 2)
True
> lookup "z" (jObject [("a", JInt 1)]) == None
True
```

## `at`

```
at : Int -> Json -> Option Json
```

Element at an index in a `JArray` (O(1)), or `None`.


*(doctest — run by `medaka test`)*

```medaka
> at 1 (jArray [JInt 10, JInt 20, JInt 30]) == Some (JInt 20)
True
> at 5 (jArray [JInt 10]) == None
True
> at 0 (JInt 1) == None
True
```

## `asString`

```
asString : Json -> Option String
```

The `String` inside a `JString`, or `None`.


*(doctest — run by `medaka test`)*

```medaka
> asString (JString "hi") == Some "hi"
True
> asString (JInt 1) == None
True
```

## `asInt`

```
asInt : Json -> Option Int
```

The `Int` inside a `JInt`, or `None`.


*(doctest — run by `medaka test`)*

```medaka
> asInt (JInt 7) == Some 7
True
> asInt JNull == None
True
```

## `asFloat`

```
asFloat : Json -> Option Float
```

The `Float` inside a `JFloat`, or `None`.


*(doctest — run by `medaka test`)*

```medaka
> asFloat (JFloat 1.5) == Some 1.5
True
> asFloat (JInt 1) == None
True
```

## `asBool`

```
asBool : Json -> Option Bool
```

The `Bool` inside a `JBool`, or `None`.


*(doctest — run by `medaka test`)*

```medaka
> asBool (JBool True) == Some True
True
> asBool JNull == None
True
```

## `asArray`

```
asArray : Json -> Option (Array Json)
```

The backing `Array` of a `JArray`, or `None`.  (Re-wrap the result in
`JArray` with `map` to compare it as a `Json` — there is no `Eq (Array Json)`
in scope here.)


*(doctest — run by `medaka test`)*

```medaka
> map JArray (asArray (jArray [JInt 1, JInt 2])) == Some (jArray [JInt 1, JInt 2])
True
> asArray (JInt 1) == None
True
```

## `Eq Json`

```
impl Eq Json
```

Structural equality. Objects compare **positionally** (same pairs in the
same order), which is what `parse-then-stringify` preserves.


*(doctest — run by `medaka test`)*

```medaka
> eq (parse "[1, 2]") (Ok (jArray [JInt 1, JInt 2]))
True
```

## `Debug Json`

```
impl Debug Json
```

`debug` renders compact JSON text (same as `stringify`).

## `Display Json`

```
impl Display Json
```

`display`/`\{…}` also render compact JSON text.

