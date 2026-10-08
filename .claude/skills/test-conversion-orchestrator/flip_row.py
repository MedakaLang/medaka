"""Flip one test/gates.toml row to a native gate-test, in place.

Usage:
    python3 <repo>/.claude/skills/test-conversion-orchestrator/flip_row.py <repo> <gate name> <repo-relative _test.mdk>

Sets kind = "native", migration = "done" and run = <file> on the row whose
name matches exactly, and drops the old script's path from `sources`. The
name is kept so the gate's cost history and shard survive. Prints the row
afterwards. Refuses when the row is missing, is already done, or is a
shell:* / blocked:* / inverted-polarity row. Then set `sources`/`corpus` by
eye to every file and directory the test reads (plus
"test/compiler_cli_test_support.mdk" when it imports it): `medaka gate reach`
selects gates by `sources`, and a missing input is invisible to every check.
"""
import os
import re
import sys

if len(sys.argv) != 4:
    print(__doc__)
    sys.exit(2)
repo, name, run = sys.argv[1:]
path = os.path.join(repo, "test", "gates.toml")
text = open(path).read()
parts = text.split("[[gate]]")
hits = [i for i, b in enumerate(parts) if re.search(r'^name = "%s"$' % re.escape(name), b, re.M)]
if len(hits) != 1:
    sys.exit(f"{name}: {len(hits)} rows match")
i = hits[0]
row = parts[i]
mig = re.search(r'^migration = "([^"]*)"', row, re.M)
if not mig or mig.group(1) not in ("native-wrap", "native-rewrite", "split-first"):
    sys.exit(f"{name}: migration is {mig.group(1) if mig else 'missing'}; refusing")
if not os.path.isfile(os.path.join(repo, run)):
    sys.exit(f"{run}: no such file under {repo}")
old_run = re.search(r'^run = "([^"]*)"', row, re.M)


def drop_old_run(m):
    # The deleted script must not linger as a source: nothing would flag it.
    items = [s.strip() for s in m.group(1).split(",") if s.strip()]
    items = [s for s in items if s != '"%s"' % old_run.group(1)]
    return "sources = [" + ", ".join(items) + "]"


if old_run:
    row = re.sub(r'^sources = \[(.*)\]$', drop_old_run, row, count=1, flags=re.M)
row = re.sub(r'^kind = "[^"]*"', 'kind = "native"', row, count=1, flags=re.M)
row = re.sub(r'^migration = "[^"]*"', 'migration = "done"', row, count=1, flags=re.M)
row = re.sub(r'^run = "[^"]*"', 'run = "%s"' % run, row, count=1, flags=re.M)
parts[i] = row
open(path, "w").write("[[gate]]".join(parts))
print("[[gate]]" + row.rstrip())
