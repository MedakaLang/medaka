#!/bin/sh
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

# Knobs, so a soak can ask for the same instrument over a longer window
# without editing it. The defaults are sized for a nightly job: minutes, not
# hours.
RECORDS=${LOAD_RECORDS:-5000}
BLOBS=${LOAD_BLOBS:-200}
CLIENTS=${LOAD_CLIENTS:-8}
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
# The scenario vocabulary lives in `pds/test/load_client_main.mdk`: a scenario
# names a cycle of route labels, and each label has one path builder there.
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

cleanup() {
  for pid in $LOAD_PIDS $SERVER_PIDS; do
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

# ── phase 1: baseline, both servers idle ────────────────────────────────────

# Both targets idle here, so the two lines for one route must agree. That is
# what makes the control a control: if the two servers did not already answer
# alike, phase 2's difference could be the servers rather than the load.
BASELINE_START=$(now_seconds)
"$WORK/client" sample "$LOADED_PORT" "$CONTROL_PORT" "$SAMPLE_SCENARIO" \
  "$COLLECTION" "$RECORDS" "$TICKS" "$INTERVAL_MS" > "$WORK/baseline.out" 2>&1 \
  || {
    cat "$WORK/baseline.out" >&2
    fail 'baseline sampler failed'
  }
grade_samples "$WORK/baseline.out" 'baseline'
sed 's/^/baseline /' "$WORK/baseline.out"
printf 'phase baseline seconds=%s\n' "$(($(now_seconds) - BASELINE_START))"

# ── phase 2: the loaded server under N concurrent clients ───────────────────

LOAD_START=$(now_seconds)
i=1
while [ "$i" -le "$CLIENTS" ]; do
  "$WORK/client" load "$LOADED_PORT" "$LOAD_SCENARIO" "$COLLECTION" \
    "$RECORDS" "$i" "$DURATION_MS" > "$WORK/load$i.out" 2>&1 &
  LOAD_PIDS="$LOAD_PIDS $!"
  i=$((i + 1))
done
# Let every generator connect and get its first requests in flight, so the
# sampler's first tick is already measuring a loaded server.
sleep "$WARMUP_SECONDS"

"$WORK/client" sample "$LOADED_PORT" "$CONTROL_PORT" "$SAMPLE_SCENARIO" \
  "$COLLECTION" "$RECORDS" "$TICKS" "$INTERVAL_MS" > "$WORK/loaded.sample" 2>&1 \
  || {
    cat "$WORK/loaded.sample" >&2
    fail 'under-load sampler failed'
  }

# Wait rather than kill: a generator killed mid-request leaves the server
# logging a reset, and its own summary — the evidence that it was not being
# refused — is printed on exit.
for pid in $LOAD_PIDS; do
  wait "$pid" || fail "load generator $pid exited non-zero"
done
LOAD_PIDS=""

grade_samples "$WORK/loaded.sample" 'under load'

# The whole-seconds part of a `seconds=` field, for the overlap check below.
# Whole seconds are enough: the margin being checked is seconds wide.
seconds_of() {
  sed -n 's/.*[ ]seconds=\([0-9]*\).*/\1/p' "$1" | head -1
}

SAMPLER_SECONDS=$(seconds_of "$WORK/loaded.sample")
[ -n "$SAMPLER_SECONDS" ] || fail 'under-load sampler reported no wall time'

i=1
while [ "$i" -le "$CLIENTS" ]; do
  grep -q ' non200=0 errors=0 ' "$WORK/load$i.out" || {
    cat "$WORK/load$i.out" >&2
    fail "load generator $i was refused or errored — its numbers are the limiter's, not the server's"
  }
  if grep -q ' requests=0 ' "$WORK/load$i.out"; then
    cat "$WORK/load$i.out" >&2
    fail "load generator $i issued no requests"
  fi
  # The load must outlast the measurement, or late ticks were measuring an
  # idle server and the percentiles are a blend of two different servers. The
  # sampler starts WARMUP_SECONDS after the generators do.
  gen_seconds=$(seconds_of "$WORK/load$i.out")
  [ -n "$gen_seconds" ] || fail "load generator $i reported no wall time"
  [ "$((WARMUP_SECONDS + SAMPLER_SECONDS))" -le "$gen_seconds" ] || {
    cat "$WORK/load$i.out" >&2
    fail "load generator $i stopped ${gen_seconds}s in, before the sampler's ${SAMPLER_SECONDS}s finished — raise LOAD_DURATION_MS"
  }
  cat "$WORK/load$i.out"
  i=$((i + 1))
done
sed 's/^/underload /' "$WORK/loaded.sample"
printf 'phase load seconds=%s\n' "$(($(now_seconds) - LOAD_START))"

require_empty "$WORK/loaded.err" 'loaded server'
require_empty "$WORK/control.err" 'control server'

printf 'PASS: %s concurrent clients, %s records, p50/p90/p99 above; the control target is an idle server sampled in the same loop\n' \
  "$CLIENTS" "$RECORDS"
