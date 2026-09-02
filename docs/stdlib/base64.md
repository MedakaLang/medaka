# base64

## `encode`

```
encode : Array Int -> String
```

Bytes → standard base64 string, `=`-padded.  RFC 4648 test vectors
(input is the UTF-8 bytes of the ASCII string):

```medaka
> encode (toUtf8 "")
""
> encode (toUtf8 "f")
"Zg=="
> encode (toUtf8 "fo")
"Zm8="
> encode (toUtf8 "foo")
"Zm9v"
> encode (toUtf8 "foob")
"Zm9vYg=="
> encode (toUtf8 "fooba")
"Zm9vYmE="
> encode (toUtf8 "foobar")
"Zm9vYmFy"
```

## `encodeUrlSafe`

```
encodeUrlSafe : Array Int -> String
```

Bytes → URL-and-filename-safe base64 (`-`/`_`, still `=`-padded).

```medaka
> encodeUrlSafe (fromList [255, 239, 191])
"_--_"
```

## `decode`

```
decode : String -> Result String (Array Int)
```

Standard base64 → bytes.  Strict: `Err` on bad length, invalid
character, or misplaced padding.

```medaka
> decode ""
Ok [||]
> decode "Zg=="
Ok [|102|]
> decode "Zm8="
Ok [|102, 111|]
> decode "Zm9v"
Ok [|102, 111, 111|]
> decode "Zm9vYmFy"
Ok [|102, 111, 111, 98, 97, 114|]
> decode "Zg="
Err "base64.decode: length not a multiple of 4"
> decode "Z@=="
Err "base64.decode: invalid character or padding"
```

## `decodeUrlSafe`

```
decodeUrlSafe : String -> Result String (Array Int)
```

URL-and-filename-safe base64 → bytes.

```medaka
> decodeUrlSafe "_--_"
Ok [|255, 239, 191|]
```

## `encodeString`

```
encodeString : String -> String
```

UTF-8 bytes of `s` → standard base64 string.

```medaka
> encodeString "foo"
"Zm9v"
```

## `decodeString`

```
decodeString : String -> Result String String
```

Standard base64 → UTF-8-decoded String.

```medaka
> decodeString "Zm9v"
Ok "foo"
```

