# META
source_lines=148
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint.mdk — the `medaka lint` facade.  The framework lives in
-- `lint_core` (types), `lint_shared` (common helpers), the `lint_rule_*`
-- modules (rule bodies), `lint_registry` (THE REGISTRY) and `lint_walk` (the runner);
-- this module re-exports the surface the CLI, MCP server and tests consume.

import tools.lint_fix as LF
import driver.diagnostics.{ppDiagCliSrc, parseErrDiag}
import frontend.ast.{Decl}
import frontend.parser.{Positions}
import tools.lint_walk.{lintParseSource, lintProgramFacts, mkFileFacts}
import tools.lint_registry.{selectRules}

export import tools.lint_core.{
  Applicability(..),
  Category(..),
  CrossFileRule(..),
  DirScope(..),
  Directive(..),
  Finding(..),
  Fix(..),
  FixEdit(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule(..),
  RuleMeta(..),
  Scope(..),
  StdlibIndex(..),
  StdlibIndexError(..),
  applicabilityText,
  emptyStdlibIndex,
  maxApplicability,
  ruleMetaName,
}
export import tools.lint_shared.{collectDirectives}
export import tools.lint_dup.{fileDupOccs}
export import tools.lint_registry.{
  allCrossFileRules,
  allRuleNames,
  allRules,
  crossFileMetaProblems,
  crossFileSelected,
  selectRules,
}
export import tools.lint_walk.{
  applyFindingDeny,
  applyFindingFilters,
  applyFixes,
  applySuppressions,
  applySuppressionsDirs,
  applySuppressionsMulti,
  applySuppressionsMultiDirs,
  buildStdlibIndexResult,
  crossFileCacheSound,
  factDirectives,
  factDupOccs,
  findingToDiag,
  isFindingError,
  lintFileDiagTriple,
  lintFileDiagTripleParsed,
  lintParseSource,
  lintProgram,
  lintProgramFacts,
  lintToLines,
  mergeCrossFileIntoTriples,
  mkFileFacts,
  runCrossFileRules,
  runCrossFileRulesFromOccs,
  splitLintNames,
  stdlibFingerprint,
  stdlibIndexNeeded,
}

-- ── fixing ───────────────────────────────────────────────────────────────────
-- A source fixed to its fixed point: the span edits of the active rules first,
-- then the whole-declaration fixers over the result.  Returns the fixed source
-- and the number of fixes made, or why it was left alone.  The CLI's `--fix` and
-- the fixture drivers share this one path.
export
fixSource : StdlibIndex ->
  Applicability ->
  List String ->
  List String ->
  String ->
  String ->
  Result String (String, Int)
fixSource idx limit only disable path src = match lintParseSource src
  Err e => Err (ppDiagCliSrc src path (parseErrDiag path e))
  Ok parsed =>
    let editRules = filter emitsEdits (selectRules only disable)
    if isEmpty editRules then
      wholeDeclFix only disable src 0 parsed
    else match (LF.applyFixes
      (editLinter idx editRules src parsed)
      limit
      path
      src)
      Err e => Err "\{path}: \{LF.fixErrorText e}"
      Ok (edited, 0) => wholeDeclFix only disable edited 0 parsed
      Ok (edited, n) => match lintParseSource edited
        Err e => Err (ppDiagCliSrc edited path (parseErrDiag path e))
        Ok reparsed => wholeDeclFix only disable edited n reparsed

wholeDeclFix : List String ->
  List String ->
  String ->
  Int ->
  (List Decl, Positions) ->
  Result String (String, Int)
wholeDeclFix only disable src edited (decls, pos) =
  let (out, adapted) = applyFixes only disable src decls pos
  Ok (out, edited + adapted)

-- A rule whose fixes are span edits rather than a whole-declaration rewrite:
-- fixable, yet carrying no declaration fixer.
emitsEdits : Rule -> Bool
emitsEdits r = match r.meta.fixability
  Fixable => isNone r.fix
  NotFixable => False
  _ => True

-- The findings of a source under `rules`, or why it does not parse.  A finding
-- that an inline directive suppresses carries no fix: the directive says the
-- shape is deliberate.  `parsed` is the parse of `first`, which the first pass
-- reads again.
editLinter : StdlibIndex ->
  List Rule ->
  String ->
  (List Decl, Positions) ->
  String ->
  String ->
  Result String (List Finding)
editLinter idx rules first parsed path src =
  if src == first then
    Ok (editFindings idx rules path src parsed)
  else match lintParseSource src
    Err e => Err (ppDiagCliSrc src path (parseErrDiag path e))
    Ok reparsed => Ok (editFindings idx rules path src reparsed)

editFindings : StdlibIndex ->
  List Rule ->
  String ->
  String ->
  (List Decl, Positions) ->
  List Finding
editFindings idx rules path src (decls, pos) =
  let facts = mkFileFacts src decls pos
  applySuppressions src (lintProgramFacts idx rules path facts pos decls)
# DESUGAR
(DUse false (UseAlias ("tools" "lint_fix") "LF"))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "ppDiagCliSrc" false) (mem "parseErrDiag" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" false))))
(DUse false (UseGroup ("tools" "lint_walk") ((mem "lintParseSource" false) (mem "lintProgramFacts" false) (mem "mkFileFacts" false))))
(DUse false (UseGroup ("tools" "lint_registry") ((mem "selectRules" false))))
(DUse true (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "CrossFileRule" true) (mem "DirScope" true) (mem "Directive" true) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "StdlibIndexError" true) (mem "applicabilityText" false) (mem "emptyStdlibIndex" false) (mem "maxApplicability" false) (mem "ruleMetaName" false))))
(DUse true (UseGroup ("tools" "lint_shared") ((mem "collectDirectives" false))))
(DUse true (UseGroup ("tools" "lint_dup") ((mem "fileDupOccs" false))))
(DUse true (UseGroup ("tools" "lint_registry") ((mem "allCrossFileRules" false) (mem "allRuleNames" false) (mem "allRules" false) (mem "crossFileMetaProblems" false) (mem "crossFileSelected" false) (mem "selectRules" false))))
(DUse true (UseGroup ("tools" "lint_walk") ((mem "applyFindingDeny" false) (mem "applyFindingFilters" false) (mem "applyFixes" false) (mem "applySuppressions" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsMultiDirs" false) (mem "buildStdlibIndexResult" false) (mem "crossFileCacheSound" false) (mem "factDirectives" false) (mem "factDupOccs" false) (mem "findingToDiag" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "lintFileDiagTripleParsed" false) (mem "lintParseSource" false) (mem "lintProgram" false) (mem "lintProgramFacts" false) (mem "lintToLines" false) (mem "mergeCrossFileIntoTriples" false) (mem "mkFileFacts" false) (mem "runCrossFileRules" false) (mem "runCrossFileRulesFromOccs" false) (mem "splitLintNames" false) (mem "stdlibFingerprint" false) (mem "stdlibIndexNeeded" false))))
(DTypeSig true "fixSource" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Applicability") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))))))
(DFunDef false "fixSource" ((PVar "idx") (PVar "limit") (PVar "only") (PVar "disable") (PVar "path") (PVar "src")) (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path")) (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))))) (arm (PCon "Ok" (PVar "parsed")) () (EBlock (DoLet false false (PVar "editRules") (EApp (EApp (EVar "filter") (EVar "emitsEdits")) (EApp (EApp (EVar "selectRules") (EVar "only")) (EVar "disable")))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "editRules")) (EApp (EApp (EApp (EApp (EApp (EVar "wholeDeclFix") (EVar "only")) (EVar "disable")) (EVar "src")) (ELit (LInt 0))) (EVar "parsed")) (EMatch (EApp (EApp (EApp (EApp (EVar "LF.applyFixes") (EApp (EApp (EApp (EApp (EVar "editLinter") (EVar "idx")) (EVar "editRules")) (EVar "src")) (EVar "parsed"))) (EVar "limit")) (EVar "path")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "LF.fixErrorText") (EVar "e")))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "edited") (PLit (LInt 0)))) () (EApp (EApp (EApp (EApp (EApp (EVar "wholeDeclFix") (EVar "only")) (EVar "disable")) (EVar "edited")) (ELit (LInt 0))) (EVar "parsed"))) (arm (PCon "Ok" (PTuple (PVar "edited") (PVar "n"))) () (EMatch (EApp (EVar "lintParseSource") (EVar "edited")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "edited")) (EVar "path")) (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))))) (arm (PCon "Ok" (PVar "reparsed")) () (EApp (EApp (EApp (EApp (EApp (EVar "wholeDeclFix") (EVar "only")) (EVar "disable")) (EVar "edited")) (EVar "n")) (EVar "reparsed"))))))))))))
(DTypeSig false "wholeDeclFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))))
(DFunDef false "wholeDeclFix" ((PVar "only") (PVar "disable") (PVar "src") (PVar "edited") (PTuple (PVar "decls") (PVar "pos"))) (EBlock (DoLet false false (PTuple (PVar "out") (PVar "adapted")) (EApp (EApp (EApp (EApp (EApp (EVar "applyFixes") (EVar "only")) (EVar "disable")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoExpr (EApp (EVar "Ok") (ETuple (EVar "out") (EBinOp "+" (EVar "edited") (EVar "adapted")))))))
(DTypeSig false "emitsEdits" (TyFun (TyCon "Rule") (TyCon "Bool")))
(DFunDef false "emitsEdits" ((PVar "r")) (EMatch (EFieldAccess (EFieldAccess (EVar "r") "meta") "fixability") (arm (PCon "Fixable") () (EApp (EVar "isNone") (EFieldAccess (EVar "r") "fix"))) (arm (PCon "NotFixable") () (EVar "False")) (arm PWild () (EVar "True"))))
(DTypeSig false "editLinter" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Finding"))))))))))
(DFunDef false "editLinter" ((PVar "idx") (PVar "rules") (PVar "first") (PVar "parsed") (PVar "path") (PVar "src")) (EIf (EBinOp "==" (EVar "src") (EVar "first")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EVar "editFindings") (EVar "idx")) (EVar "rules")) (EVar "path")) (EVar "src")) (EVar "parsed"))) (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path")) (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))))) (arm (PCon "Ok" (PVar "reparsed")) () (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EVar "editFindings") (EVar "idx")) (EVar "rules")) (EVar "path")) (EVar "src")) (EVar "reparsed")))))))
(DTypeSig false "editFindings" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "editFindings" ((PVar "idx") (PVar "rules") (PVar "path") (PVar "src") (PTuple (PVar "decls") (PVar "pos"))) (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoExpr (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "idx")) (EVar "rules")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls"))))))
# MARK
(DUse false (UseAlias ("tools" "lint_fix") "LF"))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "ppDiagCliSrc" false) (mem "parseErrDiag" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" false))))
(DUse false (UseGroup ("tools" "lint_walk") ((mem "lintParseSource" false) (mem "lintProgramFacts" false) (mem "mkFileFacts" false))))
(DUse false (UseGroup ("tools" "lint_registry") ((mem "selectRules" false))))
(DUse true (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "CrossFileRule" true) (mem "DirScope" true) (mem "Directive" true) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "StdlibIndexError" true) (mem "applicabilityText" false) (mem "emptyStdlibIndex" false) (mem "maxApplicability" false) (mem "ruleMetaName" false))))
(DUse true (UseGroup ("tools" "lint_shared") ((mem "collectDirectives" false))))
(DUse true (UseGroup ("tools" "lint_dup") ((mem "fileDupOccs" false))))
(DUse true (UseGroup ("tools" "lint_registry") ((mem "allCrossFileRules" false) (mem "allRuleNames" false) (mem "allRules" false) (mem "crossFileMetaProblems" false) (mem "crossFileSelected" false) (mem "selectRules" false))))
(DUse true (UseGroup ("tools" "lint_walk") ((mem "applyFindingDeny" false) (mem "applyFindingFilters" false) (mem "applyFixes" false) (mem "applySuppressions" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsMultiDirs" false) (mem "buildStdlibIndexResult" false) (mem "crossFileCacheSound" false) (mem "factDirectives" false) (mem "factDupOccs" false) (mem "findingToDiag" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "lintFileDiagTripleParsed" false) (mem "lintParseSource" false) (mem "lintProgram" false) (mem "lintProgramFacts" false) (mem "lintToLines" false) (mem "mergeCrossFileIntoTriples" false) (mem "mkFileFacts" false) (mem "runCrossFileRules" false) (mem "runCrossFileRulesFromOccs" false) (mem "splitLintNames" false) (mem "stdlibFingerprint" false) (mem "stdlibIndexNeeded" false))))
(DTypeSig true "fixSource" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Applicability") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int"))))))))))
(DFunDef false "fixSource" ((PVar "idx") (PVar "limit") (PVar "only") (PVar "disable") (PVar "path") (PVar "src")) (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path")) (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))))) (arm (PCon "Ok" (PVar "parsed")) () (EBlock (DoLet false false (PVar "editRules") (EApp (EApp (EMethodRef "filter") (EVar "emitsEdits")) (EApp (EApp (EVar "selectRules") (EVar "only")) (EVar "disable")))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "editRules")) (EApp (EApp (EApp (EApp (EApp (EVar "wholeDeclFix") (EVar "only")) (EVar "disable")) (EVar "src")) (ELit (LInt 0))) (EVar "parsed")) (EMatch (EApp (EApp (EApp (EApp (EVar "LF.applyFixes") (EApp (EApp (EApp (EApp (EVar "editLinter") (EVar "idx")) (EVar "editRules")) (EVar "src")) (EVar "parsed"))) (EVar "limit")) (EVar "path")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "LF.fixErrorText") (EVar "e")))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "edited") (PLit (LInt 0)))) () (EApp (EApp (EApp (EApp (EApp (EVar "wholeDeclFix") (EVar "only")) (EVar "disable")) (EVar "edited")) (ELit (LInt 0))) (EVar "parsed"))) (arm (PCon "Ok" (PTuple (PVar "edited") (PVar "n"))) () (EMatch (EApp (EVar "lintParseSource") (EVar "edited")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "edited")) (EVar "path")) (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))))) (arm (PCon "Ok" (PVar "reparsed")) () (EApp (EApp (EApp (EApp (EApp (EVar "wholeDeclFix") (EVar "only")) (EVar "disable")) (EVar "edited")) (EVar "n")) (EVar "reparsed"))))))))))))
(DTypeSig false "wholeDeclFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int")))))))))
(DFunDef false "wholeDeclFix" ((PVar "only") (PVar "disable") (PVar "src") (PVar "edited") (PTuple (PVar "decls") (PVar "pos"))) (EBlock (DoLet false false (PTuple (PVar "out") (PVar "adapted")) (EApp (EApp (EApp (EApp (EApp (EVar "applyFixes") (EVar "only")) (EVar "disable")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoExpr (EApp (EVar "Ok") (ETuple (EVar "out") (EBinOp "+" (EVar "edited") (EVar "adapted")))))))
(DTypeSig false "emitsEdits" (TyFun (TyCon "Rule") (TyCon "Bool")))
(DFunDef false "emitsEdits" ((PVar "r")) (EMatch (EFieldAccess (EFieldAccess (EVar "r") "meta") "fixability") (arm (PCon "Fixable") () (EApp (EVar "isNone") (EFieldAccess (EVar "r") "fix"))) (arm (PCon "NotFixable") () (EVar "False")) (arm PWild () (EVar "True"))))
(DTypeSig false "editLinter" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Finding"))))))))))
(DFunDef false "editLinter" ((PVar "idx") (PVar "rules") (PVar "first") (PVar "parsed") (PVar "path") (PVar "src")) (EIf (EBinOp "==" (EVar "src") (EVar "first")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EVar "editFindings") (EVar "idx")) (EVar "rules")) (EVar "path")) (EVar "src")) (EVar "parsed"))) (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path")) (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))))) (arm (PCon "Ok" (PVar "reparsed")) () (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EVar "editFindings") (EVar "idx")) (EVar "rules")) (EVar "path")) (EVar "src")) (EVar "reparsed")))))))
(DTypeSig false "editFindings" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "editFindings" ((PVar "idx") (PVar "rules") (PVar "path") (PVar "src") (PTuple (PVar "decls") (PVar "pos"))) (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoExpr (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "idx")) (EVar "rules")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls"))))))
