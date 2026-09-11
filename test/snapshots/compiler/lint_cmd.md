# META
source_lines=588
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_cmd.mdk — the `medaka lint` engine.
--
-- Everything the verb does once its flags are already parsed: resolving the
-- target set, the per-file pass (fresh or from the `--cache` shards), the
-- cross-file tier, baseline promotion at application time, and the `--json`
-- envelope.  `medaka_cli.mdk` keeps `runLintCmd` and the flag/target
-- assertions because they call `requireArgs`/`optDefault`/`dieMsg`, which are
-- defined there and shared with the other verbs; importing them here would
-- make `driver` -> `tools` -> `driver` a cycle the loader rejects.
-- `lintHelpText`/`lintArgSpec` are spec VALUES, not callers, so the cycle does
-- not pin them: they stay only because the two gates that police argv surfaces
-- name `medaka_cli.mdk` in their `sources`.  `test` resolved this the other
-- way (`tools/test_cmd.mdk` holds `testHelpText`/`testArgSpec`, and both gates'
-- `sources` name it); the two verbs are deliberately not symmetric yet.
--
-- Rule implementations are not here either: they live in `tools/lint.mdk`
-- (`Rule`/`CrossFileRule`), the cache format in `tools/lint_cache.mdk`, and
-- the count baseline in `tools/lint_baseline.mdk`.  This module only sequences
-- them.

import support.util.{anyList, joinNl}
import frontend.ast.{Decl, Loc(..)}
import frontend.parser.{
  Positions,
  parseWithPositions,
  parseWithPositionsLocated,
}
import driver.loader.{findProjectRoot, findProjectRootOrSelf}
import driver.diagnostics.{
  Diag,
  cjAllToJson,
  diagIsError,
  ppDiagCliLines,
  ppDiagCliSrc,
  srcLinesArr,
}
import support.cli_targets.{collectMdkFiles, expandLintTarget}
import tools.lint.{
  Directive,
  Finding,
  StdlibIndex,
  allRules,
  applyFindingDeny,
  applyFindingFilters,
  applyFixes,
  applySuppressionsDirs,
  applySuppressionsMulti,
  applySuppressionsMultiDirs,
  collectDirectives,
  crossFileCacheSound,
  fileDupOccs,
  findingToDiag,
  isFindingError,
  lintFileDiagTriple,
  lintFileDiagTripleParsed,
  lintProgram,
  mergeCrossFileIntoTriples,
  runCrossFileRules,
  runCrossFileRulesFromOccs,
  stdlibFingerprint,
}
import tools.lint_cache.{
  LintEntry(..),
  cacheDirOf,
  contentHashOf,
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

-- Resolve `--cache` to `Some (cacheDir, ruleSetStamp)`, or `None` to run
-- uncached.  TWO reasons this declines, both deliberate (#395):
--
--   * `--fix` (and `--json`, which never reaches here) is out of v1 scope. --fix
--     REWRITES the files whose content is the cache key, and ESLint's
--     --cache+--fix is a known sharp edge; --json is a separate per-file path.
--     Combining --cache with either is a silent no-op, not an error.
--   * `crossFileCacheSound` is False — someone added a second cross-file rule,
--     whose per-file inputs nothing caches.  Under --cache that rule would
--     SILENTLY NOT RUN.  So --cache turns itself off instead, costing a slower
--     lint rather than a wrong one.  (No warning: this is a correct, quiet
--     fallback, and a lint that prints compiler-internal chatter to stdout would
--     break every caller that diffs its output.)
--
-- The cache dir hangs off the project root — the same `medaka.toml` walk-up the
-- rest of the CLI uses, which falls back to the cwd when there is no manifest
-- (the repo root case: `medaka lint compiler stdlib sqlite` runs where no
-- medaka.toml sits, and lands the cache at the repo root, which is what the
-- pre-commit hook wants).  A cache dir that resolves somewhere unexpected costs
-- misses, never wrong answers.
--
-- The stamp folds in `stdlib.stdlibFingerprint` alongside `ruleSetStamp`
-- (#2327): `rule-stdlib-reimpl` reads the STDLIB SOURCE TREE from disk at
-- runtime (`buildStdlibIndex`), content `ruleSetStamp`'s binary hash never
-- observes. Without this, editing `stdlib/list.mdk` would leave every OTHER
-- file's cached findings silently answering with the pre-edit stdlib —
-- exactly the "wrong hit" `lint_cache.mdk`'s invariant forbids. Folding it
-- into every shard's stamp (rather than skipping caching only for this one
-- rule) is the smaller fix: shards are per-FILE, not per-rule, so declining
-- caching "for this rule" would mean declining it for every file, which is
-- declining it outright.
export
lintCacheCtx : Bool -> Bool -> <IO> Option (String, String)
lintCacheCtx False _ = None
lintCacheCtx True True = None
lintCacheCtx True False
  | not crossFileCacheSound = None
  | otherwise =
    let root = findProjectRootOrSelf (canonicalizePath ".")
    let binStamp = ruleSetStamp ()
    -- An empty stamp means the binary could not be read, so the rule set cannot
    -- be identified — the one input that makes a hit meaningful is missing.
    -- Decline rather than share a cache across unknown rule sets.
    if binStamp == "" then
      None
    else
      Some (cacheDirOf root, "\{binStamp}.\{stdlibFingerprint}")

-- `medaka lint --json`: run the lint pipeline over every resolved target file
-- and emit the SAME `{"files":[{"file":...,"diagnostics":[...]}]}` envelope
-- `medaka check --json` emits (via `cjAllToJson`) — one schema for both
-- surfaces (#249).  Each `Finding` becomes a `Diag` via `findingToDiag`
-- (inside `lintFileDiagTripleParsed`), which stamps the lint RULE NAME into
-- the diagnostic's `code` field.  Cross-file rules DO participate now (#2701
-- leg 3): the per-file pass already parses every target
-- (`lintFileDiagTripleParsed`), so those parses are reused — never re-read —
-- to run `runCrossFileRules` exactly like the human-text path does, and each
-- resulting `Finding` is folded into its OWN file's `diagnostics` array via
-- `mergeCrossFileIntoTriples` (never a new top-level key).  A duplicate whose
-- partner file lay outside `files` would be folded into a synthesized entry
-- for that file instead — `mergeCrossFileIntoTriples`'s own defensive
-- fallback, unreachable today since `files` is exactly the set every
-- cross-file rule here runs over.  `--fix` never reaches this function.
-- Exit 1 iff any diagnostic is a
-- hard error (severity 1) — matches `runCheckJsonCmd`'s convention.
export
runLintJsonCmd : StdlibIndex ->
  List String ->
  List String ->
  List String ->
  Option (String, LintBaseline) ->
  List String ->
  <IO> Unit
runLintJsonCmd idx disableNames onlyNames denyNames baseCtx files =
  let quads =
    lintFilesToDiagQuads idx disableNames onlyNames denyNames baseCtx files
  let triples = map dropQuadParse quads
  let cross = crossFileJsonFindings disableNames onlyNames denyNames quads
  let merged = mergeCrossFileIntoTriples cross triples
  let _ = putStr (cjAllToJson merged)
  if anyList cjLintTripleHasErr merged then exit 1

-- The cross-file tier's JSON-path inputs, reused from the per-file parses
-- already sitting in `quads` (#394's no-second-read rule applies here too).
-- Mirrors `runCrossFileReport`: `--only`/`--disable` are honored inside
-- `runCrossFileRules`, inline `-- lint-disable-*` directives are applied via
-- `applySuppressionsMulti` (each finding anchors to its own file), then
-- `--deny` promotion.  Unlike the text path this never renders — the caller
-- folds the result into the JSON triples instead.  Exported so
-- `compiler/tools/lint_test.mdk`'s renderer-parity property can call the SAME
-- function `runLintJsonCmd` calls, rather than a reimplementation.
export
crossFileJsonFindings : List String ->
  List String ->
  List String ->
  List (String, String, List Diag, Positions, List Decl) ->
  List Finding
crossFileJsonFindings disableNames onlyNames denyNames quads =
  let parsedTriples = map quadToParseTriple quads
  let raw = runCrossFileRules onlyNames disableNames parsedTriples
  let suppressed = applySuppressionsMulti (map quadToSrc quads) raw
  applyFindingDeny denyNames suppressed

quadToParseTriple : (String, String, List Diag, Positions, List Decl) ->
  (String, Positions, List Decl)
quadToParseTriple (path, _, _, pos, decls) = (path, pos, decls)

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
-- reason as `crossFileJsonFindings` above.
export
lintFilesToDiagQuads : StdlibIndex ->
  List String ->
  List String ->
  List String ->
  Option (String, LintBaseline) ->
  List String ->
  <IO> List (String, String, List Diag, Positions, List Decl)
lintFilesToDiagQuads _ _ _ _ _ [] = []
lintFilesToDiagQuads idx disable only deny baseCtx (f :: rest) =
  applyBaselineQuad baseCtx (lintFileDiagTripleParsed idx disable only deny f)
    :: lintFilesToDiagQuads idx disable only deny baseCtx rest

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
  List String ->
  List String ->
  List String ->
  Option (String, LintBaseline) ->
  List String ->
  <IO> List (String, String, List Diag)
lintFilesToDiagTriples _ _ _ _ _ [] = []
lintFilesToDiagTriples idx disable only deny baseCtx (f :: rest) =
  applyBaselineTriple baseCtx (lintFileDiagTriple idx disable only deny f)
    :: lintFilesToDiagTriples idx disable only deny baseCtx rest

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

-- Run the cross-file rule tier over the whole set, REUSING the parses the per-file
-- pass already produced (#394 — this used to call `parseLintFiles`, re-reading and
-- re-parsing every target, plus `readLintSrcs` for a third read of the same bytes).
-- Findings render AFTER the per-file output under a `cross-file:` header.
-- --only/--disable are honored inside `runCrossFileRules`; --deny promotion is
-- applied here (mirrors the per-file path).  Returns whether any finding is an
-- error severity (feeds the exit code).
export
runCrossFileReport : List String ->
  List String ->
  List String ->
  List (String, String, Positions, List Decl) ->
  <IO> Bool
runCrossFileReport disableNames onlyNames denyNames parsed =
  let triples = map parsedToTriple parsed
  let raw = runCrossFileRules onlyNames disableNames triples
  -- Honor inline `-- lint-disable-*` directives on cross-file findings too:
  -- each finding anchors to its own file, so filter against that file's own
  -- directives (recovered from its source) before the CLI flag filters.
  let suppressed = applySuppressionsMulti (map parsedToSrc parsed) raw
  reportCrossFindings (applyFindingDeny denyNames suppressed)

-- The --cache counterpart of `runCrossFileReport` (#395).  Identical in every
-- observable way; the ONLY difference is its input, because a cache hit has no
-- parse to give the tier:
--   * findings come from `runCrossFileRulesFromOccs` over every file's
--     occurrences — cached ones and freshly-computed ones alike — instead of
--     from `runCrossFileRules` over parses.  Both run the SAME `dupJoin`.
--   * directives are the entries' own (already parsed, cached or fresh) rather
--     than re-lexed from source.
--
-- THE JOIN RUNS EVERY TIME, over ALL files.  Only its per-file INPUTS are
-- cached.  A duplicate-body finding names file A because of file B, so caching
-- these findings would leave A's finding standing after B stopped duplicating
-- it — A is unchanged, so A hits.  Scenario 3 of
-- test/diff_compiler_lint_cache.sh is exactly that edit and exists to catch
-- anyone who tries it.  Callers must have checked `crossFileCacheSound`
-- (`lintCacheCtx` does).
export
runCrossFileReportCached : List String ->
  List String ->
  List String ->
  List LintEntry ->
  <IO> Bool
runCrossFileReportCached disableNames onlyNames denyNames entries =
  let raw =
    runCrossFileRulesFromOccs onlyNames disableNames (flatMap entryOccs entries)
  let suppressed = applySuppressionsMultiDirs (map entryDirTable entries) raw
  reportCrossFindings (applyFindingDeny denyNames suppressed)

entryOccs : LintEntry -> List (String, Int, String, String)
entryOccs e = e.dupOccs

entryDirTable : LintEntry -> (String, List Directive)
entryDirTable e = (e.path, e.directives)

-- Shared tail of both cross-file report paths: render (after the per-file
-- output, under a `cross-file:` header) and report whether anything was an
-- error.  One renderer, so the cached and uncached paths cannot format
-- differently.
reportCrossFindings : List Finding -> <IO> Bool
reportCrossFindings [] = False
reportCrossFindings findings =
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

-- Read each readable target's source into `(path, src)` for inline-directive
-- recovery in the cross-file report path.  Unreadable files are skipped.
-- Projections off the threaded (path, src, Positions, decls) quad (#394): the
-- cross-file rule tier wants (path, Positions, decls), and the inline-directive
-- suppression pass wants (path, src).  Both used to be re-derived from disk by
-- `parseLintFiles` / `readLintSrcs`, which this replaces.
parsedToTriple : (String, String, Positions, List Decl) ->
  (String, Positions, List Decl)
parsedToTriple (path, _, pos, decls) = (path, pos, decls)

parsedToSrc : (String, String, Positions, List Decl) -> (String, String)
parsedToSrc (path, src, _, _) = (path, src)

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
      let _ = exit 1
      []
    Some root => collectMdkFiles root
resolveLintTargets targets = flatMap expandLintTarget targets

-- Fold over file list, running lint on each.  acc = whether any SevError seen.
-- Returns (anyError, entries, parsedFiles).
--
-- `entries` is every readable target's LintEntry — the per-file lint result
-- (findings + duplicate-body occurrences + inline directives), however obtained.
-- Under --cache these are what gets persisted, and the dirty ones are the files
-- that actually had to be linted this run.
--
-- `parsedFiles` is threaded to the cross-file tier so it need not re-read/re-parse
-- the same targets (#394); it is empty in --fix mode, which runs no cross-file
-- rules, and empty under --cache, where a cache HIT has no parse to hand on and
-- the tier is reached from `entries` instead.  Not accumulating it under --cache
-- is also why a warm run holds no decls in memory.
--
-- The per-file printing order is unchanged: each file's report is emitted
-- (strictly) before the recursion.
export
lintFilesGo : StdlibIndex ->
  Bool ->
  Bool ->
  List String ->
  List String ->
  List String ->
  Option (String, LintBaseline) ->
  Option (String, String) ->
  List String ->
  Bool ->
  <IO> (Bool, List LintEntry, List (String, String, Positions, List Decl))
lintFilesGo _ _ _ _ _ _ _ _ [] acc = (acc, [], [])
lintFilesGo idx fixMode multiFile disableNames onlyNames denyNames baseCtx cacheCtx (f :: rest) acc =
  if fixMode then
    let hadErr = lintOneFileFix onlyNames disableNames f
    lintFilesGo
      idx
      fixMode
      multiFile
      disableNames
      onlyNames
      denyNames
      baseCtx
      cacheCtx
      rest
      (acc || hadErr)
  else
    let (hadErr, entries, parsed) =
      lintOneFileReport
        idx
        multiFile
        disableNames
        onlyNames
        denyNames
        baseCtx
        cacheCtx
        f
    let (restErr, restEntries, restParsed) =
      lintFilesGo
        idx
        fixMode
        multiFile
        disableNames
        onlyNames
        denyNames
        baseCtx
        cacheCtx
        rest
        (acc || hadErr)
    (restErr, entries ++ restEntries, parsed ++ restParsed)

-- Lint a single file in report mode.
-- multiFile=False: output is byte-for-byte identical to single-file v1 behavior.
-- multiFile=True: prints "path:" header before findings (only when there are findings).
-- Returns (hadError, parsed) where `parsed` is a 0-or-1 element list carrying this
-- file's (path, src, Positions, decls) for the cross-file tier to REUSE — empty
-- when the file could not be read (mirroring the old parseLintFiles/readLintSrcs
-- skip-unreadable behavior).  Handing the parse out rather than letting the
-- cross-file tier redo it is issue #394: the tier used to `parseLintFiles` (a full
-- re-read + re-parse of every target, 11.4% of a whole-tree lint's runtime) AND
-- `readLintSrcs` (a THIRD read of the same bytes) after this pass had already read
-- and parsed each file. Memory-neutral: runCrossFileReport already materialised
-- every triple at once.
lintOneFileReport : StdlibIndex ->
  Bool ->
  List String ->
  List String ->
  List String ->
  Option (String, LintBaseline) ->
  Option (String, String) ->
  String ->
  <IO> (Bool, List LintEntry, List (String, String, Positions, List Decl))
lintOneFileReport idx multiFile disableNames onlyNames denyNames baseCtx cacheCtx target =
  match readFile target
    Err msg =>
      let _ = ePutStrLn msg
      (True, [], [])
    Ok src =>
      let (entry, parsed) = lintEntryOf idx cacheCtx target src
      -- Suppress findings silenced by inline `-- lint-disable-*` directives before
      -- applying the CLI flag filters (--only/--disable/--deny).  Both the cached
      -- and uncached paths render from THIS one expression over the entry, so a
      -- hit and a miss cannot print different things: the only difference between
      -- them is where `entry` came from.
      let allFindings = applySuppressionsDirs entry.directives entry.findings
      let filtered =
        applyFindingFilters disableNames onlyNames denyNames allFindings
      let findings = applyBaselineFindings baseCtx target filtered
      let srcLines = srcLinesArr src
      let output =
        joinNl
          (map (f => ppDiagCliLines srcLines target (findingToDiag f)) findings)
      let hasOutput = stringLength output > 0
      let _ = if multiFile && hasOutput then putStrLn (target ++ ":")
      let _ = if hasOutput then putStrLn output
      (anyList isFindingError findings, [entry], parsed)

-- One file's lint result, from the cache when it can be trusted and from a real
-- parse otherwise.  Also returns the parse for the #394 cross-file reuse — empty
-- on a cache hit (there is no parse) and, deliberately, empty whenever the cache
-- is on at all, since that path does not consume it.
--
-- The `--cache` decision, in full: a HIT requires the shard to decode, and to
-- agree on the format version, the rule-set stamp, the path, AND the content
-- hash.  Anything else is a miss.  `lint_cache.decodeEntry` owns that check;
-- this function only decides when to ask.
lintEntryOf : StdlibIndex ->
  Option (String, String) ->
  String ->
  String ->
  <IO> (LintEntry, List (String, String, Positions, List Decl))
lintEntryOf idx None target src =
  let (entry, pos, decls) = lintFileFresh idx target src "" False
  (entry, [(target, src, pos, decls)])
lintEntryOf idx (Some (cacheDir, stamp)) target src =
  let hash = contentHashOf src
  match loadEntry cacheDir stamp target hash
    Some hit => (hit, [])
    None =>
      let (entry, _, _) = lintFileFresh idx target src hash True
      (entry, [])

-- Parse and lint a file for real: the miss path, and the whole of the uncached
-- path.  The returned entry is `dirty` — it is this run's work and its shard (if
-- any) needs writing.
--
-- `wantOccs` exists because Medaka is STRICT: an unconditional `fileDupOccs`
-- here would make every UNCACHED run compute each body's `structuralKey` twice
-- — once for this field and once inside `runCrossFileRules`, which walks the
-- parses itself — and that key is an `exprSexp` of every eligible body, i.e.
-- the single most expensive thing the cross-file tier does.  So the field is
-- filled only on the path that consumes it (--cache, via
-- runCrossFileReportCached); the uncached path leaves it empty and keeps
-- reaching the tier through the parses, exactly as before #395.
lintFileFresh : StdlibIndex ->
  String ->
  String ->
  String ->
  Bool ->
  <IO> (LintEntry, Positions, List Decl)
lintFileFresh idx target src hash wantOccs =
  let (decls, pos) = parseWithPositionsLocated src
  (
    LintEntry {
      path = target,
      contentHash = hash,
      findings = lintProgram idx allRules target src pos decls,
      dupOccs = if wantOccs then fileDupOccs (target, pos, decls) else [],
      directives = collectDirectives src,
      dirty = True,
    },
    pos,
    decls,
  )

-- Fix a single file in-place.  Returns True only on I/O error (write errors exit 1).
lintOneFileFix : List String -> List String -> String -> <IO> Bool
lintOneFileFix onlyNames disableNames target = match readFile target
  Err msg =>
    let _ = ePutStrLn msg
    True
  Ok src =>
    let (decls, pos) = parseWithPositions src
    let (newSrc, n) = applyFixes onlyNames disableNames src decls pos
    if newSrc == src then
      let _ = putStrLn ("fixed 0 finding(s) in " ++ target)
      False
    else match writeFile target newSrc
      Err msg =>
        let _ = ePutStrLn "\{target}: \{msg}"
        let _ = exit 1
        True
      Ok _ =>
        let _ = putStrLn "fixed \{intToString n} finding(s) in \{target}"
        False
# DESUGAR
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "joinNl" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" false) (mem "parseWithPositions" false) (mem "parseWithPositionsLocated" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRoot" false) (mem "findProjectRootOrSelf" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" false) (mem "cjAllToJson" false) (mem "diagIsError" false) (mem "ppDiagCliLines" false) (mem "ppDiagCliSrc" false) (mem "srcLinesArr" false))))
(DUse false (UseGroup ("support" "cli_targets") ((mem "collectMdkFiles" false) (mem "expandLintTarget" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "Directive" false) (mem "Finding" false) (mem "StdlibIndex" false) (mem "allRules" false) (mem "applyFindingDeny" false) (mem "applyFindingFilters" false) (mem "applyFixes" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsMultiDirs" false) (mem "collectDirectives" false) (mem "crossFileCacheSound" false) (mem "fileDupOccs" false) (mem "findingToDiag" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "lintFileDiagTripleParsed" false) (mem "lintProgram" false) (mem "mergeCrossFileIntoTriples" false) (mem "runCrossFileRules" false) (mem "runCrossFileRulesFromOccs" false) (mem "stdlibFingerprint" false))))
(DUse false (UseGroup ("tools" "lint_cache") ((mem "LintEntry" true) (mem "cacheDirOf" false) (mem "contentHashOf" false) (mem "loadEntry" false) (mem "ruleSetStamp" false))))
(DUse false (UseGroup ("tools" "lint_baseline") ((mem "LintBaseline" false) (mem "applyBaselineToDiags" false) (mem "applyBaselineToFindings" false) (mem "baselineDiagViolations" false) (mem "baselineKeyOf" false) (mem "baselineViolationLine" false) (mem "baselineViolations" false) (mem "diagCodeOf" false) (mem "findingRuleOf" false))))
(DTypeSig true "lintCacheCtx" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lintCacheCtx" ((PCon "False") PWild) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "True")) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "False")) (EIf (EApp (EVar "not") (EVar "crossFileCacheSound")) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "root") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "canonicalizePath") (ELit (LString "."))))) (DoLet false false (PVar "binStamp") (EApp (EVar "ruleSetStamp") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "binStamp") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (ETuple (EApp (EVar "cacheDirOf") (EVar "root")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "binStamp"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "stdlibFingerprint"))) (ELit (LString "")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "runLintJsonCmd" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "runLintJsonCmd" ((PVar "idx") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "files")) (EBlock (DoLet false false (PVar "quads") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagQuads") (EVar "idx")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "files"))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "dropQuadParse")) (EVar "quads"))) (DoLet false false (PVar "cross") (EApp (EApp (EApp (EApp (EVar "crossFileJsonFindings") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "quads"))) (DoLet false false (PVar "merged") (EApp (EApp (EVar "mergeCrossFileIntoTriples") (EVar "cross")) (EVar "triples"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "cjAllToJson") (EVar "merged")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "cjLintTripleHasErr")) (EVar "merged")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))
(DTypeSig true "crossFileJsonFindings" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "crossFileJsonFindings" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "quads")) (EBlock (DoLet false false (PVar "parsedTriples") (EApp (EApp (EVar "map") (EVar "quadToParseTriple")) (EVar "quads"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "parsedTriples"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EApp (EVar "map") (EVar "quadToSrc")) (EVar "quads"))) (EVar "raw"))) (DoExpr (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed")))))
(DTypeSig false "quadToParseTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "quadToParseTriple" ((PTuple (PVar "path") PWild PWild (PVar "pos") (PVar "decls"))) (ETuple (EVar "path") (EVar "pos") (EVar "decls")))
(DTypeSig false "quadToSrc" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "quadToSrc" ((PTuple (PVar "path") (PVar "src") PWild PWild PWild)) (ETuple (EVar "path") (EVar "src")))
(DTypeSig false "dropQuadParse" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "dropQuadParse" ((PTuple (PVar "path") (PVar "src") (PVar "diags") PWild PWild)) (ETuple (EVar "path") (EVar "src") (EVar "diags")))
(DTypeSig true "lintFilesToDiagQuads" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))))))))))))
(DFunDef false "lintFilesToDiagQuads" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintFilesToDiagQuads" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PVar "baseCtx") (PCons (PVar "f") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "applyBaselineQuad") (EVar "baseCtx")) (EApp (EApp (EApp (EApp (EApp (EVar "lintFileDiagTripleParsed") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "f"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagQuads") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "baseCtx")) (EVar "rest"))))
(DTypeSig false "applyBaselineQuad" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "applyBaselineQuad" ((PCon "None") (PVar "quad")) (EVar "quad"))
(DFunDef false "applyBaselineQuad" ((PCon "Some" (PTuple (PVar "cwd") (PVar "base"))) (PTuple (PVar "path") (PVar "src") (PVar "diags") (PVar "pos") (PVar "decls"))) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "baselineKeyOf") (EVar "cwd")) (EVar "path"))) (DoLet false false PWild (EApp (EApp (EVar "reportBaselineViolations") (EVar "key")) (EApp (EApp (EApp (EVar "baselineDiagViolations") (EVar "base")) (EVar "key")) (EVar "diags")))) (DoExpr (ETuple (EVar "path") (EVar "src") (EApp (EApp (EApp (EVar "applyBaselineToDiags") (EVar "base")) (EVar "key")) (EVar "diags")) (EVar "pos") (EVar "decls")))))
(DTypeSig true "lintFilesToDiagTriples" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))))
(DFunDef false "lintFilesToDiagTriples" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintFilesToDiagTriples" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PVar "baseCtx") (PCons (PVar "f") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "applyBaselineTriple") (EVar "baseCtx")) (EApp (EApp (EApp (EApp (EApp (EVar "lintFileDiagTriple") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "f"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "baseCtx")) (EVar "rest"))))
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
(DTypeSig true "runCrossFileReport" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runCrossFileReport" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "parsed")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "parsedToTriple")) (EVar "parsed"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "triples"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EApp (EVar "map") (EVar "parsedToSrc")) (EVar "parsed"))) (EVar "raw"))) (DoExpr (EApp (EVar "reportCrossFindings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))))))
(DTypeSig true "runCrossFileReportCached" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runCrossFileReportCached" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "entries")) (EBlock (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRulesFromOccs") (EVar "onlyNames")) (EVar "disableNames")) (EApp (EApp (EVar "flatMap") (EVar "entryOccs")) (EVar "entries")))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMultiDirs") (EApp (EApp (EVar "map") (EVar "entryDirTable")) (EVar "entries"))) (EVar "raw"))) (DoExpr (EApp (EVar "reportCrossFindings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))))))
(DTypeSig false "entryOccs" (TyFun (TyCon "LintEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "entryOccs" ((PVar "e")) (EFieldAccess (EVar "e") "dupOccs"))
(DTypeSig false "entryDirTable" (TyFun (TyCon "LintEntry") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))))
(DFunDef false "entryDirTable" ((PVar "e")) (ETuple (EFieldAccess (EVar "e") "path") (EFieldAccess (EVar "e") "directives")))
(DTypeSig false "reportCrossFindings" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "reportCrossFindings" ((PList)) (EVar "False"))
(DFunDef false "reportCrossFindings" ((PVar "findings")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "cross-file:")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "renderCrossFinding")) (EVar "findings"))))) (DoExpr (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")))))
(DTypeSig false "renderCrossFinding" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "renderCrossFinding" ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (ELit (LString ""))) (EApp (EVar "locFileOf") (EFieldAccess (EVar "f") "loc"))) (EApp (EVar "findingToDiag") (EVar "f"))))
(DTypeSig false "locFileOf" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locFileOf" ((PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild))) (EVar "file"))
(DFunDef false "locFileOf" ((PCon "None")) (ELit (LString "")))
(DTypeSig false "parsedToTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parsedToTriple" ((PTuple (PVar "path") PWild (PVar "pos") (PVar "decls"))) (ETuple (EVar "path") (EVar "pos") (EVar "decls")))
(DTypeSig false "parsedToSrc" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "parsedToSrc" ((PTuple (PVar "path") (PVar "src") PWild PWild)) (ETuple (EVar "path") (EVar "src")))
(DTypeSig true "resolveLintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "resolveLintTargets" ((PList)) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoExpr (EMatch (EApp (EVar "findProjectRoot") (EVar "cwd")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: no medaka.toml found; run from a project directory or pass file/dir paths")))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit)))) (arm (PCon "Some" (PVar "root")) () (EApp (EVar "collectMdkFiles") (EVar "root")))))))
(DFunDef false "resolveLintTargets" ((PVar "targets")) (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets")))
(DTypeSig true "lintFilesGo" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))))))
(DFunDef false "lintFilesGo" (PWild PWild PWild PWild PWild PWild PWild PWild (PList) (PVar "acc")) (ETuple (EVar "acc") (EListLit) (EListLit)))
(DFunDef false "lintFilesGo" ((PVar "idx") (PVar "fixMode") (PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "cacheCtx") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EIf (EVar "fixMode") (EBlock (DoLet false false (PVar "hadErr") (EApp (EApp (EApp (EVar "lintOneFileFix") (EVar "onlyNames")) (EVar "disableNames")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "idx")) (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))) (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "entries") (PVar "parsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileReport") (EVar "idx")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "f"))) (DoLet false false (PTuple (PVar "restErr") (PVar "restEntries") (PVar "restParsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "idx")) (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr")))) (DoExpr (ETuple (EVar "restErr") (EBinOp "++" (EVar "entries") (EVar "restEntries")) (EBinOp "++" (EVar "parsed") (EVar "restParsed")))))))
(DTypeSig false "lintOneFileReport" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))))
(DFunDef false "lintOneFileReport" ((PVar "idx") (PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "cacheCtx") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (ETuple (EVar "True") (EListLit) (EListLit))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "entry") (PVar "parsed")) (EApp (EApp (EApp (EApp (EVar "lintEntryOf") (EVar "idx")) (EVar "cacheCtx")) (EVar "target")) (EVar "src"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressionsDirs") (EFieldAccess (EVar "entry") "directives")) (EFieldAccess (EVar "entry") "findings"))) (DoLet false false (PVar "filtered") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "allFindings"))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EVar "applyBaselineFindings") (EVar "baseCtx")) (EVar "target")) (EVar "filtered"))) (DoLet false false (PVar "srcLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (DoLet false false (PVar "output") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliLines") (EVar "srcLines")) (EVar "target")) (EApp (EVar "findingToDiag") (EVar "f"))))) (EVar "findings")))) (DoLet false false (PVar "hasOutput") (EBinOp ">" (EApp (EVar "stringLength") (EVar "output")) (ELit (LInt 0)))) (DoLet false false PWild (EIf (EBinOp "&&" (EVar "multiFile") (EVar "hasOutput")) (EApp (EVar "putStrLn") (EBinOp "++" (EVar "target") (ELit (LString ":")))) (ELit LUnit))) (DoLet false false PWild (EIf (EVar "hasOutput") (EApp (EVar "putStrLn") (EVar "output")) (ELit LUnit))) (DoExpr (ETuple (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")) (EListLit (EVar "entry")) (EVar "parsed")))))))
(DTypeSig false "lintEntryOf" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "LintEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "lintEntryOf" ((PVar "idx") (PCon "None") (PVar "target") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "entry") (PVar "pos") (PVar "decls")) (EApp (EApp (EApp (EApp (EApp (EVar "lintFileFresh") (EVar "idx")) (EVar "target")) (EVar "src")) (ELit (LString ""))) (EVar "False"))) (DoExpr (ETuple (EVar "entry") (EListLit (ETuple (EVar "target") (EVar "src") (EVar "pos") (EVar "decls")))))))
(DFunDef false "lintEntryOf" ((PVar "idx") (PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) (PVar "target") (PVar "src")) (EBlock (DoLet false false (PVar "hash") (EApp (EVar "contentHashOf") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadEntry") (EVar "cacheDir")) (EVar "stamp")) (EVar "target")) (EVar "hash")) (arm (PCon "Some" (PVar "hit")) () (ETuple (EVar "hit") (EListLit))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "entry") PWild PWild) (EApp (EApp (EApp (EApp (EApp (EVar "lintFileFresh") (EVar "idx")) (EVar "target")) (EVar "src")) (EVar "hash")) (EVar "True"))) (DoExpr (ETuple (EVar "entry") (EListLit)))))))))
(DTypeSig false "lintFileFresh" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "LintEntry") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "lintFileFresh" ((PVar "idx") (PVar "target") (PVar "src") (PVar "hash") (PVar "wantOccs")) (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositionsLocated") (EVar "src"))) (DoExpr (ETuple (ERecordCreate "LintEntry" ((fa "path" (EVar "target")) (fa "contentHash" (EVar "hash")) (fa "findings" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "idx")) (EVar "allRules")) (EVar "target")) (EVar "src")) (EVar "pos")) (EVar "decls"))) (fa "dupOccs" (EIf (EVar "wantOccs") (EApp (EVar "fileDupOccs") (ETuple (EVar "target") (EVar "pos") (EVar "decls"))) (EListLit))) (fa "directives" (EApp (EVar "collectDirectives") (EVar "src"))) (fa "dirty" (EVar "True")))) (EVar "pos") (EVar "decls")))))
(DTypeSig false "lintOneFileFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "lintOneFileFix" ((PVar "onlyNames") (PVar "disableNames") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PTuple (PVar "newSrc") (PVar "n")) (EApp (EApp (EApp (EApp (EApp (EVar "applyFixes") (EVar "onlyNames")) (EVar "disableNames")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "newSrc") (EVar "src")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "fixed 0 finding(s) in ")) (EVar "target")))) (DoExpr (EVar "False"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "target")) (EVar "newSrc")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "fixed ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) in "))) (EApp (EVar "display") (EVar "target"))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))))))
# MARK
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "joinNl" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" false) (mem "parseWithPositions" false) (mem "parseWithPositionsLocated" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "findProjectRoot" false) (mem "findProjectRootOrSelf" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" false) (mem "cjAllToJson" false) (mem "diagIsError" false) (mem "ppDiagCliLines" false) (mem "ppDiagCliSrc" false) (mem "srcLinesArr" false))))
(DUse false (UseGroup ("support" "cli_targets") ((mem "collectMdkFiles" false) (mem "expandLintTarget" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "Directive" false) (mem "Finding" false) (mem "StdlibIndex" false) (mem "allRules" false) (mem "applyFindingDeny" false) (mem "applyFindingFilters" false) (mem "applyFixes" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsMultiDirs" false) (mem "collectDirectives" false) (mem "crossFileCacheSound" false) (mem "fileDupOccs" false) (mem "findingToDiag" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "lintFileDiagTripleParsed" false) (mem "lintProgram" false) (mem "mergeCrossFileIntoTriples" false) (mem "runCrossFileRules" false) (mem "runCrossFileRulesFromOccs" false) (mem "stdlibFingerprint" false))))
(DUse false (UseGroup ("tools" "lint_cache") ((mem "LintEntry" true) (mem "cacheDirOf" false) (mem "contentHashOf" false) (mem "loadEntry" false) (mem "ruleSetStamp" false))))
(DUse false (UseGroup ("tools" "lint_baseline") ((mem "LintBaseline" false) (mem "applyBaselineToDiags" false) (mem "applyBaselineToFindings" false) (mem "baselineDiagViolations" false) (mem "baselineKeyOf" false) (mem "baselineViolationLine" false) (mem "baselineViolations" false) (mem "diagCodeOf" false) (mem "findingRuleOf" false))))
(DTypeSig true "lintCacheCtx" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lintCacheCtx" ((PCon "False") PWild) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "True")) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "False")) (EIf (EApp (EVar "not") (EVar "crossFileCacheSound")) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "root") (EApp (EVar "findProjectRootOrSelf") (EApp (EVar "canonicalizePath") (ELit (LString "."))))) (DoLet false false (PVar "binStamp") (EApp (EVar "ruleSetStamp") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "binStamp") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (ETuple (EApp (EVar "cacheDirOf") (EVar "root")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "binStamp"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "stdlibFingerprint"))) (ELit (LString "")))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "runLintJsonCmd" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "runLintJsonCmd" ((PVar "idx") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "files")) (EBlock (DoLet false false (PVar "quads") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagQuads") (EVar "idx")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "files"))) (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "dropQuadParse")) (EVar "quads"))) (DoLet false false (PVar "cross") (EApp (EApp (EApp (EApp (EVar "crossFileJsonFindings") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "quads"))) (DoLet false false (PVar "merged") (EApp (EApp (EVar "mergeCrossFileIntoTriples") (EVar "cross")) (EVar "triples"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "cjAllToJson") (EVar "merged")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "cjLintTripleHasErr")) (EVar "merged")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))
(DTypeSig true "crossFileJsonFindings" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "crossFileJsonFindings" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "quads")) (EBlock (DoLet false false (PVar "parsedTriples") (EApp (EApp (EMethodRef "map") (EVar "quadToParseTriple")) (EVar "quads"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "parsedTriples"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EApp (EMethodRef "map") (EVar "quadToSrc")) (EVar "quads"))) (EVar "raw"))) (DoExpr (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed")))))
(DTypeSig false "quadToParseTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "quadToParseTriple" ((PTuple (PVar "path") PWild PWild (PVar "pos") (PVar "decls"))) (ETuple (EVar "path") (EVar "pos") (EVar "decls")))
(DTypeSig false "quadToSrc" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "quadToSrc" ((PTuple (PVar "path") (PVar "src") PWild PWild PWild)) (ETuple (EVar "path") (EVar "src")))
(DTypeSig false "dropQuadParse" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "dropQuadParse" ((PTuple (PVar "path") (PVar "src") (PVar "diags") PWild PWild)) (ETuple (EVar "path") (EVar "src") (EVar "diags")))
(DTypeSig true "lintFilesToDiagQuads" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))))))))))))
(DFunDef false "lintFilesToDiagQuads" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintFilesToDiagQuads" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PVar "baseCtx") (PCons (PVar "f") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "applyBaselineQuad") (EVar "baseCtx")) (EApp (EApp (EApp (EApp (EApp (EVar "lintFileDiagTripleParsed") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "f"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagQuads") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "baseCtx")) (EVar "rest"))))
(DTypeSig false "applyBaselineQuad" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "applyBaselineQuad" ((PCon "None") (PVar "quad")) (EVar "quad"))
(DFunDef false "applyBaselineQuad" ((PCon "Some" (PTuple (PVar "cwd") (PVar "base"))) (PTuple (PVar "path") (PVar "src") (PVar "diags") (PVar "pos") (PVar "decls"))) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EVar "baselineKeyOf") (EVar "cwd")) (EVar "path"))) (DoLet false false PWild (EApp (EApp (EVar "reportBaselineViolations") (EVar "key")) (EApp (EApp (EApp (EVar "baselineDiagViolations") (EVar "base")) (EVar "key")) (EVar "diags")))) (DoExpr (ETuple (EVar "path") (EVar "src") (EApp (EApp (EApp (EVar "applyBaselineToDiags") (EVar "base")) (EVar "key")) (EVar "diags")) (EVar "pos") (EVar "decls")))))
(DTypeSig true "lintFilesToDiagTriples" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))))
(DFunDef false "lintFilesToDiagTriples" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintFilesToDiagTriples" ((PVar "idx") (PVar "disable") (PVar "only") (PVar "deny") (PVar "baseCtx") (PCons (PVar "f") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "applyBaselineTriple") (EVar "baseCtx")) (EApp (EApp (EApp (EApp (EApp (EVar "lintFileDiagTriple") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "f"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "idx")) (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "baseCtx")) (EVar "rest"))))
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
(DTypeSig true "runCrossFileReport" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runCrossFileReport" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "parsed")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "parsedToTriple")) (EVar "parsed"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "triples"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EApp (EMethodRef "map") (EVar "parsedToSrc")) (EVar "parsed"))) (EVar "raw"))) (DoExpr (EApp (EVar "reportCrossFindings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))))))
(DTypeSig true "runCrossFileReportCached" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runCrossFileReportCached" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "entries")) (EBlock (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRulesFromOccs") (EVar "onlyNames")) (EVar "disableNames")) (EApp (EApp (EDictApp "flatMap") (EVar "entryOccs")) (EVar "entries")))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMultiDirs") (EApp (EApp (EMethodRef "map") (EVar "entryDirTable")) (EVar "entries"))) (EVar "raw"))) (DoExpr (EApp (EVar "reportCrossFindings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))))))
(DTypeSig false "entryOccs" (TyFun (TyCon "LintEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "entryOccs" ((PVar "e")) (EFieldAccess (EVar "e") "dupOccs"))
(DTypeSig false "entryDirTable" (TyFun (TyCon "LintEntry") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))))
(DFunDef false "entryDirTable" ((PVar "e")) (ETuple (EFieldAccess (EVar "e") "path") (EFieldAccess (EVar "e") "directives")))
(DTypeSig false "reportCrossFindings" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "reportCrossFindings" ((PList)) (EVar "False"))
(DFunDef false "reportCrossFindings" ((PVar "findings")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "cross-file:")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "renderCrossFinding")) (EVar "findings"))))) (DoExpr (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")))))
(DTypeSig false "renderCrossFinding" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "renderCrossFinding" ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (ELit (LString ""))) (EApp (EVar "locFileOf") (EFieldAccess (EVar "f") "loc"))) (EApp (EVar "findingToDiag") (EVar "f"))))
(DTypeSig false "locFileOf" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locFileOf" ((PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild))) (EVar "file"))
(DFunDef false "locFileOf" ((PCon "None")) (ELit (LString "")))
(DTypeSig false "parsedToTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parsedToTriple" ((PTuple (PVar "path") PWild (PVar "pos") (PVar "decls"))) (ETuple (EVar "path") (EVar "pos") (EVar "decls")))
(DTypeSig false "parsedToSrc" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "parsedToSrc" ((PTuple (PVar "path") (PVar "src") PWild PWild)) (ETuple (EVar "path") (EVar "src")))
(DTypeSig true "resolveLintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "resolveLintTargets" ((PList)) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoExpr (EMatch (EApp (EVar "findProjectRoot") (EVar "cwd")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: no medaka.toml found; run from a project directory or pass file/dir paths")))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit)))) (arm (PCon "Some" (PVar "root")) () (EApp (EVar "collectMdkFiles") (EVar "root")))))))
(DFunDef false "resolveLintTargets" ((PVar "targets")) (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets")))
(DTypeSig true "lintFilesGo" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))))))
(DFunDef false "lintFilesGo" (PWild PWild PWild PWild PWild PWild PWild PWild (PList) (PVar "acc")) (ETuple (EVar "acc") (EListLit) (EListLit)))
(DFunDef false "lintFilesGo" ((PVar "idx") (PVar "fixMode") (PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "cacheCtx") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EIf (EVar "fixMode") (EBlock (DoLet false false (PVar "hadErr") (EApp (EApp (EApp (EVar "lintOneFileFix") (EVar "onlyNames")) (EVar "disableNames")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "idx")) (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))) (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "entries") (PVar "parsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileReport") (EVar "idx")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "f"))) (DoLet false false (PTuple (PVar "restErr") (PVar "restEntries") (PVar "restParsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "idx")) (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr")))) (DoExpr (ETuple (EVar "restErr") (EBinOp "++" (EVar "entries") (EVar "restEntries")) (EBinOp "++" (EVar "parsed") (EVar "restParsed")))))))
(DTypeSig false "lintOneFileReport" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline"))) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))))
(DFunDef false "lintOneFileReport" ((PVar "idx") (PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "baseCtx") (PVar "cacheCtx") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (ETuple (EVar "True") (EListLit) (EListLit))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "entry") (PVar "parsed")) (EApp (EApp (EApp (EApp (EVar "lintEntryOf") (EVar "idx")) (EVar "cacheCtx")) (EVar "target")) (EVar "src"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressionsDirs") (EFieldAccess (EVar "entry") "directives")) (EFieldAccess (EVar "entry") "findings"))) (DoLet false false (PVar "filtered") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "allFindings"))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EVar "applyBaselineFindings") (EVar "baseCtx")) (EVar "target")) (EVar "filtered"))) (DoLet false false (PVar "srcLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (DoLet false false (PVar "output") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliLines") (EVar "srcLines")) (EVar "target")) (EApp (EVar "findingToDiag") (EVar "f"))))) (EVar "findings")))) (DoLet false false (PVar "hasOutput") (EBinOp ">" (EApp (EVar "stringLength") (EVar "output")) (ELit (LInt 0)))) (DoLet false false PWild (EIf (EBinOp "&&" (EVar "multiFile") (EVar "hasOutput")) (EApp (EVar "putStrLn") (EBinOp "++" (EVar "target") (ELit (LString ":")))) (ELit LUnit))) (DoLet false false PWild (EIf (EVar "hasOutput") (EApp (EVar "putStrLn") (EVar "output")) (ELit LUnit))) (DoExpr (ETuple (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")) (EListLit (EVar "entry")) (EVar "parsed")))))))
(DTypeSig false "lintEntryOf" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "LintEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "lintEntryOf" ((PVar "idx") (PCon "None") (PVar "target") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "entry") (PVar "pos") (PVar "decls")) (EApp (EApp (EApp (EApp (EApp (EVar "lintFileFresh") (EVar "idx")) (EVar "target")) (EVar "src")) (ELit (LString ""))) (EVar "False"))) (DoExpr (ETuple (EVar "entry") (EListLit (ETuple (EVar "target") (EVar "src") (EVar "pos") (EVar "decls")))))))
(DFunDef false "lintEntryOf" ((PVar "idx") (PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) (PVar "target") (PVar "src")) (EBlock (DoLet false false (PVar "hash") (EApp (EVar "contentHashOf") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadEntry") (EVar "cacheDir")) (EVar "stamp")) (EVar "target")) (EMethodRef "hash")) (arm (PCon "Some" (PVar "hit")) () (ETuple (EVar "hit") (EListLit))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "entry") PWild PWild) (EApp (EApp (EApp (EApp (EApp (EVar "lintFileFresh") (EVar "idx")) (EVar "target")) (EVar "src")) (EMethodRef "hash")) (EVar "True"))) (DoExpr (ETuple (EVar "entry") (EListLit)))))))))
(DTypeSig false "lintFileFresh" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "LintEntry") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "lintFileFresh" ((PVar "idx") (PVar "target") (PVar "src") (PVar "hash") (PVar "wantOccs")) (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositionsLocated") (EVar "src"))) (DoExpr (ETuple (ERecordCreate "LintEntry" ((fa "path" (EVar "target")) (fa "contentHash" (EMethodRef "hash")) (fa "findings" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "idx")) (EVar "allRules")) (EVar "target")) (EVar "src")) (EVar "pos")) (EVar "decls"))) (fa "dupOccs" (EIf (EVar "wantOccs") (EApp (EVar "fileDupOccs") (ETuple (EVar "target") (EVar "pos") (EVar "decls"))) (EListLit))) (fa "directives" (EApp (EVar "collectDirectives") (EVar "src"))) (fa "dirty" (EVar "True")))) (EVar "pos") (EVar "decls")))))
(DTypeSig false "lintOneFileFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "lintOneFileFix" ((PVar "onlyNames") (PVar "disableNames") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PTuple (PVar "newSrc") (PVar "n")) (EApp (EApp (EApp (EApp (EApp (EVar "applyFixes") (EVar "onlyNames")) (EVar "disableNames")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "newSrc") (EVar "src")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "fixed 0 finding(s) in ")) (EVar "target")))) (DoExpr (EVar "False"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "target")) (EVar "newSrc")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "fixed ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) in "))) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))))))
