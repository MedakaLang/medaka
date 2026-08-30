#!/bin/sh
# preflight.sh — the LOCAL agent loop. Fast, targeted, and deliberately INCOMPLETE.
#
#   sh test/preflight.sh [base-ref]        # default base: origin/main (NOT `main` — #560)
#
# WHY THIS EXISTS
# ---------------
# An agent that changes `parser.mdk` used to run `FORCE=1 build_oracles.sh`, which
# builds ALL 54 oracle binaries (54 × `medaka build` + clang) when it needs FOUR.
# On a shared box with several agents that is the single biggest source of CPU
# waste. This script derives the gate set from the DIFF, derives the oracle set from
# those gates, and builds only what it needs.
#
# ⚠️ THIS IS A FILTER, NOT AN AUTHORITY. ⚠️
# ------------------------------------------
# It runs a SUBSET. A green preflight does NOT mean the change is good — it means
# the change did not break the gates most likely to notice. **CI, running the FULL
# suite on a pull request, is the authority.** Nothing merges on a green preflight.
#
# That distinction is load-bearing. This project's whole testing overhaul exists
# because the suite used to report green while silently testing nothing (a missing
# oracle exited 2 = SKIP != FAIL; a gate that could not even be parsed by dash was
# counted as "skipped" for months). A targeted local run RE-INTRODUCES exactly that
# hazard if anyone mistakes it for the real suite. So this script ENDS by printing
# what it did not run. Do not make it quiet.
#
# WHAT IT DELIBERATELY SKIPS (CI runs these):
#   * diff_compiler_engines   — the whole three-engine fixture corpus × clang. The clang
#     storm, and the most expensive gate in the tree: minutes on a shared box. (Neither
#     the fixture count nor the wall time is written down here on purpose — the gate
#     derives and prints its own live count, and the time is whatever your box does
#     today. Measure it; do not trust a cardinal in a comment.)
#     ⚠️ That skip lives in ONE place — the LOCAL_SKIP block, which is BELOW the
#     PREFLIGHT_DRY exit. It must never be expressed in the change→gate map: CI reads
#     that map to narrow its PR run, so a "local" skip written there is not local. See
#     #402 and the LOCAL_SKIP comment.
#   * selfcompile_fixpoint    — minutes. Only forced locally on a BACKEND change,
#                               because for the emitter it is the decisive gate and
#                               finding out in CI is too late.
#   * the full diff_compiler_* suite — CI shards it across hosted runners for free.
#     (How many gates that is: `ls test/diff_compiler_*.sh | wc -l`. How many gate
#     scripts exist in the tree at all, shard coverage included:
#     `sh test/diff_compiler_ci_shard_coverage.sh | grep TOTAL`. Both drift with every
#     gate added, so this file names the derivation and never the number.)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Keep the build/test write-storm OUT OF RAM (/tmp is a RAM-backed tmpfs).
. "$ROOT/test/lib_scratch.sh"
mdk_warn_if_tmp_full
BASE_ARG="${1:-}"
cd "$ROOT" || exit 1

# Normalize the changed-path set once, then feed every derivation pass from the
# same newline-delimited file. A path can therefore never become shell syntax or
# collide with a here-document delimiter. The trap owns the only scratch path.
CHANGED_PATHS="$(mktemp "${TMPDIR:-/tmp}/medaka-preflight-changed.XXXXXX")" || {
  echo "preflight: mktemp failed while preparing changed paths" >&2
  exit 1
}
trap 'rm -f "$CHANGED_PATHS"' EXIT HUP INT TERM

# ── Where the changed-file list comes from ───────────────────────────────────
#
# Normally: git, relative to $BASE. But CI cannot use that. On a `pull_request`
# event `actions/checkout` gives a SHALLOW checkout of the PR's MERGE ref, so
# there is no `main` branch locally and no merge-base to three-dot against; the
# `detect` job already resolves base/head SHAs (fetching them explicitly) and
# diffs them itself. PREFLIGHT_CHANGED_FILE lets it hand that list straight in.
#
# This parameterizes only the INPUT ("what changed"), never the DERIVATION
# ("which gates does that touch"). The derivation below stays the single
# implementation — CI narrowing its PR run must not become a second, drifting
# copy of this file's change→gate map. See .github/workflows/ci.yml.
if [ -n "${PREFLIGHT_CHANGED_FILE:-}" ]; then
  [ -f "$PREFLIGHT_CHANGED_FILE" ] || {
    echo "preflight: PREFLIGHT_CHANGED_FILE='$PREFLIGHT_CHANGED_FILE' does not exist."
    exit 1
  }
  LC_ALL=C sort -u "$PREFLIGHT_CHANGED_FILE" | grep -v '^$' > "$CHANGED_PATHS"
  BASE="(PREFLIGHT_CHANGED_FILE)"
else
  # ── Which base ref? NOT `main`. ────────────────────────────────────────────
  #
  # In a worktree, `refs/heads/main` is UNMAINTAINABLE from where every agent
  # works: it is checked out in the primary tree, so `git checkout main` in an
  # agent worktree fails outright ("'main' is already used by worktree at …").
  # Nothing an agent does can advance it; it sits at whatever the last `git pull`
  # in the primary tree left, forever. `refs/remotes/origin/main` lives in the
  # same shared common dir but is refreshed by ANY fetch anywhere in the fleet —
  # including the `git merge origin/main` every agent is told to run first. So
  # origin/main is the ref the fleet actually maintains; `main` is one it cannot.
  #
  # Three-dot ALREADY handles a base that has ADVANCED past the fork point — it
  # diffs from the merge-base — so a base being "ahead" is harmless, and that is
  # why defaulting to origin/main needs no fetch to be correct. The failure is a
  # base BEHIND the fork point: the merge-base drags back, and every commit that
  # landed in between is attributed to your branch. That was #560 — a diff
  # touching only parser.mdk grew to 22 files, enrolled the wasm gates and the
  # clang storm, then exited 2 having run NOTHING. It scales with fleet
  # productivity: the more `main` lags, the more of other people's work preflight
  # blames on you.
  if [ -n "$BASE_ARG" ]; then
    BASE="$BASE_ARG"
  elif git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    BASE="origin/main"
  elif git rev-parse --verify --quiet main >/dev/null 2>&1; then
    # Fork, or a remote not named `origin`. `main` may be right here — but we
    # cannot verify freshness without origin/main, so say so rather than imply it.
    BASE="main"
    echo "preflight: NOTE — no 'origin/main' ref; falling back to local 'main'."
    echo "preflight:   Freshness is UNVERIFIABLE without it. If 'main' is behind this"
    echo "preflight:   branch's fork point, the list below includes commits that are"
    echo "preflight:   not yours and the gate set is fiction (#560)."
  else
    BASE=""
  fi

  # An unresolvable base must not be swallowed. `git diff <bad-ref>...HEAD
  # 2>/dev/null` fails silently, leaving only working-tree changes — or none at
  # all, whereupon preflight printed "no changes — nothing to do" and exited 0
  # over real committed work. Verified against this script before the fix: a green
  # that ran nothing, the exact hazard this file's header exists to rail about.
  if [ -z "$BASE" ] || ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
    echo "preflight: cannot resolve base ref '${BASE_ARG:-origin/main}' — refusing to guess." >&2
    echo "preflight:   A base that does not resolve yields a SILENTLY EMPTY diff, which" >&2
    echo "preflight:   would report 'nothing to do' and exit 0 over your committed work." >&2
    echo "preflight:   Fetch it (git fetch origin main), or pass one: sh test/preflight.sh <ref>" >&2
    exit 1
  fi

  # ── Staleness assert ──────────────────────────────────────────────────────
  #
  # Network-free. Compares the fork point $BASE implies against the one
  # origin/main implies, and fires ONLY when $BASE is a PROPER ANCESTOR of the
  # true fork point — i.e. provably reaches back too far and WILL invent files.
  # Vacuous (and free) on the default, where the two are the same commit.
  #
  # Deliberately not `--is-ancestor $BASE HEAD`: that proves ANCESTRY, not
  # FRESHNESS, and passes cheerfully on a stale main — which is precisely why the
  # BASE_OK assert every agent runs could never catch #560.
  #
  # A deliberately-NARROW override (say HEAD~3 on a branch with commits) is a
  # DESCENDANT of the fork point, so it correctly does not fire.
  #
  # WARN, not fail: after the default flip the answer is now CORRECT rather than
  # plausible-wrong, so the only way here is to ASK for a stale base — and
  # `make preflight BASE=main` is a documented invocation (Makefile). Hard-failing
  # a documented override on the most-run script in the repo buys a workaround,
  # not a fix. The unresolvable-base arm above still hard-fails, because that one
  # has no legitimate use and no way to be labelled.
  if git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    mb_base="$(git merge-base "$BASE" HEAD 2>/dev/null || true)"
    mb_true="$(git merge-base origin/main HEAD 2>/dev/null || true)"
    if [ -n "$mb_base" ] && [ -n "$mb_true" ] && [ "$mb_base" != "$mb_true" ] &&
      git merge-base --is-ancestor "$mb_base" "$mb_true" 2>/dev/null; then
      echo "preflight: ⚠️  BASE '$BASE' is $(git rev-list --count "$mb_base".."$mb_true") commit(s) BEHIND"
      echo "preflight:   this branch's fork point ($(git rev-parse --short "$mb_true"))."
      echo "preflight:   The list below WILL include commits that are not yours, and the"
      echo "preflight:   derived gate set with them (#560). Prefer: sh test/preflight.sh origin/main"
      echo
    fi
  fi

  # committed-vs-base, working tree, INDEX, and untracked. `--cached` is not optional:
  # without it a fully-`git add`ed change is invisible here (working-tree diff is empty and
  # nothing is committed yet), so `preflight` printed "no changes vs main — nothing to do"
  # and exited 0 over a staged rewrite of the compiler. That is the same silent-green
  # failure as the gate-existence check below, one step earlier in the pipe.
  {
    git diff --name-only "$BASE"...HEAD 2>/dev/null
    git diff --name-only 2>/dev/null
    git diff --name-only --cached 2>/dev/null
    git ls-files -o --exclude-standard 2>/dev/null
  } | LC_ALL=C sort -u | grep -v '^$' > "$CHANGED_PATHS"
fi

if [ ! -s "$CHANGED_PATHS" ]; then
  echo "preflight: no changes vs $BASE — nothing to do."
  exit 0
fi

echo "── changed vs $BASE ──────────────────────────────────────────"
sed 's/^/  /' "$CHANGED_PATHS"
echo

# ── changed path → gate patterns ─────────────────────────────────────────────
# Deliberately CONSERVATIVE: a change to an early stage cascades downstream, so we
# select downstream gates too. When in doubt, run MORE. A false positive costs
# seconds; a false negative costs a red CI and a round-trip.
pats=""
add() { case " $pats " in *" $1 "*) ;; *) pats="$pats $1" ;; esac; }

# ── fixture/golden directory → its ACTUAL consumers ──────────────────────────
#
# Naively, ANY change under a `*fixtures*`/`*goldens*` dir used to `add
# 'diff_compiler_*'` — every gate, including `diff_compiler_engines` (the whole
# fixture corpus × clang, the single most expensive gate in the tree). That is every
# well-behaved bug fix, since a regression fixture is required with every fix.
#
# Fix: derive the consuming gates from the gate SCRIPTS, same philosophy as the
# rest of this file (and `build_oracles.sh --for`) — never a hand-maintained
# fixture-dir→gate map, which drifts. AGENTS.md already prescribes this
# procedure manually ("Before touching a fixture dir, find every consumer:
# `grep -rl '<fixture_dir>' test/`. Then run all of them.") — this automates it.
#
# "gate" candidate universe. First cut was an INCLUDE-list by naming family
# (diff_compiler_*, bootstrap_*, selfcompile_*, wasm/diff_*) — wrong: this repo
# has plenty of real corpus-consuming gates outside those families
# (cross_project_twonames.sh reads test/cross_project_fixtures/twonames/goldens,
# check_removed_constructs.sh, effect_*_domain.sh, build_construct_coverage.sh,
# manifest_emit.sh, lsp_harness.sh, assemble_check_main.sh, w1.sh, …), so an
# include-list silently produced FALSE "no consumer found" on real corpora —
# exactly the failure mode this derivation exists to prevent. An include-list
# by naming convention also rots the same way a hand-maintained map does: every
# new gate with a novel name needs a new entry.
#
# So: the universe is EVERY GATE, MINUS the scripts that are infra (build/capture/
# orchestrate/profile) rather than pass/fail regression gates over a corpus. An
# EXCLUDE-list is far more stable than an include-list — a new *gate* is added
# constantly; a new *infra utility* is not.
#
# ⚠️ The exclude-list is NOT written here. It is test/CI-COVERAGE-TOOLS.txt — see
# _gate_candidates below for why a second copy of it in this file was itself a bug.
# ── THE GATE UNIVERSE: every TRACKED-OR-UNTRACKED-NOT-IGNORED .sh in the repo
#    that is not a TOOL ─────────────────────────────────────────────────────
#
# This used to enumerate `test/*.sh` + `test/wasm/*.sh`, filtered by a hand-written
# _NONGATE list. Both halves were the same bug, and it is the bug this whole workstream
# exists to kill:
#
#   * The ROOTS were a curated pair of globs. So the derivation could not see
#     test/native_fixtures/run.sh (a SUBDIRECTORY of test/), the 22
#     sqlite/test/*oracle.sh gates, or playground/e2e/run.sh — 24 real gates. A corpus
#     consumed only by one of those derived ZERO consumers, hit the fallback, and ran
#     the full diff_compiler_* suite while proving nothing about what actually reads it.
#   * _NONGATE was a SECOND, hand-maintained copy of the tools list, free to drift from
#     test/CI-COVERAGE-TOOLS.txt — the file that already answers "is this a gate?" and
#     that diff_compiler_ci_shard_coverage.sh treats as authoritative.
#
# So: one source of truth (CI-COVERAGE-TOOLS.txt), and the same universe the coverage
# gate enumerates. This makes preflight the FIFTH consumer of one rule, alongside
# run_gates.sh, build_oracles.sh --for, the coverage gate, and preflight's own pattern
# resolver. A derivation that disagreed with the other four would quietly under-run.
#
# `git ls-files`, not a filesystem walk: this box keeps ~30 agent worktrees under
# `.claude/worktrees/`, and a `find` from the main checkout would happily enumerate every
# OTHER worktree's copy of every gate. `git -C "$ROOT" ls-files` (tracked and, via
# `-o --exclude-standard`, untracked-not-ignored) stays scoped to THIS worktree's
# working tree, so it can't leak another worktree's files the way `find` would.
#
# Tracked-only was itself a bug (#257): `changed` (~line 68) deliberately folds in
# untracked-not-ignored files via `git ls-files -o --exclude-standard` so a brand-new,
# not-yet-`git add`ed gate script is exercised — but a tracked-only candidate universe
# couldn't count that same file, so `total_gates` undercounted by exactly the untracked
# gates in `$gates`. The union below mirrors the same `-o --exclude-standard` `changed`
# already uses, so the denominator covers exactly what `$gates` can ever contain.
_TOOLS=" $(grep -v '^[[:space:]]*#' "$ROOT/test/CI-COVERAGE-TOOLS.txt" 2>/dev/null \
           | awk 'NF { print $1 }' | tr '\n' ' ')"
_gate_candidates() {
  { git -C "$ROOT" ls-files '*.sh' 2>/dev/null; \
    git -C "$ROOT" ls-files -o --exclude-standard '*.sh' 2>/dev/null; } \
    | sort -u | while IFS= read -r _rel; do
    case "$_TOOLS" in *" ${_rel%.sh} "*) continue ;; esac
    [ -f "$ROOT/$_rel" ] || continue
    printf '%s\n' "$ROOT/$_rel"
  done
}

# Live (non-comment) reference to fixture-dir $2 inside file $1. Comments are
# stripped FIRST (full-line `#...` only) so a gate's header PROSE can't be
# mistaken for a live dependency — the exact bug `run_gates.sh`'s stale-oracle
# scrape has today (it greps `test/bin/...` including comment blocks, so a gate
# whose header says "REPLACES test/bin/parse_main" is believed to depend on a
# probe it never opens). Word-boundaries on both sides so `llvm_fixtures`
# cannot match `llvm_fixtures_modules`/`llvm_fixtures_typed` (real sibling
# corpora in this tree), and so `test/diff_fixtures` cannot match inside
# `test/snapshots/diff_fixtures` (also real, also distinct).
_refs() {
  grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -qE "(^|[^A-Za-z0-9_])$2([^A-Za-z0-9_]|\$)"
}

# Other test/*.sh or test/wasm/*.sh scripts $1 ACTUALLY INVOKES (live,
# non-comment). Anchored on the literal `sh "$ROOT/test/...` idiom this repo
# uses EVERY real invocation site (verified: 9/9 real invocations in test/*.sh
# use this exact quoted-$ROOT form). Deliberately NOT a bare `test/[name].sh`
# scrape — this codebase is full of human-readable hint strings like
# `echo "build oracles first: sh test/build_oracles.sh"` that name a script
# without invoking it; a bare scrape (the same shape as run_gates.sh's stale-
# oracle `test/bin/...` bug) falsely turned diff_compiler_new.sh into an
# "indirect consumer" of test/llvm_fixtures via its unrelated
# `echo "no golden tree ... run sh test/capture_goldens.sh"` error message,
# ballooning one fixture's consumer set from 3 gates to 42. Caught by testing
# this derivation against the real corpus before trusting it.
_invokes() {
  grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -ohE 'sh "\$ROOT/test/(wasm/)?[A-Za-z0-9_]+\.sh' \
    | sed 's/^sh "\$ROOT\///' | sort -u
}

# Does gate $1 consume fixture dir $2 — directly, OR indirectly via one hop
# through a helper it invokes? (Real case: diff_compiler_tmc_parity.sh never
# mentions test/wasm/fixtures itself — it shells to test/tmc_census.sh, and
# THAT script reads the corpus. Missing this one-hop case would silently drop
# a genuine consumer, exactly the false-negative this derivation must avoid.)
_consumes() {
  _gate="$1"; _d="$2"
  _refs "$_gate" "$_d" && return 0
  for _h in $(_invokes "$_gate"); do
    _hp="$ROOT/$_h"
    [ -f "$_hp" ] && [ "$_hp" != "$_gate" ] && _refs "$_hp" "$_d" && return 0
  done
  return 1
}

# Fixture directory for a changed path: climb from its parent to the nearest
# ancestor whose name contains "fixtures" or "goldens".
_fixture_dir_for() {
  _fd="$(dirname "$1")"
  while [ "$_fd" != "." ] && [ "$_fd" != "/" ] && [ "$_fd" != "test" ]; do
    case "$(basename "$_fd")" in
      *fixtures*|*goldens*) printf '%s\n' "$_fd"; return 0 ;;
    esac
    _fd="$(dirname "$_fd")"
  done
  return 1
}

# Gates that consume fixture dir $1. If the exact dir has no direct/one-hop
# consumer, climb to its parent and retry — some gates key off the PARENT, not
# the leaf (real case: test/snapshots/diff_fixtures is a snapshot-golden
# subdir; diff_compiler_snapshot_frontend.sh reads `$ROOT/test/snapshots`
# as a whole via SNAPDIR, never the literal string "test/snapshots/diff_fixtures").
# Stops before climbing to bare "test" (which would trivially match everything).
_gates_for_fixture_dir() {
  _d="$1"
  while : ; do
    _found=""
    for _g in $(_gate_candidates); do
      _consumes "$_g" "$_d" && _found="$_found
$_g"
    done
    if [ -n "$_found" ]; then
      printf '%s\n' "$_found" | grep -v '^$'
      return 0
    fi
    _parent="$(dirname "$_d")"
    case "$_parent" in
      test|.) return 1 ;;
    esac
    _d="$_parent"
  done
}

# ── THE MANIFEST-DERIVED PROJECT SET ─────────────────────────────────────────
#
# "What is a project in this monorepo?" has exactly one answer, and it is not a
# list anybody maintains: a directory with a `medaka.toml`, outside `compiler/`
# (the compiler is a project, but it has its own arms above and its own gates)
# and outside `test/` (those manifests are FIXTURES for the loader's multi-project
# tests, not projects to CI).
#
# This used to be three hand-written case arms — sqlite, gzip, pds — each pasted
# from the last. mq, parsec and byteparser arrived with manifests and gates and
# no arm, so every change to one of them derived ZERO gates and ONE UNMAPPED
# path, which ci.yml then widened to the FULL suite: the most expensive possible
# answer, arrived at by a map gap rather than by blast radius.
#
# Computed ONCE, here, not re-shelled per changed file.
_projects="$(git -C "$ROOT" ls-files '*medaka.toml' 2>/dev/null \
  | grep -v '^test/' | grep -v '^compiler/' \
  | sed 's|/medaka\.toml$||' | sort -u | tr '\n' ' ')"

# Gates that live-reference changed path $1 — the same direct/one-hop scan
# `_gates_for_fixture_dir` uses, but keyed on a PATH rather than on a fixture
# directory, walking the path AND every one of its ancestor directories. Stops
# after the TOP-LEVEL directory (a path with no `/` left), so it can never climb
# to `.` and trivially match every gate in the repo.
#
# ⚠️ This is a UNION over every level, NOT first-match-wins (#1987 F5). It used to
# stop at the first level with any hit, which made a gate that references only an
# ANCESTOR of the changed path invisible the moment a narrower level also matched
# — and the narrower hit did not even have to be a real one. Both live cases:
#
#   playground/e2e/tests/playground.spec.mjs derived exactly ONE gate
#   (diff_compiler_project_enrolment, via a one-hop match on LOCAL_SKIP's
#   `playground/e2e/run` string) and the gate that actually EXECUTES that spec,
#   playground/e2e/run.sh, never surfaced — masked at the file level.
#
#   playground/worker.js matched diff_compiler_wasm_shim_parity at the file level
#   only through that gate's `echo "… expected at least playground/worker.js …"`
#   diagnostic, which short-circuited the climb before the same gate's REAL
#   reference (`grep -rl … "$ROOT/playground"`, one level up) was ever consulted.
#   Same gate, right answer, wrong reason — and any OTHER playground/-level gate
#   would have been lost behind it.
#
# The union costs one extra scan per ancestor level (paths here are 1-4 levels
# deep) and can only ever WIDEN a path's set, which is the safe direction for a
# derivation whose whole failure mode is a silently-missing gate.
#
# This exists for `demo/` and `playground/`: both are graded by real gates, and
# NEITHER is a project (no manifest), so the manifest-derived arm cannot see
# them and a hand-written gate list would be exactly the drift this file spent
# five separate comments arguing against. `playground/` in particular is
# heterogeneous — worker.js is graded by the shim-parity gate, medaka_tokenizer.js
# by the keyword-sync gate, build_playground_wasm.sh by the wasm playground gate
# — so per-file derivation with a directory-level fallback is the only shape that
# is both narrow where it can be and honest where it cannot.
_gates_for_path() {
  _pp="$1"
  _pfound=""
  while : ; do
    for _g in $(_gate_candidates); do
      case "$_pfound" in
        *"
$_g
"*) continue ;;
      esac
      _consumes "$_g" "$_pp" && _pfound="$_pfound
$_g
"
    done
    case "$_pp" in
      */*) _pp="$(dirname "$_pp")" ;;
      *)   break ;;
    esac
  done
  [ -n "$_pfound" ] || return 1
  printf '%s' "$_pfound" | grep -v '^$'
  return 0
}

# ── UNMAPPED: a changed path that hits NO arm of the table below ─────────────
#
# The table is a semantic map (path → the gates that could plausibly notice a change
# there). Plenty of real paths are outside it: Makefile, .github/**, test/run_gates.sh,
# test/CI-COVERAGE-*.txt, compiler/entries/**, .claude/**, playground/**, and every
# prose .md. Locally that is harmless — preflight is a filter, and an unmapped file
# just contributes no gates.
#
# But the moment a CONSUMER uses this derivation to decide what to SKIP, "contributes
# no gates" and "I have no opinion about this file" become dangerously different
# answers, and this script was returning the first for both. So it now says which
# files it had no opinion about. .github/workflows/ci.yml reads this list and refuses
# to narrow a PR run when anything on it is not provably prose — i.e. an unmapped file
# widens CI back to the full suite rather than silently shrinking it.
#
# It is also a genuine local finding: `compiler/entries/*.mdk` (the oracle probe
# sources) hits no arm, so a change there derives only the snapshot gates today —
# under-running the gates that read the oracle it builds. Being loud about it is how
# that gets fixed rather than forgotten.
unmapped=""
note_unmapped() { case " $unmapped " in *" $1 "*) ;; *) unmapped="$unmapped $1" ;; esac; }

# ── BLAST RADIUS: the changed path is used EVERYWHERE. Run the whole suite. ───
#
# `add 'diff_compiler_*'` was doing double duty here and it is NOT the same thing as
# "the whole suite". That glob selects the 85 test/diff_compiler_*.sh gates and MISSES
# every gate outside the family — build_cmd, the 4 bootstrap_*, the 3 selfcompile_*,
# check_syntax_examples, cross_project_*, manifest_emit, lsp_harness, diff_net,
# diff_native_*, the 4 effect_*_domain, native_fixtures/run, and all 22
# sqlite/test/*oracle. For a prelude change, every one of those is in the blast radius.
#
# So a blast-radius path now raises a distinct FLAG rather than widening a glob. Locally
# it still adds 'diff_compiler_*' (unchanged behaviour — preflight is a fast filter and
# is explicit that it under-runs). But it SAYS SO, and CI reads the flag and refuses to
# narrow the PR run at all.
full_suite=0
full_reasons=""
mark_full() {
  full_suite=1
  case " $full_reasons " in *" $1 "*) ;; *) full_reasons="$full_reasons $1" ;; esac
  add 'diff_compiler_*'
}

need_fixpoint=0
while IFS= read -r f; do
  case "$f" in
    # ── front-end: everything downstream of it is suspect ──
    compiler/frontend/lexer.mdk)
      add 'diff_compiler_lex*'
      add 'diff_compiler_parse*'; add 'diff_compiler_snapshot*' ;;
    # #1131: parser.mdk/ast.mdk are cited implementing sites in BOTH
    # docs/spec/SHADOW-SEMANTICS.md §3 and docs/spec/DICT-SEMANTICS.md's own
    # enforcement table (`grep -oE 'compiler/[a-zA-Z_/]+\.mdk' docs/spec/*-SEMANTICS.md`),
    # so both spec-conformance gates belong here too.
    compiler/frontend/parser.mdk|compiler/frontend/ast.mdk)
      add 'diff_compiler_parse*'
      add 'diff_compiler_snapshot*'; add 'diff_compiler_fmt'
      # #1110: ast.mdk declares TyConOrigin and mapTyInDecl — the carrier and the
      # traversal BOTH the stamper and the agreement probe walk; parser.mdk mints the
      # OriginBuiltin tuple heads (DICT-SEMANTICS §8 I6.2).
      add 'diff_compiler_origin_agreement'
      add 'diff_compiler_shadow_semantics'; add 'diff_compiler_dict_semantics'; add 'diff_compiler_prelude_shadow_census' ;;
    # #1131: desugar.mdk is a cited DICT-SEMANTICS site.
    compiler/frontend/desugar.mdk)
      add 'diff_compiler_snapshot*'; add 'diff_compiler_eval*'
      add 'diff_compiler_dict_semantics' ;;
    # #1131: resolve.mdk is a cited DICT-SEMANTICS site (marker.mdk is cited in
    # neither table — derived via the same grep, not assumed from the issue's
    # "plausibly").
    # #1110: resolve.mdk OWNS the two origin stampers and the agreement tap they are
    # observed through, so it is the primary subject of diff_compiler_origin_agreement.
    # #1319 unit 0: resolve.mdk expands every import spelling into the name set it
    # binds and attributes each to a module — the fact every import-clause ordering
    # defect in the tracker (#733/#1253/#1284) is decided by. Goldens cannot see an
    # over-widening there; the permutation differential can.
    compiler/frontend/resolve.mdk|compiler/frontend/marker.mdk)
      add 'diff_compiler_resolve*'; add 'diff_compiler_snapshot*'; add 'diff_compiler_check*'
      add 'diff_compiler_origin_agreement'
      add 'diff_compiler_import_order'
      # G-0: the SAME argument on a different axis. resolve/marker decide which
      # interface an occurrence of a shared method name belongs to, so they own the
      # interface-DECLARATION-order dependence the way they own the clause-order one.
      add 'diff_compiler_iface_order'
      # #1608, same argument as the compiler/types/* arm: marker.mdk decides which
      # occurrences become EMethodRef and therefore which ones can carry a route at
      # all, so it owns the one gate that grades route CONSUMPTION on the typed
      # multi-module path.
      add 'diff_compiler_core_ir_typed_modules'
      add 'diff_compiler_dict_semantics' ;;
    compiler/frontend/exhaust.mdk)
      add 'diff_compiler_exhaust'; add 'diff_compiler_check_match' ;;

    # ── types ── (also the TYPES snapshot family: typecheck.mdk renders the
    #    `# TYPES` section of test/snapshots/typecheck{,_panic}_fixtures, #81 R5)
    #
    # diff_compiler_engines is included here too (#489): typecheck.mdk STAMPS the
    # dispatch routes (impl keys, dict wiring) that all three engines consume at
    # runtime, so a types/ bug can move cross-engine agreement WITHOUT touching any
    # engine's own file. PR #460 was exactly this — a typecheck.mdk-only fix for a
    # build-vs-run divergence — and `gates (engines)` ran 17s / 0 gates on it, because
    # this arm did not derive it. diff_compiler_typecheck*/snapshot*/check*/eval_typed*
    # compare against captured GOLDENS, which cannot see "eval and native now disagree
    # with each other" — only "output changed from what was recorded". Only
    # diff_compiler_engines asks the cross-engine question directly.
    # #1131: typecheck.mdk is a cited implementing site in BOTH
    # docs/spec/SHADOW-SEMANTICS.md §3 and docs/spec/DICT-SEMANTICS.md's own
    # enforcement table — the conformance gates for the class of defect this
    # subsystem produces, and the ones a `check*`/`snapshot*`/goldens-only diff
    # cannot see (they compare against captured output, not the spec).
    compiler/types/*)
      add 'diff_compiler_typecheck*'; add 'diff_compiler_snapshot*'
      add 'diff_compiler_check*'; add 'diff_compiler_exhaust'
      add 'diff_compiler_diagnostics'; add 'diff_compiler_eval_typed*'
      add 'diff_compiler_engines'
      add 'diff_compiler_shadow_semantics'; add 'diff_compiler_dict_semantics'; add 'diff_compiler_prelude_shadow_census'
      # #1110: typecheck.mdk hosts BOTH ends of the resolve->typecheck channel
      # (checkProgramSeededSplit on the flat path, elaborateModules on the graph
      # path) — i.e. two of the three arms the agreement table compares.
      add 'diff_compiler_origin_agreement'
      # #1319 unit 0: typecheck.mdk owns universeDataEnv, universeRecordByName and
      # the A-2.6 import-scoped overlay — the tables whose keying decides which
      # declaration an import clause's constructor name lands on.
      add 'diff_compiler_import_order'
      # G-0: typecheck.mdk is where the interface-declaration-order dependence was
      # MEASURED and written down — grep 'interface declarations SWAPPED' in it. It
      # attributes an unmet obligation to the LAST-DECLARED interface, which is the
      # mechanism both ledgered rows of the interface-order differential record.
      add 'diff_compiler_iface_order'
      # #1608: elaborateModules is what STAMPS the routes on the graph path, and
      # diff_compiler_core_ir_typed_modules is the only gate that grades a route
      # being CONSUMED there — its own positive control is "remove elaborateModules
      # from the driver and watch the typed arm fall back to arg-tag". The rest of
      # the diff_compiler_core_ir* family runs the UNTYPED path and is structurally
      # blind to this; it is not selected by this arm and would not cover it.
      add 'diff_compiler_core_ir_typed_modules'
      # (found deriving this row) diff_compiler_analyze_project pins DIAGNOSTICS —
      # analyzeProject's per-file bucketed severity/message output, the channel the
      # value-golden gates above (typecheck*/check*/eval_typed*) cannot see because
      # they compare a computed VALUE, not what got reported and to which file. It
      # exercises analyzeProject (compiler/driver/diagnostics.mdk), a driver distinct
      # from both checkProgramSeededSplit and elaborateModules, through its own
      # per-module resolve+typecheck+exhaust-oracle-seed call site with no
      # A-2.11/A-2.12 override above it. It hosts the #1554 control
      # (analyze_project_fixtures/1554_ctor_overlay_oracle_control) for the
      # import-scoped ctor overlay this arm's #1319 note above already flags as
      # typecheck.mdk-owned — that regression went undetected by every gate this
      # arm already listed. Listed in ci.yml's `types` shard pattern, so it runs at
      # the merge queue; missing here it ran neither locally nor on the PR check.
      add 'diff_compiler_analyze_project'
      # S-arity-census: derives call/define arity skew from emitted LLVM IR —
      # typecheck.mdk's usesImplDict decides whether a dict param exists at all
      # (the #1648 half), so a types/* change can move it without touching backend/*.
      add 'diff_compiler_call_arity'
      # #2186: a compiler/types/* change can silently drain a must-fail pin
      # (an ill-typed program that used to be rejected starts being accepted)
      # without touching diff_compiler_must_fail.sh's own sources or corpus
      # (test/gates.toml's row keys it to test/diff_compiler_must_fail.sh and
      # test/must_fail_fixtures only) — so gates.toml's corpus-membership
      # mapping under-selects it and a local preflight run misses the exact
      # defect class this arm exists to catch. Q1's incidental drain reaching
      # the review round undetected by a local run is the concrete incident.
      add 'diff_compiler_must_fail' ;;

    # ── THE THREE ENGINES ─────────────────────────────────────────────────────
    #
    # diff_compiler_engines is the differential that proves eval == native == wasm on
    # the SAME programs (it found 4 bug classes on its first run). Its subject is not a
    # directory — it is the three engines themselves, and each one has an owning arm:
    #
    #     eval    -> compiler/eval/* , compiler/ir/core_ir_eval.mdk
    #     native  -> compiler/backend/llvm_emit.mdk
    #     wasm    -> compiler/backend/wasm_emit.mdk
    #
    # ...and compiler/ir/* is the Core IR lowering that FEEDS two of the three, so a
    # change there moves what the differential compares just as directly. compiler/
    # types/* is a FOURTH owner, above, NOT listed in this trio — it doesn't execute
    # any engine, it STAMPS what all three execute (the dispatch routes), which is why
    # it needed its own explanation rather than fitting this "each engine has an arm"
    # framing (#489). Treat this list as "known owners found so far", not exhaustive:
    # compiler/frontend/desugar.mdk and compiler/ir/core_ir_lower.mdk are other
    # route/shape-feeding candidates worth auditing the same way.
    #
    # None of the three engine arms derived it (#402). A WasmGC emitter change derived
    # the llvm, core_ir and snapshot gates and NOT the gate whose entire job is to
    # notice that the wasm engine now disagrees with the other two. It is the
    # exclusion this file's own rule warns about — "when in doubt, run MORE" — and
    # ci.yml's: "a gate wrongly INCLUDED costs CI minutes, which are free on a public
    # repo. A gate wrongly EXCLUDED is a bug that reaches the queue."
    #
    # The CI cost is close to nil: `engines` owns its runner alone, so it is wall-clock
    # parallel with the shard a types/backend/eval/ir change is already paying for
    # (types is the actual critical-path shard; engines is not on it). Locally it
    # costs nothing at all — LOCAL_SKIP drops it below the PREFLIGHT_DRY exit, which
    # is the whole point of that block.

    # ── eval: also the in-language suite and the capability matrix ──
    # diff_compiler_snapshot* covers diff_compiler_snapshot_eval, whose `# EVAL`
    # section is produced by the eval pipeline — an eval.mdk change moves it.
    # #1131: eval/eval.mdk is a cited site in BOTH semantics tables.
    compiler/eval/*|compiler/ir/core_ir_eval.mdk)
      add 'diff_compiler_eval*'; add 'diff_compiler_snapshot*'; add 'diff_compiler_core_ir*'
      add 'diff_compiler_ported'; add 'diff_compiler_test'; add 'diff_compiler_capability_matrix'
      add 'diff_compiler_engines'
      add 'diff_compiler_shadow_semantics'; add 'diff_compiler_dict_semantics'; add 'diff_compiler_prelude_shadow_census' ;;

    # #1131: ir/core_ir_lower.mdk (SHADOW) and ir/core_ir.mdk (DICT) are both
    # cited sites under compiler/ir/*.
    compiler/ir/*)
      add 'diff_compiler_core_ir*'; add 'diff_compiler_llvm*'; add 'diff_compiler_snapshot*'
      add 'diff_compiler_draft_semantic'
      add 'diff_compiler_anf_identity'
      add 'diff_compiler_engines'
      add 'diff_compiler_shadow_semantics'; add 'diff_compiler_dict_semantics'; add 'diff_compiler_prelude_shadow_census'
      # S-arity-census: derives call/define arity skew from emitted LLVM IR —
      # core_ir_lower.mdk's methodArgTys decides declared arity for the #1034 half,
      # so an ir/* change can move it without touching backend/*.
      add 'diff_compiler_call_arity' ;;

    # ── backend: the FIXPOINT is the decisive gate; do not defer it to CI ──
    #
    # diff_compiler_tmc_parity is here and NOT on the arms above: it proves both backends
    # TMC the SAME functions, and the shared analysis it guards (backend/trmc_analysis.mdk)
    # plus both emitters that consume it all live under this arm. It self-provisions its
    # own emit probes, so it needs no oracle wiring here.
    # #1131: llvm_emit.mdk/wasm_emit.mdk (both tables) and private_mangle.mdk
    # (SHADOW) are all cited sites under compiler/backend/*.
    compiler/backend/*)
      add 'diff_compiler_llvm*'; add 'diff_compiler_build'; add 'diff_compiler_core_ir*'
      add 'diff_compiler_capability_matrix'
      add 'diff_compiler_engines'; add 'diff_compiler_tmc_parity'
      add 'diff_compiler_shadow_semantics'; add 'diff_compiler_dict_semantics'; add 'diff_compiler_prelude_shadow_census'
      # #1319 unit 0: private_mangle.mdk keeps its OWN ctor-import index — a
      # separate order-observable structure from typecheck's, and #674's root cause
      # was the two disagreeing. The permutation gate grades the `build` arm, so it
      # is the one differential that can see the mangler decide by clause order.
      add 'diff_compiler_import_order'
      # S-arity-census: derives call/define arity skew from emitted LLVM IR —
      # the exact instrument a backend change could silently defeat.
      add 'diff_compiler_call_arity'
      need_fixpoint=1 ;;

    # #1131: driver/loader.mdk is a cited DICT-SEMANTICS site.
    # #1319 unit 0: loader.mdk owns the dependency walk and topo sort — the module
    # ORDER every table downstream is populated in.
    compiler/driver/*)
      add 'diff_compiler_check*'; add 'diff_compiler_diagnostics'; add 'diff_compiler_build'
      add 'diff_compiler_import_order'
      # G-0: same reason — the loader fixes the order every downstream table is
      # populated in, interface declarations included.
      add 'diff_compiler_iface_order'
      add 'diff_compiler_dict_semantics'
      add 'diff_compiler_fmt_write_safety'
      # driver/diagnostics.mdk is where analyzeProject/analyzeProjectToLines are
      # DEFINED (not just called) — the driver diff_compiler_analyze_project diffs
      # against the OCaml oracle. Narrower than the compiler/types/* row's reason
      # (that arm gets it because typecheck.mdk STAMPS what analyzeProject reports;
      # this row gets it because this file IS analyzeProject's own implementation) ;
      # still absent from this arm before this change for the same reason it was
      # absent from types/* — grep 'analyze_project' test/preflight.sh (pre-fix) had
      # zero hits.
      add 'diff_compiler_analyze_project' ;;
    compiler/tools/lint*.mdk)      add 'diff_compiler_lint*' ;;
    compiler/tools/fmt.mdk|compiler/tools/printer.mdk) add 'diff_compiler_fmt'; add 'diff_compiler_snapshot*' ;;
    compiler/tools/lsp.mdk)        add 'diff_compiler_lsp*' ;;
    compiler/tools/snapshot.mdk)
                                   add 'diff_compiler_snapshot*' ;;
    compiler/tools/repl.mdk)       add 'diff_compiler_repl' ;;
    # #1131: tools/test_cmd.mdk (matched by the `*test*` glob below) is a
    # cited DICT-SEMANTICS site.
    # #1110: test_cmd.mdk is the driver the agreement probe's `single` arm mirrors
    # (elaborateModules over [("__user__", decls)]), so a change to how it elaborates
    # moves which module id that arm claims.
    compiler/tools/*test*|compiler/tools/doctest.mdk|compiler/tools/prop_runner.mdk)
      add 'diff_compiler_test'; add 'diff_compiler_ported'
      # #1229: diff_compiler_test_typecheck.sh pins the typecheck-first gate in
      # test_cmd.mdk's doctestGate — including the zero-doctest cell, whose whole
      # failure mode is exit 0 with no output, i.e. invisible to every golden gate.
      add 'diff_compiler_test_typecheck'
      add 'diff_compiler_origin_agreement'
      add 'diff_compiler_dict_semantics'
      # #81 Stage 4: diff_compiler_test_native.sh is the CI gate protecting the
      # native-engine half of this arm (`medaka test --native` / `--engines`);
      # without this line a change to test_cmd.mdk derives a gate set that omits
      # the one gate that would catch it regressing native doctest execution.
      add 'diff_compiler_test_native' ;;
    # #2191 (S-4-gate-verify): gate_cmd.mdk implements `medaka gate verify`/
    # `explain` — a change here moves the registry drift gate's OWN behavior.
    # It is ALSO an ordinary compiler/tools/*.mdk file, so it must keep the
    # catch-all's `diff_compiler_check*` line too — a bare single-`add` arm
    # here would silently shadow the catch-all below (`case` is first-match-
    # wins) and reintroduce the exact under-selection class this gate exists
    # to catch (found by end-of-sprint review, gate-registry sprint #2176).
    compiler/tools/gate_cmd.mdk)
      add 'diff_compiler_gate_registry'
      add 'diff_compiler_ci_gen_drift'
      # #2177 (S-4-coverage-authority): the coverage gate now reads
      # `medaka gate list --json` for shard membership instead of parsing
      # ci.yml's matrix, and `medaka gate explain --prose` is what the prose
      # drift gate diffs ci.yml against — both are this file's behavior now.
      add 'diff_compiler_ci_shard_coverage'
      add 'diff_compiler_prose_classifier'
      # #2178 (S-3-S-balancer): `medaka gate balance` lives here too, so a
      # change to this file moves the balancer's own gate.
      add 'diff_compiler_gate_balance'
      add 'diff_compiler_check*' ;;
    # #2178 (S-3-S-balancer): the cost-baseline READER the balancer joins on.
    # Same shadowing rule as gate_cmd.mdk above — it is also an ordinary
    # compiler/tools/*.mdk file, so it must keep the catch-all's
    # `diff_compiler_check*` line or this arm silently narrows it away.
    compiler/tools/gate_cost.mdk)
      add 'diff_compiler_gate_balance'
      add 'diff_compiler_check*' ;;
    compiler/tools/*)              add 'diff_compiler_check*' ;;

    # ── the compiler's private mini-stdlib: used by every stage. ──
    compiler/support/*)            mark_full 'compiler/support' ;;

    # ── the oracle probe SOURCES. Changing one changes the BINARY the gates read. ──
    # There was no arm for these at all, so `compiler/entries/eval_main.mdk` derived
    # only the snapshot gates — i.e. preflight would rebuild the very probe that
    # diff_compiler_eval reads and then not run diff_compiler_eval.
    compiler/entries/*)            mark_full 'compiler/entries' ;;

    # ── stdlib / runtime: BLAST RADIUS. This arm used to be the narrowest in the file. ──
    #
    # It derived FIVE gates for `stdlib/core.mdk` — the IMPLICIT PRELUDE, prepended to
    # every program the compiler ever sees. A change there moves essentially every
    # golden in the tree (eval, core_ir, llvm, engines, typecheck, check, build, …), and
    # preflight would have reported green having run lexer + snapshot + doctests.
    # AGENTS.md already says this in prose — "stdlib/core.mdk → it is used *everywhere*;
    # the blast radius genuinely is the whole suite" — the map just never agreed with it.
    #
    # The whole of stdlib/, not just core: `medaka build` links the entire stdlib root
    # into every binary, `runtime.mdk` is the extern catalog every engine reads, and
    # since 2026-06-29 the COMPILER ITSELF imports stdlib (support/ordmap.mdk wraps
    # stdlib `Map`), so `stdlib/map.mdk` is transitively compiler source. runtime/ is the
    # C runtime linked into every binary. There is no narrow answer here that is true.
    stdlib/*|runtime/*)            mark_full 'stdlib-or-runtime' ;;

    # ── a changed GATE SCRIPT runs itself ─────────────────────────────────────
    #
    # ⚠️ CASE-ARM ORDER IS LOAD-BEARING, AND THIS ARM MUST STAY ABOVE THE CORPUS ARM.
    # `test/native_fixtures/run.sh` matches BOTH this arm and `test/*fixtures*/*` below,
    # and in a `case` the FIRST match wins. The split is deliberate and is the whole rule:
    #
    #     you changed a GATE      -> run that gate
    #     you changed a FIXTURE   -> derive the gates that CONSUME that fixture dir
    #
    # Not covered by the corpus derivation, and not redundant with it: the derivation
    # answers "who READS this corpus", which is a different question from "I edited this
    # gate's own code".
    #
    # The pattern is the repo-relative path minus `.sh`, minus a leading `test/` —
    # 'diff_compiler_lexer', 'native_fixtures/run', 'build_cmd'. run_gates.sh,
    # build_oracles.sh --for and the coverage gate all resolve a slash-bearing pattern
    # from the repo ROOT, so these are exactly the names CI's shards use.
    #
    # ── …but ONLY if the gate still EXISTS (#337) ────────────────────────────
    # `changed` (see the `git diff --name-only` at the top) lists DELETED paths too,
    # and a deleted gate script derives a gate NAME with no backing script — which the
    # "matches NO gate" guard below then treats as a broken map and ABORTS on. That is
    # a false positive: the map is fine, the gate is simply gone. You cannot run a gate
    # that does not exist, and its absence is not a coverage gap in YOUR diff.
    #
    # This bites hardest via a STALE LOCAL `main`: `git diff main...HEAD` forks at an old
    # merge-base, so every gate deleted on main since then reads as "deleted by you".
    # That is exactly how #337 reproduced — `test/diff_compiler_check_modules_batch.sh`,
    # deleted in 00afa27d, aborted `make preflight` for agents who had never heard of it.
    #
    # Derived from the filesystem, NOT an exception list: nothing here is named, so this
    # cannot drift the way a hand-maintained skip list would.
    test/diff_compiler_*.sh|test/build_cmd.sh|test/native_fixtures/run.sh)
      _p="${f#test/}"
      if [ -f "$ROOT/$f" ]; then
        add "${_p%.sh}"
      else
        echo "preflight: note — gate '${_p%.sh}' is DELETED in this diff; nothing to run for it."
      fi ;;

    # ── the snapshot corpus: goldens, but NOT in a *fixtures*/*goldens* directory ──
    #
    # `_fixture_dir_for` only fires for a path with a `*fixtures*`/`*goldens*` ancestor,
    # and `test/snapshots/{compiler,stdlib,...}` has neither — so these 167 golden .md
    # files hit NO arm at all. That is not a corner case: AGENTS.md REQUIRES the moved
    # snapshot be blessed in the SAME COMMIT as the source change that moved it, so the
    # single most common compiler PR in this repo carries one. Leaving them unmapped
    # makes every such PR look like "I have no opinion about this file".
    #
    # Only the snapshot gates read them, and they read the tree as a whole (SNAPDIR),
    # never a per-file path — so the answer is the same for every file under it.
    test/snapshots/*)              add 'diff_compiler_snapshot*' ;;

    # ── #1319 unit 0: the import-order ledger, which `_fixture_dir_for` cannot see ──
    # It is a loose file under test/, not inside a `*fixtures*` directory, so the
    # corpus derivation never fires for it. This arm matters more than most: the
    # ledger is precisely the file someone edits ALONE when this gate goes red, and
    # a preflight that derives NOTHING from a ledger edit is the masking path the
    # ledger's own header warns about.
    # ── #2066: the shared shape library, which no other arm can see ───────────
    # test/perf_shapes.sh is `.`-sourced (not `sh`-invoked) by two gates, so neither the
    # gate-script arm above nor `_gates_for_path`'s one-hop `_invokes` scrape — which is
    # anchored on the `sh "$ROOT/test/…` idiom, deliberately — can reach it. Left
    # unmapped it is not merely under-run: an UNMAPPED non-prose path widens the whole PR
    # run back to the full suite ([W-THIRD-CONSUMER]), so the gap costs the most expensive
    # possible answer while proving nothing about the two gates that actually read it.
    # Derive the consumer set before editing this arm: `grep -rln perf_shapes.sh test/`.
    test/perf_shapes.sh)           add 'diff_compiler_perf_scaling'
                                   add 'diff_compiler_ir_scaling' ;;
    test/IMPORT-ORDER-LEDGER.txt)  add 'diff_compiler_import_order' ;;
    # Same argument again: the sidecar emitter-verdict ledger is also a loose file
    # under test/ that `_fixture_dir_for` cannot see, and it feeds the SAME gate
    # (RUN-XMOD-022/023, packet L1-L2-driver-asymmetry-observation).
    test/EMITTER-VERDICT-LEDGER.txt) add 'diff_compiler_import_order' ;;
    # Same argument, same shape, second axis (G-0). Both ledgers are loose files
    # under test/ that `_fixture_dir_for` cannot see, and both are exactly what
    # someone edits ALONE when their gate goes red.
    test/IFACE-ORDER-LEDGER.txt)   add 'diff_compiler_iface_order' ;;
    # #2191 (S-4-gate-verify): the registry itself. A loose file under test/
    # that `_fixture_dir_for` cannot see (no *fixtures*/*goldens* ancestor),
    # and exactly what someone edits ALONE when enrolling or fixing a gate.
    # (S-4-coverage-authority adds the coverage gate: a `shard` field edited
    # here is now the ONLY thing that decides shard membership.)
    # (#2178, S-3-S-balancer adds the balancer: `shard` is the field it derives,
    # so the registry is both its input and the file it rewrites.)
    test/gates.toml)               add 'diff_compiler_gate_registry'; add 'diff_compiler_ci_gen_drift'; add 'diff_compiler_ci_shard_coverage'; add 'diff_compiler_gate_balance' ;;
    # #2177 (S-3-generation-drift-gate): the per-shard rationale files that feed
    # `medaka gate ci`'s generated gates-matrix region. Not read by anything
    # else — a loose file under test/ that someone edits ALONE when adding a
    # gate to a shard.
    test/gate_shards/*)            add 'diff_compiler_ci_gen_drift' ;;
    # #2178 (S-1-S-cost-record): the per-gate cost transport. Two loose files
    # under test/ that `_fixture_dir_for` cannot see — the ingest TOOL (in
    # CI-COVERAGE-TOOLS.txt, so it is not a gate candidate and derives nothing
    # by itself) and the committed baseline .json it writes. Both are exactly
    # what someone edits ALONE when re-ingesting timings, and an UNMAPPED
    # non-prose path widens the whole PR run to the FULL suite
    # ([W-THIRD-CONSUMER]) — the most expensive possible answer for a file whose
    # only consumer is one millisecond-cost gate.
    # (#2178, S-3-S-balancer: the baseline is ALSO the balancer's cost input —
    # re-ingesting timings can move every shard assignment, so the balancer's
    # gate has to run on a baseline change, not just the transport's.)
    test/gate_cost_ingest.sh|test/gate_cost_baseline.json)
                                   add 'diff_compiler_gate_cost'
                                   add 'diff_compiler_gate_balance'
                                   add 'diff_compiler_ci_gen_drift' ;;
    # FR-3 (fix round, S1-1/S3-5): the nightly auto-advance TOOL (in
    # CI-COVERAGE-TOOLS.txt, so it is not a gate candidate either). It shares
    # the ingest/balance/gen-ci gates above (it calls all three), plus the two
    # checks that police its OWN classification: `medaka gate verify`'s
    # unenrolled-script scan and the CI-reachability ledger — the gap that let
    # this exact file go unclassified until the fix round caught it.
    test/gate_cost_collect.sh)
                                   add 'diff_compiler_gate_cost'
                                   add 'diff_compiler_gate_balance'
                                   add 'diff_compiler_ci_gen_drift'
                                   add 'diff_compiler_gate_registry'
                                   add 'diff_compiler_ci_shard_coverage' ;;
    # S2-5 (end-of-sprint review, #2177): the generated file itself had no arm
    # at all, so a change here fell through to the catch-all — the two gates
    # that actually police its generated content are the ones that read it.
    .github/workflows/ci.yml)      add 'diff_compiler_ci_gen_drift'; add 'diff_compiler_ci_shard_coverage' ;;
    docs/guide/*.md)               add 'check_syntax_examples' ;;
    # Third ledger, same structural blind spot (#1608). Its rows pin a WRONG VALUE
    # rather than a divergence — see its own header — but the masking path is
    # identical: a loose file under test/ that someone edits ALONE when the gate reds.
    test/CORE-IR-TYPED-LEDGER.txt) add 'diff_compiler_core_ir_typed_modules' ;;
    # Fourth ledger, same structural blind spot: a loose file under test/ that
    # `_fixture_dir_for` cannot see, and exactly what someone edits ALONE when
    # the wrapper-callers gate reds (S-migrate-tool-consumers-remainder).
    test/CHECK-WRAPPER-CALLERS.txt) add 'diff_compiler_check_wrapper_callers' ;;

    # #1315: engine value pins (`test/engine_value_pins/<corpus>/<name>.pin`, e.g.
    # `test/engine_value_pins/llvmM/foo.pin`) are the same structural blind spot as
    # the three ledgers above — a corpus `_fixture_dir_for` cannot see, since none
    # of `engine_value_pins` or its corpus subdirs (`llvm`, `llvmT`, `llvmM`, `wasm`,
    # `engine`) contain "fixtures" or "goldens" as a path substring. A pin-only diff
    # therefore fell through to the catch-all and was reported UNMAPPED — locally
    # invisible (green having graded nothing), even though CI's `detect` job
    # correctly escalated the unmapped path to the full suite (confirmed on #1297).
    # `diff_compiler_engines.sh` reads every `$PINDIR/$key.pin` on its PINFAIL path
    # (PINDIR="$ROOT/test/engine_value_pins") regardless of corpus, so it is the one
    # gate that reads the WHOLE tree unconditionally — map here.
    #
    # `diff_compiler_capability_matrix.sh` also touches pin paths, but only for
    # BOUNDARY-listed keys under corpora its own `fixdir_of` recognizes (llvm,
    # llvmT, wasm, wasmT) — `llvmM` is NOT one of them, so a `llvmM/*.pin` change is
    # genuinely invisible to that gate today (verified by reading `fixdir_of`
    # directly, not by trusting this claim). Not added here: mapping it would be
    # over-broad for the common `llvmM` case and, for the reachable corpora, the
    # gate only checks the pin's mere EXISTENCE (`[ ! -f "$pin" ]`), never its
    # value — `diff_compiler_engines` is the gate that actually exercises content.
    test/engine_value_pins/*)      add 'diff_compiler_engines' ;;

    # ── fixture/golden corpus change: run its ACTUAL consumers, not everything.
    # See _gates_for_fixture_dir above. A directory with zero discoverable
    # consumers is a real finding (dead corpus, or a gap in this derivation) —
    # loudly fall back to the full suite rather than silently running nothing.
    #
    # T8 note: this now composes with the gates that do not live in test/. The
    # derivation scans the FULL gate universe (see _gate_candidates), so
    # `test/native_fixtures/*.mdk` correctly derives `native_fixtures/run` and
    # `test/build_cmd_fixtures/*` correctly derives `build_cmd` — no explicit arm
    # needed for either, and none is present. Before the universe was widened, both
    # corpora had ZERO discoverable consumers and hit the full-suite fallback.
    test/*fixtures*/*|test/*goldens*/*)
      _fdir="$(_fixture_dir_for "$f")" || _fdir=""
      if [ -z "$_fdir" ]; then
        echo "preflight: WARNING — could not identify a fixture directory for '$f'; falling back to the FULL suite."
        mark_full "unidentifiable-fixture-dir:$f"
      else
        _gset="$(_gates_for_fixture_dir "$_fdir")"
        # A corpus DELETED in this diff has no consumers because it no longer exists —
        # that is not the "dead fixture or derivation gap" the warning below diagnoses,
        # and widening to the full suite over it is pure cost (#337). Same stale-`main`
        # trigger as the deleted-gate arm above: test/core_ir_sexp_fixtures, removed in
        # b5170cab by the snapshot migration, dragged agents into the full gate suite.
        # `_fixture_dir_for` is purely lexical, so it happily names a dir that is gone.
        if [ ! -d "$ROOT/$_fdir" ]; then
          echo "preflight: note — fixture dir '$_fdir' is DELETED in this diff; nothing to run for it."
        elif [ -z "$_gset" ]; then
          echo "preflight: WARNING — '$_fdir' has NO discoverable consumer (checked live references across every tracked gate script in the repo — every .sh not excluded by test/CI-COVERAGE-TOOLS.txt, a universe that now includes sqlite/test/, test/native_fixtures/ and playground/e2e/ — including one hop through any helper script a gate invokes). This is either a DEAD fixture directory or a gap in this derivation — investigate '$_fdir'. Falling back to the FULL suite for safety."
          mark_full "no-consumer:$_fdir"
        else
          # Report each fixture dir ONCE, however many of its files changed. Adding a
          # .mdk plus its .expected golden is the normal case and printed the same
          # derivation line twice, which reads like the derivation ran twice.
          case " ${_reported_dirs:-} " in
            *" $_fdir "*) ;;
            *) _reported_dirs="${_reported_dirs:-} $_fdir"
               printf 'preflight: %s → %s\n' "$_fdir" \
                 "$(printf '%s\n' "$_gset" | xargs -n1 basename | tr '\n' ' ')" ;;
          esac
          for _g in $_gset; do
            # Repo-relative, minus a leading `test/`, minus `.sh` — the same two-step
            # form the manifest-keyed arm below uses, and for the same reason (#1992):
            # `_gate_candidates` yields EVERY tracked .sh in the repo, not just
            # test/*.sh, so stripping `$ROOT/test/` alone leaves a gate outside test/
            # (sqlite/test/*_oracle.sh, playground/e2e/run.sh) as an ABSOLUTE path,
            # which resolves to no gate and trips the "matches NO gate" hard-fail
            # below. Latent today only because no such gate consumes a
            # *fixtures*/*goldens* corpus yet — one arriving must not red this arm.
            _pat="${_g#"$ROOT"/}"
            _pat="${_pat#test/}"
            add "${_pat%.sh}"
          done
        fi
      fi ;;

    # ── ONE generic arm for every MANIFEST-BEARING PROJECT ────────────────────
    #
    # sqlite, gzip and pds used to have three hand-pasted arms here; mq, parsec and
    # byteparser had none and were UNMAPPED. All six are now derived from
    # `$_projects` (see its definition above) — the same `git ls-files '*medaka.toml'`
    # rule ci.yml and diff_compiler_project_enrolment.sh use, so the three consumers
    # of "what is a project" cannot drift apart silently.
    #
    # WHY AN ARM IS NEEDED AT ALL (the reasoning the three old banners carried, and
    # it is unchanged): `_fixture_dir_for` only fires for a path with a
    # `*fixtures*`/`*goldens*` ANCESTOR directory. No project has one — every
    # project's goldens and vector corpora sit loose in `<project>/test/`, next to
    # the oracles that read them — so the corpus derivation below can never trigger
    # for them and they would derive NOTHING. That is not a redundant arm; it is the
    # only thing standing between "edit the SQLite library" and "preflight runs
    # nothing about it and prints green" (#1333).
    #
    # `<project>/test/*` and not `<project>/test/*oracle`: the arm does not need to
    # know each project's gate-naming convention (sqlite/gzip name theirs
    # `*_oracle.sh`, pds and the three new projects do not), only that all of a
    # project's committed gates live under `<project>/test/`. Verified equivalent on
    # today's tree: every tracked sqlite/test/*.sh and gzip/test/*.sh ends in
    # `oracle.sh`, so both globs select the same 24 and 2 gates respectively. Tools
    # that must stay OUT of reach — sqlite/findings/verify_compiler_bugs.sh,
    # pds/tools/*.sh, pds/oracle/run.sh — live outside `<project>/test/` and are
    # naturally excluded.
    #
    # The arm is deliberately `<project>/*`, i.e. as broad as the old `pds/*)` rather
    # than as narrow as the old four-alternative sqlite/gzip arms: an UNMAPPED
    # non-prose path widens every PR run to the FULL suite (ci.yml `detect`), so a
    # narrow arm pays the whole suite for `sqlite/findings/*` or a new
    # `<project>/oracle/` subdir that nobody remembered to add.
    #
    # ── demo/ and playground/: graded, but NOT projects ───────────────────────
    # Neither has a manifest, so neither belongs in `$_projects` — but both are read
    # by real gates, and being UNMAPPED costs the full suite. They get the derived
    # `_gates_for_path` treatment instead of a hand-written gate list: see that
    # function's header for why per-file-with-directory-fallback is the only honest
    # shape for playground/ in particular.
    *)
      _proj=""
      for _pr in $_projects; do
        case "$f" in "$_pr"/*) _proj="$_pr"; break ;; esac
      done
      if [ -n "$_proj" ]; then
        add "$_proj/test/*"
      else
        case "$f" in
          demo/*|playground/*)
            _pgset="$(_gates_for_path "$f")" || _pgset=""
            if [ -z "$_pgset" ]; then
              # No gate in the repo names this path or any ancestor of it. That is a
              # real "no opinion", not a narrow answer — say so rather than inventing
              # a plausible gate list.
              note_unmapped "$f"
            else
              case " ${_reported_paths:-} " in
                *" $f "*) ;;
                *) _reported_paths="${_reported_paths:-} $f"
                   printf 'preflight: %s → %s\n' "$f" \
                     "$(printf '%s\n' "$_pgset" | xargs -n1 basename | tr '\n' ' ')" ;;
              esac
              for _g in $_pgset; do
                # Repo-relative, minus a leading `test/`, minus `.sh` — the pattern
                # form run_gates.sh / build_oracles.sh --for / the coverage gate all
                # resolve. Stripping `$ROOT/test/` alone would leave an ABSOLUTE path
                # for a gate outside test/ (playground/e2e/run.sh), which resolves to
                # nothing and would trip the "matches NO gate" guard below.
                _pat="${_g#"$ROOT"/}"
                _pat="${_pat#test/}"
                add "${_pat%.sh}"
              done
            fi ;;

          # ── no arm matched: record it, do not silently ignore it. See `unmapped` above.
          *) note_unmapped "$f" ;;
        esac
      fi ;;
  esac
done < "$CHANGED_PATHS"

# ── the snapshot corpus is not a fixture dir; it is the SOURCE TREE ──────────
# Every compiler/**.mdk and stdlib/*.mdk is IN the snapshot corpus (each one carries its
# own `# SOURCE` section), so ANY edit to one moves its snapshot — a pure `medaka fmt`
# reflow is enough. That cuts across every arm of the table above, and `case` fires only
# its FIRST matching arm, so it cannot be expressed there: a second pass is the only
# correct shape.
#
# Without this, preflight reported GREEN on (say) a compiler/eval/ change while
# diff_compiler_snapshot_frontend was red — the exact "your change would have been tested
# by NOTHING" failure the gate-existence check below exists to prevent, one level up.
#
# ── the SAME reasoning applies to LEG A of diff_compiler_selfproc (#189) ─────
# LEG A runs the WHOLE compiler/*.mdk source through itself in one union closure
# (compiler/entries/all_modules_entry.mdk forces every module in) and diffs each
# module's inferred schemes against test/selfproc_goldens/legA/<module>.golden.
# ANY compiler/*.mdk change that adds/renames/removes a top-level binding can move
# that module's legA golden — same shape as the snapshot corpus, and for the same
# reason: no single arm of the table above names this gate, so it never fires there.
# Bit #161 and #185 identically (each needed a second rebless commit after CI, not
# preflight, caught it).
#
# stdlib/core.mdk and stdlib/runtime.mdk belong in this trigger too — for a DIFFERENT
# reason than the compiler modules. legA's closure is not just compiler source: the
# harness passes $CORE (stdlib/core.mdk, the implicit prelude) and $RUNTIME
# (stdlib/runtime.mdk, the extern catalog) into check_all_main
# (diff_compiler_selfproc.sh:103 — `"$CHECK_ALL" "$RUNTIME" "$CORE" "$ENTRY" ...`). A
# prelude- or runtime-signature change can therefore shift the inferred schemes of the
# COMPILER modules that reference it, moving a compiler module's legA golden even though
# core/runtime carry no golden of their own (the legA golden set is exactly the 13
# compiler-only dotted mids in MODULES — verified: `ls test/selfproc_goldens/legA/`).
# So the stdlib side of this trigger is scoped to exactly the two files legA loads by
# name. A LEAF stdlib module (map, set, …) is not passed into the closure by name, so it
# gets no entry here; a change to one still reaches selfproc via the blast-radius
# `stdlib/*|runtime/*` arm above (which does `add 'diff_compiler_*'`, matching selfproc).
while IFS= read -r f; do
  case "$f" in
    compiler/*.mdk|compiler/*/*.mdk|stdlib/*.mdk) add 'diff_compiler_snapshot*' ;;
  esac
  case "$f" in
    compiler/*.mdk|compiler/*/*.mdk|stdlib/core.mdk|stdlib/runtime.mdk) add 'diff_compiler_selfproc' ;;
  esac
done < "$CHANGED_PATHS"

# ── the control-byte ratchet applies to EVERY tracked source file (#1987 F4) ──
# diff_compiler_source_bytes.sh scans the whole tree (`git ls-files`, filtered by
# extension) and has no per-file consumer anywhere: no arm of the table above names
# it, and `_gates_for_path` can only reach it when a path happens to be mentioned
# inside the gate's own source (which is how playground/* reaches it today — via the
# gate's `playground/vendor/` exclusion line, by accident rather than by rule).
#
# So before this block, a change to demo/ or to any manifest-derived project
# (mq, parsec, byteparser, sqlite, gzip, pds) derived that gate NEVER. That was a
# real regression against the old UNMAPPED→FULL fallback, which ran it incidentally.
# A CR or a NUL pasted into mq/main.mdk would have reached the merge queue with the
# local loop green.
#
# Unconditional by design, and cheap by construction: the gate re-scans the whole
# tree regardless of what changed, so there is nothing to narrow — the only honest
# derivation is "any change at all". Guarded on $changed being non-empty so an
# empty diff still derives an empty gate set.
#
# ⚠️ This makes source_bytes the one gate a `<project>/` change derives from OUTSIDE
# `<project>/test/`. test/diff_compiler_project_enrolment.sh's PREFLIGHT leg knows
# about it BY NAME (see its UNIVERSAL_GATES) — any OTHER stray gate still fails there.
if [ -s "$CHANGED_PATHS" ]; then
  add 'diff_compiler_source_bytes'
fi

# ── the IN-LANGUAGE suite (`make test`) is NOT a gate, so nothing above can reach it ──
#
# `$gates` is a set of `test/*.sh` scripts run through run_gates.sh. `make test` is a
# different animal: it invokes `./medaka test <file>` directly on a handful of .mdk
# modules, and it is a REQUIRED check of its own (`inlang`). So every arm above can
# fire, every gate can pass, and the doctests of the very file you edited never run.
#
# That is not hypothetical — it is why this block exists. PR #1270 changed
# compiler/types/registry.mdk; `make preflight` was run TWICE, including on the merged
# tree, and could not see that the file's own doctests were red. The gate set it derives
# (25 gates) is correct and none of them run a doctest. The break was a merge artifact
# between two branches that were each green alone, so no pre-merge signal existed
# anywhere except `make test` — the one thing the loop did not call.
#
# The file list is DERIVED from the Makefile's `test:` recipe, never re-listed here.
# That matters more than the saved keystrokes: the Makefile's own comment instructs
# "Add a line here for every call-site-free compiler module", so this list is expected
# to GROW, and a copy here would silently stop covering whatever was added. Scoped to
# the `./medaka test` lines only — the recipe's `sh test/diff_compiler_ported.sh` line
# is a gate and already has arms in the table above.
#
# Cost: measured 0.5s for compiler/types/registry.mdk (144 doctests) on the dev box,
# against a preflight that spends ~1m41s building ./medaka before it runs anything. It
# adds ZERO gates — it is a separate step, like need_fixpoint — so the `would run N
# gate(s)` count is unchanged by design.
inlang_files=$(awk '/^test: medaka$/{f=1;next} f&&/^\t/{print} f&&!/^\t/{exit}' "$ROOT/Makefile" \
  | sed -n 's|^	\./medaka test ||p')
inlang_run=""
while IFS= read -r f; do
  for _if in $inlang_files; do
    [ "$f" = "$_if" ] || continue
    # Only if it still exists — a DELETED module cannot be doctested, and `changed`
    # lists deletions (same reasoning as the gate-self-run arm above, #337).
    [ -f "$ROOT/$f" ] || continue
    case " $inlang_run " in *" $f "*) ;; *) inlang_run="$inlang_run $f" ;; esac
  done
done < "$CHANGED_PATHS"

# ── resolve gates → the ORACLES they actually need ───────────────────────────
#
# ⚠️ A PATTERN THAT MATCHES ZERO GATES IS AN ERROR, NOT AN EMPTY SET.
#
# The change→gate map above hardcodes gate-name globs. When a gate is RENAMED or
# DELETED — which the snapshot migration does, on purpose, family by family — a stale
# glob silently matches NOTHING. The mapped file then resolves to NO GATE AT ALL, and
# preflight cheerfully reports success having tested that file with nothing.
#
# This ALREADY happened: the snapshot migration deleted diff_compiler_{parse,desugar,
# mark,desugar_batch,mark_batch}.sh, and preflight's `'diff_compiler_desugar*'` /
# `'diff_compiler_mark*'` globs went dead. A change to frontend/desugar.mdk would have
# mapped to zero gates and passed.
#
# It is the same bug as `$ROOT/compiler/*.mdk` globbing to zero files after the
# subfolder reorg (which silently dropped the compiler's own sources from the desugar
# corpus), and the same as a gate matching no CI shard. "This didn't run" must never be
# indistinguishable from "this passed."
gates=""
# `set -f` (noglob), NOT just for this outer split: $pats is an unquoted variable
# expansion, so without it a pattern that happens to literally match a real
# on-disk path (e.g. 'pds/test/*', which DOES match pds/test/*.sh files —
# unlike 'sqlite/test/*oracle', which never matches a real filename because
# real oracle files end '_oracle.sh' not literal 'oracle') gets pathname-
# expanded HERE, before the intended two-arm resolution below ever runs —
# corrupting the pattern into an already-extensioned filename that then fails
# the '$pat.sh' suffix the inner loop appends. Found first-hand adding the pds
# arm (S-pds-skeleton): 'sqlite/test/*oracle' and 'gzip/test/*oracle' never
# tripped this because their patterns coincidentally never match a real path.
# `set +f` for the INNER loop, which relies on genuine glob expansion to
# resolve '$pat.sh' against real files.
set -f
for pat in $pats; do
  matched=0
  set +f
  # Resolve against BOTH $ROOT/test/ and $ROOT/ — the same rule run_gates.sh,
  # build_oracles.sh --for and diff_compiler_ci_shard_coverage.sh use, so a pattern
  # naming a gate outside test/ ('sqlite/test/*oracle') resolves identically in all
  # four. Without this arm, preflight's own "matches NO gate" guard fired on the very
  # patterns its change→gate map had just emitted.
  for g in "$ROOT"/test/$pat.sh "$ROOT"/$pat.sh; do
    [ -f "$g" ] || continue
    matched=1
    case " $gates " in *" $g "*) ;; *) gates="$gates $g" ;; esac
  done
  set -f
  if [ "$matched" -eq 0 ]; then
    set +f
    echo "preflight: FAIL — the change→gate map points at '$pat', which matches NO gate."
    # Distinguish the two ways a pattern can match nothing: an EXISTING project's
    # gate was renamed/deleted out from under a stale glob (the historical case,
    # see the derivation's header above), vs. the generic manifest-keyed arm
    # (~line 877, `add "$_proj/test/*"`) firing for a project that has a manifest
    # but has NEVER had a floor gate yet — a brand-new, not-yet-enrolled project.
    # Those are different diagnoses and the wrong one sends the reader looking for
    # a rename that never happened. `diff_compiler_project_enrolment.sh`'s FLOOR
    # check already has the right wording for the second case; match it here.
    _no_floor_proj=""
    for _pr in $_projects; do
      if [ "$pat" = "$_pr/test/*" ]; then
        _no_floor_proj="$_pr"
        break
      fi
    done
    if [ -n "$_no_floor_proj" ] && { [ ! -d "$ROOT/$_no_floor_proj/test" ] || \
        [ -z "$(git -C "$ROOT" ls-files "$_no_floor_proj/test/*.sh" 2>/dev/null)" ]; }; then
      echo "  A project with a manifest and no floor gate cannot be enrolled:"
      echo "  a ci.yml shard pattern matching NO gate is a hard ::error::."
      # ⚠️ The remedy DIFFERS between these two branches, and getting it wrong
      # sends the reader to the wrong file. Here the map is CORRECT — the generic
      # manifest-keyed arm rightly named '$_no_floor_proj/test/*'. What is missing
      # is the gate itself plus its ci.yml shard glob, which is what
      # diff_compiler_project_enrolment.sh's own FLOOR/CI failures already say.
      echo "  Your change would have been tested by NOTHING. The map is right; the"
      echo "  ENROLMENT is incomplete. Add a floor gate under $_no_floor_proj/test/,"
      echo "  then a glob (e.g. '$_no_floor_proj/test/*') to a shard's pattern: in"
      echo "  .github/workflows/ci.yml, chosen by measured cost (sh scripts/ci_shard_cost.sh)."
      echo "  sh test/diff_compiler_project_enrolment.sh checks all three legs."
    else
      echo "  A gate was probably renamed or deleted (the snapshot migration does this)."
      echo "  Your change would have been tested by NOTHING. Fix the map in $0."
    fi
    exit 1
  fi
done
# NOTE: noglob STAYS ON from here to end of script. Every consumer of $pats
# below — the LOCAL_SKIP filter (which REWRITES $pats), the re-resolve, and the
# unquoted `--for $pats` / `run_gates.sh $pats` argument splits — needs word
# splitting but must NEVER pathname-expand a pattern like 'pds/test/*' that
# literally matches real files. `set -f` gives exactly that; `case` patterns are
# unaffected, and it is not inherited by child processes, so build_oracles.sh
# and run_gates.sh still glob normally on their own. RUN-PDS0-006.

# ── PREFLIGHT_DRY=1: print the derived gate set and stop ──────────────────────
# The change→gate derivation is the part most likely to silently under-run, and it was
# the only part with no way to inspect it short of a full 5-minute build+run. Now you
# can ask it what it WOULD run, which is also how the T8/T15 integration cases are
# verified.
#
# It is ALSO what .github/workflows/ci.yml's `detect` job runs to narrow the
# `pull_request` gate run (the `merge_group` run stays FULL). So it must be free —
# no `make medaka`, no oracle build, nothing but the derivation. It runs BEFORE the
# build for exactly that reason; do not move the build back above it.
#
# Three machine-readable prefixes, deliberately stable — CI parses them:
#   GATE      <repo-relative path of a gate this diff selects>
#   UNMAPPED  <changed path the map has NO OPINION about>
#   FULL      <reason this diff has whole-suite blast radius>
# CI narrows a `pull_request` run ONLY when there is no FULL line and every UNMAPPED
# path is provably prose (its own docs allowlist decides that). Anything else widens
# it back to the full suite. `merge_group` is never narrowed, whatever this prints.
#
# ⚠️ EVERYTHING ABOVE THIS EXIT IS A STATEMENT ABOUT THE DIFF, NOT ABOUT THIS BOX (#402).
# CI cannot tell the two apart — it just reads the GATE lines. So a gate this script
# declines to RUN for local cost reasons must still be PRINTED here, and must be dropped
# below, in LOCAL_SKIP. Putting a cost decision above this line silently exports it to
# every PR: `gates (engines)` reported SUCCESS in 5s having run ZERO gates on every
# backend PR because `diff_compiler_engines` was "locally skipped" by being absent from
# the map that CI reads.
if [ -n "${PREFLIGHT_DRY:-}" ]; then
  printf '── would run %s gate(s) ─────\n' "$(printf '%s\n' $gates | grep -c .)"
  for g in $gates; do printf '  GATE      %s\n' "${g#"$ROOT"/}"; done
  if [ "$full_suite" -eq 1 ]; then
    printf '── BLAST RADIUS: this diff touches something used everywhere ─────\n'
    for r in $full_reasons; do printf '  FULL      %s\n' "$r"; done
    # DERIVED, never hand-written: this line is program OUTPUT, so a stale cardinal
    # here is a lie told on every blast-radius run, not just to a comment reader.
    # ⚠️ noglob (`set -f`) is ON from the pattern resolver to the end of this script,
    # so the glob is expanded in a subshell that turns it back off — otherwise this
    # counts `1`, the literal unexpanded pattern.
    printf '  (locally that means all %s diff_compiler_* gates; in CI it means the whole suite.)\n' \
      "$(set +f; ls "$ROOT"/test/diff_compiler_*.sh 2>/dev/null | grep -c .)"
  fi
  if [ -n "$inlang_run" ]; then
    # SURFACED IN DRY ON PURPOSE. AGENTS.md records that PREFLIGHT_DRY does NOT
    # surface the forced fixpoint (that flag is read after this exit), and calls the
    # resulting short gate list misleading. Do not repeat that here: a step the real
    # run will perform must appear in the dry-run's account of the real run.
    printf '── would also run the IN-LANGUAGE suite (`make test`; the `inlang` check) ─────\n'
    for _if in $inlang_run; do printf '  INLANG    ./medaka test %s\n' "$_if"; done
  fi
  if [ -n "$unmapped" ]; then
    printf '── %s path(s) the change→gate map has NO OPINION about ─────\n' \
      "$(printf '%s\n' $unmapped | grep -c .)"
    for u in $unmapped; do printf '  UNMAPPED  %s\n' "$u"; done
  fi
  exit 0
fi

# ⚠️ `$inlang_run` is part of the "is there anything to do?" test, not just `$pats`.
# A diff touching ONLY a module named in the Makefile's `test:` recipe derives no
# gate pattern from some future arm layout, and exiting here would skip the one check
# that can see it — reinstating, in this script, exactly the blind spot the block that
# builds `$inlang_run` exists to close.
[ -n "$pats" ] || [ -n "$inlang_run" ] || { echo "preflight: no gates map to these changes (docs/config only?) — nothing to run."; exit 0; }

# ── UNMAPPED, on the REAL run path too — not just under PREFLIGHT_DRY ────────
#
# $unmapped is computed for every run but used to be PRINTED only inside the
# PREFLIGHT_DRY block above. That was survivable only while a diff the map has no
# opinion about ALSO derived no gate pattern and so fell into the "nothing to run"
# exit directly above, which said so loudly.
#
# It no longer does. The coverage floor adds an unconditional
# `add 'diff_compiler_source_bytes'` for ANY non-empty $changed, so $pats is never
# empty when there IS a diff and that exit is unreachable for a real change. Without
# this block a Makefile-only diff runs one whole-tree safety-net gate, prints a clean
# green, and says NOTHING about the fact that not one per-file-targeted gate was
# derived for it — the same "green while testing nothing" shape the header warns
# about, reintroduced by a fix that was otherwise correct.
#
# ⚠️ DIAGNOSTIC ONLY. This block must never skip, exit, or drop a gate:
# diff_compiler_source_bytes legitimately covers these paths and still runs below.
# Do not turn this back into an exit-0 short-circuit.
if [ -n "$unmapped" ]; then
  printf '── %s path(s) the change→gate map has NO OPINION about ─────\n' \
    "$(printf '%s\n' $unmapped | grep -c .)"
  for u in $unmapped; do printf '  UNMAPPED  %s\n' "$u"; done
  printf '  No per-file-targeted gate was derived for the path(s) above — only whole-tree\n'
  printf '  gates (diff_compiler_source_bytes and friends) reach them. A green run below\n'
  printf '  is NOT evidence that anything examined them. If they deserve targeted\n'
  printf '  coverage, add a map arm in %s.\n' "$0"
fi

# ── LOCAL_SKIP: what THIS BOX declines to pay for. Not what the diff misses. ──
#
# ⚠️ THIS BLOCK IS BELOW THE PREFLIGHT_DRY EXIT ON PURPOSE. DO NOT MOVE IT UP. (#402)
#
# The two questions this script answers are different, and only one of them is CI's:
#
#     which gates does this diff TOUCH?   -> the change→gate map above. CI READS THIS.
#     which of those will I run HERE?     -> this block. Local only. CI never sees it.
#
# They were the same answer until #402, and the map was where the cost decision lived —
# `diff_compiler_engines` was skipped locally by simply never being added. .github/
# workflows/ci.yml derives its `pull_request` gate set by running this script with
# PREFLIGHT_DRY=1 (deliberately — one derivation, not two drifting copies), so it
# inherited the omission and skipped the gate on the PR too. `gates (engines)` reported
# SUCCESS in 5 seconds having run ZERO gates on every backend change, while the summary
# at the bottom of this file promised "CI runs these on the PR". Both halves were
# reasonable; composing them made the suite lie.
#
# The cost is real and the local skip is deliberate: the entire three-engine fixture
# corpus × (medaka build + clang), minutes of wall time, on a box several agents share.
# It just is not a claim about the diff.
#
# ⚠️ No fixture count and no wall-clock number is written down here, on purpose. The
# gate itself says why (test/diff_compiler_engines.sh: "Corpus size is NOT hardcoded
# here on purpose … a hand-maintained total rots the moment it does. The gate derives
# and reports the live count itself; read it off a run."). A cardinal in this comment
# rots the same way and is invisible when it does — the count written here before
# 2026-08-26 had drifted by hundreds. Measure, don't quote.
#
# Only an EXACT pattern is dropped. A wildcard ('diff_compiler_*', a blast-radius diff)
# that still matches the gate legitimately pulls it back in and it runs like any other —
# the re-resolve below is what makes that fall out for free rather than needing a rule.
#
# `playground/e2e/run` joined it when the playground arm started DERIVING gates: it
# launches the SYSTEM Google Chrome through Playwright and needs a freshly built
# playground/dist/playground.wasm (~2.6 MB, gitignored). It is a NIGHTLY gate, not a
# PR gate (.github/workflows/nightly.yml `playground-e2e`; see the reasoning in
# test/CI-COVERAGE-EXCEPTIONS.txt), so no PR shard would run it either — but it must
# still be PRINTED above, because the derivation is a statement about the DIFF and
# "the playground e2e covers this file" is true whoever chooses to pay for it.
LOCAL_SKIP='diff_compiler_engines playground/e2e/run'

local_skipped=""
_np=""
for _p in $pats; do
  case " $LOCAL_SKIP " in
    *" $_p "*) local_skipped="$local_skipped $_p" ;;
    *)         _np="$_np $_p" ;;
  esac
done
pats="$_np"

if [ -n "$local_skipped" ]; then
  # Re-resolve the surviving patterns against the same two roots the resolver above
  # uses, so `$gates` keeps describing exactly what will run. Re-resolving (rather than
  # subtracting a path) is what preserves the wildcard case: if 'diff_compiler_*' is
  # still in $pats it matches the skipped gate again and it comes back, correctly.
  gates=""
  for pat in $pats; do
    set +f          # the INNER loop needs real globbing (mirrors the resolver above)
    for g in "$ROOT"/test/$pat.sh "$ROOT"/$pat.sh; do
      [ -f "$g" ] || continue
      case " $gates " in *" $g "*) ;; *) gates="$gates $g" ;; esac
    done
    set -f
  done
  [ -n "$pats" ] || {
    echo "preflight: every gate this diff derives is a local-only skip ($local_skipped) — nothing to run HERE."
    echo "  That is a LOCAL cost decision, not a coverage gap: CI's pull_request run derives and RUNS them."
    exit 0
  }
fi

# ── BLAST RADIUS: say so BEFORE you spend the box on it (#492) ───────────────
#
# `mark_full` adds the `diff_compiler_*` catch-all, so for a blast-radius path
# (stdlib/core.mdk, compiler/support/*, compiler/entries/*, …) `make preflight` IS the
# full diff_compiler_* suite (`ls test/diff_compiler_*.sh | wc -l` — do not hand-write
# the number here) — the exact thing AGENTS.md tells agents never to run locally. The
# WIDENING IS CORRECT AND STAYS: a prelude change moves essentially every golden, and a
# narrow preflight would report green having run lexer + snapshot + doctests.
#
# The bug was that it was INVISIBLE. PREFLIGHT_DRY has printed this banner for a while,
# but the run path — the one agents actually take — said nothing, so an agent obeyed
# "the loop", the shared box hit load 30, and the agent got blamed for ignoring a brief
# they had followed to the letter. Two were killed for this in one session. An
# instruction that silently expands into what another instruction forbids is worse than
# either alone: the person who obeys is the one who pays.
#
# So: announce it, and offer a documented way out that does NOT lie about coverage.
# PREFLIGHT_NO_FULL=1 runs NOTHING and says so — it deliberately does NOT fall back to a
# narrower subset, because a suite that reports green while testing less than it appears
# to is this repo's #1 hazard, and the whole point here is that the narrow set is wrong.
if [ "$full_suite" -eq 1 ]; then
  echo
  echo "── ⚠️  BLAST RADIUS — THIS IS THE FULL SUITE ─────────────────"
  for r in $full_reasons; do echo "  FULL      $r"; done
  echo "  A path in this diff is used everywhere, so the change→gate map widened to the"
  echo "  'diff_compiler_*' catch-all: this run IS the whole local gate suite, not a"
  echo "  targeted subset. On this SHARED box that takes the load average past 10 and"
  echo "  turns everyone else's 30-second gate into minutes."
  echo
  echo "  The widening is CORRECT — a prelude/support change moves essentially every"
  echo "  golden, and a narrow run here would be green for the wrong reason."
  echo "  Preferred: push and let CI run it across its parallel runners."
  echo
  echo "  To decline locally:  PREFLIGHT_NO_FULL=1 sh test/preflight.sh"
  echo "  Exact command this run is about to become:"
  echo "      sh test/run_gates.sh $pats"
  echo
  if [ -n "${PREFLIGHT_NO_FULL:-}" ]; then
    echo "── PREFLIGHT_NO_FULL=1 — DECLINED. RAN NOTHING. ──────────────"
    echo "  This is NOT a pass and NOT a coverage statement: zero gates ran here."
    echo "  Nothing about this diff has been verified locally. Push and let CI answer —"
    echo "  CI is the authority regardless (preflight is a filter, never an authority)."
    exit 0
  fi
fi

# ── build the compiler ───────────────────────────────────────────────────────
#
# NO EMITTER BORROW. `make medaka` cold-bootstraps from compiler/seed/emitter.ll.gz.
#
# This block used to `cp` an emitter out of /root/medaka or a SIBLING WORKTREE, on the
# stated grounds that "a fresh worktree cannot cold-bootstrap". That justification is
# FALSE — measured on 2026-07-16 in a fresh worktree with no ./medaka_emitter:
#
#     BOOTSTRAP-FROM-SEED PASS: built .../medaka_emitter OCaml-free from the gzipped seed.
#
# and AGENTS.md says so directly: "A fresh worktree has NO ./medaka_emitter and that is
# FINE — it cold-bootstraps from compiler/seed/emitter.ll.gz and works."
#
# The borrow was actively harmful. AGENTS.md bans exactly this cp for worktree-isolated
# subagents: reading from a tree that is not yours can trip the auto-mode isolation
# classifier, and the denial is STATEFUL — it carries forward and blocks every later
# `make` you attempt, including a clean cold-bootstrap entirely inside your own worktree.
# An agent lost a whole session to this cp on 2026-07-16. So THE SANCTIONED AGENT LOOP
# was silently performing the one command the docs tell agents never to run, in the tree
# of whichever sibling agent happened to be live. Same disease as #492 and #470: the
# tooling made the banned path the silent default.
#
# The cost of not borrowing is the SEED BOOTSTRAP ONLY — measured 31s on this box
# (2026-07-16, `time sh test/bootstrap_from_seed.sh` -> real 0m31.003s, exit 0). It is not
# the ~1m52s a fresh `make medaka` takes: stages A and B run in the BORROW path too, because
# `cp` copies the emitter binary but NOT $ROOT/.medaka_emitter.srcstamp, so the borrowed
# emitter reads as "provenance unknown" and gets rebuilt from source anyway
# (build_native_medaka.sh:212-221 — "fresh bootstrap, or copied in from another tree" is ONE
# branch). Borrowing buys 31s and risks the session. Do not reintroduce it.
echo "── building ./medaka ─────────────────────────────────────────"
make -C "$ROOT" medaka >/dev/null 2>&1 || { echo "preflight: make medaka FAILED"; exit 1; }

# Build this diff's oracles by DELEGATING to build_oracles.sh --for. Do not re-derive
# the set here.
#
# preflight used to scrape `test/bin/<name>` out of the gate scripts itself, with the
# same one-line grep build_oracles uses — but WITHOUT build_oracles' crucial second
# step: intersecting the scraped names against the authoritative ENTRIES list. The grep
# matches COMMENTS, and diff_compiler_snapshot_frontend.sh:9 carries a comment naming
# `test/bin/desugar_batch` — an oracle whose entry was deleted when that gate was
# migrated into the snapshot corpus. So preflight dutifully tried to build a
# nonexistent oracle and hard-failed:
#
#     preflight: oracle build FAILED: desugar_batch
#
# after ~4.5 minutes of building. That made preflight — THE agent inner loop — unusable
# for ANY compiler-source change, since snapshot_frontend is in almost every gate set.
#
# The bug is not really the grep. It is that TWO PLACES derived the same set and only one
# of them knew the rule. So now there is one: build_oracles.sh --for is the single source
# of truth for "which oracles does this gate set need", and preflight calls it. Same
# derivation, one implementation, cannot drift again.
rc=0

# ⚠️ BOTH of these are guarded on `$pats` being NON-EMPTY, and that guard is not
# defensive tidiness. `build_oracles.sh --for` with no pattern builds EVERY oracle
# and `run_gates.sh` with no pattern runs EVERY gate — i.e. word-splitting an empty
# `$pats` turns the narrowest possible diff into the two commands AGENTS.md most
# explicitly forbids. That path became reachable the moment `$inlang_run` alone could
# get us past the "nothing to run" exit above.
if [ -n "$pats" ]; then
  printf '── building the oracles these gates read ─────\n'
  if ! sh "$ROOT/test/build_oracles.sh" --for $pats; then
    echo "preflight: oracle build FAILED"
    exit 1
  fi

  # ── run the targeted gates ─────────────────────────────────────────────────
  echo
  echo "── gates ─────────────────────────────────────────────────────"
  sh "$ROOT/test/run_gates.sh" $pats || rc=$?
fi

# ── the in-language suite, for the modules `make test` names ─────────────────
# Needs no oracle and no golden — `./medaka test` typechecks the file and runs its
# doctests against the ./medaka just built above.
if [ -n "$inlang_run" ]; then
  echo
  echo "── in-language suite (\`make test\` names these; the \`inlang\` required check) ──"
  for _if in $inlang_run; do
    "$ROOT/medaka" test "$ROOT/$_if" || rc=1
  done
fi

# ── the fixpoint, for backend changes only ───────────────────────────────────
if [ "$need_fixpoint" -eq 1 ]; then
  echo
  echo "── selfcompile fixpoint (you touched the backend — this is THE decisive gate) ──"
  sh "$ROOT/test/selfcompile_fixpoint.sh" 2>&1 | grep -E 'C3a|C3b' || rc=1
fi

# ── SAY WHAT YOU DID NOT RUN. Never be quiet about this. ─────────────────────
#
# Two things this block must get right, both learned the hard way:
#
# 1. The TOTAL must be derived from the SAME universe `$gates` is actually drawn
#    from — not a narrower glob that happens to be convenient. `$gates` is
#    populated from three sources: the static change→gate pattern table
#    (`diff_compiler_*`, `sqlite/test/*oracle`, `native_fixtures/run`,
#    `build_cmd`, …), the "you edited a gate script" self-run arm, and
#    `_gates_for_fixture_dir`'s corpus-consumer scan — and that last one can name
#    ANY gate in the repo, not just a `diff_compiler_*` one (`bootstrap_*`,
#    `selfcompile_*`, the 22 `sqlite/test/*oracle` gates, `wasm/*`,
#    `cross_project_*`, …). A total that counts only `test/diff_compiler_*.sh`
#    undercounts that universe, and the moment enough non-`diff_compiler_*`
#    gates get pulled in, `ran_count` exceeds it (issue #113: 118 ran vs 87
#    counted, on a change whose fixture dir had non-`diff_compiler_*` consumers).
#    `_gate_candidates()` (defined above, ~line 144) is already the
#    authoritative "what is a gate" universe — it is the SAME function
#    `_gates_for_fixture_dir` walks to find corpus consumers, and every pattern
#    the static table adds names a gate that is a member of it (verified: none
#    of `diff_compiler_*`, `sqlite/test/*oracle`, `native_fixtures/run`, or
#    `build_cmd` appear in test/CI-COVERAGE-TOOLS.txt, the exclude-list
#    `_gate_candidates()` subtracts). So it is the correct denominator: every
#    gate `$gates` can ever contain is, by construction, counted here too — no
#    more baked-in literal to drift (72/82/83/84/87 — see AGENTS.md).
# 2. `diff_compiler_engines` is called out here as a standing skip, but a
#    wildcard `add 'diff_compiler_*'` (support/corpus changes) pulls it INTO
#    $gates and it runs above like everything else — printing it here
#    unconditionally then contradicts its own PASS/FAIL line a few lines up.
#    Check whether it actually ran before naming it a skip.
total_gates=$(_gate_candidates | wc -l | tr -d ' ')
ran_count=$(printf '%s\n' $gates | grep -vc '^$')
remaining=$(( total_gates - ran_count ))
if [ "$remaining" -lt 0 ]; then
  # $gates only ever gains a member by resolving a pattern to a real .sh file
  # (~line 480), and every pattern this script emits — the static table, the
  # gate-self-run arm, and _gates_for_fixture_dir's corpus-consumer scan — names
  # a file drawn from the same _gate_candidates() universe total_gates counts,
  # so ran_count > total_gates should be impossible. Surface it loudly rather
  # than silently clamping and hiding a real bookkeeping bug (this guard is
  # what caught #113 in the first place — keep it as a backstop).
  echo "preflight: INTERNAL INCONSISTENCY — ran_count ($ran_count) exceeds total_gates ($total_gates); the skip-count math below is WRONG. Report this, don't trust the number."
  remaining=0
fi

# WHERE a skipped gate actually runs is not one answer, it is three — and printing the
# wrong one is how #402 stayed invisible. "CI runs these on the PR" was asserted
# unconditionally, including for gates the PR run had ALSO just been told to skip.
# Say which of the three this is, every time.
engines_gate="$ROOT/test/diff_compiler_engines.sh"
case " $gates $local_skipped " in
  *" $engines_gate "*)
    engines_line="  diff_compiler_engines      ran above (pulled in by a wildcard gate match) — not a skip" ;;
  *" diff_compiler_engines "*)
    engines_line="  diff_compiler_engines      the 3-engine differential (whole fixture corpus × clang). This diff
                             DOES touch it — skipped HERE for cost only; CI's PR run
                             derives it and RUNS it." ;;
  *)
    engines_line="  diff_compiler_engines      not derived for this diff — so whichever \`gates_N\` row
                             holds it will no-op on the PR too. It runs FULL in the merge
                             queue." ;;
esac

cat <<EOF

── NOT RUN LOCALLY ───────────────────────────────────────────────
$engines_line
$([ "$need_fixpoint" -eq 1 ] || echo "  selfcompile_fixpoint       (not a backend change) — the \`compiler-soundness\` job runs it (narrowed on \`compiler_touched\`/\`soundness_corpora\`).")
$([ -n "$inlang_run" ] && echo "  make test                  PARTIAL — ran only the modules THIS diff touched ($(echo $inlang_run)).
                             The \`inlang\` check runs the whole recipe, doctests of every
                             module it names plus diff_compiler_ported." \
                       || echo "  make test                  the in-language suite (doctests/props). No module this diff
                             touches is named in the Makefile's \`test:\` recipe, so nothing
                             here would run it; the \`inlang\` check runs it in full.")
  the other $remaining of $total_gates gates

  This preflight is a FILTER, not an authority. A green run here means the gates
  most likely to notice your change did not break — nothing more. Push a branch and
  open a PR; CI runs the full suite on free hosted runners. DO NOT merge on this.
EOF

exit "$rc"
