# META
source_lines=3200
stages=DESUGAR,MARK
# SOURCE
-- tc_decls: declaration analysis above the written-type layer: building `DataEnv` and `DeclEnvs`
-- from declarations (`buildDeclEnvs`, `dataEnvAddDecl`, the owner tables), variant and record
-- registration (`registerVariants`, `registerRecordInfoKeyed`, the existential cells), type aliases
-- (`addAliasDecl`, cycle rejection by `rejectCyclicAliases`, the expansion normal form
-- `tyAliasNormalForm`), the recording of declared kinds (`recordDeclKinds`, `recordDeclaredKinds`),
-- the method scheme rows, and the signature layer over the conversion (`sigToScheme`, `sigVarsFor`,
-- `instantiateSigTracked`, `astTypeFreshTbl`). The conversion itself and the kind, authority,
-- effect-domain and effect-parameter checks are `tc_decls_types`.
--
-- Spec: DICT section 1; EFFECTS section 4.1 (the signature binders), section 6.1 (kinds), section 6.2
-- (kind annotations bind parameters at declaration heads), section 6.4 (kind consistency and indices
-- of a declared head); DICT section 8 I4 (the alias normal form keeps resolved identity);
-- language-design Data Types.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_foreign`,
-- `tc_solve_givens`, `tc_solve_entail`, `tc_solve`, `tc_solve_check`, `tc_shadow`, `tc_effects`,
-- `tc_occurrence`, `tc_groups`, `tc_pat`, `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`,
-- `tc_module`.

import types.tc_types.{
  PredicateSlotArgs(..),
  AliasDecl(..),
  BuiltinClass(..),
  BuiltinClasses(..),
  DataEnv(..),
  DataTypeDecl(..),
  DeclEnvAcc(..),
  DeclEnvs(..),
  DeclEnvSeedAcc(..),
  Kind(..),
  MethodPredicateSlot(..),
  MethodPredicateTemplate(..),
  MethodSchemeRow(..),
  NumAnchorTestObservation(..),
  PredicateSlot(..),
  SigVars(..),
  DeclEnvModule,
  GraphCtx,
  ModuleCtx,
  RecordInfo,
  TcEnv,
}
import types.tc_mono.{
  applyParams,
  authvarIdOf,
  collectAuthvarIds,
  collectRowEffvarIds,
  collectTyIds,
  effvarIdOf,
  foldrFun,
  monoTyvarId,
  schemeBodyOf,
  schemeIds,
  tconFrom,
  tyAppSpine,
  tyVarNames,
}
import types.tc_state.{
  carryModuleCtx,
  emptyBuiltinClasses,
  emptyDataEnv,
  freshSubRecordsOf,
  mctxAtIfSome,
  probeGraphCtx,
}
import types.tc_env.{
  addCtor,
  aliasUniverseAt,
  buildClassEnvGo,
  buildImplEnvGo,
  builtinIfaceRef,
  classEnvFinish,
  constraintSlotDispatchVar,
  declEnvDeclsOf,
  declEnvKindEntries,
  declEnvModule,
  declEnvReachFrom,
  declEnvRowVisible,
  declEnvVisibleTo,
  declGradedScope,
  declParamKinds,
  declTopFnNames,
  definersIn,
  dtopFor,
  effTailNames,
  implAccFinish,
  importLocFor,
  kindPublicDataDecl,
  methodEnvGo,
  methodSlotKey,
  namesToSet,
  publicDataDecl,
  rangedOver,
  removeAllS,
  sameIfaceDecl,
  tyTabKey,
  useModuleId,
}
import types.tc_diag.{pushTypeErrorOnce}
import types.tc_scope.{importFormRows, memberBindsCtorName}
import types.tc_unify.{
  atomsEscape,
  freshAuthBinderRanged,
  freshAuthvar,
  freshAuthvarRanged,
  freshEffMap,
  freshEffvar,
  freshTvMap,
  freshVar,
  namedArgDomains,
}
import types.tc_decls_variance.{
  declEnvPolarityChain,
  inferParamPolarities,
  payloadAstTypes,
  recordParamPolarities,
  seedParamPolarityFixpointScoped,
  variantPayload,
}
import types.tc_decls_types.{
  atomsOfWritten,
  authArgBindersIn,
  authorityBinderBound,
  binderDomainsIn,
  bindingForceFromAst,
  fromAstType,
  fromAstTypeE,
  namedArgTypes,
  namedAtomBinders,
  patternSlotNamesIn,
  payloadTypesE,
  qualifiedKindScope,
  recFieldMono,
  reportBinderDomains,
  reportUnboundAuthorityNames,
  reportUnboundAuthorityNamesIn,
  rowArgNames,
  rowArgNamesIn,
  sigVarsWithAuths,
  substAliasArgs,
  writtenBindingForce,
}
import types.effect_authority.{Authority(..), Authvar(..), authvarId}
import types.effect_rows.{
  Atom(..), EffLabel(..), EffRow(..), Effvar(..), atomsNorm, pureRow
}
import frontend.ast.{
  UsePath(..),
  Ns(..),
  Lit(..),
  Expr(..),
  Attr(..),
  ConPayload(..),
  Constraint(..),
  DataVis(..),
  Decl(..),
  EffAtomTy(..),
  Field(..),
  Ident(..),
  IfaceMethod(..),
  KindAnn(..),
  Loc(..),
  TabKey(..),
  Ty(..),
  TyConOrigin(..),
  UseMember(..),
  Variant(..),
  firstTyLoc,
  firstTyLocList,
  identOriginFold,
  lookupTab,
  mapTyFull,
  mkIdent,
  noBinderId,
  noDeclLoc,
  tabKeyEq,
  tabKeyName,
  tyConBuiltin,
}
import types.repr.{IfaceRef(..), Mono(..), Scheme(..), ppMono, ppTy}
import support.ordmap.{
  omDelete,
  omEmpty,
  omFromNames,
  omFromPairs,
  omHasKey,
  omInsert,
  omKeys,
  omLookup,
  omMapValues,
  OrdMap,
}
import types.effect_domain.{Param(..)}
import support.util.{
  allList,
  anyList,
  contains,
  dedup,
  filterList,
  isEmptyL,
  isNonEmptyL,
  isSome,
  listLen,
  lookupAssoc,
  reverseL,
  zipL,
}
import list.{elemIndex, findMap, head}
import types.registry.{spFloor}
import frontend.visibility.{useModId}
import map as IdMap

-- Fold rows into the accumulator, one row at a time, through each table's OWN
-- fold (each called with a singleton list).  Going through the existing folds
-- rather than open-coding a per-row step is what keeps a resumed prefix and a
-- whole-graph build the same function: there is exactly one implementation of
-- every table, so the two cannot drift.
export
declEnvAccOf : GraphCtx -> List DeclEnvModule -> DeclEnvAcc -> DeclEnvAcc
declEnvAccOf gctx [] a = a
declEnvAccOf gctx (m :: rest) a =
  -- #1675: BOTH definer projections come out of ONE fold.  They are derived from
  -- the same uncollapsed row list -- `deDefiners` keeps the first row per name,
  -- `deAmbigValues` records the names where keeping the first was a CHOICE between
  -- two definitions -- so computing them apart would walk `modulePubDefiners` twice
  -- and let the two disagree.
  let definers = declEnvDefinerIndex a.daDefiners a.daAmbig [m]
  declEnvAccOf gctx rest DeclEnvAcc {
    daOrdIndex = declEnvOrdIndex a.daOrdIndex [m],
    daDefiners = fst definers,
    daAmbig = snd definers,
    daData = dataEnvFromRowsGo [m] a.daData,
    daImpls = buildImplEnvGo [m] a.daImpls,
    daIfaces = buildClassEnvGo gctx [m] a.daIfaces,
    daMethods = methodEnvGo gctx [m] a.daMethods,
    daSeeds = declEnvSeedChain gctx [m] a.daSeeds,
    daPolarity = declEnvPolarityChain [m] a.daPolarity,
    daOwnerModules = declEnvOwnerModules [m] a.daOwnerModules,
  }

-- Build the envelope from an accumulator that already holds the prelude row, the
-- prelude row itself, and the loader's dependency-first module list.
-- Must run AFTER the driver's `stampGraphTyOrigins`, for the same reason
-- `meExports` must: identity lives on the decls, so an envelope built
-- from the unstamped tree would carry a different one.  Both current call sites
-- (`checkModulesPreambleK`, `elaborateModules`) sit after their driver's stamp.
--
-- `coreRow` is the CALLER'S row even when `acc` is a resumed prefix: it is what
-- `deModules`/`deAllDecls` publish, and those must name the decls this analyze
-- stamped.  See `DeclEnvAcc`.
--
-- The rows arrive built rather than being derived here, because the Module-mode
-- drivers need the same rows earlier -- `populateEffectDomainsGraph` has to run
-- before this function does (`deAtomsBefore` below reads the table it fills).
export
buildDeclEnvs : GraphCtx ->
  DeclEnvAcc ->
  DeclEnvModule ->
  List DeclEnvModule ->
  DeclEnvs
buildDeclEnvs gctx acc coreRow modRows =
  let mods = coreRow :: modRows
  let a = declEnvAccOf gctx modRows acc
  DeclEnvs {
    deModules = mods,
    deOrdIndex = a.daOrdIndex,
    deDefiners = a.daDefiners,
    deAmbigValues = a.daAmbig,
    -- #1112 A-3.1: `deAllDecls` IS `coreDecls ++ flatMap snd modules` (see
    -- `declEnvDeclsOf`).
    deAllDecls = declEnvDeclsOf mods,
    -- #1112 A-3.4 / #1519 A-3.3: `IE` and `CE` inherit this fold's ordering and
    -- its must-run-after-`stampGraphTyOrigins` precondition, exactly as `deData`
    -- does.  All three are pure folds over the same rows, none mutates a ref, and
    -- none reads another's output -- so the order they are listed in is not
    -- observable.  If a later unit gives any of them a side effect, that stops
    -- being true and this comment is the thing it invalidates.
    deData = dataEnvFinish a.daData,
    deImpls = implAccFinish a.daImpls,
    deIfaces = classEnvFinish a.daIfaces,
    deMethods = a.daMethods,
    deKindsBefore = a.daSeeds.dsKinds,
    -- #2158: `deKindsBefore`'s BARE-NAME twin, out of the SAME fold and the same
    -- `kacc` rows -- see `declEnvSeedChain`.
    deNameIndexBefore = a.daSeeds.dsNames,
    -- #1119 D-2: the VARIANCE seed.  A SEPARATE chain rather than a fourth
    -- accumulator inside `declEnvSeedChain` because it is the only one of the
    -- three that has to read its own accumulator while building it --
    -- `data Cell a = MkCell (Ref a)` composes with `Ref`'s row, and a
    -- cross-module `data W a = MkW (Cell a)` composes with a row an EARLIER
    -- module contributed.  Same ordinal-ascending walk, same "[m]'s seed is
    -- everything strictly before [m]" stamping.
    dePolaritiesBefore = snd a.daPolarity,
    -- #2110 S2-1: the ATOM-GUARANTEE seed, a third chain for a DIFFERENT reason
    -- than the variance one above: `inferParamRowAtoms` composes with NOTHING
    -- (see its note -- an occurrence reached through another type's spine drives
    -- the intersection empty), so this chain needs neither its own read edge nor
    -- a fixpoint.
    --
    -- It is derived over EVERY row here rather than resumed from `acc`, and that
    -- placement is load-bearing: an entry's ⊤ parameter comes from `dtopFor`,
    -- which reads `GraphCtx.effectDomains`.  That table is filled from the
    -- WHOLE graph's `effect` decls, so a prelude entry cached under a
    -- prelude-only key would pin whichever reading the first analyze in the
    -- process happened to take.  See `DeclEnvAcc`.
    deAtomsBefore =
      snd (declEnvRowAtomsChain gctx mods ([], omInsert "" [] omEmpty)),
    deOwnersBefore = a.daSeeds.dsOwners,
    -- #1597: the two halves of the field-owner REACHABILITY filter.  Both are
    -- whole-graph and reader-independent (the reader is applied at the READ, in
    -- `fieldOwnerNames`).  `deReach` is not in `DeclEnvAcc` because its per-row
    -- answer depends on the WHOLE graph's import index, not on a prefix.
    deOwnerModules = a.daOwnerModules,
    deReach = declEnvReachIndex mods,
  }

-- The kind entries of row [m] that a reader at ordinal [cur] may see — the exact
-- peer of `declEnvRowVisible` one projection over, and composed from the same two
-- predicates rather than from an open-coded `<=` (see `declEnvVisibleTo`'s
-- note: an open-coded comparison here would be invisible to any future re-scoping
-- of the name axis, exactly as it would have been to A-3.6's had it landed here).
-- The own-row arm is unfiltered because a module's own kinds are: `registerData`'s
-- `DData` arm calls `recordParamKinds` regardless of `dataVis`.
declEnvRowKindEntries : GraphCtx ->
  Int ->
  DeclEnvModule ->
  List (TabKey, List Kind)
declEnvRowKindEntries gctx cur m
  | declEnvVisibleTo cur m.demOrd False = declEnvKindEntries gctx m.demDecls
  | declEnvVisibleTo cur m.demOrd True = m.demKindEntries
  | otherwise = []

-- The seed chain: reader k's seed is reader (k-1)'s seed with row (k-1)'s public
-- projection folded in, built once for the whole graph, so the read is one `omLookup`
-- and allocates nothing.  Folding the visible rows at every read costs O(universe)
-- per module, and that put `typecheck` over its floor in `diff_compiler_perf_scaling`'s
-- `modules` shape.
--
-- A reader's seed never holds its own row: a module registers its own declarations
-- right after the seed is loaded (`registerAllData`), so seeding them here as well
-- would put a doubled owner key in the raw field-owner multimap.  `fieldOwnerNames`
-- dedupes it on read, so the answer would not change, but the shape and the work
-- would.  The `deSeedChainProbe` doctests in this file pin the exclusion.
--
-- Do not hand every row the final accumulator.  It includes the reader's own row, and
-- the name and data scoping tables keep the ordinal prefix rule of `declEnvVisibleAt`:
-- widening the field-owner half narrows acceptance (`declEnvVisibleTo`).  Each step
-- still routes its projection through `declEnvRowKindEntries` and `declEnvRowVisible`,
-- hence through `declEnvVisibleTo`'s two conjuncts.
declEnvSeedChain : GraphCtx ->
  List DeclEnvModule ->
  DeclEnvSeedAcc ->
  DeclEnvSeedAcc
declEnvSeedChain gctx [] s = s
declEnvSeedChain gctx (m :: rest) s =
  let kents = declEnvRowKindEntries gctx (m.demOrd + 1) m
  declEnvSeedChain gctx rest DeclEnvSeedAcc {
    dsKAcc = kents ++ s.dsKAcc,
    dsOAcc =
      declEnvDeclFieldOwners (declEnvRowVisible (m.demOrd + 1) m) s.dsOAcc,
    dsNAcc = omFromNames (map (p => tabKeyName (fst p)) kents) s.dsNAcc,
    dsKinds = omInsert m.demId s.dsKAcc s.dsKinds,
    dsOwners = omInsert m.demId s.dsOAcc s.dsOwners,
    dsNames = omInsert m.demId s.dsNAcc s.dsNames,
  }

-- ── #2110 S2-1: the ATOM-GUARANTEE seed chain ────────────────────────────
-- `declEnvPolarityChain`'s shape, one table over: the same ordinal-ascending
-- walk, the same `declEnvVisibleTo`-routed row projection, the same "row [m]'s
-- seed is every row strictly earlier than [m]" stamping under [m]'s module id.
-- Read back by `declEnvSeedDataUniverse` in exactly one `omLookup`.
--
-- WITHOUT THIS, #2110's fix is single-FILE-only and silently so — the same
-- failure `declEnvPolarityChain`'s own records, MEASURED again on the
-- row-atoms table: `export data Slot e = Slot (Unit -> <Stdout | e> Unit)`
-- (ABSTRACT export, the ordinary way a library ships a wrapper) never reaches
-- an importer's `registerVariants`, so `paramRowAtomsOf` missed there and
-- `mkSlot f = Slot f` — accepted verbatim in `Slot`'s OWN module — was
-- REJECTED through the module boundary.  The direction is over-rejection, so
-- the gap was loud rather than a launder, but it made #2110 inapplicable to
-- every abstractly-exported wrapper.
--
-- The state is the PAIR -- (accumulator, per-module seed table) -- that
-- `declEnvPolarityChain` carries, for the same reason.  This chain is NOT resumed
-- from a cached prefix, though: see `deAtomsBefore`'s note in `buildDeclEnvs`.
declEnvRowAtomsChain : GraphCtx ->
  List DeclEnvModule ->
  (List (TabKey, List (List Atom)), OrdMap (List (TabKey, List (List Atom)))) ->
  (List (TabKey, List (List Atom)), OrdMap (List (TabKey, List (List Atom))))
declEnvRowAtomsChain gctx [] s = s
declEnvRowAtomsChain gctx (m :: rest) (aacc, am) =
  let entries = declEnvRowAtomsEntries gctx (m.demOrd + 1) m
  declEnvRowAtomsChain gctx rest (entries ++ aacc, omInsert m.demId aacc am)

-- The atom entries of row [m] a reader at ordinal [cur] may see — the peer of
-- `declEnvRowKindEntries` and `declEnvRowPolarityEntries`, composed from the
-- same two predicates rather than an open-coded `<=`, and using the same
-- `kindPublicDataDecl` projection for the cross-module arm (a param's ATOM
-- GUARANTEE travels with an abstract export for the same reason its KIND and
-- its VARIANCE do — #804/#1028: the importer can write the type even though it
-- cannot see the constructors).
--
-- This one may pre-FILTER, AND #2112's split does not apply.  The variance
-- peer had to move its publicity filter to the OUTPUT because a public
-- wrapper's variance COMPOSES with a private declaration's row, so pre-filtering
-- silently dropped the private half of the wrapper's meaning.  Atom guarantees
-- compose with nothing: `inferParamRowAtoms` reads no table, and an occurrence
-- of the parameter reached through ANOTHER type's application spine contributes
-- the empty atom list by construction (see its ).  Each entry is therefore a
-- function of its own declaration alone, so filtering the input and filtering
-- the output are the same set — and pre-filtering is what `declEnvRowKindEntries`
-- does.  If this table ever grows a composing arm, this filter must move to the
-- output the way #2112 moved the variance one.
declEnvRowAtomsEntries : GraphCtx ->
  Int ->
  DeclEnvModule ->
  List (TabKey, List (List Atom))
declEnvRowAtomsEntries gctx cur m
  | declEnvVisibleTo cur m.demOrd False = declEnvRowAtomEntries gctx m.demDecls
  | declEnvVisibleTo cur m.demOrd True =
    declEnvRowAtomEntries gctx (filterList kindPublicDataDecl m.demDecls)
  | otherwise = []

-- The population half, mirroring `declEnvKindEntries` arm for arm — including
-- its `DAttrib` unwrap and its lack of a `DTypeAlias` arm.  That last omission
-- is deliberate and matches the WRITER: `recordParamRowAtoms` is reached only
-- through `registerVariants`, which `registerData` calls from its `DData` and
-- `DNewtype` arms only (its alias arm writes `aliasTableRef` instead), so an
-- alias has no per-run row either.  Adding one here would publish a
-- cross-module entry with no single-file counterpart.
declEnvRowAtomEntries : GraphCtx -> List Decl -> List (TabKey, List (List Atom))
declEnvRowAtomEntries gctx [] = []
declEnvRowAtomEntries gctx ((DAttrib _ d) :: rest) =
  declEnvRowAtomEntries gctx (d :: rest)
declEnvRowAtomEntries gctx ((DData { dataName = n, dataParams = ps, dataCtors = vs, dataOrigin = o }) :: rest) =
  (tyTabKey o n, inferParamRowAtoms gctx ps vs)
    :: declEnvRowAtomEntries gctx rest
declEnvRowAtomEntries gctx ((DNewtype { newtypeName = n, newtypeParams = ps, newtypeCtor = con, newtypeFieldTy = fty, newtypeOrigin = o }) :: rest) =
  (tyTabKey o n, inferParamRowAtoms gctx ps [Variant con (ConPos [fty])])
    :: declEnvRowAtomEntries gctx rest
declEnvRowAtomEntries gctx (_ :: rest) = declEnvRowAtomEntries gctx rest

declEnvDeclFieldOwners : List Decl ->
  OrdMap (List String) ->
  OrdMap (List String)
declEnvDeclFieldOwners [] acc = acc
declEnvDeclFieldOwners ((DAttrib _ d) :: rest) acc =
  declEnvDeclFieldOwners (d :: rest) acc
declEnvDeclFieldOwners ((DData { dataCtors = vs }) :: rest) acc =
  declEnvDeclFieldOwners rest (declEnvVariantFieldOwners vs acc)
declEnvDeclFieldOwners (_ :: rest) acc = declEnvDeclFieldOwners rest acc

declEnvVariantFieldOwners : List Variant ->
  OrdMap (List String) ->
  OrdMap (List String)
declEnvVariantFieldOwners [] acc = acc
declEnvVariantFieldOwners ((Variant cn (ConNamed fields _)) :: rest) acc =
  declEnvVariantFieldOwners
    rest
    (addFieldOwners cn (map fieldNameOf fields) acc)
declEnvVariantFieldOwners (_ :: rest) acc = declEnvVariantFieldOwners rest acc

fieldNameOf : Field -> String
fieldNameOf (Field fn _) = fn

-- The reach filter of #1597: an earlier module's record votes in
-- `resolveFieldByOwners`' ambiguity test only if the reading module reaches it through
-- `DUse` edges.  Being earlier in the topological order is not reachability: a module
-- importing nothing was rejected because an unrelated module sorted first.  Only the
-- field-owner reader gets this extra conjunct; the ordinal prefix and the population
-- stay as they are, since `declEnvVisibleAt` is shared by four name-scoping tables.
-- The closure walks every `DUse` edge regardless of publicity, selectivity or
-- re-export, so it only removes a module the reader has no import path to at all; a
-- reachable module the reader may not legally name still votes.
--
-- Field-owner KEY → the module ids that declare it.  Same `DData`/`ConNamed` walk as
-- `declEnvDeclFieldOwners`, including the `DAttrib` unwrap, so the keys here are the
-- same strings that function puts in the seed.  A LIST, not a single id: two modules
-- may declare the same named-field constructor name, and collapsing them would drop a
-- legitimate owner.
declEnvOwnerModules : List DeclEnvModule ->
  OrdMap (List String) ->
  OrdMap (List String)
declEnvOwnerModules [] acc = acc
declEnvOwnerModules (m :: rest) acc =
  declEnvOwnerModules rest (declEnvDeclOwnerModules m.demId m.demDecls acc)

declEnvDeclOwnerModules : String ->
  List Decl ->
  OrdMap (List String) ->
  OrdMap (List String)
declEnvDeclOwnerModules _ [] acc = acc
declEnvDeclOwnerModules mid ((DAttrib _ d) :: rest) acc =
  declEnvDeclOwnerModules mid (d :: rest) acc
declEnvDeclOwnerModules mid ((DData { dataCtors = vs }) :: rest) acc =
  declEnvDeclOwnerModules mid rest (declEnvVariantOwnerModules mid vs acc)
declEnvDeclOwnerModules mid (_ :: rest) acc =
  declEnvDeclOwnerModules mid rest acc

declEnvVariantOwnerModules : String ->
  List Variant ->
  OrdMap (List String) ->
  OrdMap (List String)
declEnvVariantOwnerModules _ [] acc = acc
declEnvVariantOwnerModules mid ((Variant cn (ConNamed _ _)) :: rest) acc =
  declEnvVariantOwnerModules
    mid
    rest
    (omInsert cn (mid :: optionOr [] (omLookup cn acc)) acc)
declEnvVariantOwnerModules mid (_ :: rest) acc =
  declEnvVariantOwnerModules mid rest acc

-- The ONE call site of the two seeds, so a future third table cannot be added on
-- one side only — the same "one body per direction" property `loadDataUniverse`
-- was factored for, which is what these two lines LEFT.
--
-- Keyed by the loader MODULE ID, the same string `buildDeclEnvs` stamped the chain
-- under, so no ordinal arithmetic happens at the read.  The core pass arrives as
-- `""` — the spelling both drivers pass for it — and `buildDeclEnvs` registers that
-- key explicitly, exactly as `declEnvOrdIndex` does, so ordinal 0's empty seed is a
-- HIT rather than a miss that happens to agree.
--
-- A miss yields the empty seed, and the two halves then fail in opposite
-- DIRECTIONS.  Do not read this as one fail-CLOSED story — an earlier version of
-- this comment did, and it contradicted this same PR's own analysis two functions
-- up:
--   * OWNERS — fail-CLOSED, loud.  Zero owners makes `resolveFieldByOwners` take its
--     `[]` arm, `pushUnknownField`, exit 1.  A reader with an unknown id LOSES
--     cross-module owners and REJECTS; it cannot silently accept.
--   * KINDS — fail-SILENT.  A missing param-kind entry makes `fromAstTypeApp` fall
--     to `appFallback` instead of `foldAppKinds`, so a written row in a `KRow` slot
--     elaborates as an ordinary TYPE and the effect is erased at exit 0.  That is
--     #1069, the silent face of #804/#1028, and `opaque_export_row_kind_import`'s
--     own header calls it out.
--
-- The silent direction is new here, and saying so is the point of this note.
-- Before A-3.2b, `loadDataUniverse` copied the kind universe with no key at all, so
-- an unknown `mid` could not lose kinds — there was nothing to miss.  This unit
-- converted a key-free copy into a keyed lookup whose miss is `[]`.  The
-- REACHABILITY of an unknown `mid` is SUSPECTED-UNPROVEN in both directions
-- (nobody has constructed one, and the identical `declEnvsOrdOf` → `-1` dependency
-- already gates #1553's shipped ctor overlay, so the exposure is shared rather than
-- created here) — but the exposure's SEVERITY on the kind half is not the same as
-- the owner half's, and a future reader must not infer "loud" from this site.
--
-- The last two lines are #1597's half and they are not A THIRD SEED.  They do not
-- change WHAT is in `fieldOwnersRef`; they hand `fieldOwnerNames` the two facts it
-- needs to drop a vote at the READ.  `deOwnerModules` is graph-global (the same value
-- for every reader); `deReach` is indexed by the reading module, and a MISS yields the
-- empty set — which `fieldOwnerReachFilter` treats as "know nothing, filter nothing".
-- That is the fallback `#1597`'s own design note requires: a closure miss falls back
-- to today's prefix answer, never to `[]`.
export
declEnvSeedDataUniverse : ModuleCtx -> String -> DeclEnvs -> Unit
declEnvSeedDataUniverse mctx mid envs =
  mctx.mcCells.dataParamKindsRef :=
    optionOr [] (omLookup mid envs.deKindsBefore)
  -- #2158: the BARE-NAME half of the same seed, read under the same key and from
  -- the same fold (`declEnvSeedChain`'s third accumulator), so it holds exactly
  -- the `tabKeyName`s of the line above's keys by construction.
  -- This used to rebuild the index here — `omFromNames (map … kindsRef.value)`
  -- — and that was an O(M² log M) term, since the list it folded is
  -- `deKindsBefore[mid]`, whose length grows with the module ordinal.  Do not
  -- restore it: a rebuild off a per-module prefix list is quadratic by
  -- construction, and `stage_ir_scaling`'s `modules:typecheck` row is what
  -- catches it (2.219 → 2.500 against a 2.45 ceiling when it last landed).
  -- A MISS is fail-SILENT and STRICTLY BENIGN, unlike the kind half's: an empty
  -- index makes `noImplHintFor` withhold the "add deriving / write an impl"
  -- hint, so the reject still happens with its unhinted message.
  mctx.mcCells.dataParamNameIndexRef :=
    optionOr omEmpty (omLookup mid envs.deNameIndexBefore)
  -- #1119 D-2: the VARIANCE half of the same seed, read under the same key.  A
  -- MISS here is fail-SILENT in the same direction the kind half is (an absent
  -- row makes `unifyN`'s variance gate abstain, i.e. today's leniency) — it can
  -- lose a rejection, never manufacture one.
  mctx.mcCells.dataParamPolarityRef :=
    optionOr [] (omLookup mid envs.dePolaritiesBefore)
  -- #2110 S2-1: the ATOM-GUARANTEE half of the same seed, read under the same
  -- key.  A MISS here is fail-LOUD, not fail-silent like the two above: an
  -- absent row reads as "this declaration guarantees nothing", which is the
  -- pre-#2110 behaviour, so it can only over-reject.  That is why the table
  -- shipped without a seed at all and why the gap was recoverable.
  mctx.mcCells.dataParamRowAtomsRef :=
    optionOr [] (omLookup mid envs.deAtomsBefore)
  mctx.mcCells.fieldOwnersRef :=
    optionOr omEmpty (omLookup mid envs.deOwnersBefore)
  mctx.mcCells.fieldOwnerModulesRef := envs.deOwnerModules
  mctx.mcCells.fieldOwnerReachRef :=
    optionOr omEmpty (omLookup mid envs.deReach)

-- ── doctests ─────────────────────────────────────────────────────────────
-- Both conjuncts, on the kind projection: own row ⇒ everything; earlier row ⇒ the
-- kind-public projection; later row ⇒ nothing.
-- > listLen (declEnvRowKindEntries (probeGraphCtx ()) 0 (deKindRow0 (probeGraphCtx ())))
-- 4
-- > listLen (declEnvRowKindEntries (probeGraphCtx ()) 1 (deKindRow0 (probeGraphCtx ())))
-- 3
-- > listLen (declEnvRowKindEntries (probeGraphCtx ()) 0 (deKindRow1 (probeGraphCtx ())))
-- 0

-- The field-owner population: only a `ConNamed` variant votes, and it votes under
-- its CONSTRUCTOR name.
-- > optionOr [] (omLookup "x" (declEnvDeclFieldOwners [deFieldOwnerFixtureA] omEmpty))
-- ["Pt"]
-- > optionOr [] (omLookup "x" (declEnvDeclFieldOwners [deKindNewtypeFixture] omEmpty))
-- []

-- Both ident indexes are accumulated newest-first per key and reversed once here,
-- so the fold that fills them stays resumable (see `DeclEnvAcc`).
dataEnvFinish : DataEnv -> DataEnv
dataEnvFinish env = DataEnv { env |
  deRecordIdents = omMapValues reverseL env.deRecordIdents,
  deFieldOwnerIdents = omMapValues reverseL env.deFieldOwnerIdents,
}

dataEnvFromRowsGo : List DeclEnvModule -> DataEnv -> DataEnv
dataEnvFromRowsGo [] acc = acc
dataEnvFromRowsGo (m :: rest) acc =
  let env = dataEnvFromDeclsGo m.demOrd m.demDecls acc
  dataEnvFromRowsGo rest DataEnv { env |
    deCtorExports = ctorExportsInto m env.deCtorExports,
  }

export
dataEnvFromDeclsGo : Int -> List Decl -> DataEnv -> DataEnv
dataEnvFromDeclsGo _ [] acc = acc
dataEnvFromDeclsGo ord (d :: rest) acc =
  dataEnvFromDeclsGo ord rest (dataEnvAddDecl ord False d acc)

-- ONE decl into the index. [att] is True once a `DAttrib` wrapper has been
-- unwrapped on the way here; nested wrappers recurse (the parser can produce
-- `DAttrib [a] (DAttrib [b] d)`). The unwrap is uniform across all five tables, and
-- the attributed alias is dropped at the READ, not here. `publicDataDecl` needs no
-- `DAttrib` arm of its own because `adPub` is read off the inner decl this function
-- has already unwrapped.
--
-- `deTypes`/`deCtorIdents`/`deRecordIdents`/`deFieldOwnerIdents` all keep this
-- unwrap and are strict supersets on this axis, so `adAttrib` stays POPULATED here
-- even though the alias table filters it at read time: filtering it out of the
-- population instead would make two rows of one record answer "does an attributed
-- decl count?" by opposite mechanisms. `adAttrib` costs nothing to keep, it keeps
-- the population/read split legible, and the `listLen aliasFixtureEnv.deAliases`
-- doctest pins population neutrality.
dataEnvAddDecl : Int -> Bool -> Decl -> DataEnv -> DataEnv
dataEnvAddDecl ord _ (DAttrib _ d) acc = dataEnvAddDecl ord True d acc
dataEnvAddDecl ord _ (DData { dataName, dataParams, dataCtors, dataOrigin, ... }) acc =
  addDataTypeDecl dataName dataOrigin dataParams dataCtors acc
dataEnvAddDecl ord _ (DNewtype { newtypeName, newtypeParams, newtypeCtor, newtypeFieldTy, newtypeOrigin, ... }) acc =
  addDataTypeDecl
    newtypeName
    newtypeOrigin
    newtypeParams
    [Variant newtypeCtor (ConPos [newtypeFieldTy])]
    acc
-- `publicDataDecl d` — the shared predicate applied to the alias's own decl, not
-- a `tyAliasPub` read.  See `AliasDecl`'s note.
dataEnvAddDecl ord att (d@(DTypeAlias { tyAliasName, tyAliasParams, tyAliasRhs, tyAliasOrigin, ... })) acc =
  addAliasDecl
    tyAliasName
    tyAliasOrigin
    tyAliasParams
    tyAliasRhs
    ord
    (publicDataDecl d)
    att
    acc
dataEnvAddDecl _ _ _ acc = acc

addDataTypeDecl : String ->
  TyConOrigin ->
  List String ->
  List Variant ->
  DataEnv ->
  DataEnv
addDataTypeDecl name o params variants env =
  let key = tyTabKey o name
  let dt = DataTypeDecl {
    dtKey = key,
    dtName = name,
    dtOrigin = o,
    dtParams = params,
    dtVariants = variants,
  }
  addVariantIdentsRaw name o variants DataEnv { env |
    deTypes = (key, dt) :: env.deTypes,
  }

addVariantIdentsRaw : String ->
  TyConOrigin ->
  List Variant ->
  DataEnv ->
  DataEnv
addVariantIdentsRaw _ _ [] env = env
addVariantIdentsRaw tyName o ((Variant cn payload) :: rest) env =
  addVariantIdentsRaw tyName o rest (addCtorIdentRaw tyName o cn payload env)

-- Honest absence, exactly as `spInsert`'s callers: no module id ⇒ no identity ⇒
-- no candidate — `mkIdent` refuses `OriginUnresolved`/`OriginModule ""`.
addCtorIdentRaw : String ->
  TyConOrigin ->
  String ->
  ConPayload ->
  DataEnv ->
  DataEnv
addCtorIdentRaw tyName o cn payload env = match mkIdent NsCtor o cn
  None => env
  Some ident =>
    let next =
      optionOr [] (omLookup cn env.deCtorIdents)
        ++ [(ident, tyName, Variant cn payload)]
    let env2 =
      DataEnv { env | deCtorIdents = omInsert cn next env.deCtorIdents }
    match payload
      ConNamed fields _ => addRecordIdentRaw tyName cn ident fields env2
      ConPos _ => env2

-- ✅ FIXED (#2147): both `deRecordIdents` and `deFieldOwnerIdents` buckets used
-- to be `++ [x]` per insert — O(bucket²) over the build. Now conses onto each
-- key's bucket (reversing that bucket's visible order immediately, since these
-- are keyed `OrdMap (List ...)` buckets read-modify-written throughout the
-- whole fold, not one flat list reversed once at the end); `buildDataEnv`
-- restores order with one `omMapValues reverseL` pass over each map, once,
-- when the fold finishes. Values are byte-identical, only the fold is linear.
addRecordIdentRaw : String ->
  String ->
  Ident ->
  List Field ->
  DataEnv ->
  DataEnv
addRecordIdentRaw tyName cn ident fields env =
  let next =
    (ident, tyName, fields) :: optionOr [] (omLookup cn env.deRecordIdents)
  addFieldOwnerIdents ident cn fields DataEnv { env |
    deRecordIdents = omInsert cn next env.deRecordIdents,
  }

addFieldOwnerIdents : Ident -> String -> List Field -> DataEnv -> DataEnv
addFieldOwnerIdents _ _ [] env = env
addFieldOwnerIdents ident cn ((Field fn _) :: rest) env =
  let next = (ident, cn) :: optionOr [] (omLookup fn env.deFieldOwnerIdents)
  addFieldOwnerIdents ident cn rest DataEnv { env |
    deFieldOwnerIdents = omInsert fn next env.deFieldOwnerIdents,
  }

-- The prepend is the order contract, not an implementation detail.  Rows are
-- folded in ASCENDING ordinal, decls in declaration order, and each row is
-- CONSED — so `deAliases` reads back DESCENDING by ordinal, and within one
-- module in reverse declaration order.  That is byte-for-byte the order the
-- retired `CrossRun.universeAliasTable` had: `loadDataUniverse` seeded module
-- k's working table from the universe and `registerAllData` consed module k's
-- own public aliases onto its FRONT before `storeDataUniverse` wrote it back,
-- so the accumulator was `[k rev] ++ [k-1 rev] ++ … ++ [0 rev]` too.
-- Order is observable twice over: `lookupTab` is FIRST-match, and
-- `rejectCyclicAliases` builds its graph from this list in list order and
-- `emitCyclicAliasErrors` renders in that order into goldens.  See
-- `aliasUniverseAt`, which filters this list and therefore preserves it.
addAliasDecl : String ->
  TyConOrigin ->
  List String ->
  Ty ->
  Int ->
  Bool ->
  Bool ->
  DataEnv ->
  DataEnv
addAliasDecl name o params rhs ord pub att env =
  let key = tyTabKey o name
  let ad = AliasDecl {
    adKey = key,
    adName = name,
    adParams = params,
    adRhs = rhs,
    adOrd = ord,
    adPub = pub,
    adAttrib = att,
  }
  DataEnv { env | deAliases = (key, ad) :: env.deAliases }

-- #2110: the ATOM-GUARANTEE read, sibling of `paramPolaritiesOf`.  No builtin
-- rows: `Ref`/`Array` have no KRow parameter, so they guarantee no atoms and a
-- miss (`None`) already says exactly that.
export
paramRowAtomsOf : ModuleCtx -> TabKey -> Option (List (List Atom))
paramRowAtomsOf mctx key = lookupTab key mctx.mcCells.dataParamRowAtomsRef.value

-- WS-1c: the tyvar names appearing in a signature's `=>` CONSTRAINTS (not the value
-- type).  `tyVarNames` deliberately skips TyConstrained's constraints, so a constraint
-- var that NEVER appears in the value type (`Mk a => Int -> Int` — `a` only in `Mk a`)
-- was dropped from the fresh-var map and the generalized scheme: the scheme didn't
-- quantify `a`, so a call-site instantiation couldn't pin it (anyIdPinned False), the
-- call fell to the recursive-app path with empty ids → an empty dict → runtime
-- `intToString: not an Int` / a null build dict.  Including these names (deduped
-- against tyVarNames, so a constraint var ALSO in the value type is unaffected) lets
-- the constraint var be freshened + quantified like any other, so the undetermined
-- call routes through the normal pendingDictApps path (routeUndeterminedTop).
constraintVarNamesTy : Ty -> List String
constraintVarNamesTy (TyConstrained cs t) =
  flatMap constraintArgVarNames cs ++ constraintVarNamesTy t
constraintVarNamesTy (TyEffect _ _ t) = constraintVarNamesTy t
constraintVarNamesTy _ = []

constraintArgVarNames : Constraint -> List String
constraintArgVarNames (Constraint { constraintArgs = tys }) =
  flatMap tyVarNames tys

-- tyVarNames PLUS the signature's constraint-only vars (deduped).
tyVarNamesWithConstraints : Ty -> List String
tyVarNamesWithConstraints ty = dedup (tyVarNames ty ++ constraintVarNamesTy ty)

-- ── alias cycle detection (stage 4) ──────────────────────────────────────────
-- Collect all TyCon (type-constructor) names referenced anywhere in a surface
-- Ty.  Mirrors tyVarNames but for constructor slots.  TyVar names are alias
-- params and never alias dependencies, so they are excluded.
export
tyConNamesInTy : Ty -> List String
tyConNamesInTy (TyCon { tyConName = n }) = [n]
tyConNamesInTy (TyVar _) = []
tyConNamesInTy (TyApp a b) = tyConNamesInTy a ++ tyConNamesInTy b
tyConNamesInTy (TyFun a b) = tyConNamesInTy a ++ tyConNamesInTy b
tyConNamesInTy (TyTuple ts) = flatMap tyConNamesInTy ts
tyConNamesInTy (TyEffect _ _ t) = tyConNamesInTy t
tyConNamesInTy (TyRow _ _ _) = []
tyConNamesInTy (TyAuth _ _) = []
tyConNamesInTy (TyNamed _ t _) = tyConNamesInTy t
tyConNamesInTy (TyQual t _ _) = tyConNamesInTy t
tyConNamesInTy (TyConstrained cs t) =
  flatMap tyConNamesInConstraint cs ++ tyConNamesInTy t

tyConNamesInConstraint : Constraint -> List String
tyConNamesInConstraint (Constraint { constraintHead = iname, constraintArgs = tys }) =
  iname :: flatMap tyConNamesInTy tys

-- Collect all elements from the HEAD of a list up to and including `target`.
-- The on-stack list is newest-first; when a back-edge to `target` is detected,
-- everything from the head down to `target` (inclusive) is on the cycle path.
takeUntilInclusiveS : String -> List String -> List String
takeUntilInclusiveS _ [] = []
takeUntilInclusiveS target (x :: xs) =
  if x == target then [x] else x :: takeUntilInclusiveS target xs

-- Build the alias-dependency entry for one table entry: alias name → list of
-- other alias keys mentioned in its RHS (the dependency edges).
--
-- #1111 A-2.3 deliberately left this graph bare-NAME-KEYED, and it is the
-- one consumer of `aliasTableRef` that is not re-keyed.  Three reasons, in the
-- order that decided it:
--   * it is a DELETION pass, and its over-approximation is conservative in the
--     LOUD direction — two unrelated modules' aliases sharing a spelling, one
--     of them cyclic, drops both rows and reports `T-RECURSIVE-ALIAS` naming
--     the shared name.  Wrong-but-loud.  Re-keying could only ever make it
--     delete FEWER rows, and "recursive alias silently expanded" is the one
--     outcome this pass exists to prevent (it infinite-loops the expansion
--     seam);
--   * `tyConNamesInTy` yields bare `String`s from an arbitrary `Ty`, so an
--     identity-keyed graph needs an identity-carrying spine walk — the
--     comparison-reads-origin step the arc schedules as A-2.10, not a
--     re-key;
--   * it feeds `emitCyclicAliasErrors`, whose OUTPUT ORDER is observable in
--     goldens (see the enumeration-order bullet in `types/registry.mdk`).
-- `tabKeyName` is what makes the bare half explicit here rather than implicit.
buildAliasGraphEntry : OrdMap Unit ->
  (TabKey, (List String, Ty)) ->
  (String, List String)
buildAliasGraphEntry aliasSet (key, paramsRhs) =
  let rhs = snd paramsRhs
  (
    tabKeyName key,
    filterList (k => omHasKey k aliasSet) (dedup (tyConNamesInTy rhs)),
  )

-- DFS over the alias dependency graph.  Detects back-edges (a node is reached
-- while it is already on the current path) → cycle.  On a back-edge to `target`,
-- marks every node on the stack from the head down to and including `target` as
-- cyclic (they are all on the same cycle path).
-- `onStackRef` keeps the path in order (for `takeUntilInclusiveS`); `onStackSetRef`
-- mirrors it as a set for the membership test.  Both are updated together.
aliasDfsVisit : OrdMap (List String) ->
  Ref (OrdMap Unit) ->
  Ref (List String) ->
  Ref (OrdMap Unit) ->
  Ref (List String) ->
  String ->
  Unit
aliasDfsVisit graph visitedRef onStackRef onStackSetRef cyclicOut name =
  if omHasKey name !visitedRef then
    ()
  else if omHasKey name !onStackSetRef then
    cyclicOut := dedup (takeUntilInclusiveS name !onStackRef ++ !cyclicOut)
  else
    onStackRef := name :: !onStackRef
    onStackSetRef := omInsert name () !onStackSetRef
    aliasDfsVisitNeighbors
      graph
      visitedRef
      onStackRef
      onStackSetRef
      cyclicOut
      (optionOr [] (omLookup name graph))
    onStackRef := filterList (/= name) !onStackRef
    onStackSetRef := omDelete name !onStackSetRef
    visitedRef := omInsert name () !visitedRef

aliasDfsVisitNeighbors : OrdMap (List String) ->
  Ref (OrdMap Unit) ->
  Ref (List String) ->
  Ref (OrdMap Unit) ->
  Ref (List String) ->
  List String ->
  Unit
aliasDfsVisitNeighbors _ _ _ _ _ [] = ()
aliasDfsVisitNeighbors graph visitedRef onStackRef onStackSetRef cyclicOut (n :: ns) =
  aliasDfsVisit graph visitedRef onStackRef onStackSetRef cyclicOut n
  aliasDfsVisitNeighbors graph visitedRef onStackRef onStackSetRef cyclicOut ns

aliasDfsVisitAll : OrdMap (List String) ->
  Ref (OrdMap Unit) ->
  Ref (List String) ->
  Ref (OrdMap Unit) ->
  Ref (List String) ->
  List String ->
  Unit
aliasDfsVisitAll _ _ _ _ _ [] = ()
aliasDfsVisitAll graph visitedRef onStackRef onStackSetRef cyclicOut (k :: ks) =
  aliasDfsVisit graph visitedRef onStackRef onStackSetRef cyclicOut k
  aliasDfsVisitAll graph visitedRef onStackRef onStackSetRef cyclicOut ks

-- Each report is located at the alias's right-hand side, the type that refers
-- back to it, when the reading module declares the alias; an alias another
-- module declares is reported at the import that brings it in ([prog] is the
-- reading module's declarations), since its right-hand side is in another file.
emitCyclicAliasErrors : ModuleCtx ->
  List Decl ->
  List (TabKey, (List String, Ty)) ->
  List String ->
  Unit
emitCyclicAliasErrors mctx _ _ [] = ()
emitCyclicAliasErrors mctx prog table (name :: rest) =
  let reader = mctx.mcCells.currentModuleRef.value
  let named = filterList (e => tabKeyName (fst e) == name) table
  let loc = match find (e => aliasDeclaredBy reader (fst e)) named
    Some e => firstTyLoc (snd (snd e))
    None =>
      findMap
        (e => match tabKeyModule (fst e)
          Some owner =>
            importLocFor mctx.mcGraph.declEnvsRef.value.deReach prog owner
          None => None)
        named
  pushTypeErrorOnce
    (mctxAtIfSome loc mctx)
    "T-RECURSIVE-ALIAS"
    ("type alias `"
      ++ name
      ++ "` is recursive; a type alias cannot refer to itself, so declare a `data` type instead")
  emitCyclicAliasErrors mctx prog table rest

-- Does module [reader] declare the alias keyed [key]?  A key with no module
-- (a flat program's) is the reader's own.
aliasDeclaredBy : String -> TabKey -> Bool
aliasDeclaredBy reader key = match tabKeyModule key
  Some owner => owner == reader
  None => True

-- The module a key's declaration belongs to, if it names one.
tabKeyModule : TabKey -> Option String
tabKeyModule (TkIdent (Ident _ origin _)) =
  identOriginFold None (mid => Some mid) origin
tabKeyModule (TkBare _ _) = None

-- Cycle-detection pre-pass over aliasTableRef.  MUST run after the aliases are
-- in the table and BEFORE any fromAstType* call (which would infinite-loop on a
-- cyclic alias via the recursive expansion added in stages 2–3); a declaration's
-- fields elaborate during registration, so `registerDeclsAliasesFirst` and
-- `registerImportOverlay` run it between their alias and non-alias folds.
-- A rerun finds nothing new and the diagnostic is message-deduped.
-- For each alias found on a cycle:
--   (1) emits a deduped type_error naming the offending alias;
--   (2) removes it from aliasTableRef so the expansion seam falls through to an
--       opaque TCon and cannot recurse → no stack overflow.
-- [prog] is the reading module's declarations, whose imports locate a report of
-- an alias another module declares.
export
rejectCyclicAliases : ModuleCtx -> List Decl -> Unit
-- multi-line RHS: the indented `:=` form is legal but not seed-parseable yet (#1744)
-- lint-disable-next-line rule-prefer-assign-op
rejectCyclicAliases mctx prog =
  let table = mctx.mcCells.aliasTableRef.value
  -- BARE NAMES on purpose — see `buildAliasGraphEntry`.
  let aliasKeys = map (e => tabKeyName (fst e)) table
  let aliasSet = omFromNames aliasKeys omEmpty
  -- first entry wins a duplicate key, as `lookupAssoc` did over the list
  let graph =
    omFromPairs (reverseL (map (buildAliasGraphEntry aliasSet) table)) omEmpty
  let visitedRef = Ref omEmpty
  let onStackRef = Ref []
  let onStackSetRef = Ref omEmpty
  let cyclicOut = Ref []
  aliasDfsVisitAll graph visitedRef onStackRef onStackSetRef cyclicOut aliasKeys
  let cyclic = !cyclicOut
  emitCyclicAliasErrors mctx prog table cyclic
  let cyclicSet = omFromNames cyclic omEmpty
  setRef
    mctx.mcCells.aliasTableRef
    (filterList
      (entry => not (omHasKey (tabKeyName (fst entry)) cyclicSet))
      table)

-- like astTypeFresh but also returns the name→fresh-tyvar map (the same fresh
-- vars used in the Mono), so a caller can check post-unify whether each
-- annotation tyvar stayed a distinct unbound var (C3 AnnotationTooGeneral).
export
astTypeFreshTbl : ModuleCtx -> Ty -> (Mono, List (String, Mono))
astTypeFreshTbl outer ty = atSignature outer ty (mctx =>
  let rows = rowArgNames mctx ty
  let auths = authArgBindersIn mctx ty
  let etbl = sigVarsForWith mctx ty (dedup (effTailNames ty ++ rows)) auths
  let tvs = freshTvMap mctx (sigTyVarNames ty rows (map fst auths))
  (fromAstTypeE mctx etbl tvs ty, tvs))

-- A diagnostic a signature's elaboration raises without a span of its own
-- lands on the signature, not on whatever the walk last visited.
atSignature : ModuleCtx -> Ty -> (ModuleCtx -> a) -> a
atSignature mctx ty body = body (mctxAtIfSome (firstTyLoc ty) mctx)

-- a signature → a scheme quantifying its free tyvars
export
sigToScheme : ModuleCtx -> Ty -> Scheme
sigToScheme mctx ty = fst (sigToSchemeTvs mctx ty)

-- like sigToScheme but also returns the name→tyvar map it built, so a caller can
-- recover each constraint variable's quantified id and stable position for the
-- MethodPredicateSlot carrier.  The returned scheme carries those same ids, so a
-- call-site instantiation's subst maps them.
export
sigToSchemeTvs : ModuleCtx -> Ty -> (Scheme, List (String, Mono))
sigToSchemeTvs mctx ty = sigToSchemeTvsIn mctx [] ty

-- Interface methods contribute their enclosing declaration's kinds; qualified
-- signatures additionally obtain kinds from their resolved predicates.
export
sigToSchemeTvsIn : ModuleCtx ->
  List (String, List Kind) ->
  Ty ->
  (Scheme, List (String, Mono))
sigToSchemeTvsIn outer scope ty = atSignature outer ty (mctx =>
  let rows = rowArgNamesIn mctx (qualifiedKindScope mctx scope ty) ty
  let auths = authArgBindersIn mctx ty
  let tvs = freshTvMap mctx (sigTyVarNames ty rows (map fst auths))
  let etbl = sigVarsForWith mctx ty (dedup (effTailNames ty ++ rows)) auths
  (
    Forall
      (map monoTyvarId (map snd tvs))
      (map effvarIdOf etbl.svRows)
      (map authvarIdOf etbl.svAuths)
      []
      (bindingForceFromAst mctx etbl tvs ty)
      (fromAstTypeE mctx etbl tvs ty),
    tvs,
  ))

export
sigVarsFor : ModuleCtx -> Ty -> List String -> SigVars
sigVarsFor mctx ty rowNames =
  sigVarsForWith mctx ty rowNames (authArgBindersIn mctx ty)

-- The worker, given the signature's index-slot binders already walked once
-- (`authArgBindersIn` looks the head's kinds up per type application, so a
-- seam that also needs the names for its type-variable set walks once and
-- hands the result here).
sigVarsForWith : ModuleCtx ->
  Ty ->
  List String ->
  List (String, Param) ->
  SigVars
sigVarsForWith mctx ty rowNames auths =
  let named = namedArgTypes ty
  let authNames = map fst auths
  let uses =
    binderDomainsIn mctx.mcGraph ty ++ namedAtomBinders mctx.mcGraph ty ++ auths
  reportBinderDomains mctx ty uses
  let ranged =
    binderIsPattern
      mctx.mcGraph
      (namedArgDomains ty)
      (patternSlotNamesIn mctx ty)
  let sv = SigVars {
    svRows = freshEffMap mctx rowNames,
    svAuths =
      map
        (b => freshAuthBinderRanged mctx (ranged (fst b)) b)
        (filterList
          (b => authorityBinderBound named authNames (fst b))
          (dedupBinders uses [])),
  }
  reportUnboundAuthorityNames mctx ty sv
  sv

-- The type-variable names a signature quantifies as ORDINARY type variables:
-- everything written bare that is neither a row argument nor an authority
-- index argument (`Handle p` — kind-directed, like `Async e a`'s `e`).
sigTyVarNames : Ty -> List String -> List String -> List String
sigTyVarNames ty rows authNames =
  removeAllS (rows ++ authNames) (tyVarNamesWithConstraints ty)

-- Whether a signature's binder ranges over patterns (EFFECTS-SEMANTICS
-- §4.1).  A named argument says so itself, with the `*` of its written
-- domain; one without it ranges over the whole domain wherever it is used,
-- and a pattern slot it fills refuses it (`authArgOf`).  A bare name nothing
-- writes a range for inherits the range of the slots it fills: a pattern
-- slot anywhere makes it pattern-ranging, the meet of its slots' ranges.
binderIsPattern : GraphCtx ->
  List (String, Option EffAtomTy) ->
  List String ->
  String ->
  Bool
binderIsPattern gctx domains pats n = match lookupAssoc n domains
  Some (Some d) =>
    rangedOver gctx (EffLabel d.eatLabel d.eatOrigin) d.eatPattern
  Some None => False
  None => contains n pats

export
dedupBinders : List (String, Param) ->
  List (String, Param) ->
  List (String, Param)
dedupBinders [] acc = reverseL acc
dedupBinders ((n, top) :: rest) acc =
  if isSome (lookupAssoc n acc) then
    dedupBinders rest acc
  else
    dedupBinders rest ((n, top) :: acc)

-- ── #2110: `rowArgNamesIn` with the head'S declared atom guarantee ────────
-- Structurally identical to `rowArgNamesIn` (`tc_decls_types`) — same arms, same spine
-- match, same arity guard, same fallback — but each KRow-slot occurrence is
-- reported as a PAIR `(var, atoms this head's declaration charges at that
-- slot)` instead of a bare name.  `map fst (rowArgAtomsIn s t)` is
-- `rowArgNamesIn s t`, occurrence for occurrence; the two are kept as separate
-- walkers only because `rowArgNamesIn` has a dozen callers that want names.
--
-- Why the atoms are needed (the #2110 over-rejection).  `methodEffRetOccs`
-- padded every such occurrence to `(e, [])` — "this return position carries `e`
-- and guarantees nothing" — which is right for an ABSTRACT head and wrong for a
-- declared one.  `data Slot e = Slot (Unit -> <Stdout | e> Unit)` re-supplies
-- <Stdout> at every use of `Slot e`, including `Slot <>`, so the point-free
-- relay `stash : (Unit -> <Stdout | e> Unit) -> Slot e` launders nothing and
-- must be accepted.  `data Bare e = Bare (Unit -> <e> Unit)` guarantees
-- nothing, so the same relay into `Bare e` DOES launder (at `e := <>` the field
-- reads back `Unit -> <> Unit` and prints) and must stay rejected.  The two
-- differ ONLY in the declaration, which is why the evidence has to come from
-- the table and cannot be read off the use site.
--
-- An ABSTRACT head (the graded [scope] arm) guarantees nothing and keeps `[]`:
-- what `f e a` charges depends on the impl, so the declaration cannot say.
export
rowArgAtomsIn : ModuleCtx ->
  List (String, List Kind) ->
  Ty ->
  List (String, List Atom)
rowArgAtomsIn mctx scope (TyApp a b) =
  let kinded = match tyAppSpine (TyApp a b)
    (TyCon { tyConName = n, tyConOrigin = o }, args) =>
      rowArgAtomsApp mctx scope o n args
    (TyVar h, args) => rowArgAtomsVarApp mctx scope h args
    _ => None
  match kinded
    Some occs => occs
    None => rowArgAtomsIn mctx scope a ++ rowArgAtomsIn mctx scope b
rowArgAtomsIn mctx scope (TyFun a b) =
  rowArgAtomsIn mctx scope a ++ rowArgAtomsIn mctx scope b
rowArgAtomsIn mctx scope (TyTuple ts) = flatMap (rowArgAtomsIn mctx scope) ts
rowArgAtomsIn mctx scope (TyEffect _ _ t) = rowArgAtomsIn mctx scope t
rowArgAtomsIn mctx scope (TyConstrained _ t) = rowArgAtomsIn mctx scope t
rowArgAtomsIn mctx _ _ = []

rowArgAtomsApp : ModuleCtx ->
  List (String, List Kind) ->
  TyConOrigin ->
  String ->
  List Ty ->
  Option (List (String, List Atom))
rowArgAtomsApp mctx scope o n args =
  match lookupTab (tyTabKey o n) mctx.mcCells.dataParamKindsRef.value
    Some kinds if listLen kinds == listLen args =>
      Some
        (krowArgVarAtoms
            mctx.mcGraph
            kinds
            (optionOr [] (paramRowAtomsOf mctx (tyTabKey o n)))
            args
          ++ flatMap (rowArgAtomsIn mctx scope) args)
    _ => None

rowArgAtomsVarApp : ModuleCtx ->
  List (String, List Kind) ->
  String ->
  List Ty ->
  Option (List (String, List Atom))
rowArgAtomsVarApp mctx scope h args = match lookupAssoc h scope
  Some kinds if listLen kinds == listLen args =>
    Some
      (krowArgVarAtoms mctx.mcGraph kinds [] args
        ++ flatMap (rowArgAtomsIn mctx scope) args)
  _ => None

-- `krowArgVarNames`' pair-returning twin.  [decls] is the head's per-parameter
-- guarantee list, walked in lockstep with the kinds and the args; it runs out
-- (or was never registered) into `[]`, the no-guarantee verdict.
export
krowArgVarAtoms : GraphCtx ->
  List Kind ->
  List (List Atom) ->
  List Ty ->
  List (String, List Atom)
krowArgVarAtoms gctx [] _ _ = []
krowArgVarAtoms gctx _ _ [] = []
krowArgVarAtoms gctx (KRow :: ks) decls ((TyVar n) :: as2) =
  (n, optionOr [] (head decls)) :: krowArgVarAtoms gctx ks (restAtoms decls) as2
krowArgVarAtoms gctx (KRow :: ks) decls ((TyRow labels tails _) :: as2) =
  map
      (n =>
        (n, atomsNorm (atomsOfWritten gctx labels ++ optionOr [] (head decls))))
      tails
    ++ krowArgVarAtoms gctx ks (restAtoms decls) as2
krowArgVarAtoms gctx (_ :: ks) decls (_ :: as2) =
  krowArgVarAtoms gctx ks (restAtoms decls) as2

restAtoms : List (List Atom) -> List (List Atom)
restAtoms [] = []
restAtoms (_ :: rest) = rest

-- ONE walk over a PRELUDE declaration list, picking up each built-in class's declared
-- origin and its presence.  Only `DInterface` decls contribute, and only the four fixed
-- spellings — so the population is closed even though the walk is over a decl list.
export
builtinClassesOf : List Decl -> BuiltinClasses
builtinClassesOf decls = builtinClassesGo decls emptyBuiltinClasses

-- The presence bit is set only by a declaration with at least one method, so a
-- methodless `interface Num a` leaves its class absent and the three gates (#1539)
-- OFF.  A bare `declsNonEmpty`-shaped test (`≥1 declaration` rather than `≥1 method`)
-- would turn them ON for that declaration.  The ORIGIN is still set unconditionally:
-- the origin half's population is #1446's.
export
builtinClassesGo : List Decl -> BuiltinClasses -> BuiltinClasses
builtinClassesGo [] acc = acc
builtinClassesGo ((DAttrib _ d) :: rest) acc =
  builtinClassesGo rest (builtinClassesGo [d] acc)
builtinClassesGo ((DInterface { name, ifaceOrigin = o, methods, ... }) :: rest) acc =
  builtinClassesGo rest (builtinClassSet name o (isNonEmptyL methods) acc)
builtinClassesGo (_ :: rest) acc = builtinClassesGo rest acc

-- the CLOSED spelling→member map, written once.  A name that is not one of the four
-- contributes nothing, which is what makes `builtinClassesGo` safe to run over a decl
-- list that may contain user declarations (the flattened-prelude arm).
-- Presence and identity accumulate together: once a method-bearing declaration has
-- established a class, later modules cannot replace that identity. A methodless
-- declaration leaves the slot open for a later method-bearing declaration.
builtinClassSet : String ->
  TyConOrigin ->
  Bool ->
  BuiltinClasses ->
  BuiltinClasses
builtinClassSet "Num" _ _ acc
  | acc.bcNumPresent = acc
builtinClassSet "Num" o p acc =
  BuiltinClasses { acc | bcNum = o, bcNumPresent = acc.bcNumPresent || p }
builtinClassSet "Eq" _ _ acc
  | acc.bcEqPresent = acc
builtinClassSet "Eq" o p acc =
  BuiltinClasses { acc | bcEq = o, bcEqPresent = acc.bcEqPresent || p }
builtinClassSet "Ord" _ _ acc
  | acc.bcOrdPresent = acc
builtinClassSet "Ord" o p acc =
  BuiltinClasses { acc | bcOrd = o, bcOrdPresent = acc.bcOrdPresent || p }
builtinClassSet "Semigroup" _ _ acc
  | acc.bcSemigroupPresent = acc
builtinClassSet "Semigroup" o p acc = BuiltinClasses { acc |
  bcSemigroup = o,
  bcSemigroupPresent = acc.bcSemigroupPresent || p,
}
builtinClassSet _ _ _ acc = acc

-- ── data declarations → constructor schemes ───────────────────────────────
export
registerData : TcEnv -> Decl -> TcEnv
-- #1228 / #1586: THE `DAttrib` unwrap, and it is the uniform one.  Same shape as
-- `dataEnvAddDecl`'s (`dataEnvAddDecl ord _ (DAttrib _ d) = dataEnvAddDecl ord True d
-- acc`) and PR #1058's in `lowerDeclImpl`: unwrap and recurse, so nested wrappers
-- (`DAttrib [a] (DAttrib [b] d)`) reduce.  Before this arm an attributed decl fell
-- through the catch-all below and registered NOTHING — no constructor scheme (#1228),
-- and, because `registerVariants` → `registerNamedFieldVariants` →
-- `registerRecordInfoKeyed` is what writes `fieldOwnersRef`, no field-owner row
-- either (#1586, where the missing row let a genuinely ambiguous `.field` resolve
-- silently to the attributed record's unattributed rival).
--
-- This arm carries A SAME-diff obligation and it is discharged: `aliasVisibleTo`'s
-- `not ad.adAttrib` conjunct is GONE, per the re-add condition on `dataEnvAddDecl`.
-- An attributed `type` alias now expands both where it is DECLARED (this arm) and in
-- IMPORTERS (`aliasUniverseAt`); leaving the read guard standing would have expanded
-- it locally and kept it opaque cross-module, which is the mirror of the widening
-- that guard was added to prevent.
registerData env (DAttrib _ d) = registerData env d
registerData env (DData { dataName = name, dataParams = params, dataParamKinds = anns, dataCtors = variants, dataCtorBinders = binders, dataOrigin = o }) =
  registerVariants o env name params anns variants binders
-- DECLARATION MINT (#1110/#1111 A-2.3): `tyAliasOrigin` is the alias's own
-- identity, stamped by `stampDeclOrigins` at the module that declared it — the
-- same source `registerVariants` takes `dataOrigin`/`newtypeOrigin` from, and
-- for the same reason (see its note: it must not come from ambient state).
registerData env (DTypeAlias { tyAliasName = name, tyAliasParams = params, tyAliasRhs = rhs, tyAliasOrigin = o }) =
  -- #2121 / EFFECTS-SEMANTICS §6.2: an alias head's DECLARED kinds are recorded
  -- like a data head's (`recordDeclKinds`), so `type BoxAlias (e : Effect) a =
  -- Box e a` accepts a row at its `e` slot.  `headRemainingKinds` still
  -- abstains on an alias (it checks `aliasTableRef` first), so the
  -- graded-instance-head check is unaffected; only the row-slot readers see
  -- the entry.
  env.teDyn.dcModule.mcCells.aliasTableRef :=
    (tyTabKey o name, (params, rhs))
      :: env.teDyn.dcModule.mcCells.aliasTableRef.value
  env
registerData env (DNewtype { newtypeName = name, newtypeParams = params, newtypeParamKinds = anns, newtypeCtor = con, newtypeCtorBinders = binders, newtypeFieldTy = fty, newtypeOrigin = o }) =
  registerVariants o env name params anns [Variant con (ConPos [fty])] [binders]
-- #1557 A-3.5c: THE `DInterface` arm is gone, and its absence is the point.
-- #822 registered each interface type-parameter's slot kinds here, into
-- `ifaceParamKindsRef`, *"because every consumer must see the table BEFORE the first
-- signature is elaborated, which is exactly registerAllData's slot"*.  That timing
-- constraint dissolved with the table: neither surviving consumer reads a ref at all
-- — `declGradedScope` computes the kinds from the very declaration it is elaborating,
-- and stage K's `CE` computes them once in the driver PREAMBLE, before any module
-- walks.  An interface therefore contributes nothing to `registerData` and falls
-- through to the catch-all below.
registerData env _ = env

-- ── record metadata registration & instantiation ──────────────────────────
-- registerRecordInfoKeyed uses a distinct registry KEY and result TYPE name:
-- for a record they coincide, but a named-field data variant is keyed by its
-- constructor (DInterface) while its values have the data type (Decl).
-- (`o` is the DECLARATION's identity, carried down from `registerVariants` — see
-- its note.  It belongs to `typeName`, not to `key`: the result type is the data
-- type, and a named-field variant is keyed by its constructor.)
registerRecordInfoKeyed : ModuleCtx ->
  TyConOrigin ->
  String ->
  String ->
  List String ->
  List Kind ->
  List (String, KindAnn) ->
  List Field ->
  Unit
registerRecordInfoKeyed mctx o key typeName params kinds binders fields =
  let paramReprs = mintParamReprs mctx params kinds
  let tvs = ktypeTvs params kinds paramReprs
  let opened = existentialCells mctx binders
  recordExistentials mctx.mcGraph opened
  let etbl = sigVarsWithAuths opened (paramEtbl params kinds paramReprs)
  let result = applyParams (tconFrom o typeName) paramReprs
  let fieldMonos = map (recFieldMono mctx etbl tvs) fields
  let ri =
    RecordInfo
      (collectTyIds paramReprs)
      (collectAuthvarIds paramReprs ++ map (c => authvarId (snd c)) opened)
      result
      fieldMonos
      (omFromPairs (reverseL fieldMonos) omEmpty)
  mctx.mcCells.recordByNameRef :=
    omInsert key ri mctx.mcCells.recordByNameRef.value
  mctx.mcCells.fieldOwnersRef :=
    addFieldOwners key (map fst fieldMonos) mctx.mcCells.fieldOwnersRef.value

-- Add `key` as an owner of each of its field names in the field→owners multimap.
-- Order/dedup is not maintained here — fieldOwnerNames `sortUniqS`es the value on
-- read — so this only needs to preserve the SET of owner keys per field.
export
addFieldOwners : String ->
  List String ->
  OrdMap (List String) ->
  OrdMap (List String)
addFieldOwners _ [] m = m
addFieldOwners key (fn :: rest) m =
  addFieldOwners key rest (omInsert fn (key :: optionOr [] (omLookup fn m)) m)

-- DECLARATION MINT (#1110).  This head Mono becomes every constructor's scheme
-- RETURN type, so it is the head `headTyconMono` reads at every dispatch goal —
-- the goal side of the key whose impl side (`headTyconTy`) has had identity
-- since resolve started stamping.  `o` is `DData.dataOrigin` /
-- `DNewtype.newtypeOrigin`, threaded from `registerData`'s record pattern.
--
-- It must come from the decl, not from ambient state.  `registerAllData` runs
-- over `importedCtorTypeDecls` — OTHER modules' decls — so a "current module"
-- id would attribute every imported type to the importer.  That is the same
-- class of wrongness #1219 eliminated on the flat path, and it is why this unit
-- was blocked until the decl-layer carriers landed (#1225).
registerVariants : TyConOrigin ->
  TcEnv ->
  String ->
  List String ->
  List (Option KindAnn) ->
  List Variant ->
  List (List (String, KindAnn)) ->
  TcEnv
registerVariants o env name params anns variants binders =
  -- the head's kinds were recorded ahead of every declaration (`recordDeclKinds`)
  let kinds = declParamKinds env.teDyn.dcModule.mcGraph params anns
  -- #1119 D-2: the VARIANCE twin, registered in the same breath and from the
  -- same decl-borne identity, so the two tables cannot come to disagree about
  -- which declaration a key names.  It runs AFTER `recordParamKinds` only
  -- because reading order is irrelevant here; it must run BEFORE
  -- `addVariants` so a later declaration in the same list can compose with it.
  -- #2112: the seed (`seedParamPolarityFixpoint`) has already run the
  -- TRANSITIVE fixpoint for this key over every declaration it may compose
  -- with — including PRIVATE ones an export filter later drops — so a row it
  -- wrote is at least as tight as anything recomputed here from the table AS
  -- IT STANDS, and must not be shadowed by a lenient single-pass recompute
  -- prepended in front of it.  Only a key the seed never saw (a `registerData`
  -- call outside `registerAllData`) is computed here.
  match (lookupTab
    (tyTabKey o name)
    env.teDyn.dcModule.mcCells.dataParamPolarityRef.value)
    Some _ => ()
    None =>
      recordParamPolarities
        env.teDyn.dcModule
        o
        name
        (inferParamPolarities
          env.teDyn.dcModule.mcCells.dataParamPolarityRef.value
          params
          anns
          variants)
  -- #2110: the ATOM-GUARANTEE twin, registered in the same breath and from the
  -- same decl-borne identity for the same reason the polarity twin is.  Unlike
  -- that one it reads NO table, so its ordering among these three lines is free.
  recordParamRowAtoms
    env.teDyn.dcModule
    o
    name
    (inferParamRowAtoms env.teDyn.dcModule.mcGraph params variants)
  let paramReprs = mintParamReprs env.teDyn.dcModule params kinds
  let tvs = ktypeTvs params kinds paramReprs
  let etbl = paramEtbl params kinds paramReprs
  let paramTyIds = collectTyIds paramReprs
  let rowEffvarIds = collectRowEffvarIds paramReprs
  let authvarIds = collectAuthvarIds paramReprs
  let result = applyParams (tconFrom o name) paramReprs
  registerNamedFieldVariants
    env.teDyn.dcModule
    o
    name
    params
    kinds
    variants
    binders
  addVariants
    env
    tvs
    etbl
    paramTyIds
    rowEffvarIds
    authvarIds
    result
    variants
    (padCtorBinders variants binders)

-- The sole place that adds an entry to `dataParamKindsRef`.  (It is not the ref's only
-- writer: `declEnvSeedDataUniverse` replaces the whole list with stage K's projection at
-- the reading module's ordinal — it was `loadDataUniverse` copying a `GraphCtx.crossRun`
-- accumulator until A-3.2b — and `freshModuleCtx` re-inits it to `[]`.  Those set
-- the TABLE; this is the only thing that registers a TYPE.)  Prepends, so a later
-- registration shadows an earlier one
-- under `lookupAssoc`'s first-match — the module's own decls are registered as a FRONT
-- overlay over the data universe and therefore win, which is the ordering every reader
-- assumes (see the `dataEnv` binding in checkBodyImpl).
-- (`o` is the DECLARATION's identity — #1111 A-2.3; see `tyTabKey`.)
recordCtors : GraphCtx ->
  TyConOrigin ->
  String ->
  DataVis ->
  List String ->
  List Variant ->
  Unit
recordCtors gctx o name vis params variants =
  gctx.crossRun.universeDataCtors :=
    (tyTabKey o name, (vis, params, variants))
      :: gctx.crossRun.universeDataCtors.value

-- Called once per head, by `recordDeclKinds` ahead of the declarations
-- (`registerAllDataGo`): a constant-time prepend, never a scan of the table,
-- which grows with every imported module.
recordParamKinds : ModuleCtx -> TyConOrigin -> String -> List Kind -> Unit
recordParamKinds mctx o name kinds =
  let entry = (tyTabKey o name, kinds)
  mctx.mcCells.dataParamKindsRef :=
    entry :: mctx.mcCells.dataParamKindsRef.value
  -- #2158: keep the name-only index in lockstep — an insert here because this
  -- call only ADDS one key, where `declEnvSeedDataUniverse` REPLACES the whole
  -- table (it reads its module's whole prefix out of `deNameIndexBefore` in one
  -- `omLookup`).  A duplicate name insert is a harmless no-op (Set semantics),
  -- which is what makes "own registrations on TOP of the universe" work here
  -- without the index needing the list's ordering.
  mctx.mcCells.dataParamNameIndexRef :=
    omInsert name () mctx.mcCells.dataParamNameIndexRef.value

-- ── #2110: the ATOM-GUARANTEE half, third sibling of the two above ────────
-- Same key (`tyTabKey o name`), same prepend, same first-match read.  Per
-- parameter, the atoms this DECLARATION charges at every occurrence of that
-- parameter — the coverage evidence `methodEffRetOccs` needs to tell a wrapper
-- that re-supplies an atom (`data Slot e = Slot (Unit -> <Stdout | e> Unit)`,
-- where `Slot <>` still unfolds to a `<Stdout>`-performing field) from one that
-- swallows it (`data Bare e = Bare (Unit -> <e> Unit)`, where `Bare <>` hands
-- back a pure-typed function that prints).
--
-- The key is identity-bearing (`tyTabKey` carries the DECLARATION's
-- `TyConOrigin` — #1111 A-2.3), so a row can only ever answer for the very
-- declaration that wrote it.  An entry written while checking one module is not
-- visible to an importer (`publicDataDecls` drops `VisAbstract` before an
-- importer's `registerVariants` sees the decl), so the table is seeded per
-- module by `declEnvSeedDataUniverse` from `deAtomsBefore`, exactly like its
-- two siblings; see `declEnvRowAtomsChain`.  A MISS reads as "no guarantee"
-- (`[]`): an over-rejection, loud, never a launder.
recordParamRowAtoms : ModuleCtx ->
  TyConOrigin ->
  String ->
  List (List Atom) ->
  Unit
recordParamRowAtoms mctx o name atomss =
  let entry = (tyTabKey o name, atomss)
  mctx.mcCells.dataParamRowAtomsRef :=
    entry :: mctx.mcCells.dataParamRowAtomsRef.value

-- Per parameter, the atoms GUARANTEED at every one of its occurrences in the
-- declaration's fields.  Mirrors `inferParamKinds`/`inferParamPolarities`'
-- shape: one pass over `payloadAstTypes`, positional result.
--
-- Intersection, not union, and every occurrence counts — including the ones
-- that carry no labels at all.  `data D e = D (Unit -> <Stdout | e> Unit) (Inner
-- e)` guarantees NOTHING about `e`: a caller at `e := <>` can project the second
-- field and observe `e` through whatever `Inner`'s own slot is.  So a bare
-- `TyVar e` occurrence contributes the EMPTY atom list and drives the
-- intersection to empty, and an occurrence reached through another type's
-- application spine does the same — this table composes with nothing (contrast
-- `inferParamPolarities`, which reads the polarity table for the head and
-- therefore needs a fixpoint).  Non-composition is what makes it a plain
-- one-pass fact about this declaration alone, and it can only UNDER-report.
inferParamRowAtoms : GraphCtx -> List String -> List Variant -> List (List Atom)
inferParamRowAtoms gctx params variants =
  let fieldTys = flatMap (v => payloadAstTypes (variantPayload v)) variants
  map
    (p =>
      intersectDeclAtoms
        gctx
        (flatMap (t => paramRowAtomOccs gctx p t) fieldTys))
    params

-- Every occurrence of parameter [p] in [t], each reported with the atoms
-- WRITTEN beside it at that occurrence (a tail position `<Stdout | p>` reports
-- `[Stdout]`; every other occurrence reports `[]`).
paramRowAtomOccs : GraphCtx -> String -> Ty -> List (List Atom)
paramRowAtomOccs gctx p (TyVar n) = if n == p then [[]] else []
paramRowAtomOccs gctx _ (TyCon { tyConName = _ }) = []
paramRowAtomOccs gctx p (TyEffect labels tails t) =
  paramRowAtomsFor gctx p tails labels ++ paramRowAtomOccs gctx p t
paramRowAtomOccs gctx p (TyRow labels tails _) =
  paramRowAtomsFor gctx p tails labels
paramRowAtomOccs gctx p (TyFun a b) =
  paramRowAtomOccs gctx p a ++ paramRowAtomOccs gctx p b
paramRowAtomOccs gctx p (TyTuple ts) = flatMap (paramRowAtomOccs gctx p) ts
paramRowAtomOccs gctx p (TyApp a b) =
  paramRowAtomOccs gctx p a ++ paramRowAtomOccs gctx p b
paramRowAtomOccs gctx p (TyConstrained _ t) = paramRowAtomOccs gctx p t
paramRowAtomOccs gctx _ _ = []

-- The row's written atoms, once per tail var that IS [p] (a join names several).
paramRowAtomsFor : GraphCtx ->
  String ->
  List String ->
  List EffAtomTy ->
  List (List Atom)
paramRowAtomsFor gctx p tails labels =
  map (_ => atomsOfWritten gctx labels) (filterList (== p) tails)

-- The atoms present at EVERY occurrence, under the same subsumption relation
-- the coverage check itself uses (`atomsEscape`, so `<IO>` at one occurrence
-- covers a narrow atom at another, and a parameterized atom is kept only where
-- every occurrence's row admits it).  NO occurrences at all — a phantom
-- parameter — guarantees nothing, hence `[]`: the conservative verdict, since
-- nothing here may widen acceptance on a shape this pass cannot see.
intersectDeclAtoms : GraphCtx -> List (List Atom) -> List Atom
intersectDeclAtoms gctx [] = []
intersectDeclAtoms gctx (first :: rest) =
  filterList (x => allList (b => isEmptyL (atomsEscape gctx [x] b)) rest) first

-- one representation per param shared across all ctors: KType → fresh TVar,
-- KRow → a TEff wrapping a fresh effvar (the row the param stands for),
-- KAuth → a TAuth over a fresh authority variable named after the parameter.
mintParamReprs : ModuleCtx -> List String -> List Kind -> List Mono
mintParamReprs mctx (_ :: ps) (KType :: ks) =
  freshVar mctx () :: mintParamReprs mctx ps ks
mintParamReprs mctx (_ :: ps) (KRow :: ks) =
  TEff (EffRow [] (Some (freshEffvar mctx ()))) :: mintParamReprs mctx ps ks
mintParamReprs mctx (p :: ps) ((KAuth l pat) :: ks) =
  TAuth (AVar (freshAuthvarRanged mctx (dtopFor mctx.mcGraph l) pat (Some p)))
    :: mintParamReprs mctx ps ks
mintParamReprs mctx _ _ = []

-- KType param names → their TVar (the tvs map fromAstTypeE consults for tyvars)
ktypeTvs : List String -> List Kind -> List Mono -> List (String, Mono)
ktypeTvs (p :: ps) (KType :: ks) (r :: rs) = (p, r) :: ktypeTvs ps ks rs
ktypeTvs (p :: ps) (_ :: ks) (_ :: rs) = ktypeTvs ps ks rs
ktypeTvs _ _ _ = []

-- KRow param names → the effvar cell inside their TEff repr, so a field's `<e>`
-- and a nested `Async e a` row-arg resolve to the SAME cell the result carries;
-- KAuth param names → the authority cell inside their TAuth repr, so a field's
-- `String @p`, `<L p>` and `Other p` all name the cell the result carries.
paramEtbl : List String -> List Kind -> List Mono -> SigVars
paramEtbl params kinds reprs = SigVars {
  svRows = krowRows params kinds reprs,
  svAuths = kauthCells params kinds reprs,
}

kauthCells : List String -> List Kind -> List Mono -> List (String, Ref Authvar)
kauthCells (p :: ps) ((KAuth _ _) :: ks) ((TAuth (AVar cell)) :: rs) =
  (p, cell) :: kauthCells ps ks rs
kauthCells (p :: ps) (_ :: ks) (_ :: rs) = kauthCells ps ks rs
kauthCells _ _ _ = []

-- A constructor's existential binders (`C (p : Authority L) …`): each a fresh
-- authority the constructor's scheme quantifies beside the head's, and whose
-- id is recorded as existential so a PATTERN opens it rigid rather than
-- instantiating it flexible (`instantiateCtorPattern`).
existentialCells : ModuleCtx ->
  List (String, KindAnn) ->
  List (String, Ref Authvar)
existentialCells mctx binders =
  map
    (b => match snd b
      KindAuthority l o pat _ => (
        fst b,
        freshAuthvarRanged
          mctx
          (dtopFor mctx.mcGraph (EffLabel l o))
          (rangedOver mctx.mcGraph (EffLabel l o) pat)
          (Some (fst b)),
      )
      _ => (fst b, freshAuthvar mctx PUnit (Some (fst b))))
    binders

recordExistentials : GraphCtx -> List (String, Ref Authvar) -> Unit
recordExistentials gctx [] = ()
recordExistentials gctx cells =
  gctx.graphRun.anyExistentialsRef := True
  gctx.graphRun.ctorExistentialsRef :=
    fold
      (m c => IdMap.set (authvarId (snd c)) () m)
      gctx.graphRun.ctorExistentialsRef.value
      cells

-- positional with the variants; a short list (a decl synthesised without
-- one) reads as "no binders".
padCtorBinders : List Variant ->
  List (List (String, KindAnn)) ->
  List (List (String, KindAnn))
padCtorBinders [] _ = []
padCtorBinders (_ :: vs) (b :: bs) = b :: padCtorBinders vs bs
padCtorBinders (_ :: vs) [] = [] :: padCtorBinders vs []

krowRows : List String -> List Kind -> List Mono -> List (String, Ref Effvar)
krowRows (p :: ps) (KRow :: ks) ((TEff (EffRow _ (Some cell))) :: rs) =
  (p, cell) :: krowRows ps ks rs
krowRows (p :: ps) (_ :: ks) (_ :: rs) = krowRows ps ks rs
krowRows _ _ _ = []

-- a named-field data variant (`C { f : T, … }`, e.g. ast's DInterface) carries a
-- record-shaped payload: register its field layout keyed by the CONSTRUCTOR name
-- but with the DATA TYPE as result type, so `C { f, … }` patterns / `C { … }`
-- literals resolve (the positional ctor scheme is still added by addVariants).
-- (`o` is `tyName`'s declaration identity, carried from `registerVariants`.)
registerNamedFieldVariants : ModuleCtx ->
  TyConOrigin ->
  String ->
  List String ->
  List Kind ->
  List Variant ->
  List (List (String, KindAnn)) ->
  Unit
registerNamedFieldVariants mctx o tyName params kinds variants binders =
  registerNamedFieldVariantsGo
    mctx
    o
    tyName
    params
    kinds
    variants
    (padCtorBinders variants binders)

registerNamedFieldVariantsGo : ModuleCtx ->
  TyConOrigin ->
  String ->
  List String ->
  List Kind ->
  List Variant ->
  List (List (String, KindAnn)) ->
  Unit
registerNamedFieldVariantsGo mctx o tyName params kinds ((Variant cname (ConNamed fields _)) :: rest) (bs :: brest) =
  registerRecordInfoKeyed mctx o cname tyName params kinds bs fields
  registerNamedFieldVariantsGo mctx o tyName params kinds rest brest
registerNamedFieldVariantsGo mctx o tyName params kinds (_ :: rest) (_ :: brest) =
  registerNamedFieldVariantsGo mctx o tyName params kinds rest brest
registerNamedFieldVariantsGo mctx _ _ _ _ _ _ = ()

addVariants : TcEnv ->
  List (String, Mono) ->
  SigVars ->
  List Int ->
  List Int ->
  List Int ->
  Mono ->
  List Variant ->
  List (List (String, KindAnn)) ->
  TcEnv
addVariants env tvs etbl paramTyIds rowEffvarIds authvarIds result ((Variant cname payload) :: rest) (binders :: brest) =
  let opened = existentialCells env.teDyn.dcModule binders
  recordExistentials env.teDyn.dcModule.mcGraph opened
  let ctorEtbl = sigVarsWithAuths opened etbl
  reportUnboundAuthorityNamesIn
    env.teDyn.dcModule
    (payloadAstTypes payload)
    ctorEtbl
  -- a report from elaborating a field (a pattern slot a binder cannot fill)
  -- points at the constructor's fields
  let ctorType =
    foldrFun
      (payloadTypesE
        (mctxAtIfSome
          (firstTyLocList (payloadAstTypes payload))
          env.teDyn.dcModule)
        ctorEtbl
        tvs
        payload)
      result
  let env2 =
    addCtor
      env
      cname
      (Forall
        paramTyIds
        rowEffvarIds
        (authvarIds ++ map (c => authvarId (snd c)) opened)
        []
        pureRow
        ctorType)
  addVariants env2 tvs etbl paramTyIds rowEffvarIds authvarIds result rest brest
addVariants env _ _ _ _ _ _ _ _ = env

-- a constraint in a method's own `=>` context is method-level iff it mentions a
-- tyvar.  One over only interface params is a slot too: an impl head such as
-- `Pair b` leaves `Show2 (Pair b)` open, so the caller must supply its dict.
export
constraintIsMethodLevel : List String -> Constraint -> Bool
constraintIsMethodLevel typarams c =
  isNonEmptyL (constraintSlotDispatchVar typarams c)

-- [key] is a `methodSlotKey`.
export
methodDictArityOf : ModuleCtx -> String -> Int
methodDictArityOf mctx key =
  listLen
    (optionOr [] (lookupAssoc key mctx.mcCells.methodPredicateSlotsRef.value))

export
constraintIface : Constraint -> String
constraintIface (Constraint { constraintHead = n }) = n

export
constraintVarNames : Constraint -> List String
constraintVarNames (Constraint { constraintArgs = args }) =
  flatMap tyVarNames args

-- A type with every saturated alias occurrence replaced by its expansion, top
-- down, so an alias inside an expansion expands too: the type the written one
-- denotes (DICT-SEMANTICS §8 I4.3).  Type constructors keep the identity resolve
-- stamped on them, and an expansion is located at the occurrence it replaces.
-- An alias applied at the wrong arity stays as written, as `fromAstTypeApp`
-- leaves it, so its `T-ALIAS-ARITY` is still reported where the head elaborates.
-- [seen] holds the aliases expanded on the current path, so a cyclic alias
-- stops; `rejectCyclicAliases` reports it.
tyAliasNormalForm : List (TabKey, (List String, Ty)) -> List TabKey -> Ty -> Ty
tyAliasNormalForm aliases seen ty = match aliasExpansionStep aliases ty
  Some (key, rhs) if not (anyList (k => tabKeyEq k key) seen) =>
    tyAliasNormalForm aliases (key :: seen) (locateTyAt (firstTyLoc ty) rhs)
  _ => tyAliasNormalFormKids aliases seen ty

-- The children of a type that is not itself an alias occurrence.  An applied
-- constructor's arguments are visited but its partial applications are not,
-- since `fromAstTypeApp` reads an alias's arity off the whole spine.
tyAliasNormalFormKids : List (TabKey, (List String, Ty)) ->
  List TabKey ->
  Ty ->
  Ty
tyAliasNormalFormKids aliases seen (TyApp a b) = match tyAppSpine (TyApp a b)
  (h@(TyCon { tyConName = _ }), args) =>
    fold (acc arg => TyApp acc (tyAliasNormalForm aliases seen arg)) h args
  _ =>
    TyApp (tyAliasNormalForm aliases seen a) (tyAliasNormalForm aliases seen b)
tyAliasNormalFormKids aliases seen (TyFun a b) =
  TyFun (tyAliasNormalForm aliases seen a) (tyAliasNormalForm aliases seen b)
tyAliasNormalFormKids aliases seen (TyTuple ts) =
  TyTuple (map (tyAliasNormalForm aliases seen) ts)
tyAliasNormalFormKids aliases seen (TyEffect es tails t) =
  TyEffect es tails (tyAliasNormalForm aliases seen t)
tyAliasNormalFormKids aliases seen (TyNamed n t d) =
  TyNamed n (tyAliasNormalForm aliases seen t) d
tyAliasNormalFormKids aliases seen (TyQual t ps l) =
  TyQual (tyAliasNormalForm aliases seen t) ps l
tyAliasNormalFormKids aliases seen (TyConstrained cs t) =
  TyConstrained cs (tyAliasNormalForm aliases seen t)
tyAliasNormalFormKids _ _ t = t

-- One saturated alias application at the root of [ty], expanded once: the
-- alias's key and its right-hand side with the arguments substituted.
aliasExpansionStep : List (TabKey, (List String, Ty)) ->
  Ty ->
  Option (TabKey, Ty)
aliasExpansionStep aliases ty = match tyAppSpine ty
  (TyCon { tyConName = n, tyConOrigin = o }, args) =>
    let key = tyTabKey o n
    match lookupTab key aliases
      Some (params, rhs) if listLen params == listLen args =>
        Some (key, substAliasArgs (zipL params args) rhs)
      _ => None
  _ => None

-- [ty] with each constructor that has no span of its own located at [loc].
-- `substAliasArgs` clears the spans of an alias's right-hand side, which was
-- written at the alias declaration, not where the expansion now stands.
locateTyAt : Option Loc -> Ty -> Ty
locateTyAt None ty = ty
locateTyAt loc ty =
  fst
    (mapTyFull
      (t => match t
        TyCon { tyConLoc = None } => (TyCon { t | tyConLoc = loc }, True)
        _ => (t, False))
      ty)

-- Interface method rows: each method's declaration identity, bare scheme, and
-- method-level predicate slots are constructed together.  The walk deliberately admits
-- only direct DInterface declarations; attributed-only interfaces retain their historical
-- absence from the method scheme environment.
export
ifaceMethodSchemeRows : ModuleCtx -> List Decl -> List MethodSchemeRow
ifaceMethodSchemeRows mctx decls =
  flatMap (directIfaceSchemeRows mctx) (directInterfaceDecls decls)

-- The environment and exported supplier tags must admit exactly the same
-- declarations, including the historical attributed-interface exclusion.
directInterfaceDecls : List Decl -> List Decl
directInterfaceDecls decls = filterList isDirectInterfaceDecl decls

isDirectInterfaceDecl : Decl -> Bool
isDirectInterfaceDecl (DInterface {  }) = True
isDirectInterfaceDecl _ = False

directIfaceSchemeRows : ModuleCtx -> Decl -> List MethodSchemeRow
directIfaceSchemeRows mctx (DInterface { name, typarams, typaramKinds, methods, ifaceOrigin, ... }) =
  methodSchemeRows
    mctx
    (declGradedScope mctx.mcGraph typarams typaramKinds methods)
    IfaceRef { irName = name, irOrigin = ifaceOrigin }
    typarams
    methods
directIfaceSchemeRows mctx _ = []

-- Exactly one `sigToSchemeTvsIn` allocation per row.  Slots are computed from that
-- allocation's tv map and quantified-id order, then installed at the same construction
-- point before the row is exposed to any projection.
methodSchemeRows : ModuleCtx ->
  List (String, List Kind) ->
  IfaceRef ->
  List String ->
  List IfaceMethod ->
  List MethodSchemeRow
methodSchemeRows mctx _ _ _ [] = []
methodSchemeRows mctx scope iface typarams ((IfaceMethod mname mty _ _) :: rest) =
  let (scheme, tvs) = sigToSchemeTvsIn mctx scope mty
  let slots =
    methodPredicateSlotsOfType mctx typarams mty tvs (schemeIds scheme)
  installMethodPredicateSlots mctx (methodSlotKey iface mname) slots
  MethodSchemeRow {
      msrIface = iface,
      msrName = mname,
      msrTyparams = typarams,
      msrType = mty,
      msrScheme = scheme,
      msrPredicateTemplate = MethodPredicateTemplate {
        mptInterface = iface,
        mptArguments = methodInterfacePredicateTemplate typarams tvs,
      },
      msrMethodSlots = slots,
    }
    :: methodSchemeRows mctx scope iface typarams rest

methodInterfacePredicateTemplate : List String ->
  List (String, Mono) ->
  List (Option Mono)
methodInterfacePredicateTemplate [] _ = []
methodInterfacePredicateTemplate (param :: rest) tvs =
  lookupAssoc param tvs :: methodInterfacePredicateTemplate rest tvs

-- ── #259 / DICT §8 I7 (literals): the numeric literal's anchor ──────────────────
--
-- I7 fixes the class a numeric LITERAL demands to the PRELUDE's `Num`, and therefore
-- fixes the method it is modelled through to that interface's own `fromInt`.  Before
-- this, `inferNumLit` asked `lookupVar env "fromInt"` — a bare-name lookup in the USER's
-- TERM scope — so ANY binding spelled `fromInt` (top level, `let`, or a parameter), never
-- called, re-anchored every literal in its lexical scope to that binding's type.  #259:
-- `fromInt : Int -> Float` + `println (7 / 2)` printed `3.5` under `run` and `3` from the
-- built binary, exit 0, empty stderr, on a program `check` accepts.
--
-- The successor asks the interface question and takes the interface answer: pick the
-- scheme whose key is (an interface DECL-identical to `builtinIfaceRef BNum`, `fromInt`)
-- out of the very rows env setup already built.  A user term binding contributes no row
-- to that list at all, so no spelling can reach it — this removes the read, it does not
-- special-case the name.
--
-- Selected from the already-minted rows, never re-elaborated.  A second
-- `sigToSchemeTvsIn` here would hand `recordMethodDicts` a scheme whose ids no constraint
-- row is keyed by, besides shifting every downstream id.
--
-- Identity, not spelling: `sameIfaceDecl` (the one total mint, #1647) — two STAMPED
-- occurrences match on `(module, name)`, two UNSTAMPED ones by spelling, stamped never
-- matches unstamped.  A MISS is loud in the honest direction: `inferNumLit` falls to
-- `inferNumLitBare`, which is exactly the no-prelude arm (a fresh `Num`-obligated var,
-- route RNone ⇒ Int), never a user binding's type.
--
-- The literal's impl-coverage obligation is recorded against the interface selected
-- by identity here, not by a method-name lookup (#2157).  A user module declaring
-- `interface Buildable c where fromInt : Int -> c` registers a second row under the
-- key "fromInt" in the per-module table, and a by-name lookup would then demand
-- `Buildable` instead of `Num` for every numeric literal in that module, on a program
-- with no shadow of any kind.  The misfire needs only the interface declaration, no
-- impl and no use (`test/shadow_fixtures/x9_*`, `x10_*`).  The selected row is the
-- only source for the occurrence's scheme, declared type, interface identity and
-- method-level slots: a second declaration walk could pair those fields from
-- different duplicate declarations.
export
seedNumLitFromIntAnchor : ModuleCtx -> List MethodSchemeRow -> Unit
seedNumLitFromIntAnchor mctx rows =
  mctx.mcCells.numLitFromIntAnchorRef :=
    pickNumLitRow (builtinIfaceRef mctx.mcGraph BNum) "fromInt" rows

-- Numeric seeding retains the stricter declaration-identity comparison.  The general
-- admitted-method lookup below deliberately uses `sameTyConHead`; these policies serve
-- different compatibility paths and must not be merged.
pickNumLitRow : IfaceRef ->
  String ->
  List MethodSchemeRow ->
  Option MethodSchemeRow
pickNumLitRow _ _ [] = None
pickNumLitRow iface mname (row :: rest)
  | row.msrName == mname && sameIfaceDecl row.msrIface iface = Some row
  | otherwise = pickNumLitRow iface mname rest

-- Like the row builder but WITHOUT the installMethodPredicateSlots side effect — for
-- callers (inferOneIfaceDefaults) that only need the schemes to look up a method's
-- own type and must not double-register methodPredicateSlotsRef entries (those are
-- registered once during ifaceMethodSchemeRows at env setup).
export
methodSchemesPure : ModuleCtx ->
  List (String, List Kind) ->
  List IfaceMethod ->
  List (String, Scheme)
methodSchemesPure mctx _ [] = []
methodSchemesPure mctx scope ((IfaceMethod mname mty _ _) :: rest) =
  (mname, fst (sigToSchemeTvsIn mctx scope mty))
    :: methodSchemesPure mctx scope rest

-- Install the precomputed row slots through the historical first-write guard.  Empty
-- method contexts remain absent, and the preserved Flat second row construction cannot
-- replace the first build's allocation-local ids.  [key] is a `methodSlotKey`.
installMethodPredicateSlots : ModuleCtx ->
  String ->
  List MethodPredicateSlot ->
  Unit
installMethodPredicateSlots mctx key slots =
  if isEmptyL slots
    || isSome (lookupAssoc key mctx.mcCells.methodPredicateSlotsRef.value) then
    ()
  else
    setMethodPredicateSlotEntry mctx key slots

-- The sole per-run method-carrier writer.  Predicate identity, bound ids, and stable
-- positions arrive in one record-valued payload, so no split writer or absence-based
-- fallback can disagree about slot count or order.
setMethodPredicateSlotEntry : ModuleCtx ->
  String ->
  List MethodPredicateSlot ->
  Unit
setMethodPredicateSlotEntry mctx key slots =
  mctx.mcCells.methodPredicateSlotsRef :=
    (key, slots) :: mctx.mcCells.methodPredicateSlotsRef.value

methodPredicateSlotsOfType : ModuleCtx ->
  List String ->
  Ty ->
  List (String, Mono) ->
  List Int ->
  List MethodPredicateSlot
methodPredicateSlotsOfType mctx typarams (TyConstrained cs t) tvs fullIds =
  flatMap (constraintMethodPredicateSlot mctx typarams tvs fullIds) cs
    ++ methodPredicateSlotsOfType mctx typarams t tvs fullIds
methodPredicateSlotsOfType mctx typarams (TyEffect _ _ t) tvs fullIds =
  methodPredicateSlotsOfType mctx typarams t tvs fullIds
methodPredicateSlotsOfType mctx _ _ _ _ = []

constraintMethodPredicateSlot : ModuleCtx ->
  List String ->
  List (String, Mono) ->
  List Int ->
  Constraint ->
  List MethodPredicateSlot
constraintMethodPredicateSlot mctx typarams tvs fullIds c
  | not (constraintIsMethodLevel typarams c) = []
  | otherwise =
    let bound = constraintNameMonos (constraintVarNames c) tvs
    let ids = map monoTyvarId bound
    [
      MethodPredicateSlot {
        mpsPredicate = PredicateSlot {
          psIface = IfaceRef {
            irName = constraintIface c,
            irOrigin = c.constraintOrigin,
          },
          psArgs = PSArgsKnown (map (fromAstType mctx tvs) c.constraintArgs),
          psBoundIds = ids,
        },
        mpsPositions = map (id => optionOr (0 - 1) (elemIndex id fullIds)) ids,
      },
    ]

-- S0-3: the polarity pre-seed runs here, once per call, and this is the
-- Reason the fold moved into A `…Go` HELPER.  `registerData` →
-- `registerVariants` → `recordParamPolarities` infers each decl's variance
-- against `dataParamPolarityRef` as it stands at that decl, so a wrapper
-- declared above the type it wraps read the lenient `PCo` default and never
-- tightened (see `declEnvPolarityEntriesFix`).  Seeding the ref with the
-- fixpoint over THIS CALL'S OWN decl list first makes the per-decl walk
-- find the seeded row and skip the recompute (`registerVariants` recomputes
-- only a key the table lacks).  The seeded row is the published one, with
-- "no occurrence" read as `PCo`, so it is NOT a fixpoint of one more pass
-- over itself: a pass reading a published phantom slot as `PCo` can tighten.
-- That is why the skip, not a recompute, is what keeps the seed.
--
-- The fixpoint scope is exactly the registration scope — [ds], never `prog`
-- reached from ambient state.  Two of this function's four call sites pass a
-- SUBSET (`importedCtorTypeDeclsLastWins …` on the Module arm's `base`, and
-- `publicDataDecls prog0` in `appendDataUniverse`), and seeding from a subset
-- is SAFE but not complete: an entry whose head is outside [ds] still reads
-- whatever the incoming table holds, exactly as it did before, so the pre-seed
-- can only tighten relative to today and never invents a verdict from an
-- incomplete list.  A forward reference from a public decl to a PRIVATE one
-- therefore still under-tightens at `appendDataUniverse` — the same visibility
-- filtering `declEnvRowPolarityEntries`' `kindPublicDataDecl` arm already
-- applies, a pre-existing scope question and not this order-sensitivity fix.
export
registerAllData : TcEnv -> List Decl -> TcEnv
registerAllData env ds = registerAllDataScoped env ds ds

-- #2112: register [ds], but run the polarity fixpoint over [allDs] — the
-- WHOLE declaration list [ds] was filtered from — and keep only [ds]'s own
-- keys.  `appendDataUniverse` registers a module's PUBLIC data into the
-- universe; a public wrapper over a PRIVATE write/contra-channel type must
-- still compose against the private declaration (the fixpoint's INPUT set is
-- not its EXPORT set — the same split `declEnvRowPolarityEntries` makes on the
-- cross-module chain), or the universe holds a lenient `PCo` row for the
-- wrapper that every importer then reads first.
export
registerAllDataScoped : TcEnv -> List Decl -> List Decl -> TcEnv
registerAllDataScoped env ds allDs =
  seedParamPolarityFixpointScoped env.teDyn.dcModule ds allDs
  registerAllDataGo env ds

-- Every head's declared kinds are recorded before any declaration's fields
-- elaborate, so a field may name a head declared later in the same list
-- (`data A (p : Authority L) = A (H p)` above `data H (p : Authority L)`).
registerAllDataGo : TcEnv -> List Decl -> TcEnv
registerAllDataGo env ds =
  each (recordDeclKinds env.teDyn.dcModule) ds
  registerDeclsAliasesFirst env ds

-- Aliases enter the alias table ahead of every other declaration, so a field
-- naming an alias declared later in the list expands the same as one naming an
-- alias declared above it.  An alias adds no env entry, so the split fold only
-- changes the table's contents by the time fields elaborate.  The table then
-- holds every alias the fields can name, cyclic ones included, so cycles are
-- rejected between the two folds: a field naming a cyclic alias would
-- otherwise expand it forever.
registerDeclsAliasesFirst : TcEnv -> List Decl -> TcEnv
registerDeclsAliasesFirst env ds =
  let env1 = fold (e d => if isAliasDecl d then registerData e d else e) env ds
  rejectCyclicAliases env.teDyn.dcModule ds
  fold (e d => if isAliasDecl d then e else registerData e d) env1 ds

-- Only `type` declares an alias, so the wildcard is right for every other Decl.
export
isAliasDecl : Decl -> Bool
isAliasDecl (DAttrib _ d) = isAliasDecl d
isAliasDecl (DTypeAlias { ... }) = True
isAliasDecl _ = False

export
recordDeclKinds : ModuleCtx -> Decl -> Unit
recordDeclKinds mctx (DAttrib _ d) = recordDeclKinds mctx d
recordDeclKinds mctx (DData { dataVis = vis, dataName = name, dataParams = params, dataParamKinds = anns, dataCtors = variants, dataOrigin = o }) =
  recordCtors mctx.mcGraph o name vis params variants
  recordParamKinds mctx o name (declParamKinds mctx.mcGraph params anns)
recordDeclKinds mctx (DNewtype { newtypePub = pub, newtypeName = name, newtypeParams = params, newtypeParamKinds = anns, newtypeCtor = con, newtypeFieldTy = fty, newtypeOrigin = o }) =
  let vis = if pub then VisPublic else VisAbstract
  recordCtors mctx.mcGraph o name vis params [Variant con (ConPos [fty])]
  recordParamKinds mctx o name (declParamKinds mctx.mcGraph params anns)
recordDeclKinds mctx d = recordDeclParamKinds mctx d

recordDeclParamKinds : ModuleCtx -> Decl -> Unit
recordDeclParamKinds mctx d = match declKindEntry mctx.mcGraph d
  Some (o, name, kinds) => recordParamKinds mctx o name kinds
  None => ()

-- Only a data, newtype or alias head declares parameter kinds; every other
-- declaration has none to record.
declKindEntry : GraphCtx -> Decl -> Option (TyConOrigin, String, List Kind)
declKindEntry gctx (DAttrib _ d) = declKindEntry gctx d
declKindEntry gctx (DData { dataName = name, dataParams = params, dataParamKinds = anns, dataOrigin = o }) =
  Some (o, name, declParamKinds gctx params anns)
declKindEntry gctx (DNewtype { newtypeName = name, newtypeParams = params, newtypeParamKinds = anns, newtypeOrigin = o }) =
  Some (o, name, declParamKinds gctx params anns)
declKindEntry gctx (DTypeAlias { tyAliasName = name, tyAliasParams = params, tyAliasParamKinds = anns, tyAliasOrigin = o }) =
  Some (o, name, declParamKinds gctx params anns)
declKindEntry gctx _ = None

-- Runs `k` with the declared kinds of `ds` in the table of [mctx], the current
-- record, then puts the table back as it was. A reader that elaborates signatures
-- against declarations whose own pass comes later (the extern catalog against the prelude) sees
-- their kinds, and that later pass still records each head once, so no
-- lookup scans a duplicate row. Only a head with a parameter whose kind is
-- not `Type` is recorded: every other head reads as it does with no entry,
-- which is how the catalog read before any prelude head declared a kind.
export
withDeclParamKinds : ModuleCtx -> List Decl -> (Unit -> a) -> a
withDeclParamKinds mctx ds k =
  let kinds = mctx.mcCells.dataParamKindsRef.value
  let names = mctx.mcCells.dataParamNameIndexRef.value
  each (recordDeclaredKinds mctx) ds
  let result = k ()
  mctx.mcCells.dataParamKindsRef := kinds
  mctx.mcCells.dataParamNameIndexRef := names
  result

recordDeclaredKinds : ModuleCtx -> Decl -> Unit
recordDeclaredKinds mctx d = match declKindEntry mctx.mcGraph d
  Some (o, name, kinds) if anyList kindIsDeclared kinds =>
    recordParamKinds mctx o name kinds
  _ => ()

export
kindIsDeclared : Kind -> Bool
kindIsDeclared KType = False
kindIsDeclared _ = True

-- like astTypeFresh but also returns the tyvar-name → fresh-var map
export
instantiateSigTracked : ModuleCtx ->
  Ty ->
  (Mono, List (String, Mono), Option EffRow)
instantiateSigTracked outer ty = atSignature outer ty (mctx =>
  let rows = rowArgNames mctx ty
  let auths = authArgBindersIn mctx ty
  let tvs = freshTvMap mctx (sigTyVarNames ty rows (map fst auths))
  let etbl = sigVarsForWith mctx ty (dedup (effTailNames ty ++ rows)) auths
  (fromAstTypeE mctx etbl tvs ty, tvs, writtenBindingForce mctx etbl tvs ty))

export
constraintNameMonos : List String -> List (String, Mono) -> List Mono
constraintNameMonos [] _ = []
constraintNameMonos (n :: rest) tvMap = match lookupAssoc n tvMap
  Some mono => mono :: constraintNameMonos rest tvMap
  None => constraintNameMonos rest tvMap

-- #154 PR-A: grow the persistent DATA-universe by [pubDecls] (THIS module's public data).
-- `registerData` / `registerVariants` hardcode the working table refs, so grow by
-- pointing those refs at the persistent values, registering pubDecls over the accumulated
-- ctor floor, and reading the results back into the two populations.  Called at the END
-- of checkBodyImpl's Module arm, where the working table refs are DEAD (this module's
-- inference is done and the next module's `freshModuleCtx` wipes them), so the clobber is
-- invisible.  Registers each public decl exactly ONCE across the whole run — the O(N)
-- replacing the Module arm's old per-module O(|accData|) re-registration.  Only
-- publicDataDecls are folded in (private data stays module-local).
--
-- The data universe has two halves, and only one of them is cross-run:
--   * CROSS-RUN: `universeCtorPop` and `universeRecordPop`, one `SpellingPop` per table.
--     Their payload is ELABORATED (`Scheme`, `RecordInfo`), which stage K, being
--     syntactic, cannot hold.  Each population's floor is what a module starts from: the
--     ctor floor is the base env of the Module arm's `dataEnv` (`withCtors`), the record
--     floor is loaded into `recordByNameRef` below.  Nothing copies a per-run table back:
--     `appendDataUniverse` inserts into the populations directly.
--   * STAGE K: a PROJECTION at the reader's own ordinal, with nothing to write back.
--     Only one of the three is seeded in the body below.  The other two are seeded at
--     the one call of `declEnvSeedDataUniverse mid envs`, in `checkBodyImpl`'s Module
--     arm.  Anchor on the seeder, not on a line number:
--       `aliasTableRef`      ← `aliasUniverseAt cur … .deData.deAliases`  — HERE
--       `dataParamKindsRef`  ← `declEnvSeedDataUniverse mid …`
--       `fieldOwnersRef`     ← `declEnvSeedDataUniverse mid …`
-- Do NOT add a `GraphCtx.crossRun` copy of any stage-K table "for symmetry".  That is design law
-- L1's divergence: K and a cross-run copy become two answers to one question, and the
-- copy is always the one that drifts — it would carry `rejectCyclicAliases`' per-module
-- alias deletions, and it would carry the DOUBLED owner keys `appendDataUniverse` leaves
-- behind (see its own note).
export
loadDataUniverse : ModuleCtx -> Int -> Unit
loadDataUniverse mctx cur =
  mctx.mcCells.recordByNameRef :=
    spFloor mctx.mcGraph.crossRun.universeRecordPop.value
  mctx.mcCells.aliasTableRef :=
    aliasUniverseAt cur mctx.mcGraph.declEnvsRef.value.deData.deAliases

-- ── #1111 A-2.11 (#1319 unit 1): the CONSTRUCTOR peer of meExports ──
-- `DataEnv.deCtorExports`: (module id → [(ctor name, owning type name, declaring
-- `Ident`)]), folded dependency-first by `dataEnvFromRowsGo` so a `export import` chain
-- resolves transitively and BY IDENTITY.  Read through `ctorExportsIndex` by
-- `depExportsCtorIdent` (the ctor and record scope ladders' import witness) and
-- `reexportedCtorDecls` (the exhaustiveness oracle's re-export rows).  It rides
-- `declEnvsRef` for the same reason `meExports` does and under the same two-part
-- property: the one Module-mode driver entry (`graphPreamble`) overwrites the envelope
-- whole and nothing resets it in between.  The emitter child builds it the same way,
-- because it runs that same entry; resolve's `ModuleExports` is not available there.
-- An empty index makes every candidate miss, the override declines everywhere, and the
-- ladder silently does nothing.
--
-- Must run on the STAMPED graph: identity comes from `DData.dataOrigin` /
-- `DNewtype.newtypeOrigin`, which `stampGraphTyOrigins` writes, and `buildDeclEnvs` runs
-- after the driver's stamp.
--
-- The owning type name is in the row on purpose.  It is what lets a `(..)` member be
-- expanded on BOTH sides of the chain — `export import m.{T(..)}` re-exporting T's
-- constructors, and `import m.{T(..)}` witnessing one — through the single shared
-- predicate `memberBindsCtorName`.  Without it the `(..)` spelling silently binds nothing
-- here, which is the #1272 shape.
--
-- NO `pub` FILTER, exactly as `declMethodIdentsOf` has none — but unlike the method
-- peer this cannot become that peer's F3 gap, and the reason is structural rather than a
-- promise: the CANDIDATES this index is matched against come from `publicDataDecls`
-- (`appendDataUniverse`), so a private declaration's row entry can never equal a
-- candidate's `Ident` and can never witness anything.
-- One row's step, the shape of `methodEnvGo`'s `meExports` arm: [m]'s own declarations
-- plus what it re-exports from the rows already folded.  The prelude row is keyed
-- `"core"` (its `demId`) and is folded first, so its re-export half is empty.
ctorExportsInto : DeclEnvModule ->
  OrdMap (List (String, String, Ident)) ->
  OrdMap (List (String, String, Ident))
ctorExportsInto m acc =
  omInsert
    m.demId
    (declCtorIdents m.demDecls ++ reexportedCtorIdents acc m.demDecls)
    acc

-- the (ctor name, owning type name, declaring identity) rows [decls] DECLARES.
declCtorIdents : List Decl -> List (String, String, Ident)
declCtorIdents decls = flatMap declCtorIdentsOf decls

declCtorIdentsOf : Decl -> List (String, String, Ident)
declCtorIdentsOf (DAttrib _ d) = declCtorIdentsOf d
declCtorIdentsOf (DData { dataName, dataCtors, dataOrigin, ... }) =
  flatMap (v => variantIdentRow dataName dataOrigin v) dataCtors
declCtorIdentsOf (DNewtype { newtypeName, newtypeCtor, newtypeOrigin, ... }) =
  ctorIdentRow newtypeName newtypeOrigin newtypeCtor
declCtorIdentsOf _ = []

variantIdentRow : String ->
  TyConOrigin ->
  Variant ->
  List (String, String, Ident)
variantIdentRow tyName o (Variant cn _) = ctorIdentRow tyName o cn

ctorIdentRow : String -> TyConOrigin -> String -> List (String, String, Ident)
ctorIdentRow tyName o cn = match mkIdent NsCtor o cn
  None => []
  Some i => [(cn, tyName, i)]

-- the constructor rows a module RE-EXPORTS via `export import src.{…}` (`DUse True`),
-- taken from [acc] — the dependency's already-folded row.  A `(..)` member re-exports
-- the named TYPE's constructors, which is why this cannot reuse `importedBindings`
-- (it drops the `(..)` flag) and goes through `memberBindsCtorName` instead.
reexportedCtorIdents : OrdMap (List (String, String, Ident)) ->
  List Decl ->
  List (String, String, Ident)
reexportedCtorIdents acc decls = flatMap (reexportedCtorIdentsOf acc) decls

reexportedCtorIdentsOf : OrdMap (List (String, String, Ident)) ->
  Decl ->
  List (String, String, Ident)
reexportedCtorIdentsOf acc (DAttrib _ d) = reexportedCtorIdentsOf acc d
reexportedCtorIdentsOf acc (DUse True path _) =
  match omLookup (useModId path) acc
    None => []
    Some src => match path
      -- `export import src.*` re-exports every one of src's constructors
      UseWild _ => src
      UseGroup _ ms => flatMap (m => reexportCtorMember m src) ms
      _ => []
reexportedCtorIdentsOf _ _ = []

reexportCtorMember : UseMember ->
  List (String, String, Ident) ->
  List (String, String, Ident)
reexportCtorMember m src = filterList (r => rowBoundByMember m r) src

rowBoundByMember : UseMember -> (String, String, Ident) -> Bool
rowBoundByMember m (cn, owner, _) = memberBindsCtorName cn owner m

export
graphAliasRow : Decl -> List (TabKey, (List String, Ty))
graphAliasRow (DAttrib _ d) = graphAliasRow d
graphAliasRow (DTypeAlias { tyAliasName = n, tyAliasParams = ps, tyAliasRhs = rhs, tyAliasOrigin = o }) =
  [(tyTabKey o n, (ps, rhs))]
graphAliasRow _ = []

export
implHeadNormalDecl : List (TabKey, (List String, Ty)) -> Decl -> Decl
implHeadNormalDecl aliases (DAttrib a d) =
  DAttrib a (implHeadNormalDecl aliases d)
implHeadNormalDecl aliases (d@(DImpl { tys = tys })) =
  DImpl { d | tys = map (tyAliasNormalForm aliases []) tys }
implHeadNormalDecl _ d = d

export
declEnvModulesFrom : GraphCtx ->
  Int ->
  List (String, List Decl) ->
  List DeclEnvModule
declEnvModulesFrom gctx _ [] = []
declEnvModulesFrom gctx k ((mid, decls) :: rest) =
  declEnvModule gctx k mid decls :: declEnvModulesFrom gctx (k + 1) rest

declEnvOrdIndex : OrdMap Int -> List DeclEnvModule -> OrdMap Int
declEnvOrdIndex acc [] = acc
declEnvOrdIndex acc (m :: rest) =
  declEnvOrdIndex (omInsert m.demId m.demOrd acc) rest

-- Module id → every module id it can reach through `DUse` edges.  Built once per
-- graph, walked with an explicit seen-set so an import CYCLE terminates rather than
-- relying on the loader's topological order (the loader rejects cycles, but this
-- function must not be the thing that discovers that).
--
-- THE DIRECT-import edges are indexed first, and that is not A TIDY-UP.  This
-- walk visits O(modules) rows per module, so a direct-import lookup that SCANS the
-- module list makes the whole index CUBIC in the module count on an import chain —
-- measured at N=400 as 0.84s of the `modules` perf shape's typecheck stage, which is
-- what reddened `diff_compiler_perf_scaling`'s TIME arm when #1597 landed.  Indexing
-- the edges once keeps the walk quadratic-with-log (the index's own SIZE is already
-- quadratic on a chain — each of N modules reaches ~N — so no build can be cheaper).
declEnvReachIndex : List DeclEnvModule -> OrdMap (OrdMap Unit)
declEnvReachIndex mods =
  declEnvReachGo (declEnvImportIndex mods omEmpty) mods omEmpty

-- Module id → its direct `DUse` edges, one row per module.  FIRST row wins, which is
-- the same tie-break the linear scan this replaces had (it returned the first
-- `demId` match), and an absent id yields `[]` for the same reason it did there.
declEnvImportIndex : List DeclEnvModule ->
  OrdMap (List String) ->
  OrdMap (List String)
declEnvImportIndex [] acc = acc
declEnvImportIndex (m :: rest) acc
  | omHasKey m.demId acc = declEnvImportIndex rest acc
  | otherwise =
    declEnvImportIndex
      rest
      (omInsert m.demId (flatMap useModuleId m.demDecls) acc)

declEnvReachGo : OrdMap (List String) ->
  List DeclEnvModule ->
  OrdMap (OrdMap Unit) ->
  OrdMap (OrdMap Unit)
declEnvReachGo _ [] acc = acc
declEnvReachGo edges (m :: rest) acc =
  declEnvReachGo
    edges
    rest
    (omInsert
      m.demId
      (declEnvReachFrom edges [m.demId] (declEnvReachSeed m.demId))
      acc)

-- The reader's OWN module is reachable from itself, and so is the PRELUDE under both
-- spellings the drivers use for it (`"core"` here, `""` from `declEnvOrdIndex`): no
-- module writes a `DUse` for the implicit prelude, so a closure that did not seed it
-- would silently disenfranchise every prelude record.
declEnvReachSeed : String -> OrdMap Unit
declEnvReachSeed mid =
  omInsert mid () (omInsert "" () (omInsert "core" () omEmpty))

-- ── the per-graph derivation of `deDefiners`, built once by `buildDeclEnvs` ────────────
--
-- no reset point is needed, and that is deliberate (RUN-XMOD-066 (iii)).  The obvious
-- shape for a memo here is a `GraphCtx` ref filled lazily — and `GraphCtx` has no
-- reset point at all, which is precisely what makes `mangledShadowMapRef` an anti-pattern
-- (RUN-XMOD-040): it is written once, on the emit path, and nothing invalidates it when
-- the thing it was derived FROM is replaced, so a second graph in one process reads the
-- first graph's answers.  This table is instead a FIELD of the value it is a function of.
-- `deDefiners` is derived from `mods` and from nothing else, in the same constructor, so
-- it cannot outlive its input: every write of `declEnvsRef` (the one Module-mode driver
-- entry, `graphPreamble`, writes it unconditionally, on both output selections)
-- replaces the whole envelope, table included, and a driver that never calls
-- `buildDeclEnvs` reads `emptyDeclEnvs`' empty one.  There is no state to forget to clear.
--
-- one forward fold, dependency-first.  [acc] holds the finished rows of every module of a
-- LOWER ordinal, and a re-export target is a DEPENDENCY, so it is always already in [acc]
-- — `deModules` is the loader's dependency-first order (see `DeclEnvModule.demOrd`), the
-- same premise `deKindsBefore`/`deOwnersBefore`/`declEnvSeedChain` are built on.  So the
-- transitive answer falls out of a single linear pass with no recursion, and therefore no
-- fuel: `importDefinerFuel = 64` existed only to keep termination from resting on the
-- loader's cycle rejection, and a fold over a finite list terminates outright.  (Its side
-- effect — silently truncating a re-export chain deeper than 64 to a partial row set, i.e.
-- a dropped dict on a well-typed program — goes with it.)
--
-- UNGATED: nothing in this fold checks that [deModules] really is dependency-first — it's
-- enforced upstream by the loader's topo-sort, not verified locally. A violation fails
-- CLOSED: the not-yet-inserted dependency's `omLookup` misses, yielding a partial/missing
-- row, never a crash or a wrong-but-plausible answer.
declEnvDefinerIndex : OrdMap (List (String, (String, String))) ->
  OrdMap (List (String, List String)) ->
  List DeclEnvModule ->
  (OrdMap (List (String, (String, String))), OrdMap (List (String, List String)))
declEnvDefinerIndex acc amb [] = (acc, amb)
declEnvDefinerIndex acc amb (m :: rest) =
  let rows = modulePubDefiners acc m.demId m.demDecls
  declEnvDefinerIndex
    (omInsert m.demId (firstRowPerName omEmpty rows) acc)
    (omInsert m.demId (ambiguousExportRows m.demId rows) amb)
    rest

-- ── #1675: which of a module's exported VALUE names have more than one denotation ──
-- `firstRowPerName` above keeps the first row per name, and for a module's OWN
-- declarations plus a single re-export that is a projection, not a choice.  For a
-- re-export HUB — `export import lib.pa.{g}` and `export import lib.pb.{g}` in one
-- module — the two rows name two DIFFERENT definitions, and keeping the first is a
-- silent verdict decided by the order of two `export import` lines.  This records
-- exactly those names so an IMPORTER of the hub can reject them (`reportAmbiguousImport`);
-- nothing rejects the hub itself, which is the decided USE-SITE ambiguity model
-- (#1070's reject-at-declaration remedy is superseded).
--
-- identity, not module id, is the discriminator — the same rule
-- `T-AMBIGUOUS-ALIAS-METHOD` states for methods.  The rows are deduped on the whole
-- `(definer module, name at the definer)` pair, so a DIAMOND (one definition reached
-- through two re-export hops) collapses to one denotation and is NOT ambiguous; only
-- genuinely distinct definitions collide.
--
-- A module's OWN declaration SETTLES the name rather than participating in the
-- ambiguity — `graphPubDefiners`' "declared names come first" and resolve's
-- `ambiguousSet`/`keepAmbiguous` (which drops any name with a same-module top-level
-- value shadow) already decide it that way, and a hub that both declares `g` and
-- re-exports someone else's `g` must keep meaning its own.
--
-- Grouped through an `OrdMap` rather than a per-name rescan: `rows` is the UNCOLLAPSED
-- list, which for a wildcard re-export is the whole of its dependency's export table,
-- and RUN-XMOD-066 records what a quadratic over that costs on
-- `diff_compiler_perf_scaling.sh`'s 400-module `modules` chain.
ambiguousExportRows : String ->
  List (String, (String, String)) ->
  List (String, List String)
ambiguousExportRows mid rows =
  let grouped = groupDefinerPairs omEmpty rows
  ambigRowsOf mid grouped (omKeys grouped)

groupDefinerPairs : OrdMap (List (String, String)) ->
  List (String, (String, String)) ->
  OrdMap (List (String, String))
groupDefinerPairs acc [] = acc
groupDefinerPairs acc ((n, pair) :: rest) = match omLookup n acc
  None => groupDefinerPairs (omInsert n [pair] acc) rest
  Some seen =>
    if anyList (p => fst p == fst pair && snd p == snd pair) seen then
      groupDefinerPairs acc rest
    else
      groupDefinerPairs (omInsert n (seen ++ [pair]) acc) rest

ambigRowsOf : String ->
  OrdMap (List (String, String)) ->
  List String ->
  List (String, List String)
ambigRowsOf _ _ [] = []
ambigRowsOf mid grouped (n :: rest) =
  let pairs = definerPairsOf n grouped
  if listLen pairs >= 2 && not (anyList (p => fst p == mid) pairs) then
    (n, map fst pairs) :: ambigRowsOf mid grouped rest
  else
    ambigRowsOf mid grouped rest

definerPairsOf : String ->
  OrdMap (List (String, String)) ->
  List (String, String)
definerPairsOf n grouped = match omLookup n grouped
  Some ps => ps
  None => []

-- keep the FIRST row per local spelling and drop the rest.  This is not a shortcut, it is
-- what every reader of these rows already does: `resolveMemberRows` takes `lookupAssoc`'s
-- first hit, `importDefinersOf` drops a wildcard row whose name is already spoken for, and
-- the three refs the rows land in are read first-match.  So collapsing here is
-- observationally identical AND it is what keeps the TABLE from being exponential: a
-- wildcard re-export takes its dependency's rows WHOLESALE (`importFormRows`' `None` arm),
-- so a module re-exporting two predecessors carries |rows(k-1)| + |rows(k-2)| — Fibonacci
-- in chain depth — even though the DISTINCT names are only ever the handful the graph
-- actually declares.  Measured on the round-3 breaker's own branching corpus (F4, K=26,
-- `check`, min of 3 interleaved rounds): 8.23 s without this line, 6.56 s with it, against
-- a 6.49 s base.
firstRowPerName : OrdMap Unit ->
  List (String, (String, String)) ->
  List (String, (String, String))
firstRowPerName _ [] = []
firstRowPerName seen ((k, v) :: rest) =
  if omHasKey k seen then
    firstRowPerName seen rest
  else
    (k, v) :: firstRowPerName (omInsert k () seen) rest

modulePubDefiners : OrdMap (List (String, (String, String))) ->
  String ->
  List Decl ->
  List (String, (String, String))
modulePubDefiners before mid decls =
  map (n => (n, (mid, n))) (pubTopFnNames decls)
    ++ reexportDefiners before decls

-- the rows a module's `export import` decls (`DUse True` — the same filter resolve's
-- `pubUsePaths` and `reexportSeed` use) add to its own export table.  A plain `import`
-- is not re-exported and contributes nothing downstream.
reexportDefiners : OrdMap (List (String, (String, String))) ->
  List Decl ->
  List (String, (String, String))
reexportDefiners _ [] = []
reexportDefiners before ((DAttrib _ d) :: rest) =
  reexportDefiners before [d] ++ reexportDefiners before rest
reexportDefiners before ((DUse True path _) :: rest) =
  let depId = useModId path
  if depId == "core" then
    reexportDefiners before rest
  else
    importFormRows path (definersIn before depId)
      ++ reexportDefiners before rest
reexportDefiners before (_ :: rest) = reexportDefiners before rest

-- `declTopFnNames` restricted to the EXPORTED bindings — what a wildcard import can
-- actually bind.  A private binding must not enter the definer map: it is unreachable
-- from the importer, and a row for it could shadow a genuine wildcard row of the same
-- name from a second dependency.
--
-- Standalone visibility includes an exported signature with a private body,
-- but never visibility donated by a same-named public interface method.
-- Intersect with actual function definitions to exclude extern declarations.
export
pubTopFnNames : List Decl -> List String
pubTopFnNames decls =
  let fns = namesToSet (declTopFnNames decls) omEmpty
  filterList (n => omHasKey n fns) (publicStandaloneNames decls)

publicStandaloneNames : List Decl -> List String
publicStandaloneNames [] = []
publicStandaloneNames ((DAttrib _ d) :: rest) =
  publicStandaloneNames [d] ++ publicStandaloneNames rest
publicStandaloneNames ((DFunDef True n _ _ _ _) :: rest) =
  n :: publicStandaloneNames rest
publicStandaloneNames ((DTypeSig True n _ _) :: rest) =
  n :: publicStandaloneNames rest
publicStandaloneNames (_ :: rest) = publicStandaloneNames rest

-- test-only observation: declarations whose only callers are tests and probes.

-- Fixtures for the doctests above.  `deKindRow1` is the SAME decls at ordinal 1,
-- which is how the later-row arm is exercised without a second decl set.
deKindAbstractFixture : Decl
deKindAbstractFixture = DData {
  dataVis = VisAbstract,
  dataName = "Opq",
  dataParams = [],
  dataParamKinds = [],
  dataCtors = [Variant "MkOpq" (ConPos [tyConBuiltin "Int" None])],
  dataCtorBinders = [],
  dataDerives = [],
  dataOrigin = OriginModule "m",
  dataExtern = False,
  dataNameLoc = None,
}

deKindPrivateFixture : Decl
deKindPrivateFixture = DData {
  dataVis = VisPrivate,
  dataName = "Priv",
  dataParams = [],
  dataParamKinds = [],
  dataCtors = [Variant "MkPriv" (ConPos [tyConBuiltin "Int" None])],
  dataCtorBinders = [],
  dataDerives = [],
  dataOrigin = OriginModule "m",
  dataExtern = False,
  dataNameLoc = None,
}

deKindNewtypeFixture : Decl
deKindNewtypeFixture = DNewtype {
  newtypePub = True,
  newtypeName = "Wrap",
  newtypeParams = [],
  newtypeParamKinds = [],
  newtypeCtor = "Wrap",
  newtypeFieldTy = tyConBuiltin "Int" None,
  newtypeCtorBinders = [],
  newtypeDerives = [],
  newtypeOrigin = OriginModule "m",
  newtypeNameLoc = None,
}

deKindFixtureDecls : List Decl
deKindFixtureDecls = [
  deFieldOwnerFixtureA,
  deKindAbstractFixture,
  deKindPrivateFixture,
  deKindNewtypeFixture,
]

deKindRow0 : GraphCtx -> DeclEnvModule
deKindRow0 gctx = declEnvModule gctx 0 "m" deKindFixtureDecls

deKindRow1 : GraphCtx -> DeclEnvModule
deKindRow1 gctx = declEnvModule gctx 1 "m" deKindFixtureDecls

-- ── A-3.6 bite C-1: THE OWN-row exclusion, asserted rather than incidental ────
-- `declEnvSeedChain` stamps row [m]'s id with the accumulators as they stand
-- BEFORE [m] is folded in, so [m]'s seed is "every row strictly earlier than
-- [m]" and never [m] itself.  That is a STRUCTURAL property of the fold order —
-- there is no ordinal test to find and none to keep — and until now it was
-- asserted only in prose two hundred lines up.  Prose is not fail-capable, and
-- the exclusion is load-bearing in a way an ordinal statement is not: a module
-- registers its OWN decls a second time, immediately after this seed, through
-- `registerAllData … prog0`.  Seeding the own row here too would put the same
-- `cname` key in `fieldOwnersRef` twice (`addFieldOwners` does not dedupe) —
-- `fieldOwnerNames`, its only reader, dedupes on read, so the
-- doubling would not move an answer; the assertions below pin the seed's shape.
--
-- So these four lines are A TRIPWIRE ON A specific wrong edit, and it is one
-- an implementer can arrive here already instructed to make:
-- `test/registry_keying_ratchet.sh`'s `declEnvsRef` row tells A-3.6 to *"hand
-- every row the FINAL accumulator"*.  Doing that destroys the exclusion the same
-- row calls structural.  Every assertion below moves if it is done — that is the
-- fail-capability argument, and it is by construction, not by hope:
--   * `deSeedChainProbe` is a TWO-row chain, so the final accumulator differs
--     from every row's prefix.  Row "m" is FIRST, so its correct seed is EMPTY
--     while the final accumulator holds both rows: 0 → 6 kinds, `[]` → two
--     owners.  Row "n" is LAST, so its correct seed is row "m" alone while the
--     final accumulator adds "n"'s own identical `Pt`: 3 → 6 kinds, and
--     `["Pt"]` → `["Pt", "Pt"]` — the doubled key itself, named.
--   * A ONE-row chain could not discriminate any of that (prefix and final
--     accumulator coincide at the only row), which is why the probe carries two
--     rows with DISTINCT ids rather than reusing `deKindRow0`/`deKindRow1`.
-- > listLen (optionOr [] (omLookup "m" (deSeedChainKinds (probeGraphCtx ()))))
-- 0
-- > optionOr [] (omLookup "x" (optionOr omEmpty (omLookup "m" (deSeedChainOwners (probeGraphCtx ())))))
-- []
-- > listLen (optionOr [] (omLookup "n" (deSeedChainKinds (probeGraphCtx ()))))
-- 3
-- > optionOr [] (omLookup "x" (optionOr omEmpty (omLookup "n" (deSeedChainOwners (probeGraphCtx ())))))
-- ["Pt"]

-- #2158: the THIRD accumulator, on the SAME probe, so the own-row exclusion is
-- asserted on it too — row "m" is first, so its name index is EMPTY even though
-- "m" itself declares `Pt`/`Opq`/`Wrap`; row "n" sees exactly "m"'s three
-- kind-public names and NOT its own identical copies.  (`Priv` is absent from
-- both for the separate reason `declEnvRowKindEntries`' cross-module arm drops
-- a private decl — see the kind-count doctests above.)
-- > omKeys (optionOr omEmpty (omLookup "m" (deSeedChainNames (probeGraphCtx ()))))
-- []
-- > omKeys (optionOr omEmpty (omLookup "n" (deSeedChainNames (probeGraphCtx ()))))
-- ["Opq", "Pt", "Wrap"]

-- The parity assertion, and it is the one that pins the fix.  #2158 first
-- shipped the name index as a per-module REBUILD in `declEnvSeedDataUniverse`
-- (`omFromNames (map (p => tabKeyName (fst p)) kindsRef.value) omEmpty`), which
-- was quadratic in the module count.  The accumulator replaced it, so what must
-- stay true is that the accumulated set and the rebuilt set AGREE on every row.
-- This states that as an equation over the probe rather than as prose, so a
-- future edit to either half that breaks the agreement is loud here.
-- > deSeedNameParity "m"
-- True
-- > deSeedNameParity "n"
-- True

-- Row "n" carries the SAME decls as `deKindRow0` at ordinal 1 under a DIFFERENT
-- module id.  Same decls is deliberate: it makes the own-row contribution and the
-- earlier row's contribution identical values, so the only thing the assertions
-- above can be reading is WHICH ROWS were folded, never which decls.
deSeedRowN : GraphCtx -> DeclEnvModule
deSeedRowN gctx = declEnvModule gctx 1 "n" deKindFixtureDecls

-- The bare zero, NOT `emptyDeclEnvSeedAcc`: these probes assert which ROWS were
-- folded, and the `""` core-pass seed would be an extra key in every assertion.
deSeedChainProbeZero : DeclEnvSeedAcc
deSeedChainProbeZero = DeclEnvSeedAcc {
  dsKAcc = [],
  dsOAcc = omEmpty,
  dsNAcc = omEmpty,
  dsKinds = omEmpty,
  dsOwners = omEmpty,
  dsNames = omEmpty,
}

deSeedChainProbe : GraphCtx -> DeclEnvSeedAcc
deSeedChainProbe gctx =
  declEnvSeedChain gctx [deKindRow0 gctx, deSeedRowN gctx] deSeedChainProbeZero

deSeedChainKinds : GraphCtx -> OrdMap (List (TabKey, List Kind))
deSeedChainKinds gctx = (deSeedChainProbe gctx).dsKinds

deSeedChainOwners : GraphCtx -> OrdMap (OrdMap (List String))
deSeedChainOwners gctx = (deSeedChainProbe gctx).dsOwners

deSeedChainNames : GraphCtx -> OrdMap (OrdMap Unit)
deSeedChainNames gctx = (deSeedChainProbe gctx).dsNames

-- The accumulated name set for [mid] vs. the retired rebuild, computed here off
-- the SAME row's kind seed.  `omKeys` is sorted ascending, so this compares KEY
-- SETS and is blind to tree shape and to insertion order — which is exactly the
-- equivalence class the only reader (`noImplHintFor`'s `omHasKey`) can observe.
deSeedNameParity : String -> Bool
deSeedNameParity mid =
  let gctx = probeGraphCtx ()
  let accumulated =
    omKeys (optionOr omEmpty (omLookup mid (deSeedChainNames gctx)))
  let rebuilt =
    omKeys
      (omFromNames
        (map
          (p => tabKeyName (fst p))
          (optionOr [] (omLookup mid (deSeedChainKinds gctx))))
        omEmpty)
  accumulated == rebuilt

-- ── #2158 F7: the name index as A PROGRAM-GLOBAL TABLE (T-GLOBAL-TABLE) ──────
-- `deNameIndexBefore` is a new whole-graph table, so `compiler/AGENTS.md`'s
-- T-GLOBAL-TABLE bar applies: the fixture that matters is not "the feature
-- works", it is "the feature is present and code that never touches it is
-- unaffected".  The four rows below are built for that shape specifically —
-- `deSeedChainProbe` above cannot state it, because both of its rows declare the
-- same data types, so nothing there distinguishes "row X contributed" from "row X
-- was skipped".
--
--   * `modA` declares `Alpha` and `Shared`.
--   * `modB` declares `Beta` and its OWN `Shared` — same declared NAME, different
--     module.  That pair is deliberate: the index is bare-name by construction
--     (`tabKeyName`, matching the `tabHasName` scan it replaced — see the
--     `ModuleCtx` field's comment), so the two `Shared` declarations must collapse
--     to ONE key.  A future edit that made the index identity-keyed would show up
--     as two entries here, which is the point of asserting the key LIST rather
--     than a membership Bool.
--   * `modC` and `modD` declare NO data type at all — just a value binding.  They
--     are the "unrelated code" half: their presence must leave every other row's
--     index untouched, and they must contribute nothing to any later row's.
deNameIdxAlpha : Decl
deNameIdxAlpha = DData {
  dataVis = VisPublic,
  dataName = "Alpha",
  dataParams = [],
  dataParamKinds = [],
  dataCtors = [Variant "MkAlpha" (ConPos [tyConBuiltin "Int" None])],
  dataCtorBinders = [],
  dataDerives = [],
  dataOrigin = OriginModule "modA",
  dataExtern = False,
  dataNameLoc = None,
}

deNameIdxSharedA : Decl
deNameIdxSharedA = DData {
  dataVis = VisPublic,
  dataName = "Shared",
  dataParams = [],
  dataParamKinds = [],
  dataCtors = [Variant "MkSharedA" (ConPos [tyConBuiltin "Int" None])],
  dataCtorBinders = [],
  dataDerives = [],
  dataOrigin = OriginModule "modA",
  dataExtern = False,
  dataNameLoc = None,
}

deNameIdxBeta : Decl
deNameIdxBeta = DData {
  dataVis = VisPublic,
  dataName = "Beta",
  dataParams = [],
  dataParamKinds = [],
  dataCtors = [Variant "MkBeta" (ConPos [tyConBuiltin "Int" None])],
  dataCtorBinders = [],
  dataDerives = [],
  dataOrigin = OriginModule "modB",
  dataExtern = False,
  dataNameLoc = None,
}

deNameIdxSharedB : Decl
deNameIdxSharedB = DData {
  dataVis = VisPublic,
  dataName = "Shared",
  dataParams = [],
  dataParamKinds = [],
  dataCtors = [Variant "MkSharedB" (ConPos [tyConBuiltin "Int" None])],
  dataCtorBinders = [],
  dataDerives = [],
  dataOrigin = OriginModule "modB",
  dataExtern = False,
  dataNameLoc = None,
}

deNameIdxModA : GraphCtx -> DeclEnvModule
deNameIdxModA gctx =
  declEnvModule gctx 0 "modA" [deNameIdxAlpha, deNameIdxSharedA]

deNameIdxModB : GraphCtx -> DeclEnvModule
deNameIdxModB gctx =
  declEnvModule gctx 1 "modB" [deNameIdxBeta, deNameIdxSharedB]

-- No data declaration anywhere in these two — a plain value binding, the
-- "unrelated code" T-GLOBAL-TABLE asks for.
deNameIdxModC : GraphCtx -> DeclEnvModule
deNameIdxModC gctx = declEnvModule gctx 2 "modC" [
  DFunDef True "modCHelper" [] (ELit (LInt 1)) noDeclLoc noBinderId,
]

deNameIdxModD : GraphCtx -> DeclEnvModule
deNameIdxModD gctx = declEnvModule gctx 3 "modD" [
  DFunDef True "modDHelper" [] (ELit (LInt 2)) noDeclLoc noBinderId,
]

deNameIdxChain : GraphCtx -> OrdMap (OrdMap Unit)
deNameIdxChain gctx =
  let s =
    declEnvSeedChain
      gctx
      [
        deNameIdxModA gctx,
        deNameIdxModB gctx,
        deNameIdxModC gctx,
        deNameIdxModD gctx,
      ]
      deSeedChainProbeZero
  s.dsNames

-- The SAME chain with the two data-free rows removed.  Comparing against this is
-- what turns "unrelated code is unaffected" into an assertion rather than a hope.
deNameIdxChainNoUnrelated : GraphCtx -> OrdMap (OrdMap Unit)
deNameIdxChainNoUnrelated gctx =
  let s =
    declEnvSeedChain
      gctx
      [deNameIdxModA gctx, deNameIdxModB gctx]
      deSeedChainProbeZero
  s.dsNames

deNameIdxAt : OrdMap (OrdMap Unit) -> String -> List String
deNameIdxAt nm mid = omKeys (optionOr omEmpty (omLookup mid nm))

-- ── doctests ─────────────────────────────────────────────────────────────
-- (a) A name declared in an EARLIER module is visible at a later module's seed.
--     `modB` sees `modA`'s two names and no others.
-- > deNameIdxAt (deNameIdxChain (probeGraphCtx ())) "modB"
-- ["Alpha", "Shared"]

-- (b) A name declared in the SAME module is NOT — own registrations go on TOP of
--     the universe later, via `recordParamKinds` under `registerAllData … prog0`.
--     `modB` declares `Beta`; `Beta` is absent from `modB`'s own seed and present
--     one row later.
-- > omHasKey "Beta" (optionOr omEmpty (omLookup "modB" (deNameIdxChain (probeGraphCtx ()))))
-- False
-- > omHasKey "Beta" (optionOr omEmpty (omLookup "modC" (deNameIdxChain (probeGraphCtx ()))))
-- True

--     …and the first row's seed is empty, own-row exclusion at the boundary.
-- > deNameIdxAt (deNameIdxChain (probeGraphCtx ())) "modA"
-- []

-- (c) Unrelated code — `modC`/`modD` declare no data type at all.  They
--     contribute NOTHING (the two rows' indexes are equal, so the row between
--     them added no name), and their presence perturbs NOTHING (`modA`/`modB`
--     read identically in a chain that does not contain them at all).
--     `Shared` appears ONCE across both declaring modules: bare-name by design.
-- > deNameIdxAt (deNameIdxChain (probeGraphCtx ())) "modC"
-- ["Alpha", "Beta", "Shared"]
-- > deNameIdxAt (deNameIdxChain (probeGraphCtx ())) "modD" == deNameIdxAt (deNameIdxChain (probeGraphCtx ())) "modC"
-- True
-- > deNameIdxAt (deNameIdxChainNoUnrelated (probeGraphCtx ())) "modA" == deNameIdxAt (deNameIdxChain (probeGraphCtx ())) "modA"
-- True
-- > deNameIdxAt (deNameIdxChainNoUnrelated (probeGraphCtx ())) "modB" == deNameIdxAt (deNameIdxChain (probeGraphCtx ())) "modB"
-- True

-- Build the whole-graph `DataEnv` from the per-module rows — the SAME rows
-- `deImpls`/`deIfaces` fold, visiting the same decls in the same order the
-- flattened `deAllDecls` holds them (`declEnvDeclsOf` is those rows' `demDecls`
-- concatenated in ordinal order), so nothing about the four bare-name-free
-- tables below moves by taking rows instead of the flat list.
--
-- A-3.2b residual (#1512) took the rows for one reason: `deAliases` now carries
-- the declaring module's ORDINAL, and the flattened list has no ordinal in it —
-- the same reason `buildImplEnv` has always read rows (see `buildDeclEnvs`).
buildDataEnv : List DeclEnvModule -> DataEnv
buildDataEnv rows = dataEnvFinish (dataEnvFromRowsGo rows emptyDataEnv)

-- Fixture for the doctests below: a PUBLIC alias in the prelude row (ordinal 0),
-- a PRIVATE one beside it, and a public one in a later module (ordinal 1).
aliasFixturePubCore : Decl
aliasFixturePubCore = DTypeAlias {
  tyAliasPub = True,
  tyAliasName = "PubCore",
  tyAliasParams = [],
  tyAliasParamKinds = [],
  tyAliasRhs = tyConBuiltin "Int" None,
  tyAliasOrigin = OriginModule "core",
  tyAliasNameLoc = None,
}

aliasFixturePrivCore : Decl
aliasFixturePrivCore = DTypeAlias {
  tyAliasPub = False,
  tyAliasName = "PrivCore",
  tyAliasParams = [],
  tyAliasParamKinds = [],
  tyAliasRhs = tyConBuiltin "Int" None,
  tyAliasOrigin = OriginModule "core",
  tyAliasNameLoc = None,
}

aliasFixturePubM : Decl
aliasFixturePubM = DTypeAlias {
  tyAliasPub = True,
  tyAliasName = "PubM",
  tyAliasParams = [],
  tyAliasParamKinds = [],
  tyAliasRhs = tyConBuiltin "Int" None,
  tyAliasOrigin = OriginModule "m",
  tyAliasNameLoc = None,
}

-- PUBLIC, but wrapped in an attribute.  SINCE #1228/#1586 this row is visible:
-- `registerData` unwraps `DAttrib`, so `aliasVisibleTo`'s third condition is gone
-- and this alias behaves like any other public one.  It is still in the population
-- (`deAliases` holds four rows, asserted below) — that half never changed.
aliasFixtureAttribCore : Decl
aliasFixtureAttribCore =
  DAttrib
    [AttrDeprecated (Some "old")]
    DTypeAlias {
      tyAliasPub = True,
      tyAliasName = "AttribCore",
      tyAliasParams = [],
      tyAliasParamKinds = [],
      tyAliasRhs = tyConBuiltin "Int" None,
      tyAliasOrigin = OriginModule "core",
      tyAliasNameLoc = None,
    }

aliasFixtureEnv : GraphCtx -> DataEnv
aliasFixtureEnv gctx = buildDataEnv [
  declEnvModule gctx 0 "core" [
    aliasFixturePubCore, aliasFixturePrivCore, aliasFixtureAttribCore
  ],
  declEnvModule gctx 1 "m" [aliasFixturePubM],
]

aliasNamesAt : Int -> List String
aliasNamesAt cur =
  map
    (e => tabKeyName (fst e))
    (aliasUniverseAt cur (aliasFixtureEnv (probeGraphCtx ())).deAliases)

-- ── doctests ─────────────────────────────────────────────────────────────
-- The prelude reader (ordinal 0) sees NOTHING — not even its own public alias.
-- > aliasNamesAt 0
-- []

-- A reader at ordinal 1 sees the prelude's PUBLIC aliases — the plain one and the
-- ATTRIBUTED one (#1228/#1586: an attribute is metadata and no longer hides a
-- declaration) — and NOT its private one.  `AttribCore` comes first because
-- `deAliases` is built by PREPEND and it is the last of core's three decls.
-- > aliasNamesAt 1
-- ["AttribCore", "PubCore"]

-- A reader at ordinal 2 sees every public alias, DESCENDING by ordinal — the
-- order the retired accumulator produced, which `lookupTab`'s first-match and
-- `emitCyclicAliasErrors`' render order both observe.
-- > aliasNamesAt 2
-- ["PubM", "AttribCore", "PubCore"]

-- Fail-CLOSED at `declEnvsOrdOf`'s miss sentinel, exactly as `declEnvVisibleAt`.
-- > aliasNamesAt (0 - 1)
-- []

-- POPULATION NEUTRALITY: all FOUR aliases are in `deAliases` — including the
-- attributed one and the private one — and it is the READ that narrows.  This is
-- the assertion that fails if a later edit "tidies" a visibility question back into
-- the fold, re-creating the two-rows-one-record divergence `dataEnvAddDecl`'s note
-- exists to prevent.
-- > listLen (aliasFixtureEnv (probeGraphCtx ())).deAliases
-- 4

-- Fixture for the doctests below: two DIFFERENT modules ("m", "n") each
-- declaring a record named-field variant with field "x".
deFieldOwnerFixtureA : Decl
deFieldOwnerFixtureA = DData {
  dataVis = VisPublic,
  dataName = "Pt",
  dataParams = [],
  dataParamKinds = [],
  dataCtors =
    [Variant "Pt" (ConNamed [Field "x" (tyConBuiltin "Int" None)] False)],
  dataCtorBinders = [],
  dataDerives = [],
  dataOrigin = OriginModule "m",
  dataExtern = False,
  dataNameLoc = None,
}

deFieldOwnerFixtureB : Decl
deFieldOwnerFixtureB = DData {
  dataVis = VisPublic,
  dataName = "Vec",
  dataParams = [],
  dataParamKinds = [],
  dataCtors =
    [Variant "Vec" (ConNamed [Field "x" (tyConBuiltin "Int" None)] False)],
  dataCtorBinders = [],
  dataDerives = [],
  dataOrigin = OriginModule "n",
  dataExtern = False,
  dataNameLoc = None,
}

-- Same DECLARED NAME as fixture A ("Pt"), different module.  This is the case
-- the bare-name table (`universeFieldOwners`) genuinely cannot discriminate:
-- `addFieldOwners` is already a multimap, so it does NOT collapse fixture A/B
-- above (different ctor NAMES "Pt"/"Vec" — the bare table already shows two
-- rows for those).  What the bare table collapses is A vs C: both would
-- append the SAME bare string "Pt" to field "x"'s owner list, so a reader of
-- that list cannot tell "Pt" declared twice from one declaration counted
-- twice.  The identity table keeps them as two DISTINCT `Ident`s (different
-- `OriginModule`), which `distinctIdentsIn2` below asserts on directly.
deFieldOwnerFixtureC : Decl
deFieldOwnerFixtureC = DData {
  dataVis = VisPublic,
  dataName = "Pt",
  dataParams = [],
  dataParamKinds = [],
  dataCtors =
    [Variant "Pt" (ConNamed [Field "x" (tyConBuiltin "Int" None)] False)],
  dataCtorBinders = [],
  dataDerives = [],
  dataOrigin = OriginModule "n",
  dataExtern = False,
  dataNameLoc = None,
}

deFieldOwnerCollisionEnv : GraphCtx -> DataEnv
deFieldOwnerCollisionEnv gctx = buildDataEnv [
  declEnvModule gctx 0 "m" [deFieldOwnerFixtureA, deFieldOwnerFixtureB],
]

deFieldOwnerSingleEnv : GraphCtx -> DataEnv
deFieldOwnerSingleEnv gctx =
  buildDataEnv [declEnvModule gctx 0 "m" [deFieldOwnerFixtureA]]

deFieldOwnerSameNameEnv : GraphCtx -> DataEnv
deFieldOwnerSameNameEnv gctx = buildDataEnv [
  declEnvModule gctx 0 "m" [deFieldOwnerFixtureA, deFieldOwnerFixtureC],
]

-- ── #2147 residual: `deRecordIdents`' bucket order, now pinned ───────────────
-- `deFieldOwnerIdents` has had an ORDERED assertion since A-3.2a (the `["Pt",
-- "Vec"]` doctest below states a list, not a length).  `deRecordIdents` — its
-- sibling under the same `omMapValues reverseL` finalisation in `buildDataEnv`,
-- rewritten from `++ [x]` to cons-and-reverse by #2147 — had only its VALUES
-- covered, never its ORDER.  So the one property #2147 had to preserve was the
-- one nothing asserted: drop `deRecordIdents`' half of that `omMapValues
-- reverseL` and every existing assertion in this file still passes.
--
-- The fixture needs 2+ entries under ONE key, and `deRecordIdents` is keyed by
-- CONSTRUCTOR name, so it takes two records sharing a ctor name under different
-- TYPE names — which is also what makes the assertion discriminating, since the
-- type name is then the thing that distinguishes first from second.
deRecordOrderFixtureA : Decl
deRecordOrderFixtureA = DData {
  dataVis = VisPublic,
  dataName = "P1",
  dataParams = [],
  dataParamKinds = [],
  dataCtors =
    [Variant "Pt" (ConNamed [Field "x" (tyConBuiltin "Int" None)] False)],
  dataCtorBinders = [],
  dataDerives = [],
  dataOrigin = OriginModule "m",
  dataExtern = False,
  dataNameLoc = None,
}

deRecordOrderFixtureB : Decl
deRecordOrderFixtureB = DData {
  dataVis = VisPublic,
  dataName = "P2",
  dataParams = [],
  dataParamKinds = [],
  dataCtors =
    [Variant "Pt" (ConNamed [Field "y" (tyConBuiltin "Int" None)] False)],
  dataCtorBinders = [],
  dataDerives = [],
  dataOrigin = OriginModule "n",
  dataExtern = False,
  dataNameLoc = None,
}

-- Two modules in ORDINAL order, so "P1" is declared strictly before "P2".
deRecordOrderEnv : GraphCtx -> DataEnv
deRecordOrderEnv gctx = buildDataEnv [
  declEnvModule gctx 0 "m" [deRecordOrderFixtureA],
  declEnvModule gctx 1 "n" [deRecordOrderFixtureB],
]

deRecordIdentTyNames : List (Ident, String, List Field) -> List String
deRecordIdentTyNames [] = []
deRecordIdentTyNames ((_, tyName, _) :: rest) =
  tyName :: deRecordIdentTyNames rest

-- ── doctests ─────────────────────────────────────────────────────────────
-- > map snd (optionOr [] (omLookup "x" (deFieldOwnerCollisionEnv (probeGraphCtx ())).deFieldOwnerIdents))
-- ["Pt", "Vec"]
-- > listLen (optionOr [] (omLookup "x" (deFieldOwnerCollisionEnv (probeGraphCtx ())).deFieldOwnerIdents))
-- 2
-- > map snd (optionOr [] (omLookup "x" (deFieldOwnerSingleEnv (probeGraphCtx ())).deFieldOwnerIdents))
-- ["Pt"]

-- The discriminating case: SAME declared name ("Pt") from two DIFFERENT
-- modules stays two DISTINCT identities, not one bare-name collision.
-- > map snd (optionOr [] (omLookup "x" (deFieldOwnerSameNameEnv (probeGraphCtx ())).deFieldOwnerIdents))
-- ["Pt", "Pt"]
-- > distinctIdentsIn2 (optionOr [] (omLookup "x" (deFieldOwnerSameNameEnv (probeGraphCtx ())).deFieldOwnerIdents))
-- True

-- #2147's order half, on `deRecordIdents` rather than `deFieldOwnerIdents`:
-- DECLARATION order within the bucket, "P1" (module ordinal 0) before "P2"
-- (ordinal 1).  Remove `deRecordIdents`' `omMapValues reverseL` in
-- `buildDataEnv` and this reads `["P2", "P1"]`; the length assertion beside it
-- does not move, which is precisely why a length was never enough.
-- > deRecordIdentTyNames (optionOr [] (omLookup "Pt" (deRecordOrderEnv (probeGraphCtx ())).deRecordIdents))
-- ["P1", "P2"]
-- > listLen (optionOr [] (omLookup "Pt" (deRecordOrderEnv (probeGraphCtx ())).deRecordIdents))
-- 2

-- [saved] is the caller's current record: the observation runs in a carry of it, in
-- its graph record with fresh sub-records, and its graph record is current again on
-- return.
export
methodRowNumObservation : ModuleCtx ->
  String ->
  List Decl ->
  List Decl ->
  NumAnchorTestObservation
methodRowNumObservation saved caseName builtinDecls decls =
  let gctx = freshSubRecordsOf saved.mcGraph
  let mctx = carryModuleCtx gctx saved
  gctx.crossRun.builtinClassesRef := builtinClassesOf builtinDecls
  let rows = ifaceMethodSchemeRows mctx decls
  seedNumLitFromIntAnchor mctx rows
  let observation = match mctx.mcCells.numLitFromIntAnchorRef.value
    None => NumAnchorTestObservation {
      natoCase = caseName,
      natoHasRow = False,
      natoIface = "",
      natoSchemeBody = "",
      natoDeclaredType = "",
    }
    Some anchor => NumAnchorTestObservation {
      natoCase = caseName,
      natoHasRow = True,
      natoIface = anchor.msrIface.irName,
      natoSchemeBody = ppMono (schemeBodyOf anchor.msrScheme),
      natoDeclaredType = ppTy anchor.msrType,
    }
  observation

-- Two-element owner list, DISTINCT `Ident`s (never a fixed answer): the
-- property a bare-name multimap cannot state, since two `String`s "Pt"/"Pt"
-- carry no way to tell them apart.
distinctIdentsIn2 : List (Ident, String) -> Bool
distinctIdentsIn2 [(i1, _), (i2, _)] = i1 /= i2
distinctIdentsIn2 _ = False
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "PredicateSlotArgs" true) (mem "AliasDecl" true) (mem "BuiltinClass" true) (mem "BuiltinClasses" true) (mem "DataEnv" true) (mem "DataTypeDecl" true) (mem "DeclEnvAcc" true) (mem "DeclEnvs" true) (mem "DeclEnvSeedAcc" true) (mem "Kind" true) (mem "MethodPredicateSlot" true) (mem "MethodPredicateTemplate" true) (mem "MethodSchemeRow" true) (mem "NumAnchorTestObservation" true) (mem "PredicateSlot" true) (mem "SigVars" true) (mem "DeclEnvModule" false) (mem "GraphCtx" false) (mem "ModuleCtx" false) (mem "RecordInfo" false) (mem "TcEnv" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "applyParams" false) (mem "authvarIdOf" false) (mem "collectAuthvarIds" false) (mem "collectRowEffvarIds" false) (mem "collectTyIds" false) (mem "effvarIdOf" false) (mem "foldrFun" false) (mem "monoTyvarId" false) (mem "schemeBodyOf" false) (mem "schemeIds" false) (mem "tconFrom" false) (mem "tyAppSpine" false) (mem "tyVarNames" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "carryModuleCtx" false) (mem "emptyBuiltinClasses" false) (mem "emptyDataEnv" false) (mem "freshSubRecordsOf" false) (mem "mctxAtIfSome" false) (mem "probeGraphCtx" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "addCtor" false) (mem "aliasUniverseAt" false) (mem "buildClassEnvGo" false) (mem "buildImplEnvGo" false) (mem "builtinIfaceRef" false) (mem "classEnvFinish" false) (mem "constraintSlotDispatchVar" false) (mem "declEnvDeclsOf" false) (mem "declEnvKindEntries" false) (mem "declEnvModule" false) (mem "declEnvReachFrom" false) (mem "declEnvRowVisible" false) (mem "declEnvVisibleTo" false) (mem "declGradedScope" false) (mem "declParamKinds" false) (mem "declTopFnNames" false) (mem "definersIn" false) (mem "dtopFor" false) (mem "effTailNames" false) (mem "implAccFinish" false) (mem "importLocFor" false) (mem "kindPublicDataDecl" false) (mem "methodEnvGo" false) (mem "methodSlotKey" false) (mem "namesToSet" false) (mem "publicDataDecl" false) (mem "rangedOver" false) (mem "removeAllS" false) (mem "sameIfaceDecl" false) (mem "tyTabKey" false) (mem "useModuleId" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeErrorOnce" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "importFormRows" false) (mem "memberBindsCtorName" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "atomsEscape" false) (mem "freshAuthBinderRanged" false) (mem "freshAuthvar" false) (mem "freshAuthvarRanged" false) (mem "freshEffMap" false) (mem "freshEffvar" false) (mem "freshTvMap" false) (mem "freshVar" false) (mem "namedArgDomains" false))))
(DUse false (UseGroup ("types" "tc_decls_variance") ((mem "declEnvPolarityChain" false) (mem "inferParamPolarities" false) (mem "payloadAstTypes" false) (mem "recordParamPolarities" false) (mem "seedParamPolarityFixpointScoped" false) (mem "variantPayload" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "atomsOfWritten" false) (mem "authArgBindersIn" false) (mem "authorityBinderBound" false) (mem "binderDomainsIn" false) (mem "bindingForceFromAst" false) (mem "fromAstType" false) (mem "fromAstTypeE" false) (mem "namedArgTypes" false) (mem "namedAtomBinders" false) (mem "patternSlotNamesIn" false) (mem "payloadTypesE" false) (mem "qualifiedKindScope" false) (mem "recFieldMono" false) (mem "reportBinderDomains" false) (mem "reportUnboundAuthorityNames" false) (mem "reportUnboundAuthorityNamesIn" false) (mem "rowArgNames" false) (mem "rowArgNamesIn" false) (mem "sigVarsWithAuths" false) (mem "substAliasArgs" false) (mem "writtenBindingForce" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authvarId" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffLabel" true) (mem "EffRow" true) (mem "Effvar" true) (mem "atomsNorm" false) (mem "pureRow" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "UsePath" true) (mem "Ns" true) (mem "Lit" true) (mem "Expr" true) (mem "Attr" true) (mem "ConPayload" true) (mem "Constraint" true) (mem "DataVis" true) (mem "Decl" true) (mem "EffAtomTy" true) (mem "Field" true) (mem "Ident" true) (mem "IfaceMethod" true) (mem "KindAnn" true) (mem "Loc" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "UseMember" true) (mem "Variant" true) (mem "firstTyLoc" false) (mem "firstTyLocList" false) (mem "identOriginFold" false) (mem "lookupTab" false) (mem "mapTyFull" false) (mem "mkIdent" false) (mem "noBinderId" false) (mem "noDeclLoc" false) (mem "tabKeyEq" false) (mem "tabKeyName" false) (mem "tyConBuiltin" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "ppMono" false) (mem "ppTy" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omDelete" false) (mem "omEmpty" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false) (mem "omMapValues" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "zipL" false))))
(DUse false (UseGroup ("list") ((mem "elemIndex" false) (mem "findMap" false) (mem "head" false))))
(DUse false (UseGroup ("types" "registry") ((mem "spFloor" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "useModId" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig true "declEnvAccOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "DeclEnvAcc") (TyCon "DeclEnvAcc")))))
(DFunDef false "declEnvAccOf" ((PVar "gctx") (PList) (PVar "a")) (EVar "a"))
(DFunDef false "declEnvAccOf" ((PVar "gctx") (PCons (PVar "m") (PVar "rest")) (PVar "a")) (EBlock (DoLet false false (PVar "definers") (EApp (EApp (EApp (EVar "declEnvDefinerIndex") (EFieldAccess (EVar "a") "daDefiners")) (EFieldAccess (EVar "a") "daAmbig")) (EListLit (EVar "m")))) (DoExpr (EApp (EApp (EApp (EVar "declEnvAccOf") (EVar "gctx")) (EVar "rest")) (ERecordCreate "DeclEnvAcc" ((fa "daOrdIndex" (EApp (EApp (EVar "declEnvOrdIndex") (EFieldAccess (EVar "a") "daOrdIndex")) (EListLit (EVar "m")))) (fa "daDefiners" (EApp (EVar "fst") (EVar "definers"))) (fa "daAmbig" (EApp (EVar "snd") (EVar "definers"))) (fa "daData" (EApp (EApp (EVar "dataEnvFromRowsGo") (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daData"))) (fa "daImpls" (EApp (EApp (EVar "buildImplEnvGo") (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daImpls"))) (fa "daIfaces" (EApp (EApp (EApp (EVar "buildClassEnvGo") (EVar "gctx")) (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daIfaces"))) (fa "daMethods" (EApp (EApp (EApp (EVar "methodEnvGo") (EVar "gctx")) (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daMethods"))) (fa "daSeeds" (EApp (EApp (EApp (EVar "declEnvSeedChain") (EVar "gctx")) (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daSeeds"))) (fa "daPolarity" (EApp (EApp (EVar "declEnvPolarityChain") (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daPolarity"))) (fa "daOwnerModules" (EApp (EApp (EVar "declEnvOwnerModules") (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daOwnerModules")))))))))
(DTypeSig true "buildDeclEnvs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "DeclEnvAcc") (TyFun (TyCon "DeclEnvModule") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyCon "DeclEnvs"))))))
(DFunDef false "buildDeclEnvs" ((PVar "gctx") (PVar "acc") (PVar "coreRow") (PVar "modRows")) (EBlock (DoLet false false (PVar "mods") (EBinOp "::" (EVar "coreRow") (EVar "modRows"))) (DoLet false false (PVar "a") (EApp (EApp (EApp (EVar "declEnvAccOf") (EVar "gctx")) (EVar "modRows")) (EVar "acc"))) (DoExpr (ERecordCreate "DeclEnvs" ((fa "deModules" (EVar "mods")) (fa "deOrdIndex" (EFieldAccess (EVar "a") "daOrdIndex")) (fa "deDefiners" (EFieldAccess (EVar "a") "daDefiners")) (fa "deAmbigValues" (EFieldAccess (EVar "a") "daAmbig")) (fa "deAllDecls" (EApp (EVar "declEnvDeclsOf") (EVar "mods"))) (fa "deData" (EApp (EVar "dataEnvFinish") (EFieldAccess (EVar "a") "daData"))) (fa "deImpls" (EApp (EVar "implAccFinish") (EFieldAccess (EVar "a") "daImpls"))) (fa "deIfaces" (EApp (EVar "classEnvFinish") (EFieldAccess (EVar "a") "daIfaces"))) (fa "deMethods" (EFieldAccess (EVar "a") "daMethods")) (fa "deKindsBefore" (EFieldAccess (EFieldAccess (EVar "a") "daSeeds") "dsKinds")) (fa "deNameIndexBefore" (EFieldAccess (EFieldAccess (EVar "a") "daSeeds") "dsNames")) (fa "dePolaritiesBefore" (EApp (EVar "snd") (EFieldAccess (EVar "a") "daPolarity"))) (fa "deAtomsBefore" (EApp (EVar "snd") (EApp (EApp (EApp (EVar "declEnvRowAtomsChain") (EVar "gctx")) (EVar "mods")) (ETuple (EListLit) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (EListLit)) (EVar "omEmpty")))))) (fa "deOwnersBefore" (EFieldAccess (EFieldAccess (EVar "a") "daSeeds") "dsOwners")) (fa "deOwnerModules" (EFieldAccess (EVar "a") "daOwnerModules")) (fa "deReach" (EApp (EVar "declEnvReachIndex") (EVar "mods"))))))))
(DTypeSig false "declEnvRowKindEntries" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyCon "DeclEnvModule") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "declEnvRowKindEntries" ((PVar "gctx") (PVar "cur") (PVar "m")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "False")) (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EFieldAccess (EVar "m") "demDecls")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "True")) (EFieldAccess (EVar "m") "demKindEntries") (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "declEnvSeedChain" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "DeclEnvSeedAcc") (TyCon "DeclEnvSeedAcc")))))
(DFunDef false "declEnvSeedChain" ((PVar "gctx") (PList) (PVar "s")) (EVar "s"))
(DFunDef false "declEnvSeedChain" ((PVar "gctx") (PCons (PVar "m") (PVar "rest")) (PVar "s")) (EBlock (DoLet false false (PVar "kents") (EApp (EApp (EApp (EVar "declEnvRowKindEntries") (EVar "gctx")) (EBinOp "+" (EFieldAccess (EVar "m") "demOrd") (ELit (LInt 1)))) (EVar "m"))) (DoExpr (EApp (EApp (EApp (EVar "declEnvSeedChain") (EVar "gctx")) (EVar "rest")) (ERecordCreate "DeclEnvSeedAcc" ((fa "dsKAcc" (EBinOp "++" (EVar "kents") (EFieldAccess (EVar "s") "dsKAcc"))) (fa "dsOAcc" (EApp (EApp (EVar "declEnvDeclFieldOwners") (EApp (EApp (EVar "declEnvRowVisible") (EBinOp "+" (EFieldAccess (EVar "m") "demOrd") (ELit (LInt 1)))) (EVar "m"))) (EFieldAccess (EVar "s") "dsOAcc"))) (fa "dsNAcc" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EVar "tabKeyName") (EApp (EVar "fst") (EVar "p"))))) (EVar "kents"))) (EFieldAccess (EVar "s") "dsNAcc"))) (fa "dsKinds" (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "s") "dsKAcc")) (EFieldAccess (EVar "s") "dsKinds"))) (fa "dsOwners" (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "s") "dsOAcc")) (EFieldAccess (EVar "s") "dsOwners"))) (fa "dsNames" (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "s") "dsNAcc")) (EFieldAccess (EVar "s") "dsNames")))))))))
(DTypeSig false "declEnvRowAtomsChain" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))))))))
(DFunDef false "declEnvRowAtomsChain" ((PVar "gctx") (PList) (PVar "s")) (EVar "s"))
(DFunDef false "declEnvRowAtomsChain" ((PVar "gctx") (PCons (PVar "m") (PVar "rest")) (PTuple (PVar "aacc") (PVar "am"))) (EBlock (DoLet false false (PVar "entries") (EApp (EApp (EApp (EVar "declEnvRowAtomsEntries") (EVar "gctx")) (EBinOp "+" (EFieldAccess (EVar "m") "demOrd") (ELit (LInt 1)))) (EVar "m"))) (DoExpr (EApp (EApp (EApp (EVar "declEnvRowAtomsChain") (EVar "gctx")) (EVar "rest")) (ETuple (EBinOp "++" (EVar "entries") (EVar "aacc")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EVar "aacc")) (EVar "am")))))))
(DTypeSig false "declEnvRowAtomsEntries" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyCon "DeclEnvModule") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))))))
(DFunDef false "declEnvRowAtomsEntries" ((PVar "gctx") (PVar "cur") (PVar "m")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "False")) (EApp (EApp (EVar "declEnvRowAtomEntries") (EVar "gctx")) (EFieldAccess (EVar "m") "demDecls")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "True")) (EApp (EApp (EVar "declEnvRowAtomEntries") (EVar "gctx")) (EApp (EApp (EVar "filterList") (EVar "kindPublicDataDecl")) (EFieldAccess (EVar "m") "demDecls"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "declEnvRowAtomEntries" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "declEnvRowAtomEntries" ((PVar "gctx") (PList)) (EListLit))
(DFunDef false "declEnvRowAtomEntries" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "declEnvRowAtomEntries") (EVar "gctx")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "declEnvRowAtomEntries" ((PVar "gctx") (PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataCtors" (PVar "vs")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "inferParamRowAtoms") (EVar "gctx")) (EVar "ps")) (EVar "vs"))) (EApp (EApp (EVar "declEnvRowAtomEntries") (EVar "gctx")) (EVar "rest"))))
(DFunDef false "declEnvRowAtomEntries" ((PVar "gctx") (PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "inferParamRowAtoms") (EVar "gctx")) (EVar "ps")) (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty"))))))) (EApp (EApp (EVar "declEnvRowAtomEntries") (EVar "gctx")) (EVar "rest"))))
(DFunDef false "declEnvRowAtomEntries" ((PVar "gctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "declEnvRowAtomEntries") (EVar "gctx")) (EVar "rest")))
(DTypeSig false "declEnvDeclFieldOwners" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "declEnvDeclFieldOwners" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvDeclFieldOwners" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "declEnvDeclFieldOwners") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "declEnvDeclFieldOwners" ((PCons (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "declEnvDeclFieldOwners") (EVar "rest")) (EApp (EApp (EVar "declEnvVariantFieldOwners") (EVar "vs")) (EVar "acc"))))
(DFunDef false "declEnvDeclFieldOwners" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "declEnvDeclFieldOwners") (EVar "rest")) (EVar "acc")))
(DTypeSig false "declEnvVariantFieldOwners" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "declEnvVariantFieldOwners" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvVariantFieldOwners" ((PCons (PCon "Variant" (PVar "cn") (PCon "ConNamed" (PVar "fields") PWild)) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "declEnvVariantFieldOwners") (EVar "rest")) (EApp (EApp (EApp (EVar "addFieldOwners") (EVar "cn")) (EApp (EApp (EVar "map") (EVar "fieldNameOf")) (EVar "fields"))) (EVar "acc"))))
(DFunDef false "declEnvVariantFieldOwners" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "declEnvVariantFieldOwners") (EVar "rest")) (EVar "acc")))
(DTypeSig false "fieldNameOf" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldNameOf" ((PCon "Field" (PVar "fn") PWild)) (EVar "fn"))
(DTypeSig false "declEnvOwnerModules" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "declEnvOwnerModules" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvOwnerModules" ((PCons (PVar "m") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "declEnvOwnerModules") (EVar "rest")) (EApp (EApp (EApp (EVar "declEnvDeclOwnerModules") (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "m") "demDecls")) (EVar "acc"))))
(DTypeSig false "declEnvDeclOwnerModules" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "declEnvDeclOwnerModules" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvDeclOwnerModules" ((PVar "mid") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declEnvDeclOwnerModules") (EVar "mid")) (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "declEnvDeclOwnerModules" ((PVar "mid") (PCons (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declEnvDeclOwnerModules") (EVar "mid")) (EVar "rest")) (EApp (EApp (EApp (EVar "declEnvVariantOwnerModules") (EVar "mid")) (EVar "vs")) (EVar "acc"))))
(DFunDef false "declEnvDeclOwnerModules" ((PVar "mid") (PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declEnvDeclOwnerModules") (EVar "mid")) (EVar "rest")) (EVar "acc")))
(DTypeSig false "declEnvVariantOwnerModules" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "declEnvVariantOwnerModules" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvVariantOwnerModules" ((PVar "mid") (PCons (PCon "Variant" (PVar "cn") (PCon "ConNamed" PWild PWild)) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declEnvVariantOwnerModules") (EVar "mid")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "cn")) (EBinOp "::" (EVar "mid") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "cn")) (EVar "acc"))))) (EVar "acc"))))
(DFunDef false "declEnvVariantOwnerModules" ((PVar "mid") (PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declEnvVariantOwnerModules") (EVar "mid")) (EVar "rest")) (EVar "acc")))
(DTypeSig true "declEnvSeedDataUniverse" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "DeclEnvs") (TyCon "Unit")))))
(DFunDef false "declEnvSeedDataUniverse" ((PVar "mctx") (PVar "mid") (PVar "envs")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "envs") "deKindsBefore"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamNameIndexRef")) (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "envs") "deNameIndexBefore"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamPolarityRef")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "envs") "dePolaritiesBefore"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamRowAtomsRef")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "envs") "deAtomsBefore"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnersRef")) (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "envs") "deOwnersBefore"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnerModulesRef")) (EFieldAccess (EVar "envs") "deOwnerModules"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnerReachRef")) (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "envs") "deReach")))))))
(DTypeSig false "dataEnvFinish" (TyFun (TyCon "DataEnv") (TyCon "DataEnv")))
(DFunDef false "dataEnvFinish" ((PVar "env")) (EVariantUpdate "DataEnv" (EVar "env") ((fa "deRecordIdents" (EApp (EApp (EVar "omMapValues") (EVar "reverseL")) (EFieldAccess (EVar "env") "deRecordIdents"))) (fa "deFieldOwnerIdents" (EApp (EApp (EVar "omMapValues") (EVar "reverseL")) (EFieldAccess (EVar "env") "deFieldOwnerIdents"))))))
(DTypeSig false "dataEnvFromRowsGo" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "DataEnv") (TyCon "DataEnv"))))
(DFunDef false "dataEnvFromRowsGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "dataEnvFromRowsGo" ((PCons (PVar "m") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "dataEnvFromDeclsGo") (EFieldAccess (EVar "m") "demOrd")) (EFieldAccess (EVar "m") "demDecls")) (EVar "acc"))) (DoExpr (EApp (EApp (EVar "dataEnvFromRowsGo") (EVar "rest")) (EVariantUpdate "DataEnv" (EVar "env") ((fa "deCtorExports" (EApp (EApp (EVar "ctorExportsInto") (EVar "m")) (EFieldAccess (EVar "env") "deCtorExports")))))))))
(DTypeSig true "dataEnvFromDeclsGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "DataEnv") (TyCon "DataEnv")))))
(DFunDef false "dataEnvFromDeclsGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "dataEnvFromDeclsGo" ((PVar "ord") (PCons (PVar "d") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "dataEnvFromDeclsGo") (EVar "ord")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "dataEnvAddDecl") (EVar "ord")) (EVar "False")) (EVar "d")) (EVar "acc"))))
(DTypeSig false "dataEnvAddDecl" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Decl") (TyFun (TyCon "DataEnv") (TyCon "DataEnv"))))))
(DFunDef false "dataEnvAddDecl" ((PVar "ord") PWild (PCon "DAttrib" PWild (PVar "d")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "dataEnvAddDecl") (EVar "ord")) (EVar "True")) (EVar "d")) (EVar "acc")))
(DFunDef false "dataEnvAddDecl" ((PVar "ord") PWild (PRec "DData" ((rf "dataName" None) (rf "dataParams" None) (rf "dataCtors" None) (rf "dataOrigin" None)) true) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "addDataTypeDecl") (EVar "dataName")) (EVar "dataOrigin")) (EVar "dataParams")) (EVar "dataCtors")) (EVar "acc")))
(DFunDef false "dataEnvAddDecl" ((PVar "ord") PWild (PRec "DNewtype" ((rf "newtypeName" None) (rf "newtypeParams" None) (rf "newtypeCtor" None) (rf "newtypeFieldTy" None) (rf "newtypeOrigin" None)) true) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "addDataTypeDecl") (EVar "newtypeName")) (EVar "newtypeOrigin")) (EVar "newtypeParams")) (EListLit (EApp (EApp (EVar "Variant") (EVar "newtypeCtor")) (EApp (EVar "ConPos") (EListLit (EVar "newtypeFieldTy")))))) (EVar "acc")))
(DFunDef false "dataEnvAddDecl" ((PVar "ord") (PVar "att") (PAs "d" (PRec "DTypeAlias" ((rf "tyAliasName" None) (rf "tyAliasParams" None) (rf "tyAliasRhs" None) (rf "tyAliasOrigin" None)) true)) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addAliasDecl") (EVar "tyAliasName")) (EVar "tyAliasOrigin")) (EVar "tyAliasParams")) (EVar "tyAliasRhs")) (EVar "ord")) (EApp (EVar "publicDataDecl") (EVar "d"))) (EVar "att")) (EVar "acc")))
(DFunDef false "dataEnvAddDecl" (PWild PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "addDataTypeDecl" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyCon "DataEnv") (TyCon "DataEnv")))))))
(DFunDef false "addDataTypeDecl" ((PVar "name") (PVar "o") (PVar "params") (PVar "variants") (PVar "env")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name"))) (DoLet false false (PVar "dt") (ERecordCreate "DataTypeDecl" ((fa "dtKey" (EVar "key")) (fa "dtName" (EVar "name")) (fa "dtOrigin" (EVar "o")) (fa "dtParams" (EVar "params")) (fa "dtVariants" (EVar "variants"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "addVariantIdentsRaw") (EVar "name")) (EVar "o")) (EVar "variants")) (EVariantUpdate "DataEnv" (EVar "env") ((fa "deTypes" (EBinOp "::" (ETuple (EVar "key") (EVar "dt")) (EFieldAccess (EVar "env") "deTypes")))))))))
(DTypeSig false "addVariantIdentsRaw" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyCon "DataEnv") (TyCon "DataEnv"))))))
(DFunDef false "addVariantIdentsRaw" (PWild PWild (PList) (PVar "env")) (EVar "env"))
(DFunDef false "addVariantIdentsRaw" ((PVar "tyName") (PVar "o") (PCons (PCon "Variant" (PVar "cn") (PVar "payload")) (PVar "rest")) (PVar "env")) (EApp (EApp (EApp (EApp (EVar "addVariantIdentsRaw") (EVar "tyName")) (EVar "o")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "addCtorIdentRaw") (EVar "tyName")) (EVar "o")) (EVar "cn")) (EVar "payload")) (EVar "env"))))
(DTypeSig false "addCtorIdentRaw" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyCon "ConPayload") (TyFun (TyCon "DataEnv") (TyCon "DataEnv")))))))
(DFunDef false "addCtorIdentRaw" ((PVar "tyName") (PVar "o") (PVar "cn") (PVar "payload") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsCtor")) (EVar "o")) (EVar "cn")) (arm (PCon "None") () (EVar "env")) (arm (PCon "Some" (PVar "ident")) () (EBlock (DoLet false false (PVar "next") (EBinOp "++" (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "cn")) (EFieldAccess (EVar "env") "deCtorIdents"))) (EListLit (ETuple (EVar "ident") (EVar "tyName") (EApp (EApp (EVar "Variant") (EVar "cn")) (EVar "payload")))))) (DoLet false false (PVar "env2") (EVariantUpdate "DataEnv" (EVar "env") ((fa "deCtorIdents" (EApp (EApp (EApp (EVar "omInsert") (EVar "cn")) (EVar "next")) (EFieldAccess (EVar "env") "deCtorIdents")))))) (DoExpr (EMatch (EVar "payload") (arm (PCon "ConNamed" (PVar "fields") PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "addRecordIdentRaw") (EVar "tyName")) (EVar "cn")) (EVar "ident")) (EVar "fields")) (EVar "env2"))) (arm (PCon "ConPos" PWild) () (EVar "env2"))))))))
(DTypeSig false "addRecordIdentRaw" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyCon "DataEnv") (TyCon "DataEnv")))))))
(DFunDef false "addRecordIdentRaw" ((PVar "tyName") (PVar "cn") (PVar "ident") (PVar "fields") (PVar "env")) (EBlock (DoLet false false (PVar "next") (EBinOp "::" (ETuple (EVar "ident") (EVar "tyName") (EVar "fields")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "cn")) (EFieldAccess (EVar "env") "deRecordIdents"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "addFieldOwnerIdents") (EVar "ident")) (EVar "cn")) (EVar "fields")) (EVariantUpdate "DataEnv" (EVar "env") ((fa "deRecordIdents" (EApp (EApp (EApp (EVar "omInsert") (EVar "cn")) (EVar "next")) (EFieldAccess (EVar "env") "deRecordIdents")))))))))
(DTypeSig false "addFieldOwnerIdents" (TyFun (TyCon "Ident") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyCon "DataEnv") (TyCon "DataEnv"))))))
(DFunDef false "addFieldOwnerIdents" (PWild PWild (PList) (PVar "env")) (EVar "env"))
(DFunDef false "addFieldOwnerIdents" ((PVar "ident") (PVar "cn") (PCons (PCon "Field" (PVar "fn") PWild) (PVar "rest")) (PVar "env")) (EBlock (DoLet false false (PVar "next") (EBinOp "::" (ETuple (EVar "ident") (EVar "cn")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "fn")) (EFieldAccess (EVar "env") "deFieldOwnerIdents"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "addFieldOwnerIdents") (EVar "ident")) (EVar "cn")) (EVar "rest")) (EVariantUpdate "DataEnv" (EVar "env") ((fa "deFieldOwnerIdents" (EApp (EApp (EApp (EVar "omInsert") (EVar "fn")) (EVar "next")) (EFieldAccess (EVar "env") "deFieldOwnerIdents")))))))))
(DTypeSig false "addAliasDecl" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "DataEnv") (TyCon "DataEnv"))))))))))
(DFunDef false "addAliasDecl" ((PVar "name") (PVar "o") (PVar "params") (PVar "rhs") (PVar "ord") (PVar "pub") (PVar "att") (PVar "env")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name"))) (DoLet false false (PVar "ad") (ERecordCreate "AliasDecl" ((fa "adKey" (EVar "key")) (fa "adName" (EVar "name")) (fa "adParams" (EVar "params")) (fa "adRhs" (EVar "rhs")) (fa "adOrd" (EVar "ord")) (fa "adPub" (EVar "pub")) (fa "adAttrib" (EVar "att"))))) (DoExpr (EVariantUpdate "DataEnv" (EVar "env") ((fa "deAliases" (EBinOp "::" (ETuple (EVar "key") (EVar "ad")) (EFieldAccess (EVar "env") "deAliases"))))))))
(DTypeSig true "paramRowAtomsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TabKey") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "paramRowAtomsOf" ((PVar "mctx") (PVar "key")) (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamRowAtomsRef") "value")))
(DTypeSig false "constraintVarNamesTy" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constraintVarNamesTy" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "constraintArgVarNames")) (EVar "cs")) (EApp (EVar "constraintVarNamesTy") (EVar "t"))))
(DFunDef false "constraintVarNamesTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "constraintVarNamesTy") (EVar "t")))
(DFunDef false "constraintVarNamesTy" (PWild) (EListLit))
(DTypeSig false "constraintArgVarNames" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constraintArgVarNames" ((PRec "Constraint" ((rf "constraintArgs" (PVar "tys"))) false)) (EApp (EApp (EVar "flatMap") (EVar "tyVarNames")) (EVar "tys")))
(DTypeSig false "tyVarNamesWithConstraints" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyVarNamesWithConstraints" ((PVar "ty")) (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "tyVarNames") (EVar "ty")) (EApp (EVar "constraintVarNamesTy") (EVar "ty")))))
(DTypeSig true "tyConNamesInTy" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyConNamesInTy" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "tyConNamesInTy" ((PCon "TyVar" PWild)) (EListLit))
(DFunDef false "tyConNamesInTy" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "tyConNamesInTy") (EVar "a")) (EApp (EVar "tyConNamesInTy") (EVar "b"))))
(DFunDef false "tyConNamesInTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "tyConNamesInTy") (EVar "a")) (EApp (EVar "tyConNamesInTy") (EVar "b"))))
(DFunDef false "tyConNamesInTy" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EVar "tyConNamesInTy")) (EVar "ts")))
(DFunDef false "tyConNamesInTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "tyConNamesInTy") (EVar "t")))
(DFunDef false "tyConNamesInTy" ((PCon "TyRow" PWild PWild PWild)) (EListLit))
(DFunDef false "tyConNamesInTy" ((PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "tyConNamesInTy" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "tyConNamesInTy") (EVar "t")))
(DFunDef false "tyConNamesInTy" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "tyConNamesInTy") (EVar "t")))
(DFunDef false "tyConNamesInTy" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "tyConNamesInConstraint")) (EVar "cs")) (EApp (EVar "tyConNamesInTy") (EVar "t"))))
(DTypeSig false "tyConNamesInConstraint" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyConNamesInConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iname")) (rf "constraintArgs" (PVar "tys"))) false)) (EBinOp "::" (EVar "iname") (EApp (EApp (EVar "flatMap") (EVar "tyConNamesInTy")) (EVar "tys"))))
(DTypeSig false "takeUntilInclusiveS" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "takeUntilInclusiveS" (PWild (PList)) (EListLit))
(DFunDef false "takeUntilInclusiveS" ((PVar "target") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "x") (EVar "target")) (EListLit (EVar "x")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeUntilInclusiveS") (EVar "target")) (EVar "xs")))))
(DTypeSig false "buildAliasGraphEntry" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildAliasGraphEntry" ((PVar "aliasSet") (PTuple (PVar "key") (PVar "paramsRhs"))) (EBlock (DoLet false false (PVar "rhs") (EApp (EVar "snd") (EVar "paramsRhs"))) (DoExpr (ETuple (EApp (EVar "tabKeyName") (EVar "key")) (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "aliasSet")))) (EApp (EVar "dedup") (EApp (EVar "tyConNamesInTy") (EVar "rhs"))))))))
(DTypeSig false "aliasDfsVisit" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "Unit"))))))))
(DFunDef false "aliasDfsVisit" ((PVar "graph") (PVar "visitedRef") (PVar "onStackRef") (PVar "onStackSetRef") (PVar "cyclicOut") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EUnOp "!" (EVar "visitedRef"))) (ELit LUnit) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EUnOp "!" (EVar "onStackSetRef"))) (EApp (EApp (EVar "setRef") (EVar "cyclicOut")) (EApp (EVar "dedup") (EBinOp "++" (EApp (EApp (EVar "takeUntilInclusiveS") (EVar "name")) (EUnOp "!" (EVar "onStackRef"))) (EUnOp "!" (EVar "cyclicOut"))))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "onStackRef")) (EBinOp "::" (EVar "name") (EUnOp "!" (EVar "onStackRef"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "onStackSetRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EUnOp "!" (EVar "onStackSetRef"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasDfsVisitNeighbors") (EVar "graph")) (EVar "visitedRef")) (EVar "onStackRef")) (EVar "onStackSetRef")) (EVar "cyclicOut")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "graph"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "onStackRef")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "name")))) (EUnOp "!" (EVar "onStackRef"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "onStackSetRef")) (EApp (EApp (EVar "omDelete") (EVar "name")) (EUnOp "!" (EVar "onStackSetRef"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "visitedRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EUnOp "!" (EVar "visitedRef")))))))))
(DTypeSig false "aliasDfsVisitNeighbors" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))))))
(DFunDef false "aliasDfsVisitNeighbors" (PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "aliasDfsVisitNeighbors" ((PVar "graph") (PVar "visitedRef") (PVar "onStackRef") (PVar "onStackSetRef") (PVar "cyclicOut") (PCons (PVar "n") (PVar "ns"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasDfsVisit") (EVar "graph")) (EVar "visitedRef")) (EVar "onStackRef")) (EVar "onStackSetRef")) (EVar "cyclicOut")) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasDfsVisitNeighbors") (EVar "graph")) (EVar "visitedRef")) (EVar "onStackRef")) (EVar "onStackSetRef")) (EVar "cyclicOut")) (EVar "ns")))))
(DTypeSig false "aliasDfsVisitAll" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))))))
(DFunDef false "aliasDfsVisitAll" (PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "aliasDfsVisitAll" ((PVar "graph") (PVar "visitedRef") (PVar "onStackRef") (PVar "onStackSetRef") (PVar "cyclicOut") (PCons (PVar "k") (PVar "ks"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasDfsVisit") (EVar "graph")) (EVar "visitedRef")) (EVar "onStackRef")) (EVar "onStackSetRef")) (EVar "cyclicOut")) (EVar "k"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasDfsVisitAll") (EVar "graph")) (EVar "visitedRef")) (EVar "onStackRef")) (EVar "onStackSetRef")) (EVar "cyclicOut")) (EVar "ks")))))
(DTypeSig false "emitCyclicAliasErrors" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "emitCyclicAliasErrors" ((PVar "mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "emitCyclicAliasErrors" ((PVar "mctx") (PVar "prog") (PVar "table") (PCons (PVar "name") (PVar "rest"))) (EBlock (DoLet false false (PVar "reader") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentModuleRef") "value")) (DoLet false false (PVar "named") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "tabKeyName") (EApp (EVar "fst") (EVar "e"))) (EVar "name")))) (EVar "table"))) (DoLet false false (PVar "loc") (EMatch (EApp (EApp (EVar "find") (ELam ((PVar "e")) (EApp (EApp (EVar "aliasDeclaredBy") (EVar "reader")) (EApp (EVar "fst") (EVar "e"))))) (EVar "named")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "firstTyLoc") (EApp (EVar "snd") (EApp (EVar "snd") (EVar "e"))))) (arm (PCon "None") () (EApp (EApp (EVar "findMap") (ELam ((PVar "e")) (EMatch (EApp (EVar "tabKeyModule") (EApp (EVar "fst") (EVar "e"))) (arm (PCon "Some" (PVar "owner")) () (EApp (EApp (EApp (EVar "importLocFor") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deReach")) (EVar "prog")) (EVar "owner"))) (arm (PCon "None") () (EVar "None"))))) (EVar "named"))))) (DoExpr (EApp (EApp (EApp (EVar "pushTypeErrorOnce") (EApp (EApp (EVar "mctxAtIfSome") (EVar "loc")) (EVar "mctx"))) (ELit (LString "T-RECURSIVE-ALIAS"))) (EBinOp "++" (EBinOp "++" (ELit (LString "type alias `")) (EVar "name")) (ELit (LString "` is recursive; a type alias cannot refer to itself, so declare a `data` type instead"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "emitCyclicAliasErrors") (EVar "mctx")) (EVar "prog")) (EVar "table")) (EVar "rest")))))
(DTypeSig false "aliasDeclaredBy" (TyFun (TyCon "String") (TyFun (TyCon "TabKey") (TyCon "Bool"))))
(DFunDef false "aliasDeclaredBy" ((PVar "reader") (PVar "key")) (EMatch (EApp (EVar "tabKeyModule") (EVar "key")) (arm (PCon "Some" (PVar "owner")) () (EBinOp "==" (EVar "owner") (EVar "reader"))) (arm (PCon "None") () (EVar "True"))))
(DTypeSig false "tabKeyModule" (TyFun (TyCon "TabKey") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "tabKeyModule" ((PCon "TkIdent" (PCon "Ident" PWild (PVar "origin") PWild))) (EApp (EApp (EApp (EVar "identOriginFold") (EVar "None")) (ELam ((PVar "mid")) (EApp (EVar "Some") (EVar "mid")))) (EVar "origin")))
(DFunDef false "tabKeyModule" ((PCon "TkBare" PWild PWild)) (EVar "None"))
(DTypeSig true "rejectCyclicAliases" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "rejectCyclicAliases" ((PVar "mctx") (PVar "prog")) (EBlock (DoLet false false (PVar "table") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (DoLet false false (PVar "aliasKeys") (EApp (EApp (EVar "map") (ELam ((PVar "e")) (EApp (EVar "tabKeyName") (EApp (EVar "fst") (EVar "e"))))) (EVar "table"))) (DoLet false false (PVar "aliasSet") (EApp (EApp (EVar "omFromNames") (EVar "aliasKeys")) (EVar "omEmpty"))) (DoLet false false (PVar "graph") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "map") (EApp (EVar "buildAliasGraphEntry") (EVar "aliasSet"))) (EVar "table")))) (EVar "omEmpty"))) (DoLet false false (PVar "visitedRef") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoLet false false (PVar "onStackRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "onStackSetRef") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoLet false false (PVar "cyclicOut") (EApp (EVar "Ref") (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasDfsVisitAll") (EVar "graph")) (EVar "visitedRef")) (EVar "onStackRef")) (EVar "onStackSetRef")) (EVar "cyclicOut")) (EVar "aliasKeys"))) (DoLet false false (PVar "cyclic") (EUnOp "!" (EVar "cyclicOut"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "emitCyclicAliasErrors") (EVar "mctx")) (EVar "prog")) (EVar "table")) (EVar "cyclic"))) (DoLet false false (PVar "cyclicSet") (EApp (EApp (EVar "omFromNames") (EVar "cyclic")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef")) (EApp (EApp (EVar "filterList") (ELam ((PVar "entry")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "tabKeyName") (EApp (EVar "fst") (EVar "entry")))) (EVar "cyclicSet"))))) (EVar "table"))))))
(DTypeSig true "astTypeFreshTbl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "astTypeFreshTbl" ((PVar "outer") (PVar "ty")) (EApp (EApp (EApp (EVar "atSignature") (EVar "outer")) (EVar "ty")) (ELam ((PVar "mctx")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "rowArgNames") (EVar "mctx")) (EVar "ty"))) (DoLet false false (PVar "auths") (EApp (EApp (EVar "authArgBindersIn") (EVar "mctx")) (EVar "ty"))) (DoLet false false (PVar "etbl") (EApp (EApp (EApp (EApp (EVar "sigVarsForWith") (EVar "mctx")) (EVar "ty")) (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "effTailNames") (EVar "ty")) (EVar "rows")))) (EVar "auths"))) (DoLet false false (PVar "tvs") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EApp (EApp (EVar "sigTyVarNames") (EVar "ty")) (EVar "rows")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "auths"))))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty")) (EVar "tvs")))))))
(DTypeSig false "atSignature" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyFun (TyCon "ModuleCtx") (TyVar "a")) (TyVar "a")))))
(DFunDef false "atSignature" ((PVar "mctx") (PVar "ty") (PVar "body")) (EApp (EVar "body") (EApp (EApp (EVar "mctxAtIfSome") (EApp (EVar "firstTyLoc") (EVar "ty"))) (EVar "mctx"))))
(DTypeSig true "sigToScheme" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Scheme"))))
(DFunDef false "sigToScheme" ((PVar "mctx") (PVar "ty")) (EApp (EVar "fst") (EApp (EApp (EVar "sigToSchemeTvs") (EVar "mctx")) (EVar "ty"))))
(DTypeSig true "sigToSchemeTvs" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyTuple (TyCon "Scheme") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "sigToSchemeTvs" ((PVar "mctx") (PVar "ty")) (EApp (EApp (EApp (EVar "sigToSchemeTvsIn") (EVar "mctx")) (EListLit)) (EVar "ty")))
(DTypeSig true "sigToSchemeTvsIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Scheme") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))
(DFunDef false "sigToSchemeTvsIn" ((PVar "outer") (PVar "scope") (PVar "ty")) (EApp (EApp (EApp (EVar "atSignature") (EVar "outer")) (EVar "ty")) (ELam ((PVar "mctx")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EApp (EApp (EApp (EVar "qualifiedKindScope") (EVar "mctx")) (EVar "scope")) (EVar "ty"))) (EVar "ty"))) (DoLet false false (PVar "auths") (EApp (EApp (EVar "authArgBindersIn") (EVar "mctx")) (EVar "ty"))) (DoLet false false (PVar "tvs") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EApp (EApp (EVar "sigTyVarNames") (EVar "ty")) (EVar "rows")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "auths"))))) (DoLet false false (PVar "etbl") (EApp (EApp (EApp (EApp (EVar "sigVarsForWith") (EVar "mctx")) (EVar "ty")) (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "effTailNames") (EVar "ty")) (EVar "rows")))) (EVar "auths"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EApp (EApp (EVar "map") (EVar "monoTyvarId")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "tvs")))) (EApp (EApp (EVar "map") (EVar "effvarIdOf")) (EFieldAccess (EVar "etbl") "svRows"))) (EApp (EApp (EVar "map") (EVar "authvarIdOf")) (EFieldAccess (EVar "etbl") "svAuths"))) (EListLit)) (EApp (EApp (EApp (EApp (EVar "bindingForceFromAst") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty"))) (EVar "tvs")))))))
(DTypeSig true "sigVarsFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "SigVars")))))
(DFunDef false "sigVarsFor" ((PVar "mctx") (PVar "ty") (PVar "rowNames")) (EApp (EApp (EApp (EApp (EVar "sigVarsForWith") (EVar "mctx")) (EVar "ty")) (EVar "rowNames")) (EApp (EApp (EVar "authArgBindersIn") (EVar "mctx")) (EVar "ty"))))
(DTypeSig false "sigVarsForWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "SigVars"))))))
(DFunDef false "sigVarsForWith" ((PVar "mctx") (PVar "ty") (PVar "rowNames") (PVar "auths")) (EBlock (DoLet false false (PVar "named") (EApp (EVar "namedArgTypes") (EVar "ty"))) (DoLet false false (PVar "authNames") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "auths"))) (DoLet false false (PVar "uses") (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "binderDomainsIn") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty")) (EApp (EApp (EVar "namedAtomBinders") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty"))) (EVar "auths"))) (DoExpr (EApp (EApp (EApp (EVar "reportBinderDomains") (EVar "mctx")) (EVar "ty")) (EVar "uses"))) (DoLet false false (PVar "ranged") (EApp (EApp (EApp (EVar "binderIsPattern") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "namedArgDomains") (EVar "ty"))) (EApp (EApp (EVar "patternSlotNamesIn") (EVar "mctx")) (EVar "ty")))) (DoLet false false (PVar "sv") (ERecordCreate "SigVars" ((fa "svRows" (EApp (EApp (EVar "freshEffMap") (EVar "mctx")) (EVar "rowNames"))) (fa "svAuths" (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EApp (EApp (EApp (EVar "freshAuthBinderRanged") (EVar "mctx")) (EApp (EVar "ranged") (EApp (EVar "fst") (EVar "b")))) (EVar "b")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EApp (EVar "authorityBinderBound") (EVar "named")) (EVar "authNames")) (EApp (EVar "fst") (EVar "b"))))) (EApp (EApp (EVar "dedupBinders") (EVar "uses")) (EListLit)))))))) (DoExpr (EApp (EApp (EApp (EVar "reportUnboundAuthorityNames") (EVar "mctx")) (EVar "ty")) (EVar "sv"))) (DoExpr (EVar "sv"))))
(DTypeSig false "sigTyVarNames" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sigTyVarNames" ((PVar "ty") (PVar "rows") (PVar "authNames")) (EApp (EApp (EVar "removeAllS") (EBinOp "++" (EVar "rows") (EVar "authNames"))) (EApp (EVar "tyVarNamesWithConstraints") (EVar "ty"))))
(DTypeSig false "binderIsPattern" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "EffAtomTy")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "binderIsPattern" ((PVar "gctx") (PVar "domains") (PVar "pats") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "domains")) (arm (PCon "Some" (PCon "Some" (PVar "d"))) () (EApp (EApp (EApp (EVar "rangedOver") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "d") "eatLabel")) (EFieldAccess (EVar "d") "eatOrigin"))) (EFieldAccess (EVar "d") "eatPattern"))) (arm (PCon "Some" (PCon "None")) () (EVar "False")) (arm (PCon "None") () (EApp (EApp (EVar "contains") (EVar "n")) (EVar "pats")))))
(DTypeSig true "dedupBinders" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "dedupBinders" ((PList) (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "dedupBinders" ((PCons (PTuple (PVar "n") (PVar "top")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "acc"))) (EApp (EApp (EVar "dedupBinders") (EVar "rest")) (EVar "acc")) (EApp (EApp (EVar "dedupBinders") (EVar "rest")) (EBinOp "::" (ETuple (EVar "n") (EVar "top")) (EVar "acc")))))
(DTypeSig true "rowArgAtomsIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "rowArgAtomsIn" ((PVar "mctx") (PVar "scope") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "kinded") (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EVar "rowArgAtomsApp") (EVar "mctx")) (EVar "scope")) (EVar "o")) (EVar "n")) (EVar "args"))) (arm (PTuple (PCon "TyVar" (PVar "h")) (PVar "args")) () (EApp (EApp (EApp (EApp (EVar "rowArgAtomsVarApp") (EVar "mctx")) (EVar "scope")) (EVar "h")) (EVar "args"))) (arm PWild () (EVar "None")))) (DoExpr (EMatch (EVar "kinded") (arm (PCon "Some" (PVar "occs")) () (EVar "occs")) (arm (PCon "None") () (EBinOp "++" (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "b"))))))))
(DFunDef false "rowArgAtomsIn" ((PVar "mctx") (PVar "scope") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "b"))))
(DFunDef false "rowArgAtomsIn" ((PVar "mctx") (PVar "scope") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope"))) (EVar "ts")))
(DFunDef false "rowArgAtomsIn" ((PVar "mctx") (PVar "scope") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "rowArgAtomsIn" ((PVar "mctx") (PVar "scope") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "rowArgAtomsIn" ((PVar "mctx") PWild PWild) (EListLit))
(DTypeSig false "rowArgAtomsApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))))))
(DFunDef false "rowArgAtomsApp" ((PVar "mctx") (PVar "scope") (PVar "o") (PVar "n") (PVar "args")) (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "kinds")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "paramRowAtomsOf") (EVar "mctx")) (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))))) (EVar "args")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope"))) (EVar "args"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "rowArgAtomsVarApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))))))
(DFunDef false "rowArgAtomsVarApp" ((PVar "mctx") (PVar "scope") (PVar "h") (PVar "args")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "h")) (EVar "scope")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "kinds")) (EListLit)) (EVar "args")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope"))) (EVar "args"))))) (arm PWild () (EVar "None"))))
(DTypeSig true "krowArgVarAtoms" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))))
(DFunDef false "krowArgVarAtoms" ((PVar "gctx") (PList) PWild PWild) (EListLit))
(DFunDef false "krowArgVarAtoms" ((PVar "gctx") PWild PWild (PList)) (EListLit))
(DFunDef false "krowArgVarAtoms" ((PVar "gctx") (PCons (PCon "KRow") (PVar "ks")) (PVar "decls") (PCons (PCon "TyVar" (PVar "n")) (PVar "as2"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EVar "head") (EVar "decls")))) (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EVar "gctx")) (EVar "ks")) (EApp (EVar "restAtoms") (EVar "decls"))) (EVar "as2"))))
(DFunDef false "krowArgVarAtoms" ((PVar "gctx") (PCons (PCon "KRow") (PVar "ks")) (PVar "decls") (PCons (PCon "TyRow" (PVar "labels") (PVar "tails") PWild) (PVar "as2"))) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "atomsNorm") (EBinOp "++" (EApp (EApp (EVar "atomsOfWritten") (EVar "gctx")) (EVar "labels")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EVar "head") (EVar "decls")))))))) (EVar "tails")) (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EVar "gctx")) (EVar "ks")) (EApp (EVar "restAtoms") (EVar "decls"))) (EVar "as2"))))
(DFunDef false "krowArgVarAtoms" ((PVar "gctx") (PCons PWild (PVar "ks")) (PVar "decls") (PCons PWild (PVar "as2"))) (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EVar "gctx")) (EVar "ks")) (EApp (EVar "restAtoms") (EVar "decls"))) (EVar "as2")))
(DTypeSig false "restAtoms" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "restAtoms" ((PList)) (EListLit))
(DFunDef false "restAtoms" ((PCons PWild (PVar "rest"))) (EVar "rest"))
(DTypeSig true "builtinClassesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "BuiltinClasses")))
(DFunDef false "builtinClassesOf" ((PVar "decls")) (EApp (EApp (EVar "builtinClassesGo") (EVar "decls")) (EVar "emptyBuiltinClasses")))
(DTypeSig true "builtinClassesGo" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "BuiltinClasses") (TyCon "BuiltinClasses"))))
(DFunDef false "builtinClassesGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "builtinClassesGo" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "builtinClassesGo") (EVar "rest")) (EApp (EApp (EVar "builtinClassesGo") (EListLit (EVar "d"))) (EVar "acc"))))
(DFunDef false "builtinClassesGo" ((PCons (PRec "DInterface" ((rf "name" None) (rf "ifaceOrigin" (PVar "o")) (rf "methods" None)) true) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "builtinClassesGo") (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "builtinClassSet") (EVar "name")) (EVar "o")) (EApp (EVar "isNonEmptyL") (EVar "methods"))) (EVar "acc"))))
(DFunDef false "builtinClassesGo" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "builtinClassesGo") (EVar "rest")) (EVar "acc")))
(DTypeSig false "builtinClassSet" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "Bool") (TyFun (TyCon "BuiltinClasses") (TyCon "BuiltinClasses"))))))
(DFunDef false "builtinClassSet" ((PLit (LString "Num")) PWild PWild (PVar "acc")) (EIf (EFieldAccess (EVar "acc") "bcNumPresent") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "builtinClassSet" ((PLit (LString "Num")) (PVar "o") (PVar "p") (PVar "acc")) (EVariantUpdate "BuiltinClasses" (EVar "acc") ((fa "bcNum" (EVar "o")) (fa "bcNumPresent" (EBinOp "||" (EFieldAccess (EVar "acc") "bcNumPresent") (EVar "p"))))))
(DFunDef false "builtinClassSet" ((PLit (LString "Eq")) PWild PWild (PVar "acc")) (EIf (EFieldAccess (EVar "acc") "bcEqPresent") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "builtinClassSet" ((PLit (LString "Eq")) (PVar "o") (PVar "p") (PVar "acc")) (EVariantUpdate "BuiltinClasses" (EVar "acc") ((fa "bcEq" (EVar "o")) (fa "bcEqPresent" (EBinOp "||" (EFieldAccess (EVar "acc") "bcEqPresent") (EVar "p"))))))
(DFunDef false "builtinClassSet" ((PLit (LString "Ord")) PWild PWild (PVar "acc")) (EIf (EFieldAccess (EVar "acc") "bcOrdPresent") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "builtinClassSet" ((PLit (LString "Ord")) (PVar "o") (PVar "p") (PVar "acc")) (EVariantUpdate "BuiltinClasses" (EVar "acc") ((fa "bcOrd" (EVar "o")) (fa "bcOrdPresent" (EBinOp "||" (EFieldAccess (EVar "acc") "bcOrdPresent") (EVar "p"))))))
(DFunDef false "builtinClassSet" ((PLit (LString "Semigroup")) PWild PWild (PVar "acc")) (EIf (EFieldAccess (EVar "acc") "bcSemigroupPresent") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "builtinClassSet" ((PLit (LString "Semigroup")) (PVar "o") (PVar "p") (PVar "acc")) (EVariantUpdate "BuiltinClasses" (EVar "acc") ((fa "bcSemigroup" (EVar "o")) (fa "bcSemigroupPresent" (EBinOp "||" (EFieldAccess (EVar "acc") "bcSemigroupPresent") (EVar "p"))))))
(DFunDef false "builtinClassSet" (PWild PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig true "registerData" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Decl") (TyCon "TcEnv"))))
(DFunDef false "registerData" ((PVar "env") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "registerData") (EVar "env")) (EVar "d")))
(DFunDef false "registerData" ((PVar "env") (PRec "DData" ((rf "dataName" (PVar "name")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "anns")) (rf "dataCtors" (PVar "variants")) (rf "dataCtorBinders" (PVar "binders")) (rf "dataOrigin" (PVar "o"))) false)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerVariants") (EVar "o")) (EVar "env")) (EVar "name")) (EVar "params")) (EVar "anns")) (EVar "variants")) (EVar "binders")))
(DFunDef false "registerData" ((PVar "env") (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "name")) (rf "tyAliasParams" (PVar "params")) (rf "tyAliasRhs" (PVar "rhs")) (rf "tyAliasOrigin" (PVar "o"))) false)) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "aliasTableRef")) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name")) (ETuple (EVar "params") (EVar "rhs"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "aliasTableRef") "value")))) (DoExpr (EVar "env"))))
(DFunDef false "registerData" ((PVar "env") (PRec "DNewtype" ((rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "params")) (rf "newtypeParamKinds" (PVar "anns")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeCtorBinders" (PVar "binders")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeOrigin" (PVar "o"))) false)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerVariants") (EVar "o")) (EVar "env")) (EVar "name")) (EVar "params")) (EVar "anns")) (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty")))))) (EListLit (EVar "binders"))))
(DFunDef false "registerData" ((PVar "env") PWild) (EVar "env"))
(DTypeSig false "registerRecordInfoKeyed" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyCon "Unit"))))))))))
(DFunDef false "registerRecordInfoKeyed" ((PVar "mctx") (PVar "o") (PVar "key") (PVar "typeName") (PVar "params") (PVar "kinds") (PVar "binders") (PVar "fields")) (EBlock (DoLet false false (PVar "paramReprs") (EApp (EApp (EApp (EVar "mintParamReprs") (EVar "mctx")) (EVar "params")) (EVar "kinds"))) (DoLet false false (PVar "tvs") (EApp (EApp (EApp (EVar "ktypeTvs") (EVar "params")) (EVar "kinds")) (EVar "paramReprs"))) (DoLet false false (PVar "opened") (EApp (EApp (EVar "existentialCells") (EVar "mctx")) (EVar "binders"))) (DoExpr (EApp (EApp (EVar "recordExistentials") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "opened"))) (DoLet false false (PVar "etbl") (EApp (EApp (EVar "sigVarsWithAuths") (EVar "opened")) (EApp (EApp (EApp (EVar "paramEtbl") (EVar "params")) (EVar "kinds")) (EVar "paramReprs")))) (DoLet false false (PVar "result") (EApp (EApp (EVar "applyParams") (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "typeName"))) (EVar "paramReprs"))) (DoLet false false (PVar "fieldMonos") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "recFieldMono") (EVar "mctx")) (EVar "etbl")) (EVar "tvs"))) (EVar "fields"))) (DoLet false false (PVar "ri") (EApp (EApp (EApp (EApp (EApp (EVar "RecordInfo") (EApp (EVar "collectTyIds") (EVar "paramReprs"))) (EBinOp "++" (EApp (EVar "collectAuthvarIds") (EVar "paramReprs")) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EApp (EVar "authvarId") (EApp (EVar "snd") (EVar "c"))))) (EVar "opened")))) (EVar "result")) (EVar "fieldMonos")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "fieldMonos"))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "ri")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnersRef")) (EApp (EApp (EApp (EVar "addFieldOwners") (EVar "key")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "fieldMonos"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnersRef") "value"))))))
(DTypeSig true "addFieldOwners" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "addFieldOwners" (PWild (PList) (PVar "m")) (EVar "m"))
(DFunDef false "addFieldOwners" ((PVar "key") (PCons (PVar "fn") (PVar "rest")) (PVar "m")) (EApp (EApp (EApp (EVar "addFieldOwners") (EVar "key")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "fn")) (EBinOp "::" (EVar "key") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "fn")) (EVar "m"))))) (EVar "m"))))
(DTypeSig false "registerVariants" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))) (TyCon "TcEnv")))))))))
(DFunDef false "registerVariants" ((PVar "o") (PVar "env") (PVar "name") (PVar "params") (PVar "anns") (PVar "variants") (PVar "binders")) (EBlock (DoLet false false (PVar "kinds") (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "params")) (EVar "anns"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "dataParamPolarityRef") "value")) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "recordParamPolarities") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "o")) (EVar "name")) (EApp (EApp (EApp (EApp (EVar "inferParamPolarities") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "dataParamPolarityRef") "value")) (EVar "params")) (EVar "anns")) (EVar "variants")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordParamRowAtoms") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "o")) (EVar "name")) (EApp (EApp (EApp (EVar "inferParamRowAtoms") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "params")) (EVar "variants")))) (DoLet false false (PVar "paramReprs") (EApp (EApp (EApp (EVar "mintParamReprs") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "params")) (EVar "kinds"))) (DoLet false false (PVar "tvs") (EApp (EApp (EApp (EVar "ktypeTvs") (EVar "params")) (EVar "kinds")) (EVar "paramReprs"))) (DoLet false false (PVar "etbl") (EApp (EApp (EApp (EVar "paramEtbl") (EVar "params")) (EVar "kinds")) (EVar "paramReprs"))) (DoLet false false (PVar "paramTyIds") (EApp (EVar "collectTyIds") (EVar "paramReprs"))) (DoLet false false (PVar "rowEffvarIds") (EApp (EVar "collectRowEffvarIds") (EVar "paramReprs"))) (DoLet false false (PVar "authvarIds") (EApp (EVar "collectAuthvarIds") (EVar "paramReprs"))) (DoLet false false (PVar "result") (EApp (EApp (EVar "applyParams") (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "name"))) (EVar "paramReprs"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerNamedFieldVariants") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "o")) (EVar "name")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EVar "binders"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addVariants") (EVar "env")) (EVar "tvs")) (EVar "etbl")) (EVar "paramTyIds")) (EVar "rowEffvarIds")) (EVar "authvarIds")) (EVar "result")) (EVar "variants")) (EApp (EApp (EVar "padCtorBinders") (EVar "variants")) (EVar "binders"))))))
(DTypeSig false "recordCtors" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyCon "DataVis") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Unit"))))))))
(DFunDef false "recordCtors" ((PVar "gctx") (PVar "o") (PVar "name") (PVar "vis") (PVar "params") (PVar "variants")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeDataCtors")) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name")) (ETuple (EVar "vis") (EVar "params") (EVar "variants"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeDataCtors") "value"))))
(DTypeSig false "recordParamKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Unit"))))))
(DFunDef false "recordParamKinds" ((PVar "mctx") (PVar "o") (PVar "name") (PVar "kinds")) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name")) (EVar "kinds"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef")) (EBinOp "::" (EVar "entry") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamNameIndexRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamNameIndexRef") "value"))))))
(DTypeSig false "recordParamRowAtoms" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyCon "Unit"))))))
(DFunDef false "recordParamRowAtoms" ((PVar "mctx") (PVar "o") (PVar "name") (PVar "atomss")) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name")) (EVar "atomss"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamRowAtomsRef")) (EBinOp "::" (EVar "entry") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamRowAtomsRef") "value"))))))
(DTypeSig false "inferParamRowAtoms" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "inferParamRowAtoms" ((PVar "gctx") (PVar "params") (PVar "variants")) (EBlock (DoLet false false (PVar "fieldTys") (EApp (EApp (EVar "flatMap") (ELam ((PVar "v")) (EApp (EVar "payloadAstTypes") (EApp (EVar "variantPayload") (EVar "v"))))) (EVar "variants"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "intersectDeclAtoms") (EVar "gctx")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "t")))) (EVar "fieldTys"))))) (EVar "params")))))
(DTypeSig false "paramRowAtomOccs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyVar" (PVar "n"))) (EIf (EBinOp "==" (EVar "n") (EVar "p")) (EListLit (EListLit)) (EListLit)))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") PWild (PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyEffect" (PVar "labels") (PVar "tails") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "paramRowAtomsFor") (EVar "gctx")) (EVar "p")) (EVar "tails")) (EVar "labels")) (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "t"))))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyRow" (PVar "labels") (PVar "tails") PWild)) (EApp (EApp (EApp (EApp (EVar "paramRowAtomsFor") (EVar "gctx")) (EVar "p")) (EVar "tails")) (EVar "labels")))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "a")) (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "b"))))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p"))) (EVar "ts")))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "a")) (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "b"))))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "t")))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") PWild PWild) (EListLit))
(DTypeSig false "paramRowAtomsFor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "paramRowAtomsFor" ((PVar "gctx") (PVar "p") (PVar "tails") (PVar "labels")) (EApp (EApp (EVar "map") (ELam (PWild) (EApp (EApp (EVar "atomsOfWritten") (EVar "gctx")) (EVar "labels")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "p")))) (EVar "tails"))))
(DTypeSig false "intersectDeclAtoms" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "intersectDeclAtoms" ((PVar "gctx") (PList)) (EListLit))
(DFunDef false "intersectDeclAtoms" ((PVar "gctx") (PCons (PVar "first") (PVar "rest"))) (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EApp (EApp (EVar "allList") (ELam ((PVar "b")) (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EListLit (EVar "x"))) (EVar "b"))))) (EVar "rest")))) (EVar "first")))
(DTypeSig false "mintParamReprs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "mintParamReprs" ((PVar "mctx") (PCons PWild (PVar "ps")) (PCons (PCon "KType") (PVar "ks"))) (EBinOp "::" (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)) (EApp (EApp (EApp (EVar "mintParamReprs") (EVar "mctx")) (EVar "ps")) (EVar "ks"))))
(DFunDef false "mintParamReprs" ((PVar "mctx") (PCons PWild (PVar "ps")) (PCons (PCon "KRow") (PVar "ks"))) (EBinOp "::" (EApp (EVar "TEff") (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EApp (EApp (EVar "freshEffvar") (EVar "mctx")) (ELit LUnit))))) (EApp (EApp (EApp (EVar "mintParamReprs") (EVar "mctx")) (EVar "ps")) (EVar "ks"))))
(DFunDef false "mintParamReprs" ((PVar "mctx") (PCons (PVar "p") (PVar "ps")) (PCons (PCon "KAuth" (PVar "l") (PVar "pat")) (PVar "ks"))) (EBinOp "::" (EApp (EVar "TAuth") (EApp (EVar "AVar") (EApp (EApp (EApp (EApp (EVar "freshAuthvarRanged") (EVar "mctx")) (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))) (EVar "pat")) (EApp (EVar "Some") (EVar "p"))))) (EApp (EApp (EApp (EVar "mintParamReprs") (EVar "mctx")) (EVar "ps")) (EVar "ks"))))
(DFunDef false "mintParamReprs" ((PVar "mctx") PWild PWild) (EListLit))
(DTypeSig false "ktypeTvs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "ktypeTvs" ((PCons (PVar "p") (PVar "ps")) (PCons (PCon "KType") (PVar "ks")) (PCons (PVar "r") (PVar "rs"))) (EBinOp "::" (ETuple (EVar "p") (EVar "r")) (EApp (EApp (EApp (EVar "ktypeTvs") (EVar "ps")) (EVar "ks")) (EVar "rs"))))
(DFunDef false "ktypeTvs" ((PCons (PVar "p") (PVar "ps")) (PCons PWild (PVar "ks")) (PCons PWild (PVar "rs"))) (EApp (EApp (EApp (EVar "ktypeTvs") (EVar "ps")) (EVar "ks")) (EVar "rs")))
(DFunDef false "ktypeTvs" (PWild PWild PWild) (EListLit))
(DTypeSig false "paramEtbl" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "SigVars")))))
(DFunDef false "paramEtbl" ((PVar "params") (PVar "kinds") (PVar "reprs")) (ERecordCreate "SigVars" ((fa "svRows" (EApp (EApp (EApp (EVar "krowRows") (EVar "params")) (EVar "kinds")) (EVar "reprs"))) (fa "svAuths" (EApp (EApp (EApp (EVar "kauthCells") (EVar "params")) (EVar "kinds")) (EVar "reprs"))))))
(DTypeSig false "kauthCells" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar"))))))))
(DFunDef false "kauthCells" ((PCons (PVar "p") (PVar "ps")) (PCons (PCon "KAuth" PWild PWild) (PVar "ks")) (PCons (PCon "TAuth" (PCon "AVar" (PVar "cell"))) (PVar "rs"))) (EBinOp "::" (ETuple (EVar "p") (EVar "cell")) (EApp (EApp (EApp (EVar "kauthCells") (EVar "ps")) (EVar "ks")) (EVar "rs"))))
(DFunDef false "kauthCells" ((PCons (PVar "p") (PVar "ps")) (PCons PWild (PVar "ks")) (PCons PWild (PVar "rs"))) (EApp (EApp (EApp (EVar "kauthCells") (EVar "ps")) (EVar "ks")) (EVar "rs")))
(DFunDef false "kauthCells" (PWild PWild PWild) (EListLit))
(DTypeSig false "existentialCells" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "existentialCells" ((PVar "mctx") (PVar "binders")) (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EMatch (EApp (EVar "snd") (EVar "b")) (arm (PCon "KindAuthority" (PVar "l") (PVar "o") (PVar "pat") PWild) () (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EApp (EApp (EApp (EVar "freshAuthvarRanged") (EVar "mctx")) (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o")))) (EApp (EApp (EApp (EVar "rangedOver") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))) (EVar "pat"))) (EApp (EVar "Some") (EApp (EVar "fst") (EVar "b")))))) (arm PWild () (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EApp (EApp (EVar "freshAuthvar") (EVar "mctx")) (EVar "PUnit")) (EApp (EVar "Some") (EApp (EVar "fst") (EVar "b"))))))))) (EVar "binders")))
(DTypeSig false "recordExistentials" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar")))) (TyCon "Unit"))))
(DFunDef false "recordExistentials" ((PVar "gctx") (PList)) (ELit LUnit))
(DFunDef false "recordExistentials" ((PVar "gctx") (PVar "cells")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "anyExistentialsRef")) (EVar "True"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "ctorExistentialsRef")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "c")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EApp (EVar "snd") (EVar "c")))) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "ctorExistentialsRef") "value")) (EVar "cells"))))))
(DTypeSig false "padCtorBinders" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))))))
(DFunDef false "padCtorBinders" ((PList) PWild) (EListLit))
(DFunDef false "padCtorBinders" ((PCons PWild (PVar "vs")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "::" (EVar "b") (EApp (EApp (EVar "padCtorBinders") (EVar "vs")) (EVar "bs"))))
(DFunDef false "padCtorBinders" ((PCons PWild (PVar "vs")) (PList)) (EBinOp "::" (EListLit) (EApp (EApp (EVar "padCtorBinders") (EVar "vs")) (EListLit))))
(DTypeSig false "krowRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar"))))))))
(DFunDef false "krowRows" ((PCons (PVar "p") (PVar "ps")) (PCons (PCon "KRow") (PVar "ks")) (PCons (PCon "TEff" (PCon "EffRow" PWild (PCon "Some" (PVar "cell")))) (PVar "rs"))) (EBinOp "::" (ETuple (EVar "p") (EVar "cell")) (EApp (EApp (EApp (EVar "krowRows") (EVar "ps")) (EVar "ks")) (EVar "rs"))))
(DFunDef false "krowRows" ((PCons (PVar "p") (PVar "ps")) (PCons PWild (PVar "ks")) (PCons PWild (PVar "rs"))) (EApp (EApp (EApp (EVar "krowRows") (EVar "ps")) (EVar "ks")) (EVar "rs")))
(DFunDef false "krowRows" (PWild PWild PWild) (EListLit))
(DTypeSig false "registerNamedFieldVariants" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))) (TyCon "Unit")))))))))
(DFunDef false "registerNamedFieldVariants" ((PVar "mctx") (PVar "o") (PVar "tyName") (PVar "params") (PVar "kinds") (PVar "variants") (PVar "binders")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerNamedFieldVariantsGo") (EVar "mctx")) (EVar "o")) (EVar "tyName")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EApp (EApp (EVar "padCtorBinders") (EVar "variants")) (EVar "binders"))))
(DTypeSig false "registerNamedFieldVariantsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))) (TyCon "Unit")))))))))
(DFunDef false "registerNamedFieldVariantsGo" ((PVar "mctx") (PVar "o") (PVar "tyName") (PVar "params") (PVar "kinds") (PCons (PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fields") PWild)) (PVar "rest")) (PCons (PVar "bs") (PVar "brest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerRecordInfoKeyed") (EVar "mctx")) (EVar "o")) (EVar "cname")) (EVar "tyName")) (EVar "params")) (EVar "kinds")) (EVar "bs")) (EVar "fields"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerNamedFieldVariantsGo") (EVar "mctx")) (EVar "o")) (EVar "tyName")) (EVar "params")) (EVar "kinds")) (EVar "rest")) (EVar "brest")))))
(DFunDef false "registerNamedFieldVariantsGo" ((PVar "mctx") (PVar "o") (PVar "tyName") (PVar "params") (PVar "kinds") (PCons PWild (PVar "rest")) (PCons PWild (PVar "brest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerNamedFieldVariantsGo") (EVar "mctx")) (EVar "o")) (EVar "tyName")) (EVar "params")) (EVar "kinds")) (EVar "rest")) (EVar "brest")))
(DFunDef false "registerNamedFieldVariantsGo" ((PVar "mctx") PWild PWild PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "addVariants" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))) (TyCon "TcEnv")))))))))))
(DFunDef false "addVariants" ((PVar "env") (PVar "tvs") (PVar "etbl") (PVar "paramTyIds") (PVar "rowEffvarIds") (PVar "authvarIds") (PVar "result") (PCons (PCon "Variant" (PVar "cname") (PVar "payload")) (PVar "rest")) (PCons (PVar "binders") (PVar "brest"))) (EBlock (DoLet false false (PVar "opened") (EApp (EApp (EVar "existentialCells") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "binders"))) (DoExpr (EApp (EApp (EVar "recordExistentials") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "opened"))) (DoLet false false (PVar "ctorEtbl") (EApp (EApp (EVar "sigVarsWithAuths") (EVar "opened")) (EVar "etbl"))) (DoExpr (EApp (EApp (EApp (EVar "reportUnboundAuthorityNamesIn") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "payloadAstTypes") (EVar "payload"))) (EVar "ctorEtbl"))) (DoLet false false (PVar "ctorType") (EApp (EApp (EVar "foldrFun") (EApp (EApp (EApp (EApp (EVar "payloadTypesE") (EApp (EApp (EVar "mctxAtIfSome") (EApp (EVar "firstTyLocList") (EApp (EVar "payloadAstTypes") (EVar "payload")))) (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule"))) (EVar "ctorEtbl")) (EVar "tvs")) (EVar "payload"))) (EVar "result"))) (DoLet false false (PVar "env2") (EApp (EApp (EApp (EVar "addCtor") (EVar "env")) (EVar "cname")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EVar "paramTyIds")) (EVar "rowEffvarIds")) (EBinOp "++" (EVar "authvarIds") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EApp (EVar "authvarId") (EApp (EVar "snd") (EVar "c"))))) (EVar "opened")))) (EListLit)) (EVar "pureRow")) (EVar "ctorType")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addVariants") (EVar "env2")) (EVar "tvs")) (EVar "etbl")) (EVar "paramTyIds")) (EVar "rowEffvarIds")) (EVar "authvarIds")) (EVar "result")) (EVar "rest")) (EVar "brest")))))
(DFunDef false "addVariants" ((PVar "env") PWild PWild PWild PWild PWild PWild PWild PWild) (EVar "env"))
(DTypeSig true "constraintIsMethodLevel" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Constraint") (TyCon "Bool"))))
(DFunDef false "constraintIsMethodLevel" ((PVar "typarams") (PVar "c")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "constraintSlotDispatchVar") (EVar "typarams")) (EVar "c"))))
(DTypeSig true "methodDictArityOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "methodDictArityOf" ((PVar "mctx") (PVar "key")) (EApp (EVar "listLen") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "lookupAssoc") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value")))))
(DTypeSig true "constraintIface" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "constraintIface" ((PRec "Constraint" ((rf "constraintHead" (PVar "n"))) false)) (EVar "n"))
(DTypeSig true "constraintVarNames" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constraintVarNames" ((PRec "Constraint" ((rf "constraintArgs" (PVar "args"))) false)) (EApp (EApp (EVar "flatMap") (EVar "tyVarNames")) (EVar "args")))
(DTypeSig false "tyAliasNormalForm" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyCon "Ty") (TyCon "Ty")))))
(DFunDef false "tyAliasNormalForm" ((PVar "aliases") (PVar "seen") (PVar "ty")) (EMatch (EApp (EApp (EVar "aliasExpansionStep") (EVar "aliases")) (EVar "ty")) (arm (PCon "Some" (PTuple (PVar "key") (PVar "rhs"))) ((GBool (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "k")) (EApp (EApp (EVar "tabKeyEq") (EVar "k")) (EVar "key")))) (EVar "seen"))))) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EBinOp "::" (EVar "key") (EVar "seen"))) (EApp (EApp (EVar "locateTyAt") (EApp (EVar "firstTyLoc") (EVar "ty"))) (EVar "rhs")))) (arm PWild () (EApp (EApp (EApp (EVar "tyAliasNormalFormKids") (EVar "aliases")) (EVar "seen")) (EVar "ty")))))
(DTypeSig false "tyAliasNormalFormKids" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyCon "Ty") (TyCon "Ty")))))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PAs "h" (PRec "TyCon" ((rf "tyConName" PWild)) false)) (PVar "args")) () (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "arg")) (EApp (EApp (EVar "TyApp") (EVar "acc")) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "arg"))))) (EVar "h")) (EVar "args"))) (arm PWild () (EApp (EApp (EVar "TyApp") (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "a"))) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "b"))))))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "a"))) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "b"))))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "TyTuple") (EApp (EApp (EVar "map") (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen"))) (EVar "ts"))))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyEffect" (PVar "es") (PVar "tails") (PVar "t"))) (EApp (EApp (EApp (EVar "TyEffect") (EVar "es")) (EVar "tails")) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "t"))))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyNamed" (PVar "n") (PVar "t") (PVar "d"))) (EApp (EApp (EApp (EVar "TyNamed") (EVar "n")) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "t"))) (EVar "d")))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyQual" (PVar "t") (PVar "ps") (PVar "l"))) (EApp (EApp (EApp (EVar "TyQual") (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "t"))) (EVar "ps")) (EVar "l")))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "t"))))
(DFunDef false "tyAliasNormalFormKids" (PWild PWild (PVar "t")) (EVar "t"))
(DTypeSig false "aliasExpansionStep" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "TabKey") (TyCon "Ty"))))))
(DFunDef false "aliasExpansionStep" ((PVar "aliases") (PVar "ty")) (EMatch (EApp (EVar "tyAppSpine") (EVar "ty")) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupTab") (EVar "key")) (EVar "aliases")) (arm (PCon "Some" (PTuple (PVar "params") (PVar "rhs"))) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (ETuple (EVar "key") (EApp (EApp (EVar "substAliasArgs") (EApp (EApp (EVar "zipL") (EVar "params")) (EVar "args"))) (EVar "rhs"))))) (arm PWild () (EVar "None")))))) (arm PWild () (EVar "None"))))
(DTypeSig false "locateTyAt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "locateTyAt" ((PCon "None") (PVar "ty")) (EVar "ty"))
(DFunDef false "locateTyAt" ((PVar "loc") (PVar "ty")) (EApp (EVar "fst") (EApp (EApp (EVar "mapTyFull") (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PRec "TyCon" ((rf "tyConLoc" (PCon "None"))) false) () (ETuple (EVariantUpdate "TyCon" (EVar "t") ((fa "tyConLoc" (EVar "loc")))) (EVar "True"))) (arm PWild () (ETuple (EVar "t") (EVar "False")))))) (EVar "ty"))))
(DTypeSig true "ifaceMethodSchemeRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "MethodSchemeRow")))))
(DFunDef false "ifaceMethodSchemeRows" ((PVar "mctx") (PVar "decls")) (EApp (EApp (EVar "flatMap") (EApp (EVar "directIfaceSchemeRows") (EVar "mctx"))) (EApp (EVar "directInterfaceDecls") (EVar "decls"))))
(DTypeSig false "directInterfaceDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "directInterfaceDecls" ((PVar "decls")) (EApp (EApp (EVar "filterList") (EVar "isDirectInterfaceDecl")) (EVar "decls")))
(DTypeSig false "isDirectInterfaceDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isDirectInterfaceDecl" ((PRec "DInterface" () false)) (EVar "True"))
(DFunDef false "isDirectInterfaceDecl" (PWild) (EVar "False"))
(DTypeSig false "directIfaceSchemeRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "MethodSchemeRow")))))
(DFunDef false "directIfaceSchemeRows" ((PVar "mctx") (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "methods" None) (rf "ifaceOrigin" None)) true)) (EApp (EApp (EApp (EApp (EApp (EVar "methodSchemeRows") (EVar "mctx")) (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "typarams")) (EVar "typaramKinds")) (EVar "methods"))) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "ifaceOrigin"))))) (EVar "typarams")) (EVar "methods")))
(DFunDef false "directIfaceSchemeRows" ((PVar "mctx") PWild) (EListLit))
(DTypeSig false "methodSchemeRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "MethodSchemeRow"))))))))
(DFunDef false "methodSchemeRows" ((PVar "mctx") PWild PWild PWild (PList)) (EListLit))
(DFunDef false "methodSchemeRows" ((PVar "mctx") (PVar "scope") (PVar "iface") (PVar "typarams") (PCons (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "scheme") (PVar "tvs")) (EApp (EApp (EApp (EVar "sigToSchemeTvsIn") (EVar "mctx")) (EVar "scope")) (EVar "mty"))) (DoLet false false (PVar "slots") (EApp (EApp (EApp (EApp (EApp (EVar "methodPredicateSlotsOfType") (EVar "mctx")) (EVar "typarams")) (EVar "mty")) (EVar "tvs")) (EApp (EVar "schemeIds") (EVar "scheme")))) (DoExpr (EApp (EApp (EApp (EVar "installMethodPredicateSlots") (EVar "mctx")) (EApp (EApp (EVar "methodSlotKey") (EVar "iface")) (EVar "mname"))) (EVar "slots"))) (DoExpr (EBinOp "::" (ERecordCreate "MethodSchemeRow" ((fa "msrIface" (EVar "iface")) (fa "msrName" (EVar "mname")) (fa "msrTyparams" (EVar "typarams")) (fa "msrType" (EVar "mty")) (fa "msrScheme" (EVar "scheme")) (fa "msrPredicateTemplate" (ERecordCreate "MethodPredicateTemplate" ((fa "mptInterface" (EVar "iface")) (fa "mptArguments" (EApp (EApp (EVar "methodInterfacePredicateTemplate") (EVar "typarams")) (EVar "tvs")))))) (fa "msrMethodSlots" (EVar "slots")))) (EApp (EApp (EApp (EApp (EApp (EVar "methodSchemeRows") (EVar "mctx")) (EVar "scope")) (EVar "iface")) (EVar "typarams")) (EVar "rest"))))))
(DTypeSig false "methodInterfacePredicateTemplate" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))))))
(DFunDef false "methodInterfacePredicateTemplate" ((PList) PWild) (EListLit))
(DFunDef false "methodInterfacePredicateTemplate" ((PCons (PVar "param") (PVar "rest")) (PVar "tvs")) (EBinOp "::" (EApp (EApp (EVar "lookupAssoc") (EVar "param")) (EVar "tvs")) (EApp (EApp (EVar "methodInterfacePredicateTemplate") (EVar "rest")) (EVar "tvs"))))
(DTypeSig true "seedNumLitFromIntAnchor" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyCon "Unit"))))
(DFunDef false "seedNumLitFromIntAnchor" ((PVar "mctx") (PVar "rows")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numLitFromIntAnchorRef")) (EApp (EApp (EApp (EVar "pickNumLitRow") (EApp (EApp (EVar "builtinIfaceRef") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum"))) (ELit (LString "fromInt"))) (EVar "rows"))))
(DTypeSig false "pickNumLitRow" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyApp (TyCon "Option") (TyCon "MethodSchemeRow"))))))
(DFunDef false "pickNumLitRow" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "pickNumLitRow" ((PVar "iface") (PVar "mname") (PCons (PVar "row") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "row") "msrName") (EVar "mname")) (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "row") "msrIface")) (EVar "iface"))) (EApp (EVar "Some") (EVar "row")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "pickNumLitRow") (EVar "iface")) (EVar "mname")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "methodSchemesPure" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "methodSchemesPure" ((PVar "mctx") PWild (PList)) (EListLit))
(DFunDef false "methodSchemesPure" ((PVar "mctx") (PVar "scope") (PCons (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "mname") (EApp (EVar "fst") (EApp (EApp (EApp (EVar "sigToSchemeTvsIn") (EVar "mctx")) (EVar "scope")) (EVar "mty")))) (EApp (EApp (EApp (EVar "methodSchemesPure") (EVar "mctx")) (EVar "scope")) (EVar "rest"))))
(DTypeSig false "installMethodPredicateSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyCon "Unit")))))
(DFunDef false "installMethodPredicateSlots" ((PVar "mctx") (PVar "key") (PVar "slots")) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "slots")) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value")))) (ELit LUnit) (EApp (EApp (EApp (EVar "setMethodPredicateSlotEntry") (EVar "mctx")) (EVar "key")) (EVar "slots"))))
(DTypeSig false "setMethodPredicateSlotEntry" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyCon "Unit")))))
(DFunDef false "setMethodPredicateSlotEntry" ((PVar "mctx") (PVar "key") (PVar "slots")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef")) (EBinOp "::" (ETuple (EVar "key") (EVar "slots")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value"))))
(DTypeSig false "methodPredicateSlotsOfType" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))))))
(DFunDef false "methodPredicateSlotsOfType" ((PVar "mctx") (PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t")) (PVar "tvs") (PVar "fullIds")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EVar "constraintMethodPredicateSlot") (EVar "mctx")) (EVar "typarams")) (EVar "tvs")) (EVar "fullIds"))) (EVar "cs")) (EApp (EApp (EApp (EApp (EApp (EVar "methodPredicateSlotsOfType") (EVar "mctx")) (EVar "typarams")) (EVar "t")) (EVar "tvs")) (EVar "fullIds"))))
(DFunDef false "methodPredicateSlotsOfType" ((PVar "mctx") (PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t")) (PVar "tvs") (PVar "fullIds")) (EApp (EApp (EApp (EApp (EApp (EVar "methodPredicateSlotsOfType") (EVar "mctx")) (EVar "typarams")) (EVar "t")) (EVar "tvs")) (EVar "fullIds")))
(DFunDef false "methodPredicateSlotsOfType" ((PVar "mctx") PWild PWild PWild PWild) (EListLit))
(DTypeSig false "constraintMethodPredicateSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))))))
(DFunDef false "constraintMethodPredicateSlot" ((PVar "mctx") (PVar "typarams") (PVar "tvs") (PVar "fullIds") (PVar "c")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "constraintIsMethodLevel") (EVar "typarams")) (EVar "c"))) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "bound") (EApp (EApp (EVar "constraintNameMonos") (EApp (EVar "constraintVarNames") (EVar "c"))) (EVar "tvs"))) (DoLet false false (PVar "ids") (EApp (EApp (EVar "map") (EVar "monoTyvarId")) (EVar "bound"))) (DoExpr (EListLit (ERecordCreate "MethodPredicateSlot" ((fa "mpsPredicate" (ERecordCreate "PredicateSlot" ((fa "psIface" (ERecordCreate "IfaceRef" ((fa "irName" (EApp (EVar "constraintIface") (EVar "c"))) (fa "irOrigin" (EFieldAccess (EVar "c") "constraintOrigin"))))) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EApp (EApp (EVar "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvs"))) (EFieldAccess (EVar "c") "constraintArgs")))) (fa "psBoundIds" (EVar "ids"))))) (fa "mpsPositions" (EApp (EApp (EVar "map") (ELam ((PVar "id")) (EApp (EApp (EVar "optionOr") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EVar "elemIndex") (EVar "id")) (EVar "fullIds"))))) (EVar "ids")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "registerAllData" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "TcEnv"))))
(DFunDef false "registerAllData" ((PVar "env") (PVar "ds")) (EApp (EApp (EApp (EVar "registerAllDataScoped") (EVar "env")) (EVar "ds")) (EVar "ds")))
(DTypeSig true "registerAllDataScoped" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "TcEnv")))))
(DFunDef false "registerAllDataScoped" ((PVar "env") (PVar "ds") (PVar "allDs")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "seedParamPolarityFixpointScoped") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ds")) (EVar "allDs"))) (DoExpr (EApp (EApp (EVar "registerAllDataGo") (EVar "env")) (EVar "ds")))))
(DTypeSig false "registerAllDataGo" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "TcEnv"))))
(DFunDef false "registerAllDataGo" ((PVar "env") (PVar "ds")) (EBlock (DoExpr (EApp (EApp (EVar "each") (EApp (EVar "recordDeclKinds") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule"))) (EVar "ds"))) (DoExpr (EApp (EApp (EVar "registerDeclsAliasesFirst") (EVar "env")) (EVar "ds")))))
(DTypeSig false "registerDeclsAliasesFirst" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "TcEnv"))))
(DFunDef false "registerDeclsAliasesFirst" ((PVar "env") (PVar "ds")) (EBlock (DoLet false false (PVar "env1") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "e") (PVar "d")) (EIf (EApp (EVar "isAliasDecl") (EVar "d")) (EApp (EApp (EVar "registerData") (EVar "e")) (EVar "d")) (EVar "e")))) (EVar "env")) (EVar "ds"))) (DoExpr (EApp (EApp (EVar "rejectCyclicAliases") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ds"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "e") (PVar "d")) (EIf (EApp (EVar "isAliasDecl") (EVar "d")) (EVar "e") (EApp (EApp (EVar "registerData") (EVar "e")) (EVar "d"))))) (EVar "env1")) (EVar "ds")))))
(DTypeSig true "isAliasDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isAliasDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isAliasDecl") (EVar "d")))
(DFunDef false "isAliasDecl" ((PRec "DTypeAlias" () true)) (EVar "True"))
(DFunDef false "isAliasDecl" (PWild) (EVar "False"))
(DTypeSig true "recordDeclKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "recordDeclKinds" ((PVar "mctx") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "recordDeclKinds") (EVar "mctx")) (EVar "d")))
(DFunDef false "recordDeclKinds" ((PVar "mctx") (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "name")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "anns")) (rf "dataCtors" (PVar "variants")) (rf "dataOrigin" (PVar "o"))) false)) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordCtors") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o")) (EVar "name")) (EVar "vis")) (EVar "params")) (EVar "variants"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordParamKinds") (EVar "mctx")) (EVar "o")) (EVar "name")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "params")) (EVar "anns"))))))
(DFunDef false "recordDeclKinds" ((PVar "mctx") (PRec "DNewtype" ((rf "newtypePub" (PVar "pub")) (rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "params")) (rf "newtypeParamKinds" (PVar "anns")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeOrigin" (PVar "o"))) false)) (EBlock (DoLet false false (PVar "vis") (EIf (EVar "pub") (EVar "VisPublic") (EVar "VisAbstract"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordCtors") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o")) (EVar "name")) (EVar "vis")) (EVar "params")) (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty"))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordParamKinds") (EVar "mctx")) (EVar "o")) (EVar "name")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "params")) (EVar "anns"))))))
(DFunDef false "recordDeclKinds" ((PVar "mctx") (PVar "d")) (EApp (EApp (EVar "recordDeclParamKinds") (EVar "mctx")) (EVar "d")))
(DTypeSig false "recordDeclParamKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "recordDeclParamKinds" ((PVar "mctx") (PVar "d")) (EMatch (EApp (EApp (EVar "declKindEntry") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "d")) (arm (PCon "Some" (PTuple (PVar "o") (PVar "name") (PVar "kinds"))) () (EApp (EApp (EApp (EApp (EVar "recordParamKinds") (EVar "mctx")) (EVar "o")) (EVar "name")) (EVar "kinds"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "declKindEntry" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "TyConOrigin") (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))))
(DFunDef false "declKindEntry" ((PVar "gctx") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declKindEntry") (EVar "gctx")) (EVar "d")))
(DFunDef false "declKindEntry" ((PVar "gctx") (PRec "DData" ((rf "dataName" (PVar "name")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "anns")) (rf "dataOrigin" (PVar "o"))) false)) (EApp (EVar "Some") (ETuple (EVar "o") (EVar "name") (EApp (EApp (EApp (EVar "declParamKinds") (EVar "gctx")) (EVar "params")) (EVar "anns")))))
(DFunDef false "declKindEntry" ((PVar "gctx") (PRec "DNewtype" ((rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "params")) (rf "newtypeParamKinds" (PVar "anns")) (rf "newtypeOrigin" (PVar "o"))) false)) (EApp (EVar "Some") (ETuple (EVar "o") (EVar "name") (EApp (EApp (EApp (EVar "declParamKinds") (EVar "gctx")) (EVar "params")) (EVar "anns")))))
(DFunDef false "declKindEntry" ((PVar "gctx") (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "name")) (rf "tyAliasParams" (PVar "params")) (rf "tyAliasParamKinds" (PVar "anns")) (rf "tyAliasOrigin" (PVar "o"))) false)) (EApp (EVar "Some") (ETuple (EVar "o") (EVar "name") (EApp (EApp (EApp (EVar "declParamKinds") (EVar "gctx")) (EVar "params")) (EVar "anns")))))
(DFunDef false "declKindEntry" ((PVar "gctx") PWild) (EVar "None"))
(DTypeSig true "withDeclParamKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyVar "a")))))
(DFunDef false "withDeclParamKinds" ((PVar "mctx") (PVar "ds") (PVar "k")) (EBlock (DoLet false false (PVar "kinds") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (DoLet false false (PVar "names") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamNameIndexRef") "value")) (DoExpr (EApp (EApp (EVar "each") (EApp (EVar "recordDeclaredKinds") (EVar "mctx"))) (EVar "ds"))) (DoLet false false (PVar "result") (EApp (EVar "k") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef")) (EVar "kinds"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamNameIndexRef")) (EVar "names"))) (DoExpr (EVar "result"))))
(DTypeSig false "recordDeclaredKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "recordDeclaredKinds" ((PVar "mctx") (PVar "d")) (EMatch (EApp (EApp (EVar "declKindEntry") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "d")) (arm (PCon "Some" (PTuple (PVar "o") (PVar "name") (PVar "kinds"))) ((GBool (EApp (EApp (EVar "anyList") (EVar "kindIsDeclared")) (EVar "kinds")))) (EApp (EApp (EApp (EApp (EVar "recordParamKinds") (EVar "mctx")) (EVar "o")) (EVar "name")) (EVar "kinds"))) (arm PWild () (ELit LUnit))))
(DTypeSig true "kindIsDeclared" (TyFun (TyCon "Kind") (TyCon "Bool")))
(DFunDef false "kindIsDeclared" ((PCon "KType")) (EVar "False"))
(DFunDef false "kindIsDeclared" (PWild) (EVar "True"))
(DTypeSig true "instantiateSigTracked" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "EffRow"))))))
(DFunDef false "instantiateSigTracked" ((PVar "outer") (PVar "ty")) (EApp (EApp (EApp (EVar "atSignature") (EVar "outer")) (EVar "ty")) (ELam ((PVar "mctx")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "rowArgNames") (EVar "mctx")) (EVar "ty"))) (DoLet false false (PVar "auths") (EApp (EApp (EVar "authArgBindersIn") (EVar "mctx")) (EVar "ty"))) (DoLet false false (PVar "tvs") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EApp (EApp (EVar "sigTyVarNames") (EVar "ty")) (EVar "rows")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "auths"))))) (DoLet false false (PVar "etbl") (EApp (EApp (EApp (EApp (EVar "sigVarsForWith") (EVar "mctx")) (EVar "ty")) (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "effTailNames") (EVar "ty")) (EVar "rows")))) (EVar "auths"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty")) (EVar "tvs") (EApp (EApp (EApp (EApp (EVar "writtenBindingForce") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty"))))))))
(DTypeSig true "constraintNameMonos" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "constraintNameMonos" ((PList) PWild) (EListLit))
(DFunDef false "constraintNameMonos" ((PCons (PVar "n") (PVar "rest")) (PVar "tvMap")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tvMap")) (arm (PCon "Some" (PVar "mono")) () (EBinOp "::" (EVar "mono") (EApp (EApp (EVar "constraintNameMonos") (EVar "rest")) (EVar "tvMap")))) (arm (PCon "None") () (EApp (EApp (EVar "constraintNameMonos") (EVar "rest")) (EVar "tvMap")))))
(DTypeSig true "loadDataUniverse" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "loadDataUniverse" ((PVar "mctx") (PVar "cur")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef")) (EApp (EVar "spFloor") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeRecordPop") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef")) (EApp (EApp (EVar "aliasUniverseAt") (EVar "cur")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deData") "deAliases"))))))
(DTypeSig false "ctorExportsInto" (TyFun (TyCon "DeclEnvModule") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))))
(DFunDef false "ctorExportsInto" ((PVar "m") (PVar "acc")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EBinOp "++" (EApp (EVar "declCtorIdents") (EFieldAccess (EVar "m") "demDecls")) (EApp (EApp (EVar "reexportedCtorIdents") (EVar "acc")) (EFieldAccess (EVar "m") "demDecls")))) (EVar "acc")))
(DTypeSig false "declCtorIdents" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))
(DFunDef false "declCtorIdents" ((PVar "decls")) (EApp (EApp (EVar "flatMap") (EVar "declCtorIdentsOf")) (EVar "decls")))
(DTypeSig false "declCtorIdentsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))
(DFunDef false "declCtorIdentsOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declCtorIdentsOf") (EVar "d")))
(DFunDef false "declCtorIdentsOf" ((PRec "DData" ((rf "dataName" None) (rf "dataCtors" None) (rf "dataOrigin" None)) true)) (EApp (EApp (EVar "flatMap") (ELam ((PVar "v")) (EApp (EApp (EApp (EVar "variantIdentRow") (EVar "dataName")) (EVar "dataOrigin")) (EVar "v")))) (EVar "dataCtors")))
(DFunDef false "declCtorIdentsOf" ((PRec "DNewtype" ((rf "newtypeName" None) (rf "newtypeCtor" None) (rf "newtypeOrigin" None)) true)) (EApp (EApp (EApp (EVar "ctorIdentRow") (EVar "newtypeName")) (EVar "newtypeOrigin")) (EVar "newtypeCtor")))
(DFunDef false "declCtorIdentsOf" (PWild) (EListLit))
(DTypeSig false "variantIdentRow" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))))
(DFunDef false "variantIdentRow" ((PVar "tyName") (PVar "o") (PCon "Variant" (PVar "cn") PWild)) (EApp (EApp (EApp (EVar "ctorIdentRow") (EVar "tyName")) (EVar "o")) (EVar "cn")))
(DTypeSig false "ctorIdentRow" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))))
(DFunDef false "ctorIdentRow" ((PVar "tyName") (PVar "o") (PVar "cn")) (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsCtor")) (EVar "o")) (EVar "cn")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "i")) () (EListLit (ETuple (EVar "cn") (EVar "tyName") (EVar "i"))))))
(DTypeSig false "reexportedCtorIdents" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "reexportedCtorIdents" ((PVar "acc") (PVar "decls")) (EApp (EApp (EVar "flatMap") (EApp (EVar "reexportedCtorIdentsOf") (EVar "acc"))) (EVar "decls")))
(DTypeSig false "reexportedCtorIdentsOf" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "reexportedCtorIdentsOf" ((PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "reexportedCtorIdentsOf") (EVar "acc")) (EVar "d")))
(DFunDef false "reexportedCtorIdentsOf" ((PVar "acc") (PCon "DUse" (PCon "True") (PVar "path") PWild)) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "acc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EMatch (EVar "path") (arm (PCon "UseWild" PWild) () (EVar "src")) (arm (PCon "UseGroup" PWild (PVar "ms")) () (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EApp (EApp (EVar "reexportCtorMember") (EVar "m")) (EVar "src")))) (EVar "ms"))) (arm PWild () (EListLit))))))
(DFunDef false "reexportedCtorIdentsOf" (PWild PWild) (EListLit))
(DTypeSig false "reexportCtorMember" (TyFun (TyCon "UseMember") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "reexportCtorMember" ((PVar "m") (PVar "src")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "rowBoundByMember") (EVar "m")) (EVar "r")))) (EVar "src")))
(DTypeSig false "rowBoundByMember" (TyFun (TyCon "UseMember") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")) (TyCon "Bool"))))
(DFunDef false "rowBoundByMember" ((PVar "m") (PTuple (PVar "cn") (PVar "owner") PWild)) (EApp (EApp (EApp (EVar "memberBindsCtorName") (EVar "cn")) (EVar "owner")) (EVar "m")))
(DTypeSig true "graphAliasRow" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))))
(DFunDef false "graphAliasRow" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "graphAliasRow") (EVar "d")))
(DFunDef false "graphAliasRow" ((PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasRhs" (PVar "rhs")) (rf "tyAliasOrigin" (PVar "o"))) false)) (EListLit (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (ETuple (EVar "ps") (EVar "rhs")))))
(DFunDef false "graphAliasRow" (PWild) (EListLit))
(DTypeSig true "implHeadNormalDecl" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "implHeadNormalDecl" ((PVar "aliases") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "a")) (EApp (EApp (EVar "implHeadNormalDecl") (EVar "aliases")) (EVar "d"))))
(DFunDef false "implHeadNormalDecl" ((PVar "aliases") (PAs "d" (PRec "DImpl" ((rf "tys" (PVar "tys"))) false))) (EVariantUpdate "DImpl" (EVar "d") ((fa "tys" (EApp (EApp (EVar "map") (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EListLit))) (EVar "tys"))))))
(DFunDef false "implHeadNormalDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig true "declEnvModulesFrom" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "DeclEnvModule"))))))
(DFunDef false "declEnvModulesFrom" ((PVar "gctx") PWild (PList)) (EListLit))
(DFunDef false "declEnvModulesFrom" ((PVar "gctx") (PVar "k") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (EVar "k")) (EVar "mid")) (EVar "decls")) (EApp (EApp (EApp (EVar "declEnvModulesFrom") (EVar "gctx")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "declEnvOrdIndex" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "declEnvOrdIndex" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "declEnvOrdIndex" ((PVar "acc") (PCons (PVar "m") (PVar "rest"))) (EApp (EApp (EVar "declEnvOrdIndex") (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "m") "demOrd")) (EVar "acc"))) (EVar "rest")))
(DTypeSig false "declEnvReachIndex" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "declEnvReachIndex" ((PVar "mods")) (EApp (EApp (EApp (EVar "declEnvReachGo") (EApp (EApp (EVar "declEnvImportIndex") (EVar "mods")) (EVar "omEmpty"))) (EVar "mods")) (EVar "omEmpty")))
(DTypeSig false "declEnvImportIndex" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "declEnvImportIndex" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvImportIndex" ((PCons (PVar "m") (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "m") "demId")) (EVar "acc")) (EApp (EApp (EVar "declEnvImportIndex") (EVar "rest")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EVar "declEnvImportIndex") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EApp (EApp (EVar "flatMap") (EVar "useModuleId")) (EFieldAccess (EVar "m") "demDecls"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declEnvReachGo" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "declEnvReachGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvReachGo" ((PVar "edges") (PCons (PVar "m") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declEnvReachGo") (EVar "edges")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EApp (EApp (EApp (EVar "declEnvReachFrom") (EVar "edges")) (EListLit (EFieldAccess (EVar "m") "demId"))) (EApp (EVar "declEnvReachSeed") (EFieldAccess (EVar "m") "demId")))) (EVar "acc"))))
(DTypeSig false "declEnvReachSeed" (TyFun (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "declEnvReachSeed" ((PVar "mid")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (ELit LUnit)) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (ELit LUnit)) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "core"))) (ELit LUnit)) (EVar "omEmpty")))))
(DTypeSig false "declEnvDefinerIndex" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyTuple (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "declEnvDefinerIndex" ((PVar "acc") (PVar "amb") (PList)) (ETuple (EVar "acc") (EVar "amb")))
(DFunDef false "declEnvDefinerIndex" ((PVar "acc") (PVar "amb") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EVar "modulePubDefiners") (EVar "acc")) (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "m") "demDecls"))) (DoExpr (EApp (EApp (EApp (EVar "declEnvDefinerIndex") (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EApp (EApp (EVar "firstRowPerName") (EVar "omEmpty")) (EVar "rows"))) (EVar "acc"))) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EApp (EApp (EVar "ambiguousExportRows") (EFieldAccess (EVar "m") "demId")) (EVar "rows"))) (EVar "amb"))) (EVar "rest")))))
(DTypeSig false "ambiguousExportRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ambiguousExportRows" ((PVar "mid") (PVar "rows")) (EBlock (DoLet false false (PVar "grouped") (EApp (EApp (EVar "groupDefinerPairs") (EVar "omEmpty")) (EVar "rows"))) (DoExpr (EApp (EApp (EApp (EVar "ambigRowsOf") (EVar "mid")) (EVar "grouped")) (EApp (EVar "omKeys") (EVar "grouped"))))))
(DTypeSig false "groupDefinerPairs" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "groupDefinerPairs" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "groupDefinerPairs" ((PVar "acc") (PCons (PTuple (PVar "n") (PVar "pair")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "acc")) (arm (PCon "None") () (EApp (EApp (EVar "groupDefinerPairs") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EListLit (EVar "pair"))) (EVar "acc"))) (EVar "rest"))) (arm (PCon "Some" (PVar "seen")) () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EApp (EVar "fst") (EVar "pair"))) (EBinOp "==" (EApp (EVar "snd") (EVar "p")) (EApp (EVar "snd") (EVar "pair")))))) (EVar "seen")) (EApp (EApp (EVar "groupDefinerPairs") (EVar "acc")) (EVar "rest")) (EApp (EApp (EVar "groupDefinerPairs") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "++" (EVar "seen") (EListLit (EVar "pair")))) (EVar "acc"))) (EVar "rest"))))))
(DTypeSig false "ambigRowsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ambigRowsOf" (PWild PWild (PList)) (EListLit))
(DFunDef false "ambigRowsOf" ((PVar "mid") (PVar "grouped") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EVar "definerPairsOf") (EVar "n")) (EVar "grouped"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "pairs")) (ELit (LInt 2))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EVar "mid")))) (EVar "pairs")))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pairs"))) (EApp (EApp (EApp (EVar "ambigRowsOf") (EVar "mid")) (EVar "grouped")) (EVar "rest"))) (EApp (EApp (EApp (EVar "ambigRowsOf") (EVar "mid")) (EVar "grouped")) (EVar "rest"))))))
(DTypeSig false "definerPairsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "definerPairsOf" ((PVar "n") (PVar "grouped")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "grouped")) (arm (PCon "Some" (PVar "ps")) () (EVar "ps")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "firstRowPerName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "firstRowPerName" (PWild (PList)) (EListLit))
(DFunDef false "firstRowPerName" ((PVar "seen") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "seen")) (EApp (EApp (EVar "firstRowPerName") (EVar "seen")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "firstRowPerName") (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ELit LUnit)) (EVar "seen"))) (EVar "rest")))))
(DTypeSig false "modulePubDefiners" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "modulePubDefiners" ((PVar "before") (PVar "mid") (PVar "decls")) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ETuple (EVar "mid") (EVar "n"))))) (EApp (EVar "pubTopFnNames") (EVar "decls"))) (EApp (EApp (EVar "reexportDefiners") (EVar "before")) (EVar "decls"))))
(DTypeSig false "reexportDefiners" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "reexportDefiners" (PWild (PList)) (EListLit))
(DFunDef false "reexportDefiners" ((PVar "before") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "reexportDefiners") (EVar "before")) (EListLit (EVar "d"))) (EApp (EApp (EVar "reexportDefiners") (EVar "before")) (EVar "rest"))))
(DFunDef false "reexportDefiners" ((PVar "before") (PCons (PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "depId") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "depId") (ELit (LString "core"))) (EApp (EApp (EVar "reexportDefiners") (EVar "before")) (EVar "rest")) (EBinOp "++" (EApp (EApp (EVar "importFormRows") (EVar "path")) (EApp (EApp (EVar "definersIn") (EVar "before")) (EVar "depId"))) (EApp (EApp (EVar "reexportDefiners") (EVar "before")) (EVar "rest")))))))
(DFunDef false "reexportDefiners" ((PVar "before") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "reexportDefiners") (EVar "before")) (EVar "rest")))
(DTypeSig true "pubTopFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubTopFnNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "fns") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "decls"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "fns")))) (EApp (EVar "publicStandaloneNames") (EVar "decls"))))))
(DTypeSig false "publicStandaloneNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "publicStandaloneNames" ((PList)) (EListLit))
(DFunDef false "publicStandaloneNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "publicStandaloneNames") (EListLit (EVar "d"))) (EApp (EVar "publicStandaloneNames") (EVar "rest"))))
(DFunDef false "publicStandaloneNames" ((PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "publicStandaloneNames") (EVar "rest"))))
(DFunDef false "publicStandaloneNames" ((PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "publicStandaloneNames") (EVar "rest"))))
(DFunDef false "publicStandaloneNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "publicStandaloneNames") (EVar "rest")))
(DTypeSig false "deKindAbstractFixture" (TyCon "Decl"))
(DFunDef false "deKindAbstractFixture" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisAbstract")) (fa "dataName" (ELit (LString "Opq"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "MkOpq"))) (EApp (EVar "ConPos") (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deKindPrivateFixture" (TyCon "Decl"))
(DFunDef false "deKindPrivateFixture" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPrivate")) (fa "dataName" (ELit (LString "Priv"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "MkPriv"))) (EApp (EVar "ConPos") (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deKindNewtypeFixture" (TyCon "Decl"))
(DFunDef false "deKindNewtypeFixture" () (ERecordCreate "DNewtype" ((fa "newtypePub" (EVar "True")) (fa "newtypeName" (ELit (LString "Wrap"))) (fa "newtypeParams" (EListLit)) (fa "newtypeParamKinds" (EListLit)) (fa "newtypeCtor" (ELit (LString "Wrap"))) (fa "newtypeFieldTy" (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (fa "newtypeCtorBinders" (EListLit)) (fa "newtypeDerives" (EListLit)) (fa "newtypeOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))) (fa "newtypeNameLoc" (EVar "None")))))
(DTypeSig false "deKindFixtureDecls" (TyApp (TyCon "List") (TyCon "Decl")))
(DFunDef false "deKindFixtureDecls" () (EListLit (EVar "deFieldOwnerFixtureA") (EVar "deKindAbstractFixture") (EVar "deKindPrivateFixture") (EVar "deKindNewtypeFixture")))
(DTypeSig false "deKindRow0" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deKindRow0" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "m"))) (EVar "deKindFixtureDecls")))
(DTypeSig false "deKindRow1" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deKindRow1" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "m"))) (EVar "deKindFixtureDecls")))
(DTypeSig false "deSeedRowN" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deSeedRowN" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "n"))) (EVar "deKindFixtureDecls")))
(DTypeSig false "deSeedChainProbeZero" (TyCon "DeclEnvSeedAcc"))
(DFunDef false "deSeedChainProbeZero" () (ERecordCreate "DeclEnvSeedAcc" ((fa "dsKAcc" (EListLit)) (fa "dsOAcc" (EVar "omEmpty")) (fa "dsNAcc" (EVar "omEmpty")) (fa "dsKinds" (EVar "omEmpty")) (fa "dsOwners" (EVar "omEmpty")) (fa "dsNames" (EVar "omEmpty")))))
(DTypeSig false "deSeedChainProbe" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvSeedAcc")))
(DFunDef false "deSeedChainProbe" ((PVar "gctx")) (EApp (EApp (EApp (EVar "declEnvSeedChain") (EVar "gctx")) (EListLit (EApp (EVar "deKindRow0") (EVar "gctx")) (EApp (EVar "deSeedRowN") (EVar "gctx")))) (EVar "deSeedChainProbeZero")))
(DTypeSig false "deSeedChainKinds" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind")))))))
(DFunDef false "deSeedChainKinds" ((PVar "gctx")) (EFieldAccess (EApp (EVar "deSeedChainProbe") (EVar "gctx")) "dsKinds"))
(DTypeSig false "deSeedChainOwners" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "deSeedChainOwners" ((PVar "gctx")) (EFieldAccess (EApp (EVar "deSeedChainProbe") (EVar "gctx")) "dsOwners"))
(DTypeSig false "deSeedChainNames" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "deSeedChainNames" ((PVar "gctx")) (EFieldAccess (EApp (EVar "deSeedChainProbe") (EVar "gctx")) "dsNames"))
(DTypeSig false "deSeedNameParity" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "deSeedNameParity" ((PVar "mid")) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "accumulated") (EApp (EVar "omKeys") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EApp (EVar "deSeedChainNames") (EVar "gctx")))))) (DoLet false false (PVar "rebuilt") (EApp (EVar "omKeys") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EVar "tabKeyName") (EApp (EVar "fst") (EVar "p"))))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EApp (EVar "deSeedChainKinds") (EVar "gctx")))))) (EVar "omEmpty")))) (DoExpr (EBinOp "==" (EVar "accumulated") (EVar "rebuilt")))))
(DTypeSig false "deNameIdxAlpha" (TyCon "Decl"))
(DFunDef false "deNameIdxAlpha" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Alpha"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "MkAlpha"))) (EApp (EVar "ConPos") (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "modA")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deNameIdxSharedA" (TyCon "Decl"))
(DFunDef false "deNameIdxSharedA" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Shared"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "MkSharedA"))) (EApp (EVar "ConPos") (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "modA")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deNameIdxBeta" (TyCon "Decl"))
(DFunDef false "deNameIdxBeta" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Beta"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "MkBeta"))) (EApp (EVar "ConPos") (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "modB")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deNameIdxSharedB" (TyCon "Decl"))
(DFunDef false "deNameIdxSharedB" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Shared"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "MkSharedB"))) (EApp (EVar "ConPos") (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "modB")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deNameIdxModA" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deNameIdxModA" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "modA"))) (EListLit (EVar "deNameIdxAlpha") (EVar "deNameIdxSharedA"))))
(DTypeSig false "deNameIdxModB" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deNameIdxModB" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "modB"))) (EListLit (EVar "deNameIdxBeta") (EVar "deNameIdxSharedB"))))
(DTypeSig false "deNameIdxModC" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deNameIdxModC" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 2))) (ELit (LString "modC"))) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "True")) (ELit (LString "modCHelper"))) (EListLit)) (EApp (EVar "ELit") (EApp (EVar "LInt") (ELit (LInt 1))))) (EVar "noDeclLoc")) (EVar "noBinderId")))))
(DTypeSig false "deNameIdxModD" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deNameIdxModD" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 3))) (ELit (LString "modD"))) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "True")) (ELit (LString "modDHelper"))) (EListLit)) (EApp (EVar "ELit") (EApp (EVar "LInt") (ELit (LInt 2))))) (EVar "noDeclLoc")) (EVar "noBinderId")))))
(DTypeSig false "deNameIdxChain" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "deNameIdxChain" ((PVar "gctx")) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EApp (EVar "declEnvSeedChain") (EVar "gctx")) (EListLit (EApp (EVar "deNameIdxModA") (EVar "gctx")) (EApp (EVar "deNameIdxModB") (EVar "gctx")) (EApp (EVar "deNameIdxModC") (EVar "gctx")) (EApp (EVar "deNameIdxModD") (EVar "gctx")))) (EVar "deSeedChainProbeZero"))) (DoExpr (EFieldAccess (EVar "s") "dsNames"))))
(DTypeSig false "deNameIdxChainNoUnrelated" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "deNameIdxChainNoUnrelated" ((PVar "gctx")) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EApp (EVar "declEnvSeedChain") (EVar "gctx")) (EListLit (EApp (EVar "deNameIdxModA") (EVar "gctx")) (EApp (EVar "deNameIdxModB") (EVar "gctx")))) (EVar "deSeedChainProbeZero"))) (DoExpr (EFieldAccess (EVar "s") "dsNames"))))
(DTypeSig false "deNameIdxAt" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "deNameIdxAt" ((PVar "nm") (PVar "mid")) (EApp (EVar "omKeys") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "nm")))))
(DTypeSig false "buildDataEnv" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyCon "DataEnv")))
(DFunDef false "buildDataEnv" ((PVar "rows")) (EApp (EVar "dataEnvFinish") (EApp (EApp (EVar "dataEnvFromRowsGo") (EVar "rows")) (EVar "emptyDataEnv"))))
(DTypeSig false "aliasFixturePubCore" (TyCon "Decl"))
(DFunDef false "aliasFixturePubCore" () (ERecordCreate "DTypeAlias" ((fa "tyAliasPub" (EVar "True")) (fa "tyAliasName" (ELit (LString "PubCore"))) (fa "tyAliasParams" (EListLit)) (fa "tyAliasParamKinds" (EListLit)) (fa "tyAliasRhs" (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (fa "tyAliasOrigin" (EApp (EVar "OriginModule") (ELit (LString "core")))) (fa "tyAliasNameLoc" (EVar "None")))))
(DTypeSig false "aliasFixturePrivCore" (TyCon "Decl"))
(DFunDef false "aliasFixturePrivCore" () (ERecordCreate "DTypeAlias" ((fa "tyAliasPub" (EVar "False")) (fa "tyAliasName" (ELit (LString "PrivCore"))) (fa "tyAliasParams" (EListLit)) (fa "tyAliasParamKinds" (EListLit)) (fa "tyAliasRhs" (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (fa "tyAliasOrigin" (EApp (EVar "OriginModule") (ELit (LString "core")))) (fa "tyAliasNameLoc" (EVar "None")))))
(DTypeSig false "aliasFixturePubM" (TyCon "Decl"))
(DFunDef false "aliasFixturePubM" () (ERecordCreate "DTypeAlias" ((fa "tyAliasPub" (EVar "True")) (fa "tyAliasName" (ELit (LString "PubM"))) (fa "tyAliasParams" (EListLit)) (fa "tyAliasParamKinds" (EListLit)) (fa "tyAliasRhs" (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (fa "tyAliasOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))) (fa "tyAliasNameLoc" (EVar "None")))))
(DTypeSig false "aliasFixtureAttribCore" (TyCon "Decl"))
(DFunDef false "aliasFixtureAttribCore" () (EApp (EApp (EVar "DAttrib") (EListLit (EApp (EVar "AttrDeprecated") (EApp (EVar "Some") (ELit (LString "old")))))) (ERecordCreate "DTypeAlias" ((fa "tyAliasPub" (EVar "True")) (fa "tyAliasName" (ELit (LString "AttribCore"))) (fa "tyAliasParams" (EListLit)) (fa "tyAliasParamKinds" (EListLit)) (fa "tyAliasRhs" (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (fa "tyAliasOrigin" (EApp (EVar "OriginModule") (ELit (LString "core")))) (fa "tyAliasNameLoc" (EVar "None"))))))
(DTypeSig false "aliasFixtureEnv" (TyFun (TyCon "GraphCtx") (TyCon "DataEnv")))
(DFunDef false "aliasFixtureEnv" ((PVar "gctx")) (EApp (EVar "buildDataEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "core"))) (EListLit (EVar "aliasFixturePubCore") (EVar "aliasFixturePrivCore") (EVar "aliasFixtureAttribCore"))) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "m"))) (EListLit (EVar "aliasFixturePubM"))))))
(DTypeSig false "aliasNamesAt" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "aliasNamesAt" ((PVar "cur")) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (EApp (EVar "tabKeyName") (EApp (EVar "fst") (EVar "e"))))) (EApp (EApp (EVar "aliasUniverseAt") (EVar "cur")) (EFieldAccess (EApp (EVar "aliasFixtureEnv") (EApp (EVar "probeGraphCtx") (ELit LUnit))) "deAliases"))))
(DTypeSig false "deFieldOwnerFixtureA" (TyCon "Decl"))
(DFunDef false "deFieldOwnerFixtureA" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Pt"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "Pt"))) (EApp (EApp (EVar "ConNamed") (EListLit (EApp (EApp (EVar "Field") (ELit (LString "x"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))) (EVar "False"))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deFieldOwnerFixtureB" (TyCon "Decl"))
(DFunDef false "deFieldOwnerFixtureB" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Vec"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "Vec"))) (EApp (EApp (EVar "ConNamed") (EListLit (EApp (EApp (EVar "Field") (ELit (LString "x"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))) (EVar "False"))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "n")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deFieldOwnerFixtureC" (TyCon "Decl"))
(DFunDef false "deFieldOwnerFixtureC" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Pt"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "Pt"))) (EApp (EApp (EVar "ConNamed") (EListLit (EApp (EApp (EVar "Field") (ELit (LString "x"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))) (EVar "False"))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "n")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deFieldOwnerCollisionEnv" (TyFun (TyCon "GraphCtx") (TyCon "DataEnv")))
(DFunDef false "deFieldOwnerCollisionEnv" ((PVar "gctx")) (EApp (EVar "buildDataEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "m"))) (EListLit (EVar "deFieldOwnerFixtureA") (EVar "deFieldOwnerFixtureB"))))))
(DTypeSig false "deFieldOwnerSingleEnv" (TyFun (TyCon "GraphCtx") (TyCon "DataEnv")))
(DFunDef false "deFieldOwnerSingleEnv" ((PVar "gctx")) (EApp (EVar "buildDataEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "m"))) (EListLit (EVar "deFieldOwnerFixtureA"))))))
(DTypeSig false "deFieldOwnerSameNameEnv" (TyFun (TyCon "GraphCtx") (TyCon "DataEnv")))
(DFunDef false "deFieldOwnerSameNameEnv" ((PVar "gctx")) (EApp (EVar "buildDataEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "m"))) (EListLit (EVar "deFieldOwnerFixtureA") (EVar "deFieldOwnerFixtureC"))))))
(DTypeSig false "deRecordOrderFixtureA" (TyCon "Decl"))
(DFunDef false "deRecordOrderFixtureA" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "P1"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "Pt"))) (EApp (EApp (EVar "ConNamed") (EListLit (EApp (EApp (EVar "Field") (ELit (LString "x"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))) (EVar "False"))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deRecordOrderFixtureB" (TyCon "Decl"))
(DFunDef false "deRecordOrderFixtureB" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "P2"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "Pt"))) (EApp (EApp (EVar "ConNamed") (EListLit (EApp (EApp (EVar "Field") (ELit (LString "y"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))) (EVar "False"))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "n")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deRecordOrderEnv" (TyFun (TyCon "GraphCtx") (TyCon "DataEnv")))
(DFunDef false "deRecordOrderEnv" ((PVar "gctx")) (EApp (EVar "buildDataEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "m"))) (EListLit (EVar "deRecordOrderFixtureA"))) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "n"))) (EListLit (EVar "deRecordOrderFixtureB"))))))
(DTypeSig false "deRecordIdentTyNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyApp (TyCon "List") (TyCon "Field")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "deRecordIdentTyNames" ((PList)) (EListLit))
(DFunDef false "deRecordIdentTyNames" ((PCons (PTuple PWild (PVar "tyName") PWild) (PVar "rest"))) (EBinOp "::" (EVar "tyName") (EApp (EVar "deRecordIdentTyNames") (EVar "rest"))))
(DTypeSig true "methodRowNumObservation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "NumAnchorTestObservation"))))))
(DFunDef false "methodRowNumObservation" ((PVar "saved") (PVar "caseName") (PVar "builtinDecls") (PVar "decls")) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "freshSubRecordsOf") (EFieldAccess (EVar "saved") "mcGraph"))) (DoLet false false (PVar "mctx") (EApp (EApp (EVar "carryModuleCtx") (EVar "gctx")) (EVar "saved"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef")) (EApp (EVar "builtinClassesOf") (EVar "builtinDecls")))) (DoLet false false (PVar "rows") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EVar "decls"))) (DoExpr (EApp (EApp (EVar "seedNumLitFromIntAnchor") (EVar "mctx")) (EVar "rows"))) (DoLet false false (PVar "observation") (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numLitFromIntAnchorRef") "value") (arm (PCon "None") () (ERecordCreate "NumAnchorTestObservation" ((fa "natoCase" (EVar "caseName")) (fa "natoHasRow" (EVar "False")) (fa "natoIface" (ELit (LString ""))) (fa "natoSchemeBody" (ELit (LString ""))) (fa "natoDeclaredType" (ELit (LString "")))))) (arm (PCon "Some" (PVar "anchor")) () (ERecordCreate "NumAnchorTestObservation" ((fa "natoCase" (EVar "caseName")) (fa "natoHasRow" (EVar "True")) (fa "natoIface" (EFieldAccess (EFieldAccess (EVar "anchor") "msrIface") "irName")) (fa "natoSchemeBody" (EApp (EVar "ppMono") (EApp (EVar "schemeBodyOf") (EFieldAccess (EVar "anchor") "msrScheme")))) (fa "natoDeclaredType" (EApp (EVar "ppTy") (EFieldAccess (EVar "anchor") "msrType")))))))) (DoExpr (EVar "observation"))))
(DTypeSig false "distinctIdentsIn2" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String"))) (TyCon "Bool")))
(DFunDef false "distinctIdentsIn2" ((PList (PTuple (PVar "i1") PWild) (PTuple (PVar "i2") PWild))) (EBinOp "/=" (EVar "i1") (EVar "i2")))
(DFunDef false "distinctIdentsIn2" (PWild) (EVar "False"))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "PredicateSlotArgs" true) (mem "AliasDecl" true) (mem "BuiltinClass" true) (mem "BuiltinClasses" true) (mem "DataEnv" true) (mem "DataTypeDecl" true) (mem "DeclEnvAcc" true) (mem "DeclEnvs" true) (mem "DeclEnvSeedAcc" true) (mem "Kind" true) (mem "MethodPredicateSlot" true) (mem "MethodPredicateTemplate" true) (mem "MethodSchemeRow" true) (mem "NumAnchorTestObservation" true) (mem "PredicateSlot" true) (mem "SigVars" true) (mem "DeclEnvModule" false) (mem "GraphCtx" false) (mem "ModuleCtx" false) (mem "RecordInfo" false) (mem "TcEnv" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "applyParams" false) (mem "authvarIdOf" false) (mem "collectAuthvarIds" false) (mem "collectRowEffvarIds" false) (mem "collectTyIds" false) (mem "effvarIdOf" false) (mem "foldrFun" false) (mem "monoTyvarId" false) (mem "schemeBodyOf" false) (mem "schemeIds" false) (mem "tconFrom" false) (mem "tyAppSpine" false) (mem "tyVarNames" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "carryModuleCtx" false) (mem "emptyBuiltinClasses" false) (mem "emptyDataEnv" false) (mem "freshSubRecordsOf" false) (mem "mctxAtIfSome" false) (mem "probeGraphCtx" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "addCtor" false) (mem "aliasUniverseAt" false) (mem "buildClassEnvGo" false) (mem "buildImplEnvGo" false) (mem "builtinIfaceRef" false) (mem "classEnvFinish" false) (mem "constraintSlotDispatchVar" false) (mem "declEnvDeclsOf" false) (mem "declEnvKindEntries" false) (mem "declEnvModule" false) (mem "declEnvReachFrom" false) (mem "declEnvRowVisible" false) (mem "declEnvVisibleTo" false) (mem "declGradedScope" false) (mem "declParamKinds" false) (mem "declTopFnNames" false) (mem "definersIn" false) (mem "dtopFor" false) (mem "effTailNames" false) (mem "implAccFinish" false) (mem "importLocFor" false) (mem "kindPublicDataDecl" false) (mem "methodEnvGo" false) (mem "methodSlotKey" false) (mem "namesToSet" false) (mem "publicDataDecl" false) (mem "rangedOver" false) (mem "removeAllS" false) (mem "sameIfaceDecl" false) (mem "tyTabKey" false) (mem "useModuleId" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeErrorOnce" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "importFormRows" false) (mem "memberBindsCtorName" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "atomsEscape" false) (mem "freshAuthBinderRanged" false) (mem "freshAuthvar" false) (mem "freshAuthvarRanged" false) (mem "freshEffMap" false) (mem "freshEffvar" false) (mem "freshTvMap" false) (mem "freshVar" false) (mem "namedArgDomains" false))))
(DUse false (UseGroup ("types" "tc_decls_variance") ((mem "declEnvPolarityChain" false) (mem "inferParamPolarities" false) (mem "payloadAstTypes" false) (mem "recordParamPolarities" false) (mem "seedParamPolarityFixpointScoped" false) (mem "variantPayload" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "atomsOfWritten" false) (mem "authArgBindersIn" false) (mem "authorityBinderBound" false) (mem "binderDomainsIn" false) (mem "bindingForceFromAst" false) (mem "fromAstType" false) (mem "fromAstTypeE" false) (mem "namedArgTypes" false) (mem "namedAtomBinders" false) (mem "patternSlotNamesIn" false) (mem "payloadTypesE" false) (mem "qualifiedKindScope" false) (mem "recFieldMono" false) (mem "reportBinderDomains" false) (mem "reportUnboundAuthorityNames" false) (mem "reportUnboundAuthorityNamesIn" false) (mem "rowArgNames" false) (mem "rowArgNamesIn" false) (mem "sigVarsWithAuths" false) (mem "substAliasArgs" false) (mem "writtenBindingForce" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authvarId" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "EffLabel" true) (mem "EffRow" true) (mem "Effvar" true) (mem "atomsNorm" false) (mem "pureRow" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "UsePath" true) (mem "Ns" true) (mem "Lit" true) (mem "Expr" true) (mem "Attr" true) (mem "ConPayload" true) (mem "Constraint" true) (mem "DataVis" true) (mem "Decl" true) (mem "EffAtomTy" true) (mem "Field" true) (mem "Ident" true) (mem "IfaceMethod" true) (mem "KindAnn" true) (mem "Loc" true) (mem "TabKey" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "UseMember" true) (mem "Variant" true) (mem "firstTyLoc" false) (mem "firstTyLocList" false) (mem "identOriginFold" false) (mem "lookupTab" false) (mem "mapTyFull" false) (mem "mkIdent" false) (mem "noBinderId" false) (mem "noDeclLoc" false) (mem "tabKeyEq" false) (mem "tabKeyName" false) (mem "tyConBuiltin" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "ppMono" false) (mem "ppTy" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omDelete" false) (mem "omEmpty" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false) (mem "omMapValues" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "zipL" false))))
(DUse false (UseGroup ("list") ((mem "elemIndex" false) (mem "findMap" false) (mem "head" false))))
(DUse false (UseGroup ("types" "registry") ((mem "spFloor" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "useModId" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig true "declEnvAccOf" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "DeclEnvAcc") (TyCon "DeclEnvAcc")))))
(DFunDef false "declEnvAccOf" ((PVar "gctx") (PList) (PVar "a")) (EVar "a"))
(DFunDef false "declEnvAccOf" ((PVar "gctx") (PCons (PVar "m") (PVar "rest")) (PVar "a")) (EBlock (DoLet false false (PVar "definers") (EApp (EApp (EApp (EVar "declEnvDefinerIndex") (EFieldAccess (EVar "a") "daDefiners")) (EFieldAccess (EVar "a") "daAmbig")) (EListLit (EVar "m")))) (DoExpr (EApp (EApp (EApp (EVar "declEnvAccOf") (EVar "gctx")) (EVar "rest")) (ERecordCreate "DeclEnvAcc" ((fa "daOrdIndex" (EApp (EApp (EVar "declEnvOrdIndex") (EFieldAccess (EVar "a") "daOrdIndex")) (EListLit (EVar "m")))) (fa "daDefiners" (EApp (EVar "fst") (EVar "definers"))) (fa "daAmbig" (EApp (EVar "snd") (EVar "definers"))) (fa "daData" (EApp (EApp (EVar "dataEnvFromRowsGo") (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daData"))) (fa "daImpls" (EApp (EApp (EVar "buildImplEnvGo") (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daImpls"))) (fa "daIfaces" (EApp (EApp (EApp (EVar "buildClassEnvGo") (EVar "gctx")) (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daIfaces"))) (fa "daMethods" (EApp (EApp (EApp (EVar "methodEnvGo") (EVar "gctx")) (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daMethods"))) (fa "daSeeds" (EApp (EApp (EApp (EVar "declEnvSeedChain") (EVar "gctx")) (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daSeeds"))) (fa "daPolarity" (EApp (EApp (EVar "declEnvPolarityChain") (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daPolarity"))) (fa "daOwnerModules" (EApp (EApp (EVar "declEnvOwnerModules") (EListLit (EVar "m"))) (EFieldAccess (EVar "a") "daOwnerModules")))))))))
(DTypeSig true "buildDeclEnvs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "DeclEnvAcc") (TyFun (TyCon "DeclEnvModule") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyCon "DeclEnvs"))))))
(DFunDef false "buildDeclEnvs" ((PVar "gctx") (PVar "acc") (PVar "coreRow") (PVar "modRows")) (EBlock (DoLet false false (PVar "mods") (EBinOp "::" (EVar "coreRow") (EVar "modRows"))) (DoLet false false (PVar "a") (EApp (EApp (EApp (EVar "declEnvAccOf") (EVar "gctx")) (EVar "modRows")) (EVar "acc"))) (DoExpr (ERecordCreate "DeclEnvs" ((fa "deModules" (EVar "mods")) (fa "deOrdIndex" (EFieldAccess (EVar "a") "daOrdIndex")) (fa "deDefiners" (EFieldAccess (EVar "a") "daDefiners")) (fa "deAmbigValues" (EFieldAccess (EVar "a") "daAmbig")) (fa "deAllDecls" (EApp (EVar "declEnvDeclsOf") (EVar "mods"))) (fa "deData" (EApp (EVar "dataEnvFinish") (EFieldAccess (EVar "a") "daData"))) (fa "deImpls" (EApp (EVar "implAccFinish") (EFieldAccess (EVar "a") "daImpls"))) (fa "deIfaces" (EApp (EVar "classEnvFinish") (EFieldAccess (EVar "a") "daIfaces"))) (fa "deMethods" (EFieldAccess (EVar "a") "daMethods")) (fa "deKindsBefore" (EFieldAccess (EFieldAccess (EVar "a") "daSeeds") "dsKinds")) (fa "deNameIndexBefore" (EFieldAccess (EFieldAccess (EVar "a") "daSeeds") "dsNames")) (fa "dePolaritiesBefore" (EApp (EVar "snd") (EFieldAccess (EVar "a") "daPolarity"))) (fa "deAtomsBefore" (EApp (EVar "snd") (EApp (EApp (EApp (EVar "declEnvRowAtomsChain") (EVar "gctx")) (EVar "mods")) (ETuple (EListLit) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (EListLit)) (EVar "omEmpty")))))) (fa "deOwnersBefore" (EFieldAccess (EFieldAccess (EVar "a") "daSeeds") "dsOwners")) (fa "deOwnerModules" (EFieldAccess (EVar "a") "daOwnerModules")) (fa "deReach" (EApp (EVar "declEnvReachIndex") (EVar "mods"))))))))
(DTypeSig false "declEnvRowKindEntries" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyCon "DeclEnvModule") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind"))))))))
(DFunDef false "declEnvRowKindEntries" ((PVar "gctx") (PVar "cur") (PVar "m")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "False")) (EApp (EApp (EVar "declEnvKindEntries") (EVar "gctx")) (EFieldAccess (EVar "m") "demDecls")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "True")) (EFieldAccess (EVar "m") "demKindEntries") (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "declEnvSeedChain" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "DeclEnvSeedAcc") (TyCon "DeclEnvSeedAcc")))))
(DFunDef false "declEnvSeedChain" ((PVar "gctx") (PList) (PVar "s")) (EVar "s"))
(DFunDef false "declEnvSeedChain" ((PVar "gctx") (PCons (PVar "m") (PVar "rest")) (PVar "s")) (EBlock (DoLet false false (PVar "kents") (EApp (EApp (EApp (EVar "declEnvRowKindEntries") (EVar "gctx")) (EBinOp "+" (EFieldAccess (EVar "m") "demOrd") (ELit (LInt 1)))) (EVar "m"))) (DoExpr (EApp (EApp (EApp (EVar "declEnvSeedChain") (EVar "gctx")) (EVar "rest")) (ERecordCreate "DeclEnvSeedAcc" ((fa "dsKAcc" (EBinOp "++" (EVar "kents") (EFieldAccess (EVar "s") "dsKAcc"))) (fa "dsOAcc" (EApp (EApp (EVar "declEnvDeclFieldOwners") (EApp (EApp (EVar "declEnvRowVisible") (EBinOp "+" (EFieldAccess (EVar "m") "demOrd") (ELit (LInt 1)))) (EVar "m"))) (EFieldAccess (EVar "s") "dsOAcc"))) (fa "dsNAcc" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EVar "tabKeyName") (EApp (EVar "fst") (EVar "p"))))) (EVar "kents"))) (EFieldAccess (EVar "s") "dsNAcc"))) (fa "dsKinds" (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "s") "dsKAcc")) (EFieldAccess (EVar "s") "dsKinds"))) (fa "dsOwners" (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "s") "dsOAcc")) (EFieldAccess (EVar "s") "dsOwners"))) (fa "dsNames" (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "s") "dsNAcc")) (EFieldAccess (EVar "s") "dsNames")))))))))
(DTypeSig false "declEnvRowAtomsChain" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))))))))
(DFunDef false "declEnvRowAtomsChain" ((PVar "gctx") (PList) (PVar "s")) (EVar "s"))
(DFunDef false "declEnvRowAtomsChain" ((PVar "gctx") (PCons (PVar "m") (PVar "rest")) (PTuple (PVar "aacc") (PVar "am"))) (EBlock (DoLet false false (PVar "entries") (EApp (EApp (EApp (EVar "declEnvRowAtomsEntries") (EVar "gctx")) (EBinOp "+" (EFieldAccess (EVar "m") "demOrd") (ELit (LInt 1)))) (EVar "m"))) (DoExpr (EApp (EApp (EApp (EVar "declEnvRowAtomsChain") (EVar "gctx")) (EVar "rest")) (ETuple (EBinOp "++" (EVar "entries") (EVar "aacc")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EVar "aacc")) (EVar "am")))))))
(DTypeSig false "declEnvRowAtomsEntries" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyCon "DeclEnvModule") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))))))
(DFunDef false "declEnvRowAtomsEntries" ((PVar "gctx") (PVar "cur") (PVar "m")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "False")) (EApp (EApp (EVar "declEnvRowAtomEntries") (EVar "gctx")) (EFieldAccess (EVar "m") "demDecls")) (EIf (EApp (EApp (EApp (EVar "declEnvVisibleTo") (EVar "cur")) (EFieldAccess (EVar "m") "demOrd")) (EVar "True")) (EApp (EApp (EVar "declEnvRowAtomEntries") (EVar "gctx")) (EApp (EApp (EVar "filterList") (EVar "kindPublicDataDecl")) (EFieldAccess (EVar "m") "demDecls"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "declEnvRowAtomEntries" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "declEnvRowAtomEntries" ((PVar "gctx") (PList)) (EListLit))
(DFunDef false "declEnvRowAtomEntries" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "declEnvRowAtomEntries") (EVar "gctx")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "declEnvRowAtomEntries" ((PVar "gctx") (PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataCtors" (PVar "vs")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "inferParamRowAtoms") (EVar "gctx")) (EVar "ps")) (EVar "vs"))) (EApp (EApp (EVar "declEnvRowAtomEntries") (EVar "gctx")) (EVar "rest"))))
(DFunDef false "declEnvRowAtomEntries" ((PVar "gctx") (PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "inferParamRowAtoms") (EVar "gctx")) (EVar "ps")) (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty"))))))) (EApp (EApp (EVar "declEnvRowAtomEntries") (EVar "gctx")) (EVar "rest"))))
(DFunDef false "declEnvRowAtomEntries" ((PVar "gctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "declEnvRowAtomEntries") (EVar "gctx")) (EVar "rest")))
(DTypeSig false "declEnvDeclFieldOwners" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "declEnvDeclFieldOwners" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvDeclFieldOwners" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "declEnvDeclFieldOwners") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "declEnvDeclFieldOwners" ((PCons (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "declEnvDeclFieldOwners") (EVar "rest")) (EApp (EApp (EVar "declEnvVariantFieldOwners") (EVar "vs")) (EVar "acc"))))
(DFunDef false "declEnvDeclFieldOwners" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "declEnvDeclFieldOwners") (EVar "rest")) (EVar "acc")))
(DTypeSig false "declEnvVariantFieldOwners" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "declEnvVariantFieldOwners" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvVariantFieldOwners" ((PCons (PCon "Variant" (PVar "cn") (PCon "ConNamed" (PVar "fields") PWild)) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "declEnvVariantFieldOwners") (EVar "rest")) (EApp (EApp (EApp (EVar "addFieldOwners") (EVar "cn")) (EApp (EApp (EMethodRef "map") (EVar "fieldNameOf")) (EVar "fields"))) (EVar "acc"))))
(DFunDef false "declEnvVariantFieldOwners" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "declEnvVariantFieldOwners") (EVar "rest")) (EVar "acc")))
(DTypeSig false "fieldNameOf" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldNameOf" ((PCon "Field" (PVar "fn") PWild)) (EVar "fn"))
(DTypeSig false "declEnvOwnerModules" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "declEnvOwnerModules" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvOwnerModules" ((PCons (PVar "m") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "declEnvOwnerModules") (EVar "rest")) (EApp (EApp (EApp (EVar "declEnvDeclOwnerModules") (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "m") "demDecls")) (EVar "acc"))))
(DTypeSig false "declEnvDeclOwnerModules" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "declEnvDeclOwnerModules" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvDeclOwnerModules" ((PVar "mid") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declEnvDeclOwnerModules") (EVar "mid")) (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "declEnvDeclOwnerModules" ((PVar "mid") (PCons (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declEnvDeclOwnerModules") (EVar "mid")) (EVar "rest")) (EApp (EApp (EApp (EVar "declEnvVariantOwnerModules") (EVar "mid")) (EVar "vs")) (EVar "acc"))))
(DFunDef false "declEnvDeclOwnerModules" ((PVar "mid") (PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declEnvDeclOwnerModules") (EVar "mid")) (EVar "rest")) (EVar "acc")))
(DTypeSig false "declEnvVariantOwnerModules" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "declEnvVariantOwnerModules" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvVariantOwnerModules" ((PVar "mid") (PCons (PCon "Variant" (PVar "cn") (PCon "ConNamed" PWild PWild)) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declEnvVariantOwnerModules") (EVar "mid")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "cn")) (EBinOp "::" (EVar "mid") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "cn")) (EVar "acc"))))) (EVar "acc"))))
(DFunDef false "declEnvVariantOwnerModules" ((PVar "mid") (PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declEnvVariantOwnerModules") (EVar "mid")) (EVar "rest")) (EVar "acc")))
(DTypeSig true "declEnvSeedDataUniverse" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "DeclEnvs") (TyCon "Unit")))))
(DFunDef false "declEnvSeedDataUniverse" ((PVar "mctx") (PVar "mid") (PVar "envs")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "envs") "deKindsBefore"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamNameIndexRef")) (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "envs") "deNameIndexBefore"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamPolarityRef")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "envs") "dePolaritiesBefore"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamRowAtomsRef")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "envs") "deAtomsBefore"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnersRef")) (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "envs") "deOwnersBefore"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnerModulesRef")) (EFieldAccess (EVar "envs") "deOwnerModules"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnerReachRef")) (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EFieldAccess (EVar "envs") "deReach")))))))
(DTypeSig false "dataEnvFinish" (TyFun (TyCon "DataEnv") (TyCon "DataEnv")))
(DFunDef false "dataEnvFinish" ((PVar "env")) (EVariantUpdate "DataEnv" (EVar "env") ((fa "deRecordIdents" (EApp (EApp (EVar "omMapValues") (EVar "reverseL")) (EFieldAccess (EVar "env") "deRecordIdents"))) (fa "deFieldOwnerIdents" (EApp (EApp (EVar "omMapValues") (EVar "reverseL")) (EFieldAccess (EVar "env") "deFieldOwnerIdents"))))))
(DTypeSig false "dataEnvFromRowsGo" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyCon "DataEnv") (TyCon "DataEnv"))))
(DFunDef false "dataEnvFromRowsGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "dataEnvFromRowsGo" ((PCons (PVar "m") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "dataEnvFromDeclsGo") (EFieldAccess (EVar "m") "demOrd")) (EFieldAccess (EVar "m") "demDecls")) (EVar "acc"))) (DoExpr (EApp (EApp (EVar "dataEnvFromRowsGo") (EVar "rest")) (EVariantUpdate "DataEnv" (EVar "env") ((fa "deCtorExports" (EApp (EApp (EVar "ctorExportsInto") (EVar "m")) (EFieldAccess (EVar "env") "deCtorExports")))))))))
(DTypeSig true "dataEnvFromDeclsGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "DataEnv") (TyCon "DataEnv")))))
(DFunDef false "dataEnvFromDeclsGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "dataEnvFromDeclsGo" ((PVar "ord") (PCons (PVar "d") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "dataEnvFromDeclsGo") (EVar "ord")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "dataEnvAddDecl") (EVar "ord")) (EVar "False")) (EVar "d")) (EVar "acc"))))
(DTypeSig false "dataEnvAddDecl" (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Decl") (TyFun (TyCon "DataEnv") (TyCon "DataEnv"))))))
(DFunDef false "dataEnvAddDecl" ((PVar "ord") PWild (PCon "DAttrib" PWild (PVar "d")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "dataEnvAddDecl") (EVar "ord")) (EVar "True")) (EVar "d")) (EVar "acc")))
(DFunDef false "dataEnvAddDecl" ((PVar "ord") PWild (PRec "DData" ((rf "dataName" None) (rf "dataParams" None) (rf "dataCtors" None) (rf "dataOrigin" None)) true) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "addDataTypeDecl") (EVar "dataName")) (EVar "dataOrigin")) (EVar "dataParams")) (EVar "dataCtors")) (EVar "acc")))
(DFunDef false "dataEnvAddDecl" ((PVar "ord") PWild (PRec "DNewtype" ((rf "newtypeName" None) (rf "newtypeParams" None) (rf "newtypeCtor" None) (rf "newtypeFieldTy" None) (rf "newtypeOrigin" None)) true) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "addDataTypeDecl") (EVar "newtypeName")) (EVar "newtypeOrigin")) (EVar "newtypeParams")) (EListLit (EApp (EApp (EVar "Variant") (EVar "newtypeCtor")) (EApp (EVar "ConPos") (EListLit (EVar "newtypeFieldTy")))))) (EVar "acc")))
(DFunDef false "dataEnvAddDecl" ((PVar "ord") (PVar "att") (PAs "d" (PRec "DTypeAlias" ((rf "tyAliasName" None) (rf "tyAliasParams" None) (rf "tyAliasRhs" None) (rf "tyAliasOrigin" None)) true)) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addAliasDecl") (EVar "tyAliasName")) (EVar "tyAliasOrigin")) (EVar "tyAliasParams")) (EVar "tyAliasRhs")) (EVar "ord")) (EApp (EVar "publicDataDecl") (EVar "d"))) (EVar "att")) (EVar "acc")))
(DFunDef false "dataEnvAddDecl" (PWild PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "addDataTypeDecl" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyCon "DataEnv") (TyCon "DataEnv")))))))
(DFunDef false "addDataTypeDecl" ((PVar "name") (PVar "o") (PVar "params") (PVar "variants") (PVar "env")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name"))) (DoLet false false (PVar "dt") (ERecordCreate "DataTypeDecl" ((fa "dtKey" (EVar "key")) (fa "dtName" (EVar "name")) (fa "dtOrigin" (EVar "o")) (fa "dtParams" (EVar "params")) (fa "dtVariants" (EVar "variants"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "addVariantIdentsRaw") (EVar "name")) (EVar "o")) (EVar "variants")) (EVariantUpdate "DataEnv" (EVar "env") ((fa "deTypes" (EBinOp "::" (ETuple (EVar "key") (EVar "dt")) (EFieldAccess (EVar "env") "deTypes")))))))))
(DTypeSig false "addVariantIdentsRaw" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyCon "DataEnv") (TyCon "DataEnv"))))))
(DFunDef false "addVariantIdentsRaw" (PWild PWild (PList) (PVar "env")) (EVar "env"))
(DFunDef false "addVariantIdentsRaw" ((PVar "tyName") (PVar "o") (PCons (PCon "Variant" (PVar "cn") (PVar "payload")) (PVar "rest")) (PVar "env")) (EApp (EApp (EApp (EApp (EVar "addVariantIdentsRaw") (EVar "tyName")) (EVar "o")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "addCtorIdentRaw") (EVar "tyName")) (EVar "o")) (EVar "cn")) (EVar "payload")) (EVar "env"))))
(DTypeSig false "addCtorIdentRaw" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyCon "ConPayload") (TyFun (TyCon "DataEnv") (TyCon "DataEnv")))))))
(DFunDef false "addCtorIdentRaw" ((PVar "tyName") (PVar "o") (PVar "cn") (PVar "payload") (PVar "env")) (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsCtor")) (EVar "o")) (EVar "cn")) (arm (PCon "None") () (EVar "env")) (arm (PCon "Some" (PVar "ident")) () (EBlock (DoLet false false (PVar "next") (EBinOp "++" (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "cn")) (EFieldAccess (EVar "env") "deCtorIdents"))) (EListLit (ETuple (EVar "ident") (EVar "tyName") (EApp (EApp (EVar "Variant") (EVar "cn")) (EVar "payload")))))) (DoLet false false (PVar "env2") (EVariantUpdate "DataEnv" (EVar "env") ((fa "deCtorIdents" (EApp (EApp (EApp (EVar "omInsert") (EVar "cn")) (EVar "next")) (EFieldAccess (EVar "env") "deCtorIdents")))))) (DoExpr (EMatch (EVar "payload") (arm (PCon "ConNamed" (PVar "fields") PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "addRecordIdentRaw") (EVar "tyName")) (EVar "cn")) (EVar "ident")) (EVar "fields")) (EVar "env2"))) (arm (PCon "ConPos" PWild) () (EVar "env2"))))))))
(DTypeSig false "addRecordIdentRaw" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyCon "DataEnv") (TyCon "DataEnv")))))))
(DFunDef false "addRecordIdentRaw" ((PVar "tyName") (PVar "cn") (PVar "ident") (PVar "fields") (PVar "env")) (EBlock (DoLet false false (PVar "next") (EBinOp "::" (ETuple (EVar "ident") (EVar "tyName") (EVar "fields")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "cn")) (EFieldAccess (EVar "env") "deRecordIdents"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "addFieldOwnerIdents") (EVar "ident")) (EVar "cn")) (EVar "fields")) (EVariantUpdate "DataEnv" (EVar "env") ((fa "deRecordIdents" (EApp (EApp (EApp (EVar "omInsert") (EVar "cn")) (EVar "next")) (EFieldAccess (EVar "env") "deRecordIdents")))))))))
(DTypeSig false "addFieldOwnerIdents" (TyFun (TyCon "Ident") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyCon "DataEnv") (TyCon "DataEnv"))))))
(DFunDef false "addFieldOwnerIdents" (PWild PWild (PList) (PVar "env")) (EVar "env"))
(DFunDef false "addFieldOwnerIdents" ((PVar "ident") (PVar "cn") (PCons (PCon "Field" (PVar "fn") PWild) (PVar "rest")) (PVar "env")) (EBlock (DoLet false false (PVar "next") (EBinOp "::" (ETuple (EVar "ident") (EVar "cn")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "fn")) (EFieldAccess (EVar "env") "deFieldOwnerIdents"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "addFieldOwnerIdents") (EVar "ident")) (EVar "cn")) (EVar "rest")) (EVariantUpdate "DataEnv" (EVar "env") ((fa "deFieldOwnerIdents" (EApp (EApp (EApp (EVar "omInsert") (EVar "fn")) (EVar "next")) (EFieldAccess (EVar "env") "deFieldOwnerIdents")))))))))
(DTypeSig false "addAliasDecl" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "DataEnv") (TyCon "DataEnv"))))))))))
(DFunDef false "addAliasDecl" ((PVar "name") (PVar "o") (PVar "params") (PVar "rhs") (PVar "ord") (PVar "pub") (PVar "att") (PVar "env")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name"))) (DoLet false false (PVar "ad") (ERecordCreate "AliasDecl" ((fa "adKey" (EVar "key")) (fa "adName" (EVar "name")) (fa "adParams" (EVar "params")) (fa "adRhs" (EVar "rhs")) (fa "adOrd" (EVar "ord")) (fa "adPub" (EVar "pub")) (fa "adAttrib" (EVar "att"))))) (DoExpr (EVariantUpdate "DataEnv" (EVar "env") ((fa "deAliases" (EBinOp "::" (ETuple (EVar "key") (EVar "ad")) (EFieldAccess (EVar "env") "deAliases"))))))))
(DTypeSig true "paramRowAtomsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TabKey") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "paramRowAtomsOf" ((PVar "mctx") (PVar "key")) (EApp (EApp (EVar "lookupTab") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamRowAtomsRef") "value")))
(DTypeSig false "constraintVarNamesTy" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constraintVarNamesTy" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "constraintArgVarNames")) (EVar "cs")) (EApp (EVar "constraintVarNamesTy") (EVar "t"))))
(DFunDef false "constraintVarNamesTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "constraintVarNamesTy") (EVar "t")))
(DFunDef false "constraintVarNamesTy" (PWild) (EListLit))
(DTypeSig false "constraintArgVarNames" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constraintArgVarNames" ((PRec "Constraint" ((rf "constraintArgs" (PVar "tys"))) false)) (EApp (EApp (EDictApp "flatMap") (EVar "tyVarNames")) (EVar "tys")))
(DTypeSig false "tyVarNamesWithConstraints" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyVarNamesWithConstraints" ((PVar "ty")) (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "tyVarNames") (EVar "ty")) (EApp (EVar "constraintVarNamesTy") (EVar "ty")))))
(DTypeSig true "tyConNamesInTy" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyConNamesInTy" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "tyConNamesInTy" ((PCon "TyVar" PWild)) (EListLit))
(DFunDef false "tyConNamesInTy" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "tyConNamesInTy") (EVar "a")) (EApp (EVar "tyConNamesInTy") (EVar "b"))))
(DFunDef false "tyConNamesInTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "tyConNamesInTy") (EVar "a")) (EApp (EVar "tyConNamesInTy") (EVar "b"))))
(DFunDef false "tyConNamesInTy" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EVar "tyConNamesInTy")) (EVar "ts")))
(DFunDef false "tyConNamesInTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "tyConNamesInTy") (EVar "t")))
(DFunDef false "tyConNamesInTy" ((PCon "TyRow" PWild PWild PWild)) (EListLit))
(DFunDef false "tyConNamesInTy" ((PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "tyConNamesInTy" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "tyConNamesInTy") (EVar "t")))
(DFunDef false "tyConNamesInTy" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "tyConNamesInTy") (EVar "t")))
(DFunDef false "tyConNamesInTy" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "tyConNamesInConstraint")) (EVar "cs")) (EApp (EVar "tyConNamesInTy") (EVar "t"))))
(DTypeSig false "tyConNamesInConstraint" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyConNamesInConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iname")) (rf "constraintArgs" (PVar "tys"))) false)) (EBinOp "::" (EVar "iname") (EApp (EApp (EDictApp "flatMap") (EVar "tyConNamesInTy")) (EVar "tys"))))
(DTypeSig false "takeUntilInclusiveS" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "takeUntilInclusiveS" (PWild (PList)) (EListLit))
(DFunDef false "takeUntilInclusiveS" ((PVar "target") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "x") (EVar "target")) (EListLit (EVar "x")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeUntilInclusiveS") (EVar "target")) (EVar "xs")))))
(DTypeSig false "buildAliasGraphEntry" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildAliasGraphEntry" ((PVar "aliasSet") (PTuple (PVar "key") (PVar "paramsRhs"))) (EBlock (DoLet false false (PVar "rhs") (EApp (EVar "snd") (EVar "paramsRhs"))) (DoExpr (ETuple (EApp (EVar "tabKeyName") (EVar "key")) (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "aliasSet")))) (EApp (EVar "dedup") (EApp (EVar "tyConNamesInTy") (EVar "rhs"))))))))
(DTypeSig false "aliasDfsVisit" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "Unit"))))))))
(DFunDef false "aliasDfsVisit" ((PVar "graph") (PVar "visitedRef") (PVar "onStackRef") (PVar "onStackSetRef") (PVar "cyclicOut") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EUnOp "!" (EVar "visitedRef"))) (ELit LUnit) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EUnOp "!" (EVar "onStackSetRef"))) (EApp (EApp (EVar "setRef") (EVar "cyclicOut")) (EApp (EVar "dedup") (EBinOp "++" (EApp (EApp (EVar "takeUntilInclusiveS") (EVar "name")) (EUnOp "!" (EVar "onStackRef"))) (EUnOp "!" (EVar "cyclicOut"))))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "onStackRef")) (EBinOp "::" (EVar "name") (EUnOp "!" (EVar "onStackRef"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "onStackSetRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EUnOp "!" (EVar "onStackSetRef"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasDfsVisitNeighbors") (EVar "graph")) (EVar "visitedRef")) (EVar "onStackRef")) (EVar "onStackSetRef")) (EVar "cyclicOut")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "graph"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "onStackRef")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "name")))) (EUnOp "!" (EVar "onStackRef"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "onStackSetRef")) (EApp (EApp (EVar "omDelete") (EVar "name")) (EUnOp "!" (EVar "onStackSetRef"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "visitedRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EUnOp "!" (EVar "visitedRef")))))))))
(DTypeSig false "aliasDfsVisitNeighbors" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))))))
(DFunDef false "aliasDfsVisitNeighbors" (PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "aliasDfsVisitNeighbors" ((PVar "graph") (PVar "visitedRef") (PVar "onStackRef") (PVar "onStackSetRef") (PVar "cyclicOut") (PCons (PVar "n") (PVar "ns"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasDfsVisit") (EVar "graph")) (EVar "visitedRef")) (EVar "onStackRef")) (EVar "onStackSetRef")) (EVar "cyclicOut")) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasDfsVisitNeighbors") (EVar "graph")) (EVar "visitedRef")) (EVar "onStackRef")) (EVar "onStackSetRef")) (EVar "cyclicOut")) (EVar "ns")))))
(DTypeSig false "aliasDfsVisitAll" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))))))
(DFunDef false "aliasDfsVisitAll" (PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "aliasDfsVisitAll" ((PVar "graph") (PVar "visitedRef") (PVar "onStackRef") (PVar "onStackSetRef") (PVar "cyclicOut") (PCons (PVar "k") (PVar "ks"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasDfsVisit") (EVar "graph")) (EVar "visitedRef")) (EVar "onStackRef")) (EVar "onStackSetRef")) (EVar "cyclicOut")) (EVar "k"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasDfsVisitAll") (EVar "graph")) (EVar "visitedRef")) (EVar "onStackRef")) (EVar "onStackSetRef")) (EVar "cyclicOut")) (EVar "ks")))))
(DTypeSig false "emitCyclicAliasErrors" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "emitCyclicAliasErrors" ((PVar "mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "emitCyclicAliasErrors" ((PVar "mctx") (PVar "prog") (PVar "table") (PCons (PVar "name") (PVar "rest"))) (EBlock (DoLet false false (PVar "reader") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentModuleRef") "value")) (DoLet false false (PVar "named") (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "tabKeyName") (EApp (EVar "fst") (EVar "e"))) (EVar "name")))) (EVar "table"))) (DoLet false false (PVar "loc") (EMatch (EApp (EApp (EDictApp "find") (ELam ((PVar "e")) (EApp (EApp (EVar "aliasDeclaredBy") (EVar "reader")) (EApp (EVar "fst") (EVar "e"))))) (EVar "named")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "firstTyLoc") (EApp (EVar "snd") (EApp (EVar "snd") (EVar "e"))))) (arm (PCon "None") () (EApp (EApp (EVar "findMap") (ELam ((PVar "e")) (EMatch (EApp (EVar "tabKeyModule") (EApp (EVar "fst") (EVar "e"))) (arm (PCon "Some" (PVar "owner")) () (EApp (EApp (EApp (EVar "importLocFor") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deReach")) (EVar "prog")) (EVar "owner"))) (arm (PCon "None") () (EVar "None"))))) (EVar "named"))))) (DoExpr (EApp (EApp (EApp (EVar "pushTypeErrorOnce") (EApp (EApp (EVar "mctxAtIfSome") (EVar "loc")) (EVar "mctx"))) (ELit (LString "T-RECURSIVE-ALIAS"))) (EBinOp "++" (EBinOp "++" (ELit (LString "type alias `")) (EVar "name")) (ELit (LString "` is recursive; a type alias cannot refer to itself, so declare a `data` type instead"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "emitCyclicAliasErrors") (EVar "mctx")) (EVar "prog")) (EVar "table")) (EVar "rest")))))
(DTypeSig false "aliasDeclaredBy" (TyFun (TyCon "String") (TyFun (TyCon "TabKey") (TyCon "Bool"))))
(DFunDef false "aliasDeclaredBy" ((PVar "reader") (PVar "key")) (EMatch (EApp (EVar "tabKeyModule") (EVar "key")) (arm (PCon "Some" (PVar "owner")) () (EBinOp "==" (EVar "owner") (EVar "reader"))) (arm (PCon "None") () (EVar "True"))))
(DTypeSig false "tabKeyModule" (TyFun (TyCon "TabKey") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "tabKeyModule" ((PCon "TkIdent" (PCon "Ident" PWild (PVar "origin") PWild))) (EApp (EApp (EApp (EVar "identOriginFold") (EVar "None")) (ELam ((PVar "mid")) (EApp (EVar "Some") (EVar "mid")))) (EVar "origin")))
(DFunDef false "tabKeyModule" ((PCon "TkBare" PWild PWild)) (EVar "None"))
(DTypeSig true "rejectCyclicAliases" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "rejectCyclicAliases" ((PVar "mctx") (PVar "prog")) (EBlock (DoLet false false (PVar "table") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (DoLet false false (PVar "aliasKeys") (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (EApp (EVar "tabKeyName") (EApp (EVar "fst") (EVar "e"))))) (EVar "table"))) (DoLet false false (PVar "aliasSet") (EApp (EApp (EVar "omFromNames") (EVar "aliasKeys")) (EVar "omEmpty"))) (DoLet false false (PVar "graph") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EMethodRef "map") (EApp (EVar "buildAliasGraphEntry") (EVar "aliasSet"))) (EVar "table")))) (EVar "omEmpty"))) (DoLet false false (PVar "visitedRef") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoLet false false (PVar "onStackRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "onStackSetRef") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoLet false false (PVar "cyclicOut") (EApp (EVar "Ref") (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "aliasDfsVisitAll") (EVar "graph")) (EVar "visitedRef")) (EVar "onStackRef")) (EVar "onStackSetRef")) (EVar "cyclicOut")) (EVar "aliasKeys"))) (DoLet false false (PVar "cyclic") (EUnOp "!" (EVar "cyclicOut"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "emitCyclicAliasErrors") (EVar "mctx")) (EVar "prog")) (EVar "table")) (EVar "cyclic"))) (DoLet false false (PVar "cyclicSet") (EApp (EApp (EVar "omFromNames") (EVar "cyclic")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef")) (EApp (EApp (EVar "filterList") (ELam ((PVar "entry")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "tabKeyName") (EApp (EVar "fst") (EVar "entry")))) (EVar "cyclicSet"))))) (EVar "table"))))))
(DTypeSig true "astTypeFreshTbl" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "astTypeFreshTbl" ((PVar "outer") (PVar "ty")) (EApp (EApp (EApp (EVar "atSignature") (EVar "outer")) (EVar "ty")) (ELam ((PVar "mctx")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "rowArgNames") (EVar "mctx")) (EVar "ty"))) (DoLet false false (PVar "auths") (EApp (EApp (EVar "authArgBindersIn") (EVar "mctx")) (EVar "ty"))) (DoLet false false (PVar "etbl") (EApp (EApp (EApp (EApp (EVar "sigVarsForWith") (EVar "mctx")) (EVar "ty")) (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "effTailNames") (EVar "ty")) (EVar "rows")))) (EVar "auths"))) (DoLet false false (PVar "tvs") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EApp (EApp (EVar "sigTyVarNames") (EVar "ty")) (EVar "rows")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "auths"))))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty")) (EVar "tvs")))))))
(DTypeSig false "atSignature" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyFun (TyCon "ModuleCtx") (TyVar "a")) (TyVar "a")))))
(DFunDef false "atSignature" ((PVar "mctx") (PVar "ty") (PVar "body")) (EApp (EVar "body") (EApp (EApp (EVar "mctxAtIfSome") (EApp (EVar "firstTyLoc") (EVar "ty"))) (EVar "mctx"))))
(DTypeSig true "sigToScheme" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Scheme"))))
(DFunDef false "sigToScheme" ((PVar "mctx") (PVar "ty")) (EApp (EVar "fst") (EApp (EApp (EVar "sigToSchemeTvs") (EVar "mctx")) (EVar "ty"))))
(DTypeSig true "sigToSchemeTvs" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyTuple (TyCon "Scheme") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "sigToSchemeTvs" ((PVar "mctx") (PVar "ty")) (EApp (EApp (EApp (EVar "sigToSchemeTvsIn") (EVar "mctx")) (EListLit)) (EVar "ty")))
(DTypeSig true "sigToSchemeTvsIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Scheme") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))))
(DFunDef false "sigToSchemeTvsIn" ((PVar "outer") (PVar "scope") (PVar "ty")) (EApp (EApp (EApp (EVar "atSignature") (EVar "outer")) (EVar "ty")) (ELam ((PVar "mctx")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EVar "rowArgNamesIn") (EVar "mctx")) (EApp (EApp (EApp (EVar "qualifiedKindScope") (EVar "mctx")) (EVar "scope")) (EVar "ty"))) (EVar "ty"))) (DoLet false false (PVar "auths") (EApp (EApp (EVar "authArgBindersIn") (EVar "mctx")) (EVar "ty"))) (DoLet false false (PVar "tvs") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EApp (EApp (EVar "sigTyVarNames") (EVar "ty")) (EVar "rows")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "auths"))))) (DoLet false false (PVar "etbl") (EApp (EApp (EApp (EApp (EVar "sigVarsForWith") (EVar "mctx")) (EVar "ty")) (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "effTailNames") (EVar "ty")) (EVar "rows")))) (EVar "auths"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EApp (EApp (EMethodRef "map") (EVar "monoTyvarId")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "tvs")))) (EApp (EApp (EMethodRef "map") (EVar "effvarIdOf")) (EFieldAccess (EVar "etbl") "svRows"))) (EApp (EApp (EMethodRef "map") (EVar "authvarIdOf")) (EFieldAccess (EVar "etbl") "svAuths"))) (EListLit)) (EApp (EApp (EApp (EApp (EVar "bindingForceFromAst") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty"))) (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty"))) (EVar "tvs")))))))
(DTypeSig true "sigVarsFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "SigVars")))))
(DFunDef false "sigVarsFor" ((PVar "mctx") (PVar "ty") (PVar "rowNames")) (EApp (EApp (EApp (EApp (EVar "sigVarsForWith") (EVar "mctx")) (EVar "ty")) (EVar "rowNames")) (EApp (EApp (EVar "authArgBindersIn") (EVar "mctx")) (EVar "ty"))))
(DTypeSig false "sigVarsForWith" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "SigVars"))))))
(DFunDef false "sigVarsForWith" ((PVar "mctx") (PVar "ty") (PVar "rowNames") (PVar "auths")) (EBlock (DoLet false false (PVar "named") (EApp (EVar "namedArgTypes") (EVar "ty"))) (DoLet false false (PVar "authNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "auths"))) (DoLet false false (PVar "uses") (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "binderDomainsIn") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty")) (EApp (EApp (EVar "namedAtomBinders") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ty"))) (EVar "auths"))) (DoExpr (EApp (EApp (EApp (EVar "reportBinderDomains") (EVar "mctx")) (EVar "ty")) (EVar "uses"))) (DoLet false false (PVar "ranged") (EApp (EApp (EApp (EVar "binderIsPattern") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EVar "namedArgDomains") (EVar "ty"))) (EApp (EApp (EVar "patternSlotNamesIn") (EVar "mctx")) (EVar "ty")))) (DoLet false false (PVar "sv") (ERecordCreate "SigVars" ((fa "svRows" (EApp (EApp (EVar "freshEffMap") (EVar "mctx")) (EVar "rowNames"))) (fa "svAuths" (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EApp (EApp (EApp (EVar "freshAuthBinderRanged") (EVar "mctx")) (EApp (EVar "ranged") (EApp (EVar "fst") (EVar "b")))) (EVar "b")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EApp (EVar "authorityBinderBound") (EVar "named")) (EVar "authNames")) (EApp (EVar "fst") (EVar "b"))))) (EApp (EApp (EVar "dedupBinders") (EVar "uses")) (EListLit)))))))) (DoExpr (EApp (EApp (EApp (EVar "reportUnboundAuthorityNames") (EVar "mctx")) (EVar "ty")) (EVar "sv"))) (DoExpr (EVar "sv"))))
(DTypeSig false "sigTyVarNames" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "sigTyVarNames" ((PVar "ty") (PVar "rows") (PVar "authNames")) (EApp (EApp (EVar "removeAllS") (EBinOp "++" (EVar "rows") (EVar "authNames"))) (EApp (EVar "tyVarNamesWithConstraints") (EVar "ty"))))
(DTypeSig false "binderIsPattern" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "EffAtomTy")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "binderIsPattern" ((PVar "gctx") (PVar "domains") (PVar "pats") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "domains")) (arm (PCon "Some" (PCon "Some" (PVar "d"))) () (EApp (EApp (EApp (EVar "rangedOver") (EVar "gctx")) (EApp (EApp (EVar "EffLabel") (EFieldAccess (EVar "d") "eatLabel")) (EFieldAccess (EVar "d") "eatOrigin"))) (EFieldAccess (EVar "d") "eatPattern"))) (arm (PCon "Some" (PCon "None")) () (EVar "False")) (arm (PCon "None") () (EApp (EApp (EVar "contains") (EVar "n")) (EVar "pats")))))
(DTypeSig true "dedupBinders" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "dedupBinders" ((PList) (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "dedupBinders" ((PCons (PTuple (PVar "n") (PVar "top")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "acc"))) (EApp (EApp (EVar "dedupBinders") (EVar "rest")) (EVar "acc")) (EApp (EApp (EVar "dedupBinders") (EVar "rest")) (EBinOp "::" (ETuple (EVar "n") (EVar "top")) (EVar "acc")))))
(DTypeSig true "rowArgAtomsIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "rowArgAtomsIn" ((PVar "mctx") (PVar "scope") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "kinded") (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EApp (EApp (EApp (EApp (EApp (EVar "rowArgAtomsApp") (EVar "mctx")) (EVar "scope")) (EVar "o")) (EVar "n")) (EVar "args"))) (arm (PTuple (PCon "TyVar" (PVar "h")) (PVar "args")) () (EApp (EApp (EApp (EApp (EVar "rowArgAtomsVarApp") (EVar "mctx")) (EVar "scope")) (EVar "h")) (EVar "args"))) (arm PWild () (EVar "None")))) (DoExpr (EMatch (EVar "kinded") (arm (PCon "Some" (PVar "occs")) () (EVar "occs")) (arm (PCon "None") () (EBinOp "++" (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "b"))))))))
(DFunDef false "rowArgAtomsIn" ((PVar "mctx") (PVar "scope") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "b"))))
(DFunDef false "rowArgAtomsIn" ((PVar "mctx") (PVar "scope") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope"))) (EVar "ts")))
(DFunDef false "rowArgAtomsIn" ((PVar "mctx") (PVar "scope") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "rowArgAtomsIn" ((PVar "mctx") (PVar "scope") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope")) (EVar "t")))
(DFunDef false "rowArgAtomsIn" ((PVar "mctx") PWild PWild) (EListLit))
(DTypeSig false "rowArgAtomsApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))))))
(DFunDef false "rowArgAtomsApp" ((PVar "mctx") (PVar "scope") (PVar "o") (PVar "n") (PVar "args")) (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "kinds")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "paramRowAtomsOf") (EVar "mctx")) (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))))) (EVar "args")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope"))) (EVar "args"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "rowArgAtomsVarApp" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))))))
(DFunDef false "rowArgAtomsVarApp" ((PVar "mctx") (PVar "scope") (PVar "h") (PVar "args")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "h")) (EVar "scope")) (arm (PCon "Some" (PVar "kinds")) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "kinds")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "kinds")) (EListLit)) (EVar "args")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "rowArgAtomsIn") (EVar "mctx")) (EVar "scope"))) (EVar "args"))))) (arm PWild () (EVar "None"))))
(DTypeSig true "krowArgVarAtoms" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))))))))
(DFunDef false "krowArgVarAtoms" ((PVar "gctx") (PList) PWild PWild) (EListLit))
(DFunDef false "krowArgVarAtoms" ((PVar "gctx") PWild PWild (PList)) (EListLit))
(DFunDef false "krowArgVarAtoms" ((PVar "gctx") (PCons (PCon "KRow") (PVar "ks")) (PVar "decls") (PCons (PCon "TyVar" (PVar "n")) (PVar "as2"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EVar "head") (EVar "decls")))) (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EVar "gctx")) (EVar "ks")) (EApp (EVar "restAtoms") (EVar "decls"))) (EVar "as2"))))
(DFunDef false "krowArgVarAtoms" ((PVar "gctx") (PCons (PCon "KRow") (PVar "ks")) (PVar "decls") (PCons (PCon "TyRow" (PVar "labels") (PVar "tails") PWild) (PVar "as2"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "atomsNorm") (EBinOp "++" (EApp (EApp (EVar "atomsOfWritten") (EVar "gctx")) (EVar "labels")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EVar "head") (EVar "decls")))))))) (EVar "tails")) (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EVar "gctx")) (EVar "ks")) (EApp (EVar "restAtoms") (EVar "decls"))) (EVar "as2"))))
(DFunDef false "krowArgVarAtoms" ((PVar "gctx") (PCons PWild (PVar "ks")) (PVar "decls") (PCons PWild (PVar "as2"))) (EApp (EApp (EApp (EApp (EVar "krowArgVarAtoms") (EVar "gctx")) (EVar "ks")) (EApp (EVar "restAtoms") (EVar "decls"))) (EVar "as2")))
(DTypeSig false "restAtoms" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "restAtoms" ((PList)) (EListLit))
(DFunDef false "restAtoms" ((PCons PWild (PVar "rest"))) (EVar "rest"))
(DTypeSig true "builtinClassesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "BuiltinClasses")))
(DFunDef false "builtinClassesOf" ((PVar "decls")) (EApp (EApp (EVar "builtinClassesGo") (EVar "decls")) (EVar "emptyBuiltinClasses")))
(DTypeSig true "builtinClassesGo" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "BuiltinClasses") (TyCon "BuiltinClasses"))))
(DFunDef false "builtinClassesGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "builtinClassesGo" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "builtinClassesGo") (EVar "rest")) (EApp (EApp (EVar "builtinClassesGo") (EListLit (EVar "d"))) (EVar "acc"))))
(DFunDef false "builtinClassesGo" ((PCons (PRec "DInterface" ((rf "name" None) (rf "ifaceOrigin" (PVar "o")) (rf "methods" None)) true) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "builtinClassesGo") (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "builtinClassSet") (EVar "name")) (EVar "o")) (EApp (EVar "isNonEmptyL") (EVar "methods"))) (EVar "acc"))))
(DFunDef false "builtinClassesGo" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "builtinClassesGo") (EVar "rest")) (EVar "acc")))
(DTypeSig false "builtinClassSet" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "Bool") (TyFun (TyCon "BuiltinClasses") (TyCon "BuiltinClasses"))))))
(DFunDef false "builtinClassSet" ((PLit (LString "Num")) PWild PWild (PVar "acc")) (EIf (EFieldAccess (EVar "acc") "bcNumPresent") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "builtinClassSet" ((PLit (LString "Num")) (PVar "o") (PVar "p") (PVar "acc")) (EVariantUpdate "BuiltinClasses" (EVar "acc") ((fa "bcNum" (EVar "o")) (fa "bcNumPresent" (EBinOp "||" (EFieldAccess (EVar "acc") "bcNumPresent") (EVar "p"))))))
(DFunDef false "builtinClassSet" ((PLit (LString "Eq")) PWild PWild (PVar "acc")) (EIf (EFieldAccess (EVar "acc") "bcEqPresent") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "builtinClassSet" ((PLit (LString "Eq")) (PVar "o") (PVar "p") (PVar "acc")) (EVariantUpdate "BuiltinClasses" (EVar "acc") ((fa "bcEq" (EVar "o")) (fa "bcEqPresent" (EBinOp "||" (EFieldAccess (EVar "acc") "bcEqPresent") (EVar "p"))))))
(DFunDef false "builtinClassSet" ((PLit (LString "Ord")) PWild PWild (PVar "acc")) (EIf (EFieldAccess (EVar "acc") "bcOrdPresent") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "builtinClassSet" ((PLit (LString "Ord")) (PVar "o") (PVar "p") (PVar "acc")) (EVariantUpdate "BuiltinClasses" (EVar "acc") ((fa "bcOrd" (EVar "o")) (fa "bcOrdPresent" (EBinOp "||" (EFieldAccess (EVar "acc") "bcOrdPresent") (EVar "p"))))))
(DFunDef false "builtinClassSet" ((PLit (LString "Semigroup")) PWild PWild (PVar "acc")) (EIf (EFieldAccess (EVar "acc") "bcSemigroupPresent") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "builtinClassSet" ((PLit (LString "Semigroup")) (PVar "o") (PVar "p") (PVar "acc")) (EVariantUpdate "BuiltinClasses" (EVar "acc") ((fa "bcSemigroup" (EVar "o")) (fa "bcSemigroupPresent" (EBinOp "||" (EFieldAccess (EVar "acc") "bcSemigroupPresent") (EVar "p"))))))
(DFunDef false "builtinClassSet" (PWild PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig true "registerData" (TyFun (TyCon "TcEnv") (TyFun (TyCon "Decl") (TyCon "TcEnv"))))
(DFunDef false "registerData" ((PVar "env") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "registerData") (EVar "env")) (EVar "d")))
(DFunDef false "registerData" ((PVar "env") (PRec "DData" ((rf "dataName" (PVar "name")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "anns")) (rf "dataCtors" (PVar "variants")) (rf "dataCtorBinders" (PVar "binders")) (rf "dataOrigin" (PVar "o"))) false)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerVariants") (EVar "o")) (EVar "env")) (EVar "name")) (EVar "params")) (EVar "anns")) (EVar "variants")) (EVar "binders")))
(DFunDef false "registerData" ((PVar "env") (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "name")) (rf "tyAliasParams" (PVar "params")) (rf "tyAliasRhs" (PVar "rhs")) (rf "tyAliasOrigin" (PVar "o"))) false)) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "aliasTableRef")) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name")) (ETuple (EVar "params") (EVar "rhs"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "aliasTableRef") "value")))) (DoExpr (EVar "env"))))
(DFunDef false "registerData" ((PVar "env") (PRec "DNewtype" ((rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "params")) (rf "newtypeParamKinds" (PVar "anns")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeCtorBinders" (PVar "binders")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeOrigin" (PVar "o"))) false)) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerVariants") (EVar "o")) (EVar "env")) (EVar "name")) (EVar "params")) (EVar "anns")) (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty")))))) (EListLit (EVar "binders"))))
(DFunDef false "registerData" ((PVar "env") PWild) (EVar "env"))
(DTypeSig false "registerRecordInfoKeyed" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyCon "Unit"))))))))))
(DFunDef false "registerRecordInfoKeyed" ((PVar "mctx") (PVar "o") (PVar "key") (PVar "typeName") (PVar "params") (PVar "kinds") (PVar "binders") (PVar "fields")) (EBlock (DoLet false false (PVar "paramReprs") (EApp (EApp (EApp (EVar "mintParamReprs") (EVar "mctx")) (EVar "params")) (EVar "kinds"))) (DoLet false false (PVar "tvs") (EApp (EApp (EApp (EVar "ktypeTvs") (EVar "params")) (EVar "kinds")) (EVar "paramReprs"))) (DoLet false false (PVar "opened") (EApp (EApp (EVar "existentialCells") (EVar "mctx")) (EVar "binders"))) (DoExpr (EApp (EApp (EVar "recordExistentials") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "opened"))) (DoLet false false (PVar "etbl") (EApp (EApp (EVar "sigVarsWithAuths") (EVar "opened")) (EApp (EApp (EApp (EVar "paramEtbl") (EVar "params")) (EVar "kinds")) (EVar "paramReprs")))) (DoLet false false (PVar "result") (EApp (EApp (EVar "applyParams") (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "typeName"))) (EVar "paramReprs"))) (DoLet false false (PVar "fieldMonos") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "recFieldMono") (EVar "mctx")) (EVar "etbl")) (EVar "tvs"))) (EVar "fields"))) (DoLet false false (PVar "ri") (EApp (EApp (EApp (EApp (EApp (EVar "RecordInfo") (EApp (EVar "collectTyIds") (EVar "paramReprs"))) (EBinOp "++" (EApp (EVar "collectAuthvarIds") (EVar "paramReprs")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EApp (EVar "authvarId") (EApp (EVar "snd") (EVar "c"))))) (EVar "opened")))) (EVar "result")) (EVar "fieldMonos")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "fieldMonos"))) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "ri")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnersRef")) (EApp (EApp (EApp (EVar "addFieldOwners") (EVar "key")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "fieldMonos"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnersRef") "value"))))))
(DTypeSig true "addFieldOwners" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "addFieldOwners" (PWild (PList) (PVar "m")) (EVar "m"))
(DFunDef false "addFieldOwners" ((PVar "key") (PCons (PVar "fn") (PVar "rest")) (PVar "m")) (EApp (EApp (EApp (EVar "addFieldOwners") (EVar "key")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "fn")) (EBinOp "::" (EVar "key") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "fn")) (EVar "m"))))) (EVar "m"))))
(DTypeSig false "registerVariants" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))) (TyCon "TcEnv")))))))))
(DFunDef false "registerVariants" ((PVar "o") (PVar "env") (PVar "name") (PVar "params") (PVar "anns") (PVar "variants") (PVar "binders")) (EBlock (DoLet false false (PVar "kinds") (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "params")) (EVar "anns"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupTab") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name"))) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "dataParamPolarityRef") "value")) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "recordParamPolarities") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "o")) (EVar "name")) (EApp (EApp (EApp (EApp (EVar "inferParamPolarities") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcCells") "dataParamPolarityRef") "value")) (EVar "params")) (EVar "anns")) (EVar "variants")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordParamRowAtoms") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "o")) (EVar "name")) (EApp (EApp (EApp (EVar "inferParamRowAtoms") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "params")) (EVar "variants")))) (DoLet false false (PVar "paramReprs") (EApp (EApp (EApp (EVar "mintParamReprs") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "params")) (EVar "kinds"))) (DoLet false false (PVar "tvs") (EApp (EApp (EApp (EVar "ktypeTvs") (EVar "params")) (EVar "kinds")) (EVar "paramReprs"))) (DoLet false false (PVar "etbl") (EApp (EApp (EApp (EVar "paramEtbl") (EVar "params")) (EVar "kinds")) (EVar "paramReprs"))) (DoLet false false (PVar "paramTyIds") (EApp (EVar "collectTyIds") (EVar "paramReprs"))) (DoLet false false (PVar "rowEffvarIds") (EApp (EVar "collectRowEffvarIds") (EVar "paramReprs"))) (DoLet false false (PVar "authvarIds") (EApp (EVar "collectAuthvarIds") (EVar "paramReprs"))) (DoLet false false (PVar "result") (EApp (EApp (EVar "applyParams") (EApp (EApp (EVar "tconFrom") (EVar "o")) (EVar "name"))) (EVar "paramReprs"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerNamedFieldVariants") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "o")) (EVar "name")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EVar "binders"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addVariants") (EVar "env")) (EVar "tvs")) (EVar "etbl")) (EVar "paramTyIds")) (EVar "rowEffvarIds")) (EVar "authvarIds")) (EVar "result")) (EVar "variants")) (EApp (EApp (EVar "padCtorBinders") (EVar "variants")) (EVar "binders"))))))
(DTypeSig false "recordCtors" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyCon "DataVis") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Unit"))))))))
(DFunDef false "recordCtors" ((PVar "gctx") (PVar "o") (PVar "name") (PVar "vis") (PVar "params") (PVar "variants")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeDataCtors")) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name")) (ETuple (EVar "vis") (EVar "params") (EVar "variants"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeDataCtors") "value"))))
(DTypeSig false "recordParamKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Unit"))))))
(DFunDef false "recordParamKinds" ((PVar "mctx") (PVar "o") (PVar "name") (PVar "kinds")) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name")) (EVar "kinds"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef")) (EBinOp "::" (EVar "entry") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamNameIndexRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamNameIndexRef") "value"))))))
(DTypeSig false "recordParamRowAtoms" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyCon "Unit"))))))
(DFunDef false "recordParamRowAtoms" ((PVar "mctx") (PVar "o") (PVar "name") (PVar "atomss")) (EBlock (DoLet false false (PVar "entry") (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "name")) (EVar "atomss"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamRowAtomsRef")) (EBinOp "::" (EVar "entry") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamRowAtomsRef") "value"))))))
(DTypeSig false "inferParamRowAtoms" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "inferParamRowAtoms" ((PVar "gctx") (PVar "params") (PVar "variants")) (EBlock (DoLet false false (PVar "fieldTys") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "v")) (EApp (EVar "payloadAstTypes") (EApp (EVar "variantPayload") (EVar "v"))))) (EVar "variants"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "intersectDeclAtoms") (EVar "gctx")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "t")))) (EVar "fieldTys"))))) (EVar "params")))))
(DTypeSig false "paramRowAtomOccs" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyVar" (PVar "n"))) (EIf (EBinOp "==" (EVar "n") (EVar "p")) (EListLit (EListLit)) (EListLit)))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") PWild (PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyEffect" (PVar "labels") (PVar "tails") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "paramRowAtomsFor") (EVar "gctx")) (EVar "p")) (EVar "tails")) (EVar "labels")) (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "t"))))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyRow" (PVar "labels") (PVar "tails") PWild)) (EApp (EApp (EApp (EApp (EVar "paramRowAtomsFor") (EVar "gctx")) (EVar "p")) (EVar "tails")) (EVar "labels")))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "a")) (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "b"))))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p"))) (EVar "ts")))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "a")) (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "b"))))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") (PVar "p") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "paramRowAtomOccs") (EVar "gctx")) (EVar "p")) (EVar "t")))
(DFunDef false "paramRowAtomOccs" ((PVar "gctx") PWild PWild) (EListLit))
(DTypeSig false "paramRowAtomsFor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))))))))
(DFunDef false "paramRowAtomsFor" ((PVar "gctx") (PVar "p") (PVar "tails") (PVar "labels")) (EApp (EApp (EMethodRef "map") (ELam (PWild) (EApp (EApp (EVar "atomsOfWritten") (EVar "gctx")) (EVar "labels")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "p")))) (EVar "tails"))))
(DTypeSig false "intersectDeclAtoms" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "intersectDeclAtoms" ((PVar "gctx") (PList)) (EListLit))
(DFunDef false "intersectDeclAtoms" ((PVar "gctx") (PCons (PVar "first") (PVar "rest"))) (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EApp (EApp (EVar "allList") (ELam ((PVar "b")) (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EVar "atomsEscape") (EVar "gctx")) (EListLit (EVar "x"))) (EVar "b"))))) (EVar "rest")))) (EVar "first")))
(DTypeSig false "mintParamReprs" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "mintParamReprs" ((PVar "mctx") (PCons PWild (PVar "ps")) (PCons (PCon "KType") (PVar "ks"))) (EBinOp "::" (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)) (EApp (EApp (EApp (EVar "mintParamReprs") (EVar "mctx")) (EVar "ps")) (EVar "ks"))))
(DFunDef false "mintParamReprs" ((PVar "mctx") (PCons PWild (PVar "ps")) (PCons (PCon "KRow") (PVar "ks"))) (EBinOp "::" (EApp (EVar "TEff") (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EApp (EApp (EVar "freshEffvar") (EVar "mctx")) (ELit LUnit))))) (EApp (EApp (EApp (EVar "mintParamReprs") (EVar "mctx")) (EVar "ps")) (EVar "ks"))))
(DFunDef false "mintParamReprs" ((PVar "mctx") (PCons (PVar "p") (PVar "ps")) (PCons (PCon "KAuth" (PVar "l") (PVar "pat")) (PVar "ks"))) (EBinOp "::" (EApp (EVar "TAuth") (EApp (EVar "AVar") (EApp (EApp (EApp (EApp (EVar "freshAuthvarRanged") (EVar "mctx")) (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "l"))) (EVar "pat")) (EApp (EVar "Some") (EVar "p"))))) (EApp (EApp (EApp (EVar "mintParamReprs") (EVar "mctx")) (EVar "ps")) (EVar "ks"))))
(DFunDef false "mintParamReprs" ((PVar "mctx") PWild PWild) (EListLit))
(DTypeSig false "ktypeTvs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "ktypeTvs" ((PCons (PVar "p") (PVar "ps")) (PCons (PCon "KType") (PVar "ks")) (PCons (PVar "r") (PVar "rs"))) (EBinOp "::" (ETuple (EVar "p") (EVar "r")) (EApp (EApp (EApp (EVar "ktypeTvs") (EVar "ps")) (EVar "ks")) (EVar "rs"))))
(DFunDef false "ktypeTvs" ((PCons (PVar "p") (PVar "ps")) (PCons PWild (PVar "ks")) (PCons PWild (PVar "rs"))) (EApp (EApp (EApp (EVar "ktypeTvs") (EVar "ps")) (EVar "ks")) (EVar "rs")))
(DFunDef false "ktypeTvs" (PWild PWild PWild) (EListLit))
(DTypeSig false "paramEtbl" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "SigVars")))))
(DFunDef false "paramEtbl" ((PVar "params") (PVar "kinds") (PVar "reprs")) (ERecordCreate "SigVars" ((fa "svRows" (EApp (EApp (EApp (EVar "krowRows") (EVar "params")) (EVar "kinds")) (EVar "reprs"))) (fa "svAuths" (EApp (EApp (EApp (EVar "kauthCells") (EVar "params")) (EVar "kinds")) (EVar "reprs"))))))
(DTypeSig false "kauthCells" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar"))))))))
(DFunDef false "kauthCells" ((PCons (PVar "p") (PVar "ps")) (PCons (PCon "KAuth" PWild PWild) (PVar "ks")) (PCons (PCon "TAuth" (PCon "AVar" (PVar "cell"))) (PVar "rs"))) (EBinOp "::" (ETuple (EVar "p") (EVar "cell")) (EApp (EApp (EApp (EVar "kauthCells") (EVar "ps")) (EVar "ks")) (EVar "rs"))))
(DFunDef false "kauthCells" ((PCons (PVar "p") (PVar "ps")) (PCons PWild (PVar "ks")) (PCons PWild (PVar "rs"))) (EApp (EApp (EApp (EVar "kauthCells") (EVar "ps")) (EVar "ks")) (EVar "rs")))
(DFunDef false "kauthCells" (PWild PWild PWild) (EListLit))
(DTypeSig false "existentialCells" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "existentialCells" ((PVar "mctx") (PVar "binders")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EMatch (EApp (EVar "snd") (EVar "b")) (arm (PCon "KindAuthority" (PVar "l") (PVar "o") (PVar "pat") PWild) () (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EApp (EApp (EApp (EVar "freshAuthvarRanged") (EVar "mctx")) (EApp (EApp (EVar "dtopFor") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o")))) (EApp (EApp (EApp (EVar "rangedOver") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "EffLabel") (EVar "l")) (EVar "o"))) (EVar "pat"))) (EApp (EVar "Some") (EApp (EVar "fst") (EVar "b")))))) (arm PWild () (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EApp (EApp (EVar "freshAuthvar") (EVar "mctx")) (EVar "PUnit")) (EApp (EVar "Some") (EApp (EVar "fst") (EVar "b"))))))))) (EVar "binders")))
(DTypeSig false "recordExistentials" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar")))) (TyCon "Unit"))))
(DFunDef false "recordExistentials" ((PVar "gctx") (PList)) (ELit LUnit))
(DFunDef false "recordExistentials" ((PVar "gctx") (PVar "cells")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "anyExistentialsRef")) (EVar "True"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "ctorExistentialsRef")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "c")) (EApp (EApp (EApp (EVar "IdMap.set") (EApp (EVar "authvarId") (EApp (EVar "snd") (EVar "c")))) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "graphRun") "ctorExistentialsRef") "value")) (EVar "cells"))))))
(DTypeSig false "padCtorBinders" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))))))
(DFunDef false "padCtorBinders" ((PList) PWild) (EListLit))
(DFunDef false "padCtorBinders" ((PCons PWild (PVar "vs")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "::" (EVar "b") (EApp (EApp (EVar "padCtorBinders") (EVar "vs")) (EVar "bs"))))
(DFunDef false "padCtorBinders" ((PCons PWild (PVar "vs")) (PList)) (EBinOp "::" (EListLit) (EApp (EApp (EVar "padCtorBinders") (EVar "vs")) (EListLit))))
(DTypeSig false "krowRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Effvar"))))))))
(DFunDef false "krowRows" ((PCons (PVar "p") (PVar "ps")) (PCons (PCon "KRow") (PVar "ks")) (PCons (PCon "TEff" (PCon "EffRow" PWild (PCon "Some" (PVar "cell")))) (PVar "rs"))) (EBinOp "::" (ETuple (EVar "p") (EVar "cell")) (EApp (EApp (EApp (EVar "krowRows") (EVar "ps")) (EVar "ks")) (EVar "rs"))))
(DFunDef false "krowRows" ((PCons (PVar "p") (PVar "ps")) (PCons PWild (PVar "ks")) (PCons PWild (PVar "rs"))) (EApp (EApp (EApp (EVar "krowRows") (EVar "ps")) (EVar "ks")) (EVar "rs")))
(DFunDef false "krowRows" (PWild PWild PWild) (EListLit))
(DTypeSig false "registerNamedFieldVariants" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))) (TyCon "Unit")))))))))
(DFunDef false "registerNamedFieldVariants" ((PVar "mctx") (PVar "o") (PVar "tyName") (PVar "params") (PVar "kinds") (PVar "variants") (PVar "binders")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerNamedFieldVariantsGo") (EVar "mctx")) (EVar "o")) (EVar "tyName")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EApp (EApp (EVar "padCtorBinders") (EVar "variants")) (EVar "binders"))))
(DTypeSig false "registerNamedFieldVariantsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))) (TyCon "Unit")))))))))
(DFunDef false "registerNamedFieldVariantsGo" ((PVar "mctx") (PVar "o") (PVar "tyName") (PVar "params") (PVar "kinds") (PCons (PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fields") PWild)) (PVar "rest")) (PCons (PVar "bs") (PVar "brest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerRecordInfoKeyed") (EVar "mctx")) (EVar "o")) (EVar "cname")) (EVar "tyName")) (EVar "params")) (EVar "kinds")) (EVar "bs")) (EVar "fields"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerNamedFieldVariantsGo") (EVar "mctx")) (EVar "o")) (EVar "tyName")) (EVar "params")) (EVar "kinds")) (EVar "rest")) (EVar "brest")))))
(DFunDef false "registerNamedFieldVariantsGo" ((PVar "mctx") (PVar "o") (PVar "tyName") (PVar "params") (PVar "kinds") (PCons PWild (PVar "rest")) (PCons PWild (PVar "brest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "registerNamedFieldVariantsGo") (EVar "mctx")) (EVar "o")) (EVar "tyName")) (EVar "params")) (EVar "kinds")) (EVar "rest")) (EVar "brest")))
(DFunDef false "registerNamedFieldVariantsGo" ((PVar "mctx") PWild PWild PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "addVariants" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyCon "SigVars") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn")))) (TyCon "TcEnv")))))))))))
(DFunDef false "addVariants" ((PVar "env") (PVar "tvs") (PVar "etbl") (PVar "paramTyIds") (PVar "rowEffvarIds") (PVar "authvarIds") (PVar "result") (PCons (PCon "Variant" (PVar "cname") (PVar "payload")) (PVar "rest")) (PCons (PVar "binders") (PVar "brest"))) (EBlock (DoLet false false (PVar "opened") (EApp (EApp (EVar "existentialCells") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "binders"))) (DoExpr (EApp (EApp (EVar "recordExistentials") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "opened"))) (DoLet false false (PVar "ctorEtbl") (EApp (EApp (EVar "sigVarsWithAuths") (EVar "opened")) (EVar "etbl"))) (DoExpr (EApp (EApp (EApp (EVar "reportUnboundAuthorityNamesIn") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EApp (EVar "payloadAstTypes") (EVar "payload"))) (EVar "ctorEtbl"))) (DoLet false false (PVar "ctorType") (EApp (EApp (EVar "foldrFun") (EApp (EApp (EApp (EApp (EVar "payloadTypesE") (EApp (EApp (EVar "mctxAtIfSome") (EApp (EVar "firstTyLocList") (EApp (EVar "payloadAstTypes") (EVar "payload")))) (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule"))) (EVar "ctorEtbl")) (EVar "tvs")) (EVar "payload"))) (EVar "result"))) (DoLet false false (PVar "env2") (EApp (EApp (EApp (EVar "addCtor") (EVar "env")) (EVar "cname")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EVar "paramTyIds")) (EVar "rowEffvarIds")) (EBinOp "++" (EVar "authvarIds") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EApp (EVar "authvarId") (EApp (EVar "snd") (EVar "c"))))) (EVar "opened")))) (EListLit)) (EVar "pureRow")) (EVar "ctorType")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "addVariants") (EVar "env2")) (EVar "tvs")) (EVar "etbl")) (EVar "paramTyIds")) (EVar "rowEffvarIds")) (EVar "authvarIds")) (EVar "result")) (EVar "rest")) (EVar "brest")))))
(DFunDef false "addVariants" ((PVar "env") PWild PWild PWild PWild PWild PWild PWild PWild) (EVar "env"))
(DTypeSig true "constraintIsMethodLevel" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Constraint") (TyCon "Bool"))))
(DFunDef false "constraintIsMethodLevel" ((PVar "typarams") (PVar "c")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "constraintSlotDispatchVar") (EVar "typarams")) (EVar "c"))))
(DTypeSig true "methodDictArityOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "methodDictArityOf" ((PVar "mctx") (PVar "key")) (EApp (EVar "listLen") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "lookupAssoc") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value")))))
(DTypeSig true "constraintIface" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "constraintIface" ((PRec "Constraint" ((rf "constraintHead" (PVar "n"))) false)) (EVar "n"))
(DTypeSig true "constraintVarNames" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constraintVarNames" ((PRec "Constraint" ((rf "constraintArgs" (PVar "args"))) false)) (EApp (EApp (EDictApp "flatMap") (EVar "tyVarNames")) (EVar "args")))
(DTypeSig false "tyAliasNormalForm" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyCon "Ty") (TyCon "Ty")))))
(DFunDef false "tyAliasNormalForm" ((PVar "aliases") (PVar "seen") (PVar "ty")) (EMatch (EApp (EApp (EVar "aliasExpansionStep") (EVar "aliases")) (EVar "ty")) (arm (PCon "Some" (PTuple (PVar "key") (PVar "rhs"))) ((GBool (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "k")) (EApp (EApp (EVar "tabKeyEq") (EVar "k")) (EVar "key")))) (EVar "seen"))))) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EBinOp "::" (EVar "key") (EVar "seen"))) (EApp (EApp (EVar "locateTyAt") (EApp (EVar "firstTyLoc") (EVar "ty"))) (EVar "rhs")))) (arm PWild () (EApp (EApp (EApp (EVar "tyAliasNormalFormKids") (EVar "aliases")) (EVar "seen")) (EVar "ty")))))
(DTypeSig false "tyAliasNormalFormKids" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyCon "Ty") (TyCon "Ty")))))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyApp" (PVar "a") (PVar "b"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))) (arm (PTuple (PAs "h" (PRec "TyCon" ((rf "tyConName" PWild)) false)) (PVar "args")) () (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "arg")) (EApp (EApp (EVar "TyApp") (EVar "acc")) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "arg"))))) (EVar "h")) (EVar "args"))) (arm PWild () (EApp (EApp (EVar "TyApp") (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "a"))) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "b"))))))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "a"))) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "b"))))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "TyTuple") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen"))) (EVar "ts"))))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyEffect" (PVar "es") (PVar "tails") (PVar "t"))) (EApp (EApp (EApp (EVar "TyEffect") (EVar "es")) (EVar "tails")) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "t"))))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyNamed" (PVar "n") (PVar "t") (PVar "d"))) (EApp (EApp (EApp (EVar "TyNamed") (EVar "n")) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "t"))) (EVar "d")))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyQual" (PVar "t") (PVar "ps") (PVar "l"))) (EApp (EApp (EApp (EVar "TyQual") (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "t"))) (EVar "ps")) (EVar "l")))
(DFunDef false "tyAliasNormalFormKids" ((PVar "aliases") (PVar "seen") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EApp (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EVar "seen")) (EVar "t"))))
(DFunDef false "tyAliasNormalFormKids" (PWild PWild (PVar "t")) (EVar "t"))
(DTypeSig false "aliasExpansionStep" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "TabKey") (TyCon "Ty"))))))
(DFunDef false "aliasExpansionStep" ((PVar "aliases") (PVar "ty")) (EMatch (EApp (EVar "tyAppSpine") (EVar "ty")) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false) (PVar "args")) () (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupTab") (EVar "key")) (EVar "aliases")) (arm (PCon "Some" (PTuple (PVar "params") (PVar "rhs"))) ((GBool (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (ETuple (EVar "key") (EApp (EApp (EVar "substAliasArgs") (EApp (EApp (EVar "zipL") (EVar "params")) (EVar "args"))) (EVar "rhs"))))) (arm PWild () (EVar "None")))))) (arm PWild () (EVar "None"))))
(DTypeSig false "locateTyAt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "locateTyAt" ((PCon "None") (PVar "ty")) (EVar "ty"))
(DFunDef false "locateTyAt" ((PVar "loc") (PVar "ty")) (EApp (EVar "fst") (EApp (EApp (EVar "mapTyFull") (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PRec "TyCon" ((rf "tyConLoc" (PCon "None"))) false) () (ETuple (EVariantUpdate "TyCon" (EVar "t") ((fa "tyConLoc" (EVar "loc")))) (EVar "True"))) (arm PWild () (ETuple (EVar "t") (EVar "False")))))) (EVar "ty"))))
(DTypeSig true "ifaceMethodSchemeRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "MethodSchemeRow")))))
(DFunDef false "ifaceMethodSchemeRows" ((PVar "mctx") (PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "directIfaceSchemeRows") (EVar "mctx"))) (EApp (EVar "directInterfaceDecls") (EVar "decls"))))
(DTypeSig false "directInterfaceDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "directInterfaceDecls" ((PVar "decls")) (EApp (EApp (EVar "filterList") (EVar "isDirectInterfaceDecl")) (EVar "decls")))
(DTypeSig false "isDirectInterfaceDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isDirectInterfaceDecl" ((PRec "DInterface" () false)) (EVar "True"))
(DFunDef false "isDirectInterfaceDecl" (PWild) (EVar "False"))
(DTypeSig false "directIfaceSchemeRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "MethodSchemeRow")))))
(DFunDef false "directIfaceSchemeRows" ((PVar "mctx") (PRec "DInterface" ((rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "methods" None) (rf "ifaceOrigin" None)) true)) (EApp (EApp (EApp (EApp (EApp (EVar "methodSchemeRows") (EVar "mctx")) (EApp (EApp (EApp (EApp (EVar "declGradedScope") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "typarams")) (EVar "typaramKinds")) (EVar "methods"))) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "ifaceOrigin"))))) (EVar "typarams")) (EVar "methods")))
(DFunDef false "directIfaceSchemeRows" ((PVar "mctx") PWild) (EListLit))
(DTypeSig false "methodSchemeRows" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "MethodSchemeRow"))))))))
(DFunDef false "methodSchemeRows" ((PVar "mctx") PWild PWild PWild (PList)) (EListLit))
(DFunDef false "methodSchemeRows" ((PVar "mctx") (PVar "scope") (PVar "iface") (PVar "typarams") (PCons (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "scheme") (PVar "tvs")) (EApp (EApp (EApp (EVar "sigToSchemeTvsIn") (EVar "mctx")) (EVar "scope")) (EVar "mty"))) (DoLet false false (PVar "slots") (EApp (EApp (EApp (EApp (EApp (EVar "methodPredicateSlotsOfType") (EVar "mctx")) (EVar "typarams")) (EVar "mty")) (EVar "tvs")) (EApp (EVar "schemeIds") (EVar "scheme")))) (DoExpr (EApp (EApp (EApp (EVar "installMethodPredicateSlots") (EVar "mctx")) (EApp (EApp (EVar "methodSlotKey") (EVar "iface")) (EVar "mname"))) (EVar "slots"))) (DoExpr (EBinOp "::" (ERecordCreate "MethodSchemeRow" ((fa "msrIface" (EVar "iface")) (fa "msrName" (EVar "mname")) (fa "msrTyparams" (EVar "typarams")) (fa "msrType" (EVar "mty")) (fa "msrScheme" (EVar "scheme")) (fa "msrPredicateTemplate" (ERecordCreate "MethodPredicateTemplate" ((fa "mptInterface" (EVar "iface")) (fa "mptArguments" (EApp (EApp (EVar "methodInterfacePredicateTemplate") (EVar "typarams")) (EVar "tvs")))))) (fa "msrMethodSlots" (EVar "slots")))) (EApp (EApp (EApp (EApp (EApp (EVar "methodSchemeRows") (EVar "mctx")) (EVar "scope")) (EVar "iface")) (EVar "typarams")) (EVar "rest"))))))
(DTypeSig false "methodInterfacePredicateTemplate" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Mono"))))))
(DFunDef false "methodInterfacePredicateTemplate" ((PList) PWild) (EListLit))
(DFunDef false "methodInterfacePredicateTemplate" ((PCons (PVar "param") (PVar "rest")) (PVar "tvs")) (EBinOp "::" (EApp (EApp (EVar "lookupAssoc") (EVar "param")) (EVar "tvs")) (EApp (EApp (EVar "methodInterfacePredicateTemplate") (EVar "rest")) (EVar "tvs"))))
(DTypeSig true "seedNumLitFromIntAnchor" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyCon "Unit"))))
(DFunDef false "seedNumLitFromIntAnchor" ((PVar "mctx") (PVar "rows")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numLitFromIntAnchorRef")) (EApp (EApp (EApp (EVar "pickNumLitRow") (EApp (EApp (EVar "builtinIfaceRef") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "BNum"))) (ELit (LString "fromInt"))) (EVar "rows"))))
(DTypeSig false "pickNumLitRow" (TyFun (TyCon "IfaceRef") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodSchemeRow")) (TyApp (TyCon "Option") (TyCon "MethodSchemeRow"))))))
(DFunDef false "pickNumLitRow" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "pickNumLitRow" ((PVar "iface") (PVar "mname") (PCons (PVar "row") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "row") "msrName") (EVar "mname")) (EApp (EApp (EVar "sameIfaceDecl") (EFieldAccess (EVar "row") "msrIface")) (EVar "iface"))) (EApp (EVar "Some") (EVar "row")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "pickNumLitRow") (EVar "iface")) (EVar "mname")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "methodSchemesPure" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))
(DFunDef false "methodSchemesPure" ((PVar "mctx") PWild (PList)) (EListLit))
(DFunDef false "methodSchemesPure" ((PVar "mctx") (PVar "scope") (PCons (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "mname") (EApp (EVar "fst") (EApp (EApp (EApp (EVar "sigToSchemeTvsIn") (EVar "mctx")) (EVar "scope")) (EVar "mty")))) (EApp (EApp (EApp (EVar "methodSchemesPure") (EVar "mctx")) (EVar "scope")) (EVar "rest"))))
(DTypeSig false "installMethodPredicateSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyCon "Unit")))))
(DFunDef false "installMethodPredicateSlots" ((PVar "mctx") (PVar "key") (PVar "slots")) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "slots")) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value")))) (ELit LUnit) (EApp (EApp (EApp (EVar "setMethodPredicateSlotEntry") (EVar "mctx")) (EVar "key")) (EVar "slots"))))
(DTypeSig false "setMethodPredicateSlotEntry" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodPredicateSlot")) (TyCon "Unit")))))
(DFunDef false "setMethodPredicateSlotEntry" ((PVar "mctx") (PVar "key") (PVar "slots")) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef")) (EBinOp "::" (ETuple (EVar "key") (EVar "slots")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodPredicateSlotsRef") "value"))))
(DTypeSig false "methodPredicateSlotsOfType" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))))))
(DFunDef false "methodPredicateSlotsOfType" ((PVar "mctx") (PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t")) (PVar "tvs") (PVar "fullIds")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EVar "constraintMethodPredicateSlot") (EVar "mctx")) (EVar "typarams")) (EVar "tvs")) (EVar "fullIds"))) (EVar "cs")) (EApp (EApp (EApp (EApp (EApp (EVar "methodPredicateSlotsOfType") (EVar "mctx")) (EVar "typarams")) (EVar "t")) (EVar "tvs")) (EVar "fullIds"))))
(DFunDef false "methodPredicateSlotsOfType" ((PVar "mctx") (PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t")) (PVar "tvs") (PVar "fullIds")) (EApp (EApp (EApp (EApp (EApp (EVar "methodPredicateSlotsOfType") (EVar "mctx")) (EVar "typarams")) (EVar "t")) (EVar "tvs")) (EVar "fullIds")))
(DFunDef false "methodPredicateSlotsOfType" ((PVar "mctx") PWild PWild PWild PWild) (EListLit))
(DTypeSig false "constraintMethodPredicateSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))))))
(DFunDef false "constraintMethodPredicateSlot" ((PVar "mctx") (PVar "typarams") (PVar "tvs") (PVar "fullIds") (PVar "c")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "constraintIsMethodLevel") (EVar "typarams")) (EVar "c"))) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "bound") (EApp (EApp (EVar "constraintNameMonos") (EApp (EVar "constraintVarNames") (EVar "c"))) (EVar "tvs"))) (DoLet false false (PVar "ids") (EApp (EApp (EMethodRef "map") (EVar "monoTyvarId")) (EVar "bound"))) (DoExpr (EListLit (ERecordCreate "MethodPredicateSlot" ((fa "mpsPredicate" (ERecordCreate "PredicateSlot" ((fa "psIface" (ERecordCreate "IfaceRef" ((fa "irName" (EApp (EVar "constraintIface") (EVar "c"))) (fa "irOrigin" (EFieldAccess (EVar "c") "constraintOrigin"))))) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "fromAstType") (EVar "mctx")) (EVar "tvs"))) (EFieldAccess (EVar "c") "constraintArgs")))) (fa "psBoundIds" (EVar "ids"))))) (fa "mpsPositions" (EApp (EApp (EMethodRef "map") (ELam ((PVar "id")) (EApp (EApp (EVar "optionOr") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EVar "elemIndex") (EVar "id")) (EVar "fullIds"))))) (EVar "ids")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "registerAllData" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "TcEnv"))))
(DFunDef false "registerAllData" ((PVar "env") (PVar "ds")) (EApp (EApp (EApp (EVar "registerAllDataScoped") (EVar "env")) (EVar "ds")) (EVar "ds")))
(DTypeSig true "registerAllDataScoped" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "TcEnv")))))
(DFunDef false "registerAllDataScoped" ((PVar "env") (PVar "ds") (PVar "allDs")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "seedParamPolarityFixpointScoped") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ds")) (EVar "allDs"))) (DoExpr (EApp (EApp (EVar "registerAllDataGo") (EVar "env")) (EVar "ds")))))
(DTypeSig false "registerAllDataGo" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "TcEnv"))))
(DFunDef false "registerAllDataGo" ((PVar "env") (PVar "ds")) (EBlock (DoExpr (EApp (EApp (EVar "each") (EApp (EVar "recordDeclKinds") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule"))) (EVar "ds"))) (DoExpr (EApp (EApp (EVar "registerDeclsAliasesFirst") (EVar "env")) (EVar "ds")))))
(DTypeSig false "registerDeclsAliasesFirst" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "TcEnv"))))
(DFunDef false "registerDeclsAliasesFirst" ((PVar "env") (PVar "ds")) (EBlock (DoLet false false (PVar "env1") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "e") (PVar "d")) (EIf (EApp (EVar "isAliasDecl") (EVar "d")) (EApp (EApp (EVar "registerData") (EVar "e")) (EVar "d")) (EVar "e")))) (EVar "env")) (EVar "ds"))) (DoExpr (EApp (EApp (EVar "rejectCyclicAliases") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "ds"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "e") (PVar "d")) (EIf (EApp (EVar "isAliasDecl") (EVar "d")) (EVar "e") (EApp (EApp (EVar "registerData") (EVar "e")) (EVar "d"))))) (EVar "env1")) (EVar "ds")))))
(DTypeSig true "isAliasDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isAliasDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isAliasDecl") (EVar "d")))
(DFunDef false "isAliasDecl" ((PRec "DTypeAlias" () true)) (EVar "True"))
(DFunDef false "isAliasDecl" (PWild) (EVar "False"))
(DTypeSig true "recordDeclKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "recordDeclKinds" ((PVar "mctx") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "recordDeclKinds") (EVar "mctx")) (EVar "d")))
(DFunDef false "recordDeclKinds" ((PVar "mctx") (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "name")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "anns")) (rf "dataCtors" (PVar "variants")) (rf "dataOrigin" (PVar "o"))) false)) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordCtors") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o")) (EVar "name")) (EVar "vis")) (EVar "params")) (EVar "variants"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordParamKinds") (EVar "mctx")) (EVar "o")) (EVar "name")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "params")) (EVar "anns"))))))
(DFunDef false "recordDeclKinds" ((PVar "mctx") (PRec "DNewtype" ((rf "newtypePub" (PVar "pub")) (rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "params")) (rf "newtypeParamKinds" (PVar "anns")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeOrigin" (PVar "o"))) false)) (EBlock (DoLet false false (PVar "vis") (EIf (EVar "pub") (EVar "VisPublic") (EVar "VisAbstract"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "recordCtors") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "o")) (EVar "name")) (EVar "vis")) (EVar "params")) (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty"))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "recordParamKinds") (EVar "mctx")) (EVar "o")) (EVar "name")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "params")) (EVar "anns"))))))
(DFunDef false "recordDeclKinds" ((PVar "mctx") (PVar "d")) (EApp (EApp (EVar "recordDeclParamKinds") (EVar "mctx")) (EVar "d")))
(DTypeSig false "recordDeclParamKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "recordDeclParamKinds" ((PVar "mctx") (PVar "d")) (EMatch (EApp (EApp (EVar "declKindEntry") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "d")) (arm (PCon "Some" (PTuple (PVar "o") (PVar "name") (PVar "kinds"))) () (EApp (EApp (EApp (EApp (EVar "recordParamKinds") (EVar "mctx")) (EVar "o")) (EVar "name")) (EVar "kinds"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "declKindEntry" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "TyConOrigin") (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))))
(DFunDef false "declKindEntry" ((PVar "gctx") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declKindEntry") (EVar "gctx")) (EVar "d")))
(DFunDef false "declKindEntry" ((PVar "gctx") (PRec "DData" ((rf "dataName" (PVar "name")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "anns")) (rf "dataOrigin" (PVar "o"))) false)) (EApp (EVar "Some") (ETuple (EVar "o") (EVar "name") (EApp (EApp (EApp (EVar "declParamKinds") (EVar "gctx")) (EVar "params")) (EVar "anns")))))
(DFunDef false "declKindEntry" ((PVar "gctx") (PRec "DNewtype" ((rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "params")) (rf "newtypeParamKinds" (PVar "anns")) (rf "newtypeOrigin" (PVar "o"))) false)) (EApp (EVar "Some") (ETuple (EVar "o") (EVar "name") (EApp (EApp (EApp (EVar "declParamKinds") (EVar "gctx")) (EVar "params")) (EVar "anns")))))
(DFunDef false "declKindEntry" ((PVar "gctx") (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "name")) (rf "tyAliasParams" (PVar "params")) (rf "tyAliasParamKinds" (PVar "anns")) (rf "tyAliasOrigin" (PVar "o"))) false)) (EApp (EVar "Some") (ETuple (EVar "o") (EVar "name") (EApp (EApp (EApp (EVar "declParamKinds") (EVar "gctx")) (EVar "params")) (EVar "anns")))))
(DFunDef false "declKindEntry" ((PVar "gctx") PWild) (EVar "None"))
(DTypeSig true "withDeclParamKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyVar "a")))))
(DFunDef false "withDeclParamKinds" ((PVar "mctx") (PVar "ds") (PVar "k")) (EBlock (DoLet false false (PVar "kinds") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef") "value")) (DoLet false false (PVar "names") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamNameIndexRef") "value")) (DoExpr (EApp (EApp (EVar "each") (EApp (EVar "recordDeclaredKinds") (EVar "mctx"))) (EVar "ds"))) (DoLet false false (PVar "result") (EApp (EVar "k") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamKindsRef")) (EVar "kinds"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamNameIndexRef")) (EVar "names"))) (DoExpr (EVar "result"))))
(DTypeSig false "recordDeclaredKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "recordDeclaredKinds" ((PVar "mctx") (PVar "d")) (EMatch (EApp (EApp (EVar "declKindEntry") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "d")) (arm (PCon "Some" (PTuple (PVar "o") (PVar "name") (PVar "kinds"))) ((GBool (EApp (EApp (EVar "anyList") (EVar "kindIsDeclared")) (EVar "kinds")))) (EApp (EApp (EApp (EApp (EVar "recordParamKinds") (EVar "mctx")) (EVar "o")) (EVar "name")) (EVar "kinds"))) (arm PWild () (ELit LUnit))))
(DTypeSig true "kindIsDeclared" (TyFun (TyCon "Kind") (TyCon "Bool")))
(DFunDef false "kindIsDeclared" ((PCon "KType")) (EVar "False"))
(DFunDef false "kindIsDeclared" (PWild) (EVar "True"))
(DTypeSig true "instantiateSigTracked" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "Option") (TyCon "EffRow"))))))
(DFunDef false "instantiateSigTracked" ((PVar "outer") (PVar "ty")) (EApp (EApp (EApp (EVar "atSignature") (EVar "outer")) (EVar "ty")) (ELam ((PVar "mctx")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "rowArgNames") (EVar "mctx")) (EVar "ty"))) (DoLet false false (PVar "auths") (EApp (EApp (EVar "authArgBindersIn") (EVar "mctx")) (EVar "ty"))) (DoLet false false (PVar "tvs") (EApp (EApp (EVar "freshTvMap") (EVar "mctx")) (EApp (EApp (EApp (EVar "sigTyVarNames") (EVar "ty")) (EVar "rows")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "auths"))))) (DoLet false false (PVar "etbl") (EApp (EApp (EApp (EApp (EVar "sigVarsForWith") (EVar "mctx")) (EVar "ty")) (EApp (EVar "dedup") (EBinOp "++" (EApp (EVar "effTailNames") (EVar "ty")) (EVar "rows")))) (EVar "auths"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EVar "fromAstTypeE") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty")) (EVar "tvs") (EApp (EApp (EApp (EApp (EVar "writtenBindingForce") (EVar "mctx")) (EVar "etbl")) (EVar "tvs")) (EVar "ty"))))))))
(DTypeSig true "constraintNameMonos" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "constraintNameMonos" ((PList) PWild) (EListLit))
(DFunDef false "constraintNameMonos" ((PCons (PVar "n") (PVar "rest")) (PVar "tvMap")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "tvMap")) (arm (PCon "Some" (PVar "mono")) () (EBinOp "::" (EVar "mono") (EApp (EApp (EVar "constraintNameMonos") (EVar "rest")) (EVar "tvMap")))) (arm (PCon "None") () (EApp (EApp (EVar "constraintNameMonos") (EVar "rest")) (EVar "tvMap")))))
(DTypeSig true "loadDataUniverse" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "loadDataUniverse" ((PVar "mctx") (PVar "cur")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef")) (EApp (EVar "spFloor") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeRecordPop") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef")) (EApp (EApp (EVar "aliasUniverseAt") (EVar "cur")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deData") "deAliases"))))))
(DTypeSig false "ctorExportsInto" (TyFun (TyCon "DeclEnvModule") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))))
(DFunDef false "ctorExportsInto" ((PVar "m") (PVar "acc")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EBinOp "++" (EApp (EVar "declCtorIdents") (EFieldAccess (EVar "m") "demDecls")) (EApp (EApp (EVar "reexportedCtorIdents") (EVar "acc")) (EFieldAccess (EVar "m") "demDecls")))) (EVar "acc")))
(DTypeSig false "declCtorIdents" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))
(DFunDef false "declCtorIdents" ((PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EVar "declCtorIdentsOf")) (EVar "decls")))
(DTypeSig false "declCtorIdentsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))
(DFunDef false "declCtorIdentsOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declCtorIdentsOf") (EVar "d")))
(DFunDef false "declCtorIdentsOf" ((PRec "DData" ((rf "dataName" None) (rf "dataCtors" None) (rf "dataOrigin" None)) true)) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "v")) (EApp (EApp (EApp (EVar "variantIdentRow") (EVar "dataName")) (EVar "dataOrigin")) (EVar "v")))) (EVar "dataCtors")))
(DFunDef false "declCtorIdentsOf" ((PRec "DNewtype" ((rf "newtypeName" None) (rf "newtypeCtor" None) (rf "newtypeOrigin" None)) true)) (EApp (EApp (EApp (EVar "ctorIdentRow") (EVar "newtypeName")) (EVar "newtypeOrigin")) (EVar "newtypeCtor")))
(DFunDef false "declCtorIdentsOf" (PWild) (EListLit))
(DTypeSig false "variantIdentRow" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))))
(DFunDef false "variantIdentRow" ((PVar "tyName") (PVar "o") (PCon "Variant" (PVar "cn") PWild)) (EApp (EApp (EApp (EVar "ctorIdentRow") (EVar "tyName")) (EVar "o")) (EVar "cn")))
(DTypeSig false "ctorIdentRow" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))))))
(DFunDef false "ctorIdentRow" ((PVar "tyName") (PVar "o") (PVar "cn")) (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsCtor")) (EVar "o")) (EVar "cn")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "i")) () (EListLit (ETuple (EVar "cn") (EVar "tyName") (EVar "i"))))))
(DTypeSig false "reexportedCtorIdents" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "reexportedCtorIdents" ((PVar "acc") (PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "reexportedCtorIdentsOf") (EVar "acc"))) (EVar "decls")))
(DTypeSig false "reexportedCtorIdentsOf" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "reexportedCtorIdentsOf" ((PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "reexportedCtorIdentsOf") (EVar "acc")) (EVar "d")))
(DFunDef false "reexportedCtorIdentsOf" ((PVar "acc") (PCon "DUse" (PCon "True") (PVar "path") PWild)) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "acc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EMatch (EVar "path") (arm (PCon "UseWild" PWild) () (EVar "src")) (arm (PCon "UseGroup" PWild (PVar "ms")) () (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EApp (EApp (EVar "reexportCtorMember") (EVar "m")) (EVar "src")))) (EVar "ms"))) (arm PWild () (EListLit))))))
(DFunDef false "reexportedCtorIdentsOf" (PWild PWild) (EListLit))
(DTypeSig false "reexportCtorMember" (TyFun (TyCon "UseMember") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident"))))))
(DFunDef false "reexportCtorMember" ((PVar "m") (PVar "src")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "rowBoundByMember") (EVar "m")) (EVar "r")))) (EVar "src")))
(DTypeSig false "rowBoundByMember" (TyFun (TyCon "UseMember") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident")) (TyCon "Bool"))))
(DFunDef false "rowBoundByMember" ((PVar "m") (PTuple (PVar "cn") (PVar "owner") PWild)) (EApp (EApp (EApp (EVar "memberBindsCtorName") (EVar "cn")) (EVar "owner")) (EVar "m")))
(DTypeSig true "graphAliasRow" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))))
(DFunDef false "graphAliasRow" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "graphAliasRow") (EVar "d")))
(DFunDef false "graphAliasRow" ((PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasRhs" (PVar "rhs")) (rf "tyAliasOrigin" (PVar "o"))) false)) (EListLit (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (ETuple (EVar "ps") (EVar "rhs")))))
(DFunDef false "graphAliasRow" (PWild) (EListLit))
(DTypeSig true "implHeadNormalDecl" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "implHeadNormalDecl" ((PVar "aliases") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "a")) (EApp (EApp (EVar "implHeadNormalDecl") (EVar "aliases")) (EVar "d"))))
(DFunDef false "implHeadNormalDecl" ((PVar "aliases") (PAs "d" (PRec "DImpl" ((rf "tys" (PVar "tys"))) false))) (EVariantUpdate "DImpl" (EVar "d") ((fa "tys" (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "tyAliasNormalForm") (EVar "aliases")) (EListLit))) (EVar "tys"))))))
(DFunDef false "implHeadNormalDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig true "declEnvModulesFrom" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "DeclEnvModule"))))))
(DFunDef false "declEnvModulesFrom" ((PVar "gctx") PWild (PList)) (EListLit))
(DFunDef false "declEnvModulesFrom" ((PVar "gctx") (PVar "k") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (EVar "k")) (EVar "mid")) (EVar "decls")) (EApp (EApp (EApp (EVar "declEnvModulesFrom") (EVar "gctx")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "declEnvOrdIndex" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "declEnvOrdIndex" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "declEnvOrdIndex" ((PVar "acc") (PCons (PVar "m") (PVar "rest"))) (EApp (EApp (EVar "declEnvOrdIndex") (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "m") "demOrd")) (EVar "acc"))) (EVar "rest")))
(DTypeSig false "declEnvReachIndex" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "declEnvReachIndex" ((PVar "mods")) (EApp (EApp (EApp (EVar "declEnvReachGo") (EApp (EApp (EVar "declEnvImportIndex") (EVar "mods")) (EVar "omEmpty"))) (EVar "mods")) (EVar "omEmpty")))
(DTypeSig false "declEnvImportIndex" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "declEnvImportIndex" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvImportIndex" ((PCons (PVar "m") (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "m") "demId")) (EVar "acc")) (EApp (EApp (EVar "declEnvImportIndex") (EVar "rest")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EVar "declEnvImportIndex") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EApp (EApp (EDictApp "flatMap") (EVar "useModuleId")) (EFieldAccess (EVar "m") "demDecls"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declEnvReachGo" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "declEnvReachGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "declEnvReachGo" ((PVar "edges") (PCons (PVar "m") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "declEnvReachGo") (EVar "edges")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EApp (EApp (EApp (EVar "declEnvReachFrom") (EVar "edges")) (EListLit (EFieldAccess (EVar "m") "demId"))) (EApp (EVar "declEnvReachSeed") (EFieldAccess (EVar "m") "demId")))) (EVar "acc"))))
(DTypeSig false "declEnvReachSeed" (TyFun (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "declEnvReachSeed" ((PVar "mid")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (ELit LUnit)) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString ""))) (ELit LUnit)) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "core"))) (ELit LUnit)) (EVar "omEmpty")))))
(DTypeSig false "declEnvDefinerIndex" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyTuple (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "declEnvDefinerIndex" ((PVar "acc") (PVar "amb") (PList)) (ETuple (EVar "acc") (EVar "amb")))
(DFunDef false "declEnvDefinerIndex" ((PVar "acc") (PVar "amb") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EApp (EVar "modulePubDefiners") (EVar "acc")) (EFieldAccess (EVar "m") "demId")) (EFieldAccess (EVar "m") "demDecls"))) (DoExpr (EApp (EApp (EApp (EVar "declEnvDefinerIndex") (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EApp (EApp (EVar "firstRowPerName") (EVar "omEmpty")) (EVar "rows"))) (EVar "acc"))) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "m") "demId")) (EApp (EApp (EVar "ambiguousExportRows") (EFieldAccess (EVar "m") "demId")) (EVar "rows"))) (EVar "amb"))) (EVar "rest")))))
(DTypeSig false "ambiguousExportRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ambiguousExportRows" ((PVar "mid") (PVar "rows")) (EBlock (DoLet false false (PVar "grouped") (EApp (EApp (EVar "groupDefinerPairs") (EVar "omEmpty")) (EVar "rows"))) (DoExpr (EApp (EApp (EApp (EVar "ambigRowsOf") (EVar "mid")) (EVar "grouped")) (EApp (EVar "omKeys") (EVar "grouped"))))))
(DTypeSig false "groupDefinerPairs" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "groupDefinerPairs" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "groupDefinerPairs" ((PVar "acc") (PCons (PTuple (PVar "n") (PVar "pair")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "acc")) (arm (PCon "None") () (EApp (EApp (EVar "groupDefinerPairs") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EListLit (EVar "pair"))) (EVar "acc"))) (EVar "rest"))) (arm (PCon "Some" (PVar "seen")) () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EApp (EVar "fst") (EVar "pair"))) (EBinOp "==" (EApp (EVar "snd") (EVar "p")) (EApp (EVar "snd") (EVar "pair")))))) (EVar "seen")) (EApp (EApp (EVar "groupDefinerPairs") (EVar "acc")) (EVar "rest")) (EApp (EApp (EVar "groupDefinerPairs") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "++" (EVar "seen") (EListLit (EVar "pair")))) (EVar "acc"))) (EVar "rest"))))))
(DTypeSig false "ambigRowsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ambigRowsOf" (PWild PWild (PList)) (EListLit))
(DFunDef false "ambigRowsOf" ((PVar "mid") (PVar "grouped") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false (PVar "pairs") (EApp (EApp (EVar "definerPairsOf") (EVar "n")) (EVar "grouped"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "pairs")) (ELit (LInt 2))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EVar "mid")))) (EVar "pairs")))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pairs"))) (EApp (EApp (EApp (EVar "ambigRowsOf") (EVar "mid")) (EVar "grouped")) (EVar "rest"))) (EApp (EApp (EApp (EVar "ambigRowsOf") (EVar "mid")) (EVar "grouped")) (EVar "rest"))))))
(DTypeSig false "definerPairsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "definerPairsOf" ((PVar "n") (PVar "grouped")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "grouped")) (arm (PCon "Some" (PVar "ps")) () (EVar "ps")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "firstRowPerName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "firstRowPerName" (PWild (PList)) (EListLit))
(DFunDef false "firstRowPerName" ((PVar "seen") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "seen")) (EApp (EApp (EVar "firstRowPerName") (EVar "seen")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "firstRowPerName") (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ELit LUnit)) (EVar "seen"))) (EVar "rest")))))
(DTypeSig false "modulePubDefiners" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "modulePubDefiners" ((PVar "before") (PVar "mid") (PVar "decls")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ETuple (EVar "mid") (EVar "n"))))) (EApp (EVar "pubTopFnNames") (EVar "decls"))) (EApp (EApp (EVar "reexportDefiners") (EVar "before")) (EVar "decls"))))
(DTypeSig false "reexportDefiners" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "reexportDefiners" (PWild (PList)) (EListLit))
(DFunDef false "reexportDefiners" ((PVar "before") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "reexportDefiners") (EVar "before")) (EListLit (EVar "d"))) (EApp (EApp (EVar "reexportDefiners") (EVar "before")) (EVar "rest"))))
(DFunDef false "reexportDefiners" ((PVar "before") (PCons (PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "depId") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "depId") (ELit (LString "core"))) (EApp (EApp (EVar "reexportDefiners") (EVar "before")) (EVar "rest")) (EBinOp "++" (EApp (EApp (EVar "importFormRows") (EVar "path")) (EApp (EApp (EVar "definersIn") (EVar "before")) (EVar "depId"))) (EApp (EApp (EVar "reexportDefiners") (EVar "before")) (EVar "rest")))))))
(DFunDef false "reexportDefiners" ((PVar "before") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "reexportDefiners") (EVar "before")) (EVar "rest")))
(DTypeSig true "pubTopFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubTopFnNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "fns") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "decls"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "fns")))) (EApp (EVar "publicStandaloneNames") (EVar "decls"))))))
(DTypeSig false "publicStandaloneNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "publicStandaloneNames" ((PList)) (EListLit))
(DFunDef false "publicStandaloneNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "publicStandaloneNames") (EListLit (EVar "d"))) (EApp (EVar "publicStandaloneNames") (EVar "rest"))))
(DFunDef false "publicStandaloneNames" ((PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "publicStandaloneNames") (EVar "rest"))))
(DFunDef false "publicStandaloneNames" ((PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "publicStandaloneNames") (EVar "rest"))))
(DFunDef false "publicStandaloneNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "publicStandaloneNames") (EVar "rest")))
(DTypeSig false "deKindAbstractFixture" (TyCon "Decl"))
(DFunDef false "deKindAbstractFixture" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisAbstract")) (fa "dataName" (ELit (LString "Opq"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "MkOpq"))) (EApp (EVar "ConPos") (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deKindPrivateFixture" (TyCon "Decl"))
(DFunDef false "deKindPrivateFixture" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPrivate")) (fa "dataName" (ELit (LString "Priv"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "MkPriv"))) (EApp (EVar "ConPos") (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deKindNewtypeFixture" (TyCon "Decl"))
(DFunDef false "deKindNewtypeFixture" () (ERecordCreate "DNewtype" ((fa "newtypePub" (EVar "True")) (fa "newtypeName" (ELit (LString "Wrap"))) (fa "newtypeParams" (EListLit)) (fa "newtypeParamKinds" (EListLit)) (fa "newtypeCtor" (ELit (LString "Wrap"))) (fa "newtypeFieldTy" (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (fa "newtypeCtorBinders" (EListLit)) (fa "newtypeDerives" (EListLit)) (fa "newtypeOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))) (fa "newtypeNameLoc" (EVar "None")))))
(DTypeSig false "deKindFixtureDecls" (TyApp (TyCon "List") (TyCon "Decl")))
(DFunDef false "deKindFixtureDecls" () (EListLit (EVar "deFieldOwnerFixtureA") (EVar "deKindAbstractFixture") (EVar "deKindPrivateFixture") (EVar "deKindNewtypeFixture")))
(DTypeSig false "deKindRow0" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deKindRow0" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "m"))) (EVar "deKindFixtureDecls")))
(DTypeSig false "deKindRow1" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deKindRow1" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "m"))) (EVar "deKindFixtureDecls")))
(DTypeSig false "deSeedRowN" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deSeedRowN" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "n"))) (EVar "deKindFixtureDecls")))
(DTypeSig false "deSeedChainProbeZero" (TyCon "DeclEnvSeedAcc"))
(DFunDef false "deSeedChainProbeZero" () (ERecordCreate "DeclEnvSeedAcc" ((fa "dsKAcc" (EListLit)) (fa "dsOAcc" (EVar "omEmpty")) (fa "dsNAcc" (EVar "omEmpty")) (fa "dsKinds" (EVar "omEmpty")) (fa "dsOwners" (EVar "omEmpty")) (fa "dsNames" (EVar "omEmpty")))))
(DTypeSig false "deSeedChainProbe" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvSeedAcc")))
(DFunDef false "deSeedChainProbe" ((PVar "gctx")) (EApp (EApp (EApp (EVar "declEnvSeedChain") (EVar "gctx")) (EListLit (EApp (EVar "deKindRow0") (EVar "gctx")) (EApp (EVar "deSeedRowN") (EVar "gctx")))) (EVar "deSeedChainProbeZero")))
(DTypeSig false "deSeedChainKinds" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyApp (TyCon "List") (TyCon "Kind")))))))
(DFunDef false "deSeedChainKinds" ((PVar "gctx")) (EFieldAccess (EApp (EVar "deSeedChainProbe") (EVar "gctx")) "dsKinds"))
(DTypeSig false "deSeedChainOwners" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "deSeedChainOwners" ((PVar "gctx")) (EFieldAccess (EApp (EVar "deSeedChainProbe") (EVar "gctx")) "dsOwners"))
(DTypeSig false "deSeedChainNames" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "deSeedChainNames" ((PVar "gctx")) (EFieldAccess (EApp (EVar "deSeedChainProbe") (EVar "gctx")) "dsNames"))
(DTypeSig false "deSeedNameParity" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "deSeedNameParity" ((PVar "mid")) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "accumulated") (EApp (EVar "omKeys") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EApp (EVar "deSeedChainNames") (EVar "gctx")))))) (DoLet false false (PVar "rebuilt") (EApp (EVar "omKeys") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EVar "tabKeyName") (EApp (EVar "fst") (EVar "p"))))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EApp (EVar "deSeedChainKinds") (EVar "gctx")))))) (EVar "omEmpty")))) (DoExpr (EBinOp "==" (EVar "accumulated") (EVar "rebuilt")))))
(DTypeSig false "deNameIdxAlpha" (TyCon "Decl"))
(DFunDef false "deNameIdxAlpha" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Alpha"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "MkAlpha"))) (EApp (EVar "ConPos") (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "modA")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deNameIdxSharedA" (TyCon "Decl"))
(DFunDef false "deNameIdxSharedA" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Shared"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "MkSharedA"))) (EApp (EVar "ConPos") (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "modA")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deNameIdxBeta" (TyCon "Decl"))
(DFunDef false "deNameIdxBeta" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Beta"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "MkBeta"))) (EApp (EVar "ConPos") (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "modB")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deNameIdxSharedB" (TyCon "Decl"))
(DFunDef false "deNameIdxSharedB" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Shared"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "MkSharedB"))) (EApp (EVar "ConPos") (EListLit (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "modB")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deNameIdxModA" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deNameIdxModA" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "modA"))) (EListLit (EVar "deNameIdxAlpha") (EVar "deNameIdxSharedA"))))
(DTypeSig false "deNameIdxModB" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deNameIdxModB" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "modB"))) (EListLit (EVar "deNameIdxBeta") (EVar "deNameIdxSharedB"))))
(DTypeSig false "deNameIdxModC" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deNameIdxModC" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 2))) (ELit (LString "modC"))) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "True")) (ELit (LString "modCHelper"))) (EListLit)) (EApp (EVar "ELit") (EApp (EVar "LInt") (ELit (LInt 1))))) (EVar "noDeclLoc")) (EVar "noBinderId")))))
(DTypeSig false "deNameIdxModD" (TyFun (TyCon "GraphCtx") (TyCon "DeclEnvModule")))
(DFunDef false "deNameIdxModD" ((PVar "gctx")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 3))) (ELit (LString "modD"))) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "True")) (ELit (LString "modDHelper"))) (EListLit)) (EApp (EVar "ELit") (EApp (EVar "LInt") (ELit (LInt 2))))) (EVar "noDeclLoc")) (EVar "noBinderId")))))
(DTypeSig false "deNameIdxChain" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "deNameIdxChain" ((PVar "gctx")) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EApp (EVar "declEnvSeedChain") (EVar "gctx")) (EListLit (EApp (EVar "deNameIdxModA") (EVar "gctx")) (EApp (EVar "deNameIdxModB") (EVar "gctx")) (EApp (EVar "deNameIdxModC") (EVar "gctx")) (EApp (EVar "deNameIdxModD") (EVar "gctx")))) (EVar "deSeedChainProbeZero"))) (DoExpr (EFieldAccess (EVar "s") "dsNames"))))
(DTypeSig false "deNameIdxChainNoUnrelated" (TyFun (TyCon "GraphCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "deNameIdxChainNoUnrelated" ((PVar "gctx")) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EApp (EVar "declEnvSeedChain") (EVar "gctx")) (EListLit (EApp (EVar "deNameIdxModA") (EVar "gctx")) (EApp (EVar "deNameIdxModB") (EVar "gctx")))) (EVar "deSeedChainProbeZero"))) (DoExpr (EFieldAccess (EVar "s") "dsNames"))))
(DTypeSig false "deNameIdxAt" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "deNameIdxAt" ((PVar "nm") (PVar "mid")) (EApp (EVar "omKeys") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "nm")))))
(DTypeSig false "buildDataEnv" (TyFun (TyApp (TyCon "List") (TyCon "DeclEnvModule")) (TyCon "DataEnv")))
(DFunDef false "buildDataEnv" ((PVar "rows")) (EApp (EVar "dataEnvFinish") (EApp (EApp (EVar "dataEnvFromRowsGo") (EVar "rows")) (EVar "emptyDataEnv"))))
(DTypeSig false "aliasFixturePubCore" (TyCon "Decl"))
(DFunDef false "aliasFixturePubCore" () (ERecordCreate "DTypeAlias" ((fa "tyAliasPub" (EVar "True")) (fa "tyAliasName" (ELit (LString "PubCore"))) (fa "tyAliasParams" (EListLit)) (fa "tyAliasParamKinds" (EListLit)) (fa "tyAliasRhs" (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (fa "tyAliasOrigin" (EApp (EVar "OriginModule") (ELit (LString "core")))) (fa "tyAliasNameLoc" (EVar "None")))))
(DTypeSig false "aliasFixturePrivCore" (TyCon "Decl"))
(DFunDef false "aliasFixturePrivCore" () (ERecordCreate "DTypeAlias" ((fa "tyAliasPub" (EVar "False")) (fa "tyAliasName" (ELit (LString "PrivCore"))) (fa "tyAliasParams" (EListLit)) (fa "tyAliasParamKinds" (EListLit)) (fa "tyAliasRhs" (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (fa "tyAliasOrigin" (EApp (EVar "OriginModule") (ELit (LString "core")))) (fa "tyAliasNameLoc" (EVar "None")))))
(DTypeSig false "aliasFixturePubM" (TyCon "Decl"))
(DFunDef false "aliasFixturePubM" () (ERecordCreate "DTypeAlias" ((fa "tyAliasPub" (EVar "True")) (fa "tyAliasName" (ELit (LString "PubM"))) (fa "tyAliasParams" (EListLit)) (fa "tyAliasParamKinds" (EListLit)) (fa "tyAliasRhs" (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (fa "tyAliasOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))) (fa "tyAliasNameLoc" (EVar "None")))))
(DTypeSig false "aliasFixtureAttribCore" (TyCon "Decl"))
(DFunDef false "aliasFixtureAttribCore" () (EApp (EApp (EVar "DAttrib") (EListLit (EApp (EVar "AttrDeprecated") (EApp (EVar "Some") (ELit (LString "old")))))) (ERecordCreate "DTypeAlias" ((fa "tyAliasPub" (EVar "True")) (fa "tyAliasName" (ELit (LString "AttribCore"))) (fa "tyAliasParams" (EListLit)) (fa "tyAliasParamKinds" (EListLit)) (fa "tyAliasRhs" (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))) (fa "tyAliasOrigin" (EApp (EVar "OriginModule") (ELit (LString "core")))) (fa "tyAliasNameLoc" (EVar "None"))))))
(DTypeSig false "aliasFixtureEnv" (TyFun (TyCon "GraphCtx") (TyCon "DataEnv")))
(DFunDef false "aliasFixtureEnv" ((PVar "gctx")) (EApp (EVar "buildDataEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "core"))) (EListLit (EVar "aliasFixturePubCore") (EVar "aliasFixturePrivCore") (EVar "aliasFixtureAttribCore"))) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "m"))) (EListLit (EVar "aliasFixturePubM"))))))
(DTypeSig false "aliasNamesAt" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "aliasNamesAt" ((PVar "cur")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (EApp (EVar "tabKeyName") (EApp (EVar "fst") (EVar "e"))))) (EApp (EApp (EVar "aliasUniverseAt") (EVar "cur")) (EFieldAccess (EApp (EVar "aliasFixtureEnv") (EApp (EVar "probeGraphCtx") (ELit LUnit))) "deAliases"))))
(DTypeSig false "deFieldOwnerFixtureA" (TyCon "Decl"))
(DFunDef false "deFieldOwnerFixtureA" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Pt"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "Pt"))) (EApp (EApp (EVar "ConNamed") (EListLit (EApp (EApp (EVar "Field") (ELit (LString "x"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))) (EVar "False"))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deFieldOwnerFixtureB" (TyCon "Decl"))
(DFunDef false "deFieldOwnerFixtureB" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Vec"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "Vec"))) (EApp (EApp (EVar "ConNamed") (EListLit (EApp (EApp (EVar "Field") (ELit (LString "x"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))) (EVar "False"))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "n")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deFieldOwnerFixtureC" (TyCon "Decl"))
(DFunDef false "deFieldOwnerFixtureC" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "Pt"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "Pt"))) (EApp (EApp (EVar "ConNamed") (EListLit (EApp (EApp (EVar "Field") (ELit (LString "x"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))) (EVar "False"))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "n")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deFieldOwnerCollisionEnv" (TyFun (TyCon "GraphCtx") (TyCon "DataEnv")))
(DFunDef false "deFieldOwnerCollisionEnv" ((PVar "gctx")) (EApp (EVar "buildDataEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "m"))) (EListLit (EVar "deFieldOwnerFixtureA") (EVar "deFieldOwnerFixtureB"))))))
(DTypeSig false "deFieldOwnerSingleEnv" (TyFun (TyCon "GraphCtx") (TyCon "DataEnv")))
(DFunDef false "deFieldOwnerSingleEnv" ((PVar "gctx")) (EApp (EVar "buildDataEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "m"))) (EListLit (EVar "deFieldOwnerFixtureA"))))))
(DTypeSig false "deFieldOwnerSameNameEnv" (TyFun (TyCon "GraphCtx") (TyCon "DataEnv")))
(DFunDef false "deFieldOwnerSameNameEnv" ((PVar "gctx")) (EApp (EVar "buildDataEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "m"))) (EListLit (EVar "deFieldOwnerFixtureA") (EVar "deFieldOwnerFixtureC"))))))
(DTypeSig false "deRecordOrderFixtureA" (TyCon "Decl"))
(DFunDef false "deRecordOrderFixtureA" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "P1"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "Pt"))) (EApp (EApp (EVar "ConNamed") (EListLit (EApp (EApp (EVar "Field") (ELit (LString "x"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))) (EVar "False"))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deRecordOrderFixtureB" (TyCon "Decl"))
(DFunDef false "deRecordOrderFixtureB" () (ERecordCreate "DData" ((fa "dataVis" (EVar "VisPublic")) (fa "dataName" (ELit (LString "P2"))) (fa "dataParams" (EListLit)) (fa "dataParamKinds" (EListLit)) (fa "dataCtors" (EListLit (EApp (EApp (EVar "Variant") (ELit (LString "Pt"))) (EApp (EApp (EVar "ConNamed") (EListLit (EApp (EApp (EVar "Field") (ELit (LString "y"))) (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Int"))) (EVar "None"))))) (EVar "False"))))) (fa "dataCtorBinders" (EListLit)) (fa "dataDerives" (EListLit)) (fa "dataOrigin" (EApp (EVar "OriginModule") (ELit (LString "n")))) (fa "dataExtern" (EVar "False")) (fa "dataNameLoc" (EVar "None")))))
(DTypeSig false "deRecordOrderEnv" (TyFun (TyCon "GraphCtx") (TyCon "DataEnv")))
(DFunDef false "deRecordOrderEnv" ((PVar "gctx")) (EApp (EVar "buildDataEnv") (EListLit (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 0))) (ELit (LString "m"))) (EListLit (EVar "deRecordOrderFixtureA"))) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "gctx")) (ELit (LInt 1))) (ELit (LString "n"))) (EListLit (EVar "deRecordOrderFixtureB"))))))
(DTypeSig false "deRecordIdentTyNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyApp (TyCon "List") (TyCon "Field")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "deRecordIdentTyNames" ((PList)) (EListLit))
(DFunDef false "deRecordIdentTyNames" ((PCons (PTuple PWild (PVar "tyName") PWild) (PVar "rest"))) (EBinOp "::" (EVar "tyName") (EApp (EVar "deRecordIdentTyNames") (EVar "rest"))))
(DTypeSig true "methodRowNumObservation" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "NumAnchorTestObservation"))))))
(DFunDef false "methodRowNumObservation" ((PVar "saved") (PVar "caseName") (PVar "builtinDecls") (PVar "decls")) (EBlock (DoLet false false (PVar "gctx") (EApp (EVar "freshSubRecordsOf") (EFieldAccess (EVar "saved") "mcGraph"))) (DoLet false false (PVar "mctx") (EApp (EApp (EVar "carryModuleCtx") (EVar "gctx")) (EVar "saved"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "builtinClassesRef")) (EApp (EVar "builtinClassesOf") (EVar "builtinDecls")))) (DoLet false false (PVar "rows") (EApp (EApp (EVar "ifaceMethodSchemeRows") (EVar "mctx")) (EVar "decls"))) (DoExpr (EApp (EApp (EVar "seedNumLitFromIntAnchor") (EVar "mctx")) (EVar "rows"))) (DoLet false false (PVar "observation") (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "numLitFromIntAnchorRef") "value") (arm (PCon "None") () (ERecordCreate "NumAnchorTestObservation" ((fa "natoCase" (EVar "caseName")) (fa "natoHasRow" (EVar "False")) (fa "natoIface" (ELit (LString ""))) (fa "natoSchemeBody" (ELit (LString ""))) (fa "natoDeclaredType" (ELit (LString "")))))) (arm (PCon "Some" (PVar "anchor")) () (ERecordCreate "NumAnchorTestObservation" ((fa "natoCase" (EVar "caseName")) (fa "natoHasRow" (EVar "True")) (fa "natoIface" (EFieldAccess (EFieldAccess (EVar "anchor") "msrIface") "irName")) (fa "natoSchemeBody" (EApp (EVar "ppMono") (EApp (EVar "schemeBodyOf") (EFieldAccess (EVar "anchor") "msrScheme")))) (fa "natoDeclaredType" (EApp (EVar "ppTy") (EFieldAccess (EVar "anchor") "msrType")))))))) (DoExpr (EVar "observation"))))
(DTypeSig false "distinctIdentsIn2" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String"))) (TyCon "Bool")))
(DFunDef false "distinctIdentsIn2" ((PList (PTuple (PVar "i1") PWild) (PTuple (PVar "i2") PWild))) (EBinOp "/=" (EVar "i1") (EVar "i2")))
(DFunDef false "distinctIdentsIn2" (PWild) (EVar "False"))
