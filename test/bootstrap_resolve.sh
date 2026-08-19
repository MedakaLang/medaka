#!/bin/sh
# BOOTSTRAP (B4) — natively compiled self-hosted RESOLVE stage == reference over
# resolve_fixtures.  OCaml-free (REROOT-PLAN §2e): reference = committed golden
# originally captured from `main.exe run compiler/entries/resolve_main.mdk runtime
# core <fixture>` before the OCaml main.exe was removed.  boot_resolve is now a
# FROZEN dev-probe family — no ROWS entry in capture_goldens.sh, no regeneration
# script (#1642); a missing golden must be hand-written, see the remedy below.
# Native = test/bin/resolve_main with the SAME positional args (runtime core
# fixture).  Strip the native trailing "()" before the diff.  See bootstrap_lex.sh
# for the full rationale.
#
# Usage:  sh test/bootstrap_resolve.sh
# Exit:   0 all match; 2 oracle binary missing (run sh test/build_oracles.sh).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/resolve_main"
FIXDIR="$ROOT/test/resolve_fixtures"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$RUN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$RUN") (missing $RUN)"; exit 2; }

strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0
for fix in "$FIXDIR"/*.mdk; do
  [ -f "$fix" ] || continue
  name="$(basename "$fix")"
  golden="${fix%.mdk}.boot_resolve.golden"
  if [ ! -f "$golden" ]; then
    # ⚠️ `sh test/capture_goldens.sh boot_resolve` is a NO-OP for this corpus
    # (same trap as #1241, see diff_compiler_diagnostics.sh) — boot_resolve is a
    # FROZEN dev-probe family (the OCaml main.exe that originally captured it was
    # removed); no ROWS entry, no `--frozen` tag. There is no regeneration
    # script; hand-write via
    # `"$RUN" "$RUNTIME" "$CORE" "$fix" | strip_unit > "$golden"`, review the
    # output before committing it (a captured golden records what the engine
    # DID, not what is correct).
    fail=$((fail+1)); printf 'FAIL %s (no .boot_resolve.golden — NO REGEN SCRIPT; hand-write and review, see comment above)\n' "$name"; continue
  fi
  ref="$(cat "$golden")"
  self="$("$RUN" "$RUNTIME" "$CORE" "$fix" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '%s' "$ref"  > "$ROOT/.boot_ref.$$"
    printf '%s' "$self" > "$ROOT/.boot_self.$$"
    diff "$ROOT/.boot_ref.$$" "$ROOT/.boot_self.$$" | head -20 | sed 's/^/    /'
    rm -f "$ROOT/.boot_ref.$$" "$ROOT/.boot_self.$$"
  fi
done

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
