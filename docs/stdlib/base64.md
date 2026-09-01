# base64

base64.mdk — RFC 4648 base64 encoding/decoding of raw bytes.

Bytes are `Array Int` (each element `0..255`), the same convention used by
`readFileBytes`/`writeFileBytes` (stdlib/runtime.mdk) and the
`byteparser`/`bytebuilder` codecs.

**Decode strictness.**  `decode` is strict, matching Python's `b64decode`
default: the input length must be a multiple of 4, only the standard
alphabet (`A-Z a-z 0-9 + /`) plus `=` padding is accepted, padding may only
appear in the final 4-character group (as `""`, `"X=="`, or `"XX="`... i.e.
0, 1, or 2 trailing `=`), and any other arrangement (bad char, misplaced
`=`, wrong length) is `Err`.  Whitespace is NOT skipped — embedded
whitespace is an error, it must be stripped by the caller first.

`encodeUrlSafe`/`decodeUrlSafe` are the RFC 4648 §5 URL-and-filename-safe
variant (`-`/`_` in place of `+`/`/`); padding is still emitted/required,
for symmetry with the standard variant above.

## `encode`

```
encode : Array Int -> String
```

Bytes → standard base64 string, `=`-padded.  RFC 4648 test vectors
(input is the UTF-8 bytes of the ASCII string):


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> decodeUrlSafe "_--_"
Ok [|255, 239, 191|]
```

## `encodeString`

```
encodeString : String -> String
```

UTF-8 bytes of `s` → standard base64 string.


*(doctest — run by `medaka test`)*

```medaka
> encodeString "foo"
"Zm9v"
```

## `decodeString`

```
decodeString : String -> Result String String
```

Standard base64 → UTF-8-decoded String.


*(doctest — run by `medaka test`)*

```medaka
> decodeString "Zm9v"
Ok "foo"
```

