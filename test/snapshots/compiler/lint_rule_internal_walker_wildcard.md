# META
source_lines=431
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-walker-wildcard: a self-recursive function over constructor patterns whose final wildcard returns a constant or its input without recursing.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{
  Arm(..),
  Decl(..),
  Expr(..),
  FunClause(..),
  LetBind(..),
  Lit(..),
  Loc,
  Pat(..),
  ConPayload(..),
  Variant(..),
  orElseLoc,
  patBoundNames,
}
import frontend.ast_walk.{childExprs}
import frontend.parser.{Positions(..)}
import list.{findMap, get, init, last, takeWhile, dropWhile}
import support.util.{
  anyList, allList, filterList, isEmptyL, isNonEmptyL, joinWith, listLen,
  startsWith
}
import tools.lint_calls.{lastSegment}
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
  mkRule,
  projectIndexOf,
}
import tools.lint_index.{
  IndexRow,
  Ns(..),
  ProjectIndex,
  RowKind(..),
  projectRows,
  projectRowsNamed,
  stdlibRows,
  stdlibRowsNamed,
}
import tools.lint_recursion.{spineOf}
import tools.lint_shared.{
  declLocList, firstLoc, isCtorName, mentionsVar, ruleNameWalkerWildcard,
  unwrapLoc
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameWalkerWildcard,
      summary =
        "a self-recursive function over constructor patterns ends in a wildcard that returns a constant or its input without recursing: a new constructor is silently skipped",
      doc =
        "A function that calls itself, has at least two clauses or match arms on constructors of one sum, and ends in a wildcard whose body is a literal, a constant constructor or its input unchanged, treats every constructor it does not name as a leaf. When the sum later gains a constructor, nothing goes red: the walker skips its subtree. The rule names the constructors the wildcard swallows, found in the file's own `data` declarations or the project index; when the sum cannot be resolved it says so and reports an unknown count.\n\nName the swallowed constructors in an or-pattern, so adding one is a visible edit, or recurse into them. A wildcard that is a deliberate default for three or more constructors takes a `-- lint-disable-next-line rule-walker-wildcard` that says why. Recursion counts only in a clause whose body also uses a field its constructor pattern binds. A wildcard that swallows only constructors without fields hides no subtree and is not reported. A wildcard that recurses, a function with fewer than two constructor clauses, and a function that is not self-recursive are not reported.\n\nBefore:\n  usesVar x (EVar y) = x == y\n  usesVar x (EApp f a) = usesVar x f || usesVar x a\n  usesVar _ _ = False\nAfter:\n  usesVar x (EVar y) = x == y\n  usesVar x (EApp f a) = usesVar x f || usesVar x a\n  usesVar x (ELam _ body) = usesVar x body\n  usesVar _ (ELit _ | EListLit _) = False",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [NeedsProjectIndex],
    }
    ruleWalkerWildcard
    None

-- What the rule reads of one file: the project index and the file's own declarations (their `data` resolves a constructor the index does
-- not yet hold).
data Env = Env ProjectIndex (List Decl)

-- One top-level clause with the declaration's start line.
data TopClause = TopClause String (List Pat) Expr (Option Loc)

ruleWalkerWildcard : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleWalkerWildcard idx _ _ pos prog =
  topFindings (Env (projectIndexOf idx) prog) (declLocList pos prog)

-- ── top-level groups ─────────────────────────────────────────────────────────

topFindings : Env -> List (Decl, Option Loc) -> List Finding
topFindings _ [] = []
topFindings env (dl :: rest) = match topClause dl
  None => topFindings env rest
  Some (TopClause name ps body loc) =>
    let same = takeWhile (sameTop name) rest
    let group = TopClause name ps body loc :: flatMap clauseList same
    groupFindings env name (map toClause group) (clauseLoc (lastOf group))
      ++ flatMap (topBodyFindings env) group
      ++ topFindings env (dropWhile (sameTop name) rest)

clauseList : (Decl, Option Loc) -> List TopClause
clauseList dl = match topClause dl
  Some c => [c]
  None => []

toClause : TopClause -> FunClause
toClause (TopClause _ ps body _) = FunClause ps body

lastOf : List TopClause -> Option TopClause
lastOf cs = last cs

clauseLoc : Option TopClause -> Option Loc
clauseLoc (Some (TopClause _ _ _ loc)) = loc
clauseLoc None = None

topClause : (Decl, Option Loc) -> Option TopClause
topClause (DFunDef _ name ps body _ _, loc) = Some (TopClause name ps body loc)
topClause (DAttrib _ d, loc) = topClause (d, loc)
topClause _ = None

sameTop : String -> (Decl, Option Loc) -> Bool
sameTop name dl = match topClause dl
  Some (TopClause n _ _ _) => n == name
  None => False

topBodyFindings : Env -> TopClause -> List Finding
topBodyFindings env (TopClause name _ body loc) = walkBody env name loc body

-- ── bodies ───────────────────────────────────────────────────────────────────

-- The `match` forms in a body and the `let`/`where` groups it opens.
walkBody : Env -> String -> Option Loc -> Expr -> List Finding
walkBody env name _ (ELoc l inner) = walkBody env name (Some l) inner
walkBody env name loc e =
  matchFindings env name loc e
    ++ (match e
      ELetGroup binds body =>
        flatMap (letBindFindings env) binds ++ walkBody env name loc body
      _ => flatMap (walkBody env name loc) (childExprs e))

letBindFindings : Env -> LetBind -> List Finding
letBindFindings env (LetBind name clauses site _) =
  groupFindings env name clauses (Some site)
    ++ flatMap (letClauseFindings env name site) clauses

letClauseFindings : Env -> String -> Loc -> FunClause -> List Finding
letClauseFindings env name site (FunClause _ body) =
  walkBody env name (Some site) body

-- ── the clause form ──────────────────────────────────────────────────────────

-- A function whose clauses name constructors in one parameter position and
-- whose last clause matches anything there and answers without recursing.
groupFindings : Env -> String -> List FunClause -> Option Loc -> List Finding
groupFindings env name clauses loc = match (init clauses, last clauses)
  (Some initCs, Some (FunClause pats body)) =>
    if allList irrefutable pats && not (mentionsVar name body) then
      firstPosition env name loc initCs pats body
    else
      []
  _ => []

firstPosition : Env ->
  String ->
  Option Loc ->
  List FunClause ->
  List Pat ->
  Expr ->
  List Finding
firstPosition env name loc initCs pats body =
  let found =
    findMap (positionFinding env name loc initCs pats body) (positionsOf pats)
  optionOr [] found

positionsOf : List Pat -> List Int
positionsOf pats = [0..listLen pats]

positionFinding : Env ->
  String ->
  Option Loc ->
  List FunClause ->
  List Pat ->
  Expr ->
  Int ->
  Option (List Finding)
positionFinding env name loc initCs pats body k = match get k pats
  None => None
  Some p =>
    let ctorClauses = filterList (hasCtorAt k) initCs
    let working = filterList (clauseWorks name) ctorClauses
    if listLen working >= 2
      && wildAt p body (varsOfPats pats)
      && anyList (clauseRecurses name k) working then
      Some (report env name loc (flatMap (ctorsAt k) ctorClauses))
    else
      None

hasCtorAt : Int -> FunClause -> Bool
hasCtorAt k c = isNonEmptyL (ctorsAt k c)

ctorsAt : Int -> FunClause -> List String
ctorsAt k (FunClause ps _) = match get k ps
  Some p => ctorsOfPat p
  None => []

-- A clause that does more than hand its one subterm back to the function: a
-- peel of a wrapper (`f (ELoc _ e) = f e`) walks nothing.
clauseWorks : String -> FunClause -> Bool
clauseWorks name (FunClause _ body) = not (forwards name body)

-- Recursion that reaches a subterm: the body mentions the function and a name
-- the constructor pattern at position `k` binds.
clauseRecurses : String -> Int -> FunClause -> Bool
clauseRecurses name k (FunClause ps body) = match get k ps
  Some p => reachesSubterm name p body
  None => False

forwards : String -> Expr -> Bool
forwards name e = match spineOf e []
  (hd, args) => isVar name hd && isNonEmptyL args && allList isAVar args

isAVar : Expr -> Bool
isAVar e = match unwrapLoc e
  EVar _ => True
  _ => False

varsOfPats : List Pat -> List String
varsOfPats pats = flatMap varOfPat pats

varOfPat : Pat -> List String
varOfPat (PVar n _ _) = [n]
varOfPat _ = []

irrefutable : Pat -> Bool
irrefutable PWild = True
irrefutable (PVar _ _ _) = True
irrefutable _ = False

-- ── the match form ───────────────────────────────────────────────────────────

matchFindings : Env -> String -> Option Loc -> Expr -> List Finding
matchFindings env name loc (EMatch scrut arms) =
  matchArms env name loc scrut arms
matchFindings _ _ _ _ = []

matchArms : Env -> String -> Option Loc -> Expr -> List Arm -> List Finding
matchArms env name loc scrut arms = match (
  init arms,
  last arms,
)
  (Some initArms, Some (Arm p guards body)) =>
    let ctorArms = filterList armHasCtor initArms
    let working = filterList (armWorks name) ctorArms
    if isEmptyL guards then
      if listLen working >= 2
        && wildAt p body (scrutVar scrut ++ varOfPat p)
        && anyList (armRecurses name) working then
        report
          env
          name
          (orElseLoc (firstLoc body) loc)
          (flatMap armCtors ctorArms)
      else
        []
    else
      []
  _ => []

armHasCtor : Arm -> Bool
armHasCtor arm = isNonEmptyL (armCtors arm)

armCtors : Arm -> List String
armCtors (Arm p _ _) = ctorsOfPat p

armWorks : String -> Arm -> Bool
armWorks name (Arm _ _ body) = not (forwards name body)

armRecurses : String -> Arm -> Bool
armRecurses name (Arm p _ body) = reachesSubterm name p body

reachesSubterm : String -> Pat -> Expr -> Bool
reachesSubterm name p body =
  mentionsVar name body && anyList (v => mentionsVar v body) (patBoundNames p)

scrutVar : Expr -> List String
scrutVar e = match unwrapLoc e
  EVar v => [v]
  _ => []

-- ── patterns and bodies ──────────────────────────────────────────────────────

-- The constructors a pattern names at its top: through `as`, alternatives and
-- a type ascription; a list, tuple, literal or variable pattern names none.
ctorsOfPat : Pat -> List String
ctorsOfPat (PCon n _) = [lastSegment n]
ctorsOfPat (PRec n _ _) = [lastSegment n]
ctorsOfPat (PAs _ _ _ p) = ctorsOfPat p
ctorsOfPat (PAnn p _) = ctorsOfPat p
ctorsOfPat (POr ps) = flatMap ctorsOfPat ps
-- Every other pattern form (variable, wildcard, literal, list, tuple) names no constructor at its top.
-- lint-disable-next-line rule-walker-wildcard
ctorsOfPat _ = []

-- A catch-all pattern whose body is a constant or one of `inputs` unchanged.  A
-- variable pattern is a catch-all when the body ignores it or returns it as is.
wildAt : Pat -> Expr -> List String -> Bool
wildAt PWild body inputs = constantOrInput inputs body
wildAt (PVar n _ _) body inputs =
  constantOrInput inputs body
    && (startsWith "_" n || not (mentionsVar n body) || isVar n body)
wildAt _ _ _ = False

isVar : String -> Expr -> Bool
isVar n e = match unwrapLoc e
  EVar v => v == n
  _ => False

-- A literal, a constant constructor (also applied to constants), an empty list,
-- a tuple of constants, or one of the input names.
constantOrInput : List String -> Expr -> Bool
constantOrInput inputs e = match unwrapLoc e
  ELit _ => True
  ENumLit _ _ _ => True
  EWideLit _ _ _ _ => True
  EVar v => isCtorName v || anyList (== v) inputs
  EListLit es => allList (constantOrInput []) es
  ETuple es => allList (constantOrInput inputs) es
  EUnOp "-" x _ => constantOrInput [] x
  EApp _ _ => match spineOf e []
    (hd, args) => ctorHead hd && allList (constantOrInput []) args
  -- Only the forms above can be a constant; any other expression computes.
  -- lint-disable-next-line rule-walker-wildcard
  _ => False

ctorHead : Expr -> Bool
ctorHead e = match unwrapLoc e
  EVar v => isCtorName v
  _ => False

-- ── the message ──────────────────────────────────────────────────────────────

-- One finding naming what the wildcard swallows.  A sum all of whose
-- constructors the clauses name yields none, and so does one whose swallowed
-- constructors are all nullary: they carry no subtree to skip.
report : Env -> String -> Option Loc -> List String -> List Finding
report env name loc named = match findMap (sumOf env) named
  None => [finding loc (unknownMessage name)]
  Some (ty, ctors) =>
    let swallowed = filterList (c => not (anyList (== fst c) named)) ctors
    if anyList (c => snd c >= 1) swallowed then
      [finding loc (swallowMessage name ty (map fst swallowed))]
    else
      []

finding : Option Loc -> String -> Finding
finding loc message = Finding {
  rule = ruleNameWalkerWildcard,
  message = message,
  severity = SevWarning,
  loc = loc,
  fix = None,
}

swallowMessage : String -> String -> List String -> String
swallowMessage name ty swallowed =
  "`\{name}` recurses over `\{ty}` but its final wildcard swallows \{countText (listLen swallowed)} (\{joinWith ", " swallowed}) without recursing; name them in an or-pattern, or recurse"

unknownMessage : String -> String
unknownMessage name =
  "`\{name}` recurses over constructor patterns but its final wildcard swallows an unknown number of constructors without recursing; name them in an or-pattern, or recurse"

countText : Int -> String
countText 1 = "1 constructor"
countText n = "\{n} constructors"

-- ── the sum of a constructor ─────────────────────────────────────────────────

-- The type and every constructor of the sum that declares `c`, each with its
-- field count: the file's own `data` first, then the index.
sumOf : Env -> String -> Option (String, List (String, Int))
sumOf (Env ix decls) c = match findMap (declSum c) decls
  Some s => Some s
  None => indexSum ix c

declSum : String -> Decl -> Option (String, List (String, Int))
declSum c (DData { dataName = n, dataCtors = vs, ... }) =
  if anyList (v => variantName v == c) vs then
    Some (n, map variantArity vs)
  else
    None
declSum c (DAttrib _ d) = declSum c d
declSum _ _ = None

variantName : Variant -> String
variantName (Variant n _) = n

variantArity : Variant -> (String, Int)
variantArity (Variant n (ConPos tys)) = (n, listLen tys)
variantArity (Variant n (ConNamed fields _)) = (n, listLen fields)

-- A constructor name declared once across the project and the stdlib resolves;
-- a name declared more than once, or not at all, does not.  The siblings come
-- from the scope that declares the constructor alone: a whole-scope scan
-- dominates the rule's cost.
indexSum : ProjectIndex -> String -> Option (String, List (String, Int))
indexSum ix c = match (
  filterList isCtorRow (projectRowsNamed ix NsValue c),
  filterList isCtorRow (stdlibRowsNamed ix NsValue c),
)
  ([r], []) => Some (siblingsIn r (projectRows ix))
  ([], [r]) => Some (siblingsIn r (stdlibRows ix))
  _ => None

siblingsIn : IndexRow -> List IndexRow -> (String, List (String, Int))
siblingsIn r rows = (
  r.ixrParent,
  map (x => (x.ixrName, x.ixrArity)) (filterList (siblingOf r) rows),
)

isCtorRow : IndexRow -> Bool
isCtorRow r = r.ixrKind == RkCtor

siblingOf : IndexRow -> IndexRow -> Bool
siblingOf r x =
  x.ixrKind == RkCtor
    && x.ixrModule == r.ixrModule
    && x.ixrParent == r.ixrParent
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "Expr" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Lit" true) (mem "Loc" false) (mem "Pat" true) (mem "ConPayload" true) (mem "Variant" true) (mem "orElseLoc" false) (mem "patBoundNames" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "childExprs" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "get" false) (mem "init" false) (mem "last" false) (mem "takeWhile" false) (mem "dropWhile" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "allList" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "joinWith" false) (mem "listLen" false) (mem "startsWith" false))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "lastSegment" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false) (mem "projectIndexOf" false))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "IndexRow" false) (mem "Ns" true) (mem "ProjectIndex" false) (mem "RowKind" true) (mem "projectRows" false) (mem "projectRowsNamed" false) (mem "stdlibRows" false) (mem "stdlibRowsNamed" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "spineOf" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "declLocList" false) (mem "firstLoc" false) (mem "isCtorName" false) (mem "mentionsVar" false) (mem "ruleNameWalkerWildcard" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameWalkerWildcard")) (fa "summary" (ELit (LString "a self-recursive function over constructor patterns ends in a wildcard that returns a constant or its input without recursing: a new constructor is silently skipped"))) (fa "doc" (ELit (LString "A function that calls itself, has at least two clauses or match arms on constructors of one sum, and ends in a wildcard whose body is a literal, a constant constructor or its input unchanged, treats every constructor it does not name as a leaf. When the sum later gains a constructor, nothing goes red: the walker skips its subtree. The rule names the constructors the wildcard swallows, found in the file's own `data` declarations or the project index; when the sum cannot be resolved it says so and reports an unknown count.\n\nName the swallowed constructors in an or-pattern, so adding one is a visible edit, or recurse into them. A wildcard that is a deliberate default for three or more constructors takes a `-- lint-disable-next-line rule-walker-wildcard` that says why. Recursion counts only in a clause whose body also uses a field its constructor pattern binds. A wildcard that swallows only constructors without fields hides no subtree and is not reported. A wildcard that recurses, a function with fewer than two constructor clauses, and a function that is not self-recursive are not reported.\n\nBefore:\n  usesVar x (EVar y) = x == y\n  usesVar x (EApp f a) = usesVar x f || usesVar x a\n  usesVar _ _ = False\nAfter:\n  usesVar x (EVar y) = x == y\n  usesVar x (EApp f a) = usesVar x f || usesVar x a\n  usesVar x (ELam _ body) = usesVar x body\n  usesVar _ (ELit _ | EListLit _) = False"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsProjectIndex")))))) (EVar "ruleWalkerWildcard")) (EVar "None")))
(DData Private "Env" () ((variant "Env" (ConPos (TyCon "ProjectIndex") (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DData Private "TopClause" () ((variant "TopClause" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig false "ruleWalkerWildcard" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleWalkerWildcard" ((PVar "idx") PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "topFindings") (EApp (EApp (EVar "Env") (EApp (EVar "projectIndexOf") (EVar "idx"))) (EVar "prog"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "topFindings" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "topFindings" (PWild (PList)) (EListLit))
(DFunDef false "topFindings" ((PVar "env") (PCons (PVar "dl") (PVar "rest"))) (EMatch (EApp (EVar "topClause") (EVar "dl")) (arm (PCon "None") () (EApp (EApp (EVar "topFindings") (EVar "env")) (EVar "rest"))) (arm (PCon "Some" (PCon "TopClause" (PVar "name") (PVar "ps") (PVar "body") (PVar "loc"))) () (EBlock (DoLet false false (PVar "same") (EApp (EApp (EVar "takeWhile") (EApp (EVar "sameTop") (EVar "name"))) (EVar "rest"))) (DoLet false false (PVar "group") (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "TopClause") (EVar "name")) (EVar "ps")) (EVar "body")) (EVar "loc")) (EApp (EApp (EVar "flatMap") (EVar "clauseList")) (EVar "same")))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "groupFindings") (EVar "env")) (EVar "name")) (EApp (EApp (EVar "map") (EVar "toClause")) (EVar "group"))) (EApp (EVar "clauseLoc") (EApp (EVar "lastOf") (EVar "group")))) (EApp (EApp (EVar "flatMap") (EApp (EVar "topBodyFindings") (EVar "env"))) (EVar "group"))) (EApp (EApp (EVar "topFindings") (EVar "env")) (EApp (EApp (EVar "dropWhile") (EApp (EVar "sameTop") (EVar "name"))) (EVar "rest")))))))))
(DTypeSig false "clauseList" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "TopClause"))))
(DFunDef false "clauseList" ((PVar "dl")) (EMatch (EApp (EVar "topClause") (EVar "dl")) (arm (PCon "Some" (PVar "c")) () (EListLit (EVar "c"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "toClause" (TyFun (TyCon "TopClause") (TyCon "FunClause")))
(DFunDef false "toClause" ((PCon "TopClause" PWild (PVar "ps") (PVar "body") PWild)) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "body")))
(DTypeSig false "lastOf" (TyFun (TyApp (TyCon "List") (TyCon "TopClause")) (TyApp (TyCon "Option") (TyCon "TopClause"))))
(DFunDef false "lastOf" ((PVar "cs")) (EApp (EVar "last") (EVar "cs")))
(DTypeSig false "clauseLoc" (TyFun (TyApp (TyCon "Option") (TyCon "TopClause")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "clauseLoc" ((PCon "Some" (PCon "TopClause" PWild PWild PWild (PVar "loc")))) (EVar "loc"))
(DFunDef false "clauseLoc" ((PCon "None")) (EVar "None"))
(DTypeSig false "topClause" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "Option") (TyCon "TopClause"))))
(DFunDef false "topClause" ((PTuple (PCon "DFunDef" PWild (PVar "name") (PVar "ps") (PVar "body") PWild PWild) (PVar "loc"))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "TopClause") (EVar "name")) (EVar "ps")) (EVar "body")) (EVar "loc"))))
(DFunDef false "topClause" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "topClause") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "topClause" (PWild) (EVar "None"))
(DTypeSig false "sameTop" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "sameTop" ((PVar "name") (PVar "dl")) (EMatch (EApp (EVar "topClause") (EVar "dl")) (arm (PCon "Some" (PCon "TopClause" (PVar "n") PWild PWild PWild)) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "topBodyFindings" (TyFun (TyCon "Env") (TyFun (TyCon "TopClause") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "topBodyFindings" ((PVar "env") (PCon "TopClause" (PVar "name") PWild (PVar "body") (PVar "loc"))) (EApp (EApp (EApp (EApp (EVar "walkBody") (EVar "env")) (EVar "name")) (EVar "loc")) (EVar "body")))
(DTypeSig false "walkBody" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "walkBody" ((PVar "env") (PVar "name") PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EApp (EApp (EVar "walkBody") (EVar "env")) (EVar "name")) (EApp (EVar "Some") (EVar "l"))) (EVar "inner")))
(DFunDef false "walkBody" ((PVar "env") (PVar "name") (PVar "loc") (PVar "e")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "matchFindings") (EVar "env")) (EVar "name")) (EVar "loc")) (EVar "e")) (EMatch (EVar "e") (arm (PCon "ELetGroup" (PVar "binds") (PVar "body")) () (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "letBindFindings") (EVar "env"))) (EVar "binds")) (EApp (EApp (EApp (EApp (EVar "walkBody") (EVar "env")) (EVar "name")) (EVar "loc")) (EVar "body")))) (arm PWild () (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "walkBody") (EVar "env")) (EVar "name")) (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e")))))))
(DTypeSig false "letBindFindings" (TyFun (TyCon "Env") (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "letBindFindings" ((PVar "env") (PCon "LetBind" (PVar "name") (PVar "clauses") (PVar "site") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "groupFindings") (EVar "env")) (EVar "name")) (EVar "clauses")) (EApp (EVar "Some") (EVar "site"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "letClauseFindings") (EVar "env")) (EVar "name")) (EVar "site"))) (EVar "clauses"))))
(DTypeSig false "letClauseFindings" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "letClauseFindings" ((PVar "env") (PVar "name") (PVar "site") (PCon "FunClause" PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "walkBody") (EVar "env")) (EVar "name")) (EApp (EVar "Some") (EVar "site"))) (EVar "body")))
(DTypeSig false "groupFindings" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "groupFindings" ((PVar "env") (PVar "name") (PVar "clauses") (PVar "loc")) (EMatch (ETuple (EApp (EVar "init") (EVar "clauses")) (EApp (EVar "last") (EVar "clauses"))) (arm (PTuple (PCon "Some" (PVar "initCs")) (PCon "Some" (PCon "FunClause" (PVar "pats") (PVar "body")))) () (EIf (EBinOp "&&" (EApp (EApp (EVar "allList") (EVar "irrefutable")) (EVar "pats")) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "name")) (EVar "body")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstPosition") (EVar "env")) (EVar "name")) (EVar "loc")) (EVar "initCs")) (EVar "pats")) (EVar "body")) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig false "firstPosition" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "firstPosition" ((PVar "env") (PVar "name") (PVar "loc") (PVar "initCs") (PVar "pats") (PVar "body")) (EBlock (DoLet false false (PVar "found") (EApp (EApp (EVar "findMap") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "positionFinding") (EVar "env")) (EVar "name")) (EVar "loc")) (EVar "initCs")) (EVar "pats")) (EVar "body"))) (EApp (EVar "positionsOf") (EVar "pats")))) (DoExpr (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "found")))))
(DTypeSig false "positionsOf" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "positionsOf" ((PVar "pats")) (ERangeList (ELit (LInt 0)) (EApp (EVar "listLen") (EVar "pats")) false))
(DTypeSig false "positionFinding" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Finding")))))))))))
(DFunDef false "positionFinding" ((PVar "env") (PVar "name") (PVar "loc") (PVar "initCs") (PVar "pats") (PVar "body") (PVar "k")) (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "pats")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "p")) () (EBlock (DoLet false false (PVar "ctorClauses") (EApp (EApp (EVar "filterList") (EApp (EVar "hasCtorAt") (EVar "k"))) (EVar "initCs"))) (DoLet false false (PVar "working") (EApp (EApp (EVar "filterList") (EApp (EVar "clauseWorks") (EVar "name"))) (EVar "ctorClauses"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "working")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "wildAt") (EVar "p")) (EVar "body")) (EApp (EVar "varsOfPats") (EVar "pats")))) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "clauseRecurses") (EVar "name")) (EVar "k"))) (EVar "working"))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "report") (EVar "env")) (EVar "name")) (EVar "loc")) (EApp (EApp (EVar "flatMap") (EApp (EVar "ctorsAt") (EVar "k"))) (EVar "ctorClauses")))) (EVar "None")))))))
(DTypeSig false "hasCtorAt" (TyFun (TyCon "Int") (TyFun (TyCon "FunClause") (TyCon "Bool"))))
(DFunDef false "hasCtorAt" ((PVar "k") (PVar "c")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "ctorsAt") (EVar "k")) (EVar "c"))))
(DTypeSig false "ctorsAt" (TyFun (TyCon "Int") (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ctorsAt" ((PVar "k") (PCon "FunClause" (PVar "ps") PWild)) (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "ps")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "ctorsOfPat") (EVar "p"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "clauseWorks" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyCon "Bool"))))
(DFunDef false "clauseWorks" ((PVar "name") (PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "not") (EApp (EApp (EVar "forwards") (EVar "name")) (EVar "body"))))
(DTypeSig false "clauseRecurses" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "FunClause") (TyCon "Bool")))))
(DFunDef false "clauseRecurses" ((PVar "name") (PVar "k") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "ps")) (arm (PCon "Some" (PVar "p")) () (EApp (EApp (EApp (EVar "reachesSubterm") (EVar "name")) (EVar "p")) (EVar "body"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "forwards" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "forwards" ((PVar "name") (PVar "e")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isVar") (EVar "name")) (EVar "hd")) (EApp (EVar "isNonEmptyL") (EVar "args"))) (EApp (EApp (EVar "allList") (EVar "isAVar")) (EVar "args"))))))
(DTypeSig false "isAVar" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isAVar" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "varsOfPats" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "varsOfPats" ((PVar "pats")) (EApp (EApp (EVar "flatMap") (EVar "varOfPat")) (EVar "pats")))
(DTypeSig false "varOfPat" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "varOfPat" ((PCon "PVar" (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "varOfPat" (PWild) (EListLit))
(DTypeSig false "irrefutable" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "irrefutable" ((PCon "PWild")) (EVar "True"))
(DFunDef false "irrefutable" ((PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "irrefutable" (PWild) (EVar "False"))
(DTypeSig false "matchFindings" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "matchFindings" ((PVar "env") (PVar "name") (PVar "loc") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EApp (EApp (EVar "matchArms") (EVar "env")) (EVar "name")) (EVar "loc")) (EVar "scrut")) (EVar "arms")))
(DFunDef false "matchFindings" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "matchArms" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "matchArms" ((PVar "env") (PVar "name") (PVar "loc") (PVar "scrut") (PVar "arms")) (EMatch (ETuple (EApp (EVar "init") (EVar "arms")) (EApp (EVar "last") (EVar "arms"))) (arm (PTuple (PCon "Some" (PVar "initArms")) (PCon "Some" (PCon "Arm" (PVar "p") (PVar "guards") (PVar "body")))) () (EBlock (DoLet false false (PVar "ctorArms") (EApp (EApp (EVar "filterList") (EVar "armHasCtor")) (EVar "initArms"))) (DoLet false false (PVar "working") (EApp (EApp (EVar "filterList") (EApp (EVar "armWorks") (EVar "name"))) (EVar "ctorArms"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "guards")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "working")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "wildAt") (EVar "p")) (EVar "body")) (EBinOp "++" (EApp (EVar "scrutVar") (EVar "scrut")) (EApp (EVar "varOfPat") (EVar "p"))))) (EApp (EApp (EVar "anyList") (EApp (EVar "armRecurses") (EVar "name"))) (EVar "working"))) (EApp (EApp (EApp (EApp (EVar "report") (EVar "env")) (EVar "name")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "body"))) (EVar "loc"))) (EApp (EApp (EVar "flatMap") (EVar "armCtors")) (EVar "ctorArms"))) (EListLit)) (EListLit))))) (arm PWild () (EListLit))))
(DTypeSig false "armHasCtor" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armHasCtor" ((PVar "arm")) (EApp (EVar "isNonEmptyL") (EApp (EVar "armCtors") (EVar "arm"))))
(DTypeSig false "armCtors" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "armCtors" ((PCon "Arm" (PVar "p") PWild PWild)) (EApp (EVar "ctorsOfPat") (EVar "p")))
(DTypeSig false "armWorks" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armWorks" ((PVar "name") (PCon "Arm" PWild PWild (PVar "body"))) (EApp (EVar "not") (EApp (EApp (EVar "forwards") (EVar "name")) (EVar "body"))))
(DTypeSig false "armRecurses" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armRecurses" ((PVar "name") (PCon "Arm" (PVar "p") PWild (PVar "body"))) (EApp (EApp (EApp (EVar "reachesSubterm") (EVar "name")) (EVar "p")) (EVar "body")))
(DTypeSig false "reachesSubterm" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "reachesSubterm" ((PVar "name") (PVar "p") (PVar "body")) (EBinOp "&&" (EApp (EApp (EVar "mentionsVar") (EVar "name")) (EVar "body")) (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EApp (EVar "mentionsVar") (EVar "v")) (EVar "body")))) (EApp (EVar "patBoundNames") (EVar "p")))))
(DTypeSig false "scrutVar" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "scrutVar" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "v")) () (EListLit (EVar "v"))) (arm PWild () (EListLit))))
(DTypeSig false "ctorsOfPat" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ctorsOfPat" ((PCon "PCon" (PVar "n") PWild)) (EListLit (EApp (EVar "lastSegment") (EVar "n"))))
(DFunDef false "ctorsOfPat" ((PCon "PRec" (PVar "n") PWild PWild)) (EListLit (EApp (EVar "lastSegment") (EVar "n"))))
(DFunDef false "ctorsOfPat" ((PCon "PAs" PWild PWild PWild (PVar "p"))) (EApp (EVar "ctorsOfPat") (EVar "p")))
(DFunDef false "ctorsOfPat" ((PCon "PAnn" (PVar "p") PWild)) (EApp (EVar "ctorsOfPat") (EVar "p")))
(DFunDef false "ctorsOfPat" ((PCon "POr" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "ctorsOfPat")) (EVar "ps")))
(DFunDef false "ctorsOfPat" (PWild) (EListLit))
(DTypeSig false "wildAt" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "wildAt" ((PCon "PWild") (PVar "body") (PVar "inputs")) (EApp (EApp (EVar "constantOrInput") (EVar "inputs")) (EVar "body")))
(DFunDef false "wildAt" ((PCon "PVar" (PVar "n") PWild PWild) (PVar "body") (PVar "inputs")) (EBinOp "&&" (EApp (EApp (EVar "constantOrInput") (EVar "inputs")) (EVar "body")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "startsWith") (ELit (LString "_"))) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "n")) (EVar "body")))) (EApp (EApp (EVar "isVar") (EVar "n")) (EVar "body")))))
(DFunDef false "wildAt" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "isVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isVar" ((PVar "n") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "v")) () (EBinOp "==" (EVar "v") (EVar "n"))) (arm PWild () (EVar "False"))))
(DTypeSig false "constantOrInput" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "constantOrInput" ((PVar "inputs") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "ENumLit" PWild PWild PWild) () (EVar "True")) (arm (PCon "EWideLit" PWild PWild PWild PWild) () (EVar "True")) (arm (PCon "EVar" (PVar "v")) () (EBinOp "||" (EApp (EVar "isCtorName") (EVar "v")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "v")))) (EVar "inputs")))) (arm (PCon "EListLit" (PVar "es")) () (EApp (EApp (EVar "allList") (EApp (EVar "constantOrInput") (EListLit))) (EVar "es"))) (arm (PCon "ETuple" (PVar "es")) () (EApp (EApp (EVar "allList") (EApp (EVar "constantOrInput") (EVar "inputs"))) (EVar "es"))) (arm (PCon "EUnOp" (PLit (LString "-")) (PVar "x") PWild) () (EApp (EApp (EVar "constantOrInput") (EListLit)) (EVar "x"))) (arm (PCon "EApp" PWild PWild) () (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EBinOp "&&" (EApp (EVar "ctorHead") (EVar "hd")) (EApp (EApp (EVar "allList") (EApp (EVar "constantOrInput") (EListLit))) (EVar "args")))))) (arm PWild () (EVar "False"))))
(DTypeSig false "ctorHead" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "ctorHead" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "v")) () (EApp (EVar "isCtorName") (EVar "v"))) (arm PWild () (EVar "False"))))
(DTypeSig false "report" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "report" ((PVar "env") (PVar "name") (PVar "loc") (PVar "named")) (EMatch (EApp (EApp (EVar "findMap") (EApp (EVar "sumOf") (EVar "env"))) (EVar "named")) (arm (PCon "None") () (EListLit (EApp (EApp (EVar "finding") (EVar "loc")) (EApp (EVar "unknownMessage") (EVar "name"))))) (arm (PCon "Some" (PTuple (PVar "ty") (PVar "ctors"))) () (EBlock (DoLet false false (PVar "swallowed") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EApp (EVar "fst") (EVar "c"))))) (EVar "named"))))) (EVar "ctors"))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "c")) (EBinOp ">=" (EApp (EVar "snd") (EVar "c")) (ELit (LInt 1))))) (EVar "swallowed")) (EListLit (EApp (EApp (EVar "finding") (EVar "loc")) (EApp (EApp (EApp (EVar "swallowMessage") (EVar "name")) (EVar "ty")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "swallowed"))))) (EListLit)))))))
(DTypeSig false "finding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "finding" ((PVar "loc") (PVar "message")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameWalkerWildcard")) (fa "message" (EVar "message")) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "swallowMessage" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "swallowMessage" ((PVar "name") (PVar "ty") (PVar "swallowed")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` recurses over `"))) (EApp (EVar "display") (EVar "ty"))) (ELit (LString "` but its final wildcard swallows "))) (EApp (EVar "display") (EApp (EVar "countText") (EApp (EVar "listLen") (EVar "swallowed"))))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "swallowed")))) (ELit (LString ") without recursing; name them in an or-pattern, or recurse"))))
(DTypeSig false "unknownMessage" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unknownMessage" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` recurses over constructor patterns but its final wildcard swallows an unknown number of constructors without recursing; name them in an or-pattern, or recurse"))))
(DTypeSig false "countText" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "countText" ((PLit (LInt 1))) (ELit (LString "1 constructor")))
(DFunDef false "countText" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " constructors"))))
(DTypeSig false "sumOf" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "sumOf" ((PCon "Env" (PVar "ix") (PVar "decls")) (PVar "c")) (EMatch (EApp (EApp (EVar "findMap") (EApp (EVar "declSum") (EVar "c"))) (EVar "decls")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EApp (EApp (EVar "indexSum") (EVar "ix")) (EVar "c")))))
(DTypeSig false "declSum" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "declSum" ((PVar "c") (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) true)) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EBinOp "==" (EApp (EVar "variantName") (EVar "v")) (EVar "c")))) (EVar "vs")) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "variantArity")) (EVar "vs")))) (EVar "None")))
(DFunDef false "declSum" ((PVar "c") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declSum") (EVar "c")) (EVar "d")))
(DFunDef false "declSum" (PWild PWild) (EVar "None"))
(DTypeSig false "variantName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "variantArity" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "variantArity" ((PCon "Variant" (PVar "n") (PCon "ConPos" (PVar "tys")))) (ETuple (EVar "n") (EApp (EVar "listLen") (EVar "tys"))))
(DFunDef false "variantArity" ((PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fields") PWild))) (ETuple (EVar "n") (EApp (EVar "listLen") (EVar "fields"))))
(DTypeSig false "indexSum" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "indexSum" ((PVar "ix") (PVar "c")) (EMatch (ETuple (EApp (EApp (EVar "filterList") (EVar "isCtorRow")) (EApp (EApp (EApp (EVar "projectRowsNamed") (EVar "ix")) (EVar "NsValue")) (EVar "c"))) (EApp (EApp (EVar "filterList") (EVar "isCtorRow")) (EApp (EApp (EApp (EVar "stdlibRowsNamed") (EVar "ix")) (EVar "NsValue")) (EVar "c")))) (arm (PTuple (PList (PVar "r")) (PList)) () (EApp (EVar "Some") (EApp (EApp (EVar "siblingsIn") (EVar "r")) (EApp (EVar "projectRows") (EVar "ix"))))) (arm (PTuple (PList) (PList (PVar "r"))) () (EApp (EVar "Some") (EApp (EApp (EVar "siblingsIn") (EVar "r")) (EApp (EVar "stdlibRows") (EVar "ix"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "siblingsIn" (TyFun (TyCon "IndexRow") (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "siblingsIn" ((PVar "r") (PVar "rows")) (ETuple (EFieldAccess (EVar "r") "ixrParent") (EApp (EApp (EVar "map") (ELam ((PVar "x")) (ETuple (EFieldAccess (EVar "x") "ixrName") (EFieldAccess (EVar "x") "ixrArity")))) (EApp (EApp (EVar "filterList") (EApp (EVar "siblingOf") (EVar "r"))) (EVar "rows")))))
(DTypeSig false "isCtorRow" (TyFun (TyCon "IndexRow") (TyCon "Bool")))
(DFunDef false "isCtorRow" ((PVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "ixrKind") (EVar "RkCtor")))
(DTypeSig false "siblingOf" (TyFun (TyCon "IndexRow") (TyFun (TyCon "IndexRow") (TyCon "Bool"))))
(DFunDef false "siblingOf" ((PVar "r") (PVar "x")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "x") "ixrKind") (EVar "RkCtor")) (EBinOp "==" (EFieldAccess (EVar "x") "ixrModule") (EFieldAccess (EVar "r") "ixrModule"))) (EBinOp "==" (EFieldAccess (EVar "x") "ixrParent") (EFieldAccess (EVar "r") "ixrParent"))))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "Expr" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Lit" true) (mem "Loc" false) (mem "Pat" true) (mem "ConPayload" true) (mem "Variant" true) (mem "orElseLoc" false) (mem "patBoundNames" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "childExprs" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "get" false) (mem "init" false) (mem "last" false) (mem "takeWhile" false) (mem "dropWhile" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "allList" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "joinWith" false) (mem "listLen" false) (mem "startsWith" false))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "lastSegment" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false) (mem "projectIndexOf" false))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "IndexRow" false) (mem "Ns" true) (mem "ProjectIndex" false) (mem "RowKind" true) (mem "projectRows" false) (mem "projectRowsNamed" false) (mem "stdlibRows" false) (mem "stdlibRowsNamed" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "spineOf" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "declLocList" false) (mem "firstLoc" false) (mem "isCtorName" false) (mem "mentionsVar" false) (mem "ruleNameWalkerWildcard" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameWalkerWildcard")) (fa "summary" (ELit (LString "a self-recursive function over constructor patterns ends in a wildcard that returns a constant or its input without recursing: a new constructor is silently skipped"))) (fa "doc" (ELit (LString "A function that calls itself, has at least two clauses or match arms on constructors of one sum, and ends in a wildcard whose body is a literal, a constant constructor or its input unchanged, treats every constructor it does not name as a leaf. When the sum later gains a constructor, nothing goes red: the walker skips its subtree. The rule names the constructors the wildcard swallows, found in the file's own `data` declarations or the project index; when the sum cannot be resolved it says so and reports an unknown count.\n\nName the swallowed constructors in an or-pattern, so adding one is a visible edit, or recurse into them. A wildcard that is a deliberate default for three or more constructors takes a `-- lint-disable-next-line rule-walker-wildcard` that says why. Recursion counts only in a clause whose body also uses a field its constructor pattern binds. A wildcard that swallows only constructors without fields hides no subtree and is not reported. A wildcard that recurses, a function with fewer than two constructor clauses, and a function that is not self-recursive are not reported.\n\nBefore:\n  usesVar x (EVar y) = x == y\n  usesVar x (EApp f a) = usesVar x f || usesVar x a\n  usesVar _ _ = False\nAfter:\n  usesVar x (EVar y) = x == y\n  usesVar x (EApp f a) = usesVar x f || usesVar x a\n  usesVar x (ELam _ body) = usesVar x body\n  usesVar _ (ELit _ | EListLit _) = False"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsProjectIndex")))))) (EVar "ruleWalkerWildcard")) (EVar "None")))
(DData Private "Env" () ((variant "Env" (ConPos (TyCon "ProjectIndex") (TyApp (TyCon "List") (TyCon "Decl"))))) ())
(DData Private "TopClause" () ((variant "TopClause" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig false "ruleWalkerWildcard" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleWalkerWildcard" ((PVar "idx") PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "topFindings") (EApp (EApp (EVar "Env") (EApp (EVar "projectIndexOf") (EVar "idx"))) (EVar "prog"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "topFindings" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "topFindings" (PWild (PList)) (EListLit))
(DFunDef false "topFindings" ((PVar "env") (PCons (PVar "dl") (PVar "rest"))) (EMatch (EApp (EVar "topClause") (EVar "dl")) (arm (PCon "None") () (EApp (EApp (EVar "topFindings") (EVar "env")) (EVar "rest"))) (arm (PCon "Some" (PCon "TopClause" (PVar "name") (PVar "ps") (PVar "body") (PVar "loc"))) () (EBlock (DoLet false false (PVar "same") (EApp (EApp (EVar "takeWhile") (EApp (EVar "sameTop") (EVar "name"))) (EVar "rest"))) (DoLet false false (PVar "group") (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "TopClause") (EVar "name")) (EVar "ps")) (EVar "body")) (EVar "loc")) (EApp (EApp (EDictApp "flatMap") (EVar "clauseList")) (EVar "same")))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "groupFindings") (EVar "env")) (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "toClause")) (EVar "group"))) (EApp (EVar "clauseLoc") (EApp (EVar "lastOf") (EVar "group")))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "topBodyFindings") (EVar "env"))) (EVar "group"))) (EApp (EApp (EVar "topFindings") (EVar "env")) (EApp (EApp (EVar "dropWhile") (EApp (EVar "sameTop") (EVar "name"))) (EVar "rest")))))))))
(DTypeSig false "clauseList" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "TopClause"))))
(DFunDef false "clauseList" ((PVar "dl")) (EMatch (EApp (EVar "topClause") (EVar "dl")) (arm (PCon "Some" (PVar "c")) () (EListLit (EVar "c"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "toClause" (TyFun (TyCon "TopClause") (TyCon "FunClause")))
(DFunDef false "toClause" ((PCon "TopClause" PWild (PVar "ps") (PVar "body") PWild)) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "body")))
(DTypeSig false "lastOf" (TyFun (TyApp (TyCon "List") (TyCon "TopClause")) (TyApp (TyCon "Option") (TyCon "TopClause"))))
(DFunDef false "lastOf" ((PVar "cs")) (EApp (EVar "last") (EVar "cs")))
(DTypeSig false "clauseLoc" (TyFun (TyApp (TyCon "Option") (TyCon "TopClause")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "clauseLoc" ((PCon "Some" (PCon "TopClause" PWild PWild PWild (PVar "loc")))) (EVar "loc"))
(DFunDef false "clauseLoc" ((PCon "None")) (EVar "None"))
(DTypeSig false "topClause" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "Option") (TyCon "TopClause"))))
(DFunDef false "topClause" ((PTuple (PCon "DFunDef" PWild (PVar "name") (PVar "ps") (PVar "body") PWild PWild) (PVar "loc"))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "TopClause") (EVar "name")) (EVar "ps")) (EVar "body")) (EVar "loc"))))
(DFunDef false "topClause" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "topClause") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "topClause" (PWild) (EVar "None"))
(DTypeSig false "sameTop" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "sameTop" ((PVar "name") (PVar "dl")) (EMatch (EApp (EVar "topClause") (EVar "dl")) (arm (PCon "Some" (PCon "TopClause" (PVar "n") PWild PWild PWild)) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "topBodyFindings" (TyFun (TyCon "Env") (TyFun (TyCon "TopClause") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "topBodyFindings" ((PVar "env") (PCon "TopClause" (PVar "name") PWild (PVar "body") (PVar "loc"))) (EApp (EApp (EApp (EApp (EVar "walkBody") (EVar "env")) (EVar "name")) (EVar "loc")) (EVar "body")))
(DTypeSig false "walkBody" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "walkBody" ((PVar "env") (PVar "name") PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EApp (EApp (EVar "walkBody") (EVar "env")) (EVar "name")) (EApp (EVar "Some") (EVar "l"))) (EVar "inner")))
(DFunDef false "walkBody" ((PVar "env") (PVar "name") (PVar "loc") (PVar "e")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "matchFindings") (EVar "env")) (EVar "name")) (EVar "loc")) (EVar "e")) (EMatch (EVar "e") (arm (PCon "ELetGroup" (PVar "binds") (PVar "body")) () (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "letBindFindings") (EVar "env"))) (EVar "binds")) (EApp (EApp (EApp (EApp (EVar "walkBody") (EVar "env")) (EVar "name")) (EVar "loc")) (EVar "body")))) (arm PWild () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "walkBody") (EVar "env")) (EVar "name")) (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e")))))))
(DTypeSig false "letBindFindings" (TyFun (TyCon "Env") (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "letBindFindings" ((PVar "env") (PCon "LetBind" (PVar "name") (PVar "clauses") (PVar "site") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "groupFindings") (EVar "env")) (EVar "name")) (EVar "clauses")) (EApp (EVar "Some") (EVar "site"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "letClauseFindings") (EVar "env")) (EVar "name")) (EVar "site"))) (EVar "clauses"))))
(DTypeSig false "letClauseFindings" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "letClauseFindings" ((PVar "env") (PVar "name") (PVar "site") (PCon "FunClause" PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "walkBody") (EVar "env")) (EVar "name")) (EApp (EVar "Some") (EVar "site"))) (EVar "body")))
(DTypeSig false "groupFindings" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "groupFindings" ((PVar "env") (PVar "name") (PVar "clauses") (PVar "loc")) (EMatch (ETuple (EApp (EVar "init") (EVar "clauses")) (EApp (EVar "last") (EVar "clauses"))) (arm (PTuple (PCon "Some" (PVar "initCs")) (PCon "Some" (PCon "FunClause" (PVar "pats") (PVar "body")))) () (EIf (EBinOp "&&" (EApp (EApp (EVar "allList") (EVar "irrefutable")) (EVar "pats")) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "name")) (EVar "body")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "firstPosition") (EVar "env")) (EVar "name")) (EVar "loc")) (EVar "initCs")) (EVar "pats")) (EVar "body")) (EListLit))) (arm PWild () (EListLit))))
(DTypeSig false "firstPosition" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "firstPosition" ((PVar "env") (PVar "name") (PVar "loc") (PVar "initCs") (PVar "pats") (PVar "body")) (EBlock (DoLet false false (PVar "found") (EApp (EApp (EVar "findMap") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "positionFinding") (EVar "env")) (EVar "name")) (EVar "loc")) (EVar "initCs")) (EVar "pats")) (EVar "body"))) (EApp (EVar "positionsOf") (EVar "pats")))) (DoExpr (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "found")))))
(DTypeSig false "positionsOf" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "positionsOf" ((PVar "pats")) (ERangeList (ELit (LInt 0)) (EApp (EVar "listLen") (EVar "pats")) false))
(DTypeSig false "positionFinding" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Finding")))))))))))
(DFunDef false "positionFinding" ((PVar "env") (PVar "name") (PVar "loc") (PVar "initCs") (PVar "pats") (PVar "body") (PVar "k")) (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "pats")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "p")) () (EBlock (DoLet false false (PVar "ctorClauses") (EApp (EApp (EVar "filterList") (EApp (EVar "hasCtorAt") (EVar "k"))) (EVar "initCs"))) (DoLet false false (PVar "working") (EApp (EApp (EVar "filterList") (EApp (EVar "clauseWorks") (EVar "name"))) (EVar "ctorClauses"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "working")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "wildAt") (EVar "p")) (EVar "body")) (EApp (EVar "varsOfPats") (EVar "pats")))) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "clauseRecurses") (EVar "name")) (EVar "k"))) (EVar "working"))) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "report") (EVar "env")) (EVar "name")) (EVar "loc")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "ctorsAt") (EVar "k"))) (EVar "ctorClauses")))) (EVar "None")))))))
(DTypeSig false "hasCtorAt" (TyFun (TyCon "Int") (TyFun (TyCon "FunClause") (TyCon "Bool"))))
(DFunDef false "hasCtorAt" ((PVar "k") (PVar "c")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EVar "ctorsAt") (EVar "k")) (EVar "c"))))
(DTypeSig false "ctorsAt" (TyFun (TyCon "Int") (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ctorsAt" ((PVar "k") (PCon "FunClause" (PVar "ps") PWild)) (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "ps")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "ctorsOfPat") (EVar "p"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "clauseWorks" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyCon "Bool"))))
(DFunDef false "clauseWorks" ((PVar "name") (PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "not") (EApp (EApp (EVar "forwards") (EVar "name")) (EVar "body"))))
(DTypeSig false "clauseRecurses" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "FunClause") (TyCon "Bool")))))
(DFunDef false "clauseRecurses" ((PVar "name") (PVar "k") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "ps")) (arm (PCon "Some" (PVar "p")) () (EApp (EApp (EApp (EVar "reachesSubterm") (EVar "name")) (EVar "p")) (EVar "body"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "forwards" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "forwards" ((PVar "name") (PVar "e")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isVar") (EVar "name")) (EVar "hd")) (EApp (EVar "isNonEmptyL") (EVar "args"))) (EApp (EApp (EVar "allList") (EVar "isAVar")) (EVar "args"))))))
(DTypeSig false "isAVar" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isAVar" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "varsOfPats" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "varsOfPats" ((PVar "pats")) (EApp (EApp (EDictApp "flatMap") (EVar "varOfPat")) (EVar "pats")))
(DTypeSig false "varOfPat" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "varOfPat" ((PCon "PVar" (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "varOfPat" (PWild) (EListLit))
(DTypeSig false "irrefutable" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "irrefutable" ((PCon "PWild")) (EVar "True"))
(DFunDef false "irrefutable" ((PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "irrefutable" (PWild) (EVar "False"))
(DTypeSig false "matchFindings" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "matchFindings" ((PVar "env") (PVar "name") (PVar "loc") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EApp (EApp (EVar "matchArms") (EVar "env")) (EVar "name")) (EVar "loc")) (EVar "scrut")) (EVar "arms")))
(DFunDef false "matchFindings" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "matchArms" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "matchArms" ((PVar "env") (PVar "name") (PVar "loc") (PVar "scrut") (PVar "arms")) (EMatch (ETuple (EApp (EVar "init") (EVar "arms")) (EApp (EVar "last") (EVar "arms"))) (arm (PTuple (PCon "Some" (PVar "initArms")) (PCon "Some" (PCon "Arm" (PVar "p") (PVar "guards") (PVar "body")))) () (EBlock (DoLet false false (PVar "ctorArms") (EApp (EApp (EVar "filterList") (EVar "armHasCtor")) (EVar "initArms"))) (DoLet false false (PVar "working") (EApp (EApp (EVar "filterList") (EApp (EVar "armWorks") (EVar "name"))) (EVar "ctorArms"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "guards")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "working")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "wildAt") (EVar "p")) (EVar "body")) (EBinOp "++" (EApp (EVar "scrutVar") (EVar "scrut")) (EApp (EVar "varOfPat") (EVar "p"))))) (EApp (EApp (EVar "anyList") (EApp (EVar "armRecurses") (EVar "name"))) (EVar "working"))) (EApp (EApp (EApp (EApp (EVar "report") (EVar "env")) (EVar "name")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "body"))) (EVar "loc"))) (EApp (EApp (EDictApp "flatMap") (EVar "armCtors")) (EVar "ctorArms"))) (EListLit)) (EListLit))))) (arm PWild () (EListLit))))
(DTypeSig false "armHasCtor" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armHasCtor" ((PVar "arm")) (EApp (EVar "isNonEmptyL") (EApp (EVar "armCtors") (EVar "arm"))))
(DTypeSig false "armCtors" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "armCtors" ((PCon "Arm" (PVar "p") PWild PWild)) (EApp (EVar "ctorsOfPat") (EVar "p")))
(DTypeSig false "armWorks" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armWorks" ((PVar "name") (PCon "Arm" PWild PWild (PVar "body"))) (EApp (EVar "not") (EApp (EApp (EVar "forwards") (EVar "name")) (EVar "body"))))
(DTypeSig false "armRecurses" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armRecurses" ((PVar "name") (PCon "Arm" (PVar "p") PWild (PVar "body"))) (EApp (EApp (EApp (EVar "reachesSubterm") (EVar "name")) (EVar "p")) (EVar "body")))
(DTypeSig false "reachesSubterm" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "reachesSubterm" ((PVar "name") (PVar "p") (PVar "body")) (EBinOp "&&" (EApp (EApp (EVar "mentionsVar") (EVar "name")) (EVar "body")) (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EApp (EVar "mentionsVar") (EVar "v")) (EVar "body")))) (EApp (EVar "patBoundNames") (EVar "p")))))
(DTypeSig false "scrutVar" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "scrutVar" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "v")) () (EListLit (EVar "v"))) (arm PWild () (EListLit))))
(DTypeSig false "ctorsOfPat" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ctorsOfPat" ((PCon "PCon" (PVar "n") PWild)) (EListLit (EApp (EVar "lastSegment") (EVar "n"))))
(DFunDef false "ctorsOfPat" ((PCon "PRec" (PVar "n") PWild PWild)) (EListLit (EApp (EVar "lastSegment") (EVar "n"))))
(DFunDef false "ctorsOfPat" ((PCon "PAs" PWild PWild PWild (PVar "p"))) (EApp (EVar "ctorsOfPat") (EVar "p")))
(DFunDef false "ctorsOfPat" ((PCon "PAnn" (PVar "p") PWild)) (EApp (EVar "ctorsOfPat") (EVar "p")))
(DFunDef false "ctorsOfPat" ((PCon "POr" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "ctorsOfPat")) (EVar "ps")))
(DFunDef false "ctorsOfPat" (PWild) (EListLit))
(DTypeSig false "wildAt" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "wildAt" ((PCon "PWild") (PVar "body") (PVar "inputs")) (EApp (EApp (EVar "constantOrInput") (EVar "inputs")) (EVar "body")))
(DFunDef false "wildAt" ((PCon "PVar" (PVar "n") PWild PWild) (PVar "body") (PVar "inputs")) (EBinOp "&&" (EApp (EApp (EVar "constantOrInput") (EVar "inputs")) (EVar "body")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "startsWith") (ELit (LString "_"))) (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "n")) (EVar "body")))) (EApp (EApp (EVar "isVar") (EVar "n")) (EVar "body")))))
(DFunDef false "wildAt" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "isVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isVar" ((PVar "n") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "v")) () (EBinOp "==" (EVar "v") (EVar "n"))) (arm PWild () (EVar "False"))))
(DTypeSig false "constantOrInput" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "constantOrInput" ((PVar "inputs") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "ENumLit" PWild PWild PWild) () (EVar "True")) (arm (PCon "EWideLit" PWild PWild PWild PWild) () (EVar "True")) (arm (PCon "EVar" (PVar "v")) () (EBinOp "||" (EApp (EVar "isCtorName") (EVar "v")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "v")))) (EVar "inputs")))) (arm (PCon "EListLit" (PVar "es")) () (EApp (EApp (EVar "allList") (EApp (EVar "constantOrInput") (EListLit))) (EVar "es"))) (arm (PCon "ETuple" (PVar "es")) () (EApp (EApp (EVar "allList") (EApp (EVar "constantOrInput") (EVar "inputs"))) (EVar "es"))) (arm (PCon "EUnOp" (PLit (LString "-")) (PVar "x") PWild) () (EApp (EApp (EVar "constantOrInput") (EListLit)) (EVar "x"))) (arm (PCon "EApp" PWild PWild) () (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EBinOp "&&" (EApp (EVar "ctorHead") (EVar "hd")) (EApp (EApp (EVar "allList") (EApp (EVar "constantOrInput") (EListLit))) (EVar "args")))))) (arm PWild () (EVar "False"))))
(DTypeSig false "ctorHead" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "ctorHead" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "v")) () (EApp (EVar "isCtorName") (EVar "v"))) (arm PWild () (EVar "False"))))
(DTypeSig false "report" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "report" ((PVar "env") (PVar "name") (PVar "loc") (PVar "named")) (EMatch (EApp (EApp (EVar "findMap") (EApp (EVar "sumOf") (EVar "env"))) (EVar "named")) (arm (PCon "None") () (EListLit (EApp (EApp (EVar "finding") (EVar "loc")) (EApp (EVar "unknownMessage") (EVar "name"))))) (arm (PCon "Some" (PTuple (PVar "ty") (PVar "ctors"))) () (EBlock (DoLet false false (PVar "swallowed") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EApp (EVar "fst") (EVar "c"))))) (EVar "named"))))) (EVar "ctors"))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "c")) (EBinOp ">=" (EApp (EVar "snd") (EVar "c")) (ELit (LInt 1))))) (EVar "swallowed")) (EListLit (EApp (EApp (EVar "finding") (EVar "loc")) (EApp (EApp (EApp (EVar "swallowMessage") (EVar "name")) (EVar "ty")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "swallowed"))))) (EListLit)))))))
(DTypeSig false "finding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "finding" ((PVar "loc") (PVar "message")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameWalkerWildcard")) (fa "message" (EVar "message")) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "swallowMessage" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "swallowMessage" ((PVar "name") (PVar "ty") (PVar "swallowed")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` recurses over `"))) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString "` but its final wildcard swallows "))) (EApp (EMethodRef "display") (EApp (EVar "countText") (EApp (EVar "listLen") (EVar "swallowed"))))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "swallowed")))) (ELit (LString ") without recursing; name them in an or-pattern, or recurse"))))
(DTypeSig false "unknownMessage" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unknownMessage" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` recurses over constructor patterns but its final wildcard swallows an unknown number of constructors without recursing; name them in an or-pattern, or recurse"))))
(DTypeSig false "countText" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "countText" ((PLit (LInt 1))) (ELit (LString "1 constructor")))
(DFunDef false "countText" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " constructors"))))
(DTypeSig false "sumOf" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "sumOf" ((PCon "Env" (PVar "ix") (PVar "decls")) (PVar "c")) (EMatch (EApp (EApp (EVar "findMap") (EApp (EVar "declSum") (EVar "c"))) (EVar "decls")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EApp (EApp (EVar "indexSum") (EVar "ix")) (EVar "c")))))
(DTypeSig false "declSum" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "declSum" ((PVar "c") (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) true)) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EBinOp "==" (EApp (EVar "variantName") (EVar "v")) (EVar "c")))) (EVar "vs")) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "variantArity")) (EVar "vs")))) (EVar "None")))
(DFunDef false "declSum" ((PVar "c") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declSum") (EVar "c")) (EVar "d")))
(DFunDef false "declSum" (PWild PWild) (EVar "None"))
(DTypeSig false "variantName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "variantArity" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "variantArity" ((PCon "Variant" (PVar "n") (PCon "ConPos" (PVar "tys")))) (ETuple (EVar "n") (EApp (EVar "listLen") (EVar "tys"))))
(DFunDef false "variantArity" ((PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fields") PWild))) (ETuple (EVar "n") (EApp (EVar "listLen") (EVar "fields"))))
(DTypeSig false "indexSum" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "indexSum" ((PVar "ix") (PVar "c")) (EMatch (ETuple (EApp (EApp (EVar "filterList") (EVar "isCtorRow")) (EApp (EApp (EApp (EVar "projectRowsNamed") (EVar "ix")) (EVar "NsValue")) (EVar "c"))) (EApp (EApp (EVar "filterList") (EVar "isCtorRow")) (EApp (EApp (EApp (EVar "stdlibRowsNamed") (EVar "ix")) (EVar "NsValue")) (EVar "c")))) (arm (PTuple (PList (PVar "r")) (PList)) () (EApp (EVar "Some") (EApp (EApp (EVar "siblingsIn") (EVar "r")) (EApp (EVar "projectRows") (EVar "ix"))))) (arm (PTuple (PList) (PList (PVar "r"))) () (EApp (EVar "Some") (EApp (EApp (EVar "siblingsIn") (EVar "r")) (EApp (EVar "stdlibRows") (EVar "ix"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "siblingsIn" (TyFun (TyCon "IndexRow") (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "siblingsIn" ((PVar "r") (PVar "rows")) (ETuple (EFieldAccess (EVar "r") "ixrParent") (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (ETuple (EFieldAccess (EVar "x") "ixrName") (EFieldAccess (EVar "x") "ixrArity")))) (EApp (EApp (EVar "filterList") (EApp (EVar "siblingOf") (EVar "r"))) (EVar "rows")))))
(DTypeSig false "isCtorRow" (TyFun (TyCon "IndexRow") (TyCon "Bool")))
(DFunDef false "isCtorRow" ((PVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "ixrKind") (EVar "RkCtor")))
(DTypeSig false "siblingOf" (TyFun (TyCon "IndexRow") (TyFun (TyCon "IndexRow") (TyCon "Bool"))))
(DFunDef false "siblingOf" ((PVar "r") (PVar "x")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "x") "ixrKind") (EVar "RkCtor")) (EBinOp "==" (EFieldAccess (EVar "x") "ixrModule") (EFieldAccess (EVar "r") "ixrModule"))) (EBinOp "==" (EFieldAccess (EVar "x") "ixrParent") (EFieldAccess (EVar "r") "ixrParent"))))
