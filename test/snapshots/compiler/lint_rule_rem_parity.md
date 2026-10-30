# META
source_lines=118
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-rem-parity: `n % 2 == 0` and `n % 2 /= 0` parity tests. Prefer `isEven n` / `isOdd n`.

import frontend.ast.{Loc(..), Lit(..), Expr(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
import tools.lint_core.{
  Applicability(..),
  Category(..),
  Ctx(..),
  FileFacts,
  Finding(..),
  Fix,
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor,
  mkVisitorRule,
}
import tools.lint_shared.{
  rebinds,
  exprRuleEditVisitors,
  replaceNodeFix,
  ruleNameRemParity,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameRemParity,
      summary =
        "`n % 2 == 0` / `n % 2 /= 0` parity test. Prefer `isEven n` / `isOdd n`",
      doc =
        "A remainder-by-two comparison against zero is a parity test; the prelude names it.\n\nBefore:\n  n % 2 == 0\nAfter:\n  isEven n",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = FixableUnsafe,
      needs = [NeedsScopes, NeedsWildIndex],
    }
    ruleRemParity
    None

-- `e` is the integer literal `k` — either an `ELit (LInt k)` or a Num-poly
-- `ENumLit k …` (the parser emits the latter for expression int literals; sexp
-- renders both identically, so both must be recognised).
isIntLit : Int -> Expr -> Bool
isIntLit k e = match unwrapLoc e
  ELit (LInt n) => n == k
  ENumLit n _ _ => n == k
  _ => False

-- `n % 2 == 0` → `isEven n`; `n % 2 /= 0` → `isOdd n` (either operand order).
-- ONLY the `== 0` / `/= 0` comparisons: Medaka's `%` follows the DIVIDEND's sign
-- (`-3 % 2 = -1`), so `n % 2 == 1` is FALSE for negative odd `n` — excluded.
-- Excludes the `isEven`/`isOdd` definitions themselves (their bodies ARE this
-- idiom; rewriting them would produce `isEven n = isEven n`).
remParityExcl : String -> Bool
remParityExcl name = name == "isEven" || name == "isOdd"

remParityOf : Expr -> Option Expr
remParityOf (EBinOp op a b _)
  | op == "==" || op == "/=" =
    if isIntLit 0 b then
      remParityFrom op (unwrapLoc a)
    else if isIntLit 0 a then
      remParityFrom op (unwrapLoc b)
    else
      None
remParityOf _ = None

remParityFrom : String -> Expr -> Option Expr
remParityFrom op (EBinOp "%" n two _)
  | isIntLit 2 two = Some (EApp (EVar (parityFn op)) n)
remParityFrom _ _ = None

parityFn : String -> String
parityFn op = if op == "==" then "isEven" else "isOdd"

ruleRemParity : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleRemParity idx _ facts _ _ =
  exprRuleEditVisitors
    remParityExcl
    remParityOf
    (remParityFix idx facts)
    remParityFinding

remParityFinding : Option Loc -> Expr -> Option Fix -> Finding
remParityFinding loc rewritten fix = Finding {
  rule = ruleNameRemParity,
  message = "parity test. Rewrite as '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = fix,
}

-- The rewrite calls `isEven` or `isOdd` by name.  A binding of either name
-- anywhere in the file would capture the call, so the fix is withheld there
-- (the finding stays).  The prelude's pair is `core.mdk`'s `isEven`/`isOdd`.
remParityFix : StdlibIndex -> FileFacts -> Ctx -> Expr -> Expr -> Option Fix
remParityFix idx facts ctx e rewritten =
  if rebinds idx facts ctx "isEven" || rebinds idx facts ctx "isOdd" then
    None
  else
    replaceNodeFix Unsafe "use the parity predicate" ctx e rewritten
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "rebinds" false) (mem "exprRuleEditVisitors" false) (mem "replaceNodeFix" false) (mem "ruleNameRemParity" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameRemParity")) (fa "summary" (ELit (LString "`n % 2 == 0` / `n % 2 /= 0` parity test. Prefer `isEven n` / `isOdd n`"))) (fa "doc" (ELit (LString "A remainder-by-two comparison against zero is a parity test; the prelude names it.\n\nBefore:\n  n % 2 == 0\nAfter:\n  isEven n"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "FixableUnsafe")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (EVar "ruleRemParity")) (EVar "None")))
(DTypeSig false "isIntLit" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isIntLit" ((PVar "k") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" (PCon "LInt" (PVar "n"))) () (EBinOp "==" (EVar "n") (EVar "k"))) (arm (PCon "ENumLit" (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "k"))) (arm PWild () (EVar "False"))))
(DTypeSig false "remParityExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "remParityExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "isEven"))) (EBinOp "==" (EVar "name") (ELit (LString "isOdd")))))
(DTypeSig false "remParityOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "remParityOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EBinOp "==" (EVar "op") (ELit (LString "/=")))) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 0))) (EVar "b")) (EApp (EApp (EVar "remParityFrom") (EVar "op")) (EApp (EVar "unwrapLoc") (EVar "a"))) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 0))) (EVar "a")) (EApp (EApp (EVar "remParityFrom") (EVar "op")) (EApp (EVar "unwrapLoc") (EVar "b"))) (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "remParityOf" (PWild) (EVar "None"))
(DTypeSig false "remParityFrom" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "remParityFrom" ((PVar "op") (PCon "EBinOp" (PLit (LString "%")) (PVar "n") (PVar "two") PWild)) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 2))) (EVar "two")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EApp (EVar "parityFn") (EVar "op")))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "remParityFrom" (PWild PWild) (EVar "None"))
(DTypeSig false "parityFn" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "parityFn" ((PVar "op")) (EIf (EBinOp "==" (EVar "op") (ELit (LString "=="))) (ELit (LString "isEven")) (ELit (LString "isOdd"))))
(DTypeSig false "ruleRemParity" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleRemParity" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "remParityExcl")) (EVar "remParityOf")) (EApp (EApp (EVar "remParityFix") (EVar "idx")) (EVar "facts"))) (EVar "remParityFinding")))
(DTypeSig false "remParityFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "remParityFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameRemParity")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "parity test. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "remParityFix" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "remParityFix" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (ELit (LString "isEven"))) (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (ELit (LString "isOdd")))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EVar "replaceNodeFix") (EVar "Unsafe")) (ELit (LString "use the parity predicate"))) (EVar "ctx")) (EVar "e")) (EVar "rewritten"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "rebinds" false) (mem "exprRuleEditVisitors" false) (mem "replaceNodeFix" false) (mem "ruleNameRemParity" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameRemParity")) (fa "summary" (ELit (LString "`n % 2 == 0` / `n % 2 /= 0` parity test. Prefer `isEven n` / `isOdd n`"))) (fa "doc" (ELit (LString "A remainder-by-two comparison against zero is a parity test; the prelude names it.\n\nBefore:\n  n % 2 == 0\nAfter:\n  isEven n"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "FixableUnsafe")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsWildIndex")))))) (EVar "ruleRemParity")) (EVar "None")))
(DTypeSig false "isIntLit" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isIntLit" ((PVar "k") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" (PCon "LInt" (PVar "n"))) () (EBinOp "==" (EVar "n") (EVar "k"))) (arm (PCon "ENumLit" (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "k"))) (arm PWild () (EVar "False"))))
(DTypeSig false "remParityExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "remParityExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "isEven"))) (EBinOp "==" (EVar "name") (ELit (LString "isOdd")))))
(DTypeSig false "remParityOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "remParityOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EBinOp "==" (EVar "op") (ELit (LString "/=")))) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 0))) (EVar "b")) (EApp (EApp (EVar "remParityFrom") (EVar "op")) (EApp (EVar "unwrapLoc") (EVar "a"))) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 0))) (EVar "a")) (EApp (EApp (EVar "remParityFrom") (EVar "op")) (EApp (EVar "unwrapLoc") (EVar "b"))) (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "remParityOf" (PWild) (EVar "None"))
(DTypeSig false "remParityFrom" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "remParityFrom" ((PVar "op") (PCon "EBinOp" (PLit (LString "%")) (PVar "n") (PVar "two") PWild)) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 2))) (EVar "two")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EApp (EVar "parityFn") (EVar "op")))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "remParityFrom" (PWild PWild) (EVar "None"))
(DTypeSig false "parityFn" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "parityFn" ((PVar "op")) (EIf (EBinOp "==" (EVar "op") (ELit (LString "=="))) (ELit (LString "isEven")) (ELit (LString "isOdd"))))
(DTypeSig false "ruleRemParity" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleRemParity" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "remParityExcl")) (EVar "remParityOf")) (EApp (EApp (EVar "remParityFix") (EVar "idx")) (EVar "facts"))) (EVar "remParityFinding")))
(DTypeSig false "remParityFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "remParityFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameRemParity")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "parity test. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "remParityFix" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "remParityFix" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (ELit (LString "isEven"))) (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (ELit (LString "isOdd")))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EVar "replaceNodeFix") (EVar "Unsafe")) (ELit (LString "use the parity predicate"))) (EVar "ctx")) (EVar "e")) (EVar "rewritten"))))
