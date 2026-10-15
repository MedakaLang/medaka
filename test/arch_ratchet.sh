#!/bin/sh
# test/arch_ratchet.sh -- architecture growth ratchet (#4200, tracking #4211).
#
# shell-because: compares git revisions of the PR range; a trust anchor that must not depend on the binary under test
#
# Not a standalone gate: test/typecheck_compiler_source.sh calls it, so it runs in
# the required `compiler-soundness` CI job.
#
# Check A. Code lines (neither blank nor `--`-leading) of compiler/types/typecheck.mdk
#   at HEAD may not exceed the count at BASE unless a commit in the range carries
#       Arch-Growth-Override: <reason>
# Check B. Every test/arch_goldens/*.golden at HEAD is compared with BASE. A line
#   `key<TAB>int` is a count (a rise is head > base, a missing key reads as 0); any
#   other line is a list item (a rise is an item present at HEAD and absent at BASE).
#   A golden absent at BASE is an initial pin. Falls are fine. A rise in hooks.golden
#   needs a `Hooks-Field: <reason>` trailer; a rise in any other golden needs
#   `Arch-Pin-Raise: <basename>: <reason>`, one per golden that rose.
#
# Trailers are read from commit messages of the range, never a PR body: a
# merge_group run has no PR body.
#
# BASE/HEAD/RANGE, first rule that applies:
#   1. ARCH_RATCHET_BASE set (test hook / escape hatch): BASE=$ARCH_RATCHET_BASE,
#      HEAD=${ARCH_RATCHET_HEAD:-HEAD}, RANGE=BASE..HEAD.
#   2. GITHUB_EVENT_NAME is pull_request or merge_group: event-payload SHAs
#      (PR_BASE/PR_HEAD, MG_BASE/MG_HEAD). Empty SHAs are a FAIL. A checked-out
#      sprint-branch head is a merge commit, so parents are never used.
#   3. Otherwise merge-base of HEAD and origin/main; no origin/main => SKIP, exit 0.
#
# Usage: sh test/arch_ratchet.sh [repo-root]

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

TC=compiler/types/typecheck.mdk
GOLD=test/arch_goldens
TAB="$(printf '\t')"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/arch_ratchet.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

fail() { echo "arch-ratchet: FAIL: $*" >&2; exit 1; }

# Make commit $1 present, fetching it (and then more history) if needed.
have() { git cat-file -e "$1^{commit}" 2>/dev/null; }
ensure() {
  have "$1" && return 0
  git fetch --no-tags --depth=200 origin "$1" >/dev/null 2>&1 || true
  have "$1"
}

event="${GITHUB_EVENT_NAME:-}"
if [ -n "${ARCH_RATCHET_BASE:-}" ]; then
  BASE="$ARCH_RATCHET_BASE"
  HEAD="${ARCH_RATCHET_HEAD:-HEAD}"
  ensure "$BASE" || fail "base $BASE is not available"
  ensure "$HEAD" || fail "head $HEAD is not available"
elif [ "$event" = pull_request ] || [ "$event" = merge_group ]; then
  if [ "$event" = pull_request ]; then
    pb="${PR_BASE:-}"; HEAD="${PR_HEAD:-}"
  else
    pb="${MG_BASE:-}"; HEAD="${MG_HEAD:-}"
  fi
  [ -n "$pb" ] && [ -n "$HEAD" ] ||
    fail "event $event but its payload SHAs are empty (base='$pb' head='$HEAD'); refusing to pass silently"
  ensure "$pb" || fail "event base $pb is not available after fetch"
  ensure "$HEAD" || fail "event head $HEAD is not available after fetch"
  if [ "$event" = merge_group ]; then
    BASE="$pb"
  else
    BASE="$(git merge-base "$pb" "$HEAD" 2>/dev/null)"
    n=0
    while [ -z "$BASE" ] && [ "$n" -lt 6 ]; do
      git fetch --no-tags --deepen=500 origin "$pb" "$HEAD" >/dev/null 2>&1 || true
      BASE="$(git merge-base "$pb" "$HEAD" 2>/dev/null)"
      n=$((n + 1))
    done
    [ -n "$BASE" ] || fail "no merge-base of $pb and $HEAD after deepening"
  fi
else
  if ! git rev-parse --verify -q origin/main >/dev/null; then
    echo "arch-ratchet: SKIP: no origin/main"
    exit 0
  fi
  HEAD=HEAD
  BASE="$(git merge-base HEAD origin/main)" || fail "no merge-base of HEAD and origin/main"
fi
RANGE="$BASE..$HEAD"

# The range's commit messages must be walkable; a shallow boundary would hide a trailer.
git log --pretty=%H "$RANGE" >/dev/null 2>&1 || fail "cannot walk $RANGE"
git log --pretty=%B "$RANGE" > "$TMP/msgs" 2>/dev/null
echo "arch-ratchet: base $BASE head $HEAD"

status=0

# ── Check A ────────────────────────────────────────────────────────────────
cl() {
  git show "$1:$TC" | awk '!/^[[:space:]]*$/ && !/^[[:space:]]*--/' | wc -l | tr -d ' '
}
cl_base="$(cl "$BASE")"
cl_head="$(cl "$HEAD")"
if [ "$cl_head" -gt "$cl_base" ]; then
  reason="$(grep -E '^Arch-Growth-Override: .+' "$TMP/msgs" | head -1 | sed 's/^Arch-Growth-Override: //')"
  if [ -n "$reason" ]; then
    echo "arch-ratchet: typecheck.mdk +$((cl_head - cl_base)) code lines, override: $reason"
  else
    echo "arch-ratchet: FAIL: typecheck.mdk code lines grew: base $cl_base, head $cl_head (+$((cl_head - cl_base)))." >&2
    echo "  Shrink it, or add a commit-message trailer in this PR:  Arch-Growth-Override: <reason>" >&2
    status=1
  fi
else
  echo "arch-ratchet: typecheck.mdk code lines: $cl_base -> $cl_head"
fi

# ── Check B ────────────────────────────────────────────────────────────────
git ls-tree --name-only "$HEAD" "$GOLD/" 2>/dev/null | grep '\.golden$' > "$TMP/goldens"
while IFS= read -r g; do
  [ -n "$g" ] || continue
  b="$(basename "$g")"
  if ! git cat-file -e "$BASE:$g" 2>/dev/null; then
    echo "arch-ratchet: initial pin: $g"
    continue
  fi
  {
    git show "$BASE:$g" | sed 's/^/B/'
    git show "$HEAD:$g" | sed 's/^/H/'
  } | awk -F"$TAB" '
    function iscount(s) { return s ~ /^[^\t]+\t[0-9]+$/ }
    /^B/ { l = substr($0, 2)
           if (iscount(l)) { split(l, p, "\t"); bc[p[1]] = p[2] + 0 } else bi[l] = 1
           next }
    /^H/ { l = substr($0, 2)
           if (iscount(l)) { split(l, p, "\t"); hc[p[1]] = p[2] + 0 } else hi[l] = 1 }
    END {
      for (k in hc) {
        b = (k in bc) ? bc[k] : 0
        if (hc[k] > b) print "rise\t" k ": " b " -> " hc[k]
        else if (hc[k] < b) print "fall\t" k ": " b " -> " hc[k]
      }
      for (k in bc) if (!(k in hc)) print "fall\t" k ": " bc[k] " -> removed"
      for (l in hi) if (!(l in bi)) print "rise\t" l
      for (l in bi) if (!(l in hi)) print "fall\tremoved: " l
    }' > "$TMP/diff"
  grep "^fall$TAB" "$TMP/diff" | sed "s/^fall$TAB/arch-ratchet: $b fell: /"
  if grep -q "^rise$TAB" "$TMP/diff"; then
    if [ "$b" = hooks.golden ]; then
      reason="$(grep -E '^Hooks-Field: .+' "$TMP/msgs" | head -1 | sed 's/^Hooks-Field: //')"
      need="Hooks-Field: <reason>"
    else
      pat="$(printf '%s' "$b" | sed 's/[][\.*^$/]/\\&/g')"
      reason="$(grep -E "^Arch-Pin-Raise: $pat: .+" "$TMP/msgs" | head -1 | sed 's/^Arch-Pin-Raise: [^:]*: //')"
      need="Arch-Pin-Raise: $b: <reason>"
    fi
    if [ -n "$reason" ]; then
      echo "arch-ratchet: $b rose, trailer reason: $reason"
    else
      echo "arch-ratchet: FAIL: $g rose without a commit-message trailer ($need):" >&2
      grep "^rise$TAB" "$TMP/diff" | sed "s/^rise$TAB/    /" >&2
      status=1
    fi
  else
    echo "arch-ratchet: $b: no rise"
  fi
done < "$TMP/goldens"

exit "$status"
