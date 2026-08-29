#!/bin/sh
# diff_compiler_prose_classifier.sh — the prose allowlist has TWO copies; this
# gate is the check tying them together (#2200).
#
# ONE QUESTION, TWO IMPLEMENTATIONS:
#
#   * `.github/workflows/ci.yml`'s `detect` job runs a shell `case` over every
#     changed file to answer "is this file prose?" — the answer decides
#     `docs_only` (skip the whole build) and feeds `gateset` (which gates a
#     changed path selects). It is the copy that actually gates CI.
#   * `compiler/tools/gate_cmd.mdk`'s `isProsePath` is layer 1b of
#     `medaka gate explain`, and is a HAND-WRITTEN COPY of the same allowlist,
#     kept "in the same order for the same reason" by its own comment — with
#     nothing whatsoever checking that claim.
#
# Two hand-maintained copies of one classifier, no check: a `docs/` arm added
# to one and not the other silently changes what CI skips, or what `explain`
# says a path selects, with every gate green. That is the bug class this whole
# epic (#2182) exists to remove, so it gets a gate rather than a promise.
#
# HOW IT AVOIDS BEING A THIRD COPY. This gate does NOT re-implement the
# allowlist. It EXTRACTS the `case ... esac` block from ci.yml, verbatim,
# between the whole-line markers `PROSE-ALLOWLIST:BEGIN` / `PROSE-ALLOWLIST:END`
# and RUNS it, with its own two-line `nondoc` stub in place of the detect job's.
# So the left arm of the diff is ci.yml's real code, not a description of it —
# the same reason diff_compiler_ci_gen_drift.sh regenerates rather than
# re-describes.
#
# The probe corpus lives HERE, in the script, rather than in a fixture
# directory: it is a list of PATHS, not files (several deliberately do not
# exist — `LICENSEE`, `testfile.md` — because near-misses are exactly where a
# `case` glob and a `startsWith` disagree), so there is nothing for a fixture
# directory to hold and nothing for [T-SHARED-CORPUS] to enrol.
#
# Usage:  sh test/diff_compiler_prose_classifier.sh
# Exit:   0 both classifiers agree on every probe; 1 they disagree (the
#         disagreeing paths are named); 2 no native medaka binary to run it
#         with, or ci.yml's markers are missing.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
CI_YML="$ROOT/.github/workflows/ci.yml"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -f "$CI_YML" ] || { echo "no $CI_YML — nothing to compare against"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/prose_classifier.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM

# Extract ci.yml's own classifier, verbatim, dropping the marker lines. The
# markers must be whole-line comments; a missing one is a HARNESS failure, not
# a pass — a gate that silently compares against an empty program is the
# "this didn't run == this passed" bug diff_compiler_ci_shard_coverage.sh was
# built for.
awk '/PROSE-ALLOWLIST:BEGIN/ { grab = 1; next }
     /PROSE-ALLOWLIST:END/   { grab = 0 }
     grab' "$CI_YML" > "$TMP/case.sh"

if ! grep -q 'esac' "$TMP/case.sh"; then
  echo "::error::could not extract a \`case ... esac\` between PROSE-ALLOWLIST:BEGIN/END in"
  echo "         $CI_YML — the markers are missing, reordered, or no longer bracket the"
  echo "         detect job's prose allowlist. Refusing to certify agreement."
  exit 2
fi

# The probe corpus: every arm of the allowlist, plus the near-misses either
# side of each one. `test/README.md` and `testfile.md` straddle the
# must-stay-first `test/*` arm; `LICENSE.md`/`LICENSED.md`/`LICENSEE` straddle
# `LICENSE|LICENSE.*`; `docs/spec/SYNTAX.md` vs `docs/spec/SYNTAX.md.bak` is
# the executable-spec carve-out and the path that only LOOKS like it.
probes='
test/gates.toml
test/README.md
test/wasm/run.sh
test/parse_fixtures/rare_constructs.mdk
testfile.md
docs/spec/SYNTAX.md
docs/spec/SYNTAX.md.bak
docs/spec/LAYOUT-SEMANTICS.md
docs/README.md
docs/ops/CI-ARCHITECTURE.md
docs/ops/notes.txt
LICENSE
LICENSE.txt
LICENSE.md
LICENSED.md
LICENSEE
README.md
AGENTS.md
PLAN.md
Makefile
compiler/tools/gate_cmd.mdk
stdlib/core.mdk
runtime/medaka_rt.c
sqlite/test/select_oracle.sh
playground/e2e/run.sh
.github/workflows/ci.yml
'

# ci.yml's copy: source the extracted block once per probe, with a stub
# `nondoc` standing in for the detect job's (which also appends to a runner
# temp file — irrelevant to the verdict).
nondoc() { docs_only=false; }

fail=0
n=0
for f in $probes; do
  n=$((n + 1))
  docs_only=true
  # shellcheck disable=SC1090
  . "$TMP/case.sh"
  if [ "$docs_only" = true ]; then ci_says=PROSE; else ci_says=NONDOC; fi

  gate_says="$("$MEDAKA" gate explain --prose "$f" 2>/dev/null)"
  if [ -z "$gate_says" ]; then
    echo "::error::\`medaka gate explain --prose $f\` printed nothing"
    fail=$((fail + 1))
    continue
  fi

  if [ "$ci_says" = "$gate_says" ]; then
    printf '  %-8s %s\n' "$ci_says" "$f"
  else
    printf '  MISMATCH %s: ci.yml says %s, isProsePath says %s\n' "$f" "$ci_says" "$gate_says"
    fail=$((fail + 1))
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS: ci.yml's detect-job allowlist and gate_cmd.mdk's isProsePath agree on all $n probes."
  exit 0
fi

echo "::error::$fail of $n probe paths are classified DIFFERENTLY by the two copies of the"
echo "         prose allowlist. Fix whichever is wrong: the \`case\` block between"
echo "         PROSE-ALLOWLIST:BEGIN/END in .github/workflows/ci.yml, or \`isProsePath\`"
echo "         in compiler/tools/gate_cmd.mdk. They must stay arm-for-arm identical."
exit 1
