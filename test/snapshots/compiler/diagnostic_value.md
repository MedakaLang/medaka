# META
source_lines=29
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Loc}

public export data Severity = SevError | SevWarning

-- A structured diagnostic: severity + human-readable message + an optional
-- source span (B.10.2b).  `Some` for type errors (expr-level span from the
-- ELoc substrate); `None` for resolve / guard / match diagnostics the compiler
-- pipeline does not yet locate.
-- Stage 1 (DIAGNOSTIC-CODES-DESIGN): every Diag carries a stable machine-readable
-- `Code` (a kebab string, e.g. "T-TYPE-MISMATCH") authored at its producing site.
-- The JSON `kind` is DERIVED from the code prefix (`codeKind`), never stored — so
-- authors supply exactly one token.  The CLI text renderers (`ppDiag`/
-- `ppDiagCliSrc`) deliberately ignore the code (JSON-only for Stage 1), keeping the
-- human-facing CLI output byte-identical.
-- Stage 2 (DIAGNOSTIC-CODES-DESIGN §6): a Diag optionally carries a human `help`
-- hint (Option String) and a machine-applicable `fix` (Option Fix).  Both are
-- surfaced JSON-only (CLI text is unchanged) and are `None` for most diagnostics;
-- parse and resolve diagnostics may populate them. A `Fix` replaces its
-- `Loc` span with the replacement string.
public export data Fix = Fix Loc String

public export data Diag =
  Diag Severity String String (Option Loc) (Option String) (Option Fix)

-- Smart constructor for a diagnostic with no structured help/fix (the common
-- case) — keeps the ~15 plain construction sites terse.
export
mkDiag : Severity -> String -> String -> Option Loc -> Diag
mkDiag sev code msg loc = Diag sev code msg loc None None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" false))))
(DData Public "Severity" () ((variant "SevError" (ConPos)) (variant "SevWarning" (ConPos))) ())
(DData Public "Fix" () ((variant "Fix" (ConPos (TyCon "Loc") (TyCon "String")))) ())
(DData Public "Diag" () ((variant "Diag" (ConPos (TyCon "Severity") (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Fix"))))) ())
(DTypeSig true "mkDiag" (TyFun (TyCon "Severity") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Diag"))))))
(DFunDef false "mkDiag" ((PVar "sev") (PVar "code") (PVar "msg") (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "sev")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "None")) (EVar "None")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" false))))
(DData Public "Severity" () ((variant "SevError" (ConPos)) (variant "SevWarning" (ConPos))) ())
(DData Public "Fix" () ((variant "Fix" (ConPos (TyCon "Loc") (TyCon "String")))) ())
(DData Public "Diag" () ((variant "Diag" (ConPos (TyCon "Severity") (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Fix"))))) ())
(DTypeSig true "mkDiag" (TyFun (TyCon "Severity") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Diag"))))))
(DFunDef false "mkDiag" ((PVar "sev") (PVar "code") (PVar "msg") (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "sev")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "None")) (EVar "None")))
