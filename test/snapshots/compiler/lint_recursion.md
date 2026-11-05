# META
source_lines=346
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_recursion.mdk — the shared reader of self-recursion: the
-- full-arity calls a body makes to its own owner, what each argument is made
-- of, and whether a fold lambda appends onto its accumulator.
--
-- An owner is a clause's name and parameter patterns.  A walk's `Ctx` names
-- the enclosing top-level declaration and nothing nearer, so a `where` or
-- `let` loop (`go`) is not the `Ctx` owner; `letOwners` reads those from the
-- `ELetGroup` node and hands them to the same `selfCalls`.
--
-- A call matches when its head is the owner's name, the file's scope model
-- resolves that head to the owner's own binder (a lambda parameter or local
-- `let` of the same name shadows it), and it passes exactly as many arguments
-- as the clause has parameters.  A partial application, an over-application
-- and a call to a different function (mutual recursion) never match.
--
-- An argument's role is read against the parameter it derives from.  `p ++ e`
-- is an append onto `p`; `e ++ p` is a prepend, which for a `List` costs only the
-- length of `e` (a `String`, `Bytes` or `Array` copies both operands), so it is
-- not reported as an accumulator append.  A name bound by a
-- `match` arm over a parameter (`x :: rest` over `xs`) derives from that
-- parameter.  No `types.*` import.

import frontend.ast.{
  Arm(..),
  DoStmt(..),
  Expr(..),
  FunClause(..),
  Guard(..),
  GuardArm(..),
  LetBind(..),
  Loc,
  Pat(..),
  patBoundNames,
}
import frontend.ast_walk.{childExprs}
import list.{findMap, get, last}
import tools.lint_calls.{lastSegment}
import tools.lint_scope.{Binder(..), BinderKind(..), FileScopes, binderOf}
import tools.lint_shared.{mentionsVar, unwrapLoc, varSite}

-- One clause of a function: its name, its parameter patterns and where the
-- name is bound: `None` at top level, else the span of the name token of the
-- `let`/`where` group binding.
public export data Owner = Owner String (List Pat) (Option Loc)

-- What an argument of a self-call is, relative to the parameter (by position)
-- it derives from.  `Unchanged j`: the parameter's own name.  `AppendedTo j`:
-- `p ++ e`.  `PrependedTo j`: `e ++ p`.  `Advanced j`: any other expression
-- that mentions a name bound by parameter `j`.  `Fresh`: mentions none.
public export data ArgRole =
  | Unchanged Int
  | Advanced Int
  | AppendedTo Int
  | PrependedTo Int
  | Fresh
  deriving (Eq, Debug)

-- One full-arity self-call: the span of the nearest enclosing `ELoc`, the call
-- expression and its arguments' roles in order.
public export data SelfCall = SelfCall (Option Loc) Expr (List ArgRole)

-- Whether a fold's lambda appends onto its accumulator.
public export data FoldVerdict =
  | NotAFold
  | FoldPlain
  | FoldAppends
  deriving (Eq, Debug)

-- A name a parameter binds: the name, the parameter's position, and whether
-- the name is the whole parameter and not a part of it.
data Bound = Bound String Int Bool

-- The owners of an `ELetGroup` node, one per clause, each with its body.
-- `[]` for any other node.
export
letOwners : Expr -> List (Owner, Expr)
letOwners e = match unwrapLoc e
  ELetGroup binds _ => flatMap bindOwners binds
  _ => []

bindOwners : LetBind -> List (Owner, Expr)
bindOwners (LetBind name clauses site _) =
  map ((FunClause ps body) => (Owner name ps (Some site), body)) clauses

-- The full-arity self-calls in `body`, pre-order.  A self-call's arguments are
-- searched too, so `go (go x)` yields both.
export
selfCalls : FileScopes -> Owner -> Expr -> List SelfCall
selfCalls scopes (owner@(Owner _ ps _)) body =
  walk scopes owner (paramEnv 0 ps) None body

paramEnv : Int -> List Pat -> List Bound
paramEnv _ [] = []
paramEnv j (p :: rest) = paramBounds j p ++ paramEnv (j + 1) rest

paramBounds : Int -> Pat -> List Bound
paramBounds j (PVar n _ _) = [Bound n j True]
paramBounds j (PAs x _ _ p) =
  Bound x j True :: map (n => Bound n j False) (patBoundNames p)
paramBounds j p = map (n => Bound n j False) (patBoundNames p)

walk : FileScopes -> Owner -> List Bound -> Option Loc -> Expr -> List SelfCall
-- Bound: hot compiler path: the where-go form allocates one closure per call until the lambda-lift pass (#4878); convert then.
-- lint-disable-next-line rule-threaded-invariant
walk scopes owner env _ (ELoc l inner) = walk scopes owner env (Some l) inner
walk scopes owner env loc e = match spineOf e []
  (hd, args) =>
    if isSelfCall scopes owner hd args then
      SelfCall loc e (roles env 0 args)
        :: flatMap (walk scopes owner env loc) args
    else match args
      [] => walkNode scopes owner env loc e
      _ =>
        walk scopes owner env loc hd ++ flatMap (walk scopes owner env loc) args

-- The head of an application chain with its arguments.  The head keeps its
-- `ELoc` wrappers, which carry the site the scope model is asked about.
export
spineOf : Expr -> List Expr -> (Expr, List Expr)
spineOf e args = match unwrapLoc e
  EApp f a => spineOf f (a :: args)
  _ => (e, args)

walkNode : FileScopes ->
  Owner ->
  List Bound ->
  Option Loc ->
  Expr ->
  List SelfCall
walkNode scopes owner env loc (EMatch scrut arms) =
  walk scopes owner env loc scrut
    ++ flatMap (walkArm scopes owner env loc scrut) arms
walkNode scopes owner env loc (ELam ps b) =
  walk scopes owner (without (flatMap patBoundNames ps) env) loc b
walkNode scopes owner env loc (ELet _ _ p e1 e2) =
  let env2 = without (patBoundNames p) env
  walk scopes owner env2 loc e1 ++ walk scopes owner env2 loc e2
walkNode scopes owner env loc (EBlock stmts) =
  walkStmts scopes owner env loc stmts
walkNode scopes owner env loc (EDo _ stmts) =
  walkStmts scopes owner env loc stmts
walkNode scopes owner env loc (EGuards arms) =
  flatMap ((GuardArm gs body) => walkGuarded scopes owner env loc gs body) arms
walkNode scopes owner env loc (e@(ELetGroup binds _)) =
  let env2 = without (flatMap groupNames binds) env
  flatMap (walk scopes owner env2 loc) (childExprs e)
walkNode scopes owner env loc e =
  flatMap (walk scopes owner env loc) (childExprs e)

-- A statement's binders scope over the statements after it, so they shadow
-- the parameters from there on.
walkStmts : FileScopes ->
  Owner ->
  List Bound ->
  Option Loc ->
  List DoStmt ->
  List SelfCall
walkStmts scopes owner env0 loc stmts0 = go env0 stmts0
  where
    go _ [] = []
    go env ((DoExpr e) :: rest) = walk scopes owner env loc e ++ go env rest
    go env ((DoBind p e) :: rest) =
      walk scopes owner env loc e ++ go (without (patBoundNames p) env) rest
    go env ((DoLet _ isRec p e _) :: rest) =
      let env2 = without (patBoundNames p) env
      walk scopes owner (if isRec then env2 else env) loc e ++ go env2 rest
    go env ((DoAssign _ e) :: rest) = walk scopes owner env loc e ++ go env rest
    go env ((DoFieldAssign _ _ e) :: rest) =
      walk scopes owner env loc e ++ go env rest

groupNames : LetBind -> List String
groupNames (LetBind n clauses _ _) =
  n :: flatMap (c => flatMap patBoundNames (clausePats c)) clauses

clausePats : FunClause -> List Pat
clausePats (FunClause ps _) = ps

without : List String -> List Bound -> List Bound
without [] env = env
without names env = filter (b => not (named b names)) env

named : Bound -> List String -> Bool
named (Bound n _ _) names = any (== n) names

-- An arm over a parameter's own name binds parts of that parameter.
walkArm : FileScopes ->
  Owner ->
  List Bound ->
  Option Loc ->
  Expr ->
  Arm ->
  List SelfCall
walkArm scopes owner env loc scrut (Arm p gs body) =
  let bound = patBoundNames p
  let env2 = without bound env ++ armBounds env scrut bound
  walkGuarded scopes owner env2 loc gs body

-- Guards run in order; a pattern guard's binders shadow the parameters in the
-- later guards and in the body.
walkGuarded : FileScopes ->
  Owner ->
  List Bound ->
  Option Loc ->
  List Guard ->
  Expr ->
  List SelfCall
walkGuarded scopes owner env0 loc gs0 body = go env0 gs0
  where
    go env [] = walk scopes owner env loc body
    go env ((GBool e) :: gs) = walk scopes owner env loc e ++ go env gs
    go env ((GBind p e) :: gs) =
      walk scopes owner env loc e ++ go (without (patBoundNames p) env) gs

armBounds : List Bound -> Expr -> List String -> List Bound
armBounds env scrut bound = match unwrapLoc scrut
  EVar n => match findMap (b => boundIndex n b) env
    Some j => map (m => Bound m j False) bound
    None => []
  _ => []

boundIndex : String -> Bound -> Option Int
boundIndex n (Bound m j _) = if n == m then Some j else None

isSelfCall : FileScopes -> Owner -> Expr -> List Expr -> Bool
isSelfCall scopes (owner@(Owner name ps _)) hd args =
  isNamed name hd
    && length args == length ps
    && bindsOwner scopes owner (varSite hd)

isNamed : String -> Expr -> Bool
isNamed name e = match unwrapLoc e
  EVar n => n == name
  _ => False

bindsOwner : FileScopes -> Owner -> Option Loc -> Bool
bindsOwner _ _ None = False
bindsOwner scopes (Owner name _ kind) (Some l) = match binderOf scopes l
  None => False
  Some b => b.binderName == name && bindsAs kind b

bindsAs : Option Loc -> Binder -> Bool
bindsAs None b = b.binderKind == BTopLevel
bindsAs (Some site) b =
  (b.binderKind == BLetGroup || b.binderKind == BWhere) && b.binderSpan == site

-- ── argument roles ────────────────────────────────────────────────────────────

-- The roles of the arguments from position `i` on.
roles : List Bound -> Int -> List Expr -> List ArgRole
roles _ _ [] = []
roles env i (a :: rest) = argRole env i a :: roles env (i + 1) rest

-- The role of the argument at position `i`.  An expression built from several
-- parameters is read against the one at its own position when it mentions it.
argRole : List Bound -> Int -> Expr -> ArgRole
argRole env i e = match unwrapLoc e
  EVar n => optionOr Fresh (findMap (boundRole n) env)
  EBinOp "++" a b _ => appendRole env i a b e
  _ => derivedRole env i e

boundRole : String -> Bound -> Option ArgRole
boundRole n (Bound m j whole)
  | n /= m = None
  | whole = Some (Unchanged j)
  | otherwise = Some (Advanced j)

appendRole : List Bound -> Int -> Expr -> Expr -> Expr -> ArgRole
appendRole env i a b whole = match argRole env i a
  Unchanged j => AppendedTo j
  AppendedTo j => AppendedTo j
  _ => match argRole env i b
    Unchanged j => PrependedTo j
    _ => derivedRole env i whole

derivedRole : List Bound -> Int -> Expr -> ArgRole
derivedRole env i e = match mentioned env e
  [] => Fresh
  js@(j :: _) => Advanced (if any (== i) js then i else j)

-- Positions of the parameters whose names `e` mentions, in parameter order.
mentioned : List Bound -> Expr -> List Int
mentioned env e = flatMap (b => mentionedIn e b) env

mentionedIn : Expr -> Bound -> List Int
mentionedIn e (Bound n j _) = if mentionsVar n e then [j] else []

-- ── fold lambdas ─────────────────────────────────────────────────────────────

-- For an application node: whether its head is a fold from the stdlib and one
-- of its lambda arguments appends onto the accumulator (`acc ++ e`) in a tail
-- position of the body.  The head is matched by name (the last segment of a
-- qualified one), not by the scope model, and a qualified or aliased fold is
-- the same fold.
export
foldVerdict : Expr -> FoldVerdict
foldVerdict e = match spineOf e []
  (_, []) => NotAFold
  (hd, args) => match unwrapLoc hd
    EVar n => match foldAccIndex (lastSegment n)
      None => NotAFold
      Some k =>
        if any (a => lamAppends k a) args then FoldAppends else FoldPlain
    _ => NotAFold

-- Position of the accumulator among a fold lambda's parameters, by name.
export
foldAccIndex : String -> Option Int
foldAccIndex "fold" = Some 0
foldAccIndex "foldThen" = Some 0
foldAccIndex "foldlSet" = Some 0
foldAccIndex "foldlWithKey" = Some 0
foldAccIndex "foldWithIndex" = Some 0
foldAccIndex "foldRight" = Some 1
foldAccIndex "foldrSet" = Some 1
foldAccIndex "foldrWithKey" = Some 2
foldAccIndex _ = None

lamAppends : Int -> Expr -> Bool
lamAppends k e = match unwrapLoc e
  ELam ps body => match get k ps
    Some (PVar acc _ _) => tailAppends acc body
    _ => False
  _ => False

-- Whether some tail position of `e` is `acc ++ e1`.
tailAppends : String -> Expr -> Bool
tailAppends acc e = match unwrapLoc e
  EBinOp "++" a _ _ => leftIsAcc acc a
  EIf _ t el => tailAppends acc t || tailAppends acc el
  EMatch _ arms => any (armAppends acc) arms
  ELet _ _ _ _ body => tailAppends acc body
  ELetGroup _ body => tailAppends acc body
  EBlock stmts => match last stmts
    Some (DoExpr l) => tailAppends acc l
    _ => False
  ELit _ | EVar _ | EApp _ _ | ELam _ _ | EUnOp _ _ _ | EInfix _ _ _ | EFieldAccess _ _ _ | ETuple _ | EListLit _ | EArrayLit _ | ERangeList _ _ _ | ERangeArray _ _ _ | ESlice _ _ _ _ | ESection _ | EIndex _ _ | EAnnot _ _ | EHeadAnnot _ _ | EDo _ _ | EStringInterp _ | EGuards _ | ERecordCreate _ _ | ERecordUpdate _ _ _ | EVariantUpdate _ _ _ | EMapLit _ _ | ESetLit _ _ | EAsPat _ _ | EOrPat _ | EMethodRef _ | EDictApp _ | EVarAt _ _ | EVarId _ _ | EMethodAt _ _ _ | EDictAt _ _ | ELoc _ _ | EDoOrigin _ _ | ENumLit _ _ _ | EWideLit _ _ _ _ | EBinOp _ _ _ _ =>
    False

leftIsAcc : String -> Expr -> Bool
leftIsAcc acc a = match unwrapLoc a
  EVar n => n == acc
  EBinOp "++" a2 _ _ => leftIsAcc acc a2
  _ => False

armAppends : String -> Arm -> Bool
armAppends acc (Arm _ _ body) = tailAppends acc body
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "DoStmt" true) (mem "Expr" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "LetBind" true) (mem "Loc" false) (mem "Pat" true) (mem "patBoundNames" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "childExprs" false))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "get" false) (mem "last" false))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "lastSegment" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "Binder" true) (mem "BinderKind" true) (mem "FileScopes" false) (mem "binderOf" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "mentionsVar" false) (mem "unwrapLoc" false) (mem "varSite" false))))
(DData Public "Owner" () ((variant "Owner" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DData Public "ArgRole" () ((variant "Unchanged" (ConPos (TyCon "Int"))) (variant "Advanced" (ConPos (TyCon "Int"))) (variant "AppendedTo" (ConPos (TyCon "Int"))) (variant "PrependedTo" (ConPos (TyCon "Int"))) (variant "Fresh" (ConPos))) ())
(DImpl true "Eq" ((TyCon "ArgRole")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Unchanged" (PVar "__a0")) (PCon "Unchanged" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Advanced" (PVar "__a0")) (PCon "Advanced" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "AppendedTo" (PVar "__a0")) (PCon "AppendedTo" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "PrependedTo" (PVar "__a0")) (PCon "PrependedTo" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Fresh") (PCon "Fresh")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "ArgRole")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Unchanged" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Unchanged ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "Advanced" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Advanced ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "AppendedTo" (PVar "__a0")) () (EBinOp "++" (ELit (LString "AppendedTo ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "PrependedTo" (PVar "__a0")) () (EBinOp "++" (ELit (LString "PrependedTo ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "Fresh") () (ELit (LString "Fresh")))))))
(DData Public "SelfCall" () ((variant "SelfCall" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ArgRole"))))) ())
(DData Public "FoldVerdict" () ((variant "NotAFold" (ConPos)) (variant "FoldPlain" (ConPos)) (variant "FoldAppends" (ConPos))) ())
(DImpl true "Eq" ((TyCon "FoldVerdict")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "NotAFold") (PCon "NotAFold")) () (EVar "True")) (arm (PTuple (PCon "FoldPlain") (PCon "FoldPlain")) () (EVar "True")) (arm (PTuple (PCon "FoldAppends") (PCon "FoldAppends")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "FoldVerdict")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "NotAFold") () (ELit (LString "NotAFold"))) (arm (PCon "FoldPlain") () (ELit (LString "FoldPlain"))) (arm (PCon "FoldAppends") () (ELit (LString "FoldAppends")))))))
(DData Private "Bound" () ((variant "Bound" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Bool")))) ())
(DTypeSig true "letOwners" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Owner") (TyCon "Expr")))))
(DFunDef false "letOwners" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELetGroup" (PVar "binds") PWild) () (EApp (EApp (EVar "flatMap") (EVar "bindOwners")) (EVar "binds"))) (arm PWild () (EListLit))))
(DTypeSig false "bindOwners" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyTuple (TyCon "Owner") (TyCon "Expr")))))
(DFunDef false "bindOwners" ((PCon "LetBind" (PVar "name") (PVar "clauses") (PVar "site") PWild)) (EApp (EApp (EVar "map") (ELam ((PCon "FunClause" (PVar "ps") (PVar "body"))) (ETuple (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EApp (EVar "Some") (EVar "site"))) (EVar "body")))) (EVar "clauses")))
(DTypeSig true "selfCalls" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "SelfCall"))))))
(DFunDef false "selfCalls" ((PVar "scopes") (PAs "owner" (PCon "Owner" PWild (PVar "ps") PWild)) (PVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EApp (EApp (EVar "paramEnv") (ELit (LInt 0))) (EVar "ps"))) (EVar "None")) (EVar "body")))
(DTypeSig false "paramEnv" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Bound")))))
(DFunDef false "paramEnv" (PWild (PList)) (EListLit))
(DFunDef false "paramEnv" ((PVar "j") (PCons (PVar "p") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "paramBounds") (EVar "j")) (EVar "p")) (EApp (EApp (EVar "paramEnv") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "paramBounds" (TyFun (TyCon "Int") (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "Bound")))))
(DFunDef false "paramBounds" ((PVar "j") (PCon "PVar" (PVar "n") PWild PWild)) (EListLit (EApp (EApp (EApp (EVar "Bound") (EVar "n")) (EVar "j")) (EVar "True"))))
(DFunDef false "paramBounds" ((PVar "j") (PCon "PAs" (PVar "x") PWild PWild (PVar "p"))) (EBinOp "::" (EApp (EApp (EApp (EVar "Bound") (EVar "x")) (EVar "j")) (EVar "True")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EApp (EVar "Bound") (EVar "n")) (EVar "j")) (EVar "False")))) (EApp (EVar "patBoundNames") (EVar "p")))))
(DFunDef false "paramBounds" ((PVar "j") (PVar "p")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EApp (EVar "Bound") (EVar "n")) (EVar "j")) (EVar "False")))) (EApp (EVar "patBoundNames") (EVar "p"))))
(DTypeSig false "walk" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "SelfCall"))))))))
(DFunDef false "walk" ((PVar "scopes") (PVar "owner") (PVar "env") PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EApp (EVar "Some") (EVar "l"))) (EVar "inner")))
(DFunDef false "walk" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PVar "e")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EIf (EApp (EApp (EApp (EApp (EVar "isSelfCall") (EVar "scopes")) (EVar "owner")) (EVar "hd")) (EVar "args")) (EBinOp "::" (EApp (EApp (EApp (EVar "SelfCall") (EVar "loc")) (EVar "e")) (EApp (EApp (EApp (EVar "roles") (EVar "env")) (ELit (LInt 0))) (EVar "args"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc"))) (EVar "args"))) (EMatch (EVar "args") (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EVar "walkNode") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e"))) (arm PWild () (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "hd")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc"))) (EVar "args")))))))))
(DTypeSig true "spineOf" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "spineOf" ((PVar "e") (PVar "args")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") (PVar "a")) () (EApp (EApp (EVar "spineOf") (EVar "f")) (EBinOp "::" (EVar "a") (EVar "args")))) (arm PWild () (ETuple (EVar "e") (EVar "args")))))
(DTypeSig false "walkNode" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "SelfCall"))))))))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "scrut")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EApp (EVar "walkArm") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "scrut"))) (EVar "arms"))))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EApp (EApp (EVar "without") (EApp (EApp (EVar "flatMap") (EVar "patBoundNames")) (EVar "ps"))) (EVar "env"))) (EVar "loc")) (EVar "b")))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PCon "ELet" PWild PWild (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "env2") (EApp (EApp (EVar "without") (EApp (EVar "patBoundNames") (EVar "p"))) (EVar "env"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env2")) (EVar "loc")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env2")) (EVar "loc")) (EVar "e2"))))))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "stmts")))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "stmts")))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "flatMap") (ELam ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "gs")) (EVar "body")))) (EVar "arms")))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PAs "e" (PCon "ELetGroup" (PVar "binds") PWild))) (EBlock (DoLet false false (PVar "env2") (EApp (EApp (EVar "without") (EApp (EApp (EVar "flatMap") (EVar "groupNames")) (EVar "binds"))) (EVar "env"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env2")) (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e"))))))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PVar "e")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e"))))
(DTypeSig false "walkStmts" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "SelfCall"))))))))
(DFunDef false "walkStmts" ((PVar "scopes") (PVar "owner") (PVar "env0") (PVar "loc") (PVar "stmts0")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "env") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EVar "env")) (EVar "rest")))) (clause ((PVar "env") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EApp (EApp (EVar "without") (EApp (EVar "patBoundNames") (EVar "p"))) (EVar "env"))) (EVar "rest")))) (clause ((PVar "env") (PCons (PCon "DoLet" PWild (PVar "isRec") (PVar "p") (PVar "e") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "env2") (EApp (EApp (EVar "without") (EApp (EVar "patBoundNames") (EVar "p"))) (EVar "env"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EIf (EVar "isRec") (EVar "env2") (EVar "env"))) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EVar "env2")) (EVar "rest")))))) (clause ((PVar "env") (PCons (PCon "DoAssign" PWild (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EVar "env")) (EVar "rest")))) (clause ((PVar "env") (PCons (PCon "DoFieldAssign" PWild PWild (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EVar "env")) (EVar "rest")))))) (EApp (EApp (EVar "go") (EVar "env0")) (EVar "stmts0"))))
(DTypeSig false "groupNames" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "groupNames" ((PCon "LetBind" (PVar "n") (PVar "clauses") PWild PWild)) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EApp (EApp (EVar "flatMap") (EVar "patBoundNames")) (EApp (EVar "clausePats") (EVar "c"))))) (EVar "clauses"))))
(DTypeSig false "clausePats" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "clausePats" ((PCon "FunClause" (PVar "ps") PWild)) (EVar "ps"))
(DTypeSig false "without" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyApp (TyCon "List") (TyCon "Bound")))))
(DFunDef false "without" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "without" ((PVar "names") (PVar "env")) (EApp (EApp (EVar "filter") (ELam ((PVar "b")) (EApp (EVar "not") (EApp (EApp (EVar "named") (EVar "b")) (EVar "names"))))) (EVar "env")))
(DTypeSig false "named" (TyFun (TyCon "Bound") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "named" ((PCon "Bound" (PVar "n") PWild PWild) (PVar "names")) (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EVar "names")))
(DTypeSig false "walkArm" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "SelfCall")))))))))
(DFunDef false "walkArm" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PVar "scrut") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "bound") (EApp (EVar "patBoundNames") (EVar "p"))) (DoLet false false (PVar "env2") (EBinOp "++" (EApp (EApp (EVar "without") (EVar "bound")) (EVar "env")) (EApp (EApp (EApp (EVar "armBounds") (EVar "env")) (EVar "scrut")) (EVar "bound")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "scopes")) (EVar "owner")) (EVar "env2")) (EVar "loc")) (EVar "gs")) (EVar "body")))))
(DTypeSig false "walkGuarded" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "SelfCall")))))))))
(DFunDef false "walkGuarded" ((PVar "scopes") (PVar "owner") (PVar "env0") (PVar "loc") (PVar "gs0") (PVar "body")) (ELetGroup ((lgb "go" (clause ((PVar "env") (PList)) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "body"))) (clause ((PVar "env") (PCons (PCon "GBool" (PVar "e")) (PVar "gs"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EVar "env")) (EVar "gs")))) (clause ((PVar "env") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "gs"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EApp (EApp (EVar "without") (EApp (EVar "patBoundNames") (EVar "p"))) (EVar "env"))) (EVar "gs")))))) (EApp (EApp (EVar "go") (EVar "env0")) (EVar "gs0"))))
(DTypeSig false "armBounds" (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Bound"))))))
(DFunDef false "armBounds" ((PVar "env") (PVar "scrut") (PVar "bound")) (EMatch (EApp (EVar "unwrapLoc") (EVar "scrut")) (arm (PCon "EVar" (PVar "n")) () (EMatch (EApp (EApp (EVar "findMap") (ELam ((PVar "b")) (EApp (EApp (EVar "boundIndex") (EVar "n")) (EVar "b")))) (EVar "env")) (arm (PCon "Some" (PVar "j")) () (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "Bound") (EVar "m")) (EVar "j")) (EVar "False")))) (EVar "bound"))) (arm (PCon "None") () (EListLit)))) (arm PWild () (EListLit))))
(DTypeSig false "boundIndex" (TyFun (TyCon "String") (TyFun (TyCon "Bound") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "boundIndex" ((PVar "n") (PCon "Bound" (PVar "m") (PVar "j") PWild)) (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EApp (EVar "Some") (EVar "j")) (EVar "None")))
(DTypeSig false "isSelfCall" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool"))))))
(DFunDef false "isSelfCall" ((PVar "scopes") (PAs "owner" (PCon "Owner" (PVar "name") (PVar "ps") PWild)) (PVar "hd") (PVar "args")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isNamed") (EVar "name")) (EVar "hd")) (EBinOp "==" (EApp (EVar "length") (EVar "args")) (EApp (EVar "length") (EVar "ps")))) (EApp (EApp (EApp (EVar "bindsOwner") (EVar "scopes")) (EVar "owner")) (EApp (EVar "varSite") (EVar "hd")))))
(DTypeSig false "isNamed" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isNamed" ((PVar "name") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm PWild () (EVar "False"))))
(DTypeSig false "bindsOwner" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool")))))
(DFunDef false "bindsOwner" (PWild PWild (PCon "None")) (EVar "False"))
(DFunDef false "bindsOwner" ((PVar "scopes") (PCon "Owner" (PVar "name") PWild (PVar "kind")) (PCon "Some" (PVar "l"))) (EMatch (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "l")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "b")) () (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "name")) (EApp (EApp (EVar "bindsAs") (EVar "kind")) (EVar "b"))))))
(DTypeSig false "bindsAs" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Binder") (TyCon "Bool"))))
(DFunDef false "bindsAs" ((PCon "None") (PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BTopLevel")))
(DFunDef false "bindsAs" ((PCon "Some" (PVar "site")) (PVar "b")) (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BLetGroup")) (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BWhere"))) (EBinOp "==" (EFieldAccess (EVar "b") "binderSpan") (EVar "site"))))
(DTypeSig false "roles" (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "ArgRole"))))))
(DFunDef false "roles" (PWild PWild (PList)) (EListLit))
(DFunDef false "roles" ((PVar "env") (PVar "i") (PCons (PVar "a") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "argRole") (EVar "env")) (EVar "i")) (EVar "a")) (EApp (EApp (EApp (EVar "roles") (EVar "env")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "argRole" (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "ArgRole")))))
(DFunDef false "argRole" ((PVar "env") (PVar "i") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "n")) () (EApp (EApp (EVar "optionOr") (EVar "Fresh")) (EApp (EApp (EVar "findMap") (EApp (EVar "boundRole") (EVar "n"))) (EVar "env")))) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "a") (PVar "b") PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "appendRole") (EVar "env")) (EVar "i")) (EVar "a")) (EVar "b")) (EVar "e"))) (arm PWild () (EApp (EApp (EApp (EVar "derivedRole") (EVar "env")) (EVar "i")) (EVar "e")))))
(DTypeSig false "boundRole" (TyFun (TyCon "String") (TyFun (TyCon "Bound") (TyApp (TyCon "Option") (TyCon "ArgRole")))))
(DFunDef false "boundRole" ((PVar "n") (PCon "Bound" (PVar "m") (PVar "j") (PVar "whole"))) (EIf (EBinOp "/=" (EVar "n") (EVar "m")) (EVar "None") (EIf (EVar "whole") (EApp (EVar "Some") (EApp (EVar "Unchanged") (EVar "j"))) (EIf (EVar "otherwise") (EApp (EVar "Some") (EApp (EVar "Advanced") (EVar "j"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "appendRole" (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "ArgRole")))))))
(DFunDef false "appendRole" ((PVar "env") (PVar "i") (PVar "a") (PVar "b") (PVar "whole")) (EMatch (EApp (EApp (EApp (EVar "argRole") (EVar "env")) (EVar "i")) (EVar "a")) (arm (PCon "Unchanged" (PVar "j")) () (EApp (EVar "AppendedTo") (EVar "j"))) (arm (PCon "AppendedTo" (PVar "j")) () (EApp (EVar "AppendedTo") (EVar "j"))) (arm PWild () (EMatch (EApp (EApp (EApp (EVar "argRole") (EVar "env")) (EVar "i")) (EVar "b")) (arm (PCon "Unchanged" (PVar "j")) () (EApp (EVar "PrependedTo") (EVar "j"))) (arm PWild () (EApp (EApp (EApp (EVar "derivedRole") (EVar "env")) (EVar "i")) (EVar "whole")))))))
(DTypeSig false "derivedRole" (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "ArgRole")))))
(DFunDef false "derivedRole" ((PVar "env") (PVar "i") (PVar "e")) (EMatch (EApp (EApp (EVar "mentioned") (EVar "env")) (EVar "e")) (arm (PList) () (EVar "Fresh")) (arm (PAs "js" (PCons (PVar "j") PWild)) () (EApp (EVar "Advanced") (EIf (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "i")))) (EVar "js")) (EVar "i") (EVar "j"))))))
(DTypeSig false "mentioned" (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "mentioned" ((PVar "env") (PVar "e")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "b")) (EApp (EApp (EVar "mentionedIn") (EVar "e")) (EVar "b")))) (EVar "env")))
(DTypeSig false "mentionedIn" (TyFun (TyCon "Expr") (TyFun (TyCon "Bound") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "mentionedIn" ((PVar "e") (PCon "Bound" (PVar "n") (PVar "j") PWild)) (EIf (EApp (EApp (EVar "mentionsVar") (EVar "n")) (EVar "e")) (EListLit (EVar "j")) (EListLit)))
(DTypeSig true "foldVerdict" (TyFun (TyCon "Expr") (TyCon "FoldVerdict")))
(DFunDef false "foldVerdict" ((PVar "e")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple PWild (PList)) () (EVar "NotAFold")) (arm (PTuple (PVar "hd") (PVar "args")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "n")) () (EMatch (EApp (EVar "foldAccIndex") (EApp (EVar "lastSegment") (EVar "n"))) (arm (PCon "None") () (EVar "NotAFold")) (arm (PCon "Some" (PVar "k")) () (EIf (EApp (EApp (EVar "any") (ELam ((PVar "a")) (EApp (EApp (EVar "lamAppends") (EVar "k")) (EVar "a")))) (EVar "args")) (EVar "FoldAppends") (EVar "FoldPlain"))))) (arm PWild () (EVar "NotAFold"))))))
(DTypeSig true "foldAccIndex" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "foldAccIndex" ((PLit (LString "fold"))) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldThen"))) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldlSet"))) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldlWithKey"))) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldWithIndex"))) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldRight"))) (EApp (EVar "Some") (ELit (LInt 1))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldrSet"))) (EApp (EVar "Some") (ELit (LInt 1))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldrWithKey"))) (EApp (EVar "Some") (ELit (LInt 2))))
(DFunDef false "foldAccIndex" (PWild) (EVar "None"))
(DTypeSig false "lamAppends" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "lamAppends" ((PVar "k") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELam" (PVar "ps") (PVar "body")) () (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "ps")) (arm (PCon "Some" (PCon "PVar" (PVar "acc") PWild PWild)) () (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "body"))) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "tailAppends" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "tailAppends" ((PVar "acc") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "a") PWild PWild) () (EApp (EApp (EVar "leftIsAcc") (EVar "acc")) (EVar "a"))) (arm (PCon "EIf" PWild (PVar "t") (PVar "el")) () (EBinOp "||" (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "t")) (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "el")))) (arm (PCon "EMatch" PWild (PVar "arms")) () (EApp (EApp (EVar "any") (EApp (EVar "armAppends") (EVar "acc"))) (EVar "arms"))) (arm (PCon "ELet" PWild PWild PWild PWild (PVar "body")) () (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "body"))) (arm (PCon "ELetGroup" PWild (PVar "body")) () (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "body"))) (arm (PCon "EBlock" (PVar "stmts")) () (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoExpr" (PVar "l"))) () (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "l"))) (arm PWild () (EVar "False")))) (arm (POr (PCon "ELit" PWild) (PCon "EVar" PWild) (PCon "EApp" PWild PWild) (PCon "ELam" PWild PWild) (PCon "EUnOp" PWild PWild PWild) (PCon "EInfix" PWild PWild PWild) (PCon "EFieldAccess" PWild PWild PWild) (PCon "ETuple" PWild) (PCon "EListLit" PWild) (PCon "EArrayLit" PWild) (PCon "ERangeList" PWild PWild PWild) (PCon "ERangeArray" PWild PWild PWild) (PCon "ESlice" PWild PWild PWild PWild) (PCon "ESection" PWild) (PCon "EIndex" PWild PWild) (PCon "EAnnot" PWild PWild) (PCon "EHeadAnnot" PWild PWild) (PCon "EDo" PWild PWild) (PCon "EStringInterp" PWild) (PCon "EGuards" PWild) (PCon "ERecordCreate" PWild PWild) (PCon "ERecordUpdate" PWild PWild PWild) (PCon "EVariantUpdate" PWild PWild PWild) (PCon "EMapLit" PWild PWild) (PCon "ESetLit" PWild PWild) (PCon "EAsPat" PWild PWild) (PCon "EOrPat" PWild) (PCon "EMethodRef" PWild) (PCon "EDictApp" PWild) (PCon "EVarAt" PWild PWild) (PCon "EVarId" PWild PWild) (PCon "EMethodAt" PWild PWild PWild) (PCon "EDictAt" PWild PWild) (PCon "ELoc" PWild PWild) (PCon "EDoOrigin" PWild PWild) (PCon "ENumLit" PWild PWild PWild) (PCon "EWideLit" PWild PWild PWild PWild) (PCon "EBinOp" PWild PWild PWild PWild)) () (EVar "False"))))
(DTypeSig false "leftIsAcc" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "leftIsAcc" ((PVar "acc") (PVar "a")) (EMatch (EApp (EVar "unwrapLoc") (EVar "a")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "acc"))) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "a2") PWild PWild) () (EApp (EApp (EVar "leftIsAcc") (EVar "acc")) (EVar "a2"))) (arm PWild () (EVar "False"))))
(DTypeSig false "armAppends" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armAppends" ((PVar "acc") (PCon "Arm" PWild PWild (PVar "body"))) (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "body")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "DoStmt" true) (mem "Expr" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "LetBind" true) (mem "Loc" false) (mem "Pat" true) (mem "patBoundNames" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "childExprs" false))))
(DUse false (UseGroup ("list") ((mem "findMap" false) (mem "get" false) (mem "last" false))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "lastSegment" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "Binder" true) (mem "BinderKind" true) (mem "FileScopes" false) (mem "binderOf" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "mentionsVar" false) (mem "unwrapLoc" false) (mem "varSite" false))))
(DData Public "Owner" () ((variant "Owner" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DData Public "ArgRole" () ((variant "Unchanged" (ConPos (TyCon "Int"))) (variant "Advanced" (ConPos (TyCon "Int"))) (variant "AppendedTo" (ConPos (TyCon "Int"))) (variant "PrependedTo" (ConPos (TyCon "Int"))) (variant "Fresh" (ConPos))) ())
(DImpl true "Eq" ((TyCon "ArgRole")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Unchanged" (PVar "__a0")) (PCon "Unchanged" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Advanced" (PVar "__a0")) (PCon "Advanced" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "AppendedTo" (PVar "__a0")) (PCon "AppendedTo" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "PrependedTo" (PVar "__a0")) (PCon "PrependedTo" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "Fresh") (PCon "Fresh")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "ArgRole")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Unchanged" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Unchanged ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "Advanced" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Advanced ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "AppendedTo" (PVar "__a0")) () (EBinOp "++" (ELit (LString "AppendedTo ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "PrependedTo" (PVar "__a0")) () (EBinOp "++" (ELit (LString "PrependedTo ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "Fresh") () (ELit (LString "Fresh")))))))
(DData Public "SelfCall" () ((variant "SelfCall" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ArgRole"))))) ())
(DData Public "FoldVerdict" () ((variant "NotAFold" (ConPos)) (variant "FoldPlain" (ConPos)) (variant "FoldAppends" (ConPos))) ())
(DImpl true "Eq" ((TyCon "FoldVerdict")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "NotAFold") (PCon "NotAFold")) () (EVar "True")) (arm (PTuple (PCon "FoldPlain") (PCon "FoldPlain")) () (EVar "True")) (arm (PTuple (PCon "FoldAppends") (PCon "FoldAppends")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "FoldVerdict")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "NotAFold") () (ELit (LString "NotAFold"))) (arm (PCon "FoldPlain") () (ELit (LString "FoldPlain"))) (arm (PCon "FoldAppends") () (ELit (LString "FoldAppends")))))))
(DData Private "Bound" () ((variant "Bound" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Bool")))) ())
(DTypeSig true "letOwners" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "Owner") (TyCon "Expr")))))
(DFunDef false "letOwners" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELetGroup" (PVar "binds") PWild) () (EApp (EApp (EDictApp "flatMap") (EVar "bindOwners")) (EVar "binds"))) (arm PWild () (EListLit))))
(DTypeSig false "bindOwners" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyTuple (TyCon "Owner") (TyCon "Expr")))))
(DFunDef false "bindOwners" ((PCon "LetBind" (PVar "name") (PVar "clauses") (PVar "site") PWild)) (EApp (EApp (EMethodRef "map") (ELam ((PCon "FunClause" (PVar "ps") (PVar "body"))) (ETuple (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EApp (EVar "Some") (EVar "site"))) (EVar "body")))) (EVar "clauses")))
(DTypeSig true "selfCalls" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "SelfCall"))))))
(DFunDef false "selfCalls" ((PVar "scopes") (PAs "owner" (PCon "Owner" PWild (PVar "ps") PWild)) (PVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EApp (EApp (EVar "paramEnv") (ELit (LInt 0))) (EVar "ps"))) (EVar "None")) (EVar "body")))
(DTypeSig false "paramEnv" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Bound")))))
(DFunDef false "paramEnv" (PWild (PList)) (EListLit))
(DFunDef false "paramEnv" ((PVar "j") (PCons (PVar "p") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "paramBounds") (EVar "j")) (EVar "p")) (EApp (EApp (EVar "paramEnv") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "paramBounds" (TyFun (TyCon "Int") (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "Bound")))))
(DFunDef false "paramBounds" ((PVar "j") (PCon "PVar" (PVar "n") PWild PWild)) (EListLit (EApp (EApp (EApp (EVar "Bound") (EVar "n")) (EVar "j")) (EVar "True"))))
(DFunDef false "paramBounds" ((PVar "j") (PCon "PAs" (PVar "x") PWild PWild (PVar "p"))) (EBinOp "::" (EApp (EApp (EApp (EVar "Bound") (EVar "x")) (EVar "j")) (EVar "True")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EApp (EVar "Bound") (EVar "n")) (EVar "j")) (EVar "False")))) (EApp (EVar "patBoundNames") (EVar "p")))))
(DFunDef false "paramBounds" ((PVar "j") (PVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EApp (EVar "Bound") (EVar "n")) (EVar "j")) (EVar "False")))) (EApp (EVar "patBoundNames") (EVar "p"))))
(DTypeSig false "walk" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "SelfCall"))))))))
(DFunDef false "walk" ((PVar "scopes") (PVar "owner") (PVar "env") PWild (PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EApp (EVar "Some") (EVar "l"))) (EVar "inner")))
(DFunDef false "walk" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PVar "e")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EIf (EApp (EApp (EApp (EApp (EVar "isSelfCall") (EVar "scopes")) (EVar "owner")) (EVar "hd")) (EVar "args")) (EBinOp "::" (EApp (EApp (EApp (EVar "SelfCall") (EVar "loc")) (EVar "e")) (EApp (EApp (EApp (EVar "roles") (EVar "env")) (ELit (LInt 0))) (EVar "args"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc"))) (EVar "args"))) (EMatch (EVar "args") (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EVar "walkNode") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e"))) (arm PWild () (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "hd")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc"))) (EVar "args")))))))))
(DTypeSig true "spineOf" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "spineOf" ((PVar "e") (PVar "args")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") (PVar "a")) () (EApp (EApp (EVar "spineOf") (EVar "f")) (EBinOp "::" (EVar "a") (EVar "args")))) (arm PWild () (ETuple (EVar "e") (EVar "args")))))
(DTypeSig false "walkNode" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "SelfCall"))))))))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "scrut")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EApp (EVar "walkArm") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "scrut"))) (EVar "arms"))))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EApp (EApp (EVar "without") (EApp (EApp (EDictApp "flatMap") (EVar "patBoundNames")) (EVar "ps"))) (EVar "env"))) (EVar "loc")) (EVar "b")))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PCon "ELet" PWild PWild (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "env2") (EApp (EApp (EVar "without") (EApp (EVar "patBoundNames") (EVar "p"))) (EVar "env"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env2")) (EVar "loc")) (EVar "e1")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env2")) (EVar "loc")) (EVar "e2"))))))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "stmts")))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "stmts")))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "gs")) (EVar "body")))) (EVar "arms")))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PAs "e" (PCon "ELetGroup" (PVar "binds") PWild))) (EBlock (DoLet false false (PVar "env2") (EApp (EApp (EVar "without") (EApp (EApp (EDictApp "flatMap") (EVar "groupNames")) (EVar "binds"))) (EVar "env"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env2")) (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e"))))))
(DFunDef false "walkNode" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PVar "e")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc"))) (EApp (EVar "childExprs") (EVar "e"))))
(DTypeSig false "walkStmts" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "SelfCall"))))))))
(DFunDef false "walkStmts" ((PVar "scopes") (PVar "owner") (PVar "env0") (PVar "loc") (PVar "stmts0")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "env") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EVar "env")) (EVar "rest")))) (clause ((PVar "env") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EApp (EApp (EVar "without") (EApp (EVar "patBoundNames") (EVar "p"))) (EVar "env"))) (EVar "rest")))) (clause ((PVar "env") (PCons (PCon "DoLet" PWild (PVar "isRec") (PVar "p") (PVar "e") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "env2") (EApp (EApp (EVar "without") (EApp (EVar "patBoundNames") (EVar "p"))) (EVar "env"))) (DoExpr (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EIf (EVar "isRec") (EVar "env2") (EVar "env"))) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EVar "env2")) (EVar "rest")))))) (clause ((PVar "env") (PCons (PCon "DoAssign" PWild (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EVar "env")) (EVar "rest")))) (clause ((PVar "env") (PCons (PCon "DoFieldAssign" PWild PWild (PVar "e")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EVar "env")) (EVar "rest")))))) (EApp (EApp (EVar "go") (EVar "env0")) (EVar "stmts0"))))
(DTypeSig false "groupNames" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "groupNames" ((PCon "LetBind" (PVar "n") (PVar "clauses") PWild PWild)) (EBinOp "::" (EVar "n") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EApp (EApp (EDictApp "flatMap") (EVar "patBoundNames")) (EApp (EVar "clausePats") (EVar "c"))))) (EVar "clauses"))))
(DTypeSig false "clausePats" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "clausePats" ((PCon "FunClause" (PVar "ps") PWild)) (EVar "ps"))
(DTypeSig false "without" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyApp (TyCon "List") (TyCon "Bound")))))
(DFunDef false "without" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "without" ((PVar "names") (PVar "env")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "b")) (EApp (EVar "not") (EApp (EApp (EVar "named") (EVar "b")) (EVar "names"))))) (EVar "env")))
(DTypeSig false "named" (TyFun (TyCon "Bound") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "named" ((PCon "Bound" (PVar "n") PWild PWild) (PVar "names")) (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EVar "names")))
(DTypeSig false "walkArm" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "SelfCall")))))))))
(DFunDef false "walkArm" ((PVar "scopes") (PVar "owner") (PVar "env") (PVar "loc") (PVar "scrut") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "bound") (EApp (EVar "patBoundNames") (EVar "p"))) (DoLet false false (PVar "env2") (EBinOp "++" (EApp (EApp (EVar "without") (EVar "bound")) (EVar "env")) (EApp (EApp (EApp (EVar "armBounds") (EVar "env")) (EVar "scrut")) (EVar "bound")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "scopes")) (EVar "owner")) (EVar "env2")) (EVar "loc")) (EVar "gs")) (EVar "body")))))
(DTypeSig false "walkGuarded" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "SelfCall")))))))))
(DFunDef false "walkGuarded" ((PVar "scopes") (PVar "owner") (PVar "env0") (PVar "loc") (PVar "gs0") (PVar "body")) (ELetGroup ((lgb "go" (clause ((PVar "env") (PList)) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "body"))) (clause ((PVar "env") (PCons (PCon "GBool" (PVar "e")) (PVar "gs"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EVar "env")) (EVar "gs")))) (clause ((PVar "env") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "gs"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "scopes")) (EVar "owner")) (EVar "env")) (EVar "loc")) (EVar "e")) (EApp (EApp (EVar "go") (EApp (EApp (EVar "without") (EApp (EVar "patBoundNames") (EVar "p"))) (EVar "env"))) (EVar "gs")))))) (EApp (EApp (EVar "go") (EVar "env0")) (EVar "gs0"))))
(DTypeSig false "armBounds" (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Bound"))))))
(DFunDef false "armBounds" ((PVar "env") (PVar "scrut") (PVar "bound")) (EMatch (EApp (EVar "unwrapLoc") (EVar "scrut")) (arm (PCon "EVar" (PVar "n")) () (EMatch (EApp (EApp (EVar "findMap") (ELam ((PVar "b")) (EApp (EApp (EVar "boundIndex") (EVar "n")) (EVar "b")))) (EVar "env")) (arm (PCon "Some" (PVar "j")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "Bound") (EVar "m")) (EVar "j")) (EVar "False")))) (EVar "bound"))) (arm (PCon "None") () (EListLit)))) (arm PWild () (EListLit))))
(DTypeSig false "boundIndex" (TyFun (TyCon "String") (TyFun (TyCon "Bound") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "boundIndex" ((PVar "n") (PCon "Bound" (PVar "m") (PVar "j") PWild)) (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EApp (EVar "Some") (EVar "j")) (EVar "None")))
(DTypeSig false "isSelfCall" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool"))))))
(DFunDef false "isSelfCall" ((PVar "scopes") (PAs "owner" (PCon "Owner" (PVar "name") (PVar "ps") PWild)) (PVar "hd") (PVar "args")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isNamed") (EVar "name")) (EVar "hd")) (EBinOp "==" (EApp (EMethodRef "length") (EVar "args")) (EApp (EMethodRef "length") (EVar "ps")))) (EApp (EApp (EApp (EVar "bindsOwner") (EVar "scopes")) (EVar "owner")) (EApp (EVar "varSite") (EVar "hd")))))
(DTypeSig false "isNamed" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isNamed" ((PVar "name") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm PWild () (EVar "False"))))
(DTypeSig false "bindsOwner" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Owner") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool")))))
(DFunDef false "bindsOwner" (PWild PWild (PCon "None")) (EVar "False"))
(DFunDef false "bindsOwner" ((PVar "scopes") (PCon "Owner" (PVar "name") PWild (PVar "kind")) (PCon "Some" (PVar "l"))) (EMatch (EApp (EApp (EVar "binderOf") (EVar "scopes")) (EVar "l")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "b")) () (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "name")) (EApp (EApp (EVar "bindsAs") (EVar "kind")) (EVar "b"))))))
(DTypeSig false "bindsAs" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Binder") (TyCon "Bool"))))
(DFunDef false "bindsAs" ((PCon "None") (PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BTopLevel")))
(DFunDef false "bindsAs" ((PCon "Some" (PVar "site")) (PVar "b")) (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BLetGroup")) (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BWhere"))) (EBinOp "==" (EFieldAccess (EVar "b") "binderSpan") (EVar "site"))))
(DTypeSig false "roles" (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "ArgRole"))))))
(DFunDef false "roles" (PWild PWild (PList)) (EListLit))
(DFunDef false "roles" ((PVar "env") (PVar "i") (PCons (PVar "a") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "argRole") (EVar "env")) (EVar "i")) (EVar "a")) (EApp (EApp (EApp (EVar "roles") (EVar "env")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "argRole" (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "ArgRole")))))
(DFunDef false "argRole" ((PVar "env") (PVar "i") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "n")) () (EApp (EApp (EVar "optionOr") (EVar "Fresh")) (EApp (EApp (EVar "findMap") (EApp (EVar "boundRole") (EVar "n"))) (EVar "env")))) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "a") (PVar "b") PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "appendRole") (EVar "env")) (EVar "i")) (EVar "a")) (EVar "b")) (EVar "e"))) (arm PWild () (EApp (EApp (EApp (EVar "derivedRole") (EVar "env")) (EVar "i")) (EVar "e")))))
(DTypeSig false "boundRole" (TyFun (TyCon "String") (TyFun (TyCon "Bound") (TyApp (TyCon "Option") (TyCon "ArgRole")))))
(DFunDef false "boundRole" ((PVar "n") (PCon "Bound" (PVar "m") (PVar "j") (PVar "whole"))) (EIf (EBinOp "/=" (EVar "n") (EVar "m")) (EVar "None") (EIf (EVar "whole") (EApp (EVar "Some") (EApp (EVar "Unchanged") (EVar "j"))) (EIf (EVar "otherwise") (EApp (EVar "Some") (EApp (EVar "Advanced") (EVar "j"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "appendRole" (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "ArgRole")))))))
(DFunDef false "appendRole" ((PVar "env") (PVar "i") (PVar "a") (PVar "b") (PVar "whole")) (EMatch (EApp (EApp (EApp (EVar "argRole") (EVar "env")) (EVar "i")) (EVar "a")) (arm (PCon "Unchanged" (PVar "j")) () (EApp (EVar "AppendedTo") (EVar "j"))) (arm (PCon "AppendedTo" (PVar "j")) () (EApp (EVar "AppendedTo") (EVar "j"))) (arm PWild () (EMatch (EApp (EApp (EApp (EVar "argRole") (EVar "env")) (EVar "i")) (EVar "b")) (arm (PCon "Unchanged" (PVar "j")) () (EApp (EVar "PrependedTo") (EVar "j"))) (arm PWild () (EApp (EApp (EApp (EVar "derivedRole") (EVar "env")) (EVar "i")) (EVar "whole")))))))
(DTypeSig false "derivedRole" (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "ArgRole")))))
(DFunDef false "derivedRole" ((PVar "env") (PVar "i") (PVar "e")) (EMatch (EApp (EApp (EVar "mentioned") (EVar "env")) (EVar "e")) (arm (PList) () (EVar "Fresh")) (arm (PAs "js" (PCons (PVar "j") PWild)) () (EApp (EVar "Advanced") (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "i")))) (EVar "js")) (EVar "i") (EVar "j"))))))
(DTypeSig false "mentioned" (TyFun (TyApp (TyCon "List") (TyCon "Bound")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "mentioned" ((PVar "env") (PVar "e")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "b")) (EApp (EApp (EVar "mentionedIn") (EVar "e")) (EVar "b")))) (EVar "env")))
(DTypeSig false "mentionedIn" (TyFun (TyCon "Expr") (TyFun (TyCon "Bound") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "mentionedIn" ((PVar "e") (PCon "Bound" (PVar "n") (PVar "j") PWild)) (EIf (EApp (EApp (EVar "mentionsVar") (EVar "n")) (EVar "e")) (EListLit (EVar "j")) (EListLit)))
(DTypeSig true "foldVerdict" (TyFun (TyCon "Expr") (TyCon "FoldVerdict")))
(DFunDef false "foldVerdict" ((PVar "e")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple PWild (PList)) () (EVar "NotAFold")) (arm (PTuple (PVar "hd") (PVar "args")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EVar" (PVar "n")) () (EMatch (EApp (EVar "foldAccIndex") (EApp (EVar "lastSegment") (EVar "n"))) (arm (PCon "None") () (EVar "NotAFold")) (arm (PCon "Some" (PVar "k")) () (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "a")) (EApp (EApp (EVar "lamAppends") (EVar "k")) (EVar "a")))) (EVar "args")) (EVar "FoldAppends") (EVar "FoldPlain"))))) (arm PWild () (EVar "NotAFold"))))))
(DTypeSig true "foldAccIndex" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "foldAccIndex" ((PLit (LString "fold"))) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldThen"))) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldlSet"))) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldlWithKey"))) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldWithIndex"))) (EApp (EVar "Some") (ELit (LInt 0))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldRight"))) (EApp (EVar "Some") (ELit (LInt 1))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldrSet"))) (EApp (EVar "Some") (ELit (LInt 1))))
(DFunDef false "foldAccIndex" ((PLit (LString "foldrWithKey"))) (EApp (EVar "Some") (ELit (LInt 2))))
(DFunDef false "foldAccIndex" (PWild) (EVar "None"))
(DTypeSig false "lamAppends" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "lamAppends" ((PVar "k") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELam" (PVar "ps") (PVar "body")) () (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "ps")) (arm (PCon "Some" (PCon "PVar" (PVar "acc") PWild PWild)) () (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "body"))) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "tailAppends" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "tailAppends" ((PVar "acc") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "a") PWild PWild) () (EApp (EApp (EVar "leftIsAcc") (EVar "acc")) (EVar "a"))) (arm (PCon "EIf" PWild (PVar "t") (PVar "el")) () (EBinOp "||" (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "t")) (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "el")))) (arm (PCon "EMatch" PWild (PVar "arms")) () (EApp (EApp (EDictApp "any") (EApp (EVar "armAppends") (EVar "acc"))) (EVar "arms"))) (arm (PCon "ELet" PWild PWild PWild PWild (PVar "body")) () (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "body"))) (arm (PCon "ELetGroup" PWild (PVar "body")) () (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "body"))) (arm (PCon "EBlock" (PVar "stmts")) () (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoExpr" (PVar "l"))) () (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "l"))) (arm PWild () (EVar "False")))) (arm (POr (PCon "ELit" PWild) (PCon "EVar" PWild) (PCon "EApp" PWild PWild) (PCon "ELam" PWild PWild) (PCon "EUnOp" PWild PWild PWild) (PCon "EInfix" PWild PWild PWild) (PCon "EFieldAccess" PWild PWild PWild) (PCon "ETuple" PWild) (PCon "EListLit" PWild) (PCon "EArrayLit" PWild) (PCon "ERangeList" PWild PWild PWild) (PCon "ERangeArray" PWild PWild PWild) (PCon "ESlice" PWild PWild PWild PWild) (PCon "ESection" PWild) (PCon "EIndex" PWild PWild) (PCon "EAnnot" PWild PWild) (PCon "EHeadAnnot" PWild PWild) (PCon "EDo" PWild PWild) (PCon "EStringInterp" PWild) (PCon "EGuards" PWild) (PCon "ERecordCreate" PWild PWild) (PCon "ERecordUpdate" PWild PWild PWild) (PCon "EVariantUpdate" PWild PWild PWild) (PCon "EMapLit" PWild PWild) (PCon "ESetLit" PWild PWild) (PCon "EAsPat" PWild PWild) (PCon "EOrPat" PWild) (PCon "EMethodRef" PWild) (PCon "EDictApp" PWild) (PCon "EVarAt" PWild PWild) (PCon "EVarId" PWild PWild) (PCon "EMethodAt" PWild PWild PWild) (PCon "EDictAt" PWild PWild) (PCon "ELoc" PWild PWild) (PCon "EDoOrigin" PWild PWild) (PCon "ENumLit" PWild PWild PWild) (PCon "EWideLit" PWild PWild PWild PWild) (PCon "EBinOp" PWild PWild PWild PWild)) () (EVar "False"))))
(DTypeSig false "leftIsAcc" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "leftIsAcc" ((PVar "acc") (PVar "a")) (EMatch (EApp (EVar "unwrapLoc") (EVar "a")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "acc"))) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "a2") PWild PWild) () (EApp (EApp (EVar "leftIsAcc") (EVar "acc")) (EVar "a2"))) (arm PWild () (EVar "False"))))
(DTypeSig false "armAppends" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armAppends" ((PVar "acc") (PCon "Arm" PWild PWild (PVar "body"))) (EApp (EApp (EVar "tailAppends") (EVar "acc")) (EVar "body")))
