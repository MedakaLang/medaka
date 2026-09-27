# crypto.hmac

HMAC-SHA-256 (RFC 2104) over byte strings.

A key and a message are each `Bytes`, and the result is the 32-byte
authentication tag. The key may be any length. A key longer than the
64-byte block is hashed down to its digest first, and a shorter one is
padded with zero bytes on the right.

```medaka
> hmacSha256 (encodeUtf8 "key") (encodeUtf8 "The quick brown fox jumps over the lazy dog") == fromU8Array [|0xf7, 0xbc, 0x83, 0xf4, 0x30, 0x53, 0x84, 0x24, 0xb1, 0x32, 0x98, 0xe6, 0xaa, 0x6f, 0xb1, 0x43, 0xef, 0x4d, 0x59, 0xa1, 0x49, 0x46, 0x17, 0x59, 0x97, 0x47, 0x9d, 0xbc, 0x2d, 0x1a, 0x3c, 0xd8|]
True
```

## `ctEq`

```
ctEq : Bytes -> Bytes -> Bool
ctEq a b
```

Whether two byte strings contain the same bytes.

Unequal lengths return `False`. Equal-length inputs visit every byte
position without returning early based on the contents.

```medaka
> ctEq (encodeUtf8 "Hi") (encodeUtf8 "Hi")
True
```

## `hmacSha256`

```
hmacSha256 : Bytes -> Bytes -> Bytes
hmacSha256 key message
```

The 32-byte HMAC-SHA-256 tag of `message` under `key`.

`key` may be any length, including empty.

## `HmacSha256Key`

```
data HmacSha256Key  -- abstract: the constructors are not exported
```

An HMAC-SHA-256 key with both padded blocks' compressions already
folded in.

Build one with `hmacSha256Key` and compute tags with
`hmacSha256WithKey`. Worth it for a caller that computes many tags
under the same key, such as PBKDF2's per-iteration folding: each
`hmacSha256WithKey` call then costs only the message-dependent tail of
the inner and outer hash, two SHA-256 compressions for a message that
fits in the tag's own 32 bytes, instead of `hmacSha256`'s four.

## `hmacSha256Key`

```
hmacSha256Key : Bytes -> HmacSha256Key
hmacSha256Key key
```

Precomputes the ipad/opad compressions for `key`, once.

## `hmacSha256WithKey`

```
hmacSha256WithKey : HmacSha256Key -> Bytes -> Bytes
hmacSha256WithKey _ message
```

The 32-byte HMAC-SHA-256 tag of `message` under `key`.

Byte-for-byte the same tag `hmacSha256` gives for the same key and
message.

