# META
source_lines=4497
stages=DESUGAR,MARK
# SOURCE
-- tc_env: construction of `ImplEnv`, `ClassEnv`, `MethodEnv` and lookup in every declaration
-- envelope (`DataEnv`, `DeclEnvs`: accessors, visibility, the reach/import index and the import
-- site it finds (`importLocFor`), the export and definer tables; their construction from
-- declarations is `tc_decls`), the identity keys (including the built-in classes' spellings and
-- references, `builtinClassName`, `builtinIfaceRef`), the imported-binding rows
-- (`importedBindings`, `boundNames`), the alias table's two ordinal projections
-- (`aliasUniverseAt`, `aliasOwnAt`), and the term environment (`TcEnv` extension and lookup);
-- which names an import makes visible is `tc_scope`.
--
-- Spec: DICT section 8 (identity-keyed tables).
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_diag`, `tc_scope`,
-- `tc_unify`, `tc_decls_variance`, `tc_decls_types`, `tc_decls`, `tc_foreign`, `tc_solve_givens`,
-- `tc_solve_entail`, `tc_solve`, `tc_solve_check`, `tc_shadow`, `tc_effects`, `tc_occurrence`,
-- `tc_groups`, `tc_pat`, `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`, `tc_module`.

import types.tc_mono.{
  argMentions,
  entryHeadMatches,
  headTyconTy,
  implDeclsWithReqs,
  nthTy,
  schemeBodyOf,
  schemeIds,
  tyAppSpine,
  tyVarNames,
}
import types.tc_state.{
  builtinCtors,
  emptyClassEnv,
  emptyDataEnv,
  emptyDeclEnvSeedAcc,
  emptyImplEnv,
  emptyImplUniverse,
  emptyMethodEnv,
  probeGraphCtx,
}
import frontend.ast.{
  Constraint(..),
  DataVis(..),
  Decl(..),
  Expr(..),
  FunClause(..),
  Ident(..),
  IfaceMethod(..),
  ImplMethod(..),
  KindAnn(..),
  LetBind(..),
  Loc(..),
  Ns(..),
  Pat(..),
  Require(..),
  Super(..),
  TabKey(..),
  Ty(..),
  TyConOrigin(..),
  UseMember(..),
  UsePath(..),
  Variant(..),
  identOriginOf,
  mkIdent,
  orElseLoc,
  sameTyConHead,
  tabKeyEq,
  tabKeyOf,
  tyConBuiltin,
  useMemberLocal,
  useMemberOrigin,
}
import types.repr.{IfaceRef(..), Mono(..), Scheme(..), ppTy}
import types.effect_param_decode.{dtopIn}
import types.effect_domain.{Param(..)}
import types.effect_rows.{EffLabel(..)}
import types.tc_diag_text.{kindName}
import types.effect_infer.{AlphaBinder(..)}
import types.tc_types.{
  CeRow(..),
  ClassEnv(..),
  DeclEnvAcc(..),
  DeclEnvModule(..),
  DeclEnvs(..),
  EnvBinding(..),
  GraphCtx(..),
  ImplAcc(..),
  ImplEnv(..),
  ImplRow(..),
  ImplUniverse(..),
  InstRef(..),
  KeyEntry(..),
  Kind(..),
  MethodEnv(..),
  MethodPredicateSlot(..),
  MethodRow(..),
  MethodSchemeRow(..),
  ModuleCtx(..),
  RecordInfo(..),
  StandaloneOrigin(..),
  TcEnv(..),
  ValueScheme(..),
  AliasDecl,
  CDeclared,
  BuiltinClass(..),
  dynFor,
  MethodEntry,
}
import frontend.visibility.{useModId}
import support.ordmap.{
  omEmpty, omFromNames, omHasKey, omInsert, omLookup, omSize, OrdMap
}
import list.{
  findMap,
  last,
}
import support.util.{
  anyList,
  contains,
  dedup,
  filterList,
  isEmptyL,
  isSome,
  listLen,
  reverseL,
  selfBinding,
}
import types.registry.{
  HeadKey(..),
  headKeyOfCon,
  headKeyTag,
  mregAppendK,
  mregLookupK,
  MultiRegistry,
  regInsertK,
  Registry,
  RegKey,
  regKeyNTab,
  regKeyOfTab,
  regKeyRender,
  regLookupK,
}
import types.route_key.{implRouteKeyWord}
import types.solver_contract.{GoalOrigin(..)}

-- ── A-3.2b residual (#1512): the alias universe, sourced from stage K ──────
--
-- THE RETIREMENT.  `CrossRun.universeAliasTable` was a cross-run accumulator
-- grown one module at a time by `appendDataUniverse`'s load/register/store
-- round trip.  It is GONE; this is its whole-graph replacement, and it is a
-- projection of K rather than a second copy of the same fact.
--
-- Three separately named conditions, and the split is the whole design.
-- They are NOT one fused `adPub && adOrd < cur` test — this file prohibits
-- open-coding the filter in four places (`grep -n 'open-cod'`), and
-- `declEnvRowVisible`'s own comment is *"Both arms go through the predicate;
-- neither open-codes `<=` or a `pub` test."*
--
--   1. `declEnvVisibleTo cur ad.adOrd ad.adPub` — BOTH ratified conjuncts, the
--      ordinal one and the publicity one, applied through the ONE predicate.
--      This is a production reader of `declEnvVisibleAt`.  It used to say "the
--      THIRD (after `declEnvRowVisible` and `ieSnapAt`); the ratchet's
--      `declEnvsRef` row records all three".  BOTH halves are now wrong: the
--      ratchet's count was measured wrong in both directions (RUN-007/RUN-013 —
--      it is eight leaf read paths, not three), and `ieSnapAt` is no longer a
--      reader of this predicate at all, having moved to `ieCandidacyVisibleAt` at
--      A-3.6.  DERIVE the set; do not carry a count.
--   2. `ad.adOrd /= cur` — the OWN-ROW EXCLUSION.  This one is structural, not
--      TRANSITIONAL.  This clause used to justify itself by "A-3.6 deletes
--      `declEnvVisibleAt`'s body, at which point condition 1 reduces to the
--      publicity conjunct alone and this line is the only thing still keeping the
--      reader's own row out."  A-3.6 did NOT delete that body (it split the
--      predicate and flipped the instance axis only), so condition 1 still
--      carries the ordinal — but the conclusion is UNCHANGED and does not depend
--      on the premise: this condition is structural on its own terms.  It is not
--      an ordinal FILTER wearing an
--      ordinal's clothes: the retired accumulator held the public aliases of
--      every module whose arm had ALREADY FINISHED (`appendDataUniverse` is the
--      last statement of a module's arm), so a reader at ordinal k saw
--      0..k-1 and never itself, and its own aliases — public AND private —
--      arrive by a route this unit does not touch (`registerAllData … prog0`
--      conses them onto the front of the working `aliasTableRef`).  Dropping
--      this would double-register every public alias the reader declares.
--      Conditions 1 ∧ 2 are exactly the `<` the accumulator had (`<=` ∧ `/=`).
--      This used to add "under A-3.6 they reduce to `adPub && adOrd /= cur`,
--      which is the intended end state".  They do NOT: A-3.6 left the alias table
--      — a NAME-scoping table — on `declEnvVisibleAt`, deliberately, because
--      `DICT-SEMANTICS.md`'s I5 boundary clause says its price does not extend to
--      names.  That reduction is owed to whichever unit widens the name axis, if
--      one ever is; it is not scheduled.
--   3. RETIRED.  This was `not ad.adAttrib`, the attributed-alias drop applied
--      HERE at the read rather than in the population.  #1228/#1586's re-add
--      condition on `dataEnvAddDecl` fired: `registerData` gained its `DAttrib`
--      unwrap arm, so the guard had to go in the same diff.  The POPULATION still
--      records `adAttrib` and still holds attributed aliases — that neutrality is
--      what the `listLen aliasFixtureEnv.deAliases` doctest asserts — the read
--      simply no longer narrows on it.
--
-- THE CYCLIC-alias removal is preserved by doing nothing.
-- `rejectCyclicAliases` DELETES cyclic entries from the per-run
-- `aliasTableRef`, and that deletion never reached the accumulator either:
-- `appendDataUniverse` opens by RELOADING the working ref from the universe,
-- discarding the filtered value, before it registers and stores.  So the
-- cross-module alias source has always held cyclic entries and every module
-- re-detects them through its own `rejectCyclicAliases` call.  This function
-- reproduces that exactly — it filters on visibility only.  A future edit that
-- "helpfully" pre-drops cyclic aliases here would silence the second and later
-- modules' `T-RECURSIVE-ALIAS`, which is a loud → silent severity increase.
-- Pinned by the `1512-A32b/alias-cycle-importer` leg of
-- `test/diff_compiler_check_cli_modules.sh`, which requires the diagnostic to
-- name BOTH the declaring module and the importer.
-- Allocation shape, recorded because the perf gate cannot see it.  The line
-- this replaced in `loadDataUniverse` was a pointer copy (`setRef … .value`);
-- this MATERIALISES a filtered list, and it runs twice per module (the arm's
-- own reload and `appendDataUniverse`'s).  That is the allocation term
-- `declEnvRowVisible`'s "ZERO ALLOCATION … MEASURED perf contract" note forbids
-- for its sibling — and `diff_compiler_perf_scaling.sh`'s `gen_modules` shape
-- declares no type aliases at all, so the gate is BLIND to it (derive, don't
-- trust: `grep -n 'type ' test/diff_compiler_perf_scaling.sh`).
-- It is immaterial at this size and that was MEASURED, not assumed — but by PR
-- #1588's independent reviewer, not by me, so it is RELAYED: with 24 aliases,
-- 40 modules 864 → 824 ms and 80 modules 3489 → 3462 ms (interleaved, min of 3),
-- i.e. inside the noise.  The reason it stays immaterial is that `deAliases` is
-- SMALL — 11 type aliases in the whole tree today.  If a future graph makes
-- aliases numerous, the fix is the per-ordinal snapshot `ieUnivSnaps` already
-- uses for `IE`, not a wider filter.
export
aliasUniverseAt : Int ->
  List (TabKey, AliasDecl) ->
  List (TabKey, (List String, Ty))
aliasUniverseAt _ [] = []
aliasUniverseAt cur ((key, ad) :: rest)
  | aliasVisibleTo cur ad =
    (key, (ad.adParams, ad.adRhs)) :: aliasUniverseAt cur rest
  | otherwise = aliasUniverseAt cur rest

-- The three conditions of the block above, in that order.  Split out so each is
-- separately readable and separately greppable.  This said "A-3.6 edits
-- condition 1's predicate and must leave conditions 2 and 3 standing".  A-3.6
-- (#1558) edited NONE of the three — the alias table is a NAME-scoping table and
-- the split ruling left the whole name axis alone.  All three conditions stand as
-- written; the split-out shape is what will make a future name-axis unit cheap, and
-- conditions 2 and 3 remain structural whatever happens to condition 1.
-- CONDITION 3 IS GONE — #1228/#1586's re-add condition FIRED.  `registerData` now
-- has a `DAttrib` unwrap arm, so an attributed alias expands where it is DECLARED;
-- keeping `not ad.adAttrib` here would have left it opaque in importers, i.e. the
-- exact mirror-widening `dataEnvAddDecl`'s note said this guard must not outlive.
-- `adAttrib` stays RECORDED (population neutrality is still asserted by the
-- `listLen aliasFixtureEnv.deAliases` doctest) but no longer filters.
aliasVisibleTo : Int -> AliasDecl -> Bool
aliasVisibleTo cur ad =
  declEnvVisibleTo cur ad.adOrd ad.adPub && ad.adOrd /= cur

-- The current module's aliases arrive in front of its imported alias universe in
-- `checkBodyImpl`.  `DataEnv.deAliases` is already reverse declaration order, so
-- this filter preserves the exact first-match lookup order without rebuilding a
-- second registry.
export
aliasOwnAt : Int -> List (TabKey, AliasDecl) -> List (TabKey, (List String, Ty))
aliasOwnAt _ [] = []
aliasOwnAt cur ((key, ad) :: rest)
  | ad.adOrd == cur = (key, (ad.adParams, ad.adRhs)) :: aliasOwnAt cur rest
  | otherwise = aliasOwnAt cur rest

-- The graph's interface-row index (`meIfaceExports`); `omEmpty` before a driver
-- built `DeclEnvs`, which `nameableIfaceShadows` and its peers read as "no index".
export
ifaceExportsIndex : GraphCtx -> Unit -> OrdMap (List (String, List String))
ifaceExportsIndex gctx _ = gctx.declEnvsRef.value.deMethods.meIfaceExports

-- Recursive contracts precede body generalization. Their predicate templates
-- belong to the same allocation as their scheme, not the final definition's ids.
export
bindingDeclared : TcEnv -> String -> Option CDeclared
bindingDeclared env name = match lookupBinding env name
  Some binding => binding.ebValue.vsDeclared
  None => None

export
attachStandaloneSources : OrdMap Scheme ->
  List (String, EnvBinding) ->
  List (String, EnvBinding)
attachStandaloneSources sources bindings =
  map
    ((name, binding) => (
      name,
      match omLookup name sources
        Some source => bindingWithStandalone binding (
          ImportedStandalone,
          ordinaryValueScheme source,
        )
        None => binding,
    ))
    bindings

export
standaloneValueFor : TcEnv -> String -> String -> Option ValueScheme
standaloneValueFor env name sym = match lookupStandaloneValue env name
  Some value => Some value
  None =>
    if sym == "" then
      None
    else
      map (binding => binding.ebValue) (lookupBinding env sym)

-- The type parameters and direct supers of one interface, by identity.
export
superLookup : GraphCtx -> IfaceRef -> Option (List String, List Super)
superLookup gctx ir =
  let key = regKeyOfTab (ifaceTabKey ir.irOrigin ir.irName)
  map
    (row => (ceRowTyparams row, ceRowSupers row))
    (ceLookupGraph key gctx.declEnvsRef.value.deIfaces)

export
keyEntryIface : KeyEntry -> String
keyEntryIface (KeyEntry _ _ _ _ ifn _ _ _) = ifn

-- #1675: the `deAmbigValues` peer of `graphPubDefiners`.  A driver that never built an
-- envelope (Flat / loader-less) reads the empty map and answers `[]`, so the ambiguity
-- check FAILS OPEN there — the same discipline `memberDefinerRow`'s fallback takes for
-- an absent graph, and the reason a single-file program can never trip this diagnostic.
export
graphAmbigValues : GraphCtx -> String -> List (String, List String)
graphAmbigValues gctx mid =
  match omLookup mid gctx.declEnvsRef.value.deAmbigValues
    None => []
    Some rows => rows

-- Module id → every module id it reaches through `DUse` edges, seeded EMPTY so a
-- module is reachable from itself only through a genuine cycle (the property the
-- per-target `fst p /= mid` guard above relied on the old path-pruned DFS for).
--
-- The direct-import edges are indexed FIRST, for the reason spelled out at
-- `declEnvReachIndex`: this walk visits O(modules) rows per module, so a direct-import
-- lookup that SCANS the module list — and re-runs `flatMap useModuleId` over the
-- scanned module's whole decl list, as the DFS this replaces did — makes the index
-- cubic in the module count.
export
importerReachIndex : List (String, List Decl) -> OrdMap (OrdMap Unit)
importerReachIndex mods =
  importerReachGo (importerEdgeIndex mods omEmpty) mods omEmpty

importerReachGo : OrdMap (List String) ->
  List (String, List Decl) ->
  OrdMap (OrdMap Unit) ->
  OrdMap (OrdMap Unit)
importerReachGo _ [] acc = acc
importerReachGo edges ((mid, _) :: rest) acc =
  importerReachGo
    edges
    rest
    (omInsert mid (declEnvReachFrom edges [mid] omEmpty) acc)

-- Module id → the ids its `DUse` decls name, mirroring the oracle's path→module-id
-- mapping (`useModuleId`).  FIRST row wins and an absent id yields `[]` — the two
-- properties of the `lookupAssoc` scan this replaces.
importerEdgeIndex : List (String, List Decl) ->
  OrdMap (List String) ->
  OrdMap (List String)
importerEdgeIndex [] acc = acc
importerEdgeIndex ((mid, prog) :: rest) acc
  | omHasKey mid acc = importerEdgeIndex rest acc
  | otherwise =
    importerEdgeIndex rest (omInsert mid (flatMap useModuleId prog) acc)

-- S1's standalone operand is TWO conjuncts, and the second one is not optional.
-- An import form admits the row only if it binds the LOCAL name [bare] *and* the module
-- it imports from actually exports a STANDALONE so named.  Binding the name is not the
-- same fact: `import ifc.{Sizeable, size}` binds `size` to the interface METHOD, and
-- `import list.*` binds every name `list` exports and no others — in neither case is a
-- standalone `size`/`length` owned by some third module "imported into `M`", so in
-- neither case is it a shadow in `M` (`docs/spec/SHADOW-SEMANTICS.md` §1, clause S1).
--
-- MEASURED (#2809): the wildcard arm used to answer `True` for EVERY name, and while
-- the row's symbol was `<owner>__name` that over-admission was inert (the route always
-- named a define that existed).  With the bare row the route is `name`, resolved per
-- unit, and a unit that merely binds the method name has no such define: two files,
-- `import list.*` beside another module's standalone `length`, and `build` died
-- `use of undefined value '@mdk_length'` on a program `check` and `run` both accept and
-- get right.  The member-list arm reached the same end one step earlier — a DISPATCH
-- became a direct call to a standalone that is not in scope at the call site
-- (`@mdk_impl_BoxS_size` → `@mdk_size`) — so both arms are filtered, not just the
-- wildcard.
--
-- The export half is `graphPubDefiners`, the same table `importDefinersOf` admits
-- through: declared public top-level funDefs plus re-exports resolved transitively, so
-- a standalone reaching `M` through a re-export chain is admitted exactly as a directly
-- imported one is.  It answers `[]` on a driver that built no envelope (Flat /
-- loader-less) and for `core`, and both of those FAIL OPEN — the status-quo answer, and
-- the same discipline `memberDefinerRow`'s fallback takes for an absent graph.
-- does [depId] export a top-level STANDALONE named [bare]?  Fail-open where the graph
-- cannot say (`depExportsUnknown`).
export
depExportsStandalone : GraphCtx -> String -> String -> Bool
depExportsStandalone gctx depId bare
  | depExportsUnknown gctx depId = True
  | otherwise = anyList (r => fst r == bare) (graphPubDefiners gctx depId)

-- can [depId]'s export table answer at all?  Named rather than restated because
-- `formBareLocals`' wildcard arm asks the SAME question of a whole form: a form whose
-- dependency the graph cannot speak for admits every name, which is what makes that arm
-- `blAll` rather than a set.  Two answers to one question here would be two fail-open
-- policies, which is the shape S1's admission predicate cannot afford.
export
depExportsUnknown : GraphCtx -> String -> Bool
depExportsUnknown gctx depId =
  depId == "core" || omSize gctx.declEnvsRef.value.deDefiners == 0

-- ── RefinementDomain interface (design §2.1): dtop/dsub/djoin/dmeet/drender ──
-- Stage 1: only ⊤ params (PUnit / PPrefix None) ever occur; the STRUCTURE is
-- what Stage 2's Prefix analysis plugs into.  A label's domain is fixed by its
-- declaration; dtopFor picks the ⊤ of the label's domain (all PUnit in Stage 1).
-- ⊤ parameter for a label's domain (design §2.1): consults the registry;
-- labels with no Prefix entry are atomic ⇒ PUnit.
export
dtopFor : GraphCtx -> EffLabel -> Param
dtopFor gctx label = dtopIn gctx.effectDomains.value label

-- A pattern-ranging binder needs a domain whose patterns are more than its
-- top and bottom: a Prefix domain, or a Product whose primary axis is one.
-- In a Set domain every element is exact, so the only pattern is the top.
export
domainHasPatterns : Param -> Bool
domainHasPatterns (PPrefix _) = True
domainHasPatterns (PPath _) = True
domainHasPatterns (PProduct ((_, axis) :: _)) = domainHasPatterns axis
domainHasPatterns _ = False

-- Whether a binder written with [pat] on label [l] ranges over patterns. A
-- `*` on a label with no patterns is refused where it is written; the binder
-- then ranges over the whole domain, as it would without it.
export
rangedOver : GraphCtx -> EffLabel -> Bool -> Bool
rangedOver gctx l pat = pat && domainHasPatterns (dtopFor gctx l)

-- the resolved slot kinds of the sub-interface's OWN parameter [p]
export
ifaceParamKindsFor : GraphCtx ->
  List String ->
  List (Option KindAnn) ->
  List IfaceMethod ->
  String ->
  List Kind
ifaceParamKindsFor gctx [] _ _ _ = []
ifaceParamKindsFor gctx (q :: qs) (a :: anns) methods p
  | q == p = ifaceParamKindsDecl gctx a p methods
  | otherwise = ifaceParamKindsFor gctx qs anns methods p
ifaceParamKindsFor gctx _ [] _ _ = []

-- ── #1111 A-2.3: the TYPE-namespace table key, and the MISS POLICY ────────
-- The ONE place a key for `aliasTableRef` / `dataParamKindsRef` is minted, on
-- both the write side and the read side.  `o` is always the `TyConOrigin` the
-- `Ty.TyCon` being registered or elaborated carries — never ambient state (see
-- `registerVariants`' note: `registerAllData` runs over OTHER modules'
-- decls, so a "current module" id would attribute every imported type to the
-- importer).
--
-- ── What changed, and what drains ─────────────────────────────────────────
-- Both tables are grown per-module across the WHOLE import graph and used to
-- be read by BARE NAME, so `lookupAssoc`'s first-match over a prepend meant
-- the module that registered last won for every importer, regardless of which
-- module's type was actually in scope at the use site.  Three tracked defects
-- were that one sentence: #1069 (a written row erased to its wrapped type,
-- silently, exit 0), #1090 (the same table rejecting a VALID signature with
-- T-EFFECT-KIND-MISMATCH — same collision, opposite symptom, selected by the
-- row's SPELLING at the use site, not by arity) and #1070's alias row (`v : T`
-- resolving to the wrong module's `Float`, wrong VALUE at run time, all three
-- engines agreeing).
--
-- ── MISS POLICY: a miss stays a silent `appFallback`.  Derivation ─────────
-- Every path that reaches `appFallback` (or the equivalent abstention at the
-- other readers) after this change, enumerated:
--   1. A BUILTIN HEAD.  `Int`/`Float`/`String`/`Char`/`Bool`/`Unit`/`List`/
--      `Ref`/`Array` and the tuple heads have NO declaration anywhere (checked
--      tree-wide, not assumed: no `data`/`newtype`/`type` declares any of those
--      names in `stdlib/`, `compiler/` or `sqlite/`), so they have no row in
--      either table and never had one.  This is the case the pre-existing
--      comment on `checkGradedImplHead` already names ("a builtin like `Int`,
--      whose kinds this compiler records nowhere").  It is COMMON and CORRECT.
--   2. an alias head looked up in `dataParamKindsRef` — an alias lives in the
--      other table, and its saturation is already policed by T-ALIAS-ARITY.
--   3. an arity mismatch (`listLen kinds /= listLen args`) — a guard the hot
--      readers apply AFTER the lookup; unchanged by this unit.
--   4. A name with no declaration at all, in a program resolve has already
--      rejected — errors accumulate here rather than exiting, so typecheck
--      still runs over the broken tree.
--   5. new with this unit: a head whose identity names a module that declares
--      no such type, while some OTHER module in the graph does.  That is
--      exactly #1069/#1090/#1070, and abstaining is the FIX, not a residual.
-- So "miss ⇒ hard diagnostic" is not available: case 1 alone would reject
-- every `x : List Int` ever written, and nothing at the read site can tell
-- case 1 from case 5 — the compiler records no kinds for builtins, which is
-- the very reason case 1 exists.  Cases 2–4 are equally legitimate.  A miss
-- therefore keeps doing what it does today.
-- Note what this does NOT say: the drains above do not come from the miss
-- policy, they come from the KEY.  Under bare-name keying #1069's lookup HIT
-- the wrong module's row; under identity keying it hits its own row.  Case 5
-- is the residue (a genuinely absent type), not the mechanism.
--
-- `TkBare` is not a fallback the graph path can reach. `tabKeyEq`
-- (`types/registry.mdk`) never equates a `TkIdent` with a `TkBare`, in either
-- direction, so an identity-bearing lookup can neither hit a bare row nor be
-- hit by one — re-creating the bug "with extra steps" is structurally
-- excluded rather than avoided by care.  What makes that safe rather than a
-- new silent hole is that the two halves cannot mix within one run: an
-- occurrence acquires identity from the resolved graph's `tyOriginScope`,
-- whose every layer is derived from declarations that the SAME pass stamps
-- (own / imported / prelude), plus a builtin layer whose names have no
-- declarations (case 1 above).  So "identity-bearing occurrence, unstamped
-- declaration" has no producer.
export
tyTabKey : TyConOrigin -> String -> TabKey
tyTabKey o n = tabKeyOf NsType o n

-- ── #1111 A-2.4: the INTERFACE-namespace table key ────────────────────────
-- `tyTabKey`'s peer for the `NsIface` namespace, and the ONE place a key in that
-- namespace is minted — on both the write side and the read side.  #1557 A-3.5c:
-- `ifaceParamKindsRef` was one of the two tables named here and is RETIRED; the
-- other was `universeIfaceRequiredRef`, RETIRED in turn by #1557 A-3.5a.  The
-- surviving consumer is stage K's `CE` alone — `ceRowKey`/`ceLookupAt`, and through
-- it `ceRequiredAt` (impl completeness), `ceSlotKindsAt` (graded impl heads) and
-- `ifaceDfsCycleOneSuper`'s superinterface edge.
--
-- ── The two sides, and WHY they meet ──────────────────────────────────────
-- The WRITE side always passes a `DInterface`'s `ifaceOrigin`: the DECLARATION
-- layer, stamped by `stampDeclOrigins mid` (`frontend/resolve.mdk`) with the
-- module that declared it.  The READ side always passes a `DImpl`'s
-- `implOrigin`: the OCCURRENCE layer, stamped by `stampTyOrigins` from
-- `tyOriginScope`, which maps an interface NAME to the module that DECLARED
-- it (own layer `ownIfaceOrigin mid`, imported layer `importedTypeOrigins`).
-- So both sides name the DECLARING module and the two meet — that agreement,
-- not the miss policy, is what makes this key work.  It is the same
-- per-population stamping-agreement argument A-2.3 wrote onto `tyTabKey`,
-- one namespace over; both layers are produced by `stampOneModule`
-- (`resolve.mdk`), in one function, so they cannot drift apart.
-- ── MISS POLICY: a miss ABSTAINS.  Derivation ─────────────────────────────
-- Both readers already abstain on a miss and this unit does not change that:
--   * `implCompletenessMsgsOfMap`'s `None` arm is `[]` with the pre-existing
--     comment "unknown interface (reported elsewhere) → skip".  An `impl` of
--     an interface that is genuinely not in scope is reported by RESOLVE
--     (`R-*`), so a second complaint here would be a worse-worded duplicate.
--   * `checkGradedImplTys`' `_ =>` arm is `()`, and its own doc-comment
--     already enumerates the legitimate misses (a NON-graded interface, which
--     records an all-`KType` row and is filtered by `anyKRow`; an interface
--     with fewer parameters than the impl has type arguments).
-- "Miss ⇒ hard diagnostic" is therefore not available for either, and it is
-- not a residual: with an identity key the ONLY new miss is "this impl's
-- interface resolved to a module that declares no such interface", which
-- cannot happen for an accepted program — resolve rejects the impl first.
--
export
ifaceTabKey : TyConOrigin -> String -> TabKey
ifaceTabKey o n = tabKeyOf NsIface o n

-- Build the envelope from the prelude + the loader's dependency-first module list.
-- Must run AFTER the driver's `stampGraphTyOrigins`, for the same reason
-- `meExports` must: identity lives on the decls, so an envelope built
-- from the unstamped tree would carry a different one.  The one call site
-- (`graphPreamble`) sits after the driver's stamp.  The prelude row is passed in
-- separately so the fold can be RESUMED from it -- see `buildDeclEnvs` below and
-- `DeclEnvAcc`.

export
emptyDeclEnvAcc : DeclEnvAcc
emptyDeclEnvAcc = DeclEnvAcc {
  daOrdIndex = omInsert "" 0 omEmpty,
  daDefiners = omEmpty,
  daAmbig = omEmpty,
  daData = emptyDataEnv,
  daImpls = emptyImplAcc,
  daIfaces = emptyClassEnv,
  daMethods = emptyMethodEnv,
  daSeeds = emptyDeclEnvSeedAcc,
  daPolarity = ([], omInsert "" [] omEmpty),
  daOwnerModules = omEmpty,
}

-- the only way to build A ROW.  A-3.2b (#1512) added `demPubDecls`, which is a
-- MEMO of `demDecls` and must never disagree with it; a record literal at a second
-- site is exactly how the two would come to.  Every construction — the graph builder
-- above and the `CE`/`IE` doctest probes below — goes through here.
--
-- `demPubDecls` is the publicity conjunct of `declEnvVisibleTo`, evaluated ONCE per
-- module rather than per decl at every read.  It is a MEMO, not a filtered
-- population: `demDecls` still holds the row's decls unfiltered, which is what the
-- ruling's "K is the whole graph, visibility is a predicate at the READ" requires —
-- the two projections sit side by side and `declEnvRowVisible` picks between them.
--
-- `demKindEntries` is the SAME discipline for the THIRD projection A-3.2b slice 2
-- needed (see `kindPublicDataDecl`): a memo of the row's kind-public entries, not a
-- filtered population.  It is entries rather than decls because the read side wants
-- `(TabKey, List Kind)` pairs and `inferParamKinds` is pure — computing it here runs
-- it once per decl for the whole run instead of once per (decl, reading module).
export
declEnvModule : GraphCtx -> Int -> String -> List Decl -> DeclEnvModule
declEnvModule gctx k mid decls = DeclEnvModule {
  demOrd = k,
  demId = mid,
  demDecls = decls,
  demPubDecls = publicDataDecls decls,
  demKindEntries = declEnvKindEntries gctx (filterList kindPublicDataDecl decls),
}

-- The graph's decls in ordinal order.  `++` is associative, so this is the same
-- LIST VALUE the two drivers built as `coreDecls ++ flatMap snd modules` — that
-- equality is what makes replacing their inline concats byte-identical.
export
declEnvDeclsOf : List DeclEnvModule -> List Decl
declEnvDeclsOf [] = []
declEnvDeclsOf (m :: rest) = m.demDecls ++ declEnvDeclsOf rest

-- the ordinal filter for the **NAME/DECLARATION** AXIS.  It is LIVE and it is
-- STAYING — A-3.6 did NOT delete it.
--
-- this block said "the one ordinal filter … A-3.6 is the deletion of this
-- predicate's body and nothing else" UNTIL 2026-08-12, and that design was
-- OVERRULED.  The arc had assumed one body, one semantics change.  It is not:
-- this one predicate is read by an instance-candidacy path AND by four
-- name/data-scoping tables (the alias table, the ctor overlay pool, the
-- field-owner multimap, the data param-kind table, plus `CE`'s two lookups).
-- Deleting the body would have applied an INSTANCE-candidacy licence to all of
-- them, and `docs/spec/DICT-SEMANTICS.md` forbids exactly that reading by name:
-- *"I5 does NOT extend that price to NAMES … I5's subject is `match(IE, C τ̄)`."*
-- Worse, one of the four is a NARROWING, not a widening — the paragraph on
-- `declEnvVisibleTo` below records it MEASURED on this tree — and §5 R2's two
-- enumerated exceptions are both widenings.  A narrowing cannot meet that bar.
--
-- So the predicate SPLIT, by owner ruling: A-3.6 flips the instance axis through
-- `ieCandidacyVisibleAt` below, and this one keeps its ordinal body for every
-- name-scoping reader.  The invariant that survives is NOT "there is one body" —
-- it is "there is one body PER AXIS, and no read site open-codes `<=`".  Route a
-- new ordinal test through whichever of the two matches its SUBJECT, and if you
-- cannot tell which, that is the question to escalate rather than the choice to
-- guess.  Widening any of this predicate's readers is a separate unit with its
-- own fixtures; it is not a side effect of anything.
export
declEnvVisibleAt : Int -> Int -> Bool
declEnvVisibleAt cur entryOrd = entryOrd <= cur

-- THE INSTANCE-CANDIDACY AXIS — A-3.6 (#1558), and this is the C4/I2 flip.
-- Which impls may be CANDIDATES for a goal at a reading ordinal.  Graph-global by
-- construction: every instance declared in every loaded module is a candidate
-- everywhere, so this predicate holds unconditionally and the ordinal arguments
-- exist only so the read sites do not move.
--
-- why it is `True` rather than deleted.  `DICT-SEMANTICS.md` §8 I5 / §7 C4 / I2:
-- *"`match(IE, C τ̄)` ranges over every instance declared in every module … Import
-- scoping decides which NAMES a module may write.  It never decides which
-- instances exist."*  Keeping a named predicate rather than open-coding `True` at
-- the read site keeps the axis greppable and keeps the C4/I2 guarantee attached
-- to a symbol a later unit can find; it is the same discipline the name axis
-- above is under, pointed the other way.
--
-- the parameters are deliberately unused and must stay.  `ieSnapAt` walks
-- ordinal-ordered snapshots and keeps the LAST one this admits; with `True` that
-- is the final snapshot, i.e. the whole graph, which is exactly the intended
-- semantics.  Re-introducing an ordinal test here re-instates the prefix rule and
-- silently un-does A-3.6 — the cheapest structural check that the flip is still
-- landed is that `grep 'entryOrd <= cur'` finds the name axis and NOT this one.
--
-- the second reader, and it is now ruled.  `ieRowsVisibleAt` (A-3.5b) is the
-- other `IE` reader; it answers a DECL-TIME EXISTENCE question (`checkSuperImpls`)
-- rather than a candidacy one, and when A-3.6 landed it was left on
-- `declEnvVisibleAt` with that question recorded as OPEN.  It was then MEASURED
-- open: with candidacy graph-global and existence prefix-scoped, an `impl Sup T` in
-- a topologically LATER module satisfies dispatch in the very module where
-- `checkSuperImpls` reports the same impl missing — one program, two channels, one
-- of them wrong.  ⚖️ OWNER RULING (Val, 2026-08-12, RUN-055,
-- finding SA-3): WIDEN the existence check to match candidacy.  `ieRowsVisibleAt`
-- now reads THIS predicate, so both `IE` reads answer at the same scope and the
-- diagnostic cannot contradict the engine.
-- the name axis is untouched by that ruling.  RUN-010 split the predicate
-- precisely so the name-scoping tables keep their ordinal filter, and
-- `DICT-SEMANTICS.md:2025-2033` forbids extending I5's licence to names.  The
-- SUPERS themselves still come from `CE` at the reading ordinal (`ceLookupAt` in
-- `checkImplSuperContexts`); only the row set the existence query scans moved.
ieCandidacyVisibleAt : Int -> Int -> Bool
ieCandidacyVisibleAt _ _ = True

-- The ordinal of [mid], or `0 - 1` when the envelope holds no row for it.
-- FAIL-CLOSED deliberately: at `-1` `declEnvVisibleAt` rejects every entry, so a
-- reader arriving with an unknown module id LOSES declarations and produces a
-- reject (loud), instead of gaining the whole graph early and producing a silent
-- accept.  `buildDeclEnvs` registers the prelude's `""` spelling, so the miss is
-- unreachable from the two drivers that exist today.
--
-- "FAIL-CLOSED" IS A claim about the reader, not about this function, and since
-- #1557 A-3.5c there are readers of the opposite polarity.  The argument above holds
-- for a reader that CONSUMES declarations to build something — losing them shrinks a
-- universe and the missing entry is reported.  It INVERTS for a reader that consumes
-- declarations to CHECK them: at `cur = -1`, `ceRowsVisibleAt`/`ceRowsOwnedBy` return
-- `[]` and `ceLookupAt` misses everything, so W1 acyclicity, phantom-method rejection
-- and the graded impl-head kind check all have nothing to iterate and become SILENT
-- ACCEPTS.  Same `-1`, opposite severity direction.
--
-- SUSPECTED-UNPROVEN, and recorded rather than fixed because it is not reachable
-- today: the ids come from the very list `buildDeclEnvs` indexed, within one driver
-- invocation, so a checking reader cannot arrive with an id the envelope never saw.
-- Probed against the retired #1223 nested-root fixture — the
-- one place a module id has historically disagreed with itself — and all three checks
-- fire identically on both arms.  A-3.5a/A-3.5b relocate MORE checking readers behind
-- this same ordinal; whoever writes them must not read the paragraph above as a
-- blanket safety property.  If a driver ever threads an id `buildDeclEnvs` did not
-- index, the remedy is at the READER (abstain loudly / fail the pass), not here — a
-- sentinel that means "everything" would break the consuming readers symmetrically.
export
declEnvsOrdOf : String -> DeclEnvs -> Int
declEnvsOrdOf mid envs = ordOfIndex mid envs.deOrdIndex

-- `declEnvsOrdOf` over the ordinal index alone (`DeclEnvs.deOrdIndex`, or a
-- drive's `doOrdIndex`).
export
ordOfIndex : String -> OrdMap Int -> Int
ordOfIndex mid index = match omLookup mid index
  Some k => k
  None => 0 - 1

-- 🪦 RETIRED 2026-08-12 (A-3.6 bite C-0): `declEnvsVisible` / `declEnvsUpTo` /
-- `declEnvsUpToGo` — the whole-ROW accessor path ("the graph as [mid] may see it").
-- A-3.1 shipped them speculatively and `export`ed `declEnvsVisible` only to keep
-- `rule-dead-code` off the unreached block; A-3.2a, A-3.2b, A-3.4 and A-3.5c each
-- then built their own visibility path and NONE of them used it.  Zero tree-wide
-- callers at deletion time (`grep -rn 'declEnvsVisible\|declEnvsUpTo' --include=*.mdk .`
-- → definitions and comments only).  It was also one of the direct call sites of
-- `declEnvVisibleAt`, so removing it makes that predicate's reader set entirely LIVE
-- before A-3.6 reasons about it — which is the point of retiring it first.
-- Do NOT re-add: the live shape is a predicate applied at the READ
-- (`declEnvVisibleTo` / `declEnvRowVisible` below), not a pre-filtered row list.

-- the second visibility predicate — A-3.2b (#1512), the interim rule RATIFIED by
-- the repo owner on that issue for K's declaration environments.  `DataEnv` keeps its
-- unfiltered whole-graph population (K is the whole graph, that is the point) and
-- visibility is applied HERE, at the READ, never open-coded at a read site — exactly
-- the discipline `declEnvVisibleAt` already imposes for the ordinal axis.
--
-- the two conjuncts must stay separable, and that is the whole reason this is one
-- function taking `entryIsPublic` rather than a widened `declEnvVisibleAt`:
--   * the ORDINAL conjunct was described here as "transitional scaffolding for a
--     spec'd widening (§5 R2 / C4-I2 global candidacy)" that **A-3.6 deletes**.
--     it did not.  A-3.6 (#1558) split the predicate and flipped the INSTANCE
--     axis only (`ieCandidacyVisibleAt`); this conjunct reads `declEnvVisibleAt`,
--     which kept its body, so the ordinal conjunct here is LIVE and not scheduled
--     for deletion by any unit that currently exists.  The MEASURED paragraph two
--     down is why — it is this reader's own narrowing that made the split
--     necessary.  If a later unit does widen the name axis, it is that unit's
--     acceptance delta with that unit's fixtures.
--   * the PUBLICITY conjunct is NOT transitional either — it is the language's
--     export semantics, and under the target it MIGRATES TO R (§3 row L7), it does
--     not vanish.
-- The factoring is still what keeps the two answerable separately, and that is now
-- a permanent property rather than a deletion-safety measure: the two
-- `declEnvRowVisible` arms below read "own row ⇒ every decl, any other row ⇒ its
-- public projection", which is what R inherits, and neither conjunct can be widened
-- by editing the other.
--
-- WHY A predicate is needed at all (MEASURED on this tree, not argued): an unfiltered
-- whole-graph population used as the field-owner source turns a program that compiles
-- into `T-AMBIGUOUS-FIELD`, because a PRIVATE record in an unrelated module starts
-- voting in `resolveFieldByOwners`' ambiguity test.  That is a silent acceptance
-- NARROWING — false rejects on legal programs — and §5 R2's two enumerated exceptions
-- are both WIDENINGS carried by a could-not-pass-before fixture.  A narrowing cannot
-- meet that bar.
export
declEnvVisibleTo : Int -> Int -> Bool -> Bool
declEnvVisibleTo cur entryOrd entryIsPublic =
  declEnvVisibleAt cur entryOrd && (entryOrd == cur || entryIsPublic)

-- The decls of row [m] that a reader at ordinal [cur] may see — `declEnvVisibleTo`
-- applied at the only granularity at which its publicity conjunct is CONSTANT over a
-- row: the reader's own row (publicity irrelevant, every decl visible) versus any
-- earlier row (visible only in its public projection).  Both arms go through the
-- predicate; neither open-codes `<=` or a `pub` test.
--
-- ZERO ALLOCATION: both arms return a list the envelope already holds
-- (`demDecls` / the `demPubDecls` memo).  That is a MEASURED perf contract, not
-- style — see `importedCtorTypeDecls`, whose walk over this result runs once per
-- ctor-naming import member of every module, i.e. O(modules x universe).
-- Materialising a filtered pool here would convert that TIME term into an
-- ALLOCATION term of the same order, which is what the perf gate's `modules` shape
-- grades.
export
declEnvRowVisible : Int -> DeclEnvModule -> List Decl
declEnvRowVisible cur m
  | declEnvVisibleTo cur m.demOrd False = m.demDecls
  | declEnvVisibleTo cur m.demOrd True = m.demPubDecls
  | otherwise = []

-- ── doctests ─────────────────────────────────────────────────────────────
-- Both conjuncts, each shown to be separately load-bearing: a LATER row is invisible
-- whatever its publicity (ordinal conjunct), and an EARLIER row is visible only
-- publicly while the reader's OWN row is visible privately (publicity conjunct).
-- > declEnvVisibleTo 1 2 True
-- False
-- > declEnvVisibleTo 1 0 False
-- False
-- > declEnvVisibleTo 1 0 True
-- True
-- > declEnvVisibleTo 1 1 False
-- True

-- the population half, and it mirrors `registerData`/`registerVariants` ARM FOR
-- ARM.  `registerData` unwraps `DAttrib`, so this mirror unwraps with it.  Keeping the
-- mirror is the whole discipline here: the moment the two disagree, an attributed decl
-- means one thing where it is declared and another to an importer.
--
-- only the own-row arm of `declEnvRowKindEntries` reaches this today.  The
-- cross-module projection goes through `kindPublicDataDecl`, which still has no
-- `DAttrib` arm, so an attributed PUBLIC data decl is still invisible to importers'
-- kind entries.  That is the #1063-family export gap, a different question from
-- #1228/#1586, and it is deliberately NOT touched here.
export
declEnvKindEntries : GraphCtx -> List Decl -> List (TabKey, List Kind)
declEnvKindEntries gctx [] = []
declEnvKindEntries gctx ((DAttrib _ d) :: rest) =
  declEnvKindEntries gctx (d :: rest)
declEnvKindEntries gctx ((DData { dataName = n, dataParams = ps, dataParamKinds = ks, dataOrigin = o }) :: rest) =
  (tyTabKey o n, declParamKinds gctx ps ks) :: declEnvKindEntries gctx rest
declEnvKindEntries gctx ((DNewtype { newtypeName = n, newtypeParams = ps, newtypeParamKinds = ks, newtypeOrigin = o }) :: rest) =
  (tyTabKey o n, declParamKinds gctx ps ks) :: declEnvKindEntries gctx rest
-- #2121: an alias head's declared kinds travel cross-module exactly like a
-- data head's (mirrors `registerData`'s `DTypeAlias` arm).
declEnvKindEntries gctx ((DTypeAlias { tyAliasName = n, tyAliasParams = ps, tyAliasParamKinds = ks, tyAliasOrigin = o }) :: rest) =
  (tyTabKey o n, declParamKinds gctx ps ks) :: declEnvKindEntries gctx rest
declEnvKindEntries gctx (_ :: rest) = declEnvKindEntries gctx rest

export
declEnvReachFrom : OrdMap (List String) ->
  List String ->
  OrdMap Unit ->
  OrdMap Unit
declEnvReachFrom _ [] seen = seen
declEnvReachFrom edges (mid :: rest) seen =
  let fresh =
    filterList (d => not (omHasKey d seen)) (declEnvDirectImports edges mid)
  declEnvReachFrom edges (fresh ++ rest) (declEnvMarkReached fresh seen)

declEnvMarkReached : List String -> OrdMap Unit -> OrdMap Unit
declEnvMarkReached [] seen = seen
declEnvMarkReached (d :: rest) seen =
  declEnvMarkReached rest (omInsert d () seen)

-- The module ids row [mid] imports directly.  `useModuleId` is the same path→id
-- mapping every other cross-module table in this file keys on, so a hit here is a hit
-- in `deOwnerModules`.
declEnvDirectImports : OrdMap (List String) -> String -> List String
declEnvDirectImports edges mid = optionOr [] (omLookup mid edges)

-- the blank line above is load-BEARING — do not close the gap.  A doctest's
-- EXPECTED OUTPUT runs to the end of the contiguous comment run, so without it
-- this banner is absorbed into A-3.2a's last doctest's expected value and that
-- doctest FAILS with `expected: True / actual: True` plus this text spliced in.
-- MEASURED when A-3.2a and A-3.4 first met in one tree: 13/14, and neither PR
-- could have seen it alone — no conflict marker, two adjacent comment blocks,
-- each correct in isolation.
-- ═══ #1112 A-3.4: THE `IE` REGISTRY — IE-BLOCK-BEGIN ════════════════════════════
-- the two banner lines bounding this block are read by A GATE.  Check 4
-- of `test/registry_keying_ratchet.sh` (which runs inside
-- `test/typecheck_compiler_source.sh`, inside the required `soundness` job)
-- extracts exactly the text between them and FAILS if the extraction is EMPTY —
-- so renaming or deleting either banner is loud, never a green that examined
-- nothing.  Do not reword them without editing that check.
--
-- what this is.  Stage K's `IE`: one registry answering "what impls exist",
-- replacing the three separate answers enumerated in
-- `compiler/TYPECHECK-TARGET-ARCHITECTURE.md` §9.6.  Built once, whole-graph,
-- inside `buildDeclEnvs`.  This said "every read filters through
-- `declEnvVisibleAt` (the ONE ordinal predicate, whose body A-3.6 deletes)".
-- Since A-3.6 (#1558) `IE`'s two reads went through TWO predicates, and under
-- RUN-055 (SA-3) they are back on ONE: both the candidacy read (`ieUniverseAt` →
-- `ieSnapAt`) and the decl-time existence read (`ieRowsVisibleAt`) go through
-- `ieCandidacyVisibleAt` and are GRAPH-GLOBAL — that is C4/I2 on the first and the
-- ruled agreement of diagnostic-with-engine on the second.  `declEnvVisibleAt` is
-- now the NAME axis alone and has no `IE` reader.  See all three headers.
--
-- THE CONSTRAINT (§9.3), mechanically enforced by check 4 ABOVE.  `IE` is
-- keyed by IMPL IDENTITY.  An interface's default-method arm is a property of the
-- INTERFACE declaration (`CE`, A-3a) and the emit-side method/default *word*
-- namespace belongs to B-2 (#1113).  NO `IE` key component may be A METHOD NAME:
-- a `(method, tag)`-keyed default registry here would rebuild #1265 in the new
-- substrate, since that pair is exactly the key #1265 is the first-match over.
-- A method name enters an `IE` row only as PAYLOAD (`ieMethods`).
--
-- `IE` is read, and it decides acceptance: "the registry exists" and "the registry
-- answers" are the two halves the arc's progress metric separates.
-- The Module arm's obligation universe — the table `checkCallObligationsU` asks
-- "does an impl exist for this goal", i.e. the table behind every `No impl of X
-- for Y` on the multi-module path — is a projection of `IE` at the reader's
-- ordinal, through the ONE accessor `ieUniverseAt`; no separate accumulator holds it.
--
-- what is still not read: `ieInst`/`InstRef` and `ieMethods`, both payload for
-- A-3.7 (coherence) and B-2. The standalone decl-list helpers still build their own
-- `buildImplUniverse` over its whole program — that shim retires at E-4, not here.

export
instRefMid : InstRef -> String
instRefMid (InstRef m _ _) = m

export
instRefSeq : InstRef -> Int
instRefSeq (InstRef _ _ s) = s

export
ieRowOrd : ImplRow -> Int
ieRowOrd (ImplRow o _ _ _ _ _ _) = o

export
ieRowInst : ImplRow -> InstRef
ieRowInst (ImplRow _ i _ _ _ _ _) = i

export
ieRowTriple : ImplRow -> (IfaceRef, List Ty, List Require)
ieRowTriple (ImplRow _ _ ir tys reqs _ _) = (ir, tys, reqs)

export
ieRowIface : ImplRow -> IfaceRef
ieRowIface (ImplRow _ _ ir _ _ _ _) = ir

-- The impl's own explicit/synthesized method table (§1112 A-3's disposition
-- producer reads this to decide `Supplied` vs `InheritedDefault` per slot).
export
ieRowMethodNames : ImplRow -> List String
ieRowMethodNames (ImplRow _ _ _ _ _ ms _) = ms

export
ieRowLoc : ImplRow -> Option Loc
ieRowLoc (ImplRow _ _ _ _ _ _ l) = l

emptyImplAcc : ImplAcc
emptyImplAcc = ImplAcc {
  iaEnv = emptyImplEnv,
  iaSeq = 0,
  iaSnaps = ieSnapZero,
}

buildImplEnv : List DeclEnvModule -> ImplEnv
buildImplEnv mods = implAccFinish (buildImplEnvGo mods emptyImplAcc)

-- `ieRows` and `ieUnivSnaps` are both built newest-first and reversed once here.
export
implAccFinish : ImplAcc -> ImplEnv
implAccFinish ia =
  let env = ia.iaEnv
  ImplEnv { env |
    ieRows = reverseL env.ieRows,
    ieUnivSnaps = reverseL (fst ia.iaSnaps),
  }

export
buildImplEnvGo : List DeclEnvModule -> ImplAcc -> ImplAcc
buildImplEnvGo [] ia = ia
buildImplEnvGo (m :: rest) ia =
  let rows = implRowsOf m.demId m.demOrd ia.iaSeq (implDeclFacts m.demDecls)
  buildImplEnvGo rest ImplAcc {
    iaEnv = ieAddRows rows ia.iaEnv,
    iaSeq = ia.iaSeq + listLen rows,
    iaSnaps = ieSnapStep rows ia.iaSnaps,
  }

ieSnapZero : (List (Int, ImplUniverse), ImplUniverse)
ieSnapZero = ([], emptyImplUniverse)

-- ONE same-ordinal run of rows into the accumulator (newest entry first, plus the
-- running universe).  The run contributes a single entry taken after every row in
-- it; an EMPTY run contributes none, which is what keeps a module declaring no
-- impl out of the snapshot list.  The graph builder folds module by module through
-- this same step -- a module's rows all carry its ordinal -- so a resumed prefix
-- and a whole-list build are the same function of the same rows.
ieSnapStep : List ImplRow ->
  (List (Int, ImplUniverse), ImplUniverse) ->
  (List (Int, ImplUniverse), ImplUniverse)
ieSnapStep [] acc = acc
ieSnapStep (r :: rest) (snaps, univ) =
  let univ2 = growImplUniverse (map ieRowTriple (r :: rest)) univ
  ((ieRowOrd r, univ2) :: snaps, univ2)

-- LOCKSTEP WITH `implDeclsWithReqs` / `implDeclWithReqs`: same `DAttrib` unwrap,
-- same single-`DImpl` arm, same order.  The two are kept separate rather than one
-- being defined via the other because `implDeclsWithReqs` runs per module on the
-- hot Module path and `check` is GC-bound — deriving it from this 4-tuple form
-- would allocate a method-name list per impl on every compile.  The agreement is
-- not left to the comment: A-3.4 PR1's `ieShadowCompare` measured it per module
-- slice, and PR2 measured it again at the whole-prefix level over the compiler's
-- own graph and 193 multi-module fixture projects before flipping the reader.  Both
-- instruments are now deleted, so the standing defence is the flip itself: a
-- divergence between these two walks is no longer a silent second table, it is the
-- obligation universe being wrong, which the differential gates grade directly.
--
-- The method-name list is also the post-selection route-word collision witness:
-- rowRouteKey whether any method this exact row implements is
-- shared by another row at the same head.  It deliberately does not add inherited
-- cross-module defaults, whose RDict routing is a separate backend contract.
--
-- The head is taken as the decl holds it, already in alias normal form
-- (`stampGraphDecls`); normalising here as well would give the engines, which
-- read the same `DImpl`, a different head from the one selection chose.
implDeclFacts : List Decl ->
  List (IfaceRef, List Ty, List Require, List String, Option Loc)
implDeclFacts prog = flatMap implDeclFact prog

implDeclFact : Decl ->
  List (IfaceRef, List Ty, List Require, List String, Option Loc)
implDeclFact (DAttrib _ d) = implDeclFact d
implDeclFact (DImpl { iface, tys, reqs, methods, implOrigin, implIfaceLoc, ... }) = [
  (
    IfaceRef { irName = iface, irOrigin = implOrigin },
    tys,
    reqs,
    map implMethodNameTc methods,
    implIfaceLoc,
  ),
]
implDeclFact _ = []

implRowsOf : String ->
  Int ->
  Int ->
  List (IfaceRef, List Ty, List Require, List String, Option Loc) ->
  List ImplRow
implRowsOf _ _ _ [] = []
implRowsOf mid ord seq ((iface, tys, reqs, ms, loc) :: rest) =
  ImplRow ord (InstRef mid ord seq) iface tys reqs ms loc
    :: implRowsOf mid ord (seq + 1) rest

-- UPDATES `ieRows` and the three index buckets. does **NOT** UPDATE `ieUnivSnaps`.
-- Read that as the design-law hazard it is, not as a note.
--
-- `ieUnivSnaps` is a SECOND REPRESENTATION of `ieRows` — the per-ordinal prefix
-- universes `ieUniverseAt` selects from — and it is maintained in exactly ONE place,
-- `buildImplEnv`, AFTER this fold has finished. Inserting into an already-built
-- `ImplEnv` therefore leaves a snapshot table that silently disagrees with the rows,
-- and because `ieUniverseAt` reads the SNAPSHOT, the consequence is a wrong
-- obligation universe with no diagnostic: an impl that exists is invisible to
-- dispatch, or a retired one still answers. That is a silent-wrongness shape.
--
-- It is INERT TODAY only because there is exactly one construction site
-- (`buildImplEnv`, called once per driver from `buildDeclEnvs`) — derive that before
-- trusting it: `grep -n 'ieAddRows\|ieInsertRow' compiler/types/typecheck.mdk`.
--
-- and it is this unit'S own design law, one field over. A-3.4 PR2 deleted three
-- `CrossRun` fields precisely to stop two structures answering "what impls exist"
-- (law L1), and this pair is that same shape at a smaller scale. It is accepted here
-- because the alternative — folding a snapshot per insert — is the O(modules x impls)
-- quadratic this unit was reddened by `diff_compiler_perf_scaling.sh` for and fixed.
-- So: if you need to insert into a built `ImplEnv`, RE-DERIVE the snapshots
-- (`ieUnivSnaps = ieBuildSnaps env.ieRows`) once at the end of your fold, exactly as
-- `buildImplEnv` does. Do not add a second maintainer, and do not insert without one.
--
-- AND SINCE #2146 that is two steps, not one — `REVERSE FIRST`.  `ieInsertRow`
-- now PREPENDS (`r :: env.ieRows`), so a fold over it leaves `ieRows` in reverse
-- build order; `buildImplEnv` restores it with one `reverseL` and only then calls
-- `ieBuildSnaps`.  A caller that re-derives off the un-reversed rows builds
-- snapshots whose per-ordinal prefixes are the SUFFIXES — silently wrong in
-- exactly the direction this whole note is about, and worse than not re-deriving
-- at all.  The full sequence, mirroring `buildImplEnv` line for line:
--
--     let env2 = ImplEnv { env | ieRows = reverseL env.ieRows }
--     ImplEnv { env2 | ieUnivSnaps = ieBuildSnaps env2.ieRows }
--
-- INERT TODAY (this function still has exactly one caller, `buildImplEnvGo`,
-- which is inside `buildImplEnv` and does both steps) — written down anyway,
-- because it is the instruction the NEXT caller reads, and the reverse is the
-- half a reader of the old two-line version would not know to add.
ieAddRows : List ImplRow -> ImplEnv -> ImplEnv
ieAddRows [] env = env
ieAddRows (r :: rest) env = ieAddRows rest (ieInsertRow r env)

-- The index insert, mirroring `insertUnivImplAt` arm-for-arm: the identity key plus
-- the bare compatibility leg (`oblIfaceKeys`), concrete head → the `[ifk, hd]`
-- bucket + the tag set, headless → the iface's headless bucket.  `mregAppendK`, not
-- `mregAddK`: within one bucket the FORWARD declaration order is semantic.
--
-- ONCE PER `oblIfaceKeys` ELEMENT, i.e. twice per row for every origin-bearing
-- interface.  ONLY interface-keyed indexes belong here; anything else DOUBLE-FILES.
-- The once-per-row seam is `ieFileRow` — read its header before adding a bucket.
--
-- `env.ieRows` is consed (`r :: env.ieRows`), never appended per row, which would be
-- O(rows²) over the build (`compiler/AGENTS.md`'s quadratic shape); `buildImplEnv`
-- does the one `reverseL` at the end, which restores build order (#2146).
-- does not maintain `ieUnivSnaps` — the table `ieUniverseAt` actually reads.  Only
-- `buildImplEnv` derives that, after all inserts are done.  Full hazard, and what to do
-- if you need to insert into a built `ImplEnv`, at `ieAddRows` above.
ieInsertRow : ImplRow -> ImplEnv -> ImplEnv
ieInsertRow r env = ieFileRow r { env | ieRows = r :: env.ieRows }

-- ── ARCH B-2.1-a3 (Stage B sprint): the one once-PER-row filing seam ──────────
-- EVERY PER-row index goes here, and the reason is A CORRECTNESS CONSTRAINT,
-- NOT TIDINESS.  `ieInsertRowAt` below is entered ONCE PER `oblIfaceKeys`
-- ELEMENT — i.e. TWICE for every row whose interface carries an origin, which is
-- every row but an `OriginUnresolved` one (`oblIfaceKeys`: identity key + bare
-- compatibility leg).  An index keyed by anything OTHER than the interface, filed
-- there, DOUBLE-FILES: the bucket inflates, and every count, `min⊑` and
-- declaration-order merge taken over it is silently wrong.  That is why
-- `ieByHead` — keyed by HEAD, ACROSS interfaces — is filed here and not there.
-- The doctests at `ieHeadProbeEnv` assert exactly-once and are fail-capable in
-- that direction (a filing moved into `ieInsertRowAt` doubles their expected
-- lists).
--
-- and it exists because there are **TWO** ONCE-PER-ROW PATHS.  `ieInsertRow`
-- (Module, via `ieAddRows`) and `ieIndexRows` (Flat, B-2.1-a2's index-only half)
-- both spelled `ieInsertRowKeys (oblIfaceKeys ir) r` independently, so a new index
-- added to one was silently absent from the other — the `evalModulesWith` /
-- `cevalModules` divergence shape `AGENTS.md` records ("a fix landed in one
-- parallel driver and left the other broken for months").  With this seam the two
-- arms cannot drift: the ONLY per-row difference left between them is the
-- `ieRows` append, which is exactly the difference that is supposed to be there.
ieFileRow : ImplRow -> ImplEnv -> ImplEnv
ieFileRow (r@(ImplRow _ _ ir _ _ _ _)) env =
  ieInsertRowKeys (oblIfaceKeys ir) r (ieFileRowByHead r env)

-- The HEAD-keyed, interface-BLIND index: every row filed under its receiver head's
-- bucket, or the headless bucket for a fully-general `impl C a`.  This is
-- `KeyBuckets`' OWN partition (`bucketKeyEntriesFrom` → `headBucketRender`) over
-- `IE`'s rows, and the key is minted by the SAME `headBucketKey` both tables now
-- share, so the two cannot drift in keying — only in population, which is the
-- whole point: `KeyBuckets` reaches its reader as a TOPOLOGICAL PREFIX
-- (`universeKeyBucketsRef` / `stampKeyTable`), while this is GRAPH-GLOBAL.
--
-- why an index at all, measured: the method-keyed selection leg (then
-- `matchedEntry` → `matchingEntries` → `candidateBucket`, all three deleted by
-- B-2.1-d) is *the checker's
-- hottest selector*, and answering it graph-globally by SCANNING `ieRows` cost
-- `check-self` 21.5 s -> 25.1 s (+17%) — an O(rows) scan per goal, the exact
-- `List`-as-a-map shape `compiler/AGENTS.md` forbids (RUN-B-023,
-- which is why this bite exists and precedes the repoint).
--
-- ASCENDING BY `instRefSeq`, by construction, and that is load-BEARING.  Both
-- filing paths fold rows in forward order (`buildImplEnvGo` threads one whole-graph
-- `seq` across modules in ordinal order; `buildFlatImplEnv` folds one forward list),
-- and `mregAppendK` APPENDS — so every bucket is in graph-global forward
-- declaration order.  That is `mergeByDeclIdx`'s documented ascending precondition,
-- which `universeKeyBucketsRef` VIOLATED (`bucketKeyEntriesFrom` restarts at 0 per
-- module, so its indices duplicated and each module's slice was prepended) until ARCH
-- B-2.1-d deleted it, and it is
-- the property RUN-B-007's declaration-index ruling rests on.  A prepend +
-- reverse-at-finalize would file in O(1) instead of `mregAppendK`'s O(bucket), and
-- it is deliberately NOT taken: it makes the ascending invariant true only AFTER a
-- finalize step, which is precisely the second-maintainer hazard `ieAddRows`'s
-- header forbids for `ieUnivSnaps` ("do not add a second maintainer, and do not
-- insert without one").  The cost is per-BUCKET, not per-population — this is not
-- `ieRows`' `++ [r]` — and it is measured, not asserted (B-2.1-a3).
ieFileRowByHead : ImplRow -> ImplEnv -> ImplEnv
ieFileRowByHead (r@(ImplRow _ _ _ tys _ _ _)) env = ImplEnv { env |
  ieByHead = mregAppendK (headBucketKey (univReceiverTag tys)) r env.ieByHead,
}

-- THE `IE` HEAD-bucket read accessor — the successor of `bucketOfHead`, the
-- `KeyBuckets` lookup B-2.1-d deleted.  Goal side and impl side project through the SAME `headBucketKey`,
-- so a lookup cannot silently miss the bucket its rows were filed under (which is
-- what `dispHeadTab`'s derivation is about).  Returns the rows ASCENDING by
-- `instRefSeq` — see `ieFileRowByHead`; a consumer feeding `mergeByDeclIdx` depends
-- on that and must not re-order them.
--
-- no production caller yet, deliberately: `B-2.1-a3` is additive and
-- behaviour-neutral, and `B-2.1-b2` is the repoint that consumes it.  It is bound
-- here rather than left for that bite to open-code, for the reason `ieUniverseAt`
-- gives: one read site is one place to re-scope.
export
ieHeadRows : Option HeadKey -> ImplEnv -> List ImplRow
ieHeadRows hd env = mregLookupK (headBucketKey hd) env.ieByHead

ieInsertRowKeys : List TabKey -> ImplRow -> ImplEnv -> ImplEnv
ieInsertRowKeys [] _ env = env
ieInsertRowKeys (ifk :: rest) r env =
  ieInsertRowKeys rest r (ieInsertRowAt ifk r env)

ieInsertRowAt : TabKey -> ImplRow -> ImplEnv -> ImplEnv
ieInsertRowAt ifk (r@(ImplRow _ _ _ tys _ _ _)) env = match univReceiverTag tys
  Some hk =>
    -- This writer and `insertUnivImplAt` move together.
    ImplEnv { env |
      ieConcrete =
        mregAppendK (regKeyNTab [ifk, dispHeadTab hk]) r env.ieConcrete,
    }
  None => ImplEnv { env |
    ieHeadless = mregAppendK (regKeyOfTab ifk) r env.ieHeadless,
  }

-- THE `IE` *UNIVERSE* READ ACCESSOR.  Every consumer that wants an
-- `ImplUniverse` goes through here.  Open-coding `<=` at a read site is the one
-- thing this unit must not do.
--
-- this is no longer the only `IE` READ, and it is no longer ordinal-filtered.
-- There are TWO `IE` reads and they answer different questions — this one (via
-- `ieSnapAt`) selects a candidacy UNIVERSE; `ieRowsVisibleAt` below selects rows for
-- a decl-time existence check.  They shared a predicate before A-3.6 (#1558), which
-- SPLIT it by owner ruling and moved this one alone to `ieCandidacyVisibleAt`; under
-- RUN-055 (SA-3) the existence read followed, so the two share a predicate again —
-- `ieCandidacyVisibleAt`, the WIDE one.  They are still two functions answering two
-- questions over two shapes (`ImplUniverse` vs `ImplRow`), and re-scoping either one
-- is still a one-line, one-name change.  "One body to delete" was never the
-- invariant that mattered; "no read site open-codes `<=`" is, and it still holds.  DERIVE the current set rather than trusting this
-- sentence: `grep -n 'declEnvVisibleAt\|ieCandidacyVisibleAt' compiler/types/typecheck.mdk`
-- and separate code from commentary; the ratchet's `declEnvsRef` row has been measured
-- wrong on this count in both directions (RUN-007/RUN-013).
--
-- The snapshots this SELECTS from are built by `insertUnivImpl` — the SAME writer
-- `growImplUniverse` (and so the retired accumulator) uses — so the two cannot drift
-- in key minting, and the equality reduces to population and order (§9.5's algebra +
-- `DL`) — which A-3.4 PR1's `ieShadowCompare` measured per module slice, and which
-- PR2 re-measured at the whole-prefix level, at the read site, before flipping onto
-- this function.
--
-- it selects, it does not rebuild, and that is A MEASURED REQUIREMENT.  The first
-- cut folded the visible prefix on every read — once per module — and put back the
-- exact O(modules x impls) quadratic #154 PR-C removed, reddening
-- `diff_compiler_perf_scaling.sh`'s `modules` shape at r2=3.35 against a documented
-- FLAT ~2.0.  See `ieUnivSnaps`.  A future reader "simplifying" this back into a fold
-- over `ieRows` re-introduces that; the gate will catch it, but the comment is cheaper.
--
-- the production callers (A-3.4 PR2) ARE `checkBodyImpl`'s Module arm — the
-- end-of-body obligation universe and #1549's `residualUnivRef`, which share ONE
-- binding (`moduleImplUniv`). Everything an obligation check on the multi-module path
-- knows about which impls exist comes through here. Add a caller only if it genuinely
-- needs the same ordinal-filtered answer — and never open-code the filter to get it.
export
ieUniverseAt : Int -> ImplEnv -> ImplUniverse
ieUniverseAt cur env = ieSnapAt cur env.ieUnivSnaps emptyImplUniverse

-- Walk the ordinal-ordered snapshots and keep the LAST admitted one.  This is THE
-- instance-candidacy read, and since A-3.6 (#1558) it goes through
-- `ieCandidacyVisibleAt` — not `declEnvVisibleAt`, which kept its ordinal body for
-- the name axis when the predicate split (see both headers).  The predicate is `True`,
-- so this selects the FINAL snapshot — the whole graph — which is C4/I2's global
-- instance environment reached without changing the shape of the walk.
--
-- it is still A walk, and that is not an oversight.  A constant predicate makes
-- `last` the obvious "simplification", and the two are equal only while
-- `ieUnivSnaps` is ordinal-ordered and non-empty-tailed.  The walk keeps this
-- function's shape identical to its pre-flip self, so the flip's diff is one
-- predicate name and the acceptance delta is attributable to that alone; and it
-- leaves one line to change if candidacy is ever scoped again.  Allocates nothing.
ieSnapAt : Int -> List (Int, ImplUniverse) -> ImplUniverse -> ImplUniverse
ieSnapAt _ [] acc = acc
ieSnapAt cur ((o, u) :: rest) acc
  | ieCandidacyVisibleAt cur o = ieSnapAt cur rest u
  | otherwise = acc

-- #1557 A-3.5b: the ROW-SET read for the decl-time EXISTENCE check — built as the
-- peer of `CE`'s `ceRowsVisibleAt` on the NAME/declaration axis.
-- it is no longer on that axis.  Two retractions, in order, because the second
-- only makes sense against the first: A-3.5b's original claim that this read is
-- "routed through the SAME ONE predicate so A-3.6 still has a single body to
-- delete" died when A-3.6 (#1558) SPLIT the predicate instead of deleting it; the
-- successor claim — that this read "stayed on `declEnvVisibleAt`", because a
-- decl-time EXISTENCE query is not I5's subject — is retired by ⚖️ OWNER RULING
-- (Val, 2026-08-12, RUN-055, finding SA-3).  The two-scope
-- arrangement was measured to make the diagnostic contradict the engine inside ONE
-- program (an `impl Sup T` in a topologically LATER module dispatches while this
-- check calls it missing), so this read now takes `ieCandidacyVisibleAt` — the same
-- graph-global predicate `ieSnapAt` takes.  Both `IE` reads are back on ONE
-- predicate, but by widening this one, not by narrowing that one.
-- the name stays `…VisibleAt`, and the parameter stays.  Same reason
-- `ieCandidacyVisibleAt` keeps its two unused arguments: the flip's whole diff is
-- one predicate name, so the acceptance delta is attributable to that alone, and
-- one line changes back if super-existence is ever re-scoped.  `cur` is still LIVE
-- in this check's other half — `checkImplSuperContexts` resolves the interface and
-- its supers through `ceLookupAt … cur`, which is name-scoped and did NOT move.
-- what did not move either, and must not: this returns `ImplRow`s, not an
-- `ImplUniverse`.  `ieUniverseAt` above answers "what does the obligation channel
-- know about impls here"; this answers "which impl DECLARATIONS exist", and its
-- consumer matches AST `Ty`s with `superHeadCovers` where an `ImplUniverse` holds
-- `Mono`s matched by `matchStep`.  Routing this through `ieUniverseAt` to reach the
-- same scope would swap the MATCHER as well as the table — a second, unbudgeted
-- acceptance delta riding on the ruled one.  Widen the PREDICATE, never the table.
-- and it reads `ieRows`, never the buckets — see `ieRowsAll` for why the bucket
-- walk rebuilds #1438 in this substrate.
--
-- perf: this is O(rows) per call and its caller runs per (impl x super).  Bind it
-- ONCE per whole-module check and thread the list; calling it in `superRowExists`
-- would be O(user impls x supers x all impls) — the same class as A-3.4 PR2's first
-- cut, which `diff_compiler_perf_scaling.sh` caught at r2=3.35 on the `modules` shape
-- (see `ieUnivSnaps`).  `checkSuperImpls` is the one binding site; keep it that way.
export
ieRowsVisibleAt : Int -> ImplEnv -> List ImplRow
ieRowsVisibleAt cur env =
  filterList (r => ieCandidacyVisibleAt cur (ieRowOrd r)) env.ieRows

-- #1559 A-3.7: the POPULATION reads coherence takes — the whole graph, and one
-- module's OWN rows.  Peers of `CE`'s `ceRowsVisibleAt`/`ceRowsOwnedBy`, and they read
-- `ieRows` for the same reason the snapshot fold does.
--
-- READ `ieRows`.  never the buckets.  `ieConcrete`/`ieHeadless` already group rows
-- by (interface, head), so "iterate the buckets instead of the O(pairs) scan" is the
-- obvious optimization and it is a BUG: `ieInsertRow` indexes every row under
-- `oblIfaceKeys`, which is TWO keys — the identity key AND the bare-spelling
-- compatibility leg — so a bucket walk sees every row TWICE and, in the bare bucket,
-- pairs impls of two DIFFERENT interfaces that merely share a spelling.  That
-- rebuilds #1438's false reject (the one `cohSameIface` was added to fix) inside the
-- new substrate, and double-reports every pair besides.  The collapse is asserted
-- live by this block's own doctests — the bare bucket reads 2, deliberately.  Only
-- `ieRows` is keyless, and only a keyless population can be scanned pairwise.
export
ieRowsAll : ImplEnv -> List ImplRow
ieRowsAll env = env.ieRows

-- `ieRowOrd r == cur`, NOT `declEnvVisibleAt cur (ieRowOrd r)`.  The latter is the
-- ordinal PREFIX — every earlier module too — which is a different set and the wrong
-- one for a per-module sweep; it would also hand `declEnvVisibleAt` another reader,
-- which A-3.6 (#1558) is counting.  `ceRowsOwnedBy` writes `== cur` for the identical
-- reason; keep the two spellings the same.
export
ieRowsOwnedBy : Int -> ImplEnv -> List ImplRow
ieRowsOwnedBy cur env = filterList (r => ieRowOrd r == cur) env.ieRows

-- ═══ #1112 A-3.4: IE-BLOCK-END ═════════════════════════════════════════════════

-- ═══ #1519 A-3.3: THE `CE` REGISTRY — CE-BLOCK-BEGIN (its data declarations are in compiler/types/tc_types.mdk) ═══

ceRowKey : CeRow -> RegKey
ceRowKey (CeRow k _ _ _ _ _ _ _ _) = k

export
ceRowOrd : CeRow -> Int
ceRowOrd (CeRow _ o _ _ _ _ _ _ _) = o

export
ceRowIface : CeRow -> IfaceRef
ceRowIface (CeRow _ _ ir _ _ _ _ _ _) = ir

export
ceRowTyparams : CeRow -> List String
ceRowTyparams (CeRow _ _ _ tp _ _ _ _ _) = tp

export
ceRowMethods : CeRow -> List (String, Ty, List (String, List Kind))
ceRowMethods (CeRow _ _ _ _ ms _ _ _ _) = ms

export
ceRowSupers : CeRow -> List Super
ceRowSupers (CeRow _ _ _ _ _ sups _ _ _) = sups

export
ceRowParamKinds : CeRow -> List (List Kind)
ceRowParamKinds (CeRow _ _ _ _ _ _ pk _ _) = pk

export
ceRowRequired : CeRow -> List String
ceRowRequired (CeRow _ _ _ _ _ _ _ req _) = req

export
ceRowLoc : CeRow -> Option Loc
ceRowLoc (CeRow _ _ _ _ _ _ _ _ l) = l

export
classEnvFinish : ClassEnv -> ClassEnv
classEnvFinish env = ClassEnv { env | ceRows = reverseL env.ceRows }

export
buildClassEnvGo : GraphCtx -> List DeclEnvModule -> ClassEnv -> ClassEnv
buildClassEnvGo gctx [] env = env
buildClassEnvGo gctx (m :: rest) env =
  let rows = classEnvRowsOf gctx m.demOrd (classEnvDeclFacts m.demDecls)
  buildClassEnvGo gctx rest (ceAddRows rows env)

-- One interface decl's raw facts: name, typarams, methods, supers, identity.
classEnvDeclFacts : List Decl ->
  List (String, List String, List (Option KindAnn), List IfaceMethod, List Super, TyConOrigin, Option Loc)
classEnvDeclFacts prog = flatMap classEnvDeclFact prog

classEnvDeclFact : Decl ->
  List (String, List String, List (Option KindAnn), List IfaceMethod, List Super, TyConOrigin, Option Loc)
classEnvDeclFact (DAttrib _ d) = classEnvDeclFact d
classEnvDeclFact (DInterface { name, typarams, typaramKinds, supers, methods, ifaceOrigin, ifaceNameLoc, ... }) =
  [(name, typarams, typaramKinds, methods, supers, ifaceOrigin, ifaceNameLoc)]
classEnvDeclFact _ = []

classEnvRowsOf : GraphCtx ->
  Int ->
  List (String, List String, List (Option KindAnn), List IfaceMethod, List Super, TyConOrigin, Option Loc) ->
  List CeRow
classEnvRowsOf gctx _ [] = []
classEnvRowsOf gctx ord ((name, typarams, kinds, methods, supers, o, loc) :: rest) =
  let scope = declGradedScope gctx typarams kinds methods
  let row =
    CeRow
      (regKeyOfTab (ifaceTabKey o name))
      ord
      IfaceRef {
        irName = name,
        irOrigin = o,
      }
      typarams
      (map (ceMethodOf scope) methods)
      supers
      (ifaceParamKindsDeclAll gctx typarams kinds methods)
      (requiredMethodNames methods)
      loc
  row :: classEnvRowsOf gctx ord rest

-- every parameter's RESOLVED slot kinds, positional with [typarams].
export
ifaceParamKindsDeclAll : GraphCtx ->
  List String ->
  List (Option KindAnn) ->
  List IfaceMethod ->
  List (List Kind)
ifaceParamKindsDeclAll gctx [] _ _ = []
ifaceParamKindsDeclAll gctx (p :: ps) [] methods =
  ifaceParamKindsDeclAll gctx (p :: ps) [None] methods
ifaceParamKindsDeclAll gctx (p :: ps) (a :: anns) methods =
  ifaceParamKindsDecl gctx a p methods
    :: ifaceParamKindsDeclAll gctx ps anns methods

ceMethodOf : List (String, List Kind) ->
  IfaceMethod ->
  (String, Ty, List (String, List Kind))
ceMethodOf scope (IfaceMethod n ty _ _) = (n, ty, scope)

ceAddRows : List CeRow -> ClassEnv -> ClassEnv
ceAddRows [] env = env
ceAddRows (r :: rest) env = ceAddRows rest (ceInsertRow r env)

ceInsertRow : CeRow -> ClassEnv -> ClassEnv
ceInsertRow r env = ClassEnv { env |
  ceRows = r :: env.ceRows,
  ceByKey = regInsertK (ceRowKey r) r env.ceByKey,
}

-- THE ONE `CE` READ ACCESSOR — the ordinal-filtered lookup routed through
-- `declEnvVisibleAt`.  It is the ordinal filter's LAST substrate: `IE`'s two
-- reads (`ieUniverseAt`/`ieSnapAt` under A-3.6, `ieRowsVisibleAt` under RUN-055)
-- have both moved to `ieCandidacyVisibleAt`, so `CE` and the name tables are what
-- keeps this predicate live.  Looks up by IDENTITY rather than collecting a
-- candidate set, per the shape argued at `ClassEnv` above.
--
-- This said "no caller today — construction only, per this unit's bar" while it was
-- #1519's. Production callers include `ceSlotKindsAt` (graded impl-head kinds),
-- `ifaceDfsCycleOneSuper` following a superinterface edge by identity, and
-- `ceMethodTyAt` checking impl bodies; `ceRowsVisibleAt`/`ceRowsOwnedBy` are its population peers on the
-- same ordinal predicate.  Anything reaching `ceByKey` directly instead of through
-- here would bypass `declEnvVisibleAt` and silently widen the `CE` axis — which
-- A-3.6 deliberately did NOT widen, so there is now no unit such a bypass could be
-- mistaken for finishing early.
export
ceLookupAt : RegKey -> Int -> ClassEnv -> Option CeRow
ceLookupAt key cur env = match regLookupK key env.ceByKey
  None => None
  Some r => if declEnvVisibleAt cur (ceRowOrd r) then Some r else None

-- An interface named by a RESOLVED reference: the reference's origin was bound by
-- resolve at a site that could see the declaration, so no ordinal filter applies.
-- Reached from the superclass closure, whose seeds are resolved predicate
-- interfaces and whose edges are `Super` occurrences stamped by resolve.
export
ceLookupGraph : RegKey -> ClassEnv -> Option CeRow
ceLookupGraph key env = regLookupK key env.ceByKey

-- ── #1557 A-3.5c: the ROW-SET reads, and why there are exactly two ─────────
-- `ceLookupAt` above answers "what does interface I mean here"; the two
-- relocated SCANS (W1 acyclicity, phantom methods) instead need a POPULATION,
-- and they need two DIFFERENT ones.  Both go through `declEnvVisibleAt` — the
-- name-axis ordinal predicate, per A-3.1's routing rule.  This used to end "so
-- A-3.6 still has a single body to delete"; A-3.6 (#1558) split the predicate
-- instead, and `CE` stayed on this one.  The routing rule is what survived and it
-- is why the split cost nothing here.
--
-- the two are not interchangeable, and picking the wrong one is a silent
-- widening rather than a loud one.  `ceRowsVisibleAt` is the reading module's
-- whole PREFIX (prelude + every earlier module + itself) — the population
-- `checkInterfaceCycles` needs.
-- `ceRowsOwnedBy` is the reading module ALONE — it reproduces what
-- `checkPhantomMethods` is handed today (`prog` on the Module arm, the
-- driver-staged USER decls on Flat).  Feeding the prefix to phantom-methods
-- would re-report every imported interface's phantom method once per importing
-- module; feeding own-only to the cycle scan would drop a cycle that closes
-- through an imported superinterface.
export
ceRowsVisibleAt : Int -> ClassEnv -> List CeRow
ceRowsVisibleAt cur env =
  filterList (r => declEnvVisibleAt cur (ceRowOrd r)) env.ceRows

export
ceRowsOwnedBy : Int -> ClassEnv -> List CeRow
ceRowsOwnedBy cur env = filterList (r => ceRowOrd r == cur) env.ceRows

-- Slot [i]'s declared kind signature for interface [key], at the reading
-- module's ordinal.  `ceRowParamKinds` is POSITIONAL with `ceTyparams` and
-- holds `ifaceParamKindsOf p methods` per slot — the SAME pure computation the
-- retired `ifaceParamKindsRef` writer (`registerIfaceParamKindsGo`) performed
-- per slot under an `ifaceSlotKey o iface i` key, so indexing this list by `i`
-- and looking that key up are the same question.  An out-of-range slot ABSTAINS
-- (`None`), which is the pre-existing miss policy: `checkGradedImplTys`' own
-- `_ => ()` arm already covered "an interface with fewer parameters than the
-- impl has type arguments".
export
ceSlotKindsAt : RegKey -> Int -> Int -> ClassEnv -> Option (List Kind)
ceSlotKindsAt key cur i env = match ceLookupAt key cur env
  None => None
  Some r => nthKindList i (ceRowParamKinds r)

-- #1557 A-3.5a: interface [key]'s REQUIRED-method names at the reading module's
-- ordinal — the relocation target of `universeIfaceRequiredRef`'s registry lookup
-- and of the retired bare first-match scan.
--
-- it must go through `ceLookupAt`, NOT `regLookupK … env.ceByKey`.  A second
-- open-coded path to `ceByKey` would bypass `declEnvVisibleAt` and silently widen
-- the `CE` axis.  This said "perform A-3.6's widening early, and A-3.6 depends on
-- there being exactly ONE ordinal predicate to split".  A-3.6 (#1558) has landed and
-- split the predicate; `CE` was NOT the axis it flipped, so the hazard is now an
-- unlicensed widening with no unit behind it at all.  `ceLookupAt`'s own header
-- states the rule.
--
-- MISS POLICY, and it is the unit's primary hazard: `None` means "no interface of
-- that IDENTITY is visible here", and `implCompletenessMsgsOf`'s `None` arm is `[]`
-- — i.e. a miss produces NO diagnostic, a silent accept.  That is a severity
-- INCREASE relative to a wrong-but-loud answer, so the population equality this
-- lookup rests on is what the unit owes evidence for, not the key (which does not
-- move on the Module arm — see `CeRow`'s field paragraph).
export
ceRequiredAt : RegKey -> Int -> ClassEnv -> Option (List String)
ceRequiredAt key cur env = map ceRowRequired (ceLookupAt key cur env)

nthKindList : Int -> List (List Kind) -> Option (List Kind)
nthKindList _ [] = None
nthKindList i (k :: rest)
  | i == 0 = Some k
  | otherwise = nthKindList (i - 1) rest

export
ceRowMethodNames : CeRow -> List String
ceRowMethodNames r = map ceMethodName (ceRowMethods r)

ceMethodName : (String, Ty, List (String, List Kind)) -> String
ceMethodName (n, _, _) = n

-- One `DeclEnvAcc` step per module row.  A pure function of the row's decls and the
-- dependency rows already folded, so it may resume from the prelude prefix.
export
methodEnvGo : GraphCtx -> List DeclEnvModule -> MethodEnv -> MethodEnv
methodEnvGo gctx [] env = env
methodEnvGo gctx (m :: rest) env = methodEnvGo gctx rest MethodEnv {
  meByName = methodRowsInto gctx m.demOrd m.demDecls env.meByName,
  meExports =
    omInsert
      m.demId
      (declMethodIdents m.demDecls
        ++ reexportedMethodIdents env.meExports m.demDecls)
      env.meExports,
  meIfaceExports =
    omInsert
      m.demId
      (ifaceMethodRows m.demDecls
        ++ reexportedIfaceMethods env.meIfaceExports m.demDecls)
      env.meIfaceExports,
}

methodRowsInto : GraphCtx ->
  Int ->
  List Decl ->
  OrdMap (List MethodRow) ->
  OrdMap (List MethodRow)
methodRowsInto gctx _ [] acc = acc
methodRowsInto gctx ord ((DAttrib _ d) :: rest) acc =
  methodRowsInto gctx ord rest (methodRowsInto gctx ord [d] acc)
methodRowsInto gctx ord ((DInterface { name, typarams, typaramKinds, methods, ifaceOrigin, ... }) :: rest) acc =
  methodRowsInto
    gctx
    ord
    rest
    (methodRowsOfIface
      ord
      IfaceRef { irName = name, irOrigin = ifaceOrigin }
      (regKeyOfTab (ifaceTabKey ifaceOrigin name))
      typarams
      (declGradedScope gctx typarams typaramKinds methods)
      methods
      acc)
methodRowsInto gctx ord (_ :: rest) acc = methodRowsInto gctx ord rest acc

-- A declaration with no module id mints no `Ident` and contributes no row (honest
-- absence, §8 I6.3).  Upsert BY IDENTITY: two interfaces of one module declaring the
-- same method name share one `Ident` (resolve rejects that module with
-- `R-DUPLICATE-IFACE-METHOD`), and the later declaration replaces the earlier, so a
-- spelling's row list holds DISTINCT declarations only.
methodRowsOfIface : Int ->
  IfaceRef ->
  RegKey ->
  List String ->
  List (String, List Kind) ->
  List IfaceMethod ->
  OrdMap (List MethodRow) ->
  OrdMap (List MethodRow)
methodRowsOfIface _ _ _ _ _ [] acc = acc
methodRowsOfIface ord iface key typarams scope ((IfaceMethod mname mty _ _) :: rest) acc =
  let acc2 = match mkIdent NsMethod iface.irOrigin mname
    None => acc
    Some ident =>
      let row = MethodRow {
        mrIdent = ident,
        mrOrd = ord,
        mrIface = key,
        mrEntry = (iface, typarams, mty, scope),
      }
      omInsert
        mname
        (filterList (r => r.mrIdent /= ident) (optionOr [] (omLookup mname acc))
          ++ [row])
        acc
  methodRowsOfIface ord iface key typarams scope rest acc2

export
methodRowById : Ident -> List MethodRow -> Option MethodRow
methodRowById _ [] = None
methodRowById ident (r :: rest)
  | r.mrIdent == ident = Some r
  | otherwise = methodRowById ident rest

-- The witness predicates (`anyUsePathBinds` and below) take a declaration as an
-- `(Ident, MethodEntry)` pair.
export
methodRowCand : MethodRow -> (Ident, MethodEntry)
methodRowCand r = (r.mrIdent, r.mrEntry)

export
methodRowIface : MethodRow -> IfaceRef
methodRowIface r = match r.mrEntry
  (iface, _, _, _) => iface

-- The implicit prelude's declaration of [n], when it is one of [cs].
export
methodPreludeRow : String -> List MethodRow -> Option MethodRow
methodPreludeRow n cs = do
  ident <- mkIdent NsMethod (OriginModule "core") n
  methodRowById ident cs

-- The graph's method-identity index (`meExports`); `omEmpty` before a driver built
-- `DeclEnvs`.
export
methodExportsIndex : GraphCtx -> Unit -> OrdMap (List (String, Ident))
methodExportsIndex gctx _ = gctx.declEnvsRef.value.deMethods.meExports

-- The DISCRIMINATING (receiver) typaram(s) of an interface — its FIRST typaram.
-- A multi-param interface (`FromEntries c e`) dispatches on its head/receiver
-- param `c`; the trailing `e` is a phantom element param that may appear in
-- argument types (`List e`) WITHOUT making the method arg-position dispatched.
-- Classifying by ALL typarams mis-routes `fromEntries : List e -> c` to its `List`
-- argument (an arg-tag site that has no `List` impl) instead of return-position
-- dispatch on `c`.  Single-param interfaces are unaffected (`take 1` is identity).
export
dispatchTyparams : List String -> List String
dispatchTyparams [] = []
dispatchTyparams (p :: _) = [p]

-- tvs maps a declared type-parameter name to its tyvar
-- named effect-tail variables in a signature (`<IO | e>` → ["e"]); the same
-- source name must share one effvar across the whole signature, linking a HOF's
-- callback effect to its result effect
export
effTailNames : Ty -> List String
effTailNames (TyVar _) = []
effTailNames (TyCon { tyConName = _ }) = []
effTailNames (TyApp a b) = effTailNames a ++ effTailNames b
effTailNames (TyFun a b) = effTailNames a ++ effTailNames b
effTailNames (TyTuple ts) = flatMap effTailNames ts
effTailNames (TyEffect _ tail t) = tail ++ effTailNames t
effTailNames (TyConstrained _ t) = effTailNames t
-- A bare row atom (#997) carries its own tail var directly (no wrapped type
-- to recurse into) — same tail-var-sharing contract as `TyEffect`'s arm
-- above (see the `effect_param.mdk` regression guard for why this matters:
-- a KRow arg's tail var must resolve to the SAME shared effvar cell
-- wherever it recurs in a signature).
-- Deliberately NAME-based, matching the pre-existing `TyEffect` arm above
-- (NOT new to this arm — a `TyEffect` nested in a non-KRow argument slot,
-- e.g. `List (<e> T)`, has always had the identical property): this walker
-- has no kind context, so it cannot tell a row sitting in a genuinely
-- KRow-kinded slot from one sitting in a Type-kinded slot that merely LOOKS
-- like a row syntactically (`List <e>`, `List (<e> T)`). `undeterminedRetEffVars`
-- (below) is documented as needing a KIND-AWARE argument-carrier test for
-- exactly this reason and pairs this with the actually-kind-aware
-- `rowArgNames`; this arm's over-counting is a residual channel of the same
-- shape as that pre-existing gap, not a new one — see #784.
effTailNames (TyRow _ tail _) = tail
effTailNames (TyAuth _ _) = []
effTailNames (TyNamed _ t _) = effTailNames t
effTailNames (TyQual t _ _) = effTailNames t

export
lookupBinding : TcEnv -> String -> Option EnvBinding
lookupBinding env n = omLookup n env.teVars

export
lookupVar : TcEnv -> String -> Option Scheme
lookupVar env n = match omLookup n env.teVars
  Some binding => Some binding.ebValue.vsScheme
  None => omLookup n env.teCtors

export
lookupMethodRow : TcEnv -> String -> Option MethodSchemeRow
lookupMethodRow env n = match lookupBinding env n
  Some binding => binding.ebMethodRow
  None => None

export
lookupCtor : TcEnv -> String -> Option Scheme
lookupCtor env n = omLookup n env.teCtors

export
extendVar : TcEnv -> String -> Scheme -> TcEnv
extendVar env n s =
  { env | teVars = omInsert n (ordinaryEnvBinding s) env.teVars }

export
extendVars : TcEnv -> List (String, Scheme) -> TcEnv
extendVars env [] = env
extendVars env ((n, s) :: rest) = extendVars (extendVar env n s) rest

export
extendMethodRow : TcEnv -> String -> MethodSchemeRow -> TcEnv
extendMethodRow env n row =
  { env | teVars = omInsert n (methodEnvBinding row) env.teVars }

export
extendMethodRows : TcEnv -> List MethodSchemeRow -> TcEnv
extendMethodRows env [] = env
extendMethodRows env (row :: rest) =
  let env2 =
    if methodRowCanCarry row then
      extendMethodRow env row.msrName row
    else
      extendVar env row.msrName row.msrScheme
  extendMethodRows env2 rest

export
extendBindings : TcEnv -> List (String, EnvBinding) -> TcEnv
extendBindings env [] = env
extendBindings env ((n, binding) :: rest) =
  extendBindings { env | teVars = omInsert n binding env.teVars } rest

-- A selected standalone is a term binding, even when a method is also visible
-- under its spelling. Keep both descriptors in the lexical environment. A local
-- binder replaces the complete entry, so no hidden outer initializer survives.
export
lookupStandaloneVar : TcEnv -> String -> Option Scheme
lookupStandaloneVar env name =
  map (value => value.vsScheme) (lookupStandaloneValue env name)

export
lookupStandaloneValue : TcEnv -> String -> Option ValueScheme
lookupStandaloneValue env name = match lookupBinding env name
  Some binding => map snd binding.ebStandalone
  None => None

export
lookupImportedStandalone : TcEnv -> String -> Option Scheme
lookupImportedStandalone env name = match lookupBinding env name
  Some binding => match binding.ebStandalone
    Some (ImportedStandalone, value) => Some value.vsScheme
    _ => None
  None => None

-- #739: is [name] an explicitly-imported value (has a known source module)?  A miss in
-- the qual constraint table for such a name is authoritative ("unconstrained in its
-- source"), so `declaredConstraintFor` must NOT fall through to the source-blind bare-name
-- table for it.  A local / wildcard / re-export name is absent here and keeps the old path.
export
hasImportDefiner : ModuleCtx -> String -> Bool
hasImportDefiner mctx name =
  isSome (omLookup name mctx.mcCells.currentImportDefinersRef.value)

export
bindingWithStandalone : EnvBinding ->
  (StandaloneOrigin, ValueScheme) ->
  EnvBinding
bindingWithStandalone binding source = EnvBinding {
  ebValue = binding.ebValue,
  ebMethodRow = binding.ebMethodRow,
  ebStandalone = Some source,
}

export
extendTermBindings : TcEnv -> List (String, Scheme) -> TcEnv
extendTermBindings env [] = env
extendTermBindings env ((name, scheme) :: rest) =
  extendTermBindings
    (extendBindings env [
      (
        name,
        bindingWithStandalone (ordinaryEnvBinding scheme) (
          LocalStandalone,
          ordinaryValueScheme scheme,
        ),
      ),
    ])
    rest

-- #837 incr2: like extendVar/extendVars, but FLAG the introduced names local.
-- Route every genuine body-local binder (let/where/lambda/pattern/prop/do
-- binders) through these; the is-local flag then answers the two guard sites.
-- A local binder shadows the α-let entry of its name: the abstraction reads
-- a name by its binding, never by a spelling an outer let happens to share.
export
extendLocalVar : TcEnv -> String -> Scheme -> TcEnv
extendLocalVar env n s = { env |
  teVars = omInsert n (ordinaryEnvBinding s) env.teVars,
  teAlphaLets = (n, AParam) :: env.teAlphaLets,
  teIsLocal = omInsert n True env.teIsLocal,
}

export
extendLocalVars : TcEnv -> List (String, Scheme) -> TcEnv
extendLocalVars env [] = env
extendLocalVars env ((n, s) :: rest) =
  extendLocalVars (extendLocalVar env n s) rest

-- #837 incr2: is `n` currently bound as a BODY-LOCAL binding?  Presence in the
-- is-local map means local (only `extendLocalVar[s]` insert, always True).
export
lookupLocalFlag : TcEnv -> String -> Bool
lookupLocalFlag env n = omHasKey n env.teIsLocal

export
addCtor : TcEnv -> String -> Scheme -> TcEnv
addCtor env n s = { env | teCtors = omInsert n s env.teCtors }

-- An environment holding the constructors [cs] and nothing else, in the module [mctx].
export
withCtors : ModuleCtx -> OrdMap Scheme -> TcEnv
withCtors mctx cs = TcEnv {
  teVars = omEmpty,
  teCtors = cs,
  teAlphaLets = [],
  teIsLocal = omEmpty,
  teDyn = dynFor mctx,
}

-- EFFECTS WS-2: seed α's known-prefix scope with a same-function-body let RHS.
-- Prepended (most-recent-first) to mirror α's own `(x,e1)::lets` accumulation.
export
seedAlphaLets : TcEnv -> String -> Expr -> TcEnv
seedAlphaLets env n rhs =
  { env | teAlphaLets = (n, ALet rhs) :: env.teAlphaLets }

-- read the accumulated α-let scope (for the hole-fill site)
export
envAlphaLets : TcEnv -> List (String, AlphaBinder)
envAlphaLets env = env.teAlphaLets

-- #1386: `import m as A` puts `A.mth` in scope as a second SPELLING of the method
-- `mth`, and an occurrence written that way keeps it — `renameAliasedMethods` no
-- longer rewrites it, because rewriting erased the distinction that makes the
-- occurrence decidable (see `aliasQualifiedMethodEntries`); `import m.{mth as loc}`
-- puts `loc` in scope the same way.  The rows above are keyed by the method's OWN
-- declared name, so the spelling has to be resolved back to it before the row can
-- match.  Any other occurrence is its own origin.
export
originMethodName : ModuleCtx -> String -> String
originMethodName mctx name =
  optionOr name (omLookup name mctx.mcCells.aliasMethodOriginsRef.value)

-- One `methodIfaceHere`, not two.  Leg 1 (this reader) and Leg 3
-- (`ieImplExistsForHead`) both need "which declaration does this module admit for
-- [name]", and they must get it from the SAME read — S2-DECL (b) is precisely the rule
-- that both halves come from one declaration, so two near-duplicate readers of
-- `methodEntryHere` would be the defect wearing the fix's clothes.  The definition
-- lives with `MethodEnv`; this site consumes it.
--
-- `sameTyConHead`, not a bare `irName` compare — the same rule `lookupSchemeById`
-- states: this is a LOOKUP, where a false HIT is a wrong dispatch index (silent
-- wrongness) and a false MISS routes the call site to RLocal instead of falling back
-- to a bare-name answer — see `:9088-9101` for why that is a routing change, not a
-- free miss.
export
lookupIdxById : IfaceRef ->
  String ->
  List ((IfaceRef, String), Int) ->
  Option Int
lookupIdxById _ _ [] = None
lookupIdxById iface n (((ir, mn), i) :: rest)
  | mn == n && sameTyConHead ir.irName ir.irOrigin iface.irName iface.irOrigin =
    Some i
  | otherwise = lookupIdxById iface n rest

-- `ebMethodRow = Some` certifies this predicate.  Every environment producer either
-- calls `extendMethodRows`, or installs a row returned by `admittedRowFor`; both
-- gate on this function.  Keeping the certificate at the binding boundary avoids
-- rebuilding method identities and walking declared types at every occurrence.
export
methodRowCanCarry : MethodSchemeRow -> Bool
methodRowCanCarry row =
  isSome (identOriginOf row.msrIface.irOrigin)
    && not
      (anyArgMentions
        (dispatchTyparams row.msrTyparams)
        (methodArgs row.msrType))

-- The checked type of a name in scope, for the abstraction's variable rule.
export
envVarType : TcEnv -> String -> Option Mono
envVarType env x =
  map (b => schemeBodyOf b.ebValue.vsScheme) (lookupBinding env x)

export
lookupRecordByName : ModuleCtx -> String -> Option RecordInfo
lookupRecordByName mctx name = omLookup name mctx.mcCells.recordByNameRef.value

-- ── Declared kinds (EFFECTS-SEMANTICS §6.1–§6.3, §6.8) ──────────────────
-- A data / newtype / alias parameter is `Effect`-kinded (KRow) iff its head
-- DECLARES it so — `data Async (e : Effect) a`.  The inference rule this
-- replaces ("KRow iff the name appears in some field's effect tail") is
-- retired, per §6.3's surgical rule: an UNANNOTATED parameter may be inferred
-- at any kind that contains no `Effect`, which for a data head means KType.
-- An unannotated parameter used as a row is a kind error, reported by
-- `checkDeclaredKinds` at the field that demands the kind; here it is simply
-- KType, so elaboration continues.
export
declParamKinds : GraphCtx -> List String -> List (Option KindAnn) -> List Kind
declParamKinds gctx params anns = map (kindOfAnn gctx) (padAnns params anns)

-- the annotation list is positional and the same length as the parameter
-- list; pad defensively so a short list never truncates the kinds.
export
padAnns : List String -> List (Option KindAnn) -> List (Option KindAnn)
padAnns [] _ = []
padAnns (_ :: ps) (a :: rest) = a :: padAnns ps rest
padAnns (_ :: ps) [] = None :: padAnns ps []

kindOfAnn : GraphCtx -> Option KindAnn -> Kind
kindOfAnn gctx (Some KindEffect) = KRow
kindOfAnn gctx (Some (KindAuthority l o pat _)) =
  KAuth (EffLabel l o) (rangedOver gctx (EffLabel l o) pat)
kindOfAnn gctx _ = KType

-- an INTERFACE parameter's slot kinds from its declared arrow kind: `Effect ->
-- Type -> Type` is `[KRow, KType]` (the final `Type` is the result, not a
-- slot).  An atomic annotation has no slots.
export
kindAnnSlots : GraphCtx -> KindAnn -> List Kind
kindAnnSlots gctx (KindArrow a b) = kindAnnAtom gctx a :: kindAnnSlots gctx b
kindAnnSlots gctx _ = []

kindAnnAtom : GraphCtx -> KindAnn -> Kind
kindAnnAtom gctx KindEffect = KRow
kindAnnAtom gctx (KindAuthority l o pat _) =
  KAuth (EffLabel l o) (rangedOver gctx (EffLabel l o) pat)
kindAnnAtom gctx _ = KType

-- ── #822: interface type-parameter kinds (graded interfaces) ──────────────
-- EFFECTS-SEMANTICS §6 "Graded interfaces": an interface may abstract over a
-- ROW-INDEXED constructor (`f : Row -> Type -> Type`), so that its methods can
-- carry the grade in the type index (`gandThen : f e a -> (a -> <e> f e b) ->
-- f e b`, the graded-lite degenerate the spec admits today).  Data types already
-- have per-parameter kinds (dataParamKindsRef, inferred from a variant field's
-- effect tail by inferParamKinds); interfaces had NO kind source at all, so an
-- abstract head `f e a` elaborated to an opaque `TApp` in which `e` was a plain
-- TYPE variable — which is why the graded-lite signature was rejected outright
-- (T-EFFECT-ARG-UNCOVERED: `f e b` contributed no return-position occurrence).
--
-- Inference mirrors inferParamKinds one level up: slot i of typaram `p` is KRow
-- iff SOME application `p … a_i …` in a method signature puts a bare NAME at slot
-- i that the SAME signature also uses in an effect-tail position (`<e>`).  The
-- per-interface union matters: `gpure : a -> f e a` alone would infer slot 0 as
-- KType, and disagreeing slot kinds across two methods of one interface would
-- elaborate the same index to a row in one and a tyvar in the other.
--
-- #1557 A-3.5c retired the table, not the inference.  `registerIfaceParamKinds`/
-- `registerIfaceParamKindsGo` and the `ifaceParamKindsRef`/`universeIfaceParamKinds`
-- pair they wrote into are GONE.  The inference above is unchanged and now has
-- exactly two consumers, both of which call `ifaceParamKindsOf` directly on the
-- DECLARATION they are elaborating: `declGradedScope` (the per-method scope) and
-- `classEnvRowsOf`'s `ceParamKinds` (stage K's `CE`, which is what
-- `checkGradedImplTys` now reads).  The retired writer's own comment already said the
-- table was dead weight kept only because *"removing it is a separate
-- behaviour-preserving change with its own goldens"* — this is that change.
export
anyKRow : List Kind -> Bool
anyKRow [] = False
anyKRow (KRow :: _) = True
anyKRow (_ :: rest) = anyKRow rest

-- ── #1557 A-3.5c: `insertIfaceParamKinds`/`ifaceSlotKey` STOOD HERE ──────────
-- The table they wrote is retired (see the note above `anyKRow`); the KEY SHAPE
-- they minted survives in stage K's `CE` — `ceRowKey` is `regKeyOfTab (ifaceTabKey
-- o name)` and the slot is supplied POSITIONALLY by `ceRowParamKinds`, which is
-- the same (identity, slot) pair without a composite key to mint.  The history
-- below is kept because it is the derivation behind `declGradedScope` carrying
-- its scope as an argument, and that is still live.
--
-- ONE key shape: the interface's IDENTITY plus the slot ORDINAL
-- (`regKeyTabAt (ifaceTabKey o iface) i`, #1111 A-2.4).  It was the bare string
-- `"\{iface}@\{i}"` until this unit, which is #1257: an ordinary interface and a
-- graded one, same bare name, unrelated modules, one shared key.
-- the slot is an ordinal and stays one.  It is deliberately NOT spliced into the
-- identity's name field — `"Same@0"` is not the name of anything, and putting it
-- there re-creates a bare-string composite inside the very identity that exists to
-- remove one (see `RegKey`'s doc-comment in `types/registry.mdk`).
-- An earlier cut of #822 ALSO stored the bare typaram NAME, so that the
-- elaboration seams — which see a `TyVar h` spine head carrying no interface
-- context — could look it up.  That was an S0: `rowArgNames`/`fromAstTypeE` are the
-- GENERAL signature elaborators (sigToSchemeTvs, astTypeFreshTbl), not an
-- interface-method-only seam, so a program-global `f ↦ [KRow, KType]` was adopted by
-- every unrelated `f a b` in the program — a plain top-level signature
-- (`bad : f Int a -> f String a` type-checked, both arguments erased to `<>` by
-- rowArgOf's catch-all), every OTHER module through the data universe (which is not
-- import-scoped), and the prelude itself (arity-1 `[KRow]` collides with `Mappable`/
-- `Applicative`/`Thenable`/`Foldable`, turning one clean diagnostic into 45
-- mislocated ones).  Poisoning could not save it: an interface-local type-parameter
-- name is simply not a program-global key.  The scope now travels as an explicit
-- argument instead — see declGradedScope and rowArgNamesIn.
-- (`o` is the DECLARATION's identity — `DInterface.ifaceOrigin`, threaded from
-- `registerData`'s record pattern.  Same source, same reason, as
-- `recordParamKinds`' `dataOrigin`: it must not come from ambient state, because
-- `registerAllData` also runs over OTHER modules' decls.)
-- The scope derived straight from the declaration being elaborated: the same
-- `ifaceParamKindsOf` inference stage K's `ceParamKinds` runs, on the very methods
-- whose signatures are about to be built.  No name, no table, no lookup — structurally unforgeable.
-- EFFECTS-SEMANTICS §6.3 / §6.8: the graded scope is now DECLARED — an
-- interface parameter is graded iff its head writes an arrow kind with an
-- `Effect` in it (`(f : Effect -> Type -> Type)`).  The co-occurrence inference
-- (`ifaceParamKindsOf`) is retired as a SOURCE of kinds and survives only as
-- the evidence `checkDeclaredKinds` uses to tell the author which parameter
-- needed the annotation.  [anns] is positional with [typarams].
export
declGradedScope : GraphCtx ->
  List String ->
  List (Option KindAnn) ->
  List IfaceMethod ->
  List (String, List Kind)
declGradedScope gctx [] _ _ = []
declGradedScope gctx (p :: ps) [] methods =
  declGradedScope gctx (p :: ps) [None] methods
declGradedScope gctx (p :: ps) (a :: anns) methods =
  declGradedScopeAdd
    p
    (ifaceParamKindsDecl gctx a p methods)
    (declGradedScope gctx ps anns methods)

-- an interface parameter's RESOLVED slot kinds (§6.3): the declared arrow
-- kind's slots where one is written; otherwise the inferred ARITY with every
-- slot at KType — an unannotated parameter is never `Effect`-kinded.
ifaceParamKindsDecl : GraphCtx ->
  Option KindAnn ->
  String ->
  List IfaceMethod ->
  List Kind
ifaceParamKindsDecl gctx (Some (KindArrow a b)) _ _ =
  kindAnnSlots gctx (KindArrow a b)
ifaceParamKindsDecl gctx _ p methods =
  map (_ => KType) (ifaceParamKindsOf p methods)

declGradedScopeAdd : String ->
  List Kind ->
  List (String, List Kind) ->
  List (String, List Kind)
declGradedScopeAdd p kinds rest
  | anyKRow kinds = (p, kinds) :: rest
  | otherwise = rest

-- Slot kinds of interface typaram [p].  Arity is the FIRST application's; an
-- application at any other arity is ignored (every lookup site guards on the arity
-- anyway, so a mixed-arity head simply stays opaque).
export
ifaceParamKindsOf : String -> List IfaceMethod -> List Kind
ifaceParamKindsOf p methods = match flatMap (ifaceMethodVarApps p) methods
  [] => []
  apps@((args0, _) :: _) =>
    ifaceSlotKinds
      (listLen args0)
      0
      (filterList (a => listLen (fst a) == listLen args0) apps)

-- every application of [p] in one method signature, paired with that signature's
-- effect-tail names (the "same signature" side of the KRow rule).
ifaceMethodVarApps : String -> IfaceMethod -> List (List Ty, List String)
ifaceMethodVarApps p (IfaceMethod _ mty _ _) =
  let tails = dedup (effTailNames mty)
  map (args => (args, tails)) (varHeadApps p mty)

ifaceSlotKinds : Int -> Int -> List (List Ty, List String) -> List Kind
ifaceSlotKinds arity i apps
  | i >= arity = []
  | otherwise =
    (if anySlotIsRow i apps then KRow else KType)
      :: ifaceSlotKinds arity (i + 1) apps

anySlotIsRow : Int -> List (List Ty, List String) -> Bool
anySlotIsRow _ [] = False
anySlotIsRow i ((args, tails) :: rest) = match nthTy i args
  Some (TyVar n) => contains n tails || anySlotIsRow i rest
  _ => anySlotIsRow i rest

-- every application whose SPINE HEAD is the type VARIABLE [p], as its argument
-- list.  The head of a spine is an atom (TyCon/TyVar), so recursing through the
-- arguments alone covers the whole tree.
varHeadApps : String -> Ty -> List (List Ty)
varHeadApps p (TyApp a b) =
  let sp = tyAppSpine (TyApp a b)
  varHeadHere p (fst sp) (snd sp) ++ flatMap (varHeadApps p) (snd sp)
varHeadApps p (TyFun a b) = varHeadApps p a ++ varHeadApps p b
varHeadApps p (TyTuple ts) = flatMap (varHeadApps p) ts
varHeadApps p (TyEffect _ _ t) = varHeadApps p t
varHeadApps p (TyConstrained _ t) = varHeadApps p t
varHeadApps _ _ = []

varHeadHere : String -> Ty -> List Ty -> List (List Ty)
varHeadHere p (TyVar h) args
  | h == p = [args]
  | otherwise = []
varHeadHere _ _ _ = []

-- ── top-level driver ──────────────────────────────────────────────────────
export
funClausePair : FunClause -> (List Pat, Expr)
funClausePair (FunClause pats body) = (pats, body)

export
funDefs : List Decl -> List (String, (List Pat, Expr))
-- Intentional cross-file duplicate of eval.mdk's copy. The two flatten the same
-- decl shapes for different consumers — an eval frame there, an inference SCC
-- here — and eval.mdk deliberately imports nothing from types/ so that untyped
-- eval stays runnable without the typechecker.
-- lint-disable-next-line rule-duplicate-body
funDefs [] = []
funDefs ((DFunDef _ n pats body _ _) :: rest) =
  (n, (pats, body)) :: funDefs rest
-- Top-level `let rec … with …` (DLetGroup): flatten each binding's clauses to
-- (name, (pats, body)) entries, exactly like a multi-clause DFunDef, so the SCC
-- builder groups the mutually-recursive members and assigns them schemes, feeding
-- DLetGroup bindings into the same letrec-group path.
funDefs ((DLetGroup _ binds) :: rest) = letGroupDefs binds ++ funDefs rest
funDefs ((DAttrib _ d) :: rest) = funDefs (d :: rest)
funDefs (_ :: rest) = funDefs rest

letGroupDefs : List LetBind -> List (String, (List Pat, Expr))
letGroupDefs [] = []
letGroupDefs ((LetBind n clauses _ _) :: rest) =
  map (tcClauseDef n) clauses ++ letGroupDefs rest

tcClauseDef : String -> FunClause -> (String, (List Pat, Expr))
tcClauseDef n c = (n, funClausePair c)

-- argument types of a method (strip leading constraint/effect wrappers + arrows)
export
methodArgs : Ty -> List Ty
methodArgs (TyConstrained _ t) = methodArgs t
methodArgs (TyEffect _ _ t) = methodArgs t
methodArgs (TyFun a b) = a :: methodArgs b
methodArgs _ = []

export
anyArgMentions : List String -> List Ty -> Bool
anyArgMentions _ [] = False
anyArgMentions typarams (ty :: rest) =
  argMentions typarams ty || anyArgMentions typarams rest

-- the dispatch var of a method-level slot: its first tyvar that is not an
-- interface param, else its first tyvar.  Empty for a constraint over no tyvar.
export
constraintSlotDispatchVar : List String -> Constraint -> List String
constraintSlotDispatchVar typarams (Constraint { constraintArgs = args }) =
  let vars = flatMap tyVarNames args
  match removeAllS typarams vars
    n :: _ => [n]
    [] => match vars
      n :: _ => [n]
      [] => []

-- the shared retest, and it is spelling-KEYED THROUGH `dispHeadTab` ON PURPOSE —
-- it must be the same projection the bucketing applies, never A STRONGER ONE.
-- Every head comparison in this file bottoms out here (`headTabEq`,
-- `ieImplExistsForHeadGo`, `ieCountHeadByIfaceGo`, `ieCountHeadByMethodGo`), and the
-- buckets they scan are filed by `headBucketRender` / `ieFileRowByHead` =
-- `regKeyRender (regKeyOfTab (dispHeadTab …))`.  So a retest that compared `HeadKey`s
-- STRUCTURALLY (`hd == Some hk`, which `deriving Eq` makes an IDENTITY comparison)
-- would be strictly stronger than the bucket it is scanning, and would answer False
-- wherever the two sides' ORIGINS differ.
--
-- That is the normal case, not a corner.  Neither projection GUARANTEES an
-- identity — both bottom out in `tabKeyOf`, which answers `TkBare` for an
-- origin it cannot attribute — but they are not SYMMETRIC in practice, and that
-- was measured, not argued (#1111): the impl side (`headTyconTy`, off a
-- `Ty.TyCon`) came back `TkIdent … IdentBuiltin` for every primitive head on
-- both driver arms, while the goal side (`headTyconMono`) came back mixed,
-- because `stdlib/runtime.mdk`'s EXTERN signatures never pass through resolve's
-- head-stamping walk.  So the receiver of `debug (stringLength "xy")` projects
-- `HkDecl (TkBare NsType "Int")` against the prelude impl's
-- `HkDecl (TkIdent (Ident NsType IdentBuiltin "Int"))`.  A structural compare
-- says "no impl of this method at this head", and `inferShadowApp` /
-- `resolveRLocalSite` then silently route the call to a same-named standalone
-- (S0: `debug (stringLength "xy")` printed the standalone's answer at exit 0,
-- with `check` accepting).
--
-- This is exactly the asymmetry `dispHeadTab`'s own derivation records — the
-- goal side is neither SUPPLIED nor CANONICAL until the follow-on semantics
-- unit — which is why this site belongs IN that ledger and not outside it.
-- Corpus: `test/shadow_fixtures/i11_importer_extern_receiver`.
-- ARCH B-2.1-d: this derivation used to live on `implExistsForHeadGo`, the prefix-table
-- existence scan, and was cited from here, from `headTabOf` and from
-- `ieImplExistsForHeadGo`.  That whole read side is deleted; the RULE is unchanged and
-- now lives on the primitive every surviving retest shares.
--
-- `None` is a headless (fully-general) entry, which lives in the headless
-- bucket and so cannot be reached from a `Some hk` head lookup at all; False
-- is both the unreachable answer and the pre-A-2.2b one (`noneHeadTag` never
-- equalled a projected head name).
headTabIs : Option HeadKey -> TabKey -> Bool
headTabIs (Some hk) goal = dispHeadTab hk == goal
headTabIs None _ = False

-- `headTabIs` widened to a goal that may itself be HEADLESS, for the counting
-- scans (`ieCountHeadByIfaceGo`, `ieCountHeadByMethodGo`) whose goal is an
-- `Option HeadKey` rather than the bare `HeadKey` an existence test has.
-- Same rule, same reason: both sides go through `dispHeadTab`, so the retest is
-- exactly the partition the entries were filed under and never a stronger one
-- (see the note on `headTabIs` for what a stronger one costs, and
-- `dispHeadTab`'s ledger for the enrolment rule).
--
-- The headless arm answers True on purpose: the headless bucket's every entry
-- carries `None`, and pre-A-2.2b this was the literal
-- `"__none__" == "__none__"` those entries were filed under.  The mixed arms are
-- False, which is likewise what a name-vs-`noneHeadTag` compare answered — minus
-- the forgery, since a head that SPELLS `__none__` can no longer reach the
-- headless bucket at all (`headBucketRender`).
headTabEq : Option HeadKey -> Option TabKey -> Bool
headTabEq hd (Some goal) = headTabIs hd goal
headTabEq None None = True
headTabEq (Some _) None = False

-- the goal-side projection, hoisted OUT of the scans above: Medaka is strict, so
-- projecting inside the per-entry arm would rebuild the same `TabKey` once per
-- entry in the bucket.
headTabOf : Option HeadKey -> Option TabKey
headTabOf None = None
headTabOf (Some hk) = Some (dispHeadTab hk)

-- #2188: the SAME query with the admitted declaration supplied by the CALLER rather than
-- projected from the single-winner table.  The one caller that supplies it is S2-DECL
-- (d)'s cardinality decision (`importerAdmittedVerdict`), which must ask the query once
-- PER admitted declaration — `methodIfaceHere` cannot express that, because it is a
-- cardinality-1 projection by construction.  The body is `ieImplExistsForHead`'s former
-- body verbatim; the three existence READS above are unchanged and still route through
-- the single-argument spelling, so no read has been split off from the set.
export
ieImplExistsForHeadOf : ModuleCtx ->
  ImplEnv ->
  String ->
  HeadKey ->
  Option (List IfaceRef) ->
  Bool
-- #1386: a row's method set is keyed by the method's own DECLARED name, so an
-- alias-qualified occurrence is resolved to its origin here — once per query, beside
-- the admitted declaration, never inside the row scan.
ieImplExistsForHeadOf mctx env name hk admitted =
  ieImplExistsForHeadGo
    mctx.mcGraph
    (ieHeadRows (Some hk) env)
    (originMethodName mctx name)
    (dispHeadTab hk)
    admitted

-- STILL SPELLING-KEYED, THROUGH `dispHeadTab`/`headTabIs` — the retest keeps the
-- projection strength of the bucket it scans and NOT a stronger one.  The BUCKET moved
-- from a topological prefix to the whole graph; the RETEST did not change shape.  The
-- full derivation is the note on `headTabIs`: a structural `HeadKey`
-- compare here re-opens #1111's S0 (`debug (stringLength "xy")` printing the
-- standalone's answer at exit 0), because the impl side and the goal side are measured
-- to disagree on ORIGIN per provenance.  `univReceiverTag tys` is the same head
-- projection `ieFileRowByHead` files each row under, so the two sides of `headTabIs`
-- are the partition, exactly as `ieCountHeadByIfaceGo` owes it.
-- The last field lists supplied methods only. An admitted interface's defaults
-- answer too, through the same predicate used by instance selection.
--
-- #1351/#1664 Leg 3: the row's 3rd field, `IfaceRef`, was ALREADY THERE and was
-- discarded by this pattern (`ImplRow _ _ _ tys _ ms`).  Nothing about `ImplRow`
-- widened; the retest stopped throwing away the identity it was already carrying.
ieImplExistsForHeadGo : GraphCtx ->
  List ImplRow ->
  String ->
  TabKey ->
  Option (List IfaceRef) ->
  Bool
ieImplExistsForHeadGo gctx [] _ _ _ = False
ieImplExistsForHeadGo gctx ((r@(ImplRow _ _ ir tys _ ms _)) :: rest) name goal admitted
  | headTabIs (univReceiverTag tys) goal
    && ieRowAdmittedBy ir admitted
    && ieRowAnswersMethod gctx r ms name admitted = True
  | otherwise = ieImplExistsForHeadGo gctx rest name goal admitted

-- Does this row's interface match the declaration the querying module admits?
--
-- `None` falls back to the bare-NAME ANSWER — every row passes — and that is the
-- SETTLED reading, not a hedge.  S2-DECL (c) narrows the query to declarations `M` can
-- name; (d)'s `None` arm ("S1 already says `N` is not a shadow in `M`; the standalone
-- denotes.  Unchanged by this clause") hands the EMPTY-admitted-set case to S1, upstream
-- of this query, so S2-DECL gives this site no instruction for a table miss.  `None`
-- is a module scope that admits no declaration of [name] at all, and the file's own
-- two precedents for exactly that miss both fall back: `pickSchemesByDecl`'s block ("a
-- miss must not drop the binding") and `admittedSchemeFor`'s ("never a guess").
-- Answering `False` unconditionally instead would turn a dispatched occurrence into an
-- `RLocal` one on every shape this query does not decide.  Two or more admitted
-- declarations are not a miss: they arrive as `Some []` (`methodAdmissionHere`) and
-- admit no row.
--
-- `ieRowIfaceMatches` (`sameTyConHead` over `irName`/`irOrigin`), NOT a bare `irName`
-- compare and NOT `ieCountHeadByIfaceGo`'s deliberately spelling-only test: this is a
-- LOOKUP where a false HIT is silent wrongness (an impl of an unnameable declaration
-- answering `True` — the #1664 defect) and a false MISS costs only the fall-through to
-- the standalone.  It is the one standing comparator for IfaceRef-vs-IfaceRef identity in
-- this family (`ieEntriesForIface`, `cohSameIface`, `lookupSchemeById`).
ieRowAdmittedBy : IfaceRef -> Option (List IfaceRef) -> Bool
ieRowAdmittedBy _ None = True
ieRowAdmittedBy ir (Some ifaces) = anyList (ieRowIfaceMatches ir) ifaces

-- Only the population moved; the discipline `B-2.1-g` established stays intact:
--   • Key strength is unchanged.  Both sides still project through `dispHeadTab`
--     (`headTabEq`), i.e. the head tycon spelling, exactly as `tag2 == tag`
--     compared two `headTyconNameTy`/`headTyconNameMono` names.  A structural
--     `HeadKey` compare here would re-open #1111 — see `headTabIs`'s note.
--   • The `requires`-only filter is kept (`implRowHasReqs`).  `ImplBuckets` was
--     built by `implEntryOf`, whose `match reqs [] => []` arm drops every impl with
--     no context, so the predecessor could only ever answer True for a
--     `requires`-carrying impl.  Dropping that filter is a SECOND, independent
--     semantic change (it would stop reducing to `compare` for context-free impls
--     that define the method directly) and it is NOT what the S1 needs.  It is
--     recorded as owed rather than smuggled in here.
-- The net motion is therefore a pure WIDENING of the same predicate: every True the
-- prefix answered, this answers; the ones it adds are exactly the impls the global
-- selector could already see and the guard could not.
export
ieDefinesReqMethodAt : ImplEnv -> String -> Option HeadKey -> Bool
ieDefinesReqMethodAt env method hd =
  -- goal-side key projected ONCE, here — see `headTabOf` (Medaka is strict).
  ieDefinesReqMethodAtGo (ieHeadRows hd env) method (headTabOf hd)

ieDefinesReqMethodAtGo : List ImplRow -> String -> Option TabKey -> Bool
ieDefinesReqMethodAtGo [] _ _ = False
ieDefinesReqMethodAtGo ((ImplRow _ _ _ tys reqs ms _) :: rest) method goal
  | implRowHasReqs reqs
    && headTabEq (univReceiverTag tys) goal
    && contains method ms = True
  | otherwise = ieDefinesReqMethodAtGo rest method goal

-- `implEntryOf`'s `match reqs [] => []` arm, as a predicate over an `IE` row.
implRowHasReqs : List Require -> Bool
implRowHasReqs [] = False
implRowHasReqs _ = True

-- the names of an interface's REQUIRED methods (those whose merged IfaceMethod
-- carries NO default body).  Since #1557 A-3.5a this is called once per interface at
-- `CeRow` construction (`classEnvRowsOf`) rather than once per impl-check, and it is
-- the same pure computation the retired `insertIfaceRequired` writer stored.
requiredMethodNames : List IfaceMethod -> List String
requiredMethodNames [] = []
requiredMethodNames ((IfaceMethod n _ None _) :: rest) =
  n :: requiredMethodNames rest
requiredMethodNames ((IfaceMethod _ _ (Some _) _) :: rest) =
  requiredMethodNames rest

export
recordCandInfo : (Ident, String, RecordInfo) -> RecordInfo
recordCandInfo (_, _, ri) = ri

export
ceRowIfaceName : CeRow -> String
ceRowIfaceName r = match ceRowIface r
  IfaceRef { irName = n, ... } => n

-- The `done`/`path` identity, rendered once.  `regKeyRender` is `RegKey`'s own
-- collision-free renderer, so two same-spelled interfaces in unrelated modules
-- get DIFFERENT set members — which is the whole point of the re-key.
export
ceRowDoneKey : CeRow -> String
ceRowDoneKey r = regKeyRender (ceRowKey r)

-- ── instance-`requires` impl-dict routing (Phase 83/84 single-level) ────────
-- `implMethodNameTc` and its callers route through the graph-global `IE`
-- (`ieSelectRowByIface`); a headless impl's own `requires` is discharged the
-- same way, through `ieSelectRowByIface` with the iface known.
--
-- There is a SECOND SET beyond the registrars (who writes a bucket): the
-- READERS that index a single head bucket DIRECTLY, without the headless
-- union `ieCandidatesFor*` applies -- `ieImplExistsForHead`. Audit this set as
-- a SET, not one member at a time -- [T-GLOBAL-TABLE]'s discipline for any table
-- a new AST constructor or a new bucket population could reach.
implMethodNameTc : ImplMethod -> String
implMethodNameTc (ImplMethod n _ _) = n

-- the entry's declaration index (see KeyEntry).
keyEntryIdx : KeyEntry -> Int
keyEntryIdx (KeyEntry _ _ _ _ _ _ _ i) = i

-- THE `noneHeadTag` sentinel is no longer A BUCKET NAME — "this impl has no
-- head type constructor" is spelled STRUCTURALLY, as an EMPTY identity block.
-- That is the one place this unit strictly strengthens the table rather than
-- restructuring it: a reserved NAME can be forged by a head that spells it; an
-- empty identity block cannot be produced by any head at all, because every head
-- contributes exactly one `TabKey`.
--
-- what that bought, recorded here because the selector it retired is gone (ARCH
-- B-2.1-d deleted `candidateBucket`, which carried this derivation).  A goal-head
-- bucket could once EQUAL the headless bucket, so the head-plus-headless union had to
-- carry an explicit `tag == noneHeadTag` guard against merging the headless bucket with
-- ITSELF and silently doubling every candidate.  That was live, not defensive:
-- `paramMonoOf` synthesises a head from a TYPE-PARAMETER NAME for any param an
-- occurrence leaves unbound, and `__none__` lexes as a legal type VARIABLE — `data
-- __none__ = N` is a parse error, but `impl Q __none__ where …` type-checks at exit 0,
-- so an interface declared `Ix __none__ e` put the sentinel at `goals[0]`.  The guard's
-- PRECONDITION is now UNREPRESENTABLE: the headless key is `headlessBucketKey`, an
-- EMPTY identity block, while a goal's key is exactly ONE `TabKey` whatever the head is,
-- and `regKeyRender` count-prefixes the block — so a one-element block can never render
-- as a zero-element one.  A `__none__`-spelled head now names the (empty) bucket of a
-- head that happens to be spelled `__none__`.  Do NOT read this as "the guard was
-- defensive after all"; what retires it is that ABSENCE stopped being spelled as a
-- reserved NAME.  A rigid is still keyed by its spelling here (`dispHeadTab`), so the §8
-- I6.1 residual is untouched.
--
-- `noneHeadTag` itself remains the HEAD TAG a headless impl's entries carry for
-- arg-tag dispatch and symbol naming; no dictionary word is ever spelled with it.
-- ARCH B-2.1-a3: the key `IE`'s head-keyed index (`ieFileRowByHead`, which files
-- into a `MultiRegistry`) mints from a head — the SAME partition the retired
-- KeyBuckets table used to mint via `regKeyRender (headBucketKey hd)`.
headBucketKey : Option HeadKey -> RegKey
headBucketKey None = headlessBucketKey
headBucketKey (Some hk) = regKeyOfTab (dispHeadTab hk)

-- The key of the bucket holding the fully-general (`impl C a`) entries.
headlessBucketKey : RegKey
headlessBucketKey = regKeyNTab []

-- the canonical impl key.  B-2.2-e: no longer a mirror of eval.mdk's `implKeyOf`
-- — it IS that function (`route_key.implRouteKeyWord`), reached from both sides of
-- the seam.  B-2.2-b1: this spelling passes `OriginUnresolved`, i.e. the BARE
-- interface name, and it is the mint for exactly ONE thing: `KeyEntry`'s 4th field,
-- written by `keyEntryOfRow` and read by nobody (measured, not grepped:
-- replacing the word at both sites with a literal `"__DEAD__"` builds, passes
-- `make check-self` and passes every assertion of the three dict-semantics
-- conformance gates).  The LIVE route words — the ones that
-- reach a dict cell — are minted at `rowRouteKey` from the winning ROW's own
-- `irOrigin`, so they carry the
-- interface's identity and this one does not.  Do not "unify" them without first
-- giving that field a reader.
implKeyTc : String -> List Ty -> String
implKeyTc iface tys = implRouteKeyWord OriginUnresolved iface tys None

-- stable merge of two entry lists on the declaration index.  Ties keep the LEFT
-- operand (the goal's own head bucket) first.
--
-- WHY A merge and not `++`.  `pickMostSpecificEntry` falls back to the head of the
-- list when the matching set has no unique min⊑.  That program is rejected
-- (`T-AMBIGUOUS-INSTANCE`), so the tie-break decides no value, but it still decides
-- which route the rejected compile stamps.  Concatenating buckets would make it
-- "concrete first" irrespective of where the impls appear in the source; merging on
-- the declaration index makes it DECLARATION ORDER, which the declaration-order
-- permutation differential (diff_compiler_dict_semantics_permute.sh) can see.
--
-- The PRECONDITION — both operands ascending by index — is a property of the
-- CALLER'S table, not of this function.  That is still worth stating, because it is
-- what makes a future violation possible; but it now holds at every call site, and
-- structurally rather than by convention.  ENUMERATED, since there are only two:
-- `ieCandidatesForIface` and `ieCandidatesForMethod`, both merging `ieHeadRows`
-- buckets whose index is `instRefSeq` — a WHOLE-GRAPH counter appended in build
-- order, so both operands are ascending BY CONSTRUCTION and the tie-break is
-- graph-global declaration order.
--
-- it did not always hold, and the history is what stops it being reintroduced.
-- `universeKeyBucketsRef` violated it: `appendUniverseAccums` re-entered
-- `bucketKeyEntries` once per module with a NON-EMPTY accumulator, so the numbering
-- RESTARTED AT 0 within one table (indices duplicated) and each module's slice was
-- prepended, never reversed (descending).  ARCH B-2.1-b2 moved the selectors off that
-- table and B-2.1-d deleted it, along with `candidateBucket` — the head-plus-headless
-- union that was this function's third caller.  So no `KeyBuckets` value reaches this
-- function at all any more.  Re-adding a cumulative, non-`omEmpty`-seeded accumulator
-- (see `bucketKeyEntriesFrom`) is the one edit that would break the precondition again.
--
-- On an unsorted operand this still terminates and is still deterministic; it is only
-- the "= declaration order" claim that would fail.
mergeByDeclIdx : List KeyEntry -> List KeyEntry -> List KeyEntry
mergeByDeclIdx [] ys = ys
mergeByDeclIdx xs [] = xs
mergeByDeclIdx (x :: xs) (y :: ys)
  | keyEntryIdx x <= keyEntryIdx y = x :: mergeByDeclIdx xs (y :: ys)
  | otherwise = y :: mergeByDeclIdx (x :: xs) ys

-- The three selection legs (checker, router, method-keyed) are coupled and must all
-- be updated together; repointing only two produces a segfault (the impl gains a
-- dict param but the element-route leg still selects from the prefix). See
-- compiler/TYPECHECK-TARGET-ARCHITECTURE.md § "9.6 The subsumption enumeration —
-- derived by SHAPE, not by prefix" for the measured failure and the three legs named.
--
-- DICT §11 / §6 *uniform resolution* forbids a second min⊑ selector, so every entry
-- point funnels through `pickMostSpecificEntry` — the same `entryCovers`, the same
-- closed-goal `T-AMBIGUOUS-INSTANCE` report, the same first-match fallback.
-- `keyEntryOfRow` projects rows into the `KeyEntry` that selector speaks.
--
-- The `instRefSeq` declaration index fixes ordering: every `ieHeadRows` bucket is
-- ascending by construction, so the tie-break at a no-unique-minimum goal is
-- graph-global declaration order.
--
-- The `KeyEntry` projection from a row matches the deleted `keyEntryOf` field-for-field:
-- same `headTyconTy` head projection, same `implKeyTc` key, same `tys` as `itys`,
-- with `instRefSeq` where `bucketKeyEntriesFrom` stamped a per-table ordinal.
-- Rows with no head type (`tys = []`) are unselectable on both substrates.
keyEntryOfRow : ImplRow -> List KeyEntry
keyEntryOfRow (ImplRow _ inst ir tys reqs ms _) = match tys
  headTy :: _ => [
    KeyEntry
      ms
      (headTyconTy headTy)
      headTy
      (implKeyTc ir.irName tys)
      ir.irName
      tys
      reqs
      (instRefSeq inst),
  ]
  [] => []

-- `entryHeadMatches` against a row's head vector, without building the row's
-- `KeyEntry` first — the whole point is that the hot scan below allocates only for
-- a row that MATCHES.  A `tys = []` row matches nothing (it has no head pattern to
-- match with), which agrees with `keyEntryOfRow` dropping it.
ieRowHeadMatches : List Ty -> List Mono -> Bool
ieRowHeadMatches (tys@(headTy :: _)) goals = entryHeadMatches headTy tys goals
ieRowHeadMatches [] _ = False

-- The iface-keyed candidate scan: every row of [rows] whose interface is [iface]
-- and whose head pattern matches [goals], as `KeyEntry`s, ORDER PRESERVED.  The
-- peer of the deleted `matchingEntriesByIfaceGo`, one substrate over — same
-- `ifn == iface` filter (NOT method-name membership, so a specific impl inheriting
-- a method via a DEFAULT is still seen) and the same `entryHeadMatches`.
-- `keyEntryOfRow r` is a ONE-element list on this arm (the guard proved `tys`
-- non-empty), so the `++` is a single cons.
--
-- B-4b-i widened the query side to `IfaceRef` and changed nothing else — the
-- REPRESENTATION moved, the ANSWER did not, and the neutrality is STRUCTURAL rather
-- than measured.  The filter is now `sameTyConHead` (`frontend/ast.mdk`), the
-- ACCEPTANCE-direction rule: `n1 == n2 && not (tyConIdsConflict o1 o2)`, whose
-- `tyConIdsConflict` answers True only when BOTH origins are identities and they
-- differ.  Every caller in this tree still constructs its query with
-- `ifaceRefBare` (origin `OriginUnresolved` ⇒ `identOriginOf` = `None`), so the
-- conflict test's `(Some, Some)` arm is UNREACHABLE and the whole predicate
-- collapses to `ir.irName == iface.irName` — today's `==`, byte for byte.  That
-- also disposes of the `OriginBuiltin` asymmetry (`ifaceIdentity` maps it to
-- absence, `identOriginOf` maps it to `Some IdentBuiltin`): a row minted with
-- `OriginBuiltin` still cannot conflict with an ABSENT query, so this site does not
-- depend on the "no interface is builtin" invariant holding.
--
-- NOT `ifaceIdMatches`, and the choice is the whole point of the bite.  That is
-- the LOOKUP-direction rule (`a /= "" && a == b`) — absence NEVER matches — which
-- would make every flat-driver interface (single-file `check`, lsp, repl, doc: they
-- deliberately stamp nothing) a non-match and silently empty this scan.  The two
-- rules document each other at `frontend/ast.mdk`; neither may be copied to the
-- other's site.
--
-- B-4b-ii supplied real identity, so the `(Some, Some)` arm is now reachable and
-- the paragraph above is history, not A CURRENT DESCRIPTION.  Exactly ONE of the
-- family's two entry points supplies it at every call — `findMatchingImplReqsU` →
-- `iface`, read off `Require.requireOrigin` / `Predicate.iface`; see the derivation
-- there.  The other (`entailInst`'s `EKNestedTop` arm) forwards the interface its
-- caller supplies: identity-bearing on the `requires` leg
-- (`argImplReqRoutes` reads `requireOrigin`, #3534), and possibly the bare route word
-- `pushDictApp` projects into on the top-level constrained-call leg
-- (`ifaceForInferredId`'s third fallback).
--
-- what that makes reachable, stated because B-4b-i's neutrality argument DEPENDED
-- on it being unreachable: a row whose interface carries `OriginBuiltin` would now
-- conflict with an origin-bearing query, since `ifaceIdentity` maps `OriginBuiltin` to
-- absence while `identOriginOf` maps it to `Some IdentBuiltin`.  DERIVED, not
-- inherited from the comments that assert it: the only `iface:`-tagged writers into
-- `tyOriginScope`/`flatTyOriginScope` are `ifaceDeclaredIn` and `ownIfaceOrigin`, and
-- BOTH mint `OriginModule`; `builtinTyOrigins` keys under the BARE name, i.e. the type
-- namespace, so `fillIfaceOccOrigin`'s `omLookup (ifaceKey n)` cannot return
-- `OriginBuiltin`.  Its other arm only preserves an origin the occurrence already had,
-- and no site in the tree mints `OriginBuiltin` into an interface-occurrence carrier
-- (`tyConBuiltin` builds a `Ty`; `tconBuiltin` / `tconTupleHead` / `headKeyOfCon
-- OriginBuiltin` build type heads).  Corroborated on the binary: every interface row
-- of the origin-agreement corpus reads `mod:…`, the prelude's `Eq`/`Ord`/`Debug`
-- included, and none read `builtin` in the retired origin-agreement corpus.
--
-- The rule is factored into `ieRowIfaceMatches` rather than inlined so the SELECTION
-- family has exactly ONE seam a supply bite has to reason about — and so it cannot be
-- confused with `ieCountHeadByIfaceGo`'s deliberately spelling-only test, which is a
-- different question and stays where it is.
export
ieRowIfaceMatches : IfaceRef -> IfaceRef -> Bool
ieRowIfaceMatches ir iface =
  sameTyConHead ir.irName ir.irOrigin iface.irName iface.irOrigin

export
ieEntriesForIface : List ImplRow -> IfaceRef -> List Mono -> List KeyEntry
ieEntriesForIface [] _ _ = []
ieEntriesForIface ((r@(ImplRow _ _ ir tys _ _ _)) :: rest) iface goals
  | ieRowIfaceMatches ir iface && ieRowHeadMatches tys goals =
    keyEntryOfRow r ++ ieEntriesForIface rest iface goals
  | otherwise = ieEntriesForIface rest iface goals

-- The METHOD-keyed candidate scan — the successor of `matchingEntriesGo` (deleted by
-- B-2.1-d).  Same
-- method-name membership test, same head match, same order.
--
-- ── #1182: the candidate key now has an interface component ──────────────────
-- It used to admit a row on `contains name ms` ALONE, so two impls of two
-- DIFFERENT interfaces that merely share a method SPELLING landed in ONE candidate
-- set and were ranked against each other by `pickMostSpecificEntry`.  Their head
-- vectors are ⊑-incomparable for a reason that has nothing to do with overlap, so
-- the selector fell to the head of the list and the declaration order of the two
-- `impl` BLOCKS decided which body ran — silently, at exit 0, on both engines
-- (`test/must_fail_fixtures/1182-two-ifaces-same-method-name-order-decides`: the
-- entry imports the method name from `a1` ONLY, so the occurrence has exactly one
-- binding, and it printed `2` — A2's body — under one ordering and `1` under the
-- other).  §6 C1 is a condition on the instances of ONE class (`match(IE, C τ̄)`);
-- a set drawn across two classes is a candidate-set DEFORMATION, not a program.
--
-- The admitted declaration is the SAME one `ieImplExistsForHeadGo` already tests
-- for the EXISTENCE read (`ieRowAdmittedBy`, `methodAdmissionHere`), through the same
-- comparator — `ieRowIfaceMatches` (`sameTyConHead` over `irName`/`irOrigin`), NOT a
-- bare `irName` compare and NOT `ieCountHeadByIfaceGo`'s deliberately spelling-only
-- test.  Selection is this shape's SECOND consumer; the existence read was its first.
--
-- `None` (this module's scope decides nothing for [name]) falls back to the
-- BARE-NAME ANSWER — every row passes, i.e. today's behaviour exactly.  The
-- derivation is `ieRowAdmittedBy`'s own doc-comment and is not restated here; the
-- consequence that IS specific to this site is recorded on `candsOneIface`.  Two or
-- more admitted declarations are `Some []`, not `None`, and admit no row
-- (`methodAdmissionHere`).
--
-- BEHAVIOUR-narrowing by design ([W-QUIETER] in the opposite direction): supplying
-- identity REMOVES candidates, so a program that used to dispatch by accident can now
-- fail to find an impl.  That is the point — the removed candidates implement an
-- interface the occurrence does not name.
--
-- the impl universe is unchanged (`DICT-SEMANTICS.md` §8 I5): this narrows what the
-- scan ASKS, never which modules' instances may answer.  `ieHeadRows … env` is still
-- the graph-global bucket, unfiltered.
ieEntriesForMethod : GraphCtx ->
  List ImplRow ->
  String ->
  Option (List IfaceRef) ->
  List Mono ->
  List KeyEntry
ieEntriesForMethod gctx [] _ _ _ = []
ieEntriesForMethod gctx ((r@(ImplRow _ _ ir tys _ ms _)) :: rest) name admitted goals
  | ieRowAdmittedBy ir admitted
    && ieRowHeadMatches tys goals
    && ieRowAnswersMethod gctx r ms name admitted =
    keyEntryOfRow r ++ ieEntriesForMethod gctx rest name admitted goals
  | otherwise = ieEntriesForMethod gctx rest name admitted goals

-- Does [r] answer [name]: does a call of [name] at this instance reach a body?  It
-- does for every method the impl supplies ([ms]), and for every method its
-- interface declares with a default the impl does not override — the slot the
-- disposition table publishes as `InheritedDefault` and lowering specializes for
-- this instance, so the call site owes that body the instance's `requires`
-- dictionaries exactly as it owes a supplied method them.  The inherited half is
-- read only when the occurrence's interface is known ([admitted]): without it the
-- scan cannot tell a default of the occurrence's interface from a same-spelled
-- method of another one.
ieRowAnswersMethod : GraphCtx ->
  ImplRow ->
  List String ->
  String ->
  Option (List IfaceRef) ->
  Bool
ieRowAnswersMethod gctx _ ms name None = contains name ms
ieRowAnswersMethod gctx r ms name (Some _) =
  contains name ms || ieRowInheritsDefault gctx r name

-- [name] is a defaulted method of [r]'s interface, as the impl's own module sees
-- that interface (the disposition producer's lookup, `dispositionRowsOfImpl`).  A
-- miss — an envelope with no interface registry — answers False, the supplied-only
-- reading.
ieRowInheritsDefault : GraphCtx -> ImplRow -> String -> Bool
ieRowInheritsDefault gctx r name =
  let (iface, _, _) = ieRowTriple r
  match (ceLookupAt
    (regKeyOfTab (ifaceTabKey iface.irOrigin iface.irName))
    (ieRowOrd r)
    gctx.declEnvsRef.value.deIfaces)
    None => False
    Some ceRow =>
      contains name (ceRowMethodNames ceRow)
        && not (contains name (ceRowRequired ceRow))

-- The head-plus-headless union, on `IE`: the goal head's own bucket merged with the
-- headless one, since a fully-general `impl C a` matches every goal but heads at
-- none (#1128 F-3b).  Its `KeyBuckets` predecessor was `candidateBucket`, deleted by
-- B-2.1-d; the two properties below were derived against it and still hold here.
--
-- FILTER-THEN-MERGE, where `candidateBucket` merged-then-filtered, and the two
-- are the same list: `mergeByDeclIdx` is a stable merge on an index, and dropping
-- elements cannot reorder the ones that remain or change which side wins a tie
-- (ties keep the LEFT operand, and the left operand is the head bucket on both
-- spellings).  Filtering first is what keeps the scan allocation-free on the rows
-- it rejects.
--
-- and it preserves the empty-headless fast path, which is the
-- path essentially every real lookup takes (no module of compiler/, stdlib/ or
-- sqlite/ declares a bare-tyvar impl head).  Two clauses of `mergeByDeclIdx` do
-- it: `xs [] = xs` returns the left list ITSELF — no copy, no allocation — and
-- `ieEntriesFor*` on the empty headless bucket is its own `[] => []` clause.  So
-- the fast path costs one call and one match, not a bucket copy.
export
ieCandidatesForIface : ImplEnv ->
  HeadKey ->
  IfaceRef ->
  List Mono ->
  List KeyEntry
ieCandidatesForIface env hk iface goals =
  mergeByDeclIdx
    (ieEntriesForIface (ieHeadRows (Some hk) env) iface goals)
    (ieEntriesForIface (ieHeadRows None env) iface goals)

export
ieCandidatesForMethod : GraphCtx ->
  ImplEnv ->
  HeadKey ->
  String ->
  Option (List IfaceRef) ->
  List Mono ->
  List KeyEntry
ieCandidatesForMethod gctx env hk name admitted goals =
  mergeByDeclIdx
    (ieEntriesForMethod gctx (ieHeadRows (Some hk) env) name admitted goals)
    (ieEntriesForMethod gctx (ieHeadRows None env) name admitted goals)

-- The inverse of `keyEntryOfRow`, and it is EXACT rather than heuristic: the
-- winner's `idx` IS its row's `instRefSeq`, a whole-graph counter unique within one
-- compile (`InstRef`), and the winner's row is filed in the bucket of its OWN head
-- — which is the `KeyEntry`'s own second field, minted by the same `headTyconTy`
-- `ieFileRowByHead` files under.  So ONE bucket scan finds it, with no fallback
-- arm to be silently wrong in.
export
ieRowOfEntry : ImplEnv -> Option KeyEntry -> Option ImplRow
ieRowOfEntry _ None = None
ieRowOfEntry env (Some (KeyEntry _ hd _ _ _ _ _ idx)) =
  ieRowWithSeq (ieHeadRows hd env) idx

ieRowWithSeq : List ImplRow -> Int -> Option ImplRow
ieRowWithSeq [] _ = None
ieRowWithSeq ((r@(ImplRow _ inst _ _ _ _ _)) :: rest) s
  | instRefSeq inst == s = Some r
  | otherwise = ieRowWithSeq rest s

-- The three `KeyEntry` fields the deleted `selectImplEntryByIface` handed the
-- router and the element-route legs — head pattern, FULL head vector, and the
-- impl's OWN `requires` ([] for a no-requires specific impl).  Kept as one
-- projection so the three consumers cannot drift in what they read off a row.
-- `None` on a `tys = []` row: unselectable by construction (`keyEntryOfRow`), so
-- that arm is totality, not a live fallback.
export
ieRowHeadTriple : Option ImplRow -> Option (Ty, List Ty, List Require)
ieRowHeadTriple None = None
ieRowHeadTriple (Some (ImplRow _ _ _ (tys@(headTy :: _)) reqs _ _)) =
  Some (headTy, tys, reqs)
ieRowHeadTriple (Some _) = None

-- fold each (iface, tys, reqs) triple into the universe, APPENDING to keep forward
-- declaration order within every bucket (matching the old whole-list first-match scan).
growImplUniverse : List (IfaceRef, List Ty, List Require) ->
  ImplUniverse ->
  ImplUniverse
growImplUniverse [] univ = univ
growImplUniverse (t :: rest) univ =
  growImplUniverse rest (insertUnivImpl univ t)

-- concrete receiver head (Some tag) → the "iface|tag" bucket; headless receiver (TyVar/function/empty head — None) → the iface's
-- headless bucket, which every lookup also consults (matchTyMono wildcard matches any).
insertUnivImpl : ImplUniverse ->
  (IfaceRef, List Ty, List Require) ->
  ImplUniverse
insertUnivImpl univ (iface, tys, reqs) =
  insertUnivImplKeys (oblIfaceKeys iface) tys reqs univ

-- ── the bare compatibility leg, and its drain condition ─────────────────────────
-- An impl is indexed under its interface's IDENTITY key — that is T2 — and, when it
-- HAS an identity, ALSO under the bare-spelling key.  The second index is not a
-- hedge about the impl side: it is the only thing that keeps a goal whose identity
-- is UNRECOVERABLE from missing every impl in the program.
--
-- MEASURED, and it is the finding that shaped this function.  With the identity
-- index ALONE, every predicate re-instantiated through a table with no identity keys
-- `TkBare` while the prelude's own impls key `TkIdent core`, so the lookup misses and
-- the obligation is reported as `No impl` — a FALSE REJECT, not a silent miss.  On
-- this tree that was: `medaka check` of a file containing nothing but
-- `main = println 1` → exit 1 with 9 rejects (`No impl of Applicative for Option`,
-- `Mappable`, `Thenable`, …, all mislocated to line 1); `check stdlib/core.mdk` → 7;
-- `stdlib/list.mdk` → 8; `stdlib/map.mdk` → 7; `check
-- compiler/driver/medaka_cli.mdk` → 37; and #1438's OWN control fixture (a legal
-- program the pin requires to keep working) rejected too.
--
-- the drain condition (#1507) — read it before deleting ANYTHING.  There were three
-- producers of a bare-spelling `IfaceRef` (`ifaceRefBare`), not two, the third being
-- `recordImplObligation`'s method-occurrence goal.  It records `iface`, the
-- identity-carrying `IfaceRef` `methodEntryHere` already held, instead of stripping it
-- via `ifaceRefBare iface.irName`, so every call site of `ifaceRefBare` is its
-- definition or a reader that holds only a spelling.
-- `ifaceForInferredId`'s `pendingDictApps` fallback mints none: it returns the
-- callee slot's `pdaIfaces` entry, declaration included.
--
-- **and the leg still may not be deleted — measured, not inferred from the
-- CENSUS ABOVE.**  Zero remaining `ifaceRefBare` *goal-producer* call sites does not by
-- itself mean zero remaining *bare* goals: `methodEntryHere` itself can hold an
-- `IfaceRef` whose `irOrigin` is `OriginUnresolved` — not because a producer stripped
-- it, but because nothing upstream ever stamped one — and `recordImplObligation`
-- forwarding that value FAITHFULLY (which is the whole point of U1c) still produces a
-- bare goal in that case.  Two such sources, one closed by construction and one that
-- is NOT:
--   * The compatibility leg's OWN worked example above (`main = println 1`,
--     `check stdlib/core.mdk`, …) is CLOSED as of #1227 for the ordinary "user program
--     imports the prelude" shape: `stampFlatTyOrigins`'s occurrence layer stamps a
--     prelude interface occurrence `core` even in flat/no-module-graph mode
--     (`flatTyOriginScope` carries the prelude's own interfaces), and
--     the former single-program checker additionally stamped core declarations
--     — so goal and impl agree on identity `core` and no bare goal is minted at all.
--     MEASURED on this branch (post-U1c): `check` of `main = println 1` and of
--     `compiler/driver/medaka_cli.mdk` are BOTH clean with the leg *removed* — this
--     shape genuinely needs no leg any more.
--   * `medaka check stdlib/core.mdk` **directly** (the prelude checking ITSELF, not a
--     user program importing it) is a DIFFERENT shape and is NOT closed.  Checking
--     historically, checking `core.mdk` as the entry reached that checker without a prefix
--     (the "prelude is already flattened into `prog`" arm — see this file's own
--     so `core.mdk`'s own interfaces and impls were
--     stamped with a scope that does not include core.mdk's own declarations at all —
--     they never get an identity, on EITHER layer.  MEASURED, on this branch, with the
--     leg *removed* (a throwaway experiment, reverted — not landed):
--     `medaka check stdlib/core.mdk` regresses from a clean exit 0 to **exit 1 with 32
--     `No impl of <Iface> for <Ty>` false rejects** (re-derive with `grep -c 'No impl'`
--     on the check output rather than trust this number; `Ord`/`Eq`/`Foldable`/`Mappable`/…,
--     the exact cascade shape this leg's worked example predicted). With the leg
--     restored it is clean again. `compiler/driver/medaka_cli.mdk` and
--     `main = println 1` stayed clean in BOTH arms of this experiment — the residual is
--     narrower than the pre-#1227 cascade, but it is real and it is live TODAY, after
--     U1c, not a hypothetical.
--
-- So: **do not delete this leg.**  U1c closes the THIRD `ImplUniverse` goal
-- producer, which is a real and necessary step, but it is NOT the sole remaining
-- condition — a self-checking flat prelude is a fourth source of bare goals this leg
-- protects, independent of any producer, and it has no owner yet. Do not trust a census
-- of `ifaceRefBare` call sites to answer this question by itself; re-run the experiment
-- above (temporarily drop the bare key from `oblIfaceKeys`'s non-`OriginUnresolved`
-- arm, rebuild, `check stdlib/core.mdk`) before believing the leg is dead weight.
--
-- CONSEQUENCE FOR #1438.  U1b drained the PINNED INSTANCE (a signed forwarder,
-- reached through the signature `=>` slot channel U1b widened); the CLASS did not
-- drain with it — deleting one signature line reposed the same goal through the bare
-- METHOD OCCURRENCE producer this file no longer has, and it was a silent accept
-- (`check` exit 0, `build` exit 0, built binary SEGFAULTS at 139) right up to U1c. U1c
-- closes that remaining reach: the minimal pair that used to live at
-- `test/must_fail_fixtures/1507-xmod-iface-name-collision-method-occurrence/` now
-- REJECTS and the pin is retired, replaced by the positive pair
-- `test/dict_fixtures/i4-xmod-method-occurrence-{foreign-iface-rejected,
-- own-iface-control}` (alongside U1b's own
-- `i4-xmod-sig-constraint-{foreign-iface-rejected,own-iface-control}`). **#1438 itself
-- stays open** pending confirmation that no other reach of the same collision survives
-- (see #1507's own issue thread) — this comment records the obligation-channel half,
-- not the whole issue.
--
-- Order within a bucket is preserved per key (`mregAppendK` appends), so
-- `findMatchingImplReqsU`'s declaration-order first-match is unchanged on either leg.
insertUnivImplKeys : List TabKey ->
  List Ty ->
  List Require ->
  ImplUniverse ->
  ImplUniverse
insertUnivImplKeys [] _ _ univ = univ
insertUnivImplKeys (ifk :: rest) tys reqs univ =
  insertUnivImplKeys rest tys reqs (insertUnivImplAt ifk tys reqs univ)

-- the interface keys an IMPL is indexed under: the identity key, plus the bare
-- spelling key when the two differ (an identity-less occurrence mints the bare key
-- from `tabKeyOf` already, so the list is a singleton there and nothing is doubled).
oblIfaceKeys : IfaceRef -> List TabKey
oblIfaceKeys ir = match ir.irOrigin
  OriginUnresolved => [TkBare NsIface ir.irName]
  _ => [oblIfaceKey ir, TkBare NsIface ir.irName]

insertUnivImplAt : TabKey ->
  List Ty ->
  List Require ->
  ImplUniverse ->
  ImplUniverse
insertUnivImplAt ifk tys reqs (ImplUniverse conc hl) = match univReceiverTag tys
  Some hk =>
    ImplUniverse
      (mregAppendK (regKeyNTab [ifk, dispHeadTab hk]) (tys, reqs) conc)
      hl
  None => ImplUniverse conc (mregAppendK (regKeyOfTab ifk) (tys, reqs) hl)

-- ✅ #1446 (T2): the obligation channel'S interface key is an identity.  `Predicate`
-- carries an `IfaceRef` (P1), so `checkOneCallObligation`'s goal side supplies the
-- same `TyConOrigin` the writer reads off `DImpl.implOrigin`, and this key is minted
-- through the ONE total mint (`tabKeyOf`) on both sides.
--
-- THIS BLOCK'S prediction was measured-wrong in direction, and the correction is
-- the reason the ledger says so rather than being quietly deleted.  It said keying the
-- writer while the readers stayed bare would "silently switch the whole missing-impl
-- obligation check off" — a `loud → silent` severity increase with no golden moving.
-- It is the OPPOSITE.  This is a PAYLOAD table, not a GATE: a missed lookup means "no
-- impl exists", i.e. a REJECT.  Measured twice — #1112's 2026-08-09 P1 experiment
-- (writer-only prototype: `make check-self` exit 1, 634 `No impl of …`, 61/61
-- behaviour goldens moved) and again here on this tree, where leaving just TWO goal
-- producers identity-less made `medaka check` of a file containing only
-- `main = println 1` exit 1 with 9 rejects.  The reasoning that produced the wrong
-- prediction generalised from a GATE-shaped sibling (`ifaceRegistered`, `Unit`-valued)
-- while describing a payload-shaped table; `.claude/workstreams/TYPECHECK.md` trap 11
-- now carries the rule.
--
-- the head half still does not move, and that is not symmetry-for-its-own-sake:
-- see `dispHeadTab` for the measured derivation (#1317 T1 / the closed S0 #1277).
-- The `NsIface` tag is not decoration either: it is what stops a future table that
-- mixes namespaces from colliding a bare interface name with a bare type name of the
-- same spelling.
--
-- AN IDENTITY-less goal is still legal and still matches by spelling — see
-- `insertUnivImplKeys` for the compatibility leg, the `ifaceRefBare` producers that
-- still need it (U1b/#1482 retired two of three; #1507 owns the last), and the
-- corrected condition under which it is deleted.
export
oblIfaceKey : IfaceRef -> TabKey
oblIfaceKey ir = tabKeyOf NsIface ir.irOrigin ir.irName

-- The head component of every dispatch key is bare (spelling-keyed), not
-- identity-keyed, because the GOAL side cannot match an identity there: a
-- `Mono.TCon`'s origin field is a carrier every comparison (`unifyN`
-- included) ignores, so two modules' same-named types unify regardless of
-- which mint supplied the origin, and which origin survives a unify is an
-- artifact of link direction rather than a function of the type. Supply
-- closes for the extern population (`externSchemes` stamps under
-- `externTyOriginScope`, #1280); the flat/loader-less driver's own
-- user-module declarations remain unstamped (#1115, E-1, open) because that
-- driver has no loader-derived module id and an invented one would be made
-- permanent by `stampTyHead`'s immunity rule.
--
-- The `ImplUniverse`/obligation channel (`insertUnivImpl` / `univConcreteBucket`
-- / `oblKeyParts`) has already moved to identity keys (#1446).
--
-- The rigid arm (`headKeyName (HkRigid n) = n`) is keyed deliberately too: a
-- rigid may legally be spelled `__tupleN__` (`Mono.TRigid`'s naming rule)
-- and must still land in the tuple head's bucket.
--
-- This function is the ledger for every dispatch decision taken on a head's
-- spelling, not only for keys built from one: a retest that compares heads
-- without going through it silently strengthens from spelling-equality to
-- identity-equality and reroutes calls whose receiver came from an
-- unstamped extern signature (the `implExistsForHeadGo` S0). Enrolment rule: if a site's answer would change
-- when the head half becomes an identity, it goes through this function.
-- See `compiler/TYPECHECK-TARGET-ARCHITECTURE.md` § "9.4 Data shape, key,
-- and identity" for the full derivation.
--
--   grep -nw dispHeadTab compiler/types/typecheck.mdk
export
dispHeadTab : HeadKey -> TabKey
dispHeadTab hk = TkBare NsType (headKeyTag hk)

-- the receiver-position head tycon tag of an impl's head types (None for a headless
-- receiver or an empty head list) — the SAME tag `headTyconMono` computes for a
-- dispatch mono, so an impl and the args it matches land under the same key.
univReceiverTag : List Ty -> Option HeadKey
univReceiverTag (headTy :: _) = headTyconTy headTy
univReceiverTag [] = None

export
ieRowOfIface : IfaceRef -> ImplRow -> Bool
ieRowOfIface iface (ImplRow _ _ ir _ _ _ _) = ieRowIfaceMatches ir iface

export
ieRowTys : ImplRow -> List Ty
ieRowTys (ImplRow _ _ _ tys _ _ _) = tys

-- the dispatch var name of each method-level constraint (constraintSlotDispatchVar),
-- in declaration order — the name-returning mirror of methodConstraintSlotIds (which
-- returns the ids).  One name per constraint slot.
export
methodLevelConstraintVarNames : List String -> Ty -> List String
methodLevelConstraintVarNames typarams (TyConstrained cs t) =
  flatMap (constraintSlotDispatchVar typarams) cs
    ++ methodLevelConstraintVarNames typarams t
methodLevelConstraintVarNames typarams (TyEffect _ _ t) =
  methodLevelConstraintVarNames typarams t
methodLevelConstraintVarNames _ _ = []

export
removeAllS : List String -> List String -> List String
removeAllS drop xs = filter (x => not (contains x drop)) xs

-- Resolve an impl body's declared method type from the identity-keyed class row at
-- this module's ordinal.  The row owns the interface typarams and keeps each raw Ty
-- beside its graded scope, so the body cannot be checked under another interface's
-- same-spelled method.  Reading through ceLookupAt retains declaration visibility and
-- avoids a whole-program scan per impl method.
export
ceMethodTyAt : IfaceRef ->
  String ->
  Int ->
  ClassEnv ->
  Option (List String, Ty, List (String, List Kind))
ceMethodTyAt iface mname cur ce =
  let key = regKeyOfTab (ifaceTabKey iface.irOrigin iface.irName)
  match ceLookupAt key cur ce
    Some row => ceMethodTyIn (ceRowTyparams row) mname (ceRowMethods row)
    None => None

ceMethodTyIn : List String ->
  String ->
  List (String, Ty, List (String, List Kind)) ->
  Option (List String, Ty, List (String, List Kind))
ceMethodTyIn _ _ [] = None
ceMethodTyIn typarams mname ((name, mty, scope) :: rest)
  | name == mname = Some (typarams, mty, scope)
  | otherwise = ceMethodTyIn typarams mname rest

-- Declaration identity for numeric anchors, predicate slots, and obligation keys.
-- Resolved occurrences compare by (module, name); two unresolved occurrences in
-- the former unstamped driver compared by spelling. A resolved occurrence never matches an
-- unresolved one. Reuse the declaration-key comparison so these consumers agree
-- with the identity index used by implementation-body inference.
export
sameIfaceDecl : IfaceRef -> IfaceRef -> Bool
sameIfaceDecl a b = tabKeyEq (oblIfaceKey a) (oblIfaceKey b)

-- Compatibility projection for the existing term environment and scheme output.
export
legacyMethodSchemes : List MethodSchemeRow -> List (String, Scheme)
legacyMethodSchemes [] = []
legacyMethodSchemes (row :: rest) =
  (row.msrName, row.msrScheme) :: legacyMethodSchemes rest

-- The method-context table's key: the declaring interface's identity and the
-- method's declared name, rendered through the method-row registry's own key.
export
methodSlotKey : IfaceRef -> String -> String
methodSlotKey iface method = regKeyRender (methodRowKey iface method)

-- The environment before any declaration, in the module [mctx]: the builtin
-- constructors and nothing else.
export
envFor : ModuleCtx -> TcEnv
envFor mctx = withCtors mctx builtinCtors

-- name-membership set, built ONCE, so `keepGroupNames` is O(log n)/ref instead of
-- O(names)/ref (the dep-graph build was O(names²·refs)). Output-order-preserving:
-- `keepGroupNames`'s `filterList` is unchanged, only its membership test is faster.
export
namesToSet : List String -> OrdMap Unit -> OrdMap Unit
namesToSet [] m = m
namesToSet (n :: rest) m = namesToSet rest (omInsert n () m)

-- does ANY impl of [iface] head at [hk], or head at nothing at all?  The existence twin
-- of `ieCandidatesForIface`, and it reads the same two buckets in the same order for the
-- same reason: a fully-general `impl C a` matches every goal but heads at none (#1128
-- F-3b), so the headless bucket is part of candidacy at every head.
export
ieHeadCandidateExists : ImplEnv -> IfaceRef -> HeadKey -> Bool
ieHeadCandidateExists env iface hk =
  ieAnyRowForIface (ieHeadRows (Some hk) env) iface
    || ieAnyRowForIface (ieHeadRows None env) iface

-- `ieRowIfaceMatches`, NOT a bare `irName` compare — the SAME comparator
-- `ieEntriesForIface` admits a candidate row with, for the reason derived on its header
-- (two modules can spell one interface name and mean two interfaces).
ieAnyRowForIface : List ImplRow -> IfaceRef -> Bool
ieAnyRowForIface [] _ = False
ieAnyRowForIface ((ImplRow _ _ ir _ _ _ _) :: rest) iface =
  ieRowIfaceMatches ir iface || ieAnyRowForIface rest iface

export
ifaceMethodNames : List IfaceMethod -> List String
ifaceMethodNames [] = []
ifaceMethodNames ((IfaceMethod n _ _ _) :: rest) = n :: ifaceMethodNames rest

-- `public export data` / `public export record` decls — re-registered in every
-- importing module so their constructors + field layout are in scope.
-- ALSO carries public DInterface (so the multi-module path can register the
-- interface's method→iface-param map for #11 obligation checking — a numeric
-- literal's `fromInt`/`Num` obligation, recorded via recordImplObligation, needs
-- `Num`'s entry in methodEntryHere), AND public DImpl (so checkImplObligations'
-- implHeadsOf sees core's `impl Num Int` etc. — without it a legitimately Int-typed
-- literal's Num obligation finds no matching impl head and is spuriously rejected).
-- registerAllData and buildOracle read only DData, so the extra DInterface/
-- DImpl entries are inert for them.
-- A-3.2b (#1512): the PREDICATE half, split out so `declEnvVisibleTo`'s publicity
-- conjunct and this filter cannot drift.  The ruling on #1512 requires the flag be
-- `publicDataDecls`' predicate VERBATIM, `DNewtype`'s absence included; the way to
-- guarantee "verbatim" is not to copy it but to make `publicDataDecls` itself the
-- filter over this one function, which is what the two lines below do.
--
-- `DNewtype`'s absence is deliberate, not an oversight to be tidied up: a newtype
-- constructor is module-private by design (`public` is a parse error on `newtype`),
-- and admitting one here would leak newtype constructors across module boundaries —
-- draining #1311/#1305 in the loud→silent direction, i.e. a severity INCREASE.
-- `DAttrib` is absent for the same reason it always was: an attributed decl is not
-- unwrapped here, so it does not publish.  Neither absence may be "fixed" without
-- owning those issues.
export
publicDataDecl : Decl -> Bool
publicDataDecl (DData { dataVis = VisPublic }) = True
publicDataDecl (DInterface { pub = True, ... }) = True
publicDataDecl (DImpl { pub = True, ... }) = True
publicDataDecl (DTypeAlias { tyAliasPub = True }) = True
publicDataDecl _ = False

-- #1110: the decl passes THROUGH rather than being rebuilt, or the acquired
-- `dataOrigin` is dropped on the export path — `filterList` preserves that by
-- construction, where the old per-arm `d :: …` form preserved it by remembering to.
export
publicDataDecls : List Decl -> List Decl
publicDataDecls decls = filterList publicDataDecl decls

-- A-3.2b (#1512) slice 2: the third projection, and it is A PEER OF
-- `publicDataDecl`, NEVER A widening of it.  What a module published to the RETIRED
-- `CrossRun.universeDataParamKinds` was NOT `publicDataDecls`: it was `publicDataDecls`
-- (whose only kind-bearing arm is `DData VisPublic`) PLUS a second, kinds-only pass
-- over `DData VisAbstract` and `DNewtype { newtypePub = True }`.  Reusing
-- `publicDataDecl` for the kind seed would therefore LOSE an opaque type's parameter
-- kinds cross-module, which is #804/#1028 exactly: every reader that asks "is slot i
-- row-kinded?" misses, and each one fails differently — `fromAstTypeApp` erases a
-- written row SILENTLY, the bare-row spelling draws a FALSE `T-EFFECT-KIND-MISMATCH`, and
-- #784's `checkUndeterminedRetEffVars` cannot see `Async e a` pin `<e>` and rejects the
-- method.  `stdlib/async.mdk`'s `Async` is that shape; `test/check_module_fixtures/
-- opaque_param_kinds_xmod/` and its `_newtype` sibling are the fixtures.
--
-- A kind is not A FIELD, which is why this may be wider than `publicDataDecl` without
-- leaking anything: "slot 0 of `Async` has kind Row" says nothing about `Done` or
-- `Suspend`, so the abstraction `export` buys is intact.  Only `declEnvKindEntries`
-- consumes this projection, and it mints kinds and NOTHING else — no ctor schemes, no
-- `RecordInfo`, no `fieldOwnersRef` entry.  Promoting these decls in `publicDataDecl`
-- instead would have been the one-line "fix" that leaks the constructors (and drains
-- #1311/#1305 loud→silent).
--
-- NOT `VisPrivate`: a private type's name is not in scope for an importer and the
-- kind table is not import-scoped, so publishing it could only collide a name nobody
-- can spell against one they can.  NO `DAttrib` ARM: neither source it replaces had
-- one — see `declEnvKindEntries` and #1586.  `export newtype` is in the same bucket
-- as `VisAbstract` and has no workaround at all: `public` is a parse error on `newtype`,
-- so its constructor is unconditionally module-private, which is why the third arm keys
-- on `newtypePub` and not on a visibility that does not exist.
--
-- what the identity key does and does not buy — inherited verbatim from
-- `registerOpaqueParamKinds`, which this projection replaced (A-3.2b), because a reader
-- who believes the retired version of the second bullet concludes there is nothing here
-- to fix:
--   * KEYING.  Since #1111 A-2.3 the key is a `TabKey` (see `tyTabKey`), so an opaque
--     type's kinds are registered under ITS OWN module's identity and are reachable only
--     from an occurrence that resolved to that module.  Two same-named types in
--     unrelated modules no longer share a key on the module path.
--   * THE GUARD.  An older note claimed "every hot reader additionally guards on
--     `listLen kinds == listLen args`, so a same-name/different-arity clash abstains
--     rather than mis-kinds".  It does NOT.  A 2×5 matrix (shadower arity 0/1/2/3 plus a
--     control × the row spelled WRAPPED `Box (<Stdout> Unit) Int` or BARE
--     `Bx <Stdout> Int` at the use site) moved the outcome in NEITHER direction: on the
--     guard-PASSING path the winning entry's kinds are all-`KType`, so `foldAppKinds`
--     erases the row exactly as `appFallback` does.  What actually selected
--     silent-vs-loud was the SPELLING of the row at the use site — `fromAstTypeE`'s
--     `TyEffect` arm unwraps a wrapped row to a real type and keeps inferring silently
--     (#1069), while its `TyRow` arm has no wrapped type and raises
--     `T-EFFECT-KIND-MISMATCH` (#1090).  Same table, same collision, opposite symptoms.
--   * The flat/single-file path is NOT re-keyed and still competes by bare name; that is
--     the Module-path-only bound recorded on `tyTabKey`, drained by #1115 (E-1).  It is
--     also why `declEnvSeedChain`'s fold direction is reproduced but currently
--     unobservable — see its note.
export
kindPublicDataDecl : Decl -> Bool
kindPublicDataDecl (DData { dataVis = VisPublic }) = True
kindPublicDataDecl (DData { dataVis = VisAbstract }) = True
kindPublicDataDecl (DNewtype { newtypePub = True }) = True
-- #2121: an exported alias publishes its declared kinds (see `declEnvKindEntries`).
kindPublicDataDecl (DTypeAlias { tyAliasPub = True }) = True
kindPublicDataDecl _ = False

export
ordinaryEnvBinding : Scheme -> EnvBinding
ordinaryEnvBinding scheme = EnvBinding {
  ebValue = ordinaryValueScheme scheme,
  ebMethodRow = None,
  ebStandalone = None,
}

ordinaryValueScheme : Scheme -> ValueScheme
ordinaryValueScheme scheme =
  ValueScheme { vsScheme = scheme, vsDeclared = None }

export
methodEnvBinding : MethodSchemeRow -> EnvBinding
methodEnvBinding row = EnvBinding {
  ebValue = ordinaryValueScheme row.msrScheme,
  ebMethodRow = Some row,
  ebStandalone = None,
}

export
lookupMethodRowById : IfaceRef ->
  String ->
  Registry MethodSchemeRow ->
  Option MethodSchemeRow
lookupMethodRowById iface n rows = match regLookupK (methodRowKey iface n) rows
  Some row =>
    if sameTyConHead
      row.msrIface.irName
      row.msrIface.irOrigin
      iface.irName
      iface.irOrigin then
      Some row
    else
      None
  None => None

-- `sameTyConHead`, not a bare `irName` compare: this is a LOOKUP, where a false HIT
-- is silent wrongness (the wrong interface's scheme), so absence-makes-no-claim plus
-- name equality is the comparator the file's own rule (`cohSameIface`'s header) picks
-- for this direction.  A false MISS costs only the fall-back to today's answer.
export
lookupSchemeById : IfaceRef ->
  String ->
  Registry MethodSchemeRow ->
  Option Scheme
lookupSchemeById iface n rows =
  map (row => row.msrScheme) (lookupMethodRowById iface n rows)

methodRowKey : IfaceRef -> String -> RegKey
methodRowKey iface method = regKeyNTab [
  ifaceTabKey iface.irOrigin iface.irName,
  TkBare NsMethod method,
]

export
methodRowsByIdentity : Bool ->
  List MethodSchemeRow ->
  Registry MethodSchemeRow ->
  Registry MethodSchemeRow
methodRowsByIdentity _ [] acc = acc
methodRowsByIdentity includeAll (row :: rest) acc =
  if not includeAll && not (methodRowCanCarry row) then
    methodRowsByIdentity includeAll rest acc
  else
    let key = methodRowKey row.msrIface row.msrName
    let acc2 = match regLookupK key acc
      Some _ => acc
      None => regInsertK key row acc
    methodRowsByIdentity includeAll rest acc2

-- ── IMPORT-SCOPED per-module seeding ─────────────────────────────────────
-- The multi-module drivers must NOT flat-seed the cumulative UNION of every
-- dependency's public schemes into each module's env: omInsert is last-write-wins,
-- so a later-loaded dependency's same-named binding (e.g. `string.reverse :
-- String -> String`) silently overwrites an earlier one (`list.reverse :
-- List a -> List a`) — mis-typing a module that explicitly `import list.{reverse}`.
-- Instead each module's seed is built from ONLY the names its own `DUse` decls
-- import, looked up in the SPECIFIC dependency they name.  The implicit prelude
-- (runtime + core) is always fully in scope and is threaded separately as baseSeed.

-- the bare member names a single `import` form names from its dependency
-- (BEFORE mangle-key resolution):
--   UseGroup (_, ms) → the member names         (import dep.{a, b, c})
--   UseWild _        → ALL of the dep's schemes  (import dep.*)
--   UseName ns       → [last ns] if dotted (import a.b.name), else [] (bare name)
--   UseAlias _       → [] (alias only — no auto-imported value names)
-- `None` ⇒ wildcard (every scheme); `Some names` ⇒ exactly those member names.
-- (ORIGIN, LOCAL) per imported member.  They differ only under a member alias
-- (`import m.{a as b}`): the SCHEME is looked up under the origin `a` in the
-- dependency, and bound into this module's env under the local `b`.
export
importedBindings : UsePath -> Option (List (String, String))
importedBindings (UseGroup _ ms) = Some (map memberBinding ms)
importedBindings (UseWild _) = None
importedBindings (UseName ns)
  | listLen ns > 1 = Some [selfBinding (lastComponent ns)]
  | otherwise = Some []
-- A module alias enumerates the dependency's schemes, so it cannot be expressed as a
-- fixed member list — importFormSchemes handles it directly.
importedBindings (UseAlias _ _) = Some []

-- The names an import form binds, as the resolver counts them
-- (`importedNamesMM`): a member list binds its locals, a single dotted name its
-- last component, an alias nothing bare, and a wildcard (`None`) every name it
-- reaches.
export
boundNames : UsePath -> Option (OrdMap Unit)
boundNames path =
  map (rows => omFromNames (map snd rows) omEmpty) (importedBindings path)

memberBinding : UseMember -> (String, String)
memberBinding m = (useMemberOrigin m, useMemberLocal m)

-- The definer key every fn-side qual table uses for the implicit prelude is `""`, not
-- `"core"` (`modInScope`, `selfDeclArities`, `cmCheckWorker`), because the prelude is
-- checked with the empty module id.  An import path spells it `core`, so a prelude
-- import read under its SPELLED id matches no row at all and yields no context and no
-- dict arity.  Every other module ids identically in both, so this is the whole of the
-- translation.
export
importTableMid : UsePath -> String
importTableMid path =
  let mid = useModId path
  if mid == "core" then "" else mid

-- ── #1111 A-2.5b: the method-IDENTITY rows a module carries (`meExports`) ──
-- `mid → [(name the row carries this method under, the Ident of the interface
-- declaration it means)]`, folded dependency-first by `methodEnvGo` so an
-- `export import src.{…}` resolves against `src`'s already-folded row, at any depth.
-- This is what lets `usePathWitnesses` answer "does this import bring in THAT
-- declaration" rather than "does the spelling match" (#1272 / #1275).
--
-- Resolve derives the same fact (`ModuleExports.expIfaceMethods`), but the emitter
-- child never runs resolve, so typecheck derives it from the stamped decls instead.
-- It must be built after `stampGraphTyOrigins`, which `buildDeclEnvs`' call site in
-- `graphPreamble` guarantees.
--
-- The safety property, a conjunction: (a) `GraphCtx.declEnvsRef`, which carries this
-- index, is overwritten whole at every Module-mode driver entry — there is one,
-- `graphPreamble` — never merged, so compile N's rows cannot reach compile N+1, and a
-- driver that skipped the write would read an empty index; (b) nothing resets it in
-- between — nothing resets a `GraphCtx` field within a drive, which is why the
-- index is not on `CrossRun` (`mintGraphCtx` cleared it between write and read: F1).  Both
-- halves, or neither.
--
-- No `pub` filter: a private interface's methods are carried too (F3), unlike
-- resolve's `expIfaceMethodsDirect`.  Under a wildcard import `usePathBindsName` is
-- True for every name, so such a declaration can be admitted beside the one the
-- module names.  The same absence lets `usePathWitnesses` drop a separate
-- declaring-module witness: `import dep.{mth}` where `dep` declares the interface is
-- the row `dep` seeds itself with.
--
-- The (method name, declaring identity) pairs [decls] DECLARES.  Only `DInterface`
-- contributes, and a declaration with no module id contributes nothing (honest
-- absence, §8 I6.3), as in `methodRowsOfIface`.
declMethodIdents : List Decl -> List (String, Ident)
declMethodIdents decls = flatMap declMethodIdentsOf decls

declMethodIdentsOf : Decl -> List (String, Ident)
declMethodIdentsOf (DAttrib _ d) = declMethodIdentsOf d
declMethodIdentsOf (DInterface { methods, ifaceOrigin, ... }) =
  flatMap (m => ifaceMethodIdentPair ifaceOrigin m) methods
declMethodIdentsOf _ = []

ifaceMethodIdentPair : TyConOrigin -> IfaceMethod -> List (String, Ident)
ifaceMethodIdentPair origin (IfaceMethod mname _ _ _) =
  match mkIdent NsMethod origin mname
    None => []
    Some i => [(mname, i)]

-- the identities a module RE-EXPORTS via `export import src.{…}` (`DUse True`), taken
-- from [acc] — the dependency's already-folded row.
--
-- `local` and `origin` are ALWAYS EQUAL here, so `reexportRenamed` never renames.
-- The parser refuses `export import m as A` and `export import m.{a as b}`
-- (`compiler/frontend/parser.mdk:2369,2376`), so no program renames on re-export.  The
-- generality is kept (it costs one `filterList`, and it is the shape a future
-- `export import … as …` would need) but it is dead today and must not be cited as
-- behaviour.
reexportedMethodIdents : OrdMap (List (String, Ident)) ->
  List Decl ->
  List (String, Ident)
reexportedMethodIdents acc decls = flatMap (reexportedMethodIdentsOf acc) decls

reexportedMethodIdentsOf : OrdMap (List (String, Ident)) ->
  Decl ->
  List (String, Ident)
reexportedMethodIdentsOf acc (DAttrib _ d) = reexportedMethodIdentsOf acc d
reexportedMethodIdentsOf acc (DUse True path _) =
  match omLookup (useModId path) acc
    None => []
    Some src => match importedBindings path
      -- `export import src.*` re-exports every one of src's methods, under their own names
      None => src
      Some bs => flatMap (b => reexportRenamed b src) bs
reexportedMethodIdentsOf _ _ = []

reexportRenamed : (String, String) ->
  List (String, Ident) ->
  List (String, Ident)
reexportRenamed (origin, local) src =
  map (e => (local, snd e)) (filterList (e => fst e == origin) src)

-- ── #1354 unit A: the interface rows a module carries (`meIfaceExports`) ──────
-- `mid → [(interface name as this module provides it, the method names it admits)]`,
-- folded dependency-first by `methodEnvGo`.  Read only through `nameableIfaceRows`.
--
-- This is S1's INTERFACE operand (`SHADOW-SEMANTICS.md` §1.0: "is this interface one
-- `M` can name?"), a TYPE-namespace question, which is why it is not derived from
-- `meExports`: matching re-export member lists against METHOD names drops
-- `export import ifc.{Sizeable}` on a chain (S1-CHAIN, #1380), and admitting a
-- dependency's whole row on any import makes `import smod.{sf}` name `Sizeable`
-- (#1353).  `selectIfaceRows` applies the per-method S1-NS selection on both the
-- import and the re-export side.
--
-- Built here rather than taken from resolve for the same reason as `meExports` (the
-- emitter child never runs resolve, #1382).  No `pub` filter either; for this
-- predicate that is the fail-open direction (it can only add shadow-hood), which is
-- the direction `nameableIfaceShadows` argues for.
--
-- The (interface name, its method names) pairs [decls] DECLARES.
export
ifaceMethodRows : List Decl -> List (String, List String)
ifaceMethodRows decls = flatMap ifaceMethodRowOf decls

-- C5: every interface method name declared anywhere in [decls] (unwrapping DAttrib).
export
allIfaceMethodNames : List Decl -> List String
allIfaceMethodNames [] = []
allIfaceMethodNames ((DAttrib _ d) :: rest) =
  allIfaceMethodNames [d] ++ allIfaceMethodNames rest
allIfaceMethodNames ((DInterface { methods, ... }) :: rest) =
  ifaceMethodNames methods ++ allIfaceMethodNames rest
allIfaceMethodNames (_ :: rest) = allIfaceMethodNames rest

ifaceMethodRowOf : Decl -> List (String, List String)
ifaceMethodRowOf (DAttrib _ d) = ifaceMethodRowOf d
ifaceMethodRowOf (DInterface { name, methods, ... }) =
  [(name, ifaceMethodNames methods)]
ifaceMethodRowOf _ = []

-- the rows a module RE-EXPORTS via `export import src.{…}` (`DUse True`), taken from [acc]
-- — the dependency's already-folded row, which is what makes a chain of any depth resolve.
reexportedIfaceMethods : OrdMap (List (String, List String)) ->
  List Decl ->
  List (String, List String)
reexportedIfaceMethods acc decls = flatMap (reexportedIfaceMethodsOf acc) decls

reexportedIfaceMethodsOf : OrdMap (List (String, List String)) ->
  Decl ->
  List (String, List String)
reexportedIfaceMethodsOf acc (DAttrib _ d) = reexportedIfaceMethodsOf acc d
reexportedIfaceMethodsOf acc (DUse True path _) =
  match omLookup (useModId path) acc
    None => []
    Some src => selectIfaceRows path src
reexportedIfaceMethodsOf _ _ = []

-- ── S1-NS (RULED 2026-08-08): the rows of [src] a use-path admits ──────────
-- `docs/spec/SHADOW-SEMANTICS.md` S1-NS (a): S1's right operand is the PER-METHOD UNION of
-- the two namespaces.  A row `(I, ms)` is NARROWED, not merely kept or dropped:
--
--   * WILDCARD (`import m.*`) — everything the dependency provides, so the whole row.
--   * MODULE ALIAS (`import m as A`) — the whole row, on the VALUE arm: `A.n` is a legal
--     call for every method `n`.  An alias cannot put a TYPE name in scope (alias-qualified
--     names in type position are a parse error), so it admits nothing on the type arm — but
--     a union needs only one arm.
--   * MEMBER LIST — the TYPE arm admits the WHOLE row when the list names the interface `I`
--     (an author who can write `impl I T` can write every method of `I`); otherwise the
--     VALUE arm admits ONLY the methods the list actually names.
--   * BARE (`import m`) or DOTTED (`import a.b.n`) — `importedBindings` answers `Some []` for
--     the bare form, so the member list is EMPTY and admits NOTHING.  Stated because the
--     three bullets above read as an exhaustive enumeration and this is the fourth arm:
--     reading an empty member list as "binds everything" (the way a wildcard legitimately is
--     read) is a real mistake, and `i15_importer_iface_one_hop_unbound/bare.mdk` exists to
--     catch it.  A bare import brings IMPLS into scope, which S2 governs; it binds no NAMES,
--     which is all S1 asks about.
--
-- per method, not per row, and this is measured rather than stylistic: `import ifc.{tag}`
-- leaves a sibling method UNBOUND (*"Unbound variable: size. (Did you forget to
-- 'import ifc.{size}'?)"*), so admitting the whole row because the list names ONE method
-- makes a DIFFERENT name dispatch-eligible on evidence that says nothing about it.  That
-- over-approximates both namespaces at once, and it is what silently replaced a module's own
-- top-level `size` with a foreign impl body (777 where 42 is correct, exit 0, no diagnostic
-- on any verb — `test/shadow_fixtures/d23_definer_sibling_method_silent/`).
--
-- one selector, used on the import arm **AND** THE RE-EXPORT ARM.  S1-NS makes the two
-- symmetric: `export import ifc.{size}` must admit `size` one hop down exactly as
-- `export import ifc.{Sizeable}` admits the row.  An implementation whose arms evaluate
-- different namespaces is enumerated NON-CONFORMANT, and it was live here — a method-name
-- re-export chain that `main` builds and runs at 50 failed `build` with `E-PANIC: arg-tag
-- dispatch on impl type that owns no constructors`.  Keeping this ONE function is what makes
-- that unrepresentable rather than merely fixed (`i20_importer_method_reexport_chain/`).
export
selectIfaceRows : UsePath ->
  List (String, List String) ->
  List (String, List String)
selectIfaceRows (UseAlias _ _) src = src
selectIfaceRows path src = match importedBindings path
  None => src
  Some bs => flatMap (r => narrowRowToNamed (map fst bs) r) src

-- TYPE arm: the list names the interface → the whole row.  VALUE arm: it does not → only
-- the methods it names.  An empty narrowing contributes no row at all.
--
-- known deviation from S1-NS (a)(ii), and it is observable today.  [named] is built from
-- the member ORIGIN spellings (`map fst bs`), so `import ifc.{size as sz}` admits `size` —
-- the name in the DEPENDENCY — while the only name this module can write for that method is
-- `sz`.  S1-NS (a)(ii) says the admitted name must be the CALLABLE one.
--
-- An earlier version of this note claimed the deviation was "unobservable today because
-- member-ALIASED method imports are independently broken".  both halves are false, measured:
-- `import ifc.{size as sz}` then `sz "ab"` prints 7, so aliased method imports work fine;
-- and a program does reach the difference — with a standalone `size` imported from `fmod`,
-- adding `import ifc` prints 99 while adding `import ifc.{size as sz}` prints 7, the two
-- differing only in that second import line.  Under the clause, 99 is correct for BOTH: the
-- alias case gives this module no way to write `size` for the method, so `size` unambiguously
-- denotes `fmod`'s standalone.
--
-- not fixed here, deliberately.  It is NOT a regression — base prints 7 too, so the alias arm
-- is exactly where this unit changes nothing — and any fix is a behaviour change on a fresh
-- axis that no ruling has been written for.  Pinned instead, so it self-drains:
-- `test/shadow_fixtures/i22_importer_member_alias_not_nameable/`.
--
-- A member alias reaches this selector as written on every driver
-- (`renameAliasedMethodsIn` rewrites only module aliases), so `fst b` and `snd b` differ
-- for an aliased member here, and keying the value arm on `snd` is not a no-op by
-- construction.  It would change what a standalone-bound spelling means, which no ruling
-- covers yet.
narrowRowToNamed : List String ->
  (String, List String) ->
  List (String, List String)
narrowRowToNamed named r
  | contains (fst r) named = [r]
  | otherwise = match filterList (m => contains m named) (snd r)
    [] => []
    ms => [(fst r, ms)]

-- The graph's constructor export index; `omEmpty` before a driver built `DeclEnvs`.
export
ctorExportsIndex : GraphCtx -> Unit -> OrdMap (List (String, String, Ident))
ctorExportsIndex gctx _ = gctx.declEnvsRef.value.deData.deCtorExports

export
variantNamed : String -> List Variant -> Bool
variantNamed _ [] = False
variantNamed n ((Variant cn _) :: rest) = cn == n || variantNamed n rest

-- what module [mid] EXPORTS as values, each mapped to the module that DEFINED it and
-- the name it is defined under — read off the graph envelope `buildDeclEnvs` already
-- built for this driver.  Empty when the envelope is (Flat / loader-less drivers).
--
-- Re-exports resolve through `importFormRows`, so `export import u.{p}`,
-- `export import u.*` and a chain of either resolve identically and transitively, and
-- an aliased re-export keeps the ORIGIN half of the payload pointing at the definer's
-- own name.  Declared names come first: a module that both declares and re-exports a
-- name answers with its own binding, matching first-match resolution elsewhere.
--
-- RUN-XMOD-066: THIS IS A table lookup, not A walk, and that is load-bearing for ci.
-- The first cut recursed per call: `flatMap` over every row of `deModules` to find [mid],
-- then a fresh recursive walk per `export import`.  Nothing shares a subresult, so a
-- re-export CHAIN costs O(depth * modules) per importer and a branching re-export DAG
-- costs Fibonacci-many walks (round-3 breaker, F4).  A fuel bound of 64 capped the depth
-- and not the work: `test/diff_compiler_perf_scaling.sh`'s `modules` shape — 400 modules
-- in one `export import` chain — went from 1.69 s to 2.49 s of typecheck at N=400, with
-- the ADDED term growing 3.2x per doubling of N against ~2x for everything else, and CI's
-- `gates (types)` failed it twice deterministically as SUPERLINEAR (TIME).  A comment
-- landed here calling that cost "acceptable" (RUN-XMOD-064); it was measurably wrong and
-- is retracted.
--
-- The whole answer is now derived ONCE per graph, in `declEnvDefinerIndex`, and lives on
-- the envelope as `deDefiners` — a real `OrdMap` keyed by module id, O(log modules) to
-- read, NOT a `List` scanned per lookup (this tree's thirteen quadratics are all "a List
-- used as a set or a map"; a memo that reintroduced the scan would be the fourteenth).
--
-- KEY SCOPING.  The key is the loader's module id — the SAME `demId` `deOrdIndex` is
-- keyed by and the same one `useModId` produces at every reader.  Two positions in
-- the module graph cannot collide on it, because a module id names a `deModules` row and
-- `declEnvModulesFrom` builds exactly one row per loader module; and it cannot collide
-- ACROSS graphs, because the table is a field of the envelope rather than a program-global
-- ref — see `declEnvDefinerIndex` for why that is the point.
--
-- Empty when the envelope is (Flat / loader-less drivers), exactly as before: a miss
-- answers `[]`, which is the fail-closed-on-absent-identity discipline the whole seam
-- takes (`selfDeclArities` for `mid == ""`).
export
graphPubDefiners : GraphCtx -> String -> List (String, (String, String))
graphPubDefiners gctx mid = definersIn gctx.declEnvsRef.value.deDefiners mid

export
definersIn : OrdMap (List (String, (String, String))) ->
  String ->
  List (String, (String, String))
definersIn tbl mid = match omLookup mid tbl
  None => []
  Some rows => rows

-- The per-run method-slot table omits empty rows, because absence is its
-- unconstrained answer.  The module-qualified carrier records them explicitly, so
-- `methodDictArityAtOrigin` answers a declared-unconstrained method from the
-- declaring module's own row.
export
emptyMethodModulePredicateSlots : String ->
  List Decl ->
  List ((String, String), List MethodPredicateSlot)
emptyMethodModulePredicateSlots _ [] = []
emptyMethodModulePredicateSlots mid ((DAttrib _ d) :: rest) =
  emptyMethodModulePredicateSlots mid [d]
    ++ emptyMethodModulePredicateSlots mid rest
emptyMethodModulePredicateSlots mid ((DInterface { name, typarams, methods, ifaceOrigin, ... }) :: rest) =
  flatMap
      (emptyMethodModulePredicateSlot
        mid
        IfaceRef { irName = name, irOrigin = ifaceOrigin }
        typarams)
      methods
    ++ emptyMethodModulePredicateSlots mid rest
emptyMethodModulePredicateSlots mid (_ :: rest) =
  emptyMethodModulePredicateSlots mid rest

emptyMethodModulePredicateSlot : String ->
  IfaceRef ->
  List String ->
  IfaceMethod ->
  List ((String, String), List MethodPredicateSlot)
emptyMethodModulePredicateSlot mid iface typarams (IfaceMethod name ty _ _)
  | isEmptyL (methodLevelConstraintVarNames typarams ty) =
    [((mid, methodSlotKey iface name), [])]
  | otherwise = []

-- membership-only sets (built once) instead of O(N) contains scans per entry:
-- scopeNames (~all top-level fn names) was scanned per promotedC entry → O(N²).

export
declTopFnNames : List Decl -> List String
declTopFnNames decls = map fst (funDefs decls)

export
useModuleId : Decl -> List String
useModuleId (DUse _ path _) = [useModId path]
useModuleId _ = []

export
lastComponent : List String -> String
lastComponent ns = optionOr "" (last ns)

-- The import in [prog] that brings in module [owner]'s declarations: its own
-- import, or else the first import of a module that reaches it.
export
importLocFor : OrdMap (OrdMap Unit) -> List Decl -> String -> Option Loc
importLocFor reach prog owner =
  orElseLoc
    (findMap (importLocOf owner) prog)
    (findMap (importLocReaching reach owner) prog)

importLocOf : String -> Decl -> Option Loc
importLocOf owner (DUse _ path loc)
  | useModId path == owner = Some loc
importLocOf _ _ = None

importLocReaching : OrdMap (OrdMap Unit) -> String -> Decl -> Option Loc
importLocReaching reach owner (DUse _ path loc)
  | omHasKey owner (optionOr omEmpty (omLookup (useModId path) reach)) =
    Some loc
importLocReaching _ _ _ = None

-- the spelling each built-in class has in the prelude.  It is a CONSTANT of the
-- language, not a lookup key: nothing resolves this string against a scope.
export
builtinClassName : BuiltinClass -> String
builtinClassName BNum = "Num"
builtinClassName BEq = "Eq"
builtinClassName BOrd = "Ord"
builtinClassName BSemigroup = "Semigroup"

export
builtinClassOrigin : GraphCtx -> BuiltinClass -> TyConOrigin
builtinClassOrigin gctx BNum = gctx.crossRun.builtinClassesRef.value.bcNum
builtinClassOrigin gctx BEq = gctx.crossRun.builtinClassesRef.value.bcEq
builtinClassOrigin gctx BOrd = gctx.crossRun.builtinClassesRef.value.bcOrd
builtinClassOrigin gctx BSemigroup =
  gctx.crossRun.builtinClassesRef.value.bcSemigroup

-- the identity-carrying interface reference a synthetic occurrence records.
--
-- Standing condition, for the four call sites this function feeds
-- (`recordIfaceObligation`, `inferNumLitBare`, `numCallObls`, `numDictObls`).  Each of
-- them builds a DECL-LAYER obligation goal out of this ref, via `builtinClassOrigin` ->
-- `builtinClassesRef`, a table `builtinClassesGo` populates by reading
-- `DInterface { ifaceOrigin }`.  That is sound TODAY only because no user declaration can
-- reach that table's population — MEASURED on both arms: a module IN the import graph
-- redeclaring one of the four spellings is rejected `Duplicate interface: Semigroup`
-- (exit 1); a module NOT in the graph is never loaded at all, so it contributes no
-- `DInterface` to the walk; and a user `core.mdk` cannot shadow the prelude.  The
-- cross-layer defect U1c (#1507) cured at `recordImplObligation` RETURNS at all four
-- sites if ANY of these changes: the duplicate-interface guard is relaxed; DICT §7.1 U1
-- makes the prelude a graph node (at which point §8 I4 makes two same-spelled
-- declarations legal, which is precisely what removes the guard); or a fifth
-- `BuiltinClass` is added whose spelling the guard does not cover.  The safety here is a
-- property of the LANGUAGE's current namespace rules, not of this channel.  Background:
-- `compiler/TYPECHECK-TARGET-ARCHITECTURE.md` §10.7.
export
builtinIfaceRef : GraphCtx -> BuiltinClass -> IfaceRef
builtinIfaceRef gctx c =
  IfaceRef { irName = builtinClassName c, irOrigin = builtinClassOrigin gctx c }

-- test-only observation: declarations whose only callers are tests and probes.

-- ── ARCH B-2.1-a2 history: standalone-decl-list `ImplEnv` ────────────────────
--
-- `buildImplEnv` above needs an ENVELOPE (`List DeclEnvModule`), which only the
-- graph driver builds (`buildDeclEnvs` ← `graphPreamble`, reached from `driveGraphK`
-- and from `checkModulesPreambleK`'s projection of it).
-- The retired single-program path reached this helper through `checkBodyImpl`;
-- by `medaka check <no-import file>`, `lsp`, `repl`, `doc`, and `lint`'s policy pass
-- — never calls it, so `declEnvsRef.deImpls` is `emptyImplEnv` there.  The
-- `snapshot` tool and the `llvm_emit_typed_main` / `wasm_emit_typed_main` entries
-- are NOT on this list: they elaborate through `elaborateModules`, which is the
-- graph driver, so they build a real envelope.
-- That emptiness is the hazard RUN-B-017 probe 3 MEASURED: FLAT is
-- already whole-program and already CORRECT on #1564's shape (it accepts and prints
-- `wrap(int)` where the four-module program rejects), so a later bite that repoints
-- the evidence reader onto an EMPTY Flat `IE` is a correct→broken regression on the
-- busiest verbs in the CLI.  This function removes that emptiness FIRST, additively.
-- `bodyImplEnvRef` is read: the SELECTION legs read it (`concreteReqMatchByIface`,
-- `rowRouteKey`, `implDictRoutesForRow`/`argImplDictRoutesForEncl`),
-- and B-2.1-g added the METHOD-keyed route word (`keyForSite`) plus all three shadow
-- existence reads (`ieImplExistsForHead`).  Derive the set, do not trust a list:
-- `grep -n bodyImplEnvRef compiler/types/typecheck.mdk`.
--
-- One flat program is ONE scope, so every row takes ordinal 0 and mid `""` — there
-- is no loader module id on this path (the prelude prefix carries `core` *origins*
-- on its decls, but no module id), and `""` is the same spelling `declEnvOrdIndex`
-- already seeds ordinal 0 with.  `InstRef`'s `seq` still runs across the whole
-- program, so identities stay unique within the compile, exactly as on Module.
-- Consequence, stated rather than left to be found: `instRefMid` cannot
-- distinguish a prelude impl from a user impl on FLAT.  B-2's route naming must not
-- key on `mid` for that reason — which is what the `InstRef` header already says
-- ("derive a NAME from (module id, interface identity, head) — content, not
-- position"), one path further.
--
-- linear by design, and that is why it does not call `ieAddRows`.  The rows are
-- already in hand as one forward-ordered list here, so `ieRows` is SET once and
-- only the three index buckets are folded, through the SAME `ieInsertRowKeys` /
-- `ieInsertRowAt` the Module arm uses — no per-row `ieRows` write at all, and
-- therefore no reverse to owe.
--
-- `ieInsertRow` conses and `buildImplEnv` does one `reverseL` at the end (#2146).
-- RUN-B-007's declaration-index ruling depends on `ieRows` and every bucket being
-- ASCENDING by `instRefSeq`; on the Module arm `buildImplEnv`'s final `reverseL`
-- discharges that, not the shape of `ieInsertRow`.  See
-- `ieAddRows`'s for what a caller inserting into a BUILT `ImplEnv` owes as a
-- result.  This construction still yields the same value `ieAddRows rows
-- emptyImplEnv` (followed by that reverse) would, and the bucket writer is
-- unchanged and still `mregAppendK` (forward order within a bucket).
--
-- `ieUnivSnaps` IS RE-DERIVED, per `ieAddRows`'s : it is a second
-- representation of `ieRows` maintained in exactly one place, and `ieUniverseAt`
-- reads the SNAPSHOT.  All rows share ordinal 0, so `ieBuildSnaps` emits exactly one
-- entry and `ieUniverseAt` returns the whole flat program's universe for any
-- argument — which is the correct answer on a path that has no import graph to scope.
export
buildFlatImplEnv : List Decl -> ImplEnv
buildFlatImplEnv prog =
  let rows = implRowsOf "" 0 0 (implDeclFacts prog)
  let indexed = ieIndexRows rows emptyImplEnv
  ImplEnv { indexed | ieRows = rows, ieUnivSnaps = ieBuildSnaps rows }

-- The index-only half of `ieInsertRow`: same keys, same writer, no `ieRows` append.
-- ARCH B-2.1-a3: both halves now go through the ONE once-per-row seam `ieFileRow`,
-- so an index added on either arm reaches both.  See its header — this pair is the
-- two-parallel-drivers shape, and the seam is what keeps them from drifting.
ieIndexRows : List ImplRow -> ImplEnv -> ImplEnv
ieIndexRows [] env = env
ieIndexRows (r :: rest) env = ieIndexRows rest (ieFileRow r env)

-- The per-ordinal prefix universes, in ONE left fold over the ordinal-ordered rows.
-- See `ieUnivSnaps` for why this is a performance invariant rather than a cache.
-- Emits one entry per DISTINCT ordinal (a module declaring no impl contributes no
-- entry, which is why `ieSnapAt` selects the LAST visible entry rather than indexing).
ieBuildSnaps : List ImplRow -> List (Int, ImplUniverse)
ieBuildSnaps rows = reverseL (fst (ieBuildSnapsGo rows ieSnapZero))

ieBuildSnapsGo : List ImplRow ->
  (List (Int, ImplUniverse), ImplUniverse) ->
  (List (Int, ImplUniverse), ImplUniverse)
ieBuildSnapsGo [] acc = acc
ieBuildSnapsGo (r :: rest) acc =
  let (run, more) = ieSameOrdRun (ieRowOrd r) (r :: rest) []
  ieBuildSnapsGo more (ieSnapStep run acc)

-- the leading run of rows carrying ordinal [o], and what follows it.
ieSameOrdRun : Int ->
  List ImplRow ->
  List ImplRow ->
  (List ImplRow, List ImplRow)
ieSameOrdRun _ [] acc = (reverseL acc, [])
ieSameOrdRun o (r :: rest) acc
  | ieRowOrd r == o = ieSameOrdRun o rest (r :: acc)
  | otherwise = (reverseL acc, r :: rest)

-- ── §9.7's scoping proofs, as ASSERTIONS rather than sentences ────────────────
--
-- read this before the assertions, or they will tell you something false.
-- These doctests look ONLY at the IDENTITY leg, which is the leg that does not
-- collapse.  **`IE` does still collapse same-spelled interfaces on its other
-- LEG, DELIBERATELY.**  `ieInsertRow` indexes every row under `oblIfaceKeys`,
-- which is TWO keys — the identity key AND the bare-spelling compatibility leg —
-- so `amod.Same` and `zmod.Same` below share the bare bucket, exactly as the
-- obligation channel does today.  That is inherited on purpose (see
-- `insertUnivImplKeys` for the `ifaceRefBare` goal producers that require it —
-- U1b (#1482) retired two of the three; the METHOD-OCCURRENCE one is #1507's, and
-- removing the leg is that unit's drain, not this one's), which is why #1438's
-- pin still reproduces after A-3.4 and after U1b.
--
-- So do not read the assertions below as "IE has no collapse".  They assert the
-- narrower true thing: the identity key is a SCOPE — it resolves to exactly one
-- row where a bare key would answer with two — which is what A-3 is building
-- toward and what `InstRef` and A-3.7 will consume.
--
-- `AGENTS.md` names the program-global table as this tree's most expensive shape
-- and demands the key's scope be PROVEN.  The corpus below is the adversarial
-- case: two unrelated modules that declare the same-spelled interface `Same` and
-- each impl it at ONE type, `amod`'s `Blob`.  Under a bare-name key the two
-- collapse into one bucket and one index — which is exactly the collapse A-3 is
-- removing — so every assertion here is fail-capable in the direction that
-- matters.  The type is shared on purpose: a head's key carries the TYPE's
-- module (`headKeyTag`, #1397), so two modules' own `Blob`s are two heads and
-- would test nothing about the interface half.
ieTyBlob : Ty
ieTyBlob = TyCon {
  tyConName = "Blob",
  tyConLoc = None,
  tyConOrigin = OriginModule "amod",
}

ieSameImplIn : String -> Decl
ieSameImplIn m = DImpl {
  pub = True,
  iface = "Same",
  tys = [ieTyBlob],
  reqs = [],
  methods = [],
  implOrigin = OriginModule m,
  implIfaceLoc = None,
}

-- the concrete-bucket key module [m]'s own `impl Same Blob` is indexed under.
-- Minted by the SAME calls `ieInsertRowAt` makes, so the assertions below test
-- the real key rather than a re-spelling of it.
ieProbeKey : String -> RegKey
ieProbeKey m = regKeyNTab [
  oblIfaceKey IfaceRef { irName = "Same", irOrigin = OriginModule m },
  dispHeadTab (headKeyOfCon (OriginModule "amod") "Blob"),
]

-- The COMPATIBILITY leg's key: bare interface spelling over the one shared head,
-- so it is the SAME key for both modules — which is exactly why both rows land
-- in it.
ieProbeBareKey : RegKey
ieProbeBareKey = regKeyNTab [
  TkBare NsIface "Same",
  dispHeadTab (headKeyOfCon (OriginModule "amod") "Blob"),
]

-- ordinal 0 = `amod`, ordinal 1 = `zmod`; no import edge between them is needed
-- or expressible here — that is the point of the shape.
ieProbeEnv : GraphCtx -> ImplEnv
ieProbeEnv gctx = buildImplEnv [
  declEnvModule gctx 0 "amod" [ieSameImplIn "amod"],
  declEnvModule gctx 1 "zmod" [ieSameImplIn "zmod"],
]

-- 1. the interface half is A SCOPE.  Two same-spelled interfaces in two modules
--    land in DIFFERENT buckets: each identity key resolves to exactly ONE row.
-- > listLen (mregLookupK (ieProbeKey "amod") (ieProbeEnv (probeGraphCtx ())).ieConcrete)
-- 1
-- > listLen (mregLookupK (ieProbeKey "zmod") (ieProbeEnv (probeGraphCtx ())).ieConcrete)
-- 1
--
-- 1b. and the bare leg still collapses them — asserted, not just admitted in
--     the header above, because an assertion is fail-capable and prose is not.
--     The SAME two rows also sit together under the bare-spelling key, which is
--     the compatibility leg `oblIfaceKeys` mints for goals that cannot carry an
--     identity.  Two rows, one bucket: that is #1438's shape, inherited on
--     purpose, and #1482's to drain.  If this ever reads `1`, the leg was dropped
--     and #1438's pin must have flipped with it.
-- > listLen (mregLookupK ieProbeBareKey (ieProbeEnv (probeGraphCtx ())).ieConcrete)
-- 2
--
-- 2. ROW IDENTITY.  The two same-spelled impls get DISTINCT `InstRef`s — the
--    property `bucketKeyEntriesFrom`'s restart-at-0 numbering lacks, and the one
--    A-3.7 and B-2 are waiting on.  Distinct in BOTH components, so neither the
--    module scope nor the sequence is carrying it alone.
--    OWED — this pair CANNOT discriminate an `ord`/`seq` swap: in a corpus of
--    one impl per module `ord == seq == [0, 1]`, so a builder that wrote the two
--    components the wrong way round would pass.  A discriminating corpus needs a
--    module contributing TWO impls (then `ord = [0,0,1]` while `seq = [0,1,2]`).
--    Not added here because it would also move the ordinal-filter counts in
--    assertion 3, and this round is comment-only.
-- > map (r => instRefMid (ieRowInst r)) (ieProbeEnv (probeGraphCtx ())).ieRows
-- ["amod", "zmod"]
-- > map (r => instRefSeq (ieRowInst r)) (ieProbeEnv (probeGraphCtx ())).ieRows
-- [0, 1]
--
-- 3. TABLE SCOPE — AND SINCE A-3.6 (#1558) the assertion is the opposite one.
--    This item used to pin the prefix rule: `zmod` invisible at ordinal 0, visible at
--    1, and nothing at all at `declEnvsOrdOf`'s `-1` miss.  A-3.6 flipped candidacy
--    onto `ieCandidacyVisibleAt`, so what is asserted now is the C4/I2 property
--    itself: **the selected universe is invariant in the reading ordinal.**  Every
--    impl declared anywhere in the graph is a candidate everywhere, which is what
--    *"import scoping never decides which instances exist"* means operationally.
--    which line discriminates what, kept from the pre-flip version because the
--    hazard it names inverted rather than went away.  The pairs that grade the flip
--    are the ones whose expected value CHANGED: `zmod` at ordinal 0 (1, was 0) and
--    `amod` at the `-1` miss (1, was 0).  If the prefix filter is ever re-instated on
--    this path — by re-pointing `ieSnapAt` at `declEnvVisibleAt`, or by giving
--    `ieCandidacyVisibleAt` an ordinal body — both of those fall back to 0 and this
--    block goes red.  The unchanged lines (`amod` at 0 and 1, `zmod` at 1) grade
--    nothing about the flip on their own and are kept only as the monotonicity floor:
--    they are what a candidacy predicate that is accidentally too NARROW breaks.
--    The `-1` line is no longer a fail-CLOSED assertion.  It cannot be: an
--    unknown module id now sees the WHOLE graph instead of nothing, so on this axis
--    the miss sentinel is VACUOUS.  That is a real severity change and it is
--    A-3.6's, recorded here rather than left for someone to rediscover from a `0`
--    that quietly became a `1`.  The sentinel is still live and still fail-CLOSED for
--    the NAME axis — see `declEnvsOrdOf`, and the `declEnvVisibleTo` doctests far
--    above, which assert the ordinal conjunct is still doing work there.
-- > listLen (ieProbeEnv (probeGraphCtx ())).ieUnivSnaps
-- 2
-- > listLen (mregLookupK (ieProbeKey "amod") (ieUnivConcreteOf (ieUniverseAt 0 (ieProbeEnv (probeGraphCtx ())))))
-- 1
-- > listLen (mregLookupK (ieProbeKey "amod") (ieUnivConcreteOf (ieUniverseAt 1 (ieProbeEnv (probeGraphCtx ())))))
-- 1
-- > listLen (mregLookupK (ieProbeKey "zmod") (ieUnivConcreteOf (ieUniverseAt 0 (ieProbeEnv (probeGraphCtx ())))))
-- 1
-- > listLen (mregLookupK (ieProbeKey "zmod") (ieUnivConcreteOf (ieUniverseAt 1 (ieProbeEnv (probeGraphCtx ())))))
-- 1
-- > listLen (mregLookupK (ieProbeKey "amod") (ieUnivConcreteOf (ieUniverseAt (0 - 1) (ieProbeEnv (probeGraphCtx ())))))
-- 1
--
-- 4. the projection is the obligation channel'S OWN UNIVERSE, built by the SAME
--    writer — so A-3.4 PR2's flip could not drift in key minting, only in
--    population and order, which is what both shadow instruments measured.  Since
--    that flip this is no longer a claim about a table nobody reads: it exercises the
--    projection the compiler actually dispatches on.
--    This item used to assert `zmod` at ordinals 1 and 0 as `1` and `0`.  Post-flip
--    both read `1`, i.e. the same value twice — which by item 3's own rule grades
--    nothing — so the redundant line is DELETED rather than left in place looking like
--    a test.  The surviving line still discriminates key minting: a row indexed under a
--    mis-minted concrete key answers `0` here at every ordinal.
-- > listLen (mregLookupK (ieProbeKey "zmod") (ieUnivConcreteOf (ieUniverseAt 1 (ieProbeEnv (probeGraphCtx ())))))
-- 1
ieUnivConcreteOf : ImplUniverse -> MultiRegistry (List Ty, List Require)
ieUnivConcreteOf (ImplUniverse conc _) = conc

-- ── ARCH B-2.1-a3: the HEAD-keyed index's corpus, built to DISCRIMINATE ────────
-- `ieProbeEnv` above cannot grade `ieByHead`: one impl per module means "exactly
-- once", "ascending" and "interface-blind" all read the same value, so an index that
-- double-filed, prepended, or was keyed on the interface would pass it.  This corpus
-- separates the three.  Four of its five impls carry an ORIGIN-BEARING interface, so
-- `oblIfaceKeys` mints TWO keys for each — which is what makes the double-file
-- hazard reachable at all (an all-`OriginUnresolved` corpus would mint one apiece and
-- grade nothing about the placement).
--
--   `amod` (ordinal 0): `impl Same Blob`, `impl Other Blob` — two DIFFERENT
--                       interfaces at the SAME head, which is the case `ieConcrete`
--                       separates and `ieByHead` must not.
--   `zmod` (ordinal 1): `impl Same Blob` (its own same-spelled head — `dispHeadTab`
--                       is spelling-keyed, #1317 T1, so it shares the bucket); a
--                       fully-general `impl Gen a`, which has no head tycon and must
--                       land in the HEADLESS bucket instead; and one impl whose
--                       interface is `OriginUnresolved` (below).
--
-- THE `OriginUnresolved` row is the `ieByHead`-IS-IMMUNE-TO-F1 PROBE, and it is
-- the reason this corpus has a fifth member.  RUN-B-025's review finding F1: the
-- interface keying of `a2`'s shared ref is ARM-ASYMMETRIC — `oblIfaceKeys` branches
-- on `irOrigin`, and a user-declared interface has no `flatTyOriginScope` entry on
-- Flat, so its impls file under ONE key there and TWO on Module.  `ieByHead` cannot
-- inherit that, because its key has no interface component AT ALL: it is
-- `headBucketKey (univReceiverTag tys)`, and `dispHeadTab hk = TkBare NsType
-- (headKeyName hk)` — bare spelling, origin-blind (#1317 T1).  This row asserts that
-- rather than arguing it: it lands in the SAME head bucket as its origin-bearing
-- siblings while minting half as many interface keys.
ieOtherImplIn : String -> Decl
ieOtherImplIn m = DImpl {
  pub = True,
  iface = "Other",
  tys = [ieTyBlob],
  reqs = [],
  methods = [],
  implOrigin = OriginModule m,
  implIfaceLoc = None,
}

-- a fully-general `impl Gen a`: `univReceiverTag` answers `None` for a `TyVar` head,
-- so this row is the headless-bucket case (#1128's shape).
ieGenImplIn : String -> Decl
ieGenImplIn m = DImpl {
  pub = True,
  iface = "Gen",
  tys = [TyVar "a"],
  reqs = [],
  methods = [],
  implOrigin = OriginModule m,
  implIfaceLoc = None,
}

-- `impl Loose Blob` with an IDENTITY-LESS interface: `oblIfaceKeys` mints ONE key for
-- it (the bare leg) where every sibling above gets two.  Its HEAD is an ordinary
-- concrete `Blob`, so a head-keyed index must file it beside them regardless — see the
-- F1 paragraph above.
ieLooseImplIn : String -> Decl
ieLooseImplIn m = DImpl {
  pub = True,
  iface = "Loose",
  tys = [ieTyBlob],
  reqs = [],
  methods = [],
  implOrigin = OriginUnresolved,
  implIfaceLoc = None,
}

ieHeadProbeAmod : List Decl
ieHeadProbeAmod = [ieSameImplIn "amod", ieOtherImplIn "amod"]

ieHeadProbeZmod : List Decl
ieHeadProbeZmod =
  [ieSameImplIn "zmod", ieGenImplIn "zmod", ieLooseImplIn "zmod"]

-- the SAME four decls as one standalone program, so both once-per-row
-- filing paths are graded over one corpus and a drift between them is visible.
ieHeadProbeDecls : List Decl
ieHeadProbeDecls = ieHeadProbeAmod ++ ieHeadProbeZmod

ieHeadProbeEnv : GraphCtx -> ImplEnv
ieHeadProbeEnv gctx = buildImplEnv [
  declEnvModule gctx 0 "amod" ieHeadProbeAmod,
  declEnvModule gctx 1 "zmod" ieHeadProbeZmod,
]

-- 5. the positive control: the corpus is populated and numbered as claimed.  Read
--    this first — every assertion below is a projection of it, so if this line is
--    wrong they are all measuring the wrong thing.
-- > map (r => instRefSeq (ieRowInst r)) (ieHeadProbeEnv (probeGraphCtx ())).ieRows
-- [0, 1, 2, 3, 4]
--
-- 6. `ieByHead` — four properties, one line, each independently fail-capable:
--    6a. exactly once per row.  Filed in `ieFileRow` (once per row), NOT in
--        `ieInsertRowAt` (once per `oblIfaceKeys` element).  Move the filing there
--        and this reads `[0, 0, 1, 1, 2, 2, 4]` — the inflated bucket that would
--        corrupt every count and `min⊑` taken over it.  Note seq 4 appears ONCE
--        even then: its interface is `OriginUnresolved`, so it mints one key.  A
--        double-file audit that only looked at ONE row could pick that one and see
--        nothing.
--    6b. INTERFACE-blind, across modules.  `Same`@amod, `Other`@amod, `Same`@zmod
--        and `Loose` share the bucket: this is `KeyBuckets`' head partition, not
--        `ieConcrete`'s `[iface, head]` one.  An index keyed on the interface reads
--        `[0]` or `[0, 2]`, never `[0, 1, 2, 4]`.
--    6c. ASCENDING BY `instRefSeq` — `mergeByDeclIdx`'s precondition (RUN-B-007's
--        declaration-index ruling).  `mregAddK` in place of `mregAppendK` reads
--        `[4, 2, 1, 0]`.
--    6d. immune to the arm-KEYING ASYMMETRY (RUN-B-025 F1).  Seq 4's interface mints
--        ONE `oblIfaceKeys` leg where 0/1/2 mint two, and it is in the bucket all the
--        same — because this key has no interface component.  An index that grew one
--        drops seq 4 here.  (The head itself carries the TYPE's module, `amod`'s
--        `Blob` for every row, #1397; an interface's origin never enters it.)
-- > map (r => instRefSeq (ieRowInst r)) (ieHeadRows (Some ieProbeBlobHead) (ieHeadProbeEnv (probeGraphCtx ())))
-- [0, 1, 2, 4]
--
-- 7. the headless row is in the headless bucket and nowhere else.  `impl Gen a` is
--    seq 3, and item 6 shows it is absent from the concrete bucket — so the two
--    arms of `headBucketKey` are not collapsing into one.
-- > map (r => instRefSeq (ieRowInst r)) (ieHeadRows None (ieHeadProbeEnv (probeGraphCtx ())))
-- [3]
--
-- 8. the control for 6b, and it is what proves that line tests something: the
--    INTERFACE-keyed bucket over the SAME env answers with ONE row where the head
--    bucket answers with three.  If `ieByHead` were a re-spelling of `ieConcrete`,
--    item 6 would read this value instead.
-- > listLen (mregLookupK (ieProbeKey "amod") (ieHeadProbeEnv (probeGraphCtx ())).ieConcrete)
-- 1
--
-- ITEM 9'S last expectation line is followed directly by A DECLARATION
--    (`ieProbeBlobHead`), and it has to be.  `medaka test` absorbs an ADJACENT
--    COMMENT into a doctest's expected output, so a comment there — the block-end
--    banner, where this block first ended — makes the last assertion FAIL with
--    `expected: [3]` / `actual: [3]` and the banner spliced between them: a real
--    failure that reads like a tooling bug.  Measured on this binary while writing
--    these tests.  A decl terminates the block; do not move it or interpose a
--    comment.
--
-- 9. BOTH ONCE-PER-row arms file it.  `buildImplEnv` (Module, via `ieAddRows` →
--    `ieInsertRow`) and `buildFlatImplEnv` (Flat, via `ieIndexRows`) are the two
--    paths B-2.1-a2 left in parallel, and the failure shape for a parallel pair in
--    this tree is a fix landing in one and not the other (`evalModulesWith` /
--    `cevalModules`, `AGENTS.md`).  The same five decls through the FLAT builder must
--    give the same buckets.  A future index added to only one arm leaves every line
--    above green and reddens this one.
--    This is ALSO the arm-symmetry assertion F1 does not have for the interface
--    keying: identical head buckets on both arms, over a corpus that deliberately
--    mixes origin-bearing and identity-less interfaces.  It says nothing about
--    `ieConcrete`/`ieHeadless`, which is where F1 lives and which stays open.
-- > map (r => instRefSeq (ieRowInst r)) (ieHeadRows (Some ieProbeBlobHead) (buildFlatImplEnv ieHeadProbeDecls))
-- [0, 1, 2, 4]
-- > map (r => instRefSeq (ieRowInst r)) (ieHeadRows None (buildFlatImplEnv ieHeadProbeDecls))
-- [3]
ieProbeBlobHead : HeadKey
ieProbeBlobHead = headKeyOfCon (OriginModule "amod") "Blob"

-- Fold the envelope's modules, in ordinal order, into one whole-graph
-- registry.  Builds in REVERSE and reverses once at the end — unlike
-- `ieInsertRow`'s per-row `++`, which that block's own comment records as an
-- OWED O(rows²) cost — because this is new code with no byte-identical
-- history to preserve, so there is no reason to start it with the same
-- quadratic shape `compiler/AGENTS.md` names as this tree's most expensive.
buildClassEnv : GraphCtx -> List DeclEnvModule -> ClassEnv
buildClassEnv gctx mods =
  classEnvFinish (buildClassEnvGo gctx mods emptyClassEnv)

-- ── doctests — a discriminating two-module, same-spelled-interface corpus ───
-- Mirrors `IE`'s `ieProbeEnv` shape deliberately: `AGENTS.md` demands a program
-- -global table's key be PROVEN scoped, and the proof is the adversarial case —
-- two unrelated modules declaring the SAME-SPELLED interface `Same`, each with
-- DIFFERENT content, so a bare-name (last-write-wins) construction would
-- collapse them and every assertion below would read the WRONG module's
-- content.  Every assertion here is fail-capable in that direction.
ceMethodFoo : IfaceMethod
ceMethodFoo =
  IfaceMethod "foo" (TyFun (TyVar "a") (tyConBuiltin "Int" None)) None None

ceMethodBar : IfaceMethod
ceMethodBar =
  IfaceMethod "bar" (TyFun (TyVar "a") (tyConBuiltin "String" None)) None None

ceSuperEq : Super
ceSuperEq = Super {
  superHead = "Eq",
  superParams = ["a"],
  superOrigin = OriginModule "core",
}

ceSameDeclIn : String -> List IfaceMethod -> Decl
ceSameDeclIn m methods = DInterface {
  pub = True,
  def = False,
  name = "Same",
  typarams = ["a"],
  typaramKinds = [None],
  supers = [ceSuperEq],
  methods = methods,
  ifaceOrigin = OriginModule m,
  ifaceNameLoc = None,
}

-- ordinal 0 = amod, ordinal 1 = zmod; no import edge between them, exactly as
-- `ieProbeEnv` needs none — the point of the shape is that identity alone,
-- not any resolve-level relationship, keeps the two rows apart.
ceProbeEnv : GraphCtx -> ClassEnv
ceProbeEnv gctx = buildClassEnv gctx [
  declEnvModule gctx 0 "amod" [ceSameDeclIn "amod" [ceMethodFoo]],
  declEnvModule gctx 1 "zmod" [ceSameDeclIn "zmod" [ceMethodBar]],
]

ceProbeKey : String -> RegKey
ceProbeKey m = regKeyOfTab (ifaceTabKey (OriginModule m) "Same")

-- Observes the raw `Ty` itself, via the existing renderer (`ppTy`) rather than
-- a bespoke one — this is what the WHOLE Step 0 ruling is about: a mutation
-- that replaced every method's `Ty` with a bogus constant while leaving names
-- correct would be invisible to `ceRowMethodNames` alone and must not be
-- invisible here too.
ceMethodTyStr : (String, Ty, List (String, List Kind)) -> String
ceMethodTyStr (_, ty, _) = ppTy ty

ceSuperHead : Super -> String
ceSuperHead (Super { superHead = h, ... }) = h

-- The module id, for a ROW rather than a lookup result — the row-ORDER
-- assertion below needs the identity of EACH row in `ceRows`, not a
-- single keyed lookup, exactly as `instRefMid`/`ieRowInst` give `IE`'s
-- doctests the same thing.  The non-module arms never occur on a `CeRow`
-- built from a real `DInterface` (its `ifaceOrigin` is threaded straight
-- from the decl, and this doctest corpus stamps every fixture
-- `OriginModule _`).
--
-- NAMED, NOT A WILDCARD — this tree's documented convention for a closed
-- sum like `TyConOrigin`, not a style preference of this block's.
-- `resolve.mdk:3783/3894/4087` and `originPhrase` (`typecheck.mdk`, pinned in
-- `tc_originun_allowed` below) all enumerate `TyConOrigin`'s three
-- inhabitants explicitly *"so a fourth inhabitant is made to show up"* at
-- every match, rather than being silently absorbed by a wildcard — a
-- wildcard here would still be TOTAL, but totality is not what the
-- convention is protecting; DISCOVERABILITY of a future fourth constructor
-- is.  (An earlier revision of this comment argued the wildcard on totality
-- grounds and left the convention unstated — wrong question: the tree
-- already answers it the other way in five places, and a comment settling
-- it unilaterally forecloses the one a future editor needs to see.)  Per the
-- documented remedy those five sites use, these two eliminator arms are
-- listed in `test/typecheck_compiler_source.sh`'s `tc_originun_allowed`
-- rather than the ratchet's grep being widened.
ceRowOriginTag : CeRow -> String
ceRowOriginTag r = match (ceRowIface r).irOrigin
  OriginModule m => m
  OriginBuiltin => "<builtin>"
  OriginUnresolved => "<unresolved>"

-- lookup-and-project in one call, so the doctest lines below stay one
-- expression each (this file's doctest extraction is single-line-per-`>`).
ceRowMethodNamesAt : String -> Int -> ClassEnv -> List String
ceRowMethodNamesAt m cur env = match ceLookupAt (ceProbeKey m) cur env
  None => []
  Some r => ceRowMethodNames r

ceRowMethodTysAt : String -> Int -> ClassEnv -> List String
ceRowMethodTysAt m cur env = match ceLookupAt (ceProbeKey m) cur env
  None => []
  Some r => map ceMethodTyStr (ceRowMethods r)

ceRowTyparamsAt : String -> Int -> ClassEnv -> List String
ceRowTyparamsAt m cur env = match ceLookupAt (ceProbeKey m) cur env
  None => []
  Some r => ceRowTyparams r

ceRowSuperHeadsAt : String -> Int -> ClassEnv -> List String
ceRowSuperHeadsAt m cur env = match ceLookupAt (ceProbeKey m) cur env
  None => []
  Some r => map ceSuperHead (ceRowSupers r)

-- `superParams`/`superOrigin` are asserted SEPARATELY from `superHead` above
-- (rather than folded into one combined string) so a mutation to any one of
-- the three `Super` fields fails a doctest naming that field, not a
-- catch-all — same discipline as the per-field `ceRow*At` accessors.
ceSuperParams : Super -> List String
ceSuperParams (Super { superParams = ps, ... }) = ps

-- NAMED, NOT A WILDCARD — same convention, same reason, as `ceRowOriginTag`
-- above; see its comment. Both eliminator arms are pinned in
-- `tc_originun_allowed` alongside `ceRowOriginTag`'s.
ceSuperOrigin : Super -> String
ceSuperOrigin (Super { superOrigin = (OriginModule m), ... }) = m
ceSuperOrigin (Super { superOrigin = OriginBuiltin, ... }) = "<builtin>"
ceSuperOrigin (Super { superOrigin = OriginUnresolved, ... }) = "<unresolved>"

ceRowSuperParamsAt : String -> Int -> ClassEnv -> List String
ceRowSuperParamsAt m cur env = match ceLookupAt (ceProbeKey m) cur env
  None => []
  Some r => flatMap ceSuperParams (ceRowSupers r)

ceRowSuperOriginAt : String -> Int -> ClassEnv -> String
ceRowSuperOriginAt m cur env = match ceLookupAt (ceProbeKey m) cur env
  None => ""
  Some r => match ceRowSupers r
    [] => ""
    s :: _ => ceSuperOrigin s

ceRowIfaceNameAt : String -> Int -> ClassEnv -> String
ceRowIfaceNameAt m cur env = match ceLookupAt (ceProbeKey m) cur env
  None => ""
  Some r => (ceRowIface r).irName

-- One row's param-kind signature, rendered through `kindName` (the EXISTING
-- `Kind -> String` total function, `:1904` — reused rather than shadowed by a
-- doctest-only shortener) — takes a bare `RegKey` + ordinal rather than a
-- module id, so it serves both the `ceProbeEnv` corpus below (via `ceProbeKey`)
-- and the graded/ungraded fixtures further down, whose identities are minted
-- directly rather than through `ceProbeKey`.
ceRowParamKindNamesAt : RegKey -> Int -> ClassEnv -> List (List String)
ceRowParamKindNamesAt key cur env = match ceLookupAt key cur env
  None => []
  Some r => map (ks => map kindName ks) (ceRowParamKinds r)

-- 1. WHOLE-GRAPH POPULATION: two rows, build order.
-- > listLen (ceProbeEnv (probeGraphCtx ())).ceRows
-- 2

-- 1b. ROW ORDER, asserted directly — not merely implied by the identity-keyed
--     lookups below.  Mirrors `IE`'s own row-order doctest
--     (`map (r => instRefMid (ieRowInst r)) ieProbeEnv.ieRows`), which this
--     unit's corpus otherwise mirrors everywhere except here.  Deleting
--     `classEnvFinish`'s `reverseL` leaves every OTHER doctest in this block
--     green (they all look up by identity, never by position) and is caught
--     ONLY by this one.
-- > map ceRowOriginTag (ceProbeEnv (probeGraphCtx ())).ceRows
-- ["amod", "zmod"]

-- 2. the interface half is A SCOPE — amod's identity-keyed lookup returns
--    amod's OWN row (method "foo"), never zmod's (method "bar").  Under a
--    bare-name key this would read ["bar"] for BOTH modules, since zmod is
--    registered last.
-- > ceRowMethodNamesAt "amod" 1 (ceProbeEnv (probeGraphCtx ()))
-- ["foo"]
-- > ceRowMethodNamesAt "zmod" 1 (ceProbeEnv (probeGraphCtx ()))
-- ["bar"]

-- 2b. THE RAW `Ty` ITSELF, not just the method's name — the content Step 0
--     is about.  `foo : a -> Int`, `bar : a -> String`; a mutation that
--     replaced either with a bogus constant type is caught here, not by the
--     name-only assertions above.
-- > ceRowMethodTysAt "amod" 1 (ceProbeEnv (probeGraphCtx ()))
-- ["a -> Int"]
-- > ceRowMethodTysAt "zmod" 1 (ceProbeEnv (probeGraphCtx ()))
-- ["a -> String"]

-- 3. TABLE SCOPE — the ordinal, applied through `declEnvVisibleAt` and
--    nothing else.  At ordinal 0 only amod is visible; zmod's row (declared
--    at ordinal 1) is not yet in scope.  This said "the filter A-3.6 deletes".
--    A-3.6 (#1558) did not delete it: `CE` kept its ordinal filter when the
--    predicate split, so these two lines are a LIVE assertion of a live rule, not
--    a countdown.  The `IE` block's item 3 asserts the OPPOSITE property for the
--    same shape — that is the split, visible as two doctests that disagree on
--    purpose.
-- > ceRowMethodNamesAt "zmod" 0 (ceProbeEnv (probeGraphCtx ()))
-- []
-- > ceRowMethodNamesAt "zmod" 1 (ceProbeEnv (probeGraphCtx ()))
-- ["bar"]

-- 4. TYPARAMS and SUPERS are carried unelaborated, per-row, per-module (not
--    shared or collapsed either) — `superParams`/`superOrigin` too, not only
--    `superHead`: `ceSuperEq`'s params are `["a"]` and its origin is the
--    PRELUDE (`OriginModule "core"`), both distinct from the enclosing
--    interface's own module — a mutation that garbled either would not be
--    caught by `ceRowSuperHeadsAt` alone.
-- > ceRowTyparamsAt "amod" 1 (ceProbeEnv (probeGraphCtx ()))
-- ["a"]
-- > ceRowSuperHeadsAt "zmod" 1 (ceProbeEnv (probeGraphCtx ()))
-- ["Eq"]
-- > ceRowSuperParamsAt "zmod" 1 (ceProbeEnv (probeGraphCtx ()))
-- ["a"]
-- > ceRowSuperOriginAt "zmod" 1 (ceProbeEnv (probeGraphCtx ()))
-- "core"
-- > ceRowIfaceNameAt "zmod" 1 (ceProbeEnv (probeGraphCtx ()))
-- "Same"

-- ── a graded fixture: KRow inference must match `ifaceParamKindsOf` ──────────
-- `run : f e a -> <e> a` — typaram `f`'s slot-0 argument is the bare tyvar
-- `e`, which the SAME signature's return type also uses in an effect-tail
-- position (`<e> a`), so slot 0 must infer `KRow` and slot 1 (`a`, never a
-- tail) must infer `KType`.  Until #1557 A-3.5c this asserted agreement with the
-- live `universeIfaceParamKinds` table; that table is retired and `ceParamKinds` IS
-- the answer now, so these doctests grade the production computation directly.
ceGradedMethod : IfaceMethod
ceGradedMethod =
  IfaceMethod
    "run"
    (TyFun
      (TyApp (TyApp (TyVar "f") (TyVar "e")) (TyVar "a"))
      (TyEffect [] ["e"] (TyVar "a")))
    None
    None

ceGradedIface : Decl
ceGradedIface = DInterface {
  pub = True,
  def = False,
  name = "Async",
  typarams = ["f"],
  typaramKinds = [Some (KindArrow KindEffect (KindArrow KindType KindType))],
  supers = [],
  methods = [ceGradedMethod],
  ifaceOrigin = OriginModule "gmod",
  ifaceNameLoc = None,
}

ceGradedEnv : GraphCtx -> ClassEnv
ceGradedEnv gctx =
  buildClassEnv gctx [declEnvModule gctx 0 "gmod" [ceGradedIface]]

ceGradedKey : RegKey
ceGradedKey = regKeyOfTab (ifaceTabKey (OriginModule "gmod") "Async")

-- 5. graded kind inference, positional with `ceTyparams` (here `["f"]`):
--    slot 0 (f's first argument, `e`) is `KRow`; slot 1 (`a`) is `KType`.
-- > ceRowParamKindNamesAt ceGradedKey 0 (ceGradedEnv (probeGraphCtx ()))
-- [["Effect", "Type"]]

-- ── an UNGRADED fixture: every slot is still RECORDED ("EVERY slot is recorded,
-- graded or not" — the retired writer's rule, which `ceParamKinds` keeps because
-- `checkGradedImplTys`' `anyKRow` guard, not the table, is what filters).  #1557
-- A-3.5c makes this fixture LOAD-BEARING rather than descriptive: `ceParamKinds` is
-- now the production answer, so dropping non-`KRow` rows would shift every later
-- slot's index and mis-judge a graded impl head.  `fmap : f a -> f a` applies `f` but never puts its argument in an
-- effect-tail position anywhere in the signature, so slot 0 must infer
-- `KType`, not be DROPPED from the row.  This is the fixture the reviewer's
-- mutation (b) — deleting non-`KRow` rows from `ceParamKinds` — needs to be
-- caught by: that mutation leaves the graded doctest above untouched (its one
-- slot IS `KRow`) and is invisible without a fixture whose only slot is NOT.
ceFunctorMethod : IfaceMethod
ceFunctorMethod =
  IfaceMethod
    "fmap"
    (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyApp (TyVar "f") (TyVar "a")))
    None
    None

ceFunctorIface : Decl
ceFunctorIface = DInterface {
  pub = True,
  def = False,
  name = "Functor",
  typarams = ["f"],
  typaramKinds = [None],
  supers = [],
  methods = [ceFunctorMethod],
  ifaceOrigin = OriginModule "fmod",
  ifaceNameLoc = None,
}

ceFunctorEnv : GraphCtx -> ClassEnv
ceFunctorEnv gctx =
  buildClassEnv gctx [declEnvModule gctx 0 "fmod" [ceFunctorIface]]

ceFunctorKey : RegKey
ceFunctorKey = regKeyOfTab (ifaceTabKey (OriginModule "fmod") "Functor")

-- 6. ungraded kind inference: `f`'s one applied slot is `KType`, present and
--    correct — not dropped, not defaulted to empty.
-- > ceRowParamKindNamesAt ceFunctorKey 0 (ceFunctorEnv (probeGraphCtx ()))
-- [["Type"]]

export
buildImplUniverse : List Decl -> ImplUniverse
buildImplUniverse prog =
  growImplUniverse (implDeclsWithReqs prog) emptyImplUniverse

-- Immutable observer for the method-row preparation contract.  It projects every live
-- scheme/slot cell to ids or rendered text before restoring the caller's three state
-- bundles; no row, Mono, Ref, or graph object escapes.
export
methodRowTestIface : String -> String -> List String -> List IfaceMethod -> Decl
methodRowTestIface moduleId name typarams methods = DInterface {
  pub = False,
  def = False,
  name = name,
  typarams = typarams,
  typaramKinds = map (_ => None) typarams,
  supers = [],
  methods = methods,
  ifaceOrigin = OriginModule moduleId,
  ifaceNameLoc = None,
}

export
methodRowTestConstraint : String -> String -> List Ty -> Constraint
methodRowTestConstraint moduleId name args = Constraint {
  constraintHead = name,
  constraintArgs = args,
  constraintOrigin = OriginModule moduleId,
}

export
methodRowTestFoldMapDecl : Decl
methodRowTestFoldMapDecl =
  methodRowTestIface
    "foldable-test"
    "Foldable"
    ["t"]
    [
      IfaceMethod
        "foldMap"
        (TyConstrained
          [methodRowTestConstraint "monoid-test" "Monoid" [TyVar "m"]]
          (TyFun
            (TyFun (TyVar "a") (TyVar "m"))
            (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyVar "m"))))
        None
        None,
    ]

export
methodRowTestConstantDecl : Decl
methodRowTestConstantDecl = methodRowTestIface "constant-test" "Constant" [] [
  IfaceMethod "token" (tyConBuiltin "Int" None) None None,
]

export
methodRowTestSameA : Decl
methodRowTestSameA = methodRowTestIface "same-a" "A" [] [
  IfaceMethod
    "same"
    (TyFun (tyConBuiltin "Int" None) (tyConBuiltin "Int" None))
    None
    None,
  IfaceMethod "extra" (tyConBuiltin "Int" None) None None,
]

export
methodRowTestSameB : Decl
methodRowTestSameB =
  methodRowTestIface
    "same-b"
    "B"
    ["t"]
    [
      IfaceMethod
        "same"
        (TyConstrained
          [methodRowTestConstraint "d-test" "D" [TyVar "a"]]
          (TyFun (TyVar "a") (TyVar "a")))
        None
        None,
    ]

export
methodRowTestNum : String -> Ty -> Decl
methodRowTestNum moduleId fromIntTy =
  methodRowTestIface
    moduleId
    "Num"
    ["a"]
    [IfaceMethod "fromInt" fromIntTy None None]

export
methodRowTestUserFromInt : Decl
methodRowTestUserFromInt =
  methodRowTestIface
    "user-from-int"
    "Buildable"
    ["a"]
    [
      IfaceMethod
        "fromInt"
        (TyFun (tyConBuiltin "Bool" None) (TyVar "a"))
        None
        None,
    ]

export
methodRowSameNameView : List MethodSchemeRow -> List (String, String, Int, Int)
methodRowSameNameView rows =
  map
    (row => (
      row.msrIface.irName,
      row.msrName,
      listLen (schemeIds row.msrScheme),
      listLen row.msrMethodSlots,
    ))
    rows
# DESUGAR
(DUse false (UseGroup ("types" "tc_mono") ((mem "argMentions" false) (mem "entryHeadMatches" false) (mem "headTyconTy" false) (mem "implDeclsWithReqs" false) (mem "nthTy" false) (mem "schemeBodyOf" false) (mem "schemeIds" false) (mem "tyAppSpine" false) (mem "tyVarNames" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "builtinCtors" false) (mem "emptyClassEnv" false) (mem "emptyDataEnv" false) (mem "emptyDeclEnvSeedAcc" false) (mem "emptyImplEnv" false) (mem "emptyImplUniverse" false) (mem "emptyMethodEnv" false) (mem "probeGraphCtx" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Constraint" true) (mem "DataVis" true) (mem "Decl" true) (mem "Expr" true) (mem "FunClause" true) (mem "Ident" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "KindAnn" true) (mem "LetBind" true) (mem "Loc" true) (mem "Ns" true) (mem "Pat" true) (mem "Require" true) (mem "Super" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "UseMember" true) (mem "UsePath" true) (mem "Variant" true) (mem "identOriginOf" false) (mem "mkIdent" false) (mem "orElseLoc" false) (mem "sameTyConHead" false) (mem "tabKeyEq" false) (mem "tabKeyOf" false) (mem "tyConBuiltin" false) (mem "useMemberLocal" false) (mem "useMemberOrigin" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "ppTy" false))))
(DUse false (UseGroup ("types" "effect_param_decode") ((mem "dtopIn" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffLabel" true))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "kindName" false))))
(DUse false (UseGroup ("types" "effect_infer") ((mem "AlphaBinder" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "CeRow" true) (mem "ClassEnv" true) (mem "DeclEnvAcc" true) (mem "DeclEnvModule" true) (mem "DeclEnvs" true) (mem "EnvBinding" true) (mem "GraphCtx" true) (mem "ImplAcc" true) (mem "ImplEnv" true) (mem "ImplRow" true) (mem "ImplUniverse" true) (mem "InstRef" true) (mem "KeyEntry" true) (mem "Kind" true) (mem "MethodEnv" true) (mem "MethodPredicateSlot" true) (mem "MethodRow" true) (mem "MethodSchemeRow" true) (mem "ModuleCtx" true) (mem "RecordInfo" true) (mem "StandaloneOrigin" true) (mem "TcEnv" true) (mem "ValueScheme" true) (mem "AliasDecl" false) (mem "CDeclared" false) (mem "BuiltinClass" true) (mem "dynFor" false) (mem "MethodEntry" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "useModId" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omSize" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "last" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "reverseL" false) (mem "selfBinding" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "headKeyOfCon" false) (mem "headKeyTag" false) (mem "mregAppendK" false) (mem "mregLookupK" false) (mem "MultiRegistry" false) (mem "regInsertK" false) (mem "Registry" false) (mem "RegKey" false) (mem "regKeyNTab" false) (mem "regKeyOfTab" false) (mem "regKeyRender" false) (mem "regLookupK" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "implRouteKeyWord" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "GoalOrigin" true))))
(DTypeSig true "aliasUniverseAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyCon "AliasDecl"))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))))))
(DFunDef false "aliasUniverseAt" (PWild (PList)) (EListLit))
(DFunDef false "aliasUniverseAt" ((PVar "cur") (PCons (PTuple (PVar "key") (PVar "ad")) (PVar "rest"))) (EIf (EApp (EApp (EVar "aliasVisibleTo") (EVar "cur")) (EVar "ad")) (EBinOp "::" (ETuple (EVar "key") (ETuple (EFieldAccess (EVar "ad") "adParams") (EFieldAccess (EVar "ad") "adRhs"))) (EApp (EApp (EVar "aliasUniverseAt") (EVar "cur")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "aliasUniverseAt") (EVar "cur")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "aliasVisibleTo" (TyFun (TyCon "Int") (TyFun (TyCon "AliasDecl") (TyCon "Bool"))))
(DFunDef false "aliasVisibleTo" ((PVar "cur") (PVar "ad")) (EBinOp "&&" (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "ad") "adOrd")) (EFieldAccess (EVar "ad") "adPub")) (EBinOp "/=" (EFieldAccess (EVar "ad") "adOrd") (EVar "cur"))))
(DTypeSig true "aliasOwnAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyCon "AliasDecl"))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))))))
(DFunDef false "aliasOwnAt" (PWild (PList)) (EListLit))
(DFunDef false "aliasOwnAt" ((PVar "cur") (PCons (PTuple (PVar "key") (PVar "ad")) (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EVar "ad") "adOrd") (EVar "cur")) (EBinOp "::" (ETuple (EVar "key") (ETuple (EFieldAccess (EVar "ad") "adParams") (EFieldAccess (EVar "ad") "adRhs"))) (EApp (EApp (EVar "aliasOwnAt") (EVar "cur")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "aliasOwnAt") (EVar "cur")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ifaceExportsIndex" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ifaceExportsIndex" ((PVar "gctx") PWild) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deMethods") "meIfaceExports"))
(DTypeSig true "bindingDeclared" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "CDeclared")))))
(DFunDef false "bindingDeclared" ((PVar "env") (PVar "name")) (EMatch (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "name")) (arm (PCon "Some" (PVar "binding")) () (EFieldAccess (EFieldAccess (EVar "binding") "ebValue") "vsDeclared")) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "attachStandaloneSources" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EnvBinding"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EnvBinding"))))))
(DFunDef false "attachStandaloneSources" ((PVar "sources") (PVar "bindings")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "name") (PVar "binding"))) (ETuple (EVar "name") (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "sources")) (arm (PCon "Some" (PVar "source")) () (EApp (EApp (EVar "bindingWithStandalone") (EVar "binding")) (ETuple (EVar "ImportedStandalone") (EApp (EVar "ordinaryValueScheme") (EVar "source"))))) (arm (PCon "None") () (EVar "binding")))))) (EVar "bindings")))
(DTypeSig true "standaloneValueFor" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "ValueScheme"))))))
(DFunDef false "standaloneValueFor" ((PVar "env") (PVar "name") (PVar "sym")) (EMatch (EApp (EApp (EVar "lookupStandaloneValue") (EVar "env")) (EVar "name")) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Some") (EVar "value"))) (arm (PCon "None") () (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "None") (EApp (EApp (EVar "map") (ELam ((PVar "binding")) (EFieldAccess (EVar "binding") "ebValue"))) (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "sym")))))))
(DTypeSig true "superLookup" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Super")))))))
(DFunDef false "superLookup" ((PVar "gctx") (PVar "ir")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "ir") "irName")))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "ceRowTyparams") (EVar "row")) (EApp (EVar "ceRowSupers") (EVar "row"))))) (EApp (EApp (EVar "ceLookupGraph") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deIfaces"))))))
(DTypeSig true "keyEntryIface" (TyFun (TyCon "KeyEntry") (TyCon "String")))
(DFunDef false "keyEntryIface" ((PCon "KeyEntry" PWild PWild PWild PWild (PVar "ifn") PWild PWild PWild)) (EVar "ifn"))
(DTypeSig true "graphAmbigValues" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "graphAmbigValues" ((PVar "gctx") (PVar "mid")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deAmbigValues")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "rows")) () (EVar "rows"))))
(DTypeSig true "importerReachIndex" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "importerReachIndex" ((PVar "mods")) (EApp (EApp (EApp (EVar "importerReachGo") (EApp (EApp (EVar "importerEdgeIndex") (EVar "mods")) (EVar "omEmpty"))) (EVar "mods")) (EVar "omEmpty")))
(DTypeSig false "importerReachGo" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "importerReachGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "importerReachGo" ((PVar "edges") (PCons (PTuple (PVar "mid") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "importerReachGo") (EVar "edges")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EApp (EApp (EApp (EVar "declEnvReachFrom") (EVar "edges")) (EListLit (EVar "mid"))) (EVar "omEmpty"))) (EVar "acc"))))
(DTypeSig false "importerEdgeIndex" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "importerEdgeIndex" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "importerEdgeIndex" ((PCons (PTuple (PVar "mid") (PVar "prog")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EVar "acc")) (EApp (EApp (EVar "importerEdgeIndex") (EVar "rest")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EVar "importerEdgeIndex") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EApp (EApp (EVar "flatMap") (EVar "useModuleId")) (EVar "prog"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "depExportsStandalone" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "depExportsStandalone" ((PVar "gctx") (PVar "depId") (PVar "bare")) (EIf (EApp (EApp (EVar "depExportsUnknown") (EVar "gctx")) (EVar "depId")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "==" (EApp (EVar "fst") (EVar "r")) (EVar "bare")))) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "depId"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "depExportsUnknown" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "depExportsUnknown" ((PVar "gctx") (PVar "depId")) (EBinOp "||" (EBinOp "==" (EVar "depId") (ELit (LString "core"))) (EBinOp "==" (EApp (EVar "omSize") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deDefiners")) (ELit (LInt 0)))))
(DTypeSig true "dtopFor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffLabel") (TyCon "Param"))))
(DFunDef false "dtopFor" ((PVar "gctx") (PVar "label")) (EApp (EApp (EVar "dtopIn") (EFieldAccess (EFieldAccess (EVar "gctx") "effectDomains") "value")) (EVar "label")))
(DTypeSig true "domainHasPatterns" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "domainHasPatterns" ((PCon "PPrefix" PWild)) (EVar "True"))
(DFunDef false "domainHasPatterns" ((PCon "PPath" PWild)) (EVar "True"))
(DFunDef false "domainHasPatterns" ((PCon "PProduct" (PCons (PTuple PWild (PVar "axis")) PWild))) (EApp (EVar "domainHasPatterns") (EVar "axis")))
(DFunDef false "domainHasPatterns" (PWild) (EVar "False"))
(DTypeSig true "rangedOver" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffLabel") (TyFun (TyCon "Bool") (TyCon "Bool")))))
(DFunDef false "rangedOver" ((PVar "gctx") (PVar "l") (PVar "pat")) (EBinOp "&&" (EVar "pat") (EApp (EVar "domainHasPatterns") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EVar "l")))))
(DTypeSig true "ifaceParamKindsFor" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "ifaceParamKindsFor" ((PVar "gctx") (PList) PWild PWild PWild) (EListLit))
(DFunDef false "ifaceParamKindsFor" ((PVar "gctx") (PCons (PVar "q") (PVar "qs")) (PCons (PVar "a") (PVar "anns")) (PVar "methods") (PVar "p")) (EIf (EBinOp "==" (EVar "q") (EVar "p")) (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDecl") (EVar "gctx")) (EVar "a")) (EVar "p")) (EVar "methods")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsFor") (EVar "gctx")) (EVar "qs")) (EVar "anns")) (EVar "methods")) (EVar "p")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "ifaceParamKindsFor" ((PVar "gctx") PWild (PList) PWild PWild) (EListLit))
(DTypeSig true "tyTabKey" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "TabKey"))))
(DFunDef false "tyTabKey" ((PVar "o") (PVar "n")) (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsType")) (EVar "o")) (EVar "n")))
(DTypeSig true "ifaceTabKey" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "TabKey"))))
(DFunDef false "ifaceTabKey" ((PVar "o") (PVar "n")) (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsIface")) (EVar "o")) (EVar "n")))
(DTypeSig true "emptyDeclEnvAcc" (TyCon "DeclEnvAcc"))
(DFunDef false "emptyDeclEnvAcc" () (ERecordCreate "DeclEnvAcc" ((fa "daOrdIndex" (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (ELit (LInt 0))) (EVar "omEmpty"))) (fa "daDefiners" (EVar "omEmpty")) (fa "daAmbig" (EVar "omEmpty")) (fa "daData" (EVar "emptyDataEnv")) (fa "daImpls" (EVar "emptyImplAcc")) (fa "daIfaces" (EVar "emptyClassEnv")) (fa "daMethods" (EVar "emptyMethodEnv")) (fa "daSeeds" (EVar "emptyDeclEnvSeedAcc")) (fa "daPolarity" (ETuple (EListLit) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (EListLit)) (EVar "omEmpty")))) (fa "daOwnerModules" (EVar "omEmpty")))))
(DTypeSig true "declEnvModule" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "DeclEnvModule"))))))
(DFunDef false "declEnvModule" ((PVar "gctx") (PVar "k") (PVar "mid") (PVar "decls")) (ERecordCreate "DeclEnvModule" ((fa "demOrd" (EVar "k")) (fa "demId" (EVar "mid")) (fa "demDecls" (EVar "decls")) (fa "demPubDecls" (EApp (EVar "publicDataDecls") (EVar "decls"))) (fa "demKindEntries" (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EApp (EApp (EVar "filterList") (EVar "kindPublicDataDecl")) (EVar "decls")))))))
(DTypeSig true "declEnvDeclsOf" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "declEnvDeclsOf" ((PList)) (EListLit))
(DFunDef false "declEnvDeclsOf" ((PCons (PVar "m") (PVar "rest"))) (EBinOp "++" (EFieldAccess (EVar "m") "demDecls") (EApp (EVar "declEnvDeclsOf") (EVar "rest"))))
(DTypeSig true "declEnvVisibleAt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "declEnvVisibleAt" ((PVar "cur") (PVar "entryOrd")) (EBinOp "<=" (EVar "entryOrd") (EVar "cur")))
(DTypeSig false "ieCandidacyVisibleAt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "ieCandidacyVisibleAt" (PWild PWild) (EVar "True"))
(DTypeSig true "declEnvsOrdOf" (TyFun (TyCon "String") (TyFun (TyCon "DeclEnvs") (TyCon "Int"))))
(DFunDef false "declEnvsOrdOf" ((PVar "mid") (PVar "envs")) (EApp (EApp (EVar "ordOfIndex") (EVar "mid")) (EFieldAccess (EVar "envs") "deOrdIndex")))
(DTypeSig true "ordOfIndex" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "ordOfIndex" ((PVar "mid") (PVar "index")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "index")) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))))
(DTypeSig true "declEnvVisibleTo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool")))))
(DFunDef false "declEnvVisibleTo" ((PVar "cur") (PVar "entryOrd") (PVar "entryIsPublic")) (EBinOp "&&" (EApp (EApp (EVar "declEnvVisibleAt") (EVar "cur")) (EVar "entryOrd")) (EBinOp "||" (EBinOp "==" (EVar "entryOrd") (EVar "cur")) (EVar "entryIsPublic"))))
(DTypeSig true "declEnvRowVisible" (TyFun (TyCon "Int") (TyFun (TyCon "DeclEnvModule") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "declEnvRowVisible" ((PVar "cur") (PVar "m")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "False")) (EFieldAccess (EVar "m") "demDecls") (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "True")) (EFieldAccess (EVar "m") "demPubDecls") (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "declEnvKindEntries" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind")))))))
(DFunDef false "declEnvKindEntries" ((PVar "gctx") (PList)) (EListLit))
(DFunDef false "declEnvKindEntries" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "declEnvKindEntries" ((PVar "gctx") (PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataParamKinds" (PVar "ks")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EVar "gctx")) (EVar "ps")) (EVar "ks"))) (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EVar "rest"))))
(DFunDef false "declEnvKindEntries" ((PVar "gctx") (PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeParamKinds" (PVar "ks")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EVar "gctx")) (EVar "ps")) (EVar "ks"))) (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EVar "rest"))))
(DFunDef false "declEnvKindEntries" ((PVar "gctx") (PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasParamKinds" (PVar "ks")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EVar "gctx")) (EVar "ps")) (EVar "ks"))) (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EVar "rest"))))
(DFunDef false "declEnvKindEntries" ((PVar "gctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EVar "rest")))
(DTypeSig true "declEnvReachFrom" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "declEnvReachFrom" (PWild (PList) (PVar "seen")) (EVar "seen"))
(DFunDef false "declEnvReachFrom" ((PVar "edges") (PCons (PVar "mid") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "fresh") (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "d")) (EVar "seen"))))) (EApp (EApp (EVar "declEnvDirectImports") (EVar "edges")) (EVar "mid")))) (DoExpr (EApp (EApp (EApp (EVar "declEnvReachFrom") (EVar "edges")) (EBinOp "++" (EVar "fresh") (EVar "rest"))) (EApp (EApp (EVar "declEnvMarkReached") (EVar "fresh")) (EVar "seen"))))))
(DTypeSig false "declEnvMarkReached" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "declEnvMarkReached" ((PList) (PVar "seen")) (EVar "seen"))
(DFunDef false "declEnvMarkReached" ((PCons (PVar "d") (PVar "rest")) (PVar "seen")) (EApp (EApp (EVar "declEnvMarkReached") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "d")) (ELit LUnit)) (EVar "seen"))))
(DTypeSig false "declEnvDirectImports" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declEnvDirectImports" ((PVar "edges") (PVar "mid")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "edges"))))
(DTypeSig true "instRefMid" (TyFun (TyCon "InstRef") (TyCon "String")))
(DFunDef false "instRefMid" ((PCon "InstRef" (PVar "m") PWild PWild)) (EVar "m"))
(DTypeSig true "instRefSeq" (TyFun (TyCon "InstRef") (TyCon "Int")))
(DFunDef false "instRefSeq" ((PCon "InstRef" PWild PWild (PVar "s"))) (EVar "s"))
(DTypeSig true "ieRowOrd" (TyFun (TyCon "ImplRow") (TyCon "Int")))
(DFunDef false "ieRowOrd" ((PCon "ImplRow" (PVar "o") PWild PWild PWild PWild PWild PWild)) (EVar "o"))
(DTypeSig true "ieRowInst" (TyFun (TyCon "ImplRow") (TyCon "InstRef")))
(DFunDef false "ieRowInst" ((PCon "ImplRow" PWild (PVar "i") PWild PWild PWild PWild PWild)) (EVar "i"))
(DTypeSig true "ieRowTriple" (TyFun (TyCon "ImplRow") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))))
(DFunDef false "ieRowTriple" ((PCon "ImplRow" PWild PWild (PVar "ir") (PVar "tys") (PVar "reqs") PWild PWild)) (ETuple (EVar "ir") (EVar "tys") (EVar "reqs")))
(DTypeSig true "ieRowIface" (TyFun (TyCon "ImplRow") (TyCon "IfaceRef")))
(DFunDef false "ieRowIface" ((PCon "ImplRow" PWild PWild (PVar "ir") PWild PWild PWild PWild)) (EVar "ir"))
(DTypeSig true "ieRowMethodNames" (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ieRowMethodNames" ((PCon "ImplRow" PWild PWild PWild PWild PWild (PVar "ms") PWild)) (EVar "ms"))
(DTypeSig true "ieRowLoc" (TyFun (TyCon "ImplRow") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "ieRowLoc" ((PCon "ImplRow" PWild PWild PWild PWild PWild PWild (PVar "l"))) (EVar "l"))
(DTypeSig false "emptyImplAcc" (TyCon "ImplAcc"))
(DFunDef false "emptyImplAcc" () (ERecordCreate "ImplAcc" ((fa "iaEnv" (EVar "emptyImplEnv")) (fa "iaSeq" (ELit (LInt 0))) (fa "iaSnaps" (EVar "ieSnapZero")))))
(DTypeSig false "buildImplEnv" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyCon "ImplEnv")))
(DFunDef false "buildImplEnv" ((PVar "mods")) (EApp (EVar "implAccFinish") (EApp (EApp (EVar "buildImplEnvGo") (EVar "mods")) (EVar "emptyImplAcc"))))
(DTypeSig true "implAccFinish" (TyFun (TyCon "ImplAcc") (TyCon "ImplEnv")))
(DFunDef false "implAccFinish" ((PVar "ia")) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EVar "ia") "iaEnv")) (DoExpr (EVariantUpdate "ImplEnv" (EVar "env") ((fa "ieRows" (EApp (EVar "reverseL") (EFieldAccess (EVar "env") "ieRows"))) (fa "ieUnivSnaps" (EApp (EVar "reverseL") (EApp (EVar "fst") (EFieldAccess (EVar "ia") "iaSnaps")))))))))
(DTypeSig true "buildImplEnvGo" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "ImplAcc") (TyCon "ImplAcc"))))
(DFunDef false "buildImplEnvGo" ((PList) (PVar "ia")) (EVar "ia"))
(DFunDef false "buildImplEnvGo" ((PCons (PVar "m") (PVar "rest")) (PVar "ia")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EApp (EVar "implRowsOf") (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "m") "demOrd")) (EFieldAccess (EVar "ia") "iaSeq")) (EApp (EVar "implDeclFacts") (EFieldAccess (EVar "m") "demDecls")))) (DoExpr (EApp (EApp (EVar "buildImplEnvGo") (EVar "rest")) (ERecordCreate "ImplAcc" ((fa "iaEnv" (EApp (EApp (EVar "ieAddRows") (EVar "rows")) (EFieldAccess (EVar "ia") "iaEnv"))) (fa "iaSeq" (EBinOp "+" (EFieldAccess (EVar "ia") "iaSeq") (EApp (EVar "listLen") (EVar "rows")))) (fa "iaSnaps" (EApp (EApp (EVar "ieSnapStep") (EVar "rows")) (EFieldAccess (EVar "ia") "iaSnaps")))))))))
(DTypeSig false "ieSnapZero" (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyCon "ImplUniverse")))
(DFunDef false "ieSnapZero" () (ETuple (EListLit) (EVar "emptyImplUniverse")))
(DTypeSig false "ieSnapStep" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyCon "ImplUniverse")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyCon "ImplUniverse")))))
(DFunDef false "ieSnapStep" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "ieSnapStep" ((PCons (PVar "r") (PVar "rest")) (PTuple (PVar "snaps") (PVar "univ"))) (EBlock (DoLet false false (PVar "univ2") (EApp (EApp (EVar "growImplUniverse") (EApp (EApp (EVar "map") (EVar "ieRowTriple")) (EBinOp "::" (EVar "r") (EVar "rest")))) (EVar "univ"))) (DoExpr (ETuple (EBinOp "::" (ETuple (EApp (EVar "ieRowOrd") (EVar "r")) (EVar "univ2")) (EVar "snaps")) (EVar "univ2")))))
(DTypeSig false "implDeclFacts" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "implDeclFacts" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "implDeclFact")) (EVar "prog")))
(DTypeSig false "implDeclFact" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "implDeclFact" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "implDeclFact") (EVar "d")))
(DFunDef false "implDeclFact" ((PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None) (rf "implOrigin" None) (rf "implIfaceLoc" None)) true)) (EListLit (ETuple (ERecordCreate "IfaceRef" ((fa "irName" (EVar "iface")) (fa "irOrigin" (EVar "implOrigin")))) (EVar "tys") (EVar "reqs") (EApp (EApp (EVar "map") (EVar "implMethodNameTc")) (EVar "methods")) (EVar "implIfaceLoc"))))
(DFunDef false "implDeclFact" (PWild) (EListLit))
(DTypeSig false "implRowsOf" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "ImplRow")))))))
(DFunDef false "implRowsOf" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "implRowsOf" ((PVar "mid") (PVar "ord") (PVar "seq") (PCons (PTuple (PVar "iface") (PVar "tys") (PVar "reqs") (PVar "ms") (PVar "loc")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ImplRow") (EVar "ord")) (EApp (EApp (EApp (EVar "InstRef") (EVar "mid")) (EVar "ord")) (EVar "seq"))) (EVar "iface")) (EVar "tys")) (EVar "reqs")) (EVar "ms")) (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "implRowsOf") (EVar "mid")) (EVar "ord")) (EBinOp "+" (EVar "seq") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "ieAddRows" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv"))))
(DFunDef false "ieAddRows" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "ieAddRows" ((PCons (PVar "r") (PVar "rest")) (PVar "env")) (EApp (EApp (EVar "ieAddRows") (EVar "rest")) (EApp (EApp (EVar "ieInsertRow") (EVar "r")) (EVar "env"))))
(DTypeSig false "ieInsertRow" (TyFun (TyCon "ImplRow") (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv"))))
(DFunDef false "ieInsertRow" ((PVar "r") (PVar "env")) (EApp (EApp (EVar "ieFileRow") (EVar "r")) (ERecordUpdate (EVar "env") ((fa "ieRows" (EBinOp "::" (EVar "r") (EFieldAccess (EVar "env") "ieRows")))))))
(DTypeSig false "ieFileRow" (TyFun (TyCon "ImplRow") (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv"))))
(DFunDef false "ieFileRow" ((PAs "r" (PCon "ImplRow" PWild PWild (PVar "ir") PWild PWild PWild PWild)) (PVar "env")) (EApp (EApp (EApp (EVar "ieInsertRowKeys") (EApp (EVar "oblIfaceKeys") (EVar "ir"))) (EVar "r")) (EApp (EApp (EVar "ieFileRowByHead") (EVar "r")) (EVar "env"))))
(DTypeSig false "ieFileRowByHead" (TyFun (TyCon "ImplRow") (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv"))))
(DFunDef false "ieFileRowByHead" ((PAs "r" (PCon "ImplRow" PWild PWild PWild (PVar "tys") PWild PWild PWild)) (PVar "env")) (EVariantUpdate "ImplEnv" (EVar "env") ((fa "ieByHead" (EApp (EApp (EApp (EVar "mregAppendK") (EApp (EVar "headBucketKey") (EApp (EVar "univReceiverTag") (EVar "tys")))) (EVar "r")) (EFieldAccess (EVar "env") "ieByHead"))))))
(DTypeSig true "ieHeadRows" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow")))))
(DFunDef false "ieHeadRows" ((PVar "hd") (PVar "env")) (EApp (EApp (EVar "mregLookupK") (EApp (EVar "headBucketKey") (EVar "hd"))) (EFieldAccess (EVar "env") "ieByHead")))
(DTypeSig false "ieInsertRowKeys" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyCon "ImplRow") (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv")))))
(DFunDef false "ieInsertRowKeys" ((PList) PWild (PVar "env")) (EVar "env"))
(DFunDef false "ieInsertRowKeys" ((PCons (PVar "ifk") (PVar "rest")) (PVar "r") (PVar "env")) (EApp (EApp (EApp (EVar "ieInsertRowKeys") (EVar "rest")) (EVar "r")) (EApp (EApp (EApp (EVar "ieInsertRowAt") (EVar "ifk")) (EVar "r")) (EVar "env"))))
(DTypeSig false "ieInsertRowAt" (TyFun (TyCon "TabKey") (TyFun (TyCon "ImplRow") (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv")))))
(DFunDef false "ieInsertRowAt" ((PVar "ifk") (PAs "r" (PCon "ImplRow" PWild PWild PWild (PVar "tys") PWild PWild PWild)) (PVar "env")) (EMatch (EApp (EVar "univReceiverTag") (EVar "tys")) (arm (PCon "Some" (PVar "hk")) () (EVariantUpdate "ImplEnv" (EVar "env") ((fa "ieConcrete" (EApp (EApp (EApp (EVar "mregAppendK") (EApp (EVar "regKeyNTab") (EListLit (EVar "ifk") (EApp (EVar "dispHeadTab") (EVar "hk"))))) (EVar "r")) (EFieldAccess (EVar "env") "ieConcrete")))))) (arm (PCon "None") () (EVariantUpdate "ImplEnv" (EVar "env") ((fa "ieHeadless" (EApp (EApp (EApp (EVar "mregAppendK") (EApp (EVar "regKeyOfTab") (EVar "ifk"))) (EVar "r")) (EFieldAccess (EVar "env") "ieHeadless"))))))))
(DTypeSig true "ieUniverseAt" (TyFun (TyCon "Int") (TyFun (TyCon "ImplEnv") (TyCon "ImplUniverse"))))
(DFunDef false "ieUniverseAt" ((PVar "cur") (PVar "env")) (EApp (EApp (EApp (EVar "ieSnapAt") (EVar "cur")) (EFieldAccess (EVar "env") "ieUnivSnaps")) (EVar "emptyImplUniverse")))
(DTypeSig false "ieSnapAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyFun (TyCon "ImplUniverse") (TyCon "ImplUniverse")))))
(DFunDef false "ieSnapAt" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "ieSnapAt" ((PVar "cur") (PCons (PTuple (PVar "o") (PVar "u")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "ieCandidacyVisibleAt") (EVar "cur")) (EVar "o")) (EApp (EApp (EApp (EVar "ieSnapAt") (EVar "cur")) (EVar "rest")) (EVar "u")) (EIf (EVar "otherwise") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ieRowsVisibleAt" (TyFun (TyCon "Int") (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow")))))
(DFunDef false "ieRowsVisibleAt" ((PVar "cur") (PVar "env")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "ieCandidacyVisibleAt") (EVar "cur")) (EApp (EVar "ieRowOrd") (EVar "r"))))) (EFieldAccess (EVar "env") "ieRows")))
(DTypeSig true "ieRowsAll" (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow"))))
(DFunDef false "ieRowsAll" ((PVar "env")) (EFieldAccess (EVar "env") "ieRows"))
(DTypeSig true "ieRowsOwnedBy" (TyFun (TyCon "Int") (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow")))))
(DFunDef false "ieRowsOwnedBy" ((PVar "cur") (PVar "env")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "==" (EApp (EVar "ieRowOrd") (EVar "r")) (EVar "cur")))) (EFieldAccess (EVar "env") "ieRows")))
(DTypeSig false "ceRowKey" (TyFun (TyCon "CeRow") (TyCon "RegKey")))
(DFunDef false "ceRowKey" ((PCon "CeRow" (PVar "k") PWild PWild PWild PWild PWild PWild PWild PWild)) (EVar "k"))
(DTypeSig true "ceRowOrd" (TyFun (TyCon "CeRow") (TyCon "Int")))
(DFunDef false "ceRowOrd" ((PCon "CeRow" PWild (PVar "o") PWild PWild PWild PWild PWild PWild PWild)) (EVar "o"))
(DTypeSig true "ceRowIface" (TyFun (TyCon "CeRow") (TyCon "IfaceRef")))
(DFunDef false "ceRowIface" ((PCon "CeRow" PWild PWild (PVar "ir") PWild PWild PWild PWild PWild PWild)) (EVar "ir"))
(DTypeSig true "ceRowTyparams" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ceRowTyparams" ((PCon "CeRow" PWild PWild PWild (PVar "tp") PWild PWild PWild PWild PWild)) (EVar "tp"))
(DTypeSig true "ceRowMethods" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "ceRowMethods" ((PCon "CeRow" PWild PWild PWild PWild (PVar "ms") PWild PWild PWild PWild)) (EVar "ms"))
(DTypeSig true "ceRowSupers" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyCon "Super"))))
(DFunDef false "ceRowSupers" ((PCon "CeRow" PWild PWild PWild PWild PWild (PVar "sups") PWild PWild PWild)) (EVar "sups"))
(DTypeSig true "ceRowParamKinds" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind")))))
(DFunDef false "ceRowParamKinds" ((PCon "CeRow" PWild PWild PWild PWild PWild PWild (PVar "pk") PWild PWild)) (EVar "pk"))
(DTypeSig true "ceRowRequired" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ceRowRequired" ((PCon "CeRow" PWild PWild PWild PWild PWild PWild PWild (PVar "req") PWild)) (EVar "req"))
(DTypeSig true "ceRowLoc" (TyFun (TyCon "CeRow") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "ceRowLoc" ((PCon "CeRow" PWild PWild PWild PWild PWild PWild PWild PWild (PVar "l"))) (EVar "l"))
(DTypeSig true "classEnvFinish" (TyFun (TyCon "ClassEnv") (TyCon "ClassEnv")))
(DFunDef false "classEnvFinish" ((PVar "env")) (EVariantUpdate "ClassEnv" (EVar "env") ((fa "ceRows" (EApp (EVar "reverseL") (EFieldAccess (EVar "env") "ceRows"))))))
(DTypeSig true "buildClassEnvGo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "ClassEnv") (TyCon "ClassEnv")))))
(DFunDef false "buildClassEnvGo" ((PVar "gctx") (PList) (PVar "env")) (EVar "env"))
(DFunDef false "buildClassEnvGo" ((PVar "gctx") (PCons (PVar "m") (PVar "rest")) (PVar "env")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EVar "classEnvRowsOf") (EVar "gctx")) (EFieldAccess (EVar "m") "demOrd")) (EApp (EVar "classEnvDeclFacts") (EFieldAccess (EVar "m") "demDecls")))) (DoExpr (EApp (EApp (EApp (EVar "buildClassEnvGo") (EVar "gctx")) (EVar "rest")) (EApp (EApp (EVar "ceAddRows") (EVar "rows")) (EVar "env"))))))
(DTypeSig false "classEnvDeclFacts" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "Super")) (TyCon "TyConOrigin") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "classEnvDeclFacts" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "classEnvDeclFact")) (EVar "prog")))
(DTypeSig false "classEnvDeclFact" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "Super")) (TyCon "TyConOrigin") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "classEnvDeclFact" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "classEnvDeclFact") (EVar "d")))
(DFunDef false "classEnvDeclFact" ((PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "supers" None) (rf "methods" None) (rf "ifaceOrigin" None) (rf "ifaceNameLoc" None)) true)) (EListLit (ETuple (EVar "name") (EVar "typarams") (EVar "typaramKinds") (EVar "methods") (EVar "supers") (EVar "ifaceOrigin") (EVar "ifaceNameLoc"))))
(DFunDef false "classEnvDeclFact" (PWild) (EListLit))
(DTypeSig false "classEnvRowsOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "Super")) (TyCon "TyConOrigin") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "CeRow"))))))
(DFunDef false "classEnvRowsOf" ((PVar "gctx") PWild (PList)) (EListLit))
(DFunDef false "classEnvRowsOf" ((PVar "gctx") (PVar "ord") (PCons (PTuple (PVar "name") (PVar "typarams") (PVar "kinds") (PVar "methods") (PVar "supers") (PVar "o") (PVar "loc")) (PVar "rest"))) (EBlock (DoLet false false (PVar "scope") (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EVar "gctx")) (EVar "typarams")) (EVar "kinds")) (EVar "methods"))) (DoLet false false (PVar "row") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CeRow") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "o")) (EVar "name")))) (EVar "ord")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "o"))))) (EVar "typarams")) (EApp (EApp (EVar "map") (EApp (EVar "ceMethodOf") (EVar "scope"))) (EVar "methods"))) (EVar "supers")) (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDeclAll") (EVar "gctx")) (EVar "typarams")) (EVar "kinds")) (EVar "methods"))) (EApp (EVar "requiredMethodNames") (EVar "methods"))) (EVar "loc"))) (DoExpr (EBinOp "::" (EVar "row") (EApp (EApp (EApp (EVar "classEnvRowsOf") (EVar "gctx")) (EVar "ord")) (EVar "rest"))))))
(DTypeSig true "ifaceParamKindsDeclAll" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "ifaceParamKindsDeclAll" ((PVar "gctx") (PList) PWild PWild) (EListLit))
(DFunDef false "ifaceParamKindsDeclAll" ((PVar "gctx") (PCons (PVar "p") (PVar "ps")) (PList) (PVar "methods")) (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDeclAll") (EVar "gctx")) (EBinOp "::" (EVar "p") (EVar "ps"))) (EListLit (EVar "None"))) (EVar "methods")))
(DFunDef false "ifaceParamKindsDeclAll" ((PVar "gctx") (PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "anns")) (PVar "methods")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDecl") (EVar "gctx")) (EVar "a")) (EVar "p")) (EVar "methods")) (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDeclAll") (EVar "gctx")) (EVar "ps")) (EVar "anns")) (EVar "methods"))))
(DTypeSig false "ceMethodOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "ceMethodOf" ((PVar "scope") (PCon "IfaceMethod" (PVar "n") (PVar "ty") PWild PWild)) (ETuple (EVar "n") (EVar "ty") (EVar "scope")))
(DTypeSig false "ceAddRows" (TyFun (TyApp (TyCon "List") (TyCon "CeRow")) (TyFun (TyCon "ClassEnv") (TyCon "ClassEnv"))))
(DFunDef false "ceAddRows" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "ceAddRows" ((PCons (PVar "r") (PVar "rest")) (PVar "env")) (EApp (EApp (EVar "ceAddRows") (EVar "rest")) (EApp (EApp (EVar "ceInsertRow") (EVar "r")) (EVar "env"))))
(DTypeSig false "ceInsertRow" (TyFun (TyCon "CeRow") (TyFun (TyCon "ClassEnv") (TyCon "ClassEnv"))))
(DFunDef false "ceInsertRow" ((PVar "r") (PVar "env")) (EVariantUpdate "ClassEnv" (EVar "env") ((fa "ceRows" (EBinOp "::" (EVar "r") (EFieldAccess (EVar "env") "ceRows"))) (fa "ceByKey" (EApp (EApp (EApp (EVar "regInsertK") (EApp (EVar "ceRowKey") (EVar "r"))) (EVar "r")) (EFieldAccess (EVar "env") "ceByKey"))))))
(DTypeSig true "ceLookupAt" (TyFun (TyCon "RegKey") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "Option") (TyCon "CeRow"))))))
(DFunDef false "ceLookupAt" ((PVar "key") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EVar "regLookupK") (EVar "key")) (EFieldAccess (EVar "env") "ceByKey")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "r")) () (EIf (EApp (EApp (EVar "declEnvVisibleAt") (EVar "cur")) (EApp (EVar "ceRowOrd") (EVar "r"))) (EApp (EVar "Some") (EVar "r")) (EVar "None")))))
(DTypeSig true "ceLookupGraph" (TyFun (TyCon "RegKey") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "Option") (TyCon "CeRow")))))
(DFunDef false "ceLookupGraph" ((PVar "key") (PVar "env")) (EApp (EApp (EVar "regLookupK") (EVar "key")) (EFieldAccess (EVar "env") "ceByKey")))
(DTypeSig true "ceRowsVisibleAt" (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "CeRow")))))
(DFunDef false "ceRowsVisibleAt" ((PVar "cur") (PVar "env")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "declEnvVisibleAt") (EVar "cur")) (EApp (EVar "ceRowOrd") (EVar "r"))))) (EFieldAccess (EVar "env") "ceRows")))
(DTypeSig true "ceRowsOwnedBy" (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "CeRow")))))
(DFunDef false "ceRowsOwnedBy" ((PVar "cur") (PVar "env")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "==" (EApp (EVar "ceRowOrd") (EVar "r")) (EVar "cur")))) (EFieldAccess (EVar "env") "ceRows")))
(DTypeSig true "ceSlotKindsAt" (TyFun (TyCon "RegKey") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "ceSlotKindsAt" ((PVar "key") (PVar "cur") (PVar "i") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EVar "key")) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EVar "nthKindList") (EVar "i")) (EApp (EVar "ceRowParamKinds") (EVar "r"))))))
(DTypeSig true "ceRequiredAt" (TyFun (TyCon "RegKey") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ceRequiredAt" ((PVar "key") (PVar "cur") (PVar "env")) (EApp (EApp (EVar "map") (EVar "ceRowRequired")) (EApp (EApp (EApp (EVar "ceLookupAt") (EVar "key")) (EVar "cur")) (EVar "env"))))
(DTypeSig false "nthKindList" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Kind"))))))
(DFunDef false "nthKindList" (PWild (PList)) (EVar "None"))
(DFunDef false "nthKindList" ((PVar "i") (PCons (PVar "k") (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "k")) (EIf (EVar "otherwise") (EApp (EApp (EVar "nthKindList") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ceRowMethodNames" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ceRowMethodNames" ((PVar "r")) (EApp (EApp (EVar "map") (EVar "ceMethodName")) (EApp (EVar "ceRowMethods") (EVar "r"))))
(DTypeSig false "ceMethodName" (TyFun (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))) (TyCon "String")))
(DFunDef false "ceMethodName" ((PTuple (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig true "methodEnvGo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "MethodEnv") (TyCon "MethodEnv")))))
(DFunDef false "methodEnvGo" ((PVar "gctx") (PList) (PVar "env")) (EVar "env"))
(DFunDef false "methodEnvGo" ((PVar "gctx") (PCons (PVar "m") (PVar "rest")) (PVar "env")) (EApp (EApp (EApp (EVar "methodEnvGo") (EVar "gctx")) (EVar "rest")) (ERecordCreate "MethodEnv" ((fa "meByName" (EApp (EApp (EApp (EApp (EVar "methodRowsInto") (EVar "gctx")) (EFieldAccess (EVar "m") "demOrd")) (EFieldAccess (EVar "m") "demDecls")) (EFieldAccess (EVar "env") "meByName"))) (fa "meExports" (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EBinOp "++" (EApp (EVar "declMethodIdents") (EFieldAccess (EVar "m") "demDecls")) (EApp (EApp (EVar "reexportedMethodIdents") (EFieldAccess (EVar "env") "meExports")) (EFieldAccess (EVar "m") "demDecls")))) (EFieldAccess (EVar "env") "meExports"))) (fa "meIfaceExports" (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EBinOp "++" (EApp (EVar "ifaceMethodRows") (EFieldAccess (EVar "m") "demDecls")) (EApp (EApp (EVar "reexportedIfaceMethods") (EFieldAccess (EVar "env") "meIfaceExports")) (EFieldAccess (EVar "m") "demDecls")))) (EFieldAccess (EVar "env") "meIfaceExports")))))))
(DTypeSig false "methodRowsInto" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodRow"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodRow"))))))))
(DFunDef false "methodRowsInto" ((PVar "gctx") PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "methodRowsInto" ((PVar "gctx") (PVar "ord") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "methodRowsInto") (EVar "gctx")) (EVar "ord")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "methodRowsInto") (EVar "gctx")) (EVar "ord")) (EListLit (EVar "d"))) (EVar "acc"))))
(DFunDef false "methodRowsInto" ((PVar "gctx") (PVar "ord") (PCons (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "methods" None) (rf "ifaceOrigin" None)) true) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "methodRowsInto") (EVar "gctx")) (EVar "ord")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodRowsOfIface") (EVar "ord")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "ifaceOrigin"))))) (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "ifaceOrigin")) (EVar "name")))) (EVar "typarams")) (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EVar "gctx")) (EVar "typarams")) (EVar "typaramKinds")) (EVar "methods"))) (EVar "methods")) (EVar "acc"))))
(DFunDef false "methodRowsInto" ((PVar "gctx") (PVar "ord") (PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "methodRowsInto") (EVar "gctx")) (EVar "ord")) (EVar "rest")) (EVar "acc")))
(DTypeSig false "methodRowsOfIface" (TyFun (TyCon "Int") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodRow"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodRow")))))))))))
(DFunDef false "methodRowsOfIface" (PWild PWild PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "methodRowsOfIface" ((PVar "ord") (PVar "iface") (PVar "key") (PVar "typarams") (PVar "scope") (PCons (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "acc2") (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsMethod")) (EFieldAccess (EVar "iface") "irOrigin")) (EVar "mname")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "ident")) () (EBlock (DoLet false false (PVar "row") (ERecordCreate "MethodRow" ((fa "mrIdent" (EVar "ident")) (fa "mrOrd" (EVar "ord")) (fa "mrIface" (EVar "key")) (fa "mrEntry" (ETuple (EVar "iface") (EVar "typarams") (EVar "mty") (EVar "scope")))))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "mname")) (EBinOp "++" (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "/=" (EFieldAccess (EVar "r") "mrIdent") (EVar "ident")))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mname")) (EVar "acc")))) (EListLit (EVar "row")))) (EVar "acc"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodRowsOfIface") (EVar "ord")) (EVar "iface")) (EVar "key")) (EVar "typarams")) (EVar "scope")) (EVar "rest")) (EVar "acc2")))))
(DTypeSig true "methodRowById" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyApp (TyCon "Option") (TyCon "MethodRow")))))
(DFunDef false "methodRowById" (PWild (PList)) (EVar "None"))
(DFunDef false "methodRowById" ((PVar "ident") (PCons (PVar "r") (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "mrIdent") (EVar "ident")) (EApp (EVar "Some") (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EVar "methodRowById") (EVar "ident")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "methodRowCand" (TyFun (TyCon "MethodRow") (TyTuple (TyCon "Ident") (TyCon "MethodEntry"))))
(DFunDef false "methodRowCand" ((PVar "r")) (ETuple (EFieldAccess (EVar "r") "mrIdent") (EFieldAccess (EVar "r") "mrEntry")))
(DTypeSig true "methodRowIface" (TyFun (TyCon "MethodRow") (TyCon "IfaceRef")))
(DFunDef false "methodRowIface" ((PVar "r")) (EMatch (EFieldAccess (EVar "r") "mrEntry") (arm (PTuple (PVar "iface") PWild PWild PWild) () (EVar "iface"))))
(DTypeSig true "methodPreludeRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyApp (TyCon "Option") (TyCon "MethodRow")))))
(DFunDef false "methodPreludeRow" ((PVar "n") (PVar "cs")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsMethod")) (EApp (EVar "OriginModule") (ELit (LString "core")))) (EVar "n"))) (ELam ((PVar "ident")) (EApp (EApp (EVar "methodRowById") (EVar "ident")) (EVar "cs")))))
(DTypeSig true "methodExportsIndex" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident")))))))
(DFunDef false "methodExportsIndex" ((PVar "gctx") PWild) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deMethods") "meExports"))
(DTypeSig true "dispatchTyparams" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dispatchTyparams" ((PList)) (EListLit))
(DFunDef false "dispatchTyparams" ((PCons (PVar "p") PWild)) (EListLit (EVar "p")))
(DTypeSig true "effTailNames" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "effTailNames" ((PCon "TyVar" PWild)) (EListLit))
(DFunDef false "effTailNames" ((PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "effTailNames" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "effTailNames") (EVar "a")) (EApp (EVar "effTailNames") (EVar "b"))))
(DFunDef false "effTailNames" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "effTailNames") (EVar "a")) (EApp (EVar "effTailNames") (EVar "b"))))
(DFunDef false "effTailNames" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EVar "effTailNames")) (EVar "ts")))
(DFunDef false "effTailNames" ((PCon "TyEffect" PWild (PVar "tail") (PVar "t"))) (EBinOp "++" (EVar "tail") (EApp (EVar "effTailNames") (EVar "t"))))
(DFunDef false "effTailNames" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "effTailNames") (EVar "t")))
(DFunDef false "effTailNames" ((PCon "TyRow" PWild (PVar "tail") PWild)) (EVar "tail"))
(DFunDef false "effTailNames" ((PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "effTailNames" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "effTailNames") (EVar "t")))
(DFunDef false "effTailNames" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "effTailNames") (EVar "t")))
(DTypeSig true "lookupBinding" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "EnvBinding")))))
(DFunDef false "lookupBinding" ((PVar "env") (PVar "n")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "env") "teVars")))
(DTypeSig true "lookupVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupVar" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "env") "teVars")) (arm (PCon "Some" (PVar "binding")) () (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EVar "binding") "ebValue") "vsScheme"))) (arm (PCon "None") () (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "env") "teCtors")))))
(DTypeSig true "lookupMethodRow" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodSchemeRow")))))
(DFunDef false "lookupMethodRow" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "n")) (arm (PCon "Some" (PVar "binding")) () (EFieldAccess (EVar "binding") "ebMethodRow")) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "lookupCtor" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupCtor" ((PVar "env") (PVar "n")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "env") "teCtors")))
(DTypeSig true "extendVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "TcEnv")))))
(DFunDef false "extendVar" ((PVar "env") (PVar "n") (PVar "s")) (ERecordUpdate (EVar "env") ((fa "teVars" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EVar "ordinaryEnvBinding") (EVar "s"))) (EFieldAccess (EVar "env") "teVars"))))))
(DTypeSig true "extendVars" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "TcEnv"))))
(DFunDef false "extendVars" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "extendVars" ((PVar "env") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EApp (EApp (EVar "extendVars") (EApp (EApp (EApp (EVar "extendVar") (EVar "env")) (EVar "n")) (EVar "s"))) (EVar "rest")))
(DTypeSig true "extendMethodRow" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "MethodSchemeRow") (TyCon "TcEnv")))))
(DFunDef false "extendMethodRow" ((PVar "env") (PVar "n") (PVar "row")) (ERecordUpdate (EVar "env") ((fa "teVars" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EVar "methodEnvBinding") (EVar "row"))) (EFieldAccess (EVar "env") "teVars"))))))
(DTypeSig true "extendMethodRows" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyCon "TcEnv"))))
(DFunDef false "extendMethodRows" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "extendMethodRows" ((PVar "env") (PCons (PVar "row") (PVar "rest"))) (EBlock (DoLet false false (PVar "env2") (EIf (EApp (EVar "methodRowCanCarry") (EVar "row")) (EApp (EApp (EApp (EVar "extendMethodRow") (EVar "env")) (EFieldAccess (EVar "row") "msrName")) (EVar "row")) (EApp (EApp (EApp (EVar "extendVar") (EVar "env")) (EFieldAccess (EVar "row") "msrName")) (EFieldAccess (EVar "row") "msrScheme")))) (DoExpr (EApp (EApp (EVar "extendMethodRows") (EVar "env2")) (EVar "rest")))))
(DTypeSig true "extendBindings" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EnvBinding"))) (TyCon "TcEnv"))))
(DFunDef false "extendBindings" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "extendBindings" ((PVar "env") (PCons (PTuple (PVar "n") (PVar "binding")) (PVar "rest"))) (EApp (EApp (EVar "extendBindings") (ERecordUpdate (EVar "env") ((fa "teVars" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "binding")) (EFieldAccess (EVar "env") "teVars")))))) (EVar "rest")))
(DTypeSig true "lookupStandaloneVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupStandaloneVar" ((PVar "env") (PVar "name")) (EApp (EApp (EVar "map") (ELam ((PVar "value")) (EFieldAccess (EVar "value") "vsScheme"))) (EApp (EApp (EVar "lookupStandaloneValue") (EVar "env")) (EVar "name"))))
(DTypeSig true "lookupStandaloneValue" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "ValueScheme")))))
(DFunDef false "lookupStandaloneValue" ((PVar "env") (PVar "name")) (EMatch (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "name")) (arm (PCon "Some" (PVar "binding")) () (EApp (EApp (EVar "map") (EVar "snd")) (EFieldAccess (EVar "binding") "ebStandalone"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "lookupImportedStandalone" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupImportedStandalone" ((PVar "env") (PVar "name")) (EMatch (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "name")) (arm (PCon "Some" (PVar "binding")) () (EMatch (EFieldAccess (EVar "binding") "ebStandalone") (arm (PCon "Some" (PTuple (PCon "ImportedStandalone") (PVar "value"))) () (EApp (EVar "Some") (EFieldAccess (EVar "value") "vsScheme"))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "hasImportDefiner" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasImportDefiner" ((PVar "mctx") (PVar "name")) (EApp (EVar "isSome") (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImportDefinersRef") "value"))))
(DTypeSig true "bindingWithStandalone" (TyFun (TyCon "EnvBinding") (TyFun (TyTuple (TyCon "StandaloneOrigin") (TyCon "ValueScheme")) (TyCon "EnvBinding"))))
(DFunDef false "bindingWithStandalone" ((PVar "binding") (PVar "source")) (ERecordCreate "EnvBinding" ((fa "ebValue" (EFieldAccess (EVar "binding") "ebValue")) (fa "ebMethodRow" (EFieldAccess (EVar "binding") "ebMethodRow")) (fa "ebStandalone" (EApp (EVar "Some") (EVar "source"))))))
(DTypeSig true "extendTermBindings" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "TcEnv"))))
(DFunDef false "extendTermBindings" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "extendTermBindings" ((PVar "env") (PCons (PTuple (PVar "name") (PVar "scheme")) (PVar "rest"))) (EApp (EApp (EVar "extendTermBindings") (EApp (EApp (EVar "extendBindings") (EVar "env")) (EListLit (ETuple (EVar "name") (EApp (EApp (EVar "bindingWithStandalone") (EApp (EVar "ordinaryEnvBinding") (EVar "scheme"))) (ETuple (EVar "LocalStandalone") (EApp (EVar "ordinaryValueScheme") (EVar "scheme")))))))) (EVar "rest")))
(DTypeSig true "extendLocalVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "TcEnv")))))
(DFunDef false "extendLocalVar" ((PVar "env") (PVar "n") (PVar "s")) (ERecordUpdate (EVar "env") ((fa "teVars" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EVar "ordinaryEnvBinding") (EVar "s"))) (EFieldAccess (EVar "env") "teVars"))) (fa "teAlphaLets" (EBinOp "::" (ETuple (EVar "n") (EVar "AParam")) (EFieldAccess (EVar "env") "teAlphaLets"))) (fa "teIsLocal" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "True")) (EFieldAccess (EVar "env") "teIsLocal"))))))
(DTypeSig true "extendLocalVars" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "TcEnv"))))
(DFunDef false "extendLocalVars" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "extendLocalVars" ((PVar "env") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EApp (EApp (EVar "extendLocalVars") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "n")) (EVar "s"))) (EVar "rest")))
(DTypeSig true "lookupLocalFlag" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "lookupLocalFlag" ((PVar "env") (PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "teIsLocal")))
(DTypeSig true "addCtor" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "TcEnv")))))
(DFunDef false "addCtor" ((PVar "env") (PVar "n") (PVar "s")) (ERecordUpdate (EVar "env") ((fa "teCtors" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "s")) (EFieldAccess (EVar "env") "teCtors"))))))
(DTypeSig true "withCtors" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyCon "TcEnv"))))
(DFunDef false "withCtors" ((PVar "mctx") (PVar "cs")) (ERecordCreate "TcEnv" ((fa "teVars" (EVar "omEmpty")) (fa "teCtors" (EVar "cs")) (fa "teAlphaLets" (EListLit)) (fa "teIsLocal" (EVar "omEmpty")) (fa "teDyn" (EApp (EVar "dynFor") (EVar "mctx"))))))
(DTypeSig true "seedAlphaLets" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "TcEnv")))))
(DFunDef false "seedAlphaLets" ((PVar "env") (PVar "n") (PVar "rhs")) (ERecordUpdate (EVar "env") ((fa "teAlphaLets" (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "ALet") (EVar "rhs"))) (EFieldAccess (EVar "env") "teAlphaLets"))))))
(DTypeSig true "envAlphaLets" (TyFun (TyCon "TcEnv") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder")))))
(DFunDef false "envAlphaLets" ((PVar "env")) (EFieldAccess (EVar "env") "teAlphaLets"))
(DTypeSig true "originMethodName" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "originMethodName" ((PVar "mctx") (PVar "name")) (EApp (EApp (EVar "optionOr") (EVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasMethodOriginsRef") "value"))))
(DTypeSig true "lookupIdxById" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int"))) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "lookupIdxById" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "lookupIdxById" ((PVar "iface") (PVar "n") (PCons (PTuple (PTuple (PVar "ir") (PVar "mn")) (PVar "i")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "mn") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EFieldAccess (EVar "ir") "irName")) (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "iface") "irName")) (EFieldAccess (EVar "iface") "irOrigin"))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lookupIdxById") (EVar "iface")) (EVar "n")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "methodRowCanCarry" (TyFun (TyCon "MethodSchemeRow") (TyCon "Bool")))
(DFunDef false "methodRowCanCarry" ((PVar "row")) (EBinOp "&&" (EApp (EVar "isSome") (EApp (EVar "identOriginOf") (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irOrigin"))) (EApp (EVar "not") (EApp (EApp (EVar "anyArgMentions") (EApp (EVar "dispatchTyparams") (EFieldAccess (EVar "row") "msrTyparams"))) (EApp (EVar "methodArgs") (EFieldAccess (EVar "row") "msrType"))))))
(DTypeSig true "envVarType" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "envVarType" ((PVar "env") (PVar "x")) (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EApp (EVar "schemeBodyOf") (EFieldAccess (EFieldAccess (EVar "b") "ebValue") "vsScheme")))) (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "x"))))
(DTypeSig true "lookupRecordByName" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RecordInfo")))))
(DFunDef false "lookupRecordByName" ((PVar "mctx") (PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef") "value")))
(DTypeSig true "declParamKinds" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyCon "Kind"))))))
(DFunDef false "declParamKinds" ((PVar "gctx") (PVar "params") (PVar "anns")) (EApp (EApp (EVar "map") (EApp (EVar "kindOfAnn") (EVar "gctx"))) (EApp (EApp (EVar "padAnns") (EVar "params")) (EVar "anns"))))
(DTypeSig true "padAnns" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))))))
(DFunDef false "padAnns" ((PList) PWild) (EListLit))
(DFunDef false "padAnns" ((PCons PWild (PVar "ps")) (PCons (PVar "a") (PVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EApp (EVar "padAnns") (EVar "ps")) (EVar "rest"))))
(DFunDef false "padAnns" ((PCons PWild (PVar "ps")) (PList)) (EBinOp "::" (EVar "None") (EApp (EApp (EVar "padAnns") (EVar "ps")) (EListLit))))
(DTypeSig false "kindOfAnn" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "Option") (TyCon "KindAnn")) (TyCon "Kind"))))
(DFunDef false "kindOfAnn" ((PVar "gctx") (PCon "Some" (PCon "KindEffect"))) (EVar "KRow"))
(DFunDef false "kindOfAnn" ((PVar "gctx") (PCon "Some" (PCon "KindAuthority" (PVar "l") (PVar "o") (PVar "pat") PWild))) (EApp (EApp (EVar "KAuth") (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))) (EApp (EApp (EApp (EVar "rangedOver") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))) (EVar "pat"))))
(DFunDef false "kindOfAnn" ((PVar "gctx") PWild) (EVar "KType"))
(DTypeSig true "kindAnnSlots" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "KindAnn") (TyApp (TyCon "List") (TyCon "Kind")))))
(DFunDef false "kindAnnSlots" ((PVar "gctx") (PCon "KindArrow" (PVar "a") (PVar "b"))) (EBinOp "::" (EApp (EApp (EVar "kindAnnAtom") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "kindAnnSlots") (EVar "gctx")) (EVar "b"))))
(DFunDef false "kindAnnSlots" ((PVar "gctx") PWild) (EListLit))
(DTypeSig false "kindAnnAtom" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "KindAnn") (TyCon "Kind"))))
(DFunDef false "kindAnnAtom" ((PVar "gctx") (PCon "KindEffect")) (EVar "KRow"))
(DFunDef false "kindAnnAtom" ((PVar "gctx") (PCon "KindAuthority" (PVar "l") (PVar "o") (PVar "pat") PWild)) (EApp (EApp (EVar "KAuth") (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))) (EApp (EApp (EApp (EVar "rangedOver") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))) (EVar "pat"))))
(DFunDef false "kindAnnAtom" ((PVar "gctx") PWild) (EVar "KType"))
(DTypeSig true "anyKRow" (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Bool")))
(DFunDef false "anyKRow" ((PList)) (EVar "False"))
(DFunDef false "anyKRow" ((PCons (PCon "KRow") PWild)) (EVar "True"))
(DFunDef false "anyKRow" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyKRow") (EVar "rest")))
(DTypeSig true "declGradedScope" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))))))
(DFunDef false "declGradedScope" ((PVar "gctx") (PList) PWild PWild) (EListLit))
(DFunDef false "declGradedScope" ((PVar "gctx") (PCons (PVar "p") (PVar "ps")) (PList) (PVar "methods")) (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EVar "gctx")) (EBinOp "::" (EVar "p") (EVar "ps"))) (EListLit (EVar "None"))) (EVar "methods")))
(DFunDef false "declGradedScope" ((PVar "gctx") (PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "anns")) (PVar "methods")) (EApp (EApp (EApp (EVar "declGradedScopeAdd") (EVar "p")) (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDecl") (EVar "gctx")) (EVar "a")) (EVar "p")) (EVar "methods"))) (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EVar "gctx")) (EVar "ps")) (EVar "anns")) (EVar "methods"))))
(DTypeSig false "ifaceParamKindsDecl" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "Option") (TyCon "KindAnn")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "Kind")))))))
(DFunDef false "ifaceParamKindsDecl" ((PVar "gctx") (PCon "Some" (PCon "KindArrow" (PVar "a") (PVar "b"))) PWild PWild) (EApp (EApp (EVar "kindAnnSlots") (EVar "gctx")) (EApp (EApp (EVar "KindArrow") (EVar "a")) (EVar "b"))))
(DFunDef false "ifaceParamKindsDecl" ((PVar "gctx") PWild (PVar "p") (PVar "methods")) (EApp (EApp (EVar "map") (ELam (PWild) (EVar "KType"))) (EApp (EApp (EVar "ifaceParamKindsOf") (EVar "p")) (EVar "methods"))))
(DTypeSig false "declGradedScopeAdd" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "declGradedScopeAdd" ((PVar "p") (PVar "kinds") (PVar "rest")) (EIf (EApp (EVar "anyKRow") (EVar "kinds")) (EBinOp "::" (ETuple (EVar "p") (EVar "kinds")) (EVar "rest")) (EIf (EVar "otherwise") (EVar "rest") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ifaceParamKindsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "Kind")))))
(DFunDef false "ifaceParamKindsOf" ((PVar "p") (PVar "methods")) (EMatch (EApp (EApp (EVar "flatMap") (EApp (EVar "ifaceMethodVarApps") (EVar "p"))) (EVar "methods")) (arm (PList) () (EListLit)) (arm (PAs "apps" (PCons (PTuple (PVar "args0") PWild) PWild)) () (EApp (EApp (EApp (EVar "ifaceSlotKinds") (EApp (EVar "listLen") (EVar "args0"))) (ELit (LInt 0))) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EBinOp "==" (EApp (EVar "listLen") (EApp (EVar "fst") (EVar "a"))) (EApp (EVar "listLen") (EVar "args0"))))) (EVar "apps"))))))
(DTypeSig false "ifaceMethodVarApps" (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ifaceMethodVarApps" ((PVar "p") (PCon "IfaceMethod" PWild (PVar "mty") PWild PWild)) (EBlock (DoLet false false (PVar "tails") (EApp (EVar "dedup") (EApp (EVar "effTailNames") (EVar "mty")))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "args")) (ETuple (EVar "args") (EVar "tails")))) (EApp (EApp (EVar "varHeadApps") (EVar "p")) (EVar "mty"))))))
(DTypeSig false "ifaceSlotKinds" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "Kind"))))))
(DFunDef false "ifaceSlotKinds" ((PVar "arity") (PVar "i") (PVar "apps")) (EIf (EBinOp ">=" (EVar "i") (EVar "arity")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EIf (EApp (EApp (EVar "anySlotIsRow") (EVar "i")) (EVar "apps")) (EVar "KRow") (EVar "KType")) (EApp (EApp (EApp (EVar "ifaceSlotKinds") (EVar "arity")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "apps"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "anySlotIsRow" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Bool"))))
(DFunDef false "anySlotIsRow" (PWild (PList)) (EVar "False"))
(DFunDef false "anySlotIsRow" ((PVar "i") (PCons (PTuple (PVar "args") (PVar "tails")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "nthTy") (EVar "i")) (EVar "args")) (arm (PCon "Some" (PCon "TyVar" (PVar "n"))) () (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "n")) (EVar "tails")) (EApp (EApp (EVar "anySlotIsRow") (EVar "i")) (EVar "rest")))) (arm PWild () (EApp (EApp (EVar "anySlotIsRow") (EVar "i")) (EVar "rest")))))
(DTypeSig false "varHeadApps" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Ty"))))))
(DFunDef false "varHeadApps" ((PVar "p") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "sp") (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b")))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EVar "varHeadHere") (EVar "p")) (EApp (EVar "fst") (EVar "sp"))) (EApp (EVar "snd") (EVar "sp"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "varHeadApps") (EVar "p"))) (EApp (EVar "snd") (EVar "sp")))))))
(DFunDef false "varHeadApps" ((PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "varHeadApps") (EVar "p")) (EVar "a")) (EApp (EApp (EVar "varHeadApps") (EVar "p")) (EVar "b"))))
(DFunDef false "varHeadApps" ((PVar "p") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "varHeadApps") (EVar "p"))) (EVar "ts")))
(DFunDef false "varHeadApps" ((PVar "p") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "varHeadApps") (EVar "p")) (EVar "t")))
(DFunDef false "varHeadApps" ((PVar "p") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "varHeadApps") (EVar "p")) (EVar "t")))
(DFunDef false "varHeadApps" (PWild PWild) (EListLit))
(DTypeSig false "varHeadHere" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Ty")))))))
(DFunDef false "varHeadHere" ((PVar "p") (PCon "TyVar" (PVar "h")) (PVar "args")) (EIf (EBinOp "==" (EVar "h") (EVar "p")) (EListLit (EVar "args")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "varHeadHere" (PWild PWild PWild) (EListLit))
(DTypeSig true "funClausePair" (TyFun (TyCon "FunClause") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "funClausePair" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "pats") (EVar "body")))
(DTypeSig true "funDefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "funDefs" ((PList)) (EListLit))
(DFunDef false "funDefs" ((PCons (PCon "DFunDef" PWild (PVar "n") (PVar "pats") (PVar "body") PWild PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (ETuple (EVar "pats") (EVar "body"))) (EApp (EVar "funDefs") (EVar "rest"))))
(DFunDef false "funDefs" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "letGroupDefs") (EVar "binds")) (EApp (EVar "funDefs") (EVar "rest"))))
(DFunDef false "funDefs" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "funDefs") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "funDefs" ((PCons PWild (PVar "rest"))) (EApp (EVar "funDefs") (EVar "rest")))
(DTypeSig false "letGroupDefs" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "letGroupDefs" ((PList)) (EListLit))
(DFunDef false "letGroupDefs" ((PCons (PCon "LetBind" (PVar "n") (PVar "clauses") PWild PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "tcClauseDef") (EVar "n"))) (EVar "clauses")) (EApp (EVar "letGroupDefs") (EVar "rest"))))
(DTypeSig false "tcClauseDef" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "tcClauseDef" ((PVar "n") (PVar "c")) (ETuple (EVar "n") (EApp (EVar "funClausePair") (EVar "c"))))
(DTypeSig true "methodArgs" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "methodArgs" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodArgs") (EVar "t")))
(DFunDef false "methodArgs" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodArgs") (EVar "t")))
(DFunDef false "methodArgs" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "methodArgs") (EVar "b"))))
(DFunDef false "methodArgs" (PWild) (EListLit))
(DTypeSig true "anyArgMentions" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "anyArgMentions" (PWild (PList)) (EVar "False"))
(DFunDef false "anyArgMentions" ((PVar "typarams") (PCons (PVar "ty") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "argMentions") (EVar "typarams")) (EVar "ty")) (EApp (EApp (EVar "anyArgMentions") (EVar "typarams")) (EVar "rest"))))
(DTypeSig true "constraintSlotDispatchVar" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "constraintSlotDispatchVar" ((PVar "typarams") (PRec "Constraint" ((rf "constraintArgs" (PVar "args"))) false)) (EBlock (DoLet false false (PVar "vars") (EApp (EApp (EVar "flatMap") (EVar "tyVarNames")) (EVar "args"))) (DoExpr (EMatch (EApp (EApp (EVar "removeAllS") (EVar "typarams")) (EVar "vars")) (arm (PCons (PVar "n") PWild) () (EListLit (EVar "n"))) (arm (PList) () (EMatch (EVar "vars") (arm (PCons (PVar "n") PWild) () (EListLit (EVar "n"))) (arm (PList) () (EListLit))))))))
(DTypeSig false "headTabIs" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyCon "TabKey") (TyCon "Bool"))))
(DFunDef false "headTabIs" ((PCon "Some" (PVar "hk")) (PVar "goal")) (EBinOp "==" (EApp (EVar "dispHeadTab") (EVar "hk")) (EVar "goal")))
(DFunDef false "headTabIs" ((PCon "None") PWild) (EVar "False"))
(DTypeSig false "headTabEq" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyApp (TyCon "Option") (TyCon "TabKey")) (TyCon "Bool"))))
(DFunDef false "headTabEq" ((PVar "hd") (PCon "Some" (PVar "goal"))) (EApp (EApp (EVar "headTabIs") (EVar "hd")) (EVar "goal")))
(DFunDef false "headTabEq" ((PCon "None") (PCon "None")) (EVar "True"))
(DFunDef false "headTabEq" ((PCon "Some" PWild) (PCon "None")) (EVar "False"))
(DTypeSig false "headTabOf" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyApp (TyCon "Option") (TyCon "TabKey"))))
(DFunDef false "headTabOf" ((PCon "None")) (EVar "None"))
(DFunDef false "headTabOf" ((PCon "Some" (PVar "hk"))) (EApp (EVar "Some") (EApp (EVar "dispHeadTab") (EVar "hk"))))
(DTypeSig true "ieImplExistsForHeadOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyCon "HeadKey") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))) (TyCon "Bool")))))))
(DFunDef false "ieImplExistsForHeadOf" ((PVar "mctx") (PVar "env") (PVar "name") (PVar "hk") (PVar "admitted")) (EApp (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHeadGo") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "ieHeadRows") (EApp (EVar "Some") (EVar "hk"))) (EVar "env"))) (EApp (EApp (EVar "originMethodName") (EVar "mctx")) (EVar "name"))) (EApp (EVar "dispHeadTab") (EVar "hk"))) (EVar "admitted")))
(DTypeSig false "ieImplExistsForHeadGo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "String") (TyFun (TyCon "TabKey") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))) (TyCon "Bool")))))))
(DFunDef false "ieImplExistsForHeadGo" ((PVar "gctx") (PList) PWild PWild PWild) (EVar "False"))
(DFunDef false "ieImplExistsForHeadGo" ((PVar "gctx") (PCons (PAs "r" (PCon "ImplRow" PWild PWild (PVar "ir") (PVar "tys") PWild (PVar "ms") PWild)) (PVar "rest")) (PVar "name") (PVar "goal") (PVar "admitted")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "headTabIs") (EApp (EVar "univReceiverTag") (EVar "tys"))) (EVar "goal")) (EApp (EApp (EVar "ieRowAdmittedBy") (EVar "ir")) (EVar "admitted"))) (EApp (EApp (EApp (EApp (EApp (EVar "ieRowAnswersMethod") (EVar "gctx")) (EVar "r")) (EVar "ms")) (EVar "name")) (EVar "admitted"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHeadGo") (EVar "gctx")) (EVar "rest")) (EVar "name")) (EVar "goal")) (EVar "admitted")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ieRowAdmittedBy" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))) (TyCon "Bool"))))
(DFunDef false "ieRowAdmittedBy" (PWild (PCon "None")) (EVar "True"))
(DFunDef false "ieRowAdmittedBy" ((PVar "ir") (PCon "Some" (PVar "ifaces"))) (EApp (EApp (EVar "anyList") (EApp (EVar "ieRowIfaceMatches") (EVar "ir"))) (EVar "ifaces")))
(DTypeSig true "ieDefinesReqMethodAt" (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyCon "Bool")))))
(DFunDef false "ieDefinesReqMethodAt" ((PVar "env") (PVar "method") (PVar "hd")) (EApp (EApp (EApp (EVar "ieDefinesReqMethodAtGo") (EApp (EApp (EVar "ieHeadRows") (EVar "hd")) (EVar "env"))) (EVar "method")) (EApp (EVar "headTabOf") (EVar "hd"))))
(DTypeSig false "ieDefinesReqMethodAtGo" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "TabKey")) (TyCon "Bool")))))
(DFunDef false "ieDefinesReqMethodAtGo" ((PList) PWild PWild) (EVar "False"))
(DFunDef false "ieDefinesReqMethodAtGo" ((PCons (PCon "ImplRow" PWild PWild PWild (PVar "tys") (PVar "reqs") (PVar "ms") PWild) (PVar "rest")) (PVar "method") (PVar "goal")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "implRowHasReqs") (EVar "reqs")) (EApp (EApp (EVar "headTabEq") (EApp (EVar "univReceiverTag") (EVar "tys"))) (EVar "goal"))) (EApp (EApp (EVar "contains") (EVar "method")) (EVar "ms"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "ieDefinesReqMethodAtGo") (EVar "rest")) (EVar "method")) (EVar "goal")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implRowHasReqs" (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyCon "Bool")))
(DFunDef false "implRowHasReqs" ((PList)) (EVar "False"))
(DFunDef false "implRowHasReqs" (PWild) (EVar "True"))
(DTypeSig false "requiredMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "requiredMethodNames" ((PList)) (EListLit))
(DFunDef false "requiredMethodNames" ((PCons (PCon "IfaceMethod" (PVar "n") PWild (PCon "None") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "requiredMethodNames") (EVar "rest"))))
(DFunDef false "requiredMethodNames" ((PCons (PCon "IfaceMethod" PWild PWild (PCon "Some" PWild) PWild) (PVar "rest"))) (EApp (EVar "requiredMethodNames") (EVar "rest")))
(DTypeSig true "recordCandInfo" (TyFun (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "RecordInfo")) (TyCon "RecordInfo")))
(DFunDef false "recordCandInfo" ((PTuple PWild PWild (PVar "ri"))) (EVar "ri"))
(DTypeSig true "ceRowIfaceName" (TyFun (TyCon "CeRow") (TyCon "String")))
(DFunDef false "ceRowIfaceName" ((PVar "r")) (EMatch (EApp (EVar "ceRowIface") (EVar "r")) (arm (PRec "IfaceRef" ((rf "irName" (PVar "n"))) true) () (EVar "n"))))
(DTypeSig true "ceRowDoneKey" (TyFun (TyCon "CeRow") (TyCon "String")))
(DFunDef false "ceRowDoneKey" ((PVar "r")) (EApp (EVar "regKeyRender") (EApp (EVar "ceRowKey") (EVar "r"))))
(DTypeSig false "implMethodNameTc" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodNameTc" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "keyEntryIdx" (TyFun (TyCon "KeyEntry") (TyCon "Int")))
(DFunDef false "keyEntryIdx" ((PCon "KeyEntry" PWild PWild PWild PWild PWild PWild PWild (PVar "i"))) (EVar "i"))
(DTypeSig false "headBucketKey" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyCon "RegKey")))
(DFunDef false "headBucketKey" ((PCon "None")) (EVar "headlessBucketKey"))
(DFunDef false "headBucketKey" ((PCon "Some" (PVar "hk"))) (EApp (EVar "regKeyOfTab") (EApp (EVar "dispHeadTab") (EVar "hk"))))
(DTypeSig false "headlessBucketKey" (TyCon "RegKey"))
(DFunDef false "headlessBucketKey" () (EApp (EVar "regKeyNTab") (EListLit)))
(DTypeSig false "implKeyTc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "String"))))
(DFunDef false "implKeyTc" ((PVar "iface") (PVar "tys")) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "OriginUnresolved")) (EVar "iface")) (EVar "tys")) (EVar "None")))
(DTypeSig false "mergeByDeclIdx" (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyApp (TyCon "List") (TyCon "KeyEntry")))))
(DFunDef false "mergeByDeclIdx" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "mergeByDeclIdx" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "mergeByDeclIdx" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EApp (EVar "keyEntryIdx") (EVar "x")) (EApp (EVar "keyEntryIdx") (EVar "y"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "mergeByDeclIdx") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "mergeByDeclIdx") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "keyEntryOfRow" (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "KeyEntry"))))
(DFunDef false "keyEntryOfRow" ((PCon "ImplRow" PWild (PVar "inst") (PVar "ir") (PVar "tys") (PVar "reqs") (PVar "ms") PWild)) (EMatch (EVar "tys") (arm (PCons (PVar "headTy") PWild) () (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "KeyEntry") (EVar "ms")) (EApp (EVar "headTyconTy") (EVar "headTy"))) (EVar "headTy")) (EApp (EApp (EVar "implKeyTc") (EFieldAccess (EVar "ir") "irName")) (EVar "tys"))) (EFieldAccess (EVar "ir") "irName")) (EVar "tys")) (EVar "reqs")) (EApp (EVar "instRefSeq") (EVar "inst"))))) (arm (PList) () (EListLit))))
(DTypeSig false "ieRowHeadMatches" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "ieRowHeadMatches" ((PAs "tys" (PCons (PVar "headTy") PWild)) (PVar "goals")) (EApp (EApp (EApp (EVar "entryHeadMatches") (EVar "headTy")) (EVar "tys")) (EVar "goals")))
(DFunDef false "ieRowHeadMatches" ((PList) PWild) (EVar "False"))
(DTypeSig true "ieRowIfaceMatches" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "ieRowIfaceMatches" ((PVar "ir") (PVar "iface")) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EFieldAccess (EVar "ir") "irName")) (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "iface") "irName")) (EFieldAccess (EVar "iface") "irOrigin")))
(DTypeSig true "ieEntriesForIface" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "KeyEntry"))))))
(DFunDef false "ieEntriesForIface" ((PList) PWild PWild) (EListLit))
(DFunDef false "ieEntriesForIface" ((PCons (PAs "r" (PCon "ImplRow" PWild PWild (PVar "ir") (PVar "tys") PWild PWild PWild)) (PVar "rest")) (PVar "iface") (PVar "goals")) (EIf (EBinOp "&&" (EApp (EApp (EVar "ieRowIfaceMatches") (EVar "ir")) (EVar "iface")) (EApp (EApp (EVar "ieRowHeadMatches") (EVar "tys")) (EVar "goals"))) (EBinOp "++" (EApp (EVar "keyEntryOfRow") (EVar "r")) (EApp (EApp (EApp (EVar "ieEntriesForIface") (EVar "rest")) (EVar "iface")) (EVar "goals"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "ieEntriesForIface") (EVar "rest")) (EVar "iface")) (EVar "goals")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ieEntriesForMethod" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "KeyEntry"))))))))
(DFunDef false "ieEntriesForMethod" ((PVar "gctx") (PList) PWild PWild PWild) (EListLit))
(DFunDef false "ieEntriesForMethod" ((PVar "gctx") (PCons (PAs "r" (PCon "ImplRow" PWild PWild (PVar "ir") (PVar "tys") PWild (PVar "ms") PWild)) (PVar "rest")) (PVar "name") (PVar "admitted") (PVar "goals")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "ieRowAdmittedBy") (EVar "ir")) (EVar "admitted")) (EApp (EApp (EVar "ieRowHeadMatches") (EVar "tys")) (EVar "goals"))) (EApp (EApp (EApp (EApp (EApp (EVar "ieRowAnswersMethod") (EVar "gctx")) (EVar "r")) (EVar "ms")) (EVar "name")) (EVar "admitted"))) (EBinOp "++" (EApp (EVar "keyEntryOfRow") (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "ieEntriesForMethod") (EVar "gctx")) (EVar "rest")) (EVar "name")) (EVar "admitted")) (EVar "goals"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "ieEntriesForMethod") (EVar "gctx")) (EVar "rest")) (EVar "name")) (EVar "admitted")) (EVar "goals")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ieRowAnswersMethod" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ImplRow") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))) (TyCon "Bool")))))))
(DFunDef false "ieRowAnswersMethod" ((PVar "gctx") PWild (PVar "ms") (PVar "name") (PCon "None")) (EApp (EApp (EVar "contains") (EVar "name")) (EVar "ms")))
(DFunDef false "ieRowAnswersMethod" ((PVar "gctx") (PVar "r") (PVar "ms") (PVar "name") (PCon "Some" PWild)) (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "name")) (EVar "ms")) (EApp (EApp (EApp (EVar "ieRowInheritsDefault") (EVar "gctx")) (EVar "r")) (EVar "name"))))
(DTypeSig false "ieRowInheritsDefault" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ImplRow") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "ieRowInheritsDefault" ((PVar "gctx") (PVar "r") (PVar "name")) (EBlock (DoLet false false (PTuple (PVar "iface") PWild PWild) (EApp (EVar "ieRowTriple") (EVar "r"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")))) (EApp (EVar "ieRowOrd") (EVar "r"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deIfaces")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "ceRow")) () (EBinOp "&&" (EApp (EApp (EVar "contains") (EVar "name")) (EApp (EVar "ceRowMethodNames") (EVar "ceRow"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "name")) (EApp (EVar "ceRowRequired") (EVar "ceRow"))))))))))
(DTypeSig true "ieCandidatesForIface" (TyFun (TyCon "ImplEnv") (TyFun (TyCon "HeadKey") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "KeyEntry")))))))
(DFunDef false "ieCandidatesForIface" ((PVar "env") (PVar "hk") (PVar "iface") (PVar "goals")) (EApp (EApp (EVar "mergeByDeclIdx") (EApp (EApp (EApp (EVar "ieEntriesForIface") (EApp (EApp (EVar "ieHeadRows") (EApp (EVar "Some") (EVar "hk"))) (EVar "env"))) (EVar "iface")) (EVar "goals"))) (EApp (EApp (EApp (EVar "ieEntriesForIface") (EApp (EApp (EVar "ieHeadRows") (EVar "None")) (EVar "env"))) (EVar "iface")) (EVar "goals"))))
(DTypeSig true "ieCandidatesForMethod" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "KeyEntry")))))))))
(DFunDef false "ieCandidatesForMethod" ((PVar "gctx") (PVar "env") (PVar "hk") (PVar "name") (PVar "admitted") (PVar "goals")) (EApp (EApp (EVar "mergeByDeclIdx") (EApp (EApp (EApp (EApp (EApp (EVar "ieEntriesForMethod") (EVar "gctx")) (EApp (EApp (EVar "ieHeadRows") (EApp (EVar "Some") (EVar "hk"))) (EVar "env"))) (EVar "name")) (EVar "admitted")) (EVar "goals"))) (EApp (EApp (EApp (EApp (EApp (EVar "ieEntriesForMethod") (EVar "gctx")) (EApp (EApp (EVar "ieHeadRows") (EVar "None")) (EVar "env"))) (EVar "name")) (EVar "admitted")) (EVar "goals"))))
(DTypeSig true "ieRowOfEntry" (TyFun (TyCon "ImplEnv") (TyFun (TyApp (TyCon "Option") (TyCon "KeyEntry")) (TyApp (TyCon "Option") (TyCon "ImplRow")))))
(DFunDef false "ieRowOfEntry" (PWild (PCon "None")) (EVar "None"))
(DFunDef false "ieRowOfEntry" ((PVar "env") (PCon "Some" (PCon "KeyEntry" PWild (PVar "hd") PWild PWild PWild PWild PWild (PVar "idx")))) (EApp (EApp (EVar "ieRowWithSeq") (EApp (EApp (EVar "ieHeadRows") (EVar "hd")) (EVar "env"))) (EVar "idx")))
(DTypeSig false "ieRowWithSeq" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "ImplRow")))))
(DFunDef false "ieRowWithSeq" ((PList) PWild) (EVar "None"))
(DFunDef false "ieRowWithSeq" ((PCons (PAs "r" (PCon "ImplRow" PWild (PVar "inst") PWild PWild PWild PWild PWild)) (PVar "rest")) (PVar "s")) (EIf (EBinOp "==" (EApp (EVar "instRefSeq") (EVar "inst")) (EVar "s")) (EApp (EVar "Some") (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EVar "ieRowWithSeq") (EVar "rest")) (EVar "s")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ieRowHeadTriple" (TyFun (TyApp (TyCon "Option") (TyCon "ImplRow")) (TyApp (TyCon "Option") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))))))
(DFunDef false "ieRowHeadTriple" ((PCon "None")) (EVar "None"))
(DFunDef false "ieRowHeadTriple" ((PCon "Some" (PCon "ImplRow" PWild PWild PWild (PAs "tys" (PCons (PVar "headTy") PWild)) (PVar "reqs") PWild PWild))) (EApp (EVar "Some") (ETuple (EVar "headTy") (EVar "tys") (EVar "reqs"))))
(DFunDef false "ieRowHeadTriple" ((PCon "Some" PWild)) (EVar "None"))
(DTypeSig false "growImplUniverse" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))) (TyFun (TyCon "ImplUniverse") (TyCon "ImplUniverse"))))
(DFunDef false "growImplUniverse" ((PList) (PVar "univ")) (EVar "univ"))
(DFunDef false "growImplUniverse" ((PCons (PVar "t") (PVar "rest")) (PVar "univ")) (EApp (EApp (EVar "growImplUniverse") (EVar "rest")) (EApp (EApp (EVar "insertUnivImpl") (EVar "univ")) (EVar "t"))))
(DTypeSig false "insertUnivImpl" (TyFun (TyCon "ImplUniverse") (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))) (TyCon "ImplUniverse"))))
(DFunDef false "insertUnivImpl" ((PVar "univ") (PTuple (PVar "iface") (PVar "tys") (PVar "reqs"))) (EApp (EApp (EApp (EApp (EVar "insertUnivImplKeys") (EApp (EVar "oblIfaceKeys") (EVar "iface"))) (EVar "tys")) (EVar "reqs")) (EVar "univ")))
(DTypeSig false "insertUnivImplKeys" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyCon "ImplUniverse") (TyCon "ImplUniverse"))))))
(DFunDef false "insertUnivImplKeys" ((PList) PWild PWild (PVar "univ")) (EVar "univ"))
(DFunDef false "insertUnivImplKeys" ((PCons (PVar "ifk") (PVar "rest")) (PVar "tys") (PVar "reqs") (PVar "univ")) (EApp (EApp (EApp (EApp (EVar "insertUnivImplKeys") (EVar "rest")) (EVar "tys")) (EVar "reqs")) (EApp (EApp (EApp (EApp (EVar "insertUnivImplAt") (EVar "ifk")) (EVar "tys")) (EVar "reqs")) (EVar "univ"))))
(DTypeSig false "oblIfaceKeys" (TyFun (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "TabKey"))))
(DFunDef false "oblIfaceKeys" ((PVar "ir")) (EMatch (EFieldAccess (EVar "ir") "irOrigin") (arm (PCon "OriginUnresolved") () (EListLit (EApp (EApp (EVar "TkBare") (EVar "NsIface")) (EFieldAccess (EVar "ir") "irName")))) (arm PWild () (EListLit (EApp (EVar "oblIfaceKey") (EVar "ir")) (EApp (EApp (EVar "TkBare") (EVar "NsIface")) (EFieldAccess (EVar "ir") "irName"))))))
(DTypeSig false "insertUnivImplAt" (TyFun (TyCon "TabKey") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyCon "ImplUniverse") (TyCon "ImplUniverse"))))))
(DFunDef false "insertUnivImplAt" ((PVar "ifk") (PVar "tys") (PVar "reqs") (PCon "ImplUniverse" (PVar "conc") (PVar "hl"))) (EMatch (EApp (EVar "univReceiverTag") (EVar "tys")) (arm (PCon "Some" (PVar "hk")) () (EApp (EApp (EVar "ImplUniverse") (EApp (EApp (EApp (EVar "mregAppendK") (EApp (EVar "regKeyNTab") (EListLit (EVar "ifk") (EApp (EVar "dispHeadTab") (EVar "hk"))))) (ETuple (EVar "tys") (EVar "reqs"))) (EVar "conc"))) (EVar "hl"))) (arm (PCon "None") () (EApp (EApp (EVar "ImplUniverse") (EVar "conc")) (EApp (EApp (EApp (EVar "mregAppendK") (EApp (EVar "regKeyOfTab") (EVar "ifk"))) (ETuple (EVar "tys") (EVar "reqs"))) (EVar "hl"))))))
(DTypeSig true "oblIfaceKey" (TyFun (TyCon "IfaceRef") (TyCon "TabKey")))
(DFunDef false "oblIfaceKey" ((PVar "ir")) (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsIface")) (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "ir") "irName")))
(DTypeSig true "dispHeadTab" (TyFun (TyCon "HeadKey") (TyCon "TabKey")))
(DFunDef false "dispHeadTab" ((PVar "hk")) (EApp (EApp (EVar "TkBare") (EVar "NsType")) (EApp (EVar "headKeyTag") (EVar "hk"))))
(DTypeSig false "univReceiverTag" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "HeadKey"))))
(DFunDef false "univReceiverTag" ((PCons (PVar "headTy") PWild)) (EApp (EVar "headTyconTy") (EVar "headTy")))
(DFunDef false "univReceiverTag" ((PList)) (EVar "None"))
(DTypeSig true "ieRowOfIface" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "ImplRow") (TyCon "Bool"))))
(DFunDef false "ieRowOfIface" ((PVar "iface") (PCon "ImplRow" PWild PWild (PVar "ir") PWild PWild PWild PWild)) (EApp (EApp (EVar "ieRowIfaceMatches") (EVar "ir")) (EVar "iface")))
(DTypeSig true "ieRowTys" (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "ieRowTys" ((PCon "ImplRow" PWild PWild PWild (PVar "tys") PWild PWild PWild)) (EVar "tys"))
(DTypeSig true "methodLevelConstraintVarNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodLevelConstraintVarNames" ((PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "constraintSlotDispatchVar") (EVar "typarams"))) (EVar "cs")) (EApp (EApp (EVar "methodLevelConstraintVarNames") (EVar "typarams")) (EVar "t"))))
(DFunDef false "methodLevelConstraintVarNames" ((PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "methodLevelConstraintVarNames") (EVar "typarams")) (EVar "t")))
(DFunDef false "methodLevelConstraintVarNames" (PWild PWild) (EListLit))
(DTypeSig true "removeAllS" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "removeAllS" ((PVar "drop") (PVar "xs")) (EApp (EApp (EVar "filter") (ELam ((PVar "x")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "x")) (EVar "drop"))))) (EVar "xs")))
(DTypeSig true "ceMethodTyAt" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))))))))
(DFunDef false "ceMethodTyAt" ((PVar "iface") (PVar "mname") (PVar "cur") (PVar "ce")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EVar "key")) (EVar "cur")) (EVar "ce")) (arm (PCon "Some" (PVar "row")) () (EApp (EApp (EApp (EVar "ceMethodTyIn") (EApp (EVar "ceRowTyparams") (EVar "row"))) (EVar "mname")) (EApp (EVar "ceRowMethods") (EVar "row")))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "ceMethodTyIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))))
(DFunDef false "ceMethodTyIn" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "ceMethodTyIn" ((PVar "typarams") (PVar "mname") (PCons (PTuple (PVar "name") (PVar "mty") (PVar "scope")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "mname")) (EApp (EVar "Some") (ETuple (EVar "typarams") (EVar "mty") (EVar "scope"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "ceMethodTyIn") (EVar "typarams")) (EVar "mname")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "sameIfaceDecl" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "sameIfaceDecl" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "tabKeyEq") (EApp (EVar "oblIfaceKey") (EVar "a"))) (EApp (EVar "oblIfaceKey") (EVar "b"))))
(DTypeSig true "legacyMethodSchemes" (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))
(DFunDef false "legacyMethodSchemes" ((PList)) (EListLit))
(DFunDef false "legacyMethodSchemes" ((PCons (PVar "row") (PVar "rest"))) (EBinOp "::" (ETuple (EFieldAccess (EVar "row") "msrName") (EFieldAccess (EVar "row") "msrScheme")) (EApp (EVar "legacyMethodSchemes") (EVar "rest"))))
(DTypeSig true "methodSlotKey" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "methodSlotKey" ((PVar "iface") (PVar "method")) (EApp (EVar "regKeyRender") (EApp (EApp (EVar "methodRowKey") (EVar "iface")) (EVar "method"))))
(DTypeSig true "envFor" (TyFun (TyCon "ModuleCtx") (TyCon "TcEnv")))
(DFunDef false "envFor" ((PVar "mctx")) (EApp (EApp (EVar "withCtors") (EVar "mctx")) (EVar "builtinCtors")))
(DTypeSig true "namesToSet" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "namesToSet" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "namesToSet" ((PCons (PVar "n") (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "namesToSet") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "m"))))
(DTypeSig true "ieHeadCandidateExists" (TyFun (TyCon "ImplEnv") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "HeadKey") (TyCon "Bool")))))
(DFunDef false "ieHeadCandidateExists" ((PVar "env") (PVar "iface") (PVar "hk")) (EBinOp "||" (EApp (EApp (EVar "ieAnyRowForIface") (EApp (EApp (EVar "ieHeadRows") (EApp (EVar "Some") (EVar "hk"))) (EVar "env"))) (EVar "iface")) (EApp (EApp (EVar "ieAnyRowForIface") (EApp (EApp (EVar "ieHeadRows") (EVar "None")) (EVar "env"))) (EVar "iface"))))
(DTypeSig false "ieAnyRowForIface" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "ieAnyRowForIface" ((PList) PWild) (EVar "False"))
(DFunDef false "ieAnyRowForIface" ((PCons (PCon "ImplRow" PWild PWild (PVar "ir") PWild PWild PWild PWild) (PVar "rest")) (PVar "iface")) (EBinOp "||" (EApp (EApp (EVar "ieRowIfaceMatches") (EVar "ir")) (EVar "iface")) (EApp (EApp (EVar "ieAnyRowForIface") (EVar "rest")) (EVar "iface"))))
(DTypeSig true "ifaceMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ifaceMethodNames" ((PList)) (EListLit))
(DFunDef false "ifaceMethodNames" ((PCons (PCon "IfaceMethod" (PVar "n") PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "ifaceMethodNames") (EVar "rest"))))
(DTypeSig true "publicDataDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "publicDataDecl" ((PRec "DData" ((rf "dataVis" (PCon "VisPublic"))) false)) (EVar "True"))
(DFunDef false "publicDataDecl" ((PRec "DInterface" ((rf "pub" (PCon "True"))) true)) (EVar "True"))
(DFunDef false "publicDataDecl" ((PRec "DImpl" ((rf "pub" (PCon "True"))) true)) (EVar "True"))
(DFunDef false "publicDataDecl" ((PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True"))) false)) (EVar "True"))
(DFunDef false "publicDataDecl" (PWild) (EVar "False"))
(DTypeSig true "publicDataDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "publicDataDecls" ((PVar "decls")) (EApp (EApp (EVar "filterList") (EVar "publicDataDecl")) (EVar "decls")))
(DTypeSig true "kindPublicDataDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "kindPublicDataDecl" ((PRec "DData" ((rf "dataVis" (PCon "VisPublic"))) false)) (EVar "True"))
(DFunDef false "kindPublicDataDecl" ((PRec "DData" ((rf "dataVis" (PCon "VisAbstract"))) false)) (EVar "True"))
(DFunDef false "kindPublicDataDecl" ((PRec "DNewtype" ((rf "newtypePub" (PCon "True"))) false)) (EVar "True"))
(DFunDef false "kindPublicDataDecl" ((PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True"))) false)) (EVar "True"))
(DFunDef false "kindPublicDataDecl" (PWild) (EVar "False"))
(DTypeSig true "ordinaryEnvBinding" (TyFun (TyCon "Scheme") (TyCon "EnvBinding")))
(DFunDef false "ordinaryEnvBinding" ((PVar "scheme")) (ERecordCreate "EnvBinding" ((fa "ebValue" (EApp (EVar "ordinaryValueScheme") (EVar "scheme"))) (fa "ebMethodRow" (EVar "None")) (fa "ebStandalone" (EVar "None")))))
(DTypeSig false "ordinaryValueScheme" (TyFun (TyCon "Scheme") (TyCon "ValueScheme")))
(DFunDef false "ordinaryValueScheme" ((PVar "scheme")) (ERecordCreate "ValueScheme" ((fa "vsScheme" (EVar "scheme")) (fa "vsDeclared" (EVar "None")))))
(DTypeSig true "methodEnvBinding" (TyFun (TyCon "MethodSchemeRow") (TyCon "EnvBinding")))
(DFunDef false "methodEnvBinding" ((PVar "row")) (ERecordCreate "EnvBinding" ((fa "ebValue" (EApp (EVar "ordinaryValueScheme") (EFieldAccess (EVar "row") "msrScheme"))) (fa "ebMethodRow" (EApp (EVar "Some") (EVar "row"))) (fa "ebStandalone" (EVar "None")))))
(DTypeSig true "lookupMethodRowById" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyApp (TyCon "Option") (TyCon "MethodSchemeRow"))))))
(DFunDef false "lookupMethodRowById" ((PVar "iface") (PVar "n") (PVar "rows")) (EMatch (EApp (EApp (EVar "regLookupK") (EApp (EApp (EVar "methodRowKey") (EVar "iface")) (EVar "n"))) (EVar "rows")) (arm (PCon "Some" (PVar "row")) () (EIf (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irName")) (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")) (EFieldAccess (EVar "iface") "irOrigin")) (EApp (EVar "Some") (EVar "row")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "lookupSchemeById" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyApp (TyCon "Option") (TyCon "Scheme"))))))
(DFunDef false "lookupSchemeById" ((PVar "iface") (PVar "n") (PVar "rows")) (EApp (EApp (EVar "map") (ELam ((PVar "row")) (EFieldAccess (EVar "row") "msrScheme"))) (EApp (EApp (EApp (EVar "lookupMethodRowById") (EVar "iface")) (EVar "n")) (EVar "rows"))))
(DTypeSig false "methodRowKey" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyCon "RegKey"))))
(DFunDef false "methodRowKey" ((PVar "iface") (PVar "method")) (EApp (EVar "regKeyNTab") (EListLit (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")) (EApp (EApp (EVar "TkBare") (EVar "NsMethod")) (EVar "method")))))
(DTypeSig true "methodRowsByIdentity" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow"))))))
(DFunDef false "methodRowsByIdentity" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "methodRowsByIdentity" ((PVar "includeAll") (PCons (PVar "row") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "includeAll")) (EApp (EVar "not") (EApp (EVar "methodRowCanCarry") (EVar "row")))) (EApp (EApp (EApp (EVar "methodRowsByIdentity") (EVar "includeAll")) (EVar "rest")) (EVar "acc")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "methodRowKey") (EFieldAccess (EVar "row") "msrIface")) (EFieldAccess (EVar "row") "msrName"))) (DoLet false false (PVar "acc2") (EMatch (EApp (EApp (EVar "regLookupK") (EVar "key")) (EVar "acc")) (arm (PCon "Some" PWild) () (EVar "acc")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "regInsertK") (EVar "key")) (EVar "row")) (EVar "acc"))))) (DoExpr (EApp (EApp (EApp (EVar "methodRowsByIdentity") (EVar "includeAll")) (EVar "rest")) (EVar "acc2"))))))
(DTypeSig true "importedBindings" (TyFun (TyCon "UsePath") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "importedBindings" ((PCon "UseGroup" PWild (PVar "ms"))) (EApp (EVar "Some") (EApp (EApp (EVar "map") (EVar "memberBinding")) (EVar "ms"))))
(DFunDef false "importedBindings" ((PCon "UseWild" PWild)) (EVar "None"))
(DFunDef false "importedBindings" ((PCon "UseName" (PVar "ns"))) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EVar "Some") (EListLit (EApp (EVar "selfBinding") (EApp (EVar "lastComponent") (EVar "ns"))))) (EIf (EVar "otherwise") (EApp (EVar "Some") (EListLit)) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "importedBindings" ((PCon "UseAlias" PWild PWild)) (EApp (EVar "Some") (EListLit)))
(DTypeSig true "boundNames" (TyFun (TyCon "UsePath") (TyApp (TyCon "Option") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "boundNames" ((PVar "path")) (EApp (EApp (EVar "map") (ELam ((PVar "rows")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "rows"))) (EVar "omEmpty")))) (EApp (EVar "importedBindings") (EVar "path"))))
(DTypeSig false "memberBinding" (TyFun (TyCon "UseMember") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "memberBinding" ((PVar "m")) (ETuple (EApp (EVar "useMemberOrigin") (EVar "m")) (EApp (EVar "useMemberLocal") (EVar "m"))))
(DTypeSig true "importTableMid" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "importTableMid" ((PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (ELit (LString "")) (EVar "mid")))))
(DTypeSig false "declMethodIdents" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident")))))
(DFunDef false "declMethodIdents" ((PVar "decls")) (EApp (EApp (EVar "flatMap") (EVar "declMethodIdentsOf")) (EVar "decls")))
(DTypeSig false "declMethodIdentsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident")))))
(DFunDef false "declMethodIdentsOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declMethodIdentsOf") (EVar "d")))
(DFunDef false "declMethodIdentsOf" ((PRec "DInterface" ((rf "methods" None) (rf "ifaceOrigin" None)) true)) (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EApp (EApp (EVar "ifaceMethodIdentPair") (EVar "ifaceOrigin")) (EVar "m")))) (EVar "methods")))
(DFunDef false "declMethodIdentsOf" (PWild) (EListLit))
(DTypeSig false "ifaceMethodIdentPair" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "ifaceMethodIdentPair" ((PVar "origin") (PCon "IfaceMethod" (PVar "mname") PWild PWild PWild)) (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsMethod")) (EVar "origin")) (EVar "mname")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "i")) () (EListLit (ETuple (EVar "mname") (EVar "i"))))))
(DTypeSig false "reexportedMethodIdents" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "reexportedMethodIdents" ((PVar "acc") (PVar "decls")) (EApp (EApp (EVar "flatMap") (EApp (EVar "reexportedMethodIdentsOf") (EVar "acc"))) (EVar "decls")))
(DTypeSig false "reexportedMethodIdentsOf" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident")))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "reexportedMethodIdentsOf" ((PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "reexportedMethodIdentsOf") (EVar "acc")) (EVar "d")))
(DFunDef false "reexportedMethodIdentsOf" ((PVar "acc") (PCon "DUse" (PCon "True") (PVar "path") PWild)) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "acc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EVar "src")) (arm (PCon "Some" (PVar "bs")) () (EApp (EApp (EVar "flatMap") (ELam ((PVar "b")) (EApp (EApp (EVar "reexportRenamed") (EVar "b")) (EVar "src")))) (EVar "bs")))))))
(DFunDef false "reexportedMethodIdentsOf" (PWild PWild) (EListLit))
(DTypeSig false "reexportRenamed" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "reexportRenamed" ((PTuple (PVar "origin") (PVar "local")) (PVar "src")) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (EVar "local") (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "fst") (EVar "e")) (EVar "origin")))) (EVar "src"))))
(DTypeSig true "ifaceMethodRows" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ifaceMethodRows" ((PVar "decls")) (EApp (EApp (EVar "flatMap") (EVar "ifaceMethodRowOf")) (EVar "decls")))
(DTypeSig true "allIfaceMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allIfaceMethodNames" ((PList)) (EListLit))
(DFunDef false "allIfaceMethodNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "allIfaceMethodNames") (EListLit (EVar "d"))) (EApp (EVar "allIfaceMethodNames") (EVar "rest"))))
(DFunDef false "allIfaceMethodNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EVar "ifaceMethodNames") (EVar "methods")) (EApp (EVar "allIfaceMethodNames") (EVar "rest"))))
(DFunDef false "allIfaceMethodNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "allIfaceMethodNames") (EVar "rest")))
(DTypeSig false "ifaceMethodRowOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ifaceMethodRowOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ifaceMethodRowOf") (EVar "d")))
(DFunDef false "ifaceMethodRowOf" ((PRec "DInterface" ((rf "name" None) (rf "methods" None)) true)) (EListLit (ETuple (EVar "name") (EApp (EVar "ifaceMethodNames") (EVar "methods")))))
(DFunDef false "ifaceMethodRowOf" (PWild) (EListLit))
(DTypeSig false "reexportedIfaceMethods" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reexportedIfaceMethods" ((PVar "acc") (PVar "decls")) (EApp (EApp (EVar "flatMap") (EApp (EVar "reexportedIfaceMethodsOf") (EVar "acc"))) (EVar "decls")))
(DTypeSig false "reexportedIfaceMethodsOf" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reexportedIfaceMethodsOf" ((PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "reexportedIfaceMethodsOf") (EVar "acc")) (EVar "d")))
(DFunDef false "reexportedIfaceMethodsOf" ((PVar "acc") (PCon "DUse" (PCon "True") (PVar "path") PWild)) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "acc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "selectIfaceRows") (EVar "path")) (EVar "src")))))
(DFunDef false "reexportedIfaceMethodsOf" (PWild PWild) (EListLit))
(DTypeSig true "selectIfaceRows" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "selectIfaceRows" ((PCon "UseAlias" PWild PWild) (PVar "src")) (EVar "src"))
(DFunDef false "selectIfaceRows" ((PVar "path") (PVar "src")) (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EVar "src")) (arm (PCon "Some" (PVar "bs")) () (EApp (EApp (EVar "flatMap") (ELam ((PVar "r")) (EApp (EApp (EVar "narrowRowToNamed") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "bs"))) (EVar "r")))) (EVar "src")))))
(DTypeSig false "narrowRowToNamed" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "narrowRowToNamed" ((PVar "named") (PVar "r")) (EIf (EApp (EApp (EVar "contains") (EApp (EVar "fst") (EVar "r"))) (EVar "named")) (EListLit (EVar "r")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EApp (EApp (EVar "contains") (EVar "m")) (EVar "named")))) (EApp (EVar "snd") (EVar "r"))) (arm (PList) () (EListLit)) (arm (PVar "ms") () (EListLit (ETuple (EApp (EVar "fst") (EVar "r")) (EVar "ms"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ctorExportsIndex" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))))
(DFunDef false "ctorExportsIndex" ((PVar "gctx") PWild) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deData") "deCtorExports"))
(DTypeSig true "variantNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Bool"))))
(DFunDef false "variantNamed" (PWild (PList)) (EVar "False"))
(DFunDef false "variantNamed" ((PVar "n") (PCons (PCon "Variant" (PVar "cn") PWild) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "cn") (EVar "n")) (EApp (EApp (EVar "variantNamed") (EVar "n")) (EVar "rest"))))
(DTypeSig true "graphPubDefiners" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "graphPubDefiners" ((PVar "gctx") (PVar "mid")) (EApp (EApp (EVar "definersIn") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deDefiners")) (EVar "mid")))
(DTypeSig true "definersIn" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "definersIn" ((PVar "tbl") (PVar "mid")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "tbl")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "rows")) () (EVar "rows"))))
(DTypeSig true "emptyMethodModulePredicateSlots" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))))
(DFunDef false "emptyMethodModulePredicateSlots" (PWild (PList)) (EListLit))
(DFunDef false "emptyMethodModulePredicateSlots" ((PVar "mid") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "emptyMethodModulePredicateSlots") (EVar "mid")) (EListLit (EVar "d"))) (EApp (EApp (EVar "emptyMethodModulePredicateSlots") (EVar "mid")) (EVar "rest"))))
(DFunDef false "emptyMethodModulePredicateSlots" ((PVar "mid") (PCons (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "methods" None) (rf "ifaceOrigin" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "emptyMethodModulePredicateSlot") (EVar "mid")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "ifaceOrigin"))))) (EVar "typarams"))) (EVar "methods")) (EApp (EApp (EVar "emptyMethodModulePredicateSlots") (EVar "mid")) (EVar "rest"))))
(DFunDef false "emptyMethodModulePredicateSlots" ((PVar "mid") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "emptyMethodModulePredicateSlots") (EVar "mid")) (EVar "rest")))
(DTypeSig false "emptyMethodModulePredicateSlot" (TyFun (TyCon "String") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))))))
(DFunDef false "emptyMethodModulePredicateSlot" ((PVar "mid") (PVar "iface") (PVar "typarams") (PCon "IfaceMethod" (PVar "name") (PVar "ty") PWild PWild)) (EIf (EApp (EVar "isEmptyL") (EApp (EApp (EVar "methodLevelConstraintVarNames") (EVar "typarams")) (EVar "ty"))) (EListLit (ETuple (ETuple (EVar "mid") (EApp (EApp (EVar "methodSlotKey") (EVar "iface")) (EVar "name"))) (EListLit))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "declTopFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declTopFnNames" ((PVar "decls")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "decls"))))
(DTypeSig true "useModuleId" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "useModuleId" ((PCon "DUse" PWild (PVar "path") PWild)) (EListLit (EApp (EVar "useModId") (EVar "path"))))
(DFunDef false "useModuleId" (PWild) (EListLit))
(DTypeSig true "lastComponent" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastComponent" ((PVar "ns")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "last") (EVar "ns"))))
(DTypeSig true "importLocFor" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "importLocFor" ((PVar "reach") (PVar "prog") (PVar "owner")) (EApp (EApp (EVar "orElseLoc") (EApp (EApp (EVar "findMap") (EApp (EVar "importLocOf") (EVar "owner"))) (EVar "prog"))) (EApp (EApp (EVar "findMap") (EApp (EApp (EVar "importLocReaching") (EVar "reach")) (EVar "owner"))) (EVar "prog"))))
(DTypeSig false "importLocOf" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "importLocOf" ((PVar "owner") (PCon "DUse" PWild (PVar "path") (PVar "loc"))) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (EVar "owner")) (EApp (EVar "Some") (EVar "loc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "importLocOf" (PWild PWild) (EVar "None"))
(DTypeSig false "importLocReaching" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "importLocReaching" ((PVar "reach") (PVar "owner") (PCon "DUse" PWild (PVar "path") (PVar "loc"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "owner")) (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "reach")))) (EApp (EVar "Some") (EVar "loc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "importLocReaching" (PWild PWild PWild) (EVar "None"))
(DTypeSig true "builtinClassName" (TyFun (TyCon "BuiltinClass") (TyCon "String")))
(DFunDef false "builtinClassName" ((PCon "BNum")) (ELit (LString "Num")))
(DFunDef false "builtinClassName" ((PCon "BEq")) (ELit (LString "Eq")))
(DFunDef false "builtinClassName" ((PCon "BOrd")) (ELit (LString "Ord")))
(DFunDef false "builtinClassName" ((PCon "BSemigroup")) (ELit (LString "Semigroup")))
(DTypeSig true "builtinClassOrigin" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "BuiltinClass") (TyCon "TyConOrigin"))))
(DFunDef false "builtinClassOrigin" ((PVar "gctx") (PCon "BNum")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcNum"))
(DFunDef false "builtinClassOrigin" ((PVar "gctx") (PCon "BEq")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcEq"))
(DFunDef false "builtinClassOrigin" ((PVar "gctx") (PCon "BOrd")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcOrd"))
(DFunDef false "builtinClassOrigin" ((PVar "gctx") (PCon "BSemigroup")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcSemigroup"))
(DTypeSig true "builtinIfaceRef" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "BuiltinClass") (TyCon "IfaceRef"))))
(DFunDef false "builtinIfaceRef" ((PVar "gctx") (PVar "c")) (ERecordCreate "IfaceRef" ((fa "irName" (EApp (EVar "builtinClassName") (EVar "c"))) (fa "irOrigin" (EApp (EApp (EVar "builtinClassOrigin") (EVar "gctx")) (EVar "c"))))))
(DTypeSig true "buildFlatImplEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ImplEnv")))
(DFunDef false "buildFlatImplEnv" ((PVar "prog")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EApp (EVar "implRowsOf") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "implDeclFacts") (EVar "prog")))) (DoLet false false (PVar "indexed") (EApp (EApp (EVar "ieIndexRows") (EVar "rows")) (EVar "emptyImplEnv"))) (DoExpr (EVariantUpdate "ImplEnv" (EVar "indexed") ((fa "ieRows" (EVar "rows")) (fa "ieUnivSnaps" (EApp (EVar "ieBuildSnaps") (EVar "rows"))))))))
(DTypeSig false "ieIndexRows" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv"))))
(DFunDef false "ieIndexRows" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "ieIndexRows" ((PCons (PVar "r") (PVar "rest")) (PVar "env")) (EApp (EApp (EVar "ieIndexRows") (EVar "rest")) (EApp (EApp (EVar "ieFileRow") (EVar "r")) (EVar "env"))))
(DTypeSig false "ieBuildSnaps" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse")))))
(DFunDef false "ieBuildSnaps" ((PVar "rows")) (EApp (EVar "reverseL") (EApp (EVar "fst") (EApp (EApp (EVar "ieBuildSnapsGo") (EVar "rows")) (EVar "ieSnapZero")))))
(DTypeSig false "ieBuildSnapsGo" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyCon "ImplUniverse")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyCon "ImplUniverse")))))
(DFunDef false "ieBuildSnapsGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "ieBuildSnapsGo" ((PCons (PVar "r") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PTuple (PVar "run") (PVar "more")) (EApp (EApp (EApp (EVar "ieSameOrdRun") (EApp (EVar "ieRowOrd") (EVar "r"))) (EBinOp "::" (EVar "r") (EVar "rest"))) (EListLit))) (DoExpr (EApp (EApp (EVar "ieBuildSnapsGo") (EVar "more")) (EApp (EApp (EVar "ieSnapStep") (EVar "run")) (EVar "acc"))))))
(DTypeSig false "ieSameOrdRun" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyTuple (TyApp (TyCon "List") (TyCon "ImplRow")) (TyApp (TyCon "List") (TyCon "ImplRow")))))))
(DFunDef false "ieSameOrdRun" (PWild (PList) (PVar "acc")) (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EListLit)))
(DFunDef false "ieSameOrdRun" ((PVar "o") (PCons (PVar "r") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "==" (EApp (EVar "ieRowOrd") (EVar "r")) (EVar "o")) (EApp (EApp (EApp (EVar "ieSameOrdRun") (EVar "o")) (EVar "rest")) (EBinOp "::" (EVar "r") (EVar "acc"))) (EIf (EVar "otherwise") (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EBinOp "::" (EVar "r") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ieTyBlob" (TyCon "Ty"))
(DFunDef false "ieTyBlob" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Blob"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EApp (EVar "OriginModule") (ELit (LString "amod")))))))
(DTypeSig false "ieSameImplIn" (TyFun (TyCon "String") (TyCon "Decl")))
(DFunDef false "ieSameImplIn" ((PVar "m")) (ERecordCreate "DImpl" ((fa "pub" (EVar "True")) (fa "iface" (ELit (LString "Same"))) (fa "tys" (EListLit (EVar "ieTyBlob"))) (fa "reqs" (EListLit)) (fa "methods" (EListLit)) (fa "implOrigin" (EApp (EVar "OriginModule") (EVar "m"))) (fa "implIfaceLoc" (EVar "None")))))
(DTypeSig false "ieProbeKey" (TyFun (TyCon "String") (TyCon "RegKey")))
(DFunDef false "ieProbeKey" ((PVar "m")) (EApp (EVar "regKeyNTab") (EListLit (EApp (EVar "oblIfaceKey") (ERecordCreate "IfaceRef" ((fa "irName" (ELit (LString "Same"))) (fa "irOrigin" (EApp (EVar "OriginModule") (EVar "m")))))) (EApp (EVar "dispHeadTab") (EApp (EApp (EVar "headKeyOfCon") (EApp (EVar "OriginModule") (ELit (LString "amod")))) (ELit (LString "Blob")))))))
(DTypeSig false "ieProbeBareKey" (TyCon "RegKey"))
(DFunDef false "ieProbeBareKey" () (EApp (EVar "regKeyNTab") (EListLit (EApp (EApp (EVar "TkBare") (EVar "NsIface")) (ELit (LString "Same"))) (EApp (EVar "dispHeadTab") (EApp (EApp (EVar "headKeyOfCon") (EApp (EVar "OriginModule") (ELit (LString "amod")))) (ELit (LString "Blob")))))))
(DTypeSig false "ieProbeEnv" (TyFun (TyCon "GraphCtx") (TyCon "ImplEnv")))
(DFunDef false "ieProbeEnv" ((PVar "gctx")) (EApp (EVar "buildImplEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "amod"))) (EListLit (EApp (EVar "ieSameImplIn") (ELit (LString "amod"))))) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "zmod"))) (EListLit (EApp (EVar "ieSameImplIn") (ELit (LString "zmod"))))))))
(DTypeSig false "ieUnivConcreteOf" (TyFun (TyCon "ImplUniverse") (TyApp (TyCon "MultiRegistry") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))))))
(DFunDef false "ieUnivConcreteOf" ((PCon "ImplUniverse" (PVar "conc") PWild)) (EVar "conc"))
(DTypeSig false "ieOtherImplIn" (TyFun (TyCon "String") (TyCon "Decl")))
(DFunDef false "ieOtherImplIn" ((PVar "m")) (ERecordCreate "DImpl" ((fa "pub" (EVar "True")) (fa "iface" (ELit (LString "Other"))) (fa "tys" (EListLit (EVar "ieTyBlob"))) (fa "reqs" (EListLit)) (fa "methods" (EListLit)) (fa "implOrigin" (EApp (EVar "OriginModule") (EVar "m"))) (fa "implIfaceLoc" (EVar "None")))))
(DTypeSig false "ieGenImplIn" (TyFun (TyCon "String") (TyCon "Decl")))
(DFunDef false "ieGenImplIn" ((PVar "m")) (ERecordCreate "DImpl" ((fa "pub" (EVar "True")) (fa "iface" (ELit (LString "Gen"))) (fa "tys" (EListLit (EApp (EVar "TyVar") (ELit (LString "a"))))) (fa "reqs" (EListLit)) (fa "methods" (EListLit)) (fa "implOrigin" (EApp (EVar "OriginModule") (EVar "m"))) (fa "implIfaceLoc" (EVar "None")))))
(DTypeSig false "ieLooseImplIn" (TyFun (TyCon "String") (TyCon "Decl")))
(DFunDef false "ieLooseImplIn" ((PVar "m")) (ERecordCreate "DImpl" ((fa "pub" (EVar "True")) (fa "iface" (ELit (LString "Loose"))) (fa "tys" (EListLit (EVar "ieTyBlob"))) (fa "reqs" (EListLit)) (fa "methods" (EListLit)) (fa "implOrigin" (EVar "OriginUnresolved")) (fa "implIfaceLoc" (EVar "None")))))
(DTypeSig false "ieHeadProbeAmod" (TyApp (TyCon "List") (TyCon "Decl")))
(DFunDef false "ieHeadProbeAmod" () (EListLit (EApp (EVar "ieSameImplIn") (ELit (LString "amod"))) (EApp (EVar "ieOtherImplIn") (ELit (LString "amod")))))
(DTypeSig false "ieHeadProbeZmod" (TyApp (TyCon "List") (TyCon "Decl")))
(DFunDef false "ieHeadProbeZmod" () (EListLit (EApp (EVar "ieSameImplIn") (ELit (LString "zmod"))) (EApp (EVar "ieGenImplIn") (ELit (LString "zmod"))) (EApp (EVar "ieLooseImplIn") (ELit (LString "zmod")))))
(DTypeSig false "ieHeadProbeDecls" (TyApp (TyCon "List") (TyCon "Decl")))
(DFunDef false "ieHeadProbeDecls" () (EBinOp "++" (EVar "ieHeadProbeAmod") (EVar "ieHeadProbeZmod")))
(DTypeSig false "ieHeadProbeEnv" (TyFun (TyCon "GraphCtx") (TyCon "ImplEnv")))
(DFunDef false "ieHeadProbeEnv" ((PVar "gctx")) (EApp (EVar "buildImplEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "amod"))) (EVar "ieHeadProbeAmod")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "zmod"))) (EVar "ieHeadProbeZmod")))))
(DTypeSig false "ieProbeBlobHead" (TyCon "HeadKey"))
(DFunDef false "ieProbeBlobHead" () (EApp (EApp (EVar "headKeyOfCon") (EApp (EVar "OriginModule") (ELit (LString "amod")))) (ELit (LString "Blob"))))
(DTypeSig false "buildClassEnv" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyCon "ClassEnv"))))
(DFunDef false "buildClassEnv" ((PVar "gctx") (PVar "mods")) (EApp (EVar "classEnvFinish") (EApp (EApp (EApp (EVar "buildClassEnvGo") (EVar "gctx")) (EVar "mods")) (EVar "emptyClassEnv"))))
(DTypeSig false "ceMethodFoo" (TyCon "IfaceMethod"))
(DFunDef false "ceMethodFoo" () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "foo"))) (EApp (EApp (EVar "TyFun") (EApp (EVar "TyVar") (ELit (LString "a")))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None")))) (EVar "None")) (EVar "None")))
(DTypeSig false "ceMethodBar" (TyCon "IfaceMethod"))
(DFunDef false "ceMethodBar" () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "bar"))) (EApp (EApp (EVar "TyFun") (EApp (EVar "TyVar") (ELit (LString "a")))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "String"))) (EVar "None")))) (EVar "None")) (EVar "None")))
(DTypeSig false "ceSuperEq" (TyCon "Super"))
(DFunDef false "ceSuperEq" () (ERecordCreate "Super" ((fa "superHead" (ELit (LString "Eq"))) (fa "superParams" (EListLit (ELit (LString "a")))) (fa "superOrigin" (EApp (EVar "OriginModule") (ELit (LString "core")))))))
(DTypeSig false "ceSameDeclIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Decl"))))
(DFunDef false "ceSameDeclIn" ((PVar "m") (PVar "methods")) (ERecordCreate "DInterface" ((fa "pub" (EVar "True")) (fa "def" (EVar "False")) (fa "name" (ELit (LString "Same"))) (fa "typarams" (EListLit (ELit (LString "a")))) (fa "typaramKinds" (EListLit (EVar "None"))) (fa "supers" (EListLit (EVar "ceSuperEq"))) (fa "methods" (EVar "methods")) (fa "ifaceOrigin" (EApp (EVar "OriginModule") (EVar "m"))) (fa "ifaceNameLoc" (EVar "None")))))
(DTypeSig false "ceProbeEnv" (TyFun (TyCon "GraphCtx") (TyCon "ClassEnv")))
(DFunDef false "ceProbeEnv" ((PVar "gctx")) (EApp (EApp (EVar "buildClassEnv") (EVar "gctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "amod"))) (EListLit (EApp (EApp (EVar "ceSameDeclIn") (ELit (LString "amod"))) (EListLit (EVar "ceMethodFoo"))))) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "zmod"))) (EListLit (EApp (EApp (EVar "ceSameDeclIn") (ELit (LString "zmod"))) (EListLit (EVar "ceMethodBar"))))))))
(DTypeSig false "ceProbeKey" (TyFun (TyCon "String") (TyCon "RegKey")))
(DFunDef false "ceProbeKey" ((PVar "m")) (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EApp (EVar "OriginModule") (EVar "m"))) (ELit (LString "Same")))))
(DTypeSig false "ceMethodTyStr" (TyFun (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))) (TyCon "String")))
(DFunDef false "ceMethodTyStr" ((PTuple PWild (PVar "ty") PWild)) (EApp (EVar "ppTy") (EVar "ty")))
(DTypeSig false "ceSuperHead" (TyFun (TyCon "Super") (TyCon "String")))
(DFunDef false "ceSuperHead" ((PRec "Super" ((rf "superHead" (PVar "h"))) true)) (EVar "h"))
(DTypeSig false "ceRowOriginTag" (TyFun (TyCon "CeRow") (TyCon "String")))
(DFunDef false "ceRowOriginTag" ((PVar "r")) (EMatch (EFieldAccess (EApp (EVar "ceRowIface") (EVar "r")) "irOrigin") (arm (PCon "OriginModule" (PVar "m")) () (EVar "m")) (arm (PCon "OriginBuiltin") () (ELit (LString "<builtin>"))) (arm (PCon "OriginUnresolved") () (ELit (LString "<unresolved>")))))
(DTypeSig false "ceRowMethodNamesAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ceRowMethodNamesAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "ceRowMethodNames") (EVar "r")))))
(DTypeSig false "ceRowMethodTysAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ceRowMethodTysAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EVar "map") (EVar "ceMethodTyStr")) (EApp (EVar "ceRowMethods") (EVar "r"))))))
(DTypeSig false "ceRowTyparamsAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ceRowTyparamsAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "ceRowTyparams") (EVar "r")))))
(DTypeSig false "ceRowSuperHeadsAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ceRowSuperHeadsAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EVar "map") (EVar "ceSuperHead")) (EApp (EVar "ceRowSupers") (EVar "r"))))))
(DTypeSig false "ceSuperParams" (TyFun (TyCon "Super") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ceSuperParams" ((PRec "Super" ((rf "superParams" (PVar "ps"))) true)) (EVar "ps"))
(DTypeSig false "ceSuperOrigin" (TyFun (TyCon "Super") (TyCon "String")))
(DFunDef false "ceSuperOrigin" ((PRec "Super" ((rf "superOrigin" (PCon "OriginModule" (PVar "m")))) true)) (EVar "m"))
(DFunDef false "ceSuperOrigin" ((PRec "Super" ((rf "superOrigin" (PCon "OriginBuiltin"))) true)) (ELit (LString "<builtin>")))
(DFunDef false "ceSuperOrigin" ((PRec "Super" ((rf "superOrigin" (PCon "OriginUnresolved"))) true)) (ELit (LString "<unresolved>")))
(DTypeSig false "ceRowSuperParamsAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ceRowSuperParamsAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EVar "flatMap") (EVar "ceSuperParams")) (EApp (EVar "ceRowSupers") (EVar "r"))))))
(DTypeSig false "ceRowSuperOriginAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyCon "String")))))
(DFunDef false "ceRowSuperOriginAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "r")) () (EMatch (EApp (EVar "ceRowSupers") (EVar "r")) (arm (PList) () (ELit (LString ""))) (arm (PCons (PVar "s") PWild) () (EApp (EVar "ceSuperOrigin") (EVar "s")))))))
(DTypeSig false "ceRowIfaceNameAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyCon "String")))))
(DFunDef false "ceRowIfaceNameAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "r")) () (EFieldAccess (EApp (EVar "ceRowIface") (EVar "r")) "irName"))))
(DTypeSig false "ceRowParamKindNamesAt" (TyFun (TyCon "RegKey") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ceRowParamKindNamesAt" ((PVar "key") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EVar "key")) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EVar "map") (ELam ((PVar "ks")) (EApp (EApp (EVar "map") (EVar "kindName")) (EVar "ks")))) (EApp (EVar "ceRowParamKinds") (EVar "r"))))))
(DTypeSig false "ceGradedMethod" (TyCon "IfaceMethod"))
(DFunDef false "ceGradedMethod" () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "run"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "TyApp") (EApp (EVar "TyVar") (ELit (LString "f")))) (EApp (EVar "TyVar") (ELit (LString "e"))))) (EApp (EVar "TyVar") (ELit (LString "a"))))) (EApp (EApp (EApp (EVar "TyEffect") (EListLit)) (EListLit (ELit (LString "e")))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (EVar "None")) (EVar "None")))
(DTypeSig false "ceGradedIface" (TyCon "Decl"))
(DFunDef false "ceGradedIface" () (ERecordCreate "DInterface" ((fa "pub" (EVar "True")) (fa "def" (EVar "False")) (fa "name" (ELit (LString "Async"))) (fa "typarams" (EListLit (ELit (LString "f")))) (fa "typaramKinds" (EListLit (EApp (EVar "Some") (EApp (EApp (EVar "KindArrow") (EVar "KindEffect")) (EApp (EApp (EVar "KindArrow") (EVar "KindType")) (EVar "KindType")))))) (fa "supers" (EListLit)) (fa "methods" (EListLit (EVar "ceGradedMethod"))) (fa "ifaceOrigin" (EApp (EVar "OriginModule") (ELit (LString "gmod")))) (fa "ifaceNameLoc" (EVar "None")))))
(DTypeSig false "ceGradedEnv" (TyFun (TyCon "GraphCtx") (TyCon "ClassEnv")))
(DFunDef false "ceGradedEnv" ((PVar "gctx")) (EApp (EApp (EVar "buildClassEnv") (EVar "gctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "gmod"))) (EListLit (EVar "ceGradedIface"))))))
(DTypeSig false "ceGradedKey" (TyCon "RegKey"))
(DFunDef false "ceGradedKey" () (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EApp (EVar "OriginModule") (ELit (LString "gmod")))) (ELit (LString "Async")))))
(DTypeSig false "ceFunctorMethod" (TyCon "IfaceMethod"))
(DFunDef false "ceFunctorMethod" () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "fmap"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "TyApp") (EApp (EVar "TyVar") (ELit (LString "f")))) (EApp (EVar "TyVar") (ELit (LString "a"))))) (EApp (EApp (EVar "TyApp") (EApp (EVar "TyVar") (ELit (LString "f")))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (EVar "None")) (EVar "None")))
(DTypeSig false "ceFunctorIface" (TyCon "Decl"))
(DFunDef false "ceFunctorIface" () (ERecordCreate "DInterface" ((fa "pub" (EVar "True")) (fa "def" (EVar "False")) (fa "name" (ELit (LString "Functor"))) (fa "typarams" (EListLit (ELit (LString "f")))) (fa "typaramKinds" (EListLit (EVar "None"))) (fa "supers" (EListLit)) (fa "methods" (EListLit (EVar "ceFunctorMethod"))) (fa "ifaceOrigin" (EApp (EVar "OriginModule") (ELit (LString "fmod")))) (fa "ifaceNameLoc" (EVar "None")))))
(DTypeSig false "ceFunctorEnv" (TyFun (TyCon "GraphCtx") (TyCon "ClassEnv")))
(DFunDef false "ceFunctorEnv" ((PVar "gctx")) (EApp (EApp (EVar "buildClassEnv") (EVar "gctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "fmod"))) (EListLit (EVar "ceFunctorIface"))))))
(DTypeSig false "ceFunctorKey" (TyCon "RegKey"))
(DFunDef false "ceFunctorKey" () (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EApp (EVar "OriginModule") (ELit (LString "fmod")))) (ELit (LString "Functor")))))
(DTypeSig true "buildImplUniverse" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ImplUniverse")))
(DFunDef false "buildImplUniverse" ((PVar "prog")) (EApp (EApp (EVar "growImplUniverse") (EApp (EVar "implDeclsWithReqs") (EVar "prog"))) (EVar "emptyImplUniverse")))
(DTypeSig true "methodRowTestIface" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Decl"))))))
(DFunDef false "methodRowTestIface" ((PVar "moduleId") (PVar "name") (PVar "typarams") (PVar "methods")) (ERecordCreate "DInterface" ((fa "pub" (EVar "False")) (fa "def" (EVar "False")) (fa "name" (EVar "name")) (fa "typarams" (EVar "typarams")) (fa "typaramKinds" (EApp (EApp (EVar "map") (ELam (PWild) (EVar "None"))) (EVar "typarams"))) (fa "supers" (EListLit)) (fa "methods" (EVar "methods")) (fa "ifaceOrigin" (EApp (EVar "OriginModule") (EVar "moduleId"))) (fa "ifaceNameLoc" (EVar "None")))))
(DTypeSig true "methodRowTestConstraint" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Constraint")))))
(DFunDef false "methodRowTestConstraint" ((PVar "moduleId") (PVar "name") (PVar "args")) (ERecordCreate "Constraint" ((fa "constraintHead" (EVar "name")) (fa "constraintArgs" (EVar "args")) (fa "constraintOrigin" (EApp (EVar "OriginModule") (EVar "moduleId"))))))
(DTypeSig true "methodRowTestFoldMapDecl" (TyCon "Decl"))
(DFunDef false "methodRowTestFoldMapDecl" () (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "foldable-test"))) (ELit (LString "Foldable"))) (EListLit (ELit (LString "t")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "foldMap"))) (EApp (EApp (EVar "TyConstrained") (EListLit (EApp (EApp (EApp (EVar "methodRowTestConstraint") (ELit (LString "monoid-test"))) (ELit (LString "Monoid"))) (EListLit (EApp (EVar "TyVar") (ELit (LString "m"))))))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "TyFun") (EApp (EVar "TyVar") (ELit (LString "a")))) (EApp (EVar "TyVar") (ELit (LString "m"))))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "TyApp") (EApp (EVar "TyVar") (ELit (LString "t")))) (EApp (EVar "TyVar") (ELit (LString "a"))))) (EApp (EVar "TyVar") (ELit (LString "m"))))))) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodRowTestConstantDecl" (TyCon "Decl"))
(DFunDef false "methodRowTestConstantDecl" () (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "constant-test"))) (ELit (LString "Constant"))) (EListLit)) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "token"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodRowTestSameA" (TyCon "Decl"))
(DFunDef false "methodRowTestSameA" () (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "same-a"))) (ELit (LString "A"))) (EListLit)) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "same"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None")))) (EVar "None")) (EVar "None")) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "extra"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodRowTestSameB" (TyCon "Decl"))
(DFunDef false "methodRowTestSameB" () (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "same-b"))) (ELit (LString "B"))) (EListLit (ELit (LString "t")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "same"))) (EApp (EApp (EVar "TyConstrained") (EListLit (EApp (EApp (EApp (EVar "methodRowTestConstraint") (ELit (LString "d-test"))) (ELit (LString "D"))) (EListLit (EApp (EVar "TyVar") (ELit (LString "a"))))))) (EApp (EApp (EVar "TyFun") (EApp (EVar "TyVar") (ELit (LString "a")))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodRowTestNum" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Decl"))))
(DFunDef false "methodRowTestNum" ((PVar "moduleId") (PVar "fromIntTy")) (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (EVar "moduleId")) (ELit (LString "Num"))) (EListLit (ELit (LString "a")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "fromInt"))) (EVar "fromIntTy")) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodRowTestUserFromInt" (TyCon "Decl"))
(DFunDef false "methodRowTestUserFromInt" () (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "user-from-int"))) (ELit (LString "Buildable"))) (EListLit (ELit (LString "a")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "fromInt"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Bool"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a"))))) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodRowSameNameView" (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "methodRowSameNameView" ((PVar "rows")) (EApp (EApp (EVar "map") (ELam ((PVar "row")) (ETuple (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irName") (EFieldAccess (EVar "row") "msrName") (EApp (EVar "listLen") (EApp (EVar "schemeIds") (EFieldAccess (EVar "row") "msrScheme"))) (EApp (EVar "listLen") (EFieldAccess (EVar "row") "msrMethodSlots"))))) (EVar "rows")))
# MARK
(DUse false (UseGroup ("types" "tc_mono") ((mem "argMentions" false) (mem "entryHeadMatches" false) (mem "headTyconTy" false) (mem "implDeclsWithReqs" false) (mem "nthTy" false) (mem "schemeBodyOf" false) (mem "schemeIds" false) (mem "tyAppSpine" false) (mem "tyVarNames" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "builtinCtors" false) (mem "emptyClassEnv" false) (mem "emptyDataEnv" false) (mem "emptyDeclEnvSeedAcc" false) (mem "emptyImplEnv" false) (mem "emptyImplUniverse" false) (mem "emptyMethodEnv" false) (mem "probeGraphCtx" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Constraint" true) (mem "DataVis" true) (mem "Decl" true) (mem "Expr" true) (mem "FunClause" true) (mem "Ident" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "KindAnn" true) (mem "LetBind" true) (mem "Loc" true) (mem "Ns" true) (mem "Pat" true) (mem "Require" true) (mem "Super" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "UseMember" true) (mem "UsePath" true) (mem "Variant" true) (mem "identOriginOf" false) (mem "mkIdent" false) (mem "orElseLoc" false) (mem "sameTyConHead" false) (mem "tabKeyEq" false) (mem "tabKeyOf" false) (mem "tyConBuiltin" false) (mem "useMemberLocal" false) (mem "useMemberOrigin" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "ppTy" false))))
(DUse false (UseGroup ("types" "effect_param_decode") ((mem "dtopIn" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffLabel" true))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "kindName" false))))
(DUse false (UseGroup ("types" "effect_infer") ((mem "AlphaBinder" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "CeRow" true) (mem "ClassEnv" true) (mem "DeclEnvAcc" true) (mem "DeclEnvModule" true) (mem "DeclEnvs" true) (mem "EnvBinding" true) (mem "GraphCtx" true) (mem "ImplAcc" true) (mem "ImplEnv" true) (mem "ImplRow" true) (mem "ImplUniverse" true) (mem "InstRef" true) (mem "KeyEntry" true) (mem "Kind" true) (mem "MethodEnv" true) (mem "MethodPredicateSlot" true) (mem "MethodRow" true) (mem "MethodSchemeRow" true) (mem "ModuleCtx" true) (mem "RecordInfo" true) (mem "StandaloneOrigin" true) (mem "TcEnv" true) (mem "ValueScheme" true) (mem "AliasDecl" false) (mem "CDeclared" false) (mem "BuiltinClass" true) (mem "dynFor" false) (mem "MethodEntry" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "useModId" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omSize" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "last" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "reverseL" false) (mem "selfBinding" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "headKeyOfCon" false) (mem "headKeyTag" false) (mem "mregAppendK" false) (mem "mregLookupK" false) (mem "MultiRegistry" false) (mem "regInsertK" false) (mem "Registry" false) (mem "RegKey" false) (mem "regKeyNTab" false) (mem "regKeyOfTab" false) (mem "regKeyRender" false) (mem "regLookupK" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "implRouteKeyWord" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "GoalOrigin" true))))
(DTypeSig true "aliasUniverseAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyCon "AliasDecl"))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))))))
(DFunDef false "aliasUniverseAt" (PWild (PList)) (EListLit))
(DFunDef false "aliasUniverseAt" ((PVar "cur") (PCons (PTuple (PVar "key") (PVar "ad")) (PVar "rest"))) (EIf (EApp (EApp (EVar "aliasVisibleTo") (EVar "cur")) (EVar "ad")) (EBinOp "::" (ETuple (EVar "key") (ETuple (EFieldAccess (EVar "ad") "adParams") (EFieldAccess (EVar "ad") "adRhs"))) (EApp (EApp (EVar "aliasUniverseAt") (EVar "cur")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "aliasUniverseAt") (EVar "cur")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "aliasVisibleTo" (TyFun (TyCon "Int") (TyFun (TyCon "AliasDecl") (TyCon "Bool"))))
(DFunDef false "aliasVisibleTo" ((PVar "cur") (PVar "ad")) (EBinOp "&&" (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "ad") "adOrd")) (EFieldAccess (EVar "ad") "adPub")) (EBinOp "/=" (EFieldAccess (EVar "ad") "adOrd") (EVar "cur"))))
(DTypeSig true "aliasOwnAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyCon "AliasDecl"))) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))))))
(DFunDef false "aliasOwnAt" (PWild (PList)) (EListLit))
(DFunDef false "aliasOwnAt" ((PVar "cur") (PCons (PTuple (PVar "key") (PVar "ad")) (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EVar "ad") "adOrd") (EVar "cur")) (EBinOp "::" (ETuple (EVar "key") (ETuple (EFieldAccess (EVar "ad") "adParams") (EFieldAccess (EVar "ad") "adRhs"))) (EApp (EApp (EVar "aliasOwnAt") (EVar "cur")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "aliasOwnAt") (EVar "cur")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ifaceExportsIndex" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ifaceExportsIndex" ((PVar "gctx") PWild) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deMethods") "meIfaceExports"))
(DTypeSig true "bindingDeclared" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "CDeclared")))))
(DFunDef false "bindingDeclared" ((PVar "env") (PVar "name")) (EMatch (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "name")) (arm (PCon "Some" (PVar "binding")) () (EFieldAccess (EFieldAccess (EVar "binding") "ebValue") "vsDeclared")) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "attachStandaloneSources" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EnvBinding"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EnvBinding"))))))
(DFunDef false "attachStandaloneSources" ((PVar "sources") (PVar "bindings")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "name") (PVar "binding"))) (ETuple (EVar "name") (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "sources")) (arm (PCon "Some" (PVar "source")) () (EApp (EApp (EVar "bindingWithStandalone") (EVar "binding")) (ETuple (EVar "ImportedStandalone") (EApp (EVar "ordinaryValueScheme") (EVar "source"))))) (arm (PCon "None") () (EVar "binding")))))) (EVar "bindings")))
(DTypeSig true "standaloneValueFor" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "ValueScheme"))))))
(DFunDef false "standaloneValueFor" ((PVar "env") (PVar "name") (PVar "sym")) (EMatch (EApp (EApp (EVar "lookupStandaloneValue") (EVar "env")) (EVar "name")) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Some") (EVar "value"))) (arm (PCon "None") () (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "None") (EApp (EApp (EMethodRef "map") (ELam ((PVar "binding")) (EFieldAccess (EVar "binding") "ebValue"))) (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "sym")))))))
(DTypeSig true "superLookup" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "IfaceRef") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Super")))))))
(DFunDef false "superLookup" ((PVar "gctx") (PVar "ir")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "ir") "irName")))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "ceRowTyparams") (EVar "row")) (EApp (EVar "ceRowSupers") (EVar "row"))))) (EApp (EApp (EVar "ceLookupGraph") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deIfaces"))))))
(DTypeSig true "keyEntryIface" (TyFun (TyCon "KeyEntry") (TyCon "String")))
(DFunDef false "keyEntryIface" ((PCon "KeyEntry" PWild PWild PWild PWild (PVar "ifn") PWild PWild PWild)) (EVar "ifn"))
(DTypeSig true "graphAmbigValues" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "graphAmbigValues" ((PVar "gctx") (PVar "mid")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deAmbigValues")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "rows")) () (EVar "rows"))))
(DTypeSig true "importerReachIndex" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "importerReachIndex" ((PVar "mods")) (EApp (EApp (EApp (EVar "importerReachGo") (EApp (EApp (EVar "importerEdgeIndex") (EVar "mods")) (EVar "omEmpty"))) (EVar "mods")) (EVar "omEmpty")))
(DTypeSig false "importerReachGo" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "importerReachGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "importerReachGo" ((PVar "edges") (PCons (PTuple (PVar "mid") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "importerReachGo") (EVar "edges")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EApp (EApp (EApp (EVar "declEnvReachFrom") (EVar "edges")) (EListLit (EVar "mid"))) (EVar "omEmpty"))) (EVar "acc"))))
(DTypeSig false "importerEdgeIndex" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "importerEdgeIndex" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "importerEdgeIndex" ((PCons (PTuple (PVar "mid") (PVar "prog")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EVar "acc")) (EApp (EApp (EVar "importerEdgeIndex") (EVar "rest")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EVar "importerEdgeIndex") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EApp (EApp (EDictApp "flatMap") (EVar "useModuleId")) (EVar "prog"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "depExportsStandalone" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "depExportsStandalone" ((PVar "gctx") (PVar "depId") (PVar "bare")) (EIf (EApp (EApp (EVar "depExportsUnknown") (EVar "gctx")) (EVar "depId")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "==" (EApp (EVar "fst") (EVar "r")) (EVar "bare")))) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "depId"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "depExportsUnknown" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "depExportsUnknown" ((PVar "gctx") (PVar "depId")) (EBinOp "||" (EBinOp "==" (EVar "depId") (ELit (LString "core"))) (EBinOp "==" (EApp (EVar "omSize") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deDefiners")) (ELit (LInt 0)))))
(DTypeSig true "dtopFor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffLabel") (TyCon "Param"))))
(DFunDef false "dtopFor" ((PVar "gctx") (PVar "label")) (EApp (EApp (EVar "dtopIn") (EFieldAccess (EFieldAccess (EVar "gctx") "effectDomains") "value")) (EVar "label")))
(DTypeSig true "domainHasPatterns" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "domainHasPatterns" ((PCon "PPrefix" PWild)) (EVar "True"))
(DFunDef false "domainHasPatterns" ((PCon "PPath" PWild)) (EVar "True"))
(DFunDef false "domainHasPatterns" ((PCon "PProduct" (PCons (PTuple PWild (PVar "axis")) PWild))) (EApp (EVar "domainHasPatterns") (EVar "axis")))
(DFunDef false "domainHasPatterns" (PWild) (EVar "False"))
(DTypeSig true "rangedOver" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "EffLabel") (TyFun (TyCon "Bool") (TyCon "Bool")))))
(DFunDef false "rangedOver" ((PVar "gctx") (PVar "l") (PVar "pat")) (EBinOp "&&" (EVar "pat") (EApp (EVar "domainHasPatterns") (EApp (EApp (EVar "dtopFor") (EVar "gctx")) (EVar "l")))))
(DTypeSig true "ifaceParamKindsFor" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "ifaceParamKindsFor" ((PVar "gctx") (PList) PWild PWild PWild) (EListLit))
(DFunDef false "ifaceParamKindsFor" ((PVar "gctx") (PCons (PVar "q") (PVar "qs")) (PCons (PVar "a") (PVar "anns")) (PVar "methods") (PVar "p")) (EIf (EBinOp "==" (EVar "q") (EVar "p")) (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDecl") (EVar "gctx")) (EVar "a")) (EVar "p")) (EVar "methods")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsFor") (EVar "gctx")) (EVar "qs")) (EVar "anns")) (EVar "methods")) (EVar "p")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "ifaceParamKindsFor" ((PVar "gctx") PWild (PList) PWild PWild) (EListLit))
(DTypeSig true "tyTabKey" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "TabKey"))))
(DFunDef false "tyTabKey" ((PVar "o") (PVar "n")) (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsType")) (EVar "o")) (EVar "n")))
(DTypeSig true "ifaceTabKey" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "TabKey"))))
(DFunDef false "ifaceTabKey" ((PVar "o") (PVar "n")) (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsIface")) (EVar "o")) (EVar "n")))
(DTypeSig true "emptyDeclEnvAcc" (TyCon "DeclEnvAcc"))
(DFunDef false "emptyDeclEnvAcc" () (ERecordCreate "DeclEnvAcc" ((fa "daOrdIndex" (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (ELit (LInt 0))) (EVar "omEmpty"))) (fa "daDefiners" (EVar "omEmpty")) (fa "daAmbig" (EVar "omEmpty")) (fa "daData" (EVar "emptyDataEnv")) (fa "daImpls" (EVar "emptyImplAcc")) (fa "daIfaces" (EVar "emptyClassEnv")) (fa "daMethods" (EVar "emptyMethodEnv")) (fa "daSeeds" (EVar "emptyDeclEnvSeedAcc")) (fa "daPolarity" (ETuple (EListLit) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (EListLit)) (EVar "omEmpty")))) (fa "daOwnerModules" (EVar "omEmpty")))))
(DTypeSig true "declEnvModule" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "DeclEnvModule"))))))
(DFunDef false "declEnvModule" ((PVar "gctx") (PVar "k") (PVar "mid") (PVar "decls")) (ERecordCreate "DeclEnvModule" ((fa "demOrd" (EVar "k")) (fa "demId" (EVar "mid")) (fa "demDecls" (EVar "decls")) (fa "demPubDecls" (EApp (EVar "publicDataDecls") (EVar "decls"))) (fa "demKindEntries" (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EApp (EApp (EVar "filterList") (EVar "kindPublicDataDecl")) (EVar "decls")))))))
(DTypeSig true "declEnvDeclsOf" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "declEnvDeclsOf" ((PList)) (EListLit))
(DFunDef false "declEnvDeclsOf" ((PCons (PVar "m") (PVar "rest"))) (EBinOp "++" (EFieldAccess (EVar "m") "demDecls") (EApp (EVar "declEnvDeclsOf") (EVar "rest"))))
(DTypeSig true "declEnvVisibleAt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "declEnvVisibleAt" ((PVar "cur") (PVar "entryOrd")) (EBinOp "<=" (EVar "entryOrd") (EVar "cur")))
(DTypeSig false "ieCandidacyVisibleAt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "ieCandidacyVisibleAt" (PWild PWild) (EVar "True"))
(DTypeSig true "declEnvsOrdOf" (TyFun (TyCon "String") (TyFun (TyCon "DeclEnvs") (TyCon "Int"))))
(DFunDef false "declEnvsOrdOf" ((PVar "mid") (PVar "envs")) (EApp (EApp (EVar "ordOfIndex") (EVar "mid")) (EFieldAccess (EVar "envs") "deOrdIndex")))
(DTypeSig true "ordOfIndex" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "ordOfIndex" ((PVar "mid") (PVar "index")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EMethodRef "index")) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))))
(DTypeSig true "declEnvVisibleTo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool")))))
(DFunDef false "declEnvVisibleTo" ((PVar "cur") (PVar "entryOrd") (PVar "entryIsPublic")) (EBinOp "&&" (EApp (EApp (EVar "declEnvVisibleAt") (EVar "cur")) (EVar "entryOrd")) (EBinOp "||" (EBinOp "==" (EVar "entryOrd") (EVar "cur")) (EVar "entryIsPublic"))))
(DTypeSig true "declEnvRowVisible" (TyFun (TyCon "Int") (TyFun (TyCon "DeclEnvModule") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "declEnvRowVisible" ((PVar "cur") (PVar "m")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "False")) (EFieldAccess (EVar "m") "demDecls") (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "True")) (EFieldAccess (EVar "m") "demPubDecls") (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "declEnvKindEntries" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind")))))))
(DFunDef false "declEnvKindEntries" ((PVar "gctx") (PList)) (EListLit))
(DFunDef false "declEnvKindEntries" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "declEnvKindEntries" ((PVar "gctx") (PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataParamKinds" (PVar "ks")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EVar "gctx")) (EVar "ps")) (EVar "ks"))) (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EVar "rest"))))
(DFunDef false "declEnvKindEntries" ((PVar "gctx") (PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeParamKinds" (PVar "ks")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EVar "gctx")) (EVar "ps")) (EVar "ks"))) (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EVar "rest"))))
(DFunDef false "declEnvKindEntries" ((PVar "gctx") (PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasParamKinds" (PVar "ks")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EVar "gctx")) (EVar "ps")) (EVar "ks"))) (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EVar "rest"))))
(DFunDef false "declEnvKindEntries" ((PVar "gctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EVar "rest")))
(DTypeSig true "declEnvReachFrom" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "declEnvReachFrom" (PWild (PList) (PVar "seen")) (EVar "seen"))
(DFunDef false "declEnvReachFrom" ((PVar "edges") (PCons (PVar "mid") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "fresh") (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "d")) (EVar "seen"))))) (EApp (EApp (EVar "declEnvDirectImports") (EVar "edges")) (EVar "mid")))) (DoExpr (EApp (EApp (EApp (EVar "declEnvReachFrom") (EVar "edges")) (EBinOp "++" (EVar "fresh") (EVar "rest"))) (EApp (EApp (EVar "declEnvMarkReached") (EVar "fresh")) (EVar "seen"))))))
(DTypeSig false "declEnvMarkReached" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "declEnvMarkReached" ((PList) (PVar "seen")) (EVar "seen"))
(DFunDef false "declEnvMarkReached" ((PCons (PVar "d") (PVar "rest")) (PVar "seen")) (EApp (EApp (EVar "declEnvMarkReached") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "d")) (ELit LUnit)) (EVar "seen"))))
(DTypeSig false "declEnvDirectImports" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declEnvDirectImports" ((PVar "edges") (PVar "mid")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "edges"))))
(DTypeSig true "instRefMid" (TyFun (TyCon "InstRef") (TyCon "String")))
(DFunDef false "instRefMid" ((PCon "InstRef" (PVar "m") PWild PWild)) (EVar "m"))
(DTypeSig true "instRefSeq" (TyFun (TyCon "InstRef") (TyCon "Int")))
(DFunDef false "instRefSeq" ((PCon "InstRef" PWild PWild (PVar "s"))) (EVar "s"))
(DTypeSig true "ieRowOrd" (TyFun (TyCon "ImplRow") (TyCon "Int")))
(DFunDef false "ieRowOrd" ((PCon "ImplRow" (PVar "o") PWild PWild PWild PWild PWild PWild)) (EVar "o"))
(DTypeSig true "ieRowInst" (TyFun (TyCon "ImplRow") (TyCon "InstRef")))
(DFunDef false "ieRowInst" ((PCon "ImplRow" PWild (PVar "i") PWild PWild PWild PWild PWild)) (EVar "i"))
(DTypeSig true "ieRowTriple" (TyFun (TyCon "ImplRow") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))))
(DFunDef false "ieRowTriple" ((PCon "ImplRow" PWild PWild (PVar "ir") (PVar "tys") (PVar "reqs") PWild PWild)) (ETuple (EVar "ir") (EVar "tys") (EVar "reqs")))
(DTypeSig true "ieRowIface" (TyFun (TyCon "ImplRow") (TyCon "IfaceRef")))
(DFunDef false "ieRowIface" ((PCon "ImplRow" PWild PWild (PVar "ir") PWild PWild PWild PWild)) (EVar "ir"))
(DTypeSig true "ieRowMethodNames" (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ieRowMethodNames" ((PCon "ImplRow" PWild PWild PWild PWild PWild (PVar "ms") PWild)) (EVar "ms"))
(DTypeSig true "ieRowLoc" (TyFun (TyCon "ImplRow") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "ieRowLoc" ((PCon "ImplRow" PWild PWild PWild PWild PWild PWild (PVar "l"))) (EVar "l"))
(DTypeSig false "emptyImplAcc" (TyCon "ImplAcc"))
(DFunDef false "emptyImplAcc" () (ERecordCreate "ImplAcc" ((fa "iaEnv" (EVar "emptyImplEnv")) (fa "iaSeq" (ELit (LInt 0))) (fa "iaSnaps" (EVar "ieSnapZero")))))
(DTypeSig false "buildImplEnv" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyCon "ImplEnv")))
(DFunDef false "buildImplEnv" ((PVar "mods")) (EApp (EVar "implAccFinish") (EApp (EApp (EVar "buildImplEnvGo") (EVar "mods")) (EVar "emptyImplAcc"))))
(DTypeSig true "implAccFinish" (TyFun (TyCon "ImplAcc") (TyCon "ImplEnv")))
(DFunDef false "implAccFinish" ((PVar "ia")) (EBlock (DoLet false false (PVar "env") (EFieldAccess (EVar "ia") "iaEnv")) (DoExpr (EVariantUpdate "ImplEnv" (EVar "env") ((fa "ieRows" (EApp (EVar "reverseL") (EFieldAccess (EVar "env") "ieRows"))) (fa "ieUnivSnaps" (EApp (EVar "reverseL") (EApp (EVar "fst") (EFieldAccess (EVar "ia") "iaSnaps")))))))))
(DTypeSig true "buildImplEnvGo" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "ImplAcc") (TyCon "ImplAcc"))))
(DFunDef false "buildImplEnvGo" ((PList) (PVar "ia")) (EVar "ia"))
(DFunDef false "buildImplEnvGo" ((PCons (PVar "m") (PVar "rest")) (PVar "ia")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EApp (EVar "implRowsOf") (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "m") "demOrd")) (EFieldAccess (EVar "ia") "iaSeq")) (EApp (EVar "implDeclFacts") (EFieldAccess (EVar "m") "demDecls")))) (DoExpr (EApp (EApp (EVar "buildImplEnvGo") (EVar "rest")) (ERecordCreate "ImplAcc" ((fa "iaEnv" (EApp (EApp (EVar "ieAddRows") (EVar "rows")) (EFieldAccess (EVar "ia") "iaEnv"))) (fa "iaSeq" (EBinOp "+" (EFieldAccess (EVar "ia") "iaSeq") (EApp (EVar "listLen") (EVar "rows")))) (fa "iaSnaps" (EApp (EApp (EVar "ieSnapStep") (EVar "rows")) (EFieldAccess (EVar "ia") "iaSnaps")))))))))
(DTypeSig false "ieSnapZero" (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyCon "ImplUniverse")))
(DFunDef false "ieSnapZero" () (ETuple (EListLit) (EVar "emptyImplUniverse")))
(DTypeSig false "ieSnapStep" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyCon "ImplUniverse")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyCon "ImplUniverse")))))
(DFunDef false "ieSnapStep" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "ieSnapStep" ((PCons (PVar "r") (PVar "rest")) (PTuple (PVar "snaps") (PVar "univ"))) (EBlock (DoLet false false (PVar "univ2") (EApp (EApp (EVar "growImplUniverse") (EApp (EApp (EMethodRef "map") (EVar "ieRowTriple")) (EBinOp "::" (EVar "r") (EVar "rest")))) (EVar "univ"))) (DoExpr (ETuple (EBinOp "::" (ETuple (EApp (EVar "ieRowOrd") (EVar "r")) (EVar "univ2")) (EVar "snaps")) (EVar "univ2")))))
(DTypeSig false "implDeclFacts" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "implDeclFacts" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "implDeclFact")) (EVar "prog")))
(DTypeSig false "implDeclFact" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "implDeclFact" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "implDeclFact") (EVar "d")))
(DFunDef false "implDeclFact" ((PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None) (rf "implOrigin" None) (rf "implIfaceLoc" None)) true)) (EListLit (ETuple (ERecordCreate "IfaceRef" ((fa "irName" (EVar "iface")) (fa "irOrigin" (EVar "implOrigin")))) (EVar "tys") (EVar "reqs") (EApp (EApp (EMethodRef "map") (EVar "implMethodNameTc")) (EVar "methods")) (EVar "implIfaceLoc"))))
(DFunDef false "implDeclFact" (PWild) (EListLit))
(DTypeSig false "implRowsOf" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "ImplRow")))))))
(DFunDef false "implRowsOf" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "implRowsOf" ((PVar "mid") (PVar "ord") (PVar "seq") (PCons (PTuple (PVar "iface") (PVar "tys") (PVar "reqs") (PVar "ms") (PVar "loc")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ImplRow") (EVar "ord")) (EApp (EApp (EApp (EVar "InstRef") (EVar "mid")) (EVar "ord")) (EVar "seq"))) (EVar "iface")) (EVar "tys")) (EVar "reqs")) (EVar "ms")) (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "implRowsOf") (EVar "mid")) (EVar "ord")) (EBinOp "+" (EVar "seq") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "ieAddRows" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv"))))
(DFunDef false "ieAddRows" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "ieAddRows" ((PCons (PVar "r") (PVar "rest")) (PVar "env")) (EApp (EApp (EVar "ieAddRows") (EVar "rest")) (EApp (EApp (EVar "ieInsertRow") (EVar "r")) (EVar "env"))))
(DTypeSig false "ieInsertRow" (TyFun (TyCon "ImplRow") (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv"))))
(DFunDef false "ieInsertRow" ((PVar "r") (PVar "env")) (EApp (EApp (EVar "ieFileRow") (EVar "r")) (ERecordUpdate (EVar "env") ((fa "ieRows" (EBinOp "::" (EVar "r") (EFieldAccess (EVar "env") "ieRows")))))))
(DTypeSig false "ieFileRow" (TyFun (TyCon "ImplRow") (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv"))))
(DFunDef false "ieFileRow" ((PAs "r" (PCon "ImplRow" PWild PWild (PVar "ir") PWild PWild PWild PWild)) (PVar "env")) (EApp (EApp (EApp (EVar "ieInsertRowKeys") (EApp (EVar "oblIfaceKeys") (EVar "ir"))) (EVar "r")) (EApp (EApp (EVar "ieFileRowByHead") (EVar "r")) (EVar "env"))))
(DTypeSig false "ieFileRowByHead" (TyFun (TyCon "ImplRow") (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv"))))
(DFunDef false "ieFileRowByHead" ((PAs "r" (PCon "ImplRow" PWild PWild PWild (PVar "tys") PWild PWild PWild)) (PVar "env")) (EVariantUpdate "ImplEnv" (EVar "env") ((fa "ieByHead" (EApp (EApp (EApp (EVar "mregAppendK") (EApp (EVar "headBucketKey") (EApp (EVar "univReceiverTag") (EVar "tys")))) (EVar "r")) (EFieldAccess (EVar "env") "ieByHead"))))))
(DTypeSig true "ieHeadRows" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow")))))
(DFunDef false "ieHeadRows" ((PVar "hd") (PVar "env")) (EApp (EApp (EVar "mregLookupK") (EApp (EVar "headBucketKey") (EVar "hd"))) (EFieldAccess (EVar "env") "ieByHead")))
(DTypeSig false "ieInsertRowKeys" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyCon "ImplRow") (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv")))))
(DFunDef false "ieInsertRowKeys" ((PList) PWild (PVar "env")) (EVar "env"))
(DFunDef false "ieInsertRowKeys" ((PCons (PVar "ifk") (PVar "rest")) (PVar "r") (PVar "env")) (EApp (EApp (EApp (EVar "ieInsertRowKeys") (EVar "rest")) (EVar "r")) (EApp (EApp (EApp (EVar "ieInsertRowAt") (EVar "ifk")) (EVar "r")) (EVar "env"))))
(DTypeSig false "ieInsertRowAt" (TyFun (TyCon "TabKey") (TyFun (TyCon "ImplRow") (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv")))))
(DFunDef false "ieInsertRowAt" ((PVar "ifk") (PAs "r" (PCon "ImplRow" PWild PWild PWild (PVar "tys") PWild PWild PWild)) (PVar "env")) (EMatch (EApp (EVar "univReceiverTag") (EVar "tys")) (arm (PCon "Some" (PVar "hk")) () (EVariantUpdate "ImplEnv" (EVar "env") ((fa "ieConcrete" (EApp (EApp (EApp (EVar "mregAppendK") (EApp (EVar "regKeyNTab") (EListLit (EVar "ifk") (EApp (EVar "dispHeadTab") (EVar "hk"))))) (EVar "r")) (EFieldAccess (EVar "env") "ieConcrete")))))) (arm (PCon "None") () (EVariantUpdate "ImplEnv" (EVar "env") ((fa "ieHeadless" (EApp (EApp (EApp (EVar "mregAppendK") (EApp (EVar "regKeyOfTab") (EVar "ifk"))) (EVar "r")) (EFieldAccess (EVar "env") "ieHeadless"))))))))
(DTypeSig true "ieUniverseAt" (TyFun (TyCon "Int") (TyFun (TyCon "ImplEnv") (TyCon "ImplUniverse"))))
(DFunDef false "ieUniverseAt" ((PVar "cur") (PVar "env")) (EApp (EApp (EApp (EVar "ieSnapAt") (EVar "cur")) (EFieldAccess (EVar "env") "ieUnivSnaps")) (EVar "emptyImplUniverse")))
(DTypeSig false "ieSnapAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyFun (TyCon "ImplUniverse") (TyCon "ImplUniverse")))))
(DFunDef false "ieSnapAt" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "ieSnapAt" ((PVar "cur") (PCons (PTuple (PVar "o") (PVar "u")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "ieCandidacyVisibleAt") (EVar "cur")) (EVar "o")) (EApp (EApp (EApp (EVar "ieSnapAt") (EVar "cur")) (EVar "rest")) (EVar "u")) (EIf (EVar "otherwise") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ieRowsVisibleAt" (TyFun (TyCon "Int") (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow")))))
(DFunDef false "ieRowsVisibleAt" ((PVar "cur") (PVar "env")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "ieCandidacyVisibleAt") (EVar "cur")) (EApp (EVar "ieRowOrd") (EVar "r"))))) (EFieldAccess (EVar "env") "ieRows")))
(DTypeSig true "ieRowsAll" (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow"))))
(DFunDef false "ieRowsAll" ((PVar "env")) (EFieldAccess (EVar "env") "ieRows"))
(DTypeSig true "ieRowsOwnedBy" (TyFun (TyCon "Int") (TyFun (TyCon "ImplEnv") (TyApp (TyCon "List") (TyCon "ImplRow")))))
(DFunDef false "ieRowsOwnedBy" ((PVar "cur") (PVar "env")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "==" (EApp (EVar "ieRowOrd") (EVar "r")) (EVar "cur")))) (EFieldAccess (EVar "env") "ieRows")))
(DTypeSig false "ceRowKey" (TyFun (TyCon "CeRow") (TyCon "RegKey")))
(DFunDef false "ceRowKey" ((PCon "CeRow" (PVar "k") PWild PWild PWild PWild PWild PWild PWild PWild)) (EVar "k"))
(DTypeSig true "ceRowOrd" (TyFun (TyCon "CeRow") (TyCon "Int")))
(DFunDef false "ceRowOrd" ((PCon "CeRow" PWild (PVar "o") PWild PWild PWild PWild PWild PWild PWild)) (EVar "o"))
(DTypeSig true "ceRowIface" (TyFun (TyCon "CeRow") (TyCon "IfaceRef")))
(DFunDef false "ceRowIface" ((PCon "CeRow" PWild PWild (PVar "ir") PWild PWild PWild PWild PWild PWild)) (EVar "ir"))
(DTypeSig true "ceRowTyparams" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ceRowTyparams" ((PCon "CeRow" PWild PWild PWild (PVar "tp") PWild PWild PWild PWild PWild)) (EVar "tp"))
(DTypeSig true "ceRowMethods" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "ceRowMethods" ((PCon "CeRow" PWild PWild PWild PWild (PVar "ms") PWild PWild PWild PWild)) (EVar "ms"))
(DTypeSig true "ceRowSupers" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyCon "Super"))))
(DFunDef false "ceRowSupers" ((PCon "CeRow" PWild PWild PWild PWild PWild (PVar "sups") PWild PWild PWild)) (EVar "sups"))
(DTypeSig true "ceRowParamKinds" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind")))))
(DFunDef false "ceRowParamKinds" ((PCon "CeRow" PWild PWild PWild PWild PWild PWild (PVar "pk") PWild PWild)) (EVar "pk"))
(DTypeSig true "ceRowRequired" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ceRowRequired" ((PCon "CeRow" PWild PWild PWild PWild PWild PWild PWild (PVar "req") PWild)) (EVar "req"))
(DTypeSig true "ceRowLoc" (TyFun (TyCon "CeRow") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "ceRowLoc" ((PCon "CeRow" PWild PWild PWild PWild PWild PWild PWild PWild (PVar "l"))) (EVar "l"))
(DTypeSig true "classEnvFinish" (TyFun (TyCon "ClassEnv") (TyCon "ClassEnv")))
(DFunDef false "classEnvFinish" ((PVar "env")) (EVariantUpdate "ClassEnv" (EVar "env") ((fa "ceRows" (EApp (EVar "reverseL") (EFieldAccess (EVar "env") "ceRows"))))))
(DTypeSig true "buildClassEnvGo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "ClassEnv") (TyCon "ClassEnv")))))
(DFunDef false "buildClassEnvGo" ((PVar "gctx") (PList) (PVar "env")) (EVar "env"))
(DFunDef false "buildClassEnvGo" ((PVar "gctx") (PCons (PVar "m") (PVar "rest")) (PVar "env")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EVar "classEnvRowsOf") (EVar "gctx")) (EFieldAccess (EVar "m") "demOrd")) (EApp (EVar "classEnvDeclFacts") (EFieldAccess (EVar "m") "demDecls")))) (DoExpr (EApp (EApp (EApp (EVar "buildClassEnvGo") (EVar "gctx")) (EVar "rest")) (EApp (EApp (EVar "ceAddRows") (EVar "rows")) (EVar "env"))))))
(DTypeSig false "classEnvDeclFacts" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "Super")) (TyCon "TyConOrigin") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "classEnvDeclFacts" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "classEnvDeclFact")) (EVar "prog")))
(DTypeSig false "classEnvDeclFact" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "Super")) (TyCon "TyConOrigin") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "classEnvDeclFact" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "classEnvDeclFact") (EVar "d")))
(DFunDef false "classEnvDeclFact" ((PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "supers" None) (rf "methods" None) (rf "ifaceOrigin" None) (rf "ifaceNameLoc" None)) true)) (EListLit (ETuple (EVar "name") (EVar "typarams") (EVar "typaramKinds") (EVar "methods") (EVar "supers") (EVar "ifaceOrigin") (EVar "ifaceNameLoc"))))
(DFunDef false "classEnvDeclFact" (PWild) (EListLit))
(DTypeSig false "classEnvRowsOf" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "Super")) (TyCon "TyConOrigin") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "CeRow"))))))
(DFunDef false "classEnvRowsOf" ((PVar "gctx") PWild (PList)) (EListLit))
(DFunDef false "classEnvRowsOf" ((PVar "gctx") (PVar "ord") (PCons (PTuple (PVar "name") (PVar "typarams") (PVar "kinds") (PVar "methods") (PVar "supers") (PVar "o") (PVar "loc")) (PVar "rest"))) (EBlock (DoLet false false (PVar "scope") (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EVar "gctx")) (EVar "typarams")) (EVar "kinds")) (EVar "methods"))) (DoLet false false (PVar "row") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CeRow") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "o")) (EVar "name")))) (EVar "ord")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "o"))))) (EVar "typarams")) (EApp (EApp (EMethodRef "map") (EApp (EVar "ceMethodOf") (EVar "scope"))) (EVar "methods"))) (EVar "supers")) (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDeclAll") (EVar "gctx")) (EVar "typarams")) (EVar "kinds")) (EVar "methods"))) (EApp (EVar "requiredMethodNames") (EVar "methods"))) (EVar "loc"))) (DoExpr (EBinOp "::" (EVar "row") (EApp (EApp (EApp (EVar "classEnvRowsOf") (EVar "gctx")) (EVar "ord")) (EVar "rest"))))))
(DTypeSig true "ifaceParamKindsDeclAll" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "ifaceParamKindsDeclAll" ((PVar "gctx") (PList) PWild PWild) (EListLit))
(DFunDef false "ifaceParamKindsDeclAll" ((PVar "gctx") (PCons (PVar "p") (PVar "ps")) (PList) (PVar "methods")) (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDeclAll") (EVar "gctx")) (EBinOp "::" (EVar "p") (EVar "ps"))) (EListLit (EVar "None"))) (EVar "methods")))
(DFunDef false "ifaceParamKindsDeclAll" ((PVar "gctx") (PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "anns")) (PVar "methods")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDecl") (EVar "gctx")) (EVar "a")) (EVar "p")) (EVar "methods")) (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDeclAll") (EVar "gctx")) (EVar "ps")) (EVar "anns")) (EVar "methods"))))
(DTypeSig false "ceMethodOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "ceMethodOf" ((PVar "scope") (PCon "IfaceMethod" (PVar "n") (PVar "ty") PWild PWild)) (ETuple (EVar "n") (EVar "ty") (EVar "scope")))
(DTypeSig false "ceAddRows" (TyFun (TyApp (TyCon "List") (TyCon "CeRow")) (TyFun (TyCon "ClassEnv") (TyCon "ClassEnv"))))
(DFunDef false "ceAddRows" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "ceAddRows" ((PCons (PVar "r") (PVar "rest")) (PVar "env")) (EApp (EApp (EVar "ceAddRows") (EVar "rest")) (EApp (EApp (EVar "ceInsertRow") (EVar "r")) (EVar "env"))))
(DTypeSig false "ceInsertRow" (TyFun (TyCon "CeRow") (TyFun (TyCon "ClassEnv") (TyCon "ClassEnv"))))
(DFunDef false "ceInsertRow" ((PVar "r") (PVar "env")) (EVariantUpdate "ClassEnv" (EVar "env") ((fa "ceRows" (EBinOp "::" (EVar "r") (EFieldAccess (EVar "env") "ceRows"))) (fa "ceByKey" (EApp (EApp (EApp (EVar "regInsertK") (EApp (EVar "ceRowKey") (EVar "r"))) (EVar "r")) (EFieldAccess (EVar "env") "ceByKey"))))))
(DTypeSig true "ceLookupAt" (TyFun (TyCon "RegKey") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "Option") (TyCon "CeRow"))))))
(DFunDef false "ceLookupAt" ((PVar "key") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EVar "regLookupK") (EVar "key")) (EFieldAccess (EVar "env") "ceByKey")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "r")) () (EIf (EApp (EApp (EVar "declEnvVisibleAt") (EVar "cur")) (EApp (EVar "ceRowOrd") (EVar "r"))) (EApp (EVar "Some") (EVar "r")) (EVar "None")))))
(DTypeSig true "ceLookupGraph" (TyFun (TyCon "RegKey") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "Option") (TyCon "CeRow")))))
(DFunDef false "ceLookupGraph" ((PVar "key") (PVar "env")) (EApp (EApp (EVar "regLookupK") (EVar "key")) (EFieldAccess (EVar "env") "ceByKey")))
(DTypeSig true "ceRowsVisibleAt" (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "CeRow")))))
(DFunDef false "ceRowsVisibleAt" ((PVar "cur") (PVar "env")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "declEnvVisibleAt") (EVar "cur")) (EApp (EVar "ceRowOrd") (EVar "r"))))) (EFieldAccess (EVar "env") "ceRows")))
(DTypeSig true "ceRowsOwnedBy" (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "CeRow")))))
(DFunDef false "ceRowsOwnedBy" ((PVar "cur") (PVar "env")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "==" (EApp (EVar "ceRowOrd") (EVar "r")) (EVar "cur")))) (EFieldAccess (EVar "env") "ceRows")))
(DTypeSig true "ceSlotKindsAt" (TyFun (TyCon "RegKey") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "ceSlotKindsAt" ((PVar "key") (PVar "cur") (PVar "i") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EVar "key")) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EVar "nthKindList") (EVar "i")) (EApp (EVar "ceRowParamKinds") (EVar "r"))))))
(DTypeSig true "ceRequiredAt" (TyFun (TyCon "RegKey") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ceRequiredAt" ((PVar "key") (PVar "cur") (PVar "env")) (EApp (EApp (EMethodRef "map") (EVar "ceRowRequired")) (EApp (EApp (EApp (EVar "ceLookupAt") (EVar "key")) (EVar "cur")) (EVar "env"))))
(DTypeSig false "nthKindList" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Kind"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Kind"))))))
(DFunDef false "nthKindList" (PWild (PList)) (EVar "None"))
(DFunDef false "nthKindList" ((PVar "i") (PCons (PVar "k") (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "k")) (EIf (EVar "otherwise") (EApp (EApp (EVar "nthKindList") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ceRowMethodNames" (TyFun (TyCon "CeRow") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ceRowMethodNames" ((PVar "r")) (EApp (EApp (EMethodRef "map") (EVar "ceMethodName")) (EApp (EVar "ceRowMethods") (EVar "r"))))
(DTypeSig false "ceMethodName" (TyFun (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))) (TyCon "String")))
(DFunDef false "ceMethodName" ((PTuple (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig true "methodEnvGo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "MethodEnv") (TyCon "MethodEnv")))))
(DFunDef false "methodEnvGo" ((PVar "gctx") (PList) (PVar "env")) (EVar "env"))
(DFunDef false "methodEnvGo" ((PVar "gctx") (PCons (PVar "m") (PVar "rest")) (PVar "env")) (EApp (EApp (EApp (EVar "methodEnvGo") (EVar "gctx")) (EVar "rest")) (ERecordCreate "MethodEnv" ((fa "meByName" (EApp (EApp (EApp (EApp (EVar "methodRowsInto") (EVar "gctx")) (EFieldAccess (EVar "m") "demOrd")) (EFieldAccess (EVar "m") "demDecls")) (EFieldAccess (EVar "env") "meByName"))) (fa "meExports" (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EBinOp "++" (EApp (EVar "declMethodIdents") (EFieldAccess (EVar "m") "demDecls")) (EApp (EApp (EVar "reexportedMethodIdents") (EFieldAccess (EVar "env") "meExports")) (EFieldAccess (EVar "m") "demDecls")))) (EFieldAccess (EVar "env") "meExports"))) (fa "meIfaceExports" (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EBinOp "++" (EApp (EVar "ifaceMethodRows") (EFieldAccess (EVar "m") "demDecls")) (EApp (EApp (EVar "reexportedIfaceMethods") (EFieldAccess (EVar "env") "meIfaceExports")) (EFieldAccess (EVar "m") "demDecls")))) (EFieldAccess (EVar "env") "meIfaceExports")))))))
(DTypeSig false "methodRowsInto" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodRow"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodRow"))))))))
(DFunDef false "methodRowsInto" ((PVar "gctx") PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "methodRowsInto" ((PVar "gctx") (PVar "ord") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "methodRowsInto") (EVar "gctx")) (EVar "ord")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "methodRowsInto") (EVar "gctx")) (EVar "ord")) (EListLit (EVar "d"))) (EVar "acc"))))
(DFunDef false "methodRowsInto" ((PVar "gctx") (PVar "ord") (PCons (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "methods" None) (rf "ifaceOrigin" None)) true) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "methodRowsInto") (EVar "gctx")) (EVar "ord")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodRowsOfIface") (EVar "ord")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "ifaceOrigin"))))) (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EVar "ifaceOrigin")) (EVar "name")))) (EVar "typarams")) (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EVar "gctx")) (EVar "typarams")) (EVar "typaramKinds")) (EVar "methods"))) (EVar "methods")) (EVar "acc"))))
(DFunDef false "methodRowsInto" ((PVar "gctx") (PVar "ord") (PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "methodRowsInto") (EVar "gctx")) (EVar "ord")) (EVar "rest")) (EVar "acc")))
(DTypeSig false "methodRowsOfIface" (TyFun (TyCon "Int") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodRow"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodRow")))))))))))
(DFunDef false "methodRowsOfIface" (PWild PWild PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "methodRowsOfIface" ((PVar "ord") (PVar "iface") (PVar "key") (PVar "typarams") (PVar "scope") (PCons (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "acc2") (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsMethod")) (EFieldAccess (EVar "iface") "irOrigin")) (EVar "mname")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "ident")) () (EBlock (DoLet false false (PVar "row") (ERecordCreate "MethodRow" ((fa "mrIdent" (EVar "ident")) (fa "mrOrd" (EVar "ord")) (fa "mrIface" (EVar "key")) (fa "mrEntry" (ETuple (EVar "iface") (EVar "typarams") (EVar "mty") (EVar "scope")))))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "mname")) (EBinOp "++" (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "/=" (EFieldAccess (EVar "r") "mrIdent") (EVar "ident")))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mname")) (EVar "acc")))) (EListLit (EVar "row")))) (EVar "acc"))))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodRowsOfIface") (EVar "ord")) (EVar "iface")) (EVar "key")) (EVar "typarams")) (EVar "scope")) (EVar "rest")) (EVar "acc2")))))
(DTypeSig true "methodRowById" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyApp (TyCon "Option") (TyCon "MethodRow")))))
(DFunDef false "methodRowById" (PWild (PList)) (EVar "None"))
(DFunDef false "methodRowById" ((PVar "ident") (PCons (PVar "r") (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "mrIdent") (EVar "ident")) (EApp (EVar "Some") (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EVar "methodRowById") (EVar "ident")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "methodRowCand" (TyFun (TyCon "MethodRow") (TyTuple (TyCon "Ident") (TyCon "MethodEntry"))))
(DFunDef false "methodRowCand" ((PVar "r")) (ETuple (EFieldAccess (EVar "r") "mrIdent") (EFieldAccess (EVar "r") "mrEntry")))
(DTypeSig true "methodRowIface" (TyFun (TyCon "MethodRow") (TyCon "IfaceRef")))
(DFunDef false "methodRowIface" ((PVar "r")) (EMatch (EFieldAccess (EVar "r") "mrEntry") (arm (PTuple (PVar "iface") PWild PWild PWild) () (EVar "iface"))))
(DTypeSig true "methodPreludeRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyApp (TyCon "Option") (TyCon "MethodRow")))))
(DFunDef false "methodPreludeRow" ((PVar "n") (PVar "cs")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsMethod")) (EApp (EVar "OriginModule") (ELit (LString "core")))) (EVar "n"))) (ELam ((PVar "ident")) (EApp (EApp (EVar "methodRowById") (EVar "ident")) (EVar "cs")))))
(DTypeSig true "methodExportsIndex" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident")))))))
(DFunDef false "methodExportsIndex" ((PVar "gctx") PWild) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deMethods") "meExports"))
(DTypeSig true "dispatchTyparams" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dispatchTyparams" ((PList)) (EListLit))
(DFunDef false "dispatchTyparams" ((PCons (PVar "p") PWild)) (EListLit (EVar "p")))
(DTypeSig true "effTailNames" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "effTailNames" ((PCon "TyVar" PWild)) (EListLit))
(DFunDef false "effTailNames" ((PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "effTailNames" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "effTailNames") (EVar "a")) (EApp (EVar "effTailNames") (EVar "b"))))
(DFunDef false "effTailNames" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "effTailNames") (EVar "a")) (EApp (EVar "effTailNames") (EVar "b"))))
(DFunDef false "effTailNames" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EVar "effTailNames")) (EVar "ts")))
(DFunDef false "effTailNames" ((PCon "TyEffect" PWild (PVar "tail") (PVar "t"))) (EBinOp "++" (EVar "tail") (EApp (EVar "effTailNames") (EVar "t"))))
(DFunDef false "effTailNames" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "effTailNames") (EVar "t")))
(DFunDef false "effTailNames" ((PCon "TyRow" PWild (PVar "tail") PWild)) (EVar "tail"))
(DFunDef false "effTailNames" ((PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "effTailNames" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "effTailNames") (EVar "t")))
(DFunDef false "effTailNames" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "effTailNames") (EVar "t")))
(DTypeSig true "lookupBinding" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "EnvBinding")))))
(DFunDef false "lookupBinding" ((PVar "env") (PVar "n")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "env") "teVars")))
(DTypeSig true "lookupVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupVar" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "env") "teVars")) (arm (PCon "Some" (PVar "binding")) () (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EVar "binding") "ebValue") "vsScheme"))) (arm (PCon "None") () (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "env") "teCtors")))))
(DTypeSig true "lookupMethodRow" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodSchemeRow")))))
(DFunDef false "lookupMethodRow" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "n")) (arm (PCon "Some" (PVar "binding")) () (EFieldAccess (EVar "binding") "ebMethodRow")) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "lookupCtor" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupCtor" ((PVar "env") (PVar "n")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "env") "teCtors")))
(DTypeSig true "extendVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "TcEnv")))))
(DFunDef false "extendVar" ((PVar "env") (PVar "n") (PVar "s")) (ERecordUpdate (EVar "env") ((fa "teVars" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EVar "ordinaryEnvBinding") (EVar "s"))) (EFieldAccess (EVar "env") "teVars"))))))
(DTypeSig true "extendVars" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "TcEnv"))))
(DFunDef false "extendVars" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "extendVars" ((PVar "env") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EApp (EApp (EVar "extendVars") (EApp (EApp (EApp (EVar "extendVar") (EVar "env")) (EVar "n")) (EVar "s"))) (EVar "rest")))
(DTypeSig true "extendMethodRow" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "MethodSchemeRow") (TyCon "TcEnv")))))
(DFunDef false "extendMethodRow" ((PVar "env") (PVar "n") (PVar "row")) (ERecordUpdate (EVar "env") ((fa "teVars" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EVar "methodEnvBinding") (EVar "row"))) (EFieldAccess (EVar "env") "teVars"))))))
(DTypeSig true "extendMethodRows" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyCon "TcEnv"))))
(DFunDef false "extendMethodRows" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "extendMethodRows" ((PVar "env") (PCons (PVar "row") (PVar "rest"))) (EBlock (DoLet false false (PVar "env2") (EIf (EApp (EVar "methodRowCanCarry") (EVar "row")) (EApp (EApp (EApp (EVar "extendMethodRow") (EVar "env")) (EFieldAccess (EVar "row") "msrName")) (EVar "row")) (EApp (EApp (EApp (EVar "extendVar") (EVar "env")) (EFieldAccess (EVar "row") "msrName")) (EFieldAccess (EVar "row") "msrScheme")))) (DoExpr (EApp (EApp (EVar "extendMethodRows") (EVar "env2")) (EVar "rest")))))
(DTypeSig true "extendBindings" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EnvBinding"))) (TyCon "TcEnv"))))
(DFunDef false "extendBindings" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "extendBindings" ((PVar "env") (PCons (PTuple (PVar "n") (PVar "binding")) (PVar "rest"))) (EApp (EApp (EVar "extendBindings") (ERecordUpdate (EVar "env") ((fa "teVars" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "binding")) (EFieldAccess (EVar "env") "teVars")))))) (EVar "rest")))
(DTypeSig true "lookupStandaloneVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupStandaloneVar" ((PVar "env") (PVar "name")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "value")) (EFieldAccess (EVar "value") "vsScheme"))) (EApp (EApp (EVar "lookupStandaloneValue") (EVar "env")) (EVar "name"))))
(DTypeSig true "lookupStandaloneValue" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "ValueScheme")))))
(DFunDef false "lookupStandaloneValue" ((PVar "env") (PVar "name")) (EMatch (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "name")) (arm (PCon "Some" (PVar "binding")) () (EApp (EApp (EMethodRef "map") (EVar "snd")) (EFieldAccess (EVar "binding") "ebStandalone"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "lookupImportedStandalone" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Scheme")))))
(DFunDef false "lookupImportedStandalone" ((PVar "env") (PVar "name")) (EMatch (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "name")) (arm (PCon "Some" (PVar "binding")) () (EMatch (EFieldAccess (EVar "binding") "ebStandalone") (arm (PCon "Some" (PTuple (PCon "ImportedStandalone") (PVar "value"))) () (EApp (EVar "Some") (EFieldAccess (EVar "value") "vsScheme"))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "hasImportDefiner" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasImportDefiner" ((PVar "mctx") (PVar "name")) (EApp (EVar "isSome") (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentImportDefinersRef") "value"))))
(DTypeSig true "bindingWithStandalone" (TyFun (TyCon "EnvBinding") (TyFun (TyTuple (TyCon "StandaloneOrigin") (TyCon "ValueScheme")) (TyCon "EnvBinding"))))
(DFunDef false "bindingWithStandalone" ((PVar "binding") (PVar "source")) (ERecordCreate "EnvBinding" ((fa "ebValue" (EFieldAccess (EVar "binding") "ebValue")) (fa "ebMethodRow" (EFieldAccess (EVar "binding") "ebMethodRow")) (fa "ebStandalone" (EApp (EVar "Some") (EVar "source"))))))
(DTypeSig true "extendTermBindings" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "TcEnv"))))
(DFunDef false "extendTermBindings" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "extendTermBindings" ((PVar "env") (PCons (PTuple (PVar "name") (PVar "scheme")) (PVar "rest"))) (EApp (EApp (EVar "extendTermBindings") (EApp (EApp (EVar "extendBindings") (EVar "env")) (EListLit (ETuple (EVar "name") (EApp (EApp (EVar "bindingWithStandalone") (EApp (EVar "ordinaryEnvBinding") (EVar "scheme"))) (ETuple (EVar "LocalStandalone") (EApp (EVar "ordinaryValueScheme") (EVar "scheme")))))))) (EVar "rest")))
(DTypeSig true "extendLocalVar" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "TcEnv")))))
(DFunDef false "extendLocalVar" ((PVar "env") (PVar "n") (PVar "s")) (ERecordUpdate (EVar "env") ((fa "teVars" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EVar "ordinaryEnvBinding") (EVar "s"))) (EFieldAccess (EVar "env") "teVars"))) (fa "teAlphaLets" (EBinOp "::" (ETuple (EVar "n") (EVar "AParam")) (EFieldAccess (EVar "env") "teAlphaLets"))) (fa "teIsLocal" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "True")) (EFieldAccess (EVar "env") "teIsLocal"))))))
(DTypeSig true "extendLocalVars" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "TcEnv"))))
(DFunDef false "extendLocalVars" ((PVar "env") (PList)) (EVar "env"))
(DFunDef false "extendLocalVars" ((PVar "env") (PCons (PTuple (PVar "n") (PVar "s")) (PVar "rest"))) (EApp (EApp (EVar "extendLocalVars") (EApp (EApp (EApp (EVar "extendLocalVar") (EVar "env")) (EVar "n")) (EVar "s"))) (EVar "rest")))
(DTypeSig true "lookupLocalFlag" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "lookupLocalFlag" ((PVar "env") (PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "teIsLocal")))
(DTypeSig true "addCtor" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Scheme") (TyCon "TcEnv")))))
(DFunDef false "addCtor" ((PVar "env") (PVar "n") (PVar "s")) (ERecordUpdate (EVar "env") ((fa "teCtors" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "s")) (EFieldAccess (EVar "env") "teCtors"))))))
(DTypeSig true "withCtors" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyCon "TcEnv"))))
(DFunDef false "withCtors" ((PVar "mctx") (PVar "cs")) (ERecordCreate "TcEnv" ((fa "teVars" (EVar "omEmpty")) (fa "teCtors" (EVar "cs")) (fa "teAlphaLets" (EListLit)) (fa "teIsLocal" (EVar "omEmpty")) (fa "teDyn" (EApp (EVar "dynFor") (EVar "mctx"))))))
(DTypeSig true "seedAlphaLets" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "TcEnv")))))
(DFunDef false "seedAlphaLets" ((PVar "env") (PVar "n") (PVar "rhs")) (ERecordUpdate (EVar "env") ((fa "teAlphaLets" (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "ALet") (EVar "rhs"))) (EFieldAccess (EVar "env") "teAlphaLets"))))))
(DTypeSig true "envAlphaLets" (TyFun (TyCon "TcEnv") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder")))))
(DFunDef false "envAlphaLets" ((PVar "env")) (EFieldAccess (EVar "env") "teAlphaLets"))
(DTypeSig true "originMethodName" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "originMethodName" ((PVar "mctx") (PVar "name")) (EApp (EApp (EVar "optionOr") (EVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasMethodOriginsRef") "value"))))
(DTypeSig true "lookupIdxById" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int"))) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "lookupIdxById" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "lookupIdxById" ((PVar "iface") (PVar "n") (PCons (PTuple (PTuple (PVar "ir") (PVar "mn")) (PVar "i")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "mn") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EFieldAccess (EVar "ir") "irName")) (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "iface") "irName")) (EFieldAccess (EVar "iface") "irOrigin"))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lookupIdxById") (EVar "iface")) (EVar "n")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "methodRowCanCarry" (TyFun (TyCon "MethodSchemeRow") (TyCon "Bool")))
(DFunDef false "methodRowCanCarry" ((PVar "row")) (EBinOp "&&" (EApp (EVar "isSome") (EApp (EVar "identOriginOf") (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irOrigin"))) (EApp (EVar "not") (EApp (EApp (EVar "anyArgMentions") (EApp (EVar "dispatchTyparams") (EFieldAccess (EVar "row") "msrTyparams"))) (EApp (EVar "methodArgs") (EFieldAccess (EVar "row") "msrType"))))))
(DTypeSig true "envVarType" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono")))))
(DFunDef false "envVarType" ((PVar "env") (PVar "x")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EApp (EVar "schemeBodyOf") (EFieldAccess (EFieldAccess (EVar "b") "ebValue") "vsScheme")))) (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "x"))))
(DTypeSig true "lookupRecordByName" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RecordInfo")))))
(DFunDef false "lookupRecordByName" ((PVar "mctx") (PVar "name")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef") "value")))
(DTypeSig true "declParamKinds" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyCon "Kind"))))))
(DFunDef false "declParamKinds" ((PVar "gctx") (PVar "params") (PVar "anns")) (EApp (EApp (EMethodRef "map") (EApp (EVar "kindOfAnn") (EVar "gctx"))) (EApp (EApp (EVar "padAnns") (EVar "params")) (EVar "anns"))))
(DTypeSig true "padAnns" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))))))
(DFunDef false "padAnns" ((PList) PWild) (EListLit))
(DFunDef false "padAnns" ((PCons PWild (PVar "ps")) (PCons (PVar "a") (PVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EApp (EVar "padAnns") (EVar "ps")) (EVar "rest"))))
(DFunDef false "padAnns" ((PCons PWild (PVar "ps")) (PList)) (EBinOp "::" (EVar "None") (EApp (EApp (EVar "padAnns") (EVar "ps")) (EListLit))))
(DTypeSig false "kindOfAnn" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "Option") (TyCon "KindAnn")) (TyCon "Kind"))))
(DFunDef false "kindOfAnn" ((PVar "gctx") (PCon "Some" (PCon "KindEffect"))) (EVar "KRow"))
(DFunDef false "kindOfAnn" ((PVar "gctx") (PCon "Some" (PCon "KindAuthority" (PVar "l") (PVar "o") (PVar "pat") PWild))) (EApp (EApp (EVar "KAuth") (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))) (EApp (EApp (EApp (EVar "rangedOver") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))) (EVar "pat"))))
(DFunDef false "kindOfAnn" ((PVar "gctx") PWild) (EVar "KType"))
(DTypeSig true "kindAnnSlots" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "KindAnn") (TyApp (TyCon "List") (TyCon "Kind")))))
(DFunDef false "kindAnnSlots" ((PVar "gctx") (PCon "KindArrow" (PVar "a") (PVar "b"))) (EBinOp "::" (EApp (EApp (EVar "kindAnnAtom") (EVar "gctx")) (EVar "a")) (EApp (EApp (EVar "kindAnnSlots") (EVar "gctx")) (EVar "b"))))
(DFunDef false "kindAnnSlots" ((PVar "gctx") PWild) (EListLit))
(DTypeSig false "kindAnnAtom" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "KindAnn") (TyCon "Kind"))))
(DFunDef false "kindAnnAtom" ((PVar "gctx") (PCon "KindEffect")) (EVar "KRow"))
(DFunDef false "kindAnnAtom" ((PVar "gctx") (PCon "KindAuthority" (PVar "l") (PVar "o") (PVar "pat") PWild)) (EApp (EApp (EVar "KAuth") (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))) (EApp (EApp (EApp (EVar "rangedOver") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))) (EVar "pat"))))
(DFunDef false "kindAnnAtom" ((PVar "gctx") PWild) (EVar "KType"))
(DTypeSig true "anyKRow" (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Bool")))
(DFunDef false "anyKRow" ((PList)) (EVar "False"))
(DFunDef false "anyKRow" ((PCons (PCon "KRow") PWild)) (EVar "True"))
(DFunDef false "anyKRow" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyKRow") (EVar "rest")))
(DTypeSig true "declGradedScope" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))))))
(DFunDef false "declGradedScope" ((PVar "gctx") (PList) PWild PWild) (EListLit))
(DFunDef false "declGradedScope" ((PVar "gctx") (PCons (PVar "p") (PVar "ps")) (PList) (PVar "methods")) (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EVar "gctx")) (EBinOp "::" (EVar "p") (EVar "ps"))) (EListLit (EVar "None"))) (EVar "methods")))
(DFunDef false "declGradedScope" ((PVar "gctx") (PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "anns")) (PVar "methods")) (EApp (EApp (EApp (EVar "declGradedScopeAdd") (EVar "p")) (EApp (EApp (EApp (EApp (EVar "ifaceParamKindsDecl") (EVar "gctx")) (EVar "a")) (EVar "p")) (EVar "methods"))) (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EVar "gctx")) (EVar "ps")) (EVar "anns")) (EVar "methods"))))
(DTypeSig false "ifaceParamKindsDecl" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "Option") (TyCon "KindAnn")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "Kind")))))))
(DFunDef false "ifaceParamKindsDecl" ((PVar "gctx") (PCon "Some" (PCon "KindArrow" (PVar "a") (PVar "b"))) PWild PWild) (EApp (EApp (EVar "kindAnnSlots") (EVar "gctx")) (EApp (EApp (EVar "KindArrow") (EVar "a")) (EVar "b"))))
(DFunDef false "ifaceParamKindsDecl" ((PVar "gctx") PWild (PVar "p") (PVar "methods")) (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "KType"))) (EApp (EApp (EVar "ifaceParamKindsOf") (EVar "p")) (EVar "methods"))))
(DTypeSig false "declGradedScopeAdd" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "declGradedScopeAdd" ((PVar "p") (PVar "kinds") (PVar "rest")) (EIf (EApp (EVar "anyKRow") (EVar "kinds")) (EBinOp "::" (ETuple (EVar "p") (EVar "kinds")) (EVar "rest")) (EIf (EVar "otherwise") (EVar "rest") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ifaceParamKindsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "Kind")))))
(DFunDef false "ifaceParamKindsOf" ((PVar "p") (PVar "methods")) (EMatch (EApp (EApp (EDictApp "flatMap") (EApp (EVar "ifaceMethodVarApps") (EVar "p"))) (EVar "methods")) (arm (PList) () (EListLit)) (arm (PAs "apps" (PCons (PTuple (PVar "args0") PWild) PWild)) () (EApp (EApp (EApp (EVar "ifaceSlotKinds") (EApp (EVar "listLen") (EVar "args0"))) (ELit (LInt 0))) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EBinOp "==" (EApp (EVar "listLen") (EApp (EVar "fst") (EVar "a"))) (EApp (EVar "listLen") (EVar "args0"))))) (EVar "apps"))))))
(DTypeSig false "ifaceMethodVarApps" (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ifaceMethodVarApps" ((PVar "p") (PCon "IfaceMethod" PWild (PVar "mty") PWild PWild)) (EBlock (DoLet false false (PVar "tails") (EApp (EVar "dedup") (EApp (EVar "effTailNames") (EVar "mty")))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "args")) (ETuple (EVar "args") (EVar "tails")))) (EApp (EApp (EVar "varHeadApps") (EVar "p")) (EVar "mty"))))))
(DTypeSig false "ifaceSlotKinds" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "Kind"))))))
(DFunDef false "ifaceSlotKinds" ((PVar "arity") (PVar "i") (PVar "apps")) (EIf (EBinOp ">=" (EVar "i") (EVar "arity")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EIf (EApp (EApp (EVar "anySlotIsRow") (EVar "i")) (EVar "apps")) (EVar "KRow") (EVar "KType")) (EApp (EApp (EApp (EVar "ifaceSlotKinds") (EVar "arity")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "apps"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "anySlotIsRow" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Bool"))))
(DFunDef false "anySlotIsRow" (PWild (PList)) (EVar "False"))
(DFunDef false "anySlotIsRow" ((PVar "i") (PCons (PTuple (PVar "args") (PVar "tails")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "nthTy") (EVar "i")) (EVar "args")) (arm (PCon "Some" (PCon "TyVar" (PVar "n"))) () (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "n")) (EVar "tails")) (EApp (EApp (EVar "anySlotIsRow") (EVar "i")) (EVar "rest")))) (arm PWild () (EApp (EApp (EVar "anySlotIsRow") (EVar "i")) (EVar "rest")))))
(DTypeSig false "varHeadApps" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Ty"))))))
(DFunDef false "varHeadApps" ((PVar "p") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "sp") (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b")))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EVar "varHeadHere") (EVar "p")) (EApp (EVar "fst") (EVar "sp"))) (EApp (EVar "snd") (EVar "sp"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "varHeadApps") (EVar "p"))) (EApp (EVar "snd") (EVar "sp")))))))
(DFunDef false "varHeadApps" ((PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "varHeadApps") (EVar "p")) (EVar "a")) (EApp (EApp (EVar "varHeadApps") (EVar "p")) (EVar "b"))))
(DFunDef false "varHeadApps" ((PVar "p") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "varHeadApps") (EVar "p"))) (EVar "ts")))
(DFunDef false "varHeadApps" ((PVar "p") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "varHeadApps") (EVar "p")) (EVar "t")))
(DFunDef false "varHeadApps" ((PVar "p") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "varHeadApps") (EVar "p")) (EVar "t")))
(DFunDef false "varHeadApps" (PWild PWild) (EListLit))
(DTypeSig false "varHeadHere" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Ty")))))))
(DFunDef false "varHeadHere" ((PVar "p") (PCon "TyVar" (PVar "h")) (PVar "args")) (EIf (EBinOp "==" (EVar "h") (EVar "p")) (EListLit (EVar "args")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "varHeadHere" (PWild PWild PWild) (EListLit))
(DTypeSig true "funClausePair" (TyFun (TyCon "FunClause") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "funClausePair" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "pats") (EVar "body")))
(DTypeSig true "funDefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "funDefs" ((PList)) (EListLit))
(DFunDef false "funDefs" ((PCons (PCon "DFunDef" PWild (PVar "n") (PVar "pats") (PVar "body") PWild PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (ETuple (EVar "pats") (EVar "body"))) (EApp (EVar "funDefs") (EVar "rest"))))
(DFunDef false "funDefs" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "letGroupDefs") (EVar "binds")) (EApp (EVar "funDefs") (EVar "rest"))))
(DFunDef false "funDefs" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "funDefs") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "funDefs" ((PCons PWild (PVar "rest"))) (EApp (EVar "funDefs") (EVar "rest")))
(DTypeSig false "letGroupDefs" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "letGroupDefs" ((PList)) (EListLit))
(DFunDef false "letGroupDefs" ((PCons (PCon "LetBind" (PVar "n") (PVar "clauses") PWild PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "tcClauseDef") (EVar "n"))) (EVar "clauses")) (EApp (EVar "letGroupDefs") (EVar "rest"))))
(DTypeSig false "tcClauseDef" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "tcClauseDef" ((PVar "n") (PVar "c")) (ETuple (EVar "n") (EApp (EVar "funClausePair") (EVar "c"))))
(DTypeSig true "methodArgs" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "methodArgs" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodArgs") (EVar "t")))
(DFunDef false "methodArgs" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodArgs") (EVar "t")))
(DFunDef false "methodArgs" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "methodArgs") (EVar "b"))))
(DFunDef false "methodArgs" (PWild) (EListLit))
(DTypeSig true "anyArgMentions" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "anyArgMentions" (PWild (PList)) (EVar "False"))
(DFunDef false "anyArgMentions" ((PVar "typarams") (PCons (PVar "ty") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "argMentions") (EVar "typarams")) (EVar "ty")) (EApp (EApp (EVar "anyArgMentions") (EVar "typarams")) (EVar "rest"))))
(DTypeSig true "constraintSlotDispatchVar" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "constraintSlotDispatchVar" ((PVar "typarams") (PRec "Constraint" ((rf "constraintArgs" (PVar "args"))) false)) (EBlock (DoLet false false (PVar "vars") (EApp (EApp (EDictApp "flatMap") (EVar "tyVarNames")) (EVar "args"))) (DoExpr (EMatch (EApp (EApp (EVar "removeAllS") (EVar "typarams")) (EVar "vars")) (arm (PCons (PVar "n") PWild) () (EListLit (EVar "n"))) (arm (PList) () (EMatch (EVar "vars") (arm (PCons (PVar "n") PWild) () (EListLit (EVar "n"))) (arm (PList) () (EListLit))))))))
(DTypeSig false "headTabIs" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyCon "TabKey") (TyCon "Bool"))))
(DFunDef false "headTabIs" ((PCon "Some" (PVar "hk")) (PVar "goal")) (EBinOp "==" (EApp (EVar "dispHeadTab") (EVar "hk")) (EVar "goal")))
(DFunDef false "headTabIs" ((PCon "None") PWild) (EVar "False"))
(DTypeSig false "headTabEq" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyApp (TyCon "Option") (TyCon "TabKey")) (TyCon "Bool"))))
(DFunDef false "headTabEq" ((PVar "hd") (PCon "Some" (PVar "goal"))) (EApp (EApp (EVar "headTabIs") (EVar "hd")) (EVar "goal")))
(DFunDef false "headTabEq" ((PCon "None") (PCon "None")) (EVar "True"))
(DFunDef false "headTabEq" ((PCon "Some" PWild) (PCon "None")) (EVar "False"))
(DTypeSig false "headTabOf" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyApp (TyCon "Option") (TyCon "TabKey"))))
(DFunDef false "headTabOf" ((PCon "None")) (EVar "None"))
(DFunDef false "headTabOf" ((PCon "Some" (PVar "hk"))) (EApp (EVar "Some") (EApp (EVar "dispHeadTab") (EVar "hk"))))
(DTypeSig true "ieImplExistsForHeadOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyCon "HeadKey") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))) (TyCon "Bool")))))))
(DFunDef false "ieImplExistsForHeadOf" ((PVar "mctx") (PVar "env") (PVar "name") (PVar "hk") (PVar "admitted")) (EApp (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHeadGo") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "ieHeadRows") (EApp (EVar "Some") (EVar "hk"))) (EVar "env"))) (EApp (EApp (EVar "originMethodName") (EVar "mctx")) (EVar "name"))) (EApp (EVar "dispHeadTab") (EVar "hk"))) (EVar "admitted")))
(DTypeSig false "ieImplExistsForHeadGo" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "String") (TyFun (TyCon "TabKey") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))) (TyCon "Bool")))))))
(DFunDef false "ieImplExistsForHeadGo" ((PVar "gctx") (PList) PWild PWild PWild) (EVar "False"))
(DFunDef false "ieImplExistsForHeadGo" ((PVar "gctx") (PCons (PAs "r" (PCon "ImplRow" PWild PWild (PVar "ir") (PVar "tys") PWild (PVar "ms") PWild)) (PVar "rest")) (PVar "name") (PVar "goal") (PVar "admitted")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "headTabIs") (EApp (EVar "univReceiverTag") (EVar "tys"))) (EVar "goal")) (EApp (EApp (EVar "ieRowAdmittedBy") (EVar "ir")) (EVar "admitted"))) (EApp (EApp (EApp (EApp (EApp (EVar "ieRowAnswersMethod") (EVar "gctx")) (EVar "r")) (EVar "ms")) (EVar "name")) (EVar "admitted"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHeadGo") (EVar "gctx")) (EVar "rest")) (EVar "name")) (EVar "goal")) (EVar "admitted")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ieRowAdmittedBy" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))) (TyCon "Bool"))))
(DFunDef false "ieRowAdmittedBy" (PWild (PCon "None")) (EVar "True"))
(DFunDef false "ieRowAdmittedBy" ((PVar "ir") (PCon "Some" (PVar "ifaces"))) (EApp (EApp (EVar "anyList") (EApp (EVar "ieRowIfaceMatches") (EVar "ir"))) (EVar "ifaces")))
(DTypeSig true "ieDefinesReqMethodAt" (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyCon "Bool")))))
(DFunDef false "ieDefinesReqMethodAt" ((PVar "env") (PVar "method") (PVar "hd")) (EApp (EApp (EApp (EVar "ieDefinesReqMethodAtGo") (EApp (EApp (EVar "ieHeadRows") (EVar "hd")) (EVar "env"))) (EVar "method")) (EApp (EVar "headTabOf") (EVar "hd"))))
(DTypeSig false "ieDefinesReqMethodAtGo" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "TabKey")) (TyCon "Bool")))))
(DFunDef false "ieDefinesReqMethodAtGo" ((PList) PWild PWild) (EVar "False"))
(DFunDef false "ieDefinesReqMethodAtGo" ((PCons (PCon "ImplRow" PWild PWild PWild (PVar "tys") (PVar "reqs") (PVar "ms") PWild) (PVar "rest")) (PVar "method") (PVar "goal")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "implRowHasReqs") (EVar "reqs")) (EApp (EApp (EVar "headTabEq") (EApp (EVar "univReceiverTag") (EVar "tys"))) (EVar "goal"))) (EApp (EApp (EVar "contains") (EVar "method")) (EVar "ms"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "ieDefinesReqMethodAtGo") (EVar "rest")) (EVar "method")) (EVar "goal")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implRowHasReqs" (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyCon "Bool")))
(DFunDef false "implRowHasReqs" ((PList)) (EVar "False"))
(DFunDef false "implRowHasReqs" (PWild) (EVar "True"))
(DTypeSig false "requiredMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "requiredMethodNames" ((PList)) (EListLit))
(DFunDef false "requiredMethodNames" ((PCons (PCon "IfaceMethod" (PVar "n") PWild (PCon "None") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "requiredMethodNames") (EVar "rest"))))
(DFunDef false "requiredMethodNames" ((PCons (PCon "IfaceMethod" PWild PWild (PCon "Some" PWild) PWild) (PVar "rest"))) (EApp (EVar "requiredMethodNames") (EVar "rest")))
(DTypeSig true "recordCandInfo" (TyFun (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "RecordInfo")) (TyCon "RecordInfo")))
(DFunDef false "recordCandInfo" ((PTuple PWild PWild (PVar "ri"))) (EVar "ri"))
(DTypeSig true "ceRowIfaceName" (TyFun (TyCon "CeRow") (TyCon "String")))
(DFunDef false "ceRowIfaceName" ((PVar "r")) (EMatch (EApp (EVar "ceRowIface") (EVar "r")) (arm (PRec "IfaceRef" ((rf "irName" (PVar "n"))) true) () (EVar "n"))))
(DTypeSig true "ceRowDoneKey" (TyFun (TyCon "CeRow") (TyCon "String")))
(DFunDef false "ceRowDoneKey" ((PVar "r")) (EApp (EVar "regKeyRender") (EApp (EVar "ceRowKey") (EVar "r"))))
(DTypeSig false "implMethodNameTc" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodNameTc" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "keyEntryIdx" (TyFun (TyCon "KeyEntry") (TyCon "Int")))
(DFunDef false "keyEntryIdx" ((PCon "KeyEntry" PWild PWild PWild PWild PWild PWild PWild (PVar "i"))) (EVar "i"))
(DTypeSig false "headBucketKey" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyCon "RegKey")))
(DFunDef false "headBucketKey" ((PCon "None")) (EVar "headlessBucketKey"))
(DFunDef false "headBucketKey" ((PCon "Some" (PVar "hk"))) (EApp (EVar "regKeyOfTab") (EApp (EVar "dispHeadTab") (EVar "hk"))))
(DTypeSig false "headlessBucketKey" (TyCon "RegKey"))
(DFunDef false "headlessBucketKey" () (EApp (EVar "regKeyNTab") (EListLit)))
(DTypeSig false "implKeyTc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "String"))))
(DFunDef false "implKeyTc" ((PVar "iface") (PVar "tys")) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "OriginUnresolved")) (EVar "iface")) (EVar "tys")) (EVar "None")))
(DTypeSig false "mergeByDeclIdx" (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyApp (TyCon "List") (TyCon "KeyEntry")))))
(DFunDef false "mergeByDeclIdx" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "mergeByDeclIdx" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "mergeByDeclIdx" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EApp (EVar "keyEntryIdx") (EVar "x")) (EApp (EVar "keyEntryIdx") (EVar "y"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "mergeByDeclIdx") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "mergeByDeclIdx") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "keyEntryOfRow" (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "KeyEntry"))))
(DFunDef false "keyEntryOfRow" ((PCon "ImplRow" PWild (PVar "inst") (PVar "ir") (PVar "tys") (PVar "reqs") (PVar "ms") PWild)) (EMatch (EVar "tys") (arm (PCons (PVar "headTy") PWild) () (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "KeyEntry") (EVar "ms")) (EApp (EVar "headTyconTy") (EVar "headTy"))) (EVar "headTy")) (EApp (EApp (EVar "implKeyTc") (EFieldAccess (EVar "ir") "irName")) (EVar "tys"))) (EFieldAccess (EVar "ir") "irName")) (EVar "tys")) (EVar "reqs")) (EApp (EVar "instRefSeq") (EVar "inst"))))) (arm (PList) () (EListLit))))
(DTypeSig false "ieRowHeadMatches" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Bool"))))
(DFunDef false "ieRowHeadMatches" ((PAs "tys" (PCons (PVar "headTy") PWild)) (PVar "goals")) (EApp (EApp (EApp (EVar "entryHeadMatches") (EVar "headTy")) (EVar "tys")) (EVar "goals")))
(DFunDef false "ieRowHeadMatches" ((PList) PWild) (EVar "False"))
(DTypeSig true "ieRowIfaceMatches" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "ieRowIfaceMatches" ((PVar "ir") (PVar "iface")) (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EFieldAccess (EVar "ir") "irName")) (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "iface") "irName")) (EFieldAccess (EVar "iface") "irOrigin")))
(DTypeSig true "ieEntriesForIface" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "KeyEntry"))))))
(DFunDef false "ieEntriesForIface" ((PList) PWild PWild) (EListLit))
(DFunDef false "ieEntriesForIface" ((PCons (PAs "r" (PCon "ImplRow" PWild PWild (PVar "ir") (PVar "tys") PWild PWild PWild)) (PVar "rest")) (PVar "iface") (PVar "goals")) (EIf (EBinOp "&&" (EApp (EApp (EVar "ieRowIfaceMatches") (EVar "ir")) (EVar "iface")) (EApp (EApp (EVar "ieRowHeadMatches") (EVar "tys")) (EVar "goals"))) (EBinOp "++" (EApp (EVar "keyEntryOfRow") (EVar "r")) (EApp (EApp (EApp (EVar "ieEntriesForIface") (EVar "rest")) (EVar "iface")) (EVar "goals"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "ieEntriesForIface") (EVar "rest")) (EVar "iface")) (EVar "goals")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ieEntriesForMethod" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "KeyEntry"))))))))
(DFunDef false "ieEntriesForMethod" ((PVar "gctx") (PList) PWild PWild PWild) (EListLit))
(DFunDef false "ieEntriesForMethod" ((PVar "gctx") (PCons (PAs "r" (PCon "ImplRow" PWild PWild (PVar "ir") (PVar "tys") PWild (PVar "ms") PWild)) (PVar "rest")) (PVar "name") (PVar "admitted") (PVar "goals")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "ieRowAdmittedBy") (EVar "ir")) (EVar "admitted")) (EApp (EApp (EVar "ieRowHeadMatches") (EVar "tys")) (EVar "goals"))) (EApp (EApp (EApp (EApp (EApp (EVar "ieRowAnswersMethod") (EVar "gctx")) (EVar "r")) (EVar "ms")) (EVar "name")) (EVar "admitted"))) (EBinOp "++" (EApp (EVar "keyEntryOfRow") (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "ieEntriesForMethod") (EVar "gctx")) (EVar "rest")) (EVar "name")) (EVar "admitted")) (EVar "goals"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "ieEntriesForMethod") (EVar "gctx")) (EVar "rest")) (EVar "name")) (EVar "admitted")) (EVar "goals")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ieRowAnswersMethod" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ImplRow") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))) (TyCon "Bool")))))))
(DFunDef false "ieRowAnswersMethod" ((PVar "gctx") PWild (PVar "ms") (PVar "name") (PCon "None")) (EApp (EApp (EVar "contains") (EVar "name")) (EVar "ms")))
(DFunDef false "ieRowAnswersMethod" ((PVar "gctx") (PVar "r") (PVar "ms") (PVar "name") (PCon "Some" PWild)) (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "name")) (EVar "ms")) (EApp (EApp (EApp (EVar "ieRowInheritsDefault") (EVar "gctx")) (EVar "r")) (EVar "name"))))
(DTypeSig false "ieRowInheritsDefault" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ImplRow") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "ieRowInheritsDefault" ((PVar "gctx") (PVar "r") (PVar "name")) (EBlock (DoLet false false (PTuple (PVar "iface") PWild PWild) (EApp (EVar "ieRowTriple") (EVar "r"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")))) (EApp (EVar "ieRowOrd") (EVar "r"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deIfaces")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "ceRow")) () (EBinOp "&&" (EApp (EApp (EVar "contains") (EVar "name")) (EApp (EVar "ceRowMethodNames") (EVar "ceRow"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "name")) (EApp (EVar "ceRowRequired") (EVar "ceRow"))))))))))
(DTypeSig true "ieCandidatesForIface" (TyFun (TyCon "ImplEnv") (TyFun (TyCon "HeadKey") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "KeyEntry")))))))
(DFunDef false "ieCandidatesForIface" ((PVar "env") (PVar "hk") (PVar "iface") (PVar "goals")) (EApp (EApp (EVar "mergeByDeclIdx") (EApp (EApp (EApp (EVar "ieEntriesForIface") (EApp (EApp (EVar "ieHeadRows") (EApp (EVar "Some") (EVar "hk"))) (EVar "env"))) (EVar "iface")) (EVar "goals"))) (EApp (EApp (EApp (EVar "ieEntriesForIface") (EApp (EApp (EVar "ieHeadRows") (EVar "None")) (EVar "env"))) (EVar "iface")) (EVar "goals"))))
(DTypeSig true "ieCandidatesForMethod" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "KeyEntry")))))))))
(DFunDef false "ieCandidatesForMethod" ((PVar "gctx") (PVar "env") (PVar "hk") (PVar "name") (PVar "admitted") (PVar "goals")) (EApp (EApp (EVar "mergeByDeclIdx") (EApp (EApp (EApp (EApp (EApp (EVar "ieEntriesForMethod") (EVar "gctx")) (EApp (EApp (EVar "ieHeadRows") (EApp (EVar "Some") (EVar "hk"))) (EVar "env"))) (EVar "name")) (EVar "admitted")) (EVar "goals"))) (EApp (EApp (EApp (EApp (EApp (EVar "ieEntriesForMethod") (EVar "gctx")) (EApp (EApp (EVar "ieHeadRows") (EVar "None")) (EVar "env"))) (EVar "name")) (EVar "admitted")) (EVar "goals"))))
(DTypeSig true "ieRowOfEntry" (TyFun (TyCon "ImplEnv") (TyFun (TyApp (TyCon "Option") (TyCon "KeyEntry")) (TyApp (TyCon "Option") (TyCon "ImplRow")))))
(DFunDef false "ieRowOfEntry" (PWild (PCon "None")) (EVar "None"))
(DFunDef false "ieRowOfEntry" ((PVar "env") (PCon "Some" (PCon "KeyEntry" PWild (PVar "hd") PWild PWild PWild PWild PWild (PVar "idx")))) (EApp (EApp (EVar "ieRowWithSeq") (EApp (EApp (EVar "ieHeadRows") (EVar "hd")) (EVar "env"))) (EVar "idx")))
(DTypeSig false "ieRowWithSeq" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "ImplRow")))))
(DFunDef false "ieRowWithSeq" ((PList) PWild) (EVar "None"))
(DFunDef false "ieRowWithSeq" ((PCons (PAs "r" (PCon "ImplRow" PWild (PVar "inst") PWild PWild PWild PWild PWild)) (PVar "rest")) (PVar "s")) (EIf (EBinOp "==" (EApp (EVar "instRefSeq") (EVar "inst")) (EVar "s")) (EApp (EVar "Some") (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EVar "ieRowWithSeq") (EVar "rest")) (EVar "s")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ieRowHeadTriple" (TyFun (TyApp (TyCon "Option") (TyCon "ImplRow")) (TyApp (TyCon "Option") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))))))
(DFunDef false "ieRowHeadTriple" ((PCon "None")) (EVar "None"))
(DFunDef false "ieRowHeadTriple" ((PCon "Some" (PCon "ImplRow" PWild PWild PWild (PAs "tys" (PCons (PVar "headTy") PWild)) (PVar "reqs") PWild PWild))) (EApp (EVar "Some") (ETuple (EVar "headTy") (EVar "tys") (EVar "reqs"))))
(DFunDef false "ieRowHeadTriple" ((PCon "Some" PWild)) (EVar "None"))
(DTypeSig false "growImplUniverse" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require")))) (TyFun (TyCon "ImplUniverse") (TyCon "ImplUniverse"))))
(DFunDef false "growImplUniverse" ((PList) (PVar "univ")) (EVar "univ"))
(DFunDef false "growImplUniverse" ((PCons (PVar "t") (PVar "rest")) (PVar "univ")) (EApp (EApp (EVar "growImplUniverse") (EVar "rest")) (EApp (EApp (EVar "insertUnivImpl") (EVar "univ")) (EVar "t"))))
(DTypeSig false "insertUnivImpl" (TyFun (TyCon "ImplUniverse") (TyFun (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))) (TyCon "ImplUniverse"))))
(DFunDef false "insertUnivImpl" ((PVar "univ") (PTuple (PVar "iface") (PVar "tys") (PVar "reqs"))) (EApp (EApp (EApp (EApp (EVar "insertUnivImplKeys") (EApp (EVar "oblIfaceKeys") (EVar "iface"))) (EVar "tys")) (EVar "reqs")) (EVar "univ")))
(DTypeSig false "insertUnivImplKeys" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyCon "ImplUniverse") (TyCon "ImplUniverse"))))))
(DFunDef false "insertUnivImplKeys" ((PList) PWild PWild (PVar "univ")) (EVar "univ"))
(DFunDef false "insertUnivImplKeys" ((PCons (PVar "ifk") (PVar "rest")) (PVar "tys") (PVar "reqs") (PVar "univ")) (EApp (EApp (EApp (EApp (EVar "insertUnivImplKeys") (EVar "rest")) (EVar "tys")) (EVar "reqs")) (EApp (EApp (EApp (EApp (EVar "insertUnivImplAt") (EVar "ifk")) (EVar "tys")) (EVar "reqs")) (EVar "univ"))))
(DTypeSig false "oblIfaceKeys" (TyFun (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "TabKey"))))
(DFunDef false "oblIfaceKeys" ((PVar "ir")) (EMatch (EFieldAccess (EVar "ir") "irOrigin") (arm (PCon "OriginUnresolved") () (EListLit (EApp (EApp (EVar "TkBare") (EVar "NsIface")) (EFieldAccess (EVar "ir") "irName")))) (arm PWild () (EListLit (EApp (EVar "oblIfaceKey") (EVar "ir")) (EApp (EApp (EVar "TkBare") (EVar "NsIface")) (EFieldAccess (EVar "ir") "irName"))))))
(DTypeSig false "insertUnivImplAt" (TyFun (TyCon "TabKey") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyCon "ImplUniverse") (TyCon "ImplUniverse"))))))
(DFunDef false "insertUnivImplAt" ((PVar "ifk") (PVar "tys") (PVar "reqs") (PCon "ImplUniverse" (PVar "conc") (PVar "hl"))) (EMatch (EApp (EVar "univReceiverTag") (EVar "tys")) (arm (PCon "Some" (PVar "hk")) () (EApp (EApp (EVar "ImplUniverse") (EApp (EApp (EApp (EVar "mregAppendK") (EApp (EVar "regKeyNTab") (EListLit (EVar "ifk") (EApp (EVar "dispHeadTab") (EVar "hk"))))) (ETuple (EVar "tys") (EVar "reqs"))) (EVar "conc"))) (EVar "hl"))) (arm (PCon "None") () (EApp (EApp (EVar "ImplUniverse") (EVar "conc")) (EApp (EApp (EApp (EVar "mregAppendK") (EApp (EVar "regKeyOfTab") (EVar "ifk"))) (ETuple (EVar "tys") (EVar "reqs"))) (EVar "hl"))))))
(DTypeSig true "oblIfaceKey" (TyFun (TyCon "IfaceRef") (TyCon "TabKey")))
(DFunDef false "oblIfaceKey" ((PVar "ir")) (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsIface")) (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "ir") "irName")))
(DTypeSig true "dispHeadTab" (TyFun (TyCon "HeadKey") (TyCon "TabKey")))
(DFunDef false "dispHeadTab" ((PVar "hk")) (EApp (EApp (EVar "TkBare") (EVar "NsType")) (EApp (EVar "headKeyTag") (EVar "hk"))))
(DTypeSig false "univReceiverTag" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "HeadKey"))))
(DFunDef false "univReceiverTag" ((PCons (PVar "headTy") PWild)) (EApp (EVar "headTyconTy") (EVar "headTy")))
(DFunDef false "univReceiverTag" ((PList)) (EVar "None"))
(DTypeSig true "ieRowOfIface" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "ImplRow") (TyCon "Bool"))))
(DFunDef false "ieRowOfIface" ((PVar "iface") (PCon "ImplRow" PWild PWild (PVar "ir") PWild PWild PWild PWild)) (EApp (EApp (EVar "ieRowIfaceMatches") (EVar "ir")) (EVar "iface")))
(DTypeSig true "ieRowTys" (TyFun (TyCon "ImplRow") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "ieRowTys" ((PCon "ImplRow" PWild PWild PWild (PVar "tys") PWild PWild PWild)) (EVar "tys"))
(DTypeSig true "methodLevelConstraintVarNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodLevelConstraintVarNames" ((PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "constraintSlotDispatchVar") (EVar "typarams"))) (EVar "cs")) (EApp (EApp (EVar "methodLevelConstraintVarNames") (EVar "typarams")) (EVar "t"))))
(DFunDef false "methodLevelConstraintVarNames" ((PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "methodLevelConstraintVarNames") (EVar "typarams")) (EVar "t")))
(DFunDef false "methodLevelConstraintVarNames" (PWild PWild) (EListLit))
(DTypeSig true "removeAllS" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "removeAllS" ((PVar "drop") (PVar "xs")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "x")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "x")) (EVar "drop"))))) (EVar "xs")))
(DTypeSig true "ceMethodTyAt" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))))))))
(DFunDef false "ceMethodTyAt" ((PVar "iface") (PVar "mname") (PVar "cur") (PVar "ce")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EVar "key")) (EVar "cur")) (EVar "ce")) (arm (PCon "Some" (PVar "row")) () (EApp (EApp (EApp (EVar "ceMethodTyIn") (EApp (EVar "ceRowTyparams") (EVar "row"))) (EVar "mname")) (EApp (EVar "ceRowMethods") (EVar "row")))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "ceMethodTyIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))))
(DFunDef false "ceMethodTyIn" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "ceMethodTyIn" ((PVar "typarams") (PVar "mname") (PCons (PTuple (PVar "name") (PVar "mty") (PVar "scope")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "name") (EVar "mname")) (EApp (EVar "Some") (ETuple (EVar "typarams") (EVar "mty") (EVar "scope"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "ceMethodTyIn") (EVar "typarams")) (EVar "mname")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "sameIfaceDecl" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "sameIfaceDecl" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "tabKeyEq") (EApp (EVar "oblIfaceKey") (EVar "a"))) (EApp (EVar "oblIfaceKey") (EVar "b"))))
(DTypeSig true "legacyMethodSchemes" (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))
(DFunDef false "legacyMethodSchemes" ((PList)) (EListLit))
(DFunDef false "legacyMethodSchemes" ((PCons (PVar "row") (PVar "rest"))) (EBinOp "::" (ETuple (EFieldAccess (EVar "row") "msrName") (EFieldAccess (EVar "row") "msrScheme")) (EApp (EVar "legacyMethodSchemes") (EVar "rest"))))
(DTypeSig true "methodSlotKey" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "methodSlotKey" ((PVar "iface") (PVar "method")) (EApp (EVar "regKeyRender") (EApp (EApp (EVar "methodRowKey") (EVar "iface")) (EVar "method"))))
(DTypeSig true "envFor" (TyFun (TyCon "ModuleCtx") (TyCon "TcEnv")))
(DFunDef false "envFor" ((PVar "mctx")) (EApp (EApp (EVar "withCtors") (EVar "mctx")) (EVar "builtinCtors")))
(DTypeSig true "namesToSet" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "namesToSet" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "namesToSet" ((PCons (PVar "n") (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "namesToSet") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "m"))))
(DTypeSig true "ieHeadCandidateExists" (TyFun (TyCon "ImplEnv") (TyFun (TyCon "IfaceRef") (TyFun (TyCon "HeadKey") (TyCon "Bool")))))
(DFunDef false "ieHeadCandidateExists" ((PVar "env") (PVar "iface") (PVar "hk")) (EBinOp "||" (EApp (EApp (EVar "ieAnyRowForIface") (EApp (EApp (EVar "ieHeadRows") (EApp (EVar "Some") (EVar "hk"))) (EVar "env"))) (EVar "iface")) (EApp (EApp (EVar "ieAnyRowForIface") (EApp (EApp (EVar "ieHeadRows") (EVar "None")) (EVar "env"))) (EVar "iface"))))
(DTypeSig false "ieAnyRowForIface" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))
(DFunDef false "ieAnyRowForIface" ((PList) PWild) (EVar "False"))
(DFunDef false "ieAnyRowForIface" ((PCons (PCon "ImplRow" PWild PWild (PVar "ir") PWild PWild PWild PWild) (PVar "rest")) (PVar "iface")) (EBinOp "||" (EApp (EApp (EVar "ieRowIfaceMatches") (EVar "ir")) (EVar "iface")) (EApp (EApp (EVar "ieAnyRowForIface") (EVar "rest")) (EVar "iface"))))
(DTypeSig true "ifaceMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ifaceMethodNames" ((PList)) (EListLit))
(DFunDef false "ifaceMethodNames" ((PCons (PCon "IfaceMethod" (PVar "n") PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "ifaceMethodNames") (EVar "rest"))))
(DTypeSig true "publicDataDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "publicDataDecl" ((PRec "DData" ((rf "dataVis" (PCon "VisPublic"))) false)) (EVar "True"))
(DFunDef false "publicDataDecl" ((PRec "DInterface" ((rf "pub" (PCon "True"))) true)) (EVar "True"))
(DFunDef false "publicDataDecl" ((PRec "DImpl" ((rf "pub" (PCon "True"))) true)) (EVar "True"))
(DFunDef false "publicDataDecl" ((PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True"))) false)) (EVar "True"))
(DFunDef false "publicDataDecl" (PWild) (EVar "False"))
(DTypeSig true "publicDataDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "publicDataDecls" ((PVar "decls")) (EApp (EApp (EVar "filterList") (EVar "publicDataDecl")) (EVar "decls")))
(DTypeSig true "kindPublicDataDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "kindPublicDataDecl" ((PRec "DData" ((rf "dataVis" (PCon "VisPublic"))) false)) (EVar "True"))
(DFunDef false "kindPublicDataDecl" ((PRec "DData" ((rf "dataVis" (PCon "VisAbstract"))) false)) (EVar "True"))
(DFunDef false "kindPublicDataDecl" ((PRec "DNewtype" ((rf "newtypePub" (PCon "True"))) false)) (EVar "True"))
(DFunDef false "kindPublicDataDecl" ((PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True"))) false)) (EVar "True"))
(DFunDef false "kindPublicDataDecl" (PWild) (EVar "False"))
(DTypeSig true "ordinaryEnvBinding" (TyFun (TyCon "Scheme") (TyCon "EnvBinding")))
(DFunDef false "ordinaryEnvBinding" ((PVar "scheme")) (ERecordCreate "EnvBinding" ((fa "ebValue" (EApp (EVar "ordinaryValueScheme") (EVar "scheme"))) (fa "ebMethodRow" (EVar "None")) (fa "ebStandalone" (EVar "None")))))
(DTypeSig false "ordinaryValueScheme" (TyFun (TyCon "Scheme") (TyCon "ValueScheme")))
(DFunDef false "ordinaryValueScheme" ((PVar "scheme")) (ERecordCreate "ValueScheme" ((fa "vsScheme" (EVar "scheme")) (fa "vsDeclared" (EVar "None")))))
(DTypeSig true "methodEnvBinding" (TyFun (TyCon "MethodSchemeRow") (TyCon "EnvBinding")))
(DFunDef false "methodEnvBinding" ((PVar "row")) (ERecordCreate "EnvBinding" ((fa "ebValue" (EApp (EVar "ordinaryValueScheme") (EFieldAccess (EVar "row") "msrScheme"))) (fa "ebMethodRow" (EApp (EVar "Some") (EVar "row"))) (fa "ebStandalone" (EVar "None")))))
(DTypeSig true "lookupMethodRowById" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyApp (TyCon "Option") (TyCon "MethodSchemeRow"))))))
(DFunDef false "lookupMethodRowById" ((PVar "iface") (PVar "n") (PVar "rows")) (EMatch (EApp (EApp (EVar "regLookupK") (EApp (EApp (EVar "methodRowKey") (EVar "iface")) (EVar "n"))) (EVar "rows")) (arm (PCon "Some" (PVar "row")) () (EIf (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irName")) (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")) (EFieldAccess (EVar "iface") "irOrigin")) (EApp (EVar "Some") (EVar "row")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "lookupSchemeById" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyApp (TyCon "Option") (TyCon "Scheme"))))))
(DFunDef false "lookupSchemeById" ((PVar "iface") (PVar "n") (PVar "rows")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (EFieldAccess (EVar "row") "msrScheme"))) (EApp (EApp (EApp (EVar "lookupMethodRowById") (EVar "iface")) (EVar "n")) (EVar "rows"))))
(DTypeSig false "methodRowKey" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyCon "RegKey"))))
(DFunDef false "methodRowKey" ((PVar "iface") (PVar "method")) (EApp (EVar "regKeyNTab") (EListLit (EApp (EApp (EVar "ifaceTabKey") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName")) (EApp (EApp (EVar "TkBare") (EVar "NsMethod")) (EVar "method")))))
(DTypeSig true "methodRowsByIdentity" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow"))))))
(DFunDef false "methodRowsByIdentity" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "methodRowsByIdentity" ((PVar "includeAll") (PCons (PVar "row") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "includeAll")) (EApp (EVar "not") (EApp (EVar "methodRowCanCarry") (EVar "row")))) (EApp (EApp (EApp (EVar "methodRowsByIdentity") (EVar "includeAll")) (EVar "rest")) (EVar "acc")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "methodRowKey") (EFieldAccess (EVar "row") "msrIface")) (EFieldAccess (EVar "row") "msrName"))) (DoLet false false (PVar "acc2") (EMatch (EApp (EApp (EVar "regLookupK") (EVar "key")) (EVar "acc")) (arm (PCon "Some" PWild) () (EVar "acc")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "regInsertK") (EVar "key")) (EVar "row")) (EVar "acc"))))) (DoExpr (EApp (EApp (EApp (EVar "methodRowsByIdentity") (EVar "includeAll")) (EVar "rest")) (EVar "acc2"))))))
(DTypeSig true "importedBindings" (TyFun (TyCon "UsePath") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "importedBindings" ((PCon "UseGroup" PWild (PVar "ms"))) (EApp (EVar "Some") (EApp (EApp (EMethodRef "map") (EVar "memberBinding")) (EVar "ms"))))
(DFunDef false "importedBindings" ((PCon "UseWild" PWild)) (EVar "None"))
(DFunDef false "importedBindings" ((PCon "UseName" (PVar "ns"))) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EVar "Some") (EListLit (EApp (EVar "selfBinding") (EApp (EVar "lastComponent") (EVar "ns"))))) (EIf (EVar "otherwise") (EApp (EVar "Some") (EListLit)) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "importedBindings" ((PCon "UseAlias" PWild PWild)) (EApp (EVar "Some") (EListLit)))
(DTypeSig true "boundNames" (TyFun (TyCon "UsePath") (TyApp (TyCon "Option") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "boundNames" ((PVar "path")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "rows")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "rows"))) (EVar "omEmpty")))) (EApp (EVar "importedBindings") (EVar "path"))))
(DTypeSig false "memberBinding" (TyFun (TyCon "UseMember") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "memberBinding" ((PVar "m")) (ETuple (EApp (EVar "useMemberOrigin") (EVar "m")) (EApp (EVar "useMemberLocal") (EVar "m"))))
(DTypeSig true "importTableMid" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "importTableMid" ((PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (ELit (LString "")) (EVar "mid")))))
(DTypeSig false "declMethodIdents" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident")))))
(DFunDef false "declMethodIdents" ((PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EVar "declMethodIdentsOf")) (EVar "decls")))
(DTypeSig false "declMethodIdentsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident")))))
(DFunDef false "declMethodIdentsOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declMethodIdentsOf") (EVar "d")))
(DFunDef false "declMethodIdentsOf" ((PRec "DInterface" ((rf "methods" None) (rf "ifaceOrigin" None)) true)) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EApp (EApp (EVar "ifaceMethodIdentPair") (EVar "ifaceOrigin")) (EVar "m")))) (EVar "methods")))
(DFunDef false "declMethodIdentsOf" (PWild) (EListLit))
(DTypeSig false "ifaceMethodIdentPair" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "ifaceMethodIdentPair" ((PVar "origin") (PCon "IfaceMethod" (PVar "mname") PWild PWild PWild)) (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsMethod")) (EVar "origin")) (EVar "mname")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "i")) () (EListLit (ETuple (EVar "mname") (EVar "i"))))))
(DTypeSig false "reexportedMethodIdents" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "reexportedMethodIdents" ((PVar "acc") (PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "reexportedMethodIdentsOf") (EVar "acc"))) (EVar "decls")))
(DTypeSig false "reexportedMethodIdentsOf" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident")))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "reexportedMethodIdentsOf" ((PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "reexportedMethodIdentsOf") (EVar "acc")) (EVar "d")))
(DFunDef false "reexportedMethodIdentsOf" ((PVar "acc") (PCon "DUse" (PCon "True") (PVar "path") PWild)) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "acc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EVar "src")) (arm (PCon "Some" (PVar "bs")) () (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "b")) (EApp (EApp (EVar "reexportRenamed") (EVar "b")) (EVar "src")))) (EVar "bs")))))))
(DFunDef false "reexportedMethodIdentsOf" (PWild PWild) (EListLit))
(DTypeSig false "reexportRenamed" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "reexportRenamed" ((PTuple (PVar "origin") (PVar "local")) (PVar "src")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (EVar "local") (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "fst") (EVar "e")) (EVar "origin")))) (EVar "src"))))
(DTypeSig true "ifaceMethodRows" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ifaceMethodRows" ((PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceMethodRowOf")) (EVar "decls")))
(DTypeSig true "allIfaceMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allIfaceMethodNames" ((PList)) (EListLit))
(DFunDef false "allIfaceMethodNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "allIfaceMethodNames") (EListLit (EVar "d"))) (EApp (EVar "allIfaceMethodNames") (EVar "rest"))))
(DFunDef false "allIfaceMethodNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EVar "ifaceMethodNames") (EVar "methods")) (EApp (EVar "allIfaceMethodNames") (EVar "rest"))))
(DFunDef false "allIfaceMethodNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "allIfaceMethodNames") (EVar "rest")))
(DTypeSig false "ifaceMethodRowOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ifaceMethodRowOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ifaceMethodRowOf") (EVar "d")))
(DFunDef false "ifaceMethodRowOf" ((PRec "DInterface" ((rf "name" None) (rf "methods" None)) true)) (EListLit (ETuple (EVar "name") (EApp (EVar "ifaceMethodNames") (EVar "methods")))))
(DFunDef false "ifaceMethodRowOf" (PWild) (EListLit))
(DTypeSig false "reexportedIfaceMethods" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reexportedIfaceMethods" ((PVar "acc") (PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "reexportedIfaceMethodsOf") (EVar "acc"))) (EVar "decls")))
(DTypeSig false "reexportedIfaceMethodsOf" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reexportedIfaceMethodsOf" ((PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "reexportedIfaceMethodsOf") (EVar "acc")) (EVar "d")))
(DFunDef false "reexportedIfaceMethodsOf" ((PVar "acc") (PCon "DUse" (PCon "True") (PVar "path") PWild)) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "acc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "selectIfaceRows") (EVar "path")) (EVar "src")))))
(DFunDef false "reexportedIfaceMethodsOf" (PWild PWild) (EListLit))
(DTypeSig true "selectIfaceRows" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "selectIfaceRows" ((PCon "UseAlias" PWild PWild) (PVar "src")) (EVar "src"))
(DFunDef false "selectIfaceRows" ((PVar "path") (PVar "src")) (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EVar "src")) (arm (PCon "Some" (PVar "bs")) () (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "r")) (EApp (EApp (EVar "narrowRowToNamed") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "bs"))) (EVar "r")))) (EVar "src")))))
(DTypeSig false "narrowRowToNamed" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "narrowRowToNamed" ((PVar "named") (PVar "r")) (EIf (EApp (EApp (EVar "contains") (EApp (EVar "fst") (EVar "r"))) (EVar "named")) (EListLit (EVar "r")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "m")) (EApp (EApp (EVar "contains") (EVar "m")) (EVar "named")))) (EApp (EVar "snd") (EVar "r"))) (arm (PList) () (EListLit)) (arm (PVar "ms") () (EListLit (ETuple (EApp (EVar "fst") (EVar "r")) (EVar "ms"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ctorExportsIndex" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))))
(DFunDef false "ctorExportsIndex" ((PVar "gctx") PWild) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deData") "deCtorExports"))
(DTypeSig true "variantNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Bool"))))
(DFunDef false "variantNamed" (PWild (PList)) (EVar "False"))
(DFunDef false "variantNamed" ((PVar "n") (PCons (PCon "Variant" (PVar "cn") PWild) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "cn") (EVar "n")) (EApp (EApp (EVar "variantNamed") (EVar "n")) (EVar "rest"))))
(DTypeSig true "graphPubDefiners" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "graphPubDefiners" ((PVar "gctx") (PVar "mid")) (EApp (EApp (EVar "definersIn") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "declEnvsRef") "value") "deDefiners")) (EVar "mid")))
(DTypeSig true "definersIn" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "definersIn" ((PVar "tbl") (PVar "mid")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "tbl")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "rows")) () (EVar "rows"))))
(DTypeSig true "emptyMethodModulePredicateSlots" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))))
(DFunDef false "emptyMethodModulePredicateSlots" (PWild (PList)) (EListLit))
(DFunDef false "emptyMethodModulePredicateSlots" ((PVar "mid") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "emptyMethodModulePredicateSlots") (EVar "mid")) (EListLit (EVar "d"))) (EApp (EApp (EVar "emptyMethodModulePredicateSlots") (EVar "mid")) (EVar "rest"))))
(DFunDef false "emptyMethodModulePredicateSlots" ((PVar "mid") (PCons (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "methods" None) (rf "ifaceOrigin" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "emptyMethodModulePredicateSlot") (EVar "mid")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "ifaceOrigin"))))) (EVar "typarams"))) (EVar "methods")) (EApp (EApp (EVar "emptyMethodModulePredicateSlots") (EVar "mid")) (EVar "rest"))))
(DFunDef false "emptyMethodModulePredicateSlots" ((PVar "mid") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "emptyMethodModulePredicateSlots") (EVar "mid")) (EVar "rest")))
(DTypeSig false "emptyMethodModulePredicateSlot" (TyFun (TyCon "String") (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")))))))))
(DFunDef false "emptyMethodModulePredicateSlot" ((PVar "mid") (PVar "iface") (PVar "typarams") (PCon "IfaceMethod" (PVar "name") (PVar "ty") PWild PWild)) (EIf (EApp (EVar "isEmptyL") (EApp (EApp (EVar "methodLevelConstraintVarNames") (EVar "typarams")) (EVar "ty"))) (EListLit (ETuple (ETuple (EVar "mid") (EApp (EApp (EVar "methodSlotKey") (EVar "iface")) (EVar "name"))) (EListLit))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "declTopFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declTopFnNames" ((PVar "decls")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "decls"))))
(DTypeSig true "useModuleId" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "useModuleId" ((PCon "DUse" PWild (PVar "path") PWild)) (EListLit (EApp (EVar "useModId") (EVar "path"))))
(DFunDef false "useModuleId" (PWild) (EListLit))
(DTypeSig true "lastComponent" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastComponent" ((PVar "ns")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "last") (EVar "ns"))))
(DTypeSig true "importLocFor" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "importLocFor" ((PVar "reach") (PVar "prog") (PVar "owner")) (EApp (EApp (EVar "orElseLoc") (EApp (EApp (EVar "findMap") (EApp (EVar "importLocOf") (EVar "owner"))) (EVar "prog"))) (EApp (EApp (EVar "findMap") (EApp (EApp (EVar "importLocReaching") (EVar "reach")) (EVar "owner"))) (EVar "prog"))))
(DTypeSig false "importLocOf" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "importLocOf" ((PVar "owner") (PCon "DUse" PWild (PVar "path") (PVar "loc"))) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (EVar "owner")) (EApp (EVar "Some") (EVar "loc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "importLocOf" (PWild PWild) (EVar "None"))
(DTypeSig false "importLocReaching" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "importLocReaching" ((PVar "reach") (PVar "owner") (PCon "DUse" PWild (PVar "path") (PVar "loc"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "owner")) (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "reach")))) (EApp (EVar "Some") (EVar "loc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "importLocReaching" (PWild PWild PWild) (EVar "None"))
(DTypeSig true "builtinClassName" (TyFun (TyCon "BuiltinClass") (TyCon "String")))
(DFunDef false "builtinClassName" ((PCon "BNum")) (ELit (LString "Num")))
(DFunDef false "builtinClassName" ((PCon "BEq")) (ELit (LString "Eq")))
(DFunDef false "builtinClassName" ((PCon "BOrd")) (ELit (LString "Ord")))
(DFunDef false "builtinClassName" ((PCon "BSemigroup")) (ELit (LString "Semigroup")))
(DTypeSig true "builtinClassOrigin" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "BuiltinClass") (TyCon "TyConOrigin"))))
(DFunDef false "builtinClassOrigin" ((PVar "gctx") (PCon "BNum")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcNum"))
(DFunDef false "builtinClassOrigin" ((PVar "gctx") (PCon "BEq")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcEq"))
(DFunDef false "builtinClassOrigin" ((PVar "gctx") (PCon "BOrd")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcOrd"))
(DFunDef false "builtinClassOrigin" ((PVar "gctx") (PCon "BSemigroup")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef") "value") "bcSemigroup"))
(DTypeSig true "builtinIfaceRef" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "BuiltinClass") (TyCon "IfaceRef"))))
(DFunDef false "builtinIfaceRef" ((PVar "gctx") (PVar "c")) (ERecordCreate "IfaceRef" ((fa "irName" (EApp (EVar "builtinClassName") (EVar "c"))) (fa "irOrigin" (EApp (EApp (EVar "builtinClassOrigin") (EVar "gctx")) (EVar "c"))))))
(DTypeSig true "buildFlatImplEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ImplEnv")))
(DFunDef false "buildFlatImplEnv" ((PVar "prog")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EApp (EVar "implRowsOf") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "implDeclFacts") (EVar "prog")))) (DoLet false false (PVar "indexed") (EApp (EApp (EVar "ieIndexRows") (EVar "rows")) (EVar "emptyImplEnv"))) (DoExpr (EVariantUpdate "ImplEnv" (EVar "indexed") ((fa "ieRows" (EVar "rows")) (fa "ieUnivSnaps" (EApp (EVar "ieBuildSnaps") (EVar "rows"))))))))
(DTypeSig false "ieIndexRows" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyCon "ImplEnv") (TyCon "ImplEnv"))))
(DFunDef false "ieIndexRows" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "ieIndexRows" ((PCons (PVar "r") (PVar "rest")) (PVar "env")) (EApp (EApp (EVar "ieIndexRows") (EVar "rest")) (EApp (EApp (EVar "ieFileRow") (EVar "r")) (EVar "env"))))
(DTypeSig false "ieBuildSnaps" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse")))))
(DFunDef false "ieBuildSnaps" ((PVar "rows")) (EApp (EVar "reverseL") (EApp (EVar "fst") (EApp (EApp (EVar "ieBuildSnapsGo") (EVar "rows")) (EVar "ieSnapZero")))))
(DTypeSig false "ieBuildSnapsGo" (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyCon "ImplUniverse")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "ImplUniverse"))) (TyCon "ImplUniverse")))))
(DFunDef false "ieBuildSnapsGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "ieBuildSnapsGo" ((PCons (PVar "r") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PTuple (PVar "run") (PVar "more")) (EApp (EApp (EApp (EVar "ieSameOrdRun") (EApp (EVar "ieRowOrd") (EVar "r"))) (EBinOp "::" (EVar "r") (EVar "rest"))) (EListLit))) (DoExpr (EApp (EApp (EVar "ieBuildSnapsGo") (EVar "more")) (EApp (EApp (EVar "ieSnapStep") (EVar "run")) (EVar "acc"))))))
(DTypeSig false "ieSameOrdRun" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyFun (TyApp (TyCon "List") (TyCon "ImplRow")) (TyTuple (TyApp (TyCon "List") (TyCon "ImplRow")) (TyApp (TyCon "List") (TyCon "ImplRow")))))))
(DFunDef false "ieSameOrdRun" (PWild (PList) (PVar "acc")) (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EListLit)))
(DFunDef false "ieSameOrdRun" ((PVar "o") (PCons (PVar "r") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "==" (EApp (EVar "ieRowOrd") (EVar "r")) (EVar "o")) (EApp (EApp (EApp (EVar "ieSameOrdRun") (EVar "o")) (EVar "rest")) (EBinOp "::" (EVar "r") (EVar "acc"))) (EIf (EVar "otherwise") (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EBinOp "::" (EVar "r") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ieTyBlob" (TyCon "Ty"))
(DFunDef false "ieTyBlob" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Blob"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EApp (EVar "OriginModule") (ELit (LString "amod")))))))
(DTypeSig false "ieSameImplIn" (TyFun (TyCon "String") (TyCon "Decl")))
(DFunDef false "ieSameImplIn" ((PVar "m")) (ERecordCreate "DImpl" ((fa "pub" (EVar "True")) (fa "iface" (ELit (LString "Same"))) (fa "tys" (EListLit (EVar "ieTyBlob"))) (fa "reqs" (EListLit)) (fa "methods" (EListLit)) (fa "implOrigin" (EApp (EVar "OriginModule") (EVar "m"))) (fa "implIfaceLoc" (EVar "None")))))
(DTypeSig false "ieProbeKey" (TyFun (TyCon "String") (TyCon "RegKey")))
(DFunDef false "ieProbeKey" ((PVar "m")) (EApp (EVar "regKeyNTab") (EListLit (EApp (EVar "oblIfaceKey") (ERecordCreate "IfaceRef" ((fa "irName" (ELit (LString "Same"))) (fa "irOrigin" (EApp (EVar "OriginModule") (EVar "m")))))) (EApp (EVar "dispHeadTab") (EApp (EApp (EVar "headKeyOfCon") (EApp (EVar "OriginModule") (ELit (LString "amod")))) (ELit (LString "Blob")))))))
(DTypeSig false "ieProbeBareKey" (TyCon "RegKey"))
(DFunDef false "ieProbeBareKey" () (EApp (EVar "regKeyNTab") (EListLit (EApp (EApp (EVar "TkBare") (EVar "NsIface")) (ELit (LString "Same"))) (EApp (EVar "dispHeadTab") (EApp (EApp (EVar "headKeyOfCon") (EApp (EVar "OriginModule") (ELit (LString "amod")))) (ELit (LString "Blob")))))))
(DTypeSig false "ieProbeEnv" (TyFun (TyCon "GraphCtx") (TyCon "ImplEnv")))
(DFunDef false "ieProbeEnv" ((PVar "gctx")) (EApp (EVar "buildImplEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "amod"))) (EListLit (EApp (EVar "ieSameImplIn") (ELit (LString "amod"))))) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "zmod"))) (EListLit (EApp (EVar "ieSameImplIn") (ELit (LString "zmod"))))))))
(DTypeSig false "ieUnivConcreteOf" (TyFun (TyCon "ImplUniverse") (TyApp (TyCon "MultiRegistry") (TyTuple (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Require"))))))
(DFunDef false "ieUnivConcreteOf" ((PCon "ImplUniverse" (PVar "conc") PWild)) (EVar "conc"))
(DTypeSig false "ieOtherImplIn" (TyFun (TyCon "String") (TyCon "Decl")))
(DFunDef false "ieOtherImplIn" ((PVar "m")) (ERecordCreate "DImpl" ((fa "pub" (EVar "True")) (fa "iface" (ELit (LString "Other"))) (fa "tys" (EListLit (EVar "ieTyBlob"))) (fa "reqs" (EListLit)) (fa "methods" (EListLit)) (fa "implOrigin" (EApp (EVar "OriginModule") (EVar "m"))) (fa "implIfaceLoc" (EVar "None")))))
(DTypeSig false "ieGenImplIn" (TyFun (TyCon "String") (TyCon "Decl")))
(DFunDef false "ieGenImplIn" ((PVar "m")) (ERecordCreate "DImpl" ((fa "pub" (EVar "True")) (fa "iface" (ELit (LString "Gen"))) (fa "tys" (EListLit (EApp (EVar "TyVar") (ELit (LString "a"))))) (fa "reqs" (EListLit)) (fa "methods" (EListLit)) (fa "implOrigin" (EApp (EVar "OriginModule") (EVar "m"))) (fa "implIfaceLoc" (EVar "None")))))
(DTypeSig false "ieLooseImplIn" (TyFun (TyCon "String") (TyCon "Decl")))
(DFunDef false "ieLooseImplIn" ((PVar "m")) (ERecordCreate "DImpl" ((fa "pub" (EVar "True")) (fa "iface" (ELit (LString "Loose"))) (fa "tys" (EListLit (EVar "ieTyBlob"))) (fa "reqs" (EListLit)) (fa "methods" (EListLit)) (fa "implOrigin" (EVar "OriginUnresolved")) (fa "implIfaceLoc" (EVar "None")))))
(DTypeSig false "ieHeadProbeAmod" (TyApp (TyCon "List") (TyCon "Decl")))
(DFunDef false "ieHeadProbeAmod" () (EListLit (EApp (EVar "ieSameImplIn") (ELit (LString "amod"))) (EApp (EVar "ieOtherImplIn") (ELit (LString "amod")))))
(DTypeSig false "ieHeadProbeZmod" (TyApp (TyCon "List") (TyCon "Decl")))
(DFunDef false "ieHeadProbeZmod" () (EListLit (EApp (EVar "ieSameImplIn") (ELit (LString "zmod"))) (EApp (EVar "ieGenImplIn") (ELit (LString "zmod"))) (EApp (EVar "ieLooseImplIn") (ELit (LString "zmod")))))
(DTypeSig false "ieHeadProbeDecls" (TyApp (TyCon "List") (TyCon "Decl")))
(DFunDef false "ieHeadProbeDecls" () (EBinOp "++" (EVar "ieHeadProbeAmod") (EVar "ieHeadProbeZmod")))
(DTypeSig false "ieHeadProbeEnv" (TyFun (TyCon "GraphCtx") (TyCon "ImplEnv")))
(DFunDef false "ieHeadProbeEnv" ((PVar "gctx")) (EApp (EVar "buildImplEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "amod"))) (EVar "ieHeadProbeAmod")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "zmod"))) (EVar "ieHeadProbeZmod")))))
(DTypeSig false "ieProbeBlobHead" (TyCon "HeadKey"))
(DFunDef false "ieProbeBlobHead" () (EApp (EApp (EVar "headKeyOfCon") (EApp (EVar "OriginModule") (ELit (LString "amod")))) (ELit (LString "Blob"))))
(DTypeSig false "buildClassEnv" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyCon "ClassEnv"))))
(DFunDef false "buildClassEnv" ((PVar "gctx") (PVar "mods")) (EApp (EVar "classEnvFinish") (EApp (EApp (EApp (EVar "buildClassEnvGo") (EVar "gctx")) (EVar "mods")) (EVar "emptyClassEnv"))))
(DTypeSig false "ceMethodFoo" (TyCon "IfaceMethod"))
(DFunDef false "ceMethodFoo" () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "foo"))) (EApp (EApp (EVar "TyFun") (EApp (EVar "TyVar") (ELit (LString "a")))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None")))) (EVar "None")) (EVar "None")))
(DTypeSig false "ceMethodBar" (TyCon "IfaceMethod"))
(DFunDef false "ceMethodBar" () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "bar"))) (EApp (EApp (EVar "TyFun") (EApp (EVar "TyVar") (ELit (LString "a")))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "String"))) (EVar "None")))) (EVar "None")) (EVar "None")))
(DTypeSig false "ceSuperEq" (TyCon "Super"))
(DFunDef false "ceSuperEq" () (ERecordCreate "Super" ((fa "superHead" (ELit (LString "Eq"))) (fa "superParams" (EListLit (ELit (LString "a")))) (fa "superOrigin" (EApp (EVar "OriginModule") (ELit (LString "core")))))))
(DTypeSig false "ceSameDeclIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Decl"))))
(DFunDef false "ceSameDeclIn" ((PVar "m") (PVar "methods")) (ERecordCreate "DInterface" ((fa "pub" (EVar "True")) (fa "def" (EVar "False")) (fa "name" (ELit (LString "Same"))) (fa "typarams" (EListLit (ELit (LString "a")))) (fa "typaramKinds" (EListLit (EVar "None"))) (fa "supers" (EListLit (EVar "ceSuperEq"))) (fa "methods" (EVar "methods")) (fa "ifaceOrigin" (EApp (EVar "OriginModule") (EVar "m"))) (fa "ifaceNameLoc" (EVar "None")))))
(DTypeSig false "ceProbeEnv" (TyFun (TyCon "GraphCtx") (TyCon "ClassEnv")))
(DFunDef false "ceProbeEnv" ((PVar "gctx")) (EApp (EApp (EVar "buildClassEnv") (EVar "gctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "amod"))) (EListLit (EApp (EApp (EVar "ceSameDeclIn") (ELit (LString "amod"))) (EListLit (EVar "ceMethodFoo"))))) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "zmod"))) (EListLit (EApp (EApp (EVar "ceSameDeclIn") (ELit (LString "zmod"))) (EListLit (EVar "ceMethodBar"))))))))
(DTypeSig false "ceProbeKey" (TyFun (TyCon "String") (TyCon "RegKey")))
(DFunDef false "ceProbeKey" ((PVar "m")) (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EApp (EVar "OriginModule") (EVar "m"))) (ELit (LString "Same")))))
(DTypeSig false "ceMethodTyStr" (TyFun (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))) (TyCon "String")))
(DFunDef false "ceMethodTyStr" ((PTuple PWild (PVar "ty") PWild)) (EApp (EVar "ppTy") (EVar "ty")))
(DTypeSig false "ceSuperHead" (TyFun (TyCon "Super") (TyCon "String")))
(DFunDef false "ceSuperHead" ((PRec "Super" ((rf "superHead" (PVar "h"))) true)) (EVar "h"))
(DTypeSig false "ceRowOriginTag" (TyFun (TyCon "CeRow") (TyCon "String")))
(DFunDef false "ceRowOriginTag" ((PVar "r")) (EMatch (EFieldAccess (EApp (EVar "ceRowIface") (EVar "r")) "irOrigin") (arm (PCon "OriginModule" (PVar "m")) () (EVar "m")) (arm (PCon "OriginBuiltin") () (ELit (LString "<builtin>"))) (arm (PCon "OriginUnresolved") () (ELit (LString "<unresolved>")))))
(DTypeSig false "ceRowMethodNamesAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ceRowMethodNamesAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "ceRowMethodNames") (EVar "r")))))
(DTypeSig false "ceRowMethodTysAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ceRowMethodTysAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EMethodRef "map") (EVar "ceMethodTyStr")) (EApp (EVar "ceRowMethods") (EVar "r"))))))
(DTypeSig false "ceRowTyparamsAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ceRowTyparamsAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "ceRowTyparams") (EVar "r")))))
(DTypeSig false "ceRowSuperHeadsAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ceRowSuperHeadsAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EMethodRef "map") (EVar "ceSuperHead")) (EApp (EVar "ceRowSupers") (EVar "r"))))))
(DTypeSig false "ceSuperParams" (TyFun (TyCon "Super") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ceSuperParams" ((PRec "Super" ((rf "superParams" (PVar "ps"))) true)) (EVar "ps"))
(DTypeSig false "ceSuperOrigin" (TyFun (TyCon "Super") (TyCon "String")))
(DFunDef false "ceSuperOrigin" ((PRec "Super" ((rf "superOrigin" (PCon "OriginModule" (PVar "m")))) true)) (EVar "m"))
(DFunDef false "ceSuperOrigin" ((PRec "Super" ((rf "superOrigin" (PCon "OriginBuiltin"))) true)) (ELit (LString "<builtin>")))
(DFunDef false "ceSuperOrigin" ((PRec "Super" ((rf "superOrigin" (PCon "OriginUnresolved"))) true)) (ELit (LString "<unresolved>")))
(DTypeSig false "ceRowSuperParamsAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ceRowSuperParamsAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EDictApp "flatMap") (EVar "ceSuperParams")) (EApp (EVar "ceRowSupers") (EVar "r"))))))
(DTypeSig false "ceRowSuperOriginAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyCon "String")))))
(DFunDef false "ceRowSuperOriginAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "r")) () (EMatch (EApp (EVar "ceRowSupers") (EVar "r")) (arm (PList) () (ELit (LString ""))) (arm (PCons (PVar "s") PWild) () (EApp (EVar "ceSuperOrigin") (EVar "s")))))))
(DTypeSig false "ceRowIfaceNameAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyCon "String")))))
(DFunDef false "ceRowIfaceNameAt" ((PVar "m") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EApp (EVar "ceProbeKey") (EVar "m"))) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "r")) () (EFieldAccess (EApp (EVar "ceRowIface") (EVar "r")) "irName"))))
(DTypeSig false "ceRowParamKindNamesAt" (TyFun (TyCon "RegKey") (TyFun (TyCon "Int") (TyFun (TyCon "ClassEnv") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ceRowParamKindNamesAt" ((PVar "key") (PVar "cur") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "ceLookupAt") (EVar "key")) (EVar "cur")) (EVar "env")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "ks")) (EApp (EApp (EMethodRef "map") (EVar "kindName")) (EVar "ks")))) (EApp (EVar "ceRowParamKinds") (EVar "r"))))))
(DTypeSig false "ceGradedMethod" (TyCon "IfaceMethod"))
(DFunDef false "ceGradedMethod" () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "run"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "TyApp") (EApp (EVar "TyVar") (ELit (LString "f")))) (EApp (EVar "TyVar") (ELit (LString "e"))))) (EApp (EVar "TyVar") (ELit (LString "a"))))) (EApp (EApp (EApp (EVar "TyEffect") (EListLit)) (EListLit (ELit (LString "e")))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (EVar "None")) (EVar "None")))
(DTypeSig false "ceGradedIface" (TyCon "Decl"))
(DFunDef false "ceGradedIface" () (ERecordCreate "DInterface" ((fa "pub" (EVar "True")) (fa "def" (EVar "False")) (fa "name" (ELit (LString "Async"))) (fa "typarams" (EListLit (ELit (LString "f")))) (fa "typaramKinds" (EListLit (EApp (EVar "Some") (EApp (EApp (EVar "KindArrow") (EVar "KindEffect")) (EApp (EApp (EVar "KindArrow") (EVar "KindType")) (EVar "KindType")))))) (fa "supers" (EListLit)) (fa "methods" (EListLit (EVar "ceGradedMethod"))) (fa "ifaceOrigin" (EApp (EVar "OriginModule") (ELit (LString "gmod")))) (fa "ifaceNameLoc" (EVar "None")))))
(DTypeSig false "ceGradedEnv" (TyFun (TyCon "GraphCtx") (TyCon "ClassEnv")))
(DFunDef false "ceGradedEnv" ((PVar "gctx")) (EApp (EApp (EVar "buildClassEnv") (EVar "gctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "gmod"))) (EListLit (EVar "ceGradedIface"))))))
(DTypeSig false "ceGradedKey" (TyCon "RegKey"))
(DFunDef false "ceGradedKey" () (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EApp (EVar "OriginModule") (ELit (LString "gmod")))) (ELit (LString "Async")))))
(DTypeSig false "ceFunctorMethod" (TyCon "IfaceMethod"))
(DFunDef false "ceFunctorMethod" () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "fmap"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "TyApp") (EApp (EVar "TyVar") (ELit (LString "f")))) (EApp (EVar "TyVar") (ELit (LString "a"))))) (EApp (EApp (EVar "TyApp") (EApp (EVar "TyVar") (ELit (LString "f")))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (EVar "None")) (EVar "None")))
(DTypeSig false "ceFunctorIface" (TyCon "Decl"))
(DFunDef false "ceFunctorIface" () (ERecordCreate "DInterface" ((fa "pub" (EVar "True")) (fa "def" (EVar "False")) (fa "name" (ELit (LString "Functor"))) (fa "typarams" (EListLit (ELit (LString "f")))) (fa "typaramKinds" (EListLit (EVar "None"))) (fa "supers" (EListLit)) (fa "methods" (EListLit (EVar "ceFunctorMethod"))) (fa "ifaceOrigin" (EApp (EVar "OriginModule") (ELit (LString "fmod")))) (fa "ifaceNameLoc" (EVar "None")))))
(DTypeSig false "ceFunctorEnv" (TyFun (TyCon "GraphCtx") (TyCon "ClassEnv")))
(DFunDef false "ceFunctorEnv" ((PVar "gctx")) (EApp (EApp (EVar "buildClassEnv") (EVar "gctx")) (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "fmod"))) (EListLit (EVar "ceFunctorIface"))))))
(DTypeSig false "ceFunctorKey" (TyCon "RegKey"))
(DFunDef false "ceFunctorKey" () (EApp (EVar "regKeyOfTab") (EApp (EApp (EVar "ifaceTabKey") (EApp (EVar "OriginModule") (ELit (LString "fmod")))) (ELit (LString "Functor")))))
(DTypeSig true "buildImplUniverse" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ImplUniverse")))
(DFunDef false "buildImplUniverse" ((PVar "prog")) (EApp (EApp (EVar "growImplUniverse") (EApp (EVar "implDeclsWithReqs") (EVar "prog"))) (EVar "emptyImplUniverse")))
(DTypeSig true "methodRowTestIface" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Decl"))))))
(DFunDef false "methodRowTestIface" ((PVar "moduleId") (PVar "name") (PVar "typarams") (PVar "methods")) (ERecordCreate "DInterface" ((fa "pub" (EVar "False")) (fa "def" (EVar "False")) (fa "name" (EVar "name")) (fa "typarams" (EVar "typarams")) (fa "typaramKinds" (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "None"))) (EVar "typarams"))) (fa "supers" (EListLit)) (fa "methods" (EVar "methods")) (fa "ifaceOrigin" (EApp (EVar "OriginModule") (EVar "moduleId"))) (fa "ifaceNameLoc" (EVar "None")))))
(DTypeSig true "methodRowTestConstraint" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Constraint")))))
(DFunDef false "methodRowTestConstraint" ((PVar "moduleId") (PVar "name") (PVar "args")) (ERecordCreate "Constraint" ((fa "constraintHead" (EVar "name")) (fa "constraintArgs" (EVar "args")) (fa "constraintOrigin" (EApp (EVar "OriginModule") (EVar "moduleId"))))))
(DTypeSig true "methodRowTestFoldMapDecl" (TyCon "Decl"))
(DFunDef false "methodRowTestFoldMapDecl" () (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "foldable-test"))) (ELit (LString "Foldable"))) (EListLit (ELit (LString "t")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "foldMap"))) (EApp (EApp (EVar "TyConstrained") (EListLit (EApp (EApp (EApp (EVar "methodRowTestConstraint") (ELit (LString "monoid-test"))) (ELit (LString "Monoid"))) (EListLit (EApp (EVar "TyVar") (ELit (LString "m"))))))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "TyFun") (EApp (EVar "TyVar") (ELit (LString "a")))) (EApp (EVar "TyVar") (ELit (LString "m"))))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "TyApp") (EApp (EVar "TyVar") (ELit (LString "t")))) (EApp (EVar "TyVar") (ELit (LString "a"))))) (EApp (EVar "TyVar") (ELit (LString "m"))))))) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodRowTestConstantDecl" (TyCon "Decl"))
(DFunDef false "methodRowTestConstantDecl" () (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "constant-test"))) (ELit (LString "Constant"))) (EListLit)) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "token"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodRowTestSameA" (TyCon "Decl"))
(DFunDef false "methodRowTestSameA" () (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "same-a"))) (ELit (LString "A"))) (EListLit)) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "same"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None")))) (EVar "None")) (EVar "None")) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "extra"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodRowTestSameB" (TyCon "Decl"))
(DFunDef false "methodRowTestSameB" () (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "same-b"))) (ELit (LString "B"))) (EListLit (ELit (LString "t")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "same"))) (EApp (EApp (EVar "TyConstrained") (EListLit (EApp (EApp (EApp (EVar "methodRowTestConstraint") (ELit (LString "d-test"))) (ELit (LString "D"))) (EListLit (EApp (EVar "TyVar") (ELit (LString "a"))))))) (EApp (EApp (EVar "TyFun") (EApp (EVar "TyVar") (ELit (LString "a")))) (EApp (EVar "TyVar") (ELit (LString "a")))))) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodRowTestNum" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Decl"))))
(DFunDef false "methodRowTestNum" ((PVar "moduleId") (PVar "fromIntTy")) (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (EVar "moduleId")) (ELit (LString "Num"))) (EListLit (ELit (LString "a")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "fromInt"))) (EVar "fromIntTy")) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodRowTestUserFromInt" (TyCon "Decl"))
(DFunDef false "methodRowTestUserFromInt" () (EApp (EApp (EApp (EApp (EVar "methodRowTestIface") (ELit (LString "user-from-int"))) (ELit (LString "Buildable"))) (EListLit (ELit (LString "a")))) (EListLit (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (ELit (LString "fromInt"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Bool"))) (EVar "None"))) (EApp (EVar "TyVar") (ELit (LString "a"))))) (EVar "None")) (EVar "None")))))
(DTypeSig true "methodRowSameNameView" (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "methodRowSameNameView" ((PVar "rows")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (ETuple (EFieldAccess (EFieldAccess (EVar "row") "msrIface") "irName") (EFieldAccess (EVar "row") "msrName") (EApp (EVar "listLen") (EApp (EVar "schemeIds") (EFieldAccess (EVar "row") "msrScheme"))) (EApp (EVar "listLen") (EFieldAccess (EVar "row") "msrMethodSlots"))))) (EVar "rows")))
