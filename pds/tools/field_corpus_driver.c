/* field_corpus_driver.c — reference answer key for pds/lib/field.mdk
 * (S-field, #1699 field 10x2^26 limbs).
 *
 * Prints, on stdout, the reference corpus that grades Medaka's secp256k1
 * field arithmetic against libsecp256k1 (bitcoin-core/secp256k1), pinned at
 * commit 6e2c8bc4ecdc6e71dbe7a368f360d8d453ce435d (tag v0.8.0, PEELED — the
 * annotated tag OBJECT is 18f07c42..., which is NOT the commit).
 *
 * Build (no autotools, no cmake — libsecp256k1's field code is header-only):
 *
 *   cc -O2 -DUSE_FORCE_WIDEMUL_INT64=1 -I<clone> -o drv field_corpus_driver.c
 *
 * -DUSE_FORCE_WIDEMUL_INT64=1 selects src/field_10x26_impl.h, i.e. the SAME
 * 10 x 2^26 limb layout pds/lib/field.mdk mirrors (design P10).  A field
 * element's canonical 32 bytes do not depend on the limb layout, so this flag
 * does not change the answer key; it makes the oracle run the layout the
 * module is cross-checked against, which is P10's whole rationale.
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
 *   <op> <a-64hex> <r-64hex>            for op in { red, sqr, neg, inv }
 *   <op> <a-64hex> <b-64hex> <r-64hex>  for op in { mul, add, sub }
 *
 * Lines beginning '#' are comments.  Operands are RAW 32-byte big-endian
 * values that MAY BE >= p: every one is read with secp256k1_fe_set_b32_mod
 * (reduce mod p) and normalized before use.  `red` grades exactly that
 * reduction.  Results are always secp256k1_fe_normalize + secp256k1_fe_get_b32
 * (canonical 32 bytes).
 *
 * `sub` is NEGATE-THEN-ADD: libsecp256k1 has no secp256k1_fe_sub.  It is
 * computed as secp256k1_fe_negate(&nb, &b, 1) followed by secp256k1_fe_add.
 */

#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "src/util.h"
#include "src/field_impl.h"

#define PINNED_COMMIT "6e2c8bc4ecdc6e71dbe7a368f360d8d453ce435d"

/* p = 2^256 - 2^32 - 977 */
static const char *P_HEX =
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f";

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

static void print_hex32(const unsigned char v[32]) {
    int i;
    for (i = 0; i < 32; i++) printf("%02x", v[i]);
}

/* ── the input set ──────────────────────────────────────────────────────── */

#define N_EDGE 28
#define N_RAND 16
#define N_VALS (N_EDGE + N_RAND)

static unsigned char vals[N_VALS][32];

/* The nine limb boundaries of the 10 x 2^26 layout: limbs 0..8 hold 26 bits
 * each and limb 9 holds the remaining 22 (9*26 + 22 = 256).  k = 234 is the
 * 26/22 seam at limb 9 (#1699 names it specifically). */
static const int LIMB_BITS[9] = {26, 52, 78, 104, 130, 156, 182, 208, 234};

/* SplitMix64 — a documented, self-contained, deterministic generator, seeded
 * with the literal below.  Its outputs are INPUTS, not answer keys, so they
 * need no provenance; they must only be reproducible, which is why the
 * generator and its seed live in this committed file. */
static uint64_t sm_state = UINT64_C(0x0ddba11c0ffee123);

static uint64_t splitmix64(void) {
    uint64_t z = (sm_state += UINT64_C(0x9E3779B97F4A7C15));
    z = (z ^ (z >> 30)) * UINT64_C(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)) * UINT64_C(0x94D049BB133111EB);
    return z ^ (z >> 31);
}

static void build_values(void) {
    int i, j, n = 0;
    unsigned char p[32];

    bytes_from_hex(p, P_HEX);

    bytes_zero(vals[n]); n++;                                  /* 0  = 0     */
    bytes_zero(vals[n]); bytes_setbit(vals[n], 0); n++;        /* 1  = 1     */
    bytes_zero(vals[n]); bytes_setbit(vals[n], 1); n++;        /* 2  = 2     */
    bytes_zero(vals[n]); bytes_setbit(vals[n], 0);
                         bytes_setbit(vals[n], 1);
                         bytes_setbit(vals[n], 2); n++;        /* 3  = 7     */

    for (i = 0; i < 9; i++) {                                  /* 4..21      */
        bytes_zero(vals[n]); bytes_setbit(vals[n], LIMB_BITS[i]);
        bytes_sub1(vals[n]); n++;                              /* 2^k - 1    */
        bytes_zero(vals[n]); bytes_setbit(vals[n], LIMB_BITS[i]); n++; /* 2^k */
    }

    bytes_zero(vals[n]); bytes_setbit(vals[n], 255); n++;      /* 22 = 2^255 */
    memset(vals[n], 0xff, 32); bytes_sub1(vals[n]); n++;       /* 23 = 2^256-2 */

    memcpy(vals[n], p, 32); bytes_sub1(vals[n]); n++;          /* 24 = p-1   */
    memcpy(vals[n], p, 32); n++;                               /* 25 = p     */
    memcpy(vals[n], p, 32); bytes_add1(vals[n]); n++;          /* 26 = p+1   */
    memset(vals[n], 0xff, 32); n++;                            /* 27 = 2^256-1 */

    /* 28..43 — pseudo-random, 4 SplitMix64 draws each, big-endian, first
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
 * block, and the four edge operands paired against every random value. */
static const int SUBSET12[12] = { 0, 1, 2, 4, 5, 20, 21, 24, 25, 26, 27, 22 };
static const int PAIR_EDGES[4] = { 1, 5, 24, 27 };

/* ── the operations ─────────────────────────────────────────────────────── */

static void load(secp256k1_fe *r, const unsigned char v[32]) {
    secp256k1_fe_set_b32_mod(r, v);
    secp256k1_fe_normalize(r);
}

static void emit_unary(const char *op, const unsigned char a[32]) {
    secp256k1_fe x, r;
    unsigned char out[32];

    load(&x, a);
    if (strcmp(op, "red") == 0) {
        r = x;
    } else if (strcmp(op, "sqr") == 0) {
        secp256k1_fe_sqr(&r, &x);
    } else if (strcmp(op, "neg") == 0) {
        secp256k1_fe_negate(&r, &x, 1);
    } else { /* inv */
        secp256k1_fe_inv(&r, &x);
    }
    secp256k1_fe_normalize(&r);
    secp256k1_fe_get_b32(out, &r);

    printf("%s ", op);
    print_hex32(a);
    printf(" ");
    print_hex32(out);
    printf("\n");
}

static void emit_binary(const char *op, const unsigned char a[32], const unsigned char b[32]) {
    secp256k1_fe x, y, r, nb;
    unsigned char out[32];

    load(&x, a);
    load(&y, b);
    if (strcmp(op, "mul") == 0) {
        secp256k1_fe_mul(&r, &x, &y);
    } else if (strcmp(op, "add") == 0) {
        r = x;
        secp256k1_fe_add(&r, &y);
    } else { /* sub — negate then add; libsecp256k1 has no fe_sub */
        secp256k1_fe_negate(&nb, &y, 1);
        r = x;
        secp256k1_fe_add(&r, &nb);
    }
    secp256k1_fe_normalize(&r);
    secp256k1_fe_get_b32(out, &r);

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
    static const char *UNARY[4] = {"red", "sqr", "neg", "inv"};
    static const char *BINARY[3] = {"mul", "add", "sub"};
    int i, v;

    build_values();

    printf("# field_10x26 reference corpus for pds/lib/field.mdk (S-field, #1699)\n");
    printf("# reference: bitcoin-core/secp256k1 v0.8.0 @ %s\n", PINNED_COMMIT);
    printf("# generated by pds/tools/field_corpus_driver.c via pds/tools/gen_field_corpus.sh\n");
    printf("# GENERATED — do not hand-edit; re-running the generator must reproduce this file byte-for-byte.\n");
    printf("# grammar: '<op> <a> <r>' for red/sqr/neg/inv; '<op> <a> <b> <r>' for mul/add/sub.\n");
    printf("#          all operands 64 lowercase hex chars, 32 bytes big-endian.\n");
    printf("# operands are RAW and MAY BE >= p; each is read with secp256k1_fe_set_b32_mod\n");
    printf("#          (reduce mod p) and normalized.  Results are canonical (normalize+get_b32).\n");
    printf("# 'sub' is NEGATE-THEN-ADD: libsecp256k1 has no secp256k1_fe_sub.\n");
    printf("# 'inv 0' is 0 in this reference — inversion of zero is not an error here.\n");
#ifdef SECP256K1_WIDEMUL_INT64
    printf("# widemul: INT64 (field_10x26)\n");
#else
    printf("# widemul: NOT INT64 — this corpus was NOT generated against field_10x26\n");
#endif

    for (i = 0; i < 4; i++)
        for (v = 0; v < N_VALS; v++)
            emit_unary(UNARY[i], vals[v]);

    for (i = 0; i < 3; i++)
        emit_pairs(BINARY[i]);

    return 0;
}
