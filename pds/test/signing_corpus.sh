#!/bin/sh
# Offline S3-A signing/Wycheproof semantic gate. No expected value comes from Medaka.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
python3 "$ROOT/pds/tools/signing_corpus_check.py" "$ROOT"
