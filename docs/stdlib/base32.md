# base32

Base32 encoding and decoding, per RFC 4648.

`base32Encode` uses the lowercase alphabet and never emits `=` padding.
`base32Decode` accepts exactly that canonical form: uppercase, `=`
padding, non-alphabet characters, non-zero residual bits, and
non-canonical lengths are rejected rather than normalized.

Under the interpreter (`medaka run`, `medaka test`), both overflow the
stack on inputs of more than a few kilobytes. Native builds have no such
limit.

## `base32Encode`

```
base32Encode : Bytes -> String
base32Encode bs
```

The bytes as lowercase, unpadded base32.

```medaka
> base32Encode (fromU8Array [|102, 111, 111|])
"mzxw6"
```

## `base32Decode`

```
base32Decode : String -> Result String Bytes
base32Decode text
```

The bytes written in canonical (lowercase, unpadded) base32, as a
`Bytes`.

`Err` when the input carries padding, an uppercase letter, a character
outside the alphabet, non-zero trailing bits, or a length that no byte
sequence encodes to.

```medaka
> map toArray (base32Decode "mzxw6")
Ok [|102, 111, 111|]
> base32Decode "MZXW6"
Err "base32: uppercase is not canonical"
```

