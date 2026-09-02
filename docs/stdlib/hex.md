# hex

Hexadecimal encoding and decoding of bytes.

Bytes are an `Array Int` with each element from `0` to `255`, the same
form `readFileBytes` and `writeFileBytes` use. Each byte becomes two hex
digits, most significant first. `encode` produces lowercase digits and
`decode` accepts either case.

## Encoding

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

