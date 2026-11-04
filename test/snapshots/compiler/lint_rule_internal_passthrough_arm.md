# META
source_lines=176
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-passthrough-arm: a two-arm `match` over an Option/Result with a verbatim `None => None` / `Err e => Err e` arm. Bind in a `do` block instead.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{
  Arm(..), Decl, DoStmt(..), Expr(..), FunClause(..), LetBind(..), Loc, Pat(..)
}
import frontend.ast_walk.{
  BodyOwner(..), DeclBody(..), ExprKind(..), childExprs, declBodies
}
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
-- `rule-match-to-map`), and a match whose success arm ends in a call of the
-- enclosing function (a self-recursive tail), where the `do` form costs a
-- closure per iteration.
export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNamePassthroughArm,
      summary =
        "a two-arm `match` over an Option/Result with a verbatim `None => None` / `Err e => Err e` arm: bind in a `do` block instead",
      doc =
        "A `match` that passes a failure straight through (`None => None`, or `Err e => Err e` with the same variable) and continues in the other arm is a monadic bind written by hand. Write it as a `do` block, at any depth: one level is enough, unlike `rule-bind-chain-to-do`, which needs a pyramid of three. The rule only suggests; it has no fixer.\n\nNot reported: a failure arm that rebuilds its value (`Err e => Err (wrap e)`), a match with a third arm or a guard, a success arm that re-wraps in the same constructor (`rule-match-to-map` owns it). A match whose success arm ends, through `if`, `let`, `match` arms and block tails, in a call of the enclosing function (a self-recursive tail, including a where-local `go`) is not reported: the `do` form lowers to `andThen`, which allocates a closure per iteration and measurably slows the loop.\n\nBefore:\n  match catalogRow n\n    Some r => g r\n    None => None\nAfter:\n  do\n    r <- catalogRow n\n    g r",
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
rulePassthroughArm _ _ _ _ prog =
  [OnExpr [KMatch] (passthroughAt (flatMap declExempt prog))]

-- ── the match ────────────────────────────────────────────────────────────────

-- `exempt` holds the span of each match whose success arm is a self-recursive
-- tail.
passthroughAt : List (Option Loc) -> Ctx -> Expr -> List Finding
passthroughAt exempt ctx e = match passthroughOf e
  Some (kind, _) =>
    if anyList (== ctx.ctxSpan) exempt then [] else [report ctx.ctxSpan kind]
  None => []

-- `(kind, success body)` of a two-arm passthrough `match`.
passthroughOf : Expr -> Option (String, Expr)
passthroughOf (EMatch _ [a1, a2]) = match bindArm a1 a2
  Some r => Some r
  None => bindArm a2 a1
passthroughOf _ = None

-- ── self-recursive tails ─────────────────────────────────────────────────────

-- The spans of the passthrough matches in a declaration's bodies whose success
-- arm ends in a call of the nearest enclosing function: the clause itself, or
-- the `where`/`let` binding the match sits in.
declExempt : Decl -> List (Option Loc)
declExempt d = flatMap bodyExempt (declBodies d)

bodyExempt : DeclBody -> List (Option Loc)
bodyExempt (DeclBody owner body) = exemptIn (ownerName owner) None body

ownerName : BodyOwner -> String
ownerName (OwnerClause n _) = n
ownerName (OwnerImplMethod _ m _) = m
ownerName (OwnerIfaceDefault _ m _) = m
ownerName (OwnerTest _) = ""
ownerName (OwnerProp _ _) = ""
ownerName (OwnerLetGroup n _) = n

exemptIn : String -> Option Loc -> Expr -> List (Option Loc)
exemptIn owner _ (ELoc l inner) = exemptIn owner (Some l) inner
exemptIn owner loc e =
  thisExempt owner loc e
    ++ (match e
      ELetGroup binds body =>
        flatMap (localExempt loc) binds ++ exemptIn owner loc body
      _ => flatMap (exemptIn owner loc) (childExprs e))

localExempt : Option Loc -> LetBind -> List (Option Loc)
localExempt loc (LetBind n clauses _ _) =
  flatMap ((FunClause _ body) => exemptIn n loc body) clauses

thisExempt : String -> Option Loc -> Expr -> List (Option Loc)
thisExempt owner loc e = match passthroughOf e
  Some (_, body) => if selfTail owner body then [loc] else []
  None => []

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
success ctor kind (p@(PCon c [_])) body =
  if c == ctor && isNone (matchToMapTransform ctor p body) then
    Some (kind, body)
  else
    None
success _ _ _ _ = None

-- Some tail position of `e` is a call of `name`, the function the match sits in.
selfTail : String -> Expr -> Bool
selfTail name e = match unwrapLoc e
  EApp f _ => calls name f
  EIf _ t el => selfTail name t || selfTail name el
  ELet _ _ _ _ body => selfTail name body
  ELetGroup _ body => selfTail name body
  EMatch _ arms => anyList (armTail name) arms
  EBlock stmts => match last stmts
    Some (DoExpr l) => selfTail name l
    _ => False
  _ => False

armTail : String -> Arm -> Bool
armTail name (Arm _ _ body) = selfTail name body

calls : String -> Expr -> Bool
calls name f = match unwrapLoc f
  EVar n => n == name
  EApp g _ => calls name g
  _ => False

report : Option Loc -> String -> Finding
report loc kind = Finding {
  rule = ruleNamePassthroughArm,
  message =
    "`match` over \{kind} passes the failure straight through: bind it in a `do` block (`pat <- scrutinee`, then the success arm)",
  severity = SevWarning,
  loc = loc,
  fix = None,
}
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" false) (mem "DoStmt" true) (mem "Expr" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Loc" false) (mem "Pat" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "ExprKind" true) (mem "childExprs" false) (mem "declBodies" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ctorVarPassthru" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchToMapTransform" false) (mem "ruleNamePassthroughArm" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePassthroughArm")) (fa "summary" (ELit (LString "a two-arm `match` over an Option/Result with a verbatim `None => None` / `Err e => Err e` arm: bind in a `do` block instead"))) (fa "doc" (ELit (LString "A `match` that passes a failure straight through (`None => None`, or `Err e => Err e` with the same variable) and continues in the other arm is a monadic bind written by hand. Write it as a `do` block, at any depth: one level is enough, unlike `rule-bind-chain-to-do`, which needs a pyramid of three. The rule only suggests; it has no fixer.\n\nNot reported: a failure arm that rebuilds its value (`Err e => Err (wrap e)`), a match with a third arm or a guard, a success arm that re-wraps in the same constructor (`rule-match-to-map` owns it). A match whose success arm ends, through `if`, `let`, `match` arms and block tails, in a call of the enclosing function (a self-recursive tail, including a where-local `go`) is not reported: the `do` form lowers to `andThen`, which allocates a closure per iteration and measurably slows the loop.\n\nBefore:\n  match catalogRow n\n    Some r => g r\n    None => None\nAfter:\n  do\n    r <- catalogRow n\n    g r"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "SuggestOnly")) (fa "needs" (EListLit))))) (EVar "rulePassthroughArm")) (EVar "None")))
(DTypeSig false "rulePassthroughArm" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "rulePassthroughArm" (PWild PWild PWild PWild (PVar "prog")) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KMatch"))) (EApp (EVar "passthroughAt") (EApp (EApp (EVar "flatMap") (EVar "declExempt")) (EVar "prog"))))))
(DTypeSig false "passthroughAt" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "passthroughAt" ((PVar "exempt") (PVar "ctx") (PVar "e")) (EMatch (EApp (EVar "passthroughOf") (EVar "e")) (arm (PCon "Some" (PTuple (PVar "kind") PWild)) () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EFieldAccess (EVar "ctx") "ctxSpan")))) (EVar "exempt")) (EListLit) (EListLit (EApp (EApp (EVar "report") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "kind"))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "passthroughOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr")))))
(DFunDef false "passthroughOf" ((PCon "EMatch" PWild (PList (PVar "a1") (PVar "a2")))) (EMatch (EApp (EApp (EVar "bindArm") (EVar "a1")) (EVar "a2")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "Some") (EVar "r"))) (arm (PCon "None") () (EApp (EApp (EVar "bindArm") (EVar "a2")) (EVar "a1")))))
(DFunDef false "passthroughOf" (PWild) (EVar "None"))
(DTypeSig false "declExempt" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "declExempt" ((PVar "d")) (EApp (EApp (EVar "flatMap") (EVar "bodyExempt")) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig false "bodyExempt" (TyFun (TyCon "DeclBody") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "bodyExempt" ((PCon "DeclBody" (PVar "owner") (PVar "body"))) (EApp (EApp (EApp (EVar "exemptIn") (EApp (EVar "ownerName") (EVar "owner"))) (EVar "None")) (EVar "body")))
(DTypeSig false "ownerName" (TyFun (TyCon "BodyOwner") (TyCon "String")))
(DFunDef false "ownerName" ((PCon "OwnerClause" (PVar "n") PWild)) (EVar "n"))
(DFunDef false "ownerName" ((PCon "OwnerImplMethod" PWild (PVar "m") PWild)) (EVar "m"))
(DFunDef false "ownerName" ((PCon "OwnerIfaceDefault" PWild (PVar "m") PWild)) (EVar "m"))
(DFunDef false "ownerName" ((PCon "OwnerTest" PWild)) (ELit (LString "")))
(DFunDef false "ownerName" ((PCon "OwnerProp" PWild PWild)) (ELit (LString "")))
(DFunDef false "ownerName" ((PCon "OwnerLetGroup" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "exemptIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "exemptIn" ((PVar "owner") PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EApp (EVar "exemptIn") (EVar "owner")) (EApp (EVar "Some") (EVar "l"))) (EVar "inner")))
(DFunDef false "exemptIn" ((PVar "owner") (PVar "loc") (PVar "e")) (EBinOp "++" (EApp (EApp (EApp (EVar "thisExempt") (EVar "owner")) (EVar "loc")) (EVar "e")) (EMatch (EVar "e") (arm (PCon "ELetGroup" (PVar "binds") (PVar "body")) () (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "localExempt") (EVar "loc"))) (EVar "binds")) (EApp (EApp (EApp (EVar "exemptIn") (EVar "owner")) (EVar "loc")) (EVar "body")))) (arm PWild () (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "exemptIn") (EVar "owner")) (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e")))))))
(DTypeSig false "localExempt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "localExempt" ((PVar "loc") (PCon "LetBind" (PVar "n") (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "flatMap") (ELam ((PCon "FunClause" PWild (PVar "body"))) (EApp (EApp (EApp (EVar "exemptIn") (EVar "n")) (EVar "loc")) (EVar "body")))) (EVar "clauses")))
(DTypeSig false "thisExempt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "thisExempt" ((PVar "owner") (PVar "loc") (PVar "e")) (EMatch (EApp (EVar "passthroughOf") (EVar "e")) (arm (PCon "Some" (PTuple PWild (PVar "body"))) () (EIf (EApp (EApp (EVar "selfTail") (EVar "owner")) (EVar "body")) (EListLit (EVar "loc")) (EListLit))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "bindArm" (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr"))))))
(DFunDef false "bindArm" ((PCon "Arm" (PVar "fp") (PVar "fgs") (PVar "fbody")) (PCon "Arm" (PVar "sp") (PVar "sgs") (PVar "sbody"))) (EIf (EApp (EVar "not") (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "fgs")) (EApp (EVar "isEmptyL") (EVar "sgs")))) (EVar "None") (EIf (EBinOp "&&" (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "fp")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "None"))) (EVar "fbody"))) (EApp (EApp (EApp (EApp (EVar "success") (ELit (LString "Some"))) (ELit (LString "Option"))) (EVar "sp")) (EVar "sbody")) (EIf (EApp (EApp (EApp (EVar "ctorVarPassthru") (ELit (LString "Err"))) (EVar "fp")) (EVar "fbody")) (EApp (EApp (EApp (EApp (EVar "success") (ELit (LString "Ok"))) (ELit (LString "Result"))) (EVar "sp")) (EVar "sbody")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "success" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr"))))))))
(DFunDef false "success" ((PVar "ctor") (PVar "kind") (PAs "p" (PCon "PCon" (PVar "c") (PList PWild))) (PVar "body")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (EVar "ctor")) (EApp (EVar "isNone") (EApp (EApp (EApp (EVar "matchToMapTransform") (EVar "ctor")) (EVar "p")) (EVar "body")))) (EApp (EVar "Some") (ETuple (EVar "kind") (EVar "body"))) (EVar "None")))
(DFunDef false "success" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "selfTail" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "selfTail" ((PVar "name") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EApp (EVar "calls") (EVar "name")) (EVar "f"))) (arm (PCon "EIf" PWild (PVar "t") (PVar "el")) () (EBinOp "||" (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "t")) (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "el")))) (arm (PCon "ELet" PWild PWild PWild PWild (PVar "body")) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "body"))) (arm (PCon "ELetGroup" PWild (PVar "body")) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "body"))) (arm (PCon "EMatch" PWild (PVar "arms")) () (EApp (EApp (EVar "anyList") (EApp (EVar "armTail") (EVar "name"))) (EVar "arms"))) (arm (PCon "EBlock" (PVar "stmts")) () (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoExpr" (PVar "l"))) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "l"))) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "armTail" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armTail" ((PVar "name") (PCon "Arm" PWild PWild (PVar "body"))) (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "body")))
(DTypeSig false "calls" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "calls" ((PVar "name") (PVar "f")) (EMatch (EApp (EVar "unwrapLoc") (EVar "f")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "EApp" (PVar "g") PWild) () (EApp (EApp (EVar "calls") (EVar "name")) (EVar "g"))) (arm PWild () (EVar "False"))))
(DTypeSig false "report" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "report" ((PVar "loc") (PVar "kind")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePassthroughArm")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`match` over ")) (EApp (EVar "display") (EVar "kind"))) (ELit (LString " passes the failure straight through: bind it in a `do` block (`pat <- scrutinee`, then the success arm)")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" false) (mem "DoStmt" true) (mem "Expr" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Loc" false) (mem "Pat" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "ExprKind" true) (mem "childExprs" false) (mem "declBodies" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ctorVarPassthru" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchToMapTransform" false) (mem "ruleNamePassthroughArm" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePassthroughArm")) (fa "summary" (ELit (LString "a two-arm `match` over an Option/Result with a verbatim `None => None` / `Err e => Err e` arm: bind in a `do` block instead"))) (fa "doc" (ELit (LString "A `match` that passes a failure straight through (`None => None`, or `Err e => Err e` with the same variable) and continues in the other arm is a monadic bind written by hand. Write it as a `do` block, at any depth: one level is enough, unlike `rule-bind-chain-to-do`, which needs a pyramid of three. The rule only suggests; it has no fixer.\n\nNot reported: a failure arm that rebuilds its value (`Err e => Err (wrap e)`), a match with a third arm or a guard, a success arm that re-wraps in the same constructor (`rule-match-to-map` owns it). A match whose success arm ends, through `if`, `let`, `match` arms and block tails, in a call of the enclosing function (a self-recursive tail, including a where-local `go`) is not reported: the `do` form lowers to `andThen`, which allocates a closure per iteration and measurably slows the loop.\n\nBefore:\n  match catalogRow n\n    Some r => g r\n    None => None\nAfter:\n  do\n    r <- catalogRow n\n    g r"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "SuggestOnly")) (fa "needs" (EListLit))))) (EVar "rulePassthroughArm")) (EVar "None")))
(DTypeSig false "rulePassthroughArm" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "rulePassthroughArm" (PWild PWild PWild PWild (PVar "prog")) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KMatch"))) (EApp (EVar "passthroughAt") (EApp (EApp (EDictApp "flatMap") (EVar "declExempt")) (EVar "prog"))))))
(DTypeSig false "passthroughAt" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "passthroughAt" ((PVar "exempt") (PVar "ctx") (PVar "e")) (EMatch (EApp (EVar "passthroughOf") (EVar "e")) (arm (PCon "Some" (PTuple (PVar "kind") PWild)) () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EFieldAccess (EVar "ctx") "ctxSpan")))) (EVar "exempt")) (EListLit) (EListLit (EApp (EApp (EVar "report") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "kind"))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "passthroughOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr")))))
(DFunDef false "passthroughOf" ((PCon "EMatch" PWild (PList (PVar "a1") (PVar "a2")))) (EMatch (EApp (EApp (EVar "bindArm") (EVar "a1")) (EVar "a2")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "Some") (EVar "r"))) (arm (PCon "None") () (EApp (EApp (EVar "bindArm") (EVar "a2")) (EVar "a1")))))
(DFunDef false "passthroughOf" (PWild) (EVar "None"))
(DTypeSig false "declExempt" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "declExempt" ((PVar "d")) (EApp (EApp (EDictApp "flatMap") (EVar "bodyExempt")) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig false "bodyExempt" (TyFun (TyCon "DeclBody") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "bodyExempt" ((PCon "DeclBody" (PVar "owner") (PVar "body"))) (EApp (EApp (EApp (EVar "exemptIn") (EApp (EVar "ownerName") (EVar "owner"))) (EVar "None")) (EVar "body")))
(DTypeSig false "ownerName" (TyFun (TyCon "BodyOwner") (TyCon "String")))
(DFunDef false "ownerName" ((PCon "OwnerClause" (PVar "n") PWild)) (EVar "n"))
(DFunDef false "ownerName" ((PCon "OwnerImplMethod" PWild (PVar "m") PWild)) (EVar "m"))
(DFunDef false "ownerName" ((PCon "OwnerIfaceDefault" PWild (PVar "m") PWild)) (EVar "m"))
(DFunDef false "ownerName" ((PCon "OwnerTest" PWild)) (ELit (LString "")))
(DFunDef false "ownerName" ((PCon "OwnerProp" PWild PWild)) (ELit (LString "")))
(DFunDef false "ownerName" ((PCon "OwnerLetGroup" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "exemptIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "exemptIn" ((PVar "owner") PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EApp (EVar "exemptIn") (EVar "owner")) (EApp (EVar "Some") (EVar "l"))) (EVar "inner")))
(DFunDef false "exemptIn" ((PVar "owner") (PVar "loc") (PVar "e")) (EBinOp "++" (EApp (EApp (EApp (EVar "thisExempt") (EVar "owner")) (EVar "loc")) (EVar "e")) (EMatch (EVar "e") (arm (PCon "ELetGroup" (PVar "binds") (PVar "body")) () (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "localExempt") (EVar "loc"))) (EVar "binds")) (EApp (EApp (EApp (EVar "exemptIn") (EVar "owner")) (EVar "loc")) (EVar "body")))) (arm PWild () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "exemptIn") (EVar "owner")) (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e")))))))
(DTypeSig false "localExempt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "localExempt" ((PVar "loc") (PCon "LetBind" (PVar "n") (PVar "clauses") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (ELam ((PCon "FunClause" PWild (PVar "body"))) (EApp (EApp (EApp (EVar "exemptIn") (EVar "n")) (EVar "loc")) (EVar "body")))) (EVar "clauses")))
(DTypeSig false "thisExempt" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "thisExempt" ((PVar "owner") (PVar "loc") (PVar "e")) (EMatch (EApp (EVar "passthroughOf") (EVar "e")) (arm (PCon "Some" (PTuple PWild (PVar "body"))) () (EIf (EApp (EApp (EVar "selfTail") (EVar "owner")) (EVar "body")) (EListLit (EVar "loc")) (EListLit))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "bindArm" (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr"))))))
(DFunDef false "bindArm" ((PCon "Arm" (PVar "fp") (PVar "fgs") (PVar "fbody")) (PCon "Arm" (PVar "sp") (PVar "sgs") (PVar "sbody"))) (EIf (EApp (EVar "not") (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "fgs")) (EApp (EVar "isEmptyL") (EVar "sgs")))) (EVar "None") (EIf (EBinOp "&&" (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "fp")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "None"))) (EVar "fbody"))) (EApp (EApp (EApp (EApp (EVar "success") (ELit (LString "Some"))) (ELit (LString "Option"))) (EVar "sp")) (EVar "sbody")) (EIf (EApp (EApp (EApp (EVar "ctorVarPassthru") (ELit (LString "Err"))) (EVar "fp")) (EVar "fbody")) (EApp (EApp (EApp (EApp (EVar "success") (ELit (LString "Ok"))) (ELit (LString "Result"))) (EVar "sp")) (EVar "sbody")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "success" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr"))))))))
(DFunDef false "success" ((PVar "ctor") (PVar "kind") (PAs "p" (PCon "PCon" (PVar "c") (PList PWild))) (PVar "body")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (EVar "ctor")) (EApp (EVar "isNone") (EApp (EApp (EApp (EVar "matchToMapTransform") (EVar "ctor")) (EVar "p")) (EVar "body")))) (EApp (EVar "Some") (ETuple (EVar "kind") (EVar "body"))) (EVar "None")))
(DFunDef false "success" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "selfTail" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "selfTail" ((PVar "name") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EApp (EVar "calls") (EVar "name")) (EVar "f"))) (arm (PCon "EIf" PWild (PVar "t") (PVar "el")) () (EBinOp "||" (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "t")) (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "el")))) (arm (PCon "ELet" PWild PWild PWild PWild (PVar "body")) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "body"))) (arm (PCon "ELetGroup" PWild (PVar "body")) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "body"))) (arm (PCon "EMatch" PWild (PVar "arms")) () (EApp (EApp (EVar "anyList") (EApp (EVar "armTail") (EVar "name"))) (EVar "arms"))) (arm (PCon "EBlock" (PVar "stmts")) () (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoExpr" (PVar "l"))) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "l"))) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "armTail" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armTail" ((PVar "name") (PCon "Arm" PWild PWild (PVar "body"))) (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "body")))
(DTypeSig false "calls" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "calls" ((PVar "name") (PVar "f")) (EMatch (EApp (EVar "unwrapLoc") (EVar "f")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "EApp" (PVar "g") PWild) () (EApp (EApp (EVar "calls") (EVar "name")) (EVar "g"))) (arm PWild () (EVar "False"))))
(DTypeSig false "report" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "report" ((PVar "loc") (PVar "kind")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePassthroughArm")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`match` over ")) (EApp (EMethodRef "display") (EVar "kind"))) (ELit (LString " passes the failure straight through: bind it in a `do` block (`pat <- scrutinee`, then the success arm)")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
