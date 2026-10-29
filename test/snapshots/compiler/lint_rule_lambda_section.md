# META
source_lines=296
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-lambda-section: a lambda whose body is one binary op on its parameter(s). Prefer an operator section.

import frontend.ast.{
  Loc(..), Pat(..), Guard(..), Arm(..), ImplMethod(..), DoStmt(..), Section(..),
  InterpPart(..), GuardArm(..), FieldAssign(..), LetBind(..), FunClause(..),
  Expr(..), Decl(..)
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{contains}
import tools.printer.{exprToString}
import ir.sexp.{exprSexp}
import frontend.exhaust.{Oracle}
import tools.lint_core.{
  Category(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  mkRule,
}
import tools.lint_shared.{
  childExprs,
  declLocList,
  implMethodsBodyKey,
  isEVarNamed,
  mentionsVar,
  ruleNameLambdaSection,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkRule
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
ruleLambdaSection : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleLambdaSection _ _ _ pos prog =
  flatMap lambdaSectionDeclL (declLocList pos prog)

lambdaSectionDeclL : (Decl, Option Loc) -> List Finding
lambdaSectionDeclL (d, loc) = map (lambdaSectionFinding loc) (declLamSections d)

declLamSections : Decl -> List Section
declLamSections (DFunDef _ _ _ body _ _) = collectLamSections body
declLamSections (DImpl { methods, ... }) = flatMap implMethodLamSections methods
declLamSections (DAttrib _ d) = declLamSections d
declLamSections _ = []

implMethodLamSections : ImplMethod -> List Section
implMethodLamSections (ImplMethod _ _ body) = collectLamSections body

-- every eligible lambda anywhere in the expression tree (order irrelevant).
collectLamSections : Expr -> List Section
collectLamSections e = lamHitOf e ++ flatMap collectLamSections (childExprs e)

lamHitOf : Expr -> List Section
lamHitOf (ELam pats body) = optSectionToList (lamSection pats body)
lamHitOf _ = []

optSectionToList : Option Section -> List Section
optSectionToList (Some s) = [s]
optSectionToList None = []

lambdaSectionFinding : Option Loc -> Section -> Finding
lambdaSectionFinding loc s = Finding {
  rule = ruleNameLambdaSection,
  message =
    "lambda is a single binary operation on its parameter(s). Rewrite as the operator section '"
      ++ exprToString (ESection s)
      ++ "'",
  severity = SevWarning,
  loc = loc,
}

-- ── autofix ───────────────────────────────────────────────────────────────────
-- Rebuild the decl body converting every eligible lambda to `ESection`.  Detects
-- "did anything change" by comparing the location-stripped sexp of old vs new.
lambdaSectionFix : Oracle -> Decl -> Option (List Decl)
lambdaSectionFix _ (DFunDef vis name pats body site bid) =
  let body2 = rewriteLamExpr body
  if exprSexp body2 == exprSexp body then
    None
  else
    Some [DFunDef vis name pats body2 site bid]
lambdaSectionFix orc (DAttrib a d) = match lambdaSectionFix orc d
  Some [d2] => Some [DAttrib a d2]
  _ => None
lambdaSectionFix _ (d@(DImpl { implOrigin = _, methods })) =
  let methods2 = map fixImplMethod methods
  if implMethodsBodyKey methods2 == implMethodsBodyKey methods then
    None
  else
    -- #1110: record UPDATE — re-synthesising would reset the acquired identity.
    Some [DImpl { d | methods = methods2 }]
lambdaSectionFix _ _ = None

fixImplMethod : ImplMethod -> ImplMethod
fixImplMethod (ImplMethod nm ps body) = ImplMethod nm ps (rewriteLamExpr body)

-- if a rewritten lambda is an eligible section, collapse it; else keep it.
tryLamSection : List Pat -> Expr -> Expr
tryLamSection ps b = match lamSection ps b
  Some s => ESection s
  None => ELam ps b

-- recursively rewrite children (bottom-up), then collapse THIS lambda if eligible.
rewriteLamExpr : Expr -> Expr
rewriteLamExpr (ELoc l e) = ELoc l (rewriteLamExpr e)
rewriteLamExpr (EDoOrigin l e) = EDoOrigin l (rewriteLamExpr e)
rewriteLamExpr (EApp f x) = EApp (rewriteLamExpr f) (rewriteLamExpr x)
rewriteLamExpr (ELam ps b) = tryLamSection ps (rewriteLamExpr b)
rewriteLamExpr (ELet m isf p e1 e2) =
  ELet m isf p (rewriteLamExpr e1) (rewriteLamExpr e2)
rewriteLamExpr (EMatch s arms) =
  EMatch (rewriteLamExpr s) (map rewriteLamArm arms)
rewriteLamExpr (EIf c t el) =
  EIf (rewriteLamExpr c) (rewriteLamExpr t) (rewriteLamExpr el)
rewriteLamExpr (EBinOp op a b r) =
  EBinOp op (rewriteLamExpr a) (rewriteLamExpr b) r
rewriteLamExpr (EUnOp op a r) = EUnOp op (rewriteLamExpr a) r
rewriteLamExpr (EInfix op a b) = EInfix op (rewriteLamExpr a) (rewriteLamExpr b)
rewriteLamExpr (EFieldAccess e f r) = EFieldAccess (rewriteLamExpr e) f r
rewriteLamExpr (ETuple es) = ETuple (map rewriteLamExpr es)
rewriteLamExpr (EListLit es) = EListLit (map rewriteLamExpr es)
rewriteLamExpr (EArrayLit es) = EArrayLit (map rewriteLamExpr es)
rewriteLamExpr (ERangeList lo hi i) =
  ERangeList (rewriteLamExpr lo) (rewriteLamExpr hi) i
rewriteLamExpr (ERangeArray lo hi i) =
  ERangeArray (rewriteLamExpr lo) (rewriteLamExpr hi) i
rewriteLamExpr (ESlice e lo hi i) =
  ESlice (rewriteLamExpr e) (rewriteLamExpr lo) (rewriteLamExpr hi) i
rewriteLamExpr (ELetGroup binds body) =
  ELetGroup (map rewriteLamLet binds) (rewriteLamExpr body)
rewriteLamExpr (ESection s) = ESection (rewriteLamSection s)
rewriteLamExpr (EIndex a i) = EIndex (rewriteLamExpr a) (rewriteLamExpr i)
rewriteLamExpr (EAnnot e t) = EAnnot (rewriteLamExpr e) t
rewriteLamExpr (EHeadAnnot e t) = EHeadAnnot (rewriteLamExpr e) t
rewriteLamExpr (EBlock stmts) = EBlock (map rewriteLamStmt stmts)
rewriteLamExpr (EDo d stmts) = EDo d (map rewriteLamStmt stmts)
rewriteLamExpr (EStringInterp parts) =
  EStringInterp (map rewriteLamInterp parts)
rewriteLamExpr (EGuards arms) = EGuards (map rewriteLamGuardArm arms)
rewriteLamExpr (ERecordCreate n fs) = ERecordCreate n (map rewriteLamField fs)
rewriteLamExpr (ERecordUpdate e fs r) =
  ERecordUpdate (rewriteLamExpr e) (map rewriteLamField fs) r
rewriteLamExpr (EVariantUpdate c e fs) =
  EVariantUpdate c (rewriteLamExpr e) (map rewriteLamField fs)
rewriteLamExpr (EMapLit n kvs) = EMapLit n (map rewriteLamKv kvs)
rewriteLamExpr (ESetLit n es) = ESetLit n (map rewriteLamExpr es)
rewriteLamExpr (EAsPat x e) = EAsPat x (rewriteLamExpr e)
rewriteLamExpr (EOrPat es) = EOrPat (map rewriteLamExpr es)
rewriteLamExpr e = e

rewriteLamStmt : DoStmt -> DoStmt
rewriteLamStmt (DoExpr e) = DoExpr (rewriteLamExpr e)
rewriteLamStmt (DoBind p e) = DoBind p (rewriteLamExpr e)
rewriteLamStmt (DoLet m r p e site) = DoLet m r p (rewriteLamExpr e) site
rewriteLamStmt (DoAssign x e) = DoAssign x (rewriteLamExpr e)
rewriteLamStmt (DoFieldAssign x fs e) = DoFieldAssign x fs (rewriteLamExpr e)

rewriteLamArm : Arm -> Arm
rewriteLamArm (Arm p gs body) =
  Arm p (map rewriteLamGuard gs) (rewriteLamExpr body)

rewriteLamGuard : Guard -> Guard
rewriteLamGuard (GBool e) = GBool (rewriteLamExpr e)
rewriteLamGuard (GBind p e) = GBind p (rewriteLamExpr e)

rewriteLamLet : LetBind -> LetBind
rewriteLamLet (LetBind n clauses site bid) =
  LetBind n (map rewriteLamClause clauses) site bid

rewriteLamClause : FunClause -> FunClause
rewriteLamClause (FunClause ps body) = FunClause ps (rewriteLamExpr body)

rewriteLamSection : Section -> Section
rewriteLamSection (SecBare op) = SecBare op
rewriteLamSection (SecRight op e) = SecRight op (rewriteLamExpr e)
rewriteLamSection (SecLeft e op) = SecLeft (rewriteLamExpr e) op

rewriteLamInterp : InterpPart -> InterpPart
rewriteLamInterp (InterpStr s) = InterpStr s
rewriteLamInterp (InterpExpr e) = InterpExpr (rewriteLamExpr e)

rewriteLamGuardArm : GuardArm -> GuardArm
rewriteLamGuardArm (GuardArm gs body) =
  GuardArm (map rewriteLamGuard gs) (rewriteLamExpr body)

rewriteLamField : FieldAssign -> FieldAssign
rewriteLamField (FieldAssign n e) = FieldAssign n (rewriteLamExpr e)

rewriteLamKv : (Expr, Expr) -> (Expr, Expr)
rewriteLamKv (k, v) = (rewriteLamExpr k, rewriteLamExpr v)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Guard" true) (mem "Arm" true) (mem "ImplMethod" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "childExprs" false) (mem "declLocList" false) (mem "implMethodsBodyKey" false) (mem "isEVarNamed" false) (mem "mentionsVar" false) (mem "ruleNameLambdaSection" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameLambdaSection")) (fa "summary" (ELit (LString "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")"))) (fa "doc" (ELit (LString "A lambda whose body is a single binary operator applied to its parameter is an operator section. The section is shorter and names no throwaway variable.\n\nBefore:\n  map (x => x + 1) xs\nAfter:\n  map (+ 1) xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleLambdaSection")) (EApp (EVar "Some") (EVar "lambdaSectionFix"))))
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
(DTypeSig false "ruleLambdaSection" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleLambdaSection" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "lambdaSectionDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "lambdaSectionDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "lambdaSectionDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (EApp (EVar "lambdaSectionFinding") (EVar "loc"))) (EApp (EVar "declLamSections") (EVar "d"))))
(DTypeSig false "declLamSections" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "declLamSections" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "collectLamSections") (EVar "body")))
(DFunDef false "declLamSections" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "implMethodLamSections")) (EVar "methods")))
(DFunDef false "declLamSections" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declLamSections") (EVar "d")))
(DFunDef false "declLamSections" (PWild) (EListLit))
(DTypeSig false "implMethodLamSections" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "implMethodLamSections" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectLamSections") (EVar "body")))
(DTypeSig false "collectLamSections" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "collectLamSections" ((PVar "e")) (EBinOp "++" (EApp (EVar "lamHitOf") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "collectLamSections")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "lamHitOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "lamHitOf" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EVar "optSectionToList") (EApp (EApp (EVar "lamSection") (EVar "pats")) (EVar "body"))))
(DFunDef false "lamHitOf" (PWild) (EListLit))
(DTypeSig false "optSectionToList" (TyFun (TyApp (TyCon "Option") (TyCon "Section")) (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "optSectionToList" ((PCon "Some" (PVar "s"))) (EListLit (EVar "s")))
(DFunDef false "optSectionToList" ((PCon "None")) (EListLit))
(DTypeSig false "lambdaSectionFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Section") (TyCon "Finding"))))
(DFunDef false "lambdaSectionFinding" ((PVar "loc") (PVar "s")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameLambdaSection")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "lambda is a single binary operation on its parameter(s). Rewrite as the operator section '")) (EApp (EVar "exprToString") (EApp (EVar "ESection") (EVar "s")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "lambdaSectionFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lambdaSectionFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteLamExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2")) (EVar "site")) (EVar "bid"))))))))
(DFunDef false "lambdaSectionFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "lambdaSectionFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "lambdaSectionFix" (PWild (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild) (rf "methods" None)) false))) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EVar "map") (EVar "fixImplMethod")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EVar "methods2"))))))))))
(DFunDef false "lambdaSectionFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethod" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethod" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "tryLamSection" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "tryLamSection" ((PVar "ps") (PVar "b")) (EMatch (EApp (EApp (EVar "lamSection") (EVar "ps")) (EVar "b")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "ESection") (EVar "s"))) (arm (PCon "None") () (EApp (EApp (EVar "ELam") (EVar "ps")) (EVar "b")))))
(DTypeSig false "rewriteLamExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteLamExpr" ((PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamExpr" ((PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamExpr" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EVar "rewriteLamExpr") (EVar "f"))) (EApp (EVar "rewriteLamExpr") (EVar "x"))))
(DFunDef false "rewriteLamExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "tryLamSection") (EVar "ps")) (EApp (EVar "rewriteLamExpr") (EVar "b"))))
(DFunDef false "rewriteLamExpr" ((PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e1"))) (EApp (EVar "rewriteLamExpr") (EVar "e2"))))
(DFunDef false "rewriteLamExpr" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "rewriteLamExpr") (EVar "s"))) (EApp (EApp (EVar "map") (EVar "rewriteLamArm")) (EVar "arms"))))
(DFunDef false "rewriteLamExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EVar "rewriteLamExpr") (EVar "c"))) (EApp (EVar "rewriteLamExpr") (EVar "t"))) (EApp (EVar "rewriteLamExpr") (EVar "el"))))
(DFunDef false "rewriteLamExpr" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EApp (EVar "rewriteLamExpr") (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EApp (EVar "rewriteLamExpr") (EVar "b"))))
(DFunDef false "rewriteLamExpr" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "rewriteLamExpr") (EVar "lo"))) (EApp (EVar "rewriteLamExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteLamExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "rewriteLamExpr") (EVar "lo"))) (EApp (EVar "rewriteLamExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteLamExpr" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EApp (EVar "rewriteLamExpr") (EVar "lo"))) (EApp (EVar "rewriteLamExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteLamExpr" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EVar "rewriteLamLet")) (EVar "binds"))) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DFunDef false "rewriteLamExpr" ((PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EVar "rewriteLamSection") (EVar "s"))))
(DFunDef false "rewriteLamExpr" ((PCon "EIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EApp (EVar "rewriteLamExpr") (EVar "i"))))
(DFunDef false "rewriteLamExpr" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteLamExpr" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteLamExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "map") (EVar "rewriteLamStmt")) (EVar "stmts"))))
(DFunDef false "rewriteLamExpr" ((PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EVar "map") (EVar "rewriteLamStmt")) (EVar "stmts"))))
(DFunDef false "rewriteLamExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EVar "rewriteLamInterp")) (EVar "parts"))))
(DFunDef false "rewriteLamExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EVar "rewriteLamGuardArm")) (EVar "arms"))))
(DFunDef false "rewriteLamExpr" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteLamField")) (EVar "fs"))))
(DFunDef false "rewriteLamExpr" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EApp (EApp (EVar "map") (EVar "rewriteLamField")) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EApp (EApp (EVar "map") (EVar "rewriteLamField")) (EVar "fs"))))
(DFunDef false "rewriteLamExpr" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteLamKv")) (EVar "kvs"))))
(DFunDef false "rewriteLamExpr" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamExpr" ((PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EVar "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteLamStmt" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "rewriteLamStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "site")))
(DFunDef false "rewriteLamStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamArm" (TyFun (TyCon "Arm") (TyCon "Arm")))
(DFunDef false "rewriteLamArm" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EVar "map") (EVar "rewriteLamGuard")) (EVar "gs"))) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "rewriteLamGuard" (TyFun (TyCon "Guard") (TyCon "Guard")))
(DFunDef false "rewriteLamGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamLet" (TyFun (TyCon "LetBind") (TyCon "LetBind")))
(DFunDef false "rewriteLamLet" ((PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteLamClause")) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteLamClause" (TyFun (TyCon "FunClause") (TyCon "FunClause")))
(DFunDef false "rewriteLamClause" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "rewriteLamSection" (TyFun (TyCon "Section") (TyCon "Section")))
(DFunDef false "rewriteLamSection" ((PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteLamSection" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamSection" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteLamInterp" (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))
(DFunDef false "rewriteLamInterp" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteLamInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamGuardArm" (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))
(DFunDef false "rewriteLamGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EVar "map") (EVar "rewriteLamGuard")) (EVar "gs"))) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "rewriteLamField" (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))
(DFunDef false "rewriteLamField" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteLamKv" ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "rewriteLamExpr") (EVar "k")) (EApp (EVar "rewriteLamExpr") (EVar "v"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Guard" true) (mem "Arm" true) (mem "ImplMethod" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "childExprs" false) (mem "declLocList" false) (mem "implMethodsBodyKey" false) (mem "isEVarNamed" false) (mem "mentionsVar" false) (mem "ruleNameLambdaSection" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameLambdaSection")) (fa "summary" (ELit (LString "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")"))) (fa "doc" (ELit (LString "A lambda whose body is a single binary operator applied to its parameter is an operator section. The section is shorter and names no throwaway variable.\n\nBefore:\n  map (x => x + 1) xs\nAfter:\n  map (+ 1) xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleLambdaSection")) (EApp (EVar "Some") (EVar "lambdaSectionFix"))))
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
(DTypeSig false "ruleLambdaSection" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleLambdaSection" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "lambdaSectionDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "lambdaSectionDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "lambdaSectionDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "lambdaSectionFinding") (EVar "loc"))) (EApp (EVar "declLamSections") (EVar "d"))))
(DTypeSig false "declLamSections" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "declLamSections" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "collectLamSections") (EVar "body")))
(DFunDef false "declLamSections" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "implMethodLamSections")) (EVar "methods")))
(DFunDef false "declLamSections" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declLamSections") (EVar "d")))
(DFunDef false "declLamSections" (PWild) (EListLit))
(DTypeSig false "implMethodLamSections" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "implMethodLamSections" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectLamSections") (EVar "body")))
(DTypeSig false "collectLamSections" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "collectLamSections" ((PVar "e")) (EBinOp "++" (EApp (EVar "lamHitOf") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "collectLamSections")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "lamHitOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "lamHitOf" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EVar "optSectionToList") (EApp (EApp (EVar "lamSection") (EVar "pats")) (EVar "body"))))
(DFunDef false "lamHitOf" (PWild) (EListLit))
(DTypeSig false "optSectionToList" (TyFun (TyApp (TyCon "Option") (TyCon "Section")) (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "optSectionToList" ((PCon "Some" (PVar "s"))) (EListLit (EVar "s")))
(DFunDef false "optSectionToList" ((PCon "None")) (EListLit))
(DTypeSig false "lambdaSectionFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Section") (TyCon "Finding"))))
(DFunDef false "lambdaSectionFinding" ((PVar "loc") (PVar "s")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameLambdaSection")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "lambda is a single binary operation on its parameter(s). Rewrite as the operator section '")) (EApp (EVar "exprToString") (EApp (EVar "ESection") (EVar "s")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "lambdaSectionFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lambdaSectionFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteLamExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2")) (EVar "site")) (EVar "bid"))))))))
(DFunDef false "lambdaSectionFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "lambdaSectionFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "lambdaSectionFix" (PWild (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild) (rf "methods" None)) false))) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EMethodRef "map") (EVar "fixImplMethod")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EVar "methods2"))))))))))
(DFunDef false "lambdaSectionFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethod" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethod" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "tryLamSection" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "tryLamSection" ((PVar "ps") (PVar "b")) (EMatch (EApp (EApp (EVar "lamSection") (EVar "ps")) (EVar "b")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "ESection") (EVar "s"))) (arm (PCon "None") () (EApp (EApp (EVar "ELam") (EVar "ps")) (EVar "b")))))
(DTypeSig false "rewriteLamExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteLamExpr" ((PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamExpr" ((PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamExpr" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EVar "rewriteLamExpr") (EVar "f"))) (EApp (EVar "rewriteLamExpr") (EVar "x"))))
(DFunDef false "rewriteLamExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "tryLamSection") (EVar "ps")) (EApp (EVar "rewriteLamExpr") (EVar "b"))))
(DFunDef false "rewriteLamExpr" ((PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e1"))) (EApp (EVar "rewriteLamExpr") (EVar "e2"))))
(DFunDef false "rewriteLamExpr" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "rewriteLamExpr") (EVar "s"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamArm")) (EVar "arms"))))
(DFunDef false "rewriteLamExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EVar "rewriteLamExpr") (EVar "c"))) (EApp (EVar "rewriteLamExpr") (EVar "t"))) (EApp (EVar "rewriteLamExpr") (EVar "el"))))
(DFunDef false "rewriteLamExpr" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EApp (EVar "rewriteLamExpr") (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EApp (EVar "rewriteLamExpr") (EVar "b"))))
(DFunDef false "rewriteLamExpr" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "rewriteLamExpr") (EVar "lo"))) (EApp (EVar "rewriteLamExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteLamExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "rewriteLamExpr") (EVar "lo"))) (EApp (EVar "rewriteLamExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteLamExpr" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EApp (EVar "rewriteLamExpr") (EVar "lo"))) (EApp (EVar "rewriteLamExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteLamExpr" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamLet")) (EVar "binds"))) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DFunDef false "rewriteLamExpr" ((PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EVar "rewriteLamSection") (EVar "s"))))
(DFunDef false "rewriteLamExpr" ((PCon "EIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EApp (EVar "rewriteLamExpr") (EVar "i"))))
(DFunDef false "rewriteLamExpr" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteLamExpr" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteLamExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamStmt")) (EVar "stmts"))))
(DFunDef false "rewriteLamExpr" ((PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamStmt")) (EVar "stmts"))))
(DFunDef false "rewriteLamExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamInterp")) (EVar "parts"))))
(DFunDef false "rewriteLamExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamGuardArm")) (EVar "arms"))))
(DFunDef false "rewriteLamExpr" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamField")) (EVar "fs"))))
(DFunDef false "rewriteLamExpr" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamField")) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamField")) (EVar "fs"))))
(DFunDef false "rewriteLamExpr" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamKv")) (EVar "kvs"))))
(DFunDef false "rewriteLamExpr" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamExpr" ((PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteLamStmt" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "rewriteLamStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "site")))
(DFunDef false "rewriteLamStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamArm" (TyFun (TyCon "Arm") (TyCon "Arm")))
(DFunDef false "rewriteLamArm" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamGuard")) (EVar "gs"))) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "rewriteLamGuard" (TyFun (TyCon "Guard") (TyCon "Guard")))
(DFunDef false "rewriteLamGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamLet" (TyFun (TyCon "LetBind") (TyCon "LetBind")))
(DFunDef false "rewriteLamLet" ((PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamClause")) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteLamClause" (TyFun (TyCon "FunClause") (TyCon "FunClause")))
(DFunDef false "rewriteLamClause" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "rewriteLamSection" (TyFun (TyCon "Section") (TyCon "Section")))
(DFunDef false "rewriteLamSection" ((PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteLamSection" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamSection" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteLamInterp" (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))
(DFunDef false "rewriteLamInterp" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteLamInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamGuardArm" (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))
(DFunDef false "rewriteLamGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamGuard")) (EVar "gs"))) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "rewriteLamField" (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))
(DFunDef false "rewriteLamField" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteLamKv" ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "rewriteLamExpr") (EVar "k")) (EApp (EVar "rewriteLamExpr") (EVar "v"))))
