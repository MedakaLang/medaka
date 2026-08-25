#!/bin/sh
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
#              UNIVERSAL_GATES below), and it produces no UNMAPPED and no FULL line.
#
# THE ONE EXCEPTION. `UNIVERSAL_GATES` (in the PREFLIGHT leg) names gates that are
# repo-wide by design — they scan the whole tracked tree and have no per-file
# consumer, so preflight derives them for EVERY changed path and "outside
# `<project>/test/`" is the correct answer for them, not drift. Today that set is
# exactly one gate: `test/diff_compiler_source_bytes.sh` (the control-byte ratchet,
# #1987 F4). It is a NAMED LIST, deliberately not a pattern and not an allowlist
# mechanism — a stray gate that is stray for any other reason must still fail this
# leg, which is the whole point of the check.
#
# The PREFLIGHT leg deliberately RUNS preflight rather than reading its source: the
# thing that matters is the derivation's OUTPUT, and a gate that greps for a case
# arm would be a fourth hand-maintained copy of the map it is policing.
#
# Usage:  sh test/diff_compiler_project_enrolment.sh
# Exit:   0 every project is enrolled in all three; 1 a project is missing one.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

fails=0
checked=0

for p in $PROJECTS; do
  checked=$((checked + 1))
  echo "── $p ──────────────────────────────────────────────"

  # ── FLOOR ──────────────────────────────────────────────────────────────────
  floor="$(git -C "$ROOT" ls-files "$p/test/*.sh" 2>/dev/null)"
  if [ -z "$floor" ]; then
    echo "  FLOOR      FAIL — no tracked gate script under $p/test/."
    echo "             A project with a manifest and no floor gate cannot be enrolled:"
    echo "             a ci.yml shard pattern matching NO gate is a hard ::error::."
    fails=$((fails + 1))
  else
    echo "  FLOOR      ok — $(printf '%s\n' "$floor" | grep -c .) gate(s) under $p/test/"
  fi

  # ── CI ─────────────────────────────────────────────────────────────────────
  ci_out="$(python3 - "$ROOT" "$p" <<'PY'
import sys, glob, pathlib, re, shlex

root, proj = sys.argv[1], sys.argv[2]
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

# Resolve every pattern token against BOTH roots, exactly as run_gates.sh,
# build_oracles.sh --for, preflight's resolver and the coverage gate all do.
hits = []
for shard, pat in sorted(pats.items()):
    for tok in shlex.split(pat):
        for cand in glob.glob(f'{root}/test/{tok}.sh') + glob.glob(f'{root}/{tok}.sh'):
            rel = str(pathlib.Path(cand).relative_to(root))
            if rel.startswith(proj + '/test/'):
                hits.append((shard, tok, rel))

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
  # outside $p/test/ is correct for them specifically. Exact-match, one gate, no
  # patterns: every other stray gate still fails below.
  UNIVERSAL_GATES='test/diff_compiler_source_bytes.sh'
  stray="$(printf '%s\n' "$derived" | grep -v '^$' | grep -v "^$p/test/" \
             | grep -vxF "$UNIVERSAL_GATES" || true)"
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
