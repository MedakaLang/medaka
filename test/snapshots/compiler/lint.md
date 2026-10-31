# META
source_lines=190
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint.mdk — the `medaka lint` facade.  The framework lives in
-- `lint_core` (types), `lint_shared` (common helpers), the `lint_rule_*`
-- modules (rule bodies), `lint_registry` (THE REGISTRY) and `lint_walk` (the runner);
-- this module re-exports the surface the CLI, MCP server and tests consume.

import tools.lint_fix as LF
import driver.diagnostics.{ppDiagCliSrc, parseErrDiag}
import frontend.ast.{Decl}
import frontend.parser.{ParseError, Positions}
import tools.lint_walk.{
  lintParseSource,
  lintProgramFacts,
  mkFileFacts,
  mkFileFactsAt,
  withLocalMods,
}
import tools.lint_registry.{selectRules}

export import tools.lint_core.{
  Applicability(..),
  Category(..),
  ProjectRule(..),
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
  Summary(..),
  applicabilityText,
  emptyStdlibIndex,
  maxApplicability,
  mkStdlibIndex,
  projectIndexOf,
  ruleMetaName,
}
export import tools.lint_shared.{collectDirectives}
export import tools.lint_fix.{FixRun(..), fixPassLimit, runParts}
export import tools.lint_registry.{
  allProjectRules,
  allRuleNames,
  allRules,
  projectRuleMetaProblems,
  projectRuleSelected,
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
  buildProjectIndexResult,
  buildStdlibIndexResult,
  factDirectives,
  fileSummaries,
  findingToDiag,
  indexForRoster,
  indexForRun,
  indexKeyFor,
  isFindingError,
  lintFileDiagTriple,
  lintFileDiagTripleParsed,
  lintParseSource,
  lintProgram,
  lintProgramFacts,
  lintProgramRanked,
  lintToLines,
  mergeProjectIntoTriples,
  mkFileFacts,
  mkFileFactsAt,
  projectIndexNeeded,
  projectWildMods,
  ranked,
  rankedIndexRules,
  rosterNeeds,
  runProjectRules,
  runProjectRulesOver,
  splitByIndex,
  splitLintNames,
  stdlibIndexNeeded,
  stdlibIndexNeededFor,
  wildIndexNeeded,
}

-- ── fixing ───────────────────────────────────────────────────────────────────
-- A source fixed to its fixed point: the span edits of the active rules first,
-- then the whole-declaration fixers over the result.  Returns the fixed source
-- and the number of fixes made, or why it was left alone.  The CLI's `--fix` and
-- the fixture drivers share this one path.  `localMods` names the source's
-- `import m.*` modules that are files of the project (`projectWildMods`).
export
fixSource : StdlibIndex ->
  Applicability ->
  List String ->
  List String ->
  List String ->
  String ->
  String ->
  Result String LF.FixRun
fixSource idx limit only disable localMods path src = match lintParseSource src
  Err e => Err (parseFailure src path e)
  Ok parsed =>
    let editRules = filter emitsEdits (selectRules only disable)
    if isEmpty editRules then
      wholeDeclFix only disable (LF.Settled src 0) parsed
    else match (LF.applyFixes
      (editLinter idx editRules localMods src parsed)
      limit
      path
      src)
      Err e => Err "\{path}: \{LF.fixErrorText e}"
      Ok run => match LF.runParts run
        (_, 0) => wholeDeclFix only disable run parsed
        (edited, _) => match lintParseSource edited
          Err e => Err (parseFailure edited path e)
          Ok reparsed => wholeDeclFix only disable run reparsed

-- The whole-declaration fixers over the source `run` left, keeping its cap.
wholeDeclFix : List String ->
  List String ->
  LF.FixRun ->
  (List Decl, Positions) ->
  Result String LF.FixRun
wholeDeclFix only disable run (decls, pos) =
  let (edited, n) = LF.runParts run
  let (out, adapted) = applyFixes only disable edited decls pos
  Ok (LF.sameCap run out (n + adapted))

parseFailure : String -> String -> ParseError -> String
parseFailure src path e = ppDiagCliSrc src path (parseErrDiag path e)

-- The index the rules named by `only` are linted with: the CLI's when one of
-- them reads it, else the empty one.
export
indexForRules : List String -> <IO> Result String StdlibIndex
indexForRules only =
  if stdlibIndexNeeded only []
    || wildIndexNeeded only [] then match buildStdlibIndexResult
    Ok idx => Ok idx
    Err _ => Err "cannot build the stdlib index"
  else
    Ok emptyStdlibIndex

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
  List String ->
  String ->
  (List Decl, Positions) ->
  String ->
  String ->
  Result String (List Finding)
editLinter idx rules localMods first parsed path src =
  if src == first then
    Ok (editFindings idx rules localMods path src parsed)
  else match lintParseSource src
    Err e => Err (parseFailure src path e)
    Ok reparsed => Ok (editFindings idx rules localMods path src reparsed)

editFindings : StdlibIndex ->
  List Rule ->
  List String ->
  String ->
  String ->
  (List Decl, Positions) ->
  List Finding
editFindings idx rules localMods path src (decls, pos) =
  let facts = withLocalMods localMods (mkFileFacts src decls pos)
  applySuppressions src (lintProgramFacts idx rules path facts pos decls)
# DESUGAR
(DUse false (UseAlias ("tools" "lint_fix") "LF"))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "ppDiagCliSrc" false) (mem "parseErrDiag" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "ParseError" false) (mem "Positions" false))))
(DUse false (UseGroup ("tools" "lint_walk") ((mem "lintParseSource" false) (mem "lintProgramFacts" false) (mem "mkFileFacts" false) (mem "mkFileFactsAt" false) (mem "withLocalMods" false))))
(DUse false (UseGroup ("tools" "lint_registry") ((mem "selectRules" false))))
(DUse true (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "ProjectRule" true) (mem "DirScope" true) (mem "Directive" true) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "StdlibIndexError" true) (mem "Summary" true) (mem "applicabilityText" false) (mem "emptyStdlibIndex" false) (mem "maxApplicability" false) (mem "mkStdlibIndex" false) (mem "projectIndexOf" false) (mem "ruleMetaName" false))))
(DUse true (UseGroup ("tools" "lint_shared") ((mem "collectDirectives" false))))
(DUse true (UseGroup ("tools" "lint_fix") ((mem "FixRun" true) (mem "fixPassLimit" false) (mem "runParts" false))))
(DUse true (UseGroup ("tools" "lint_registry") ((mem "allProjectRules" false) (mem "allRuleNames" false) (mem "allRules" false) (mem "projectRuleMetaProblems" false) (mem "projectRuleSelected" false) (mem "selectRules" false))))
(DUse true (UseGroup ("tools" "lint_walk") ((mem "applyFindingDeny" false) (mem "applyFindingFilters" false) (mem "applyFixes" false) (mem "applySuppressions" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsMultiDirs" false) (mem "buildProjectIndexResult" false) (mem "buildStdlibIndexResult" false) (mem "factDirectives" false) (mem "fileSummaries" false) (mem "findingToDiag" false) (mem "indexForRoster" false) (mem "indexForRun" false) (mem "indexKeyFor" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "lintFileDiagTripleParsed" false) (mem "lintParseSource" false) (mem "lintProgram" false) (mem "lintProgramFacts" false) (mem "lintProgramRanked" false) (mem "lintToLines" false) (mem "mergeProjectIntoTriples" false) (mem "mkFileFacts" false) (mem "mkFileFactsAt" false) (mem "projectIndexNeeded" false) (mem "projectWildMods" false) (mem "ranked" false) (mem "rankedIndexRules" false) (mem "rosterNeeds" false) (mem "runProjectRules" false) (mem "runProjectRulesOver" false) (mem "splitByIndex" false) (mem "splitLintNames" false) (mem "stdlibIndexNeeded" false) (mem "stdlibIndexNeededFor" false) (mem "wildIndexNeeded" false))))
(DTypeSig true "fixSource" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Applicability") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "LF.FixRun"))))))))))
(DFunDef false "fixSource" ((PVar "idx") (PVar "limit") (PVar "only") (PVar "disable") (PVar "localMods") (PVar "path") (PVar "src")) (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "parseFailure") (EVar "src")) (EVar "path")) (EVar "e")))) (arm (PCon "Ok" (PVar "parsed")) () (EBlock (DoLet false false (PVar "editRules") (EApp (EApp (EVar "filter") (EVar "emitsEdits")) (EApp (EApp (EVar "selectRules") (EVar "only")) (EVar "disable")))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "editRules")) (EApp (EApp (EApp (EApp (EVar "wholeDeclFix") (EVar "only")) (EVar "disable")) (EApp (EApp (EVar "LF.Settled") (EVar "src")) (ELit (LInt 0)))) (EVar "parsed")) (EMatch (EApp (EApp (EApp (EApp (EVar "LF.applyFixes") (EApp (EApp (EApp (EApp (EApp (EVar "editLinter") (EVar "idx")) (EVar "editRules")) (EVar "localMods")) (EVar "src")) (EVar "parsed"))) (EVar "limit")) (EVar "path")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "LF.fixErrorText") (EVar "e")))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "run")) () (EMatch (EApp (EVar "LF.runParts") (EVar "run")) (arm (PTuple PWild (PLit (LInt 0))) () (EApp (EApp (EApp (EApp (EVar "wholeDeclFix") (EVar "only")) (EVar "disable")) (EVar "run")) (EVar "parsed"))) (arm (PTuple (PVar "edited") PWild) () (EMatch (EApp (EVar "lintParseSource") (EVar "edited")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "parseFailure") (EVar "edited")) (EVar "path")) (EVar "e")))) (arm (PCon "Ok" (PVar "reparsed")) () (EApp (EApp (EApp (EApp (EVar "wholeDeclFix") (EVar "only")) (EVar "disable")) (EVar "run")) (EVar "reparsed"))))))))))))))
(DTypeSig false "wholeDeclFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "LF.FixRun") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "LF.FixRun")))))))
(DFunDef false "wholeDeclFix" ((PVar "only") (PVar "disable") (PVar "run") (PTuple (PVar "decls") (PVar "pos"))) (EBlock (DoLet false false (PTuple (PVar "edited") (PVar "n")) (EApp (EVar "LF.runParts") (EVar "run"))) (DoLet false false (PTuple (PVar "out") (PVar "adapted")) (EApp (EApp (EApp (EApp (EApp (EVar "applyFixes") (EVar "only")) (EVar "disable")) (EVar "edited")) (EVar "decls")) (EVar "pos"))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "LF.sameCap") (EVar "run")) (EVar "out")) (EBinOp "+" (EVar "n") (EVar "adapted")))))))
(DTypeSig false "parseFailure" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "parseFailure" ((PVar "src") (PVar "path") (PVar "e")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path")) (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))))
(DTypeSig true "indexForRules" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "StdlibIndex")))))
(DFunDef false "indexForRules" ((PVar "only")) (EIf (EBinOp "||" (EApp (EApp (EVar "stdlibIndexNeeded") (EVar "only")) (EListLit)) (EApp (EApp (EVar "wildIndexNeeded") (EVar "only")) (EListLit))) (EMatch (EVar "buildStdlibIndexResult") (arm (PCon "Ok" (PVar "idx")) () (EApp (EVar "Ok") (EVar "idx"))) (arm (PCon "Err" PWild) () (EApp (EVar "Err") (ELit (LString "cannot build the stdlib index"))))) (EApp (EVar "Ok") (EVar "emptyStdlibIndex"))))
(DTypeSig false "emitsEdits" (TyFun (TyCon "Rule") (TyCon "Bool")))
(DFunDef false "emitsEdits" ((PVar "r")) (EMatch (EFieldAccess (EFieldAccess (EVar "r") "meta") "fixability") (arm (PCon "Fixable") () (EApp (EVar "isNone") (EFieldAccess (EVar "r") "fix"))) (arm (PCon "NotFixable") () (EVar "False")) (arm PWild () (EVar "True"))))
(DTypeSig false "editLinter" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Finding")))))))))))
(DFunDef false "editLinter" ((PVar "idx") (PVar "rules") (PVar "localMods") (PVar "first") (PVar "parsed") (PVar "path") (PVar "src")) (EIf (EBinOp "==" (EVar "src") (EVar "first")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "editFindings") (EVar "idx")) (EVar "rules")) (EVar "localMods")) (EVar "path")) (EVar "src")) (EVar "parsed"))) (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "parseFailure") (EVar "src")) (EVar "path")) (EVar "e")))) (arm (PCon "Ok" (PVar "reparsed")) () (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "editFindings") (EVar "idx")) (EVar "rules")) (EVar "localMods")) (EVar "path")) (EVar "src")) (EVar "reparsed")))))))
(DTypeSig false "editFindings" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")) (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "editFindings" ((PVar "idx") (PVar "rules") (PVar "localMods") (PVar "path") (PVar "src") (PTuple (PVar "decls") (PVar "pos"))) (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EVar "withLocalMods") (EVar "localMods")) (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "decls")) (EVar "pos")))) (DoExpr (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "idx")) (EVar "rules")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls"))))))
# MARK
(DUse false (UseAlias ("tools" "lint_fix") "LF"))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "ppDiagCliSrc" false) (mem "parseErrDiag" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "ParseError" false) (mem "Positions" false))))
(DUse false (UseGroup ("tools" "lint_walk") ((mem "lintParseSource" false) (mem "lintProgramFacts" false) (mem "mkFileFacts" false) (mem "mkFileFactsAt" false) (mem "withLocalMods" false))))
(DUse false (UseGroup ("tools" "lint_registry") ((mem "selectRules" false))))
(DUse true (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "ProjectRule" true) (mem "DirScope" true) (mem "Directive" true) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "StdlibIndexError" true) (mem "Summary" true) (mem "applicabilityText" false) (mem "emptyStdlibIndex" false) (mem "maxApplicability" false) (mem "mkStdlibIndex" false) (mem "projectIndexOf" false) (mem "ruleMetaName" false))))
(DUse true (UseGroup ("tools" "lint_shared") ((mem "collectDirectives" false))))
(DUse true (UseGroup ("tools" "lint_fix") ((mem "FixRun" true) (mem "fixPassLimit" false) (mem "runParts" false))))
(DUse true (UseGroup ("tools" "lint_registry") ((mem "allProjectRules" false) (mem "allRuleNames" false) (mem "allRules" false) (mem "projectRuleMetaProblems" false) (mem "projectRuleSelected" false) (mem "selectRules" false))))
(DUse true (UseGroup ("tools" "lint_walk") ((mem "applyFindingDeny" false) (mem "applyFindingFilters" false) (mem "applyFixes" false) (mem "applySuppressions" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsMultiDirs" false) (mem "buildProjectIndexResult" false) (mem "buildStdlibIndexResult" false) (mem "factDirectives" false) (mem "fileSummaries" false) (mem "findingToDiag" false) (mem "indexForRoster" false) (mem "indexForRun" false) (mem "indexKeyFor" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "lintFileDiagTripleParsed" false) (mem "lintParseSource" false) (mem "lintProgram" false) (mem "lintProgramFacts" false) (mem "lintProgramRanked" false) (mem "lintToLines" false) (mem "mergeProjectIntoTriples" false) (mem "mkFileFacts" false) (mem "mkFileFactsAt" false) (mem "projectIndexNeeded" false) (mem "projectWildMods" false) (mem "ranked" false) (mem "rankedIndexRules" false) (mem "rosterNeeds" false) (mem "runProjectRules" false) (mem "runProjectRulesOver" false) (mem "splitByIndex" false) (mem "splitLintNames" false) (mem "stdlibIndexNeeded" false) (mem "stdlibIndexNeededFor" false) (mem "wildIndexNeeded" false))))
(DTypeSig true "fixSource" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Applicability") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "LF.FixRun"))))))))))
(DFunDef false "fixSource" ((PVar "idx") (PVar "limit") (PVar "only") (PVar "disable") (PVar "localMods") (PVar "path") (PVar "src")) (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "parseFailure") (EVar "src")) (EVar "path")) (EVar "e")))) (arm (PCon "Ok" (PVar "parsed")) () (EBlock (DoLet false false (PVar "editRules") (EApp (EApp (EMethodRef "filter") (EVar "emitsEdits")) (EApp (EApp (EVar "selectRules") (EVar "only")) (EVar "disable")))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "editRules")) (EApp (EApp (EApp (EApp (EVar "wholeDeclFix") (EVar "only")) (EVar "disable")) (EApp (EApp (EVar "LF.Settled") (EVar "src")) (ELit (LInt 0)))) (EVar "parsed")) (EMatch (EApp (EApp (EApp (EApp (EVar "LF.applyFixes") (EApp (EApp (EApp (EApp (EApp (EVar "editLinter") (EVar "idx")) (EVar "editRules")) (EVar "localMods")) (EVar "src")) (EVar "parsed"))) (EVar "limit")) (EVar "path")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "LF.fixErrorText") (EVar "e")))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "run")) () (EMatch (EApp (EVar "LF.runParts") (EVar "run")) (arm (PTuple PWild (PLit (LInt 0))) () (EApp (EApp (EApp (EApp (EVar "wholeDeclFix") (EVar "only")) (EVar "disable")) (EVar "run")) (EVar "parsed"))) (arm (PTuple (PVar "edited") PWild) () (EMatch (EApp (EVar "lintParseSource") (EVar "edited")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "parseFailure") (EVar "edited")) (EVar "path")) (EVar "e")))) (arm (PCon "Ok" (PVar "reparsed")) () (EApp (EApp (EApp (EApp (EVar "wholeDeclFix") (EVar "only")) (EVar "disable")) (EVar "run")) (EVar "reparsed"))))))))))))))
(DTypeSig false "wholeDeclFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "LF.FixRun") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "LF.FixRun")))))))
(DFunDef false "wholeDeclFix" ((PVar "only") (PVar "disable") (PVar "run") (PTuple (PVar "decls") (PVar "pos"))) (EBlock (DoLet false false (PTuple (PVar "edited") (PVar "n")) (EApp (EVar "LF.runParts") (EVar "run"))) (DoLet false false (PTuple (PVar "out") (PVar "adapted")) (EApp (EApp (EApp (EApp (EApp (EVar "applyFixes") (EVar "only")) (EVar "disable")) (EVar "edited")) (EVar "decls")) (EVar "pos"))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "LF.sameCap") (EVar "run")) (EVar "out")) (EBinOp "+" (EVar "n") (EVar "adapted")))))))
(DTypeSig false "parseFailure" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "parseFailure" ((PVar "src") (PVar "path") (PVar "e")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path")) (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))))
(DTypeSig true "indexForRules" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "StdlibIndex")))))
(DFunDef false "indexForRules" ((PVar "only")) (EIf (EBinOp "||" (EApp (EApp (EVar "stdlibIndexNeeded") (EVar "only")) (EListLit)) (EApp (EApp (EVar "wildIndexNeeded") (EVar "only")) (EListLit))) (EMatch (EVar "buildStdlibIndexResult") (arm (PCon "Ok" (PVar "idx")) () (EApp (EVar "Ok") (EVar "idx"))) (arm (PCon "Err" PWild) () (EApp (EVar "Err") (ELit (LString "cannot build the stdlib index"))))) (EApp (EVar "Ok") (EVar "emptyStdlibIndex"))))
(DTypeSig false "emitsEdits" (TyFun (TyCon "Rule") (TyCon "Bool")))
(DFunDef false "emitsEdits" ((PVar "r")) (EMatch (EFieldAccess (EFieldAccess (EVar "r") "meta") "fixability") (arm (PCon "Fixable") () (EApp (EVar "isNone") (EFieldAccess (EVar "r") "fix"))) (arm (PCon "NotFixable") () (EVar "False")) (arm PWild () (EVar "True"))))
(DTypeSig false "editLinter" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Finding")))))))))))
(DFunDef false "editLinter" ((PVar "idx") (PVar "rules") (PVar "localMods") (PVar "first") (PVar "parsed") (PVar "path") (PVar "src")) (EIf (EBinOp "==" (EVar "src") (EVar "first")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "editFindings") (EVar "idx")) (EVar "rules")) (EVar "localMods")) (EVar "path")) (EVar "src")) (EVar "parsed"))) (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "parseFailure") (EVar "src")) (EVar "path")) (EVar "e")))) (arm (PCon "Ok" (PVar "reparsed")) () (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "editFindings") (EVar "idx")) (EVar "rules")) (EVar "localMods")) (EVar "path")) (EVar "src")) (EVar "reparsed")))))))
(DTypeSig false "editFindings" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")) (TyApp (TyCon "List") (TyCon "Finding")))))))))
(DFunDef false "editFindings" ((PVar "idx") (PVar "rules") (PVar "localMods") (PVar "path") (PVar "src") (PTuple (PVar "decls") (PVar "pos"))) (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EVar "withLocalMods") (EVar "localMods")) (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "decls")) (EVar "pos")))) (DoExpr (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramFacts") (EVar "idx")) (EVar "rules")) (EVar "path")) (EVar "facts")) (EVar "pos")) (EVar "decls"))))))
