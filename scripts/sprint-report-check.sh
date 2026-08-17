#!/bin/sh
# sprint-report-check.sh — mechanical §9 section check for a sprint agent report.
# NOT A GATE (ledgered in test/CI-COVERAGE-TOOLS.txt): it grades documents in an
# ephemeral sprint record dir under /var/tmp, never anything in this tree.
#
# Usage: sh scripts/sprint-report-check.sh <report.md> [...]
# Exit 0 = every named report carries all six sections; exit 1 = at least one
# does not (or does not exist).
#
# PRESENCE ONLY — whether the content is any good is a seat's judgment, not this
# script's. It exists so report intake needs no judgment at all: in
# sprint/ctor-identity 10 of 31 report files were missing at least one section
# and ZERO bounces were issued, because the roles' own definitions licensed a
# role-local body format while claiming "§9 governs".
#
# A section counts as present only if it is MARKED: a heading (`## Verdict`), a
# bold label (`**Verdict**` / `**Verdict:**`), or a column-0 `Verdict:` line. An
# earlier draft accepted `^<name>` anywhere at column 0 and was fooled by the
# prose line "Decisions-surfaced item awaiting ruling." — a false NEGATIVE, i.e.
# the masking direction of the very check. If you loosen this matcher, re-run it
# over a known-bad corpus and confirm the miss count does not drop.
rc=0
for f in "$@"; do
  if [ ! -f "$f" ]; then
    printf '%s: MISSING FILE\n' "$f"
    rc=1
    continue
  fi
  miss=
  for s in 'Verdict' 'Evidence' 'Decisions[ -]surfaced' 'Deviations' 'Not[ -]covered' 'Friction'; do
    if ! grep -qiE "^ {0,3}(#{1,4} *|\*\*)${s}" "$f" && ! grep -qiE "^${s} *:" "$f"; then
      miss="$miss [$(printf '%s' "$s" | sed 's/\[ -\]/ /g')]"
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
