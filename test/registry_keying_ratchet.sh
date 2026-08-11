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
universeRecordByName -- accumulated record name -> RecordInfo map (bare registry key, last-write-wins -- the table behind #1256 and #1283 Repro A). A-2.12 (#1319 unit 2): STILL bare-name and still the FLOOR, but the Module arm now installs it OVERLAID per module by applyRecordScopeOverrides. A-2.13 (#1319 unit 3) NARROWED WHAT IT IS ASKED rather than re-keying it: it answered TWO questions -- (1) which declaration does a record name WRITTEN IN THIS MODULE SOURCE denote (inferPatRec, inferRecordCreate, inferVariantUpdate), and (2) which RecordInfo describes a receiver whose type is already inferred (resolveFieldRecord arm a) -- and one bare-keyed entry cannot answer both for a module that NAMES one declaration and HOLDS a value of another. DICT-SEMANTICS section 8 I4 qualification 2 draws exactly that line: r.f is resolved by the TYPE of r, while record construction and record patterns name the record. Question (2) now selects out of universeRecordIdentsRef by the receiver Ident (lookupRecordForReceiver) and reaches this table only on an honest MISS; question (1) still keys on the spelling, which is correct for it. DRAINED #1376 (value-only import -- the residual this row named as spelling-scoped, unreachable by ANY scope decision because there is no spelling to key one on) and #1377 (names one Cfg, holds another). STILL BARE-KEYED AND STILL THE FLOOR: unit 3 is not the re-keying, and #1288 remains the deleter
universeRecordIdentsRef -- A-2.12 (#1319 unit 2): the IDENTITY-KEYED companion of the line above -- every (declaring module, registry key) declaration of each record/named-field-variant key, with the OWNING TYPE name and the very RecordInfo universeRecordByName holds, so a bare-name collision keeps BOTH rows instead of losing one to last-write-wins. It is NOT a bare-name-keyed cross-module table in the sense this ratchet pins: the outer key is the bare registry key ONLY as an index into a candidate LIST, and selection is by Ident NsCtor minted from the declaration TyConOrigin. Module-path-only: a flat/unstamped declaration mints no Ident (#1115 / E-1) and contributes no candidate. Grown in appendDataUniverse from publicDataDecls, in the same call and reading back the same recordByNameRef rows registerAllData just wrote -- so the two cannot come to hold different RecordInfos. A-2.13 (#1319 unit 3) GAVE IT A SECOND READER: resolveFieldRecord arm a now selects a candidate here by comparing the RECEIVER head identity against the pair (declaring module of the candidate, OWNING TYPE name of the candidate). RETRACTION (#1381 round-2 review, finding 1): an earlier version of this row said BOTH halves required, since a candidate keyed Plain may own type Holder, so a test on the module alone or on the key alone cannot tell two candidates apart. The MODULE half is required and is measured (dropping it reds record_receiver_ident_named_vs_held). The OWNING-TYPE-NAME half is NOT measured by anything and cannot be by any fixture asserting a value or an acceptance -- dropping it leaves all 52 diff_compiler_llvm_modules cells, make check-self, and five purpose-built two-field probes graded on the executed native binary green. It is kept as belt-and-braces so the selector does not rest silently on Duplicate constructor rejection in another subsystem; the derivation and the one diagnostic-only shape where it is observable are written at recordCandIsType in compiler/types/typecheck.mdk. So this table is no longer only the candidate pool for the overlay; it is the identity index the receiver question is answered from. SCAFFOLDING WITH A NAMED DELETER, exactly as universeCtorIdentsRef: #1288 owns the consolidation
universeRecordCollidedRef -- A-2.12: the registry KEYS universeRecordIdentsRef holds >=2 distinct identities for. Normally EMPTY; it is what keeps the per-module overlay O(collisions) instead of O(all records) -- the role universeMethodCollidedRef / universeCtorCollidedRef play for their namespaces
universeFieldOwners -- accumulated field-name -> owning-record(s) map. STILL UNSCOPED, and the row is OPEN, not excused. The KEY was never the defect: a field name is exactly the query. What is wrong is the VALUE -- an ACCUMULATING multimap whose candidate owner set is graph-global, so a record the importing module has no import path to still votes in the ambiguity test and a valid program is refused (the fourth row routed to #1319 by the #1070 audit). A last-write-wins overlay structurally cannot fix that, which is why the A-2.6 drain never reached it. A-2.12 (#1319 unit 2) BUILT a per-module narrowing here and then REMOVED it before landing, after adversarial review measured three defects in it, recorded so the next attempt does not repeat them: (a) wrong question -- the second consumer, resolveFieldRecord concrete-receiver fallback, needs "could this module be HOLDING a value of that record", not "is its CONSTRUCTOR in scope", and importing only a VALUE reaches it, so no constructor-spelling predicate can serve (measured accept->reject regression, 8/exit 0 -> Type mismatch/exit 1); (b) the collided-FIELD list is NOT rare -- any two records in the graph sharing name/id/size put a name on it, measured 5.6x net allocation at 240 modules, r3=6.47 against a hard 3.0; (c) non-monotonic -- the list is grown at the END of a module arm so its own decls are absent, leaving the common local-record-plus-one-collider case rejected while a SECOND collider made it compile. The predicate this needs is type REACHABILITY -- can a value of that record be OBTAINED here at all, which is a CLOSURE over the imported type surface and not the one-hop test "is it mentioned by the type of some imported binding" (a record reachable only transitively -- a field of an imported record, an element of an imported List, a type argument -- is still a value this module can hold and project on). That is a different analysis from the constructor-witness substrate this arc built. A-2.13 (#1319 unit 3) did NOT touch this row and found a SECOND, distinct bare-key defect on the same fallback while building its bystander fixture, recorded here because it is one grep from the code that answers it: pairRecordByName reads lookupRecordByName with a registry KEY, so when that key is a named-field-variant CONSTRUCTOR name that also spells another module record TYPE name, the fallback returns the wrong RecordInfo. Measured: module ahold declares data Holder = | Plain { hx : Int } and module plainlib declares data Plain = { px : Int }; an entry importing both and writing mkH.hx is REFUSED (Type mismatch: Holder vs Plain, then Field hx does not belong to record Plain) where 100 is correct. Verified PRE-EXISTING by stubbing unit 3 identity selection back out and reproducing identically, so it is not introduced by that unit. It is now FILED as #1383 (S1) and PINNED at test/must_fail_fixtures/1383-variant-ctor-name-collides-xmod-record-type/, and it was re-confirmed still reproducing after unit 3 was rebased onto #1395 -- #1395 narrowed the give-up arm of lookupRecordByMangledHead, which is a DIFFERENT arm from this one, so it does not reach this defect. GRADE IT S0-SILENT, NOT ONLY S1-LOUD: an earlier version of this row described the residual purely as a false REJECT (#1383, loud, exit 1) and framed the danger as a RISK OF a run-vs-build divergence if selection were changed. Measured 2026-08-08, that understates it -- the fallback ALREADY HAS a silent built-binary face today, and it is #1216 (S0, OPEN). Two modules each declaring a named-field variant spelled Cfg whose owning TYPES are WrapA and WrapZ, same two Int fields at opposite indices, every projection inside its own declaring module: check exits 0, medaka run prints the correct 11,22,44,33, and the BUILT BINARY prints 11,22,33,44 at exit 0 with no diagnostic. Neither key suffix-matches the other head, so #1395 never runs and pairRecordByName picks by module-NAME sort order. Verified PRE-EXISTING by stubbing unit 3 back out; full repro ported into the #1216 pin claim, since this harness allows one fixture per issue. NOT fixed by unit 3, deliberately: the owners fallback returns the registry KEY as the record NAME the emitter then reads, and for a collided key that string is ambiguous downstream (#1292 / #1305 territory), so selecting a different RecordInfo while returning the same key could ADD a second run-vs-build divergence on top of the one already there -- not a trade unit 3 was in a position to prove safe
universeDataParamKinds -- accumulated data-type param-kind list; IDENTITY-KEYED since A-2.3 (TabKey; flat/single-file table holds BOTH populations -- prelude rows key TkIdent via stampDeclOrigins "core", flat USER rows have no identity and stay TkBare until #1115)
universeIfaceParamKinds -- accumulated interface param-kind list (#822, iface half of the kind universe); IDENTITY x SLOT-KEYED since A-2.4 (RegKey via regKeyTabAt (ifaceTabKey o iface) i, replacing the "<iface>@<slot>" string; drained #1257. Read on BOTH driver arms, so flat/single-file rows key TkBare until #1115)
universeAliasTable -- accumulated type-alias table; IDENTITY-KEYED since A-2.3 (TabKey; flat/single-file table holds BOTH populations -- prelude rows key TkIdent via stampDeclOrigins "core", flat USER rows have no identity and stay TkBare until #1115)
universeDataEnv -- accumulated ctor environment (bare-name, last-write-wins -- the thing #674 works around). A-2.11: STILL bare-name and still the FLOOR, but the Module arm now installs it OVERLAID per module by applyCtorScopeOverrides, so a constructor name two modules both declare is decided by the importing module scope rather than by registration order (#1284/#1283/#733 item 1c)
universeCtorIdentsRef -- A-2.11 (#1319 unit 1): the IDENTITY-KEYED companion of universeDataEnv above -- every (declaring module, ctor name) declaration of each constructor name, with the OWNING TYPE name and the very Scheme universeDataEnv holds, so a bare-name collision keeps BOTH rows instead of losing one to last-write-wins. It is NOT a bare-name-keyed cross-module table in the sense this ratchet pins: the outer key is the bare ctor name ONLY as an index into a candidate LIST, and selection is by Ident NsCtor minted from the declaration TyConOrigin. Module-path-only: a flat/unstamped declaration mints no Ident (#1115 / E-1) and contributes no candidate. It is grown in appendDataUniverse from publicDataDecls, i.e. exactly the population universeDataEnv is grown from, in the same call, from the same env -- so the two cannot come to hold different schemes. SCAFFOLDING WITH A NAMED DELETER: this is the CONSTRUCTOR twin of universeMethodIdentsRef and, like it, is a further implementation of a fact resolve already derives; #1288 owns the consolidation and its scope names the constructor peer
universeCtorCollidedRef -- A-2.11: the ctor NAMES universeCtorIdentsRef holds >=2 distinct identities for. Normally EMPTY; it is what keeps the per-module overlay O(collisions) instead of O(all constructors) -- the exact role universeMethodCollidedRef plays for methods
obUnivConcreteRef -- accumulated concrete-instance obligation-impl universe bucket; A-2.2b: MultiRegistry (explicitly commutative, mregAppendK so the first-match order findMatchingImplReqsU depends on is kept), keyed by the structured (NsIface, NsType) RegKey pair that replaced the "<iface>|<tag>" string splice. Both halves BARE: iface by derivation (Predicate carries no origin), head by derivation (dispHeadTab)
obUnivHeadlessRef -- accumulated headless obligation-impl universe bucket; A-2.2b: MultiRegistry keyed by the bare NsIface RegKey, same derivation as the row above
obUnivIfaceTagsRef -- accumulated iface-tag obligation-impl universe bucket; #1446 T2: outer key is now the IDENTITY-keyed NsIface TabKey (tabKeyOf on the interface occurrence origin), inner key stays bare NsType (the #1317 T1 rule -- a head route word is inherently spelling-scoped; re-keying it re-introduces the closed S0 #1277)
builtinClassesRef -- #1446 P1 / DICT-SEMANTICS 8 I7: the four operator-and-literal classes` (Num/Eq/Ord/Semigroup) TyConOrigin, read off the PRELUDE`s own DInterface decls. NOT a bare-name-keyed cross-module table in the sense this ratchet pins: the key is a CLOSED four-constructor enum (BuiltinClass) that no declaration can extend, and the population path (seedBuiltinClasses) reads a prelude decl list only -- which is what makes I7`s `no user declaration can capture an operator`s class` a representation fact rather than a rule. On CrossRun rather than DriverState deliberately: it IS re-seeded after every reset by the core pass (checkBodyImpl runs seedBuiltinClasses on the Module arm for mid ""/"core", and unconditionally on the Flat arm), which is the same lifecycle every universe* row above has and the exact conjunct graphMethodExportsRef lacks
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
graphIfaceMethodsRef -- #1354 unit A (#1353/#1380): the TYPE-NAMESPACE peer of graphMethodExportsRef above -- module id -> the (interface name a module row CARRIES, that interface method names) rows, re-exports folded in dependency-first. All five of the points argued on the graphMethodExportsRef row apply here VERBATIM and are not restated: same outer-key-is-a-scope argument (the outer key is the loader module id, so a same-named interface in another module gets its own row under its own mid), same DriverState-not-CrossRun placement for the same F1 reason, same two-part conjunction (unconditional whole-value overwrite at BOTH Module-mode driver entries AND no reset point in between -- this field is written on the line immediately after its peer at both entries, so the two cannot drift), same interim status with #1288 as the named absorbing stage that DELETES it. WHY A SECOND INDEX RATHER THAN REUSING THE FIRST, which is the question a reviewer should ask: the method index cannot answer the question SHADOW-SEMANTICS 1.0 actually asks. That clause scopes S1 INTERFACE operand -- a TYPE-namespace question -- and asking the method index instead is wrong in BOTH directions, each MEASURED on a built compiler. TOO STRICT: a re-exporter row is folded by matching the export import member list against METHOD names, so the ordinary export import ifc.{Sizeable} yields an EMPTY row and the predicate answers not-nameable for an interface that is -- two entry files differing by one import line, the direct one printing 300 and the chained one REJECTED, which is the non-conformance S1-CHAIN enumerates by name. TOO LOOSE: any import of the declaring module admitted that module WHOLE method row, so import smod.{sf} made the interface nameable when writing impl Sizeable Blob in that same module is rejected Unknown interface: Sizeable. Both are guarded by test/shadow_fixtures/i14_importer_iface_via_reexport_chain and i15_importer_iface_one_hop_unbound. ONE DIFFERENCE from the peer, narrowing: the member filter (selectIfaceRows) is applied on the IMPORT side as well as the re-export side. ⚠️ It matches the interface name OR the method names, not the interface name alone -- this sentence said INTERFACE name only, and S1-NS (RULED 2026-08-08) made that stale before it shipped: selectIfaceRows NARROWS a row per METHOD, so a member list naming the interface admits the whole row, one naming only sibling methods admits exactly those methods, and only a bare import or a list naming neither admits nothing. The per-method half is what i19_importer_sibling_method_silent and d23_definer_sibling_method_silent grade; the admits-nothing half is i15_importer_iface_one_hop_unbound. SAME pub-filter gap as the peer (F3 / #1302), same fail-open direction, deliberately unfixed here
declEnvsRef -- #1112 A-3.1: the whole-graph declaration ENVELOPE (stage K) -- the loader graph tagged with a module ordinal (prelude 0, then dependency-first), its module-id -> ordinal index, and the flattened decl list. Placed on DriverState beside the three graph*Ref peers above and under the IDENTICAL two-part conjunction they argue: (a) unconditional whole-value overwrite at BOTH Module-mode driver entries (checkModulesPreamble, elaborateModules), AND (b) no reset point in between (DriverState has none). Both halves are necessary here for the same F1 reason -- it is derived once from the whole graph and has no per-module re-seed path, so a CrossRun placement would silently empty it at resetCrossModuleState. NOT a bare-name-keyed cross-module table in the sense this ratchet pins: the key is the loader module id, i.e. a SCOPE, and the value is that module own decls. A-3.2b (#1512) IS THE FIRST RETIREMENT: universeDataDecls -- #674`s positional overlay pool -- has LEFT cross_allowed above, and both its consumers (the dataEnv ctor overlay and checkModuleFullDiags` exhaust-oracle seed) now read deModules at the reader`s own ordinal through declEnvRowVisible/declEnvVisibleTo. HISTORY, kept because the rows below are still true of their own units -- A-3.1 carried no CE/IE/DataEnv contents; A-3.2a (#1112) added the DataEnv slice (deTypes/deCtorIdents/deRecordIdents/deFieldOwnerIdents/deAliases) but populates it SYNTACTICALLY (raw decls, no elaborated Scheme/RecordInfo/Mono) and retires or re-keys NO universe*/obUniv* row -- no load/store call, no overlay removed. CE/IE remain owed to A-3.3/A-3.4. Only deAllDecls is read today (deData has no reader, and deImpls has none either outside the temporary ieShadowCompare instrument); the ordinal filter declEnvVisibleAt had NO reader at all after A-3.2a -- that unit`s DataEnv construction reads deAllDecls directly, unfiltered, and calls neither declEnvsVisible nor declEnvVisibleAt. ⚠️ A-3.2b CHANGES THAT: declEnvVisibleAt now has a PRODUCTION reader, through declEnvVisibleTo (the SECOND, ratified visibility predicate -- ordinal AND publicity, deliberately two SEPARABLE conjuncts because A-3.6 deletes only the first while the second migrates to R per §3 L7) and declEnvRowVisible, on the overlay-pool walk. A-3.6 is still the deletion of the ONE declEnvVisibleAt body; it must not take the publicity conjunct with it. ⚠️ A-3.4 CHANGES THAT HALFWAY, so state it precisely: ieTriplesUpTo (the ordinal filter on IE, reached through the single read accessor ieUniverseAt) DOES call declEnvVisibleAt, and the doctests at the IE builder exercise it -- so the predicate is no longer dead, but it still has NO PRODUCTION reader, because ieUniverseAt has no caller outside those doctests until A-3.4 PR2 flips the Module arm onto it. A-3.6 remains the deletion of that one predicate body. THE PROGRESS SIGNAL for the rest of A-3 is this row GROWING while cross_allowed above SHRINKS -- A-3.2a did NOT move that signal: it grew this row (DataEnv) but shrank nothing in cross_allowed, because it retired no universe* row. A-3.2b (#1512, absorbing #1319 unit 4) MOVED IT for the first time -- one row out of cross_allowed (universeDataDecls). It is a FIRST shrink, not a finished one: the four load/store tables (universeRecordByName, universeFieldOwners, universeDataParamKinds, universeAliasTable) and universeDataEnv/universeCtorIdentsRef all remain, three of them because their payload is ELABORATED (RecordInfo/Scheme) and the Step 0 ruling keeps K syntactic #1112 A-3.4 ADDS deImpls -- IE, the whole-graph impl registry: every impl in the graph with its full head, context and method table, plus an InstRef instance identity and the declaring module ordinal its visibility filters on. THE INTERFACE HALF IS IDENTITY-KEYED and mints no parallel scheme: ieInsertRow calls the SAME oblIfaceKeys the obligation-channel writer calls, which is TWO keys -- the identity key AND the bare-spelling compatibility leg -- so IE inherits the same-spelled-interface collapse #1438 pins, deliberately, and that drain is #1482`s not this unit`s (asserted, not merely admitted: a doctest at the IE builder shows both same-spelled rows in ONE bare bucket). The head half stays BARE by the #1317 T1 rule that re-keying it re-introduces the closed S0 #1277. NO IE KEY COMPONENT IS A METHOD NAME -- check 4 below enforces that mechanically, because a (method, tag)-keyed default registry here would rebuild #1265 in the new substrate; a method name is PAYLOAD (ieMethods) only. A-3.4 does NOT move the progress signal either, for the SAME reason A-3.2a does not: PR1 has ZERO readers, so cross_allowed keeps all three obUniv* rows and this row grew without anything shrinking. A-3.4 PR2 is the unit that flips the Module arm`s obligation universe onto ieUniverseAt and takes obUnivConcreteRef/obUnivHeadlessRef/obUnivIfaceTagsRef out of cross_allowed -- THAT is A-3.4`s shrink, and it is blocked on #1508 (cmCheckWorker discards its module id, so every user module on the checkModules driver arrives at ordinal 0)
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

# #1112 A-3.4: THE THIRD AND FOURTH ALLOWLISTS -- the `DeclEnvs` BUNDLE ITSELF.
# Until A-3.4 this check pinned `CrossRun` and `DriverState` only, so `DeclEnvs`
# -- the bundle `declEnvsRef` merely POINTS AT -- had its field set pinned by
# NOTHING. That is the wrong side of the pointer: A-3's whole shape is universe*
# rows LEAVING CrossRun and their contents arriving inside `DeclEnvs`, so without
# these two lists each remaining A-3 unit would add a program-global table
# OUTSIDE the very field ratchet that exists for that shape, and the gap would
# widen per unit rather than being a one-off. A-3.2/A-3.3 add `CE`/`DataEnv`
# fields here; A-3.5/3.6/3.7 edit the reasons.
declenvs_allowed='deModules -- the loader graph as ordinal-tagged module rows (prelude 0, then dependency-first). Not bare-name-keyed: the row key is the loader module id, i.e. a SCOPE
deOrdIndex -- module id -> ordinal index; the lookup `declEnvsOrdOf` uses, fail-CLOSED at -1
deAllDecls -- the flattened whole-graph decl list; the same list value each driver used to build inline as `coreDecls ++ flatMap snd modules`
deData -- #1112 A-3.2a: the `DataEnv` half of stage K -- an identity-keyed index over the RAW declarations (no elaborated Scheme/RecordInfo/Mono), built once from `deAllDecls`. CONSTRUCTION ONLY and NOT LIVE: nothing outside its own block populates or reads it. Allowlisted HERE, by A-3.4, rather than by the unit that added it -- A-3.2a landed `deData` while `DeclEnvs` was still pinned by NOTHING (check 1 covered only CrossRun and DriverState), and A-3.4 is the unit that extends the extraction to this record. That is the gap this extension exists to close, and its first act is to retro-pin a field that was already in the tree. ⚠️ Scope-of-key question deliberately left OPEN by A-3.2a and not settled here: `buildDataEnv` folds EVERY decl including private ones, making it a SUPERSET of what the live `universeDataEnv` (public-only) ever held -- harmless while nothing reads it, a real decision the moment something does
deImpls -- #1112 A-3.4: the `IE` registry. Every impl in the graph with its full head, context and method table, plus an `InstRef` instance identity and the declaring module ordinal its visibility is filtered on. THE INTERFACE HALF IS IDENTITY-KEYED and mints no parallel scheme: `ieInsertRow` calls the SAME `oblIfaceKeys` the obligation-channel writer calls (identity key + the bare compatibility leg #1438 still rides on), and the head half stays BARE by the #1317 T1 rule that re-keying it re-introduces the closed S0 #1277. NO KEY COMPONENT IS A METHOD NAME -- check 4 below enforces that mechanically, because a (method, tag)-keyed default registry here would rebuild #1265 in the new substrate; a method name is PAYLOAD (`ieMethods`) only. ZERO READERS in PR1: the Module arm still reads the three obUniv* accumulators and the flip onto `ieUniverseAt` is PR2, so `cross_allowed` above has not shrunk yet -- that shrink is the progress signal this row is waiting to produce
deIfaces -- #1519 (ARCH A-3.3): the `CE` registry. Interfaces with declared parameter kinds, method schemes (raw Ty, unelaborated -- same Step 0 ruling deData rests on), superclass predicates. Keyed by interface IDENTITY (RegKey via ifaceTabKey/regKeyOfTab), one row per declaration, so two same-spelled interfaces in unrelated modules get DISTINCT rows rather than a last-write-wins collapse -- the doctests at the CE block assert this directly on a two-module same-spelled-interface corpus mirroring ieProbeEnv. EXCLUDES universeMethodDispatchIdxRef and universeIfaceMethodsRef -- lifted bare and unchanged, never keyed here (#1354s method-namespace unit, OPEN, owns both). ZERO READERS: construction only, same bar as deData/deImpls'

declenvmodule_allowed='demOrd -- this module`s ordinal; 0 = the prelude
demId -- the loader module id (the SCOPE the two rows above are keyed by)
demDecls -- this module`s own decls, UNFILTERED (K is the whole graph; visibility is a predicate at the READ -- see declEnvVisibleTo)
demPubDecls -- #1512 A-3.2b: `publicDataDecls demDecls`, a MEMO of the publicity conjunct of declEnvVisibleTo, not a filtered population -- demDecls above still holds the row whole. Evaluated once per module in `declEnvModule` (the single constructor, so the two cannot drift) because the alternative is a per-decl publicity test inside a walk that runs once per ctor-naming import member of every module, i.e. an O(modules x universe) term'

cross_expected=$(printf '%s\n' "$cross_allowed" | awk 'NF{print $1}' | LC_ALL=C sort)
driver_expected=$(printf '%s\n' "$driver_allowed" | awk 'NF{print $1}' | LC_ALL=C sort)
declenvs_expected=$(printf '%s\n' "$declenvs_allowed" | awk 'NF{print $1}' | LC_ALL=C sort)
declenvmodule_expected=$(printf '%s\n' "$declenvmodule_allowed" | awk 'NF{print $1}' | LC_ALL=C sort)

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

declenvs_actual=$(sed -n '/^data DeclEnvs = DeclEnvs {$/,/^  }$/p' "$TC" \
  | strip_comments \
  | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:.*/\1/' \
  | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' \
  | LC_ALL=C sort)
declenvmodule_actual=$(sed -n '/^data DeclEnvModule = DeclEnvModule {$/,/^  }$/p' "$TC" \
  | strip_comments \
  | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:.*/\1/' \
  | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' \
  | LC_ALL=C sort)

cross_n=$(printf '%s\n' "$cross_actual" | grep -c .)
driver_n=$(printf '%s\n' "$driver_actual" | grep -c .)
declenvs_n=$(printf '%s\n' "$declenvs_actual" | grep -c .)
declenvmodule_n=$(printf '%s\n' "$declenvmodule_actual" | grep -c .)
if [ "$cross_n" -eq 0 ] || [ "$driver_n" -eq 0 ]; then
  echo "FAIL: check 1 extracted ZERO fields from CrossRun ($cross_n) or DriverState"
  echo "  ($driver_n). Either record was renamed/reshaped and the sed range markers"
  echo "  ('data CrossRun = CrossRun {' / '  | DriverState {') no longer match, or"
  echo "  this check just validated nothing. Update the range markers -- do NOT"
  echo "  treat a zero extraction as a pass."
  exit 1
fi
# Same fail-closed rule for the two A-3 bundle records. A zero extraction here is
# a BROKEN DELIMITER, never an empty answer -- and it is the likelier failure of
# the two, because #829 can flip a record's header between the one-line
# `data X = X {` form these ranges match and the two-line `data X =` / `| X {`
# form they do not.
if [ "$declenvs_n" -eq 0 ] || [ "$declenvmodule_n" -eq 0 ]; then
  echo "FAIL: check 1 extracted ZERO fields from DeclEnvs ($declenvs_n) or"
  echo "  DeclEnvModule ($declenvmodule_n). Either record was renamed/reshaped and"
  echo "  the sed range markers ('data DeclEnvs = DeclEnvs {' /"
  echo "  'data DeclEnvModule = DeclEnvModule {') no longer match -- note that"
  echo "  losing a record's last interior comment flips its header to the two-line"
  echo "  form, which these ranges do NOT match -- or this check just validated"
  echo "  nothing. Update the range markers -- do NOT treat a zero extraction as a"
  echo "  pass."
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
if [ "$declenvs_actual" != "$declenvs_expected" ]; then
  echo "FAIL: DeclEnvs' field set changed."
  echo "  allowed:"
  printf '%s\n' "$declenvs_expected" | sed 's/^/    /'
  echo "  actual:"
  printf '%s\n' "$declenvs_actual" | sed 's/^/    /'
  echo "  DeclEnvs is stage K's whole-graph environment bundle: a field added here"
  echo "  is a new PROGRAM-GLOBAL table, the shape AGENTS.md names as the most"
  echo "  expensive in this tree. REMEDY: add it to declenvs_allowed above with a"
  echo "  reason that PROVES its key's scope (what stops two same-spelled"
  echo "  declarations in unrelated modules from colliding) -- never widen this"
  echo "  check."
  exit 1
fi
if [ "$declenvmodule_actual" != "$declenvmodule_expected" ]; then
  echo "FAIL: DeclEnvModule's field set changed."
  echo "  allowed:"
  printf '%s\n' "$declenvmodule_expected" | sed 's/^/    /'
  echo "  actual:"
  printf '%s\n' "$declenvmodule_actual" | sed 's/^/    /'
  echo "  REMEDY: add the field to declenvmodule_allowed above with a one-line"
  echo "  reason -- never widen this check."
  exit 1
fi
echo "  ok: $cross_n CrossRun field(s), $driver_n DriverState field(s), $declenvs_n DeclEnvs field(s), $declenvmodule_n DeclEnvModule field(s), no new bundle field"

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
#
# 🚨 AND ctorFieldOrdersRef IS ITSELF A BARE-`String`-KEYED, GRAPH-GLOBAL
# POSITIONAL-LAYOUT TABLE (an assoc List, ctor name -> field-order List), so it
# is a member of the #1070 class even though the row above is only about WHO
# SEEDS it. Recorded here because PR #1381's round-2 review found the negative
# asserted more broadly than any command supported: that PR's body claimed
# "grep -n 'recordByName|RecordInfo|fieldOwners' over eval.mdk and
# core_ir_eval.mdk returns nothing, so neither module driver carries a parallel
# record table". The grep is literally true and none of its three terms can
# match `ctorFieldOrdersRef`, so the conclusion does not follow from it. The
# NARROW true claim, which is all the evidence supports:
#   - the TREE-WALK path is structurally immune -- it never populates the
#     table (checked above), so ERecordCreate yields `VRecord name assigns`
#     and evalField resolves by field NAME at run time; that immunity is
#     exactly why `medaka run` stayed correct throughout #1382.
#     🚨 THAT IMMUNITY IS ABOUT FIELD SLOTS AND NOTHING ELSE -- do not read it
#     as "the interpreter is safe from record-name collisions". It is not, and
#     the counterexample is one line away. Measured 2026-08-08: two modules each
#     declaring `public export data Cfg` with the same two Int fields in
#     OPPOSITE order and `deriving (Debug)`, an entry importing a value of each
#     and printing `debug` of both -- `check` exits 0 and `medaka run` prints
#     `Cfg { a = 11, b = 22 }` then `Cfg { a = 44, b = 33 }`, where the second
#     is the OTHER module's derived impl rendering zrmod's value: the field
#     values are name-correct but the render ORDER is armod's. Wrong impl,
#     wrong output, exit 0, from the interpreter. (The built binary is louder
#     for the same program -- `runtime error [E-NONEXHAUSTIVE-MATCH]`, exit 1,
#     which is the second face #1216's own body documents.) So state the narrow
#     claim: the tree-walk path resolves FIELD ACCESS by name, so no slot can be
#     mis-indexed there; IMPL SELECTION over a collided record name is a
#     different question and the interpreter gets it wrong;
#   - on the cevalModules path the table IS populated and IS bare-keyed. On
#     the emit path its keys are the MANGLED ctor names, which distinguishes
#     them. #1395's author probed three shapes against it and could not
#     reproduce a defect. That is NOT FOUND, not SAFE, and nobody should cite
#     it as a proof of absence.
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

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 4 — #1112 A-3.4: the `IE` NAMESPACE ratchet
# ═══════════════════════════════════════════════════════════════════════════
# THE PROPOSITION. `IE` is keyed by IMPL IDENTITY. An interface's default-method
# arm is a property of the INTERFACE declaration (CE's content, A-3a) and the
# emit-side method/default WORD namespace belongs to B-2 (#1113). No `IE` key
# component may be a method name.
#
# WHY MECHANICALLY. A future `IE` that folded the default-body registry in and
# keyed it (method, tag) would rebuild the OPEN S0 #1265 in the new substrate --
# that pair is exactly the key #1265 is the first-match over. Prose in the
# source would not hold anyone to this; a grep over a delimited block does.
# TYPECHECK-TARGET-ARCHITECTURE.md §9.3 records that this design decision is
# held OPEN to dissent; if it is ever overturned, this check is the artefact
# that must be edited, which is the point.
#
# ⚠️ WHAT THIS ENFORCES IS A PROXY FOR THE PROPOSITION, NOT THE PROPOSITION.
# Stated so nobody prices it higher than it is. The proposition is "no IE key
# component is a method name". What is actually checked is "no NsMethod/NsField/
# NsValue tag, and no reach into the named default-arm machinery, appears inside
# the IE block". Those coincide for every mint shape in the tree today -- a
# method name enters a TabKey through `tabKeyOf NsMethod` or an equivalent
# NsMethod-tagged mint -- but they are not the same statement, and the gap is
# constructible: a key built directly from the `ieMethods` payload strings, e.g.
# `regKeyNTab` over TabKeys minted with an NsType/NsIface tag from a method name,
# would satisfy this check and violate the proposition. Closing that needs a
# taint-style check on what flows INTO a key mint, which is well beyond a grep.
# The residual is accepted deliberately: this check's job is to make the design
# decision expensive to reverse by accident, and it does that.
#
# Occurrence-level (`grep -oE`), never a per-line containment test -- the hole
# this script's own header documents as "THE A-1 HOLE".
#
# 🔬 POSITIVE CONTROLS -- mutate compiler/types/typecheck.mdk, rerun, restore:
#   G  add `tabKeyOf NsMethod o n` INSIDE the IE block          -> FAIL
#   H  the same text in a COMMENT inside the block              -> pass
#      (a mention is not a mint; comments are stripped first)
#   I  the same text OUTSIDE the block                          -> pass
#      (the delimiting works)
#   J  delete/rename the IE-BLOCK-BEGIN banner so the block
#      extracts EMPTY                                           -> FAIL
#      <- THE LOAD-BEARING ONE. Without J this check carries this tree's
#         signature failure mode built in: a later refactor moves or rewords a
#         banner, the block extracts empty, and check 4 passes having examined
#         nothing -- a green that tested less than it appears to. Check 1
#         already solves exactly this; the fail-closed `-eq 0` guard below is
#         that pattern copied.
echo "checking #1112 A-3.4 IE namespace ratchet ..."

ie_block=$(sed -n '/IE-BLOCK-BEGIN/,/IE-BLOCK-END/p' "$TC" | strip_comments)
ie_n=$(printf '%s\n' "$ie_block" | grep -c . || true)
if [ "$ie_n" -eq 0 ]; then
  echo "FAIL: check 4 extracted ZERO lines for the IE block. Either the"
  echo "  'IE-BLOCK-BEGIN' / 'IE-BLOCK-END' banner comments in"
  echo "  compiler/types/typecheck.mdk were moved, reworded or deleted, or this"
  echo "  check just validated nothing. A zero-length IE block is a BROKEN"
  echo "  DELIMITER, never an empty answer. Restore the banners (or update this"
  echo "  range) -- do NOT treat a zero extraction as a pass."
  exit 1
fi

# The two families, kept separate so the failure message can say WHICH rule fired.
#   (a) a key MINT naming a namespace that is not IE's. NsType/NsIface are IE's
#       two; NsMethod/NsField/NsValue are not.
#   (b) the default-arm registry and its selector, plus the emit-side method
#       word table -- the specific machinery #1265 lives in and that B-2 owns.
ie_ns_hits=$(printf '%s\n' "$ie_block" \
  | grep -oE '\bNs(Method|Field|Value)\b' | LC_ALL=C sort -u || true)
ie_default_hits=$(printf '%s\n' "$ie_block" \
  | grep -oE '\b(defaultFnName|defaultFnNameW|defaultCellName|ifaceIdsAtTag|defaultOwnedBy|narrowDefaults|CImplDefault|methodIfaceTableRef|methodIfaceIndexRef)\b' \
  | LC_ALL=C sort -u || true)

if [ -n "$ie_ns_hits" ]; then
  echo "FAIL: the IE block mints a key in a namespace that is not IE's:"
  printf '%s\n' "$ie_ns_hits" | sed 's/^/    /'
  echo "  IE's key components are NsIface (identity, via oblIfaceKey) and NsType"
  echo "  (the head, bare by the #1317 T1 rule). A method/field/value component"
  echo "  in an IE key is the (method, tag) shape that rebuilds #1265 here."
  echo "  REMEDY: a method name belongs in an IE row as PAYLOAD (ieMethods), not"
  echo "  in a key. If you believe IE genuinely needs a method-name key"
  echo "  component, that is an owner-level re-adjudication of"
  echo "  TYPECHECK-TARGET-ARCHITECTURE.md §9.3 -- not a widening of this check."
  exit 1
fi
if [ -n "$ie_default_hits" ]; then
  echo "FAIL: the IE block reaches into the default-arm / emit-word machinery:"
  printf '%s\n' "$ie_default_hits" | sed 's/^/    /'
  echo "  That registry and its selector are #1265's and B-2's (#1113), not IE's."
  echo "  REMEDY: see the message above -- re-adjudicate §9.3 or move the code."
  exit 1
fi
echo "  ok: IE block is $ie_n line(s), no non-IE namespace mint, no default-arm reach"

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 5 — #1519 A-3.3: the `CE` construction ratchet
# ═══════════════════════════════════════════════════════════════════════════
# THE PROPOSITION, two-part, mirroring check 4's shape for the constraint this
# unit actually has (CE's defining rule is not a shared key namespace with a
# sibling table -- it is SYNTACTIC CONSTRUCTION plus a NAMED EXCLUSION):
#   (a) CE is built SYNTACTICALLY -- no call into the elaboration machinery
#       (fromAstTypeE / registerRecordInfoKeyed / freshVars / freshEffvar) may
#       appear inside the block. Those mint fresh tyvar ids from the global
#       counter and mutate perRun refs from the driver PREAMBLE, before the
#       per-module walk that owns that counter -- see the Step 0 derivation
#       in the block's own header.
#   (b) CE never reaches `universeMethodDispatchIdxRef` or
#       `universeIfaceMethodsRef` -- lifted bare and unchanged, deliberately
#       excluded (#1354's method-namespace unit, OPEN, owns both; keying
#       either here would build a second, differently-shaped answer to a
#       question #1353's S1-NS ruling already decided at the read).
#
# 🔬 POSITIVE CONTROLS -- mutate compiler/types/typecheck.mdk, rerun, restore:
#   K  add a call to `fromAstTypeE` INSIDE the CE block               -> FAIL
#   L  the same text in a COMMENT inside the block                    -> pass
#   M  the same text OUTSIDE the block                                -> pass
#   N  reference `universeIfaceMethodsRef` INSIDE the CE block        -> FAIL
#   O  delete/rename the CE-BLOCK-BEGIN banner so the block extracts
#      EMPTY                                                          -> FAIL
echo "checking #1519 A-3.3 CE construction ratchet ..."

ce_block=$(sed -n '/CE-BLOCK-BEGIN/,/CE-BLOCK-END/p' "$TC" | strip_comments)
ce_n=$(printf '%s\n' "$ce_block" | grep -c . || true)
if [ "$ce_n" -eq 0 ]; then
  echo "FAIL: check 5 extracted ZERO lines for the CE block. Either the"
  echo "  'CE-BLOCK-BEGIN' / 'CE-BLOCK-END' banner comments in"
  echo "  compiler/types/typecheck.mdk were moved, reworded or deleted, or this"
  echo "  check just validated nothing. A zero-length CE block is a BROKEN"
  echo "  DELIMITER, never an empty answer. Restore the banners (or update this"
  echo "  range) -- do NOT treat a zero extraction as a pass."
  exit 1
fi

ce_elab_hits=$(printf '%s\n' "$ce_block" \
  | grep -oE '\b(fromAstTypeE|registerRecordInfoKeyed|freshVars|freshEffvar)\b' \
  | LC_ALL=C sort -u || true)
ce_excluded_hits=$(printf '%s\n' "$ce_block" \
  | grep -oE '\b(universeMethodDispatchIdxRef|universeIfaceMethodsRef)\b' \
  | LC_ALL=C sort -u || true)

if [ -n "$ce_elab_hits" ]; then
  echo "FAIL: the CE block calls elaboration machinery:"
  printf '%s\n' "$ce_elab_hits" | sed 's/^/    /'
  echo "  CE is built SYNTACTICALLY (raw Ty/Super/Kind, no Scheme/Mono/RecordInfo)"
  echo "  -- the Step 0 ruling this unit's header derives and re-confirms. These"
  echo "  calls mint fresh tyvar ids and mutate perRun refs from the driver"
  echo "  PREAMBLE, before the per-module walk that owns that state."
  echo "  REMEDY: elaborate on demand at the READ site, not at construction --"
  echo "  or this is an owner-level re-adjudication of the Step 0 ruling, not a"
  echo "  widening of this check."
  exit 1
fi
if [ -n "$ce_excluded_hits" ]; then
  echo "FAIL: the CE block reaches a table #1519 excludes:"
  printf '%s\n' "$ce_excluded_hits" | sed 's/^/    /'
  echo "  universeMethodDispatchIdxRef and universeIfaceMethodsRef are lifted"
  echo "  bare and unchanged, never keyed here -- both belong to #1354's"
  echo "  method-namespace unit (OPEN)."
  echo "  REMEDY: see the message above -- re-adjudicate the exclusion with"
  echo "  #1354's owner or move the code there, not a widening of this check."
  exit 1
fi
echo "  ok: CE block is $ce_n line(s), no elaboration-machinery call, no excluded-table reach"

echo "PASS: #1111 registry keying ratchet (CrossRun/DriverState/DeclEnvs fields, writer sites, three-driver frame parity, #1112 A-3.4 IE namespace, #1519 A-3.3 CE construction)."
