#!/bin/sh
# Regenerate pds/lib/lexicon_schemas.mdk from the committed Lexicon answer key
# pds/test/vectors/lexicon_schemas.json, formatted by this tree's `medaka fmt`
# (so `make medaka` first). `--check` regenerates into a scratch directory and
# compares instead of writing.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
MODE=write
if [ "${1:-}" = "--check" ]; then MODE=check; fi
SCHEMAS="$ROOT/pds/test/vectors/lexicon_schemas.json"
TARGET="$ROOT/pds/lib/lexicon_schemas.mdk"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-lexicon-schemas.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

python3 "$HERE/gen_lexicon_schemas.py" "$SCHEMAS" "$WORK/lexicon_schemas.mdk"
"$ROOT/medaka" fmt --write "$WORK/lexicon_schemas.mdk" >/dev/null

if [ "$MODE" = check ]; then
  cmp "$WORK/lexicon_schemas.mdk" "$TARGET"
  echo "gen_lexicon_schemas: CHECK PASS"
else
  cp "$WORK/lexicon_schemas.mdk" "$TARGET"
  echo "gen_lexicon_schemas: wrote $TARGET"
fi
