#!/bin/sh
# shell-because: external-harness The subject is scripts/mcp_bench/collect.py, a subprocess collector independent of the Medaka executable.
set -eu
cd "$(dirname "$0")/.."
python3 -m unittest discover -s scripts/mcp_bench -p '*_test.py'
