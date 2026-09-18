#!/bin/sh
# BYTES CENSUS RATCHET (CI, epic #3134).
#
# WHAT IT PROVES: for every file enrolled in test/bytes_census_baseline.toml
# (Phase A: stdlib/hex.mdk only), the file's `Array Int` type-position count
# has not risen since the baseline was captured. A file with no row is
# UNCONSTRAINED by design — see test/bytes_census.sh's header for why this is
# a per-file opt-in ratchet rather than a tree-wide one: `Array Int` remains
# the FFI-crossable set (limbs, general-purpose Int arrays), so a bare "may
# only fall, everywhere" rule would false-positive on legitimate new arrays
# unrelated to the Bytes migration.
#
# WHAT IT DOES NOT PROVE: that a file's current count is CORRECT, or that
# every byte-sequence use of `Array Int` in the tree has been found — the
# census counts text positions of the literal "Array Int", not semantics, and
# only enrolled files are checked at all.
#
# Needs no built ./medaka -- pure text/grep, like test/bytes_census.sh itself.
#
# Usage:  sh test/diff_compiler_bytes_census.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

sh "$ROOT/test/bytes_census.sh" --check "$ROOT/test/bytes_census_baseline.toml"
exit $?
