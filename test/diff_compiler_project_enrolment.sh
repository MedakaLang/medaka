#!/bin/sh
# shell-because: trust-anchor — circular: checks the machinery a native gate would run inside
# diff_compiler_project_enrolment.sh — a monorepo project must be CI'd, and the
# THREE independent consumers of "what is a project" must agree about it.
#
# WHAT IS A PROJECT? One answer, derived, never hand-listed: a directory holding a
# `medaka.toml`, outside `compiler/` (a project, but one with its own arms and its
# own gates everywhere) and outside `test/` (those manifests are FIXTURES for the
# loader's multi-project tests, not projects to CI). Today that is six directories.
#
# WHY THIS GATE EXISTS
# --------------------
# Enrolment used to be hand-maintained in three places that had no way to notice
# each other drifting:
#
#   1. test/preflight.sh   three pasted case arms (sqlite, gzip, pds) mapping a
#                          changed path to the project's gates.
#   2. .github/workflows/  a shard `pattern:` naming the project's gates.
#      ci.yml
#   3. the gates on disk   `<project>/test/*.sh` — the floor. AGENTS.md [W-THIRD-
#                          CONSUMER] names exactly this three-way split.
#
# `mq/`, `parsec/` and `byteparser/` landed with manifests and had NONE of the
# three for months. The failure mode is silent in the worst direction: a change to
# an unenrolled project derived ZERO gates and ONE UNMAPPED path, which ci.yml then
# widened to the FULL suite — so it neither tested the project NOR looked cheap. A
# missing arm reads exactly like a project nobody has an opinion about.
#
# Preflight now derives (1) from the same `git ls-files '*medaka.toml'` rule this
# gate uses, so (1) cannot drift by construction. (2) and (3) still can, and a
# derivation is only as good as the thing that proves it is still wired up — so
# this gate re-asks all three questions from scratch, every run:
#
#   FLOOR      at least one tracked gate script under `<project>/test/`.
#   CI         some ci.yml shard pattern resolves to a gate under `<project>/test/`.
#   PREFLIGHT  a changed file under `<project>/` derives at least one gate, every
#              derived gate lives under `<project>/test/` (except the named
#              UNIVERSAL_GATES or a graph-derived EXTRA gate, both below), and it
#              produces no UNMAPPED and no FULL line.
#   REACH      preflight's shell-derived project-graph set agrees with `./medaka
#              gate reach --json`'s canonical answer, on one representative path
#              per project plus the parsec→sqlite dependency case. This is the
#              FOURTH assertion — see "THE GRAPH EXCEPTION" below.
#
# THE UNIVERSAL EXCEPTIONS. `UNIVERSAL_GATES` (in the PREFLIGHT leg) names gates
# that are repo-wide by design — they scan the whole tracked tree and have no
# per-file consumer, so preflight derives them for EVERY changed path and
# "outside `<project>/test/`" is the correct answer for them, not drift. Today
# that set is two gates: `test/diff_compiler_source_bytes.sh` (the control-byte
# ratchet, #1987 F4) and `test/diff_compiler_comment_shout_diff.sh` (the
# diff-scoped emoji-shout check, #2621 — it re-scans every changed `.mdk`
# whatever project it lives under). It is a NAMED LIST, deliberately not a
# pattern and not an allowlist mechanism — a stray gate that is stray for any
# other reason must still fail this leg, which is the whole point of the check.
#
# THE GRAPH EXCEPTION. preflight's generic project arm now also widens across the
# project GRAPH: a dependency edge (from a manifest's `[dependencies]`, e.g.
# sqlite depends on parsec) runs the CONSUMER's gates when the DEPENDENCY changes,
# and a corpus edge (from `test/gates.toml`'s `corpus =`/`project =` fields, e.g.
# `wasm/diff_gzip` reads the `gzip` project's fixtures) runs that gate on ANY
# change to the project whose corpus it consumes — not just a change under that
# project's own `test/`. So "outside `<project>/test/`" is no longer proof of
# drift by itself; EXTRA_MAP (below) computes, from the SAME manifests and
# `test/gates.toml` fields, which extra gates are legitimate for each project, and
# the stray check subtracts those before judging. A gate that is stray for any
# OTHER reason still fails.
#
# The PREFLIGHT leg deliberately RUNS preflight rather than reading its source: the
# thing that matters is the derivation's OUTPUT, and a gate that greps for a case
# arm would be a fourth hand-maintained copy of the map it is policing. EXTRA_MAP
# is a tolerance list, not a second source of truth — the REACH leg is what
# actually polices preflight's derivation against the canonical `medaka gate
# reach` answer.
#
# Usage:  sh test/diff_compiler_project_enrolment.sh
# Exit:   0 every project is enrolled in all three; 1 a project is missing one.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/test/gate_native_rows.sh"
command -v python3 >/dev/null 2>&1 || { echo "python3 not found (needed to parse the workflow YAML)"; exit 2; }

# ── the project set — the SAME rule test/preflight.sh's generic arm uses ──────
PROJECTS="$(git -C "$ROOT" ls-files '*medaka.toml' 2>/dev/null \
  | grep -v '^test/' | grep -v '^compiler/' \
  | sed 's|/medaka\.toml$||' | sort -u)"

if [ -z "$PROJECTS" ]; then
  echo "FAIL: derived ZERO projects from \`git ls-files '*medaka.toml'\`."
  echo "      This repo has at least sqlite/ and gzip/. An empty project set means the"
  echo "      derivation broke, not that enrolment is perfect — refusing to certify."
  exit 1
fi

# ── EXTRA_MAP: "<project> <extra-gate-or-test-prefix>" pairs the PREFLIGHT leg's
# stray check tolerates — derived from manifests' `[dependencies]` and
# `test/gates.toml`'s `corpus =`/`project =` fields, the same two sources
# test/preflight.sh's generic project arm reads. Lines ending in `/test/` are a
# whole consumer project's gate tree (dependency edge); other lines are one exact
# gate path (corpus edge).
EXTRA_MAP="$(python3 - "$ROOT" "$PROJECTS" <<'PY'
import sys, re, pathlib

root = sys.argv[1]
projects = sys.argv[2].split()

dep_edges = []  # (consumer, dependency)
for p in projects:
    mf = pathlib.Path(root) / p / "medaka.toml"
    if not mf.exists():
        continue
    in_deps = False
    for line in mf.read_text().splitlines():
        line = line.strip()
        if line.startswith('[dependencies]'):
            in_deps = True
            continue
        if line.startswith('['):
            in_deps = False
            continue
        if not in_deps or '=' not in line:
            continue
        name = line.split('=', 1)[0].strip()
        if name:
            dep_edges.append((p, name))

# corpus edges: gate -> project, only project="compiler" gates (a gate owned by
# a library project already lives under that project's own test/).
gt = pathlib.Path(root) / "test" / "gates.toml"
corpus_edges = []
cur_name = cur_project = cur_corpus = None
def flush():
    if cur_name and cur_project == "compiler" and cur_corpus:
        for c in cur_corpus:
            if c in projects:
                corpus_edges.append((cur_name, c))
for line in gt.read_text().splitlines():
    line = line.strip()
    if line == "[[gate]]":
        flush()
        cur_name = cur_project = cur_corpus = None
        continue
    if line.startswith('name = "'):
        cur_name = line[len('name = "'):-1]
    elif line.startswith('project = "'):
        cur_project = line[len('project = "'):-1]
    elif line.startswith('corpus = ['):
        inner = line[len('corpus = ['):-1]
        cur_corpus = re.findall(r'"([^"]*)"', inner)
flush()

def consumers_of(target):
    seen = {target}
    changed = True
    while changed:
        changed = False
        for c, d in dep_edges:
            if d in seen and c not in seen:
                seen.add(c)
                changed = True
    return seen

for p in projects:
    aff = consumers_of(p)
    for a in aff:
        print(f"{p} {a}/test/")
    for gate, corpus_p in corpus_edges:
        if corpus_p in aff:
            print(f"{p} test/{gate}.sh")
PY
)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

fails=0
checked=0

for p in $PROJECTS; do
  checked=$((checked + 1))
  echo "── $p ──────────────────────────────────────────────"

  # ── FLOOR ──────────────────────────────────────────────────────────────────
  # A floor gate can be a `.sh` script OR a `kind = "native"` registry row whose
  # `run` sits under `<project>/test/` (#2591; run_gates.sh/preflight/build_
  # oracles.sh all already resolve a native gate by registry row the same way).
  floor="$(git -C "$ROOT" ls-files "$p/test/*.sh" 2>/dev/null)"
  native_floor="$(_native_rows | awk '{print $2}' | grep "^$p/test/" || true)"
  if [ -z "$floor" ] && [ -z "$native_floor" ]; then
    echo "  FLOOR      FAIL — no tracked gate script or native gate under $p/test/."
    echo "             A project with a manifest and no floor gate cannot be enrolled:"
    echo "             a ci.yml shard pattern matching NO gate is a hard ::error::."
    fails=$((fails + 1))
  else
    _floor_n=$(( $(printf '%s\n' "$floor" | grep -c .) + $(printf '%s\n' "$native_floor" | grep -c .) ))
    echo "  FLOOR      ok — $_floor_n gate(s) under $p/test/"
  fi

  # ── CI ─────────────────────────────────────────────────────────────────────
  ci_out="$(python3 - "$ROOT" "$p" "$(_native_rows)" <<'PY'
import sys, fnmatch, glob, pathlib, re, shlex

root, proj = sys.argv[1], sys.argv[2]

# "<name> <run>" per line, from test/gate_native_rows.sh — the ONE parser for a
# `kind = "native"` row (#2636). Parsed in the shell and handed down rather than
# re-read here, so this arm cannot drift from the FLOOR arm above, which asks
# the same helper the same question.
native = [l.split(None, 1) for l in sys.argv[3].splitlines() if l.strip()]
wfdir = pathlib.Path(root) / '.github' / 'workflows'
wf_paths = sorted(wfdir.glob('*.yml')) + sorted(wfdir.glob('*.yaml'))

# Shard patterns come from a job shaped like ci.yml's `gates` job (a
# strategy.matrix.include list of {name, pattern} dicts) — the same extraction
# diff_compiler_ci_shard_coverage.sh does, and deliberately not a second, looser
# regex of its own.
pats = {}
for wf in wf_paths:
    txt = wf.read_text()
    try:
        import yaml
        doc = yaml.safe_load(txt)
        for job in (doc.get('jobs') or {}).values():
            include = (((job or {}).get('strategy') or {}).get('matrix') or {}).get('include')
            if not include:
                continue
            for e in include:
                if 'name' in e and 'pattern' in e:
                    pats[e['name']] = e['pattern']
    except Exception:
        pats.update(dict(re.findall(r'- name: (\w+)\n\s+pattern: "([^"]+)"', txt)))

if not pats:
    print("ERROR no shard patterns could be read out of any workflow file")
    sys.exit(0)

# Resolve every pattern token two ways, because a gate is reached two ways.
#
#  * `kind = "exec"`: the token is a path stem under either root, so glob it as
#    `.sh` — run_gates.sh's own two-glob rule.
#  * `kind = "native"` (#2592): there is no `.sh` to glob. The token is matched
#    against the registry NAME and the row's `run` module is the gate, exactly
#    as run_gates.sh, build_oracles.sh --for and preflight's resolver do it. A
#    token is a shell glob in all four, so fnmatch, not equality.
#
# Both arms key on the resolved repo-relative path being under `<proj>/test/`,
# so a project whose floor gate is a native row is reported reached rather than
# MISSING — which is what it would read as if only the `.sh` arm existed.
hits = []
for shard, pat in sorted(pats.items()):
    for tok in shlex.split(pat):
        for cand in glob.glob(f'{root}/test/{tok}.sh') + glob.glob(f'{root}/{tok}.sh'):
            rel = str(pathlib.Path(cand).relative_to(root))
            if rel.startswith(proj + '/test/'):
                hits.append((shard, tok, rel))
        for name, run in native:
            if fnmatch.fnmatch(name, tok) and run.startswith(proj + '/test/'):
                hits.append((shard, tok, run))

if not hits:
    print("MISSING")
else:
    shards = sorted({h[0] for h in hits})
    toks = sorted({h[1] for h in hits})
    print("OK %d gate(s) via %s in shard(s) %s"
          % (len({h[2] for h in hits}), ' '.join(toks), ' '.join(shards)))
PY
)"
  case "$ci_out" in
    OK*)      echo "  CI         ${ci_out}" ;;
    MISSING)
      echo "  CI         FAIL — no ci.yml shard pattern resolves to any gate under $p/test/."
      echo "             The project's gates exist but CI never runs them. Add a glob"
      echo "             (e.g. '$p/test/*') to a shard's pattern: in .github/workflows/ci.yml,"
      echo "             chosen by measured cost (sh scripts/ci_shard_cost.sh)."
      fails=$((fails + 1)) ;;
    *)
      echo "  CI         FAIL — $ci_out"
      fails=$((fails + 1)) ;;
  esac

  # ── PREFLIGHT ──────────────────────────────────────────────────────────────
  # A path that need not exist: PREFLIGHT_CHANGED_FILE is a LIST, and preflight
  # already handles deleted paths. Using a synthetic name keeps the probe from
  # depending on which files a project happens to have today.
  printf '%s/lib/__enrolment_probe__.mdk\n' "$p" > "$WORK/changed.txt"
  if ! PREFLIGHT_DRY=1 PREFLIGHT_CHANGED_FILE="$WORK/changed.txt" \
       sh "$ROOT/test/preflight.sh" > "$WORK/pf.out" 2>&1; then
    echo "  PREFLIGHT  FAIL — preflight exited nonzero on a $p/ path:"
    sed 's/^/             /' "$WORK/pf.out"
    fails=$((fails + 1))
    continue
  fi
  derived="$(sed -n 's/^  GATE      //p' "$WORK/pf.out")"
  n_unmapped="$(grep -c '^  UNMAPPED  ' "$WORK/pf.out" || true)"
  n_full="$(grep -c '^  FULL      ' "$WORK/pf.out" || true)"
  # The named universal set — see "THE ONE EXCEPTION" in this script's header.
  # These are repo-wide gates preflight derives for EVERY changed path, so being
  # outside $p/test/ is correct for them specifically. Exact-match names only,
  # no patterns: every other stray gate still fails below. One name per line
  # (not a single grep -F pattern) because grep -F treats an embedded newline
  # as part of one literal, which would require a multi-line match instead of
  # matching either name on its own line.
  UNIVERSAL_GATES='test/diff_compiler_source_bytes.sh
test/diff_compiler_comment_shout_diff.sh'
  stray="$(printf '%s\n' "$derived" | grep -v '^$' | grep -v "^$p/test/" || true)"
  for ug in $UNIVERSAL_GATES; do
    stray="$(printf '%s\n' "$stray" | grep -vxF "$ug" || true)"
  done
  # Subtract graph-derived EXTRA gates — see "THE GRAPH EXCEPTION" in this
  # script's header. Lines ending in `/test/` allow a whole consumer project's
  # gate tree (dependency edge); other lines are one exact corpus-edge gate path.
  if [ -n "$stray" ]; then
    extra="$(printf '%s\n' "$EXTRA_MAP" | awk -v p="$p" '$1==p{print $2}')"
    for ex in $extra; do
      case "$ex" in
        */test/) stray="$(printf '%s\n' "$stray" | grep -v "^${ex}" || true)" ;;
        *)       stray="$(printf '%s\n' "$stray" | grep -vxF "$ex" || true)" ;;
      esac
    done
  fi
  if [ -z "$derived" ]; then
    echo "  PREFLIGHT  FAIL — a change under $p/ derives ZERO gates."
    echo "             Every such change then reads as UNMAPPED to ci.yml's detect job,"
    echo "             which widens the PR run to the FULL suite while proving nothing"
    echo "             about $p/. Check test/preflight.sh's manifest-derived arm."
    fails=$((fails + 1))
  elif [ "$n_unmapped" != "0" ] || [ "$n_full" != "0" ]; then
    echo "  PREFLIGHT  FAIL — a change under $p/ still yields UNMAPPED/FULL lines:"
    grep -E '^  (UNMAPPED|FULL)  ' "$WORK/pf.out" | sed 's/^/             /'
    fails=$((fails + 1))
  elif [ -n "$stray" ]; then
    echo "  PREFLIGHT  FAIL — a change under $p/ derives gate(s) outside $p/test/:"
    printf '%s\n' "$stray" | sed 's/^/             /'
    fails=$((fails + 1))
  else
    echo "  PREFLIGHT  ok — $(printf '%s\n' "$derived" | grep -c .) gate(s), all under $p/test/ or in the named universal set, no UNMAPPED/FULL"
  fi

  # ── REACH ──────────────────────────────────────────────────────────────────
  # The fourth assertion: preflight's shell-derived project-graph set (THE GRAPH
  # EXCEPTION, above) must agree with `./medaka gate reach --json`'s canonical
  # answer for the SAME changed path — this is what lets preflight's manifest/
  # gates.toml reimplementation drift out of sync with the reference without
  # going unnoticed. Needs a built `./medaka` (this gate runs inside
  # test/run_gates.sh, after `make medaka`).
  if [ ! -x "$ROOT/medaka" ]; then
    echo "  REACH      FAIL — no built $ROOT/medaka (this gate needs one; run_gates.sh builds it first)."
    fails=$((fails + 1))
  else
    reach_json="$(MEDAKA_STRICT=1 "$ROOT/medaka" gate reach --json -- "$p/lib/__enrolment_probe__.mdk" 2>"$WORK/reach.err")"
    reach_projects="$(printf '%s' "$reach_json" \
      | python3 -c 'import json,sys
try:
    print(" ".join(sorted(json.load(sys.stdin)["projects"])))
except Exception:
    pass' 2>/dev/null)"
    if [ -z "$reach_projects" ]; then
      echo "  REACH      FAIL — \`medaka gate reach --json -- $p/lib/__enrolment_probe__.mdk\` produced no usable output:"
      sed 's/^/             /' "$WORK/reach.err"
      fails=$((fails + 1))
    else
      # Build preflight's equivalent project set from $derived: $p itself, every
      # OTHER project whose test/ prefix shows up (a dependency-edge widening),
      # and "compiler" if anything else survived the UNIVERSAL_GATES filter (a
      # corpus edge — `reach` names the gate's OWNING project, "compiler", not
      # the library project the gate reads, so this is the correct comparison,
      # not a looser one).
      shell_set="$p"
      for pr2 in $PROJECTS; do
        case "$pr2" in "$p") continue ;; esac
        printf '%s\n' "$derived" | grep -q "^$pr2/test/" && shell_set="$shell_set $pr2"
      done
      other="$(printf '%s\n' "$derived" | grep -v '^$' || true)"
      for pr2 in $PROJECTS; do
        other="$(printf '%s\n' "$other" | grep -v "^$pr2/test/" || true)"
      done
      other="$(printf '%s\n' "$other" | grep -vxF "$UNIVERSAL_GATES" || true)"
      [ -n "$other" ] && shell_set="$shell_set compiler"
      shell_norm="$(printf '%s\n' $shell_set | sort -u | tr '\n' ' ' | sed 's/ *$//')"
      reach_norm="$(printf '%s\n' $reach_projects | sort -u | tr '\n' ' ' | sed 's/ *$//')"
      if [ "$shell_norm" != "$reach_norm" ]; then
        echo "  REACH      FAIL — preflight's derived project set disagrees with \`medaka gate reach\`:"
        echo "             preflight: $shell_norm"
        echo "             reach:     $reach_norm"
        fails=$((fails + 1))
      else
        echo "  REACH      ok — preflight agrees with \`medaka gate reach\`: $shell_norm"
      fi
    fi
  fi
done

echo
if [ "$fails" -eq 0 ]; then
  echo "OK: $checked manifest-bearing project(s), each with a floor gate, a ci.yml shard, and a preflight derivation."
  exit 0
fi
echo "FAIL: $fails enrolment problem(s) across $checked manifest-bearing project(s)."
echo "  See this script's header: a project that is not enrolled in all three is not"
echo "  merely untested — it silently widens every PR run to the FULL suite."
exit 1
