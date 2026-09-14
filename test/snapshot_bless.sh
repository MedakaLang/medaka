#!/bin/sh
# snapshot_bless.sh — the WRITE half of the snapshot suite: `--new` and `--bless`.
# NOT A GATE (it writes goldens; it asserts nothing), so it is ledgered in
# test/CI-COVERAGE-TOOLS.txt rather than enrolled in test/gates.toml.
#
# The CHECK half is test/diff_compiler_snapshot_frontend_test.mdk, a
# `kind = "native"` gate module that runs the same family table as data. Both
# halves exist because they answer different questions: a check runs in CI over
# a tree nobody is editing, and a write runs on a developer's machine over the
# one fixture they just changed. Only the check needs a registry entry.
#
# ── the family table ─────────────────────────────────────────────────────────
# A FAMILY is a (snapshot subdirectory, stage set, corpus) triple. It is the
# whole configuration of this suite: `medaka snapshot` does the work, and the
# only thing a caller supplies is which corpus to render at which stages into
# which directory. Seven shell gates used to carry fifteen such triples between
# them, one `run_family` call at a time; the table below is those fifteen, and
# it is the only copy in this file.
#
# The Medaka gate module mirrors this table and asserts, as one of its own
# tests, that its rows and the ones below name the same (subdir, stages, spec)
# triples — so the two copies cannot drift apart in silence.
#
#   spec        what the corpus IS
#   dir:<D>     every `.mdk` directly under <D> (not recursive)
#   file:<F>    exactly the one file <F>
#   compiler    the compiler's own sources: `.mdk` under compiler/{frontend,
#               types,ir,backend,eval,driver,tools,support}, minus `*_test.mdk`
#
# Two corpora are rendered TWICE, into different subdirectories at different
# stages, and that is why a family is keyed by subdirectory and not by corpus:
# `stdlib/core.mdk` is both `stdlib` (desugar,mark — it is a source file like
# any other) and `prelude` (types — a single dump of every prelude scheme, the
# whole-prelude inference invariant); `test/diff_fixtures` is both
# `diff_fixtures` (tokens,desugar,mark) and `diff_fixtures_types` (types_user,
# each fixture's OWN schemes, inferred prelude-aware).
#
# Nothing here renders the FULL stage set. Snapshotting the compiler's own
# sources single-file, with no import resolution and no core prelude, makes
# `# TYPES` a wall of bogus `Unbound variable` errors and `# CORE_IR` a 180 KB
# single line; a stage is snapshotted where it carries signal, and `stages=` in
# each `# META` records the choice where the next reader will see it.
#
# ── usage ────────────────────────────────────────────────────────────────────
#   sh test/snapshot_bless.sh --new                 # create every MISSING snapshot
#   sh test/snapshot_bless.sh --bless <path>...     # re-cut the NAMED fixtures
#
# `--new` never overwrites: rewriting an existing snapshot from the current
# compiler IS blessing. It is suite-wide by design — a newly added fixture is
# minted without its author having to know which family owns it.
#
# `--bless` REQUIRES explicit paths. There is no whole-suite bless and there
# will not be one; naming what you approve is the friction, and it is the only
# part of the design that survives without CI. A path belonging to two families
# is re-cut in BOTH (that is what "this fixture's snapshots" means), and every
# file written is named on stdout. The review gate is `git diff` on
# test/snapshots/, not the absence of a bless button.
#
# `--bless` also refuses, per fixture, to rewrite a section carrying compiler
# diagnostic prose — a `# PARSE` holding a parse error, a `# TYPES` holding a
# TYPE ERROR, a `# CRASH`. Those are graded against compiler/ERROR-QUALITY.md
# and must be READ, not rubber-stamped; to re-cut one, `rm` the `.md` and
# `--new` it, which lands in review as a delete+add. That refusal lives in
# `medaka snapshot` itself (compiler/tools/snapshot.mdk), not here. Every
# section of the eval_error_fixtures family is a `# CRASH`, so that family is
# permanently rm+--new and never --bless.
#
# WHY BLESS EXISTS AT ALL: the compiler's own sources are in this corpus, so
# ANY edit to compiler/**.mdk — a pure `medaka fmt` reflow included — changes
# that file's `# SOURCE` section and fails the check.
#
# Exit: 0 if every named fixture was handled; 1 on any refusal or write error;
#       2 if the compiler is not built (the tool never ran).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# $MEDAKA honoured so a caller that resolved its own binary (the pre-commit
# hook falls back to PATH) drives the same tool rather than a second copy.
MEDAKA="${MEDAKA:-$ROOT/medaka}"
SNAPDIR="$ROOT/test/snapshots"

[ -x "$MEDAKA" ] || {
  echo "build the compiler first: make medaka (missing $MEDAKA)" >&2
  exit 2
}

# ── FAMILY TABLE BEGIN ───────────────────────────────────────────────────────
# <subdir> <stages> <spec>.  Mirrored by
# test/diff_compiler_snapshot_frontend_test.mdk, which compares the two.
snapshot_families() {
  cat <<'EOF'
eval_fixtures core_ir dir:test/eval_fixtures
eval_dict_fixtures eval dir:test/eval_dict_fixtures
eval_typed_fixtures eval dir:test/eval_typed_fixtures
eval_error_fixtures eval dir:test/eval_error_fixtures
parse_fixtures parse,printer,desugar,mark dir:test/parse_fixtures
parse_only_fixtures parse dir:test/parse_only_fixtures
positions_fixtures positions dir:test/positions_fixtures
comment_fixtures comments dir:test/comment_fixtures
diff_fixtures tokens,desugar,mark dir:test/diff_fixtures
diff_fixtures_types types_user dir:test/diff_fixtures
typecheck_fixtures types dir:test/typecheck_fixtures
typecheck_panic_fixtures types dir:test/typecheck_panic_fixtures
stdlib desugar,mark dir:stdlib
prelude types file:stdlib/core.mdk
compiler desugar,mark compiler
EOF
}
# ── FAMILY TABLE END ─────────────────────────────────────────────────────────

# The corpus directories a `not part of the snapshot corpus` message lists.
corpus_blurb() {
  snapshot_families | while read -r _sub _stages spec; do
    case "$spec" in
      dir:*)  printf '%s\n' "${spec#dir:}" ;;
      file:*) printf '%s\n' "${spec#file:}" ;;
      *)      printf 'compiler\n' ;;
    esac
  done | sort -u | tr '\n' ' '
}

# The compiler's own sources, as the snapshot corpus defines them: eight
# subdirectories, `*_test.mdk` subtracted. A test module is not compiler source
# and owes no blessed snapshot ([P-TEST-SIBLING]); the check half subtracts the
# same set, so a golden the check never compares cannot be minted here.
compiler_sources() {
  for f in "$ROOT"/compiler/frontend/*.mdk "$ROOT"/compiler/types/*.mdk \
           "$ROOT"/compiler/ir/*.mdk "$ROOT"/compiler/backend/*.mdk \
           "$ROOT"/compiler/eval/*.mdk "$ROOT"/compiler/driver/*.mdk \
           "$ROOT"/compiler/tools/*.mdk "$ROOT"/compiler/support/*.mdk; do
    case "$f" in *_test.mdk) continue ;; esac
    printf '%s\n' "$f"
  done
}

# The absolute paths one family's spec expands to, one per line.
family_files() {
  case "$1" in
    dir:*)  ls "$ROOT/${1#dir:}"/*.mdk 2>/dev/null ;;
    file:*) printf '%s\n' "$ROOT/${1#file:}" ;;
    *)      compiler_sources ;;
  esac
}

# True when the absolute path $2 is inside (or is) the corpus named by spec $1.
# A DIRECTORY argument matches a family whose corpus lies under it, which is
# what makes `--bless compiler/frontend` and `--bless stdlib` work.
#
# The upward half is deliberately ONE level and `file:`-only. A `dir:` or
# compiler corpus is already reached by its own root going down, so the only
# case it has to serve is a single-file family whose file sits directly in the
# directory named — `--bless stdlib` reaching `prelude` (corpus
# `stdlib/core.mdk`). Matching any ANCESTOR instead made `--bless $ROOT` and
# `--bless $ROOT/test` own a dozen families apiece: a whole-suite bless by
# another spelling, which this tool's header says does not exist.
spec_owns() {
  case "$1" in
    dir:*)  _root="$ROOT/${1#dir:}" ;;
    file:*) _root="$ROOT/${1#file:}" ;;
    *)      _root="$ROOT/compiler" ;;
  esac
  case "$2" in
    "$_root") return 0 ;;
    "$_root"/*) return 0 ;;
  esac
  case "$1" in
    file:*) [ "$2" = "$(dirname "$_root")" ] && return 0 ;;
  esac
  return 1
}

usage() {
  echo "usage: sh test/snapshot_bless.sh --new" >&2
  echo "       sh test/snapshot_bless.sh --bless <path>..." >&2
}

# ── --new: mint every MISSING snapshot, across every family ──────────────────
if [ "${1:-}" = "--new" ]; then
  [ "$#" -eq 1 ] || { echo "--new takes no further arguments" >&2; usage; exit 1; }
  rc=0
  # A `for` over a flattened table rather than `snapshot_families | while`: a
  # pipeline runs the loop in a subshell, where `rc` would be set and thrown
  # away, and one failing family would have to abort the rest to be noticed at
  # all. Every family is minted, and every failure is reported.
  for row in $(snapshot_families | tr ' ' '|'); do
    sub="${row%%|*}"; rest="${row#*|}"
    stages="${rest%%|*}"; spec="${rest#*|}"
    mkdir -p "$SNAPDIR/$sub"
    files="$(family_files "$spec")"
    if [ -z "$files" ]; then
      echo "$sub: corpus is empty: $spec" >&2
      rc=1; continue
    fi
    # shellcheck disable=SC2086  # word-splitting is how the file list is passed
    out="$("$MEDAKA" snapshot --new --root "$ROOT" --out "$SNAPDIR/$sub" \
             --stages "$stages" $files 2>&1)" || rc=1
    printf '%-26s %s\n' "$sub" "$(printf '%s\n' "$out" | tail -1)"
    printf '%s\n' "$out" | grep -E ': (FAIL|ERROR)' | sed 's/^/    /'
  done
  exit "$rc"
fi

# ── --bless <path>...: re-cut the NAMED fixtures, in every family owning them ─
if [ "${1:-}" = "--bless" ]; then
  shift
  if [ "$#" -eq 0 ]; then
    echo "--bless requires explicit fixture paths — there is no whole-suite bless." >&2
    echo "  e.g.  sh test/snapshot_bless.sh --bless compiler/frontend/lexer.mdk" >&2
    exit 1
  fi
  rc=0
  for p in "$@"; do
    # Tolerate repeated flags: `--bless A --bless B` is a natural spelling, and
    # without this the second literal `--bless` resolves as a cwd-relative PATH
    # and is reported "not part of the snapshot corpus" — a confusing
    # half-success.
    [ "$p" = "--bless" ] && continue
    case "$p" in
      /*) ;;
      *) p="$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")" ;;
    esac
    [ -e "$p" ] || { echo "no such path: $p" >&2; rc=1; continue; }
    case "$p" in
      "$ROOT"/compiler/*_test.mdk)
        echo "not part of the snapshot corpus: $p" >&2
        echo "  (a *_test.mdk sibling is excluded from the compiler family)" >&2
        rc=1; continue ;;
    esac
    owners=""
    for row in $(snapshot_families | tr ' ' '|'); do
      sub="${row%%|*}"; spec="${row##*|}"
      spec_owns "$spec" "$p" && owners="$owners $sub"
    done
    if [ -z "$owners" ]; then
      echo "not part of the snapshot corpus: $p" >&2
      echo "  (corpus: $(corpus_blurb))" >&2
      rc=1; continue
    fi
    for sub in $owners; do
      # `--stages` is deliberately NOT passed: an existing snapshot names its
      # own stage set in `# META`, and a bless re-cuts the stages the file
      # already has — never widens them behind the author's back. That is also
      # what keeps a two-family path honest, since the two files disagree about
      # their stages by construction.
      "$MEDAKA" snapshot --bless --root "$ROOT" --out "$SNAPDIR/$sub" "$p" || rc=1
    done
  done
  exit "$rc"
fi

usage
exit 1
