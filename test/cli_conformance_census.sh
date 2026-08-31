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
# test/CI-COVERAGE-TOOLS.txt rather than enrolled in test/gates.toml: every
# non-conforming cell it reports today is a KNOWN, OPEN defect that the
# cli-one-program sprint's later slices drain (#2354). A gate here would be red
# from the moment it landed and would stay red for the length of the sprint,
# which is how a red stops meaning anything. The enforcing gate is S-4's
# help/parse-arm agreement gate; this is the map that slice works from.
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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cli-census.XXXXXX") || exit 0
trap 'rm -rf "$WORK"' EXIT INT TERM
printf 'main = println 1\n' > "$WORK/ok.mdk"
printf 'main = println (1 + True)\n' > "$WORK/bad.mdk"
mkdir -p "$WORK/empty"

# `MEDAKA_STRICT=1` on every probe so a stale binary fails loudly rather than
# answering ([B-STALENESS]/[B-STDERR]): a census read off a stale binary is a
# census of last week's CLI.
export MEDAKA_STRICT=1

OUT="$WORK/o"; ERR="$WORK/e"

# run <verb-and-args...>  →  sets RC / OUT / ERR files. stdin is /dev/null so
# the three stdio servers (repl/lsp/mcp) terminate instead of blocking.
probe() {
  ( cd "$WORK" && "$MEDAKA" "$@" >"$OUT" 2>"$ERR" </dev/null )
  RC=$?
}

# Where did this invocation speak? stdout / stderr / both / silent.
stream_of() {
  _o=0; _e=0
  [ -s "$OUT" ] && _o=1
  [ -s "$ERR" ] && _e=1
  case "$_o$_e" in
    00) echo "silent" ;;
    10) echo "stdout" ;;
    01) echo "stderr" ;;
    *)  echo "both" ;;
  esac
}

first_line() { head -n 1 "$1" | cut -c1-96; }

# ── the verb list, from the binary's own usage block ─────────────────────────
"$MEDAKA" help >"$WORK/usage" 2>/dev/null
if [ -n "$VERBS_OVERRIDE" ]; then
  VERBS=$VERBS_OVERRIDE
else
  VERBS=$(sed -n 's/^  medaka \([a-z][a-z-]*\).*/\1/p' "$WORK/usage" | sort -u | tr '\n' ' ')
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
  probe "$v" --zzz-not-a-flag ok.mdk
  st=$(stream_of)
  msg=$(cat "$OUT" "$ERR" 2>/dev/null)
  if [ "$RC" = 0 ] && [ "$st" = silent ]; then
    cls=SILENT-ACCEPT
  elif printf '%s' "$msg" | grep -q -- '--zzz-not-a-flag'; then
    cls=REJECT-NAMED
  elif printf '%s' "$msg" | grep -qi 'no such file\|is a directory'; then
    cls=AS-FILENAME
  elif [ "$RC" = 0 ]; then
    cls=SILENT-IGNORE
  else
    cls=REJECT-VAGUE
  fi
  line=$(cat "$ERR" "$OUT" 2>/dev/null | head -n 1 | cut -c1-96)
  printf '%-14s %-4s %-7s %-14s %s\n' "$v" "$RC" "$st" "$cls" "$line"
done
echo

# ── column 3: usage-error exit code, on the emptiest possible invocation ─────
echo "── usage-error exit code + stream (probe: medaka <verb>, no arguments) ──"
printf '%-14s %-4s %-7s %s\n' VERB RC STREAM "first line"
for v in $VERBS; do
  probe "$v"
  printf '%-14s %-4s %-7s %s\n' "$v" "$RC" "$(stream_of)" \
    "$(cat "$ERR" "$OUT" 2>/dev/null | head -n 1 | cut -c1-88)"
done
echo

# ── column 4: "no .mdk files found" — one (stream, code) pair, or three? ─────
echo "── empty-directory target (probe: medaka <verb> empty/) ──"
printf '%-14s %-4s %-7s %s\n' VERB RC STREAM "first line"
for v in $VERBS; do
  case "$v" in build|new|repl|lsp|mcp|gate|help|version) continue ;; esac
  probe "$v" empty
  printf '%-14s %-4s %-7s %s\n' "$v" "$RC" "$(stream_of)" \
    "$(cat "$ERR" "$OUT" 2>/dev/null | head -n 1 | cut -c1-88)"
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
  probe "$v" --json bad.mdk
  ch=none; verdict="no envelope on either stream"
  if head -c 1 "$OUT" 2>/dev/null | grep -q '[{[]'; then
    ch=stdout; verdict="envelope on stdout"
  elif head -c 1 "$ERR" 2>/dev/null | grep -q '[{[]'; then
    ch=stderr; verdict="envelope on STDERR — a stdout consumer sees nothing"
  elif printf '%s' "$(cat "$ERR" "$OUT")" | grep -q -- '--json'; then
    verdict="--json rejected as an unknown flag"
  elif [ "$RC" = 0 ] || [ -s "$OUT" ] || [ -s "$ERR" ]; then
    verdict="--json accepted and IGNORED (human text)"
  fi
  printf '%-14s %-4s %-9s %s\n' "$v" "$RC" "$ch" "$verdict"
done
echo

# ── column 6: does `--help` work at all, and at first position only? ─────────
echo "── --help (probe: medaka <verb> --help) ──"
printf '%-14s %-4s %-7s %s\n' VERB RC STREAM "first line"
for v in $VERBS; do
  probe "$v" --help
  printf '%-14s %-4s %-7s %s\n' "$v" "$RC" "$(stream_of)" \
    "$(cat "$OUT" "$ERR" 2>/dev/null | head -n 1 | cut -c1-88)"
done
echo

# ── column 7: HELP/PARSE-ARM AGREEMENT, derived, per verb ────────────────────
#
# For every `--`-shaped token the verb's OWN help text names, run the verb with
# it and see whether the verb rejects it as unrecognized. A rejection is a hard
# finding: the help advertises a flag the parse arms do not have.
#
# ⚠️ THE BOUND, STATED RATHER THAN HIDDEN. This probe answers "is this flag
# rejected as unknown", not "is this flag honoured". A value-taking flag is
# given the dummy value `Z` (a bare `--flag` with no value can fail for the
# missing value rather than for the flag), so a flag that validates its value
# shows up as VALUE-REJECTED — real evidence the arm EXISTS, not a defect. And
# an accepted-but-ignored flag (`gate run --jobs`, documented as such in its
# own help) reads as PARSED here, because from outside the process it is. That
# residue is S-4's to close with a source-side derivation; this column's job is
# to hand S-4 the list, having already excluded everything the binary can
# settle on its own.
#
# Two shapes the naive probe gets wrong, both handled DERIVED rather than by a
# list of verb names in this file:
#
#   * A verb whose first positional is a required SUB-NAME (`medaka gate list`,
#     `medaka codemod effect-labels`) rejects a leading flag as a bad sub-name,
#     not as a bad flag. Detected from the verb's own rejection wording, and
#     the sub-name to use is read out of that same message's `(expected: a, b,
#     …)` list, or off the `Available …:` block its no-argument usage prints.
#   * `--flag` appearing MID-SENTENCE in help prose is a metavariable, not a
#     flag ("Any other --flag consumes the next token as its value"). Only
#     tokens at the start of an indented help line are taken as advertised.
echo "── help/parse-arm agreement (each flag the verb's own --help names) ──"
printf '%-14s %-22s %-16s %s\n' VERB FLAG VERDICT "evidence"
for v in $VERBS; do
  case "$v" in help|version) continue ;; esac

  # Does this verb want a sub-name first? Ask it, and read the answer. A
  # multi-subcommand verb's help is the UNION over its subcommands, so a flag
  # is "parsed" if ANY subcommand takes it — probe them all rather than
  # reporting `gate run --jobs` as missing because `gate list` refuses it.
  SUBS=""
  probe "$v" --zzz-not-a-flag ok.mdk
  submsg=$(cat "$ERR" "$OUT" 2>/dev/null)
  case "$submsg" in
    *"unknown subcommand"*|*"unknown codemod"*)
      SUBS=$(printf '%s' "$submsg" \
             | sed -n 's/.*(expected: \([a-z, -]*\)).*/\1/p' | tr -d ',' | head -n 1)
      if [ -z "$SUBS" ]; then
        probe "$v"
        SUBS=$(sed -n 's/^  \([a-z][a-z0-9-]*\) *—.*/\1/p' "$OUT" "$ERR" 2>/dev/null | tr '\n' ' ')
      fi
      ;;
  esac

  # `@none` is a sentinel, not a subcommand: it keeps the loop below one shape
  # for both the sub-taking and the flat verbs.
  [ -n "$SUBS" ] || SUBS=@none

  probe "$v" --help
  flags=$(sed -n 's/^[[:space:]]*\(--[a-z][a-z-]*\).*/\1/p' "$OUT" | sort -u)
  [ -n "$flags" ] || continue
  for f in $flags; do
    case "$f" in --help) continue ;; esac
    case "$v" in build) [ "$DO_BUILD" = 1 ] || continue ;; esac
    verdict=NOT-PARSED
    for s in $SUBS; do
      if [ "$s" = @none ]; then probe "$v" "$f" Z ok.mdk; else probe "$v" "$s" "$f" Z ok.mdk; fi
      msg=$(cat "$ERR" "$OUT" 2>/dev/null)
      if printf '%s' "$msg" | grep -qi "unknown flag: $f\|unrecognized flag '$f'\|unknown option '$f'\|unknown argument '$f'\|unknown codemod '$f'\|unknown subcommand '$f'"; then
        continue
      elif printf '%s' "$msg" | grep -q -- "$f"; then
        verdict=VALUE-REJECTED; break
      else
        verdict=PARSED; break
      fi
    done
    if [ "$verdict" = NOT-PARSED ]; then
      printf '%-14s %-22s %-16s %s\n' "$v" "$f" "$verdict" \
        "$(printf '%s' "$msg" | head -n 1 | cut -c1-70)"
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
# flag in passing. `medaka run --help` says its `--release` is "kept for
# symmetry with `medaka build --release`" — and `build` has no `--release` arm
# at all, so the sentence explaining the flag is the false part, not the flag.
# Every `medaka <verb> --flag` phrase in every help text is therefore probed
# against the verb it actually names.
echo "── help-prose cross-references (every 'medaka <verb> --flag' phrase) ──"
printf '%-20s %-22s %-14s %s\n' "CITED IN" "CITED AS" VERDICT "evidence"
{ cat "$WORK/usage"; for v in $VERBS; do probe "$v" --help; sed "s/^/$v|/" "$OUT"; done; } \
  > "$WORK/allhelp" 2>/dev/null
sed -n 's/.*medaka \([a-z][a-z-]*\) \(--[a-z][a-z-]*\).*/\1 \2/p' "$WORK/allhelp" \
  | sort -u | while read -r cv cf; do
  case "$cv" in help|version) continue ;; esac
  case "$cf" in --help) continue ;; esac
  case "$cv" in build) [ "$DO_BUILD" = 1 ] || continue ;; esac
  probe "$cv" "$cf" Z ok.mdk
  m=$(cat "$ERR" "$OUT" 2>/dev/null)
  if printf '%s' "$m" | grep -qi "unknown flag: $cf\|unrecognized flag '$cf'\|unknown option '$cf'\|unknown argument '$cf'\|unknown codemod '$cf'\|unknown subcommand '$cf'"; then
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

# ── column 8: verbs the usage block does not mention ─────────────────────────
#
# The verb list above IS the usage block, so a verb missing from it is invisible
# to this census by construction. That blind spot is closed here, from the other
# side: the dispatch arms in the source, compared against what usage prints.
echo "── verbs_missing_from_usage (dispatch arms vs. the usage block) ──"
CLI=$ROOT/compiler/driver/medaka_cli.mdk
if [ -f "$CLI" ]; then
  sed -n 's/^  "\([a-z][a-z-]*\)"::rest =>.*/\1/p' "$CLI" | sort -u > "$WORK/dispatch"
  printf '%s\n' $VERBS | sort -u > "$WORK/advertised"
  miss=$(comm -23 "$WORK/dispatch" "$WORK/advertised" | tr '\n' ' ')
  [ -n "$miss" ] && echo "  DISPATCHED BUT NOT IN USAGE: $miss" || echo "  (none)"
  extra=$(comm -13 "$WORK/dispatch" "$WORK/advertised" | tr '\n' ' ')
  [ -n "$extra" ] && echo "  IN USAGE BUT NOT A DISPATCH ARM: $extra"
else
  echo "  (source not found at $CLI — skipped)"
fi
echo
echo "census complete. This script asserts nothing; see docs/ops/CLI-CONFORMANCE.md"
echo "for which of these cells conform to the ratified conventions."
exit 0
