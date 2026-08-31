#!/bin/sh
# cli_conformance_lib.sh — SHELL LIBRARY, not a script. Sourced, never executed.
#
# The ONE implementation of "ask the built ./medaka what its own CLI surface is".
# Two consumers today:
#
#   * test/cli_conformance_census.sh   — the MAP. Prints every derived column,
#                                        asserts nothing, always exits 0.
#   * test/diff_compiler_cli_help_conformance.sh
#                                      — the GATE. Asserts the three agreement
#                                        properties and exits non-zero on drift.
#
# WHY A LIBRARY AND NOT A SECOND COPY. The census already derived the hard half
# (which flags a verb advertises, which it parses, how to reach a sub-taking
# verb's arms). A gate that re-derived the same facts its own way would be a
# SECOND, possibly-wrong answer to a question the binary answers exactly — the
# multi-consumer drift the cli-one-program sprint exists to remove, committed
# inside the sprint that removes it. Same shape as test/perf_shapes.sh (#2066),
# where two gates kept hand-copied generators until they diverged.
#
# ── EVERYTHING IS DERIVED. NOTHING IS ENCODED. ───────────────────────────────
#
# No roster of verbs, flags, or subcommands appears anywhere in this file. Every
# list comes back out of the binary:
#
#   verbs        ← `medaka help`'s own usage block
#   advertised   ← `medaka <verb> --help`, the `--`-token at the start of an
#                  indented line (mid-sentence `--flag` is prose, not a flag)
#   parsed       ← RUNNING the verb with the flag and classifying the result
#   known roster ← the `(known: …)` list the verb's OWN unknown-flag rejection
#                  prints (`assertCliFlags`, compiler/driver/medaka_cli.mdk) —
#                  the binary stating its parse arms in its own words
#   subcommands  ← the sub-taking verb's own `(expected: …)` rejection wording
#
# Callers must set MEDAKA (path to the binary) before sourcing, or accept the
# $ROOT/medaka default, and must call `cli_lib_init` once.

# ── init ─────────────────────────────────────────────────────────────────────
#
# Sets CLI_WORK (scratch dir with ok.mdk / bad.mdk / empty/), CLI_OUT, CLI_ERR.
# `MEDAKA_STRICT=1` on every probe so a stale binary fails loudly rather than
# answering ([B-STALENESS]/[B-STDERR]): a census — or a gate — read off a stale
# binary describes last week's CLI.
cli_lib_init() {
  CLI_WORK=$(mktemp -d "${TMPDIR:-/tmp}/cli-conf.XXXXXX") || return 1
  CLI_OUT=$CLI_WORK/o
  CLI_ERR=$CLI_WORK/e
  printf 'main = println 1\n' > "$CLI_WORK/ok.mdk"
  printf 'main = println (1 + True)\n' > "$CLI_WORK/bad.mdk"
  mkdir -p "$CLI_WORK/empty"
  export MEDAKA_STRICT=1
}

cli_lib_cleanup() { [ -n "${CLI_WORK:-}" ] && rm -rf "$CLI_WORK"; }

# ── cli_probe <argv...> ──────────────────────────────────────────────────────
#
# Runs the binary and leaves stdout in $CLI_OUT, stderr in $CLI_ERR, exit code
# in $CLI_RC. stdin is /dev/null so the three stdio servers (repl/lsp/mcp)
# terminate instead of blocking forever.
cli_probe() {
  ( cd "$CLI_WORK" && "$MEDAKA" "$@" >"$CLI_OUT" 2>"$CLI_ERR" </dev/null )
  CLI_RC=$?
}

# Where did this invocation speak? stdout / stderr / both / silent.
cli_stream_of() {
  _o=0; _e=0
  [ -s "$CLI_OUT" ] && _o=1
  [ -s "$CLI_ERR" ] && _e=1
  case "$_o$_e" in
    00) echo "silent" ;;
    10) echo "stdout" ;;
    01) echo "stderr" ;;
    *)  echo "both" ;;
  esac
}

cli_msg() { cat "$CLI_ERR" "$CLI_OUT" 2>/dev/null; }
cli_first_line() { cli_msg | head -n 1 | cut -c1-96; }

# ── cli_verbs ────────────────────────────────────────────────────────────────
#
# The verb list, from the binary's own usage block. A verb dispatched but never
# given a usage line is INVISIBLE here by construction — which is itself a
# finding, and one the census reports from the other side (verbs_missing_from_usage).
cli_verbs() {
  "$MEDAKA" help >"$CLI_WORK/usage" 2>/dev/null
  sed -n 's/^  medaka \([a-z][a-z-]*\).*/\1/p' "$CLI_WORK/usage" | sort -u | tr '\n' ' '
}

# ── cli_subs_of <verb> ───────────────────────────────────────────────────────
#
# A verb whose first positional is a required SUB-NAME (`medaka gate list`,
# `medaka codemod effect-labels`) rejects a leading flag as a bad sub-name, not
# as a bad flag. Detected from the verb's OWN rejection wording; the sub-names
# come out of that same message's `(expected: a, b, …)` list, or off the
# `Available …:` block its no-argument usage prints. Echoes the sentinel
# `@none` for a flat verb, so callers keep one loop shape for both.
cli_subs_of() {
  cli_probe "$1" --zzz-not-a-flag ok.mdk
  _submsg=$(cli_msg)
  _subs=""
  case "$_submsg" in
    *"unknown subcommand"*|*"unknown codemod"*)
      _subs=$(printf '%s' "$_submsg" \
              | sed -n 's/.*(expected: \([a-z, -]*\)).*/\1/p' | tr -d ',' | head -n 1)
      if [ -z "$_subs" ]; then
        cli_probe "$1"
        _subs=$(sed -n 's/^  \([a-z][a-z0-9-]*\) *—.*/\1/p' "$CLI_OUT" "$CLI_ERR" 2>/dev/null | tr '\n' ' ')
      fi
      ;;
  esac
  [ -n "$_subs" ] || _subs=@none
  echo "$_subs"
}

# ── cli_help_flags_of <verb> ─────────────────────────────────────────────────
#
# Every `--`-shaped token this verb's own `--help` ADVERTISES. Only tokens at
# the start of an indented help line count: a `--flag` appearing mid-sentence is
# a metavariable, not a flag ("Any other --flag consumes the next token as its
# value"). `--help` itself is dropped — it is intercepted centrally by
# `dispatchSub`, not by any verb's parse arms.
cli_help_flags_of() {
  cli_probe "$1" --help
  sed -n 's/^[[:space:]]*\(--[a-z][a-z-]*\).*/\1/p' "$CLI_OUT" | sort -u | grep -v '^--help$'
}

# ── cli_help_text_of <verb> ──────────────────────────────────────────────────
cli_help_text_of() { cli_probe "$1" --help; cat "$CLI_OUT"; }

# ── cli_known_flags_of <verb> ────────────────────────────────────────────────
#
# The roster the verb states IN ITS OWN WORDS: `assertCliFlags` renders
# `(known: --a, --b, --c)` in every unknown-flag rejection. This is the binary's
# statement of its parse arms — the only non-source-grep answer to "which flags
# does this verb actually have", and the direction the execution probes cannot
# reach (running a flag can show one EXISTS; nothing you can run enumerates the
# ones you did not think to try).
#
# Bound, stated rather than hidden: a verb with no `assertCliFlags` call prints
# no roster and yields the empty string — cli_known_flags_of cannot distinguish
# "no flags" from "no roster", so callers that need that distinction must treat
# an empty result as UNCOVERED, not as "zero flags". `(known: none)` — the
# rendering for a genuinely flagless verb — yields empty too, and correctly so:
# there is nothing to check.
#
# The list is cut at the first `;`, because a roster may be followed by prose
# inside the same parentheses (`gate reach` appends "; use `--` before a path
# starting with '-'"), and then filtered to `--`-shaped tokens. Both are shape
# rules, not a list of which verbs do it.
cli_known_flags_of() {
  _kf_verb=$1
  _kf_all=""
  for _kf_s in $(cli_subs_of "$_kf_verb"); do
    if [ "$_kf_s" = @none ]; then
      cli_probe "$_kf_verb" --zzz-not-a-flag ok.mdk
    else
      cli_probe "$_kf_verb" "$_kf_s" --zzz-not-a-flag ok.mdk
    fi
    _kf_line=$(cli_msg | sed -n 's/.*(known: \([^)]*\)).*/\1/p' | head -n 1)
    _kf_line=${_kf_line%%;*}
    _kf_all="$_kf_all $(printf '%s' "$_kf_line" | tr -d ',')"
  done
  printf '%s\n' $_kf_all | grep '^--[a-z]' | sort -u
}

# ── cli_flag_verdict <verb> <flag> ───────────────────────────────────────────
#
# Echoes PARSED / VALUE-REJECTED / NOT-PARSED and leaves the deciding message in
# $CLI_EVIDENCE.
#
# ⚠️ THE BOUND, STATED RATHER THAN HIDDEN. This answers "is this flag rejected as
# unknown", not "is this flag honoured". A value-taking flag is given the dummy
# value `Z` (a bare `--flag` with no value can fail for the missing value rather
# than for the flag), so a flag that validates its value shows up as
# VALUE-REJECTED — real evidence the arm EXISTS, not a defect. An
# accepted-but-ignored flag (`gate run --jobs`, documented as such in its own
# help) reads as PARSED, because from outside the process it is.
#
# A multi-subcommand verb's help is the UNION over its subcommands, so a flag is
# PARSED if ANY subcommand takes it — every sub is probed rather than reporting
# `gate run --jobs` as missing because `gate list` refuses it.
cli_flag_verdict() {
  _fv_verb=$1; _fv_flag=$2
  _fv_verdict=NOT-PARSED
  CLI_EVIDENCE=""
  for _fv_s in $(cli_subs_of "$_fv_verb"); do
    if [ "$_fv_s" = @none ]; then
      cli_probe "$_fv_verb" "$_fv_flag" Z ok.mdk
    else
      cli_probe "$_fv_verb" "$_fv_s" "$_fv_flag" Z ok.mdk
    fi
    _fv_msg=$(cli_msg)
    CLI_EVIDENCE=$(printf '%s' "$_fv_msg" | head -n 1 | cut -c1-70)
    if cli_rejects_as_unknown "$_fv_msg" "$_fv_flag"; then
      continue
    elif printf '%s' "$_fv_msg" | grep -q -- "$_fv_flag"; then
      _fv_verdict=VALUE-REJECTED; break
    else
      _fv_verdict=PARSED; break
    fi
  done
  echo "$_fv_verdict"
}

# Did this message reject <flag> as an unrecognized token (as opposed to
# accepting it, or failing for some other reason)? One place, because the
# rejection wordings are a set that grows and must not be half-updated in two
# consumers.
cli_rejects_as_unknown() {
  printf '%s' "$1" | grep -qi \
    "unknown flag: $2\|unrecognized flag '$2'\|unknown option '$2'\|unknown argument '$2'\|unknown codemod '$2'\|unknown subcommand '$2'"
}

# ── cli_crossref_pairs ───────────────────────────────────────────────────────
#
# Every `medaka <verb> --flag` phrase appearing in ANY help text, as
# `<verb> <flag>` lines. The per-verb agreement check only ever probes a flag
# against the verb whose help names it, so it is blind to the other way a help
# text lies: naming ANOTHER verb's flag in passing.
cli_crossref_pairs() {
  {
    cat "$CLI_WORK/usage" 2>/dev/null
    for _cr_v in $1; do cli_probe "$_cr_v" --help; cat "$CLI_OUT"; done
  } > "$CLI_WORK/allhelp" 2>/dev/null
  sed -n 's/.*medaka \([a-z][a-z-]*\) \(--[a-z][a-z-]*\).*/\1 \2/p' "$CLI_WORK/allhelp" | sort -u
}
