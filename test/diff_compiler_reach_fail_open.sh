#!/bin/sh
# diff_compiler_reach_fail_open.sh — a broken project-reach selector must run
# EVERYTHING, never silently skip.
#
# S-queue-scoping (#2179) taught `ci.yml`'s `detect` job to narrow a
# `merge_group` queue entry's library-project gates to the projects its diff
# actually reaches (`id: reach`, step "Derive the project reach for this queue
# entry"). Narrowing is only safe to trust if every way that derivation can go
# wrong answers `full` — the most expensive possible answer, never a silent
# skip. This gate proves that by FAULT INJECTION against the shipped step
# body, extracted verbatim out of ci.yml (never retyped), so what runs here is
# the actual script, not a paraphrase of it.
#
# Three fail-open triggers, named in the step's own banner comment
# (`.github/workflows/ci.yml`, just above `id: reach`):
#
#   DERIVATION FAILURE   `test/preflight.sh` exits nonzero.
#   UNMAPPED PATH        the changed-file set includes a path preflight (or
#                         the step's own rule-1 "outside every project" guard)
#                         has no opinion about.
#   EMPTY SELECTION      preflight succeeds, prints no FULL/UNMAPPED line, yet
#                         the derived non-compiler project set is empty.
#
# ── WHY EMPTY SELECTION IS TESTED VIA A CRAFTED INTERMEDIATE FILE ────────────
#
# The first two arms are reached with a real `changed.txt` — a real broken
# preflight, a real path outside every project. Empty selection cannot be
# reached that way under the CURRENT registry: every manifest-bearing project
# carries at least one gate whose registry `project` field is itself, so a
# real diff entirely inside one project's directory always derives at least
# one non-"compiler" project. That is a registry fact (verified below), not a
# defect in the step. Contract §7 pre-licenses exactly this situation: "if
# 'empty selection' turns out unreachable as a distinct arm, an N-way build
# differential ... discharges that arm instead." The differential here feeds
# the step's OWN post-preflight half a crafted `$RUNNER_TEMP/reach.txt` whose
# only GATE line resolves to registry `project = "compiler"` — the exact
# shape "preflight succeeded, said nothing about FULL/UNMAPPED, but derived
# zero library-project gates" — and shows the step still answers `full`.
#
# ── HONESTY NOTE: arms 1 and 3 have teeth; arm 2 cannot ─────────────────────
#
# Arms 1 (derivation failure) and 3 (empty selection) each have a paired
# "gut the fail-open branch, same fault, does the reason text vanish" check —
# a check that cannot fail proves nothing. Arm 2 (unmapped path) does NOT,
# and cannot: rule-1's "outside every project" loop and preflight's own
# UNMAPPED derivation are the SAME set/prefix test over the SAME input (see
# the file header), so they are provably redundant on every unmapped path —
# gutting either one alone leaves the other still answering `full` for the
# identical fault, which would make a single-branch teeth check pass for the
# wrong reason. That redundancy is defense in depth, verified as such below
# (arm 2's second check), not a gap this gate can close by asserting harder.
#
# Usage:  sh test/diff_compiler_reach_fail_open.sh
# Exit:   0 all arms behave (green baseline narrows; every fault answers
#         `full`, with the derivation-failure fault-handling code path shown
#         to matter — a mutated copy without it does NOT produce the same
#         reason text); 1 a fault failed to fail open; 2 setup problem.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
CI="$ROOT/.github/workflows/ci.yml"
[ -f "$CI" ] || { echo "missing $CI"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

fail=0
note() { printf '%s\n' "$1"; }
red() { printf 'FAIL: %s\n' "$1"; fail=1; }

# ── extract the shipped step body verbatim ───────────────────────────────────
cat > "$WORK/extract.py" <<'PYEOF'
import sys
STEP_NAME = "Derive the project reach for this queue entry"
def extract(ci_path, step_name):
    lines = open(ci_path).read().split("\n")
    i = 0
    while i < len(lines):
        if lines[i].strip() == "- name: %s" % step_name:
            break
        i += 1
    else:
        raise SystemExit("step not found: %s" % step_name)
    while lines[i].strip() != "run: |":
        i += 1
    indent = len(lines[i]) - len(lines[i].lstrip())
    body_indent = indent + 2
    i += 1
    out = []
    while i < len(lines):
        l = lines[i]
        if l.strip() == "":
            out.append("")
            i += 1
            continue
        if len(l) - len(l.lstrip()) < body_indent:
            break
        out.append(l[body_indent:])
        i += 1
    return "\n".join(out).rstrip() + "\n"

if __name__ == "__main__":
    body = extract(sys.argv[1], STEP_NAME)
    assert "${{" not in body, [l for l in body.split("\n") if "${{" in l]
    sys.stdout.write(body)
PYEOF
python3 "$WORK/extract.py" "$CI" > "$WORK/reach_body.sh" 2>"$WORK/extract.err"
if [ ! -s "$WORK/reach_body.sh" ]; then
  cat "$WORK/extract.err"
  echo "could not extract the 'reach' step body from ci.yml — is it still named the same?"
  exit 2
fi

run_reach() {
  # $1 = body script; changed.txt contents (one path per line) come via stdin.
  _rt="$(mktemp -d "$WORK/rt.XXXXXX")"
  cat > "$_rt/changed.txt"
  : > "$_rt/out.txt"
  ( EVENT=merge_group RUNNER_TEMP="$_rt" GITHUB_OUTPUT="$_rt/out.txt" sh "$1" ) > "$_rt/log.txt" 2>&1
  echo "$_rt"
}

# ── arm 0: green baseline — a real diff entirely inside one project ─────────
rt0="$(printf 'mq/main.mdk\n' | run_reach "$WORK/reach_body.sh")"
out0="$(cat "$rt0/out.txt" 2>/dev/null || true)"
case "$out0" in
  *project_reach=full*) red "baseline: an ordinary mq/-only diff produced project_reach=full (should narrow to 'mq'): $out0" ;;
  *project_reach=mq*)   note "OK  baseline narrows: $out0" ;;
  *)                    red "baseline: unexpected output: $out0 (log: $(cat "$rt0/log.txt")))" ;;
esac

# ── arm 1: derivation failure — test/preflight.sh exits nonzero ─────────────
cat > "$WORK/broken_preflight.sh" <<'EOF'
this is not valid shell ((( &&&
EOF
sed 's|sh test/preflight\.sh|sh '"$WORK"'/broken_preflight.sh|' \
  "$WORK/reach_body.sh" > "$WORK/reach_body_derivfail.sh"
if [ "$(grep -c 'broken_preflight' "$WORK/reach_body_derivfail.sh")" -lt 1 ]; then
  red "could not patch the preflight invocation for the derivation-failure arm — has the step body's phrasing changed?"
fi
rt1="$(printf 'mq/main.mdk\n' | run_reach "$WORK/reach_body_derivfail.sh")"
out1="$(cat "$rt1/out.txt" 2>/dev/null || true)"
reason1="refusing to narrow on a broken derivation"
case "$out1" in
  *project_reach=full*) : ;;
  *) red "derivation-failure arm: expected project_reach=full, got: $out1 (log: $(cat "$rt1/log.txt"))" ;;
esac
if ! grep -q "$reason1" "$rt1/log.txt"; then
  red "derivation-failure arm: fail-open fired but not via the preflight-exit-nonzero branch (reason text '$reason1' absent): $(cat "$rt1/log.txt")"
else
  note "OK  derivation-failure arm answers full via the preflight-exit-nonzero branch"
fi

# teeth check: the SAME fault, with that branch's code deleted, must NOT
# produce the same reason text — a check that cannot fail proves nothing.
python3 - "$WORK/reach_body_derivfail.sh" "$WORK/reach_body_derivfail_gutted.sh" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")
out = []
skip = 0
i = 0
while i < len(lines):
    l = lines[i]
    if l.strip().startswith("if ! PREFLIGHT_DRY=1"):
        # this if-block spans until its matching 'fi'
        depth = 0
        while True:
            if lines[i].strip() == "fi":
                i += 1
                break
            i += 1
        continue
    out.append(l)
    i += 1
open(dst, "w").write("\n".join(out))
PYEOF
if [ ! -s "$WORK/reach_body_derivfail_gutted.sh" ]; then
  red "could not gut the derivation-failure fail-open branch for the teeth check — has the step body's shape changed?"
else
  rt1g="$(printf 'mq/main.mdk\n' | run_reach "$WORK/reach_body_derivfail_gutted.sh")"
  if grep -q "$reason1" "$rt1g/log.txt"; then
    red "teeth check failed: removing the derivation-failure fail-open branch STILL produced its reason text — the check proves nothing: $(cat "$rt1g/log.txt")"
  else
    note "OK  teeth check: gutting the derivation-failure branch removes its reason text (log: $(head -c 200 "$rt1g/log.txt" | tr '\n' ' '))"
  fi
fi

# ── arm 2: unmapped path — a changed path preflight has no opinion about ────
# A path with no manifest-bearing ancestor is outside every library project;
# the step's own rule-1 guard (identical set/prefix test to preflight's
# UNMAPPED derivation, see the file header) answers full for it before
# preflight is even invoked — same fail-open OUTCOME the contract names,
# verified against the real code path rather than a synthetic one. Not under
# demo/ or playground/ on purpose: those two go through a fixture-consumer
# grep (`_gates_for_path`) that would treat this very script's own source
# text as a false "consumer" if the probed path's name showed up in it
# (verified the hard way — an earlier draft used `demo/some_file.mdk` and the
# grep matched this script's own comments). A path outside every project and
# outside demo/playground hits the bare `note_unmapped` catch-all directly,
# with no text-matching involved.
rt2="$(printf 'zzz_unmapped_probe_dir/nothing.mdk\n' | run_reach "$WORK/reach_body.sh")"
out2="$(cat "$rt2/out.txt" 2>/dev/null || true)"
case "$out2" in
  *project_reach=full*) note "OK  unmapped-path arm answers full: $(cat "$rt2/log.txt")" ;;
  *) red "unmapped-path arm: expected project_reach=full for a path with no project opinion, got: $out2 (log: $(cat "$rt2/log.txt"))" ;;
esac

# corroborate that this path is genuinely UNMAPPED as far as preflight itself
# is concerned (not merely "outside" by some unrelated rule) — this IS this
# arm's teeth: it shows the redundancy (see file header) is real, not
# assumed. No branch-deletion teeth check follows, by construction (header).
: > "$WORK/pf_changed.txt"
printf 'zzz_unmapped_probe_dir/nothing.mdk\n' > "$WORK/pf_changed.txt"
pf_out="$(PREFLIGHT_DRY=1 PREFLIGHT_CHANGED_FILE="$WORK/pf_changed.txt" sh test/preflight.sh 2>&1)"
if printf '%s' "$pf_out" | grep -q '^  UNMAPPED '; then
  note "OK  preflight itself independently reports UNMAPPED for the same path"
else
  red "preflight did not report UNMAPPED for zzz_unmapped_probe_dir/nothing.mdk — the unmapped-path scenario may no longer be constructed correctly: $pf_out"
fi

# ── arm 3: empty selection — preflight succeeds, no FULL/UNMAPPED, yet the
#    derived project set (excluding "compiler") is empty ────────────────────
#
# Reachability check first: does the registry give every manifest-bearing
# project at least one gate whose own `project` field is itself? If yes (as
# today), a real diff can never construct this arm — confirmed, then
# discharged via the pre-licensed N-way differential instead.
projects="$(git ls-files '*medaka.toml' 2>/dev/null | grep -v '^test/' | grep -v '^compiler/' | sed 's|/medaka\.toml$||' | sort -u)"
naturally_reachable=""
for p in $projects; do
  cnt="$(awk -v p="$p" '/^\[\[gate\]\]/{proj=""} /^project *= *"/{proj=$0; sub(/^project *= *"/,"",proj); sub(/".*$/,"",proj)} /^run *= *"/{r=$0; sub(/^run *= *"/,"",r); sub(/".*$/,"",r)} r ~ "^" p "/" && proj == p {c++} END{print c+0}' test/gates.toml)"
  if [ "${cnt:-0}" -eq 0 ]; then
    naturally_reachable="$naturally_reachable $p"
  fi
done
if [ -n "$naturally_reachable" ]; then
  red "REGISTRY CHANGED: project(s)$naturally_reachable now have NO self-owned gate — the empty-selection arm may be naturally reachable now; this gate's N-way-differential discharge is stale and needs a real fault-injection arm instead."
else
  note "OK  registry check: every manifest-bearing project owns >=1 gate under its own name — empty-selection is unreachable via a real diff (pre-licensed fallback applies)"
fi

# N-way differential: (a) real post-preflight half fed a crafted reach.txt
# whose only GATE resolves to project="compiler" -> must answer full;
# (b) the same input through a copy with the "zero library-project gates"
# fail-open branch deleted -> must NOT answer full (teeth for this arm too).
rt3="$WORK/rt3"
mkdir -p "$rt3"
cat > "$rt3/reach.txt" <<'EOF'
  GATE      test/diff_compiler_source_bytes.sh
EOF
# The real body always calls preflight itself and overwrites reach.txt, so
# to exercise the parsing/empty-check half specifically, split the body at
# the preflight invocation and run only the tail against our crafted
# reach.txt directly.
python3 - "$WORK/reach_body.sh" "$WORK/reach_body_tail.sh" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")
# keep the head verbatim through the end of the full() function definition
# (its own closing '}') so the tail still has `full` available ...
head = []
i = 0
while i < len(lines):
    head.append(lines[i])
    if lines[i].strip() == "}":
        i += 1
        break
    i += 1
# ... then skip everything up to and including the preflight if-block, and
# keep the rest verbatim.
marker = 'if ! PREFLIGHT_DRY=1'
while i < len(lines) and marker not in lines[i]:
    i += 1
if i >= len(lines):
    raise SystemExit("marker not found")
while lines[i].strip() != "fi":
    i += 1
i += 1
tail = lines[i:]
out = head + tail
open(dst, "w").write("\n".join(out))
PYEOF
if [ ! -s "$WORK/reach_body_tail.sh" ]; then
  red "could not split the step body at the preflight call for the empty-selection arm — has the step body's shape changed?"
else
  rt3b="$WORK/rt3b"
  mkdir -p "$rt3b"
  cp "$rt3/reach.txt" "$rt3b/reach.txt"
  : > "$rt3b/out.txt"
  ( RUNNER_TEMP="$rt3b" GITHUB_OUTPUT="$rt3b/out.txt" sh "$WORK/reach_body_tail.sh" ) > "$rt3b/log.txt" 2>&1
  out3b="$(cat "$rt3b/out.txt" 2>/dev/null || true)"
  case "$out3b" in
    *project_reach=full*) note "OK  empty-selection differential (real code, crafted reach.txt): $out3b" ;;
    *) red "empty-selection differential: crafted reach.txt (only a project=compiler GATE line) did not answer full, got: $out3b (log: $(cat "$rt3b/log.txt"))" ;;
  esac

  # teeth: gut the "zero library-project gates" fail-open and re-run —
  # must NOT answer full via that reason text.
  python3 - "$WORK/reach_body_tail.sh" "$WORK/reach_body_tail_gutted.sh" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")
out = []
i = 0
while i < len(lines):
    l = lines[i]
    if l.strip().startswith('[ -n "$reach" ] ||'):
        i += 1
        continue
    out.append(l)
    i += 1
open(dst, "w").write("\n".join(out))
PYEOF
  rt3c="$WORK/rt3c"
  mkdir -p "$rt3c"
  cp "$rt3/reach.txt" "$rt3c/reach.txt"
  : > "$rt3c/out.txt"
  ( RUNNER_TEMP="$rt3c" GITHUB_OUTPUT="$rt3c/out.txt" sh "$WORK/reach_body_tail_gutted.sh" ) > "$rt3c/log.txt" 2>&1
  reason3="zero library-project gates"
  if grep -q "$reason3" "$rt3c/log.txt"; then
    red "teeth check failed: removing the empty-selection fail-open branch STILL produced its reason text: $(cat "$rt3c/log.txt")"
  else
    note "OK  teeth check: gutting the empty-selection branch removes its reason text"
  fi
fi

if [ "$fail" -eq 0 ]; then
  echo "diff_compiler_reach_fail_open: PASS — green baseline narrows, all fault arms answer full"
  exit 0
else
  echo "diff_compiler_reach_fail_open: FAIL — see FAIL lines above"
  exit 1
fi
