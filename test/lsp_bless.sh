#!/bin/sh
# test/lsp_bless.sh — re-mints the goldens `test/diff_compiler_lsp_test.mdk`
# reads.
#
# A TOOL, not a gate: it only ever WRITES, so it grades nothing and is ledgered
# in `test/CI-COVERAGE-TOOLS.txt` rather than carrying a registry row. The gate
# that reads these goldens is `test/diff_compiler_lsp_test.mdk`, and its last
# test holds the list below to the one those rows read, so a golden cannot lose
# its re-mint path in silence.
#
# 🚨 A captured golden records what the server DID, not what is correct. Three
# of these have an independent oracle and seven do not:
#
#   check_{clean,err,project}.json  `medaka check --json` over the same source —
#                                   a DIFFERENT code path, so a disagreement
#                                   between it and the LSP is real signal.
#   b3_fmt.txt                      `medaka fmt --stdout` over the same source —
#                                   likewise independent of the LSP.
#   b3_sym_def_hl.ndjson, b4_*      raw protocol dumps of the server under test.
#                                   Blessing one is tautological: read the diff
#                                   and decide from the protocol whether the new
#                                   answer is right, because nothing else will.
#
# Usage:
#   sh test/lsp_bless.sh                 re-mint every golden
#   sh test/lsp_bless.sh b4_hover.ndjson b4_inlay.ndjson
#                                        re-mint only the named ones
#
set -u
ROOT="${MEDAKA_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
GOLD="$ROOT/test/lsp_goldens"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required to frame and decode JSON-RPC"; exit 2; }

# The goldens this tool mints, one per line. The gate compares this list to the
# goldens its rows read, so the two stay one set; `wanted` reads it too, which
# is what makes a mistyped argument an error rather than a silent no-op.
golden_table() {
  cat <<'EOF'
# ── GOLDEN TABLE BEGIN
check_clean.json
check_err.json
check_project.json
b3_fmt.txt
b3_sym_def_hl.ndjson
b4_compl.ndjson
b4_compl_full.ndjson
b4_hover.ndjson
b4_hover_off.ndjson
b4_inlay.ndjson
# ── GOLDEN TABLE END
EOF
}

for arg in "$@"; do
  if ! golden_table | grep -qx "$arg"; then
    echo "no such golden: $arg" >&2
    golden_table | grep -v '^#' | sed 's/^/  /' >&2
    exit 1
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
wrote=0

# Was this golden asked for?  No arguments means all of them.
wanted() {
  [ "$#" -eq 1 ] && return 0
  name="$1"; shift
  for a in "$@"; do [ "$a" = "$name" ] && return 0; done
  return 1
}

bounded() { perl -e 'alarm 180; exec @ARGV' -- "$@"; }

# The two halves of the protocol, kept as files rather than inline heredocs so
# each can read the PIPE as its stdin.
cat > "$TMP/frame.py" <<'PY'
import sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    b = line.encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(b))
    sys.stdout.buffer.write(b)
PY

cat > "$TMP/decode.py" <<'PY'
import sys, json, os


def stab(o):
    if isinstance(o, dict):
        return {k: stab(v) for k, v in o.items()}
    if isinstance(o, list):
        return [stab(x) for x in o]
    if isinstance(o, str) and o.startswith("file://"):
        return "file:///" + os.path.basename(o)
    return o


data = open(sys.argv[1], "rb").read()
i = 0
while i < len(data):
    head = b"Content-Length: "
    if not data.startswith(head, i):
        break
    j = i + len(head)
    k = j
    while k < len(data) and data[k:k + 1].isdigit():
        k += 1
    n = int(data[j:k])
    body = data[k + 4:k + 4 + n]
    print(json.dumps(stab(json.loads(body.decode("utf-8"))), sort_keys=True))
    i = k + 4 + n
PY

# Frame every message on stdin (one compact JSON object per line), drive one
# `medaka lsp` over the result, and write the decoded responses to
# $TMP/out.ndjson as one canonical JSON object per line -- sorted keys,
# `file://` uris reduced to a basename, so a golden carries no build path and no
# dictionary order.
drive() {
  python3 "$TMP/frame.py" > "$TMP/in.bin"
  MEDAKA_ROOT="$ROOT" bounded "$MEDAKA" lsp < "$TMP/in.bin" > "$TMP/out.bin" 2>/dev/null
  python3 "$TMP/decode.py" "$TMP/out.bin" > "$TMP/out.ndjson"
  # An empty dump is never a golden: the session produced no response frames.
  [ -s "$TMP/out.ndjson" ] || { echo "the session produced no response frames" >&2; exit 1; }
}

# Persist $TMP/out.ndjson (or a named file) as a golden, and say so.
finish() {
  cp "$2" "$GOLD/$1"
  wrote=$((wrote + 1))
  printf 'BLESSED test/lsp_goldens/%s\n' "$1"
}

# ── check --json goldens: an independent oracle over the same source ─────────

if wanted check_clean.json "$@"; then
  printf 'main = println "hi"\n' > "$TMP/clean.mdk"
  MEDAKA_ROOT="$ROOT" bounded "$MEDAKA" check --json "$TMP/clean.mdk" 2>/dev/null \
    | sed "s|$TMP/||g" > "$TMP/g"
  finish check_clean.json "$TMP/g"
fi

if wanted check_err.json "$@"; then
  printf 'main = 1 + "x"\n' > "$TMP/err.mdk"
  MEDAKA_ROOT="$ROOT" bounded "$MEDAKA" check --json "$TMP/err.mdk" 2>/dev/null \
    | sed "s|$TMP/||g" > "$TMP/g"
  finish check_err.json "$TMP/g"
fi

if wanted check_project.json "$@"; then
  PROJ="$TMP/proj"
  mkdir -p "$PROJ"
  printf 'export double : Int -> Int\ndouble x = x + x\n' > "$PROJ/lib_clean.mdk"
  printf 'import lib_clean.{double}\n\nexport oops : Int\noops = double "no"\n' > "$PROJ/lib_bad.mdk"
  printf 'import lib_clean.{double}\nimport lib_bad.{oops}\n\nmain = println (double 21)\n' > "$PROJ/main_app.mdk"
  # Every file under $PROJ, not just the entry, needs its directory stripped for
  # a golden that is byte-stable across machines.
  MEDAKA_ROOT="$ROOT" bounded "$MEDAKA" check --json "$PROJ/main_app.mdk" 2>/dev/null \
    | sed "s|$PROJ/||g" > "$TMP/g"
  finish check_project.json "$TMP/g"
fi

# ── fmt golden: likewise an independent oracle ──────────────────────────────

if wanted b3_fmt.txt "$@"; then
  printf 'main   =   println    "hi"\n\n\n' > "$TMP/unfmt.mdk"
  MEDAKA_ROOT="$ROOT" bounded "$MEDAKA" fmt --stdout "$TMP/unfmt.mdk" 2>/dev/null > "$TMP/g"
  finish b3_fmt.txt "$TMP/g"
fi

# ── protocol dumps: the server under test, captured ─────────────────────────
# Each block is the SAME session the gate's row of that name drives. A session
# spelled wrong here mints a golden the gate then rejects, so these copies
# cannot drift apart quietly.

B3_SRC='data Point = { x : Int, y : Int }\n\ndata Shape = Circle Int | Square Int\n\narea s = match s\n  Circle r => r * r\n  Square w => w * w\n'
B4_SRC='double x = x + x\ntriple : Int -> Int\ntriple x = x * 3\nresult = double 5\nexport quad x = x * 4\n'
B4_NAMES='alpha = 1\nbeta = 2\n\n'
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
INITED='{"jsonrpc":"2.0","method":"initialized","params":{}}'
EXIT='{"jsonrpc":"2.0","method":"exit","params":{}}'

didopen() { # uri, JSON-escaped text
  printf '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"%s","languageId":"medaka","version":1,"text":"%s"}}}\n' "$1" "$2"
}

if wanted b3_sym_def_hl.ndjson "$@"; then
  {
    printf '%s\n%s\n' "$INIT" "$INITED"
    didopen 'file:///s.mdk' "$B3_SRC"
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///s.mdk"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///s.mdk"},"position":{"line":4,"character":0}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"textDocument/documentHighlight","params":{"textDocument":{"uri":"file:///s.mdk"},"position":{"line":4,"character":0}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":9,"method":"shutdown","params":{}}'
    printf '%s\n' "$EXIT"
  } | drive
  finish b3_sym_def_hl.ndjson "$TMP/out.ndjson"
fi

if wanted b4_hover.ndjson "$@"; then
  {
    printf '%s\n' "$INIT"
    didopen 'file:///b4.mdk' "$B4_SRC"
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///b4.mdk"},"position":{"line":0,"character":2}}}'
    printf '%s\n' "$EXIT"
  } | drive
  finish b4_hover.ndjson "$TMP/out.ndjson"
fi

if wanted b4_hover_off.ndjson "$@"; then
  {
    printf '%s\n' "$INIT"
    didopen 'file:///b4.mdk' "$B4_SRC"
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///b4.mdk"},"position":{"line":0,"character":9}}}'
    printf '%s\n' "$EXIT"
  } | drive
  finish b4_hover_off.ndjson "$TMP/out.ndjson"
fi

if wanted b4_compl.ndjson "$@"; then
  {
    printf '%s\n' "$INIT"
    didopen 'file:///b4.mdk' "$B4_SRC"
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///b4.mdk"},"position":{"line":3,"character":13}}}'
    printf '%s\n' "$EXIT"
  } | drive
  finish b4_compl.ndjson "$TMP/out.ndjson"
fi

if wanted b4_compl_full.ndjson "$@"; then
  {
    printf '%s\n' "$INIT"
    didopen 'file:///b4b.mdk' "$B4_NAMES"
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///b4b.mdk"},"position":{"line":2,"character":0}}}'
    printf '%s\n' "$EXIT"
  } | drive
  finish b4_compl_full.ndjson "$TMP/out.ndjson"
fi

if wanted b4_inlay.ndjson "$@"; then
  {
    printf '%s\n' "$INIT"
    didopen 'file:///b4.mdk' "$B4_SRC"
    printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///b4.mdk"},"range":{"start":{"line":0,"character":0},"end":{"line":10,"character":0}}}}'
    printf '%s\n' "$EXIT"
  } | drive
  finish b4_inlay.ndjson "$TMP/out.ndjson"
fi

# A run that wrote nothing must not look like a successful re-mint.
if [ "$wrote" -eq 0 ]; then
  echo "no golden matched $* — see the GOLDEN TABLE at the top of this file" >&2
  exit 1
fi
printf '\n%d golden(s) re-minted. Read the diff before committing: a dump of the\nserver under test is not evidence that the server is right.\n' "$wrote"
