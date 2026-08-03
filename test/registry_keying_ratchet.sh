#!/bin/sh
# test/registry_keying_ratchet.sh — #1111 Stage A-2 unit A-2.8: the registry
# keying RATCHET.
#
# NOT A STANDALONE GATE. Invoked from test/typecheck_compiler_source.sh (which
# already runs in the required `soundness` CI job) rather than wired directly
# into ci.yml. Reason: a new top-level test/*.sh matching the
# `test/diff_compiler_*.sh` shape but absent from any shard pattern in
# .github/workflows/ci.yml SILENTLY NEVER RUNS -- diff_compiler_ci_shard_coverage.sh
# bounces exactly that PR shape. Folding into an already-wired gate sidesteps
# the whole hazard: no new CI wiring, no CI-COVERAGE-*.txt row, no chance of a
# silent no-run. Verified directly against this tree:
#   grep -n typecheck_compiler_source .github/workflows/ci.yml
# -> matched only inside run_gates.sh's own EXTRA_GATES wiring (which
#    typecheck_compiler_source.sh's own header comment documents), which the
#    `soundness` job in ci.yml invokes via `sh test/run_gates.sh` with
#    EXTRA_GATES engaged. There is no direct `ci.yml` line naming this script,
#    which is exactly why THIS gate must ride inside it rather than beside it.
#
# WHAT THIS PINS. Stage A-2 (#1111) is re-keying ~15 program-global
# cross-module tables from bare names to qualified (module, name) identity,
# because two modules declaring the same type/interface/method/constructor
# name currently collapse into one table entry, silently. This script is the
# MECHANICAL ENFORCEMENT, not a re-keying -- it does not change any table's
# representation. It buys two things:
#   1. no *new* bare-name-keyed cross-module table/accumulator/write-site can
#      be added without a reviewer consciously touching an allowlist here;
#   2. each later A-2 unit's progress is visible as a row LEAVING an
#      allowlist as it re-keys (or consolidates a bare/qualified field pair
#      into one) a table this pins.
#
# THREE CHECKS:
#   1. CrossRun + DriverState FIELD allowlist (compiler/types/typecheck.mdk)
#   2. the cross-module WRITER ratchet: every `setRef crossRun.value.*` /
#      `setRef driverState.value.*` site, pinned by TARGET FIELD (load-bearing)
#   3. the THREE parallel engine module drivers' frame-seeding parity
#      (evalModulesWith / evalModulesRootEnvWith / cevalModules)
#
# 🚨 REMEDY WHEN ANY CHECK FIRES: add the offending FIELD/LINE to the relevant
# allowlist below and justify it in the PR -- never widen a pattern to make a
# check stop firing. Widening is the masking path: every pattern here matches
# on the THING being enumerated (a field name, a qualified write target, a
# fixed call shape) and relaxing it re-admits exactly what the check exists to
# name. A later A-2 unit legitimately EDITING a pinned site is expected to
# touch the allowlist in the same PR -- that edit is the review point, not a
# thing to avoid.
#
# 🔬 POSITIVE CONTROL -- apply each to compiler/types/typecheck.mdk (or the
# named file), rerun this script, restore. RUN ALL SIX if you touch any
# extraction/filter in this file. Green means NOTHING unless B, C, D and E all
# FAIL and A, F pass.
#   A  (unmodified tree)                                            -> pass
#   B  add `rogueRef : Ref (OrdMap Int),` as a new CrossRun field    -> FAIL (check 1)
#   C  add `let _ = setRef crossRun.value.rogueRef (f prog)` on its
#      OWN line inside appendUniverseAccums                          -> FAIL (check 2)
#   D  add, ON ONE LINE, an allowlisted write AND a rogue one:
#      `let _ = setRef crossRun.value.universeFunNamesRef (f prog) in
#       setRef crossRun.value.rogueRef (f prog)`                     -> FAIL (check 2)
#         <- THE A-1 HOLE. If D passes while C fails, the filter is
#            per-LINE (treats "line contains an allowed substring" as
#            "line is accounted for") instead of per-OCCURRENCE, and
#            this ratchet is already holed exactly like that one was.
#   E  delete the `installDispatchTables allDecls` line from ONE of
#      the three module drivers (eval.mdk's evalModulesWith or
#      evalModulesRootEnvWith, or core_ir_eval.mdk's cevalModules)    -> FAIL (check 3)
#   F  add a COMMENT line mentioning `setRef crossRun.value.foo`      -> pass
#      (a side comment is not a write: must not false-positive)
#
# All six were actually executed against this tree while writing this script
# (mutate, rerun, restore) -- not reasoned about. See the PR description / the
# authoring report for the six observed results.
#
# Implementation note on how D is made to fail correctly: every extraction
# below uses `grep -oE` (extract ALL non-overlapping occurrences on a line),
# never a line-level "does this line contain an allowed substring" test. A
# line carrying two `setRef crossRun.value.*` targets yields TWO extracted
# tokens, each independently checked against the allowlist -- so an allowed
# token sharing a line with a rogue one cannot hide the rogue one. This is the
# occurrence-level discipline the #1110 Mono.TCon ratchet's own header
# demands (`sed '...'//g` erase-in-place); grep -oE gets the same property
# here without needing an erase step, because it already decomposes a line
# into independent matches rather than testing the line as one unit.
#
# Comments are stripped (full `--`-led lines dropped, trailing ` -- ...` cut)
# before any extraction, so control F cannot false-positive.
#
# Usage: sh test/registry_keying_ratchet.sh [ROOT]
# Exit:  0 all three checks pass; 1 a ratchet fired (offending item printed).
set -u

if [ "${1:-}" != "" ]; then
  ROOT="$1"
else
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
TC="$ROOT/compiler/types/typecheck.mdk"
EV="$ROOT/compiler/eval/eval.mdk"
CIE="$ROOT/compiler/ir/core_ir_eval.mdk"

# ── shared helpers ──────────────────────────────────────────────────────────

# join_setref FILE: this codebase writes some `setRef` calls as
#   setRef
#     <target>
#     (<value>)
# (bare `setRef` at the end of one line, the target alone on the next) as well
# as the single-line `setRef <target> (<value>)` form. A grep for the literal
# substring `setRef crossRun.value.` on its own MISSES the split form outright
# -- verified against this file: the naive single-line grep the #1111 brief
# itself suggests undercounts CrossRun's writer set by one field
# (universeIfaceRequiredRef, written via the split form at what is currently
# typecheck.mdk:18411-18413) and DriverState's by two (effectDomains,
# abstractRecordTypesRef). This helper joins a bare trailing `setRef` line
# with the line that follows it -- as an EXTRA synthesized line emitted ahead
# of the untouched original stream, so nothing is dropped and the single-line
# form still matches exactly as before.
join_setref() {
  awk '
    {
      if (pend) { print pendline " " $0; pend = 0 }
      line = $0
      trimmed = line
      gsub(/^[ ]+/, "", trimmed)
      gsub(/[ ]+$/, "", trimmed)
      if (trimmed == "setRef" || trimmed ~ /^.* setRef$/) { pend = 1; pendline = line }
      print line
    }
  ' "$1"
}

# strip a full-comment line outright; cut a trailing side comment in place.
strip_comments() {
  grep -vE '^[[:space:]]*--' | sed -E 's/[[:space:]]--[[:space:]].*$//'
}

# body_of FILE START_REGEX: a function's own equation line (the line START_REGEX
# matches) through, but NOT including, the next top-level (column-0) decl --
# every body line in this codebase is indented, so the next column-0 line is
# always the boundary. Never drops interior comment lines (they start with
# `-`, not a letter, so they don't trip the boundary test).
body_of() {
  awk -v start="$2" '
    $0 ~ start { found=1; print; next }
    found && /^[A-Za-z_]/ { exit }
    found { print }
  ' "$1"
}

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 1 — CrossRun / DriverState FIELD allowlist
# ═══════════════════════════════════════════════════════════════════════════
# Seeded with TODAY's full field set (derived below, not assumed) -- this
# check asserts nothing about the existing 43 fields' correctness, only that
# no NEW field is added to either bundle without a reviewer adding a row here
# with its own one-line reason. As each later A-2 unit re-keys a table, its
# row here is the place that PR touches (a rename, or two bare/qualified
# mirror fields consolidating into one qualified field), so the allowlist
# shrinking over the arc is the mechanically visible progress signal.
#
# ⚠️ DERIVED, NOT TRUSTED: CrossRun's own comments (typecheck.mdk:2671, :2709,
# :2775, :2789) say "22" or "23" cross-module accumulators. Extracting the
# record's actual field block gives 25 -- the comments are stale by two or
# three fields apiece. Trust the extraction; the comments are prose, not a
# gate. (DriverState's own "~18 RESIDUAL survivor Refs" comment at :2204-2214
# DOES match its actual field count of 18.)
echo "checking #1111 CrossRun / DriverState field allowlist ..."

cross_allowed='universeIfaceMethodsRef -- accumulated interface-method NAME set across all modules (definer-shadow checks)
universeFunNamesRef -- accumulated top-level fn NAME set across all modules (importer-shadow checks)
universeKeyBucketsRef -- accumulated impl-existence key buckets (implExistsForHead)
universeIfaceRequiredRef -- accumulated iface -> required-method-names map (impl completeness); IDENTITY-KEYED since A-2.4 (a Registry keyed by regKeyOfTab (ifaceTabKey <ifaceOrigin/implOrigin> name); drained #1258. Flat/single-file rows key TkBare until #1115 -- but this table is READ only on the Module arm)
universeMethodIfaceParamsRef -- accumulated method -> iface param map (#822 kind universe, iface half)
universeRegisteredIfacesRef -- accumulated registered-iface set, paired with the map above. STILL BARE-NAME, DELIBERATELY, and A-2.4 examined it and declined: the value is Unit, so a collapse selects no row; all three readers (recordIfaceObligation / inferNumLit / checkOneCallObligation, via ifaceRegistered) pass a LITERAL prelude name with no TyConOrigin to key from; and what it gates is the obligation channel, which is itself "<iface>|<tag>"-keyed and belongs to A-2.2. Full derivation on ifaceRegistered in typecheck.mdk. Revisit WITH obUniv*, not before
universeMethodDispatchIdxRef -- accumulated interface dispatch-index list
universeRecordByName -- accumulated record name -> RecordInfo map
universeFieldOwners -- accumulated field-name -> owning-record(s) map
universeDataParamKinds -- accumulated data-type param-kind list; IDENTITY-KEYED since A-2.3 (TabKey; flat/single-file table holds BOTH populations -- prelude rows key TkIdent via stampDeclOrigins "core", flat USER rows have no identity and stay TkBare until #1115)
universeIfaceParamKinds -- accumulated interface param-kind list (#822, iface half of the kind universe); IDENTITY x SLOT-KEYED since A-2.4 (RegKey via regKeyTabAt (ifaceTabKey o iface) i, replacing the "<iface>@<slot>" string; drained #1257. Read on BOTH driver arms, so flat/single-file rows key TkBare until #1115)
universeAliasTable -- accumulated type-alias table; IDENTITY-KEYED since A-2.3 (TabKey; flat/single-file table holds BOTH populations -- prelude rows key TkIdent via stampDeclOrigins "core", flat USER rows have no identity and stay TkBare until #1115)
universeDataEnv -- accumulated ctor environment (bare-name, last-write-wins -- the thing #674 works around)
universeDataDecls -- accumulated PUBLIC data decls (#674: recovers per-module ctor identity universeDataEnv loses)
obUnivConcreteRef -- accumulated concrete-instance obligation-impl universe bucket
obUnivHeadlessRef -- accumulated headless obligation-impl universe bucket
obUnivIfaceTagsRef -- accumulated iface-tag obligation-impl universe bucket
crossModuleFunConstraintsRef -- cross-module fn constraint-arity snapshot, bare name
crossModuleFunConstraintsQualRef -- cross-module fn constraint-arity snapshot, module-qualified mirror
crossModuleFunConstraintIfacesRef -- cross-module fn constraint-iface snapshot, bare name
crossModuleFunConstraintIfacesQualRef -- cross-module fn constraint-iface snapshot, module-qualified mirror
crossModuleMethodConstraintsRef -- cross-module method constraint-arity snapshot, bare name
crossModuleMethodConstraintsQualRef -- cross-module method constraint-arity snapshot, module-qualified mirror
coreSchemeObligationsRef -- #673: core pass own scheme-obligations snapshot, taken after the core pass'

driver_allowed='effectDomains -- effect-label -> domain-param registry; driver-set-once preamble state, single writer
abstractRecordTypesRef -- abstract (opaque) record TYPE names, seeded once over the whole module graph
argDispatchIdxRef -- arg-position dispatch index list, seeded once over allDecls
dictEligibleRef -- dict-eligible fn NAME list, module-path scratch set fresh per elaboration
dictEligibleSetRef -- dict-eligible fn NAME set, OrdMap mirror of dictEligibleRef for O(log) membership
mangledShadowMapRef -- mangled-name -> bare-method-name shadow map, emit path only (P0-18)
userIfaceNamesRef -- user-declared interface NAME set, gates super-expansion (WS-1b)
coherenceUserDecls -- user decls consulted by coherence warnings
superDeclsRef -- interfaces in scope for super-constraint expansion
standaloneValuesRef -- standalone (importer+definer) shadow NAME list
methodDispatchIdxRef -- per-module copy of the CrossRun universe dispatch-index accumulator (Module arm)
matchOracle -- built exhaustiveness Oracle for the CURRENT check group
matchWarnings -- accumulated match-related TcDiag warnings for the current group
promotionHarvestRef -- accumulated directly-promoted fn names across modules (#194 harvest)
mainSchemeRef -- the entry module inferred `main` scheme; last writer (dependency-order last) wins
sigNameSetRef -- signature NAME set, OrdMap membership mirror
sigTyMapRef -- signature name -> Ty map
implInferEnabled -- toggle: whether impl-body inference is active on this pass'

cross_expected=$(printf '%s\n' "$cross_allowed" | awk 'NF{print $1}' | LC_ALL=C sort)
driver_expected=$(printf '%s\n' "$driver_allowed" | awk 'NF{print $1}' | LC_ALL=C sort)

cross_actual=$(sed -n '/^data CrossRun = CrossRun {$/,/^  }$/p' "$TC" \
  | strip_comments \
  | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:.*/\1/' \
  | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' \
  | LC_ALL=C sort)
driver_actual=$(sed -n '/^  | DriverState {$/,/^    }$/p' "$TC" \
  | strip_comments \
  | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:.*/\1/' \
  | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' \
  | LC_ALL=C sort)

cross_n=$(printf '%s\n' "$cross_actual" | grep -c .)
driver_n=$(printf '%s\n' "$driver_actual" | grep -c .)
if [ "$cross_n" -eq 0 ] || [ "$driver_n" -eq 0 ]; then
  echo "FAIL: check 1 extracted ZERO fields from CrossRun ($cross_n) or DriverState"
  echo "  ($driver_n). Either record was renamed/reshaped and the sed range markers"
  echo "  ('data CrossRun = CrossRun {' / '  | DriverState {') no longer match, or"
  echo "  this check just validated nothing. Update the range markers -- do NOT"
  echo "  treat a zero extraction as a pass."
  exit 1
fi

if [ "$cross_actual" != "$cross_expected" ]; then
  echo "FAIL: CrossRun's field set changed."
  echo "  allowed:"
  printf '%s\n' "$cross_expected" | sed 's/^/    /'
  echo "  actual:"
  printf '%s\n' "$cross_actual" | sed 's/^/    /'
  echo "  A field added to CrossRun without review is a new program-global"
  echo "  cross-module accumulator nobody graded for bare-name-keying risk."
  echo "  REMEDY: add the field to cross_allowed above with a one-line reason,"
  echo "  and say in the PR whether it is bare-name-keyed (the thing #1111"
  echo "  re-keys) or already module-qualified -- never widen this check."
  exit 1
fi
if [ "$driver_actual" != "$driver_expected" ]; then
  echo "FAIL: DriverState's field set changed."
  echo "  allowed:"
  printf '%s\n' "$driver_expected" | sed 's/^/    /'
  echo "  actual:"
  printf '%s\n' "$driver_actual" | sed 's/^/    /'
  echo "  REMEDY: add the field to driver_allowed above with a one-line reason --"
  echo "  never widen this check."
  exit 1
fi
echo "  ok: $cross_n CrossRun field(s), $driver_n DriverState field(s), no new bundle field"

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 2 — the cross-module WRITER ratchet (load-bearing)
# ═══════════════════════════════════════════════════════════════════════════
# Pins the exact SET of `setRef crossRun.value.<field>` / `setRef
# driverState.value.<field>` write TARGETS anywhere in typecheck.mdk. A new
# cross-module accumulator (or a new write path to an existing one) cannot be
# added without a reviewer editing this allowlist -- which is the review
# point #1111 exists to create. Every field from check 1 is expected to
# appear here too (every CrossRun/DriverState field IS written somewhere,
# verified below) -- check 2 is a SEPARATE textual ratchet on the write SITES
# themselves, not a restatement of check 1: it catches a NEW write occurrence
# to a field regardless of whether that field is already declared.
echo "checking #1111 crossRun / driverState setRef writer ratchet ..."

cross_write_allowed=$(printf '%s\n' "$cross_expected" | sed 's/^/crossRun.value./')
driver_write_allowed=$(printf '%s\n' "$driver_expected" | sed 's/^/driverState.value./')

# join_setref makes the split `setRef\n  target\n  (value)` layout visible to
# the same single-line extraction as the one-line form; strip_comments closes
# control F (a comment mentioning the pattern is not a write). grep -oE then
# extracts EVERY `setRef <target>` occurrence independently -- a line with
# TWO such occurrences (control D) yields two tokens, not one, so an allowed
# token cannot hide a rogue one on the same line (the A-1 hole this ratchet
# must not repeat).
cross_write_actual=$(join_setref "$TC" \
  | strip_comments \
  | grep -oE 'setRef[ ]+crossRun\.value\.[A-Za-z_][A-Za-z0-9_]*' \
  | sed -E 's/^setRef[ ]+//' \
  | LC_ALL=C sort -u)
driver_write_actual=$(join_setref "$TC" \
  | strip_comments \
  | grep -oE 'setRef[ ]+driverState\.value\.[A-Za-z_][A-Za-z0-9_]*' \
  | sed -E 's/^setRef[ ]+//' \
  | LC_ALL=C sort -u)

cross_write_n=$(printf '%s\n' "$cross_write_actual" | grep -c .)
driver_write_n=$(printf '%s\n' "$driver_write_actual" | grep -c .)
if [ "$cross_write_n" -eq 0 ] || [ "$driver_write_n" -eq 0 ]; then
  echo "FAIL: check 2 found ZERO setRef write targets for crossRun ($cross_write_n)"
  echo "  or driverState ($driver_write_n). Either the accessor pattern changed"
  echo "  (crossRun.value.* / driverState.value.*) or this check validated"
  echo "  nothing. Do not treat a zero extraction as a pass."
  exit 1
fi

if [ "$cross_write_actual" != "$(printf '%s\n' "$cross_write_allowed" | LC_ALL=C sort)" ]; then
  echo "FAIL: the set of \`setRef crossRun.value.*\` write targets changed."
  echo "  allowed:"
  printf '%s\n' "$cross_write_allowed" | LC_ALL=C sort | sed 's/^/    /'
  echo "  actual:"
  printf '%s\n' "$cross_write_actual" | sed 's/^/    /'
  echo "  REMEDY WHEN THIS FIRES: add the offending write target to"
  echo "  cross_write_allowed above (it should already be a field in"
  echo "  cross_allowed -- if not, check 1 owes a row too) and justify it in"
  echo "  the PR. Never widen the crossRun.value. pattern above."
  exit 1
fi
if [ "$driver_write_actual" != "$(printf '%s\n' "$driver_write_allowed" | LC_ALL=C sort)" ]; then
  echo "FAIL: the set of \`setRef driverState.value.*\` write targets changed."
  echo "  allowed:"
  printf '%s\n' "$driver_write_allowed" | LC_ALL=C sort | sed 's/^/    /'
  echo "  actual:"
  printf '%s\n' "$driver_write_actual" | sed 's/^/    /'
  echo "  REMEDY WHEN THIS FIRES: add the offending write target to"
  echo "  driver_write_allowed above and justify it in the PR. Never widen the"
  echo "  driverState.value. pattern above."
  exit 1
fi
echo "  ok: $cross_write_n crossRun.value.* write target(s), $driver_write_n driverState.value.* write target(s), no rogue writer"

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 3 — the engine frame ratchet (THREE parallel module drivers)
# ═══════════════════════════════════════════════════════════════════════════
# There are three, not two: evalModulesWith / evalModulesRootEnvWith
# (compiler/eval/eval.mdk) and cevalModules (compiler/ir/core_ir_eval.mdk).
# evalModulesRootEnvWith's own comment (eval.mdk:3045-3046) says it is "kept
# in LOCKSTEP with evalModulesWith" -- this check turns that prose into a
# gate: each of the three must seed its frame with the SAME four operations
# (the ctorToTypeRef seed, installDispatchTables allDecls, collectCtors
# allDecls -> globalNames, and the globalCells construction), because a fix
# to one driver silently absent from another is the repo's #1 recurring bug
# class (the P0-9 constructor-collision fix originally shipped patching only
# eval.mdk's evalModules, leaving core_ir_eval.mdk's cevalModules broken for
# months).
echo "checking #1111 three-way engine module-driver frame parity ..."

ceval_body=$(body_of "$CIE" '^cevalModules preludeDecls modules =')
withA_body=$(body_of "$EV" '^evalModulesWith extraExterns preludeDecls modules =')
withB_body=$(body_of "$EV" '^evalModulesRootEnvWith extraExterns preludeDecls modules =')

frame_check() {
  # $1 = driver label, $2 = body text
  label="$1"
  body="$2"
  n=0
  for marker in \
    'setRef ctorToTypeRef (buildCtorToType allDecls)' \
    'installDispatchTables allDecls' \
    'collectCtors allDecls' \
    'let globalCells = map (n => (n, Ref VUnit)) globalNames'
  do
    c=$(printf '%s\n' "$body" | grep -Fc "$marker")
    if [ "$c" -ne 1 ]; then
      echo "FAIL: $label does not seed its frame with exactly one occurrence of:"
      echo "    $marker"
      echo "  (found $c). This is the P0-9 shape: a frame-seeding fix landed in"
      echo "  one module driver and not this one. Add the missing operation to"
      echo "  $label in LOCKSTEP with the other two drivers -- do NOT relax this"
      echo "  check's marker list instead."
      exit 1
    fi
    n=$((n + c))
  done
  echo "  ok: $label seeds all 4 frame operations"
  return 0
}

frame_check "cevalModules (core_ir_eval.mdk)" "$ceval_body"
frame_check "evalModulesWith (eval.mdk)" "$withA_body"
frame_check "evalModulesRootEnvWith (eval.mdk)" "$withB_body"

# "exactly these three" -- a whole-file total (not body-scoped) catches a
# phantom fourth driver anywhere else in either file. Uses the SAME binder
# names (`disp`, `ctors`) the three real drivers use for installDispatchTables
# / collectCtors, which also dodges the false collision with those two
# functions' OWN one-line definitions elsewhere in eval.mdk (installDispatchTables
# allDecls = ...) that a bare-substring whole-file count would hit.
total_ctortotype=$(grep -F -c 'setRef ctorToTypeRef (buildCtorToType allDecls)' "$EV" "$CIE" | awk -F: '{s+=$2} END{print s+0}')
total_disp=$(grep -F -c 'let disp = installDispatchTables allDecls' "$EV" "$CIE" | awk -F: '{s+=$2} END{print s+0}')
total_ctors=$(grep -F -c 'let ctors = collectCtors allDecls' "$EV" "$CIE" | awk -F: '{s+=$2} END{print s+0}')
total_globalcells=$(grep -F -c 'let globalCells = map (n => (n, Ref VUnit)) globalNames' "$EV" "$CIE" | awk -F: '{s+=$2} END{print s+0}')

for pair in "ctorToTypeRef seed:$total_ctortotype" "installDispatchTables call:$total_disp" "collectCtors call:$total_ctors" "globalCells construction:$total_globalcells"; do
  what="${pair%%:*}"
  cnt="${pair##*:}"
  if [ "$cnt" -ne 3 ]; then
    echo "FAIL: expected the $what to appear in EXACTLY 3 places across"
    echo "  eval.mdk + core_ir_eval.mdk (the three known module drivers), found $cnt."
    echo "  Either a driver is missing it (see the per-driver check above for"
    echo "  which one) or a FOURTH place now has it -- a phantom parallel"
    echo "  driver this ratchet was not told about. Add it to the frame_check"
    echo "  calls above and this total list, and justify the new driver in the PR."
    exit 1
  fi
done
echo "  ok: all 4 frame operations appear in exactly 3 places total (no phantom driver)"

# ⚠️ ONE KNOWN, DELIBERATE ASYMMETRY: ctorFieldOrdersRef is seeded ONLY by
# cevalModules, not by either eval.mdk driver. eval.mdk:1487-1490's own
# comment: the tree-walk `run` path's ERecordCreate arm (eval.mdk:1184-1188)
# looks up ctorFieldOrdersRef and falls back to `VRecord` when the table has
# no entry for that constructor -- and since evalModulesWith /
# evalModulesRootEnvWith never populate it, ctorFieldOrdersRef.value stays its
# initial `[]` for the whole tree-walk run, so evalVariantUpdate's VRecord arm
# is the one that always fires there; it never reaches the VCon arm that
# needs the field-order table. Re-verified at this HEAD (not just cited):
#   - eval.mdk:244 `ctorFieldOrdersRef = Ref []` (the only initializer)
#   - `setRef ctorFieldOrdersRef` occurs EXACTLY ONCE in the whole compiler,
#     at core_ir_eval.mdk:511, inside cevalModules
#   - eval.mdk:1184-1188 (ERecordCreate) and eval.mdk:1479-1493
#     (evalVariantUpdate) still branch on `lookupAssoc name
#     ctorFieldOrdersRef.value` / pattern-match VRecord-vs-VCon exactly as
#     the comment describes
# So the asymmetry is a genuine "this driver never needs it," not a silent
# gap -- but it is EXACTLY the P0-9 shape (an operation present in one module
# driver and absent from the others) with a real justification behind it, so
# it is allowlisted HERE, with its reasoning inline, rather than left to rot
# 1400 lines away from the three drivers it concerns.
ceval_cfo=$(printf '%s\n' "$ceval_body" | grep -Fc 'setRef ctorFieldOrdersRef (buildCtorFieldOrders allDecls)')
withA_cfo=$(printf '%s\n' "$withA_body" | grep -Fc 'setRef ctorFieldOrdersRef')
withB_cfo=$(printf '%s\n' "$withB_body" | grep -Fc 'setRef ctorFieldOrdersRef')
total_cfo=$(grep -F -c 'setRef ctorFieldOrdersRef' "$EV" "$CIE" | awk -F: '{s+=$2} END{print s+0}')
if [ "$ceval_cfo" -ne 1 ] || [ "$withA_cfo" -ne 0 ] || [ "$withB_cfo" -ne 0 ] || [ "$total_cfo" -ne 1 ]; then
  echo "FAIL: the ctorFieldOrdersRef asymmetry changed shape (cevalModules=$ceval_cfo,"
  echo "  evalModulesWith=$withA_cfo, evalModulesRootEnvWith=$withB_cfo, total=$total_cfo;"
  echo "  expected 1/0/0/1). This table's seeding just moved between drivers, or"
  echo "  a NEW driver writes it. If the tree-walk path (evalModulesWith /"
  echo "  evalModulesRootEnvWith) now genuinely needs it -- i.e. its ERecordCreate"
  echo "  arm can now produce a VCon for a named-field constructor -- update this"
  echo "  block's expected counts AND re-verify eval.mdk:1184-1493's VRecord/VCon"
  echo "  split still matches your new reasoning; do not just bump the numbers."
  exit 1
fi
echo "  ok: ctorFieldOrdersRef asymmetry unchanged (cevalModules-only, justified above)"

echo "PASS: #1111 registry keying ratchet (CrossRun/DriverState fields, writer sites, three-driver frame parity)."
