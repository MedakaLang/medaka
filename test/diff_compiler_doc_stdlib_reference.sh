#!/bin/sh
# Freshness gate for the generated stdlib reference tree (docs/stdlib/*.md +
# index.md + inventory.json, S-reference-lands / #2249).
#
# There is no oracle to diff against here — the "correct" output IS "what
# `./medaka doc` just produced" (byte-identity is the only property under
# test), same shape as the `docs-index` / `gen-ci` Makefile targets
# (Makefile:151-172): regenerate into a scratch dir, diff against the
# committed tree, fail on any difference.
#
# The committed docs/stdlib/ directory also holds HAND-WRITTEN design docs
# that `medaka doc` does not produce and never touches (STDLIB.md,
# FP-STDLIB-DESIGN.md, P1-STDLIB-DESIGN.md, ...) — this gate only compares
# the files the generator itself just wrote, one-for-one against the
# committed file of the same name. It does not enumerate the committed
# directory looking for extras; a hand-written doc living alongside the
# generated ones is not this gate's concern.
#
# Usage:  sh test/diff_compiler_doc_stdlib_reference.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
COMMITTED="$ROOT/docs/stdlib"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cd "$ROOT" || exit 1
"$MEDAKA" doc --out "$TMPDIR" stdlib/*.mdk >/dev/null 2>&1
status=$?
if [ "$status" -ne 0 ]; then
  printf 'FAIL generator exited %d ("%s" doc --out %s stdlib/*.mdk) — refusing to check a partial/crashed run\n' "$status" "$MEDAKA" "$TMPDIR"
  exit 1
fi

# Expected file set, derived INDEPENDENTLY of whatever the generator actually
# wrote: one .md per stdlib/*.mdk module, plus index.md and inventory.json.
# Iterating this list (rather than "whatever landed in $TMPDIR") is what
# catches a partial run — a generator that writes 2 of 31 files and exits 0
# would otherwise report "2 ok, 0 failing".
expected="$TMPDIR/.expected"
: > "$expected"
for f in "$ROOT"/stdlib/*.mdk; do
  name="$(basename "$f" .mdk)"
  printf '%s.md\n' "$name" >> "$expected"
done
printf 'index.md\ninventory.json\n' >> "$expected"

pass=0
fail=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ ! -f "$TMPDIR/$name" ]; then
    fail=$((fail + 1))
    printf 'FAIL %s (expected but generator did not produce it — partial/crashed run)\n' "$name"
    continue
  fi
  if [ ! -f "$COMMITTED/$name" ]; then
    fail=$((fail + 1))
    printf 'FAIL %s (freshly generated, but docs/stdlib/%s is not committed)\n' "$name" "$name"
    continue
  fi
  if diff -q "$TMPDIR/$name" "$COMMITTED/$name" >/dev/null 2>&1; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s (committed docs/stdlib/%s differs from a fresh regen — run: ./medaka doc --out docs/stdlib stdlib/*.mdk)\n' "$name" "$name"
  fi
done < "$expected"

# ── name visibility ─────────────────────────────────────────────────────────
# Every bare backticked identifier in a page's rendered PROSE must name
# something visible on that page: an entry heading, a token of a rendered
# signature block (the type line, or the head line `take n _` naming the
# parameters the defining clauses bind), a prelude name (a `core`/`runtime`
# entry, constructor, interface method or type — those pages are in scope
# everywhere), a language keyword or builtin type, a stdlib module name, a
# module-qualified name (`string.split`), a field or member of a name that is
# visible on the page (`Args.given`), or a row of
# test/STDLIB-DOC-NAME-EXCEPTIONS.txt. A name that resolves only in the
# SOURCE — a parameter the head does not show, a local, a private helper, an
# abstract type's constructor — is exactly the reader-facing rot this checks
# for: the prose names it, the page never shows it. Expression spans
# (`arr[i]`, `O(n)`) and fenced examples are not checked, nor is a span with
# no lowercase letter (`PATH`, `N`): those are placeholders and environment
# names, not identifier claims.
EXC="$ROOT/test/STDLIB-DOC-NAME-EXCEPTIONS.txt"
KEYWORDS='match if then else let in data type impl interface import export public deriving where do defer extern prop test newtype True False not otherwise main'
BUILTINS='Int Float String Bool Char Unit List Array Ref Option Result Effect Type'
MODULES="$(for f in "$ROOT"/stdlib/*.mdk; do basename "$f" .mdk; done | tr '\n' ' ')"
if [ ! -f "$TMPDIR/core.md" ] || [ ! -f "$TMPDIR/runtime.md" ]; then
  fail=$((fail + 1))
  printf 'FAIL name visibility (no core.md/runtime.md to derive the prelude set from)\n'
else
  while IFS= read -r name; do
    case "$name" in *.md) ;; *) continue ;; esac
    case "$name" in index.md) continue ;; esac
    [ -f "$TMPDIR/$name" ] || continue
    mod="${name%.md}"
    if awk -v MOD="$mod" -v EXC="$EXC" -v KW="$KEYWORDS $BUILTINS $MODULES" '
      BEGIN {
        n = split(KW, w, " "); for (i = 1; i <= n; i++) allow[w[i]] = 1
        while ((getline l < EXC) > 0) {
          if (l ~ /^#/ || l == "") continue
          split(l, f, "\t"); if (f[1] == MOD) exc[f[2]] = 1
        }
      }
      FNR == 1 { idx++; infence = 0; lang = ""; entry = "(module)" }
      /^```/ { if (infence) infence = 0; else { infence = 1; lang = substr($0, 4) }; next }
      infence {
        if (lang != "" || idx == 4) next
        n = split($0, w, /[^A-Za-z0-9_\047]+/)
        if (idx == 3) { for (i = 1; i <= n; i++) if (w[i] != "") vis[w[i]] = 1 }
        else {
          for (i = 1; i <= n; i++) if (w[i] ~ /^[A-Z]/) allow[w[i]] = 1
          if ($0 ~ /^  [a-z][A-Za-z0-9_\047]* : /) allow[$1] = 1
        }
        next
      }
      /^##+ `/ {
        s = $0; sub(/^##+ `/, "", s); sub(/`.*$/, "", s); split(s, hw, " ")
        if (idx <= 2) allow[hw[1]] = 1; else if (idx == 3) vis[hw[1]] = 1; else entry = s
        next
      }
      /^#/ { next }
      idx == 4 {
        line = $0
        while (match(line, /`[^`]+`/)) {
          sp = substr(line, RSTART + 1, RLENGTH - 2); line = substr(line, RSTART + RLENGTH)
          if (sp ~ /^[A-Za-z_][A-Za-z0-9_\047]*$/ && sp ~ /[a-z]/) {
            if (!(sp in vis) && !(sp in allow) && !(sp in exc)) {
              printf "FAIL %s.md: `%s` under `%s` names nothing visible on the page\n", MOD, sp, entry; bad++
            }
          } else if (sp ~ /^[A-Za-z_][A-Za-z0-9_\047]*(\.[A-Za-z_][A-Za-z0-9_\047]*)+$/) {
            m = sp; sub(/\..*/, "", m)
            if (!(m in allow) && !(m in vis) && !(sp in exc)) {
              printf "FAIL %s.md: `%s` under `%s` qualifies with `%s`, which is neither a stdlib module nor visible on the page\n", MOD, sp, entry, m; bad++
            }
          }
        }
      }
      END { exit (bad > 0) }
    ' "$TMPDIR/core.md" "$TMPDIR/runtime.md" "$TMPDIR/$name" "$TMPDIR/$name"; then
      pass=$((pass + 1))
      printf 'ok   %s (every backticked name is visible on the page)\n' "$name"
    else
      fail=$((fail + 1))
    fi
  done < "$expected"
fi

# 0-checked must fail: a gate that iterated no output proves nothing.
if [ "$((pass + fail))" -eq 0 ]; then
  printf '\nNO GENERATED FILES PRODUCED by "%s doc --out %s stdlib/*.mdk" — 0 checked, refusing to pass\n' "$MEDAKA" "$TMPDIR"
  exit 1
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
