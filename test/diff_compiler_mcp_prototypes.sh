#!/bin/sh
# shell-because: external-harness The subject is the independent Python subprocess and installed artifact experiment.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
python3 "$root/scripts/mcp_bench/prototypes/protocol_test.py"
MEDAKA_STRICT=1 "$root/medaka" build "$root/scripts/mcp_bench/prototypes/installed_main.mdk" -o "$tmp/supervisor"
sh "$root/scripts/make_dist.sh" "$tmp"
tar -xzf "$tmp"/*.tar.gz -C "$tmp"
bundle=$(find "$tmp" -type d -name 'medaka-*' -prune)
python3 "$root/scripts/mcp_bench/prototypes/exercise.py" "$bundle" "$tmp/supervisor" "$root"
