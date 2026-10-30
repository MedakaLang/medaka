# META
source_lines=340
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-promissory-reader: a comment says a symbol has no reader yet, but the file reads it (#2550).

import frontend.ast.{Loc(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{listLen, anyList, splitNl, joinWith, startsWith, isSome}
import list.{last}
import support.char.{isAlnum}
import regex.{
  Regex, Match, mustCompile, isMatch, find as reFind, findAll as reFindAll,
  replaceAll, escape
}
import tools.lint_core.{
  Category(..),
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
  codeLineAt,
  codePortions,
  commentBlocks,
  ruleNamePromissoryReader,
  trimWs,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNamePromissoryReader,
      summary =
        "comment claims a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") but the file reads it (#2550)",
      doc =
        "A comment claiming a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") while the file reads it is stale and misleads the next editor (#2550). This enforces the repository comment register.\n\nBefore:\n  -- nothing reads this yet\n  cache = ...   -- read two screens down\nAfter:\n  delete or correct the comment",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    rulePromissoryReader
    None

-- ── rule: promissory-reader (#2550) ───────────────────────────────────────────
-- A comment claiming a symbol is not read YET ("nothing reads this yet",
-- "no reader yet", "do not add a reader") is a negative about the whole file that
-- expires the moment a reader lands, and no other gate notices (#2550 has the
-- measured failure rate).  This rule asserts the claim: the subject must occur in
-- no code line of the file other than its own definition.
--
-- The SUBJECT is, in order: the identifier the claim names in backticks right
-- after "reads" (the claim names its subject in backticks); for a trailing comment, the field or
-- binding declared on the comment's own line; for a leading block, the first
-- declaration after the block (an `export` line is skipped).  A READER is any
-- whole-word occurrence of the subject on a code line that is not the subject's
-- own signature, clause head, field declaration or record initializer, and is not
-- an assignment target (`x := …`).  Double-quoted spans are removed before the
-- phrase test, so a retraction that quotes the old claim is not a claim.
--
-- Deliberately NOT matched: the backward-looking form ("inert BECAUSE x was
-- reverted", "MEASURED constant-True").  Those carry their own evidence and do not
-- expire; each one in the tree stopped a deletion that a body-only reading would
-- have licensed.  The defect this rule fixes is the grammatical form, not the
-- practice of recording inertness.
rulePromissoryReader : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
rulePromissoryReader _ path facts _ _ =
  let ls = splitNl facts.ffSrc
  let comments = factComments facts
  let codeLines = arrayFromList (codePortions ls comments 1)
  flatMap
    (promissoryFinding path codeLines)
    (promissoryClaims (commentBlocks comments codeLines))

-- Blocks whose (quote-stripped, lowercased) text makes a promissory claim, as
-- (claim line, its raw text, the block).
promissoryClaims : List CommentBlock -> List (Int, String, CommentBlock)
promissoryClaims blocks = flatMap promissoryClaimOf blocks

promissoryClaimOf : CommentBlock -> List (Int, String, CommentBlock)
promissoryClaimOf (b@(CommentBlock first _ _ text)) =
  if not (mayBePromissory (stringToLower text)) then
    []
  else
    let lines = splitNl text
    match promissoryLine lines 0
      Some (i, l) => [(first + i, l, b)]
      None =>
        -- a claim wrapped across lines: test the block as one line
        let joined = joinWith " " lines
        if isPromissoryText (stringToLower (stripQuoted joined)) then
          [(first, joined, b)]
        else
          []

-- Necessary condition of `isPromissoryText` on lowercased RAW text: every
-- phrase contains `yet` or `reader`.  Both are space-free, so a quoted span
-- replaced by a space in `stripQuoted` cannot create one.
mayBePromissory : String -> Bool
mayBePromissory low =
  isSome (stringIndexOf "yet" low) || isSome (stringIndexOf "reader" low)

promissoryLine : List String -> Int -> Option (Int, String)
promissoryLine [] _ = None
promissoryLine (l :: rest) i
  | mayBePromissory (stringToLower l)
    && isPromissoryText (stringToLower (stripQuoted l)) = Some (i, l)
  | otherwise = promissoryLine rest (i + 1)

nothingReadsRe : Regex
nothingReadsRe = mustCompile (escape "nothing reads")

yetRe : Regex
yetRe = mustCompile (escape "yet")

promissoryPhraseRe : Regex
promissoryPhraseRe =
  mustCompile
    (joinWith
      "|"
      (map escape [
        "no reader yet",
        "no readers yet",
        "no consumer yet",
        "no consumers yet",
        "do not add a reader",
        "don't add a reader",
      ]))

isPromissoryText : String -> Bool
isPromissoryText t =
  isMatch nothingReadsRe t && isMatch yetRe t || isMatch promissoryPhraseRe t

quoteCharRe : Regex
quoteCharRe = mustCompile "\""

pairedQuoteRe : Regex
pairedQuoteRe = mustCompile "\"[^\"]*\""

-- Drop every double-quoted span (an unterminated quote runs to end of line).
-- Pairing is sequential from the start (1st+2nd quote, 3rd+4th, …), so an odd
-- total count means the LAST quote is the unpaired one; truncate there first
-- (matching the original recursion's per-line "runs to end of line" base
-- case), then replace every remaining paired span with a single space.
stripQuoted : String -> String
stripQuoted s =
  let quotes = reFindAll quoteCharRe s
  let truncated =
    if listLen quotes % 2 == 1 then match last quotes
      Some m => stringSlice 0 m.start s
      None => s
    else
      s
  replaceAll pairedQuoteRe " " truncated

-- The subject of a claim, per the header's order.
claimSubject : Array String -> (Int, String, CommentBlock) -> Option String
claimSubject codeLines (line, text, CommentBlock _ last trailing _) =
  match backtickedAfterReads text
    Some n => Some n
    None =>
      if trailing then
        declaredNameOf (codeLineAt codeLines line)
      else
        nextDeclaredName codeLines (last + 1)

-- The backticked subject: the identifier right after "reads `" in the claim.
backtickedAfterReads : String -> Option String
backtickedAfterReads t =
  let lower = stringToLower t
  match stringIndexOf "reads `" lower
    None => None
    Some i =>
      let start = i + stringLength "reads `"
      let rest = stringSlice start (stringLength t) t
      map (j => stringSlice 0 j rest) (stringIndexOf "`" rest)

-- The first declaration at or after `line`: a signature, clause head, field or
-- data/type name; `export` lines are skipped; a blank line ends the search (the
-- comment did not precede a declaration).
nextDeclaredName : Array String -> Int -> Option String
nextDeclaredName codeLines line
  | line > arrayLength codeLines = None
  | otherwise =
    let t = trimWs (codeLineAt codeLines line)
    if t == "export" || t == "public export" then
      nextDeclaredName codeLines (line + 1)
    else
      declaredNameOf t

-- The identifier a code line declares: the leading word of `name : …`,
-- `name args = …`, `  field : …`, `data Name` / `type Name`, after an optional
-- `export` / `public export` prefix.
declaredNameOf : String -> Option String
declaredNameOf c =
  let t = trimWs c
  let t1 = dropPrefixWord "public" t
  let t2 = dropPrefixWord "export" t1
  let t3 =
    dropPrefixWord
      "data"
      (dropPrefixWord "type" (dropPrefixWord "interface" t2))
  let w = leadingIdent t3
  if w == "" then None else Some w

dropPrefixWord : String -> String -> String
dropPrefixWord w s
  | startsWith (w ++ " ") s =
    trimWs (stringSlice (stringLength w) (stringLength s) s)
  | otherwise = s

leadingIdentRe : Regex
leadingIdentRe = mustCompile "^[A-Za-z0-9_']+"

leadingIdent : String -> String
leadingIdent s = match reFind leadingIdentRe s
  Some m => m.text
  None => ""

isIdentChar : Char -> Bool
isIdentChar ch = isAlnum ch || ch == '_' || ch == '\''

-- The finding: a claim whose subject has a reader.
promissoryFinding : String ->
  Array String ->
  (Int, String, CommentBlock) ->
  List Finding
promissoryFinding path codeLines claim = match claimSubject codeLines claim
  None => []
  Some subject =>
    -- a claim about a name this file does not declare is another file's to bear
    -- out (and a bare word from the prose would otherwise match any use of it)
    if declaredInFile subject codeLines then
      readerFinding path subject claim (readerLines subject codeLines)
    else
      []

readerFinding : String ->
  String ->
  (Int, String, CommentBlock) ->
  List Int ->
  List Finding
readerFinding _ _ _ [] = []
readerFinding path subject (line, _, _) (firstReader :: more) = [
  Finding {
    rule = ruleNamePromissoryReader,
    message =
      "comment claims nothing reads `\{subject}` yet, but it is read on line \{firstReader}\{readerCountSuffix (listLen more)}. Restate the claim as what is measured today, or delete it",
    severity = SevWarning,
    loc = Some (Loc path line 1 line 1),
    fix = None,
  },
]

declaredInFile : String -> Array String -> Bool
declaredInFile subject codeLines =
  declaredInFileGo subject codeLines (arrayLength codeLines) 1

declaredInFileGo : String -> Array String -> Int -> Int -> Bool
declaredInFileGo subject codeLines n line
  | line > n = False
  | isDefinitionLine subject (arrayGetUnsafe (line - 1) codeLines) = True
  | otherwise = declaredInFileGo subject codeLines n (line + 1)

readerCountSuffix : Int -> String
readerCountSuffix 0 = ""
readerCountSuffix n = " and \{n} more line(s)"

-- Every code line on which `subject` occurs as a reader, ascending.
readerLines : String -> Array String -> List Int
readerLines subject codeLines =
  readerLinesGo subject codeLines (arrayLength codeLines) 1

readerLinesGo : String -> Array String -> Int -> Int -> List Int
readerLinesGo subject codeLines n line
  | line > n = []
  | isReaderLine subject (arrayGetUnsafe (line - 1) codeLines) =
    line :: readerLinesGo subject codeLines n (line + 1)
  | otherwise = readerLinesGo subject codeLines n (line + 1)

isReaderLine : String -> String -> Bool
isReaderLine subject c =
  not (isDefinitionLine subject c) && wordReadIn subject c

-- `subject` at column 0 (signature / clause head, optionally `export`-prefixed),
-- or indented and followed by `:` (field declaration) or `=` (record initializer).
isDefinitionLine : String -> String -> Bool
isDefinitionLine subject c =
  let t = dropPrefixWord "export" (dropPrefixWord "public" (trimWs c))
  let after = trimWs (stringSlice (stringLength subject) (stringLength t) t)
  startsWith subject t
    && identBoundaryAt (stringToChars t) (stringLength subject)
    && (not (startsWith " " c || startsWith "\t" c)
      || startsWith ":" after && not (startsWith ":=" after)
      || startsWith "=" after && not (startsWith "==" after))

identBoundaryAt : Array Char -> Int -> Bool
identBoundaryAt cs i =
  i >= arrayLength cs || not (isIdentChar (arrayGetUnsafe i cs))

-- Whole-word occurrence of `w` in `line` that is not an assignment target.
-- `reFindAll` locates every raw occurrence of `w`; the boundary and
-- assignment-target checks stay plain code and are applied to each match's
-- OWN position afterward (match, then test the tail), rather than folded
-- into the pattern — a consuming boundary class baked into the pattern would
-- make two occurrences of `w` separated by exactly one boundary char (e.g.
-- `a[a]`) invisible to a left-to-right non-overlapping scan, since the first
-- match would consume the shared boundary character the second needs.
wordReadIn : String -> String -> Bool
wordReadIn w line =
  let cs = stringToChars line
  let n = arrayLength cs
  anyList (m => wordReadOk cs n m) (reFindAll (mustCompile (escape w)) line)

wordReadOk : Array Char -> Int -> Match -> Bool
wordReadOk cs n m =
  (m.start == 0 || not (isIdentChar (arrayGetUnsafe (m.start - 1) cs)))
    && identBoundaryAt cs m.end
    && not (assignFollows cs n m.end)

assignFollows : Array Char -> Int -> Int -> Bool
assignFollows cs n i
  | i < n && arrayGetUnsafe i cs == ' ' = assignFollows cs n (i + 1)
  | i + 1 < n = arrayGetUnsafe i cs == ':' && arrayGetUnsafe (i + 1) cs == '='
  | otherwise = False
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "anyList" false) (mem "splitNl" false) (mem "joinWith" false) (mem "startsWith" false) (mem "isSome" false))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "Match" false) (mem "mustCompile" false) (mem "isMatch" false) (mem "find" false "reFind") (mem "findAll" false "reFindAll") (mem "replaceAll" false) (mem "escape" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factComments" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "CommentBlock" true) (mem "codeLineAt" false) (mem "codePortions" false) (mem "commentBlocks" false) (mem "ruleNamePromissoryReader" false) (mem "trimWs" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePromissoryReader")) (fa "summary" (ELit (LString "comment claims a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") but the file reads it (#2550)"))) (fa "doc" (ELit (LString "A comment claiming a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") while the file reads it is stale and misleads the next editor (#2550). This enforces the repository comment register.\n\nBefore:\n  -- nothing reads this yet\n  cache = ...   -- read two screens down\nAfter:\n  delete or correct the comment"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "rulePromissoryReader")) (EVar "None")))
(DTypeSig false "rulePromissoryReader" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "rulePromissoryReader" (PWild (PVar "path") (PVar "facts") PWild PWild) (EBlock (DoLet false false (PVar "ls") (EApp (EVar "splitNl") (EFieldAccess (EVar "facts") "ffSrc"))) (DoLet false false (PVar "comments") (EApp (EVar "factComments") (EVar "facts"))) (DoLet false false (PVar "codeLines") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "codePortions") (EVar "ls")) (EVar "comments")) (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "promissoryFinding") (EVar "path")) (EVar "codeLines"))) (EApp (EVar "promissoryClaims") (EApp (EApp (EVar "commentBlocks") (EVar "comments")) (EVar "codeLines")))))))
(DTypeSig false "promissoryClaims" (TyFun (TyApp (TyCon "List") (TyCon "CommentBlock")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String") (TyCon "CommentBlock")))))
(DFunDef false "promissoryClaims" ((PVar "blocks")) (EApp (EApp (EVar "flatMap") (EVar "promissoryClaimOf")) (EVar "blocks")))
(DTypeSig false "promissoryClaimOf" (TyFun (TyCon "CommentBlock") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String") (TyCon "CommentBlock")))))
(DFunDef false "promissoryClaimOf" ((PAs "b" (PCon "CommentBlock" (PVar "first") PWild PWild (PVar "text")))) (EIf (EApp (EVar "not") (EApp (EVar "mayBePromissory") (EApp (EVar "stringToLower") (EVar "text")))) (EListLit) (EBlock (DoLet false false (PVar "lines") (EApp (EVar "splitNl") (EVar "text"))) (DoExpr (EMatch (EApp (EApp (EVar "promissoryLine") (EVar "lines")) (ELit (LInt 0))) (arm (PCon "Some" (PTuple (PVar "i") (PVar "l"))) () (EListLit (ETuple (EBinOp "+" (EVar "first") (EVar "i")) (EVar "l") (EVar "b")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "joined") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "lines"))) (DoExpr (EIf (EApp (EVar "isPromissoryText") (EApp (EVar "stringToLower") (EApp (EVar "stripQuoted") (EVar "joined")))) (EListLit (ETuple (EVar "first") (EVar "joined") (EVar "b"))) (EListLit))))))))))
(DTypeSig false "mayBePromissory" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "mayBePromissory" ((PVar "low")) (EBinOp "||" (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (ELit (LString "yet"))) (EVar "low"))) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (ELit (LString "reader"))) (EVar "low")))))
(DTypeSig false "promissoryLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "String"))))))
(DFunDef false "promissoryLine" ((PList) PWild) (EVar "None"))
(DFunDef false "promissoryLine" ((PCons (PVar "l") (PVar "rest")) (PVar "i")) (EIf (EBinOp "&&" (EApp (EVar "mayBePromissory") (EApp (EVar "stringToLower") (EVar "l"))) (EApp (EVar "isPromissoryText") (EApp (EVar "stringToLower") (EApp (EVar "stripQuoted") (EVar "l"))))) (EApp (EVar "Some") (ETuple (EVar "i") (EVar "l"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "promissoryLine") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nothingReadsRe" (TyCon "Regex"))
(DFunDef false "nothingReadsRe" () (EApp (EVar "mustCompile") (EApp (EVar "escape") (ELit (LString "nothing reads")))))
(DTypeSig false "yetRe" (TyCon "Regex"))
(DFunDef false "yetRe" () (EApp (EVar "mustCompile") (EApp (EVar "escape") (ELit (LString "yet")))))
(DTypeSig false "promissoryPhraseRe" (TyCon "Regex"))
(DFunDef false "promissoryPhraseRe" () (EApp (EVar "mustCompile") (EApp (EApp (EVar "joinWith") (ELit (LString "|"))) (EApp (EApp (EVar "map") (EVar "escape")) (EListLit (ELit (LString "no reader yet")) (ELit (LString "no readers yet")) (ELit (LString "no consumer yet")) (ELit (LString "no consumers yet")) (ELit (LString "do not add a reader")) (ELit (LString "don't add a reader")))))))
(DTypeSig false "isPromissoryText" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isPromissoryText" ((PVar "t")) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EVar "isMatch") (EVar "nothingReadsRe")) (EVar "t")) (EApp (EApp (EVar "isMatch") (EVar "yetRe")) (EVar "t"))) (EApp (EApp (EVar "isMatch") (EVar "promissoryPhraseRe")) (EVar "t"))))
(DTypeSig false "quoteCharRe" (TyCon "Regex"))
(DFunDef false "quoteCharRe" () (EApp (EVar "mustCompile") (ELit (LString "\""))))
(DTypeSig false "pairedQuoteRe" (TyCon "Regex"))
(DFunDef false "pairedQuoteRe" () (EApp (EVar "mustCompile") (ELit (LString "\"[^\"]*\""))))
(DTypeSig false "stripQuoted" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripQuoted" ((PVar "s")) (EBlock (DoLet false false (PVar "quotes") (EApp (EApp (EVar "reFindAll") (EVar "quoteCharRe")) (EVar "s"))) (DoLet false false (PVar "truncated") (EIf (EBinOp "==" (EBinOp "%" (EApp (EVar "listLen") (EVar "quotes")) (ELit (LInt 2))) (ELit (LInt 1))) (EMatch (EApp (EVar "last") (EVar "quotes")) (arm (PCon "Some" (PVar "m")) () (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EFieldAccess (EVar "m") "start")) (EVar "s"))) (arm (PCon "None") () (EVar "s"))) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "replaceAll") (EVar "pairedQuoteRe")) (ELit (LString " "))) (EVar "truncated")))))
(DTypeSig false "claimSubject" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyTuple (TyCon "Int") (TyCon "String") (TyCon "CommentBlock")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "claimSubject" ((PVar "codeLines") (PTuple (PVar "line") (PVar "text") (PCon "CommentBlock" PWild (PVar "last") (PVar "trailing") PWild))) (EMatch (EApp (EVar "backtickedAfterReads") (EVar "text")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "None") () (EIf (EVar "trailing") (EApp (EVar "declaredNameOf") (EApp (EApp (EVar "codeLineAt") (EVar "codeLines")) (EVar "line"))) (EApp (EApp (EVar "nextDeclaredName") (EVar "codeLines")) (EBinOp "+" (EVar "last") (ELit (LInt 1))))))))
(DTypeSig false "backtickedAfterReads" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "backtickedAfterReads" ((PVar "t")) (EBlock (DoLet false false (PVar "lower") (EApp (EVar "stringToLower") (EVar "t"))) (DoExpr (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "reads `"))) (EVar "lower")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "start") (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (ELit (LString "reads `"))))) (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EApp (EVar "stringLength") (EVar "t"))) (EVar "t"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "j")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "j")) (EVar "rest")))) (EApp (EApp (EVar "stringIndexOf") (ELit (LString "`"))) (EVar "rest"))))))))))
(DTypeSig false "nextDeclaredName" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "nextDeclaredName" ((PVar "codeLines") (PVar "line")) (EIf (EBinOp ">" (EVar "line") (EApp (EVar "arrayLength") (EVar "codeLines"))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "t") (EApp (EVar "trimWs") (EApp (EApp (EVar "codeLineAt") (EVar "codeLines")) (EVar "line")))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "t") (ELit (LString "export"))) (EBinOp "==" (EVar "t") (ELit (LString "public export")))) (EApp (EApp (EVar "nextDeclaredName") (EVar "codeLines")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EApp (EVar "declaredNameOf") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declaredNameOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declaredNameOf" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "trimWs") (EVar "c"))) (DoLet false false (PVar "t1") (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "public"))) (EVar "t"))) (DoLet false false (PVar "t2") (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "export"))) (EVar "t1"))) (DoLet false false (PVar "t3") (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "data"))) (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "type"))) (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "interface"))) (EVar "t2"))))) (DoLet false false (PVar "w") (EApp (EVar "leadingIdent") (EVar "t3"))) (DoExpr (EIf (EBinOp "==" (EVar "w") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "w"))))))
(DTypeSig false "dropPrefixWord" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "dropPrefixWord" ((PVar "w") (PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (EBinOp "++" (EVar "w") (ELit (LString " ")))) (EVar "s")) (EApp (EVar "trimWs") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "w"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "leadingIdentRe" (TyCon "Regex"))
(DFunDef false "leadingIdentRe" () (EApp (EVar "mustCompile") (ELit (LString "^[A-Za-z0-9_']+"))))
(DTypeSig false "leadingIdent" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "leadingIdent" ((PVar "s")) (EMatch (EApp (EApp (EVar "reFind") (EVar "leadingIdentRe")) (EVar "s")) (arm (PCon "Some" (PVar "m")) () (EFieldAccess (EVar "m") "text")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "isIdentChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isIdentChar" ((PVar "ch")) (EBinOp "||" (EBinOp "||" (EApp (EVar "isAlnum") (EVar "ch")) (EBinOp "==" (EVar "ch") (ELit (LChar "_")))) (EBinOp "==" (EVar "ch") (ELit (LChar "'")))))
(DTypeSig false "promissoryFinding" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyTuple (TyCon "Int") (TyCon "String") (TyCon "CommentBlock")) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "promissoryFinding" ((PVar "path") (PVar "codeLines") (PVar "claim")) (EMatch (EApp (EApp (EVar "claimSubject") (EVar "codeLines")) (EVar "claim")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "subject")) () (EIf (EApp (EApp (EVar "declaredInFile") (EVar "subject")) (EVar "codeLines")) (EApp (EApp (EApp (EApp (EVar "readerFinding") (EVar "path")) (EVar "subject")) (EVar "claim")) (EApp (EApp (EVar "readerLines") (EVar "subject")) (EVar "codeLines"))) (EListLit)))))
(DTypeSig false "readerFinding" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Int") (TyCon "String") (TyCon "CommentBlock")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "readerFinding" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "readerFinding" ((PVar "path") (PVar "subject") (PTuple (PVar "line") PWild PWild) (PCons (PVar "firstReader") (PVar "more"))) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePromissoryReader")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "comment claims nothing reads `")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString "` yet, but it is read on line "))) (EApp (EVar "display") (EVar "firstReader"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "readerCountSuffix") (EApp (EVar "listLen") (EVar "more"))))) (ELit (LString ". Restate the claim as what is measured today, or delete it")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "line")) (ELit (LInt 1))) (EVar "line")) (ELit (LInt 1))))) (fa "fix" (EVar "None"))))))
(DTypeSig false "declaredInFile" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "declaredInFile" ((PVar "subject") (PVar "codeLines")) (EApp (EApp (EApp (EApp (EVar "declaredInFileGo") (EVar "subject")) (EVar "codeLines")) (EApp (EVar "arrayLength") (EVar "codeLines"))) (ELit (LInt 1))))
(DTypeSig false "declaredInFileGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "declaredInFileGo" ((PVar "subject") (PVar "codeLines") (PVar "n") (PVar "line")) (EIf (EBinOp ">" (EVar "line") (EVar "n")) (EVar "False") (EIf (EApp (EApp (EVar "isDefinitionLine") (EVar "subject")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EVar "codeLines"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "declaredInFileGo") (EVar "subject")) (EVar "codeLines")) (EVar "n")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "readerCountSuffix" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "readerCountSuffix" ((PLit (LInt 0))) (ELit (LString "")))
(DFunDef false "readerCountSuffix" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString " and ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " more line(s)"))))
(DTypeSig false "readerLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "readerLines" ((PVar "subject") (PVar "codeLines")) (EApp (EApp (EApp (EApp (EVar "readerLinesGo") (EVar "subject")) (EVar "codeLines")) (EApp (EVar "arrayLength") (EVar "codeLines"))) (ELit (LInt 1))))
(DTypeSig false "readerLinesGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "readerLinesGo" ((PVar "subject") (PVar "codeLines") (PVar "n") (PVar "line")) (EIf (EBinOp ">" (EVar "line") (EVar "n")) (EListLit) (EIf (EApp (EApp (EVar "isReaderLine") (EVar "subject")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EVar "codeLines"))) (EBinOp "::" (EVar "line") (EApp (EApp (EApp (EApp (EVar "readerLinesGo") (EVar "subject")) (EVar "codeLines")) (EVar "n")) (EBinOp "+" (EVar "line") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "readerLinesGo") (EVar "subject")) (EVar "codeLines")) (EVar "n")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isReaderLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isReaderLine" ((PVar "subject") (PVar "c")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "isDefinitionLine") (EVar "subject")) (EVar "c"))) (EApp (EApp (EVar "wordReadIn") (EVar "subject")) (EVar "c"))))
(DTypeSig false "isDefinitionLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isDefinitionLine" ((PVar "subject") (PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "export"))) (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "public"))) (EApp (EVar "trimWs") (EVar "c"))))) (DoLet false false (PVar "after") (EApp (EVar "trimWs") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "subject"))) (EApp (EVar "stringLength") (EVar "t"))) (EVar "t")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EVar "subject")) (EVar "t")) (EApp (EApp (EVar "identBoundaryAt") (EApp (EVar "stringToChars") (EVar "t"))) (EApp (EVar "stringLength") (EVar "subject")))) (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EBinOp "||" (EApp (EApp (EVar "startsWith") (ELit (LString " "))) (EVar "c")) (EApp (EApp (EVar "startsWith") (ELit (LString "\t"))) (EVar "c")))) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString ":"))) (EVar "after")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString ":="))) (EVar "after"))))) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "="))) (EVar "after")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "=="))) (EVar "after")))))))))
(DTypeSig false "identBoundaryAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "identBoundaryAt" ((PVar "cs") (PVar "i")) (EBinOp "||" (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))))
(DTypeSig false "wordReadIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "wordReadIn" ((PVar "w") (PVar "line")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "line"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "wordReadOk") (EVar "cs")) (EVar "n")) (EVar "m")))) (EApp (EApp (EVar "reFindAll") (EApp (EVar "mustCompile") (EApp (EVar "escape") (EVar "w")))) (EVar "line"))))))
(DTypeSig false "wordReadOk" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Match") (TyCon "Bool")))))
(DFunDef false "wordReadOk" ((PVar "cs") (PVar "n") (PVar "m")) (EBinOp "&&" (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "m") "start") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EFieldAccess (EVar "m") "start") (ELit (LInt 1)))) (EVar "cs"))))) (EApp (EApp (EVar "identBoundaryAt") (EVar "cs")) (EFieldAccess (EVar "m") "end"))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "assignFollows") (EVar "cs")) (EVar "n")) (EFieldAccess (EVar "m") "end")))))
(DTypeSig false "assignFollows" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "assignFollows" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EVar "n")) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar " ")))) (EApp (EApp (EApp (EVar "assignFollows") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar ":"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "=")))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "anyList" false) (mem "splitNl" false) (mem "joinWith" false) (mem "startsWith" false) (mem "isSome" false))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false))))
(DUse false (UseGroup ("regex") ((mem "Regex" false) (mem "Match" false) (mem "mustCompile" false) (mem "isMatch" false) (mem "find" false "reFind") (mem "findAll" false "reFindAll") (mem "replaceAll" false) (mem "escape" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factComments" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "CommentBlock" true) (mem "codeLineAt" false) (mem "codePortions" false) (mem "commentBlocks" false) (mem "ruleNamePromissoryReader" false) (mem "trimWs" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePromissoryReader")) (fa "summary" (ELit (LString "comment claims a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") but the file reads it (#2550)"))) (fa "doc" (ELit (LString "A comment claiming a symbol has no reader yet (\"nothing reads this yet\", \"no reader yet\", \"do not add a reader\") while the file reads it is stale and misleads the next editor (#2550). This enforces the repository comment register.\n\nBefore:\n  -- nothing reads this yet\n  cache = ...   -- read two screens down\nAfter:\n  delete or correct the comment"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "rulePromissoryReader")) (EVar "None")))
(DTypeSig false "rulePromissoryReader" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "rulePromissoryReader" (PWild (PVar "path") (PVar "facts") PWild PWild) (EBlock (DoLet false false (PVar "ls") (EApp (EVar "splitNl") (EFieldAccess (EVar "facts") "ffSrc"))) (DoLet false false (PVar "comments") (EApp (EVar "factComments") (EVar "facts"))) (DoLet false false (PVar "codeLines") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "codePortions") (EVar "ls")) (EVar "comments")) (ELit (LInt 1))))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "promissoryFinding") (EVar "path")) (EVar "codeLines"))) (EApp (EVar "promissoryClaims") (EApp (EApp (EVar "commentBlocks") (EVar "comments")) (EVar "codeLines")))))))
(DTypeSig false "promissoryClaims" (TyFun (TyApp (TyCon "List") (TyCon "CommentBlock")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String") (TyCon "CommentBlock")))))
(DFunDef false "promissoryClaims" ((PVar "blocks")) (EApp (EApp (EDictApp "flatMap") (EVar "promissoryClaimOf")) (EVar "blocks")))
(DTypeSig false "promissoryClaimOf" (TyFun (TyCon "CommentBlock") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String") (TyCon "CommentBlock")))))
(DFunDef false "promissoryClaimOf" ((PAs "b" (PCon "CommentBlock" (PVar "first") PWild PWild (PVar "text")))) (EIf (EApp (EVar "not") (EApp (EVar "mayBePromissory") (EApp (EVar "stringToLower") (EVar "text")))) (EListLit) (EBlock (DoLet false false (PVar "lines") (EApp (EVar "splitNl") (EVar "text"))) (DoExpr (EMatch (EApp (EApp (EVar "promissoryLine") (EVar "lines")) (ELit (LInt 0))) (arm (PCon "Some" (PTuple (PVar "i") (PVar "l"))) () (EListLit (ETuple (EBinOp "+" (EVar "first") (EVar "i")) (EVar "l") (EVar "b")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "joined") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "lines"))) (DoExpr (EIf (EApp (EVar "isPromissoryText") (EApp (EVar "stringToLower") (EApp (EVar "stripQuoted") (EVar "joined")))) (EListLit (ETuple (EVar "first") (EVar "joined") (EVar "b"))) (EListLit))))))))))
(DTypeSig false "mayBePromissory" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "mayBePromissory" ((PVar "low")) (EBinOp "||" (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (ELit (LString "yet"))) (EVar "low"))) (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (ELit (LString "reader"))) (EVar "low")))))
(DTypeSig false "promissoryLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "String"))))))
(DFunDef false "promissoryLine" ((PList) PWild) (EVar "None"))
(DFunDef false "promissoryLine" ((PCons (PVar "l") (PVar "rest")) (PVar "i")) (EIf (EBinOp "&&" (EApp (EVar "mayBePromissory") (EApp (EVar "stringToLower") (EVar "l"))) (EApp (EVar "isPromissoryText") (EApp (EVar "stringToLower") (EApp (EVar "stripQuoted") (EVar "l"))))) (EApp (EVar "Some") (ETuple (EVar "i") (EVar "l"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "promissoryLine") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nothingReadsRe" (TyCon "Regex"))
(DFunDef false "nothingReadsRe" () (EApp (EVar "mustCompile") (EApp (EVar "escape") (ELit (LString "nothing reads")))))
(DTypeSig false "yetRe" (TyCon "Regex"))
(DFunDef false "yetRe" () (EApp (EVar "mustCompile") (EApp (EVar "escape") (ELit (LString "yet")))))
(DTypeSig false "promissoryPhraseRe" (TyCon "Regex"))
(DFunDef false "promissoryPhraseRe" () (EApp (EVar "mustCompile") (EApp (EApp (EVar "joinWith") (ELit (LString "|"))) (EApp (EApp (EMethodRef "map") (EVar "escape")) (EListLit (ELit (LString "no reader yet")) (ELit (LString "no readers yet")) (ELit (LString "no consumer yet")) (ELit (LString "no consumers yet")) (ELit (LString "do not add a reader")) (ELit (LString "don't add a reader")))))))
(DTypeSig false "isPromissoryText" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isPromissoryText" ((PVar "t")) (EBinOp "||" (EBinOp "&&" (EApp (EApp (EVar "isMatch") (EVar "nothingReadsRe")) (EVar "t")) (EApp (EApp (EVar "isMatch") (EVar "yetRe")) (EVar "t"))) (EApp (EApp (EVar "isMatch") (EVar "promissoryPhraseRe")) (EVar "t"))))
(DTypeSig false "quoteCharRe" (TyCon "Regex"))
(DFunDef false "quoteCharRe" () (EApp (EVar "mustCompile") (ELit (LString "\""))))
(DTypeSig false "pairedQuoteRe" (TyCon "Regex"))
(DFunDef false "pairedQuoteRe" () (EApp (EVar "mustCompile") (ELit (LString "\"[^\"]*\""))))
(DTypeSig false "stripQuoted" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripQuoted" ((PVar "s")) (EBlock (DoLet false false (PVar "quotes") (EApp (EApp (EVar "reFindAll") (EVar "quoteCharRe")) (EVar "s"))) (DoLet false false (PVar "truncated") (EIf (EBinOp "==" (EBinOp "%" (EApp (EVar "listLen") (EVar "quotes")) (ELit (LInt 2))) (ELit (LInt 1))) (EMatch (EApp (EVar "last") (EVar "quotes")) (arm (PCon "Some" (PVar "m")) () (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EFieldAccess (EVar "m") "start")) (EVar "s"))) (arm (PCon "None") () (EVar "s"))) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "replaceAll") (EVar "pairedQuoteRe")) (ELit (LString " "))) (EVar "truncated")))))
(DTypeSig false "claimSubject" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyTuple (TyCon "Int") (TyCon "String") (TyCon "CommentBlock")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "claimSubject" ((PVar "codeLines") (PTuple (PVar "line") (PVar "text") (PCon "CommentBlock" PWild (PVar "last") (PVar "trailing") PWild))) (EMatch (EApp (EVar "backtickedAfterReads") (EVar "text")) (arm (PCon "Some" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "None") () (EIf (EVar "trailing") (EApp (EVar "declaredNameOf") (EApp (EApp (EVar "codeLineAt") (EVar "codeLines")) (EVar "line"))) (EApp (EApp (EVar "nextDeclaredName") (EVar "codeLines")) (EBinOp "+" (EVar "last") (ELit (LInt 1))))))))
(DTypeSig false "backtickedAfterReads" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "backtickedAfterReads" ((PVar "t")) (EBlock (DoLet false false (PVar "lower") (EApp (EVar "stringToLower") (EVar "t"))) (DoExpr (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "reads `"))) (EVar "lower")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "start") (EBinOp "+" (EVar "i") (EApp (EVar "stringLength") (ELit (LString "reads `"))))) (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EApp (EVar "stringLength") (EVar "t"))) (EVar "t"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "j")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "j")) (EVar "rest")))) (EApp (EApp (EVar "stringIndexOf") (ELit (LString "`"))) (EVar "rest"))))))))))
(DTypeSig false "nextDeclaredName" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "nextDeclaredName" ((PVar "codeLines") (PVar "line")) (EIf (EBinOp ">" (EVar "line") (EApp (EVar "arrayLength") (EVar "codeLines"))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "t") (EApp (EVar "trimWs") (EApp (EApp (EVar "codeLineAt") (EVar "codeLines")) (EVar "line")))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "t") (ELit (LString "export"))) (EBinOp "==" (EVar "t") (ELit (LString "public export")))) (EApp (EApp (EVar "nextDeclaredName") (EVar "codeLines")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EApp (EVar "declaredNameOf") (EVar "t"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declaredNameOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declaredNameOf" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "trimWs") (EVar "c"))) (DoLet false false (PVar "t1") (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "public"))) (EVar "t"))) (DoLet false false (PVar "t2") (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "export"))) (EVar "t1"))) (DoLet false false (PVar "t3") (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "data"))) (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "type"))) (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "interface"))) (EVar "t2"))))) (DoLet false false (PVar "w") (EApp (EVar "leadingIdent") (EVar "t3"))) (DoExpr (EIf (EBinOp "==" (EVar "w") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "w"))))))
(DTypeSig false "dropPrefixWord" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "dropPrefixWord" ((PVar "w") (PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (EBinOp "++" (EVar "w") (ELit (LString " ")))) (EVar "s")) (EApp (EVar "trimWs") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "w"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "leadingIdentRe" (TyCon "Regex"))
(DFunDef false "leadingIdentRe" () (EApp (EVar "mustCompile") (ELit (LString "^[A-Za-z0-9_']+"))))
(DTypeSig false "leadingIdent" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "leadingIdent" ((PVar "s")) (EMatch (EApp (EApp (EVar "reFind") (EVar "leadingIdentRe")) (EVar "s")) (arm (PCon "Some" (PVar "m")) () (EFieldAccess (EVar "m") "text")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "isIdentChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isIdentChar" ((PVar "ch")) (EBinOp "||" (EBinOp "||" (EApp (EVar "isAlnum") (EVar "ch")) (EBinOp "==" (EVar "ch") (ELit (LChar "_")))) (EBinOp "==" (EVar "ch") (ELit (LChar "'")))))
(DTypeSig false "promissoryFinding" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyTuple (TyCon "Int") (TyCon "String") (TyCon "CommentBlock")) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "promissoryFinding" ((PVar "path") (PVar "codeLines") (PVar "claim")) (EMatch (EApp (EApp (EVar "claimSubject") (EVar "codeLines")) (EVar "claim")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "subject")) () (EIf (EApp (EApp (EVar "declaredInFile") (EVar "subject")) (EVar "codeLines")) (EApp (EApp (EApp (EApp (EVar "readerFinding") (EVar "path")) (EVar "subject")) (EVar "claim")) (EApp (EApp (EVar "readerLines") (EVar "subject")) (EVar "codeLines"))) (EListLit)))))
(DTypeSig false "readerFinding" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Int") (TyCon "String") (TyCon "CommentBlock")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "readerFinding" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "readerFinding" ((PVar "path") (PVar "subject") (PTuple (PVar "line") PWild PWild) (PCons (PVar "firstReader") (PVar "more"))) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePromissoryReader")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "comment claims nothing reads `")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString "` yet, but it is read on line "))) (EApp (EMethodRef "display") (EVar "firstReader"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "readerCountSuffix") (EApp (EVar "listLen") (EVar "more"))))) (ELit (LString ". Restate the claim as what is measured today, or delete it")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "line")) (ELit (LInt 1))) (EVar "line")) (ELit (LInt 1))))) (fa "fix" (EVar "None"))))))
(DTypeSig false "declaredInFile" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "declaredInFile" ((PVar "subject") (PVar "codeLines")) (EApp (EApp (EApp (EApp (EVar "declaredInFileGo") (EVar "subject")) (EVar "codeLines")) (EApp (EVar "arrayLength") (EVar "codeLines"))) (ELit (LInt 1))))
(DTypeSig false "declaredInFileGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "declaredInFileGo" ((PVar "subject") (PVar "codeLines") (PVar "n") (PVar "line")) (EIf (EBinOp ">" (EVar "line") (EVar "n")) (EVar "False") (EIf (EApp (EApp (EVar "isDefinitionLine") (EVar "subject")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EVar "codeLines"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "declaredInFileGo") (EVar "subject")) (EVar "codeLines")) (EVar "n")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "readerCountSuffix" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "readerCountSuffix" ((PLit (LInt 0))) (ELit (LString "")))
(DFunDef false "readerCountSuffix" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString " and ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " more line(s)"))))
(DTypeSig false "readerLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "readerLines" ((PVar "subject") (PVar "codeLines")) (EApp (EApp (EApp (EApp (EVar "readerLinesGo") (EVar "subject")) (EVar "codeLines")) (EApp (EVar "arrayLength") (EVar "codeLines"))) (ELit (LInt 1))))
(DTypeSig false "readerLinesGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "readerLinesGo" ((PVar "subject") (PVar "codeLines") (PVar "n") (PVar "line")) (EIf (EBinOp ">" (EVar "line") (EVar "n")) (EListLit) (EIf (EApp (EApp (EVar "isReaderLine") (EVar "subject")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "line") (ELit (LInt 1)))) (EVar "codeLines"))) (EBinOp "::" (EVar "line") (EApp (EApp (EApp (EApp (EVar "readerLinesGo") (EVar "subject")) (EVar "codeLines")) (EVar "n")) (EBinOp "+" (EVar "line") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "readerLinesGo") (EVar "subject")) (EVar "codeLines")) (EVar "n")) (EBinOp "+" (EVar "line") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isReaderLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isReaderLine" ((PVar "subject") (PVar "c")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "isDefinitionLine") (EVar "subject")) (EVar "c"))) (EApp (EApp (EVar "wordReadIn") (EVar "subject")) (EVar "c"))))
(DTypeSig false "isDefinitionLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isDefinitionLine" ((PVar "subject") (PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "export"))) (EApp (EApp (EVar "dropPrefixWord") (ELit (LString "public"))) (EApp (EVar "trimWs") (EVar "c"))))) (DoLet false false (PVar "after") (EApp (EVar "trimWs") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "subject"))) (EApp (EVar "stringLength") (EVar "t"))) (EVar "t")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EVar "subject")) (EVar "t")) (EApp (EApp (EVar "identBoundaryAt") (EApp (EVar "stringToChars") (EVar "t"))) (EApp (EVar "stringLength") (EVar "subject")))) (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EBinOp "||" (EApp (EApp (EVar "startsWith") (ELit (LString " "))) (EVar "c")) (EApp (EApp (EVar "startsWith") (ELit (LString "\t"))) (EVar "c")))) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString ":"))) (EVar "after")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString ":="))) (EVar "after"))))) (EBinOp "&&" (EApp (EApp (EVar "startsWith") (ELit (LString "="))) (EVar "after")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "=="))) (EVar "after")))))))))
(DTypeSig false "identBoundaryAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "identBoundaryAt" ((PVar "cs") (PVar "i")) (EBinOp "||" (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))))
(DTypeSig false "wordReadIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "wordReadIn" ((PVar "w") (PVar "line")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "line"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EApp (EApp (EVar "anyList") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "wordReadOk") (EVar "cs")) (EVar "n")) (EVar "m")))) (EApp (EApp (EVar "reFindAll") (EApp (EVar "mustCompile") (EApp (EVar "escape") (EVar "w")))) (EVar "line"))))))
(DTypeSig false "wordReadOk" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Match") (TyCon "Bool")))))
(DFunDef false "wordReadOk" ((PVar "cs") (PVar "n") (PVar "m")) (EBinOp "&&" (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "m") "start") (ELit (LInt 0))) (EApp (EVar "not") (EApp (EVar "isIdentChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EFieldAccess (EVar "m") "start") (ELit (LInt 1)))) (EVar "cs"))))) (EApp (EApp (EVar "identBoundaryAt") (EVar "cs")) (EFieldAccess (EVar "m") "end"))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "assignFollows") (EVar "cs")) (EVar "n")) (EFieldAccess (EVar "m") "end")))))
(DTypeSig false "assignFollows" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "assignFollows" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EVar "n")) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar " ")))) (EApp (EApp (EApp (EVar "assignFollows") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar ":"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "=")))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
