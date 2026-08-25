#!/usr/bin/env bash
# Floor CI check for the mq/ project (#1933 coverage half): proves
# `./medaka check mq/main.mdk` stays green so this manifest-bearing project
# is not silently unenrolled from CI. No doctests/`test "…"` decls exist in
# this project today, so this script runs `check` only — add a `medaka
# test` invocation here if that ever changes.
set -u

ROOT="${MEDAKA_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
export MEDAKA_ROOT="$ROOT"

[ -x "$MEDAKA" ] || { echo "FAIL: no native medaka at $MEDAKA (build it first)"; exit 1; }

"$MEDAKA" check "$ROOT/mq/main.mdk" || { echo "FAIL: mq/main.mdk failed check"; exit 1; }

echo "OK: mq/test/check.sh"
