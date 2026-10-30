# META
source_lines=215
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-lambda-section: a lambda whose body is one binary op on its parameter(s). Prefer an operator section.

import frontend.ast.{Loc(..), Pat(..), Section(..), Expr(..), Decl(..)}
import frontend.ast_walk.{ExprKind(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{contains}
import list.{drop, last}
import support.char.{isIdentChar}
import string.{lines, stripSuffix, trimRight, unwords}
import tools.printer.{exprToString}
import tools.lint_fix.{Binding(..)}
import tools.lint_core.{
  Category(..),
  Ctx(..),
  FileFacts(..),
  Finding(..),
  Fix,
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
  isEVarNamed,
  mentionsVar,
  replaceFix,
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
    None

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
-- including impl-method bodies; the fix replaces each eligible lambda with its
-- `ESection`.

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
ruleLambdaSection _ _ facts _ _ = [OnExpr [KLam] (lambdaSectionAt facts)]

lambdaSectionAt : FileFacts -> Ctx -> Expr -> List Finding
lambdaSectionAt facts ctx (ELam pats body) = match lamSection pats body
  Some sec => [
    lambdaSectionFinding
      ctx.ctxDeclLoc
      sec
      (lambdaSectionFix facts ctx pats sec),
  ]
  None => []
lambdaSectionAt _ _ _ = []

lambdaSectionFinding : Option Loc -> Section -> Option Fix -> Finding
lambdaSectionFinding loc s fix = Finding {
  rule = ruleNameLambdaSection,
  message =
    "lambda is a single binary operation on its parameter(s). Rewrite as the operator section '"
      ++ exprToString (ESection s)
      ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = fix,
}

-- ── autofix ───────────────────────────────────────────────────────────────────
-- The section carries its own brackets, so it reads the same wherever the
-- lambda stood.
lambdaSectionFix : FileFacts -> Ctx -> List Pat -> Section -> Option Fix
lambdaSectionFix facts ctx pats sec =
  replaceFix
    "use the operator section"
    (lambdaSpan facts ctx pats)
    Closed
    ctx
    (exprToString (ESection sec))

-- The `ELoc` of a lambda starts at its arrow and its parameters carry no
-- positions, so the source line gives the rest.  A parenthesised lambda is
-- wrapped by a further `ELoc` whose first character is the bracket, and the
-- section replaces it, brackets and all.  An unbracketed one is replaced from
-- its first parameter, found by reading the parameter names back from the
-- arrow; any other spacing leaves the finding without a fix.
lambdaSpan : FileFacts -> Ctx -> List Pat -> Option Loc
lambdaSpan facts ctx pats = match ctx.ctxOwn
  Some (own@(Loc f sl sc el ec)) =>
    let before = stringSlice 0 sc (sourceLine facts sl)
    if stringSlice sc (sc + 1) (sourceLine facts sl) == "(" then
      Some own
    else
      map
        (start => Loc f sl start el ec)
        (paramsStart before (unwords (flatMap patVarName pats)))
  None => None

patVarName : Pat -> List String
patVarName (PVar x _ _) = [x]
patVarName _ = []

-- The 1-based line of the source.
sourceLine : FileFacts -> Int -> String
sourceLine facts n = match drop (n - 1) (lines facts.ffSrc)
  l :: _ => l
  [] => ""

-- The column where `params` begins, given the text before the arrow.
paramsStart : String -> String -> Option Int
paramsStart before params = match stripSuffix params (trimRight before)
  Some rest => if endsInIdent rest then None else Some (stringLength rest)
  None => None

endsInIdent : String -> Bool
endsInIdent text = match last (toList (stringToChars text))
  Some c => isIdentChar c
  None => False
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Section" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "last" false))))
(DUse false (UseGroup ("support" "char") ((mem "isIdentChar" false))))
(DUse false (UseGroup ("string") ((mem "lines" false) (mem "stripSuffix" false) (mem "trimRight" false) (mem "unwords" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_fix") ((mem "Binding" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "isEVarNamed" false) (mem "mentionsVar" false) (mem "replaceFix" false) (mem "ruleNameLambdaSection" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameLambdaSection")) (fa "summary" (ELit (LString "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")"))) (fa "doc" (ELit (LString "A lambda whose body is a single binary operator applied to its parameter is an operator section. The section is shorter and names no throwaway variable.\n\nBefore:\n  map (x => x + 1) xs\nAfter:\n  map (+ 1) xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleLambdaSection")) (EVar "None")))
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
(DFunDef false "ruleLambdaSection" (PWild PWild (PVar "facts") PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KLam"))) (EApp (EVar "lambdaSectionAt") (EVar "facts")))))
(DTypeSig false "lambdaSectionAt" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "lambdaSectionAt" ((PVar "facts") (PVar "ctx") (PCon "ELam" (PVar "pats") (PVar "body"))) (EMatch (EApp (EApp (EVar "lamSection") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PVar "sec")) () (EListLit (EApp (EApp (EApp (EVar "lambdaSectionFinding") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "sec")) (EApp (EApp (EApp (EApp (EVar "lambdaSectionFix") (EVar "facts")) (EVar "ctx")) (EVar "pats")) (EVar "sec"))))) (arm (PCon "None") () (EListLit))))
(DFunDef false "lambdaSectionAt" (PWild PWild PWild) (EListLit))
(DTypeSig false "lambdaSectionFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Section") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "lambdaSectionFinding" ((PVar "loc") (PVar "s") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameLambdaSection")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "lambda is a single binary operation on its parameter(s). Rewrite as the operator section '")) (EApp (EVar "exprToString") (EApp (EVar "ESection") (EVar "s")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "lambdaSectionFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Section") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "lambdaSectionFix" ((PVar "facts") (PVar "ctx") (PVar "pats") (PVar "sec")) (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (ELit (LString "use the operator section"))) (EApp (EApp (EApp (EVar "lambdaSpan") (EVar "facts")) (EVar "ctx")) (EVar "pats"))) (EVar "Closed")) (EVar "ctx")) (EApp (EVar "exprToString") (EApp (EVar "ESection") (EVar "sec")))))
(DTypeSig false "lambdaSpan" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "lambdaSpan" ((PVar "facts") (PVar "ctx") (PVar "pats")) (EMatch (EFieldAccess (EVar "ctx") "ctxOwn") (arm (PCon "Some" (PAs "own" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) () (EBlock (DoLet false false (PVar "before") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "sc")) (EApp (EApp (EVar "sourceLine") (EVar "facts")) (EVar "sl")))) (DoExpr (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "sc")) (EBinOp "+" (EVar "sc") (ELit (LInt 1)))) (EApp (EApp (EVar "sourceLine") (EVar "facts")) (EVar "sl"))) (ELit (LString "("))) (EApp (EVar "Some") (EVar "own")) (EApp (EApp (EVar "map") (ELam ((PVar "start")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "start")) (EVar "el")) (EVar "ec")))) (EApp (EApp (EVar "paramsStart") (EVar "before")) (EApp (EVar "unwords") (EApp (EApp (EVar "flatMap") (EVar "patVarName")) (EVar "pats"))))))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "patVarName" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarName" ((PCon "PVar" (PVar "x") PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "patVarName" (PWild) (EListLit))
(DTypeSig false "sourceLine" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "sourceLine" ((PVar "facts") (PVar "n")) (EMatch (EApp (EApp (EVar "drop") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "lines") (EFieldAccess (EVar "facts") "ffSrc"))) (arm (PCons (PVar "l") PWild) () (EVar "l")) (arm (PList) () (ELit (LString "")))))
(DTypeSig false "paramsStart" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "paramsStart" ((PVar "before") (PVar "params")) (EMatch (EApp (EApp (EVar "stripSuffix") (EVar "params")) (EApp (EVar "trimRight") (EVar "before"))) (arm (PCon "Some" (PVar "rest")) () (EIf (EApp (EVar "endsInIdent") (EVar "rest")) (EVar "None") (EApp (EVar "Some") (EApp (EVar "stringLength") (EVar "rest"))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "endsInIdent" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "endsInIdent" ((PVar "text")) (EMatch (EApp (EVar "last") (EApp (EVar "toList") (EApp (EVar "stringToChars") (EVar "text")))) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "isIdentChar") (EVar "c"))) (arm (PCon "None") () (EVar "False"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Section" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "last" false))))
(DUse false (UseGroup ("support" "char") ((mem "isIdentChar" false))))
(DUse false (UseGroup ("string") ((mem "lines" false) (mem "stripSuffix" false) (mem "trimRight" false) (mem "unwords" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_fix") ((mem "Binding" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "isEVarNamed" false) (mem "mentionsVar" false) (mem "replaceFix" false) (mem "ruleNameLambdaSection" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameLambdaSection")) (fa "summary" (ELit (LString "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")"))) (fa "doc" (ELit (LString "A lambda whose body is a single binary operator applied to its parameter is an operator section. The section is shorter and names no throwaway variable.\n\nBefore:\n  map (x => x + 1) xs\nAfter:\n  map (+ 1) xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleLambdaSection")) (EVar "None")))
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
(DFunDef false "ruleLambdaSection" (PWild PWild (PVar "facts") PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KLam"))) (EApp (EVar "lambdaSectionAt") (EVar "facts")))))
(DTypeSig false "lambdaSectionAt" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "lambdaSectionAt" ((PVar "facts") (PVar "ctx") (PCon "ELam" (PVar "pats") (PVar "body"))) (EMatch (EApp (EApp (EVar "lamSection") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PVar "sec")) () (EListLit (EApp (EApp (EApp (EVar "lambdaSectionFinding") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "sec")) (EApp (EApp (EApp (EApp (EVar "lambdaSectionFix") (EVar "facts")) (EVar "ctx")) (EVar "pats")) (EVar "sec"))))) (arm (PCon "None") () (EListLit))))
(DFunDef false "lambdaSectionAt" (PWild PWild PWild) (EListLit))
(DTypeSig false "lambdaSectionFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Section") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "lambdaSectionFinding" ((PVar "loc") (PVar "s") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameLambdaSection")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "lambda is a single binary operation on its parameter(s). Rewrite as the operator section '")) (EApp (EVar "exprToString") (EApp (EVar "ESection") (EVar "s")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "lambdaSectionFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Section") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "lambdaSectionFix" ((PVar "facts") (PVar "ctx") (PVar "pats") (PVar "sec")) (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (ELit (LString "use the operator section"))) (EApp (EApp (EApp (EVar "lambdaSpan") (EVar "facts")) (EVar "ctx")) (EVar "pats"))) (EVar "Closed")) (EVar "ctx")) (EApp (EVar "exprToString") (EApp (EVar "ESection") (EVar "sec")))))
(DTypeSig false "lambdaSpan" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "lambdaSpan" ((PVar "facts") (PVar "ctx") (PVar "pats")) (EMatch (EFieldAccess (EVar "ctx") "ctxOwn") (arm (PCon "Some" (PAs "own" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) () (EBlock (DoLet false false (PVar "before") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "sc")) (EApp (EApp (EVar "sourceLine") (EVar "facts")) (EVar "sl")))) (DoExpr (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "sc")) (EBinOp "+" (EVar "sc") (ELit (LInt 1)))) (EApp (EApp (EVar "sourceLine") (EVar "facts")) (EVar "sl"))) (ELit (LString "("))) (EApp (EVar "Some") (EVar "own")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "start")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "start")) (EVar "el")) (EVar "ec")))) (EApp (EApp (EVar "paramsStart") (EVar "before")) (EApp (EVar "unwords") (EApp (EApp (EDictApp "flatMap") (EVar "patVarName")) (EVar "pats"))))))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "patVarName" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarName" ((PCon "PVar" (PVar "x") PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "patVarName" (PWild) (EListLit))
(DTypeSig false "sourceLine" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "sourceLine" ((PVar "facts") (PVar "n")) (EMatch (EApp (EApp (EVar "drop") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "lines") (EFieldAccess (EVar "facts") "ffSrc"))) (arm (PCons (PVar "l") PWild) () (EVar "l")) (arm (PList) () (ELit (LString "")))))
(DTypeSig false "paramsStart" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "paramsStart" ((PVar "before") (PVar "params")) (EMatch (EApp (EApp (EVar "stripSuffix") (EVar "params")) (EApp (EVar "trimRight") (EVar "before"))) (arm (PCon "Some" (PVar "rest")) () (EIf (EApp (EVar "endsInIdent") (EVar "rest")) (EVar "None") (EApp (EVar "Some") (EApp (EVar "stringLength") (EVar "rest"))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "endsInIdent" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "endsInIdent" ((PVar "text")) (EMatch (EApp (EVar "last") (EApp (EMethodRef "toList") (EApp (EVar "stringToChars") (EVar "text")))) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "isIdentChar") (EVar "c"))) (arm (PCon "None") () (EVar "False"))))
