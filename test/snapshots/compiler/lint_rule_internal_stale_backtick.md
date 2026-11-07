# META
source_lines=249
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-comment-stale-backtick: a backticked identifier in a comment names nothing the project or the stdlib declares (#4319).

import frontend.ast.{Loc(..), Decl(..)}
import driver.diagnostics.{Severity(..)}
import frontend.lexer.{Comment, Token(..), commentLine, commentText, tokenize}
import frontend.parser.{Positions(..)}
import support.util.{anyList, filterList, splitNl, listLen, isEmptyL}
import support.char.{isAlnum, isLower, isDigit}
import string.{split, startsWith, contains}
import hash_set.{HashSet, new, fromList, has, insertInPlace}
import list.{mapWithIndex, drop}
import tools.lint_core.{
  Category(..),
  FileFacts,
  Finding(..),
  Fixability(..),
  Need(..),
  ProseComments(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  factCodeLines,
  factProseComments,
  mkRule,
  noFix,
  projectIndexOf,
  Memo,
  memoNew,
  memoGet,
}
import tools.lint_index.{ProjectIndex, Ns(..), rowsNamed, indexKnowsWord}
import tools.lint_shared.{ruleNameCommentStaleBacktick}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameCommentStaleBacktick,
      summary =
        "a backticked identifier in a comment names nothing the project or the stdlib declares, and occurs in no code line of the file (#4319)",
      doc =
        "A comment that names a function or value in backticks goes stale when the name is renamed or deleted, and no other gate notices. The rule reads each backticked lowercase identifier in a prose comment and accepts it when it is a declaration in the project or stdlib index, a record field or a module-name segment there, a Medaka keyword, or a whole word on some code line of the same file. A name spelled like no Medaka declaration is skipped: three characters or fewer, a mangled `__` name, a C-runtime, C-library or gate-name prefix, a hex hash, or a word of SQL, LLVM IR, WebAssembly, C or the shell. Anything else names a thing that is gone, or a local of another file: point the comment at the live top-level name, restate the constraint without it, or delete the comment.\n\nBefore:\n  -- see `oldHelper` for the cache key\nAfter:\n  -- see `cacheKey` for the cache key",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [NeedsProjectIndex],
    }
    ruleStaleBacktick
    None

ruleStaleBacktick : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleStaleBacktick idx _ facts _ _ =
  let prose = factProseComments facts
  let ix = projectIndexOf idx
  let code = memoNew (_ => codeWords (factCodeLines facts) prose.proseBlocks)
  flatMap (commentFindings ix code) (prose.proseBlocks ++ prose.proseLines)

-- Every whole word on the file's code lines, built for the first name the index
-- does not resolve.  The lines a block comment continues onto are skipped:
-- `factCodeLines` keeps them whole, as if they were code.  Only a word that
-- could be asked about is kept: four characters or more, starting lowercase.
codeWords : Array String -> List Comment -> HashSet String
codeWords lines blocks = go 0
  where
    inBlock = fromList (flatMap continuationLines blocks)
    words = new ()
    go i
      | i >= arrayLength lines = words
      | has i inBlock = go (i + 1)
      | otherwise =
        lineWordsInto (arrayGetUnsafe i lines) words
        go (i + 1)

-- A word is a maximal run of identifier characters (`isAlnum` counts `_` and
-- the apostrophe).
lineWordsInto : String -> HashSet String -> Unit
lineWordsInto line words = go 0
  where
    cs = stringToChars line
    n = arrayLength cs
    go i
      | i >= n = ()
      | isAlnum (arrayGetUnsafe i cs) = keep i (wordEnd (i + 1))
      | otherwise = go (i + 1)
    wordEnd j =
      if j < n && isAlnum (arrayGetUnsafe j cs) then wordEnd (j + 1) else j
    keep start end =
      if end - start > 3 && isLower (arrayGetUnsafe start cs) then
        insertInPlace (stringSlice start end line) words
      go end

continuationLines : Comment -> List Int
continuationLines c =
  let first = commentLine c
  [first..first + listLen (splitNl (commentText c)) - 1]

commentFindings : ProjectIndex ->
  Memo (HashSet String) ->
  Comment ->
  List Finding
commentFindings ix code c =
  if contains "`" (commentText c) then
    flatMap
      ((i, l) => lineFindings ix code (commentLine c + i) l)
      (mapWithIndex (i l => (i, l)) (splitNl (commentText c)))
  else
    []

lineFindings : ProjectIndex ->
  Memo (HashSet String) ->
  Int ->
  String ->
  List Finding
lineFindings ix code line text =
  map (stale line) (filterList (name => isStale ix code name) (candidates text))

stale : Int -> String -> Finding
stale line name = Finding {
  rule = ruleNameCommentStaleBacktick,
  message =
    "`\{name}` in this comment names nothing declared in the project or the stdlib",
  severity = SevWarning,
  loc = Some (Loc "" line 1 line 1),
  fix = noFix,
}

-- The backticked identifiers of one comment line.  A line with an odd number of
-- backticks pairs them unreliably (a span wrapped from the line above), so it
-- yields none.
candidates : String -> List String
candidates text = if contains "`" text then backticked (split "`" text) else []

backticked : List String -> List String
backticked parts =
  if isEven (listLen parts) then
    []
  else
    filterList isIdentifier (everyOther (drop 1 parts))

everyOther : List a -> List a
everyOther [] = []
everyOther [x] = [x]
everyOther (x :: _ :: rest) = x :: everyOther rest

isIdentifier : String -> Bool
isIdentifier s =
  let cs = stringToChars s
  arrayLength cs > 0 && isLower (arrayGetUnsafe 0 cs) && all isAlnum cs

isStale : ProjectIndex -> Memo (HashSet String) -> String -> Bool
isStale ix code name =
  not (foreignShape name)
    && isEmptyL (rowsNamed ix NsValue name)
    && isEmptyL (rowsNamed ix NsType name)
    && not (indexKnowsWord ix name)
    && not (isKeyword name)
    && not (has name (memoGet code))

-- Names that are not Medaka declarations by their spelling: a placeholder of
-- at most three characters (`x`, `acc`), a mangled name (`core__map`), a
-- symbol of the C runtime or a C library (`mdk_alloc`), a gate name
-- (`diff_compiler_fmt`), a hash in hex with a digit in it (`eb92cdff`), or a
-- word of SQL, of the LLVM or WebAssembly text formats, of C or of the shell.
foreignShape : String -> Bool
foreignShape name =
  stringLength name <= 3
    || contains "__" name
    || anyList (p => startsWith p name) foreignPrefixes
    || isHexHash name
    || has name foreignWords

foreignPrefixes : List String
foreignPrefixes = ["mdk_", "secp256k1_", "diff_compiler_"]

isHexHash : String -> Bool
isHexHash name =
  let cs = stringToChars name
  all (c => isDigit c || c >= 'a' && c <= 'f') cs && any isDigit cs

foreignWords : HashSet String
foreignWords = fromList [
  "sqlite3",
  "sqlite_master",
  "rootpage",
  "integrity_check",
  "substr",
  "ltrim",
  "rtrim",
  "null",
  "true",
  "false",
  "case",
  "enum",
  "musttail",
  "icmp",
  "fcmp",
  "fneg",
  "frem",
  "getelementptr",
  "ptrtoint",
  "noreturn",
  "unreachable",
  "declare",
  "define",
  "external",
  "void",
  "return_call",
  "br_table",
  "i31ref",
  "divsd",
  "fmod",
  "getenv",
  "exec",
  "execvp",
  "libsecp256k1",
  "clang",
  "python3",
  "bash",
  "make",
  "mkdir",
  "echo",
  "grep",
  "sed",
  "awk",
  "xargs",
  "curl",
  "valgrind",
  "gunzip",
  "timeout",
  "perl",
]

-- Whether `name` lexes as a reserved word rather than an identifier.
isKeyword : String -> Bool
isKeyword name = not (anyList isIdentToken (tokenize name))

isIdentToken : Token -> Bool
isIdentToken (TIdent _) = True
isIdentToken _ = False
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "Token" true) (mem "commentLine" false) (mem "commentText" false) (mem "tokenize" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "filterList" false) (mem "splitNl" false) (mem "listLen" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false) (mem "isLower" false) (mem "isDigit" false))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "startsWith" false) (mem "contains" false))))
(DUse false (UseGroup ("hash_set") ((mem "HashSet" false) (mem "new" false) (mem "fromList" false) (mem "has" false) (mem "insertInPlace" false))))
(DUse false (UseGroup ("list") ((mem "mapWithIndex" false) (mem "drop" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "ProseComments" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factCodeLines" false) (mem "factProseComments" false) (mem "mkRule" false) (mem "noFix" false) (mem "projectIndexOf" false) (mem "Memo" false) (mem "memoNew" false) (mem "memoGet" false))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "ProjectIndex" false) (mem "Ns" true) (mem "rowsNamed" false) (mem "indexKnowsWord" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameCommentStaleBacktick" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameCommentStaleBacktick")) (fa "summary" (ELit (LString "a backticked identifier in a comment names nothing the project or the stdlib declares, and occurs in no code line of the file (#4319)"))) (fa "doc" (ELit (LString "A comment that names a function or value in backticks goes stale when the name is renamed or deleted, and no other gate notices. The rule reads each backticked lowercase identifier in a prose comment and accepts it when it is a declaration in the project or stdlib index, a record field or a module-name segment there, a Medaka keyword, or a whole word on some code line of the same file. A name spelled like no Medaka declaration is skipped: three characters or fewer, a mangled `__` name, a C-runtime, C-library or gate-name prefix, a hex hash, or a word of SQL, LLVM IR, WebAssembly, C or the shell. Anything else names a thing that is gone, or a local of another file: point the comment at the live top-level name, restate the constraint without it, or delete the comment.\n\nBefore:\n  -- see `oldHelper` for the cache key\nAfter:\n  -- see `cacheKey` for the cache key"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsProjectIndex")))))) (EVar "ruleStaleBacktick")) (EVar "None")))
(DTypeSig false "ruleStaleBacktick" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleStaleBacktick" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EBlock (DoLet false false (PVar "prose") (EApp (EVar "factProseComments") (EVar "facts"))) (DoLet false false (PVar "ix") (EApp (EVar "projectIndexOf") (EVar "idx"))) (DoLet false false (PVar "code") (EApp (EVar "memoNew") (ELam (PWild) (EApp (EApp (EVar "codeWords") (EApp (EVar "factCodeLines") (EVar "facts"))) (EFieldAccess (EVar "prose") "proseBlocks"))))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "commentFindings") (EVar "ix")) (EVar "code"))) (EBinOp "++" (EFieldAccess (EVar "prose") "proseBlocks") (EFieldAccess (EVar "prose") "proseLines"))))))
(DTypeSig false "codeWords" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "HashSet") (TyCon "String")))))
(DFunDef false "codeWords" ((PVar "lines") (PVar "blocks")) (ELetGroup ((lgb "inBlock" (clause () (EApp (EVar "fromList") (EApp (EApp (EVar "flatMap") (EVar "continuationLines")) (EVar "blocks"))))) (lgb "words" (clause () (EApp (EVar "new") (ELit LUnit)))) (lgb "go" (clause ((PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "lines"))) (EVar "words") (EIf (EApp (EApp (EVar "has") (EVar "i")) (EVar "inBlock")) (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EVar "lineWordsInto") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "lines"))) (EVar "words"))) (DoExpr (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))) (EApp (EVar "go") (ELit (LInt 0)))))
(DTypeSig false "lineWordsInto" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "HashSet") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "lineWordsInto" ((PVar "line") (PVar "words")) (ELetGroup ((lgb "cs" (clause () (EApp (EVar "stringToChars") (EVar "line")))) (lgb "n" (clause () (EApp (EVar "arrayLength") (EVar "cs")))) (lgb "go" (clause ((PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EApp (EVar "isAlnum") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "keep") (EVar "i")) (EApp (EVar "wordEnd") (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (lgb "wordEnd" (clause ((PVar "j")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "j") (EVar "n")) (EApp (EVar "isAlnum") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "cs")))) (EApp (EVar "wordEnd") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "j")))) (lgb "keep" (clause ((PVar "start") (PVar "end")) (EBlock (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EBinOp "-" (EVar "end") (EVar "start")) (ELit (LInt 3))) (EApp (EVar "isLower") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "start")) (EVar "cs")))) (EApp (EApp (EVar "insertInPlace") (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "end")) (EVar "line"))) (EVar "words")) (ELit LUnit))) (DoExpr (EApp (EVar "go") (EVar "end"))))))) (EApp (EVar "go") (ELit (LInt 0)))))
(DTypeSig false "continuationLines" (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "continuationLines" ((PVar "c")) (EBlock (DoLet false false (PVar "first") (EApp (EVar "commentLine") (EVar "c"))) (DoExpr (ERangeList (EVar "first") (EBinOp "-" (EBinOp "+" (EVar "first") (EApp (EVar "listLen") (EApp (EVar "splitNl") (EApp (EVar "commentText") (EVar "c"))))) (ELit (LInt 1))) false))))
(DTypeSig false "commentFindings" (TyFun (TyCon "ProjectIndex") (TyFun (TyApp (TyCon "Memo") (TyApp (TyCon "HashSet") (TyCon "String"))) (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "commentFindings" ((PVar "ix") (PVar "code") (PVar "c")) (EIf (EApp (EApp (EVar "contains") (ELit (LString "`"))) (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "i") (PVar "l"))) (EApp (EApp (EApp (EApp (EVar "lineFindings") (EVar "ix")) (EVar "code")) (EBinOp "+" (EApp (EVar "commentLine") (EVar "c")) (EVar "i"))) (EVar "l")))) (EApp (EApp (EVar "mapWithIndex") (ELam ((PVar "i") (PVar "l")) (ETuple (EVar "i") (EVar "l")))) (EApp (EVar "splitNl") (EApp (EVar "commentText") (EVar "c"))))) (EListLit)))
(DTypeSig false "lineFindings" (TyFun (TyCon "ProjectIndex") (TyFun (TyApp (TyCon "Memo") (TyApp (TyCon "HashSet") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "lineFindings" ((PVar "ix") (PVar "code") (PVar "line") (PVar "text")) (EApp (EApp (EVar "map") (EApp (EVar "stale") (EVar "line"))) (EApp (EApp (EVar "filterList") (ELam ((PVar "name")) (EApp (EApp (EApp (EVar "isStale") (EVar "ix")) (EVar "code")) (EVar "name")))) (EApp (EVar "candidates") (EVar "text")))))
(DTypeSig false "stale" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "stale" ((PVar "line") (PVar "name")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameCommentStaleBacktick")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "$core.display") (EVar "name"))) (ELit (LString "` in this comment names nothing declared in the project or the stdlib")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "line")) (ELit (LInt 1))) (EVar "line")) (ELit (LInt 1))))) (fa "fix" (EVar "noFix")))))
(DTypeSig false "candidates" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "candidates" ((PVar "text")) (EIf (EApp (EApp (EVar "contains") (ELit (LString "`"))) (EVar "text")) (EApp (EVar "backticked") (EApp (EApp (EVar "split") (ELit (LString "`"))) (EVar "text"))) (EListLit)))
(DTypeSig false "backticked" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "backticked" ((PVar "parts")) (EIf (EApp (EVar "isEven") (EApp (EVar "listLen") (EVar "parts"))) (EListLit) (EApp (EApp (EVar "filterList") (EVar "isIdentifier")) (EApp (EVar "everyOther") (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EVar "parts"))))))
(DTypeSig false "everyOther" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "everyOther" ((PList)) (EListLit))
(DFunDef false "everyOther" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "everyOther" ((PCons (PVar "x") (PCons PWild (PVar "rest")))) (EBinOp "::" (EVar "x") (EApp (EVar "everyOther") (EVar "rest"))))
(DTypeSig false "isIdentifier" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isIdentifier" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EApp (EVar "isLower") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")))) (EApp (EApp (EVar "all") (EVar "isAlnum")) (EVar "cs"))))))
(DTypeSig false "isStale" (TyFun (TyCon "ProjectIndex") (TyFun (TyApp (TyCon "Memo") (TyApp (TyCon "HashSet") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isStale" ((PVar "ix") (PVar "code") (PVar "name")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "foreignShape") (EVar "name"))) (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EVar "rowsNamed") (EVar "ix")) (EVar "NsValue")) (EVar "name")))) (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EVar "rowsNamed") (EVar "ix")) (EVar "NsType")) (EVar "name")))) (EApp (EVar "not") (EApp (EApp (EVar "indexKnowsWord") (EVar "ix")) (EVar "name")))) (EApp (EVar "not") (EApp (EVar "isKeyword") (EVar "name")))) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "name")) (EApp (EVar "memoGet") (EVar "code"))))))
(DTypeSig false "foreignShape" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "foreignShape" ((PVar "name")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "<=" (EApp (EVar "stringLength") (EVar "name")) (ELit (LInt 3))) (EApp (EApp (EVar "contains") (ELit (LString "__"))) (EVar "name"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EApp (EApp (EVar "startsWith") (EVar "p")) (EVar "name")))) (EVar "foreignPrefixes"))) (EApp (EVar "isHexHash") (EVar "name"))) (EApp (EApp (EVar "has") (EVar "name")) (EVar "foreignWords"))))
(DTypeSig false "foreignPrefixes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "foreignPrefixes" () (EListLit (ELit (LString "mdk_")) (ELit (LString "secp256k1_")) (ELit (LString "diff_compiler_"))))
(DTypeSig false "isHexHash" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHexHash" ((PVar "name")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "name"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "all") (ELam ((PVar "c")) (EBinOp "||" (EApp (EVar "isDigit") (EVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "f"))))))) (EVar "cs")) (EApp (EApp (EVar "any") (EVar "isDigit")) (EVar "cs"))))))
(DTypeSig false "foreignWords" (TyApp (TyCon "HashSet") (TyCon "String")))
(DFunDef false "foreignWords" () (EApp (EVar "fromList") (EListLit (ELit (LString "sqlite3")) (ELit (LString "sqlite_master")) (ELit (LString "rootpage")) (ELit (LString "integrity_check")) (ELit (LString "substr")) (ELit (LString "ltrim")) (ELit (LString "rtrim")) (ELit (LString "null")) (ELit (LString "true")) (ELit (LString "false")) (ELit (LString "case")) (ELit (LString "enum")) (ELit (LString "musttail")) (ELit (LString "icmp")) (ELit (LString "fcmp")) (ELit (LString "fneg")) (ELit (LString "frem")) (ELit (LString "getelementptr")) (ELit (LString "ptrtoint")) (ELit (LString "noreturn")) (ELit (LString "unreachable")) (ELit (LString "declare")) (ELit (LString "define")) (ELit (LString "external")) (ELit (LString "void")) (ELit (LString "return_call")) (ELit (LString "br_table")) (ELit (LString "i31ref")) (ELit (LString "divsd")) (ELit (LString "fmod")) (ELit (LString "getenv")) (ELit (LString "exec")) (ELit (LString "execvp")) (ELit (LString "libsecp256k1")) (ELit (LString "clang")) (ELit (LString "python3")) (ELit (LString "bash")) (ELit (LString "make")) (ELit (LString "mkdir")) (ELit (LString "echo")) (ELit (LString "grep")) (ELit (LString "sed")) (ELit (LString "awk")) (ELit (LString "xargs")) (ELit (LString "curl")) (ELit (LString "valgrind")) (ELit (LString "gunzip")) (ELit (LString "timeout")) (ELit (LString "perl")))))
(DTypeSig false "isKeyword" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isKeyword" ((PVar "name")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EVar "isIdentToken")) (EApp (EVar "tokenize") (EVar "name")))))
(DTypeSig false "isIdentToken" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isIdentToken" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "isIdentToken" (PWild) (EVar "False"))
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "Token" true) (mem "commentLine" false) (mem "commentText" false) (mem "tokenize" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "filterList" false) (mem "splitNl" false) (mem "listLen" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false) (mem "isLower" false) (mem "isDigit" false))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "startsWith" false) (mem "contains" false))))
(DUse false (UseGroup ("hash_set") ((mem "HashSet" false) (mem "new" false) (mem "fromList" false) (mem "has" false) (mem "insertInPlace" false))))
(DUse false (UseGroup ("list") ((mem "mapWithIndex" false) (mem "drop" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "ProseComments" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factCodeLines" false) (mem "factProseComments" false) (mem "mkRule" false) (mem "noFix" false) (mem "projectIndexOf" false) (mem "Memo" false) (mem "memoNew" false) (mem "memoGet" false))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "ProjectIndex" false) (mem "Ns" true) (mem "rowsNamed" false) (mem "indexKnowsWord" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameCommentStaleBacktick" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameCommentStaleBacktick")) (fa "summary" (ELit (LString "a backticked identifier in a comment names nothing the project or the stdlib declares, and occurs in no code line of the file (#4319)"))) (fa "doc" (ELit (LString "A comment that names a function or value in backticks goes stale when the name is renamed or deleted, and no other gate notices. The rule reads each backticked lowercase identifier in a prose comment and accepts it when it is a declaration in the project or stdlib index, a record field or a module-name segment there, a Medaka keyword, or a whole word on some code line of the same file. A name spelled like no Medaka declaration is skipped: three characters or fewer, a mangled `__` name, a C-runtime, C-library or gate-name prefix, a hex hash, or a word of SQL, LLVM IR, WebAssembly, C or the shell. Anything else names a thing that is gone, or a local of another file: point the comment at the live top-level name, restate the constraint without it, or delete the comment.\n\nBefore:\n  -- see `oldHelper` for the cache key\nAfter:\n  -- see `cacheKey` for the cache key"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsProjectIndex")))))) (EVar "ruleStaleBacktick")) (EVar "None")))
(DTypeSig false "ruleStaleBacktick" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleStaleBacktick" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EBlock (DoLet false false (PVar "prose") (EApp (EVar "factProseComments") (EVar "facts"))) (DoLet false false (PVar "ix") (EApp (EVar "projectIndexOf") (EVar "idx"))) (DoLet false false (PVar "code") (EApp (EVar "memoNew") (ELam (PWild) (EApp (EApp (EVar "codeWords") (EApp (EVar "factCodeLines") (EVar "facts"))) (EFieldAccess (EVar "prose") "proseBlocks"))))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "commentFindings") (EVar "ix")) (EVar "code"))) (EBinOp "++" (EFieldAccess (EVar "prose") "proseBlocks") (EFieldAccess (EVar "prose") "proseLines"))))))
(DTypeSig false "codeWords" (TyFun (TyApp (TyCon "Array") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "HashSet") (TyCon "String")))))
(DFunDef false "codeWords" ((PVar "lines") (PVar "blocks")) (ELetGroup ((lgb "inBlock" (clause () (EApp (EVar "fromList") (EApp (EApp (EDictApp "flatMap") (EVar "continuationLines")) (EVar "blocks"))))) (lgb "words" (clause () (EApp (EVar "new") (ELit LUnit)))) (lgb "go" (clause ((PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "lines"))) (EVar "words") (EIf (EApp (EApp (EVar "has") (EVar "i")) (EVar "inBlock")) (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EVar "lineWordsInto") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "lines"))) (EVar "words"))) (DoExpr (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))) (EApp (EVar "go") (ELit (LInt 0)))))
(DTypeSig false "lineWordsInto" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "HashSet") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "lineWordsInto" ((PVar "line") (PVar "words")) (ELetGroup ((lgb "cs" (clause () (EApp (EVar "stringToChars") (EVar "line")))) (lgb "n" (clause () (EApp (EVar "arrayLength") (EVar "cs")))) (lgb "go" (clause ((PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EApp (EVar "isAlnum") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "keep") (EVar "i")) (EApp (EVar "wordEnd") (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (lgb "wordEnd" (clause ((PVar "j")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "j") (EVar "n")) (EApp (EVar "isAlnum") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "cs")))) (EApp (EVar "wordEnd") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EVar "j")))) (lgb "keep" (clause ((PVar "start") (PVar "end")) (EBlock (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EBinOp "-" (EVar "end") (EVar "start")) (ELit (LInt 3))) (EApp (EVar "isLower") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "start")) (EVar "cs")))) (EApp (EApp (EVar "insertInPlace") (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "end")) (EVar "line"))) (EVar "words")) (ELit LUnit))) (DoExpr (EApp (EVar "go") (EVar "end"))))))) (EApp (EVar "go") (ELit (LInt 0)))))
(DTypeSig false "continuationLines" (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "continuationLines" ((PVar "c")) (EBlock (DoLet false false (PVar "first") (EApp (EVar "commentLine") (EVar "c"))) (DoExpr (ERangeList (EVar "first") (EBinOp "-" (EBinOp "+" (EVar "first") (EApp (EVar "listLen") (EApp (EVar "splitNl") (EApp (EVar "commentText") (EVar "c"))))) (ELit (LInt 1))) false))))
(DTypeSig false "commentFindings" (TyFun (TyCon "ProjectIndex") (TyFun (TyApp (TyCon "Memo") (TyApp (TyCon "HashSet") (TyCon "String"))) (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "commentFindings" ((PVar "ix") (PVar "code") (PVar "c")) (EIf (EApp (EApp (EVar "contains") (ELit (LString "`"))) (EApp (EVar "commentText") (EVar "c"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "i") (PVar "l"))) (EApp (EApp (EApp (EApp (EVar "lineFindings") (EVar "ix")) (EVar "code")) (EBinOp "+" (EApp (EVar "commentLine") (EVar "c")) (EVar "i"))) (EVar "l")))) (EApp (EApp (EVar "mapWithIndex") (ELam ((PVar "i") (PVar "l")) (ETuple (EVar "i") (EVar "l")))) (EApp (EVar "splitNl") (EApp (EVar "commentText") (EVar "c"))))) (EListLit)))
(DTypeSig false "lineFindings" (TyFun (TyCon "ProjectIndex") (TyFun (TyApp (TyCon "Memo") (TyApp (TyCon "HashSet") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "lineFindings" ((PVar "ix") (PVar "code") (PVar "line") (PVar "text")) (EApp (EApp (EMethodRef "map") (EApp (EVar "stale") (EVar "line"))) (EApp (EApp (EVar "filterList") (ELam ((PVar "name")) (EApp (EApp (EApp (EVar "isStale") (EVar "ix")) (EVar "code")) (EVar "name")))) (EApp (EVar "candidates") (EVar "text")))))
(DTypeSig false "stale" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "stale" ((PVar "line") (PVar "name")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameCommentStaleBacktick")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "$core.display") (EVar "name"))) (ELit (LString "` in this comment names nothing declared in the project or the stdlib")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "line")) (ELit (LInt 1))) (EVar "line")) (ELit (LInt 1))))) (fa "fix" (EVar "noFix")))))
(DTypeSig false "candidates" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "candidates" ((PVar "text")) (EIf (EApp (EApp (EVar "contains") (ELit (LString "`"))) (EVar "text")) (EApp (EVar "backticked") (EApp (EApp (EVar "split") (ELit (LString "`"))) (EVar "text"))) (EListLit)))
(DTypeSig false "backticked" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "backticked" ((PVar "parts")) (EIf (EApp (EVar "isEven") (EApp (EVar "listLen") (EVar "parts"))) (EListLit) (EApp (EApp (EVar "filterList") (EVar "isIdentifier")) (EApp (EVar "everyOther") (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EVar "parts"))))))
(DTypeSig false "everyOther" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "everyOther" ((PList)) (EListLit))
(DFunDef false "everyOther" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "everyOther" ((PCons (PVar "x") (PCons PWild (PVar "rest")))) (EBinOp "::" (EVar "x") (EApp (EVar "everyOther") (EVar "rest"))))
(DTypeSig false "isIdentifier" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isIdentifier" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EApp (EVar "isLower") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")))) (EApp (EApp (EDictApp "all") (EVar "isAlnum")) (EVar "cs"))))))
(DTypeSig false "isStale" (TyFun (TyCon "ProjectIndex") (TyFun (TyApp (TyCon "Memo") (TyApp (TyCon "HashSet") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isStale" ((PVar "ix") (PVar "code") (PVar "name")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "foreignShape") (EVar "name"))) (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EVar "rowsNamed") (EVar "ix")) (EVar "NsValue")) (EVar "name")))) (EApp (EVar "isEmptyL") (EApp (EApp (EApp (EVar "rowsNamed") (EVar "ix")) (EVar "NsType")) (EVar "name")))) (EApp (EVar "not") (EApp (EApp (EVar "indexKnowsWord") (EVar "ix")) (EVar "name")))) (EApp (EVar "not") (EApp (EVar "isKeyword") (EVar "name")))) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "name")) (EApp (EVar "memoGet") (EVar "code"))))))
(DTypeSig false "foreignShape" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "foreignShape" ((PVar "name")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "<=" (EApp (EVar "stringLength") (EVar "name")) (ELit (LInt 3))) (EApp (EApp (EVar "contains") (ELit (LString "__"))) (EVar "name"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EApp (EApp (EVar "startsWith") (EVar "p")) (EVar "name")))) (EVar "foreignPrefixes"))) (EApp (EVar "isHexHash") (EVar "name"))) (EApp (EApp (EVar "has") (EVar "name")) (EVar "foreignWords"))))
(DTypeSig false "foreignPrefixes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "foreignPrefixes" () (EListLit (ELit (LString "mdk_")) (ELit (LString "secp256k1_")) (ELit (LString "diff_compiler_"))))
(DTypeSig false "isHexHash" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHexHash" ((PVar "name")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "name"))) (DoExpr (EBinOp "&&" (EApp (EApp (EDictApp "all") (ELam ((PVar "c")) (EBinOp "||" (EApp (EVar "isDigit") (EVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "a"))) (EBinOp "<=" (EVar "c") (ELit (LChar "f"))))))) (EVar "cs")) (EApp (EApp (EDictApp "any") (EVar "isDigit")) (EVar "cs"))))))
(DTypeSig false "foreignWords" (TyApp (TyCon "HashSet") (TyCon "String")))
(DFunDef false "foreignWords" () (EApp (EVar "fromList") (EListLit (ELit (LString "sqlite3")) (ELit (LString "sqlite_master")) (ELit (LString "rootpage")) (ELit (LString "integrity_check")) (ELit (LString "substr")) (ELit (LString "ltrim")) (ELit (LString "rtrim")) (ELit (LString "null")) (ELit (LString "true")) (ELit (LString "false")) (ELit (LString "case")) (ELit (LString "enum")) (ELit (LString "musttail")) (ELit (LString "icmp")) (ELit (LString "fcmp")) (ELit (LString "fneg")) (ELit (LString "frem")) (ELit (LString "getelementptr")) (ELit (LString "ptrtoint")) (ELit (LString "noreturn")) (ELit (LString "unreachable")) (ELit (LString "declare")) (ELit (LString "define")) (ELit (LString "external")) (ELit (LString "void")) (ELit (LString "return_call")) (ELit (LString "br_table")) (ELit (LString "i31ref")) (ELit (LString "divsd")) (ELit (LString "fmod")) (ELit (LString "getenv")) (ELit (LString "exec")) (ELit (LString "execvp")) (ELit (LString "libsecp256k1")) (ELit (LString "clang")) (ELit (LString "python3")) (ELit (LString "bash")) (ELit (LString "make")) (ELit (LString "mkdir")) (ELit (LString "echo")) (ELit (LString "grep")) (ELit (LString "sed")) (ELit (LString "awk")) (ELit (LString "xargs")) (ELit (LString "curl")) (ELit (LString "valgrind")) (ELit (LString "gunzip")) (ELit (LString "timeout")) (ELit (LString "perl")))))
(DTypeSig false "isKeyword" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isKeyword" ((PVar "name")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EVar "isIdentToken")) (EApp (EVar "tokenize") (EVar "name")))))
(DTypeSig false "isIdentToken" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isIdentToken" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "isIdentToken" (PWild) (EVar "False"))
