# META
source_lines=666
stages=DESUGAR,MARK
# SOURCE
-- One module's checked diagnostics-arm contribution as a value, the key it is
-- valid under, and the one process cache of them.
--
-- A `ModuleInterface` is what a diagnostics drive needs from a module before the
-- entry to continue as if it had checked it: the module's frozen diagnostics row,
-- its own export bindings, and the rows its check added to the graph record.  It is
-- admissible by `prelude_interface.mdk`'s rule: no `Decl`, no `Ref`, no live
-- `Scheme`.  Every scheme, slot and record a later module reads is copied over
-- fresh cells when it is recorded and again each time it is applied, so no drive
-- shares a cell with another; the diagnostics row is frozen once and only rendered.
--
-- What a module's check adds, and how `applyModuleInterface` replays it:
--   * the lists a module prepends to (the constructor universe, the predicate slots,
--     the declared prefixes, the scheme obligations, the evidence entries and the
--     sticky diagnostics): the recorded prefix, in front of the current list.  A
--     module's check re-orders the bare slot rows it does not own without changing
--     any first-match lookup, so the replayed order answers every reader alike;
--   * the dispatch-index universe, which a module appends to: the recorded suffix;
--   * the function-name universe, the existential and pattern-authority ids, the
--     binder rows and the grant tables: the recorded new keys, inserted;
--   * the constructor and record populations: the module's own rows, inserted by
--     identity (`spInsert`), then its floor-only spellings.
-- Nothing else a module writes is read by a later module on the diagnostics arm: a
-- module records only after its goals are drained, and its given environment,
-- scopes and evidence cells are read only inside it.  No id is relocated: binder
-- and evidence ordinals are process-global, and a drive that serves starts its type
-- and effect variables above every id a served interface was recorded with
-- (`Lineage`).  The evidence cells a served module minted are not carried, so the
-- served drive's evidence table lacks their entries; no diagnostics-arm reader reads
-- that table.
--
-- A tree drive needs more of a module than its interface: the trees the drive
-- continues with, and the rows its graph-end passes read for them (`ModuleTrees`).
-- The trees are the module's marked trees, taken before `dictPass`, which the
-- serving drive runs again over the whole graph.  Two of its rows are
-- exceptions to the admissibility rule above: the trees, a frozen `List Decl` that
-- holds no cell, admitted as the prelude's shipped trees are
-- (`types/prelude_elab.mdk`), and the file bounds, which keep the recording check's
-- own variables because the grant pass resolves them against the authority cells
-- that check's occurrences hold.  In process the trees' evidence ordinals stay below
-- every ordinal the serving drive mints, so they are carried as recorded.
--
-- The cache holds one interface per module id, the newest recorded, with no count
-- cap.  Each recorded interface carries a process serial, and an importer's key
-- carries the serial of each import (`moduleInterfaceIdentity`), so an importer
-- whose import was re-recorded misses without any digest.
import frontend.ast.{
  TabKey, DataVis, Variant, EvTable, Ident, Decl(..), EvEntry(..), EvVal(..),
  EvId(..), IfaceMethod(..), declBinderNames
}
import list.{drop, take, mapAccumL}
import map as M
import map.{Map(..)}
import support.ordmap.{
  OrdMap, omEmpty, omInsert, omDelete, omLookup, omHasKey, omRestrict,
  omFromPairs
}
import support.util.{joinNl, lenKey, listLen, isNonEmptyL, dedup, lookupAssoc}
import types.invocation_basis.{publishInvocationView}
import types.prelude_interface.{
  freezeScheme, thawScheme, zonkSlot, zonkMethodSlot, zonkRecord, mapSlots
}
import types.publish.{
  ModDiags, PubScheme(..), TcDiag, emptyZonk, zonkScheme, zonkVecObl
}
import types.registry.{SpellingPop, spInsert, spMap, spRows, spFloor}
import types.effect_rows.{EffRow}
import types.repr.{IfaceRef, Mono, VecObl}
import types.route_key.{EvIndex, evidenceLookup, ifaceWordOf, replaceEntryIn}
import types.runtime_types.{BinderRow, BinderTypeTable, addBinderRow}
import types.tc_types.{
  GraphCtx(..), CrossRun(..), GraphRun(..), GrantState(..), ModuleCtx(..),
  ModuleCells(..), ExportBinding(..), PredicateSlot, MethodPredicateSlot,
  CDeclaredPrefix, RecordInfo, MethodGrant, PublishedInvocationView, EvCell(..),
  SiteCell(..), LocalAbs(..), LocalAbsState(..), GrantBinder, grantTopKey,
  methodGrantKey, setGrantIds
}

-- ── the key ─────────────────────────────────────────────────────────────────

-- What an interface is valid under: the module id, the source key its driver passes
-- (the module id, its path and the exact source the loader parsed), the identity of
-- each direct import, and the drive's graph key (its configuration, the prelude
-- generation but not the entry or roots, and every module's instance heads and
-- constrained signature names, which a module reads whether or not it imports their
-- definer),
-- followed by the interface declarations of the modules before it, whose method
-- names it reads by bare name; a tree drive also adds the promotion harvest of those
-- modules.  An import that was checked and not recorded has a serial no interface carries.
public export data ModuleKey = ModuleKey {
  mkModule : String,
  mkSource : String,
  mkImports : List (String, String),
  mkGraph : String,
}

-- The one rendering of a key, which the cache compares.  Every field is
-- length-prefixed, so two keys render alike only when they are equal.
export
moduleKeyText : ModuleKey -> String
moduleKeyText k =
  joinNl
    ([lenKey k.mkModule, lenKey k.mkSource, lenKey k.mkGraph]
      ++ map (imp => "\{lenKey (fst imp)}\{lenKey (snd imp)}") k.mkImports)

-- ── the interface value ─────────────────────────────────────────────────────

-- An export binding over fresh cells.  Its scheme and its standalone alternative are
-- copied with one zonk state, so a variable the two share stays one variable.
public export data FrozenExport = FrozenExport {
  feScheme : PubScheme,
  feStandalone : Option PubScheme,
  feExtern : Bool,
}

public export data ModuleInterface = ModuleInterface {
  miKey : ModuleKey,
  miKeyText : String,
  miSerial : Int,
  miRow : ModDiags,
  miExports : List (String, FrozenExport),
  miFunNames : List String,
  miDispatchIdx : List ((IfaceRef, String), Int),
  miDataCtors : List (TabKey, (DataVis, List String, List Variant)),
  miCtorPop : SpellingPop PubScheme,
  miRecordPop : SpellingPop RecordInfo,
  miFunSlots : List (String, List PredicateSlot),
  miFunSlotsQual : List ((String, String), List PredicateSlot),
  miDeclared : List (String, CDeclaredPrefix),
  miDeclaredQual : List ((String, String), CDeclaredPrefix),
  miMethodSlots : List (String, List MethodPredicateSlot),
  miMethodSlotsQual : List ((String, String), List MethodPredicateSlot),
  miSchemeOblsQual : List ((String, String), List VecObl),
  miExistentials : List Int,
  miPatternAuth : List Int,
  miAnyExistentials : Bool,
  miEvTable : EvTable,
  miBinders : List BinderRow,
  miTopIds : List (String, List Int),
  miMethodGrants : List (String, MethodGrant),
  miTakers : List String,
  miSticky : List (String, TcDiag),
  miInvocationView : PublishedInvocationView,
  miTrees : Option ModuleTrees,
}

-- A module's tree content, recorded by a tree drive (`None` on an interface a
-- diagnostics drive recorded, which a tree drive does not serve):
--   * its marked trees;
--   * the entries of the method and site cells its check minted, as the check left
--     them; the grant pass of the serving drive still counts a method's grants into
--     the arity of its occurrences;
--   * the rows the graph-end passes read for its trees: the grant ids of each of its
--     top-level binders, the abstraction and grant ids of each local it named and the
--     grants of each method its interfaces declare, keyed by names that carry the
--     module's id and so recorded for every such name, with an empty list or `None`
--     where it takes none; the file bounds of its sites, keyed by the module and the
--     site; and the authority variables no caller supplies;
--   * the names it promoted, which a later module is marked with, and its `main`.
public export data ModuleTrees = ModuleTrees {
  mtMarked : List Decl,
  mtEvidence : EvTable,
  mtTopIds : List (String, List Int),
  mtLocalAbs : List (String, Option LocalAbs),
  mtLocalIds : List (String, List Int),
  mtMethodGrants : List (String, Option MethodGrant),
  mtSourceless : List Int,
  mtBounds : List (String, List (EffRow, List GrantBinder)),
  mtValueBounds : List (String, List (Mono, List GrantBinder)),
  mtPromoted : List String,
  mtMain : Option PubScheme,
}

-- The rows of a graph record a module's check adds to, read at one point: the
-- view before the module and the view after it are what an interface records the
-- difference of.
export data ModuleRows = ModuleRows {
  mrFunNames : OrdMap Unit,
  mrDispatchIdx : List ((IfaceRef, String), Int),
  mrDataCtors : List (TabKey, (DataVis, List String, List Variant)),
  mrFunSlots : List (String, List PredicateSlot),
  mrFunSlotsQual : List ((String, String), List PredicateSlot),
  mrDeclared : List (String, CDeclaredPrefix),
  mrDeclaredQual : List ((String, String), CDeclaredPrefix),
  mrMethodSlots : List (String, List MethodPredicateSlot),
  mrMethodSlotsQual : List ((String, String), List MethodPredicateSlot),
  mrSchemeOblsQual : List ((String, String), List VecObl),
  mrExistentials : Map Int Unit,
  mrPatternAuth : Map Int Unit,
  mrAnyExistentials : Bool,
  mrEvTable : EvTable,
  mrBinders : BinderTypeTable,
  mrTopIds : OrdMap (List Int),
  mrMethodGrants : OrdMap MethodGrant,
  mrTakers : OrdMap Unit,
  mrSticky : List (String, TcDiag),
  mrEvCounter : Int,
  mrSourceless : Map Int Unit,
  mrBounds : OrdMap (List (EffRow, List GrantBinder)),
  mrValueBounds : OrdMap (List (Mono, List GrantBinder)),
}

export
captureModuleRows : GraphCtx -> ModuleRows
captureModuleRows g =
  let c = g.crossRun
  let r = g.graphRun
  ModuleRows {
    mrFunNames = c.universeFunNamesRef.value,
    mrDispatchIdx = c.universeMethodDispatchIdxByIdRef.value,
    mrDataCtors = c.universeDataCtors.value,
    mrFunSlots = c.crossModuleFunPredicateSlotsRef.value,
    mrFunSlotsQual = c.crossModuleFunPredicateSlotsQualRef.value,
    mrDeclared = c.crossModuleFunConstraintDeclaredRef.value,
    mrDeclaredQual = c.crossModuleFunConstraintDeclaredQualRef.value,
    mrMethodSlots = c.crossModuleMethodPredicateSlotsRef.value,
    mrMethodSlotsQual = c.crossModuleMethodPredicateSlotsQualRef.value,
    mrSchemeOblsQual = c.crossModuleSchemeOblsQualRef.value,
    mrExistentials = r.ctorExistentialsRef.value,
    mrPatternAuth = r.patternAuthIdsRef.value,
    mrAnyExistentials = r.anyExistentialsRef.value,
    mrEvTable = r.evTable.value,
    mrBinders = r.binderRows.value,
    mrTopIds = r.grants.gsTopIds.value,
    mrMethodGrants = r.grants.gsMethods.value,
    mrTakers = r.grants.gsTakers.value,
    mrSticky = g.typeErrorsStickyDiags.value,
    mrEvCounter = r.evCounter.value,
    mrSourceless = r.grants.gsSourceless.value,
    mrBounds = r.grants.gsBounds.value,
    mrValueBounds = r.grants.gsValueBounds.value,
  }

-- ── freeze and apply ────────────────────────────────────────────────────────

-- The rows [after] holds in front of [before]'s.
newPrefix : List a -> List a -> List a
newPrefix after before = take (listLen after - listLen before) after

zonkObls : List (k, List VecObl) -> List (k, List VecObl)
zonkObls rows =
  map (row => (fst row, snd (mapAccumL zonkVecObl emptyZonk (snd row)))) rows

freezeExport : ExportBinding -> FrozenExport
freezeExport xb =
  let (z, s) = zonkScheme emptyZonk xb.xbScheme
  FrozenExport {
    feScheme = PubScheme { psScheme = s, psContext = [] },
    feStandalone =
      map
        (alt => PubScheme { psScheme = snd (zonkScheme z alt), psContext = [] })
        xb.xbStandalone,
    feExtern = xb.xbExtern,
  }

thawExport : FrozenExport -> ExportBinding
thawExport fe =
  let (z, s) = zonkScheme emptyZonk fe.feScheme.psScheme
  ExportBinding {
    xbScheme = s,
    xbStandalone = map (alt => snd (zonkScheme z alt.psScheme)) fe.feStandalone,
    xbExtern = fe.feExtern,
  }

-- The interface of a module just checked and drained: [row] is its frozen
-- diagnostics row, [exports] its own export bindings, [before] the view taken before
-- its check, [mctx] its record after the drain and [trees] its tree content, which
-- only a tree drive records.
export
freezeModuleInterface : ModuleKey ->
  Int ->
  ModDiags ->
  List (String, ExportBinding) ->
  ModuleRows ->
  ModuleCtx ->
  Option ModuleTrees ->
  ModuleInterface
freezeModuleInterface key serial row exports before mctx trees =
  let after = captureModuleRows mctx.mcGraph
  let (ctorPop, recordPop) = mctx.mcCells.ownPopsRef.value
  let existentials =
    M.keys (M.difference after.mrExistentials before.mrExistentials)
  ModuleInterface {
    miKey = key,
    miKeyText = moduleKeyText key,
    miSerial = serial,
    miRow = row,
    miExports = map (b => (fst b, freezeExport (snd b))) exports,
    miFunNames = M.keys (M.difference after.mrFunNames before.mrFunNames),
    miDispatchIdx = drop (listLen before.mrDispatchIdx) after.mrDispatchIdx,
    miDataCtors = newPrefix after.mrDataCtors before.mrDataCtors,
    miCtorPop = spMap freezeScheme ctorPop,
    miRecordPop = spMap zonkRecord recordPop,
    miFunSlots =
      mapSlots zonkSlot (newPrefix after.mrFunSlots before.mrFunSlots),
    miFunSlotsQual =
      mapSlots zonkSlot (newPrefix after.mrFunSlotsQual before.mrFunSlotsQual),
    miDeclared = newPrefix after.mrDeclared before.mrDeclared,
    miDeclaredQual = newPrefix after.mrDeclaredQual before.mrDeclaredQual,
    miMethodSlots =
      mapSlots
        zonkMethodSlot
        (newPrefix after.mrMethodSlots before.mrMethodSlots),
    miMethodSlotsQual =
      mapSlots
        zonkMethodSlot
        (newPrefix after.mrMethodSlotsQual before.mrMethodSlotsQual),
    miSchemeOblsQual =
      zonkObls (newPrefix after.mrSchemeOblsQual before.mrSchemeOblsQual),
    miExistentials = existentials,
    miPatternAuth =
      M.keys (M.difference after.mrPatternAuth before.mrPatternAuth),
    -- Set by this module when it registered an existential constructor, or when it
    -- turned the flag on.
    miAnyExistentials =
      isNonEmptyL existentials
        || after.mrAnyExistentials && not before.mrAnyExistentials,
    miEvTable = newPrefix after.mrEvTable before.mrEvTable,
    miBinders =
      map snd (M.entries (M.difference after.mrBinders before.mrBinders)),
    miTopIds = M.entries (M.difference after.mrTopIds before.mrTopIds),
    miMethodGrants =
      M.entries (M.difference after.mrMethodGrants before.mrMethodGrants),
    miTakers = M.keys (M.difference after.mrTakers before.mrTakers),
    miSticky = newPrefix after.mrSticky before.mrSticky,
    miInvocationView =
      publishInvocationView mctx.mcCells.invocationViewRef.value,
    miTrees = trees,
  }

-- The tree content of module [mid], just checked and drained, from its marked trees
-- [marked], its frozen schemes [published], the view [before] taken before its check
-- and its record [mctx].
export
freezeModuleTrees : String ->
  List Decl ->
  List (String, PubScheme) ->
  ModuleRows ->
  ModuleCtx ->
  ModuleTrees
freezeModuleTrees mid marked published before mctx =
  let r = mctx.mcGraph.graphRun
  let gs = r.grants
  let locals = r.localAbs.lasMinted.value
  ModuleTrees {
    mtMarked = marked,
    mtEvidence = cellEntriesFrom r before.mrEvCounter,
    mtTopIds =
      idsUnder
        (map (grantTopKey mid) (topBinderNames marked))
        gs.gsTopIds.value,
    mtLocalAbs =
      map
        (row => (fst row, map zonkLocalAbs (snd row)))
        (M.entries (omRestrict locals r.localAbs.lasBinders.value)),
    mtLocalIds = idsUnder locals gs.gsLocalIds.value,
    mtMethodGrants =
      map (k => (k, omLookup k gs.gsMethods.value)) (methodGrantKeys marked),
    mtSourceless =
      M.keys (M.difference gs.gsSourceless.value before.mrSourceless),
    mtBounds = M.entries (M.difference gs.gsBounds.value before.mrBounds),
    mtValueBounds =
      M.entries (M.difference gs.gsValueBounds.value before.mrValueBounds),
    mtPromoted = mctx.mcCells.promotedRef.value,
    mtMain = lookupAssoc "main" published,
  }

-- Replays [t] into [g], the record the serving drive continues from, and returns
-- the module's marked trees.  Each row keyed by name replaces what another check of
-- the module id wrote under that name, and a name the recording holds no row for
-- loses the row it has, so the rows are the ones these trees were checked with.
export
applyModuleTrees : GraphCtx -> ModuleTrees -> List Decl
applyModuleTrees g t =
  let r = g.graphRun
  let gs = r.grants
  let las = r.localAbs
  r.evTable := t.mtEvidence ++ r.evTable.value
  each (setGrantIds gs.gsTopIds) t.mtTopIds
  each (row => forgetLocalRows las gs (fst row)) t.mtLocalIds
  las.lasBinders :=
    omFromPairs
      (map (row => (fst row, map zonkLocalAbs (snd row))) t.mtLocalAbs)
      las.lasBinders.value
  each (setGrantIds gs.gsLocalIds) t.mtLocalIds
  gs.gsMethods :=
    fold
      (acc row => match snd row
        Some mg => omInsert (fst row) mg acc
        None => omDelete (fst row) acc)
      gs.gsMethods.value
      t.mtMethodGrants
  gs.gsSourceless := insertIds t.mtSourceless gs.gsSourceless.value
  gs.gsBounds := omFromPairs t.mtBounds gs.gsBounds.value
  gs.gsValueBounds := omFromPairs t.mtValueBounds gs.gsValueBounds.value
  g.promotionHarvestRef := dedup (g.promotionHarvestRef.value ++ t.mtPromoted)
  match t.mtMain
    Some p => g.mainSchemeRef := Some (thawScheme p)
    None => ()
  t.mtMarked

zonkLocalAbs : LocalAbs -> LocalAbs
zonkLocalAbs la = { la | laSlots = map zonkSlot la.laSlots }

-- Delete every row recorded under the renamed local binder [name].
export
forgetLocalRows : LocalAbsState -> GrantState -> String -> Unit
forgetLocalRows las gs name =
  las.lasBinders := omDelete name las.lasBinders.value
  las.lasRecOccs := omDelete name las.lasRecOccs.value
  gs.gsLocalIds := omDelete name gs.gsLocalIds.value

-- The keys of the methods the interfaces of [prog] declare.
methodGrantKeys : List Decl -> List String
methodGrantKeys prog = flatMap declMethodGrantKeys prog

declMethodGrantKeys : Decl -> List String
declMethodGrantKeys (DInterface { name, methods, ifaceOrigin, ... }) =
  map
    ((IfaceMethod m _ _ _) => methodGrantKey (ifaceWordOf ifaceOrigin name) m)
    methods
-- a declaration that declares no interface method
declMethodGrantKeys _ = []

-- Each of [keys] with the grant ids [table] holds under it, empty for none.
idsUnder : List String -> OrdMap (List Int) -> List (String, List Int)
idsUnder keys table = map (k => (k, optionOr [] (omLookup k table))) keys

-- The names the top-level definitions of [prog] bind.
topBinderNames : List Decl -> List String
topBinderNames prog = dedup (flatMap declBinderNames prog)

-- ── evidence cells ──────────────────────────────────────────────────────────

-- Every method and site cell of [r] minted at ordinal [lo] or later, as published
-- entries, method cells first: the per-node half of a drive's evidence table.
export
cellEntriesFrom : GraphRun -> Int -> EvTable
cellEntriesFrom r lo =
  let from = max 0 (lo - r.evBase)
  let cells = r.evCells.value
  let sites = r.siteCells.value
  methodCellEntriesFrom cells from (arrayLength cells - 1) []
    ++ siteCellEntriesFrom sites from (arrayLength sites - 1) []

methodCellEntriesFrom : Array (Option EvCell) ->
  Int ->
  Int ->
  EvTable ->
  EvTable
methodCellEntriesFrom arr lo i acc
  | i < lo = acc
  | otherwise = match arrayGetUnsafe i arr
    None => methodCellEntriesFrom arr lo (i - 1) acc
    Some c =>
      let arity =
        optionOrPanic
          "method cell published before its selected scheme supplied an arity"
          c.ecArity.value
      methodCellEntriesFrom
        arr
        lo
        (i - 1)
        (EvEntry
            c.ecId
            (EvMethod
              c.ecIface.value
              arity
              c.ecTag.value
              c.ecImpl.value
              c.ecMeth.value)
          :: acc)

siteCellEntriesFrom : Array (Option (EvId, SiteCell)) ->
  Int ->
  Int ->
  EvTable ->
  EvTable
siteCellEntriesFrom arr lo i acc
  | i < lo = acc
  | otherwise = match arrayGetUnsafe i arr
    None => siteCellEntriesFrom arr lo (i - 1) acc
    Some (ev, c) =>
      siteCellEntriesFrom arr lo (i - 1) (EvEntry ev (siteCellValue c) :: acc)

siteCellValue : SiteCell -> EvVal
siteCellValue (OpSite r) = EvOne r.value
siteCellValue (LitSite f r) = EvLit f.value r.value
siteCellValue (HeadSite h) = EvHead h.value

-- The grant pass counts a method's grants into the arity of each of its
-- occurrences, which the published table carries.  An occurrence in a module the
-- drive served has no cell in this lineage, so the count goes to its entry in the
-- drive's index [idx], and the published table reads the served entries back out of
-- the index after the pass (`servedEntriesFrom`).
export
setServedArity : EvIndex -> EvId -> Int -> Unit
setServedArity idx ev arity =
  match evidenceLookup (Some idx) "served method occurrence" ev
    Ok (EvMethod iface _ tag impls meths) =>
      replaceEntryIn idx (EvEntry ev (EvMethod iface arity tag impls meths))
    Ok _ =>
      panic
        "evidence table: a method occurrence answered by another kind of entry"
    Err message => panic message

-- [rows] with each method entry below ordinal [base], the served ones, as [idx]
-- holds it.
export
servedEntriesFrom : EvIndex -> Int -> EvTable -> EvTable
servedEntriesFrom idx base rows = map (servedEntryIn idx base) rows

servedEntryIn : EvIndex -> Int -> EvEntry -> EvEntry
servedEntryIn idx base (e@(EvEntry ev (EvMethod _ _ _ _ _))) =
  let (EvId _ i) = ev
  if i < base then match evidenceLookup (Some idx) "served method occurrence" ev
    Ok v => EvEntry ev v
    Err message => panic message
  else
    e
servedEntryIn _ _ e = e

-- [own]'s rows inserted into [pop] by identity, each spelling's rows in their own
-- order, then [own]'s floor entries for the spellings that hold no row of [own].
mergePop : SpellingPop a -> SpellingPop a -> SpellingPop a
mergePop own pop =
  let rows = spRows own
  let withRows =
    fold
      (acc e => fold (acc2 row => insertRow (fst e) row acc2) acc (snd e))
      pop
      (M.entries rows)
  fold
    (acc e =>
      if omHasKey (fst e) rows then
        acc
      else
        spInsert None (fst e) "" (snd e) acc)
    withRows
    (M.entries (spFloor own))

insertRow : String -> (Ident, String, a) -> SpellingPop a -> SpellingPop a
insertRow spelling (ident, owner, payload) pop =
  spInsert (Some ident) spelling owner payload pop

insertIds : List Int -> Map Int Unit -> Map Int Unit
insertIds ids m = fold (acc i => M.set i () acc) m ids

-- Replays [mi]'s rows into [g], the record the serving drive continues from, and
-- returns the module's diagnostics row and its own export bindings over fresh cells.
export
applyModuleInterface : GraphCtx ->
  ModuleInterface ->
  (ModDiags, List (String, ExportBinding))
applyModuleInterface g mi =
  let c = g.crossRun
  let r = g.graphRun
  let gs = r.grants
  c.universeFunNamesRef :=
    fold (acc n => omInsert n () acc) c.universeFunNamesRef.value mi.miFunNames
  c.universeMethodDispatchIdxByIdRef :=
    c.universeMethodDispatchIdxByIdRef.value ++ mi.miDispatchIdx
  c.universeDataCtors := mi.miDataCtors ++ c.universeDataCtors.value
  c.universeCtorPop :=
    mergePop (spMap thawScheme mi.miCtorPop) c.universeCtorPop.value
  c.universeRecordPop :=
    mergePop (spMap zonkRecord mi.miRecordPop) c.universeRecordPop.value
  c.crossModuleFunPredicateSlotsRef :=
    mapSlots zonkSlot mi.miFunSlots ++ c.crossModuleFunPredicateSlotsRef.value
  c.crossModuleFunPredicateSlotsQualRef :=
    mapSlots zonkSlot mi.miFunSlotsQual
      ++ c.crossModuleFunPredicateSlotsQualRef.value
  c.crossModuleFunConstraintDeclaredRef :=
    mi.miDeclared ++ c.crossModuleFunConstraintDeclaredRef.value
  c.crossModuleFunConstraintDeclaredQualRef :=
    mi.miDeclaredQual ++ c.crossModuleFunConstraintDeclaredQualRef.value
  c.crossModuleMethodPredicateSlotsRef :=
    mapSlots zonkMethodSlot mi.miMethodSlots
      ++ c.crossModuleMethodPredicateSlotsRef.value
  c.crossModuleMethodPredicateSlotsQualRef :=
    mapSlots zonkMethodSlot mi.miMethodSlotsQual
      ++ c.crossModuleMethodPredicateSlotsQualRef.value
  c.crossModuleSchemeOblsQualRef :=
    zonkObls mi.miSchemeOblsQual ++ c.crossModuleSchemeOblsQualRef.value
  r.ctorExistentialsRef :=
    insertIds mi.miExistentials r.ctorExistentialsRef.value
  r.patternAuthIdsRef := insertIds mi.miPatternAuth r.patternAuthIdsRef.value
  r.anyExistentialsRef := r.anyExistentialsRef.value || mi.miAnyExistentials
  r.evTable := mi.miEvTable ++ r.evTable.value
  r.binderRows :=
    fold (acc row => addBinderRow row acc) r.binderRows.value mi.miBinders
  gs.gsTopIds :=
    fold (acc e => omInsert (fst e) (snd e) acc) gs.gsTopIds.value mi.miTopIds
  gs.gsMethods :=
    fold
      (acc e => omInsert (fst e) (snd e) acc)
      gs.gsMethods.value
      mi.miMethodGrants
  gs.gsTakers := fold (acc n => omInsert n () acc) gs.gsTakers.value mi.miTakers
  g.typeErrorsSticky := g.typeErrorsSticky.value || isNonEmptyL mi.miSticky
  g.typeErrorsStickyDiags := mi.miSticky ++ g.typeErrorsStickyDiags.value
  (mi.miRow, map (b => (fst b, thawExport (snd b))) mi.miExports)

-- ── the process cache ───────────────────────────────────────────────────────

-- [mcSerial] is the last serial handed out.
data ModuleCache = ModuleCache {
  mcEntries : OrdMap ModuleInterface,
  mcSerial : Int,
}

moduleCacheRef : Ref ModuleCache
moduleCacheRef = Ref ModuleCache { mcEntries = omEmpty, mcSerial = 0 }

-- A serial no earlier call returned: the serial of an interface about to be recorded,
-- or the identity of a module checked and not recorded, which no key recorded before
-- can name.
export
freshModuleSerial : Unit -> Int
freshModuleSerial _ =
  let cache = moduleCacheRef.value
  let next = cache.mcSerial + 1
  moduleCacheRef := { cache | mcSerial = next }
  next

-- What an importer's key carries for this module: its serial, in decimal.
export
moduleInterfaceIdentity : ModuleInterface -> String
moduleInterfaceIdentity mi = intToString mi.miSerial

export
moduleCacheHit : ModuleKey -> Option ModuleInterface
moduleCacheHit key = match omLookup key.mkModule moduleCacheRef.value.mcEntries
  Some mi => if mi.miKeyText == moduleKeyText key then Some mi else None
  None => None

-- Keeps [mi] as its module's interface, replacing the one recorded before.
export
recordModuleInterface : ModuleInterface -> Unit
recordModuleInterface mi =
  moduleCacheRef := withInterface moduleCacheRef.value mi

-- Drops the interfaces of every module outside [mids], so the cache is bounded by
-- the graph last analyzed rather than by every module id ever loaded.
export
retainModuleInterfaces : List String -> Unit
retainModuleInterfaces mids =
  let cache = moduleCacheRef.value
  moduleCacheRef := { cache | mcEntries = omRestrict mids cache.mcEntries }

-- Adds interfaces read from elsewhere.  The serials handed out afterwards start
-- above theirs.
export
seedModuleInterfaces : List ModuleInterface -> Unit
seedModuleInterfaces mis =
  moduleCacheRef := fold withInterface moduleCacheRef.value mis

withInterface : ModuleCache -> ModuleInterface -> ModuleCache
withInterface cache mi = ModuleCache {
  mcEntries = omInsert mi.miKey.mkModule mi cache.mcEntries,
  mcSerial = max cache.mcSerial mi.miSerial,
}

export
currentModuleInterfaces : Unit -> List ModuleInterface
currentModuleInterfaces _ = map snd (M.entries moduleCacheRef.value.mcEntries)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "TabKey" false) (mem "DataVis" false) (mem "Variant" false) (mem "EvTable" false) (mem "Ident" false) (mem "Decl" true) (mem "EvEntry" true) (mem "EvVal" true) (mem "EvId" true) (mem "IfaceMethod" true) (mem "declBinderNames" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "take" false) (mem "mapAccumL" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omDelete" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omRestrict" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "lenKey" false) (mem "listLen" false) (mem "isNonEmptyL" false) (mem "dedup" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("types" "invocation_basis") ((mem "publishInvocationView" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "freezeScheme" false) (mem "thawScheme" false) (mem "zonkSlot" false) (mem "zonkMethodSlot" false) (mem "zonkRecord" false) (mem "mapSlots" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ModDiags" false) (mem "PubScheme" true) (mem "TcDiag" false) (mem "emptyZonk" false) (mem "zonkScheme" false) (mem "zonkVecObl" false))))
(DUse false (UseGroup ("types" "registry") ((mem "SpellingPop" false) (mem "spInsert" false) (mem "spMap" false) (mem "spRows" false) (mem "spFloor" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" false) (mem "Mono" false) (mem "VecObl" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "EvIndex" false) (mem "evidenceLookup" false) (mem "ifaceWordOf" false) (mem "replaceEntryIn" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" false) (mem "BinderTypeTable" false) (mem "addBinderRow" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "GraphCtx" true) (mem "CrossRun" true) (mem "GraphRun" true) (mem "GrantState" true) (mem "ModuleCtx" true) (mem "ModuleCells" true) (mem "ExportBinding" true) (mem "PredicateSlot" false) (mem "MethodPredicateSlot" false) (mem "CDeclaredPrefix" false) (mem "RecordInfo" false) (mem "MethodGrant" false) (mem "PublishedInvocationView" false) (mem "EvCell" true) (mem "SiteCell" true) (mem "LocalAbs" true) (mem "LocalAbsState" true) (mem "GrantBinder" false) (mem "grantTopKey" false) (mem "methodGrantKey" false) (mem "setGrantIds" false))))
(DData Public "ModuleKey" () ((variant "ModuleKey" (ConNamed (field "mkModule" (TyCon "String")) (field "mkSource" (TyCon "String")) (field "mkImports" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "mkGraph" (TyCon "String"))))) ())
(DTypeSig true "moduleKeyText" (TyFun (TyCon "ModuleKey") (TyCon "String")))
(DFunDef false "moduleKeyText" ((PVar "k")) (EApp (EVar "joinNl") (EBinOp "++" (EListLit (EApp (EVar "lenKey") (EFieldAccess (EVar "k") "mkModule")) (EApp (EVar "lenKey") (EFieldAccess (EVar "k") "mkSource")) (EApp (EVar "lenKey") (EFieldAccess (EVar "k") "mkGraph"))) (EApp (EApp (EVar "map") (ELam ((PVar "imp")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lenKey") (EApp (EVar "fst") (EVar "imp"))))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "lenKey") (EApp (EVar "snd") (EVar "imp"))))) (ELit (LString ""))))) (EFieldAccess (EVar "k") "mkImports")))))
(DData Public "FrozenExport" () ((variant "FrozenExport" (ConNamed (field "feScheme" (TyCon "PubScheme")) (field "feStandalone" (TyApp (TyCon "Option") (TyCon "PubScheme"))) (field "feExtern" (TyCon "Bool"))))) ())
(DData Public "ModuleInterface" () ((variant "ModuleInterface" (ConNamed (field "miKey" (TyCon "ModuleKey")) (field "miKeyText" (TyCon "String")) (field "miSerial" (TyCon "Int")) (field "miRow" (TyCon "ModDiags")) (field "miExports" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "FrozenExport")))) (field "miFunNames" (TyApp (TyCon "List") (TyCon "String"))) (field "miDispatchIdx" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))) (field "miDataCtors" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyCon "DataVis") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant")))))) (field "miCtorPop" (TyApp (TyCon "SpellingPop") (TyCon "PubScheme"))) (field "miRecordPop" (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo"))) (field "miFunSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "miFunSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "miDeclared" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix")))) (field "miDeclaredQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CDeclaredPrefix")))) (field "miMethodSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "miMethodSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "miSchemeOblsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl"))))) (field "miExistentials" (TyApp (TyCon "List") (TyCon "Int"))) (field "miPatternAuth" (TyApp (TyCon "List") (TyCon "Int"))) (field "miAnyExistentials" (TyCon "Bool")) (field "miEvTable" (TyCon "EvTable")) (field "miBinders" (TyApp (TyCon "List") (TyCon "BinderRow"))) (field "miTopIds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))) (field "miMethodGrants" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "MethodGrant")))) (field "miTakers" (TyApp (TyCon "List") (TyCon "String"))) (field "miSticky" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (field "miInvocationView" (TyCon "PublishedInvocationView")) (field "miTrees" (TyApp (TyCon "Option") (TyCon "ModuleTrees")))))) ())
(DData Public "ModuleTrees" () ((variant "ModuleTrees" (ConNamed (field "mtMarked" (TyApp (TyCon "List") (TyCon "Decl"))) (field "mtEvidence" (TyCon "EvTable")) (field "mtTopIds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))) (field "mtLocalAbs" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "LocalAbs"))))) (field "mtLocalIds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))) (field "mtMethodGrants" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodGrant"))))) (field "mtSourceless" (TyApp (TyCon "List") (TyCon "Int"))) (field "mtBounds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "GrantBinder"))))))) (field "mtValueBounds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "GrantBinder"))))))) (field "mtPromoted" (TyApp (TyCon "List") (TyCon "String"))) (field "mtMain" (TyApp (TyCon "Option") (TyCon "PubScheme")))))) ())
(DData Abstract "ModuleRows" () ((variant "ModuleRows" (ConNamed (field "mrFunNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mrDispatchIdx" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))) (field "mrDataCtors" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyCon "DataVis") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant")))))) (field "mrFunSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "mrFunSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "mrDeclared" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix")))) (field "mrDeclaredQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CDeclaredPrefix")))) (field "mrMethodSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "mrMethodSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "mrSchemeOblsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl"))))) (field "mrExistentials" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "mrPatternAuth" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "mrAnyExistentials" (TyCon "Bool")) (field "mrEvTable" (TyCon "EvTable")) (field "mrBinders" (TyCon "BinderTypeTable")) (field "mrTopIds" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrMethodGrants" (TyApp (TyCon "OrdMap") (TyCon "MethodGrant"))) (field "mrTakers" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mrSticky" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (field "mrEvCounter" (TyCon "Int")) (field "mrSourceless" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "mrBounds" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "GrantBinder")))))) (field "mrValueBounds" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "GrantBinder"))))))))) ())
(DTypeSig true "captureModuleRows" (TyFun (TyCon "GraphCtx") (TyCon "ModuleRows")))
(DFunDef false "captureModuleRows" ((PVar "g")) (EBlock (DoLet false false (PVar "c") (EFieldAccess (EVar "g") "crossRun")) (DoLet false false (PVar "r") (EFieldAccess (EVar "g") "graphRun")) (DoExpr (ERecordCreate "ModuleRows" ((fa "mrFunNames" (EFieldAccess (EFieldAccess (EVar "c") "universeFunNamesRef") "value")) (fa "mrDispatchIdx" (EFieldAccess (EFieldAccess (EVar "c") "universeMethodDispatchIdxByIdRef") "value")) (fa "mrDataCtors" (EFieldAccess (EFieldAccess (EVar "c") "universeDataCtors") "value")) (fa "mrFunSlots" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsRef") "value")) (fa "mrFunSlotsQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsQualRef") "value")) (fa "mrDeclared" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredRef") "value")) (fa "mrDeclaredQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredQualRef") "value")) (fa "mrMethodSlots" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsRef") "value")) (fa "mrMethodSlotsQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsQualRef") "value")) (fa "mrSchemeOblsQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleSchemeOblsQualRef") "value")) (fa "mrExistentials" (EFieldAccess (EFieldAccess (EVar "r") "ctorExistentialsRef") "value")) (fa "mrPatternAuth" (EFieldAccess (EFieldAccess (EVar "r") "patternAuthIdsRef") "value")) (fa "mrAnyExistentials" (EFieldAccess (EFieldAccess (EVar "r") "anyExistentialsRef") "value")) (fa "mrEvTable" (EFieldAccess (EFieldAccess (EVar "r") "evTable") "value")) (fa "mrBinders" (EFieldAccess (EFieldAccess (EVar "r") "binderRows") "value")) (fa "mrTopIds" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsTopIds") "value")) (fa "mrMethodGrants" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsMethods") "value")) (fa "mrTakers" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsTakers") "value")) (fa "mrSticky" (EFieldAccess (EFieldAccess (EVar "g") "typeErrorsStickyDiags") "value")) (fa "mrEvCounter" (EFieldAccess (EFieldAccess (EVar "r") "evCounter") "value")) (fa "mrSourceless" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsSourceless") "value")) (fa "mrBounds" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsBounds") "value")) (fa "mrValueBounds" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsValueBounds") "value")))))))
(DTypeSig false "newPrefix" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "newPrefix" ((PVar "after") (PVar "before")) (EApp (EApp (EVar "take") (EBinOp "-" (EApp (EVar "listLen") (EVar "after")) (EApp (EVar "listLen") (EVar "before")))) (EVar "after")))
(DTypeSig false "zonkObls" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyApp (TyCon "List") (TyCon "VecObl"))))))
(DFunDef false "zonkObls" ((PVar "rows")) (EApp (EApp (EVar "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EApp (EVar "snd") (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkVecObl")) (EVar "emptyZonk")) (EApp (EVar "snd") (EVar "row"))))))) (EVar "rows")))
(DTypeSig false "freezeExport" (TyFun (TyCon "ExportBinding") (TyCon "FrozenExport")))
(DFunDef false "freezeExport" ((PVar "xb")) (EBlock (DoLet false false (PTuple (PVar "z") (PVar "s")) (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EFieldAccess (EVar "xb") "xbScheme"))) (DoExpr (ERecordCreate "FrozenExport" ((fa "feScheme" (ERecordCreate "PubScheme" ((fa "psScheme" (EVar "s")) (fa "psContext" (EListLit))))) (fa "feStandalone" (EApp (EApp (EVar "map") (ELam ((PVar "alt")) (ERecordCreate "PubScheme" ((fa "psScheme" (EApp (EVar "snd") (EApp (EApp (EVar "zonkScheme") (EVar "z")) (EVar "alt")))) (fa "psContext" (EListLit)))))) (EFieldAccess (EVar "xb") "xbStandalone"))) (fa "feExtern" (EFieldAccess (EVar "xb") "xbExtern")))))))
(DTypeSig false "thawExport" (TyFun (TyCon "FrozenExport") (TyCon "ExportBinding")))
(DFunDef false "thawExport" ((PVar "fe")) (EBlock (DoLet false false (PTuple (PVar "z") (PVar "s")) (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EFieldAccess (EFieldAccess (EVar "fe") "feScheme") "psScheme"))) (DoExpr (ERecordCreate "ExportBinding" ((fa "xbScheme" (EVar "s")) (fa "xbStandalone" (EApp (EApp (EVar "map") (ELam ((PVar "alt")) (EApp (EVar "snd") (EApp (EApp (EVar "zonkScheme") (EVar "z")) (EFieldAccess (EVar "alt") "psScheme"))))) (EFieldAccess (EVar "fe") "feStandalone"))) (fa "xbExtern" (EFieldAccess (EVar "fe") "feExtern")))))))
(DTypeSig true "freezeModuleInterface" (TyFun (TyCon "ModuleKey") (TyFun (TyCon "Int") (TyFun (TyCon "ModDiags") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyCon "ModuleRows") (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "ModuleTrees")) (TyCon "ModuleInterface")))))))))
(DFunDef false "freezeModuleInterface" ((PVar "key") (PVar "serial") (PVar "row") (PVar "exports") (PVar "before") (PVar "mctx") (PVar "trees")) (EBlock (DoLet false false (PVar "after") (EApp (EVar "captureModuleRows") (EFieldAccess (EVar "mctx") "mcGraph"))) (DoLet false false (PTuple (PVar "ctorPop") (PVar "recordPop")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ownPopsRef") "value")) (DoLet false false (PVar "existentials") (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrExistentials")) (EFieldAccess (EVar "before") "mrExistentials")))) (DoExpr (ERecordCreate "ModuleInterface" ((fa "miKey" (EVar "key")) (fa "miKeyText" (EApp (EVar "moduleKeyText") (EVar "key"))) (fa "miSerial" (EVar "serial")) (fa "miRow" (EVar "row")) (fa "miExports" (EApp (EApp (EVar "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EVar "freezeExport") (EApp (EVar "snd") (EVar "b")))))) (EVar "exports"))) (fa "miFunNames" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrFunNames")) (EFieldAccess (EVar "before") "mrFunNames")))) (fa "miDispatchIdx" (EApp (EApp (EVar "drop") (EApp (EVar "listLen") (EFieldAccess (EVar "before") "mrDispatchIdx"))) (EFieldAccess (EVar "after") "mrDispatchIdx"))) (fa "miDataCtors" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrDataCtors")) (EFieldAccess (EVar "before") "mrDataCtors"))) (fa "miCtorPop" (EApp (EApp (EVar "spMap") (EVar "freezeScheme")) (EVar "ctorPop"))) (fa "miRecordPop" (EApp (EApp (EVar "spMap") (EVar "zonkRecord")) (EVar "recordPop"))) (fa "miFunSlots" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrFunSlots")) (EFieldAccess (EVar "before") "mrFunSlots")))) (fa "miFunSlotsQual" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrFunSlotsQual")) (EFieldAccess (EVar "before") "mrFunSlotsQual")))) (fa "miDeclared" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrDeclared")) (EFieldAccess (EVar "before") "mrDeclared"))) (fa "miDeclaredQual" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrDeclaredQual")) (EFieldAccess (EVar "before") "mrDeclaredQual"))) (fa "miMethodSlots" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrMethodSlots")) (EFieldAccess (EVar "before") "mrMethodSlots")))) (fa "miMethodSlotsQual" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrMethodSlotsQual")) (EFieldAccess (EVar "before") "mrMethodSlotsQual")))) (fa "miSchemeOblsQual" (EApp (EVar "zonkObls") (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrSchemeOblsQual")) (EFieldAccess (EVar "before") "mrSchemeOblsQual")))) (fa "miExistentials" (EVar "existentials")) (fa "miPatternAuth" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrPatternAuth")) (EFieldAccess (EVar "before") "mrPatternAuth")))) (fa "miAnyExistentials" (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "existentials")) (EBinOp "&&" (EFieldAccess (EVar "after") "mrAnyExistentials") (EApp (EVar "not") (EFieldAccess (EVar "before") "mrAnyExistentials"))))) (fa "miEvTable" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrEvTable")) (EFieldAccess (EVar "before") "mrEvTable"))) (fa "miBinders" (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrBinders")) (EFieldAccess (EVar "before") "mrBinders"))))) (fa "miTopIds" (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrTopIds")) (EFieldAccess (EVar "before") "mrTopIds")))) (fa "miMethodGrants" (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrMethodGrants")) (EFieldAccess (EVar "before") "mrMethodGrants")))) (fa "miTakers" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrTakers")) (EFieldAccess (EVar "before") "mrTakers")))) (fa "miSticky" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrSticky")) (EFieldAccess (EVar "before") "mrSticky"))) (fa "miInvocationView" (EApp (EVar "publishInvocationView") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "invocationViewRef") "value"))) (fa "miTrees" (EVar "trees")))))))
(DTypeSig true "freezeModuleTrees" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyCon "ModuleRows") (TyFun (TyCon "ModuleCtx") (TyCon "ModuleTrees")))))))
(DFunDef false "freezeModuleTrees" ((PVar "mid") (PVar "marked") (PVar "published") (PVar "before") (PVar "mctx")) (EBlock (DoLet false false (PVar "r") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "gs") (EFieldAccess (EVar "r") "grants")) (DoLet false false (PVar "locals") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "localAbs") "lasMinted") "value")) (DoExpr (ERecordCreate "ModuleTrees" ((fa "mtMarked" (EVar "marked")) (fa "mtEvidence" (EApp (EApp (EVar "cellEntriesFrom") (EVar "r")) (EFieldAccess (EVar "before") "mrEvCounter"))) (fa "mtTopIds" (EApp (EApp (EVar "idsUnder") (EApp (EApp (EVar "map") (EApp (EVar "grantTopKey") (EVar "mid"))) (EApp (EVar "topBinderNames") (EVar "marked")))) (EFieldAccess (EFieldAccess (EVar "gs") "gsTopIds") "value"))) (fa "mtLocalAbs" (EApp (EApp (EVar "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EApp (EApp (EVar "map") (EVar "zonkLocalAbs")) (EApp (EVar "snd") (EVar "row")))))) (EApp (EVar "M.entries") (EApp (EApp (EVar "omRestrict") (EVar "locals")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "localAbs") "lasBinders") "value"))))) (fa "mtLocalIds" (EApp (EApp (EVar "idsUnder") (EVar "locals")) (EFieldAccess (EFieldAccess (EVar "gs") "gsLocalIds") "value"))) (fa "mtMethodGrants" (EApp (EApp (EVar "map") (ELam ((PVar "k")) (ETuple (EVar "k") (EApp (EApp (EVar "omLookup") (EVar "k")) (EFieldAccess (EFieldAccess (EVar "gs") "gsMethods") "value"))))) (EApp (EVar "methodGrantKeys") (EVar "marked")))) (fa "mtSourceless" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EFieldAccess (EVar "gs") "gsSourceless") "value")) (EFieldAccess (EVar "before") "mrSourceless")))) (fa "mtBounds" (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EFieldAccess (EVar "gs") "gsBounds") "value")) (EFieldAccess (EVar "before") "mrBounds")))) (fa "mtValueBounds" (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EFieldAccess (EVar "gs") "gsValueBounds") "value")) (EFieldAccess (EVar "before") "mrValueBounds")))) (fa "mtPromoted" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "promotedRef") "value")) (fa "mtMain" (EApp (EApp (EVar "lookupAssoc") (ELit (LString "main"))) (EVar "published"))))))))
(DTypeSig true "applyModuleTrees" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ModuleTrees") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "applyModuleTrees" ((PVar "g") (PVar "t")) (EBlock (DoLet false false (PVar "r") (EFieldAccess (EVar "g") "graphRun")) (DoLet false false (PVar "gs") (EFieldAccess (EVar "r") "grants")) (DoLet false false (PVar "las") (EFieldAccess (EVar "r") "localAbs")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "evTable")) (EBinOp "++" (EFieldAccess (EVar "t") "mtEvidence") (EFieldAccess (EFieldAccess (EVar "r") "evTable") "value")))) (DoExpr (EApp (EApp (EVar "each") (EApp (EVar "setGrantIds") (EFieldAccess (EVar "gs") "gsTopIds"))) (EFieldAccess (EVar "t") "mtTopIds"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "row")) (EApp (EApp (EApp (EVar "forgetLocalRows") (EVar "las")) (EVar "gs")) (EApp (EVar "fst") (EVar "row"))))) (EFieldAccess (EVar "t") "mtLocalIds"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "las") "lasBinders")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EApp (EApp (EVar "map") (EVar "zonkLocalAbs")) (EApp (EVar "snd") (EVar "row")))))) (EFieldAccess (EVar "t") "mtLocalAbs"))) (EFieldAccess (EFieldAccess (EVar "las") "lasBinders") "value")))) (DoExpr (EApp (EApp (EVar "each") (EApp (EVar "setGrantIds") (EFieldAccess (EVar "gs") "gsLocalIds"))) (EFieldAccess (EVar "t") "mtLocalIds"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsMethods")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "row")) (EMatch (EApp (EVar "snd") (EVar "row")) (arm (PCon "Some" (PVar "mg")) () (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "fst") (EVar "row"))) (EVar "mg")) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EVar "omDelete") (EApp (EVar "fst") (EVar "row"))) (EVar "acc")))))) (EFieldAccess (EFieldAccess (EVar "gs") "gsMethods") "value")) (EFieldAccess (EVar "t") "mtMethodGrants")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsSourceless")) (EApp (EApp (EVar "insertIds") (EFieldAccess (EVar "t") "mtSourceless")) (EFieldAccess (EFieldAccess (EVar "gs") "gsSourceless") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsBounds")) (EApp (EApp (EVar "omFromPairs") (EFieldAccess (EVar "t") "mtBounds")) (EFieldAccess (EFieldAccess (EVar "gs") "gsBounds") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsValueBounds")) (EApp (EApp (EVar "omFromPairs") (EFieldAccess (EVar "t") "mtValueBounds")) (EFieldAccess (EFieldAccess (EVar "gs") "gsValueBounds") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "promotionHarvestRef")) (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "promotionHarvestRef") "value") (EFieldAccess (EVar "t") "mtPromoted"))))) (DoExpr (EMatch (EFieldAccess (EVar "t") "mtMain") (arm (PCon "Some" (PVar "p")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "mainSchemeRef")) (EApp (EVar "Some") (EApp (EVar "thawScheme") (EVar "p"))))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EFieldAccess (EVar "t") "mtMarked"))))
(DTypeSig false "zonkLocalAbs" (TyFun (TyCon "LocalAbs") (TyCon "LocalAbs")))
(DFunDef false "zonkLocalAbs" ((PVar "la")) (ERecordUpdate (EVar "la") ((fa "laSlots" (EApp (EApp (EVar "map") (EVar "zonkSlot")) (EFieldAccess (EVar "la") "laSlots"))))))
(DTypeSig true "forgetLocalRows" (TyFun (TyCon "LocalAbsState") (TyFun (TyCon "GrantState") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "forgetLocalRows" ((PVar "las") (PVar "gs") (PVar "name")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "las") "lasBinders")) (EApp (EApp (EVar "omDelete") (EVar "name")) (EFieldAccess (EFieldAccess (EVar "las") "lasBinders") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "las") "lasRecOccs")) (EApp (EApp (EVar "omDelete") (EVar "name")) (EFieldAccess (EFieldAccess (EVar "las") "lasRecOccs") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsLocalIds")) (EApp (EApp (EVar "omDelete") (EVar "name")) (EFieldAccess (EFieldAccess (EVar "gs") "gsLocalIds") "value"))))))
(DTypeSig false "methodGrantKeys" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodGrantKeys" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "declMethodGrantKeys")) (EVar "prog")))
(DTypeSig false "declMethodGrantKeys" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declMethodGrantKeys" ((PRec "DInterface" ((rf "name" None) (rf "methods" None) (rf "ifaceOrigin" None)) true)) (EApp (EApp (EVar "map") (ELam ((PCon "IfaceMethod" (PVar "m") PWild PWild PWild)) (EApp (EApp (EVar "methodGrantKey") (EApp (EApp (EVar "ifaceWordOf") (EVar "ifaceOrigin")) (EVar "name"))) (EVar "m")))) (EVar "methods")))
(DFunDef false "declMethodGrantKeys" (PWild) (EListLit))
(DTypeSig false "idsUnder" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "idsUnder" ((PVar "keys") (PVar "table")) (EApp (EApp (EVar "map") (ELam ((PVar "k")) (ETuple (EVar "k") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "table")))))) (EVar "keys")))
(DTypeSig false "topBinderNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topBinderNames" ((PVar "prog")) (EApp (EVar "dedup") (EApp (EApp (EVar "flatMap") (EVar "declBinderNames")) (EVar "prog"))))
(DTypeSig true "cellEntriesFrom" (TyFun (TyCon "GraphRun") (TyFun (TyCon "Int") (TyCon "EvTable"))))
(DFunDef false "cellEntriesFrom" ((PVar "r") (PVar "lo")) (EBlock (DoLet false false (PVar "from") (EApp (EApp (EVar "max") (ELit (LInt 0))) (EBinOp "-" (EVar "lo") (EFieldAccess (EVar "r") "evBase")))) (DoLet false false (PVar "cells") (EFieldAccess (EFieldAccess (EVar "r") "evCells") "value")) (DoLet false false (PVar "sites") (EFieldAccess (EFieldAccess (EVar "r") "siteCells") "value")) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "methodCellEntriesFrom") (EVar "cells")) (EVar "from")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "cells")) (ELit (LInt 1)))) (EListLit)) (EApp (EApp (EApp (EApp (EVar "siteCellEntriesFrom") (EVar "sites")) (EVar "from")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "sites")) (ELit (LInt 1)))) (EListLit))))))
(DTypeSig false "methodCellEntriesFrom" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvCell"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "EvTable") (TyCon "EvTable"))))))
(DFunDef false "methodCellEntriesFrom" ((PVar "arr") (PVar "lo") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (EVar "lo")) (EVar "acc") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "methodCellEntriesFrom") (EVar "arr")) (EVar "lo")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))) (arm (PCon "Some" (PVar "c")) () (EBlock (DoLet false false (PVar "arity") (EApp (EApp (EVar "optionOrPanic") (ELit (LString "method cell published before its selected scheme supplied an arity"))) (EFieldAccess (EFieldAccess (EVar "c") "ecArity") "value"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "methodCellEntriesFrom") (EVar "arr")) (EVar "lo")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "EvEntry") (EFieldAccess (EVar "c") "ecId")) (EApp (EApp (EApp (EApp (EApp (EVar "EvMethod") (EFieldAccess (EFieldAccess (EVar "c") "ecIface") "value")) (EVar "arity")) (EFieldAccess (EFieldAccess (EVar "c") "ecTag") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecImpl") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecMeth") "value"))) (EVar "acc"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "siteCellEntriesFrom" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyTuple (TyCon "EvId") (TyCon "SiteCell")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "EvTable") (TyCon "EvTable"))))))
(DFunDef false "siteCellEntriesFrom" ((PVar "arr") (PVar "lo") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (EVar "lo")) (EVar "acc") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "siteCellEntriesFrom") (EVar "arr")) (EVar "lo")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))) (arm (PCon "Some" (PTuple (PVar "ev") (PVar "c"))) () (EApp (EApp (EApp (EApp (EVar "siteCellEntriesFrom") (EVar "arr")) (EVar "lo")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "EvEntry") (EVar "ev")) (EApp (EVar "siteCellValue") (EVar "c"))) (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "siteCellValue" (TyFun (TyCon "SiteCell") (TyCon "EvVal")))
(DFunDef false "siteCellValue" ((PCon "OpSite" (PVar "r"))) (EApp (EVar "EvOne") (EFieldAccess (EVar "r") "value")))
(DFunDef false "siteCellValue" ((PCon "LitSite" (PVar "f") (PVar "r"))) (EApp (EApp (EVar "EvLit") (EFieldAccess (EVar "f") "value")) (EFieldAccess (EVar "r") "value")))
(DFunDef false "siteCellValue" ((PCon "HeadSite" (PVar "h"))) (EApp (EVar "EvHead") (EFieldAccess (EVar "h") "value")))
(DTypeSig true "setServedArity" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "setServedArity" ((PVar "idx") (PVar "ev") (PVar "arity")) (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (ELit (LString "served method occurrence"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvMethod" (PVar "iface") PWild (PVar "tag") (PVar "impls") (PVar "meths"))) () (EApp (EApp (EVar "replaceEntryIn") (EVar "idx")) (EApp (EApp (EVar "EvEntry") (EVar "ev")) (EApp (EApp (EApp (EApp (EApp (EVar "EvMethod") (EVar "iface")) (EVar "arity")) (EVar "tag")) (EVar "impls")) (EVar "meths"))))) (arm (PCon "Ok" PWild) () (EApp (EVar "panic") (ELit (LString "evidence table: a method occurrence answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "servedEntriesFrom" (TyFun (TyCon "EvIndex") (TyFun (TyCon "Int") (TyFun (TyCon "EvTable") (TyCon "EvTable")))))
(DFunDef false "servedEntriesFrom" ((PVar "idx") (PVar "base") (PVar "rows")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "servedEntryIn") (EVar "idx")) (EVar "base"))) (EVar "rows")))
(DTypeSig false "servedEntryIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "Int") (TyFun (TyCon "EvEntry") (TyCon "EvEntry")))))
(DFunDef false "servedEntryIn" ((PVar "idx") (PVar "base") (PAs "e" (PCon "EvEntry" (PVar "ev") (PCon "EvMethod" PWild PWild PWild PWild PWild)))) (EBlock (DoLet false false (PCon "EvId" PWild (PVar "i")) (EVar "ev")) (DoExpr (EIf (EBinOp "<" (EVar "i") (EVar "base")) (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (ELit (LString "served method occurrence"))) (EVar "ev")) (arm (PCon "Ok" (PVar "v")) () (EApp (EApp (EVar "EvEntry") (EVar "ev")) (EVar "v"))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))) (EVar "e")))))
(DFunDef false "servedEntryIn" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "mergePop" (TyFun (TyApp (TyCon "SpellingPop") (TyVar "a")) (TyFun (TyApp (TyCon "SpellingPop") (TyVar "a")) (TyApp (TyCon "SpellingPop") (TyVar "a")))))
(DFunDef false "mergePop" ((PVar "own") (PVar "pop")) (EBlock (DoLet false false (PVar "rows") (EApp (EVar "spRows") (EVar "own"))) (DoLet false false (PVar "withRows") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "e")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "row")) (EApp (EApp (EApp (EVar "insertRow") (EApp (EVar "fst") (EVar "e"))) (EVar "row")) (EVar "acc2")))) (EVar "acc")) (EApp (EVar "snd") (EVar "e"))))) (EVar "pop")) (EApp (EVar "M.entries") (EVar "rows")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "e")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "rows")) (EVar "acc") (EApp (EApp (EApp (EApp (EApp (EVar "spInsert") (EVar "None")) (EApp (EVar "fst") (EVar "e"))) (ELit (LString ""))) (EApp (EVar "snd") (EVar "e"))) (EVar "acc"))))) (EVar "withRows")) (EApp (EVar "M.entries") (EApp (EVar "spFloor") (EVar "own")))))))
(DTypeSig false "insertRow" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyCon "String") (TyVar "a")) (TyFun (TyApp (TyCon "SpellingPop") (TyVar "a")) (TyApp (TyCon "SpellingPop") (TyVar "a"))))))
(DFunDef false "insertRow" ((PVar "spelling") (PTuple (PVar "ident") (PVar "owner") (PVar "payload")) (PVar "pop")) (EApp (EApp (EApp (EApp (EApp (EVar "spInsert") (EApp (EVar "Some") (EVar "ident"))) (EVar "spelling")) (EVar "owner")) (EVar "payload")) (EVar "pop")))
(DTypeSig false "insertIds" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "insertIds" ((PVar "ids") (PVar "m")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "i")) (EApp (EApp (EApp (EVar "M.set") (EVar "i")) (ELit LUnit)) (EVar "acc")))) (EVar "m")) (EVar "ids")))
(DTypeSig true "applyModuleInterface" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ModuleInterface") (TyTuple (TyCon "ModDiags") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding")))))))
(DFunDef false "applyModuleInterface" ((PVar "g") (PVar "mi")) (EBlock (DoLet false false (PVar "c") (EFieldAccess (EVar "g") "crossRun")) (DoLet false false (PVar "r") (EFieldAccess (EVar "g") "graphRun")) (DoLet false false (PVar "gs") (EFieldAccess (EVar "r") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "universeFunNamesRef")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "c") "universeFunNamesRef") "value")) (EFieldAccess (EVar "mi") "miFunNames")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "universeMethodDispatchIdxByIdRef")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "c") "universeMethodDispatchIdxByIdRef") "value") (EFieldAccess (EVar "mi") "miDispatchIdx")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "universeDataCtors")) (EBinOp "++" (EFieldAccess (EVar "mi") "miDataCtors") (EFieldAccess (EFieldAccess (EVar "c") "universeDataCtors") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "universeCtorPop")) (EApp (EApp (EVar "mergePop") (EApp (EApp (EVar "spMap") (EVar "thawScheme")) (EFieldAccess (EVar "mi") "miCtorPop"))) (EFieldAccess (EFieldAccess (EVar "c") "universeCtorPop") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "universeRecordPop")) (EApp (EApp (EVar "mergePop") (EApp (EApp (EVar "spMap") (EVar "zonkRecord")) (EFieldAccess (EVar "mi") "miRecordPop"))) (EFieldAccess (EFieldAccess (EVar "c") "universeRecordPop") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsRef")) (EBinOp "++" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EFieldAccess (EVar "mi") "miFunSlots")) (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsQualRef")) (EBinOp "++" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EFieldAccess (EVar "mi") "miFunSlotsQual")) (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredRef")) (EBinOp "++" (EFieldAccess (EVar "mi") "miDeclared") (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredQualRef")) (EBinOp "++" (EFieldAccess (EVar "mi") "miDeclaredQual") (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsRef")) (EBinOp "++" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EFieldAccess (EVar "mi") "miMethodSlots")) (EFieldAccess (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsQualRef")) (EBinOp "++" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EFieldAccess (EVar "mi") "miMethodSlotsQual")) (EFieldAccess (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleSchemeOblsQualRef")) (EBinOp "++" (EApp (EVar "zonkObls") (EFieldAccess (EVar "mi") "miSchemeOblsQual")) (EFieldAccess (EFieldAccess (EVar "c") "crossModuleSchemeOblsQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "ctorExistentialsRef")) (EApp (EApp (EVar "insertIds") (EFieldAccess (EVar "mi") "miExistentials")) (EFieldAccess (EFieldAccess (EVar "r") "ctorExistentialsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "patternAuthIdsRef")) (EApp (EApp (EVar "insertIds") (EFieldAccess (EVar "mi") "miPatternAuth")) (EFieldAccess (EFieldAccess (EVar "r") "patternAuthIdsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "anyExistentialsRef")) (EBinOp "||" (EFieldAccess (EFieldAccess (EVar "r") "anyExistentialsRef") "value") (EFieldAccess (EVar "mi") "miAnyExistentials")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "evTable")) (EBinOp "++" (EFieldAccess (EVar "mi") "miEvTable") (EFieldAccess (EFieldAccess (EVar "r") "evTable") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "binderRows")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "row")) (EApp (EApp (EVar "addBinderRow") (EVar "row")) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "r") "binderRows") "value")) (EFieldAccess (EVar "mi") "miBinders")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsTopIds")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "e")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "gs") "gsTopIds") "value")) (EFieldAccess (EVar "mi") "miTopIds")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsMethods")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "e")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "gs") "gsMethods") "value")) (EFieldAccess (EVar "mi") "miMethodGrants")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsTakers")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "gs") "gsTakers") "value")) (EFieldAccess (EVar "mi") "miTakers")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "typeErrorsSticky")) (EBinOp "||" (EFieldAccess (EFieldAccess (EVar "g") "typeErrorsSticky") "value") (EApp (EVar "isNonEmptyL") (EFieldAccess (EVar "mi") "miSticky"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "typeErrorsStickyDiags")) (EBinOp "++" (EFieldAccess (EVar "mi") "miSticky") (EFieldAccess (EFieldAccess (EVar "g") "typeErrorsStickyDiags") "value")))) (DoExpr (ETuple (EFieldAccess (EVar "mi") "miRow") (EApp (EApp (EVar "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EVar "thawExport") (EApp (EVar "snd") (EVar "b")))))) (EFieldAccess (EVar "mi") "miExports"))))))
(DData Private "ModuleCache" () ((variant "ModuleCache" (ConNamed (field "mcEntries" (TyApp (TyCon "OrdMap") (TyCon "ModuleInterface"))) (field "mcSerial" (TyCon "Int"))))) ())
(DTypeSig false "moduleCacheRef" (TyApp (TyCon "Ref") (TyCon "ModuleCache")))
(DFunDef false "moduleCacheRef" () (EApp (EVar "Ref") (ERecordCreate "ModuleCache" ((fa "mcEntries" (EVar "omEmpty")) (fa "mcSerial" (ELit (LInt 0)))))))
(DTypeSig true "freshModuleSerial" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "freshModuleSerial" (PWild) (EBlock (DoLet false false (PVar "cache") (EFieldAccess (EVar "moduleCacheRef") "value")) (DoLet false false (PVar "next") (EBinOp "+" (EFieldAccess (EVar "cache") "mcSerial") (ELit (LInt 1)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "moduleCacheRef")) (ERecordUpdate (EVar "cache") ((fa "mcSerial" (EVar "next")))))) (DoExpr (EVar "next"))))
(DTypeSig true "moduleInterfaceIdentity" (TyFun (TyCon "ModuleInterface") (TyCon "String")))
(DFunDef false "moduleInterfaceIdentity" ((PVar "mi")) (EApp (EVar "intToString") (EFieldAccess (EVar "mi") "miSerial")))
(DTypeSig true "moduleCacheHit" (TyFun (TyCon "ModuleKey") (TyApp (TyCon "Option") (TyCon "ModuleInterface"))))
(DFunDef false "moduleCacheHit" ((PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "key") "mkModule")) (EFieldAccess (EFieldAccess (EVar "moduleCacheRef") "value") "mcEntries")) (arm (PCon "Some" (PVar "mi")) () (EIf (EBinOp "==" (EFieldAccess (EVar "mi") "miKeyText") (EApp (EVar "moduleKeyText") (EVar "key"))) (EApp (EVar "Some") (EVar "mi")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "recordModuleInterface" (TyFun (TyCon "ModuleInterface") (TyCon "Unit")))
(DFunDef false "recordModuleInterface" ((PVar "mi")) (EApp (EApp (EVar "setRef") (EVar "moduleCacheRef")) (EApp (EApp (EVar "withInterface") (EFieldAccess (EVar "moduleCacheRef") "value")) (EVar "mi"))))
(DTypeSig true "retainModuleInterfaces" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))
(DFunDef false "retainModuleInterfaces" ((PVar "mids")) (EBlock (DoLet false false (PVar "cache") (EFieldAccess (EVar "moduleCacheRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "moduleCacheRef")) (ERecordUpdate (EVar "cache") ((fa "mcEntries" (EApp (EApp (EVar "omRestrict") (EVar "mids")) (EFieldAccess (EVar "cache") "mcEntries")))))))))
(DTypeSig true "seedModuleInterfaces" (TyFun (TyApp (TyCon "List") (TyCon "ModuleInterface")) (TyCon "Unit")))
(DFunDef false "seedModuleInterfaces" ((PVar "mis")) (EApp (EApp (EVar "setRef") (EVar "moduleCacheRef")) (EApp (EApp (EApp (EVar "fold") (EVar "withInterface")) (EFieldAccess (EVar "moduleCacheRef") "value")) (EVar "mis"))))
(DTypeSig false "withInterface" (TyFun (TyCon "ModuleCache") (TyFun (TyCon "ModuleInterface") (TyCon "ModuleCache"))))
(DFunDef false "withInterface" ((PVar "cache") (PVar "mi")) (ERecordCreate "ModuleCache" ((fa "mcEntries" (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EFieldAccess (EVar "mi") "miKey") "mkModule")) (EVar "mi")) (EFieldAccess (EVar "cache") "mcEntries"))) (fa "mcSerial" (EApp (EApp (EVar "max") (EFieldAccess (EVar "cache") "mcSerial")) (EFieldAccess (EVar "mi") "miSerial"))))))
(DTypeSig true "currentModuleInterfaces" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "ModuleInterface"))))
(DFunDef false "currentModuleInterfaces" (PWild) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "M.entries") (EFieldAccess (EFieldAccess (EVar "moduleCacheRef") "value") "mcEntries"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "TabKey" false) (mem "DataVis" false) (mem "Variant" false) (mem "EvTable" false) (mem "Ident" false) (mem "Decl" true) (mem "EvEntry" true) (mem "EvVal" true) (mem "EvId" true) (mem "IfaceMethod" true) (mem "declBinderNames" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "take" false) (mem "mapAccumL" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omDelete" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omRestrict" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "lenKey" false) (mem "listLen" false) (mem "isNonEmptyL" false) (mem "dedup" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("types" "invocation_basis") ((mem "publishInvocationView" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "freezeScheme" false) (mem "thawScheme" false) (mem "zonkSlot" false) (mem "zonkMethodSlot" false) (mem "zonkRecord" false) (mem "mapSlots" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ModDiags" false) (mem "PubScheme" true) (mem "TcDiag" false) (mem "emptyZonk" false) (mem "zonkScheme" false) (mem "zonkVecObl" false))))
(DUse false (UseGroup ("types" "registry") ((mem "SpellingPop" false) (mem "spInsert" false) (mem "spMap" false) (mem "spRows" false) (mem "spFloor" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" false) (mem "Mono" false) (mem "VecObl" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "EvIndex" false) (mem "evidenceLookup" false) (mem "ifaceWordOf" false) (mem "replaceEntryIn" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" false) (mem "BinderTypeTable" false) (mem "addBinderRow" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "GraphCtx" true) (mem "CrossRun" true) (mem "GraphRun" true) (mem "GrantState" true) (mem "ModuleCtx" true) (mem "ModuleCells" true) (mem "ExportBinding" true) (mem "PredicateSlot" false) (mem "MethodPredicateSlot" false) (mem "CDeclaredPrefix" false) (mem "RecordInfo" false) (mem "MethodGrant" false) (mem "PublishedInvocationView" false) (mem "EvCell" true) (mem "SiteCell" true) (mem "LocalAbs" true) (mem "LocalAbsState" true) (mem "GrantBinder" false) (mem "grantTopKey" false) (mem "methodGrantKey" false) (mem "setGrantIds" false))))
(DData Public "ModuleKey" () ((variant "ModuleKey" (ConNamed (field "mkModule" (TyCon "String")) (field "mkSource" (TyCon "String")) (field "mkImports" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "mkGraph" (TyCon "String"))))) ())
(DTypeSig true "moduleKeyText" (TyFun (TyCon "ModuleKey") (TyCon "String")))
(DFunDef false "moduleKeyText" ((PVar "k")) (EApp (EVar "joinNl") (EBinOp "++" (EListLit (EApp (EVar "lenKey") (EFieldAccess (EVar "k") "mkModule")) (EApp (EVar "lenKey") (EFieldAccess (EVar "k") "mkSource")) (EApp (EVar "lenKey") (EFieldAccess (EVar "k") "mkGraph"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "imp")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EApp (EVar "fst") (EVar "imp"))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EApp (EVar "snd") (EVar "imp"))))) (ELit (LString ""))))) (EFieldAccess (EVar "k") "mkImports")))))
(DData Public "FrozenExport" () ((variant "FrozenExport" (ConNamed (field "feScheme" (TyCon "PubScheme")) (field "feStandalone" (TyApp (TyCon "Option") (TyCon "PubScheme"))) (field "feExtern" (TyCon "Bool"))))) ())
(DData Public "ModuleInterface" () ((variant "ModuleInterface" (ConNamed (field "miKey" (TyCon "ModuleKey")) (field "miKeyText" (TyCon "String")) (field "miSerial" (TyCon "Int")) (field "miRow" (TyCon "ModDiags")) (field "miExports" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "FrozenExport")))) (field "miFunNames" (TyApp (TyCon "List") (TyCon "String"))) (field "miDispatchIdx" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))) (field "miDataCtors" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyCon "DataVis") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant")))))) (field "miCtorPop" (TyApp (TyCon "SpellingPop") (TyCon "PubScheme"))) (field "miRecordPop" (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo"))) (field "miFunSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "miFunSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "miDeclared" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix")))) (field "miDeclaredQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CDeclaredPrefix")))) (field "miMethodSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "miMethodSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "miSchemeOblsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl"))))) (field "miExistentials" (TyApp (TyCon "List") (TyCon "Int"))) (field "miPatternAuth" (TyApp (TyCon "List") (TyCon "Int"))) (field "miAnyExistentials" (TyCon "Bool")) (field "miEvTable" (TyCon "EvTable")) (field "miBinders" (TyApp (TyCon "List") (TyCon "BinderRow"))) (field "miTopIds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))) (field "miMethodGrants" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "MethodGrant")))) (field "miTakers" (TyApp (TyCon "List") (TyCon "String"))) (field "miSticky" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (field "miInvocationView" (TyCon "PublishedInvocationView")) (field "miTrees" (TyApp (TyCon "Option") (TyCon "ModuleTrees")))))) ())
(DData Public "ModuleTrees" () ((variant "ModuleTrees" (ConNamed (field "mtMarked" (TyApp (TyCon "List") (TyCon "Decl"))) (field "mtEvidence" (TyCon "EvTable")) (field "mtTopIds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))) (field "mtLocalAbs" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "LocalAbs"))))) (field "mtLocalIds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))) (field "mtMethodGrants" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodGrant"))))) (field "mtSourceless" (TyApp (TyCon "List") (TyCon "Int"))) (field "mtBounds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "GrantBinder"))))))) (field "mtValueBounds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "GrantBinder"))))))) (field "mtPromoted" (TyApp (TyCon "List") (TyCon "String"))) (field "mtMain" (TyApp (TyCon "Option") (TyCon "PubScheme")))))) ())
(DData Abstract "ModuleRows" () ((variant "ModuleRows" (ConNamed (field "mrFunNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mrDispatchIdx" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))) (field "mrDataCtors" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyCon "DataVis") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant")))))) (field "mrFunSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "mrFunSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "mrDeclared" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix")))) (field "mrDeclaredQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CDeclaredPrefix")))) (field "mrMethodSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "mrMethodSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "mrSchemeOblsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl"))))) (field "mrExistentials" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "mrPatternAuth" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "mrAnyExistentials" (TyCon "Bool")) (field "mrEvTable" (TyCon "EvTable")) (field "mrBinders" (TyCon "BinderTypeTable")) (field "mrTopIds" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrMethodGrants" (TyApp (TyCon "OrdMap") (TyCon "MethodGrant"))) (field "mrTakers" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mrSticky" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (field "mrEvCounter" (TyCon "Int")) (field "mrSourceless" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "mrBounds" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "EffRow") (TyApp (TyCon "List") (TyCon "GrantBinder")))))) (field "mrValueBounds" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "GrantBinder"))))))))) ())
(DTypeSig true "captureModuleRows" (TyFun (TyCon "GraphCtx") (TyCon "ModuleRows")))
(DFunDef false "captureModuleRows" ((PVar "g")) (EBlock (DoLet false false (PVar "c") (EFieldAccess (EVar "g") "crossRun")) (DoLet false false (PVar "r") (EFieldAccess (EVar "g") "graphRun")) (DoExpr (ERecordCreate "ModuleRows" ((fa "mrFunNames" (EFieldAccess (EFieldAccess (EVar "c") "universeFunNamesRef") "value")) (fa "mrDispatchIdx" (EFieldAccess (EFieldAccess (EVar "c") "universeMethodDispatchIdxByIdRef") "value")) (fa "mrDataCtors" (EFieldAccess (EFieldAccess (EVar "c") "universeDataCtors") "value")) (fa "mrFunSlots" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsRef") "value")) (fa "mrFunSlotsQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsQualRef") "value")) (fa "mrDeclared" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredRef") "value")) (fa "mrDeclaredQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredQualRef") "value")) (fa "mrMethodSlots" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsRef") "value")) (fa "mrMethodSlotsQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsQualRef") "value")) (fa "mrSchemeOblsQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleSchemeOblsQualRef") "value")) (fa "mrExistentials" (EFieldAccess (EFieldAccess (EVar "r") "ctorExistentialsRef") "value")) (fa "mrPatternAuth" (EFieldAccess (EFieldAccess (EVar "r") "patternAuthIdsRef") "value")) (fa "mrAnyExistentials" (EFieldAccess (EFieldAccess (EVar "r") "anyExistentialsRef") "value")) (fa "mrEvTable" (EFieldAccess (EFieldAccess (EVar "r") "evTable") "value")) (fa "mrBinders" (EFieldAccess (EFieldAccess (EVar "r") "binderRows") "value")) (fa "mrTopIds" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsTopIds") "value")) (fa "mrMethodGrants" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsMethods") "value")) (fa "mrTakers" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsTakers") "value")) (fa "mrSticky" (EFieldAccess (EFieldAccess (EVar "g") "typeErrorsStickyDiags") "value")) (fa "mrEvCounter" (EFieldAccess (EFieldAccess (EVar "r") "evCounter") "value")) (fa "mrSourceless" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsSourceless") "value")) (fa "mrBounds" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsBounds") "value")) (fa "mrValueBounds" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsValueBounds") "value")))))))
(DTypeSig false "newPrefix" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "newPrefix" ((PVar "after") (PVar "before")) (EApp (EApp (EVar "take") (EBinOp "-" (EApp (EVar "listLen") (EVar "after")) (EApp (EVar "listLen") (EVar "before")))) (EVar "after")))
(DTypeSig false "zonkObls" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyApp (TyCon "List") (TyCon "VecObl"))))))
(DFunDef false "zonkObls" ((PVar "rows")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EApp (EVar "snd") (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkVecObl")) (EVar "emptyZonk")) (EApp (EVar "snd") (EVar "row"))))))) (EVar "rows")))
(DTypeSig false "freezeExport" (TyFun (TyCon "ExportBinding") (TyCon "FrozenExport")))
(DFunDef false "freezeExport" ((PVar "xb")) (EBlock (DoLet false false (PTuple (PVar "z") (PVar "s")) (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EFieldAccess (EVar "xb") "xbScheme"))) (DoExpr (ERecordCreate "FrozenExport" ((fa "feScheme" (ERecordCreate "PubScheme" ((fa "psScheme" (EVar "s")) (fa "psContext" (EListLit))))) (fa "feStandalone" (EApp (EApp (EMethodRef "map") (ELam ((PVar "alt")) (ERecordCreate "PubScheme" ((fa "psScheme" (EApp (EVar "snd") (EApp (EApp (EVar "zonkScheme") (EVar "z")) (EVar "alt")))) (fa "psContext" (EListLit)))))) (EFieldAccess (EVar "xb") "xbStandalone"))) (fa "feExtern" (EFieldAccess (EVar "xb") "xbExtern")))))))
(DTypeSig false "thawExport" (TyFun (TyCon "FrozenExport") (TyCon "ExportBinding")))
(DFunDef false "thawExport" ((PVar "fe")) (EBlock (DoLet false false (PTuple (PVar "z") (PVar "s")) (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EFieldAccess (EFieldAccess (EVar "fe") "feScheme") "psScheme"))) (DoExpr (ERecordCreate "ExportBinding" ((fa "xbScheme" (EVar "s")) (fa "xbStandalone" (EApp (EApp (EMethodRef "map") (ELam ((PVar "alt")) (EApp (EVar "snd") (EApp (EApp (EVar "zonkScheme") (EVar "z")) (EFieldAccess (EVar "alt") "psScheme"))))) (EFieldAccess (EVar "fe") "feStandalone"))) (fa "xbExtern" (EFieldAccess (EVar "fe") "feExtern")))))))
(DTypeSig true "freezeModuleInterface" (TyFun (TyCon "ModuleKey") (TyFun (TyCon "Int") (TyFun (TyCon "ModDiags") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyCon "ModuleRows") (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "ModuleTrees")) (TyCon "ModuleInterface")))))))))
(DFunDef false "freezeModuleInterface" ((PVar "key") (PVar "serial") (PVar "row") (PVar "exports") (PVar "before") (PVar "mctx") (PVar "trees")) (EBlock (DoLet false false (PVar "after") (EApp (EVar "captureModuleRows") (EFieldAccess (EVar "mctx") "mcGraph"))) (DoLet false false (PTuple (PVar "ctorPop") (PVar "recordPop")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ownPopsRef") "value")) (DoLet false false (PVar "existentials") (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrExistentials")) (EFieldAccess (EVar "before") "mrExistentials")))) (DoExpr (ERecordCreate "ModuleInterface" ((fa "miKey" (EVar "key")) (fa "miKeyText" (EApp (EVar "moduleKeyText") (EVar "key"))) (fa "miSerial" (EVar "serial")) (fa "miRow" (EVar "row")) (fa "miExports" (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EVar "freezeExport") (EApp (EVar "snd") (EVar "b")))))) (EVar "exports"))) (fa "miFunNames" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrFunNames")) (EFieldAccess (EVar "before") "mrFunNames")))) (fa "miDispatchIdx" (EApp (EApp (EVar "drop") (EApp (EVar "listLen") (EFieldAccess (EVar "before") "mrDispatchIdx"))) (EFieldAccess (EVar "after") "mrDispatchIdx"))) (fa "miDataCtors" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrDataCtors")) (EFieldAccess (EVar "before") "mrDataCtors"))) (fa "miCtorPop" (EApp (EApp (EVar "spMap") (EVar "freezeScheme")) (EVar "ctorPop"))) (fa "miRecordPop" (EApp (EApp (EVar "spMap") (EVar "zonkRecord")) (EVar "recordPop"))) (fa "miFunSlots" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrFunSlots")) (EFieldAccess (EVar "before") "mrFunSlots")))) (fa "miFunSlotsQual" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrFunSlotsQual")) (EFieldAccess (EVar "before") "mrFunSlotsQual")))) (fa "miDeclared" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrDeclared")) (EFieldAccess (EVar "before") "mrDeclared"))) (fa "miDeclaredQual" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrDeclaredQual")) (EFieldAccess (EVar "before") "mrDeclaredQual"))) (fa "miMethodSlots" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrMethodSlots")) (EFieldAccess (EVar "before") "mrMethodSlots")))) (fa "miMethodSlotsQual" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrMethodSlotsQual")) (EFieldAccess (EVar "before") "mrMethodSlotsQual")))) (fa "miSchemeOblsQual" (EApp (EVar "zonkObls") (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrSchemeOblsQual")) (EFieldAccess (EVar "before") "mrSchemeOblsQual")))) (fa "miExistentials" (EVar "existentials")) (fa "miPatternAuth" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrPatternAuth")) (EFieldAccess (EVar "before") "mrPatternAuth")))) (fa "miAnyExistentials" (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "existentials")) (EBinOp "&&" (EFieldAccess (EVar "after") "mrAnyExistentials") (EApp (EVar "not") (EFieldAccess (EVar "before") "mrAnyExistentials"))))) (fa "miEvTable" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrEvTable")) (EFieldAccess (EVar "before") "mrEvTable"))) (fa "miBinders" (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrBinders")) (EFieldAccess (EVar "before") "mrBinders"))))) (fa "miTopIds" (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrTopIds")) (EFieldAccess (EVar "before") "mrTopIds")))) (fa "miMethodGrants" (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrMethodGrants")) (EFieldAccess (EVar "before") "mrMethodGrants")))) (fa "miTakers" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrTakers")) (EFieldAccess (EVar "before") "mrTakers")))) (fa "miSticky" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrSticky")) (EFieldAccess (EVar "before") "mrSticky"))) (fa "miInvocationView" (EApp (EVar "publishInvocationView") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "invocationViewRef") "value"))) (fa "miTrees" (EVar "trees")))))))
(DTypeSig true "freezeModuleTrees" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyCon "ModuleRows") (TyFun (TyCon "ModuleCtx") (TyCon "ModuleTrees")))))))
(DFunDef false "freezeModuleTrees" ((PVar "mid") (PVar "marked") (PVar "published") (PVar "before") (PVar "mctx")) (EBlock (DoLet false false (PVar "r") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun")) (DoLet false false (PVar "gs") (EFieldAccess (EVar "r") "grants")) (DoLet false false (PVar "locals") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "localAbs") "lasMinted") "value")) (DoExpr (ERecordCreate "ModuleTrees" ((fa "mtMarked" (EVar "marked")) (fa "mtEvidence" (EApp (EApp (EVar "cellEntriesFrom") (EVar "r")) (EFieldAccess (EVar "before") "mrEvCounter"))) (fa "mtTopIds" (EApp (EApp (EVar "idsUnder") (EApp (EApp (EMethodRef "map") (EApp (EVar "grantTopKey") (EVar "mid"))) (EApp (EVar "topBinderNames") (EVar "marked")))) (EFieldAccess (EFieldAccess (EVar "gs") "gsTopIds") "value"))) (fa "mtLocalAbs" (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EApp (EApp (EMethodRef "map") (EVar "zonkLocalAbs")) (EApp (EVar "snd") (EVar "row")))))) (EApp (EVar "M.entries") (EApp (EApp (EVar "omRestrict") (EVar "locals")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "localAbs") "lasBinders") "value"))))) (fa "mtLocalIds" (EApp (EApp (EVar "idsUnder") (EVar "locals")) (EFieldAccess (EFieldAccess (EVar "gs") "gsLocalIds") "value"))) (fa "mtMethodGrants" (EApp (EApp (EMethodRef "map") (ELam ((PVar "k")) (ETuple (EVar "k") (EApp (EApp (EVar "omLookup") (EVar "k")) (EFieldAccess (EFieldAccess (EVar "gs") "gsMethods") "value"))))) (EApp (EVar "methodGrantKeys") (EVar "marked")))) (fa "mtSourceless" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EFieldAccess (EVar "gs") "gsSourceless") "value")) (EFieldAccess (EVar "before") "mrSourceless")))) (fa "mtBounds" (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EFieldAccess (EVar "gs") "gsBounds") "value")) (EFieldAccess (EVar "before") "mrBounds")))) (fa "mtValueBounds" (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EFieldAccess (EVar "gs") "gsValueBounds") "value")) (EFieldAccess (EVar "before") "mrValueBounds")))) (fa "mtPromoted" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "promotedRef") "value")) (fa "mtMain" (EApp (EApp (EVar "lookupAssoc") (ELit (LString "main"))) (EVar "published"))))))))
(DTypeSig true "applyModuleTrees" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ModuleTrees") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "applyModuleTrees" ((PVar "g") (PVar "t")) (EBlock (DoLet false false (PVar "r") (EFieldAccess (EVar "g") "graphRun")) (DoLet false false (PVar "gs") (EFieldAccess (EVar "r") "grants")) (DoLet false false (PVar "las") (EFieldAccess (EVar "r") "localAbs")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "evTable")) (EBinOp "++" (EFieldAccess (EVar "t") "mtEvidence") (EFieldAccess (EFieldAccess (EVar "r") "evTable") "value")))) (DoExpr (EApp (EApp (EVar "each") (EApp (EVar "setGrantIds") (EFieldAccess (EVar "gs") "gsTopIds"))) (EFieldAccess (EVar "t") "mtTopIds"))) (DoExpr (EApp (EApp (EVar "each") (ELam ((PVar "row")) (EApp (EApp (EApp (EVar "forgetLocalRows") (EVar "las")) (EVar "gs")) (EApp (EVar "fst") (EVar "row"))))) (EFieldAccess (EVar "t") "mtLocalIds"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "las") "lasBinders")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EApp (EApp (EMethodRef "map") (EVar "zonkLocalAbs")) (EApp (EVar "snd") (EVar "row")))))) (EFieldAccess (EVar "t") "mtLocalAbs"))) (EFieldAccess (EFieldAccess (EVar "las") "lasBinders") "value")))) (DoExpr (EApp (EApp (EVar "each") (EApp (EVar "setGrantIds") (EFieldAccess (EVar "gs") "gsLocalIds"))) (EFieldAccess (EVar "t") "mtLocalIds"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsMethods")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "row")) (EMatch (EApp (EVar "snd") (EVar "row")) (arm (PCon "Some" (PVar "mg")) () (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "fst") (EVar "row"))) (EVar "mg")) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EVar "omDelete") (EApp (EVar "fst") (EVar "row"))) (EVar "acc")))))) (EFieldAccess (EFieldAccess (EVar "gs") "gsMethods") "value")) (EFieldAccess (EVar "t") "mtMethodGrants")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsSourceless")) (EApp (EApp (EVar "insertIds") (EFieldAccess (EVar "t") "mtSourceless")) (EFieldAccess (EFieldAccess (EVar "gs") "gsSourceless") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsBounds")) (EApp (EApp (EVar "omFromPairs") (EFieldAccess (EVar "t") "mtBounds")) (EFieldAccess (EFieldAccess (EVar "gs") "gsBounds") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsValueBounds")) (EApp (EApp (EVar "omFromPairs") (EFieldAccess (EVar "t") "mtValueBounds")) (EFieldAccess (EFieldAccess (EVar "gs") "gsValueBounds") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "promotionHarvestRef")) (EApp (EVar "dedup") (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "g") "promotionHarvestRef") "value") (EFieldAccess (EVar "t") "mtPromoted"))))) (DoExpr (EMatch (EFieldAccess (EVar "t") "mtMain") (arm (PCon "Some" (PVar "p")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "mainSchemeRef")) (EApp (EVar "Some") (EApp (EVar "thawScheme") (EVar "p"))))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EFieldAccess (EVar "t") "mtMarked"))))
(DTypeSig false "zonkLocalAbs" (TyFun (TyCon "LocalAbs") (TyCon "LocalAbs")))
(DFunDef false "zonkLocalAbs" ((PVar "la")) (ERecordUpdate (EVar "la") ((fa "laSlots" (EApp (EApp (EMethodRef "map") (EVar "zonkSlot")) (EFieldAccess (EVar "la") "laSlots"))))))
(DTypeSig true "forgetLocalRows" (TyFun (TyCon "LocalAbsState") (TyFun (TyCon "GrantState") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "forgetLocalRows" ((PVar "las") (PVar "gs") (PVar "name")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "las") "lasBinders")) (EApp (EApp (EVar "omDelete") (EVar "name")) (EFieldAccess (EFieldAccess (EVar "las") "lasBinders") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "las") "lasRecOccs")) (EApp (EApp (EVar "omDelete") (EVar "name")) (EFieldAccess (EFieldAccess (EVar "las") "lasRecOccs") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsLocalIds")) (EApp (EApp (EVar "omDelete") (EVar "name")) (EFieldAccess (EFieldAccess (EVar "gs") "gsLocalIds") "value"))))))
(DTypeSig false "methodGrantKeys" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "methodGrantKeys" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "declMethodGrantKeys")) (EVar "prog")))
(DTypeSig false "declMethodGrantKeys" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declMethodGrantKeys" ((PRec "DInterface" ((rf "name" None) (rf "methods" None) (rf "ifaceOrigin" None)) true)) (EApp (EApp (EMethodRef "map") (ELam ((PCon "IfaceMethod" (PVar "m") PWild PWild PWild)) (EApp (EApp (EVar "methodGrantKey") (EApp (EApp (EVar "ifaceWordOf") (EVar "ifaceOrigin")) (EVar "name"))) (EVar "m")))) (EVar "methods")))
(DFunDef false "declMethodGrantKeys" (PWild) (EListLit))
(DTypeSig false "idsUnder" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "idsUnder" ((PVar "keys") (PVar "table")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "k")) (ETuple (EVar "k") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "table")))))) (EVar "keys")))
(DTypeSig false "topBinderNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topBinderNames" ((PVar "prog")) (EApp (EVar "dedup") (EApp (EApp (EDictApp "flatMap") (EVar "declBinderNames")) (EVar "prog"))))
(DTypeSig true "cellEntriesFrom" (TyFun (TyCon "GraphRun") (TyFun (TyCon "Int") (TyCon "EvTable"))))
(DFunDef false "cellEntriesFrom" ((PVar "r") (PVar "lo")) (EBlock (DoLet false false (PVar "from") (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EBinOp "-" (EVar "lo") (EFieldAccess (EVar "r") "evBase")))) (DoLet false false (PVar "cells") (EFieldAccess (EFieldAccess (EVar "r") "evCells") "value")) (DoLet false false (PVar "sites") (EFieldAccess (EFieldAccess (EVar "r") "siteCells") "value")) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "methodCellEntriesFrom") (EVar "cells")) (EVar "from")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "cells")) (ELit (LInt 1)))) (EListLit)) (EApp (EApp (EApp (EApp (EVar "siteCellEntriesFrom") (EVar "sites")) (EVar "from")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "sites")) (ELit (LInt 1)))) (EListLit))))))
(DTypeSig false "methodCellEntriesFrom" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvCell"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "EvTable") (TyCon "EvTable"))))))
(DFunDef false "methodCellEntriesFrom" ((PVar "arr") (PVar "lo") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (EVar "lo")) (EVar "acc") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "methodCellEntriesFrom") (EVar "arr")) (EVar "lo")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))) (arm (PCon "Some" (PVar "c")) () (EBlock (DoLet false false (PVar "arity") (EApp (EApp (EVar "optionOrPanic") (ELit (LString "method cell published before its selected scheme supplied an arity"))) (EFieldAccess (EFieldAccess (EVar "c") "ecArity") "value"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "methodCellEntriesFrom") (EVar "arr")) (EVar "lo")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "EvEntry") (EFieldAccess (EVar "c") "ecId")) (EApp (EApp (EApp (EApp (EApp (EVar "EvMethod") (EFieldAccess (EFieldAccess (EVar "c") "ecIface") "value")) (EVar "arity")) (EFieldAccess (EFieldAccess (EVar "c") "ecTag") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecImpl") "value")) (EFieldAccess (EFieldAccess (EVar "c") "ecMeth") "value"))) (EVar "acc"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "siteCellEntriesFrom" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyTuple (TyCon "EvId") (TyCon "SiteCell")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "EvTable") (TyCon "EvTable"))))))
(DFunDef false "siteCellEntriesFrom" ((PVar "arr") (PVar "lo") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (EVar "lo")) (EVar "acc") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "siteCellEntriesFrom") (EVar "arr")) (EVar "lo")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))) (arm (PCon "Some" (PTuple (PVar "ev") (PVar "c"))) () (EApp (EApp (EApp (EApp (EVar "siteCellEntriesFrom") (EVar "arr")) (EVar "lo")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "EvEntry") (EVar "ev")) (EApp (EVar "siteCellValue") (EVar "c"))) (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "siteCellValue" (TyFun (TyCon "SiteCell") (TyCon "EvVal")))
(DFunDef false "siteCellValue" ((PCon "OpSite" (PVar "r"))) (EApp (EVar "EvOne") (EFieldAccess (EVar "r") "value")))
(DFunDef false "siteCellValue" ((PCon "LitSite" (PVar "f") (PVar "r"))) (EApp (EApp (EVar "EvLit") (EFieldAccess (EVar "f") "value")) (EFieldAccess (EVar "r") "value")))
(DFunDef false "siteCellValue" ((PCon "HeadSite" (PVar "h"))) (EApp (EVar "EvHead") (EFieldAccess (EVar "h") "value")))
(DTypeSig true "setServedArity" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyFun (TyCon "Int") (TyCon "Unit")))))
(DFunDef false "setServedArity" ((PVar "idx") (PVar "ev") (PVar "arity")) (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (ELit (LString "served method occurrence"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvMethod" (PVar "iface") PWild (PVar "tag") (PVar "impls") (PVar "meths"))) () (EApp (EApp (EVar "replaceEntryIn") (EVar "idx")) (EApp (EApp (EVar "EvEntry") (EVar "ev")) (EApp (EApp (EApp (EApp (EApp (EVar "EvMethod") (EVar "iface")) (EVar "arity")) (EVar "tag")) (EVar "impls")) (EVar "meths"))))) (arm (PCon "Ok" PWild) () (EApp (EVar "panic") (ELit (LString "evidence table: a method occurrence answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "servedEntriesFrom" (TyFun (TyCon "EvIndex") (TyFun (TyCon "Int") (TyFun (TyCon "EvTable") (TyCon "EvTable")))))
(DFunDef false "servedEntriesFrom" ((PVar "idx") (PVar "base") (PVar "rows")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "servedEntryIn") (EVar "idx")) (EVar "base"))) (EVar "rows")))
(DTypeSig false "servedEntryIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "Int") (TyFun (TyCon "EvEntry") (TyCon "EvEntry")))))
(DFunDef false "servedEntryIn" ((PVar "idx") (PVar "base") (PAs "e" (PCon "EvEntry" (PVar "ev") (PCon "EvMethod" PWild PWild PWild PWild PWild)))) (EBlock (DoLet false false (PCon "EvId" PWild (PVar "i")) (EVar "ev")) (DoExpr (EIf (EBinOp "<" (EVar "i") (EVar "base")) (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (ELit (LString "served method occurrence"))) (EVar "ev")) (arm (PCon "Ok" (PVar "v")) () (EApp (EApp (EVar "EvEntry") (EVar "ev")) (EVar "v"))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))) (EVar "e")))))
(DFunDef false "servedEntryIn" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "mergePop" (TyFun (TyApp (TyCon "SpellingPop") (TyVar "a")) (TyFun (TyApp (TyCon "SpellingPop") (TyVar "a")) (TyApp (TyCon "SpellingPop") (TyVar "a")))))
(DFunDef false "mergePop" ((PVar "own") (PVar "pop")) (EBlock (DoLet false false (PVar "rows") (EApp (EVar "spRows") (EVar "own"))) (DoLet false false (PVar "withRows") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "e")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "row")) (EApp (EApp (EApp (EVar "insertRow") (EApp (EVar "fst") (EVar "e"))) (EVar "row")) (EVar "acc2")))) (EVar "acc")) (EApp (EVar "snd") (EVar "e"))))) (EVar "pop")) (EApp (EVar "M.entries") (EVar "rows")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "e")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "e"))) (EVar "rows")) (EVar "acc") (EApp (EApp (EApp (EApp (EApp (EVar "spInsert") (EVar "None")) (EApp (EVar "fst") (EVar "e"))) (ELit (LString ""))) (EApp (EVar "snd") (EVar "e"))) (EVar "acc"))))) (EVar "withRows")) (EApp (EVar "M.entries") (EApp (EVar "spFloor") (EVar "own")))))))
(DTypeSig false "insertRow" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyCon "String") (TyVar "a")) (TyFun (TyApp (TyCon "SpellingPop") (TyVar "a")) (TyApp (TyCon "SpellingPop") (TyVar "a"))))))
(DFunDef false "insertRow" ((PVar "spelling") (PTuple (PVar "ident") (PVar "owner") (PVar "payload")) (PVar "pop")) (EApp (EApp (EApp (EApp (EApp (EVar "spInsert") (EApp (EVar "Some") (EVar "ident"))) (EVar "spelling")) (EVar "owner")) (EVar "payload")) (EVar "pop")))
(DTypeSig false "insertIds" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "insertIds" ((PVar "ids") (PVar "m")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "i")) (EApp (EApp (EApp (EVar "M.set") (EVar "i")) (ELit LUnit)) (EVar "acc")))) (EVar "m")) (EVar "ids")))
(DTypeSig true "applyModuleInterface" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "ModuleInterface") (TyTuple (TyCon "ModDiags") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding")))))))
(DFunDef false "applyModuleInterface" ((PVar "g") (PVar "mi")) (EBlock (DoLet false false (PVar "c") (EFieldAccess (EVar "g") "crossRun")) (DoLet false false (PVar "r") (EFieldAccess (EVar "g") "graphRun")) (DoLet false false (PVar "gs") (EFieldAccess (EVar "r") "grants")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "universeFunNamesRef")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "c") "universeFunNamesRef") "value")) (EFieldAccess (EVar "mi") "miFunNames")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "universeMethodDispatchIdxByIdRef")) (EBinOp "++" (EFieldAccess (EFieldAccess (EVar "c") "universeMethodDispatchIdxByIdRef") "value") (EFieldAccess (EVar "mi") "miDispatchIdx")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "universeDataCtors")) (EBinOp "++" (EFieldAccess (EVar "mi") "miDataCtors") (EFieldAccess (EFieldAccess (EVar "c") "universeDataCtors") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "universeCtorPop")) (EApp (EApp (EVar "mergePop") (EApp (EApp (EVar "spMap") (EVar "thawScheme")) (EFieldAccess (EVar "mi") "miCtorPop"))) (EFieldAccess (EFieldAccess (EVar "c") "universeCtorPop") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "universeRecordPop")) (EApp (EApp (EVar "mergePop") (EApp (EApp (EVar "spMap") (EVar "zonkRecord")) (EFieldAccess (EVar "mi") "miRecordPop"))) (EFieldAccess (EFieldAccess (EVar "c") "universeRecordPop") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsRef")) (EBinOp "++" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EFieldAccess (EVar "mi") "miFunSlots")) (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsQualRef")) (EBinOp "++" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EFieldAccess (EVar "mi") "miFunSlotsQual")) (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredRef")) (EBinOp "++" (EFieldAccess (EVar "mi") "miDeclared") (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredQualRef")) (EBinOp "++" (EFieldAccess (EVar "mi") "miDeclaredQual") (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsRef")) (EBinOp "++" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EFieldAccess (EVar "mi") "miMethodSlots")) (EFieldAccess (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsQualRef")) (EBinOp "++" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EFieldAccess (EVar "mi") "miMethodSlotsQual")) (EFieldAccess (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "c") "crossModuleSchemeOblsQualRef")) (EBinOp "++" (EApp (EVar "zonkObls") (EFieldAccess (EVar "mi") "miSchemeOblsQual")) (EFieldAccess (EFieldAccess (EVar "c") "crossModuleSchemeOblsQualRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "ctorExistentialsRef")) (EApp (EApp (EVar "insertIds") (EFieldAccess (EVar "mi") "miExistentials")) (EFieldAccess (EFieldAccess (EVar "r") "ctorExistentialsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "patternAuthIdsRef")) (EApp (EApp (EVar "insertIds") (EFieldAccess (EVar "mi") "miPatternAuth")) (EFieldAccess (EFieldAccess (EVar "r") "patternAuthIdsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "anyExistentialsRef")) (EBinOp "||" (EFieldAccess (EFieldAccess (EVar "r") "anyExistentialsRef") "value") (EFieldAccess (EVar "mi") "miAnyExistentials")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "evTable")) (EBinOp "++" (EFieldAccess (EVar "mi") "miEvTable") (EFieldAccess (EFieldAccess (EVar "r") "evTable") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "r") "binderRows")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "row")) (EApp (EApp (EVar "addBinderRow") (EVar "row")) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "r") "binderRows") "value")) (EFieldAccess (EVar "mi") "miBinders")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsTopIds")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "e")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "gs") "gsTopIds") "value")) (EFieldAccess (EVar "mi") "miTopIds")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsMethods")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "e")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "snd") (EVar "e"))) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "gs") "gsMethods") "value")) (EFieldAccess (EVar "mi") "miMethodGrants")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "gs") "gsTakers")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "acc")))) (EFieldAccess (EFieldAccess (EVar "gs") "gsTakers") "value")) (EFieldAccess (EVar "mi") "miTakers")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "typeErrorsSticky")) (EBinOp "||" (EFieldAccess (EFieldAccess (EVar "g") "typeErrorsSticky") "value") (EApp (EVar "isNonEmptyL") (EFieldAccess (EVar "mi") "miSticky"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "typeErrorsStickyDiags")) (EBinOp "++" (EFieldAccess (EVar "mi") "miSticky") (EFieldAccess (EFieldAccess (EVar "g") "typeErrorsStickyDiags") "value")))) (DoExpr (ETuple (EFieldAccess (EVar "mi") "miRow") (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EVar "thawExport") (EApp (EVar "snd") (EVar "b")))))) (EFieldAccess (EVar "mi") "miExports"))))))
(DData Private "ModuleCache" () ((variant "ModuleCache" (ConNamed (field "mcEntries" (TyApp (TyCon "OrdMap") (TyCon "ModuleInterface"))) (field "mcSerial" (TyCon "Int"))))) ())
(DTypeSig false "moduleCacheRef" (TyApp (TyCon "Ref") (TyCon "ModuleCache")))
(DFunDef false "moduleCacheRef" () (EApp (EVar "Ref") (ERecordCreate "ModuleCache" ((fa "mcEntries" (EVar "omEmpty")) (fa "mcSerial" (ELit (LInt 0)))))))
(DTypeSig true "freshModuleSerial" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "freshModuleSerial" (PWild) (EBlock (DoLet false false (PVar "cache") (EFieldAccess (EVar "moduleCacheRef") "value")) (DoLet false false (PVar "next") (EBinOp "+" (EFieldAccess (EVar "cache") "mcSerial") (ELit (LInt 1)))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "moduleCacheRef")) (ERecordUpdate (EVar "cache") ((fa "mcSerial" (EVar "next")))))) (DoExpr (EVar "next"))))
(DTypeSig true "moduleInterfaceIdentity" (TyFun (TyCon "ModuleInterface") (TyCon "String")))
(DFunDef false "moduleInterfaceIdentity" ((PVar "mi")) (EApp (EVar "intToString") (EFieldAccess (EVar "mi") "miSerial")))
(DTypeSig true "moduleCacheHit" (TyFun (TyCon "ModuleKey") (TyApp (TyCon "Option") (TyCon "ModuleInterface"))))
(DFunDef false "moduleCacheHit" ((PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "key") "mkModule")) (EFieldAccess (EFieldAccess (EVar "moduleCacheRef") "value") "mcEntries")) (arm (PCon "Some" (PVar "mi")) () (EIf (EBinOp "==" (EFieldAccess (EVar "mi") "miKeyText") (EApp (EVar "moduleKeyText") (EVar "key"))) (EApp (EVar "Some") (EVar "mi")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig true "recordModuleInterface" (TyFun (TyCon "ModuleInterface") (TyCon "Unit")))
(DFunDef false "recordModuleInterface" ((PVar "mi")) (EApp (EApp (EVar "setRef") (EVar "moduleCacheRef")) (EApp (EApp (EVar "withInterface") (EFieldAccess (EVar "moduleCacheRef") "value")) (EVar "mi"))))
(DTypeSig true "retainModuleInterfaces" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))
(DFunDef false "retainModuleInterfaces" ((PVar "mids")) (EBlock (DoLet false false (PVar "cache") (EFieldAccess (EVar "moduleCacheRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EVar "moduleCacheRef")) (ERecordUpdate (EVar "cache") ((fa "mcEntries" (EApp (EApp (EVar "omRestrict") (EVar "mids")) (EFieldAccess (EVar "cache") "mcEntries")))))))))
(DTypeSig true "seedModuleInterfaces" (TyFun (TyApp (TyCon "List") (TyCon "ModuleInterface")) (TyCon "Unit")))
(DFunDef false "seedModuleInterfaces" ((PVar "mis")) (EApp (EApp (EVar "setRef") (EVar "moduleCacheRef")) (EApp (EApp (EApp (EMethodRef "fold") (EVar "withInterface")) (EFieldAccess (EVar "moduleCacheRef") "value")) (EVar "mis"))))
(DTypeSig false "withInterface" (TyFun (TyCon "ModuleCache") (TyFun (TyCon "ModuleInterface") (TyCon "ModuleCache"))))
(DFunDef false "withInterface" ((PVar "cache") (PVar "mi")) (ERecordCreate "ModuleCache" ((fa "mcEntries" (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EFieldAccess (EVar "mi") "miKey") "mkModule")) (EVar "mi")) (EFieldAccess (EVar "cache") "mcEntries"))) (fa "mcSerial" (EApp (EApp (EMethodRef "max") (EFieldAccess (EVar "cache") "mcSerial")) (EFieldAccess (EVar "mi") "miSerial"))))))
(DTypeSig true "currentModuleInterfaces" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "ModuleInterface"))))
(DFunDef false "currentModuleInterfaces" (PWild) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EVar "M.entries") (EFieldAccess (EFieldAccess (EVar "moduleCacheRef") "value") "mcEntries"))))
