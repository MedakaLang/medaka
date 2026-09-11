# hmac

HMAC-SHA-256 (RFC 2104) over byte arrays.

A key and a message are each an `Array Int` with every element from `0` to
`255`, and the result is the 32-byte authentication tag. The key may be any
length: RFC 2104's schedule hashes a key longer than the 64-byte block down
to its digest first, and pads a shorter one with zero bytes on the right.

`hmacSha256` panics when any element of the key or the message is outside
`0` to `255`. `hmacSha256FixedBytes` is the same tag without that check,
for a caller whose bytes are already known to be in range.

## `hmacSha256`

```
hmacSha256 : Array Int -> Array Int -> Array Int
```

The 32-byte HMAC-SHA-256 tag of `message` under `key`.

`key` may be any length, including empty. Panics when any element of
either argument is outside `0` to `255`.

## `hmacSha256FixedBytes`

```
hmacSha256FixedBytes : Array Int -> Array Int -> Array Int
```

The 32-byte HMAC-SHA-256 tag of `message` under `key`, skipping the
byte-domain check.

Every element of `key` and `message` must still be in `0` to `255`.
Nothing here checks that, and an element outside the range silently
authenticates some other input. Prefer `hmacSha256` unless the bytes come
from a source that already guarantees the range.

