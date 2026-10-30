# META
source_lines=274
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-directive-reason: a `-- lint-disable-*` directive with no comment in its own comment block stating the constraint that forced it. An issue number alone is not a reason.

import frontend.ast.{Loc(..), Decl(..)}
import frontend.parser.{
  Positions(..),
  DeclPos,
  positionsDecls,
  declPosLine,
  declPosEndLine,
}
import driver.diagnostics.{Severity(..)}
import support.util.{contains, anyList, filterList, splitNl, isSome}
import string.{toLower, words}
import regex.{Regex, mustCompile, isMatch}
import frontend.lexer.{Comment, commentLine, commentText}
import tools.lint_core.{
  Category(..),
  DirScope(..),
  Directive(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  factComments,
  mkRule,
}
import tools.lint_shared.{
  CommentBlock(..),
  codePortions,
  commentBlocks,
  parseDirective,
  ruleNameDirectiveReason,
  zipDeclPos,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameDirectiveReason,
      summary =
        "a `-- lint-disable-*` directive with no comment in its own comment block stating the constraint that forced it — an issue number alone is not a reason (#2862)",
      doc =
        "A `-- lint-disable-*` directive needs a comment in its own comment block stating the constraint that forced it; an issue number alone is not a reason (#2862). This enforces the repository suppression convention.\n\nBefore:\n  -- lint-disable-next-line rule-x\nAfter:\n  -- bounded: at most 3 fields, so a list lookup is cheaper\n  -- lint-disable-next-line rule-x",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleDirectiveReason
    None

-- A `-- lint-disable-*` directive with no comment stating the constraint that
-- forced it is itself a finding: the same failure mode the-baseline-goes-down
-- sprint found only by hand.
--
-- The reason must live in the SAME contiguous comment block as the directive
-- (`commentBlocks`/`codePortions`, rule-promissory-reader's helpers, reused
-- unmodified above) — above it, below it, or beside another directive in the
-- same block. Several existing file-scope directives sit on line 1, where
-- nothing can precede them, and state their reason in the lines that follow
-- instead (`compiler/tools/lsp.mdk`, `compiler/backend/wasm_emit.mdk`); the
-- same-block rule (rather than "immediately above only") is what keeps this
-- rule silent on those.
--
-- A `lint-disable-line`/`lint-disable-next-line` directive whose own block
-- has no reason gets ONE fallback: `export\n<name> : <type>` (or a bare
-- signature line alone) can sit between a leading doc comment and the
-- directive, breaking block contiguity even though a reader plainly reads
-- that comment as the declaration's reason (`compiler/tools/lint.mdk`'s own
-- `trimWs`, `compiler/entries/entry_support.mdk`'s `failWith`). The parsed
-- AST already threads `Positions` into every rule, so instead of guessing
-- what a "signature-only" line looks like, find the `DeclPos` the directive's
-- target line falls inside and check the comment block ending immediately
-- before THAT declaration starts.
--
-- A block counts as reasoned when some OTHER comment in it (not a directive
-- line itself) has a "substantive word": a run of at least 4 alphabetic
-- characters. Digits and `#` never contribute, so a bare issue reference
-- (`#1234`) is never one; short connector words ("see", "cf", "ref") aren't
-- either, so `-- see #1234` does not count as a reason.
ruleDirectiveReason : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleDirectiveReason _ _ facts pos prog =
  let comments = factComments facts
  let ls = splitNl facts.ffSrc
  let codeLines = arrayFromList (codePortions ls comments 1)
  let blocks = commentBlocks comments codeLines
  let declZips = zipDeclPos prog (positionsDecls pos)
  let dirCmts = filterList (c => isSome (parseDirective c)) comments
  flatMap (directiveReasonCheck comments blocks declZips) dirCmts

directiveReasonCheck : List Comment ->
  List CommentBlock ->
  List (Decl, DeclPos) ->
  Comment ->
  List Finding
directiveReasonCheck comments blocks declZips c =
  if directiveReasoned comments blocks declZips c then
    []
  else
    [directiveReasonFinding c]

directiveReasoned : List Comment ->
  List CommentBlock ->
  List (Decl, DeclPos) ->
  Comment ->
  Bool
directiveReasoned comments blocks declZips c =
  let ownReasoned = match find (commentBlockContainsLine (commentLine c)) blocks
    Some b => blockHasReason comments b
    None => False
  if ownReasoned then
    True
  else match parseDirective c
    Some (Directive (DScopeLine target) _) =>
      declGapReasoned
        comments
        blocks
        declZips
        (declZipNameAt declZips target)
        (commentLine c)
    Some (Directive DScopeFile _) => False
    None => False

-- Walk backward from `line` through a CHAIN of declarations that abut it
-- exactly (no blank line between): a signature-only `DTypeSig` (alone or
-- `export`-prefixed) between a leading doc comment and the directive it
-- explains — `compiler/tools/lint.mdk`'s own `trimWs` a few hundred lines
-- above this rule, `compiler/entries/entry_support.mdk`'s `failWith` — or a
-- one-line-per-clause function whose OWN signature sits one hop further back
-- (`compiler/types/route_key.mdk`'s `rkEffAtom`: directive between its two
-- clauses, reason above the signature two hops up). Each hop requires the
-- PRECEDING declaration to end on the exact line before AND to be the SAME
-- declaration the directive suppresses — a `DTypeSig`/`DFunDef` sharing the
-- target's own name — so a real blank line still stops the walk, and so does
-- an adjacent but UNRELATED top-level declaration (a different function's
-- doc comment must never be credited to this directive).
declGapReasoned : List Comment ->
  List CommentBlock ->
  List (Decl, DeclPos) ->
  Option String ->
  Int ->
  Bool
declGapReasoned comments blocks declZips targetName line =
  match find (commentBlockEndsAt (line - 1)) blocks
    Some b => blockHasReason comments b
    None => match find (declZipEndsAt (line - 1)) declZips
      Some (d, dp) =>
        if declGapNameMatches targetName d then
          declGapReasoned comments blocks declZips targetName (declPosLine dp)
        else
          False
      None => False

-- The name of the declaration the directive's target `line` falls inside —
-- `None` when no top-level `DTypeSig`/`DFunDef` covers that line (a
-- different decl kind, or the directive is the last thing in the file), in
-- which case `declGapNameMatches` below never credits a gap hop.
declZipNameAt : List (Decl, DeclPos) -> Int -> Option String
declZipNameAt declZips line = match find (declZipContainsLine line) declZips
  Some (d, _) => declBridgeName d
  None => None

declZipContainsLine : Int -> (Decl, DeclPos) -> Bool
declZipContainsLine line (_, dp) =
  declPosLine dp <= line && declPosEndLine dp >= line

declBridgeName : Decl -> Option String
declBridgeName (DTypeSig _ n _ _) = Some n
declBridgeName (DFunDef _ n _ _ _ _) = Some n
declBridgeName _ = None

declGapNameMatches : Option String -> Decl -> Bool
declGapNameMatches (Some target) d = match declBridgeName d
  Some n => n == target
  None => False
declGapNameMatches None _ = False

commentBlockContainsLine : Int -> CommentBlock -> Bool
commentBlockContainsLine line (CommentBlock first last _ _) =
  line >= first && line <= last

commentBlockEndsAt : Int -> CommentBlock -> Bool
commentBlockEndsAt line (CommentBlock _ last _ _) = last == line

declZipEndsAt : Int -> (Decl, DeclPos) -> Bool
declZipEndsAt line (_, dp) = declPosEndLine dp == line

blockHasReason : List Comment -> CommentBlock -> Bool
blockHasReason comments (CommentBlock first last _ _) =
  let inBlock =
    filterList (c => commentLine c >= first && commentLine c <= last) comments
  let reasonCmts = filterList (c => isNone (parseDirective c)) inBlock
  anyList directiveReasonHasProse reasonCmts

-- A comment line counts as a reason only when it contains a REASON WORD: a
-- whitespace-delimited token with a substantive (>=4 alphabetic char) run
-- that is not one of the shapes `rule-directive-reason` exists to reject —
-- `todo`/`fixme`/`xxx`, an issue-reference token (`#1234`) or its connector
-- word (`see`/`issue`/`cf`/`ref`), or a bare rule name (`rule-clone-type`) —
-- each of which has >=4 alphabetic characters on its own but states no
-- constraint. A comment mixing one of these with real prose still counts,
-- since the prose word alone satisfies the check.
directiveReasonHasProse : Comment -> Bool
directiveReasonHasProse c = anyList isReasonWord (words (commentText c))

isReasonWord : String -> Bool
isReasonWord raw =
  if isNonReasonToken raw then False else hasSubstantiveWord raw

isNonReasonToken : String -> Bool
isNonReasonToken raw =
  let low = toLower (stripTrailingPunct raw)
  contains low ["todo", "fixme", "xxx", "see", "issue", "cf", "ref"]
    || isIssueRefToken low
    || isRuleNameToken low

-- A single hyphenated token naming a rule (`rule-clone-type`) rather than a
-- reason -- checked char-by-char rather than against a quoted "rule-..."
-- literal, which would falsely register this heuristic as an unenrolled
-- rule name under `diff_compiler_lint_baseline.sh`'s assertion 1b.
ruleNameTokenRe : Regex
ruleNameTokenRe = mustCompile "^rule-"

isRuleNameToken : String -> Bool
isRuleNameToken low = isMatch ruleNameTokenRe low

issueRefTokenRe : Regex
issueRefTokenRe = mustCompile "^#[0-9]+$"

isIssueRefToken : String -> Bool
isIssueRefToken low = isMatch issueRefTokenRe low

stripTrailingPunct : String -> String
stripTrailingPunct s =
  let n = stringLength s
  if n == 0 then
    s
  else if isTrailingPunctChar (arrayGetUnsafe (n - 1) (stringToChars s)) then
    stripTrailingPunct (stringSlice 0 (n - 1) s)
  else
    s

isTrailingPunctChar : Char -> Bool
isTrailingPunctChar ch =
  ch == ':' || ch == '.' || ch == ',' || ch == ';' || ch == '!' || ch == '?'

substantiveWordRe : Regex
substantiveWordRe = mustCompile "[A-Za-z]{4}"

hasSubstantiveWord : String -> Bool
hasSubstantiveWord s = isMatch substantiveWordRe s

directiveReasonFinding : Comment -> Finding
directiveReasonFinding c = Finding {
  rule = ruleNameDirectiveReason,
  message =
    "`-- lint-disable-*` directive has no comment in its own comment block stating the constraint that forced it -- an issue number alone is not a reason",
  severity = SevWarning,
  loc = Some (Loc "" (commentLine c) 1 (commentLine c) 1),
  fix = None,
}
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false) (mem "declPosEndLine" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "anyList" false) (mem "filterList" false) (mem "splitNl" false) (mem "isSome" false))))
(DUse false (UseGroup ("string") ((mem "toLower" false) (mem "words" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "mustCompile" false) (mem "isMatch" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "DirScope" true) (mem "Directive" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factComments" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "CommentBlock" true) (mem "codePortions" false) (mem "commentBlocks" false) (mem "parseDirective" false) (mem "ruleNameDirectiveReason" false) (mem "zipDeclPos" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDirectiveReason")) (fa "summary" (ELit (LString "a `-- lint-disable-*` directive with no comment in its own comment block stating the constraint that forced it — an issue number alone is not a reason (#2862)"))) (fa "doc" (ELit (LString "A `-- lint-disable-*` directive needs a comment in its own comment block stating the constraint that forced it; an issue number alone is not a reason (#2862). This enforces the repository suppression convention.\n\nBefore:\n  -- lint-disable-next-line rule-x\nAfter:\n  -- bounded: at most 3 fields, so a list lookup is cheaper\n  -- lint-disable-next-line rule-x"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDirectiveReason")) (EVar "None")))
(DTypeSig false "ruleDirectiveReason" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleDirectiveReason" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "comments") (EApp (EVar "factComments") (EVar "facts"))) (DoLet false false (PVar "ls") (EApp (EVar "splitNl") (EFieldAccess (EVar "facts") "ffSrc"))) (DoLet false false (PVar "codeLines") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "codePortions") (EVar "ls")) (EVar "comments")) (ELit (LInt 1))))) (DoLet false false (PVar "blocks") (EApp (EApp (EVar "commentBlocks") (EVar "comments")) (EVar "codeLines"))) (DoLet false false (PVar "declZips") (EApp (EApp (EVar "zipDeclPos") (EVar "prog")) (EApp (EVar "positionsDecls") (EVar "pos")))) (DoLet false false (PVar "dirCmts") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "isSome") (EApp (EVar "parseDirective") (EVar "c"))))) (EVar "comments"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "directiveReasonCheck") (EVar "comments")) (EVar "blocks")) (EVar "declZips"))) (EVar "dirCmts")))))
(DTypeSig false "directiveReasonCheck" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "CommentBlock")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "directiveReasonCheck" ((PVar "comments") (PVar "blocks") (PVar "declZips") (PVar "c")) (EIf (EApp (EApp (EApp (EApp (EVar "directiveReasoned") (EVar "comments")) (EVar "blocks")) (EVar "declZips")) (EVar "c")) (EListLit) (EListLit (EApp (EVar "directiveReasonFinding") (EVar "c")))))
(DTypeSig false "directiveReasoned" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "CommentBlock")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyCon "Comment") (TyCon "Bool"))))))
(DFunDef false "directiveReasoned" ((PVar "comments") (PVar "blocks") (PVar "declZips") (PVar "c")) (EBlock (DoLet false false (PVar "ownReasoned") (EMatch (EApp (EApp (EVar "find") (EApp (EVar "commentBlockContainsLine") (EApp (EVar "commentLine") (EVar "c")))) (EVar "blocks")) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "blockHasReason") (EVar "comments")) (EVar "b"))) (arm (PCon "None") () (EVar "False")))) (DoExpr (EIf (EVar "ownReasoned") (EVar "True") (EMatch (EApp (EVar "parseDirective") (EVar "c")) (arm (PCon "Some" (PCon "Directive" (PCon "DScopeLine" (PVar "target")) PWild)) () (EApp (EApp (EApp (EApp (EApp (EVar "declGapReasoned") (EVar "comments")) (EVar "blocks")) (EVar "declZips")) (EApp (EApp (EVar "declZipNameAt") (EVar "declZips")) (EVar "target"))) (EApp (EVar "commentLine") (EVar "c")))) (arm (PCon "Some" (PCon "Directive" (PCon "DScopeFile") PWild)) () (EVar "False")) (arm (PCon "None") () (EVar "False")))))))
(DTypeSig false "declGapReasoned" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "CommentBlock")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "declGapReasoned" ((PVar "comments") (PVar "blocks") (PVar "declZips") (PVar "targetName") (PVar "line")) (EMatch (EApp (EApp (EVar "find") (EApp (EVar "commentBlockEndsAt") (EBinOp "-" (EVar "line") (ELit (LInt 1))))) (EVar "blocks")) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "blockHasReason") (EVar "comments")) (EVar "b"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "find") (EApp (EVar "declZipEndsAt") (EBinOp "-" (EVar "line") (ELit (LInt 1))))) (EVar "declZips")) (arm (PCon "Some" (PTuple (PVar "d") (PVar "dp"))) () (EIf (EApp (EApp (EVar "declGapNameMatches") (EVar "targetName")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EVar "declGapReasoned") (EVar "comments")) (EVar "blocks")) (EVar "declZips")) (EVar "targetName")) (EApp (EVar "declPosLine") (EVar "dp"))) (EVar "False"))) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "declZipNameAt" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "declZipNameAt" ((PVar "declZips") (PVar "line")) (EMatch (EApp (EApp (EVar "find") (EApp (EVar "declZipContainsLine") (EVar "line"))) (EVar "declZips")) (arm (PCon "Some" (PTuple (PVar "d") PWild)) () (EApp (EVar "declBridgeName") (EVar "d"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "declZipContainsLine" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "Decl") (TyCon "DeclPos")) (TyCon "Bool"))))
(DFunDef false "declZipContainsLine" ((PVar "line") (PTuple PWild (PVar "dp"))) (EBinOp "&&" (EBinOp "<=" (EApp (EVar "declPosLine") (EVar "dp")) (EVar "line")) (EBinOp ">=" (EApp (EVar "declPosEndLine") (EVar "dp")) (EVar "line"))))
(DTypeSig false "declBridgeName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declBridgeName" ((PCon "DTypeSig" PWild (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "declBridgeName" ((PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "declBridgeName" (PWild) (EVar "None"))
(DTypeSig false "declGapNameMatches" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "declGapNameMatches" ((PCon "Some" (PVar "target")) (PVar "d")) (EMatch (EApp (EVar "declBridgeName") (EVar "d")) (arm (PCon "Some" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "target"))) (arm (PCon "None") () (EVar "False"))))
(DFunDef false "declGapNameMatches" ((PCon "None") PWild) (EVar "False"))
(DTypeSig false "commentBlockContainsLine" (TyFun (TyCon "Int") (TyFun (TyCon "CommentBlock") (TyCon "Bool"))))
(DFunDef false "commentBlockContainsLine" ((PVar "line") (PCon "CommentBlock" (PVar "first") (PVar "last") PWild PWild)) (EBinOp "&&" (EBinOp ">=" (EVar "line") (EVar "first")) (EBinOp "<=" (EVar "line") (EVar "last"))))
(DTypeSig false "commentBlockEndsAt" (TyFun (TyCon "Int") (TyFun (TyCon "CommentBlock") (TyCon "Bool"))))
(DFunDef false "commentBlockEndsAt" ((PVar "line") (PCon "CommentBlock" PWild (PVar "last") PWild PWild)) (EBinOp "==" (EVar "last") (EVar "line")))
(DTypeSig false "declZipEndsAt" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "Decl") (TyCon "DeclPos")) (TyCon "Bool"))))
(DFunDef false "declZipEndsAt" ((PVar "line") (PTuple PWild (PVar "dp"))) (EBinOp "==" (EApp (EVar "declPosEndLine") (EVar "dp")) (EVar "line")))
(DTypeSig false "blockHasReason" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "CommentBlock") (TyCon "Bool"))))
(DFunDef false "blockHasReason" ((PVar "comments") (PCon "CommentBlock" (PVar "first") (PVar "last") PWild PWild)) (EBlock (DoLet false false (PVar "inBlock") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "commentLine") (EVar "c")) (EVar "first")) (EBinOp "<=" (EApp (EVar "commentLine") (EVar "c")) (EVar "last"))))) (EVar "comments"))) (DoLet false false (PVar "reasonCmts") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "isNone") (EApp (EVar "parseDirective") (EVar "c"))))) (EVar "inBlock"))) (DoExpr (EApp (EApp (EVar "anyList") (EVar "directiveReasonHasProse")) (EVar "reasonCmts")))))
(DTypeSig false "directiveReasonHasProse" (TyFun (TyCon "Comment") (TyCon "Bool")))
(DFunDef false "directiveReasonHasProse" ((PVar "c")) (EApp (EApp (EVar "anyList") (EVar "isReasonWord")) (EApp (EVar "words") (EApp (EVar "commentText") (EVar "c")))))
(DTypeSig false "isReasonWord" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isReasonWord" ((PVar "raw")) (EIf (EApp (EVar "isNonReasonToken") (EVar "raw")) (EVar "False") (EApp (EVar "hasSubstantiveWord") (EVar "raw"))))
(DTypeSig false "isNonReasonToken" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isNonReasonToken" ((PVar "raw")) (EBlock (DoLet false false (PVar "low") (EApp (EVar "toLower") (EApp (EVar "stripTrailingPunct") (EVar "raw")))) (DoExpr (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "low")) (EListLit (ELit (LString "todo")) (ELit (LString "fixme")) (ELit (LString "xxx")) (ELit (LString "see")) (ELit (LString "issue")) (ELit (LString "cf")) (ELit (LString "ref")))) (EApp (EVar "isIssueRefToken") (EVar "low"))) (EApp (EVar "isRuleNameToken") (EVar "low"))))))
(DTypeSig false "ruleNameTokenRe" (TyCon "Regex"))
(DFunDef false "ruleNameTokenRe" () (EApp (EVar "mustCompile") (ELit (LString "^rule-"))))
(DTypeSig false "isRuleNameToken" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isRuleNameToken" ((PVar "low")) (EApp (EApp (EVar "isMatch") (EVar "ruleNameTokenRe")) (EVar "low")))
(DTypeSig false "issueRefTokenRe" (TyCon "Regex"))
(DFunDef false "issueRefTokenRe" () (EApp (EVar "mustCompile") (ELit (LString "^#[0-9]+$"))))
(DTypeSig false "isIssueRefToken" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isIssueRefToken" ((PVar "low")) (EApp (EApp (EVar "isMatch") (EVar "issueRefTokenRe")) (EVar "low")))
(DTypeSig false "stripTrailingPunct" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripTrailingPunct" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "s") (EIf (EApp (EVar "isTrailingPunctChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "stringToChars") (EVar "s")))) (EApp (EVar "stripTrailingPunct") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s"))) (EVar "s"))))))
(DTypeSig false "isTrailingPunctChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isTrailingPunctChar" ((PVar "ch")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "ch") (ELit (LChar ":"))) (EBinOp "==" (EVar "ch") (ELit (LChar ".")))) (EBinOp "==" (EVar "ch") (ELit (LChar ",")))) (EBinOp "==" (EVar "ch") (ELit (LChar ";")))) (EBinOp "==" (EVar "ch") (ELit (LChar "!")))) (EBinOp "==" (EVar "ch") (ELit (LChar "?")))))
(DTypeSig false "substantiveWordRe" (TyCon "Regex"))
(DFunDef false "substantiveWordRe" () (EApp (EVar "mustCompile") (ELit (LString "[A-Za-z]{4}"))))
(DTypeSig false "hasSubstantiveWord" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasSubstantiveWord" ((PVar "s")) (EApp (EApp (EVar "isMatch") (EVar "substantiveWordRe")) (EVar "s")))
(DTypeSig false "directiveReasonFinding" (TyFun (TyCon "Comment") (TyCon "Finding")))
(DFunDef false "directiveReasonFinding" ((PVar "c")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDirectiveReason")) (fa "message" (ELit (LString "`-- lint-disable-*` directive has no comment in its own comment block stating the constraint that forced it -- an issue number alone is not a reason"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EApp (EVar "commentLine") (EVar "c"))) (ELit (LInt 1))) (EApp (EVar "commentLine") (EVar "c"))) (ELit (LInt 1))))) (fa "fix" (EVar "None")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false) (mem "declPosEndLine" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "anyList" false) (mem "filterList" false) (mem "splitNl" false) (mem "isSome" false))))
(DUse false (UseGroup ("string") ((mem "toLower" false) (mem "words" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "mustCompile" false) (mem "isMatch" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "DirScope" true) (mem "Directive" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factComments" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "CommentBlock" true) (mem "codePortions" false) (mem "commentBlocks" false) (mem "parseDirective" false) (mem "ruleNameDirectiveReason" false) (mem "zipDeclPos" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDirectiveReason")) (fa "summary" (ELit (LString "a `-- lint-disable-*` directive with no comment in its own comment block stating the constraint that forced it — an issue number alone is not a reason (#2862)"))) (fa "doc" (ELit (LString "A `-- lint-disable-*` directive needs a comment in its own comment block stating the constraint that forced it; an issue number alone is not a reason (#2862). This enforces the repository suppression convention.\n\nBefore:\n  -- lint-disable-next-line rule-x\nAfter:\n  -- bounded: at most 3 fields, so a list lookup is cheaper\n  -- lint-disable-next-line rule-x"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDirectiveReason")) (EVar "None")))
(DTypeSig false "ruleDirectiveReason" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleDirectiveReason" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "comments") (EApp (EVar "factComments") (EVar "facts"))) (DoLet false false (PVar "ls") (EApp (EVar "splitNl") (EFieldAccess (EVar "facts") "ffSrc"))) (DoLet false false (PVar "codeLines") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "codePortions") (EVar "ls")) (EVar "comments")) (ELit (LInt 1))))) (DoLet false false (PVar "blocks") (EApp (EApp (EVar "commentBlocks") (EVar "comments")) (EVar "codeLines"))) (DoLet false false (PVar "declZips") (EApp (EApp (EVar "zipDeclPos") (EVar "prog")) (EApp (EVar "positionsDecls") (EVar "pos")))) (DoLet false false (PVar "dirCmts") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "isSome") (EApp (EVar "parseDirective") (EVar "c"))))) (EVar "comments"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "directiveReasonCheck") (EVar "comments")) (EVar "blocks")) (EVar "declZips"))) (EVar "dirCmts")))))
(DTypeSig false "directiveReasonCheck" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "CommentBlock")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "directiveReasonCheck" ((PVar "comments") (PVar "blocks") (PVar "declZips") (PVar "c")) (EIf (EApp (EApp (EApp (EApp (EVar "directiveReasoned") (EVar "comments")) (EVar "blocks")) (EVar "declZips")) (EVar "c")) (EListLit) (EListLit (EApp (EVar "directiveReasonFinding") (EVar "c")))))
(DTypeSig false "directiveReasoned" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "CommentBlock")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyCon "Comment") (TyCon "Bool"))))))
(DFunDef false "directiveReasoned" ((PVar "comments") (PVar "blocks") (PVar "declZips") (PVar "c")) (EBlock (DoLet false false (PVar "ownReasoned") (EMatch (EApp (EApp (EDictApp "find") (EApp (EVar "commentBlockContainsLine") (EApp (EVar "commentLine") (EVar "c")))) (EVar "blocks")) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "blockHasReason") (EVar "comments")) (EVar "b"))) (arm (PCon "None") () (EVar "False")))) (DoExpr (EIf (EVar "ownReasoned") (EVar "True") (EMatch (EApp (EVar "parseDirective") (EVar "c")) (arm (PCon "Some" (PCon "Directive" (PCon "DScopeLine" (PVar "target")) PWild)) () (EApp (EApp (EApp (EApp (EApp (EVar "declGapReasoned") (EVar "comments")) (EVar "blocks")) (EVar "declZips")) (EApp (EApp (EVar "declZipNameAt") (EVar "declZips")) (EVar "target"))) (EApp (EVar "commentLine") (EVar "c")))) (arm (PCon "Some" (PCon "Directive" (PCon "DScopeFile") PWild)) () (EVar "False")) (arm (PCon "None") () (EVar "False")))))))
(DTypeSig false "declGapReasoned" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyApp (TyCon "List") (TyCon "CommentBlock")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "declGapReasoned" ((PVar "comments") (PVar "blocks") (PVar "declZips") (PVar "targetName") (PVar "line")) (EMatch (EApp (EApp (EDictApp "find") (EApp (EVar "commentBlockEndsAt") (EBinOp "-" (EVar "line") (ELit (LInt 1))))) (EVar "blocks")) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "blockHasReason") (EVar "comments")) (EVar "b"))) (arm (PCon "None") () (EMatch (EApp (EApp (EDictApp "find") (EApp (EVar "declZipEndsAt") (EBinOp "-" (EVar "line") (ELit (LInt 1))))) (EVar "declZips")) (arm (PCon "Some" (PTuple (PVar "d") (PVar "dp"))) () (EIf (EApp (EApp (EVar "declGapNameMatches") (EVar "targetName")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EVar "declGapReasoned") (EVar "comments")) (EVar "blocks")) (EVar "declZips")) (EVar "targetName")) (EApp (EVar "declPosLine") (EVar "dp"))) (EVar "False"))) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "declZipNameAt" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "declZipNameAt" ((PVar "declZips") (PVar "line")) (EMatch (EApp (EApp (EDictApp "find") (EApp (EVar "declZipContainsLine") (EVar "line"))) (EVar "declZips")) (arm (PCon "Some" (PTuple (PVar "d") PWild)) () (EApp (EVar "declBridgeName") (EVar "d"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "declZipContainsLine" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "Decl") (TyCon "DeclPos")) (TyCon "Bool"))))
(DFunDef false "declZipContainsLine" ((PVar "line") (PTuple PWild (PVar "dp"))) (EBinOp "&&" (EBinOp "<=" (EApp (EVar "declPosLine") (EVar "dp")) (EVar "line")) (EBinOp ">=" (EApp (EVar "declPosEndLine") (EVar "dp")) (EVar "line"))))
(DTypeSig false "declBridgeName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declBridgeName" ((PCon "DTypeSig" PWild (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "declBridgeName" ((PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "declBridgeName" (PWild) (EVar "None"))
(DTypeSig false "declGapNameMatches" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "declGapNameMatches" ((PCon "Some" (PVar "target")) (PVar "d")) (EMatch (EApp (EVar "declBridgeName") (EVar "d")) (arm (PCon "Some" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "target"))) (arm (PCon "None") () (EVar "False"))))
(DFunDef false "declGapNameMatches" ((PCon "None") PWild) (EVar "False"))
(DTypeSig false "commentBlockContainsLine" (TyFun (TyCon "Int") (TyFun (TyCon "CommentBlock") (TyCon "Bool"))))
(DFunDef false "commentBlockContainsLine" ((PVar "line") (PCon "CommentBlock" (PVar "first") (PVar "last") PWild PWild)) (EBinOp "&&" (EBinOp ">=" (EVar "line") (EVar "first")) (EBinOp "<=" (EVar "line") (EVar "last"))))
(DTypeSig false "commentBlockEndsAt" (TyFun (TyCon "Int") (TyFun (TyCon "CommentBlock") (TyCon "Bool"))))
(DFunDef false "commentBlockEndsAt" ((PVar "line") (PCon "CommentBlock" PWild (PVar "last") PWild PWild)) (EBinOp "==" (EVar "last") (EVar "line")))
(DTypeSig false "declZipEndsAt" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "Decl") (TyCon "DeclPos")) (TyCon "Bool"))))
(DFunDef false "declZipEndsAt" ((PVar "line") (PTuple PWild (PVar "dp"))) (EBinOp "==" (EApp (EVar "declPosEndLine") (EVar "dp")) (EVar "line")))
(DTypeSig false "blockHasReason" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyFun (TyCon "CommentBlock") (TyCon "Bool"))))
(DFunDef false "blockHasReason" ((PVar "comments") (PCon "CommentBlock" (PVar "first") (PVar "last") PWild PWild)) (EBlock (DoLet false false (PVar "inBlock") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "commentLine") (EVar "c")) (EVar "first")) (EBinOp "<=" (EApp (EVar "commentLine") (EVar "c")) (EVar "last"))))) (EVar "comments"))) (DoLet false false (PVar "reasonCmts") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "isNone") (EApp (EVar "parseDirective") (EVar "c"))))) (EVar "inBlock"))) (DoExpr (EApp (EApp (EVar "anyList") (EVar "directiveReasonHasProse")) (EVar "reasonCmts")))))
(DTypeSig false "directiveReasonHasProse" (TyFun (TyCon "Comment") (TyCon "Bool")))
(DFunDef false "directiveReasonHasProse" ((PVar "c")) (EApp (EApp (EVar "anyList") (EVar "isReasonWord")) (EApp (EVar "words") (EApp (EVar "commentText") (EVar "c")))))
(DTypeSig false "isReasonWord" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isReasonWord" ((PVar "raw")) (EIf (EApp (EVar "isNonReasonToken") (EVar "raw")) (EVar "False") (EApp (EVar "hasSubstantiveWord") (EVar "raw"))))
(DTypeSig false "isNonReasonToken" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isNonReasonToken" ((PVar "raw")) (EBlock (DoLet false false (PVar "low") (EApp (EVar "toLower") (EApp (EVar "stripTrailingPunct") (EVar "raw")))) (DoExpr (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "low")) (EListLit (ELit (LString "todo")) (ELit (LString "fixme")) (ELit (LString "xxx")) (ELit (LString "see")) (ELit (LString "issue")) (ELit (LString "cf")) (ELit (LString "ref")))) (EApp (EVar "isIssueRefToken") (EVar "low"))) (EApp (EVar "isRuleNameToken") (EVar "low"))))))
(DTypeSig false "ruleNameTokenRe" (TyCon "Regex"))
(DFunDef false "ruleNameTokenRe" () (EApp (EVar "mustCompile") (ELit (LString "^rule-"))))
(DTypeSig false "isRuleNameToken" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isRuleNameToken" ((PVar "low")) (EApp (EApp (EVar "isMatch") (EVar "ruleNameTokenRe")) (EVar "low")))
(DTypeSig false "issueRefTokenRe" (TyCon "Regex"))
(DFunDef false "issueRefTokenRe" () (EApp (EVar "mustCompile") (ELit (LString "^#[0-9]+$"))))
(DTypeSig false "isIssueRefToken" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isIssueRefToken" ((PVar "low")) (EApp (EApp (EVar "isMatch") (EVar "issueRefTokenRe")) (EVar "low")))
(DTypeSig false "stripTrailingPunct" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripTrailingPunct" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "s") (EIf (EApp (EVar "isTrailingPunctChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "stringToChars") (EVar "s")))) (EApp (EVar "stripTrailingPunct") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s"))) (EVar "s"))))))
(DTypeSig false "isTrailingPunctChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isTrailingPunctChar" ((PVar "ch")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "ch") (ELit (LChar ":"))) (EBinOp "==" (EVar "ch") (ELit (LChar ".")))) (EBinOp "==" (EVar "ch") (ELit (LChar ",")))) (EBinOp "==" (EVar "ch") (ELit (LChar ";")))) (EBinOp "==" (EVar "ch") (ELit (LChar "!")))) (EBinOp "==" (EVar "ch") (ELit (LChar "?")))))
(DTypeSig false "substantiveWordRe" (TyCon "Regex"))
(DFunDef false "substantiveWordRe" () (EApp (EVar "mustCompile") (ELit (LString "[A-Za-z]{4}"))))
(DTypeSig false "hasSubstantiveWord" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasSubstantiveWord" ((PVar "s")) (EApp (EApp (EVar "isMatch") (EVar "substantiveWordRe")) (EVar "s")))
(DTypeSig false "directiveReasonFinding" (TyFun (TyCon "Comment") (TyCon "Finding")))
(DFunDef false "directiveReasonFinding" ((PVar "c")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDirectiveReason")) (fa "message" (ELit (LString "`-- lint-disable-*` directive has no comment in its own comment block stating the constraint that forced it -- an issue number alone is not a reason"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EApp (EVar "commentLine") (EVar "c"))) (ELit (LInt 1))) (EApp (EVar "commentLine") (EVar "c"))) (ELit (LInt 1))))) (fa "fix" (EVar "None")))))
