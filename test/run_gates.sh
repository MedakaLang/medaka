#!/bin/sh
# run_gates.sh — run the differential compiler gates concurrently.
#
# The ~72 test/diff_compiler_*.sh gates are independent (each streams the pre-built
# test/bin/<oracle> over goldens through pipes, or uses `mktemp -d` scratch — no
# shared fixed temp paths), so they parallelize cleanly. This runner fans them out
# across a job pool and prints a PASS/FAIL summary.
#
# Usage:
#   sh test/run_gates.sh                 # all diff_compiler_*.sh, JOBS=logical CPUs
#   sh test/run_gates.sh 'pattern*'      # only gates whose basename matches the glob
#   JOBS=4 sh test/run_gates.sh          # cap concurrency
#
# Exit: 0 if every selected gate passes, else 1. Per-gate exit 2 is reported as
#       SKIP only when the skip is a GENUINE opt-in toolchain-absence (no C
#       compiler / no libgc / no wasm-tools on PATH — see LEGIT_SKIP_RE below).
#       An exit-2 whose message says an oracle/binary was never built
#       (test/bin/* or ./medaka missing) means the gate executed ZERO tests —
#       that is infra rot, not an opt-in skip, and is reclassified as FAIL (see
#       the --run-one worker). Invariant: this script must never exit 0 having
#       executed no tests (either every gate skipped, or none ran at all).
#
#       Before any of that, each gate is syntax-checked with its own shebang's
#       `-n` flag (#1577): dash also exits 2 on a plain shell parse error, which
#       is otherwise indistinguishable from the "oracle not built" exit-2
#       convention above — and AGENTS.md tells readers to dismiss THAT verdict
#       as benign. A gate that fails its own syntax check is reported as a
#       distinct "SYNTAX ERROR"/BROKEN status (st=3), never folded into the
#       phantom-skip path.
#
# NOTE: gate REGISTRATION (which gates exist, their shard) now lives in
# test/gates.toml, the registry of record — read/verify/explain it with
# `medaka gate list`/`verify`/`explain`, and generate ci.yml's shard matrix
# from it with `make gen-ci`. This script still discovers and RUNS gates by
# globbing test/diff_compiler_*.sh directly — that is unchanged for now (the
# registry's rollout is ordered: generator first, done; preflight and this
# runner's own oracle/gate derivation follow in later, separate changes).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Keep the build/test write-storm OUT OF RAM (/tmp is a RAM-backed tmpfs).
. "$ROOT/test/lib_scratch.sh"
mdk_warn_if_tmp_full
NCPU="$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
# Outer pool: how many gates run at once. Inner pool (INNER_JOBS, exported as JOBS
# to each gate): a heavy gate's own fixture fan-out. Nesting the two naively gives
# OUTER×INNER concurrent processes and oversubscribes; but the gates are latency-
# bound (thousands of tiny process spawns/execs), so a little oversubscription
# hides that latency — but too much (outer=NCPU × inner) causes scheduling spikes.
# Measured sweet spot on a 10-core box: outer≈0.6·NCPU, inner=3 (stable ~34s full
# suite vs 47s at outer=NCPU vs 125s fully serial). Tune with JOBS/INNER_JOBS.
JOBS="${JOBS:-$(( (NCPU * 3 + 2) / 5 ))}"
[ "${JOBS:-0}" -ge 2 ] 2>/dev/null || JOBS=2
INNER_JOBS="${INNER_JOBS:-3}"

# ── PER-GATE COST TRANSPORT (#2178, S-1-S-cost-record) ────────────────────────
#
# `GATE_TIMING_JSON=<path>` makes this run ALSO write a machine-readable per-gate
# timing report to <path>. Unset (the default, and every local invocation) it
# writes nothing and changes nothing — the timing capture below is two `date`
# calls per gate and never touches the exit-code classification.
#
# WHY HERE AND NOT IN `medaka gate run`. CI-ARCHITECTURE.md §3.3 says timings are
# "recorded by the driver". The driver is not what CI executes: ci.yml's
# "Gate shard — …" step runs `sh test/run_gates.sh ${{ steps.plan.outputs.pats }}`,
# and `medaka gate run` is not yet CI's executor (it does not reproduce this
# script's exit-code CLASSIFICATION — see GATE-REGISTRY-DESIGN.md §7). A cost
# baseline must be measured on the code path CI actually takes, so the producer
# is this script. The SCHEMA is `medaka gate run --report`'s
# (`runReportJson`/`resultJson`, compiler/tools/gate_cmd.mdk) minus the two
# fields a cost record has no use for, so the day the driver does become the
# executor the transport is unchanged. See docs/ops/GATE-REGISTRY-DESIGN.md §7.
#
# ⚠️ POISONING GUARD — STRUCTURAL, NOT POLICY. A `pull_request` run is the ONE
# narrowable event (ci.yml's `detect` narrows `pats` for that event alone), so
# its per-gate times are measured over a gate subset and its shard wall-clocks
# mean nothing for balancing. This script therefore REFUSES TO PRODUCE a report
# at all when the event is a pull_request — not "CI happens not to ask for one",
# and not a filter in the consumer that a future edit could drop. The consumer
# (test/gate_cost_ingest.sh) independently refuses any report whose recorded
# event is not on its allowlist; both halves are load-bearing on purpose, and
# the consumer's half is the one under test (test/diff_compiler_gate_cost.sh).
GATE_TIMING_JSON="${GATE_TIMING_JSON:-}"
GATE_TIMING_SHARD="${GATE_TIMING_SHARD:-local}"
_ev="${GITHUB_EVENT_NAME:-local}"
case "$_ev" in
  pull_request|pull_request_target)
    if [ -n "$GATE_TIMING_JSON" ]; then
      echo "run_gates: REFUSING to write a timing report on a '$_ev' run —"
      echo "           that event is narrowable, so its per-gate times are not a"
      echo "           baseline sample. (GATE_TIMING_JSON=$GATE_TIMING_JSON ignored.)"
    fi
    GATE_TIMING_JSON=""
    ;;
esac
export GATE_TIMING_JSON

# Milliseconds since the epoch. GNU `date +%s%N` on Linux (every CI runner is
# ubuntu-latest, so every baseline sample comes from this arm); BSD/macOS `date`
# has no %N and prints a literal `N`, where this degrades to whole seconds
# rather than lying — [B-DUAL-PLATFORM]. Division is done in the shell, not awk:
# a 19-digit nanosecond count does not survive a double.
_now_ms() {
  _n=$(date +%s%N 2>/dev/null)
  case "$_n" in
    ''|*[!0-9]*) date +%s | awk '{ printf "%d\n", $1 * 1000 }' ;;
    *)           echo $(( _n / 1000000 )) ;;
  esac
}

# JSON string escaping for the few values that are not [a-z0-9_/.-] by
# construction (a ref name, a shard name from the matrix).
_jstr() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'
}

RESULTDIR="$(mktemp -d)"
trap 'rm -rf "$RESULTDIR"' EXIT

# A gate's exit-2 skip message is only a LEGITIMATE opt-in skip when it names a
# genuinely-absent piece of the platform toolchain. Every other exit-2 (a
# missing test/bin/* oracle, a missing ./medaka, a missing golden/fixture) means
# the gate never actually compared anything — reclassified as FAIL below.
#
# ⚠️ THIS REGEX IS A LAUNDERER, and a gate must not rely on it alone (#2065). It matches
# on a MESSAGE STRING, so any gate whose toolchain vanishes IN CI gets its silence
# blessed here: `diff_compiler_ir_scaling` did exactly that — valgrind absent, "not on
# PATH" printed, exit 2 reclassified to a legitimate SKIP, shard green, `Ir` scaling
# ungraded, no red anywhere. The repair is at the GATE, not here: both Ir gates now
# exit 1 (which no classifier can reinterpret) when their tool is missing and `CI` is
# set, and skip only off CI. Any new gate guarding on a toolchain owes the same split —
# a skip is a dev-box convenience, never a CI verdict.
LEGIT_SKIP_RE='no C compiler|libgc \(bdw-gc\)|not on PATH'

# ── A gate is identified by its PATH, not its basename ────────────────────────
#
# Gates do not all live in test/. `sqlite/test/*_oracle.sh` (22 differential gates
# against the real sqlite3 CLI) and test/native_fixtures/run.sh are gates too, and
# basenames COLLIDE across those roots (test/native_fixtures/run.sh vs
# playground/e2e/run.sh both stem to "run"). A results dir keyed on the basename
# would silently overwrite one gate's status with another's — "this didn't run"
# masquerading as "this passed", which is the one thing this suite exists to
# prevent. So key on the repo-relative path.
#
# The leading `test_` is stripped so the ~119 gates under test/ keep their familiar
# labels (diff_compiler_lexer, not test_diff_compiler_lexer) — only gates outside
# test/ gain a prefix, and they had no label before because they never ran.
#
# A `kind = "native"` gate's `run` is `test/<name>_test.mdk`, so stripping the
# `_test.mdk` suffix yields the SAME label its `.sh` carried before the
# migration. That is not cosmetic: test/gate_cost_baseline.json is keyed by gate
# label, so a migrated gate keeps its cost history instead of arriving uncosted
# and hard-refusing `medaka gate balance`.
gate_name() {
  printf '%s\n' "${1#"$ROOT"/}" \
    | sed -e 's|_test\.mdk$||' -e 's|\.sh$||' -e 's|/|_|g' -e 's|^test_||'
}

# ── Registry rows no `.sh` glob can find ─────────────────────────────────────
#
# A `kind = "native"` entry runs a `*_test.mdk` module, so the two-glob rule
# below cannot see it: a shard naming one would resolve to a SMALLER set with no
# error anywhere, which is the one failure this suite exists to prevent. These
# rows are read straight out of test/gates.toml (the same line-scan
# test/preflight.sh and ci.yml's `plan` step use) rather than through
# `./medaka gate list`, because two of the four resolvers that must agree run at
# a point in CI where no binary is built yet.
#
# One line per row: "<name> <repo-relative run path>". Neither field can contain
# a space (`gate verify` constrains a name; `run` is a path in this tree), so the
# pair survives shell word-splitting.
_native_rows() {
  awk -F'"' '
    /^\[\[gate\]\]/ { if (k == "native" && n != "" && r != "") print n, r; n=""; k=""; r="" }
    /^name = "/       { n = $2 }
    /^kind = "/       { k = $2 }
    /^run = "/        { r = $2 }
    END               { if (k == "native" && n != "" && r != "") print n, r }
  ' "$ROOT/test/gates.toml" 2>/dev/null
}

# The registry NAME of the native gate whose `run` is repo-relative path $1, or
# empty if there is none. `medaka gate run` selects by name, so the worker below
# asks the registry rather than guessing from the filename.
_native_name_of() {
  _native_rows | awk -v r="$1" '$2 == r { print $1; exit }'
}

# Gates outside test/ (the sqlite oracles) locate the tree through these rather
# than by walking up from $0. Defaults only — an explicit value always wins.
export MEDAKA_ROOT="${MEDAKA_ROOT:-$ROOT}"
export MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"

# ── Worker mode: run one gate, record its status ──────────────────────────────
if [ "${1:-}" = "--run-one" ]; then
  g="$2"
  rd="$3"
  name="$(gate_name "$g")"
  # ── HONOR THE SHEBANG. Do not hardcode `sh`. ────────────────────────────────
  #
  # This ran EVERY gate with `sh` — which on Debian is dash. But 6 gates under test/
  # are `#!/usr/bin/env bash` and use bashisms (`local`, `set -o pipefail`, process
  # substitution, `${BASH_SOURCE[0]}`), and THREE OF THEM ARE ALREADY IN CI SHARDS:
  # diff_compiler_engines, diff_compiler_lint_multi, diff_compiler_tmc_parity. They
  # have been run under the wrong interpreter this whole time. They happen to survive
  # it; that is luck, not design, and "the gate ran under an interpreter it wasn't
  # written for" is not a property you want to be lucky about.
  #
  # It stopped being luck the moment the sqlite oracles were enrolled: all 22 are
  # `#!/usr/bin/env bash`, and under dash all 22 FAILED — while passing perfectly when
  # invoked directly. A gate that fails only because the runner picked the wrong shell
  # is the purest form of the bug this suite exists to prevent: the result says
  # "the compiler is broken" and means "the harness is broken".
  #
  # A `kind = "native"` gate is a Medaka test module, not a script: it has no
  # shebang to honour and no `sh -n` that could parse it, and its invocation
  # (scratch dir, timeout, environment) belongs to `medaka gate run` so this
  # runner and that command cannot drift into two ways of running one gate.
  case "$g" in
    *.mdk) _native_gate=1 ;;
    *)     _native_gate=0 ;;
  esac
  if [ "$_native_gate" -eq 1 ]; then
    _shell=medaka
  else
    case "$(head -n 1 "$g")" in
      *bash*) _shell=bash ;;
      *)      _shell=sh ;;
    esac
  fi
  # ── SYNTAX-CHECK FIRST, before running the gate (#1577) ─────────────────────
  #
  # dash exits 2 on a genuine shell parse error (e.g. an unescaped apostrophe
  # inside a single-quoted string breaking the rest of the file) — the SAME
  # exit code the gates use, by convention, for "my oracle isn't built" (see
  # LEGIT_SKIP_RE below). Left unchecked, a gate with a syntax error is
  # indistinguishable from st=9's phantom skip, and AGENTS.md explicitly tells
  # readers to dismiss a phantom skip as "not a regression" — funneling a real,
  # loud breakage into the one verdict everyone is told to wave through.
  #
  # Honor the gate's own shebang, not a hardcoded `sh -n`: 6 gates under test/
  # are `#!/usr/bin/env bash` and use bashisms `sh -n` would reject as false
  # positives — reuse the same shebang dispatch just above.
  # The clock starts BEFORE the syntax pre-check and stops after the gate exits,
  # so a recorded ms is the whole cost this runner pays for that gate — which is
  # the quantity a shard balancer packs. It is written unconditionally; whether a
  # sample is USABLE is the consumer's call (test/gate_cost_ingest.sh drops any
  # gate whose `ok` is false), never a silent omission here.
  _t0=$(_now_ms)
  if [ "$_native_gate" -eq 0 ] && ! "$_shell" -n "$g" >"$rd/$name.log" 2>&1; then
    st=3   # syntax error: the gate script itself is malformed, not "unbuilt"
    raw=$st
    echo "$st" >"$rd/$name.status"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(( $(_now_ms) - _t0 ))" "$raw" "$st" "$_shell" \
      "${g#"$ROOT"/}" >"$rd/$name.timing"
    printf 'BROKEN %s  (SYNTAX ERROR: %s -n rejected this gate — see log)\n' "$name" "$_shell"
    exit 0
  fi
  if [ "$_native_gate" -eq 1 ]; then
    # Selected by registry NAME, asked of the registry rather than guessed from
    # the filename. `--no-stale-check` because this script already refused above
    # on a stale oracle, and running that check twice can only disagree.
    _gn="$(_native_name_of "${g#"$ROOT"/}")"
    if [ -z "$_gn" ]; then
      echo "$g: no native registry entry declares this run target" \
        >"$rd/$name.log"
      st=3
    elif JOBS="${INNER_JOBS:-1}" "$MEDAKA" gate run --no-stale-check "$_gn" \
           >"$rd/$name.log" 2>&1; then
      st=0
    else
      st=$?
    fi
  elif JOBS="${INNER_JOBS:-1}" "$_shell" "$g" >"$rd/$name.log" 2>&1; then
    st=0
  else
    st=$?
  fi
  _ms=$(( $(_now_ms) - _t0 ))
  raw=$st                # the gate's OWN exit code, before reclassification
  if [ "$st" = 2 ] && ! grep -qE "$LEGIT_SKIP_RE" "$rd/$name.log"; then
    st=9   # phantom skip: oracle/binary never built — a bug, not an opt-in skip
  fi
  echo "$st" >"$rd/$name.status"
  printf '%s\t%s\t%s\t%s\t%s\n' "$_ms" "$raw" "$st" "$_shell" "${g#"$ROOT"/}" \
    >"$rd/$name.timing"
  case "$st" in
    0) printf 'PASS  %s\n' "$name" ;;
    2) printf 'SKIP  %s\n' "$name" ;;
    9) printf 'FAIL* %s  (phantom skip: oracle/binary not built — see log)\n' "$name" ;;
    *) printf 'FAIL  %s\n' "$name" ;;
  esac
  exit 0
fi

# Accept MULTIPLE patterns, so the suite can be sharded across CI jobs:
#   sh test/run_gates.sh 'diff_compiler_lex*' 'diff_compiler_parse*'
# Do NOT be tempted to pass a brace expansion ('diff_compiler_{lex*,parse*}') —
# this script runs under POSIX sh (dash on Debian), which does NOT expand braces.
# It would silently glob to nothing; the "no gates match" guard below is what turns
# that into a loud failure instead of a green no-op.
#
# A gate matching two patterns is deduped, so overlapping shards are safe.
[ "$#" -gt 0 ] || set -- 'diff_compiler_*'

#
# A pattern resolves against BOTH `$ROOT/test/` and `$ROOT/`, so a shard can name a
# gate that does not live under test/ — e.g. 'sqlite/test/*_oracle' (the 22
# differential gates against the real sqlite3 CLI, which had never run in CI at all
# because no pattern could even REACH them). A bare pattern like 'diff_compiler_*'
# matches nothing at the repo root, so this is backwards-compatible.
#
# build_oracles.sh --for, test/preflight.sh's resolver, its re-resolver, its
# _gates_for_fixture_dir corpus scan, diff_compiler_ci_shard_coverage.sh and
# ci.yml's `plan` step resolve patterns the SAME way. All of them must agree: if
# one believed a shard pattern selected a gate another could not resolve, CI
# would certify coverage of a gate that silently never ran.
#
# The second arm is `kind = "native"` (#2591): such an entry has no `.sh` for the
# globs to find, so it resolves by registry NAME instead, and the gate IS its
# `run` module. It exists so a migration never silently shrinks a shard — proven
# by `effect_set_domain` (the first migrated row), and load-bearing from here on
# as more gates migrate.
gates=""
# "<name>:<run>" pairs — ':' because a `for` split over "<name> <run>" would tear
# the pair in half, and neither a gate name nor a path in this tree contains one.
_native_pairs="$(_native_rows | tr ' ' ':')"
for pat in "$@"; do
  for g in "$ROOT"/test/$pat.sh "$ROOT"/$pat.sh; do
    [ -f "$g" ] || continue
    case " $gates " in
      *" $g "*) ;;              # already selected by an earlier pattern
      *) gates="$gates $g" ;;
    esac
  done
  # `set -f` so the word split below cannot pathname-expand a registry row.
  # `case` patterns still glob under noglob, which is what makes
  # 'diff_compiler_*' select a native gate exactly as it selects a script one.
  set -f
  for _row in $_native_pairs; do
    case "${_row%%:*}" in
      $pat)
        _ng="$ROOT/${_row#*:}"
        [ -f "$_ng" ] || continue
        case " $gates " in
          *" $_ng "*) ;;
          *) gates="$gates $_ng" ;;
        esac ;;
    esac
  done
  set +f
done
[ -n "$gates" ] || { echo "no gates match: $*"; exit 1; }

# ── STALE ORACLES: refuse to run. A stale oracle does not fail — it LIES. ────────
#
# test/bin/* are compiled probe binaries. If one predates the compiler source, every
# gate that reads it is testing a compiler that no longer exists — and it reports a
# perfectly ordinary-looking FAIL. There is no way to tell that from a real regression
# by reading the output, and three agents were burned by it in one day:
#
#   * one saw `unbound variable 'areaOf'` — THE EXACT SYMPTOM OF THE BUG IT WAS FIXING —
#     emitted by a binary built before its own fix, and nearly re-diagnosed it;
#   * one saw diff_compiler_tmc_parity report `llvm=0 wasm=5` and read it as "my merge
#     broke the dispatch-group path". The LLVM probe was simply pre-merge;
#   * one chased a red eval_modules/core_ir_modules/llvm_modules trio that was purely age.
#
# So this is not a warning. A run against stale oracles PROVED NOTHING about the current
# source, and "proved nothing" must never be reported as pass OR as a compiler failure —
# that conflation is this suite's entire reason for existing (see the header).
#
# ⚠️ DISABLED IN CI ON PURPOSE — mtime is the WRONG SIGNAL THERE, and this is not a
# cop-out, it is the stronger check winning.
#
# CI restores test/bin from an actions/cache whose KEY IS A CONTENT HASH of compiler/**,
# stdlib/**, runtime/** and the build scripts. A cache HIT therefore means the oracles were
# built from exactly this source — proven by hash, not inferred from a clock. Meanwhile
# `actions/checkout` stamps every source file with a FRESH mtime, and the cache restores the
# binaries with their ORIGINAL (older) mtimes. So mtime says "stale" about oracles that are
# provably current, and this check red-lit all six shards on its first CI run.
#
# A content-hash key is STRICTLY STRONGER than an mtime comparison: mtime can be fooled by a
# touch, a checkout, or a clock skew; a hash cannot. Keep the weak local heuristic for local
# trees (where there is no hash to consult) and defer to the strong one where it exists.
#
# Also skipped by NO_STALE_CHECK=1 (build_oracles.sh's own internal invocations).
if [ -z "${NO_STALE_CHECK:-}" ] && [ -z "${CI:-}" ] && [ -d "$ROOT/test/bin" ]; then
  newest_src=0
  for f in $(find "$ROOT/compiler" "$ROOT/stdlib" -name '*.mdk' -not -name '*_test.mdk'; \
             find "$ROOT/runtime" -name '*.c' -o -name '*.h'); do
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
    [ "$m" -gt "$newest_src" ] && newest_src=$m
  done

  # Check ONLY the probes the SELECTED gates actually read — derived from the gate
  # scripts themselves (the same `test/bin/<name>` scrape build_oracles.sh --for uses),
  # not every file in test/bin.
  #
  # Checking all of test/bin was wrong and I shipped it for about five minutes: the wasm
  # probes are built by a DIFFERENT script (test/wasm/build_wasm_oracle.sh) and are not in
  # build_oracles' ENTRIES, so they are routinely older than source — which would have
  # blocked an unrelated `diff_compiler_lexer` run over a probe it never opens. Scope the
  # complaint to what this run actually depends on.
  #
  # This still catches the real cases: diff_compiler_tmc_parity DOES read the wasm probes,
  # so a stale one is flagged when — and only when — that gate is selected. That is exactly
  # the false RED that cost an agent a wrong diagnosis (`llvm=0 wasm=5`, from a pre-merge
  # LLVM probe).
  needed=""
  for g in $gates; do
    for o in $(grep -ohE 'test/bin/[a-z_0-9]+' "$g" 2>/dev/null | sed 's|test/bin/||' | sort -u); do
      case " $needed " in *" $o "*) ;; *) needed="$needed $o" ;; esac
    done
  done

  stale=""
  stale_all=""          # every stale name, untruncated (see the banner below, #470)
  n_stale=0
  for o in $needed; do
    b="$ROOT/test/bin/$o"
    [ -f "$b" ] || continue          # MISSING is a different failure — the phantom-skip
                                     # path below owns it, and says so in its own words.
    m=$(stat -c %Y "$b" 2>/dev/null || stat -f %m "$b" 2>/dev/null)
    if [ "${m:-0}" -lt "$newest_src" ]; then
      n_stale=$((n_stale + 1))
      [ "$n_stale" -le 6 ] && stale="$stale  $o
"
      # Every stale name, untruncated — this banner KNOWS exactly which probes are
      # stale, so it can print the exact narrow rebuild command instead of the blunt
      # whole-suite one (#470).
      stale_all="$stale_all $o"
    fi
  done

  if [ "$n_stale" -gt 0 ]; then
    echo "════════════════════════════════════════════════════════════════════"
    echo "STALE ORACLES ($n_stale) — REFUSING TO RUN."
    echo
    printf '%s' "$stale"
    [ "$n_stale" -gt 6 ] && echo "  ... and $((n_stale - 6)) more"
    echo
    echo "These probe binaries are OLDER than compiler/ stdlib/ runtime/ source."
    echo "A gate reading one is testing a compiler that no longer exists — and it"
    echo "reports an ordinary-looking FAIL that is INDISTINGUISHABLE from a real"
    echo "regression. Agents have re-diagnosed their own already-fixed bug from one."
    echo
    # ── Print the NARROW command, not the blunt one (#470) ──────────────────
    #
    # This banner used to lead with the unqualified `FORCE=1 sh test/build_oracles.sh`
    # — the whole-suite form that builds all 54 probes through an `xargs -P` pool that
    # OUTLIVES an agent's turn and gets respawned by the harness. AGENTS.md and
    # ORCHESTRATING.md both ban that command by name; this banner recommended it anyway,
    # at the exact moment an agent is blocked and looking for the next thing to type.
    # The banner won, because it is right there in the terminal and the ban is only in
    # prose. It has ALWAYS known which probes are stale ($stale_all) — it just printed
    # the blunt instrument instead of the narrow one it could already derive.
    echo "Rebuild ONLY what is stale — one probe per command:"
    for o in $stale_all; do
      echo "    FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $o"
    done
    echo
    echo "Or, for the gate set you asked for:"
    echo "    FORCE=1 sh test/build_oracles.sh --for '<gate>'"
    echo
    echo "⚠️  NOT 'FORCE=1 sh test/build_oracles.sh' with no --for/--build-one: that"
    echo "    rebuilds ALL 54 probes via an xargs -P pool that outlives an agent's turn"
    echo "    and gets respawned by the harness. It has killed several agent sessions"
    echo "    and held this shared box at load 40 for hours."
    echo
    echo "(Override with NO_STALE_CHECK=1 only if you know exactly why.)"
    echo "════════════════════════════════════════════════════════════════════"
    exit 1
  fi
fi

export INNER_JOBS

# ── FEED THE POOL COST-DESCENDING (#2207) ─────────────────────────────────────
#
# `xargs -P $JOBS` consumes this list IN ORDER, so the order IS the schedule.
# Fed in glob order — which is what happened until now — a row's wall clock
# depends on where alphabetically its expensive gates happen to fall: start a
# 480s gate last and every other worker idles behind it while it finishes alone.
#
# Longest-processing-time first is the standard list-scheduling heuristic, and
# it is the one `medaka gate balance` MODELS this pool with when it scores a
# row's makespan (`balAdd`/`balBucketAdd`, compiler/tools/gate_cmd.mdk). That
# is the real reason this is not merely a speed-up: until execution order here
# is deterministic AND matches the model, no makespan prediction is falsifiable
# — the same assignment would produce a different wall clock run to run, and a
# residual against the prediction would be measuring the glob.
#
# ⚠️ AN UNCOSTED GATE RUNS FIRST, NOT LAST. A gate with no baseline row is new,
# renamed, or moved, and its cost is UNKNOWN — not zero. The balancer refuses to
# pack on exactly that distinction (`balUncosted`: "a missing cost is not a cheap
# gate, it is an unknown one"), and the scheduling consequence points the same
# way: LPT's failure mode is a long job started late, so an unknown belongs at
# the front, where guessing wrong costs nothing if it turns out cheap. Ties
# break on the gate label, so the order is a function of the inputs rather than
# of the glob's — `candBefore`'s rule, for `candBefore`'s reason.
#
# A missing or unreadable baseline degrades to "every gate uncosted", i.e. a
# deterministic label order: no worse than the glob it replaces, and never an
# error — this is a scheduling hint, and a gate must still RUN without one.
_order="$RESULTDIR/.order"
for g in $gates; do
  printf '%s %s\n' "$(gate_name "$g")" "$g"
done | awk -v base="$ROOT/test/gate_cost_baseline.json" '
  # Field extraction by SUB, not by substr() arithmetic. The arithmetic form
  # was written first and was wrong by one character: it chopped the leading
  # digit off every cost (395575 -> 95575), which still sorted, still looked
  # like a plausible descending order, and still produced a schedule — just not
  # the one it claimed. There is no offset to get wrong here.
  BEGIN {
    while ((getline line < base) > 0) {
      if (line !~ /"medianMs":/) continue
      if (!match(line, /"name": "[^"]+"/)) continue
      n = substr(line, RSTART, RLENGTH); sub(/^"name": "/, "", n); sub(/"$/, "", n)
      if (!match(line, /"medianMs": [0-9]+/)) continue
      v = substr(line, RSTART, RLENGTH); sub(/^"medianMs": /, "", v)
      cost[n] = v + 0
    }
  }
  { if ($1 in cost) printf "1 %d %s %s\n", cost[$1], $1, $2
    else            printf "0 0 %s %s\n", $1, $2 }
' | sort -k1,1n -k2,2nr -k3,3 | cut -d' ' -f4 >"$_order"

# Wall clock spanning the whole fan-out (#2208): "from before the xargs -P
# $JOBS pool starts to after it drains" — the row's own total elapsed time,
# distinct from any single gate's `ms`. Nothing computed this before; it is a
# new measurement, not an existing one exposed.
_row_t0=$(_now_ms)
xargs -P "$JOBS" -I{} sh "$0" --run-one {} "$RESULTDIR" <"$_order"
_row_elapsed_ms=$(( $(_now_ms) - _row_t0 ))

# ── Summary ───────────────────────────────────────────────────────────────────
# status 9 = "phantom skip": the gate exited 2 because its oracle/binary was never
# built. That IS a failure (a gate that ran nothing must not report green — see the
# header), but it is a DIFFERENT failure from "the compiler is broken", and the
# summary must not conflate them.
#
# On a fresh worktree with no test/bin, EVERY oracle-reading gate phantom-skips, and
# the old summary printed a bare "63 failed" — which reads as a catastrophic
# regression. An agent hit exactly this tonight and had to read the per-gate
# annotations to discover the real message was just "you haven't built the oracles".
# Being loud is right; being loud AND misleading is not.
pass=0; fail=0; skip=0; phantom=0; syntax=0; failed=""
for s in "$RESULTDIR"/*.status; do
  [ -f "$s" ] || continue
  name="$(basename "$s" .status)"
  st="$(cat "$s")"
  case "$st" in
    0) pass=$((pass+1)) ;;
    2) skip=$((skip+1)) ;;
    9) fail=$((fail+1)); phantom=$((phantom+1)); failed="$failed $name" ;;
    3) fail=$((fail+1)); syntax=$((syntax+1)); failed="$failed $name" ;;
    *) fail=$((fail+1)); failed="$failed $name" ;;
  esac
done

printf '\n=== gates: %d passed, %d failed, %d skipped (JOBS=%s) ===\n' "$pass" "$fail" "$skip" "$JOBS"

# ── the per-gate cost report (#2178) ─────────────────────────────────────────
#
# Emitted BEFORE the failure branches below, because a red run's per-gate times
# are still real measurements of the gates that DID pass — the consumer decides
# what to admit, this script only reports. One gate per LINE, deliberately: the
# consumer is a shell tool, and a line-oriented record is one it can read
# without a JSON parser it does not have. Fields are `resultJson`'s
# (compiler/tools/gate_cmd.mdk), minus `stdout`/`stderr` — a cost record has no
# use for a gate's output, and omitting it also removes the one place arbitrary
# gate text could sit inside the document the consumer scans.
if [ -n "$GATE_TIMING_JSON" ]; then
  {
    echo '{'
    printf '  "schema": "gate-cost/1",\n'
    printf '  "jobs": %s,\n' "$JOBS"
    printf '  "parallel": true,\n'
    printf '  "rowElapsedMs": %s,\n' "$_row_elapsed_ms"
    printf '  "ok": %s,\n' "$pass"
    printf '  "failing": %s,\n' "$fail"
    printf '  "provenance": {\n'
    printf '    "event": "%s",\n'      "$(_jstr "$_ev")"
    printf '    "shard": "%s",\n'      "$(_jstr "$GATE_TIMING_SHARD")"
    printf '    "runId": "%s",\n'      "$(_jstr "${GITHUB_RUN_ID:-}")"
    printf '    "runAttempt": "%s",\n' "$(_jstr "${GITHUB_RUN_ATTEMPT:-}")"
    printf '    "repo": "%s",\n'       "$(_jstr "${GITHUB_REPOSITORY:-}")"
    printf '    "ref": "%s",\n'        "$(_jstr "${GITHUB_REF:-}")"
    printf '    "sha": "%s",\n'        "$(_jstr "${GITHUB_SHA:-}")"
    printf '    "date": "%s"\n'        "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  },\n'
    printf '  "gates": [\n'
    _sep=''
    for t in "$RESULTDIR"/*.timing; do
      [ -f "$t" ] || continue
      _n="$(basename "$t" .timing)"
      IFS='	' read -r _ms _raw _st _sh _script <"$t"
      _okj=false; [ "$_st" = 0 ] && _okj=true
      printf '%s    {"name": "%s", "script": "%s", "shell": "%s", "exit": %s, "timedOut": false, "ms": %s, "seconds": %s, "ok": %s, "spawnError": ""}' \
        "$_sep" "$_n" "$_script" "$_sh" "$_raw" "$_ms" \
        "$(echo "$_ms" | awk '{ printf "%.3f", $1 / 1000 }')" "$_okj"
      _sep=',
'
    done
    printf '\n  ]\n}\n'
  } >"$GATE_TIMING_JSON"
  echo "run_gates: per-gate cost report -> $GATE_TIMING_JSON (event=$_ev, shard=$GATE_TIMING_SHARD)"
fi
if [ "$fail" -gt 0 ]; then
  # If EVERY failure is a phantom skip, the compiler is fine — you just have no
  # oracles. Say that, instead of printing a bare failure count that reads like a
  # catastrophic regression.
  if [ "$phantom" -eq "$fail" ]; then
    cat <<EOF
FAIL: none of these gates could run — their oracle binaries are not built.
      This is NOT a compiler regression. test/bin/ is not committed, so a fresh
      clone or worktree has no oracles.

      Build them:  sh test/build_oracles.sh --for 'diff_compiler_*'
                   (52 oracles, ~2 min, foreground — the safe recipe)

      Or just what you need:
                   sh test/preflight.sh          # derives them from your diff
                   sh test/build_oracles.sh --for '<gate-pattern>'

      (These gates are counted as FAILED, not skipped, on purpose: a gate that ran
       nothing must never report green. That is a deliberate fix — a fresh clone
       used to run ZERO tests and print "0 failed".)
EOF
    echo "PHANTOM-SKIPPED:$failed"
    exit 1
  fi
  echo "FAILED:$failed"
  [ "$phantom" -gt 0 ] && echo "  ($phantom of these are phantom skips: oracle not built — see above)"
  [ "$syntax" -gt 0 ] && echo "  ($syntax of these are SYNTAX ERRORS: the gate script itself is malformed, not unbuilt/failing — see above)"
  # ── PRINT THE FAILING GATE'S OUTPUT. It used to be discarded, and that is a
  # diagnosability hole with teeth: each gate's stdout+stderr goes to a file in a
  # `mktemp -d` that nothing uploads and nothing prints, so a required CI shard could
  # fail with a bare `FAIL  <gate>` and NOTHING else. On a dev box you just re-run the
  # gate; in CI the temp dir is gone with the runner, so a failure that does not
  # reproduce locally is not diagnosable AT ALL.
  #
  # The incident that prompted this is worth stating exactly, because the obvious reading
  # of it is wrong: `diff_compiler_import_order` was red in the CI eval shard across three
  # pushes and green on seven local runs (warm build, cold bootstrap from the seed, JOBS=1,
  # JOBS=2 through this script, JOBS=12, two-core-pinned). That looked environment-dependent
  # and was not. `main` had gained a LEDGERED fixture the branch predated, the branch's fix
  # DRAINED it, and CI tests the PR merged onto `main` while the local tree does not — so
  # the two were grading different corpora. One line of the gate's own output said so
  # ("DRAINED — … no longer diverges"); it was thrown away, and hours went into
  # environment theories instead. A merge-vs-branch corpus difference is the single most
  # likely reason a gate is red only in CI, and it is exactly what this output reveals.
  #
  # Bounded per gate so a chatty gate cannot bury the summary above it.  200 lines, not
  # 80: the bound must clear the LONGEST failing gate in the tree with real margin, and it
  # does not clear it by much — `diff_compiler_must_fail.sh` prints 77 lines on a single
  # drained row and grows with every fixture added, and it is precisely the gate whose text
  # names the issue to close.  A bound that truncates the top of that output would cut the
  # per-fixture explanation and keep only the tally, which is the half you already had.
  # Derive the current worst case rather than trusting this number:
  #   for g in test/diff_compiler_*.sh; do printf '%s ' "$g"; sh "$g" 2>&1 | wc -l; done
  # `NO_FAIL_LOGS=1` restores the old silence.
  if [ -z "${NO_FAIL_LOGS:-}" ]; then
    for n in $failed; do
      lf="$RESULTDIR/$n.log"
      [ -f "$lf" ] || continue
      printf '\n───── %s — last %s lines of its output ─────\n' "$n" "${FAIL_LOG_LINES:-200}"
      tail -n "${FAIL_LOG_LINES:-200}" "$lf"
    done
    printf '\n'
  fi
  echo "(re-run a single gate by its path, e.g. sh test/<name>.sh"
  echo " — a name like sqlite_test_oracle is the repo-relative path with '/' as '_')"
  exit 1
fi
# Invariant: never report success having executed zero tests — a run where
# every gate skipped (even for a "legitimate" toolchain-absent reason) ran no
# comparisons and must not exit 0.
if [ "$pass" -eq 0 ]; then
  echo "FAIL: 0 gates passed ($skip skipped, $fail failed) — no tests were actually executed"
  exit 1
fi
exit 0
