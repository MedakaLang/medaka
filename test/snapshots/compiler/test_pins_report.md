# META
source_lines=178
stages=DESUGAR,MARK
# SOURCE
-- Command-layer grading for the typed known-red ledger. Engine runners return
-- raw outcomes; this module attaches a verdict without changing those outcomes.

import tools.doctest.{ExResult(..)}
import tools.prop_runner.{
  PropResult,
  PropStatus(..),
  PropFailureKind(..),
  propResultStatus,
  propResultFailureKind,
  propResultDetail,
  propResultEngine,
  propResultName,
  propResultPassed,
}
import tools.test_pins.{
  PinIndex,
  PinKind(..),
  PinObservation(..),
  PinVerdict(..),
  pinFromIndex,
  classifyPin,
  pinVerdictPassed,
  pinVerdictDetail,
}

public export data GradedProp = GradedProp PropResult (Option PinVerdict)

public export data GradedTest =
  | GradedTest String String Int ExResult (Option PinVerdict)

export
gradeProps : PinIndex -> String -> List PropResult -> List GradedProp
gradeProps index file rows = map (gradeProp index file) rows

gradeProp : PinIndex -> String -> PropResult -> GradedProp
gradeProp index file raw =
  let verdict =
    map
      (pin => classifyPin pin (propObservation raw))
      (pinFromIndex
        index
        file
        PropPin
        (propResultName raw)
        (propResultEngine raw))
  GradedProp raw verdict

propObservation : PropResult -> PinObservation
propObservation raw = match propResultStatus raw
  PropPassedResult => PinPassed
  PropFailedResult => match propResultFailureKind raw
    Some PropLawFalse => PinLawFailure
    _ => PinRuntimeError (propResultDetail raw)
  PropErroredResult => PinRuntimeError (propResultDetail raw)

export
gradeTests : PinIndex ->
  String ->
  List (String, String, Int, ExResult) ->
  List GradedTest
gradeTests index file rows = map (gradeTest index file) rows

gradeTest : PinIndex -> String -> (String, String, Int, ExResult) -> GradedTest
gradeTest index file (engine, name, line, raw) =
  let verdict =
    map
      (pin => classifyPin pin (testObservation raw))
      (pinFromIndex index file TestPin name engine)
  GradedTest engine name line raw verdict

testObservation : ExResult -> PinObservation
testObservation (Pass _ _) = PinPassed
testObservation (Fail detail _ _) = PinAssertionFailure detail
testObservation (Errored detail) = PinRuntimeError detail

export
gradedPropRaw : GradedProp -> PropResult
gradedPropRaw (GradedProp raw _) = raw

export
gradedPropVerdict : GradedProp -> Option PinVerdict
gradedPropVerdict (GradedProp _ verdict) = verdict

export
gradedPropPassed : GradedProp -> Bool
gradedPropPassed (GradedProp raw None) = propResultPassed raw
gradedPropPassed (GradedProp _ (Some verdict)) = pinVerdictPassed verdict

export
gradedPropStatus : GradedProp -> String
gradedPropStatus (GradedProp _ (Some (PinHeld _))) = "known-red"
gradedPropStatus (GradedProp raw _) = rawPropStatus raw

-- Grading is an overlay: JSON consumers need the engine outcome as well as
-- the ledger verdict, especially when a native error pin is deliberately held.
export
gradedPropRawStatus : GradedProp -> String
gradedPropRawStatus (GradedProp raw _) = rawPropStatus raw

rawPropStatus : PropResult -> String
rawPropStatus raw = match propResultStatus raw
  PropPassedResult => "pass"
  PropFailedResult => "fail"
  PropErroredResult => "error"

export
gradedPropIssue : GradedProp -> Option Int
gradedPropIssue (GradedProp _ verdict) = verdictIssue verdict

export
gradedPropPinDetail : GradedProp -> Option String
gradedPropPinDetail (GradedProp _ None) = None
gradedPropPinDetail (GradedProp _ (Some verdict)) =
  Some (pinVerdictDetail verdict)

export
gradedTestRaw : GradedTest -> (String, String, Int, ExResult)
gradedTestRaw (GradedTest engine name line raw _) = (engine, name, line, raw)

export
gradedTestVerdict : GradedTest -> Option PinVerdict
gradedTestVerdict (GradedTest _ _ _ _ verdict) = verdict

export
gradedTestPassed : GradedTest -> Bool
gradedTestPassed (GradedTest _ _ _ raw verdict) = match verdict
  Some value => pinVerdictPassed value
  None => rawTestPassed raw

rawTestPassed : ExResult -> Bool
rawTestPassed (Pass _ _) = True
rawTestPassed _ = False

export
gradedTestStatus : GradedTest -> String
gradedTestStatus (GradedTest _ _ _ raw verdict) = match verdict
  Some (PinHeld _) => "known-red"
  _ => rawTestStatus raw

export
gradedTestRawStatus : GradedTest -> String
gradedTestRawStatus (GradedTest _ _ _ raw _) = rawTestStatus raw

rawTestStatus : ExResult -> String
rawTestStatus (Pass _ _) = "pass"
rawTestStatus (Fail _ _ _) = "fail"
rawTestStatus (Errored _) = "error"

export
gradedTestIssue : GradedTest -> Option Int
gradedTestIssue (GradedTest _ _ _ _ verdict) = verdictIssue verdict

export
gradedTestPinDetail : GradedTest -> Option String
gradedTestPinDetail (GradedTest _ _ _ _ None) = None
gradedTestPinDetail (GradedTest _ _ _ _ (Some verdict)) =
  Some (pinVerdictDetail verdict)

verdictIssue : Option PinVerdict -> Option Int
verdictIssue None = None
verdictIssue (Some (PinHeld issue)) = Some issue
verdictIssue (Some (PinDrained issue)) = Some issue
verdictIssue (Some (PinChanged issue _)) = Some issue

export
knownRedCountProps : List GradedProp -> Int
knownRedCountProps [] = 0
knownRedCountProps ((GradedProp _ (Some (PinHeld _))) :: rest) =
  1 + knownRedCountProps rest
knownRedCountProps (_ :: rest) = knownRedCountProps rest

export
knownRedCountTests : List GradedTest -> Int
knownRedCountTests [] = 0
knownRedCountTests ((GradedTest _ _ _ _ (Some (PinHeld _))) :: rest) =
  1 + knownRedCountTests rest
knownRedCountTests (_ :: rest) = knownRedCountTests rest
# DESUGAR
(DUse false (UseGroup ("tools" "doctest") ((mem "ExResult" true))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropResult" false) (mem "PropStatus" true) (mem "PropFailureKind" true) (mem "propResultStatus" false) (mem "propResultFailureKind" false) (mem "propResultDetail" false) (mem "propResultEngine" false) (mem "propResultName" false) (mem "propResultPassed" false))))
(DUse false (UseGroup ("tools" "test_pins") ((mem "PinIndex" false) (mem "PinKind" true) (mem "PinObservation" true) (mem "PinVerdict" true) (mem "pinFromIndex" false) (mem "classifyPin" false) (mem "pinVerdictPassed" false) (mem "pinVerdictDetail" false))))
(DData Public "GradedProp" () ((variant "GradedProp" (ConPos (TyCon "PropResult") (TyApp (TyCon "Option") (TyCon "PinVerdict"))))) ())
(DData Public "GradedTest" () ((variant "GradedTest" (ConPos (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "ExResult") (TyApp (TyCon "Option") (TyCon "PinVerdict"))))) ())
(DTypeSig true "gradeProps" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyCon "GradedProp"))))))
(DFunDef false "gradeProps" ((PVar "index") (PVar "file") (PVar "rows")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "gradeProp") (EVar "index")) (EVar "file"))) (EVar "rows")))
(DTypeSig false "gradeProp" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyCon "PropResult") (TyCon "GradedProp")))))
(DFunDef false "gradeProp" ((PVar "index") (PVar "file") (PVar "raw")) (EBlock (DoLet false false (PVar "verdict") (EApp (EApp (EVar "map") (ELam ((PVar "pin")) (EApp (EApp (EVar "classifyPin") (EVar "pin")) (EApp (EVar "propObservation") (EVar "raw"))))) (EApp (EApp (EApp (EApp (EApp (EVar "pinFromIndex") (EVar "index")) (EVar "file")) (EVar "PropPin")) (EApp (EVar "propResultName") (EVar "raw"))) (EApp (EVar "propResultEngine") (EVar "raw"))))) (DoExpr (EApp (EApp (EVar "GradedProp") (EVar "raw")) (EVar "verdict")))))
(DTypeSig false "propObservation" (TyFun (TyCon "PropResult") (TyCon "PinObservation")))
(DFunDef false "propObservation" ((PVar "raw")) (EMatch (EApp (EVar "propResultStatus") (EVar "raw")) (arm (PCon "PropPassedResult") () (EVar "PinPassed")) (arm (PCon "PropFailedResult") () (EMatch (EApp (EVar "propResultFailureKind") (EVar "raw")) (arm (PCon "Some" (PCon "PropLawFalse")) () (EVar "PinLawFailure")) (arm PWild () (EApp (EVar "PinRuntimeError") (EApp (EVar "propResultDetail") (EVar "raw")))))) (arm (PCon "PropErroredResult") () (EApp (EVar "PinRuntimeError") (EApp (EVar "propResultDetail") (EVar "raw"))))))
(DTypeSig true "gradeTests" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyApp (TyCon "List") (TyCon "GradedTest"))))))
(DFunDef false "gradeTests" ((PVar "index") (PVar "file") (PVar "rows")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "gradeTest") (EVar "index")) (EVar "file"))) (EVar "rows")))
(DTypeSig false "gradeTest" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "ExResult")) (TyCon "GradedTest")))))
(DFunDef false "gradeTest" ((PVar "index") (PVar "file") (PTuple (PVar "engine") (PVar "name") (PVar "line") (PVar "raw"))) (EBlock (DoLet false false (PVar "verdict") (EApp (EApp (EVar "map") (ELam ((PVar "pin")) (EApp (EApp (EVar "classifyPin") (EVar "pin")) (EApp (EVar "testObservation") (EVar "raw"))))) (EApp (EApp (EApp (EApp (EApp (EVar "pinFromIndex") (EVar "index")) (EVar "file")) (EVar "TestPin")) (EVar "name")) (EVar "engine")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "GradedTest") (EVar "engine")) (EVar "name")) (EVar "line")) (EVar "raw")) (EVar "verdict")))))
(DTypeSig false "testObservation" (TyFun (TyCon "ExResult") (TyCon "PinObservation")))
(DFunDef false "testObservation" ((PCon "Pass" PWild PWild)) (EVar "PinPassed"))
(DFunDef false "testObservation" ((PCon "Fail" (PVar "detail") PWild PWild)) (EApp (EVar "PinAssertionFailure") (EVar "detail")))
(DFunDef false "testObservation" ((PCon "Errored" (PVar "detail"))) (EApp (EVar "PinRuntimeError") (EVar "detail")))
(DTypeSig true "gradedPropRaw" (TyFun (TyCon "GradedProp") (TyCon "PropResult")))
(DFunDef false "gradedPropRaw" ((PCon "GradedProp" (PVar "raw") PWild)) (EVar "raw"))
(DTypeSig true "gradedPropVerdict" (TyFun (TyCon "GradedProp") (TyApp (TyCon "Option") (TyCon "PinVerdict"))))
(DFunDef false "gradedPropVerdict" ((PCon "GradedProp" PWild (PVar "verdict"))) (EVar "verdict"))
(DTypeSig true "gradedPropPassed" (TyFun (TyCon "GradedProp") (TyCon "Bool")))
(DFunDef false "gradedPropPassed" ((PCon "GradedProp" (PVar "raw") (PCon "None"))) (EApp (EVar "propResultPassed") (EVar "raw")))
(DFunDef false "gradedPropPassed" ((PCon "GradedProp" PWild (PCon "Some" (PVar "verdict")))) (EApp (EVar "pinVerdictPassed") (EVar "verdict")))
(DTypeSig true "gradedPropStatus" (TyFun (TyCon "GradedProp") (TyCon "String")))
(DFunDef false "gradedPropStatus" ((PCon "GradedProp" PWild (PCon "Some" (PCon "PinHeld" PWild)))) (ELit (LString "known-red")))
(DFunDef false "gradedPropStatus" ((PCon "GradedProp" (PVar "raw") PWild)) (EApp (EVar "rawPropStatus") (EVar "raw")))
(DTypeSig true "gradedPropRawStatus" (TyFun (TyCon "GradedProp") (TyCon "String")))
(DFunDef false "gradedPropRawStatus" ((PCon "GradedProp" (PVar "raw") PWild)) (EApp (EVar "rawPropStatus") (EVar "raw")))
(DTypeSig false "rawPropStatus" (TyFun (TyCon "PropResult") (TyCon "String")))
(DFunDef false "rawPropStatus" ((PVar "raw")) (EMatch (EApp (EVar "propResultStatus") (EVar "raw")) (arm (PCon "PropPassedResult") () (ELit (LString "pass"))) (arm (PCon "PropFailedResult") () (ELit (LString "fail"))) (arm (PCon "PropErroredResult") () (ELit (LString "error")))))
(DTypeSig true "gradedPropIssue" (TyFun (TyCon "GradedProp") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "gradedPropIssue" ((PCon "GradedProp" PWild (PVar "verdict"))) (EApp (EVar "verdictIssue") (EVar "verdict")))
(DTypeSig true "gradedPropPinDetail" (TyFun (TyCon "GradedProp") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "gradedPropPinDetail" ((PCon "GradedProp" PWild (PCon "None"))) (EVar "None"))
(DFunDef false "gradedPropPinDetail" ((PCon "GradedProp" PWild (PCon "Some" (PVar "verdict")))) (EApp (EVar "Some") (EApp (EVar "pinVerdictDetail") (EVar "verdict"))))
(DTypeSig true "gradedTestRaw" (TyFun (TyCon "GradedTest") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))
(DFunDef false "gradedTestRaw" ((PCon "GradedTest" (PVar "engine") (PVar "name") (PVar "line") (PVar "raw") PWild)) (ETuple (EVar "engine") (EVar "name") (EVar "line") (EVar "raw")))
(DTypeSig true "gradedTestVerdict" (TyFun (TyCon "GradedTest") (TyApp (TyCon "Option") (TyCon "PinVerdict"))))
(DFunDef false "gradedTestVerdict" ((PCon "GradedTest" PWild PWild PWild PWild (PVar "verdict"))) (EVar "verdict"))
(DTypeSig true "gradedTestPassed" (TyFun (TyCon "GradedTest") (TyCon "Bool")))
(DFunDef false "gradedTestPassed" ((PCon "GradedTest" PWild PWild PWild (PVar "raw") (PVar "verdict"))) (EMatch (EVar "verdict") (arm (PCon "Some" (PVar "value")) () (EApp (EVar "pinVerdictPassed") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "rawTestPassed") (EVar "raw")))))
(DTypeSig false "rawTestPassed" (TyFun (TyCon "ExResult") (TyCon "Bool")))
(DFunDef false "rawTestPassed" ((PCon "Pass" PWild PWild)) (EVar "True"))
(DFunDef false "rawTestPassed" (PWild) (EVar "False"))
(DTypeSig true "gradedTestStatus" (TyFun (TyCon "GradedTest") (TyCon "String")))
(DFunDef false "gradedTestStatus" ((PCon "GradedTest" PWild PWild PWild (PVar "raw") (PVar "verdict"))) (EMatch (EVar "verdict") (arm (PCon "Some" (PCon "PinHeld" PWild)) () (ELit (LString "known-red"))) (arm PWild () (EApp (EVar "rawTestStatus") (EVar "raw")))))
(DTypeSig true "gradedTestRawStatus" (TyFun (TyCon "GradedTest") (TyCon "String")))
(DFunDef false "gradedTestRawStatus" ((PCon "GradedTest" PWild PWild PWild (PVar "raw") PWild)) (EApp (EVar "rawTestStatus") (EVar "raw")))
(DTypeSig false "rawTestStatus" (TyFun (TyCon "ExResult") (TyCon "String")))
(DFunDef false "rawTestStatus" ((PCon "Pass" PWild PWild)) (ELit (LString "pass")))
(DFunDef false "rawTestStatus" ((PCon "Fail" PWild PWild PWild)) (ELit (LString "fail")))
(DFunDef false "rawTestStatus" ((PCon "Errored" PWild)) (ELit (LString "error")))
(DTypeSig true "gradedTestIssue" (TyFun (TyCon "GradedTest") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "gradedTestIssue" ((PCon "GradedTest" PWild PWild PWild PWild (PVar "verdict"))) (EApp (EVar "verdictIssue") (EVar "verdict")))
(DTypeSig true "gradedTestPinDetail" (TyFun (TyCon "GradedTest") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "gradedTestPinDetail" ((PCon "GradedTest" PWild PWild PWild PWild (PCon "None"))) (EVar "None"))
(DFunDef false "gradedTestPinDetail" ((PCon "GradedTest" PWild PWild PWild PWild (PCon "Some" (PVar "verdict")))) (EApp (EVar "Some") (EApp (EVar "pinVerdictDetail") (EVar "verdict"))))
(DTypeSig false "verdictIssue" (TyFun (TyApp (TyCon "Option") (TyCon "PinVerdict")) (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "verdictIssue" ((PCon "None")) (EVar "None"))
(DFunDef false "verdictIssue" ((PCon "Some" (PCon "PinHeld" (PVar "issue")))) (EApp (EVar "Some") (EVar "issue")))
(DFunDef false "verdictIssue" ((PCon "Some" (PCon "PinDrained" (PVar "issue")))) (EApp (EVar "Some") (EVar "issue")))
(DFunDef false "verdictIssue" ((PCon "Some" (PCon "PinChanged" (PVar "issue") PWild))) (EApp (EVar "Some") (EVar "issue")))
(DTypeSig true "knownRedCountProps" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Int")))
(DFunDef false "knownRedCountProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "knownRedCountProps" ((PCons (PCon "GradedProp" PWild (PCon "Some" (PCon "PinHeld" PWild))) (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "knownRedCountProps") (EVar "rest"))))
(DFunDef false "knownRedCountProps" ((PCons PWild (PVar "rest"))) (EApp (EVar "knownRedCountProps") (EVar "rest")))
(DTypeSig true "knownRedCountTests" (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyCon "Int")))
(DFunDef false "knownRedCountTests" ((PList)) (ELit (LInt 0)))
(DFunDef false "knownRedCountTests" ((PCons (PCon "GradedTest" PWild PWild PWild PWild (PCon "Some" (PCon "PinHeld" PWild))) (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "knownRedCountTests") (EVar "rest"))))
(DFunDef false "knownRedCountTests" ((PCons PWild (PVar "rest"))) (EApp (EVar "knownRedCountTests") (EVar "rest")))
# MARK
(DUse false (UseGroup ("tools" "doctest") ((mem "ExResult" true))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "PropResult" false) (mem "PropStatus" true) (mem "PropFailureKind" true) (mem "propResultStatus" false) (mem "propResultFailureKind" false) (mem "propResultDetail" false) (mem "propResultEngine" false) (mem "propResultName" false) (mem "propResultPassed" false))))
(DUse false (UseGroup ("tools" "test_pins") ((mem "PinIndex" false) (mem "PinKind" true) (mem "PinObservation" true) (mem "PinVerdict" true) (mem "pinFromIndex" false) (mem "classifyPin" false) (mem "pinVerdictPassed" false) (mem "pinVerdictDetail" false))))
(DData Public "GradedProp" () ((variant "GradedProp" (ConPos (TyCon "PropResult") (TyApp (TyCon "Option") (TyCon "PinVerdict"))))) ())
(DData Public "GradedTest" () ((variant "GradedTest" (ConPos (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "ExResult") (TyApp (TyCon "Option") (TyCon "PinVerdict"))))) ())
(DTypeSig true "gradeProps" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "PropResult")) (TyApp (TyCon "List") (TyCon "GradedProp"))))))
(DFunDef false "gradeProps" ((PVar "index") (PVar "file") (PVar "rows")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "gradeProp") (EMethodRef "index")) (EVar "file"))) (EVar "rows")))
(DTypeSig false "gradeProp" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyCon "PropResult") (TyCon "GradedProp")))))
(DFunDef false "gradeProp" ((PVar "index") (PVar "file") (PVar "raw")) (EBlock (DoLet false false (PVar "verdict") (EApp (EApp (EMethodRef "map") (ELam ((PVar "pin")) (EApp (EApp (EVar "classifyPin") (EVar "pin")) (EApp (EVar "propObservation") (EVar "raw"))))) (EApp (EApp (EApp (EApp (EApp (EVar "pinFromIndex") (EMethodRef "index")) (EVar "file")) (EVar "PropPin")) (EApp (EVar "propResultName") (EVar "raw"))) (EApp (EVar "propResultEngine") (EVar "raw"))))) (DoExpr (EApp (EApp (EVar "GradedProp") (EVar "raw")) (EVar "verdict")))))
(DTypeSig false "propObservation" (TyFun (TyCon "PropResult") (TyCon "PinObservation")))
(DFunDef false "propObservation" ((PVar "raw")) (EMatch (EApp (EVar "propResultStatus") (EVar "raw")) (arm (PCon "PropPassedResult") () (EVar "PinPassed")) (arm (PCon "PropFailedResult") () (EMatch (EApp (EVar "propResultFailureKind") (EVar "raw")) (arm (PCon "Some" (PCon "PropLawFalse")) () (EVar "PinLawFailure")) (arm PWild () (EApp (EVar "PinRuntimeError") (EApp (EVar "propResultDetail") (EVar "raw")))))) (arm (PCon "PropErroredResult") () (EApp (EVar "PinRuntimeError") (EApp (EVar "propResultDetail") (EVar "raw"))))))
(DTypeSig true "gradeTests" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))) (TyApp (TyCon "List") (TyCon "GradedTest"))))))
(DFunDef false "gradeTests" ((PVar "index") (PVar "file") (PVar "rows")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "gradeTest") (EMethodRef "index")) (EVar "file"))) (EVar "rows")))
(DTypeSig false "gradeTest" (TyFun (TyCon "PinIndex") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "ExResult")) (TyCon "GradedTest")))))
(DFunDef false "gradeTest" ((PVar "index") (PVar "file") (PTuple (PVar "engine") (PVar "name") (PVar "line") (PVar "raw"))) (EBlock (DoLet false false (PVar "verdict") (EApp (EApp (EMethodRef "map") (ELam ((PVar "pin")) (EApp (EApp (EVar "classifyPin") (EVar "pin")) (EApp (EVar "testObservation") (EVar "raw"))))) (EApp (EApp (EApp (EApp (EApp (EVar "pinFromIndex") (EMethodRef "index")) (EVar "file")) (EVar "TestPin")) (EVar "name")) (EVar "engine")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "GradedTest") (EVar "engine")) (EVar "name")) (EVar "line")) (EVar "raw")) (EVar "verdict")))))
(DTypeSig false "testObservation" (TyFun (TyCon "ExResult") (TyCon "PinObservation")))
(DFunDef false "testObservation" ((PCon "Pass" PWild PWild)) (EVar "PinPassed"))
(DFunDef false "testObservation" ((PCon "Fail" (PVar "detail") PWild PWild)) (EApp (EVar "PinAssertionFailure") (EVar "detail")))
(DFunDef false "testObservation" ((PCon "Errored" (PVar "detail"))) (EApp (EVar "PinRuntimeError") (EVar "detail")))
(DTypeSig true "gradedPropRaw" (TyFun (TyCon "GradedProp") (TyCon "PropResult")))
(DFunDef false "gradedPropRaw" ((PCon "GradedProp" (PVar "raw") PWild)) (EVar "raw"))
(DTypeSig true "gradedPropVerdict" (TyFun (TyCon "GradedProp") (TyApp (TyCon "Option") (TyCon "PinVerdict"))))
(DFunDef false "gradedPropVerdict" ((PCon "GradedProp" PWild (PVar "verdict"))) (EVar "verdict"))
(DTypeSig true "gradedPropPassed" (TyFun (TyCon "GradedProp") (TyCon "Bool")))
(DFunDef false "gradedPropPassed" ((PCon "GradedProp" (PVar "raw") (PCon "None"))) (EApp (EVar "propResultPassed") (EVar "raw")))
(DFunDef false "gradedPropPassed" ((PCon "GradedProp" PWild (PCon "Some" (PVar "verdict")))) (EApp (EVar "pinVerdictPassed") (EVar "verdict")))
(DTypeSig true "gradedPropStatus" (TyFun (TyCon "GradedProp") (TyCon "String")))
(DFunDef false "gradedPropStatus" ((PCon "GradedProp" PWild (PCon "Some" (PCon "PinHeld" PWild)))) (ELit (LString "known-red")))
(DFunDef false "gradedPropStatus" ((PCon "GradedProp" (PVar "raw") PWild)) (EApp (EVar "rawPropStatus") (EVar "raw")))
(DTypeSig true "gradedPropRawStatus" (TyFun (TyCon "GradedProp") (TyCon "String")))
(DFunDef false "gradedPropRawStatus" ((PCon "GradedProp" (PVar "raw") PWild)) (EApp (EVar "rawPropStatus") (EVar "raw")))
(DTypeSig false "rawPropStatus" (TyFun (TyCon "PropResult") (TyCon "String")))
(DFunDef false "rawPropStatus" ((PVar "raw")) (EMatch (EApp (EVar "propResultStatus") (EVar "raw")) (arm (PCon "PropPassedResult") () (ELit (LString "pass"))) (arm (PCon "PropFailedResult") () (ELit (LString "fail"))) (arm (PCon "PropErroredResult") () (ELit (LString "error")))))
(DTypeSig true "gradedPropIssue" (TyFun (TyCon "GradedProp") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "gradedPropIssue" ((PCon "GradedProp" PWild (PVar "verdict"))) (EApp (EVar "verdictIssue") (EVar "verdict")))
(DTypeSig true "gradedPropPinDetail" (TyFun (TyCon "GradedProp") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "gradedPropPinDetail" ((PCon "GradedProp" PWild (PCon "None"))) (EVar "None"))
(DFunDef false "gradedPropPinDetail" ((PCon "GradedProp" PWild (PCon "Some" (PVar "verdict")))) (EApp (EVar "Some") (EApp (EVar "pinVerdictDetail") (EVar "verdict"))))
(DTypeSig true "gradedTestRaw" (TyFun (TyCon "GradedTest") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int") (TyCon "ExResult"))))
(DFunDef false "gradedTestRaw" ((PCon "GradedTest" (PVar "engine") (PVar "name") (PVar "line") (PVar "raw") PWild)) (ETuple (EVar "engine") (EVar "name") (EVar "line") (EVar "raw")))
(DTypeSig true "gradedTestVerdict" (TyFun (TyCon "GradedTest") (TyApp (TyCon "Option") (TyCon "PinVerdict"))))
(DFunDef false "gradedTestVerdict" ((PCon "GradedTest" PWild PWild PWild PWild (PVar "verdict"))) (EVar "verdict"))
(DTypeSig true "gradedTestPassed" (TyFun (TyCon "GradedTest") (TyCon "Bool")))
(DFunDef false "gradedTestPassed" ((PCon "GradedTest" PWild PWild PWild (PVar "raw") (PVar "verdict"))) (EMatch (EVar "verdict") (arm (PCon "Some" (PVar "value")) () (EApp (EVar "pinVerdictPassed") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "rawTestPassed") (EVar "raw")))))
(DTypeSig false "rawTestPassed" (TyFun (TyCon "ExResult") (TyCon "Bool")))
(DFunDef false "rawTestPassed" ((PCon "Pass" PWild PWild)) (EVar "True"))
(DFunDef false "rawTestPassed" (PWild) (EVar "False"))
(DTypeSig true "gradedTestStatus" (TyFun (TyCon "GradedTest") (TyCon "String")))
(DFunDef false "gradedTestStatus" ((PCon "GradedTest" PWild PWild PWild (PVar "raw") (PVar "verdict"))) (EMatch (EVar "verdict") (arm (PCon "Some" (PCon "PinHeld" PWild)) () (ELit (LString "known-red"))) (arm PWild () (EApp (EVar "rawTestStatus") (EVar "raw")))))
(DTypeSig true "gradedTestRawStatus" (TyFun (TyCon "GradedTest") (TyCon "String")))
(DFunDef false "gradedTestRawStatus" ((PCon "GradedTest" PWild PWild PWild (PVar "raw") PWild)) (EApp (EVar "rawTestStatus") (EVar "raw")))
(DTypeSig false "rawTestStatus" (TyFun (TyCon "ExResult") (TyCon "String")))
(DFunDef false "rawTestStatus" ((PCon "Pass" PWild PWild)) (ELit (LString "pass")))
(DFunDef false "rawTestStatus" ((PCon "Fail" PWild PWild PWild)) (ELit (LString "fail")))
(DFunDef false "rawTestStatus" ((PCon "Errored" PWild)) (ELit (LString "error")))
(DTypeSig true "gradedTestIssue" (TyFun (TyCon "GradedTest") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "gradedTestIssue" ((PCon "GradedTest" PWild PWild PWild PWild (PVar "verdict"))) (EApp (EVar "verdictIssue") (EVar "verdict")))
(DTypeSig true "gradedTestPinDetail" (TyFun (TyCon "GradedTest") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "gradedTestPinDetail" ((PCon "GradedTest" PWild PWild PWild PWild (PCon "None"))) (EVar "None"))
(DFunDef false "gradedTestPinDetail" ((PCon "GradedTest" PWild PWild PWild PWild (PCon "Some" (PVar "verdict")))) (EApp (EVar "Some") (EApp (EVar "pinVerdictDetail") (EVar "verdict"))))
(DTypeSig false "verdictIssue" (TyFun (TyApp (TyCon "Option") (TyCon "PinVerdict")) (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "verdictIssue" ((PCon "None")) (EVar "None"))
(DFunDef false "verdictIssue" ((PCon "Some" (PCon "PinHeld" (PVar "issue")))) (EApp (EVar "Some") (EVar "issue")))
(DFunDef false "verdictIssue" ((PCon "Some" (PCon "PinDrained" (PVar "issue")))) (EApp (EVar "Some") (EVar "issue")))
(DFunDef false "verdictIssue" ((PCon "Some" (PCon "PinChanged" (PVar "issue") PWild))) (EApp (EVar "Some") (EVar "issue")))
(DTypeSig true "knownRedCountProps" (TyFun (TyApp (TyCon "List") (TyCon "GradedProp")) (TyCon "Int")))
(DFunDef false "knownRedCountProps" ((PList)) (ELit (LInt 0)))
(DFunDef false "knownRedCountProps" ((PCons (PCon "GradedProp" PWild (PCon "Some" (PCon "PinHeld" PWild))) (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "knownRedCountProps") (EVar "rest"))))
(DFunDef false "knownRedCountProps" ((PCons PWild (PVar "rest"))) (EApp (EVar "knownRedCountProps") (EVar "rest")))
(DTypeSig true "knownRedCountTests" (TyFun (TyApp (TyCon "List") (TyCon "GradedTest")) (TyCon "Int")))
(DFunDef false "knownRedCountTests" ((PList)) (ELit (LInt 0)))
(DFunDef false "knownRedCountTests" ((PCons (PCon "GradedTest" PWild PWild PWild PWild (PCon "Some" (PCon "PinHeld" PWild))) (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "knownRedCountTests") (EVar "rest"))))
(DFunDef false "knownRedCountTests" ((PCons PWild (PVar "rest"))) (EApp (EVar "knownRedCountTests") (EVar "rest")))
