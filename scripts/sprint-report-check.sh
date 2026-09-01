#!/bin/sh
# sprint-report-check.sh — mechanical section check for a v8 sprint agent report.
# NOT A GATE (ledgered in test/CI-COVERAGE-TOOLS.txt): it grades documents in an
# ephemeral sprint record dir under /var/tmp, never anything in this tree.
#
# Usage: sh scripts/sprint-report-check.sh <report.md> [...]
# Exit 0 = every named report opens with a well-formed Verdict line and carries
# a marked Evidence and Notes section; exit 1 = at least one does not (or does
# not exist).
#
# THE FORMAT IT GRADES is the one and only report format, defined in
# `.claude/skills/sprint-packet/SKILL.md` § "The report": THREE sections —
# Verdict (the first line, one of `LANDED @<sha>` / `REFUSED` / `BLOCKED` /
# `SPIKE-DONE`), Evidence, Notes. There is no `time:` line. Until 2026-09-01
# this script graded the RETIRED v≤7 six-section format
# (Verdict/Evidence/Decisions-surfaced/Deviations/Not-covered/Friction + a
# `time:` line), so every v8-conformant report bounced — a checker that
# rejects everything stops being read, which is the dynamic this script exists
# to prevent. `sprint-packet` is the single source for the shape; if the two
# ever disagree, `sprint-packet` wins and this script is the bug.
#
# Point it at REPORTS ONLY. A packet, a contract, or NOTES.md is not a report
# and will bounce; a sweep that always fires one known-false alarm is how a
# check stops being believed.
#
# PRESENCE ONLY — whether the content is any good is the orchestrator's
# judgment, not this script's. It exists so report intake needs no judgment at
# all: in sprint/ctor-identity 10 of 31 report files were missing at least one
# section and ZERO bounces were issued.
#
# HOW EACH SECTION IS RECOGNISED — this matcher is TIGHTER than the retired
# one, deliberately:
#   * Verdict is positional AND lexical: the FIRST non-blank line must BE the
#     verdict — `LANDED @<sha>` (>=7 hex), `REFUSED`, `BLOCKED`, or
#     `SPIKE-DONE` — optionally behind a `## Verdict` / `**Verdict:**` /
#     column-0 `Verdict:` marker on that same line. A report whose verdict is
#     buried below prose is not machine-readable by the orchestrator, which
#     merges by the SHA on that line.
#   * Evidence and Notes count as present only if MARKED: a heading
#     (`## Evidence`), a bold label (`**Notes**` / `**Notes:**`), or a
#     column-0 `Notes:` line. An earlier draft accepted `^<name>` anywhere at
#     column 0 and was fooled by the prose line "Decisions-surfaced item
#     awaiting ruling." — a false NEGATIVE, i.e. the masking direction of the
#     very check.
# If you loosen this matcher, re-run it over a known-bad corpus and confirm the
# miss count does not drop.
rc=0
for f in "$@"; do
  if [ ! -f "$f" ]; then
    printf '%s: MISSING FILE\n' "$f"
    rc=1
    continue
  fi
  miss=

  # Verdict: positional (first non-blank line) and lexical (one of the four).
  first="$(sed -e '/^[[:space:]]*$/d' -e 'q' "$f")"
  # Strip an optional Verdict marker off that line. Explicit [Vv] classes and
  # BREs only — GNU sed's `I` flag and `\|` alternation are not portable to
  # BSD sed ([B-DUAL-PLATFORM]).
  verdict_body="$(printf '%s' "$first" |
    sed -e 's/^ \{0,3\}//' \
        -e 's/^#\{1,4\} *//' \
        -e 's/^\*\* *[Vv]erdict *:\{0,1\} *\*\*//' \
        -e 's/^[Vv]erdict//' \
        -e 's/^ *: *//' \
        -e 's/^ *//')"
  if ! printf '%s\n' "$verdict_body" |
       grep -qE '^(LANDED @[0-9a-f]{7,40}|REFUSED|BLOCKED|SPIKE-DONE)( .*)?$'; then
    miss="$miss [Verdict]"
  fi

  for s in 'Evidence' 'Notes'; do
    if ! grep -qiE "^ {0,3}(#{1,4} *|\*\*)${s}" "$f" && ! grep -qiE "^${s} *:" "$f"; then
      miss="$miss [$s]"
    fi
  done

  if [ -n "$miss" ]; then
    printf '%s: BOUNCE — missing:%s\n' "$f" "$miss"
    rc=1
  else
    printf '%s: ok\n' "$f"
  fi
done
exit $rc
