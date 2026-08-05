# `gzip/` — a DEFLATE/gzip codec in pure Medaka

**Status:** PARTIAL — Phases 1-4: foundation, fixed-Huffman inflate,
dynamic-Huffman inflate, and deflate (LZ77 + fixed-Huffman + stored
fallback). Stored, fixed-Huffman, and dynamic-Huffman blocks (`BTYPE`
00/01/10 — every block type a real-world `.gz` file uses) all decompress
for real, including this repo's own `compiler/seed/emitter.ll.gz`.
Compression now works too: `gzip/lib/deflate.mdk` emits real `.gz` files the
system `gunzip` accepts and reproduces byte-for-byte — LZ77 hash-chain
matching with lazy matching, fixed-Huffman blocks, and a stored-block
fallback that guarantees incompressible input never grows beyond a small
fixed overhead. Dynamic-Huffman *encoding* (Phase 5 — frequency counting,
block splitting) is not yet implemented, so our own output is always larger
than `gzip -6`'s (see `gzip/lib/deflate.mdk`'s module header for the ratio
this leaves on the table). Design and phasing:
[`../docs/design/GZIP-DESIGN.md`](../docs/design/GZIP-DESIGN.md).

A dogfooding project, chosen to exercise the parts of the language the SQLite
library leaves cold: sub-byte bit streams, in-place mutable arrays in a hot
loop, and property testing against an external oracle.

## What is here

| Module | What it does |
|--------|--------------|
| `lib/crc32.mdk` | CRC-32 (IEEE, reflected, `0xEDB88320`) and Adler-32 |
| `lib/bitio.mdk` | LSB-first `BitReader`/`BitWriter` — the bit cursor `byteparser` cannot provide |
| `lib/container.mdk` | RFC 1952 gzip member header and trailer, parse and emit |
| `lib/huffman.mdk` | Canonical Huffman decoding (counts-and-offsets), fixed tables, length/distance tables |
| `lib/inflate.mdk` | The DEFLATE block loop — stored (`BTYPE=00`), fixed-Huffman (`BTYPE=01`), and dynamic-Huffman (`BTYPE=10`) blocks all decode — plus the gzip member decoder (`gunzipMember`) wrapping it |
| `lib/deflate.mdk` | Phase 4: LZ77 hash-chain match finder (with lazy matching) + fixed-Huffman block encoding (`BTYPE=01`) + stored-block fallback (`BTYPE=00`) + the gzip member compressor (`gzipCompress`) wrapping it. Dynamic-Huffman encoding (`BTYPE=10`) is Phase 5, not yet implemented |
| `main.mdk` | The cross-module integration probe (see below) |
| `inflate_demo.mdk` | CLI: `inflate_demo <input.gz> <output>` — the actual decompressor, used by `gzip/test/inflate_oracle.sh` |
| `deflate_demo.mdk` | CLI: `deflate_demo <input> <output.gz>` — the actual compressor, used by `gzip/test/deflate_oracle.sh` |

## Running it

```sh
medaka test gzip/lib/crc32.mdk        # and bitio.mdk, container.mdk, huffman.mdk, inflate.mdk, deflate.mdk
medaka run  gzip/main.mdk
medaka build gzip/main.mdk -o gzip_probe && ./gzip_probe
medaka build gzip/inflate_demo.mdk -o inflate_demo && ./inflate_demo some.gz out.bin
medaka build gzip/deflate_demo.mdk -o deflate_demo && ./deflate_demo some_file out.gz
sh gzip/test/inflate_oracle.sh   # differential oracle against the system gzip/gunzip (decompress direction)
sh gzip/test/deflate_oracle.sh   # differential oracle against the system gzip/gunzip (compress direction)
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
