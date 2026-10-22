# META
source_lines=286
stages=DESUGAR,MARK
# SOURCE
-- The prelude interface as a value, and the one process cache that holds it.
--
-- A `PreludeInterface` is what a drive needs from the prelude's core pass to
-- continue as if it had run that pass: the accumulated cross-module universes,
-- the predicate slots, the declared prefixes, the extern catalog, the id
-- counters and the published rows.  It is admissible only if every field is a
-- pure function of the module's declarations: no `Decl`, no `Ref`, no live
-- `Scheme` (a `PubScheme` after `freezePub` is the admitted form, and a thaw
-- never hands frozen cells to inference but instantiates fresh ones from
-- them), and no read of process-global state.  The mark sets are therefore not
-- a field (they hold `Decl`s), and neither are the rows computed once from the
-- whole graph, which `graphPreamble` recomputes per drive.  No field type
-- carries a lineage id or a binder ordinal.
--
-- `freezeInterface` reads each `Ref` once; `thawInterface` mints fresh ones.
-- The cache (`preludeCacheRef`) keeps one entry: the interface sections of one
-- compiler generation, each valid for the IO joins it lists.  A key
-- (`InterfaceKey`) names what an on-disk copy was built from; the caller
-- hashes the source texts and supplies the compiler identity.
import frontend.ast.{Ty, TabKey, DataVis, Variant}
import list.{mapAccumL}
import map as M
import map.{Map(..), entries}
import support.ordmap.{OrdMap, omEmpty, omHasKey, omFromPairs}
import support.util.{joinWith}
import types.effect_rows.{Atom, atomKey, renderAtom}
import types.publish.{
  PubScheme(..), freezePub, freezeRows, emptyZonk, zonkMono, ZState
}
import types.registry.{SpellingPop, spMap}
import types.repr.{Mono, Scheme, IfaceRef, VecObl}
import types.tc_types.{
  GraphCtx(..), CrossRun(..), GraphRun(..), BuiltinClasses, PredicateSlot(..),
  PredicateSlotArgs(..), MethodPredicateSlot(..), CDeclaredPrefix,
  RecordInfo(..), ModuleBindings(..)
}

-- ── the interface value ─────────────────────────────────────────────────────

public export data PreludeInterface = PreludeInterface {
  piFunNames : OrdMap Unit,
  piMethodDispatchIdx : List ((IfaceRef, String), Int),
  piDataCtors : List (TabKey, (DataVis, List String, List Variant)),
  piCtorPop : SpellingPop PubScheme,
  piRecordPop : SpellingPop RecordInfo,
  piBuiltinClasses : BuiltinClasses,
  piFunPredicateSlots : List (String, List PredicateSlot),
  piFunPredicateSlotsQual : List ((String, String), List PredicateSlot),
  piFunConstraintDeclared : List (String, CDeclaredPrefix),
  piFunConstraintDeclaredQual : List ((String, String), CDeclaredPrefix),
  piMethodPredicateSlots : List (String, List MethodPredicateSlot),
  piMethodPredicateSlotsQual : List ((String, String), List MethodPredicateSlot),
  piCtorExistentials : Map Int Unit,
  piAnyExistentials : Bool,
  piExternNames : OrdMap (Ty, List (String, Int)),
  piTyvarNext : Int,
  piEffvarNext : Int,
  piCore : List (String, PubScheme),
  piStandaloneNames : OrdMap Unit,
}

-- The four `GraphRun` values a cache hit restores.
public export data GraphRunSeed = GraphRunSeed {
  grsCtorExistentials : Map Int Unit,
  grsAnyExistentials : Bool,
  grsTyvarNext : Int,
  grsEffvarNext : Int,
}

-- ── freeze and thaw ─────────────────────────────────────────────────────────

-- Every mono of a value rebuilt over fresh cells, one cell per id.  Frozen and
-- thawed values both come out of this, so neither shares a cell with its source.
zonkMonoList : ZState -> List Mono -> (ZState, List Mono)
zonkMonoList = mapAccumL zonkMono

zonkSlot : PredicateSlot -> PredicateSlot
zonkSlot (PredicateSlot { psIface = iface, psArgs = (PSArgsKnown args), psBoundIds = ids }) = PredicateSlot {
  psIface = iface,
  psArgs = PSArgsKnown (snd (zonkMonoList emptyZonk args)),
  psBoundIds = ids,
}
zonkSlot slot = slot

zonkMethodSlot : MethodPredicateSlot -> MethodPredicateSlot
zonkMethodSlot (MethodPredicateSlot { mpsPredicate = p, mpsPositions = ps }) =
  MethodPredicateSlot { mpsPredicate = zonkSlot p, mpsPositions = ps }

zonkRecord : RecordInfo -> RecordInfo
zonkRecord (RecordInfo ids authIds result fields index) =
  let (z1, result1) = zonkMono emptyZonk result
  let (z2, fieldMonos) = zonkMonoList z1 (map snd fields)
  let (_, indexMonos) = zonkMonoList z2 (map snd (entries index))
  RecordInfo
    ids
    authIds
    result1
    (zipNames (map fst fields) fieldMonos)
    (M.fromList (zipNames (map fst (entries index)) indexMonos))

zipNames : List String -> List Mono -> List (String, Mono)
zipNames (n :: ns) (m :: ms) = (n, m) :: zipNames ns ms
zipNames _ _ = []

export
freezeScheme : Scheme -> PubScheme
freezeScheme s = freezePub s []

export
thawScheme : PubScheme -> Scheme
thawScheme p = (freezePub p.psScheme p.psContext).psScheme

mapSlots : (a -> a) -> List (k, List a) -> List (k, List a)
mapSlots f = map (row => (fst row, map f (snd row)))

export
freezeInterface : CrossRun ->
  GraphRun ->
  OrdMap (Ty, List (String, Int)) ->
  List (String, PubScheme) ->
  OrdMap Unit ->
  PreludeInterface
freezeInterface cross run externs core standalone = PreludeInterface {
  piFunNames = cross.universeFunNamesRef.value,
  piMethodDispatchIdx = cross.universeMethodDispatchIdxByIdRef.value,
  piDataCtors = cross.universeDataCtors.value,
  piCtorPop = spMap freezeScheme cross.universeCtorPop.value,
  piRecordPop = spMap zonkRecord cross.universeRecordPop.value,
  piBuiltinClasses = cross.builtinClassesRef.value,
  piFunPredicateSlots =
    mapSlots zonkSlot cross.crossModuleFunPredicateSlotsRef.value,
  piFunPredicateSlotsQual =
    mapSlots zonkSlot cross.crossModuleFunPredicateSlotsQualRef.value,
  piFunConstraintDeclared = cross.crossModuleFunConstraintDeclaredRef.value,
  piFunConstraintDeclaredQual =
    cross.crossModuleFunConstraintDeclaredQualRef.value,
  piMethodPredicateSlots =
    mapSlots zonkMethodSlot cross.crossModuleMethodPredicateSlotsRef.value,
  piMethodPredicateSlotsQual =
    mapSlots zonkMethodSlot cross.crossModuleMethodPredicateSlotsQualRef.value,
  piCtorExistentials = run.ctorExistentialsRef.value,
  piAnyExistentials = run.anyExistentialsRef.value,
  piExternNames = externs,
  piTyvarNext = run.tyvarCounter.value,
  piEffvarNext = run.effvarCounter.value,
  piCore = freezeRows core,
  piStandaloneNames = standalone,
}

-- The last published row per standalone name: a name in `globalS` that a
-- top-level definition shadows resolves to the definition, which is published
-- after it.
standaloneRows : OrdMap Unit -> List (String, Scheme) -> OrdMap Scheme
standaloneRows names rows =
  omFromPairs (filter (row => omHasKey (fst row) names) rows) omEmpty

-- Core's own obligation contexts by bare name, the rows that carry any.
hasObligations : List VecObl -> Bool
hasObligations [] = False
hasObligations _ = True

contextsOf : List (String, PubScheme) -> OrdMap (List VecObl)
contextsOf rows =
  omFromPairs
    (filter
      (row => hasObligations (snd row))
      (map (row => (fst row, (snd row).psContext)) rows))
    omEmpty

-- The graph's detached state from [pi]: fresh `Ref`s over fresh cells, so
-- nothing this drive writes reaches the interface or another drive.  [_ctx] is
-- the record the state will join; none of its fields is read.
export
thawInterface : GraphCtx ->
  PreludeInterface ->
  (ModuleBindings, List (String, PubScheme), CrossRun, GraphRunSeed)
thawInterface _ctx pi =
  let live = map (row => (fst row, thawScheme (snd row))) pi.piCore
  let bindings = ModuleBindings {
    mbSchemes = live,
    mbStandaloneSchemes = standaloneRows pi.piStandaloneNames live,
  }
  let cross = CrossRun {
    universeFunNamesRef = Ref pi.piFunNames,
    universeMethodDispatchIdxByIdRef = Ref pi.piMethodDispatchIdx,
    universeDataCtors = Ref pi.piDataCtors,
    universeCtorPop = Ref (spMap thawScheme pi.piCtorPop),
    universeRecordPop = Ref (spMap zonkRecord pi.piRecordPop),
    builtinClassesRef = Ref pi.piBuiltinClasses,
    crossModuleFunPredicateSlotsRef =
      Ref (mapSlots zonkSlot pi.piFunPredicateSlots),
    crossModuleFunPredicateSlotsQualRef =
      Ref (mapSlots zonkSlot pi.piFunPredicateSlotsQual),
    crossModuleFunConstraintDeclaredRef = Ref pi.piFunConstraintDeclared,
    crossModuleFunConstraintDeclaredQualRef =
      Ref pi.piFunConstraintDeclaredQual,
    crossModuleMethodPredicateSlotsRef =
      Ref (mapSlots zonkMethodSlot pi.piMethodPredicateSlots),
    crossModuleMethodPredicateSlotsQualRef =
      Ref (mapSlots zonkMethodSlot pi.piMethodPredicateSlotsQual),
    coreSchemeObligationsRef = Ref (contextsOf pi.piCore),
    crossModuleSchemeOblsQualRef = Ref [],
  }
  let seed = GraphRunSeed {
    grsCtorExistentials = pi.piCtorExistentials,
    grsAnyExistentials = pi.piAnyExistentials,
    grsTyvarNext = pi.piTyvarNext,
    grsEffvarNext = pi.piEffvarNext,
  }
  (bindings, pi.piCore, cross, seed)

-- ── the process cache ───────────────────────────────────────────────────────

-- [pceSections] pairs each interface with the IO joins it was built under; a
-- drive under any other join, or another generation, misses.
public export data PreludeCacheEntry = PreludeCacheEntry {
  pceGeneration : (Int, Int),
  pceSections : List (List (List Atom), PreludeInterface),
}

export
preludeCacheRef : Ref (Option PreludeCacheEntry)
preludeCacheRef = Ref None

export
seedPreludeInterface : (Int, Int) ->
  List (List (List Atom), PreludeInterface) ->
  Unit
seedPreludeInterface generation sections =
  preludeCacheRef := Some PreludeCacheEntry {
    pceGeneration = generation,
    pceSections = sections,
  }

-- Atoms carry no `Eq`; the identity key and the rendered authority together
-- name an atom of a normalized join.
joinKey : List Atom -> String
joinKey atoms = joinWith "," (map (a => "\{atomKey a} \{renderAtom a}") atoms)

export
preludeCacheHit : (Int, Int) -> List Atom -> Option PreludeInterface
preludeCacheHit generation join = match !preludeCacheRef
  None => None
  Some entry =>
    if entry.pceGeneration == generation then
      map
        snd
        (find
          (section => any (j => joinKey j == joinKey join) (fst section))
          entry.pceSections)
    else
      None

export
currentPreludeInterface : Unit -> List (List (List Atom), PreludeInterface)
currentPreludeInterface _ = match !preludeCacheRef
  None => []
  Some entry => entry.pceSections

-- ── the key an on-disk copy is validated against ────────────────────────────

-- [ikSources] is `(path, hash)` per source file, the hash being the SHA-256 of
-- the file's bytes; [ikCompiler] names the compiler that built the copy.  The
-- IO join is not part of the key: the sections of one copy are selected by it.
public export data InterfaceKey = InterfaceKey {
  ikFormat : Int,
  ikSources : List (String, String),
  ikCompiler : String,
}

export
interfaceKeyOf : Int -> List (String, String) -> String -> InterfaceKey
interfaceKeyOf format sources compiler = InterfaceKey {
  ikFormat = format,
  ikSources = sources,
  ikCompiler = compiler,
}

-- The first component that differs, or `None` when the keys agree.
export
keysMatch : InterfaceKey -> InterfaceKey -> Option String
keysMatch a b
  | a.ikFormat /= b.ikFormat = Some "format"
  | a.ikSources /= b.ikSources = Some "sources"
  | a.ikCompiler /= b.ikCompiler = Some "compiler"
  | otherwise = None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" false) (mem "TabKey" false) (mem "DataVis" false) (mem "Variant" false))))
(DUse false (UseGroup ("list") ((mem "mapAccumL" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true) (mem "entries" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "atomKey" false) (mem "renderAtom" false))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "freezePub" false) (mem "freezeRows" false) (mem "emptyZonk" false) (mem "zonkMono" false) (mem "ZState" false))))
(DUse false (UseGroup ("types" "registry") ((mem "SpellingPop" false) (mem "spMap" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" false) (mem "Scheme" false) (mem "IfaceRef" false) (mem "VecObl" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "GraphCtx" true) (mem "CrossRun" true) (mem "GraphRun" true) (mem "BuiltinClasses" false) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "MethodPredicateSlot" true) (mem "CDeclaredPrefix" false) (mem "RecordInfo" true) (mem "ModuleBindings" true))))
(DData Public "PreludeInterface" () ((variant "PreludeInterface" (ConNamed (field "piFunNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "piMethodDispatchIdx" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))) (field "piDataCtors" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyCon "DataVis") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant")))))) (field "piCtorPop" (TyApp (TyCon "SpellingPop") (TyCon "PubScheme"))) (field "piRecordPop" (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo"))) (field "piBuiltinClasses" (TyCon "BuiltinClasses")) (field "piFunPredicateSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "piFunPredicateSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "piFunConstraintDeclared" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix")))) (field "piFunConstraintDeclaredQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CDeclaredPrefix")))) (field "piMethodPredicateSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "piMethodPredicateSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "piCtorExistentials" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "piAnyExistentials" (TyCon "Bool")) (field "piExternNames" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))) (field "piTyvarNext" (TyCon "Int")) (field "piEffvarNext" (TyCon "Int")) (field "piCore" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (field "piStandaloneNames" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DData Public "GraphRunSeed" () ((variant "GraphRunSeed" (ConNamed (field "grsCtorExistentials" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "grsAnyExistentials" (TyCon "Bool")) (field "grsTyvarNext" (TyCon "Int")) (field "grsEffvarNext" (TyCon "Int"))))) ())
(DTypeSig false "zonkMonoList" (TyFun (TyCon "ZState") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyTuple (TyCon "ZState") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "zonkMonoList" () (EApp (EVar "mapAccumL") (EVar "zonkMono")))
(DTypeSig false "zonkSlot" (TyFun (TyCon "PredicateSlot") (TyCon "PredicateSlot")))
(DFunDef false "zonkSlot" ((PRec "PredicateSlot" ((rf "psIface" (PVar "iface")) (rf "psArgs" (PCon "PSArgsKnown" (PVar "args"))) (rf "psBoundIds" (PVar "ids"))) false)) (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EApp (EVar "snd") (EApp (EApp (EVar "zonkMonoList") (EVar "emptyZonk")) (EVar "args"))))) (fa "psBoundIds" (EVar "ids")))))
(DFunDef false "zonkSlot" ((PVar "slot")) (EVar "slot"))
(DTypeSig false "zonkMethodSlot" (TyFun (TyCon "MethodPredicateSlot") (TyCon "MethodPredicateSlot")))
(DFunDef false "zonkMethodSlot" ((PRec "MethodPredicateSlot" ((rf "mpsPredicate" (PVar "p")) (rf "mpsPositions" (PVar "ps"))) false)) (ERecordCreate "MethodPredicateSlot" ((fa "mpsPredicate" (EApp (EVar "zonkSlot") (EVar "p"))) (fa "mpsPositions" (EVar "ps")))))
(DTypeSig false "zonkRecord" (TyFun (TyCon "RecordInfo") (TyCon "RecordInfo")))
(DFunDef false "zonkRecord" ((PCon "RecordInfo" (PVar "ids") (PVar "authIds") (PVar "result") (PVar "fields") (PVar "index"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "result1")) (EApp (EApp (EVar "zonkMono") (EVar "emptyZonk")) (EVar "result"))) (DoLet false false (PTuple (PVar "z2") (PVar "fieldMonos")) (EApp (EApp (EVar "zonkMonoList") (EVar "z1")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "fields")))) (DoLet false false (PTuple PWild (PVar "indexMonos")) (EApp (EApp (EVar "zonkMonoList") (EVar "z2")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "entries") (EVar "index"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "RecordInfo") (EVar "ids")) (EVar "authIds")) (EVar "result1")) (EApp (EApp (EVar "zipNames") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "fields"))) (EVar "fieldMonos"))) (EApp (EVar "M.fromList") (EApp (EApp (EVar "zipNames") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "entries") (EVar "index")))) (EVar "indexMonos")))))))
(DTypeSig false "zipNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))
(DFunDef false "zipNames" ((PCons (PVar "n") (PVar "ns")) (PCons (PVar "m") (PVar "ms"))) (EBinOp "::" (ETuple (EVar "n") (EVar "m")) (EApp (EApp (EVar "zipNames") (EVar "ns")) (EVar "ms"))))
(DFunDef false "zipNames" (PWild PWild) (EListLit))
(DTypeSig true "freezeScheme" (TyFun (TyCon "Scheme") (TyCon "PubScheme")))
(DFunDef false "freezeScheme" ((PVar "s")) (EApp (EApp (EVar "freezePub") (EVar "s")) (EListLit)))
(DTypeSig true "thawScheme" (TyFun (TyCon "PubScheme") (TyCon "Scheme")))
(DFunDef false "thawScheme" ((PVar "p")) (EFieldAccess (EApp (EApp (EVar "freezePub") (EFieldAccess (EVar "p") "psScheme")) (EFieldAccess (EVar "p") "psContext")) "psScheme"))
(DTypeSig false "mapSlots" (TyFun (TyFun (TyVar "a") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyApp (TyCon "List") (TyVar "a")))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "mapSlots" ((PVar "f")) (EApp (EVar "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EApp (EApp (EVar "map") (EVar "f")) (EApp (EVar "snd") (EVar "row")))))))
(DTypeSig true "freezeInterface" (TyFun (TyCon "CrossRun") (TyFun (TyCon "GraphRun") (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "PreludeInterface")))))))
(DFunDef false "freezeInterface" ((PVar "cross") (PVar "run") (PVar "externs") (PVar "core") (PVar "standalone")) (ERecordCreate "PreludeInterface" ((fa "piFunNames" (EFieldAccess (EFieldAccess (EVar "cross") "universeFunNamesRef") "value")) (fa "piMethodDispatchIdx" (EFieldAccess (EFieldAccess (EVar "cross") "universeMethodDispatchIdxByIdRef") "value")) (fa "piDataCtors" (EFieldAccess (EFieldAccess (EVar "cross") "universeDataCtors") "value")) (fa "piCtorPop" (EApp (EApp (EVar "spMap") (EVar "freezeScheme")) (EFieldAccess (EFieldAccess (EVar "cross") "universeCtorPop") "value"))) (fa "piRecordPop" (EApp (EApp (EVar "spMap") (EVar "zonkRecord")) (EFieldAccess (EFieldAccess (EVar "cross") "universeRecordPop") "value"))) (fa "piBuiltinClasses" (EFieldAccess (EFieldAccess (EVar "cross") "builtinClassesRef") "value")) (fa "piFunPredicateSlots" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EFieldAccess (EFieldAccess (EVar "cross") "crossModuleFunPredicateSlotsRef") "value"))) (fa "piFunPredicateSlotsQual" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EFieldAccess (EFieldAccess (EVar "cross") "crossModuleFunPredicateSlotsQualRef") "value"))) (fa "piFunConstraintDeclared" (EFieldAccess (EFieldAccess (EVar "cross") "crossModuleFunConstraintDeclaredRef") "value")) (fa "piFunConstraintDeclaredQual" (EFieldAccess (EFieldAccess (EVar "cross") "crossModuleFunConstraintDeclaredQualRef") "value")) (fa "piMethodPredicateSlots" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EFieldAccess (EFieldAccess (EVar "cross") "crossModuleMethodPredicateSlotsRef") "value"))) (fa "piMethodPredicateSlotsQual" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EFieldAccess (EFieldAccess (EVar "cross") "crossModuleMethodPredicateSlotsQualRef") "value"))) (fa "piCtorExistentials" (EFieldAccess (EFieldAccess (EVar "run") "ctorExistentialsRef") "value")) (fa "piAnyExistentials" (EFieldAccess (EFieldAccess (EVar "run") "anyExistentialsRef") "value")) (fa "piExternNames" (EVar "externs")) (fa "piTyvarNext" (EFieldAccess (EFieldAccess (EVar "run") "tyvarCounter") "value")) (fa "piEffvarNext" (EFieldAccess (EFieldAccess (EVar "run") "effvarCounter") "value")) (fa "piCore" (EApp (EVar "freezeRows") (EVar "core"))) (fa "piStandaloneNames" (EVar "standalone")))))
(DTypeSig false "standaloneRows" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "OrdMap") (TyCon "Scheme")))))
(DFunDef false "standaloneRows" ((PVar "names") (PVar "rows")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "filter") (ELam ((PVar "row")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "row"))) (EVar "names")))) (EVar "rows"))) (EVar "omEmpty")))
(DTypeSig false "hasObligations" (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyCon "Bool")))
(DFunDef false "hasObligations" ((PList)) (EVar "False"))
(DFunDef false "hasObligations" (PWild) (EVar "True"))
(DTypeSig false "contextsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl")))))
(DFunDef false "contextsOf" ((PVar "rows")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "filter") (ELam ((PVar "row")) (EApp (EVar "hasObligations") (EApp (EVar "snd") (EVar "row"))))) (EApp (EApp (EVar "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EFieldAccess (EApp (EVar "snd") (EVar "row")) "psContext")))) (EVar "rows")))) (EVar "omEmpty")))
(DTypeSig true "thawInterface" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PreludeInterface") (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyCon "CrossRun") (TyCon "GraphRunSeed")))))
(DFunDef false "thawInterface" ((PVar "_ctx") (PVar "pi")) (EBlock (DoLet false false (PVar "live") (EApp (EApp (EVar "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EApp (EVar "thawScheme") (EApp (EVar "snd") (EVar "row")))))) (EFieldAccess (EVar "pi") "piCore"))) (DoLet false false (PVar "bindings") (ERecordCreate "ModuleBindings" ((fa "mbSchemes" (EVar "live")) (fa "mbStandaloneSchemes" (EApp (EApp (EVar "standaloneRows") (EFieldAccess (EVar "pi") "piStandaloneNames")) (EVar "live")))))) (DoLet false false (PVar "cross") (ERecordCreate "CrossRun" ((fa "universeFunNamesRef" (EApp (EVar "Ref") (EFieldAccess (EVar "pi") "piFunNames"))) (fa "universeMethodDispatchIdxByIdRef" (EApp (EVar "Ref") (EFieldAccess (EVar "pi") "piMethodDispatchIdx"))) (fa "universeDataCtors" (EApp (EVar "Ref") (EFieldAccess (EVar "pi") "piDataCtors"))) (fa "universeCtorPop" (EApp (EVar "Ref") (EApp (EApp (EVar "spMap") (EVar "thawScheme")) (EFieldAccess (EVar "pi") "piCtorPop")))) (fa "universeRecordPop" (EApp (EVar "Ref") (EApp (EApp (EVar "spMap") (EVar "zonkRecord")) (EFieldAccess (EVar "pi") "piRecordPop")))) (fa "builtinClassesRef" (EApp (EVar "Ref") (EFieldAccess (EVar "pi") "piBuiltinClasses"))) (fa "crossModuleFunPredicateSlotsRef" (EApp (EVar "Ref") (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EFieldAccess (EVar "pi") "piFunPredicateSlots")))) (fa "crossModuleFunPredicateSlotsQualRef" (EApp (EVar "Ref") (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EFieldAccess (EVar "pi") "piFunPredicateSlotsQual")))) (fa "crossModuleFunConstraintDeclaredRef" (EApp (EVar "Ref") (EFieldAccess (EVar "pi") "piFunConstraintDeclared"))) (fa "crossModuleFunConstraintDeclaredQualRef" (EApp (EVar "Ref") (EFieldAccess (EVar "pi") "piFunConstraintDeclaredQual"))) (fa "crossModuleMethodPredicateSlotsRef" (EApp (EVar "Ref") (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EFieldAccess (EVar "pi") "piMethodPredicateSlots")))) (fa "crossModuleMethodPredicateSlotsQualRef" (EApp (EVar "Ref") (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EFieldAccess (EVar "pi") "piMethodPredicateSlotsQual")))) (fa "coreSchemeObligationsRef" (EApp (EVar "Ref") (EApp (EVar "contextsOf") (EFieldAccess (EVar "pi") "piCore")))) (fa "crossModuleSchemeOblsQualRef" (EApp (EVar "Ref") (EListLit)))))) (DoLet false false (PVar "seed") (ERecordCreate "GraphRunSeed" ((fa "grsCtorExistentials" (EFieldAccess (EVar "pi") "piCtorExistentials")) (fa "grsAnyExistentials" (EFieldAccess (EVar "pi") "piAnyExistentials")) (fa "grsTyvarNext" (EFieldAccess (EVar "pi") "piTyvarNext")) (fa "grsEffvarNext" (EFieldAccess (EVar "pi") "piEffvarNext"))))) (DoExpr (ETuple (EVar "bindings") (EFieldAccess (EVar "pi") "piCore") (EVar "cross") (EVar "seed")))))
(DData Public "PreludeCacheEntry" () ((variant "PreludeCacheEntry" (ConNamed (field "pceGeneration" (TyTuple (TyCon "Int") (TyCon "Int"))) (field "pceSections" (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyCon "PreludeInterface"))))))) ())
(DTypeSig true "preludeCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "PreludeCacheEntry"))))
(DFunDef false "preludeCacheRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "seedPreludeInterface" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyCon "PreludeInterface"))) (TyCon "Unit"))))
(DFunDef false "seedPreludeInterface" ((PVar "generation") (PVar "sections")) (EApp (EApp (EVar "setRef") (EVar "preludeCacheRef")) (EApp (EVar "Some") (ERecordCreate "PreludeCacheEntry" ((fa "pceGeneration" (EVar "generation")) (fa "pceSections" (EVar "sections")))))))
(DTypeSig false "joinKey" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "joinKey" ((PVar "atoms")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "atomKey") (EVar "a")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "renderAtom") (EVar "a")))) (ELit (LString ""))))) (EVar "atoms"))))
(DTypeSig true "preludeCacheHit" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "Option") (TyCon "PreludeInterface")))))
(DFunDef false "preludeCacheHit" ((PVar "generation") (PVar "join")) (EMatch (EUnOp "!" (EVar "preludeCacheRef")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "entry")) () (EIf (EBinOp "==" (EFieldAccess (EVar "entry") "pceGeneration") (EVar "generation")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "find") (ELam ((PVar "section")) (EApp (EApp (EVar "any") (ELam ((PVar "j")) (EBinOp "==" (EApp (EVar "joinKey") (EVar "j")) (EApp (EVar "joinKey") (EVar "join"))))) (EApp (EVar "fst") (EVar "section"))))) (EFieldAccess (EVar "entry") "pceSections"))) (EVar "None")))))
(DTypeSig true "currentPreludeInterface" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyCon "PreludeInterface")))))
(DFunDef false "currentPreludeInterface" (PWild) (EMatch (EUnOp "!" (EVar "preludeCacheRef")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "entry")) () (EFieldAccess (EVar "entry") "pceSections"))))
(DData Public "InterfaceKey" () ((variant "InterfaceKey" (ConNamed (field "ikFormat" (TyCon "Int")) (field "ikSources" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "ikCompiler" (TyCon "String"))))) ())
(DTypeSig true "interfaceKeyOf" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "InterfaceKey")))))
(DFunDef false "interfaceKeyOf" ((PVar "format") (PVar "sources") (PVar "compiler")) (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "format")) (fa "ikSources" (EVar "sources")) (fa "ikCompiler" (EVar "compiler")))))
(DTypeSig true "keysMatch" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "InterfaceKey") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "keysMatch" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EFieldAccess (EVar "a") "ikFormat") (EFieldAccess (EVar "b") "ikFormat")) (EApp (EVar "Some") (ELit (LString "format"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "a") "ikSources") (EFieldAccess (EVar "b") "ikSources")) (EApp (EVar "Some") (ELit (LString "sources"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "a") "ikCompiler") (EFieldAccess (EVar "b") "ikCompiler")) (EApp (EVar "Some") (ELit (LString "compiler"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" false) (mem "TabKey" false) (mem "DataVis" false) (mem "Variant" false))))
(DUse false (UseGroup ("list") ((mem "mapAccumL" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("map") ((mem "Map" true) (mem "entries" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "atomKey" false) (mem "renderAtom" false))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "freezePub" false) (mem "freezeRows" false) (mem "emptyZonk" false) (mem "zonkMono" false) (mem "ZState" false))))
(DUse false (UseGroup ("types" "registry") ((mem "SpellingPop" false) (mem "spMap" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" false) (mem "Scheme" false) (mem "IfaceRef" false) (mem "VecObl" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "GraphCtx" true) (mem "CrossRun" true) (mem "GraphRun" true) (mem "BuiltinClasses" false) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "MethodPredicateSlot" true) (mem "CDeclaredPrefix" false) (mem "RecordInfo" true) (mem "ModuleBindings" true))))
(DData Public "PreludeInterface" () ((variant "PreludeInterface" (ConNamed (field "piFunNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "piMethodDispatchIdx" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int")))) (field "piDataCtors" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyCon "DataVis") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant")))))) (field "piCtorPop" (TyApp (TyCon "SpellingPop") (TyCon "PubScheme"))) (field "piRecordPop" (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo"))) (field "piBuiltinClasses" (TyCon "BuiltinClasses")) (field "piFunPredicateSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "piFunPredicateSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PredicateSlot"))))) (field "piFunConstraintDeclared" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CDeclaredPrefix")))) (field "piFunConstraintDeclaredQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CDeclaredPrefix")))) (field "piMethodPredicateSlots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "piMethodPredicateSlotsQual" (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "MethodPredicateSlot"))))) (field "piCtorExistentials" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "piAnyExistentials" (TyCon "Bool")) (field "piExternNames" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))) (field "piTyvarNext" (TyCon "Int")) (field "piEffvarNext" (TyCon "Int")) (field "piCore" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (field "piStandaloneNames" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DData Public "GraphRunSeed" () ((variant "GraphRunSeed" (ConNamed (field "grsCtorExistentials" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit"))) (field "grsAnyExistentials" (TyCon "Bool")) (field "grsTyvarNext" (TyCon "Int")) (field "grsEffvarNext" (TyCon "Int"))))) ())
(DTypeSig false "zonkMonoList" (TyFun (TyCon "ZState") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyTuple (TyCon "ZState") (TyApp (TyCon "List") (TyCon "Mono"))))))
(DFunDef false "zonkMonoList" () (EApp (EVar "mapAccumL") (EVar "zonkMono")))
(DTypeSig false "zonkSlot" (TyFun (TyCon "PredicateSlot") (TyCon "PredicateSlot")))
(DFunDef false "zonkSlot" ((PRec "PredicateSlot" ((rf "psIface" (PVar "iface")) (rf "psArgs" (PCon "PSArgsKnown" (PVar "args"))) (rf "psBoundIds" (PVar "ids"))) false)) (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EApp (EVar "PSArgsKnown") (EApp (EVar "snd") (EApp (EApp (EVar "zonkMonoList") (EVar "emptyZonk")) (EVar "args"))))) (fa "psBoundIds" (EVar "ids")))))
(DFunDef false "zonkSlot" ((PVar "slot")) (EVar "slot"))
(DTypeSig false "zonkMethodSlot" (TyFun (TyCon "MethodPredicateSlot") (TyCon "MethodPredicateSlot")))
(DFunDef false "zonkMethodSlot" ((PRec "MethodPredicateSlot" ((rf "mpsPredicate" (PVar "p")) (rf "mpsPositions" (PVar "ps"))) false)) (ERecordCreate "MethodPredicateSlot" ((fa "mpsPredicate" (EApp (EVar "zonkSlot") (EVar "p"))) (fa "mpsPositions" (EVar "ps")))))
(DTypeSig false "zonkRecord" (TyFun (TyCon "RecordInfo") (TyCon "RecordInfo")))
(DFunDef false "zonkRecord" ((PCon "RecordInfo" (PVar "ids") (PVar "authIds") (PVar "result") (PVar "fields") (PVar "index"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "result1")) (EApp (EApp (EVar "zonkMono") (EVar "emptyZonk")) (EVar "result"))) (DoLet false false (PTuple (PVar "z2") (PVar "fieldMonos")) (EApp (EApp (EVar "zonkMonoList") (EVar "z1")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "fields")))) (DoLet false false (PTuple PWild (PVar "indexMonos")) (EApp (EApp (EVar "zonkMonoList") (EVar "z2")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EVar "entries") (EMethodRef "index"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "RecordInfo") (EVar "ids")) (EVar "authIds")) (EVar "result1")) (EApp (EApp (EVar "zipNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "fields"))) (EVar "fieldMonos"))) (EApp (EVar "M.fromList") (EApp (EApp (EVar "zipNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "entries") (EMethodRef "index")))) (EVar "indexMonos")))))))
(DTypeSig false "zipNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))))
(DFunDef false "zipNames" ((PCons (PVar "n") (PVar "ns")) (PCons (PVar "m") (PVar "ms"))) (EBinOp "::" (ETuple (EVar "n") (EVar "m")) (EApp (EApp (EVar "zipNames") (EVar "ns")) (EVar "ms"))))
(DFunDef false "zipNames" (PWild PWild) (EListLit))
(DTypeSig true "freezeScheme" (TyFun (TyCon "Scheme") (TyCon "PubScheme")))
(DFunDef false "freezeScheme" ((PVar "s")) (EApp (EApp (EVar "freezePub") (EVar "s")) (EListLit)))
(DTypeSig true "thawScheme" (TyFun (TyCon "PubScheme") (TyCon "Scheme")))
(DFunDef false "thawScheme" ((PVar "p")) (EFieldAccess (EApp (EApp (EVar "freezePub") (EFieldAccess (EVar "p") "psScheme")) (EFieldAccess (EVar "p") "psContext")) "psScheme"))
(DTypeSig false "mapSlots" (TyFun (TyFun (TyVar "a") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyApp (TyCon "List") (TyVar "a")))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "mapSlots" ((PVar "f")) (EApp (EMethodRef "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EApp (EApp (EMethodRef "map") (EVar "f")) (EApp (EVar "snd") (EVar "row")))))))
(DTypeSig true "freezeInterface" (TyFun (TyCon "CrossRun") (TyFun (TyCon "GraphRun") (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "PreludeInterface")))))))
(DFunDef false "freezeInterface" ((PVar "cross") (PVar "run") (PVar "externs") (PVar "core") (PVar "standalone")) (ERecordCreate "PreludeInterface" ((fa "piFunNames" (EFieldAccess (EFieldAccess (EVar "cross") "universeFunNamesRef") "value")) (fa "piMethodDispatchIdx" (EFieldAccess (EFieldAccess (EVar "cross") "universeMethodDispatchIdxByIdRef") "value")) (fa "piDataCtors" (EFieldAccess (EFieldAccess (EVar "cross") "universeDataCtors") "value")) (fa "piCtorPop" (EApp (EApp (EVar "spMap") (EVar "freezeScheme")) (EFieldAccess (EFieldAccess (EVar "cross") "universeCtorPop") "value"))) (fa "piRecordPop" (EApp (EApp (EVar "spMap") (EVar "zonkRecord")) (EFieldAccess (EFieldAccess (EVar "cross") "universeRecordPop") "value"))) (fa "piBuiltinClasses" (EFieldAccess (EFieldAccess (EVar "cross") "builtinClassesRef") "value")) (fa "piFunPredicateSlots" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EFieldAccess (EFieldAccess (EVar "cross") "crossModuleFunPredicateSlotsRef") "value"))) (fa "piFunPredicateSlotsQual" (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EFieldAccess (EFieldAccess (EVar "cross") "crossModuleFunPredicateSlotsQualRef") "value"))) (fa "piFunConstraintDeclared" (EFieldAccess (EFieldAccess (EVar "cross") "crossModuleFunConstraintDeclaredRef") "value")) (fa "piFunConstraintDeclaredQual" (EFieldAccess (EFieldAccess (EVar "cross") "crossModuleFunConstraintDeclaredQualRef") "value")) (fa "piMethodPredicateSlots" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EFieldAccess (EFieldAccess (EVar "cross") "crossModuleMethodPredicateSlotsRef") "value"))) (fa "piMethodPredicateSlotsQual" (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EFieldAccess (EFieldAccess (EVar "cross") "crossModuleMethodPredicateSlotsQualRef") "value"))) (fa "piCtorExistentials" (EFieldAccess (EFieldAccess (EVar "run") "ctorExistentialsRef") "value")) (fa "piAnyExistentials" (EFieldAccess (EFieldAccess (EVar "run") "anyExistentialsRef") "value")) (fa "piExternNames" (EVar "externs")) (fa "piTyvarNext" (EFieldAccess (EFieldAccess (EVar "run") "tyvarCounter") "value")) (fa "piEffvarNext" (EFieldAccess (EFieldAccess (EVar "run") "effvarCounter") "value")) (fa "piCore" (EApp (EVar "freezeRows") (EVar "core"))) (fa "piStandaloneNames" (EVar "standalone")))))
(DTypeSig false "standaloneRows" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "OrdMap") (TyCon "Scheme")))))
(DFunDef false "standaloneRows" ((PVar "names") (PVar "rows")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "row")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "row"))) (EVar "names")))) (EVar "rows"))) (EVar "omEmpty")))
(DTypeSig false "hasObligations" (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyCon "Bool")))
(DFunDef false "hasObligations" ((PList)) (EVar "False"))
(DFunDef false "hasObligations" (PWild) (EVar "True"))
(DTypeSig false "contextsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl")))))
(DFunDef false "contextsOf" ((PVar "rows")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "row")) (EApp (EVar "hasObligations") (EApp (EVar "snd") (EVar "row"))))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EFieldAccess (EApp (EVar "snd") (EVar "row")) "psContext")))) (EVar "rows")))) (EVar "omEmpty")))
(DTypeSig true "thawInterface" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "PreludeInterface") (TyTuple (TyCon "ModuleBindings") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyCon "CrossRun") (TyCon "GraphRunSeed")))))
(DFunDef false "thawInterface" ((PVar "_ctx") (PVar "pi")) (EBlock (DoLet false false (PVar "live") (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "fst") (EVar "row")) (EApp (EVar "thawScheme") (EApp (EVar "snd") (EVar "row")))))) (EFieldAccess (EVar "pi") "piCore"))) (DoLet false false (PVar "bindings") (ERecordCreate "ModuleBindings" ((fa "mbSchemes" (EVar "live")) (fa "mbStandaloneSchemes" (EApp (EApp (EVar "standaloneRows") (EFieldAccess (EVar "pi") "piStandaloneNames")) (EVar "live")))))) (DoLet false false (PVar "cross") (ERecordCreate "CrossRun" ((fa "universeFunNamesRef" (EApp (EVar "Ref") (EFieldAccess (EVar "pi") "piFunNames"))) (fa "universeMethodDispatchIdxByIdRef" (EApp (EVar "Ref") (EFieldAccess (EVar "pi") "piMethodDispatchIdx"))) (fa "universeDataCtors" (EApp (EVar "Ref") (EFieldAccess (EVar "pi") "piDataCtors"))) (fa "universeCtorPop" (EApp (EVar "Ref") (EApp (EApp (EVar "spMap") (EVar "thawScheme")) (EFieldAccess (EVar "pi") "piCtorPop")))) (fa "universeRecordPop" (EApp (EVar "Ref") (EApp (EApp (EVar "spMap") (EVar "zonkRecord")) (EFieldAccess (EVar "pi") "piRecordPop")))) (fa "builtinClassesRef" (EApp (EVar "Ref") (EFieldAccess (EVar "pi") "piBuiltinClasses"))) (fa "crossModuleFunPredicateSlotsRef" (EApp (EVar "Ref") (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EFieldAccess (EVar "pi") "piFunPredicateSlots")))) (fa "crossModuleFunPredicateSlotsQualRef" (EApp (EVar "Ref") (EApp (EApp (EVar "mapSlots") (EVar "zonkSlot")) (EFieldAccess (EVar "pi") "piFunPredicateSlotsQual")))) (fa "crossModuleFunConstraintDeclaredRef" (EApp (EVar "Ref") (EFieldAccess (EVar "pi") "piFunConstraintDeclared"))) (fa "crossModuleFunConstraintDeclaredQualRef" (EApp (EVar "Ref") (EFieldAccess (EVar "pi") "piFunConstraintDeclaredQual"))) (fa "crossModuleMethodPredicateSlotsRef" (EApp (EVar "Ref") (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EFieldAccess (EVar "pi") "piMethodPredicateSlots")))) (fa "crossModuleMethodPredicateSlotsQualRef" (EApp (EVar "Ref") (EApp (EApp (EVar "mapSlots") (EVar "zonkMethodSlot")) (EFieldAccess (EVar "pi") "piMethodPredicateSlotsQual")))) (fa "coreSchemeObligationsRef" (EApp (EVar "Ref") (EApp (EVar "contextsOf") (EFieldAccess (EVar "pi") "piCore")))) (fa "crossModuleSchemeOblsQualRef" (EApp (EVar "Ref") (EListLit)))))) (DoLet false false (PVar "seed") (ERecordCreate "GraphRunSeed" ((fa "grsCtorExistentials" (EFieldAccess (EVar "pi") "piCtorExistentials")) (fa "grsAnyExistentials" (EFieldAccess (EVar "pi") "piAnyExistentials")) (fa "grsTyvarNext" (EFieldAccess (EVar "pi") "piTyvarNext")) (fa "grsEffvarNext" (EFieldAccess (EVar "pi") "piEffvarNext"))))) (DoExpr (ETuple (EVar "bindings") (EFieldAccess (EVar "pi") "piCore") (EVar "cross") (EVar "seed")))))
(DData Public "PreludeCacheEntry" () ((variant "PreludeCacheEntry" (ConNamed (field "pceGeneration" (TyTuple (TyCon "Int") (TyCon "Int"))) (field "pceSections" (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyCon "PreludeInterface"))))))) ())
(DTypeSig true "preludeCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "PreludeCacheEntry"))))
(DFunDef false "preludeCacheRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "seedPreludeInterface" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyCon "PreludeInterface"))) (TyCon "Unit"))))
(DFunDef false "seedPreludeInterface" ((PVar "generation") (PVar "sections")) (EApp (EApp (EVar "setRef") (EVar "preludeCacheRef")) (EApp (EVar "Some") (ERecordCreate "PreludeCacheEntry" ((fa "pceGeneration" (EVar "generation")) (fa "pceSections" (EVar "sections")))))))
(DTypeSig false "joinKey" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "joinKey" ((PVar "atoms")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "atomKey") (EVar "a")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "renderAtom") (EVar "a")))) (ELit (LString ""))))) (EVar "atoms"))))
(DTypeSig true "preludeCacheHit" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "Option") (TyCon "PreludeInterface")))))
(DFunDef false "preludeCacheHit" ((PVar "generation") (PVar "join")) (EMatch (EUnOp "!" (EVar "preludeCacheRef")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "entry")) () (EIf (EBinOp "==" (EFieldAccess (EVar "entry") "pceGeneration") (EVar "generation")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EDictApp "find") (ELam ((PVar "section")) (EApp (EApp (EDictApp "any") (ELam ((PVar "j")) (EBinOp "==" (EApp (EVar "joinKey") (EVar "j")) (EApp (EVar "joinKey") (EVar "join"))))) (EApp (EVar "fst") (EVar "section"))))) (EFieldAccess (EVar "entry") "pceSections"))) (EVar "None")))))
(DTypeSig true "currentPreludeInterface" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyCon "PreludeInterface")))))
(DFunDef false "currentPreludeInterface" (PWild) (EMatch (EUnOp "!" (EVar "preludeCacheRef")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "entry")) () (EFieldAccess (EVar "entry") "pceSections"))))
(DData Public "InterfaceKey" () ((variant "InterfaceKey" (ConNamed (field "ikFormat" (TyCon "Int")) (field "ikSources" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "ikCompiler" (TyCon "String"))))) ())
(DTypeSig true "interfaceKeyOf" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "InterfaceKey")))))
(DFunDef false "interfaceKeyOf" ((PVar "format") (PVar "sources") (PVar "compiler")) (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "format")) (fa "ikSources" (EVar "sources")) (fa "ikCompiler" (EVar "compiler")))))
(DTypeSig true "keysMatch" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "InterfaceKey") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "keysMatch" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EFieldAccess (EVar "a") "ikFormat") (EFieldAccess (EVar "b") "ikFormat")) (EApp (EVar "Some") (ELit (LString "format"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "a") "ikSources") (EFieldAccess (EVar "b") "ikSources")) (EApp (EVar "Some") (ELit (LString "sources"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "a") "ikCompiler") (EFieldAccess (EVar "b") "ikCompiler")) (EApp (EVar "Some") (ELit (LString "compiler"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
