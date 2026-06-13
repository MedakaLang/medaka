#!/bin/sh
# Phase 0 (DRIVER-COLLAPSE-PLAN) equivalence harness — TEMPORARY (deleted in Phase 5).
#
# Runs every existing single-file flat fixture through BOTH:
#   (a) the FLAT path     — elaborateDict → evalOutput   (eval_dict_main pipeline)
#   (b) the 1-MODULE path — elaborateOne  → evalOneOutput (the new wrappers)
# via the additive probe selfhost/entries/flat_vs_one_probe.mdk (one binary, a
# `flat|one` mode arg), and asserts byte-identical stdout.  Its job is to PROVE
# 1-module ≡ flat before any real driver migrates — or to surface (FAIL lines) the
# exact fixtures where they diverge, which scope the later phases.
#
# OCaml-free: both sides are native (the probe is one self-hosted binary).  This is
# NOT a vs-OCaml gate.
#
# Usage:  sh test/diff_flat_vs_onemodule.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
PROBE_SRC="$ROOT/selfhost/entries/flat_vs_one_probe.mdk"
PROBE_BIN="$ROOT/test/bin/flat_vs_one_probe"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"

# Corpora: the single-file fixtures the flat path is exercised on today.
FIXDIRS="$ROOT/test/eval_fixtures $ROOT/test/eval_dict_fixtures"

command -v clang >/dev/null 2>&1 || { echo "no clang on PATH — skipping (opt-in)"; exit 2; }
[ -x "$MEDAKA" ] && [ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

# ── build the probe (always, so a wrapper/probe edit is reflected) ─────────────
mkdir -p "$ROOT/test/bin"
printf 'building flat_vs_one_probe ...\n'
if ! ( cd "$ROOT" && MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build "$PROBE_SRC" -o "$PROBE_BIN" ) >"$PROBE_BIN.buildlog" 2>&1; then
  echo "FAIL: could not native-compile flat_vs_one_probe:"; tail -12 "$PROBE_BIN.buildlog"; exit 1
fi
[ -x "$PROBE_BIN" ] || { echo "FAIL: probe build produced no binary"; tail -12 "$PROBE_BIN.buildlog"; exit 1; }
rm -f "$PROBE_BIN.buildlog"

strip_unit() { sed '${/^()$/d;}'; }  # drop native runtime's trailing Unit auto-print

pass=0; diverge=0; err=0
for dir in $FIXDIRS; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.mdk; do
    [ -f "$f" ] || continue
    name="$(basename "$dir")/$(basename "$f")"
    flat="$("$PROBE_BIN" flat "$RT" "$CORE" "$f" 2>/dev/null | strip_unit)"
    fst=$?
    one="$("$PROBE_BIN" one "$RT" "$CORE" "$f" 2>/dev/null | strip_unit)"
    ost=$?
    if [ "$fst" -ne 0 ] || [ "$ost" -ne 0 ]; then
      err=$((err+1)); printf 'ERR  %s (flat exit %s / one exit %s)\n' "$name" "$fst" "$ost"; continue
    fi
    if [ "$flat" = "$one" ]; then
      pass=$((pass+1)); printf 'ok   %s\n' "$name"
    else
      diverge=$((diverge+1))
      printf 'DIVERGE %s\n  flat: %s\n  one : %s\n' "$name" "$flat" "$one"
    fi
  done
done

printf '\n%d identical, %d DIVERGE, %d error\n' "$pass" "$diverge" "$err"
# Phase 0 is discovery: divergences are the deliverable, not a build failure.  Exit
# 0 if the harness RAN (no probe/exec errors); non-zero only on infrastructure error.
[ "$err" -eq 0 ]
