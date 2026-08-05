#!/usr/bin/env python3
"""
gzip/test/gen_zerodist_fixture.py -- hand-construct a raw DEFLATE
dynamic-Huffman block whose DISTANCE alphabet has ZERO used codes (RFC 1951
Sec 3.2.7's "no distance codes used at all" shape, HDIST field = 0 meaning
1 code, that one code's length = 0). Invoked by inflate_oracle.sh; not a
gate on its own.

Why hand-built, not the system `gzip` or Python's `zlib`: measured
empirically that neither ever produces this shape. `gzip`'s block-splitting
heuristic won't even choose a dynamic block for tiny/uniform-random inputs
(it falls back to stored), and zlib's own encoder -- at every strategy
tried, including Z_HUFFMAN_ONLY which disables LZ77 matching entirely --
pads the distance tree to at least 2 non-zero-frequency codes whenever real
usage is 0 or 1 (its own trees.c comment: "to avoid special checks later on
we force at least two codes of non zero frequency"). So neither tool
structurally ever emits the numUsed==0 shape; only a from-scratch encoder
can produce it, the same way Phase 3 hand-built a bitstream via bitio's
writer primitives to pin the repeat-code-16 error path.

Every literal byte 0..255 is used exactly once (a shuffled permutation of
the full byte range) plus the end-of-block symbol 256 --- 257 real-valued
lit/len codes, HLIT field = 0. No back-references are ever emitted, so the
distance alphabet is genuinely unused, not just small.
"""
import sys
import random
import zlib
import heapq


def canonical_codes(lengths):
    """lengths: list indexed by symbol -> code length (0 = unused).
    Returns dict symbol -> (code_int, length), MSB-first-bit-pattern
    integers per RFC 1951 3.2.2's canonical construction."""
    max_len = max(lengths) if lengths else 0
    bl_count = [0] * (max_len + 1)
    for l in lengths:
        if l > 0:
            bl_count[l] += 1
    code = 0
    next_code = [0] * (max_len + 2)
    for bits in range(1, max_len + 1):
        code = (code + bl_count[bits - 1]) << 1
        next_code[bits] = code
    out = {}
    for sym, l in enumerate(lengths):
        if l > 0:
            out[sym] = (next_code[l], l)
            next_code[l] += 1
    return out


def huffman_lengths(freqs, nsyms, max_len=15):
    """Standard greedy Huffman over freqs (dict sym->freq, freq>0 only).
    Returns list of length nsyms with code length per symbol (0 if unused).
    """
    if not freqs:
        return [0] * nsyms
    if len(freqs) == 1:
        # A single symbol still needs a real 1-bit code (length-1
        # exception territory) -- but for OUR literal alphabet we always
        # have >1 symbol, so this path is unused in this script.
        (only,) = freqs.keys()
        lengths = [0] * nsyms
        lengths[only] = 1
        return lengths
    heap = []
    uid = 0
    for sym, f in freqs.items():
        heap.append((f, uid, ('leaf', sym)))
        uid += 1
    heapq.heapify(heap)
    while len(heap) > 1:
        f1, _, n1 = heapq.heappop(heap)
        f2, _, n2 = heapq.heappop(heap)
        node = ('node', n1, n2)
        heapq.heappush(heap, (f1 + f2, uid, node))
        uid += 1
    _, _, root = heap[0]

    lengths = [0] * nsyms

    def walk(node, d):
        if node[0] == 'leaf':
            lengths[node[1]] = d if d > 0 else 1
        else:
            walk(node[1], d + 1)
            walk(node[2], d + 1)

    walk(root, 0)
    assert max(lengths) <= max_len, "length-limiting not needed for this small alphabet"
    return lengths


class BitWriterLSB:
    """LSB-first bit writer matching gzip/lib/bitio.mdk's putBits convention."""
    def __init__(self):
        self.bytes_out = bytearray()
        self.hold = 0
        self.count = 0

    def put_bits(self, v, n):
        self.hold |= (v & ((1 << n) - 1)) << self.count
        self.count += n
        while self.count >= 8:
            self.bytes_out.append(self.hold & 0xFF)
            self.hold >>= 8
            self.count -= 8

    def put_code_msb(self, code, length):
        # Walk the code's bits from MSB to LSB, each one pushed via the
        # LSB-first bit stream -- exactly putCodeMSB's contract.
        for i in range(length - 1, -1, -1):
            self.put_bits((code >> i) & 1, 1)

    def finish(self):
        if self.count > 0:
            self.bytes_out.append(self.hold & 0xFF)
            self.hold = 0
            self.count = 0
        return bytes(self.bytes_out)


CL_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]


def build_block(data: bytes) -> bytes:
    # literal/length alphabet: 256 literals (freq = 1 each, all used) + EOB(256)
    freqs = {b: 1 for b in range(256)}
    freqs[256] = 1
    litlen_lengths = huffman_lengths(freqs, 257)
    assert all(l > 0 for l in litlen_lengths), "every literal + EOB must be used"
    litlen_codes = canonical_codes(litlen_lengths)

    # distance alphabet: HDIST field = 0 -> 1 code total, that code UNUSED
    # (length 0) -- the numUsed==0 shape.
    dist_lengths = [0]  # single entry, length 0: "no distance codes used"

    # code-length sequence to transmit: 257 lit/len lengths + 1 dist length
    cl_seq = litlen_lengths + dist_lengths
    assert len(cl_seq) == 258

    # RLE-encode cl_seq per RFC 1951 3.2.7 (symbols 0-15 direct, 16/17/18
    # repeat codes). Our sequence has no runs worth compressing (all
    # distinct-ish small integers, one trailing 0) so we simply emit every
    # entry directly via code-length-alphabet symbol == its own value.
    # (Direct symbols only -- 16/17/18 stay unused, which is fine: they are
    # simply absent from the CL alphabet's frequency table.)
    cl_freqs = {}
    for v in cl_seq:
        cl_freqs[v] = cl_freqs.get(v, 0) + 1
    cl_lengths = huffman_lengths(cl_freqs, 19, max_len=7)
    cl_codes = canonical_codes(cl_lengths)

    # HCLEN: how many entries (in the RFC's permuted order) we must send to
    # cover every CL symbol with a nonzero length.
    last_nonzero_idx = 0
    for i, sym in enumerate(CL_ORDER):
        if cl_lengths[sym] > 0:
            last_nonzero_idx = i
    hclen_count = max(last_nonzero_idx + 1, 4)

    w = BitWriterLSB()
    w.put_bits(1, 1)   # BFINAL
    w.put_bits(2, 2)   # BTYPE = 10 (dynamic Huffman) -- LSB-first 2-bit field, value 2
    w.put_bits(257 - 257, 5)  # HLIT: 257 lit/len codes -> field 0
    w.put_bits(1 - 1, 5)      # HDIST: 1 dist code -> field 0
    w.put_bits(hclen_count - 4, 4)  # HCLEN

    for i in range(hclen_count):
        sym = CL_ORDER[i]
        w.put_bits(cl_lengths[sym], 3)

    for v in cl_seq:
        code, length = cl_codes[v]
        w.put_code_msb(code, length)
        # (no extra-bits fields needed -- we used only direct symbols 0-15)

    for b in data:
        code, length = litlen_codes[b]
        w.put_code_msb(code, length)
    # end of block
    code, length = litlen_codes[256]
    w.put_code_msb(code, length)

    return w.finish()


def make_gzip(raw_deflate: bytes, plain: bytes) -> bytes:
    header = bytes([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
    crc = zlib.crc32(plain) & 0xFFFFFFFF
    isize = len(plain) & 0xFFFFFFFF
    trailer = crc.to_bytes(4, 'little') + isize.to_bytes(4, 'little')
    return header + raw_deflate + trailer


# ---- bit-level self-verification (independent of the encoder above) ----

class BitReaderLSB:
    def __init__(self, b):
        self.b = b; self.pos = 0; self.bitpos = 0

    def bits(self, n):
        v = 0
        for i in range(n):
            byte = self.b[self.pos]
            bit = (byte >> self.bitpos) & 1
            v |= bit << i
            self.bitpos += 1
            if self.bitpos == 8:
                self.bitpos = 0
                self.pos += 1
        return v


def verify_shape(raw: bytes):
    br = BitReaderLSB(raw)
    bfinal = br.bits(1)
    btype = br.bits(2)
    assert bfinal == 1, bfinal
    assert btype == 2, f"expected BTYPE=10 (dynamic), got {btype}"
    hlit = br.bits(5) + 257
    hdist = br.bits(5) + 1
    hclen = br.bits(4) + 4
    cl = [0] * 19
    for i in range(hclen):
        cl[CL_ORDER[i]] = br.bits(3)
    cl_codes = canonical_codes(cl)
    # invert for decode: (code,len) -> sym
    inv = {}
    for sym, (c, l) in cl_codes.items():
        inv[(c, l)] = sym

    def decode_one():
        code = 0
        length = 0
        while length <= 15:
            code = (code << 1) | br.bits(1)
            length += 1
            if (code, length) in inv:
                return inv[(code, length)]
        raise Exception("bad CL code")

    total = hlit + hdist
    lens = []
    prev = 0
    while len(lens) < total:
        sym = decode_one()
        if sym <= 15:
            lens.append(sym)
            prev = sym
        elif sym == 16:
            rep = br.bits(2) + 3
            lens.extend([prev] * rep)
        elif sym == 17:
            rep = br.bits(3) + 3
            lens.extend([0] * rep)
        elif sym == 18:
            rep = br.bits(7) + 11
            lens.extend([0] * rep)
    dist_lens = lens[hlit:hlit + hdist]
    num_used_dist = sum(1 for x in dist_lens if x > 0)
    return dict(bfinal=bfinal, btype=btype, hlit=hlit, hdist=hdist,
                dist_lens=dist_lens, num_used_dist=num_used_dist)


def main():
    random.seed(20260805)
    data = bytearray(range(256))
    random.shuffle(data)
    data = bytes(data)

    raw = build_block(data)
    shape = verify_shape(raw)
    print("shape:", shape, file=sys.stderr)
    assert shape['btype'] == 2
    assert shape['num_used_dist'] == 0, "did not achieve the numUsed==0 shape"

    # cross-check with an independent decoder (python's own zlib) that this
    # is a well-formed raw deflate stream decoding to our known plaintext --
    # NOT our own inflater, so this is a real independent check.
    d = zlib.decompressobj(-15)
    out = d.decompress(raw) + d.flush()
    assert out == data, "python zlib disagrees with our hand-built stream"

    gz = make_gzip(raw, data)

    with open(sys.argv[1], 'wb') as f:
        f.write(gz)
    with open(sys.argv[2], 'wb') as f:
        f.write(data)
    print(f"wrote {sys.argv[1]} ({len(gz)} bytes), {sys.argv[2]} ({len(data)} bytes)", file=sys.stderr)


if __name__ == '__main__':
    main()
