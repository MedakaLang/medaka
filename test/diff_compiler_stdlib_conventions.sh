#!/bin/sh
# test/diff_compiler_stdlib_conventions.sh — ratified stdlib API-conventions
# detector (#2306 leg 9, S-conventions-ratchet).
#
# stdlib/README.md's "API conventions" section writes down 7 rules ratified
# by #2306's surface-freeze sheet. Most of those rules need a human's
# judgment (a resource handle, a measured fast path, ...) and cannot be
# mechanically checked. This gate covers the two that CAN be, reading the
# generated `docs/stdlib/inventory.json` (module/name/signature for every
# stdlib export) rather than re-parsing source:
#
#   (a) D-2 / D-5: `<type><Op>` ("xToY"-shaped) names are the PRIMITIVE
#       LAYER's naming marker (stdlib/runtime.mdk). A library module (any
#       stdlib/*.mdk module other than runtime.mdk) exporting a new name of
#       that exact shape would claim the marker for a name that isn't a
#       primitive, so this gate reds on one.
#
#   (b) B-3 / C-1: the `keys`/`values`/`toList`/`elems`/`entries`/`items`
#       "container accessor" family was settled into ONE name per shape per
#       module (`hash_map.entries` removed, kept `toList`; `map.elems`
#       renamed to `values`). A module re-introducing two family names with
#       an IDENTICAL signature is exactly the synonym drift that ruling
#       closed, so this gate reds on that too.
#
# Neither check is a general-purpose duplicate-signature or naming-style
# linter — the sheet's own R-1/R-2/R-3/R-4 rulings license plenty of
# same-shaped names and same-looking signatures elsewhere in the surface for
# good reason (see stdlib/README.md), and a broader mechanical sweep would
# flag those wrong (ratified-rules.md's own stated failure mode). This gate
# is deliberately narrow to the two rules the sheet ITSELF says are
# mechanically checkable.
#
# Usage:  sh test/diff_compiler_stdlib_conventions.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
INVENTORY="$ROOT/docs/stdlib/inventory.json"

if [ ! -f "$INVENTORY" ]; then
  printf 'FAIL %s does not exist — run: %s doc --out %s/docs/stdlib %s/stdlib/*.mdk\n' \
    "$INVENTORY" "$MEDAKA" "$ROOT" "$ROOT"
  exit 1
fi

python3 - "$INVENTORY" <<'PYEOF'
import json
import re
import sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

if not data:
    print("NO ENTRIES read from inventory.json — 0 checked, refusing to pass")
    sys.exit(1)

xtoy = re.compile(r'^[a-z][a-zA-Z0-9]*[a-z]To[A-Z][a-zA-Z0-9]*$')
family = {"keys", "values", "elems", "entries", "toList", "items"}

fails = []
checked = 0

def shape(name, sig):
    # The generated signature is "<name> : <type>" — strip the leading
    # "<name> : " so two different names with the same TYPE compare equal.
    # (Multi-clause/data signatures can span the name on their own first
    # line too; only the type after the first " : " is the shape.)
    prefix = name + " :"
    if sig.startswith(prefix):
        return sig[len(prefix):].strip()
    return sig.strip()

by_module = {}
for e in data:
    mod = e["module"]
    name = e["name"]
    sig = e["signature"]
    by_module.setdefault(mod, []).append((name, sig, shape(name, sig)))

for mod, entries in by_module.items():
    for name, sig, sh in entries:
        checked += 1
        # (a) xToY-shaped name outside the primitive layer.
        if mod != "runtime" and xtoy.match(name):
            fails.append(
                "%s.%s: 'xToY'-shaped name outside the primitive layer "
                "(runtime.mdk) — D-2/D-5 reserve that spelling for "
                "primitive externs; see stdlib/README.md rule 8" % (mod, name)
            )

    # (b) duplicate signature (by TYPE SHAPE, name stripped) within the
    # keys/values/toList/elems/entries family, in the same module.
    fam_entries = [(n, sh) for (n, _, sh) in entries if n in family]
    for i in range(len(fam_entries)):
        for j in range(i + 1, len(fam_entries)):
            n1, s1 = fam_entries[i]
            n2, s2 = fam_entries[j]
            if s1 == s2:
                fails.append(
                    "%s: '%s' and '%s' share an identical signature shape "
                    "(%s) — B-3/C-1 settled the "
                    "keys/values/toList/elems/entries family to one name "
                    "per shape per module; see stdlib/README.md rule 9" % (mod, n1, n2, s1)
                )

for msg in fails:
    print("FAIL " + msg)

print()
print("%d modules, %d entries checked, %d failing" % (len(by_module), checked, len(fails)))
sys.exit(1 if fails else 0)
PYEOF
