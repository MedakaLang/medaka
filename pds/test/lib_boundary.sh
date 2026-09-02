#!/bin/sh
# #2481 pds/lib ⇄ pds/shell boundary: pds/lib/*.mdk must never import
# pds/shell/ (the pure core performs no I/O — see pds/README.md's "Layout")
# every pds/lib/*.mdk export must carry an explicit type signature, and no
# such signature may declare an effect row (`<...>`). The signature check is
# what makes the effect check non-bypassable: an unannotated export gets an
# inferred row, which no grep over declared rows can see. All three checks
# are cheap static greps/awk, no build required.
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

# Prints one violation line per export that carries no explicit type
# signature; exit 0 with no output when clean. Without this the effect check
# above is bypassable by omission: an export with no signature at all
# compiles (the typechecker infers its row), and an inferred effect row is
# invisible to a grep over declared ones.
#
# A signature is the first non-blank line after the `export` line and has the
# form `<name> : ...`; a definition (`<name> <args> = ...`) does not. `export
# data`/`export interface` and friends put the keyword on the `export` line
# itself, so they never enter this state machine.
check_export_has_signature() {
  dir=$1
  for f in "$dir"/*.mdk; do
    [ -f "$f" ] || continue
    awk -v file="$f" '
      /^export$/ || /^public export$/ { pending = NR; next }
      pending {
        if ($0 ~ /^[ \t]*$/) next
        if ($0 !~ /^[^ \t:]+[ \t]*:/)
          print file ":" pending ": export without a type signature: " $0
        pending = 0
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
  unsigned_hits=$(check_export_has_signature "$dir")
  if [ -n "$shell_hits" ]; then
    echo "$shell_hits" >&2
    fail "$label: pds/lib imports pds/shell"
  fi
  if [ -n "$effect_hits" ]; then
    echo "$effect_hits" >&2
    fail "$label: pds/lib exports an effect-bearing signature"
  fi
  if [ -n "$unsigned_hits" ]; then
    echo "$unsigned_hits" >&2
    fail "$label: pds/lib export carries no type signature"
  fi
}

run_checks "$LIB_DIR" 'real tree'
echo 'boundary clean: no pds/lib -> pds/shell import, every pds/lib export signed, none effect-bearing'

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

# Violation 3: an unannotated export whose effect row the typechecker would
# infer. This is exactly what violation 2's check cannot see, which is why
# the signature check exists.
cp -R "$LIB_DIR" "$SCRATCH"
VICTIM3="$SCRATCH/repo.mdk"
printf '\nexport\nboundaryUnsignedProbeForTest x = println x\n' >>"$VICTIM3"
if effect_hits=$(check_no_effect_export "$SCRATCH") && [ -n "$effect_hits" ]; then
  fail 'mutation control: the effect check was expected to MISS an unannotated export'
fi
if unsigned_hits=$(check_export_has_signature "$SCRATCH") \
  && [ -z "$unsigned_hits" ]; then
  fail 'mutation control: injected unannotated export was not caught'
fi
echo 'mutation control: injected unannotated effect-bearing export correctly caught'
rm -rf "$SCRATCH"

# The real tree is untouched (checks ran against copies only) and still green.
run_checks "$LIB_DIR" 'real tree, post-mutation-control'

echo 'PASS: lib_boundary — no shell import, every export signed, no effect export, mutation control caught all three'
