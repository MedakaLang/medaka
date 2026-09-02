#!/bin/sh
# test/doctest_shape_census.sh — derived doctest-shape census. Not a gate:
# this is a reporting tool, run via `make slop-census` (registry row
# `doctest-shape (leg 5)`) or directly. It asserts nothing; exits 0 on a
# healthy run, and refuses (exit 1) only if the doctest-line corpus comes
# back empty — see below.
#
# WHY THIS EXISTS (#2513 tracking, #2276 leg 5, feeds #2290's remediation):
# every doctest input line (`-- > expr` / `> expr`) in tracked `compiler/*.mdk`
# and `stdlib/*.mdk` files is one of two shapes — DOCUMENTARY (illustrates a
# public function's real return value to a reader) or UNIT-TEST-SHAPED (a
# boolean assertion against internal/unexported machinery, standing in for a
# unit test the language has no other vehicle for). #2290 needs a per-site
# worklist of the unit-test-shaped ones to migrate later; this script derives
# that worklist instead of hand-surveying it, the same way this crusade's
# other census scripts derive their counts (test/fmt_clean_census.sh,
# test/comment_register_census.sh).
#
# CLASSIFICATION (three cheaply-greppable tells, any one is sufficient to
# call a doctest unit-test-shaped; #2290's own named tells):
#   1. boolean-equality assertion — the expression ends `== None`,
#      `== True`, or `== False`.
#   2. bare boolean output — the expected-output line, once its `-- `
#      comment prefix (if any) is stripped, is exactly `True` or `False`
#      with nothing else — the doctest asserts a predicate rather than
#      showing a real value.
#   3. unexported target — the first identifier token of the expression is
#      defined as a top-level binding in the SAME file but never appears
#      after an `export` line (or `public export data|fn|interface|impl`)
#      there, i.e. the doctest exercises private machinery a reader of the
#      module's public surface never sees.
# A doctest is DOCUMENTARY when none of the three tells fire and its target
# is a plain identifier. It is UNCLASSIFIED only when even the target can't
# be read off cheaply (the expression doesn't start with a plain identifier
# — a literal, an operator section, a tuple, ...) — that bucket is the
# honest "cannot judge cheaply" case, not a dumping ground for the rest. A
# MISSING-row-prints-0 shape here (silently defaulting the unjudged
# remainder to "fine") is exactly the fail-open bug this census exists to
# avoid, so UNCLASSIFIED is reported, never folded into documentary.
#
# The fixture-top-level-binding tell #2290 also names is NOT independently
# detected here: tell 3 already catches the concrete instances seen in this
# tree (a fixture is a local unexported binding), and a general free-name-
# resolution check is explicitly out of scope for a cheap regex census (see
# the packet this script was cut from).
#
# SCOPE: every git-tracked `*.mdk` file under compiler/ and stdlib/, matching
# `^[[:space:]]*(-- )?> ` for doctest input lines (catches both the
# `--`-prefixed block-comment form used under compiler/ and the bare `> `
# form inside `"""` doc blocks used under stdlib/).
#
# WHY ON-DEMAND, NOT A CI GATE: same rationale as this crusade's other
# member censuses — gating this tree-wide would surface pre-existing
# doctest-shape debt as a sudden required-check failure unconnected to
# whatever PR happens to trip it. Developer/agent convenience, not a merge
# gate.
#
# Needs no built ./medaka — pure text/regex over tracked source files.
# Portable POSIX sh (grep -E, awk; no bash-only features).
#
# Usage:  sh test/doctest_shape_census.sh
# Output: a per-file breakdown with a per-site worklist (file:line,
#         classification, reason), then per-file and grand-total counts
#         (documentary / unit-test-shaped / UNCLASSIFIED). Exits 0 on a
#         healthy run; refuses (exit 1) only if the doctest-line corpus
#         comes back empty, which would otherwise misreport as a clean zero.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

IFS='
'
files="$(git -C "$ROOT" ls-files -- 'compiler/*.mdk' 'stdlib/*.mdk')"

if [ -z "$files" ]; then
  echo "doctest_shape_census: matched ZERO .mdk files under compiler/ or stdlib/ — harness bug, refusing to report" >&2
  exit 1
fi

grand_total=0
grand_doc=0
grand_unit=0
grand_unclassified=0

for f in $files; do
  [ -n "$f" ] || continue
  [ -f "$ROOT/$f" ] || continue

  n=$(grep -cE '^[[:space:]]*(-- )?> ' "$ROOT/$f" 2>/dev/null || true)
  n=${n:-0}
  [ "$n" -gt 0 ] || continue

  # Names appearing right after a top-level `export` line, or inline after
  # `public export data|fn|interface|impl`.
  exports="$(awk '
    /^export$/ { pending = 1; next }
    pending {
      pending = 0
      if (match($0, /^[A-Za-z_][A-Za-z0-9_]*/)) print substr($0, RSTART, RLENGTH)
    }
    match($0, /^public export (data|fn|interface|impl) +[A-Za-z_][A-Za-z0-9_]*/) {
      rest = substr($0, RSTART, RLENGTH)
      sub(/^public export (data|fn|interface|impl) +/, "", rest)
      print rest
    }
  ' "$ROOT/$f" | sort -u)"

  # Plain top-level bindings: `name ... = ...` at column 0, not a keyword
  # line and not a type signature (`name : Type`).
  bindings="$(awk '
    match($0, /^[A-Za-z_][A-Za-z0-9_]*/) {
      name = substr($0, RSTART, RLENGTH)
      if (name == "export" || name == "data" || name == "fn" || name == "interface" || \
          name == "impl" || name == "import" || name == "public" || name == "type") next
      if ($0 ~ /=/ && $0 !~ /^[A-Za-z_][A-Za-z0-9_]* *:/) print name
    }
  ' "$ROOT/$f" | sort -u)"

  worklist="$(awk -v exports="$exports" -v bindings="$bindings" -v fname="$f" '
    BEGIN {
      ne = split(exports, ea, "\n")
      for (i = 1; i <= ne; i++) if (ea[i] != "") expset[ea[i]] = 1
      nb = split(bindings, ba, "\n")
      for (i = 1; i <= nb; i++) if (ba[i] != "") bindset[ba[i]] = 1
      pending = 0
    }
    function is_input(s) { return s ~ /^[[:space:]]*(-- )?> / }
    function classify() {
      cls = ""
      reason = ""
      if (pending_expr ~ /==[[:space:]]*(None|True|False)[[:space:]]*$/) {
        cls = "unit-test-shaped"; reason = "boolean-equality assertion"
      }
      if (cls == "" && pending_out != "" && (pending_out == "True" || pending_out == "False")) {
        cls = "unit-test-shaped"; reason = "bare boolean output"
      }
      target = pending_expr
      sub(/^[[:space:]]*\(*/, "", target)
      sub(/[[:space:](].*$/, "", target)
      if (cls == "" && target != "" && (target in bindset) && !(target in expset)) {
        cls = "unit-test-shaped"; reason = "target `" target "` is a local unexported binding"
      }
      if (cls == "") {
        if (target ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
          cls = "documentary"; reason = "no unit-test tell matched"
        } else {
          cls = "UNCLASSIFIED"; reason = "expression does not start with a plain identifier"
        }
      }
      print fname ":" pending_line "  " cls "  (" reason ")"
    }
    is_input($0) {
      if (pending) classify()
      pending = 1
      pending_line = FNR
      pending_expr = $0
      sub(/^[[:space:]]*(-- )?> /, "", pending_expr)
      pending_out = ""
      next
    }
    pending && pending_out == "" {
      outv = $0
      sub(/^[[:space:]]*-- /, "", outv)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", outv)
      pending_out = outv
      classify()
      pending = 0
      next
    }
    END { if (pending) classify() }
  ' "$ROOT/$f")"

  file_total=$(printf '%s\n' "$worklist" | grep -c .)
  file_doc=$(printf '%s\n' "$worklist" | grep -c '  documentary  ')
  file_unit=$(printf '%s\n' "$worklist" | grep -c '  unit-test-shaped  ')
  file_unclassified=$(printf '%s\n' "$worklist" | grep -c '  UNCLASSIFIED  ')

  echo "-- $f -- total=$file_total documentary=$file_doc unit-test-shaped=$file_unit UNCLASSIFIED=$file_unclassified"
  printf '%s\n' "$worklist"
  echo

  grand_total=$((grand_total + file_total))
  grand_doc=$((grand_doc + file_doc))
  grand_unit=$((grand_unit + file_unit))
  grand_unclassified=$((grand_unclassified + file_unclassified))
done

if [ "$grand_total" -eq 0 ]; then
  echo "doctest_shape_census: matched ZERO doctest input lines — harness bug, refusing to report" >&2
  exit 1
fi

echo "doctest_shape_census: $grand_total doctest input lines — documentary=$grand_doc unit-test-shaped=$grand_unit UNCLASSIFIED=$grand_unclassified"

exit 0
