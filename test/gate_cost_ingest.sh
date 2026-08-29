#!/bin/sh
# gate_cost_ingest.sh — fold `run_gates.sh` per-gate timing reports into the
# committed cost baseline (#2178, S-1-S-cost-record).
#
#   sh test/gate_cost_ingest.sh [--baseline PATH] [--allow-event EV]... \
#                               [--max-samples N] [--max-runs N] [--dry-run] \
#                               REPORT.json...
#
# A REPORT is what `GATE_TIMING_JSON=<path> sh test/run_gates.sh …` writes
# (schema `gate-cost/1`). The BASELINE (test/gate_cost_baseline.json by default)
# is a COMMITTED file: schema `gate-cost-baseline/1`, one row per gate carrying
# its retained raw samples and their median.
#
# ── WHY A COMMITTED FILE, NOT THE ACTIONS API ────────────────────────────────
# GATE-REGISTRY-DESIGN.md §7 weighed "committed file updated from CI" against
# "fetched from the Actions API at balance time" and leaned committed, for
# reviewability. This is that decision landed. The balancer (#2178's S-3) reads
# a file in the tree, so a rebalance diff can be read next to the numbers that
# caused it, the numbers are pinned at review time rather than re-fetched into a
# different answer, and the balancer has no network dependency and no token.
#
# ── WHY THE MEDIAN, NOT THE MEAN ─────────────────────────────────────────────
# One runner hiccup — a cold cache, a noisy neighbour, a retried step — is a
# single wild sample, and a mean lets it move a gate's placement. The median
# ignores it entirely unless it is the majority behaviour, which is exactly the
# question a balancer is asking ("what does this gate USUALLY cost?"). Samples
# are retained raw in the file so the median is re-derivable by any reader and
# so an outlier is visible in review rather than averaged into invisibility.
# For an even sample count the LOWER median is taken: deterministic, integral,
# and no float rounding to churn a diff.
#
# ── THE ADMISSION CHECK IS LOAD-BEARING, AND IT IS THE POINT ─────────────────
# ci.yml narrows the gate set for `pull_request` and for that event alone
# (`detect`'s `plan` step), so a pull_request run measures a SUBSET of each
# shard and its numbers are not a baseline sample. `run_gates.sh` already
# refuses to PRODUCE a report on that event; this tool independently refuses to
# ADMIT one whose recorded event is not on the allowlist, AND refuses to admit
# one whose runId/runAttempt/sha/ref provenance is empty — both conditions must
# hold. The event allowlist alone does not stop a locally-produced report that
# merely claims an admissible event string (e.g. hand-setting
# GITHUB_EVENT_NAME=push for a local run); the provenance check closes that gap,
# since only a real Actions run has those env vars set. Neither half is
# decoration: the producer's guard is what stops the artifact existing, and this
# guard is what stops a hand-carried, downloaded, or replayed artifact — or a
# future ci.yml edit — reaching the committed file. It is exercised by
# test/diff_compiler_gate_cost.sh.
#
# A FAILING gate contributes no sample: its `ms` is the cost of failing, which
# is not the cost of running, and a red gate is often red because it stopped
# early. Its run is still recorded in `runs` so the provenance is honest.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BASELINE="$ROOT/test/gate_cost_baseline.json"
# The events ci.yml CANNOT narrow (`detect` narrows on `pull_request` alone).
ALLOW="workflow_dispatch merge_group push schedule"
ALLOW_SET=0
MAX_SAMPLES=9
MAX_RUNS=24
DRY=0
reports=""

usage() {
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --baseline)     BASELINE="$2"; shift 2 ;;
    --allow-event)  if [ "$ALLOW_SET" = 0 ]; then ALLOW=""; ALLOW_SET=1; fi
                    ALLOW="$ALLOW $2"; shift 2 ;;
    --max-samples)  MAX_SAMPLES="$2"; shift 2 ;;
    --max-runs)     MAX_RUNS="$2"; shift 2 ;;
    --dry-run)      DRY=1; shift ;;
    -h|--help)      usage 0 ;;
    -*)             echo "gate_cost_ingest: unknown option '$1'"; usage 1 ;;
    *)              reports="$reports $1"; shift ;;
  esac
done

[ -n "$reports" ] || { echo "gate_cost_ingest: no report files given"; usage 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/runs.tsv"
: >"$TMP/samples.tsv"

# One provenance field out of a `gate-cost/1` report. The report is written one
# field per line by run_gates.sh, deliberately, so this needs no JSON parser.
_prov() { sed -n "s/^    \"$2\": \"\\(.*\\)\",\\{0,1\\}\$/\\1/p" "$1" | head -n 1; }

for r in $reports; do
  if [ ! -f "$r" ]; then
    echo "gate_cost_ingest: REFUSED — no such report: $r"
    exit 1
  fi
  if ! grep -q '^  "schema": "gate-cost/1",$' "$r"; then
    echo "gate_cost_ingest: REFUSED — $r is not a 'gate-cost/1' report."
    echo "  Produce one with: GATE_TIMING_JSON=<path> sh test/run_gates.sh <patterns>"
    exit 1
  fi
  ev="$(_prov "$r" event)"
  if [ -z "$ev" ]; then
    echo "gate_cost_ingest: REFUSED — $r records no provenance event."
    exit 1
  fi
  case " $ALLOW " in
    *" $ev "*) ;;
    *)
      echo "gate_cost_ingest: REFUSED — $r was produced by a '$ev' run."
      echo "  Only these events are admissible: $ALLOW"
      echo "  ci.yml narrows the gate set for pull_request and for that event alone,"
      echo "  so a narrowed run measures a SUBSET of the shard and its per-gate times"
      echo "  are not a baseline sample. A 'local' run is not a CI runner and is not"
      echo "  comparable either. This is a structural refusal, not a warning."
      exit 1
      ;;
  esac

  rid="$(_prov "$r" runId)"
  att="$(_prov "$r" runAttempt)"
  shd="$(_prov "$r" shard)"
  sha="$(_prov "$r" sha)"
  ref="$(_prov "$r" ref)"
  dat="$(_prov "$r" date)"

  # The event-string allowlist alone does not stop a locally-produced report
  # that merely CLAIMS a real CI event: nothing stops hand-setting
  # GITHUB_EVENT_NAME=push for a local run. A real workflow_dispatch/
  # merge_group/push/schedule run always has GITHUB_RUN_ID/GITHUB_RUN_ATTEMPT/
  # GITHUB_SHA/GITHUB_REF set by Actions; nothing outside Actions sets them, so
  # a local run is empty here by construction. Require all four non-empty as
  # an ADDITIONAL admission condition, alongside (not instead of) the event
  # allowlist above.
  missing=""
  [ -n "$rid" ] || missing="$missing runId"
  [ -n "$att" ] || missing="$missing runAttempt"
  [ -n "$sha" ] || missing="$missing sha"
  [ -n "$ref" ] || missing="$missing ref"
  if [ -n "$missing" ]; then
    echo "gate_cost_ingest: REFUSED — $r has a '$ev' event but missing provenance field(s):$missing"
    echo "  A real CI run of this event always sets these (github.run_id/run_attempt/"
    echo "  sha/ref in the workflow env). A locally-produced report — even one that"
    echo "  hand-tags an admissible event string — cannot have real values here."
    exit 1
  fi
  key="$rid:$att:$shd"
  ngates="$(grep -c '^    {"name": ' "$r" || true)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$key" "$rid" "$att" "$shd" "$ev" "$sha" "$ref" "$dat" "$ngates" >>"$TMP/runs.tsv"
  # name / ms, for the gates that actually PASSED.
  sed -n 's/^    {"name": "\([^"]*\)".*"ms": \([0-9][0-9]*\),.*"ok": true.*$/\1\t\2/p' \
    "$r" | while IFS='	' read -r gn gms; do
      printf '%s\t%s\t%s\n' "$key" "$gn" "$gms" >>"$TMP/samples.tsv"
    done
done

[ -f "$BASELINE" ] || : >"$TMP/empty-baseline"
OLD="$BASELINE"
[ -f "$OLD" ] || OLD="$TMP/empty-baseline"

awk -v maxs="$MAX_SAMPLES" -v maxr="$MAX_RUNS" \
    -v now="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -v oldf="$OLD" -v runsf="$TMP/runs.tsv" -v sampf="$TMP/samples.tsv" '
function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
# Lower median of the values ms[name][1..n], insertion-sorted into a scratch.
function median(n,   i, j, k, v, a) {
  for (i = 1; i <= n; i++) a[i] = SORTV[i]
  for (i = 2; i <= n; i++) {
    v = a[i]; j = i - 1
    while (j >= 1 && a[j] > v) { a[j+1] = a[j]; j-- }
    a[j+1] = v
  }
  k = int((n + 1) / 2)          # lower median: n=4 -> 2nd, n=5 -> 3rd
  return a[k]
}
BEGIN {
  nrun = 0; ngate = 0

  # ── the existing baseline ────────────────────────────────────────────────
  sect = ""
  while ((getline line < oldf) > 0) {
    if (line ~ /^  "runs": \[/)  { sect = "runs";  continue }
    if (line ~ /^  "gates": \[/) { sect = "gates"; continue }
    if (line ~ /^  \]/)          { sect = "";      continue }
    if (sect == "runs" && line ~ /^    \{"key": /) {
      raw = line; sub(/,$/, "", raw)
      match(line, /"key": "[^"]*"/); k = substr(line, RSTART + 8, RLENGTH - 9)
      if (!(k in runseen)) { runseen[k] = 1; nrun++; runorder[nrun] = k; runjson[k] = raw }
    }
    if (sect == "gates" && line ~ /^    \{"name": /) {
      match(line, /"name": "[^"]*"/); g = substr(line, RSTART + 9, RLENGTH - 10)
      match(line, /"ms": \[[^]]*\]/); arr = substr(line, RSTART + 7, RLENGTH - 8)
      if (!(g in gseen)) { gseen[g] = 1; ngate++; gorder[ngate] = g; gms[g] = "" }
      n = split(arr, parts, /, */)
      for (i = 1; i <= n; i++) if (parts[i] != "") gms[g] = gms[g] (gms[g] == "" ? "" : " ") parts[i]
    }
  }
  close(oldf)

  # ── the new runs. A run already in the baseline is SKIPPED whole (key =
  #    runId:runAttempt:shard), so re-ingesting the same artifact is a no-op
  #    rather than a second sample of the same measurement. ─────────────────
  while ((getline line < runsf) > 0) {
    split(line, f, "\t")
    k = f[1]
    if (k in runseen) { skipped[k] = 1; continue }
    runseen[k] = 1; nrun++; runorder[nrun] = k
    runjson[k] = sprintf("    {\"key\": \"%s\", \"runId\": \"%s\", \"runAttempt\": \"%s\", \"shard\": \"%s\", \"event\": \"%s\", \"sha\": \"%s\", \"ref\": \"%s\", \"date\": \"%s\", \"gates\": %s}",
                         jesc(f[1]), jesc(f[2]), jesc(f[3]), jesc(f[4]), jesc(f[5]), jesc(f[6]), jesc(f[7]), jesc(f[8]), f[9] + 0)
    accepted[k] = 1
  }
  close(runsf)

  while ((getline line < sampf) > 0) {
    split(line, f, "\t")
    if (!(f[1] in accepted)) continue
    g = f[2]
    if (!(g in gseen)) { gseen[g] = 1; ngate++; gorder[ngate] = g; gms[g] = "" }
    gms[g] = gms[g] (gms[g] == "" ? "" : " ") (f[3] + 0)
  }
  close(sampf)

  # ── emit ─────────────────────────────────────────────────────────────────
  print "{"
  print "  \"schema\": \"gate-cost-baseline/1\","
  print "  \"note\": \"Per-gate wall-clock cost, measured by test/run_gates.sh on UNNARROWED CI runs and folded in by test/gate_cost_ingest.sh. medianMs is the LOWER median of the retained raw ms samples; a balancer packs shards from it. GENERATED — do not hand-edit; re-derive from the artifacts instead.\","
  printf "  \"generated\": \"%s\",\n", now
  printf "  \"maxSamples\": %d,\n", maxs
  print "  \"runs\": ["
  first = nrun - maxr + 1; if (first < 1) first = 1
  sep = ""
  for (i = first; i <= nrun; i++) { printf "%s%s", sep, runjson[runorder[i]]; sep = ",\n" }
  if (sep != "") printf "\n"
  print "  ],"
  print "  \"gates\": ["
  # name order, insertion-sorted: a stable order is what makes the committed
  # file a readable diff rather than a reshuffle on every ingest.
  for (i = 2; i <= ngate; i++) {
    v = gorder[i]; j = i - 1
    while (j >= 1 && gorder[j] > v) { gorder[j+1] = gorder[j]; j-- }
    gorder[j+1] = v
  }
  sep = ""
  for (i = 1; i <= ngate; i++) {
    g = gorder[i]
    n = split(gms[g], sv, " ")
    lo = n - maxs + 1; if (lo < 1) lo = 1
    m = 0
    for (j = lo; j <= n; j++) { m++; SORTV[m] = sv[j] + 0 }
    if (m == 0) continue
    lst = ""
    for (j = 1; j <= m; j++) lst = lst (j == 1 ? "" : ", ") (sv[lo + j - 1] + 0)
    printf "%s    {\"name\": \"%s\", \"medianMs\": %d, \"samples\": %d, \"ms\": [%s]}",
           sep, jesc(g), median(m), m, lst
    sep = ",\n"
  }
  if (sep != "") printf "\n"
  print "  ]"
  print "}"
}
' >"$TMP/out.json" || { echo "gate_cost_ingest: merge failed"; exit 1; }

if [ "$DRY" = 1 ]; then
  cat "$TMP/out.json"
  exit 0
fi

cp "$TMP/out.json" "$BASELINE"
echo "gate_cost_ingest: wrote $BASELINE"
echo "  runs:  $(grep -c '^    {"key": ' "$BASELINE" || true)"
echo "  gates: $(grep -c '^    {"name": ' "$BASELINE" || true)"
