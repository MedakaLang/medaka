# META
source_lines=176
stages=DESUGAR,MARK
# SOURCE
import driver.diagnostic_value.{
  Diag(..), Fix(..), DiagId(..), diagIdText, Severity(..)
}
import support.source_index.{SourceIndex, sourcePositionToOffset}
import tools.lsp_positions.{locToLspRange}
import tools.source_snapshot.{SourceSnapshot(..), SnapshotId(..), snapshotId}
import tools.source_edits.{SourceEdit(..), validateSourceEdits}
import frontend.syntax_source.{SourceSpan(..)}
import frontend.ast.{Loc(..)}
import frontend.parse_diagnostic.{
  ParseDiagnostic, ParseEdit(..), EditApplicability(..), diagnosticCode,
  diagnosticLoc, diagnosticEdits
}
import json.{Json(..), jObject, jArray}

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
      ("code", JString (diagIdText code)),
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
fixField index (Some (FixEdits applicability edits)) = [
  (
    "fix",
    jObject [
      ("applicability", JString applicability),
      (
        "edits",
        JArray
          (arrayFromList
            (map
              ((loc, replacement) => jObject [
                ("range", optionOr JNull (locToLspRange index loc)),
                ("replacement", JString replacement),
              ])
              edits)),
      ),
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

export
snapshotJson : SourceSnapshot -> Json
snapshotJson snapshot = match snapshotId snapshot
  SnapshotId uri generation => jObject [
    ("uri", JString uri),
    ("generation", JInt generation),
  ]

export
parseDiagnosticJson : SourceSnapshot -> Json -> Diag -> ParseDiagnostic -> Json
parseDiagnosticJson snapshot fallback d pd = match snapshot
  SourceSnapshot _ _ _ _ index => match d
    Diag _ code _ loc _ _ =>
      let base = diagnosticJsonOr index fallback d
      let matching =
        code == Coded (diagnosticCode pd)
          && (match loc
            Some l =>
              locToLspRange index l == locToLspRange index (diagnosticLoc pd)
            None => False)
      if matching
        && length (parseDiagnosticActions snapshot [pd]) > 0 then match base
        JObject fields =>
          jObject (toList fields ++ [("data", snapshotJson snapshot)])
        _ => base
      else
        base

actionForEdit : SourceSnapshot -> ParseEdit -> List Json
actionForEdit (snapshot@(SourceSnapshot uri version _ _ index)) (ParseEdit loc expected replacement applicability) =
  match loc
    Loc _ sl sc el ec => match (
      sourcePositionToOffset index sl sc,
      sourcePositionToOffset index el ec,
      locToLspRange index loc,
    )
      (Some start, Some end, Some range) =>
        if applicability == MachineApplicable
          && (match (validateSourceEdits snapshot [
            SourceEdit
              (snapshotId snapshot)
              (SourceSpan start end)
              expected
              replacement,
          ])
            Ok _ => True
            Err _ => False) then
          [
            jObject [
              ("title", JString ("Replace with " ++ replacement)),
              ("kind", JString "quickfix"),
              (
                "edit",
                jObject [
                  (
                    "documentChanges",
                    jArray [
                      jObject [
                        (
                          "textDocument",
                          jObject [
                            ("uri", JString uri),
                            (
                              "version",
                              match version
                                Some v => JInt v
                                None => JNull,
                            ),
                          ],
                        ),
                        (
                          "edits",
                          jArray [
                            jObject [
                              ("range", range),
                              ("newText", JString replacement),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ],
          ]
        else
          []
      _ => []

export
parseDiagnosticActions : SourceSnapshot -> List ParseDiagnostic -> List Json
parseDiagnosticActions snapshot diagnostics =
  flatMap
    (d => flatMap (actionForEdit snapshot) (diagnosticEdits d))
    diagnostics
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostic_value") ((mem "Diag" true) (mem "Fix" true) (mem "DiagId" true) (mem "diagIdText" false) (mem "Severity" true))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "sourcePositionToOffset" false))))
(DUse false (UseGroup ("tools" "lsp_positions") ((mem "locToLspRange" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceSnapshot" true) (mem "SnapshotId" true) (mem "snapshotId" false))))
(DUse false (UseGroup ("tools" "source_edits") ((mem "SourceEdit" true) (mem "validateSourceEdits" false))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "SourceSpan" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "ParseEdit" true) (mem "EditApplicability" true) (mem "diagnosticCode" false) (mem "diagnosticLoc" false) (mem "diagnosticEdits" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "jArray" false))))
(DTypeSig false "severityCode" (TyFun (TyCon "Severity") (TyCon "Int")))
(DFunDef false "severityCode" ((PCon "SevError")) (ELit (LInt 1)))
(DFunDef false "severityCode" ((PCon "SevWarning")) (ELit (LInt 2)))
(DTypeSig false "fields" (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "fields" ((PVar "range") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") PWild (PVar "help") PWild)) (EBinOp "++" (EListLit (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (EApp (EVar "severityCode") (EVar "sev")))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))) (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EApp (EVar "diagIdText") (EVar "code"))))) (EMatch (EVar "help") (arm (PCon "Some" (PVar "h")) () (EListLit (ETuple (ELit (LString "help")) (EApp (EVar "JString") (EVar "h"))))) (arm (PCon "None") () (EListLit)))))
(DTypeSig true "diagnosticWithRange" (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyCon "Json"))))
(DFunDef false "diagnosticWithRange" ((PVar "range") (PVar "d")) (EApp (EVar "jObject") (EApp (EApp (EVar "fields") (EVar "range")) (EVar "d"))))
(DTypeSig false "fixField" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "fixField" ((PVar "index") (PCon "Some" (PCon "Fix" (PVar "loc") (PVar "replacement")))) (EListLit (ETuple (ELit (LString "fix")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EVar "index")) (EVar "loc")))) (ETuple (ELit (LString "replacement")) (EApp (EVar "JString") (EVar "replacement"))))))))
(DFunDef false "fixField" ((PVar "index") (PCon "Some" (PCon "FixEdits" (PVar "applicability") (PVar "edits")))) (EListLit (ETuple (ELit (LString "fix")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "applicability")) (EApp (EVar "JString") (EVar "applicability"))) (ETuple (ELit (LString "edits")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "loc") (PVar "replacement"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EVar "index")) (EVar "loc")))) (ETuple (ELit (LString "replacement")) (EApp (EVar "JString") (EVar "replacement"))))))) (EVar "edits"))))))))))
(DFunDef false "fixField" (PWild (PCon "None")) (EListLit))
(DTypeSig true "diagnosticJson" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Diag") (TyCon "Json"))))
(DFunDef false "diagnosticJson" ((PVar "index") (PVar "d")) (EApp (EApp (EApp (EVar "diagnosticJsonOr") (EVar "index")) (EVar "JNull")) (EVar "d")))
(DTypeSig true "diagnosticJsonOr" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyCon "Json")))))
(DFunDef false "diagnosticJsonOr" ((PVar "index") (PVar "fallback") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") (PVar "loc") (PVar "help") (PVar "fix"))) (EBlock (DoLet false false (PVar "range") (EMatch (EVar "loc") (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EVar "index")) (EVar "l")))) (arm (PCon "None") () (EVar "fallback")))) (DoLet false false (PVar "d") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "sev")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "help")) (EVar "fix"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EApp (EApp (EVar "fields") (EVar "range")) (EVar "d")) (EApp (EApp (EVar "fixField") (EVar "index")) (EVar "fix")))))))
(DTypeSig true "snapshotJson" (TyFun (TyCon "SourceSnapshot") (TyCon "Json")))
(DFunDef false "snapshotJson" ((PVar "snapshot")) (EMatch (EApp (EVar "snapshotId") (EVar "snapshot")) (arm (PCon "SnapshotId" (PVar "uri") (PVar "generation")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "generation")) (EApp (EVar "JInt") (EVar "generation"))))))))
(DTypeSig true "parseDiagnosticJson" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyFun (TyCon "ParseDiagnostic") (TyCon "Json"))))))
(DFunDef false "parseDiagnosticJson" ((PVar "snapshot") (PVar "fallback") (PVar "d") (PVar "pd")) (EMatch (EVar "snapshot") (arm (PCon "SourceSnapshot" PWild PWild PWild PWild (PVar "index")) () (EMatch (EVar "d") (arm (PCon "Diag" PWild (PVar "code") PWild (PVar "loc") PWild PWild) () (EBlock (DoLet false false (PVar "base") (EApp (EApp (EApp (EVar "diagnosticJsonOr") (EVar "index")) (EVar "fallback")) (EVar "d"))) (DoLet false false (PVar "matching") (EBinOp "&&" (EBinOp "==" (EVar "code") (EApp (EVar "Coded") (EApp (EVar "diagnosticCode") (EVar "pd")))) (EMatch (EVar "loc") (arm (PCon "Some" (PVar "l")) () (EBinOp "==" (EApp (EApp (EVar "locToLspRange") (EVar "index")) (EVar "l")) (EApp (EApp (EVar "locToLspRange") (EVar "index")) (EApp (EVar "diagnosticLoc") (EVar "pd"))))) (arm (PCon "None") () (EVar "False"))))) (DoExpr (EIf (EBinOp "&&" (EVar "matching") (EBinOp ">" (EApp (EVar "length") (EApp (EApp (EVar "parseDiagnosticActions") (EVar "snapshot")) (EListLit (EVar "pd")))) (ELit (LInt 0)))) (EMatch (EVar "base") (arm (PCon "JObject" (PVar "fields")) () (EApp (EVar "jObject") (EBinOp "++" (EApp (EVar "toList") (EVar "fields")) (EListLit (ETuple (ELit (LString "data")) (EApp (EVar "snapshotJson") (EVar "snapshot"))))))) (arm PWild () (EVar "base"))) (EVar "base")))))))))
(DTypeSig false "actionForEdit" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "ParseEdit") (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "actionForEdit" ((PAs "snapshot" (PCon "SourceSnapshot" (PVar "uri") (PVar "version") PWild PWild (PVar "index"))) (PCon "ParseEdit" (PVar "loc") (PVar "expected") (PVar "replacement") (PVar "applicability"))) (EMatch (EVar "loc") (arm (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) () (EMatch (ETuple (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EVar "sl")) (EVar "sc")) (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EVar "el")) (EVar "ec")) (EApp (EApp (EVar "locToLspRange") (EVar "index")) (EVar "loc"))) (arm (PTuple (PCon "Some" (PVar "start")) (PCon "Some" (PVar "end")) (PCon "Some" (PVar "range"))) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "applicability") (EVar "MachineApplicable")) (EMatch (EApp (EApp (EVar "validateSourceEdits") (EVar "snapshot")) (EListLit (EApp (EApp (EApp (EApp (EVar "SourceEdit") (EApp (EVar "snapshotId") (EVar "snapshot"))) (EApp (EApp (EVar "SourceSpan") (EVar "start")) (EVar "end"))) (EVar "expected")) (EVar "replacement")))) (arm (PCon "Ok" PWild) () (EVar "True")) (arm (PCon "Err" PWild) () (EVar "False")))) (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "title")) (EApp (EVar "JString") (EBinOp "++" (ELit (LString "Replace with ")) (EVar "replacement")))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (ELit (LString "quickfix")))) (ETuple (ELit (LString "edit")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "documentChanges")) (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocument")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "version")) (EMatch (EVar "version") (arm (PCon "Some" (PVar "v")) () (EApp (EVar "JInt") (EVar "v"))) (arm (PCon "None") () (EVar "JNull"))))))) (ETuple (ELit (LString "edits")) (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "newText")) (EApp (EVar "JString") (EVar "replacement"))))))))))))))))))) (EListLit))) (arm PWild () (EListLit))))))
(DTypeSig true "parseDiagnosticActions" (TyFun (TyCon "SourceSnapshot") (TyFun (TyApp (TyCon "List") (TyCon "ParseDiagnostic")) (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "parseDiagnosticActions" ((PVar "snapshot") (PVar "diagnostics")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "d")) (EApp (EApp (EVar "flatMap") (EApp (EVar "actionForEdit") (EVar "snapshot"))) (EApp (EVar "diagnosticEdits") (EVar "d"))))) (EVar "diagnostics")))
# MARK
(DUse false (UseGroup ("driver" "diagnostic_value") ((mem "Diag" true) (mem "Fix" true) (mem "DiagId" true) (mem "diagIdText" false) (mem "Severity" true))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "sourcePositionToOffset" false))))
(DUse false (UseGroup ("tools" "lsp_positions") ((mem "locToLspRange" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceSnapshot" true) (mem "SnapshotId" true) (mem "snapshotId" false))))
(DUse false (UseGroup ("tools" "source_edits") ((mem "SourceEdit" true) (mem "validateSourceEdits" false))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "SourceSpan" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "ParseEdit" true) (mem "EditApplicability" true) (mem "diagnosticCode" false) (mem "diagnosticLoc" false) (mem "diagnosticEdits" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "jArray" false))))
(DTypeSig false "severityCode" (TyFun (TyCon "Severity") (TyCon "Int")))
(DFunDef false "severityCode" ((PCon "SevError")) (ELit (LInt 1)))
(DFunDef false "severityCode" ((PCon "SevWarning")) (ELit (LInt 2)))
(DTypeSig false "fields" (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "fields" ((PVar "range") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") PWild (PVar "help") PWild)) (EBinOp "++" (EListLit (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (EApp (EVar "severityCode") (EVar "sev")))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))) (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EApp (EVar "diagIdText") (EVar "code"))))) (EMatch (EVar "help") (arm (PCon "Some" (PVar "h")) () (EListLit (ETuple (ELit (LString "help")) (EApp (EVar "JString") (EVar "h"))))) (arm (PCon "None") () (EListLit)))))
(DTypeSig true "diagnosticWithRange" (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyCon "Json"))))
(DFunDef false "diagnosticWithRange" ((PVar "range") (PVar "d")) (EApp (EVar "jObject") (EApp (EApp (EVar "fields") (EVar "range")) (EVar "d"))))
(DTypeSig false "fixField" (TyFun (TyCon "SourceIndex") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "fixField" ((PVar "index") (PCon "Some" (PCon "Fix" (PVar "loc") (PVar "replacement")))) (EListLit (ETuple (ELit (LString "fix")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EMethodRef "index")) (EVar "loc")))) (ETuple (ELit (LString "replacement")) (EApp (EVar "JString") (EVar "replacement"))))))))
(DFunDef false "fixField" ((PVar "index") (PCon "Some" (PCon "FixEdits" (PVar "applicability") (PVar "edits")))) (EListLit (ETuple (ELit (LString "fix")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "applicability")) (EApp (EVar "JString") (EVar "applicability"))) (ETuple (ELit (LString "edits")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "loc") (PVar "replacement"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EMethodRef "index")) (EVar "loc")))) (ETuple (ELit (LString "replacement")) (EApp (EVar "JString") (EVar "replacement"))))))) (EVar "edits"))))))))))
(DFunDef false "fixField" (PWild (PCon "None")) (EListLit))
(DTypeSig true "diagnosticJson" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Diag") (TyCon "Json"))))
(DFunDef false "diagnosticJson" ((PVar "index") (PVar "d")) (EApp (EApp (EApp (EVar "diagnosticJsonOr") (EMethodRef "index")) (EVar "JNull")) (EVar "d")))
(DTypeSig true "diagnosticJsonOr" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyCon "Json")))))
(DFunDef false "diagnosticJsonOr" ((PVar "index") (PVar "fallback") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") (PVar "loc") (PVar "help") (PVar "fix"))) (EBlock (DoLet false false (PVar "range") (EMatch (EVar "loc") (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EMethodRef "index")) (EVar "l")))) (arm (PCon "None") () (EVar "fallback")))) (DoLet false false (PVar "d") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "sev")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "help")) (EVar "fix"))) (DoExpr (EApp (EVar "jObject") (EBinOp "++" (EApp (EApp (EVar "fields") (EVar "range")) (EVar "d")) (EApp (EApp (EVar "fixField") (EMethodRef "index")) (EVar "fix")))))))
(DTypeSig true "snapshotJson" (TyFun (TyCon "SourceSnapshot") (TyCon "Json")))
(DFunDef false "snapshotJson" ((PVar "snapshot")) (EMatch (EApp (EVar "snapshotId") (EVar "snapshot")) (arm (PCon "SnapshotId" (PVar "uri") (PVar "generation")) () (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "generation")) (EApp (EVar "JInt") (EVar "generation"))))))))
(DTypeSig true "parseDiagnosticJson" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "Json") (TyFun (TyCon "Diag") (TyFun (TyCon "ParseDiagnostic") (TyCon "Json"))))))
(DFunDef false "parseDiagnosticJson" ((PVar "snapshot") (PVar "fallback") (PVar "d") (PVar "pd")) (EMatch (EVar "snapshot") (arm (PCon "SourceSnapshot" PWild PWild PWild PWild (PVar "index")) () (EMatch (EVar "d") (arm (PCon "Diag" PWild (PVar "code") PWild (PVar "loc") PWild PWild) () (EBlock (DoLet false false (PVar "base") (EApp (EApp (EApp (EVar "diagnosticJsonOr") (EMethodRef "index")) (EVar "fallback")) (EVar "d"))) (DoLet false false (PVar "matching") (EBinOp "&&" (EBinOp "==" (EVar "code") (EApp (EVar "Coded") (EApp (EVar "diagnosticCode") (EVar "pd")))) (EMatch (EVar "loc") (arm (PCon "Some" (PVar "l")) () (EBinOp "==" (EApp (EApp (EVar "locToLspRange") (EMethodRef "index")) (EVar "l")) (EApp (EApp (EVar "locToLspRange") (EMethodRef "index")) (EApp (EVar "diagnosticLoc") (EVar "pd"))))) (arm (PCon "None") () (EVar "False"))))) (DoExpr (EIf (EBinOp "&&" (EVar "matching") (EBinOp ">" (EApp (EMethodRef "length") (EApp (EApp (EVar "parseDiagnosticActions") (EVar "snapshot")) (EListLit (EVar "pd")))) (ELit (LInt 0)))) (EMatch (EVar "base") (arm (PCon "JObject" (PVar "fields")) () (EApp (EVar "jObject") (EBinOp "++" (EApp (EMethodRef "toList") (EVar "fields")) (EListLit (ETuple (ELit (LString "data")) (EApp (EVar "snapshotJson") (EVar "snapshot"))))))) (arm PWild () (EVar "base"))) (EVar "base")))))))))
(DTypeSig false "actionForEdit" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "ParseEdit") (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "actionForEdit" ((PAs "snapshot" (PCon "SourceSnapshot" (PVar "uri") (PVar "version") PWild PWild (PVar "index"))) (PCon "ParseEdit" (PVar "loc") (PVar "expected") (PVar "replacement") (PVar "applicability"))) (EMatch (EVar "loc") (arm (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) () (EMatch (ETuple (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EVar "sl")) (EVar "sc")) (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EVar "el")) (EVar "ec")) (EApp (EApp (EVar "locToLspRange") (EMethodRef "index")) (EVar "loc"))) (arm (PTuple (PCon "Some" (PVar "start")) (PCon "Some" (PVar "end")) (PCon "Some" (PVar "range"))) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "applicability") (EVar "MachineApplicable")) (EMatch (EApp (EApp (EVar "validateSourceEdits") (EVar "snapshot")) (EListLit (EApp (EApp (EApp (EApp (EVar "SourceEdit") (EApp (EVar "snapshotId") (EVar "snapshot"))) (EApp (EApp (EVar "SourceSpan") (EVar "start")) (EVar "end"))) (EVar "expected")) (EVar "replacement")))) (arm (PCon "Ok" PWild) () (EVar "True")) (arm (PCon "Err" PWild) () (EVar "False")))) (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "title")) (EApp (EVar "JString") (EBinOp "++" (ELit (LString "Replace with ")) (EVar "replacement")))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (ELit (LString "quickfix")))) (ETuple (ELit (LString "edit")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "documentChanges")) (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "textDocument")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "uri")) (EApp (EVar "JString") (EVar "uri"))) (ETuple (ELit (LString "version")) (EMatch (EVar "version") (arm (PCon "Some" (PVar "v")) () (EApp (EVar "JInt") (EVar "v"))) (arm (PCon "None") () (EVar "JNull"))))))) (ETuple (ELit (LString "edits")) (EApp (EVar "jArray") (EListLit (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "newText")) (EApp (EVar "JString") (EVar "replacement"))))))))))))))))))) (EListLit))) (arm PWild () (EListLit))))))
(DTypeSig true "parseDiagnosticActions" (TyFun (TyCon "SourceSnapshot") (TyFun (TyApp (TyCon "List") (TyCon "ParseDiagnostic")) (TyApp (TyCon "List") (TyCon "Json")))))
(DFunDef false "parseDiagnosticActions" ((PVar "snapshot") (PVar "diagnostics")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "d")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "actionForEdit") (EVar "snapshot"))) (EApp (EVar "diagnosticEdits") (EVar "d"))))) (EVar "diagnostics")))
