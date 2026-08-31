#!/bin/sh
# diff_compiler_cli_help_conformance.sh — every help text must describe the CLI
# that actually exists (#2354, S-help-truthfulness; umbrella #2301).
#
# A help string is a promise the binary makes about itself, and it is the ONLY
# part of the CLI nothing was checking. Flags get added, renamed and removed in
# per-verb parse arms; the prose describing them sits in a different function in
# a different part of the file and rots in silence. Every member of the drift set
# this gate was built from was TRUE PROSE on the day it was written:
#
#   * `medaka run --help` explained its `--release` as "kept for symmetry with
#     `medaka build --release`" — and `build` has no `--release` arm at all.
#   * `medaka snapshot` parses `--root` and `--worker`; `snapshotHelpText`
#     mentioned neither.
#   * the top-level usage block advertised `medaka check [--json]` while
#     `checkHelpText` (correctly) advertised three flags, and offered
#     `medaka doc [file.mdk]` as optional when `doc` requires the file.
#
# None of those is catchable by a fixture over one verb's output, because none
# of them is wrong ON ITS OWN — each is a DISAGREEMENT between two places, and
# the drift is in whichever one moved. So this gate asserts agreement, not text.
#
# ── THE THREE PROPERTIES ─────────────────────────────────────────────────────
#
#   A  ADVERTISED ⊆ PARSED. Every `--`-shaped flag a verb's own `--help` names
#      must not be rejected by that verb as an unrecognized token.
#   B  CROSS-REFERENCES RESOLVE. Every `medaka <verb> --flag` phrase appearing in
#      ANY help text (including the top-level usage block) must name a flag that
#      THAT verb parses. A is blind to this: it only ever probes a flag against
#      the verb whose own help names it.
#   C  PARSED ⊆ ADVERTISED. Every flag in a verb's own `(known: …)` roster must
#      appear somewhere in that verb's `--help` output.
#
# A and B are execution-derived: run the verb with the flag, read the answer.
# C cannot be — nothing you can RUN enumerates the flags nobody thought to try —
# so it reads the roster each verb prints in its own unknown-flag rejection
# (`assertCliFlags`, compiler/driver/medaka_cli.mdk, landed by
# S-unknown-flag-floor). That is still the BINARY's answer, not a source-grep
# guess: source-grep cannot attribute a flag to a verb, because the parse arms
# live in per-verb helpers across three files.
#
# ── NOTHING IS ENCODED ───────────────────────────────────────────────────────
#
# There is no roster of verbs, flags or subcommands in this file. All of it comes
# out of the binary, through the ONE derivation in test/cli_conformance_lib.sh —
# shared with test/cli_conformance_census.sh, the map this gate was built from.
# A gate that re-derived the same facts its own way would be a second, possibly
# wrong answer to a question the binary answers exactly.
#
# ── WHAT THIS GATE DOES NOT COVER, STATED RATHER THAN HIDDEN ─────────────────
#
# Coverage is REPORTED, per verb, per property, on every run — including the
# `uncovered` count — because a gate that silently checks nine verbs of sixteen
# while reading as complete is worse than the drift it replaces.
#
#   * A and B answer "is this flag rejected as unknown", NOT "is this flag
#     honoured". A value-taking flag is probed with the dummy value `Z`; a flag
#     that validates its value reads as VALUE-REJECTED, which is evidence the arm
#     EXISTS. An accepted-but-ignored flag reads as PARSED, because from outside
#     the process it is — `medaka gate run --jobs` is exactly that, and is
#     documented as accepted-and-ignored in its own help, so it is CONFORMING
#     dead surface and this gate must not flag it.
#   * C covers only the verbs that PRINT a roster. A verb with no
#     `assertCliFlags` call is listed as `NO ROSTER (uncovered)` in the report
#     and asserted on in neither direction of C. `(known: none)` — a genuinely
#     flagless verb — is covered vacuously and correctly.
#   * `build` shells out to clang, so its probes are the slow ones; NO_BUILD=1
#     skips them and SAYS SO in the report rather than quietly narrowing.
#
# Usage:  sh test/diff_compiler_cli_help_conformance.sh
#         NO_BUILD=1 sh test/diff_compiler_cli_help_conformance.sh
# Exit:   0 all three properties hold; 1 a disagreement; 2 no ./medaka built.

set -u

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
MEDAKA=${MEDAKA:-$ROOT/medaka}
NO_BUILD=${NO_BUILD:-0}

if [ ! -x "$MEDAKA" ]; then
  echo "diff_compiler_cli_help_conformance: no binary at $MEDAKA — run 'make medaka' first." >&2
  exit 2
fi

. "$ROOT/test/cli_conformance_lib.sh"
cli_lib_init || exit 2
trap 'cli_lib_cleanup' EXIT INT TERM

FAILS=$CLI_WORK/fails
: > "$FAILS"
fail() { echo "FAIL $*" | tee -a "$FAILS"; }

VERBS=$(cli_verbs)
echo "== medaka CLI help/parse-arm conformance =="
echo "   binary: $MEDAKA"
echo "   verbs : $VERBS"
[ "$NO_BUILD" = 1 ] && echo "   NOTE  : NO_BUILD=1 — every \`build\` probe is SKIPPED (uncovered, not passing)."
echo

skip_build() { [ "$1" = build ] && [ "$NO_BUILD" = 1 ]; }

# ── A: every advertised flag parses ──────────────────────────────────────────
echo "-- A: advertised ⊆ parsed --"
a_ok=0; a_uncov=""
for v in $VERBS; do
  case "$v" in help|version) continue ;; esac
  if skip_build "$v"; then a_uncov="$a_uncov $v"; continue; fi
  flags=$(cli_help_flags_of "$v")
  if [ -z "$flags" ]; then
    echo "   $v: (advertises no flags)"
    continue
  fi
  for f in $flags; do
    verdict=$(cli_flag_verdict "$v" "$f")
    if [ "$verdict" = NOT-PARSED ]; then
      fail "A $v --help advertises $f, but \`medaka $v $f\` rejects it: $CLI_EVIDENCE"
    else
      a_ok=$((a_ok + 1))
    fi
  done
  echo "   $v: $(printf '%s ' $flags)"
done
echo "   A: $a_ok advertised flags parse.${a_uncov:+ UNCOVERED (NO_BUILD):$a_uncov}"
echo

# ── B: every help-prose cross-reference resolves ─────────────────────────────
echo "-- B: 'medaka <verb> --flag' cross-references resolve --"
b_ok=0; b_seen=0
cli_crossref_pairs "$VERBS" > "$CLI_WORK/pairs"
while read -r cv cf; do
  [ -n "$cv" ] || continue
  case "$cv" in help|version) continue ;; esac
  case "$cf" in --help) continue ;; esac
  if skip_build "$cv"; then continue; fi
  b_seen=$((b_seen + 1))
  cli_probe "$cv" "$cf" Z ok.mdk
  m=$(cli_msg)
  if cli_rejects_as_unknown "$m" "$cf"; then
    fail "B a help text cites \`medaka $cv $cf\`, but $cv rejects it: $(printf '%s' "$m" | head -n 1 | cut -c1-70)"
  else
    case "$m" in
      # A verb that counts the cited flag as an extra POSITIONAL has no arm for
      # it either — it merely fails later, and more confusingly.
      *"takes exactly one input file"*)
        fail "B a help text cites \`medaka $cv $cf\`, but $cv takes it as a POSITIONAL: $(printf '%s' "$m" | head -n 1 | cut -c1-70)" ;;
      *) b_ok=$((b_ok + 1)) ;;
    esac
  fi
done < "$CLI_WORK/pairs"
echo "   B: $b_ok of $b_seen cross-references resolve."
echo

# ── C: every parsed flag is advertised ───────────────────────────────────────
echo "-- C: parsed ⊆ advertised (each verb's own \`(known: …)\` roster) --"
c_ok=0; c_uncov=""
for v in $VERBS; do
  case "$v" in help|version) continue ;; esac
  if skip_build "$v"; then c_uncov="$c_uncov $v(NO_BUILD)"; continue; fi
  known=$(cli_known_flags_of "$v")
  if [ -z "$known" ]; then
    # Cannot distinguish "no flags" from "no roster" — so this is UNCOVERED, and
    # says so, rather than counting as a pass.
    c_uncov="$c_uncov $v"
    continue
  fi
  helptext=$(cli_help_text_of "$v")
  for f in $known; do
    if printf '%s' "$helptext" | grep -q -- "$f"; then
      c_ok=$((c_ok + 1))
    else
      fail "C \`medaka $v\` parses $f, but \`medaka $v --help\` never mentions it"
    fi
  done
  echo "   $v: $(printf '%s ' $known)"
done
echo "   C: $c_ok parsed flags are advertised."
[ -n "$c_uncov" ] && echo "   C UNCOVERED (verb prints no \`(known: …)\` roster):$c_uncov"
echo

# `wc -l`, not `grep -c`: grep EXITS 1 on an empty file, so a `|| echo 0`
# fallback appends a SECOND zero and every later `[ "$n" -eq 0 ]` dies on
# "Illegal number: 0\n0" — a counting bug that reports FAIL on a clean run.
n=$(wc -l < "$FAILS" | tr -d ' ')
if [ "$n" -eq 0 ]; then
  echo "PASS diff_compiler_cli_help_conformance: A/B/C all hold."
  exit 0
fi
echo "FAIL diff_compiler_cli_help_conformance: $n disagreement(s) above."
exit 1
