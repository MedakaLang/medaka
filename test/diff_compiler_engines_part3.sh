#!/usr/bin/env bash
# Part 3 of the three-engine differential: the fixtures whose LC_ALL=C sorted-key
# index is 2 mod ENGINE_PARTS. The body, the partition rule and the knobs
# are in test/lib_engines_differential.sh.
# Oracles (read by build_oracles.sh --for): test/bin/eval_autoprint_main test/bin/wasm_emit_modules_main
ENGINE_PART=3 exec bash "$(dirname "$0")/lib_engines_differential.sh" "$@"
