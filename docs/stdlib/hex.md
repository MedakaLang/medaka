# hex

Hexadecimal encoding and decoding.

`encode`/`decode` take and return `Bytes`. Each byte becomes two hex
digits, most significant first. Encoding produces lowercase digits and
decoding accepts either case; `encodeUpper` produces uppercase digits.

## Encoding

### `encode`

```
encode : Bytes -> String
encode b
```

The bytes as lowercase hex, two digits per byte.

```medaka
> encode (fromU8Array [|255, 0, 16|])
"ff0010"
```

### `encodeUpper`

```
encodeUpper : Bytes -> String
encodeUpper b
```

The bytes as uppercase hex, two digits per byte.

```medaka
> encodeUpper (fromU8Array [|255, 0, 16|])
"FF0010"
```

### `encodeString`

```
encodeString : String -> String
encodeString s
```

The UTF-8 bytes of a string as lowercase hex.

```medaka
> encodeString "Hello"
"48656c6c6f"
```

## Decoding

### `decode`

```
decode : String -> Result String Bytes
decode s
```

The bytes written in a hex string, as a `Bytes`.

`Err` when the string has an odd length or any character that is not a
hex digit. Whitespace is not skipped.

```medaka
> map toArray (decode "ff0010")
Ok [|255, 0, 16|]
> decode "zz"
Err "hex.decode: invalid hex digit"
```

### `decodeString`

```
decodeString : String -> Result String String
decodeString s
```

The string whose UTF-8 bytes are written in a hex string.

```medaka
> decodeString "48656c6c6f"
Ok "Hello"
```

