# META
source_lines=422
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
import list.{last, sort}
import string.{endsWith, indexOf, repeat, startsWith, trim, trimLeft, trimRight}
import support.char.{isAlnum}
import support.util.{allList, anyList, initList, isEmptyL}
import tools.lint_core.{
  Applicability(..),
  Category(..),
  Ctx(..),
  FileFacts,
  Finding(..),
  Fix(..),
  FixEdit(..),
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
  indentWidth,
  isCodeText,
  isEVarNamed,
  isNilPCon,
  matchScrutOf,
  matchToMapTransform,
  ruleNamePassthroughArm,
  sourceLine,
  tightSpan,
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
        "A `match` that passes a failure straight through (`None => None`, or `Err e => Err e` with the same variable) and continues in the other arm is a monadic bind written by hand. Write it as a `do` block, at any depth: one level is enough, unlike `rule-bind-chain-to-do`, which needs a pyramid of three. `--fix --unsafe-fixes` rewrites the statement-position cases; the rest are reported only.\n\nNot reported: a failure arm that rebuilds its value (`Err e => Err (wrap e)`), a match with a third arm or a guard, a success arm that re-wraps in the same constructor (`rule-match-to-map` owns it). A match whose success arm ends, through `if`, `let`, `match` arms and block tails, in a call of the enclosing function (a self-recursive tail, including a where-local `go`) is not reported: the `do` form lowers to `andThen`, which allocates a closure per iteration and measurably slows the loop.\n\nBefore:\n  match catalogRow n\n    Some r => g r\n    None => None\nAfter:\n  do\n    r <- catalogRow n\n    g r",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = FixableUnsafe,
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
rulePassthroughArm _ _ facts _ prog =
  [OnExpr [KMatch] (passthroughAt facts (flatMap declExempt prog))]

-- ── the match ────────────────────────────────────────────────────────────────

-- `exempt` holds the span of each match whose success arm is a self-recursive
-- tail.
passthroughAt : FileFacts -> List (Option Loc) -> Ctx -> Expr -> List Finding
passthroughAt facts exempt ctx e = match passthroughOf e
  Some (kind, _) =>
    if anyList (== ctx.ctxSpan) exempt then
      []
    else
      [report ctx.ctxSpan kind (passthroughFix facts ctx e)]
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
  ELit _ | EVar _ | ELam _ _ | EBinOp _ _ _ _ | EUnOp _ _ _ | EInfix _ _ _ | EFieldAccess _ _ _ | ETuple _ | EListLit _ | EArrayLit _ | ERangeList _ _ _ | ERangeArray _ _ _ | ESlice _ _ _ _ | ESection _ | EIndex _ _ | EAnnot _ _ | EHeadAnnot _ _ | EDo _ _ | EStringInterp _ | EGuards _ | ERecordCreate _ _ | ERecordUpdate _ _ _ | EVariantUpdate _ _ _ | EMapLit _ _ | ESetLit _ _ | EAsPat _ _ | EOrPat _ | EMethodRef _ | EDictApp _ | EVarAt _ _ | EVarId _ _ | EMethodAt _ _ _ | EDictAt _ _ | ELoc _ _ | EDoOrigin _ _ | ENumLit _ _ _ | EWideLit _ _ _ _ =>
    False

armTail : String -> Arm -> Bool
armTail name (Arm _ _ body) = selfTail name body

calls : String -> Expr -> Bool
calls name f = match unwrapLoc f
  EVar n => n == name
  EApp g _ => calls name g
  _ => False

report : Option Loc -> String -> Option Fix -> Finding
report loc kind fix = Finding {
  rule = ruleNamePassthroughArm,
  message =
    "`match` over \{kind} passes the failure straight through: bind it in a `do` block (`pat <- scrutinee`, then the success arm)",
  severity = SevWarning,
  loc = loc,
  fix = fix,
}

-- ── the fix ──────────────────────────────────────────────────────────────────

-- Unsafe: `--fix --unsafe-fixes` rewrites
--
--   match e                  do
--     Some p => body    ==>    p <- e
--     None => None             body
--
-- as text edits, so the success arm's body keeps its lines and comments. The
-- fix is withheld, the finding still reported, unless the whole shape is known:
--   * the match is a clause body, a `let` value or an arm body (never a bare
--     operand, argument, `if` branch or parenthesised), and starts a line or
--     follows an `=` / `=>` that ends the previous significant line;
--   * the scrutinee ends on the `match` line, the arms sit at one column below
--     it, and the passthrough arm is exactly one line `None => None` /
--     `Err x => Err x`;
--   * the success pattern is a variable, `_`, or a tuple of them, which a `do`
--     bind accepts without a failure path;
--   * the success body has no bare expression statement before its last one,
--     which would be a statement in the scrutinee's monad inside the `do`;
--   * no comment touches an edited line (the driver demotes such a fix).
-- The passthrough arm is listed first or second. A success body that starts on
-- the arrow's line moves to the arm's column, and the bind is placed there; a
-- body that starts on the next line stays where it is and the bind is placed at
-- its column. Both match and `do` blocks are layout blocks, so no line is
-- re-indented.
passthroughFix : FileFacts -> Ctx -> Expr -> Option Fix
passthroughFix facts ctx e = do
  (Loc path sl sc el ec) <- ctx.ctxSpan
  (first, pass, succArm) <- passthroughArms e
  guard (ctx.ctxOwn == ctx.ctxSpan && statementParent ctx.ctxParent)
  scrutEnd <- tightSpan (matchScrutOf e)
  guard (spanEndLine scrutEnd == sl && matchTokenAt facts sl sc)
  guard (positionOk facts ctx sl sc (if ec == 0 then el - 1 else el))
  firstArm <- nextCode facts sl
  let ac = indentWidth (lineAt facts firstArm)
  guard (ac > indentWidth (lineAt facts sl))
  passLine <- passthroughLine first pass firstArm
  succLine <- if first then nextCode facts passLine else Some firstArm
  guard (first || succLine < passLine)
  guard (indentWidth (lineAt facts passLine) == ac)
  guard (isPassthroughText (lineAt facts passLine))
  guard (indentWidth (lineAt facts succLine) == ac)
  (ctorName, inner) <- successParts succArm
  guard (not (hasBareStatement succArm))
  let sline = lineAt facts succLine
  arrow <- indexOf "=>" sline
  guard
    (stringSlice ac (ac + stringLength ctorName + 1) sline == ctorName ++ " ")
  let patText = trim (stringSlice (ac + stringLength ctorName) arrow sline)
  guard (patTextOk inner patText)
  (blockCol, deleted, extra) <- bodyPlan facts path ac succLine passLine arrow
  let header =
    FixEdit
      (Loc path sl sc sl (sc + 5))
      "do\n\{repeat blockCol " "}\{patText} <-"
  Some Fix {
    fixApplicability = Unsafe,
    fixEdits =
      header :: extra ++ map (deleteLines facts path) (runs (sort deleted)),
    fixMessage = "bind the scrutinee in a `do` block",
  }

-- Where the bind goes, the lines to delete, and the edit that lifts a body
-- starting on the arrow's line to the arm's column.
bodyPlan : FileFacts ->
  String ->
  Int ->
  Int ->
  Int ->
  Int ->
  Option (Int, List Int, List FixEdit)
bodyPlan facts path ac succLine passLine arrow = do
  let sline = lineAt facts succLine
  let rest = stringSlice (arrow + 2) (stringLength sline) sline
  if trim rest == "" then do
    bodyLine <- nextCode facts succLine
    let bi = indentWidth (lineAt facts bodyLine)
    guard (bi > ac)
    Some (bi, [passLine, succLine], [])
  else do
    guard (not (startsWith "--" (trim rest)))
    let bodyCol = arrow + 2 + stringLength rest - stringLength (trimLeft rest)
    Some (ac, [passLine], [FixEdit (Loc path succLine ac succLine bodyCol) ""])

-- `(passthrough listed first, passthrough arm, success arm)`.
passthroughArms : Expr -> Option (Bool, Arm, Arm)
passthroughArms (EMatch _ [a1, a2]) =
  if isSome (bindArm a1 a2) then
    Some (True, a1, a2)
  else if isSome (bindArm a2 a1) then
    Some (False, a2, a1)
  else
    None
passthroughArms _ = None

-- The success body is a block with a bare expression statement before its last
-- statement, as in `log x` then the result.
hasBareStatement : Arm -> Bool
hasBareStatement (Arm _ _ body) = match unwrapLoc body
  EBlock stmts => anyList isBare (initList stmts)
  _ => False

isBare : DoStmt -> Bool
isBare (DoExpr _) = True
isBare _ = False

-- The success arm's constructor and the pattern it wraps.
successParts : Arm -> Option (String, Pat)
successParts (Arm (PCon c [p]) _ _) = Some (c, p)
successParts _ = None

-- The line of the passthrough arm: the first arm, else the line its body is on.
passthroughLine : Bool -> Arm -> Int -> Option Int
passthroughLine True _ firstArm = Some firstArm
passthroughLine False (Arm _ _ body) _ = map spanStartLine (tightSpan body)

spanStartLine : Loc -> Int
spanStartLine (Loc _ l _ _ _) = l

spanEndLine : Loc -> Int
spanEndLine (Loc _ _ _ l _) = l

-- Where a multi-line `do` can replace the match without regrouping its parent.
statementParent : Option ExprKind -> Bool
statementParent None = True
statementParent (Some KMatch) = True
statementParent (Some KLet) = True
statementParent (Some KLetGroup) = True
statementParent (Some KGuards) = True
statementParent (Some KDo) = True
statementParent (Some KBlock) = True
statementParent (Some _) = False

matchTokenAt : FileFacts -> Int -> Int -> Bool
matchTokenAt facts l c = stringSlice c (c + 5) (lineAt facts l) == "match"

-- The match follows an `=` or `=>`, or is the last statement of a block, which
-- a `do` takes the place of.
positionOk : FileFacts -> Ctx -> Int -> Int -> Int -> Bool
positionOk facts ctx l c endLine =
  assignmentBefore facts l c || lastStatement facts ctx l c endLine

lastStatement : FileFacts -> Ctx -> Int -> Int -> Int -> Bool
lastStatement facts ctx l c endLine =
  (ctx.ctxParent == Some KDo || ctx.ctxParent == Some KBlock)
    && trim (stringSlice 0 c (lineAt facts l)) == ""
    && (match prevCode facts l
      Some p => indentWidth (lineAt facts p) == indentWidth (lineAt facts l)
      None => False)
    && (match nextCode facts endLine
      Some n => indentWidth (lineAt facts n) < indentWidth (lineAt facts l)
      None => True)

-- The match follows an `=` or `=>` on its line, or starts its line right after
-- a significant line that ends with one.
assignmentBefore : FileFacts -> Int -> Int -> Bool
assignmentBefore facts l c =
  let before = stringSlice 0 c (lineAt facts l)
  if trim before == "" then match prevCode facts l
    Some p => endsAssign (lineAt facts p)
    None => False
  else
    endsAssign before

endsAssign : String -> Bool
endsAssign s =
  let t = trimRight s
  endsWith "=>" t
    || endsWith "=" t
      && not (anyList (c => endsWith (c ++ "=") t) ["=", "<", ">", "!", "/"])

lineAt : FileFacts -> Int -> String
lineAt facts n = optionOr "" (sourceLine facts n)

nextCode : FileFacts -> Int -> Option Int
nextCode facts n = match sourceLine facts (n + 1)
  Some l => if isCodeText l then Some (n + 1) else nextCode facts (n + 1)
  None => None

prevCode : FileFacts -> Int -> Option Int
prevCode facts n
  | n <= 1 = None
  | isCodeText (lineAt facts (n - 1)) = Some (n - 1)
  | otherwise = prevCode facts (n - 1)

-- `None => None`, `Err e => Err e` on one line.
isPassthroughText : String -> Bool
isPassthroughText l = match indexOf "=>" l
  Some i =>
    let lhs = trim (stringSlice 0 i l)
    let rhs = trim (stringSlice (i + 2) (stringLength l) l)
    lhs == rhs && (lhs == "None" || startsWith "Err " lhs)
  None => False

-- A variable, `_` or a tuple of them, written with nothing else.
patTextOk : Pat -> String -> Bool
patTextOk p t =
  patShapeOk p
    && allList
      (c => isAlnum c || elem c [',', ' ', '(', ')'])
      (toList (stringToChars t))

patShapeOk : Pat -> Bool
patShapeOk (PVar _ _ _) = True
patShapeOk PWild = True
patShapeOk (PTuple ps) = allList patShapeOk ps
patShapeOk (PLit _ | PCon _ _ | PCons _ _ | PList _ | PAs _ _ _ _ | POr _ | PRng _ _ _ | PRec _ _ _ | PAnn _ _) =
  False

-- Consecutive line numbers as `(first, last)` runs.
runs : List Int -> List (Int, Int)
runs [] = []
runs (x :: xs) = runFrom x x xs

runFrom : Int -> Int -> List Int -> List (Int, Int)
runFrom lo hi (y :: ys)
  | y == hi + 1 = runFrom lo y ys
runFrom lo hi rest = (lo, hi) :: runs rest

-- Deletes lines `lo..hi` with the newline that precedes them.
deleteLines : FileFacts -> String -> (Int, Int) -> FixEdit
deleteLines facts path (lo, hi) =
  FixEdit
    (Loc
      path
      (lo - 1)
      (stringLength (lineAt facts (lo - 1)))
      hi
      (stringLength (lineAt facts hi)))
    ""
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" false) (mem "DoStmt" true) (mem "Expr" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Loc" false) (mem "Pat" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "ExprKind" true) (mem "childExprs" false) (mem "declBodies" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "last" false) (mem "sort" false))))
(DUse false (UseGroup ("string") ((mem "endsWith" false) (mem "indexOf" false) (mem "repeat" false) (mem "startsWith" false) (mem "trim" false) (mem "trimLeft" false) (mem "trimRight" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "initList" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ctorVarPassthru" false) (mem "indentWidth" false) (mem "isCodeText" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchScrutOf" false) (mem "matchToMapTransform" false) (mem "ruleNamePassthroughArm" false) (mem "sourceLine" false) (mem "tightSpan" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePassthroughArm")) (fa "summary" (ELit (LString "a two-arm `match` over an Option/Result with a verbatim `None => None` / `Err e => Err e` arm: bind in a `do` block instead"))) (fa "doc" (ELit (LString "A `match` that passes a failure straight through (`None => None`, or `Err e => Err e` with the same variable) and continues in the other arm is a monadic bind written by hand. Write it as a `do` block, at any depth: one level is enough, unlike `rule-bind-chain-to-do`, which needs a pyramid of three. `--fix --unsafe-fixes` rewrites the statement-position cases; the rest are reported only.\n\nNot reported: a failure arm that rebuilds its value (`Err e => Err (wrap e)`), a match with a third arm or a guard, a success arm that re-wraps in the same constructor (`rule-match-to-map` owns it). A match whose success arm ends, through `if`, `let`, `match` arms and block tails, in a call of the enclosing function (a self-recursive tail, including a where-local `go`) is not reported: the `do` form lowers to `andThen`, which allocates a closure per iteration and measurably slows the loop.\n\nBefore:\n  match catalogRow n\n    Some r => g r\n    None => None\nAfter:\n  do\n    r <- catalogRow n\n    g r"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "FixableUnsafe")) (fa "needs" (EListLit))))) (EVar "rulePassthroughArm")) (EVar "None")))
(DTypeSig false "rulePassthroughArm" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "rulePassthroughArm" (PWild PWild (PVar "facts") PWild (PVar "prog")) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KMatch"))) (EApp (EApp (EVar "passthroughAt") (EVar "facts")) (EApp (EApp (EVar "flatMap") (EVar "declExempt")) (EVar "prog"))))))
(DTypeSig false "passthroughAt" (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "passthroughAt" ((PVar "facts") (PVar "exempt") (PVar "ctx") (PVar "e")) (EMatch (EApp (EVar "passthroughOf") (EVar "e")) (arm (PCon "Some" (PTuple (PVar "kind") PWild)) () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EFieldAccess (EVar "ctx") "ctxSpan")))) (EVar "exempt")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "report") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "kind")) (EApp (EApp (EApp (EVar "passthroughFix") (EVar "facts")) (EVar "ctx")) (EVar "e")))))) (arm (PCon "None") () (EListLit))))
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
(DFunDef false "selfTail" ((PVar "name") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EApp (EVar "calls") (EVar "name")) (EVar "f"))) (arm (PCon "EIf" PWild (PVar "t") (PVar "el")) () (EBinOp "||" (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "t")) (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "el")))) (arm (PCon "ELet" PWild PWild PWild PWild (PVar "body")) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "body"))) (arm (PCon "ELetGroup" PWild (PVar "body")) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "body"))) (arm (PCon "EMatch" PWild (PVar "arms")) () (EApp (EApp (EVar "anyList") (EApp (EVar "armTail") (EVar "name"))) (EVar "arms"))) (arm (PCon "EBlock" (PVar "stmts")) () (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoExpr" (PVar "l"))) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "l"))) (arm PWild () (EVar "False")))) (arm (POr (PCon "ELit" PWild) (PCon "EVar" PWild) (PCon "ELam" PWild PWild) (PCon "EBinOp" PWild PWild PWild PWild) (PCon "EUnOp" PWild PWild PWild) (PCon "EInfix" PWild PWild PWild) (PCon "EFieldAccess" PWild PWild PWild) (PCon "ETuple" PWild) (PCon "EListLit" PWild) (PCon "EArrayLit" PWild) (PCon "ERangeList" PWild PWild PWild) (PCon "ERangeArray" PWild PWild PWild) (PCon "ESlice" PWild PWild PWild PWild) (PCon "ESection" PWild) (PCon "EIndex" PWild PWild) (PCon "EAnnot" PWild PWild) (PCon "EHeadAnnot" PWild PWild) (PCon "EDo" PWild PWild) (PCon "EStringInterp" PWild) (PCon "EGuards" PWild) (PCon "ERecordCreate" PWild PWild) (PCon "ERecordUpdate" PWild PWild PWild) (PCon "EVariantUpdate" PWild PWild PWild) (PCon "EMapLit" PWild PWild) (PCon "ESetLit" PWild PWild) (PCon "EAsPat" PWild PWild) (PCon "EOrPat" PWild) (PCon "EMethodRef" PWild) (PCon "EDictApp" PWild) (PCon "EVarAt" PWild PWild) (PCon "EVarId" PWild PWild) (PCon "EMethodAt" PWild PWild PWild) (PCon "EDictAt" PWild PWild) (PCon "ELoc" PWild PWild) (PCon "EDoOrigin" PWild PWild) (PCon "ENumLit" PWild PWild PWild) (PCon "EWideLit" PWild PWild PWild PWild)) () (EVar "False"))))
(DTypeSig false "armTail" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armTail" ((PVar "name") (PCon "Arm" PWild PWild (PVar "body"))) (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "body")))
(DTypeSig false "calls" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "calls" ((PVar "name") (PVar "f")) (EMatch (EApp (EVar "unwrapLoc") (EVar "f")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "EApp" (PVar "g") PWild) () (EApp (EApp (EVar "calls") (EVar "name")) (EVar "g"))) (arm PWild () (EVar "False"))))
(DTypeSig false "report" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "report" ((PVar "loc") (PVar "kind") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePassthroughArm")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`match` over ")) (EApp (EVar "display") (EVar "kind"))) (ELit (LString " passes the failure straight through: bind it in a `do` block (`pat <- scrutinee`, then the success arm)")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "passthroughFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))
(DFunDef false "passthroughFix" ((PVar "facts") (PVar "ctx") (PVar "e")) (EApp (EApp (EVar "andThen") (EFieldAccess (EVar "ctx") "ctxSpan")) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "Loc" (PVar "path") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) () (EApp (EApp (EVar "andThen") (EApp (EVar "passthroughArms") (EVar "e"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "first") (PVar "pass") (PVar "succArm")) () (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "ctx") "ctxOwn") (EFieldAccess (EVar "ctx") "ctxSpan")) (EApp (EVar "statementParent") (EFieldAccess (EVar "ctx") "ctxParent"))))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "tightSpan") (EApp (EVar "matchScrutOf") (EVar "e")))) (ELam ((PVar "scrutEnd")) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EBinOp "&&" (EBinOp "==" (EApp (EVar "spanEndLine") (EVar "scrutEnd")) (EVar "sl")) (EApp (EApp (EApp (EVar "matchTokenAt") (EVar "facts")) (EVar "sl")) (EVar "sc"))))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EApp (EApp (EApp (EApp (EApp (EVar "positionOk") (EVar "facts")) (EVar "ctx")) (EVar "sl")) (EVar "sc")) (EIf (EBinOp "==" (EVar "ec") (ELit (LInt 0))) (EBinOp "-" (EVar "el") (ELit (LInt 1))) (EVar "el"))))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "nextCode") (EVar "facts")) (EVar "sl"))) (ELam ((PVar "firstArm")) (ELet false (PVar "ac") (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "firstArm"))) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EBinOp ">" (EVar "ac") (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "sl")))))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "passthroughLine") (EVar "first")) (EVar "pass")) (EVar "firstArm"))) (ELam ((PVar "passLine")) (EApp (EApp (EVar "andThen") (EIf (EVar "first") (EApp (EApp (EVar "nextCode") (EVar "facts")) (EVar "passLine")) (EApp (EVar "Some") (EVar "firstArm")))) (ELam ((PVar "succLine")) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EBinOp "||" (EVar "first") (EBinOp "<" (EVar "succLine") (EVar "passLine"))))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EBinOp "==" (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "passLine"))) (EVar "ac")))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EApp (EVar "isPassthroughText") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "passLine"))))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EBinOp "==" (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "succLine"))) (EVar "ac")))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "successParts") (EVar "succArm"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "ctorName") (PVar "inner")) () (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EApp (EVar "not") (EApp (EVar "hasBareStatement") (EVar "succArm"))))) (ELam (PWild) (ELet false (PVar "sline") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "succLine")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "indexOf") (ELit (LString "=>"))) (EVar "sline"))) (ELam ((PVar "arrow")) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "ac")) (EBinOp "+" (EBinOp "+" (EVar "ac") (EApp (EVar "stringLength") (EVar "ctorName"))) (ELit (LInt 1)))) (EVar "sline")) (EBinOp "++" (EVar "ctorName") (ELit (LString " ")))))) (ELam (PWild) (ELet false (PVar "patText") (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "ac") (EApp (EVar "stringLength") (EVar "ctorName")))) (EVar "arrow")) (EVar "sline"))) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EApp (EApp (EVar "patTextOk") (EVar "inner")) (EVar "patText")))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "bodyPlan") (EVar "facts")) (EVar "path")) (EVar "ac")) (EVar "succLine")) (EVar "passLine")) (EVar "arrow"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "blockCol") (PVar "deleted") (PVar "extra")) () (ELet false (PVar "header") (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (ELit (LInt 5))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "do\n")) (EApp (EVar "display") (EApp (EApp (EVar "repeat") (EVar "blockCol")) (ELit (LString " "))))) (ELit (LString ""))) (EApp (EVar "display") (EVar "patText"))) (ELit (LString " <-")))) (EApp (EVar "Some") (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "Unsafe")) (fa "fixEdits" (EBinOp "::" (EVar "header") (EBinOp "++" (EVar "extra") (EApp (EApp (EVar "map") (EApp (EApp (EVar "deleteLines") (EVar "facts")) (EVar "path"))) (EApp (EVar "runs") (EApp (EVar "sort") (EVar "deleted"))))))) (fa "fixMessage" (ELit (LString "bind the scrutinee in a `do` block")))))))))))))))))))))))))))))))))))))))))))))))))))))))))))
(DTypeSig false "bodyPlan" (TyFun (TyCon "FileFacts") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "FixEdit")))))))))))
(DFunDef false "bodyPlan" ((PVar "facts") (PVar "path") (PVar "ac") (PVar "succLine") (PVar "passLine") (PVar "arrow")) (ELet false (PVar "sline") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "succLine")) (ELet false (PVar "rest") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "arrow") (ELit (LInt 2)))) (EApp (EVar "stringLength") (EVar "sline"))) (EVar "sline")) (EIf (EBinOp "==" (EApp (EVar "trim") (EVar "rest")) (ELit (LString ""))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "nextCode") (EVar "facts")) (EVar "succLine"))) (ELam ((PVar "bodyLine")) (ELet false (PVar "bi") (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "bodyLine"))) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EBinOp ">" (EVar "bi") (EVar "ac")))) (ELam (PWild) (EApp (EVar "Some") (ETuple (EVar "bi") (EListLit (EVar "passLine") (EVar "succLine")) (EListLit)))))))) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EApp (EVar "trim") (EVar "rest")))))) (ELam (PWild) (ELet false (PVar "bodyCol") (EBinOp "-" (EBinOp "+" (EBinOp "+" (EVar "arrow") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "rest"))) (EApp (EVar "stringLength") (EApp (EVar "trimLeft") (EVar "rest")))) (EApp (EVar "Some") (ETuple (EVar "ac") (EListLit (EVar "passLine")) (EListLit (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "succLine")) (EVar "ac")) (EVar "succLine")) (EVar "bodyCol"))) (ELit (LString "")))))))))))))
(DTypeSig false "passthroughArms" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "Bool") (TyCon "Arm") (TyCon "Arm")))))
(DFunDef false "passthroughArms" ((PCon "EMatch" PWild (PList (PVar "a1") (PVar "a2")))) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "bindArm") (EVar "a1")) (EVar "a2"))) (EApp (EVar "Some") (ETuple (EVar "True") (EVar "a1") (EVar "a2"))) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "bindArm") (EVar "a2")) (EVar "a1"))) (EApp (EVar "Some") (ETuple (EVar "False") (EVar "a2") (EVar "a1"))) (EVar "None"))))
(DFunDef false "passthroughArms" (PWild) (EVar "None"))
(DTypeSig false "hasBareStatement" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "hasBareStatement" ((PCon "Arm" PWild PWild (PVar "body"))) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EBlock" (PVar "stmts")) () (EApp (EApp (EVar "anyList") (EVar "isBare")) (EApp (EVar "initList") (EVar "stmts")))) (arm PWild () (EVar "False"))))
(DTypeSig false "isBare" (TyFun (TyCon "DoStmt") (TyCon "Bool")))
(DFunDef false "isBare" ((PCon "DoExpr" PWild)) (EVar "True"))
(DFunDef false "isBare" (PWild) (EVar "False"))
(DTypeSig false "successParts" (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Pat")))))
(DFunDef false "successParts" ((PCon "Arm" (PCon "PCon" (PVar "c") (PList (PVar "p"))) PWild PWild)) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "p"))))
(DFunDef false "successParts" (PWild) (EVar "None"))
(DTypeSig false "passthroughLine" (TyFun (TyCon "Bool") (TyFun (TyCon "Arm") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "passthroughLine" ((PCon "True") PWild (PVar "firstArm")) (EApp (EVar "Some") (EVar "firstArm")))
(DFunDef false "passthroughLine" ((PCon "False") (PCon "Arm" PWild PWild (PVar "body")) PWild) (EApp (EApp (EVar "map") (EVar "spanStartLine")) (EApp (EVar "tightSpan") (EVar "body"))))
(DTypeSig false "spanStartLine" (TyFun (TyCon "Loc") (TyCon "Int")))
(DFunDef false "spanStartLine" ((PCon "Loc" PWild (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeSig false "spanEndLine" (TyFun (TyCon "Loc") (TyCon "Int")))
(DFunDef false "spanEndLine" ((PCon "Loc" PWild PWild PWild (PVar "l") PWild)) (EVar "l"))
(DTypeSig false "statementParent" (TyFun (TyApp (TyCon "Option") (TyCon "ExprKind")) (TyCon "Bool")))
(DFunDef false "statementParent" ((PCon "None")) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" (PCon "KMatch"))) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" (PCon "KLet"))) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" (PCon "KLetGroup"))) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" (PCon "KGuards"))) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" (PCon "KDo"))) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" (PCon "KBlock"))) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" PWild)) (EVar "False"))
(DTypeSig false "matchTokenAt" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "matchTokenAt" ((PVar "facts") (PVar "l") (PVar "c")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "c")) (EBinOp "+" (EVar "c") (ELit (LInt 5)))) (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "l"))) (ELit (LString "match"))))
(DTypeSig false "positionOk" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "positionOk" ((PVar "facts") (PVar "ctx") (PVar "l") (PVar "c") (PVar "endLine")) (EBinOp "||" (EApp (EApp (EApp (EVar "assignmentBefore") (EVar "facts")) (EVar "l")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "lastStatement") (EVar "facts")) (EVar "ctx")) (EVar "l")) (EVar "c")) (EVar "endLine"))))
(DTypeSig false "lastStatement" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "lastStatement" ((PVar "facts") (PVar "ctx") (PVar "l") (PVar "c") (PVar "endLine")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "ctx") "ctxParent") (EApp (EVar "Some") (EVar "KDo"))) (EBinOp "==" (EFieldAccess (EVar "ctx") "ctxParent") (EApp (EVar "Some") (EVar "KBlock")))) (EBinOp "==" (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "c")) (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "l")))) (ELit (LString "")))) (EMatch (EApp (EApp (EVar "prevCode") (EVar "facts")) (EVar "l")) (arm (PCon "Some" (PVar "p")) () (EBinOp "==" (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "p"))) (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "l"))))) (arm (PCon "None") () (EVar "False")))) (EMatch (EApp (EApp (EVar "nextCode") (EVar "facts")) (EVar "endLine")) (arm (PCon "Some" (PVar "n")) () (EBinOp "<" (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "n"))) (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "l"))))) (arm (PCon "None") () (EVar "True")))))
(DTypeSig false "assignmentBefore" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "assignmentBefore" ((PVar "facts") (PVar "l") (PVar "c")) (EBlock (DoLet false false (PVar "before") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "c")) (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "l")))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "trim") (EVar "before")) (ELit (LString ""))) (EMatch (EApp (EApp (EVar "prevCode") (EVar "facts")) (EVar "l")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "endsAssign") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "p")))) (arm (PCon "None") () (EVar "False"))) (EApp (EVar "endsAssign") (EVar "before"))))))
(DTypeSig false "endsAssign" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "endsAssign" ((PVar "s")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "trimRight") (EVar "s"))) (DoExpr (EBinOp "||" (EApp (EApp (EVar "endsWith") (ELit (LString "=>"))) (EVar "t")) (EBinOp "&&" (EApp (EApp (EVar "endsWith") (ELit (LString "="))) (EVar "t")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "c")) (EApp (EApp (EVar "endsWith") (EBinOp "++" (EVar "c") (ELit (LString "=")))) (EVar "t")))) (EListLit (ELit (LString "=")) (ELit (LString "<")) (ELit (LString ">")) (ELit (LString "!")) (ELit (LString "/"))))))))))
(DTypeSig false "lineAt" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "lineAt" ((PVar "facts") (PVar "n")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "sourceLine") (EVar "facts")) (EVar "n"))))
(DTypeSig false "nextCode" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "nextCode" ((PVar "facts") (PVar "n")) (EMatch (EApp (EApp (EVar "sourceLine") (EVar "facts")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (arm (PCon "Some" (PVar "l")) () (EIf (EApp (EVar "isCodeText") (EVar "l")) (EApp (EVar "Some") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EApp (EApp (EVar "nextCode") (EVar "facts")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "prevCode" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "prevCode" ((PVar "facts") (PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 1))) (EVar "None") (EIf (EApp (EVar "isCodeText") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EVar "prevCode") (EVar "facts")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isPassthroughText" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isPassthroughText" ((PVar "l")) (EMatch (EApp (EApp (EVar "indexOf") (ELit (LString "=>"))) (EVar "l")) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "lhs") (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "l")))) (DoLet false false (PVar "rhs") (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EApp (EVar "stringLength") (EVar "l"))) (EVar "l")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EVar "lhs") (EVar "rhs")) (EBinOp "||" (EBinOp "==" (EVar "lhs") (ELit (LString "None"))) (EApp (EApp (EVar "startsWith") (ELit (LString "Err "))) (EVar "lhs"))))))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "patTextOk" (TyFun (TyCon "Pat") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "patTextOk" ((PVar "p") (PVar "t")) (EBinOp "&&" (EApp (EVar "patShapeOk") (EVar "p")) (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EBinOp "||" (EApp (EVar "isAlnum") (EVar "c")) (EApp (EApp (EVar "elem") (EVar "c")) (EListLit (ELit (LChar ",")) (ELit (LChar " ")) (ELit (LChar "(")) (ELit (LChar ")"))))))) (EApp (EVar "toList") (EApp (EVar "stringToChars") (EVar "t"))))))
(DTypeSig false "patShapeOk" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patShapeOk" ((PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patShapeOk" ((PCon "PWild")) (EVar "True"))
(DFunDef false "patShapeOk" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EVar "patShapeOk")) (EVar "ps")))
(DFunDef false "patShapeOk" ((POr (PCon "PLit" PWild) (PCon "PCon" PWild PWild) (PCon "PCons" PWild PWild) (PCon "PList" PWild) (PCon "PAs" PWild PWild PWild PWild) (PCon "POr" PWild) (PCon "PRng" PWild PWild PWild) (PCon "PRec" PWild PWild PWild) (PCon "PAnn" PWild PWild))) (EVar "False"))
(DTypeSig false "runs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "runs" ((PList)) (EListLit))
(DFunDef false "runs" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EVar "runFrom") (EVar "x")) (EVar "x")) (EVar "xs")))
(DTypeSig false "runFrom" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "runFrom" ((PVar "lo") (PVar "hi") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "y") (EBinOp "+" (EVar "hi") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "runFrom") (EVar "lo")) (EVar "y")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "runFrom" ((PVar "lo") (PVar "hi") (PVar "rest")) (EBinOp "::" (ETuple (EVar "lo") (EVar "hi")) (EApp (EVar "runs") (EVar "rest"))))
(DTypeSig false "deleteLines" (TyFun (TyCon "FileFacts") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "FixEdit")))))
(DFunDef false "deleteLines" ((PVar "facts") (PVar "path") (PTuple (PVar "lo") (PVar "hi"))) (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EBinOp "-" (EVar "lo") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EBinOp "-" (EVar "lo") (ELit (LInt 1)))))) (EVar "hi")) (EApp (EVar "stringLength") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "hi"))))) (ELit (LString ""))))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" false) (mem "DoStmt" true) (mem "Expr" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Loc" false) (mem "Pat" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "ExprKind" true) (mem "childExprs" false) (mem "declBodies" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("list") ((mem "last" false) (mem "sort" false))))
(DUse false (UseGroup ("string") ((mem "endsWith" false) (mem "indexOf" false) (mem "repeat" false) (mem "startsWith" false) (mem "trim" false) (mem "trimLeft" false) (mem "trimRight" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "initList" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ctorVarPassthru" false) (mem "indentWidth" false) (mem "isCodeText" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchScrutOf" false) (mem "matchToMapTransform" false) (mem "ruleNamePassthroughArm" false) (mem "sourceLine" false) (mem "tightSpan" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePassthroughArm")) (fa "summary" (ELit (LString "a two-arm `match` over an Option/Result with a verbatim `None => None` / `Err e => Err e` arm: bind in a `do` block instead"))) (fa "doc" (ELit (LString "A `match` that passes a failure straight through (`None => None`, or `Err e => Err e` with the same variable) and continues in the other arm is a monadic bind written by hand. Write it as a `do` block, at any depth: one level is enough, unlike `rule-bind-chain-to-do`, which needs a pyramid of three. `--fix --unsafe-fixes` rewrites the statement-position cases; the rest are reported only.\n\nNot reported: a failure arm that rebuilds its value (`Err e => Err (wrap e)`), a match with a third arm or a guard, a success arm that re-wraps in the same constructor (`rule-match-to-map` owns it). A match whose success arm ends, through `if`, `let`, `match` arms and block tails, in a call of the enclosing function (a self-recursive tail, including a where-local `go`) is not reported: the `do` form lowers to `andThen`, which allocates a closure per iteration and measurably slows the loop.\n\nBefore:\n  match catalogRow n\n    Some r => g r\n    None => None\nAfter:\n  do\n    r <- catalogRow n\n    g r"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "FixableUnsafe")) (fa "needs" (EListLit))))) (EVar "rulePassthroughArm")) (EVar "None")))
(DTypeSig false "rulePassthroughArm" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "rulePassthroughArm" (PWild PWild (PVar "facts") PWild (PVar "prog")) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KMatch"))) (EApp (EApp (EVar "passthroughAt") (EVar "facts")) (EApp (EApp (EDictApp "flatMap") (EVar "declExempt")) (EVar "prog"))))))
(DTypeSig false "passthroughAt" (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "passthroughAt" ((PVar "facts") (PVar "exempt") (PVar "ctx") (PVar "e")) (EMatch (EApp (EVar "passthroughOf") (EVar "e")) (arm (PCon "Some" (PTuple (PVar "kind") PWild)) () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EFieldAccess (EVar "ctx") "ctxSpan")))) (EVar "exempt")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "report") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "kind")) (EApp (EApp (EApp (EVar "passthroughFix") (EVar "facts")) (EVar "ctx")) (EVar "e")))))) (arm (PCon "None") () (EListLit))))
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
(DFunDef false "selfTail" ((PVar "name") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EApp (EVar "calls") (EVar "name")) (EVar "f"))) (arm (PCon "EIf" PWild (PVar "t") (PVar "el")) () (EBinOp "||" (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "t")) (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "el")))) (arm (PCon "ELet" PWild PWild PWild PWild (PVar "body")) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "body"))) (arm (PCon "ELetGroup" PWild (PVar "body")) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "body"))) (arm (PCon "EMatch" PWild (PVar "arms")) () (EApp (EApp (EVar "anyList") (EApp (EVar "armTail") (EVar "name"))) (EVar "arms"))) (arm (PCon "EBlock" (PVar "stmts")) () (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoExpr" (PVar "l"))) () (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "l"))) (arm PWild () (EVar "False")))) (arm (POr (PCon "ELit" PWild) (PCon "EVar" PWild) (PCon "ELam" PWild PWild) (PCon "EBinOp" PWild PWild PWild PWild) (PCon "EUnOp" PWild PWild PWild) (PCon "EInfix" PWild PWild PWild) (PCon "EFieldAccess" PWild PWild PWild) (PCon "ETuple" PWild) (PCon "EListLit" PWild) (PCon "EArrayLit" PWild) (PCon "ERangeList" PWild PWild PWild) (PCon "ERangeArray" PWild PWild PWild) (PCon "ESlice" PWild PWild PWild PWild) (PCon "ESection" PWild) (PCon "EIndex" PWild PWild) (PCon "EAnnot" PWild PWild) (PCon "EHeadAnnot" PWild PWild) (PCon "EDo" PWild PWild) (PCon "EStringInterp" PWild) (PCon "EGuards" PWild) (PCon "ERecordCreate" PWild PWild) (PCon "ERecordUpdate" PWild PWild PWild) (PCon "EVariantUpdate" PWild PWild PWild) (PCon "EMapLit" PWild PWild) (PCon "ESetLit" PWild PWild) (PCon "EAsPat" PWild PWild) (PCon "EOrPat" PWild) (PCon "EMethodRef" PWild) (PCon "EDictApp" PWild) (PCon "EVarAt" PWild PWild) (PCon "EVarId" PWild PWild) (PCon "EMethodAt" PWild PWild PWild) (PCon "EDictAt" PWild PWild) (PCon "ELoc" PWild PWild) (PCon "EDoOrigin" PWild PWild) (PCon "ENumLit" PWild PWild PWild) (PCon "EWideLit" PWild PWild PWild PWild)) () (EVar "False"))))
(DTypeSig false "armTail" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armTail" ((PVar "name") (PCon "Arm" PWild PWild (PVar "body"))) (EApp (EApp (EVar "selfTail") (EVar "name")) (EVar "body")))
(DTypeSig false "calls" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "calls" ((PVar "name") (PVar "f")) (EMatch (EApp (EVar "unwrapLoc") (EVar "f")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "name"))) (arm (PCon "EApp" (PVar "g") PWild) () (EApp (EApp (EVar "calls") (EVar "name")) (EVar "g"))) (arm PWild () (EVar "False"))))
(DTypeSig false "report" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "report" ((PVar "loc") (PVar "kind") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePassthroughArm")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`match` over ")) (EApp (EMethodRef "display") (EVar "kind"))) (ELit (LString " passes the failure straight through: bind it in a `do` block (`pat <- scrutinee`, then the success arm)")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "passthroughFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))
(DFunDef false "passthroughFix" ((PVar "facts") (PVar "ctx") (PVar "e")) (EApp (EApp (EMethodRef "andThen") (EFieldAccess (EVar "ctx") "ctxSpan")) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "Loc" (PVar "path") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "passthroughArms") (EVar "e"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "first") (PVar "pass") (PVar "succArm")) () (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "ctx") "ctxOwn") (EFieldAccess (EVar "ctx") "ctxSpan")) (EApp (EVar "statementParent") (EFieldAccess (EVar "ctx") "ctxParent"))))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "tightSpan") (EApp (EVar "matchScrutOf") (EVar "e")))) (ELam ((PVar "scrutEnd")) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EBinOp "&&" (EBinOp "==" (EApp (EVar "spanEndLine") (EVar "scrutEnd")) (EVar "sl")) (EApp (EApp (EApp (EVar "matchTokenAt") (EVar "facts")) (EVar "sl")) (EVar "sc"))))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EApp (EApp (EApp (EApp (EApp (EVar "positionOk") (EVar "facts")) (EVar "ctx")) (EVar "sl")) (EVar "sc")) (EIf (EBinOp "==" (EVar "ec") (ELit (LInt 0))) (EBinOp "-" (EVar "el") (ELit (LInt 1))) (EVar "el"))))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "nextCode") (EVar "facts")) (EVar "sl"))) (ELam ((PVar "firstArm")) (ELet false (PVar "ac") (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "firstArm"))) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EBinOp ">" (EVar "ac") (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "sl")))))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "passthroughLine") (EVar "first")) (EVar "pass")) (EVar "firstArm"))) (ELam ((PVar "passLine")) (EApp (EApp (EMethodRef "andThen") (EIf (EVar "first") (EApp (EApp (EVar "nextCode") (EVar "facts")) (EVar "passLine")) (EApp (EVar "Some") (EVar "firstArm")))) (ELam ((PVar "succLine")) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EBinOp "||" (EVar "first") (EBinOp "<" (EVar "succLine") (EVar "passLine"))))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EBinOp "==" (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "passLine"))) (EVar "ac")))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EApp (EVar "isPassthroughText") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "passLine"))))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EBinOp "==" (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "succLine"))) (EVar "ac")))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "successParts") (EVar "succArm"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "ctorName") (PVar "inner")) () (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EApp (EVar "not") (EApp (EVar "hasBareStatement") (EVar "succArm"))))) (ELam (PWild) (ELet false (PVar "sline") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "succLine")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "indexOf") (ELit (LString "=>"))) (EVar "sline"))) (ELam ((PVar "arrow")) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "ac")) (EBinOp "+" (EBinOp "+" (EVar "ac") (EApp (EVar "stringLength") (EVar "ctorName"))) (ELit (LInt 1)))) (EVar "sline")) (EBinOp "++" (EVar "ctorName") (ELit (LString " ")))))) (ELam (PWild) (ELet false (PVar "patText") (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "ac") (EApp (EVar "stringLength") (EVar "ctorName")))) (EVar "arrow")) (EVar "sline"))) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EApp (EApp (EVar "patTextOk") (EVar "inner")) (EVar "patText")))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "bodyPlan") (EVar "facts")) (EVar "path")) (EVar "ac")) (EVar "succLine")) (EVar "passLine")) (EVar "arrow"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "blockCol") (PVar "deleted") (PVar "extra")) () (ELet false (PVar "header") (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (ELit (LInt 5))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "do\n")) (EApp (EMethodRef "display") (EApp (EApp (EVar "repeat") (EVar "blockCol")) (ELit (LString " "))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "patText"))) (ELit (LString " <-")))) (EApp (EVar "Some") (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "Unsafe")) (fa "fixEdits" (EBinOp "::" (EVar "header") (EBinOp "++" (EVar "extra") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "deleteLines") (EVar "facts")) (EVar "path"))) (EApp (EVar "runs") (EApp (EVar "sort") (EVar "deleted"))))))) (fa "fixMessage" (ELit (LString "bind the scrutinee in a `do` block")))))))))))))))))))))))))))))))))))))))))))))))))))))))))))
(DTypeSig false "bodyPlan" (TyFun (TyCon "FileFacts") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "FixEdit")))))))))))
(DFunDef false "bodyPlan" ((PVar "facts") (PVar "path") (PVar "ac") (PVar "succLine") (PVar "passLine") (PVar "arrow")) (ELet false (PVar "sline") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "succLine")) (ELet false (PVar "rest") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "arrow") (ELit (LInt 2)))) (EApp (EVar "stringLength") (EVar "sline"))) (EVar "sline")) (EIf (EBinOp "==" (EApp (EVar "trim") (EVar "rest")) (ELit (LString ""))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "nextCode") (EVar "facts")) (EVar "succLine"))) (ELam ((PVar "bodyLine")) (ELet false (PVar "bi") (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "bodyLine"))) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EBinOp ">" (EVar "bi") (EVar "ac")))) (ELam (PWild) (EApp (EVar "Some") (ETuple (EVar "bi") (EListLit (EVar "passLine") (EVar "succLine")) (EListLit)))))))) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EApp (EVar "trim") (EVar "rest")))))) (ELam (PWild) (ELet false (PVar "bodyCol") (EBinOp "-" (EBinOp "+" (EBinOp "+" (EVar "arrow") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "rest"))) (EApp (EVar "stringLength") (EApp (EVar "trimLeft") (EVar "rest")))) (EApp (EVar "Some") (ETuple (EVar "ac") (EListLit (EVar "passLine")) (EListLit (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "succLine")) (EVar "ac")) (EVar "succLine")) (EVar "bodyCol"))) (ELit (LString "")))))))))))))
(DTypeSig false "passthroughArms" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "Bool") (TyCon "Arm") (TyCon "Arm")))))
(DFunDef false "passthroughArms" ((PCon "EMatch" PWild (PList (PVar "a1") (PVar "a2")))) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "bindArm") (EVar "a1")) (EVar "a2"))) (EApp (EVar "Some") (ETuple (EVar "True") (EVar "a1") (EVar "a2"))) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "bindArm") (EVar "a2")) (EVar "a1"))) (EApp (EVar "Some") (ETuple (EVar "False") (EVar "a2") (EVar "a1"))) (EVar "None"))))
(DFunDef false "passthroughArms" (PWild) (EVar "None"))
(DTypeSig false "hasBareStatement" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "hasBareStatement" ((PCon "Arm" PWild PWild (PVar "body"))) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EBlock" (PVar "stmts")) () (EApp (EApp (EVar "anyList") (EVar "isBare")) (EApp (EVar "initList") (EVar "stmts")))) (arm PWild () (EVar "False"))))
(DTypeSig false "isBare" (TyFun (TyCon "DoStmt") (TyCon "Bool")))
(DFunDef false "isBare" ((PCon "DoExpr" PWild)) (EVar "True"))
(DFunDef false "isBare" (PWild) (EVar "False"))
(DTypeSig false "successParts" (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Pat")))))
(DFunDef false "successParts" ((PCon "Arm" (PCon "PCon" (PVar "c") (PList (PVar "p"))) PWild PWild)) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "p"))))
(DFunDef false "successParts" (PWild) (EVar "None"))
(DTypeSig false "passthroughLine" (TyFun (TyCon "Bool") (TyFun (TyCon "Arm") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "passthroughLine" ((PCon "True") PWild (PVar "firstArm")) (EApp (EVar "Some") (EVar "firstArm")))
(DFunDef false "passthroughLine" ((PCon "False") (PCon "Arm" PWild PWild (PVar "body")) PWild) (EApp (EApp (EMethodRef "map") (EVar "spanStartLine")) (EApp (EVar "tightSpan") (EVar "body"))))
(DTypeSig false "spanStartLine" (TyFun (TyCon "Loc") (TyCon "Int")))
(DFunDef false "spanStartLine" ((PCon "Loc" PWild (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeSig false "spanEndLine" (TyFun (TyCon "Loc") (TyCon "Int")))
(DFunDef false "spanEndLine" ((PCon "Loc" PWild PWild PWild (PVar "l") PWild)) (EVar "l"))
(DTypeSig false "statementParent" (TyFun (TyApp (TyCon "Option") (TyCon "ExprKind")) (TyCon "Bool")))
(DFunDef false "statementParent" ((PCon "None")) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" (PCon "KMatch"))) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" (PCon "KLet"))) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" (PCon "KLetGroup"))) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" (PCon "KGuards"))) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" (PCon "KDo"))) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" (PCon "KBlock"))) (EVar "True"))
(DFunDef false "statementParent" ((PCon "Some" PWild)) (EVar "False"))
(DTypeSig false "matchTokenAt" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "matchTokenAt" ((PVar "facts") (PVar "l") (PVar "c")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "c")) (EBinOp "+" (EVar "c") (ELit (LInt 5)))) (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "l"))) (ELit (LString "match"))))
(DTypeSig false "positionOk" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "positionOk" ((PVar "facts") (PVar "ctx") (PVar "l") (PVar "c") (PVar "endLine")) (EBinOp "||" (EApp (EApp (EApp (EVar "assignmentBefore") (EVar "facts")) (EVar "l")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "lastStatement") (EVar "facts")) (EVar "ctx")) (EVar "l")) (EVar "c")) (EVar "endLine"))))
(DTypeSig false "lastStatement" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "lastStatement" ((PVar "facts") (PVar "ctx") (PVar "l") (PVar "c") (PVar "endLine")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "ctx") "ctxParent") (EApp (EVar "Some") (EVar "KDo"))) (EBinOp "==" (EFieldAccess (EVar "ctx") "ctxParent") (EApp (EVar "Some") (EVar "KBlock")))) (EBinOp "==" (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "c")) (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "l")))) (ELit (LString "")))) (EMatch (EApp (EApp (EVar "prevCode") (EVar "facts")) (EVar "l")) (arm (PCon "Some" (PVar "p")) () (EBinOp "==" (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "p"))) (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "l"))))) (arm (PCon "None") () (EVar "False")))) (EMatch (EApp (EApp (EVar "nextCode") (EVar "facts")) (EVar "endLine")) (arm (PCon "Some" (PVar "n")) () (EBinOp "<" (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "n"))) (EApp (EVar "indentWidth") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "l"))))) (arm (PCon "None") () (EVar "True")))))
(DTypeSig false "assignmentBefore" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "assignmentBefore" ((PVar "facts") (PVar "l") (PVar "c")) (EBlock (DoLet false false (PVar "before") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "c")) (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "l")))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "trim") (EVar "before")) (ELit (LString ""))) (EMatch (EApp (EApp (EVar "prevCode") (EVar "facts")) (EVar "l")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "endsAssign") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "p")))) (arm (PCon "None") () (EVar "False"))) (EApp (EVar "endsAssign") (EVar "before"))))))
(DTypeSig false "endsAssign" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "endsAssign" ((PVar "s")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "trimRight") (EVar "s"))) (DoExpr (EBinOp "||" (EApp (EApp (EVar "endsWith") (ELit (LString "=>"))) (EVar "t")) (EBinOp "&&" (EApp (EApp (EVar "endsWith") (ELit (LString "="))) (EVar "t")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "c")) (EApp (EApp (EVar "endsWith") (EBinOp "++" (EVar "c") (ELit (LString "=")))) (EVar "t")))) (EListLit (ELit (LString "=")) (ELit (LString "<")) (ELit (LString ">")) (ELit (LString "!")) (ELit (LString "/"))))))))))
(DTypeSig false "lineAt" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "lineAt" ((PVar "facts") (PVar "n")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "sourceLine") (EVar "facts")) (EVar "n"))))
(DTypeSig false "nextCode" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "nextCode" ((PVar "facts") (PVar "n")) (EMatch (EApp (EApp (EVar "sourceLine") (EVar "facts")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (arm (PCon "Some" (PVar "l")) () (EIf (EApp (EVar "isCodeText") (EVar "l")) (EApp (EVar "Some") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EApp (EApp (EVar "nextCode") (EVar "facts")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "prevCode" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "prevCode" ((PVar "facts") (PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 1))) (EVar "None") (EIf (EApp (EVar "isCodeText") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EVar "prevCode") (EVar "facts")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isPassthroughText" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isPassthroughText" ((PVar "l")) (EMatch (EApp (EApp (EVar "indexOf") (ELit (LString "=>"))) (EVar "l")) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "lhs") (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "l")))) (DoLet false false (PVar "rhs") (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EApp (EVar "stringLength") (EVar "l"))) (EVar "l")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EVar "lhs") (EVar "rhs")) (EBinOp "||" (EBinOp "==" (EVar "lhs") (ELit (LString "None"))) (EApp (EApp (EVar "startsWith") (ELit (LString "Err "))) (EVar "lhs"))))))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "patTextOk" (TyFun (TyCon "Pat") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "patTextOk" ((PVar "p") (PVar "t")) (EBinOp "&&" (EApp (EVar "patShapeOk") (EVar "p")) (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EBinOp "||" (EApp (EVar "isAlnum") (EVar "c")) (EApp (EApp (EDictApp "elem") (EVar "c")) (EListLit (ELit (LChar ",")) (ELit (LChar " ")) (ELit (LChar "(")) (ELit (LChar ")"))))))) (EApp (EMethodRef "toList") (EApp (EVar "stringToChars") (EVar "t"))))))
(DTypeSig false "patShapeOk" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patShapeOk" ((PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patShapeOk" ((PCon "PWild")) (EVar "True"))
(DFunDef false "patShapeOk" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EVar "patShapeOk")) (EVar "ps")))
(DFunDef false "patShapeOk" ((POr (PCon "PLit" PWild) (PCon "PCon" PWild PWild) (PCon "PCons" PWild PWild) (PCon "PList" PWild) (PCon "PAs" PWild PWild PWild PWild) (PCon "POr" PWild) (PCon "PRng" PWild PWild PWild) (PCon "PRec" PWild PWild PWild) (PCon "PAnn" PWild PWild))) (EVar "False"))
(DTypeSig false "runs" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "runs" ((PList)) (EListLit))
(DFunDef false "runs" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EVar "runFrom") (EVar "x")) (EVar "x")) (EVar "xs")))
(DTypeSig false "runFrom" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "runFrom" ((PVar "lo") (PVar "hi") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "y") (EBinOp "+" (EVar "hi") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "runFrom") (EVar "lo")) (EVar "y")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "runFrom" ((PVar "lo") (PVar "hi") (PVar "rest")) (EBinOp "::" (ETuple (EVar "lo") (EVar "hi")) (EApp (EVar "runs") (EVar "rest"))))
(DTypeSig false "deleteLines" (TyFun (TyCon "FileFacts") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "FixEdit")))))
(DFunDef false "deleteLines" ((PVar "facts") (PVar "path") (PTuple (PVar "lo") (PVar "hi"))) (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EBinOp "-" (EVar "lo") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EBinOp "-" (EVar "lo") (ELit (LInt 1)))))) (EVar "hi")) (EApp (EVar "stringLength") (EApp (EApp (EVar "lineAt") (EVar "facts")) (EVar "hi"))))) (ELit (LString ""))))
