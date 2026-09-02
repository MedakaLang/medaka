#!/bin/sh
# diff_compiler_error_quality_baseline.sh — gate wrapper over
# test/error_quality_fixtures/capture.sh's CHECK mode.
#
# capture.sh's DEFAULT action writes (blesses) the 78 `.out` goldens under
# test/error_quality_fixtures/ — that's why capture.sh itself is listed in
# test/CI-COVERAGE-TOOLS.txt as a golden-capture action, not a gate. Nothing
# was diffing those goldens against a fresh binary in CI, so all 66
# non-silent-accept fixtures rotted out from under GRADING.md's scoring
# without any check going red (F5, #2446). This is that check: it drives
# capture.sh in CHECK=1 mode, which compares the corpus against the committed
# `.out` files and exits nonzero on any mismatch — never writes.
#
# Usage:
#   sh test/diff_compiler_error_quality_baseline.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CHECK=1 sh "$ROOT/test/error_quality_fixtures/capture.sh"
