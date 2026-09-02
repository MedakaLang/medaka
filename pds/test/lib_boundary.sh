#!/bin/sh
# #2481 pds/lib ⇄ pds/shell boundary: pds/lib/*.mdk must never import
# pds/shell/ (the pure core performs no I/O — see pds/README.md's "Layout")
# and no pds/lib/*.mdk export may declare an effect row (`<...>`) in its
# signature. Both checks are cheap static greps/awk, no build required.
#
# A mutation control proves each check can actually fail: a throwaway
# violation is injected into a scratch copy of one pds/lib file, shown to
# red, then the real tree is checked again to prove it is untouched and
# green.
set -eu

ROOT=${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}
LIB_DIR="$ROOT/pds/lib"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pds-boundary.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# ── the two checks, parameterized over a directory ──────────────────────────

# Prints one violation line per offending import; exit 0 with no output when
# clean.
check_no_shell_import() {
  dir=$1
  find "$dir" -name '*.mdk' -print0 |
    xargs -0 grep -n '^import shell\.' 2>/dev/null || true
}

# Prints one violation line per exported signature that declares an effect
# row; exit 0 with no output when clean. An exported signature starts on its
# own "export" (or "public export") line, and may wrap across further
# INDENTED lines — the signature block ends at the next column-0 line.
check_no_effect_export() {
  dir=$1
  for f in "$dir"/*.mdk; do
    [ -f "$f" ] || continue
    awk -v file="$f" '
      /^export$/ || /^public export$/ { collecting = 1; sig = ""; first = 1; next }
      collecting {
        if (!first && $0 !~ /^[ \t]/) {
          if (sig ~ /</) print file ": " sig
          collecting = 0
        } else {
          sig = sig " " $0
          first = 0
        }
      }
    ' "$f"
  done
}

# ── the real tree ────────────────────────────────────────────────────────────

run_checks() {
  dir=$1
  label=$2
  shell_hits=$(check_no_shell_import "$dir")
  effect_hits=$(check_no_effect_export "$dir")
  if [ -n "$shell_hits" ]; then
    echo "$shell_hits" >&2
    fail "$label: pds/lib imports pds/shell"
  fi
  if [ -n "$effect_hits" ]; then
    echo "$effect_hits" >&2
    fail "$label: pds/lib exports an effect-bearing signature"
  fi
}

run_checks "$LIB_DIR" 'real tree'
echo 'boundary clean: no pds/lib -> pds/shell import, no effect-bearing pds/lib export'

# ── mutation control: prove each check can fail ─────────────────────────────

SCRATCH="$WORK/lib"
cp -R "$LIB_DIR" "$SCRATCH"

# Violation 1: a throwaway import of pds/shell.
VICTIM1="$SCRATCH/repo.mdk"
printf 'import shell.persist.{persistSave}\n' >>"$VICTIM1"
if shell_hits=$(check_no_shell_import "$SCRATCH") && [ -z "$shell_hits" ]; then
  fail 'mutation control: injected shell import was not caught'
fi
echo 'mutation control: injected shell import correctly caught'
rm -rf "$SCRATCH"

# Violation 2: a throwaway effect-bearing exported signature.
cp -R "$LIB_DIR" "$SCRATCH"
VICTIM2="$SCRATCH/repo.mdk"
printf '\nexport\nboundaryProbeForTest : Int -> <IO> Int\nboundaryProbeForTest x = x\n' \
  >>"$VICTIM2"
if effect_hits=$(check_no_effect_export "$SCRATCH") && [ -z "$effect_hits" ]; then
  fail 'mutation control: injected effect-bearing export was not caught'
fi
echo 'mutation control: injected effect-bearing export correctly caught'
rm -rf "$SCRATCH"

# The real tree is untouched (checks ran against copies only) and still green.
run_checks "$LIB_DIR" 'real tree, post-mutation-control'

echo 'PASS: lib_boundary — no shell import, no effect export, mutation control caught both'
