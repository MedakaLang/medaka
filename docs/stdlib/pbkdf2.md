# pbkdf2

PBKDF2-HMAC-SHA-256 (RFC 2898 §5.2), the password-hashing key
derivation function.

A password, a salt and the derived key are each an `Array Int` with every
element from `0` to `255`. The caller supplies the salt; nothing here
draws entropy, reads a clock, or performs any I/O.

## `pbkdf2HmacSha256`

```
pbkdf2HmacSha256 : Array Int -> Array Int -> Int -> Int -> Array Int
```

The `dkLen`-byte key derived from `password` and `salt` by RFC 2898's
PBKDF2 with HMAC-SHA-256.

`salt` is caller-supplied; this function never draws entropy itself.
Panics when `iterations` or `dkLen` is less than 1, and when any element
of `password` or `salt` is outside `0` to `255`.

