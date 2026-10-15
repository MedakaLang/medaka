#!/bin/sh
# test/arch_ratchet.sh -- architecture growth ratchet (#4200, tracking #4211).
#
# shell-because: trust-anchor — compares git revisions of the PR range; must not depend on the binary under test
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
# merge_group run has no PR body. A trailer is a column-0 line whose reason is
# non-empty and not the `<reason>` placeholder. The range is trusted only once no
# commit reachable from BASE or HEAD is a shallow boundary (CI checks out at depth 1);
# otherwise the script unshallows, and FAILs if it cannot.
# A golden pinned at BASE and absent at HEAD needs `Arch-Pin-Raise: <basename>: <reason>`.
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

# Make commit $1 present, fetching it if needed.
have() { git cat-file -e "$1^{commit}" 2>/dev/null; }
ensure() {
  have "$1" && return 0
  git fetch --no-tags --depth=1 origin "$1" >/dev/null 2>&1 || true
  have "$1"
}

# Event SHAs come from the environment (test hook) or else the event payload file;
# a step-level env: block would change the gate's derived tier (diff_compiler_tier_drift).
payload_sha() {
  [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -r "$GITHUB_EVENT_PATH" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r "$1 // empty" "$GITHUB_EVENT_PATH" 2>/dev/null
}

# A trailer is a line at column 0: `Key:` + whitespace + a reason that is non-empty and
# does not start with `<` (the placeholder the FAIL messages print).
trailer_reason() { # $1 = key regex (after "^"), $2 = prefix regex to strip
  grep -E "^$1[[:space:]]+[^[:space:]<]" "$TMP/msgs" | head -1 | sed -E "s/^$2[[:space:]]+//"
}

# History completeness. Under a shallow clone a commit's parents can be unknown, so
# `BASE..HEAD` may include old commits (and their trailers) or miss PR commits. The
# range is trusted only when no commit reachable from the tips is a shallow boundary.
shallow_file="$(git rev-parse --git-path shallow)"
complete() { # $@ = tips
  [ -s "$shallow_file" ] || return 0
  git rev-list "$@" > "$TMP/reach" 2>/dev/null || return 1
  ! grep -qxFf "$shallow_file" "$TMP/reach"
}
make_complete() { # $@ = tips
  complete "$@" && return 0
  git fetch --no-tags --unshallow --filter=tree:0 origin "$@" >/dev/null 2>&1 ||
    git fetch --no-tags --unshallow origin "$@" >/dev/null 2>&1 || true
  complete "$@" ||
    fail "history of $* is shallow and could not be completed; refusing to trust a partial range"
}

event="${GITHUB_EVENT_NAME:-}"
if [ -n "${ARCH_RATCHET_BASE:-}" ]; then
  BASE="$ARCH_RATCHET_BASE"
  HEAD="${ARCH_RATCHET_HEAD:-HEAD}"
  ensure "$BASE" || fail "base $BASE is not available"
  ensure "$HEAD" || fail "head $HEAD is not available"
  make_complete "$BASE" "$HEAD"
elif [ "$event" = pull_request ] || [ "$event" = merge_group ]; then
  if [ "$event" = pull_request ]; then
    pb="${PR_BASE:-$(payload_sha .pull_request.base.sha)}"; HEAD="${PR_HEAD:-$(payload_sha .pull_request.head.sha)}"
  else
    pb="${MG_BASE:-$(payload_sha .merge_group.base_sha)}"; HEAD="${MG_HEAD:-$(payload_sha .merge_group.head_sha)}"
  fi
  [ -n "$pb" ] && [ -n "$HEAD" ] ||
    fail "event $event but its payload SHAs are empty (base='$pb' head='$HEAD'); refusing to pass silently"
  ensure "$pb" || fail "event base $pb is not available after fetch"
  ensure "$HEAD" || fail "event head $HEAD is not available after fetch"
  make_complete "$pb" "$HEAD"
  if [ "$event" = merge_group ]; then
    BASE="$pb"
  else
    BASE="$(git merge-base "$pb" "$HEAD" 2>/dev/null)"
    [ -n "$BASE" ] || fail "no merge-base of $pb and $HEAD"
  fi
else
  if ! git rev-parse --verify -q origin/main >/dev/null; then
    echo "arch-ratchet: SKIP: no origin/main"
    exit 0
  fi
  HEAD=HEAD
  make_complete HEAD origin/main
  BASE="$(git merge-base HEAD origin/main)" || fail "no merge-base of HEAD and origin/main"
fi
git merge-base --is-ancestor "$BASE" "$HEAD" 2>/dev/null ||
  fail "base $BASE is not an ancestor of head $HEAD"
RANGE="$BASE..$HEAD"

git log --pretty=%B "$RANGE" > "$TMP/msgs" 2>/dev/null || fail "cannot walk $RANGE"
echo "arch-ratchet: base $BASE head $HEAD"

status=0

# ── Check A ────────────────────────────────────────────────────────────────
git cat-file -e "$BASE:$TC" 2>/dev/null || fail "$TC is missing at base $BASE"
git cat-file -e "$HEAD:$TC" 2>/dev/null || fail "$TC is missing at head $HEAD (moved or deleted?); the ratchet would measure 0"
cl() {
  git show "$1:$TC" | awk '!/^[[:space:]]*$/ && !/^[[:space:]]*--/' | wc -l | tr -d ' '
}
cl_base="$(cl "$BASE")"
cl_head="$(cl "$HEAD")"
if [ "$cl_head" -gt "$cl_base" ]; then
  reason="$(trailer_reason 'Arch-Growth-Override:' 'Arch-Growth-Override:')"
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

pin_reason() { # $1 = golden basename
  pat="$(printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g')"
  trailer_reason "Arch-Pin-Raise:[[:space:]]+$pat:" "Arch-Pin-Raise:[[:space:]]+$pat:"
}

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
      reason="$(trailer_reason 'Hooks-Field:' 'Hooks-Field:')"
      need="Hooks-Field: <reason>"
    else
      reason="$(pin_reason "$b")"
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

# A golden pinned at BASE and gone at HEAD is a change to review, not a fall.
git ls-tree --name-only "$BASE" "$GOLD/" 2>/dev/null | grep '\.golden$' > "$TMP/base_goldens"
while IFS= read -r g; do
  [ -n "$g" ] || continue
  git cat-file -e "$HEAD:$g" 2>/dev/null && continue
  b="$(basename "$g")"
  reason="$(pin_reason "$b")"
  if [ -n "$reason" ]; then
    echo "arch-ratchet: $b removed, trailer reason: $reason"
  else
    echo "arch-ratchet: FAIL: $g is pinned at base and absent at head (deleted or renamed); needs a commit-message trailer (Arch-Pin-Raise: $b: <reason>)" >&2
    status=1
  fi
done < "$TMP/base_goldens"

exit "$status"
