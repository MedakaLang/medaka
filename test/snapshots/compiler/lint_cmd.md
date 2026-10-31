# META
source_lines=1138
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_cmd.mdk — the `medaka lint` engine.
--
-- Everything the verb does once its flags are already parsed: resolving the
-- target set, the per-file pass (fresh or from the `--cache` shards), the
-- project-rule tier, baseline promotion at application time, and the `--json`
-- envelope.  `medaka_cli.mdk` keeps `runLintCmd` and the flag/target
-- assertions because they call `requireArgs`/`optDefault`/`dieMsg`, which are
-- defined there and shared with the other verbs; importing them here would
-- make `driver` -> `tools` -> `driver` a cycle the loader rejects.
-- `lintArgSpec` is a spec VALUE, not a caller, so the cycle does not pin it: it
-- stays only because the two gates that police argv surfaces name
-- `medaka_cli.mdk` in their `sources`.  `lintHelpText` lives here, with the
-- `--list-rules`/`--explain` views of the registry.
--
-- Rule implementations are not here either: the `Rule`/`ProjectRule` types
-- live in `tools/lint_core.mdk`, the rules in the `tools/lint_rule_*` modules
-- listed by `tools/lint_registry.mdk`, the per-file runner in
-- `tools/lint_walk.mdk`, the cache format in `tools/lint_cache.mdk`, and the
-- count baseline in `tools/lint_baseline.mdk`.  This module only sequences them.

import support.util.{anyList, contains, joinNl, joinWith, lookupAssoc}
import support.path.{dirOf}
import support.ordmap.{OrdMap, omEmpty, omInsert, omLookup}
import string as Str
import json.{Json(..), jArray, jObject, stringify}
import frontend.ast.{Decl, Loc(..)}
import frontend.parser.{ParseError, Positions}
import driver.loader.{
  findProjectRoot,
  findProjectRootOrSelf,
  manifestLintInternal,
  readSource,
}
import driver.diagnostics.{
  Diag,
  cjAllToJson,
  ppSeverity,
  diagIsError,
  ppDiagCliLines,
  ppDiagCliSrc,
  srcLinesArr,
  parseErrDiag,
}
import support.cli_targets.{collectMdkFiles, expandLintTarget}
import support.stage_count.{stageExit}
import tools.lint.{
  Applicability(..),
  Category(..),
  ProjectRule(..),
  Directive,
  Finding,
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule(..),
  RuleMeta(..),
  Scope(..),
  Summary,
  applicabilityText,
  maxApplicability,
  ruleMetaName,
  allProjectRules,
  StdlibIndex,
  allRules,
  applyFindingDeny,
  applyFindingFilters,
  applySuppressionsDirs,
  applySuppressionsMulti,
  applySuppressionsMultiDirs,
  factDirectives,
  fileSummaries,
  findingToDiag,
  fixPassLimit,
  fixSource,
  FixRun(..),
  runParts,
  isFindingError,
  lintFileDiagTriple,
  lintFileDiagTripleParsed,
  lintParseSource,
  lintProgramRanked,
  indexKeyFor,
  rankedIndexRules,
  splitByIndex,
  mkFileFacts,
  mkFileFactsAt,
  projectWildMods,
  projectRuleSelected,
  ranked,
  selectRules,
  mergeProjectIntoTriples,
  runProjectRules,
}
import tools.lint_core.{
  recordingStdlibIndex,
  stdlibRecorded,
  stdlibAnswersHold,
}
import tools.lint_cache.{
  LintEntry(..),
  ShardLoad(..),
  cacheDirOf,
  contentHashOf,
  entryFindings,
  loadEntry,
  ruleSetStamp,
}
import tools.lint_baseline.{
  LintBaseline,
  applyBaselineToDiags,
  applyBaselineToFindings,
  baselineDiagViolations,
  baselineKeyOf,
  baselineViolationLine,
  baselineViolations,
  diagCodeOf,
  findingRuleOf,
}

-- ── `medaka lint --help`, `--list-rules`, `--explain` ──────────────────────────
-- The flag surface is declared by `lintArgSpec` in `medaka_cli.mdk`; the text
-- and the registry views the flags print live here, next to the verb's engine.

export
lintHelpText : String
lintHelpText = stringConcat [
  "medaka lint — Lint files/dirs against style rules\n", "\n", "Usage:\n",
  "  medaka lint [paths...] [flags]\n",
  "  medaka lint --list-rules [filters] [--json|--markdown]\n",
  "  medaka lint --explain <rule>\n", "\n",
  "  --fix                 rewrite fixable findings in-place\n",
  "  --unsafe-fixes        with --fix: also apply fixes that may change behavior\n",
  "  --json                emit the {\"files\":[...]} structured-diagnostics\n",
  "                       envelope instead of human text (--fix is ignored)\n",
  "  --cache                reuse per-file results for files whose content is\n",
  "                       unchanged (opt-in, like ESLint's --cache)\n",
  "  --disable=r1,r2,...    suppress findings from the named rules\n",
  "  --only=r1,...          keep only findings from the named rules\n",
  "  --deny=r1,...          promote findings from the named rules to error\n",
  "  --baseline=<file>      error only where a file's per-rule finding count\n",
  "                       exceeds its row in <file> (counts may fall freely)\n",
  "  --write-baseline=<f>   regenerate <f> from this run instead of reporting\n",
  "  --list-rules           list every rule with its metadata (--json for the\n",
  "                       machine form, --markdown for docs/ops/LINT-RULES.md)\n",
  "  --scope=universal|internal     with --list-rules: keep one scope\n",
  "  --ratchet=gated|baselined      with --list-rules: keep one ratchet\n",
  "  --tier=file|cross              with --list-rules: keep one rule tier\n",
  "  --names                with --list-rules: print only the names, one per line\n",
  "  --explain <rule>       print a rule's summary and documentation\n",
  "  --internal             run the internal-scope rules on every target (they are\n",
  "                       otherwise on only under a manifest with [lint] internal = true)\n",
  "\n", "Target resolution: explicit file args are linted in order; a single\n",
  "directory arg lints its top-level .mdk files (not recursive); no args\n",
  "finds the medaka.toml project root and lints its top-level .mdk files.\n",
  "Exit 0 unless a SevError finding exists.\n"
]

-- One distinct rule name with the tiers it is registered in.  `rule-duplicate-body`
-- is registered twice (a same-file `Rule` and the `ProjectRule`) under one name
-- and appears once here, with both tiers; its per-file metadata is the row's.
export data RuleRow = RuleRow { rrMeta : RuleMeta, rrTiers : List Tier }

-- Which registry a rule is registered in: the per-file `allRules`, the
-- project-rule `allProjectRules`, or both.
export data Tier = TierFile | TierCross deriving (Eq)

tierText : Tier -> String
tierText TierFile = "file"
tierText TierCross = "cross"

export
allRuleRows : List RuleRow
allRuleRows =
  let fileMetas = map ruleMetaOf allRules
  let crossMetas = map crossMetaOf allProjectRules
  let fileNames = map ruleMetaName fileMetas
  let crossNames = map ruleMetaName crossMetas
  let crossOnly =
    filter (m => not (contains (ruleMetaName m) fileNames)) crossMetas
  map (m => mkRow m (tiersOf (ruleMetaName m) crossNames)) fileMetas
    ++ map (m => mkRow m [TierCross]) crossOnly

ruleMetaOf : Rule -> RuleMeta
ruleMetaOf r = r.meta

crossMetaOf : ProjectRule -> RuleMeta
crossMetaOf r = r.meta

mkRow : RuleMeta -> List Tier -> RuleRow
mkRow m tiers = RuleRow { rrMeta = m, rrTiers = tiers }

rowName : RuleRow -> String
rowName row = ruleMetaName row.rrMeta

tiersText : List Tier -> String
tiersText tiers = joinWith "," (map tierText tiers)

tiersOf : String -> List String -> List Tier
tiersOf n crossNames
  | contains n crossNames = [TierFile, TierCross]
  | otherwise = [TierFile]

scopeText : Scope -> String
scopeText Universal = "universal"
scopeText Internal = "internal"

ratchetText : Ratchet -> String
ratchetText Gated = "gated"
ratchetText Baselined = "baselined"

categoryText : Category -> String
categoryText Correctness = "correctness"
categoryText Suspicious = "suspicious"
categoryText Perf = "perf"
categoryText Complexity = "complexity"
categoryText Style = "style"

fixabilityText : Fixability -> String
fixabilityText Fixable = "fixable"
fixabilityText FixableUnsafe = "fixable-unsafe"
fixabilityText SuggestOnly = "suggest-only"
fixabilityText NotFixable = "not-fixable"

needText : Need -> String
needText NeedsStdlibIndex = "stdlib-index"
needText NeedsProjectIndex = "project-index"
needText NeedsWildIndex = "wildcard-index"
needText NeedsScopes = "scopes"

-- `--scope`/`--ratchet`/`--tier` narrow the listing; an unrecognised value is an
-- error naming the accepted ones, never an empty listing that reads as "none".
export
selectRuleRows : Option String ->
  Option String ->
  Option String ->
  Result String (List RuleRow)
selectRuleRows scope ratchet tier = do
  s <- checkChoice "--scope" (choicesOf scopeText [Universal, Internal]) scope
  r <- checkChoice
    "--ratchet"
    (choicesOf ratchetText [Gated, Baselined])
    ratchet
  t <- checkChoice "--tier" (choicesOf tierText [TierFile, TierCross]) tier
  Ok (filter (rowMatches s r t) allRuleRows)

choicesOf : (a -> String) -> List a -> List (String, a)
choicesOf render values = map (v => (render v, v)) values

checkChoice : String ->
  List (String, a) ->
  Option String ->
  Result String (Option a)
checkChoice _ _ None = Ok None
checkChoice flagName choices (Some v) = match lookupAssoc v choices
  Some value => Ok (Some value)
  None =>
    Err
      "\{flagName} must be one of \{joinWith ", " (map fst choices)}, got `\{v}`"

rowMatches : Option Scope -> Option Ratchet -> Option Tier -> RuleRow -> Bool
rowMatches s r t row =
  optMatches s row.rrMeta.scope
    && optMatches r row.rrMeta.ratchet
    && (match t
      None => True
      Some v => elem v row.rrTiers)

optMatches : Eq a => Option a -> a -> Bool
optMatches None _ = True
optMatches (Some v) actual = v == actual

-- Just the rule names, one per line: the form shell consumers read.
export
renderRuleRowsNames : List RuleRow -> String
renderRuleRowsNames rows = joinNl (map rowName rows) ++ "\n"

-- One tab-separated line per rule: name, scope, category, ratchet, fixability,
-- tiers, summary.
export
renderRuleRowsText : List RuleRow -> String
renderRuleRowsText rows = joinNl (map ruleRowLine rows) ++ "\n"

ruleRowLine : RuleRow -> String
ruleRowLine row =
  let m = row.rrMeta
  joinWith "\t" [
    m.name,
    scopeText m.scope,
    categoryText m.category,
    ratchetText m.ratchet,
    fixabilityText m.fixability,
    tiersText row.rrTiers,
    m.summary,
  ]

export
renderRuleRowsJson : List RuleRow -> String
renderRuleRowsJson rows =
  stringify (jObject [("rules", jArray (map ruleRowJson rows))]) ++ "\n"

ruleRowJson : RuleRow -> Json
ruleRowJson row =
  let m = row.rrMeta
  jObject [
    ("name", JString m.name),
    ("summary", JString m.summary),
    ("doc", JString m.doc),
    ("category", JString (categoryText m.category)),
    ("scope", JString (scopeText m.scope)),
    ("ratchet", JString (ratchetText m.ratchet)),
    ("severity", JString (ppSeverity m.defaultSeverity)),
    ("fixability", JString (fixabilityText m.fixability)),
    (
      "maxApplicability",
      optionOr
        JNull
        (map
          (a => JString (applicabilityText a))
          (maxApplicability m.fixability)),
    ),
    ("needs", jArray (map (n => JString (needText n)) m.needs)),
    ("tiers", jArray (map (t => JString (tierText t)) row.rrTiers)),
  ]

-- `--explain <rule>`: the summary, the documentation, then the classification.
-- An unknown name is an `Err` that offers the first registered rule whose name
-- contains the argument, when there is one.
export
explainRule : String -> Result String String
explainRule q = match filter (row => rowName row == q) allRuleRows
  row :: _ => Ok (explainText row)
  [] =>
    let near = filter (row => Str.contains q (rowName row)) allRuleRows
    match near
      row :: _ => Err "unknown rule `\{q}` (did you mean `\{rowName row}`?)"
      [] => Err "unknown rule `\{q}` (see `medaka lint --list-rules`)"

explainText : RuleRow -> String
explainText row =
  let m = row.rrMeta
  joinNl [
    m.name,
    "",
    m.summary,
    "",
    m.doc,
    "",
    "scope: \{scopeText m.scope}  category: \{categoryText m.category}  ratchet: \{ratchetText m.ratchet}  fixability: \{fixabilityText m.fixability}  tiers: \{tiersText row.rrTiers}",
  ]

-- The generated page `docs/ops/LINT-RULES.md`.  The `lint_test.mdk` test
-- "docs/ops/LINT-RULES.md matches the registry" compares the checked-in page
-- with this text.
export
rulesPageMarkdown : String
rulesPageMarkdown =
  joinNl
      ([
          "# Lint rules",
          "",
          "<!-- Generated by `medaka lint --list-rules --markdown`. Do not edit by hand. -->",
          "",
          "Every rule `medaka lint` knows. `universal` rules are meaningful in any Medaka program; `internal` rules enforce this repository's own conventions. `gated` rules must have zero findings across the enforced tree; `baselined` rules may only fall (`docs/ops/CLI-CONFORMANCE.md`, `.githooks/pre-commit`). Per-rule detail: `medaka lint --explain <rule>`.",
          "",
          "| Rule | Scope | Category | Ratchet | Fix | Tiers |",
          "|---|---|---|---|---|---|",
        ]
        ++ map rulesPageTableRow allRuleRows
        ++ flatMap rulesPageSection allRuleRows)
    ++ "\n"

rulesPageTableRow : RuleRow -> String
rulesPageTableRow row =
  let m = row.rrMeta
  "| [`\{m.name}`](#\{m.name}) | \{scopeText m.scope} | \{categoryText m.category} | \{ratchetText m.ratchet} | \{fixabilityText m.fixability} | \{joinWith ", " (map tierText row.rrTiers)} |"

rulesPageSection : RuleRow -> List String
rulesPageSection row =
  let m = row.rrMeta
  ["", "## \{m.name}", "", m.summary, ""] ++ docBody m.doc

-- Prose before the first `Before:` stays prose; the example goes in a fence.
docBody : String -> List String
docBody doc = match Str.indexOf "\n\nBefore:" doc
  None => [doc]
  Some i =>
    [Str.take i doc, "", "```"] ++ Str.lines (Str.drop (i + 2) doc) ++ ["```"]

-- Resolve `--cache` to `Some (cacheDir, ruleSetStamp)`, or `None` to run
-- uncached.  `--fix` (and `--json`, which never reaches here) is out of v1
-- scope: --fix REWRITES the files whose content is the cache key, and ESLint's
-- --cache+--fix is a known sharp edge; --json is a separate per-file path.
-- Combining --cache with either is a silent no-op, not an error.
--
-- The cache dir hangs off the project root — the same `medaka.toml` walk-up the
-- rest of the CLI uses, which falls back to the cwd when there is no manifest
-- (the repo root case: `medaka lint compiler stdlib sqlite` runs where no
-- medaka.toml sits, and lands the cache at the repo root, which is what the
-- pre-commit hook wants).  A cache dir that resolves somewhere unexpected costs
-- misses, never wrong answers.
--
-- The stamp is the binary alone.  What the declaration index contributes is a
-- separate key on the shard's index-reading findings (`indexKeyFor`), so an
-- edit to a stdlib file re-runs only the rules that read the index.
export
lintCacheCtx : Bool -> Bool -> <IO> Option (String, String)
lintCacheCtx False _ = None
lintCacheCtx True True = None
lintCacheCtx True False =
  let root = findProjectRootOrSelf (canonicalizePath ".")
  let binStamp = ruleSetStamp ()
  -- An empty stamp means the binary could not be read, so the rule set cannot
  -- be identified — the one input that makes a hit meaningful is missing.
  -- Decline rather than share a cache across unknown rule sets.
  if binStamp == "" then None else Some (cacheDirOf root, binStamp)

-- `medaka lint --json`: run the lint pipeline over every resolved target file
-- and emit the SAME `{"files":[{"file":...,"diagnostics":[...]}]}` envelope
-- `medaka check --json` emits (via `cjAllToJson`) — one schema for both
-- surfaces (#249).  Each `Finding` becomes a `Diag` via `findingToDiag`
-- (inside `lintFileDiagTripleParsed`), which stamps the lint RULE NAME into
-- the diagnostic's `code` field.  Cross-file rules DO participate (#2701
-- leg 3): the per-file pass already parses every target
-- (`lintFileDiagTripleParsed`), and `--json` summarizes those parses and
-- evaluates the project rules over them (the human-text path reaches the tier
-- from entries instead, see `runProjectReport`).  Each
-- resulting `Finding` is folded into its OWN file's `diagnostics` array via
-- `mergeProjectIntoTriples` (never a new top-level key).  A duplicate whose
-- partner file lay outside `files` would be folded into a synthesized entry
-- for that file instead — `mergeProjectIntoTriples`'s own defensive
-- fallback, unreachable today since `files` is exactly the set every
-- project rule here runs over.  `--fix` never reaches this function.
-- Exit 1 iff any diagnostic is a
-- hard error (severity 1) — matches `runCheckJsonCmd`'s convention.
export
runLintJsonCmd : StdlibIndex ->
  Bool ->
  List String ->
  List String ->
  List String ->
  Option (String, LintBaseline) ->
  List String ->
  <IO> Unit
runLintJsonCmd idx internalFlag disableNames onlyNames denyNames baseCtx files =
  let quads =
    lintFilesToDiagQuads
      idx
      internalFlag
      disableNames
      onlyNames
      denyNames
      baseCtx
      files
  let triples = map dropQuadParse quads
  let cross =
    projectJsonFindings idx internalFlag disableNames onlyNames denyNames quads
  let merged = mergeProjectIntoTriples cross triples
  let _ = putStr (cjAllToJson merged)
  if anyList cjLintTripleHasErr merged then stageExit 1

-- The project-rule tier's JSON-path inputs, reused from the per-file parses
-- already sitting in `quads` (#394's no-second-read rule applies here too).
-- Mirrors `runProjectReport`: `--only`/`--disable` are honored inside
-- `runProjectRules`, inline `-- lint-disable-*` directives are applied via
-- `applySuppressionsMulti` (each finding anchors to its own file), then
-- `--deny` promotion.  Unlike the text path this never renders — the caller
-- folds the result into the JSON triples instead.  Exported so
-- `compiler/tools/lint_test.mdk`'s renderer-parity property can call the SAME
-- function `runLintJsonCmd` calls, rather than a reimplementation.
export
projectJsonFindings : StdlibIndex ->
  Bool ->
  List String ->
  List String ->
  List String ->
  List (String, String, List Diag, Positions, List Decl) ->
  <IO> List Finding
projectJsonFindings idx internalFlag disableNames onlyNames denyNames quads =
  let summaries = map (quadSummaries onlyNames disableNames) quads
  let raw = runProjectRules onlyNames disableNames idx summaries
  let active = dropInactiveInternalProject allProjectRules internalFlag raw
  let suppressed = applySuppressionsMulti (map quadToSrc quads) active
  applyFindingDeny denyNames suppressed

-- A parsed file's project-rule summaries, from the parse alone.
export
quadSummaries : List String ->
  List String ->
  (String, String, List Diag, Positions, List Decl) ->
  (String, List (String, Summary))
quadSummaries only disable (path, src, _, pos, decls) =
  (path, fileSummaries only disable path (mkFileFacts src decls pos) pos decls)

export
quadToSrc : (String, String, List Diag, Positions, List Decl) ->
  (String, String)
quadToSrc (path, src, _, _, _) = (path, src)

dropQuadParse : (String, String, List Diag, Positions, List Decl) ->
  (String, String, List Diag)
dropQuadParse (path, src, diags, _, _) = (path, src, diags)

-- Sequence `lintFileDiagTripleParsed` over every target file, in order,
-- applying baseline promotion to the diagnostics while carrying the parse
-- along untouched — the cross-file tier's input.  Mirrors `lintFilesGo`'s
-- explicit recursion — this codebase sequences an `<IO>` list traversal by
-- hand, not via `map` over an effectful function.  Exported for the same
-- reason as `projectJsonFindings` above.
export
lintFilesToDiagQuads : StdlibIndex ->
  Bool ->
  List String ->
  List String ->
  List String ->
  Option (String, LintBaseline) ->
  List String ->
  <IO> List (String, String, List Diag, Positions, List Decl)
lintFilesToDiagQuads _ _ _ _ _ _ [] = []
lintFilesToDiagQuads idx internalFlag disable only deny baseCtx (f :: rest) =
  let fileDisable = disable ++ internalDisabledFor internalFlag f
  applyBaselineQuad
      baseCtx
      (lintFileDiagTripleParsed idx fileDisable only deny f)
    :: lintFilesToDiagQuads idx internalFlag disable only deny baseCtx rest

applyBaselineQuad : Option (String, LintBaseline) ->
  (String, String, List Diag, Positions, List Decl) ->
  <IO> (String, String, List Diag, Positions, List Decl)
applyBaselineQuad None quad = quad
applyBaselineQuad (Some (cwd, base)) (path, src, diags, pos, decls) =
  let key = baselineKeyOf cwd path
  let _ = reportBaselineViolations key (baselineDiagViolations base key diags)
  (path, src, applyBaselineToDiags base key diags, pos, decls)

-- Sequence `lintFileDiagTriple` over every target file, in order.  Mirrors
-- `lintFilesGo`'s explicit recursion — this codebase sequences an `<IO>`
-- list traversal by hand, not via `map` over an effectful function.  Used by
-- `--write-baseline`, which needs only the per-file diagnostics, not the
-- cross-file tier's parse inputs.
export
lintFilesToDiagTriples : StdlibIndex ->
  Bool ->
  List String ->
  List String ->
  List String ->
  Option (String, LintBaseline) ->
  List String ->
  <IO> List (String, String, List Diag)
lintFilesToDiagTriples _ _ _ _ _ _ [] = []
lintFilesToDiagTriples idx internalFlag disable only deny baseCtx (f :: rest) =
  let fileDisable = disable ++ internalDisabledFor internalFlag f
  applyBaselineTriple baseCtx (lintFileDiagTriple idx fileDisable only deny f)
    :: lintFilesToDiagTriples idx internalFlag disable only deny baseCtx rest

-- The `--json` half of the baseline promotion.  Reports the same stderr lines
-- the text path does: stdout stays exactly one JSON document (C4), so a machine
-- consumer that only reads the envelope still sees the promoted severity, and a
-- human reading the terminal still learns which count moved.
applyBaselineTriple : Option (String, LintBaseline) ->
  (String, String, List Diag) ->
  <IO> (String, String, List Diag)
applyBaselineTriple None triple = triple
applyBaselineTriple (Some (cwd, base)) (path, src, diags) =
  let key = baselineKeyOf cwd path
  let _ = reportBaselineViolations key (baselineDiagViolations base key diags)
  (path, src, applyBaselineToDiags base key diags)

cjLintTripleHasErr : (String, String, List Diag) -> Bool
cjLintTripleHasErr (_, _, diags) = anyList diagIsError diags

applyBaselineFindings : Option (String, LintBaseline) ->
  String ->
  List Finding ->
  <IO> List Finding
applyBaselineFindings None _ findings = findings
applyBaselineFindings (Some (cwd, base)) target findings =
  let key = baselineKeyOf cwd target
  let _ =
    reportBaselineViolations
      key
      (baselineViolations base key (map findingRuleOf findings))
  applyBaselineToFindings base key findings

-- On stderr, beside the promoted findings on stdout: the finding text says what
-- the rule found, this says which count moved and what it was allowed to be.
reportBaselineViolations : String -> List (String, Int, Option Int) -> <IO> Unit
reportBaselineViolations _ [] = ()
reportBaselineViolations key (v :: rest) =
  let _ = ePutStrLn "medaka lint: baseline: \{baselineViolationLine key v}"
  reportBaselineViolations key rest

export
baselineFileCodes : String ->
  (String, String, List Diag) ->
  (String, List String)
baselineFileCodes cwd (path, _, diags) =
  (baselineKeyOf cwd path, map diagCodeOf diags)

-- Run the project-rule tier over the whole set from the summaries the per-file
-- pass produced, cached and fresh alike: a cache hit has no parse to give the
-- tier, and a summary is all the tier reads.  Findings render AFTER the
-- per-file output under a `cross-file:` header.  --only/--disable are honored
-- inside `runProjectRules`; --deny promotion is applied here (mirrors the
-- per-file path).  Directives are the entries' own (already parsed, cached or
-- fresh).  Returns whether any finding is an error severity (feeds the exit
-- code).
--
-- The evaluation runs every time, over ALL files.  Only its per-file INPUTS are
-- cached.  A duplicate-body finding names file A because of file B, so caching
-- these findings would leave A's finding standing after B stopped duplicating
-- it — A is unchanged, so A hits.  Scenario 3 of
-- test/diff_compiler_lint_cache.sh is exactly that edit and exists to catch
-- anyone who tries it.
export
runProjectReport : StdlibIndex ->
  Bool ->
  List String ->
  List String ->
  List String ->
  List LintEntry ->
  <IO> Bool
runProjectReport idx internalFlag disableNames onlyNames denyNames entries =
  let raw =
    dropInactiveInternalProject
      allProjectRules
      internalFlag
      (runProjectRules onlyNames disableNames idx (map entrySummaries entries))
  let suppressed = applySuppressionsMultiDirs (map entryDirTable entries) raw
  reportProjectFindings (applyFindingDeny denyNames suppressed)

entrySummaries : LintEntry -> (String, List (String, Summary))
entrySummaries e = (e.path, e.summaries)

entryDirTable : LintEntry -> (String, List Directive)
entryDirTable e = (e.path, e.directives)

-- Tail of the project-rule report: render (after the per-file
-- output, under a `cross-file:` header) and report whether anything was an
-- error.
reportProjectFindings : List Finding -> <IO> Bool
reportProjectFindings [] = False
reportProjectFindings findings =
  let _ = putStrLn ""
  let _ = putStrLn "cross-file:"
  let _ = putStrLn (joinNl (map renderCrossFinding findings))
  anyList isFindingError findings

-- Render one cross-file finding.  The file path lives in the finding's loc; pass
-- it as the diagnostic's file (src="" → header-only, no carat, so output stays
-- deterministic across the whole file set).
renderCrossFinding : Finding -> String
renderCrossFinding f = ppDiagCliSrc "" (locFileOf f.loc) (findingToDiag f)

locFileOf : Option Loc -> String
locFileOf (Some (Loc file _ _ _ _)) = file
locFileOf None = ""

-- Resolve file args to a concrete list of .mdk paths.
-- Empty args → project root mode (find medaka.toml, list top-level .mdk files).
-- Each non-empty arg is expanded individually: a path listDir succeeds on is
-- treated as a directory (recursively collected); else it's kept as a literal
-- file path. This applies uniformly whether one or many targets are given, so
-- `medaka lint dirA dirB` expands BOTH dirs (not just the first).
export
resolveLintTargets : List String -> <IO> List String
resolveLintTargets [] =
  let cwd = canonicalizePath "."
  match findProjectRoot cwd
    None =>
      let _ =
        ePutStrLn
          "medaka lint: no medaka.toml found; run from a project directory or pass file/dir paths"
      let _ = stageExit 1
      []
    Some root => collectMdkFiles root
resolveLintTargets targets = flatMap expandLintTarget targets

-- ── internal-scope activation ───────────────────────────────────────────────
-- An internal rule (`scope = Internal`) enforces this repository's own
-- conventions, so it runs only where asked: `--internal`, or a manifest whose
-- `[lint]` section says `internal = true` (checked per target file, against the
-- nearest `medaka.toml`).  Everywhere else the rule is added to the disable list,
-- which also keeps it out of a `--cache` replay (the cache holds the full roster;
-- findings are filtered at render time).
export
internalRuleNames : List String
internalRuleNames =
  map rowName (filter (row => isInternalScope row.rrMeta.scope) allRuleRows)

isInternalScope : Scope -> Bool
isInternalScope Internal = True
isInternalScope Universal = False

-- The names to add to a file's disable list when internal rules are not active
-- for it.
export
internalDisabledFor : Bool -> String -> <IO> List String
internalDisabledFor internalFlag target =
  if internalActiveFor internalFlag target then [] else internalRuleNames

export
internalActiveFor : Bool -> String -> <IO> Bool
internalActiveFor True _ = True
internalActiveFor False target =
  internalActiveForDir (canonicalizePath (dirOf target))

-- CLI-CONFORMANCE §5f: `--only`/`--deny` naming an internal rule where internal
-- rules are not active matches nothing and would exit 0 like a clean file.
-- The message for the first target it cannot reach, or `None`.
export
inactiveInternalRuleUse : Bool ->
  List String ->
  List String ->
  <IO> Option String
inactiveInternalRuleUse internalFlag names files =
  let named = filter (n => contains n internalRuleNames) names
  if internalFlag || isEmpty named then
    None
  else
    firstInactiveTarget (joinWith ", " named) files

firstInactiveTarget : String -> List String -> <IO> Option String
firstInactiveTarget _ [] = None
firstInactiveTarget named (f :: rest) =
  if internalActiveFor False f then
    firstInactiveTarget named rest
  else
    Some
      "internal rule \{named} is not active for `\{f}`; pass --internal or set `[lint] internal = true` in the project's medaka.toml"

-- The project-rule tier sees every target at once, so its internal-scope rules
-- cannot be switched off by a per-file disable list.  Their findings are
-- filtered instead, by whether internal rules are active for the file each
-- finding lands in.
export
dropInactiveInternalProject : List ProjectRule ->
  Bool ->
  List Finding ->
  <IO> List Finding
dropInactiveInternalProject _ _ [] = []
dropInactiveInternalProject rules internalFlag (f :: rest) =
  let keep =
    if isInternalProjectRule rules f.rule then
      findingInActiveProject internalFlag f
    else
      True
  let kept = dropInactiveInternalProject rules internalFlag rest
  if keep then f :: kept else kept

isInternalProjectRule : List ProjectRule -> String -> Bool
isInternalProjectRule rules name = anyList (isInternalProjectNamed name) rules

isInternalProjectNamed : String -> ProjectRule -> Bool
isInternalProjectNamed name r = r.name == name && isInternalScope r.meta.scope

findingInActiveProject : Bool -> Finding -> <IO> Bool
findingInActiveProject internalFlag f = match f.loc
  Some (Loc file _ _ _ _) => internalActiveFor internalFlag file
  None => True

-- Activation is a property of the target's project, so the manifest walk starts
-- from the target's ABSOLUTE directory (a relative start would read whichever
-- manifest the cwd sits under).  Both answers are memoized for the process, in
-- one cell keyed `dir <path>` / `root <path>`: a directory resolves to its root
-- once, and a root's manifest is read and scanned once, instead of once per
-- target file.
internalActivationMemo : Ref (OrdMap Bool)
internalActivationMemo = Ref omEmpty

internalActiveForDir : String -> <IO> Bool
internalActiveForDir dir = match memoLookup "dir \{dir}"
  Some active => active
  None =>
    let active = match findProjectRoot dir
      Some root => internalActiveForRoot root
      None => False
    memoStore "dir \{dir}" active

internalActiveForRoot : String -> <IO> Bool
internalActiveForRoot root = match memoLookup "root \{root}"
  Some active => active
  None => memoStore "root \{root}" (manifestLintInternal root)

memoLookup : String -> Option Bool
memoLookup key = omLookup key !internalActivationMemo

memoStore : String -> Bool -> Bool
memoStore key active =
  internalActivationMemo := omInsert key active !internalActivationMemo
  active

-- How one `medaka lint` run treats its files: `--internal` forces the
-- internal-scope rules on, `--fix` rewrites instead of reporting, and
-- `lrMulti` (more than one target) adds the per-file "path:" header.
public export data LintRun = LintRun {
  lrInternal : Bool,
  lrFix : Bool,
  lrUnsafe : Bool,
  lrMulti : Bool,
}

-- Fold over file list, running lint on each.  acc = whether any SevError seen.
-- Returns (anyError, entries).
--
-- `entries` is every readable target's LintEntry — the per-file lint result
-- (findings + project-rule summaries + inline directives), however obtained.
-- Under --cache these are what gets persisted, and the dirty ones are the files
-- that actually had to be linted this run.  The project-rule tier reads the
-- entries, never a parse, so a warm run holds no decls in memory.
--
-- The per-file printing order is unchanged: each file's report is emitted
-- (strictly) before the recursion.
export
lintFilesGo : StdlibIndex ->
  LintRun ->
  List String ->
  List String ->
  List String ->
  Option (String, LintBaseline) ->
  Option (String, String) ->
  List String ->
  Bool ->
  <IO> (Bool, List LintEntry)
lintFilesGo _ _ _ _ _ _ _ [] acc = (acc, [])
lintFilesGo idx run disableNames onlyNames denyNames baseCtx cacheCtx (f :: rest) acc =
  let fileDisable = disableNames ++ internalDisabledFor run.lrInternal f
  if run.lrFix then
    let hadErr = lintOneFileFix idx run.lrUnsafe onlyNames fileDisable f
    lintFilesGo
      idx
      run
      disableNames
      onlyNames
      denyNames
      baseCtx
      cacheCtx
      rest
      (acc || hadErr)
  else
    let (hadErr, entries) =
      lintOneFileReport
        idx
        run.lrMulti
        fileDisable
        onlyNames
        denyNames
        baseCtx
        cacheCtx
        f
    let (restErr, restEntries) =
      lintFilesGo
        idx
        run
        disableNames
        onlyNames
        denyNames
        baseCtx
        cacheCtx
        rest
        (acc || hadErr)
    (restErr, entries ++ restEntries)

-- Lint a single file in report mode.
-- multiFile=False: output is byte-for-byte identical to single-file v1 behavior.
-- multiFile=True: prints "path:" header before findings (only when there are findings).
-- Returns (hadError, entries): the 0-or-1 element list carries this file's
-- LintEntry for the project-rule tier and the shard writer.
--
-- The `--cache` decision, in full: a HIT requires the shard to decode, and to
-- agree on the format version, the rule-set stamp, the path, the content hash
-- AND the index key.  Agreeing on all but the index key is a partial hit: the
-- file is parsed and only the index-reading rules re-run.  Anything else is a
-- miss.  `lint_cache.decodeEntry` owns that check; this function only decides
-- when to ask.
lintOneFileReport : StdlibIndex ->
  Bool ->
  List String ->
  List String ->
  List String ->
  Option (String, LintBaseline) ->
  Option (String, String) ->
  String ->
  <IO> (Bool, List LintEntry)
lintOneFileReport idx multiFile disableNames onlyNames denyNames baseCtx cacheCtx target =
  match readSource target
    Err msg =>
      let _ = ePutStrLn msg
      (True, [])
    Ok src =>
      let wantSummaries =
        multiFile && projectRuleSelected onlyNames disableNames
      let found =
        entryOfFile idx cacheCtx disableNames onlyNames wantSummaries target src
      match found
        Err e =>
          ePutStrLn (ppDiagCliSrc src target (parseErrDiag target e))
          (True, [])
        Ok entry =>
          lintOneFileRender
            multiFile
            disableNames
            onlyNames
            denyNames
            baseCtx
            target
            src
            entry

lintOneFileRender : Bool ->
  List String ->
  List String ->
  List String ->
  Option (String, LintBaseline) ->
  String ->
  String ->
  LintEntry ->
  <IO> (Bool, List LintEntry)
lintOneFileRender multiFile disableNames onlyNames denyNames baseCtx target src entry =
  -- Suppress findings silenced by inline `-- lint-disable-*` directives before
  -- applying the CLI flag filters (--only/--disable/--deny).  Both the cached
  -- and uncached paths render from THIS one expression over the entry, so a
  -- hit and a miss cannot print different things: the only difference between
  -- them is where `entry` came from.
  let allFindings = applySuppressionsDirs entry.directives (entryFindings entry)
  let filtered =
    applyFindingFilters disableNames onlyNames denyNames allFindings
  let findings = applyBaselineFindings baseCtx target filtered
  -- `srcLinesArr` whole-file-splits `src` — deferred until there is at
  -- least one finding to render, since a clean file (the common case
  -- across a large corpus) never needs it.
  let output = match findings
    [] => ""
    _ =>
      let srcLines = srcLinesArr src
      joinNl
        (map (f => ppDiagCliLines srcLines target (findingToDiag f)) findings)
  let hasOutput = stringLength output > 0
  let _ = if multiFile && hasOutput then putStrLn (target ++ ":")
  let _ = if hasOutput then putStrLn output
  (anyList isFindingError findings, [entry])

-- One file's entry: from the cache when `cacheCtx` is set and a shard answers,
-- else from a parse.  An unparsable file has no entry.
entryOfFile : StdlibIndex ->
  Option (String, String) ->
  List String ->
  List String ->
  Bool ->
  String ->
  String ->
  <IO> Result ParseError LintEntry
entryOfFile idx None disableNames onlyNames wantSummaries target src =
  map
    ((decls, pos) =>
      uncachedEntryOf
        idx
        disableNames
        onlyNames
        wantSummaries
        target
        src
        decls
        pos)
    (lintParseSource src)
entryOfFile idx (Some (cacheDir, stamp)) _ _ _ target src =
  cachedEntryOf allRules indexKeyFor idx cacheDir stamp target src

-- The entry a `--cache` run uses for one file: the shard if it answers in full,
-- the shard's free findings and summaries with the index-reading rules re-run
-- if the index answers the file's recorded questions differently, a fresh lint
-- of the whole `roster` otherwise.  `keyOf` names the index the index-reading
-- findings were made against; the soundness tests substitute a key without the
-- fingerprint (`indexKeyWith`).
export
cachedEntryOf : List Rule ->
  (List Rule -> StdlibIndex -> String) ->
  StdlibIndex ->
  String ->
  String ->
  String ->
  String ->
  <IO> Result ParseError LintEntry
cachedEntryOf = cachedEntryWith recordingStdlibIndex

-- `cachedEntryOf` with the index a file's rules are handed made by `view`.
-- Production records what the rules ask (`recordingStdlibIndex`); the
-- soundness tests pass the index unchanged to show that a shard whose questions
-- went unrecorded is served stale.
export
cachedEntryWith : (StdlibIndex -> StdlibIndex) ->
  List Rule ->
  (List Rule -> StdlibIndex -> String) ->
  StdlibIndex ->
  String ->
  String ->
  String ->
  String ->
  <IO> Result ParseError LintEntry
cachedEntryWith view roster keyOf idx cacheDir stamp target src =
  let hash = contentHashOf src
  let key = keyOf roster idx
  match loadEntry cacheDir stamp key (stdlibAnswersHold idx) target hash
    ShardHit hit => Ok hit
    loaded =>
      map
        ((decls, pos) =>
          cachedEntryFrom
            roster
            key
            (view idx)
            loaded
            target
            src
            hash
            decls
            pos)
        (lintParseSource src)

-- Uncached, the excluded rules are skipped outright (their findings would be
-- filtered anyway).
uncachedEntryOf : StdlibIndex ->
  List String ->
  List String ->
  Bool ->
  String ->
  String ->
  List Decl ->
  Positions ->
  <IO> LintEntry
uncachedEntryOf idx disableNames onlyNames wantSummaries target src decls pos =
  let facts = mkFileFactsAt target src decls pos
  let rules = selectRules onlyNames disableNames
  LintEntry {
    path = target,
    contentHash = "",
    freeFindings =
      lintProgramRanked idx (ranked 0 rules) target facts pos decls,
    indexFindings = [],
    indexKey = "",
    indexAnswers = [],
    summaries =
      if wantSummaries then
        fileSummaries onlyNames disableNames target facts pos decls
      else
        [],
    directives = factDirectives facts,
    dirty = True,
  }

-- Under --cache the shard must hold the full roster, so every rule runs, except
-- that a stale shard (`ShardStale`) already holds the index-free findings,
-- summaries and directives, and only the index-reading rules run again.  `idx`
-- is this file's own recording index, so what its rules asked is read back
-- once they have run.
cachedEntryFrom : List Rule ->
  String ->
  StdlibIndex ->
  ShardLoad ->
  String ->
  String ->
  String ->
  List Decl ->
  Positions ->
  <IO> LintEntry
cachedEntryFrom roster _ idx (ShardStale stale) target src _ decls pos =
  let facts = mkFileFactsAt target src decls pos
  let indexed =
    lintProgramRanked idx (rankedIndexRules roster) target facts pos decls
  { stale |
    indexFindings = indexed,
    indexAnswers = stdlibRecorded idx,
    dirty = True,
  }
cachedEntryFrom roster key idx _ target src hash decls pos =
  let facts = mkFileFactsAt target src decls pos
  let all = lintProgramRanked idx (ranked 0 roster) target facts pos decls
  let (free, indexed) = splitByIndex roster all
  LintEntry {
    path = target,
    contentHash = hash,
    freeFindings = free,
    indexFindings = indexed,
    indexKey = key,
    indexAnswers = stdlibRecorded idx,
    summaries = fileSummaries [] [] target facts pos decls,
    directives = factDirectives facts,
    dirty = True,
  }

-- Fix a single file in-place.  Returns True only on I/O error (write errors exit 1).
lintOneFileFix : StdlibIndex ->
  Bool ->
  List String ->
  List String ->
  String ->
  <IO> Bool
lintOneFileFix idx unsafeMode onlyNames disableNames target =
  match readSource target
    Err msg =>
      let _ = ePutStrLn msg
      True
    Ok src =>
      let limit = if unsafeMode then Unsafe else Safe
      let localMods = match lintParseSource src
        Ok (decls, _) => projectWildMods target decls
        Err _ => []
      match fixSource idx limit onlyNames disableNames localMods target src
        Err msg =>
          let _ = ePutStrLn msg
          True
        Ok run => writeFixed target src run

-- A run that stopped at the pass limit still writes what it fixed; it exits
-- non-zero (C3: everything but clean) so a script sees the file is not done.
writeFixed : String -> String -> FixRun -> <IO> Bool
writeFixed target src run =
  let (newSrc, n) = runParts run
  let failed = writeFixedSource target src newSrc n
  match run
    Capped _ _ =>
      ePutStrLn
        "\{target}: stopped after \{intToString fixPassLimit} passes; run again"
      True
    Settled _ _ => failed

writeFixedSource : String -> String -> String -> Int -> <IO> Bool
writeFixedSource target src newSrc n =
  if n == 0 && newSrc == src then
    let _ = putStrLn ("fixed 0 finding(s) in " ++ target)
    False
  else match writeFile target newSrc
    Err msg =>
      let _ = ePutStrLn "\{target}: \{msg}"
      let _ = stageExit 1
      True
    Ok _ =>
      let _ = putStrLn "fixed \{intToString n} finding(s) in \{target}"
      False
# DESUGAR
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "joinNl" false) (mem "joinWith" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseAlias ("string") "Str"))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "ParseError" false) (mem "Positions" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRoot" false) (mem "findProjectRootOrSelf" false) (mem "manifestLintInternal" false) (mem "readSource" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" false) (mem "cjAllToJson" false) (mem "ppSeverity" false) (mem "diagIsError" false) (mem "ppDiagCliLines" false) (mem "ppDiagCliSrc" false) (mem "srcLinesArr" false) (mem "parseErrDiag" false))))
(DUse false (UseGroup ("support" "cli_targets") ((mem "collectMdkFiles" false) (mem "expandLintTarget" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageExit" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "Applicability" true) (mem "Category" true) (mem "ProjectRule" true) (mem "Directive" false) (mem "Finding" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "Summary" false) (mem "applicabilityText" false) (mem "maxApplicability" false) (mem "ruleMetaName" false) (mem "allProjectRules" false) (mem "StdlibIndex" false) (mem "allRules" false) (mem "applyFindingDeny" false) (mem "applyFindingFilters" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsMultiDirs" false) (mem "factDirectives" false) (mem "fileSummaries" false) (mem "findingToDiag" false) (mem "fixPassLimit" false) (mem "fixSource" false) (mem "FixRun" true) (mem "runParts" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "lintFileDiagTripleParsed" false) (mem "lintParseSource" false) (mem "lintProgramRanked" false) (mem "indexKeyFor" false) (mem "rankedIndexRules" false) (mem "splitByIndex" false) (mem "mkFileFacts" false) (mem "mkFileFactsAt" false) (mem "projectWildMods" false) (mem "projectRuleSelected" false) (mem "ranked" false) (mem "selectRules" false) (mem "mergeProjectIntoTriples" false) (mem "runProjectRules" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "recordingStdlibIndex" false) (mem "stdlibRecorded" false) (mem "stdlibAnswersHold" false))))
(DUse false (UseGroup ("tools" "lint_cache") ((mem "LintEntry" true) (mem "ShardLoad" true) (mem "cacheDirOf" false) (mem "contentHashOf" false) (mem "entryFindings" false) (mem "loadEntry" false) (mem "ruleSetStamp" false))))
(DUse false (UseGroup ("tools" "lint_baseline") ((mem "LintBaseline" false) (mem "applyBaselineToDiags" false) (mem "applyBaselineToFindings" false) (mem "baselineDiagViolations" false) (mem "baselineKeyOf" false) (mem "baselineViolationLine" false) (mem "baselineViolations" false) (mem "diagCodeOf" false) (mem "findingRuleOf" false))))
(DTypeSig true "lintHelpText" (TyCon "String"))
(DFunDef false "lintHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka lint — Lint files/dirs against style rules\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka lint [paths...] [flags]\n")) (ELit (LString "  medaka lint --list-rules [filters] [--json|--markdown]\n")) (ELit (LString "  medaka lint --explain <rule>\n")) (ELit (LString "\n")) (ELit (LString "  --fix                 rewrite fixable findings in-place\n")) (ELit (LString "  --unsafe-fixes        with --fix: also apply fixes that may change behavior\n")) (ELit (LString "  --json                emit the {\"files\":[...]} structured-diagnostics\n")) (ELit (LString "                       envelope instead of human text (--fix is ignored)\n")) (ELit (LString "  --cache                reuse per-file results for files whose content is\n")) (ELit (LString "                       unchanged (opt-in, like ESLint's --cache)\n")) (ELit (LString "  --disable=r1,r2,...    suppress findings from the named rules\n")) (ELit (LString "  --only=r1,...          keep only findings from the named rules\n")) (ELit (LString "  --deny=r1,...          promote findings from the named rules to error\n")) (ELit (LString "  --baseline=<file>      error only where a file's per-rule finding count\n")) (ELit (LString "                       exceeds its row in <file> (counts may fall freely)\n")) (ELit (LString "  --write-baseline=<f>   regenerate <f> from this run instead of reporting\n")) (ELit (LString "  --list-rules           list every rule with its metadata (--json for the\n")) (ELit (LString "                       machine form, --markdown for docs/ops/LINT-RULES.md)\n")) (ELit (LString "  --scope=universal|internal     with --list-rules: keep one scope\n")) (ELit (LString "  --ratchet=gated|baselined      with --list-rules: keep one ratchet\n")) (ELit (LString "  --tier=file|cross              with --list-rules: keep one rule tier\n")) (ELit (LString "  --names                with --list-rules: print only the names, one per line\n")) (ELit (LString "  --explain <rule>       print a rule's summary and documentation\n")) (ELit (LString "  --internal             run the internal-scope rules on every target (they are\n")) (ELit (LString "                       otherwise on only under a manifest with [lint] internal = true)\n")) (ELit (LString "\n")) (ELit (LString "Target resolution: explicit file args are linted in order; a single\n")) (ELit (LString "directory arg lints its top-level .mdk files (not recursive); no args\n")) (ELit (LString "finds the medaka.toml project root and lints its top-level .mdk files.\n")) (ELit (LString "Exit 0 unless a SevError finding exists.\n")))))
(DData Abstract "RuleRow" () ((variant "RuleRow" (ConNamed (field "rrMeta" (TyCon "RuleMeta")) (field "rrTiers" (TyApp (TyCon "List") (TyCon "Tier")))))) ())
(DData Abstract "Tier" () ((variant "TierFile" (ConPos)) (variant "TierCross" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Tier")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TierFile") (PCon "TierFile")) () (EVar "True")) (arm (PTuple (PCon "TierCross") (PCon "TierCross")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DTypeSig false "tierText" (TyFun (TyCon "Tier") (TyCon "String")))
(DFunDef false "tierText" ((PCon "TierFile")) (ELit (LString "file")))
(DFunDef false "tierText" ((PCon "TierCross")) (ELit (LString "cross")))
(DTypeSig true "allRuleRows" (TyApp (TyCon "List") (TyCon "RuleRow")))
(DFunDef false "allRuleRows" () (EBlock (DoLet false false (PVar "fileMetas") (EApp (EApp (EVar "map") (EVar "ruleMetaOf")) (EVar "allRules"))) (DoLet false false (PVar "crossMetas") (EApp (EApp (EVar "map") (EVar "crossMetaOf")) (EVar "allProjectRules"))) (DoLet false false (PVar "fileNames") (EApp (EApp (EVar "map") (EVar "ruleMetaName")) (EVar "fileMetas"))) (DoLet false false (PVar "crossNames") (EApp (EApp (EVar "map") (EVar "ruleMetaName")) (EVar "crossMetas"))) (DoLet false false (PVar "crossOnly") (EApp (EApp (EVar "filter") (ELam ((PVar "m")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EApp (EVar "ruleMetaName") (EVar "m"))) (EVar "fileNames"))))) (EVar "crossMetas"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EVar "mkRow") (EVar "m")) (EApp (EApp (EVar "tiersOf") (EApp (EVar "ruleMetaName") (EVar "m"))) (EVar "crossNames"))))) (EVar "fileMetas")) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EVar "mkRow") (EVar "m")) (EListLit (EVar "TierCross"))))) (EVar "crossOnly"))))))
(DTypeSig false "ruleMetaOf" (TyFun (TyCon "Rule") (TyCon "RuleMeta")))
(DFunDef false "ruleMetaOf" ((PVar "r")) (EFieldAccess (EVar "r") "meta"))
(DTypeSig false "crossMetaOf" (TyFun (TyCon "ProjectRule") (TyCon "RuleMeta")))
(DFunDef false "crossMetaOf" ((PVar "r")) (EFieldAccess (EVar "r") "meta"))
(DTypeSig false "mkRow" (TyFun (TyCon "RuleMeta") (TyFun (TyApp (TyCon "List") (TyCon "Tier")) (TyCon "RuleRow"))))
(DFunDef false "mkRow" ((PVar "m") (PVar "tiers")) (ERecordCreate "RuleRow" ((fa "rrMeta" (EVar "m")) (fa "rrTiers" (EVar "tiers")))))
(DTypeSig false "rowName" (TyFun (TyCon "RuleRow") (TyCon "String")))
(DFunDef false "rowName" ((PVar "row")) (EApp (EVar "ruleMetaName") (EFieldAccess (EVar "row") "rrMeta")))
(DTypeSig false "tiersText" (TyFun (TyApp (TyCon "List") (TyCon "Tier")) (TyCon "String")))
(DFunDef false "tiersText" ((PVar "tiers")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "tierText")) (EVar "tiers"))))
(DTypeSig false "tiersOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Tier")))))
(DFunDef false "tiersOf" ((PVar "n") (PVar "crossNames")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "crossNames")) (EListLit (EVar "TierFile") (EVar "TierCross")) (EIf (EVar "otherwise") (EListLit (EVar "TierFile")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scopeText" (TyFun (TyCon "Scope") (TyCon "String")))
(DFunDef false "scopeText" ((PCon "Universal")) (ELit (LString "universal")))
(DFunDef false "scopeText" ((PCon "Internal")) (ELit (LString "internal")))
(DTypeSig false "ratchetText" (TyFun (TyCon "Ratchet") (TyCon "String")))
(DFunDef false "ratchetText" ((PCon "Gated")) (ELit (LString "gated")))
(DFunDef false "ratchetText" ((PCon "Baselined")) (ELit (LString "baselined")))
(DTypeSig false "categoryText" (TyFun (TyCon "Category") (TyCon "String")))
(DFunDef false "categoryText" ((PCon "Correctness")) (ELit (LString "correctness")))
(DFunDef false "categoryText" ((PCon "Suspicious")) (ELit (LString "suspicious")))
(DFunDef false "categoryText" ((PCon "Perf")) (ELit (LString "perf")))
(DFunDef false "categoryText" ((PCon "Complexity")) (ELit (LString "complexity")))
(DFunDef false "categoryText" ((PCon "Style")) (ELit (LString "style")))
(DTypeSig false "fixabilityText" (TyFun (TyCon "Fixability") (TyCon "String")))
(DFunDef false "fixabilityText" ((PCon "Fixable")) (ELit (LString "fixable")))
(DFunDef false "fixabilityText" ((PCon "FixableUnsafe")) (ELit (LString "fixable-unsafe")))
(DFunDef false "fixabilityText" ((PCon "SuggestOnly")) (ELit (LString "suggest-only")))
(DFunDef false "fixabilityText" ((PCon "NotFixable")) (ELit (LString "not-fixable")))
(DTypeSig false "needText" (TyFun (TyCon "Need") (TyCon "String")))
(DFunDef false "needText" ((PCon "NeedsStdlibIndex")) (ELit (LString "stdlib-index")))
(DFunDef false "needText" ((PCon "NeedsProjectIndex")) (ELit (LString "project-index")))
(DFunDef false "needText" ((PCon "NeedsWildIndex")) (ELit (LString "wildcard-index")))
(DFunDef false "needText" ((PCon "NeedsScopes")) (ELit (LString "scopes")))
(DTypeSig true "selectRuleRows" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RuleRow")))))))
(DFunDef false "selectRuleRows" ((PVar "scope") (PVar "ratchet") (PVar "tier")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "checkChoice") (ELit (LString "--scope"))) (EApp (EApp (EVar "choicesOf") (EVar "scopeText")) (EListLit (EVar "Universal") (EVar "Internal")))) (EVar "scope"))) (ELam ((PVar "s")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "checkChoice") (ELit (LString "--ratchet"))) (EApp (EApp (EVar "choicesOf") (EVar "ratchetText")) (EListLit (EVar "Gated") (EVar "Baselined")))) (EVar "ratchet"))) (ELam ((PVar "r")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "checkChoice") (ELit (LString "--tier"))) (EApp (EApp (EVar "choicesOf") (EVar "tierText")) (EListLit (EVar "TierFile") (EVar "TierCross")))) (EVar "tier"))) (ELam ((PVar "t")) (EApp (EVar "Ok") (EApp (EApp (EVar "filter") (EApp (EApp (EApp (EVar "rowMatches") (EVar "s")) (EVar "r")) (EVar "t"))) (EVar "allRuleRows"))))))))))
(DTypeSig false "choicesOf" (TyFun (TyFun (TyVar "a") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "choicesOf" ((PVar "render") (PVar "values")) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (ETuple (EApp (EVar "render") (EVar "v")) (EVar "v")))) (EVar "values")))
(DTypeSig false "checkChoice" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyVar "a")))))))
(DFunDef false "checkChoice" (PWild PWild (PCon "None")) (EApp (EVar "Ok") (EVar "None")))
(DFunDef false "checkChoice" ((PVar "flagName") (PVar "choices") (PCon "Some" (PVar "v"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "choices")) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "value")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "flagName"))) (ELit (LString " must be one of "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "choices"))))) (ELit (LString ", got `"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "`")))))))
(DTypeSig false "rowMatches" (TyFun (TyApp (TyCon "Option") (TyCon "Scope")) (TyFun (TyApp (TyCon "Option") (TyCon "Ratchet")) (TyFun (TyApp (TyCon "Option") (TyCon "Tier")) (TyFun (TyCon "RuleRow") (TyCon "Bool"))))))
(DFunDef false "rowMatches" ((PVar "s") (PVar "r") (PVar "t") (PVar "row")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "optMatches") (EVar "s")) (EFieldAccess (EFieldAccess (EVar "row") "rrMeta") "scope")) (EApp (EApp (EVar "optMatches") (EVar "r")) (EFieldAccess (EFieldAccess (EVar "row") "rrMeta") "ratchet"))) (EMatch (EVar "t") (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EVar "elem") (EVar "v")) (EFieldAccess (EVar "row") "rrTiers"))))))
(DTypeSig false "optMatches" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyVar "a") (TyCon "Bool")))))
(DFunDef false "optMatches" ((PCon "None") PWild) (EVar "True"))
(DFunDef false "optMatches" ((PCon "Some" (PVar "v")) (PVar "actual")) (EBinOp "==" (EVar "v") (EVar "actual")))
(DTypeSig true "renderRuleRowsNames" (TyFun (TyApp (TyCon "List") (TyCon "RuleRow")) (TyCon "String")))
(DFunDef false "renderRuleRowsNames" ((PVar "rows")) (EBinOp "++" (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "rowName")) (EVar "rows"))) (ELit (LString "\n"))))
(DTypeSig true "renderRuleRowsText" (TyFun (TyApp (TyCon "List") (TyCon "RuleRow")) (TyCon "String")))
(DFunDef false "renderRuleRowsText" ((PVar "rows")) (EBinOp "++" (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "ruleRowLine")) (EVar "rows"))) (ELit (LString "\n"))))
(DTypeSig false "ruleRowLine" (TyFun (TyCon "RuleRow") (TyCon "String")))
(DFunDef false "ruleRowLine" ((PVar "row")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "row") "rrMeta")) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString "\t"))) (EListLit (EFieldAccess (EVar "m") "name") (EApp (EVar "scopeText") (EFieldAccess (EVar "m") "scope")) (EApp (EVar "categoryText") (EFieldAccess (EVar "m") "category")) (EApp (EVar "ratchetText") (EFieldAccess (EVar "m") "ratchet")) (EApp (EVar "fixabilityText") (EFieldAccess (EVar "m") "fixability")) (EApp (EVar "tiersText") (EFieldAccess (EVar "row") "rrTiers")) (EFieldAccess (EVar "m") "summary"))))))
(DTypeSig true "renderRuleRowsJson" (TyFun (TyApp (TyCon "List") (TyCon "RuleRow")) (TyCon "String")))
(DFunDef false "renderRuleRowsJson" ((PVar "rows")) (EBinOp "++" (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "rules")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "ruleRowJson")) (EVar "rows"))))))) (ELit (LString "\n"))))
(DTypeSig false "ruleRowJson" (TyFun (TyCon "RuleRow") (TyCon "Json")))
(DFunDef false "ruleRowJson" ((PVar "row")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "row") "rrMeta")) (DoExpr (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "m") "name"))) (ETuple (ELit (LString "summary")) (EApp (EVar "JString") (EFieldAccess (EVar "m") "summary"))) (ETuple (ELit (LString "doc")) (EApp (EVar "JString") (EFieldAccess (EVar "m") "doc"))) (ETuple (ELit (LString "category")) (EApp (EVar "JString") (EApp (EVar "categoryText") (EFieldAccess (EVar "m") "category")))) (ETuple (ELit (LString "scope")) (EApp (EVar "JString") (EApp (EVar "scopeText") (EFieldAccess (EVar "m") "scope")))) (ETuple (ELit (LString "ratchet")) (EApp (EVar "JString") (EApp (EVar "ratchetText") (EFieldAccess (EVar "m") "ratchet")))) (ETuple (ELit (LString "severity")) (EApp (EVar "JString") (EApp (EVar "ppSeverity") (EFieldAccess (EVar "m") "defaultSeverity")))) (ETuple (ELit (LString "fixability")) (EApp (EVar "JString") (EApp (EVar "fixabilityText") (EFieldAccess (EVar "m") "fixability")))) (ETuple (ELit (LString "maxApplicability")) (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EApp (EVar "JString") (EApp (EVar "applicabilityText") (EVar "a"))))) (EApp (EVar "maxApplicability") (EFieldAccess (EVar "m") "fixability"))))) (ETuple (ELit (LString "needs")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EVar "JString") (EApp (EVar "needText") (EVar "n"))))) (EFieldAccess (EVar "m") "needs")))) (ETuple (ELit (LString "tiers")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EVar "JString") (EApp (EVar "tierText") (EVar "t"))))) (EFieldAccess (EVar "row") "rrTiers")))))))))
(DTypeSig true "explainRule" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))
(DFunDef false "explainRule" ((PVar "q")) (EMatch (EApp (EApp (EVar "filter") (ELam ((PVar "row")) (EBinOp "==" (EApp (EVar "rowName") (EVar "row")) (EVar "q")))) (EVar "allRuleRows")) (arm (PCons (PVar "row") PWild) () (EApp (EVar "Ok") (EApp (EVar "explainText") (EVar "row")))) (arm (PList) () (EBlock (DoLet false false (PVar "near") (EApp (EApp (EVar "filter") (ELam ((PVar "row")) (EApp (EApp (EVar "Str.contains") (EVar "q")) (EApp (EVar "rowName") (EVar "row"))))) (EVar "allRuleRows"))) (DoExpr (EMatch (EVar "near") (arm (PCons (PVar "row") PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unknown rule `")) (EApp (EVar "display") (EVar "q"))) (ELit (LString "` (did you mean `"))) (EApp (EVar "display") (EApp (EVar "rowName") (EVar "row")))) (ELit (LString "`?)"))))) (arm (PList) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown rule `")) (EApp (EVar "display") (EVar "q"))) (ELit (LString "` (see `medaka lint --list-rules`)")))))))))))
(DTypeSig false "explainText" (TyFun (TyCon "RuleRow") (TyCon "String")))
(DFunDef false "explainText" ((PVar "row")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "row") "rrMeta")) (DoExpr (EApp (EVar "joinNl") (EListLit (EFieldAccess (EVar "m") "name") (ELit (LString "")) (EFieldAccess (EVar "m") "summary") (ELit (LString "")) (EFieldAccess (EVar "m") "doc") (ELit (LString "")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "scope: ")) (EApp (EVar "display") (EApp (EVar "scopeText") (EFieldAccess (EVar "m") "scope")))) (ELit (LString "  category: "))) (EApp (EVar "display") (EApp (EVar "categoryText") (EFieldAccess (EVar "m") "category")))) (ELit (LString "  ratchet: "))) (EApp (EVar "display") (EApp (EVar "ratchetText") (EFieldAccess (EVar "m") "ratchet")))) (ELit (LString "  fixability: "))) (EApp (EVar "display") (EApp (EVar "fixabilityText") (EFieldAccess (EVar "m") "fixability")))) (ELit (LString "  tiers: "))) (EApp (EVar "display") (EApp (EVar "tiersText") (EFieldAccess (EVar "row") "rrTiers")))) (ELit (LString ""))))))))
(DTypeSig true "rulesPageMarkdown" (TyCon "String"))
(DFunDef false "rulesPageMarkdown" () (EBinOp "++" (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "# Lint rules")) (ELit (LString "")) (ELit (LString "<!-- Generated by `medaka lint --list-rules --markdown`. Do not edit by hand. -->")) (ELit (LString "")) (ELit (LString "Every rule `medaka lint` knows. `universal` rules are meaningful in any Medaka program; `internal` rules enforce this repository's own conventions. `gated` rules must have zero findings across the enforced tree; `baselined` rules may only fall (`docs/ops/CLI-CONFORMANCE.md`, `.githooks/pre-commit`). Per-rule detail: `medaka lint --explain <rule>`.")) (ELit (LString "")) (ELit (LString "| Rule | Scope | Category | Ratchet | Fix | Tiers |")) (ELit (LString "|---|---|---|---|---|---|"))) (EApp (EApp (EVar "map") (EVar "rulesPageTableRow")) (EVar "allRuleRows"))) (EApp (EApp (EVar "flatMap") (EVar "rulesPageSection")) (EVar "allRuleRows")))) (ELit (LString "\n"))))
(DTypeSig false "rulesPageTableRow" (TyFun (TyCon "RuleRow") (TyCon "String")))
(DFunDef false "rulesPageTableRow" ((PVar "row")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "row") "rrMeta")) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "| [`")) (EApp (EVar "display") (EFieldAccess (EVar "m") "name"))) (ELit (LString "`](#"))) (EApp (EVar "display") (EFieldAccess (EVar "m") "name"))) (ELit (LString ") | "))) (EApp (EVar "display") (EApp (EVar "scopeText") (EFieldAccess (EVar "m") "scope")))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EVar "categoryText") (EFieldAccess (EVar "m") "category")))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EVar "ratchetText") (EFieldAccess (EVar "m") "ratchet")))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EVar "fixabilityText") (EFieldAccess (EVar "m") "fixability")))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "tierText")) (EFieldAccess (EVar "row") "rrTiers"))))) (ELit (LString " |"))))))
(DTypeSig false "rulesPageSection" (TyFun (TyCon "RuleRow") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rulesPageSection" ((PVar "row")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "row") "rrMeta")) (DoExpr (EBinOp "++" (EListLit (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "## ")) (EApp (EVar "display") (EFieldAccess (EVar "m") "name"))) (ELit (LString ""))) (ELit (LString "")) (EFieldAccess (EVar "m") "summary") (ELit (LString ""))) (EApp (EVar "docBody") (EFieldAccess (EVar "m") "doc"))))))
(DTypeSig false "docBody" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "docBody" ((PVar "doc")) (EMatch (EApp (EApp (EVar "Str.indexOf") (ELit (LString "\n\nBefore:"))) (EVar "doc")) (arm (PCon "None") () (EListLit (EVar "doc"))) (arm (PCon "Some" (PVar "i")) () (EBinOp "++" (EBinOp "++" (EListLit (EApp (EApp (EVar "Str.take") (EVar "i")) (EVar "doc")) (ELit (LString "")) (ELit (LString "```"))) (EApp (EVar "Str.lines") (EApp (EApp (EVar "Str.drop") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "doc")))) (EListLit (ELit (LString "```")))))))
(DTypeSig true "lintCacheCtx" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lintCacheCtx" ((PCon "False") PWild) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "True")) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "False")) (EBlock (DoLet false false (PVar "root") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "canonicalizePath") (ELit (LString "."))))) (DoLet false false (PVar "binStamp") (EApp (EVar "ruleSetStamp") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "binStamp") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (ETuple (EApp (EVar "cacheDirOf") (EVar "root")) (EVar "binStamp")))))))
(DTypeSig true "runLintJsonCmd" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "runLintJsonCmd" ((PVar "idx") (PVar "internalFlag") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "files")) (EBlock (DoLet false false (PVar "quads") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagQuads") (EVar "idx")) (EVar "internalFlag")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "files"))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "dropQuadParse")) (EVar "quads"))) (DoLet false false (PVar "cross") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectJsonFindings") (EVar "idx")) (EVar "internalFlag")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "quads"))) (DoLet false false (PVar "merged") (EApp (EApp (EVar "mergeProjectIntoTriples") (EVar "cross")) (EVar "triples"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "cjAllToJson") (EVar "merged")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "cjLintTripleHasErr")) (EVar "merged")) (EApp (EVar "stageExit") (ELit (LInt 1))) (ELit LUnit)))))
(DTypeSig true "projectJsonFindings" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Finding"))))))))))
(DFunDef false "projectJsonFindings" ((PVar "idx") (PVar "internalFlag") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "quads")) (EBlock (DoLet false false (PVar "summaries") (EApp (EApp (EVar "map") (EApp (EApp (EVar "quadSummaries") (EVar "onlyNames")) (EVar "disableNames"))) (EVar "quads"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EApp (EVar "runProjectRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "idx")) (EVar "summaries"))) (DoLet false false (PVar "active") (EApp (EApp (EApp (EVar "dropInactiveInternalProject") (EVar "allProjectRules")) (EVar "internalFlag")) (EVar "raw"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EApp (EVar "map") (EVar "quadToSrc")) (EVar "quads"))) (EVar "active"))) (DoExpr (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed")))))
(DTypeSig true "quadSummaries" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))))))
(DFunDef false "quadSummaries" ((PVar "only") (PVar "disable") (PTuple (PVar "path") (PVar "src") PWild (PVar "pos") (PVar "decls"))) (ETuple (EVar "path") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileSummaries") (EVar "only")) (EVar "disable")) (EVar "path")) (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "decls")) (EVar "pos"))) (EVar "pos")) (EVar "decls"))))
(DTypeSig true "quadToSrc" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "quadToSrc" ((PTuple (PVar "path") (PVar "src") PWild PWild PWild)) (ETuple (EVar "path") (EVar "src")))
(DTypeSig false "dropQuadParse" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "dropQuadParse" ((PTuple (PVar "path") (PVar "src") (PVar "diags") PWild PWild)) (ETuple (EVar "path") (EVar "src") (EVar "diags")))
(DTypeSig true "lintFilesToDiagQuads" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))
(DFunDef false "lintFilesToDiagQuads" (PWild PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintFilesToDiagQuads" ((PVar "idx") (PVar "internalFlag") (PVar "disable") (PVar "only") (PVar "deny") (PVar "baseCtx") (PCons (PVar "f") (PVar "rest"))) (EBlock (DoLet false false (PVar "fileDisable") (EBinOp "++" (EVar "disable") (EApp (EApp (EVar "internalDisabledFor") (EVar "internalFlag")) (EVar "f")))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "applyBaselineQuad") (EVar "baseCtx")) (EApp (EApp (EApp (EApp (EApp (EVar "lintFileDiagTripleParsed") (EVar "idx")) (EVar "fileDisable")) (EVar "only")) (EVar "deny")) (EVar "f"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagQuads") (EVar "idx")) (EVar "internalFlag")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "baseCtx")) (EVar "rest"))))))
(DTypeSig false "applyBaselineQuad" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "applyBaselineQuad" ((PCon "None") (PVar "quad")) (EVar "quad"))
(DFunDef false "applyBaselineQuad" ((PCon "Some" (PTuple (PVar "cwd") (PVar "base"))) (PTuple (PVar "path") (PVar "src") (PVar "diags") (PVar "pos") (PVar "decls"))) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "baselineKeyOf") (EVar "cwd")) (EVar "path"))) (DoLet false false PWild (EApp (EApp (EVar "reportBaselineViolations") (EVar "key")) (EApp (EApp (EApp (EVar "baselineDiagViolations") (EVar "base")) (EVar "key")) (EVar "diags")))) (DoExpr (ETuple (EVar "path") (EVar "src") (EApp (EApp (EApp (EVar "applyBaselineToDiags") (EVar "base")) (EVar "key")) (EVar "diags")) (EVar "pos") (EVar "decls")))))
(DTypeSig true "lintFilesToDiagTriples" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))
(DFunDef false "lintFilesToDiagTriples" (PWild PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintFilesToDiagTriples" ((PVar "idx") (PVar "internalFlag") (PVar "disable") (PVar "only") (PVar "deny") (PVar "baseCtx") (PCons (PVar "f") (PVar "rest"))) (EBlock (DoLet false false (PVar "fileDisable") (EBinOp "++" (EVar "disable") (EApp (EApp (EVar "internalDisabledFor") (EVar "internalFlag")) (EVar "f")))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "applyBaselineTriple") (EVar "baseCtx")) (EApp (EApp (EApp (EApp (EApp (EVar "lintFileDiagTriple") (EVar "idx")) (EVar "fileDisable")) (EVar "only")) (EVar "deny")) (EVar "f"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "idx")) (EVar "internalFlag")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "baseCtx")) (EVar "rest"))))))
(DTypeSig false "applyBaselineTriple" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "applyBaselineTriple" ((PCon "None") (PVar "triple")) (EVar "triple"))
(DFunDef false "applyBaselineTriple" ((PCon "Some" (PTuple (PVar "cwd") (PVar "base"))) (PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "baselineKeyOf") (EVar "cwd")) (EVar "path"))) (DoLet false false PWild (EApp (EApp (EVar "reportBaselineViolations") (EVar "key")) (EApp (EApp (EApp (EVar "baselineDiagViolations") (EVar "base")) (EVar "key")) (EVar "diags")))) (DoExpr (ETuple (EVar "path") (EVar "src") (EApp (EApp (EApp (EVar "applyBaselineToDiags") (EVar "base")) (EVar "key")) (EVar "diags"))))))
(DTypeSig false "cjLintTripleHasErr" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "cjLintTripleHasErr" ((PTuple PWild PWild (PVar "diags"))) (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags")))
(DTypeSig false "applyBaselineFindings" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "applyBaselineFindings" ((PCon "None") PWild (PVar "findings")) (EVar "findings"))
(DFunDef false "applyBaselineFindings" ((PCon "Some" (PTuple (PVar "cwd") (PVar "base"))) (PVar "target") (PVar "findings")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "baselineKeyOf") (EVar "cwd")) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EVar "reportBaselineViolations") (EVar "key")) (EApp (EApp (EApp (EVar "baselineViolations") (EVar "base")) (EVar "key")) (EApp (EApp (EVar "map") (EVar "findingRuleOf")) (EVar "findings"))))) (DoExpr (EApp (EApp (EApp (EVar "applyBaselineToFindings") (EVar "base")) (EVar "key")) (EVar "findings")))))
(DTypeSig false "reportBaselineViolations" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "reportBaselineViolations" (PWild (PList)) (ELit LUnit))
(DFunDef false "reportBaselineViolations" ((PVar "key") (PCons (PVar "v") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: baseline: ")) (EApp (EVar "display") (EApp (EApp (EVar "baselineViolationLine") (EVar "key")) (EVar "v")))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EVar "reportBaselineViolations") (EVar "key")) (EVar "rest")))))
(DTypeSig true "baselineFileCodes" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "baselineFileCodes" ((PVar "cwd") (PTuple (PVar "path") PWild (PVar "diags"))) (ETuple (EApp (EApp (EVar "baselineKeyOf") (EVar "cwd")) (EVar "path")) (EApp (EApp (EVar "map") (EVar "diagCodeOf")) (EVar "diags"))))
(DTypeSig true "runProjectReport" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runProjectReport" ((PVar "idx") (PVar "internalFlag") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "entries")) (EBlock (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "dropInactiveInternalProject") (EVar "allProjectRules")) (EVar "internalFlag")) (EApp (EApp (EApp (EApp (EVar "runProjectRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "idx")) (EApp (EApp (EVar "map") (EVar "entrySummaries")) (EVar "entries"))))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMultiDirs") (EApp (EApp (EVar "map") (EVar "entryDirTable")) (EVar "entries"))) (EVar "raw"))) (DoExpr (EApp (EVar "reportProjectFindings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))))))
(DTypeSig false "entrySummaries" (TyFun (TyCon "LintEntry") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))))
(DFunDef false "entrySummaries" ((PVar "e")) (ETuple (EFieldAccess (EVar "e") "path") (EFieldAccess (EVar "e") "summaries")))
(DTypeSig false "entryDirTable" (TyFun (TyCon "LintEntry") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))))
(DFunDef false "entryDirTable" ((PVar "e")) (ETuple (EFieldAccess (EVar "e") "path") (EFieldAccess (EVar "e") "directives")))
(DTypeSig false "reportProjectFindings" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "reportProjectFindings" ((PList)) (EVar "False"))
(DFunDef false "reportProjectFindings" ((PVar "findings")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "cross-file:")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "renderCrossFinding")) (EVar "findings"))))) (DoExpr (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")))))
(DTypeSig false "renderCrossFinding" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "renderCrossFinding" ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (ELit (LString ""))) (EApp (EVar "locFileOf") (EFieldAccess (EVar "f") "loc"))) (EApp (EVar "findingToDiag") (EVar "f"))))
(DTypeSig false "locFileOf" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locFileOf" ((PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild))) (EVar "file"))
(DFunDef false "locFileOf" ((PCon "None")) (ELit (LString "")))
(DTypeSig true "resolveLintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "resolveLintTargets" ((PList)) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoExpr (EMatch (EApp (EVar "findProjectRoot") (EVar "cwd")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: no medaka.toml found; run from a project directory or pass file/dir paths")))) (DoLet false false PWild (EApp (EVar "stageExit") (ELit (LInt 1)))) (DoExpr (EListLit)))) (arm (PCon "Some" (PVar "root")) () (EApp (EVar "collectMdkFiles") (EVar "root")))))))
(DFunDef false "resolveLintTargets" ((PVar "targets")) (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets")))
(DTypeSig true "internalRuleNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "internalRuleNames" () (EApp (EApp (EVar "map") (EVar "rowName")) (EApp (EApp (EVar "filter") (ELam ((PVar "row")) (EApp (EVar "isInternalScope") (EFieldAccess (EFieldAccess (EVar "row") "rrMeta") "scope")))) (EVar "allRuleRows"))))
(DTypeSig false "isInternalScope" (TyFun (TyCon "Scope") (TyCon "Bool")))
(DFunDef false "isInternalScope" ((PCon "Internal")) (EVar "True"))
(DFunDef false "isInternalScope" ((PCon "Universal")) (EVar "False"))
(DTypeSig true "internalDisabledFor" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "internalDisabledFor" ((PVar "internalFlag") (PVar "target")) (EIf (EApp (EApp (EVar "internalActiveFor") (EVar "internalFlag")) (EVar "target")) (EListLit) (EVar "internalRuleNames")))
(DTypeSig true "internalActiveFor" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "internalActiveFor" ((PCon "True") PWild) (EVar "True"))
(DFunDef false "internalActiveFor" ((PCon "False") (PVar "target")) (EApp (EVar "internalActiveForDir") (EApp (EVar "canonicalizePath") (EApp (EVar "dirOf") (EVar "target")))))
(DTypeSig true "inactiveInternalRuleUse" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "inactiveInternalRuleUse" ((PVar "internalFlag") (PVar "names") (PVar "files")) (EBlock (DoLet false false (PVar "named") (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "internalRuleNames")))) (EVar "names"))) (DoExpr (EIf (EBinOp "||" (EVar "internalFlag") (EApp (EVar "isEmpty") (EVar "named"))) (EVar "None") (EApp (EApp (EVar "firstInactiveTarget") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "named"))) (EVar "files"))))))
(DTypeSig false "firstInactiveTarget" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "firstInactiveTarget" (PWild (PList)) (EVar "None"))
(DFunDef false "firstInactiveTarget" ((PVar "named") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "internalActiveFor") (EVar "False")) (EVar "f")) (EApp (EApp (EVar "firstInactiveTarget") (EVar "named")) (EVar "rest")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal rule ")) (EApp (EVar "display") (EVar "named"))) (ELit (LString " is not active for `"))) (EApp (EVar "display") (EVar "f"))) (ELit (LString "`; pass --internal or set `[lint] internal = true` in the project's medaka.toml"))))))
(DTypeSig true "dropInactiveInternalProject" (TyFun (TyApp (TyCon "List") (TyCon "ProjectRule")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "dropInactiveInternalProject" (PWild PWild (PList)) (EListLit))
(DFunDef false "dropInactiveInternalProject" ((PVar "rules") (PVar "internalFlag") (PCons (PVar "f") (PVar "rest"))) (EBlock (DoLet false false (PVar "keep") (EIf (EApp (EApp (EVar "isInternalProjectRule") (EVar "rules")) (EFieldAccess (EVar "f") "rule")) (EApp (EApp (EVar "findingInActiveProject") (EVar "internalFlag")) (EVar "f")) (EVar "True"))) (DoLet false false (PVar "kept") (EApp (EApp (EApp (EVar "dropInactiveInternalProject") (EVar "rules")) (EVar "internalFlag")) (EVar "rest"))) (DoExpr (EIf (EVar "keep") (EBinOp "::" (EVar "f") (EVar "kept")) (EVar "kept")))))
(DTypeSig false "isInternalProjectRule" (TyFun (TyApp (TyCon "List") (TyCon "ProjectRule")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isInternalProjectRule" ((PVar "rules") (PVar "name")) (EApp (EApp (EVar "anyList") (EApp (EVar "isInternalProjectNamed") (EVar "name"))) (EVar "rules")))
(DTypeSig false "isInternalProjectNamed" (TyFun (TyCon "String") (TyFun (TyCon "ProjectRule") (TyCon "Bool"))))
(DFunDef false "isInternalProjectNamed" ((PVar "name") (PVar "r")) (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "r") "name") (EVar "name")) (EApp (EVar "isInternalScope") (EFieldAccess (EFieldAccess (EVar "r") "meta") "scope"))))
(DTypeSig false "findingInActiveProject" (TyFun (TyCon "Bool") (TyFun (TyCon "Finding") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "findingInActiveProject" ((PVar "internalFlag") (PVar "f")) (EMatch (EFieldAccess (EVar "f") "loc") (arm (PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild)) () (EApp (EApp (EVar "internalActiveFor") (EVar "internalFlag")) (EVar "file"))) (arm (PCon "None") () (EVar "True"))))
(DTypeSig false "internalActivationMemo" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Bool"))))
(DFunDef false "internalActivationMemo" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig false "internalActiveForDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "internalActiveForDir" ((PVar "dir")) (EMatch (EApp (EVar "memoLookup") (EBinOp "++" (EBinOp "++" (ELit (LString "dir ")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "")))) (arm (PCon "Some" (PVar "active")) () (EVar "active")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "active") (EMatch (EApp (EVar "findProjectRoot") (EVar "dir")) (arm (PCon "Some" (PVar "root")) () (EApp (EVar "internalActiveForRoot") (EVar "root"))) (arm (PCon "None") () (EVar "False")))) (DoExpr (EApp (EApp (EVar "memoStore") (EBinOp "++" (EBinOp "++" (ELit (LString "dir ")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "")))) (EVar "active")))))))
(DTypeSig false "internalActiveForRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "internalActiveForRoot" ((PVar "root")) (EMatch (EApp (EVar "memoLookup") (EBinOp "++" (EBinOp "++" (ELit (LString "root ")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "")))) (arm (PCon "Some" (PVar "active")) () (EVar "active")) (arm (PCon "None") () (EApp (EApp (EVar "memoStore") (EBinOp "++" (EBinOp "++" (ELit (LString "root ")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "")))) (EApp (EVar "manifestLintInternal") (EVar "root"))))))
(DTypeSig false "memoLookup" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Bool"))))
(DFunDef false "memoLookup" ((PVar "key")) (EApp (EApp (EVar "omLookup") (EVar "key")) (EUnOp "!" (EVar "internalActivationMemo"))))
(DTypeSig false "memoStore" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "memoStore" ((PVar "key") (PVar "active")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "internalActivationMemo")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "active")) (EUnOp "!" (EVar "internalActivationMemo"))))) (DoExpr (EVar "active"))))
(DData Public "LintRun" () ((variant "LintRun" (ConNamed (field "lrInternal" (TyCon "Bool")) (field "lrFix" (TyCon "Bool")) (field "lrUnsafe" (TyCon "Bool")) (field "lrMulti" (TyCon "Bool"))))) ())
(DTypeSig true "lintFilesGo" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "LintRun") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry"))))))))))))))
(DFunDef false "lintFilesGo" (PWild PWild PWild PWild PWild PWild PWild (PList) (PVar "acc")) (ETuple (EVar "acc") (EListLit)))
(DFunDef false "lintFilesGo" ((PVar "idx") (PVar "run") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "cacheCtx") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "fileDisable") (EBinOp "++" (EVar "disableNames") (EApp (EApp (EVar "internalDisabledFor") (EFieldAccess (EVar "run") "lrInternal")) (EVar "f")))) (DoExpr (EIf (EFieldAccess (EVar "run") "lrFix") (EBlock (DoLet false false (PVar "hadErr") (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileFix") (EVar "idx")) (EFieldAccess (EVar "run") "lrUnsafe")) (EVar "onlyNames")) (EVar "fileDisable")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "idx")) (EVar "run")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))) (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "entries")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileReport") (EVar "idx")) (EFieldAccess (EVar "run") "lrMulti")) (EVar "fileDisable")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "f"))) (DoLet false false (PTuple (PVar "restErr") (PVar "restEntries")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "idx")) (EVar "run")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr")))) (DoExpr (ETuple (EVar "restErr") (EBinOp "++" (EVar "entries") (EVar "restEntries")))))))))
(DTypeSig false "lintOneFileReport" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")))))))))))))
(DFunDef false "lintOneFileReport" ((PVar "idx") (PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "cacheCtx") (PVar "target")) (EMatch (EApp (EVar "readSource") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (ETuple (EVar "True") (EListLit))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PVar "wantSummaries") (EBinOp "&&" (EVar "multiFile") (EApp (EApp (EVar "projectRuleSelected") (EVar "onlyNames")) (EVar "disableNames")))) (DoLet false false (PVar "found") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entryOfFile") (EVar "idx")) (EVar "cacheCtx")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "wantSummaries")) (EVar "target")) (EVar "src"))) (DoExpr (EMatch (EVar "found") (arm (PCon "Err" (PVar "e")) () (EBlock (DoExpr (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "target")) (EApp (EApp (EVar "parseErrDiag") (EVar "target")) (EVar "e"))))) (DoExpr (ETuple (EVar "True") (EListLit))))) (arm (PCon "Ok" (PVar "entry")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileRender") (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "target")) (EVar "src")) (EVar "entry")))))))))
(DTypeSig false "lintOneFileRender" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LintEntry") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")))))))))))))
(DFunDef false "lintOneFileRender" ((PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "target") (PVar "src") (PVar "entry")) (EBlock (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressionsDirs") (EFieldAccess (EVar "entry") "directives")) (EApp (EVar "entryFindings") (EVar "entry")))) (DoLet false false (PVar "filtered") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "allFindings"))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EVar "applyBaselineFindings") (EVar "baseCtx")) (EVar "target")) (EVar "filtered"))) (DoLet false false (PVar "output") (EMatch (EVar "findings") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBlock (DoLet false false (PVar "srcLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (DoExpr (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliLines") (EVar "srcLines")) (EVar "target")) (EApp (EVar "findingToDiag") (EVar "f"))))) (EVar "findings")))))))) (DoLet false false (PVar "hasOutput") (EBinOp ">" (EApp (EVar "stringLength") (EVar "output")) (ELit (LInt 0)))) (DoLet false false PWild (EIf (EBinOp "&&" (EVar "multiFile") (EVar "hasOutput")) (EApp (EVar "putStrLn") (EBinOp "++" (EVar "target") (ELit (LString ":")))) (ELit LUnit))) (DoLet false false PWild (EIf (EVar "hasOutput") (EApp (EVar "putStrLn") (EVar "output")) (ELit LUnit))) (DoExpr (ETuple (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")) (EListLit (EVar "entry"))))))
(DTypeSig false "entryOfFile" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyCon "LintEntry")))))))))))
(DFunDef false "entryOfFile" ((PVar "idx") (PCon "None") (PVar "disableNames") (PVar "onlyNames") (PVar "wantSummaries") (PVar "target") (PVar "src")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "decls") (PVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "uncachedEntryOf") (EVar "idx")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "wantSummaries")) (EVar "target")) (EVar "src")) (EVar "decls")) (EVar "pos")))) (EApp (EVar "lintParseSource") (EVar "src"))))
(DFunDef false "entryOfFile" ((PVar "idx") (PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) PWild PWild PWild (PVar "target") (PVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cachedEntryOf") (EVar "allRules")) (EVar "indexKeyFor")) (EVar "idx")) (EVar "cacheDir")) (EVar "stamp")) (EVar "target")) (EVar "src")))
(DTypeSig true "cachedEntryOf" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "StdlibIndex") (TyCon "String"))) (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyCon "LintEntry")))))))))))
(DFunDef false "cachedEntryOf" () (EApp (EVar "cachedEntryWith") (EVar "recordingStdlibIndex")))
(DTypeSig true "cachedEntryWith" (TyFun (TyFun (TyCon "StdlibIndex") (TyCon "StdlibIndex")) (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "StdlibIndex") (TyCon "String"))) (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyCon "LintEntry"))))))))))))
(DFunDef false "cachedEntryWith" ((PVar "view") (PVar "roster") (PVar "keyOf") (PVar "idx") (PVar "cacheDir") (PVar "stamp") (PVar "target") (PVar "src")) (EBlock (DoLet false false (PVar "hash") (EApp (EVar "contentHashOf") (EVar "src"))) (DoLet false false (PVar "key") (EApp (EApp (EVar "keyOf") (EVar "roster")) (EVar "idx"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "loadEntry") (EVar "cacheDir")) (EVar "stamp")) (EVar "key")) (EApp (EVar "stdlibAnswersHold") (EVar "idx"))) (EVar "target")) (EVar "hash")) (arm (PCon "ShardHit" (PVar "hit")) () (EApp (EVar "Ok") (EVar "hit"))) (arm (PVar "loaded") () (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "decls") (PVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cachedEntryFrom") (EVar "roster")) (EVar "key")) (EApp (EVar "view") (EVar "idx"))) (EVar "loaded")) (EVar "target")) (EVar "src")) (EVar "hash")) (EVar "decls")) (EVar "pos")))) (EApp (EVar "lintParseSource") (EVar "src"))))))))
(DTypeSig false "uncachedEntryOf" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyEffect ("IO") None (TyCon "LintEntry")))))))))))
(DFunDef false "uncachedEntryOf" ((PVar "idx") (PVar "disableNames") (PVar "onlyNames") (PVar "wantSummaries") (PVar "target") (PVar "src") (PVar "decls") (PVar "pos")) (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EApp (EApp (EVar "mkFileFactsAt") (EVar "target")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoLet false false (PVar "rules") (EApp (EApp (EVar "selectRules") (EVar "onlyNames")) (EVar "disableNames"))) (DoExpr (ERecordCreate "LintEntry" ((fa "path" (EVar "target")) (fa "contentHash" (ELit (LString ""))) (fa "freeFindings" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramRanked") (EVar "idx")) (EApp (EApp (EVar "ranked") (ELit (LInt 0))) (EVar "rules"))) (EVar "target")) (EVar "facts")) (EVar "pos")) (EVar "decls"))) (fa "indexFindings" (EListLit)) (fa "indexKey" (ELit (LString ""))) (fa "indexAnswers" (EListLit)) (fa "summaries" (EIf (EVar "wantSummaries") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileSummaries") (EVar "onlyNames")) (EVar "disableNames")) (EVar "target")) (EVar "facts")) (EVar "pos")) (EVar "decls")) (EListLit))) (fa "directives" (EApp (EVar "factDirectives") (EVar "facts"))) (fa "dirty" (EVar "True")))))))
(DTypeSig false "cachedEntryFrom" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "ShardLoad") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyEffect ("IO") None (TyCon "LintEntry"))))))))))))
(DFunDef false "cachedEntryFrom" ((PVar "roster") PWild (PVar "idx") (PCon "ShardStale" (PVar "stale")) (PVar "target") (PVar "src") PWild (PVar "decls") (PVar "pos")) (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EApp (EApp (EVar "mkFileFactsAt") (EVar "target")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoLet false false (PVar "indexed") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramRanked") (EVar "idx")) (EApp (EVar "rankedIndexRules") (EVar "roster"))) (EVar "target")) (EVar "facts")) (EVar "pos")) (EVar "decls"))) (DoExpr (ERecordUpdate (EVar "stale") ((fa "indexFindings" (EVar "indexed")) (fa "indexAnswers" (EApp (EVar "stdlibRecorded") (EVar "idx"))) (fa "dirty" (EVar "True")))))))
(DFunDef false "cachedEntryFrom" ((PVar "roster") (PVar "key") (PVar "idx") PWild (PVar "target") (PVar "src") (PVar "hash") (PVar "decls") (PVar "pos")) (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EApp (EApp (EVar "mkFileFactsAt") (EVar "target")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoLet false false (PVar "all") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramRanked") (EVar "idx")) (EApp (EApp (EVar "ranked") (ELit (LInt 0))) (EVar "roster"))) (EVar "target")) (EVar "facts")) (EVar "pos")) (EVar "decls"))) (DoLet false false (PTuple (PVar "free") (PVar "indexed")) (EApp (EApp (EVar "splitByIndex") (EVar "roster")) (EVar "all"))) (DoExpr (ERecordCreate "LintEntry" ((fa "path" (EVar "target")) (fa "contentHash" (EVar "hash")) (fa "freeFindings" (EVar "free")) (fa "indexFindings" (EVar "indexed")) (fa "indexKey" (EVar "key")) (fa "indexAnswers" (EApp (EVar "stdlibRecorded") (EVar "idx"))) (fa "summaries" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileSummaries") (EListLit)) (EListLit)) (EVar "target")) (EVar "facts")) (EVar "pos")) (EVar "decls"))) (fa "directives" (EApp (EVar "factDirectives") (EVar "facts"))) (fa "dirty" (EVar "True")))))))
(DTypeSig false "lintOneFileFix" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "lintOneFileFix" ((PVar "idx") (PVar "unsafeMode") (PVar "onlyNames") (PVar "disableNames") (PVar "target")) (EMatch (EApp (EVar "readSource") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PVar "limit") (EIf (EVar "unsafeMode") (EVar "Unsafe") (EVar "Safe"))) (DoLet false false (PVar "localMods") (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Ok" (PTuple (PVar "decls") PWild)) () (EApp (EApp (EVar "projectWildMods") (EVar "target")) (EVar "decls"))) (arm (PCon "Err" PWild) () (EListLit)))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fixSource") (EVar "idx")) (EVar "limit")) (EVar "onlyNames")) (EVar "disableNames")) (EVar "localMods")) (EVar "target")) (EVar "src")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "run")) () (EApp (EApp (EApp (EVar "writeFixed") (EVar "target")) (EVar "src")) (EVar "run")))))))))
(DTypeSig false "writeFixed" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "FixRun") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "writeFixed" ((PVar "target") (PVar "src") (PVar "run")) (EBlock (DoLet false false (PTuple (PVar "newSrc") (PVar "n")) (EApp (EVar "runParts") (EVar "run"))) (DoLet false false (PVar "failed") (EApp (EApp (EApp (EApp (EVar "writeFixedSource") (EVar "target")) (EVar "src")) (EVar "newSrc")) (EVar "n"))) (DoExpr (EMatch (EVar "run") (arm (PCon "Capped" PWild PWild) () (EBlock (DoExpr (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": stopped after "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "fixPassLimit")))) (ELit (LString " passes; run again"))))) (DoExpr (EVar "True")))) (arm (PCon "Settled" PWild PWild) () (EVar "failed"))))))
(DTypeSig false "writeFixedSource" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "writeFixedSource" ((PVar "target") (PVar "src") (PVar "newSrc") (PVar "n")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EVar "newSrc") (EVar "src"))) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "fixed 0 finding(s) in ")) (EVar "target")))) (DoExpr (EVar "False"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "target")) (EVar "newSrc")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "stageExit") (ELit (LInt 1)))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "fixed ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) in "))) (EApp (EVar "display") (EVar "target"))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))
# MARK
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "joinNl" false) (mem "joinWith" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseAlias ("string") "Str"))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "ParseError" false) (mem "Positions" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRoot" false) (mem "findProjectRootOrSelf" false) (mem "manifestLintInternal" false) (mem "readSource" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" false) (mem "cjAllToJson" false) (mem "ppSeverity" false) (mem "diagIsError" false) (mem "ppDiagCliLines" false) (mem "ppDiagCliSrc" false) (mem "srcLinesArr" false) (mem "parseErrDiag" false))))
(DUse false (UseGroup ("support" "cli_targets") ((mem "collectMdkFiles" false) (mem "expandLintTarget" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageExit" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "Applicability" true) (mem "Category" true) (mem "ProjectRule" true) (mem "Directive" false) (mem "Finding" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "Summary" false) (mem "applicabilityText" false) (mem "maxApplicability" false) (mem "ruleMetaName" false) (mem "allProjectRules" false) (mem "StdlibIndex" false) (mem "allRules" false) (mem "applyFindingDeny" false) (mem "applyFindingFilters" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsMultiDirs" false) (mem "factDirectives" false) (mem "fileSummaries" false) (mem "findingToDiag" false) (mem "fixPassLimit" false) (mem "fixSource" false) (mem "FixRun" true) (mem "runParts" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "lintFileDiagTripleParsed" false) (mem "lintParseSource" false) (mem "lintProgramRanked" false) (mem "indexKeyFor" false) (mem "rankedIndexRules" false) (mem "splitByIndex" false) (mem "mkFileFacts" false) (mem "mkFileFactsAt" false) (mem "projectWildMods" false) (mem "projectRuleSelected" false) (mem "ranked" false) (mem "selectRules" false) (mem "mergeProjectIntoTriples" false) (mem "runProjectRules" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "recordingStdlibIndex" false) (mem "stdlibRecorded" false) (mem "stdlibAnswersHold" false))))
(DUse false (UseGroup ("tools" "lint_cache") ((mem "LintEntry" true) (mem "ShardLoad" true) (mem "cacheDirOf" false) (mem "contentHashOf" false) (mem "entryFindings" false) (mem "loadEntry" false) (mem "ruleSetStamp" false))))
(DUse false (UseGroup ("tools" "lint_baseline") ((mem "LintBaseline" false) (mem "applyBaselineToDiags" false) (mem "applyBaselineToFindings" false) (mem "baselineDiagViolations" false) (mem "baselineKeyOf" false) (mem "baselineViolationLine" false) (mem "baselineViolations" false) (mem "diagCodeOf" false) (mem "findingRuleOf" false))))
(DTypeSig true "lintHelpText" (TyCon "String"))
(DFunDef false "lintHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka lint — Lint files/dirs against style rules\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka lint [paths...] [flags]\n")) (ELit (LString "  medaka lint --list-rules [filters] [--json|--markdown]\n")) (ELit (LString "  medaka lint --explain <rule>\n")) (ELit (LString "\n")) (ELit (LString "  --fix                 rewrite fixable findings in-place\n")) (ELit (LString "  --unsafe-fixes        with --fix: also apply fixes that may change behavior\n")) (ELit (LString "  --json                emit the {\"files\":[...]} structured-diagnostics\n")) (ELit (LString "                       envelope instead of human text (--fix is ignored)\n")) (ELit (LString "  --cache                reuse per-file results for files whose content is\n")) (ELit (LString "                       unchanged (opt-in, like ESLint's --cache)\n")) (ELit (LString "  --disable=r1,r2,...    suppress findings from the named rules\n")) (ELit (LString "  --only=r1,...          keep only findings from the named rules\n")) (ELit (LString "  --deny=r1,...          promote findings from the named rules to error\n")) (ELit (LString "  --baseline=<file>      error only where a file's per-rule finding count\n")) (ELit (LString "                       exceeds its row in <file> (counts may fall freely)\n")) (ELit (LString "  --write-baseline=<f>   regenerate <f> from this run instead of reporting\n")) (ELit (LString "  --list-rules           list every rule with its metadata (--json for the\n")) (ELit (LString "                       machine form, --markdown for docs/ops/LINT-RULES.md)\n")) (ELit (LString "  --scope=universal|internal     with --list-rules: keep one scope\n")) (ELit (LString "  --ratchet=gated|baselined      with --list-rules: keep one ratchet\n")) (ELit (LString "  --tier=file|cross              with --list-rules: keep one rule tier\n")) (ELit (LString "  --names                with --list-rules: print only the names, one per line\n")) (ELit (LString "  --explain <rule>       print a rule's summary and documentation\n")) (ELit (LString "  --internal             run the internal-scope rules on every target (they are\n")) (ELit (LString "                       otherwise on only under a manifest with [lint] internal = true)\n")) (ELit (LString "\n")) (ELit (LString "Target resolution: explicit file args are linted in order; a single\n")) (ELit (LString "directory arg lints its top-level .mdk files (not recursive); no args\n")) (ELit (LString "finds the medaka.toml project root and lints its top-level .mdk files.\n")) (ELit (LString "Exit 0 unless a SevError finding exists.\n")))))
(DData Abstract "RuleRow" () ((variant "RuleRow" (ConNamed (field "rrMeta" (TyCon "RuleMeta")) (field "rrTiers" (TyApp (TyCon "List") (TyCon "Tier")))))) ())
(DData Abstract "Tier" () ((variant "TierFile" (ConPos)) (variant "TierCross" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Tier")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TierFile") (PCon "TierFile")) () (EVar "True")) (arm (PTuple (PCon "TierCross") (PCon "TierCross")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DTypeSig false "tierText" (TyFun (TyCon "Tier") (TyCon "String")))
(DFunDef false "tierText" ((PCon "TierFile")) (ELit (LString "file")))
(DFunDef false "tierText" ((PCon "TierCross")) (ELit (LString "cross")))
(DTypeSig true "allRuleRows" (TyApp (TyCon "List") (TyCon "RuleRow")))
(DFunDef false "allRuleRows" () (EBlock (DoLet false false (PVar "fileMetas") (EApp (EApp (EMethodRef "map") (EVar "ruleMetaOf")) (EVar "allRules"))) (DoLet false false (PVar "crossMetas") (EApp (EApp (EMethodRef "map") (EVar "crossMetaOf")) (EVar "allProjectRules"))) (DoLet false false (PVar "fileNames") (EApp (EApp (EMethodRef "map") (EVar "ruleMetaName")) (EVar "fileMetas"))) (DoLet false false (PVar "crossNames") (EApp (EApp (EMethodRef "map") (EVar "ruleMetaName")) (EVar "crossMetas"))) (DoLet false false (PVar "crossOnly") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "m")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EApp (EVar "ruleMetaName") (EVar "m"))) (EVar "fileNames"))))) (EVar "crossMetas"))) (DoExpr (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EVar "mkRow") (EVar "m")) (EApp (EApp (EVar "tiersOf") (EApp (EVar "ruleMetaName") (EVar "m"))) (EVar "crossNames"))))) (EVar "fileMetas")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EVar "mkRow") (EVar "m")) (EListLit (EVar "TierCross"))))) (EVar "crossOnly"))))))
(DTypeSig false "ruleMetaOf" (TyFun (TyCon "Rule") (TyCon "RuleMeta")))
(DFunDef false "ruleMetaOf" ((PVar "r")) (EFieldAccess (EVar "r") "meta"))
(DTypeSig false "crossMetaOf" (TyFun (TyCon "ProjectRule") (TyCon "RuleMeta")))
(DFunDef false "crossMetaOf" ((PVar "r")) (EFieldAccess (EVar "r") "meta"))
(DTypeSig false "mkRow" (TyFun (TyCon "RuleMeta") (TyFun (TyApp (TyCon "List") (TyCon "Tier")) (TyCon "RuleRow"))))
(DFunDef false "mkRow" ((PVar "m") (PVar "tiers")) (ERecordCreate "RuleRow" ((fa "rrMeta" (EVar "m")) (fa "rrTiers" (EVar "tiers")))))
(DTypeSig false "rowName" (TyFun (TyCon "RuleRow") (TyCon "String")))
(DFunDef false "rowName" ((PVar "row")) (EApp (EVar "ruleMetaName") (EFieldAccess (EVar "row") "rrMeta")))
(DTypeSig false "tiersText" (TyFun (TyApp (TyCon "List") (TyCon "Tier")) (TyCon "String")))
(DFunDef false "tiersText" ((PVar "tiers")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "tierText")) (EVar "tiers"))))
(DTypeSig false "tiersOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Tier")))))
(DFunDef false "tiersOf" ((PVar "n") (PVar "crossNames")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "crossNames")) (EListLit (EVar "TierFile") (EVar "TierCross")) (EIf (EVar "otherwise") (EListLit (EVar "TierFile")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "scopeText" (TyFun (TyCon "Scope") (TyCon "String")))
(DFunDef false "scopeText" ((PCon "Universal")) (ELit (LString "universal")))
(DFunDef false "scopeText" ((PCon "Internal")) (ELit (LString "internal")))
(DTypeSig false "ratchetText" (TyFun (TyCon "Ratchet") (TyCon "String")))
(DFunDef false "ratchetText" ((PCon "Gated")) (ELit (LString "gated")))
(DFunDef false "ratchetText" ((PCon "Baselined")) (ELit (LString "baselined")))
(DTypeSig false "categoryText" (TyFun (TyCon "Category") (TyCon "String")))
(DFunDef false "categoryText" ((PCon "Correctness")) (ELit (LString "correctness")))
(DFunDef false "categoryText" ((PCon "Suspicious")) (ELit (LString "suspicious")))
(DFunDef false "categoryText" ((PCon "Perf")) (ELit (LString "perf")))
(DFunDef false "categoryText" ((PCon "Complexity")) (ELit (LString "complexity")))
(DFunDef false "categoryText" ((PCon "Style")) (ELit (LString "style")))
(DTypeSig false "fixabilityText" (TyFun (TyCon "Fixability") (TyCon "String")))
(DFunDef false "fixabilityText" ((PCon "Fixable")) (ELit (LString "fixable")))
(DFunDef false "fixabilityText" ((PCon "FixableUnsafe")) (ELit (LString "fixable-unsafe")))
(DFunDef false "fixabilityText" ((PCon "SuggestOnly")) (ELit (LString "suggest-only")))
(DFunDef false "fixabilityText" ((PCon "NotFixable")) (ELit (LString "not-fixable")))
(DTypeSig false "needText" (TyFun (TyCon "Need") (TyCon "String")))
(DFunDef false "needText" ((PCon "NeedsStdlibIndex")) (ELit (LString "stdlib-index")))
(DFunDef false "needText" ((PCon "NeedsProjectIndex")) (ELit (LString "project-index")))
(DFunDef false "needText" ((PCon "NeedsWildIndex")) (ELit (LString "wildcard-index")))
(DFunDef false "needText" ((PCon "NeedsScopes")) (ELit (LString "scopes")))
(DTypeSig true "selectRuleRows" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RuleRow")))))))
(DFunDef false "selectRuleRows" ((PVar "scope") (PVar "ratchet") (PVar "tier")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "checkChoice") (ELit (LString "--scope"))) (EApp (EApp (EVar "choicesOf") (EVar "scopeText")) (EListLit (EVar "Universal") (EVar "Internal")))) (EVar "scope"))) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "checkChoice") (ELit (LString "--ratchet"))) (EApp (EApp (EVar "choicesOf") (EVar "ratchetText")) (EListLit (EVar "Gated") (EVar "Baselined")))) (EVar "ratchet"))) (ELam ((PVar "r")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "checkChoice") (ELit (LString "--tier"))) (EApp (EApp (EVar "choicesOf") (EVar "tierText")) (EListLit (EVar "TierFile") (EVar "TierCross")))) (EVar "tier"))) (ELam ((PVar "t")) (EApp (EVar "Ok") (EApp (EApp (EMethodRef "filter") (EApp (EApp (EApp (EVar "rowMatches") (EVar "s")) (EVar "r")) (EVar "t"))) (EVar "allRuleRows"))))))))))
(DTypeSig false "choicesOf" (TyFun (TyFun (TyVar "a") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "choicesOf" ((PVar "render") (PVar "values")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (ETuple (EApp (EVar "render") (EVar "v")) (EVar "v")))) (EVar "values")))
(DTypeSig false "checkChoice" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyVar "a")))))))
(DFunDef false "checkChoice" (PWild PWild (PCon "None")) (EApp (EVar "Ok") (EVar "None")))
(DFunDef false "checkChoice" ((PVar "flagName") (PVar "choices") (PCon "Some" (PVar "v"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "choices")) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "value")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "flagName"))) (ELit (LString " must be one of "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "choices"))))) (ELit (LString ", got `"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "`")))))))
(DTypeSig false "rowMatches" (TyFun (TyApp (TyCon "Option") (TyCon "Scope")) (TyFun (TyApp (TyCon "Option") (TyCon "Ratchet")) (TyFun (TyApp (TyCon "Option") (TyCon "Tier")) (TyFun (TyCon "RuleRow") (TyCon "Bool"))))))
(DFunDef false "rowMatches" ((PVar "s") (PVar "r") (PVar "t") (PVar "row")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EDictApp "optMatches") (EVar "s")) (EFieldAccess (EFieldAccess (EVar "row") "rrMeta") "scope")) (EApp (EApp (EDictApp "optMatches") (EVar "r")) (EFieldAccess (EFieldAccess (EVar "row") "rrMeta") "ratchet"))) (EMatch (EVar "t") (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EDictApp "elem") (EVar "v")) (EFieldAccess (EVar "row") "rrTiers"))))))
(DTypeSig false "optMatches" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyFun (TyVar "a") (TyCon "Bool")))))
(DFunDef false "optMatches" ((PCon "None") PWild) (EVar "True"))
(DFunDef false "optMatches" ((PCon "Some" (PVar "v")) (PVar "actual")) (EBinOp "==" (EVar "v") (EVar "actual")))
(DTypeSig true "renderRuleRowsNames" (TyFun (TyApp (TyCon "List") (TyCon "RuleRow")) (TyCon "String")))
(DFunDef false "renderRuleRowsNames" ((PVar "rows")) (EBinOp "++" (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "rowName")) (EVar "rows"))) (ELit (LString "\n"))))
(DTypeSig true "renderRuleRowsText" (TyFun (TyApp (TyCon "List") (TyCon "RuleRow")) (TyCon "String")))
(DFunDef false "renderRuleRowsText" ((PVar "rows")) (EBinOp "++" (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "ruleRowLine")) (EVar "rows"))) (ELit (LString "\n"))))
(DTypeSig false "ruleRowLine" (TyFun (TyCon "RuleRow") (TyCon "String")))
(DFunDef false "ruleRowLine" ((PVar "row")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "row") "rrMeta")) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString "\t"))) (EListLit (EFieldAccess (EVar "m") "name") (EApp (EVar "scopeText") (EFieldAccess (EVar "m") "scope")) (EApp (EVar "categoryText") (EFieldAccess (EVar "m") "category")) (EApp (EVar "ratchetText") (EFieldAccess (EVar "m") "ratchet")) (EApp (EVar "fixabilityText") (EFieldAccess (EVar "m") "fixability")) (EApp (EVar "tiersText") (EFieldAccess (EVar "row") "rrTiers")) (EFieldAccess (EVar "m") "summary"))))))
(DTypeSig true "renderRuleRowsJson" (TyFun (TyApp (TyCon "List") (TyCon "RuleRow")) (TyCon "String")))
(DFunDef false "renderRuleRowsJson" ((PVar "rows")) (EBinOp "++" (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "rules")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "ruleRowJson")) (EVar "rows"))))))) (ELit (LString "\n"))))
(DTypeSig false "ruleRowJson" (TyFun (TyCon "RuleRow") (TyCon "Json")))
(DFunDef false "ruleRowJson" ((PVar "row")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "row") "rrMeta")) (DoExpr (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "m") "name"))) (ETuple (ELit (LString "summary")) (EApp (EVar "JString") (EFieldAccess (EVar "m") "summary"))) (ETuple (ELit (LString "doc")) (EApp (EVar "JString") (EFieldAccess (EVar "m") "doc"))) (ETuple (ELit (LString "category")) (EApp (EVar "JString") (EApp (EVar "categoryText") (EFieldAccess (EVar "m") "category")))) (ETuple (ELit (LString "scope")) (EApp (EVar "JString") (EApp (EVar "scopeText") (EFieldAccess (EVar "m") "scope")))) (ETuple (ELit (LString "ratchet")) (EApp (EVar "JString") (EApp (EVar "ratchetText") (EFieldAccess (EVar "m") "ratchet")))) (ETuple (ELit (LString "severity")) (EApp (EVar "JString") (EApp (EVar "ppSeverity") (EFieldAccess (EVar "m") "defaultSeverity")))) (ETuple (ELit (LString "fixability")) (EApp (EVar "JString") (EApp (EVar "fixabilityText") (EFieldAccess (EVar "m") "fixability")))) (ETuple (ELit (LString "maxApplicability")) (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EApp (EVar "JString") (EApp (EVar "applicabilityText") (EVar "a"))))) (EApp (EVar "maxApplicability") (EFieldAccess (EVar "m") "fixability"))))) (ETuple (ELit (LString "needs")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EVar "JString") (EApp (EVar "needText") (EVar "n"))))) (EFieldAccess (EVar "m") "needs")))) (ETuple (ELit (LString "tiers")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EVar "JString") (EApp (EVar "tierText") (EVar "t"))))) (EFieldAccess (EVar "row") "rrTiers")))))))))
(DTypeSig true "explainRule" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))
(DFunDef false "explainRule" ((PVar "q")) (EMatch (EApp (EApp (EMethodRef "filter") (ELam ((PVar "row")) (EBinOp "==" (EApp (EVar "rowName") (EVar "row")) (EVar "q")))) (EVar "allRuleRows")) (arm (PCons (PVar "row") PWild) () (EApp (EVar "Ok") (EApp (EVar "explainText") (EVar "row")))) (arm (PList) () (EBlock (DoLet false false (PVar "near") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "row")) (EApp (EApp (EVar "Str.contains") (EVar "q")) (EApp (EVar "rowName") (EVar "row"))))) (EVar "allRuleRows"))) (DoExpr (EMatch (EVar "near") (arm (PCons (PVar "row") PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unknown rule `")) (EApp (EMethodRef "display") (EVar "q"))) (ELit (LString "` (did you mean `"))) (EApp (EMethodRef "display") (EApp (EVar "rowName") (EVar "row")))) (ELit (LString "`?)"))))) (arm (PList) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown rule `")) (EApp (EMethodRef "display") (EVar "q"))) (ELit (LString "` (see `medaka lint --list-rules`)")))))))))))
(DTypeSig false "explainText" (TyFun (TyCon "RuleRow") (TyCon "String")))
(DFunDef false "explainText" ((PVar "row")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "row") "rrMeta")) (DoExpr (EApp (EVar "joinNl") (EListLit (EFieldAccess (EVar "m") "name") (ELit (LString "")) (EFieldAccess (EVar "m") "summary") (ELit (LString "")) (EFieldAccess (EVar "m") "doc") (ELit (LString "")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "scope: ")) (EApp (EMethodRef "display") (EApp (EVar "scopeText") (EFieldAccess (EVar "m") "scope")))) (ELit (LString "  category: "))) (EApp (EMethodRef "display") (EApp (EVar "categoryText") (EFieldAccess (EVar "m") "category")))) (ELit (LString "  ratchet: "))) (EApp (EMethodRef "display") (EApp (EVar "ratchetText") (EFieldAccess (EVar "m") "ratchet")))) (ELit (LString "  fixability: "))) (EApp (EMethodRef "display") (EApp (EVar "fixabilityText") (EFieldAccess (EVar "m") "fixability")))) (ELit (LString "  tiers: "))) (EApp (EMethodRef "display") (EApp (EVar "tiersText") (EFieldAccess (EVar "row") "rrTiers")))) (ELit (LString ""))))))))
(DTypeSig true "rulesPageMarkdown" (TyCon "String"))
(DFunDef false "rulesPageMarkdown" () (EBinOp "++" (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "# Lint rules")) (ELit (LString "")) (ELit (LString "<!-- Generated by `medaka lint --list-rules --markdown`. Do not edit by hand. -->")) (ELit (LString "")) (ELit (LString "Every rule `medaka lint` knows. `universal` rules are meaningful in any Medaka program; `internal` rules enforce this repository's own conventions. `gated` rules must have zero findings across the enforced tree; `baselined` rules may only fall (`docs/ops/CLI-CONFORMANCE.md`, `.githooks/pre-commit`). Per-rule detail: `medaka lint --explain <rule>`.")) (ELit (LString "")) (ELit (LString "| Rule | Scope | Category | Ratchet | Fix | Tiers |")) (ELit (LString "|---|---|---|---|---|---|"))) (EApp (EApp (EMethodRef "map") (EVar "rulesPageTableRow")) (EVar "allRuleRows"))) (EApp (EApp (EDictApp "flatMap") (EVar "rulesPageSection")) (EVar "allRuleRows")))) (ELit (LString "\n"))))
(DTypeSig false "rulesPageTableRow" (TyFun (TyCon "RuleRow") (TyCon "String")))
(DFunDef false "rulesPageTableRow" ((PVar "row")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "row") "rrMeta")) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "| [`")) (EApp (EMethodRef "display") (EFieldAccess (EVar "m") "name"))) (ELit (LString "`](#"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "m") "name"))) (ELit (LString ") | "))) (EApp (EMethodRef "display") (EApp (EVar "scopeText") (EFieldAccess (EVar "m") "scope")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EVar "categoryText") (EFieldAccess (EVar "m") "category")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EVar "ratchetText") (EFieldAccess (EVar "m") "ratchet")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EVar "fixabilityText") (EFieldAccess (EVar "m") "fixability")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "tierText")) (EFieldAccess (EVar "row") "rrTiers"))))) (ELit (LString " |"))))))
(DTypeSig false "rulesPageSection" (TyFun (TyCon "RuleRow") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rulesPageSection" ((PVar "row")) (EBlock (DoLet false false (PVar "m") (EFieldAccess (EVar "row") "rrMeta")) (DoExpr (EBinOp "++" (EListLit (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "## ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "m") "name"))) (ELit (LString ""))) (ELit (LString "")) (EFieldAccess (EVar "m") "summary") (ELit (LString ""))) (EApp (EVar "docBody") (EFieldAccess (EVar "m") "doc"))))))
(DTypeSig false "docBody" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "docBody" ((PVar "doc")) (EMatch (EApp (EApp (EVar "Str.indexOf") (ELit (LString "\n\nBefore:"))) (EVar "doc")) (arm (PCon "None") () (EListLit (EVar "doc"))) (arm (PCon "Some" (PVar "i")) () (EBinOp "++" (EBinOp "++" (EListLit (EApp (EApp (EVar "Str.take") (EVar "i")) (EVar "doc")) (ELit (LString "")) (ELit (LString "```"))) (EApp (EVar "Str.lines") (EApp (EApp (EVar "Str.drop") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "doc")))) (EListLit (ELit (LString "```")))))))
(DTypeSig true "lintCacheCtx" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lintCacheCtx" ((PCon "False") PWild) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "True")) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "False")) (EBlock (DoLet false false (PVar "root") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "canonicalizePath") (ELit (LString "."))))) (DoLet false false (PVar "binStamp") (EApp (EVar "ruleSetStamp") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "binStamp") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (ETuple (EApp (EVar "cacheDirOf") (EVar "root")) (EVar "binStamp")))))))
(DTypeSig true "runLintJsonCmd" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "runLintJsonCmd" ((PVar "idx") (PVar "internalFlag") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "files")) (EBlock (DoLet false false (PVar "quads") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagQuads") (EVar "idx")) (EVar "internalFlag")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "files"))) (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "dropQuadParse")) (EVar "quads"))) (DoLet false false (PVar "cross") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "projectJsonFindings") (EVar "idx")) (EVar "internalFlag")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "quads"))) (DoLet false false (PVar "merged") (EApp (EApp (EVar "mergeProjectIntoTriples") (EVar "cross")) (EVar "triples"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "cjAllToJson") (EVar "merged")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "cjLintTripleHasErr")) (EVar "merged")) (EApp (EVar "stageExit") (ELit (LInt 1))) (ELit LUnit)))))
(DTypeSig true "projectJsonFindings" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Finding"))))))))))
(DFunDef false "projectJsonFindings" ((PVar "idx") (PVar "internalFlag") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "quads")) (EBlock (DoLet false false (PVar "summaries") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "quadSummaries") (EVar "onlyNames")) (EVar "disableNames"))) (EVar "quads"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EApp (EVar "runProjectRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "idx")) (EVar "summaries"))) (DoLet false false (PVar "active") (EApp (EApp (EApp (EVar "dropInactiveInternalProject") (EVar "allProjectRules")) (EVar "internalFlag")) (EVar "raw"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EApp (EMethodRef "map") (EVar "quadToSrc")) (EVar "quads"))) (EVar "active"))) (DoExpr (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed")))))
(DTypeSig true "quadSummaries" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))))))
(DFunDef false "quadSummaries" ((PVar "only") (PVar "disable") (PTuple (PVar "path") (PVar "src") PWild (PVar "pos") (PVar "decls"))) (ETuple (EVar "path") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileSummaries") (EVar "only")) (EVar "disable")) (EVar "path")) (EApp (EApp (EApp (EVar "mkFileFacts") (EVar "src")) (EVar "decls")) (EVar "pos"))) (EVar "pos")) (EVar "decls"))))
(DTypeSig true "quadToSrc" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "quadToSrc" ((PTuple (PVar "path") (PVar "src") PWild PWild PWild)) (ETuple (EVar "path") (EVar "src")))
(DTypeSig false "dropQuadParse" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "dropQuadParse" ((PTuple (PVar "path") (PVar "src") (PVar "diags") PWild PWild)) (ETuple (EVar "path") (EVar "src") (EVar "diags")))
(DTypeSig true "lintFilesToDiagQuads" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))
(DFunDef false "lintFilesToDiagQuads" (PWild PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintFilesToDiagQuads" ((PVar "idx") (PVar "internalFlag") (PVar "disable") (PVar "only") (PVar "deny") (PVar "baseCtx") (PCons (PVar "f") (PVar "rest"))) (EBlock (DoLet false false (PVar "fileDisable") (EBinOp "++" (EVar "disable") (EApp (EApp (EVar "internalDisabledFor") (EVar "internalFlag")) (EVar "f")))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "applyBaselineQuad") (EVar "baseCtx")) (EApp (EApp (EApp (EApp (EApp (EVar "lintFileDiagTripleParsed") (EVar "idx")) (EVar "fileDisable")) (EVar "only")) (EVar "deny")) (EVar "f"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagQuads") (EVar "idx")) (EVar "internalFlag")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "baseCtx")) (EVar "rest"))))))
(DTypeSig false "applyBaselineQuad" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "applyBaselineQuad" ((PCon "None") (PVar "quad")) (EVar "quad"))
(DFunDef false "applyBaselineQuad" ((PCon "Some" (PTuple (PVar "cwd") (PVar "base"))) (PTuple (PVar "path") (PVar "src") (PVar "diags") (PVar "pos") (PVar "decls"))) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "baselineKeyOf") (EVar "cwd")) (EVar "path"))) (DoLet false false PWild (EApp (EApp (EVar "reportBaselineViolations") (EVar "key")) (EApp (EApp (EApp (EVar "baselineDiagViolations") (EVar "base")) (EVar "key")) (EVar "diags")))) (DoExpr (ETuple (EVar "path") (EVar "src") (EApp (EApp (EApp (EVar "applyBaselineToDiags") (EVar "base")) (EVar "key")) (EVar "diags")) (EVar "pos") (EVar "decls")))))
(DTypeSig true "lintFilesToDiagTriples" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))
(DFunDef false "lintFilesToDiagTriples" (PWild PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintFilesToDiagTriples" ((PVar "idx") (PVar "internalFlag") (PVar "disable") (PVar "only") (PVar "deny") (PVar "baseCtx") (PCons (PVar "f") (PVar "rest"))) (EBlock (DoLet false false (PVar "fileDisable") (EBinOp "++" (EVar "disable") (EApp (EApp (EVar "internalDisabledFor") (EVar "internalFlag")) (EVar "f")))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "applyBaselineTriple") (EVar "baseCtx")) (EApp (EApp (EApp (EApp (EApp (EVar "lintFileDiagTriple") (EVar "idx")) (EVar "fileDisable")) (EVar "only")) (EVar "deny")) (EVar "f"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "idx")) (EVar "internalFlag")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "baseCtx")) (EVar "rest"))))))
(DTypeSig false "applyBaselineTriple" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "applyBaselineTriple" ((PCon "None") (PVar "triple")) (EVar "triple"))
(DFunDef false "applyBaselineTriple" ((PCon "Some" (PTuple (PVar "cwd") (PVar "base"))) (PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "baselineKeyOf") (EVar "cwd")) (EVar "path"))) (DoLet false false PWild (EApp (EApp (EVar "reportBaselineViolations") (EVar "key")) (EApp (EApp (EApp (EVar "baselineDiagViolations") (EVar "base")) (EVar "key")) (EVar "diags")))) (DoExpr (ETuple (EVar "path") (EVar "src") (EApp (EApp (EApp (EVar "applyBaselineToDiags") (EVar "base")) (EVar "key")) (EVar "diags"))))))
(DTypeSig false "cjLintTripleHasErr" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "cjLintTripleHasErr" ((PTuple PWild PWild (PVar "diags"))) (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags")))
(DTypeSig false "applyBaselineFindings" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "applyBaselineFindings" ((PCon "None") PWild (PVar "findings")) (EVar "findings"))
(DFunDef false "applyBaselineFindings" ((PCon "Some" (PTuple (PVar "cwd") (PVar "base"))) (PVar "target") (PVar "findings")) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "baselineKeyOf") (EVar "cwd")) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EVar "reportBaselineViolations") (EVar "key")) (EApp (EApp (EApp (EVar "baselineViolations") (EVar "base")) (EVar "key")) (EApp (EApp (EMethodRef "map") (EVar "findingRuleOf")) (EVar "findings"))))) (DoExpr (EApp (EApp (EApp (EVar "applyBaselineToFindings") (EVar "base")) (EVar "key")) (EVar "findings")))))
(DTypeSig false "reportBaselineViolations" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "reportBaselineViolations" (PWild (PList)) (ELit LUnit))
(DFunDef false "reportBaselineViolations" ((PVar "key") (PCons (PVar "v") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: baseline: ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "baselineViolationLine") (EVar "key")) (EVar "v")))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EVar "reportBaselineViolations") (EVar "key")) (EVar "rest")))))
(DTypeSig true "baselineFileCodes" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "baselineFileCodes" ((PVar "cwd") (PTuple (PVar "path") PWild (PVar "diags"))) (ETuple (EApp (EApp (EVar "baselineKeyOf") (EVar "cwd")) (EVar "path")) (EApp (EApp (EMethodRef "map") (EVar "diagCodeOf")) (EVar "diags"))))
(DTypeSig true "runProjectReport" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runProjectReport" ((PVar "idx") (PVar "internalFlag") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "entries")) (EBlock (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "dropInactiveInternalProject") (EVar "allProjectRules")) (EVar "internalFlag")) (EApp (EApp (EApp (EApp (EVar "runProjectRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "idx")) (EApp (EApp (EMethodRef "map") (EVar "entrySummaries")) (EVar "entries"))))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMultiDirs") (EApp (EApp (EMethodRef "map") (EVar "entryDirTable")) (EVar "entries"))) (EVar "raw"))) (DoExpr (EApp (EVar "reportProjectFindings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))))))
(DTypeSig false "entrySummaries" (TyFun (TyCon "LintEntry") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))))))
(DFunDef false "entrySummaries" ((PVar "e")) (ETuple (EFieldAccess (EVar "e") "path") (EFieldAccess (EVar "e") "summaries")))
(DTypeSig false "entryDirTable" (TyFun (TyCon "LintEntry") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))))
(DFunDef false "entryDirTable" ((PVar "e")) (ETuple (EFieldAccess (EVar "e") "path") (EFieldAccess (EVar "e") "directives")))
(DTypeSig false "reportProjectFindings" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "reportProjectFindings" ((PList)) (EVar "False"))
(DFunDef false "reportProjectFindings" ((PVar "findings")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "cross-file:")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "renderCrossFinding")) (EVar "findings"))))) (DoExpr (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")))))
(DTypeSig false "renderCrossFinding" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "renderCrossFinding" ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (ELit (LString ""))) (EApp (EVar "locFileOf") (EFieldAccess (EVar "f") "loc"))) (EApp (EVar "findingToDiag") (EVar "f"))))
(DTypeSig false "locFileOf" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locFileOf" ((PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild))) (EVar "file"))
(DFunDef false "locFileOf" ((PCon "None")) (ELit (LString "")))
(DTypeSig true "resolveLintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "resolveLintTargets" ((PList)) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoExpr (EMatch (EApp (EVar "findProjectRoot") (EVar "cwd")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: no medaka.toml found; run from a project directory or pass file/dir paths")))) (DoLet false false PWild (EApp (EVar "stageExit") (ELit (LInt 1)))) (DoExpr (EListLit)))) (arm (PCon "Some" (PVar "root")) () (EApp (EVar "collectMdkFiles") (EVar "root")))))))
(DFunDef false "resolveLintTargets" ((PVar "targets")) (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets")))
(DTypeSig true "internalRuleNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "internalRuleNames" () (EApp (EApp (EMethodRef "map") (EVar "rowName")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "row")) (EApp (EVar "isInternalScope") (EFieldAccess (EFieldAccess (EVar "row") "rrMeta") "scope")))) (EVar "allRuleRows"))))
(DTypeSig false "isInternalScope" (TyFun (TyCon "Scope") (TyCon "Bool")))
(DFunDef false "isInternalScope" ((PCon "Internal")) (EVar "True"))
(DFunDef false "isInternalScope" ((PCon "Universal")) (EVar "False"))
(DTypeSig true "internalDisabledFor" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "internalDisabledFor" ((PVar "internalFlag") (PVar "target")) (EIf (EApp (EApp (EVar "internalActiveFor") (EVar "internalFlag")) (EVar "target")) (EListLit) (EVar "internalRuleNames")))
(DTypeSig true "internalActiveFor" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "internalActiveFor" ((PCon "True") PWild) (EVar "True"))
(DFunDef false "internalActiveFor" ((PCon "False") (PVar "target")) (EApp (EVar "internalActiveForDir") (EApp (EVar "canonicalizePath") (EApp (EVar "dirOf") (EVar "target")))))
(DTypeSig true "inactiveInternalRuleUse" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "inactiveInternalRuleUse" ((PVar "internalFlag") (PVar "names") (PVar "files")) (EBlock (DoLet false false (PVar "named") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "internalRuleNames")))) (EVar "names"))) (DoExpr (EIf (EBinOp "||" (EVar "internalFlag") (EApp (EMethodRef "isEmpty") (EVar "named"))) (EVar "None") (EApp (EApp (EVar "firstInactiveTarget") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "named"))) (EVar "files"))))))
(DTypeSig false "firstInactiveTarget" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "firstInactiveTarget" (PWild (PList)) (EVar "None"))
(DFunDef false "firstInactiveTarget" ((PVar "named") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "internalActiveFor") (EVar "False")) (EVar "f")) (EApp (EApp (EVar "firstInactiveTarget") (EVar "named")) (EVar "rest")) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal rule ")) (EApp (EMethodRef "display") (EVar "named"))) (ELit (LString " is not active for `"))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString "`; pass --internal or set `[lint] internal = true` in the project's medaka.toml"))))))
(DTypeSig true "dropInactiveInternalProject" (TyFun (TyApp (TyCon "List") (TyCon "ProjectRule")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "dropInactiveInternalProject" (PWild PWild (PList)) (EListLit))
(DFunDef false "dropInactiveInternalProject" ((PVar "rules") (PVar "internalFlag") (PCons (PVar "f") (PVar "rest"))) (EBlock (DoLet false false (PVar "keep") (EIf (EApp (EApp (EVar "isInternalProjectRule") (EVar "rules")) (EFieldAccess (EVar "f") "rule")) (EApp (EApp (EVar "findingInActiveProject") (EVar "internalFlag")) (EVar "f")) (EVar "True"))) (DoLet false false (PVar "kept") (EApp (EApp (EApp (EVar "dropInactiveInternalProject") (EVar "rules")) (EVar "internalFlag")) (EVar "rest"))) (DoExpr (EIf (EVar "keep") (EBinOp "::" (EVar "f") (EVar "kept")) (EVar "kept")))))
(DTypeSig false "isInternalProjectRule" (TyFun (TyApp (TyCon "List") (TyCon "ProjectRule")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isInternalProjectRule" ((PVar "rules") (PVar "name")) (EApp (EApp (EVar "anyList") (EApp (EVar "isInternalProjectNamed") (EVar "name"))) (EVar "rules")))
(DTypeSig false "isInternalProjectNamed" (TyFun (TyCon "String") (TyFun (TyCon "ProjectRule") (TyCon "Bool"))))
(DFunDef false "isInternalProjectNamed" ((PVar "name") (PVar "r")) (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "r") "name") (EVar "name")) (EApp (EVar "isInternalScope") (EFieldAccess (EFieldAccess (EVar "r") "meta") "scope"))))
(DTypeSig false "findingInActiveProject" (TyFun (TyCon "Bool") (TyFun (TyCon "Finding") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "findingInActiveProject" ((PVar "internalFlag") (PVar "f")) (EMatch (EFieldAccess (EVar "f") "loc") (arm (PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild)) () (EApp (EApp (EVar "internalActiveFor") (EVar "internalFlag")) (EVar "file"))) (arm (PCon "None") () (EVar "True"))))
(DTypeSig false "internalActivationMemo" (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Bool"))))
(DFunDef false "internalActivationMemo" () (EApp (EVar "Ref") (EVar "omEmpty")))
(DTypeSig false "internalActiveForDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "internalActiveForDir" ((PVar "dir")) (EMatch (EApp (EVar "memoLookup") (EBinOp "++" (EBinOp "++" (ELit (LString "dir ")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "")))) (arm (PCon "Some" (PVar "active")) () (EVar "active")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "active") (EMatch (EApp (EVar "findProjectRoot") (EVar "dir")) (arm (PCon "Some" (PVar "root")) () (EApp (EVar "internalActiveForRoot") (EVar "root"))) (arm (PCon "None") () (EVar "False")))) (DoExpr (EApp (EApp (EVar "memoStore") (EBinOp "++" (EBinOp "++" (ELit (LString "dir ")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "")))) (EVar "active")))))))
(DTypeSig false "internalActiveForRoot" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "internalActiveForRoot" ((PVar "root")) (EMatch (EApp (EVar "memoLookup") (EBinOp "++" (EBinOp "++" (ELit (LString "root ")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "")))) (arm (PCon "Some" (PVar "active")) () (EVar "active")) (arm (PCon "None") () (EApp (EApp (EVar "memoStore") (EBinOp "++" (EBinOp "++" (ELit (LString "root ")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "")))) (EApp (EVar "manifestLintInternal") (EVar "root"))))))
(DTypeSig false "memoLookup" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Bool"))))
(DFunDef false "memoLookup" ((PVar "key")) (EApp (EApp (EVar "omLookup") (EVar "key")) (EUnOp "!" (EVar "internalActivationMemo"))))
(DTypeSig false "memoStore" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "memoStore" ((PVar "key") (PVar "active")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "internalActivationMemo")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "active")) (EUnOp "!" (EVar "internalActivationMemo"))))) (DoExpr (EVar "active"))))
(DData Public "LintRun" () ((variant "LintRun" (ConNamed (field "lrInternal" (TyCon "Bool")) (field "lrFix" (TyCon "Bool")) (field "lrUnsafe" (TyCon "Bool")) (field "lrMulti" (TyCon "Bool"))))) ())
(DTypeSig true "lintFilesGo" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "LintRun") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry"))))))))))))))
(DFunDef false "lintFilesGo" (PWild PWild PWild PWild PWild PWild PWild (PList) (PVar "acc")) (ETuple (EVar "acc") (EListLit)))
(DFunDef false "lintFilesGo" ((PVar "idx") (PVar "run") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "cacheCtx") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "fileDisable") (EBinOp "++" (EVar "disableNames") (EApp (EApp (EVar "internalDisabledFor") (EFieldAccess (EVar "run") "lrInternal")) (EVar "f")))) (DoExpr (EIf (EFieldAccess (EVar "run") "lrFix") (EBlock (DoLet false false (PVar "hadErr") (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileFix") (EVar "idx")) (EFieldAccess (EVar "run") "lrUnsafe")) (EVar "onlyNames")) (EVar "fileDisable")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "idx")) (EVar "run")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))) (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "entries")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileReport") (EVar "idx")) (EFieldAccess (EVar "run") "lrMulti")) (EVar "fileDisable")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "f"))) (DoLet false false (PTuple (PVar "restErr") (PVar "restEntries")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "idx")) (EVar "run")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr")))) (DoExpr (ETuple (EVar "restErr") (EBinOp "++" (EVar "entries") (EVar "restEntries")))))))))
(DTypeSig false "lintOneFileReport" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")))))))))))))
(DFunDef false "lintOneFileReport" ((PVar "idx") (PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "cacheCtx") (PVar "target")) (EMatch (EApp (EVar "readSource") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (ETuple (EVar "True") (EListLit))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PVar "wantSummaries") (EBinOp "&&" (EVar "multiFile") (EApp (EApp (EVar "projectRuleSelected") (EVar "onlyNames")) (EVar "disableNames")))) (DoLet false false (PVar "found") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "entryOfFile") (EVar "idx")) (EVar "cacheCtx")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "wantSummaries")) (EVar "target")) (EVar "src"))) (DoExpr (EMatch (EVar "found") (arm (PCon "Err" (PVar "e")) () (EBlock (DoExpr (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "target")) (EApp (EApp (EVar "parseErrDiag") (EVar "target")) (EVar "e"))))) (DoExpr (ETuple (EVar "True") (EListLit))))) (arm (PCon "Ok" (PVar "entry")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileRender") (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "target")) (EVar "src")) (EVar "entry")))))))))
(DTypeSig false "lintOneFileRender" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LintEntry") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")))))))))))))
(DFunDef false "lintOneFileRender" ((PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "target") (PVar "src") (PVar "entry")) (EBlock (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressionsDirs") (EFieldAccess (EVar "entry") "directives")) (EApp (EVar "entryFindings") (EVar "entry")))) (DoLet false false (PVar "filtered") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "allFindings"))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EVar "applyBaselineFindings") (EVar "baseCtx")) (EVar "target")) (EVar "filtered"))) (DoLet false false (PVar "output") (EMatch (EVar "findings") (arm (PList) () (ELit (LString ""))) (arm PWild () (EBlock (DoLet false false (PVar "srcLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (DoExpr (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliLines") (EVar "srcLines")) (EVar "target")) (EApp (EVar "findingToDiag") (EVar "f"))))) (EVar "findings")))))))) (DoLet false false (PVar "hasOutput") (EBinOp ">" (EApp (EVar "stringLength") (EVar "output")) (ELit (LInt 0)))) (DoLet false false PWild (EIf (EBinOp "&&" (EVar "multiFile") (EVar "hasOutput")) (EApp (EVar "putStrLn") (EBinOp "++" (EVar "target") (ELit (LString ":")))) (ELit LUnit))) (DoLet false false PWild (EIf (EVar "hasOutput") (EApp (EVar "putStrLn") (EVar "output")) (ELit LUnit))) (DoExpr (ETuple (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")) (EListLit (EVar "entry"))))))
(DTypeSig false "entryOfFile" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyCon "LintEntry")))))))))))
(DFunDef false "entryOfFile" ((PVar "idx") (PCon "None") (PVar "disableNames") (PVar "onlyNames") (PVar "wantSummaries") (PVar "target") (PVar "src")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "decls") (PVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "uncachedEntryOf") (EVar "idx")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "wantSummaries")) (EVar "target")) (EVar "src")) (EVar "decls")) (EVar "pos")))) (EApp (EVar "lintParseSource") (EVar "src"))))
(DFunDef false "entryOfFile" ((PVar "idx") (PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) PWild PWild PWild (PVar "target") (PVar "src")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cachedEntryOf") (EVar "allRules")) (EVar "indexKeyFor")) (EVar "idx")) (EVar "cacheDir")) (EVar "stamp")) (EVar "target")) (EVar "src")))
(DTypeSig true "cachedEntryOf" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "StdlibIndex") (TyCon "String"))) (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyCon "LintEntry")))))))))))
(DFunDef false "cachedEntryOf" () (EApp (EVar "cachedEntryWith") (EVar "recordingStdlibIndex")))
(DTypeSig true "cachedEntryWith" (TyFun (TyFun (TyCon "StdlibIndex") (TyCon "StdlibIndex")) (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "StdlibIndex") (TyCon "String"))) (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyCon "LintEntry"))))))))))))
(DFunDef false "cachedEntryWith" ((PVar "view") (PVar "roster") (PVar "keyOf") (PVar "idx") (PVar "cacheDir") (PVar "stamp") (PVar "target") (PVar "src")) (EBlock (DoLet false false (PVar "hash") (EApp (EVar "contentHashOf") (EVar "src"))) (DoLet false false (PVar "key") (EApp (EApp (EVar "keyOf") (EVar "roster")) (EVar "idx"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "loadEntry") (EVar "cacheDir")) (EVar "stamp")) (EVar "key")) (EApp (EVar "stdlibAnswersHold") (EVar "idx"))) (EVar "target")) (EMethodRef "hash")) (arm (PCon "ShardHit" (PVar "hit")) () (EApp (EVar "Ok") (EVar "hit"))) (arm (PVar "loaded") () (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "decls") (PVar "pos"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cachedEntryFrom") (EVar "roster")) (EVar "key")) (EApp (EVar "view") (EVar "idx"))) (EVar "loaded")) (EVar "target")) (EVar "src")) (EMethodRef "hash")) (EVar "decls")) (EVar "pos")))) (EApp (EVar "lintParseSource") (EVar "src"))))))))
(DTypeSig false "uncachedEntryOf" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyEffect ("IO") None (TyCon "LintEntry")))))))))))
(DFunDef false "uncachedEntryOf" ((PVar "idx") (PVar "disableNames") (PVar "onlyNames") (PVar "wantSummaries") (PVar "target") (PVar "src") (PVar "decls") (PVar "pos")) (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EApp (EApp (EVar "mkFileFactsAt") (EVar "target")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoLet false false (PVar "rules") (EApp (EApp (EVar "selectRules") (EVar "onlyNames")) (EVar "disableNames"))) (DoExpr (ERecordCreate "LintEntry" ((fa "path" (EVar "target")) (fa "contentHash" (ELit (LString ""))) (fa "freeFindings" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramRanked") (EVar "idx")) (EApp (EApp (EVar "ranked") (ELit (LInt 0))) (EVar "rules"))) (EVar "target")) (EVar "facts")) (EVar "pos")) (EVar "decls"))) (fa "indexFindings" (EListLit)) (fa "indexKey" (ELit (LString ""))) (fa "indexAnswers" (EListLit)) (fa "summaries" (EIf (EVar "wantSummaries") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileSummaries") (EVar "onlyNames")) (EVar "disableNames")) (EVar "target")) (EVar "facts")) (EVar "pos")) (EVar "decls")) (EListLit))) (fa "directives" (EApp (EVar "factDirectives") (EVar "facts"))) (fa "dirty" (EVar "True")))))))
(DTypeSig false "cachedEntryFrom" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "ShardLoad") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyEffect ("IO") None (TyCon "LintEntry"))))))))))))
(DFunDef false "cachedEntryFrom" ((PVar "roster") PWild (PVar "idx") (PCon "ShardStale" (PVar "stale")) (PVar "target") (PVar "src") PWild (PVar "decls") (PVar "pos")) (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EApp (EApp (EVar "mkFileFactsAt") (EVar "target")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoLet false false (PVar "indexed") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramRanked") (EVar "idx")) (EApp (EVar "rankedIndexRules") (EVar "roster"))) (EVar "target")) (EVar "facts")) (EVar "pos")) (EVar "decls"))) (DoExpr (ERecordUpdate (EVar "stale") ((fa "indexFindings" (EVar "indexed")) (fa "indexAnswers" (EApp (EVar "stdlibRecorded") (EVar "idx"))) (fa "dirty" (EVar "True")))))))
(DFunDef false "cachedEntryFrom" ((PVar "roster") (PVar "key") (PVar "idx") PWild (PVar "target") (PVar "src") (PVar "hash") (PVar "decls") (PVar "pos")) (EBlock (DoLet false false (PVar "facts") (EApp (EApp (EApp (EApp (EVar "mkFileFactsAt") (EVar "target")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoLet false false (PVar "all") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgramRanked") (EVar "idx")) (EApp (EApp (EVar "ranked") (ELit (LInt 0))) (EVar "roster"))) (EVar "target")) (EVar "facts")) (EVar "pos")) (EVar "decls"))) (DoLet false false (PTuple (PVar "free") (PVar "indexed")) (EApp (EApp (EVar "splitByIndex") (EVar "roster")) (EDictApp "all"))) (DoExpr (ERecordCreate "LintEntry" ((fa "path" (EVar "target")) (fa "contentHash" (EMethodRef "hash")) (fa "freeFindings" (EVar "free")) (fa "indexFindings" (EVar "indexed")) (fa "indexKey" (EVar "key")) (fa "indexAnswers" (EApp (EVar "stdlibRecorded") (EVar "idx"))) (fa "summaries" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fileSummaries") (EListLit)) (EListLit)) (EVar "target")) (EVar "facts")) (EVar "pos")) (EVar "decls"))) (fa "directives" (EApp (EVar "factDirectives") (EVar "facts"))) (fa "dirty" (EVar "True")))))))
(DTypeSig false "lintOneFileFix" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "lintOneFileFix" ((PVar "idx") (PVar "unsafeMode") (PVar "onlyNames") (PVar "disableNames") (PVar "target")) (EMatch (EApp (EVar "readSource") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PVar "limit") (EIf (EVar "unsafeMode") (EVar "Unsafe") (EVar "Safe"))) (DoLet false false (PVar "localMods") (EMatch (EApp (EVar "lintParseSource") (EVar "src")) (arm (PCon "Ok" (PTuple (PVar "decls") PWild)) () (EApp (EApp (EVar "projectWildMods") (EVar "target")) (EVar "decls"))) (arm (PCon "Err" PWild) () (EListLit)))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fixSource") (EVar "idx")) (EVar "limit")) (EVar "onlyNames")) (EVar "disableNames")) (EVar "localMods")) (EVar "target")) (EVar "src")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "run")) () (EApp (EApp (EApp (EVar "writeFixed") (EVar "target")) (EVar "src")) (EVar "run")))))))))
(DTypeSig false "writeFixed" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "FixRun") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "writeFixed" ((PVar "target") (PVar "src") (PVar "run")) (EBlock (DoLet false false (PTuple (PVar "newSrc") (PVar "n")) (EApp (EVar "runParts") (EVar "run"))) (DoLet false false (PVar "failed") (EApp (EApp (EApp (EApp (EVar "writeFixedSource") (EVar "target")) (EVar "src")) (EVar "newSrc")) (EVar "n"))) (DoExpr (EMatch (EVar "run") (arm (PCon "Capped" PWild PWild) () (EBlock (DoExpr (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": stopped after "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "fixPassLimit")))) (ELit (LString " passes; run again"))))) (DoExpr (EVar "True")))) (arm (PCon "Settled" PWild PWild) () (EVar "failed"))))))
(DTypeSig false "writeFixedSource" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "writeFixedSource" ((PVar "target") (PVar "src") (PVar "newSrc") (PVar "n")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EVar "newSrc") (EVar "src"))) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "fixed 0 finding(s) in ")) (EVar "target")))) (DoExpr (EVar "False"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "target")) (EVar "newSrc")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "stageExit") (ELit (LInt 1)))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "fixed ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) in "))) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))
