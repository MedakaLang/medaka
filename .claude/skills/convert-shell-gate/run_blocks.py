"""Run every `test "..."` block of one test file alone, to expose order dependence.

Usage:
    python3 <repo>/.claude/skills/convert-shell-gate/run_blocks.py <abs medaka binary> <abs _test.mdk>

Prints one line per block: its pass summary (or the failing lines) and its
name. A block that passes in the whole-file run but fails alone depends on
another block's side effects.
"""
import re
import subprocess
import sys

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)
medaka, path = sys.argv[1:]
names = re.findall(r'^test "((?:[^"\\]|\\.)*)"', open(path).read(), re.M)
if not names:
    sys.exit(f"{path}: no test blocks")
bad = 0
for name in names:
    p = subprocess.run([medaka, "test", "--filter", name, path], capture_output=True, text=True)
    out = p.stdout + p.stderr
    summary = [l for l in out.splitlines() if re.search(r"\d+/\d+ passed", l)]
    if p.returncode != 0 or not summary:
        bad += 1
        tail = " | ".join(l.strip() for l in out.splitlines() if "FAIL" in l or "error" in l)[:300]
        print(f"FAIL (exit {p.returncode})  <-  {name}  {tail}")
    else:
        print(f"{summary[-1].split(': ')[-1]}  <-  {name}")
sys.exit(1 if bad else 0)
