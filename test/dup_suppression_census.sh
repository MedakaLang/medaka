#!/bin/sh
# test/dup_suppression_census.sh — what `rule-duplicate-body`'s zero is hiding,
# run via `make dup-census`. It is not a gate: it asserts nothing and always
# exits 0.
#
# WHY THIS EXISTS (#2861). `medaka lint --only=rule-duplicate-body compiler
# stdlib sqlite` prints nothing and exits 0. That zero is not a measurement of
# the tree -- it is the sum of every inline suppression in it. A detector whose
# zero means "nobody looked" is a census wearing a rule's clothes, which is the
# shape the slop-burndown crusade (#2276) exists to close. So the number that
# actually describes the tree is published here instead: how many suppressions
# there are, how many findings they hide, and how many of them state the
# constraint that forced them.
#
# HOW THE HIDDEN COUNT IS DERIVED. The only honest way to ask "what would the
# rule say if nobody had silenced it" is to ask the rule. This script copies
# the lint roots into a scratch directory, deletes every rule-duplicate-body
# directive line from the copy, and runs the SAME built ./medaka over the copy.
# It never writes to the working tree. The copy is what makes the number real
# rather than an estimate off the directive count: a `-- lint-disable-file`
# directive hides an unbounded number of findings, so directives and findings
# are different quantities and this script reports both.
#
# WHY IT IS NOT A GATE. The hidden count is a debt ledger. Asserting on it
# would pin a number nobody has agreed is right and would red on every honest
# consolidation that moves it. Enforcement against NEW duplicates lives in
# test/diff_compiler_lint_baseline.sh (assertion 3) and .githooks/pre-commit
# (check 3); both are max ratchets, and neither is weakened by anything here.
#
# THE RATIONALE COLUMN. A surviving suppression must state the constraint that
# forced it -- an issue number is not a reason (#1214's corollary). This script
# reports how many do, by looking for reason vocabulary in the comment context
# leading into each directive. That test is a HEURISTIC and is labelled as one:
# it can call a directive reasoned because an unrelated comment nearby used the
# word "parallel". It is a report, not the detector; the detector is #2862.
#
# Needs a built ./medaka (it runs the real rule). Portable POSIX sh.
#
# Usage:  sh test/dup_suppression_census.sh
# Output: what the rule reports per root (marking any root outside the hook's
#         LINT_ROOTS as unenforced), per-file directive counts, the count the
#         directives hide, and the reasoned/bare split with the bare sites
#         named. Always exits 0.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 0

MEDAKA="$ROOT/medaka"
RULE="rule-duplicate-body"
# The enforced roots are read out of the hook rather than retyped, the same way
# test/diff_compiler_lint_baseline.sh reads them: two consumers of one list
# cannot drift apart if only one of them holds it.
HOOK="$ROOT/.githooks/pre-commit"
ENFORCED="$(sed -n 's/^LINT_ROOTS="\(.*\)"$/\1/p' "$HOOK")"
# `pds` carries directives and findings of its own but is NOT in LINT_ROOTS, so
# nothing enforces the rule there. Censusing it anyway is the point: a root the
# enforcement does not reach is exactly the kind of zero this file exists to
# stop anyone reading as cleanliness.
EXTRA="pds"

present=""
for r in $ENFORCED $EXTRA; do
  [ -d "$ROOT/$r" ] && present="$present $r"
done

echo "== rule-duplicate-body suppression census (#2861) =="
echo "roots censused:$present"
echo "roots ENFORCED (.githooks/pre-commit LINT_ROOTS): $ENFORCED"
echo ""

# ── 1. what the rule reports as the tree stands ──────────────────────────────
# Per root, so "reported" and "hidden" below can never be read as one pool:
# a root outside LINT_ROOTS can report a nonzero count forever without any
# gate noticing, which is a different defect from a suppressed zero.
if [ -x "$MEDAKA" ]; then
  echo "-- reported by the rule as the tree stands, per root --"
  reported=0
  for r in $present; do
    n="$("$MEDAKA" lint --only="$RULE" "$r" 2>/dev/null | grep -c "\[$RULE\]")"
    gated="enforced"
    case " $ENFORCED " in
      *" $r "*) ;;
      *) gated="NOT ENFORCED" ;;
    esac
    echo "    $r: $n ($gated)"
    reported=$((reported + n))
  done
  echo "    total: $reported"
else
  reported=0
  echo "reported by the rule as the tree stands: SKIPPED (no built ./medaka)"
fi

# ── 2. the suppressions ──────────────────────────────────────────────────────
sites="$(grep -rn "lint-disable.*$RULE" $present --include='*.mdk' 2>/dev/null)"
n_sites="$(printf '%s\n' "$sites" | grep -c . )"
n_file_scope="$(printf '%s\n' "$sites" | grep -c 'lint-disable-file' )"
echo "suppression directives: $n_sites ($n_file_scope of them file-scoped)"
echo ""
echo "-- directives per file --"
printf '%s\n' "$sites" | grep . | cut -d: -f1 | sort | uniq -c | sort -rn

# ── 3. what they hide ────────────────────────────────────────────────────────
echo ""
if [ ! -x "$MEDAKA" ]; then
  echo "hidden findings: SKIPPED (no built ./medaka at $MEDAKA -- run 'make medaka')"
else
  scratch="$(mktemp -d)"
  for r in $present; do
    # `cp -R <dir> <dest>/` keeps the root's own name, so paths in the scratch
    # copy read the same as paths in the tree and the output is comparable.
    cp -R "$ROOT/$r" "$scratch/" 2>/dev/null
  done
  # Delete the directive LINES, nothing else: the census must change what the
  # rule is allowed to say, never what the code says.
  grep -rl "lint-disable.*$RULE" "$scratch" 2>/dev/null | while read -r f; do
    sed -i.bak "/lint-disable.*$RULE/d" "$f" 2>/dev/null || \
      { sed "/lint-disable.*$RULE/d" "$f" > "$f.new" && mv "$f.new" "$f"; }
    rm -f "$f.bak"
  done
  copied=""
  for r in $present; do
    [ -d "$scratch/$r" ] && copied="$copied $r"
  done
  # shellcheck disable=SC2086
  hidden="$(cd "$scratch" && "$MEDAKA" lint --only="$RULE" $copied 2>/dev/null | grep "\[$RULE\]")"
  n_total="$(printf '%s\n' "$hidden" | grep -c . )"
  n_hidden=$((n_total - reported))
  echo "with every directive stripped (same binary, scratch copy): $n_total"
  echo "  of which already reported above:                         $reported"
  echo "  HIDDEN BY SUPPRESSION -- the number this census exists for: $n_hidden"
  echo ""
  echo "-- findings per file, directives stripped --"
  printf '%s\n' "$hidden" | grep . | sed 's/^warning: //' | cut -d: -f1 | sort | uniq -c | sort -rn
  rm -rf "$scratch"
fi

# ── 4. the rationale split ───────────────────────────────────────────────────
# HEURISTIC, per this file's header: a directive counts as reasoned when the
# comment context above it uses reason vocabulary. Over-reports, never under.
echo ""
tmp_bare="$(mktemp)"
printf '%s\n' "$sites" | grep . | while IFS=: read -r f ln _; do
  a=$((ln - 10))
  [ "$a" -lt 1 ] && a=1
  ctx="$(sed -n "${a},$((ln - 1))p" "$f")"
  case "$ctx" in
    *[Dd]uplicat*|*consolidat*|*[Ii]ntentional*|*[Dd]eliberat*|*identical*|*[Mm]irror*|*predicate*|*copy*|*[Pp]arallel*|*"abstract over"*|*reimplement*|*"shared module"*)
      : ;;
    *) echo "$f:$ln" >> "$tmp_bare" ;;
  esac
done
# `grep -c` exits 1 on no matches, so an `|| echo 0` fallback would APPEND a
# second line to the count and make the arithmetic below fail on the literal
# two-line string. Count with wc instead, which exits 0 on an empty file.
n_bare="$(wc -l < "$tmp_bare" | tr -d ' ')"
[ -n "$n_bare" ] || n_bare=0
n_reasoned=$((n_sites - n_bare))
echo "rationale (heuristic): $n_reasoned state a constraint, $n_bare do not"
if [ "$n_bare" -gt 0 ]; then
  echo ""
  echo "-- directives with no stated constraint --"
  sed 's/^/    /' "$tmp_bare"
fi
rm -f "$tmp_bare"

echo ""
echo "(report only -- exits 0 by design. Enforcement against NEW duplicates:"
echo " test/diff_compiler_lint_baseline.sh assertion 3, .githooks/pre-commit check 3.)"
exit 0
