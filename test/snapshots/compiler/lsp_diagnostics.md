# META
source_lines=50
stages=DESUGAR,MARK
# SOURCE
import driver.diagnostic_value.{Diag(..), Fix(..), Severity(..)}
import support.source_index.{SourceIndex}
import tools.lsp_positions.{locToLspRange}
import json.{Json(..), jObject}

severityCode : Severity -> Int
severityCode SevError = 1
severityCode SevWarning = 2

fields : Json -> Diag -> List (String, Json)
fields range (Diag sev code msg _ help _) =
  [
      ("range", range),
      ("severity", JInt (severityCode sev)),
      ("source", JString "medaka"),
      ("message", JString msg),
      ("code", JString code),
    ]
    ++ (match help
      Some h => [("help", JString h)]
      None => [])

export
diagnosticWithRange : Json -> Diag -> Json
diagnosticWithRange range d = jObject (fields range d)

fixField : SourceIndex -> Option Fix -> List (String, Json)
fixField index (Some (Fix loc replacement)) = [
  (
    "fix",
    jObject [
      ("range", optionOr JNull (locToLspRange index loc)),
      ("replacement", JString replacement),
    ],
  ),
]
fixField _ None = []

export
diagnosticJson : SourceIndex -> Diag -> Json
diagnosticJson index d = diagnosticJsonOr index JNull d

export
diagnosticJsonOr : SourceIndex -> Json -> Diag -> Json
diagnosticJsonOr index fallback (Diag sev code msg loc help fix) =
  let range = match loc
    Some l => optionOr JNull (locToLspRange index l)
    None => fallback
  let d = Diag sev code msg loc help fix
  jObject (fields range d ++ fixField index fix)
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostic_value") ((mem "Diag" true) (mem "Fix" true) (mem "Severity" true))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false))))
(DUse false (UseGroup ("tools" "lsp_positions") ((mem "locToLspRange" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false))))
(DTypeSig false "severityCode" (TyFun (TyCon "Severity") (TyCon "Int")))
(DFunDef false "severityCode" ((PCon "SevError")) (ELit (LInt 1)))
(DFunDef false "severityCode" ((PCon "SevWarning")) (ELit (LInt 2)))
(DTypeSig false "fields" (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "fields" ((PVar "range") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") PWild (PVar "help") PWild)) (EBinOp "++" (EListLit (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (EApp (EVar "severityCode") (EVar "sev")))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))) (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EVar "code")))) (EMatch (EVar "help") (arm (PCon "Some" (PVar "h")) () (EListLit (ETuple (ELit (LString "help")) (EApp (EVar "JString") (EVar "h"))))) (arm (PCon "None") () (EListLit)))))
(DTypeSig true "diagnosticWithRange" (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyCon "Json"))))
(DFunDef false "diagnosticWithRange" ((PVar "range") (PVar "d")) (EApp (EVar "jObject") (EApp (EApp (EVar "fields") (EVar "range")) (EVar "d"))))
(DTypeSig false "fixField" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "fixField" ((PVar "index") (PCon "Some" (PCon "Fix" (PVar "loc") (PVar "replacement")))) (EListLit (ETuple (ELit (LString "fix")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EVar "index")) (EVar "loc")))) (ETuple (ELit (LString "replacement")) (EApp (EVar "JString") (EVar "replacement"))))))))
(DFunDef false "fixField" (PWild (PCon "None")) (EListLit))
(DTypeSig true "diagnosticJson" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Diag") (TyCon "Json"))))
(DFunDef false "diagnosticJson" ((PVar "index") (PVar "d")) (EApp (EApp (EApp (EVar "diagnosticJsonOr") (EVar "index")) (EVar "JNull")) (EVar "d")))
(DTypeSig true "diagnosticJsonOr" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyCon "Json")))))
(DFunDef false "diagnosticJsonOr" ((PVar "index") (PVar "fallback") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") (PVar "loc") (PVar "help") (PVar "fix"))) (EBlock (DoLet false false (PVar "range") (EMatch (EVar "loc") (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EVar "index")) (EVar "l")))) (arm (PCon "None") () (EVar "fallback")))) (DoLet false false (PVar "d") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "sev")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "help")) (EVar "fix"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EApp (EApp (EVar "fields") (EVar "range")) (EVar "d")) (EApp (EApp (EVar "fixField") (EVar "index")) (EVar "fix")))))))
# MARK
(DUse false (UseGroup ("driver" "diagnostic_value") ((mem "Diag" true) (mem "Fix" true) (mem "Severity" true))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false))))
(DUse false (UseGroup ("tools" "lsp_positions") ((mem "locToLspRange" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false))))
(DTypeSig false "severityCode" (TyFun (TyCon "Severity") (TyCon "Int")))
(DFunDef false "severityCode" ((PCon "SevError")) (ELit (LInt 1)))
(DFunDef false "severityCode" ((PCon "SevWarning")) (ELit (LInt 2)))
(DTypeSig false "fields" (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "fields" ((PVar "range") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") PWild (PVar "help") PWild)) (EBinOp "++" (EListLit (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (EApp (EVar "severityCode") (EVar "sev")))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))) (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EVar "code")))) (EMatch (EVar "help") (arm (PCon "Some" (PVar "h")) () (EListLit (ETuple (ELit (LString "help")) (EApp (EVar "JString") (EVar "h"))))) (arm (PCon "None") () (EListLit)))))
(DTypeSig true "diagnosticWithRange" (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyCon "Json"))))
(DFunDef false "diagnosticWithRange" ((PVar "range") (PVar "d")) (EApp (EVar "jObject") (EApp (EApp (EVar "fields") (EVar "range")) (EVar "d"))))
(DTypeSig false "fixField" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "fixField" ((PVar "index") (PCon "Some" (PCon "Fix" (PVar "loc") (PVar "replacement")))) (EListLit (ETuple (ELit (LString "fix")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EMethodRef "index")) (EVar "loc")))) (ETuple (ELit (LString "replacement")) (EApp (EVar "JString") (EVar "replacement"))))))))
(DFunDef false "fixField" (PWild (PCon "None")) (EListLit))
(DTypeSig true "diagnosticJson" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Diag") (TyCon "Json"))))
(DFunDef false "diagnosticJson" ((PVar "index") (PVar "d")) (EApp (EApp (EApp (EVar "diagnosticJsonOr") (EMethodRef "index")) (EVar "JNull")) (EVar "d")))
(DTypeSig true "diagnosticJsonOr" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyCon "Json")))))
(DFunDef false "diagnosticJsonOr" ((PVar "index") (PVar "fallback") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") (PVar "loc") (PVar "help") (PVar "fix"))) (EBlock (DoLet false false (PVar "range") (EMatch (EVar "loc") (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EMethodRef "index")) (EVar "l")))) (arm (PCon "None") () (EVar "fallback")))) (DoLet false false (PVar "d") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "sev")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "help")) (EVar "fix"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EApp (EApp (EVar "fields") (EVar "range")) (EVar "d")) (EApp (EApp (EVar "fixField") (EMethodRef "index")) (EVar "fix")))))))
