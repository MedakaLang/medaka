#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The generator adds the raw-s capture to this pinned upstream translation unit. */
#include "src/secp256k1.c"

static unsigned char keys[16][32];
static unsigned char digests[16][32];

static int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static int read_hex(const char *text, unsigned char *out, size_t size) {
    size_t i;
    if (strlen(text) != size * 2) return 0;
    for (i = 0; i < size; i++) {
        int hi = hex_value(text[i * 2]);
        int lo = hex_value(text[i * 2 + 1]);
        if (hi < 0 || lo < 0) return 0;
        out[i] = (unsigned char)((hi << 4) | lo);
    }
    return 1;
}

static void print_hex(const unsigned char *bytes, size_t size) {
    size_t i;
    for (i = 0; i < size; i++) printf("%02x", bytes[i]);
}

static void emit_tuple(
    secp256k1_context *ctx,
    const char *kind,
    unsigned int id,
    const unsigned char key[32],
    const unsigned char digest[32],
    const char *message
) {
    unsigned char nonce[32], raw_s[32], signature[64], pub_bytes[33];
    secp256k1_ecdsa_signature sig;
    secp256k1_pubkey pub;
    size_t pub_size = sizeof(pub_bytes);
    unsigned int captures_before = medaka_raw_s_capture_count;

    if (!nonce_function_rfc6979_impl(
            secp256k1_get_hash_context(ctx), nonce, digest, key, NULL, NULL, 0)) {
        fprintf(stderr, "libsecp256k1 RFC6979 failed for row %u\n", id);
        exit(1);
    }
    if (!secp256k1_ecdsa_sign(ctx, &sig, digest, key, NULL, NULL)) {
        fprintf(stderr, "libsecp256k1 signing failed for row %u\n", id);
        exit(1);
    }
    if (medaka_raw_s_capture_count != captures_before + 1) {
        fprintf(stderr, "libsecp256k1 raw-s capture count drifted for row %u\n", id);
        exit(1);
    }
    secp256k1_scalar_get_b32(raw_s, &medaka_captured_raw_s);
    if (!secp256k1_ecdsa_signature_serialize_compact(ctx, signature, &sig)
        || !secp256k1_ec_pubkey_create(ctx, &pub, key)
        || !secp256k1_ec_pubkey_serialize(
            ctx, pub_bytes, &pub_size, &pub, SECP256K1_EC_COMPRESSED)) {
        fprintf(stderr, "libsecp256k1 serialization failed for row %u\n", id);
        exit(1);
    }

    printf("%s %u ", kind, id);
    print_hex(key, 32);
    if (message != NULL) printf(" %s", message);
    printf(" ");
    print_hex(digest, 32);
    printf(" ");
    print_hex(pub_bytes, pub_size);
    printf(" ");
    print_hex(nonce, 32);
    printf(" ");
    print_hex(signature, 32);
    printf(" ");
    print_hex(raw_s, 32);
    printf(" ");
    print_hex(signature + 32, 32);
    printf(" ");
    print_hex(signature, 64);
    putchar('\n');
}

int main(int argc, char **argv) {
    FILE *input;
    char line[1024], kind[16], a[1024], b[1024], c[1024];
    unsigned char pds_digest[32];
    secp256k1_context *ctx;
    unsigned int id, key_id, digest_id;

    if (argc != 2) {
        fprintf(stderr, "usage: signing_corpus_libsecp <signing_inputs.txt>\n");
        return 2;
    }
    input = fopen(argv[1], "r");
    if (input == NULL) return 2;
    ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
    if (ctx == NULL) return 2;

    while (fgets(line, sizeof(line), input) != NULL) {
        if (line[0] == '#' || line[0] == '\n') continue;
        if (sscanf(line, "%15s %u %1023s %1023s %1023s", kind, &id, a, b, c) < 3) return 2;
        if (strcmp(kind, "key") == 0) {
            if (id >= 16 || !read_hex(a, keys[id], 32)) return 2;
        } else if (strcmp(kind, "digest") == 0) {
            if (id >= 16 || !read_hex(a, digests[id], 32)) return 2;
        }
    }
    rewind(input);
    while (fgets(line, sizeof(line), input) != NULL) {
        if (line[0] == '#' || line[0] == '\n') continue;
        if (sscanf(line, "%15s %u %1023s %1023s %1023s", kind, &id, a, b, c) < 3) return 2;
        if (strcmp(kind, "pair") == 0) {
            key_id = (unsigned int)strtoul(a, NULL, 10);
            digest_id = (unsigned int)strtoul(b, NULL, 10);
            if (key_id >= 16 || digest_id >= 16) return 2;
            emit_tuple(ctx, "sign", id, keys[key_id], digests[digest_id], NULL);
        } else if (strcmp(kind, "pds") == 0) {
            key_id = (unsigned int)strtoul(a, NULL, 10);
            if (key_id >= 16 || !read_hex(c, pds_digest, 32)) return 2;
            emit_tuple(ctx, "pds-ref", id, keys[key_id], pds_digest, b);
        }
    }

    fclose(input);
    secp256k1_context_destroy(ctx);
    return 0;
}
