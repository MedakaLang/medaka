/* scalar_corpus_driver.c — reference answer key for pds/lib/scalar.mdk
 * (S-scalar, #1700 secp256k1 group ops + RFC 6979 + low-S).
 *
 * Prints, on stdout, the reference corpus that grades Medaka's arithmetic
 * modulo the secp256k1 GROUP ORDER
 *
 *   n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141
 *
 * against libsecp256k1 (bitcoin-core/secp256k1), pinned at commit
 * 6e2c8bc4ecdc6e71dbe7a368f360d8d453ce435d (tag v0.8.0, PEELED — the
 * annotated tag OBJECT is 18f07c42..., which is NOT the commit).
 *
 * Build (no autotools, no cmake — libsecp256k1's scalar code is header-only):
 *
 *   cc -O2 -DUSE_FORCE_WIDEMUL_INT64=1 -I<clone> -o drv scalar_corpus_driver.c
 *
 * -DUSE_FORCE_WIDEMUL_INT64=1 selects src/scalar_8x32_impl.h.  UNLIKE the
 * field driver, that flag is NOT load-bearing for this answer key: a scalar
 * enters and leaves through canonical 32-byte big-endian serialization, so
 * scalar_8x32 and scalar_4x64 emit identical bytes, and pds/lib/scalar.mdk
 * mirrors NEITHER layout (it uses 16 limbs of 2^16 — see its module header).
 * The flag is passed anyway to keep the committed [impl] stanza's note true
 * and to match the recipe pds/tools/gen_field_corpus.sh already proved.
 *
 * DETERMINISM IS A CONTRACT.  This program must emit byte-identical output on
 * every run, on every machine: no timestamps, no paths, no locale-dependent
 * formatting, no iteration over an unordered container.  The only constant in
 * the header below is the pinned commit.  pds/test/VECTOR-PROVENANCE.txt's
 * `extraction:` field claims re-running reproduces the corpus byte-for-byte.
 *
 * THE INPUT SET AND THE PAIR LIST LIVE HERE, IN COMMITTED SOURCE, and are not
 * passed at run time (RUN-PDS0-016 Q2): a selection that lives outside the
 * committed artifacts would make `extraction:` not a procedure.  This program
 * takes no arguments at all.
 *
 * Output grammar — one row per line, lowercase hex, single-space separated:
 *
 *   <op> <a-64hex> <r-64hex>            for op in { red, neg, inv }
 *   <op> <a-64hex> <bit>                for op in { high, ovf }   bit is 0/1
 *   <op> <a-64hex> <b-64hex> <r-64hex>  for op in { mul, add, sub }
 *
 * Lines beginning '#' are comments.  Operands are RAW 32-byte big-endian
 * values that MAY BE >= n: every one is read with secp256k1_scalar_set_b32,
 * which reduces mod n.  `red` grades exactly that reduction.
 *
 * `ovf` records set_b32's *overflow flag — 1 iff the RAW 32 bytes were >= n.
 * That is the answer key for scalar.mdk's scFromBytes rejection boundary, and
 * it is the cell that catches an off-by-one at n itself.
 *
 * `high` is secp256k1_scalar_is_high on the REDUCED value — the low-S
 * predicate, strictly s > floor(n/2).
 *
 * `sub` is NEGATE-THEN-ADD: libsecp256k1 has no secp256k1_scalar_sub.
 *
 * `inv 0` is 0 in this reference: secp256k1_scalar_inverse is built directly
 * on secp256k1_modinv32, whose header states "If x is zero, the result will be
 * zero as well".  Inversion of zero is NOT an error here (RUN-PDS0-016 Q1).
 */

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>

#include "src/util.h"
#include "src/scalar_impl.h"

#define PINNED_COMMIT "6e2c8bc4ecdc6e71dbe7a368f360d8d453ce435d"

/* n, the secp256k1 group order (SEC 2 v2 §2.4.1). */
static const char *N_HEX =
    "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141";

/* floor(n/2) — hardcoded AND asserted equal to a byte-wise n >> 1 below, so a
 * transcription slip in either one is loud rather than silent. */
static const char *N_H_HEX =
    "7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0";

/* ── 32-byte big-endian helpers ─────────────────────────────────────────── */

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static void bytes_from_hex(unsigned char v[32], const char *hex) {
    int i;
    for (i = 0; i < 32; i++) {
        v[i] = (unsigned char)((hexval(hex[2 * i]) << 4) | hexval(hex[2 * i + 1]));
    }
}

static void bytes_zero(unsigned char v[32]) { memset(v, 0, 32); }

static void bytes_setbit(unsigned char v[32], int k) {
    v[31 - k / 8] |= (unsigned char)(1u << (k % 8));
}

static void bytes_add1(unsigned char v[32]) {
    int i;
    for (i = 31; i >= 0; i--) {
        v[i] = (unsigned char)(v[i] + 1);
        if (v[i] != 0) break;
    }
}

static void bytes_sub1(unsigned char v[32]) {
    int i;
    for (i = 31; i >= 0; i--) {
        unsigned char old = v[i];
        v[i] = (unsigned char)(v[i] - 1);
        if (old != 0) break;
    }
}

/* r := v >> 1, over 32 big-endian bytes. */
static void bytes_shr1(unsigned char r[32], const unsigned char v[32]) {
    int i;
    unsigned carry = 0;
    for (i = 0; i < 32; i++) {
        unsigned cur = v[i];
        r[i] = (unsigned char)((cur >> 1) | (carry << 7));
        carry = cur & 1u;
    }
}

static void print_hex32(const unsigned char v[32]) {
    int i;
    for (i = 0; i < 32; i++) printf("%02x", v[i]);
}

/* ── the input set ──────────────────────────────────────────────────────── */

#define N_EDGE 36
#define N_RAND 16
#define N_VALS (N_EDGE + N_RAND)

static unsigned char vals[N_VALS][32];

/* Bit positions probed as 2^k-1 / 2^k pairs.  16, 32, ... 240 are the limb
 * boundaries of pds/lib/scalar.mdk's 16 x 2^16 layout; 8 and 248 are byte
 * boundaries, so the set is right for a base-2^8 layout too; 128 and 96 sit
 * mid-word for the 8x32 / 4x64 reference layouts. */
static const int BIT_POS[12] = {8, 16, 32, 48, 64, 96, 128, 160, 192, 224, 240, 248};

/* SplitMix64 — a documented, self-contained, deterministic generator, seeded
 * with the literal below.  Its outputs are INPUTS, not answer keys, so they
 * need no provenance; they must only be reproducible, which is why the
 * generator and its seed live in this committed file.  The seed value is
 * ARBITRARY; it differs from pds/tools/field_corpus_driver.c's on purpose, so
 * the two corpora do not probe the same 16 random points. */
static uint64_t sm_state = UINT64_C(0x5ca1a12ec0ffee42);

static uint64_t splitmix64(void) {
    uint64_t z = (sm_state += UINT64_C(0x9E3779B97F4A7C15));
    z = (z ^ (z >> 30)) * UINT64_C(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)) * UINT64_C(0x94D049BB133111EB);
    return z ^ (z >> 31);
}

static void build_values(void) {
    int i, j, n = 0;
    unsigned char nn[32], nh[32], nh_check[32];

    bytes_from_hex(nn, N_HEX);
    bytes_from_hex(nh, N_H_HEX);

    /* n_h must equal n >> 1.  A mismatch is a transcription error in one of
     * the two literals above, and it must stop the run rather than silently
     * ship a wrong low-S boundary. */
    bytes_shr1(nh_check, nn);
    if (memcmp(nh, nh_check, 32) != 0) {
        fprintf(stderr, "FAIL: N_H_HEX != n >> 1 — transcription error\n");
        exit(1);
    }

    bytes_zero(vals[n]); n++;                                  /* 0  = 0     */
    bytes_zero(vals[n]); bytes_setbit(vals[n], 0); n++;        /* 1  = 1     */
    bytes_zero(vals[n]); bytes_setbit(vals[n], 1); n++;        /* 2  = 2     */
    bytes_zero(vals[n]); bytes_setbit(vals[n], 0);
                         bytes_setbit(vals[n], 1);
                         bytes_setbit(vals[n], 2); n++;        /* 3  = 7     */

    for (i = 0; i < 12; i++) {                                 /* 4..27      */
        bytes_zero(vals[n]); bytes_setbit(vals[n], BIT_POS[i]);
        bytes_sub1(vals[n]); n++;                              /* 2^k - 1    */
        bytes_zero(vals[n]); bytes_setbit(vals[n], BIT_POS[i]); n++; /* 2^k  */
    }

    memcpy(vals[n], nn, 32); bytes_sub1(vals[n]);
                             bytes_sub1(vals[n]); n++;         /* 28 = n-2   */
    memcpy(vals[n], nn, 32); bytes_sub1(vals[n]); n++;         /* 29 = n-1   */
    memcpy(vals[n], nn, 32); n++;                              /* 30 = n     */
    memcpy(vals[n], nn, 32); bytes_add1(vals[n]); n++;         /* 31 = n+1   */
    memcpy(vals[n], nh, 32); n++;                              /* 32 = n_h   */
    memcpy(vals[n], nh, 32); bytes_add1(vals[n]); n++;         /* 33 = n_h+1 */
    bytes_zero(vals[n]); bytes_setbit(vals[n], 255); n++;      /* 34 = 2^255 */
    memset(vals[n], 0xff, 32); n++;                            /* 35 = 2^256-1 */

    /* 36..51 — pseudo-random, 4 SplitMix64 draws each, big-endian, first
     * draw most significant. */
    for (i = 0; i < N_RAND; i++) {
        for (j = 0; j < 4; j++) {
            uint64_t d = splitmix64();
            int b;
            for (b = 0; b < 8; b++) {
                vals[n][j * 8 + b] = (unsigned char)((d >> (56 - 8 * b)) & 0xff);
            }
        }
        n++;
    }
}

/* Indices into vals[]: the 12-element subset used for the all-ordered-pairs
 * block (the n-neighbourhood, the low-S boundary, and the 2^128 seam), and
 * the four edge operands paired against every random value. */
static const int SUBSET12[12] = { 0, 1, 2, 16, 17, 34, 35, 29, 30, 31, 32, 33 };
/*                                0  1  2  2^128-1  2^128  2^255  2^256-1
 *                                n-1  n  n+1  n_h  n_h+1                    */
static const int PAIR_EDGES[4] = { 1, 29, 32, 35 };   /* 1, n-1, n_h, 2^256-1 */

/* ── the operations ─────────────────────────────────────────────────────── */

/* Load raw 32 big-endian bytes as a scalar (reduces mod n), returning
 * set_b32's overflow flag: 1 iff the raw value was >= n. */
static int load(secp256k1_scalar *r, const unsigned char v[32]) {
    int overflow = 0;
    secp256k1_scalar_set_b32(r, v, &overflow);
    return overflow;
}

static void emit_unary(const char *op, const unsigned char a[32]) {
    secp256k1_scalar x, r;
    unsigned char out[32];
    int overflow;

    overflow = load(&x, a);

    if (strcmp(op, "high") == 0 || strcmp(op, "ovf") == 0) {
        int bit = (strcmp(op, "ovf") == 0) ? overflow : secp256k1_scalar_is_high(&x);
        printf("%s ", op);
        print_hex32(a);
        printf(" %d\n", bit ? 1 : 0);
        return;
    }

    if (strcmp(op, "red") == 0) {
        r = x;
    } else if (strcmp(op, "neg") == 0) {
        secp256k1_scalar_negate(&r, &x);
    } else { /* inv */
        secp256k1_scalar_inverse(&r, &x);
    }
    secp256k1_scalar_get_b32(out, &r);

    printf("%s ", op);
    print_hex32(a);
    printf(" ");
    print_hex32(out);
    printf("\n");
}

static void emit_binary(const char *op, const unsigned char a[32], const unsigned char b[32]) {
    secp256k1_scalar x, y, r, nb;
    unsigned char out[32];

    load(&x, a);
    load(&y, b);
    if (strcmp(op, "mul") == 0) {
        secp256k1_scalar_mul(&r, &x, &y);
    } else if (strcmp(op, "add") == 0) {
        secp256k1_scalar_add(&r, &x, &y);
    } else { /* sub — negate then add; libsecp256k1 has no scalar_sub */
        secp256k1_scalar_negate(&nb, &y);
        secp256k1_scalar_add(&r, &x, &nb);
    }
    secp256k1_scalar_get_b32(out, &r);

    printf("%s ", op);
    print_hex32(a);
    printf(" ");
    print_hex32(b);
    printf(" ");
    print_hex32(out);
    printf("\n");
}

/* The pair list, in a fixed order.  Emitted for each of mul/add/sub. */
static void emit_pairs(const char *op) {
    int i, j;

    /* (1) all 144 ordered pairs from the 12-element edge subset */
    for (i = 0; i < 12; i++)
        for (j = 0; j < 12; j++)
            emit_binary(op, vals[SUBSET12[i]], vals[SUBSET12[j]]);

    /* (2) random x random: j in { i, i+1, i+5 } mod 16 — 48 pairs */
    for (i = 0; i < N_RAND; i++) {
        static const int OFF[3] = {0, 1, 5};
        for (j = 0; j < 3; j++) {
            int t = (i + OFF[j]) % N_RAND;
            emit_binary(op, vals[N_EDGE + i], vals[N_EDGE + t]);
        }
    }

    /* (3) random x each of four edge operands — 64 pairs */
    for (i = 0; i < N_RAND; i++)
        for (j = 0; j < 4; j++)
            emit_binary(op, vals[N_EDGE + i], vals[PAIR_EDGES[j]]);
}

int main(void) {
    static const char *UNARY[5] = {"red", "neg", "inv", "high", "ovf"};
    static const char *BINARY[3] = {"mul", "add", "sub"};
    int i, v;

    build_values();

    printf("# secp256k1 scalar (mod n) reference corpus for pds/lib/scalar.mdk (S-scalar, #1700)\n");
    printf("# reference: bitcoin-core/secp256k1 v0.8.0 @ %s\n", PINNED_COMMIT);
    printf("# generated by pds/tools/scalar_corpus_driver.c via pds/tools/gen_scalar_corpus.sh\n");
    printf("# GENERATED — do not hand-edit; re-running the generator must reproduce this file byte-for-byte.\n");
    printf("# grammar: '<op> <a> <r>' for red/neg/inv; '<op> <a> <bit>' for high/ovf;\n");
    printf("#          '<op> <a> <b> <r>' for mul/add/sub.\n");
    printf("#          all 32-byte operands are 64 lowercase hex chars, big-endian; <bit> is 0 or 1.\n");
    printf("# operands are RAW and MAY BE >= n; each is read with secp256k1_scalar_set_b32,\n");
    printf("#          which reduces mod n.  Results are canonical (secp256k1_scalar_get_b32).\n");
    printf("# 'ovf' is set_b32's overflow flag: 1 iff the RAW 32 bytes were >= n.\n");
    printf("# 'high' is secp256k1_scalar_is_high on the REDUCED value: strictly s > floor(n/2).\n");
    printf("# 'sub' is NEGATE-THEN-ADD: libsecp256k1 has no secp256k1_scalar_sub.\n");
    printf("# 'inv 0' is 0 in this reference — inversion of zero is not an error here.\n");
#ifdef SECP256K1_WIDEMUL_INT64
    printf("# widemul: INT64 (scalar_8x32)\n");
#else
    printf("# widemul: NOT INT64 — this corpus was NOT generated against scalar_8x32\n");
#endif

    for (i = 0; i < 5; i++)
        for (v = 0; v < N_VALS; v++)
            emit_unary(UNARY[i], vals[v]);

    for (i = 0; i < 3; i++)
        emit_pairs(BINARY[i]);

    return 0;
}
