# META
source_lines=316
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_shared.mdk — helpers used by more than one lint module:
-- the rule-name constants, location and trimming helpers, the suppression
-- directive parser, and the stdlib path predicates.

import frontend.ast.{Loc(..), Expr(..), Decl(..)}
import frontend.parser.{Positions(..), DeclPos, positionsDecls, declPosLine}
import driver.diagnostics.{Severity(..), Diag(..), DiagId(..)}
import support.util.{contains, filterList, splitOnChar, joinWith, startsWith}
import list.{sortBy}
import support.path.{stripMdk}
import regex.{Regex, mustCompile, find as reFind, escape}
import frontend.lexer.{Comment, commentLine, commentText}
import tools.lint_core.{DirScope(..), Directive(..)}

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
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true) (mem "DiagId" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "filterList" false) (mem "splitOnChar" false) (mem "joinWith" false) (mem "startsWith" false))))
(DUse false (UseGroup ("list") ((mem "sortBy" false))))
(DUse false (UseGroup ("support" "path") ((mem "stripMdk" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "mustCompile" false) (mem "find" false "reFind") (mem "escape" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "DirScope" true) (mem "Directive" true))))
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
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true) (mem "DiagId" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "filterList" false) (mem "splitOnChar" false) (mem "joinWith" false) (mem "startsWith" false))))
(DUse false (UseGroup ("list") ((mem "sortBy" false))))
(DUse false (UseGroup ("support" "path") ((mem "stripMdk" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "mustCompile" false) (mem "find" false "reFind") (mem "escape" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "DirScope" true) (mem "Directive" true))))
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
