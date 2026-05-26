#!/usr/bin/env bash
# Phase 34 — sanity check that `medaka lsp` responds with diagnostics for a
# broken Medaka source.  Not part of `dune test` because it spawns the binary
# and pipes JSON-RPC through stdio (the harness can't reliably drive
# interactive processes per PLAN.md §2.2).
#
# Usage: dev/lsp_smoke.sh
# Exits 0 on success, non-zero with stderr explaining the failure.

set -euo pipefail

BIN=./_build/default/bin/main.exe
if [[ ! -x "$BIN" ]]; then
  echo "missing $BIN — run 'dune build' first" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Source with a deliberate Unbound variable so we expect at least one
# Error-severity diagnostic in the published list.
cat > "$TMP/in.txt" <<'PAYLOAD'
__INITIALIZE__
__OPEN_BROKEN__
__SHUTDOWN__
__EXIT__
PAYLOAD

py=$(command -v python3 || command -v python)
if [[ -z "$py" ]]; then
  echo "python required for the smoke driver" >&2
  exit 1
fi

OUT=$("$py" - <<'PY' "$BIN"
import json, struct, subprocess, sys

bin_path = sys.argv[1]

def frame(obj):
    body = json.dumps(obj).encode("utf-8")
    header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
    return header + body

msgs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"processId": None, "rootUri": None, "capabilities": {}}},
    {"jsonrpc": "2.0", "method": "initialized", "params": {}},
    {"jsonrpc": "2.0", "method": "textDocument/didOpen",
     "params": {"textDocument": {
        "uri": "file:///tmp/broken.mdk",
        "languageId": "medaka",
        "version": 1,
        "text": "f = nope\n"}}},
    {"jsonrpc": "2.0", "id": 2, "method": "shutdown"},
    {"jsonrpc": "2.0", "method": "exit"},
]

payload = b"".join(frame(m) for m in msgs)

proc = subprocess.run(
    [bin_path, "lsp"],
    input=payload, capture_output=True, timeout=10)

# Parse framed responses out of stdout.
data = proc.stdout
out_msgs = []
while data:
    idx = data.find(b"\r\n\r\n")
    if idx < 0: break
    header = data[:idx].decode("ascii")
    rest = data[idx+4:]
    length = None
    for line in header.split("\r\n"):
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    if length is None: break
    body = rest[:length]
    data = rest[length:]
    out_msgs.append(json.loads(body))

print(json.dumps(out_msgs, indent=2))
PY
)

echo "$OUT"

# Check for: a successful initialize result and a publishDiagnostics
# notification with at least one Error-severity diagnostic.
if ! echo "$OUT" | grep -q '"method": "textDocument/publishDiagnostics"'; then
  echo "FAIL: no publishDiagnostics notification" >&2
  exit 1
fi

if ! echo "$OUT" | grep -q '"severity": 1'; then
  echo "FAIL: no Error-severity diagnostic" >&2
  exit 1
fi

if ! echo "$OUT" | grep -qi 'unbound'; then
  echo "FAIL: diagnostic doesn't mention 'unbound'" >&2
  exit 1
fi

echo "OK: lsp smoke test passed"
