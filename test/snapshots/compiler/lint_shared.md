# META
source_lines=958
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_shared.mdk — helpers used by more than one lint module:
-- the rule-name constants, location and trimming helpers, the suppression
-- directive parser, and the stdlib path predicates.

import frontend.ast.{
  Loc(..), Expr(..), Decl(..), noBinderId, noDeclLoc, Ty(..), Pat(..),
  UseMember(..), Guard(..), Arm(..), ImplMethod(..), DoStmt(..), Section(..),
  InterpPart(..), GuardArm(..), FieldAssign(..), LetBind(..), FunClause(..)
}
import frontend.parser.{Positions(..), DeclPos, positionsDecls, declPosLine}
import support.util.{
  contains, filterList, splitOnChar, joinWith, startsWith, listLen, anyList,
  joinNl, dedupBy
}
import list.{sortBy, last}
import support.path.{stripMdk}
import regex.{Regex, mustCompile, find as reFind, escape, isMatch}
import frontend.lexer.{Comment, commentLine, commentText, commentCol}
import tools.lint_core.{DirScope(..), Directive(..), Finding(..)}
import frontend.desugar.{mapChildren}
import hash_map.{HashMap, new, setInPlace}
import tools.printer.{exprToString}
import ir.sexp.{exprSexp}
import frontend.exhaust.{Oracle, oGetCtorSiblings}

-- ── rule names (kept in sync between the Rule entry and its Findings) ─────────
export
ruleNameMatchParam : String
ruleNameMatchParam = "rule-match-on-param"

export
ruleNameDerivable : String
ruleNameDerivable = "rule-hand-rolled-derivable"

export
ruleNameStdlibReimpl : String
ruleNameStdlibReimpl = "rule-stdlib-reimpl"

export
ruleNameDuplicateBody : String
ruleNameDuplicateBody = "rule-duplicate-body"

export
ruleNameBindThenDestructure : String
ruleNameBindThenDestructure = "rule-bind-then-destructure"

export
ruleNameLambdaSection : String
ruleNameLambdaSection = "rule-lambda-section"

export
ruleNameIfMaxMin : String
ruleNameIfMaxMin = "rule-if-max-min"

export
ruleNameAndThenPureMap : String
ruleNameAndThenPureMap = "rule-andthen-pure-map"

export
ruleNameDestructureInParam : String
ruleNameDestructureInParam = "rule-destructure-in-param"

export
ruleNameMissingSignature : String
ruleNameMissingSignature = "rule-missing-signature"

export
ruleNameNotEq : String
ruleNameNotEq = "rule-not-eq"

export
ruleNameBoolSimplify : String
ruleNameBoolSimplify = "rule-bool-simplify"

export
ruleNameRemParity : String
ruleNameRemParity = "rule-rem-parity"

export
ruleNameDoubleReverse : String
ruleNameDoubleReverse = "rule-double-reverse"

export
ruleNameWhenUnless : String
ruleNameWhenUnless = "rule-when-unless"

export
ruleNameComplementPredicate : String
ruleNameComplementPredicate = "rule-complement-predicate"

export
ruleNameMatchToMap : String
ruleNameMatchToMap = "rule-match-to-map"

export
ruleNameBindChainToDo : String
ruleNameBindChainToDo = "rule-bind-chain-to-do"

export
ruleNameDeadCode : String
ruleNameDeadCode = "rule-dead-code"

export
ruleNameConcatToInterp : String
ruleNameConcatToInterp = "rule-concat-to-interp"

export
ruleNameSelfShadowExtern : String
ruleNameSelfShadowExtern = "rule-self-shadow-extern"

export
ruleNamePreferAssignOp : String
ruleNamePreferAssignOp = "rule-prefer-assign-op"

export
ruleNamePromissoryReader : String
ruleNamePromissoryReader = "rule-promissory-reader"

export
ruleNameOrElseStaircase : String
ruleNameOrElseStaircase = "rule-orelse-staircase"

export
ruleNameCloneType : String
ruleNameCloneType = "rule-clone-type"

export
ruleNameClauseMap : String
ruleNameClauseMap = "rule-clause-map"

export
ruleNameDirectiveReason : String
ruleNameDirectiveReason = "rule-directive-reason"

export
ruleNameRegexLiteral : String
ruleNameRegexLiteral = "rule-regex-literal"

export
ruleNameTestBoolLiteralEqual : String
ruleNameTestBoolLiteralEqual = "rule-test-bool-literal-equal"

export
ruleNameTestEqualInTrue : String
ruleNameTestEqualInTrue = "rule-test-equal-in-true"

export
ruleNameTestPreludeShadow : String
ruleNameTestPreludeShadow = "rule-test-prelude-shadow"

-- Is the target file part of the stdlib itself?  A `stdlib` path SEGMENT (so
-- `stdlib/core.mdk`, `./stdlib/list.mdk`, `/abs/medaka/stdlib/map.mdk` all match,
-- but `test/lint_fixtures/foo.mdk` does not).
--
-- `rule-hand-rolled-derivable` uses this blanket path test as-is: a hand-
-- written `impl Eq/Ord/Debug` anywhere inside the stdlib is legitimate
-- regardless of which stdlib file it lives in or which type it's for
-- (bootstrap ordering, a ctor/class name clash, or a non-structural instance
-- whose `deriving` would be semantically WRONG) — the exemption there is
-- "this is stdlib code," not "this file owns this particular name."
--
-- `rule-stdlib-reimpl` does NOT use this: its exemption is per (path, name)
-- OWNERSHIP, not per path — see `firstMatchingModule` below.  A blanket path skip
-- would wrongly exempt a stdlib file that only CONSUMES a name it doesn't own
-- (`stdlib/toml.mdk` reimplementing `list.reverse` as `listReverse`) right
-- alongside the file that legitimately defines it.
export
isStdlibPath : String -> Bool
isStdlibPath path = contains "stdlib" (splitOnChar '/' path)

-- The import id a path under `stdlib/` names: the segments after the last
-- `stdlib` segment, dot-joined, so `stdlib/crypto/hmac.mdk` is `crypto.hmac`.
-- `None` for a path with no `stdlib` segment.
export
stdlibModuleOf : String -> Option String
stdlibModuleOf path = stdlibModuleGo (splitOnChar '/' (stripMdk path)) None

stdlibModuleGo : List String -> Option String -> Option String
stdlibModuleGo [] found = found
stdlibModuleGo (seg :: rest) found =
  if seg == "stdlib" then
    stdlibModuleGo rest (Some (joinWith "." rest))
  else
    stdlibModuleGo rest found

-- Sorted, duplicate-free `String` list.  Local to lint: `support.util.sortUniqS`
-- is an insertion sort and these call sites run once per file or per def.
export
sortUniqS : List String -> List String
sortUniqS xs = dedupSortedS (sortBy stringCompare xs)

dedupSortedS : List String -> List String
dedupSortedS (a :: b :: rest) =
  if a == b then dedupSortedS (b :: rest) else a :: dedupSortedS (b :: rest)
dedupSortedS xs = xs

export
zipDeclPos : List Decl -> List DeclPos -> List (Decl, DeclPos)
zipDeclPos [] _ = []
zipDeclPos _ [] = []
zipDeclPos (d :: ds) (p :: ps) = (d, p) :: zipDeclPos ds ps

export
collectDirectives : List Comment -> List Directive
collectDirectives cmts = flatMap (c => dirToList (parseDirective c)) cmts

dirToList : Option Directive -> List Directive
dirToList None = []
dirToList (Some d) = [d]

-- A comment becomes a directive iff it is a `--` line comment whose trimmed body
-- (after the `--`) starts with a directive keyword.  `commentText` includes the
-- delimiters, so we strip a leading `--` then re-trim.
export
parseDirective : Comment -> Option Directive
parseDirective c =
  let body = trimWs (commentText c)
  if startsWith "--" body then
    parseDirectiveBody
      (commentLine c)
      (trimWs (stringSlice 2 (stringLength body) body))
  else
    None

lintDisableNextLineRe : Regex
lintDisableNextLineRe = keywordRe "lint-disable-next-line"

lintDisableLineRe : Regex
lintDisableLineRe = keywordRe "lint-disable-line"

lintDisableFileRe : Regex
lintDisableFileRe = keywordRe "lint-disable-file"

-- `kw` at the start of `s`, followed by end-of-string or whitespace (so
-- `lint-disable-lineXYZ` does NOT match `lint-disable-line`), with the
-- remainder captured in group 1.
keywordRe : String -> Regex
keywordRe kw = mustCompile ("^" ++ escape kw ++ "($|[ \\t].*)$")

parseDirectiveBody : Int -> String -> Option Directive
parseDirectiveBody line s =
  if startsWith "lint-" s then parseDirectiveKeyword line s else None

-- Every directive keyword begins `lint-`, so `parseDirectiveBody` only reaches
-- the regexes for text that can match one.
parseDirectiveKeyword : Int -> String -> Option Directive
parseDirectiveKeyword line s = match matchKeyword lintDisableNextLineRe s
  Some names => Some (Directive (DScopeLine (line + 1)) (parseRuleNames names))
  None => match matchKeyword lintDisableLineRe s
    Some names => Some (Directive (DScopeLine line) (parseRuleNames names))
    None =>
      map
        (names => Directive DScopeFile (parseRuleNames names))
        (matchKeyword lintDisableFileRe s)

-- If `s` matches `re` (`keywordRe`'s keyword-plus-boundary shape), return the
-- trimmed remainder (the rule-name list) captured in group 1; else None.
matchKeyword : Regex -> String -> Option String
matchKeyword re s = match reFind re s
  Some m => match m.groups
    (Some g) :: _ => Some (trimWs g.text)
    _ => None
  None => None

-- Split a rule-name list on commas and/or spaces, dropping empty fragments.
parseRuleNames : String -> List String
parseRuleNames s =
  filterList nonEmptyStr (flatMap (splitOnChar ' ') (splitOnChar ',' s))

nonEmptyStr : String -> Bool
nonEmptyStr n = n /= ""

-- trim ASCII whitespace from both ends. Narrower than stdlib `string.trim`
-- (space/tab/CR/LF only, vs. `isSpace`'s broader VT/FF) — inputs here are
-- lint-directive comment bodies, where a stray VT/FF is plausible source
-- text and swapping to `trim` would silently change what counts as a
-- directive boundary. Kept intentionally; see #2349.
export
trimWs : String -> String
-- lint-disable-next-line rule-stdlib-reimpl
trimWs s =
  let cs = stringToChars s
  let n = arrayLength cs
  let a = trimWsStart cs n 0
  let b = trimWsEnd cs a n
  stringSlice a b s

trimWsStart : Array Char -> Int -> Int -> Int
trimWsStart cs n i
  | i >= n = i
  | isWsChar (arrayGetUnsafe i cs) = trimWsStart cs n (i + 1)
  | otherwise = i

trimWsEnd : Array Char -> Int -> Int -> Int
trimWsEnd cs a n
  | n <= a = a
  | isWsChar (arrayGetUnsafe (n - 1) cs) = trimWsEnd cs a (n - 1)
  | otherwise = n

isWsChar : Char -> Bool
isWsChar c = c == ' ' || c == '\t' || c == '\r' || c == '\n'

-- ── small AST helpers ─────────────────────────────────────────────────────────

-- strip the transparent ELoc wrapper(s) to reach the real node
export
unwrapLoc : Expr -> Expr
unwrapLoc (ELoc _ e) = unwrapLoc e
unwrapLoc e = e

-- ── per-decl source locations (Task B) ─────────────────────────────────────────
-- `Positions` carries one `DeclPos` per top-level decl, parallel to the decl
-- list.  We pair each decl with `Some (Loc … startLine 1 startLine 1)` so a rule
-- can stamp its finding with the decl's REAL start line (decls themselves carry
-- no `Loc`).  This is the only location source the carat path (CLI) needs; the
-- golden line format (`findingLine`) ignores it, so goldens stay location-stripped.
export
declLocList : Positions -> List Decl -> List (Decl, Option Loc)
declLocList pos prog = zipDeclLoc prog (positionsDecls pos)

zipDeclLoc : List Decl -> List DeclPos -> List (Decl, Option Loc)
zipDeclLoc [] _ = []
zipDeclLoc (d :: ds) [] = (d, None) :: zipDeclLoc ds []
zipDeclLoc (d :: ds) (p :: ps) = (d, Some (declPosToLoc p)) :: zipDeclLoc ds ps

declPosToLoc : DeclPos -> Loc
declPosToLoc p = let l = declPosLine p in Loc "" l 1 l 1

-- ── helpers used by two or more rules ───────────────────────────────────────────

export
isBareParam : String -> Pat -> Bool
isBareParam p (PVar q _ _) = p == q
isBareParam _ _ = False

-- ── SHARED detector (rule-match-on-param + rule-destructure-in-param) ──────────
-- The function-clause body (under `ELoc`) is a `match <p>` whose scrutinee is a
-- bare-`PVar p` parameter at position `k` in `pats`.  Returns `(p, k, arms)`.
-- Arm-count / guard / irrefutability gates live in each rule.  `paramIndex`
-- only yields `Some` when a bare `PVar p` parameter exists, so a `Some` result
-- already guarantees the scrutinee is a bare parameter.
export
matchBodyOnBareParam : List Pat -> Expr -> Option (String, Int, List Arm)
matchBodyOnBareParam pats body = match unwrapLoc body
  EMatch scrut arms => match unwrapLoc scrut
    EVar p => map (k => (p, k, arms)) (paramIndex p pats)
    _ => None
  _ => None

export
patIsWild : Pat -> Bool
patIsWild PWild = True
patIsWild _ = False

-- position of the first bare-`PVar p` parameter
paramIndex : String -> List Pat -> Option Int
paramIndex p pats = paramIndexGo p pats 0

paramIndexGo : String -> List Pat -> Int -> Option Int
paramIndexGo _ [] _ = None
paramIndexGo p (pat :: rest) i
  | isBareParam p pat = Some i
  | otherwise = paramIndexGo p rest (i + 1)

-- one clause: replace the param at position k with the arm pattern, body = arm
-- rhs.  Special case: a `PWild` arm whose body references the scrutinee `p` is
-- rendered with `PVar p` instead of `_`, re-binding the scrutinee so the body's
-- reference stays valid (the bail in `matchParamFixVar` has already rejected any
-- UNSAFE — non-wildcard — mention).
export
armToClause : Bool -> String -> String -> List Pat -> Int -> Arm -> Decl
armToClause vis name p pats k (Arm pat _ body) =
  let cpat =
    if patIsWild pat && wholeWordIn p (exprToString body) then
      PVar p (Loc "" 0 0 0 0) noBinderId
    else
      pat
  DFunDef vis name (replaceAt k cpat pats) body noDeclLoc noBinderId

replaceAt : Int -> a -> List a -> List a
replaceAt _ _ [] = []
replaceAt 0 x (_ :: rest) = x :: rest
replaceAt n x (y :: rest) = y :: replaceAt (n - 1) x rest

-- whole-word (identifier-token) occurrence of `name` in `s`.  Boundaries are any
-- non-identifier char (isAlnum covers alnum/_/').  Over-matches into string
-- literals etc. — that only makes the fix gate MORE conservative, never less.
--
-- The boundary is a hand-built CONSUMING class around the escaped name
-- (`(?:^|[^A-Za-z0-9_'])…(?:$|[^A-Za-z0-9_'])`) rather than the engine's
-- built-in `\b`, which is ASCII `[A-Za-z0-9_]` only and would narrow a name
-- ending in `'`. `isMatch` tries every start position independently (it is
-- not a left-to-right non-overlapping scan), so this is safe for a plain
-- existence check even though the class is consuming.
export
wholeWordIn : String -> String -> Bool
wholeWordIn name s = isMatch (mustCompile (wholeWordPattern name)) s

wholeWordPattern : String -> String
wholeWordPattern name =
  "(?:^|[^A-Za-z0-9_'])" ++ escape name ++ "(?:$|[^A-Za-z0-9_'])"

-- the constructor `c` belongs to a type declared (or built-in) with EXACTLY one
-- constructor — so a `c …` pattern can never fail to match.  An unknown ctor
-- (its type isn't visible in this file) is NOT provably single → False (SKIP).
export
ctorIsSingle : Oracle -> String -> Bool
ctorIsSingle orc c = match oGetCtorSiblings orc c
  -- the constructor's OWN declaration's set, not a round trip through its
  -- type's spelling, which two same-named types share (#3465)
  Some ctors => listLen ctors == 1
  None => False

export
tyHeadName : Ty -> Option String
tyHeadName (TyCon { tyConName = n }) = Some n
tyHeadName (TyApp f _) = tyHeadName f
tyHeadName _ = None

export
topDefNameL : (Decl, Option Loc) -> List (String, Option Loc)
topDefNameL (DFunDef _ name _ _ _ _, loc) = [(name, loc)]
topDefNameL (DAttrib _ d, loc) = topDefNameL (d, loc)
topDefNameL _ = []

-- keep the first (name, loc) per distinct name, preserving order
-- (#242: order-preserving dedup on the name key → shared support.util.dedupBy)
export
dedupeNamesLoc : List (String, Option Loc) -> List (String, Option Loc)
dedupeNamesLoc xs = dedupBy fst xs

export
clausesOf : String -> List Decl -> List (List Pat, Expr)
clausesOf _ [] = []
clausesOf name ((DAttrib _ d) :: rest) = clausesOf name (d :: rest)
clausesOf name ((DFunDef _ n ps body _ _) :: rest)
  | n == name = (ps, body) :: clausesOf name rest
  | otherwise = clausesOf name rest
clausesOf name (_ :: rest) = clausesOf name rest

-- The parser wraps every expr production in a transparent `ELoc` (span info
-- for diagnostics) — mirrors `frontend/parser.mdk`'s own private `stripLoc`,
-- unexported there, so a shape match here must peel it locally.
export
stripELoc : Expr -> Expr
stripELoc (ELoc _ e) = stripELoc e
stripELoc e = e

-- Flattens a curried application spine: `f a b` is `EApp (EApp f a) b`.
export
appSpineOf : Expr -> (Expr, List Expr)
appSpineOf e = appSpineGo e []

appSpineGo : Expr -> List Expr -> (Expr, List Expr)
appSpineGo e acc = match stripELoc e
  EApp f a => appSpineGo f (a :: acc)
  other => (other, acc)

export
paramNameOf : Pat -> Option String
paramNameOf (PVar n _ _) = Some n
paramNameOf _ = None

export
memberLocalIfOrigin : String -> UseMember -> Option String
memberLocalIfOrigin stdName (UseMember origin _ _ alias) =
  if origin == stdName then
    Some (match alias
      Some a => a
      None => origin)
  else
    None

export
lastSegOf : List String -> String
lastSegOf [] = ""
lastSegOf [x] = x
lastSegOf (_ :: rest) = lastSegOf rest

-- immediate sub-expressions of an expr (order irrelevant; used to recurse).
export
childExprs : Expr -> List Expr
childExprs (ELoc _ e) = [e]
childExprs (EDoOrigin _ e) = [e]
childExprs (EApp f x) = [f, x]
childExprs (ELam _ b) = [b]
childExprs (ELet _ _ _ e1 e2) = [e1, e2]
childExprs (EMatch s arms) = s :: flatMap armExprs arms
childExprs (EIf c t el) = [c, t, el]
childExprs (EBinOp _ a b _) = [a, b]
childExprs (EUnOp _ a _) = [a]
childExprs (EInfix _ a b) = [a, b]
childExprs (EFieldAccess e _ _) = [e]
childExprs (ETuple es) = es
childExprs (EListLit es) = es
childExprs (EArrayLit es) = es
childExprs (ERangeList lo hi _) = [lo, hi]
childExprs (ERangeArray lo hi _) = [lo, hi]
childExprs (ESlice e lo hi _) = [e, lo, hi]
childExprs (ELetGroup binds body) = flatMap letBindExprs binds ++ [body]
childExprs (ESection s) = sectionExprs s
childExprs (EIndex a i) = [a, i]
childExprs (EAnnot e _) = [e]
childExprs (EHeadAnnot e _) = [e]
childExprs (EBlock stmts) = flatMap stmtExprs stmts
childExprs (EDo _ stmts) = flatMap stmtExprs stmts
childExprs (EStringInterp parts) = flatMap interpPartExprs parts
childExprs (EGuards arms) = flatMap guardArmExprs arms
childExprs (ERecordCreate _ fs) = map fieldAssignExpr fs
childExprs (ERecordUpdate e fs _) = e :: map fieldAssignExpr fs
childExprs (EVariantUpdate _ e fs) = e :: map fieldAssignExpr fs
childExprs (EMapLit _ kvs) = flatMap kvExprs kvs
childExprs (ESetLit _ es) = es
childExprs (EAsPat _ e) = [e]
childExprs (EOrPat es) = es
childExprs _ = []

armExprs : Arm -> List Expr
armExprs (Arm _ gs body) = flatMap guardExprs gs ++ [body]

guardExprs : Guard -> List Expr
guardExprs (GBool e) = [e]
guardExprs (GBind _ e) = [e]

export
stmtExprs : DoStmt -> List Expr
stmtExprs (DoExpr e) = [e]
stmtExprs (DoBind _ e) = [e]
stmtExprs (DoLet _ _ _ e _) = [e]
stmtExprs (DoAssign _ e) = [e]
stmtExprs (DoFieldAssign _ _ e) = [e]

letBindExprs : LetBind -> List Expr
letBindExprs (LetBind _ clauses _ _) = flatMap funClauseExprs clauses

funClauseExprs : FunClause -> List Expr
funClauseExprs (FunClause _ body) = [body]

sectionExprs : Section -> List Expr
sectionExprs (SecBare _) = []
sectionExprs (SecRight _ e) = [e]
sectionExprs (SecLeft e _) = [e]

interpPartExprs : InterpPart -> List Expr
interpPartExprs (InterpStr _) = []
interpPartExprs (InterpExpr e) = [e]

guardArmExprs : GuardArm -> List Expr
guardArmExprs (GuardArm gs body) = flatMap guardExprs gs ++ [body]

fieldAssignExpr : FieldAssign -> Expr
fieldAssignExpr (FieldAssign _ e) = e

kvExprs : (Expr, Expr) -> List Expr
kvExprs (k, v) = [k, v]

-- an `EVar x` leaf (under any ELoc wrapper)
export
isEVarNamed : String -> Expr -> Bool
isEVarNamed x e = match unwrapLoc e
  EVar w => w == x
  _ => False

-- does `x` occur (conservatively: anywhere) in `e`?  A nested binder re-binding
-- `x` only makes this OVER-count → we bail (safe), never rewrite unsoundly.
export
mentionsVar : String -> Expr -> Bool
mentionsVar x e = match unwrapLoc e
  EVar w => w == x
  e2 => anyList (mentionsVar x) (childExprs e2)

export
implMethodsBodyKey : List ImplMethod -> String
implMethodsBodyKey ms = joinNl (map implMethodBodySexp ms)

implMethodBodySexp : ImplMethod -> String
implMethodBodySexp (ImplMethod _ _ body) = exprSexp body

-- if `arg` is `f x` — x as the SOLE final argument, `f` not mentioning x —
-- return `Some f` (the eta-reduced function); else `None`.
export
andThenEtaFn : String -> Expr -> Option Expr
andThenEtaFn x arg = match unwrapLoc arg
  EApp f lastArg if isEVarNamed x lastArg && not (mentionsVar x f) => Some f
  _ => None

-- ══ batch of local-expression simplification rules (shared generic walk) ═══════
-- The five rules below (`rule-not-eq`, `rule-bool-simplify`, `rule-rem-parity`,
-- `rule-double-reverse`, `rule-when-unless`) are all pure LOCAL-NODE rewrites: a
-- single AST node is recognised and replaced by an equivalent one, anywhere in a
-- decl body.  Rather than each hand-rolling the ~90-line whole-tree walk the
-- earlier rules use (`rewriteLamExpr` &c.), they share ONE generic bottom-up
-- rewriter (`mapChildExprs`/`rewriteExprBU`) plus generic check/fix drivers.  A
-- rule supplies only:
--   * a detector `Expr -> Option Expr` matching the RAW node (NOT under its outer
--     `ELoc` — `childExprs` descends through `ELoc`, so matching the wrapper too
--     would double-count; mirrors `andThenPureMapHitOf`).  It returns the
--     rewritten node.
--   * an excluded-decl-name predicate (a rule whose target idiom IS the body of a
--     stdlib primitive it rewrites TO — `isEven`/`isOdd` for rule-rem-parity,
--     `when`/`unless` for rule-when-unless — must skip that primitive's own
--     definition, or it would rewrite the body to an infinite self-reference).
-- Every rewrite is EXACTLY equivalent (see each rule's soundness note), so the
-- self-compile fixpoint stays byte-identical after the tree is fixed.

-- rebuild every immediate child expr with `g`: the shared one-level step
-- (`desugar.mapChildren`) plus the parser's as-pattern node, which the other
-- whole-tree rewriters here (`rewriteLamExpr` &c.) descend into as well.
export
mapChildExprs : (Expr -> Expr) -> Expr -> Expr
mapChildExprs g (EAsPat x e) = EAsPat x (g e)
mapChildExprs g (EOrPat es) = EOrPat (map g es)
mapChildExprs g e = mapChildren g e

-- generic bottom-up rewrite: rebuild children first, THEN apply the node-local
-- transform `f` at this (child-rewritten) node.  Bottom-up so a rewrite exposed by
-- an inner one (`not (not (not x))`) is re-collapsed by the enclosing node.
export
rewriteExprBU : (Expr -> Expr) -> Expr -> Expr
rewriteExprBU f e = f (mapChildExprs (rewriteExprBU f) e)

-- turn a detector into a total node transform (identity where it does not fire).
export
detApply : (Expr -> Option Expr) -> Expr -> Expr
detApply det e = match det e
  Some e2 => e2
  None => e

-- ── generic check driver ──────────────────────────────────────────────────────
-- Collect one finding per detector hit anywhere in a decl body, skipping decls
-- whose name the exclusion predicate rejects.  `mkFinding loc rewritten` builds
-- the rule's message from the rewritten node (for a helpful "prefer …" hint).
-- `loc` here is the HIT's own location (#649) — the nearest `ELoc` enclosing the
-- matched expression, tracked by `collectRewrites` as it descends — falling back
-- to the decl's location only for a hit with no enclosing `ELoc` on its path at
-- all (the decl-level `loc` threaded in as the initial "nearest so far").
export
exprRuleFindings : (String -> Bool) ->
  (Expr -> Option Expr) ->
  (Option Loc -> Expr -> Finding) ->
  Positions ->
  List Decl ->
  List Finding
exprRuleFindings excl det mkFinding pos prog =
  flatMap (exprRuleDeclL excl det mkFinding) (declLocList pos prog)

exprRuleDeclL : (String -> Bool) ->
  (Expr -> Option Expr) ->
  (Option Loc -> Expr -> Finding) ->
  (Decl, Option Loc) ->
  List Finding
exprRuleDeclL excl det mkFinding (d, loc) =
  map ((hitLoc, hit) => mkFinding hitLoc hit) (declRewriteHits excl det loc d)

declRewriteHits : (String -> Bool) ->
  (Expr -> Option Expr) ->
  Option Loc ->
  Decl ->
  List (Option Loc, Expr)
declRewriteHits excl det loc (DFunDef _ name _ body _ _)
  | excl name = []
  | otherwise = collectRewrites loc det body
declRewriteHits _ det loc (DImpl { methods, ... }) =
  flatMap (implMethodRewriteHits loc det) methods
declRewriteHits excl det loc (DAttrib _ d) = declRewriteHits excl det loc d
declRewriteHits _ _ _ _ = []

implMethodRewriteHits : Option Loc ->
  (Expr -> Option Expr) ->
  ImplMethod ->
  List (Option Loc, Expr)
implMethodRewriteHits loc det (ImplMethod _ _ body) =
  collectRewrites loc det body

-- every detector hit anywhere in the tree, paired with ITS OWN location (#649).
-- `curLoc` tracks the nearest enclosing `ELoc` seen so far as we descend,
-- starting from the decl's location (the fallback for a hit with no `ELoc` on
-- its path).  The detector matches the RAW node — an `ELoc`-wrapped node
-- contributes nothing here, `childExprs` descends into it, and its `Loc`
-- becomes the new `curLoc` for everything beneath it — so each real node is
-- counted exactly once, now stamped with the location of the innermost `ELoc`
-- that actually wraps it (mirrors `collectLamSections`).
export
collectRewrites : Option Loc ->
  (Expr -> Option Expr) ->
  Expr ->
  List (Option Loc, Expr)
collectRewrites _ det (ELoc l e) = collectRewrites (Some l) det e
collectRewrites curLoc det e =
  optExprToLocList curLoc (det e)
    ++ flatMap (collectRewrites curLoc det) (childExprs e)

optExprToLocList : Option Loc -> Option Expr -> List (Option Loc, Expr)
optExprToLocList _ None = []
optExprToLocList loc (Some x) = [(loc, x)]

-- ── generic fix driver ────────────────────────────────────────────────────────
-- Rebuild the decl body applying `f` bottom-up; return `Some [newDecl]` only when
-- the location-stripped sexp changed (same change-detection the other fixers use).
-- Honors the excluded-decl-name predicate.
export
exprRuleFix : (String -> Bool) -> (Expr -> Expr) -> Decl -> Option (List Decl)
exprRuleFix excl f (DFunDef vis name pats body site bid)
  | excl name = None
  | otherwise =
    let body2 = rewriteExprBU f body
    if exprSexp body2 == exprSexp body then
      None
    else
      Some [DFunDef vis name pats body2 site bid]
exprRuleFix excl f (DAttrib a d) = match exprRuleFix excl f d
  Some [d2] => Some [DAttrib a d2]
  _ => None
exprRuleFix _ f (d@(DImpl { implOrigin = _, methods })) =
  let methods2 = map (fixImplMethodWith f) methods
  if implMethodsBodyKey methods2 == implMethodsBodyKey methods then
    None
  else
    -- #1110: record UPDATE — re-synthesising would reset the acquired identity.
    Some [DImpl { d | methods = methods2 }]
exprRuleFix _ _ _ = None

fixImplMethodWith : (Expr -> Expr) -> ImplMethod -> ImplMethod
fixImplMethodWith f (ImplMethod nm ps body) =
  ImplMethod nm ps (rewriteExprBU f body)

-- no decls are excluded by name (the common case)
export
noExcl : String -> Bool
noExcl _ = False

-- ── the in-tests variants of the two drivers above ───────────────────────────
-- `exprRuleFindings`/`exprRuleFix` reach a `DFunDef` body, a `DImpl` method body
-- and through a `DAttrib`, and stop there: a `test "…"` or `prop "…"` body is a
-- `DTest`/`DProp`, which lands on their final wildcard arm and is never walked.
-- Measured on this tree (#3235): the three `expectEqual True …` sites in
-- `gzip/lib/huffman.mdk` and every one of the 26 sites the two test-verb rules
-- below answer for live inside a `test "…"` body, so a rule built on the plain
-- drivers reports a clean tree over code it never read.
--
-- These two variants add exactly the `DTest`/`DProp` descent and DELEGATE every
-- other decl shape back to the plain driver, so the two walkers cannot drift.
-- They are OPT-IN, taken only by `rule-test-bool-literal-equal` and
-- `rule-test-equal-in-true`: the plain drivers are untouched, so the twelve
-- other rules built on them — `rule-not-eq` included — keep exactly the reach
-- they had. That asymmetry is deliberate and is NOT a half-finished migration:
-- widening the plain drivers surfaces 23 pre-existing findings for five other
-- gated max-ratchet rules across eight `stdlib/`+`compiler/` files, which is a
-- drain of its own and not this rule's to pay.
export
exprRuleFindingsInTests : (String -> Bool) ->
  (Expr -> Option Expr) ->
  (Option Loc -> Expr -> Finding) ->
  Positions ->
  List Decl ->
  List Finding
exprRuleFindingsInTests excl det mkFinding pos prog =
  flatMap (exprRuleDeclLInTests excl det mkFinding) (declLocList pos prog)

exprRuleDeclLInTests : (String -> Bool) ->
  (Expr -> Option Expr) ->
  (Option Loc -> Expr -> Finding) ->
  (Decl, Option Loc) ->
  List Finding
exprRuleDeclLInTests excl det mkFinding (d, loc) =
  map
    ((hitLoc, hit) => mkFinding hitLoc hit)
    (declRewriteHitsInTests excl det loc d)

declRewriteHitsInTests : (String -> Bool) ->
  (Expr -> Option Expr) ->
  Option Loc ->
  Decl ->
  List (Option Loc, Expr)
declRewriteHitsInTests _ det loc (DTest _ _ body) = collectRewrites loc det body
declRewriteHitsInTests _ det loc (DProp _ _ _ body) =
  collectRewrites loc det body
-- `parseAttrib` wraps ANY decl, a test decl included, so the attributed case has
-- to re-enter HERE rather than fall through to the plain driver's own `DAttrib`
-- arm, which would drop back to the non-test walker one level down.
declRewriteHitsInTests excl det loc (DAttrib _ d) =
  declRewriteHitsInTests excl det loc d
declRewriteHitsInTests excl det loc d = declRewriteHits excl det loc d

export
exprRuleFixInTests : (String -> Bool) ->
  (Expr -> Expr) ->
  Decl ->
  Option (List Decl)
exprRuleFixInTests _ f (DTest pub name body) =
  testDeclFix (DTest pub name) f body
exprRuleFixInTests _ f (DProp pub name ps body) =
  testDeclFix (DProp pub name ps) f body
exprRuleFixInTests excl f (DAttrib a d) = match exprRuleFixInTests excl f d
  Some [d2] => Some [DAttrib a d2]
  _ => None
exprRuleFixInTests excl f d = exprRuleFix excl f d

-- Shared tail of the `DTest`/`DProp` fix arms: rebuild the body, and emit a
-- replacement only when the location-stripped sexp changed — the same
-- change-detection `exprRuleFix`'s own `DFunDef` arm uses. `rebuild` is the
-- constructor with everything but the body already applied.
testDeclFix : (Expr -> Decl) -> (Expr -> Expr) -> Expr -> Option (List Decl)
testDeclFix rebuild f body =
  let body2 = rewriteExprBU f body
  if exprSexp body2 == exprSexp body then None else Some [rebuild body2]

-- ── shared node predicates ────────────────────────────────────────────────────

-- `e` is a logical negation `not X`; return the negated operand `X`.  `not` parses
-- to `EApp (EVar "not") X`.
--
-- The `EUnOp "!"` arm is GONE (#1739 half A) and must not come back: `!x` is now
-- Ref-DEREFERENCE, so reading it as a negation would make every rule below rewrite a
-- cell read into boolean logic — `!r` would "simplify" to something that no longer
-- reads the Ref at all.  That is a silent-wrongness rewrite, and `--fix` would apply
-- it unprompted.  `not` is the sole boolean negation.
export
notArgOf : Expr -> Option Expr
notArgOf (EApp hd x) = if isEVarNamed "not" hd then Some x else None
notArgOf _ = None

export
isTrueLit : Expr -> Bool
isTrueLit e = isEVarNamed "True" e

export
isFalseLit : Expr -> Bool
isFalseLit e = isEVarNamed "False" e

export
isBoolLit : Expr -> Bool
isBoolLit e = isTrueLit e || isFalseLit e

-- ── rule: match-to-map ────────────────────────────────────────────────────────
-- A 2-arm `match` on an Option or Result that structurally IS a functor `map`
-- over the success side — rewrite to `map f o` (hlint "use fmap").  Fires on
-- EXACTLY these two shapes (the mapError/bimap variants fire nowhere in-tree):
--   Option: `match o { None => None; Some p => Some <expr> }` → `map (p => <expr>) o`
--   Result: `match r { Err v => Err v; Ok  p => Ok  <expr> }` → `map (p => <expr>) r`
-- Arm order is either way.  ETA-REDUCE to `map f o` when `<expr>` is exactly
-- `f p` (p the plain binder used once as the sole/last argument, `f` not
-- mentioning p).  Firing conditions (census-precision ~100%):
--   (1) EXACTLY 2 arms, NO guards, flat single-expression bodies.
--   (2) ONE Option ctor-pair (None+Some) or ONE Result ctor-pair (Err+Ok); these
--       ctor names belong only to the prelude Option/Result types, so keying off
--       the arm patterns is sound with no type inference.
--   (3) the PASSTHROUGH arm reconstructs VERBATIM: `None => None`, or `Err v =>
--       Err v` with the SAME identifier v (rejects `Err e => Err (…e…)` rebuilds
--       and `None => Some …`).
--   (4) LINCHPIN — the transform arm's body HEAD is literally the SAME ctor
--       wrapping an expression (`Some <expr>` / `Ok <expr>`).  This excludes the
--       `Ok x => f x` / `Ok x => andThen …` BIND chains (they UNWRAP, no re-wrap)
--       which are `andThen`/monadic, NOT map.
-- No self-reference risk: the prelude `map` impls are multi-clause function
-- clauses, not a scrutinee `EMatch`, so `map`'s own definition never fires.

-- pattern is a nullary `PCon name` (e.g. `None`)
export
isNilPCon : String -> Pat -> Bool
isNilPCon name (PCon n []) = n == name
isNilPCon _ _ = False

-- transform arm: `PCon ctor [binder] => <ctor> <expr>` — the body head is
-- LITERALLY `ctor` (condition 4).  Returns `(binder, <expr>)`.
export
matchToMapTransform : String -> Pat -> Expr -> Option (Pat, Expr)
matchToMapTransform ctor (PCon c [binder]) body
  | c == ctor = match unwrapLoc body
    EApp hd inner => if isEVarNamed ctor hd then Some (binder, inner) else None
    _ => None
matchToMapTransform _ _ _ = None

-- Arm `PCon ctor [v] => <ctor> v` — unwraps and re-wraps the SAME identifier v,
-- so the arm is the identity on that constructor.  Rejects a rebuild
-- (`Err e => Err (wrap e)`) and a ctor swap (`None => Some …`).
export
ctorVarPassthru : String -> Pat -> Expr -> Bool
ctorVarPassthru ctor (PCon c [PVar v _ _]) body
  | c == ctor = match unwrapLoc body
    EApp hd arg => isEVarNamed ctor hd && isEVarNamed v arg
    _ => False
ctorVarPassthru _ _ _ = False

-- Result passthrough arm: `Err v => Err v` with the SAME identifier v (condition 3).
export
matchToMapErrPassthru : Pat -> Expr -> Bool
matchToMapErrPassthru p body = ctorVarPassthru "Err" p body

-- the scrutinee of a `match`, or the expression itself when it is not one.
export
matchScrutOf : Expr -> Expr
matchScrutOf e = match unwrapLoc e
  EMatch s _ => s
  _ => e

-- The code portion of every source line (text before the line's comment, or the
-- whole line when it has none), by one linear merge of the line list against the
-- comment list — both are in ascending line order.
export
codePortions : List String -> List Comment -> Int -> List String
codePortions [] _ _ = []
codePortions (l :: rest) [] n = l :: codePortions rest [] (n + 1)
codePortions (l :: rest) (c :: cs) n
  | commentLine c < n = codePortions (l :: rest) cs n
  | commentLine c == n =
    stringSlice 0 (commentCol c) l :: codePortions rest cs (n + 1)
  | otherwise = l :: codePortions rest (c :: cs) (n + 1)

-- One claim candidate per comment BLOCK: consecutive full-line comments form a
-- block; a trailing comment (code before it on its line) is a block of its own.
-- Fields: first line, last line, trailing?, the joined comment text.
public export data CommentBlock = CommentBlock Int Int Bool String

export
commentBlocks : List Comment -> Array String -> List CommentBlock
commentBlocks [] _ = []
commentBlocks (c :: rest) codeLines =
  let line = commentLine c
  let trailing = trimWs (codeLineAt codeLines line) /= ""
  if trailing then
    CommentBlock line line True (commentText c) :: commentBlocks rest codeLines
  else match commentBlockExtend rest codeLines line (commentText c)
    (lastLine, text, rest2) =>
      CommentBlock line lastLine False text :: commentBlocks rest2 codeLines

commentBlockExtend : List Comment ->
  Array String ->
  Int ->
  String ->
  (Int, String, List Comment)
commentBlockExtend [] _ last text = (last, text, [])
commentBlockExtend (c :: rest) codeLines last text
  | commentLine c == last + 1
    && trimWs (codeLineAt codeLines (last + 1)) == "" =
    commentBlockExtend rest codeLines (last + 1) "\{text}\n\{commentText c}"
  | otherwise = (last, text, c :: rest)

export
codeLineAt : Array String -> Int -> String
codeLineAt codeLines line
  | line >= 1 && line <= arrayLength codeLines =
    arrayGetUnsafe (line - 1) codeLines
  | otherwise = ""

-- Build a HashMap-as-set from a name list (membership testing only).
export
nameSetOf : List String -> HashMap String Unit
nameSetOf names =
  let s = new ()
  let _ = nameSetInto names s
  s

nameSetInto : List String -> HashMap String Unit -> Unit
nameSetInto [] _ = ()
nameSetInto (n :: rest) s =
  let _ = setInPlace n () s
  nameSetInto rest s
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true) (mem "noBinderId" false) (mem "noDeclLoc" false) (mem "Ty" true) (mem "Pat" true) (mem "UseMember" true) (mem "Guard" true) (mem "Arm" true) (mem "ImplMethod" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "filterList" false) (mem "splitOnChar" false) (mem "joinWith" false) (mem "startsWith" false) (mem "listLen" false) (mem "anyList" false) (mem "joinNl" false) (mem "dedupBy" false))))
(DUse false (UseGroup ("list") ((mem "sortBy" false) (mem "last" false))))
(DUse false (UseGroup ("support" "path") ((mem "stripMdk" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "mustCompile" false) (mem "find" false "reFind") (mem "escape" false) (mem "isMatch" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentLine" false) (mem "commentText" false) (mem "commentCol" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "DirScope" true) (mem "Directive" true) (mem "Finding" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapChildren" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false) (mem "oGetCtorSiblings" false))))
(DTypeSig true "ruleNameMatchParam" (TyCon "String"))
(DFunDef false "ruleNameMatchParam" () (ELit (LString "rule-match-on-param")))
(DTypeSig true "ruleNameDerivable" (TyCon "String"))
(DFunDef false "ruleNameDerivable" () (ELit (LString "rule-hand-rolled-derivable")))
(DTypeSig true "ruleNameStdlibReimpl" (TyCon "String"))
(DFunDef false "ruleNameStdlibReimpl" () (ELit (LString "rule-stdlib-reimpl")))
(DTypeSig true "ruleNameDuplicateBody" (TyCon "String"))
(DFunDef false "ruleNameDuplicateBody" () (ELit (LString "rule-duplicate-body")))
(DTypeSig true "ruleNameBindThenDestructure" (TyCon "String"))
(DFunDef false "ruleNameBindThenDestructure" () (ELit (LString "rule-bind-then-destructure")))
(DTypeSig true "ruleNameLambdaSection" (TyCon "String"))
(DFunDef false "ruleNameLambdaSection" () (ELit (LString "rule-lambda-section")))
(DTypeSig true "ruleNameIfMaxMin" (TyCon "String"))
(DFunDef false "ruleNameIfMaxMin" () (ELit (LString "rule-if-max-min")))
(DTypeSig true "ruleNameAndThenPureMap" (TyCon "String"))
(DFunDef false "ruleNameAndThenPureMap" () (ELit (LString "rule-andthen-pure-map")))
(DTypeSig true "ruleNameDestructureInParam" (TyCon "String"))
(DFunDef false "ruleNameDestructureInParam" () (ELit (LString "rule-destructure-in-param")))
(DTypeSig true "ruleNameMissingSignature" (TyCon "String"))
(DFunDef false "ruleNameMissingSignature" () (ELit (LString "rule-missing-signature")))
(DTypeSig true "ruleNameNotEq" (TyCon "String"))
(DFunDef false "ruleNameNotEq" () (ELit (LString "rule-not-eq")))
(DTypeSig true "ruleNameBoolSimplify" (TyCon "String"))
(DFunDef false "ruleNameBoolSimplify" () (ELit (LString "rule-bool-simplify")))
(DTypeSig true "ruleNameRemParity" (TyCon "String"))
(DFunDef false "ruleNameRemParity" () (ELit (LString "rule-rem-parity")))
(DTypeSig true "ruleNameDoubleReverse" (TyCon "String"))
(DFunDef false "ruleNameDoubleReverse" () (ELit (LString "rule-double-reverse")))
(DTypeSig true "ruleNameWhenUnless" (TyCon "String"))
(DFunDef false "ruleNameWhenUnless" () (ELit (LString "rule-when-unless")))
(DTypeSig true "ruleNameComplementPredicate" (TyCon "String"))
(DFunDef false "ruleNameComplementPredicate" () (ELit (LString "rule-complement-predicate")))
(DTypeSig true "ruleNameMatchToMap" (TyCon "String"))
(DFunDef false "ruleNameMatchToMap" () (ELit (LString "rule-match-to-map")))
(DTypeSig true "ruleNameBindChainToDo" (TyCon "String"))
(DFunDef false "ruleNameBindChainToDo" () (ELit (LString "rule-bind-chain-to-do")))
(DTypeSig true "ruleNameDeadCode" (TyCon "String"))
(DFunDef false "ruleNameDeadCode" () (ELit (LString "rule-dead-code")))
(DTypeSig true "ruleNameConcatToInterp" (TyCon "String"))
(DFunDef false "ruleNameConcatToInterp" () (ELit (LString "rule-concat-to-interp")))
(DTypeSig true "ruleNameSelfShadowExtern" (TyCon "String"))
(DFunDef false "ruleNameSelfShadowExtern" () (ELit (LString "rule-self-shadow-extern")))
(DTypeSig true "ruleNamePreferAssignOp" (TyCon "String"))
(DFunDef false "ruleNamePreferAssignOp" () (ELit (LString "rule-prefer-assign-op")))
(DTypeSig true "ruleNamePromissoryReader" (TyCon "String"))
(DFunDef false "ruleNamePromissoryReader" () (ELit (LString "rule-promissory-reader")))
(DTypeSig true "ruleNameOrElseStaircase" (TyCon "String"))
(DFunDef false "ruleNameOrElseStaircase" () (ELit (LString "rule-orelse-staircase")))
(DTypeSig true "ruleNameCloneType" (TyCon "String"))
(DFunDef false "ruleNameCloneType" () (ELit (LString "rule-clone-type")))
(DTypeSig true "ruleNameClauseMap" (TyCon "String"))
(DFunDef false "ruleNameClauseMap" () (ELit (LString "rule-clause-map")))
(DTypeSig true "ruleNameDirectiveReason" (TyCon "String"))
(DFunDef false "ruleNameDirectiveReason" () (ELit (LString "rule-directive-reason")))
(DTypeSig true "ruleNameRegexLiteral" (TyCon "String"))
(DFunDef false "ruleNameRegexLiteral" () (ELit (LString "rule-regex-literal")))
(DTypeSig true "ruleNameTestBoolLiteralEqual" (TyCon "String"))
(DFunDef false "ruleNameTestBoolLiteralEqual" () (ELit (LString "rule-test-bool-literal-equal")))
(DTypeSig true "ruleNameTestEqualInTrue" (TyCon "String"))
(DFunDef false "ruleNameTestEqualInTrue" () (ELit (LString "rule-test-equal-in-true")))
(DTypeSig true "ruleNameTestPreludeShadow" (TyCon "String"))
(DFunDef false "ruleNameTestPreludeShadow" () (ELit (LString "rule-test-prelude-shadow")))
(DTypeSig true "isStdlibPath" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isStdlibPath" ((PVar "path")) (EApp (EApp (EVar "contains") (ELit (LString "stdlib"))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "path"))))
(DTypeSig true "stdlibModuleOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "stdlibModuleOf" ((PVar "path")) (EApp (EApp (EVar "stdlibModuleGo") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EApp (EVar "stripMdk") (EVar "path")))) (EVar "None")))
(DTypeSig false "stdlibModuleGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stdlibModuleGo" ((PList) (PVar "found")) (EVar "found"))
(DFunDef false "stdlibModuleGo" ((PCons (PVar "seg") (PVar "rest")) (PVar "found")) (EIf (EBinOp "==" (EVar "seg") (ELit (LString "stdlib"))) (EApp (EApp (EVar "stdlibModuleGo") (EVar "rest")) (EApp (EVar "Some") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "rest")))) (EApp (EApp (EVar "stdlibModuleGo") (EVar "rest")) (EVar "found"))))
(DTypeSig true "sortUniqS" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sortUniqS" ((PVar "xs")) (EApp (EVar "dedupSortedS") (EApp (EApp (EVar "sortBy") (EVar "stringCompare")) (EVar "xs"))))
(DTypeSig false "dedupSortedS" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dedupSortedS" ((PCons (PVar "a") (PCons (PVar "b") (PVar "rest")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EVar "dedupSortedS") (EBinOp "::" (EVar "b") (EVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EVar "dedupSortedS") (EBinOp "::" (EVar "b") (EVar "rest"))))))
(DFunDef false "dedupSortedS" ((PVar "xs")) (EVar "xs"))
(DTypeSig true "zipDeclPos" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))))))
(DFunDef false "zipDeclPos" ((PList) PWild) (EListLit))
(DFunDef false "zipDeclPos" (PWild (PList)) (EListLit))
(DFunDef false "zipDeclPos" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EBinOp "::" (ETuple (EVar "d") (EVar "p")) (EApp (EApp (EVar "zipDeclPos") (EVar "ds")) (EVar "ps"))))
(DTypeSig true "collectDirectives" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "collectDirectives" ((PVar "cmts")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EApp (EVar "dirToList") (EApp (EVar "parseDirective") (EVar "c"))))) (EVar "cmts")))
(DTypeSig false "dirToList" (TyFun (TyApp (TyCon "Option") (TyCon "Directive")) (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "dirToList" ((PCon "None")) (EListLit))
(DFunDef false "dirToList" ((PCon "Some" (PVar "d"))) (EListLit (EVar "d")))
(DTypeSig true "parseDirective" (TyFun (TyCon "Comment") (TyApp (TyCon "Option") (TyCon "Directive"))))
(DFunDef false "parseDirective" ((PVar "c")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "trimWs") (EApp (EVar "commentText") (EVar "c")))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "body")) (EApp (EApp (EVar "parseDirectiveBody") (EApp (EVar "commentLine") (EVar "c"))) (EApp (EVar "trimWs") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "body"))) (EVar "body")))) (EVar "None")))))
(DTypeSig false "lintDisableNextLineRe" (TyCon "Regex"))
(DFunDef false "lintDisableNextLineRe" () (EApp (EVar "keywordRe") (ELit (LString "lint-disable-next-line"))))
(DTypeSig false "lintDisableLineRe" (TyCon "Regex"))
(DFunDef false "lintDisableLineRe" () (EApp (EVar "keywordRe") (ELit (LString "lint-disable-line"))))
(DTypeSig false "lintDisableFileRe" (TyCon "Regex"))
(DFunDef false "lintDisableFileRe" () (EApp (EVar "keywordRe") (ELit (LString "lint-disable-file"))))
(DTypeSig false "keywordRe" (TyFun (TyCon "String") (TyCon "Regex")))
(DFunDef false "keywordRe" ((PVar "kw")) (EApp (EVar "mustCompile") (EBinOp "++" (EBinOp "++" (ELit (LString "^")) (EApp (EVar "escape") (EVar "kw"))) (ELit (LString "($|[ \\t].*)$")))))
(DTypeSig false "parseDirectiveBody" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Directive")))))
(DFunDef false "parseDirectiveBody" ((PVar "line") (PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "lint-"))) (EVar "s")) (EApp (EApp (EVar "parseDirectiveKeyword") (EVar "line")) (EVar "s")) (EVar "None")))
(DTypeSig false "parseDirectiveKeyword" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Directive")))))
(DFunDef false "parseDirectiveKeyword" ((PVar "line") (PVar "s")) (EMatch (EApp (EApp (EVar "matchKeyword") (EVar "lintDisableNextLineRe")) (EVar "s")) (arm (PCon "Some" (PVar "names")) () (EApp (EVar "Some") (EApp (EApp (EVar "Directive") (EApp (EVar "DScopeLine") (EBinOp "+" (EVar "line") (ELit (LInt 1))))) (EApp (EVar "parseRuleNames") (EVar "names"))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "matchKeyword") (EVar "lintDisableLineRe")) (EVar "s")) (arm (PCon "Some" (PVar "names")) () (EApp (EVar "Some") (EApp (EApp (EVar "Directive") (EApp (EVar "DScopeLine") (EVar "line"))) (EApp (EVar "parseRuleNames") (EVar "names"))))) (arm (PCon "None") () (EApp (EApp (EVar "map") (ELam ((PVar "names")) (EApp (EApp (EVar "Directive") (EVar "DScopeFile")) (EApp (EVar "parseRuleNames") (EVar "names"))))) (EApp (EApp (EVar "matchKeyword") (EVar "lintDisableFileRe")) (EVar "s"))))))))
(DTypeSig false "matchKeyword" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "matchKeyword" ((PVar "re") (PVar "s")) (EMatch (EApp (EApp (EVar "reFind") (EVar "re")) (EVar "s")) (arm (PCon "Some" (PVar "m")) () (EMatch (EFieldAccess (EVar "m") "groups") (arm (PCons (PCon "Some" (PVar "g")) PWild) () (EApp (EVar "Some") (EApp (EVar "trimWs") (EFieldAccess (EVar "g") "text")))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "parseRuleNames" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "parseRuleNames" ((PVar "s")) (EApp (EApp (EVar "filterList") (EVar "nonEmptyStr")) (EApp (EApp (EVar "flatMap") (EApp (EVar "splitOnChar") (ELit (LChar " ")))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar ","))) (EVar "s")))))
(DTypeSig false "nonEmptyStr" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonEmptyStr" ((PVar "n")) (EBinOp "/=" (EVar "n") (ELit (LString ""))))
(DTypeSig true "trimWs" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trimWs" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "a") (EApp (EApp (EApp (EVar "trimWsStart") (EVar "cs")) (EVar "n")) (ELit (LInt 0)))) (DoLet false false (PVar "b") (EApp (EApp (EApp (EVar "trimWsEnd") (EVar "cs")) (EVar "a")) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EVar "s")))))
(DTypeSig false "trimWsStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimWsStart" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "i") (EIf (EApp (EVar "isWsChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "trimWsStart") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "trimWsEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimWsEnd" ((PVar "cs") (PVar "a") (PVar "n")) (EIf (EBinOp "<=" (EVar "n") (EVar "a")) (EVar "a") (EIf (EApp (EVar "isWsChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "cs"))) (EApp (EApp (EApp (EVar "trimWsEnd") (EVar "cs")) (EVar "a")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "n") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isWsChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isWsChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar " "))) (EBinOp "==" (EVar "c") (ELit (LChar "\t")))) (EBinOp "==" (EVar "c") (ELit (LChar "\r")))) (EBinOp "==" (EVar "c") (ELit (LChar "\n")))))
(DTypeSig true "unwrapLoc" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "unwrapLoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "unwrapLoc") (EVar "e")))
(DFunDef false "unwrapLoc" ((PVar "e")) (EVar "e"))
(DTypeSig true "declLocList" (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "declLocList" ((PVar "pos") (PVar "prog")) (EApp (EApp (EVar "zipDeclLoc") (EVar "prog")) (EApp (EVar "positionsDecls") (EVar "pos"))))
(DTypeSig false "zipDeclLoc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "zipDeclLoc" ((PList) PWild) (EListLit))
(DFunDef false "zipDeclLoc" ((PCons (PVar "d") (PVar "ds")) (PList)) (EBinOp "::" (ETuple (EVar "d") (EVar "None")) (EApp (EApp (EVar "zipDeclLoc") (EVar "ds")) (EListLit))))
(DFunDef false "zipDeclLoc" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EBinOp "::" (ETuple (EVar "d") (EApp (EVar "Some") (EApp (EVar "declPosToLoc") (EVar "p")))) (EApp (EApp (EVar "zipDeclLoc") (EVar "ds")) (EVar "ps"))))
(DTypeSig false "declPosToLoc" (TyFun (TyCon "DeclPos") (TyCon "Loc")))
(DFunDef false "declPosToLoc" ((PVar "p")) (ELet false (PVar "l") (EApp (EVar "declPosLine") (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "l")) (ELit (LInt 1))) (EVar "l")) (ELit (LInt 1)))))
(DTypeSig true "isBareParam" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "isBareParam" ((PVar "p") (PCon "PVar" (PVar "q") PWild PWild)) (EBinOp "==" (EVar "p") (EVar "q")))
(DFunDef false "isBareParam" (PWild PWild) (EVar "False"))
(DTypeSig true "matchBodyOnBareParam" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Arm")))))))
(DFunDef false "matchBodyOnBareParam" ((PVar "pats") (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EMatch" (PVar "scrut") (PVar "arms")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "scrut")) (arm (PCon "EVar" (PVar "p")) () (EApp (EApp (EVar "map") (ELam ((PVar "k")) (ETuple (EVar "p") (EVar "k") (EVar "arms")))) (EApp (EApp (EVar "paramIndex") (EVar "p")) (EVar "pats")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig true "patIsWild" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patIsWild" ((PCon "PWild")) (EVar "True"))
(DFunDef false "patIsWild" (PWild) (EVar "False"))
(DTypeSig false "paramIndex" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "paramIndex" ((PVar "p") (PVar "pats")) (EApp (EApp (EApp (EVar "paramIndexGo") (EVar "p")) (EVar "pats")) (ELit (LInt 0))))
(DTypeSig false "paramIndexGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "paramIndexGo" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "paramIndexGo" ((PVar "p") (PCons (PVar "pat") (PVar "rest")) (PVar "i")) (EIf (EApp (EApp (EVar "isBareParam") (EVar "p")) (EVar "pat")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "paramIndexGo") (EVar "p")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "armToClause" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Int") (TyFun (TyCon "Arm") (TyCon "Decl"))))))))
(DFunDef false "armToClause" ((PVar "vis") (PVar "name") (PVar "p") (PVar "pats") (PVar "k") (PCon "Arm" (PVar "pat") PWild (PVar "body"))) (EBlock (DoLet false false (PVar "cpat") (EIf (EBinOp "&&" (EApp (EVar "patIsWild") (EVar "pat")) (EApp (EApp (EVar "wholeWordIn") (EVar "p")) (EApp (EVar "exprToString") (EVar "body")))) (EApp (EApp (EApp (EVar "PVar") (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EApp (EApp (EApp (EVar "replaceAt") (EVar "k")) (EVar "cpat")) (EVar "pats"))) (EVar "body")) (EVar "noDeclLoc")) (EVar "noBinderId")))))
(DTypeSig false "replaceAt" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "replaceAt" (PWild PWild (PList)) (EListLit))
(DFunDef false "replaceAt" ((PLit (LInt 0)) (PVar "x") (PCons PWild (PVar "rest"))) (EBinOp "::" (EVar "x") (EVar "rest")))
(DFunDef false "replaceAt" ((PVar "n") (PVar "x") (PCons (PVar "y") (PVar "rest"))) (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "replaceAt") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "x")) (EVar "rest"))))
(DTypeSig true "wholeWordIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "wholeWordIn" ((PVar "name") (PVar "s")) (EApp (EApp (EVar "isMatch") (EApp (EVar "mustCompile") (EApp (EVar "wholeWordPattern") (EVar "name")))) (EVar "s")))
(DTypeSig false "wholeWordPattern" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "wholeWordPattern" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "(?:^|[^A-Za-z0-9_'])")) (EApp (EVar "escape") (EVar "name"))) (ELit (LString "(?:$|[^A-Za-z0-9_'])"))))
(DTypeSig true "ctorIsSingle" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ctorIsSingle" ((PVar "orc") (PVar "c")) (EMatch (EApp (EApp (EVar "oGetCtorSiblings") (EVar "orc")) (EVar "c")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "==" (EApp (EVar "listLen") (EVar "ctors")) (ELit (LInt 1)))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "tyHeadName" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "tyHeadName" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "tyHeadName" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "tyHeadName") (EVar "f")))
(DFunDef false "tyHeadName" (PWild) (EVar "None"))
(DTypeSig true "topDefNameL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "topDefNameL" ((PTuple (PCon "DFunDef" PWild (PVar "name") PWild PWild PWild PWild) (PVar "loc"))) (EListLit (ETuple (EVar "name") (EVar "loc"))))
(DFunDef false "topDefNameL" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "topDefNameL") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "topDefNameL" (PWild) (EListLit))
(DTypeSig true "dedupeNamesLoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "dedupeNamesLoc" ((PVar "xs")) (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EVar "xs")))
(DTypeSig true "clausesOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesOf" (PWild (PList)) (EListLit))
(DFunDef false "clausesOf" ((PVar "name") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "clausesOf") (EVar "name")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "clausesOf" ((PVar "name") (PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") PWild PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "::" (ETuple (EVar "ps") (EVar "body")) (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "clausesOf" ((PVar "name") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "rest")))
(DTypeSig true "stripELoc" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripELoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripELoc") (EVar "e")))
(DFunDef false "stripELoc" ((PVar "e")) (EVar "e"))
(DTypeSig true "appSpineOf" (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "appSpineOf" ((PVar "e")) (EApp (EApp (EVar "appSpineGo") (EVar "e")) (EListLit)))
(DTypeSig false "appSpineGo" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "appSpineGo" ((PVar "e") (PVar "acc")) (EMatch (EApp (EVar "stripELoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") (PVar "a")) () (EApp (EApp (EVar "appSpineGo") (EVar "f")) (EBinOp "::" (EVar "a") (EVar "acc")))) (arm (PVar "other") () (ETuple (EVar "other") (EVar "acc")))))
(DTypeSig true "paramNameOf" (TyFun (TyCon "Pat") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "paramNameOf" ((PCon "PVar" (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "paramNameOf" (PWild) (EVar "None"))
(DTypeSig true "memberLocalIfOrigin" (TyFun (TyCon "String") (TyFun (TyCon "UseMember") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "memberLocalIfOrigin" ((PVar "stdName") (PCon "UseMember" (PVar "origin") PWild PWild (PVar "alias"))) (EIf (EBinOp "==" (EVar "origin") (EVar "stdName")) (EApp (EVar "Some") (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EVar "origin")))) (EVar "None")))
(DTypeSig true "lastSegOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastSegOf" ((PList)) (ELit (LString "")))
(DFunDef false "lastSegOf" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastSegOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastSegOf") (EVar "rest")))
(DTypeSig true "childExprs" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "childExprs" ((PCon "ELoc" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EDoOrigin" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EApp" (PVar "f") (PVar "x"))) (EListLit (EVar "f") (EVar "x")))
(DFunDef false "childExprs" ((PCon "ELam" PWild (PVar "b"))) (EListLit (EVar "b")))
(DFunDef false "childExprs" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EListLit (EVar "e1") (EVar "e2")))
(DFunDef false "childExprs" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EBinOp "::" (EVar "s") (EApp (EApp (EVar "flatMap") (EVar "armExprs")) (EVar "arms"))))
(DFunDef false "childExprs" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EListLit (EVar "c") (EVar "t") (EVar "el")))
(DFunDef false "childExprs" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EListLit (EVar "a") (EVar "b")))
(DFunDef false "childExprs" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EListLit (EVar "a")))
(DFunDef false "childExprs" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EListLit (EVar "a") (EVar "b")))
(DFunDef false "childExprs" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "ETuple" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EListLit" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EArrayLit" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "e") (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "letBindExprs")) (EVar "binds")) (EListLit (EVar "body"))))
(DFunDef false "childExprs" ((PCon "ESection" (PVar "s"))) (EApp (EVar "sectionExprs") (EVar "s")))
(DFunDef false "childExprs" ((PCon "EIndex" (PVar "a") (PVar "i"))) (EListLit (EVar "a") (EVar "i")))
(DFunDef false "childExprs" ((PCon "EAnnot" (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "stmtExprs")) (EVar "stmts")))
(DFunDef false "childExprs" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "stmtExprs")) (EVar "stmts")))
(DFunDef false "childExprs" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "flatMap") (EVar "interpPartExprs")) (EVar "parts")))
(DFunDef false "childExprs" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "flatMap") (EVar "guardArmExprs")) (EVar "arms")))
(DFunDef false "childExprs" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "map") (EVar "fieldAssignExpr")) (EVar "fs")))
(DFunDef false "childExprs" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBinOp "::" (EVar "e") (EApp (EApp (EVar "map") (EVar "fieldAssignExpr")) (EVar "fs"))))
(DFunDef false "childExprs" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "::" (EVar "e") (EApp (EApp (EVar "map") (EVar "fieldAssignExpr")) (EVar "fs"))))
(DFunDef false "childExprs" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EVar "flatMap") (EVar "kvExprs")) (EVar "kvs")))
(DFunDef false "childExprs" ((PCon "ESetLit" PWild (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EAsPat" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EOrPat" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" (PWild) (EListLit))
(DTypeSig false "armExprs" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "armExprs" ((PCon "Arm" PWild (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardExprs")) (EVar "gs")) (EListLit (EVar "body"))))
(DTypeSig false "guardExprs" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "guardExprs" ((PCon "GBool" (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "guardExprs" ((PCon "GBind" PWild (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig true "stmtExprs" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "stmtExprs" ((PCon "DoExpr" (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoBind" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoAssign" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "letBindExprs" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "letBindExprs" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "flatMap") (EVar "funClauseExprs")) (EVar "clauses")))
(DTypeSig false "funClauseExprs" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "funClauseExprs" ((PCon "FunClause" PWild (PVar "body"))) (EListLit (EVar "body")))
(DTypeSig false "sectionExprs" (TyFun (TyCon "Section") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "sectionExprs" ((PCon "SecBare" PWild)) (EListLit))
(DFunDef false "sectionExprs" ((PCon "SecRight" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "sectionExprs" ((PCon "SecLeft" (PVar "e") PWild)) (EListLit (EVar "e")))
(DTypeSig false "interpPartExprs" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "interpPartExprs" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpPartExprs" ((PCon "InterpExpr" (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "guardArmExprs" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "guardArmExprs" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardExprs")) (EVar "gs")) (EListLit (EVar "body"))))
(DTypeSig false "fieldAssignExpr" (TyFun (TyCon "FieldAssign") (TyCon "Expr")))
(DFunDef false "fieldAssignExpr" ((PCon "FieldAssign" PWild (PVar "e"))) (EVar "e"))
(DTypeSig false "kvExprs" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "kvExprs" ((PTuple (PVar "k") (PVar "v"))) (EListLit (EVar "k") (EVar "v")))
(DTypeSig true "isEVarNamed" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isEVarNamed" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EBinOp "==" (EVar "w") (EVar "x"))) (arm PWild () (EVar "False"))))
(DTypeSig true "mentionsVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "mentionsVar" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EBinOp "==" (EVar "w") (EVar "x"))) (arm (PVar "e2") () (EApp (EApp (EVar "anyList") (EApp (EVar "mentionsVar") (EVar "x"))) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig true "implMethodsBodyKey" (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "String")))
(DFunDef false "implMethodsBodyKey" ((PVar "ms")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "implMethodBodySexp")) (EVar "ms"))))
(DTypeSig false "implMethodBodySexp" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodBodySexp" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "exprSexp") (EVar "body")))
(DTypeSig true "andThenEtaFn" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "andThenEtaFn" ((PVar "x") (PVar "arg")) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg")) (arm (PCon "EApp" (PVar "f") (PVar "lastArg")) ((GBool (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "lastArg")) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EVar "f")))))) (EApp (EVar "Some") (EVar "f"))) (arm PWild () (EVar "None"))))
(DTypeSig true "mapChildExprs" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EVar "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PVar "e")) (EApp (EApp (EVar "mapChildren") (EVar "g")) (EVar "e")))
(DTypeSig true "rewriteExprBU" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteExprBU" ((PVar "f") (PVar "e")) (EApp (EVar "f") (EApp (EApp (EVar "mapChildExprs") (EApp (EVar "rewriteExprBU") (EVar "f"))) (EVar "e"))))
(DTypeSig true "detApply" (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "detApply" ((PVar "det") (PVar "e")) (EMatch (EApp (EVar "det") (EVar "e")) (arm (PCon "Some" (PVar "e2")) () (EVar "e2")) (arm (PCon "None") () (EVar "e"))))
(DTypeSig true "exprRuleFindings" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))) (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "exprRuleFindings" ((PVar "excl") (PVar "det") (PVar "mkFinding") (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "exprRuleDeclL") (EVar "excl")) (EVar "det")) (EVar "mkFinding"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "exprRuleDeclL" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))) (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "exprRuleDeclL" ((PVar "excl") (PVar "det") (PVar "mkFinding") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "hitLoc") (PVar "hit"))) (EApp (EApp (EVar "mkFinding") (EVar "hitLoc")) (EVar "hit")))) (EApp (EApp (EApp (EApp (EVar "declRewriteHits") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d"))))
(DTypeSig false "declRewriteHits" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr"))))))))
(DFunDef false "declRewriteHits" ((PVar "excl") (PVar "det") (PVar "loc") (PCon "DFunDef" PWild (PVar "name") PWild (PVar "body") PWild PWild)) (EIf (EApp (EVar "excl") (EVar "name")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collectRewrites") (EVar "loc")) (EVar "det")) (EVar "body")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "declRewriteHits" (PWild (PVar "det") (PVar "loc") (PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "implMethodRewriteHits") (EVar "loc")) (EVar "det"))) (EVar "methods")))
(DFunDef false "declRewriteHits" ((PVar "excl") (PVar "det") (PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "declRewriteHits") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d")))
(DFunDef false "declRewriteHits" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "implMethodRewriteHits" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr")))))))
(DFunDef false "implMethodRewriteHits" ((PVar "loc") (PVar "det") (PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EVar "collectRewrites") (EVar "loc")) (EVar "det")) (EVar "body")))
(DTypeSig true "collectRewrites" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr")))))))
(DFunDef false "collectRewrites" (PWild (PVar "det") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EVar "collectRewrites") (EApp (EVar "Some") (EVar "l"))) (EVar "det")) (EVar "e")))
(DFunDef false "collectRewrites" ((PVar "curLoc") (PVar "det") (PVar "e")) (EBinOp "++" (EApp (EApp (EVar "optExprToLocList") (EVar "curLoc")) (EApp (EVar "det") (EVar "e"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "collectRewrites") (EVar "curLoc")) (EVar "det"))) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "optExprToLocList" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr"))))))
(DFunDef false "optExprToLocList" (PWild (PCon "None")) (EListLit))
(DFunDef false "optExprToLocList" ((PVar "loc") (PCon "Some" (PVar "x"))) (EListLit (ETuple (EVar "loc") (EVar "x"))))
(DTypeSig true "exprRuleFix" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "exprRuleFix" ((PVar "excl") (PVar "f") (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EIf (EApp (EVar "excl") (EVar "name")) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "body2") (EApp (EApp (EVar "rewriteExprBU") (EVar "f")) (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2")) (EVar "site")) (EVar "bid"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "exprRuleFix" ((PVar "excl") (PVar "f") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "excl")) (EVar "f")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "exprRuleFix" (PWild (PVar "f") (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild) (rf "methods" None)) false))) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EVar "map") (EApp (EVar "fixImplMethodWith") (EVar "f"))) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EVar "methods2"))))))))))
(DFunDef false "exprRuleFix" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodWith" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "fixImplMethodWith" ((PVar "f") (PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EApp (EVar "rewriteExprBU") (EVar "f")) (EVar "body"))))
(DTypeSig true "noExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "noExcl" (PWild) (EVar "False"))
(DTypeSig true "exprRuleFindingsInTests" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))) (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "exprRuleFindingsInTests" ((PVar "excl") (PVar "det") (PVar "mkFinding") (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "exprRuleDeclLInTests") (EVar "excl")) (EVar "det")) (EVar "mkFinding"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "exprRuleDeclLInTests" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))) (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "exprRuleDeclLInTests" ((PVar "excl") (PVar "det") (PVar "mkFinding") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "hitLoc") (PVar "hit"))) (EApp (EApp (EVar "mkFinding") (EVar "hitLoc")) (EVar "hit")))) (EApp (EApp (EApp (EApp (EVar "declRewriteHitsInTests") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d"))))
(DTypeSig false "declRewriteHitsInTests" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr"))))))))
(DFunDef false "declRewriteHitsInTests" (PWild (PVar "det") (PVar "loc") (PCon "DTest" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EVar "collectRewrites") (EVar "loc")) (EVar "det")) (EVar "body")))
(DFunDef false "declRewriteHitsInTests" (PWild (PVar "det") (PVar "loc") (PCon "DProp" PWild PWild PWild (PVar "body"))) (EApp (EApp (EApp (EVar "collectRewrites") (EVar "loc")) (EVar "det")) (EVar "body")))
(DFunDef false "declRewriteHitsInTests" ((PVar "excl") (PVar "det") (PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "declRewriteHitsInTests") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d")))
(DFunDef false "declRewriteHitsInTests" ((PVar "excl") (PVar "det") (PVar "loc") (PVar "d")) (EApp (EApp (EApp (EApp (EVar "declRewriteHits") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d")))
(DTypeSig true "exprRuleFixInTests" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "exprRuleFixInTests" (PWild (PVar "f") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "testDeclFix") (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name"))) (EVar "f")) (EVar "body")))
(DFunDef false "exprRuleFixInTests" (PWild (PVar "f") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "testDeclFix") (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "ps"))) (EVar "f")) (EVar "body")))
(DFunDef false "exprRuleFixInTests" ((PVar "excl") (PVar "f") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EApp (EVar "exprRuleFixInTests") (EVar "excl")) (EVar "f")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "exprRuleFixInTests" ((PVar "excl") (PVar "f") (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "excl")) (EVar "f")) (EVar "d")))
(DTypeSig false "testDeclFix" (TyFun (TyFun (TyCon "Expr") (TyCon "Decl")) (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "testDeclFix" ((PVar "rebuild") (PVar "f") (PVar "body")) (EBlock (DoLet false false (PVar "body2") (EApp (EApp (EVar "rewriteExprBU") (EVar "f")) (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EVar "rebuild") (EVar "body2"))))))))
(DTypeSig true "notArgOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "notArgOf" ((PCon "EApp" (PVar "hd") (PVar "x"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "not"))) (EVar "hd")) (EApp (EVar "Some") (EVar "x")) (EVar "None")))
(DFunDef false "notArgOf" (PWild) (EVar "None"))
(DTypeSig true "isTrueLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isTrueLit" ((PVar "e")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "True"))) (EVar "e")))
(DTypeSig true "isFalseLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isFalseLit" ((PVar "e")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "False"))) (EVar "e")))
(DTypeSig true "isBoolLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isBoolLit" ((PVar "e")) (EBinOp "||" (EApp (EVar "isTrueLit") (EVar "e")) (EApp (EVar "isFalseLit") (EVar "e"))))
(DTypeSig true "isNilPCon" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "isNilPCon" ((PVar "name") (PCon "PCon" (PVar "n") (PList))) (EBinOp "==" (EVar "n") (EVar "name")))
(DFunDef false "isNilPCon" (PWild PWild) (EVar "False"))
(DTypeSig true "matchToMapTransform" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "Pat") (TyCon "Expr")))))))
(DFunDef false "matchToMapTransform" ((PVar "ctor") (PCon "PCon" (PVar "c") (PList (PVar "binder"))) (PVar "body")) (EIf (EBinOp "==" (EVar "c") (EVar "ctor")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "hd") (PVar "inner")) () (EIf (EApp (EApp (EVar "isEVarNamed") (EVar "ctor")) (EVar "hd")) (EApp (EVar "Some") (ETuple (EVar "binder") (EVar "inner"))) (EVar "None"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "matchToMapTransform" (PWild PWild PWild) (EVar "None"))
(DTypeSig true "ctorVarPassthru" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "ctorVarPassthru" ((PVar "ctor") (PCon "PCon" (PVar "c") (PList (PCon "PVar" (PVar "v") PWild PWild))) (PVar "body")) (EIf (EBinOp "==" (EVar "c") (EVar "ctor")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "hd") (PVar "arg")) () (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "ctor")) (EVar "hd")) (EApp (EApp (EVar "isEVarNamed") (EVar "v")) (EVar "arg")))) (arm PWild () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "ctorVarPassthru" (PWild PWild PWild) (EVar "False"))
(DTypeSig true "matchToMapErrPassthru" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "matchToMapErrPassthru" ((PVar "p") (PVar "body")) (EApp (EApp (EApp (EVar "ctorVarPassthru") (ELit (LString "Err"))) (EVar "p")) (EVar "body")))
(DTypeSig true "matchScrutOf" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "matchScrutOf" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EMatch" (PVar "s") PWild) () (EVar "s")) (arm PWild () (EVar "e"))))
(DTypeSig true "codePortions" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "codePortions" ((PList) PWild PWild) (EListLit))
(DFunDef false "codePortions" ((PCons (PVar "l") (PVar "rest")) (PList) (PVar "n")) (EBinOp "::" (EVar "l") (EApp (EApp (EApp (EVar "codePortions") (EVar "rest")) (EListLit)) (EBinOp "+" (EVar "n") (ELit (LInt 1))))))
(DFunDef false "codePortions" ((PCons (PVar "l") (PVar "rest")) (PCons (PVar "c") (PVar "cs")) (PVar "n")) (EIf (EBinOp "<" (EApp (EVar "commentLine") (EVar "c")) (EVar "n")) (EApp (EApp (EApp (EVar "codePortions") (EBinOp "::" (EVar "l") (EVar "rest"))) (EVar "cs")) (EVar "n")) (EIf (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "n")) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EApp (EVar "commentCol") (EVar "c"))) (EVar "l")) (EApp (EApp (EApp (EVar "codePortions") (EVar "rest")) (EVar "cs")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "l") (EApp (EApp (EApp (EVar "codePortions") (EVar "rest")) (EBinOp "::" (EVar "c") (EVar "cs"))) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DData Public "CommentBlock" () ((variant "CommentBlock" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Bool") (TyCon "String")))) ())
(DTypeSig true "commentBlocks" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyApp (TyCon "List") (TyCon "CommentBlock")))))
(DFunDef false "commentBlocks" ((PList) PWild) (EListLit))
(DFunDef false "commentBlocks" ((PCons (PVar "c") (PVar "rest")) (PVar "codeLines")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "commentLine") (EVar "c"))) (DoLet false false (PVar "trailing") (EBinOp "/=" (EApp (EVar "trimWs") (EApp (EApp (EVar "codeLineAt") (EVar "codeLines")) (EVar "line"))) (ELit (LString "")))) (DoExpr (EIf (EVar "trailing") (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "CommentBlock") (EVar "line")) (EVar "line")) (EVar "True")) (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EVar "commentBlocks") (EVar "rest")) (EVar "codeLines"))) (EMatch (EApp (EApp (EApp (EApp (EVar "commentBlockExtend") (EVar "rest")) (EVar "codeLines")) (EVar "line")) (EApp (EVar "commentText") (EVar "c"))) (arm (PTuple (PVar "lastLine") (PVar "text") (PVar "rest2")) () (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "CommentBlock") (EVar "line")) (EVar "lastLine")) (EVar "False")) (EVar "text")) (EApp (EApp (EVar "commentBlocks") (EVar "rest2")) (EVar "codeLines")))))))))
(DTypeSig false "commentBlockExtend" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyTuple (TyCon "Int") (TyCon "String") (TyApp (TyCon "List") (TyCon "Comment"))))))))
(DFunDef false "commentBlockExtend" ((PList) PWild (PVar "last") (PVar "text")) (ETuple (EVar "last") (EVar "text") (EListLit)))
(DFunDef false "commentBlockExtend" ((PCons (PVar "c") (PVar "rest")) (PVar "codeLines") (PVar "last") (PVar "text")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EBinOp "+" (EVar "last") (ELit (LInt 1)))) (EBinOp "==" (EApp (EVar "trimWs") (EApp (EApp (EVar "codeLineAt") (EVar "codeLines")) (EBinOp "+" (EVar "last") (ELit (LInt 1))))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EVar "commentBlockExtend") (EVar "rest")) (EVar "codeLines")) (EBinOp "+" (EVar "last") (ELit (LInt 1)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "text"))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "commentText") (EVar "c")))) (ELit (LString "")))) (EIf (EVar "otherwise") (ETuple (EVar "last") (EVar "text") (EBinOp "::" (EVar "c") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "codeLineAt" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "codeLineAt" ((PVar "codeLines") (PVar "line")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "line") (ELit (LInt 1))) (EBinOp "<=" (EVar "line") (EApp (EVar "arrayLength") (EVar "codeLines")))) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EVar "codeLines")) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "nameSetOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "nameSetOf" ((PVar "names")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "nameSetInto") (EVar "names")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "nameSetInto" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "nameSetInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "nameSetInto" ((PCons (PVar "n") (PVar "rest")) (PVar "s")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (ELit LUnit)) (EVar "s"))) (DoExpr (EApp (EApp (EVar "nameSetInto") (EVar "rest")) (EVar "s")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true) (mem "noBinderId" false) (mem "noDeclLoc" false) (mem "Ty" true) (mem "Pat" true) (mem "UseMember" true) (mem "Guard" true) (mem "Arm" true) (mem "ImplMethod" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "filterList" false) (mem "splitOnChar" false) (mem "joinWith" false) (mem "startsWith" false) (mem "listLen" false) (mem "anyList" false) (mem "joinNl" false) (mem "dedupBy" false))))
(DUse false (UseGroup ("list") ((mem "sortBy" false) (mem "last" false))))
(DUse false (UseGroup ("support" "path") ((mem "stripMdk" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "mustCompile" false) (mem "find" false "reFind") (mem "escape" false) (mem "isMatch" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentLine" false) (mem "commentText" false) (mem "commentCol" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "DirScope" true) (mem "Directive" true) (mem "Finding" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapChildren" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false) (mem "oGetCtorSiblings" false))))
(DTypeSig true "ruleNameMatchParam" (TyCon "String"))
(DFunDef false "ruleNameMatchParam" () (ELit (LString "rule-match-on-param")))
(DTypeSig true "ruleNameDerivable" (TyCon "String"))
(DFunDef false "ruleNameDerivable" () (ELit (LString "rule-hand-rolled-derivable")))
(DTypeSig true "ruleNameStdlibReimpl" (TyCon "String"))
(DFunDef false "ruleNameStdlibReimpl" () (ELit (LString "rule-stdlib-reimpl")))
(DTypeSig true "ruleNameDuplicateBody" (TyCon "String"))
(DFunDef false "ruleNameDuplicateBody" () (ELit (LString "rule-duplicate-body")))
(DTypeSig true "ruleNameBindThenDestructure" (TyCon "String"))
(DFunDef false "ruleNameBindThenDestructure" () (ELit (LString "rule-bind-then-destructure")))
(DTypeSig true "ruleNameLambdaSection" (TyCon "String"))
(DFunDef false "ruleNameLambdaSection" () (ELit (LString "rule-lambda-section")))
(DTypeSig true "ruleNameIfMaxMin" (TyCon "String"))
(DFunDef false "ruleNameIfMaxMin" () (ELit (LString "rule-if-max-min")))
(DTypeSig true "ruleNameAndThenPureMap" (TyCon "String"))
(DFunDef false "ruleNameAndThenPureMap" () (ELit (LString "rule-andthen-pure-map")))
(DTypeSig true "ruleNameDestructureInParam" (TyCon "String"))
(DFunDef false "ruleNameDestructureInParam" () (ELit (LString "rule-destructure-in-param")))
(DTypeSig true "ruleNameMissingSignature" (TyCon "String"))
(DFunDef false "ruleNameMissingSignature" () (ELit (LString "rule-missing-signature")))
(DTypeSig true "ruleNameNotEq" (TyCon "String"))
(DFunDef false "ruleNameNotEq" () (ELit (LString "rule-not-eq")))
(DTypeSig true "ruleNameBoolSimplify" (TyCon "String"))
(DFunDef false "ruleNameBoolSimplify" () (ELit (LString "rule-bool-simplify")))
(DTypeSig true "ruleNameRemParity" (TyCon "String"))
(DFunDef false "ruleNameRemParity" () (ELit (LString "rule-rem-parity")))
(DTypeSig true "ruleNameDoubleReverse" (TyCon "String"))
(DFunDef false "ruleNameDoubleReverse" () (ELit (LString "rule-double-reverse")))
(DTypeSig true "ruleNameWhenUnless" (TyCon "String"))
(DFunDef false "ruleNameWhenUnless" () (ELit (LString "rule-when-unless")))
(DTypeSig true "ruleNameComplementPredicate" (TyCon "String"))
(DFunDef false "ruleNameComplementPredicate" () (ELit (LString "rule-complement-predicate")))
(DTypeSig true "ruleNameMatchToMap" (TyCon "String"))
(DFunDef false "ruleNameMatchToMap" () (ELit (LString "rule-match-to-map")))
(DTypeSig true "ruleNameBindChainToDo" (TyCon "String"))
(DFunDef false "ruleNameBindChainToDo" () (ELit (LString "rule-bind-chain-to-do")))
(DTypeSig true "ruleNameDeadCode" (TyCon "String"))
(DFunDef false "ruleNameDeadCode" () (ELit (LString "rule-dead-code")))
(DTypeSig true "ruleNameConcatToInterp" (TyCon "String"))
(DFunDef false "ruleNameConcatToInterp" () (ELit (LString "rule-concat-to-interp")))
(DTypeSig true "ruleNameSelfShadowExtern" (TyCon "String"))
(DFunDef false "ruleNameSelfShadowExtern" () (ELit (LString "rule-self-shadow-extern")))
(DTypeSig true "ruleNamePreferAssignOp" (TyCon "String"))
(DFunDef false "ruleNamePreferAssignOp" () (ELit (LString "rule-prefer-assign-op")))
(DTypeSig true "ruleNamePromissoryReader" (TyCon "String"))
(DFunDef false "ruleNamePromissoryReader" () (ELit (LString "rule-promissory-reader")))
(DTypeSig true "ruleNameOrElseStaircase" (TyCon "String"))
(DFunDef false "ruleNameOrElseStaircase" () (ELit (LString "rule-orelse-staircase")))
(DTypeSig true "ruleNameCloneType" (TyCon "String"))
(DFunDef false "ruleNameCloneType" () (ELit (LString "rule-clone-type")))
(DTypeSig true "ruleNameClauseMap" (TyCon "String"))
(DFunDef false "ruleNameClauseMap" () (ELit (LString "rule-clause-map")))
(DTypeSig true "ruleNameDirectiveReason" (TyCon "String"))
(DFunDef false "ruleNameDirectiveReason" () (ELit (LString "rule-directive-reason")))
(DTypeSig true "ruleNameRegexLiteral" (TyCon "String"))
(DFunDef false "ruleNameRegexLiteral" () (ELit (LString "rule-regex-literal")))
(DTypeSig true "ruleNameTestBoolLiteralEqual" (TyCon "String"))
(DFunDef false "ruleNameTestBoolLiteralEqual" () (ELit (LString "rule-test-bool-literal-equal")))
(DTypeSig true "ruleNameTestEqualInTrue" (TyCon "String"))
(DFunDef false "ruleNameTestEqualInTrue" () (ELit (LString "rule-test-equal-in-true")))
(DTypeSig true "ruleNameTestPreludeShadow" (TyCon "String"))
(DFunDef false "ruleNameTestPreludeShadow" () (ELit (LString "rule-test-prelude-shadow")))
(DTypeSig true "isStdlibPath" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isStdlibPath" ((PVar "path")) (EApp (EApp (EVar "contains") (ELit (LString "stdlib"))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "path"))))
(DTypeSig true "stdlibModuleOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "stdlibModuleOf" ((PVar "path")) (EApp (EApp (EVar "stdlibModuleGo") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EApp (EVar "stripMdk") (EVar "path")))) (EVar "None")))
(DTypeSig false "stdlibModuleGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "stdlibModuleGo" ((PList) (PVar "found")) (EVar "found"))
(DFunDef false "stdlibModuleGo" ((PCons (PVar "seg") (PVar "rest")) (PVar "found")) (EIf (EBinOp "==" (EVar "seg") (ELit (LString "stdlib"))) (EApp (EApp (EVar "stdlibModuleGo") (EVar "rest")) (EApp (EVar "Some") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "rest")))) (EApp (EApp (EVar "stdlibModuleGo") (EVar "rest")) (EVar "found"))))
(DTypeSig true "sortUniqS" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sortUniqS" ((PVar "xs")) (EApp (EVar "dedupSortedS") (EApp (EApp (EVar "sortBy") (EVar "stringCompare")) (EVar "xs"))))
(DTypeSig false "dedupSortedS" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dedupSortedS" ((PCons (PVar "a") (PCons (PVar "b") (PVar "rest")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EVar "dedupSortedS") (EBinOp "::" (EVar "b") (EVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EVar "dedupSortedS") (EBinOp "::" (EVar "b") (EVar "rest"))))))
(DFunDef false "dedupSortedS" ((PVar "xs")) (EVar "xs"))
(DTypeSig true "zipDeclPos" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))))))
(DFunDef false "zipDeclPos" ((PList) PWild) (EListLit))
(DFunDef false "zipDeclPos" (PWild (PList)) (EListLit))
(DFunDef false "zipDeclPos" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EBinOp "::" (ETuple (EVar "d") (EVar "p")) (EApp (EApp (EVar "zipDeclPos") (EVar "ds")) (EVar "ps"))))
(DTypeSig true "collectDirectives" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "collectDirectives" ((PVar "cmts")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EApp (EVar "dirToList") (EApp (EVar "parseDirective") (EVar "c"))))) (EVar "cmts")))
(DTypeSig false "dirToList" (TyFun (TyApp (TyCon "Option") (TyCon "Directive")) (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "dirToList" ((PCon "None")) (EListLit))
(DFunDef false "dirToList" ((PCon "Some" (PVar "d"))) (EListLit (EVar "d")))
(DTypeSig true "parseDirective" (TyFun (TyCon "Comment") (TyApp (TyCon "Option") (TyCon "Directive"))))
(DFunDef false "parseDirective" ((PVar "c")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "trimWs") (EApp (EVar "commentText") (EVar "c")))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "body")) (EApp (EApp (EVar "parseDirectiveBody") (EApp (EVar "commentLine") (EVar "c"))) (EApp (EVar "trimWs") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "body"))) (EVar "body")))) (EVar "None")))))
(DTypeSig false "lintDisableNextLineRe" (TyCon "Regex"))
(DFunDef false "lintDisableNextLineRe" () (EApp (EVar "keywordRe") (ELit (LString "lint-disable-next-line"))))
(DTypeSig false "lintDisableLineRe" (TyCon "Regex"))
(DFunDef false "lintDisableLineRe" () (EApp (EVar "keywordRe") (ELit (LString "lint-disable-line"))))
(DTypeSig false "lintDisableFileRe" (TyCon "Regex"))
(DFunDef false "lintDisableFileRe" () (EApp (EVar "keywordRe") (ELit (LString "lint-disable-file"))))
(DTypeSig false "keywordRe" (TyFun (TyCon "String") (TyCon "Regex")))
(DFunDef false "keywordRe" ((PVar "kw")) (EApp (EVar "mustCompile") (EBinOp "++" (EBinOp "++" (ELit (LString "^")) (EApp (EVar "escape") (EVar "kw"))) (ELit (LString "($|[ \\t].*)$")))))
(DTypeSig false "parseDirectiveBody" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Directive")))))
(DFunDef false "parseDirectiveBody" ((PVar "line") (PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "lint-"))) (EVar "s")) (EApp (EApp (EVar "parseDirectiveKeyword") (EVar "line")) (EVar "s")) (EVar "None")))
(DTypeSig false "parseDirectiveKeyword" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Directive")))))
(DFunDef false "parseDirectiveKeyword" ((PVar "line") (PVar "s")) (EMatch (EApp (EApp (EVar "matchKeyword") (EVar "lintDisableNextLineRe")) (EVar "s")) (arm (PCon "Some" (PVar "names")) () (EApp (EVar "Some") (EApp (EApp (EVar "Directive") (EApp (EVar "DScopeLine") (EBinOp "+" (EVar "line") (ELit (LInt 1))))) (EApp (EVar "parseRuleNames") (EVar "names"))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "matchKeyword") (EVar "lintDisableLineRe")) (EVar "s")) (arm (PCon "Some" (PVar "names")) () (EApp (EVar "Some") (EApp (EApp (EVar "Directive") (EApp (EVar "DScopeLine") (EVar "line"))) (EApp (EVar "parseRuleNames") (EVar "names"))))) (arm (PCon "None") () (EApp (EApp (EMethodRef "map") (ELam ((PVar "names")) (EApp (EApp (EVar "Directive") (EVar "DScopeFile")) (EApp (EVar "parseRuleNames") (EVar "names"))))) (EApp (EApp (EVar "matchKeyword") (EVar "lintDisableFileRe")) (EVar "s"))))))))
(DTypeSig false "matchKeyword" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "matchKeyword" ((PVar "re") (PVar "s")) (EMatch (EApp (EApp (EVar "reFind") (EVar "re")) (EVar "s")) (arm (PCon "Some" (PVar "m")) () (EMatch (EFieldAccess (EVar "m") "groups") (arm (PCons (PCon "Some" (PVar "g")) PWild) () (EApp (EVar "Some") (EApp (EVar "trimWs") (EFieldAccess (EVar "g") "text")))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "parseRuleNames" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "parseRuleNames" ((PVar "s")) (EApp (EApp (EVar "filterList") (EVar "nonEmptyStr")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "splitOnChar") (ELit (LChar " ")))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar ","))) (EVar "s")))))
(DTypeSig false "nonEmptyStr" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonEmptyStr" ((PVar "n")) (EBinOp "/=" (EVar "n") (ELit (LString ""))))
(DTypeSig true "trimWs" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trimWs" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "a") (EApp (EApp (EApp (EVar "trimWsStart") (EVar "cs")) (EVar "n")) (ELit (LInt 0)))) (DoLet false false (PVar "b") (EApp (EApp (EApp (EVar "trimWsEnd") (EVar "cs")) (EVar "a")) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EVar "s")))))
(DTypeSig false "trimWsStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimWsStart" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "i") (EIf (EApp (EVar "isWsChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "trimWsStart") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "trimWsEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimWsEnd" ((PVar "cs") (PVar "a") (PVar "n")) (EIf (EBinOp "<=" (EVar "n") (EVar "a")) (EVar "a") (EIf (EApp (EVar "isWsChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "cs"))) (EApp (EApp (EApp (EVar "trimWsEnd") (EVar "cs")) (EVar "a")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "n") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isWsChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isWsChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar " "))) (EBinOp "==" (EVar "c") (ELit (LChar "\t")))) (EBinOp "==" (EVar "c") (ELit (LChar "\r")))) (EBinOp "==" (EVar "c") (ELit (LChar "\n")))))
(DTypeSig true "unwrapLoc" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "unwrapLoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "unwrapLoc") (EVar "e")))
(DFunDef false "unwrapLoc" ((PVar "e")) (EVar "e"))
(DTypeSig true "declLocList" (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "declLocList" ((PVar "pos") (PVar "prog")) (EApp (EApp (EVar "zipDeclLoc") (EVar "prog")) (EApp (EVar "positionsDecls") (EVar "pos"))))
(DTypeSig false "zipDeclLoc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "zipDeclLoc" ((PList) PWild) (EListLit))
(DFunDef false "zipDeclLoc" ((PCons (PVar "d") (PVar "ds")) (PList)) (EBinOp "::" (ETuple (EVar "d") (EVar "None")) (EApp (EApp (EVar "zipDeclLoc") (EVar "ds")) (EListLit))))
(DFunDef false "zipDeclLoc" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EBinOp "::" (ETuple (EVar "d") (EApp (EVar "Some") (EApp (EVar "declPosToLoc") (EVar "p")))) (EApp (EApp (EVar "zipDeclLoc") (EVar "ds")) (EVar "ps"))))
(DTypeSig false "declPosToLoc" (TyFun (TyCon "DeclPos") (TyCon "Loc")))
(DFunDef false "declPosToLoc" ((PVar "p")) (ELet false (PVar "l") (EApp (EVar "declPosLine") (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "l")) (ELit (LInt 1))) (EVar "l")) (ELit (LInt 1)))))
(DTypeSig true "isBareParam" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "isBareParam" ((PVar "p") (PCon "PVar" (PVar "q") PWild PWild)) (EBinOp "==" (EVar "p") (EVar "q")))
(DFunDef false "isBareParam" (PWild PWild) (EVar "False"))
(DTypeSig true "matchBodyOnBareParam" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Arm")))))))
(DFunDef false "matchBodyOnBareParam" ((PVar "pats") (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EMatch" (PVar "scrut") (PVar "arms")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "scrut")) (arm (PCon "EVar" (PVar "p")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "k")) (ETuple (EVar "p") (EVar "k") (EVar "arms")))) (EApp (EApp (EVar "paramIndex") (EVar "p")) (EVar "pats")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig true "patIsWild" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patIsWild" ((PCon "PWild")) (EVar "True"))
(DFunDef false "patIsWild" (PWild) (EVar "False"))
(DTypeSig false "paramIndex" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "paramIndex" ((PVar "p") (PVar "pats")) (EApp (EApp (EApp (EVar "paramIndexGo") (EVar "p")) (EVar "pats")) (ELit (LInt 0))))
(DTypeSig false "paramIndexGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "paramIndexGo" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "paramIndexGo" ((PVar "p") (PCons (PVar "pat") (PVar "rest")) (PVar "i")) (EIf (EApp (EApp (EVar "isBareParam") (EVar "p")) (EVar "pat")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "paramIndexGo") (EVar "p")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "armToClause" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Int") (TyFun (TyCon "Arm") (TyCon "Decl"))))))))
(DFunDef false "armToClause" ((PVar "vis") (PVar "name") (PVar "p") (PVar "pats") (PVar "k") (PCon "Arm" (PVar "pat") PWild (PVar "body"))) (EBlock (DoLet false false (PVar "cpat") (EIf (EBinOp "&&" (EApp (EVar "patIsWild") (EVar "pat")) (EApp (EApp (EVar "wholeWordIn") (EVar "p")) (EApp (EVar "exprToString") (EVar "body")))) (EApp (EApp (EApp (EVar "PVar") (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EApp (EApp (EApp (EVar "replaceAt") (EVar "k")) (EVar "cpat")) (EVar "pats"))) (EVar "body")) (EVar "noDeclLoc")) (EVar "noBinderId")))))
(DTypeSig false "replaceAt" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "replaceAt" (PWild PWild (PList)) (EListLit))
(DFunDef false "replaceAt" ((PLit (LInt 0)) (PVar "x") (PCons PWild (PVar "rest"))) (EBinOp "::" (EVar "x") (EVar "rest")))
(DFunDef false "replaceAt" ((PVar "n") (PVar "x") (PCons (PVar "y") (PVar "rest"))) (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "replaceAt") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "x")) (EVar "rest"))))
(DTypeSig true "wholeWordIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "wholeWordIn" ((PVar "name") (PVar "s")) (EApp (EApp (EVar "isMatch") (EApp (EVar "mustCompile") (EApp (EVar "wholeWordPattern") (EVar "name")))) (EVar "s")))
(DTypeSig false "wholeWordPattern" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "wholeWordPattern" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "(?:^|[^A-Za-z0-9_'])")) (EApp (EVar "escape") (EVar "name"))) (ELit (LString "(?:$|[^A-Za-z0-9_'])"))))
(DTypeSig true "ctorIsSingle" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ctorIsSingle" ((PVar "orc") (PVar "c")) (EMatch (EApp (EApp (EVar "oGetCtorSiblings") (EVar "orc")) (EVar "c")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "==" (EApp (EVar "listLen") (EVar "ctors")) (ELit (LInt 1)))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "tyHeadName" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "tyHeadName" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "tyHeadName" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "tyHeadName") (EVar "f")))
(DFunDef false "tyHeadName" (PWild) (EVar "None"))
(DTypeSig true "topDefNameL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "topDefNameL" ((PTuple (PCon "DFunDef" PWild (PVar "name") PWild PWild PWild PWild) (PVar "loc"))) (EListLit (ETuple (EVar "name") (EVar "loc"))))
(DFunDef false "topDefNameL" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "topDefNameL") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "topDefNameL" (PWild) (EListLit))
(DTypeSig true "dedupeNamesLoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "dedupeNamesLoc" ((PVar "xs")) (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EVar "xs")))
(DTypeSig true "clausesOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesOf" (PWild (PList)) (EListLit))
(DFunDef false "clausesOf" ((PVar "name") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "clausesOf") (EVar "name")) (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "clausesOf" ((PVar "name") (PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") PWild PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "::" (ETuple (EVar "ps") (EVar "body")) (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "clausesOf" ((PVar "name") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "rest")))
(DTypeSig true "stripELoc" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripELoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripELoc") (EVar "e")))
(DFunDef false "stripELoc" ((PVar "e")) (EVar "e"))
(DTypeSig true "appSpineOf" (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "appSpineOf" ((PVar "e")) (EApp (EApp (EVar "appSpineGo") (EVar "e")) (EListLit)))
(DTypeSig false "appSpineGo" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "appSpineGo" ((PVar "e") (PVar "acc")) (EMatch (EApp (EVar "stripELoc") (EVar "e")) (arm (PCon "EApp" (PVar "f") (PVar "a")) () (EApp (EApp (EVar "appSpineGo") (EVar "f")) (EBinOp "::" (EVar "a") (EVar "acc")))) (arm (PVar "other") () (ETuple (EVar "other") (EVar "acc")))))
(DTypeSig true "paramNameOf" (TyFun (TyCon "Pat") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "paramNameOf" ((PCon "PVar" (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "paramNameOf" (PWild) (EVar "None"))
(DTypeSig true "memberLocalIfOrigin" (TyFun (TyCon "String") (TyFun (TyCon "UseMember") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "memberLocalIfOrigin" ((PVar "stdName") (PCon "UseMember" (PVar "origin") PWild PWild (PVar "alias"))) (EIf (EBinOp "==" (EVar "origin") (EVar "stdName")) (EApp (EVar "Some") (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EVar "origin")))) (EVar "None")))
(DTypeSig true "lastSegOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastSegOf" ((PList)) (ELit (LString "")))
(DFunDef false "lastSegOf" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastSegOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastSegOf") (EVar "rest")))
(DTypeSig true "childExprs" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "childExprs" ((PCon "ELoc" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EDoOrigin" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EApp" (PVar "f") (PVar "x"))) (EListLit (EVar "f") (EVar "x")))
(DFunDef false "childExprs" ((PCon "ELam" PWild (PVar "b"))) (EListLit (EVar "b")))
(DFunDef false "childExprs" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EListLit (EVar "e1") (EVar "e2")))
(DFunDef false "childExprs" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EBinOp "::" (EVar "s") (EApp (EApp (EDictApp "flatMap") (EVar "armExprs")) (EVar "arms"))))
(DFunDef false "childExprs" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EListLit (EVar "c") (EVar "t") (EVar "el")))
(DFunDef false "childExprs" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EListLit (EVar "a") (EVar "b")))
(DFunDef false "childExprs" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EListLit (EVar "a")))
(DFunDef false "childExprs" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EListLit (EVar "a") (EVar "b")))
(DFunDef false "childExprs" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "ETuple" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EListLit" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EArrayLit" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "e") (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "letBindExprs")) (EVar "binds")) (EListLit (EVar "body"))))
(DFunDef false "childExprs" ((PCon "ESection" (PVar "s"))) (EApp (EVar "sectionExprs") (EVar "s")))
(DFunDef false "childExprs" ((PCon "EIndex" (PVar "a") (PVar "i"))) (EListLit (EVar "a") (EVar "i")))
(DFunDef false "childExprs" ((PCon "EAnnot" (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "stmtExprs")) (EVar "stmts")))
(DFunDef false "childExprs" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "stmtExprs")) (EVar "stmts")))
(DFunDef false "childExprs" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EDictApp "flatMap") (EVar "interpPartExprs")) (EVar "parts")))
(DFunDef false "childExprs" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EDictApp "flatMap") (EVar "guardArmExprs")) (EVar "arms")))
(DFunDef false "childExprs" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EMethodRef "map") (EVar "fieldAssignExpr")) (EVar "fs")))
(DFunDef false "childExprs" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBinOp "::" (EVar "e") (EApp (EApp (EMethodRef "map") (EVar "fieldAssignExpr")) (EVar "fs"))))
(DFunDef false "childExprs" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "::" (EVar "e") (EApp (EApp (EMethodRef "map") (EVar "fieldAssignExpr")) (EVar "fs"))))
(DFunDef false "childExprs" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EDictApp "flatMap") (EVar "kvExprs")) (EVar "kvs")))
(DFunDef false "childExprs" ((PCon "ESetLit" PWild (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EAsPat" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EOrPat" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" (PWild) (EListLit))
(DTypeSig false "armExprs" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "armExprs" ((PCon "Arm" PWild (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardExprs")) (EVar "gs")) (EListLit (EVar "body"))))
(DTypeSig false "guardExprs" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "guardExprs" ((PCon "GBool" (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "guardExprs" ((PCon "GBind" PWild (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig true "stmtExprs" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "stmtExprs" ((PCon "DoExpr" (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoBind" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoAssign" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "letBindExprs" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "letBindExprs" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "funClauseExprs")) (EVar "clauses")))
(DTypeSig false "funClauseExprs" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "funClauseExprs" ((PCon "FunClause" PWild (PVar "body"))) (EListLit (EVar "body")))
(DTypeSig false "sectionExprs" (TyFun (TyCon "Section") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "sectionExprs" ((PCon "SecBare" PWild)) (EListLit))
(DFunDef false "sectionExprs" ((PCon "SecRight" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "sectionExprs" ((PCon "SecLeft" (PVar "e") PWild)) (EListLit (EVar "e")))
(DTypeSig false "interpPartExprs" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "interpPartExprs" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpPartExprs" ((PCon "InterpExpr" (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "guardArmExprs" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "guardArmExprs" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardExprs")) (EVar "gs")) (EListLit (EVar "body"))))
(DTypeSig false "fieldAssignExpr" (TyFun (TyCon "FieldAssign") (TyCon "Expr")))
(DFunDef false "fieldAssignExpr" ((PCon "FieldAssign" PWild (PVar "e"))) (EVar "e"))
(DTypeSig false "kvExprs" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "kvExprs" ((PTuple (PVar "k") (PVar "v"))) (EListLit (EVar "k") (EVar "v")))
(DTypeSig true "isEVarNamed" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isEVarNamed" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EBinOp "==" (EVar "w") (EVar "x"))) (arm PWild () (EVar "False"))))
(DTypeSig true "mentionsVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "mentionsVar" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EBinOp "==" (EVar "w") (EVar "x"))) (arm (PVar "e2") () (EApp (EApp (EVar "anyList") (EApp (EVar "mentionsVar") (EVar "x"))) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig true "implMethodsBodyKey" (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "String")))
(DFunDef false "implMethodsBodyKey" ((PVar "ms")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "implMethodBodySexp")) (EVar "ms"))))
(DTypeSig false "implMethodBodySexp" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodBodySexp" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "exprSexp") (EVar "body")))
(DTypeSig true "andThenEtaFn" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "andThenEtaFn" ((PVar "x") (PVar "arg")) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg")) (arm (PCon "EApp" (PVar "f") (PVar "lastArg")) ((GBool (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "lastArg")) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EVar "f")))))) (EApp (EVar "Some") (EVar "f"))) (arm PWild () (EVar "None"))))
(DTypeSig true "mapChildExprs" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PVar "e")) (EApp (EApp (EVar "mapChildren") (EVar "g")) (EVar "e")))
(DTypeSig true "rewriteExprBU" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteExprBU" ((PVar "f") (PVar "e")) (EApp (EVar "f") (EApp (EApp (EVar "mapChildExprs") (EApp (EVar "rewriteExprBU") (EVar "f"))) (EVar "e"))))
(DTypeSig true "detApply" (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "detApply" ((PVar "det") (PVar "e")) (EMatch (EApp (EVar "det") (EVar "e")) (arm (PCon "Some" (PVar "e2")) () (EVar "e2")) (arm (PCon "None") () (EVar "e"))))
(DTypeSig true "exprRuleFindings" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))) (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "exprRuleFindings" ((PVar "excl") (PVar "det") (PVar "mkFinding") (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "exprRuleDeclL") (EVar "excl")) (EVar "det")) (EVar "mkFinding"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "exprRuleDeclL" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))) (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "exprRuleDeclL" ((PVar "excl") (PVar "det") (PVar "mkFinding") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "hitLoc") (PVar "hit"))) (EApp (EApp (EVar "mkFinding") (EVar "hitLoc")) (EVar "hit")))) (EApp (EApp (EApp (EApp (EVar "declRewriteHits") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d"))))
(DTypeSig false "declRewriteHits" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr"))))))))
(DFunDef false "declRewriteHits" ((PVar "excl") (PVar "det") (PVar "loc") (PCon "DFunDef" PWild (PVar "name") PWild (PVar "body") PWild PWild)) (EIf (EApp (EVar "excl") (EVar "name")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collectRewrites") (EVar "loc")) (EVar "det")) (EVar "body")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "declRewriteHits" (PWild (PVar "det") (PVar "loc") (PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "implMethodRewriteHits") (EVar "loc")) (EVar "det"))) (EVar "methods")))
(DFunDef false "declRewriteHits" ((PVar "excl") (PVar "det") (PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "declRewriteHits") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d")))
(DFunDef false "declRewriteHits" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "implMethodRewriteHits" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr")))))))
(DFunDef false "implMethodRewriteHits" ((PVar "loc") (PVar "det") (PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EVar "collectRewrites") (EVar "loc")) (EVar "det")) (EVar "body")))
(DTypeSig true "collectRewrites" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr")))))))
(DFunDef false "collectRewrites" (PWild (PVar "det") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EVar "collectRewrites") (EApp (EVar "Some") (EVar "l"))) (EVar "det")) (EVar "e")))
(DFunDef false "collectRewrites" ((PVar "curLoc") (PVar "det") (PVar "e")) (EBinOp "++" (EApp (EApp (EVar "optExprToLocList") (EVar "curLoc")) (EApp (EVar "det") (EVar "e"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "collectRewrites") (EVar "curLoc")) (EVar "det"))) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "optExprToLocList" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr"))))))
(DFunDef false "optExprToLocList" (PWild (PCon "None")) (EListLit))
(DFunDef false "optExprToLocList" ((PVar "loc") (PCon "Some" (PVar "x"))) (EListLit (ETuple (EVar "loc") (EVar "x"))))
(DTypeSig true "exprRuleFix" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "exprRuleFix" ((PVar "excl") (PVar "f") (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EIf (EApp (EVar "excl") (EVar "name")) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "body2") (EApp (EApp (EVar "rewriteExprBU") (EVar "f")) (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2")) (EVar "site")) (EVar "bid"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "exprRuleFix" ((PVar "excl") (PVar "f") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "excl")) (EVar "f")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "exprRuleFix" (PWild (PVar "f") (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild) (rf "methods" None)) false))) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EMethodRef "map") (EApp (EVar "fixImplMethodWith") (EVar "f"))) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EVar "methods2"))))))))))
(DFunDef false "exprRuleFix" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodWith" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "fixImplMethodWith" ((PVar "f") (PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EApp (EVar "rewriteExprBU") (EVar "f")) (EVar "body"))))
(DTypeSig true "noExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "noExcl" (PWild) (EVar "False"))
(DTypeSig true "exprRuleFindingsInTests" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))) (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "exprRuleFindingsInTests" ((PVar "excl") (PVar "det") (PVar "mkFinding") (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "exprRuleDeclLInTests") (EVar "excl")) (EVar "det")) (EVar "mkFinding"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "exprRuleDeclLInTests" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))) (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "exprRuleDeclLInTests" ((PVar "excl") (PVar "det") (PVar "mkFinding") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "hitLoc") (PVar "hit"))) (EApp (EApp (EVar "mkFinding") (EVar "hitLoc")) (EVar "hit")))) (EApp (EApp (EApp (EApp (EVar "declRewriteHitsInTests") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d"))))
(DTypeSig false "declRewriteHitsInTests" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr"))))))))
(DFunDef false "declRewriteHitsInTests" (PWild (PVar "det") (PVar "loc") (PCon "DTest" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EVar "collectRewrites") (EVar "loc")) (EVar "det")) (EVar "body")))
(DFunDef false "declRewriteHitsInTests" (PWild (PVar "det") (PVar "loc") (PCon "DProp" PWild PWild PWild (PVar "body"))) (EApp (EApp (EApp (EVar "collectRewrites") (EVar "loc")) (EVar "det")) (EVar "body")))
(DFunDef false "declRewriteHitsInTests" ((PVar "excl") (PVar "det") (PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "declRewriteHitsInTests") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d")))
(DFunDef false "declRewriteHitsInTests" ((PVar "excl") (PVar "det") (PVar "loc") (PVar "d")) (EApp (EApp (EApp (EApp (EVar "declRewriteHits") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d")))
(DTypeSig true "exprRuleFixInTests" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "exprRuleFixInTests" (PWild (PVar "f") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "testDeclFix") (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name"))) (EVar "f")) (EVar "body")))
(DFunDef false "exprRuleFixInTests" (PWild (PVar "f") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "testDeclFix") (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "ps"))) (EVar "f")) (EVar "body")))
(DFunDef false "exprRuleFixInTests" ((PVar "excl") (PVar "f") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EApp (EVar "exprRuleFixInTests") (EVar "excl")) (EVar "f")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "exprRuleFixInTests" ((PVar "excl") (PVar "f") (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "excl")) (EVar "f")) (EVar "d")))
(DTypeSig false "testDeclFix" (TyFun (TyFun (TyCon "Expr") (TyCon "Decl")) (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "testDeclFix" ((PVar "rebuild") (PVar "f") (PVar "body")) (EBlock (DoLet false false (PVar "body2") (EApp (EApp (EVar "rewriteExprBU") (EVar "f")) (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EVar "rebuild") (EVar "body2"))))))))
(DTypeSig true "notArgOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "notArgOf" ((PCon "EApp" (PVar "hd") (PVar "x"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "not"))) (EVar "hd")) (EApp (EVar "Some") (EVar "x")) (EVar "None")))
(DFunDef false "notArgOf" (PWild) (EVar "None"))
(DTypeSig true "isTrueLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isTrueLit" ((PVar "e")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "True"))) (EVar "e")))
(DTypeSig true "isFalseLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isFalseLit" ((PVar "e")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "False"))) (EVar "e")))
(DTypeSig true "isBoolLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isBoolLit" ((PVar "e")) (EBinOp "||" (EApp (EVar "isTrueLit") (EVar "e")) (EApp (EVar "isFalseLit") (EVar "e"))))
(DTypeSig true "isNilPCon" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "isNilPCon" ((PVar "name") (PCon "PCon" (PVar "n") (PList))) (EBinOp "==" (EVar "n") (EVar "name")))
(DFunDef false "isNilPCon" (PWild PWild) (EVar "False"))
(DTypeSig true "matchToMapTransform" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "Pat") (TyCon "Expr")))))))
(DFunDef false "matchToMapTransform" ((PVar "ctor") (PCon "PCon" (PVar "c") (PList (PVar "binder"))) (PVar "body")) (EIf (EBinOp "==" (EVar "c") (EVar "ctor")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "hd") (PVar "inner")) () (EIf (EApp (EApp (EVar "isEVarNamed") (EVar "ctor")) (EVar "hd")) (EApp (EVar "Some") (ETuple (EVar "binder") (EVar "inner"))) (EVar "None"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "matchToMapTransform" (PWild PWild PWild) (EVar "None"))
(DTypeSig true "ctorVarPassthru" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "ctorVarPassthru" ((PVar "ctor") (PCon "PCon" (PVar "c") (PList (PCon "PVar" (PVar "v") PWild PWild))) (PVar "body")) (EIf (EBinOp "==" (EVar "c") (EVar "ctor")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "hd") (PVar "arg")) () (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "ctor")) (EVar "hd")) (EApp (EApp (EVar "isEVarNamed") (EVar "v")) (EVar "arg")))) (arm PWild () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "ctorVarPassthru" (PWild PWild PWild) (EVar "False"))
(DTypeSig true "matchToMapErrPassthru" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "matchToMapErrPassthru" ((PVar "p") (PVar "body")) (EApp (EApp (EApp (EVar "ctorVarPassthru") (ELit (LString "Err"))) (EVar "p")) (EVar "body")))
(DTypeSig true "matchScrutOf" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "matchScrutOf" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EMatch" (PVar "s") PWild) () (EVar "s")) (arm PWild () (EVar "e"))))
(DTypeSig true "codePortions" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "codePortions" ((PList) PWild PWild) (EListLit))
(DFunDef false "codePortions" ((PCons (PVar "l") (PVar "rest")) (PList) (PVar "n")) (EBinOp "::" (EVar "l") (EApp (EApp (EApp (EVar "codePortions") (EVar "rest")) (EListLit)) (EBinOp "+" (EVar "n") (ELit (LInt 1))))))
(DFunDef false "codePortions" ((PCons (PVar "l") (PVar "rest")) (PCons (PVar "c") (PVar "cs")) (PVar "n")) (EIf (EBinOp "<" (EApp (EVar "commentLine") (EVar "c")) (EVar "n")) (EApp (EApp (EApp (EVar "codePortions") (EBinOp "::" (EVar "l") (EVar "rest"))) (EVar "cs")) (EVar "n")) (EIf (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EVar "n")) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EApp (EVar "commentCol") (EVar "c"))) (EVar "l")) (EApp (EApp (EApp (EVar "codePortions") (EVar "rest")) (EVar "cs")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "l") (EApp (EApp (EApp (EVar "codePortions") (EVar "rest")) (EBinOp "::" (EVar "c") (EVar "cs"))) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DData Public "CommentBlock" () ((variant "CommentBlock" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Bool") (TyCon "String")))) ())
(DTypeSig true "commentBlocks" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyApp (TyCon "List") (TyCon "CommentBlock")))))
(DFunDef false "commentBlocks" ((PList) PWild) (EListLit))
(DFunDef false "commentBlocks" ((PCons (PVar "c") (PVar "rest")) (PVar "codeLines")) (EBlock (DoLet false false (PVar "line") (EApp (EVar "commentLine") (EVar "c"))) (DoLet false false (PVar "trailing") (EBinOp "/=" (EApp (EVar "trimWs") (EApp (EApp (EVar "codeLineAt") (EVar "codeLines")) (EVar "line"))) (ELit (LString "")))) (DoExpr (EIf (EVar "trailing") (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "CommentBlock") (EVar "line")) (EVar "line")) (EVar "True")) (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EVar "commentBlocks") (EVar "rest")) (EVar "codeLines"))) (EMatch (EApp (EApp (EApp (EApp (EVar "commentBlockExtend") (EVar "rest")) (EVar "codeLines")) (EVar "line")) (EApp (EVar "commentText") (EVar "c"))) (arm (PTuple (PVar "lastLine") (PVar "text") (PVar "rest2")) () (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "CommentBlock") (EVar "line")) (EVar "lastLine")) (EVar "False")) (EVar "text")) (EApp (EApp (EVar "commentBlocks") (EVar "rest2")) (EVar "codeLines")))))))))
(DTypeSig false "commentBlockExtend" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyTuple (TyCon "Int") (TyCon "String") (TyApp (TyCon "List") (TyCon "Comment"))))))))
(DFunDef false "commentBlockExtend" ((PList) PWild (PVar "last") (PVar "text")) (ETuple (EVar "last") (EVar "text") (EListLit)))
(DFunDef false "commentBlockExtend" ((PCons (PVar "c") (PVar "rest")) (PVar "codeLines") (PVar "last") (PVar "text")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "commentLine") (EVar "c")) (EBinOp "+" (EVar "last") (ELit (LInt 1)))) (EBinOp "==" (EApp (EVar "trimWs") (EApp (EApp (EVar "codeLineAt") (EVar "codeLines")) (EBinOp "+" (EVar "last") (ELit (LInt 1))))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EVar "commentBlockExtend") (EVar "rest")) (EVar "codeLines")) (EBinOp "+" (EVar "last") (ELit (LInt 1)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "text"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "commentText") (EVar "c")))) (ELit (LString "")))) (EIf (EVar "otherwise") (ETuple (EVar "last") (EVar "text") (EBinOp "::" (EVar "c") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "codeLineAt" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "codeLineAt" ((PVar "codeLines") (PVar "line")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "line") (ELit (LInt 1))) (EBinOp "<=" (EVar "line") (EApp (EVar "arrayLength") (EVar "codeLines")))) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EVar "codeLines")) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "nameSetOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "nameSetOf" ((PVar "names")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "nameSetInto") (EVar "names")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "nameSetInto" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "nameSetInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "nameSetInto" ((PCons (PVar "n") (PVar "rest")) (PVar "s")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (ELit LUnit)) (EVar "s"))) (DoExpr (EApp (EApp (EVar "nameSetInto") (EVar "rest")) (EVar "s")))))
