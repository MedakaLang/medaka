# hex

hex.mdk — hex (base16) encoding/decoding of raw bytes.

Bytes are `Array Int` (each element `0..255`), matching the convention
used by `readFileBytes`/`writeFileBytes` (stdlib/runtime.mdk) and the
`byteparser`/`bytebuilder` codecs: two hex digits per byte, most
significant nibble first.

**Decode strictness.**  `decode` rejects (`Err`) an odd-length input and
any non-hex-digit character.  Whitespace is NOT skipped — a string with
embedded spaces/newlines is an error.  Both uppercase and lowercase hex
digits are accepted on decode (mirrors `string.fromDigit`, which already
treats `'a'..'f'`/`'A'..'F'` uniformly); `encode` always produces
lowercase, `encodeUpper` uppercase.

## `encode`

```
encode : Array Int -> String
```

Bytes → lowercase hex string, two characters per byte, most-significant
nibble first.


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> encodeUpper (fromList [255, 0, 16])
"FF0010"
```

## `encodeString`

```
encodeString : String -> String
```

UTF-8 bytes of `s` → lowercase hex string.


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> decodeString "48656c6c6f"
Ok "Hello"
```

