# crypto.sha256

SHA-256 hashing of a byte array (FIPS 180-4).

A message is an `Array Int` with each element from `0` to `255`, the same
form `readFileBytes` and `hex.decode` use. The digest is 32 bytes, most
significant byte of each word first.

`sha256` panics when any element is outside `0` to `255`. `sha256FixedBytes`
is the same hash without that check, for a caller whose bytes are already
known to be in range.

There is no incremental form. A message is hashed in one call.

Under the interpreter (`medaka run`, `medaka test`), `sha256` overflows the
stack on a message longer than about 25 kilobytes. `sha256FixedBytes` and
native builds hash messages of a megabyte and more.

## `sha256AssumeByteDomainFrom`

```
sha256AssumeByteDomainFrom : (Int, Int, Int, Int, Int, Int, Int, Int) -> Int -> Array Int -> Array Int
sha256AssumeByteDomainFrom priorState priorBytes msg
```

## `sha256FoldKeyBlock`

```
sha256FoldKeyBlock : Array Int -> (Int, Int, Int, Int, Int, Int, Int, Int)
sha256FoldKeyBlock block
```

## `sha256FixedBytes`

```
sha256FixedBytes : Array Int -> Array Int
sha256FixedBytes msg
```

The 32-byte SHA-256 digest of `msg`, without checking the byte domain.

Every element of `msg` must be in `0` to `255`. An element outside that
range is not detected and yields the digest of some other message. Use
`sha256` unless the bytes are already known to be in range.

## `sha256`

```
sha256 : Array Int -> Array Int
sha256 msg
```

The 32-byte SHA-256 digest of `msg`.

Panics when any element of `msg` is outside `0` to `255`.

