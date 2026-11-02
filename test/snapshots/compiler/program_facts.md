# META
source_lines=123
stages=DESUGAR,MARK
# SOURCE
import types.symbol_origins.{SymbolOrigins}
-- The facts a typechecked program carries to the stages that read it: the
-- evidence index, the disposition table and the binder-type table, as one value.
-- A reader takes a `ProgramFacts` argument, or reads it off the `EvalEnv` it
-- evaluates in.
-- No inference and no table construction beyond `evIndexOf`: a leaf that imports
-- representation modules only, never `types.typecheck`.

import frontend.ast.{Decl, EvTable}
import frontend.ast.{SiblingPair}
import types.extern_source.{
  ExternSource, ExternHeadRows, ExternProvenance(..), sourceExterns
}
import types.route_key.{EvIndex, evIndexOf}
import types.disposition.{DispositionTable}
import types.runtime_types.{BinderTypeTable}
import types.publish.{CheckedProgram(..), EntryOutcome}
import types.tc_types.{DriveOutputs, ElabResult(..), ElabFacts(..)}
import types.capability_manifest.{CapabilityManifest}

-- `Option` fields are `None` for a program that was never typechecked, so an
-- untyped lowering reads absence.
public export data ProgramFacts = ProgramFacts {
  pfSymbolOrigins : Option SymbolOrigins,
  pfManifests : List CapabilityManifest,
  pfEvidence : EvIndex,
  pfDispositions : Option DispositionTable,
  pfBinders : Option BinderTypeTable,
  pfEntryOutcome : Option EntryOutcome,
  pfExternSources : Option (List ExternSource),
  pfSibling : List SiblingPair,
}

-- No evidence, no dispositions, no binders: untyped lowering and eval.
export
emptyFacts : ProgramFacts
emptyFacts = ProgramFacts {
  pfSymbolOrigins = None,
  pfManifests = [],
  pfEvidence = evIndexOf [],
  pfDispositions = None,
  pfBinders = None,
  pfEntryOutcome = None,
  pfExternSources = None,
  pfSibling = [],
}

export
factsOfChecked : CheckedProgram -> ProgramFacts
factsOfChecked c = ProgramFacts {
  pfSymbolOrigins = None,
  pfManifests = c.cpManifests,
  pfEvidence = evIndexOf c.cpEvidence,
  pfDispositions = Some c.cpDispositions,
  pfBinders = Some c.cpBinders,
  pfEntryOutcome = Some c.cpEntryOutcome,
  pfExternSources = None,
  pfSibling = [],
}

-- The facts of one elaboration, as it returned them: before `mangleUnitsEv`
-- renames the trees, so a caller that lowers mangled trees takes
-- `factsOfElabWith` and the table the mangle returned.
export
factsOfElab : ElabResult -> ProgramFacts
factsOfElab elab = factsOfElabWith elab.erEvidence elab

-- [elab]'s facts with [table] as its evidence.
factsOfElabWith : EvTable -> ElabResult -> ProgramFacts
factsOfElabWith table elab = ProgramFacts {
  pfSymbolOrigins = None,
  pfManifests = elab.erFacts.efManifests,
  pfEvidence = evIndexOf table,
  pfDispositions = Some elab.erDispositions,
  pfBinders = Some elab.erFacts.efBinders,
  pfEntryOutcome = Some elab.erFacts.efEntryOutcome,
  pfExternSources = None,
  pfSibling = [],
}

export
factsOfElabSources : (DriveOutputs -> List (String, List Decl) -> ExternHeadRows) ->
  DriveOutputs ->
  ElabResult ->
  EvTable ->
  ProgramFacts
factsOfElabSources project outputs elab table =
  withCheckedExternSources
    project
    outputs
    elab.erCore
    elab.erModules
    (factsOfElabWith table elab)

export
withCheckedExternSources : (DriveOutputs -> List (String, List Decl) -> ExternHeadRows) ->
  DriveOutputs ->
  List Decl ->
  List (String, List Decl) ->
  ProgramFacts ->
  ProgramFacts
withCheckedExternSources project outputs core modules facts =
  let sources =
    flatMap
      ((mid, decls) =>
        sourceExterns CheckedSource mid (project outputs [(mid, decls)]) decls)
      (("core", core) :: modules)
  { facts | pfExternSources = Some sources }

export
factsWithEvidence : EvTable -> ProgramFacts -> ProgramFacts
factsWithEvidence table facts = { facts | pfEvidence = evIndexOf table }

export
withSymbolOrigins : SymbolOrigins -> ProgramFacts -> ProgramFacts
withSymbolOrigins origins facts = { facts | pfSymbolOrigins = Some origins }

-- [facts] for the drive whose test sibling pairs are [sibling]
-- (`DriveInputs.diSibling`): the engines give each sibling its subject's full
-- view of its names.
export
withSibling : List SiblingPair -> ProgramFacts -> ProgramFacts
withSibling sibling facts = { facts | pfSibling = sibling }
# DESUGAR
(DUse false (UseGroup ("types" "symbol_origins") ((mem "SymbolOrigins" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "EvTable" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "SiblingPair" false))))
(DUse false (UseGroup ("types" "extern_source") ((mem "ExternSource" false) (mem "ExternHeadRows" false) (mem "ExternProvenance" true) (mem "sourceExterns" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "EvIndex" false) (mem "evIndexOf" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "DispositionTable" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderTypeTable" false))))
(DUse false (UseGroup ("types" "publish") ((mem "CheckedProgram" true) (mem "EntryOutcome" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveOutputs" false) (mem "ElabResult" true) (mem "ElabFacts" true))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "CapabilityManifest" false))))
(DData Public "ProgramFacts" () ((variant "ProgramFacts" (ConNamed (field "pfSymbolOrigins" (TyApp (TyCon "Option") (TyCon "SymbolOrigins"))) (field "pfManifests" (TyApp (TyCon "List") (TyCon "CapabilityManifest"))) (field "pfEvidence" (TyCon "EvIndex")) (field "pfDispositions" (TyApp (TyCon "Option") (TyCon "DispositionTable"))) (field "pfBinders" (TyApp (TyCon "Option") (TyCon "BinderTypeTable"))) (field "pfEntryOutcome" (TyApp (TyCon "Option") (TyCon "EntryOutcome"))) (field "pfExternSources" (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "ExternSource")))) (field "pfSibling" (TyApp (TyCon "List") (TyCon "SiblingPair")))))) ())
(DTypeSig true "emptyFacts" (TyCon "ProgramFacts"))
(DFunDef false "emptyFacts" () (ERecordCreate "ProgramFacts" ((fa "pfSymbolOrigins" (EVar "None")) (fa "pfManifests" (EListLit)) (fa "pfEvidence" (EApp (EVar "evIndexOf") (EListLit))) (fa "pfDispositions" (EVar "None")) (fa "pfBinders" (EVar "None")) (fa "pfEntryOutcome" (EVar "None")) (fa "pfExternSources" (EVar "None")) (fa "pfSibling" (EListLit)))))
(DTypeSig true "factsOfChecked" (TyFun (TyCon "CheckedProgram") (TyCon "ProgramFacts")))
(DFunDef false "factsOfChecked" ((PVar "c")) (ERecordCreate "ProgramFacts" ((fa "pfSymbolOrigins" (EVar "None")) (fa "pfManifests" (EFieldAccess (EVar "c") "cpManifests")) (fa "pfEvidence" (EApp (EVar "evIndexOf") (EFieldAccess (EVar "c") "cpEvidence"))) (fa "pfDispositions" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpDispositions"))) (fa "pfBinders" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpBinders"))) (fa "pfEntryOutcome" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpEntryOutcome"))) (fa "pfExternSources" (EVar "None")) (fa "pfSibling" (EListLit)))))
(DTypeSig true "factsOfElab" (TyFun (TyCon "ElabResult") (TyCon "ProgramFacts")))
(DFunDef false "factsOfElab" ((PVar "elab")) (EApp (EApp (EVar "factsOfElabWith") (EFieldAccess (EVar "elab") "erEvidence")) (EVar "elab")))
(DTypeSig false "factsOfElabWith" (TyFun (TyCon "EvTable") (TyFun (TyCon "ElabResult") (TyCon "ProgramFacts"))))
(DFunDef false "factsOfElabWith" ((PVar "table") (PVar "elab")) (ERecordCreate "ProgramFacts" ((fa "pfSymbolOrigins" (EVar "None")) (fa "pfManifests" (EFieldAccess (EFieldAccess (EVar "elab") "erFacts") "efManifests")) (fa "pfEvidence" (EApp (EVar "evIndexOf") (EVar "table"))) (fa "pfDispositions" (EApp (EVar "Some") (EFieldAccess (EVar "elab") "erDispositions"))) (fa "pfBinders" (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EVar "elab") "erFacts") "efBinders"))) (fa "pfEntryOutcome" (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EVar "elab") "erFacts") "efEntryOutcome"))) (fa "pfExternSources" (EVar "None")) (fa "pfSibling" (EListLit)))))
(DTypeSig true "factsOfElabSources" (TyFun (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ExternHeadRows"))) (TyFun (TyCon "DriveOutputs") (TyFun (TyCon "ElabResult") (TyFun (TyCon "EvTable") (TyCon "ProgramFacts"))))))
(DFunDef false "factsOfElabSources" ((PVar "project") (PVar "outputs") (PVar "elab") (PVar "table")) (EApp (EApp (EApp (EApp (EApp (EVar "withCheckedExternSources") (EVar "project")) (EVar "outputs")) (EFieldAccess (EVar "elab") "erCore")) (EFieldAccess (EVar "elab") "erModules")) (EApp (EApp (EVar "factsOfElabWith") (EVar "table")) (EVar "elab"))))
(DTypeSig true "withCheckedExternSources" (TyFun (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ExternHeadRows"))) (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts")))))))
(DFunDef false "withCheckedExternSources" ((PVar "project") (PVar "outputs") (PVar "core") (PVar "modules") (PVar "facts")) (EBlock (DoLet false false (PVar "sources") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EApp (EApp (EVar "sourceExterns") (EVar "CheckedSource")) (EVar "mid")) (EApp (EApp (EVar "project") (EVar "outputs")) (EListLit (ETuple (EVar "mid") (EVar "decls"))))) (EVar "decls")))) (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "core")) (EVar "modules")))) (DoExpr (ERecordUpdate (EVar "facts") ((fa "pfExternSources" (EApp (EVar "Some") (EVar "sources"))))))))
(DTypeSig true "factsWithEvidence" (TyFun (TyCon "EvTable") (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts"))))
(DFunDef false "factsWithEvidence" ((PVar "table") (PVar "facts")) (ERecordUpdate (EVar "facts") ((fa "pfEvidence" (EApp (EVar "evIndexOf") (EVar "table"))))))
(DTypeSig true "withSymbolOrigins" (TyFun (TyCon "SymbolOrigins") (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts"))))
(DFunDef false "withSymbolOrigins" ((PVar "origins") (PVar "facts")) (ERecordUpdate (EVar "facts") ((fa "pfSymbolOrigins" (EApp (EVar "Some") (EVar "origins"))))))
(DTypeSig true "withSibling" (TyFun (TyApp (TyCon "List") (TyCon "SiblingPair")) (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts"))))
(DFunDef false "withSibling" ((PVar "sibling") (PVar "facts")) (ERecordUpdate (EVar "facts") ((fa "pfSibling" (EVar "sibling")))))
# MARK
(DUse false (UseGroup ("types" "symbol_origins") ((mem "SymbolOrigins" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "EvTable" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "SiblingPair" false))))
(DUse false (UseGroup ("types" "extern_source") ((mem "ExternSource" false) (mem "ExternHeadRows" false) (mem "ExternProvenance" true) (mem "sourceExterns" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "EvIndex" false) (mem "evIndexOf" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "DispositionTable" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderTypeTable" false))))
(DUse false (UseGroup ("types" "publish") ((mem "CheckedProgram" true) (mem "EntryOutcome" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveOutputs" false) (mem "ElabResult" true) (mem "ElabFacts" true))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "CapabilityManifest" false))))
(DData Public "ProgramFacts" () ((variant "ProgramFacts" (ConNamed (field "pfSymbolOrigins" (TyApp (TyCon "Option") (TyCon "SymbolOrigins"))) (field "pfManifests" (TyApp (TyCon "List") (TyCon "CapabilityManifest"))) (field "pfEvidence" (TyCon "EvIndex")) (field "pfDispositions" (TyApp (TyCon "Option") (TyCon "DispositionTable"))) (field "pfBinders" (TyApp (TyCon "Option") (TyCon "BinderTypeTable"))) (field "pfEntryOutcome" (TyApp (TyCon "Option") (TyCon "EntryOutcome"))) (field "pfExternSources" (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "ExternSource")))) (field "pfSibling" (TyApp (TyCon "List") (TyCon "SiblingPair")))))) ())
(DTypeSig true "emptyFacts" (TyCon "ProgramFacts"))
(DFunDef false "emptyFacts" () (ERecordCreate "ProgramFacts" ((fa "pfSymbolOrigins" (EVar "None")) (fa "pfManifests" (EListLit)) (fa "pfEvidence" (EApp (EVar "evIndexOf") (EListLit))) (fa "pfDispositions" (EVar "None")) (fa "pfBinders" (EVar "None")) (fa "pfEntryOutcome" (EVar "None")) (fa "pfExternSources" (EVar "None")) (fa "pfSibling" (EListLit)))))
(DTypeSig true "factsOfChecked" (TyFun (TyCon "CheckedProgram") (TyCon "ProgramFacts")))
(DFunDef false "factsOfChecked" ((PVar "c")) (ERecordCreate "ProgramFacts" ((fa "pfSymbolOrigins" (EVar "None")) (fa "pfManifests" (EFieldAccess (EVar "c") "cpManifests")) (fa "pfEvidence" (EApp (EVar "evIndexOf") (EFieldAccess (EVar "c") "cpEvidence"))) (fa "pfDispositions" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpDispositions"))) (fa "pfBinders" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpBinders"))) (fa "pfEntryOutcome" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpEntryOutcome"))) (fa "pfExternSources" (EVar "None")) (fa "pfSibling" (EListLit)))))
(DTypeSig true "factsOfElab" (TyFun (TyCon "ElabResult") (TyCon "ProgramFacts")))
(DFunDef false "factsOfElab" ((PVar "elab")) (EApp (EApp (EVar "factsOfElabWith") (EFieldAccess (EVar "elab") "erEvidence")) (EVar "elab")))
(DTypeSig false "factsOfElabWith" (TyFun (TyCon "EvTable") (TyFun (TyCon "ElabResult") (TyCon "ProgramFacts"))))
(DFunDef false "factsOfElabWith" ((PVar "table") (PVar "elab")) (ERecordCreate "ProgramFacts" ((fa "pfSymbolOrigins" (EVar "None")) (fa "pfManifests" (EFieldAccess (EFieldAccess (EVar "elab") "erFacts") "efManifests")) (fa "pfEvidence" (EApp (EVar "evIndexOf") (EVar "table"))) (fa "pfDispositions" (EApp (EVar "Some") (EFieldAccess (EVar "elab") "erDispositions"))) (fa "pfBinders" (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EVar "elab") "erFacts") "efBinders"))) (fa "pfEntryOutcome" (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EVar "elab") "erFacts") "efEntryOutcome"))) (fa "pfExternSources" (EVar "None")) (fa "pfSibling" (EListLit)))))
(DTypeSig true "factsOfElabSources" (TyFun (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ExternHeadRows"))) (TyFun (TyCon "DriveOutputs") (TyFun (TyCon "ElabResult") (TyFun (TyCon "EvTable") (TyCon "ProgramFacts"))))))
(DFunDef false "factsOfElabSources" ((PVar "project") (PVar "outputs") (PVar "elab") (PVar "table")) (EApp (EApp (EApp (EApp (EApp (EVar "withCheckedExternSources") (EVar "project")) (EVar "outputs")) (EFieldAccess (EVar "elab") "erCore")) (EFieldAccess (EVar "elab") "erModules")) (EApp (EApp (EVar "factsOfElabWith") (EVar "table")) (EVar "elab"))))
(DTypeSig true "withCheckedExternSources" (TyFun (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ExternHeadRows"))) (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts")))))))
(DFunDef false "withCheckedExternSources" ((PVar "project") (PVar "outputs") (PVar "core") (PVar "modules") (PVar "facts")) (EBlock (DoLet false false (PVar "sources") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EApp (EApp (EVar "sourceExterns") (EVar "CheckedSource")) (EVar "mid")) (EApp (EApp (EVar "project") (EVar "outputs")) (EListLit (ETuple (EVar "mid") (EVar "decls"))))) (EVar "decls")))) (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "core")) (EVar "modules")))) (DoExpr (ERecordUpdate (EVar "facts") ((fa "pfExternSources" (EApp (EVar "Some") (EVar "sources"))))))))
(DTypeSig true "factsWithEvidence" (TyFun (TyCon "EvTable") (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts"))))
(DFunDef false "factsWithEvidence" ((PVar "table") (PVar "facts")) (ERecordUpdate (EVar "facts") ((fa "pfEvidence" (EApp (EVar "evIndexOf") (EVar "table"))))))
(DTypeSig true "withSymbolOrigins" (TyFun (TyCon "SymbolOrigins") (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts"))))
(DFunDef false "withSymbolOrigins" ((PVar "origins") (PVar "facts")) (ERecordUpdate (EVar "facts") ((fa "pfSymbolOrigins" (EApp (EVar "Some") (EVar "origins"))))))
(DTypeSig true "withSibling" (TyFun (TyApp (TyCon "List") (TyCon "SiblingPair")) (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts"))))
(DFunDef false "withSibling" ((PVar "sibling") (PVar "facts")) (ERecordUpdate (EVar "facts") ((fa "pfSibling" (EVar "sibling")))))
