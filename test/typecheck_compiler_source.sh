#!/bin/sh
# test/typecheck_compiler_source.sh — strict-typecheck gate over the COMPILER'S
# OWN SOURCE.
#
# Pain point: `make medaka` + the self-compile fixpoint run the typechecker (for
# route-stamping / dict-passing) but never consult `hadTypeErrors()` — so an
# ill-typed compiler source can build green (only an oracle's `medaka build`/
# `medaka check` would catch it, and nothing runs that over the WHOLE compiler
# today). This gate closes that hole: it runs the project-wide diagnostics
# driver (compiler/entries/diagnostics_project_main.mdk, oracle at
# test/bin/diagnostics_project_main, same one test/diff_compiler_analyze_project.sh
# uses) over `compiler/driver/medaka_cli.mdk` — the real top-level CLI entry,
# whose transitive imports pull in essentially every compiler subsystem
# (frontend/types/ir/backend/driver/tools) in one closure — and FAILS if any
# ERROR-severity diagnostic is reported anywhere in the graph.
#
# ⚠️ COVERAGE GAP (issue #472): the medaka_cli.mdk closure above only reaches
# modules IMPORTED (transitively) from the CLI. `compiler/entries/*.mdk` are
# SEPARATE probe entry points (fuzz_gen_main, core_ir_typed_modules_dump_main,
# etc.) not reachable from medaka_cli — so a type error introduced only in one
# of those was never caught here (PR #465's DData re-signing merged 12/12 green
# while fuzz_gen_main, which hand-builds AST, silently stopped typechecking;
# caught 24h later by nightly). This gate closes THAT hole too: after the
# medaka_cli pass, it separately typechecks EVERY compiler/entries/*.mdk file as
# its OWN entry, through the same oracle with the same `compiler stdlib` search
# roots, fanned out across a capped `xargs -P` pool (each entry costs ~3s; ~63
# entries serial would be ~3 min, so parallelism is required to keep this gate
# affordable).
#
# WARNING-severity diagnostics (e.g. the internal-only `arrayGetUnsafe` notes,
# non-exhaustive-match warnings) do NOT fail this gate — only `error`/`error@` is
# treated as failing, mirroring the `<severity>:` convention documented in
# compiler/entries/diagnostics_project_main.mdk's own output format.
#
# ⚠️ SLOW ORACLE, NOT SLOW GATE: the compiled oracle runs in ~2-4 minutes (it
# typechecks ~35+ modules with no incremental caching) — seconds-fast relative to
# `medaka run` (the tree-walking interpreter, which never finishes over the whole
# compiler in practice), but slow relative to the other diff_compiler_*.sh gates.
# For that reason it is NOT picked up by run_gates.sh's default
# `diff_compiler_*` glob; it is wired in as an explicit extra gate (see
# run_gates.sh's EXTRA_GATES).
#
# Usage: sh test/typecheck_compiler_source.sh
#        JOBS=n sh test/typecheck_compiler_source.sh   # cap the entries-fan-out pool (default 4)
# Exit:  0 clean (zero error-severity diagnostics, entries count > 0);
#        1 an error-severity diagnostic was found (offending FILE/entry + lines
#          printed), or a worker crashed, or the entries glob matched zero files;
#        2 oracle missing (build it first: FORCE=1 JOBS=1 sh test/build_oracles.sh).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/diagnostics_project_main"
# NOTE: paths passed to the oracle must be RELATIVE to $ROOT (module ids are
# derived from these path strings — mixing an absolute entry with relative
# roots, or vice versa, makes the loader miss the module-under-root match and
# error "unknown module"). Run with cwd=$ROOT and pass everything relative.
RT="stdlib/runtime.mdk"
CORE="stdlib/core.mdk"
ENTRY="compiler/driver/medaka_cli.mdk"

# ── Per-entry worker (parallel fan-out target for compiler/entries/*.mdk) ─────
# Re-invoked as `sh "$0" --one <entry-relative-path>` under an xargs -P pool.
# Shared config (SELF/RT/CORE/ROOT/RESULTDIR) arrives via env. Writes
# ok/FAIL(status) to $RESULTDIR/<basename>.status and the bucketed error lines
# (if any) to $RESULTDIR/<basename>.out.
if [ "${1:-}" = "--one" ]; then
  entry="$2"
  name="$(basename "$entry")"
  out="$(cd "$ROOT" && "$SELF" "$RT" "$CORE" "$entry" compiler stdlib 2>&1)"
  st=$?
  if [ "$st" -ne 0 ]; then
    {
      echo "CRASH: diagnostics_project_main exited $st on entry $entry (not a diagnostic) — output:"
      printf '%s\n' "$out"
    } > "$RESULTDIR/$name.out"
    echo 1 > "$RESULTDIR/$name.status"
    exit 0
  fi
  errors="$(printf '%s\n' "$out" | awk '
    /^## FILE / { file = $0; next }
    /^error(@|:)/ { print file; print; next }
  ')"
  if [ -n "$errors" ]; then
    {
      echo "entry: $entry"
      echo "$errors"
    } > "$RESULTDIR/$name.out"
    echo 1 > "$RESULTDIR/$name.status"
  else
    : > "$RESULTDIR/$name.out"
    echo 0 > "$RESULTDIR/$name.status"
  fi
  exit 0
fi

[ -x "$SELF" ] || {
  echo "build the oracle first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$SELF") (missing $SELF)"
  exit 2
}

# ── Pass 1: the real top-level CLI entry (unchanged from the original gate) ──
out="$(cd "$ROOT" && "$SELF" "$RT" "$CORE" "$ENTRY" compiler stdlib 2>&1)"
status=$?

if [ "$status" -ne 0 ]; then
  echo "FAIL: diagnostics_project_main exited $status (crash, not a diagnostic) — output:"
  printf '%s\n' "$out"
  exit 1
fi

# Bucket the flat "## FILE <path>" / "<severity>[@line:col]: <message>" stream
# by file, then report only files carrying at least one error-severity line.
errors="$(printf '%s\n' "$out" | awk '
  /^## FILE / { file = $0; next }
  /^error(@|:)/ { print file; print; next }
')"

if [ -n "$errors" ]; then
  echo "FAIL: compiler source has type errors (medaka_cli.mdk closure):"
  echo "$errors"
  exit 1
fi

echo "PASS: medaka_cli.mdk closure is type-clean (0 error-severity diagnostics)."

# ── Pass 2: every compiler/entries/*.mdk as its own entry (issue #472) ───────
JOBS="${JOBS:-4}"

RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS"' EXIT

entries="$(cd "$ROOT" && ls compiler/entries/*.mdk 2>/dev/null)"
n_entries=0
if [ -n "$entries" ]; then
  n_entries="$(printf '%s\n' "$entries" | wc -l | tr -d ' ')"
fi

if [ "$n_entries" -eq 0 ]; then
  echo "FAIL: compiler/entries/*.mdk glob matched ZERO files — this is a mis-glob, not a clean tree (a gate that checks nothing must not pass)."
  exit 1
fi

printf '%s\n' "$entries" \
  | SELF="$SELF" RT="$RT" CORE="$CORE" ROOT="$ROOT" RESULTDIR="$RESULTS" \
    xargs -P "$JOBS" -n 1 -I{} sh "$0" --one {}

fail_count=0
seen_count=0
entry_errors=""
for s in "$RESULTS"/*.status; do
  [ -f "$s" ] || continue
  seen_count=$((seen_count + 1))
  if [ "$(cat "$s")" != 0 ]; then
    fail_count=$((fail_count + 1))
    o="${s%.status}.out"
    entry_errors="$entry_errors$(cat "$o" 2>/dev/null)
"
  fi
done

# Completeness check (issue #637): a worker killed mid-run (e.g. by a signal
# under xargs -P) writes no .status file at all, so it would otherwise vanish
# from BOTH fail_count and the printed total — a silently-shrunk "green" run.
if [ "$seen_count" -ne "$n_entries" ]; then
  missing=$((n_entries - seen_count))
  echo "FAIL: $missing of $n_entries compiler/entries/*.mdk workers produced no result — a worker died/was killed; this run is INCOMPLETE, not green."
  exit 1
fi

echo "typechecked $n_entries entries"

if [ "$fail_count" -ne 0 ]; then
  echo "FAIL: $fail_count of $n_entries compiler/entries/*.mdk failed to typecheck cleanly:"
  printf '%s' "$entry_errors"
  exit 1
fi

# ── #1110 §8 I6.3 producer ratchet ─────────────────────────────────────────
# `OriginUnresolved` (frontend/ast.mdk) is the PRE-RESOLVE inhabitant of
# `TyConOrigin`, and DICT-SEMANTICS.md §8 I6.3 forbids a sentinel origin whose
# meaning is decided per call site. Resolve now stamps identity onto every head
# it can (`stampGraphTyOrigins` / `stampFlatTyOrigins`), so after resolve the
# ONLY head still carrying `OriginUnresolved` is one whose type name is in no
# scope at all — which resolve has already reported as `UnknownType`.
#
# That characterisation holds only while every producer of the sentinel is
# PRE-RESOLVE. A new producer added downstream (the shape that bit the carrier
# PR twice: typecheck's `RScalar` synthesis and `substTyVars`, both since moved
# to `tyConBuiltin` / node-preserving) would silently reintroduce a post-resolve
# sentinel with no gate to notice. This pins the producer set.
#
# ⚠️ It lives HERE, in a gate the `soundness` job runs on every PR, rather than
# in the topically-better `test/check_removed_constructs.sh` — that one is
# NIGHTLY-only, so a ratchet in it cannot block the PR that breaks it.
#
# ⚠️ This is a PRODUCER ratchet, not the runtime drain #1110 asks for. It cannot
# see whether a driver forgot to stamp; nothing reads `tyConOrigin` yet, so no
# differential gate can distinguish a stamped tree from an unstamped one. The
# executable runtime drain is owed by the PR that adds the first READER.
echo "checking #1110 OriginUnresolved producer set ..."
tyconun_allowed="compiler/entries/fuzz_gen_main.mdk
compiler/frontend/ast.mdk
compiler/frontend/desugar.mdk
compiler/frontend/parser.mdk"
tyconun_actual=$(git -C "$ROOT" grep -lw -- 'tyConUnresolved' -- '*.mdk' 2>/dev/null \
  | while IFS= read -r f; do
      # a file counts only if it mentions the producer OUTSIDE a comment line
      if grep -w 'tyConUnresolved' "$ROOT/$f" | grep -qvE '^[[:space:]]*--'; then
        echo "$f"
      fi
    done | sort)
if [ "$tyconun_actual" != "$tyconun_allowed" ]; then
  echo "FAIL: the #1110 \`tyConUnresolved\` producer set changed."
  echo "  allowed (PRE-RESOLVE construction only):"
  printf '    %s\n' $tyconun_allowed
  echo "  actual:"
  printf '    %s\n' $tyconun_actual
  echo "  A POST-RESOLVE producer reintroduces the \`OriginUnresolved\` sentinel"
  echo "  DICT-SEMANTICS.md §8 I6.3 forbids. Use \`tyConBuiltin\` for a language-"
  echo "  provided head, or preserve the node you are rebuilding. If the new site"
  echo "  really is pre-resolve, add it to the list above and say why in the PR."
  exit 1
fi
echo "  ok: $(printf '%s\n' "$tyconun_actual" | grep -c .) pre-resolve producer file(s)"

echo "PASS: compiler source is type-clean (0 error-severity diagnostics across medaka_cli.mdk + $n_entries entries)."
exit 0
