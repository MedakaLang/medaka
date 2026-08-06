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
# (universeIfaceRequiredRef, written via the split form -- find it with
# `grep -n 'universeIfaceRequiredRef' compiler/types/typecheck.mdk`, the site
# whose `setRef` sits alone at the end of its line) and DriverState's by two
# (effectDomains,
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
# check asserts nothing about the existing 44 fields' correctness, only that
# no NEW field is added to either bundle without a reviewer adding a row here
# with its own one-line reason. As each later A-2 unit re-keys a table, its
# row here is the place that PR touches (a rename, or two bare/qualified
# mirror fields consolidating into one qualified field), so the allowlist
# shrinking over the arc is the mechanically visible progress signal.
#
# ⚠️ DERIVED, NOT TRUSTED. This block used to carry field COUNTS for both
# records, alongside a note that the records' own prose comments were stale by
# three or four fields apiece. Those numbers went stale in turn the next time a
# field landed (A-2.11 added two to CrossRun and one to DriverState), which is
# the same failure one level up. The counts are gone rather than bumped: the
# script PRINTS the actual field counts on every run, and the allowlists below
# are the reviewable artefact. Trust the extraction; treat any count written in
# prose -- here, in typecheck.mdk, or in a PR body -- as unverified.
echo "checking #1111 CrossRun / DriverState field allowlist ..."

cross_allowed='universeIfaceMethodsRef -- accumulated interface-method NAME set across all modules (definer-shadow checks)
universeFunNamesRef -- accumulated top-level fn NAME set across all modules (importer-shadow checks)
universeKeyBucketsRef -- accumulated impl-existence key buckets (implExistsForHead); A-2.2b moved it onto the RegKey substrate (headBucketRender): absence is now an EMPTY IDENTITY BLOCK, not the noneHeadTag NAME, so a head that spells the sentinel can no longer forge the headless bucket. The head COMPONENT is still keyed by spelling (dispHeadTab) -- blocked on goal-side Mono.TCon origin, derived there
universeIfaceRequiredRef -- accumulated iface -> required-method-names map (impl completeness); IDENTITY-KEYED since A-2.4 (a Registry keyed by regKeyOfTab (ifaceTabKey <ifaceOrigin/implOrigin> name); drained #1258. Flat/single-file rows key TkBare until #1115 -- but this table is READ only on the Module arm)
universeMethodIfaceParamsRef -- accumulated method -> iface param map (#822 kind universe, iface half); still BARE-NAME-keyed and last-write-wins, but since A-2.5 it is only the FLOOR: the Module arm installs it OVERLAID per module by applyMethodScopeOverrides, so a name two interfaces both declare is decided by the importing module scope, not by registration order (#1092)
universeMethodIdentsRef -- A-2.5: the IDENTITY-KEYED companion of the line above -- every (declaring module, method name) declaration of each method name, so a bare-name collision keeps BOTH rows instead of losing one to last-write-wins. Module-path-only: a flat/unstamped declaration mints no Ident (#1115 / E-1)
universeMethodCollidedRef -- A-2.5: the method NAMES universeMethodIdentsRef holds >=2 distinct identities for. Normally EMPTY; it is what keeps the per-module overlay O(collisions) instead of O(all methods)
universeRegisteredIfacesRef -- accumulated registered-iface set, paired with universeMethodIfaceParamsRef above. STILL BARE-NAME, DELIBERATELY: A-2.4 examined it and declined, A-2.2b re-derived the same answer. The value is Unit, so a collapse selects no row; all three readers (recordIfaceObligation / inferNumLit / checkOneCallObligation, via ifaceRegistered) pass a LITERAL prelude name with no TyConOrigin to key from -- an identity key would answer False everywhere and silently switch every operator obligation off; and what it gates is the obligation channel, whose iface half is a bare TkBare NsIface (A-2.2b replaced the "<iface>|<tag>" splice with a RegKey but did NOT make that half an identity -- oblIfaceKey). Full derivation on ifaceRegistered in typecheck.mdk. Revisit WITH the obligation channel, not before
universeMethodDispatchIdxRef -- accumulated interface dispatch-index list
universeRecordByName -- accumulated record name -> RecordInfo map (bare registry key, last-write-wins -- the table behind #1256 and #1283 Repro A). A-2.12 (#1319 unit 2): STILL bare-name and still the FLOOR, but the Module arm now installs it OVERLAID per module by applyRecordScopeOverrides. That overlay decides ONLY on its [only] arm -- a collided key whose candidates are witnessed by ZERO imports of this module, or by TWO, keeps the load-order floor untouched, so the coverage is spelling-scoped and NOT defect-scoped. Measured residual, so it is not left to inference: an entry importing only a VALUE of the record (no type member, no ctor member, no `(..)`) witnesses nothing and is still answered by load order -- reproduces identically on the pre-change binary AND with the declaring module named directly, i.e. it is the #1256 family surviving in a spelling A-2.6 also could not reach, not a #1283 re-export residual
universeRecordIdentsRef -- A-2.12 (#1319 unit 2): the IDENTITY-KEYED companion of the line above -- every (declaring module, registry key) declaration of each record/named-field-variant key, with the OWNING TYPE name and the very RecordInfo universeRecordByName holds, so a bare-name collision keeps BOTH rows instead of losing one to last-write-wins. It is NOT a bare-name-keyed cross-module table in the sense this ratchet pins: the outer key is the bare registry key ONLY as an index into a candidate LIST, and selection is by Ident NsCtor minted from the declaration TyConOrigin. Module-path-only: a flat/unstamped declaration mints no Ident (#1115 / E-1) and contributes no candidate. Grown in appendDataUniverse from publicDataDecls, in the same call and reading back the same recordByNameRef rows registerAllData just wrote -- so the two cannot come to hold different RecordInfos. SCAFFOLDING WITH A NAMED DELETER, exactly as universeCtorIdentsRef: #1288 owns the consolidation
universeRecordCollidedRef -- A-2.12: the registry KEYS universeRecordIdentsRef holds >=2 distinct identities for. Normally EMPTY; it is what keeps the per-module overlay O(collisions) instead of O(all records) -- the role universeMethodCollidedRef / universeCtorCollidedRef play for their namespaces
universeFieldOwners -- accumulated field-name -> owning-record(s) map. STILL UNSCOPED, and the row is OPEN, not excused. The KEY was never the defect: a field name is exactly the query. What is wrong is the VALUE -- an ACCUMULATING multimap whose candidate owner set is graph-global, so a record the importing module has no import path to still votes in the ambiguity test and a valid program is refused (the fourth row routed to #1319 by the #1070 audit). A last-write-wins overlay structurally cannot fix that, which is why the A-2.6 drain never reached it. A-2.12 (#1319 unit 2) BUILT a per-module narrowing here and then REMOVED it before landing, after adversarial review measured three defects in it, recorded so the next attempt does not repeat them: (a) wrong question -- the second consumer, resolveFieldRecord concrete-receiver fallback, needs "could this module be HOLDING a value of that record", not "is its CONSTRUCTOR in scope", and importing only a VALUE reaches it, so no constructor-spelling predicate can serve (measured accept->reject regression, 8/exit 0 -> Type mismatch/exit 1); (b) the collided-FIELD list is NOT rare -- any two records in the graph sharing name/id/size put a name on it, measured 5.6x net allocation at 240 modules, r3=6.47 against a hard 3.0; (c) non-monotonic -- the list is grown at the END of a module arm so its own decls are absent, leaving the common local-record-plus-one-collider case rejected while a SECOND collider made it compile. The predicate this needs is type REACHABILITY -- can a value of that record be OBTAINED here at all, which is a CLOSURE over the imported type surface and not the one-hop test "is it mentioned by the type of some imported binding" (a record reachable only transitively -- a field of an imported record, an element of an imported List, a type argument -- is still a value this module can hold and project on). That is a different analysis from the constructor-witness substrate this arc built
universeDataParamKinds -- accumulated data-type param-kind list; IDENTITY-KEYED since A-2.3 (TabKey; flat/single-file table holds BOTH populations -- prelude rows key TkIdent via stampDeclOrigins "core", flat USER rows have no identity and stay TkBare until #1115)
universeIfaceParamKinds -- accumulated interface param-kind list (#822, iface half of the kind universe); IDENTITY x SLOT-KEYED since A-2.4 (RegKey via regKeyTabAt (ifaceTabKey o iface) i, replacing the "<iface>@<slot>" string; drained #1257. Read on BOTH driver arms, so flat/single-file rows key TkBare until #1115)
universeAliasTable -- accumulated type-alias table; IDENTITY-KEYED since A-2.3 (TabKey; flat/single-file table holds BOTH populations -- prelude rows key TkIdent via stampDeclOrigins "core", flat USER rows have no identity and stay TkBare until #1115)
universeDataEnv -- accumulated ctor environment (bare-name, last-write-wins -- the thing #674 works around). A-2.11: STILL bare-name and still the FLOOR, but the Module arm now installs it OVERLAID per module by applyCtorScopeOverrides, so a constructor name two modules both declare is decided by the importing module scope rather than by registration order (#1284/#1283/#733 item 1c)
universeCtorIdentsRef -- A-2.11 (#1319 unit 1): the IDENTITY-KEYED companion of universeDataEnv above -- every (declaring module, ctor name) declaration of each constructor name, with the OWNING TYPE name and the very Scheme universeDataEnv holds, so a bare-name collision keeps BOTH rows instead of losing one to last-write-wins. It is NOT a bare-name-keyed cross-module table in the sense this ratchet pins: the outer key is the bare ctor name ONLY as an index into a candidate LIST, and selection is by Ident NsCtor minted from the declaration TyConOrigin. Module-path-only: a flat/unstamped declaration mints no Ident (#1115 / E-1) and contributes no candidate. It is grown in appendDataUniverse from publicDataDecls, i.e. exactly the population universeDataEnv is grown from, in the same call, from the same env -- so the two cannot come to hold different schemes. SCAFFOLDING WITH A NAMED DELETER: this is the CONSTRUCTOR twin of universeMethodIdentsRef and, like it, is a further implementation of a fact resolve already derives; #1288 owns the consolidation and its scope names the constructor peer
universeCtorCollidedRef -- A-2.11: the ctor NAMES universeCtorIdentsRef holds >=2 distinct identities for. Normally EMPTY; it is what keeps the per-module overlay O(collisions) instead of O(all constructors) -- the exact role universeMethodCollidedRef plays for methods
universeDataDecls -- accumulated PUBLIC data decls (#674: recovers per-module ctor identity universeDataEnv loses)
obUnivConcreteRef -- accumulated concrete-instance obligation-impl universe bucket; A-2.2b: MultiRegistry (explicitly commutative, mregAppendK so the first-match order findMatchingImplReqsU depends on is kept), keyed by the structured (NsIface, NsType) RegKey pair that replaced the "<iface>|<tag>" string splice. Both halves BARE: iface by derivation (Predicate carries no origin), head by derivation (dispHeadTab)
obUnivHeadlessRef -- accumulated headless obligation-impl universe bucket; A-2.2b: MultiRegistry keyed by the bare NsIface RegKey, same derivation as the row above
obUnivIfaceTagsRef -- accumulated iface-tag obligation-impl universe bucket; A-2.2b: Registry SetRegistry (implCountForIfaceU is sregSize, the combinator A-2.0 added for it), outer key bare NsIface, inner key bare NsType
crossModuleFunConstraintsRef -- cross-module fn constraint-arity snapshot, bare name
crossModuleFunConstraintsQualRef -- cross-module fn constraint-arity snapshot, module-qualified mirror
crossModuleFunConstraintIfacesRef -- cross-module fn constraint-iface snapshot, bare name
crossModuleFunConstraintIfacesQualRef -- cross-module fn constraint-iface snapshot, module-qualified mirror
crossModuleMethodConstraintsRef -- cross-module method constraint-arity snapshot, bare name
crossModuleMethodConstraintsQualRef -- cross-module method constraint-arity snapshot, module-qualified mirror
coreSchemeObligationsRef -- #673: core pass own scheme-obligations snapshot, taken after the core pass
crossModuleSchemeOblsQualRef -- #1114 (#845): every USER module own scheme-obligations snapshot, the per-module generalization of coreSchemeObligationsRef one row up. MODULE-QUALIFIED, not bare name: keyed (defining module id, exported top-level name) by attributeModuleSchemeObls, the same key attributeModuleArities uses two rows up and for the same #739 reason -- a bare-name cross-module obligation table hands one module constrained f context to another module unconstrained f. NEITHER READ SITE IS BARE-NAME EITHER, which is the half a keying claim usually omits: the only reader is qualSchemeOblsFor, which reads importedSchemeOblsRef -- a PER-MODULE projection (perRun, re-derived per module by importedSchemeOblEntries from THAT module own DUse decls), so an entry is reachable only from a module whose own import names the module that defines it. Covers all four import spellings deliberately (selective, member-alias, wildcard, module-alias); see importedSchemeOblEntries for why the wildcard arm is NOT added to aliasConstraintEntries instead'

driver_allowed='effectDomains -- effect-label -> domain-param registry; driver-set-once preamble state, single writer
graphMethodExportsRef -- #1111 A-2.5b (#1272/#1275): module id -> the (name, declaring Ident) method pairs that a module row CARRIES, re-exports folded in dependency-first. ARGUED, not merely allowlisted, on five points. (1) NOT a bare-name-keyed cross-module table in the sense this ratchet pins: the OUTER key is the loader module id -- a SCOPE, whose absence is what makes such a table collide -- and the VALUE carries Ident, so a same-named interface in another module gets its own row under its own mid and its own identity. That is the collapse being removed, not a new one. (2) It is on DriverState and NOT on CrossRun DELIBERATELY, and that placement IS the fix for review finding F1. CrossRun is contracted as what a per-run reset clears; resetCrossModuleState swaps the whole bundle for freshCrossRun, and the elaborateModules promotion arm opens with a SECOND such reset. Every other universe* field is re-seeded after a reset by the core pass or by appendUniverseAccums; this one is derived once from the whole graph and has no re-seed path, so while it sat on CrossRun it silently emptied and check disagreed with run and build. DriverState has no reset point -- its own header says freshDriverState is the INITIAL construction only, and a grep for a whole-bundle setRef on driverState in compiler/types/typecheck.mdk has no hits -- so the clearing is now structurally impossible rather than patched. (3) THE SAFETY PROPERTY IS A CONJUNCTION -- state both halves or neither. (a) UNCONDITIONAL WHOLE-VALUE OVERWRITE at every Module-mode driver entry (checkModulesPreamble and elaborateModules, each setRef-ing a value derived from the graph of that compile; never omInsert, never a merge), AND (b) NO RESET POINT in between (DriverState has none). BOTH are necessary. Without (a) the index is omEmpty from freshDriverState and every candidate misses -- which IS the F1 symptom; without (b) the writes in (a) are present and correct and a reset still empties the field between write and read -- which IS how F1 actually happened, on CrossRun. An earlier version of this row said the property was liveness-at-every-entry and called that greppable, and dismissed the writer enumeration as the wrong question: both are wrong. Liveness is a DYNAMIC property; the greppable proposition is (b). The writer enumeration is (a), a NECESSARY conjunct, not a distraction -- it was correct when first derived and only INSUFFICIENT. An even earlier version claimed Built ONCE per compile and never grown per module; F1 falsified that too -- it is derived once per DRIVER ENTRY and a driver may run twice over one graph. (4) INTERIM, with a NAMED ABSORBING STAGE. resolve already derives this same fact (ModuleExports.expIfaceMethods / reExpIfaceMethods, and valueProvenance / ambiguousSet via publicIfaceMethodVals), so this is a THIRD implementation of it, and #1288 is an open S1 against the resolve copy. The long-term home is upstream: R / #1288 owns the fact and typecheck consumes it, and R / #1288 IS THE STAGE THAT DELETES THIS FIELD. It lands now only so that two S0s need not wait on a component that does not exist yet. (5) The row has NO pub filter, so export is the wrong verb for it: a private interface methods are in the row too. That is F3, filed as #1302, pre-existing, reproduces on main, and deliberately unfixed here because whether a private interface method is visible to dispatch is a language decision owed to the spec.
graphCtorExportsRef -- #1111 A-2.11 (#1319 unit 1, drains #1284 / #1283-B / #733 item 1c): the CONSTRUCTOR peer of graphMethodExportsRef above -- module id -> the (ctor name, owning type name, declaring Ident) rows that a module row CARRIES, re-exports folded in dependency-first. All five of the points argued on that row apply here VERBATIM and are not restated: same outer-key-is-a-scope argument, same DriverState-not-CrossRun placement for the same F1 reason, same two-part conjunction (unconditional whole-value overwrite at BOTH Module-mode driver entries AND no reset point in between), same interim status with #1288 as the named absorbing stage. TWO differences, both narrowing: (1) the row carries the OWNING TYPE NAME as well, because a `(..)` member binds a constructor WITHOUT SPELLING IT -- usePathBindsName is not reusable for this namespace and reusing it would reproduce the #1272/#1275 class here; (2) the missing pub filter (F3 / #1302 on the method peer) cannot bite here, structurally rather than by promise: the CANDIDATES this index is matched against come from publicDataDecls, so a private declaration row entry can never equal a candidate Ident
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
