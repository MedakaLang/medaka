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
#     needs.<job>.outputs.<X> == 'true'          (or a `contains(...)` truthy match)
#   referencing a job this job `needs:` MUST be reachable only when ORed with
#     needs.<job>.result != 'success'
#   A NEGATIVE-match-only guard (`needs.detect.outputs.docs_only != 'true'`, with no
#   companion positive `== 'true'` clause) is already fail-safe by construction on a
#   `detect` failure (empty string != 'true' is TRUE, so the step runs unguarded) and
#   needs no disjunct — flagging it would be a false positive against a correct,
#   intentional pattern (see `build`'s and `seed-health`'s bare `docs_only != 'true'`
#   steps).
#
# Required JOBS (backing the twelve required contexts, derived from the ruleset —
# see AGENTS.md [W-REQUIRED-CHECKS] for how to re-derive; trusted here per the
# packet's §4 audit): gates, soundness, compiler-soundness, seed-health, inlang, wasm.
#
# Usage:  sh test/diff_compiler_ci_guard_failsafe.sh
# Exit:   0 every positive-match step-if in a required job carries the disjunct
#         (or has no positive match at all); 1 one or more do not.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CIYML="$ROOT/.github/workflows/ci.yml"

[ -f "$CIYML" ] || { echo "no ci.yml at $CIYML — nothing to check"; exit 1; }

python3 - "$CIYML" <<'PY'
import sys, re

path = sys.argv[1]
text = open(path, encoding='utf-8').read()
lines = text.splitlines()

REQUIRED_JOBS = {"gates", "soundness", "compiler-soundness", "seed-health", "inlang", "wasm"}

# Find `jobs:` top-level key, then every top-level (2-space-indent) job header under
# it, giving each job a [start, end) line range (0-indexed into `lines`).
jobs_idx = None
for i, ln in enumerate(lines):
    if ln == "jobs:":
        jobs_idx = i
        break
if jobs_idx is None:
    print("FAIL: no top-level `jobs:` key found in ci.yml — cannot scope job bodies.")
    sys.exit(1)

job_header_re = re.compile(r'^  ([A-Za-z0-9_-]+):\s*$')
headers = []  # (name, line_index)
for i in range(jobs_idx + 1, len(lines)):
    ln = lines[i]
    if ln and not ln.startswith(' '):
        break  # dedented past the jobs: block entirely
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

# Step-level `if:` lines sit at 8-space indent (`        if: ...`); job-level `if:`
# sits at 4-space indent (`    if: ${{ !cancelled() }}`) — confirmed pattern across
# every required job on this tree (AGENTS.md / packet §4). Only step-level lines are
# in scope: a step is what can individually skip while the job still reports a
# conclusion from whatever steps DID run.
step_if_re = re.compile(r'^        if:\s*(.*)$')

# A positive truthy match against a `needs.<job>.outputs.<x>` reference:
#   needs.JOB.outputs.X == 'true'          (bare or inside ${{ }})
#   contains(needs.JOB.outputs.X, 'true')  (or contains(..., ..., 'true') shape)
pos_re = re.compile(r"needs\.([A-Za-z0-9_-]+)\.outputs\.[A-Za-z0-9_]+\s*==\s*'true'"
                     r"|contains\(\s*needs\.([A-Za-z0-9_-]+)\.outputs\.[A-Za-z0-9_]+")

def disjunct_present(if_text, job):
    return re.search(rf"needs\.{re.escape(job)}\.result\s*!=\s*'success'", if_text) is not None

violations = []
checked_positive = 0
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
            checked_positive += 1
            if not disjunct_present(if_text, refjob):
                violations.append((job, i + 1, refjob, ln.strip()))

if violations:
    print(f"FAIL: {len(violations)} step-if(s) in a required job have a positive")
    print("      needs.<job>.outputs.X == 'true' match with NO needs.<job>.result != 'success'")
    print("      disjunct — these go green-by-skip if the upstream job fails outright:")
    for job, lineno, refjob, text in violations:
        print(f"       {path}:{lineno} (job '{job}', references '{refjob}'): {text}")
    sys.exit(1)

print(f"PASS: {checked_positive} positive-match step-if(s) across {len(REQUIRED_JOBS)} "
      f"required jobs ({', '.join(sorted(REQUIRED_JOBS))}) all carry the fail-safe disjunct.")
sys.exit(0)
PY
