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


def methods(name):
    # Interface methods (`toList`, `map`, `length`) live inside their interface's entry.
    for e in entries:
        if e["signature"].startswith("interface "):
            for line in e["signature"].splitlines()[1:]:
                parts = line.strip().split(" : ", 1)
                if parts[0] == name and len(parts) == 2 and parts[1] != "_":
                    yield f"{e['module']}.{e['name']}.{name} : {parts[1]}  (interface method; no import needed from core)"


found = bool(hits)
if args[0] not in ("-m", "-s"):
    for a in args:
        ms = list(methods(a))
        found = found or bool(ms)
        for m in ms:
            print(m)
        if not ms and not any(e["name"] == a for e in hits):
            print(f"{a} : NOT IN STDLIB (try -s {a}; test-support helpers are in the skill's cheat sheet)")
elif not hits:
    print(f"no match for {' '.join(args[1:])}")
sys.exit(0 if found else 1)
