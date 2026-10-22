# META
source_lines=81
stages=DESUGAR,MARK
# SOURCE
-- The facts a typechecked program carries to the stages that read it: the
-- evidence index, the disposition table and the binder-type table, as one value,
-- plus the one run-owned cell that holds it for the duration of a bracketed
-- region.  A reader asks `factsNow` or takes a `ProgramFacts` argument.  The cell
-- is owned by the run that sets it.
-- No inference and no table construction beyond `evIndexOf`: a leaf that imports
-- representation modules only, never `types.typecheck`.

import frontend.ast.{EvTable}
import types.route_key.{EvIndex, evIndexOf}
import types.disposition.{DispositionTable}
import types.runtime_types.{BinderTypeTable}
import types.publish.{CheckedProgram(..), EntryOutcome}
import types.tc_types.{ElabResult, ElabFacts(..)}

-- `Option` fields are `None` for a program that was never typechecked, so an
-- untyped lowering reads absence.
public export data ProgramFacts = ProgramFacts {
  pfEvidence : EvIndex,
  pfDispositions : Option DispositionTable,
  pfBinders : Option BinderTypeTable,
  pfEntryOutcome : Option EntryOutcome,
}

-- No evidence, no dispositions, no binders: untyped lowering and eval.
export
emptyFacts : ProgramFacts
emptyFacts = ProgramFacts {
  pfEvidence = evIndexOf [],
  pfDispositions = None,
  pfBinders = None,
  pfEntryOutcome = None,
}

export
factsOfChecked : CheckedProgram -> ProgramFacts
factsOfChecked c = ProgramFacts {
  pfEvidence = evIndexOf c.cpEvidence,
  pfDispositions = Some c.cpDispositions,
  pfBinders = Some c.cpBinders,
  pfEntryOutcome = Some c.cpEntryOutcome,
}

-- The facts of one elaboration, as it returned them: before `mangleUnitsEv`
-- renames the trees, so a caller that lowers mangled trees takes
-- `factsOfElabWith` and the table the mangle returned.
export
factsOfElab : ElabResult -> ProgramFacts
factsOfElab (elab@(_, _, _, _, table, _, _)) = factsOfElabWith table elab

-- [elab]'s facts with [table] as its evidence.
export
factsOfElabWith : EvTable -> ElabResult -> ProgramFacts
factsOfElabWith table (_, _, _, _, _, dispositions, facts) = ProgramFacts {
  pfEvidence = evIndexOf table,
  pfDispositions = Some dispositions,
  pfBinders = Some facts.efBinders,
  pfEntryOutcome = Some facts.efEntryOutcome,
}

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
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "EvTable" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "EvIndex" false) (mem "evIndexOf" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "DispositionTable" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderTypeTable" false))))
(DUse false (UseGroup ("types" "publish") ((mem "CheckedProgram" true) (mem "EntryOutcome" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "ElabResult" false) (mem "ElabFacts" true))))
(DData Public "ProgramFacts" () ((variant "ProgramFacts" (ConNamed (field "pfEvidence" (TyCon "EvIndex")) (field "pfDispositions" (TyApp (TyCon "Option") (TyCon "DispositionTable"))) (field "pfBinders" (TyApp (TyCon "Option") (TyCon "BinderTypeTable"))) (field "pfEntryOutcome" (TyApp (TyCon "Option") (TyCon "EntryOutcome")))))) ())
(DTypeSig true "emptyFacts" (TyCon "ProgramFacts"))
(DFunDef false "emptyFacts" () (ERecordCreate "ProgramFacts" ((fa "pfEvidence" (EApp (EVar "evIndexOf") (EListLit))) (fa "pfDispositions" (EVar "None")) (fa "pfBinders" (EVar "None")) (fa "pfEntryOutcome" (EVar "None")))))
(DTypeSig true "factsOfChecked" (TyFun (TyCon "CheckedProgram") (TyCon "ProgramFacts")))
(DFunDef false "factsOfChecked" ((PVar "c")) (ERecordCreate "ProgramFacts" ((fa "pfEvidence" (EApp (EVar "evIndexOf") (EFieldAccess (EVar "c") "cpEvidence"))) (fa "pfDispositions" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpDispositions"))) (fa "pfBinders" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpBinders"))) (fa "pfEntryOutcome" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpEntryOutcome"))))))
(DTypeSig true "factsOfElab" (TyFun (TyCon "ElabResult") (TyCon "ProgramFacts")))
(DFunDef false "factsOfElab" ((PAs "elab" (PTuple PWild PWild PWild PWild (PVar "table") PWild PWild))) (EApp (EApp (EVar "factsOfElabWith") (EVar "table")) (EVar "elab")))
(DTypeSig true "factsOfElabWith" (TyFun (TyCon "EvTable") (TyFun (TyCon "ElabResult") (TyCon "ProgramFacts"))))
(DFunDef false "factsOfElabWith" ((PVar "table") (PTuple PWild PWild PWild PWild PWild (PVar "dispositions") (PVar "facts"))) (ERecordCreate "ProgramFacts" ((fa "pfEvidence" (EApp (EVar "evIndexOf") (EVar "table"))) (fa "pfDispositions" (EApp (EVar "Some") (EVar "dispositions"))) (fa "pfBinders" (EApp (EVar "Some") (EFieldAccess (EVar "facts") "efBinders"))) (fa "pfEntryOutcome" (EApp (EVar "Some") (EFieldAccess (EVar "facts") "efEntryOutcome"))))))
(DTypeSig false "currentFacts" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "ProgramFacts"))))
(DFunDef false "currentFacts" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "withFacts" (TyFun (TyCon "ProgramFacts") (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyEffect () (Some "e") (TyVar "a")))))
(DFunDef false "withFacts" ((PVar "facts") (PVar "action")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "currentFacts"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentFacts")) (EApp (EVar "Some") (EVar "facts")))) (DoLet false false (PVar "result") (EApp (EVar "action") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentFacts")) (EVar "saved"))) (DoExpr (EVar "result"))))
(DTypeSig true "factsNow" (TyFun (TyCon "Unit") (TyCon "ProgramFacts")))
(DFunDef false "factsNow" (PWild) (EMatch (EUnOp "!" (EVar "currentFacts")) (arm (PCon "Some" (PVar "facts")) () (EVar "facts")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "program facts: read outside any withFacts bracket"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "EvTable" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "EvIndex" false) (mem "evIndexOf" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "DispositionTable" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderTypeTable" false))))
(DUse false (UseGroup ("types" "publish") ((mem "CheckedProgram" true) (mem "EntryOutcome" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "ElabResult" false) (mem "ElabFacts" true))))
(DData Public "ProgramFacts" () ((variant "ProgramFacts" (ConNamed (field "pfEvidence" (TyCon "EvIndex")) (field "pfDispositions" (TyApp (TyCon "Option") (TyCon "DispositionTable"))) (field "pfBinders" (TyApp (TyCon "Option") (TyCon "BinderTypeTable"))) (field "pfEntryOutcome" (TyApp (TyCon "Option") (TyCon "EntryOutcome")))))) ())
(DTypeSig true "emptyFacts" (TyCon "ProgramFacts"))
(DFunDef false "emptyFacts" () (ERecordCreate "ProgramFacts" ((fa "pfEvidence" (EApp (EVar "evIndexOf") (EListLit))) (fa "pfDispositions" (EVar "None")) (fa "pfBinders" (EVar "None")) (fa "pfEntryOutcome" (EVar "None")))))
(DTypeSig true "factsOfChecked" (TyFun (TyCon "CheckedProgram") (TyCon "ProgramFacts")))
(DFunDef false "factsOfChecked" ((PVar "c")) (ERecordCreate "ProgramFacts" ((fa "pfEvidence" (EApp (EVar "evIndexOf") (EFieldAccess (EVar "c") "cpEvidence"))) (fa "pfDispositions" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpDispositions"))) (fa "pfBinders" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpBinders"))) (fa "pfEntryOutcome" (EApp (EVar "Some") (EFieldAccess (EVar "c") "cpEntryOutcome"))))))
(DTypeSig true "factsOfElab" (TyFun (TyCon "ElabResult") (TyCon "ProgramFacts")))
(DFunDef false "factsOfElab" ((PAs "elab" (PTuple PWild PWild PWild PWild (PVar "table") PWild PWild))) (EApp (EApp (EVar "factsOfElabWith") (EVar "table")) (EVar "elab")))
(DTypeSig true "factsOfElabWith" (TyFun (TyCon "EvTable") (TyFun (TyCon "ElabResult") (TyCon "ProgramFacts"))))
(DFunDef false "factsOfElabWith" ((PVar "table") (PTuple PWild PWild PWild PWild PWild (PVar "dispositions") (PVar "facts"))) (ERecordCreate "ProgramFacts" ((fa "pfEvidence" (EApp (EVar "evIndexOf") (EVar "table"))) (fa "pfDispositions" (EApp (EVar "Some") (EVar "dispositions"))) (fa "pfBinders" (EApp (EVar "Some") (EFieldAccess (EVar "facts") "efBinders"))) (fa "pfEntryOutcome" (EApp (EVar "Some") (EFieldAccess (EVar "facts") "efEntryOutcome"))))))
(DTypeSig false "currentFacts" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "ProgramFacts"))))
(DFunDef false "currentFacts" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "withFacts" (TyFun (TyCon "ProgramFacts") (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyEffect () (Some "e") (TyVar "a")))))
(DFunDef false "withFacts" ((PVar "facts") (PVar "action")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "currentFacts"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentFacts")) (EApp (EVar "Some") (EVar "facts")))) (DoLet false false (PVar "result") (EApp (EVar "action") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentFacts")) (EVar "saved"))) (DoExpr (EVar "result"))))
(DTypeSig true "factsNow" (TyFun (TyCon "Unit") (TyCon "ProgramFacts")))
(DFunDef false "factsNow" (PWild) (EMatch (EUnOp "!" (EVar "currentFacts")) (arm (PCon "Some" (PVar "facts")) () (EVar "facts")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "program facts: read outside any withFacts bracket"))))))
