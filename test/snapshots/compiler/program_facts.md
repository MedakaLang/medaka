# META
source_lines=135
stages=DESUGAR,MARK
# SOURCE
import types.symbol_origins.{SymbolOrigins}
-- The facts a typechecked program carries to the stages that read it: the
-- evidence index, the disposition table and the binder-type table, as one value,
-- plus the one run-owned cell that holds it for the duration of a bracketed
-- region.  A reader asks `factsNow` or takes a `ProgramFacts` argument.  The cell
-- is owned by the run that sets it.
-- No inference and no table construction beyond `evIndexOf`: a leaf that imports
-- representation modules only, never `types.typecheck`.

import frontend.ast.{Decl, EvTable}
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
}

-- The facts of one elaboration, as it returned them: before `mangleUnitsEv`
-- renames the trees, so a caller that lowers mangled trees takes
-- `factsOfElabWith` and the table the mangle returned.
export
factsOfElab : ElabResult -> ProgramFacts
factsOfElab elab = factsOfElabWith elab.erEvidence elab

-- [elab]'s facts with [table] as its evidence.
export
factsOfElabWith : EvTable -> ElabResult -> ProgramFacts
factsOfElabWith table elab = ProgramFacts {
  pfSymbolOrigins = None,
  pfManifests = elab.erFacts.efManifests,
  pfEvidence = evIndexOf table,
  pfDispositions = Some elab.erDispositions,
  pfBinders = Some elab.erFacts.efBinders,
  pfEntryOutcome = Some elab.erFacts.efEntryOutcome,
  pfExternSources = None,
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

currentFacts : Ref (Option ProgramFacts)
currentFacts = Ref None

-- Run [action] with [facts] current, then put back whatever was current before, so
-- brackets nest and follow one another.
export
withFacts : ProgramFacts -> (Unit -> <e> a) -> <e> a
withFacts facts action =
  let saved = !currentFacts
  currentFacts := Some facts
  let result = action ()
  currentFacts := saved
  result

-- The facts of the innermost enclosing `withFacts`; a read outside every bracket
-- is a panic.
export
factsNow : Unit -> ProgramFacts
factsNow _ = match !currentFacts
  Some facts => facts
  None => panic "program facts: read outside any withFacts bracket"

export
withSymbolOrigins : SymbolOrigins -> ProgramFacts -> ProgramFacts
withSymbolOrigins origins facts = { facts | pfSymbolOrigins = Some origins }
# DESUGAR
(DUse false (UseGroup ("types" "symbol_origins") ((mem "SymbolOrigins" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "EvTable" false))))
(DUse false (UseGroup ("types" "extern_source") ((mem "ExternSource" false) (mem "ExternHeadRows" false) (mem "ExternProvenance" true) (mem "sourceExterns" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "EvIndex" false) (mem "evIndexOf" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "DispositionTable" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderTypeTable" false))))
(DUse false (UseGroup ("types" "publish") ((mem "CheckedProgram" true) (mem "EntryOutcome" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveOutputs" false) (mem "ElabResult" true) (mem "ElabFacts" true))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "CapabilityManifest" false))))
(DData Public "ProgramFacts" () ((variant "ProgramFacts" (ConNamed (field "pfSymbolOrigins" (TyApp (TyCon "Option") (TyCon "SymbolOrigins"))) (field "pfManifests" (TyApp (TyCon "List") (TyCon "CapabilityManifest"))) (field "pfEvidence" (TyCon "EvIndex")) (field "pfDispositions" (TyApp (TyCon "Option") (TyCon "DispositionTable"))) (field "pfBinders" (TyApp (TyCon "Option") (TyCon "BinderTypeTable"))) (field "pfEntryOutcome" (TyApp (TyCon "Option") (TyCon "EntryOutcome"))) (field "pfExternSources" (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "ExternSource"))))))) ())
(DTypeSig true "emptyFacts" (TyCon "ProgramFacts"))
(DFunDef false "emptyFacts" () (ERecordCreate "ProgramFacts" ((fa "pfSymbolOrigins" (EVar "None")) (fa "pfManifests" (EListLit)) (fa "pfEvidence" (EApp (EVar "evIndexOf") (EListLit))) (fa "pfDispositions" (EVar "None")) (fa "pfBinders" (EVar "None")) (fa "pfEntryOutcome" (EVar "None")) (fa "pfExternSources" (EVar "None")))))
(DTypeSig true "factsOfChecked" (TyFun (TyCon "CheckedProgram") (TyCon "ProgramFacts")))
(DFunDef false "factsOfChecked" ((PVar "c")) (ERecordCreate "ProgramFacts" ((fa "pfSymbolOrigins" (EVar "None")) (fa "pfManifests" (EFieldAccess (EVar "c") "cpManifests")) (fa "pfEvidence" (EApp (EVar "evIndexOf") (EFieldAccess (EVar "c") "cpEvidence"))) (fa "pfDispositions" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpDispositions"))) (fa "pfBinders" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpBinders"))) (fa "pfEntryOutcome" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpEntryOutcome"))) (fa "pfExternSources" (EVar "None")))))
(DTypeSig true "factsOfElab" (TyFun (TyCon "ElabResult") (TyCon "ProgramFacts")))
(DFunDef false "factsOfElab" ((PVar "elab")) (EApp (EApp (EVar "factsOfElabWith") (EFieldAccess (EVar "elab") "erEvidence")) (EVar "elab")))
(DTypeSig true "factsOfElabWith" (TyFun (TyCon "EvTable") (TyFun (TyCon "ElabResult") (TyCon "ProgramFacts"))))
(DFunDef false "factsOfElabWith" ((PVar "table") (PVar "elab")) (ERecordCreate "ProgramFacts" ((fa "pfSymbolOrigins" (EVar "None")) (fa "pfManifests" (EFieldAccess (EFieldAccess (EVar "elab") "erFacts") "efManifests")) (fa "pfEvidence" (EApp (EVar "evIndexOf") (EVar "table"))) (fa "pfDispositions" (EApp (EVar "Some") (EFieldAccess (EVar "elab") "erDispositions"))) (fa "pfBinders" (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EVar "elab") "erFacts") "efBinders"))) (fa "pfEntryOutcome" (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EVar "elab") "erFacts") "efEntryOutcome"))) (fa "pfExternSources" (EVar "None")))))
(DTypeSig true "factsOfElabSources" (TyFun (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ExternHeadRows"))) (TyFun (TyCon "DriveOutputs") (TyFun (TyCon "ElabResult") (TyFun (TyCon "EvTable") (TyCon "ProgramFacts"))))))
(DFunDef false "factsOfElabSources" ((PVar "project") (PVar "outputs") (PVar "elab") (PVar "table")) (EApp (EApp (EApp (EApp (EApp (EVar "withCheckedExternSources") (EVar "project")) (EVar "outputs")) (EFieldAccess (EVar "elab") "erCore")) (EFieldAccess (EVar "elab") "erModules")) (EApp (EApp (EVar "factsOfElabWith") (EVar "table")) (EVar "elab"))))
(DTypeSig true "withCheckedExternSources" (TyFun (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ExternHeadRows"))) (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts")))))))
(DFunDef false "withCheckedExternSources" ((PVar "project") (PVar "outputs") (PVar "core") (PVar "modules") (PVar "facts")) (EBlock (DoLet false false (PVar "sources") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EApp (EApp (EVar "sourceExterns") (EVar "CheckedSource")) (EVar "mid")) (EApp (EApp (EVar "project") (EVar "outputs")) (EListLit (ETuple (EVar "mid") (EVar "decls"))))) (EVar "decls")))) (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "core")) (EVar "modules")))) (DoExpr (ERecordUpdate (EVar "facts") ((fa "pfExternSources" (EApp (EVar "Some") (EVar "sources"))))))))
(DTypeSig true "factsWithEvidence" (TyFun (TyCon "EvTable") (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts"))))
(DFunDef false "factsWithEvidence" ((PVar "table") (PVar "facts")) (ERecordUpdate (EVar "facts") ((fa "pfEvidence" (EApp (EVar "evIndexOf") (EVar "table"))))))
(DTypeSig false "currentFacts" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "ProgramFacts"))))
(DFunDef false "currentFacts" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "withFacts" (TyFun (TyCon "ProgramFacts") (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyEffect () (Some "e") (TyVar "a")))))
(DFunDef false "withFacts" ((PVar "facts") (PVar "action")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "currentFacts"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentFacts")) (EApp (EVar "Some") (EVar "facts")))) (DoLet false false (PVar "result") (EApp (EVar "action") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentFacts")) (EVar "saved"))) (DoExpr (EVar "result"))))
(DTypeSig true "factsNow" (TyFun (TyCon "Unit") (TyCon "ProgramFacts")))
(DFunDef false "factsNow" (PWild) (EMatch (EUnOp "!" (EVar "currentFacts")) (arm (PCon "Some" (PVar "facts")) () (EVar "facts")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "program facts: read outside any withFacts bracket"))))))
(DTypeSig true "withSymbolOrigins" (TyFun (TyCon "SymbolOrigins") (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts"))))
(DFunDef false "withSymbolOrigins" ((PVar "origins") (PVar "facts")) (ERecordUpdate (EVar "facts") ((fa "pfSymbolOrigins" (EApp (EVar "Some") (EVar "origins"))))))
# MARK
(DUse false (UseGroup ("types" "symbol_origins") ((mem "SymbolOrigins" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "EvTable" false))))
(DUse false (UseGroup ("types" "extern_source") ((mem "ExternSource" false) (mem "ExternHeadRows" false) (mem "ExternProvenance" true) (mem "sourceExterns" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "EvIndex" false) (mem "evIndexOf" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "DispositionTable" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderTypeTable" false))))
(DUse false (UseGroup ("types" "publish") ((mem "CheckedProgram" true) (mem "EntryOutcome" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveOutputs" false) (mem "ElabResult" true) (mem "ElabFacts" true))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "CapabilityManifest" false))))
(DData Public "ProgramFacts" () ((variant "ProgramFacts" (ConNamed (field "pfSymbolOrigins" (TyApp (TyCon "Option") (TyCon "SymbolOrigins"))) (field "pfManifests" (TyApp (TyCon "List") (TyCon "CapabilityManifest"))) (field "pfEvidence" (TyCon "EvIndex")) (field "pfDispositions" (TyApp (TyCon "Option") (TyCon "DispositionTable"))) (field "pfBinders" (TyApp (TyCon "Option") (TyCon "BinderTypeTable"))) (field "pfEntryOutcome" (TyApp (TyCon "Option") (TyCon "EntryOutcome"))) (field "pfExternSources" (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "ExternSource"))))))) ())
(DTypeSig true "emptyFacts" (TyCon "ProgramFacts"))
(DFunDef false "emptyFacts" () (ERecordCreate "ProgramFacts" ((fa "pfSymbolOrigins" (EVar "None")) (fa "pfManifests" (EListLit)) (fa "pfEvidence" (EApp (EVar "evIndexOf") (EListLit))) (fa "pfDispositions" (EVar "None")) (fa "pfBinders" (EVar "None")) (fa "pfEntryOutcome" (EVar "None")) (fa "pfExternSources" (EVar "None")))))
(DTypeSig true "factsOfChecked" (TyFun (TyCon "CheckedProgram") (TyCon "ProgramFacts")))
(DFunDef false "factsOfChecked" ((PVar "c")) (ERecordCreate "ProgramFacts" ((fa "pfSymbolOrigins" (EVar "None")) (fa "pfManifests" (EFieldAccess (EVar "c") "cpManifests")) (fa "pfEvidence" (EApp (EVar "evIndexOf") (EFieldAccess (EVar "c") "cpEvidence"))) (fa "pfDispositions" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpDispositions"))) (fa "pfBinders" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpBinders"))) (fa "pfEntryOutcome" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpEntryOutcome"))) (fa "pfExternSources" (EVar "None")))))
(DTypeSig true "factsOfElab" (TyFun (TyCon "ElabResult") (TyCon "ProgramFacts")))
(DFunDef false "factsOfElab" ((PVar "elab")) (EApp (EApp (EVar "factsOfElabWith") (EFieldAccess (EVar "elab") "erEvidence")) (EVar "elab")))
(DTypeSig true "factsOfElabWith" (TyFun (TyCon "EvTable") (TyFun (TyCon "ElabResult") (TyCon "ProgramFacts"))))
(DFunDef false "factsOfElabWith" ((PVar "table") (PVar "elab")) (ERecordCreate "ProgramFacts" ((fa "pfSymbolOrigins" (EVar "None")) (fa "pfManifests" (EFieldAccess (EFieldAccess (EVar "elab") "erFacts") "efManifests")) (fa "pfEvidence" (EApp (EVar "evIndexOf") (EVar "table"))) (fa "pfDispositions" (EApp (EVar "Some") (EFieldAccess (EVar "elab") "erDispositions"))) (fa "pfBinders" (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EVar "elab") "erFacts") "efBinders"))) (fa "pfEntryOutcome" (EApp (EVar "Some") (EFieldAccess (EFieldAccess (EVar "elab") "erFacts") "efEntryOutcome"))) (fa "pfExternSources" (EVar "None")))))
(DTypeSig true "factsOfElabSources" (TyFun (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ExternHeadRows"))) (TyFun (TyCon "DriveOutputs") (TyFun (TyCon "ElabResult") (TyFun (TyCon "EvTable") (TyCon "ProgramFacts"))))))
(DFunDef false "factsOfElabSources" ((PVar "project") (PVar "outputs") (PVar "elab") (PVar "table")) (EApp (EApp (EApp (EApp (EApp (EVar "withCheckedExternSources") (EVar "project")) (EVar "outputs")) (EFieldAccess (EVar "elab") "erCore")) (EFieldAccess (EVar "elab") "erModules")) (EApp (EApp (EVar "factsOfElabWith") (EVar "table")) (EVar "elab"))))
(DTypeSig true "withCheckedExternSources" (TyFun (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ExternHeadRows"))) (TyFun (TyCon "DriveOutputs") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts")))))))
(DFunDef false "withCheckedExternSources" ((PVar "project") (PVar "outputs") (PVar "core") (PVar "modules") (PVar "facts")) (EBlock (DoLet false false (PVar "sources") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EApp (EApp (EVar "sourceExterns") (EVar "CheckedSource")) (EVar "mid")) (EApp (EApp (EVar "project") (EVar "outputs")) (EListLit (ETuple (EVar "mid") (EVar "decls"))))) (EVar "decls")))) (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "core")) (EVar "modules")))) (DoExpr (ERecordUpdate (EVar "facts") ((fa "pfExternSources" (EApp (EVar "Some") (EVar "sources"))))))))
(DTypeSig true "factsWithEvidence" (TyFun (TyCon "EvTable") (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts"))))
(DFunDef false "factsWithEvidence" ((PVar "table") (PVar "facts")) (ERecordUpdate (EVar "facts") ((fa "pfEvidence" (EApp (EVar "evIndexOf") (EVar "table"))))))
(DTypeSig false "currentFacts" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "ProgramFacts"))))
(DFunDef false "currentFacts" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "withFacts" (TyFun (TyCon "ProgramFacts") (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyEffect () (Some "e") (TyVar "a")))))
(DFunDef false "withFacts" ((PVar "facts") (PVar "action")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "currentFacts"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentFacts")) (EApp (EVar "Some") (EVar "facts")))) (DoLet false false (PVar "result") (EApp (EVar "action") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentFacts")) (EVar "saved"))) (DoExpr (EVar "result"))))
(DTypeSig true "factsNow" (TyFun (TyCon "Unit") (TyCon "ProgramFacts")))
(DFunDef false "factsNow" (PWild) (EMatch (EUnOp "!" (EVar "currentFacts")) (arm (PCon "Some" (PVar "facts")) () (EVar "facts")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "program facts: read outside any withFacts bracket"))))))
(DTypeSig true "withSymbolOrigins" (TyFun (TyCon "SymbolOrigins") (TyFun (TyCon "ProgramFacts") (TyCon "ProgramFacts"))))
(DFunDef false "withSymbolOrigins" ((PVar "origins") (PVar "facts")) (ERecordUpdate (EVar "facts") ((fa "pfSymbolOrigins" (EApp (EVar "Some") (EVar "origins"))))))
