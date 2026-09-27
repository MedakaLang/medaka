# base64

Base64 encoding and decoding, per RFC 4648.

`encode` and `decode` use the standard alphabet with `=` padding;
`encodeUrlSafe` and `decodeUrlSafe` use the URL and filename safe
alphabet, with `-` and `_` in place of `+` and `/`, still padded.

Decoding is strict: the length must be a multiple of four, only the
alphabet and trailing padding are accepted, and whitespace is not
skipped.

## Encoding

### `encode`

```
encode : Bytes -> String
encode bs
```

The bytes as standard base64, padded with `=`.

```medaka
> encode (encodeUtf8 "foobar")
"Zm9vYmFy"
> encode (encodeUtf8 "fo")
"Zm8="
```

### `encodeUrlSafe`

```
encodeUrlSafe : Bytes -> String
encodeUrlSafe bs
```

The bytes as URL and filename safe base64, padded with `=`.

```medaka
> encodeUrlSafe (fromU8Array [|255, 239, 191|])
"_--_"
```

### `encodeString`

```
encodeString : String -> String
encodeString s
```

The UTF-8 bytes of a string as standard base64.

```medaka
> encodeString "foo"
"Zm9v"
```

## Decoding

### `decode`

```
decode : String -> Result String Bytes
decode s
```

The bytes written in standard base64, as a `Bytes`.

`Err` when the length is not a multiple of four, a character is outside
the alphabet, or padding appears anywhere but the end.

```medaka
> map toArray (decode "Zm9vYmFy")
Ok [|102, 111, 111, 98, 97, 114|]
> decode "Zg="
Err "base64.decode: length not a multiple of 4"
```

### `decodeUrlSafe`

```
decodeUrlSafe : String -> Result String Bytes
decodeUrlSafe s
```

The bytes written in URL and filename safe base64, as a `Bytes`.

```medaka
> map toArray (decodeUrlSafe "_--_")
Ok [|255, 239, 191|]
```

### `decodeString`

```
decodeString : String -> Result String String
decodeString s
```

The string whose UTF-8 bytes are written in standard base64.

```medaka
> decodeString "Zm9v"
Ok "foo"
```

