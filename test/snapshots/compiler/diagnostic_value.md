# META
source_lines=56
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Loc}
import support.diag_codes.{DiagCode, DiagKind(..), codeKind, codeText, kindText}

public export data Severity = SevError | SevWarning

-- A structured diagnostic: severity + human-readable message + an optional
-- source span (B.10.2b).  `Some` for type errors (expr-level span from the
-- ELoc substrate); `None` for resolve / guard / match diagnostics the compiler
-- pipeline does not yet locate.
-- Stage 1 (DIAGNOSTIC-CODES-DESIGN): every Diag carries a stable machine-readable
-- `DiagId`, authored at its producing site: a `DiagCode` constructor for every compiler
-- diagnostic, or the lint rule's name (`LintRule`), whose set is open.
-- The JSON `kind` is DERIVED from the id (`diagIdKind`), never stored — so
-- authors supply exactly one token.  The CLI text renderers (`ppDiag`/
-- `ppDiagCliSrc`) deliberately ignore the code (JSON-only for Stage 1), keeping the
-- human-facing CLI output byte-identical.
-- Stage 2 (DIAGNOSTIC-CODES-DESIGN §6): a Diag optionally carries a human `help`
-- hint (Option String) and a machine-applicable `fix` (Option Fix).  Both are
-- surfaced JSON-only (CLI text is unchanged) and are `None` for most diagnostics;
-- parse and resolve diagnostics may populate them. A `Fix` replaces its
-- `Loc` span with the replacement string.
-- `FixEdits` is a lint fix: an applicability name (`safe`, `unsafe`,
-- `suggest`) and several span edits that apply together.
public export data Fix = Fix Loc String | FixEdits String (List (Loc, String))

-- A diagnostic id is a compiler code or a lint rule name, two sources that share the one
-- `Diag`; neither is the other's failure case, so `Result` does not fit.
-- lint-disable-next-line rule-clone-type
public export data DiagId = Coded DiagCode | LintRule String deriving (Eq)

public export data Diag =
  Diag Severity DiagId String (Option Loc) (Option String) (Option Fix)

-- The text of [i] as `--json`, the LSP and the baselines carry it.
export
diagIdText : DiagId -> String
diagIdText (Coded c) = codeText c
diagIdText (LintRule r) = r

-- Whether [i] is a lexer or parser code: a diagnostic of the source's own syntax.
export
diagIdIsSyntax : DiagId -> Bool
diagIdIsSyntax (Coded c) = codeKind c == DkLex || codeKind c == DkParse
diagIdIsSyntax (LintRule _) = False

-- The JSON `kind` of [i] read from the id alone: the family of a code, `lint` for a rule.
export
diagIdKind : DiagId -> String
diagIdKind (Coded c) = kindText (codeKind c)
diagIdKind (LintRule _) = "lint"

-- Smart constructor for a diagnostic with no structured help/fix (the common
-- case) — keeps the ~15 plain construction sites terse.
export
mkDiag : Severity -> DiagCode -> String -> Option Loc -> Diag
mkDiag sev code msg loc = Diag sev (Coded code) msg loc None None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" false))))
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" false) (mem "DiagKind" true) (mem "codeKind" false) (mem "codeText" false) (mem "kindText" false))))
(DData Public "Severity" () ((variant "SevError" (ConPos)) (variant "SevWarning" (ConPos))) ())
(DData Public "Fix" () ((variant "Fix" (ConPos (TyCon "Loc") (TyCon "String"))) (variant "FixEdits" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "String")))))) ())
(DData Public "DiagId" () ((variant "Coded" (ConPos (TyCon "DiagCode"))) (variant "LintRule" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "DiagId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Coded" (PVar "__a0")) (PCon "Coded" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "LintRule" (PVar "__a0")) (PCon "LintRule" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "Diag" () ((variant "Diag" (ConPos (TyCon "Severity") (TyCon "DiagId") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Fix"))))) ())
(DTypeSig true "diagIdText" (TyFun (TyCon "DiagId") (TyCon "String")))
(DFunDef false "diagIdText" ((PCon "Coded" (PVar "c"))) (EApp (EVar "codeText") (EVar "c")))
(DFunDef false "diagIdText" ((PCon "LintRule" (PVar "r"))) (EVar "r"))
(DTypeSig true "diagIdIsSyntax" (TyFun (TyCon "DiagId") (TyCon "Bool")))
(DFunDef false "diagIdIsSyntax" ((PCon "Coded" (PVar "c"))) (EBinOp "||" (EBinOp "==" (EApp (EVar "codeKind") (EVar "c")) (EVar "DkLex")) (EBinOp "==" (EApp (EVar "codeKind") (EVar "c")) (EVar "DkParse"))))
(DFunDef false "diagIdIsSyntax" ((PCon "LintRule" PWild)) (EVar "False"))
(DTypeSig true "diagIdKind" (TyFun (TyCon "DiagId") (TyCon "String")))
(DFunDef false "diagIdKind" ((PCon "Coded" (PVar "c"))) (EApp (EVar "kindText") (EApp (EVar "codeKind") (EVar "c"))))
(DFunDef false "diagIdKind" ((PCon "LintRule" PWild)) (ELit (LString "lint")))
(DTypeSig true "mkDiag" (TyFun (TyCon "Severity") (TyFun (TyCon "DiagCode") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Diag"))))))
(DFunDef false "mkDiag" ((PVar "sev") (PVar "code") (PVar "msg") (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "sev")) (EApp (EVar "Coded") (EVar "code"))) (EVar "msg")) (EVar "loc")) (EVar "None")) (EVar "None")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" false))))
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" false) (mem "DiagKind" true) (mem "codeKind" false) (mem "codeText" false) (mem "kindText" false))))
(DData Public "Severity" () ((variant "SevError" (ConPos)) (variant "SevWarning" (ConPos))) ())
(DData Public "Fix" () ((variant "Fix" (ConPos (TyCon "Loc") (TyCon "String"))) (variant "FixEdits" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "String")))))) ())
(DData Public "DiagId" () ((variant "Coded" (ConPos (TyCon "DiagCode"))) (variant "LintRule" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "DiagId")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Coded" (PVar "__a0")) (PCon "Coded" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "LintRule" (PVar "__a0")) (PCon "LintRule" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "Diag" () ((variant "Diag" (ConPos (TyCon "Severity") (TyCon "DiagId") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Fix"))))) ())
(DTypeSig true "diagIdText" (TyFun (TyCon "DiagId") (TyCon "String")))
(DFunDef false "diagIdText" ((PCon "Coded" (PVar "c"))) (EApp (EVar "codeText") (EVar "c")))
(DFunDef false "diagIdText" ((PCon "LintRule" (PVar "r"))) (EVar "r"))
(DTypeSig true "diagIdIsSyntax" (TyFun (TyCon "DiagId") (TyCon "Bool")))
(DFunDef false "diagIdIsSyntax" ((PCon "Coded" (PVar "c"))) (EBinOp "||" (EBinOp "==" (EApp (EVar "codeKind") (EVar "c")) (EVar "DkLex")) (EBinOp "==" (EApp (EVar "codeKind") (EVar "c")) (EVar "DkParse"))))
(DFunDef false "diagIdIsSyntax" ((PCon "LintRule" PWild)) (EVar "False"))
(DTypeSig true "diagIdKind" (TyFun (TyCon "DiagId") (TyCon "String")))
(DFunDef false "diagIdKind" ((PCon "Coded" (PVar "c"))) (EApp (EVar "kindText") (EApp (EVar "codeKind") (EVar "c"))))
(DFunDef false "diagIdKind" ((PCon "LintRule" PWild)) (ELit (LString "lint")))
(DTypeSig true "mkDiag" (TyFun (TyCon "Severity") (TyFun (TyCon "DiagCode") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Diag"))))))
(DFunDef false "mkDiag" ((PVar "sev") (PVar "code") (PVar "msg") (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "sev")) (EApp (EVar "Coded") (EVar "code"))) (EVar "msg")) (EVar "loc")) (EVar "None")) (EVar "None")))
