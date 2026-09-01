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
# THE FORMAT IT GRADES: THREE sections — Verdict, Evidence, Notes — per
# `.claude/skills/sprint-packet/SKILL.md` § "The report" and, for the two
# role agents that write their own verdict token instead of a sprint-packet
# one, `.claude/agents/sprint-reviewer.md` and `.claude/agents/sprint-retro.md`.
# Verdict must be one of: `LANDED @<sha>`, `REFUSED`, `BLOCKED`, `SPIKE-DONE`,
# `REVIEW-DONE: <n> findings (<k> S0/S1)`, or `RETRO: <n> proposals`. There is
# no `time:` line. `sprint-packet` and the two agent role files are the
# sources for the shape; if this script disagrees with any of them, they win
# and this script is the bug (see #2276 for the checker-format incident
# history).
#
# Point it at REPORTS ONLY. A packet, a contract, or NOTES.md is not a report
# and will bounce; a sweep that always fires one known-false alarm is how a
# check stops being believed.
#
# PRESENCE ONLY — whether the content is any good is the orchestrator's
# judgment, not this script's. It exists so report intake needs no judgment at
# all (see #2276 for the corpus that motivated this).
#
# HOW EACH SECTION IS RECOGNISED — this matcher is deliberately tight:
#   * Verdict is positional AND lexical: the FIRST non-blank line must BE one
#     of the accepted verdict forms above, optionally behind a `## Verdict` /
#     `**Verdict:**` / column-0 `Verdict:` marker on that same line. A report
#     whose verdict is buried below prose is not machine-readable by the
#     orchestrator, which merges by the SHA on that line.
#   * Evidence and Notes count as present only if MARKED: a heading
#     (`## Evidence`), a bold label (`**Notes**` / `**Notes:**`), or a
#     column-0 `Notes:` line — a bare `^<name>` match anywhere at column 0 is
#     a known false-negative trap, fooled by prose that merely mentions the
#     section name (see #2276).
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

  # Verdict: positional (first non-blank line) and lexical (one of the six accepted forms).
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
       grep -qE '^(LANDED @[0-9a-f]{7,40}|REFUSED|BLOCKED|SPIKE-DONE|REVIEW-DONE: [0-9]+ findings \([0-9]+ S0/S1\)|RETRO: [0-9]+ proposals)( .*)?$'; then
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
