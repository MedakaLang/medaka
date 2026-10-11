#!/bin/sh
# diff_compiler_fmt_roundtrip.sh — AST-FIDELITY gate for `medaka fmt` (issue #130).
#
# `fmt --write` silently dropping parens is a latent S0: a formatter that can change a
# program's PARSE is a silent-wrongness vector, and the pre-commit hook force-runs fmt
# over the compiler's own source on every commit. This gate turns "does fmt preserve
# meaning" into a machine-checked invariant instead of a hope.
#
# Method: for each source file f, compare the parse-stage AST S-expression dump
# (test/bin/parse_main, compiler/entries/parse_main.mdk:15 `programToSexp (parse src)`)
# BEFORE formatting vs AFTER running it through the formatter (test/bin/fmt_main,
# compiler/entries/fmt_main.mdk). If fmt changed what the program PARSES TO, the two
# dumps differ and the gate fails.
#
# The dump is location-insensitive by construction: ELoc/spans are stripped before
# printing (compiler/ir/sexp.mdk:116 `exprSexp (ELoc _ e) = exprSexp e`), so different
# byte offsets after reformatting never show up — the comparison is exact byte-equality
# of the dump text, no span normalization needed. Parens carry no author-record in the
# AST (no EParen node; a paren is a transparent ELoc atom around its inner expr), so
# AST-equality is exactly the right invariant: fmt dropping a REDUNDANT paren is
# AST-equal (PASS, the fix for #130); fmt regrouping a MEANING-changing expression is
# AST-different (FAIL, caught here). This also permanently pins issue #51's bug class
# (any future fmt corruption that changes parse shape, not just the float-literal case).
#
# Corpus: every real .mdk source under compiler/ + stdlib/, plus both format-focused
# fixture corpora (test/fmt_fixtures, test/parse_fixtures) — the broadest round-trip
# sweep any fmt gate in this tree runs.
#
# Two further invariants over that same corpus, both #2159:
#   IDEMPOTENCY   — fmt(fmt(x)) must equal fmt(x) byte-for-byte (a second fmt pass on
#                   fmt's own output must be a no-op).
#   NO TRAILING WS — fmt's own canonical output must never end a line in a space/tab.
# Both route through the same known-divergence ledger as the AST-fidelity check
# below, since it is keyed by file path, not by which invariant diverges.
#
# Usage:  sh test/diff_compiler_fmt_roundtrip.sh [files...]
# Exit:   0 every file's parse-before == parse-after AND fmt is idempotent AND fmt's
#         output has no trailing whitespace (and at least one file was checked);
#         1 a mismatch, OR zero files checked (a gate that runs nothing must FAIL,
#         not pass); 2 an oracle binary is missing.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARSE="$ROOT/test/bin/parse_main"
FMT="$ROOT/test/bin/fmt_main"

# Collect ALL missing oracles before failing — naming only the first costs a
# round-trip per oracle in a fresh worktree (#398).
_missing=""
[ -x "$PARSE" ] || _missing="$_missing $PARSE"
[ -x "$FMT" ] || _missing="$_missing $FMT"
if [ -n "$_missing" ]; then
  echo "build oracles first — missing:"
  for _m in $_missing; do
    echo "  FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$_m")  (missing $_m)"
  done
  exit 2
fi

# NOTE on the sibling gates' "Unit auto-print" convention (test/diff_compiler_fmt_test.mdk,
# and the retired printer gate — now the # PRINTER snapshot section — both piped
# through a `strip_unit` that drops a trailing
# "()"): that convention does NOT apply here, verified empirically against this build —
# parse_main and fmt_main are BOTH `main : <IO> Unit` (a `match args () { ... }` whose
# every arm is Unit-typed: putStr/ePutStrLn), and `shouldAutoPrintMain`
# (compiler/driver/main_autoprint.mdk) explicitly returns False whenever
# `mainTypeIsUnit()` — so the wrap that would emit `println <e>` never fires, and no
# trailing "()" is ever appended to either oracle's stdout (checked via `od -c` on
# fmt_main's raw output for several fixtures: it ends exactly at the source's own last
# byte, never "()"). This matches the MEMORY note "Unit main no auto-print": the
# behavior the sibling gates' `strip_unit` guards against was fixed away upstream, and
# their `strip_unit` is now a harmless no-op for THEIR use (comparing text against a
# golden). It is NOT harmless here: this gate feeds fmt_main's stdout back into a
# re-parse, so blindly stripping a trailing "()" would corrupt any file whose real last
# line legitimately ends in "()" (e.g. `unit = ()`, `replLoop ()`) into unparseable
# source — which is exactly what an earlier version of this gate did, and it is why
# there is no strip_unit call below.

# --worker mode: the parallel pass below re-invokes this script as
# `sh "$SELF" --worker "$WORKDIR" <n>` under `xargs -P`. It runs the per-file oracle work
# for corpus index <n>, leaves its results in $WORKDIR, and prints nothing; the main run
# replays those results in index order.
if [ "${1:-}" = "--worker" ]; then
  WORKDIR="$2"
  n="$3"
  f="$(sed -n "${n}p" "$WORKDIR/list")"
  rel="${f#"$ROOT"/}"

  # Same crash guards as the serial loop used to have, in the same order.
  before="$("$PARSE" "$f" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL %s: parse_main crashed (exit %d) on the original source\n' "$rel" "$rc" > "$WORKDIR/$n.msg"
    printf 'crash\n' > "$WORKDIR/$n.st"
    exit 0
  fi

  formatted="$WORKDIR/$n.mdk"
  "$FMT" "$f" 2>/dev/null > "$formatted"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL %s: fmt_main crashed (exit %d)\n' "$rel" "$rc" > "$WORKDIR/$n.msg"
    printf 'crash\n' > "$WORKDIR/$n.st"
    exit 0
  fi

  after="$("$PARSE" "$formatted" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL %s: parse_main crashed (exit %d) re-parsing the formatted output\n' "$rel" "$rc" > "$WORKDIR/$n.msg"
    printf 'crash\n' > "$WORKDIR/$n.st"
    exit 0
  fi

  # IDEMPOTENCY: fmt(fmt(x)) must equal fmt(x) byte-for-byte (#2159).
  twice="$WORKDIR/$n.twice.mdk"
  "$FMT" "$formatted" 2>/dev/null > "$twice"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL %s: fmt_main crashed (exit %d) re-formatting the formatted output (idempotency pass)\n' "$rel" "$rc" > "$WORKDIR/$n.msg"
    printf 'crash\n' > "$WORKDIR/$n.st"
    exit 0
  fi
  idem_ok=1
  cmp -s "$formatted" "$twice" || idem_ok=0

  # NO TRAILING HORIZONTAL WHITESPACE (#2159). [[:blank:]] is space and tab.
  grep -nE '[[:blank:]]+$' "$formatted" > "$WORKDIR/$n.ws" 2>/dev/null
  ws_ok=1
  if [ -s "$WORKDIR/$n.ws" ]; then ws_ok=0; fi

  ast_ok=1
  [ "$before" = "$after" ] || ast_ok=0
  if [ "$ast_ok" -eq 0 ]; then
    printf '%s\n' "$before" > "$WORKDIR/$n.before.sexp"
    printf '%s\n' "$after" > "$WORKDIR/$n.after.sexp"
  fi

  printf 'ok %d %d %d\n' "$ast_ok" "$idem_ok" "$ws_ok" > "$WORKDIR/$n.st"
  exit 0
fi

# ── KNOWN-DIVERGENCE LEDGER (self-draining ratchet) ──────────────────────────
# A short checked-in list of fixtures where fmt is KNOWN to change the parse, each
# with a tracking issue (test/fmt_roundtrip_known_divergence.txt). The ratchet runs
# in BOTH directions — this is the whole point, a plain skip-list rots:
#   * a file that diverges and is NOT listed          -> FAIL (a new regression);
#   * a listed file that now ROUND-TRIPS CLEAN         -> FAIL ("now passes — remove
#                                                         it"), so a fix cannot land
#                                                         and leave the ledger stale;
#   * a listed file that STILL diverges                -> tolerated, but COUNTED and
#                                                         NAMED (never silent).
# Paths in the ledger are repo-relative; the corpus paths here are absolute, so we
# compare on the "$ROOT/"-stripped tail.
LEDGER="$ROOT/test/fmt_roundtrip_known_divergence.txt"
known=""
if [ -f "$LEDGER" ]; then
  # First whitespace-delimited token of each non-comment line is the path.
  known="$(sed 's/#.*//' "$LEDGER" | while read -r p _; do
    [ -n "$p" ] && printf '%s\n' "$p"
  done)"
fi
is_known() { case "
$known
" in *"
$1
"*) return 0 ;; *) return 1 ;; esac; }

if [ "$#" -gt 0 ]; then
  files="$*"
  full_run=0
else
  # EVERY tracked .mdk outside test/ (#2500: the old hand-listed corpus missed
  # pds/, sqlite/, parsec/ and gzip/, which is where the last two formatter bugs
  # were found) plus the two formatter fixture corpora.  test/ itself holds
  # many fixtures that are MEANT not to parse, so it is not swept wholesale; a
  # parse failure on any file listed here is a hard failure of this gate.
  files="$(cd "$ROOT" && git ls-files '*.mdk' | grep -v '^test/' | sed "s|^|$ROOT/|") \
$ROOT/test/fmt_fixtures/*.mdk $ROOT/test/parse_fixtures/*.mdk"
  full_run=1
fi

# Local scratch dir — deliberately NOT named TMPDIR (that is the well-known env var;
# reassigning it would leak into this script's every child process).
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM


# Per-file work fans out over `xargs -P`. Bounded by default to min(4, NCPU/2), at least
# 1: the box is shared, so never NCPU. FMT_ROUNDTRIP_JOBS overrides.
NCPU="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
XJOBS=$(( NCPU / 2 ))
[ "$XJOBS" -gt 4 ] && XJOBS=4
[ "$XJOBS" -lt 1 ] && XJOBS=1
XJOBS="${FMT_ROUNDTRIP_JOBS:-$XJOBS}"
SELF="$ROOT/test/diff_compiler_fmt_roundtrip.sh"

# Pass 1 (serial, cheap): number the files that exist, in corpus order. Index n is the
# file's position; every per-file artifact is keyed by it, so the replay below prints
# results in exactly the order the old serial loop did.
: > "$WORKDIR/list"
n=0
for f in $files; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  printf '%s\n' "$f" >> "$WORKDIR/list"
done

# Pass 2 (parallel): one worker per index, each a re-invocation of this script in
# --worker mode. Workers print nothing; results land in $WORKDIR/$n.st and friends.
if [ "$n" -gt 0 ]; then
  i=1
  while [ "$i" -le "$n" ]; do
    printf '%s\n' "$i"
    i=$((i + 1))
  done | xargs -P "$XJOBS" -n 1 sh "$SELF" --worker "$WORKDIR"
fi

# Pass 3 (serial): replay the results in index order. Output, counters and exit status
# match the old single loop, including stopping at the first oracle crash.
n=0
pass=0
fail=0
kdiv=0              # ledgered files that STILL diverge (tolerated)
kdiv_names=""
seen_known=""      # ledgered files actually encountered this run
while IFS= read -r f; do
  n=$((n + 1))
  rel="${f#"$ROOT"/}"

  # An oracle CRASH must never impersonate a result: the worker recorded it as a
  # labelled failure, and the replay stops here exactly as the serial loop did.
  if [ ! -f "$WORKDIR/$n.st" ]; then
    printf 'FAIL %s: parallel worker wrote no result\n' "$rel"
    exit 1
  fi
  read -r kind ast_ok idem_ok ws_ok < "$WORKDIR/$n.st"
  if [ "$kind" = crash ]; then
    cat "$WORKDIR/$n.msg"
    exit 1
  fi

  if is_known "$rel"; then
    seen_known="$seen_known $rel"
    if [ "$ast_ok" -eq 1 ] && [ "$idem_ok" -eq 1 ] && [ "$ws_ok" -eq 1 ]; then
      # Accidental fix: a ledgered divergence now round-trips clean on every checked
      # invariant. FAIL loudly so the ledger cannot silently retain a fixed entry.
      fail=$((fail + 1))
      printf 'FAIL %s — known divergence (#142) now passes AST/idempotency/whitespace: remove it from test/fmt_roundtrip_known_divergence.txt and close the tracking issue\n' "$rel"
    else
      kdiv=$((kdiv + 1))
      kdiv_names="$kdiv_names $rel"
      [ "$ast_ok" -eq 1 ] || printf '  (known) %s: AST divergence\n' "$rel"
      [ "$idem_ok" -eq 1 ] || printf '  (known) %s: fmt is not idempotent\n' "$rel"
      [ "$ws_ok" -eq 1 ] || printf '  (known) %s: trailing whitespace in fmt output\n' "$rel"
    fi
  elif [ "$ast_ok" -eq 1 ] && [ "$idem_ok" -eq 1 ] && [ "$ws_ok" -eq 1 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    if [ "$ast_ok" -eq 0 ]; then
      printf 'FAIL %s (fmt round-trip changed the AST — not in the known-divergence ledger)\n' "$rel"
      diff -u "$WORKDIR/$n.before.sexp" "$WORKDIR/$n.after.sexp" | sed 's/^/    /'
    fi
    if [ "$idem_ok" -eq 0 ]; then
      printf 'FAIL %s (fmt is not idempotent: fmt(fmt(x)) != fmt(x) — not in the known-divergence ledger)\n' "$rel"
      diff -u "$WORKDIR/$n.mdk" "$WORKDIR/$n.twice.mdk" | sed 's/^/    /'
    fi
    if [ "$ws_ok" -eq 0 ]; then
      printf 'FAIL %s (fmt output has trailing horizontal whitespace — not in the known-divergence ledger)\n' "$rel"
      sed 's/^/    /' "$WORKDIR/$n.ws"
    fi
  fi
done < "$WORKDIR/list"

# In a full-corpus run, a ledger entry that was NEVER encountered is stale (the fixture
# was renamed or deleted): it can no longer self-drain, so flag it. Skipped for a
# targeted [files...] run, which legitimately covers only a subset.
if [ "$full_run" -eq 1 ]; then
  for k in $known; do
    case " $seen_known " in
      *" $k "*) ;;
      *) fail=$((fail + 1)); printf 'FAIL %s — ledgered in test/fmt_roundtrip_known_divergence.txt but not present in the corpus (stale entry; remove it)\n' "$k" ;;
    esac
  done
fi

printf 'checked %d files\n' "$n"
if [ "$n" -eq 0 ]; then
  echo "NOTHING COMPARED — the corpus globs matched zero files (this is not a pass)"
  exit 1
fi
if [ "$kdiv" -gt 0 ]; then
  printf '%d known-divergence(s):%s\n' "$kdiv" "$kdiv_names"
fi
printf '%d matched, %d ledgered divergence(s), %d unexpected failure(s)\n' \
  "$pass" "$kdiv" "$fail"
[ "$fail" -eq 0 ]
