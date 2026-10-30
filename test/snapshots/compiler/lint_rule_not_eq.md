# META
source_lines=71
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-not-eq: a negated equality `not (a == b)` / `not (a /= b)`; prefer the operator.

import driver.diagnostics.{Severity(..)}
import tools.lint_core.{
  Applicability(..),
  Category(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  mkVisitorRule,
}
import tools.lint_hints.{
  Hint,
  HintCond(..),
  HintRow(..),
  compileHints,
  hintVisitors,
}
import tools.lint_shared.{ruleNameNotEq}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameNotEq,
      summary =
        "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`",
      doc =
        "A negated equality test has a direct operator.\n\nBefore:\n  not (a == b)\nAfter:\n  a /= b",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [NeedsScopes, NeedsWildIndex],
    }
    (idx path facts pos decls =>
      hintVisitors ruleNameNotEq SevWarning hints idx path facts pos decls)
    None

-- ── rule: not-eq ──────────────────────────────────────────────────────────────
-- `not (a == b)` → `a /= b`; `not (a /= b)` → `a == b`.  ONLY `==`/`/=`: they
-- are TOTAL, so De Morgan applies unconditionally.  `<`/`>` &c. are deliberately
-- excluded: their complement is unsound for `Float` (NaN makes `not (a < b)`
-- ≠ `a >= b`).  Inside the definition of `==` or `/=` the written operator
-- would be the method calling itself, so the fix is withheld there.
export
hintRows : List HintRow
hintRows = [
  HintRow {
    rowText = "not (a == b) ==> a /= b",
    rowMessage = "negated equality",
    rowFix = "use the operator",
    rowApplicability = Safe,
    rowConds = [NotInDefOf ["==", "/="]],
  },
  HintRow {
    rowText = "not (a /= b) ==> a == b",
    rowMessage = "negated equality",
    rowFix = "use the operator",
    rowApplicability = Safe,
    rowConds = [NotInDefOf ["==", "/="]],
  },
]

hints : List Hint
hints = compileHints hintRows
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_hints") ((mem "Hint" false) (mem "HintCond" true) (mem "HintRow" true) (mem "compileHints" false) (mem "hintVisitors" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameNotEq" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameNotEq")) (fa "summary" (ELit (LString "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`"))) (fa "doc" (ELit (LString "A negated equality test has a direct operator.\n\nBefore:\n  not (a == b)\nAfter:\n  a /= b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (ELam ((PVar "idx") (PVar "path") (PVar "facts") (PVar "pos") (PVar "decls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintVisitors") (EVar "ruleNameNotEq")) (EVar "SevWarning")) (EVar "hints")) (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls")))) (EVar "None")))
(DTypeSig true "hintRows" (TyApp (TyCon "List") (TyCon "HintRow")))
(DFunDef false "hintRows" () (EListLit (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "not (a == b) ==> a /= b"))) (fa "rowMessage" (ELit (LString "negated equality"))) (fa "rowFix" (ELit (LString "use the operator"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit (EApp (EVar "NotInDefOf") (EListLit (ELit (LString "==")) (ELit (LString "/=")))))))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "not (a /= b) ==> a == b"))) (fa "rowMessage" (ELit (LString "negated equality"))) (fa "rowFix" (ELit (LString "use the operator"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit (EApp (EVar "NotInDefOf") (EListLit (ELit (LString "==")) (ELit (LString "/="))))))))))
(DTypeSig false "hints" (TyApp (TyCon "List") (TyCon "Hint")))
(DFunDef false "hints" () (EApp (EVar "compileHints") (EVar "hintRows")))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_hints") ((mem "Hint" false) (mem "HintCond" true) (mem "HintRow" true) (mem "compileHints" false) (mem "hintVisitors" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameNotEq" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameNotEq")) (fa "summary" (ELit (LString "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`"))) (fa "doc" (ELit (LString "A negated equality test has a direct operator.\n\nBefore:\n  not (a == b)\nAfter:\n  a /= b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (ELam ((PVar "idx") (PVar "path") (PVar "facts") (PVar "pos") (PVar "decls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintVisitors") (EVar "ruleNameNotEq")) (EVar "SevWarning")) (EVar "hints")) (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls")))) (EVar "None")))
(DTypeSig true "hintRows" (TyApp (TyCon "List") (TyCon "HintRow")))
(DFunDef false "hintRows" () (EListLit (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "not (a == b) ==> a /= b"))) (fa "rowMessage" (ELit (LString "negated equality"))) (fa "rowFix" (ELit (LString "use the operator"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit (EApp (EVar "NotInDefOf") (EListLit (ELit (LString "==")) (ELit (LString "/=")))))))) (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "not (a /= b) ==> a == b"))) (fa "rowMessage" (ELit (LString "negated equality"))) (fa "rowFix" (ELit (LString "use the operator"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit (EApp (EVar "NotInDefOf") (EListLit (ELit (LString "==")) (ELit (LString "/="))))))))))
(DTypeSig false "hints" (TyApp (TyCon "List") (TyCon "Hint")))
(DFunDef false "hints" () (EApp (EVar "compileHints") (EVar "hintRows")))
