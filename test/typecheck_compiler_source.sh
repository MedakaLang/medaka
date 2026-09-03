#!/bin/sh
# shell-because: trust-anchor — circular: checks the machinery a native gate would run inside
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
#        2 oracle missing (build it first: FORCE=1 JOBS=1 sh test/build_oracles.sh),
#          or ./medaka + ./medaka_emitter missing for pass 3 (run `make medaka`).
#
# ⚠️ TWO DRIVERS, NOT ONE (issue #1811). Passes 1 and 2 below run the CHECK
# driver (`analyzeProject`). `medaka run`/`medaka build` typecheck through a
# SECOND driver (`elaborateModules`, after a graph-global
# buildStandaloneShadowsGraph/prePassDictArg rewrite) that derives errors the
# first one structurally cannot see. Pass 3 runs that second driver over the
# same closure. See pass 3's own header for why it costs a whole `medaka build`.
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
  echo "SKIP: build the oracle first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$SELF") (missing $SELF)"
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
    xargs -P "$JOBS" -I{} sh "$0" --one {}

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

# ── shared comment-filtered-mention helper (#1237) ──────────────────────────
# The producer/carrier ratchets below (and the two carrier-classification loops
# further down) all answer the same underlying question -- "does this name
# appear in this file OUTSIDE a leading-comment line?" -- with the same filter:
# `^[[:space:]]*--`, i.e. LEADING comments only (a trailing side comment or a
# string literal merely naming the pattern would trip it spuriously). That
# filter used to be copy-pasted five times; collapsing it to one home means
# hardening it (a deliberately separate, NOT-urgent change -- see #1237) is a
# one-place edit, and the next carrier family is a one-line call rather than a
# sixth copy.
#
# ratchet_name_live_in PATTERN FILE
#   Success (exit 0) iff FILE mentions the whole-word/alternation PATTERN
#   outside a leading-comment line. PATTERN is a `grep -wE` pattern (a literal
#   name or a `|`-alternation) -- `-E` is a no-op on a plain literal, so one
#   form covers both.
ratchet_name_live_in() {
  grep -wE "$1" "$2" | grep -qvE '^[[:space:]]*--'
}
# ratchet_producer_files PATTERN
#   Prints the sorted, newline-separated list of tracked `.mdk` files that
#   mention PATTERN outside a leading-comment line (empty output => no hits).
ratchet_producer_files() {
  git -C "$ROOT" grep -lwE -- "$1" -- '*.mdk' 2>/dev/null \
    | while IFS= read -r f; do
        if ratchet_name_live_in "$1" "$ROOT/$f"; then
          echo "$f"
        fi
      done | sort
}

# ── #1110 §8 I6.3 producer ratchet ─────────────────────────────────────────
# `OriginUnresolved` (frontend/ast.mdk) is the "no identity was available"
# inhabitant of `TyConOrigin`, and DICT-SEMANTICS.md §8 I6.3 forbids a sentinel
# origin whose meaning is decided per call site. It survives resolve in exactly
# two shapes, both honest ABSENCE: a name in no scope at all, and a loader-less
# (flat) driver that has no module id for the user's own declarations. What must
# never appear is a THIRD shape — a post-resolve site minting the sentinel onto a
# head that already had, or should have had, a real identity.
#
# That is not hypothetical: it bit the carrier PR twice (typecheck's `RScalar`
# synthesis, and `substTyVars` rebuilding a node from its name alone — both since
# moved to `tyConBuiltin` / node-preserving). This pins the producer set so a
# third one cannot land silently.
#
# TWO checks, because the first alone is a hole: `tyConUnresolved` is only the
# HELPER, and a direct `TyCon { …, tyConOrigin = OriginUnresolved }` record
# literal bypasses it entirely. So the constructor itself is pinned too. Its
# allowed set is SMALLER, and deliberately so — `frontend/{parser,desugar}.mdk`
# and the fuzz generator all go through the helper, so only the module that
# DEFINES the type and the module that CONSUMES it in a pattern may name it.
#
# ⚠️ It lives HERE, in a gate the `compiler-soundness` job runs (narrowed on
# `compiler_touched`/`soundness_corpora`), rather than in the topically-better
# `test/check_removed_constructs.sh` — that one is NIGHTLY-only, so a ratchet
# in it cannot block the PR that breaks it.
#
# ⚠️ This is a PRODUCER ratchet, not the runtime drain #1110 asks for. It cannot
# see whether a driver forgot to stamp, nor whether one stamped the WRONG id --
# the defect class review found in the first cut.
#
# Both need a way to OBSERVE an origin from a compilation, and as of #1110's
# agreement gate that way EXISTS: test/diff_compiler_origin_agreement.sh drives the
# flat / single-module / graph elaboration entry points over one loader graph and
# diffs the resulting agreement table, so a driver that stamps the WRONG id shows up
# as a CONFLICT row. (This note used to end "which today does not exist" -- it did
# not, then; it does now. The two gates are complements: this one pins WHO MAY MINT
# the sentinel, that one pins WHAT THE DRIVERS AGREE ON.)
echo "checking #1110 OriginUnresolved producer set ..."
tyconun_allowed="compiler/entries/fuzz_gen_main.mdk
compiler/frontend/ast.mdk
compiler/frontend/desugar.mdk
compiler/frontend/parser.mdk"
# ⚠️ THIS LIST IS FILENAMES, so it cannot tell CONSTRUCTION from a PATTERN, and a
# file that only READS the constructor has to be listed too. That is the case for
# origin_agreement_main.mdk: its single mention is `originKey OriginUnresolved = "-"`,
# an arm of a total match over `TyConOrigin` (deliberately enumerated rather than
# wildcarded, so a fourth inhabitant is made to show up rather than silently reading
# as "no claim"). The comment above already licenses this -- "the module that
# CONSUMES it in a pattern may name it" -- the mechanism just cannot see the
# difference. It mints nothing: it is a probe with no `TyCon` construction anywhere.
#
# ⚠️ types/typecheck.mdk IS on this list as of #1110 unit D, and it is the one entry
# that mints the sentinel at a layer this ratchet's prose was not written for. Its
# mentions are the `Mono` layer, NOT `Ty`: `tconUnresolved n = TCon n
# OriginUnresolved` and its two callers. `Mono` has no stamping pass and therefore no
# immunity rule to make a wrong first write permanent, so the hazard the paragraph
# above describes does not transfer -- what transfers is the weaker requirement that
# a site claiming "no identity available" be deliberate and few.
#
# 🚨 BUT A FILENAME ENTRY EXEMPTS THE WHOLE 20k-LINE FILE, INCLUDING ANY FUTURE
# `Ty`-LAYER `TyCon { …, tyConOrigin = OriginUnresolved }` LITERAL IN IT -- which is
# precisely the bypass this ratchet's FAIL message exists to catch. Nothing is masked
# today, and rather than accept the forward-looking softening the exemption is made
# LINE-GRAINED by the companion check just below: the `OriginUnresolved`-bearing lines
# of typecheck.mdk are pinned by text, so a `Ty`-layer literal added there fails even
# though the filename is allow-listed.
# ⚠️ `compiler/types/route_key.mdk`: same entry, same reason, same "red since
# `B-2.2-a`" caveat as `occun_allowed` above. Its three hits are the DOCTEST FIXTURES
# `rkTyInt`/`rkTyBool`/`rkTyList` — `TyCon { …, tyConOrigin = OriginUnresolved }`,
# built to be exactly the node a LOADER-LESS driver hands the mint, because the
# doctests' whole job is to pin that the absent-origin arm still spells the bare
# interface name. A `tyConUnresolved` call would satisfy the letter of this ratchet
# and move the file onto `tyconun_allowed` instead; the literal is kept because the
# fixture is asserting the SHAPE.
# 🚨 THIS ENTRY IS NOW LINE-GRAINED BY A COMPANION CHECK (`rk_originun_allowed`,
# below the `tc_originun` one), AND THE SENTENCE THAT USED TO END THIS PARAGRAPH —
# "the file mints nothing the pipeline consumes" — IS THE REASON. It was true when
# `B-2.2-a` landed the module inert and FALSE by the time `B-2.2-b1`/`-e` wired
# `implRouteKeyWord`/`routeWordFor` into `typecheck.mdk`'s live route path, in the
# same sprint. A filename entry granted on "nothing calls this file" cannot survive
# the file acquiring callers, so the exemption is pinned to its four actual lines
# the way `typecheck.mdk`'s is.
originun_allowed="compiler/entries/origin_agreement_main.mdk
compiler/frontend/ast.mdk
compiler/frontend/resolve.mdk
compiler/types/route_key.mdk
compiler/types/typecheck.mdk"
tyconun_actual=$(ratchet_producer_files 'tyConUnresolved')
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

# The DECLARATION-layer peers (#1110): `dDataUnresolved` / `dTypeAliasUnresolved` /
# `dNewtypeUnresolved` / `dInterfaceUnresolved` mint a type DECLARATION whose module
# identity has not been acquired. Same hazard as the `Ty` layer, one layer down: a
# POST-resolve call re-synthesises a decl from its projected fields and silently
# resets an identity resolve already stamped — and the immunity rule
# (`fillDeclOrigin` fills only an unresolved origin) makes that reset PERMANENT.
# The remedy is a record UPDATE (`DData { d | dataCtors = … }`), which is what every
# rebuild site in the tree now uses.
#
# ⚠️ `tools/printer.mdk` IS on this list, and it is the one entry that is not
# pre-resolve. `printNamedFieldData`'s fallback arm builds a throwaway `DData` purely
# to reach `printDecl`'s arm, and every renderer STRIPS decl identity the way `ELoc`
# is stripped — so the origin of that node is unobservable by construction, and the
# node itself is discarded in the same expression. It is listed with that reasoning
# rather than silently tolerated; a NEW entry needs its own.
declun_allowed="compiler/entries/fuzz_gen_main.mdk
compiler/frontend/ast.mdk
compiler/frontend/parser.mdk
compiler/tools/printer.mdk"
# â ï¸ Inherits #1222: `git grep` sees only TRACKED files, so an UNTRACKED `.mdk`
# calling one of these post-resolve passes this check. Character-for-character the
# same construction as the two sibling ratchets, and fixed in the same place when
# #1222 lands â not worked around here, so all three move together.
declun_actual=$(ratchet_producer_files 'dDataUnresolved|dTypeAliasUnresolved|dNewtypeUnresolved|dInterfaceUnresolved')
if [ "$declun_actual" != "$declun_allowed" ]; then
  echo "FAIL: the #1110 decl-layer unresolved-producer set changed."
  echo "  allowed (PRE-RESOLVE construction, plus the identity-stripping printer):"
  printf '    %s\n' $declun_allowed
  echo "  actual:"
  printf '    %s\n' $declun_actual
  echo "  A post-resolve call to one of these RESETS an acquired decl identity, and"
  echo "  the immunity rule makes that permanent. Rebuild with a record UPDATE"
  echo "  (\`DData { d | dataCtors = … }\`) instead. If the new site really is"
  echo "  pre-resolve, add it to the list above and say why in the PR."
  exit 1
fi
echo "  ok: $(printf '%s\n' "$declun_actual" | grep -c .) decl-layer producer file(s)"

# The INTERFACE-OCCURRENCE peers (#1110 PR B): `constraintUnresolved` /
# `requireUnresolved` / `superUnresolved` / `dImplUnresolved` mint a node that NAMES
# an interface at a use site (`=>` predicate, `requires`, superinterface, `impl`
# head) whose module identity has not been acquired. Same hazard, same remedy as
# the two ratchets above: a POST-resolve call re-synthesises the node from its
# projected fields and silently resets an identity resolve already stamped, and the
# immunity rule makes the reset permanent. Rebuild with a record UPDATE
# (`Constraint { c | constraintArgs = … }`, `DImpl { d | methods = … }`).
#
# Deliberately a SEPARATE list from `declun_allowed` rather than four more names in
# its alternation: an `impl` is not a DECLARATION of the interface it names, so
# `DImpl` mints no decl-layer carrier and must never grow a `declHeadOf` arm (see
# that function's own comment in compiler/entries/origin_agreement_main.mdk).
# Merging the two lists is how that distinction gets lost.
# ⚠️ `compiler/types/route_key.mdk` IS ON THIS LIST FOR ITS DOCTEST FIXTURES ALONE,
# and it has been RED SINCE `B-2.2-a` LANDED THAT FILE (2026-08-13) — this ratchet
# is a `git grep` over TRACKED files, not over an import closure, so the module was
# never invisible to it; `a` simply ran no gate beyond build/check-self/snapshot and
# nobody looked. Recorded rather than quietly fixed, because "a call-site-free module
# is in no gate" is true of the COMPILER's gates and false of this one.
# WHY IT IS SAFE: `route_key.mdk` mints route WORDS from a `Ty` it only ever READS.
# It constructs no AST node for the pipeline at all — the sole non-comment hit is the
# `constraintUnresolved` IMPORT that feeds `rkTy`'s two `TyConstrained` doctests. So
# there is no post-resolve rebuild here to reset an acquired identity, which is the
# hazard this ratchet exists to catch.
# 🚨 THAT REASONING IS ABOUT THE LINE, NOT THE FILE, AND THE FILE-LEVEL VERSION OF IT
# EXPIRED IN THE SPRINT THAT WROTE IT. `route_key.mdk` was inert when `B-2.2-a`
# landed it; `B-2.2-b1`/`-e` then put it in `typecheck.mdk`'s live import closure, so
# a whole-file exemption now covers a module the pipeline calls. Pinned to that one
# line by the companion check `rk_occun_allowed` (below the `tc_originun` one), the
# same way `typecheck.mdk`'s filename entry is.
occun_allowed="compiler/frontend/ast.mdk
compiler/frontend/desugar.mdk
compiler/frontend/parser.mdk
compiler/types/route_key.mdk"
# ⚠️ Inherits #1222 exactly as the two ratchets above do: `git grep` sees only
# TRACKED files. Same construction on purpose, so all three move together.
occun_actual=$(ratchet_producer_files 'constraintUnresolved|requireUnresolved|superUnresolved|dImplUnresolved')
if [ "$occun_actual" != "$occun_allowed" ]; then
  echo "FAIL: the #1110 interface-occurrence unresolved-producer set changed."
  echo "  allowed (PRE-RESOLVE construction only):"
  printf '    %s\n' $occun_allowed
  echo "  actual:"
  printf '    %s\n' $occun_actual
  echo "  A post-resolve call to one of these RESETS an acquired interface-occurrence"
  echo "  identity, and the immunity rule makes that permanent. Rebuild with a record"
  echo "  UPDATE (\`Constraint { c | constraintArgs = … }\`) instead. If the new site"
  echo "  really is pre-resolve, add it to the list above and say why in the PR."
  exit 1
fi
echo "  ok: $(printf '%s\n' "$occun_actual" | grep -c .) occurrence-layer producer file(s)"

originun_actual=$(ratchet_producer_files 'OriginUnresolved')
if [ "$originun_actual" != "$originun_allowed" ]; then
  echo "FAIL: the #1110 \`OriginUnresolved\` constructor site set changed."
  echo "  allowed (definition + resolve's own stamper):"
  printf '    %s\n' $originun_allowed
  echo "  actual:"
  printf '    %s\n' $originun_actual
  echo "  A direct \`TyCon { …, tyConOrigin = OriginUnresolved }\` literal bypasses the"
  echo "  \`tyConUnresolved\` helper and its ratchet above. Build pre-resolve nodes with"
  echo "  \`tyConUnresolved\`, language-provided heads with \`tyConBuiltin\`, and preserve"
  echo "  the node you are rebuilding rather than re-synthesising it from its name."
  exit 1
fi
echo "  ok: $(printf '%s\n' "$originun_actual" | grep -c .) OriginUnresolved constructor site(s)"

# The LINE-GRAINED half of the typecheck.mdk entry above (see its comment). The
# filename allow-list cannot tell the `Mono` layer from the `Ty` layer inside one
# 20k-line file; this pins the exact lines, so a `Ty`-layer
# `TyCon { …, tyConOrigin = OriginUnresolved }` literal added to typecheck.mdk fails
# here even though the file is allow-listed.
# ⚠️ ONE OF THE TWO LINES IS AN ELIMINATOR ARM, NOT A CONSTRUCTION.
# `originPhrase OriginUnresolved = …` (#1111 A-2.10) renders an origin into the
# user-facing text of the same-spelling type-mismatch hint. It CONSTRUCTS nothing —
# `OriginUnresolved` is on its LEFT-hand side — and it exists to keep `originPhrase`
# TOTAL over the three inhabitants rather than closing it with a wildcard, which is
# the shape `stampTyHead`'s own comment argues for ("a fourth inhabitant should be
# MADE TO SHOW UP here"). The arm is unreachable from its only caller (a conflict
# requires two PRESENT identities, so `firstIdConflict` never hands it an absent
# one); it is answered rather than omitted so that a future caller with a laxer
# precondition gets prose instead of a non-exhaustive-match warning. Listed here
# rather than the grep widened, per the remedy this ratchet's siblings state.
# ⚠️ #1446 (P1) ADDED SIX LINES, ALL AT THE INTERFACE-OCCURRENCE LAYER AND NONE AT
# THE `Ty` LAYER — which is the distinction this pin exists to make, so they are
# listed rather than the grep widened.
#   * `ifaceRefBare` — the ONE mint for an interface occurrence whose identity is not
#     recoverable at the site (`funConstraintIfacesRef` / `schemeObligationsRef`, both
#     inside #1425's seam). Its two callers are the residual worklist; `grep -n
#     ifaceRefBare compiler/types/typecheck.mdk` is the drain check.
#   * `oblIfaceKeys`' `OriginUnresolved => [TkBare NsIface …]` arm — an ELIMINATOR,
#     `OriginUnresolved` is on the LEFT. It constructs nothing.
#   * `emptyBuiltinClasses`' four fields — the §8 I7 built-in-class table before any
#     prelude has been seen. `OriginUnresolved` is the honest answer there (a
#     prelude-free program declares none of the four and implements none of them), and
#     it is the value a `Ty`-layer sentinel would be WRONG to have: nothing stamps this
#     table, so there is no immunity rule to make a first write permanent.
# ⚠️ U1b (#1482) ADDED ONE LINE, `ifaceRefNone`, AND IT IS A DIFFERENT FACT FROM
# `ifaceRefBare` — which is the whole reason it is a second name rather than a call.
# The slot-parallel interface channels (`funConstraintIfacesRef` and the `CSlot`
# lists derived from it) have always used the EMPTY SPELLING `""` to mean "this dict
# slot has no recoverable interface at all"; every reader tests `irName == ""` and
# SKIPS the slot. `ifaceRefBare` means the opposite kind of thing — a real interface
# whose IDENTITY is not recoverable here — and its call sites are the residual
# worklist `grep -n ifaceRefBare` drains. Routing the empty sentinel through it would
# put a permanent non-drainable hit on that worklist and make the drain check lie.
# It is at the interface-occurrence layer, not the `Ty` layer, so the same reasoning
# as the six #1446 lines applies: listed here rather than the grep widened. It mints
# no identity a `stampTyHead` immunity rule could make permanent — the value is never
# compared for identity, only for `irName == ""`.
# ⚠️ #1519 (ARCH A-3.3) ADDED TWO LINES, BOTH ELIMINATOR ARMS, SAME SHAPE AS
# `originPhrase`'s ABOVE. `ceRowOriginTag`/`ceSuperOrigin` (`CE`'s doctest-only
# projections of `IfaceRef.irOrigin`/`Super.superOrigin`) enumerate all three
# `TyConOrigin` inhabitants rather than closing the match with a wildcard — a
# wildcard would still be TOTAL (an earlier revision of that code argued
# exactly that and was corrected in review), but totality is not what this
# ratchet's convention protects: DISCOVERABILITY of a fourth inhabitant is,
# per `originPhrase`'s own comment ("MADE TO SHOW UP"). Neither arm
# CONSTRUCTS — `OriginUnresolved`/`OriginBuiltin` are on the LEFT in both — and
# neither is reachable on any `CeRow`/`Super` this unit's fixtures build (every
# fixture stamps `OriginModule _`); they exist only so the match stays total
# AND discoverable, exactly as `originPhrase`'s arm does. Listed here rather
# than the grep widened, per the remedy this ratchet's other entries state.
# ⚠️ ARCH B-2.1-a3 (Stage B sprint) ADDED ONE LINE, AND IT IS THE FIRST ENTRY ON THIS
# LIST THAT *CONSTRUCTS* — stated plainly because that is a stronger claim than every
# entry above it. `implOrigin = OriginUnresolved,` is inside `ieLooseImplIn`, a
# DOCTEST FIXTURE in the `IE` doctest block (grep `ieLooseImplIn`), not a production
# mint: the #1519 entries above have `OriginUnresolved` on the LEFT of an eliminator
# arm, whereas this one puts it on the right.
#
# Why the fixture needs it, and why widening the grep would be wrong: the fixture's
# whole purpose is to exercise the IDENTITY-LESS case. `oblIfaceKeys` mints ONE key
# (the bare leg) for an identity-less interface where every identity-bearing sibling
# gets two, and `ieByHead`'s partition is keyed on the receiver HEAD with no interface
# component — so the fixture proves a head-keyed index files `impl Loose Blob` beside
# its siblings REGARDLESS of that asymmetry. That is the property distinguishing
# `ieByHead` from `ieConcrete`/`ieHeadless`, which remain asymmetric (see the F1
# investigation, `.claude/sprint-b/DECISIONS.md` RUN-B-027/RUN-B-030: the asymmetry is
# DORMANT, not absent — it re-opens for anything that compares `TabKey`s for equality
# or renders one). Deleting the fixture would delete the only in-tree proof of that.
# Listed here rather than the grep widened, per the remedy this ratchet's other
# entries state — a widened grep would stop reporting a FOURTH inhabitant, which is
# the discoverability this ratchet exists to protect.
# ⚠️ B-2.2-b1 ADDED ONE LINE, AND IT IS THE SECOND ENTRY THAT *CONSTRUCTS* —
# `implKeyTc iface tys = implRouteKeyWord OriginUnresolved iface tys None`. It is a
# `Ty`-layer literal in the sense the failure message warns about, so it needs the
# justification stated here rather than a widened grep:
#   * `implKeyTc` no longer mints a ROUTE. After `b1` its ONLY callers are
#     `keyEntryOf`/`keyEntryOfRow`, which write `KeyEntry`'s 4th field — a field with
#     NO READER (measured: stamping a literal `"__DEAD__"` at both sites builds,
#     passes `make check-self`, and passes all of `diff_compiler_dict_semantics.sh`).
#     The live route words are minted from the winning ROW's own `irOrigin` at
#     `keyForSite`/`keyForSiteByIface`, which is what carries identity.
#   * It constructs no NODE. `OriginUnresolved` here is an ARGUMENT to a word mint
#     that renders it as "no module prefix"; nothing is stamped, so there is no
#     immunity rule for it to make permanent — the same reasoning `ifaceRefBare`'s
#     entry above carries, one layer further out.
# If `KeyEntry`'s key field ever acquires a reader, this line stops being justified
# and the word must come from the row like the other two.
tc_originun_allowed="OriginUnresolved => \"<unresolved>\"
OriginUnresolved => [TkBare NsIface ir.irName]
bcEq = OriginUnresolved,
bcNum = OriginUnresolved,
bcOrd = OriginUnresolved,
bcSemigroup = OriginUnresolved,
ceSuperOrigin (Super { superOrigin = OriginUnresolved, ... }) = \"<unresolved>\"
ifaceRefBare n = IfaceRef { irName = n, irOrigin = OriginUnresolved }
ifaceRefNone = IfaceRef { irName = \"\", irOrigin = OriginUnresolved }
implKeyTc iface tys = implRouteKeyWord OriginUnresolved iface tys None
implOrigin = OriginUnresolved,
originPhrase OriginUnresolved = \"an unknown module\"
tconUnresolved n = TCon n OriginUnresolved"
tc_originun_actual=$(grep -w 'OriginUnresolved' "$ROOT/compiler/types/typecheck.mdk" \
  | sed 's/^[[:space:]]*//' \
  | grep -vE '^--' \
  | LC_ALL=C sort)
if [ "$tc_originun_actual" != "$tc_originun_allowed" ]; then
  echo "FAIL: the OriginUnresolved lines of compiler/types/typecheck.mdk changed."
  echo "  allowed (the Mono-layer mint, and nothing else):"
  printf '%s\n' "$tc_originun_allowed" | sed 's/^/    /'
  echo "  actual:"
  printf '%s\n' "$tc_originun_actual" | sed 's/^/    /'
  echo "  typecheck.mdk is on \`originun_allowed\` for its \`Mono\`-layer mint ONLY."
  echo "  A \`Ty\`-layer literal here bypasses \`tyConUnresolved\` and its ratchet; a"
  echo "  NEW Mono-layer sentinel site needs the same justification the two existing"
  echo "  callers carry at the call. Route it, or add the line here and say why."
  exit 1
fi
echo "  ok: 1 Mono-layer OriginUnresolved line in typecheck.mdk, no Ty-layer literal"

# ── The LINE-GRAINED half of the two `compiler/types/route_key.mdk` entries ──
# 🚨 WHY THIS EXISTS, stated plainly because the justification it replaces EXPIRED
# AS IT WAS WRITTEN. Both filename entries (`originun_allowed` and `occun_allowed`)
# were added with the reasoning "route_key.mdk is inert — it has no call sites, so
# a filename exemption over the whole file exempts nothing that runs." THE SAME
# SPRINT MOVED THAT MODULE INTO THE IMPORT CLOSURE (`B-2.2-a` minted it,
# `B-2.2-b1`/`-e` wired `implRouteKeyWord`/`routeWordFor` into `typecheck.mdk`'s
# live route path), so by the time the entries landed the premise was already
# false: a filename entry now exempts a module the pipeline actually calls.
# Derive rather than trust this paragraph:
#   grep -rn 'route_key' compiler/types/typecheck.mdk | head
#
# THE REMEDY IS THE ONE `typecheck.mdk` ALREADY USES ABOVE, and it is chosen over
# deleting the filename entries because the two producer ratchets compare EXACT
# SETS of filenames — there is no way to say "this file, these lines" in the list
# itself, so line-graining has to be a companion check. `typecheck.mdk` had one and
# this file did not; that asymmetry is the whole defect. A new `OriginUnresolved`
# or interface-occurrence mint added to route_key.mdk now FAILS here even though
# the filename stays allow-listed.
#
# WHAT THE PINNED LINES ARE, and why each is safe:
#   * three `TyCon { …, tyConOrigin = OriginUnresolved }` literals — the DOCTEST
#     FIXTURES `rkTyInt`/`rkTyBool`/`rkTyList`. They are built to be exactly the node
#     a LOADER-LESS driver hands the mint, because the doctests' job is to pin that
#     the absent-origin arm still spells the bare interface name. Nothing stamps
#     them and nothing in the pipeline consumes them, so there is no immunity rule
#     for them to make permanent.
#   * one `constraintUnresolved,` — an IMPORT, not a construction, feeding `rkTy`'s
#     two `TyConstrained` doctests.
# ⚠️ The doctest COMMENT lines that mention `OriginUnresolved` (there are many —
# `implRouteKeyWord OriginUnresolved "Show" …`) are excluded by the same `^--`
# filter the sibling checks use, so this pin does not fight the doctests it protects.
echo "checking route_key.mdk unresolved-sentinel lines ..."
rk_originun_allowed="TyCon { tyConName = \"Bool\", tyConLoc = None, tyConOrigin = OriginUnresolved }
TyCon { tyConName = \"Int\", tyConLoc = None, tyConOrigin = OriginUnresolved }
TyCon { tyConName = \"List\", tyConLoc = None, tyConOrigin = OriginUnresolved }"
rk_originun_actual=$(grep -w 'OriginUnresolved' "$ROOT/compiler/types/route_key.mdk" \
  | sed 's/^[[:space:]]*//' \
  | grep -vE '^--' \
  | LC_ALL=C sort)
if [ "$rk_originun_actual" != "$rk_originun_allowed" ]; then
  echo "FAIL: the OriginUnresolved lines of compiler/types/route_key.mdk changed."
  echo "  allowed (the three rkTy* doctest fixtures, and nothing else):"
  printf '%s\n' "$rk_originun_allowed" | sed 's/^/    /'
  echo "  actual:"
  printf '%s\n' "$rk_originun_actual" | sed 's/^/    /'
  echo "  route_key.mdk is on \`originun_allowed\` for its DOCTEST FIXTURES ONLY, and"
  echo "  that module is now IN the live import closure -- the 'it is inert' reasoning"
  echo "  the filename entry was granted under no longer holds. A new sentinel site"
  echo "  here needs its own justification: add the line above and say why in the PR,"
  echo "  or build the node with \`tyConUnresolved\` / \`tyConBuiltin\` instead."
  exit 1
fi
echo "  ok: 3 doctest-fixture OriginUnresolved lines in route_key.mdk, no live mint"

rk_occun_allowed="constraintUnresolved,"
rk_occun_actual=$(grep -wE 'constraintUnresolved|requireUnresolved|superUnresolved|dImplUnresolved' \
    "$ROOT/compiler/types/route_key.mdk" \
  | sed 's/^[[:space:]]*//' \
  | grep -vE '^--' \
  | LC_ALL=C sort)
if [ "$rk_occun_actual" != "$rk_occun_allowed" ]; then
  echo "FAIL: the interface-occurrence unresolved lines of compiler/types/route_key.mdk changed."
  echo "  allowed (the import that feeds the TyConstrained doctests, and nothing else):"
  printf '%s\n' "$rk_occun_allowed" | sed 's/^/    /'
  echo "  actual:"
  printf '%s\n' "$rk_occun_actual" | sed 's/^/    /'
  echo "  route_key.mdk is on \`occun_allowed\` for that ONE import, and the module is"
  echo "  now IN the live import closure. A post-resolve rebuild here would reset an"
  echo "  acquired interface-occurrence identity permanently. Rebuild with a record"
  echo "  UPDATE (\`Constraint { c | constraintArgs = … }\`) instead."
  exit 1
fi
echo "  ok: 1 doctest-feeding occurrence-layer import in route_key.mdk, no live mint"

# ── #1110 unit D: the `Mono.TCon` MINT SET ──────────────────────────────────
# `Mono.TCon` (compiler/types/typecheck.mdk) carries a `TyConOrigin` — the GOAL side
# of a dispatch key, the peer of the impl side's `headTyconTy`. Unlike the `Ty` layer
# it has NO stamping pass, so there is no `stampTyHead`-style first-write filter for
# its correctness to rest on: identity must be right AT CONSTRUCTION.
#
# "Every construction site is individually right" is a materially weaker property
# than a single filter, so the source does not rely on it. Every application of the
# constructor is funnelled through FOUR one-line mints, each named for the identity
# class it claims, and this ratchet pins that there are no others. What the pin buys
# is that a reviewer grades four lines plus the choice of helper at each call, rather
# than re-deriving what a bare third argument meant at ~90 sites.
#
# HOW IT TELLS A CONSTRUCTION FROM A PATTERN: a pattern that does not need the origin
# leaves its slot `_`, and an occurrence of `TCon` whose origin slot is anything else
# is a construction OR a pattern that binds the origin. ⚠️ The second half of that
# disjunction used to read "nothing reads the origin field yet, so every PATTERN
# leaves its slot `_`" — that stopped being true at #1111 A-2.2 (`headTyconMono`) and
# is thoroughly false since A-2.10, which made SIX comparisons read it. The filter is
# unchanged and still correct; only its rationale was overstated. The allowlist below
# is therefore the audit: four mints plus every origin-binding pattern, each listed.
# ⚠️ Do NOT write the pattern COUNT into this prose. The list is the count, and the
# label the gate prints derives it — an encoded number here is exactly the kind of
# fact that was already falsified once by the next unit to touch this file.
#
# 🚨 IT FILTERS PER OCCURRENCE, NOT PER LINE, AND THE DIFFERENCE IS A PROVEN HOLE.
# The first cut of this ratchet dropped any LINE matching the pattern shape, so a line
# carrying BOTH a pattern and a construction vanished whole. Measured against the head
# blob at the time:
#   baseline                                        -> 5 lines (decl + 4 mints)
#   + `rogue (TCon a _) = TCon a OriginBuiltin`      -> 5 lines, IDENTICAL: invisible
#   + `rogue2 x = TCon x OriginBuiltin` (own line)   -> 6 lines, caught
# 35 lines in the file already match the pattern shape and could host one — including
# `unifyN (ta@(TCon a _)) (tb@(TCon b _))` and `cohGoR _ (TCon a _) (TCon b _)`, i.e.
# exactly where the next unit edits. So patterns are ERASED IN PLACE (`sed …//g`) and
# whatever `TCon` survives is reported. ⚠️ A reported line therefore shows GAPS where
# a pattern stood — probe B below reports `rogueA () = TCon a OriginBuiltin` — and
# that is the erasure, not a corrupted source line.
#
# The trailing-comment strip in front of it closes the false positive that WAS this
# ratchet's masking path: a side comment mentioning `TCon` survives the `^--` filter,
# fails the gate, and cannot sensibly be "added to the list of mints" — so the only
# available response would have been the one thing the remedy below forbids.
#
# 🔬 POSITIVE CONTROL — append each to compiler/types/typecheck.mdk, rerun this gate,
# restore. Re-run ALL FOUR if you touch the filter; a green here means nothing unless
# B and C both fail and D does not.
#   A  (unmodified)                                  -> ok, 4 mints
#   B  rogueA (TCon a _) = TCon a OriginBuiltin      -> FAIL   (construction sharing a
#                                                       line with a pattern: the hole)
#   C  rogueB x = TCon x OriginBuiltin               -> FAIL   (own line)
#   D  rogueC : Int -> Int  -- a note about TCon     -> ok     (side comment, not a
#                                                       construction: no false positive)
#
# 🚨 REMEDY WHEN THIS FIRES: add the offending LINE to `mono_tcon_allowed` and justify
# it in the PR — never widen the regex. Widening is the masking path: the filter's
# only discriminator is the `_` in the origin slot, so relaxing it re-admits exactly
# the sites this exists to enumerate. A pattern that legitimately BINDS the origin is
# the expected first false positive; list it, and the list stays the audit.
echo "checking #1110 Mono.TCon mint set ..."
# ⚠️ ONLY FOUR OF THE LINES BELOW ARE MINTS. The declaration line and the
# origin-BINDING PATTERNS are listed here too, because the filter's discriminator is
# the `_` in the origin slot and a pattern that binds the origin cannot be erased by
# it. That is exactly the false positive the remedy predicts — "a pattern that
# legitimately BINDS the origin is the expected first false positive; list it, and
# the list stays the audit" — so they are listed rather than the filter widened.
# NONE OF THEM CONSTRUCTS A `TCon` — that is the property, and it is checked by the
# exact-set comparison, not by counting.
#
# ⚠️ THIS LINE SAID "NONE of the seven" AND THEN ENUMERATED EIGHT FUNCTIONS, two
# lines below the sentence forbidding exactly that. Do not replace it with a
# corrected number: the enumeration below is the set, and the gate's own label
# derives the arithmetic from the allowlist (`$mono_tcon_pats origin-binding
# pattern(s)`) — run the gate if you want a count.
#
#   `TCon n o => Some (headKeyOfCon o n)`  — `headTyconMono`, #1111 A-2.2: the first
#     site in the file to READ an origin, projecting the head into a `HeadKey`.
#   the SIX COMPARISONS — #1111 A-2.10: the "are these the same type?" tests, all
#     routed through `sameTyConHead` (`compiler/frontend/ast.mdk`), which owns the
#     absent-origin rule. In source order: `unifyN`, `cohGoR`, `cohStep` (two
#     lines: the general-side match and its `TCon`/`TCon` inner arm), `cohEqR`,
#     `matchStep`, `monoSameGiven` (two lines, same reason as `cohStep`).
#   `(TCon n1 o1, TCon n2 o2) =>`  — `firstIdConflict`, #1111 A-2.10: the DIAGNOSTIC
#     side of the same rule. It finds the head whose two identities conflict so the
#     otherwise-unreadable `Type mismatch: T vs T` can name the two modules. It is a
#     READER, not a decider — nothing about acceptance goes through it.
#   `TCon "Async" (OriginModule "async") => True`  — `mainTypeIsAsync` (async runtime
#     review fix, #500): the `main : Async` driver rewrite must fire only for the
#     stdlib `async` module's type, so this READS the origin against a literal —
#     the bare-name match it replaced rewrote a user type named `Async` too.
#
# 🚨 THIS LIST IS THE ONLY PLACE THE COMPARISON SET IS ENUMERATED MECHANICALLY.
# ANY further comparison added without listing it here FAILS this gate, which is the
# point: the set is what a reviewer has to grade, and `AGENTS.md`'s wildcard-arm
# hazard says to audit it as a SET rather than one member.  (This sentence said "a
# seventh" while the list already held more than that — an ordinal is a count.)
mono_tcon_allowed="| TCon String TyConOrigin
TCon n o => Some (headKeyOfCon o n)
(TCon n1 o1, TCon n2 o2) =>
TCon \"Async\" (OriginModule \"async\") => True
unifyN (ta@(TCon a oa)) (tb@(TCon b ob)) =
cohGoR _ (TCon a oa) (TCon b ob) = sameTyConHead a oa b ob
TCon a oa => match s
TCon b ob => if sameTyConHead a oa b ob then MOk else MFail
cohEqR (TCon a oa) (TCon b ob) = sameTyConHead a oa b ob
TCon n2 o2 => if sameTyConHead n o n2 o2 then MOk else MFail
TCon x ox => match normalize b
TCon y oy => sameTyConHead x ox y oy
tconBuiltin n = TCon n OriginBuiltin
tconFrom o n = TCon n o
tconTupleHead n = TCon (tupleHeadTagTc n) OriginBuiltin
tconUnresolved n = TCon n OriginUnresolved"
mono_tcon_actual=$(grep -wE 'TCon' "$ROOT/compiler/types/typecheck.mdk" \
  | sed 's/^[[:space:]]*//' \
  | grep -vE '^--' \
  | sed -E 's/[[:space:]]--[[:space:]].*$//' \
  | sed -E 's/TCon (_|[A-Za-z0-9_]+|"[A-Za-z0-9_]+") _//g' \
  | grep -wE 'TCon' \
  | LC_ALL=C sort)
mono_tcon_expected=$(printf '%s\n' "$mono_tcon_allowed" | LC_ALL=C sort)
if [ "$mono_tcon_actual" != "$mono_tcon_expected" ]; then
  echo "FAIL: the #1110 \`Mono.TCon\` construction set changed."
  echo "  allowed (the declaration + the four mints):"
  printf '%s\n' "$mono_tcon_expected" | sed 's/^/    /'
  echo "  actual:"
  printf '%s\n' "$mono_tcon_actual" | sed 's/^/    /'
  echo "  A \`TCon\` built outside \`tconBuiltin\` / \`tconTupleHead\` / \`tconFrom\` /"
  echo "  \`tconUnresolved\` decides a module identity at a site nobody reviewed as"
  echo "  deciding one. Route it through the mint whose NAME states the class:"
  echo "    tconBuiltin     a head the LANGUAGE provides (§8 I6.2(a))"
  echo "    tconTupleHead   the builtin \`__tupleN__\` head"
  echo "    tconFrom        an identity ACQUIRED from a Ty.TyCon or a decl carrier"
  echo "    tconUnresolved  no identity source exists at this site -- say why"
  echo "  Do NOT widen the pattern-vs-construction filter above; add the line here."
  exit 1
fi
# ⚠️ DERIVED, not a hardcoded subtraction.  This label read `- 2` (declaration +
# one bound pattern) and would have been wrong the moment A-2.10 listed six more —
# the same "encoded fact with no derivation" `AGENTS.md` warns about, inside the
# gate that exists to keep a set honest.  The four mints are exactly the allowlist
# rows that CONSTRUCT (` = TCon `); everything else in it is the declaration or a
# pattern.  What actually prevents a silent absorption is still the exact-set
# comparison above, not this arithmetic.
mono_tcon_mints=$(printf '%s\n' "$mono_tcon_expected" | grep -c ' = TCon ')
mono_tcon_pats=$(($(printf '%s\n' "$mono_tcon_expected" | grep -c .) - mono_tcon_mints - 1))
echo "  ok: $mono_tcon_mints Mono.TCon mint(s) + $mono_tcon_pats origin-binding pattern(s), no other construction site"

# The names `tconBuiltin` claims as language-provided must be exactly that, and the
# authority is resolve's own `primitiveTypes` rather than a second hand-kept list here.
#
# ⚠️ WHAT THIS CHECK ACTUALLY BUYS, stated because the first cut claimed something
# stronger and false ("one list read by both layers, so they cannot disagree"). The
# `Ty` layer does NOT answer *from* `primitiveTypes`: `tyOriginScope`
# (compiler/frontend/resolve.mdk) is a LAST-WINS fold whose builtin layer has the
# LOWEST precedence, under prelude, imports and the module's own declarations. What
# closes the gap is a different fact -- `primitiveTypes` is ALSO the duplicate-type
# seed (`duplicateErrors`'s `typeSeed = primitiveTypes ++ …`, unconditional), so no
# module can declare a TYPE of one of these names and the higher layers are empty at
# those keys. Measured: `data List a = …` -> `Duplicate type: List`.
#
# ⚠️ Only the TYPE namespace: `primitiveTypes` does not seed `ifaceSeed`, so
# `interface Int a where …` is accepted (measured, exit 0). It cannot collide here
# because interfaces are keyed `iface:<Name>` while the builtin layer holds the bare
# name -- witness `test/references_fixtures/iface_ty_collide/`.
#
# 🚨 THEREFORE THIS CHECK IS MEMBERSHIP, NOT AGREEMENT, AND CANNOT SEE THE DAY THAT
# CHANGES. If duplicate-type rejection is ever relaxed -- resolve's own comment
# contemplates "a future prelude `data List`" -- an occurrence would carry
# `OriginModule "core"` while `tconBuiltin "List"` still hands out `OriginBuiltin`,
# and this gate would stay GREEN. Whoever relaxes it owes both sites.
prim_block=$(sed -n '/^primitiveTypes : List String$/,/^$/p' "$ROOT/compiler/frontend/resolve.mdk")
prim_names=$(grep -oE 'tconBuiltin "[A-Za-z0-9_]+"' "$ROOT/compiler/types/typecheck.mdk" \
             | sed 's/.*"\(.*\)"/\1/' | LC_ALL=C sort -u)
# ⚠️ COUNTED, not just checked: an empty `prim_names` would walk zero iterations and
# print the same `ok` line as a full pass -- the "a validator that checked nothing
# reads exactly like one that passed" shape the anti-vacuity guards elsewhere in this
# suite exist for. The four ratchets above all print counts; this one now does too.
prim_n=$(printf '%s\n' "$prim_names" | grep -c .)
if [ "$prim_n" -eq 0 ]; then
  echo "FAIL: no \`tconBuiltin \"<name>\"\` call sites found in typecheck.mdk at all."
  echo "  This check just asserted nothing. Either the mint was renamed (update the"
  echo "  grep) or every builtin head moved to another mint (say which, and why)."
  exit 1
fi
prim_bad=""
for n in $prim_names; do
  case "$prim_block" in
    *"\"$n\""*) ;;
    *) prim_bad="$prim_bad $n" ;;
  esac
done
if [ -n "$prim_bad" ]; then
  echo "FAIL: \`tconBuiltin\` is claiming §8 I6.2(a)'s program-global identity for"
  echo "  head(s) that are NOT in compiler/frontend/resolve.mdk's \`primitiveTypes\`:"
  printf '    %s\n' $prim_bad
  echo "  A name outside that list CAN be declared by a module (it is the same list"
  echo "  duplicate-type rejection seeds from), so the Ty layer would attribute it to"
  echo "  that module while this mint calls it builtin. Use \`tconFrom\` with the"
  echo "  acquired origin, or \`tconUnresolved\` if this site genuinely has none."
  exit 1
fi
echo "  ok: $prim_n distinct tconBuiltin head(s), all in resolve's primitiveTypes"

# ── #1110/#1226 carrier-completeness ratchet ────────────────────────────────
# `declHeadOf` (compiler/entries/origin_agreement_main.mdk) has a wildcard fallback
# (`declHeadOf _ = []`), and the decl-layer producer ratchet above hardcodes a
# four-name alternation (`dDataUnresolved|dTypeAliasUnresolved|dNewtypeUnresolved|
# dInterfaceUnresolved`). Both silently ignore any `TyConOrigin` carrier beyond
# TODAY's five fields in compiler/frontend/ast.mdk (`tyConOrigin` on `TyCon`, the
# occurrence carrier, plus the four decl-layer carriers above). #1110 still owes
# three more carrier families (ctor/method/record); when one of those lands it adds
# a SIXTH `: TyConOrigin` field that both switches above would keep ignoring --
# populated and graded by NOTHING, under a green gate that looks like it covers the
# layer. This pins the NAME SET (not a count -- a bare count has no derivation and a
# rename would slip past it) so a new or renamed carrier field fails HERE instead.
#
# ⚠️ TWO CLASSES, PINNED SEPARATELY (#1110 PR B). A single flat name-set could be
# kept green by adding a name to it, which is the masking move this pin exists to
# refuse. So each carrier must declare WHICH grader owns it:
#
#   GRADED -- the agreement probe reads this field by name at runtime. Mechanically
#             verified below: the name must appear OUTSIDE a comment in
#             compiler/entries/origin_agreement_main.mdk.
#   OWED   -- the field exists but no grader reads it yet, with the PR that owes the
#             grading named here. Mechanically SELF-DRAINING below: the name must
#             NOT yet appear in the probe, so the moment someone wires it in, this
#             gate reds and forces the name to move up to the graded set.
#
# The OWED list held #1110 PR B's four interface-OCCURRENCE carriers, which PR B
# could not grade: nothing stamped them yet (PR B was carrier-only), so every arm
# would have reported `OriginUnresolved` and the only thing the probe could print
# was a larger RESIDUAL -- a golden move on a PR whose whole contract was
# byte-identity. PR C landed the stamping AND the grading together, which is
# precisely what the two-sided self-drain below forces, and the four names moved to
# GRADED.
#
# ⚠️ #1110 PR C DRAINED THE OWED LIST TO EMPTY, and the four names moved UP rather
# than being deleted: resolve now stamps the interface-occurrence carriers
# (`fillIfaceOccOrigin` through `mapOriginsInDecl`) and the agreement probe grades them as
# `iface:<Name>` rows. Both halves of the OWED self-drain fired on that change —
# the probe half and the stamper half — which is exactly the promotion this pin was
# built to force. An EMPTY owed list is a legitimate steady state, not a disarmed
# ratchet: the name-set pin below still fails on any new or renamed carrier, and a
# newly-added one has to be classified into one of these two lists to get past it.
carrier_graded_expected="constraintOrigin
dataOrigin
ifaceOrigin
implOrigin
newtypeOrigin
requireOrigin
superOrigin
tyAliasOrigin
tyConOrigin"
carrier_owed_expected=""
# ⚠️ `grep -v '^$'` is load-bearing now that the OWED list can legitimately be
# EMPTY: `printf '%s\n%s\n'` on an empty second argument emits a blank line, which
# sorts FIRST and would make this set comparison fail against a field list that can
# never contain one.
carrier_expected=$(printf '%s\n%s\n' "$carrier_graded_expected" "$carrier_owed_expected" | grep -v '^$' | sort)
# ⚠️ `[[:space:]]+`, NOT `[[:space:]]*`, AND THE CHANGE IS A NARROWING WITH A
# DERIVATION — not the regex-widening the sibling ratchets forbid.  A carrier is a
# RECORD FIELD, and a record field in this file is always INDENTED: it sits inside a
# `Ctor { … }` block, which the offside rule cannot place at column 0.  A TOP-LEVEL
# TYPE SIGNATURE whose FIRST parameter happens to be a `TyConOrigin` is
# indistinguishable from a field under the old `*` form — `tyConIdsConflict :
# TyConOrigin -> TyConOrigin -> Bool` (#1111 A-2.10) was reported as a tenth carrier
# field, and the remedy this gate prints would have had it added to
# `carrier_graded_expected`, i.e. a NON-FIELD listed as a carrier and then required
# to appear in the agreement probe.  Listing it would have been the lie; requiring
# the indentation a field always has is the fix.  (`sameTyConHead` beside it never
# matched, because its first parameter is a `String` — which is exactly why the
# false positive is a coincidence of parameter ORDER and would have recurred.)
carrier_actual=$(grep -oE '^[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*TyConOrigin' "$ROOT/compiler/frontend/ast.mdk" \
  | sed -E 's/^[[:space:]]*//; s/[[:space:]]*:.*$//' | sort)
if [ "$carrier_actual" != "$carrier_expected" ]; then
  echo "FAIL: the set of \`: TyConOrigin\`-typed fields in compiler/frontend/ast.mdk changed."
  echo "  expected:"
  printf '    %s\n' $carrier_expected
  echo "  actual:"
  printf '    %s\n' $carrier_actual
  echo "  A new (or renamed) TyConOrigin carrier is invisible to BOTH of:"
  echo "    - declHeadOf in compiler/entries/origin_agreement_main.mdk -- its wildcard"
  echo "      arm (\`declHeadOf _ = []\`) silently drops any carrier it doesn't name;"
  echo "      add a match arm for the new decl constructor. (Note: an OCCURRENCE"
  echo "      carrier does NOT belong there -- see declHeadOf's own comment.)"
  echo "    - the producer ratchets just above in THIS file -- their hardcoded name"
  echo "      alternations won't see the new carrier's mint helper; add it there too."
  echo "  Update BOTH, then add the field to carrier_graded_expected (if a grader now"
  echo "  reads it) or carrier_owed_expected (naming the PR that owes the grading)."
  exit 1
fi
# GRADED: each name must be read, outside a comment, by the agreement probe.
probe_src="$ROOT/compiler/entries/origin_agreement_main.mdk"
for c in $carrier_graded_expected; do
  if ! ratchet_name_live_in "$c" "$probe_src"; then
    echo "FAIL: carrier \`$c\` is listed as GRADED but compiler/entries/origin_agreement_main.mdk"
    echo "  no longer reads it outside a comment. Either restore the read, or move the"
    echo "  name to carrier_owed_expected and say in the PR which PR owes the grading."
    exit 1
  fi
done
# OWED: the self-drain, pinned in BOTH directions -- the name must be absent from
# the probe AND from the stamper.
#
# The probe half alone pins BOOKKEEPING, not grading, and would have a hole big
# enough to drive the whole hazard through: a later PR could stamp an OWED carrier
# inside compiler/frontend/resolve.mdk and never touch the probe, and EVERY ratchet
# here stays green -- `originun_allowed` already lists resolve.mdk (it is the decl
# stamper's home) and the producer ratchets pin only mint-helper CALL SITES, not
# field writes. The gate would then print `ok: … (N graded, M owed)` over carriers
# that are live, stamped, and graded by nothing -- verbatim the hazard the header
# above says this ratchet exists to prevent. So pin the stamper too: the moment the
# stamp lands, this reds and demands the promotion AND the probe wiring together.
#
# ⚠️ The comment filter is `^[[:space:]]*--`, i.e. LEADING comments only. A TRAILING
# side comment or a string literal that merely NAMES an owed carrier would therefore
# trip this check spuriously -- and the printed remedy would then "fix" it by moving
# the name to the graded list, disarming the tripwire in two lines. That is the
# remedy-disarms-the-tripwire shape, so it is stated rather than left to be
# rediscovered. It is a note and not a code change because both files are clean of
# that shape today (verified: no trailing `--` mentions of any carrier name in
# either), and a looser filter would cost more than it buys.
stamper_src="$ROOT/compiler/frontend/resolve.mdk"
for c in $carrier_owed_expected; do
  if ratchet_name_live_in "$c" "$probe_src"; then
    echo "FAIL: carrier \`$c\` is listed as OWED but compiler/entries/origin_agreement_main.mdk"
    echo "  now reads it -- the grading this list was waiting for has landed."
    echo "  Move \`$c\` from carrier_owed_expected to carrier_graded_expected."
    exit 1
  fi
  if ratchet_name_live_in "$c" "$stamper_src"; then
    echo "FAIL: carrier \`$c\` is listed as OWED but compiler/frontend/resolve.mdk now"
    echo "  WRITES it -- the carrier is live while nothing grades it, which is the"
    echo "  exact state this ratchet exists to refuse."
    echo "  Land the grading in the SAME change: extend the agreement probe"
    echo "  (compiler/entries/origin_agreement_main.mdk) to read \`$c\`, then move it"
    echo "  from carrier_owed_expected to carrier_graded_expected."
    exit 1
  fi
done
echo "  ok: $(printf '%s\n' "$carrier_actual" | grep -c .) TyConOrigin carrier field(s) ($(printf '%s\n' "$carrier_graded_expected" | grep -c .) graded, $(printf '%s\n' "$carrier_owed_expected" | grep -c .) owed)"

# The name-set pin above matches `<name> : TyConOrigin`, so it only sees a
# NAMED-record field -- verified by mutation: a new named field fires it, a
# rename fires it, tab-indent fires it, but a POSITIONAL carrier (e.g.
# `Variant String ConPayload TyConOrigin`, no field name at all) is SILENT, and
# so is a field reached through a type alias. That gap is not academic:
# `Variant` (ConPayload's ctor), `IfaceMethod`, and `Field` are ALL positional
# today, and #1110's three remaining carrier families (ctor / method / record)
# land on exactly those -- the name-set pin would stay green while reproducing
# the very hole it exists to close. This second pin is FORM-INDEPENDENT: every
# literal mention of `TyConOrigin` in ast.mdk (the data decl itself, plus each
# named or positional type occurrence) moves this count, named or not. It
# complements rather than replaces the name-set pin above: a RENAME holds this
# count steady (same mention, different name) but changes the name set, which
# only the pin above catches; a POSITIONAL addition holds the name set steady
# but moves this count, which only THIS pin catches.
# 6 -> 10 (#1110 PR B): the four interface-occurrence carriers
# (`constraintOrigin` / `superOrigin` / `requireOrigin` / `implOrigin`). Every one is
# a NAMED field, so the name-set pin above sees them too; this count moves for the
# same four and is bumped for that reason and no other.
#
# 10 -> 11 (#1047, Stage A-2 unit A-2.9): `ifaceIdentity : TyConOrigin -> String ->
# String`, ast.mdk's first CONSUMER of the carrier — the function that projects
# `(originModule, name)` into the one comparable string the Core IR's
# `CImplDefault` and eval's default cells carry.  It is a READER, not a carrier:
# it adds no field to any node, mints no origin, and declares no new inhabitant,
# so neither `declHeadOf` nor either producer ratchet gains an arm (adding one
# would be the contradiction this gate's own message warns about).  The name-set
# pin above is correctly silent — a signature is not a named record field — and
# this form-independent count is correctly NOT, which is exactly the division of
# labour the paragraph above describes.  Bumped for that reason and no other.
#
# 11 -> 13 (#1111, Stage A-2 unit A-2.0): `identOriginOf : TyConOrigin -> Option
# IdentOrigin` and `mkIdent : Ns -> TyConOrigin -> String -> Option Ident`, the
# substrate's two CONSUMERS of the carrier — the total conversion from a
# pipeline-stage-marked `TyConOrigin` to the well-formed `IdentOrigin` that keys
# every re-keyed cross-module table, and the convenience form over it.  Exactly
# the same class as the 10 -> 11 bump above and bumped for the same reason: both
# are READERS.  Neither adds a field to any node, mints an origin, or declares a
# new `TyConOrigin` inhabitant, so no `declHeadOf` arm and no producer-ratchet
# entry is owed — and the carrier field set is INDEPENDENTLY still `9 graded, 0
# owed`, which is the pin that would have caught a real carrier sneaking in here.
#
# ⚠️ This bump was forced by the MERGE QUEUE, not by either branch: #1264 set this
# to 11 and #1262 added the two signatures, so both were green alone and the
# merged tree was red.  That is the pin working.  Any A-2 unit that adds a
# `TyConOrigin` reader to ast.mdk while another is in flight will land here again;
# re-derive with
#   grep -w 'TyConOrigin' compiler/frontend/ast.mdk | grep -cvE '^[[:space:]]*--'
# rather than trusting this number.
#
# 13 -> 15 (#1111, Stage A-2 unit A-2.10): `sameTyConHead : String -> TyConOrigin ->
# String -> TyConOrigin -> Bool` and `tyConIdsConflict : TyConOrigin -> TyConOrigin
# -> Bool` — the seam every "are these the same type?" comparison in
# `types/typecheck.mdk` now goes through.  Same class as both bumps above and
# bumped for the same reason: READERS.  No field on any node, no mint, no new
# inhabitant, so no `declHeadOf` arm and no producer-ratchet entry is owed, and the
# carrier field set is INDEPENDENTLY still `9 graded, 0 owed`.
#
# ⚠️ `tyConIdsConflict` ALSO tripped the NAME-SET pin above, which the paragraph
# there says is "correctly silent — a signature is not a named record field".  That
# claim was true of every prior reader by ACCIDENT OF PARAMETER ORDER and false for
# this one: its first parameter is a `TyConOrigin`, so `^[[:space:]]*NAME[[:space:]]*:
# [[:space:]]*TyConOrigin` matched the signature.  The discriminator was narrowed to
# require the indentation a record field always has; the derivation is at that grep.
#
# 15 -> 16 (sprint/ctor-identity, S-ctor-oracle-identity leaf 1, the `TabKey`
# re-home): `tabKeyOf : Ns -> TyConOrigin -> String -> TabKey`. Same class as both
# bumps above: a READER. `TabKey = TkIdent Ident | TkBare Ns String`, `Ident = Ident
# Ns IdentOrigin String` — no `TyConOrigin` anywhere in the result type, so
# `tabKeyOf` provably consumes and discards; its result cannot carry an origin even
# in principle. No field on any node, no mint, no new inhabitant, so no
# `declHeadOf` arm and no producer-ratchet entry is owed, and the carrier field set
# is INDEPENDENTLY still `9 graded, 0 owed`.
carrier_count_expected=16
# Comment-filtered, matching the idiom the three sibling ratchets above already
# use (`grep -w … | grep -qvE '^[[:space:]]*--'`). An unfiltered count reds this
# gate on a COMMENT-ONLY diff that merely names `TyConOrigin` in prose -- someone
# trips on that and bumps 6->7, and the pin now has SLACK: a later PR that adds a
# genuine positional carrier (+1) while deleting that comment (-1) lands back on 7
# with BOTH pins silent, reopening the exact hole this pin exists to close. The
# spurious-trip class IS the masking class -- filter it out at the source.
carrier_count_actual=$(grep -w 'TyConOrigin' "$ROOT/compiler/frontend/ast.mdk" \
  | grep -cvE '^[[:space:]]*--')
if [ "$carrier_count_actual" != "$carrier_count_expected" ]; then
  echo "FAIL: the number of \`TyConOrigin\` mentions in compiler/frontend/ast.mdk changed"
  echo "  (expected $carrier_count_expected, got $carrier_count_actual)."
  echo "  The name-set pin just above only sees NAMED-record fields, so it is SILENT on"
  echo "  a POSITIONAL TyConOrigin carrier (e.g. \`Variant String ConPayload TyConOrigin\`)"
  echo "  or one reached through a type alias -- both move THIS count instead."
  echo "  If you added a genuine new carrier -- FIRST decide which LAYER it is on,"
  echo "  because the remedy differs and getting it backwards is a contradiction:"
  echo "    - DECL-layer (a type DECLARATION acquires identity): add a match arm to"
  echo "      declHeadOf in compiler/entries/origin_agreement_main.mdk (its wildcard"
  echo "      arm silently drops any carrier it doesn't name), and add its mint"
  echo "      helper to the DECL-layer producer ratchet above in THIS file."
  echo "    - OCCURRENCE-layer (a USE site names a head someone else declared): do"
  echo "      NOT add a declHeadOf arm -- that function's own comment forbids it for"
  echo "      exactly this case ('DImpl mints NO decl-layer carrier and must not"
  echo "      appear here'). Add the mint helper to the OCCURRENCE-layer producer"
  echo "      ratchet above instead, and grade it in the probe's occurrence walk."
  echo "    - then classify the field: add it to carrier_graded_expected (a grader"
  echo "      reads it) or carrier_owed_expected (grading owed; name the PR that owes"
  echo "      it). Do NOT edit carrier_expected -- it is DERIVED from those two."
  echo "    - then update carrier_count_expected here to the new mention count,"
  echo "      and say why in the PR."
  exit 1
fi
echo "  ok: $carrier_count_actual TyConOrigin mention(s) in ast.mdk (name-set + positional)"

# ── #1318 B-4 predicate-slot producer-authority ratchet ─────────────────────
# Function, impl-`requires`, method, recursive, and cross-module consumers share
# record-valued carriers. One complete predicate owns one dict slot; argument vectors
# and method quantifier positions are fields of that slot, never parallel authorities.
predicate_slot_src="$ROOT/compiler/types/typecheck.mdk"
predicate_slot_required='data PredicateSlotArgs = PSArgsUnknown | PSArgsKnown (List Mono)
data PredicateRequest = PredicateRequest {
data PredicateSlot = PredicateSlot {
data MethodPredicateSlot = MethodPredicateSlot {
data PendingMethodDict = PendingMethodDict {
implReqPredicateSlot : (String, List Int, Predicate) -> (String, PredicateSlot)
setFunConstraintEntry : String -> List PredicateSlot -> Unit
registerActiveDictVars : String -> Int -> List PredicateSlot -> Unit
recordCallObligations : List CSlot -> List Mono -> List (List Mono) -> Unit
expandPredicateSlots : List Decl -> List PredicateSlot -> List PredicateSlot
predicateRequestMatchesSlot : PredicateRequest -> PredicateSlot -> Bool
&& sameIfaceDecl request.prIface slot.psIface
monoVecSameGiven requestArgs slotArgs
activeDictPreds : Ref (List (PredicateSlot, String))
registerFunPredGiven : PredicateSlot -> String -> Unit
activeFunDictPredOf : PredicateRequest -> String -> Option String
goalRequestOfKind : String -> EntailKind -> Option PredicateRequest
goalPredOf : String -> Mono -> Option PredicateRequest
goalPredOfOp : String -> Option PredicateRequest
activeDictVarOfEncl : Option PredicateRequest -> Mono -> String -> Option String
activeDictVarOfEncl None m encl = activeDictVarForEncl m encl
activeDictVarOfEncl (Some request) m encl =
enclSlotIndex : Option PredicateRequest -> Int -> String -> Option Int
enclSlotIndex None target encl = indexOfId target (enclSlotIds encl)
enclSlotIndex (Some request) target encl =
implReqPick : Int ->
entailAssumVar _ m encl _ (EKNestedTop iface _ _ _ rest) =
goalMatchesGiven : IfaceRef -> List Mono -> Bool
anyGivenMatches : PredicateRequest -> List (PredicateSlot, String) -> Bool
implReqPredicateSlots : Ref (List (String, PredicateSlot))
funPredicateSlotsRef : Ref (List (String, List PredicateSlot))
methodPredicateSlotsRef : Ref (List (String, List MethodPredicateSlot))
crossModuleFunPredicateSlotsRef : Ref (List (String, List PredicateSlot))
crossModuleFunPredicateSlotsQualRef : Ref (List ((String, String), List PredicateSlot))
crossModuleMethodPredicateSlotsRef : Ref (List (String, List MethodPredicateSlot))
crossModuleMethodPredicateSlotsQualRef : Ref (List ((String, String), List MethodPredicateSlot))
perRun.value.funPredicateSlotsRef :=
perRun.value.implReqPredicateSlots :=
perRun.value.methodPredicateSlotsRef :=
crossRun.value.crossModuleFunPredicateSlotsRef :=
crossRun.value.crossModuleFunPredicateSlotsQualRef
crossRun.value.crossModuleMethodPredicateSlotsRef :=
crossRun.value.crossModuleMethodPredicateSlotsQualRef
registerMethodConstraints : List String ->
setMethodPredicateSlotEntry : String -> List MethodPredicateSlot -> Unit
methodDictArityOf : String -> Int
resolveMethodDicts : ImplBuckets -> List PendingMethodDict -> Unit
pending.pmdRoutesRef :=
methodPredicateRoutes : ImplBuckets ->
methodPredicateRoute : ImplBuckets -> String -> PredicateSlot -> Route
realizeRecDictApps : ImplBuckets -> List RecDictApp -> Unit
recRoutes : ImplBuckets -> String -> Mono -> List PredicateSlot -> List Route
recRoute : ImplBuckets -> String -> Mono -> PredicateSlot -> Route
scopePredicateSlots : List ((String, String), List PredicateSlot) ->
scopeMethodPredicateSlots : List ((String, String), List MethodPredicateSlot) ->
attributeMethodModulePredicateSlots : String ->'

printf '%s\n' "$predicate_slot_required" | while IFS= read -r required; do
  if ! grep -Fq "$required" "$predicate_slot_src"; then
    echo "FAIL: #1318 predicate-slot producer authority is missing required source: $required"
    exit 1
  fi
done || exit 1

predicate_slot_old_consumers='setFunConstraintEntry : String -> List CSlot -> Option (List (List Mono)) -> Unit
registerActiveDictVars : String -> Int -> List Int -> Unit
recordCallObligations : List CSlot -> List Mono -> Unit
predArgsAgreeEncl : List Mono -> List Mono -> Bool
predArgsAgreeSameInstantiation : List Mono -> List Mono -> Bool
registerFunPredGiven : String -> PredicateSlotArgs -> String -> Unit
activeFunDictPredOf : String -> List Mono -> String -> Option String
activeDictPreds : Ref (List (String, List Mono, String))
implReqPick : Int -> Predicate -> String -> Bool -> List (String, PredicateSlot) -> Option String
enclSlotIndex : Option Predicate -> Int -> String -> Option Int
enclSlotIndex (Some p) target encl = match indexOfPred target p (enclPreds encl)
None => indexOfId target (enclSlotIds encl)
entailAssumVar m encl _ (EKNestedTop _ _ _ _ _) = activeDictVarForEncl m encl'

printf '%s\n' "$predicate_slot_old_consumers" | while IFS= read -r retired; do
  if grep -Fq "$retired" "$predicate_slot_src"; then
    echo "FAIL: #1318 retired predicate-slot consumer is present: $retired"
    exit 1
  fi
done || exit 1

# Deferred operator routes keep their lexical evidence owner through the concrete-head
# stamper.  The scalar registry is global and uncleared, so an empty owner or an
# owner-prefix miss must not borrow another method's dict.  The direct in-impl operator
# bypass remains a separately tracked residual and is pinned independently below.
lexical_dict_block="$(sed -n '/^activeDictVarForEncl :/,/^firstDictForEncl :/p' "$predicate_slot_src")"
printf '%s\n' "$lexical_dict_block" | grep -Fq '| encl == "" = None' || {
  echo "FAIL: activeDictVarForEncl must reject an empty evidence owner"
  exit 1
}
printf '%s\n' "$lexical_dict_block" | grep -Fq 'TVar cell =>' || {
  echo "FAIL: activeDictVarForEncl must retain its type-variable lookup arm"
  exit 1
}
printf '%s\n' "$lexical_dict_block" | grep -Fq 'firstDictForEncl' || {
  echo "FAIL: activeDictVarForEncl must reject an owner-prefix miss"
  exit 1
}
if printf '%s\n' "$lexical_dict_block" | grep -Fq 'activeDictVarOf m'; then
  echo "FAIL: activeDictVarForEncl retains a non-lexical global fallback"
  exit 1
fi

operator_owner_required='stampOpRouteVal : Bool ->
let reqs = argImplDictRoutesForEncl
entailInst implTable name m encl tag (EKOp isBinop _) =
(stampOpRouteVal isBinop implTable encl name m tag, [])'
printf '%s\n' "$operator_owner_required" | while IFS= read -r required; do
  if ! grep -Fq "$required" "$predicate_slot_src"; then
    echo "FAIL: operator route dropped its evidence owner: $required"
    exit 1
  fi
done || exit 1
if grep -Fq 'argImplDictRoutesFor :' "$predicate_slot_src"; then
  echo "FAIL: owner-erasing argImplDictRoutesFor wrapper remains"
  exit 1
fi

op_dict_block="$(sed -n '/^opDictVarOf :/,/^resolveOpSite :/p' "$predicate_slot_src")"
printf '%s\n' "$op_dict_block" | grep -Fq '| inImpl = activeDictVarOf m' || {
  echo "FAIL: direct opDictVarOf in-impl residual moved during the lexical cutoff"
  exit 1
}

predicate_relation_uses=$(grep -F 'predicateRequestMatchesSlot request' "$predicate_slot_src" \
  | grep -cvE '^[[:space:]]*--')
if [ "$predicate_relation_uses" -ne 6 ]; then
  echo "FAIL: #1318 shared request/slot relation must serve all five identity consumers plus its definition (got $predicate_relation_uses)"
  exit 1
fi

predicate_slot_retired='implReqPreds
funConstraintsRef
funConstraintIfacesRef
funConstraintArgsRef
crossModuleFunConstraintsRef
crossModuleFunConstraintsQualRef
crossModuleFunConstraintIfacesRef
crossModuleFunConstraintIfacesQualRef
crossModuleFunConstraintArgsQualRef
methodConstraintsRef
methodConstraintIdsRef
methodConstraintPositionsRef
crossModuleMethodConstraintsRef
crossModuleMethodConstraintsQualRef
legacyCSlotsOfPredicateSlots
legacyArgsOfPredicateSlots
predicateSlotOfImplReq
legacyImplReqOfPredicateSlot
predicateSlotShadowCompare
shadowImplReqEntry
unknownPredicateSlot
unknownPredicateSlotsEntry
unknownPredicateSlotsTable
predicateSlotIdsEntry
predicateSlotIdsTable
alignedMethodConstraintIds
positionMatch
bestAlignedEntry
countInSubst
scopeMethodArities
attributeMethodModuleConstraints'

printf '%s\n' "$predicate_slot_retired" | while IFS= read -r retired; do
  if grep -w "$retired" "$predicate_slot_src" \
    | grep -vE '^[[:space:]]*--' >/dev/null; then
    echo "FAIL: #1318 retired predicate-slot authority is present in live source: $retired"
    exit 1
  fi
done || exit 1
echo "  ok: #1318 predicate-slot exclusive authority present; retired split authorities absent"

# ── #1111 Stage A-2 unit A-2.8: registry keying ratchet ─────────────────────
# Mechanical enforcement for the registry-keying arc (re-keying ~15
# program-global cross-module tables from bare names to qualified identity):
# pins CrossRun's and DriverState's field sets, their setRef write targets,
# and the three engine module drivers' frame-seeding parity. Deliberately
# NOT a standalone test/*.sh gate -- see test/registry_keying_ratchet.sh's own
# header for why it rides inside this already-CI-wired script instead.
if ! sh "$ROOT/test/registry_keying_ratchet.sh" "$ROOT"; then
  exit 1
fi

# ── Pass 3: the ELABORATE driver's view of the SAME closure (issue #1811) ───
#
# ⚠️ SCOPE, STATED UP FRONT: passes 1-2 cover the FULL compiler-source closure
# (`medaka_cli.mdk` plus every entry point under compiler/entries/ — 71 closures as
# of this writing); pass 3 covers `medaka_cli.mdk` ALONE — 1 closure, not the set.
# The reason is cost, not principle: this arm
# pays a whole `medaka build` per closure (~40s at -O0, see below) against the
# compiler-soundness job's time budget, so running it per entry does not fit. The
# PASS lines at the end of this pass are scoped to match; keep them that way.
#
# Passes 1 and 2 run ONE driver: `analyzeProject` / `diagnostics_project_main` —
# the same pass `medaka check` uses.  `medaka run` / `medaka build` do NOT use it
# alone: they run a SECOND typecheck through `elaborateModules`, which first runs
# `buildStandaloneShadowsGraph` + `prePassDictArg` over the WHOLE graph (mangled,
# graph-global) and only then typechecks.  A type error that only that rewrite
# derives is invisible to passes 1 and 2 by construction — `check` exits 0 while
# `run`/`build` exit 1 with "type error … detected during elaboration" (#1812).
#
# That is not hypothetical: the four-module `A2` corpus (an alias import plus an
# imported standalone shadowing an interface method) reads `check=0 build=1` on
# this very tree.  So `compiler-soundness` — the job that exists because "ALL the gate
# shards pass on an ill-typed compiler" — was vetting the compiler with an
# instrument blind to a whole class of ill-typedness.  This pass closes that:
# it puts the compiler's own closure through the elaborate driver's gate, which
# is exactly what `medaka build` does (typecheckGateRoute, medaka_cli.mdk:
# `resetTypeErrorsSticky` → `elaborateModules` → `hadTypeErrors`).
#
# WHY THE WHOLE `build`, AND NOT SOMETHING NARROWER.  No entry point exposes
# "elaborate + hadTypeErrors" on its own: the emit drivers (entry_support.mdk's
# runEmitWith) call `elaborateModules` and never read `hadTypeErrors`, so they
# are not fail-capable for this.  `medaka build` is the only shipped consumer of
# that gate that reaches a whole project, so the arm pays for the emit + clang
# tail it does not need.  MEDAKA_CLANG_OPT=-O0 keeps that tail cheap (the binary
# is discarded): 40s at -O0 against 77s at the -O2 default, measured on the dev
# box.  If a narrower fail-capable seam ever exists, this should move to it.
#
# ⚠️ MEDAKA_STRICT=1 is deliberate ([B-STALENESS]): the arm is only meaningful if
# ./medaka was built from THIS compiler/ tree, and a stale binary must say so
# loudly rather than answer about someone else's source.  The failure branch
# below discriminates that case, and a non-type failure generally, from the type
# diagnostic this arm exists to surface.
MEDAKA_BIN="${MEDAKA:-$ROOT/medaka}"
if [ ! -x "$MEDAKA_BIN" ]; then
  echo "SKIP: the elaborate arm needs the compiler binary: run \`make medaka\` first (missing $MEDAKA_BIN)"
  exit 2
fi
if [ -z "${MEDAKA_EMITTER:-}" ] && [ ! -x "$ROOT/medaka_emitter" ]; then
  echo "SKIP: the elaborate arm needs the native emitter: run \`make medaka\` first (missing $ROOT/medaka_emitter)"
  exit 2
fi

elab_log="$RESULTS/elaborate.log"
# [D-BUILD-PIPE]: `medaka build`'s exit code does NOT survive a pipe — redirect
# to a file, read $? immediately, and read the file only afterwards.
(cd "$ROOT" && MEDAKA_STRICT=1 MEDAKA_CLANG_OPT=-O0 \
  "$MEDAKA_BIN" build "$ENTRY" -o "$RESULTS/medaka_cli.elabprobe") > "$elab_log" 2>&1
elab_status=$?

if [ "$elab_status" -ne 0 ]; then
  if grep -q 'may be stale; rebuild' "$elab_log"; then
    echo "FAIL: the elaborate arm ran a STALE ./medaka (MEDAKA_STRICT=1 tripped) — this says"
    echo "  nothing about the compiler source. Rebuild with \`make medaka\` and re-run."
  elif grep -qE '^error(@|:)|error: type error in' "$elab_log"; then
    echo "FAIL: compiler source has a type error the CHECK driver does not derive"
    echo "  (medaka_cli.mdk closure, elaborate driver — passes 1/2 above were GREEN)."
    echo "  This is the #1811 class. Do NOT weaken or narrow this arm to make it pass."
  else
    echo "FAIL: the elaborate arm exited $elab_status with no type diagnostic — that is a"
    echo "  defect in THIS arm's mechanism (emitter gap, clang, resource limit), not a"
    echo "  finding about the compiler's types. Fix the arm, do not bless the output."
  fi
  cat "$elab_log"
  exit 1
fi

echo "PASS: elaborate driver clean for ONE closure only: $ENTRY (medaka build's"
echo "  elaborate + hadTypeErrors gate). The $n_entries entry closures passes 1-2 cover are NOT"
echo "  covered by this arm — see the cost note in pass 3's header."

echo "PASS: compiler source is type-clean (0 error-severity diagnostics; CHECK driver across"
echo "  $ENTRY + $n_entries entries, ELABORATE driver across $ENTRY only)."
exit 0
