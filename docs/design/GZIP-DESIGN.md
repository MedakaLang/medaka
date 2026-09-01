# DEFLATE / gzip — a compression codec in pure Medaka

**Status:** PARTIAL — Phases 1-4 shipped (`gzip/`): stored + fixed-Huffman +
dynamic-Huffman inflate (real round-trip decompression of any `.gz` whose
blocks are BTYPE 00/01/10 — i.e. every real-world DEFLATE block type), plus
deflate — LZ77 hash-chain match finding (with lazy matching) + fixed-Huffman
block encoding + stored-block fallback, real compression the system
`gunzip` accepts and reproduces byte-for-byte. Dynamic-Huffman *encoding*
(Phase 5) is not yet implemented, so our own output is always somewhat
larger than `gzip -6`'s. A dogfood capstone chosen to exercise the parts of
the language and
stdlib that the SQLite library (`archive/design/SQLITE-DESIGN.md`, as-built in
`sqlite/`) leaves cold: sub-byte bit streams, in-place mutable arrays in a hot
loop, and round-trip property testing against an external oracle. The phasing
table below is the plan of record.

---

## Goal & scope (locked decisions)

Build a **pure-Medaka DEFLATE codec** — decompressor and compressor — plus the
`gzip` and `zlib` container formats wrapped around it. No C FFI, no bindings.

**Locked:**

- **Pure Medaka.** The only primitives used are ones that already exist:
  `bitAnd`/`bitOr`/`bitXor`/`shiftLeft`/`shiftRight` (`stdlib/runtime.mdk`),
  `readFileBytes`/`writeFileBytes`, and `Array Int`. **No new extern is
  required** — see "Foundation" below. That is deliberate: a new prelude extern
  forces a seed re-mint and can hard-crash the fixpoint, and this project does
  not need one.
- **Synchronous, whole-buffer.** Input is slurped to one `Array Int`; output is
  built into one `Array Int`. No streaming/incremental API in v1, and therefore
  no Async — which is not ready for use.
- **Decompress first.** Inflate is the load-bearing half (every `.gz` in the
  wild must decode) and is far easier to make correct. Deflate follows.
- **RFC-conformant, not byte-identical to zlib.** A compressor is correct if
  the system `gunzip` accepts its output and reproduces the input exactly.
  Matching zlib's *exact* bit stream is an explicit non-goal — that is a
  heuristics-tuning exercise with no correctness content.
- **Differential oracle: the system `gzip`/`gunzip` CLI**, in both directions,
  exactly mirroring the `sqlite3`-CLI discipline of the SQLite library.

**Out of scope (v1):** streaming/chunked APIs, zlib-compatible output bits,
DEFLATE64, Zopfli-grade optimal parsing, dictionary presets
(`FDICT`), multi-member `.gz` concatenation beyond a simple loop, and
`.zip` archive containers (a natural follow-on, not this doc).

---

## Why this project (what it exercises that SQLite does not)

The SQLite library is ~10.7k lines of big-endian, byte-aligned, read-mostly,
immutable-data decoding driven by a recursive-descent parser. It is a good
workout for ADTs, pattern matching, and `stdlib/byteparser.mdk`. It leaves whole
regions of the language untested.

| Dimension | `sqlite/` | This project |
|-----------|-----------|--------------|
| Bit granularity | Byte-aligned, big-endian | **LSB-first bit stream**; Huffman codes packed MSB-of-code-first inside it. Two opposite bit orders in one format |
| Data mutation | Immutable; `Array Int` read-only | **In-place `Array Int` / `Vector Int`** — a 32 KB sliding window with *overlapping* back-references (the `distance < length` case is the whole trick) |
| Hot loops | Allocation-heavy, not perf-sensitive | Genuinely hot inner loops. Gives `test/diff_compiler_perf_scaling.sh` and the emitter a real **non-compiler** workload, which the tree currently has none of |
| Numeric surface | Varints, big-endian ints | 32-bit masked arithmetic (CRC-32, Adler-32) on a 63-bit `Int`; `shiftRight` is **logical**, which is what CRC needs |
| Testing style | Fixed corpus + golden diffs | **Round-trip properties** (`inflate (deflate x) == x`) over generated inputs — an unbounded oracle, not a fixed corpus |
| Failure mode | Wrong rows | Wrong *bytes*, which is a much sharper signal: any divergence is a hard mismatch, no "close enough" |

The two-opposite-bit-orders point is worth calling out. DEFLATE packs the bit
stream least-significant-bit-first within each byte, but Huffman codes are
transmitted most-significant-bit-of-the-code first, and the extra-bits fields
after length/distance codes are LSB-first again. Every implementation of this
format gets it wrong once. That makes it an unusually good test of whether the
language's bit primitives compose without surprises across engines.

---

## Foundation — what already exists

Nothing needs to be added to the runtime. Verified against the current tree:

| Need | Provided by | Notes |
|------|-------------|-------|
| Bitwise ops | `bitAnd`, `bitOr`, `bitXor`, `shiftLeft`, `shiftRight`, `bitNot` (`stdlib/runtime.mdk`) | `shiftRight` is **logical** (unsigned), documented as such at its declaration — correct for CRC and for bit extraction |
| Binary file read | `readFileBytes : String -> <FileRead "_"> Result String (Array Int)` | The byte-clean read; `readFile` UTF-8-decodes and would corrupt any byte ≥ 0x80 |
| Binary file write | `writeFileBytes : String -> Array Int -> <FileWrite "_"> Result String Unit` | The byte-clean counterpart. The SQLite project's write path already leans on it |
| Growable output | `stdlib/vector.mdk` — `push`, `set`, `get`, `toArray`, amortized O(1) | The natural output accumulator |
| Fixed buffers | `stdlib/array.mdk` — `make`, `set`, `blit`, `fill`, `copy` | The window and the Huffman decode tables. `blit` handles non-overlapping copies; overlapping LZ77 copies must be byte-at-a-time by definition |
| Byte-level framing | `stdlib/byteparser.mdk` (`leUint`, `takeSlice`, `runByteParser`) and `stdlib/bytebuilder.mdk` (`emitU8`, `emitU32LE`, `buildArray`) | Used for the **container** layers only — gzip/zlib headers and trailers are byte-aligned. The DEFLATE payload needs its own bit reader (below) |

### The one new abstraction: `BitReader` / `BitWriter`

`stdlib/byteparser.mdk` is byte-granular by construction — the position it
threads through every combinator is a byte index. DEFLATE needs a bit cursor.
This is a genuinely new module, not a variant of an existing one. Note also that
byteparser threads that position **explicitly and functionally** (its own header:
*"Position threading is EXPLICIT — there is no hidden state monad"*), whereas the
`BitReader` below is deliberately `Ref`-based — so this is a different design, not
a re-parameterization of the same one:

```
-- LSB-first bit reader over an immutable byte array.
-- `hold` accumulates up to 63 bits; `count` is how many are valid.
data BitReader = BitReader
  { src   : Array Int
  , pos   : Ref Int    -- next byte index to refill from
  , hold  : Ref Int    -- bit accumulator, LSB-first
  , count : Ref Int    -- valid bits in `hold`
  }

needBits : Int -> BitReader -> Result String Unit   -- refill until count >= n
getBits  : Int -> BitReader -> Result String Int    -- consume n bits, LSB-first
alignByte : BitReader -> Unit                       -- discard to byte boundary (stored blocks)
```

It lives in `gzip/lib/bitio.mdk` for v1. If it proves out, graduating it to
`stdlib/` is the same path `byteparser` itself took (its own project first, the
stdlib second) — but that is a later decision, not a v1 commitment.

Note the `Ref`-based state rather than a threaded functional cursor. That is
deliberate and it is one of the things this project is testing: the bit reader
is called once per Huffman symbol, so a functional cursor allocating a tuple per
bit-read would dominate the profile. Whether the emitter makes the `Ref` version
actually fast is an open question this project will answer.

---

## Phasing

| Phase | What ships | Oracle |
|-------|-----------|--------|
| **1** | `BitReader` + **stored (uncompressed) blocks** + gzip container parse/emit + CRC-32 | incompressible input (`/dev/urandom`) at any level emits a stored block — see below; `printf` \| `gzip` round-trip |
| **2** | **Inflate, fixed Huffman** — the RFC 1951 static code tables, length/distance decoding, sliding window | `gzip -1`..`-9` (SHIPPED — see `gzip/test/inflate_oracle.sh`). ⚠️ You do not get to choose BTYPE; see "When gzip actually emits fixed Huffman" below. The oracle asserts the BTYPE it observed rather than assuming one |
| **3** | **Inflate, dynamic Huffman** — code-length alphabet, HLIT/HDIST/HCLEN, canonical code construction (SHIPPED) | Real `.gz` corpus, including this repo's own `compiler/seed/emitter.ll.gz` — see `gzip/test/inflate_oracle.sh` |
| **4** | **Deflate** — LZ77 hash-chain matcher + fixed-Huffman blocks + stored-block fallback (SHIPPED) | `gunzip` accepts our output and reproduces the input — see `gzip/test/deflate_oracle.sh` |
| **5** | **Deflate, dynamic Huffman** — frequency counting, length-limited code construction, block-splitting heuristic | Compression ratio vs `gzip -6` on a fixed corpus (reported, not gated) |
| **6** | zlib container (RFC 1950) + Adler-32 | `python3 -c "import zlib"` round-trip |

Phases 1–4 are the ones with real-world value on their own; a compressor
without dynamic Huffman is still a useful library, just not a
ratio-competitive one. Phase 5 is what closes that gap; Phase 6 is a
sibling container format.

---

## The format

Sources: [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951) (DEFLATE),
[RFC 1952](https://www.rfc-editor.org/rfc/rfc1952) (gzip),
[RFC 1950](https://www.rfc-editor.org/rfc/rfc1950) (zlib).

### 1. gzip member header

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0 | 2 | Magic | `0x1F 0x8B` |
| 2 | 1 | CM | Compression method; **8** = deflate, anything else is an error |
| 3 | 1 | FLG | Bit 0 `FTEXT`, 1 `FHCRC`, 2 `FEXTRA`, 3 `FNAME`, 4 `FCOMMENT` |
| 4 | 4 | MTIME | Little-endian uint32, seconds since epoch; 0 = unavailable |
| 8 | 1 | XFL | Compressor hint; ignored on read |
| 9 | 1 | OS | Source filesystem; ignored on read |

Then, conditionally in this order: `FEXTRA` → 2-byte LE length + that many
bytes; `FNAME` → NUL-terminated name; `FCOMMENT` → NUL-terminated comment;
`FHCRC` → 2-byte LE low half of the CRC-32 of the header so far. Then the
DEFLATE stream. Then the trailer:

| Size | Field |
|------|-------|
| 4 | CRC-32 of the *uncompressed* data, little-endian |
| 4 | ISIZE — uncompressed length mod 2³², little-endian |

Both trailer fields are checked on inflate; a mismatch is an `Err`, never a
warning. The whole point of a checksum is that it is loud.

```
data GzipHeader = GzipHeader
  { mtime   : Int
  , name    : Option String
  , comment : Option String
  , os      : Int
  }
```

### 2. DEFLATE block structure

The payload is a sequence of blocks. Each begins with three bits:

```
BFINAL : 1 bit   -- 1 = last block in the stream
BTYPE  : 2 bits  -- 00 stored, 01 fixed Huffman, 10 dynamic Huffman, 11 error
```

Blocks are **not** byte-aligned relative to each other except for stored blocks,
which pad to the next byte boundary before their length header.

```
data BlockType = Stored | FixedHuffman | DynamicHuffman
```

#### Stored block (BTYPE 00)

Align to byte, then `LEN` (2 bytes LE) and `NLEN` (2 bytes LE, the one's
complement of `LEN` — validate it), then `LEN` raw bytes copied verbatim to the
output *and into the sliding window* (a stored block can be referenced by a
later block's back-references; forgetting this is a classic bug).

⚠️ **There is no `gzip -0`** — GNU gzip 1.13 rejects it (`invalid option -- '0'`);
the levels are `-1`..`-9`. To get a stored block from the system tool, feed it
**incompressible** input: gzip falls back to BTYPE 00 when compressing would
expand the data. Verified:

```
$ head -c 200 /dev/urandom > rand.bin && gzip -1 -n -c rand.bin | xxd -s 10 -l 6
0000000a: 01c8 0037 ff                             ...7.
```

`0x01` is `BFINAL=1, BTYPE=00`; `LEN=0x00c8`=200 and `NLEN=0xff37` is its exact
one's complement. That is the Phase 1 oracle, and it is a better one than a
hypothetical `-0` anyway: it is the shape a real decompressor must handle.

#### When gzip actually emits fixed Huffman

You cannot ask for a block type — `gzip`'s block-splitting heuristic decides,
and **the deciding factor is symbol diversity, not size.** An earlier draft of
this doc said fixed Huffman held "past roughly 2-4 KB of non-random input at
any level". That is true only of the *highly repetitive* corpus the figure was
measured on, and badly wrong for realistic content. Measured at `-1`
(`1` = fixed, `2` = dynamic):

| content | 50 B | 100 B | 200 B | 500 B | 1 KB | 2 KB | 4 KB |
|---|---|---|---|---|---|---|---|
| one repeated byte | 1 | 1 | 1 | 1 | 1 | 1 | 2 |
| a repeated phrase | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| **english-like prose** | 1 | 1 | **2** | 2 | 2 | 2 | 2 |
| **source code** | 1 | **2** | 2 | 2 | 2 | 2 | 2 |

So prose tips at ~200 bytes and source at ~100, while a repeated phrase stays
fixed at 4 KB. The intuition to carry is that a *literal-diverse* input makes a
custom code table pay for itself almost immediately, whereas a low-entropy one
never does.

Consequence for testing: **assert the BTYPE you actually got.** A gate that
assumes fixed Huffman from a size threshold silently tests nothing the moment
the heuristic disagrees. Re-derive rather than trusting this table:

```sh
gzip -1 -n -c FILE | python3 -c "
import sys; d=sys.stdin.buffer.read(); flg=d[3]; off=10
if flg&4: off += 2 + (d[off]|(d[off+1]<<8))
if flg&8:
    while d[off]: off+=1
    off+=1
if flg&16:
    while d[off]: off+=1
    off+=1
if flg&2: off+=2
print((d[off]>>1)&3)"
```

⚠️ That header walk matters: a `.gz` carrying `FNAME` puts the first DEFLATE
block well past byte 10 (`compiler/seed/emitter.ll.gz` starts at 18), so a
fixed-offset read misidentifies its BTYPE.

#### Fixed Huffman (BTYPE 01)

The literal/length code lengths are fixed by the RFC:

| Symbol range | Code length |
|--------------|-------------|
| 0–143 | 8 |
| 144–255 | 9 |
| 256–279 | 7 |
| 280–287 | 8 |

Distance codes are a flat 5-bit code, 0–29 (30 and 31 are invalid). Build the
same canonical tables Phase 3 builds — do not special-case the decoder. Feeding
these fixed lengths through the general canonical-code builder means Phase 2 and
Phase 3 share one decoder, and Phase 2 becomes a test of the builder.

#### Dynamic Huffman (BTYPE 10)

```
HLIT  : 5 bits  -- number of literal/length codes  - 257
HDIST : 5 bits  -- number of distance codes        - 1
HCLEN : 4 bits  -- number of code-length codes     - 4
```

Then `HCLEN + 4` three-bit code lengths, transmitted in this permuted order:

```
16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
```

That permuted table is a constant `Array Int`. From those, build the
code-length Huffman code, then use it to decode `HLIT + 257 + HDIST + 1` code
lengths for the two real alphabets, where symbols 16/17/18 are run-length
escapes: 16 = repeat previous length 3–6 times (2 extra bits), 17 = repeat zero
3–10 times (3 extra bits), 18 = repeat zero 11–138 times (7 extra bits). A
symbol-16 run at the very start of the stream (no previous length) is a
malformed stream, not a zero run.

### 3. Length and distance codes

Literal/length symbol 256 ends the block. Symbols 257–285 are lengths:

| Symbol | Extra bits | Base length |
|--------|-----------|-------------|
| 257–264 | 0 | 3–10 |
| 265–268 | 1 | 11, 13, 15, 17 |
| 269–272 | 2 | 19, 23, 27, 31 |
| 273–276 | 3 | 35, 43, 51, 59 |
| 277–280 | 4 | 67, 83, 99, 115 |
| 281–284 | 5 | 131, 163, 195, 227 |
| 285 | 0 | 258 |

Distance symbols 0–29 follow the same shape: bases 1, 2, 3, 4, then pairs with
1, 2, 3, … extra bits up to 13, reaching a maximum distance of 32768. Both are
best expressed as two parallel constant `Array Int` (base, extra-bits) indexed
by symbol — flat arrays, not a `Map`, because this is the hot path.

Encode both tables **once**, as data, and derive the encoder's inverse mapping
from the same arrays at startup rather than writing a second hand-typed table.
A hand-copied second table is exactly the kind of thing that is wrong in one
cell and passes every test but one.

### 4. The sliding window and the overlap case

Output is a `Vector Int` that *is* the window — no separate 32 KB ring buffer.
A back-reference `(length, distance)` copies from `outLen - distance` forward:

```
copyBack : Int -> Int -> Vector Int -> Result String Unit
-- for i in 0..length-1:  push (get (outLen - distance + i)) out
```

Read-then-push, one byte at a time, **in that order**. When
`distance < length` the source region overlaps the destination and the bytes
being copied include bytes this very loop is producing — `distance = 1` is the
run-length encoding of a repeated byte, and it is extremely common. A `blit`
here would be wrong; so would any implementation that snapshots the source
slice first. This is the single most-often-broken line in any inflate.

A `distance > outLen` reference is a malformed stream (`Err`), not a wrap-around.

### 5. Canonical Huffman decoding

Given code lengths per symbol, canonical construction assigns codes in
increasing length, and within a length in increasing symbol order. The decoder
does **not** walk a tree node-per-bit; it uses the counts-and-offsets method:

```
data Huffman = Huffman
  { counts  : Array Int   -- counts[len] = number of codes of that length, len 0..15
  , symbols : Array Int   -- symbols sorted by (length, symbol)
  }

buildHuffman : Array Int -> Result String Huffman
decodeSym    : Huffman -> BitReader -> Result String Int
```

`decodeSym` reads one bit at a time, maintaining `code`, `first`, and `index`
per length — at most 15 iterations, no allocation, no tree nodes. It is ~15
lines and it is the whole decoder. A table-driven multi-bit-at-a-time decoder is
faster and is a Phase 5+ optimization; do not start there.

Validation: an **over-subscribed** code (Kraft sum > 1) is an error; an
**incomplete** code is an error too, with one RFC-sanctioned exception — a
distance alphabet with a single used code is legal in streams produced by some
encoders and must be accepted.

### 6. CRC-32

The gzip CRC is the standard IEEE polynomial, reflected, `0xEDB88320`, with
initial and final inversion. On a 63-bit `Int` the only discipline required is
masking to `0xFFFFFFFF` after every shift, and `shiftRight` being logical means
no sign-bit contamination.

```
crc32 : Array Int -> Int
crc32Update : Int -> Int -> Int   -- running crc, byte -> new crc
```

Build the 256-entry table once into an `Array Int` at module level. This is
also the first real test in this tree of a **lazily-initialized top-level
table** in a hot path.

Adler-32 (zlib, Phase 6) is simpler, with one trap: two running sums mod 65521,
where **`s1` initializes to 1 and `s2` to 0 — not both zero.** Carrying over
CRC-32's start-at-zero mental model produces a checksum that is wrong for every
input, including the empty one, whose correct Adler-32 is `0x00000001` (verified:
`python3 -c "import zlib; print(zlib.adler32(b''))"` → `1`). This is the one
place in this document where a reader who codes straight from the prose and
nothing else gets a working-looking implementation that is wrong everywhere.

---

## Compression (Phases 4–5)

### LZ77 match finding

A three-byte rolling hash into a chain table, the classic zlib arrangement, all
in flat `Array Int`:

```
head  : Array Int   -- hashSize entries; most recent position with this hash, or -1
prev  : Array Int   -- windowSize entries; prev[p] = previous position with p's hash
```

At each input position: hash the next three bytes, walk the chain backwards up
to `maxChainLength` links, keep the longest match within 32768 bytes and at
least 3 long. `maxChainLength` is the compression-level knob and the only
tuning parameter v1 exposes.

**Lazy matching** (defer emitting a match if the *next* position has a strictly
longer one) is a real ratio win for a few lines and should land in Phase 4, not
be deferred.

This is the part of the project with no counterpart anywhere in the tree: two
mutable index arrays, no allocation in the inner loop, a chain walk that is
purely index arithmetic. If the emitter generates bad code for that shape, this
is where it shows up.

### Emitting

Phase 4 emits fixed-Huffman blocks unconditionally, with a stored-block fallback
when the fixed encoding would be larger than the raw bytes (which happens on
incompressible input, and is the correctness case people forget). Phase 5 adds
symbol-frequency counting, length-limited canonical code construction capped at
15 bits, and the header encoding of those code lengths through the code-length
alphabet with its run-length escapes — i.e. Phase 3's reader run backwards.

Correctness for both phases is the same single question: **does the system
`gunzip` accept it and reproduce the input byte-for-byte?**

---

## Testing

### Structure

Mirror `sqlite/` exactly: a top-level `gzip/` project with its own
`medaka.toml`, `lib/` modules, demo entry points, and a `test/` directory of
oracle scripts. The SQLite oracles are wired into CI as the `sqlite` shard by
pattern (`.github/workflows/ci.yml`), and its scripts under `sqlite/test/`
are the template to copy — including the `MEDAKA_ROOT`/`MEDAKA_EMITTER`
preamble and the "build the demo, run it, diff against the real tool" shape.

### The oracle scripts

- **Decompress:** for each corpus file and each level 0–9, `gzip -N` it with the
  system tool, inflate with ours, diff against the original.
- **Compress:** deflate with ours, `gunzip` it with the system tool, diff
  against the original. This direction is the one that proves RFC conformance
  without demanding bit-identical output.
- **Round-trip:** `inflate (deflate x) == x` entirely inside Medaka — the
  property-test surface, run over generated inputs via `stdlib/test.mdk`.
- **Self-referential:** inflate `compiler/seed/emitter.ll.gz` and diff against
  `gunzip -c` of the same file. ~1.7 MB of real dynamic-Huffman data, already in
  the repo, no fixture to add.

### The corpus, and why each entry is there

| Input | What it catches |
|-------|-----------------|
| Empty file | Zero-length stream, `BFINAL` on an empty block |
| One byte | A minimal fixed-Huffman stream (the system `gzip` picks BTYPE=1 for a genuinely 0- or 1-byte input at every level 1–9 — its block-splitting heuristic never has enough symbol diversity at this size to justify a dynamic table, so this entry does **not** exercise a degenerate Huffman alphabet; see the "dynamic Huffman with zero used distance codes" entry below for that) |
| Dynamic block with zero used distance codes | Degenerate Huffman alphabet: RFC 1951 §3.2.7's "no distance codes used at all" shape (`numUsed == 0`), which arises when a dynamic block is all-literals. Neither the system `gzip` nor Python's `zlib` (any strategy) ever produces this — both pad the distance tree to ≥2 codes when real usage is 0 or 1 — so this fixture is hand-built (`gzip/test/gen_zerodist_fixture.py`), the same technique Phase 3 used to pin the repeat-code-16 error path |
| 100 KB of one repeated byte | The `distance = 1` overlap case, and the maximum-length code |
| `/dev/urandom` output | Incompressible input → stored-block fallback; catches an encoder that grows the data and never notices |
| A large `.mdk` source file | Realistic text, dynamic Huffman, long matches |
| A file with every byte value 0–255 | Full literal alphabet; catches a lit/len table off by one at 255/256 |
| A file just over 32768 bytes | Window wrap boundary |
| Deliberately truncated `.gz` | Error path: must `Err`, must not hang or read out of bounds |
| `.gz` with a corrupted CRC | Error path: must `Err` *after* producing plausible-looking output |

That last pair matters more than it looks. A decompressor's error paths are
where out-of-bounds reads live, and this repo already has an open
memory-safety interest in exactly that class.

> ⚠️ **A captured golden here would record what our codec did, not what is
> correct.** Do not capture goldens of our own output. Every assertion in this
> project is a diff against the *system tool* or a round-trip identity. That is
> the one discipline that makes this project immune to the enshrine-the-bug
> failure mode, and it should not be relaxed for convenience.

### Engine parity

Everything here is pure integer and array work with no platform surface beyond
file IO, so the codec should run identically under `medaka run`, native, and
WasmGC. That makes it a strong candidate for a tandem gate alongside the
existing `test/wasm/diff_sqlite.sh` — a `diff_gzip.sh` sibling running the same
round-trip on the wasm engine. Any divergence is a backend bug in bit
manipulation, which is precisely the kind of thing the three-engine
differential exists to find and has never had a bit-heavy workload to find it
with.

---

## What this is *not* for

One claim needs retracting before someone builds on it: **this cannot remove
the `gunzip` dependency from the cold bootstrap.**
`test/bootstrap_from_seed.sh` expands `compiler/seed/emitter.ll.gz` *before* any
Medaka binary exists — that is the entire point of a seed. A Medaka inflate
would need a Medaka binary to run, which is the thing the seed is there to
produce. The chicken-and-egg is unresolvable and should not be attempted.

The genuine adjacent payoff is on the *write* side: `test/refresh_seed.sh`
invokes the system `gzip` to produce the committed seed, and that step runs when
a working `medaka` already exists. Replacing it is possible. It should also be
approached with suspicion — a subtly wrong deflate there produces a committed
artifact that fails to expand on someone else's machine, and the failure lands
in cold bootstrap, the least debuggable place in the tree. If it is ever done,
the rule is: emit with ours, expand with the system `gunzip`, diff against the
input, and refuse to write the artifact unless that round-trip passes.

Better follow-ons, in order of value:

1. **A `.git` object-store reader.** Loose objects are zlib streams; packfiles
   add delta encoding. The oracle is `git cat-file` — the same
   real-tool-differential shape that made the SQLite project work, on a format
   with far more real-world reach.
2. **`.zip` archive support.** DEFLATE plus a central-directory parser; a small
   increment over Phases 1–4 with immediate practical use.
3. **Graduating `BitReader`/`BitWriter` to `stdlib/`.** Every binary format
   with sub-byte fields wants it, and there is currently nothing.
