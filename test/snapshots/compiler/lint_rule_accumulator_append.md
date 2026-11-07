# META
source_lines=221
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-accumulator-append: `acc ++ e` grown across iterations of a loop (a self-call argument, `r := !r ++ e`, a fold lambda). Cons then `reverse`, collect then join once, or use a builder.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{Decl, Expr(..), Lit(..), Loc, orElseLoc}
import frontend.ast_walk.{
  BodyOwner(..),
  DeclBody(..),
  ExprKind(..),
  childExprs,
  declBodies,
}
import frontend.parser.{Positions(..)}
import list.{get}
import string.{contains}
import tools.lint_core.{
  Category(..),
  Ctx(..),
  FileFacts,
  Finding(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor(..),
  factScopes,
  mkVisitorRule,
  noFix,
}
import tools.lint_recursion.{
  ArgRole(..),
  FoldVerdict(..),
  Owner(..),
  SelfCall(..),
  foldVerdict,
  letOwners,
  selfCalls,
}
import tools.lint_scope.{FileScopes}
import tools.lint_shared.{
  appArgsOf, firstLoc, ruleNameAccumulatorAppend, unwrapLoc
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameAccumulatorAppend,
      summary =
        "`acc ++ e` grown across a loop: each step copies the whole accumulator. Cons then `reverse`, collect then join once, or use a builder",
      doc =
        "Appending to the end of an accumulator copies the accumulator, so a loop that does it once per step does work quadratic in the length of the result. The rule reports three shapes: a self-call that passes `acc ++ e` for one of its own parameters, `r := !r ++ e` on a `Ref` inside a self-recursive function, and a fold lambda `acc x => acc ++ ...`. The same holds for a `List`, a `String` and a `Bytes`. `e ++ acc` is not reported: for a `List` it costs only the length of `e`, while a `String`, `Bytes` or `Array` copies both operands. A partial application and a call to a different function (mutual recursion) are not self-calls.\n\nCons the new element and `reverse` once at the end, collect the pieces and join them once (`concat`, `joinWith`), or use a builder. A loop whose bound is small and fixed can carry a `-- lint-disable-next-line rule-accumulator-append` with the bound as its reason.\n\nBefore:\n  go acc (x :: xs) = go (acc ++ [f x]) xs\nAfter:\n  go acc (x :: xs) = go (f x :: acc) xs  -- and `reverse acc` at the end",
      category = Perf,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [NeedsScopes],
    }
    ruleAccumulatorAppend
    None

-- A file with no `++` has nothing to report, so its bodies are not walked.
ruleAccumulatorAppend : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleAccumulatorAppend _ _ facts _ _
  | contains "++" facts.ffSrc =
    let scopes = factScopes facts
    [
      OnDecl (declFindings scopes),
      OnExpr [KLetGroup] (localFindings scopes),
      OnExpr [KApp] foldFindings,
    ]
  | otherwise = []

-- The top-level owners of one declaration.  Test and prop bodies run over fixed
-- data and are not checked.
declFindings : FileScopes -> Ctx -> Decl -> List Finding
declFindings scopes ctx d =
  flatMap (bodyFindings scopes ctx.ctxSpan) (declBodies d)

bodyFindings : FileScopes -> Option Loc -> DeclBody -> List Finding
bodyFindings scopes fallback (DeclBody owner body) = match ownerOf owner
  Some o => ownerFindings scopes fallback (o, body)
  None => []

ownerOf : BodyOwner -> Option Owner
ownerOf (OwnerClause name ps) = Some (Owner name ps None)
ownerOf (OwnerImplMethod _ name ps) = Some (Owner name ps None)
ownerOf (OwnerIfaceDefault _ name ps) = Some (Owner name ps None)
ownerOf (OwnerLetGroup name ps) = Some (Owner name ps None)
ownerOf (OwnerTest _) = None
ownerOf (OwnerProp _ _) = None

-- The `where`/`let` loops of one group.
localFindings : FileScopes -> Ctx -> Expr -> List Finding
localFindings scopes ctx e
  | ctx.ctxInTest = []
  | otherwise = flatMap (ownerFindings scopes ctx.ctxSpan) (letOwners e)

ownerFindings : FileScopes -> Option Loc -> (Owner, Expr) -> List Finding
ownerFindings scopes fallback (owner, body) = match selfCalls scopes owner body
  [] => []
  calls =>
    flatMap (callFinding fallback) calls
      ++ map (refFinding fallback) (refAppends fallback body)

callFinding : Option Loc -> SelfCall -> List Finding
callFinding fallback (SelfCall loc call roles) =
  match appendedArg roles (appArgsOf call)
    Some a => [
      report
        (orElseLoc (firstLoc a) (orElseLoc loc fallback))
        (callMessage (kindOf a)),
    ]
    None => []

-- The argument whose role is `AppendedTo`, first by position.
appendedArg : List ArgRole -> List Expr -> Option Expr
appendedArg roles args = go 0 roles
  where
    go _ [] = None
    go i ((AppendedTo _) :: _) = get i args
    go i (_ :: rest) = go (i + 1) rest

-- What the appended operand is, when the source says so.
data Operand = OpList | OpString | OpUnknown

kindOf : Expr -> Operand
kindOf a = match unwrapLoc a
  EBinOp "++" _ r _ => kindOfRight r
  _ => OpUnknown

kindOfRight : Expr -> Operand
kindOfRight r = match unwrapLoc r
  EListLit _ => OpList
  ELit (LString _) => OpString
  _ => OpUnknown

-- ── `r := !r ++ e` ───────────────────────────────────────────────────────────

-- The assignments `r := !r ++ e` in `body`, not looking into the bodies of
-- nested `let`/`where` groups: those are owners of their own.
refAppends : Option Loc -> Expr -> List (Option Loc, Operand)
refAppends _ (ELoc l inner) = refAppends (Some l) inner
refAppends loc (EBinOp ":=" r v _) =
  assignOperand r v loc ++ flatMap (refAppends loc) [r, v]
refAppends loc (ELetGroup _ body) = refAppends loc body
refAppends loc e = flatMap (refAppends loc) (childExprs e)

assignOperand : Expr -> Expr -> Option Loc -> List (Option Loc, Operand)
assignOperand r v loc = match unwrapLoc v
  EBinOp "++" l rhs _ => if derefOf r l then [(loc, kindOfRight rhs)] else []
  _ => []

derefOf : Expr -> Expr -> Bool
derefOf r l = match unwrapLoc l
  EUnOp "!" inner _ => sameRef r inner
  _ => False

sameRef : Expr -> Expr -> Bool
sameRef a b = match (unwrapLoc a, unwrapLoc b)
  (EVar x, EVar y) => x == y
  _ => False

refFinding : Option Loc -> (Option Loc, Operand) -> Finding
refFinding fallback (loc, op) = report (orElseLoc loc fallback) (refMessage op)

-- ── fold lambdas ─────────────────────────────────────────────────────────────

-- A fold call is reported where its lambda is the last argument given: a call
-- supplies the lambda once, so the later partial prefixes of the same call are
-- not reported again.
foldFindings : Ctx -> Expr -> List Finding
foldFindings ctx e
  | ctx.ctxInTest = []
  | otherwise = match e
    EApp _ a => match unwrapLoc a
      ELam _ _ => match foldVerdict e
        FoldAppends => [report (orElseLoc (firstLoc e) ctx.ctxSpan) foldMessage]
        _ => []
      _ => []
    _ => []

-- ── findings ─────────────────────────────────────────────────────────────────

report : Option Loc -> String -> Finding
report loc message = Finding {
  rule = ruleNameAccumulatorAppend,
  message = message,
  severity = SevWarning,
  loc = loc,
  fix = noFix,
}

fixes : Operand -> String
fixes OpString =
  "Collect the pieces and join them once (`joinWith`, `concat`), or build the `String` with a builder"
fixes OpList =
  "Cons the element onto the accumulator and `reverse` once at the end, or collect the pieces and `concat` once"
fixes OpUnknown =
  "Cons onto the accumulator and `reverse` once at the end, collect the pieces and join them once, or use a builder"

callMessage : Operand -> String
callMessage op =
  "`acc ++ e` passed to a self-call copies the whole accumulator on every step, so the loop is quadratic. \{fixes op}"

refMessage : Operand -> String
refMessage op =
  "`r := !r ++ e` in a self-recursive function copies the whole value on every step, so the loop is quadratic. \{fixes op}"

foldMessage : String
foldMessage =
  "A fold lambda that returns `acc ++ ...` copies the whole accumulator on every step, so the fold is quadratic. \{fixes OpUnknown}"
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Expr" true) (mem "Lit" true) (mem "Loc" false) (mem "orElseLoc" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "ExprKind" true) (mem "childExprs" false) (mem "declBodies" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "get" false))))
(DUse false (UseGroup ("string") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "factScopes" false) (mem "mkVisitorRule" false) (mem "noFix" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "ArgRole" true) (mem "FoldVerdict" true) (mem "Owner" true) (mem "SelfCall" true) (mem "foldVerdict" false) (mem "letOwners" false) (mem "selfCalls" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "appArgsOf" false) (mem "firstLoc" false) (mem "ruleNameAccumulatorAppend" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameAccumulatorAppend")) (fa "summary" (ELit (LString "`acc ++ e` grown across a loop: each step copies the whole accumulator. Cons then `reverse`, collect then join once, or use a builder"))) (fa "doc" (ELit (LString "Appending to the end of an accumulator copies the accumulator, so a loop that does it once per step does work quadratic in the length of the result. The rule reports three shapes: a self-call that passes `acc ++ e` for one of its own parameters, `r := !r ++ e` on a `Ref` inside a self-recursive function, and a fold lambda `acc x => acc ++ ...`. The same holds for a `List`, a `String` and a `Bytes`. `e ++ acc` is not reported: for a `List` it costs only the length of `e`, while a `String`, `Bytes` or `Array` copies both operands. A partial application and a call to a different function (mutual recursion) are not self-calls.\n\nCons the new element and `reverse` once at the end, collect the pieces and join them once (`concat`, `joinWith`), or use a builder. A loop whose bound is small and fixed can carry a `-- lint-disable-next-line rule-accumulator-append` with the bound as its reason.\n\nBefore:\n  go acc (x :: xs) = go (acc ++ [f x]) xs\nAfter:\n  go acc (x :: xs) = go (f x :: acc) xs  -- and `reverse acc` at the end"))) (fa "category" (EVar "Perf")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleAccumulatorAppend")) (EVar "None")))
(DTypeSig false "ruleAccumulatorAppend" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleAccumulatorAppend" (PWild PWild (PVar "facts") PWild PWild) (EIf (EApp (EApp (EVar "contains") (ELit (LString "++"))) (EFieldAccess (EVar "facts") "ffSrc")) (EBlock (DoLet false false (PVar "scopes") (EApp (EVar "factScopes") (EVar "facts"))) (DoExpr (EListLit (EApp (EVar "OnDecl") (EApp (EVar "declFindings") (EVar "scopes"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KLetGroup"))) (EApp (EVar "localFindings") (EVar "scopes"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KApp"))) (EVar "foldFindings"))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declFindings" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "declFindings" ((PVar "scopes") (PVar "ctx") (PVar "d")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "bodyFindings") (EVar "scopes")) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig false "bodyFindings" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DeclBody") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "bodyFindings" ((PVar "scopes") (PVar "fallback") (PCon "DeclBody" (PVar "owner") (PVar "body"))) (EMatch (EApp (EVar "ownerOf") (EVar "owner")) (arm (PCon "Some" (PVar "o")) () (EApp (EApp (EApp (EVar "ownerFindings") (EVar "scopes")) (EVar "fallback")) (ETuple (EVar "o") (EVar "body")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "ownerOf" (TyFun (TyCon "BodyOwner") (TyApp (TyCon "Option") (TyCon "Owner"))))
(DFunDef false "ownerOf" ((PCon "OwnerClause" (PVar "name") (PVar "ps"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))))
(DFunDef false "ownerOf" ((PCon "OwnerImplMethod" PWild (PVar "name") (PVar "ps"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))))
(DFunDef false "ownerOf" ((PCon "OwnerIfaceDefault" PWild (PVar "name") (PVar "ps"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))))
(DFunDef false "ownerOf" ((PCon "OwnerLetGroup" (PVar "name") (PVar "ps"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))))
(DFunDef false "ownerOf" ((PCon "OwnerTest" PWild)) (EVar "None"))
(DFunDef false "ownerOf" ((PCon "OwnerProp" PWild PWild)) (EVar "None"))
(DTypeSig false "localFindings" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "localFindings" ((PVar "scopes") (PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "ownerFindings") (EVar "scopes")) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EVar "letOwners") (EVar "e"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ownerFindings" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "Owner") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "ownerFindings" ((PVar "scopes") (PVar "fallback") (PTuple (PVar "owner") (PVar "body"))) (EMatch (EApp (EApp (EApp (EVar "selfCalls") (EVar "scopes")) (EVar "owner")) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "calls") () (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "callFinding") (EVar "fallback"))) (EVar "calls")) (EApp (EApp (EVar "map") (EApp (EVar "refFinding") (EVar "fallback"))) (EApp (EApp (EVar "refAppends") (EVar "fallback")) (EVar "body")))))))
(DTypeSig false "callFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "SelfCall") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "callFinding" ((PVar "fallback") (PCon "SelfCall" (PVar "loc") (PVar "call") (PVar "roles"))) (EMatch (EApp (EApp (EVar "appendedArg") (EVar "roles")) (EApp (EVar "appArgsOf") (EVar "call"))) (arm (PCon "Some" (PVar "a")) () (EListLit (EApp (EApp (EVar "report") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "a"))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "fallback")))) (EApp (EVar "callMessage") (EApp (EVar "kindOf") (EVar "a")))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "appendedArg" (TyFun (TyApp (TyCon "List") (TyCon "ArgRole")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "appendedArg" ((PVar "roles") (PVar "args")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EVar "None")) (clause ((PVar "i") (PCons (PCon "AppendedTo" PWild) PWild)) (EApp (EApp (EVar "get") (EVar "i")) (EVar "args"))) (clause ((PVar "i") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "roles"))))
(DData Private "Operand" () ((variant "OpList" (ConPos)) (variant "OpString" (ConPos)) (variant "OpUnknown" (ConPos))) ())
(DTypeSig false "kindOf" (TyFun (TyCon "Expr") (TyCon "Operand")))
(DFunDef false "kindOf" ((PVar "a")) (EMatch (EApp (EVar "unwrapLoc") (EVar "a")) (arm (PCon "EBinOp" (PLit (LString "++")) PWild (PVar "r") PWild) () (EApp (EVar "kindOfRight") (EVar "r"))) (arm PWild () (EVar "OpUnknown"))))
(DTypeSig false "kindOfRight" (TyFun (TyCon "Expr") (TyCon "Operand")))
(DFunDef false "kindOfRight" ((PVar "r")) (EMatch (EApp (EVar "unwrapLoc") (EVar "r")) (arm (PCon "EListLit" PWild) () (EVar "OpList")) (arm (PCon "ELit" (PCon "LString" PWild)) () (EVar "OpString")) (arm PWild () (EVar "OpUnknown"))))
(DTypeSig false "refAppends" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Operand"))))))
(DFunDef false "refAppends" (PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EVar "refAppends") (EApp (EVar "Some") (EVar "l"))) (EVar "inner")))
(DFunDef false "refAppends" ((PVar "loc") (PCon "EBinOp" (PLit (LString ":=")) (PVar "r") (PVar "v") PWild)) (EBinOp "++" (EApp (EApp (EApp (EVar "assignOperand") (EVar "r")) (EVar "v")) (EVar "loc")) (EApp (EApp (EVar "flatMap") (EApp (EVar "refAppends") (EVar "loc"))) (EListLit (EVar "r") (EVar "v")))))
(DFunDef false "refAppends" ((PVar "loc") (PCon "ELetGroup" PWild (PVar "body"))) (EApp (EApp (EVar "refAppends") (EVar "loc")) (EVar "body")))
(DFunDef false "refAppends" ((PVar "loc") (PVar "e")) (EApp (EApp (EVar "flatMap") (EApp (EVar "refAppends") (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e"))))
(DTypeSig false "assignOperand" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Operand")))))))
(DFunDef false "assignOperand" ((PVar "r") (PVar "v") (PVar "loc")) (EMatch (EApp (EVar "unwrapLoc") (EVar "v")) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "l") (PVar "rhs") PWild) () (EIf (EApp (EApp (EVar "derefOf") (EVar "r")) (EVar "l")) (EListLit (ETuple (EVar "loc") (EApp (EVar "kindOfRight") (EVar "rhs")))) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig false "derefOf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "derefOf" ((PVar "r") (PVar "l")) (EMatch (EApp (EVar "unwrapLoc") (EVar "l")) (arm (PCon "EUnOp" (PLit (LString "!")) (PVar "inner") PWild) () (EApp (EApp (EVar "sameRef") (EVar "r")) (EVar "inner"))) (arm PWild () (EVar "False"))))
(DTypeSig false "sameRef" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "sameRef" ((PVar "a") (PVar "b")) (EMatch (ETuple (EApp (EVar "unwrapLoc") (EVar "a")) (EApp (EVar "unwrapLoc") (EVar "b"))) (arm (PTuple (PCon "EVar" (PVar "x")) (PCon "EVar" (PVar "y"))) () (EBinOp "==" (EVar "x") (EVar "y"))) (arm PWild () (EVar "False"))))
(DTypeSig false "refFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Operand")) (TyCon "Finding"))))
(DFunDef false "refFinding" ((PVar "fallback") (PTuple (PVar "loc") (PVar "op"))) (EApp (EApp (EVar "report") (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "fallback"))) (EApp (EVar "refMessage") (EVar "op"))))
(DTypeSig false "foldFindings" (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "foldFindings" ((PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EMatch (EVar "e") (arm (PCon "EApp" PWild (PVar "a")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "a")) (arm (PCon "ELam" PWild PWild) () (EMatch (EApp (EVar "foldVerdict") (EVar "e")) (arm (PCon "FoldAppends") () (EListLit (EApp (EApp (EVar "report") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "e"))) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EVar "foldMessage")))) (arm PWild () (EListLit)))) (arm PWild () (EListLit)))) (arm PWild () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "report" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "report" ((PVar "loc") (PVar "message")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameAccumulatorAppend")) (fa "message" (EVar "message")) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "noFix")))))
(DTypeSig false "fixes" (TyFun (TyCon "Operand") (TyCon "String")))
(DFunDef false "fixes" ((PCon "OpString")) (ELit (LString "Collect the pieces and join them once (`joinWith`, `concat`), or build the `String` with a builder")))
(DFunDef false "fixes" ((PCon "OpList")) (ELit (LString "Cons the element onto the accumulator and `reverse` once at the end, or collect the pieces and `concat` once")))
(DFunDef false "fixes" ((PCon "OpUnknown")) (ELit (LString "Cons onto the accumulator and `reverse` once at the end, collect the pieces and join them once, or use a builder")))
(DTypeSig false "callMessage" (TyFun (TyCon "Operand") (TyCon "String")))
(DFunDef false "callMessage" ((PVar "op")) (EBinOp "++" (EBinOp "++" (ELit (LString "`acc ++ e` passed to a self-call copies the whole accumulator on every step, so the loop is quadratic. ")) (EApp (EVar "$core.display") (EApp (EVar "fixes") (EVar "op")))) (ELit (LString ""))))
(DTypeSig false "refMessage" (TyFun (TyCon "Operand") (TyCon "String")))
(DFunDef false "refMessage" ((PVar "op")) (EBinOp "++" (EBinOp "++" (ELit (LString "`r := !r ++ e` in a self-recursive function copies the whole value on every step, so the loop is quadratic. ")) (EApp (EVar "$core.display") (EApp (EVar "fixes") (EVar "op")))) (ELit (LString ""))))
(DTypeSig false "foldMessage" (TyCon "String"))
(DFunDef false "foldMessage" () (EBinOp "++" (EBinOp "++" (ELit (LString "A fold lambda that returns `acc ++ ...` copies the whole accumulator on every step, so the fold is quadratic. ")) (EApp (EVar "$core.display") (EApp (EVar "fixes") (EVar "OpUnknown")))) (ELit (LString ""))))
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Expr" true) (mem "Lit" true) (mem "Loc" false) (mem "orElseLoc" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "ExprKind" true) (mem "childExprs" false) (mem "declBodies" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "get" false))))
(DUse false (UseGroup ("string") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "factScopes" false) (mem "mkVisitorRule" false) (mem "noFix" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "ArgRole" true) (mem "FoldVerdict" true) (mem "Owner" true) (mem "SelfCall" true) (mem "foldVerdict" false) (mem "letOwners" false) (mem "selfCalls" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "appArgsOf" false) (mem "firstLoc" false) (mem "ruleNameAccumulatorAppend" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameAccumulatorAppend")) (fa "summary" (ELit (LString "`acc ++ e` grown across a loop: each step copies the whole accumulator. Cons then `reverse`, collect then join once, or use a builder"))) (fa "doc" (ELit (LString "Appending to the end of an accumulator copies the accumulator, so a loop that does it once per step does work quadratic in the length of the result. The rule reports three shapes: a self-call that passes `acc ++ e` for one of its own parameters, `r := !r ++ e` on a `Ref` inside a self-recursive function, and a fold lambda `acc x => acc ++ ...`. The same holds for a `List`, a `String` and a `Bytes`. `e ++ acc` is not reported: for a `List` it costs only the length of `e`, while a `String`, `Bytes` or `Array` copies both operands. A partial application and a call to a different function (mutual recursion) are not self-calls.\n\nCons the new element and `reverse` once at the end, collect the pieces and join them once (`concat`, `joinWith`), or use a builder. A loop whose bound is small and fixed can carry a `-- lint-disable-next-line rule-accumulator-append` with the bound as its reason.\n\nBefore:\n  go acc (x :: xs) = go (acc ++ [f x]) xs\nAfter:\n  go acc (x :: xs) = go (f x :: acc) xs  -- and `reverse acc` at the end"))) (fa "category" (EVar "Perf")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleAccumulatorAppend")) (EVar "None")))
(DTypeSig false "ruleAccumulatorAppend" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleAccumulatorAppend" (PWild PWild (PVar "facts") PWild PWild) (EIf (EApp (EApp (EVar "contains") (ELit (LString "++"))) (EFieldAccess (EVar "facts") "ffSrc")) (EBlock (DoLet false false (PVar "scopes") (EApp (EVar "factScopes") (EVar "facts"))) (DoExpr (EListLit (EApp (EVar "OnDecl") (EApp (EVar "declFindings") (EVar "scopes"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KLetGroup"))) (EApp (EVar "localFindings") (EVar "scopes"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KApp"))) (EVar "foldFindings"))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declFindings" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "declFindings" ((PVar "scopes") (PVar "ctx") (PVar "d")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "bodyFindings") (EVar "scopes")) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig false "bodyFindings" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DeclBody") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "bodyFindings" ((PVar "scopes") (PVar "fallback") (PCon "DeclBody" (PVar "owner") (PVar "body"))) (EMatch (EApp (EVar "ownerOf") (EVar "owner")) (arm (PCon "Some" (PVar "o")) () (EApp (EApp (EApp (EVar "ownerFindings") (EVar "scopes")) (EVar "fallback")) (ETuple (EVar "o") (EVar "body")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "ownerOf" (TyFun (TyCon "BodyOwner") (TyApp (TyCon "Option") (TyCon "Owner"))))
(DFunDef false "ownerOf" ((PCon "OwnerClause" (PVar "name") (PVar "ps"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))))
(DFunDef false "ownerOf" ((PCon "OwnerImplMethod" PWild (PVar "name") (PVar "ps"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))))
(DFunDef false "ownerOf" ((PCon "OwnerIfaceDefault" PWild (PVar "name") (PVar "ps"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))))
(DFunDef false "ownerOf" ((PCon "OwnerLetGroup" (PVar "name") (PVar "ps"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))))
(DFunDef false "ownerOf" ((PCon "OwnerTest" PWild)) (EVar "None"))
(DFunDef false "ownerOf" ((PCon "OwnerProp" PWild PWild)) (EVar "None"))
(DTypeSig false "localFindings" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "localFindings" ((PVar "scopes") (PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "ownerFindings") (EVar "scopes")) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EVar "letOwners") (EVar "e"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ownerFindings" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "Owner") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "ownerFindings" ((PVar "scopes") (PVar "fallback") (PTuple (PVar "owner") (PVar "body"))) (EMatch (EApp (EApp (EApp (EVar "selfCalls") (EVar "scopes")) (EVar "owner")) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "calls") () (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "callFinding") (EVar "fallback"))) (EVar "calls")) (EApp (EApp (EMethodRef "map") (EApp (EVar "refFinding") (EVar "fallback"))) (EApp (EApp (EVar "refAppends") (EVar "fallback")) (EVar "body")))))))
(DTypeSig false "callFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "SelfCall") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "callFinding" ((PVar "fallback") (PCon "SelfCall" (PVar "loc") (PVar "call") (PVar "roles"))) (EMatch (EApp (EApp (EVar "appendedArg") (EVar "roles")) (EApp (EVar "appArgsOf") (EVar "call"))) (arm (PCon "Some" (PVar "a")) () (EListLit (EApp (EApp (EVar "report") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "a"))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "fallback")))) (EApp (EVar "callMessage") (EApp (EVar "kindOf") (EVar "a")))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "appendedArg" (TyFun (TyApp (TyCon "List") (TyCon "ArgRole")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "appendedArg" ((PVar "roles") (PVar "args")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EVar "None")) (clause ((PVar "i") (PCons (PCon "AppendedTo" PWild) PWild)) (EApp (EApp (EVar "get") (EVar "i")) (EVar "args"))) (clause ((PVar "i") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "roles"))))
(DData Private "Operand" () ((variant "OpList" (ConPos)) (variant "OpString" (ConPos)) (variant "OpUnknown" (ConPos))) ())
(DTypeSig false "kindOf" (TyFun (TyCon "Expr") (TyCon "Operand")))
(DFunDef false "kindOf" ((PVar "a")) (EMatch (EApp (EVar "unwrapLoc") (EVar "a")) (arm (PCon "EBinOp" (PLit (LString "++")) PWild (PVar "r") PWild) () (EApp (EVar "kindOfRight") (EVar "r"))) (arm PWild () (EVar "OpUnknown"))))
(DTypeSig false "kindOfRight" (TyFun (TyCon "Expr") (TyCon "Operand")))
(DFunDef false "kindOfRight" ((PVar "r")) (EMatch (EApp (EVar "unwrapLoc") (EVar "r")) (arm (PCon "EListLit" PWild) () (EVar "OpList")) (arm (PCon "ELit" (PCon "LString" PWild)) () (EVar "OpString")) (arm PWild () (EVar "OpUnknown"))))
(DTypeSig false "refAppends" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Operand"))))))
(DFunDef false "refAppends" (PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EVar "refAppends") (EApp (EVar "Some") (EVar "l"))) (EVar "inner")))
(DFunDef false "refAppends" ((PVar "loc") (PCon "EBinOp" (PLit (LString ":=")) (PVar "r") (PVar "v") PWild)) (EBinOp "++" (EApp (EApp (EApp (EVar "assignOperand") (EVar "r")) (EVar "v")) (EVar "loc")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "refAppends") (EVar "loc"))) (EListLit (EVar "r") (EVar "v")))))
(DFunDef false "refAppends" ((PVar "loc") (PCon "ELetGroup" PWild (PVar "body"))) (EApp (EApp (EVar "refAppends") (EVar "loc")) (EVar "body")))
(DFunDef false "refAppends" ((PVar "loc") (PVar "e")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "refAppends") (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e"))))
(DTypeSig false "assignOperand" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Operand")))))))
(DFunDef false "assignOperand" ((PVar "r") (PVar "v") (PVar "loc")) (EMatch (EApp (EVar "unwrapLoc") (EVar "v")) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "l") (PVar "rhs") PWild) () (EIf (EApp (EApp (EVar "derefOf") (EVar "r")) (EVar "l")) (EListLit (ETuple (EVar "loc") (EApp (EVar "kindOfRight") (EVar "rhs")))) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig false "derefOf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "derefOf" ((PVar "r") (PVar "l")) (EMatch (EApp (EVar "unwrapLoc") (EVar "l")) (arm (PCon "EUnOp" (PLit (LString "!")) (PVar "inner") PWild) () (EApp (EApp (EVar "sameRef") (EVar "r")) (EVar "inner"))) (arm PWild () (EVar "False"))))
(DTypeSig false "sameRef" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "sameRef" ((PVar "a") (PVar "b")) (EMatch (ETuple (EApp (EVar "unwrapLoc") (EVar "a")) (EApp (EVar "unwrapLoc") (EVar "b"))) (arm (PTuple (PCon "EVar" (PVar "x")) (PCon "EVar" (PVar "y"))) () (EBinOp "==" (EVar "x") (EVar "y"))) (arm PWild () (EVar "False"))))
(DTypeSig false "refFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Operand")) (TyCon "Finding"))))
(DFunDef false "refFinding" ((PVar "fallback") (PTuple (PVar "loc") (PVar "op"))) (EApp (EApp (EVar "report") (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "fallback"))) (EApp (EVar "refMessage") (EVar "op"))))
(DTypeSig false "foldFindings" (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "foldFindings" ((PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EMatch (EVar "e") (arm (PCon "EApp" PWild (PVar "a")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "a")) (arm (PCon "ELam" PWild PWild) () (EMatch (EApp (EVar "foldVerdict") (EVar "e")) (arm (PCon "FoldAppends") () (EListLit (EApp (EApp (EVar "report") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "e"))) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EVar "foldMessage")))) (arm PWild () (EListLit)))) (arm PWild () (EListLit)))) (arm PWild () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "report" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "report" ((PVar "loc") (PVar "message")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameAccumulatorAppend")) (fa "message" (EVar "message")) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "noFix")))))
(DTypeSig false "fixes" (TyFun (TyCon "Operand") (TyCon "String")))
(DFunDef false "fixes" ((PCon "OpString")) (ELit (LString "Collect the pieces and join them once (`joinWith`, `concat`), or build the `String` with a builder")))
(DFunDef false "fixes" ((PCon "OpList")) (ELit (LString "Cons the element onto the accumulator and `reverse` once at the end, or collect the pieces and `concat` once")))
(DFunDef false "fixes" ((PCon "OpUnknown")) (ELit (LString "Cons onto the accumulator and `reverse` once at the end, collect the pieces and join them once, or use a builder")))
(DTypeSig false "callMessage" (TyFun (TyCon "Operand") (TyCon "String")))
(DFunDef false "callMessage" ((PVar "op")) (EBinOp "++" (EBinOp "++" (ELit (LString "`acc ++ e` passed to a self-call copies the whole accumulator on every step, so the loop is quadratic. ")) (EApp (EVar "$core.display") (EApp (EVar "fixes") (EVar "op")))) (ELit (LString ""))))
(DTypeSig false "refMessage" (TyFun (TyCon "Operand") (TyCon "String")))
(DFunDef false "refMessage" ((PVar "op")) (EBinOp "++" (EBinOp "++" (ELit (LString "`r := !r ++ e` in a self-recursive function copies the whole value on every step, so the loop is quadratic. ")) (EApp (EVar "$core.display") (EApp (EVar "fixes") (EVar "op")))) (ELit (LString ""))))
(DTypeSig false "foldMessage" (TyCon "String"))
(DFunDef false "foldMessage" () (EBinOp "++" (EBinOp "++" (ELit (LString "A fold lambda that returns `acc ++ ...` copies the whole accumulator on every step, so the fold is quadratic. ")) (EApp (EVar "$core.display") (EApp (EVar "fixes") (EVar "OpUnknown")))) (ELit (LString ""))))
