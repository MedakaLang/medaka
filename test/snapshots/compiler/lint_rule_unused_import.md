# META
source_lines=158
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-unused-import: an `import m.{…}` member that nothing in the file uses. Drop the name from the list.

import frontend.ast.{Decl(..), Loc(..), UseMember(..), UsePath(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import frontend.lex_scan.{scanRaw}
import frontend.lex_token.{RawTok(..), Token(..)}
import frontend.lexer.{Comment, commentText}
import list.{drop, indexed}
import string.{lines, stripPrefix, trim}
import support.util.{joinWith}
import tools.lint_core.{
  Applicability(..),
  Category(..),
  FileFacts(..),
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
  factComments,
  factScopes,
  mkRule,
}
import tools.lint_fix.{removeListItem}
import tools.lint_scope.{Binder(..), FileScopes, binderOf, importUses}
import tools.lint_shared.{ruleNameUnusedImport}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameUnusedImport,
      summary = "an imported name that nothing in the file uses",
      doc =
        "A name listed in `import m.{…}` that no expression, signature, constraint, pattern, doctest, `test` or `prop` body of the file uses is dead weight and hides which imports matter. `public import` re-exports, `import m.*`, bare `import m` and `import m as A` list no names and are not checked, and a `T(..)` member is never reported, since a constructor use is not tied to `T`. The fix drops the name and its comma; when no name of the line is used it leaves a bare `import m`, which still brings the module's `impl`s into scope.\n\nBefore:\n  import list.{sort, nub}\n  main = sort [2, 1]\nAfter:\n  import list.{sort}\n  main = sort [2, 1]",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [NeedsScopes],
    }
    ruleUnusedImport
    None

ruleUnusedImport : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleUnusedImport _ _ facts _ prog =
  let fs = factScopes facts
  let silent = filter (u => snd u == 0) (importUses fs)
  if isEmpty silent then
    []
  else
    let seen = doctestNames (doctestBodies (factComments facts))
    let dead =
      map
        (u => (fst u).binderId)
        (filter (u => not (elem (fst u).binderName seen)) silent)
    flatMap (groupFindings fs dead) prog

-- A `public import` re-exports its names, so none of them is dead.
groupFindings : FileScopes -> List Int -> Decl -> List Finding
groupFindings fs dead (DUse False (UseGroup path members) groupLoc) =
  let flags = map (memberDead fs dead) members
  let locs = map memberLoc members
  let everyDead = all (f => f) flags
  flatMap
    (ix => memberFinding path groupLoc locs everyDead members ix)
    (filter (ix => nthFlag flags ix) (map fst (indexed members)))
groupFindings _ _ _ = []

-- The identifiers of doctest inputs, which are comments and so never walked.
doctestNames : List String -> List String
doctestNames inputs = flatMap (d => flatMap rawIdent (scanRaw d)) inputs

rawIdent : RawTok -> List String
rawIdent (RTok (TIdent x) _ _) = [x]
rawIdent (RTok (TUpper x) _ _) = [x]
rawIdent _ = []

-- The input of each doctest line: `-- > expr` in a line comment, or a line
-- starting `> ` inside a block comment, which on the opening line follows the
-- `{-`.
doctestBodies : List Comment -> List String
doctestBodies comments =
  flatMap (c => flatMap doctestBody (lines (commentText c))) comments

doctestBody : String -> List String
doctestBody line =
  let t = trim line
  let inner = trim (optionOr t (stripPrefix "{-" t))
  toList (stripPrefix "-- > " t) ++ toList (stripPrefix "> " inner)

memberLoc : UseMember -> Loc
memberLoc (UseMember _ _ loc _) = loc

-- A `T(..)` member is never dead: it may be used through a constructor, which
-- the scope model does not tie to `T`.
memberDead : FileScopes -> List Int -> UseMember -> Bool
memberDead fs dead (UseMember _ allCtors loc _) = match binderOf fs loc
  Some b => not allCtors && elem b.binderId dead
  None => False

nthFlag : List Bool -> Int -> Bool
nthFlag flags ix = match drop ix flags
  f :: _ => f
  [] => False

memberFinding : List String ->
  Loc ->
  List Loc ->
  Bool ->
  List UseMember ->
  Int ->
  List Finding
memberFinding path groupLoc locs everyDead members ix = match drop ix members
  (UseMember n _ loc alias) :: _ => [
    Finding {
      rule = ruleNameUnusedImport,
      message =
        "imported name '\{optionOr n alias}' is never used. Remove it from the import list",
      severity = SevWarning,
      loc = Some loc,
      fix = removalFix path groupLoc locs everyDead ix,
    },
  ]
  [] => []

-- A line whose names are all dead keeps the bare import, because the module's
-- `impl`s stay in scope through it.  A bare import of a dotted path does not
-- resolve for a project module (`import frontend.ast` is "unknown module"), so
-- there the fix is only suggested.
removalFix : List String -> Loc -> List Loc -> Bool -> Int -> Option Fix
removalFix path groupLoc locs everyDead ix
  | everyDead =
    Some
      (fixOf
        (if length path > 1 then Suggest else Safe)
        (FixEdit groupLoc ("import " ++ joinWith "." path)))
  | otherwise = map (fixOf Safe) (removeListItem locs ix)

fixOf : Applicability -> FixEdit -> Fix
fixOf applicability edit = Fix {
  fixApplicability = applicability,
  fixEdits = [edit],
  fixMessage = "remove the unused import",
}
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Loc" true) (mem "UseMember" true) (mem "UsePath" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "lex_scan") ((mem "scanRaw" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "RawTok" true) (mem "Token" true))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentText" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "indexed" false))))
(DUse false (UseGroup ("string") ((mem "lines" false) (mem "stripPrefix" false) (mem "trim" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factComments" false) (mem "factScopes" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_fix") ((mem "removeListItem" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "Binder" true) (mem "FileScopes" false) (mem "binderOf" false) (mem "importUses" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameUnusedImport" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameUnusedImport")) (fa "summary" (ELit (LString "an imported name that nothing in the file uses"))) (fa "doc" (ELit (LString "A name listed in `import m.{…}` that no expression, signature, constraint, pattern, doctest, `test` or `prop` body of the file uses is dead weight and hides which imports matter. `public import` re-exports, `import m.*`, bare `import m` and `import m as A` list no names and are not checked, and a `T(..)` member is never reported, since a constructor use is not tied to `T`. The fix drops the name and its comma; when no name of the line is used it leaves a bare `import m`, which still brings the module's `impl`s into scope.\n\nBefore:\n  import list.{sort, nub}\n  main = sort [2, 1]\nAfter:\n  import list.{sort}\n  main = sort [2, 1]"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleUnusedImport")) (EVar "None")))
(DTypeSig false "ruleUnusedImport" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleUnusedImport" (PWild PWild (PVar "facts") PWild (PVar "prog")) (EBlock (DoLet false false (PVar "fs") (EApp (EVar "factScopes") (EVar "facts"))) (DoLet false false (PVar "silent") (EApp (EApp (EVar "filter") (ELam ((PVar "u")) (EBinOp "==" (EApp (EVar "snd") (EVar "u")) (ELit (LInt 0))))) (EApp (EVar "importUses") (EVar "fs")))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "silent")) (EListLit) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "doctestNames") (EApp (EVar "doctestBodies") (EApp (EVar "factComments") (EVar "facts"))))) (DoLet false false (PVar "dead") (EApp (EApp (EVar "map") (ELam ((PVar "u")) (EFieldAccess (EApp (EVar "fst") (EVar "u")) "binderId"))) (EApp (EApp (EVar "filter") (ELam ((PVar "u")) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EFieldAccess (EApp (EVar "fst") (EVar "u")) "binderName")) (EVar "seen"))))) (EVar "silent")))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "groupFindings") (EVar "fs")) (EVar "dead"))) (EVar "prog"))))))))
(DTypeSig false "groupFindings" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "groupFindings" ((PVar "fs") (PVar "dead") (PCon "DUse" (PCon "False") (PCon "UseGroup" (PVar "path") (PVar "members")) (PVar "groupLoc"))) (EBlock (DoLet false false (PVar "flags") (EApp (EApp (EVar "map") (EApp (EApp (EVar "memberDead") (EVar "fs")) (EVar "dead"))) (EVar "members"))) (DoLet false false (PVar "locs") (EApp (EApp (EVar "map") (EVar "memberLoc")) (EVar "members"))) (DoLet false false (PVar "everyDead") (EApp (EApp (EVar "all") (ELam ((PVar "f")) (EVar "f"))) (EVar "flags"))) (DoExpr (EApp (EApp (EVar "flatMap") (ELam ((PVar "ix")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "memberFinding") (EVar "path")) (EVar "groupLoc")) (EVar "locs")) (EVar "everyDead")) (EVar "members")) (EVar "ix")))) (EApp (EApp (EVar "filter") (ELam ((PVar "ix")) (EApp (EApp (EVar "nthFlag") (EVar "flags")) (EVar "ix")))) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "indexed") (EVar "members"))))))))
(DFunDef false "groupFindings" (PWild PWild PWild) (EListLit))
(DTypeSig false "doctestNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doctestNames" ((PVar "inputs")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "d")) (EApp (EApp (EVar "flatMap") (EVar "rawIdent")) (EApp (EVar "scanRaw") (EVar "d"))))) (EVar "inputs")))
(DTypeSig false "rawIdent" (TyFun (TyCon "RawTok") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rawIdent" ((PCon "RTok" (PCon "TIdent" (PVar "x")) PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "rawIdent" ((PCon "RTok" (PCon "TUpper" (PVar "x")) PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "rawIdent" (PWild) (EListLit))
(DTypeSig false "doctestBodies" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doctestBodies" ((PVar "comments")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EApp (EApp (EVar "flatMap") (EVar "doctestBody")) (EApp (EVar "lines") (EApp (EVar "commentText") (EVar "c")))))) (EVar "comments")))
(DTypeSig false "doctestBody" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doctestBody" ((PVar "line")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "trim") (EVar "line"))) (DoLet false false (PVar "inner") (EApp (EVar "trim") (EApp (EApp (EVar "optionOr") (EVar "t")) (EApp (EApp (EVar "stripPrefix") (ELit (LString "{-"))) (EVar "t"))))) (DoExpr (EBinOp "++" (EApp (EVar "toList") (EApp (EApp (EVar "stripPrefix") (ELit (LString "-- > "))) (EVar "t"))) (EApp (EVar "toList") (EApp (EApp (EVar "stripPrefix") (ELit (LString "> "))) (EVar "inner")))))))
(DTypeSig false "memberLoc" (TyFun (TyCon "UseMember") (TyCon "Loc")))
(DFunDef false "memberLoc" ((PCon "UseMember" PWild PWild (PVar "loc") PWild)) (EVar "loc"))
(DTypeSig false "memberDead" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "UseMember") (TyCon "Bool")))))
(DFunDef false "memberDead" ((PVar "fs") (PVar "dead") (PCon "UseMember" PWild (PVar "allCtors") (PVar "loc") PWild)) (EMatch (EApp (EApp (EVar "binderOf") (EVar "fs")) (EVar "loc")) (arm (PCon "Some" (PVar "b")) () (EBinOp "&&" (EApp (EVar "not") (EVar "allCtors")) (EApp (EApp (EVar "elem") (EFieldAccess (EVar "b") "binderId")) (EVar "dead")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "nthFlag" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "nthFlag" ((PVar "flags") (PVar "ix")) (EMatch (EApp (EApp (EVar "drop") (EVar "ix")) (EVar "flags")) (arm (PCons (PVar "f") PWild) () (EVar "f")) (arm (PList) () (EVar "False"))))
(DTypeSig false "memberFinding" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Loc")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "memberFinding" ((PVar "path") (PVar "groupLoc") (PVar "locs") (PVar "everyDead") (PVar "members") (PVar "ix")) (EMatch (EApp (EApp (EVar "drop") (EVar "ix")) (EVar "members")) (arm (PCons (PCon "UseMember" (PVar "n") PWild (PVar "loc") (PVar "alias")) PWild) () (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameUnusedImport")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "imported name '")) (EApp (EVar "display") (EApp (EApp (EVar "optionOr") (EVar "n")) (EVar "alias")))) (ELit (LString "' is never used. Remove it from the import list")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EVar "loc"))) (fa "fix" (EApp (EApp (EApp (EApp (EApp (EVar "removalFix") (EVar "path")) (EVar "groupLoc")) (EVar "locs")) (EVar "everyDead")) (EVar "ix"))))))) (arm (PList) () (EListLit))))
(DTypeSig false "removalFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Loc")) (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "removalFix" ((PVar "path") (PVar "groupLoc") (PVar "locs") (PVar "everyDead") (PVar "ix")) (EIf (EVar "everyDead") (EApp (EVar "Some") (EApp (EApp (EVar "fixOf") (EIf (EBinOp ">" (EApp (EVar "length") (EVar "path")) (ELit (LInt 1))) (EVar "Suggest") (EVar "Safe"))) (EApp (EApp (EVar "FixEdit") (EVar "groupLoc")) (EBinOp "++" (ELit (LString "import ")) (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "path")))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (EApp (EVar "fixOf") (EVar "Safe"))) (EApp (EApp (EVar "removeListItem") (EVar "locs")) (EVar "ix"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fixOf" (TyFun (TyCon "Applicability") (TyFun (TyCon "FixEdit") (TyCon "Fix"))))
(DFunDef false "fixOf" ((PVar "applicability") (PVar "edit")) (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "applicability")) (fa "fixEdits" (EListLit (EVar "edit"))) (fa "fixMessage" (ELit (LString "remove the unused import"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Loc" true) (mem "UseMember" true) (mem "UsePath" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "lex_scan") ((mem "scanRaw" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "RawTok" true) (mem "Token" true))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "commentText" false))))
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "indexed" false))))
(DUse false (UseGroup ("string") ((mem "lines" false) (mem "stripPrefix" false) (mem "trim" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "factComments" false) (mem "factScopes" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_fix") ((mem "removeListItem" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "Binder" true) (mem "FileScopes" false) (mem "binderOf" false) (mem "importUses" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameUnusedImport" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameUnusedImport")) (fa "summary" (ELit (LString "an imported name that nothing in the file uses"))) (fa "doc" (ELit (LString "A name listed in `import m.{…}` that no expression, signature, constraint, pattern, doctest, `test` or `prop` body of the file uses is dead weight and hides which imports matter. `public import` re-exports, `import m.*`, bare `import m` and `import m as A` list no names and are not checked, and a `T(..)` member is never reported, since a constructor use is not tied to `T`. The fix drops the name and its comma; when no name of the line is used it leaves a bare `import m`, which still brings the module's `impl`s into scope.\n\nBefore:\n  import list.{sort, nub}\n  main = sort [2, 1]\nAfter:\n  import list.{sort}\n  main = sort [2, 1]"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleUnusedImport")) (EVar "None")))
(DTypeSig false "ruleUnusedImport" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleUnusedImport" (PWild PWild (PVar "facts") PWild (PVar "prog")) (EBlock (DoLet false false (PVar "fs") (EApp (EVar "factScopes") (EVar "facts"))) (DoLet false false (PVar "silent") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "u")) (EBinOp "==" (EApp (EVar "snd") (EVar "u")) (ELit (LInt 0))))) (EApp (EVar "importUses") (EVar "fs")))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "silent")) (EListLit) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "doctestNames") (EApp (EVar "doctestBodies") (EApp (EVar "factComments") (EVar "facts"))))) (DoLet false false (PVar "dead") (EApp (EApp (EMethodRef "map") (ELam ((PVar "u")) (EFieldAccess (EApp (EVar "fst") (EVar "u")) "binderId"))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "u")) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EFieldAccess (EApp (EVar "fst") (EVar "u")) "binderName")) (EVar "seen"))))) (EVar "silent")))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "groupFindings") (EVar "fs")) (EVar "dead"))) (EVar "prog"))))))))
(DTypeSig false "groupFindings" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "groupFindings" ((PVar "fs") (PVar "dead") (PCon "DUse" (PCon "False") (PCon "UseGroup" (PVar "path") (PVar "members")) (PVar "groupLoc"))) (EBlock (DoLet false false (PVar "flags") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "memberDead") (EVar "fs")) (EVar "dead"))) (EVar "members"))) (DoLet false false (PVar "locs") (EApp (EApp (EMethodRef "map") (EVar "memberLoc")) (EVar "members"))) (DoLet false false (PVar "everyDead") (EApp (EApp (EDictApp "all") (ELam ((PVar "f")) (EVar "f"))) (EVar "flags"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "ix")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "memberFinding") (EVar "path")) (EVar "groupLoc")) (EVar "locs")) (EVar "everyDead")) (EVar "members")) (EVar "ix")))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "ix")) (EApp (EApp (EVar "nthFlag") (EVar "flags")) (EVar "ix")))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "indexed") (EVar "members"))))))))
(DFunDef false "groupFindings" (PWild PWild PWild) (EListLit))
(DTypeSig false "doctestNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doctestNames" ((PVar "inputs")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "d")) (EApp (EApp (EDictApp "flatMap") (EVar "rawIdent")) (EApp (EVar "scanRaw") (EVar "d"))))) (EVar "inputs")))
(DTypeSig false "rawIdent" (TyFun (TyCon "RawTok") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rawIdent" ((PCon "RTok" (PCon "TIdent" (PVar "x")) PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "rawIdent" ((PCon "RTok" (PCon "TUpper" (PVar "x")) PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "rawIdent" (PWild) (EListLit))
(DTypeSig false "doctestBodies" (TyFun (TyApp (TyCon "List") (TyCon "Comment")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doctestBodies" ((PVar "comments")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EApp (EApp (EDictApp "flatMap") (EVar "doctestBody")) (EApp (EVar "lines") (EApp (EVar "commentText") (EVar "c")))))) (EVar "comments")))
(DTypeSig false "doctestBody" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doctestBody" ((PVar "line")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "trim") (EVar "line"))) (DoLet false false (PVar "inner") (EApp (EVar "trim") (EApp (EApp (EVar "optionOr") (EVar "t")) (EApp (EApp (EVar "stripPrefix") (ELit (LString "{-"))) (EVar "t"))))) (DoExpr (EBinOp "++" (EApp (EMethodRef "toList") (EApp (EApp (EVar "stripPrefix") (ELit (LString "-- > "))) (EVar "t"))) (EApp (EMethodRef "toList") (EApp (EApp (EVar "stripPrefix") (ELit (LString "> "))) (EVar "inner")))))))
(DTypeSig false "memberLoc" (TyFun (TyCon "UseMember") (TyCon "Loc")))
(DFunDef false "memberLoc" ((PCon "UseMember" PWild PWild (PVar "loc") PWild)) (EVar "loc"))
(DTypeSig false "memberDead" (TyFun (TyCon "FileScopes") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "UseMember") (TyCon "Bool")))))
(DFunDef false "memberDead" ((PVar "fs") (PVar "dead") (PCon "UseMember" PWild (PVar "allCtors") (PVar "loc") PWild)) (EMatch (EApp (EApp (EVar "binderOf") (EVar "fs")) (EVar "loc")) (arm (PCon "Some" (PVar "b")) () (EBinOp "&&" (EApp (EVar "not") (EVar "allCtors")) (EApp (EApp (EDictApp "elem") (EFieldAccess (EVar "b") "binderId")) (EVar "dead")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "nthFlag" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "nthFlag" ((PVar "flags") (PVar "ix")) (EMatch (EApp (EApp (EVar "drop") (EVar "ix")) (EVar "flags")) (arm (PCons (PVar "f") PWild) () (EVar "f")) (arm (PList) () (EVar "False"))))
(DTypeSig false "memberFinding" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Loc")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "memberFinding" ((PVar "path") (PVar "groupLoc") (PVar "locs") (PVar "everyDead") (PVar "members") (PVar "ix")) (EMatch (EApp (EApp (EVar "drop") (EVar "ix")) (EVar "members")) (arm (PCons (PCon "UseMember" (PVar "n") PWild (PVar "loc") (PVar "alias")) PWild) () (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameUnusedImport")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "imported name '")) (EApp (EMethodRef "display") (EApp (EApp (EVar "optionOr") (EVar "n")) (EVar "alias")))) (ELit (LString "' is never used. Remove it from the import list")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EVar "loc"))) (fa "fix" (EApp (EApp (EApp (EApp (EApp (EVar "removalFix") (EVar "path")) (EVar "groupLoc")) (EVar "locs")) (EVar "everyDead")) (EVar "ix"))))))) (arm (PList) () (EListLit))))
(DTypeSig false "removalFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Loc")) (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "removalFix" ((PVar "path") (PVar "groupLoc") (PVar "locs") (PVar "everyDead") (PVar "ix")) (EIf (EVar "everyDead") (EApp (EVar "Some") (EApp (EApp (EVar "fixOf") (EIf (EBinOp ">" (EApp (EMethodRef "length") (EVar "path")) (ELit (LInt 1))) (EVar "Suggest") (EVar "Safe"))) (EApp (EApp (EVar "FixEdit") (EVar "groupLoc")) (EBinOp "++" (ELit (LString "import ")) (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "path")))))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (EApp (EVar "fixOf") (EVar "Safe"))) (EApp (EApp (EVar "removeListItem") (EVar "locs")) (EVar "ix"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fixOf" (TyFun (TyCon "Applicability") (TyFun (TyCon "FixEdit") (TyCon "Fix"))))
(DFunDef false "fixOf" ((PVar "applicability") (PVar "edit")) (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "applicability")) (fa "fixEdits" (EListLit (EVar "edit"))) (fa "fixMessage" (ELit (LString "remove the unused import"))))))
