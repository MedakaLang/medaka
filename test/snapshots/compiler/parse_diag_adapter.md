# META
source_lines=26
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Loc(..)}
import frontend.parse_diagnostic.{
  ParseDiagnostic, ParseEdit(..), EditApplicability(..), diagnosticCode,
  diagnosticLoc, diagnosticHelp, diagnosticEdits, renderParseDiagnostic
}
import driver.diagnostic_value.{Diag(..), Fix(..), Severity(..)}

withPath : String -> Loc -> Loc
withPath path (Loc _ sl sc el ec) = Loc path sl sc el ec

machineFix : String -> List ParseEdit -> Option Fix
machineFix _ [] = None
machineFix path ((ParseEdit loc _ replacement MachineApplicable) :: _) =
  Some (Fix (withPath path loc) replacement)
machineFix path (_ :: rest) = machineFix path rest

export
parseDiagnosticToDiag : String -> ParseDiagnostic -> Diag
parseDiagnosticToDiag path diagnostic =
  Diag
    SevError
    (diagnosticCode diagnostic)
    (renderParseDiagnostic diagnostic)
    (Some (withPath path (diagnosticLoc diagnostic)))
    (diagnosticHelp diagnostic)
    (machineFix path (diagnosticEdits diagnostic))
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "ParseEdit" true) (mem "EditApplicability" true) (mem "diagnosticCode" false) (mem "diagnosticLoc" false) (mem "diagnosticHelp" false) (mem "diagnosticEdits" false) (mem "renderParseDiagnostic" false))))
(DUse false (UseGroup ("driver" "diagnostic_value") ((mem "Diag" true) (mem "Fix" true) (mem "Severity" true))))
(DTypeSig false "withPath" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Loc"))))
(DFunDef false "withPath" ((PVar "path") (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))
(DTypeSig false "machineFix" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ParseEdit")) (TyApp (TyCon "Option") (TyCon "Fix")))))
(DFunDef false "machineFix" (PWild (PList)) (EVar "None"))
(DFunDef false "machineFix" ((PVar "path") (PCons (PCon "ParseEdit" (PVar "loc") PWild (PVar "replacement") (PCon "MachineApplicable")) PWild)) (EApp (EVar "Some") (EApp (EApp (EVar "Fix") (EApp (EApp (EVar "withPath") (EVar "path")) (EVar "loc"))) (EVar "replacement"))))
(DFunDef false "machineFix" ((PVar "path") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "machineFix") (EVar "path")) (EVar "rest")))
(DTypeSig true "parseDiagnosticToDiag" (TyFun (TyCon "String") (TyFun (TyCon "ParseDiagnostic") (TyCon "Diag"))))
(DFunDef false "parseDiagnosticToDiag" ((PVar "path") (PVar "diagnostic")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "diagnosticCode") (EVar "diagnostic"))) (EApp (EVar "renderParseDiagnostic") (EVar "diagnostic"))) (EApp (EVar "Some") (EApp (EApp (EVar "withPath") (EVar "path")) (EApp (EVar "diagnosticLoc") (EVar "diagnostic"))))) (EApp (EVar "diagnosticHelp") (EVar "diagnostic"))) (EApp (EApp (EVar "machineFix") (EVar "path")) (EApp (EVar "diagnosticEdits") (EVar "diagnostic")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "ParseEdit" true) (mem "EditApplicability" true) (mem "diagnosticCode" false) (mem "diagnosticLoc" false) (mem "diagnosticHelp" false) (mem "diagnosticEdits" false) (mem "renderParseDiagnostic" false))))
(DUse false (UseGroup ("driver" "diagnostic_value") ((mem "Diag" true) (mem "Fix" true) (mem "Severity" true))))
(DTypeSig false "withPath" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Loc"))))
(DFunDef false "withPath" ((PVar "path") (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))
(DTypeSig false "machineFix" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ParseEdit")) (TyApp (TyCon "Option") (TyCon "Fix")))))
(DFunDef false "machineFix" (PWild (PList)) (EVar "None"))
(DFunDef false "machineFix" ((PVar "path") (PCons (PCon "ParseEdit" (PVar "loc") PWild (PVar "replacement") (PCon "MachineApplicable")) PWild)) (EApp (EVar "Some") (EApp (EApp (EVar "Fix") (EApp (EApp (EVar "withPath") (EVar "path")) (EVar "loc"))) (EVar "replacement"))))
(DFunDef false "machineFix" ((PVar "path") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "machineFix") (EVar "path")) (EVar "rest")))
(DTypeSig true "parseDiagnosticToDiag" (TyFun (TyCon "String") (TyFun (TyCon "ParseDiagnostic") (TyCon "Diag"))))
(DFunDef false "parseDiagnosticToDiag" ((PVar "path") (PVar "diagnostic")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "diagnosticCode") (EVar "diagnostic"))) (EApp (EVar "renderParseDiagnostic") (EVar "diagnostic"))) (EApp (EVar "Some") (EApp (EApp (EVar "withPath") (EVar "path")) (EApp (EVar "diagnosticLoc") (EVar "diagnostic"))))) (EApp (EVar "diagnosticHelp") (EVar "diagnostic"))) (EApp (EApp (EVar "machineFix") (EVar "path")) (EApp (EVar "diagnosticEdits") (EVar "diagnostic")))))
