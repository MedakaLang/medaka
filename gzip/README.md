# `gzip/` — a DEFLATE/gzip codec in pure Medaka

**Status:** PARTIAL — Phase 1 (foundation) only. No inflater yet, so this cannot
decompress anything. Design and phasing: [`../docs/design/GZIP-DESIGN.md`](../docs/design/GZIP-DESIGN.md).

A dogfooding project, chosen to exercise the parts of the language the SQLite
library leaves cold: sub-byte bit streams, in-place mutable arrays in a hot
loop, and property testing against an external oracle.

## What is here

| Module | What it does |
|--------|--------------|
| `lib/crc32.mdk` | CRC-32 (IEEE, reflected, `0xEDB88320`) and Adler-32 |
| `lib/bitio.mdk` | LSB-first `BitReader`/`BitWriter` — the bit cursor `byteparser` cannot provide |
| `lib/container.mdk` | RFC 1952 gzip member header and trailer, parse and emit |
| `main.mdk` | The cross-module integration probe (see below) |

## Running it

```sh
medaka test gzip/lib/crc32.mdk        # and bitio.mdk, container.mdk
medaka run  gzip/main.mdk
medaka build gzip/main.mdk -o gzip_probe && ./gzip_probe
```

Both engines must agree. An interpreter-green result proves nothing about the
compiled path — that is not a slogan here, it is why `main.mdk` exists.

## Why `main.mdk` is not a CLI

Every module's own suite is green in isolation, and that proves nothing about
whether they **compose**. A record exported with `export` rather than
`public export` is abstract to every other module: its fields are inaccessible
from outside, and no same-module test can ever see that. `main.mdk` reads a
real `printf 'hello' | gzip -n` byte stream through all three modules at once,
so that class of failure is loud.

It checks two facts against an independent oracle rather than against itself:

- the trailer's CRC-32 equals our own `crc32` of the decompressed bytes
  (`python3 -c "import zlib; print(zlib.crc32(b'hello'))"` → `907060870`);
- the trailer's ISIZE equals the real length.

It also reads the first DEFLATE block header off the payload with the bit
cursor, which reports `BFINAL=1 BTYPE=1 (fixed Huffman)` — what `gzip` really
emits for an input this small.

## Testing policy

`test` and `prop` declarations are the primary coverage; doctests are
illustration only. Every expected value is derived from an **external** source
(Python's `zlib`, or bytes captured from the system `gzip`) or from a
hand-derived bit pattern stated in the test's own comment.

**No golden is ever captured from this library's own output.** A captured
golden records what the code did, not what is correct, and would enshrine a bug
as the expected answer. Where a property is used, it must be able to fail: a
round-trip that restates a definition is not a test, and one such property was
caught and replaced with an independent bit-serial CRC reference during Phase 1.
