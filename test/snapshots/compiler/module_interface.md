# META
source_lines=409
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
-- The cache holds one interface per module id, the newest recorded, with no count
-- cap.  Each recorded interface carries a process serial, and an importer's key
-- carries the serial of each import (`moduleInterfaceIdentity`), so an importer
-- whose import was re-recorded misses without any digest.
import frontend.ast.{TabKey, DataVis, Variant, EvTable, Ident}
import list.{drop, take, mapAccumL}
import map as M
import map.{Map(..)}
import support.ordmap.{
  OrdMap, omEmpty, omInsert, omLookup, omHasKey, omRestrict
}
import support.util.{joinNl, lenKey, listLen, isNonEmptyL}
import types.prelude_interface.{
  freezeScheme, thawScheme, zonkSlot, zonkMethodSlot, zonkRecord, mapSlots
}
import types.publish.{
  ModDiags, PubScheme(..), TcDiag, emptyZonk, zonkScheme, zonkVecObl
}
import types.registry.{SpellingPop, spInsert, spMap, spRows, spFloor}
import types.repr.{IfaceRef, VecObl}
import types.runtime_types.{BinderRow, BinderTypeTable, addBinderRow}
import types.tc_types.{
  GraphCtx(..), CrossRun(..), GraphRun(..), GrantState(..), ModuleCtx(..),
  ModuleCells(..), ExportBinding(..), PredicateSlot, MethodPredicateSlot,
  CDeclaredPrefix, RecordInfo, MethodGrant
}

-- ── the key ─────────────────────────────────────────────────────────────────

-- What an interface is valid under: the module id, the source key its driver passes
-- (the module id, its path and the exact source the loader parsed), the identity of
-- each direct import, and the drive's graph key (its configuration, the prelude
-- generation and chain key, and every module's instance heads and constrained
-- signature names, which a module reads whether or not it imports their definer).
-- An import that was checked and not recorded has a serial no interface carries.
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
-- its check and [mctx] its record after the drain.
export
freezeModuleInterface : ModuleKey ->
  Int ->
  ModDiags ->
  List (String, ExportBinding) ->
  ModuleRows ->
  ModuleCtx ->
  ModuleInterface
freezeModuleInterface key serial row exports before mctx =
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
  }

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
(DUse false (UseGroup ("frontend" "ast") ((mem "TabKey" false) (mem "DataVis" false) (mem "Variant" false) (mem "EvTable" false) (mem "Ident" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "take" false) (mem "mapAccumL" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omRestrict" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "lenKey" false) (mem "listLen" false) (mem "isNonEmptyL" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "freezeScheme" false) (mem "thawScheme" false) (mem "zonkSlot" false) (mem "zonkMethodSlot" false) (mem "zonkRecord" false) (mem "mapSlots" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ModDiags" false) (mem "PubScheme" true) (mem "TcDiag" false) (mem "emptyZonk" false) (mem "zonkScheme" false) (mem "zonkVecObl" false))))
(DUse false (UseGroup ("types" "registry") ((mem "SpellingPop" false) (mem "spInsert" false) (mem "spMap" false) (mem "spRows" false) (mem "spFloor" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" false) (mem "VecObl" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" false) (mem "BinderTypeTable" false) (mem "addBinderRow" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "GraphCtx" true) (mem "CrossRun" true) (mem "GraphRun" true) (mem "GrantState" true) (mem "ModuleCtx" true) (mem "ModuleCells" true) (mem "ExportBinding" true) (mem "PredicateSlot" false) (mem "MethodPredicateSlot" false) (mem "CDeclaredPrefix" false) (mem "RecordInfo" false) (mem "MethodGrant" false))))
(DData Public "ModuleKey" () ((variant "ModuleKey" (ConNamed (field "mkModule" (TyCon "String")) (field "mkSource" (TyCon "String")) (field "mkImports" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "mkGraph" (TyCon "String"))))) ())
(DTypeSig true "moduleKeyText" (TyFun (TyCon "ModuleKey") (TyCon "String")))
(DFunDef false "moduleKeyText" ((PVar "k")) (EApp (EVar "joinNl") (EBinOp "++" (EListLit (EApp (EVar "lenKey") (EFieldAccess (EVar "k") "mkModule")) (EApp (EVar "lenKey") (EFieldAccess (EVar "k") "mkSource")) (EApp (EVar "lenKey") (EFieldAccess (EVar "k") "mkGraph"))) (EApp (EApp (EVar "map") (ELam ((PVar "imp")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lenKey") (EApp (EVar "fst") (EVar "imp"))))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "lenKey") (EApp (EVar "snd") (EVar "imp"))))) (ELit (LString ""))))) (EFieldAccess (EVar "k") "mkImports")))))
(DData Public "FrozenExport" () ((variant "FrozenExport" (ConNamed (field "feScheme" (TyCon "PubScheme")) (field "feStandalone" (TyApp (TyCon "Option") (TyCon "PubScheme"))) (field "feExtern" (TyCon "Bool"))))) ())
(DData Public "ModuleInterface" () ((variant "ModuleInterface" (ConNamed (field "miKey" (TyCon "ModuleKey")) (field "miKeyText" (TyCon "String")) (field "miSerial" (TyCon "Int")) (field "miRow" (TyCon "ModDiags")) (field "miExports" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "FrozenExport")))) (field "miFunNames" (TyApp (TyCon "List") (TyCon "String"))) (field "miDispatchIdx" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))) (field "miDataCtors" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyCon "DataVis") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant")))))) (field "miCtorPop" (TyApp (TyCon "SpellingPop") (TyCon "PubScheme"))) (field "miRecordPop" (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo"))) (field "miFunSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "miFunSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "miDeclared" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix")))) (field "miDeclaredQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CDeclaredPrefix")))) (field "miMethodSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "miMethodSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "miSchemeOblsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl"))))) (field "miExistentials" (TyApp (TyCon "List") (TyCon "Int"))) (field "miPatternAuth" (TyApp (TyCon "List") (TyCon "Int"))) (field "miAnyExistentials" (TyCon "Bool")) (field "miEvTable" (TyCon "EvTable")) (field "miBinders" (TyApp (TyCon "List") (TyCon "BinderRow"))) (field "miTopIds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))) (field "miMethodGrants" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "MethodGrant")))) (field "miTakers" (TyApp (TyCon "List") (TyCon "String"))) (field "miSticky" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))) ())
(DData Abstract "ModuleRows" () ((variant "ModuleRows" (ConNamed (field "mrFunNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mrDispatchIdx" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))) (field "mrDataCtors" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyCon "DataVis") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant")))))) (field "mrFunSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "mrFunSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "mrDeclared" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix")))) (field "mrDeclaredQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CDeclaredPrefix")))) (field "mrMethodSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "mrMethodSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "mrSchemeOblsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl"))))) (field "mrExistentials" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "mrPatternAuth" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "mrAnyExistentials" (TyCon "Bool")) (field "mrEvTable" (TyCon "EvTable")) (field "mrBinders" (TyCon "BinderTypeTable")) (field "mrTopIds" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrMethodGrants" (TyApp (TyCon "OrdMap") (TyCon "MethodGrant"))) (field "mrTakers" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mrSticky" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))) ())
(DTypeSig true "captureModuleRows" (TyFun (TyCon "GraphCtx") (TyCon "ModuleRows")))
(DFunDef false "captureModuleRows" ((PVar "g")) (EBlock (DoLet false false (PVar "c") (EFieldAccess (EVar "g") "crossRun")) (DoLet false false (PVar "r") (EFieldAccess (EVar "g") "graphRun")) (DoExpr (ERecordCreate "ModuleRows" ((fa "mrFunNames" (EFieldAccess (EFieldAccess (EVar "c") "universeFunNamesRef") "value")) (fa "mrDispatchIdx" (EFieldAccess (EFieldAccess (EVar "c") "universeMethodDispatchIdxByIdRef") "value")) (fa "mrDataCtors" (EFieldAccess (EFieldAccess (EVar "c") "universeDataCtors") "value")) (fa "mrFunSlots" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsRef") "value")) (fa "mrFunSlotsQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsQualRef") "value")) (fa "mrDeclared" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredRef") "value")) (fa "mrDeclaredQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredQualRef") "value")) (fa "mrMethodSlots" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsRef") "value")) (fa "mrMethodSlotsQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsQualRef") "value")) (fa "mrSchemeOblsQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleSchemeOblsQualRef") "value")) (fa "mrExistentials" (EFieldAccess (EFieldAccess (EVar "r") "ctorExistentialsRef") "value")) (fa "mrPatternAuth" (EFieldAccess (EFieldAccess (EVar "r") "patternAuthIdsRef") "value")) (fa "mrAnyExistentials" (EFieldAccess (EFieldAccess (EVar "r") "anyExistentialsRef") "value")) (fa "mrEvTable" (EFieldAccess (EFieldAccess (EVar "r") "evTable") "value")) (fa "mrBinders" (EFieldAccess (EFieldAccess (EVar "r") "binderRows") "value")) (fa "mrTopIds" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsTopIds") "value")) (fa "mrMethodGrants" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsMethods") "value")) (fa "mrTakers" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsTakers") "value")) (fa "mrSticky" (EFieldAccess (EFieldAccess (EVar "g") "typeErrorsStickyDiags") "value")))))))
(DTypeSig false "newPrefix" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "newPrefix" ((PVar "after") (PVar "before")) (EApp (EApp (EVar "take") (EBinOp "-" (EApp (EVar "listLen") (EVar "after")) (EApp (EVar "listLen") (EVar "before")))) (EVar "after")))
(DTypeSig false "zonkObls" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyApp (TyCon "List") (TyCon "VecObl"))))))
(DFunDef false "zonkObls" ((PVar "rows")) (EApp (EApp (EVar "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EApp (EVar "snd") (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkVecObl")) (EVar "emptyZonk")) (EApp (EVar "snd") (EVar "row"))))))) (EVar "rows")))
(DTypeSig false "freezeExport" (TyFun (TyCon "ExportBinding") (TyCon "FrozenExport")))
(DFunDef false "freezeExport" ((PVar "xb")) (EBlock (DoLet false false (PTuple (PVar "z") (PVar "s")) (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EFieldAccess (EVar "xb") "xbScheme"))) (DoExpr (ERecordCreate "FrozenExport" ((fa "feScheme" (ERecordCreate "PubScheme" ((fa "psScheme" (EVar "s")) (fa "psContext" (EListLit))))) (fa "feStandalone" (EApp (EApp (EVar "map") (ELam ((PVar "alt")) (ERecordCreate "PubScheme" ((fa "psScheme" (EApp (EVar "snd") (EApp (EApp (EVar "zonkScheme") (EVar "z")) (EVar "alt")))) (fa "psContext" (EListLit)))))) (EFieldAccess (EVar "xb") "xbStandalone"))) (fa "feExtern" (EFieldAccess (EVar "xb") "xbExtern")))))))
(DTypeSig false "thawExport" (TyFun (TyCon "FrozenExport") (TyCon "ExportBinding")))
(DFunDef false "thawExport" ((PVar "fe")) (EBlock (DoLet false false (PTuple (PVar "z") (PVar "s")) (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EFieldAccess (EFieldAccess (EVar "fe") "feScheme") "psScheme"))) (DoExpr (ERecordCreate "ExportBinding" ((fa "xbScheme" (EVar "s")) (fa "xbStandalone" (EApp (EApp (EVar "map") (ELam ((PVar "alt")) (EApp (EVar "snd") (EApp (EApp (EVar "zonkScheme") (EVar "z")) (EFieldAccess (EVar "alt") "psScheme"))))) (EFieldAccess (EVar "fe") "feStandalone"))) (fa "xbExtern" (EFieldAccess (EVar "fe") "feExtern")))))))
(DTypeSig true "freezeModuleInterface" (TyFun (TyCon "ModuleKey") (TyFun (TyCon "Int") (TyFun (TyCon "ModDiags") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyCon "ModuleRows") (TyFun (TyCon "ModuleCtx") (TyCon "ModuleInterface"))))))))
(DFunDef false "freezeModuleInterface" ((PVar "key") (PVar "serial") (PVar "row") (PVar "exports") (PVar "before") (PVar "mctx")) (EBlock (DoLet false false (PVar "after") (EApp (EVar "captureModuleRows") (EFieldAccess (EVar "mctx") "mcGraph"))) (DoLet false false (PTuple (PVar "ctorPop") (PVar "recordPop")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ownPopsRef") "value")) (DoLet false false (PVar "existentials") (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrExistentials")) (EFieldAccess (EVar "before") "mrExistentials")))) (DoExpr (ERecordCreate "ModuleInterface" ((fa "miKey" (EVar "key")) (fa "miKeyText" (EApp (EVar "moduleKeyText") (EVar "key"))) (fa "miSerial" (EVar "serial")) (fa "miRow" (EVar "row")) (fa "miExports" (EApp (EApp (EVar "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EVar "freezeExport") (EApp (EVar "snd") (EVar "b")))))) (EVar "exports"))) (fa "miFunNames" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrFunNames")) (EFieldAccess (EVar "before") "mrFunNames")))) (fa "miDispatchIdx" (EApp (EApp (EVar "drop") (EApp (EVar "listLen") (EFieldAccess (EVar "before") "mrDispatchIdx"))) (EFieldAccess (EVar "after") "mrDispatchIdx"))) (fa "miDataCtors" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrDataCtors")) (EFieldAccess (EVar "before") "mrDataCtors"))) (fa "miCtorPop" (EApp (EApp (EVar "spMap") (EVar "freezeScheme")) (EVar "ctorPop"))) (fa "miRecordPop" (EApp (EApp (EVar "spMap") (EVar "zonkRecord")) (EVar "recordPop"))) (fa "miFunSlots" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrFunSlots")) (EFieldAccess (EVar "before") "mrFunSlots")))) (fa "miFunSlotsQual" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrFunSlotsQual")) (EFieldAccess (EVar "before") "mrFunSlotsQual")))) (fa "miDeclared" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrDeclared")) (EFieldAccess (EVar "before") "mrDeclared"))) (fa "miDeclaredQual" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrDeclaredQual")) (EFieldAccess (EVar "before") "mrDeclaredQual"))) (fa "miMethodSlots" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrMethodSlots")) (EFieldAccess (EVar "before") "mrMethodSlots")))) (fa "miMethodSlotsQual" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrMethodSlotsQual")) (EFieldAccess (EVar "before") "mrMethodSlotsQual")))) (fa "miSchemeOblsQual" (EApp (EVar "zonkObls") (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrSchemeOblsQual")) (EFieldAccess (EVar "before") "mrSchemeOblsQual")))) (fa "miExistentials" (EVar "existentials")) (fa "miPatternAuth" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrPatternAuth")) (EFieldAccess (EVar "before") "mrPatternAuth")))) (fa "miAnyExistentials" (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "existentials")) (EBinOp "&&" (EFieldAccess (EVar "after") "mrAnyExistentials") (EApp (EVar "not") (EFieldAccess (EVar "before") "mrAnyExistentials"))))) (fa "miEvTable" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrEvTable")) (EFieldAccess (EVar "before") "mrEvTable"))) (fa "miBinders" (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrBinders")) (EFieldAccess (EVar "before") "mrBinders"))))) (fa "miTopIds" (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrTopIds")) (EFieldAccess (EVar "before") "mrTopIds")))) (fa "miMethodGrants" (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrMethodGrants")) (EFieldAccess (EVar "before") "mrMethodGrants")))) (fa "miTakers" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrTakers")) (EFieldAccess (EVar "before") "mrTakers")))) (fa "miSticky" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrSticky")) (EFieldAccess (EVar "before") "mrSticky"))))))))
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
(DUse false (UseGroup ("frontend" "ast") ((mem "TabKey" false) (mem "DataVis" false) (mem "Variant" false) (mem "EvTable" false) (mem "Ident" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "take" false) (mem "mapAccumL" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omRestrict" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "lenKey" false) (mem "listLen" false) (mem "isNonEmptyL" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "freezeScheme" false) (mem "thawScheme" false) (mem "zonkSlot" false) (mem "zonkMethodSlot" false) (mem "zonkRecord" false) (mem "mapSlots" false))))
(DUse false (UseGroup ("types" "publish") ((mem "ModDiags" false) (mem "PubScheme" true) (mem "TcDiag" false) (mem "emptyZonk" false) (mem "zonkScheme" false) (mem "zonkVecObl" false))))
(DUse false (UseGroup ("types" "registry") ((mem "SpellingPop" false) (mem "spInsert" false) (mem "spMap" false) (mem "spRows" false) (mem "spFloor" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" false) (mem "VecObl" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" false) (mem "BinderTypeTable" false) (mem "addBinderRow" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "GraphCtx" true) (mem "CrossRun" true) (mem "GraphRun" true) (mem "GrantState" true) (mem "ModuleCtx" true) (mem "ModuleCells" true) (mem "ExportBinding" true) (mem "PredicateSlot" false) (mem "MethodPredicateSlot" false) (mem "CDeclaredPrefix" false) (mem "RecordInfo" false) (mem "MethodGrant" false))))
(DData Public "ModuleKey" () ((variant "ModuleKey" (ConNamed (field "mkModule" (TyCon "String")) (field "mkSource" (TyCon "String")) (field "mkImports" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "mkGraph" (TyCon "String"))))) ())
(DTypeSig true "moduleKeyText" (TyFun (TyCon "ModuleKey") (TyCon "String")))
(DFunDef false "moduleKeyText" ((PVar "k")) (EApp (EVar "joinNl") (EBinOp "++" (EListLit (EApp (EVar "lenKey") (EFieldAccess (EVar "k") "mkModule")) (EApp (EVar "lenKey") (EFieldAccess (EVar "k") "mkSource")) (EApp (EVar "lenKey") (EFieldAccess (EVar "k") "mkGraph"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "imp")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EApp (EVar "fst") (EVar "imp"))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EApp (EVar "snd") (EVar "imp"))))) (ELit (LString ""))))) (EFieldAccess (EVar "k") "mkImports")))))
(DData Public "FrozenExport" () ((variant "FrozenExport" (ConNamed (field "feScheme" (TyCon "PubScheme")) (field "feStandalone" (TyApp (TyCon "Option") (TyCon "PubScheme"))) (field "feExtern" (TyCon "Bool"))))) ())
(DData Public "ModuleInterface" () ((variant "ModuleInterface" (ConNamed (field "miKey" (TyCon "ModuleKey")) (field "miKeyText" (TyCon "String")) (field "miSerial" (TyCon "Int")) (field "miRow" (TyCon "ModDiags")) (field "miExports" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "FrozenExport")))) (field "miFunNames" (TyApp (TyCon "List") (TyCon "String"))) (field "miDispatchIdx" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))) (field "miDataCtors" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyCon "DataVis") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant")))))) (field "miCtorPop" (TyApp (TyCon "SpellingPop") (TyCon "PubScheme"))) (field "miRecordPop" (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo"))) (field "miFunSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "miFunSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "miDeclared" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix")))) (field "miDeclaredQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CDeclaredPrefix")))) (field "miMethodSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "miMethodSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "miSchemeOblsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl"))))) (field "miExistentials" (TyApp (TyCon "List") (TyCon "Int"))) (field "miPatternAuth" (TyApp (TyCon "List") (TyCon "Int"))) (field "miAnyExistentials" (TyCon "Bool")) (field "miEvTable" (TyCon "EvTable")) (field "miBinders" (TyApp (TyCon "List") (TyCon "BinderRow"))) (field "miTopIds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int"))))) (field "miMethodGrants" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "MethodGrant")))) (field "miTakers" (TyApp (TyCon "List") (TyCon "String"))) (field "miSticky" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))) ())
(DData Abstract "ModuleRows" () ((variant "ModuleRows" (ConNamed (field "mrFunNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mrDispatchIdx" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))) (field "mrDataCtors" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyCon "DataVis") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant")))))) (field "mrFunSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "mrFunSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "mrDeclared" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix")))) (field "mrDeclaredQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CDeclaredPrefix")))) (field "mrMethodSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "mrMethodSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "mrSchemeOblsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl"))))) (field "mrExistentials" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "mrPatternAuth" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "mrAnyExistentials" (TyCon "Bool")) (field "mrEvTable" (TyCon "EvTable")) (field "mrBinders" (TyCon "BinderTypeTable")) (field "mrTopIds" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (field "mrMethodGrants" (TyApp (TyCon "OrdMap") (TyCon "MethodGrant"))) (field "mrTakers" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "mrSticky" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))))))) ())
(DTypeSig true "captureModuleRows" (TyFun (TyCon "GraphCtx") (TyCon "ModuleRows")))
(DFunDef false "captureModuleRows" ((PVar "g")) (EBlock (DoLet false false (PVar "c") (EFieldAccess (EVar "g") "crossRun")) (DoLet false false (PVar "r") (EFieldAccess (EVar "g") "graphRun")) (DoExpr (ERecordCreate "ModuleRows" ((fa "mrFunNames" (EFieldAccess (EFieldAccess (EVar "c") "universeFunNamesRef") "value")) (fa "mrDispatchIdx" (EFieldAccess (EFieldAccess (EVar "c") "universeMethodDispatchIdxByIdRef") "value")) (fa "mrDataCtors" (EFieldAccess (EFieldAccess (EVar "c") "universeDataCtors") "value")) (fa "mrFunSlots" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsRef") "value")) (fa "mrFunSlotsQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunPredicateSlotsQualRef") "value")) (fa "mrDeclared" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredRef") "value")) (fa "mrDeclaredQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleFunConstraintDeclaredQualRef") "value")) (fa "mrMethodSlots" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsRef") "value")) (fa "mrMethodSlotsQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleMethodPredicateSlotsQualRef") "value")) (fa "mrSchemeOblsQual" (EFieldAccess (EFieldAccess (EVar "c") "crossModuleSchemeOblsQualRef") "value")) (fa "mrExistentials" (EFieldAccess (EFieldAccess (EVar "r") "ctorExistentialsRef") "value")) (fa "mrPatternAuth" (EFieldAccess (EFieldAccess (EVar "r") "patternAuthIdsRef") "value")) (fa "mrAnyExistentials" (EFieldAccess (EFieldAccess (EVar "r") "anyExistentialsRef") "value")) (fa "mrEvTable" (EFieldAccess (EFieldAccess (EVar "r") "evTable") "value")) (fa "mrBinders" (EFieldAccess (EFieldAccess (EVar "r") "binderRows") "value")) (fa "mrTopIds" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsTopIds") "value")) (fa "mrMethodGrants" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsMethods") "value")) (fa "mrTakers" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "r") "grants") "gsTakers") "value")) (fa "mrSticky" (EFieldAccess (EFieldAccess (EVar "g") "typeErrorsStickyDiags") "value")))))))
(DTypeSig false "newPrefix" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "newPrefix" ((PVar "after") (PVar "before")) (EApp (EApp (EVar "take") (EBinOp "-" (EApp (EVar "listLen") (EVar "after")) (EApp (EVar "listLen") (EVar "before")))) (EVar "after")))
(DTypeSig false "zonkObls" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyApp (TyCon "List") (TyCon "VecObl"))))))
(DFunDef false "zonkObls" ((PVar "rows")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EApp (EVar "snd") (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkVecObl")) (EVar "emptyZonk")) (EApp (EVar "snd") (EVar "row"))))))) (EVar "rows")))
(DTypeSig false "freezeExport" (TyFun (TyCon "ExportBinding") (TyCon "FrozenExport")))
(DFunDef false "freezeExport" ((PVar "xb")) (EBlock (DoLet false false (PTuple (PVar "z") (PVar "s")) (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EFieldAccess (EVar "xb") "xbScheme"))) (DoExpr (ERecordCreate "FrozenExport" ((fa "feScheme" (ERecordCreate "PubScheme" ((fa "psScheme" (EVar "s")) (fa "psContext" (EListLit))))) (fa "feStandalone" (EApp (EApp (EMethodRef "map") (ELam ((PVar "alt")) (ERecordCreate "PubScheme" ((fa "psScheme" (EApp (EVar "snd") (EApp (EApp (EVar "zonkScheme") (EVar "z")) (EVar "alt")))) (fa "psContext" (EListLit)))))) (EFieldAccess (EVar "xb") "xbStandalone"))) (fa "feExtern" (EFieldAccess (EVar "xb") "xbExtern")))))))
(DTypeSig false "thawExport" (TyFun (TyCon "FrozenExport") (TyCon "ExportBinding")))
(DFunDef false "thawExport" ((PVar "fe")) (EBlock (DoLet false false (PTuple (PVar "z") (PVar "s")) (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EFieldAccess (EFieldAccess (EVar "fe") "feScheme") "psScheme"))) (DoExpr (ERecordCreate "ExportBinding" ((fa "xbScheme" (EVar "s")) (fa "xbStandalone" (EApp (EApp (EMethodRef "map") (ELam ((PVar "alt")) (EApp (EVar "snd") (EApp (EApp (EVar "zonkScheme") (EVar "z")) (EFieldAccess (EVar "alt") "psScheme"))))) (EFieldAccess (EVar "fe") "feStandalone"))) (fa "xbExtern" (EFieldAccess (EVar "fe") "feExtern")))))))
(DTypeSig true "freezeModuleInterface" (TyFun (TyCon "ModuleKey") (TyFun (TyCon "Int") (TyFun (TyCon "ModDiags") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportBinding"))) (TyFun (TyCon "ModuleRows") (TyFun (TyCon "ModuleCtx") (TyCon "ModuleInterface"))))))))
(DFunDef false "freezeModuleInterface" ((PVar "key") (PVar "serial") (PVar "row") (PVar "exports") (PVar "before") (PVar "mctx")) (EBlock (DoLet false false (PVar "after") (EApp (EVar "captureModuleRows") (EFieldAccess (EVar "mctx") "mcGraph"))) (DoLet false false (PTuple (PVar "ctorPop") (PVar "recordPop")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ownPopsRef") "value")) (DoLet false false (PVar "existentials") (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrExistentials")) (EFieldAccess (EVar "before") "mrExistentials")))) (DoExpr (ERecordCreate "ModuleInterface" ((fa "miKey" (EVar "key")) (fa "miKeyText" (EApp (EVar "moduleKeyText") (EVar "key"))) (fa "miSerial" (EVar "serial")) (fa "miRow" (EVar "row")) (fa "miExports" (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EVar "freezeExport") (EApp (EVar "snd") (EVar "b")))))) (EVar "exports"))) (fa "miFunNames" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrFunNames")) (EFieldAccess (EVar "before") "mrFunNames")))) (fa "miDispatchIdx" (EApp (EApp (EVar "drop") (EApp (EVar "listLen") (EFieldAccess (EVar "before") "mrDispatchIdx"))) (EFieldAccess (EVar "after") "mrDispatchIdx"))) (fa "miDataCtors" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrDataCtors")) (EFieldAccess (EVar "before") "mrDataCtors"))) (fa "miCtorPop" (EApp (EApp (EVar "spMap") (EVar "freezeScheme")) (EVar "ctorPop"))) (fa "miRecordPop" (EApp (EApp (EVar "spMap") (EVar "zonkRecord")) (EVar "recordPop"))) (fa "miFunSlots" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrFunSlots")) (EFieldAccess (EVar "before") "mrFunSlots")))) (fa "miFunSlotsQual" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrFunSlotsQual")) (EFieldAccess (EVar "before") "mrFunSlotsQual")))) (fa "miDeclared" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrDeclared")) (EFieldAccess (EVar "before") "mrDeclared"))) (fa "miDeclaredQual" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrDeclaredQual")) (EFieldAccess (EVar "before") "mrDeclaredQual"))) (fa "miMethodSlots" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrMethodSlots")) (EFieldAccess (EVar "before") "mrMethodSlots")))) (fa "miMethodSlotsQual" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrMethodSlotsQual")) (EFieldAccess (EVar "before") "mrMethodSlotsQual")))) (fa "miSchemeOblsQual" (EApp (EVar "zonkObls") (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrSchemeOblsQual")) (EFieldAccess (EVar "before") "mrSchemeOblsQual")))) (fa "miExistentials" (EVar "existentials")) (fa "miPatternAuth" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrPatternAuth")) (EFieldAccess (EVar "before") "mrPatternAuth")))) (fa "miAnyExistentials" (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "existentials")) (EBinOp "&&" (EFieldAccess (EVar "after") "mrAnyExistentials") (EApp (EVar "not") (EFieldAccess (EVar "before") "mrAnyExistentials"))))) (fa "miEvTable" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrEvTable")) (EFieldAccess (EVar "before") "mrEvTable"))) (fa "miBinders" (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrBinders")) (EFieldAccess (EVar "before") "mrBinders"))))) (fa "miTopIds" (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrTopIds")) (EFieldAccess (EVar "before") "mrTopIds")))) (fa "miMethodGrants" (EApp (EVar "M.entries") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrMethodGrants")) (EFieldAccess (EVar "before") "mrMethodGrants")))) (fa "miTakers" (EApp (EVar "M.keys") (EApp (EApp (EVar "M.difference") (EFieldAccess (EVar "after") "mrTakers")) (EFieldAccess (EVar "before") "mrTakers")))) (fa "miSticky" (EApp (EApp (EVar "newPrefix") (EFieldAccess (EVar "after") "mrSticky")) (EFieldAccess (EVar "before") "mrSticky"))))))))
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
