#!/bin/sh
# shell-because: trust-anchor — circular: checks the machinery a native gate would run inside
# check_fingerprint_parity.sh — proves the source-staleness fingerprint mirror
# still agrees with itself (issue #267).
#
# WHY THIS GATE EXISTS. test/build_native_medaka.sh's src_fingerprint_compiler()
# hashes `find compiler -name '*.mdk' -not -name '*_test.mdk' -print | LC_ALL=C sort`
# (names AND contents, via a `while read f; do printf ...; cat "$f"; done` shell
# loop) and bakes the
# result into ./medaka as -DMEDAKA_SRC_FP. compiler/driver/medaka_cli.mdk's
# `liveSourceFingerprint` REIMPLEMENTS that exact same algorithm (same find/sort,
# same hash_stream chain) in a one-shot perl one-liner for speed, and compares its
# live result against the baked value on every `./medaka` invocation
# (`checkSourceStaleness`; MEDAKA_STRICT=1 promotes a mismatch to a hard `exit 1`).
#
# These are TWO HAND-SYNCED IMPLEMENTATIONS of one hashing algorithm, in two
# different languages, in two different files, and NOTHING proved they still
# agree. #182's first attempt broke exactly this mirror (baked compiler+runtime
# while the live side stayed compiler-only) — every ./medaka invocation would
# have warned stale / hard-failed under MEDAKA_STRICT — and it was caught only by
# human review during PR #263, not by any gate. A future edit to either side
# (the shell loop in build_native_medaka.sh, or the perl one-liner in
# medaka_cli.mdk) can silently re-break the mirror the same way.
#
# THE INVARIANT THIS GATE ASSERTS (see the STOP-guardrail note below for why it
# is not a bare "the two hashes are always equal"): on the tree `./medaka` was
# JUST BUILT FROM, the compiler-only fingerprint baked into that binary
# (build_native_medaka.sh's src_fingerprint_compiler(), shell/cat-based) MUST
# equal the live compiler-only fingerprint medaka_cli.mdk's liveSourceFingerprint
# recomputes at runtime (perl-based) over that SAME tree. If the two
# implementations have drifted apart — different hashing, different file set,
# different newline handling, whatever — this is the one place that shows up:
# `MEDAKA_STRICT=1 ./medaka` on its own freshly-built, unmodified source tree
# must NOT warn stale and must NOT exit nonzero. It is deliberately silent about
# WHAT differs (that is a job for whoever edits either side); it only proves that
# TODAY, right now, the two agree.
#
# NOTE this is not "the fingerprint of an unchanged tree equals some fixed
# constant" — it is "the two INDEPENDENT implementations, run over the identical
# bytes, produce the identical hash." That is exactly the property #182 broke:
# both computations still ran fine on their own, they just stopped being the
# SAME computation. A raw comparison of the two, computed by two different tools
# over the same tree, is the only form of this check that actually tests parity
# rather than testing "did the tree change" (which every existing staleness path
# already tests, right down to the mtime-vs-fingerprint fix that fixed #89/#182).
#
# WHY THIS RUNS AS A STEP IN `compiler-soundness`, NOT A NEW GATE SHARD: it
# needs a freshly-built ./medaka on a tree matching that build (compiler-soundness
# already builds one via `make medaka` when it runs) — a new shard would need
# its own ci.yml matrix entry and its own oracle plumbing for no reason, when
# compiler-soundness (narrowed on `compiler_touched`/`soundness_corpora`) already
# has exactly the binary and tree state this needs. See AGENTS.md "a gate must
# run where the bug lands."
#
# ⚠️ TREATS A NON-COMPARISON AS FAILURE, NOT A PASS. A missing/non-executable
# ./medaka, a MEDAKA_ROOT that resolves to a tree with no compiler/ directory, or
# any inability to actually exercise checkSourceStaleness is a HARD FAIL here —
# never a silent skip. (checkSourceStaleness itself silently no-ops on a SHIPPED
# binary — no baked fingerprint, or no compiler/ beside it — by design, so that a
# distributed binary never warns about source it was never packaged with. That
# is the right behavior for a shipped binary; it is exactly the wrong behavior
# for a gate, so this script does not rely on the binary's own silence and checks
# every precondition itself before trusting its exit code.)
#
# Usage: sh test/check_fingerprint_parity.sh
# Exit:  0 the two fingerprint implementations agree (checked); 1 otherwise
#          (mismatch, or any precondition failed to hold).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/medaka"

if [ ! -x "$BIN" ]; then
  echo "FAIL: no executable $BIN — build it first (make medaka), then re-run this gate."
  echo "      (A missing binary is a FAILURE here, not a skip: this gate needs to actually"
  echo "       exercise the built binary's own staleness self-check.)"
  exit 1
fi

if [ ! -d "$ROOT/compiler" ]; then
  echo "FAIL: no $ROOT/compiler — cannot compare a live fingerprint against nothing."
  exit 1
fi

command -v perl >/dev/null 2>&1 || {
  echo "FAIL: no perl on PATH — liveSourceFingerprint silently no-ops without it, which"
  echo "      would make this gate pass by never actually comparing anything. Install perl."
  exit 1
}

# Exercise the binary's OWN staleness check (checkSourceStaleness / MEDAKA_STRICT=1),
# on the exact tree it was just built from. This is the parity assertion: the baked
# value came from build_native_medaka.sh's shell/cat-based src_fingerprint_compiler();
# the live value is recomputed right now by medaka_cli.mdk's perl-based
# liveSourceFingerprint. If the two implementations disagree, checkSourceStaleness
# prints the "may be stale" warning and MEDAKA_STRICT=1 turns that into exit 1.
OUT="$(cd "$ROOT" && MEDAKA_ROOT="$ROOT" MEDAKA_STRICT=1 "$BIN" --version 2>&1)"
STATUS=$?

if [ "$STATUS" -ne 0 ] || printf '%s\n' "$OUT" | grep -q 'may be stale'; then
  echo "FAIL: fingerprint mirror MISMATCH — build_native_medaka.sh's baked"
  echo "      src_fingerprint_compiler() and medaka_cli.mdk's liveSourceFingerprint no"
  echo "      longer agree on the SAME tree. One of the two hand-synced implementations"
  echo "      drifted from the other (issue #267). ./medaka output was:"
  printf '%s\n' "$OUT" | sed 's/^/      | /'
  exit 1
fi

echo "checked: build_native_medaka.sh's baked compiler-fingerprint == medaka_cli.mdk's"
echo "liveSourceFingerprint on $ROOT/compiler — PASS (mirror agrees)."

# ── ARM 2: the FP_FULL import-closure walker vs. the loader's real module graph ──
#
# FP_FULL no longer hashes all of compiler/ (#2680): it hashes the emitter's OWN
# import closure, plus stdlib/**.mdk (#2682) and runtime/*.c. That closure is
# computed by test/emitter_source_set.awk, a STATIC walker — src_fingerprint_full()
# runs on the cold path with no ./medaka in existence, so it cannot ask the real
# loader. So this is the SAME hand-synced-implementations hazard as arm 1, one
# level up: a reimplementation of driver.loader's `directImports`/`findInRoots`
# that can drift from the thing it models.
#
# The asymmetry is what makes this worth a gate rather than a comment. An
# OVER-reporting walker costs an unnecessary rebuild. An UNDER-reporting one —
# a new import form the regex misses, a module reached only through a shape the
# walker does not parse — makes stage A report "up-to-date" about an emitter
# built from source that is no longer on disk, which is the exact silent
# wrongness #182 and #2682 both are.
#
# The loader's own answer comes from compiler/entries/module_closure_probe.mdk.
# It is BUILT rather than `medaka run`, because the tree-walking interpreter
# overflows its 25000-frame limit parsing a graph this size.
echo
echo "arm 2: FP_FULL import-closure walker vs. the loader's real module graph ..."

# Derived from the script under test, never re-typed here: the two must name the
# same entry and roots or this arm proves nothing about what actually gets hashed.
FP_ENTRY="$(sed -n 's/^FP_ENTRY="\(.*\)"$/\1/p' "$ROOT/test/build_native_medaka.sh")"
FP_ROOTS="$(sed -n 's/^FP_ROOTS="\(.*\)"$/\1/p' "$ROOT/test/build_native_medaka.sh")"
if [ -z "$FP_ENTRY" ] || [ -z "$FP_ROOTS" ]; then
  echo "FAIL: could not read FP_ENTRY/FP_ROOTS out of test/build_native_medaka.sh."
  echo "      They are the entry + search roots FP_FULL's closure is taken over; if they"
  echo "      moved or were renamed, this arm would silently check a different graph."
  exit 1
fi
# The awk walker takes roots colon-separated; the probe takes them as argv words.
FP_ROOTS_SPACED="$(printf '%s' "$FP_ROOTS" | tr ':' ' ')"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STATIC="$WORK/static.txt"
# The walk and the sort are two statements, not one pipeline: `! cmd | sort` negates
# the PIPELINE's status, which is sort's, so a walker exiting 1 would be absorbed and
# reported later as a downstream symptom (an empty list) naming the wrong cause.
if ! ( cd "$ROOT" && awk -v entry="$FP_ENTRY" -v roots="$FP_ROOTS" \
         -f test/emitter_source_set.awk ) > "$WORK/static.raw"; then
  echo "FAIL: test/emitter_source_set.awk could not walk $FP_ENTRY."
  echo "      src_fingerprint_full() would fall back to hashing all of compiler/ — safe,"
  echo "      but it means the narrowing this gate exists to protect is not in effect."
  exit 1
fi
LC_ALL=C sort "$WORK/static.raw" > "$STATIC"

PROBE_SRC="$ROOT/compiler/entries/module_closure_probe.mdk"
PROBE_BIN="$WORK/module_closure_probe"
if [ ! -f "$PROBE_SRC" ]; then
  echo "FAIL: no $PROBE_SRC — this arm has nothing to ask the loader with."
  exit 1
fi
[ -x "$ROOT/medaka_emitter" ] && export MEDAKA_EMITTER="$ROOT/medaka_emitter"
# Redirected, not piped: `medaka build`'s exit code does not survive a pipe
# (AGENTS.md [D-BUILD-PIPE]).
if ! ( cd "$ROOT" && "$BIN" build "$PROBE_SRC" -o "$PROBE_BIN" ) > "$WORK/build.log" 2>&1; then
  echo "FAIL: could not build $PROBE_SRC:"
  sed 's/^/      | /' "$WORK/build.log"
  exit 1
fi

LOADER="$WORK/loader.txt"
if ! ( cd "$ROOT" && "$PROBE_BIN" "$FP_ENTRY" $FP_ROOTS_SPACED ) > "$LOADER".raw 2>"$WORK/probe.err"; then
  echo "FAIL: $PROBE_SRC exited nonzero:"
  sed 's/^/      | /' "$WORK/probe.err"
  exit 1
fi
LC_ALL=C sort "$LOADER".raw > "$LOADER"

# BOTH lists must be non-empty before `diff` is allowed to mean anything: two
# empty files compare equal and would manufacture a pass out of a walker that
# walked nothing and a probe that loaded nothing (#2682's first attempt did
# exactly this with two empty IR dumps).
if [ ! -s "$STATIC" ] || [ ! -s "$LOADER" ]; then
  echo "FAIL: empty closure list — static=$(wc -l < "$STATIC") loader=$(wc -l < "$LOADER")."
  echo "      A comparison of two empty lists is not a passing comparison."
  exit 1
fi

if ! diff -u "$STATIC" "$LOADER" > "$WORK/closure.diff"; then
  echo "FAIL: the static FP_FULL walker and driver.loader disagree on the import"
  echo "      closure of $FP_ENTRY (-static +loader):"
  sed 's/^/      | /' "$WORK/closure.diff"
  echo "      A '-' line is a file FP_FULL hashes but the emitter never compiles"
  echo "      (harmless, costs a rebuild). A '+' line is a file the emitter DOES"
  echo "      compile that FP_FULL does NOT hash — stage A will report 'up-to-date'"
  echo "      about an emitter built from source that has since changed."
  exit 1
fi

echo "checked: test/emitter_source_set.awk == driver.loader's real closure of"
echo "$FP_ENTRY ($(wc -l < "$STATIC" | tr -d ' ') modules) — PASS."
exit 0
