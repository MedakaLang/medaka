# META
source_lines=391
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-list-as-set: a `List` a loop grows and membership-tests on every step (`contains`, `elem`, `notElem`, `lookupAssoc`, `lookup`). Keep a `Set` or `Map` beside it, or build the set once.
--
-- The rule has no types, so it keys on shape.  A membership call is reported
-- when its container (the second argument, or the left operand of `|>`) is one
-- of these, resolved by the file's scope model rather than by name:
--
-- * a parameter of a self-recursive function, at a position that some
--   full-arity self-call, in any clause of the function, passes grown: `e :: p`,
--   `p ++ e`, `e ++ p`, or a name a `let` in that clause binds to one of those;
-- * the accumulator parameter of a fold lambda (the folds `lint_recursion`
--   knows) whose body returns the accumulator grown in a tail position.
--
-- Growth is what makes the test a loop cost: a container that only shrinks or
-- is passed on unchanged is not reported.  Not covered: a container held in a
-- `Ref`, a record field or a top-level table; a test or growth made by a helper
-- the loop calls, or through mutual recursion; a tuple accumulator; a hand-rolled
-- membership function or `any (== x) xs`; a `let` alias of an alias; a test or
-- prop body.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{
  Arm(..), Decl, DoStmt(..), Expr(..), Loc, Pat(..), orElseLoc
}
import frontend.ast_walk.{
  BodyOwner(..),
  DeclBody(..),
  ExprKind(..),
  childExprs,
  declBodies,
  stmtExprs,
}
import frontend.parser.{Positions(..)}
import list.{findMap, get, indexed}
import string.{contains}
import tools.lint_calls.{lastSegment}
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
}
import tools.lint_recursion.{
  Owner(..),
  SelfCall(..),
  foldAccIndex,
  letOwners,
  selfCalls,
  spineOf,
}
import tools.lint_scope.{FileScopes, binderOf}
import tools.lint_shared.{
  appSpineOf, firstLoc, ruleNameListAsSet, unwrapLoc, varSite
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameListAsSet,
      summary =
        "a `List` a loop grows and membership-tests on every step: each test walks the whole list. Keep a `Set` or `Map` beside it, or build the set once",
      doc =
        "A membership test on a `List` (`contains`, `elem`, `notElem`, `lookupAssoc`, `lookup`) walks the list. When a loop grows the list and tests it on every step, the loop does work quadratic in the number of steps. The rule reports a membership test whose container is a parameter that a self-call of the same function passes grown (`x :: seen`, `seen ++ xs`, `xs ++ seen`, or a `let` bound to one of those), and a test on the accumulator of a fold lambda that returns the accumulator grown. A container that is only passed on unchanged or shrinks is not reported, nor is one held in a `Ref`, a record field or a top-level table, nor a test made by a helper the loop calls. A partial application and a call to a different function (mutual recursion) are not self-calls.\n\nKeep the names in a `Set` (or the pairs in a `Map`) beside the list, or build the set once before the loop. A list whose length is small and fixed can carry a `-- lint-disable-next-line rule-list-as-set` with the bound as its reason.\n\nBefore:\n  go seen (x :: xs) = if contains x seen then go seen xs else go (x :: seen) xs\nAfter:\n  go seen (x :: xs) = if has x seen then go seen xs else go (insert x seen) xs  -- with `seen : Set String`",
      category = Perf,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [NeedsScopes],
    }
    ruleListAsSet
    None

-- A file that names no membership function has nothing to report, so its
-- bodies are not walked.
ruleListAsSet : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleListAsSet _ _ facts _ decls
  | any (w => contains w facts.ffSrc) mentions =
    let scopes = factScopes facts
    [
      OnDecl (declFindings scopes decls),
      OnExpr [KLetGroup] (localFindings scopes),
      OnExpr [KApp] (foldFindings scopes),
    ]
  | otherwise = []

mentions : List String
mentions = ["contains", "elem", "lookup"]

-- ── membership tests ─────────────────────────────────────────────────────────

-- A membership call: its span, the callee and the container argument.
data Probe = Probe (Option Loc) String Expr

-- Every membership call in `e`, nested bodies included: a container resolves
-- to its own binder, so a test inside a nested loop is matched to the loop
-- whose parameter it tests.
probesIn : Option Loc -> Expr -> List Probe
probesIn _ (ELoc l inner) = probesIn (Some l) inner
probesIn loc e = probeHere loc e ++ flatMap (probesIn loc) (childExprs e)

probeHere : Option Loc -> Expr -> List Probe
probeHere loc (EApp f a) = match spineOf f [a]
  (hd, args) => callProbe loc hd args
probeHere loc (EBinOp "|>" l r _) = match spineOf r []
  (hd, args) => callProbe loc hd (args ++ [l])
probeHere _ _ = []

callProbe : Option Loc -> Expr -> List Expr -> List Probe
callProbe loc hd args = match (unwrapLoc hd, args)
  (EVar n, [_, c]) =>
    if isMembership (lastSegment n) then
      [Probe (orElseLoc (firstLoc hd) loc) (lastSegment n) c]
    else
      []
  _ => []

isMembership : String -> Bool
isMembership n =
  n == "contains"
    || n == "elem"
    || n == "notElem"
    || n == "lookupAssoc"
    || n == "lookup"

-- A parameter bound as a whole: its name and the span of its name token.
data Param = Param String Loc

wholeParam : Pat -> Option Param
wholeParam (PVar n l _) = Some (Param n l)
wholeParam (PAs n l _ _) = Some (Param n l)
wholeParam _ = None

-- Whether `e` is a use of the parameter itself, as the scope model resolves it.
isParam : FileScopes -> Param -> Expr -> Bool
isParam scopes (Param n l) e = match varSite e
  None => False
  Some site => match binderOf scopes site
    Some b => b.binderName == n && b.binderSpan == l
    None => False

-- The membership calls in `body` whose container is a whole parameter, with
-- the parameter's position.
paramProbes : FileScopes -> List Pat -> Expr -> List (Probe, Int)
paramProbes scopes ps body = match probesIn None body
  [] => []
  probes => flatMap (probeParam scopes ps) probes

probeParam : FileScopes -> List Pat -> Probe -> List (Probe, Int)
probeParam scopes ps (probe@(Probe _ _ c)) =
  match findMap (atParam scopes c) (indexed ps)
    Some j => [(probe, j)]
    None => []

atParam : FileScopes -> Expr -> (Int, Pat) -> Option Int
atParam scopes c (j, p) = match wholeParam p
  Some param => if isParam scopes param c then Some j else None
  None => None

-- ── growth ───────────────────────────────────────────────────────────────────

-- Whether `e` is the parameter grown by `::` or `++`, or a name a `let` of the
-- clause (`lets`, by binder span) binds to such an expression.
grows : FileScopes -> List (Loc, Expr) -> Param -> Expr -> Bool
grows scopes lets param e = match unwrapLoc e
  EVar _ => match aliasOf scopes lets e
    Some rhs => grownDirect scopes param rhs
    None => False
  _ => grownDirect scopes param e

grownDirect : FileScopes -> Param -> Expr -> Bool
grownDirect scopes param e = match unwrapLoc e
  EBinOp "::" _ t _ => isParam scopes param t || grownDirect scopes param t
  EBinOp "++" a b _ =>
    isParam scopes param a
      || isParam scopes param b
      || grownDirect scopes param a
      || grownDirect scopes param b
  EIf _ t f => grownDirect scopes param t || grownDirect scopes param f
  _ => False

aliasOf : FileScopes -> List (Loc, Expr) -> Expr -> Option Expr
aliasOf scopes lets e = match varSite e
  None => None
  Some site => match binderOf scopes site
    Some b =>
      findMap ((l, rhs) => if l == b.binderSpan then Some rhs else None) lets
    None => None

-- The `let x = rhs` bindings of a body, by the span of `x`.
letsIn : Expr -> List (Loc, Expr)
letsIn e = match unwrapLoc e
  ELet _ _ (PVar _ l _) rhs body => (l, rhs) :: letsIn rhs ++ letsIn body
  EBlock stmts => flatMap stmtLets stmts
  e2 => flatMap letsIn (childExprs e2)

stmtLets : DoStmt -> List (Loc, Expr)
stmtLets (DoLet _ _ (PVar _ l _) rhs _) = (l, rhs) :: letsIn rhs
stmtLets s = flatMap letsIn (stmtExprs s)

-- The parameter positions that some self-call of the function passes grown.
-- `clauses` are all the clauses of the function, each with its parameters.
grownPositions : FileScopes ->
  String ->
  Option Loc ->
  List (List Pat, Expr) ->
  List Int
grownPositions scopes name site clauses =
  flatMap (clauseGrown scopes name site) clauses

clauseGrown : FileScopes -> String -> Option Loc -> (List Pat, Expr) -> List Int
clauseGrown scopes name site (ps, body) =
  match selfCalls scopes (Owner name ps site) body
    [] => []
    calls =>
      let lets = letsIn body
      flatMap (callGrown scopes lets ps) calls

callGrown : FileScopes -> List (Loc, Expr) -> List Pat -> SelfCall -> List Int
callGrown scopes lets ps (SelfCall _ call _) =
  flatMap (argGrown scopes lets ps) (indexed (argsOf call))

argGrown : FileScopes -> List (Loc, Expr) -> List Pat -> (Int, Expr) -> List Int
argGrown scopes lets ps (j, a) = match get j ps
  Some p => match wholeParam p
    Some param => if grows scopes lets param a then [j] else []
    None => []
  None => []

argsOf : Expr -> List Expr
argsOf e = match appSpineOf e
  (_, args) => args

-- ── loops ────────────────────────────────────────────────────────────────────

-- One clause of a top-level function.  The growth is read over every clause of
-- the function, since a scope walk tests in one clause and grows in another.
-- Test and prop bodies run over fixed data and are not checked.
declFindings : FileScopes -> List Decl -> Ctx -> Decl -> List Finding
declFindings scopes decls ctx d =
  flatMap (bodyFindings scopes decls ctx.ctxSpan) (declBodies d)

bodyFindings : FileScopes -> List Decl -> Option Loc -> DeclBody -> List Finding
bodyFindings scopes decls fallback (DeclBody (OwnerClause name ps) body) =
  match paramProbes scopes ps body
    [] => []
    probes =>
      reportGrown
        fallback
        (grownPositions scopes name None (clausesNamed decls name))
        probes
bodyFindings _ _ _ _ = []

clausesNamed : List Decl -> String -> List (List Pat, Expr)
clausesNamed decls name =
  flatMap (d => flatMap (clauseNamed name) (declBodies d)) decls

clauseNamed : String -> DeclBody -> List (List Pat, Expr)
clauseNamed name (DeclBody (OwnerClause n ps) body) =
  if n == name then [(ps, body)] else []
clauseNamed _ _ = []

-- The `where`/`let` loops of one group, each read over all of its clauses.
localFindings : FileScopes -> Ctx -> Expr -> List Finding
localFindings scopes ctx e
  | ctx.ctxInTest = []
  | otherwise = match letOwners e
    [] => []
    owners => flatMap (ownerFindings scopes ctx.ctxSpan owners) owners

ownerFindings : FileScopes ->
  Option Loc ->
  List (Owner, Expr) ->
  (Owner, Expr) ->
  List Finding
ownerFindings scopes fallback owners (Owner name ps site, body) =
  match paramProbes scopes ps body
    [] => []
    probes =>
      reportGrown
        fallback
        (grownPositions scopes name site (sameOwner name site owners))
        probes

sameOwner : String -> Option Loc -> List (Owner, Expr) -> List (List Pat, Expr)
sameOwner name site owners = flatMap (o => ownerClause name site o) owners

ownerClause : String -> Option Loc -> (Owner, Expr) -> List (List Pat, Expr)
ownerClause name site (Owner n ps s, body) =
  if n == name && s == site then [(ps, body)] else []

reportGrown : Option Loc -> List Int -> List (Probe, Int) -> List Finding
reportGrown _ [] _ = []
reportGrown fallback grown probes =
  flatMap
    ((probe, j) =>
      if any (== j) grown then [probeFinding fallback probe] else [])
    probes

-- ── fold lambdas ─────────────────────────────────────────────────────────────

-- A fold call is read where its lambda is the last argument given, so the later
-- partial prefixes of the same call are not read again.
foldFindings : FileScopes -> Ctx -> Expr -> List Finding
foldFindings scopes ctx e
  | ctx.ctxInTest = []
  | otherwise = match e
    EApp _ a => match unwrapLoc a
      ELam ps body => match foldAccOf e ps
        Some acc =>
          if tailGrows scopes acc body then
            map
              (probeFinding (orElseLoc (firstLoc e) ctx.ctxSpan))
              (accProbes scopes acc body)
          else
            []
        None => []
      _ => []
    _ => []

-- The accumulator parameter of the lambda when the call's head is a fold.
foldAccOf : Expr -> List Pat -> Option Param
foldAccOf e ps = match spineOf e []
  (hd, _) => match unwrapLoc hd
    EVar n => match foldAccIndex (lastSegment n)
      Some k => match get k ps
        Some p => wholeParam p
        None => None
      None => None
    _ => None

accProbes : FileScopes -> Param -> Expr -> List Probe
accProbes scopes acc body =
  filter ((Probe _ _ c) => isParam scopes acc c) (probesIn None body)

-- Whether some tail position of `e` returns the accumulator grown.
tailGrows : FileScopes -> Param -> Expr -> Bool
tailGrows scopes acc e = match unwrapLoc e
  EBinOp "::" _ _ _ => grownDirect scopes acc e
  EBinOp "++" _ _ _ => grownDirect scopes acc e
  EIf _ t f => tailGrows scopes acc t || tailGrows scopes acc f
  EMatch _ arms => any ((Arm _ _ b) => tailGrows scopes acc b) arms
  ELet _ _ _ _ body => tailGrows scopes acc body
  ELetGroup _ body => tailGrows scopes acc body
  _ => False

-- ── findings ─────────────────────────────────────────────────────────────────

probeFinding : Option Loc -> Probe -> Finding
probeFinding fallback (Probe loc callee c) = Finding {
  rule = ruleNameListAsSet,
  message = message callee (containerName c),
  severity = SevWarning,
  loc = orElseLoc loc fallback,
  fix = None,
}

containerName : Expr -> String
containerName c = match unwrapLoc c
  EVar n => n
  _ => "the list"

message : String -> String -> String
message callee v =
  "`\{callee}` on `\{v}`, which this loop grows on every step, walks the whole list each time, so the loop is quadratic. \{fixFor callee}"

fixFor : String -> String
fixFor "lookupAssoc" = lookupFix
fixFor "lookup" = lookupFix
fixFor _ =
  "Keep the elements in a `Set` beside the list (`has`, `insert`), or build the set once before the loop"

lookupFix : String
lookupFix =
  "Keep the pairs in a `Map` beside the list (`get`, `insert`), or build the map once before the loop"
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" false) (mem "DoStmt" true) (mem "Expr" true) (mem "Loc" false) (mem "Pat" true) (mem "orElseLoc" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "ExprKind" true) (mem "childExprs" false) (mem "declBodies" false) (mem "stmtExprs" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "get" false) (mem "indexed" false))))
(DUse false (UseGroup ("string") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "lastSegment" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "factScopes" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "Owner" true) (mem "SelfCall" true) (mem "foldAccIndex" false) (mem "letOwners" false) (mem "selfCalls" false) (mem "spineOf" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false) (mem "binderOf" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "appSpineOf" false) (mem "firstLoc" false) (mem "ruleNameListAsSet" false) (mem "unwrapLoc" false) (mem "varSite" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameListAsSet")) (fa "summary" (ELit (LString "a `List` a loop grows and membership-tests on every step: each test walks the whole list. Keep a `Set` or `Map` beside it, or build the set once"))) (fa "doc" (ELit (LString "A membership test on a `List` (`contains`, `elem`, `notElem`, `lookupAssoc`, `lookup`) walks the list. When a loop grows the list and tests it on every step, the loop does work quadratic in the number of steps. The rule reports a membership test whose container is a parameter that a self-call of the same function passes grown (`x :: seen`, `seen ++ xs`, `xs ++ seen`, or a `let` bound to one of those), and a test on the accumulator of a fold lambda that returns the accumulator grown. A container that is only passed on unchanged or shrinks is not reported, nor is one held in a `Ref`, a record field or a top-level table, nor a test made by a helper the loop calls. A partial application and a call to a different function (mutual recursion) are not self-calls.\n\nKeep the names in a `Set` (or the pairs in a `Map`) beside the list, or build the set once before the loop. A list whose length is small and fixed can carry a `-- lint-disable-next-line rule-list-as-set` with the bound as its reason.\n\nBefore:\n  go seen (x :: xs) = if contains x seen then go seen xs else go (x :: seen) xs\nAfter:\n  go seen (x :: xs) = if has x seen then go seen xs else go (insert x seen) xs  -- with `seen : Set String`"))) (fa "category" (EVar "Perf")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleListAsSet")) (EVar "None")))
(DTypeSig false "ruleListAsSet" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleListAsSet" (PWild PWild (PVar "facts") PWild (PVar "decls")) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "w")) (EApp (EApp (EVar "contains") (EVar "w")) (EFieldAccess (EVar "facts") "ffSrc")))) (EVar "mentions")) (EBlock (DoLet false false (PVar "scopes") (EApp (EVar "factScopes") (EVar "facts"))) (DoExpr (EListLit (EApp (EVar "OnDecl") (EApp (EApp (EVar "declFindings") (EVar "scopes")) (EVar "decls"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KLetGroup"))) (EApp (EVar "localFindings") (EVar "scopes"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KApp"))) (EApp (EVar "foldFindings") (EVar "scopes")))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mentions" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mentions" () (EListLit (ELit (LString "contains")) (ELit (LString "elem")) (ELit (LString "lookup"))))
(DData Private "Probe" () ((variant "Probe" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String") (TyCon "Expr")))) ())
(DTypeSig false "probesIn" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Probe")))))
(DFunDef false "probesIn" (PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EVar "probesIn") (EApp (EVar "Some") (EVar "l"))) (EVar "inner")))
(DFunDef false "probesIn" ((PVar "loc") (PVar "e")) (EBinOp "++" (EApp (EApp (EVar "probeHere") (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "flatMap") (EApp (EVar "probesIn") (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "probeHere" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Probe")))))
(DFunDef false "probeHere" ((PVar "loc") (PCon "EApp" (PVar "f") (PVar "a"))) (EMatch (EApp (EApp (EVar "spineOf") (EVar "f")) (EListLit (EVar "a"))) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EApp (EVar "callProbe") (EVar "loc")) (EVar "hd")) (EVar "args")))))
(DFunDef false "probeHere" ((PVar "loc") (PCon "EBinOp" (PLit (LString "|>")) (PVar "l") (PVar "r") PWild)) (EMatch (EApp (EApp (EVar "spineOf") (EVar "r")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EApp (EVar "callProbe") (EVar "loc")) (EVar "hd")) (EBinOp "++" (EVar "args") (EListLit (EVar "l")))))))
(DFunDef false "probeHere" (PWild PWild) (EListLit))
(DTypeSig false "callProbe" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Probe"))))))
(DFunDef false "callProbe" ((PVar "loc") (PVar "hd") (PVar "args")) (EMatch (ETuple (EApp (EVar "unwrapLoc") (EVar "hd")) (EVar "args")) (arm (PTuple (PCon "EVar" (PVar "n")) (PList PWild (PVar "c"))) () (EIf (EApp (EVar "isMembership") (EApp (EVar "lastSegment") (EVar "n"))) (EListLit (EApp (EApp (EApp (EVar "Probe") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "hd"))) (EVar "loc"))) (EApp (EVar "lastSegment") (EVar "n"))) (EVar "c"))) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig false "isMembership" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isMembership" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "contains"))) (EBinOp "==" (EVar "n") (ELit (LString "elem")))) (EBinOp "==" (EVar "n") (ELit (LString "notElem")))) (EBinOp "==" (EVar "n") (ELit (LString "lookupAssoc")))) (EBinOp "==" (EVar "n") (ELit (LString "lookup")))))
(DData Private "Param" () ((variant "Param" (ConPos (TyCon "String") (TyCon "Loc")))) ())
(DTypeSig false "wholeParam" (TyFun (TyCon "Pat") (TyApp (TyCon "Option") (TyCon "Param"))))
(DFunDef false "wholeParam" ((PCon "PVar" (PVar "n") (PVar "l") PWild)) (EApp (EVar "Some") (EApp (EApp (EVar "Param") (EVar "n")) (EVar "l"))))
(DFunDef false "wholeParam" ((PCon "PAs" (PVar "n") (PVar "l") PWild PWild)) (EApp (EVar "Some") (EApp (EApp (EVar "Param") (EVar "n")) (EVar "l"))))
(DFunDef false "wholeParam" (PWild) (EVar "None"))
(DTypeSig false "isParam" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "isParam" ((PVar "scopes") (PCon "Param" (PVar "n") (PVar "l")) (PVar "e")) (EMatch (EApp (EVar "varSite") (EVar "e")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "site")) () (EMatch (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "site")) (arm (PCon "Some" (PVar "b")) () (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "n")) (EBinOp "==" (EFieldAccess (EVar "b") "binderSpan") (EVar "l")))) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "paramProbes" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Probe") (TyCon "Int")))))))
(DFunDef false "paramProbes" ((PVar "scopes") (PVar "ps") (PVar "body")) (EMatch (EApp (EApp (EVar "probesIn") (EVar "None")) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "probes") () (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "probeParam") (EVar "scopes")) (EVar "ps"))) (EVar "probes")))))
(DTypeSig false "probeParam" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Probe") (TyApp (TyCon "List") (TyTuple (TyCon "Probe") (TyCon "Int")))))))
(DFunDef false "probeParam" ((PVar "scopes") (PVar "ps") (PAs "probe" (PCon "Probe" PWild PWild (PVar "c")))) (EMatch (EApp (EApp (EVar "findMap") (EApp (EApp (EVar "atParam") (EVar "scopes")) (EVar "c"))) (EApp (EVar "indexed") (EVar "ps"))) (arm (PCon "Some" (PVar "j")) () (EListLit (ETuple (EVar "probe") (EVar "j")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "atParam" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Expr") (TyFun (TyTuple (TyCon "Int") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "atParam" ((PVar "scopes") (PVar "c") (PTuple (PVar "j") (PVar "p"))) (EMatch (EApp (EVar "wholeParam") (EVar "p")) (arm (PCon "Some" (PVar "param")) () (EIf (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "c")) (EApp (EVar "Some") (EVar "j")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "grows" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool"))))))
(DFunDef false "grows" ((PVar "scopes") (PVar "lets") (PVar "param") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" PWild) () (EMatch (EApp (EApp (EApp (EVar "aliasOf") (EVar "scopes")) (EVar "lets")) (EVar "e")) (arm (PCon "Some" (PVar "rhs")) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "rhs"))) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "e")))))
(DTypeSig false "grownDirect" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "grownDirect" ((PVar "scopes") (PVar "param") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "::")) PWild (PVar "t") PWild) () (EBinOp "||" (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "t")) (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "t")))) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "a") (PVar "b") PWild) () (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "a")) (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "b"))) (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "a"))) (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "b")))) (arm (PCon "EIf" PWild (PVar "t") (PVar "f")) () (EBinOp "||" (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "t")) (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "f")))) (arm PWild () (EVar "False"))))
(DTypeSig false "aliasOf" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "aliasOf" ((PVar "scopes") (PVar "lets") (PVar "e")) (EMatch (EApp (EVar "varSite") (EVar "e")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "site")) () (EMatch (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "site")) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "findMap") (ELam ((PTuple (PVar "l") (PVar "rhs"))) (EIf (EBinOp "==" (EVar "l") (EFieldAccess (EVar "b") "binderSpan")) (EApp (EVar "Some") (EVar "rhs")) (EVar "None")))) (EVar "lets"))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "letsIn" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr")))))
(DFunDef false "letsIn" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELet" PWild PWild (PCon "PVar" PWild (PVar "l") PWild) (PVar "rhs") (PVar "body")) () (EBinOp "::" (ETuple (EVar "l") (EVar "rhs")) (EBinOp "++" (EApp (EVar "letsIn") (EVar "rhs")) (EApp (EVar "letsIn") (EVar "body"))))) (arm (PCon "EBlock" (PVar "stmts")) () (EApp (EApp (EVar "flatMap") (EVar "stmtLets")) (EVar "stmts"))) (arm (PVar "e2") () (EApp (EApp (EVar "flatMap") (EVar "letsIn")) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig false "stmtLets" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr")))))
(DFunDef false "stmtLets" ((PCon "DoLet" PWild PWild (PCon "PVar" PWild (PVar "l") PWild) (PVar "rhs") PWild)) (EBinOp "::" (ETuple (EVar "l") (EVar "rhs")) (EApp (EVar "letsIn") (EVar "rhs"))))
(DFunDef false "stmtLets" ((PVar "s")) (EApp (EApp (EVar "flatMap") (EVar "letsIn")) (EApp (EVar "stmtExprs") (EVar "s"))))
(DTypeSig false "grownPositions" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "grownPositions" ((PVar "scopes") (PVar "name") (PVar "site") (PVar "clauses")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "clauseGrown") (EVar "scopes")) (EVar "name")) (EVar "site"))) (EVar "clauses")))
(DTypeSig false "clauseGrown" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "clauseGrown" ((PVar "scopes") (PVar "name") (PVar "site") (PTuple (PVar "ps") (PVar "body"))) (EMatch (EApp (EApp (EApp (EVar "selfCalls") (EVar "scopes")) (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "site"))) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "calls") () (EBlock (DoLet false false (PVar "lets") (EApp (EVar "letsIn") (EVar "body"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "callGrown") (EVar "scopes")) (EVar "lets")) (EVar "ps"))) (EVar "calls")))))))
(DTypeSig false "callGrown" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "SelfCall") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "callGrown" ((PVar "scopes") (PVar "lets") (PVar "ps") (PCon "SelfCall" PWild (PVar "call") PWild)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "argGrown") (EVar "scopes")) (EVar "lets")) (EVar "ps"))) (EApp (EVar "indexed") (EApp (EVar "argsOf") (EVar "call")))))
(DTypeSig false "argGrown" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyTuple (TyCon "Int") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "argGrown" ((PVar "scopes") (PVar "lets") (PVar "ps") (PTuple (PVar "j") (PVar "a"))) (EMatch (EApp (EApp (EVar "get") (EVar "j")) (EVar "ps")) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EVar "wholeParam") (EVar "p")) (arm (PCon "Some" (PVar "param")) () (EIf (EApp (EApp (EApp (EApp (EVar "grows") (EVar "scopes")) (EVar "lets")) (EVar "param")) (EVar "a")) (EListLit (EVar "j")) (EListLit))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "argsOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "argsOf" ((PVar "e")) (EMatch (EApp (EVar "appSpineOf") (EVar "e")) (arm (PTuple PWild (PVar "args")) () (EVar "args"))))
(DTypeSig false "declFindings" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "declFindings" ((PVar "scopes") (PVar "decls") (PVar "ctx") (PVar "d")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "bodyFindings") (EVar "scopes")) (EVar "decls")) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig false "bodyFindings" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DeclBody") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "bodyFindings" ((PVar "scopes") (PVar "decls") (PVar "fallback") (PCon "DeclBody" (PCon "OwnerClause" (PVar "name") (PVar "ps")) (PVar "body"))) (EMatch (EApp (EApp (EApp (EVar "paramProbes") (EVar "scopes")) (EVar "ps")) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "probes") () (EApp (EApp (EApp (EVar "reportGrown") (EVar "fallback")) (EApp (EApp (EApp (EApp (EVar "grownPositions") (EVar "scopes")) (EVar "name")) (EVar "None")) (EApp (EApp (EVar "clausesNamed") (EVar "decls")) (EVar "name")))) (EVar "probes")))))
(DFunDef false "bodyFindings" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "clausesNamed" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesNamed" ((PVar "decls") (PVar "name")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "d")) (EApp (EApp (EVar "flatMap") (EApp (EVar "clauseNamed") (EVar "name"))) (EApp (EVar "declBodies") (EVar "d"))))) (EVar "decls")))
(DTypeSig false "clauseNamed" (TyFun (TyCon "String") (TyFun (TyCon "DeclBody") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clauseNamed" ((PVar "name") (PCon "DeclBody" (PCon "OwnerClause" (PVar "n") (PVar "ps")) (PVar "body"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EListLit (ETuple (EVar "ps") (EVar "body"))) (EListLit)))
(DFunDef false "clauseNamed" (PWild PWild) (EListLit))
(DTypeSig false "localFindings" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "localFindings" ((PVar "scopes") (PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "letOwners") (EVar "e")) (arm (PList) () (EListLit)) (arm (PVar "owners") () (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "ownerFindings") (EVar "scopes")) (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "owners"))) (EVar "owners")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ownerFindings" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Owner") (TyCon "Expr"))) (TyFun (TyTuple (TyCon "Owner") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ownerFindings" ((PVar "scopes") (PVar "fallback") (PVar "owners") (PTuple (PCon "Owner" (PVar "name") (PVar "ps") (PVar "site")) (PVar "body"))) (EMatch (EApp (EApp (EApp (EVar "paramProbes") (EVar "scopes")) (EVar "ps")) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "probes") () (EApp (EApp (EApp (EVar "reportGrown") (EVar "fallback")) (EApp (EApp (EApp (EApp (EVar "grownPositions") (EVar "scopes")) (EVar "name")) (EVar "site")) (EApp (EApp (EApp (EVar "sameOwner") (EVar "name")) (EVar "site")) (EVar "owners")))) (EVar "probes")))))
(DTypeSig false "sameOwner" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Owner") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "sameOwner" ((PVar "name") (PVar "site") (PVar "owners")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "o")) (EApp (EApp (EApp (EVar "ownerClause") (EVar "name")) (EVar "site")) (EVar "o")))) (EVar "owners")))
(DTypeSig false "ownerClause" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "Owner") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "ownerClause" ((PVar "name") (PVar "site") (PTuple (PCon "Owner" (PVar "n") (PVar "ps") (PVar "s")) (PVar "body"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "==" (EVar "s") (EVar "site"))) (EListLit (ETuple (EVar "ps") (EVar "body"))) (EListLit)))
(DTypeSig false "reportGrown" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Probe") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "reportGrown" (PWild (PList) PWild) (EListLit))
(DFunDef false "reportGrown" ((PVar "fallback") (PVar "grown") (PVar "probes")) (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "probe") (PVar "j"))) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "j")))) (EVar "grown")) (EListLit (EApp (EApp (EVar "probeFinding") (EVar "fallback")) (EVar "probe"))) (EListLit)))) (EVar "probes")))
(DTypeSig false "foldFindings" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "foldFindings" ((PVar "scopes") (PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EMatch (EVar "e") (arm (PCon "EApp" PWild (PVar "a")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "a")) (arm (PCon "ELam" (PVar "ps") (PVar "body")) () (EMatch (EApp (EApp (EVar "foldAccOf") (EVar "e")) (EVar "ps")) (arm (PCon "Some" (PVar "acc")) () (EIf (EApp (EApp (EApp (EVar "tailGrows") (EVar "scopes")) (EVar "acc")) (EVar "body")) (EApp (EApp (EVar "map") (EApp (EVar "probeFinding") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "e"))) (EFieldAccess (EVar "ctx") "ctxSpan")))) (EApp (EApp (EApp (EVar "accProbes") (EVar "scopes")) (EVar "acc")) (EVar "body"))) (EListLit))) (arm (PCon "None") () (EListLit)))) (arm PWild () (EListLit)))) (arm PWild () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldAccOf" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Param")))))
(DFunDef false "foldAccOf" ((PVar "e") (PVar "ps")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") PWild) () (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "n")) () (EMatch (EApp (EVar "foldAccIndex") (EApp (EVar "lastSegment") (EVar "n"))) (arm (PCon "Some" (PVar "k")) () (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "ps")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "wholeParam") (EVar "p"))) (arm (PCon "None") () (EVar "None")))) (arm (PCon "None") () (EVar "None")))) (arm PWild () (EVar "None"))))))
(DTypeSig false "accProbes" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Probe"))))))
(DFunDef false "accProbes" ((PVar "scopes") (PVar "acc") (PVar "body")) (EApp (EApp (EVar "filter") (ELam ((PCon "Probe" PWild PWild (PVar "c"))) (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "acc")) (EVar "c")))) (EApp (EApp (EVar "probesIn") (EVar "None")) (EVar "body"))))
(DTypeSig false "tailGrows" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "tailGrows" ((PVar "scopes") (PVar "acc") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "::")) PWild PWild PWild) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "acc")) (EVar "e"))) (arm (PCon "EBinOp" (PLit (LString "++")) PWild PWild PWild) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "acc")) (EVar "e"))) (arm (PCon "EIf" PWild (PVar "t") (PVar "f")) () (EBinOp "||" (EApp (EApp (EApp (EVar "tailGrows") (EVar "scopes")) (EVar "acc")) (EVar "t")) (EApp (EApp (EApp (EVar "tailGrows") (EVar "scopes")) (EVar "acc")) (EVar "f")))) (arm (PCon "EMatch" PWild (PVar "arms")) () (EApp (EApp (EVar "any") (ELam ((PCon "Arm" PWild PWild (PVar "b"))) (EApp (EApp (EApp (EVar "tailGrows") (EVar "scopes")) (EVar "acc")) (EVar "b")))) (EVar "arms"))) (arm (PCon "ELet" PWild PWild PWild PWild (PVar "body")) () (EApp (EApp (EApp (EVar "tailGrows") (EVar "scopes")) (EVar "acc")) (EVar "body"))) (arm (PCon "ELetGroup" PWild (PVar "body")) () (EApp (EApp (EApp (EVar "tailGrows") (EVar "scopes")) (EVar "acc")) (EVar "body"))) (arm PWild () (EVar "False"))))
(DTypeSig false "probeFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Probe") (TyCon "Finding"))))
(DFunDef false "probeFinding" ((PVar "fallback") (PCon "Probe" (PVar "loc") (PVar "callee") (PVar "c"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameListAsSet")) (fa "message" (EApp (EApp (EVar "message") (EVar "callee")) (EApp (EVar "containerName") (EVar "c")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "fallback"))) (fa "fix" (EVar "None")))))
(DTypeSig false "containerName" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "containerName" ((PVar "c")) (EMatch (EApp (EVar "unwrapLoc") (EVar "c")) (arm (PCon "EVar" (PVar "n")) () (EVar "n")) (arm PWild () (ELit (LString "the list")))))
(DTypeSig false "message" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "message" ((PVar "callee") (PVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "callee"))) (ELit (LString "` on `"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "`, which this loop grows on every step, walks the whole list each time, so the loop is quadratic. "))) (EApp (EVar "display") (EApp (EVar "fixFor") (EVar "callee")))) (ELit (LString ""))))
(DTypeSig false "fixFor" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "fixFor" ((PLit (LString "lookupAssoc"))) (EVar "lookupFix"))
(DFunDef false "fixFor" ((PLit (LString "lookup"))) (EVar "lookupFix"))
(DFunDef false "fixFor" (PWild) (ELit (LString "Keep the elements in a `Set` beside the list (`has`, `insert`), or build the set once before the loop")))
(DTypeSig false "lookupFix" (TyCon "String"))
(DFunDef false "lookupFix" () (ELit (LString "Keep the pairs in a `Map` beside the list (`get`, `insert`), or build the map once before the loop")))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" false) (mem "DoStmt" true) (mem "Expr" true) (mem "Loc" false) (mem "Pat" true) (mem "orElseLoc" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "ExprKind" true) (mem "childExprs" false) (mem "declBodies" false) (mem "stmtExprs" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "get" false) (mem "indexed" false))))
(DUse false (UseGroup ("string") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "lastSegment" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "factScopes" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "Owner" true) (mem "SelfCall" true) (mem "foldAccIndex" false) (mem "letOwners" false) (mem "selfCalls" false) (mem "spineOf" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false) (mem "binderOf" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "appSpineOf" false) (mem "firstLoc" false) (mem "ruleNameListAsSet" false) (mem "unwrapLoc" false) (mem "varSite" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameListAsSet")) (fa "summary" (ELit (LString "a `List` a loop grows and membership-tests on every step: each test walks the whole list. Keep a `Set` or `Map` beside it, or build the set once"))) (fa "doc" (ELit (LString "A membership test on a `List` (`contains`, `elem`, `notElem`, `lookupAssoc`, `lookup`) walks the list. When a loop grows the list and tests it on every step, the loop does work quadratic in the number of steps. The rule reports a membership test whose container is a parameter that a self-call of the same function passes grown (`x :: seen`, `seen ++ xs`, `xs ++ seen`, or a `let` bound to one of those), and a test on the accumulator of a fold lambda that returns the accumulator grown. A container that is only passed on unchanged or shrinks is not reported, nor is one held in a `Ref`, a record field or a top-level table, nor a test made by a helper the loop calls. A partial application and a call to a different function (mutual recursion) are not self-calls.\n\nKeep the names in a `Set` (or the pairs in a `Map`) beside the list, or build the set once before the loop. A list whose length is small and fixed can carry a `-- lint-disable-next-line rule-list-as-set` with the bound as its reason.\n\nBefore:\n  go seen (x :: xs) = if contains x seen then go seen xs else go (x :: seen) xs\nAfter:\n  go seen (x :: xs) = if has x seen then go seen xs else go (insert x seen) xs  -- with `seen : Set String`"))) (fa "category" (EVar "Perf")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleListAsSet")) (EVar "None")))
(DTypeSig false "ruleListAsSet" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleListAsSet" (PWild PWild (PVar "facts") PWild (PVar "decls")) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "w")) (EApp (EApp (EVar "contains") (EVar "w")) (EFieldAccess (EVar "facts") "ffSrc")))) (EVar "mentions")) (EBlock (DoLet false false (PVar "scopes") (EApp (EVar "factScopes") (EVar "facts"))) (DoExpr (EListLit (EApp (EVar "OnDecl") (EApp (EApp (EVar "declFindings") (EVar "scopes")) (EVar "decls"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KLetGroup"))) (EApp (EVar "localFindings") (EVar "scopes"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KApp"))) (EApp (EVar "foldFindings") (EVar "scopes")))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mentions" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mentions" () (EListLit (ELit (LString "contains")) (ELit (LString "elem")) (ELit (LString "lookup"))))
(DData Private "Probe" () ((variant "Probe" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String") (TyCon "Expr")))) ())
(DTypeSig false "probesIn" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Probe")))))
(DFunDef false "probesIn" (PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EVar "probesIn") (EApp (EVar "Some") (EVar "l"))) (EVar "inner")))
(DFunDef false "probesIn" ((PVar "loc") (PVar "e")) (EBinOp "++" (EApp (EApp (EVar "probeHere") (EVar "loc")) (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "probesIn") (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "probeHere" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Probe")))))
(DFunDef false "probeHere" ((PVar "loc") (PCon "EApp" (PVar "f") (PVar "a"))) (EMatch (EApp (EApp (EVar "spineOf") (EVar "f")) (EListLit (EVar "a"))) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EApp (EVar "callProbe") (EVar "loc")) (EVar "hd")) (EVar "args")))))
(DFunDef false "probeHere" ((PVar "loc") (PCon "EBinOp" (PLit (LString "|>")) (PVar "l") (PVar "r") PWild)) (EMatch (EApp (EApp (EVar "spineOf") (EVar "r")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EApp (EVar "callProbe") (EVar "loc")) (EVar "hd")) (EBinOp "++" (EVar "args") (EListLit (EVar "l")))))))
(DFunDef false "probeHere" (PWild PWild) (EListLit))
(DTypeSig false "callProbe" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Probe"))))))
(DFunDef false "callProbe" ((PVar "loc") (PVar "hd") (PVar "args")) (EMatch (ETuple (EApp (EVar "unwrapLoc") (EVar "hd")) (EVar "args")) (arm (PTuple (PCon "EVar" (PVar "n")) (PList PWild (PVar "c"))) () (EIf (EApp (EVar "isMembership") (EApp (EVar "lastSegment") (EVar "n"))) (EListLit (EApp (EApp (EApp (EVar "Probe") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "hd"))) (EVar "loc"))) (EApp (EVar "lastSegment") (EVar "n"))) (EVar "c"))) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig false "isMembership" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isMembership" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "contains"))) (EBinOp "==" (EVar "n") (ELit (LString "elem")))) (EBinOp "==" (EVar "n") (ELit (LString "notElem")))) (EBinOp "==" (EVar "n") (ELit (LString "lookupAssoc")))) (EBinOp "==" (EVar "n") (ELit (LString "lookup")))))
(DData Private "Param" () ((variant "Param" (ConPos (TyCon "String") (TyCon "Loc")))) ())
(DTypeSig false "wholeParam" (TyFun (TyCon "Pat") (TyApp (TyCon "Option") (TyCon "Param"))))
(DFunDef false "wholeParam" ((PCon "PVar" (PVar "n") (PVar "l") PWild)) (EApp (EVar "Some") (EApp (EApp (EVar "Param") (EVar "n")) (EVar "l"))))
(DFunDef false "wholeParam" ((PCon "PAs" (PVar "n") (PVar "l") PWild PWild)) (EApp (EVar "Some") (EApp (EApp (EVar "Param") (EVar "n")) (EVar "l"))))
(DFunDef false "wholeParam" (PWild) (EVar "None"))
(DTypeSig false "isParam" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "isParam" ((PVar "scopes") (PCon "Param" (PVar "n") (PVar "l")) (PVar "e")) (EMatch (EApp (EVar "varSite") (EVar "e")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "site")) () (EMatch (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "site")) (arm (PCon "Some" (PVar "b")) () (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "n")) (EBinOp "==" (EFieldAccess (EVar "b") "binderSpan") (EVar "l")))) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "paramProbes" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Probe") (TyCon "Int")))))))
(DFunDef false "paramProbes" ((PVar "scopes") (PVar "ps") (PVar "body")) (EMatch (EApp (EApp (EVar "probesIn") (EVar "None")) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "probes") () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "probeParam") (EVar "scopes")) (EVar "ps"))) (EVar "probes")))))
(DTypeSig false "probeParam" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Probe") (TyApp (TyCon "List") (TyTuple (TyCon "Probe") (TyCon "Int")))))))
(DFunDef false "probeParam" ((PVar "scopes") (PVar "ps") (PAs "probe" (PCon "Probe" PWild PWild (PVar "c")))) (EMatch (EApp (EApp (EVar "findMap") (EApp (EApp (EVar "atParam") (EVar "scopes")) (EVar "c"))) (EApp (EVar "indexed") (EVar "ps"))) (arm (PCon "Some" (PVar "j")) () (EListLit (ETuple (EVar "probe") (EVar "j")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "atParam" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Expr") (TyFun (TyTuple (TyCon "Int") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "atParam" ((PVar "scopes") (PVar "c") (PTuple (PVar "j") (PVar "p"))) (EMatch (EApp (EVar "wholeParam") (EVar "p")) (arm (PCon "Some" (PVar "param")) () (EIf (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "c")) (EApp (EVar "Some") (EVar "j")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "grows" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool"))))))
(DFunDef false "grows" ((PVar "scopes") (PVar "lets") (PVar "param") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" PWild) () (EMatch (EApp (EApp (EApp (EVar "aliasOf") (EVar "scopes")) (EVar "lets")) (EVar "e")) (arm (PCon "Some" (PVar "rhs")) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "rhs"))) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "e")))))
(DTypeSig false "grownDirect" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "grownDirect" ((PVar "scopes") (PVar "param") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "::")) PWild (PVar "t") PWild) () (EBinOp "||" (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "t")) (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "t")))) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "a") (PVar "b") PWild) () (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "a")) (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "b"))) (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "a"))) (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "b")))) (arm (PCon "EIf" PWild (PVar "t") (PVar "f")) () (EBinOp "||" (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "t")) (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "param")) (EVar "f")))) (arm PWild () (EVar "False"))))
(DTypeSig false "aliasOf" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "aliasOf" ((PVar "scopes") (PVar "lets") (PVar "e")) (EMatch (EApp (EVar "varSite") (EVar "e")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "site")) () (EMatch (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "site")) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "findMap") (ELam ((PTuple (PVar "l") (PVar "rhs"))) (EIf (EBinOp "==" (EVar "l") (EFieldAccess (EVar "b") "binderSpan")) (EApp (EVar "Some") (EVar "rhs")) (EVar "None")))) (EVar "lets"))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "letsIn" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr")))))
(DFunDef false "letsIn" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELet" PWild PWild (PCon "PVar" PWild (PVar "l") PWild) (PVar "rhs") (PVar "body")) () (EBinOp "::" (ETuple (EVar "l") (EVar "rhs")) (EBinOp "++" (EApp (EVar "letsIn") (EVar "rhs")) (EApp (EVar "letsIn") (EVar "body"))))) (arm (PCon "EBlock" (PVar "stmts")) () (EApp (EApp (EDictApp "flatMap") (EVar "stmtLets")) (EVar "stmts"))) (arm (PVar "e2") () (EApp (EApp (EDictApp "flatMap") (EVar "letsIn")) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig false "stmtLets" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr")))))
(DFunDef false "stmtLets" ((PCon "DoLet" PWild PWild (PCon "PVar" PWild (PVar "l") PWild) (PVar "rhs") PWild)) (EBinOp "::" (ETuple (EVar "l") (EVar "rhs")) (EApp (EVar "letsIn") (EVar "rhs"))))
(DFunDef false "stmtLets" ((PVar "s")) (EApp (EApp (EDictApp "flatMap") (EVar "letsIn")) (EApp (EVar "stmtExprs") (EVar "s"))))
(DTypeSig false "grownPositions" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "grownPositions" ((PVar "scopes") (PVar "name") (PVar "site") (PVar "clauses")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "clauseGrown") (EVar "scopes")) (EVar "name")) (EVar "site"))) (EVar "clauses")))
(DTypeSig false "clauseGrown" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "clauseGrown" ((PVar "scopes") (PVar "name") (PVar "site") (PTuple (PVar "ps") (PVar "body"))) (EMatch (EApp (EApp (EApp (EVar "selfCalls") (EVar "scopes")) (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "site"))) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "calls") () (EBlock (DoLet false false (PVar "lets") (EApp (EVar "letsIn") (EVar "body"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "callGrown") (EVar "scopes")) (EVar "lets")) (EVar "ps"))) (EVar "calls")))))))
(DTypeSig false "callGrown" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "SelfCall") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "callGrown" ((PVar "scopes") (PVar "lets") (PVar "ps") (PCon "SelfCall" PWild (PVar "call") PWild)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "argGrown") (EVar "scopes")) (EVar "lets")) (EVar "ps"))) (EApp (EVar "indexed") (EApp (EVar "argsOf") (EVar "call")))))
(DTypeSig false "argGrown" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyTuple (TyCon "Int") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "argGrown" ((PVar "scopes") (PVar "lets") (PVar "ps") (PTuple (PVar "j") (PVar "a"))) (EMatch (EApp (EApp (EVar "get") (EVar "j")) (EVar "ps")) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EVar "wholeParam") (EVar "p")) (arm (PCon "Some" (PVar "param")) () (EIf (EApp (EApp (EApp (EApp (EVar "grows") (EVar "scopes")) (EVar "lets")) (EVar "param")) (EVar "a")) (EListLit (EVar "j")) (EListLit))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "argsOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "argsOf" ((PVar "e")) (EMatch (EApp (EVar "appSpineOf") (EVar "e")) (arm (PTuple PWild (PVar "args")) () (EVar "args"))))
(DTypeSig false "declFindings" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "declFindings" ((PVar "scopes") (PVar "decls") (PVar "ctx") (PVar "d")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "bodyFindings") (EVar "scopes")) (EVar "decls")) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EVar "declBodies") (EVar "d"))))
(DTypeSig false "bodyFindings" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "DeclBody") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "bodyFindings" ((PVar "scopes") (PVar "decls") (PVar "fallback") (PCon "DeclBody" (PCon "OwnerClause" (PVar "name") (PVar "ps")) (PVar "body"))) (EMatch (EApp (EApp (EApp (EVar "paramProbes") (EVar "scopes")) (EVar "ps")) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "probes") () (EApp (EApp (EApp (EVar "reportGrown") (EVar "fallback")) (EApp (EApp (EApp (EApp (EVar "grownPositions") (EVar "scopes")) (EVar "name")) (EVar "None")) (EApp (EApp (EVar "clausesNamed") (EVar "decls")) (EVar "name")))) (EVar "probes")))))
(DFunDef false "bodyFindings" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "clausesNamed" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesNamed" ((PVar "decls") (PVar "name")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "d")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "clauseNamed") (EVar "name"))) (EApp (EVar "declBodies") (EVar "d"))))) (EVar "decls")))
(DTypeSig false "clauseNamed" (TyFun (TyCon "String") (TyFun (TyCon "DeclBody") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clauseNamed" ((PVar "name") (PCon "DeclBody" (PCon "OwnerClause" (PVar "n") (PVar "ps")) (PVar "body"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EListLit (ETuple (EVar "ps") (EVar "body"))) (EListLit)))
(DFunDef false "clauseNamed" (PWild PWild) (EListLit))
(DTypeSig false "localFindings" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "localFindings" ((PVar "scopes") (PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "letOwners") (EVar "e")) (arm (PList) () (EListLit)) (arm (PVar "owners") () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "ownerFindings") (EVar "scopes")) (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "owners"))) (EVar "owners")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ownerFindings" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Owner") (TyCon "Expr"))) (TyFun (TyTuple (TyCon "Owner") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ownerFindings" ((PVar "scopes") (PVar "fallback") (PVar "owners") (PTuple (PCon "Owner" (PVar "name") (PVar "ps") (PVar "site")) (PVar "body"))) (EMatch (EApp (EApp (EApp (EVar "paramProbes") (EVar "scopes")) (EVar "ps")) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "probes") () (EApp (EApp (EApp (EVar "reportGrown") (EVar "fallback")) (EApp (EApp (EApp (EApp (EVar "grownPositions") (EVar "scopes")) (EVar "name")) (EVar "site")) (EApp (EApp (EApp (EVar "sameOwner") (EVar "name")) (EVar "site")) (EVar "owners")))) (EVar "probes")))))
(DTypeSig false "sameOwner" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Owner") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "sameOwner" ((PVar "name") (PVar "site") (PVar "owners")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "o")) (EApp (EApp (EApp (EVar "ownerClause") (EVar "name")) (EVar "site")) (EVar "o")))) (EVar "owners")))
(DTypeSig false "ownerClause" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "Owner") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "ownerClause" ((PVar "name") (PVar "site") (PTuple (PCon "Owner" (PVar "n") (PVar "ps") (PVar "s")) (PVar "body"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "==" (EVar "s") (EVar "site"))) (EListLit (ETuple (EVar "ps") (EVar "body"))) (EListLit)))
(DTypeSig false "reportGrown" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Probe") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "reportGrown" (PWild (PList) PWild) (EListLit))
(DFunDef false "reportGrown" ((PVar "fallback") (PVar "grown") (PVar "probes")) (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "probe") (PVar "j"))) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "j")))) (EVar "grown")) (EListLit (EApp (EApp (EVar "probeFinding") (EVar "fallback")) (EVar "probe"))) (EListLit)))) (EVar "probes")))
(DTypeSig false "foldFindings" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "foldFindings" ((PVar "scopes") (PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EMatch (EVar "e") (arm (PCon "EApp" PWild (PVar "a")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "a")) (arm (PCon "ELam" (PVar "ps") (PVar "body")) () (EMatch (EApp (EApp (EVar "foldAccOf") (EVar "e")) (EVar "ps")) (arm (PCon "Some" (PVar "acc")) () (EIf (EApp (EApp (EApp (EVar "tailGrows") (EVar "scopes")) (EVar "acc")) (EVar "body")) (EApp (EApp (EMethodRef "map") (EApp (EVar "probeFinding") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "e"))) (EFieldAccess (EVar "ctx") "ctxSpan")))) (EApp (EApp (EApp (EVar "accProbes") (EVar "scopes")) (EVar "acc")) (EVar "body"))) (EListLit))) (arm (PCon "None") () (EListLit)))) (arm PWild () (EListLit)))) (arm PWild () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldAccOf" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Param")))))
(DFunDef false "foldAccOf" ((PVar "e") (PVar "ps")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") PWild) () (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "n")) () (EMatch (EApp (EVar "foldAccIndex") (EApp (EVar "lastSegment") (EVar "n"))) (arm (PCon "Some" (PVar "k")) () (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "ps")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "wholeParam") (EVar "p"))) (arm (PCon "None") () (EVar "None")))) (arm (PCon "None") () (EVar "None")))) (arm PWild () (EVar "None"))))))
(DTypeSig false "accProbes" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Probe"))))))
(DFunDef false "accProbes" ((PVar "scopes") (PVar "acc") (PVar "body")) (EApp (EApp (EMethodRef "filter") (ELam ((PCon "Probe" PWild PWild (PVar "c"))) (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "acc")) (EVar "c")))) (EApp (EApp (EVar "probesIn") (EVar "None")) (EVar "body"))))
(DTypeSig false "tailGrows" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "tailGrows" ((PVar "scopes") (PVar "acc") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "::")) PWild PWild PWild) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "acc")) (EVar "e"))) (arm (PCon "EBinOp" (PLit (LString "++")) PWild PWild PWild) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "scopes")) (EVar "acc")) (EVar "e"))) (arm (PCon "EIf" PWild (PVar "t") (PVar "f")) () (EBinOp "||" (EApp (EApp (EApp (EVar "tailGrows") (EVar "scopes")) (EVar "acc")) (EVar "t")) (EApp (EApp (EApp (EVar "tailGrows") (EVar "scopes")) (EVar "acc")) (EVar "f")))) (arm (PCon "EMatch" PWild (PVar "arms")) () (EApp (EApp (EDictApp "any") (ELam ((PCon "Arm" PWild PWild (PVar "b"))) (EApp (EApp (EApp (EVar "tailGrows") (EVar "scopes")) (EVar "acc")) (EVar "b")))) (EVar "arms"))) (arm (PCon "ELet" PWild PWild PWild PWild (PVar "body")) () (EApp (EApp (EApp (EVar "tailGrows") (EVar "scopes")) (EVar "acc")) (EVar "body"))) (arm (PCon "ELetGroup" PWild (PVar "body")) () (EApp (EApp (EApp (EVar "tailGrows") (EVar "scopes")) (EVar "acc")) (EVar "body"))) (arm PWild () (EVar "False"))))
(DTypeSig false "probeFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Probe") (TyCon "Finding"))))
(DFunDef false "probeFinding" ((PVar "fallback") (PCon "Probe" (PVar "loc") (PVar "callee") (PVar "c"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameListAsSet")) (fa "message" (EApp (EApp (EVar "message") (EVar "callee")) (EApp (EVar "containerName") (EVar "c")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "fallback"))) (fa "fix" (EVar "None")))))
(DTypeSig false "containerName" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "containerName" ((PVar "c")) (EMatch (EApp (EVar "unwrapLoc") (EVar "c")) (arm (PCon "EVar" (PVar "n")) () (EVar "n")) (arm PWild () (ELit (LString "the list")))))
(DTypeSig false "message" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "message" ((PVar "callee") (PVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "callee"))) (ELit (LString "` on `"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "`, which this loop grows on every step, walks the whole list each time, so the loop is quadratic. "))) (EApp (EMethodRef "display") (EApp (EVar "fixFor") (EVar "callee")))) (ELit (LString ""))))
(DTypeSig false "fixFor" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "fixFor" ((PLit (LString "lookupAssoc"))) (EVar "lookupFix"))
(DFunDef false "fixFor" ((PLit (LString "lookup"))) (EVar "lookupFix"))
(DFunDef false "fixFor" (PWild) (ELit (LString "Keep the elements in a `Set` beside the list (`has`, `insert`), or build the set once before the loop")))
(DTypeSig false "lookupFix" (TyCon "String"))
(DFunDef false "lookupFix" () (ELit (LString "Keep the pairs in a `Map` beside the list (`get`, `insert`), or build the map once before the loop")))
