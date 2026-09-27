# crypto.sha256

SHA-256 hashing of a byte string (FIPS 180-4).

A message is `Bytes` and so is the digest, 32 bytes, most significant byte
of each word first.

There is no incremental form. A message is hashed in one call.

## `sha256AssumeByteDomainFrom`

```
sha256AssumeByteDomainFrom : (U32, U32, U32, U32, U32, U32, U32, U32) -> Int -> Bytes -> Bytes
sha256AssumeByteDomainFrom priorState priorBytes msg
```

## `sha256FoldKeyBlock`

```
sha256FoldKeyBlock : Bytes -> (U32, U32, U32, U32, U32, U32, U32, U32)
sha256FoldKeyBlock block
```

## `sha256`

```
sha256 : Bytes -> Bytes
sha256 msg
```

The 32-byte SHA-256 digest of `msg`.

