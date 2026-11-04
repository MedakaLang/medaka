#!/bin/sh
# shell-because: external-harness The subject is scripts/mcp_bench/prototypes/exercise.py and its installed subprocess experiment.
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

case $(uname -s) in
  Linux|Darwin) ;;
  *) echo "process replay: BLOCKED (Linux/macOS POSIX reference required)" >&2; exit 1 ;;
esac
python3 "$root/scripts/mcp_bench/prototypes/process_contract_probe.py" --out "$tmp/process" > "$tmp/process.log"
grep -F 'SIGCHLD-ignore: UnsupportedWaitOwnership before fork' "$tmp/process.log"
grep -F 'SIGCHLD-no-cldwait: UnsupportedWaitOwnership before fork' "$tmp/process.log"
grep -F 'lifecycle controls passed' "$tmp/process.log"
python3 "$root/scripts/mcp_bench/prototypes/process_readiness_probe.py" --out "$tmp/readiness" > "$tmp/readiness.log"
grep -F '"name": "strong_containment", "status": "BLOCKED"' "$tmp/readiness.log"
case $(uname -s) in
  Linux) grep -F 'EPIPE returned; original handler preserved; generated signal consumed' "$tmp/readiness.log" ;;
  Darwin) grep -F '"name": "sigpipe_mask_control", "status": "BLOCKED"' "$tmp/readiness.log" ;;
esac
grep -F 'Readiness controls passed; strong containment remains BLOCKED.' "$tmp/readiness.log"
