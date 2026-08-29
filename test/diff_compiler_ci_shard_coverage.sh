#!/bin/sh
# diff_compiler_ci_shard_coverage.sh — every gate must be REACHABLE IN CI.
#
# CI runs the 200+ gate scripts SHARDED across parallel hosted runners. A gate
# that no shard runs and no job names is never run in CI — silently. It still
# passes locally, `run_gates.sh` still counts it, and nothing anywhere says it
# was skipped.
#
# THIS IS NOT HYPOTHETICAL. It happened the same day the sharding landed: the
# new perf-scaling gate matched none of the six shard patterns and would have
# silently never run in CI. It was caught only because someone ran this check
# by hand — which is exactly the wrong way to depend on it. So the check is a
# GATE. A coverage check you have to remember to run is a coverage check that
# will eventually not get run.
#
# ── ONE AUTHORITY, NOT TWO (#2177, S-4) ──────────────────────────────────────
#
# This script used to PARSE `.github/workflows/ci.yml` itself — walking
# `strategy.matrix.include` for `{name, pattern}` rows and re-resolving each
# pattern glob against `$ROOT/test/` and `$ROOT/` — to work out which shard a
# gate ran in. That was correct when the matrix was hand-written and nothing
# else knew the mapping. It is now the SECOND way to answer a question the
# registry answers directly:
#
#   * `test/gates.toml` carries a `shard` field on every entry (S-1);
#   * `medaka gate ci` GENERATES ci.yml's matrix from those fields (S-2);
#   * the generated region on disk still equals what the registry generates —
#     asserted by `medaka gate ci --check`, which THIS SCRIPT runs itself (see
#     (c) below).
#
# So "which shard does this gate run in" is true BY CONSTRUCTION from the
# registry, and re-deriving it here could only ever disagree with it — a second
# mechanism, which is the defect. Shard membership now comes from
# `medaka gate list --json`'s `shard` field, and the eight legal row names from
# `medaka gate list --shards --json`. This file no longer reads ci.yml's matrix
# at all, and "a gate is in more than one shard" is no longer a state that can
# exist (one entry, one `shard` string).
#
# ── WHAT THIS GATE STILL UNIQUELY PROVES ─────────────────────────────────────
#
# Three things, two of which nothing else in the tree does:
#
#   (a) REACHABILITY of an `other-job` entry. `shard = "other-job"` says only
#       "not scheduled by the gates matrix"; it does NOT say which job runs it,
#       and the registry deliberately does not invent that field. So each such
#       entry must be either NAMED by a real `run:` step somewhere in
#       `.github/workflows/*.yml` (or a local composite action, #1961) or be on
#       the CI-COVERAGE-EXCEPTIONS ledger. An `other-job` entry that is neither
#       runs NOWHERE, and reds here.
#   (b) ORPHAN REFERENCES. A workflow `run:` step that invokes a `.sh` which is
#       in neither the registry nor CI-COVERAGE-TOOLS.txt — a renamed, deleted,
#       or never-enrolled script CI still tries to run.
#
# The workflow scan that answers both has no equivalent anywhere in the tree,
# which is why this script survives rather than folding into `medaka gate
# verify`: `verify` is text-over-the-registry and reads no workflow YAML.
#
#   (c) MATRIX AGREEMENT, at the REQUIRED tier (F-1). (a) and (b) read shard
#       membership from the registry, which is only sound if ci.yml's matrix
#       still says what the registry generates. `diff_compiler_ci_gen_drift`
#       asserts exactly that, but it is ADVISORY — so a hand-edit dropping
#       gates from a matrix row passed every REQUIRED gate. This script
#       therefore makes the same assertion itself, with the same
#       `medaka gate ci --check` call, before it certifies anything. It is a
#       deliberate second caller of one mechanism, not a second mechanism.
#
# ── THE DIVISION OF LABOUR, EXPLICITLY ───────────────────────────────────────
#
# `medaka gate verify` (via test/diff_compiler_gate_registry.sh) owns
# ENROLMENT: every `.sh` candidate in the tree is a registry `run` target or is
# listed in test/CI-COVERAGE-TOOLS.txt, no third state. Its candidate universe
# is preflight's own (tracked OR untracked), a strict superset of this file's,
# so re-checking enrolment here would be a second mechanism for the same
# question — exactly what this slice removed. THIS file owns CI REACHABILITY of
# what is enrolled. Between them every script is still classified into exactly
# one of the four states the old single script kept:
#
#     in a shard row  |  named by a real `run:` step  |  EXCEPTIONS ledger  |  TOOLS
#
# and this gate prints all four counts, so shrinking one silently is still not
# possible. It also refuses the two contradictions the split makes newly
# expressible: an entry that is BOTH in a shard row and on the EXCEPTIONS
# ledger, and a script that is BOTH a registry entry and a TOOLS entry.
#
# ── WHY THE SCOPE IS THE WHOLE REPO, AND WHY GIT ENUMERATES IT ───────────────
#
# (Kept from the original, because it is the reason this gate exists at all.)
# The curated version enumerated `test/diff_compiler_*.sh` and so certified
# coverage while a DOZEN real gates had never run in CI, and later `test/*.sh`
# + `test/wasm/*.sh` while THIRTY-EIGHT scripts sat outside its globs —
# including 22 sqlite oracle gates and a RED `test/native_fixtures/run.sh`
# nobody was looking at. A completeness check that defines its own scope will
# always certify itself complete. Scripts are therefore enumerated with
# `git ls-files`, not a filesystem walk: a `glob('**/*.sh')` happens to work
# only because Python's `**` skips dot-directories, and this box keeps ~30 agent
# worktrees under `.claude/worktrees/`. A gate is identified by its
# REPO-RELATIVE PATH (minus `.sh`), never a basename — basenames COLLIDE across
# roots (`test/native_fixtures/run.sh` vs `playground/e2e/run.sh`), and a ledger
# keyed on a colliding name classifies the wrong file.
#
# Usage:  sh test/diff_compiler_ci_shard_coverage.sh
#         sh test/diff_compiler_ci_shard_coverage.sh <path-minus-.sh>...
#             ^ ask which of the four states each named script is in, and exit 0.
#               A classification nobody can interrogate is a classification
#               nobody can check; the gate answers for one script as readily as
#               it certifies all of them.
# Exit:   0 ci.yml's generated matrix agrees with the registry, every registry
#         entry is reachable in CI, and no workflow names an unenrolled script;
#         1 a violation (each one named); 2 no native medaka binary, or no
#         python3.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WFDIR="$ROOT/.github/workflows"
MEDAKA="${MEDAKA:-$ROOT/medaka}"

[ -d "$WFDIR" ] || { echo "no workflow dir at $WFDIR — nothing to check"; exit 1; }
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found (needed to parse the workflow YAML)"; exit 2; }

# (c) MATRIX AGREEMENT, at the required tier. Everything below reads shard
# membership from the registry; that is only a statement about CI if ci.yml's
# matrix still equals what the registry generates. Non-mutating by
# construction — `--check` never writes ci.yml. Skipped in single-script query
# mode, whose contract is to classify and exit 0.
if [ "$#" -eq 0 ]; then
  if ! MEDAKA_ROOT="$ROOT" LC_ALL=C "$MEDAKA" gate ci --check; then
    echo
    echo "FAIL: .github/workflows/ci.yml's generated gates-matrix region does not agree with"
    echo "      test/gates.toml (message above). Shard membership below is read from the"
    echo "      registry, so a drifted matrix means this gate's answer is not what CI runs."
    echo "      Run 'make gen-ci' and commit the result."
    exit 1
  fi
fi

python3 - "$ROOT" "$WFDIR" "$MEDAKA" "$@" <<'PY'
import sys, json, pathlib, re, subprocess

root, wfdir, medaka = sys.argv[1], sys.argv[2], sys.argv[3]
queries = sys.argv[4:]

# ── the registry, via the ONE lossless data hook. ─────────────────────────────
# `--registry` is passed explicitly rather than relying on MEDAKA_ROOT so this
# gate reads the registry of the tree it lives in, whatever the environment.
def gate_list(*args):
    cmd = [medaka, 'gate', 'list', '--registry', f'{root}/test/gates.toml', '--json', *args]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        print(f"FAIL: `{' '.join(cmd)}` exited {out.returncode} — cannot read the registry.")
        print("      Refusing to certify coverage from a partial list.")
        for line in (out.stderr or '').strip().splitlines():
            print(f"       {line}")
        sys.exit(1)
    try:
        return json.loads(out.stdout)
    except Exception as e:
        print(f"FAIL: `medaka gate list {' '.join(args)} --json` did not produce JSON: {e}")
        sys.exit(1)

entries = gate_list()
rows = [s['name'] for s in gate_list('--shards')]
if not entries or not rows:
    print("FAIL: the registry produced no entries or no shard rows (harness bug)")
    sys.exit(1)

# ── the workflow scan. Unchanged in substance from the pre-#2177 script; this
# is the half nothing else in the tree can answer. ───────────────────────────
#
# `invocation_text` (#1969) collects ONLY the text of actual invocation sites —
# `run:` step bodies, from workflow jobs AND composite-action steps (#1961) —
# not the whole raw file. A gate's path merely being MENTIONED somewhere in a
# workflow (a `case` arm mapping paths to shard names, a comment, a job
# `name:`) is not evidence the gate is ever run; only a `run:` step containing
# the path is. Composite actions (`.github/actions/*/action.yml`) are invisible
# to the workflow glob but can be the ONLY place a gate is invoked from.
wf_paths = sorted(pathlib.Path(wfdir).glob('*.yml')) + sorted(pathlib.Path(wfdir).glob('*.yaml'))
if not wf_paths:
    print(f"FAIL: no workflow files under {wfdir} — nothing to check")
    sys.exit(1)

actions_dir = pathlib.Path(root) / '.github' / 'actions'
action_paths = (sorted(actions_dir.glob('*/action.yml')) + sorted(actions_dir.glob('*/action.yaml'))
                if actions_dir.is_dir() else [])

def run_step_texts(doc):
    texts = []
    if not isinstance(doc, dict):
        return texts
    jobs = doc.get('jobs')
    if isinstance(jobs, dict):
        for job in jobs.values():
            for step in ((job or {}).get('steps') or []):
                run = (step or {}).get('run')
                if isinstance(run, str):
                    texts.append(run)
    runs = doc.get('runs')
    if isinstance(runs, dict):
        for step in (runs.get('steps') or []):
            run = (step or {}).get('run')
            if isinstance(run, str):
                texts.append(run)
    return texts

invocation_text_parts = []
for path in list(wf_paths) + list(action_paths):
    txt = path.read_text()
    try:
        import yaml
        invocation_text_parts.extend(run_step_texts(yaml.safe_load(txt)))
    except Exception:
        # No PyYAML, or this file didn't parse? Scan its whole raw text for
        # invocation purposes — conservative on purpose. A file we cannot read
        # must not silently drop out of the scan, because "unreadable" would
        # then look exactly like "invokes nothing".
        invocation_text_parts.append(txt)
invocation_text = '\n'.join(invocation_text_parts)

# A `case` pattern is always immediately followed by `)` (optionally after `|`
# alternation, e.g. `foo.sh|bar.sh)`); a genuine invocation (`sh test/foo.sh`,
# `./medaka build test/foo.sh`, a bare `test/foo.sh` command line) never is. So
# a match immediately followed by `)` is a case-arm mention, not a real
# invocation. (A case-pattern-shaped occurrence INSIDE a real invocation, e.g.
# `$(sh test/foo.sh)`, is an accepted rare false-negative rather than solved.)
def _is_real_invocation(stem, text):
    pat = re.compile(rf'(?<![\w/-]){re.escape(stem)}\.sh\b')
    for m in pat.finditer(text):
        if m.end() < len(text) and text[m.end()] == ')':
            continue
        return True
    return False

# ── the two ledgers. Same files, same keys, same semantics as before: one
# non-comment line per entry, keyed by the FIRST whitespace-separated token
# (repo-relative path, minus `.sh`). ─────────────────────────────────────────
def ledger(name):
    out = {}
    p = pathlib.Path(root) / 'test' / name
    if p.exists():
        for line in p.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith('#'):
                stem, _, reason = line.partition(' ')
                out[stem] = reason.strip()
    return out

tools = ledger('CI-COVERAGE-TOOLS.txt')
exc = ledger('CI-COVERAGE-EXCEPTIONS.txt')

out = subprocess.run(['git', '-C', root, 'ls-files', '-z', '*.sh'],
                     capture_output=True, text=True)
if out.returncode != 0:
    print(f"FAIL: `git ls-files` failed in {root} — cannot enumerate the script universe.")
    print("      Refusing to certify coverage from a partial list.")
    sys.exit(1)
tracked = {p[:-3] for p in out.stdout.split('\0') if p.endswith('.sh')}
if not tracked:
    print("FAIL: found no scripts at all in the repo (harness bug)")
    sys.exit(1)

# ── classify every registry entry. ───────────────────────────────────────────
by_stem = {}
bad_run = []
for e in entries:
    run = e.get('run', '')
    if not run.endswith('.sh'):
        bad_run.append((e['name'], run))
        continue
    by_stem[run[:-3]] = e

sharded, named, excepted, unreachable = {}, [], [], []
bad_shard, both_shard_and_excepted = [], []
for stem in sorted(by_stem):
    e = by_stem[stem]
    sh = e['shard']
    on_ledger = stem in exc
    if sh in rows:
        if on_ledger:
            both_shard_and_excepted.append((stem, sh))
        sharded[stem] = sh
    elif sh == 'other-job':
        if on_ledger:
            excepted.append(stem)
        elif _is_real_invocation(stem, invocation_text):
            named.append(stem)
        else:
            unreachable.append(stem)
    else:
        bad_shard.append((stem, sh))

both_registry_and_tool = sorted(set(by_stem) & set(tools))

# ── query mode: which of the four states is this script in? A classification
# nobody can interrogate is a classification nobody can check. ───────────────
if queries:
    for q in queries:
        q = q[:-3] if q.endswith('.sh') else q
        if q in sharded:
            print(f"  SHARD:{sharded[q]:<12} {q}  (gates matrix row, from test/gates.toml's `shard`)")
        elif q in excepted:
            print(f"  {'EXCEPTED':<18} {q}  ({exc[q]})")
        elif q in named:
            print(f"  {'NAMED':<18} {q}  (a real workflow/composite-action `run:` step invokes it)")
        elif q in unreachable:
            print(f"  {'UNREACHABLE':<18} {q}  (shard is other-job, named nowhere, not on the ledger)")
        elif q in tools:
            print(f"  {'TOOLS':<18} {q}  ({tools[q]})")
        else:
            print(f"  {'UNCLASSIFIED':<18} {q}  (not a registry entry, not a CI-COVERAGE-TOOLS.txt entry)")
    sys.exit(0)

# ── ORPHAN REFERENCES: a `run:` step naming a script the registry does not
# have. The regex takes repo-relative-looking paths only (a match may not be
# preceded by a path character, so `"$RUNNER_TEMP/x.sh"` contributes nothing);
# a trailing `)` means a `case` arm, as above. A token with a shell metachar,
# or one that is not a tracked file, is not evidence of a stale reference —
# `*.sh`, `$f.sh` and friends are ordinary shell — so only TRACKED,
# UNCLASSIFIED scripts are reported. ─────────────────────────────────────────
REF = re.compile(r'(?<![\w./$-])((?:[\w.+-]+/)*[\w.+-]+)\.sh\b')
referenced = set()
for m in REF.finditer(invocation_text):
    if m.end() < len(invocation_text) and invocation_text[m.end()] == ')':
        continue
    referenced.add(m.group(1))
orphans = sorted(s for s in referenced
                 if s in tracked and s not in by_stem and s not in tools)

# ── report. ──────────────────────────────────────────────────────────────────
for row in rows:
    print(f"  {row:<10} {sum(1 for v in sharded.values() if v == row):>3} gates")
print(f"  {'named':<10} {len(named):>3} gates (run by name, unsharded — e.g. the compiler-soundness job)")
print(f"  {'EXCEPTED':<10} {len(excepted):>3} gates (NOT run in CI — ledger below)")
# Counted against `tracked`, not against the ledger's raw line count: the file
# carries multi-line descriptions whose continuation lines the shared
# first-token reader (preflight's `awk 'NF { print $1 }'`, `gate verify`'s
# `toolNames`, and this one) each read as further keys. They match no script,
# so they classify nothing — but they would inflate a raw tally into a lie.
print(f"  {'TOOLS':<10} {len(set(tools) & tracked):>3} scripts (not gates — test/CI-COVERAGE-TOOLS.txt)")
print(f"  {'TOTAL':<10} {len(sharded) + len(named):>3} of {len(by_stem)} registry entries reach CI"
      f" ({len(excepted)} excepted, {len(unreachable)} unreachable)")

rc = 0
if exc:
    print()
    print("  CI-COVERAGE-EXCEPTIONS.txt — these gates do NOT run in CI:")
    for stem, reason in sorted(exc.items()):
        live = " (ledger entry is STALE — this gate no longer exists)" if stem not in tracked else ""
        print(f"       {stem}: {reason}{live}")
    # A ledger entry for a gate that no longer exists is rot — the exact failure
    # mode a plain skip-list has. Fail on it, so the ledger cannot quietly
    # outlive its gate.
    stale = sorted(set(exc) - tracked)
    if stale:
        print()
        print("FAIL: the exceptions ledger names gates that DO NOT EXIST:")
        for s in stale:
            print(f"       {s}")
        print("       Remove them from test/CI-COVERAGE-EXCEPTIONS.txt.")
        rc = 1

if unreachable:
    print()
    print("FAIL: these gates are `shard = \"other-job\"` but NOTHING RUNS THEM — no workflow")
    print("      `run:` step names them and they are not on the exceptions ledger, so they")
    print("      would SILENTLY NEVER RUN in CI:")
    for m in unreachable:
        print(f"       {m}")
    print("       Give the entry a real `shard` in test/gates.toml (then `make gen-ci`), run")
    print("       it by name in a job, or add it to test/CI-COVERAGE-EXCEPTIONS.txt WITH A REASON.")
    rc = 1

if orphans:
    print()
    print("FAIL: a workflow `run:` step invokes these scripts, but the gate registry does not")
    print("      have them and test/CI-COVERAGE-TOOLS.txt does not claim them:")
    for o in orphans:
        print(f"       {o}.sh")
    print("       Enrol them in test/gates.toml, list them in test/CI-COVERAGE-TOOLS.txt, or")
    print("       stop invoking them.")
    rc = 1

if bad_shard:
    print()
    print("FAIL: these entries carry a `shard` that is neither a matrix row nor `other-job`:")
    for stem, sh in bad_shard:
        print(f"       {stem}: shard = \"{sh}\" (rows: {' '.join(rows)})")
    rc = 1

if both_shard_and_excepted:
    print()
    print("FAIL: these entries are scheduled by the `gates` matrix AND on the exceptions")
    print("      ledger — the ledger claims they do not run in CI, and they do:")
    for stem, sh in both_shard_and_excepted:
        print(f"       {stem}: shard = \"{sh}\", also in test/CI-COVERAGE-EXCEPTIONS.txt")
    rc = 1

if both_registry_and_tool:
    print()
    print("FAIL: these scripts are BOTH a gate registry entry and a CI-COVERAGE-TOOLS.txt")
    print("      entry — the tools ledger claims running them proves nothing:")
    for s in both_registry_and_tool:
        print(f"       {s}")
    rc = 1

if bad_run:
    print()
    print("FAIL: these registry entries have a `run` target that is not a `.sh` script:")
    for name, run in bad_run:
        print(f"       {name}: run = \"{run}\"")
    rc = 1

if rc == 0:
    print()
    print("PASS: every gate registry entry is reachable in CI, and no workflow step names an")
    print("      unenrolled script. (Shard membership read from the registry, not from"
          " ci.yml.)")
sys.exit(rc)
PY
