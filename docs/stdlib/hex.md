# hex

## `encode`

```
encode : Array Int -> String
```

Bytes → lowercase hex string, two characters per byte, most-significant
nibble first.

```medaka
> encode (fromList [255, 0, 16])
"ff0010"
> encode ([||] : Array Int)
""
> encode (fromList [0])
"00"
```

## `encodeUpper`

```
encodeUpper : Array Int -> String
```

Bytes → uppercase hex string.

```medaka
> encodeUpper (fromList [255, 0, 16])
"FF0010"
```

## `encodeString`

```
encodeString : String -> String
```

UTF-8 bytes of `s` → lowercase hex string.

```medaka
> encodeString "Hello"
"48656c6c6f"
```

## `decode`

```
decode : String -> Result String (Array Int)
```

Hex string → bytes.  `Err` on odd length or any non-hex-digit character
(uppercase and lowercase digits both accepted; no whitespace skipping).

```medaka
> decode "ff0010"
Ok [|255, 0, 16|]
> decode "FF0010"
Ok [|255, 0, 16|]
> decode ""
Ok [||]
> decode "f"
Err "hex.decode: odd-length input"
> decode "zz"
Err "hex.decode: invalid hex digit"
```

## `decodeString`

```
decodeString : String -> Result String String
```

Hex string → UTF-8-decoded String.

```medaka
> decodeString "48656c6c6f"
Ok "Hello"
```

