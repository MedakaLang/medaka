# crypto.sha256_fast

SHA-256 of non-secret data, computed in the runtime.

`sha256Fast` returns the same 32-byte digest as `crypto.sha256.sha256`.
The runtime kernel makes no constant-time promise, so code that hashes
secret material (HMAC, signing) uses `crypto.sha256.sha256`, the audited
Medaka implementation, and never this module.

## `sha256Fast`

```
sha256Fast : Bytes -> Bytes
sha256Fast msg
```

The 32-byte SHA-256 digest of `msg`, computed natively.

