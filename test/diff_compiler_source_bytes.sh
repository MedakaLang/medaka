#!/bin/sh
# diff_compiler_source_bytes.sh — no tracked source file may contain a raw C0 control byte.
#
# WHY THIS EXISTS. compiler/tools/printer.mdk carried a literal NUL byte for months.
# Nobody typed it: printer.mdk:258 must compare a char against NUL, so someone wrote
# `"\0"` — and `medaka fmt` ROUND-TRIPPED THAT ESCAPE BACK OUT AS A RAW NUL BYTE,
# because the formatter's string escaper handled \\ " \n \t \r and passed everything
# else through untouched. The formatter corrupted its own source, and then kept the
# corruption stable across every subsequent format.
#
# The damage is not cosmetic. A file containing a NUL is BINARY to grep:
#
#     $ grep -c printDecl compiler/tools/printer.mdk
#     $                      <- prints NOTHING, exits 1, on a file with 35 matches
#     $ grep -ac printDecl compiler/tools/printer.mdk
#     35
#
# No warning. Not even "Binary file matches". A confident, silent lie about a
# 1100-line compiler source, to every human and every agent that greps it. An agent
# hit exactly this and briefly concluded the function did not exist.
#
# So: this repo's defining bug class ("this didn't run" being indistinguishable from
# "this passed") had been planted IN THE SEARCH PATH by our own formatter.
#
# The escaper is fixed (printer.mdk escSOne + its twin util.mdk escOne now emit \0 and
# \u{XX} for every C0 char). This gate is the ratchet: it does not care HOW a control
# byte gets in — formatter, editor, bad merge, a paste — it just refuses to let one live
# in tracked source. That is the right shape, because the next corruption will arrive by
# a route nobody predicted.
#
# Allowed: \t (0x09) and \n (0x0a). Everything else in C0 (0x00-0x08, 0x0b-0x1f) is out.
# \r (0x0d) is out too: this tree is LF-only, and a stray CR is its own class of bug.
#
# Usage:  sh test/diff_compiler_source_bytes.sh
# Exit:   0 clean; 1 a tracked source file contains a raw control byte.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; exit 2; }

cd "$ROOT" || exit 1

python3 - <<'PY'
import subprocess, sys, pathlib

# Tracked files only — build outputs, the .ll seed, and test binaries are legitimately
# binary and are not source.
out = subprocess.run(['git', 'ls-files', '-z'], capture_output=True)
files = [f for f in out.stdout.decode().split('\0') if f]

# Source extensions we hold to this bar. Deliberately NOT everything git tracks:
# compiler/seed/emitter.ll.gz is gzip.
EXTS = {'.mdk', '.sh', '.md', '.toml', '.yml', '.yaml', '.c', '.h', '.py', '.mjs', '.js'}
ALLOWED = {0x09, 0x0a}                    # tab, newline
BAD = set(range(0x00, 0x20)) - ALLOWED    # includes 0x0d (CR): first-party source is LF-only

# FIRST-PARTY SOURCE ONLY. The excluded trees are excluded on purpose, not swept under
# a rug — a control byte in each of them is legitimate:
#
#   test/*_fixtures/, test/snapshots/, test/*_goldens/
#       Fixtures EXIST to carry hostile bytes. test/diff_fixtures/crlf.mdk is a file full
#       of CRLFs whose entire job is to prove the lexer handles CRLF; banning its CRs
#       would delete the test. The snapshots/goldens then faithfully mirror those bytes,
#       as they should.
#   playground/vendor/
#       Vendored third-party (CodeMirror). Not ours to reformat.
#
# The bar applies to what WE write and what our own formatter rewrites — which is exactly
# where the corruption came from.
def excluded(f):
    return (f.startswith('playground/vendor/')
            or f.startswith('test/snapshots/')
            or '_fixtures/' in f
            or '_goldens/' in f)

checked = 0
bad = []
for f in files:
    p = pathlib.Path(f)
    if p.suffix not in EXTS or excluded(f):
        continue
    try:
        b = p.read_bytes()
    except OSError:
        continue
    checked += 1
    for i, byte in enumerate(b):
        if byte in BAD:
            line = b[:i].count(b'\n') + 1
            bad.append((f, line, byte))
            break   # one report per file is enough to fail it

# NEVER PASS HAVING CHECKED NOTHING. A bad glob, a cwd surprise, or an empty
# `git ls-files` would otherwise print "0 files, clean" and exit 0 — which is the exact
# bug this gate is about.
if checked == 0:
    print("FAIL: this gate examined ZERO files — it proved nothing.")
    print("      Check the `git ls-files` call and the cwd. An empty scan is not a pass.")
    sys.exit(1)

if bad:
    print(f"FAIL: {len(bad)} tracked source file(s) contain a raw control byte:")
    for f, line, byte in bad:
        print(f"       {f}:{line}: byte 0x{byte:02x}")
    print()
    print("       A NUL makes the file BINARY to grep — it will silently match nothing.")
    print("       Write the escape (\\0, \\u{XX}) instead of the raw byte. If `medaka fmt`")
    print("       PUT it there, the string escaper has regressed: see printer.mdk escSOne")
    print("       and its twin util.mdk escOne, which must stay in lockstep.")
    sys.exit(1)

print(f"source bytes: {checked} tracked source files, 0 raw control bytes")
PY
