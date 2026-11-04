# META
source_lines=144
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-passthrough-arm: a two-arm `match` over an Option/Result with a verbatim `None => None` / `Err e => Err e` arm. Bind in a `do` block instead.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{
  Arm(..), Decl(..), DoStmt(..), Expr(..), Loc, Pat(..), Variant(..)
}
import frontend.ast_walk.{ExprKind(..)}
import frontend.parser.{Positions(..)}
import list.{last}
import support.util.{anyList, isEmptyL}
import tools.lint_core.{
  Category(..),
  Ctx(..),
  FileFacts,
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
  ctorVarPassthru,
  isEVarNamed,
  isNilPCon,
  matchToMapTransform,
  ruleNamePassthroughArm,
  unwrapLoc,
}

-- Flagged at any depth, one level included: a `match` with exactly two arms, no
-- guards, one a verbatim failure passthrough (`None => None`, or `Err e => Err e`
-- returning the bound variable unchanged) and the other the success bind
-- (`Some p => body`, `Ok p => body`). Not flagged: a rebuilt failure value
-- (`Err e => Err (wrap e)`), a constructor swap, a third arm, a guarded arm, a
-- success arm that re-wraps in the same constructor (a `map`, owned by
-- `rule-match-to-map`), and any file that declares its own `None` or `Err`
-- constructor. A self-recursive tail is flagged too; the message says so, since
-- the `do` form loses the tail call.
export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNamePassthroughArm,
      summary =
        "a two-arm `match` over an Option/Result with a verbatim `None => None` / `Err e => Err e` arm: bind in a `do` block instead",
      doc =
        "A `match` that passes a failure straight through (`None => None`, or `Err e => Err e` with the same variable) and continues in the other arm is a monadic bind written by hand. Write it as a `do` block, at any depth: one level is enough, unlike `rule-bind-chain-to-do`, which needs a pyramid of three. The rule only suggests; it has no fixer.\n\nNot reported: a failure arm that rebuilds its value (`Err e => Err (wrap e)`), a match with a third arm or a guard, a success arm that re-wraps in the same constructor (`rule-match-to-map` owns it), and a file that declares its own `None` or `Err` constructor. A self-recursive tail call in the success arm is reported, and the message says so: the `do` form lowers to `andThen` and the call stops being a tail call.\n\nBefore:\n  match catalogRow n\n    Some r => g r\n    None => None\nAfter:\n  do\n    r <- catalogRow n\n    g r",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = SuggestOnly,
      needs = [],
    }
    rulePassthroughArm
    None

rulePassthroughArm : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
rulePassthroughArm _ _ _ _ prog
  | declaresCtor prog = []
  | otherwise = [OnExpr [KMatch] passthroughAt]

-- The file declares a constructor named `None` or `Err`, so the arm names no
-- longer mean the prelude's.
declaresCtor : List Decl -> Bool
declaresCtor prog = anyList declCtor prog

declCtor : Decl -> Bool
declCtor (DData { dataCtors }) = anyList shadowing dataCtors
declCtor _ = False

shadowing : Variant -> Bool
shadowing (Variant n _) = n == "None" || n == "Err"

-- ── the match ────────────────────────────────────────────────────────────────

passthroughAt : Ctx -> Expr -> List Finding
passthroughAt ctx e = match e
  EMatch _ [a1, a2] => match bindArm a1 a2
    Some (kind, body) =>
      [report ctx.ctxSpan kind (selfTail ctx.ctxDeclName body)]
    None => match bindArm a2 a1
      Some (kind, body) =>
        [report ctx.ctxSpan kind (selfTail ctx.ctxDeclName body)]
      None => []
  _ => []

-- `(kind, success body)` when the first arm is the passthrough and the second
-- the bind.
bindArm : Arm -> Arm -> Option (String, Expr)
bindArm (Arm fp fgs fbody) (Arm sp sgs sbody)
  | not (isEmptyL fgs && isEmptyL sgs) = None
  | isNilPCon "None" fp && isEVarNamed "None" fbody =
    success "Some" "Option" sp sbody
  | ctorVarPassthru "Err" fp fbody = success "Ok" "Result" sp sbody
  | otherwise = None

success : String -> String -> Pat -> Expr -> Option (String, Expr)
success ctor kind p body = match p
  PCon c [_] =>
    if c == ctor && isNone (matchToMapTransform ctor p body) then
      Some (kind, body)
    else
      None
  _ => None

-- The success body ends in a call of the enclosing function.
selfTail : String -> Expr -> Bool
selfTail name e = match unwrapLoc e
  EApp f _ => calls name f
  EBlock stmts => match last stmts
    Some (DoExpr l) => selfTail name l
    _ => False
  _ => False

calls : String -> Expr -> Bool
calls name f = match unwrapLoc f
  EVar n => n == name
  EApp g _ => calls name g
  _ => False

report : Option Loc -> String -> Bool -> Finding
report loc kind tailNote = Finding {
  rule = ruleNamePassthroughArm,
  message =
    "`match` over \{kind} passes the failure straight through: bind it in a `do` block (`pat <- scrutinee`, then the success arm)"
      ++ (if tailNote then
        "; the success arm is a self-recursive tail call, which `do` does not keep"
      else
        ""),
  severity = SevWarning,
  loc = loc,
  fix = None,
}
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "Loc" false) (mem "Pat" true) (mem "Variant" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ctorVarPassthru" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchToMapTransform" false) (mem "ruleNamePassthroughArm" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePassthroughArm")) (fa "summary" (ELit (LString "a two-arm `match` over an Option/Result with a verbatim `None => None` / `Err e => Err e` arm: bind in a `do` block instead"))) (fa "doc" (ELit (LString "A `match` that passes a failure straight through (`None => None`, or `Err e => Err e` with the same variable) and continues in the other arm is a monadic bind written by hand. Write it as a `do` block, at any depth: one level is enough, unlike `rule-bind-chain-to-do`, which needs a pyramid of three. The rule only suggests; it has no fixer.\n\nNot reported: a failure arm that rebuilds its value (`Err e => Err (wrap e)`), a match with a third arm or a guard, a success arm that re-wraps in the same constructor (`rule-match-to-map` owns it), and a file that declares its own `None` or `Err` constructor. A self-recursive tail call in the success arm is reported, and the message says so: the `do` form lowers to `andThen` and the call stops being a tail call.\n\nBefore:\n  match catalogRow n\n    Some r => g r\n    None => None\nAfter:\n  do\n    r <- catalogRow n\n    g r"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "SuggestOnly")) (fa "needs" (EListLit))))) (EVar "rulePassthroughArm")) (EVar "None")))
(DTypeSig false "rulePassthroughArm" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "rulePassthroughArm" (PWild PWild PWild PWild (PVar "prog")) (EIf (EApp (EVar "declaresCtor") (EVar "prog")) (EListLit) (EIf (EVar "otherwise") (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KMatch"))) (EVar "passthroughAt"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declaresCtor" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "declaresCtor" ((PVar "prog")) (EApp (EApp (EVar "anyList") (EVar "declCtor")) (EVar "prog")))
(DTypeSig false "declCtor" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "declCtor" ((PRec "DData" ((rf "dataCtors" None)) false)) (EApp (EApp (EVar "anyList") (EVar "shadowing")) (EVar "dataCtors")))
(DFunDef false "declCtor" (PWild) (EVar "False"))
(DTypeSig false "shadowing" (TyFun (TyCon "Variant") (TyCon "Bool")))
(DFunDef false "shadowing" ((PCon "Variant" (PVar "n") PWild)) (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "None"))) (EBinOp "==" (EVar "n") (ELit (LString "Err")))))
(DTypeSig false "passthroughAt" (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "passthroughAt" ((PVar "ctx") (PVar "e")) (EMatch (EVar "e") (arm (PCon "EMatch" PWild (PList (PVar "a1") (PVar "a2"))) () (EMatch (EApp (EApp (EVar "bindArm") (EVar "a1")) (EVar "a2")) (arm (PCon "Some" (PTuple (PVar "kind") (PVar "body"))) () (EListLit (EApp (EApp (EApp (EVar "report") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "kind")) (EApp (EApp (EVar "selfTail") (EFieldAccess (EVar "ctx") "ctxDeclName")) (EVar "body"))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "bindArm") (EVar "a2")) (EVar "a1")) (arm (PCon "Some" (PTuple (PVar "kind") (PVar "body"))) () (EListLit (EApp (EApp (EApp (EVar "report") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "kind")) (EApp (EApp (EVar "selfTail") (EFieldAccess (EVar "ctx") "ctxDeclName")) (EVar "body"))))) (arm (PCon "None") () (EListLit)))))) (arm PWild () (EListLit))))
(DTypeSig false "bindArm" (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr"))))))
(DFunDef false "bindArm" ((PCon "Arm" (PVar "fp") (PVar "fgs") (PVar "fbody")) (PCon "Arm" (PVar "sp") (PVar "sgs") (PVar "sbody"))) (EIf (EApp (EVar "not") (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "fgs")) (EApp (EVar "isEmptyL") (EVar "sgs")))) (EVar "None") (EIf (EBinOp "&&" (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "fp")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "None"))) (EVar "fbody"))) (EApp (EApp (EApp (EApp (EVar "success") (ELit (LString "Some"))) (ELit (LString "Option"))) (EVar "sp")) (EVar "sbody")) (EIf (EApp (EApp (EApp (EVar "ctorVarPassthru") (ELit (LString "Err"))) (EVar "fp")) (EVar "fbody")) (EApp (EApp (EApp (EApp (EVar "success") (ELit (LString "Ok"))) (ELit (LString "Result"))) (EVar "sp")) (EVar "sbody")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "success" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr"))))))))
(DFunDef false "success" ((PVar "ctor") (PVar "kind") (PVar "p") (PVar "body")) (EMatch (EVar "p") (arm (PCon "PCon" (PVar "c") (PList PWild)) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (EVar "ctor")) (EApp (EVar "isNone") (EApp (EApp (EApp (EVar "matchToMapTransform") (EVar "ctor")) (EVar "p")) (EVar "body")))) (EApp (EVar "Some") (ETuple (EVar "kind") (EVar "body"))) (EVar "None"))) (arm PWild () (EVar "None"))))
(DTypeSig false "selfTail" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "selfTail" ((PVar "name") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EApp (EVar "calls") (EVar "name")) (EVar "f"))) (arm (PCon "EBlock" (PVar "stmts")) () (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoExpr" (PVar "l"))) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "l"))) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "calls" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "calls" ((PVar "name") (PVar "f")) (EMatch (EApp (EVar "unwrapLoc") (EVar "f")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "EApp" (PVar "g") PWild) () (EApp (EApp (EVar "calls") (EVar "name")) (EVar "g"))) (arm PWild () (EVar "False"))))
(DTypeSig false "report" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Finding")))))
(DFunDef false "report" ((PVar "loc") (PVar "kind") (PVar "tailNote")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePassthroughArm")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`match` over ")) (EApp (EVar "display") (EVar "kind"))) (ELit (LString " passes the failure straight through: bind it in a `do` block (`pat <- scrutinee`, then the success arm)"))) (EIf (EVar "tailNote") (ELit (LString "; the success arm is a self-recursive tail call, which `do` does not keep")) (ELit (LString ""))))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "Loc" false) (mem "Pat" true) (mem "Variant" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ctorVarPassthru" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchToMapTransform" false) (mem "ruleNamePassthroughArm" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePassthroughArm")) (fa "summary" (ELit (LString "a two-arm `match` over an Option/Result with a verbatim `None => None` / `Err e => Err e` arm: bind in a `do` block instead"))) (fa "doc" (ELit (LString "A `match` that passes a failure straight through (`None => None`, or `Err e => Err e` with the same variable) and continues in the other arm is a monadic bind written by hand. Write it as a `do` block, at any depth: one level is enough, unlike `rule-bind-chain-to-do`, which needs a pyramid of three. The rule only suggests; it has no fixer.\n\nNot reported: a failure arm that rebuilds its value (`Err e => Err (wrap e)`), a match with a third arm or a guard, a success arm that re-wraps in the same constructor (`rule-match-to-map` owns it), and a file that declares its own `None` or `Err` constructor. A self-recursive tail call in the success arm is reported, and the message says so: the `do` form lowers to `andThen` and the call stops being a tail call.\n\nBefore:\n  match catalogRow n\n    Some r => g r\n    None => None\nAfter:\n  do\n    r <- catalogRow n\n    g r"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "SuggestOnly")) (fa "needs" (EListLit))))) (EVar "rulePassthroughArm")) (EVar "None")))
(DTypeSig false "rulePassthroughArm" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "rulePassthroughArm" (PWild PWild PWild PWild (PVar "prog")) (EIf (EApp (EVar "declaresCtor") (EVar "prog")) (EListLit) (EIf (EVar "otherwise") (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KMatch"))) (EVar "passthroughAt"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declaresCtor" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "declaresCtor" ((PVar "prog")) (EApp (EApp (EVar "anyList") (EVar "declCtor")) (EVar "prog")))
(DTypeSig false "declCtor" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "declCtor" ((PRec "DData" ((rf "dataCtors" None)) false)) (EApp (EApp (EVar "anyList") (EVar "shadowing")) (EVar "dataCtors")))
(DFunDef false "declCtor" (PWild) (EVar "False"))
(DTypeSig false "shadowing" (TyFun (TyCon "Variant") (TyCon "Bool")))
(DFunDef false "shadowing" ((PCon "Variant" (PVar "n") PWild)) (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "None"))) (EBinOp "==" (EVar "n") (ELit (LString "Err")))))
(DTypeSig false "passthroughAt" (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "passthroughAt" ((PVar "ctx") (PVar "e")) (EMatch (EVar "e") (arm (PCon "EMatch" PWild (PList (PVar "a1") (PVar "a2"))) () (EMatch (EApp (EApp (EVar "bindArm") (EVar "a1")) (EVar "a2")) (arm (PCon "Some" (PTuple (PVar "kind") (PVar "body"))) () (EListLit (EApp (EApp (EApp (EVar "report") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "kind")) (EApp (EApp (EVar "selfTail") (EFieldAccess (EVar "ctx") "ctxDeclName")) (EVar "body"))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "bindArm") (EVar "a2")) (EVar "a1")) (arm (PCon "Some" (PTuple (PVar "kind") (PVar "body"))) () (EListLit (EApp (EApp (EApp (EVar "report") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "kind")) (EApp (EApp (EVar "selfTail") (EFieldAccess (EVar "ctx") "ctxDeclName")) (EVar "body"))))) (arm (PCon "None") () (EListLit)))))) (arm PWild () (EListLit))))
(DTypeSig false "bindArm" (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr"))))))
(DFunDef false "bindArm" ((PCon "Arm" (PVar "fp") (PVar "fgs") (PVar "fbody")) (PCon "Arm" (PVar "sp") (PVar "sgs") (PVar "sbody"))) (EIf (EApp (EVar "not") (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "fgs")) (EApp (EVar "isEmptyL") (EVar "sgs")))) (EVar "None") (EIf (EBinOp "&&" (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "fp")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "None"))) (EVar "fbody"))) (EApp (EApp (EApp (EApp (EVar "success") (ELit (LString "Some"))) (ELit (LString "Option"))) (EVar "sp")) (EVar "sbody")) (EIf (EApp (EApp (EApp (EVar "ctorVarPassthru") (ELit (LString "Err"))) (EVar "fp")) (EVar "fbody")) (EApp (EApp (EApp (EApp (EVar "success") (ELit (LString "Ok"))) (ELit (LString "Result"))) (EVar "sp")) (EVar "sbody")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "success" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr"))))))))
(DFunDef false "success" ((PVar "ctor") (PVar "kind") (PVar "p") (PVar "body")) (EMatch (EVar "p") (arm (PCon "PCon" (PVar "c") (PList PWild)) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (EVar "ctor")) (EApp (EVar "isNone") (EApp (EApp (EApp (EVar "matchToMapTransform") (EVar "ctor")) (EVar "p")) (EVar "body")))) (EApp (EVar "Some") (ETuple (EVar "kind") (EVar "body"))) (EVar "None"))) (arm PWild () (EVar "None"))))
(DTypeSig false "selfTail" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "selfTail" ((PVar "name") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EApp (EVar "calls") (EVar "name")) (EVar "f"))) (arm (PCon "EBlock" (PVar "stmts")) () (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoExpr" (PVar "l"))) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "l"))) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "calls" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "calls" ((PVar "name") (PVar "f")) (EMatch (EApp (EVar "unwrapLoc") (EVar "f")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "EApp" (PVar "g") PWild) () (EApp (EApp (EVar "calls") (EVar "name")) (EVar "g"))) (arm PWild () (EVar "False"))))
(DTypeSig false "report" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Finding")))))
(DFunDef false "report" ((PVar "loc") (PVar "kind") (PVar "tailNote")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePassthroughArm")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`match` over ")) (EApp (EMethodRef "display") (EVar "kind"))) (ELit (LString " passes the failure straight through: bind it in a `do` block (`pat <- scrutinee`, then the success arm)"))) (EIf (EVar "tailNote") (ELit (LString "; the success arm is a self-recursive tail call, which `do` does not keep")) (ELit (LString ""))))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
