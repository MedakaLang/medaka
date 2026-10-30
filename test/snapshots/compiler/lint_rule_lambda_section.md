# META
source_lines=166
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-lambda-section: a lambda whose body is one binary op on its parameter(s). Prefer an operator section.

import frontend.ast.{Loc(..), Pat(..), Section(..), Expr(..), Decl(..)}
import frontend.ast_walk.{ExprKind(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{contains}
import tools.printer.{exprToString}
import frontend.exhaust.{Oracle}
import tools.lint_core.{
  Category(..),
  Ctx(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor(..),
  mkVisitorRule,
}
import tools.lint_shared.{
  detApply,
  exprRuleFix,
  isEVarNamed,
  mentionsVar,
  noExcl,
  ruleNameLambdaSection,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameLambdaSection,
      summary =
        "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")",
      doc =
        "A lambda whose body is a single binary operator applied to its parameter is an operator section. The section is shorter and names no throwaway variable.\n\nBefore:\n  map (x => x + 1) xs\nAfter:\n  map (+ 1) xs",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleLambdaSection
    (Some lambdaSectionFix)

-- ── rule: lambda-section (STYLE "Dogfooding" — operator sections) ─────────────
-- A single-clause lambda whose body is ONE binary operation on its bound
-- parameter(s), rewritable to the canonical operator SECTION idiom:
--   (x => x OP e)   [e free of x]  → (OP e)    right section  ESection (SecRight OP e)
--   (x => e OP x)   [e free of x]  → (e OP _)   left section   ESection (SecLeft e OP)
--   (x y => x OP y)  [x ≠ y]       → (OP)       bare section   ESection (SecBare OP)
--
-- CONSERVATISM (a false positive here CORRUPTS code):
--   * single-param: the param must be EXACTLY one operand of the OUTERMOST binary
--     op (a bare `EVar x` leaf); the OTHER operand must NOT mention x anywhere.
--     So `x => x OP x`, `x => f x OP e`, `x => (x + 1) OP e` all skip.
--   * two-param: body is exactly `EVar x OP EVar y` (in order, distinct names).
--   * only the SYMBOLIC operators the parser accepts as sections round-trip
--     (`sectionOpStr` in parser.mdk): + * / == /= < > <= >= && || :: ++ |> >> <<,
--     plus `-` for LEFT/BARE only (a `-` RIGHT section `(- e)` parses as unary
--     negation — EXCLUDED).  Backtick infix (`EInfix`) is NOT handled: the printer
--     emits a word-operator section without backticks, so it would not round-trip.
--   * `ELam` is inherently single-clause / guard-free, so no extra guard check is
--     needed (contrast the §8 match-on-param rule).
-- The check walks the WHOLE decl expression tree (a lambda can nest anywhere) —
-- including impl-method bodies; the fix rebuilds the tree converting every
-- eligible lambda to `ESection`.

-- symbolic operators that round-trip as a section (parser.mdk `sectionOpStr`).
sectionSymOps : List String
sectionSymOps = [
  "+",
  "*",
  "/",
  "==",
  "/=",
  "<",
  ">",
  "<=",
  ">=",
  "&&",
  "||",
  "::",
  "++",
  "|>",
  ">>",
  "<<",
]

-- `-` is a valid LEFT/BARE section but NOT a right section (`(- e)` = negation).
rightSectionOp : String -> Bool
rightSectionOp op = contains op sectionSymOps

leftSectionOp : String -> Bool
leftSectionOp op = op == "-" || contains op sectionSymOps

bareSectionOp : String -> Bool
bareSectionOp op = op == "-" || contains op sectionSymOps

-- the section a lambda collapses to, or None if it is not an eligible shape.
lamSection : List Pat -> Expr -> Option Section
lamSection [PVar x _ _] body = lamSection1 x (unwrapLoc body)
lamSection [PVar x _ _, PVar y _ _] body
  | x /= y = lamSection2 x y (unwrapLoc body)
  | otherwise = None
lamSection _ _ = None

lamSection1 : String -> Expr -> Option Section
lamSection1 x (EBinOp op a b _)
  | isEVarNamed x a && rightSectionOp op && not (mentionsVar x b) =
    Some (SecRight op b)
  | isEVarNamed x b && leftSectionOp op && not (mentionsVar x a) =
    Some (SecLeft a op)
  | otherwise = None
lamSection1 _ _ = None

lamSection2 : String -> String -> Expr -> Option Section
lamSection2 x y (EBinOp op a b _)
  | isEVarNamed x a && isEVarNamed y b && bareSectionOp op = Some (SecBare op)
  | otherwise = None
lamSection2 _ _ _ = None

-- ── check ─────────────────────────────────────────────────────────────────────
-- Only `ELam` nodes can match, so only those are visited.
ruleLambdaSection : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleLambdaSection _ _ _ _ _ = [OnExpr [KLam] lambdaSectionAt]

lambdaSectionAt : Ctx -> Expr -> List Finding
lambdaSectionAt ctx (ELam pats body) = match lamSection pats body
  Some s => [lambdaSectionFinding ctx.ctxDeclLoc s]
  None => []
lambdaSectionAt _ _ = []

lambdaSectionFinding : Option Loc -> Section -> Finding
lambdaSectionFinding loc s = Finding {
  rule = ruleNameLambdaSection,
  message =
    "lambda is a single binary operation on its parameter(s). Rewrite as the operator section '"
      ++ exprToString (ESection s)
      ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = None,
}

-- ── autofix ───────────────────────────────────────────────────────────────────
-- Bottom-up: every eligible lambda becomes an `ESection`.
lambdaSectionFix : Oracle -> Decl -> Option (List Decl)
lambdaSectionFix _ d = exprRuleFix noExcl (detApply lamSectionRewrite) d

lamSectionRewrite : Expr -> Option Expr
lamSectionRewrite (ELam ps b) = map ESection (lamSection ps b)
lamSectionRewrite _ = None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Section" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleFix" false) (mem "isEVarNamed" false) (mem "mentionsVar" false) (mem "noExcl" false) (mem "ruleNameLambdaSection" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameLambdaSection")) (fa "summary" (ELit (LString "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")"))) (fa "doc" (ELit (LString "A lambda whose body is a single binary operator applied to its parameter is an operator section. The section is shorter and names no throwaway variable.\n\nBefore:\n  map (x => x + 1) xs\nAfter:\n  map (+ 1) xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleLambdaSection")) (EApp (EVar "Some") (EVar "lambdaSectionFix"))))
(DTypeSig false "sectionSymOps" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "sectionSymOps" () (EListLit (ELit (LString "+")) (ELit (LString "*")) (ELit (LString "/")) (ELit (LString "==")) (ELit (LString "/=")) (ELit (LString "<")) (ELit (LString ">")) (ELit (LString "<=")) (ELit (LString ">=")) (ELit (LString "&&")) (ELit (LString "||")) (ELit (LString "::")) (ELit (LString "++")) (ELit (LString "|>")) (ELit (LString ">>")) (ELit (LString "<<"))))
(DTypeSig false "rightSectionOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rightSectionOp" ((PVar "op")) (EApp (EApp (EVar "contains") (EVar "op")) (EVar "sectionSymOps")))
(DTypeSig false "leftSectionOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "leftSectionOp" ((PVar "op")) (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EApp (EVar "contains") (EVar "op")) (EVar "sectionSymOps"))))
(DTypeSig false "bareSectionOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "bareSectionOp" ((PVar "op")) (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EApp (EVar "contains") (EVar "op")) (EVar "sectionSymOps"))))
(DTypeSig false "lamSection" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Section")))))
(DFunDef false "lamSection" ((PList (PCon "PVar" (PVar "x") PWild PWild)) (PVar "body")) (EApp (EApp (EVar "lamSection1") (EVar "x")) (EApp (EVar "unwrapLoc") (EVar "body"))))
(DFunDef false "lamSection" ((PList (PCon "PVar" (PVar "x") PWild PWild) (PCon "PVar" (PVar "y") PWild PWild)) (PVar "body")) (EIf (EBinOp "/=" (EVar "x") (EVar "y")) (EApp (EApp (EApp (EVar "lamSection2") (EVar "x")) (EVar "y")) (EApp (EVar "unwrapLoc") (EVar "body"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lamSection" (PWild PWild) (EVar "None"))
(DTypeSig false "lamSection1" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Section")))))
(DFunDef false "lamSection1" ((PVar "x") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "a")) (EApp (EVar "rightSectionOp") (EVar "op"))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EVar "b")))) (EApp (EVar "Some") (EApp (EApp (EVar "SecRight") (EVar "op")) (EVar "b"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "b")) (EApp (EVar "leftSectionOp") (EVar "op"))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EVar "a")))) (EApp (EVar "Some") (EApp (EApp (EVar "SecLeft") (EVar "a")) (EVar "op"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "lamSection1" (PWild PWild) (EVar "None"))
(DTypeSig false "lamSection2" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Section"))))))
(DFunDef false "lamSection2" ((PVar "x") (PVar "y") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "a")) (EApp (EApp (EVar "isEVarNamed") (EVar "y")) (EVar "b"))) (EApp (EVar "bareSectionOp") (EVar "op"))) (EApp (EVar "Some") (EApp (EVar "SecBare") (EVar "op"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lamSection2" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "ruleLambdaSection" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleLambdaSection" (PWild PWild PWild PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KLam"))) (EVar "lambdaSectionAt"))))
(DTypeSig false "lambdaSectionAt" (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lambdaSectionAt" ((PVar "ctx") (PCon "ELam" (PVar "pats") (PVar "body"))) (EMatch (EApp (EApp (EVar "lamSection") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PVar "s")) () (EListLit (EApp (EApp (EVar "lambdaSectionFinding") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "s")))) (arm (PCon "None") () (EListLit))))
(DFunDef false "lambdaSectionAt" (PWild PWild) (EListLit))
(DTypeSig false "lambdaSectionFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Section") (TyCon "Finding"))))
(DFunDef false "lambdaSectionFinding" ((PVar "loc") (PVar "s")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameLambdaSection")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "lambda is a single binary operation on its parameter(s). Rewrite as the operator section '")) (EApp (EVar "exprToString") (EApp (EVar "ESection") (EVar "s")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "lambdaSectionFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lambdaSectionFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "lamSectionRewrite"))) (EVar "d")))
(DTypeSig false "lamSectionRewrite" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "lamSectionRewrite" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "map") (EVar "ESection")) (EApp (EApp (EVar "lamSection") (EVar "ps")) (EVar "b"))))
(DFunDef false "lamSectionRewrite" (PWild) (EVar "None"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Section" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleFix" false) (mem "isEVarNamed" false) (mem "mentionsVar" false) (mem "noExcl" false) (mem "ruleNameLambdaSection" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameLambdaSection")) (fa "summary" (ELit (LString "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")"))) (fa "doc" (ELit (LString "A lambda whose body is a single binary operator applied to its parameter is an operator section. The section is shorter and names no throwaway variable.\n\nBefore:\n  map (x => x + 1) xs\nAfter:\n  map (+ 1) xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleLambdaSection")) (EApp (EVar "Some") (EVar "lambdaSectionFix"))))
(DTypeSig false "sectionSymOps" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "sectionSymOps" () (EListLit (ELit (LString "+")) (ELit (LString "*")) (ELit (LString "/")) (ELit (LString "==")) (ELit (LString "/=")) (ELit (LString "<")) (ELit (LString ">")) (ELit (LString "<=")) (ELit (LString ">=")) (ELit (LString "&&")) (ELit (LString "||")) (ELit (LString "::")) (ELit (LString "++")) (ELit (LString "|>")) (ELit (LString ">>")) (ELit (LString "<<"))))
(DTypeSig false "rightSectionOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rightSectionOp" ((PVar "op")) (EApp (EApp (EVar "contains") (EVar "op")) (EVar "sectionSymOps")))
(DTypeSig false "leftSectionOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "leftSectionOp" ((PVar "op")) (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EApp (EVar "contains") (EVar "op")) (EVar "sectionSymOps"))))
(DTypeSig false "bareSectionOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "bareSectionOp" ((PVar "op")) (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EApp (EVar "contains") (EVar "op")) (EVar "sectionSymOps"))))
(DTypeSig false "lamSection" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Section")))))
(DFunDef false "lamSection" ((PList (PCon "PVar" (PVar "x") PWild PWild)) (PVar "body")) (EApp (EApp (EVar "lamSection1") (EVar "x")) (EApp (EVar "unwrapLoc") (EVar "body"))))
(DFunDef false "lamSection" ((PList (PCon "PVar" (PVar "x") PWild PWild) (PCon "PVar" (PVar "y") PWild PWild)) (PVar "body")) (EIf (EBinOp "/=" (EVar "x") (EVar "y")) (EApp (EApp (EApp (EVar "lamSection2") (EVar "x")) (EVar "y")) (EApp (EVar "unwrapLoc") (EVar "body"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lamSection" (PWild PWild) (EVar "None"))
(DTypeSig false "lamSection1" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Section")))))
(DFunDef false "lamSection1" ((PVar "x") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "a")) (EApp (EVar "rightSectionOp") (EVar "op"))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EVar "b")))) (EApp (EVar "Some") (EApp (EApp (EVar "SecRight") (EVar "op")) (EVar "b"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "b")) (EApp (EVar "leftSectionOp") (EVar "op"))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EVar "a")))) (EApp (EVar "Some") (EApp (EApp (EVar "SecLeft") (EVar "a")) (EVar "op"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "lamSection1" (PWild PWild) (EVar "None"))
(DTypeSig false "lamSection2" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Section"))))))
(DFunDef false "lamSection2" ((PVar "x") (PVar "y") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "a")) (EApp (EApp (EVar "isEVarNamed") (EVar "y")) (EVar "b"))) (EApp (EVar "bareSectionOp") (EVar "op"))) (EApp (EVar "Some") (EApp (EVar "SecBare") (EVar "op"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lamSection2" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "ruleLambdaSection" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleLambdaSection" (PWild PWild PWild PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KLam"))) (EVar "lambdaSectionAt"))))
(DTypeSig false "lambdaSectionAt" (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lambdaSectionAt" ((PVar "ctx") (PCon "ELam" (PVar "pats") (PVar "body"))) (EMatch (EApp (EApp (EVar "lamSection") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PVar "s")) () (EListLit (EApp (EApp (EVar "lambdaSectionFinding") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "s")))) (arm (PCon "None") () (EListLit))))
(DFunDef false "lambdaSectionAt" (PWild PWild) (EListLit))
(DTypeSig false "lambdaSectionFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Section") (TyCon "Finding"))))
(DFunDef false "lambdaSectionFinding" ((PVar "loc") (PVar "s")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameLambdaSection")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "lambda is a single binary operation on its parameter(s). Rewrite as the operator section '")) (EApp (EVar "exprToString") (EApp (EVar "ESection") (EVar "s")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "lambdaSectionFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lambdaSectionFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "lamSectionRewrite"))) (EVar "d")))
(DTypeSig false "lamSectionRewrite" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "lamSectionRewrite" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EMethodRef "map") (EVar "ESection")) (EApp (EApp (EVar "lamSection") (EVar "ps")) (EVar "b"))))
(DFunDef false "lamSectionRewrite" (PWild) (EVar "None"))
