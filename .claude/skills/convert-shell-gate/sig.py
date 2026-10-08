"""Print stdlib signatures by name, from the generated docs/stdlib/inventory.json.

Usage (absolute paths; the repo root is found from this file's location):
    python3 <repo>/.claude/skills/convert-shell-gate/sig.py NAME [NAME...]
    python3 <repo>/.claude/skills/convert-shell-gate/sig.py -m MODULE   # every export of one module
    python3 <repo>/.claude/skills/convert-shell-gate/sig.py -s TEXT     # names containing TEXT

One line per hit: `module.name : signature`. Use it instead of grepping
stdlib sources or docs; it costs a few lines of context per lookup.
"""
import json
import os
import sys

root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
inventory = os.path.join(root, "docs", "stdlib", "inventory.json")
entries = json.load(open(inventory))


def show(e):
    sig = " ".join(e["signature"].split())
    if len(sig) > 200:
        sig = sig[:200] + " ..."
    print(f"{e['module']}.{e['name']} : {sig}")


args = sys.argv[1:]
if not args:
    print(__doc__)
    sys.exit(2)
if args[0] == "-m":
    hits = [e for e in entries if e["module"] in args[1:]]
elif args[0] == "-s":
    needles = [a.lower() for a in args[1:]]
    hits = [e for e in entries if any(n in e["name"].lower() for n in needles)]
else:
    hits = [e for e in entries if e["name"] in args]
for e in hits:
    show(e)
missing = [a for a in args if not a.startswith("-") and args[0] not in ("-m", "-s")
           and not any(e["name"] == a for e in hits)]
for a in missing:
    print(f"{a} : NOT IN STDLIB (try -s {a})")
