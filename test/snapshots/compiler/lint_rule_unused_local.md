# META
source_lines=61
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-unused-local: a `let` binder that nothing reads. Delete the binding, or use it; rename it `_name` or write `let _ =` to say it is intentionally unused.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{Decl}
import frontend.parser.{Positions(..)}
import tools.lint_core.{
  Category(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  factScopes,
  mkRule,
}
import tools.lint_scope.{Binder(..), BinderKind(..), unusedBinders}
import tools.lint_shared.{ruleNameUnusedLocal}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameUnusedLocal,
      summary = "a `let` binder that nothing reads",
      doc =
        "A `let` binder that no use resolves to is either dead work or a missed use. Delete the binding if the bound expression has no effect, or use the name if it was meant to be read. A name starting with `_` is not reported; the intended discard is `let _ =` in `do` code and a bare statement elsewhere. Only plain and `do` `let` binders are checked; parameter, lambda, match-arm and `<-` bind binders are not. The finding is only suggested, never fixed, because the bound expression may run an effect.\n\nBefore:\n  let total = sum xs\n  count xs\nAfter:\n  count xs",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [NeedsScopes],
    }
    ruleUnusedLocal
    None

ruleUnusedLocal : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleUnusedLocal _ _ facts _ _ =
  map
    localFinding
    (filter (b => b.binderKind == BLet) (unusedBinders (factScopes facts)))

localFinding : Binder -> Finding
localFinding b = Finding {
  rule = ruleNameUnusedLocal,
  message =
    "'\{b.binderName}' is bound by a `let` but never read. Either the bound expression is dead work and the binding can be deleted, or a use of '\{b.binderName}' is missing; write '_\{b.binderName}' or `let _ =` to keep it on purpose",
  severity = SevWarning,
  loc = Some b.binderSpan,
  fix = None,
}
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factScopes" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "Binder" true) (mem "BinderKind" true) (mem "unusedBinders" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameUnusedLocal" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameUnusedLocal")) (fa "summary" (ELit (LString "a `let` binder that nothing reads"))) (fa "doc" (ELit (LString "A `let` binder that no use resolves to is either dead work or a missed use. Delete the binding if the bound expression has no effect, or use the name if it was meant to be read. A name starting with `_` is not reported; the intended discard is `let _ =` in `do` code and a bare statement elsewhere. Only plain and `do` `let` binders are checked; parameter, lambda, match-arm and `<-` bind binders are not. The finding is only suggested, never fixed, because the bound expression may run an effect.\n\nBefore:\n  let total = sum xs\n  count xs\nAfter:\n  count xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleUnusedLocal")) (EVar "None")))
(DTypeSig false "ruleUnusedLocal" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleUnusedLocal" (PWild PWild (PVar "facts") PWild PWild) (EApp (EApp (EVar "map") (EVar "localFinding")) (EApp (EApp (EVar "filter") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BLet")))) (EApp (EVar "unusedBinders") (EApp (EVar "factScopes") (EVar "facts"))))))
(DTypeSig false "localFinding" (TyFun (TyCon "Binder") (TyCon "Finding")))
(DFunDef false "localFinding" ((PVar "b")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameUnusedLocal")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EFieldAccess (EVar "b") "binderName"))) (ELit (LString "' is bound by a `let` but never read. Either the bound expression is dead work and the binding can be deleted, or a use of '"))) (EApp (EVar "display") (EFieldAccess (EVar "b") "binderName"))) (ELit (LString "' is missing; write '_"))) (EApp (EVar "display") (EFieldAccess (EVar "b") "binderName"))) (ELit (LString "' or `let _ =` to keep it on purpose")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EFieldAccess (EVar "b") "binderSpan"))) (fa "fix" (EVar "None")))))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factScopes" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "Binder" true) (mem "BinderKind" true) (mem "unusedBinders" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameUnusedLocal" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameUnusedLocal")) (fa "summary" (ELit (LString "a `let` binder that nothing reads"))) (fa "doc" (ELit (LString "A `let` binder that no use resolves to is either dead work or a missed use. Delete the binding if the bound expression has no effect, or use the name if it was meant to be read. A name starting with `_` is not reported; the intended discard is `let _ =` in `do` code and a bare statement elsewhere. Only plain and `do` `let` binders are checked; parameter, lambda, match-arm and `<-` bind binders are not. The finding is only suggested, never fixed, because the bound expression may run an effect.\n\nBefore:\n  let total = sum xs\n  count xs\nAfter:\n  count xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleUnusedLocal")) (EVar "None")))
(DTypeSig false "ruleUnusedLocal" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleUnusedLocal" (PWild PWild (PVar "facts") PWild PWild) (EApp (EApp (EMethodRef "map") (EVar "localFinding")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BLet")))) (EApp (EVar "unusedBinders") (EApp (EVar "factScopes") (EVar "facts"))))))
(DTypeSig false "localFinding" (TyFun (TyCon "Binder") (TyCon "Finding")))
(DFunDef false "localFinding" ((PVar "b")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameUnusedLocal")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EFieldAccess (EVar "b") "binderName"))) (ELit (LString "' is bound by a `let` but never read. Either the bound expression is dead work and the binding can be deleted, or a use of '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "b") "binderName"))) (ELit (LString "' is missing; write '_"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "b") "binderName"))) (ELit (LString "' or `let _ =` to keep it on purpose")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EFieldAccess (EVar "b") "binderSpan"))) (fa "fix" (EVar "None")))))
