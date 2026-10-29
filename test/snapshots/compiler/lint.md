# META
source_lines=59
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint.mdk — the `medaka lint` facade.  The framework lives in
-- `lint_core` (types), `lint_shared` (common helpers), `lint_rules_staging`
-- (rule bodies), `lint_registry` (THE REGISTRY) and `lint_walk` (the runner);
-- this module re-exports the surface the CLI, MCP server and tests consume.

export import tools.lint_core.{
  Category(..),
  CrossFileRule(..),
  DirScope(..),
  Directive(..),
  Finding(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule(..),
  RuleMeta(..),
  Scope(..),
  StdlibIndex(..),
  StdlibIndexError(..),
  emptyStdlibIndex,
  ruleMetaName,
}
export import tools.lint_shared.{collectDirectives}
export import tools.lint_rules_staging.{fileDupOccs}
export import tools.lint_registry.{
  allCrossFileRules,
  allRuleNames,
  allRules,
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
# DESUGAR
(DUse true (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "CrossFileRule" true) (mem "DirScope" true) (mem "Directive" true) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "StdlibIndexError" true) (mem "emptyStdlibIndex" false) (mem "ruleMetaName" false))))
(DUse true (UseGroup ("tools" "lint_shared") ((mem "collectDirectives" false))))
(DUse true (UseGroup ("tools" "lint_rules_staging") ((mem "fileDupOccs" false))))
(DUse true (UseGroup ("tools" "lint_registry") ((mem "allCrossFileRules" false) (mem "allRuleNames" false) (mem "allRules" false) (mem "crossFileSelected" false) (mem "selectRules" false))))
(DUse true (UseGroup ("tools" "lint_walk") ((mem "applyFindingDeny" false) (mem "applyFindingFilters" false) (mem "applyFixes" false) (mem "applySuppressions" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsMultiDirs" false) (mem "buildStdlibIndexResult" false) (mem "crossFileCacheSound" false) (mem "factDirectives" false) (mem "factDupOccs" false) (mem "findingToDiag" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "lintFileDiagTripleParsed" false) (mem "lintParseSource" false) (mem "lintProgram" false) (mem "lintProgramFacts" false) (mem "lintToLines" false) (mem "mergeCrossFileIntoTriples" false) (mem "mkFileFacts" false) (mem "runCrossFileRules" false) (mem "runCrossFileRulesFromOccs" false) (mem "splitLintNames" false) (mem "stdlibFingerprint" false) (mem "stdlibIndexNeeded" false))))
# MARK
(DUse true (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "CrossFileRule" true) (mem "DirScope" true) (mem "Directive" true) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "StdlibIndexError" true) (mem "emptyStdlibIndex" false) (mem "ruleMetaName" false))))
(DUse true (UseGroup ("tools" "lint_shared") ((mem "collectDirectives" false))))
(DUse true (UseGroup ("tools" "lint_rules_staging") ((mem "fileDupOccs" false))))
(DUse true (UseGroup ("tools" "lint_registry") ((mem "allCrossFileRules" false) (mem "allRuleNames" false) (mem "allRules" false) (mem "crossFileSelected" false) (mem "selectRules" false))))
(DUse true (UseGroup ("tools" "lint_walk") ((mem "applyFindingDeny" false) (mem "applyFindingFilters" false) (mem "applyFixes" false) (mem "applySuppressions" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsMultiDirs" false) (mem "buildStdlibIndexResult" false) (mem "crossFileCacheSound" false) (mem "factDirectives" false) (mem "factDupOccs" false) (mem "findingToDiag" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "lintFileDiagTripleParsed" false) (mem "lintParseSource" false) (mem "lintProgram" false) (mem "lintProgramFacts" false) (mem "lintToLines" false) (mem "mergeCrossFileIntoTriples" false) (mem "mkFileFacts" false) (mem "runCrossFileRules" false) (mem "runCrossFileRulesFromOccs" false) (mem "splitLintNames" false) (mem "stdlibFingerprint" false) (mem "stdlibIndexNeeded" false))))
