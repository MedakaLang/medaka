#!/bin/sh
# Differential gate for `medaka doc` (compiler/tools/doc.mdk via the native CLI).
#
# `medaka doc` was ported to the native CLI in 96b62efb ("feat(cli): port `medaka
# doc` to the native CLI (single-file)") but shipped with ZERO regression
# coverage — test/doc_fixtures/ (14 real .mdk fixtures) had no consumer at all
# (see test/FIXTURE-CORPUS-EXCEPTIONS.txt). This gate closes that hole.
#
# Drives the real `./medaka doc <fixture>` CLI (not an entry probe — `doc` has
# no standalone test/bin/* oracle) against a committed golden per fixture:
# test/doc_goldens/<name>.doc.golden. `medaka doc` output is deterministic (the
# `# <title>` header comes from the fixture's basename, not its path — verified
# identical when invoked from a different cwd/absolute path) and embeds no
# timestamp, so a plain literal compare is sound.
#
# Usage:  sh test/diff_compiler_doc.sh
#         CAPTURE=1 sh test/diff_compiler_doc.sh   # (re)capture goldens via the
#                                                   # EXACT same invocation the
#                                                   # gate reads with — single
#                                                   # source of truth, goldens
#                                                   # can never drift from the
#                                                   # read path.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# $MEDAKA honoured for local runs against a borrowed/pre-built binary; CI (which
# builds ./medaka before running gates) falls back to $ROOT/medaka.
MEDAKA="${MEDAKA:-$ROOT/medaka}"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
FIXDIR="$ROOT/test/doc_fixtures"
GOLDENDIR="$ROOT/test/doc_goldens"
# S-doc-library-mode: `medaka doc --out DIR <files...>` arm. Small fixture
# library (an `async`-named probe to prove the exclusion rule is name-keyed, not
# path-keyed; plus S-doc-surface-truth's `gamma`/`array` pair for the impl
# rebucketing rule) under its own subdir/golden dir so the single-file loop
# above (`$FIXDIR/*.mdk`, non-recursive) never touches it.
#
# S-doc-surface-truth also adds four single-file fixtures to $FIXDIR, picked up
# by the glob above with no edit here: reexport_entry/reexport_helper (hole (a),
# `export import m.{...}`), runtime.mdk (hole (c), the prelude-only extern
# exception, name-keyed) and bare_extern.mdk (its negative control).
LIBFIXDIR="$FIXDIR/library"
LIBGOLDENDIR="$GOLDENDIR/library"
LIBTMPDIR="$(mktemp -d)"
# Separate scratch for the duplicate-basename probe (S2-4): it must not live
# under $LIBTMPDIR, which is compared wholesale against the golden tree.
DUPTMPDIR="$(mktemp -d)"
trap 'rm -rf "$LIBTMPDIR" "$DUPTMPDIR"' EXIT

if [ "${CAPTURE:-0}" = "1" ]; then
  mkdir -p "$GOLDENDIR"
  n=0
  for f in "$FIXDIR"/*.mdk; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    name="$(basename "$f" .mdk)"
    "$MEDAKA" doc "$f" > "$GOLDENDIR/$name.doc.golden" 2>/dev/null
    printf 'captured %s\n' "$name"
  done
  printf '\ngoldens captured for %d fixtures in %s\n' "$n" "$GOLDENDIR"
  [ "$n" -gt 0 ] || { echo "NO FIXTURES FOUND under $FIXDIR — refusing to report a pass on zero input"; exit 1; }

  rm -rf "$LIBGOLDENDIR"
  mkdir -p "$LIBGOLDENDIR"
  "$MEDAKA" doc --out "$LIBGOLDENDIR" "$LIBFIXDIR"/*.mdk >/dev/null 2>/dev/null
  printf 'captured library-mode golden tree in %s\n' "$LIBGOLDENDIR"
  exit 0
fi

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .mdk)"
  golden="$GOLDENDIR/$name.doc.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail + 1))
    printf 'FAIL %s (no golden — run CAPTURE=1 sh test/diff_compiler_doc.sh)\n' "$name"
    continue
  fi
  expected="$(cat "$golden")"
  actual="$("$MEDAKA" doc "$f" 2>/dev/null)"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s (medaka doc output differs from golden)\n' "$name"
  fi
done

# ── library-mode arm ────────────────────────────────────────────────────────
if [ -d "$LIBGOLDENDIR" ]; then
  "$MEDAKA" doc --out "$LIBTMPDIR" "$LIBFIXDIR"/*.mdk >/dev/null 2>/dev/null
  # `async.mdk` (the exclusion probe) must produce no page. Checked together
  # with proof the run actually produced its OTHER expected pages — bare
  # absence of async.md is also satisfied by a total generator failure
  # (nothing generated = async.md also absent = vacuous "pass").
  if [ -f "$LIBTMPDIR/async.md" ]; then
    fail=$((fail + 1))
    printf 'FAIL library-mode (async-probe module was NOT excluded — async.md exists)\n'
  elif [ -f "$LIBTMPDIR/alpha.md" ] && [ -f "$LIBTMPDIR/beta.md" ] && [ -f "$LIBTMPDIR/gamma.md" ]; then
    pass=$((pass + 1))
    printf 'ok   library-mode async-exclusion\n'
  else
    fail=$((fail + 1))
    printf 'FAIL library-mode async-exclusion (generator produced no other pages — vacuous absence, not a real exclusion)\n'
  fi
  # S-doc-surface-truth hole (b): `rebucketLibraryImpls` files an impl under the
  # page of the type it is ON, not the module that declared it. gamma.mdk writes
  # `impl Sizeish (Array Int)`; `Array` is an opaque builtin with no declaring
  # module, so the page named for it owns the entry. Asserted DIRECTLY (not only
  # via the golden tree) so a rebucketing regression cannot be blessed away.
  # Matched on the ENTRY HEADER line, not anywhere in the page — both fixtures'
  # own header prose names the impl, so a bare substring grep is satisfied by
  # documentation about the rule rather than by the rule holding. A documented
  # impl renders as a `###` entry inside the page's closing Instances section.
  if grep -q '^##* .Sizeish (Array Int).$' "$LIBTMPDIR/array.md" 2>/dev/null \
    && ! grep -q '^##* .Sizeish (Array Int).$' "$LIBTMPDIR/gamma.md" 2>/dev/null; then
    pass=$((pass + 1))
    printf 'ok   library-mode impl rebucketing (Sizeish (Array Int) -> array.md)\n'
  else
    fail=$((fail + 1))
    printf 'FAIL library-mode impl rebucketing (Sizeish (Array Int) is not filed on array.md)\n'
  fi
  # ... and the declaring module still keeps an impl on a type it DECLARES.
  if grep -q '^##* .Sizeish Widget.$' "$LIBTMPDIR/gamma.md" 2>/dev/null; then
    pass=$((pass + 1))
    printf 'ok   library-mode impl rebucketing (Sizeish Widget stays on gamma.md)\n'
  else
    fail=$((fail + 1))
    printf 'FAIL library-mode impl rebucketing (Sizeish Widget left gamma.md)\n'
  fi
  # S2-1: ownership clause 1 must see a PRIVATE `data` declaration. owner.mdk
  # declares `Gadget` without exporting it (so it renders NO doc entry) and
  # writes `impl Countish Gadget`; gadget.mdk exists under the matching name
  # but says nothing about the type. Pre-fix, the owner map was built from
  # rendered entries, missed the private declaration, and filed the impl on
  # gadget.md. Both halves asserted: it IS on owner.md and is NOT on gadget.md
  # — a one-sided check passes if the entry vanishes entirely.
  if grep -q '^##* .Countish Gadget.$' "$LIBTMPDIR/owner.md" 2>/dev/null \
    && ! grep -q '^##* .Countish Gadget.$' "$LIBTMPDIR/gadget.md" 2>/dev/null; then
    pass=$((pass + 1))
    printf 'ok   library-mode impl rebucketing (private-type owner keeps Countish Gadget)\n'
  else
    fail=$((fail + 1))
    printf 'FAIL library-mode impl rebucketing (Countish Gadget misfiled off owner.md — private `data Gadget` not seen as ownership evidence)\n'
  fi
  if diff -rq "$LIBGOLDENDIR" "$LIBTMPDIR" >/dev/null 2>&1; then
    pass=$((pass + 1))
    printf 'ok   library-mode tree (index.md + inventory.json + per-module pages)\n'
  else
    fail=$((fail + 1))
    printf 'FAIL library-mode tree differs from golden:\n'
    diff -rq "$LIBGOLDENDIR" "$LIBTMPDIR" || true
  fi
else
  fail=$((fail + 1))
  printf 'FAIL library-mode (no golden tree — run CAPTURE=1 sh test/diff_compiler_doc.sh)\n'
fi

# ── direct assertions (not only via goldens) ────────────────────────────────
# The single-file goldens above already pin these fixtures byte-for-byte, but a
# golden can be re-blessed; these state the PROPERTY, so a regression has to be
# argued with rather than captured away.

# S2-2: doc's example detection == doctest.mdk's `-- > ` rule. The fixture holds
# one real doctest and one `-->`-shaped decoy. Cross-checked against `medaka
# test` itself, which is the authority on how many doctests the file has — a
# rendered example claims to be a verified doctest, and this is that claim,
# measured: one fenced example, one doctest run.
DTFIX="$FIXDIR/doctest_marker.mdk"
if [ -f "$DTFIX" ]; then
  fences="$("$MEDAKA" doc "$DTFIX" 2>/dev/null | grep -c '^```medaka$')"
  ran="$("$MEDAKA" test "$DTFIX" 2>/dev/null | grep -c '^  ok  ')"
  if [ "$fences" = "1" ] && [ "$ran" = "1" ]; then
    pass=$((pass + 1))
    printf 'ok   rendered examples agree with medaka test (1 fenced example, 1 doctest run)\n'
  else
    fail=$((fail + 1))
    printf 'FAIL rendered examples disagree with medaka test (%s fenced example(s), %s doctest(s) actually run)\n' "$fences" "$ran"
  fi
  # ... and the decoy renders as escaped prose, never inside a fence.
  if "$MEDAKA" doc "$DTFIX" 2>/dev/null | grep -q '^\\> fakeExample 1$'; then
    pass=$((pass + 1))
    printf 'ok   `-->` line renders as escaped prose, not a fenced example\n'
  else
    fail=$((fail + 1))
    printf 'FAIL `-->` line did not render as escaped prose\n'
  fi
else
  fail=$((fail + 1))
  printf 'FAIL doctest marker check (missing fixture %s)\n' "$DTFIX"
fi

# S2-3: `| ` is stripped only where a Haddock marker can sit. The marker sits on
# the SECOND line of the block (below a decorative separator merged in by
# `findDocForLine`) and must go; the table rows below it are user content and
# must survive verbatim.
PPFIX="$FIXDIR/pipe_prose.mdk"
if [ -f "$PPFIX" ]; then
  pp="$("$MEDAKA" doc "$PPFIX" 2>/dev/null)"
  if printf '%s\n' "$pp" | grep -q '^Parse an expression\.$' \
    && printf '%s\n' "$pp" | grep -q '^| expr | term |$' \
    && printf '%s\n' "$pp" | grep -q '^|------|------|$' \
    && printf '%s\n' "$pp" | grep -q '^| still | a | table |$'; then
    pass=$((pass + 1))
    printf 'ok   pipe marker stripped once per block, table rows survive\n'
  else
    fail=$((fail + 1))
    printf 'FAIL pipe-prose handling (marker not stripped, or a `|`-led user line was eaten)\n'
  fi
else
  fail=$((fail + 1))
  printf 'FAIL pipe-prose check (missing fixture %s)\n' "$PPFIX"
fi

# S2-4: library mode must REFUSE two targets that share a module basename rather
# than silently overwriting one page with the other (and misattributing both
# modules' entries in inventory.json). Inputs are synthesized here rather than
# committed, so no shared fixture corpus grows a directory for one negative
# case. The refusal must land BEFORE any output is written.
DUPDIR="$DUPTMPDIR"
mkdir -p "$DUPDIR/a" "$DUPDIR/b" "$DUPDIR/out"
cp "$LIBFIXDIR/alpha.mdk" "$DUPDIR/a/samename.mdk"
cp "$LIBFIXDIR/beta.mdk" "$DUPDIR/b/samename.mdk"
dupout="$("$MEDAKA" doc --out "$DUPDIR/out" "$DUPDIR/a/samename.mdk" "$DUPDIR/b/samename.mdk" 2>&1)"
dupstatus=$?
if [ "$dupstatus" -ne 0 ] \
  && printf '%s\n' "$dupout" | grep -q "share the module name 'samename'" \
  && [ ! -f "$DUPDIR/out/samename.md" ]; then
  pass=$((pass + 1))
  printf 'ok   library-mode refuses a duplicate module basename\n'
else
  fail=$((fail + 1))
  printf 'FAIL library-mode duplicate basename (exit %d, wrote samename.md=%s) — output:\n%s\n' \
    "$dupstatus" \
    "$([ -f "$DUPDIR/out/samename.md" ] && echo yes || echo no)" \
    "$dupout"
fi

# 0-checked must fail: a gate that iterated no fixtures proves nothing and must
# never report green (see e.g. diff_compiler_snapshot_frontend.sh's "NOTHING
# COMPARED" branch for the same house rule).
if [ "$((pass + fail))" -eq 0 ]; then
  printf '\nNO FIXTURES FOUND under %s — 0 checked, refusing to pass\n' "$FIXDIR"
  exit 1
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
