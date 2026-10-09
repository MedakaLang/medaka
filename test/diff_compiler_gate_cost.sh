#!/bin/sh
# shell-because: trust-anchor — circular: checks the machinery a native gate would run inside
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
cp "$ROOT/test/gate_native_rows.sh" "$TMP/tree/test/gate_native_rows.sh"
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
  grep -q "is not a 'gate-cost/1' or 'oracle-cost/1' report" "$TMP/junk.out" \
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

# ── 7. the ingest reader fails closed on a layout it cannot read ──────────────
# A pretty-printed baseline matches none of the reader's one-row-per-line
# patterns; without the row-count check the rows vanish and the loss is written.
PP="$TMP/pretty.json"
cat >"$PP" <<'PRETTY_EOF'
{
  "schema": "gate-cost-baseline/1",
  "generated": "2026-01-01T00:00:00Z",
  "maxSamples": 9,
  "runs": [
    {
      "key": "1:1:x", "runId": "1", "runAttempt": "1", "shard": "x", "event": "push",
      "sha": "a", "ref": "r", "date": "d", "jobs": null, "parallel": null,
      "rowElapsedMs": null, "gates": 1, "gatesDigest": null
    }
  ],
  "gates": [
    {
      "name": "gate_a", "medianMs": 100, "samples": 1, "ms": [100], "sampleRuns": ["1"]
    }
  ]
}
PRETTY_EOF
cp "$PP" "$TMP/pretty.orig"
if sh "$INGEST" --baseline "$PP" "$TMP/s1.json" >"$TMP/pretty.out" 2>&1; then
  bad "ingest accepted a pretty-printed baseline and would have dropped its rows"
  cat "$TMP/pretty.out"
else
  if cmp -s "$PP" "$TMP/pretty.orig" && grep -q 'REFUSED' "$TMP/pretty.out"; then
    ok "ingest refuses a pretty-printed baseline and leaves it byte-identical"
  else
    bad "ingest exited nonzero on a pretty-printed baseline but modified it or did not say REFUSED"
    cat "$TMP/pretty.out"
  fi
fi

# ── 7b. oracle build cost is recorded data (#2209) ────────────────────────────
# Producer: test/build_oracles.sh appends one sample per COLD build to
# ORACLE_TIMING_LOG and wraps the log into an oracle-cost/1 report. A cache hit
# builds nothing, so its log is empty and NO report is written.
OL="$TMP/oracle-samples.tsv"
OREP="$TMP/oracle-report.json"
: >"$OL"
GITHUB_EVENT_NAME=merge_group GITHUB_RUN_ID=7001 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=beef GITHUB_REF=refs/heads/x \
  GATE_TIMING_SHARD=orow ORACLE_TIMING_LOG="$OL" \
  sh "$ROOT/test/build_oracles.sh" --write-timing-report "$OREP" >/dev/null 2>&1
if [ -e "$OREP" ]; then
  bad "a cache-hit build (empty sample log) still produced an oracle report"
else
  ok "a cache-hit build records no oracle sample (empty log writes no report)"
fi
ORACLE_TIMING_LOG="$OL" sh "$ROOT/test/build_oracles.sh" --record-sample oracle_a 41000 2
ORACLE_TIMING_LOG="$OL" sh "$ROOT/test/build_oracles.sh" --record-sample oracle_b 52000 2
env GITHUB_EVENT_NAME=pull_request GITHUB_RUN_ID=7001 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=beef GITHUB_REF=refs/heads/x \
  ORACLE_TIMING_LOG="$OL" sh "$ROOT/test/build_oracles.sh" --write-timing-report "$TMP/oracle-pr.json" >/dev/null 2>&1
[ -e "$TMP/oracle-pr.json" ] && bad "producer wrote an oracle report on a pull_request run" \
                             || ok "producer writes no oracle report on a pull_request run"
env GITHUB_EVENT_NAME=merge_group GITHUB_RUN_ID=7001 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=beef GITHUB_REF=refs/heads/x \
  GATE_TIMING_SHARD=orow ORACLE_TIMING_LOG="$OL" \
  sh "$ROOT/test/build_oracles.sh" --write-timing-report "$OREP" >/dev/null 2>&1
grep -q '^  "schema": "oracle-cost/1",$' "$OREP" && grep -q '{"name": "oracle_a", "ms": 41000, "jobs": 2}' "$OREP" \
  && ok "two cold builds are written as an oracle-cost/1 report with ms and JOBS" \
  || { bad "oracle report malformed"; cat "$OREP"; }

# Consumer: round-trip into oracles[], reader-accounted one-for-one.
OB="$TMP/obase.json"
rm -f "$OB"
sh "$INGEST" --baseline "$OB" "$TMP/s1.json" "$OREP" >"$TMP/o1.out" 2>&1 || { bad "ingest failed on a gate+oracle report pair"; cat "$TMP/o1.out"; }
if grep -q '^    {"name": "oracle_a", "medianMs": 41000, "samples": 1, "ms": \[41000\], "sampleRuns": \["7001"\], "jobs": \[2\]}' "$OB" \
   && grep -q '^    {"name": "oracle_b", "medianMs": 52000, ' "$OB" \
   && grep -q '^    {"name": "gate_a", ' "$OB"; then
  ok "oracle samples fold into oracles[] (median, samples, sampleRuns, jobs) beside gates[]"
else
  bad "oracles[] missing or wrong in the baseline"
  cat "$OB"
fi
cp "$OB" "$TMP/obase.once"
sh "$INGEST" --baseline "$OB" "$OREP" >/dev/null 2>&1
if [ "$(grep -c '^    {"name": "oracle_' "$OB")" = "2" ] && grep -q '"samples": 1, "ms": \[41000\]' "$OB"; then
  ok "re-ingesting an oracle report is idempotent, and a re-read baseline keeps its oracles[] rows"
else
  bad "re-ingest of an oracle report duplicated or lost samples"
  cat "$OB"
fi
# A second run adds a second sample to the same oracle.
sed -e 's/"runId": "7001"/"runId": "7002"/' -e 's/41000/45000/' "$OREP" >"$TMP/oracle-report2.json"
sh "$INGEST" --baseline "$OB" "$TMP/oracle-report2.json" >/dev/null 2>&1
grep -q '"name": "oracle_a", "medianMs": 41000, "samples": 2, "ms": \[41000, 45000\], "sampleRuns": \["7001", "7002"\], "jobs": \[2, 2\]' "$OB" \
  && ok "a second run's cold build is a second sample of the same oracle (lower median)" \
  || { bad "second oracle sample not folded"; cat "$OB"; }

# Malformed: a row with no ms, and a non-numeric ms. Refused, baseline untouched.
sed 's/"ms": 41000, //' "$OREP" >"$TMP/oracle-noms.json"
sed 's/"ms": 41000/"ms": "slow"/' "$OREP" >"$TMP/oracle-nan.json"
for _m in noms nan; do
  cp "$OB" "$TMP/obase.pre"
  if sh "$INGEST" --baseline "$OB" "$TMP/oracle-$_m.json" >"$TMP/om.out" 2>&1; then
    bad "ingest accepted a malformed oracle report ($_m)"
  elif cmp -s "$OB" "$TMP/obase.pre" && grep -q 'REFUSED' "$TMP/om.out"; then
    ok "malformed oracle report ($_m) refused with the baseline byte-identical"
  else
    bad "malformed oracle report ($_m) exited nonzero but changed the baseline or did not say REFUSED"
    cat "$TMP/om.out"
  fi
done

# Fail-closed accounting now covers oracles[]: a pretty-printed oracles row is refused.
awk '/^    \{"name": "oracle_a"/ { print "    {"; print "      \"name\": \"oracle_a\", \"medianMs\": 1, \"samples\": 1, \"ms\": [1]"; print "    },"; next } { print }' "$OB" >"$TMP/obase.pp"
cp "$TMP/obase.pp" "$TMP/obase.pp.orig"
if sh "$INGEST" --baseline "$TMP/obase.pp" "$OREP" >"$TMP/opp.out" 2>&1; then
  bad "ingest accepted a baseline whose oracles[] row it cannot read"
elif cmp -s "$TMP/obase.pp" "$TMP/obase.pp.orig" && grep -q 'REFUSED' "$TMP/opp.out"; then
  ok "ingest refuses a baseline whose oracles[] rows the line reader cannot account for"
else
  bad "unreadable oracles[] row: wrong refusal"; cat "$TMP/opp.out"
fi

# ── 8. the collector: prunes orphans, supersedes only its own stale PRs ───────
# A scratch copy of the tree with a local bare remote, a stubbed `gh` that logs
# every mutating call, and a stubbed `medaka`. Nothing real is closed or pushed.
CT="$TMP/ctree"
mkdir -p "$CT/test" "$CT/stubbin"
cp "$ROOT/test/gate_cost_collect.sh" "$ROOT/test/gate_cost_ingest.sh" "$CT/test/"
printf 'gen-ci:\n\t@true\n' >"$CT/Makefile"
printf '# registry stand-in\n' >"$CT/test/gates.toml"
mkdir -p "$CT/.github/workflows"
echo "name: ci" >"$CT/.github/workflows/ci.yml"
cat >"$CT/medaka" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "gate list") echo '[{"baselineKey": "gate_a"}]' ;;
  "gate balance") exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$CT/medaka"
cat >"$CT/test/gate_cost_baseline.json" <<'BASE_EOF'
{
  "schema": "gate-cost-baseline/1",
  "note": "n",
  "generated": "2026-01-01T00:00:00Z",
  "maxSamples": 9,
  "runs": [
  ],
  "gates": [
    {"name": "gate_a", "medianMs": 100, "samples": 1, "ms": [100], "sampleRuns": ["1"]},
    {"name": "gate_orphan", "medianMs": 50, "samples": 1, "ms": [50], "sampleRuns": ["1"]}
  ]
}
BASE_EOF
_synth "$TMP/c1.json" 7001 "gate_a:120:true" "gate_orphan:60:true"
cat >"$CT/stubbin/gh" <<'GHSTUB'
#!/bin/sh
# run list -> one successful push run; run download -> copy the synthetic report;
# pr list --head B -> PR numbers from $GH_PRS (lines "branch number"); pr close -> log.
case "$1 $2" in
  "run list") echo '[{"databaseId": 7001, "event": "push", "conclusion": "success", "headSha": "x"}]' ;;
  "repo view") echo "o/r" ;;
  "run download")
    shift 2; dir=""
    while [ $# -gt 0 ]; do case "$1" in --dir) dir="$2"; shift 2 ;; *) shift ;; esac; done
    cp "$GH_REPORT" "$dir/gate-timings-synth.json" ;;
  "pr list")
    head=""
    while [ $# -gt 0 ]; do case "$1" in --head) head="$2"; shift 2 ;; *) shift ;; esac; done
    awk -v h="$head" '$1 == h { print $2 }' "$GH_PRS" ;;
  "pr close") echo "close $3 :: $*" >>"$GH_LOG" ;;
  *) echo "unexpected gh $*" >>"$GH_LOG" ;;
esac
GHSTUB
chmod +x "$CT/stubbin/gh"
git init -q --bare "$TMP/remote.git"
git -C "$CT" init -q -b main
git -C "$CT" config user.email t@example.com
git -C "$CT" config user.name t
git -C "$CT" remote add origin "$TMP/remote.git"
git -C "$CT" add -A
git -C "$CT" commit -q -m base
git -C "$CT" push -q origin main
for old in cost-baseline-autoadvance-20200101000000 other-feature-branch; do
  git -C "$CT" push -q origin "main:refs/heads/$old"
done
printf 'cost-baseline-autoadvance-20200101000000 41\nother-feature-branch 42\n' >"$TMP/prs.txt"
: >"$TMP/gh.log"
_collect() {
  env PATH="$CT/stubbin:$PATH" GH_PRS="$TMP/prs.txt" GH_LOG="$TMP/gh.log" GH_REPORT="$TMP/c1.json" \
    sh "$CT/test/gate_cost_collect.sh" --base-branch main "$@"
}
_collect --dry-run >"$TMP/col_dry.out" 2>&1
if grep -q 'would close superseded PR #41' "$TMP/col_dry.out" && [ ! -s "$TMP/gh.log" ] \
   && git -C "$CT" ls-remote --heads origin | grep -q 'cost-baseline-autoadvance-20200101000000'; then
  ok "collector --dry-run says what it would close and closes/deletes nothing"
else
  bad "collector --dry-run closed something or did not say what it would close"
  cat "$TMP/col_dry.out" "$TMP/gh.log"
fi
cp "$CT/test/gate_cost_baseline.json" "$TMP/col_dry_baseline.json"
git -C "$CT" checkout -q -- test/gate_cost_baseline.json
_collect >"$TMP/col.out" 2>&1
if grep -q '"name": "gate_orphan"' "$CT/test/gate_cost_baseline.json" 2>/dev/null; then
  bad "collector left the orphan baseline row (no --registry on the ingest)"
  cat "$TMP/col.out"
else
  # after the run the collector sits on its new branch with the baseline committed
  if git -C "$CT" show HEAD:test/gate_cost_baseline.json | grep -q '"name": "gate_a"' \
     && ! git -C "$CT" show HEAD:test/gate_cost_baseline.json | grep -q 'gate_orphan'; then
    ok "collector path prunes the orphan baseline row and keeps the live one"
  else
    bad "collector pruned the live row or the commit does not hold the pruned baseline"
    cat "$TMP/col.out"
  fi
fi
_new="$(git -C "$CT" rev-parse --abbrev-ref HEAD)"
if grep -q '^close 41 ' "$TMP/gh.log" && grep -q "$_new" "$TMP/gh.log" \
   && ! grep -q '42' "$TMP/gh.log" && [ "$(grep -c '^close' "$TMP/gh.log")" = "1" ]; then
  ok "collector closes only its own cost-baseline-autoadvance-* PR, comment names the replacement"
else
  bad "collector close behaviour wrong (expected exactly: close 41, naming $_new)"
  cat "$TMP/gh.log"
fi
_heads="$(git -C "$CT" ls-remote --heads origin)"
if printf '%s\n' "$_heads" | grep -q 'other-feature-branch' \
   && ! printf '%s\n' "$_heads" | grep -q 'cost-baseline-autoadvance-20200101000000'; then
  ok "collector deleted the superseded branch and left the differently-named branch alone"
else
  bad "remote branches after the collector are wrong"
  printf '%s\n' "$_heads"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "gate cost transport: all checks pass"
  exit 0
fi
echo "gate cost transport: $fail check(s) FAILED"
exit 1
