# META
source_lines=239
stages=DESUGAR,MARK
# SOURCE
-- lint rules rule-comment-history, rule-comment-ruling, rule-comment-tombstone, rule-comment-emoji, rule-comment-draft, rule-comment-deictic, rule-comment-dead-path, rule-comment-shout: comment lines in a register that goes stale.

import frontend.ast.{Loc(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{anyList, filterList, splitNl}
import string.{contains}
import regex.{Regex, mustCompile, isMatch}
import frontend.lexer.{Comment, commentLine, commentText}
import tools.lint_core.{
  Category(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  ProseComments(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  factProseComments,
  mkRule,
  noFix,
}
import tools.lint_shared.{
  ruleNameCommentDeadPath,
  ruleNameCommentDeictic,
  ruleNameCommentDraft,
  ruleNameCommentEmoji,
  ruleNameCommentHistory,
  ruleNameCommentRuling,
  ruleNameCommentShout,
  ruleNameCommentTombstone,
}

-- One rule per comment-register class. A finding is one comment LINE: a block
-- comment contributes one finding per physical line that matches. A `--`
-- comment that trails code is skipped, because the register is about prose a
-- reader meets as prose; every line of a `{- -}` block counts.
export
rules : List Rule
rules = [
  classRuleCoarse
    ruleNameCommentHistory
    "comment line narrates history (\"formerly\", \"used to\", \"The old \", \"Until 2026-\")"
    "A comment line that narrates what the code used to be (\"formerly\", \"used to\", \"withdrawn\", \"The old \", \"Until 2026-\") goes stale the day it is written; state the constraint the code carries now.\n\nBefore:\n  -- formerly a list, now a map\nAfter:\n  -- keyed by name so lookups stay O(log n)"
    hasHistoryPhrase
    isHistoryLine,
  classRule
    ruleNameCommentRuling
    "comment line uses reviewer-addressed ruling vocabulary (\"refuted\", \"ratified\", \"withdrawn\")"
    "Ruling vocabulary (\"refuted\", \"ratified\", \"withdrawn\", \"ruling\") addresses a reviewer; it belongs on the PR or issue, not in the source.\n\nBefore:\n  -- ratified in review\nAfter:\n  -- the invariant the review settled, stated directly"
    isRulingLine,
  classRule
    ruleNameCommentTombstone
    "comment line is a tombstone for code that no longer exists"
    "A tombstone (\"was HERE and is RETIRED\", \"do not re-add\", \"now lives in\", \"moved to\", \"now comes from\") points at code that is gone.\n\nBefore:\n  -- moved to util.mdk\nAfter:\n  delete the comment"
    isTombstoneLine,
  classRule
    ruleNameCommentEmoji
    "comment line carries an emoji shout"
    "An emoji shout (a siren, a warning sign or a lock) in a comment; state the constraint in words.\n\nBefore:\n  -- (siren) never edit this\nAfter:\n  -- byte-pinned by a gate: edits break its golden"
    isEmojiLine,
  classRule
    ruleNameCommentDraft
    "comment line narrates a draft (\"earlier cut\", \"first cut\", \"earlier revision\")"
    "Draft self-narration (\"earlier cut\", \"first cut\", \"earlier revision\") describes the author's process, not the code.\n\nBefore:\n  -- the first cut used a list\nAfter:\n  delete the comment"
    isDraftLine,
  classRule
    ruleNameCommentDeictic
    "comment line points at \"this PR\""
    "A comment that says \"this PR\" does not survive the PR merging.\n\nBefore:\n  -- added in this PR\nAfter:\n  delete the comment"
    isDeicticLine,
  classRule
    ruleNameCommentDeadPath
    "comment line cites a dead OCaml path (lib/*.ml)"
    "A comment that cites a path under lib/ ending in .ml points at the removed OCaml compiler.\n\nBefore:\n  -- see lib/typecheck.ml\nAfter:\n  cite the Medaka module that holds the code"
    isDeadPathLine,
  classRule
    ruleNameCommentShout
    "comment line has three consecutive capitalised words"
    "Three consecutive words in capitals read as shouting; state the constraint in plain words.\n\nBefore:\n  -- (caps) do not edit this\nAfter:\n  -- byte-pinned by a gate"
    isShoutLine,
]

classRule : String -> String -> String -> (String -> Bool) -> Rule
classRule name summary doc hit = classRuleCoarse name summary doc hit hit

-- `coarse` holds of any text with a hit line in it: a block comment is split
-- into lines only when it does.
classRuleCoarse : String ->
  String ->
  String ->
  (String -> Bool) ->
  (String -> Bool) ->
  Rule
classRuleCoarse name summary doc coarse hit =
  mkRule
    RuleMeta {
      name = name,
      summary = summary,
      doc = doc,
      category = Style,
      scope = Internal,
      ratchet = Baselined,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    (_ _ facts _ _ => commentLineFindings name coarse hit facts)
    None

commentLineFindings : String ->
  (String -> Bool) ->
  (String -> Bool) ->
  FileFacts ->
  List Finding
commentLineFindings name coarse hit facts =
  let prose = factProseComments facts
  let lineHits = filterList (c => hit (commentText c)) prose.proseLines
  let blocks = filterList (c => coarse (commentText c)) prose.proseBlocks
  flatMap (blockFindings name hit) blocks
    ++ map (c => lineFinding name (commentLine c)) lineHits

blockFindings : String -> (String -> Bool) -> Comment -> List Finding
blockFindings name hit c = go (commentLine c) (splitNl (commentText c))
  where
    go _ [] = []
    go n (l :: rest) =
      if hit l then lineFinding name n :: go (n + 1) rest else go (n + 1) rest

lineFinding : String -> Int -> Finding
lineFinding name line = Finding {
  rule = name,
  message = "comment line in the `\{name}` register",
  severity = SevWarning,
  loc = Some (Loc "" line 1 line 1),
  fix = noFix,
}

anyInfix : List String -> String -> Bool
anyInfix needles s = anyList (n => contains n s) needles

historyWordRe : Regex
historyWordRe =
  mustCompile "(^|[^A-Za-z0-9_])(formerly|withdrawn|used to)([^A-Za-z0-9_]|$)"

hasHistoryPhrase : String -> Bool
hasHistoryPhrase l =
  contains "Until 2026-" l
    || contains "The old " l
    || anyInfix ["formerly", "withdrawn", "used to"] l
      && isMatch historyWordRe l

-- A line that says "is used to" (and kin) describes present use, not history.
isHistoryLine : String -> Bool
isHistoryLine l =
  hasHistoryPhrase l
    && not
      (anyInfix
        [
          "is used to",
          "are used to",
          "was used to",
          "be used to",
          "been used to",
        ]
        l)

isRulingLine : String -> Bool
isRulingLine = anyInfix ["refuted", "ratified", "withdrawn", "\"ruling\""]

isTombstoneLine : String -> Bool
isTombstoneLine = anyInfix [
  "was HERE and is RETIRED",
  "do not re-add",
  "now lives in",
  "moved to",
  "now comes from",
]

isEmojiLine : String -> Bool
isEmojiLine l =
  stringByteLength l /= stringLength l && anyInfix ["🚨", "⚠️", "🔒"] l

isDraftLine : String -> Bool
isDraftLine = anyInfix ["earlier cut", "first cut", "earlier revision"]

isDeicticLine : String -> Bool
isDeicticLine = contains "this PR"

deadPathRe : Regex
deadPathRe = mustCompile "lib/[A-Za-z0-9_./]*\\.ml[a-z]*"

isDeadPathLine : String -> Bool
isDeadPathLine l = contains "lib/" l && isMatch deadPathRe l

-- Three words of capitals (two letters or more) in a row, each of the first
-- two followed by at most one of `,.:;)` and one space.
isShoutLine : String -> Bool
isShoutLine l = shoutFrom (stringToChars l)

-- Runs of capitals are visited whole, so each is tested once.
shoutFrom : Array Char -> Bool
shoutFrom arr = go 0
  where
    go i
      | i >= arrayLength arr = False
      | isUpperAt arr i =
        let e = runEnd arr i
        e - i >= 2 && shoutRest arr e 2 || go e
      | otherwise = go (i + 1)

-- `k` more words of capitals must follow the run that ended at `e`.
shoutRest : Array Char -> Int -> Int -> Bool
shoutRest arr e k = match afterSep arr e
  Some j =>
    let e2 = runEnd arr j
    e2 - j >= 2 && (k == 1 || shoutRest arr e2 (k - 1))
  None => False

runEnd : Array Char -> Int -> Int
runEnd arr i = if isUpperAt arr i then runEnd arr (i + 1) else i

afterSep : Array Char -> Int -> Option Int
afterSep arr e
  | charAt arr e == ' ' = Some (e + 1)
  | isShoutPunct (charAt arr e) && charAt arr (e + 1) == ' ' = Some (e + 2)
  | otherwise = None

isShoutPunct : Char -> Bool
isShoutPunct c = c == ',' || c == '.' || c == ':' || c == ';' || c == ')'

charAt : Array Char -> Int -> Char
charAt arr i = if i < arrayLength arr then arrayGetUnsafe i arr else '\0'

isUpperAt : Array Char -> Int -> Bool
isUpperAt arr i =
  i < arrayLength arr
    && arrayGetUnsafe i arr >= 'A'
    && arrayGetUnsafe i arr <= 'Z'
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "filterList" false) (mem "splitNl" false))))
(DUse false (UseGroup ("string") ((mem "contains" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "mustCompile" false) (mem "isMatch" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "ProseComments" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "factProseComments" false) (mem "mkRule" false) (mem "noFix" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameCommentDeadPath" false) (mem "ruleNameCommentDeictic" false) (mem "ruleNameCommentDraft" false) (mem "ruleNameCommentEmoji" false) (mem "ruleNameCommentHistory" false) (mem "ruleNameCommentRuling" false) (mem "ruleNameCommentShout" false) (mem "ruleNameCommentTombstone" false))))
(DTypeSig true "rules" (TyApp (TyCon "List") (TyCon "Rule")))
(DFunDef false "rules" () (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "classRuleCoarse") (EVar "ruleNameCommentHistory")) (ELit (LString "comment line narrates history (\"formerly\", \"used to\", \"The old \", \"Until 2026-\")"))) (ELit (LString "A comment line that narrates what the code used to be (\"formerly\", \"used to\", \"withdrawn\", \"The old \", \"Until 2026-\") goes stale the day it is written; state the constraint the code carries now.\n\nBefore:\n  -- formerly a list, now a map\nAfter:\n  -- keyed by name so lookups stay O(log n)"))) (EVar "hasHistoryPhrase")) (EVar "isHistoryLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentRuling")) (ELit (LString "comment line uses reviewer-addressed ruling vocabulary (\"refuted\", \"ratified\", \"withdrawn\")"))) (ELit (LString "Ruling vocabulary (\"refuted\", \"ratified\", \"withdrawn\", \"ruling\") addresses a reviewer; it belongs on the PR or issue, not in the source.\n\nBefore:\n  -- ratified in review\nAfter:\n  -- the invariant the review settled, stated directly"))) (EVar "isRulingLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentTombstone")) (ELit (LString "comment line is a tombstone for code that no longer exists"))) (ELit (LString "A tombstone (\"was HERE and is RETIRED\", \"do not re-add\", \"now lives in\", \"moved to\", \"now comes from\") points at code that is gone.\n\nBefore:\n  -- moved to util.mdk\nAfter:\n  delete the comment"))) (EVar "isTombstoneLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentEmoji")) (ELit (LString "comment line carries an emoji shout"))) (ELit (LString "An emoji shout (a siren, a warning sign or a lock) in a comment; state the constraint in words.\n\nBefore:\n  -- (siren) never edit this\nAfter:\n  -- byte-pinned by a gate: edits break its golden"))) (EVar "isEmojiLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentDraft")) (ELit (LString "comment line narrates a draft (\"earlier cut\", \"first cut\", \"earlier revision\")"))) (ELit (LString "Draft self-narration (\"earlier cut\", \"first cut\", \"earlier revision\") describes the author's process, not the code.\n\nBefore:\n  -- the first cut used a list\nAfter:\n  delete the comment"))) (EVar "isDraftLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentDeictic")) (ELit (LString "comment line points at \"this PR\""))) (ELit (LString "A comment that says \"this PR\" does not survive the PR merging.\n\nBefore:\n  -- added in this PR\nAfter:\n  delete the comment"))) (EVar "isDeicticLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentDeadPath")) (ELit (LString "comment line cites a dead OCaml path (lib/*.ml)"))) (ELit (LString "A comment that cites a path under lib/ ending in .ml points at the removed OCaml compiler.\n\nBefore:\n  -- see lib/typecheck.ml\nAfter:\n  cite the Medaka module that holds the code"))) (EVar "isDeadPathLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentShout")) (ELit (LString "comment line has three consecutive capitalised words"))) (ELit (LString "Three consecutive words in capitals read as shouting; state the constraint in plain words.\n\nBefore:\n  -- (caps) do not edit this\nAfter:\n  -- byte-pinned by a gate"))) (EVar "isShoutLine"))))
(DTypeSig false "classRule" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyCon "Rule"))))))
(DFunDef false "classRule" ((PVar "name") (PVar "summary") (PVar "doc") (PVar "hit")) (EApp (EApp (EApp (EApp (EApp (EVar "classRuleCoarse") (EVar "name")) (EVar "summary")) (EVar "doc")) (EVar "hit")) (EVar "hit")))
(DTypeSig false "classRuleCoarse" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyCon "Rule")))))))
(DFunDef false "classRuleCoarse" ((PVar "name") (PVar "summary") (PVar "doc") (PVar "coarse") (PVar "hit")) (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "name")) (fa "summary" (EVar "summary")) (fa "doc" (EVar "doc")) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (ELam (PWild PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "commentLineFindings") (EVar "name")) (EVar "coarse")) (EVar "hit")) (EVar "facts")))) (EVar "None")))
(DTypeSig false "commentLineFindings" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "commentLineFindings" ((PVar "name") (PVar "coarse") (PVar "hit") (PVar "facts")) (EBlock (DoLet false false (PVar "prose") (EApp (EVar "factProseComments") (EVar "facts"))) (DoLet false false (PVar "lineHits") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "hit") (EApp (EVar "commentText") (EVar "c"))))) (EFieldAccess (EVar "prose") "proseLines"))) (DoLet false false (PVar "blocks") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "coarse") (EApp (EVar "commentText") (EVar "c"))))) (EFieldAccess (EVar "prose") "proseBlocks"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "blockFindings") (EVar "name")) (EVar "hit"))) (EVar "blocks")) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EApp (EApp (EVar "lineFinding") (EVar "name")) (EApp (EVar "commentLine") (EVar "c"))))) (EVar "lineHits"))))))
(DTypeSig false "blockFindings" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "blockFindings" ((PVar "name") (PVar "hit") (PVar "c")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "n") (PCons (PVar "l") (PVar "rest"))) (EIf (EApp (EVar "hit") (EVar "l")) (EBinOp "::" (EApp (EApp (EVar "lineFinding") (EVar "name")) (EVar "n")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "rest"))) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "rest")))))) (EApp (EApp (EVar "go") (EApp (EVar "commentLine") (EVar "c"))) (EApp (EVar "splitNl") (EApp (EVar "commentText") (EVar "c"))))))
(DTypeSig false "lineFinding" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Finding"))))
(DFunDef false "lineFinding" ((PVar "name") (PVar "line")) (ERecordCreate "Finding" ((fa "rule" (EVar "name")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "comment line in the `")) (EApp (EVar "$core.display") (EVar "name"))) (ELit (LString "` register")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "line")) (ELit (LInt 1))) (EVar "line")) (ELit (LInt 1))))) (fa "fix" (EVar "noFix")))))
(DTypeSig false "anyInfix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "anyInfix" ((PVar "needles") (PVar "s")) (EApp (EApp (EVar "anyList") (ELam ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "s")))) (EVar "needles")))
(DTypeSig false "historyWordRe" (TyCon "Regex"))
(DFunDef false "historyWordRe" () (EApp (EVar "mustCompile") (ELit (LString "(^|[^A-Za-z0-9_])(formerly|withdrawn|used to)([^A-Za-z0-9_]|$)"))))
(DTypeSig false "hasHistoryPhrase" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasHistoryPhrase" ((PVar "l")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (ELit (LString "Until 2026-"))) (EVar "l")) (EApp (EApp (EVar "contains") (ELit (LString "The old "))) (EVar "l"))) (EBinOp "&&" (EApp (EApp (EVar "anyInfix") (EListLit (ELit (LString "formerly")) (ELit (LString "withdrawn")) (ELit (LString "used to")))) (EVar "l")) (EApp (EApp (EVar "isMatch") (EVar "historyWordRe")) (EVar "l")))))
(DTypeSig false "isHistoryLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHistoryLine" ((PVar "l")) (EBinOp "&&" (EApp (EVar "hasHistoryPhrase") (EVar "l")) (EApp (EVar "not") (EApp (EApp (EVar "anyInfix") (EListLit (ELit (LString "is used to")) (ELit (LString "are used to")) (ELit (LString "was used to")) (ELit (LString "be used to")) (ELit (LString "been used to")))) (EVar "l")))))
(DTypeSig false "isRulingLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isRulingLine" () (EApp (EVar "anyInfix") (EListLit (ELit (LString "refuted")) (ELit (LString "ratified")) (ELit (LString "withdrawn")) (ELit (LString "\"ruling\"")))))
(DTypeSig false "isTombstoneLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isTombstoneLine" () (EApp (EVar "anyInfix") (EListLit (ELit (LString "was HERE and is RETIRED")) (ELit (LString "do not re-add")) (ELit (LString "now lives in")) (ELit (LString "moved to")) (ELit (LString "now comes from")))))
(DTypeSig false "isEmojiLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isEmojiLine" ((PVar "l")) (EBinOp "&&" (EBinOp "/=" (EApp (EVar "stringByteLength") (EVar "l")) (EApp (EVar "stringLength") (EVar "l"))) (EApp (EApp (EVar "anyInfix") (EListLit (ELit (LString "🚨")) (ELit (LString "⚠️")) (ELit (LString "🔒")))) (EVar "l"))))
(DTypeSig false "isDraftLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDraftLine" () (EApp (EVar "anyInfix") (EListLit (ELit (LString "earlier cut")) (ELit (LString "first cut")) (ELit (LString "earlier revision")))))
(DTypeSig false "isDeicticLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDeicticLine" () (EApp (EVar "contains") (ELit (LString "this PR"))))
(DTypeSig false "deadPathRe" (TyCon "Regex"))
(DFunDef false "deadPathRe" () (EApp (EVar "mustCompile") (ELit (LString "lib/[A-Za-z0-9_./]*\\.ml[a-z]*"))))
(DTypeSig false "isDeadPathLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDeadPathLine" ((PVar "l")) (EBinOp "&&" (EApp (EApp (EVar "contains") (ELit (LString "lib/"))) (EVar "l")) (EApp (EApp (EVar "isMatch") (EVar "deadPathRe")) (EVar "l"))))
(DTypeSig false "isShoutLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isShoutLine" ((PVar "l")) (EApp (EVar "shoutFrom") (EApp (EVar "stringToChars") (EVar "l"))))
(DTypeSig false "shoutFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "shoutFrom" ((PVar "arr")) (ELetGroup ((lgb "go" (clause ((PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "False") (EIf (EApp (EApp (EVar "isUpperAt") (EVar "arr")) (EVar "i")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EVar "runEnd") (EVar "arr")) (EVar "i"))) (DoExpr (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EBinOp "-" (EVar "e") (EVar "i")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "shoutRest") (EVar "arr")) (EVar "e")) (ELit (LInt 2)))) (EApp (EVar "go") (EVar "e"))))) (EIf (EVar "otherwise") (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))) (EApp (EVar "go") (ELit (LInt 0)))))
(DTypeSig false "shoutRest" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "shoutRest" ((PVar "arr") (PVar "e") (PVar "k")) (EMatch (EApp (EApp (EVar "afterSep") (EVar "arr")) (EVar "e")) (arm (PCon "Some" (PVar "j")) () (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EVar "runEnd") (EVar "arr")) (EVar "j"))) (DoExpr (EBinOp "&&" (EBinOp ">=" (EBinOp "-" (EVar "e2") (EVar "j")) (ELit (LInt 2))) (EBinOp "||" (EBinOp "==" (EVar "k") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "shoutRest") (EVar "arr")) (EVar "e2")) (EBinOp "-" (EVar "k") (ELit (LInt 1))))))))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "runEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "runEnd" ((PVar "arr") (PVar "i")) (EIf (EApp (EApp (EVar "isUpperAt") (EVar "arr")) (EVar "i")) (EApp (EApp (EVar "runEnd") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i")))
(DTypeSig false "afterSep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "afterSep" ((PVar "arr") (PVar "e")) (EIf (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "arr")) (EVar "e")) (ELit (LChar " "))) (EApp (EVar "Some") (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EApp (EVar "isShoutPunct") (EApp (EApp (EVar "charAt") (EVar "arr")) (EVar "e"))) (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "arr")) (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (ELit (LChar " ")))) (EApp (EVar "Some") (EBinOp "+" (EVar "e") (ELit (LInt 2)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isShoutPunct" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isShoutPunct" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar ","))) (EBinOp "==" (EVar "c") (ELit (LChar ".")))) (EBinOp "==" (EVar "c") (ELit (LChar ":")))) (EBinOp "==" (EVar "c") (ELit (LChar ";")))) (EBinOp "==" (EVar "c") (ELit (LChar ")")))))
(DTypeSig false "charAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "charAt" ((PVar "arr") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\0"))))
(DTypeSig false "isUpperAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "isUpperAt" ((PVar "arr") (PVar "i")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EBinOp ">=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "A")))) (EBinOp "<=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "Z")))))
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "filterList" false) (mem "splitNl" false))))
(DUse false (UseGroup ("string") ((mem "contains" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "mustCompile" false) (mem "isMatch" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentLine" false) (mem "commentText" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "ProseComments" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "factProseComments" false) (mem "mkRule" false) (mem "noFix" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameCommentDeadPath" false) (mem "ruleNameCommentDeictic" false) (mem "ruleNameCommentDraft" false) (mem "ruleNameCommentEmoji" false) (mem "ruleNameCommentHistory" false) (mem "ruleNameCommentRuling" false) (mem "ruleNameCommentShout" false) (mem "ruleNameCommentTombstone" false))))
(DTypeSig true "rules" (TyApp (TyCon "List") (TyCon "Rule")))
(DFunDef false "rules" () (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "classRuleCoarse") (EVar "ruleNameCommentHistory")) (ELit (LString "comment line narrates history (\"formerly\", \"used to\", \"The old \", \"Until 2026-\")"))) (ELit (LString "A comment line that narrates what the code used to be (\"formerly\", \"used to\", \"withdrawn\", \"The old \", \"Until 2026-\") goes stale the day it is written; state the constraint the code carries now.\n\nBefore:\n  -- formerly a list, now a map\nAfter:\n  -- keyed by name so lookups stay O(log n)"))) (EVar "hasHistoryPhrase")) (EVar "isHistoryLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentRuling")) (ELit (LString "comment line uses reviewer-addressed ruling vocabulary (\"refuted\", \"ratified\", \"withdrawn\")"))) (ELit (LString "Ruling vocabulary (\"refuted\", \"ratified\", \"withdrawn\", \"ruling\") addresses a reviewer; it belongs on the PR or issue, not in the source.\n\nBefore:\n  -- ratified in review\nAfter:\n  -- the invariant the review settled, stated directly"))) (EVar "isRulingLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentTombstone")) (ELit (LString "comment line is a tombstone for code that no longer exists"))) (ELit (LString "A tombstone (\"was HERE and is RETIRED\", \"do not re-add\", \"now lives in\", \"moved to\", \"now comes from\") points at code that is gone.\n\nBefore:\n  -- moved to util.mdk\nAfter:\n  delete the comment"))) (EVar "isTombstoneLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentEmoji")) (ELit (LString "comment line carries an emoji shout"))) (ELit (LString "An emoji shout (a siren, a warning sign or a lock) in a comment; state the constraint in words.\n\nBefore:\n  -- (siren) never edit this\nAfter:\n  -- byte-pinned by a gate: edits break its golden"))) (EVar "isEmojiLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentDraft")) (ELit (LString "comment line narrates a draft (\"earlier cut\", \"first cut\", \"earlier revision\")"))) (ELit (LString "Draft self-narration (\"earlier cut\", \"first cut\", \"earlier revision\") describes the author's process, not the code.\n\nBefore:\n  -- the first cut used a list\nAfter:\n  delete the comment"))) (EVar "isDraftLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentDeictic")) (ELit (LString "comment line points at \"this PR\""))) (ELit (LString "A comment that says \"this PR\" does not survive the PR merging.\n\nBefore:\n  -- added in this PR\nAfter:\n  delete the comment"))) (EVar "isDeicticLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentDeadPath")) (ELit (LString "comment line cites a dead OCaml path (lib/*.ml)"))) (ELit (LString "A comment that cites a path under lib/ ending in .ml points at the removed OCaml compiler.\n\nBefore:\n  -- see lib/typecheck.ml\nAfter:\n  cite the Medaka module that holds the code"))) (EVar "isDeadPathLine")) (EApp (EApp (EApp (EApp (EVar "classRule") (EVar "ruleNameCommentShout")) (ELit (LString "comment line has three consecutive capitalised words"))) (ELit (LString "Three consecutive words in capitals read as shouting; state the constraint in plain words.\n\nBefore:\n  -- (caps) do not edit this\nAfter:\n  -- byte-pinned by a gate"))) (EVar "isShoutLine"))))
(DTypeSig false "classRule" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyCon "Rule"))))))
(DFunDef false "classRule" ((PVar "name") (PVar "summary") (PVar "doc") (PVar "hit")) (EApp (EApp (EApp (EApp (EApp (EVar "classRuleCoarse") (EVar "name")) (EVar "summary")) (EVar "doc")) (EVar "hit")) (EVar "hit")))
(DTypeSig false "classRuleCoarse" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyCon "Rule")))))))
(DFunDef false "classRuleCoarse" ((PVar "name") (PVar "summary") (PVar "doc") (PVar "coarse") (PVar "hit")) (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "name")) (fa "summary" (EVar "summary")) (fa "doc" (EVar "doc")) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (ELam (PWild PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "commentLineFindings") (EVar "name")) (EVar "coarse")) (EVar "hit")) (EVar "facts")))) (EVar "None")))
(DTypeSig false "commentLineFindings" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyCon "FileFacts") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "commentLineFindings" ((PVar "name") (PVar "coarse") (PVar "hit") (PVar "facts")) (EBlock (DoLet false false (PVar "prose") (EApp (EVar "factProseComments") (EVar "facts"))) (DoLet false false (PVar "lineHits") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "hit") (EApp (EVar "commentText") (EVar "c"))))) (EFieldAccess (EVar "prose") "proseLines"))) (DoLet false false (PVar "blocks") (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "coarse") (EApp (EVar "commentText") (EVar "c"))))) (EFieldAccess (EVar "prose") "proseBlocks"))) (DoExpr (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "blockFindings") (EVar "name")) (EVar "hit"))) (EVar "blocks")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EApp (EApp (EVar "lineFinding") (EVar "name")) (EApp (EVar "commentLine") (EVar "c"))))) (EVar "lineHits"))))))
(DTypeSig false "blockFindings" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "blockFindings" ((PVar "name") (PVar "hit") (PVar "c")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "n") (PCons (PVar "l") (PVar "rest"))) (EIf (EApp (EVar "hit") (EVar "l")) (EBinOp "::" (EApp (EApp (EVar "lineFinding") (EVar "name")) (EVar "n")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "rest"))) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "rest")))))) (EApp (EApp (EVar "go") (EApp (EVar "commentLine") (EVar "c"))) (EApp (EVar "splitNl") (EApp (EVar "commentText") (EVar "c"))))))
(DTypeSig false "lineFinding" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Finding"))))
(DFunDef false "lineFinding" ((PVar "name") (PVar "line")) (ERecordCreate "Finding" ((fa "rule" (EVar "name")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "comment line in the `")) (EApp (EVar "$core.display") (EVar "name"))) (ELit (LString "` register")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "line")) (ELit (LInt 1))) (EVar "line")) (ELit (LInt 1))))) (fa "fix" (EVar "noFix")))))
(DTypeSig false "anyInfix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "anyInfix" ((PVar "needles") (PVar "s")) (EApp (EApp (EVar "anyList") (ELam ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "s")))) (EVar "needles")))
(DTypeSig false "historyWordRe" (TyCon "Regex"))
(DFunDef false "historyWordRe" () (EApp (EVar "mustCompile") (ELit (LString "(^|[^A-Za-z0-9_])(formerly|withdrawn|used to)([^A-Za-z0-9_]|$)"))))
(DTypeSig false "hasHistoryPhrase" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasHistoryPhrase" ((PVar "l")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (ELit (LString "Until 2026-"))) (EVar "l")) (EApp (EApp (EVar "contains") (ELit (LString "The old "))) (EVar "l"))) (EBinOp "&&" (EApp (EApp (EVar "anyInfix") (EListLit (ELit (LString "formerly")) (ELit (LString "withdrawn")) (ELit (LString "used to")))) (EVar "l")) (EApp (EApp (EVar "isMatch") (EVar "historyWordRe")) (EVar "l")))))
(DTypeSig false "isHistoryLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHistoryLine" ((PVar "l")) (EBinOp "&&" (EApp (EVar "hasHistoryPhrase") (EVar "l")) (EApp (EVar "not") (EApp (EApp (EVar "anyInfix") (EListLit (ELit (LString "is used to")) (ELit (LString "are used to")) (ELit (LString "was used to")) (ELit (LString "be used to")) (ELit (LString "been used to")))) (EVar "l")))))
(DTypeSig false "isRulingLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isRulingLine" () (EApp (EVar "anyInfix") (EListLit (ELit (LString "refuted")) (ELit (LString "ratified")) (ELit (LString "withdrawn")) (ELit (LString "\"ruling\"")))))
(DTypeSig false "isTombstoneLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isTombstoneLine" () (EApp (EVar "anyInfix") (EListLit (ELit (LString "was HERE and is RETIRED")) (ELit (LString "do not re-add")) (ELit (LString "now lives in")) (ELit (LString "moved to")) (ELit (LString "now comes from")))))
(DTypeSig false "isEmojiLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isEmojiLine" ((PVar "l")) (EBinOp "&&" (EBinOp "/=" (EApp (EVar "stringByteLength") (EVar "l")) (EApp (EVar "stringLength") (EVar "l"))) (EApp (EApp (EVar "anyInfix") (EListLit (ELit (LString "🚨")) (ELit (LString "⚠️")) (ELit (LString "🔒")))) (EVar "l"))))
(DTypeSig false "isDraftLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDraftLine" () (EApp (EVar "anyInfix") (EListLit (ELit (LString "earlier cut")) (ELit (LString "first cut")) (ELit (LString "earlier revision")))))
(DTypeSig false "isDeicticLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDeicticLine" () (EApp (EVar "contains") (ELit (LString "this PR"))))
(DTypeSig false "deadPathRe" (TyCon "Regex"))
(DFunDef false "deadPathRe" () (EApp (EVar "mustCompile") (ELit (LString "lib/[A-Za-z0-9_./]*\\.ml[a-z]*"))))
(DTypeSig false "isDeadPathLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDeadPathLine" ((PVar "l")) (EBinOp "&&" (EApp (EApp (EVar "contains") (ELit (LString "lib/"))) (EVar "l")) (EApp (EApp (EVar "isMatch") (EVar "deadPathRe")) (EVar "l"))))
(DTypeSig false "isShoutLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isShoutLine" ((PVar "l")) (EApp (EVar "shoutFrom") (EApp (EVar "stringToChars") (EVar "l"))))
(DTypeSig false "shoutFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "shoutFrom" ((PVar "arr")) (ELetGroup ((lgb "go" (clause ((PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "False") (EIf (EApp (EApp (EVar "isUpperAt") (EVar "arr")) (EVar "i")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EVar "runEnd") (EVar "arr")) (EVar "i"))) (DoExpr (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EBinOp "-" (EVar "e") (EVar "i")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "shoutRest") (EVar "arr")) (EVar "e")) (ELit (LInt 2)))) (EApp (EVar "go") (EVar "e"))))) (EIf (EVar "otherwise") (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))) (EApp (EVar "go") (ELit (LInt 0)))))
(DTypeSig false "shoutRest" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "shoutRest" ((PVar "arr") (PVar "e") (PVar "k")) (EMatch (EApp (EApp (EVar "afterSep") (EVar "arr")) (EVar "e")) (arm (PCon "Some" (PVar "j")) () (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EVar "runEnd") (EVar "arr")) (EVar "j"))) (DoExpr (EBinOp "&&" (EBinOp ">=" (EBinOp "-" (EVar "e2") (EVar "j")) (ELit (LInt 2))) (EBinOp "||" (EBinOp "==" (EVar "k") (ELit (LInt 1))) (EApp (EApp (EApp (EVar "shoutRest") (EVar "arr")) (EVar "e2")) (EBinOp "-" (EVar "k") (ELit (LInt 1))))))))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "runEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "runEnd" ((PVar "arr") (PVar "i")) (EIf (EApp (EApp (EVar "isUpperAt") (EVar "arr")) (EVar "i")) (EApp (EApp (EVar "runEnd") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i")))
(DTypeSig false "afterSep" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "afterSep" ((PVar "arr") (PVar "e")) (EIf (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "arr")) (EVar "e")) (ELit (LChar " "))) (EApp (EVar "Some") (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EApp (EVar "isShoutPunct") (EApp (EApp (EVar "charAt") (EVar "arr")) (EVar "e"))) (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "arr")) (EBinOp "+" (EVar "e") (ELit (LInt 1)))) (ELit (LChar " ")))) (EApp (EVar "Some") (EBinOp "+" (EVar "e") (ELit (LInt 2)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isShoutPunct" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isShoutPunct" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar ","))) (EBinOp "==" (EVar "c") (ELit (LChar ".")))) (EBinOp "==" (EVar "c") (ELit (LChar ":")))) (EBinOp "==" (EVar "c") (ELit (LChar ";")))) (EBinOp "==" (EVar "c") (ELit (LChar ")")))))
(DTypeSig false "charAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Char"))))
(DFunDef false "charAt" ((PVar "arr") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "\0"))))
(DTypeSig false "isUpperAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "isUpperAt" ((PVar "arr") (PVar "i")) (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EBinOp ">=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "A")))) (EBinOp "<=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar "Z")))))
