#!/bin/sh
# cli_conformance_census.sh — re-derive the CLI conformance table from the BINARY.
#
# `docs/ops/CLI-CONFORMANCE.md` states four ratified conventions and a table of
# which cells conform to them. A table typed by hand is a snapshot of one
# afternoon: it is correct on the day it is written and silently wrong forever
# after. This script re-derives every machine-checkable column by EXECUTING
# ./medaka, so the doc can be re-confirmed in one command instead of re-audited.
#
# ── IT ASSERTS NOTHING. IT IS A CENSUS, NOT A GATE. ──────────────────────────
#
# It always exits 0. That is deliberate, and it is why this script is listed in
# test/CI-COVERAGE-TOOLS.txt rather than enrolled in test/gates.toml: several of
# the non-conforming cells it reports are KNOWN, OPEN defects that the
# cli-one-program sprint's later slices drain (#2354). A gate over ALL of them
# would be red from the moment it landed, which is how a red stops meaning
# anything. The enforcing gate over the AGREEMENT columns — the three
# help/parse-arm properties — is test/diff_compiler_cli_help_conformance.sh;
# this is the map that gate works from, and the two share one derivation
# (test/cli_conformance_lib.sh) rather than each deriving its own answer.
#
# ── EVERYTHING IS DERIVED. NOTHING IS ENCODED. ───────────────────────────────
#
# Three rosters this script could have hand-typed, and where each comes from
# instead ([DERIVE, don't encode]):
#
#   * THE VERB LIST comes from `medaka help`'s own usage block (the `  medaka
#     <verb>` column), not from a list in this file. A verb added to the CLI
#     without a usage line is therefore INVISIBLE here — which is itself a
#     finding, and one the census prints (see `verbs_missing_from_usage`).
#   * EACH VERB'S FLAG VOCABULARY comes from that verb's own `--help` output,
#     scraped at run time for `--`-shaped tokens.
#   * WHETHER A VERB ACTUALLY PARSES A FLAG is decided by RUNNING the verb with
#     it and classifying the result — never by grepping the source for a
#     literal. Source-grep cannot attribute a flag to a verb (the parse arms
#     live in per-verb helpers, in three different files), and a grep that
#     guesses the attribution would be a second, wrong answer to a question the
#     binary answers exactly.
#
# All three derivations live in test/cli_conformance_lib.sh, sourced below.
#
# Usage:
#   sh test/cli_conformance_census.sh              # full census, human table
#   sh test/cli_conformance_census.sh --verbs "check lint doc"   # a subset
#   MEDAKA=/path/to/medaka sh test/cli_conformance_census.sh
#
# Cheap by construction EXCEPT for `build`, which shells out to clang; pass
# --no-build to skip the two probes that reach it.

set -u

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
MEDAKA=${MEDAKA:-$ROOT/medaka}
VERBS_OVERRIDE=""
DO_BUILD=1

while [ $# -gt 0 ]; do
  case "$1" in
    --verbs) VERBS_OVERRIDE=$2; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "cli_conformance_census: unknown option '$1'" >&2; exit 1 ;;
  esac
done

if [ ! -x "$MEDAKA" ]; then
  echo "cli_conformance_census: no binary at $MEDAKA — run 'make medaka' first." >&2
  exit 0
fi

. "$ROOT/test/cli_conformance_lib.sh"
cli_lib_init || exit 0
trap 'cli_lib_cleanup' EXIT INT TERM

OUT=$CLI_OUT; ERR=$CLI_ERR

# ── the verb list, from the binary's own usage block ─────────────────────────
ALL_VERBS=$(cli_verbs)
if [ -n "$VERBS_OVERRIDE" ]; then
  VERBS=$VERBS_OVERRIDE
else
  VERBS=$ALL_VERBS
fi

echo "=============================================================================="
echo "medaka CLI conformance census"
echo "  binary : $MEDAKA"
echo "  version: $("$MEDAKA" --version 2>/dev/null)"
echo "  verbs  : $VERBS"
echo "=============================================================================="
echo

# ── column 1+2: unknown-flag disposition and its exit code ───────────────────
#
# Classification is behavioural, from the (rc, stream, text) triple:
#
#   REJECT-NAMED   rejected, and the message names the offending token   ← the
#                  ratified disposition (the #2316 `medaka test` wording)
#   REJECT-VAGUE   rejected, but the message does not name the token — the
#                  user is told the shape of the command, not their mistake
#   AS-FILENAME    not rejected; the token became a positional and the verb
#                  tried to OPEN it. The S0-shaped cell: a typo'd flag names
#                  a file.
#   SILENT-ACCEPT  exit 0, nothing printed — indistinguishable from success
#
echo "── unknown-flag disposition (probe: medaka <verb> --zzz-not-a-flag ok.mdk) ──"
printf '%-14s %-4s %-7s %-14s %s\n' VERB RC STREAM CLASS "first line of message"
for v in $VERBS; do
  case "$v" in
    build) [ "$DO_BUILD" = 1 ] || continue ;;
  esac
  cli_probe "$v" --zzz-not-a-flag ok.mdk
  st=$(cli_stream_of)
  msg=$(cat "$OUT" "$ERR" 2>/dev/null)
  if [ "$CLI_RC" = 0 ] && [ "$st" = silent ]; then
    cls=SILENT-ACCEPT
  elif printf '%s' "$msg" | grep -q -- '--zzz-not-a-flag'; then
    cls=REJECT-NAMED
  elif printf '%s' "$msg" | grep -qi 'no such file\|is a directory'; then
    cls=AS-FILENAME
  elif [ "$CLI_RC" = 0 ]; then
    cls=SILENT-IGNORE
  else
    cls=REJECT-VAGUE
  fi
  printf '%-14s %-4s %-7s %-14s %s\n' "$v" "$CLI_RC" "$st" "$cls" "$(cli_first_line)"
done
echo

# ── column 3: usage-error exit code, on the emptiest possible invocation ─────
echo "── usage-error exit code + stream (probe: medaka <verb>, no arguments) ──"
printf '%-14s %-4s %-7s %s\n' VERB RC STREAM "first line"
for v in $VERBS; do
  cli_probe "$v"
  printf '%-14s %-4s %-7s %s\n' "$v" "$CLI_RC" "$(cli_stream_of)" \
    "$(cli_msg | head -n 1 | cut -c1-88)"
done
echo

# ── column 4: "no .mdk files found" — one (stream, code) pair, or three? ─────
echo "── empty-directory target (probe: medaka <verb> empty/) ──"
printf '%-14s %-4s %-7s %s\n' VERB RC STREAM "first line"
for v in $VERBS; do
  case "$v" in build|new|repl|lsp|mcp|gate|help|version) continue ;; esac
  cli_probe "$v" empty
  printf '%-14s %-4s %-7s %s\n' "$v" "$CLI_RC" "$(cli_stream_of)" \
    "$(cli_msg | head -n 1 | cut -c1-88)"
done
echo

# ── column 5: --json availability, and WHICH CHANNEL the envelope lands on ───
#
# The channel is the load-bearing half. A machine consumer reads ONE stream; a
# verb that answers `--json` on the other one is unavailable to it in practice
# however well-formed the JSON is.
echo "── --json availability and channel (probe: medaka <verb> --json bad.mdk) ──"
printf '%-14s %-4s %-9s %s\n' VERB RC CHANNEL "verdict"
for v in $VERBS; do
  case "$v" in new|repl|lsp|mcp|help|version) continue ;; esac
  case "$v" in build) [ "$DO_BUILD" = 1 ] || continue ;; esac
  cli_probe "$v" --json bad.mdk
  ch=none; verdict="no envelope on either stream"
  if head -c 1 "$OUT" 2>/dev/null | grep -q '[{[]'; then
    ch=stdout; verdict="envelope on stdout"
  elif head -c 1 "$ERR" 2>/dev/null | grep -q '[{[]'; then
    ch=stderr; verdict="envelope on STDERR — a stdout consumer sees nothing"
  elif printf '%s' "$(cat "$ERR" "$OUT")" | grep -q -- '--json'; then
    verdict="--json rejected as an unknown flag"
  elif [ "$CLI_RC" = 0 ] || [ -s "$OUT" ] || [ -s "$ERR" ]; then
    verdict="--json accepted and IGNORED (human text)"
  fi
  printf '%-14s %-4s %-9s %s\n' "$v" "$CLI_RC" "$ch" "$verdict"
done
echo

# ── column 6: does `--help` work at all, and at first position only? ─────────
echo "── --help (probe: medaka <verb> --help) ──"
printf '%-14s %-4s %-7s %s\n' VERB RC STREAM "first line"
for v in $VERBS; do
  cli_probe "$v" --help
  printf '%-14s %-4s %-7s %s\n' "$v" "$CLI_RC" "$(cli_stream_of)" \
    "$(cat "$OUT" "$ERR" 2>/dev/null | head -n 1 | cut -c1-88)"
done
echo

# ── column 7: HELP/PARSE-ARM AGREEMENT, derived, per verb ────────────────────
#
# For every `--`-shaped token the verb's OWN help text names, run the verb with
# it and see whether the verb rejects it as unrecognized. A rejection is a hard
# finding: the help advertises a flag the parse arms do not have.
#
# The bound on this probe, the sub-name handling, and the mid-sentence-prose
# rule all live in cli_flag_verdict / cli_help_flags_of — see their headers in
# test/cli_conformance_lib.sh. THIS COLUMN IS GATED: the same call is what
# test/diff_compiler_cli_help_conformance.sh asserts on.
echo "── help/parse-arm agreement (each flag the verb's own --help names) ──"
printf '%-14s %-22s %-16s %s\n' VERB FLAG VERDICT "evidence"
for v in $VERBS; do
  case "$v" in help|version) continue ;; esac
  case "$v" in build) [ "$DO_BUILD" = 1 ] || continue ;; esac
  for f in $(cli_help_flags_of "$v"); do
    verdict=$(cli_flag_verdict "$v" "$f")
    if [ "$verdict" = NOT-PARSED ]; then
      printf '%-14s %-22s %-16s %s\n' "$v" "$f" "$verdict" "$CLI_EVIDENCE"
    fi
  done
done
echo "  (only NOT-PARSED rows are printed — a help text advertising a flag the"
echo "   verb rejects. An empty section here means every advertised flag parses.)"
echo

# ── column 7b: CROSS-REFERENCES inside help prose ────────────────────────────
#
# The column above only ever probes a flag against the verb whose help names
# it, so it is blind to the other way a help text lies: naming ANOTHER verb's
# flag in passing. `medaka run --help` used to say its `--release` is "kept for
# symmetry with `medaka build --release`" — and `build` has no `--release` arm
# at all, so the sentence explaining the flag was the false part, not the flag.
# Every `medaka <verb> --flag` phrase in every help text is therefore probed
# against the verb it actually names. ALSO GATED.
echo "── help-prose cross-references (every 'medaka <verb> --flag' phrase) ──"
printf '%-20s %-22s %-14s %s\n' "CITED IN" "CITED AS" VERDICT "evidence"
cli_crossref_pairs "$VERBS" | while read -r cv cf; do
  case "$cv" in help|version) continue ;; esac
  case "$cf" in --help) continue ;; esac
  case "$cv" in build) [ "$DO_BUILD" = 1 ] || continue ;; esac
  cli_probe "$cv" "$cf" Z ok.mdk
  m=$(cli_msg)
  if cli_rejects_as_unknown "$m" "$cf"; then
    printf '%-20s %-22s %-14s %s\n' "$cv" "$cf" NOT-PARSED "$(printf '%s' "$m" | head -n 1 | cut -c1-60)"
  else
    case "$m" in
      *"takes exactly one input file"*)
        printf '%-20s %-22s %-14s %s\n' "$cv" "$cf" NOT-PARSED \
          "$(printf '%s' "$m" | head -n 1 | cut -c1-60)" ;;
    esac
  fi
done
echo "  (only NOT-PARSED rows print. A verb that counts the cited flag as an extra"
echo "   POSITIONAL — 'takes exactly one input file' — has no arm for it either.)"
echo

# ── column 7c: PARSED BUT NOT ADVERTISED — the other direction ───────────────
#
# Columns 7 and 7b both run from the HELP side: they can only ever catch a help
# text promising something the arms do not have. Nothing you can RUN enumerates
# the flags nobody thought to try, so the reverse — an arm the help never
# mentions — was invisible to this census until the verbs learned to state their
# own roster. `assertCliFlags` renders `(known: --a, --b, --c)` in every
# unknown-flag rejection (S-unknown-flag-floor), so the binary now answers this
# direction too, in its own words. ALSO GATED.
echo "── parsed-but-not-advertised (each flag the verb's own roster names) ──"
printf '%-14s %-22s %s\n' VERB FLAG VERDICT
for v in $VERBS; do
  case "$v" in help|version) continue ;; esac
  case "$v" in build) [ "$DO_BUILD" = 1 ] || continue ;; esac
  known=$(cli_known_flags_of "$v")
  [ -n "$known" ] || { printf '%-14s %-22s %s\n' "$v" "-" "NO ROSTER (uncovered)"; continue; }
  helptext=$(cli_help_text_of "$v")
  for f in $known; do
    printf '%s' "$helptext" | grep -q -- "$f" \
      || printf '%-14s %-22s %s\n' "$v" "$f" UNDOCUMENTED
  done
done
echo "  (only UNDOCUMENTED rows and roster-less verbs print. A verb with NO ROSTER"
echo "   is not covered in this direction at all — see the gate's own report.)"
echo

# ── column 8: verbs the usage block does not mention ─────────────────────────
#
# The verb list above IS the usage block, so a verb missing from it is invisible
# to this census by construction. That blind spot is closed here, from the other
# side: the dispatch arms in the source, compared against what usage prints.
echo "── verbs_missing_from_usage (dispatch arms vs. the usage block) ──"
CLI=$ROOT/compiler/driver/medaka_cli.mdk
if [ -f "$CLI" ]; then
  sed -n 's/^  "\([a-z][a-z-]*\)"::rest =>.*/\1/p' "$CLI" | sort -u > "$CLI_WORK/dispatch"
  printf '%s\n' $ALL_VERBS | sort -u > "$CLI_WORK/advertised"
  miss=$(comm -23 "$CLI_WORK/dispatch" "$CLI_WORK/advertised" | tr '\n' ' ')
  [ -n "$miss" ] && echo "  DISPATCHED BUT NOT IN USAGE: $miss" || echo "  (none)"
  extra=$(comm -13 "$CLI_WORK/dispatch" "$CLI_WORK/advertised" | tr '\n' ' ')
  [ -n "$extra" ] && echo "  IN USAGE BUT NOT A DISPATCH ARM: $extra"
else
  echo "  (source not found at $CLI — skipped)"
fi
echo
echo "census complete. This script asserts nothing; see docs/ops/CLI-CONFORMANCE.md"
echo "for which of these cells conform to the ratified conventions, and"
echo "test/diff_compiler_cli_help_conformance.sh for the ones that are GATED."
exit 0
