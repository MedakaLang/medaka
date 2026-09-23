#!/bin/sh
# blocked-because: detached-process — two `pdsd` servers plus N generators and a sampler all run at once, each outliving its own spawn; concurrent-spawn is the second capability it needs
# The concurrency cost instrument for #2954: N client processes drive a real
# `pdsd` over loopback while one sampling process reports p50/p90/p99 per
# route. Slices that measure a structural stall (#2955, #2956) and the soak
# (#2957) read this, so the numbers have to be the SERVER's.
#
# NIGHTLY ONLY, and never on the PR or merge-queue path: a run is minutes of
# saturated loopback traffic on a shared box, and a box-load-sensitive latency
# figure is not something a merge should be gated on. Enrolled in
# `test/gates.toml` with `shard = "other-job"`, and named by literal path in
# `.github/workflows/nightly.yml`'s `pds-load-harness` job so
# `diff_compiler_ci_shard_coverage.sh` clause (a) still counts it as covered.
#
# NATIVE ONLY. The eval interpreter binds a canned `monotonicSec` by design,
# so every binary here is built with `medaka build` and nothing is ever run
# through the interpreter or joined to an `*_all_engines` family.
#
# HOW CLIENT DELAY IS EXCLUDED. `stdlib/async.mdk` is a single-threaded
# cooperative scheduler, so N client tasks in ONE process report their own
# queuing as the server's latency. Here every client is its own OS process
# running a synchronous loop with one request in flight
# (`pds/test/load_client_main.mdk`), the load generators are never measured,
# and exactly one sampler measures — so no percentile is aggregated across
# processes and no measured request ever waits on another client's.
#
# What remains — the box's own scheduler under the load the generators make —
# is measured rather than assumed: a SECOND, idle `pdsd` on its own copy of
# the same corpus is sampled in the same loop, microseconds after each loaded
# sample. Delay this client process suffers lands on both; delay only the
# loaded target shows is that server's own queuing.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
MEDAKA=${MEDAKA:-"$ROOT/medaka"}
SERVE_SRC="$ROOT/pds/serve.mdk"
SYNTH_SRC="$ROOT/pds/test/synth_repo_main.mdk"
CLIENT_SRC="$ROOT/pds/test/load_client_main.mdk"
SUBSCRIBE_SRC="$ROOT/pds/test/serve_subscribe_main.mdk"

# Knobs, so a soak can ask for the same instrument over a longer window
# without editing it. The defaults are sized for a nightly job: minutes, not
# hours.
RECORDS=${LOAD_RECORDS:-5000}
BLOBS=${LOAD_BLOBS:-200}
CLIENTS=${LOAD_CLIENTS:-8}
WRITE_CLIENTS=${LOAD_WRITE_CLIENTS:-1}
SUBSCRIBER=${LOAD_SUBSCRIBER:-1}
# The generators run well past the sampler on purpose; the overlap check
# below is what enforces that they actually did, and names this knob when
# they did not. A tick costs the interval plus the requests it makes, so the
# sampler's own wall time is always longer than ticks x interval.
DURATION_MS=${LOAD_DURATION_MS:-120000}
# 600 ticks over a four-route scenario is 150 samples per route, so a p99 is
# read off a rank rather than off the single slowest request.
TICKS=${LOAD_TICKS:-600}
INTERVAL_MS=${LOAD_INTERVAL_MS:-100}
# How long the generators run before the sampler's first tick. Also the margin
# the overlap check below requires between the two wall times.
WARMUP_SECONDS=${LOAD_WARMUP_SECONDS:-2}
RESOURCE_SAMPLE_SECONDS=${LOAD_RESOURCE_SAMPLE_SECONDS:-60}
FULL_SOAK=${LOAD_FULL_SOAK:-0}
MAX_RSS_GROWTH_PCT=${LOAD_MAX_RSS_GROWTH_PCT:-}
MAX_DISK_GROWTH_KIB=${LOAD_MAX_DISK_GROWTH_KIB:-}
# The scenario vocabulary lives in `pds/test/load_client_main.mdk`: a scenario
# names a cycle of route labels, and each label has one path builder there.
# `read-load` is the default load; `repo-export` (#2955) and `blob-burst`
# (#2956) are the two structural hazards, each driven by setting
# LOAD_LOAD_SCENARIO while the sampler stays on `read-mix` — so what a run
# reports is the delay the hazard imposes on unrelated reads.
SAMPLE_SCENARIO=${LOAD_SAMPLE_SCENARIO:-read-mix}
LOAD_SCENARIO=${LOAD_LOAD_SCENARIO:-read-load}

# The corpus shape and the collection holding the bulk of it. `one-collection`
# is the shape whose reads are least helped by collection-level narrowing, so
# it is the honest default for a read-cost figure.
SHAPE=one-collection
COLLECTION=bulk.synth.record

# The synthetic account `pds/test/synth_repo_main.mdk` signs its corpus for,
# and the key it signs with. A server configured with any other pair cannot
# load the corpus's head at all.
DID='did:plc:synthrepocorpus000000000'
HANDLE='alice.test'
HOSTNAME='pds.test'
SECRET_HEX='c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721'
TOKEN_SECRET_HEX='7f1c0a6d2b93e45880ac31f6d5e27b04913ca8e6f27d4b51a03c8e19d6b4720f'
PASSWORD='pds load harness password'

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-load-harness.XXXXXX")
SERVER_PIDS=""
LOAD_PIDS=""
SUBSCRIBER_PIDS=""
METRICS_PID=""

cleanup() {
  for pid in $LOAD_PIDS $SUBSCRIBER_PIDS $METRICS_PID $SERVER_PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  if [ "${KEEP_WORK:-0}" = 1 ]; then
    printf 'kept work directory: %s\n' "$WORK" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

if [ "$FULL_SOAK" = 1 ]; then
  [ -n "${LOAD_DURATION_MS:-}" ] || fail 'full-soak mode requires an explicit LOAD_DURATION_MS'
  [ -n "$MAX_RSS_GROWTH_PCT" ] || fail 'full-soak mode requires LOAD_MAX_RSS_GROWTH_PCT; no RSS bound is assumed'
  [ -n "$MAX_DISK_GROWTH_KIB" ] || fail 'full-soak mode requires LOAD_MAX_DISK_GROWTH_KIB; no disk bound is assumed'
fi
case "$MAX_RSS_GROWTH_PCT" in
  '') ;;
  *) awk -v n="$MAX_RSS_GROWTH_PCT" 'BEGIN { exit !(n ~ /^[0-9]+([.][0-9]+)?$/) }' \
       || fail 'LOAD_MAX_RSS_GROWTH_PCT must be a non-negative number' ;;
esac
case "$MAX_DISK_GROWTH_KIB" in
  '') ;;
  *[!0-9]*) fail 'LOAD_MAX_DISK_GROWTH_KIB must be a non-negative integer' ;;
esac
case "$RESOURCE_SAMPLE_SECONDS" in
  ''|*[!0-9]*) fail 'LOAD_RESOURCE_SAMPLE_SECONDS must be a positive integer' ;;
esac
[ "$RESOURCE_SAMPLE_SECONDS" -gt 0 ] || fail 'LOAD_RESOURCE_SAMPLE_SECONDS must be a positive integer'
[ "$SUBSCRIBER" = 1 ] || fail 'LOAD_SUBSCRIBER must be 1; a soak requires one live consumer'
[ "$WRITE_CLIENTS" -gt 0 ] || fail 'LOAD_WRITE_CLIENTS must be positive'

[ -x "$MEDAKA" ] || fail 'build medaka first'

# Seconds since the epoch, both platforms. Used only for coarse phase timing,
# so whole seconds are enough.
now_seconds() {
  date +%s
}

build_one() {
  src=$1
  out=$2
  if ! MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$MEDAKA" build "$src" -o "$out" \
    > "$out.build.log" 2>&1
  then
    cat "$out.build.log" >&2
    fail "native build of $src failed"
  fi
}

# ── build ───────────────────────────────────────────────────────────────────

export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
BUILD_START=$(now_seconds)
build_one "$SERVE_SRC" "$WORK/pdsd"
build_one "$SYNTH_SRC" "$WORK/synth"
build_one "$CLIENT_SRC" "$WORK/client"
build_one "$SUBSCRIBE_SRC" "$WORK/subscriber"
printf 'phase build seconds=%s\n' "$(($(now_seconds) - BUILD_START))"

# ── corpus ──────────────────────────────────────────────────────────────────

# One corpus, built once and copied: the loaded server and the idle control
# server must be reading identical repositories, or their latencies are not
# comparable and the control proves nothing.
CORPUS_START=$(now_seconds)
mkdir -p "$WORK/corpus"
"$WORK/synth" build "$SHAPE" "$WORK/corpus" "$RECORDS" "$BLOBS" 1 \
  > "$WORK/corpus.out" 2>&1 || {
  cat "$WORK/corpus.out" >&2
  fail 'corpus build failed'
}
cat "$WORK/corpus.out"
cp -R "$WORK/corpus" "$WORK/data-loaded"
cp -R "$WORK/corpus" "$WORK/data-control"
printf 'phase corpus seconds=%s\n' "$(($(now_seconds) - CORPUS_START))"

printf '%s\n' "$SECRET_HEX" > "$WORK/key.hex"
printf '%s\n' "$TOKEN_SECRET_HEX" > "$WORK/token.hex"
printf '%s\n' "$PASSWORD" > "$WORK/password"
# The server refuses a group- or world-readable signing key, session-token
# secret or password file before it binds.
chmod 600 "$WORK/key.hex" "$WORK/token.hex" "$WORK/password"

# ── the two servers ─────────────────────────────────────────────────────────

# `--trusted-proxy` is not a test convenience: without it every client here
# shares one rate-limit identity and is refused within seconds
# (`maxRequestsPerWindow`), and a 429 is answered without touching the
# repository — a rate-limited run measures the limiter instead of the read
# path. It is also how this server is deployed (`pds/Caddyfile`).
#
# `--password-file` and no `--init`: the data directory already holds the
# repository the corpus builder wrote, and it holds no credential yet.
start_server() {
  tag=$1
  datadir=$2
  "$WORK/pdsd" \
    --did "$DID" --handle "$HANDLE" --hostname "$HOSTNAME" \
    --key "$WORK/key.hex" --token-secret "$WORK/token.hex" \
    --password-file "$WORK/password" \
    --data "$datadir" --port 0 --trusted-proxy \
    > "$WORK/$tag.out" 2> "$WORK/$tag.err" &
  echo $! > "$WORK/$tag.pid"
  SERVER_PIDS="$SERVER_PIDS $!"
}

# Prints the port a started server bound, once it reports readiness. The
# ceiling is generous because startup verifies the whole corpus's signed head
# before it binds, and that is the one part of this run whose cost grows with
# LOAD_RECORDS.
wait_for_port() {
  tag=$1
  i=0
  while [ "$i" -lt 3000 ]; do
    if grep -F 'serve: listening on 127.0.0.1:' "$WORK/$tag.out" >/dev/null 2>&1
    then
      sed -n 's/.*listening on 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$WORK/$tag.out" \
        | head -1
      return 0
    fi
    kill -0 "$(cat "$WORK/$tag.pid")" 2>/dev/null || return 1
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

require_empty() {
  [ ! -s "$1" ] || {
    cat "$1" >&2
    fail "$2 emitted stderr"
  }
}

# The primary loaded process, not the generator or subscriber, is the memory
# signal. `ps` and `du -sk` are available in both supported host environments.
LOADED_PID=""
RESOURCE_LOG="$WORK/resources.out"
record_resource_sample() {
  state=$(ps -o stat= -p "$LOADED_PID" 2>/dev/null | tr -d ' ')
  case "$state" in
    ''|*Z*) fail "loaded server PID $LOADED_PID exited during the soak" ;;
  esac
  rss=$(ps -o rss= -p "$LOADED_PID" 2>/dev/null | tr -d ' ')
  case "$rss" in
    ''|*[!0-9]*) fail "could not sample RSS for loaded server PID $LOADED_PID" ;;
  esac
  disk=$(du -sk "$WORK/data-loaded" | awk '{print $1}')
  case "$disk" in
    ''|*[!0-9]*) fail 'could not sample loaded data-directory size' ;;
  esac
  printf 'soak-sample timestamp=%s server_pid=%s rss_kib=%s data_kib=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOADED_PID" "$rss" "$disk" \
    >> "$RESOURCE_LOG"
}

monitor_resources() {
  while [ ! -f "$WORK/metrics.stop" ]; do
    sleep "$RESOURCE_SAMPLE_SECONDS"
    [ ! -f "$WORK/metrics.stop" ] || break
    record_resource_sample
  done
  record_resource_sample
}

check_resource_evidence() {
  samples=$(grep -c '^soak-sample ' "$RESOURCE_LOG" || true)
  [ "$samples" -ge 2 ] || fail "expected initial and final server resource samples, got $samples"
  set -- $(awk '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        split($i, pair, "=")
        if (pair[1] == "rss_kib") first_rss = pair[2]
        if (pair[1] == "data_kib") first_disk = pair[2]
      }
    }
    {
      for (i = 1; i <= NF; i++) {
        split($i, pair, "=")
        if (pair[1] == "rss_kib") last_rss = pair[2]
        if (pair[1] == "data_kib") last_disk = pair[2]
      }
    }
    END { print first_rss, first_disk, last_rss, last_disk }
  ' "$RESOURCE_LOG")
  rss_start=$1
  disk_start=$2
  rss_end=$3
  disk_end=$4
  [ "$rss_start" -gt 0 ] || fail 'initial server RSS sample was zero'
  rss_delta=$((rss_end - rss_start))
  disk_delta=$((disk_end - disk_start))
  rss_pct=$(awk -v a="$rss_start" -v b="$rss_end" \
    'BEGIN { printf "%.3f", ((b - a) / a) * 100 }')
  printf 'soak-delta server_pid=%s rss_initial_kib=%s rss_final_kib=%s rss_delta_kib=%s rss_growth_pct=%s data_initial_kib=%s data_final_kib=%s data_delta_kib=%s samples=%s\n' \
    "$LOADED_PID" "$rss_start" "$rss_end" "$rss_delta" "$rss_pct" \
    "$disk_start" "$disk_end" "$disk_delta" "$samples"
  awk -v pid="$LOADED_PID" '
    { found = 0; for (i = 1; i <= NF; i++) { split($i, pair, "="); if (pair[1] == "server_pid") { found = 1; if (pair[2] != pid) exit 1 } } if (!found) exit 1 }
  ' "$RESOURCE_LOG" || fail 'loaded server PID changed or was absent in resource samples'
  printf 'server-continuity pid=%s samples=%s PASS\n' "$LOADED_PID" "$samples"
  if [ -n "$MAX_RSS_GROWTH_PCT" ]; then
    awk -v actual="$rss_pct" -v limit="$MAX_RSS_GROWTH_PCT" \
      'BEGIN { exit !(actual <= limit) }' \
      || fail "RSS growth $rss_pct% exceeded configured limit ${MAX_RSS_GROWTH_PCT}%"
    printf 'rss-bound limit_pct=%s PASS\n' "$MAX_RSS_GROWTH_PCT"
  else
    printf 'rss-bound not-configured (shakeout only; no limit inferred)\n'
  fi
  if [ -n "$MAX_DISK_GROWTH_KIB" ]; then
    [ "$disk_delta" -le "$MAX_DISK_GROWTH_KIB" ] \
      || fail "data growth ${disk_delta}KiB exceeded configured limit ${MAX_DISK_GROWTH_KIB}KiB"
    printf 'disk-bound limit_kib=%s PASS\n' "$MAX_DISK_GROWTH_KIB"
  else
    printf 'disk-bound not-configured (shakeout only; no limit inferred)\n'
  fi
  cat "$RESOURCE_LOG"
}

SERVER_START=$(now_seconds)
start_server loaded "$WORK/data-loaded"
start_server control "$WORK/data-control"
LOADED_PORT=$(wait_for_port loaded) || {
  cat "$WORK/loaded.err" >&2
  fail 'loaded server did not report readiness'
}
CONTROL_PORT=$(wait_for_port control) || {
  cat "$WORK/control.err" >&2
  fail 'control server did not report readiness'
}
require_empty "$WORK/loaded.err" 'loaded server startup'
require_empty "$WORK/control.err" 'control server startup'
printf 'phase servers seconds=%s loaded_port=%s control_port=%s\n' \
  "$(($(now_seconds) - SERVER_START))" "$LOADED_PORT" "$CONTROL_PORT"

# ── grading ─────────────────────────────────────────────────────────────────

# A sampler run is only a measurement if every request it timed was answered
# 200. A refused or dropped request is excluded from the percentiles by the
# client, so a run that tolerated them would report a confident number over
# whatever happened to get through.
grade_samples() {
  file=$1
  phase=$2
  lines=$(grep -c '^sample ' "$file" || true)
  [ "$lines" -ge 1 ] || {
    cat "$file" >&2
    fail "$phase: sampler emitted no per-route lines"
  }
  bad=$(grep -c '^sample .*errors=[1-9]' "$file" || true)
  [ "$bad" = 0 ] || {
    cat "$file" >&2
    fail "$phase: $bad route(s) reported unanswered or non-200 requests"
  }
  empty=$(grep -c '^sample .*n=0 ' "$file" || true)
  [ "$empty" = 0 ] || {
    cat "$file" >&2
    fail "$phase: $empty route(s) recorded no samples at all"
  }
}

# Two independent server processes under real OS scheduling do not report
# identical p50s even both idle — two 25-sample-per-route idle probe runs on
# this box showed differences up to ~0.42ms absolute and ~30% relative on the
# sub-millisecond routes (the cheap routes are where a fixed-ms tolerance
# alone would be too tight, and a percent-only one would be too tight on a
# near-zero base). The tolerance here is whichever of an absolute floor or a
# relative margin is looser, set with headroom above that observed spread for
# a noisier CI runner. It is a knob, not a magic number, so a route whose true
# idle noise is wider can be widened without touching the check's logic.
IDLE_ABS_TOL_MS=${LOAD_IDLE_ABS_TOL_MS:-0.75}
IDLE_PCT_TOL=${LOAD_IDLE_PCT_TOL:-0.50}

# For each route present in both the loaded and control lines, the two p50s
# must agree within tolerance — otherwise the control is not proving what the
# comment above it claims: that phase 2's loaded-vs-control gap is the load,
# not the two servers already answering differently at rest.
check_idle_agreement() {
  file=$1
  awk -v abs_tol="$IDLE_ABS_TOL_MS" -v pct_tol="$IDLE_PCT_TOL" '
    /^sample target=loaded / {
      route = $0; sub(/.*route=/, "", route); sub(/ .*/, "", route)
      p50 = $0; sub(/.*p50_ms=/, "", p50); sub(/ .*/, "", p50)
      loaded[route] = p50
    }
    /^sample target=control / {
      route = $0; sub(/.*route=/, "", route); sub(/ .*/, "", route)
      p50 = $0; sub(/.*p50_ms=/, "", p50); sub(/ .*/, "", p50)
      control[route] = p50
    }
    END {
      bad = 0
      for (r in loaded) {
        if (!(r in control)) continue
        l = loaded[r] + 0
        c = control[r] + 0
        diff = l - c
        if (diff < 0) diff = -diff
        floor = l < c ? l : c
        allowed = abs_tol
        pct_allowed = floor * pct_tol
        if (pct_allowed > allowed) allowed = pct_allowed
        printf "idle-agreement route=%s loaded_p50_ms=%s control_p50_ms=%s diff_ms=%.3f allowed_ms=%.3f\n", \
          r, loaded[r], control[r], diff, allowed
        if (diff > allowed) bad = 1
      }
      exit bad
    }
  ' "$file"
}

# ── phase 1: baseline, both servers idle ────────────────────────────────────

# Both targets idle here, so the two lines for one route must agree. That is
# what makes the control a control: if the two servers did not already answer
# alike, phase 2's difference could be the servers rather than the load.
# `check_idle_agreement` below is what enforces that, not just this comment.
BASELINE_START=$(now_seconds)
"$WORK/client" sample "$LOADED_PORT" "$CONTROL_PORT" "$SAMPLE_SCENARIO" \
  "$COLLECTION" "$RECORDS" "$BLOBS" "$TICKS" "$INTERVAL_MS" \
  > "$WORK/baseline.out" 2>&1 \
  || {
    cat "$WORK/baseline.out" >&2
    fail 'baseline sampler failed'
  }
grade_samples "$WORK/baseline.out" 'baseline'
check_idle_agreement "$WORK/baseline.out" || {
  cat "$WORK/baseline.out" >&2
  fail 'baseline: loaded and control p50s did not agree within tolerance while both idle'
}
sed 's/^/baseline /' "$WORK/baseline.out"
printf 'phase baseline seconds=%s\n' "$(($(now_seconds) - BASELINE_START))"

# ── phase 2: mixed synthetic reads, writes and a live relay consumer ─────────

LOAD_START=$(now_seconds)
LOADED_PID=$(cat "$WORK/loaded.pid")
SUBSCRIBER_DURATION_MS=$((DURATION_MS + WARMUP_SECONDS * 1000 + 5000))
"$WORK/subscriber" soak "$LOADED_PORT" "$SUBSCRIBER_DURATION_MS" \
  > "$WORK/subscriber.out" 2>&1 &
SUBSCRIBER_PID=$!
SUBSCRIBER_PIDS="$SUBSCRIBER_PID"
i=0
while [ "$i" -lt 3000 ]; do
  if grep -F 'subscriber ready' "$WORK/subscriber.out" >/dev/null 2>&1; then
    break
  fi
  kill -0 "$SUBSCRIBER_PID" 2>/dev/null || {
    cat "$WORK/subscriber.out" >&2
    fail 'synthetic relay subscriber exited before readiness'
  }
  i=$((i + 1))
  sleep 0.1
done
[ "$i" -lt 3000 ] || fail 'synthetic relay subscriber did not become ready'

# Initial resource values are taken before any load write. The metrics worker
# samples the same pdsd PID and data directory through the complete workload.
record_resource_sample
monitor_resources &
METRICS_PID=$!

LOAD_PIDS=""
i=1
while [ "$i" -le "$CLIENTS" ]; do
  "$WORK/client" load "$LOADED_PORT" "$LOAD_SCENARIO" "$COLLECTION" \
    "$RECORDS" "$BLOBS" "$i" "$DURATION_MS" > "$WORK/load$i.out" 2>&1 &
  LOAD_PIDS="$LOAD_PIDS $!"
  i=$((i + 1))
done
i=1
while [ "$i" -le "$WRITE_CLIENTS" ]; do
  writer_id=$((128 + i))
  "$WORK/client" write "$LOADED_PORT" "$COLLECTION" "$writer_id" \
    "$DURATION_MS" "$DID" "$WORK/password" > "$WORK/write$i.out" 2>&1 &
  LOAD_PIDS="$LOAD_PIDS $!"
  i=$((i + 1))
done
# Give every generator time to establish its connection before sampling. The
# relay subscription is already open, so each accepted write has a consumer.
sleep "$WARMUP_SECONDS"

"$WORK/client" sample "$LOADED_PORT" "$CONTROL_PORT" "$SAMPLE_SCENARIO" \
  "$COLLECTION" "$RECORDS" "$BLOBS" "$TICKS" "$INTERVAL_MS" \
  > "$WORK/loaded.sample" 2>&1 \
  || {
    cat "$WORK/loaded.sample" >&2
    fail 'under-load sampler failed'
  }

# Wait rather than kill: a generator cut off mid-request is not evidence of a
# clean write or read. Each process reports its own successful workload count.
for pid in $LOAD_PIDS; do
  wait "$pid" || fail "load generator/writer $pid exited non-zero"
done
LOAD_PIDS=""
wait "$SUBSCRIBER_PID" || {
  cat "$WORK/subscriber.out" >&2
  fail 'synthetic relay subscriber failed'
}
SUBSCRIBER_PIDS=""

grade_samples "$WORK/loaded.sample" 'under load'

# The whole-seconds part of a `seconds=` field, for the overlap check below.
# Whole seconds are enough: the margin being checked is seconds wide.
seconds_of() {
  sed -n 's/.*[ ]seconds=\([0-9]*\).*/\1/p' "$1" | head -1
}
field_of() {
  sed -n "s/.* $1=\([0-9][0-9]*\).*/\1/p" "$2" | head -1
}

SAMPLER_SECONDS=$(seconds_of "$WORK/loaded.sample")
[ -n "$SAMPLER_SECONDS" ] || fail 'under-load sampler reported no wall time'
READ_REQUESTS=0
i=1
while [ "$i" -le "$CLIENTS" ]; do
  grep -q ' non200=0 errors=0 ' "$WORK/load$i.out" || {
    cat "$WORK/load$i.out" >&2
    fail "read generator $i was refused or errored"
  }
  requests=$(field_of requests "$WORK/load$i.out")
  [ -n "$requests" ] && [ "$requests" -gt 0 ] || {
    cat "$WORK/load$i.out" >&2
    fail "read generator $i issued no requests"
  }
  READ_REQUESTS=$((READ_REQUESTS + requests))
  gen_seconds=$(seconds_of "$WORK/load$i.out")
  [ -n "$gen_seconds" ] || fail "read generator $i reported no wall time"
  [ "$((WARMUP_SECONDS + SAMPLER_SECONDS))" -le "$gen_seconds" ] || {
    cat "$WORK/load$i.out" >&2
    fail "read generator $i stopped before the sampler finished — raise LOAD_DURATION_MS"
  }
  cat "$WORK/load$i.out"
  i=$((i + 1))
done
WRITE_COUNT=0
WRITE_REQUESTS=0
i=1
while [ "$i" -le "$WRITE_CLIENTS" ]; do
  grep -q ' non200=0 errors=0 ' "$WORK/write$i.out" || {
    cat "$WORK/write$i.out" >&2
    fail "write generator $i was refused or errored"
  }
  writes=$(field_of writes "$WORK/write$i.out")
  requests=$(field_of requests "$WORK/write$i.out")
  [ -n "$writes" ] && [ "$writes" -gt 0 ] || {
    cat "$WORK/write$i.out" >&2
    fail "write generator $i committed no records"
  }
  [ -n "$requests" ] || fail "write generator $i reported no request count"
  WRITE_COUNT=$((WRITE_COUNT + writes))
  WRITE_REQUESTS=$((WRITE_REQUESTS + requests))
  cat "$WORK/write$i.out"
  i=$((i + 1))
done
sed 's/^/underload /' "$WORK/loaded.sample"
cat "$WORK/subscriber.out"
EVENT_COUNT=$(field_of events "$WORK/subscriber.out")
RELAY_COMMITS=$(field_of commits "$WORK/subscriber.out")
[ -n "$EVENT_COUNT" ] && [ "$EVENT_COUNT" -gt 0 ] \
  || fail 'synthetic subscriber received no relay events'
[ -n "$RELAY_COMMITS" ] && [ "$RELAY_COMMITS" -ge "$WRITE_COUNT" ] \
  || fail "relay delivered ${RELAY_COMMITS:-missing} commits, fewer than $WRITE_COUNT committed writes"
printf 'phase load seconds=%s\n' "$(($(now_seconds) - LOAD_START))"

: > "$WORK/metrics.stop"
wait "$METRICS_PID" || fail 'server resource monitor detected process loss or could not sample'
METRICS_PID=""
check_resource_evidence
require_empty "$WORK/loaded.err" 'loaded server'
require_empty "$WORK/control.err" 'control server'

REQUEST_ERRORS=0
printf 'mixed-workload reads=%s read_requests=%s committed_writes=%s relay_events=%s relay_commits=%s request_errors=%s server_pid=%s\n' \
  "$CLIENTS" "$READ_REQUESTS" "$WRITE_COUNT" "$EVENT_COUNT" "$RELAY_COMMITS" \
  "$REQUEST_ERRORS" "$LOADED_PID"
printf 'PASS: concurrent reads, authenticated writes and a live synthetic relay consumer; server stayed in one PID\n'
