#!/bin/sh
# diff_compiler_gate_cost.sh — the per-gate cost transport's own gate (#2178,
# S-1-S-cost-record).
#
# It grades three things, and the FIRST TWO are the ones that matter:
#
#   1. The PRODUCER refuses. `test/run_gates.sh` writes no timing report at all
#      when `GITHUB_EVENT_NAME` is a pull_request — the one event ci.yml narrows
#      (`detect`'s `plan` step). A narrowed run measures a SUBSET of each shard;
#      its per-gate times are not a baseline sample and its shard wall-clock is
#      meaningless for balancing.
#   2. The CONSUMER refuses. `test/gate_cost_ingest.sh` rejects any report whose
#      recorded event is not on its allowlist, rejects one whose runId/
#      runAttempt/sha/ref provenance is empty (both conditions required — the
#      event string alone does not stop a locally-produced report that merely
#      claims an admissible event), and rejects a document that is not a
#      `gate-cost/1` report at all. This half is what stops a hand-carried,
#      downloaded, or replayed artifact reaching the committed baseline even
#      though the producer would never have made one — and it is what stops a
#      future ci.yml edit from quietly re-opening the path. "The workflow does
#      not call it for that event" is not a guard; this is.
#   3. The arithmetic and the committed file. The lower median is what the file
#      says it is, re-ingesting one run twice is a no-op rather than a duplicate
#      sample, a FAILING gate contributes no sample, and the committed
#      test/gate_cost_baseline.json's medianMs values still agree with the raw
#      samples printed beside them — so the file cannot drift from its own data.
#
# The producer half runs against a SCRATCH TREE (a copy of run_gates.sh plus one
# trivial fake gate under `mktemp -d`), not against this repo's real gates: the
# property under test is the report-writing path, and running real gates to
# observe it would make this gate cost what they cost and depend on their
# oracles.
#
# Usage:  sh test/diff_compiler_gate_cost.sh
# Exit:   0 all checks pass, 1 a check failed.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INGEST="$ROOT/test/gate_cost_ingest.sh"
BASELINE="$ROOT/test/gate_cost_baseline.json"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

echo "── gate cost transport (#2178) ─────────────────────────────────────────"

# ── a scratch tree with exactly one, trivial, oracle-free gate ────────────────
mkdir -p "$TMP/tree/test"
cp "$ROOT/test/run_gates.sh"  "$TMP/tree/test/run_gates.sh"
cp "$ROOT/test/lib_scratch.sh" "$TMP/tree/test/lib_scratch.sh"
cat >"$TMP/tree/test/diff_compiler_fake_pass.sh" <<'FAKE'
#!/bin/sh
# a fake gate: costs a measurable but tiny amount of wall clock, and passes.
i=0
while [ "$i" -lt 200 ]; do i=$((i + 1)); done
echo "fake gate ok"
exit 0
FAKE
cat >"$TMP/tree/test/diff_compiler_fake_fail.sh" <<'FAKE'
#!/bin/sh
echo "fake gate deliberately red"
exit 1
FAKE

_run_gates() {
  # $1 = event, $2 = report path, rest = patterns
  _ev="$1"; _out="$2"; shift 2
  env GITHUB_EVENT_NAME="$_ev" GITHUB_RUN_ID="${RUNID:-4242}" GITHUB_RUN_ATTEMPT=1 \
      GITHUB_REPOSITORY=MedakaLang/medaka GITHUB_REF=refs/heads/testing-arc \
      GITHUB_SHA="${SHA:-cafebabe}" GATE_TIMING_SHARD="${SHARD:-scratch}" \
      GATE_TIMING_JSON="$_out" JOBS=2 \
      sh "$TMP/tree/test/run_gates.sh" "$@" >"$TMP/rg.log" 2>&1
}

# ── 1. the producer refuses on a narrowable event ─────────────────────────────
_run_gates pull_request "$TMP/pr.json" 'diff_compiler_fake_pass'
if [ -e "$TMP/pr.json" ]; then
  bad "producer wrote a timing report on a pull_request run — the narrowable event"
  sed -n '1,20p' "$TMP/pr.json"
else
  ok "producer writes NO timing report on a pull_request run"
fi
if grep -q 'REFUSING to write a timing report' "$TMP/rg.log"; then
  ok "producer says why it refused (the refusal is visible, not silent)"
else
  bad "producer refused silently — no explanation in its output"
  cat "$TMP/rg.log"
fi

# ── 2. the producer emits on an unnarrowable event, with a real measurement ───
_run_gates workflow_dispatch "$TMP/wd.json" 'diff_compiler_fake_pass'
if [ ! -f "$TMP/wd.json" ]; then
  bad "producer wrote no report on a workflow_dispatch run"
  cat "$TMP/rg.log"
else
  ok "producer wrote a report on a workflow_dispatch run"
  grep -q '^  "schema": "gate-cost/1",$' "$TMP/wd.json" \
    && ok "report carries schema gate-cost/1" \
    || bad "report is missing its schema line"
  grep -q '"event": "workflow_dispatch"' "$TMP/wd.json" \
    && ok "report records its provenance event" \
    || bad "report records no provenance event"
  grep -q '"runId": "4242"' "$TMP/wd.json" \
    && ok "report records the CI run id" \
    || bad "report records no run id"
  # ms must be a real measurement, not a zero-filled placeholder.
  _ms="$(sed -n 's/^    {"name": "diff_compiler_fake_pass".*"ms": \([0-9][0-9]*\),.*$/\1/p' "$TMP/wd.json")"
  if [ -n "$_ms" ] && [ "$_ms" -ge 0 ] 2>/dev/null; then
    ok "per-gate ms is present and numeric (fake gate: ${_ms}ms)"
  else
    bad "per-gate ms is absent or non-numeric"
    cat "$TMP/wd.json"
  fi
  # rowElapsedMs (#2208): the whole fan-out's own wall clock, a NEW top-level
  # field distinct from any single gate's ms — must be present and numeric.
  _row="$(sed -n 's/^  "rowElapsedMs": \([0-9][0-9]*\),\{0,1\}$/\1/p' "$TMP/wd.json")"
  if [ -n "$_row" ] && [ "$_row" -ge 0 ] 2>/dev/null; then
    ok "rowElapsedMs is present and numeric (fake row: ${_row}ms)"
  else
    bad "rowElapsedMs is absent or non-numeric"
    cat "$TMP/wd.json"
  fi
fi

# ── 3. the consumer refuses a narrowed-event report ───────────────────────────
#
# The producer will never make one, which is exactly why this must be tested
# with a hand-built artifact: the question is whether the INGEST path admits it,
# not whether CI happens to produce it.
sed 's/"event": "workflow_dispatch"/"event": "pull_request"/' "$TMP/wd.json" >"$TMP/poison.json"
if sh "$INGEST" --dry-run --baseline "$TMP/none.json" "$TMP/poison.json" >"$TMP/poison.out" 2>&1; then
  bad "ingest ACCEPTED a pull_request-tagged report — the baseline is poisonable"
  cat "$TMP/poison.out"
else
  if grep -q "produced by a 'pull_request' run" "$TMP/poison.out"; then
    ok "ingest refuses a pull_request-tagged report, naming the event"
  else
    bad "ingest exited nonzero but not for the event — check the message"
    cat "$TMP/poison.out"
  fi
fi

# A local run is not a CI runner either.
sed 's/"event": "workflow_dispatch"/"event": "local"/' "$TMP/wd.json" >"$TMP/local.json"
if sh "$INGEST" --dry-run --baseline "$TMP/none.json" "$TMP/local.json" >/dev/null 2>&1; then
  bad "ingest accepted a 'local' report"
else
  ok "ingest refuses a 'local' report"
fi

# A document that is not a report at all.
echo '{"schema": "something-else"}' >"$TMP/junk.json"
if sh "$INGEST" --dry-run --baseline "$TMP/none.json" "$TMP/junk.json" >"$TMP/junk.out" 2>&1; then
  bad "ingest accepted a document that is not a gate-cost/1 report"
else
  grep -q "is not a 'gate-cost/1' report" "$TMP/junk.out" \
    && ok "ingest refuses a non-report document" \
    || bad "ingest refused a non-report, but not for that reason"
fi

# A locally-fabricated report hand-tagged with a LEGITIMATE event string but
# empty runId/runAttempt/sha/ref (nothing outside Actions sets those) must
# still be refused — the event allowlist alone does not stop this artifact.
sed -e 's/"runId": "4242"/"runId": ""/' -e 's/"runAttempt": "1"/"runAttempt": ""/' \
    -e 's/"sha": "cafebabe"/"sha": ""/' -e 's/"ref": "refs\/heads\/testing-arc"/"ref": ""/' \
    "$TMP/wd.json" >"$TMP/emptyprov.json"
if sh "$INGEST" --dry-run --baseline "$TMP/none.json" "$TMP/emptyprov.json" >"$TMP/emptyprov.out" 2>&1; then
  bad "ingest ACCEPTED a 'workflow_dispatch'-tagged report with empty provenance"
  cat "$TMP/emptyprov.out"
else
  if grep -q 'missing provenance field' "$TMP/emptyprov.out" \
     && grep -q 'runId' "$TMP/emptyprov.out" && grep -q 'runAttempt' "$TMP/emptyprov.out" \
     && grep -q 'sha' "$TMP/emptyprov.out" && grep -q 'ref' "$TMP/emptyprov.out"; then
    ok "ingest refuses a legitimate-event report with empty runId/runAttempt/sha/ref, naming them"
  else
    bad "ingest exited nonzero but did not name the missing provenance fields"
    cat "$TMP/emptyprov.out"
  fi
fi

# ── 4. the arithmetic: LOWER median over retained raw samples ─────────────────
_synth() { # $1 = out, $2 = runId, $3.. = "name:ms" pairs
  _o="$1"; _r="$2"; shift 2
  {
    echo '{'
    echo '  "schema": "gate-cost/1",'
    echo '  "jobs": 2,'
    echo '  "parallel": true,'
    echo '  "rowElapsedMs": 999,'
    echo '  "ok": 1,'
    echo '  "failing": 0,'
    echo '  "provenance": {'
    echo '    "event": "merge_group",'
    echo '    "shard": "synth",'
    printf '    "runId": "%s",\n' "$_r"
    echo '    "runAttempt": "1",'
    echo '    "repo": "MedakaLang/medaka",'
    echo '    "ref": "refs/heads/main",'
    echo '    "sha": "0000000",'
    echo '    "date": "2026-01-01T00:00:00Z"'
    echo '  },'
    echo '  "gates": ['
    _s=''
    for p in "$@"; do
      printf '%s    {"name": "%s", "script": "test/%s.sh", "shell": "sh", "exit": 0, "timedOut": false, "ms": %s, "seconds": 0.0, "ok": %s, "spawnError": ""}' \
        "$_s" "${p%%:*}" "${p%%:*}" "$(echo "$p" | cut -d: -f2)" "$(echo "$p" | cut -d: -f3)"
      _s=',
'
    done
    printf '\n  ]\n}\n'
  } >"$_o"
}

B="$TMP/base.json"
rm -f "$B"
# five samples of gate A: 100 700 200 300 400 -> sorted 100 200 300 400 700 -> 300
_synth "$TMP/s1.json" 5001 "gate_a:100:true"
_synth "$TMP/s2.json" 5002 "gate_a:700:true"
_synth "$TMP/s3.json" 5003 "gate_a:200:true"
_synth "$TMP/s4.json" 5004 "gate_a:300:true"
_synth "$TMP/s5.json" 5005 "gate_a:400:true"
sh "$INGEST" --baseline "$B" "$TMP/s1.json" "$TMP/s2.json" "$TMP/s3.json" \
                             "$TMP/s4.json" "$TMP/s5.json" >/dev/null 2>&1 \
  || bad "ingest failed on five admissible reports"
_med="$(sed -n 's/^    {"name": "gate_a", "medianMs": \([0-9]*\),.*$/\1/p' "$B")"
[ "$_med" = "300" ] && ok "odd-count median is the middle sample (300 of 100/200/300/400/700)" \
                    || bad "odd-count median was '$_med', expected 300"
_smp="$(sed -n 's/^    {"name": "gate_a".*"samples": \([0-9]*\),.*$/\1/p' "$B")"
[ "$_smp" = "5" ] && ok "all five samples retained raw in the file" \
                  || bad "samples was '$_smp', expected 5"

# ── each sample carries ITS OWN run (FR-1, #2222 review S0-1) ────────────────
#
# The five reports above were ingested in runId order 5001..5005 and each
# contributed one sample, so `sampleRuns` must read back in exactly that
# order beside `ms`. This is what retires the positional inference the review
# found: the reader no longer has to deduce which run a sample came from from
# how many samples there happen to be, and a `sampleRuns` that drifted out of
# step with `ms` would put that bug back one layer down.
_srun="$(sed -n 's/^    {"name": "gate_a".*"sampleRuns": \[\([^]]*\)\].*$/\1/p' "$B")"
if [ "$_srun" = '"5001", "5002", "5003", "5004", "5005"' ]; then
  ok "each retained sample records the run it came from, in ms order"
else
  bad "sampleRuns was [$_srun], expected the five runIds 5001..5005 in order"
fi

# A baseline written BEFORE the field existed must carry forward UNATTRIBUTED,
# never backfilled. The provenance of those samples was not recorded and is
# not recoverable from the file, so inventing one — even a plausible one, even
# by position — is the defect rather than the repair. New samples ingested on
# top of it still carry their real runId, so the two are distinguishable in
# the same array.
BL="$TMP/legacy.json"
cat >"$BL" <<'LEGACY_EOF'
{
  "schema": "gate-cost-baseline/1",
  "note": "pre-FR-1 shape: ms with no sampleRuns",
  "generated": "2026-01-01T00:00:00Z",
  "maxSamples": 9,
  "runs": [
  ],
  "gates": [
    {"name": "gate_a", "medianMs": 100, "samples": 2, "ms": [100, 110]}
  ]
}
LEGACY_EOF
sh "$INGEST" --baseline "$BL" "$TMP/s1.json" >/dev/null 2>&1 \
  || bad "ingest failed folding a report into a pre-FR-1 baseline"
_lsr="$(sed -n 's/^    {"name": "gate_a".*"sampleRuns": \[\([^]]*\)\].*$/\1/p' "$BL")"
if [ "$_lsr" = '"", "", "5001"' ]; then
  ok "legacy samples carry forward unattributed; only the new sample names its run"
else
  bad "legacy carry-forward produced sampleRuns [$_lsr], expected [\"\", \"\", \"5001\"]"
fi

# jobs/parallel/rowElapsedMs (#2208) round-trip into the runs[] entry for the
# run they came from, recorded per-run (not merged/averaged across runs).
_run5001="$(grep '"runId": "5001"' "$B")"
case "$_run5001" in
  *'"jobs": 2'*'"parallel": true'*'"rowElapsedMs": 999'*)
    ok "runs[] entry carries jobs/parallel/rowElapsedMs from its own report" ;;
  *)
    bad "runs[] entry for runId 5001 is missing jobs/parallel/rowElapsedMs: $_run5001" ;;
esac

# even count -> LOWER median. 100 200 300 400 -> 200
B2="$TMP/base2.json"
sh "$INGEST" --baseline "$B2" "$TMP/s1.json" "$TMP/s3.json" "$TMP/s4.json" "$TMP/s5.json" \
  >/dev/null 2>&1 || bad "ingest failed on four admissible reports"
_med2="$(sed -n 's/^    {"name": "gate_a", "medianMs": \([0-9]*\),.*$/\1/p' "$B2")"
[ "$_med2" = "200" ] && ok "even-count median is the LOWER middle (200 of 100/200/300/400)" \
                     || bad "even-count median was '$_med2', expected 200"

# re-ingesting the same run is a no-op, not a second sample.
cp "$B" "$TMP/before.json"
sh "$INGEST" --baseline "$B" "$TMP/s1.json" >/dev/null 2>&1 \
  || bad "ingest failed re-ingesting an already-recorded run"
_smp2="$(sed -n 's/^    {"name": "gate_a".*"samples": \([0-9]*\),.*$/\1/p' "$B")"
[ "$_smp2" = "5" ] && ok "re-ingesting a recorded run adds no sample (idempotent)" \
                   || bad "re-ingest changed samples from 5 to '$_smp2'"

# a FAILING gate contributes no sample, but its run is still recorded.
B3="$TMP/base3.json"
_synth "$TMP/red.json" 6001 "gate_red:900:false" "gate_green:50:true"
sh "$INGEST" --baseline "$B3" "$TMP/red.json" >/dev/null 2>&1 \
  || bad "ingest failed on a report containing a failing gate"
if grep -q '"name": "gate_red"' "$B3"; then
  bad "a FAILING gate contributed a cost sample"
else
  ok "a failing gate contributes no sample"
fi
grep -q '"name": "gate_green"' "$B3" \
  && ok "the passing gate in the same report is still recorded" \
  || bad "the passing gate in a partly-red report was dropped"
grep -q '"runId": "6001"' "$B3" \
  && ok "the run itself is recorded even though one gate was red" \
  || bad "a partly-red run left no provenance entry"

# ── 5. the COMMITTED baseline agrees with its own samples ────────────────────
if [ ! -f "$BASELINE" ]; then
  bad "test/gate_cost_baseline.json is missing — the committed transport has no file"
else
  grep -q '^  "schema": "gate-cost-baseline/1",$' "$BASELINE" \
    && ok "committed baseline carries schema gate-cost-baseline/1" \
    || bad "committed baseline is missing its schema line"
  _bad="$(awk '
    /^    \{"name": / {
      match($0, /"name": "[^"]*"/);      nm = substr($0, RSTART + 9,  RLENGTH - 10)
      match($0, /"medianMs": [0-9]+/);   md = substr($0, RSTART + 12, RLENGTH - 12) + 0
      match($0, /"ms": \[[^]]*\]/);      ar = substr($0, RSTART + 7,  RLENGTH - 8)
      n = split(ar, v, /, */)
      for (i = 2; i <= n; i++) { x = v[i] + 0; j = i - 1
        while (j >= 1 && (v[j] + 0) > x) { v[j+1] = v[j]; j-- }
        v[j+1] = x }
      k = int((n + 1) / 2)
      if ((v[k] + 0) != md) print nm " medianMs=" md " but lower median of its samples is " (v[k] + 0)
    }' "$BASELINE")"
  if [ -n "$_bad" ]; then
    bad "committed baseline medians disagree with their own samples:"
    printf '%s\n' "$_bad"
  else
    ok "every committed medianMs is the lower median of its own retained samples"
  fi
fi

# ── 6. the gate-SET digest is a mirror pair, and it is order-independent ──────
#
# `_digest` here and `gate_cost.gateSetDigest` on the Medaka side are two
# implementations of one rule (S-2, #2223). A drift between them shows up in
# production as a permanent, unexplained [STALE] annotation on every
# calibration line — loud, but loud in the way that trains a reader to ignore
# the annotation. The constant below is the one
# test/gate_balance_fixtures/calib_staleness.json records for row `c`, and
# test/diff_compiler_gate_balance.sh asserts the Medaka side against that same
# fixture, so the two gates pin the two halves against one number.
_rep() { printf '%s\n' '{' '  "schema": "gate-cost/1",' '  "gates": [' "$@" '  ]' '}'; }
_rep '    {"name": "swapped_out", "ms": 10, "ok": true}' >"$TMP/dg1.json"
_d1="$(sh "$ROOT/test/gate_cost_ingest.sh" --digest "$TMP/dg1.json")"
if [ "$_d1" = "1926625894" ]; then
  ok "the ingester's gate-set digest matches the value calib_staleness pins"
else
  bad "gate-set digest drifted: got '$_d1', calib_staleness.json records 1926625894"
fi

# A sum, so the report's pattern-resolution order and the registry's enrolment
# order must produce the same digest — they are not the same order, and a
# digest that depended on it would fire STALE on every row forever.
_rep '    {"name": "alpha", "ms": 1, "ok": true}' \
     '    {"name": "beta", "ms": 1, "ok": true}' >"$TMP/dg2.json"
_rep '    {"name": "beta", "ms": 1, "ok": true}' \
     '    {"name": "alpha", "ms": 1, "ok": true}' >"$TMP/dg3.json"
_d2="$(sh "$ROOT/test/gate_cost_ingest.sh" --digest "$TMP/dg2.json")"
_d3="$(sh "$ROOT/test/gate_cost_ingest.sh" --digest "$TMP/dg3.json")"
if [ "$_d2" = "$_d3" ] && [ -n "$_d2" ]; then
  ok "the gate-set digest ignores the order gates are reported in"
else
  bad "the gate-set digest depends on report order ($_d2 vs $_d3)"
fi

# ...and it must still SEPARATE a same-size swap, which is the whole point.
_rep '    {"name": "alpha", "ms": 1, "ok": true}' \
     '    {"name": "gamma", "ms": 1, "ok": true}' >"$TMP/dg4.json"
_d4="$(sh "$ROOT/test/gate_cost_ingest.sh" --digest "$TMP/dg4.json")"
if [ "$_d2" != "$_d4" ]; then
  ok "the gate-set digest separates a same-size swap"
else
  bad "swapping one gate for another left the digest unchanged ($_d2)"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "gate cost transport: all checks pass"
  exit 0
fi
echo "gate cost transport: $fail check(s) FAILED"
exit 1
