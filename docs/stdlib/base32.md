# base32

Base32 encoding and decoding of bytes, per RFC 4648.

Bytes are an `Array Int` with each element from `0` to `255`. `base32Encode`
uses the lowercase alphabet and never emits `=` padding. `base32Decode`
accepts exactly that canonical form: uppercase, `=` padding, non-alphabet
characters, non-zero residual bits, and non-canonical lengths are rejected
rather than normalized.

Under the interpreter (`medaka run`, `medaka test`), both overflow the
stack on inputs of more than a few kilobytes. Native builds have no such
limit.

## `base32Encode`

```
base32Encode : Array Int -> String
```

The bytes as lowercase, unpadded base32.

Panics when an element of `bytes` is outside `0` to `255`.

```medaka
> base32Encode [|102, 111, 111|]
"mzxw6"
```

## `base32Decode`

```
base32Decode : String -> Result String (Array Int)
```

The bytes written in canonical (lowercase, unpadded) base32.

`Err` when the input carries padding, an uppercase letter, a character
outside the alphabet, non-zero trailing bits, or a length that no byte
sequence encodes to.

```medaka
> base32Decode "mzxw6"
Ok [|102, 111, 111|]
> base32Decode "MZXW6"
Err "base32: uppercase is not canonical"
```

