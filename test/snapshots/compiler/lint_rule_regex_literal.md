# META
source_lines=159
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-regex-literal: a string literal passed to `compile`/`mustCompile` that fails to compile as a regex.

import frontend.ast.{
  Loc(..), Lit(..), UsePath(..), qualifiedLocal, Expr(..), Decl(..)
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{contains}
import tools.printer.{exprToString}
import regex.{RegexError(..), compile}
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
  mkRule,
}
import tools.lint_shared.{
  exprRuleFindings,
  lastSegOf,
  memberLocalIfOrigin,
  noExcl,
  ruleNameRegexLiteral,
  stripELoc,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameRegexLiteral,
      summary =
        "a string literal passed directly to `compile`/`mustCompile` fails to compile as a regex pattern",
      doc =
        "A string literal passed directly to `compile` or `mustCompile` that is not a valid regex fails at run time on every call. The rule compiles it at lint time.\n\nBefore:\n  mustCompile \"(unclosed\"\nAfter:\n  mustCompile \"(closed)\"",
      category = Correctness,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleRegexLiteral
    None

-- ── rule: regex-literal ────────────────────────────────────────────────────────
-- A string literal passed directly to `compile`/`mustCompile` (bare, or
-- reached through any of THIS FILE's own `import regex` forms -- a module
-- alias's dotted spelling, or a group import's renamed member) is run through
-- `regex.compile` AT LINT TIME; a bad pattern becomes one located finding
-- instead of a `mustCompile` panic the FIRST time the line runs.
regexLiteralCallNames : List String
regexLiteralCallNames = ["compile", "mustCompile"]

-- The extra call spellings THIS FILE's own `import regex` decls bind for
-- `compile`/`mustCompile`: a module alias (`import regex as Re` ->
-- `Re.compile`), a group-import rename (`import regex.{mustCompile as mc}`
-- -> `mc`), or a group import's own unrenamed member.  Read straight off the
-- raw `DUse` decls (lint has no resolver, [P-DESUGAR-FIRST]) and across
-- EVERY such decl in the file, not just the first -- a file may import the
-- same module more than once under different forms.  An unaliased dotted
-- `regex.mustCompile` is never produced here -- a bare `import regex` binds
-- no names at all ([P-IMPORT-BINDS]), so that spelling is not a call real
-- code can make.
regexImportedCallNames : List Decl -> List String
regexImportedCallNames prog =
  flatMap (regexImportedCallNamesFor prog) ["compile", "mustCompile"]

regexImportedCallNamesFor : List Decl -> String -> List String
regexImportedCallNamesFor prog stdName =
  flatMap (regexLocalNamesInDecl stdName) prog

regexLocalNamesInDecl : String -> Decl -> List String
regexLocalNamesInDecl stdName (DUse _ path _) =
  regexLocalNamesInPath stdName path
regexLocalNamesInDecl stdName (DAttrib _ d) = regexLocalNamesInDecl stdName d
regexLocalNamesInDecl _ _ = []

regexLocalNamesInPath : String -> UsePath -> List String
regexLocalNamesInPath stdName (UseGroup path members)
  | lastSegOf path == "regex" = filterMap (memberLocalIfOrigin stdName) members
  | otherwise = []
regexLocalNamesInPath stdName (UseWild path)
  | lastSegOf path == "regex" = [stdName]
  | otherwise = []
regexLocalNamesInPath stdName (UseAlias path alias)
  | lastSegOf path == "regex" = [qualifiedLocal alias stdName]
  | otherwise = []
regexLocalNamesInPath _ _ = []

ruleRegexLiteral : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleRegexLiteral _ _ _ pos prog =
  exprRuleFindings
    noExcl
    (regexLiteralOf (regexLiteralCallNames ++ regexImportedCallNames prog))
    regexLiteralFinding
    pos
    prog

-- The parser ELoc-wraps every expr, callee and argument included, so both
-- must be peeled (`stripELoc`) before the shape match.
regexLiteralOf : List String -> Expr -> Option Expr
regexLiteralOf names e = regexLiteralOfSpine names e (stripELoc e)

regexLiteralOfSpine : List String -> Expr -> Expr -> Option Expr
regexLiteralOfSpine names e (EApp callee arg) =
  regexLiteralOfArg names e (stripELoc callee) (stripELoc arg)
regexLiteralOfSpine _ _ _ = None

regexLiteralOfArg : List String -> Expr -> Expr -> Expr -> Option Expr
regexLiteralOfArg names e callee (ELit (LString pat))
  | contains (exprToString callee) names && isRegexErr pat = Some e
  | otherwise = None
regexLiteralOfArg _ _ _ _ = None

isRegexErr : String -> Bool
isRegexErr pat = match compile pat
  Err _ => True
  Ok _ => False

regexLiteralFinding : Option Loc -> Expr -> Finding
regexLiteralFinding loc e = regexLiteralFindingSpine loc (stripELoc e)

regexLiteralFindingSpine : Option Loc -> Expr -> Finding
regexLiteralFindingSpine loc (EApp _ arg) =
  regexLiteralFindingArg loc (stripELoc arg)
-- `regexLiteralOf` only ever hits an `EApp _ (ELit (LString _))`.
regexLiteralFindingSpine loc _ = regexLiteralErrFinding loc ""

regexLiteralFindingArg : Option Loc -> Expr -> Finding
regexLiteralFindingArg loc (ELit (LString pat)) = regexLiteralErrFinding loc pat
regexLiteralFindingArg loc _ = regexLiteralErrFinding loc ""

regexLiteralErrFinding : Option Loc -> String -> Finding
regexLiteralErrFinding loc pat = match compile pat
  Err (RegexError { message, position }) => Finding {
    rule = ruleNameRegexLiteral,
    message =
      "regex pattern \"\{pat}\" fails to compile: \{message} (position \{intToString position})",
    severity = SevWarning,
    loc = loc,
  }
  Ok _ => Finding {
    rule = ruleNameRegexLiteral,
    message = "regex pattern \"\{pat}\" fails to compile",
    severity = SevWarning,
    loc = loc,
  }
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "UsePath" true) (mem "qualifiedLocal" false) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("regex") ((mem "RegexError" true) (mem "compile" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "exprRuleFindings" false) (mem "lastSegOf" false) (mem "memberLocalIfOrigin" false) (mem "noExcl" false) (mem "ruleNameRegexLiteral" false) (mem "stripELoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameRegexLiteral")) (fa "summary" (ELit (LString "a string literal passed directly to `compile`/`mustCompile` fails to compile as a regex pattern"))) (fa "doc" (ELit (LString "A string literal passed directly to `compile` or `mustCompile` that is not a valid regex fails at run time on every call. The rule compiles it at lint time.\n\nBefore:\n  mustCompile \"(unclosed\"\nAfter:\n  mustCompile \"(closed)\""))) (fa "category" (EVar "Correctness")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleRegexLiteral")) (EVar "None")))
(DTypeSig false "regexLiteralCallNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "regexLiteralCallNames" () (EListLit (ELit (LString "compile")) (ELit (LString "mustCompile"))))
(DTypeSig false "regexImportedCallNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "regexImportedCallNames" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "regexImportedCallNamesFor") (EVar "prog"))) (EListLit (ELit (LString "compile")) (ELit (LString "mustCompile")))))
(DTypeSig false "regexImportedCallNamesFor" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "regexImportedCallNamesFor" ((PVar "prog") (PVar "stdName")) (EApp (EApp (EVar "flatMap") (EApp (EVar "regexLocalNamesInDecl") (EVar "stdName"))) (EVar "prog")))
(DTypeSig false "regexLocalNamesInDecl" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "regexLocalNamesInDecl" ((PVar "stdName") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "regexLocalNamesInPath") (EVar "stdName")) (EVar "path")))
(DFunDef false "regexLocalNamesInDecl" ((PVar "stdName") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "regexLocalNamesInDecl") (EVar "stdName")) (EVar "d")))
(DFunDef false "regexLocalNamesInDecl" (PWild PWild) (EListLit))
(DTypeSig false "regexLocalNamesInPath" (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "regexLocalNamesInPath" ((PVar "stdName") (PCon "UseGroup" (PVar "path") (PVar "members"))) (EIf (EBinOp "==" (EApp (EVar "lastSegOf") (EVar "path")) (ELit (LString "regex"))) (EApp (EApp (EVar "filterMap") (EApp (EVar "memberLocalIfOrigin") (EVar "stdName"))) (EVar "members")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "regexLocalNamesInPath" ((PVar "stdName") (PCon "UseWild" (PVar "path"))) (EIf (EBinOp "==" (EApp (EVar "lastSegOf") (EVar "path")) (ELit (LString "regex"))) (EListLit (EVar "stdName")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "regexLocalNamesInPath" ((PVar "stdName") (PCon "UseAlias" (PVar "path") (PVar "alias"))) (EIf (EBinOp "==" (EApp (EVar "lastSegOf") (EVar "path")) (ELit (LString "regex"))) (EListLit (EApp (EApp (EVar "qualifiedLocal") (EVar "alias")) (EVar "stdName"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "regexLocalNamesInPath" (PWild PWild) (EListLit))
(DTypeSig false "ruleRegexLiteral" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleRegexLiteral" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EApp (EVar "regexLiteralOf") (EBinOp "++" (EVar "regexLiteralCallNames") (EApp (EVar "regexImportedCallNames") (EVar "prog"))))) (EVar "regexLiteralFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "regexLiteralOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "regexLiteralOf" ((PVar "names") (PVar "e")) (EApp (EApp (EApp (EVar "regexLiteralOfSpine") (EVar "names")) (EVar "e")) (EApp (EVar "stripELoc") (EVar "e"))))
(DTypeSig false "regexLiteralOfSpine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "regexLiteralOfSpine" ((PVar "names") (PVar "e") (PCon "EApp" (PVar "callee") (PVar "arg"))) (EApp (EApp (EApp (EApp (EVar "regexLiteralOfArg") (EVar "names")) (EVar "e")) (EApp (EVar "stripELoc") (EVar "callee"))) (EApp (EVar "stripELoc") (EVar "arg"))))
(DFunDef false "regexLiteralOfSpine" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "regexLiteralOfArg" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))))
(DFunDef false "regexLiteralOfArg" ((PVar "names") (PVar "e") (PVar "callee") (PCon "ELit" (PCon "LString" (PVar "pat")))) (EIf (EBinOp "&&" (EApp (EApp (EVar "contains") (EApp (EVar "exprToString") (EVar "callee"))) (EVar "names")) (EApp (EVar "isRegexErr") (EVar "pat"))) (EApp (EVar "Some") (EVar "e")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "regexLiteralOfArg" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "isRegexErr" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isRegexErr" ((PVar "pat")) (EMatch (EApp (EVar "compile") (EVar "pat")) (arm (PCon "Err" PWild) () (EVar "True")) (arm (PCon "Ok" PWild) () (EVar "False"))))
(DTypeSig false "regexLiteralFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "regexLiteralFinding" ((PVar "loc") (PVar "e")) (EApp (EApp (EVar "regexLiteralFindingSpine") (EVar "loc")) (EApp (EVar "stripELoc") (EVar "e"))))
(DTypeSig false "regexLiteralFindingSpine" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "regexLiteralFindingSpine" ((PVar "loc") (PCon "EApp" PWild (PVar "arg"))) (EApp (EApp (EVar "regexLiteralFindingArg") (EVar "loc")) (EApp (EVar "stripELoc") (EVar "arg"))))
(DFunDef false "regexLiteralFindingSpine" ((PVar "loc") PWild) (EApp (EApp (EVar "regexLiteralErrFinding") (EVar "loc")) (ELit (LString ""))))
(DTypeSig false "regexLiteralFindingArg" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "regexLiteralFindingArg" ((PVar "loc") (PCon "ELit" (PCon "LString" (PVar "pat")))) (EApp (EApp (EVar "regexLiteralErrFinding") (EVar "loc")) (EVar "pat")))
(DFunDef false "regexLiteralFindingArg" ((PVar "loc") PWild) (EApp (EApp (EVar "regexLiteralErrFinding") (EVar "loc")) (ELit (LString ""))))
(DTypeSig false "regexLiteralErrFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "regexLiteralErrFinding" ((PVar "loc") (PVar "pat")) (EMatch (EApp (EVar "compile") (EVar "pat")) (arm (PCon "Err" (PRec "RegexError" ((rf "message" None) (rf "position" None)) false)) () (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameRegexLiteral")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "regex pattern \"")) (EApp (EVar "display") (EVar "pat"))) (ELit (LString "\" fails to compile: "))) (EApp (EVar "display") (EVar "message"))) (ELit (LString " (position "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "position")))) (ELit (LString ")")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (arm (PCon "Ok" PWild) () (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameRegexLiteral")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "regex pattern \"")) (EApp (EVar "display") (EVar "pat"))) (ELit (LString "\" fails to compile")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "UsePath" true) (mem "qualifiedLocal" false) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("regex") ((mem "RegexError" true) (mem "compile" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "exprRuleFindings" false) (mem "lastSegOf" false) (mem "memberLocalIfOrigin" false) (mem "noExcl" false) (mem "ruleNameRegexLiteral" false) (mem "stripELoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameRegexLiteral")) (fa "summary" (ELit (LString "a string literal passed directly to `compile`/`mustCompile` fails to compile as a regex pattern"))) (fa "doc" (ELit (LString "A string literal passed directly to `compile` or `mustCompile` that is not a valid regex fails at run time on every call. The rule compiles it at lint time.\n\nBefore:\n  mustCompile \"(unclosed\"\nAfter:\n  mustCompile \"(closed)\""))) (fa "category" (EVar "Correctness")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleRegexLiteral")) (EVar "None")))
(DTypeSig false "regexLiteralCallNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "regexLiteralCallNames" () (EListLit (ELit (LString "compile")) (ELit (LString "mustCompile"))))
(DTypeSig false "regexImportedCallNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "regexImportedCallNames" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "regexImportedCallNamesFor") (EVar "prog"))) (EListLit (ELit (LString "compile")) (ELit (LString "mustCompile")))))
(DTypeSig false "regexImportedCallNamesFor" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "regexImportedCallNamesFor" ((PVar "prog") (PVar "stdName")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "regexLocalNamesInDecl") (EVar "stdName"))) (EVar "prog")))
(DTypeSig false "regexLocalNamesInDecl" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "regexLocalNamesInDecl" ((PVar "stdName") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "regexLocalNamesInPath") (EVar "stdName")) (EVar "path")))
(DFunDef false "regexLocalNamesInDecl" ((PVar "stdName") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "regexLocalNamesInDecl") (EVar "stdName")) (EVar "d")))
(DFunDef false "regexLocalNamesInDecl" (PWild PWild) (EListLit))
(DTypeSig false "regexLocalNamesInPath" (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "regexLocalNamesInPath" ((PVar "stdName") (PCon "UseGroup" (PVar "path") (PVar "members"))) (EIf (EBinOp "==" (EApp (EVar "lastSegOf") (EVar "path")) (ELit (LString "regex"))) (EApp (EApp (EMethodRef "filterMap") (EApp (EVar "memberLocalIfOrigin") (EVar "stdName"))) (EVar "members")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "regexLocalNamesInPath" ((PVar "stdName") (PCon "UseWild" (PVar "path"))) (EIf (EBinOp "==" (EApp (EVar "lastSegOf") (EVar "path")) (ELit (LString "regex"))) (EListLit (EVar "stdName")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "regexLocalNamesInPath" ((PVar "stdName") (PCon "UseAlias" (PVar "path") (PVar "alias"))) (EIf (EBinOp "==" (EApp (EVar "lastSegOf") (EVar "path")) (ELit (LString "regex"))) (EListLit (EApp (EApp (EVar "qualifiedLocal") (EVar "alias")) (EVar "stdName"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "regexLocalNamesInPath" (PWild PWild) (EListLit))
(DTypeSig false "ruleRegexLiteral" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleRegexLiteral" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EApp (EVar "regexLiteralOf") (EBinOp "++" (EVar "regexLiteralCallNames") (EApp (EVar "regexImportedCallNames") (EVar "prog"))))) (EVar "regexLiteralFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "regexLiteralOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "regexLiteralOf" ((PVar "names") (PVar "e")) (EApp (EApp (EApp (EVar "regexLiteralOfSpine") (EVar "names")) (EVar "e")) (EApp (EVar "stripELoc") (EVar "e"))))
(DTypeSig false "regexLiteralOfSpine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "regexLiteralOfSpine" ((PVar "names") (PVar "e") (PCon "EApp" (PVar "callee") (PVar "arg"))) (EApp (EApp (EApp (EApp (EVar "regexLiteralOfArg") (EVar "names")) (EVar "e")) (EApp (EVar "stripELoc") (EVar "callee"))) (EApp (EVar "stripELoc") (EVar "arg"))))
(DFunDef false "regexLiteralOfSpine" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "regexLiteralOfArg" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))))
(DFunDef false "regexLiteralOfArg" ((PVar "names") (PVar "e") (PVar "callee") (PCon "ELit" (PCon "LString" (PVar "pat")))) (EIf (EBinOp "&&" (EApp (EApp (EVar "contains") (EApp (EVar "exprToString") (EVar "callee"))) (EVar "names")) (EApp (EVar "isRegexErr") (EVar "pat"))) (EApp (EVar "Some") (EVar "e")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "regexLiteralOfArg" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "isRegexErr" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isRegexErr" ((PVar "pat")) (EMatch (EApp (EVar "compile") (EVar "pat")) (arm (PCon "Err" PWild) () (EVar "True")) (arm (PCon "Ok" PWild) () (EVar "False"))))
(DTypeSig false "regexLiteralFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "regexLiteralFinding" ((PVar "loc") (PVar "e")) (EApp (EApp (EVar "regexLiteralFindingSpine") (EVar "loc")) (EApp (EVar "stripELoc") (EVar "e"))))
(DTypeSig false "regexLiteralFindingSpine" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "regexLiteralFindingSpine" ((PVar "loc") (PCon "EApp" PWild (PVar "arg"))) (EApp (EApp (EVar "regexLiteralFindingArg") (EVar "loc")) (EApp (EVar "stripELoc") (EVar "arg"))))
(DFunDef false "regexLiteralFindingSpine" ((PVar "loc") PWild) (EApp (EApp (EVar "regexLiteralErrFinding") (EVar "loc")) (ELit (LString ""))))
(DTypeSig false "regexLiteralFindingArg" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "regexLiteralFindingArg" ((PVar "loc") (PCon "ELit" (PCon "LString" (PVar "pat")))) (EApp (EApp (EVar "regexLiteralErrFinding") (EVar "loc")) (EVar "pat")))
(DFunDef false "regexLiteralFindingArg" ((PVar "loc") PWild) (EApp (EApp (EVar "regexLiteralErrFinding") (EVar "loc")) (ELit (LString ""))))
(DTypeSig false "regexLiteralErrFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "regexLiteralErrFinding" ((PVar "loc") (PVar "pat")) (EMatch (EApp (EVar "compile") (EVar "pat")) (arm (PCon "Err" (PRec "RegexError" ((rf "message" None) (rf "position" None)) false)) () (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameRegexLiteral")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "regex pattern \"")) (EApp (EMethodRef "display") (EVar "pat"))) (ELit (LString "\" fails to compile: "))) (EApp (EMethodRef "display") (EVar "message"))) (ELit (LString " (position "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "position")))) (ELit (LString ")")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (arm (PCon "Ok" PWild) () (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameRegexLiteral")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "regex pattern \"")) (EApp (EMethodRef "display") (EVar "pat"))) (ELit (LString "\" fails to compile")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))))
