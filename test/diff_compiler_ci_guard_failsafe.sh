#!/bin/sh
# diff_compiler_ci_guard_failsafe.sh — every required job's step-level `if:` must not
# go green-by-skip when its upstream classifier job fails outright.
#
# Ten guards added by #1931/#1932 read `needs.detect.outputs.FOO == 'true'` at STEP
# level to narrow a required job's work to the paths that actually touched it. That is
# correct on the happy path — but on a `detect` FAILURE, GitHub Actions still runs
# downstream jobs whose `if:` is `${{ !cancelled() }}` (never skipped by a failed
# `needs:`), and an *unwritten* job output reads back as the empty string. So
# `needs.detect.outputs.FOO == 'true'` is FALSE when `detect` failed just as much as
# when it legitimately produced 'false' — the step SKIPS, the job reports its overall
# conclusion from whatever steps DID run, and a required check can go green having
# tested NOTHING. That is #1971 exactly, and it already happened once (FIX-1,
# `c24ade9c`, added the `needs.detect.result != 'success' ||` disjunct to every
# affected step).
#
# THE RULE (see S-guard-failsafe-gate packet §3 for the derivation):
#   For every step `if:` in a job backing a REQUIRED context, any clause of the shape
#     needs.<job>.outputs.<X> == '<literal>'    (any quoted literal — not just 'true';
#                                                 an empty unwritten output never equals
#                                                 ANY specific literal, so `== 'false'`
#                                                 is just as unsafe as `== 'true'`)
#     contains(needs.<job>.outputs.<X>, ...)    (empty string never `contains` anything)
#   referencing a job this job `needs:` MUST be reachable only when ORed with
#     needs.<job>.result != 'success'
#   A NEGATIVE-match-only guard (`needs.detect.outputs.docs_only != 'true'`, with no
#   companion positive `==`/`contains` clause) is already fail-safe by construction on a
#   `detect` failure (empty string != anything is TRUE, so the step runs unguarded) and
#   needs no disjunct — flagging it would be a false positive against a correct,
#   intentional pattern (see `build`'s and `seed-health`'s bare `docs_only != 'true'`
#   steps).
#
# Required JOBS (backing the twelve required contexts, derived from the ruleset —
# see AGENTS.md [W-REQUIRED-CHECKS] for how to re-derive; trusted here per the
# packet's §4 audit): gates, soundness, compiler-soundness, seed-health, inlang, wasm.
#
# EXTRACTION (F2 hardening, review-round finding): step `if:` conditions are read via
# PyYAML, not a raw-line regex — a YAML parser is indentation- and folding-invariant by
# construction, so a folded-scalar rewrite (`if: >-` + continuations) or a different
# indent level cannot silently evade detection the way a fixed-column line regex could
# (and did — confirmed by the review round: count silently dropped 10 -> 9, exit still
# 0, and rewriting ALL guards this way yielded "PASS: 0 ..." at exit 0, i.e. success
# having checked nothing). A workflow file that fails to parse as YAML falls back to
# the old line regex rather than being silently treated as zero sites — same
# conservative-fallback discipline `diff_compiler_ci_shard_coverage.sh` uses.
#
# FLOOR: each required job's known-good positive-match count (per slice 4's audited
# report, cross-checked by the review round) is baked in as a MINIMUM, not an exact
# match — a future PR may legitimately add more guarded steps, so exceeding the floor
# is fine. Dropping BELOW it is itself a FAIL: fewer guarded sites than are known to
# exist means either the parser broke or a guard was silently removed, and printing
# PASS over that is the exact failure mode this gate exists to catch. Floors below are
# "known-good as of this commit; if this legitimately drops, lower the floor and say
# why in the commit" (EXCEPTIONS.txt-style: a deliberate, reviewable, commented
# adjustment, never a silent skip).
#
# Usage:  sh test/diff_compiler_ci_guard_failsafe.sh
# Exit:   0 every positive-match step-if in a required job carries the disjunct, and
#         every required job's count meets its floor; 1 otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CIYML="$ROOT/.github/workflows/ci.yml"

[ -f "$CIYML" ] || { echo "no ci.yml at $CIYML — nothing to check"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found (needed to parse the workflow YAML)"; exit 2; }

python3 - "$CIYML" <<'PY'
import sys, re

path = sys.argv[1]
text = open(path, encoding='utf-8').read()
lines = text.splitlines()

# Hardcoded job-template names, not ruleset CONTEXTS: `gates` is one matrix job
# template that expands to 7 required contexts (ruleset 18885875 has 12 required
# contexts total, this set has 6 entries) — this list must be kept in sync with
# that ruleset by hand. This gate does NOT verify that sync; it only verifies
# the fail-safe `if:` shape (a positive-match disjunct on every step) for
# whichever job templates it's told about here. A ruleset context renamed,
# added, or removed without a matching edit here goes unnoticed by this gate.
REQUIRED_JOBS = {"gates", "soundness", "compiler-soundness", "seed-health", "inlang", "wasm"}

# Known-good floors — see header comment. A job not listed here has floor 0.
FLOORS = {
    "compiler-soundness": 5,
    "inlang": 2,
    "wasm": 3,
    "seed-health": 0,
    "gates": 0,
    "soundness": 0,
}

# A positive match against a `needs.<job>.outputs.<x>` reference: any quoted-literal
# equality (not just 'true' — 'false' is just as unsafe, see header) or a `contains(...)`
# call over the same output.
pos_re = re.compile(r"needs\.([A-Za-z0-9_-]+)\.outputs\.[A-Za-z0-9_]+\s*==\s*'[^']*'"
                     r"|contains\(\s*needs\.([A-Za-z0-9_-]+)\.outputs\.[A-Za-z0-9_]+")

def disjunct_present(if_text, job):
    return re.search(rf"needs\.{re.escape(job)}\.result\s*!=\s*'success'", if_text) is not None

def collapse(s):
    return re.sub(r'\s+', ' ', s).strip()

# ---- YAML-based extraction (primary path) --------------------------------------

class LineLoader(__import__('yaml').SafeLoader):
    pass

def _construct_mapping(loader, node, deep=False):
    import yaml
    mapping = yaml.SafeLoader.construct_mapping(loader, node, deep=deep)
    mapping['__line__'] = node.start_mark.line + 1
    return mapping

LineLoader.add_constructor(
    __import__('yaml').resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping)

def yaml_extract():
    import yaml
    doc = yaml.load(text, Loader=LineLoader)
    if not isinstance(doc, dict) or not isinstance(doc.get('jobs'), dict):
        raise ValueError("no top-level `jobs:` mapping found")
    jobs = doc['jobs']
    missing_required = sorted(REQUIRED_JOBS - set(jobs.keys()))
    if missing_required:
        print("FAIL: these required jobs were not found in ci.yml at all (name drift?):")
        for m in missing_required:
            print(f"       {m}")
        sys.exit(1)

    violations = []
    counts = {j: 0 for j in REQUIRED_JOBS}
    for job in sorted(REQUIRED_JOBS):
        jobdef = jobs.get(job) or {}
        steps = jobdef.get('steps') or []
        for step in steps:
            if not isinstance(step, dict) or 'if' not in step:
                continue
            if_text = collapse(str(step['if']))
            lineno = step.get('__line__', jobdef.get('__line__', 0))
            referenced = set(g for pair in pos_re.findall(if_text) for g in pair if g)
            for refjob in referenced:
                counts[job] += 1
                if not disjunct_present(if_text, refjob):
                    violations.append((job, lineno, refjob, if_text))
    return violations, counts, len(jobs)

# ---- Regex-based fallback (only if YAML fails to parse) -------------------------
# Conservative fallback discipline: a workflow file we CANNOT parse must never be
# silently treated as "zero sites, PASS" — say so, and fall back to a best-effort
# line scan (fixed 8-space step indent) rather than certifying an empty scan.

def regex_extract():
    job_header_re = re.compile(r'^  ([A-Za-z0-9_-]+):\s*$')
    jobs_idx = None
    for i, ln in enumerate(lines):
        if ln == "jobs:":
            jobs_idx = i
            break
    if jobs_idx is None:
        print("FAIL: no top-level `jobs:` key found in ci.yml — cannot scope job bodies.")
        sys.exit(1)
    headers = []
    for i in range(jobs_idx + 1, len(lines)):
        ln = lines[i]
        if ln and not ln.startswith(' '):
            break
        m = job_header_re.match(ln)
        if m:
            headers.append((m.group(1), i))
    if not headers:
        print("FAIL: found `jobs:` but no job headers under it — cannot scope job bodies.")
        sys.exit(1)
    job_ranges = {}
    for idx, (name, start) in enumerate(headers):
        end = headers[idx + 1][1] if idx + 1 < len(headers) else len(lines)
        job_ranges[name] = (start, end)
    missing_required = sorted(REQUIRED_JOBS - set(job_ranges))
    if missing_required:
        print("FAIL: these required jobs were not found in ci.yml at all (name drift?):")
        for m in missing_required:
            print(f"       {m}")
        sys.exit(1)
    step_if_re = re.compile(r'^        if:\s*(.*)$')
    violations = []
    counts = {j: 0 for j in REQUIRED_JOBS}
    for job in sorted(REQUIRED_JOBS):
        start, end = job_ranges[job]
        for i in range(start, end):
            ln = lines[i]
            m = step_if_re.match(ln)
            if not m:
                continue
            if_text = m.group(1)
            referenced = set(g for pair in pos_re.findall(if_text) for g in pair if g)
            for refjob in referenced:
                counts[job] += 1
                if not disjunct_present(if_text, refjob):
                    violations.append((job, i + 1, refjob, ln.strip()))
    return violations, counts, len(job_ranges)

try:
    import yaml  # noqa: F401
    violations, counts, njobs = yaml_extract()
    mode = "YAML"
except Exception as e:
    print(f"WARN: could not parse {path} as YAML ({e}); falling back to a raw-line regex")
    print("      scan (fixed 8-space step indent) — refusing to silently treat this as")
    print("      zero sites. Re-derive why the YAML parse failed before trusting this run.")
    violations, counts, njobs = regex_extract()
    mode = "regex-fallback"

checked_positive = sum(counts.values())

floor_violations = []
for job in sorted(REQUIRED_JOBS):
    floor = FLOORS.get(job, 0)
    if counts.get(job, 0) < floor:
        floor_violations.append((job, counts.get(job, 0), floor))

failed = False

if violations:
    failed = True
    print(f"FAIL: {len(violations)} step-if(s) in a required job have a positive")
    print("      needs.<job>.outputs.X match with NO needs.<job>.result != 'success'")
    print("      disjunct — these go green-by-skip if the upstream job fails outright:")
    for job, lineno, refjob, text in violations:
        print(f"       {path}:{lineno} (job '{job}', references '{refjob}'): {text}")

if floor_violations:
    failed = True
    print(f"FAIL: {len(floor_violations)} required job(s) fell BELOW their known-good")
    print("      positive-match floor — fewer guarded sites than are known to exist means")
    print("      either the parser broke or a guard was silently removed:")
    for job, found, floor in floor_violations:
        print(f"       job '{job}': found {found}, floor {floor}")

if failed:
    sys.exit(1)

print(f"PASS: {checked_positive} positive-match step-if(s) across {len(REQUIRED_JOBS)} "
      f"required jobs ({', '.join(sorted(REQUIRED_JOBS))}) all carry the fail-safe disjunct "
      f"(extraction: {mode}; per-job floors held).")
sys.exit(0)
PY
