"""Mechanical verdict on one converted gate-test, so the orchestrator does not read it.

Usage:
    python3 <repo>/.claude/skills/test-conversion-orchestrator/verify_conversion.py <repo> <repo-relative _test.mdk> [<repo-relative old script>]

Prints about ten lines, each OK, WARN or FAIL, and exits 1 on any FAIL. It runs
the file whole and block by block, lints it, and greps it for the shapes earlier
waves shipped by mistake. It does NOT judge whether every check of the script
was carried; that is the auditor's job. The old script is only used for a
check-count comparison (pass it before you delete the script, or a
`git show BASE:<path>` copy).
"""
import os
import re
import subprocess
import sys

if len(sys.argv) not in (3, 4):
    print(__doc__)
    sys.exit(2)
repo, rel = sys.argv[1], sys.argv[2]
script = sys.argv[3] if len(sys.argv) == 4 else None
medaka = os.path.join(repo, "medaka")
path = os.path.join(repo, rel)
src = open(path).read()
verdicts = []


def say(level, msg):
    verdicts.append(level)
    print(f"{level:4} {msg}")


def run(args):
    p = subprocess.run(args, capture_output=True, text=True, cwd=repo)
    return p.returncode, p.stdout + p.stderr


# Whole-file run.
code, out = run([medaka, "test", path])
summary = [l for l in out.splitlines() if re.search(r"\d+/\d+ passed", l)]
if code == 0 and summary:
    say("OK", "whole file: " + summary[-1].split(": ")[-1])
else:
    fails = [l.strip() for l in out.splitlines() if "FAIL" in l or "error" in l][:3]
    say("FAIL", f"whole file exit {code}: " + " | ".join(fails)[:300])

# Each block alone.
names = re.findall(r'^test "((?:[^"\\]|\\.)*)"', src, re.M)
alone_bad = []
for n in names:
    c, o = run([medaka, "test", "--filter", n, path])
    if c != 0:
        alone_bad.append(n)
if len(names) > 1:
    say("FAIL" if alone_bad else "OK", f"{len(names)} blocks alone" + (": red alone: " + "; ".join(alone_bad) if alone_bad else ": all green"))

# Lint and fmt.
c, o = run([medaka, "lint", path])
hits = [l.strip() for l in o.splitlines() if re.search(r":\d+:\d+:", l)] or [l.strip() for l in o.splitlines() if l.strip()]
if not hits:
    say("OK", "lint clean")
for h in hits[:10]:
    say("FAIL", "lint: " + h[:200])
c, o = run([medaka, "fmt", "--check", path])
say("OK" if c == 0 else "WARN", "fmt clean" if c == 0 else "fmt --check differs (run fmt --write)")

# Greps for shapes that hid bugs before.
def grep(pattern):
    return [i + 1 for i, l in enumerate(src.splitlines()) if re.search(pattern, l)]

checks = [
    (r"lint-disable", "FAIL", "lint suppression"),
    (r"(?<!with)(?<!\w)scratchDir\b", "FAIL", "bare scratchDir (shared by every block)"),
    (r"expectEqual 0 code", "WARN", "exit graded as expectEqual 0 code (gate verify wants `code /=`)"),
    (r"length \(lines ", "WARN", "length (lines ...) is 1 on empty text"),
    (r"expectAtLeast 1 \(", "WARN", "floor of 1 (should be today's count)"),
    (r"-- CONTINUE:", "FAIL", "CONTINUE marker left in (unfinished parts)"),
    (r"\b(boundedVerb\w*|runVerb|boundedInTree|expectSpawn\w*)\s+(\d+\s+)?\"(python3|grep|sed|awk)\"",
     "WARN", "spawns a text tool (native-rewrite should not)"),
]
for pat, level, msg in checks:
    hits = grep(pat)
    if hits:
        say(level, f"{msg} at line(s) {hits[:6]}")

spawns = grep(r"\b(boundedVerb|boundedVerbSeconds|runMedaka|boundedInTree|runVerb)\b")
graded = grep(r"code /=|code ==|expectSpawn|expectCheck")
if spawns and not graded:
    say("FAIL", f"spawns at lines {spawns[:4]} but no `code /=`/`code ==` grading")
enum = grep(r"\b(fixtureStems|fixtureFiles|fixtureDirs|walkDir)\b")
if enum and not grep(r"expectAtLeast|expectFloor"):
    say("FAIL", f"enumerates at lines {enum[:4]} with no floor")

# Check-count comparison (informational).
asserts = len(grep(r"\b(fail|expect[A-Z]\w*)\b"))
if script and os.path.isfile(os.path.join(repo, script)):
    s = open(os.path.join(repo, script)).read()
    sites = len(re.findall(r"\bFAIL\b|\bfail\b|exit 1", s))
    say("INFO", f"script fail sites {sites}; test blocks {len(names)}, assertion sites {asserts}")
else:
    say("INFO", f"test blocks {len(names)}, assertion sites {asserts}")

sys.exit(1 if "FAIL" in verdicts else 0)
