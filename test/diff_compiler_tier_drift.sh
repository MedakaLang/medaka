#!/bin/sh
# shell-because: trust-anchor — circular: checks the machinery a native gate would run inside
# diff_compiler_tier_drift.sh — a registry entry's `tiers` must be what the
# workflows actually do (#2181, epic #2182).
#
# `test/gates.toml` says, per gate, WHEN it runs: `tiers = ["merge"]`,
# `["nightly"]`, `["merge", "nightly/PERF_DEEP=1"]`. Nothing enforced that.
# Three of the 235 entries were simply wrong when this gate was written, and
# each was wrong SILENTLY — a decorative field disagreeing with the tree is
# indistinguishable from one agreeing with it:
#
#   * registry_keying_ratchet     said `ondemand`; test/typecheck_compiler_source.sh
#                                 runs it on every merge.
#   * diff_compiler_eval_scaling  said `merge`; nightly's `eval-scaling` job runs
#                                 it too, with the identical invocation.
#   * diff_compiler_perf_scaling  said `merge`; nightly's `perf-scaling-deep`
#                                 job runs it with PERF_DEEP=1.
#
# ── THE SHAPE, FROM diff_compiler_ci_gen_drift.sh ────────────────────────────
#
# Same three properties as that gate, for the same reasons:
#
#   * IT DOES NOT HEAL. It never rewrites test/gates.toml. A gate that fixes
#     the registry before comparing reports PASS having destroyed the evidence.
#   * IT ATTRIBUTES. Every violation names the gate, the declared set, the
#     derived set, and WHERE each derived run token came from (which workflow
#     job, or which gate script invoked it). "the registry drifted" with no
#     site is a bug report nobody can act on.
#   * IT READS THE REGISTRY THROUGH THE ONE HOOK, `medaka gate list --json`,
#     never by parsing TOML itself — a second reader of the registry is a
#     second answer to the question the registry exists to settle.
#
# It is NOT binary-free (it runs `./medaka gate list`), the same accepted gap
# diff_compiler_gate_registry.sh and diff_compiler_ci_gen_drift.sh have.
#
# ── HOW THE DERIVED SIDE IS BUILT ────────────────────────────────────────────
#
# Three sources, unioned, per tier:
#
#   1. MERGE, from the matrix. A gate whose `shard` is a real row runs in the
#      `gates` job, which is on the merge path. Shard membership is read from
#      the registry rather than from ci.yml because `medaka gate ci --check`
#      (diff_compiler_ci_gen_drift, required) already proves the two agree —
#      re-deriving it here would be a second mechanism for a settled question.
#   2. NAMED STEPS. A real `run:` step in .github/workflows/ci.yml (-> merge)
#      or nightly.yml (-> nightly) that INVOKES the gate script, plus the steps
#      of any local composite action those workflows `uses:` (#1961 — a
#      composite action can be the only invocation site).
#   3. ONE CLOSURE STEP through the gate scripts themselves: a gate script that
#      runs at tier T and invokes another gate script gives that one tier T
#      too. This is the whole reason registry_keying_ratchet was mis-tiered —
#      its merge run is three files away from any workflow.
#
# A gate no source reaches derives `ondemand`, which is exactly what that token
# claims.
#
# ⚠️ INVOCATION, NOT SUBSTRING. This is the trap that produced a false finding
# in an earlier cut of this work, so it is mechanised rather than remembered.
# `test/registry_keying_ratchet.sh` appears in ci.yml TWICE without ever being
# run there: once in a comment, once inside a `case` arm's `|` alternation
# (`test/typecheck_compiler_source.sh|test/registry_keying_ratchet.sh)`). So:
#   * `#`-to-end-of-line is stripped from every `run:` body first; and
#   * the path must sit in COMMAND POSITION — after a command separator, past
#     any shell keyword / `VAR=value` / `timeout N` / `env` / `exec` / `nice`
#     prefix, immediately following a literal `sh`/`bash`/`dash`. A case
#     pattern never is.
# Failing to recognise a new invocation spelling therefore makes a gate derive
# FEWER tiers than it declares, which reds here. It cannot fail silent.
#
# ⚠️ A FLAG-BEARING CALL IS A TOOL CALL, NOT A RUN. `pds/nightly/repo_vectors_eval_engine.sh`
# runs `sh pds/test/vector_provenance.sh --files-for P1-D-REPO` — it is asking
# that gate a question, not running its checks, exactly as
# `diff_compiler_ci_shard_coverage.sh <path>` documents its own query mode.
# Counting it would have made this gate demand `nightly` on a gate whose
# nightly checks never run. Positional arguments do NOT disqualify a run
# (`bash test/fuzz_diff.sh 1 1000 …` and `sh …/registry_keying_ratchet.sh "$ROOT"`
# are both real runs); only a leading-`-` argument does.
#
# ── MODES ────────────────────────────────────────────────────────────────────
#
# A run token's `/<mode>` is the INVOCATION DELTA: the comma-joined, sorted
# `KEY=VALUE` environment assignments the invoking step sets, minus the neutral
# plumbing keys below. That makes the mode CHECKABLE — `nightly/PERF_DEEP=1` is
# compared against the workflow, not read as a label somebody chose. The
# neutral set is small and explicit on purpose: a key that is NOT on it is
# treated as behaviour-changing, so the failure direction of a new env var is a
# red here, not a silently-tolerated difference.
#
# Usage:  sh test/diff_compiler_tier_drift.sh
# Exit:   0 every entry's `tiers` equals the derived run set; 1 at least one
#         drifted (each named, with provenance); 2 no native medaka binary, no
#         python3, or no PyYAML (the env attribution needs a real YAML parse —
#         refusing beats certifying from a text scan).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found (needed to parse the workflow YAML)"; exit 2; }

python3 - "$ROOT" "$MEDAKA" <<'PY'
import sys, json, re, pathlib, subprocess, collections

root, medaka = sys.argv[1], sys.argv[2]

try:
    import yaml
except ImportError:
    print("PyYAML not available — this gate reads each `run:` step's `env:`, which a")
    print("raw text scan cannot attribute. Refusing to certify tiers without it.")
    sys.exit(2)

# ── the registry, through the one lossless hook. `--registry` is explicit so
# this gate reads the tree it lives in, whatever the environment. ────────────
cmd = [medaka, 'gate', 'list', '--registry', f'{root}/test/gates.toml', '--json']
out = subprocess.run(cmd, capture_output=True, text=True)
if out.returncode != 0:
    print(f"FAIL: `{' '.join(cmd)}` exited {out.returncode} — cannot read the registry.")
    for line in (out.stderr or '').strip().splitlines():
        print(f"       {line}")
    sys.exit(1)
try:
    entries = json.loads(out.stdout)
except Exception as e:
    print(f"FAIL: `medaka gate list --json` did not produce JSON: {e}")
    sys.exit(1)
if not entries:
    print("FAIL: the registry produced no entries (harness bug)")
    sys.exit(1)

by_stem = {}
native_stems = set()
dup_stem = []
for e in entries:
    if e['run'].endswith('.sh'):
        stem = e['run'][:-3]
    else:
        # `kind = "native"` (#2591): no `.sh` script to strip a stem from —
        # the gate IS its `run` module. Keyed by the FULL run path (left
        # `.mdk`-suffixed) so it stays distinguishable from a `.sh` stem
        # everywhere below: `RES`/`runs_in()` skip it (no shell text to grep
        # for a `.sh` invocation — its only tier source is the matrix/`shard`
        # field, handled identically to a `.sh` entry) and the gate-script
        # closure walk (below) skips it too (no `.sh` file to open).
        stem = e['run']
        native_stems.add(stem)
    if stem in by_stem:
        dup_stem.append((stem, by_stem[stem]['name'], e['name']))
    by_stem[stem] = e
if dup_stem:
    print("FAIL: the registry has entries this gate's stem index would silently drop or clobber.")
    for stem, first, second in dup_stem:
        print(f"       {first!r} and {second!r} share stem {stem!r} — {second!r} silently clobbers {first!r}")
    print("      Refusing to certify tiers from a partial view.")
    sys.exit(1)
if not by_stem:
    print("FAIL: no registry entry has a `.sh` run target (harness bug)")
    sys.exit(1)

# Environment keys that do not change WHAT a gate checks — pure plumbing: where
# the tree is, which binary to use, byte-ordering, the API credentials a
# filing step needs, and a worker-count cap (JOBS — a fan-out pool size, not
# a scope change; surfaced only once F2's inline-env folding started seeing
# `JOBS=3 bash test/typecheck_compiler_source.sh` in ci.yml). Anything else
# counts as a mode.
NEUTRAL = {'MEDAKA_ROOT', 'MEDAKA', 'MEDAKA_EMITTER', 'LC_ALL',
           'GH_REPO', 'GH_TOKEN', 'GITHUB_TOKEN', 'JOBS'}

# Command-position prefixes: what may sit between a command separator and the
# `sh`/`bash`/`dash` that runs a gate.
# The VAR=value and timeout branches use [ \t]+ (not \s+) for their trailing
# separator so a prefix can never absorb a newline — "rc=1" ending one
# statement must not fuse with "bash foo.sh" starting the next just because
# \s+ is willing to eat the line break between them (that fusion would also
# misattribute rc=1 as an inline env assignment for F2's env folding, below).
PRE = (r'(?:(?:if|then|else|elif|do|while|until|!|not)\s+'
       r'|[A-Za-z_][A-Za-z0-9_]*=[^\s]*[ \t]+'
       r'|timeout[ \t]+[^\s]+[ \t]+'
       r'|env\s+|exec\s+|nice\s+(?:-n\s+[^\s]+\s+)?)*')


def strip_comments(text):
    """Drop `#`-to-end-of-line where the `#` starts a word. A `#` inside a word
    (`foo#bar`, a colour, a fragment) is not a comment introducer in sh."""
    out = []
    for line in text.splitlines():
        i = line.find('#')
        while i >= 0:
            if i == 0 or line[i - 1] in ' \t':
                line = line[:i]
                break
            i = line.find('#', i + 1)
        out.append(line)
    return '\n'.join(out)


def invocation_re(stem):
    return re.compile(
        r'(?:^|[\n;&|(`])\s*(?P<pre>' + PRE + r')'
        r'(?:sh|bash|dash)\s+(?:-[^\s]+\s+)*'
        r'["\']?(?:\$\{?ROOT\}?/|\$\{\{[^}]*\}\}/|\./)?'
        + re.escape(stem) + r'\.sh["\']?(?P<args>[^\n;&|]*)')


RES = {s: invocation_re(s) for s in by_stem if s not in native_stems}

# An inline `VAR=value` command prefix (the same shape `PRE` already
# recognizes and steps past to find the `sh`/`bash`/`dash`) is an env
# assignment the identical `env:` YAML spelling would also produce — fold it
# into the invocation's env the same way, so the two spellings derive the
# same mode (F2, #2181 review finding).
INLINE_ENV_RE = re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)=([^\s]*)')


def inline_env(pre_text):
    return dict(INLINE_ENV_RE.findall(pre_text))


def runs_in(text):
    """{stem: inline-env} for every gate this text actually RUNS (see the two
    ⚠️ notes above), `inline-env` being any `VAR=value` prefix(es) on that
    invocation's own command line."""
    found = {}
    for stem, rx in RES.items():
        for m in rx.finditer(text):
            if any(t.startswith('-') for t in m.group('args').split()):
                continue        # a tool call, not a run
            extra = inline_env(m.group('pre'))
            if stem in found:
                found[stem].update(extra)
            else:
                found[stem] = extra
    return found


def workflow_steps(path):
    """(job label, comment-stripped run body, effective env) for every `run:`
    step of a workflow, including the steps of local composite actions it
    `uses:` — a composite action can be a gate's only invocation site."""
    doc = yaml.safe_load(pathlib.Path(path).read_text())
    steps = []
    for job_name, job in ((doc or {}).get('jobs') or {}).items():
        for st in ((job or {}).get('steps') or []):
            env = {}
            env.update((job or {}).get('env') or {})
            env.update((st or {}).get('env') or {})
            body = (st or {}).get('run')
            if isinstance(body, str):
                steps.append((f'job {job_name}', strip_comments(body), env))
            uses = (st or {}).get('uses')
            if isinstance(uses, str) and uses.startswith('./.github/actions/'):
                ap = pathlib.Path(root) / uses[2:] / 'action.yml'
                if not ap.exists():
                    ap = pathlib.Path(root) / uses[2:] / 'action.yaml'
                if ap.exists():
                    act = yaml.safe_load(ap.read_text())
                    for ast in ((act or {}).get('runs') or {}).get('steps') or []:
                        abody = (ast or {}).get('run')
                        if isinstance(abody, str):
                            aenv = dict(env)
                            aenv.update((ast or {}).get('env') or {})
                            steps.append((f'job {job_name} via {uses}',
                                          strip_comments(abody), aenv))
    return steps


WORKFLOWS = (('ci.yml', 'merge'), ('nightly.yml', 'nightly'))

derived = collections.defaultdict(set)   # stem -> {run token}
why = {}                                 # (stem, token) -> provenance

# (1) merge, from the gates matrix — `shard` is the registry's own answer, and
#     `medaka gate ci --check` already proves ci.yml agrees with it.
for stem, e in by_stem.items():
    if e['shard'] != 'other-job':
        derived[stem].add('merge')
        why[(stem, 'merge')] = f"the `gates` matrix row {e['shard']}"

# (2) named `run:` steps.
for wf, tier in WORKFLOWS:
    p = pathlib.Path(root) / '.github' / 'workflows' / wf
    if not p.exists():
        print(f"FAIL: {wf} is missing — cannot derive the {tier} tier from it.")
        sys.exit(1)
    for label, body, env in workflow_steps(p):
        mode = ','.join(f'{k}={v}' for k, v in sorted(env.items())
                        if k not in NEUTRAL)
        token = f'{tier}/{mode}' if mode else tier
        for stem, extra in runs_in(body).items():
            if extra:
                full_env = dict(env)
                full_env.update(extra)
                full_mode = ','.join(f'{k}={v}' for k, v in sorted(full_env.items())
                                      if k not in NEUTRAL)
                tok = f'{tier}/{full_mode}' if full_mode else tier
            else:
                tok = token
            derived[stem].add(tok)
            why.setdefault((stem, tok), f'{wf} {label}')

# (3) one closure step, iterated to a fixpoint, through the gate scripts.
for _, tier in WORKFLOWS:
    frontier = [s for s, toks in derived.items()
                if any(t == tier or t.startswith(tier + '/') for t in toks)]
    seen = set(frontier)
    while frontier:
        stem = frontier.pop()
        if stem in native_stems:
            # No `.sh` script to open for its own invocations — a native
            # gate's tier source is the matrix/`shard` field alone (source 1
            # above), already captured before this closure walk runs.
            continue
        p = pathlib.Path(root) / f'{stem}.sh'
        if not p.exists():
            print(f"FAIL: {by_stem[stem]['name']}'s `run` ({stem}.sh) does not exist on disk.")
            print("      Refusing to certify tiers from a partial closure — a registry entry")
            print("      whose script is missing cannot be walked for its own invocations.")
            sys.exit(1)
        for callee in runs_in(strip_comments(p.read_text())):
            if callee == stem:
                continue
            derived[callee].add(tier)
            why.setdefault((callee, tier), f'invoked by {stem}.sh')
            if callee not in seen:
                seen.add(callee)
                frontier.append(callee)

# ── compare. ─────────────────────────────────────────────────────────────────
violations = 0
census = collections.Counter()
for stem in sorted(by_stem):
    e = by_stem[stem]
    got = derived.get(stem) or {'ondemand'}
    want = set(e['tiers'])
    census[' '.join(sorted(got))] += 1
    if got == want:
        continue
    violations += 1
    print(f"DRIFT  {e['name']}")
    print(f"         declared  tiers = [{', '.join(repr(t) for t in sorted(want))}]")
    print(f"         derived   tiers = [{', '.join(repr(t) for t in sorted(got))}]")
    for t in sorted(got - want):
        print(f"           + {t!r}  <- {why.get((stem, t), 'nothing invokes this gate')}")
    for t in sorted(want - got):
        print(f"           - {t!r}  declared, but nothing in the tree does it")

print()
for k, v in sorted(census.items()):
    print(f"  {v:>4} gates  [{k}]")
print(f"  {len(by_stem):>4} gates  total")

if violations:
    print()
    noun = 'entry disagrees' if violations == 1 else 'entries disagree'
    print(f"FAIL: {violations} registry {noun} with the workflows about when the gate runs.")
    print("      Fix the `tiers` line in test/gates.toml to the derived set, or change")
    print("      the workflow if the declared set is the intended one. Do NOT add a")
    print("      waiver list: a tier nobody can trust is the field this gate replaced.")
    sys.exit(1)

print()
print(f"tier drift: OK — {len(by_stem)} entries, 0 disagreements with the workflows.")
PY
