# META
source_lines=137
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-threaded-invariant: a top-level self-recursive function whose self-calls all pass two or more of its own parameters through unchanged. Close over them in a where-local `go`.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{Decl(..), Expr, Loc, Pat(..)}
import frontend.parser.{Positions(..)}
import list.{get}
import support.util.{allList, anyList, filterList, joinWith, listLen}
import tools.lint_core.{
  Category(..),
  FileFacts,
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
import tools.lint_recursion.{ArgRole(..), Owner(..), SelfCall(..), selfCalls}
import tools.lint_scope.{FileScopes}
import tools.lint_shared.{declLocList, mentionsVar, ruleNameThreadedInvariant}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameThreadedInvariant,
      summary =
        "a self-recursive function passes two or more of its parameters through every self-call unchanged: close over them in a where-local `go`",
      doc =
        "A top-level function that calls itself with the same two or more parameters, in the same positions, in every self-call carries those parameters through the whole recursion for nothing. A local `go` in a `where` closes over them, so the recursion names only what changes. The rule reads each function as a group of clauses: a position counts when every full-arity self-call of every clause that makes one passes that clause's own parameter there, unchanged. One invariant parameter is not reported, nor is a `go` that already closes over its invariants, a partial application, mutual recursion, or a loop local to a `let` or `where`.\n\nBefore:\n  extractFold bare heads acc (x :: xs) = extractFold bare heads (step bare heads acc x) xs\n  extractFold _ _ acc [] = acc\nAfter:\n  extractFold bare heads acc0 xs0 = go acc0 xs0\n    where\n      go acc [] = acc\n      go acc (x :: xs) = go (step bare heads acc x) xs",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = SuggestOnly,
      needs = [NeedsScopes],
    }
    ruleThreadedInvariant
    None

ruleThreadedInvariant : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleThreadedInvariant _ _ facts pos prog =
  let scopes = factScopes facts
  flatMap (functionFindings scopes) (functionGroups (declLocList pos prog))

-- ── the functions of a file ──────────────────────────────────────────────────

-- A top-level function: its name, the start line of its first clause and its
-- clauses in order.
data Group = Group String (Option Loc) (List (List Pat, Expr))

-- Adjacent clauses of one name make one function.
functionGroups : List (Decl, Option Loc) -> List Group
functionGroups dls = foldRight joinClause [] (flatMap clauseOf dls)

clauseOf : (Decl, Option Loc) -> List (String, Option Loc, (List Pat, Expr))
clauseOf (DFunDef _ n ps body _ _, loc) = [(n, loc, (ps, body))]
clauseOf (DAttrib _ d, loc) = clauseOf (d, loc)
clauseOf _ = []

joinClause : (String, Option Loc, (List Pat, Expr)) -> List Group -> List Group
joinClause (n, loc, c) ((Group m _ cs) :: rest)
  | n == m = Group n loc (c :: cs) :: rest
joinClause (n, loc, c) groups = Group n loc [c] :: groups

-- ── one function ─────────────────────────────────────────────────────────────

-- A clause that makes self-calls, with the positions all of them pass through
-- unchanged.
data Threaded = Threaded (List Pat) (List Int)

functionFindings : FileScopes -> Group -> List Finding
functionFindings scopes (Group name loc clauses) =
  match flatMap (clauseThreaded scopes name) clauses
    [] => []
    ts@((Threaded ps first) :: _) =>
      let shared = filterList (inAll ts) first
      if listLen shared >= 2 then
        [report name loc (map (i => paramName ps i) shared)]
      else
        []

-- A clause that never names its own function makes no self-call, and that is
-- nearly every clause, so the scope-aware walk runs only on the rest.
clauseThreaded : FileScopes -> String -> (List Pat, Expr) -> List Threaded
clauseThreaded scopes name (ps, body)
  | listLen ps < 2 || not (mentionsVar name body) = []
  | otherwise = match selfCalls scopes (Owner name ps None) body
    [] => []
    calls => [Threaded ps (filterList (unchangedIn calls) [0..=listLen ps - 1])]

inAll : List Threaded -> Int -> Bool
inAll ts i = allList (t => hasPosition i t) ts

hasPosition : Int -> Threaded -> Bool
hasPosition i (Threaded _ positions) = anyList (== i) positions

unchangedIn : List SelfCall -> Int -> Bool
unchangedIn calls i = allList (callKeeps i) calls

callKeeps : Int -> SelfCall -> Bool
callKeeps i (SelfCall _ _ roles) = match get i roles
  Some (Unchanged j) => j == i
  _ => False

paramName : List Pat -> Int -> String
paramName ps i = match get i ps
  Some (PVar n _ _) => n
  Some (PAs n _ _ _) => n
  _ => "_"

-- ── findings ─────────────────────────────────────────────────────────────────

report : String -> Option Loc -> List String -> Finding
report name loc names =
  let listed = joinWith ", " (map quoted names)
  Finding {
    rule = ruleNameThreadedInvariant,
    message =
      "`\{name}` passes \{listed} through every self-call unchanged: close over them in a where-local `go`",
    severity = SevWarning,
    loc = loc,
    fix = None,
  }

quoted : String -> String
quoted n = "`\{n}`"
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" false) (mem "Loc" false) (mem "Pat" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "get" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "filterList" false) (mem "joinWith" false) (mem "listLen" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factScopes" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "ArgRole" true) (mem "Owner" true) (mem "SelfCall" true) (mem "selfCalls" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "declLocList" false) (mem "mentionsVar" false) (mem "ruleNameThreadedInvariant" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameThreadedInvariant")) (fa "summary" (ELit (LString "a self-recursive function passes two or more of its parameters through every self-call unchanged: close over them in a where-local `go`"))) (fa "doc" (ELit (LString "A top-level function that calls itself with the same two or more parameters, in the same positions, in every self-call carries those parameters through the whole recursion for nothing. A local `go` in a `where` closes over them, so the recursion names only what changes. The rule reads each function as a group of clauses: a position counts when every full-arity self-call of every clause that makes one passes that clause's own parameter there, unchanged. One invariant parameter is not reported, nor is a `go` that already closes over its invariants, a partial application, mutual recursion, or a loop local to a `let` or `where`.\n\nBefore:\n  extractFold bare heads acc (x :: xs) = extractFold bare heads (step bare heads acc x) xs\n  extractFold _ _ acc [] = acc\nAfter:\n  extractFold bare heads acc0 xs0 = go acc0 xs0\n    where\n      go acc [] = acc\n      go acc (x :: xs) = go (step bare heads acc x) xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "SuggestOnly")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleThreadedInvariant")) (EVar "None")))
(DTypeSig false "ruleThreadedInvariant" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleThreadedInvariant" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "scopes") (EApp (EVar "factScopes") (EVar "facts"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "functionFindings") (EVar "scopes"))) (EApp (EVar "functionGroups") (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))))
(DData Private "Group" () ((variant "Group" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))) ())
(DTypeSig false "functionGroups" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "Group"))))
(DFunDef false "functionGroups" ((PVar "dls")) (EApp (EApp (EApp (EVar "foldRight") (EVar "joinClause")) (EListLit)) (EApp (EApp (EVar "flatMap") (EVar "clauseOf")) (EVar "dls"))))
(DTypeSig false "clauseOf" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clauseOf" ((PTuple (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") PWild PWild) (PVar "loc"))) (EListLit (ETuple (EVar "n") (EVar "loc") (ETuple (EVar "ps") (EVar "body")))))
(DFunDef false "clauseOf" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "clauseOf") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "clauseOf" (PWild) (EListLit))
(DTypeSig false "joinClause" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "Group")) (TyApp (TyCon "List") (TyCon "Group")))))
(DFunDef false "joinClause" ((PTuple (PVar "n") (PVar "loc") (PVar "c")) (PCons (PCon "Group" (PVar "m") PWild (PVar "cs")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EBinOp "::" (EApp (EApp (EApp (EVar "Group") (EVar "n")) (EVar "loc")) (EBinOp "::" (EVar "c") (EVar "cs"))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "joinClause" ((PTuple (PVar "n") (PVar "loc") (PVar "c")) (PVar "groups")) (EBinOp "::" (EApp (EApp (EApp (EVar "Group") (EVar "n")) (EVar "loc")) (EListLit (EVar "c"))) (EVar "groups")))
(DData Private "Threaded" () ((variant "Threaded" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DTypeSig false "functionFindings" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Group") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "functionFindings" ((PVar "scopes") (PCon "Group" (PVar "name") (PVar "loc") (PVar "clauses"))) (EMatch (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "clauseThreaded") (EVar "scopes")) (EVar "name"))) (EVar "clauses")) (arm (PList) () (EListLit)) (arm (PAs "ts" (PCons (PCon "Threaded" (PVar "ps") (PVar "first")) PWild)) () (EBlock (DoLet false false (PVar "shared") (EApp (EApp (EVar "filterList") (EApp (EVar "inAll") (EVar "ts"))) (EVar "first"))) (DoExpr (EIf (EBinOp ">=" (EApp (EVar "listLen") (EVar "shared")) (ELit (LInt 2))) (EListLit (EApp (EApp (EApp (EVar "report") (EVar "name")) (EVar "loc")) (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EVar "paramName") (EVar "ps")) (EVar "i")))) (EVar "shared")))) (EListLit)))))))
(DTypeSig false "clauseThreaded" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Threaded"))))))
(DFunDef false "clauseThreaded" ((PVar "scopes") (PVar "name") (PTuple (PVar "ps") (PVar "body"))) (EIf (EBinOp "||" (EBinOp "<" (EApp (EVar "listLen") (EVar "ps")) (ELit (LInt 2))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "name")) (EVar "body")))) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "selfCalls") (EVar "scopes")) (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "calls") () (EListLit (EApp (EApp (EVar "Threaded") (EVar "ps")) (EApp (EApp (EVar "filterList") (EApp (EVar "unchangedIn") (EVar "calls"))) (ERangeList (ELit (LInt 0)) (EBinOp "-" (EApp (EVar "listLen") (EVar "ps")) (ELit (LInt 1))) true)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "inAll" (TyFun (TyApp (TyCon "List") (TyCon "Threaded")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "inAll" ((PVar "ts") (PVar "i")) (EApp (EApp (EVar "allList") (ELam ((PVar "t")) (EApp (EApp (EVar "hasPosition") (EVar "i")) (EVar "t")))) (EVar "ts")))
(DTypeSig false "hasPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Threaded") (TyCon "Bool"))))
(DFunDef false "hasPosition" ((PVar "i") (PCon "Threaded" PWild (PVar "positions"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "i")))) (EVar "positions")))
(DTypeSig false "unchangedIn" (TyFun (TyApp (TyCon "List") (TyCon "SelfCall")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "unchangedIn" ((PVar "calls") (PVar "i")) (EApp (EApp (EVar "allList") (EApp (EVar "callKeeps") (EVar "i"))) (EVar "calls")))
(DTypeSig false "callKeeps" (TyFun (TyCon "Int") (TyFun (TyCon "SelfCall") (TyCon "Bool"))))
(DFunDef false "callKeeps" ((PVar "i") (PCon "SelfCall" PWild PWild (PVar "roles"))) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "roles")) (arm (PCon "Some" (PCon "Unchanged" (PVar "j"))) () (EBinOp "==" (EVar "j") (EVar "i"))) (arm PWild () (EVar "False"))))
(DTypeSig false "paramName" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "paramName" ((PVar "ps") (PVar "i")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "ps")) (arm (PCon "Some" (PCon "PVar" (PVar "n") PWild PWild)) () (EVar "n")) (arm (PCon "Some" (PCon "PAs" (PVar "n") PWild PWild PWild)) () (EVar "n")) (arm PWild () (ELit (LString "_")))))
(DTypeSig false "report" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Finding")))))
(DFunDef false "report" ((PVar "name") (PVar "loc") (PVar "names")) (EBlock (DoLet false false (PVar "listed") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "quoted")) (EVar "names")))) (DoExpr (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameThreadedInvariant")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` passes "))) (EApp (EVar "display") (EVar "listed"))) (ELit (LString " through every self-call unchanged: close over them in a where-local `go`")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))))
(DTypeSig false "quoted" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoted" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`"))))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" false) (mem "Loc" false) (mem "Pat" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "get" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "filterList" false) (mem "joinWith" false) (mem "listLen" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factScopes" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "ArgRole" true) (mem "Owner" true) (mem "SelfCall" true) (mem "selfCalls" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "declLocList" false) (mem "mentionsVar" false) (mem "ruleNameThreadedInvariant" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameThreadedInvariant")) (fa "summary" (ELit (LString "a self-recursive function passes two or more of its parameters through every self-call unchanged: close over them in a where-local `go`"))) (fa "doc" (ELit (LString "A top-level function that calls itself with the same two or more parameters, in the same positions, in every self-call carries those parameters through the whole recursion for nothing. A local `go` in a `where` closes over them, so the recursion names only what changes. The rule reads each function as a group of clauses: a position counts when every full-arity self-call of every clause that makes one passes that clause's own parameter there, unchanged. One invariant parameter is not reported, nor is a `go` that already closes over its invariants, a partial application, mutual recursion, or a loop local to a `let` or `where`.\n\nBefore:\n  extractFold bare heads acc (x :: xs) = extractFold bare heads (step bare heads acc x) xs\n  extractFold _ _ acc [] = acc\nAfter:\n  extractFold bare heads acc0 xs0 = go acc0 xs0\n    where\n      go acc [] = acc\n      go acc (x :: xs) = go (step bare heads acc x) xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "SuggestOnly")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleThreadedInvariant")) (EVar "None")))
(DTypeSig false "ruleThreadedInvariant" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleThreadedInvariant" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "scopes") (EApp (EVar "factScopes") (EVar "facts"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "functionFindings") (EVar "scopes"))) (EApp (EVar "functionGroups") (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))))
(DData Private "Group" () ((variant "Group" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))) ())
(DTypeSig false "functionGroups" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "Group"))))
(DFunDef false "functionGroups" ((PVar "dls")) (EApp (EApp (EApp (EMethodRef "foldRight") (EVar "joinClause")) (EListLit)) (EApp (EApp (EDictApp "flatMap") (EVar "clauseOf")) (EVar "dls"))))
(DTypeSig false "clauseOf" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clauseOf" ((PTuple (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") PWild PWild) (PVar "loc"))) (EListLit (ETuple (EVar "n") (EVar "loc") (ETuple (EVar "ps") (EVar "body")))))
(DFunDef false "clauseOf" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "clauseOf") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "clauseOf" (PWild) (EListLit))
(DTypeSig false "joinClause" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "Group")) (TyApp (TyCon "List") (TyCon "Group")))))
(DFunDef false "joinClause" ((PTuple (PVar "n") (PVar "loc") (PVar "c")) (PCons (PCon "Group" (PVar "m") PWild (PVar "cs")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EBinOp "::" (EApp (EApp (EApp (EVar "Group") (EVar "n")) (EVar "loc")) (EBinOp "::" (EVar "c") (EVar "cs"))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "joinClause" ((PTuple (PVar "n") (PVar "loc") (PVar "c")) (PVar "groups")) (EBinOp "::" (EApp (EApp (EApp (EVar "Group") (EVar "n")) (EVar "loc")) (EListLit (EVar "c"))) (EVar "groups")))
(DData Private "Threaded" () ((variant "Threaded" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DTypeSig false "functionFindings" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Group") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "functionFindings" ((PVar "scopes") (PCon "Group" (PVar "name") (PVar "loc") (PVar "clauses"))) (EMatch (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "clauseThreaded") (EVar "scopes")) (EVar "name"))) (EVar "clauses")) (arm (PList) () (EListLit)) (arm (PAs "ts" (PCons (PCon "Threaded" (PVar "ps") (PVar "first")) PWild)) () (EBlock (DoLet false false (PVar "shared") (EApp (EApp (EVar "filterList") (EApp (EVar "inAll") (EVar "ts"))) (EVar "first"))) (DoExpr (EIf (EBinOp ">=" (EApp (EVar "listLen") (EVar "shared")) (ELit (LInt 2))) (EListLit (EApp (EApp (EApp (EVar "report") (EVar "name")) (EVar "loc")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EVar "paramName") (EVar "ps")) (EVar "i")))) (EVar "shared")))) (EListLit)))))))
(DTypeSig false "clauseThreaded" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Threaded"))))))
(DFunDef false "clauseThreaded" ((PVar "scopes") (PVar "name") (PTuple (PVar "ps") (PVar "body"))) (EIf (EBinOp "||" (EBinOp "<" (EApp (EVar "listLen") (EVar "ps")) (ELit (LInt 2))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "name")) (EVar "body")))) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "selfCalls") (EVar "scopes")) (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "calls") () (EListLit (EApp (EApp (EVar "Threaded") (EVar "ps")) (EApp (EApp (EVar "filterList") (EApp (EVar "unchangedIn") (EVar "calls"))) (ERangeList (ELit (LInt 0)) (EBinOp "-" (EApp (EVar "listLen") (EVar "ps")) (ELit (LInt 1))) true)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "inAll" (TyFun (TyApp (TyCon "List") (TyCon "Threaded")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "inAll" ((PVar "ts") (PVar "i")) (EApp (EApp (EVar "allList") (ELam ((PVar "t")) (EApp (EApp (EVar "hasPosition") (EVar "i")) (EVar "t")))) (EVar "ts")))
(DTypeSig false "hasPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Threaded") (TyCon "Bool"))))
(DFunDef false "hasPosition" ((PVar "i") (PCon "Threaded" PWild (PVar "positions"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "i")))) (EVar "positions")))
(DTypeSig false "unchangedIn" (TyFun (TyApp (TyCon "List") (TyCon "SelfCall")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "unchangedIn" ((PVar "calls") (PVar "i")) (EApp (EApp (EVar "allList") (EApp (EVar "callKeeps") (EVar "i"))) (EVar "calls")))
(DTypeSig false "callKeeps" (TyFun (TyCon "Int") (TyFun (TyCon "SelfCall") (TyCon "Bool"))))
(DFunDef false "callKeeps" ((PVar "i") (PCon "SelfCall" PWild PWild (PVar "roles"))) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "roles")) (arm (PCon "Some" (PCon "Unchanged" (PVar "j"))) () (EBinOp "==" (EVar "j") (EVar "i"))) (arm PWild () (EVar "False"))))
(DTypeSig false "paramName" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "paramName" ((PVar "ps") (PVar "i")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "ps")) (arm (PCon "Some" (PCon "PVar" (PVar "n") PWild PWild)) () (EVar "n")) (arm (PCon "Some" (PCon "PAs" (PVar "n") PWild PWild PWild)) () (EVar "n")) (arm PWild () (ELit (LString "_")))))
(DTypeSig false "report" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Finding")))))
(DFunDef false "report" ((PVar "name") (PVar "loc") (PVar "names")) (EBlock (DoLet false false (PVar "listed") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "quoted")) (EVar "names")))) (DoExpr (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameThreadedInvariant")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` passes "))) (EApp (EMethodRef "display") (EVar "listed"))) (ELit (LString " through every self-call unchanged: close over them in a where-local `go`")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))))
(DTypeSig false "quoted" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoted" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`"))))
