# hex

Hexadecimal encoding and decoding of bytes.

`encode`/`decode` take an `Array Int` with each element from `0` to `255`,
the same form `readFileBytes` and `writeFileBytes` use; `encodeBytes`/
`decodeBytes` take and return `Bytes` instead. Each byte becomes two hex
digits, most significant first. Encoding produces lowercase digits and
decoding accepts either case.

An element outside `0` to `255` is masked to its low eight bits on the way
in rather than refused, so `-1` and `511` both encode as `ff`.

## Encoding

### `encodeBytes`

```
encodeBytes : Bytes -> String
```

The byte string as lowercase hex, two digits per byte.

```medaka
> encodeBytes (fromArrayAssumeByteDomain [|255, 0, 16|])
"ff0010"
```

### `encode`

```
encode : Array Int -> String
```

The bytes as lowercase hex, two digits per byte.

```medaka
> encode (fromList [255, 0, 16])
"ff0010"
```

### `encodeUpper`

```
encodeUpper : Array Int -> String
```

The bytes as uppercase hex, two digits per byte.

```medaka
> encodeUpper (fromList [255, 0, 16])
"FF0010"
```

### `encodeString`

```
encodeString : String -> String
```

The UTF-8 bytes of a string as lowercase hex.

```medaka
> encodeString "Hello"
"48656c6c6f"
```

## Decoding

### `decodeBytes`

```
decodeBytes : String -> Result String Bytes
```

The bytes written in a hex string, as a `Bytes`.

`Err` when the string has an odd length or any character that is not a
hex digit. Whitespace is not skipped.

```medaka
> map toArray (decodeBytes "ff0010")
Ok [|255, 0, 16|]
> decodeBytes "zz"
Err "hex.decode: invalid hex digit"
```

### `decode`

```
decode : String -> Result String (Array Int)
```

The bytes written in a hex string.

`Err` when the string has an odd length or any character that is not a
hex digit. Whitespace is not skipped.

```medaka
> decode "ff0010"
Ok [|255, 0, 16|]
> decode "zz"
Err "hex.decode: invalid hex digit"
```

### `decodeString`

```
decodeString : String -> Result String String
```

The string whose UTF-8 bytes are written in a hex string.

```medaka
> decodeString "48656c6c6f"
Ok "Hello"
```

