# hmac

HMAC-SHA-256 (RFC 2104) over byte arrays.

A key and a message are each an `Array Int` with every element from `0` to
`255`, and the result is the 32-byte authentication tag. The key may be any
length. A key longer than the 64-byte block is hashed down to its digest
first, and a shorter one is padded with zero bytes on the right.

`hmacSha256` panics when any element of the key or the message is outside
`0` to `255`. `hmacSha256FixedBytes` is the same tag without that check,
for a caller whose bytes are already known to be in range.

## `ctEq`

```
ctEq : Array Int -> Array Int -> Bool
ctEq a b
```

Whether two byte arrays contain the same values.

Unequal lengths return `False`. Equal-length inputs visit every byte
position without returning early based on the contents.

```medaka
> ctEq [|0x48, 0x69|] [|0x48, 0x69|]
True
```

## `hmacSha256`

```
hmacSha256 : Array Int -> Array Int -> Array Int
hmacSha256 key message
```

The 32-byte HMAC-SHA-256 tag of `message` under `key`.

`key` may be any length, including empty. Panics when any element of
either argument is outside `0` to `255`.

## `hmacSha256FixedBytes`

```
hmacSha256FixedBytes : Array Int -> Array Int -> Array Int
hmacSha256FixedBytes key message
```

The 32-byte HMAC-SHA-256 tag of `message` under `key`, without checking
the byte domain.

Every element of `key` and `message` must be in `0` to `255`. An element
outside that range is not detected and yields the tag of some other
input. Use `hmacSha256` unless the bytes are already known to be in
range.

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

Byte-for-byte the same tag `hmacSha256`/`hmacSha256FixedBytes` give for
the same key and message.

