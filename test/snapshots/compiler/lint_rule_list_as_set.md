# META
source_lines=646
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
--   `p ++ e`, `e ++ p`, a name a `let` in that clause binds to one of those, or
--   a call of a growing helper (below) on `p`;
-- * the accumulator parameter of a fold lambda (the folds `lint_recursion`
--   knows) whose body returns the accumulator grown in a tail position.
--
-- A membership call is a call of one of the names above, or a full-arity call
-- of a hand-rolled membership function of the file: a top-level function whose
-- signature returns `Bool` or `Option`, which compares (`==` or a membership
-- name), and whose every self-call passes the tail of a `h :: t` parameter
-- pattern at one position and every other parameter unchanged.
--
-- One hop through a helper, a top-level function of the same file, is read.  A
-- helper membership-tests a parameter when its own body makes a membership call
-- on that parameter; a full-arity call of it in the loop is reported at the
-- call.  A helper grows a parameter when its body returns it grown in a tail
-- position; a self-call that passes such a call grows the container.  A helper
-- of a helper is not read, nor a helper in another module or a `where` group.
--
-- Growth is what makes the test a loop cost: a container that only shrinks or
-- is passed on unchanged is not reported.  Not covered: a container held in a
-- `Ref`, a record field or a top-level table; mutual recursion; a tuple
-- accumulator; `any (== x) xs`; a hand-rolled walk that returns anything other
-- than `Bool` or `Option`; a `let` alias of an alias; a test or prop body; a
-- `*_test.mdk` file, whose loops run over fixed test data.  A file that names
-- none of `contains`, `elem` and `lookup` is not read.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{
  Arm(..),
  Decl(..),
  DoStmt(..),
  Expr(..),
  GuardArm(..),
  Loc,
  Pat(..),
  Ty(..),
  orElseLoc,
}
import frontend.ast_walk.{ExprKind(..), childExprs, stmtExprs}
import frontend.parser.{Positions(..)}
import list.{findMap, get, indexed, last, nub}
import map as M
import string.{contains, endsWith}
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
  ArgRole(..),
  Owner(..),
  SelfCall(..),
  foldAccIndex,
  letOwners,
  selfCalls,
  spineOf,
}
import tools.lint_scope.{BinderKind(..), FileScopes, binderOf}
import tools.lint_shared.{
  appArgsOf, firstLoc, ruleNameListAsSet, tyHeadName, unwrapLoc, varSite
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
        "A membership test on a `List` (`contains`, `elem`, `notElem`, `lookupAssoc`, `lookup`, or a hand-rolled function of the file that walks a list and returns `Bool` or `Option`) walks the list. When a loop grows the list and tests it on every step, the loop does work quadratic in the number of steps. The rule reports a membership test whose container is a parameter that a self-call of the same function passes grown (`x :: seen`, `seen ++ xs`, `xs ++ seen`, a `let` bound to one of those, or a helper of the file that returns its argument grown), and a test on the accumulator of a fold lambda that returns the accumulator grown. A test made by a helper of the same file that the loop calls with the list is reported at the call. A container that is only passed on unchanged or shrinks is not reported, nor is one held in a `Ref`, a record field or a top-level table, nor a test two helpers away. A partial application and a call to a different function (mutual recursion) are not self-calls. `*_test.mdk` files are not checked.\n\nKeep the names in a `Set` (or the pairs in a `Map`) beside the list, or build the set once before the loop. A list whose length is small and fixed can carry a `-- lint-disable-next-line rule-list-as-set` with the bound as its reason.\n\nBefore:\n  go seen (x :: xs) = if contains x seen then go seen xs else go (x :: seen) xs\nAfter:\n  go seen (x :: xs) = if has x seen then go seen xs else go (insert x seen) xs  -- with `seen : Set String`",
      category = Perf,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [NeedsScopes],
    }
    ruleListAsSet
    None

ruleListAsSet : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleListAsSet _ path facts _ decls
  | endsWith "_test.mdk" path = []
  | any (w => contains w facts.ffSrc) mentions =
    let scopes = factScopes facts
    let defs = topDefs decls
    let rd = Reader scopes (helperTable scopes decls defs)
    [
      OnDecl (declFindings rd defs),
      OnExpr [KLetGroup] (localFindings rd),
      OnExpr [KApp] (foldFindings rd),
    ]
  | otherwise = []

mentions : List String
mentions = ["contains", "elem", "lookup"]

-- The scope model and the helper table of one file.
data Reader = Reader FileScopes (M.Map String Helper)

-- ── helpers ──────────────────────────────────────────────────────────────────

-- What one top-level function of the file does with its parameters: its arity,
-- the position it walks when it is a hand-rolled membership function, the
-- positions its body membership-tests (each with the membership callee), and
-- the positions it returns grown.
data Helper = Helper Int (Option Int) (List (Int, String)) (List Int)

-- One clause of a top-level function: its site, parameters, body and the
-- candidate membership calls of the body, collected once.
data Def = Def Loc (List Pat) Expr (List Call)

-- The clauses of every top-level function, by name.
topDefs : List Decl -> M.Map String (List Def)
topDefs decls =
  let heads = flatMap topHead decls
  let names = M.fromList (map ((n, _, _, _) => (n, ())) heads)
  fold
    (m (n, l, ps, body) =>
      M.insertWith (++) n [Def l ps body (callsIn names None body [])] m)
    empty
    heads

topHead : Decl -> List (String, Loc, List Pat, Expr)
topHead (DFunDef _ n ps body l _) = [(n, l, ps, body)]
topHead (DAttrib _ d) = topHead d
topHead _ = []

-- The table is built in two steps so that a helper's own facts read only
-- direct membership calls and hand-rolled membership functions: one hop.
helperTable : FileScopes ->
  List Decl ->
  M.Map String (List Def) ->
  M.Map String Helper
helperTable scopes decls defs =
  let sigs = M.fromList (flatMap sigOf decls)
  let entries = M.entries defs
  let searches = M.fromList (flatMap (searchEntry scopes sigs) entries)
  let rd = Reader scopes searches
  M.fromList (flatMap (helperEntry rd searches) entries)

sigOf : Decl -> List (String, Ty)
sigOf (DTypeSig _ name ty _) = [(name, ty)]
sigOf (DAttrib _ d) = sigOf d
sigOf _ = []

helperEntry : Reader ->
  M.Map String Helper ->
  (String, List Def) ->
  List (String, Helper)
helperEntry (rd@(Reader scopes _)) searches (name, ds) =
  let search = do
    (Helper _ k _ _) <- M.get name searches
    k
  let tested =
    nub
      (flatMap
        ((Def _ ps _ calls) =>
          map
            ((Probe _ callee _ _, j) => (j, callee))
            (paramProbes rd (Some name) ps calls))
        ds)
  let grown = nub (flatMap (clauseReturnsGrown scopes) ds)
  match (search, tested, grown)
    (None, [], []) => []
    _ => [(name, Helper (arityOf ds) search tested grown)]

arityOf : List Def -> Int
arityOf ((Def _ ps _ _) :: _) = length ps
arityOf [] = 0

-- The parameter positions a clause returns grown in a tail position.
clauseReturnsGrown : FileScopes -> Def -> List Int
clauseReturnsGrown scopes (Def _ ps body _) =
  flatMap
    ((j, p) => match wholeParam p
      Some param =>
        if tailGrows (Reader scopes empty) param body then [j] else []
      None => [])
    (indexed ps)

-- A hand-rolled membership function: its signature returns `Bool` or
-- `Option`, and at one position every self-call walks the tail of the list.
searchEntry : FileScopes ->
  M.Map String Ty ->
  (String, List Def) ->
  List (String, Helper)
searchEntry scopes sigs (name, ds) = match M.get name sigs
  Some ty if returnsTest ty
    && any
      ((Def _ _ body _) => compares body)
      ds => match searchPos scopes name ds
    Some k => [(name, Helper (arityOf ds) (Some k) [] [])]
    None => []
  _ => []

returnsTest : Ty -> Bool
returnsTest (TyFun _ r) = returnsTest r
returnsTest (TyConstrained _ t) = returnsTest t
returnsTest t = match tyHeadName t
  Some "Bool" => True
  Some "Option" => True
  _ => False

compares : Expr -> Bool
compares e = match unwrapLoc e
  EBinOp "==" _ _ _ => True
  EVar n => isMembership (lastSegment n)
  e2 => any compares (childExprs e2)

-- The first position at which some clause binds a `h :: t` pattern and every
-- self-call passes that clause's `t`, with every other parameter unchanged.
searchPos : FileScopes -> String -> List Def -> Option Int
searchPos scopes name ds = match flatMap (defSelfCalls scopes name) ds
  [] => None
  calls =>
    findMap
      (k => if all (walksAt scopes k) calls then Some k else None)
      (nub (flatMap consPositions ds))

defSelfCalls : FileScopes -> String -> Def -> List (List Pat, SelfCall)
defSelfCalls scopes name (Def _ ps body _) =
  map (c => (ps, c)) (selfCalls scopes (Owner name ps None) body)

consPositions : Def -> List Int
consPositions (Def _ ps _ _) =
  flatMap ((j, p) => if isSome (consTail p) then [j] else []) (indexed ps)

consTail : Pat -> Option Param
consTail (PCons _ (PVar t l _)) = Some (Param t l)
consTail _ = None

walksAt : FileScopes -> Int -> (List Pat, SelfCall) -> Bool
walksAt scopes k (ps, SelfCall _ call roles) =
  let tailPassed = match (get k ps, get k (appArgsOf call))
    (Some p, Some a) => match consTail p
      Some t => isParam scopes t a
      None => False
    _ => False
  tailPassed && all ((j, r) => j == k || r == Unchanged j) (indexed roles)

-- The helper a call's head names, when it resolves to a top-level function of
-- the file other than `self` and the call passes its full arity.
topHelper : Reader -> Option String -> Expr -> Int -> Option Helper
topHelper (Reader scopes hs) self hd n = match unwrapLoc hd
  EVar name => match M.get name hs
    Some (h@(Helper arity _ _ _)) if arity == n && Some name /= self =>
      if bindsTop scopes name hd then Some h else None
    _ => None
  _ => None

bindsTop : FileScopes -> String -> Expr -> Bool
bindsTop scopes name hd = match varSite hd
  Some site => match binderOf scopes site
    Some b => b.binderKind == BTopLevel && b.binderName == name
    None => False
  None => False

-- ── membership tests ─────────────────────────────────────────────────────────

-- A call that may be a membership test: its span, the head's name, the head
-- and the arguments.  The head is a membership name or a top-level function of
-- the file; arity and scope are checked when the call is read.
data Call = Call (Option Loc) String Expr (List Expr)

-- A membership call: its span, the membership callee, the helper of the file
-- the loop calls when the test is made there, and the container argument.
data Probe = Probe (Option Loc) String (Option String) Expr

-- The candidate calls in `e`, nested bodies included, onto `acc`.  `tops`
-- holds the names of the file's top-level functions.
callsIn : M.Map String v -> Option Loc -> Expr -> List Call -> List Call
callsIn tops _ (ELoc l inner) acc = callsIn tops (Some l) inner acc
callsIn tops loc (EApp f a) acc = match spineOf f [a]
  (hd, args) =>
    fold
      (acc2 c => callsIn tops loc c acc2)
      (callsIn tops loc hd (candidate tops loc hd args acc))
      args
callsIn tops loc (e@(EBinOp "|>" l r _)) acc = match spineOf r []
  (hd, args) =>
    fold
      (acc2 c => callsIn tops loc c acc2)
      (candidate tops loc hd (args ++ [l]) acc)
      (childExprs e)
callsIn tops loc e acc =
  fold (acc2 c => callsIn tops loc c acc2) acc (childExprs e)

candidate : M.Map String v ->
  Option Loc ->
  Expr ->
  List Expr ->
  List Call ->
  List Call
candidate tops loc hd args acc = match unwrapLoc hd
  EVar n if isSome (membershipName n) || M.has n tops =>
    Call (orElseLoc (firstLoc hd) loc) n hd args :: acc
  _ => acc

-- Every membership call in `e`, nested bodies included: a container resolves
-- to its own binder, so a test inside a nested loop is matched to the loop
-- whose parameter it tests.
probesIn : Reader -> Expr -> List Probe
probesIn (rd@(Reader _ hs)) e =
  flatMap (callProbes rd None) (callsIn hs None e [])

-- The membership tests a call makes.  `self` is the top-level function being
-- read, whose own calls are self-calls, not helper calls.
callProbes : Reader -> Option String -> Call -> List Probe
callProbes rd self (Call site n hd args) = match membershipName n
  Some m => match args
    [_, c] => [Probe site m None c]
    _ => []
  None => match topHelper rd self hd (length args)
    Some h => helperProbes site n h args
    None => []

helperProbes : Option Loc -> String -> Helper -> List Expr -> List Probe
helperProbes site n (Helper _ search tested _) args =
  let searched = match search
    Some k => match get k args
      Some c => [Probe site n None c]
      None => []
    None => []
  searched
    ++ flatMap
      ((j, callee) => match get j args
        Some c => [Probe site callee (Some n) c]
        None => [])
      tested

-- The membership name a callee spells, unqualified: a qualified call such as `L.lookup` parses as a field access and never reaches this function.
membershipName : String -> Option String
membershipName n
  | isMembership n = Some n
  | contains "." n && isMembership (lastSegment n) = Some (lastSegment n)
  | otherwise = None

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

-- The membership tests among `calls` whose container is a whole parameter,
-- with the parameter's position.
paramProbes : Reader ->
  Option String ->
  List Pat ->
  List Call ->
  List (Probe, Int)
paramProbes (rd@(Reader scopes _)) self ps calls =
  match flatMap (callProbes rd self) calls
    [] => []
    probes => flatMap (probeParam scopes ps) probes

probeParam : FileScopes -> List Pat -> Probe -> List (Probe, Int)
probeParam scopes ps (probe@(Probe _ _ _ c)) =
  match findMap (atParam scopes c) (indexed ps)
    Some j => [(probe, j)]
    None => []

atParam : FileScopes -> Expr -> (Int, Pat) -> Option Int
atParam scopes c (j, p) = do
  param <- wholeParam p
  if isParam scopes param c then Some j else None

-- ── growth ───────────────────────────────────────────────────────────────────

-- Whether `e` is the parameter grown by `::`, `++` or a growing helper, or a
-- name a `let` of the clause (`lets`, by binder span) binds to such an
-- expression.
grows : Reader -> List (Loc, Expr) -> Param -> Expr -> Bool
grows (rd@(Reader scopes _)) lets param e = match unwrapLoc e
  EVar _ => match aliasOf scopes lets e
    Some rhs => grownDirect rd param rhs
    None => False
  _ => grownDirect rd param e

grownDirect : Reader -> Param -> Expr -> Bool
grownDirect (rd@(Reader scopes _)) param e = match unwrapLoc e
  EBinOp "::" _ t _ => isParam scopes param t || grownDirect rd param t
  EBinOp "++" a b _ =>
    isParam scopes param a
      || isParam scopes param b
      || grownDirect rd param a
      || grownDirect rd param b
  EIf _ t f => grownDirect rd param t || grownDirect rd param f
  EApp _ _ => helperGrows rd param e
  ELit _ | EVar _ | ELam _ _ | ELet _ _ _ _ _ | EMatch _ _ | EUnOp _ _ _ | EInfix _ _ _ | EFieldAccess _ _ _ | ETuple _ | EListLit _ | EArrayLit _ | ERangeList _ _ _ | ERangeArray _ _ _ | ESlice _ _ _ _ | ELetGroup _ _ | ESection _ | EIndex _ _ | EAnnot _ _ | EHeadAnnot _ _ | EBlock _ | EDo _ _ | EStringInterp _ | EGuards _ | ERecordCreate _ _ | ERecordUpdate _ _ _ | EVariantUpdate _ _ _ | EMapLit _ _ | ESetLit _ _ | EAsPat _ _ | EOrPat _ | EMethodRef _ | EDictApp _ | EVarAt _ _ | EVarId _ _ | EMethodAt _ _ _ | EDictAt _ _ | ELoc _ _ | EDoOrigin _ _ | ENumLit _ _ _ | EWideLit _ _ _ _ | EBinOp _ _ _ _ =>
    False

-- Whether `e` is a full-arity call of a helper that returns, grown, the
-- argument it is passed the parameter at.
helperGrows : Reader -> Param -> Expr -> Bool
helperGrows (rd@(Reader scopes _)) param e = match spineOf e []
  (hd, args) => match topHelper rd None hd (length args)
    Some (Helper _ _ _ grown) =>
      any
        (j => match get j args
          Some a => isParam scopes param a
          None => False)
        grown
    None => False

aliasOf : FileScopes -> List (Loc, Expr) -> Expr -> Option Expr
aliasOf scopes lets e = do
  site <- varSite e
  do
    b <- binderOf scopes site
    findMap ((l, rhs) => if l == b.binderSpan then Some rhs else None) lets

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
grownPositions : Reader ->
  String ->
  Option Loc ->
  List (List Pat, Expr) ->
  List Int
grownPositions rd name site clauses = flatMap (clauseGrown rd name site) clauses

clauseGrown : Reader -> String -> Option Loc -> (List Pat, Expr) -> List Int
clauseGrown (rd@(Reader scopes _)) name site (ps, body) =
  match selfCalls scopes (Owner name ps site) body
    [] => []
    calls =>
      let lets = letsIn body
      flatMap (callGrown rd lets ps) calls

callGrown : Reader -> List (Loc, Expr) -> List Pat -> SelfCall -> List Int
callGrown rd lets ps (SelfCall _ call _) =
  flatMap (argGrown rd lets ps) (indexed (appArgsOf call))

argGrown : Reader -> List (Loc, Expr) -> List Pat -> (Int, Expr) -> List Int
argGrown rd lets ps (j, a) = match get j ps
  Some p => match wholeParam p
    Some param => if grows rd lets param a then [j] else []
    None => []
  None => []

-- ── loops ────────────────────────────────────────────────────────────────────

-- One clause of a top-level function.  The growth is read over every clause of
-- the function, since a scope walk tests in one clause and grows in another.
-- Test and prop bodies run over fixed data and are not checked.
declFindings : Reader -> M.Map String (List Def) -> Ctx -> Decl -> List Finding
declFindings rd defs ctx d =
  flatMap (headFindings rd defs ctx.ctxSpan) (topHead d)

headFindings : Reader ->
  M.Map String (List Def) ->
  Option Loc ->
  (String, Loc, List Pat, Expr) ->
  List Finding
headFindings rd defs fallback (name, site, ps, _) =
  let ds = M.findWithDefault [] name defs
  match findMap ((Def l _ _ calls) => if l == site then Some calls else None) ds
    Some calls => match paramProbes rd (Some name) ps calls
      [] => []
      probes =>
        reportGrown
          fallback
          (grownPositions rd name None (map defClause ds))
          probes
    None => []

defClause : Def -> (List Pat, Expr)
defClause (Def _ ps body _) = (ps, body)

-- The `where`/`let` loops of one group, each read over all of its clauses.
localFindings : Reader -> Ctx -> Expr -> List Finding
localFindings rd ctx e
  | ctx.ctxInTest = []
  | otherwise = match letOwners e
    [] => []
    owners => flatMap (ownerFindings rd ctx.ctxSpan owners) owners

ownerFindings : Reader ->
  Option Loc ->
  List (Owner, Expr) ->
  (Owner, Expr) ->
  List Finding
ownerFindings (rd@(Reader _ hs)) fallback owners (Owner name ps site, body) =
  match paramProbes rd None ps (callsIn hs None body [])
    [] => []
    probes =>
      reportGrown
        fallback
        (grownPositions rd name site (sameOwner name site owners))
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
foldFindings : Reader -> Ctx -> Expr -> List Finding
foldFindings rd ctx e
  | ctx.ctxInTest = []
  | otherwise = match e
    EApp _ a => match unwrapLoc a
      ELam ps body => match foldAccOf e ps
        Some acc =>
          if tailGrows rd acc body then
            map
              (probeFinding (orElseLoc (firstLoc e) ctx.ctxSpan))
              (accProbes rd acc body)
          else
            []
        None => []
      _ => []
    _ => []

-- The accumulator parameter of the lambda when the call's head is a fold.
foldAccOf : Expr -> List Pat -> Option Param
foldAccOf e ps = match spineOf e []
  (hd, _) => match unwrapLoc hd
    EVar n => do
      k <- foldAccIndex (lastSegment n)
      do
        p <- get k ps
        wholeParam p
    _ => None

accProbes : Reader -> Param -> Expr -> List Probe
accProbes (rd@(Reader scopes _)) acc body =
  filter ((Probe _ _ _ c) => isParam scopes acc c) (probesIn rd body)

-- Whether some tail position of `e` returns the accumulator grown.
tailGrows : Reader -> Param -> Expr -> Bool
tailGrows rd acc e = match unwrapLoc e
  EBinOp "::" _ _ _ => grownDirect rd acc e
  EBinOp "++" _ _ _ => grownDirect rd acc e
  EApp _ _ => grownDirect rd acc e
  EIf _ t f => tailGrows rd acc t || tailGrows rd acc f
  EMatch _ arms => any ((Arm _ _ b) => tailGrows rd acc b) arms
  EGuards arms => any ((GuardArm _ b) => tailGrows rd acc b) arms
  ELet _ _ _ _ body => tailGrows rd acc body
  ELetGroup _ body => tailGrows rd acc body
  EBlock stmts => match last stmts
    Some (DoExpr l) => tailGrows rd acc l
    _ => False
  ELit _ | EVar _ | ELam _ _ | EUnOp _ _ _ | EInfix _ _ _ | EFieldAccess _ _ _ | ETuple _ | EListLit _ | EArrayLit _ | ERangeList _ _ _ | ERangeArray _ _ _ | ESlice _ _ _ _ | ESection _ | EIndex _ _ | EAnnot _ _ | EHeadAnnot _ _ | EDo _ _ | EStringInterp _ | ERecordCreate _ _ | ERecordUpdate _ _ _ | EVariantUpdate _ _ _ | EMapLit _ _ | ESetLit _ _ | EAsPat _ _ | EOrPat _ | EMethodRef _ | EDictApp _ | EVarAt _ _ | EVarId _ _ | EMethodAt _ _ _ | EDictAt _ _ | ELoc _ _ | EDoOrigin _ _ | ENumLit _ _ _ | EWideLit _ _ _ _ | EBinOp _ _ _ _ =>
    False

-- ── findings ─────────────────────────────────────────────────────────────────

probeFinding : Option Loc -> Probe -> Finding
probeFinding fallback (Probe loc callee via c) = Finding {
  rule = ruleNameListAsSet,
  message = message callee via (containerName c),
  severity = SevWarning,
  loc = orElseLoc loc fallback,
  fix = None,
}

containerName : Expr -> String
containerName c = match unwrapLoc c
  EVar n => n
  _ => "the list"

message : String -> Option String -> String -> String
message callee None v =
  "`\{callee}` on `\{v}`, which this loop grows on every step, walks the whole list each time, so the loop is quadratic. \{fixFor callee}"
message callee (Some helper) v =
  "`\{helper}` tests `\{v}` with `\{callee}`, and this loop grows `\{v}` on every step, so each call walks the whole list and the loop is quadratic. \{fixFor callee}"

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
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "GuardArm" true) (mem "Loc" false) (mem "Pat" true) (mem "Ty" true) (mem "orElseLoc" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true) (mem "childExprs" false) (mem "stmtExprs" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "get" false) (mem "indexed" false) (mem "last" false) (mem "nub" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "endsWith" false))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "lastSegment" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "factScopes" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "ArgRole" true) (mem "Owner" true) (mem "SelfCall" true) (mem "foldAccIndex" false) (mem "letOwners" false) (mem "selfCalls" false) (mem "spineOf" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "BinderKind" true) (mem "FileScopes" false) (mem "binderOf" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "appArgsOf" false) (mem "firstLoc" false) (mem "ruleNameListAsSet" false) (mem "tyHeadName" false) (mem "unwrapLoc" false) (mem "varSite" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameListAsSet")) (fa "summary" (ELit (LString "a `List` a loop grows and membership-tests on every step: each test walks the whole list. Keep a `Set` or `Map` beside it, or build the set once"))) (fa "doc" (ELit (LString "A membership test on a `List` (`contains`, `elem`, `notElem`, `lookupAssoc`, `lookup`, or a hand-rolled function of the file that walks a list and returns `Bool` or `Option`) walks the list. When a loop grows the list and tests it on every step, the loop does work quadratic in the number of steps. The rule reports a membership test whose container is a parameter that a self-call of the same function passes grown (`x :: seen`, `seen ++ xs`, `xs ++ seen`, a `let` bound to one of those, or a helper of the file that returns its argument grown), and a test on the accumulator of a fold lambda that returns the accumulator grown. A test made by a helper of the same file that the loop calls with the list is reported at the call. A container that is only passed on unchanged or shrinks is not reported, nor is one held in a `Ref`, a record field or a top-level table, nor a test two helpers away. A partial application and a call to a different function (mutual recursion) are not self-calls. `*_test.mdk` files are not checked.\n\nKeep the names in a `Set` (or the pairs in a `Map`) beside the list, or build the set once before the loop. A list whose length is small and fixed can carry a `-- lint-disable-next-line rule-list-as-set` with the bound as its reason.\n\nBefore:\n  go seen (x :: xs) = if contains x seen then go seen xs else go (x :: seen) xs\nAfter:\n  go seen (x :: xs) = if has x seen then go seen xs else go (insert x seen) xs  -- with `seen : Set String`"))) (fa "category" (EVar "Perf")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleListAsSet")) (EVar "None")))
(DTypeSig false "ruleListAsSet" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleListAsSet" (PWild (PVar "path") (PVar "facts") PWild (PVar "decls")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "path")) (EListLit) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "w")) (EApp (EApp (EVar "contains") (EVar "w")) (EFieldAccess (EVar "facts") "ffSrc")))) (EVar "mentions")) (EBlock (DoLet false false (PVar "scopes") (EApp (EVar "factScopes") (EVar "facts"))) (DoLet false false (PVar "defs") (EApp (EVar "topDefs") (EVar "decls"))) (DoLet false false (PVar "rd") (EApp (EApp (EVar "Reader") (EVar "scopes")) (EApp (EApp (EApp (EVar "helperTable") (EVar "scopes")) (EVar "decls")) (EVar "defs")))) (DoExpr (EListLit (EApp (EVar "OnDecl") (EApp (EApp (EVar "declFindings") (EVar "rd")) (EVar "defs"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KLetGroup"))) (EApp (EVar "localFindings") (EVar "rd"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KApp"))) (EApp (EVar "foldFindings") (EVar "rd")))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "mentions" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mentions" () (EListLit (ELit (LString "contains")) (ELit (LString "elem")) (ELit (LString "lookup"))))
(DData Private "Reader" () ((variant "Reader" (ConPos (TyCon "FileScopes") (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyCon "Helper"))))) ())
(DData Private "Helper" () ((variant "Helper" (ConPos (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DData Private "Def" () ((variant "Def" (ConPos (TyCon "Loc") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Call"))))) ())
(DTypeSig false "topDefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Def")))))
(DFunDef false "topDefs" ((PVar "decls")) (EBlock (DoLet false false (PVar "heads") (EApp (EApp (EVar "flatMap") (EVar "topHead")) (EVar "decls"))) (DoLet false false (PVar "names") (EApp (EVar "M.fromList") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "n") PWild PWild PWild)) (ETuple (EVar "n") (ELit LUnit)))) (EVar "heads")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PTuple (PVar "n") (PVar "l") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "M.insertWith") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "++" (EVar "_a") (EVar "_b")))) (EVar "n")) (EListLit (EApp (EApp (EApp (EApp (EVar "Def") (EVar "l")) (EVar "ps")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "names")) (EVar "None")) (EVar "body")) (EListLit))))) (EVar "m")))) (EVar "empty")) (EVar "heads")))))
(DTypeSig false "topHead" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "topHead" ((PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") (PVar "l") PWild)) (EListLit (ETuple (EVar "n") (EVar "l") (EVar "ps") (EVar "body"))))
(DFunDef false "topHead" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topHead") (EVar "d")))
(DFunDef false "topHead" (PWild) (EListLit))
(DTypeSig false "helperTable" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Def"))) (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyCon "Helper"))))))
(DFunDef false "helperTable" ((PVar "scopes") (PVar "decls") (PVar "defs")) (EBlock (DoLet false false (PVar "sigs") (EApp (EVar "M.fromList") (EApp (EApp (EVar "flatMap") (EVar "sigOf")) (EVar "decls")))) (DoLet false false (PVar "entries") (EApp (EVar "M.entries") (EVar "defs"))) (DoLet false false (PVar "searches") (EApp (EVar "M.fromList") (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "searchEntry") (EVar "scopes")) (EVar "sigs"))) (EVar "entries")))) (DoLet false false (PVar "rd") (EApp (EApp (EVar "Reader") (EVar "scopes")) (EVar "searches"))) (DoExpr (EApp (EVar "M.fromList") (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "helperEntry") (EVar "rd")) (EVar "searches"))) (EVar "entries"))))))
(DTypeSig false "sigOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))
(DFunDef false "sigOf" ((PCon "DTypeSig" PWild (PVar "name") (PVar "ty") PWild)) (EListLit (ETuple (EVar "name") (EVar "ty"))))
(DFunDef false "sigOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "sigOf") (EVar "d")))
(DFunDef false "sigOf" (PWild) (EListLit))
(DTypeSig false "helperEntry" (TyFun (TyCon "Reader") (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyCon "Helper")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Def"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Helper")))))))
(DFunDef false "helperEntry" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "searches") (PTuple (PVar "name") (PVar "ds"))) (EBlock (DoLet false false (PVar "search") (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "M.get") (EVar "name")) (EVar "searches"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "Helper" PWild (PVar "k") PWild PWild) () (EVar "k")))))) (DoLet false false (PVar "tested") (EApp (EVar "nub") (EApp (EApp (EVar "flatMap") (ELam ((PCon "Def" PWild (PVar "ps") PWild (PVar "calls"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PCon "Probe" PWild (PVar "callee") PWild PWild) (PVar "j"))) (ETuple (EVar "j") (EVar "callee")))) (EApp (EApp (EApp (EApp (EVar "paramProbes") (EVar "rd")) (EApp (EVar "Some") (EVar "name"))) (EVar "ps")) (EVar "calls"))))) (EVar "ds")))) (DoLet false false (PVar "grown") (EApp (EVar "nub") (EApp (EApp (EVar "flatMap") (EApp (EVar "clauseReturnsGrown") (EVar "scopes"))) (EVar "ds")))) (DoExpr (EMatch (ETuple (EVar "search") (EVar "tested") (EVar "grown")) (arm (PTuple (PCon "None") (PList) (PList)) () (EListLit)) (arm PWild () (EListLit (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EVar "Helper") (EApp (EVar "arityOf") (EVar "ds"))) (EVar "search")) (EVar "tested")) (EVar "grown")))))))))
(DTypeSig false "arityOf" (TyFun (TyApp (TyCon "List") (TyCon "Def")) (TyCon "Int")))
(DFunDef false "arityOf" ((PCons (PCon "Def" PWild (PVar "ps") PWild PWild) PWild)) (EApp (EVar "length") (EVar "ps")))
(DFunDef false "arityOf" ((PList)) (ELit (LInt 0)))
(DTypeSig false "clauseReturnsGrown" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Def") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "clauseReturnsGrown" ((PVar "scopes") (PCon "Def" PWild (PVar "ps") (PVar "body") PWild)) (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "j") (PVar "p"))) (EMatch (EApp (EVar "wholeParam") (EVar "p")) (arm (PCon "Some" (PVar "param")) () (EIf (EApp (EApp (EApp (EVar "tailGrows") (EApp (EApp (EVar "Reader") (EVar "scopes")) (EVar "empty"))) (EVar "param")) (EVar "body")) (EListLit (EVar "j")) (EListLit))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "indexed") (EVar "ps"))))
(DTypeSig false "searchEntry" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyCon "Ty")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Def"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Helper")))))))
(DFunDef false "searchEntry" ((PVar "scopes") (PVar "sigs") (PTuple (PVar "name") (PVar "ds"))) (EMatch (EApp (EApp (EVar "M.get") (EVar "name")) (EVar "sigs")) (arm (PCon "Some" (PVar "ty")) ((GBool (EBinOp "&&" (EApp (EVar "returnsTest") (EVar "ty")) (EApp (EApp (EVar "any") (ELam ((PCon "Def" PWild PWild (PVar "body") PWild)) (EApp (EVar "compares") (EVar "body")))) (EVar "ds"))))) (EMatch (EApp (EApp (EApp (EVar "searchPos") (EVar "scopes")) (EVar "name")) (EVar "ds")) (arm (PCon "Some" (PVar "k")) () (EListLit (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EVar "Helper") (EApp (EVar "arityOf") (EVar "ds"))) (EApp (EVar "Some") (EVar "k"))) (EListLit)) (EListLit))))) (arm (PCon "None") () (EListLit)))) (arm PWild () (EListLit))))
(DTypeSig false "returnsTest" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "returnsTest" ((PCon "TyFun" PWild (PVar "r"))) (EApp (EVar "returnsTest") (EVar "r")))
(DFunDef false "returnsTest" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "returnsTest") (EVar "t")))
(DFunDef false "returnsTest" ((PVar "t")) (EMatch (EApp (EVar "tyHeadName") (EVar "t")) (arm (PCon "Some" (PLit (LString "Bool"))) () (EVar "True")) (arm (PCon "Some" (PLit (LString "Option"))) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "compares" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "compares" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "==")) PWild PWild PWild) () (EVar "True")) (arm (PCon "EVar" (PVar "n")) () (EApp (EVar "isMembership") (EApp (EVar "lastSegment") (EVar "n")))) (arm (PVar "e2") () (EApp (EApp (EVar "any") (EVar "compares")) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig false "searchPos" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Def")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "searchPos" ((PVar "scopes") (PVar "name") (PVar "ds")) (EMatch (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "defSelfCalls") (EVar "scopes")) (EVar "name"))) (EVar "ds")) (arm (PList) () (EVar "None")) (arm (PVar "calls") () (EApp (EApp (EVar "findMap") (ELam ((PVar "k")) (EIf (EApp (EApp (EVar "all") (EApp (EApp (EVar "walksAt") (EVar "scopes")) (EVar "k"))) (EVar "calls")) (EApp (EVar "Some") (EVar "k")) (EVar "None")))) (EApp (EVar "nub") (EApp (EApp (EVar "flatMap") (EVar "consPositions")) (EVar "ds")))))))
(DTypeSig false "defSelfCalls" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "Def") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "SelfCall")))))))
(DFunDef false "defSelfCalls" ((PVar "scopes") (PVar "name") (PCon "Def" PWild (PVar "ps") (PVar "body") PWild)) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (ETuple (EVar "ps") (EVar "c")))) (EApp (EApp (EApp (EVar "selfCalls") (EVar "scopes")) (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))) (EVar "body"))))
(DTypeSig false "consPositions" (TyFun (TyCon "Def") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "consPositions" ((PCon "Def" PWild (PVar "ps") PWild PWild)) (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "j") (PVar "p"))) (EIf (EApp (EVar "isSome") (EApp (EVar "consTail") (EVar "p"))) (EListLit (EVar "j")) (EListLit)))) (EApp (EVar "indexed") (EVar "ps"))))
(DTypeSig false "consTail" (TyFun (TyCon "Pat") (TyApp (TyCon "Option") (TyCon "Param"))))
(DFunDef false "consTail" ((PCon "PCons" PWild (PCon "PVar" (PVar "t") (PVar "l") PWild))) (EApp (EVar "Some") (EApp (EApp (EVar "Param") (EVar "t")) (EVar "l"))))
(DFunDef false "consTail" (PWild) (EVar "None"))
(DTypeSig false "walksAt" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Int") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "SelfCall")) (TyCon "Bool")))))
(DFunDef false "walksAt" ((PVar "scopes") (PVar "k") (PTuple (PVar "ps") (PCon "SelfCall" PWild (PVar "call") (PVar "roles")))) (EBlock (DoLet false false (PVar "tailPassed") (EMatch (ETuple (EApp (EApp (EVar "get") (EVar "k")) (EVar "ps")) (EApp (EApp (EVar "get") (EVar "k")) (EApp (EVar "appArgsOf") (EVar "call")))) (arm (PTuple (PCon "Some" (PVar "p")) (PCon "Some" (PVar "a"))) () (EMatch (EApp (EVar "consTail") (EVar "p")) (arm (PCon "Some" (PVar "t")) () (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "t")) (EVar "a"))) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EVar "False")))) (DoExpr (EBinOp "&&" (EVar "tailPassed") (EApp (EApp (EVar "all") (ELam ((PTuple (PVar "j") (PVar "r"))) (EBinOp "||" (EBinOp "==" (EVar "j") (EVar "k")) (EBinOp "==" (EVar "r") (EApp (EVar "Unchanged") (EVar "j")))))) (EApp (EVar "indexed") (EVar "roles")))))))
(DTypeSig false "topHelper" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Helper")))))))
(DFunDef false "topHelper" ((PCon "Reader" (PVar "scopes") (PVar "hs")) (PVar "self") (PVar "hd") (PVar "n")) (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "name")) () (EMatch (EApp (EApp (EVar "M.get") (EVar "name")) (EVar "hs")) (arm (PCon "Some" (PAs "h" (PCon "Helper" (PVar "arity") PWild PWild PWild))) ((GBool (EBinOp "&&" (EBinOp "==" (EVar "arity") (EVar "n")) (EBinOp "/=" (EApp (EVar "Some") (EVar "name")) (EVar "self"))))) (EIf (EApp (EApp (EApp (EVar "bindsTop") (EVar "scopes")) (EVar "name")) (EVar "hd")) (EApp (EVar "Some") (EVar "h")) (EVar "None"))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "bindsTop" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "bindsTop" ((PVar "scopes") (PVar "name") (PVar "hd")) (EMatch (EApp (EVar "varSite") (EVar "hd")) (arm (PCon "Some" (PVar "site")) () (EMatch (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "site")) (arm (PCon "Some" (PVar "b")) () (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BTopLevel")) (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "name")))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DData Private "Call" () ((variant "Call" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String") (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))) ())
(DData Private "Probe" () ((variant "Probe" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Expr")))) ())
(DTypeSig false "callsIn" (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyVar "v")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Call")) (TyApp (TyCon "List") (TyCon "Call")))))))
(DFunDef false "callsIn" ((PVar "tops") PWild (PCon "ELoc" (PVar "l") (PVar "inner")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "tops")) (EApp (EVar "Some") (EVar "l"))) (EVar "inner")) (EVar "acc")))
(DFunDef false "callsIn" ((PVar "tops") (PVar "loc") (PCon "EApp" (PVar "f") (PVar "a")) (PVar "acc")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "f")) (EListLit (EVar "a"))) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "c")) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "tops")) (EVar "loc")) (EVar "c")) (EVar "acc2")))) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "tops")) (EVar "loc")) (EVar "hd")) (EApp (EApp (EApp (EApp (EApp (EVar "candidate") (EVar "tops")) (EVar "loc")) (EVar "hd")) (EVar "args")) (EVar "acc")))) (EVar "args")))))
(DFunDef false "callsIn" ((PVar "tops") (PVar "loc") (PAs "e" (PCon "EBinOp" (PLit (LString "|>")) (PVar "l") (PVar "r") PWild)) (PVar "acc")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "r")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "c")) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "tops")) (EVar "loc")) (EVar "c")) (EVar "acc2")))) (EApp (EApp (EApp (EApp (EApp (EVar "candidate") (EVar "tops")) (EVar "loc")) (EVar "hd")) (EBinOp "++" (EVar "args") (EListLit (EVar "l")))) (EVar "acc"))) (EApp (EVar "childExprs") (EVar "e"))))))
(DFunDef false "callsIn" ((PVar "tops") (PVar "loc") (PVar "e") (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "c")) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "tops")) (EVar "loc")) (EVar "c")) (EVar "acc2")))) (EVar "acc")) (EApp (EVar "childExprs") (EVar "e"))))
(DTypeSig false "candidate" (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyVar "v")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyApp (TyCon "List") (TyCon "Call")) (TyApp (TyCon "List") (TyCon "Call"))))))))
(DFunDef false "candidate" ((PVar "tops") (PVar "loc") (PVar "hd") (PVar "args") (PVar "acc")) (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "n")) ((GBool (EBinOp "||" (EApp (EVar "isSome") (EApp (EVar "membershipName") (EVar "n"))) (EApp (EApp (EVar "M.has") (EVar "n")) (EVar "tops"))))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "Call") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "hd"))) (EVar "loc"))) (EVar "n")) (EVar "hd")) (EVar "args")) (EVar "acc"))) (arm PWild () (EVar "acc"))))
(DTypeSig false "probesIn" (TyFun (TyCon "Reader") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Probe")))))
(DFunDef false "probesIn" ((PAs "rd" (PCon "Reader" PWild (PVar "hs"))) (PVar "e")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "callProbes") (EVar "rd")) (EVar "None"))) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "hs")) (EVar "None")) (EVar "e")) (EListLit))))
(DTypeSig false "callProbes" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Call") (TyApp (TyCon "List") (TyCon "Probe"))))))
(DFunDef false "callProbes" ((PVar "rd") (PVar "self") (PCon "Call" (PVar "site") (PVar "n") (PVar "hd") (PVar "args"))) (EMatch (EApp (EVar "membershipName") (EVar "n")) (arm (PCon "Some" (PVar "m")) () (EMatch (EVar "args") (arm (PList PWild (PVar "c")) () (EListLit (EApp (EApp (EApp (EApp (EVar "Probe") (EVar "site")) (EVar "m")) (EVar "None")) (EVar "c")))) (arm PWild () (EListLit)))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "topHelper") (EVar "rd")) (EVar "self")) (EVar "hd")) (EApp (EVar "length") (EVar "args"))) (arm (PCon "Some" (PVar "h")) () (EApp (EApp (EApp (EApp (EVar "helperProbes") (EVar "site")) (EVar "n")) (EVar "h")) (EVar "args"))) (arm (PCon "None") () (EListLit))))))
(DTypeSig false "helperProbes" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "Helper") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Probe")))))))
(DFunDef false "helperProbes" ((PVar "site") (PVar "n") (PCon "Helper" PWild (PVar "search") (PVar "tested") PWild) (PVar "args")) (EBlock (DoLet false false (PVar "searched") (EMatch (EVar "search") (arm (PCon "Some" (PVar "k")) () (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "args")) (arm (PCon "Some" (PVar "c")) () (EListLit (EApp (EApp (EApp (EApp (EVar "Probe") (EVar "site")) (EVar "n")) (EVar "None")) (EVar "c")))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit)))) (DoExpr (EBinOp "++" (EVar "searched") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "j") (PVar "callee"))) (EMatch (EApp (EApp (EVar "get") (EVar "j")) (EVar "args")) (arm (PCon "Some" (PVar "c")) () (EListLit (EApp (EApp (EApp (EApp (EVar "Probe") (EVar "site")) (EVar "callee")) (EApp (EVar "Some") (EVar "n"))) (EVar "c")))) (arm (PCon "None") () (EListLit))))) (EVar "tested"))))))
(DTypeSig false "membershipName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "membershipName" ((PVar "n")) (EIf (EApp (EVar "isMembership") (EVar "n")) (EApp (EVar "Some") (EVar "n")) (EIf (EBinOp "&&" (EApp (EApp (EVar "contains") (ELit (LString "."))) (EVar "n")) (EApp (EVar "isMembership") (EApp (EVar "lastSegment") (EVar "n")))) (EApp (EVar "Some") (EApp (EVar "lastSegment") (EVar "n"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isMembership" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isMembership" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "contains"))) (EBinOp "==" (EVar "n") (ELit (LString "elem")))) (EBinOp "==" (EVar "n") (ELit (LString "notElem")))) (EBinOp "==" (EVar "n") (ELit (LString "lookupAssoc")))) (EBinOp "==" (EVar "n") (ELit (LString "lookup")))))
(DData Private "Param" () ((variant "Param" (ConPos (TyCon "String") (TyCon "Loc")))) ())
(DTypeSig false "wholeParam" (TyFun (TyCon "Pat") (TyApp (TyCon "Option") (TyCon "Param"))))
(DFunDef false "wholeParam" ((PCon "PVar" (PVar "n") (PVar "l") PWild)) (EApp (EVar "Some") (EApp (EApp (EVar "Param") (EVar "n")) (EVar "l"))))
(DFunDef false "wholeParam" ((PCon "PAs" (PVar "n") (PVar "l") PWild PWild)) (EApp (EVar "Some") (EApp (EApp (EVar "Param") (EVar "n")) (EVar "l"))))
(DFunDef false "wholeParam" (PWild) (EVar "None"))
(DTypeSig false "isParam" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "isParam" ((PVar "scopes") (PCon "Param" (PVar "n") (PVar "l")) (PVar "e")) (EMatch (EApp (EVar "varSite") (EVar "e")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "site")) () (EMatch (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "site")) (arm (PCon "Some" (PVar "b")) () (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "n")) (EBinOp "==" (EFieldAccess (EVar "b") "binderSpan") (EVar "l")))) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "paramProbes" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "List") (TyCon "Call")) (TyApp (TyCon "List") (TyTuple (TyCon "Probe") (TyCon "Int"))))))))
(DFunDef false "paramProbes" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "self") (PVar "ps") (PVar "calls")) (EMatch (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "callProbes") (EVar "rd")) (EVar "self"))) (EVar "calls")) (arm (PList) () (EListLit)) (arm (PVar "probes") () (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "probeParam") (EVar "scopes")) (EVar "ps"))) (EVar "probes")))))
(DTypeSig false "probeParam" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Probe") (TyApp (TyCon "List") (TyTuple (TyCon "Probe") (TyCon "Int")))))))
(DFunDef false "probeParam" ((PVar "scopes") (PVar "ps") (PAs "probe" (PCon "Probe" PWild PWild PWild (PVar "c")))) (EMatch (EApp (EApp (EVar "findMap") (EApp (EApp (EVar "atParam") (EVar "scopes")) (EVar "c"))) (EApp (EVar "indexed") (EVar "ps"))) (arm (PCon "Some" (PVar "j")) () (EListLit (ETuple (EVar "probe") (EVar "j")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "atParam" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Expr") (TyFun (TyTuple (TyCon "Int") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "atParam" ((PVar "scopes") (PVar "c") (PTuple (PVar "j") (PVar "p"))) (EApp (EApp (EVar "andThen") (EApp (EVar "wholeParam") (EVar "p"))) (ELam ((PVar "param")) (EIf (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "c")) (EApp (EVar "Some") (EVar "j")) (EVar "None")))))
(DTypeSig false "grows" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool"))))))
(DFunDef false "grows" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "lets") (PVar "param") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" PWild) () (EMatch (EApp (EApp (EApp (EVar "aliasOf") (EVar "scopes")) (EVar "lets")) (EVar "e")) (arm (PCon "Some" (PVar "rhs")) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "rhs"))) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "e")))))
(DTypeSig false "grownDirect" (TyFun (TyCon "Reader") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "grownDirect" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "param") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "::")) PWild (PVar "t") PWild) () (EBinOp "||" (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "t")) (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "t")))) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "a") (PVar "b") PWild) () (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "a")) (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "b"))) (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "a"))) (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "b")))) (arm (PCon "EIf" PWild (PVar "t") (PVar "f")) () (EBinOp "||" (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "t")) (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "f")))) (arm (PCon "EApp" PWild PWild) () (EApp (EApp (EApp (EVar "helperGrows") (EVar "rd")) (EVar "param")) (EVar "e"))) (arm (POr (PCon "ELit" PWild) (PCon "EVar" PWild) (PCon "ELam" PWild PWild) (PCon "ELet" PWild PWild PWild PWild PWild) (PCon "EMatch" PWild PWild) (PCon "EUnOp" PWild PWild PWild) (PCon "EInfix" PWild PWild PWild) (PCon "EFieldAccess" PWild PWild PWild) (PCon "ETuple" PWild) (PCon "EListLit" PWild) (PCon "EArrayLit" PWild) (PCon "ERangeList" PWild PWild PWild) (PCon "ERangeArray" PWild PWild PWild) (PCon "ESlice" PWild PWild PWild PWild) (PCon "ELetGroup" PWild PWild) (PCon "ESection" PWild) (PCon "EIndex" PWild PWild) (PCon "EAnnot" PWild PWild) (PCon "EHeadAnnot" PWild PWild) (PCon "EBlock" PWild) (PCon "EDo" PWild PWild) (PCon "EStringInterp" PWild) (PCon "EGuards" PWild) (PCon "ERecordCreate" PWild PWild) (PCon "ERecordUpdate" PWild PWild PWild) (PCon "EVariantUpdate" PWild PWild PWild) (PCon "EMapLit" PWild PWild) (PCon "ESetLit" PWild PWild) (PCon "EAsPat" PWild PWild) (PCon "EOrPat" PWild) (PCon "EMethodRef" PWild) (PCon "EDictApp" PWild) (PCon "EVarAt" PWild PWild) (PCon "EVarId" PWild PWild) (PCon "EMethodAt" PWild PWild PWild) (PCon "EDictAt" PWild PWild) (PCon "ELoc" PWild PWild) (PCon "EDoOrigin" PWild PWild) (PCon "ENumLit" PWild PWild PWild) (PCon "EWideLit" PWild PWild PWild PWild) (PCon "EBinOp" PWild PWild PWild PWild)) () (EVar "False"))))
(DTypeSig false "helperGrows" (TyFun (TyCon "Reader") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "helperGrows" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "param") (PVar "e")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EMatch (EApp (EApp (EApp (EApp (EVar "topHelper") (EVar "rd")) (EVar "None")) (EVar "hd")) (EApp (EVar "length") (EVar "args"))) (arm (PCon "Some" (PCon "Helper" PWild PWild PWild (PVar "grown"))) () (EApp (EApp (EVar "any") (ELam ((PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "j")) (EVar "args")) (arm (PCon "Some" (PVar "a")) () (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "a"))) (arm (PCon "None") () (EVar "False"))))) (EVar "grown"))) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "aliasOf" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "aliasOf" ((PVar "scopes") (PVar "lets") (PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EVar "varSite") (EVar "e"))) (ELam ((PVar "site")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "site"))) (ELam ((PVar "b")) (EApp (EApp (EVar "findMap") (ELam ((PTuple (PVar "l") (PVar "rhs"))) (EIf (EBinOp "==" (EVar "l") (EFieldAccess (EVar "b") "binderSpan")) (EApp (EVar "Some") (EVar "rhs")) (EVar "None")))) (EVar "lets")))))))
(DTypeSig false "letsIn" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr")))))
(DFunDef false "letsIn" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELet" PWild PWild (PCon "PVar" PWild (PVar "l") PWild) (PVar "rhs") (PVar "body")) () (EBinOp "::" (ETuple (EVar "l") (EVar "rhs")) (EBinOp "++" (EApp (EVar "letsIn") (EVar "rhs")) (EApp (EVar "letsIn") (EVar "body"))))) (arm (PCon "EBlock" (PVar "stmts")) () (EApp (EApp (EVar "flatMap") (EVar "stmtLets")) (EVar "stmts"))) (arm (PVar "e2") () (EApp (EApp (EVar "flatMap") (EVar "letsIn")) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig false "stmtLets" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr")))))
(DFunDef false "stmtLets" ((PCon "DoLet" PWild PWild (PCon "PVar" PWild (PVar "l") PWild) (PVar "rhs") PWild)) (EBinOp "::" (ETuple (EVar "l") (EVar "rhs")) (EApp (EVar "letsIn") (EVar "rhs"))))
(DFunDef false "stmtLets" ((PVar "s")) (EApp (EApp (EVar "flatMap") (EVar "letsIn")) (EApp (EVar "stmtExprs") (EVar "s"))))
(DTypeSig false "grownPositions" (TyFun (TyCon "Reader") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "grownPositions" ((PVar "rd") (PVar "name") (PVar "site") (PVar "clauses")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "clauseGrown") (EVar "rd")) (EVar "name")) (EVar "site"))) (EVar "clauses")))
(DTypeSig false "clauseGrown" (TyFun (TyCon "Reader") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "clauseGrown" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "name") (PVar "site") (PTuple (PVar "ps") (PVar "body"))) (EMatch (EApp (EApp (EApp (EVar "selfCalls") (EVar "scopes")) (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "site"))) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "calls") () (EBlock (DoLet false false (PVar "lets") (EApp (EVar "letsIn") (EVar "body"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "callGrown") (EVar "rd")) (EVar "lets")) (EVar "ps"))) (EVar "calls")))))))
(DTypeSig false "callGrown" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "SelfCall") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "callGrown" ((PVar "rd") (PVar "lets") (PVar "ps") (PCon "SelfCall" PWild (PVar "call") PWild)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "argGrown") (EVar "rd")) (EVar "lets")) (EVar "ps"))) (EApp (EVar "indexed") (EApp (EVar "appArgsOf") (EVar "call")))))
(DTypeSig false "argGrown" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyTuple (TyCon "Int") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "argGrown" ((PVar "rd") (PVar "lets") (PVar "ps") (PTuple (PVar "j") (PVar "a"))) (EMatch (EApp (EApp (EVar "get") (EVar "j")) (EVar "ps")) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EVar "wholeParam") (EVar "p")) (arm (PCon "Some" (PVar "param")) () (EIf (EApp (EApp (EApp (EApp (EVar "grows") (EVar "rd")) (EVar "lets")) (EVar "param")) (EVar "a")) (EListLit (EVar "j")) (EListLit))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "declFindings" (TyFun (TyCon "Reader") (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Def"))) (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "declFindings" ((PVar "rd") (PVar "defs") (PVar "ctx") (PVar "d")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "headFindings") (EVar "rd")) (EVar "defs")) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EVar "topHead") (EVar "d"))))
(DTypeSig false "headFindings" (TyFun (TyCon "Reader") (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Def"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Loc") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "headFindings" ((PVar "rd") (PVar "defs") (PVar "fallback") (PTuple (PVar "name") (PVar "site") (PVar "ps") PWild)) (EBlock (DoLet false false (PVar "ds") (EApp (EApp (EApp (EVar "M.findWithDefault") (EListLit)) (EVar "name")) (EVar "defs"))) (DoExpr (EMatch (EApp (EApp (EVar "findMap") (ELam ((PCon "Def" (PVar "l") PWild PWild (PVar "calls"))) (EIf (EBinOp "==" (EVar "l") (EVar "site")) (EApp (EVar "Some") (EVar "calls")) (EVar "None")))) (EVar "ds")) (arm (PCon "Some" (PVar "calls")) () (EMatch (EApp (EApp (EApp (EApp (EVar "paramProbes") (EVar "rd")) (EApp (EVar "Some") (EVar "name"))) (EVar "ps")) (EVar "calls")) (arm (PList) () (EListLit)) (arm (PVar "probes") () (EApp (EApp (EApp (EVar "reportGrown") (EVar "fallback")) (EApp (EApp (EApp (EApp (EVar "grownPositions") (EVar "rd")) (EVar "name")) (EVar "None")) (EApp (EApp (EVar "map") (EVar "defClause")) (EVar "ds")))) (EVar "probes"))))) (arm (PCon "None") () (EListLit))))))
(DTypeSig false "defClause" (TyFun (TyCon "Def") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "defClause" ((PCon "Def" PWild (PVar "ps") (PVar "body") PWild)) (ETuple (EVar "ps") (EVar "body")))
(DTypeSig false "localFindings" (TyFun (TyCon "Reader") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "localFindings" ((PVar "rd") (PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "letOwners") (EVar "e")) (arm (PList) () (EListLit)) (arm (PVar "owners") () (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "ownerFindings") (EVar "rd")) (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "owners"))) (EVar "owners")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ownerFindings" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Owner") (TyCon "Expr"))) (TyFun (TyTuple (TyCon "Owner") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ownerFindings" ((PAs "rd" (PCon "Reader" PWild (PVar "hs"))) (PVar "fallback") (PVar "owners") (PTuple (PCon "Owner" (PVar "name") (PVar "ps") (PVar "site")) (PVar "body"))) (EMatch (EApp (EApp (EApp (EApp (EVar "paramProbes") (EVar "rd")) (EVar "None")) (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "hs")) (EVar "None")) (EVar "body")) (EListLit))) (arm (PList) () (EListLit)) (arm (PVar "probes") () (EApp (EApp (EApp (EVar "reportGrown") (EVar "fallback")) (EApp (EApp (EApp (EApp (EVar "grownPositions") (EVar "rd")) (EVar "name")) (EVar "site")) (EApp (EApp (EApp (EVar "sameOwner") (EVar "name")) (EVar "site")) (EVar "owners")))) (EVar "probes")))))
(DTypeSig false "sameOwner" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Owner") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "sameOwner" ((PVar "name") (PVar "site") (PVar "owners")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "o")) (EApp (EApp (EApp (EVar "ownerClause") (EVar "name")) (EVar "site")) (EVar "o")))) (EVar "owners")))
(DTypeSig false "ownerClause" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "Owner") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "ownerClause" ((PVar "name") (PVar "site") (PTuple (PCon "Owner" (PVar "n") (PVar "ps") (PVar "s")) (PVar "body"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "==" (EVar "s") (EVar "site"))) (EListLit (ETuple (EVar "ps") (EVar "body"))) (EListLit)))
(DTypeSig false "reportGrown" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Probe") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "reportGrown" (PWild (PList) PWild) (EListLit))
(DFunDef false "reportGrown" ((PVar "fallback") (PVar "grown") (PVar "probes")) (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "probe") (PVar "j"))) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "j")))) (EVar "grown")) (EListLit (EApp (EApp (EVar "probeFinding") (EVar "fallback")) (EVar "probe"))) (EListLit)))) (EVar "probes")))
(DTypeSig false "foldFindings" (TyFun (TyCon "Reader") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "foldFindings" ((PVar "rd") (PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EMatch (EVar "e") (arm (PCon "EApp" PWild (PVar "a")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "a")) (arm (PCon "ELam" (PVar "ps") (PVar "body")) () (EMatch (EApp (EApp (EVar "foldAccOf") (EVar "e")) (EVar "ps")) (arm (PCon "Some" (PVar "acc")) () (EIf (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "body")) (EApp (EApp (EVar "map") (EApp (EVar "probeFinding") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "e"))) (EFieldAccess (EVar "ctx") "ctxSpan")))) (EApp (EApp (EApp (EVar "accProbes") (EVar "rd")) (EVar "acc")) (EVar "body"))) (EListLit))) (arm (PCon "None") () (EListLit)))) (arm PWild () (EListLit)))) (arm PWild () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldAccOf" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Param")))))
(DFunDef false "foldAccOf" ((PVar "e") (PVar "ps")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") PWild) () (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "n")) () (EApp (EApp (EVar "andThen") (EApp (EVar "foldAccIndex") (EApp (EVar "lastSegment") (EVar "n")))) (ELam ((PVar "k")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "get") (EVar "k")) (EVar "ps"))) (ELam ((PVar "p")) (EApp (EVar "wholeParam") (EVar "p"))))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "accProbes" (TyFun (TyCon "Reader") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Probe"))))))
(DFunDef false "accProbes" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "acc") (PVar "body")) (EApp (EApp (EVar "filter") (ELam ((PCon "Probe" PWild PWild PWild (PVar "c"))) (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "acc")) (EVar "c")))) (EApp (EApp (EVar "probesIn") (EVar "rd")) (EVar "body"))))
(DTypeSig false "tailGrows" (TyFun (TyCon "Reader") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "tailGrows" ((PVar "rd") (PVar "acc") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "::")) PWild PWild PWild) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "acc")) (EVar "e"))) (arm (PCon "EBinOp" (PLit (LString "++")) PWild PWild PWild) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "acc")) (EVar "e"))) (arm (PCon "EApp" PWild PWild) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "acc")) (EVar "e"))) (arm (PCon "EIf" PWild (PVar "t") (PVar "f")) () (EBinOp "||" (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "t")) (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "f")))) (arm (PCon "EMatch" PWild (PVar "arms")) () (EApp (EApp (EVar "any") (ELam ((PCon "Arm" PWild PWild (PVar "b"))) (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "b")))) (EVar "arms"))) (arm (PCon "EGuards" (PVar "arms")) () (EApp (EApp (EVar "any") (ELam ((PCon "GuardArm" PWild (PVar "b"))) (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "b")))) (EVar "arms"))) (arm (PCon "ELet" PWild PWild PWild PWild (PVar "body")) () (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "body"))) (arm (PCon "ELetGroup" PWild (PVar "body")) () (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "body"))) (arm (PCon "EBlock" (PVar "stmts")) () (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoExpr" (PVar "l"))) () (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "l"))) (arm PWild () (EVar "False")))) (arm (POr (PCon "ELit" PWild) (PCon "EVar" PWild) (PCon "ELam" PWild PWild) (PCon "EUnOp" PWild PWild PWild) (PCon "EInfix" PWild PWild PWild) (PCon "EFieldAccess" PWild PWild PWild) (PCon "ETuple" PWild) (PCon "EListLit" PWild) (PCon "EArrayLit" PWild) (PCon "ERangeList" PWild PWild PWild) (PCon "ERangeArray" PWild PWild PWild) (PCon "ESlice" PWild PWild PWild PWild) (PCon "ESection" PWild) (PCon "EIndex" PWild PWild) (PCon "EAnnot" PWild PWild) (PCon "EHeadAnnot" PWild PWild) (PCon "EDo" PWild PWild) (PCon "EStringInterp" PWild) (PCon "ERecordCreate" PWild PWild) (PCon "ERecordUpdate" PWild PWild PWild) (PCon "EVariantUpdate" PWild PWild PWild) (PCon "EMapLit" PWild PWild) (PCon "ESetLit" PWild PWild) (PCon "EAsPat" PWild PWild) (PCon "EOrPat" PWild) (PCon "EMethodRef" PWild) (PCon "EDictApp" PWild) (PCon "EVarAt" PWild PWild) (PCon "EVarId" PWild PWild) (PCon "EMethodAt" PWild PWild PWild) (PCon "EDictAt" PWild PWild) (PCon "ELoc" PWild PWild) (PCon "EDoOrigin" PWild PWild) (PCon "ENumLit" PWild PWild PWild) (PCon "EWideLit" PWild PWild PWild PWild) (PCon "EBinOp" PWild PWild PWild PWild)) () (EVar "False"))))
(DTypeSig false "probeFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Probe") (TyCon "Finding"))))
(DFunDef false "probeFinding" ((PVar "fallback") (PCon "Probe" (PVar "loc") (PVar "callee") (PVar "via") (PVar "c"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameListAsSet")) (fa "message" (EApp (EApp (EApp (EVar "message") (EVar "callee")) (EVar "via")) (EApp (EVar "containerName") (EVar "c")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "fallback"))) (fa "fix" (EVar "None")))))
(DTypeSig false "containerName" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "containerName" ((PVar "c")) (EMatch (EApp (EVar "unwrapLoc") (EVar "c")) (arm (PCon "EVar" (PVar "n")) () (EVar "n")) (arm PWild () (ELit (LString "the list")))))
(DTypeSig false "message" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "message" ((PVar "callee") (PCon "None") (PVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "callee"))) (ELit (LString "` on `"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "`, which this loop grows on every step, walks the whole list each time, so the loop is quadratic. "))) (EApp (EVar "display") (EApp (EVar "fixFor") (EVar "callee")))) (ELit (LString ""))))
(DFunDef false "message" ((PVar "callee") (PCon "Some" (PVar "helper")) (PVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "helper"))) (ELit (LString "` tests `"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "` with `"))) (EApp (EVar "display") (EVar "callee"))) (ELit (LString "`, and this loop grows `"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "` on every step, so each call walks the whole list and the loop is quadratic. "))) (EApp (EVar "display") (EApp (EVar "fixFor") (EVar "callee")))) (ELit (LString ""))))
(DTypeSig false "fixFor" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "fixFor" ((PLit (LString "lookupAssoc"))) (EVar "lookupFix"))
(DFunDef false "fixFor" ((PLit (LString "lookup"))) (EVar "lookupFix"))
(DFunDef false "fixFor" (PWild) (ELit (LString "Keep the elements in a `Set` beside the list (`has`, `insert`), or build the set once before the loop")))
(DTypeSig false "lookupFix" (TyCon "String"))
(DFunDef false "lookupFix" () (ELit (LString "Keep the pairs in a `Map` beside the list (`get`, `insert`), or build the map once before the loop")))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "GuardArm" true) (mem "Loc" false) (mem "Pat" true) (mem "Ty" true) (mem "orElseLoc" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true) (mem "childExprs" false) (mem "stmtExprs" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "get" false) (mem "indexed" false) (mem "last" false) (mem "nub" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "endsWith" false))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "lastSegment" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "factScopes" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "ArgRole" true) (mem "Owner" true) (mem "SelfCall" true) (mem "foldAccIndex" false) (mem "letOwners" false) (mem "selfCalls" false) (mem "spineOf" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "BinderKind" true) (mem "FileScopes" false) (mem "binderOf" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "appArgsOf" false) (mem "firstLoc" false) (mem "ruleNameListAsSet" false) (mem "tyHeadName" false) (mem "unwrapLoc" false) (mem "varSite" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameListAsSet")) (fa "summary" (ELit (LString "a `List` a loop grows and membership-tests on every step: each test walks the whole list. Keep a `Set` or `Map` beside it, or build the set once"))) (fa "doc" (ELit (LString "A membership test on a `List` (`contains`, `elem`, `notElem`, `lookupAssoc`, `lookup`, or a hand-rolled function of the file that walks a list and returns `Bool` or `Option`) walks the list. When a loop grows the list and tests it on every step, the loop does work quadratic in the number of steps. The rule reports a membership test whose container is a parameter that a self-call of the same function passes grown (`x :: seen`, `seen ++ xs`, `xs ++ seen`, a `let` bound to one of those, or a helper of the file that returns its argument grown), and a test on the accumulator of a fold lambda that returns the accumulator grown. A test made by a helper of the same file that the loop calls with the list is reported at the call. A container that is only passed on unchanged or shrinks is not reported, nor is one held in a `Ref`, a record field or a top-level table, nor a test two helpers away. A partial application and a call to a different function (mutual recursion) are not self-calls. `*_test.mdk` files are not checked.\n\nKeep the names in a `Set` (or the pairs in a `Map`) beside the list, or build the set once before the loop. A list whose length is small and fixed can carry a `-- lint-disable-next-line rule-list-as-set` with the bound as its reason.\n\nBefore:\n  go seen (x :: xs) = if contains x seen then go seen xs else go (x :: seen) xs\nAfter:\n  go seen (x :: xs) = if has x seen then go seen xs else go (insert x seen) xs  -- with `seen : Set String`"))) (fa "category" (EVar "Perf")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleListAsSet")) (EVar "None")))
(DTypeSig false "ruleListAsSet" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleListAsSet" (PWild (PVar "path") (PVar "facts") PWild (PVar "decls")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "path")) (EListLit) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "w")) (EApp (EApp (EVar "contains") (EVar "w")) (EFieldAccess (EVar "facts") "ffSrc")))) (EVar "mentions")) (EBlock (DoLet false false (PVar "scopes") (EApp (EVar "factScopes") (EVar "facts"))) (DoLet false false (PVar "defs") (EApp (EVar "topDefs") (EVar "decls"))) (DoLet false false (PVar "rd") (EApp (EApp (EVar "Reader") (EVar "scopes")) (EApp (EApp (EApp (EVar "helperTable") (EVar "scopes")) (EVar "decls")) (EVar "defs")))) (DoExpr (EListLit (EApp (EVar "OnDecl") (EApp (EApp (EVar "declFindings") (EVar "rd")) (EVar "defs"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KLetGroup"))) (EApp (EVar "localFindings") (EVar "rd"))) (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KApp"))) (EApp (EVar "foldFindings") (EVar "rd")))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "mentions" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "mentions" () (EListLit (ELit (LString "contains")) (ELit (LString "elem")) (ELit (LString "lookup"))))
(DData Private "Reader" () ((variant "Reader" (ConPos (TyCon "FileScopes") (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyCon "Helper"))))) ())
(DData Private "Helper" () ((variant "Helper" (ConPos (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DData Private "Def" () ((variant "Def" (ConPos (TyCon "Loc") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Call"))))) ())
(DTypeSig false "topDefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Def")))))
(DFunDef false "topDefs" ((PVar "decls")) (EBlock (DoLet false false (PVar "heads") (EApp (EApp (EDictApp "flatMap") (EVar "topHead")) (EVar "decls"))) (DoLet false false (PVar "names") (EApp (EVar "M.fromList") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "n") PWild PWild PWild)) (ETuple (EVar "n") (ELit LUnit)))) (EVar "heads")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PTuple (PVar "n") (PVar "l") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "M.insertWith") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "++" (EVar "_a") (EVar "_b")))) (EVar "n")) (EListLit (EApp (EApp (EApp (EApp (EVar "Def") (EVar "l")) (EVar "ps")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "names")) (EVar "None")) (EVar "body")) (EListLit))))) (EVar "m")))) (EMethodRef "empty")) (EVar "heads")))))
(DTypeSig false "topHead" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "topHead" ((PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") (PVar "l") PWild)) (EListLit (ETuple (EVar "n") (EVar "l") (EVar "ps") (EVar "body"))))
(DFunDef false "topHead" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topHead") (EVar "d")))
(DFunDef false "topHead" (PWild) (EListLit))
(DTypeSig false "helperTable" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Def"))) (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyCon "Helper"))))))
(DFunDef false "helperTable" ((PVar "scopes") (PVar "decls") (PVar "defs")) (EBlock (DoLet false false (PVar "sigs") (EApp (EVar "M.fromList") (EApp (EApp (EDictApp "flatMap") (EVar "sigOf")) (EVar "decls")))) (DoLet false false (PVar "entries") (EApp (EVar "M.entries") (EVar "defs"))) (DoLet false false (PVar "searches") (EApp (EVar "M.fromList") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "searchEntry") (EVar "scopes")) (EVar "sigs"))) (EVar "entries")))) (DoLet false false (PVar "rd") (EApp (EApp (EVar "Reader") (EVar "scopes")) (EVar "searches"))) (DoExpr (EApp (EVar "M.fromList") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "helperEntry") (EVar "rd")) (EVar "searches"))) (EVar "entries"))))))
(DTypeSig false "sigOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))
(DFunDef false "sigOf" ((PCon "DTypeSig" PWild (PVar "name") (PVar "ty") PWild)) (EListLit (ETuple (EVar "name") (EVar "ty"))))
(DFunDef false "sigOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "sigOf") (EVar "d")))
(DFunDef false "sigOf" (PWild) (EListLit))
(DTypeSig false "helperEntry" (TyFun (TyCon "Reader") (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyCon "Helper")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Def"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Helper")))))))
(DFunDef false "helperEntry" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "searches") (PTuple (PVar "name") (PVar "ds"))) (EBlock (DoLet false false (PVar "search") (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "M.get") (EVar "name")) (EVar "searches"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "Helper" PWild (PVar "k") PWild PWild) () (EVar "k")))))) (DoLet false false (PVar "tested") (EApp (EVar "nub") (EApp (EApp (EDictApp "flatMap") (ELam ((PCon "Def" PWild (PVar "ps") PWild (PVar "calls"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PCon "Probe" PWild (PVar "callee") PWild PWild) (PVar "j"))) (ETuple (EVar "j") (EVar "callee")))) (EApp (EApp (EApp (EApp (EVar "paramProbes") (EVar "rd")) (EApp (EVar "Some") (EVar "name"))) (EVar "ps")) (EVar "calls"))))) (EVar "ds")))) (DoLet false false (PVar "grown") (EApp (EVar "nub") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "clauseReturnsGrown") (EVar "scopes"))) (EVar "ds")))) (DoExpr (EMatch (ETuple (EVar "search") (EVar "tested") (EVar "grown")) (arm (PTuple (PCon "None") (PList) (PList)) () (EListLit)) (arm PWild () (EListLit (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EVar "Helper") (EApp (EVar "arityOf") (EVar "ds"))) (EVar "search")) (EVar "tested")) (EVar "grown")))))))))
(DTypeSig false "arityOf" (TyFun (TyApp (TyCon "List") (TyCon "Def")) (TyCon "Int")))
(DFunDef false "arityOf" ((PCons (PCon "Def" PWild (PVar "ps") PWild PWild) PWild)) (EApp (EMethodRef "length") (EVar "ps")))
(DFunDef false "arityOf" ((PList)) (ELit (LInt 0)))
(DTypeSig false "clauseReturnsGrown" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Def") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "clauseReturnsGrown" ((PVar "scopes") (PCon "Def" PWild (PVar "ps") (PVar "body") PWild)) (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "j") (PVar "p"))) (EMatch (EApp (EVar "wholeParam") (EVar "p")) (arm (PCon "Some" (PVar "param")) () (EIf (EApp (EApp (EApp (EVar "tailGrows") (EApp (EApp (EVar "Reader") (EVar "scopes")) (EMethodRef "empty"))) (EVar "param")) (EVar "body")) (EListLit (EVar "j")) (EListLit))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "indexed") (EVar "ps"))))
(DTypeSig false "searchEntry" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyCon "Ty")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Def"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Helper")))))))
(DFunDef false "searchEntry" ((PVar "scopes") (PVar "sigs") (PTuple (PVar "name") (PVar "ds"))) (EMatch (EApp (EApp (EVar "M.get") (EVar "name")) (EVar "sigs")) (arm (PCon "Some" (PVar "ty")) ((GBool (EBinOp "&&" (EApp (EVar "returnsTest") (EVar "ty")) (EApp (EApp (EDictApp "any") (ELam ((PCon "Def" PWild PWild (PVar "body") PWild)) (EApp (EVar "compares") (EVar "body")))) (EVar "ds"))))) (EMatch (EApp (EApp (EApp (EVar "searchPos") (EVar "scopes")) (EVar "name")) (EVar "ds")) (arm (PCon "Some" (PVar "k")) () (EListLit (ETuple (EVar "name") (EApp (EApp (EApp (EApp (EVar "Helper") (EApp (EVar "arityOf") (EVar "ds"))) (EApp (EVar "Some") (EVar "k"))) (EListLit)) (EListLit))))) (arm (PCon "None") () (EListLit)))) (arm PWild () (EListLit))))
(DTypeSig false "returnsTest" (TyFun (TyCon "Ty") (TyCon "Bool")))
(DFunDef false "returnsTest" ((PCon "TyFun" PWild (PVar "r"))) (EApp (EVar "returnsTest") (EVar "r")))
(DFunDef false "returnsTest" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "returnsTest") (EVar "t")))
(DFunDef false "returnsTest" ((PVar "t")) (EMatch (EApp (EVar "tyHeadName") (EVar "t")) (arm (PCon "Some" (PLit (LString "Bool"))) () (EVar "True")) (arm (PCon "Some" (PLit (LString "Option"))) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "compares" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "compares" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "==")) PWild PWild PWild) () (EVar "True")) (arm (PCon "EVar" (PVar "n")) () (EApp (EVar "isMembership") (EApp (EVar "lastSegment") (EVar "n")))) (arm (PVar "e2") () (EApp (EApp (EDictApp "any") (EVar "compares")) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig false "searchPos" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Def")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "searchPos" ((PVar "scopes") (PVar "name") (PVar "ds")) (EMatch (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "defSelfCalls") (EVar "scopes")) (EVar "name"))) (EVar "ds")) (arm (PList) () (EVar "None")) (arm (PVar "calls") () (EApp (EApp (EVar "findMap") (ELam ((PVar "k")) (EIf (EApp (EApp (EDictApp "all") (EApp (EApp (EVar "walksAt") (EVar "scopes")) (EVar "k"))) (EVar "calls")) (EApp (EVar "Some") (EVar "k")) (EVar "None")))) (EApp (EVar "nub") (EApp (EApp (EDictApp "flatMap") (EVar "consPositions")) (EVar "ds")))))))
(DTypeSig false "defSelfCalls" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "Def") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "SelfCall")))))))
(DFunDef false "defSelfCalls" ((PVar "scopes") (PVar "name") (PCon "Def" PWild (PVar "ps") (PVar "body") PWild)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (ETuple (EVar "ps") (EVar "c")))) (EApp (EApp (EApp (EVar "selfCalls") (EVar "scopes")) (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))) (EVar "body"))))
(DTypeSig false "consPositions" (TyFun (TyCon "Def") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "consPositions" ((PCon "Def" PWild (PVar "ps") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "j") (PVar "p"))) (EIf (EApp (EVar "isSome") (EApp (EVar "consTail") (EVar "p"))) (EListLit (EVar "j")) (EListLit)))) (EApp (EVar "indexed") (EVar "ps"))))
(DTypeSig false "consTail" (TyFun (TyCon "Pat") (TyApp (TyCon "Option") (TyCon "Param"))))
(DFunDef false "consTail" ((PCon "PCons" PWild (PCon "PVar" (PVar "t") (PVar "l") PWild))) (EApp (EVar "Some") (EApp (EApp (EVar "Param") (EVar "t")) (EVar "l"))))
(DFunDef false "consTail" (PWild) (EVar "None"))
(DTypeSig false "walksAt" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Int") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "SelfCall")) (TyCon "Bool")))))
(DFunDef false "walksAt" ((PVar "scopes") (PVar "k") (PTuple (PVar "ps") (PCon "SelfCall" PWild (PVar "call") (PVar "roles")))) (EBlock (DoLet false false (PVar "tailPassed") (EMatch (ETuple (EApp (EApp (EVar "get") (EVar "k")) (EVar "ps")) (EApp (EApp (EVar "get") (EVar "k")) (EApp (EVar "appArgsOf") (EVar "call")))) (arm (PTuple (PCon "Some" (PVar "p")) (PCon "Some" (PVar "a"))) () (EMatch (EApp (EVar "consTail") (EVar "p")) (arm (PCon "Some" (PVar "t")) () (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "t")) (EVar "a"))) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EVar "False")))) (DoExpr (EBinOp "&&" (EVar "tailPassed") (EApp (EApp (EDictApp "all") (ELam ((PTuple (PVar "j") (PVar "r"))) (EBinOp "||" (EBinOp "==" (EVar "j") (EVar "k")) (EBinOp "==" (EVar "r") (EApp (EVar "Unchanged") (EVar "j")))))) (EApp (EVar "indexed") (EVar "roles")))))))
(DTypeSig false "topHelper" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Helper")))))))
(DFunDef false "topHelper" ((PCon "Reader" (PVar "scopes") (PVar "hs")) (PVar "self") (PVar "hd") (PVar "n")) (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "name")) () (EMatch (EApp (EApp (EVar "M.get") (EVar "name")) (EVar "hs")) (arm (PCon "Some" (PAs "h" (PCon "Helper" (PVar "arity") PWild PWild PWild))) ((GBool (EBinOp "&&" (EBinOp "==" (EVar "arity") (EVar "n")) (EBinOp "/=" (EApp (EVar "Some") (EVar "name")) (EVar "self"))))) (EIf (EApp (EApp (EApp (EVar "bindsTop") (EVar "scopes")) (EVar "name")) (EVar "hd")) (EApp (EVar "Some") (EVar "h")) (EVar "None"))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "bindsTop" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "bindsTop" ((PVar "scopes") (PVar "name") (PVar "hd")) (EMatch (EApp (EVar "varSite") (EVar "hd")) (arm (PCon "Some" (PVar "site")) () (EMatch (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "site")) (arm (PCon "Some" (PVar "b")) () (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BTopLevel")) (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "name")))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DData Private "Call" () ((variant "Call" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String") (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))) ())
(DData Private "Probe" () ((variant "Probe" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Expr")))) ())
(DTypeSig false "callsIn" (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyVar "v")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Call")) (TyApp (TyCon "List") (TyCon "Call")))))))
(DFunDef false "callsIn" ((PVar "tops") PWild (PCon "ELoc" (PVar "l") (PVar "inner")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "tops")) (EApp (EVar "Some") (EVar "l"))) (EVar "inner")) (EVar "acc")))
(DFunDef false "callsIn" ((PVar "tops") (PVar "loc") (PCon "EApp" (PVar "f") (PVar "a")) (PVar "acc")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "f")) (EListLit (EVar "a"))) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "c")) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "tops")) (EVar "loc")) (EVar "c")) (EVar "acc2")))) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "tops")) (EVar "loc")) (EVar "hd")) (EApp (EApp (EApp (EApp (EApp (EVar "candidate") (EVar "tops")) (EVar "loc")) (EVar "hd")) (EVar "args")) (EVar "acc")))) (EVar "args")))))
(DFunDef false "callsIn" ((PVar "tops") (PVar "loc") (PAs "e" (PCon "EBinOp" (PLit (LString "|>")) (PVar "l") (PVar "r") PWild)) (PVar "acc")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "r")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "c")) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "tops")) (EVar "loc")) (EVar "c")) (EVar "acc2")))) (EApp (EApp (EApp (EApp (EApp (EVar "candidate") (EVar "tops")) (EVar "loc")) (EVar "hd")) (EBinOp "++" (EVar "args") (EListLit (EVar "l")))) (EVar "acc"))) (EApp (EVar "childExprs") (EVar "e"))))))
(DFunDef false "callsIn" ((PVar "tops") (PVar "loc") (PVar "e") (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "c")) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "tops")) (EVar "loc")) (EVar "c")) (EVar "acc2")))) (EVar "acc")) (EApp (EVar "childExprs") (EVar "e"))))
(DTypeSig false "candidate" (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyVar "v")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyApp (TyCon "List") (TyCon "Call")) (TyApp (TyCon "List") (TyCon "Call"))))))))
(DFunDef false "candidate" ((PVar "tops") (PVar "loc") (PVar "hd") (PVar "args") (PVar "acc")) (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "n")) ((GBool (EBinOp "||" (EApp (EVar "isSome") (EApp (EVar "membershipName") (EVar "n"))) (EApp (EApp (EVar "M.has") (EVar "n")) (EVar "tops"))))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "Call") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "hd"))) (EVar "loc"))) (EVar "n")) (EVar "hd")) (EVar "args")) (EVar "acc"))) (arm PWild () (EVar "acc"))))
(DTypeSig false "probesIn" (TyFun (TyCon "Reader") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Probe")))))
(DFunDef false "probesIn" ((PAs "rd" (PCon "Reader" PWild (PVar "hs"))) (PVar "e")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "callProbes") (EVar "rd")) (EVar "None"))) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "hs")) (EVar "None")) (EVar "e")) (EListLit))))
(DTypeSig false "callProbes" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Call") (TyApp (TyCon "List") (TyCon "Probe"))))))
(DFunDef false "callProbes" ((PVar "rd") (PVar "self") (PCon "Call" (PVar "site") (PVar "n") (PVar "hd") (PVar "args"))) (EMatch (EApp (EVar "membershipName") (EVar "n")) (arm (PCon "Some" (PVar "m")) () (EMatch (EVar "args") (arm (PList PWild (PVar "c")) () (EListLit (EApp (EApp (EApp (EApp (EVar "Probe") (EVar "site")) (EVar "m")) (EVar "None")) (EVar "c")))) (arm PWild () (EListLit)))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "topHelper") (EVar "rd")) (EVar "self")) (EVar "hd")) (EApp (EMethodRef "length") (EVar "args"))) (arm (PCon "Some" (PVar "h")) () (EApp (EApp (EApp (EApp (EVar "helperProbes") (EVar "site")) (EVar "n")) (EVar "h")) (EVar "args"))) (arm (PCon "None") () (EListLit))))))
(DTypeSig false "helperProbes" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "Helper") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Probe")))))))
(DFunDef false "helperProbes" ((PVar "site") (PVar "n") (PCon "Helper" PWild (PVar "search") (PVar "tested") PWild) (PVar "args")) (EBlock (DoLet false false (PVar "searched") (EMatch (EVar "search") (arm (PCon "Some" (PVar "k")) () (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "args")) (arm (PCon "Some" (PVar "c")) () (EListLit (EApp (EApp (EApp (EApp (EVar "Probe") (EVar "site")) (EVar "n")) (EVar "None")) (EVar "c")))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit)))) (DoExpr (EBinOp "++" (EVar "searched") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "j") (PVar "callee"))) (EMatch (EApp (EApp (EVar "get") (EVar "j")) (EVar "args")) (arm (PCon "Some" (PVar "c")) () (EListLit (EApp (EApp (EApp (EApp (EVar "Probe") (EVar "site")) (EVar "callee")) (EApp (EVar "Some") (EVar "n"))) (EVar "c")))) (arm (PCon "None") () (EListLit))))) (EVar "tested"))))))
(DTypeSig false "membershipName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "membershipName" ((PVar "n")) (EIf (EApp (EVar "isMembership") (EVar "n")) (EApp (EVar "Some") (EVar "n")) (EIf (EBinOp "&&" (EApp (EApp (EVar "contains") (ELit (LString "."))) (EVar "n")) (EApp (EVar "isMembership") (EApp (EVar "lastSegment") (EVar "n")))) (EApp (EVar "Some") (EApp (EVar "lastSegment") (EVar "n"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isMembership" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isMembership" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "contains"))) (EBinOp "==" (EVar "n") (ELit (LString "elem")))) (EBinOp "==" (EVar "n") (ELit (LString "notElem")))) (EBinOp "==" (EVar "n") (ELit (LString "lookupAssoc")))) (EBinOp "==" (EVar "n") (ELit (LString "lookup")))))
(DData Private "Param" () ((variant "Param" (ConPos (TyCon "String") (TyCon "Loc")))) ())
(DTypeSig false "wholeParam" (TyFun (TyCon "Pat") (TyApp (TyCon "Option") (TyCon "Param"))))
(DFunDef false "wholeParam" ((PCon "PVar" (PVar "n") (PVar "l") PWild)) (EApp (EVar "Some") (EApp (EApp (EVar "Param") (EVar "n")) (EVar "l"))))
(DFunDef false "wholeParam" ((PCon "PAs" (PVar "n") (PVar "l") PWild PWild)) (EApp (EVar "Some") (EApp (EApp (EVar "Param") (EVar "n")) (EVar "l"))))
(DFunDef false "wholeParam" (PWild) (EVar "None"))
(DTypeSig false "isParam" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "isParam" ((PVar "scopes") (PCon "Param" (PVar "n") (PVar "l")) (PVar "e")) (EMatch (EApp (EVar "varSite") (EVar "e")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "site")) () (EMatch (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "site")) (arm (PCon "Some" (PVar "b")) () (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "n")) (EBinOp "==" (EFieldAccess (EVar "b") "binderSpan") (EVar "l")))) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "paramProbes" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "List") (TyCon "Call")) (TyApp (TyCon "List") (TyTuple (TyCon "Probe") (TyCon "Int"))))))))
(DFunDef false "paramProbes" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "self") (PVar "ps") (PVar "calls")) (EMatch (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "callProbes") (EVar "rd")) (EVar "self"))) (EVar "calls")) (arm (PList) () (EListLit)) (arm (PVar "probes") () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "probeParam") (EVar "scopes")) (EVar "ps"))) (EVar "probes")))))
(DTypeSig false "probeParam" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Probe") (TyApp (TyCon "List") (TyTuple (TyCon "Probe") (TyCon "Int")))))))
(DFunDef false "probeParam" ((PVar "scopes") (PVar "ps") (PAs "probe" (PCon "Probe" PWild PWild PWild (PVar "c")))) (EMatch (EApp (EApp (EVar "findMap") (EApp (EApp (EVar "atParam") (EVar "scopes")) (EVar "c"))) (EApp (EVar "indexed") (EVar "ps"))) (arm (PCon "Some" (PVar "j")) () (EListLit (ETuple (EVar "probe") (EVar "j")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "atParam" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Expr") (TyFun (TyTuple (TyCon "Int") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "atParam" ((PVar "scopes") (PVar "c") (PTuple (PVar "j") (PVar "p"))) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "wholeParam") (EVar "p"))) (ELam ((PVar "param")) (EIf (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "c")) (EApp (EVar "Some") (EVar "j")) (EVar "None")))))
(DTypeSig false "grows" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool"))))))
(DFunDef false "grows" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "lets") (PVar "param") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" PWild) () (EMatch (EApp (EApp (EApp (EVar "aliasOf") (EVar "scopes")) (EVar "lets")) (EVar "e")) (arm (PCon "Some" (PVar "rhs")) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "rhs"))) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "e")))))
(DTypeSig false "grownDirect" (TyFun (TyCon "Reader") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "grownDirect" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "param") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "::")) PWild (PVar "t") PWild) () (EBinOp "||" (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "t")) (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "t")))) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "a") (PVar "b") PWild) () (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "a")) (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "b"))) (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "a"))) (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "b")))) (arm (PCon "EIf" PWild (PVar "t") (PVar "f")) () (EBinOp "||" (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "t")) (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "param")) (EVar "f")))) (arm (PCon "EApp" PWild PWild) () (EApp (EApp (EApp (EVar "helperGrows") (EVar "rd")) (EVar "param")) (EVar "e"))) (arm (POr (PCon "ELit" PWild) (PCon "EVar" PWild) (PCon "ELam" PWild PWild) (PCon "ELet" PWild PWild PWild PWild PWild) (PCon "EMatch" PWild PWild) (PCon "EUnOp" PWild PWild PWild) (PCon "EInfix" PWild PWild PWild) (PCon "EFieldAccess" PWild PWild PWild) (PCon "ETuple" PWild) (PCon "EListLit" PWild) (PCon "EArrayLit" PWild) (PCon "ERangeList" PWild PWild PWild) (PCon "ERangeArray" PWild PWild PWild) (PCon "ESlice" PWild PWild PWild PWild) (PCon "ELetGroup" PWild PWild) (PCon "ESection" PWild) (PCon "EIndex" PWild PWild) (PCon "EAnnot" PWild PWild) (PCon "EHeadAnnot" PWild PWild) (PCon "EBlock" PWild) (PCon "EDo" PWild PWild) (PCon "EStringInterp" PWild) (PCon "EGuards" PWild) (PCon "ERecordCreate" PWild PWild) (PCon "ERecordUpdate" PWild PWild PWild) (PCon "EVariantUpdate" PWild PWild PWild) (PCon "EMapLit" PWild PWild) (PCon "ESetLit" PWild PWild) (PCon "EAsPat" PWild PWild) (PCon "EOrPat" PWild) (PCon "EMethodRef" PWild) (PCon "EDictApp" PWild) (PCon "EVarAt" PWild PWild) (PCon "EVarId" PWild PWild) (PCon "EMethodAt" PWild PWild PWild) (PCon "EDictAt" PWild PWild) (PCon "ELoc" PWild PWild) (PCon "EDoOrigin" PWild PWild) (PCon "ENumLit" PWild PWild PWild) (PCon "EWideLit" PWild PWild PWild PWild) (PCon "EBinOp" PWild PWild PWild PWild)) () (EVar "False"))))
(DTypeSig false "helperGrows" (TyFun (TyCon "Reader") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "helperGrows" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "param") (PVar "e")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EMatch (EApp (EApp (EApp (EApp (EVar "topHelper") (EVar "rd")) (EVar "None")) (EVar "hd")) (EApp (EMethodRef "length") (EVar "args"))) (arm (PCon "Some" (PCon "Helper" PWild PWild PWild (PVar "grown"))) () (EApp (EApp (EDictApp "any") (ELam ((PVar "j")) (EMatch (EApp (EApp (EVar "get") (EVar "j")) (EVar "args")) (arm (PCon "Some" (PVar "a")) () (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "param")) (EVar "a"))) (arm (PCon "None") () (EVar "False"))))) (EVar "grown"))) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "aliasOf" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "aliasOf" ((PVar "scopes") (PVar "lets") (PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "varSite") (EVar "e"))) (ELam ((PVar "site")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "site"))) (ELam ((PVar "b")) (EApp (EApp (EVar "findMap") (ELam ((PTuple (PVar "l") (PVar "rhs"))) (EIf (EBinOp "==" (EVar "l") (EFieldAccess (EVar "b") "binderSpan")) (EApp (EVar "Some") (EVar "rhs")) (EVar "None")))) (EVar "lets")))))))
(DTypeSig false "letsIn" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr")))))
(DFunDef false "letsIn" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELet" PWild PWild (PCon "PVar" PWild (PVar "l") PWild) (PVar "rhs") (PVar "body")) () (EBinOp "::" (ETuple (EVar "l") (EVar "rhs")) (EBinOp "++" (EApp (EVar "letsIn") (EVar "rhs")) (EApp (EVar "letsIn") (EVar "body"))))) (arm (PCon "EBlock" (PVar "stmts")) () (EApp (EApp (EDictApp "flatMap") (EVar "stmtLets")) (EVar "stmts"))) (arm (PVar "e2") () (EApp (EApp (EDictApp "flatMap") (EVar "letsIn")) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig false "stmtLets" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr")))))
(DFunDef false "stmtLets" ((PCon "DoLet" PWild PWild (PCon "PVar" PWild (PVar "l") PWild) (PVar "rhs") PWild)) (EBinOp "::" (ETuple (EVar "l") (EVar "rhs")) (EApp (EVar "letsIn") (EVar "rhs"))))
(DFunDef false "stmtLets" ((PVar "s")) (EApp (EApp (EDictApp "flatMap") (EVar "letsIn")) (EApp (EVar "stmtExprs") (EVar "s"))))
(DTypeSig false "grownPositions" (TyFun (TyCon "Reader") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "grownPositions" ((PVar "rd") (PVar "name") (PVar "site") (PVar "clauses")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "clauseGrown") (EVar "rd")) (EVar "name")) (EVar "site"))) (EVar "clauses")))
(DTypeSig false "clauseGrown" (TyFun (TyCon "Reader") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "clauseGrown" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "name") (PVar "site") (PTuple (PVar "ps") (PVar "body"))) (EMatch (EApp (EApp (EApp (EVar "selfCalls") (EVar "scopes")) (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "site"))) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "calls") () (EBlock (DoLet false false (PVar "lets") (EApp (EVar "letsIn") (EVar "body"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "callGrown") (EVar "rd")) (EVar "lets")) (EVar "ps"))) (EVar "calls")))))))
(DTypeSig false "callGrown" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "SelfCall") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "callGrown" ((PVar "rd") (PVar "lets") (PVar "ps") (PCon "SelfCall" PWild (PVar "call") PWild)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "argGrown") (EVar "rd")) (EVar "lets")) (EVar "ps"))) (EApp (EVar "indexed") (EApp (EVar "appArgsOf") (EVar "call")))))
(DTypeSig false "argGrown" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyTuple (TyCon "Int") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "argGrown" ((PVar "rd") (PVar "lets") (PVar "ps") (PTuple (PVar "j") (PVar "a"))) (EMatch (EApp (EApp (EVar "get") (EVar "j")) (EVar "ps")) (arm (PCon "Some" (PVar "p")) () (EMatch (EApp (EVar "wholeParam") (EVar "p")) (arm (PCon "Some" (PVar "param")) () (EIf (EApp (EApp (EApp (EApp (EVar "grows") (EVar "rd")) (EVar "lets")) (EVar "param")) (EVar "a")) (EListLit (EVar "j")) (EListLit))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "declFindings" (TyFun (TyCon "Reader") (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Def"))) (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "declFindings" ((PVar "rd") (PVar "defs") (PVar "ctx") (PVar "d")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "headFindings") (EVar "rd")) (EVar "defs")) (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EVar "topHead") (EVar "d"))))
(DTypeSig false "headFindings" (TyFun (TyCon "Reader") (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Def"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Loc") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "headFindings" ((PVar "rd") (PVar "defs") (PVar "fallback") (PTuple (PVar "name") (PVar "site") (PVar "ps") PWild)) (EBlock (DoLet false false (PVar "ds") (EApp (EApp (EApp (EVar "M.findWithDefault") (EListLit)) (EVar "name")) (EVar "defs"))) (DoExpr (EMatch (EApp (EApp (EVar "findMap") (ELam ((PCon "Def" (PVar "l") PWild PWild (PVar "calls"))) (EIf (EBinOp "==" (EVar "l") (EVar "site")) (EApp (EVar "Some") (EVar "calls")) (EVar "None")))) (EVar "ds")) (arm (PCon "Some" (PVar "calls")) () (EMatch (EApp (EApp (EApp (EApp (EVar "paramProbes") (EVar "rd")) (EApp (EVar "Some") (EVar "name"))) (EVar "ps")) (EVar "calls")) (arm (PList) () (EListLit)) (arm (PVar "probes") () (EApp (EApp (EApp (EVar "reportGrown") (EVar "fallback")) (EApp (EApp (EApp (EApp (EVar "grownPositions") (EVar "rd")) (EVar "name")) (EVar "None")) (EApp (EApp (EMethodRef "map") (EVar "defClause")) (EVar "ds")))) (EVar "probes"))))) (arm (PCon "None") () (EListLit))))))
(DTypeSig false "defClause" (TyFun (TyCon "Def") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "defClause" ((PCon "Def" PWild (PVar "ps") (PVar "body") PWild)) (ETuple (EVar "ps") (EVar "body")))
(DTypeSig false "localFindings" (TyFun (TyCon "Reader") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "localFindings" ((PVar "rd") (PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "letOwners") (EVar "e")) (arm (PList) () (EListLit)) (arm (PVar "owners") () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "ownerFindings") (EVar "rd")) (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "owners"))) (EVar "owners")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ownerFindings" (TyFun (TyCon "Reader") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Owner") (TyCon "Expr"))) (TyFun (TyTuple (TyCon "Owner") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ownerFindings" ((PAs "rd" (PCon "Reader" PWild (PVar "hs"))) (PVar "fallback") (PVar "owners") (PTuple (PCon "Owner" (PVar "name") (PVar "ps") (PVar "site")) (PVar "body"))) (EMatch (EApp (EApp (EApp (EApp (EVar "paramProbes") (EVar "rd")) (EVar "None")) (EVar "ps")) (EApp (EApp (EApp (EApp (EVar "callsIn") (EVar "hs")) (EVar "None")) (EVar "body")) (EListLit))) (arm (PList) () (EListLit)) (arm (PVar "probes") () (EApp (EApp (EApp (EVar "reportGrown") (EVar "fallback")) (EApp (EApp (EApp (EApp (EVar "grownPositions") (EVar "rd")) (EVar "name")) (EVar "site")) (EApp (EApp (EApp (EVar "sameOwner") (EVar "name")) (EVar "site")) (EVar "owners")))) (EVar "probes")))))
(DTypeSig false "sameOwner" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Owner") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "sameOwner" ((PVar "name") (PVar "site") (PVar "owners")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "o")) (EApp (EApp (EApp (EVar "ownerClause") (EVar "name")) (EVar "site")) (EVar "o")))) (EVar "owners")))
(DTypeSig false "ownerClause" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "Owner") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "ownerClause" ((PVar "name") (PVar "site") (PTuple (PCon "Owner" (PVar "n") (PVar "ps") (PVar "s")) (PVar "body"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "==" (EVar "s") (EVar "site"))) (EListLit (ETuple (EVar "ps") (EVar "body"))) (EListLit)))
(DTypeSig false "reportGrown" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Probe") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "reportGrown" (PWild (PList) PWild) (EListLit))
(DFunDef false "reportGrown" ((PVar "fallback") (PVar "grown") (PVar "probes")) (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "probe") (PVar "j"))) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "j")))) (EVar "grown")) (EListLit (EApp (EApp (EVar "probeFinding") (EVar "fallback")) (EVar "probe"))) (EListLit)))) (EVar "probes")))
(DTypeSig false "foldFindings" (TyFun (TyCon "Reader") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "foldFindings" ((PVar "rd") (PVar "ctx") (PVar "e")) (EIf (EFieldAccess (EVar "ctx") "ctxInTest") (EListLit) (EIf (EVar "otherwise") (EMatch (EVar "e") (arm (PCon "EApp" PWild (PVar "a")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "a")) (arm (PCon "ELam" (PVar "ps") (PVar "body")) () (EMatch (EApp (EApp (EVar "foldAccOf") (EVar "e")) (EVar "ps")) (arm (PCon "Some" (PVar "acc")) () (EIf (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "body")) (EApp (EApp (EMethodRef "map") (EApp (EVar "probeFinding") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstLoc") (EVar "e"))) (EFieldAccess (EVar "ctx") "ctxSpan")))) (EApp (EApp (EApp (EVar "accProbes") (EVar "rd")) (EVar "acc")) (EVar "body"))) (EListLit))) (arm (PCon "None") () (EListLit)))) (arm PWild () (EListLit)))) (arm PWild () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldAccOf" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Param")))))
(DFunDef false "foldAccOf" ((PVar "e") (PVar "ps")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") PWild) () (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "n")) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "foldAccIndex") (EApp (EVar "lastSegment") (EVar "n")))) (ELam ((PVar "k")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "get") (EVar "k")) (EVar "ps"))) (ELam ((PVar "p")) (EApp (EVar "wholeParam") (EVar "p"))))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "accProbes" (TyFun (TyCon "Reader") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Probe"))))))
(DFunDef false "accProbes" ((PAs "rd" (PCon "Reader" (PVar "scopes") PWild)) (PVar "acc") (PVar "body")) (EApp (EApp (EMethodRef "filter") (ELam ((PCon "Probe" PWild PWild PWild (PVar "c"))) (EApp (EApp (EApp (EVar "isParam") (EVar "scopes")) (EVar "acc")) (EVar "c")))) (EApp (EApp (EVar "probesIn") (EVar "rd")) (EVar "body"))))
(DTypeSig false "tailGrows" (TyFun (TyCon "Reader") (TyFun (TyCon "Param") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "tailGrows" ((PVar "rd") (PVar "acc") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "::")) PWild PWild PWild) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "acc")) (EVar "e"))) (arm (PCon "EBinOp" (PLit (LString "++")) PWild PWild PWild) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "acc")) (EVar "e"))) (arm (PCon "EApp" PWild PWild) () (EApp (EApp (EApp (EVar "grownDirect") (EVar "rd")) (EVar "acc")) (EVar "e"))) (arm (PCon "EIf" PWild (PVar "t") (PVar "f")) () (EBinOp "||" (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "t")) (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "f")))) (arm (PCon "EMatch" PWild (PVar "arms")) () (EApp (EApp (EDictApp "any") (ELam ((PCon "Arm" PWild PWild (PVar "b"))) (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "b")))) (EVar "arms"))) (arm (PCon "EGuards" (PVar "arms")) () (EApp (EApp (EDictApp "any") (ELam ((PCon "GuardArm" PWild (PVar "b"))) (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "b")))) (EVar "arms"))) (arm (PCon "ELet" PWild PWild PWild PWild (PVar "body")) () (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "body"))) (arm (PCon "ELetGroup" PWild (PVar "body")) () (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "body"))) (arm (PCon "EBlock" (PVar "stmts")) () (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoExpr" (PVar "l"))) () (EApp (EApp (EApp (EVar "tailGrows") (EVar "rd")) (EVar "acc")) (EVar "l"))) (arm PWild () (EVar "False")))) (arm (POr (PCon "ELit" PWild) (PCon "EVar" PWild) (PCon "ELam" PWild PWild) (PCon "EUnOp" PWild PWild PWild) (PCon "EInfix" PWild PWild PWild) (PCon "EFieldAccess" PWild PWild PWild) (PCon "ETuple" PWild) (PCon "EListLit" PWild) (PCon "EArrayLit" PWild) (PCon "ERangeList" PWild PWild PWild) (PCon "ERangeArray" PWild PWild PWild) (PCon "ESlice" PWild PWild PWild PWild) (PCon "ESection" PWild) (PCon "EIndex" PWild PWild) (PCon "EAnnot" PWild PWild) (PCon "EHeadAnnot" PWild PWild) (PCon "EDo" PWild PWild) (PCon "EStringInterp" PWild) (PCon "ERecordCreate" PWild PWild) (PCon "ERecordUpdate" PWild PWild PWild) (PCon "EVariantUpdate" PWild PWild PWild) (PCon "EMapLit" PWild PWild) (PCon "ESetLit" PWild PWild) (PCon "EAsPat" PWild PWild) (PCon "EOrPat" PWild) (PCon "EMethodRef" PWild) (PCon "EDictApp" PWild) (PCon "EVarAt" PWild PWild) (PCon "EVarId" PWild PWild) (PCon "EMethodAt" PWild PWild PWild) (PCon "EDictAt" PWild PWild) (PCon "ELoc" PWild PWild) (PCon "EDoOrigin" PWild PWild) (PCon "ENumLit" PWild PWild PWild) (PCon "EWideLit" PWild PWild PWild PWild) (PCon "EBinOp" PWild PWild PWild PWild)) () (EVar "False"))))
(DTypeSig false "probeFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Probe") (TyCon "Finding"))))
(DFunDef false "probeFinding" ((PVar "fallback") (PCon "Probe" (PVar "loc") (PVar "callee") (PVar "via") (PVar "c"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameListAsSet")) (fa "message" (EApp (EApp (EApp (EVar "message") (EVar "callee")) (EVar "via")) (EApp (EVar "containerName") (EVar "c")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "fallback"))) (fa "fix" (EVar "None")))))
(DTypeSig false "containerName" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "containerName" ((PVar "c")) (EMatch (EApp (EVar "unwrapLoc") (EVar "c")) (arm (PCon "EVar" (PVar "n")) () (EVar "n")) (arm PWild () (ELit (LString "the list")))))
(DTypeSig false "message" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "message" ((PVar "callee") (PCon "None") (PVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "callee"))) (ELit (LString "` on `"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "`, which this loop grows on every step, walks the whole list each time, so the loop is quadratic. "))) (EApp (EMethodRef "display") (EApp (EVar "fixFor") (EVar "callee")))) (ELit (LString ""))))
(DFunDef false "message" ((PVar "callee") (PCon "Some" (PVar "helper")) (PVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "helper"))) (ELit (LString "` tests `"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "` with `"))) (EApp (EMethodRef "display") (EVar "callee"))) (ELit (LString "`, and this loop grows `"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "` on every step, so each call walks the whole list and the loop is quadratic. "))) (EApp (EMethodRef "display") (EApp (EVar "fixFor") (EVar "callee")))) (ELit (LString ""))))
(DTypeSig false "fixFor" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "fixFor" ((PLit (LString "lookupAssoc"))) (EVar "lookupFix"))
(DFunDef false "fixFor" ((PLit (LString "lookup"))) (EVar "lookupFix"))
(DFunDef false "fixFor" (PWild) (ELit (LString "Keep the elements in a `Set` beside the list (`has`, `insert`), or build the set once before the loop")))
(DTypeSig false "lookupFix" (TyCon "String"))
(DFunDef false "lookupFix" () (ELit (LString "Keep the pairs in a `Map` beside the list (`get`, `insert`), or build the map once before the loop")))
