# pbkdf2

PBKDF2 key derivation with HMAC-SHA-256 (RFC 2898).

A password, a salt and the derived key are each an `Array Int` with every
element from `0` to `255`. The caller supplies the salt. Nothing here
draws entropy or performs any I/O.

## `pbkdf2HmacSha256`

```
pbkdf2HmacSha256 : Array Int -> Array Int -> Int -> Int -> Array Int
```

The `dkLen`-byte key derived from `password` and `salt` over
`iterations` rounds.

Panics when `iterations` or `dkLen` is less than 1, and when any element
of `password` or `salt` is outside `0` to `255`.

