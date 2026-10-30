# META
source_lines=69
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-double-reverse: `reverse (reverse x)` is `x`. Drop the double reversal.

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
import tools.lint_shared.{ruleNameDoubleReverse}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameDoubleReverse,
      summary = "`reverse (reverse x)` is `x`. Drop the double reversal",
      doc =
        "Reversing a list twice returns the original list after two traversals.\n\nBefore:\n  reverse (reverse xs)\nAfter:\n  xs",
      category = Complexity,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [NeedsScopes, NeedsWildIndex],
    }
    (idx path facts pos decls =>
      hintVisitors
        ruleNameDoubleReverse
        SevWarning
        hints
        idx
        path
        facts
        pos
        decls)
    None

-- ── rule: double-reverse ──────────────────────────────────────────────────────
-- `reverse (reverse x)` → `x` (`reverse` is an involution).  Both `reverse`
-- heads must be the prelude's: a `reverse` the file binds is not the list
-- involution the rule knows, and its fix is withheld.
export
hintRows : List HintRow
hintRows = [
  HintRow {
    rowText = "reverse (reverse a) ==> a",
    rowMessage = "`reverse (reverse …)` is a no-op",
    rowFix = "drop the double reversal",
    rowApplicability = Safe,
    rowConds = [],
  },
]

hints : List Hint
hints = compileHints hintRows
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_hints") ((mem "Hint" false) (mem "HintCond" true) (mem "HintRow" true) (mem "compileHints" false) (mem "hintVisitors" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameDoubleReverse" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "summary" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "doc" (ELit (LString "Reversing a list twice returns the original list after two traversals.\n\nBefore:\n  reverse (reverse xs)\nAfter:\n  xs"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (ELam ((PVar "idx") (PVar "path") (PVar "facts") (PVar "pos") (PVar "decls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintVisitors") (EVar "ruleNameDoubleReverse")) (EVar "SevWarning")) (EVar "hints")) (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls")))) (EVar "None")))
(DTypeSig true "hintRows" (TyApp (TyCon "List") (TyCon "HintRow")))
(DFunDef false "hintRows" () (EListLit (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "reverse (reverse a) ==> a"))) (fa "rowMessage" (ELit (LString "`reverse (reverse …)` is a no-op"))) (fa "rowFix" (ELit (LString "drop the double reversal"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit))))))
(DTypeSig false "hints" (TyApp (TyCon "List") (TyCon "Hint")))
(DFunDef false "hints" () (EApp (EVar "compileHints") (EVar "hintRows")))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_hints") ((mem "Hint" false) (mem "HintCond" true) (mem "HintRow" true) (mem "compileHints" false) (mem "hintVisitors" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameDoubleReverse" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "summary" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "doc" (ELit (LString "Reversing a list twice returns the original list after two traversals.\n\nBefore:\n  reverse (reverse xs)\nAfter:\n  xs"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (ELam ((PVar "idx") (PVar "path") (PVar "facts") (PVar "pos") (PVar "decls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hintVisitors") (EVar "ruleNameDoubleReverse")) (EVar "SevWarning")) (EVar "hints")) (EVar "idx")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls")))) (EVar "None")))
(DTypeSig true "hintRows" (TyApp (TyCon "List") (TyCon "HintRow")))
(DFunDef false "hintRows" () (EListLit (ERecordCreate "HintRow" ((fa "rowText" (ELit (LString "reverse (reverse a) ==> a"))) (fa "rowMessage" (ELit (LString "`reverse (reverse …)` is a no-op"))) (fa "rowFix" (ELit (LString "drop the double reversal"))) (fa "rowApplicability" (EVar "Safe")) (fa "rowConds" (EListLit))))))
(DTypeSig false "hints" (TyApp (TyCon "List") (TyCon "Hint")))
(DFunDef false "hints" () (EApp (EVar "compileHints") (EVar "hintRows")))
