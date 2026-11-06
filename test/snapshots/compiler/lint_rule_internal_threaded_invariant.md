# META
source_lines=933
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-threaded-invariant: a top-level self-recursive function whose self-calls all pass two or more of its own parameters through unchanged. Close over them in a where-local `go`. The `--fix` rewrite can leave a let-generalised loop that dictionary-dispatches (#MONOLOCAL); see the notes above `threadFix`.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{
  Arm(..),
  Constraint(..),
  Decl(..),
  Expr(..),
  FunClause(..),
  Guard(..),
  LetBind(..),
  Loc(..),
  Pat(..),
  Ty(..),
  patBoundNames,
}
import frontend.ast_walk.{childExprs}
import frontend.marker.{localBoundNames}
import frontend.parser.{Positions(..)}
import array.{get as arrayGet}
import list.{dropWhile, findMap, get, last, lookup, reverse, sortBy, zip}
import string.{contains, repeat, startsWith, trim, trimLeft, trimRight}
import support.char.{isIdentChar}
import support.util.{allList, anyList, filterList, joinWith, listLen}
import tools.lint_core.{
  Applicability(..),
  Category(..),
  FileFacts,
  Finding(..),
  Fix(..),
  FixEdit(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  factLines,
  factScopes,
  mkRule,
}
import tools.lint_recursion.{
  ArgRole(..), Owner(..), SelfCall(..), selfCalls, spineOf
}
import tools.lint_scope.{FileScopes}
import tools.lint_shared.{
  declLocList,
  isCtorName,
  isEVarNamed,
  mentionsVar,
  ruleNameThreadedInvariant,
  unwrapLoc,
  varSite,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameThreadedInvariant,
      summary =
        "a self-recursive function passes two or more of its parameters through every self-call unchanged: close over them in a where-local `go`",
      doc =
        "A top-level function that calls itself with the same two or more parameters, in the same positions, in every self-call carries those parameters through the whole recursion for nothing. A local `go` in a `where` closes over them, so the recursion names only what changes. The rule reads each function as a group of clauses: a position counts when every full-arity self-call of every clause that makes one passes that clause's own parameter there, unchanged. One invariant parameter is not reported, nor is a `go` that already closes over its invariants, a partial application, mutual recursion, or a loop local to a `let` or `where`.\n\n`--fix --unsafe-fixes` writes the `go` form when the whole shape is known: a signature whose class constraints the closed-over parameters carry, each invariant parameter a plain name (or ignored) in every clause, no list builder in tail position modulo cons, no invariant parameter used only to be passed on, and a `where` of its own only on a single clause. The rest are reported only. Run `medaka fmt --write` after it, then check the converted loop for dictionary dispatch: `go` is inferred, not declared, so a changing parameter whose type only the signature fixes (a counter under `+` or `==`, an element that is interpolated) is let-generalised and the loop passes a dictionary on every call (#MONOLOCAL, MonoLocalBinds). The fix does not see that shape.\n\nBefore:\n  extractFold bare heads acc (x :: xs) = extractFold bare heads (step bare heads acc x) xs\n  extractFold _ _ acc [] = acc\nAfter:\n  extractFold bare heads acc0 xs0 = go acc0 xs0\n    where\n      go acc [] = acc\n      go acc (x :: xs) = go (step bare heads acc x) xs",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = FixableUnsafe,
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
  let groups = functionGroups (declLocList pos prog)
  flatMap (functionFindings facts prog) groups

-- ── the functions of a file ──────────────────────────────────────────────────

-- One clause: the line its name starts (0 when it carries an attribute), its
-- parameters and its body.
data Clause = Clause Int (List Pat) Expr

-- A top-level function: its name, the start line of its first clause, its
-- clauses in order and the start line of the declaration after it (0 at the
-- end of the file).
data Group = Group String (Option Loc) (List Clause) Int

-- Adjacent clauses of one name make one function.
functionGroups : List (Decl, Option Loc) -> List Group
functionGroups dls = foldRight joinClause [] (flatMap clauseOf (withNext dls))

-- Each declaration with the start line of the one after it.
withNext : List (Decl, Option Loc) -> List (Decl, Option Loc, Int)
withNext [] = []
withNext ((d, loc) :: rest) = (d, loc, startOf rest) :: withNext rest

startOf : List (Decl, Option Loc) -> Int
startOf ((_, Some (Loc _ l _ _ _)) :: _) = l
startOf _ = 0

clauseOf : (Decl, Option Loc, Int) -> List (String, Option Loc, Int, Clause)
clauseOf (DFunDef _ n ps body (Loc _ l _ _ _) _, loc, next) =
  [(n, loc, next, Clause l ps body)]
clauseOf (DAttrib _ d, loc, next) = map unplaced (clauseOf (d, loc, next))
clauseOf _ = []

unplaced : (String, Option Loc, Int, Clause) ->
  (String, Option Loc, Int, Clause)
unplaced (n, loc, next, Clause _ ps body) = (n, loc, next, Clause 0 ps body)

joinClause : (String, Option Loc, Int, Clause) -> List Group -> List Group
joinClause (n, loc, _, c) ((Group m _ cs next) :: rest)
  | n == m = Group n loc (c :: cs) next :: rest
joinClause (n, loc, next, c) groups = Group n loc [c] next :: groups

-- ── one function ─────────────────────────────────────────────────────────────

-- A clause that makes self-calls, with the positions all of them pass through
-- unchanged, and the calls.
data Threaded = Threaded (List Pat) (List Int) (List SelfCall)

functionFindings : FileFacts -> List Decl -> Group -> List Finding
functionFindings facts prog (g@(Group name loc clauses _)) =
  match flatMap (clauseThreaded (factScopes facts) name) clauses
    [] => []
    ts@((Threaded ps first _) :: _) =>
      let shared = filterList (inAll ts) first
      if listLen shared >= 2 then
        let names = map (i => paramName ps i) shared
        let calls = flatMap threadedCalls ts
        [report name loc names (threadFix facts prog g shared names calls)]
      else
        []

-- A clause that never names its own function makes no self-call, and that is
-- nearly every clause, so the scope-aware walk runs only on the rest.
clauseThreaded : FileScopes -> String -> Clause -> List Threaded
clauseThreaded scopes name (Clause _ ps body)
  | listLen ps < 2 || not (mentionsVar name body) = []
  | otherwise = match selfCalls scopes (Owner name ps None) body
    [] => []
    calls =>
      [Threaded ps (filterList (unchangedIn calls) [0..=listLen ps - 1]) calls]

threadedCalls : Threaded -> List SelfCall
threadedCalls (Threaded _ _ calls) = calls

inAll : List Threaded -> Int -> Bool
inAll ts i = allList (t => hasPosition i t) ts

hasPosition : Int -> Threaded -> Bool
hasPosition i (Threaded _ positions _) = anyList (== i) positions

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

report : String -> Option Loc -> List String -> Option Fix -> Finding
report name loc names fix =
  let listed = joinWith ", " (map quoted names)
  Finding {
    rule = ruleNameThreadedInvariant,
    message =
      "`\{name}` passes \{listed} through every self-call unchanged: close over them in a where-local `go`",
    severity = SevWarning,
    loc = loc,
    fix = fix,
  }

quoted : String -> String
quoted n = "`\{n}`"

-- ── the fix ──────────────────────────────────────────────────────────────────

-- Unsafe: `--fix --unsafe-fixes` rewrites
--
--   f a b (x :: xs) = ... f a b xs ...      f a b xs0 = go xs0
--   f _ _ [] = e                     ==>      where
--                                               go (x :: xs) = ... go xs ...
--                                               go [] = e
--
-- as text edits: the first clause's head becomes the outer line and the
-- `where`, each clause head becomes `go` over the parameters that change, the
-- clause lines move four columns right, and each self-call loses its invariant
-- arguments. The signature, the doc comment and every comment stay where they
-- are; the driver demotes a fix whose edit would cut through a comment. The
-- outer function keeps its name and signature, so a partial application of it
-- elsewhere still means the same.
--
-- A line whose later tokens would move against the next line (a block opened
-- after an edit on that line) is padded with spaces instead, so every column
-- the layout reads keeps its place relative to the lines below.
--
-- The fix is withheld, the finding still reported, when:
--   * a clause pattern-matches an invariant parameter, names it differently,
--     or ignores it (`_`, `_x`) while its body mentions the name, which the
--     closed-over parameter would capture;
--   * a clause head is not one line `f p1 .. pn` followed by `=` or a guard,
--     or carries an attribute;
--   * the function has no signature, or a class constraint of the signature
--     constrains a type variable that no invariant parameter's type mentions:
--     the local `go` would be generalised over it on its own;
--   * a self-call is the tail of `::` or the last field of a constructor: the
--     backend builds such a list in constant stack for a top-level function
--     only (tail recursion modulo cons);
--   * an invariant parameter is used only to be passed on (a dead parameter,
--     which wants deleting, not closing over);
--   * a clause has a `where` of its own, unless it is the only clause, its
--     `where` stands on its own line and no binding in it mentions a name the
--     changing parameters bind: the bindings then join the new `where`;
--   * an invariant argument of a self-call is bracketed, or starts its line
--     with more after it;
--   * the signature has an effect row variable: `go` would infer and
--     generalise a row of its own;
--   * a match-arm guard reads an invariant parameter (#4901);
--   * a field read or record update reads a record that is neither an
--     invariant parameter nor a name no clause binds: `go` learns the types of
--     its parameters only by inference, too late to choose between records
--     that share the field name;
--   * a triple-quoted string or a tab sits in the function, where moving a
--     line would change text or columns.
-- Not seen by shape: a method whose impl only the type of a changing parameter
-- selects can resolve to another impl in scope while `go` is inferred. That
-- impl fixes the parameter's type, which the call of `go` then contradicts, so
-- the result does not type-check; a rewrite that does type-check has the same
-- types and so the same impls.
-- Not seen either, and not decidable from syntax: `go` is let-generalised, so a
-- changing parameter whose type only the outer signature fixes becomes a type
-- variable of its own. Under an overloaded operator, literal or interpolation
-- it carries a class constraint, and the loop then dictionary-dispatches on
-- every call (#MONOLOCAL, MonoLocalBinds). Whether a captured variable or a
-- monomorphic callee fixes that type takes type inference, which this rule
-- does not run; check the converted loop's IR for a `mdk.gen.dictcell`.
-- The local is `go`, or `go1`, `go2`, ... when the function mentions `go`, and
-- the outer parameters get fresh names no clause mentions. `go` always takes
-- its parameters explicitly, `()` when every parameter is invariant, so the
-- value restriction never applies to it. A self-call partially applied, over-
-- applied or made under a shadowing binder is not a self-call and stays.
threadFix : FileFacts ->
  List Decl ->
  Group ->
  List Int ->
  List String ->
  List SelfCall ->
  Option Fix
threadFix facts prog (Group name _ clauses next) shared names calls = do
  first <- clauseHead clauses
  let ls = factLines facts
  let plan = Plan {
    plLines = ls,
    plName = name,
    plArity = listLen (clausePats first),
    plShared = shared,
    plNames = names,
    plCalls = calls,
    plBound = localBoundNames (filterList (definesName name) prog),
  }
  spans <- traverse (clauseSpan plan) (withBounds (lineCount ls next) clauses)
  guard (allList (spanFits plan) spans)
  guard (allList (usedBeyondCalls plan spans) names)
  guard (not (anyList (sp => buildsModuloCons plan sp.spBody) spans))
  guard (allList (sp => recordTargetsFit plan sp.spBody) spans)
  guard (not (anyList (sp => armGuardReadsInvariant plan sp.spBody) spans))
  guard (signatureFits plan prog)
  merge <- whereMerge plan spans
  edits <- rewriteEdits plan spans merge
  Some Fix {
    fixApplicability = Unsafe,
    fixEdits = edits,
    fixMessage = "close over the invariant parameters in a where-local `go`",
  }

clauseHead : List Clause -> Option Clause
clauseHead (c :: _) = Some c
clauseHead [] = None

clausePats : Clause -> List Pat
clausePats (Clause _ ps _) = ps

definesName : String -> Decl -> Bool
definesName name (DFunDef _ n _ _ _ _) = n == name
definesName _ _ = False

-- What the rewrite of one function reads: the file's lines, the function's
-- name and arity, its invariant positions with their names, every self-call
-- it makes, and every name its clauses bind (parameters included).
data Plan = Plan {
  plLines : Array String,
  plName : String,
  plArity : Int,
  plShared : List Int,
  plNames : List String,
  plCalls : List SelfCall,
  plBound : List String,
}

-- One clause as written: its head line, its last code line, its parameters,
-- its body and the columns of its parameters in the head.
data Span = Span {
  spFirst : Int,
  spLast : Int,
  spPats : List Pat,
  spBody : Expr,
  spAtoms : List (Int, Int),
}

-- The line after the last of the file, for a function that ends it.
lineCount : Array String -> Int -> Int
lineCount ls next = if next > 0 then next else arrayLength ls + 1

-- Each clause with the line its successor starts on.
withBounds : Int -> List Clause -> List (Clause, Int)
withBounds bound cs0 = go cs0
  where
    go [] = []
    go [c] = [(c, bound)]
    go (c :: rest@((Clause l _ _) :: _)) = (c, l) :: go rest

clauseSpan : Plan -> (Clause, Int) -> Option Span
clauseSpan plan (Clause l ps body, bound) = do
  guard (l > 0)
  let text = lineText plan.plLines l
  guard (startsWith (plan.plName ++ " ") text)
  atoms <- headAtoms text (stringLength plan.plName)
  guard (listLen atoms == listLen ps && listLen ps == plan.plArity)
  Some Span {
    spFirst = l,
    spLast = lastCode plan.plLines l (bound - 1),
    spPats = ps,
    spBody = body,
    spAtoms = atoms,
  }

lineText : Array String -> Int -> String
lineText ls n = optionOr "" (arrayGet (n - 1) ls)

isCode : String -> Bool
isCode s =
  let t = trim s
  t /= "" && not (startsWith "--" t)

indentAt : Array String -> Int -> Int
indentAt ls n =
  let s = lineText ls n
  stringLength s - stringLength (trimLeft s)

-- The last code line from `lo` up to `hi`, `lo` itself when there is none.
lastCode : Array String -> Int -> Int -> Int
lastCode ls lo hi0 = go hi0
  where
    go hi
      | hi <= lo = lo
      | isCode (lineText ls hi) = hi
      | otherwise = go (hi - 1)

-- The columns of the parameter patterns of a head line, from `start` (just
-- after the function's name) to the first `=` or `|` outside brackets.
-- `None` for a head that runs on, holds a comment or a character literal, or
-- whose brackets do not balance.
headAtoms : String -> Int -> Option (List (Int, Int))
headAtoms text start =
  let cs = stringToChars text
  headAtomsFrom cs (arrayLength cs) start 0 (0 - 1) []

-- Top level rather than a where-local loop: a local `go` here is let-generalised
-- over `depth` and dictionary-passes the walk (#MONOLOCAL, MonoLocalBinds).
headAtomsFrom : Array Char ->
  Int ->
  Int ->
  Int ->
  Int ->
  List (Int, Int) ->
  Option (List (Int, Int))
headAtomsFrom cs n i depth from acc
  | i >= n = if depth == 0 then Some (reverse (closed from i acc)) else None
  | otherwise = headAtomStep cs n i depth from acc (arrayGetUnsafe i cs)

headAtomStep : Array Char ->
  Int ->
  Int ->
  Int ->
  Int ->
  List (Int, Int) ->
  Char ->
  Option (List (Int, Int))
headAtomStep cs n i depth from acc c
  | depth == 0 && (c == '=' || c == '|') =
    if from >= 0 then None else Some (reverse acc)
  | depth == 0 && c == ' ' =
    headAtomsFrom cs n (i + 1) 0 (0 - 1) (closed from i acc)
  | c == '"' =
    headAtomsFrom cs n (stringLitEnd cs n (i + 1)) depth (opened from i) acc
  | c == '-' && i + 1 < n && arrayGetUnsafe (i + 1) cs == '-' = None
  | c == '\'' && not (i > 0 && isIdentChar (arrayGetUnsafe (i - 1) cs)) = None
  | c == '(' || c == '[' || c == '{' =
    headAtomsFrom cs n (i + 1) (depth + 1) (opened from i) acc
  | c == ')' || c == ']' || c == '}' =
    if depth == 0 then None else headAtomsFrom cs n (i + 1) (depth - 1) from acc
  | otherwise = headAtomsFrom cs n (i + 1) depth (opened from i) acc

-- The index just past the closing quote of a string literal whose body starts
-- at `j0`; `n` when the text runs out first.
stringLitEnd : Array Char -> Int -> Int -> Int
stringLitEnd cs n j0 = go j0
  where
    go j
      | j >= n = n
      | arrayGetUnsafe j cs == '\\' = go (j + 2)
      | arrayGetUnsafe j cs == '"' = j + 1
      | otherwise = go (j + 1)

closed : Int -> Int -> List (Int, Int) -> List (Int, Int)
closed from i acc = if from >= 0 then (from, i) :: acc else acc

opened : Int -> Int -> Int
opened from i = if from >= 0 then from else i

atomText : Plan -> Span -> Int -> String
atomText plan sp i = match get i sp.spAtoms
  Some (a, b) => stringSlice a b (lineText plan.plLines sp.spFirst)
  None => ""

headEnd : Span -> Int
headEnd sp = match last sp.spAtoms
  Some (_, b) => b
  None => 0

-- ── the conditions ───────────────────────────────────────────────────────────

-- Every clause binds each invariant parameter to its name, or ignores it and
-- does not mention the name; no line of it is a triple-quoted string, holds a
-- tab, or starts at column 0 after the head.
spanFits : Plan -> Span -> Bool
spanFits plan sp =
  allList (invariantFits plan sp) (zip plan.plShared plan.plNames)
    && allList (lineFits plan sp) [sp.spFirst..=sp.spLast]

invariantFits : Plan -> Span -> (Int, String) -> Bool
invariantFits plan sp (i, v) = match get i sp.spPats
  Some (PVar x _ _) =>
    atomText plan sp i == x
      && (x == v
        || startsWith "_" x
          && not (mentionsVar v sp.spBody || mentionsVar x sp.spBody))
  Some PWild => atomText plan sp i == "_" && not (mentionsVar v sp.spBody)
  _ => False

lineFits : Plan -> Span -> Int -> Bool
lineFits plan sp l =
  let s = lineText plan.plLines l
  not (contains "\"\"\"" s || contains "\t" s)
    && (l == sp.spFirst || not (isCode s) || indentAt plan.plLines l > 0)

-- An invariant parameter that the clauses mention only as the arguments of the
-- self-calls is dead.
usedBeyondCalls : Plan -> List Span -> String -> Bool
usedBeyondCalls plan spans v =
  sum (map (sp => countVar v sp.spBody) spans) > listLen plan.plCalls

countVar : String -> Expr -> Int
countVar x e = match unwrapLoc e
  EVar w => if w == x then 1 else 0
  e2 => sum (map (countVar x) (childExprs e2))

-- A self-call as the tail of `::` or as the last field of a constructor.
buildsModuloCons : Plan -> Expr -> Bool
buildsModuloCons plan e =
  consTail plan (unwrapLoc e)
    || anyList (buildsModuloCons plan) (childExprs (unwrapLoc e))

consTail : Plan -> Expr -> Bool
consTail plan (EBinOp "::" _ tl _) = isSelfApp plan tl
consTail plan (e@(EApp _ _)) = match spineOf e []
  (hd, args) =>
    isCtorHead hd
      && (match last args
        Some a => isSelfApp plan a
        None => False)
consTail _ _ = False

isCtorHead : Expr -> Bool
isCtorHead e = match unwrapLoc e
  EVar c => isCtorName c
  _ => False

isSelfApp : Plan -> Expr -> Bool
isSelfApp plan e = match spineOf e []
  (hd, args) => isEVarNamed plan.plName hd && listLen args == plan.plArity

-- A match-arm guard that reads an invariant parameter: the emitter cannot
-- capture it in the local `go` (#4901).
armGuardReadsInvariant : Plan -> Expr -> Bool
armGuardReadsInvariant plan e =
  armGuards plan (unwrapLoc e)
    || anyList (armGuardReadsInvariant plan) (childExprs (unwrapLoc e))

armGuards : Plan -> Expr -> Bool
armGuards plan (EMatch _ arms) = anyList (armReads plan) arms
armGuards _ _ = False

armReads : Plan -> Arm -> Bool
armReads plan (Arm _ gs _) = anyList (guardReads plan) gs

guardReads : Plan -> Guard -> Bool
guardReads plan (GBool g) = readsInvariant plan g
guardReads plan (GBind _ g) = readsInvariant plan g

readsInvariant : Plan -> Expr -> Bool
readsInvariant plan g = anyList (n => mentionsVar n g) plan.plNames

-- A field read or record update whose record is an invariant parameter or a
-- name no clause binds. The type of anything else may reach the local `go`
-- only through its inferred parameters, too late to choose between records
-- that share the field name.
recordTargetsFit : Plan -> Expr -> Bool
recordTargetsFit plan e =
  targetFits plan (unwrapLoc e)
    && allList (recordTargetsFit plan) (childExprs (unwrapLoc e))

targetFits : Plan -> Expr -> Bool
targetFits plan (EFieldAccess r _ _) = recordRootFits plan r
targetFits plan (ERecordUpdate r _ _) = recordRootFits plan r
targetFits _ _ = True

recordRootFits : Plan -> Expr -> Bool
recordRootFits plan r = match unwrapLoc r
  EFieldAccess inner _ _ => recordRootFits plan inner
  EVar n => anyList (== n) plan.plNames || not (anyList (== n) plan.plBound)
  _ => False

-- A signature exists, it has no effect row variable (the local `go` would
-- infer its own row and generalise it), and every type variable a class
-- constraint names is mentioned by the type of an invariant parameter, so
-- `go` sees it fixed.
signatureFits : Plan -> List Decl -> Bool
signatureFits plan prog = match findMap (sigNamed plan.plName) prog
  None => False
  Some t => tyEvery (_ => True) isEmpty t && constraintsHeld plan t

constraintsHeld : Plan -> Ty -> Bool
constraintsHeld plan (TyConstrained cs t) =
  let doms = domains plan.plArity t
  let held = flatMap (i => toList (get i doms)) plan.plShared
  listLen doms == plan.plArity
    && allList
      (c =>
        allList
          (tyEvery (v => anyList (tyMentions v) held) (_ => True))
          c.constraintArgs)
      cs
constraintsHeld _ _ = True

sigNamed : String -> Decl -> Option Ty
sigNamed n (DTypeSig _ m t _) = if m == n then Some t else None
sigNamed _ _ = None

-- The first `k` parameter types of a function type.
domains : Int -> Ty -> List Ty
domains k (TyFun a b)
  | k > 0 = a :: domains (k - 1) b
domains _ _ = []

tyMentions : String -> Ty -> Bool
tyMentions v t = not (tyEvery (/= v) (_ => True) t)

-- Whether every type variable `t` names satisfies `ok` and every effect row
-- tail in it satisfies `okTail`.
tyEvery : (String -> Bool) -> (List String -> Bool) -> Ty -> Bool
tyEvery ok okTail t0 = go t0
  where
    go (TyVar v) = ok v
    go (TyApp f x) = go f && go x
    go (TyFun a b) = go a && go b
    go (TyTuple ts) = allList go ts
    go (TyEffect _ tl t) = okTail tl && go t
    go (TyConstrained cs t) =
      allList (c => allList go c.constraintArgs) cs && go t
    go (TyNamed _ t _) = go t
    go (TyQual t _ _) = go t
    go (TyRow _ tl _) = okTail tl
    go (TyCon { tyConName = _ }) = True
    go (TyAuth _ _) = True

-- `Some None` when no clause has a `where`, `Some (Some w)` when the only
-- clause has one on line `w` whose bindings can join the new `where`, and
-- `None` otherwise.
whereMerge : Plan -> List Span -> Option (Option Int)
whereMerge plan spans =
  match (flatMap
    (sp => filterList (hasWhere plan) [sp.spFirst..=sp.spLast])
    spans)
    [] => Some None
    [w] => match spans
      [sp] =>
        if trim (lineText plan.plLines w) == "where"
          && indentAt plan.plLines w == 2
          && bindingsFit plan sp w then
          Some (Some w)
        else
          None
      _ => None
    _ => None

hasWhere : Plan -> Int -> Bool
hasWhere plan l = anyList (== "where") (identifiersIn (lineText plan.plLines l))

bindingsFit : Plan -> Span -> Int -> Bool
bindingsFit plan sp w = match unwrapLoc sp.spBody
  ELetGroup binds _ =>
    let changing = flatMap patBoundNames (restPats plan sp)
    allList (b => not (anyList (n => bindMentions n b) changing)) binds
      && allList
        (l =>
          not (isCode (lineText plan.plLines l))
            || indentAt plan.plLines l >= 4)
        [w + 1..=sp.spLast]
  _ => False

bindMentions : String -> LetBind -> Bool
bindMentions n (LetBind _ clauses _ _) =
  anyList ((FunClause _ body) => mentionsVar n body) clauses

-- ── the edits ────────────────────────────────────────────────────────────────

-- One edit inside a line of a self-call: line, columns and replacement.
data Cut = Cut Int Int Int String

-- The positions that change, in order.
restOf : Plan -> List Int
restOf plan =
  filterList (i => not (anyList (== i) plan.plShared)) [0..=plan.plArity - 1]

restPats : Plan -> Span -> List Pat
restPats plan sp = flatMap (i => toList (get i sp.spPats)) (restOf plan)

rewriteEdits : Plan -> List Span -> Option Int -> Option (List FixEdit)
rewriteEdits plan spans merge = do
  let taken = flatMap (sp => regionWords plan sp) spans
  let goName = if anyList (== "go") taken then freshFrom taken "go" 1 else "go"
  let fresh = outerNames plan spans taken goName
  let goArgs = if listLen fresh == 0 then " ()" else ""
  let callHead = goName ++ goArgs
  pieces <- traverse (callPieces plan callHead) plan.plCalls
  let cuts = flatMap fst pieces
  let dropped = flatMap snd pieces ++ toList merge
  guard (allList (cutInside spans) cuts)
  lineCuts <- traverse (lineEdits plan spans dropped merge) (cutLines cuts)
  heads <- traverse
    (headEdit plan dropped merge goName fresh)
    (indexedSpans spans)
  let shifts = flatMap (shiftEdits plan dropped merge) spans
  Some
    (heads
      ++ flatMap (es => es) lineCuts
      ++ shifts
      ++ map (dropLine plan) dropped)

indexedSpans : List Span -> List (Int, Span)
indexedSpans spans = zip [0..=listLen spans - 1] spans

-- Every identifier-like word of a clause's lines, comments and strings too.
regionWords : Plan -> Span -> List String
regionWords plan sp =
  flatMap
    (l => identifiersIn (lineText plan.plLines l))
    [sp.spFirst..=sp.spLast]

identifiersIn : String -> List String
identifiersIn s = go 0 (0 - 1) []
  where
    cs = stringToChars s
    n = arrayLength cs
    go i from acc
      | i >= n = reverse (word from i acc)
      | isIdentChar (arrayGetUnsafe i cs) = go (i + 1) (opened from i) acc
      | otherwise = go (i + 1) (0 - 1) (word from i acc)
    word from i acc = if from >= 0 then stringSlice from i s :: acc else acc

-- `base` followed by the first number from `k0` on that no word of the
-- function spells.
freshFrom : List String -> String -> Int -> String
freshFrom taken base k0 = go k0
  where
    go k =
      let candidate = base ++ intToString k
      if anyList (== candidate) taken then go (k + 1) else candidate

-- Names for the outer parameters that change: the clauses' own name with its
-- trailing digits replaced by the first free number.
outerNames : Plan -> List Span -> List String -> String -> List String
outerNames plan spans taken goName = go (goName :: taken) (restOf plan)
  where
    go _ [] = []
    go used (i :: is) =
      let n = freshFrom used (baseName spans i) 0
      n :: go (n :: used) is

baseName : List Span -> Int -> String
baseName spans i = match findMap (sp => namedAt sp i) spans
  Some n => stripDigits n
  None => if anyList (sp => listLike sp i) spans then "xs" else "x"

namedAt : Span -> Int -> Option String
namedAt sp i = match get i sp.spPats
  Some (PVar n _ _) => if startsWith "_" n then None else Some n
  Some (PAs n _ _ _) => Some n
  _ => None

listLike : Span -> Int -> Bool
listLike sp i = match get i sp.spPats
  Some (PCons _ _) => True
  Some (PList _) => True
  _ => False

stripDigits : String -> String
stripDigits n =
  let cs = toList (stringToChars n)
  let kept =
    reverse (dropWhile (c => c >= '0' && c <= '9' || c == '\'') (reverse cs))
  if listLen kept == 0 then "x" else stringFromChars (arrayFromList kept)

-- The cuts of one self-call, and the lines it leaves empty: the head becomes
-- `go`, each invariant argument goes with the spaces before it, or with its
-- whole line when it stands alone there.
callPieces : Plan -> String -> SelfCall -> Option (List Cut, List Int)
callPieces plan callHead (SelfCall _ e _) = match spineOf e []
  (hd, args) => do
    (Loc _ hl hc _ hec) <- varSite hd
    guard (stringSlice hc hec (lineText plan.plLines hl) == plan.plName)
    pieces <- traverse (argPiece plan args) (zip plan.plShared plan.plNames)
    Some (Cut hl hc hec callHead :: flatMap fst pieces, flatMap snd pieces)

argPiece : Plan -> List Expr -> (Int, String) -> Option (List Cut, List Int)
argPiece plan args (i, v) = do
  a <- get i args
  (Loc _ al ac el aec) <- varSite a
  let s = lineText plan.plLines al
  guard (el == al && stringSlice ac aec s == v)
  if trim s == v then
    Some ([], [al])
  else
    let kept = stringLength (trimRight (stringSlice 0 ac s))
    if kept > 0 && kept < ac then Some ([Cut al kept aec ""], []) else None

cutInside : List Span -> Cut -> Bool
cutInside spans (Cut l c _ _) =
  anyList
    (sp =>
      l >= sp.spFirst && l <= sp.spLast && (l > sp.spFirst || c >= headEnd sp))
    spans

cutLine : Cut -> Int
cutLine (Cut l _ _ _) = l

cutStart : Cut -> Int
cutStart (Cut _ c _ _) = c

cutKey : Cut -> (Int, Int)
cutKey (Cut l c _ _) = (l, c)

cutLines : List Cut -> List (Int, List Cut)
cutLines cuts =
  let sorted = sortBy (a b => compare (cutKey a) (cutKey b)) cuts
  foldRight addCut [] sorted

addCut : Cut -> List (Int, List Cut) -> List (Int, List Cut)
addCut c ((l, cs) :: rest)
  | l == cutLine c = (l, c :: cs) :: rest
addCut c groups = (cutLine c, [c]) :: groups

-- The cuts of one line, padded with spaces to their own width when a token
-- after them would move against the next line.
lineEdits : Plan ->
  List Span ->
  List Int ->
  Option Int ->
  (Int, List Cut) ->
  Option (List FixEdit)
lineEdits plan spans dropped merge (l, cs) = do
  sp <- findMap
    (s => if l >= s.spFirst && l <= s.spLast then Some s else None)
    spans
  let s = lineText plan.plLines l
  let start = match cs
    c :: _ => cutStart c
    [] => 0
  let below = nextCodeLine plan dropped l (limitFor merge sp l)
  let pad =
    if l == sp.spFirst then
      isSome below
    else
      movesTokens s cs
        && (match below
          Some b => indentAt plan.plLines b >= start
          None => False)
  traverse (cutEdit pad) cs

movesTokens : String -> List Cut -> Bool
movesTokens _ [] = False
movesTokens s (cs@(_ :: rest)) =
  let ends = map cutEnd cs
  let starts = map cutStart rest ++ [stringLength s]
  anyList ((a, b) => trim (stringSlice a b s) /= "") (zip ends starts)

cutEnd : Cut -> Int
cutEnd (Cut _ _ e _) = e

cutEdit : Bool -> Cut -> Option FixEdit
cutEdit pad (Cut l c e text)
  | not pad = Some (FixEdit (Loc "" l c l e) text)
  | stringLength text <= e - c =
    Some
      (FixEdit
        (Loc "" l c l e)
        (text ++ repeat (e - c - stringLength text) " "))
  | otherwise = None

-- The last line the layout of line `l` answers to: a body line answers to the
-- body, which ends before a `where` that joins the new one.
limitFor : Option Int -> Span -> Int -> Int
limitFor (Some w) sp l = if l < w then w - 1 else sp.spLast
limitFor None sp _ = sp.spLast

nextCodeLine : Plan -> List Int -> Int -> Int -> Option Int
nextCodeLine plan dropped l0 limit = go (l0 + 1)
  where
    go l
      | l > limit = None
      | anyList (== l) dropped || not (isCode (lineText plan.plLines l)) =
        go (l + 1)
      | otherwise = Some l

-- The head of clause `k`: the outer line and the `where` before the first.
headEdit : Plan ->
  List Int ->
  Option Int ->
  String ->
  List String ->
  (Int, Span) ->
  Option FixEdit
headEdit plan dropped merge goName fresh (k, sp) = do
  let s = lineText plan.plLines sp.spFirst
  let he = headEnd sp
  let changing = map (i => " " ++ atomText plan sp i) (restOf plan)
  let goHead =
    goName ++ (if listLen changing == 0 then " ()" else stringConcat changing)
  let d = 4 + stringLength goHead - he
  guard (d <= 4)
  let post = stringSlice he (stringLength s) s
  let at = he + stringLength post - stringLength (trimLeft post)
  let lead = trim post
  let below =
    nextCodeLine plan dropped sp.spFirst (limitFor merge sp sp.spFirst)
  let pad =
    lead /= ""
      && lead /= "="
      && (match below
        Some b => indentAt plan.plLines b + 4 > at + d
        None => False)
  let padding = if pad then repeat (4 - d) " " else ""
  let prefix =
    if k == 0 then outerLine plan goName fresh ++ "\n  where\n    " else "    "
  Some
    (FixEdit (Loc "" sp.spFirst 0 sp.spFirst he) (prefix ++ goHead ++ padding))

outerLine : Plan -> String -> List String -> String
outerLine plan goName fresh =
  let params = outerParams plan fresh
  let args =
    if listLen fresh == 0 then " ()" else stringConcat (map (" " ++ _) fresh)
  let spaced = stringConcat (map (" " ++ _) params)
  "\{plan.plName}\{spaced} = \{goName}\{args}"

-- The invariant positions keep their names; the others take the fresh ones.
outerParams : Plan -> List String -> List String
outerParams plan fresh = map (i => paramAt plan fresh i) [0..=plan.plArity - 1]

paramAt : Plan -> List String -> Int -> String
paramAt plan fresh i = match lookup i (zip plan.plShared plan.plNames)
  Some v => v
  None => optionOr "_" (lookup i (zip (restOf plan) fresh))

-- Four columns right for every line of a clause after its head, but the lines
-- that go and the bindings of a `where` that joins the new one.
shiftEdits : Plan -> List Int -> Option Int -> Span -> List FixEdit
shiftEdits plan dropped merge sp =
  map
    (l => FixEdit (Loc "" l 0 l 0) "    ")
    (filterList
      (l => shifted plan dropped merge l)
      [sp.spFirst + 1..=sp.spLast])

shifted : Plan -> List Int -> Option Int -> Int -> Bool
shifted plan dropped merge l =
  not (anyList (== l) dropped)
    && trim (lineText plan.plLines l) /= ""
    && (match merge
      Some w => l < w
      None => True)

-- Removes line `l` with the newline before it.
dropLine : Plan -> Int -> FixEdit
dropLine plan l =
  FixEdit
    (Loc
      ""
      (l - 1)
      (stringLength (lineText plan.plLines (l - 1)))
      l
      (stringLength (lineText plan.plLines l)))
    ""
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Constraint" true) (mem "Decl" true) (mem "Expr" true) (mem "FunClause" true) (mem "Guard" true) (mem "LetBind" true) (mem "Loc" true) (mem "Pat" true) (mem "Ty" true) (mem "patBoundNames" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "childExprs" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "localBoundNames" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("array") ((mem "get" false "arrayGet"))))
(DUse false (UseGroup ("list") ((mem "dropWhile" false) (mem "findMap" false) (mem "get" false) (mem "last" false) (mem "lookup" false) (mem "reverse" false) (mem "sortBy" false) (mem "zip" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "repeat" false) (mem "startsWith" false) (mem "trim" false) (mem "trimLeft" false) (mem "trimRight" false))))
(DUse false (UseGroup ("support" "char") ((mem "isIdentChar" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "filterList" false) (mem "joinWith" false) (mem "listLen" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factLines" false) (mem "factScopes" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "ArgRole" true) (mem "Owner" true) (mem "SelfCall" true) (mem "selfCalls" false) (mem "spineOf" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "declLocList" false) (mem "isCtorName" false) (mem "isEVarNamed" false) (mem "mentionsVar" false) (mem "ruleNameThreadedInvariant" false) (mem "unwrapLoc" false) (mem "varSite" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameThreadedInvariant")) (fa "summary" (ELit (LString "a self-recursive function passes two or more of its parameters through every self-call unchanged: close over them in a where-local `go`"))) (fa "doc" (ELit (LString "A top-level function that calls itself with the same two or more parameters, in the same positions, in every self-call carries those parameters through the whole recursion for nothing. A local `go` in a `where` closes over them, so the recursion names only what changes. The rule reads each function as a group of clauses: a position counts when every full-arity self-call of every clause that makes one passes that clause's own parameter there, unchanged. One invariant parameter is not reported, nor is a `go` that already closes over its invariants, a partial application, mutual recursion, or a loop local to a `let` or `where`.\n\n`--fix --unsafe-fixes` writes the `go` form when the whole shape is known: a signature whose class constraints the closed-over parameters carry, each invariant parameter a plain name (or ignored) in every clause, no list builder in tail position modulo cons, no invariant parameter used only to be passed on, and a `where` of its own only on a single clause. The rest are reported only. Run `medaka fmt --write` after it, then check the converted loop for dictionary dispatch: `go` is inferred, not declared, so a changing parameter whose type only the signature fixes (a counter under `+` or `==`, an element that is interpolated) is let-generalised and the loop passes a dictionary on every call (#MONOLOCAL, MonoLocalBinds). The fix does not see that shape.\n\nBefore:\n  extractFold bare heads acc (x :: xs) = extractFold bare heads (step bare heads acc x) xs\n  extractFold _ _ acc [] = acc\nAfter:\n  extractFold bare heads acc0 xs0 = go acc0 xs0\n    where\n      go acc [] = acc\n      go acc (x :: xs) = go (step bare heads acc x) xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "FixableUnsafe")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleThreadedInvariant")) (EVar "None")))
(DTypeSig false "ruleThreadedInvariant" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleThreadedInvariant" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "groups") (EApp (EVar "functionGroups") (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "functionFindings") (EVar "facts")) (EVar "prog"))) (EVar "groups")))))
(DData Private "Clause" () ((variant "Clause" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) ())
(DData Private "Group" () ((variant "Group" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "Clause")) (TyCon "Int")))) ())
(DTypeSig false "functionGroups" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "Group"))))
(DFunDef false "functionGroups" ((PVar "dls")) (EApp (EApp (EApp (EVar "foldRight") (EVar "joinClause")) (EListLit)) (EApp (EApp (EVar "flatMap") (EVar "clauseOf")) (EApp (EVar "withNext") (EVar "dls")))))
(DTypeSig false "withNext" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int")))))
(DFunDef false "withNext" ((PList)) (EListLit))
(DFunDef false "withNext" ((PCons (PTuple (PVar "d") (PVar "loc")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "d") (EVar "loc") (EApp (EVar "startOf") (EVar "rest"))) (EApp (EVar "withNext") (EVar "rest"))))
(DTypeSig false "startOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Int")))
(DFunDef false "startOf" ((PCons (PTuple PWild (PCon "Some" (PCon "Loc" PWild (PVar "l") PWild PWild PWild))) PWild)) (EVar "l"))
(DFunDef false "startOf" (PWild) (ELit (LInt 0)))
(DTypeSig false "clauseOf" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int") (TyCon "Clause")))))
(DFunDef false "clauseOf" ((PTuple (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") (PCon "Loc" PWild (PVar "l") PWild PWild PWild) PWild) (PVar "loc") (PVar "next"))) (EListLit (ETuple (EVar "n") (EVar "loc") (EVar "next") (EApp (EApp (EApp (EVar "Clause") (EVar "l")) (EVar "ps")) (EVar "body")))))
(DFunDef false "clauseOf" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc") (PVar "next"))) (EApp (EApp (EVar "map") (EVar "unplaced")) (EApp (EVar "clauseOf") (ETuple (EVar "d") (EVar "loc") (EVar "next")))))
(DFunDef false "clauseOf" (PWild) (EListLit))
(DTypeSig false "unplaced" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int") (TyCon "Clause")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int") (TyCon "Clause"))))
(DFunDef false "unplaced" ((PTuple (PVar "n") (PVar "loc") (PVar "next") (PCon "Clause" PWild (PVar "ps") (PVar "body")))) (ETuple (EVar "n") (EVar "loc") (EVar "next") (EApp (EApp (EApp (EVar "Clause") (ELit (LInt 0))) (EVar "ps")) (EVar "body"))))
(DTypeSig false "joinClause" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int") (TyCon "Clause")) (TyFun (TyApp (TyCon "List") (TyCon "Group")) (TyApp (TyCon "List") (TyCon "Group")))))
(DFunDef false "joinClause" ((PTuple (PVar "n") (PVar "loc") PWild (PVar "c")) (PCons (PCon "Group" (PVar "m") PWild (PVar "cs") (PVar "next")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "Group") (EVar "n")) (EVar "loc")) (EBinOp "::" (EVar "c") (EVar "cs"))) (EVar "next")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "joinClause" ((PTuple (PVar "n") (PVar "loc") (PVar "next") (PVar "c")) (PVar "groups")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "Group") (EVar "n")) (EVar "loc")) (EListLit (EVar "c"))) (EVar "next")) (EVar "groups")))
(DData Private "Threaded" () ((variant "Threaded" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "SelfCall"))))) ())
(DTypeSig false "functionFindings" (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Group") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "functionFindings" ((PVar "facts") (PVar "prog") (PAs "g" (PCon "Group" (PVar "name") (PVar "loc") (PVar "clauses") PWild))) (EMatch (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "clauseThreaded") (EApp (EVar "factScopes") (EVar "facts"))) (EVar "name"))) (EVar "clauses")) (arm (PList) () (EListLit)) (arm (PAs "ts" (PCons (PCon "Threaded" (PVar "ps") (PVar "first") PWild) PWild)) () (EBlock (DoLet false false (PVar "shared") (EApp (EApp (EVar "filterList") (EApp (EVar "inAll") (EVar "ts"))) (EVar "first"))) (DoExpr (EIf (EBinOp ">=" (EApp (EVar "listLen") (EVar "shared")) (ELit (LInt 2))) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EVar "paramName") (EVar "ps")) (EVar "i")))) (EVar "shared"))) (DoLet false false (PVar "calls") (EApp (EApp (EVar "flatMap") (EVar "threadedCalls")) (EVar "ts"))) (DoExpr (EListLit (EApp (EApp (EApp (EApp (EVar "report") (EVar "name")) (EVar "loc")) (EVar "names")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "threadFix") (EVar "facts")) (EVar "prog")) (EVar "g")) (EVar "shared")) (EVar "names")) (EVar "calls")))))) (EListLit)))))))
(DTypeSig false "clauseThreaded" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "Clause") (TyApp (TyCon "List") (TyCon "Threaded"))))))
(DFunDef false "clauseThreaded" ((PVar "scopes") (PVar "name") (PCon "Clause" PWild (PVar "ps") (PVar "body"))) (EIf (EBinOp "||" (EBinOp "<" (EApp (EVar "listLen") (EVar "ps")) (ELit (LInt 2))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "name")) (EVar "body")))) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "selfCalls") (EVar "scopes")) (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "calls") () (EListLit (EApp (EApp (EApp (EVar "Threaded") (EVar "ps")) (EApp (EApp (EVar "filterList") (EApp (EVar "unchangedIn") (EVar "calls"))) (ERangeList (ELit (LInt 0)) (EBinOp "-" (EApp (EVar "listLen") (EVar "ps")) (ELit (LInt 1))) true))) (EVar "calls"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "threadedCalls" (TyFun (TyCon "Threaded") (TyApp (TyCon "List") (TyCon "SelfCall"))))
(DFunDef false "threadedCalls" ((PCon "Threaded" PWild PWild (PVar "calls"))) (EVar "calls"))
(DTypeSig false "inAll" (TyFun (TyApp (TyCon "List") (TyCon "Threaded")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "inAll" ((PVar "ts") (PVar "i")) (EApp (EApp (EVar "allList") (ELam ((PVar "t")) (EApp (EApp (EVar "hasPosition") (EVar "i")) (EVar "t")))) (EVar "ts")))
(DTypeSig false "hasPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Threaded") (TyCon "Bool"))))
(DFunDef false "hasPosition" ((PVar "i") (PCon "Threaded" PWild (PVar "positions") PWild)) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "i")))) (EVar "positions")))
(DTypeSig false "unchangedIn" (TyFun (TyApp (TyCon "List") (TyCon "SelfCall")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "unchangedIn" ((PVar "calls") (PVar "i")) (EApp (EApp (EVar "allList") (EApp (EVar "callKeeps") (EVar "i"))) (EVar "calls")))
(DTypeSig false "callKeeps" (TyFun (TyCon "Int") (TyFun (TyCon "SelfCall") (TyCon "Bool"))))
(DFunDef false "callKeeps" ((PVar "i") (PCon "SelfCall" PWild PWild (PVar "roles"))) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "roles")) (arm (PCon "Some" (PCon "Unchanged" (PVar "j"))) () (EBinOp "==" (EVar "j") (EVar "i"))) (arm PWild () (EVar "False"))))
(DTypeSig false "paramName" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "paramName" ((PVar "ps") (PVar "i")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "ps")) (arm (PCon "Some" (PCon "PVar" (PVar "n") PWild PWild)) () (EVar "n")) (arm (PCon "Some" (PCon "PAs" (PVar "n") PWild PWild PWild)) () (EVar "n")) (arm PWild () (ELit (LString "_")))))
(DTypeSig false "report" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding"))))))
(DFunDef false "report" ((PVar "name") (PVar "loc") (PVar "names") (PVar "fix")) (EBlock (DoLet false false (PVar "listed") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "quoted")) (EVar "names")))) (DoExpr (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameThreadedInvariant")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` passes "))) (EApp (EVar "display") (EVar "listed"))) (ELit (LString " through every self-call unchanged: close over them in a where-local `go`")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))))
(DTypeSig false "quoted" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoted" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`"))))
(DTypeSig false "threadFix" (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Group") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "SelfCall")) (TyApp (TyCon "Option") (TyCon "Fix")))))))))
(DFunDef false "threadFix" ((PVar "facts") (PVar "prog") (PCon "Group" (PVar "name") PWild (PVar "clauses") (PVar "next")) (PVar "shared") (PVar "names") (PVar "calls")) (EApp (EApp (EVar "andThen") (EApp (EVar "clauseHead") (EVar "clauses"))) (ELam ((PVar "first")) (ELet false (PVar "ls") (EApp (EVar "factLines") (EVar "facts")) (ELet false (PVar "plan") (ERecordCreate "Plan" ((fa "plLines" (EVar "ls")) (fa "plName" (EVar "name")) (fa "plArity" (EApp (EVar "listLen") (EApp (EVar "clausePats") (EVar "first")))) (fa "plShared" (EVar "shared")) (fa "plNames" (EVar "names")) (fa "plCalls" (EVar "calls")) (fa "plBound" (EApp (EVar "localBoundNames") (EApp (EApp (EVar "filterList") (EApp (EVar "definesName") (EVar "name"))) (EVar "prog")))))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "traverse") (EApp (EVar "clauseSpan") (EVar "plan"))) (EApp (EApp (EVar "withBounds") (EApp (EApp (EVar "lineCount") (EVar "ls")) (EVar "next"))) (EVar "clauses")))) (ELam ((PVar "spans")) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EApp (EApp (EVar "allList") (EApp (EVar "spanFits") (EVar "plan"))) (EVar "spans")))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EApp (EApp (EVar "allList") (EApp (EApp (EVar "usedBeyondCalls") (EVar "plan")) (EVar "spans"))) (EVar "names")))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "sp")) (EApp (EApp (EVar "buildsModuloCons") (EVar "plan")) (EFieldAccess (EVar "sp") "spBody")))) (EVar "spans"))))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EApp (EApp (EVar "allList") (ELam ((PVar "sp")) (EApp (EApp (EVar "recordTargetsFit") (EVar "plan")) (EFieldAccess (EVar "sp") "spBody")))) (EVar "spans")))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "sp")) (EApp (EApp (EVar "armGuardReadsInvariant") (EVar "plan")) (EFieldAccess (EVar "sp") "spBody")))) (EVar "spans"))))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EApp (EApp (EVar "signatureFits") (EVar "plan")) (EVar "prog")))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "whereMerge") (EVar "plan")) (EVar "spans"))) (ELam ((PVar "merge")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "rewriteEdits") (EVar "plan")) (EVar "spans")) (EVar "merge"))) (ELam ((PVar "edits")) (EApp (EVar "Some") (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "Unsafe")) (fa "fixEdits" (EVar "edits")) (fa "fixMessage" (ELit (LString "close over the invariant parameters in a where-local `go`")))))))))))))))))))))))))))))
(DTypeSig false "clauseHead" (TyFun (TyApp (TyCon "List") (TyCon "Clause")) (TyApp (TyCon "Option") (TyCon "Clause"))))
(DFunDef false "clauseHead" ((PCons (PVar "c") PWild)) (EApp (EVar "Some") (EVar "c")))
(DFunDef false "clauseHead" ((PList)) (EVar "None"))
(DTypeSig false "clausePats" (TyFun (TyCon "Clause") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "clausePats" ((PCon "Clause" PWild (PVar "ps") PWild)) (EVar "ps"))
(DTypeSig false "definesName" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "definesName" ((PVar "name") (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild)) (EBinOp "==" (EVar "n") (EVar "name")))
(DFunDef false "definesName" (PWild PWild) (EVar "False"))
(DData Private "Plan" () ((variant "Plan" (ConNamed (field "plLines" (TyApp (TyCon "Array") (TyCon "String"))) (field "plName" (TyCon "String")) (field "plArity" (TyCon "Int")) (field "plShared" (TyApp (TyCon "List") (TyCon "Int"))) (field "plNames" (TyApp (TyCon "List") (TyCon "String"))) (field "plCalls" (TyApp (TyCon "List") (TyCon "SelfCall"))) (field "plBound" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Private "Span" () ((variant "Span" (ConNamed (field "spFirst" (TyCon "Int")) (field "spLast" (TyCon "Int")) (field "spPats" (TyApp (TyCon "List") (TyCon "Pat"))) (field "spBody" (TyCon "Expr")) (field "spAtoms" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))) ())
(DTypeSig false "lineCount" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lineCount" ((PVar "ls") (PVar "next")) (EIf (EBinOp ">" (EVar "next") (ELit (LInt 0))) (EVar "next") (EBinOp "+" (EApp (EVar "arrayLength") (EVar "ls")) (ELit (LInt 1)))))
(DTypeSig false "withBounds" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Clause")) (TyApp (TyCon "List") (TyTuple (TyCon "Clause") (TyCon "Int"))))))
(DFunDef false "withBounds" ((PVar "bound") (PVar "cs0")) (ELetGroup ((lgb "go" (clause ((PList)) (EListLit)) (clause ((PList (PVar "c"))) (EListLit (ETuple (EVar "c") (EVar "bound")))) (clause ((PCons (PVar "c") (PAs "rest" (PCons (PCon "Clause" (PVar "l") PWild PWild) PWild)))) (EBinOp "::" (ETuple (EVar "c") (EVar "l")) (EApp (EVar "go") (EVar "rest")))))) (EApp (EVar "go") (EVar "cs0"))))
(DTypeSig false "clauseSpan" (TyFun (TyCon "Plan") (TyFun (TyTuple (TyCon "Clause") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Span")))))
(DFunDef false "clauseSpan" ((PVar "plan") (PTuple (PCon "Clause" (PVar "l") (PVar "ps") (PVar "body")) (PVar "bound"))) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EBinOp ">" (EVar "l") (ELit (LInt 0))))) (ELam (PWild) (ELet false (PVar "text") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EApp (EApp (EVar "startsWith") (EBinOp "++" (EFieldAccess (EVar "plan") "plName") (ELit (LString " ")))) (EVar "text")))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "headAtoms") (EVar "text")) (EApp (EVar "stringLength") (EFieldAccess (EVar "plan") "plName")))) (ELam ((PVar "atoms")) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "atoms")) (EApp (EVar "listLen") (EVar "ps"))) (EBinOp "==" (EApp (EVar "listLen") (EVar "ps")) (EFieldAccess (EVar "plan") "plArity"))))) (ELam (PWild) (EApp (EVar "Some") (ERecordCreate "Span" ((fa "spFirst" (EVar "l")) (fa "spLast" (EApp (EApp (EApp (EVar "lastCode") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")) (EBinOp "-" (EVar "bound") (ELit (LInt 1))))) (fa "spPats" (EVar "ps")) (fa "spBody" (EVar "body")) (fa "spAtoms" (EVar "atoms")))))))))))))))
(DTypeSig false "lineText" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "lineText" ((PVar "ls") (PVar "n")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "arrayGet") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "ls"))))
(DTypeSig false "isCode" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isCode" ((PVar "s")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "trim") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp "/=" (EVar "t") (ELit (LString ""))) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "t")))))))
(DTypeSig false "indentAt" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "indentAt" ((PVar "ls") (PVar "n")) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "lineText") (EVar "ls")) (EVar "n"))) (DoExpr (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EApp (EVar "trimLeft") (EVar "s")))))))
(DTypeSig false "lastCode" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lastCode" ((PVar "ls") (PVar "lo") (PVar "hi0")) (ELetGroup ((lgb "go" (clause ((PVar "hi")) (EIf (EBinOp "<=" (EVar "hi") (EVar "lo")) (EVar "lo") (EIf (EApp (EVar "isCode") (EApp (EApp (EVar "lineText") (EVar "ls")) (EVar "hi"))) (EVar "hi") (EIf (EVar "otherwise") (EApp (EVar "go") (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))) (EApp (EVar "go") (EVar "hi0"))))
(DTypeSig false "headAtoms" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "headAtoms" ((PVar "text") (PVar "start")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "text"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomsFrom") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "start")) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EListLit)))))
(DTypeSig false "headAtomsFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "headAtomsFrom" ((PVar "cs") (PVar "n") (PVar "i") (PVar "depth") (PVar "from") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EIf (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "closed") (EVar "from")) (EVar "i")) (EVar "acc")))) (EVar "None")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomStep") (EVar "cs")) (EVar "n")) (EVar "i")) (EVar "depth")) (EVar "from")) (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "headAtomStep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "headAtomStep" ((PVar "cs") (PVar "n") (PVar "i") (PVar "depth") (PVar "from") (PVar "acc") (PVar "c")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "="))) (EBinOp "==" (EVar "c") (ELit (LChar "|"))))) (EIf (EBinOp ">=" (EVar "from") (ELit (LInt 0))) (EVar "None") (EApp (EVar "Some") (EApp (EVar "reverse") (EVar "acc")))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "==" (EVar "c") (ELit (LChar " ")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomsFrom") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "closed") (EVar "from")) (EVar "i")) (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomsFrom") (EVar "cs")) (EVar "n")) (EApp (EApp (EApp (EVar "stringLitEnd") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EVar "depth")) (EApp (EApp (EVar "opened") (EVar "from")) (EVar "i"))) (EVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "-"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "-")))) (EVar "None") (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "'"))) (EApp (EVar "not") (EBinOp "&&" (EBinOp ">" (EVar "i") (ELit (LInt 0))) (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "cs")))))) (EVar "None") (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "("))) (EBinOp "==" (EVar "c") (ELit (LChar "[")))) (EBinOp "==" (EVar "c") (ELit (LChar "{")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomsFrom") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EApp (EApp (EVar "opened") (EVar "from")) (EVar "i"))) (EVar "acc")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar ")"))) (EBinOp "==" (EVar "c") (ELit (LChar "]")))) (EBinOp "==" (EVar "c") (ELit (LChar "}")))) (EIf (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomsFrom") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "from")) (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomsFrom") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EApp (EVar "opened") (EVar "from")) (EVar "i"))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "stringLitEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "stringLitEnd" ((PVar "cs") (PVar "n") (PVar "j0")) (ELetGroup ((lgb "go" (clause ((PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EVar "n")) (EVar "n") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "cs")) (ELit (LChar "\\"))) (EApp (EVar "go") (EBinOp "+" (EVar "j") (ELit (LInt 2)))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "cs")) (ELit (LChar "\""))) (EBinOp "+" (EVar "j") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EVar "go") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))) (EApp (EVar "go") (EVar "j0"))))
(DTypeSig false "closed" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "closed" ((PVar "from") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "from") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "from") (EVar "i")) (EVar "acc")) (EVar "acc")))
(DTypeSig false "opened" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "opened" ((PVar "from") (PVar "i")) (EIf (EBinOp ">=" (EVar "from") (ELit (LInt 0))) (EVar "from") (EVar "i")))
(DTypeSig false "atomText" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "atomText" ((PVar "plan") (PVar "sp") (PVar "i")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EFieldAccess (EVar "sp") "spAtoms")) (arm (PCon "Some" (PTuple (PVar "a") (PVar "b"))) () (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EFieldAccess (EVar "sp") "spFirst")))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "headEnd" (TyFun (TyCon "Span") (TyCon "Int")))
(DFunDef false "headEnd" ((PVar "sp")) (EMatch (EApp (EVar "last") (EFieldAccess (EVar "sp") "spAtoms")) (arm (PCon "Some" (PTuple PWild (PVar "b"))) () (EVar "b")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "spanFits" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyCon "Bool"))))
(DFunDef false "spanFits" ((PVar "plan") (PVar "sp")) (EBinOp "&&" (EApp (EApp (EVar "allList") (EApp (EApp (EVar "invariantFits") (EVar "plan")) (EVar "sp"))) (EApp (EApp (EVar "zip") (EFieldAccess (EVar "plan") "plShared")) (EFieldAccess (EVar "plan") "plNames"))) (EApp (EApp (EVar "allList") (EApp (EApp (EVar "lineFits") (EVar "plan")) (EVar "sp"))) (ERangeList (EFieldAccess (EVar "sp") "spFirst") (EFieldAccess (EVar "sp") "spLast") true))))
(DTypeSig false "invariantFits" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "invariantFits" ((PVar "plan") (PVar "sp") (PTuple (PVar "i") (PVar "v"))) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EFieldAccess (EVar "sp") "spPats")) (arm (PCon "Some" (PCon "PVar" (PVar "x") PWild PWild)) () (EBinOp "&&" (EBinOp "==" (EApp (EApp (EApp (EVar "atomText") (EVar "plan")) (EVar "sp")) (EVar "i")) (EVar "x")) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "v")) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "_"))) (EVar "x")) (EApp (EVar "not") (EBinOp "||" (EApp (EApp (EVar "mentionsVar") (EVar "v")) (EFieldAccess (EVar "sp") "spBody")) (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EFieldAccess (EVar "sp") "spBody")))))))) (arm (PCon "Some" (PCon "PWild")) () (EBinOp "&&" (EBinOp "==" (EApp (EApp (EApp (EVar "atomText") (EVar "plan")) (EVar "sp")) (EVar "i")) (ELit (LString "_"))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "v")) (EFieldAccess (EVar "sp") "spBody"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "lineFits" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "lineFits" ((PVar "plan") (PVar "sp") (PVar "l")) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l"))) (DoExpr (EBinOp "&&" (EApp (EVar "not") (EBinOp "||" (EApp (EApp (EVar "contains") (ELit (LString "\"\"\""))) (EVar "s")) (EApp (EApp (EVar "contains") (ELit (LString "\t"))) (EVar "s")))) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "l") (EFieldAccess (EVar "sp") "spFirst")) (EApp (EVar "not") (EApp (EVar "isCode") (EVar "s")))) (EBinOp ">" (EApp (EApp (EVar "indentAt") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")) (ELit (LInt 0))))))))
(DTypeSig false "usedBeyondCalls" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "usedBeyondCalls" ((PVar "plan") (PVar "spans") (PVar "v")) (EBinOp ">" (EApp (EVar "sum") (EApp (EApp (EVar "map") (ELam ((PVar "sp")) (EApp (EApp (EVar "countVar") (EVar "v")) (EFieldAccess (EVar "sp") "spBody")))) (EVar "spans"))) (EApp (EVar "listLen") (EFieldAccess (EVar "plan") "plCalls"))))
(DTypeSig false "countVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Int"))))
(DFunDef false "countVar" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EIf (EBinOp "==" (EVar "w") (EVar "x")) (ELit (LInt 1)) (ELit (LInt 0)))) (arm (PVar "e2") () (EApp (EVar "sum") (EApp (EApp (EVar "map") (EApp (EVar "countVar") (EVar "x"))) (EApp (EVar "childExprs") (EVar "e2")))))))
(DTypeSig false "buildsModuloCons" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "buildsModuloCons" ((PVar "plan") (PVar "e")) (EBinOp "||" (EApp (EApp (EVar "consTail") (EVar "plan")) (EApp (EVar "unwrapLoc") (EVar "e"))) (EApp (EApp (EVar "anyList") (EApp (EVar "buildsModuloCons") (EVar "plan"))) (EApp (EVar "childExprs") (EApp (EVar "unwrapLoc") (EVar "e"))))))
(DTypeSig false "consTail" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "consTail" ((PVar "plan") (PCon "EBinOp" (PLit (LString "::")) PWild (PVar "tl") PWild)) (EApp (EApp (EVar "isSelfApp") (EVar "plan")) (EVar "tl")))
(DFunDef false "consTail" ((PVar "plan") (PAs "e" (PCon "EApp" PWild PWild))) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EBinOp "&&" (EApp (EVar "isCtorHead") (EVar "hd")) (EMatch (EApp (EVar "last") (EVar "args")) (arm (PCon "Some" (PVar "a")) () (EApp (EApp (EVar "isSelfApp") (EVar "plan")) (EVar "a"))) (arm (PCon "None") () (EVar "False")))))))
(DFunDef false "consTail" (PWild PWild) (EVar "False"))
(DTypeSig false "isCtorHead" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isCtorHead" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "c")) () (EApp (EVar "isCtorName") (EVar "c"))) (arm PWild () (EVar "False"))))
(DTypeSig false "isSelfApp" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isSelfApp" ((PVar "plan") (PVar "e")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EFieldAccess (EVar "plan") "plName")) (EVar "hd")) (EBinOp "==" (EApp (EVar "listLen") (EVar "args")) (EFieldAccess (EVar "plan") "plArity"))))))
(DTypeSig false "armGuardReadsInvariant" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "armGuardReadsInvariant" ((PVar "plan") (PVar "e")) (EBinOp "||" (EApp (EApp (EVar "armGuards") (EVar "plan")) (EApp (EVar "unwrapLoc") (EVar "e"))) (EApp (EApp (EVar "anyList") (EApp (EVar "armGuardReadsInvariant") (EVar "plan"))) (EApp (EVar "childExprs") (EApp (EVar "unwrapLoc") (EVar "e"))))))
(DTypeSig false "armGuards" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "armGuards" ((PVar "plan") (PCon "EMatch" PWild (PVar "arms"))) (EApp (EApp (EVar "anyList") (EApp (EVar "armReads") (EVar "plan"))) (EVar "arms")))
(DFunDef false "armGuards" (PWild PWild) (EVar "False"))
(DTypeSig false "armReads" (TyFun (TyCon "Plan") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armReads" ((PVar "plan") (PCon "Arm" PWild (PVar "gs") PWild)) (EApp (EApp (EVar "anyList") (EApp (EVar "guardReads") (EVar "plan"))) (EVar "gs")))
(DTypeSig false "guardReads" (TyFun (TyCon "Plan") (TyFun (TyCon "Guard") (TyCon "Bool"))))
(DFunDef false "guardReads" ((PVar "plan") (PCon "GBool" (PVar "g"))) (EApp (EApp (EVar "readsInvariant") (EVar "plan")) (EVar "g")))
(DFunDef false "guardReads" ((PVar "plan") (PCon "GBind" PWild (PVar "g"))) (EApp (EApp (EVar "readsInvariant") (EVar "plan")) (EVar "g")))
(DTypeSig false "readsInvariant" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "readsInvariant" ((PVar "plan") (PVar "g")) (EApp (EApp (EVar "anyList") (ELam ((PVar "n")) (EApp (EApp (EVar "mentionsVar") (EVar "n")) (EVar "g")))) (EFieldAccess (EVar "plan") "plNames")))
(DTypeSig false "recordTargetsFit" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "recordTargetsFit" ((PVar "plan") (PVar "e")) (EBinOp "&&" (EApp (EApp (EVar "targetFits") (EVar "plan")) (EApp (EVar "unwrapLoc") (EVar "e"))) (EApp (EApp (EVar "allList") (EApp (EVar "recordTargetsFit") (EVar "plan"))) (EApp (EVar "childExprs") (EApp (EVar "unwrapLoc") (EVar "e"))))))
(DTypeSig false "targetFits" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "targetFits" ((PVar "plan") (PCon "EFieldAccess" (PVar "r") PWild PWild)) (EApp (EApp (EVar "recordRootFits") (EVar "plan")) (EVar "r")))
(DFunDef false "targetFits" ((PVar "plan") (PCon "ERecordUpdate" (PVar "r") PWild PWild)) (EApp (EApp (EVar "recordRootFits") (EVar "plan")) (EVar "r")))
(DFunDef false "targetFits" (PWild PWild) (EVar "True"))
(DTypeSig false "recordRootFits" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "recordRootFits" ((PVar "plan") (PVar "r")) (EMatch (EApp (EVar "unwrapLoc") (EVar "r")) (arm (PCon "EFieldAccess" (PVar "inner") PWild PWild) () (EApp (EApp (EVar "recordRootFits") (EVar "plan")) (EVar "inner"))) (arm (PCon "EVar" (PVar "n")) () (EBinOp "||" (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EFieldAccess (EVar "plan") "plNames")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EFieldAccess (EVar "plan") "plBound"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "signatureFits" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "signatureFits" ((PVar "plan") (PVar "prog")) (EMatch (EApp (EApp (EVar "findMap") (EApp (EVar "sigNamed") (EFieldAccess (EVar "plan") "plName"))) (EVar "prog")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "t")) () (EBinOp "&&" (EApp (EApp (EApp (EVar "tyEvery") (ELam (PWild) (EVar "True"))) (EVar "isEmpty")) (EVar "t")) (EApp (EApp (EVar "constraintsHeld") (EVar "plan")) (EVar "t"))))))
(DTypeSig false "constraintsHeld" (TyFun (TyCon "Plan") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "constraintsHeld" ((PVar "plan") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "doms") (EApp (EApp (EVar "domains") (EFieldAccess (EVar "plan") "plArity")) (EVar "t"))) (DoLet false false (PVar "held") (EApp (EApp (EVar "flatMap") (ELam ((PVar "i")) (EApp (EVar "toList") (EApp (EApp (EVar "get") (EVar "i")) (EVar "doms"))))) (EFieldAccess (EVar "plan") "plShared"))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "doms")) (EFieldAccess (EVar "plan") "plArity")) (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EApp (EApp (EVar "allList") (EApp (EApp (EVar "tyEvery") (ELam ((PVar "v")) (EApp (EApp (EVar "anyList") (EApp (EVar "tyMentions") (EVar "v"))) (EVar "held")))) (ELam (PWild) (EVar "True")))) (EFieldAccess (EVar "c") "constraintArgs")))) (EVar "cs"))))))
(DFunDef false "constraintsHeld" (PWild PWild) (EVar "True"))
(DTypeSig false "sigNamed" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Ty")))))
(DFunDef false "sigNamed" ((PVar "n") (PCon "DTypeSig" PWild (PVar "m") (PVar "t") PWild)) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "Some") (EVar "t")) (EVar "None")))
(DFunDef false "sigNamed" (PWild PWild) (EVar "None"))
(DTypeSig false "domains" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "domains" ((PVar "k") (PCon "TyFun" (PVar "a") (PVar "b"))) (EIf (EBinOp ">" (EVar "k") (ELit (LInt 0))) (EBinOp "::" (EVar "a") (EApp (EApp (EVar "domains") (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "domains" (PWild PWild) (EListLit))
(DTypeSig false "tyMentions" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "tyMentions" ((PVar "v") (PVar "t")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "tyEvery") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "v")))) (ELam (PWild) (EVar "True"))) (EVar "t"))))
(DTypeSig false "tyEvery" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")) (TyFun (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "tyEvery" ((PVar "ok") (PVar "okTail") (PVar "t0")) (ELetGroup ((lgb "go" (clause ((PCon "TyVar" (PVar "v"))) (EApp (EVar "ok") (EVar "v"))) (clause ((PCon "TyApp" (PVar "f") (PVar "x"))) (EBinOp "&&" (EApp (EVar "go") (EVar "f")) (EApp (EVar "go") (EVar "x")))) (clause ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "&&" (EApp (EVar "go") (EVar "a")) (EApp (EVar "go") (EVar "b")))) (clause ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "allList") (EVar "go")) (EVar "ts"))) (clause ((PCon "TyEffect" PWild (PVar "tl") (PVar "t"))) (EBinOp "&&" (EApp (EVar "okTail") (EVar "tl")) (EApp (EVar "go") (EVar "t")))) (clause ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "&&" (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EApp (EApp (EVar "allList") (EVar "go")) (EFieldAccess (EVar "c") "constraintArgs")))) (EVar "cs")) (EApp (EVar "go") (EVar "t")))) (clause ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "go") (EVar "t"))) (clause ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "go") (EVar "t"))) (clause ((PCon "TyRow" PWild (PVar "tl") PWild)) (EApp (EVar "okTail") (EVar "tl"))) (clause ((PRec "TyCon" ((rf "tyConName" PWild)) false)) (EVar "True")) (clause ((PCon "TyAuth" PWild PWild)) (EVar "True")))) (EApp (EVar "go") (EVar "t0"))))
(DTypeSig false "whereMerge" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyApp (TyCon "Option") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "whereMerge" ((PVar "plan") (PVar "spans")) (EMatch (EApp (EApp (EVar "flatMap") (ELam ((PVar "sp")) (EApp (EApp (EVar "filterList") (EApp (EVar "hasWhere") (EVar "plan"))) (ERangeList (EFieldAccess (EVar "sp") "spFirst") (EFieldAccess (EVar "sp") "spLast") true)))) (EVar "spans")) (arm (PList) () (EApp (EVar "Some") (EVar "None"))) (arm (PList (PVar "w")) () (EMatch (EVar "spans") (arm (PList (PVar "sp")) () (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "trim") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "w"))) (ELit (LString "where"))) (EBinOp "==" (EApp (EApp (EVar "indentAt") (EFieldAccess (EVar "plan") "plLines")) (EVar "w")) (ELit (LInt 2)))) (EApp (EApp (EApp (EVar "bindingsFit") (EVar "plan")) (EVar "sp")) (EVar "w"))) (EApp (EVar "Some") (EApp (EVar "Some") (EVar "w"))) (EVar "None"))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "hasWhere" (TyFun (TyCon "Plan") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "hasWhere" ((PVar "plan") (PVar "l")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LString "where"))))) (EApp (EVar "identifiersIn") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")))))
(DTypeSig false "bindingsFit" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "bindingsFit" ((PVar "plan") (PVar "sp") (PVar "w")) (EMatch (EApp (EVar "unwrapLoc") (EFieldAccess (EVar "sp") "spBody")) (arm (PCon "ELetGroup" (PVar "binds") PWild) () (EBlock (DoLet false false (PVar "changing") (EApp (EApp (EVar "flatMap") (EVar "patBoundNames")) (EApp (EApp (EVar "restPats") (EVar "plan")) (EVar "sp")))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "allList") (ELam ((PVar "b")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "n")) (EApp (EApp (EVar "bindMentions") (EVar "n")) (EVar "b")))) (EVar "changing"))))) (EVar "binds")) (EApp (EApp (EVar "allList") (ELam ((PVar "l")) (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isCode") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")))) (EBinOp ">=" (EApp (EApp (EVar "indentAt") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")) (ELit (LInt 4)))))) (ERangeList (EBinOp "+" (EVar "w") (ELit (LInt 1))) (EFieldAccess (EVar "sp") "spLast") true)))))) (arm PWild () (EVar "False"))))
(DTypeSig false "bindMentions" (TyFun (TyCon "String") (TyFun (TyCon "LetBind") (TyCon "Bool"))))
(DFunDef false "bindMentions" ((PVar "n") (PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "anyList") (ELam ((PCon "FunClause" PWild (PVar "body"))) (EApp (EApp (EVar "mentionsVar") (EVar "n")) (EVar "body")))) (EVar "clauses")))
(DData Private "Cut" () ((variant "Cut" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "String")))) ())
(DTypeSig false "restOf" (TyFun (TyCon "Plan") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "restOf" ((PVar "plan")) (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "i")))) (EFieldAccess (EVar "plan") "plShared"))))) (ERangeList (ELit (LInt 0)) (EBinOp "-" (EFieldAccess (EVar "plan") "plArity") (ELit (LInt 1))) true)))
(DTypeSig false "restPats" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "restPats" ((PVar "plan") (PVar "sp")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "i")) (EApp (EVar "toList") (EApp (EApp (EVar "get") (EVar "i")) (EFieldAccess (EVar "sp") "spPats"))))) (EApp (EVar "restOf") (EVar "plan"))))
(DTypeSig false "rewriteEdits" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "FixEdit")))))))
(DFunDef false "rewriteEdits" ((PVar "plan") (PVar "spans") (PVar "merge")) (ELet false (PVar "taken") (EApp (EApp (EVar "flatMap") (ELam ((PVar "sp")) (EApp (EApp (EVar "regionWords") (EVar "plan")) (EVar "sp")))) (EVar "spans")) (ELet false (PVar "goName") (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LString "go"))))) (EVar "taken")) (EApp (EApp (EApp (EVar "freshFrom") (EVar "taken")) (ELit (LString "go"))) (ELit (LInt 1))) (ELit (LString "go"))) (ELet false (PVar "fresh") (EApp (EApp (EApp (EApp (EVar "outerNames") (EVar "plan")) (EVar "spans")) (EVar "taken")) (EVar "goName")) (ELet false (PVar "goArgs") (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "fresh")) (ELit (LInt 0))) (ELit (LString " ()")) (ELit (LString ""))) (ELet false (PVar "callHead") (EBinOp "++" (EVar "goName") (EVar "goArgs")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "traverse") (EApp (EApp (EVar "callPieces") (EVar "plan")) (EVar "callHead"))) (EFieldAccess (EVar "plan") "plCalls"))) (ELam ((PVar "pieces")) (ELet false (PVar "cuts") (EApp (EApp (EVar "flatMap") (EVar "fst")) (EVar "pieces")) (ELet false (PVar "dropped") (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "pieces")) (EApp (EVar "toList") (EVar "merge"))) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EApp (EApp (EVar "allList") (EApp (EVar "cutInside") (EVar "spans"))) (EVar "cuts")))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "traverse") (EApp (EApp (EApp (EApp (EVar "lineEdits") (EVar "plan")) (EVar "spans")) (EVar "dropped")) (EVar "merge"))) (EApp (EVar "cutLines") (EVar "cuts")))) (ELam ((PVar "lineCuts")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "traverse") (EApp (EApp (EApp (EApp (EApp (EVar "headEdit") (EVar "plan")) (EVar "dropped")) (EVar "merge")) (EVar "goName")) (EVar "fresh"))) (EApp (EVar "indexedSpans") (EVar "spans")))) (ELam ((PVar "heads")) (ELet false (PVar "shifts") (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "shiftEdits") (EVar "plan")) (EVar "dropped")) (EVar "merge"))) (EVar "spans")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "heads") (EApp (EApp (EVar "flatMap") (ELam ((PVar "es")) (EVar "es"))) (EVar "lineCuts"))) (EVar "shifts")) (EApp (EApp (EVar "map") (EApp (EVar "dropLine") (EVar "plan"))) (EVar "dropped")))))))))))))))))))))
(DTypeSig false "indexedSpans" (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Span")))))
(DFunDef false "indexedSpans" ((PVar "spans")) (EApp (EApp (EVar "zip") (ERangeList (ELit (LInt 0)) (EBinOp "-" (EApp (EVar "listLen") (EVar "spans")) (ELit (LInt 1))) true)) (EVar "spans")))
(DTypeSig false "regionWords" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "regionWords" ((PVar "plan") (PVar "sp")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "l")) (EApp (EVar "identifiersIn") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l"))))) (ERangeList (EFieldAccess (EVar "sp") "spFirst") (EFieldAccess (EVar "sp") "spLast") true)))
(DTypeSig false "identifiersIn" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "identifiersIn" ((PVar "s")) (ELetGroup ((lgb "cs" (clause () (EApp (EVar "stringToChars") (EVar "s")))) (lgb "n" (clause () (EApp (EVar "arrayLength") (EVar "cs")))) (lgb "go" (clause ((PVar "i") (PVar "from") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "word") (EVar "from")) (EVar "i")) (EVar "acc"))) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EVar "opened") (EVar "from")) (EVar "i"))) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "word") (EVar "from")) (EVar "i")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (lgb "word" (clause ((PVar "from") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "from") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "from")) (EVar "i")) (EVar "s")) (EVar "acc")) (EVar "acc"))))) (EApp (EApp (EApp (EVar "go") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EListLit))))
(DTypeSig false "freshFrom" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "freshFrom" ((PVar "taken") (PVar "base") (PVar "k0")) (ELetGroup ((lgb "go" (clause ((PVar "k")) (EBlock (DoLet false false (PVar "candidate") (EBinOp "++" (EVar "base") (EApp (EVar "intToString") (EVar "k")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "candidate")))) (EVar "taken")) (EApp (EVar "go") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "candidate"))))))) (EApp (EVar "go") (EVar "k0"))))
(DTypeSig false "outerNames" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "outerNames" ((PVar "plan") (PVar "spans") (PVar "taken") (PVar "goName")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "used") (PCons (PVar "i") (PVar "is"))) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EApp (EVar "freshFrom") (EVar "used")) (EApp (EApp (EVar "baseName") (EVar "spans")) (EVar "i"))) (ELit (LInt 0)))) (DoExpr (EBinOp "::" (EVar "n") (EApp (EApp (EVar "go") (EBinOp "::" (EVar "n") (EVar "used"))) (EVar "is")))))))) (EApp (EApp (EVar "go") (EBinOp "::" (EVar "goName") (EVar "taken"))) (EApp (EVar "restOf") (EVar "plan")))))
(DTypeSig false "baseName" (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "baseName" ((PVar "spans") (PVar "i")) (EMatch (EApp (EApp (EVar "findMap") (ELam ((PVar "sp")) (EApp (EApp (EVar "namedAt") (EVar "sp")) (EVar "i")))) (EVar "spans")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "stripDigits") (EVar "n"))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "sp")) (EApp (EApp (EVar "listLike") (EVar "sp")) (EVar "i")))) (EVar "spans")) (ELit (LString "xs")) (ELit (LString "x"))))))
(DTypeSig false "namedAt" (TyFun (TyCon "Span") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "namedAt" ((PVar "sp") (PVar "i")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EFieldAccess (EVar "sp") "spPats")) (arm (PCon "Some" (PCon "PVar" (PVar "n") PWild PWild)) () (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "_"))) (EVar "n")) (EVar "None") (EApp (EVar "Some") (EVar "n")))) (arm (PCon "Some" (PCon "PAs" (PVar "n") PWild PWild PWild)) () (EApp (EVar "Some") (EVar "n"))) (arm PWild () (EVar "None"))))
(DTypeSig false "listLike" (TyFun (TyCon "Span") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "listLike" ((PVar "sp") (PVar "i")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EFieldAccess (EVar "sp") "spPats")) (arm (PCon "Some" (PCon "PCons" PWild PWild)) () (EVar "True")) (arm (PCon "Some" (PCon "PList" PWild)) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "stripDigits" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripDigits" ((PVar "n")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "toList") (EApp (EVar "stringToChars") (EVar "n")))) (DoLet false false (PVar "kept") (EApp (EVar "reverse") (EApp (EApp (EVar "dropWhile") (ELam ((PVar "c")) (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9")))) (EBinOp "==" (EVar "c") (ELit (LChar "'")))))) (EApp (EVar "reverse") (EVar "cs"))))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "kept")) (ELit (LInt 0))) (ELit (LString "x")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EVar "kept")))))))
(DTypeSig false "callPieces" (TyFun (TyCon "Plan") (TyFun (TyCon "String") (TyFun (TyCon "SelfCall") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Cut")) (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "callPieces" ((PVar "plan") (PVar "callHead") (PCon "SelfCall" PWild (PVar "e") PWild)) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EVar "andThen") (EApp (EVar "varSite") (EVar "hd"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "Loc" PWild (PVar "hl") (PVar "hc") PWild (PVar "hec")) () (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "hc")) (EVar "hec")) (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "hl"))) (EFieldAccess (EVar "plan") "plName")))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "traverse") (EApp (EApp (EVar "argPiece") (EVar "plan")) (EVar "args"))) (EApp (EApp (EVar "zip") (EFieldAccess (EVar "plan") "plShared")) (EFieldAccess (EVar "plan") "plNames")))) (ELam ((PVar "pieces")) (EApp (EVar "Some") (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "Cut") (EVar "hl")) (EVar "hc")) (EVar "hec")) (EVar "callHead")) (EApp (EApp (EVar "flatMap") (EVar "fst")) (EVar "pieces"))) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "pieces")))))))))))))))
(DTypeSig false "argPiece" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Cut")) (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "argPiece" ((PVar "plan") (PVar "args") (PTuple (PVar "i") (PVar "v"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "get") (EVar "i")) (EVar "args"))) (ELam ((PVar "a")) (EApp (EApp (EVar "andThen") (EApp (EVar "varSite") (EVar "a"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "Loc" PWild (PVar "al") (PVar "ac") (PVar "el") (PVar "aec")) () (ELet false (PVar "s") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "al")) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EBinOp "&&" (EBinOp "==" (EVar "el") (EVar "al")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "ac")) (EVar "aec")) (EVar "s")) (EVar "v"))))) (ELam (PWild) (EIf (EBinOp "==" (EApp (EVar "trim") (EVar "s")) (EVar "v")) (EApp (EVar "Some") (ETuple (EListLit) (EListLit (EVar "al")))) (EBlock (DoLet false false (PVar "kept") (EApp (EVar "stringLength") (EApp (EVar "trimRight") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "ac")) (EVar "s"))))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "kept") (ELit (LInt 0))) (EBinOp "<" (EVar "kept") (EVar "ac"))) (EApp (EVar "Some") (ETuple (EListLit (EApp (EApp (EApp (EApp (EVar "Cut") (EVar "al")) (EVar "kept")) (EVar "aec")) (ELit (LString "")))) (EListLit))) (EVar "None")))))))))))))))
(DTypeSig false "cutInside" (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyFun (TyCon "Cut") (TyCon "Bool"))))
(DFunDef false "cutInside" ((PVar "spans") (PCon "Cut" (PVar "l") (PVar "c") PWild PWild)) (EApp (EApp (EVar "anyList") (ELam ((PVar "sp")) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "l") (EFieldAccess (EVar "sp") "spFirst")) (EBinOp "<=" (EVar "l") (EFieldAccess (EVar "sp") "spLast"))) (EBinOp "||" (EBinOp ">" (EVar "l") (EFieldAccess (EVar "sp") "spFirst")) (EBinOp ">=" (EVar "c") (EApp (EVar "headEnd") (EVar "sp"))))))) (EVar "spans")))
(DTypeSig false "cutLine" (TyFun (TyCon "Cut") (TyCon "Int")))
(DFunDef false "cutLine" ((PCon "Cut" (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeSig false "cutStart" (TyFun (TyCon "Cut") (TyCon "Int")))
(DFunDef false "cutStart" ((PCon "Cut" PWild (PVar "c") PWild PWild)) (EVar "c"))
(DTypeSig false "cutKey" (TyFun (TyCon "Cut") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "cutKey" ((PCon "Cut" (PVar "l") (PVar "c") PWild PWild)) (ETuple (EVar "l") (EVar "c")))
(DTypeSig false "cutLines" (TyFun (TyApp (TyCon "List") (TyCon "Cut")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Cut"))))))
(DFunDef false "cutLines" ((PVar "cuts")) (EBlock (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (ELam ((PVar "a") (PVar "b")) (EApp (EApp (EVar "compare") (EApp (EVar "cutKey") (EVar "a"))) (EApp (EVar "cutKey") (EVar "b"))))) (EVar "cuts"))) (DoExpr (EApp (EApp (EApp (EVar "foldRight") (EVar "addCut")) (EListLit)) (EVar "sorted")))))
(DTypeSig false "addCut" (TyFun (TyCon "Cut") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Cut")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Cut")))))))
(DFunDef false "addCut" ((PVar "c") (PCons (PTuple (PVar "l") (PVar "cs")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "l") (EApp (EVar "cutLine") (EVar "c"))) (EBinOp "::" (ETuple (EVar "l") (EBinOp "::" (EVar "c") (EVar "cs"))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "addCut" ((PVar "c") (PVar "groups")) (EBinOp "::" (ETuple (EApp (EVar "cutLine") (EVar "c")) (EListLit (EVar "c"))) (EVar "groups")))
(DTypeSig false "lineEdits" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Cut"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "FixEdit")))))))))
(DFunDef false "lineEdits" ((PVar "plan") (PVar "spans") (PVar "dropped") (PVar "merge") (PTuple (PVar "l") (PVar "cs"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "findMap") (ELam ((PVar "s")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "l") (EFieldAccess (EVar "s") "spFirst")) (EBinOp "<=" (EVar "l") (EFieldAccess (EVar "s") "spLast"))) (EApp (EVar "Some") (EVar "s")) (EVar "None")))) (EVar "spans"))) (ELam ((PVar "sp")) (ELet false (PVar "s") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")) (ELet false (PVar "start") (EMatch (EVar "cs") (arm (PCons (PVar "c") PWild) () (EApp (EVar "cutStart") (EVar "c"))) (arm (PList) () (ELit (LInt 0)))) (ELet false (PVar "below") (EApp (EApp (EApp (EApp (EVar "nextCodeLine") (EVar "plan")) (EVar "dropped")) (EVar "l")) (EApp (EApp (EApp (EVar "limitFor") (EVar "merge")) (EVar "sp")) (EVar "l"))) (ELet false (PVar "pad") (EIf (EBinOp "==" (EVar "l") (EFieldAccess (EVar "sp") "spFirst")) (EApp (EVar "isSome") (EVar "below")) (EBinOp "&&" (EApp (EApp (EVar "movesTokens") (EVar "s")) (EVar "cs")) (EMatch (EVar "below") (arm (PCon "Some" (PVar "b")) () (EBinOp ">=" (EApp (EApp (EVar "indentAt") (EFieldAccess (EVar "plan") "plLines")) (EVar "b")) (EVar "start"))) (arm (PCon "None") () (EVar "False"))))) (EApp (EApp (EVar "traverse") (EApp (EVar "cutEdit") (EVar "pad"))) (EVar "cs")))))))))
(DTypeSig false "movesTokens" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cut")) (TyCon "Bool"))))
(DFunDef false "movesTokens" (PWild (PList)) (EVar "False"))
(DFunDef false "movesTokens" ((PVar "s") (PAs "cs" (PCons PWild (PVar "rest")))) (EBlock (DoLet false false (PVar "ends") (EApp (EApp (EVar "map") (EVar "cutEnd")) (EVar "cs"))) (DoLet false false (PVar "starts") (EBinOp "++" (EApp (EApp (EVar "map") (EVar "cutStart")) (EVar "rest")) (EListLit (EApp (EVar "stringLength") (EVar "s"))))) (DoExpr (EApp (EApp (EVar "anyList") (ELam ((PTuple (PVar "a") (PVar "b"))) (EBinOp "/=" (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EVar "s"))) (ELit (LString ""))))) (EApp (EApp (EVar "zip") (EVar "ends")) (EVar "starts"))))))
(DTypeSig false "cutEnd" (TyFun (TyCon "Cut") (TyCon "Int")))
(DFunDef false "cutEnd" ((PCon "Cut" PWild PWild (PVar "e") PWild)) (EVar "e"))
(DTypeSig false "cutEdit" (TyFun (TyCon "Bool") (TyFun (TyCon "Cut") (TyApp (TyCon "Option") (TyCon "FixEdit")))))
(DFunDef false "cutEdit" ((PVar "pad") (PCon "Cut" (PVar "l") (PVar "c") (PVar "e") (PVar "text"))) (EIf (EApp (EVar "not") (EVar "pad")) (EApp (EVar "Some") (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "l")) (EVar "c")) (EVar "l")) (EVar "e"))) (EVar "text"))) (EIf (EBinOp "<=" (EApp (EVar "stringLength") (EVar "text")) (EBinOp "-" (EVar "e") (EVar "c"))) (EApp (EVar "Some") (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "l")) (EVar "c")) (EVar "l")) (EVar "e"))) (EBinOp "++" (EVar "text") (EApp (EApp (EVar "repeat") (EBinOp "-" (EBinOp "-" (EVar "e") (EVar "c")) (EApp (EVar "stringLength") (EVar "text")))) (ELit (LString " ")))))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "limitFor" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Span") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "limitFor" ((PCon "Some" (PVar "w")) (PVar "sp") (PVar "l")) (EIf (EBinOp "<" (EVar "l") (EVar "w")) (EBinOp "-" (EVar "w") (ELit (LInt 1))) (EFieldAccess (EVar "sp") "spLast")))
(DFunDef false "limitFor" ((PCon "None") (PVar "sp") PWild) (EFieldAccess (EVar "sp") "spLast"))
(DTypeSig false "nextCodeLine" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "nextCodeLine" ((PVar "plan") (PVar "dropped") (PVar "l0") (PVar "limit")) (ELetGroup ((lgb "go" (clause ((PVar "l")) (EIf (EBinOp ">" (EVar "l") (EVar "limit")) (EVar "None") (EIf (EBinOp "||" (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "l")))) (EVar "dropped")) (EApp (EVar "not") (EApp (EVar "isCode") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l"))))) (EApp (EVar "go") (EBinOp "+" (EVar "l") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EVar "Some") (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))) (EApp (EVar "go") (EBinOp "+" (EVar "l0") (ELit (LInt 1))))))
(DTypeSig false "headEdit" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "Int") (TyCon "Span")) (TyApp (TyCon "Option") (TyCon "FixEdit")))))))))
(DFunDef false "headEdit" ((PVar "plan") (PVar "dropped") (PVar "merge") (PVar "goName") (PVar "fresh") (PTuple (PVar "k") (PVar "sp"))) (ELet false (PVar "s") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EFieldAccess (EVar "sp") "spFirst")) (ELet false (PVar "he") (EApp (EVar "headEnd") (EVar "sp")) (ELet false (PVar "changing") (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EBinOp "++" (ELit (LString " ")) (EApp (EApp (EApp (EVar "atomText") (EVar "plan")) (EVar "sp")) (EVar "i"))))) (EApp (EVar "restOf") (EVar "plan"))) (ELet false (PVar "goHead") (EBinOp "++" (EVar "goName") (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "changing")) (ELit (LInt 0))) (ELit (LString " ()")) (EApp (EVar "stringConcat") (EVar "changing")))) (ELet false (PVar "d") (EBinOp "-" (EBinOp "+" (ELit (LInt 4)) (EApp (EVar "stringLength") (EVar "goHead"))) (EVar "he")) (EApp (EApp (EVar "andThen") (EApp (EVar "guard") (EBinOp "<=" (EVar "d") (ELit (LInt 4))))) (ELam (PWild) (ELet false (PVar "post") (EApp (EApp (EApp (EVar "stringSlice") (EVar "he")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (ELet false (PVar "at") (EBinOp "-" (EBinOp "+" (EVar "he") (EApp (EVar "stringLength") (EVar "post"))) (EApp (EVar "stringLength") (EApp (EVar "trimLeft") (EVar "post")))) (ELet false (PVar "lead") (EApp (EVar "trim") (EVar "post")) (ELet false (PVar "below") (EApp (EApp (EApp (EApp (EVar "nextCodeLine") (EVar "plan")) (EVar "dropped")) (EFieldAccess (EVar "sp") "spFirst")) (EApp (EApp (EApp (EVar "limitFor") (EVar "merge")) (EVar "sp")) (EFieldAccess (EVar "sp") "spFirst"))) (ELet false (PVar "pad") (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "lead") (ELit (LString ""))) (EBinOp "/=" (EVar "lead") (ELit (LString "=")))) (EMatch (EVar "below") (arm (PCon "Some" (PVar "b")) () (EBinOp ">" (EBinOp "+" (EApp (EApp (EVar "indentAt") (EFieldAccess (EVar "plan") "plLines")) (EVar "b")) (ELit (LInt 4))) (EBinOp "+" (EVar "at") (EVar "d")))) (arm (PCon "None") () (EVar "False")))) (ELet false (PVar "padding") (EIf (EVar "pad") (EApp (EApp (EVar "repeat") (EBinOp "-" (ELit (LInt 4)) (EVar "d"))) (ELit (LString " "))) (ELit (LString ""))) (ELet false (PVar "prefix") (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EBinOp "++" (EApp (EApp (EApp (EVar "outerLine") (EVar "plan")) (EVar "goName")) (EVar "fresh")) (ELit (LString "\n  where\n    "))) (ELit (LString "    "))) (EApp (EVar "Some") (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EFieldAccess (EVar "sp") "spFirst")) (ELit (LInt 0))) (EFieldAccess (EVar "sp") "spFirst")) (EVar "he"))) (EBinOp "++" (EBinOp "++" (EVar "prefix") (EVar "goHead")) (EVar "padding")))))))))))))))))))
(DTypeSig false "outerLine" (TyFun (TyCon "Plan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "outerLine" ((PVar "plan") (PVar "goName") (PVar "fresh")) (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "outerParams") (EVar "plan")) (EVar "fresh"))) (DoLet false false (PVar "args") (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "fresh")) (ELit (LInt 0))) (ELit (LString " ()")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString " ")) (EVar "_s")))) (EVar "fresh"))))) (DoLet false false (PVar "spaced") (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString " ")) (EVar "_s")))) (EVar "params")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "plan") "plName"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "spaced"))) (ELit (LString " = "))) (EApp (EVar "display") (EVar "goName"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "args"))) (ELit (LString ""))))))
(DTypeSig false "outerParams" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "outerParams" ((PVar "plan") (PVar "fresh")) (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "paramAt") (EVar "plan")) (EVar "fresh")) (EVar "i")))) (ERangeList (ELit (LInt 0)) (EBinOp "-" (EFieldAccess (EVar "plan") "plArity") (ELit (LInt 1))) true)))
(DTypeSig false "paramAt" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "paramAt" ((PVar "plan") (PVar "fresh") (PVar "i")) (EMatch (EApp (EApp (EVar "lookup") (EVar "i")) (EApp (EApp (EVar "zip") (EFieldAccess (EVar "plan") "plShared")) (EFieldAccess (EVar "plan") "plNames"))) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EApp (EVar "optionOr") (ELit (LString "_"))) (EApp (EApp (EVar "lookup") (EVar "i")) (EApp (EApp (EVar "zip") (EApp (EVar "restOf") (EVar "plan"))) (EVar "fresh")))))))
(DTypeSig false "shiftEdits" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Span") (TyApp (TyCon "List") (TyCon "FixEdit")))))))
(DFunDef false "shiftEdits" ((PVar "plan") (PVar "dropped") (PVar "merge") (PVar "sp")) (EApp (EApp (EVar "map") (ELam ((PVar "l")) (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "l")) (ELit (LInt 0))) (EVar "l")) (ELit (LInt 0)))) (ELit (LString "    "))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "l")) (EApp (EApp (EApp (EApp (EVar "shifted") (EVar "plan")) (EVar "dropped")) (EVar "merge")) (EVar "l")))) (ERangeList (EBinOp "+" (EFieldAccess (EVar "sp") "spFirst") (ELit (LInt 1))) (EFieldAccess (EVar "sp") "spLast") true))))
(DTypeSig false "shifted" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "shifted" ((PVar "plan") (PVar "dropped") (PVar "merge") (PVar "l")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "l")))) (EVar "dropped"))) (EBinOp "/=" (EApp (EVar "trim") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l"))) (ELit (LString "")))) (EMatch (EVar "merge") (arm (PCon "Some" (PVar "w")) () (EBinOp "<" (EVar "l") (EVar "w"))) (arm (PCon "None") () (EVar "True")))))
(DTypeSig false "dropLine" (TyFun (TyCon "Plan") (TyFun (TyCon "Int") (TyCon "FixEdit"))))
(DFunDef false "dropLine" ((PVar "plan") (PVar "l")) (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EBinOp "-" (EVar "l") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EBinOp "-" (EVar "l") (ELit (LInt 1)))))) (EVar "l")) (EApp (EVar "stringLength") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l"))))) (ELit (LString ""))))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Constraint" true) (mem "Decl" true) (mem "Expr" true) (mem "FunClause" true) (mem "Guard" true) (mem "LetBind" true) (mem "Loc" true) (mem "Pat" true) (mem "Ty" true) (mem "patBoundNames" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "childExprs" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "localBoundNames" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("array") ((mem "get" false "arrayGet"))))
(DUse false (UseGroup ("list") ((mem "dropWhile" false) (mem "findMap" false) (mem "get" false) (mem "last" false) (mem "lookup" false) (mem "reverse" false) (mem "sortBy" false) (mem "zip" false))))
(DUse false (UseGroup ("string") ((mem "contains" false) (mem "repeat" false) (mem "startsWith" false) (mem "trim" false) (mem "trimLeft" false) (mem "trimRight" false))))
(DUse false (UseGroup ("support" "char") ((mem "isIdentChar" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "filterList" false) (mem "joinWith" false) (mem "listLen" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factLines" false) (mem "factScopes" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_recursion") ((mem "ArgRole" true) (mem "Owner" true) (mem "SelfCall" true) (mem "selfCalls" false) (mem "spineOf" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "declLocList" false) (mem "isCtorName" false) (mem "isEVarNamed" false) (mem "mentionsVar" false) (mem "ruleNameThreadedInvariant" false) (mem "unwrapLoc" false) (mem "varSite" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameThreadedInvariant")) (fa "summary" (ELit (LString "a self-recursive function passes two or more of its parameters through every self-call unchanged: close over them in a where-local `go`"))) (fa "doc" (ELit (LString "A top-level function that calls itself with the same two or more parameters, in the same positions, in every self-call carries those parameters through the whole recursion for nothing. A local `go` in a `where` closes over them, so the recursion names only what changes. The rule reads each function as a group of clauses: a position counts when every full-arity self-call of every clause that makes one passes that clause's own parameter there, unchanged. One invariant parameter is not reported, nor is a `go` that already closes over its invariants, a partial application, mutual recursion, or a loop local to a `let` or `where`.\n\n`--fix --unsafe-fixes` writes the `go` form when the whole shape is known: a signature whose class constraints the closed-over parameters carry, each invariant parameter a plain name (or ignored) in every clause, no list builder in tail position modulo cons, no invariant parameter used only to be passed on, and a `where` of its own only on a single clause. The rest are reported only. Run `medaka fmt --write` after it, then check the converted loop for dictionary dispatch: `go` is inferred, not declared, so a changing parameter whose type only the signature fixes (a counter under `+` or `==`, an element that is interpolated) is let-generalised and the loop passes a dictionary on every call (#MONOLOCAL, MonoLocalBinds). The fix does not see that shape.\n\nBefore:\n  extractFold bare heads acc (x :: xs) = extractFold bare heads (step bare heads acc x) xs\n  extractFold _ _ acc [] = acc\nAfter:\n  extractFold bare heads acc0 xs0 = go acc0 xs0\n    where\n      go acc [] = acc\n      go acc (x :: xs) = go (step bare heads acc x) xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "FixableUnsafe")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleThreadedInvariant")) (EVar "None")))
(DTypeSig false "ruleThreadedInvariant" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleThreadedInvariant" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "groups") (EApp (EVar "functionGroups") (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "functionFindings") (EVar "facts")) (EVar "prog"))) (EVar "groups")))))
(DData Private "Clause" () ((variant "Clause" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) ())
(DData Private "Group" () ((variant "Group" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "Clause")) (TyCon "Int")))) ())
(DTypeSig false "functionGroups" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "Group"))))
(DFunDef false "functionGroups" ((PVar "dls")) (EApp (EApp (EApp (EMethodRef "foldRight") (EVar "joinClause")) (EListLit)) (EApp (EApp (EDictApp "flatMap") (EVar "clauseOf")) (EApp (EVar "withNext") (EVar "dls")))))
(DTypeSig false "withNext" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int")))))
(DFunDef false "withNext" ((PList)) (EListLit))
(DFunDef false "withNext" ((PCons (PTuple (PVar "d") (PVar "loc")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "d") (EVar "loc") (EApp (EVar "startOf") (EVar "rest"))) (EApp (EVar "withNext") (EVar "rest"))))
(DTypeSig false "startOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyCon "Int")))
(DFunDef false "startOf" ((PCons (PTuple PWild (PCon "Some" (PCon "Loc" PWild (PVar "l") PWild PWild PWild))) PWild)) (EVar "l"))
(DFunDef false "startOf" (PWild) (ELit (LInt 0)))
(DTypeSig false "clauseOf" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int") (TyCon "Clause")))))
(DFunDef false "clauseOf" ((PTuple (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") (PCon "Loc" PWild (PVar "l") PWild PWild PWild) PWild) (PVar "loc") (PVar "next"))) (EListLit (ETuple (EVar "n") (EVar "loc") (EVar "next") (EApp (EApp (EApp (EVar "Clause") (EVar "l")) (EVar "ps")) (EVar "body")))))
(DFunDef false "clauseOf" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc") (PVar "next"))) (EApp (EApp (EMethodRef "map") (EVar "unplaced")) (EApp (EVar "clauseOf") (ETuple (EVar "d") (EVar "loc") (EVar "next")))))
(DFunDef false "clauseOf" (PWild) (EListLit))
(DTypeSig false "unplaced" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int") (TyCon "Clause")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int") (TyCon "Clause"))))
(DFunDef false "unplaced" ((PTuple (PVar "n") (PVar "loc") (PVar "next") (PCon "Clause" PWild (PVar "ps") (PVar "body")))) (ETuple (EVar "n") (EVar "loc") (EVar "next") (EApp (EApp (EApp (EVar "Clause") (ELit (LInt 0))) (EVar "ps")) (EVar "body"))))
(DTypeSig false "joinClause" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int") (TyCon "Clause")) (TyFun (TyApp (TyCon "List") (TyCon "Group")) (TyApp (TyCon "List") (TyCon "Group")))))
(DFunDef false "joinClause" ((PTuple (PVar "n") (PVar "loc") PWild (PVar "c")) (PCons (PCon "Group" (PVar "m") PWild (PVar "cs") (PVar "next")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "Group") (EVar "n")) (EVar "loc")) (EBinOp "::" (EVar "c") (EVar "cs"))) (EVar "next")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "joinClause" ((PTuple (PVar "n") (PVar "loc") (PVar "next") (PVar "c")) (PVar "groups")) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "Group") (EVar "n")) (EVar "loc")) (EListLit (EVar "c"))) (EVar "next")) (EVar "groups")))
(DData Private "Threaded" () ((variant "Threaded" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "SelfCall"))))) ())
(DTypeSig false "functionFindings" (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Group") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "functionFindings" ((PVar "facts") (PVar "prog") (PAs "g" (PCon "Group" (PVar "name") (PVar "loc") (PVar "clauses") PWild))) (EMatch (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "clauseThreaded") (EApp (EVar "factScopes") (EVar "facts"))) (EVar "name"))) (EVar "clauses")) (arm (PList) () (EListLit)) (arm (PAs "ts" (PCons (PCon "Threaded" (PVar "ps") (PVar "first") PWild) PWild)) () (EBlock (DoLet false false (PVar "shared") (EApp (EApp (EVar "filterList") (EApp (EVar "inAll") (EVar "ts"))) (EVar "first"))) (DoExpr (EIf (EBinOp ">=" (EApp (EVar "listLen") (EVar "shared")) (ELit (LInt 2))) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EVar "paramName") (EVar "ps")) (EVar "i")))) (EVar "shared"))) (DoLet false false (PVar "calls") (EApp (EApp (EDictApp "flatMap") (EVar "threadedCalls")) (EVar "ts"))) (DoExpr (EListLit (EApp (EApp (EApp (EApp (EVar "report") (EVar "name")) (EVar "loc")) (EVar "names")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "threadFix") (EVar "facts")) (EVar "prog")) (EVar "g")) (EVar "shared")) (EVar "names")) (EVar "calls")))))) (EListLit)))))))
(DTypeSig false "clauseThreaded" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "Clause") (TyApp (TyCon "List") (TyCon "Threaded"))))))
(DFunDef false "clauseThreaded" ((PVar "scopes") (PVar "name") (PCon "Clause" PWild (PVar "ps") (PVar "body"))) (EIf (EBinOp "||" (EBinOp "<" (EApp (EVar "listLen") (EVar "ps")) (ELit (LInt 2))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "name")) (EVar "body")))) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "selfCalls") (EVar "scopes")) (EApp (EApp (EApp (EVar "Owner") (EVar "name")) (EVar "ps")) (EVar "None"))) (EVar "body")) (arm (PList) () (EListLit)) (arm (PVar "calls") () (EListLit (EApp (EApp (EApp (EVar "Threaded") (EVar "ps")) (EApp (EApp (EVar "filterList") (EApp (EVar "unchangedIn") (EVar "calls"))) (ERangeList (ELit (LInt 0)) (EBinOp "-" (EApp (EVar "listLen") (EVar "ps")) (ELit (LInt 1))) true))) (EVar "calls"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "threadedCalls" (TyFun (TyCon "Threaded") (TyApp (TyCon "List") (TyCon "SelfCall"))))
(DFunDef false "threadedCalls" ((PCon "Threaded" PWild PWild (PVar "calls"))) (EVar "calls"))
(DTypeSig false "inAll" (TyFun (TyApp (TyCon "List") (TyCon "Threaded")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "inAll" ((PVar "ts") (PVar "i")) (EApp (EApp (EVar "allList") (ELam ((PVar "t")) (EApp (EApp (EVar "hasPosition") (EVar "i")) (EVar "t")))) (EVar "ts")))
(DTypeSig false "hasPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Threaded") (TyCon "Bool"))))
(DFunDef false "hasPosition" ((PVar "i") (PCon "Threaded" PWild (PVar "positions") PWild)) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "i")))) (EVar "positions")))
(DTypeSig false "unchangedIn" (TyFun (TyApp (TyCon "List") (TyCon "SelfCall")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "unchangedIn" ((PVar "calls") (PVar "i")) (EApp (EApp (EVar "allList") (EApp (EVar "callKeeps") (EVar "i"))) (EVar "calls")))
(DTypeSig false "callKeeps" (TyFun (TyCon "Int") (TyFun (TyCon "SelfCall") (TyCon "Bool"))))
(DFunDef false "callKeeps" ((PVar "i") (PCon "SelfCall" PWild PWild (PVar "roles"))) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "roles")) (arm (PCon "Some" (PCon "Unchanged" (PVar "j"))) () (EBinOp "==" (EVar "j") (EVar "i"))) (arm PWild () (EVar "False"))))
(DTypeSig false "paramName" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "paramName" ((PVar "ps") (PVar "i")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EVar "ps")) (arm (PCon "Some" (PCon "PVar" (PVar "n") PWild PWild)) () (EVar "n")) (arm (PCon "Some" (PCon "PAs" (PVar "n") PWild PWild PWild)) () (EVar "n")) (arm PWild () (ELit (LString "_")))))
(DTypeSig false "report" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding"))))))
(DFunDef false "report" ((PVar "name") (PVar "loc") (PVar "names") (PVar "fix")) (EBlock (DoLet false false (PVar "listed") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "quoted")) (EVar "names")))) (DoExpr (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameThreadedInvariant")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` passes "))) (EApp (EMethodRef "display") (EVar "listed"))) (ELit (LString " through every self-call unchanged: close over them in a where-local `go`")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))))
(DTypeSig false "quoted" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoted" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`"))))
(DTypeSig false "threadFix" (TyFun (TyCon "FileFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Group") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "SelfCall")) (TyApp (TyCon "Option") (TyCon "Fix")))))))))
(DFunDef false "threadFix" ((PVar "facts") (PVar "prog") (PCon "Group" (PVar "name") PWild (PVar "clauses") (PVar "next")) (PVar "shared") (PVar "names") (PVar "calls")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "clauseHead") (EVar "clauses"))) (ELam ((PVar "first")) (ELet false (PVar "ls") (EApp (EVar "factLines") (EVar "facts")) (ELet false (PVar "plan") (ERecordCreate "Plan" ((fa "plLines" (EVar "ls")) (fa "plName" (EVar "name")) (fa "plArity" (EApp (EVar "listLen") (EApp (EVar "clausePats") (EVar "first")))) (fa "plShared" (EVar "shared")) (fa "plNames" (EVar "names")) (fa "plCalls" (EVar "calls")) (fa "plBound" (EApp (EVar "localBoundNames") (EApp (EApp (EVar "filterList") (EApp (EVar "definesName") (EVar "name"))) (EVar "prog")))))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EMethodRef "traverse") (EApp (EVar "clauseSpan") (EVar "plan"))) (EApp (EApp (EVar "withBounds") (EApp (EApp (EVar "lineCount") (EVar "ls")) (EVar "next"))) (EVar "clauses")))) (ELam ((PVar "spans")) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EApp (EApp (EVar "allList") (EApp (EVar "spanFits") (EVar "plan"))) (EVar "spans")))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EApp (EApp (EVar "allList") (EApp (EApp (EVar "usedBeyondCalls") (EVar "plan")) (EVar "spans"))) (EVar "names")))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "sp")) (EApp (EApp (EVar "buildsModuloCons") (EVar "plan")) (EFieldAccess (EVar "sp") "spBody")))) (EVar "spans"))))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EApp (EApp (EVar "allList") (ELam ((PVar "sp")) (EApp (EApp (EVar "recordTargetsFit") (EVar "plan")) (EFieldAccess (EVar "sp") "spBody")))) (EVar "spans")))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "sp")) (EApp (EApp (EVar "armGuardReadsInvariant") (EVar "plan")) (EFieldAccess (EVar "sp") "spBody")))) (EVar "spans"))))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EApp (EApp (EVar "signatureFits") (EVar "plan")) (EVar "prog")))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "whereMerge") (EVar "plan")) (EVar "spans"))) (ELam ((PVar "merge")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "rewriteEdits") (EVar "plan")) (EVar "spans")) (EVar "merge"))) (ELam ((PVar "edits")) (EApp (EVar "Some") (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "Unsafe")) (fa "fixEdits" (EVar "edits")) (fa "fixMessage" (ELit (LString "close over the invariant parameters in a where-local `go`")))))))))))))))))))))))))))))
(DTypeSig false "clauseHead" (TyFun (TyApp (TyCon "List") (TyCon "Clause")) (TyApp (TyCon "Option") (TyCon "Clause"))))
(DFunDef false "clauseHead" ((PCons (PVar "c") PWild)) (EApp (EVar "Some") (EVar "c")))
(DFunDef false "clauseHead" ((PList)) (EVar "None"))
(DTypeSig false "clausePats" (TyFun (TyCon "Clause") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "clausePats" ((PCon "Clause" PWild (PVar "ps") PWild)) (EVar "ps"))
(DTypeSig false "definesName" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "definesName" ((PVar "name") (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild)) (EBinOp "==" (EVar "n") (EVar "name")))
(DFunDef false "definesName" (PWild PWild) (EVar "False"))
(DData Private "Plan" () ((variant "Plan" (ConNamed (field "plLines" (TyApp (TyCon "Array") (TyCon "String"))) (field "plName" (TyCon "String")) (field "plArity" (TyCon "Int")) (field "plShared" (TyApp (TyCon "List") (TyCon "Int"))) (field "plNames" (TyApp (TyCon "List") (TyCon "String"))) (field "plCalls" (TyApp (TyCon "List") (TyCon "SelfCall"))) (field "plBound" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Private "Span" () ((variant "Span" (ConNamed (field "spFirst" (TyCon "Int")) (field "spLast" (TyCon "Int")) (field "spPats" (TyApp (TyCon "List") (TyCon "Pat"))) (field "spBody" (TyCon "Expr")) (field "spAtoms" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))) ())
(DTypeSig false "lineCount" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lineCount" ((PVar "ls") (PVar "next")) (EIf (EBinOp ">" (EVar "next") (ELit (LInt 0))) (EVar "next") (EBinOp "+" (EApp (EVar "arrayLength") (EVar "ls")) (ELit (LInt 1)))))
(DTypeSig false "withBounds" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Clause")) (TyApp (TyCon "List") (TyTuple (TyCon "Clause") (TyCon "Int"))))))
(DFunDef false "withBounds" ((PVar "bound") (PVar "cs0")) (ELetGroup ((lgb "go" (clause ((PList)) (EListLit)) (clause ((PList (PVar "c"))) (EListLit (ETuple (EVar "c") (EVar "bound")))) (clause ((PCons (PVar "c") (PAs "rest" (PCons (PCon "Clause" (PVar "l") PWild PWild) PWild)))) (EBinOp "::" (ETuple (EVar "c") (EVar "l")) (EApp (EVar "go") (EVar "rest")))))) (EApp (EVar "go") (EVar "cs0"))))
(DTypeSig false "clauseSpan" (TyFun (TyCon "Plan") (TyFun (TyTuple (TyCon "Clause") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Span")))))
(DFunDef false "clauseSpan" ((PVar "plan") (PTuple (PCon "Clause" (PVar "l") (PVar "ps") (PVar "body")) (PVar "bound"))) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EBinOp ">" (EVar "l") (ELit (LInt 0))))) (ELam (PWild) (ELet false (PVar "text") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EApp (EApp (EVar "startsWith") (EBinOp "++" (EFieldAccess (EVar "plan") "plName") (ELit (LString " ")))) (EVar "text")))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "headAtoms") (EVar "text")) (EApp (EVar "stringLength") (EFieldAccess (EVar "plan") "plName")))) (ELam ((PVar "atoms")) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "atoms")) (EApp (EVar "listLen") (EVar "ps"))) (EBinOp "==" (EApp (EVar "listLen") (EVar "ps")) (EFieldAccess (EVar "plan") "plArity"))))) (ELam (PWild) (EApp (EVar "Some") (ERecordCreate "Span" ((fa "spFirst" (EVar "l")) (fa "spLast" (EApp (EApp (EApp (EVar "lastCode") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")) (EBinOp "-" (EVar "bound") (ELit (LInt 1))))) (fa "spPats" (EVar "ps")) (fa "spBody" (EVar "body")) (fa "spAtoms" (EVar "atoms")))))))))))))))
(DTypeSig false "lineText" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "lineText" ((PVar "ls") (PVar "n")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "arrayGet") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "ls"))))
(DTypeSig false "isCode" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isCode" ((PVar "s")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "trim") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp "/=" (EVar "t") (ELit (LString ""))) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "t")))))))
(DTypeSig false "indentAt" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "indentAt" ((PVar "ls") (PVar "n")) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "lineText") (EVar "ls")) (EVar "n"))) (DoExpr (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (EApp (EVar "stringLength") (EApp (EVar "trimLeft") (EVar "s")))))))
(DTypeSig false "lastCode" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lastCode" ((PVar "ls") (PVar "lo") (PVar "hi0")) (ELetGroup ((lgb "go" (clause ((PVar "hi")) (EIf (EBinOp "<=" (EVar "hi") (EVar "lo")) (EVar "lo") (EIf (EApp (EVar "isCode") (EApp (EApp (EVar "lineText") (EVar "ls")) (EVar "hi"))) (EVar "hi") (EIf (EVar "otherwise") (EApp (EVar "go") (EBinOp "-" (EVar "hi") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))) (EApp (EVar "go") (EVar "hi0"))))
(DTypeSig false "headAtoms" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "headAtoms" ((PVar "text") (PVar "start")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "text"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomsFrom") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "start")) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EListLit)))))
(DTypeSig false "headAtomsFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))))))
(DFunDef false "headAtomsFrom" ((PVar "cs") (PVar "n") (PVar "i") (PVar "depth") (PVar "from") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EIf (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "Some") (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "closed") (EVar "from")) (EVar "i")) (EVar "acc")))) (EVar "None")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomStep") (EVar "cs")) (EVar "n")) (EVar "i")) (EVar "depth")) (EVar "from")) (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "headAtomStep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))))))))
(DFunDef false "headAtomStep" ((PVar "cs") (PVar "n") (PVar "i") (PVar "depth") (PVar "from") (PVar "acc") (PVar "c")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "="))) (EBinOp "==" (EVar "c") (ELit (LChar "|"))))) (EIf (EBinOp ">=" (EVar "from") (ELit (LInt 0))) (EVar "None") (EApp (EVar "Some") (EApp (EVar "reverse") (EVar "acc")))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "==" (EVar "c") (ELit (LChar " ")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomsFrom") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "closed") (EVar "from")) (EVar "i")) (EVar "acc"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomsFrom") (EVar "cs")) (EVar "n")) (EApp (EApp (EApp (EVar "stringLitEnd") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EVar "depth")) (EApp (EApp (EVar "opened") (EVar "from")) (EVar "i"))) (EVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "-"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "-")))) (EVar "None") (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "'"))) (EApp (EVar "not") (EBinOp "&&" (EBinOp ">" (EVar "i") (ELit (LInt 0))) (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "cs")))))) (EVar "None") (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "("))) (EBinOp "==" (EVar "c") (ELit (LChar "[")))) (EBinOp "==" (EVar "c") (ELit (LChar "{")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomsFrom") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EApp (EApp (EVar "opened") (EVar "from")) (EVar "i"))) (EVar "acc")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar ")"))) (EBinOp "==" (EVar "c") (ELit (LChar "]")))) (EBinOp "==" (EVar "c") (ELit (LChar "}")))) (EIf (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomsFrom") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "from")) (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "headAtomsFrom") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EApp (EVar "opened") (EVar "from")) (EVar "i"))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "stringLitEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "stringLitEnd" ((PVar "cs") (PVar "n") (PVar "j0")) (ELetGroup ((lgb "go" (clause ((PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EVar "n")) (EVar "n") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "cs")) (ELit (LChar "\\"))) (EApp (EVar "go") (EBinOp "+" (EVar "j") (ELit (LInt 2)))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "cs")) (ELit (LChar "\""))) (EBinOp "+" (EVar "j") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EVar "go") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))) (EApp (EVar "go") (EVar "j0"))))
(DTypeSig false "closed" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "closed" ((PVar "from") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "from") (ELit (LInt 0))) (EBinOp "::" (ETuple (EVar "from") (EVar "i")) (EVar "acc")) (EVar "acc")))
(DTypeSig false "opened" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "opened" ((PVar "from") (PVar "i")) (EIf (EBinOp ">=" (EVar "from") (ELit (LInt 0))) (EVar "from") (EVar "i")))
(DTypeSig false "atomText" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "atomText" ((PVar "plan") (PVar "sp") (PVar "i")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EFieldAccess (EVar "sp") "spAtoms")) (arm (PCon "Some" (PTuple (PVar "a") (PVar "b"))) () (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EFieldAccess (EVar "sp") "spFirst")))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "headEnd" (TyFun (TyCon "Span") (TyCon "Int")))
(DFunDef false "headEnd" ((PVar "sp")) (EMatch (EApp (EVar "last") (EFieldAccess (EVar "sp") "spAtoms")) (arm (PCon "Some" (PTuple PWild (PVar "b"))) () (EVar "b")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "spanFits" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyCon "Bool"))))
(DFunDef false "spanFits" ((PVar "plan") (PVar "sp")) (EBinOp "&&" (EApp (EApp (EVar "allList") (EApp (EApp (EVar "invariantFits") (EVar "plan")) (EVar "sp"))) (EApp (EApp (EVar "zip") (EFieldAccess (EVar "plan") "plShared")) (EFieldAccess (EVar "plan") "plNames"))) (EApp (EApp (EVar "allList") (EApp (EApp (EVar "lineFits") (EVar "plan")) (EVar "sp"))) (ERangeList (EFieldAccess (EVar "sp") "spFirst") (EFieldAccess (EVar "sp") "spLast") true))))
(DTypeSig false "invariantFits" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "invariantFits" ((PVar "plan") (PVar "sp") (PTuple (PVar "i") (PVar "v"))) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EFieldAccess (EVar "sp") "spPats")) (arm (PCon "Some" (PCon "PVar" (PVar "x") PWild PWild)) () (EBinOp "&&" (EBinOp "==" (EApp (EApp (EApp (EVar "atomText") (EVar "plan")) (EVar "sp")) (EVar "i")) (EVar "x")) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "v")) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "_"))) (EVar "x")) (EApp (EVar "not") (EBinOp "||" (EApp (EApp (EVar "mentionsVar") (EVar "v")) (EFieldAccess (EVar "sp") "spBody")) (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EFieldAccess (EVar "sp") "spBody")))))))) (arm (PCon "Some" (PCon "PWild")) () (EBinOp "&&" (EBinOp "==" (EApp (EApp (EApp (EVar "atomText") (EVar "plan")) (EVar "sp")) (EVar "i")) (ELit (LString "_"))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "v")) (EFieldAccess (EVar "sp") "spBody"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "lineFits" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "lineFits" ((PVar "plan") (PVar "sp") (PVar "l")) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l"))) (DoExpr (EBinOp "&&" (EApp (EVar "not") (EBinOp "||" (EApp (EApp (EVar "contains") (ELit (LString "\"\"\""))) (EVar "s")) (EApp (EApp (EVar "contains") (ELit (LString "\t"))) (EVar "s")))) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "l") (EFieldAccess (EVar "sp") "spFirst")) (EApp (EVar "not") (EApp (EVar "isCode") (EVar "s")))) (EBinOp ">" (EApp (EApp (EVar "indentAt") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")) (ELit (LInt 0))))))))
(DTypeSig false "usedBeyondCalls" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "usedBeyondCalls" ((PVar "plan") (PVar "spans") (PVar "v")) (EBinOp ">" (EApp (EDictApp "sum") (EApp (EApp (EMethodRef "map") (ELam ((PVar "sp")) (EApp (EApp (EVar "countVar") (EVar "v")) (EFieldAccess (EVar "sp") "spBody")))) (EVar "spans"))) (EApp (EVar "listLen") (EFieldAccess (EVar "plan") "plCalls"))))
(DTypeSig false "countVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Int"))))
(DFunDef false "countVar" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EIf (EBinOp "==" (EVar "w") (EVar "x")) (ELit (LInt 1)) (ELit (LInt 0)))) (arm (PVar "e2") () (EApp (EDictApp "sum") (EApp (EApp (EMethodRef "map") (EApp (EVar "countVar") (EVar "x"))) (EApp (EVar "childExprs") (EVar "e2")))))))
(DTypeSig false "buildsModuloCons" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "buildsModuloCons" ((PVar "plan") (PVar "e")) (EBinOp "||" (EApp (EApp (EVar "consTail") (EVar "plan")) (EApp (EVar "unwrapLoc") (EVar "e"))) (EApp (EApp (EVar "anyList") (EApp (EVar "buildsModuloCons") (EVar "plan"))) (EApp (EVar "childExprs") (EApp (EVar "unwrapLoc") (EVar "e"))))))
(DTypeSig false "consTail" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "consTail" ((PVar "plan") (PCon "EBinOp" (PLit (LString "::")) PWild (PVar "tl") PWild)) (EApp (EApp (EVar "isSelfApp") (EVar "plan")) (EVar "tl")))
(DFunDef false "consTail" ((PVar "plan") (PAs "e" (PCon "EApp" PWild PWild))) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EBinOp "&&" (EApp (EVar "isCtorHead") (EVar "hd")) (EMatch (EApp (EVar "last") (EVar "args")) (arm (PCon "Some" (PVar "a")) () (EApp (EApp (EVar "isSelfApp") (EVar "plan")) (EVar "a"))) (arm (PCon "None") () (EVar "False")))))))
(DFunDef false "consTail" (PWild PWild) (EVar "False"))
(DTypeSig false "isCtorHead" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isCtorHead" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "c")) () (EApp (EVar "isCtorName") (EVar "c"))) (arm PWild () (EVar "False"))))
(DTypeSig false "isSelfApp" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isSelfApp" ((PVar "plan") (PVar "e")) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EFieldAccess (EVar "plan") "plName")) (EVar "hd")) (EBinOp "==" (EApp (EVar "listLen") (EVar "args")) (EFieldAccess (EVar "plan") "plArity"))))))
(DTypeSig false "armGuardReadsInvariant" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "armGuardReadsInvariant" ((PVar "plan") (PVar "e")) (EBinOp "||" (EApp (EApp (EVar "armGuards") (EVar "plan")) (EApp (EVar "unwrapLoc") (EVar "e"))) (EApp (EApp (EVar "anyList") (EApp (EVar "armGuardReadsInvariant") (EVar "plan"))) (EApp (EVar "childExprs") (EApp (EVar "unwrapLoc") (EVar "e"))))))
(DTypeSig false "armGuards" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "armGuards" ((PVar "plan") (PCon "EMatch" PWild (PVar "arms"))) (EApp (EApp (EVar "anyList") (EApp (EVar "armReads") (EVar "plan"))) (EVar "arms")))
(DFunDef false "armGuards" (PWild PWild) (EVar "False"))
(DTypeSig false "armReads" (TyFun (TyCon "Plan") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armReads" ((PVar "plan") (PCon "Arm" PWild (PVar "gs") PWild)) (EApp (EApp (EVar "anyList") (EApp (EVar "guardReads") (EVar "plan"))) (EVar "gs")))
(DTypeSig false "guardReads" (TyFun (TyCon "Plan") (TyFun (TyCon "Guard") (TyCon "Bool"))))
(DFunDef false "guardReads" ((PVar "plan") (PCon "GBool" (PVar "g"))) (EApp (EApp (EVar "readsInvariant") (EVar "plan")) (EVar "g")))
(DFunDef false "guardReads" ((PVar "plan") (PCon "GBind" PWild (PVar "g"))) (EApp (EApp (EVar "readsInvariant") (EVar "plan")) (EVar "g")))
(DTypeSig false "readsInvariant" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "readsInvariant" ((PVar "plan") (PVar "g")) (EApp (EApp (EVar "anyList") (ELam ((PVar "n")) (EApp (EApp (EVar "mentionsVar") (EVar "n")) (EVar "g")))) (EFieldAccess (EVar "plan") "plNames")))
(DTypeSig false "recordTargetsFit" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "recordTargetsFit" ((PVar "plan") (PVar "e")) (EBinOp "&&" (EApp (EApp (EVar "targetFits") (EVar "plan")) (EApp (EVar "unwrapLoc") (EVar "e"))) (EApp (EApp (EVar "allList") (EApp (EVar "recordTargetsFit") (EVar "plan"))) (EApp (EVar "childExprs") (EApp (EVar "unwrapLoc") (EVar "e"))))))
(DTypeSig false "targetFits" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "targetFits" ((PVar "plan") (PCon "EFieldAccess" (PVar "r") PWild PWild)) (EApp (EApp (EVar "recordRootFits") (EVar "plan")) (EVar "r")))
(DFunDef false "targetFits" ((PVar "plan") (PCon "ERecordUpdate" (PVar "r") PWild PWild)) (EApp (EApp (EVar "recordRootFits") (EVar "plan")) (EVar "r")))
(DFunDef false "targetFits" (PWild PWild) (EVar "True"))
(DTypeSig false "recordRootFits" (TyFun (TyCon "Plan") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "recordRootFits" ((PVar "plan") (PVar "r")) (EMatch (EApp (EVar "unwrapLoc") (EVar "r")) (arm (PCon "EFieldAccess" (PVar "inner") PWild PWild) () (EApp (EApp (EVar "recordRootFits") (EVar "plan")) (EVar "inner"))) (arm (PCon "EVar" (PVar "n")) () (EBinOp "||" (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EFieldAccess (EVar "plan") "plNames")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EFieldAccess (EVar "plan") "plBound"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "signatureFits" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "signatureFits" ((PVar "plan") (PVar "prog")) (EMatch (EApp (EApp (EVar "findMap") (EApp (EVar "sigNamed") (EFieldAccess (EVar "plan") "plName"))) (EVar "prog")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "t")) () (EBinOp "&&" (EApp (EApp (EApp (EVar "tyEvery") (ELam (PWild) (EVar "True"))) (EMethodRef "isEmpty")) (EVar "t")) (EApp (EApp (EVar "constraintsHeld") (EVar "plan")) (EVar "t"))))))
(DTypeSig false "constraintsHeld" (TyFun (TyCon "Plan") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "constraintsHeld" ((PVar "plan") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "doms") (EApp (EApp (EVar "domains") (EFieldAccess (EVar "plan") "plArity")) (EVar "t"))) (DoLet false false (PVar "held") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "i")) (EApp (EMethodRef "toList") (EApp (EApp (EVar "get") (EVar "i")) (EVar "doms"))))) (EFieldAccess (EVar "plan") "plShared"))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "doms")) (EFieldAccess (EVar "plan") "plArity")) (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EApp (EApp (EVar "allList") (EApp (EApp (EVar "tyEvery") (ELam ((PVar "v")) (EApp (EApp (EVar "anyList") (EApp (EVar "tyMentions") (EVar "v"))) (EVar "held")))) (ELam (PWild) (EVar "True")))) (EFieldAccess (EVar "c") "constraintArgs")))) (EVar "cs"))))))
(DFunDef false "constraintsHeld" (PWild PWild) (EVar "True"))
(DTypeSig false "sigNamed" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Ty")))))
(DFunDef false "sigNamed" ((PVar "n") (PCon "DTypeSig" PWild (PVar "m") (PVar "t") PWild)) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EApp (EVar "Some") (EVar "t")) (EVar "None")))
(DFunDef false "sigNamed" (PWild PWild) (EVar "None"))
(DTypeSig false "domains" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty")))))
(DFunDef false "domains" ((PVar "k") (PCon "TyFun" (PVar "a") (PVar "b"))) (EIf (EBinOp ">" (EVar "k") (ELit (LInt 0))) (EBinOp "::" (EVar "a") (EApp (EApp (EVar "domains") (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "domains" (PWild PWild) (EListLit))
(DTypeSig false "tyMentions" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "tyMentions" ((PVar "v") (PVar "t")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "tyEvery") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "v")))) (ELam (PWild) (EVar "True"))) (EVar "t"))))
(DTypeSig false "tyEvery" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")) (TyFun (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "tyEvery" ((PVar "ok") (PVar "okTail") (PVar "t0")) (ELetGroup ((lgb "go" (clause ((PCon "TyVar" (PVar "v"))) (EApp (EVar "ok") (EVar "v"))) (clause ((PCon "TyApp" (PVar "f") (PVar "x"))) (EBinOp "&&" (EApp (EVar "go") (EVar "f")) (EApp (EVar "go") (EVar "x")))) (clause ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "&&" (EApp (EVar "go") (EVar "a")) (EApp (EVar "go") (EVar "b")))) (clause ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "allList") (EVar "go")) (EVar "ts"))) (clause ((PCon "TyEffect" PWild (PVar "tl") (PVar "t"))) (EBinOp "&&" (EApp (EVar "okTail") (EVar "tl")) (EApp (EVar "go") (EVar "t")))) (clause ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "&&" (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EApp (EApp (EVar "allList") (EVar "go")) (EFieldAccess (EVar "c") "constraintArgs")))) (EVar "cs")) (EApp (EVar "go") (EVar "t")))) (clause ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "go") (EVar "t"))) (clause ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "go") (EVar "t"))) (clause ((PCon "TyRow" PWild (PVar "tl") PWild)) (EApp (EVar "okTail") (EVar "tl"))) (clause ((PRec "TyCon" ((rf "tyConName" PWild)) false)) (EVar "True")) (clause ((PCon "TyAuth" PWild PWild)) (EVar "True")))) (EApp (EVar "go") (EVar "t0"))))
(DTypeSig false "whereMerge" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyApp (TyCon "Option") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "whereMerge" ((PVar "plan") (PVar "spans")) (EMatch (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "sp")) (EApp (EApp (EVar "filterList") (EApp (EVar "hasWhere") (EVar "plan"))) (ERangeList (EFieldAccess (EVar "sp") "spFirst") (EFieldAccess (EVar "sp") "spLast") true)))) (EVar "spans")) (arm (PList) () (EApp (EVar "Some") (EVar "None"))) (arm (PList (PVar "w")) () (EMatch (EVar "spans") (arm (PList (PVar "sp")) () (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "trim") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "w"))) (ELit (LString "where"))) (EBinOp "==" (EApp (EApp (EVar "indentAt") (EFieldAccess (EVar "plan") "plLines")) (EVar "w")) (ELit (LInt 2)))) (EApp (EApp (EApp (EVar "bindingsFit") (EVar "plan")) (EVar "sp")) (EVar "w"))) (EApp (EVar "Some") (EApp (EVar "Some") (EVar "w"))) (EVar "None"))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "hasWhere" (TyFun (TyCon "Plan") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "hasWhere" ((PVar "plan") (PVar "l")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LString "where"))))) (EApp (EVar "identifiersIn") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")))))
(DTypeSig false "bindingsFit" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "bindingsFit" ((PVar "plan") (PVar "sp") (PVar "w")) (EMatch (EApp (EVar "unwrapLoc") (EFieldAccess (EVar "sp") "spBody")) (arm (PCon "ELetGroup" (PVar "binds") PWild) () (EBlock (DoLet false false (PVar "changing") (EApp (EApp (EDictApp "flatMap") (EVar "patBoundNames")) (EApp (EApp (EVar "restPats") (EVar "plan")) (EVar "sp")))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "allList") (ELam ((PVar "b")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "n")) (EApp (EApp (EVar "bindMentions") (EVar "n")) (EVar "b")))) (EVar "changing"))))) (EVar "binds")) (EApp (EApp (EVar "allList") (ELam ((PVar "l")) (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isCode") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")))) (EBinOp ">=" (EApp (EApp (EVar "indentAt") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")) (ELit (LInt 4)))))) (ERangeList (EBinOp "+" (EVar "w") (ELit (LInt 1))) (EFieldAccess (EVar "sp") "spLast") true)))))) (arm PWild () (EVar "False"))))
(DTypeSig false "bindMentions" (TyFun (TyCon "String") (TyFun (TyCon "LetBind") (TyCon "Bool"))))
(DFunDef false "bindMentions" ((PVar "n") (PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "anyList") (ELam ((PCon "FunClause" PWild (PVar "body"))) (EApp (EApp (EVar "mentionsVar") (EVar "n")) (EVar "body")))) (EVar "clauses")))
(DData Private "Cut" () ((variant "Cut" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "String")))) ())
(DTypeSig false "restOf" (TyFun (TyCon "Plan") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "restOf" ((PVar "plan")) (EApp (EApp (EVar "filterList") (ELam ((PVar "i")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "i")))) (EFieldAccess (EVar "plan") "plShared"))))) (ERangeList (ELit (LInt 0)) (EBinOp "-" (EFieldAccess (EVar "plan") "plArity") (ELit (LInt 1))) true)))
(DTypeSig false "restPats" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "restPats" ((PVar "plan") (PVar "sp")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "i")) (EApp (EMethodRef "toList") (EApp (EApp (EVar "get") (EVar "i")) (EFieldAccess (EVar "sp") "spPats"))))) (EApp (EVar "restOf") (EVar "plan"))))
(DTypeSig false "rewriteEdits" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "FixEdit")))))))
(DFunDef false "rewriteEdits" ((PVar "plan") (PVar "spans") (PVar "merge")) (ELet false (PVar "taken") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "sp")) (EApp (EApp (EVar "regionWords") (EVar "plan")) (EVar "sp")))) (EVar "spans")) (ELet false (PVar "goName") (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LString "go"))))) (EVar "taken")) (EApp (EApp (EApp (EVar "freshFrom") (EVar "taken")) (ELit (LString "go"))) (ELit (LInt 1))) (ELit (LString "go"))) (ELet false (PVar "fresh") (EApp (EApp (EApp (EApp (EVar "outerNames") (EVar "plan")) (EVar "spans")) (EVar "taken")) (EVar "goName")) (ELet false (PVar "goArgs") (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "fresh")) (ELit (LInt 0))) (ELit (LString " ()")) (ELit (LString ""))) (ELet false (PVar "callHead") (EBinOp "++" (EVar "goName") (EVar "goArgs")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EMethodRef "traverse") (EApp (EApp (EVar "callPieces") (EVar "plan")) (EVar "callHead"))) (EFieldAccess (EVar "plan") "plCalls"))) (ELam ((PVar "pieces")) (ELet false (PVar "cuts") (EApp (EApp (EDictApp "flatMap") (EVar "fst")) (EVar "pieces")) (ELet false (PVar "dropped") (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "pieces")) (EApp (EMethodRef "toList") (EVar "merge"))) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EApp (EApp (EVar "allList") (EApp (EVar "cutInside") (EVar "spans"))) (EVar "cuts")))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EMethodRef "traverse") (EApp (EApp (EApp (EApp (EVar "lineEdits") (EVar "plan")) (EVar "spans")) (EVar "dropped")) (EVar "merge"))) (EApp (EVar "cutLines") (EVar "cuts")))) (ELam ((PVar "lineCuts")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EMethodRef "traverse") (EApp (EApp (EApp (EApp (EApp (EVar "headEdit") (EVar "plan")) (EVar "dropped")) (EVar "merge")) (EVar "goName")) (EVar "fresh"))) (EApp (EVar "indexedSpans") (EVar "spans")))) (ELam ((PVar "heads")) (ELet false (PVar "shifts") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "shiftEdits") (EVar "plan")) (EVar "dropped")) (EVar "merge"))) (EVar "spans")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "heads") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "es")) (EVar "es"))) (EVar "lineCuts"))) (EVar "shifts")) (EApp (EApp (EMethodRef "map") (EApp (EVar "dropLine") (EVar "plan"))) (EVar "dropped")))))))))))))))))))))
(DTypeSig false "indexedSpans" (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Span")))))
(DFunDef false "indexedSpans" ((PVar "spans")) (EApp (EApp (EVar "zip") (ERangeList (ELit (LInt 0)) (EBinOp "-" (EApp (EVar "listLen") (EVar "spans")) (ELit (LInt 1))) true)) (EVar "spans")))
(DTypeSig false "regionWords" (TyFun (TyCon "Plan") (TyFun (TyCon "Span") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "regionWords" ((PVar "plan") (PVar "sp")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "l")) (EApp (EVar "identifiersIn") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l"))))) (ERangeList (EFieldAccess (EVar "sp") "spFirst") (EFieldAccess (EVar "sp") "spLast") true)))
(DTypeSig false "identifiersIn" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "identifiersIn" ((PVar "s")) (ELetGroup ((lgb "cs" (clause () (EApp (EVar "stringToChars") (EVar "s")))) (lgb "n" (clause () (EApp (EVar "arrayLength") (EVar "cs")))) (lgb "go" (clause ((PVar "i") (PVar "from") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "reverse") (EApp (EApp (EApp (EVar "word") (EVar "from")) (EVar "i")) (EVar "acc"))) (EIf (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EVar "opened") (EVar "from")) (EVar "i"))) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "word") (EVar "from")) (EVar "i")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (lgb "word" (clause ((PVar "from") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "from") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "from")) (EVar "i")) (EVar "s")) (EVar "acc")) (EVar "acc"))))) (EApp (EApp (EApp (EVar "go") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EListLit))))
(DTypeSig false "freshFrom" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "freshFrom" ((PVar "taken") (PVar "base") (PVar "k0")) (ELetGroup ((lgb "go" (clause ((PVar "k")) (EBlock (DoLet false false (PVar "candidate") (EBinOp "++" (EVar "base") (EApp (EVar "intToString") (EVar "k")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "candidate")))) (EVar "taken")) (EApp (EVar "go") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "candidate"))))))) (EApp (EVar "go") (EVar "k0"))))
(DTypeSig false "outerNames" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "outerNames" ((PVar "plan") (PVar "spans") (PVar "taken") (PVar "goName")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "used") (PCons (PVar "i") (PVar "is"))) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EApp (EVar "freshFrom") (EVar "used")) (EApp (EApp (EVar "baseName") (EVar "spans")) (EVar "i"))) (ELit (LInt 0)))) (DoExpr (EBinOp "::" (EVar "n") (EApp (EApp (EVar "go") (EBinOp "::" (EVar "n") (EVar "used"))) (EVar "is")))))))) (EApp (EApp (EVar "go") (EBinOp "::" (EVar "goName") (EVar "taken"))) (EApp (EVar "restOf") (EVar "plan")))))
(DTypeSig false "baseName" (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "baseName" ((PVar "spans") (PVar "i")) (EMatch (EApp (EApp (EVar "findMap") (ELam ((PVar "sp")) (EApp (EApp (EVar "namedAt") (EVar "sp")) (EVar "i")))) (EVar "spans")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "stripDigits") (EVar "n"))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "sp")) (EApp (EApp (EVar "listLike") (EVar "sp")) (EVar "i")))) (EVar "spans")) (ELit (LString "xs")) (ELit (LString "x"))))))
(DTypeSig false "namedAt" (TyFun (TyCon "Span") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "namedAt" ((PVar "sp") (PVar "i")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EFieldAccess (EVar "sp") "spPats")) (arm (PCon "Some" (PCon "PVar" (PVar "n") PWild PWild)) () (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "_"))) (EVar "n")) (EVar "None") (EApp (EVar "Some") (EVar "n")))) (arm (PCon "Some" (PCon "PAs" (PVar "n") PWild PWild PWild)) () (EApp (EVar "Some") (EVar "n"))) (arm PWild () (EVar "None"))))
(DTypeSig false "listLike" (TyFun (TyCon "Span") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "listLike" ((PVar "sp") (PVar "i")) (EMatch (EApp (EApp (EVar "get") (EVar "i")) (EFieldAccess (EVar "sp") "spPats")) (arm (PCon "Some" (PCon "PCons" PWild PWild)) () (EVar "True")) (arm (PCon "Some" (PCon "PList" PWild)) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "stripDigits" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripDigits" ((PVar "n")) (EBlock (DoLet false false (PVar "cs") (EApp (EMethodRef "toList") (EApp (EVar "stringToChars") (EVar "n")))) (DoLet false false (PVar "kept") (EApp (EVar "reverse") (EApp (EApp (EVar "dropWhile") (ELam ((PVar "c")) (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9")))) (EBinOp "==" (EVar "c") (ELit (LChar "'")))))) (EApp (EVar "reverse") (EVar "cs"))))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "kept")) (ELit (LInt 0))) (ELit (LString "x")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EVar "kept")))))))
(DTypeSig false "callPieces" (TyFun (TyCon "Plan") (TyFun (TyCon "String") (TyFun (TyCon "SelfCall") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Cut")) (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "callPieces" ((PVar "plan") (PVar "callHead") (PCon "SelfCall" PWild (PVar "e") PWild)) (EMatch (EApp (EApp (EVar "spineOf") (EVar "e")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "varSite") (EVar "hd"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "Loc" PWild (PVar "hl") (PVar "hc") PWild (PVar "hec")) () (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "hc")) (EVar "hec")) (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "hl"))) (EFieldAccess (EVar "plan") "plName")))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EMethodRef "traverse") (EApp (EApp (EVar "argPiece") (EVar "plan")) (EVar "args"))) (EApp (EApp (EVar "zip") (EFieldAccess (EVar "plan") "plShared")) (EFieldAccess (EVar "plan") "plNames")))) (ELam ((PVar "pieces")) (EApp (EVar "Some") (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "Cut") (EVar "hl")) (EVar "hc")) (EVar "hec")) (EVar "callHead")) (EApp (EApp (EDictApp "flatMap") (EVar "fst")) (EVar "pieces"))) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "pieces")))))))))))))))
(DTypeSig false "argPiece" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyTuple (TyCon "Int") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Cut")) (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "argPiece" ((PVar "plan") (PVar "args") (PTuple (PVar "i") (PVar "v"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "get") (EVar "i")) (EVar "args"))) (ELam ((PVar "a")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "varSite") (EVar "a"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "Loc" PWild (PVar "al") (PVar "ac") (PVar "el") (PVar "aec")) () (ELet false (PVar "s") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "al")) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EBinOp "&&" (EBinOp "==" (EVar "el") (EVar "al")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "ac")) (EVar "aec")) (EVar "s")) (EVar "v"))))) (ELam (PWild) (EIf (EBinOp "==" (EApp (EVar "trim") (EVar "s")) (EVar "v")) (EApp (EVar "Some") (ETuple (EListLit) (EListLit (EVar "al")))) (EBlock (DoLet false false (PVar "kept") (EApp (EVar "stringLength") (EApp (EVar "trimRight") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "ac")) (EVar "s"))))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "kept") (ELit (LInt 0))) (EBinOp "<" (EVar "kept") (EVar "ac"))) (EApp (EVar "Some") (ETuple (EListLit (EApp (EApp (EApp (EApp (EVar "Cut") (EVar "al")) (EVar "kept")) (EVar "aec")) (ELit (LString "")))) (EListLit))) (EVar "None")))))))))))))))
(DTypeSig false "cutInside" (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyFun (TyCon "Cut") (TyCon "Bool"))))
(DFunDef false "cutInside" ((PVar "spans") (PCon "Cut" (PVar "l") (PVar "c") PWild PWild)) (EApp (EApp (EVar "anyList") (ELam ((PVar "sp")) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "l") (EFieldAccess (EVar "sp") "spFirst")) (EBinOp "<=" (EVar "l") (EFieldAccess (EVar "sp") "spLast"))) (EBinOp "||" (EBinOp ">" (EVar "l") (EFieldAccess (EVar "sp") "spFirst")) (EBinOp ">=" (EVar "c") (EApp (EVar "headEnd") (EVar "sp"))))))) (EVar "spans")))
(DTypeSig false "cutLine" (TyFun (TyCon "Cut") (TyCon "Int")))
(DFunDef false "cutLine" ((PCon "Cut" (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeSig false "cutStart" (TyFun (TyCon "Cut") (TyCon "Int")))
(DFunDef false "cutStart" ((PCon "Cut" PWild (PVar "c") PWild PWild)) (EVar "c"))
(DTypeSig false "cutKey" (TyFun (TyCon "Cut") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "cutKey" ((PCon "Cut" (PVar "l") (PVar "c") PWild PWild)) (ETuple (EVar "l") (EVar "c")))
(DTypeSig false "cutLines" (TyFun (TyApp (TyCon "List") (TyCon "Cut")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Cut"))))))
(DFunDef false "cutLines" ((PVar "cuts")) (EBlock (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (ELam ((PVar "a") (PVar "b")) (EApp (EApp (EMethodRef "compare") (EApp (EVar "cutKey") (EVar "a"))) (EApp (EVar "cutKey") (EVar "b"))))) (EVar "cuts"))) (DoExpr (EApp (EApp (EApp (EMethodRef "foldRight") (EVar "addCut")) (EListLit)) (EVar "sorted")))))
(DTypeSig false "addCut" (TyFun (TyCon "Cut") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Cut")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Cut")))))))
(DFunDef false "addCut" ((PVar "c") (PCons (PTuple (PVar "l") (PVar "cs")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "l") (EApp (EVar "cutLine") (EVar "c"))) (EBinOp "::" (ETuple (EVar "l") (EBinOp "::" (EVar "c") (EVar "cs"))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "addCut" ((PVar "c") (PVar "groups")) (EBinOp "::" (ETuple (EApp (EVar "cutLine") (EVar "c")) (EListLit (EVar "c"))) (EVar "groups")))
(DTypeSig false "lineEdits" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Span")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "Cut"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "FixEdit")))))))))
(DFunDef false "lineEdits" ((PVar "plan") (PVar "spans") (PVar "dropped") (PVar "merge") (PTuple (PVar "l") (PVar "cs"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "findMap") (ELam ((PVar "s")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "l") (EFieldAccess (EVar "s") "spFirst")) (EBinOp "<=" (EVar "l") (EFieldAccess (EVar "s") "spLast"))) (EApp (EVar "Some") (EVar "s")) (EVar "None")))) (EVar "spans"))) (ELam ((PVar "sp")) (ELet false (PVar "s") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l")) (ELet false (PVar "start") (EMatch (EVar "cs") (arm (PCons (PVar "c") PWild) () (EApp (EVar "cutStart") (EVar "c"))) (arm (PList) () (ELit (LInt 0)))) (ELet false (PVar "below") (EApp (EApp (EApp (EApp (EVar "nextCodeLine") (EVar "plan")) (EVar "dropped")) (EVar "l")) (EApp (EApp (EApp (EVar "limitFor") (EVar "merge")) (EVar "sp")) (EVar "l"))) (ELet false (PVar "pad") (EIf (EBinOp "==" (EVar "l") (EFieldAccess (EVar "sp") "spFirst")) (EApp (EVar "isSome") (EVar "below")) (EBinOp "&&" (EApp (EApp (EVar "movesTokens") (EVar "s")) (EVar "cs")) (EMatch (EVar "below") (arm (PCon "Some" (PVar "b")) () (EBinOp ">=" (EApp (EApp (EVar "indentAt") (EFieldAccess (EVar "plan") "plLines")) (EVar "b")) (EVar "start"))) (arm (PCon "None") () (EVar "False"))))) (EApp (EApp (EMethodRef "traverse") (EApp (EVar "cutEdit") (EVar "pad"))) (EVar "cs")))))))))
(DTypeSig false "movesTokens" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cut")) (TyCon "Bool"))))
(DFunDef false "movesTokens" (PWild (PList)) (EVar "False"))
(DFunDef false "movesTokens" ((PVar "s") (PAs "cs" (PCons PWild (PVar "rest")))) (EBlock (DoLet false false (PVar "ends") (EApp (EApp (EMethodRef "map") (EVar "cutEnd")) (EVar "cs"))) (DoLet false false (PVar "starts") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "cutStart")) (EVar "rest")) (EListLit (EApp (EVar "stringLength") (EVar "s"))))) (DoExpr (EApp (EApp (EVar "anyList") (ELam ((PTuple (PVar "a") (PVar "b"))) (EBinOp "/=" (EApp (EVar "trim") (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EVar "s"))) (ELit (LString ""))))) (EApp (EApp (EVar "zip") (EVar "ends")) (EVar "starts"))))))
(DTypeSig false "cutEnd" (TyFun (TyCon "Cut") (TyCon "Int")))
(DFunDef false "cutEnd" ((PCon "Cut" PWild PWild (PVar "e") PWild)) (EVar "e"))
(DTypeSig false "cutEdit" (TyFun (TyCon "Bool") (TyFun (TyCon "Cut") (TyApp (TyCon "Option") (TyCon "FixEdit")))))
(DFunDef false "cutEdit" ((PVar "pad") (PCon "Cut" (PVar "l") (PVar "c") (PVar "e") (PVar "text"))) (EIf (EApp (EVar "not") (EVar "pad")) (EApp (EVar "Some") (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "l")) (EVar "c")) (EVar "l")) (EVar "e"))) (EVar "text"))) (EIf (EBinOp "<=" (EApp (EVar "stringLength") (EVar "text")) (EBinOp "-" (EVar "e") (EVar "c"))) (EApp (EVar "Some") (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "l")) (EVar "c")) (EVar "l")) (EVar "e"))) (EBinOp "++" (EVar "text") (EApp (EApp (EVar "repeat") (EBinOp "-" (EBinOp "-" (EVar "e") (EVar "c")) (EApp (EVar "stringLength") (EVar "text")))) (ELit (LString " ")))))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "limitFor" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Span") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "limitFor" ((PCon "Some" (PVar "w")) (PVar "sp") (PVar "l")) (EIf (EBinOp "<" (EVar "l") (EVar "w")) (EBinOp "-" (EVar "w") (ELit (LInt 1))) (EFieldAccess (EVar "sp") "spLast")))
(DFunDef false "limitFor" ((PCon "None") (PVar "sp") PWild) (EFieldAccess (EVar "sp") "spLast"))
(DTypeSig false "nextCodeLine" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "nextCodeLine" ((PVar "plan") (PVar "dropped") (PVar "l0") (PVar "limit")) (ELetGroup ((lgb "go" (clause ((PVar "l")) (EIf (EBinOp ">" (EVar "l") (EVar "limit")) (EVar "None") (EIf (EBinOp "||" (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "l")))) (EVar "dropped")) (EApp (EVar "not") (EApp (EVar "isCode") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l"))))) (EApp (EVar "go") (EBinOp "+" (EVar "l") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EVar "Some") (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))) (EApp (EVar "go") (EBinOp "+" (EVar "l0") (ELit (LInt 1))))))
(DTypeSig false "headEdit" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "Int") (TyCon "Span")) (TyApp (TyCon "Option") (TyCon "FixEdit")))))))))
(DFunDef false "headEdit" ((PVar "plan") (PVar "dropped") (PVar "merge") (PVar "goName") (PVar "fresh") (PTuple (PVar "k") (PVar "sp"))) (ELet false (PVar "s") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EFieldAccess (EVar "sp") "spFirst")) (ELet false (PVar "he") (EApp (EVar "headEnd") (EVar "sp")) (ELet false (PVar "changing") (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EBinOp "++" (ELit (LString " ")) (EApp (EApp (EApp (EVar "atomText") (EVar "plan")) (EVar "sp")) (EVar "i"))))) (EApp (EVar "restOf") (EVar "plan"))) (ELet false (PVar "goHead") (EBinOp "++" (EVar "goName") (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "changing")) (ELit (LInt 0))) (ELit (LString " ()")) (EApp (EVar "stringConcat") (EVar "changing")))) (ELet false (PVar "d") (EBinOp "-" (EBinOp "+" (ELit (LInt 4)) (EApp (EVar "stringLength") (EVar "goHead"))) (EVar "he")) (EApp (EApp (EMethodRef "andThen") (EApp (EDictApp "guard") (EBinOp "<=" (EVar "d") (ELit (LInt 4))))) (ELam (PWild) (ELet false (PVar "post") (EApp (EApp (EApp (EVar "stringSlice") (EVar "he")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (ELet false (PVar "at") (EBinOp "-" (EBinOp "+" (EVar "he") (EApp (EVar "stringLength") (EVar "post"))) (EApp (EVar "stringLength") (EApp (EVar "trimLeft") (EVar "post")))) (ELet false (PVar "lead") (EApp (EVar "trim") (EVar "post")) (ELet false (PVar "below") (EApp (EApp (EApp (EApp (EVar "nextCodeLine") (EVar "plan")) (EVar "dropped")) (EFieldAccess (EVar "sp") "spFirst")) (EApp (EApp (EApp (EVar "limitFor") (EVar "merge")) (EVar "sp")) (EFieldAccess (EVar "sp") "spFirst"))) (ELet false (PVar "pad") (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "lead") (ELit (LString ""))) (EBinOp "/=" (EVar "lead") (ELit (LString "=")))) (EMatch (EVar "below") (arm (PCon "Some" (PVar "b")) () (EBinOp ">" (EBinOp "+" (EApp (EApp (EVar "indentAt") (EFieldAccess (EVar "plan") "plLines")) (EVar "b")) (ELit (LInt 4))) (EBinOp "+" (EVar "at") (EVar "d")))) (arm (PCon "None") () (EVar "False")))) (ELet false (PVar "padding") (EIf (EVar "pad") (EApp (EApp (EVar "repeat") (EBinOp "-" (ELit (LInt 4)) (EVar "d"))) (ELit (LString " "))) (ELit (LString ""))) (ELet false (PVar "prefix") (EIf (EBinOp "==" (EVar "k") (ELit (LInt 0))) (EBinOp "++" (EApp (EApp (EApp (EVar "outerLine") (EVar "plan")) (EVar "goName")) (EVar "fresh")) (ELit (LString "\n  where\n    "))) (ELit (LString "    "))) (EApp (EVar "Some") (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EFieldAccess (EVar "sp") "spFirst")) (ELit (LInt 0))) (EFieldAccess (EVar "sp") "spFirst")) (EVar "he"))) (EBinOp "++" (EBinOp "++" (EVar "prefix") (EVar "goHead")) (EVar "padding")))))))))))))))))))
(DTypeSig false "outerLine" (TyFun (TyCon "Plan") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "outerLine" ((PVar "plan") (PVar "goName") (PVar "fresh")) (EBlock (DoLet false false (PVar "params") (EApp (EApp (EVar "outerParams") (EVar "plan")) (EVar "fresh"))) (DoLet false false (PVar "args") (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "fresh")) (ELit (LInt 0))) (ELit (LString " ()")) (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString " ")) (EVar "_s")))) (EVar "fresh"))))) (DoLet false false (PVar "spaced") (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString " ")) (EVar "_s")))) (EVar "params")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "plan") "plName"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "spaced"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EVar "goName"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "args"))) (ELit (LString ""))))))
(DTypeSig false "outerParams" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "outerParams" ((PVar "plan") (PVar "fresh")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "paramAt") (EVar "plan")) (EVar "fresh")) (EVar "i")))) (ERangeList (ELit (LInt 0)) (EBinOp "-" (EFieldAccess (EVar "plan") "plArity") (ELit (LInt 1))) true)))
(DTypeSig false "paramAt" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "paramAt" ((PVar "plan") (PVar "fresh") (PVar "i")) (EMatch (EApp (EApp (EVar "lookup") (EVar "i")) (EApp (EApp (EVar "zip") (EFieldAccess (EVar "plan") "plShared")) (EFieldAccess (EVar "plan") "plNames"))) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EApp (EVar "optionOr") (ELit (LString "_"))) (EApp (EApp (EVar "lookup") (EVar "i")) (EApp (EApp (EVar "zip") (EApp (EVar "restOf") (EVar "plan"))) (EVar "fresh")))))))
(DTypeSig false "shiftEdits" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Span") (TyApp (TyCon "List") (TyCon "FixEdit")))))))
(DFunDef false "shiftEdits" ((PVar "plan") (PVar "dropped") (PVar "merge") (PVar "sp")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "l")) (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "l")) (ELit (LInt 0))) (EVar "l")) (ELit (LInt 0)))) (ELit (LString "    "))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "l")) (EApp (EApp (EApp (EApp (EVar "shifted") (EVar "plan")) (EVar "dropped")) (EVar "merge")) (EVar "l")))) (ERangeList (EBinOp "+" (EFieldAccess (EVar "sp") "spFirst") (ELit (LInt 1))) (EFieldAccess (EVar "sp") "spLast") true))))
(DTypeSig false "shifted" (TyFun (TyCon "Plan") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "shifted" ((PVar "plan") (PVar "dropped") (PVar "merge") (PVar "l")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "l")))) (EVar "dropped"))) (EBinOp "/=" (EApp (EVar "trim") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l"))) (ELit (LString "")))) (EMatch (EVar "merge") (arm (PCon "Some" (PVar "w")) () (EBinOp "<" (EVar "l") (EVar "w"))) (arm (PCon "None") () (EVar "True")))))
(DTypeSig false "dropLine" (TyFun (TyCon "Plan") (TyFun (TyCon "Int") (TyCon "FixEdit"))))
(DFunDef false "dropLine" ((PVar "plan") (PVar "l")) (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EBinOp "-" (EVar "l") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EBinOp "-" (EVar "l") (ELit (LInt 1)))))) (EVar "l")) (EApp (EVar "stringLength") (EApp (EApp (EVar "lineText") (EFieldAccess (EVar "plan") "plLines")) (EVar "l"))))) (ELit (LString ""))))
