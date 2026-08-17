#!/bin/sh
# gen_field_corpus.sh — regenerate pds/test/vectors/field_reference_corpus.txt
# from libsecp256k1 at the pinned commit (S-field, #1699 field 10x2^26 limbs).
#
# THIS IS A TOOL, NOT A GATE.  It asserts nothing about the Medaka compiler.
# It needs NETWORK (it clones bitcoin-core/secp256k1) and a C compiler, so it
# is never run in CI, and it deliberately lives OUTSIDE pds/test/ — a *.sh
# directly under pds/test/ is executed as a CI gate by the `'pds/test/*'`
# shard glob (pds/README.md, "CI classification policy" (c)).  Its row lives
# in test/CI-COVERAGE-TOOLS.txt, keyed by repo-relative path minus `.sh`.
#
# What IS graded is the artifact it produces: pds/test/field_vectors.sh runs
# the corpus against pds/lib/field.mdk, and pds/test/vector_provenance.sh
# checks the corpus's ledger row and re-hashes its bytes.
#
# Usage:
#   sh pds/tools/gen_field_corpus.sh [output-path]
#
# The ONLY run-time parameter is the output path.  The input set and the pair
# list live in committed source (pds/tools/field_corpus_driver.c), never in
# argv or the environment — pds/test/VECTOR-PROVENANCE.txt's `extraction:`
# key requires a procedure that regenerates the file byte-for-byte, and a
# selection passed at run time would not be one (RUN-PDS0-016 Q2).
#
# Re-verify the committed corpus:
#   sh pds/tools/gen_field_corpus.sh /tmp/x \
#     && cmp /tmp/x pds/test/vectors/field_reference_corpus.txt
set -eu

# The pin.  This string must equal pds/test/VECTOR-PROVENANCE.txt's
# [impl] libsecp256k1 `commit:` value.
PIN_TAG="v0.8.0"
PIN_COMMIT="6e2c8bc4ecdc6e71dbe7a368f360d8d453ce435d"
REPO="https://github.com/bitcoin-core/secp256k1"

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$HERE/../.." && pwd)"

OUT="${1:-$ROOT/pds/test/vectors/field_reference_corpus.txt}"
DRIVER="$HERE/field_corpus_driver.c"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

CLONE="$WORK/secp256k1"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$PIN_TAG" "$REPO" "$CLONE"

# ^{commit} IS LOAD-BEARING — DO NOT "SIMPLIFY" IT AWAY.  v0.8.0 is an
# ANNOTATED tag: a bare `git rev-parse v0.8.0` (and a `git ls-remote` on the
# unpeeled refs/tags/v0.8.0) hands back the TAG OBJECT's sha (18f07c42...),
# not the commit (6e2c8bc4...).  The ledger's `commit:` key means the commit,
# and nothing downstream can catch the substitution: the provenance gate
# checks 40-lowercase-hex and cross-stanza agreement, neither of which
# distinguishes a tag object from a commit (RUN-PDS0-016).
ACTUAL="$(git -C "$CLONE" rev-parse "$PIN_TAG^{commit}")"
if [ "$ACTUAL" != "$PIN_COMMIT" ]; then
  echo "FAIL: $PIN_TAG resolves to $ACTUAL, not the pinned $PIN_COMMIT" >&2
  echo "      A MOVED TAG IS A STOP-AND-REPORT, not a silent re-pin." >&2
  exit 1
fi

# libsecp256k1's field code is header-only under src/, so one cc invocation
# compiles the driver against the clone: no autotools, no cmake, no library
# build.  -DUSE_FORCE_WIDEMUL_INT64=1 selects src/field_10x26_impl.h.
cc -O2 -DUSE_FORCE_WIDEMUL_INT64=1 -I"$CLONE" -o "$WORK/field_corpus_driver" "$DRIVER"

"$WORK/field_corpus_driver" > "$WORK/corpus.txt"

mkdir -p "$(dirname -- "$OUT")"
cp "$WORK/corpus.txt" "$OUT"
echo "wrote $OUT ($(wc -l < "$OUT") lines) from $REPO @ $PIN_COMMIT"
