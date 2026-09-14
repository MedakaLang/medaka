#!/bin/sh
# test/lsp_warm_session.sh — the LSP property that needs a LIVE session.
#
# Invoked BY another gate, never by a workflow: `test/diff_compiler_lsp_test.mdk`
# spawns this and grades its exit code and transcript, so its verdict reaches CI
# through THAT registry row. It GRADES, so it is not a CI-COVERAGE-TOOLS.txt
# entry (those claim "running me proves nothing about the compiler"); it is
# ledgered in `test/CI-COVERAGE-EXCEPTIONS.txt`, which records why no workflow
# step names it.
#
# Every other LSP property is one framed request stream in and one framed
# response stream out, which the native gate drives directly. This one is not:
# it drives ONE `medaka lsp` process through seven states of a three-module
# project, and two of those states rewrite an IMPORTED module ON DISK — edits
# that have to land BETWEEN messages of the same session. Medaka's only process
# extern is `runCommand`, which runs a command to completion with no stdin
# handle, so there is no native spelling of a session that writes, waits for a
# reply, and writes again.
#
# The property is warm-equals-cold. Every other LSP check opens a buffer once,
# so nothing reaches the per-analyze prefix memos (the resolve chain in
# driver/diagnostics.mdk, the module chain in types/typecheck.mdk) on a HIT: a
# memo replaying a stale verdict would pass all of them and only show up in an
# editor. Here, after EACH state, the per-file diagnostics the server published
# must equal what `medaka check --json` reports for that same state from a COLD
# process. A hit that quietly replays the previous state's verdict fails in the
# direction that matters — the stale verdict is usually the CLEAN one.
#
# Usage: sh test/lsp_warm_session.sh
#   MEDAKA      the binary to drive (default: the one beside this tree)
#   MEDAKA_ROOT the tree it resolves its stdlib from
set -u
ROOT="${MEDAKA_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required to drive an interactive session"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
pass=0; fail=0

check() {
  if [ "$2" = "0" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$1"; fi
}

P6="$TMP/p6"
mkdir -p "$P6"
printf '[package]\nname = "p6"\nversion = "0.1.0"\n' > "$P6/medaka.toml"
perl -e 'alarm 300; exec @ARGV' -- python3 - "$MEDAKA" "$ROOT" "$P6" <<'PY'
import json, os, subprocess, sys

MEDAKA, ROOT, P6 = sys.argv[1], sys.argv[2], sys.argv[3]
ENTRY = os.path.join(P6, "main6.mdk")

BASE_OK = ("public export data Shape = Circle Int | Square Int\n\n"
           "export\nareaish : Shape -> Int\n"
           "areaish (Circle r) = r * r * 3\nareaish (Square s) = s * s\n\n"
           "export\nbump : Int -> Int\nbump n = n + 1\n")
# `bump` no longer exported: a resolve error only `mid` (its importer) can see.
BASE_BAD = BASE_OK.replace("export\nbump", "bump")
MID = ("import base.{Shape(..), areaish, bump}\n\n"
       "export\ntotal : List Shape -> Int\n"
       "total ss = fold (acc => s => acc + areaish s) 0 ss\n\n"
       "export\ntagOf : Shape -> Int\ntagOf s = bump (areaish s)\n")
ENTRY_OK = ("import mid.{total, tagOf}\nimport base.{Shape(..)}\n\n"
            "shapes : List Shape\nshapes = [Circle 1, Square 2]\n\n"
            "main = println (intToString (total shapes))\n")
ENTRY_BAD = ENTRY_OK.replace("(total shapes)", '(total "not a list")')

# (label, entry text, base text) — the leaf changes on every step, as an editor
# would drive it; base changes only at steps 4 and 5.
STATES = [
    ("open",             ENTRY_OK,                 BASE_OK),
    ("leaf-keystroke",   ENTRY_OK + "-- k1\n",     BASE_OK),
    ("leaf-type-error",  ENTRY_BAD + "-- k2\n",    BASE_OK),
    ("leaf-cleared",     ENTRY_OK + "-- k3\n",     BASE_OK),
    ("import-broken",    ENTRY_OK + "-- k4\n",     BASE_BAD),
    ("import-still-bad", ENTRY_OK + "-- k5\n",     BASE_BAD),
    ("import-cleared",   ENTRY_OK + "-- k6\n",     BASE_OK),
]

open(os.path.join(P6, "mid.mdk"), "w").write(MID)


def frame(o):
    b = json.dumps(o, separators=(",", ":")).encode()
    return b"Content-Length: %d\r\n\r\n" % len(b) + b


class Sess:
    def __init__(self):
        env = dict(os.environ, MEDAKA_ROOT=ROOT)
        self.p = subprocess.Popen([MEDAKA, "lsp"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  env=env)
        self.buf = b""
        self.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                   "params": {"processId": None, "rootUri": "file://" + P6,
                              "capabilities": {}}})
        self.pump(1)
        self.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

    def send(self, o):
        self.p.stdin.write(frame(o))
        self.p.stdin.flush()

    def one(self):
        while b"\r\n\r\n" not in self.buf:
            c = self.p.stdout.read(1)
            if not c:
                return None
            self.buf += c
        head, rest = self.buf.split(b"\r\n\r\n", 1)
        n = int([h for h in head.split(b"\r\n")
                 if h.lower().startswith(b"content-length")][0].split(b":")[1])
        while len(rest) < n:
            c = self.p.stdout.read(n - len(rest))
            if not c:
                return None
            rest += c
        self.buf = rest[n:]
        return json.loads(rest[:n].decode())

    def pump(self, wait_id):
        """Read until the reply to `wait_id`; collect publishes seen on the way."""
        pubs = []
        while True:
            o = self.one()
            if o is None:
                return pubs
            if o.get("method") == "textDocument/publishDiagnostics":
                pubs.append(o["params"])
            if o.get("id") == wait_id:
                return pubs


def norm(uri_diag_pairs):
    out = {}
    for uri, diags in uri_diag_pairs:
        out[os.path.basename(uri)] = sorted(
            (d.get("severity"), d["range"]["start"]["line"],
             d["range"]["start"]["character"], d.get("message", ""))
            for d in diags)
    return out


def cold(entry_text, base_text):
    open(ENTRY, "w").write(entry_text)
    open(os.path.join(P6, "base.mdk"), "w").write(base_text)
    r = subprocess.run([MEDAKA, "check", "--json", ENTRY],
                       capture_output=True, text=True,
                       env=dict(os.environ, MEDAKA_ROOT=ROOT))
    j = json.loads(r.stdout)
    return norm((f["file"], f["diagnostics"]) for f in j.get("files", []))


bad = []
s = Sess()
for i, (label, entry_text, base_text) in enumerate(STATES):
    open(ENTRY, "w").write(entry_text)
    open(os.path.join(P6, "base.mdk"), "w").write(base_text)
    if i == 0:
        s.send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                "params": {"textDocument": {"uri": "file://" + ENTRY,
                                            "languageId": "medaka", "version": 1,
                                            "text": entry_text}}})
    else:
        s.send({"jsonrpc": "2.0", "method": "textDocument/didChange",
                "params": {"textDocument": {"uri": "file://" + ENTRY,
                                            "version": i + 1},
                           "contentChanges": [{"text": entry_text}]}})
    # A round-trip request after the notification: its reply cannot be written
    # before the analyze the notification triggered has published.
    s.send({"jsonrpc": "2.0", "id": 900 + i, "method": "textDocument/documentSymbol",
            "params": {"textDocument": {"uri": "file://" + ENTRY}}})
    warm = norm((p["uri"], p["diagnostics"]) for p in s.pump(900 + i))
    want = cold(entry_text, base_text)
    if warm != want:
        bad.append("  %s: warm=%s cold=%s" % (label, warm, want))
s.send({"jsonrpc": "2.0", "id": 999, "method": "shutdown", "params": {}})
s.send({"jsonrpc": "2.0", "method": "exit", "params": {}})
s.p.stdin.close()
s.p.wait()

# The states must not all be clean, or "warm == cold" is satisfied by publishing
# nothing: assert the two error states actually produced diagnostics COLD.
if not any(any(v for v in cold(e, b).values()) for (_l, e, b) in STATES[2:3] + STATES[4:5]):
    bad.append("  the error states produced no diagnostics at all — fixture is inert")
for line in bad:
    sys.stderr.write(line + "\n")
sys.exit(1 if bad else 0)
PY
check "multi-module project, 7 didChange states → warm publishes == cold check --json each time" "$?"

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
