#!/bin/sh
# test/diff_compiler_lsp.sh — differential gate for the self-hosted LSP
# (Stage 4 Phase B.10, slices B.10.0 + B.10.1).
#
# Drives compiler/entries/lsp_main.mdk with hand-framed Content-Length JSON-RPC requests
# on stdin and checks the framed JSON responses against the OCaml reference:
#
#   • initialize          — the response is a well-formed JSON-RPC result whose
#                           capabilities advertise textDocumentSync (B.10 only
#                           implements sync+diagnostics; hover/completion/etc.
#                           are later slices and are NOT advertised here, so we
#                           assert the known B.10 shape rather than diffing the
#                           full OCaml capability set, which includes providers
#                           B.10 does not implement).
#   • didOpen (clean)     — publishDiagnostics with an empty diagnostics array,
#                           matching `medaka check --json` (no diagnostics).
#   • didOpen (type err)  — publishDiagnostics carrying one Error diagnostic
#                           (severity 1, source "medaka"), matching the
#                           single-diagnostic shape of `check --json`.  B.10.2b:
#                           the diagnostic now carries an EXPR-LEVEL range from
#                           the ELoc substrate — this gate asserts its START
#                           position matches the OCaml LSP's expr range exactly.
#
# Message TEXT is intentionally NOT diffed (unification order differs from the
# oracle — the documented compiler limitation, cf. diff_compiler_diagnostics.sh).
#
# RANGE (B.10.2b): the start position is asserted to match the OCaml LSP's
# expr-level range exactly.  The END position is an APPROXIMATION: the compiler
# parser derives a token span from token START offsets (`locOfSpan`), so a
# single-token expr yields an empty span (end == start) where OCaml's `$endpos`
# reaches the token's end.  True end positions need token lengths threaded
# through the lexer's layout pass (a cross-cutting lexer change deferred here);
# the start — the position editors anchor a squiggle at — is exact.
#
# The three committed goldens this gate reads (check_clean/check_err/
# check_project.json) are NOT raw LSP protocol dumps — they are `medaka check
# --json` output on the SAME fixture, i.e. a cross-check against a DIFFERENT
# native code path, not a self-referential capture. Despite predating OCaml
# removal, they need no "live" session to re-mint: CAPTURE=1 sh
# test/diff_compiler_lsp.sh regenerates all three from the current native
# `./medaka check --json` (#621).
#
# Usage: sh test/diff_compiler_lsp.sh
#   CAPTURE=1 sh test/diff_compiler_lsp.sh   — re-mint check_{clean,err,project}.json
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# OCaml-free: drive the CANONICAL native LSP (the shipped binary, same one Cursor
# uses) and diff vs committed goldens captured from the OCaml `check --json`
# oracle (test/capture_goldens.sh, OCaml trusted at capture time).
MEDAKA="$ROOT/medaka"
GOLD="$ROOT/test/lsp_goldens"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
pass=0; fail=0
CAPTURE="${CAPTURE:-0}"

# capture_or_load <golden-path> <fixture.mdk> : in CAPTURE mode, overwrite the
# golden with `medaka check --json <fixture>` (cross-checks the check --json
# code path, NOT a self-referential capture off the LSP server this gate
# tests); either way, print the (possibly just-refreshed) golden's contents.
# The fixture's absolute $TMP path is replaced by its bare basename (matching
# the pre-existing goldens' convention) so a re-capture is byte-stable across
# runs/machines instead of baking in a fresh mktemp path every time.
capture_or_load() {
  golden="$1"; fixture="$2"
  if [ "$CAPTURE" = 1 ]; then
    MEDAKA_ROOT="$ROOT" perl -e 'alarm 60; exec @ARGV' -- "$MEDAKA" check --json "$fixture" 2>/dev/null \
      | sed "s|$fixture|$(basename "$fixture")|g" > "$golden"
    printf 'CAPTURE %s\n' "$golden" >&2
  fi
  cat "$golden"
}

# Frame a JSON string as a Content-Length JSON-RPC packet (byte-accurate length).
frame() {
  python3 - "$1" <<'PY'
import sys
b = sys.argv[1].encode("utf-8")
sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(b))
sys.stdout.buffer.write(b)
PY
}

# Run the compiler LSP over a framed stdin stream (built from the JSON messages
# passed as args), capture stdout, and split it into one JSON object per frame.
# Writes the decoded JSON objects (one per line) to $TMP/out.json.
drive_lsp() {
  : > "$TMP/in.bin"
  for msg in "$@"; do frame "$msg" >> "$TMP/in.bin"; done
  perl -e 'alarm 180; exec @ARGV' \
    env MEDAKA_ROOT="$ROOT" "$MEDAKA" lsp < "$TMP/in.bin" > "$TMP/out.bin" 2>/dev/null
  python3 - "$TMP/out.bin" > "$TMP/out.json" <<'PY'
import sys, re, json
data = open(sys.argv[1], "rb").read()
# Split into frames on the Content-Length header; emit each body as compact JSON.
parts = re.split(rb"Content-Length: \d+\r\n\r\n", data)
for p in parts:
    p = p.strip()
    if not p:
        continue
    # A frame body is exactly one JSON object; trailing bytes belong to the next
    # frame's header which the split already consumed, so decode greedily.
    dec = json.JSONDecoder()
    idx = 0
    s = p.decode("utf-8")
    while idx < len(s):
        s2 = s[idx:].lstrip()
        if not s2:
            break
        try:
            obj, end = dec.raw_decode(s2)
        except ValueError:
            break
        # Skip non-object tokens (the native CLI prints a trailing Unit `0` after
        # the framed responses; LSP messages are always JSON objects).
        if isinstance(obj, dict):
            print(json.dumps(obj))
        idx += len(s[idx:]) - len(s2) + end
PY
}

check() { # desc, condition (already evaluated to 0/1 via test)
  if [ "$2" = "0" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$1"; fi
}

# ── 1. initialize handshake ─────────────────────────────────────────────────
drive_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"exit","params":{}}'
python3 - "$TMP/out.json" <<'PY'
import sys, json
objs = [json.loads(l) for l in open(sys.argv[0+1]) if l.strip()]
init = next((o for o in objs if o.get("id") == 1), None)
ok = (init is not None
      and init.get("jsonrpc") == "2.0"
      and "result" in init
      and "textDocumentSync" in init["result"]["capabilities"]
      and init["result"]["serverInfo"]["name"] == "medaka-lsp")
sys.exit(0 if ok else 1)
PY
check "initialize → jsonrpc result with textDocumentSync capability" "$?"

# ── 2. didOpen a CLEAN file → empty diagnostics (matches check --json) ───────
CLEAN='main = println "hi"\n'
printf 'main = println "hi"\n' > "$TMP/clean.mdk"
ORACLE_CLEAN="$(capture_or_load "$GOLD/check_clean.json" "$TMP/clean.mdk")"
drive_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///clean.mdk","text":"main = println \"hi\"\n"}}}' \
  '{"jsonrpc":"2.0","method":"exit","params":{}}'
python3 - "$TMP/out.json" "$ORACLE_CLEAN" <<'PY'
import sys, json
objs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
pub = next((o for o in objs if o.get("method") == "textDocument/publishDiagnostics"), None)
oracle = json.loads(sys.argv[2])
oracle_diags = oracle["files"][0]["diagnostics"] if oracle.get("files") else []
ok = (pub is not None
      and pub["params"]["diagnostics"] == []
      and oracle_diags == [])
sys.exit(0 if ok else 1)
PY
check "didOpen clean → publishDiagnostics [] (== check --json)" "$?"

# ── 3. didOpen a TYPE-ERROR file → one Error diagnostic ─────────────────────
printf 'main = 1 + "x"\n' > "$TMP/err.mdk"
ORACLE_ERR="$(capture_or_load "$GOLD/check_err.json" "$TMP/err.mdk")"
drive_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///err.mdk","text":"main = 1 + \"x\"\n"}}}' \
  '{"jsonrpc":"2.0","method":"exit","params":{}}'
python3 - "$TMP/out.json" "$ORACLE_ERR" <<'PY'
import sys, json
objs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
pub = next((o for o in objs if o.get("method") == "textDocument/publishDiagnostics"), None)
oracle = json.loads(sys.argv[2])
od = oracle["files"][0]["diagnostics"]
if pub is None:
    sys.exit(1)
sd = pub["params"]["diagnostics"]
# Structural parity: same count, same first-diagnostic severity + source.
# (message text diverges by design — unification order — see header.)
struct_ok = (len(sd) == len(od) == 1
      and sd[0]["severity"] == od[0]["severity"] == 1
      and sd[0]["source"] == od[0]["source"] == "medaka"
      and "range" in sd[0] and "message" in sd[0])
# B.10.2b: expr-level RANGE.  The START position must match the OCaml LSP's
# expr-level range exactly (the ELoc substrate captures the same span).  The END
# position is an approximation (token-START-derived span → empty span); we assert
# only that it is well-formed and does not precede the start, and that it is on
# the same line as OCaml's end (documented $endpos gap — see header).
sr, oj = sd[0]["range"], od[0]["range"]
start_ok = (sr["start"] == oj["start"])
end_ok = (sr["end"] == oj["end"])
if not start_ok:
    sys.stderr.write("RANGE START mismatch: self=%s oracle=%s\n" % (sr["start"], oj["start"]))
if not end_ok:
    sys.stderr.write("RANGE END mismatch: self=%s oracle=%s\n" % (sr["end"], oj["end"]))
ok = struct_ok and start_ok and end_ok
sys.exit(0 if ok else 1)
PY
check "didOpen type-error → one Error diagnostic; expr-range START and END == check --json" "$?"

# ── 4. didChange replaces a clean buffer with an error one ──────────────────
drive_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///d.mdk","text":"main = println \"hi\"\n"}}}' \
  '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///d.mdk"},"contentChanges":[{"text":"main = 1 + \"x\"\n"}]}}' \
  '{"jsonrpc":"2.0","method":"exit","params":{}}'
python3 - "$TMP/out.json" <<'PY'
import sys, json
objs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
pubs = [o for o in objs if o.get("method") == "textDocument/publishDiagnostics"]
# Two publishes: didOpen (clean → []) then didChange (error → 1 diagnostic).
ok = (len(pubs) == 2
      and pubs[0]["params"]["diagnostics"] == []
      and len(pubs[1]["params"]["diagnostics"]) == 1
      and pubs[1]["params"]["diagnostics"][0]["severity"] == 1)
sys.exit(0 if ok else 1)
PY
check "didChange clean→error → republish with one diagnostic" "$?"

# ── 5. B.10.5: project-wide didOpen → one publish PER graph file ─────────────
# A multi-file project (entry imports a clean sibling + a sibling with a type
# error).  Opening the entry triggers analyzeProject: one publishDiagnostics per
# file in the import graph, the bad file carrying its diagnostic WITHOUT blanking
# the clean files (the "bad import doesn't sink the batch" property).  The entry's
# absolute file:// uri drives project_dir = its directory (the loader root); the
# read override is only needed for the entry (its siblings are read from disk).
PROJ="$TMP/proj"
mkdir -p "$PROJ"
printf 'export double : Int -> Int\ndouble x = x + x\n' > "$PROJ/lib_clean.mdk"
printf 'import lib_clean.{double}\n\nexport oops : Int\noops = double "no"\n' > "$PROJ/lib_bad.mdk"
printf 'import lib_clean.{double}\nimport lib_bad.{oops}\n\nmain = println (double 21)\n' > "$PROJ/main_app.mdk"
ENTRY_TXT="$(python3 -c 'import json,sys;print(json.dumps(open(sys.argv[1]).read()))' "$PROJ/main_app.mdk")"
# Oracle: medaka check --json over the same entry (the real analyze_project).
# (Not routed through capture_or_load: a project has multiple files under
# $PROJ, so ALL of them — not just the entry — need their absolute dir
# stripped for a byte-stable golden.)
if [ "$CAPTURE" = 1 ]; then
  MEDAKA_ROOT="$ROOT" perl -e 'alarm 60; exec @ARGV' -- "$MEDAKA" check --json "$PROJ/main_app.mdk" 2>/dev/null \
    | sed "s|$PROJ/||g" > "$GOLD/check_project.json"
  printf 'CAPTURE %s\n' "$GOLD/check_project.json" >&2
fi
ORACLE_PROJ="$(cat "$GOLD/check_project.json")"
drive_lsp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://$PROJ/main_app.mdk\",\"text\":$ENTRY_TXT}}}" \
  '{"jsonrpc":"2.0","method":"exit","params":{}}'
python3 - "$TMP/out.json" "$ORACLE_PROJ" <<'PY'
import sys, json, os
objs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
pubs = [o for o in objs if o.get("method") == "textDocument/publishDiagnostics"]
# compiler: {basename: [(sev, msg, start)]}
self = {}
for p in pubs:
    base = os.path.basename(p["params"]["uri"])
    self[base] = [(d["severity"], d["message"], (d["range"]["start"]["line"], d["range"]["start"]["character"]))
                  for d in p["params"]["diagnostics"]]
# oracle: same shape from analyze_project's files array
oracle = {}
oj = json.loads(sys.argv[2])
for f in oj["files"]:
    base = os.path.basename(f["file"])
    oracle[base] = [(d["severity"], d["message"], (d["range"]["start"]["line"], d["range"]["start"]["character"]))
                    for d in f["diagnostics"]]
# One publish per graph file; same file set.
if set(self) != set(oracle):
    sys.stderr.write("FILE SET: self=%s oracle=%s\n" % (sorted(self), sorted(oracle)))
    sys.exit(1)
ok = True
for base in oracle:
    o = sorted(oracle[base]); s = sorted(self[base])
    # severity + start must match exactly; message matches here (stable type msg).
    o_key = sorted((sev, st) for (sev, _m, st) in oracle[base])
    s_key = sorted((sev, st) for (sev, _m, st) in self[base])
    if o_key != s_key:
        sys.stderr.write("  %s: (sev,start) mismatch self=%s oracle=%s\n" % (base, s_key, o_key))
        ok = False
# Explicitly: the clean siblings are [], the bad one is non-empty.
if self.get("lib_clean.mdk") != [] or self.get("main_app.mdk") != []:
    sys.stderr.write("clean files not blank: %s\n" % self); ok = False
if not self.get("lib_bad.mdk"):
    sys.stderr.write("bad file blanked: %s\n" % self); ok = False
sys.exit(0 if ok else 1)
PY
check "project didOpen → per-file publishDiagnostics (== check --json; bad import doesn't blank clean files)" "$?"


# ── 6. multi-module project through repeated didChange (the WARM chain path) ──
# Every other case above opens a buffer once, so nothing here reached the
# per-analyze prefix memos (the resolve chain in driver/diagnostics.mdk and the
# module chain in types/typecheck.mdk) on a HIT: a memo that replayed a stale
# verdict would pass all five and only show up in an editor.
#
# One `medaka lsp` process is driven through a sequence of states of a 3-module
# project — leaf keystrokes, a type error introduced into the leaf and cleared,
# and an IMPORTED module rewritten ON DISK to introduce a resolve error only its
# dependents can see and then to clear it — and after EACH state the published
# per-file diagnostics must equal `medaka check --json` on the same state from a
# COLD process.  Warm-equals-cold is the property; a hit that quietly replays the
# previous state's verdict fails it in the direction that matters ([W-QUIETER]:
# the stale verdict is usually the CLEAN one).
#
# Driven from python rather than through `drive_lsp` because the disk edits have
# to land BETWEEN messages, which a single pre-framed stdin stream cannot do.
P6="$TMP/p6"
mkdir -p "$P6"
printf '[package]\nname = "p6"\nversion = "0.1.0"\n' > "$P6/medaka.toml"
python3 - "$MEDAKA" "$ROOT" "$P6" <<'PY'
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
