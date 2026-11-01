# META
source_lines=4738
stages=DESUGAR,MARK
# SOURCE
import support.diag_codes.{DiagCode(..), codeText}
import driver.main_autoprint.{executedMainInputs}
import types.capability_manifest.{
  EntryKey(..), ManifestSelector(..), InvocationProtocol(..)
}
-- compiler/driver/medaka_cli.mdk — the native `medaka` CLI dispatcher (Phase C
-- Slice 0+1).  Compiled natively (`medaka build compiler/driver/medaka_cli.mdk -o
-- ./medaka`) this is a Medaka CLI replacing bin/main.ml's check/fmt/new
-- subcommands with no OCaml at runtime.
--
--   ./medaka check <file.mdk>     type-check (parse→…→typecheck), via check.runCheck
--   ./medaka fmt [--stdout|--check|--write] <file.mdk>   format (default: --check, read-only; --write rewrites)
--   ./medaka new <name>           scaffold a new project
--   ./medaka help | --help | -h   usage
--
-- Stdlib paths (runtime.mdk / core.mdk) resolve from MEDAKA_ROOT, mirroring
-- compiler/driver/build_cmd.mdk's envOr — compiler has no getcwd/executable_name
-- extern.  The implemented subcommands are exactly the dispatch arms below
-- (check/fmt/new/build/run/test/repl/lsp/doc/check-policy/manifest/gate/interface); any other
-- subcommand falls through to the catch-all, which prints "not yet in native
-- CLI" and exits 1.

import tools.check.{
  checkModulesReport,
  entryExhaust,
}
import tools.snapshot.{
  runSnapshotWorker,
  runSnapshotSupervisor,
  parseStages,
  SnapMode(..),
}
import tools.fmt.{formatSourceChecked, FmtMode(..)}
import tools.gate_cmd.{gateHelpText, runGateCmd}
import tools.interface_cmd.{interfaceHelpText, runInterfaceCmd}
import tools.new_cmd.{newProject}
import driver.build_cmd.{
  BuildReport,
  BuildTarget(..),
  ppBuildReport,
  runBuild,
  emitRtObj,
  emitPreludeObj,
  envOr,
  defaultMedakaRoot,
  readPreludeSources,
  loadPreludeInterface,
  PreludeInputs(..),
  SideFile(..),
  staleLine,
  shippedInputs,
  FileVerdict,
  checkPreludeElab,
  loadPreludeElab,
  preludeDeclsVerdict,
  reportStaleLine,
}
import support.util.{
  reverseL,
  joinNl,
  joinWith,
  splitNl,
  startsWith,
  endsWith,
  anyList,
  filterList,
  contains,
  sortUniqS,
  listLen,
  schemeLineName,
  stringTrim,
  lookupAssoc,
}
import support.opcount.{setOpCounting, opSnap}
import support.stage_count.{stageCountInit, stageDump, stageExit}
import support.ordmap.{OrdMap, omEmpty, omHasKey, omFromNames}
import support.path.{baseOf, chopExt, joinPath}
import support.timer.{
  perfEnabled,
  now,
  emitPhase,
  emitPhaseAO,
  allocSnap,
  emitTotal,
  perfArm,
  emitAbortTotal,
  perfSinkOn,
  flushPerfSinkProse,
}
import list.{sortOn, head}
import driver.profile_select.{manifestProfileOf, carryProjectProfile}
import types.target_profile.{
  Backend(..),
  buildableNames,
  lookupProfile,
  profileBackend,
  runProfile,
  selectedProfile,
}
import tools.target_check.{targetRefusal, ppTargetDiag, foldTargetDiags}
import string.{toInt}
-- S-cli-onto-args (#2355): the ONE argument parser.  Every verb's flag
-- vocabulary below is an `ArgSpec` value, so its `(known: …)` roster, its
-- rejection sentences and what it actually parses are three renderings of one
-- declaration instead of three hand-kept lists.  `docs/design/ARGS-DESIGN.md`.
import args.{
  ArgSpec,
  Args(..),
  spec,
  switch,
  value,
  internal,
  parseArgs,
  flag,
  flagValue,
  lastValue,
  flagValues,
  unknownFlagMessage,
  usageExitCode,
  withStrictDash,
}
import frontend.ast.{
  letBindName, Decl(..), ExternDecl(..), Expr(..), Loc(..), Pat, LetBind(..),
  EvTable, EvId
}
import frontend.parser.{
  parseWithPositions,
  parseWithPositionsLocated,
  parseResult,
  parseLocatedResult,
  Positions,
}
import frontend.lexer.{tokenizeWithOffsetPairs}
import frontend.desugar_cache.{desugaredPrelude, preludeGeneration}
import frontend.desugar.{desugarIn}
import tools.target_parse.{targetDesugared}
import driver.loader.{
  loadProgramFilesLocatedE,
  stdinEntry,
  readStdinProgram,
  stdinReadOverride,
  readSource,
  readSourceE,
  sourceNotUtf8Message,
  dropPathTriple,
  modIdToPath,
  findProjectRoot,
  findProjectRootOrSelf,
  entrySearchRoots,
  projectTrustedMods,
  stdlibOwnership,
}
import driver.front_gate.{
  GateAsk(..),
  cliStdlibExports,
  envelopeWithNotes,
  moduleLoadErrText,
  ppParseError,
}
import driver.diagnostics.{
  desugaredModPairs,
  CheckDrive(..),
  CheckDump(..),
  frontEnd,
  checkFrontDrive,
  FrontProgram(..),
  FrontInput(..),
  FrontPolicy(..),
  FrontOutput(..),
  ppDiagCli,
  ppDiagCliSrc,
  ppDiagCliLines,
  renderTcDiags,
  ppDiagBuckets,
  stdlibExportsReader,
  diagOfResError,
  diagOfTypeError,
  relDiagPath,
  srcLinesArr,
  Diag(..),
  DiagId(..),
  diagIdIsSyntax,
  Severity(..),
  Severity(..),
  cjPosition,
  cjRange,
  cjRangeOfLoc,
  cjDiagnostic,
  cjFileEntry,
  cjAllToJson,
  flushRunEnvelope,
  pendingStaleNotice,
  pendingPreludeNotices,
  readDiagSrc,
  optField,
  cjFixJson,
  mkDiag,
  checkJsonFileParts,
  CheckJson(..),
  ppCheckJson,
  cjFoldIntoFile,
  readFileSafe,
  diagIsError,
  diagIsWarn,
  cohWarnsOfTriple,
  joinedOrNone,
  renderTripleErrors,
  renderTripleWarnings,
  residualOrGeneric,
  coherenceWarnCode,
  runBuildWarnCodes,
  isCoherenceWarn,
  mainShapeWarnings,
  mainEntryError,
  ppMainEntryError,
}
import json.{
  Json(..),
  jObject,
  jArray,
  stringify,
  parse as parseJson,
  asString,
}
import types.publish.{TcReport(..), tcCode}
import types.program_facts.{ProgramFacts, factsOfChecked}
import types.typecheck.{
  TcDiag,
  driveInputsFor,
}
import types.tc_types.{DriveInputs(..), DriveOutputs(..)}
import driver.main_autoprint.{
  asyncMainShapeError,
  shouldAutoPrintMain,
  valueMainCandidate,
  executedFromReport,
}
import eval.eval.{
  evalModulesOutputRunFacts,
  currentEvalFile,
  modulePathMap,
  runJsonMode,
  pendingRunDiags,
  progArgsRef,
}
import tools.test_cmd.{
  runTest,
  runTestReport,
  runTestGradedReport,
  filterMatchedNothing,
  testHelpText,
  testArgSpec,
  parseTestEngines,
  parseTestCasesFlag,
  parseTestIntFlag,
  runTestOne,
  cliTestReportOk,
  cliTestReportJson,
  cliGradedTestReportOk,
  cliGradedTestReportJson,
  checkTestMdkRoster,
  testFilesGo,
  runEvalPropsWorker,
}
import tools.prop_runner.{seedPropRng, PropRequest(..)}
import tools.doctest.{Engine(..)}
import tools.repl.{initSession, replLoop}
import tools.lsp.{runServer}
import tools.mcp.{runMcpServer}
import tools.doc.{
  runDoc,
  ModuleDoc,
  computeModuleDoc,
  docParseError,
  mdName,
  renderModulePage,
  renderIndex,
  libraryInventoryJson,
  rebucketLibraryImpls,
}
import tools.lint.{
  allRules,
  lintProgram,
  StdlibIndex,
  StdlibIndexError(..),
  indexForRun,
  applySuppressions,
  applySuppressionsMulti,
  applySuppressionsDirs,
  applySuppressionsMultiDirs,
  collectDirectives,
  findingToDiag,
  Finding,
  Directive,
  applyFixes,
  allRuleNames,
  applyFindingFilters,
  applyFindingDeny,
  isFindingError,
  lintFileDiagTriple,
  splitLintNames,
}
import tools.lint_cache.{storeEntries}
import tools.lint_baseline.{
  LintBaseline,
  readLintBaseline,
  baselineKeyOf,
  baselineViolations,
  baselineViolationLine,
  applyBaselineToFindings,
  applyBaselineToDiags,
  baselineDiagViolations,
  diagCodeOf,
  findingRuleOf,
  renderLintBaseline,
}
import tools.codemod.{
  findCodemod,
  codemodMk,
  codemodWarnDecls,
  codemodListing,
  codemodSource,
  CodeMode(..),
}
import tools.lint_cmd.{
  explainRule,
  lintCacheCtx,
  lintHelpText,
  renderRuleRowsJson,
  renderRuleRowsNames,
  renderRuleRowsText,
  rulesPageMarkdown,
  selectRuleRows,
  runLintJsonCmd,
  lintFilesToDiagTriples,
  baselineFileCodes,
  runProjectReport,
  resolveLintTargets,
  lintFilesGo,
  LintRun(..),
  inactiveInternalRuleUse,
}
import support.cli_targets.{lintTargetExists, expandLintTarget}
import tools.check_policy.{
  runCheckPolicy,
  PolicyArgs(..),
  PolicyOutcome(..),
  runManifest,
  ManifestArgs(..),
  analyzeProgramReport,
  EntryAnalysis(..),
  TargetInputs(..),
}

-- FLAG for user confirmation: exact version NUMBER not yet confirmed — using
-- "0.1.0-preview" (the 0.1.0 public-preview target named in AGENTS.md)
-- pending sign-off. In compiler/, the only other copy of this literal is
-- `serverVersion` in compiler/entries/lsp_main.mdk, which must match it; lsp.mdk
-- and mcp.mdk take the value as a parameter. (new_cmd.mdk hardcodes a literal
-- "0.1.0" into scaffolded medaka.toml.)
medakaVersion : String
medakaVersion = "0.1.0-preview"

-- Full version string: version + commit + build date, from the ONE stamping
-- seam (issue #74 W8) — test/build_native_medaka.sh stamps commit/build-date
-- alongside the fingerprint, surfaced via the `buildCommit`/`buildDate`
-- externs (same empty-on-absent contract as `buildFingerprint`). Degrades to just the bare version when neither is
-- baked (a dev/interpreted run, or a shipped binary with no provenance).
-- Used by `printVersion` (CLI `--version`) only. MCP's `initialize` handshake
-- reports the bare `medakaVersion` instead, not this — a per-build string
-- that changes on every commit is unstable as a protocol field and unpinnable
-- by any golden.
medakaVersionString : Unit -> <IO> String
medakaVersionString _ =
  let commit = buildCommit ()
  let date = buildDate ()
  if commit == "" && date == "" then
    "medaka " ++ medakaVersion
  else if commit == "" then
    "medaka \{medakaVersion} (built \{date})"
  else if date == "" then
    "medaka \{medakaVersion} (\{commit})"
  else
    "medaka \{medakaVersion} (\{commit}, built \{date})"

printVersion : Unit -> <IO> Unit
printVersion _ = putStrLn (medakaVersionString ())

-- ── staleness guard (issue #89) ─────────────────────────────────────────────
-- A ./medaka built in tree Y but run against tree X's NEWER compiler sources
-- silently applies OLD compiler semantics (an old binary misreads `1.5e3` as
-- `Unbound variable: e3`), and the version string ("0.1.0-preview") never moves,
-- so it is useless as a staleness signal.  test/build_native_medaka.sh stamps the
-- compiler-source fingerprint into the binary (surfaced by the `buildFingerprint`
-- extern); here we recompute the SAME fingerprint over the LIVE <root>/compiler
-- and <root>/stdlib and warn on a mismatch.  MEDAKA_STRICT=1 promotes the warning
-- to a hard error.  Runs on every invocation, so it is gated TIGHTLY:
-- only when a stamp was baked AND <root>/compiler is present (a shipped binary
-- has neither).
--
-- `liveSourceFingerprint` reproduces src_fingerprint_compiler() from the build
-- script byte-for-byte: names AND contents of `find compiler -name '*.mdk'
-- -not -name '*_test.mdk'` PLUS `find stdlib -name '*.mdk' -not -name
-- '*_test.mdk'`, combined and `LC_ALL=C sort`ed together, hashed by the same
-- hash_stream chain (sha256sum → shasum → cksum). stdlib/ is on this list
-- because it is compiled INTO the CLI binary too (a compiler/*.mdk module can
-- import stdlib/*.mdk), so a stdlib-only edit must be visible to this check
-- exactly like a compiler/*.mdk edit (issue #2682). The per-file `while read;
-- cat` shell loop the script uses costs ~110ms (118 forks); we stream through
-- ONE perl process (~16ms, verified byte-identical).  perl absent → the guard
-- exits non-zero → None → the check silently skips (never a false warning).
--
-- `*_test.mdk` siblings are excluded on BOTH sides: a test sibling is linked into
-- no binary, so hashing one would make editing a test report the compiler stale.
liveSourceFingerprint : String -> <IO> Option String
liveSourceFingerprint root =
  let script = stringConcat [
    "command -v perl >/dev/null 2>&1 || exit 7; cd \"", root,
    "\" && { find compiler -name '*.mdk' -not -name '*_test.mdk' -print;",
    " find stdlib -name '*.mdk' -not -name '*_test.mdk' -print; } | LC_ALL=C sort",
    " | perl -ne 'chomp; print \"$_\\n\"; open F,\"<\",$_ or next; local $/; my $c=<F>; print $c if defined $c; close F' 2>/dev/null",
    " | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; elif command -v shasum >/dev/null 2>&1; then shasum -a 256; else cksum; fi; }",
    " | cut -d' ' -f1"
  ]
  match runCommand "sh" ["-c", script]
    -- fail-open-by-design: any failure (no perl, no hash tool, spawn error)
    -- reports None, per the comment above ("the check silently skips").
    Ok (0, out, _) =>
      let h = stringTrim out
      if h == "" then None else Some h
    _ => None

-- The staleness VERDICT, factored out of `checkSourceStaleness` (#846) so the
-- MCP layer (compiler/tools/mcp.mdk) can surface the SAME fingerprint check
-- per tool call, not just once as a CLI-startup stderr warning a tool-calling
-- agent never sees. `mcp.mdk` cannot import this module directly (medaka_cli
-- is the top of the dependency graph — it is the one that imports mcp.mdk),
-- so this is threaded down as a closure instead (`runMcpServer`'s 4th
-- argument): `Some compilerDir` on a mismatch, `None` when fresh, unknown
-- (no baked stamp — a dev build or a shipped binary), or the `compiler/`
-- directory itself is missing.
sourceStalenessVerdict : Unit -> <IO> Option String
sourceStalenessVerdict _ =
  let baked = buildFingerprint ()
  if baked == "" then
    None
  else
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let compilerDir = joinPath root "compiler"
    if not (fileExists compilerDir) then
      None
    else match liveSourceFingerprint root
      None => None
      Some live => if live == baked then None else Some compilerDir

-- C4 (docs/ops/CLI-CONFORMANCE.md §4): `run --json` is the ONE invocation whose
-- MACHINE channel is stderr — `run`'s stdout belongs to the user program — and
-- this warning is written to stderr.  Emitting it as prose there corrupts the
-- envelope; SILENCING it would hide a stale binary from every MCP/LSP consumer,
-- a severity INCREASE dressed as a fix ([W-QUIETER]).  So on that one path the
-- verdict is DEFERRED into `pendingStaleNotice` and rides INSIDE the envelope
-- as a `staleBinary` field — the same shape `attachStaleness` already uses for
-- MCP results.  Every `run --json` arm that leaves WITHOUT an envelope flushes
-- it back out as prose (`runAbort`), so it is relocated on every path, dropped
-- on none.
--
-- MEDAKA_STRICT keeps its hard stop and keeps printing prose: it exits before
-- any envelope can exist, so prose is the only channel there is.
checkSourceStaleness : List String -> <IO> Unit
checkSourceStaleness argv = match sourceStalenessVerdict ()
  None => ()
  Some compilerDir =>
    let msg =
      "warning: this ./medaka was built from compiler source that differs from "
        ++ compilerDir
        ++ "; rebuild with `make medaka`"
    if envOr "MEDAKA_STRICT" "" /= "" then
      dieMsg msg
    else if runJsonInvocation argv then
      pendingStaleNotice := Some msg
    else
      ePutStrLn msg

-- The check family's prelude: load `<stdlibDir>/core.mdki` into the prelude
-- cache, and report a stale file on stderr, once per process: the interface,
-- then the declarations `readPreludeSources` took or did not.  Under
-- MEDAKA_STRICT a stale file stops the verb, as a stale binary does.  `run`
-- and `build` do not call this: `run --json`'s machine channel is stderr.
loadCheckPrelude : PreludeInputs -> <IO> Unit
loadCheckPrelude prelude =
  let verdict = loadPreludeInterface prelude
  let _ = reportStaleLine dieMsg None (staleLine InterfaceFile verdict)
  reportDecls None dieMsg prelude

-- The same load for a verb outside the check family, which prints nothing: a
-- stale file only means core is checked from source.
seedCheckPrelude : PreludeInputs -> <IO> Unit
seedCheckPrelude prelude =
  let _ = loadPreludeInterface prelude
  ()

-- A tree-arm verb's report of the prelude's elaborated trees, made once by the
-- verb's own process: one stderr line when `stdlib/core.mdke` is stale, a stop
-- under MEDAKA_STRICT (through [stop]), and nothing for a missing, disabled or
-- loaded file.  [staging] (`run --json`, C4) stages the line for the envelope.
reportTrees : Option (String -> Unit) ->
  (String -> <IO> Unit) ->
  FileVerdict ->
  <IO> Unit
reportTrees staging stop verdict =
  reportStaleLine stop staging (staleLine TreesFile verdict)

-- The same report for the prelude's declarations (`stdlib/core.mdkd`), made
-- after the verb's own demand of the trees, so a body that failed to decode
-- there is reported too.
reportDecls : Option (String -> Unit) ->
  (String -> <IO> Unit) ->
  PreludeInputs ->
  <IO> Unit
reportDecls staging stop prelude =
  reportStaleLine
    stop
    staging
    (staleLine DeclsFile (preludeDeclsVerdict prelude))

-- `run --json`'s staging of a stale line as the envelope's [field], when
-- [jsonMode]; none otherwise.
deferredInto : Bool -> String -> Option (String -> Unit)
deferredInto False _ = None
deferredInto True field = Some (msg =>
  pendingPreludeNotices := !pendingPreludeNotices ++ [(field, msg)])

-- A verb that stages no line.
unstaged : String -> Option (String -> Unit)
unstaged _ = None

-- `run`'s prelude: hold the interface and the elaborated trees beside `core.mdk`,
-- so its drive skips core's pass, and report the trees' and the declarations'
-- verdicts, each staged as [stagingFor] says for its envelope field.
takeShippedPrelude : (String -> Option (String -> Unit)) ->
  PreludeInputs ->
  <IO> Unit
takeShippedPrelude stagingFor prelude =
  let _ = loadPreludeInterface prelude
  let _ =
    reportTrees
      (stagingFor "stalePreludeTrees")
      runAbort
      (loadPreludeElab prelude)
  reportDecls (stagingFor "stalePreludeDecls") runAbort prelude

-- The same two reports from the files' headers alone, for a `run` that stops
-- before it uses the prelude: nothing is loaded or decoded.
reportShippedHeaders : (String -> Option (String -> Unit)) ->
  PreludeInputs ->
  <IO> Unit
reportShippedHeaders stagingFor prelude =
  let _ =
    reportTrees
      (stagingFor "stalePreludeTrees")
      runAbort
      (checkPreludeElab prelude)
  reportDecls (stagingFor "stalePreludeDecls") runAbort prelude

-- The trees' verdict for a verb whose emitter children take them (`build`,
-- `test`), read without decoding them; the children print nothing.  The
-- declarations' verdict is this process's own.
reportChildTrees : PreludeInputs -> <IO> Unit
reportChildTrees prelude =
  let _ = reportTrees None dieMsg (checkPreludeElab prelude)
  reportDecls None dieMsg prelude

-- Is this argv `medaka run … --json …`?  The predicate is deliberately the
-- BYTE-IDENTICAL one `runRunCmd` uses to compute its own `jsonMode`
-- (`runFlagGiven "--json"` over the whole post-verb argv, program passthrough args
-- included).  If the two ever disagreed, a deferred notice would be staged for
-- an invocation that never emits an envelope — i.e. suppression — so they are
-- kept the same predicate on purpose, imprecision included.
runJsonInvocation : List String -> Bool
runJsonInvocation ("run" :: rest) = runFlagGiven "--json" rest
runJsonInvocation _ = False

-- Print the deferred staleness notices as prose and clear them.  Called from every
-- exit that is NOT the envelope: `run`'s error arms (via `runAbort`) and
-- `dispatchSub`'s `--help`.  A no-op whenever nothing was deferred.
flushStaleNoticeProse : Unit -> <IO> Unit
flushStaleNoticeProse _ =
  let _ = match !pendingStaleNotice
    None => ()
    Some msg =>
      pendingStaleNotice := None
      ePutStrLn msg
  let notices = !pendingPreludeNotices
  pendingPreludeNotices := []
  emitWarningLines (map snd notices)

-- `run`'s error exit: report `msg` and leave with 1, first flushing BOTH
-- deferred notices as prose — the staleness verdict and, under `--json`, the
-- `[perf]` lines `runRunCmd` armed `support.timer`'s sink to buffer.  These
-- arms emit human diagnostics rather than the JSON envelope even under
-- `--json` (pre-existing; see the report's Notes), so there is no envelope for
-- either notice to ride, and prose is the only channel left; two more prose
-- lines are not a channel regression — whereas losing them is ([W-QUIETER]).
-- Order mirrors plain `run`: staleness (emitted at startup there) first, then
-- the `[perf]` lines (emitted as each phase ends), then the error.  Both
-- flushes are no-ops when nothing was staged, so every non-`--json` run and
-- every run without MEDAKA_PERF is byte-identical.
-- The tree's uniform print-and-exit shape outside `run`'s flush-then-print
-- path (#2264 shape B): print `msg` to stderr and exit 1.  Structurally
-- identical to `entries/entry_support.failWith`, but not consolidatable with
-- it here: that module is documented as `medaka run`-only scaffolding, free
-- to import the whole compiler, which `medaka_cli.mdk` — compiled into the
-- shipped binary and part of the emitter seed graph — cannot do.
dieMsg : String -> <IO> Unit
-- lint-disable-next-line rule-duplicate-body
dieMsg msg =
  let _ = emitAbortTotal ()
  let _ = ePutStrLn msg
  stageExit 1

runAbort : String -> <IO> Unit
runAbort msg =
  let _ = flushStaleNoticeProse ()
  let _ = emitAbortTotal ()
  let _ = flushPerfSinkProse ()
  dieMsg msg

-- `run`'s success chain repeatedly unwraps a `Result String a`, aborting via
-- `runAbort` on `Err`; `orExit` is that unwrap made generic, so each step in
-- the chain composes as one flat `let` instead of nesting the rest of the
-- function inside the `Ok` arm.  The `panic` below never runs — `runAbort`'s
-- `exit` ends the process first — it exists only so both match arms share
-- type `a`.
orExit : Result String a -> <IO> a
orExit (Ok v) = v
orExit (Err msg) =
  let _ = runAbort msg
  panic msg

main : <IO> Unit
main =
  let _ = stageCountInit ()
  let _ = checkSourceStaleness (args ())
  let _ = runCli ()
  stageDump ()

runCli : Unit -> <IO> Unit
runCli _ = match args ()
  [] => usage ()
  "help" :: _ => usage ()
  "--help" :: _ => usage ()
  "-h" :: _ => usage ()
  "--version" :: _ => printVersion ()
  "-v" :: _ => printVersion ()
  "version" :: _ => printVersion ()
  "check" :: rest => dispatchSub checkHelpText runCheckCmd rest
  "fmt" :: rest => dispatchSub fmtHelpText runFmtCmd rest
  "new" :: rest => runNewCmd rest
  "build" :: rest => runBuildCmd rest
  "run" :: rest => dispatchSub runHelpText runRunCmd rest
  "test" :: rest => dispatchSub testHelpText runTestCmd rest
  "snapshot" :: rest => dispatchSub snapshotHelpText runSnapshotCmd rest
  "doc" :: rest => dispatchSub docHelpText runDocCmd rest
  "lint" :: rest => dispatchSub lintHelpText runLintCmd rest
  "codemod" :: rest => dispatchSub codemodHelpText runCodemodCmd rest
  "check-policy" :: rest =>
    dispatchSub checkPolicyHelpText runCheckPolicyCmd rest
  "manifest" :: rest => dispatchSub manifestHelpText runManifestCmd rest
  "gate" :: rest => dispatchSub gateHelpText runGateCmd rest
  "interface" :: rest => dispatchSub interfaceHelpText runInterfaceCmd rest
  "repl" :: rest => runReplCmd rest
  "lsp" :: rest => runLspCmd rest
  "mcp" :: rest => runMcpCmd rest
  sub :: _ => unknownSubcommand sub

-- #1348: `medaka <sub> --help`/`-h` would otherwise fall straight into the
-- subcommand's own argv parsing, which (for every subcommand below) treats
-- an unrecognized leading-`-` token as either a hard parse error or — worse,
-- for `check`/`run`/`doc`/etc, whose parsers only strip a small flag
-- ALLOWLIST — a literal filename, so `medaka fmt --help` reported "unknown
-- flag: --help" and `medaka check --help` tried to read a file named
-- `--help`. `build`/`new`/`repl`/`lsp`/`mcp` already special-case `--help`/
-- `-h` internally (kept as-is); this intercepts it centrally for the rest,
-- at the FIRST position only — a `--help` appearing after a real target is
-- passed through unchanged (e.g. a program's own `--help` passthrough arg
-- to `medaka run prog.mdk --help`).
dispatchSub : String -> (List String -> <IO> Unit) -> List String -> <IO> Unit
dispatchSub help _ ("--help" :: _) =
  let _ = flushStaleNoticeProse ()
  let _ = putStrLn help
  stageExit 0
dispatchSub help _ ("-h" :: _) =
  let _ = flushStaleNoticeProse ()
  let _ = putStrLn help
  stageExit 0
dispatchSub _ run rest = run rest

-- ── usage (mirrors bin/main.ml print_usage) ───────────────────────────────
-- Takes Unit so the interpreter's top-level-value evaluation doesn't fire its
-- IO eagerly (native build only runs main); native CLI prints it on demand.
usage : Unit -> <IO> Unit
usage _ =
  putStrLn
    (stringConcat [
      "medaka. A functional language compiler\n", "\n", "Usage:\n",
      "  medaka                    Show this message\n",
      "  medaka run [--json] [--allow-internal] [--release] <file.mdk | -> [args...]   Type-check and run a program\n",
      "  medaka build <file.mdk> [-o <out>] [--keep-ir]  Compile to a native binary (LLVM + clang)\n",
      "  medaka check [--json] [--types] [--allow-internal] <file.mdk>    Type-check without running\n",
      "  medaka test [--native | --engines eval,native] [--filter <substring>] [--seed <n>] [--cases <n>] [file.mdk]    Run doctests + prop tests (--native runs doctests through a compiled native binary INSTEAD of the interpreter; --engines runs the listed set, exit is the AND)\n",
      "  medaka doc <file.mdk>     Generate Markdown documentation (one file; required)\n",
      "  medaka lint [paths...]    Lint files/dirs (style rules; --fix, --cache, --disable/--only/--deny=<rules,...>)\n",
      "  medaka codemod <name> [flags] [paths...]  Apply a named source-preserving AST transform (--write/--stdout)\n",
      "  medaka snapshot [--check|--new|--bless] [paths...]  Per-stage snapshot tests (--out <dir>, --stages <a,b,..>)\n",
      "  medaka fmt [paths...]     Report unformatted files (default; use --write to rewrite in place)\n",
      "  medaka new <name>         Scaffold a new project directory\n",
      "  medaka repl               Start an interactive REPL (reads stdin until EOF or :quit)\n",
      "  medaka lsp                Run the language server over stdio\n",
      "  medaka mcp                Run the MCP server over stdio (JSON-RPC for agents)\n",
      "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]  Check a plugin's inferred effects against an allow-list\n",
      "  medaka manifest <file.mdk> [--fn name]  Emit the verified capability manifest as TOML\n",
      "  medaka gate list [<selector>...] [--json]  Query the gate registry (test/gates.toml)\n",
      "  medaka gate run [<selector>...] [--dry-run]  Run the selected gates\n",
      "  medaka interface write|verify <module.mdk>, show <file.mdki>  Write, show or verify the prelude interface file\n",
      "  medaka help               Show this message\n",
      "  medaka --version          Show the compiler version\n"
    ])

-- ── unmatched subcommand ──────────────────────────────────────────────────
-- S-help-truthfulness (#2354): this used to say "not yet in native CLI",
-- which was true only while there WAS another CLI — the OCaml reference
-- compiler, removed 2026-06-26.  Since then the sentence has promised every
-- user that some other implementation already has the verb they typed.
--
-- Derivation of what reaches it: `dispatch` above matches every verb by
-- literal, so this arm is reached by exactly the tokens that are NOT verbs —
-- a typo, a removed verb, or a `--`-shaped token in verb position
-- (`medaka --zz`).  For EVERY input it can receive, "not yet" was false; the
-- verb does not exist, and no other CLI has it either.  So the honest answer
-- is the ratified REJECT-NAMED disposition (docs/ops/CLI-CONFORMANCE.md C2):
-- name the offending token and point at the roster.
unknownSubcommand : String -> <IO> Unit
unknownSubcommand sub =
  dieMsg
    "medaka: unknown subcommand `\{sub}`; run `medaka help` for the list of subcommands"

-- ── check ─────────────────────────────────────────────────────────────────

-- The CLI's import-hint reader: `cliStdlibExports` (compiler/driver/front_gate.mdk)
-- under the stdlib root every verb resolves `stdlib/` against, read at each call.
cliStdlibExportsEnv : List String -> <IO> List (String, List String)
cliStdlibExportsEnv names =
  cliStdlibExports (envOr "MEDAKA_ROOT" defaultMedakaRoot ++ "/stdlib") names

-- Reads <MEDAKA_ROOT>/stdlib/{runtime,core}.mdk + the target, runs
-- check.runCheck, prints schemes/diagnostics.  Mirrors check_main.mdk; exit 0
-- (runCheck reports diagnostics in-band, like the interpreted driver).
--
-- DRIVER-COLLAPSE Phase 4 (OPTION A): `check` now RESOLVES imports.  We load the
-- entry + its transitive imports via loadProgram (same roots/priority as run/build)
-- and route by module count: a 1-module load (no non-core imports) goes through the
-- single-file runCheck (full prelude+user scheme dump, byte-identical to the old
-- behaviour — keeps the no-import goldens green); a multi-module load goes through
-- the multi-module report (resolve + per-module-frame typecheck), so a valid
-- cross-module reference reports import-aware diagnostics instead of `UnknownModule`.
checkHelpText : String
checkHelpText = stringConcat [
  "medaka check — Type-check a file without running it\n", "\n", "Usage:\n",
  "  medaka check [--json] [--types] [--allow-internal] <file.mdk>\n", "\n",
  "  --json            emit the {\"files\":[...]} structured-diagnostics\n",
  "                    envelope instead of human text\n",
  "  --types           show the full inferred-scheme dump, prelude included\n",
  "                    (default: only your own top-level bindings; no effect\n",
  "                    under --json — the envelope carries diagnostics, not\n",
  "                    scheme dumps)\n",
  "  --allow-internal  permit internal-only externs outside stdlib/\n",
  "  --target <name>   refuse a program whose `main` performs a label this\n",
  "                    target profile does not grant (default: [target] in\n",
  "                    medaka.toml, else no target check)\n"
]

-- C2: `check`'s whole flag vocabulary, as `checkHelpText` documents it.
-- `--release` is deliberately NOT here: nothing documents it for `check` and
-- `runCheckCmd` never reads it, so it is REJECTED rather than stripped.  A
-- shared flag strip that dropped it for every consumer would accept it by
-- accident instead.  (The flag check runs before any strip, so the
-- rejection wins.)
-- `withStrictDash` (S-5, #2355 residual A): `check`'s file positional is what
-- an undeclared `-foo` would otherwise fall into (AS-FILENAME, exemplar X3) — an
-- undeclared single-dash token is now C2-rejected like `--foo` is.
checkArgSpec : ArgSpec
checkArgSpec =
  withStrictDash
    (spec "check" [
      switch ["--json"] "emit the structured-diagnostics envelope",
      switch ["--types"] "show the full inferred-scheme dump",
      switch
        ["--allow-internal"]
        "permit internal-only externs outside stdlib/",
      value ["--target"] "NAME" "target profile `main` must fit",
    ])

runCheckCmd : List String -> <IO> Unit
runCheckCmd argv =
  -- C2: the parse is the floor.  An unrecognized `--`-shaped token never
  -- reaches the positional list, which is how `medaka check --zzz` became an
  -- attempt to open a FILE named `--zzz` (AS-FILENAME, docs/ops/
  -- CLI-CONFORMANCE.md §5a, exemplar X3).
  let a = requireArgs checkArgSpec argv
  let perfOn = perfEnabled ()
  let perfT0 = now ()
  let jsonMode = flag "--json" a
  let allowInternal = flag "--allow-internal" a
  let typesMode = flag "--types" a
  match a.positionals
    [target] =>
      perfArm perfT0
      carryTargetProfile (lastValue "--target" a) target
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let stdlibDir = root ++ "/stdlib"
      let roots = entrySearchRoots (dirOf2 target) ++ [stdlibDir]
      match readPreludeSources stdlibDir
        Err msg => dieMsg msg
        Ok prelude =>
          let rsrc = prelude.pnRuntimeSrc
          let csrc = prelude.pnCoreSrc
          let _ = loadCheckPrelude prelude
          if jsonMode then
            -- E: `--types` requests a human-text scheme dump; the `--json`
            -- envelope has no field for one (structured diagnostics only), so
            -- rather than silently drop the flag (the S-2/S-3/S-4 residual),
            -- name the no-op on stderr — stdout stays the plain JSON envelope,
            -- byte-identical to `--json` alone (diff_native_cli/--json goldens
            -- unaffected).
            let _ =
              if typesMode then
                ePutStrLn
                  "medaka check: --types has no effect under --json; the envelope carries no scheme dump"
            runCheckJsonCmd allowInternal rsrc csrc target stdlibDir
          else match readSource target
            Err msg => dieMsg msg
            -- Load with parseLocated (real ELoc spans), mirroring `run`
            -- (line ~678): plain loadProgram uses placeholder-loc `parse`,
            -- which collapses every span to 1:0, so an import-bearing
            -- file's Unbound-variable diagnostic pointed at the import
            -- line instead of the actual use site.
            Ok tsrc => match loadProgramFilesLocatedE (_ => None) target roots
              Err lerr => match parseResult tsrc
                Err e => dieMsg (ppParseError tsrc target e)
                Ok _ =>
                  let _ = emitAbortTotal ()
                  let _ =
                    ePutStrLn (moduleLoadErrText tsrc target stdlibDir lerr)
                  stageExit 1
              Ok modsWithPath =>
                let mods = map dropPathTriple modsWithPath
                let trusted = projectTrustedMods target roots stdlibDir mods
                -- #2072: the FFI-stamp discriminator, handed to typecheck alongside the
                -- #1713 reference-trust set above.  Different predicate, deliberately: this
                -- one is stdlib-root ownership with no `allow-internal` opt-out.
                let (flatStdlib, ownedStdlib) =
                  stdlibOwnership target roots stdlibDir mods
                let inputs =
                  driveInputsFor !selectedProfile flatStdlib ownedStdlib
                let perfTLoad = now ()
                let _ = emitPhase perfOn "load" (perfTLoad - perfT0) target
                let _ =
                  checkRoute
                    inputs
                    typesMode
                    allowInternal
                    trusted
                    roots
                    rsrc
                    csrc
                    tsrc
                    target
                    modsWithPath
                let perfTCheck = now ()
                let _ = emitPhase perfOn "check" (perfTCheck - perfTLoad) target
                emitTotal perfOn (perfTCheck - perfT0)
    _ =>
      let _ =
        ePutStrLn
          "usage: medaka check [--json] [--types] [--allow-internal] [--target <profile>] <file.mdk>"
      stageExit 1
-- G1: print the report (byte-identical stdout for no-import files:
-- diff_native_cli gate), then gate the EXIT CODE on the error predicate
-- so CI `$?` matches OCaml `check` (exit 1 on any error).

-- A load error (missing/cyclic import) is reported verbatim, like
-- build/run; exit 1.  No-fixture single-file files never error here.

-- BOTH halves of a graph's diagnostics from ONE front-end run (`frontEnd`'s
-- per-file buckets): the rendered errors AND the COHERENCE warnings.
--
-- Why one pass.  `run`/`build`'s multi-module arms already call this analysis as
-- their check-strength gate and then THREW THE WARNINGS AWAY — so after F-3d demoted
-- the coherence reject onto the warning channel, a program those verbs would
-- reject compiled and ran with nothing on any channel.  A second entry point would
-- mean a second whole-front-end pass over the whole graph, which is the dominant
-- cost of the gate; splitting one pass's result costs a list filter.
--
-- 🚨 THE SECOND COMPONENT IS UNRENDERED, AND THAT IS LOAD-BEARING, NOT STYLE.
-- Medaka is STRICT, so `fst`-only callers — every `medaka check` of a multi-module
-- project — evaluate it too.  Returning RENDERED warning lines for the whole
-- channel here takes multi-module `check` from 16.0–17.1 s to 38.9–40.6 s
-- with byte-identical stdout: rendering a located diagnostic has to materialise the
-- containing file's lines (`ppDiagCliSrc` → `srcLinesArr`), so a rendered channel
-- pays that per file — thousands of times over a graph — for output nobody reads.
-- Now it is a `filter isCoherenceWarn` over already-materialised `Diag`s (no source
-- text touched), and rendering happens at the emit site — which also lets that site
-- choose human text or `--json`.  KEEP IT UNRENDERED.
--
-- Warnings are grouped by THEIR OWN file, never the entry's — the #414 hazard
-- `globalCoherenceConflict` documents, where a foreign span renders a caret at that
-- line/col in the wrong file.
--
-- ⚠️ ONE TRIPLE PER FILE, EMPTIES INCLUDED, in dependency-first order (helper before
-- entry) — do NOT filter the empties out here.  `checkRoute` identifies the ENTRY's
-- triple POSITIONALLY, as the last one (`dropEntryTriple`), because the paths
-- `analyzeProject` reports are loader-normalised (`./main.mdk`) and will not compare
-- equal to the CLI's own `target` argument.  Pre-filtering would make "last" mean
-- "the last module that happens to warn", so a clean entry would silently cost an
-- imported module its warning.  Emptiness is filtered at the emit sites instead.
-- #1719: the third component is a CHEAP count (no rendering — see the "KEEP IT
-- UNRENDERED" note above) of warning diagnostics that exist in a NON-ENTRY
-- module but are NEITHER an error NOR the one coherence code the second
-- component already carries — i.e. exactly the diagnostics human `check`
-- would otherwise drop with no trace (matchWarnings/exhaustiveness on an
-- imported module).  `check` uses this to print a one-line "N further
-- diagnostics" note instead of silently reading as clean; `run`/`build` (the
-- other two callers) ignore it, so their narrow-to-coherence behaviour and
-- its measured perf/noise rationale (see `isCoherenceWarn`) are untouched.
-- `results` are the buckets of a graph resolve accepted, one per loaded file.
locatedProjectDiags : List (String, List Diag) ->
  <IO> (Option String, List (String, String, List Diag), Int)
locatedProjectDiags results =
  let triples = map readDiagSrc results
  (
    joinedOrNone (flatMap renderTripleErrors triples),
    map cohWarnsOfTriple triples,
    length (flatMap hiddenWarnsOfTriple (dropEntryTriple triples)),
  )

-- `run --json`'s multi-module arms' own copy of `diagnostics.relDiagTriple`
-- (not exported there — only `relDiagPath`, its one-line body, is): strip the
-- project-root prefix from a triple's `file` so an imported module resolved
-- through the absolute `stdlibDir` root doesn't leak the worktree layout into
-- the envelope, matching `check --json`'s own multi-module normalization
-- (diagnostics.mdk's `checkJsonFileParts`, ~:2478-2482; #2798 review S2).
relDiagTriple : String ->
  (String, String, List Diag) ->
  (String, String, List Diag)
relDiagTriple root (path, src, diags) = (relDiagPath root path, src, diags)

-- the warn diagnostics on one (non-entry) module's triple that neither
-- channel above already surfaces (see the doc comment on `locatedProjectDiags`).
hiddenWarnsOfTriple : (String, String, List Diag) -> List Diag
hiddenWarnsOfTriple (_, _, diags) = filter isHiddenNonEntryWarn diags

isHiddenNonEntryWarn : Diag -> Bool
isHiddenNonEntryWarn d = diagIsWarn d && not (isCoherenceWarn d)

-- ── run --json structured error exit (#2798) ────────────────────────────────
-- `run`'s error arms would otherwise call `runAbort` unconditionally on a non-empty
-- diagnostic list, printing human caret text on stderr even under `--json` —
-- the ONE compile-time gap `runHelpText` otherwise carries as a documented KNOWN
-- GAP. `runAbortJson` is the JSON twin: it stages `triples` into the SAME
-- `pendingRunDiags` envelope the clean-exit (`finishRunEval`) and
-- runtime-panic (`eval.runtimePanic`) paths already flush, rather than
-- inventing a second JSON printer, so the staleness/perf notices ride the
-- envelope (`runEnvelopeFields`, read inside `flushRunEnvelope`) instead of
-- being flushed as prose ahead of it the way `runAbort` does.
runAbortJson : List (String, String, List Diag) -> <IO> Unit
runAbortJson triples =
  let _ = emitAbortTotal ()
  pendingRunDiags := nonEmptyTriples triples
  let _ = flushPendingRunDiags True
  stageExit 1

-- `run --json`'s structured counterpart to `ppDiagBuckets` over a graph resolve
-- rejected — one triple per file with at least one resolve error, left for
-- `cjAllToJson` (via `runAbortJson`) to serialize instead of a second JSON
-- printer.  `ResError` carries no warning variant (frontend.resolve.ResError,
-- all-error), so unlike the typecheck triples below there is no filter to widen
-- here.
resolveErrorJsonTriples : List (String, List Diag) ->
  <IO> List (String, String, List Diag)
resolveErrorJsonTriples [] = []
resolveErrorJsonTriples ((_, []) :: rest) = resolveErrorJsonTriples rest
resolveErrorJsonTriples ((file, diags) :: rest) =
  (file, readFileSafe file, diags) :: resolveErrorJsonTriples rest

-- The generic #1812 deflection (`residualOrGeneric`'s own `[] =>` arm), as a
-- `Diag` instead of prose, for the JSON residual arm's empty-residual case
-- below.  Same code family as the rest of this file's minted diagnostics
-- (`R-BUILD-FAILED` etc. in `cjBuildFailedJson`) — `T-RESIDUAL` names the one
-- circumstance this fires: the graph-end drain saw a type error the per-module
-- pass did not, so there is no located diagnostic to report instead.
--
-- NO KNOWN INPUT REACHES THIS ARM, so do not look for a fixture that covers it:
-- two reviewers failed to construct one, and the graph-end drain (`driveGraphK` in
-- `compiler/types/typecheck.mdk`) raises no diagnostic on a program the per-module
-- pass accepts, so nothing arms the gate that would route here without a located
-- diagnostic behind it.  It exists so
-- the empty-residual case cannot exit 1 with an empty envelope, which is a shape the
-- code must handle whether or not an input is known to produce it.  Documented in `compiler/DIAGNOSTIC-CODES-DESIGN.md`;
-- `test/diag_census.sh` cannot see it, since that census enumerates codes that FIRE.
genericResidualDiag : String -> Diag
genericResidualDiag target =
  mkDiag
    SevError
    TResidual
    ("type error in "
      ++ target
      ++ ", detected during elaboration; no located diagnostic is available,"
      ++ " and `medaka check` may not report it")
    None

-- `run --json`'s structured counterpart to `residualOrGeneric`/`renderTcDiags` —
-- one `Diag` triple per graph-end residual entry, attributed to its own module
-- id via `pathMap` exactly as the human renderer looks the file up, via the
-- SAME `diagOfTypeError` conversion.  Left unmerged across entries that land in
-- the same file — `pendingRunDiags` already carries repeated file entries on
-- this same envelope (`eval.runtimePanic`'s own append), so a second grouping
-- pass here would buy nothing.
--
-- Two guarantees `residualOrGeneric` states explicitly and this must match
-- (#2798 review S1): an EMPTY residual still yields the generic #1812 triple,
-- attributed to the ENTRY file — `runAbortJson` must never exit 1 with an
-- empty envelope, the JSON twin of "never leaves the user with exit 1 and no
-- text" — and a `pathMap` MISS (a module id the loader's map does not know)
-- attributes to the entry file too, rather than the non-path
-- `"(module <mid>)"` placeholder string a `file` field is not allowed to be.
residualJsonTriples : String ->
  List (String, String) ->
  List (String, TcDiag) ->
  <IO> List (String, String, List Diag)
residualJsonTriples entryFile _ [] =
  [(entryFile, readFileSafe entryFile, [genericResidualDiag entryFile])]
residualJsonTriples entryFile pathMap ((mid, d) :: rest) =
  match lookupAssoc mid pathMap
    Some file =>
      (file, readFileSafe file, [diagOfTypeError d])
        :: residualJsonTriples entryFile pathMap rest
    None =>
      (entryFile, readFileSafe entryFile, [diagOfTypeError d])
        :: residualJsonTriples entryFile pathMap rest

-- One front-end run (`frontEnd`, driven by `checkFrontDrive`), then the report
-- by module count: a single loaded module (no non-core imports) ⇒ the
-- single-file runCheck (byte-identical full dump); >1 module ⇒ the multi-module
-- import-resolving report.  `mods` is dependency-first, entry last.
-- `target` is passed for positioned error output (Stage-A: file:line:col: message).
--
-- 0.1.0 preview UX (audit #6): bare `medaka check` on a clean single-file
-- program would dump the ~120-line prelude `=== TYPES ===` scheme corpus
-- ahead of the user's own bindings — noisy and beginner-unfriendly. `typesMode`
-- (the `--types` flag) opts back into that full dump, byte-identical to the
-- historical behaviour (preserves the diff_native_cli goldens, which now pass
-- `--types`). Bare `check` instead keeps only the lines naming one of the
-- user's OWN top-level bindings (`userSchemeLines`) — filtering happens HERE,
-- CLI-only, so the probe-driven goldens (check_main.mdk et al., which call
-- `runCheck`/`checkModulesEntryLines` directly) keep dumping unconditionally.
--
-- BUGFIX (internal-extern noise on stdlib/compiler self-checks): `trusted`
-- (projectTrustedMods, owning-root based) lifts the guard for EVERY module
-- count, so `medaka check` on a bare stdlib file (e.g. `stdlib/array.mdk`, no
-- non-core imports ⇒ the single-file arm) does not flag its OWN legitimate
-- internal-extern calls unless the flag is passed every time.
-- S-3/#164: the single-file arm analyses the loader's parsed, real-span `decls`
-- for its one module, so the entry is not parsed a second time.
checkRoute : DriveInputs ->
  Bool ->
  Bool ->
  List String ->
  List String ->
  String ->
  String ->
  String ->
  String ->
  List (String, String, List Decl) ->
  <IO> Unit
checkRoute inputs typesMode allowInternal trusted roots rsrc csrc tsrc target modsWithPath =
  -- One desugar per module for the whole check: resolve, the drive and the entry
  -- exhaust read these same trees.
  let program = match modsWithPath
    [m] => FrontFile m
    _ => FrontGraph modsWithPath (desugaredModPairs modsWithPath)
  let front = frontEnd cliStdlibExportsEnv (checkFrontDrive
    target
    roots) FrontInput {
    fiInputs = inputs,
    fiAllowInternal = allowInternal,
    fiTrusted = trusted,
    fiRuntimeSrc = rsrc,
    fiCoreSrc = csrc,
    fiPolicy = NeverDriveRejected,
    fiProgram = program,
  }
  match program
    FrontFile (_, _, decls) =>
      checkFileReport typesMode rsrc csrc tsrc target decls front
    FrontGraph mods modPairs =>
      checkProjectReport rsrc csrc tsrc target mods modPairs front

-- `check`'s single-file report over its front-end run.
checkFileReport : Bool ->
  String ->
  String ->
  String ->
  String ->
  List Decl ->
  FrontOutput CheckDump ->
  <IO> Unit
checkFileReport typesMode rsrc csrc tsrc target decls front =
  let diags = flatMap snd front.foDiags
  let errs = filter diagIsError diags
  match errs
    [] =>
      -- Clean (no errors): the scheme dump goes to STDOUT loc-free, but any
      -- non-exhaustive-match WARNING is re-rendered LOCATED (file:L:C: + caret)
      -- to STDERR, byte-consistent with how errors render (line ~277).  The dump
      -- bundles the warning loc-free into stdout, so we strip its "Warning: …"
      -- lines and re-emit them from `diags` (which carries the real Loc the
      -- --json path already reports).  See ERROR-QUALITY.md (Located dimension).
      let warns = filter diagIsWarn diags
      -- The dump comes from the typecheck drive the front end already ran, so
      -- no second front end or elaboration is needed to print it.
      let dumpLines = match front.foDriven
        Some d => d.cdLines
        None => []
      let dump = stripWarningLines (joinNl dumpLines)
      let filtered = userSchemeLines decls dump
      let report = if typesMode then dump else filtered
      -- The target check reads the drive that produced the report, so there
      -- is no later elaboration to order the report ahead of.
      let _ = match front.foDriven
        Some d => checkTargetGate rsrc csrc tsrc target d.cdDrive
        None => ()
      let _ = putStrLn report
      -- #916: a clean single-file check gave no unambiguous success signal —
      -- "no error lines among the interface dump" was the only tell, and on a
      -- file whose filtered dump is EMPTY (no top-level bindings the dump
      -- names, e.g. a `main`-only script) there was no output at all. Print
      -- one terse trailing line naming the file and how many of ITS OWN
      -- declarations were checked, ADDITIVE to the (still byte-identical)
      -- scheme dump above so `--types`/`--json`/dict_semantics's exact-line
      -- scheme assertions are unaffected. `--types` keeps the historical
      -- unadorned full dump (still the byte-identical escape hatch).
      let _ = if typesMode then () else putStrLn (checkOkLine target filtered)
      -- The main-shape warning reads the raw entry decls alone, so its first
      -- three (ignored) parameters are passed empty.
      let mainWarns = mainShapeWarnings [] [] [] decls
      let _ = emitLocatedWarnings tsrc target (warns ++ mainWarns)
      ()
    _ =>
      let _ = emitAbortTotal ()
      let _ =
        ePutStrLn (joinNl (map (ppDiagCliLines (srcLinesArr tsrc) target) errs))
      stageExit 1

-- `check`'s multi-module report over its front-end run.  RESOLVE-phase errors
-- (e.g. importing a name a module does not export — PrivateNameAccess) go to
-- STDERR + exit 1, mirroring the single-file arm's channel discipline
-- (errors→stderr).  #41: each module's resolve errors are attributed to its OWN
-- file, not a single `target` fallback that mislabels every imported-module
-- error as the entry file.
checkProjectReport : String ->
  String ->
  String ->
  String ->
  List (String, String, List Decl) ->
  List (String, List Decl) ->
  FrontOutput CheckDump ->
  <IO> Unit
checkProjectReport rsrc csrc tsrc target mods modPairs front =
  match front.foDriven
    None => dieMsg (ppDiagBuckets front.foDiags)
    Some dump =>
      -- The entry's guard-exhaustiveness lines, rendered whenever resolve accepted
      -- the graph.
      let exWarns =
        entryExhaust (desugaredPrelude rsrc) (desugaredPrelude csrc) modPairs
      match locatedProjectDiags front.foDiags
        -- BUGFIX (imported-module diagnostics): when there ARE type errors, render
        -- the accumulated per-module diagnostics LOCATED (`file:L:C: msg` + caret),
        -- across ALL modules — reusing the exact analyzeProject surface `--json`
        -- mirrors — instead of the entry report's loc-free `TYPE ERROR: …` (which
        -- also dropped every imported-module error's location).  Clean ⇒ the schemes
        -- dump + main-shape warnings, unchanged.
        (Some errText, _, _) =>
          let _ = emitAbortTotal ()
          let _ = putStrLn errText
          stageExit 1
        (None, projWarns, hiddenCount) =>
          let report = checkModulesReport exWarns front.foReport.trDiagnostics
          let _ = checkTargetGate rsrc csrc tsrc target dump.cdDrive
          let _ = putStrLn report
          -- F-3d: an IMPORTED module's ⊑-incomparable pair, LOCATED against that
          -- module's own file.  The line above reaches the ENTRY's diagnostics only,
          -- which is why the entry triple is special-cased here (not the whole list)
          -- — see `trimEntryTriple` for the four graph positions this was silent in,
          -- and for why the entry is trimmed by code rather than dropped whole.
          let _ =
            emitWarningLines
              (flatMap renderTripleWarnings (trimEntryTriple projWarns))
          -- #1719: a non-entry module can carry OTHER warnings (chiefly
          -- non-exhaustive-match) that the line above does not surface — human
          -- `check` would otherwise drop these with no trace, reading as a clean
          -- bill of health.  Say so instead of staying silent; `--json` already
          -- reports them per-file.
          let _ = emitHiddenDiagNote hiddenCount
          -- The main-shape warning reads the entry module's raw decls alone, so its
          -- first three (ignored) parameters are passed empty.
          let mainWarns = match lastModPair (map dropPathTriple mods)
            Some (_, edecls) => mainShapeWarnings [] [] [] edecls
            None => []
          emitLocatedWarnings tsrc target mainWarns

-- ── main shape ──────────────────────────────────────────────────────────────
-- `check`'s warning (`mainShapeWarnings`) and `run`/`build`'s refusal
-- (`mainEntryError`) live in `compiler/driver/diagnostics.mdk`, beside the
-- section comment that states which verb reports which shape.

-- Last (String, List Decl) pair — the entry module (loader's `mods` is
-- dependency-first, entry last).
lastModPair : List (String, List Decl) -> Option (String, List Decl)
lastModPair [] = None
lastModPair [p] = Some p
lastModPair (_ :: rest) = lastModPair rest

-- ── the target check ────────────────────────────────────────────────────────
-- `check`'s refusal of a program its typecheck accepted, when a profile is
-- selected: the refusal is the verdict, so it replaces the clean report.
checkTargetGate : String ->
  String ->
  String ->
  String ->
  CheckDrive ->
  <IO> Unit
checkTargetGate rsrc csrc tsrc target drive =
  match checkTargetRefusal rsrc csrc target drive.cdPaths drive
    [] => ()
    ds =>
      let _ = emitAbortTotal ()
      let _ = ePutStrLn (joinNl (map (ppTargetDiag target tsrc) ds))
      stageExit 1

-- The selected profile's refusals of a typechecked program, judged from the
-- drive that typechecked it.  `paths` names each module's file.
checkTargetRefusal : String ->
  String ->
  String ->
  List (String, String) ->
  CheckDrive ->
  <IO> List Diag
checkTargetRefusal rsrc csrc target paths drive = match !selectedProfile
  None => []
  Some profile =>
    targetRefusal profile target paths (checkTargetInputs rsrc csrc drive)

-- The target verdict's inputs, off a check drive: `shouldAutoPrintMain` reads
-- the drive's outputs for its `main` type.  The preludes are the memoized trees
-- the drive read.
checkTargetInputs : String -> String -> CheckDrive -> TargetInputs
checkTargetInputs rsrc csrc drive =
  let core = desugaredPrelude csrc
  let printed =
    if shouldAutoPrintMain drive.cdOutputs.doEntryOutcome core drive.cdMods then
      lookupAssoc "println" drive.cdCoreSchemes
    else
      None
  TargetInputs {
    tiSchemes = drive.cdEntrySchemes ++ drive.cdCoreSchemes,
    tiEntryDecls = match lastModPair drive.cdMods
      Some (_, decls) => decls
      None => [],
    tiAutoPrintCall = printed,
    tiCore = core,
    tiModules = drive.cdMods,
    tiRuntime = desugaredPrelude rsrc,
    tiOutputs = drive.cdOutputs,
    tiStdlibOwned = [],
  }

-- `check --json`'s copy of the same refusal, folded into the entry's file.  A
-- check that found no error always has a drive; a missing one is a bug here.
checkTargetJson : String ->
  String ->
  String ->
  String ->
  CheckJson ->
  Option CheckDrive ->
  <IO> Option CheckJson
checkTargetJson rsrc csrc target stdlibDir cj drive = match !selectedProfile
  None => None
  Some _ => match drive
    None => panic "check --json --target: a clean check left no drive to judge"
    Some dr =>
      let paths =
        map ((mid, path) => (mid, reportKey stdlibDir cj path)) dr.cdPaths
      match (checkTargetRefusal rsrc csrc target paths dr, cj)
        ([], _) => None
        (ds, CjParts entry triples) =>
          Some
            (CjParts
              entry
              (foldTargetDiags entry (readFileSafe entry) ds triples))
        _ => None

-- A module's file as the report spells it: verbatim when the report has a row
-- for it, else relative to the root a multi-module report strips.
reportKey : String -> CheckJson -> String -> String
reportKey stdlibDir (CjParts _ triples) path =
  if any ((p, _, _) => p == path) triples then
    path
  else
    relDiagPath (dirOf2 stdlibDir) path
reportKey _ _ path = path

-- `run`'s refusal, against `eval/run` and the selected profile together.  An
-- entry `run` cannot start at all is left to `finishRunEval`'s own refusal.
-- `rel` spells each `--json` file as the envelope does.
runTargetGate : Bool ->
  ((String, String, List Diag) -> (String, String, List Diag)) ->
  String ->
  List (String, String) ->
  List (String, List Decl) ->
  EntryAnalysis ->
  <IO> Unit
runTargetGate jsonMode rel target pathMap mods analysis =
  let startable = match lastModPair mods
    Some (_, edecls) => isNone (mainEntryError edecls)
    None => False
  let refusal =
    if startable then
      targetRefusal
        (runProfile !selectedProfile)
        target
        pathMap
        analysis.eaTarget
    else
      []
  match refusal
    [] => ()
    ds =>
      let src = readFileSafe target
      match jsonMode
        True => runAbortJson (map rel (foldTargetDiags target src ds []))
        False => runAbort (joinNl (map (ppTargetDiag target src) ds))

-- ── `run`'s argv filter — TrailingRaw semantics (S-5, #2355 residual B) ────
-- S-cli-onto-args (#2355) migrated every other verb onto `stdlib/args.mdk`.
-- `run` keeps a LOCAL filter (not `args.mdk`'s own `TrailingRaw`) because
-- `run` still needs its own C2 rejection wording/ordering (the leading-dash
-- check in `runRunCmd`), but the SEMANTICS are now `args.mdk`'s TrailingRaw:
-- flag scanning stops at the first token that isn't one of run's own known
-- flags, and everything from there on — the entry file plus every token
-- after it — passes through completely untouched.
--
-- 🚨 FORMER KNOWN DEFECT, now fixed.  `runArgvFilter` used to filter the
-- WHOLE argv, so a `--json`/`--release`/`--allow-internal`/`--types` token
-- belonging to the USER PROGRAM (`medaka run argv.mdk --json`) was silently
-- eaten before it reached `progArgsRef` — contradicts docs/ops/
-- CLI-CONFORMANCE.md §4 D-2(b) ("everything after the first positional is
-- the program's argv"). Now it stops recursing at the first non-flag token
-- and returns the remainder verbatim, so `medaka run argv.mdk --json a b`
-- delivers `["--json", "a", "b"]` to the program.
--
-- `--types` is `check`'s flag, not `run`'s (`runRunCmd` never reads it), but
-- it was in the shared filter's arm list before the entry file and removing
-- it here would be a behaviour change on the PRE-positional prefix, so it
-- stays consumed there.
runArgvFilter : List String -> List String
runArgvFilter [] = []
runArgvFilter ("--json" :: rest) = runArgvFilter rest
runArgvFilter ("--release" :: rest) = runArgvFilter rest
runArgvFilter ("--allow-internal" :: rest) = runArgvFilter rest
runArgvFilter ("--types" :: rest) = runArgvFilter rest
runArgvFilter ("--target" :: _ :: rest) = runArgvFilter rest
runArgvFilter (x :: rest)
  | startsWith "--target=" x = runArgvFilter rest
runArgvFilter argv = argv

-- `--target`'s value in `run`'s pre-positional prefix, last one winning.
runTargetFlag : List String -> Option String
runTargetFlag argv = runTargetGo None argv

runTargetGo : Option String -> List String -> Option String
runTargetGo _ ("--target" :: v :: rest) = runTargetGo (Some v) rest
runTargetGo acc (x :: rest)
  | startsWith "--target=" x =
    runTargetGo (Some (stringSlice 9 (stringLength x) x)) rest
  | x == "--json"
    || x == "--release"
    || x == "--allow-internal"
    || x == "--types" = runTargetGo acc rest
  | otherwise = acc
runTargetGo acc [] = acc

-- Resolve `--target` (over the manifest) and carry the profile; a name the
-- table does not know aborts.
carryTargetProfile : Option String -> String -> <IO> Unit
carryTargetProfile flagValue entry = match carryProjectProfile flagValue entry
  Ok _ => ()
  Err m => dieMsg ("error: " ++ m)

-- True if the flag appears in `run`'s PRE-positional prefix ONLY — the same
-- prefix `runArgvFilter` consumes, program passthrough args (after the first
-- positional) excluded.  `runJsonInvocation` is required to match this
-- byte-for-byte (see its note); both now agree on the fixed, precise scope.
runFlagGiven : String -> List String -> Bool
runFlagGiven _ [] = False
runFlagGiven nm ("--target" :: _ :: rest) = runFlagGiven nm rest
runFlagGiven nm (x :: rest)
  | x == "--json"
    || x == "--release"
    || x == "--allow-internal"
    || x == "--types"
    || startsWith "--target=" x = x == nm || runFlagGiven nm rest
  | otherwise = False

-- ── C1/C2: the one flag floor every verb shares ────────────────────────────
-- docs/ops/CLI-CONFORMANCE.md §2 (RATIFIED).  Every verb rejects an
-- unrecognized `--`-shaped token in flag position; the rejection goes to
-- stderr, names the offending token AND the verb's known flag set, and exits
-- 1.  No verb may treat an unrecognized `--` token as a filename (the
-- AS-FILENAME cell `check`/`doc`/`check-policy`/`manifest` would otherwise occupy,
-- which turns a typo'd flag into `No such file or directory`), and no verb may
-- ignore one (`lint`'s SILENT-ACCEPT cell — exit 0, nothing printed,
-- indistinguishable from a clean run).
--
-- The wording is `medaka test`'s (#2316), which is the reference
-- implementation and the only one that told the reader what to type next.
-- `validateTestFlags` was the per-verb original; it now calls this, so ONE
-- writer owns the sentence, the exit code and the known-set rendering instead
-- of ten near-copies drifting apart (the tree carried FIVE wordings for this
-- one event).
--
-- C1 (§1) rides along, because the two conventions are the same scan: a
-- value-taking flag is recognised in BOTH spellings, so `--flag v` consumes
-- its value (never mistaking the value for a positional or for an unknown
-- flag) and `--flag=v` is the same flag.  Neither spelling is ever silently
-- dropped or reinterpreted.
--
-- S-cli-onto-args (#2355): the scan, the sentences and the `(known: …)`
-- rendering all live in `stdlib/args.mdk`, and every `<verb>ArgSpec` below is
-- the ONE declaration they are rendered from.  The per-verb `expandEqFlags` /
-- `collapseEqFlags` argv rewrites are gone with it — `args.mdk` accepts both
-- C1 spellings uniformly, so no verb has to normalise argv into the one
-- spelling its own parser happened to read.

-- The IO shape every migrated verb calls.  `requireArgs <verb>ArgSpec argv`
-- replaces the old `assertCliFlags "<verb>" bools values argv` at every site:
-- one call, one declaration, and the parsed `Args` handed back instead of
-- discarded (the old helper VALIDATED and then let each verb re-scan raw argv
-- with its own reader, which is how the two could disagree).
--
-- Rejections go to stderr and exit `usageExitCode` (C3 — ratified for every
-- rejection this helper owns, whatever the verb's other exit codes do).
--
-- ⚠️ `test/diff_compiler_cli_reject_floor.sh` derives its COVERED-VERB set from
-- the `requireArgs <name>ArgSpec` call sites here plus each spec's own
-- `spec "<verb>"` head.  Renaming this function, or the `…ArgSpec` suffix,
-- leaves both properties K and S uncovered-but-green — update that derivation
-- in the same commit.
requireArgs : ArgSpec -> List String -> <IO> Args
requireArgs sp argv = match parseArgs sp argv
  Ok a => a
  Err msg =>
    let _ = ePutStrLn msg
    let _ = stageExit usageExitCode
    Args { given = [], positionals = [], rest = [] }

-- ── check --json ───────────────────────────────────────────────────────────
-- Mirrors OCaml's `check --json` (bin/main.ml line ~863):
--   analyze_project → all_diagnostics_to_json → print_endline → exit
-- Key ordering matches OCaml/Yojson alphabetical insertion:
--   file entry:   file, diagnostics
--   diagnostic:   message, range, severity, source
--   range:        end, start
--   position:     character, line

-- Run check --json: mirrors OCaml's check --json (analyze_project → JSON).
-- Loads the graph once with the located loader and runs one `frontEnd` over it
-- (`checkJsonFileParts`), enveloped by module count as `checkRoute` reports.
-- When the load fails, the ENTRY's parse errors are detected FIRST via
-- parseResult; an IMPORTED module's are reported by the loader itself (#100),
-- attributed to that module.
-- Output: {"files":[{"file":<path>,"diagnostics":[...]}]}
-- Exits 1 if any error diagnostic; 0 otherwise.
-- The whole routing (parse-error / load-error / single / multi module) now lives
-- in `checkJsonFile` (driver.diagnostics), shared with the `medaka mcp`
-- medaka_check tool.  This driver prints the JSON and gates the exit code, and
-- on a clean program folds in the selected profile's refusal (`checkTargetJson`).
-- #333: `target` is `readFile`'d FIRST (mirrors `medaka_check`'s MCP handler,
-- `runCheckTool` in tools/mcp.mdk) so a nonexistent/unreadable path reports a
-- file-not-found diagnostic instead of falling into `checkJsonFile`'s import
-- loader, which otherwise misreports it as an unknown-module R-MODULE-LOAD
-- diagnostic (`checkJsonFile` reads the path itself via `readFileSafe`, which
-- swallows the error as `""`). This guard only validates readability; the
-- content it reads is discarded and `checkJsonFile` re-reads `target` for the
-- real run with full import resolution.
runCheckJsonCmd : Bool -> String -> String -> String -> String -> <IO> Unit
runCheckJsonCmd allowInternal rsrc csrc target stdlibDir =
  match readSourceE target
    Err e =>
      let _ = println (cjSourceReadJson target e)
      stageExit 1
    Ok _ =>
      let (cj, hasErr, drive) =
        checkJsonFileParts allowInternal rsrc csrc target stdlibDir
      let refused =
        if hasErr then
          None
        else
          checkTargetJson rsrc csrc target stdlibDir cj drive
      match refused
        Some refusedCj =>
          let _ = println (ppCheckJson refusedCj)
          stageExit 1
        None =>
          let _ = println (ppCheckJson cj)
          if hasErr then stageExit 1

-- #1078: `medaka build --json`'s envelope for a build-STAGE failure — the
-- emitter/clang step itself, AFTER the front-end gate has already passed.
-- Same `{"files":[...]}` shape as every other `--json` path (`cjAllToJson`),
-- one span-less `Diag` carrying the emitter's
-- own message verbatim, so a caller keying off `code` (AGENTS.md) can
-- distinguish this from a front-end R-*/T-* diagnostic. Registered in
-- compiler/DIAGNOSTIC-CODES-DESIGN.md.
cjBuildFailedJson : String -> String -> String
cjBuildFailedJson target msg = cjAllToJson [
  (target, "", [Diag SevError (Coded RBuildFailed) msg None None None]),
]

-- `medaka build --json`: one typecheck, in the emitter child, whose front-end
-- gate writes the envelope `check --json` prints for the program (the same
-- builders, so the bytes are the same): a refusal ends the build with it, and
-- a clean build prints it as its success marker, with the build's own notes
-- folded in — no separate "built X -> Y" prose on this channel, so a machine
-- consumer sees exactly one shape regardless of outcome.  A build-stage
-- failure (emitter/clang) becomes a `cjBuildFailedJson` envelope instead of the
-- plain rendered error text.
runBuildJsonCmd : Args ->
  Bool ->
  String ->
  String ->
  String ->
  Option String ->
  BuildTarget ->
  <IO> Unit
runBuildJsonCmd a allowInternal root stdlibDir input outOpt target =
  match readSourceE input
    Err e =>
      let _ = println (cjSourceReadJson input e)
      stageExit 1
    Ok entrySrc => match readPreludeSources stdlibDir
      Err msg =>
        let _ = println (cjBuildFailedJson input msg)
        stageExit 1
      Ok prelude =>
        let notices = jsonPreludeNotices target prelude
        let medaka = envOr "MEDAKA" "medaka"
        let cc = envOr "CC" "clang"
        let keepIrCli = flag "--keep-ir" a
        let stampBuild = flag "--stamp-build" a
        let outPath = match outOpt
          Some o => o
          None => defaultOutPath target input
        let ask =
          GateAsk { askAllowInternal = allowInternal, askDiagJson = True }
        -- `quietEmitStderr = True`: the child's verdict arrives as the
        -- envelope (`diagEnvelope`), so its human copy is not forwarded.
        match (runBuild
          root
          medaka
          cc
          target
          input
          outPath
          keepIrCli
          True
          stampBuild
          (Some ask))
          -- #2243: the build's own notes (a failed `--keep-ir` copy) join
          -- the entry file's `diagnostics` array rather than vanishing
          -- with the status line this channel never prints.
          Ok rep => match rep.diagEnvelope
            Some (entry, envelope) =>
              println
                (withPreludeFields
                  notices
                  (envelopeWithNotes entry rep.notes envelope))
            None =>
              let _ =
                println
                  (withPreludeFields
                    notices
                    (cjBuildFailedJson
                      input
                      "error: the emitter wrote no diagnostics envelope; an emitter built from an older medaka does not write one"))
              stageExit 1
          Err rep => match rep.diagEnvelope
            -- The front end refused the program.
            Some (_, envelope) =>
              let _ = println (withPreludeFields notices envelope)
              stageExit 1
            -- A build-stage FAILURE already carried its notes: they are
            -- part of the rendered message, exactly as the plain CLI
            -- prints them, inside the one R-BUILD-FAILED diagnostic.
            None =>
              let _ =
                println
                  (withPreludeFields
                    notices
                    (cjBuildFailedJson input (ppBuildReport rep)))
              stageExit 1

-- `build --json`'s stale lines, carried in its envelope as the field each
-- names rather than as prose; under MEDAKA_STRICT a line stops the verb, as a
-- stale binary does, before any envelope exists.  Only a native build's emitter
-- child takes the trees; this process took the declarations.
jsonPreludeNotices : BuildTarget -> PreludeInputs -> <IO> List (String, String)
jsonPreludeNotices target prelude =
  let staged = Ref []
  let stage = field => Some (msg => staged := staged.value ++ [(field, msg)])
  let trees = match target
    TNative => staleLine TreesFile (checkPreludeElab prelude)
    TWasm => None
  let _ = reportStaleLine dieMsg (stage "stalePreludeTrees") trees
  let _ =
    reportStaleLine
      dieMsg
      (stage "stalePreludeDecls")
      (staleLine DeclsFile (preludeDeclsVerdict prelude))
  staged.value

-- [envelope] with each of [notices] appended as its field.
withPreludeFields : List (String, String) -> String -> String
withPreludeFields [] envelope = envelope
withPreludeFields notices envelope = match parseJson envelope
  Ok (JObject pairs) =>
    stringify
      (jObject
        (toList pairs ++ map ((field, msg) => (field, JString msg)) notices))
  _ => envelope

-- The `{"files":[...]}` envelope for a target that could not be read at all —
-- a file-not-found/unreadable-path diagnostic, unlocated (no source to point
-- into), carrying its own stable code so a caller keying off `code` (per
-- AGENTS.md) can distinguish "the file doesn't exist" from "the module
-- doesn't exist" (R-MODULE-LOAD).
cjFileNotFoundJson : String -> String -> String
cjFileNotFoundJson target err =
  cjUnlocatedJson target RFileNotFound "cannot read file `\{target}`: \{err}"

-- The envelope for a target the entry read refused: `R-FILE-NOT-UTF8` for a
-- file that exists but is not UTF-8 text, else `R-FILE-NOT-FOUND`.
cjSourceReadJson : String -> Option String -> String
cjSourceReadJson target (Some e) = cjFileNotFoundJson target e
cjSourceReadJson target None =
  cjUnlocatedJson target RFileNotUtf8 (sourceNotUtf8Message target)

-- A one-diagnostic, unlocated `{"files":[...]}` envelope for `target`.
cjUnlocatedJson : String -> DiagCode -> String -> String
cjUnlocatedJson target code msg =
  let diagJson = jObject [
    ("code", JString (codeText code)),
    ("kind", JString "resolve"),
    ("message", JString msg),
    ("range", JNull),
    ("severity", JInt 1),
    ("source", JString "medaka"),
  ]
  let filesJson =
    jObject [("file", JString target), ("diagnostics", jArray [diagJson])]
  stringify (jObject [("files", jArray [filesJson])])

-- Drop the loc-free "Warning: …" lines the scheme dump carries, so
-- the located re-render (emitLocatedWarnings) is the single warning surface —
-- otherwise the CLI would print each warning twice (loc-free + located).  Scheme
-- lines are "name : type", never "Warning: …", so this only removes warnings.
stripWarningLines : String -> String
stripWarningLines s =
  joinNl (filter (l => not (startsWith "Warning: " l)) (splitNl s))

-- 0.1.0 preview UX (audit #6): filter the "name : scheme" dump down to
-- just the lines naming one of THIS file's own top-level bindings, dropping the
-- prelude's ~120 always-present schemes (eq/append/map/println/…). Each kept
-- line's name is matched by exact "\{name} : " prefix (scheme lines are never
-- "Warning: …" — those are already stripped by `stripWarningLines` upstream).
--
-- PERF: O(lines × log names).  This used to be O(lines × names) — an `anyList`
-- over EVERY top-level name per dump line, each probe allocating a fresh
-- "\{n} : " prefix string.  On a 2k-function file that is ~8.5M prefix builds +
-- compares, and it was the single largest cost of `medaka check` on a large
-- file.  A line's candidate name is uniquely determined (`schemeLineName`: the
-- text before its first " : ", since identifiers hold no space), so one set
-- lookup decides the line.
userSchemeLines : List Decl -> String -> String
userSchemeLines decls report =
  let names = omFromNames (topLevelNames decls) omEmpty
  joinNl (filter (namesUserBinding names) (splitNl report))

-- #916: the terse "clean check" success line. `filtered` is the ALREADY
-- user-scheme-filtered dump (empty string when a file names no bindings the
-- dump would show, e.g. a `main`-only script) — count its non-empty lines
-- rather than re-deriving from `decls`, so the number always matches what
-- the reader can see printed just above it.
checkOkLine : String -> String -> String
checkOkLine target filtered =
  let n = count (/= "") (splitNl filtered)
  "-- \{target}: ok (\{intToString n} declaration(s) checked, 0 errors)"

namesUserBinding : OrdMap Unit -> String -> Bool
namesUserBinding names l = match schemeLineName l
  Some n => omHasKey n names
  None => False

-- Every name a top-level Decl of this file introduces into value scope,
-- regardless of `pub` (single-file `check` has no module boundary to gate on).
topLevelNames : List Decl -> List String
topLevelNames [] = []
topLevelNames ((DAttrib _ d) :: rest) = topLevelNames [d] ++ topLevelNames rest
topLevelNames ((DFunDef _ n _ _ _ _) :: rest) = n :: topLevelNames rest
topLevelNames ((DTypeSig _ n _ _) :: rest) = n :: topLevelNames rest
topLevelNames ((DExtern (ExternDecl { edName = n, ... })) :: rest) =
  n :: topLevelNames rest
topLevelNames ((DLetGroup _ binds) :: rest) =
  map letBindName binds ++ topLevelNames rest
topLevelNames (_ :: rest) = topLevelNames rest

-- Re-render warning Diags LOCATED (file:L:C: + caret) to STDERR, exactly like
-- errors (ppDiagCliSrc).  Warnings do not change the exit code (stays 0).
emitLocatedWarnings : String -> String -> List Diag -> <IO> Unit
emitLocatedWarnings _ _ [] = ()
emitLocatedWarnings src file ws =
  ePutStrLn (joinNl (map (ppDiagCliLines (srcLinesArr src) file) ws))

-- Emit warning lines that are ALREADY rendered.  `run`/`build`'s multi-module arms
-- must render each warning against its OWN file (see `renderTripleWarnings`), which
-- `emitLocatedWarnings` cannot do — it takes one src/file pair for the whole list.
emitWarningLines : List String -> <IO> Unit
emitWarningLines [] = ()
emitWarningLines ls = ePutStrLn (joinNl ls)

-- #1719: human `check` on a multi-module project surfaces the entry module's
-- own warnings in full and every module's coherence warning (see the calls
-- above), but — for the measured perf/noise reasons `isCoherenceWarn` documents
-- — does not render a non-entry module's OTHER warnings (chiefly
-- non-exhaustive-match).  Rather than let that read as a clean bill of health,
-- name the count and point at `--json`, which already reports them per-file.
emitHiddenDiagNote : Int -> <IO> Unit
emitHiddenDiagNote 0 = ()
emitHiddenDiagNote 1 =
  ePutStrLn
    "1 further diagnostic in imported modules; rerun with --json to see it"
emitHiddenDiagNote n =
  ePutStrLn
    "\{intToString n} further diagnostics in imported modules; rerun with --json to see them"

-- The (path, src, warnings) triple of a SINGLE-file analysis.  The single-module
-- twin of what `locatedProjectDiags` returns, so both `run` arms hand
-- `finishRunEval` the SAME shape.
--
-- ⚠️ TRIPLES, NOT PRE-RENDERED STRINGS, and the reason is `--json`.  An earlier
-- revision passed `List String` rendered by `ppDiagCliSrc` at the call site — human
-- caret text, committed before the renderer knew whether it was writing to a human
-- or to a machine.  On `medaka run --json` that put caret art on a stream whose
-- documented contract is a `Diag` JSON envelope, and `diff_compiler_eval_json`
-- (which captures stderr ALONE) caught it.  Deferring the rendering to the emit
-- site is what lets one carrier serve both.
--
-- #2400 / F4.  This USED TO BE `cohWarnTriples`, filtering `isCoherenceWarn`; it now
-- filters `diagIsWarn`, and it is the ONLY place `run`/`build` widen past
-- `runBuildWarnCodes`.  (Its call site — `run`'s single-file arm — is
-- single-module, so nothing on the multi-module path lost a filter; those arms
-- carry `projWarns` from
-- `locatedProjectDiags` and still go through `cohWarnsOfTriple`/`isCoherenceWarn`.)
-- Read `isCoherenceWarn`'s 🚨 block first: it records why widening the WHOLE channel
-- to `diagIsWarn` was tried and reverted.  Every one of its three measured
-- objections is a property of the MODULE GRAPH, and none of them reaches this door:
--
--  (2) SPEW.  The volume is graph-borne: on the compiler's own graph the channel
--      carries 8 `W-NONEXHAUSTIVE-CLAUSES` and 2 `W-NONEXHAUSTIVE`, hand-graded
--      genuine now that the exhaustiveness oracle reads the constructors a module can
--      name (#1185).  A single file has no imported modules to add warnings from.
--  (3) PERF.  The render cost is "per file whose channel is non-empty"; here there
--      is exactly ONE file, already read into `src` for the error path.
--  (1) CRITERION.  `check`'s single-file arm (`checkFileReport`) and `run`'s
--      (`runRunCmd`'s `[_]` arm) apply the SAME `filter diagIsWarn` to the
--      diagnostics of one `frontEnd` run over the SAME `FrontFile` program.
--      Not to the same `diags` VALUE: `check` passes its `trusted` set as
--      `fiTrusted` and `run`'s single-file arm passes `[]`, a pre-existing
--      asymmetry that `run`'s own arm documents.  The front end's guard is
--      `internalGuardFor (fiAllowInternal || contains mid fiTrusted)`, which
--      decides only which constructs count as "internal" for `ResError` gating,
--      and every `ResError` reaches `diags` as a `SevError` via `diagOfResError`,
--      so the two results can differ ONLY in their ERROR set, never in the
--      `diagIsWarn` subset either arm surfaces.  So this cannot surface a
--      warning `check` does not already show: it makes the three verbs agree on
--      one input, which is the criterion.
--
-- The split is deliberate.  The multi-module arms (`locatedProjectDiags`'s
-- callers, `isHiddenNonEntryWarn`, `hiddenWarnsOfTriple`) stay on
-- `runBuildWarnCodes`; widening them would surface the graph's genuine
-- non-exhaustiveness warnings on every `run`/`build`, which is a decision about
-- those findings that the allowlist (`runBuildWarnCodes`) has not yet taken.
allWarnTriples : String ->
  String ->
  List Diag ->
  List (String, String, List Diag)
allWarnTriples src file diags = match filter diagIsWarn diags
  [] => []
  ws => [(file, src, ws)]

-- Drop triples with no warnings, so `cjAllToJson` never emits a `"diagnostics":[]`
-- entry for a file that had nothing to say.
nonEmptyTriples : List (String, String, List Diag) ->
  List (String, String, List Diag)
nonEmptyTriples ts = filter tripleHasDiags ts

-- Every module's coherence warnings EXCEPT the entry module's.
--
-- 🚨 WHY `check` NEEDS THIS AND `run`/`build` DO NOT.  `checkRoute`'s multi-module arm
-- already surfaces the ENTRY's coherence warning — the entry report bundles it
-- loc-free into the scheme dump it prints to stdout, and `globalCoherenceConflict`'s
-- cross-module finding is attached to the entry module too — so re-emitting the whole
-- list here would double-print exactly the shapes that already work.  What that stdout
-- path CANNOT reach is an IMPORTED module's own ⊑-incomparable pair: the entry report
-- reports the entry's diagnostics, not every module's.  Result, measured across the
-- seven positions a pair can occupy in a module graph: `check` reported the pair for
-- the entry (1) and the split-across-two-modules case (1) and **NOTHING AT ALL** when
-- the pair sat in a directly-imported, transitively-imported, bare-imported or
-- diamond-imported module — 0 occurrences on either channel, while `check --json`,
-- `run` and `build` all correctly reported 1.  That is the same loud→silent transition
-- F-3d exists to prevent, relocated from the VERB to the module POSITION.
--
-- ⚠️ POSITIONAL, and it must be: the entry is LAST in `locatedProjectDiags`' order
-- (dependency-first, helper before entry — that function's own contract), while the
-- PATHS it reports are loader-normalised (`./main.mdk`) and do not compare equal to
-- the CLI's `target`.  See that function for why the list must reach here UNFILTERED.
dropEntryTriple : List (String, String, List Diag) ->
  List (String, String, List Diag)
dropEntryTriple [] = []
dropEntryTriple [_] = []
dropEntryTriple (t :: rest) = t :: dropEntryTriple rest

-- #1499: the human multi-module `check` EMIT site trims the entry triple instead
-- of dropping it, and the difference is one measured cell.  `dropEntryTriple`
-- exists because the entry report — printed immediately above that emit — already
-- carries the ENTRY module's `W-INCOMPARABLE-IMPLS` on the typecheck warning
-- channel, so re-rendering the entry triple would print it TWICE.
-- `W-PRELUDE-METHOD-SHADOW` is NOT on that channel (it is an `analyzeProject`-side
-- Diag from `preludeStandaloneShadows`), so dropping the entry triple whole left it
-- silent in exactly one cell: multi-module human `check` with the collision in the
-- ENTRY module — while `check --json`, `run`, `build` and the imported-module
-- position all reported it (all five measured on this diff).  Trimming BY CODE
-- keeps the de-duplication that motivated `dropEntryTriple` and gives every other
-- allowlisted code exactly one channel.  A code added to `runBuildWarnCodes` that
-- the entry report DOES print must be added to `onTypecheckWarnChannel` too, or
-- human `check` will double-report it on the entry.
trimEntryTriple : List (String, String, List Diag) ->
  List (String, String, List Diag)
trimEntryTriple [] = []
trimEntryTriple [(p, s, ds)] =
  [(p, s, filter (d => not (onTypecheckWarnChannel d)) ds)]
trimEntryTriple (t :: rest) = t :: trimEntryTriple rest

-- `coherenceWarnCode` is pushed off the entry module's own diags, so the entry
-- report already prints it; without this test `trimEntryTriple` would leave it in
-- the entry triple and `check` would print it twice. `W-PRELUDE-METHOD-SHADOW` and
-- `W-IMPORT-METHOD-SHADOW` are NOT included — they are `analyzeProject`-side
-- `Diag`s the entry report does not print (see `trimEntryTriple`'s own comment), so
-- this is a one-code test, not a membership test over `runBuildWarnCodes`.
onTypecheckWarnChannel : Diag -> Bool
onTypecheckWarnChannel (Diag _ c _ _ _ _) = c == Coded coherenceWarnCode

tripleHasDiags : (String, String, List Diag) -> Bool
tripleHasDiags (_, _, []) = False
tripleHasDiags _ = True

-- #1348: writing REQUIRES `--write`. The bare form would otherwise default to
-- FmtWrite (silent in-place rewrite, no output, exit 0 whether or not
-- anything changed) — a destructive operation indistinguishable from a
-- no-op, and it once silently reformatted ~500 tracked files. The bare
-- default is now `FmtCheck`: read-only (never touches the file), reports
-- which files are NOT formatted (one line each, exit 1 if any), and is
-- SILENT + exit 0 when everything is already formatted — exactly `--check`
-- with no flag needed. This is chosen over defaulting to `--stdout`
-- (dumping the formatted source to stdout) because it is the one behaviour
-- that already generalizes uniformly across a single file, multiple files,
-- and a directory target (`--stdout` inherently requires exactly one file,
-- so a bare `medaka fmt somedir/` would need a second, different default);
-- it also matches the read-only convention of `gofmt -l`/`rustfmt --check`.
-- `--write` is the only mode that mutates, and it now prints a one-line
-- summary of what it did (`formatted N file(s)` / `already formatted`) —
-- see `fmtWriteSummaryLine` — so a write can never again produce zero
-- observable output.
--
-- A single literal-file target keeps the ORIGINAL single-file path
-- byte-for-byte (goldens depend on this).  A directory target (or multiple
-- targets) recursively expands via the SAME `expandLintTarget`/
-- `collectMdkFiles` walk `medaka lint` uses (dir/file discriminated by
-- `listDir`; skips dotfiles/dot-dirs; no test/-exclusion, matching lint's
-- own behavior) and formats every `.mdk` found, aggregating exit codes the
-- way `medaka lint`'s multi-file path does (any error → exit 1).
fmtHelpText : String
fmtHelpText = stringConcat [
  "medaka fmt — Format .mdk file(s)\n", "\n", "Usage:\n",
  "  medaka fmt [--check | --stdout | --write] <path>...\n", "\n",
  "Read-only unless --write is given.\n", "\n",
  "  (default)    same as --check: reports files that are not formatted\n",
  "               (exit 1 if any); prints nothing when already formatted.\n",
  "               Never writes.\n",
  "  --check      explicit form of the default\n",
  "  --stdout     print the formatted result to stdout (single file only);\n",
  "               never writes\n",
  "  --write, -w  rewrite the file(s) in place and print a one-line summary\n",
  "               (\"formatted N file(s)\" / \"already formatted\")\n", "\n",
  "A path may be a file or a directory (recursively expanded; dotfiles and\n",
  "dot-dirs are skipped).\n"
]

runFmtCmd : List String -> <IO> Unit
runFmtCmd argv =
  -- ORDER IS LOAD-BEARING and preserved: the mode-conflict check runs on RAW
  -- argv, BEFORE the parse, so `medaka fmt --write --stdout --zzz` still
  -- reports the conflict rather than the unknown flag.  Moving it after
  -- `requireArgs` would swap those two messages.
  let _ = assertFmtOneMode argv
  runFmtArgs (requireArgs fmtArgSpec argv)

-- §5f, mirroring `snapshotMode`: two modes at once is a person who does not
-- know which one they meant, and guessing for them is how an intended
-- `--write` becomes a no-op that still exits 0.
assertFmtOneMode : List String -> <IO> Unit
assertFmtOneMode argv = match fmtModeConflict argv
  [] => ()
  [_] => ()
  many =>
    let _ =
      ePutStrLn
        "medaka fmt: \{joinWith " " many} are mutually exclusive; pass one"
    stageExit 1

runFmtArgs : Args -> <IO> Unit
runFmtArgs a =
  -- C2: `fmt`'s classification is `-`-prefix, not `--`-prefix — PRE-EXISTING
  -- and deliberate, because `-w` is a real fmt flag, so a bare `-x` is a flag
  -- typo here and not a path.  `args.mdk` deliberately leaves an UNDECLARED
  -- single-dash token as a positional (a filename may start with `-`), so the
  -- extra half of fmt's rule is applied here rather than lost.
  let _ = assertFmtNoDashTargets a.positionals
  match (fmtModeOf a, a.positionals)
    (_, []) =>
      let _ =
        ePutStrLn "Usage: medaka fmt [--check | --stdout | --write] <path>..."
      stageExit 1
    -- `listDir` Err = literal file (EXACT original single-file behavior); Ok =
    -- a directory, recursively expanded.
    (mode, [target]) => match listDir target
      Err _ => fmtOne mode target
      Ok _ => fmtManyTargets mode [target]
    (mode, targets) => fmtManyTargets mode targets

-- C2/C3: an unrecognized flag exits 1, like every other verb's -- as do the
-- bare-usage and `no .mdk files found` arms above (C3: 2 is RESERVED).
assertFmtNoDashTargets : List String -> <IO> Unit
assertFmtNoDashTargets [] = ()
assertFmtNoDashTargets (x :: rest) =
  if stringLength x > 0 && stringSlice 0 1 x == "-" then
    dieMsg (unknownFlagMessage fmtArgSpec x)
  else
    assertFmtNoDashTargets rest

-- The three modes are LAST-WINS (`parseFmtArgs`'s pre-migration behaviour:
-- each arm overwrote `mode`).  `Args.given` keeps argv order and records the
-- CANONICAL name whichever spelling was typed, so `-w` lands here as
-- `--write`.  Default is `FmtCheck`.
fmtModeOf : Args -> FmtMode
fmtModeOf a = fmtModeGo a.given FmtCheck

fmtModeGo : List (String, Option String) -> FmtMode -> FmtMode
fmtModeGo [] m = m
fmtModeGo ((k, _) :: rest) m
  | k == "--check" = fmtModeGo rest FmtCheck
  | k == "--stdout" = fmtModeGo rest FmtStdout
  | k == "--write" = fmtModeGo rest FmtWrite
  | otherwise = fmtModeGo rest m

-- Multiple targets and/or a directory target: expand to concrete .mdk files
-- and format each, aggregating. `--stdout` only makes sense for one file.
fmtManyTargets : FmtMode -> List String -> <IO> Unit
fmtManyTargets FmtStdout _ =
  dieMsg "medaka fmt: --stdout requires exactly one file"
fmtManyTargets mode targets =
  let files = flatMap expandLintTarget targets
  match files
    [] => dieMsg "medaka fmt: no .mdk files found"
    _ =>
      let (hadErr, changed) = fmtFilesGo mode files (False, 0)
      let _ = match mode
        FmtWrite => putStrLn (fmtWriteSummaryLine changed)
        _ => ()
      if hadErr then stageExit 1

-- Fold over an expanded file list, formatting each and aggregating whether
-- any error occurred (read failure, parse error, or --check finding
-- unformatted output — mirrors `lintFilesGo`'s aggregation) AND, for
-- `--write`, how many files were actually rewritten (so the caller can print
-- the "#1348" summary line once for the whole batch rather than per file).
fmtFilesGo : FmtMode -> List String -> (Bool, Int) -> <IO> (Bool, Int)
fmtFilesGo _ [] acc = acc
fmtFilesGo mode (f :: rest) (errAcc, changedAcc) =
  let (hadErr, changed) = fmtOneReport mode f
  fmtFilesGo mode rest (
    errAcc || hadErr,
    changedAcc + (if changed then 1 else 0),
  )

-- One line summarizing a `--write` run over N files: 0 changed reads as
-- "already formatted" (mirrors `fmtOne`'s single-file wording), one file
-- changed keeps the singular, more than one pluralizes.
fmtWriteSummaryLine : Int -> String
fmtWriteSummaryLine 0 = "already formatted"
fmtWriteSummaryLine 1 = "formatted 1 file"
fmtWriteSummaryLine n = "formatted \{intToString n} files"

-- The line `fmt` and the codemods print for a file they could not read: the
-- encoding refusal carries its own path, any other failure is prefixed with it.
sourceReadLine : String -> Option String -> String
sourceReadLine file None = "error: \{sourceNotUtf8Message file}"
sourceReadLine file (Some msg) = "\{file}: \{msg}"

-- Like `fmtOne` but reports to stdout/stderr and RETURNS (hadErr, changed)
-- instead of exiting immediately, so `fmtFilesGo` can aggregate across many
-- files (the single-file path still calls `fmtOne` directly and exits per
-- its own original codes, unchanged). `changed` is only meaningful for
-- `FmtWrite` — every other mode returns `False` for it.
fmtOneReport : FmtMode -> String -> <IO> (Bool, Bool)
fmtOneReport mode file = match readSourceE file
  Err e =>
    let _ = ePutStrLn (sourceReadLine file e)
    (True, False)
  -- One lexing pass shared by the parse check and the formatter.
  Ok src => match tokenizeWithOffsetPairs src
    (toks, pairs) => match formatSourceChecked src toks pairs
      Err e =>
        let _ = ePutStrLn (ppParseError src file e)
        (True, False)
      Ok formatted => match mode
        FmtStdout =>
          let _ = putStr formatted
          (False, False)
        FmtCheck =>
          if formatted == src then
            (False, False)
          else
            let _ = ePutStrLn (file ++ ": not formatted")
            (True, False)
        FmtWrite =>
          if formatted == src then
            (False, False)
          else match writeFile file formatted
            Err msg =>
              let _ = ePutStrLn "\{file}: \{msg}"
              (True, False)
            Ok _ => (False, True)

fmtArgSpec : ArgSpec
fmtArgSpec = spec "fmt" [
  switch ["--check"] "report unformatted files; write nothing",
  switch ["--stdout"] "print the formatted source of one file",
  switch ["--write", "-w"] "rewrite the file in place",
]

-- §5f: `--write` and `--stdout` are mutually exclusive MODES, but both would
-- be accepted with `--stdout` silently winning — so `medaka fmt --write
-- --stdout f.mdk` writes nothing and exits 0, which reads as a successful
-- rewrite.  `snapshot` already refuses its own mode conflict rather than
-- guessing (`snapshotMode`); this mirrors that message.
-- Reads RAW argv (not the parsed `Args`) on purpose — see `runFmtCmd`'s
-- ORDER note.  `contains` is the same "appears anywhere in argv" test the
-- retired `hasFlag` performed, spelled with the helper the file already
-- imports.
fmtModeConflict : List String -> List String
fmtModeConflict argv =
  let writeOn = contains "--write" argv || contains "-w" argv
  let named = filterList (f => contains f argv) ["--check", "--stdout"]
  if writeOn then named ++ ["--write"] else named

fmtOne : FmtMode -> String -> <IO> Unit
fmtOne mode file = match readSourceE file
  Err e => dieMsg (sourceReadLine file e)
  -- PARSE-ERROR-LOCATION Stage 1: surface a located parse error before
  -- formatSource's panicking `parse` fires a bare `parse error`.
  -- One lexing pass shared by the parse check and the formatter.
  Ok src => match tokenizeWithOffsetPairs src
    (toks, pairs) => match formatSourceChecked src toks pairs
      Err e => dieMsg (ppParseError src file e)
      Ok formatted => match mode
        FmtStdout => putStr formatted
        FmtCheck =>
          if formatted == src then () else dieMsg (file ++ ": not formatted")
        FmtWrite =>
          if formatted == src then
            putStrLn "already formatted"
          else match writeFile file formatted
            Err msg => dieMsg "\{file}: \{msg}"
            Ok _ => putStrLn "formatted 1 file"

-- ── codemod ────────────────────────────────────────────────────────────────
-- `medaka codemod <name> [codemod-flags] [--write|--stdout] <paths...>`.
--
-- Registry-driven (tools/codemod.mdk): the first arg names a codemod; the rest
-- splits into mode flags (--write/--stdout), the codemod's OWN value-taking flags
-- (any other `--flag value`, handed to the codemod's `mk`), and file/dir targets
-- (expanded by the SAME `expandLintTarget`/`collectMdkFiles` walk fmt/lint use).
--
-- Modes mirror `fmt`: default is a DRY-RUN that prints `would rewrite: <file>`
-- per changed file and exits 1 if any would change (0 otherwise), so idempotence
-- is a plain exit-code check; `--write` rewrites only files that actually change;
-- `--stdout` prints one file's result (original text if unchanged).  A bare
-- `medaka codemod` lists the registry and exits 2.
codemodHelpText : String
codemodHelpText = stringConcat [
  "medaka codemod — Apply a named source-preserving AST transform\n", "\n",
  "Usage:\n", "  medaka codemod <name> [flags] [--write|--stdout] <paths...>\n",
  "\n",
  "  (default)  dry-run: prints \"would rewrite: <file>\" per changed file,\n",
  "             exits 1 if any file would change. Never writes.\n",
  "  --write    rewrite only the files that actually change\n",
  "  --stdout   print one file's result (single file only)\n", "\n",
  "Any other --flag consumes the next token as its value, passed to the\n",
  "named codemod. Run `medaka codemod` with no arguments to list the\n",
  "available codemods.\n", "\n",
  "NOTE: `--help`/`-h` is only recognized in the FIRST position — as\n",
  "`medaka codemod --help`, before a codemod name. `medaka codemod <name>\n",
  "--help` is NOT special-cased (it is a codemod flag) and codemod-specific\n",
  "help does not exist yet.\n"
]

runCodemodCmd : List String -> <IO> Unit
runCodemodCmd [] = listCodemodsAndExit ()
runCodemodCmd (name :: rest) = match findCodemod name
  -- C3/C4: an unrecognized first token would otherwise produce ONE message — "unknown
  -- codemod '<tok>'" — for two different mistakes, and `medaka codemod <dir>`
  -- got the wrong one: a path was read as a codemod NAME, so a directory (empty
  -- or not) was reported as a typo'd codemod rather than as the missing name it
  -- is.  Discriminate on whether the token names something on disk.  Note this
  -- is deliberately NOT an emptiness check: `medaka codemod src/` is the SAME
  -- mistake whether or not `src/` holds `.mdk` files, and reporting "no .mdk
  -- files found" for a full directory would be a lie.  Both arms land on
  -- (stderr, 1) with the usage listing.
  None =>
    let _ =
      if lintTargetExists name then
        ePutStrLn
          "medaka codemod: missing codemod name; `\{name}` is a path, and the codemod name comes first"
      else
        ePutStrLn "medaka codemod: unknown codemod `\{name}`"
    listCodemodsAndExit ()
  Some cm => match splitCodemodArgv rest CmDry [] []
    Err msg => dieMsg msg
    Ok (mode, cargs, targets) => match codemodMk cm cargs
      Err msg => dieMsg "medaka codemod \{name}: \{msg}"
      Ok xf =>
        let files = flatMap expandLintTarget targets
        match files
          [] => dieMsg "medaka codemod: no .mdk files found"
          _ => match mode
            CmStdout => match files
              [one] => codemodStdout xf (codemodWarnDecls cm cargs) one
              _ =>
                let _ =
                  ePutStrLn "medaka codemod: --stdout requires exactly one file"
                stageExit 1
            _ =>
              if codemodFilesGo
                mode
                xf
                (codemodWarnDecls cm cargs)
                files
                False then
                stageExit 1

-- C4: every caller of this is an ERROR path (bare `medaka codemod`, or a first
-- token that is neither a known codemod nor usable as one), so the usage block
-- is a diagnostic, not an answer — stderr, not stdout.  `medaka codemod --help`
-- is handled upstream by `dispatchSub` and still prints help to stdout at exit
-- 0, which is where the "listing as an answer" case lives.
listCodemodsAndExit : Unit -> <IO> Unit
listCodemodsAndExit _ =
  let _ =
    ePutStrLn
      "Usage: medaka codemod <name> [flags] [--write|--stdout] <paths...>"
  let _ = ePutStrLn ""
  let _ = ePutStrLn "Available codemods:"
  dieMsg codemodListing

-- Split the post-name argv into (mode, codemod-flags, paths).  --write/--stdout
-- are consumed as modes; any other `--flag` is a codemod flag that consumes the
-- NEXT token as its value (the effect-labels convention: --strip <v>, --rename
-- <v>); everything else is a target path.
splitCodemodArgv : List String ->
  CodeMode ->
  List String ->
  List String ->
  Result String (CodeMode, List String, List String)
splitCodemodArgv [] mode cargs paths = Ok (mode, reverseL cargs, reverseL paths)
splitCodemodArgv ("--write" :: rest) _ cargs paths =
  splitCodemodArgv rest CmWrite cargs paths
splitCodemodArgv ("--stdout" :: rest) _ cargs paths =
  splitCodemodArgv rest CmStdout cargs paths
-- C1: `--strip=<v>` would otherwise be taken as a flag literally NAMED `--strip=<v>`
-- that then ate the next token (a PATH) as its value.  A codemod's flag names
-- are its own (there is no central roster to consult), so the `=` form is
-- split structurally here — `--strip=Log` becomes `--strip`, `Log` in `cargs`
-- and consumes nothing else, which is exactly what the space form produces.
splitCodemodArgv (tok :: rest) mode cargs paths =
  if startsWith "--" tok then match codemodFlagEq tok
    Some (nm, v) => splitCodemodArgv rest mode (v :: nm :: cargs) paths
    None => match rest
      v :: rest2 => splitCodemodArgv rest2 mode (v :: tok :: cargs) paths
      [] => Err "medaka codemod: flag `\{tok}` requires a value"
  else
    splitCodemodArgv rest mode cargs (tok :: paths)

-- `--flag=value` split for a codemod flag: ANY `--`-shaped token with an `=`,
-- since the name set is per-codemod (contrast `flagEqSplit`, which is told
-- which names to split).  A leading `=` (`--=v`) is not a flag name; leave it
-- to the codemod's own `mk` to reject by name.
codemodFlagEq : String -> Option (String, String)
codemodFlagEq tok = codemodFlagEqGo tok 0 (stringLength tok)

codemodFlagEqGo : String -> Int -> Int -> Option (String, String)
codemodFlagEqGo tok i n =
  if i >= n then
    None
  else if stringSlice i (i + 1) tok == "=" then
    if i <= 2 then
      None
    else
      Some (stringSlice 0 i tok, stringSlice (i + 1) n tok)
  else
    codemodFlagEqGo tok (i + 1) n

-- --stdout for a single file: parse errors exit 1, otherwise print the rewritten
-- (or, if unchanged, the original) source.  Advisory warnings go to stderr.
codemodStdout : (Decl -> (Decl, Bool)) ->
  (List Decl -> List String) ->
  String ->
  <IO> Unit
codemodStdout xf warnFn file = match readSourceE file
  Err e => dieMsg (sourceReadLine file e)
  Ok src => match codemodSource xf src
    Err e => dieMsg (ppParseError src file e)
    Ok result =>
      let _ = emitCodemodWarns warnFn file src
      match result
        None => putStr src
        Some out => putStr out

-- Dry-run / --write fold over an expanded file list.  Returns whether the
-- process should exit 1: for dry-run that is "any file would change"; for
-- --write it is "any read/parse/write error" (a successful rewrite is exit 0).
codemodFilesGo : CodeMode ->
  (Decl -> (Decl, Bool)) ->
  (List Decl -> List String) ->
  List String ->
  Bool ->
  <IO> Bool
codemodFilesGo _ _ _ [] acc = acc
codemodFilesGo mode xf warnFn (f :: rest) acc =
  let signal = codemodOneReport mode xf warnFn f
  codemodFilesGo mode xf warnFn rest (acc || signal)

codemodOneReport : CodeMode ->
  (Decl -> (Decl, Bool)) ->
  (List Decl -> List String) ->
  String ->
  <IO> Bool
codemodOneReport mode xf warnFn file = match readSourceE file
  Err e =>
    let _ = ePutStrLn (sourceReadLine file e)
    True
  Ok src => match codemodSource xf src
    Err e =>
      let _ = ePutStrLn (ppParseError src file e)
      True
    Ok result =>
      let _ = emitCodemodWarns warnFn file src
      match result
        None => False
        Some out => match mode
          CmWrite => match writeFile file out
            Err msg =>
              let _ = ePutStrLn "\{file}: \{msg}"
              True
            Ok _ => False
          _ =>
            let _ = putStrLn "would rewrite: \{file}"
            True

-- Emit a codemod's advisory warnings for one file to stderr.  Safe to reparse:
-- the caller only reaches here after `codemodSource` proved the source parses.
emitCodemodWarns : (List Decl -> List String) -> String -> String -> <IO> Unit
emitCodemodWarns warnFn file src =
  let (decls, _) = parseWithPositions src
  emitWarnLines file (warnFn decls)

emitWarnLines : String -> List String -> <IO> Unit
emitWarnLines _ [] = ()
emitWarnLines file (w :: ws) =
  let _ = ePutStrLn "\{file}: warning: \{w}"
  emitWarnLines file ws

-- ── new ───────────────────────────────────────────────────────────────────
-- `medaka new <name>` scaffolds a project directory named after `name` — so
-- `name` must be validated BEFORE any filesystem write happens (#582). A
-- leading-dash arg is never a legal project name: `--help`/`-h` is help (print
-- usage, exit 0, no scaffolding), anything else starting with `-` is an
-- unrecognized option (error + usage to stderr, nonzero exit, no
-- scaffolding). Mirrors `runFmtCmd`'s "-"-prefix flag detection and
-- `buildUsage`'s subcommand-local `--help` handling.
newUsageLine : String
newUsageLine = "Usage: medaka new <name>"

-- `new` takes no flags at all, so its roster renders `none`.  Declared as a
-- spec (rather than an empty name list at the call site) so the sentence has
-- exactly one writer, like every other verb's.  Not routed through
-- `requireArgs`: `new` rejects a leading-`-` token and takes a bare NAME, not
-- a flag-and-positional argv.
newArgSpec : ArgSpec
newArgSpec = spec "new" []

runNewCmd : List String -> <IO> Unit
runNewCmd [arg] =
  if arg == "--help" || arg == "-h" then
    putStrLn newUsageLine
  else if stringLength arg > 0 && stringSlice 0 1 arg == "-" then
    -- C2: one wording, and the REJECTION exits 1.  `new` takes no flags at
    -- all, so its known set is empty.  (The bare `medaka new` usage error
    -- below exits 1 too -- C3's convergence, no verb exits 2.)
    let _ = ePutStrLn (unknownFlagMessage newArgSpec arg)
    dieMsg newUsageLine
  else
    let code = newProject arg
    if code == 0 then () else stageExit code
runNewCmd args = match filterList (startsWith "-") args
  -- Arity mismatch (0 or 2+ args): still C2-name a leading-dash token before
  -- falling back to the generic usage line, so `medaka new --zzz ok.mdk`
  -- doesn't read as REJECT-VAGUE just because it also has too many args.

  flagTok :: _ =>
    let _ = ePutStrLn (unknownFlagMessage newArgSpec flagTok)
    dieMsg newUsageLine
  [] => dieMsg newUsageLine

-- ── build ─────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `build` arm (Build_cmd.run) + build_main.mdk: parse
-- `<entry.mdk> [-o <out>]`, then drive build_cmd.runBuild (emit IR via a fresh
-- emitter subprocess → clang + C runtime + Boehm GC → native binary).  Paths
-- come from the environment (MEDAKA_ROOT/MEDAKA/CC) since compiler has no
-- getcwd/executable_name extern.  MEDAKA defaults to "./medaka" so a build with
-- no MEDAKA set re-invokes THIS native binary as the emitter host (no OCaml).
-- `build`'s whole flag vocabulary, as `buildUsage` documents it.  `--release`
-- is deliberately ABSENT — a native build is always optimized, so there is no
-- mode to select.  `runHelpText` must not cross-reference it as if `build` had
-- it (exemplar X7); S-help-truthfulness fixed the SENTENCE rather than adding
-- an arm, and test/diff_compiler_cli_help_conformance.sh property B now keeps
-- any help text from citing a `medaka <verb> --flag` that verb does not parse.
-- Under C2 a typed `build --release` reads back as a named rejection listing
-- what build really takes, instead of the argument-COUNT error it once gave.
-- Declaration ORDER is the `(known: …)` roster order (`rosterOf` renders every
-- name of every flag in declaration order), so it reproduces the old
-- `buildBoolFlags ++ buildValueFlags` rendering exactly.
-- `withStrictDash` (S-5, #2355 residual A): an undeclared `-x` would otherwise fall
-- through as the input file (AS-FILENAME); now C2-rejected like `--x`.
buildArgSpec : ArgSpec
buildArgSpec =
  withStrictDash
    (spec
      "build"
      [
        switch ["--keep-ir"] "keep the emitted IR beside the output",
        switch
          ["--allow-internal"]
          "permit internal-only externs outside stdlib/",
        switch ["--json"] "emit the structured-diagnostics envelope",
        switch
          ["--stamp-build"]
          "stamp the commit, compiler fingerprint and build date into the binary",
        value ["-o"] "PATH" "output path for the binary",
        -- `value`, not `oneOf`: the rejection sentence for a bad target is
        -- `lookupProfile`'s own `unknown target '…' (known: …)`,
        -- and this slice keeps every hand-written sentence verbatim.
        value ["--target"] "PROFILE" "target profile to build for",
        value ["--emit-rt-obj"] "PATH" "precompile the C runtime to an object",
        value
          ["--emit-prelude-obj"]
          "PATH"
          "precompile the prelude to an object",
      ])

runBuildCmd : List String -> <IO> Unit
runBuildCmd argv =
  -- `--help`/`-h` is read off RAW argv, before the parse: neither is a
  -- declared `build` flag, so routing it through `requireArgs` would turn
  -- `medaka build --help` into an unknown-flag rejection.
  if contains "--help" argv || contains "-h" argv then
    buildUsage ()
  else
    -- C1: `-o=out` / `--target=wasm` / `--emit-rt-obj=<p>` would otherwise fall
    -- through as an extra positional ("takes exactly one input file") or be
    -- dropped; `args.mdk` takes both spellings.
    -- C2: REJECT-VAGUE — an unknown flag became a second positional and was
    -- reported as an argument-count error naming neither the flag nor the set.
    runBuildModes (requireArgs buildArgSpec argv)

-- The mode dispatch (--emit-rt-obj / --emit-prelude-obj / --json / plain),
-- split out so the flag floor above is a flat prologue rather than another
-- level of `else` around this whole match.
runBuildModes : Args -> <IO> Unit
runBuildModes a = match flagValue "--emit-rt-obj" a
  -- `medaka build --emit-rt-obj <path>`: precompile runtime/medaka_rt.c to a
  -- reusable object with EXACTLY the flags a normal link would apply, then exit.
  -- No input .mdk is required (or read) in this mode — it compiles only the C
  -- runtime.  A CI gate points MEDAKA_RT_OBJ at the result to skip the redundant
  -- per-build recompile of the identical runtime.
  Some objPath =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let cc = envOr "CC" "clang"
    match emitRtObj cc root objPath
      Ok rep => println (ppBuildReport rep)
      Err rep => dieMsg (ppBuildReport rep)
  None => match flagValue "--emit-prelude-obj" a
    -- `medaka build --emit-prelude-obj <path>`: precompile stdlib/core.mdk to a
    -- reusable object with EXACTLY the flags a normal link would apply, then exit
    -- (issue #118 — the same trick as --emit-rt-obj, one level up: the prelude is
    -- 88% of a small program's IR).  No input .mdk is required (or read) in this
    -- mode.  A CI gate points MEDAKA_PRELUDE_OBJ at the result to skip
    -- re-optimising the identical prelude on every subsequent build.
    Some objPath =>
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let cc = envOr "CC" "clang"
      let medaka = envOr "MEDAKA" "./medaka"
      match emitPreludeObj cc root medaka objPath
        Ok rep => println (ppBuildReport rep)
        Err rep => dieMsg (ppBuildReport rep)
    -- #1078: `--json` is now a recognized flag (claimed by `buildArgSpec`,
    -- above) rather than a phantom second positional. Dispatch to a
    -- dedicated function per mode rather than inlining the branch here —
    -- `runBuildJsonCmd` prints the envelope `check --json` prints for the
    -- program (written by the emitter child's gate) and wraps a genuine
    -- emit/clang failure in the same `{"files":[...]}` `Diag` envelope, so
    -- one JSON shape covers every failure mode, front-end or backend; the
    -- plain-text arm (`runBuildPlainCmd`) is the pre-#1078 body, unchanged.
    None => if flag "--json" a then runBuildJsonEntry a else runBuildPlainCmd a

-- The plain-text `medaka build` body (parse args -> prelude check ->
-- emit+clang), kept separate from `runBuildJsonEntry` to avoid interleaving
-- argument-parsing dispatch at the same indent level.  This process reads the
-- two prelude files, for `readPreludeSources`'s missing-stdlib and prelude
-- parse-error messages, and does no other front-end work: the `medaka_emitter`
-- child loads, parses, resolves and typechecks the program once, under the
-- front-end gate `runBuild` asks it for (`driver/front_gate.frontGate`), and a
-- refusal reaches this process as the child's diagnostic.
runBuildPlainCmd : Args -> <IO> Unit
runBuildPlainCmd a =
  let perfOn = perfEnabled ()
  let perfT0 = now ()
  match parseBuildArgs a
    Err msg => dieMsg msg
    Ok (input, outOpt, _) =>
      if not (fileExists input) then
        dieMsg ("error: no such file: " ++ input)
      else
        let target = buildTargetOrDie a input
        perfArm perfT0
        let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
        let medaka = envOr "MEDAKA" "medaka"
        let cc = envOr "CC" "clang"
        let inputAbs = input
        let allowInternal = flag "--allow-internal" a
        let keepIrCli = flag "--keep-ir" a
        let stampBuild = flag "--stamp-build" a
        let outPath = match outOpt
          Some o => o
          None => defaultOutPath target input
        match readPreludeSources (root ++ "/stdlib")
          Err msg => dieMsg msg
          Ok prelude =>
            let _ = nativeTreesReport target prelude
            match (runBuild
              root
              medaka
              cc
              target
              inputAbs
              outPath
              keepIrCli
              False
              stampBuild
              (Some GateAsk {
                askAllowInternal = allowInternal,
                askDiagJson = False,
              }))
              Ok rep =>
                let perfTEmit = now ()
                let _ = emitPhase perfOn "emit" (perfTEmit - perfT0) input
                let _ = emitTotal perfOn (perfTEmit - perfT0)
                println (ppBuildReport rep)
              Err rep => dieMsg (ppBuildReport rep)

-- `build`'s report of the prelude's files: only a native build's emitter child
-- takes the trees, and this process took the declarations.
nativeTreesReport : BuildTarget -> PreludeInputs -> <IO> Unit
nativeTreesReport TNative prelude = reportChildTrees prelude
nativeTreesReport TWasm prelude = reportDecls None dieMsg prelude

-- `medaka build --json`'s own argument-parsing arm: a flag error still goes
-- through `parseBuildArgs`, but a bad-args message is now the JSON envelope
-- (`cjBuildFailedJson`, target "" — genuinely span-less, no input file was
-- even identified) rather than plain text, so a `--json` caller never has to
-- fall back to scraping stderr prose for THIS failure mode either.
runBuildJsonEntry : Args -> <IO> Unit
runBuildJsonEntry a = match parseBuildArgs a
  Err msg =>
    let _ = println (cjBuildFailedJson "" msg)
    stageExit 1
  Ok (input, outOpt, _) => match selectBuildProfile a input
    Err msg =>
      let _ = println (cjBuildFailedJson "" msg)
      stageExit 1
    Ok target =>
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let stdlibDir = root ++ "/stdlib"
      let allowInternal = flag "--allow-internal" a
      runBuildJsonCmd a allowInternal root stdlibDir input outOpt target

-- `medaka build --help` / `-h`: a subcommand-local usage, since the global
-- `usage()` (only matched when --help/-h is argv[0]) never sees this — dispatch
-- routes "build"::rest to runBuildCmd before the top-level --help arm gets a
-- chance.  Exists specifically so --keep-ir (and the other build-only flags)
-- are discoverable without reading the source.
buildUsage : Unit -> <IO> Unit
buildUsage _ =
  putStrLn
    (stringConcat [
      "usage: medaka build [--target <profile>] <file.mdk> [-o <out>] [--keep-ir] [--allow-internal] [--json] [--stamp-build]\n",
      "\n",
      "  -o <out>          output path for the binary (default: <file> with its extension dropped)\n",
      "  --target <profile> target profile, one of: \{joinWith ", " buildableNames}\n",
      "                    (default: [target] profile in medaka.toml, else llvm/native-posix).\n",
      "                    The program is checked against the profile before it is lowered;\n",
      "                    its backend picks the emitter (LLVM + clang, or WasmGC + wasm-tools)\n",
      "  --json            emit the {\"files\":[...]} structured-diagnostics envelope (same\n",
      "                    schema as `medaka check --json`) instead of human text; a genuine\n",
      "                    build-stage (emitter/clang) failure carries code R-BUILD-FAILED\n",
      "  --keep-ir         keep the emitted IR (.ll for native, .wat for wasm) at <out>.ll/.wat\n",
      "                    instead of discarding it with the build's scratch directory; the\n",
      "                    kept path is printed. Env var MEDAKA_KEEP_IR=1 does the same for a\n",
      "                    build invoked by something else (e.g. a test harness)\n",
      "  --allow-internal  permit internal-only externs outside stdlib/\n",
      "  --stamp-build     bake build provenance into the binary: the project's git commit\n",
      "                    (with a -dirty suffix on a modified tree), the fingerprint of\n",
      "                    the compiler that built it, and the UTC build date, read back at\n",
      "                    run time through buildCommit/buildFingerprint/buildDate. Without\n",
      "                    it those three read \"\", which is what every other build path\n",
      "                    links; a field that cannot be derived is stamped empty\n",
      "  --emit-rt-obj <p> compile only runtime/medaka_rt.c to a reusable object at <p> (with\n",
      "                    the same flags a normal link uses, including ThinLTO bitcode by\n",
      "                    default) and exit; point MEDAKA_RT_OBJ at it to skip recompiling\n",
      "                    the runtime on every subsequent build. MEDAKA_RT_OBJ must be paired\n",
      "                    with the matching link mode (MEDAKA_NO_LTO set for both, or for\n",
      "                    neither) — a mismatch either fails to link or silently loses\n",
      "                    ThinLTO's inlining\n",
      "  --emit-prelude-obj <p>\n",
      "                    compile only stdlib/core.mdk to a reusable object at <p> (with the\n",
      "                    same flags a normal link uses) and exit; point MEDAKA_PRELUDE_OBJ at\n",
      "                    it to skip re-optimising the prelude on every subsequent build.\n",
      "                    Opt-in: separate objects cannot inline the prelude into user code\n",
      "\n",
      "runtime object cache (ON by default):\n",
      "  Every native build links a compiled runtime/medaka_rt.c. Rather than recompile\n",
      "  it each time (~0.76s), build caches the object, keyed on a hash of the .c\n",
      "  source, the C compiler and its version, and the exact compile flags, so a\n",
      "  changed runtime or compiler never reuses a stale object.\n",
      "  Location (first that applies): $MEDAKA_CACHE_DIR, else\n",
      "  $XDG_CACHE_HOME/medaka, else $HOME/.cache/medaka.\n",
      "  MEDAKA_NO_OBJ_CACHE=1  disable the cache; compile medaka_rt.c inline every build\n",
      "  MEDAKA_CACHE_DIR=<d>   put the cache somewhere else (e.g. a per-CI-job scratch dir)\n",
      "  An explicit MEDAKA_RT_OBJ still wins over the cache. Every cache failure is\n",
      "  fail-open: build falls back to the inline compile, never to an error.\n",
      "\n",
      "MEDAKA_NO_LTO=1 (any non-empty value): force the plain link instead of the\n",
      "  default ThinLTO link. For a consumer that needs a NATIVE runtime object\n",
      "  (which `ld -r` can merge and ThinLTO bitcode cannot), e.g.\n",
      "  test/diff_compiler_llvm_ffi.sh and the memcheck probe in\n",
      "  pds/test/constant_time_signing.sh. Set it for both the build that emits\n",
      "  the object and the build that links it.\n",
    ])

-- Default output path per target: native drops the extension (a bare exe name);
-- wasm appends `.wasm` to the entry's base.
defaultOutPath : BuildTarget -> String -> String
defaultOutPath TNative input = chopExt (baseOf input)
defaultOutPath TWasm input = chopExt (baseOf input) ++ ".wasm"

-- Read `[-o <out>] [--target <native|wasm>]` off the parsed argv; the
-- positionals are the input.  Default target is TNative (the LLVM/clang path).
--
-- BOTH flags are LAST-WINS, as `check` and `run` read `--target`: an earlier
-- `--target` is overridden, not validated.  `--keep-ir`/`--allow-internal`/
-- `--json` are read separately by their own call sites and are simply not
-- positionals any more, which is what the old "strip it here so it doesn't
-- fall through to finishBuildArgs" arms existed to arrange (#1078).
parseBuildArgs : Args -> Result String (String, Option String, BuildTarget)
parseBuildArgs a = match buildTargetOf (lastValue "--target" a)
  Err msg => Err msg
  Ok target => finishBuildArgs a.positionals (lastValue "-o" a) target

buildTargetOf : Option String -> Result String BuildTarget
buildTargetOf None = Ok TNative
buildTargetOf (Some v) = parseTarget v

-- Through the profile table: an alias or profile name resolves, its backend
-- picks the `BuildTarget`, and the interpreter's profile is not buildable.
parseTarget : String -> Result String BuildTarget
parseTarget name = match lookupProfile name
  Err m => Err ("error: " ++ m)
  Ok p => match profileBackend p
    BackendLlvm => Ok TNative
    BackendWasmgc => Ok TWasm
    BackendEval =>
      Err
        "error: `\{name}` is not buildable (buildable: \{joinWith ", " buildableNames})"

-- `build`'s profile: `--target`, else the manifest's `[target] profile`, else
-- `llvm/native-posix`.  Its backend picks the emitter, and it is carried to the
-- emitter child, which checks the program against it before lowering.
selectBuildProfile : Args -> String -> <IO> Result String BuildTarget
selectBuildProfile a input =
  let named = match lastValue "--target" a
    Some v => Ok v
    None => map (optionOr "llvm/native-posix") (manifestProfileOf input)
  match named
    Err m => Err ("error: " ++ m)
    Ok name => match lookupProfile name
      Err m => Err ("error: " ++ m)
      Ok p => match parseTarget name
        Err m => Err m
        Ok target =>
          selectedProfile := Some p
          Ok target

buildTargetOrDie : Args -> String -> <IO> BuildTarget
buildTargetOrDie a input = match selectBuildProfile a input
  Ok target => target
  Err msg =>
    let _ = dieMsg msg
    TNative

finishBuildArgs : List String ->
  Option String ->
  BuildTarget ->
  Result String (String, Option String, BuildTarget)
finishBuildArgs [] _ _ =
  Err "usage: medaka build [--target <profile>] <file.mdk> [-o <out>]"
finishBuildArgs [input] out target = Ok (input, out, target)
finishBuildArgs _ _ _ = Err "error: medaka build takes exactly one input file"

-- ── run ───────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `run` arm + eval_typed_modules_main.mdk: load the entry
-- + its transitive imports (dependency-first), desugar each, elaborateModules
-- (marker + typecheck route-stamping over the module graph), then evalModulesWith
-- forces `main` for IO and returns the captured stdout.  `main` must be a
-- zero-arg value (`main = …`); top-level nullary bindings are LAZY (Phase-125),
-- so only effects reached from main run.  Roots: the entry's dir (user modules
-- shadow stdlib) then MEDAKA_ROOT/stdlib — same priority as the OCaml loader.
-- `--release`/`--json` are accepted-but-ignored (dropFlags), matching `check`.
--
-- ARGS NOTE.  `medaka run FILE a b c` passes a/b/c as the program's args.  The
-- native runtime's `args` extern returns the WHOLE process argv[1..] (set once in
-- @main's prologue), so a program run this way observes the CLI's own argv —
-- unlike the OCaml driver, which slices argv[3..].  This only matters for
-- programs that read `args ()`; the common `main = …` case is unaffected.  The
-- first positional after `runArgvFilter` is the entry; any further positionals are
-- the program's intended args (passthrough; observed via the native extern).
--
-- Shared eval tail: once the gate has ruled the program CLEAN and the whole
-- module graph has been elaborated (route-stamping via the per-module
-- typecheck, mainSchemeRef populated), force `main`.  Only reached AFTER the
-- check-strength gate below (both arms: the front end's diagnostics, then its
-- drive's report, which must carry `trChecked`), so a genuinely ill-typed
-- program never reaches evalModulesOutput (G1 soundness invariant).
-- [cohWarns] are the warnings the caller's own gate already computed, as (path,
-- src, diags) triples: the single-file arm's whole warning set
-- (`allWarnTriples`), the multi-module arm's `runBuildWarnCodes` only
-- (`isCoherenceWarn`, whose note says why not the whole channel).
-- A parameter rather than something recomputed here because the two arms derive
-- them differently, and recomputing would mean a second front-end pass.
--
-- 🚨 THIS PARAMETER EXISTS BECAUSE `run` WAS SILENT ON THE ONE DIAGNOSTIC F-3d
-- DEMOTED.  `finishRunEval` has always called `emitLocatedWarnings`, but only over
-- the main-shape warnings it builds locally, so nothing from the typecheck channel
-- reached this verb.  That gap is OLDER than F-3d and is not a regression on its own
-- — every other warning on the channel was invisible here before and still is.  What
-- F-3d changed is that a diagnostic `run`/`build` DID surface (as a hard error) was
-- routed onto the silent channel, which is a loud→silent transition.  Restoring that
-- one is the whole job.
--
-- 🚨 AND `--json` IS A DIFFERENT CHANNEL, NOT A DIFFERENT FORMATTING PREFERENCE.
-- `medaka run --json`'s STDERR is a `Diag` JSON envelope (AGENTS.md; the serializer
-- is `cjAllToJson`, the same one `check --json` uses), and `diff_compiler_eval_json`
-- grades that stream ALONE (`2>&1 1>/dev/null`).  Emitting human caret text there
-- does not merely look wrong — it makes the stream unparseable, which is strictly
-- worse than the silence this parameter exists to fix.  So on `--json` the warnings
-- are STAGED into `pendingRunDiags` and merged into the ONE envelope that stream
-- carries: `runtimePanic` prepends them if the program dies, and the flush below
-- emits them if it does not.  ⚠️ The ORDER differs between the two modes on purpose
-- — human: warnings BEFORE the program's output, matching `check`; JSON: after,
-- because "one document" wins and the document cannot be written until it is known
-- whether a runtime error joins it.
--
-- An entry `run` cannot start (`mainEntryError`: a function-shaped `main`, or
-- none) is refused here, before any warning and before anything is forced, on
-- the same two channels: the `Diag` envelope under `--json`, caret text otherwise.
-- `postPerf` closes over the caller's phase timestamps and emits the `eval` and
-- `total` `[perf]` lines.  It is a PARAMETER, not something the caller runs
-- afterwards, because under `--json` those lines are buffered into the envelope
-- (C4) and the envelope is flushed on the next line — a caller emitting them
-- after this function returned would stage them into an already-drained sink
-- and lose them.  Under plain `run` it is the same two calls in the same order,
-- just one stack frame in.
-- [facts] are those of the checked program whose trees `elaborated` holds.
finishRunEval : String ->
  Bool ->
  ProgramFacts ->
  (List Decl, List (String, List Decl)) ->
  List (String, List Decl) ->
  List (String, String, List Diag) ->
  (Unit -> <IO> Unit) ->
  <IO> Unit
finishRunEval target jsonMode facts elaborated mods cohWarns postPerf =
  let tsrc = readFileSafe target
  let _ = match lastModPair mods
    Some (_, edecls) => match mainEntryError edecls
      Some d => match jsonMode
        True => runAbortJson [(target, tsrc, [d])]
        False => runAbort (ppMainEntryError tsrc target d)
      None => ()
    None => ()
  -- On `--json` the warnings fold into the ONE `pendingRunDiags` envelope this
  -- stream carries (see above).
  let _ =
    if jsonMode then
      pendingRunDiags := nonEmptyTriples cohWarns
    else
      emitWarningLines (flatMap renderTripleWarnings cohWarns)
  currentEvalFile := target
  runJsonMode := jsonMode
  let _ = putStr (runProgramOutput facts (fst elaborated) (snd elaborated))
  -- The `eval`/`total` timings, BEFORE the envelope — see `postPerf`'s note.
  let _ = postPerf ()
  -- Reached only when the program did NOT panic (`panic` is a noreturn C abort), so
  -- this and `runtimePanic`'s merge are mutually exclusive — the envelope is emitted
  -- exactly once, never twice and never zero times.
  flushPendingRunDiags jsonMode

-- C4: the envelope now also carries whatever the two deferred human writers
-- staged (`staleBinary`, `perf`), so the emptiness test moved INTO
-- `flushRunEnvelope` — "no diagnostics" is no longer the same question as
-- "nothing to say".  With neither notice staged the bytes are unchanged.
flushPendingRunDiags : Bool -> <IO> Unit
flushPendingRunDiags False = ()
flushPendingRunDiags True = flushRunEnvelope !pendingRunDiags

runHelpText : String
runHelpText = stringConcat [
  "medaka run — Type-check and run a program (interpreter)\n", "\n", "Usage:\n",
  "  medaka run [--json] [--allow-internal] [--release] <file.mdk | -> [args...]\n",
  "\n",
  "  --json            emit the Diag JSON envelope on stderr instead of human\n",
  "                    text, for a runtime panic, a static (resolve/type) error\n",
  "                    in the program, or a warning in a SINGLE-FILE program. A\n",
  "                    clean run emits no envelope at all; a multi-module\n",
  "                    program's warnings are not reported by `run` (issue\n",
  "                    #2818) — use `medaka check --json` for those. KNOWN GAP:\n",
  "                    a usage error (bad flag, missing file) or a load/parse\n",
  "                    failure (bad import, malformed source) still prints human\n",
  "                    text on stderr and exits 1 with no envelope, so a\n",
  "                    consumer must handle both.\n",
  "  --allow-internal  permit internal-only externs outside stdlib/\n",
  "  --target <name>   target profile `main` must also fit; every run is\n",
  "                    checked against eval/run (default: [target] profile in\n",
  "                    medaka.toml)\n",
  "  --release         accepted, ignored — the interpreter has no release mode.\n",
  "                    There is no `build --release`; a native build is always\n",
  "                    optimized. Kept so a `--release` in a shared script does\n",
  "                    not make `medaka run` fail.\n", "\n",
  "`run` is the interpreter: it starts at once but runs slowly. For speed, use\n",
  "`medaka build`, the fast native path.\n", "\n",
  "Args after <file.mdk> are passed through to the program's own `args`.\n",
  "`medaka run -` reads the program from standard input (a heredoc), so the\n",
  "program's own `readAll`/`readLine` see end-of-file; a script that is also a\n",
  "filter must be run from a file. Imports resolve against the current directory.\n",
  "Inline-eval (`-e <expr>`) is NOT supported; use `medaka run -` and a heredoc.\n"
]

-- `run`'s flag vocabulary, as `runHelpText` documents it.  `--types` is also
-- stripped by `runArgvFilter` but is `check`'s flag, not `run`'s, and
-- `runRunCmd` never reads it — it is not advertised here.
--
-- Declared as an `ArgSpec` so the C2 sentence has the same one writer every
-- other verb's does, but `run` deliberately does NOT call `requireArgs`: see
-- `runArgvFilter`'s note and `runRunCmd`'s first-positional check.
runArgSpec : ArgSpec
runArgSpec = spec "run" [
  switch ["--json"] "emit the structured-diagnostics envelope on stderr",
  switch ["--allow-internal"] "permit internal-only externs outside stdlib/",
  switch ["--release"] "accepted and ignored (eval is never optimized)",
  value ["--target"] "NAME" "target profile `main` must also fit",
]

-- The `eval` + `total` phase lines, as a named partially-applied function so the
-- deeply-indented `finishRunEval` call sites stay one flat line.  `finishRunEval`
-- runs this itself, immediately before flushing the envelope — see its `postPerf`
-- note for why the caller must not run it afterwards.
runEvalPerf : Bool ->
  String ->
  Float ->
  Float ->
  Float ->
  Int ->
  Unit ->
  <IO> Unit
runEvalPerf perfOn target perfT0 perfTCheck allocCheck opCheck _ =
  let perfTEval = now ()
  let _ =
    emitPhaseAO
      perfOn
      "eval"
      (perfTEval - perfTCheck)
      (allocSnap () - allocCheck)
      target
      (opSnap () - opCheck)
  emitTotal perfOn (perfTEval - perfT0)

runRunCmd : List String -> <IO> Unit
runRunCmd argv =
  let perfOn = perfEnabled ()
  let _ = setOpCounting perfOn
  let perfT0 = now ()
  let jsonMode = runFlagGiven "--json" argv
  -- C4: under `--json` stderr is this verb's MACHINE channel, so `MEDAKA_PERF`'s
  -- `[perf]` lines must not be written to it as prose.  Arm `timer.mdk`'s sink
  -- and they are buffered instead, then folded into the ONE envelope as a `perf`
  -- array ([W-QUIETER]: routed, not silenced).  Disarmed for plain `run`, which
  -- is what `profile_compiler.sh` and the perf gates invoke.
  perfSinkOn := jsonMode && perfOn
  match runArgvFilter argv
    [] =>
      runAbort
        "usage: medaka run [--json] [--allow-internal] [--release] [--target <profile>] <file.mdk | -> [args...]"
    -- #219: a leading-`-` token `dropFlags` didn't recognize (e.g. `-e`) used
    -- to fall through as the entry `target`, so the loader rejected it as
    -- "unknown module: -e" — a message that sends the reader debugging a
    -- module path for what is actually a typo'd/unsupported flag. Report it
    -- as a flag error instead, mirroring `runFmtCmd`'s "-"-prefix detection
    -- (`parseFmtArgs`) and its shared C2 wording. Only the FIRST
    -- positional is checked — anything after it is the program's own
    -- passthrough args (ARGS NOTE above), which may legitimately start with
    -- `-`.
    target :: _ if target /= "-"
      && stringLength target > 0
      && stringSlice 0 1 target == "-" =>
      -- C2: same event, the shared wording.  This stays a check on the FIRST
      -- positional only — everything after it is the program's own argv,
      -- `--`-shaped or not (`medaka run argv.mdk -- --foo` must still deliver
      -- ["--", "--foo"]), so `run` must NOT route its whole argv through
      -- `assertCliFlags` the way the other verbs do.
      runAbort (unknownFlagMessage runArgSpec target)
    -- #2366: a path-shaped target (a `/`, or a `.mdk` suffix) that names no
    -- file is a filesystem error, not a module the loader failed to find (its
    -- "available modules" roster is misleading here).  A bare name still goes
    -- to the loader, which resolves it as a module.  Same wording as
    -- `medaka build`.
    target :: _ if (hasSlash target || endsWith ".mdk" target)
      && not (fileExists target) => runAbort ("error: no such file: " ++ target)
    target :: _ if target == stdinEntry =>
      runAbort
        "error: `<stdin>` is not a file; use `medaka run -` to read the program from standard input"
    rawTarget :: progArgs =>
      let isStdin = rawTarget == "-"
      let target = if isStdin then stdinEntry else rawTarget
      let stdinText = if isStdin then orExit (readStdinProgram ()) else ""
      perfArm perfT0
      carryTargetProfile (runTargetFlag argv) target
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let stdlibDir = root ++ "/stdlib"
      let roots = entrySearchRoots (dirOf2 target) ++ [stdlibDir]
      let allowInternal = runFlagGiven "--allow-internal" argv
      -- publish the args AFTER the target for the run-path `args` extern
      -- (eval.mdk's pArgs reads this Ref): `medaka run prog.mdk a b` ⇒ ["a","b"],
      -- matching what the same program's compiled binary sees.
      progArgsRef := progArgs
      let prelude = orExit (readPreludeSources stdlibDir)
      let rsrc = prelude.pnRuntimeSrc
      let csrc = prelude.pnCoreSrc
      -- Parse the user modules with parseLocated (real ELoc spans) so a
      -- runtime error (E-*) can report a correct file:L:C.  Plain loadProgram
      -- uses placeholder-loc `parse`, which collapses every span to 1:0.
      -- Structurally identical decls → eval output byte-identical.
      -- PARSE-ERROR-LOCATION Stage 1: surface a located parse error on the
      -- ENTRY file.  An IMPORTED module's parse error is located by the loader
      -- itself (#100) and rendered by moduleLoadErrText, so neither one is a
      -- bare `parse error` panic any more.  The entry is re-parsed only in the
      -- loader's failure arm below, so valid input pays no second parse.
      let tsrc = if isStdin then stdinText else readFileSafe target
      -- #186/#1360: keep the loader's per-module PATHS instead of dropping
      -- them at the load site.  They were already being carried here and
      -- discarded one line later, which is why every imported module's
      -- resolve error had to fall back to the entry file's path.
      -- `moduleLoadErrText` renders in `<IO>`, so this step stays a local
      -- match rather than composing through `orExit`/`mapErr` (both fixed to
      -- a pure error-rendering function).
      let readEntry = stdinReadOverride stdinText
      let modsWithPath = match loadProgramFilesLocatedE readEntry target roots
        Err lerr =>
          let _ = reportShippedHeaders (deferredInto jsonMode) prelude
          let _ = orExit (mapErr (ppParseError tsrc target) (parseResult tsrc))
          let _ = runAbort (moduleLoadErrText tsrc target stdlibDir lerr)
          panic "unreachable"
        Ok mp => mp
      let mods = map dropPathTriple modsWithPath
      let pathMap = map modIdToPath modsWithPath
      -- #1542: same per-module (modId -> path) map #41 already built
      -- here for resolve-phase attribution, now ALSO published to the
      -- evaluator so a RUNTIME error raised inside an imported module
      -- reports THAT module's file instead of the entry's.
      modulePathMap := pathMap
      -- S-1/#2234 (F-converge): same content-keyed prelude memo `check`
      -- already routes through; consumed live by `elaborateModules` below.
      let rtD = desugaredPrelude rsrc
      let coreD = desugaredPrelude csrc
      let modsD = map desugarPair mods
      let _ = takeShippedPrelude (deferredInto jsonMode) prelude
      let trusted = projectTrustedMods target roots stdlibDir mods
      -- #2072: the FFI-stamp discriminator, handed to typecheck alongside the
      -- #1713 reference-trust set above.  Different predicate, deliberately: this
      -- one is stdlib-root ownership with no `allow-internal` opt-out.
      let (flatStdlib, ownedStdlib) =
        stdlibOwnership target roots stdlibDir mods
      let inputs = { driveInputsFor !selectedProfile flatStdlib ownedStdlib |
        diPreludeKey = Some (preludeGeneration rsrc csrc),
      }
      let perfTLoad = now ()
      let _ = emitPhase perfOn "load" (perfTLoad - perfT0) target
      -- One front-end run (`frontEnd`), the same raw-tree passes and resolve
      -- `checkRoute` runs, so `run` accepts/rejects the SAME set of programs
      -- `medaka check` does (beta P0-1 / P1-8).  A gate of resolve-errors +
      -- elaborate + hadTypeErrors for ALL programs is a WEAKER predicate
      -- than check's: it misses constraint/no-impl/coherence errors
      -- (so run silently executes ill-typed programs) AND spuriously
      -- fires on some check-clean programs (standalone-fn-shadows-iface).
      -- ONE typecheck of the program (ARCH §E): the front end's drive is the
      -- elaboration `run` executes, so the located report is rendered from ITS
      -- output rather than from a second, check-only pass.
      -- S-3/#164 (F-converge): a single module is analysed from the loader's
      -- own raw, real-span decls (its guard-exhaustiveness/`checkDerives` passes
      -- need the RAW tree).  That arm's guard never consulted the `trusted` set,
      -- only the bare `--allow-internal` flag, unlike `build`'s single-module
      -- gate (`driver/front_gate.frontGate`).  That asymmetry is pre-existing;
      -- this parity slice does not change it.
      let (program, frontTrusted) = match modsWithPath
        [m] => (FrontFile m, [])
        _ => (FrontGraph modsWithPath modsD, trusted)
      let executionDriver =
        EntryKey { moduleId = "async", binding = "runAsyncMain" }
      let front =
        frontEnd
          cliStdlibExportsEnv
          (d => elaborateRun d.fdInputs executionDriver rtD coreD modsD)
          FrontInput {
            fiInputs = inputs,
            fiAllowInternal = allowInternal,
            fiTrusted = frontTrusted,
            fiRuntimeSrc = rsrc,
            fiCoreSrc = csrc,
            fiPolicy = NeverDriveRejected,
            fiProgram = program,
          }
      let report = front.foReport
      match mods
        [_] =>
          -- Single-file: render byte-identical caret diagnostics via
          -- ppDiagCliSrc, instead of an opaque "type error in <file>" message.
          -- A program resolve rejected was not driven and carries its resolve
          -- errors here.
          let tsrc = if isStdin then stdinText else readFileSafe target
          let diags = flatMap snd front.foDiags
          match (filter diagIsError diags, front.foDriven)
            ([], Some analysis) =>
              let residual = analysis.eaElab.erResidual
              match isNone report.trChecked
                -- Belt-and-braces, as on the multi-module arm: anything only
                -- the graph-end drain can see still aborts before eval.
                True => match jsonMode
                  True =>
                    runAbortJson (residualJsonTriples target pathMap residual)
                  False => runAbort (residualOrGeneric pathMap target residual)
                False =>
                  let _ =
                    runTargetGate jsonMode (t => t) target pathMap mods analysis
                  let perfTCheck = now ()
                  let allocCheck = allocSnap ()
                  let opCheck = opSnap ()
                  let _ =
                    emitPhase perfOn "check" (perfTCheck - perfTLoad) target
                  -- #2400 / F4: SINGLE-FILE only, so `allWarnTriples` carries
                  -- the FULL warning set here (it filters `diagIsWarn`, not
                  -- `runBuildWarnCodes`; see its note).
                  -- `finishRunEval` carries this triple down BOTH channels
                  -- (human `renderTripleWarnings`, `--json` `pendingRunDiags`),
                  -- so widening here widens both in lockstep.  The
                  -- multi-module arm below keeps `projWarns` on the
                  -- coherence allowlist.
                  let executed =
                    executedFromReport report executionDriver (coreD, modsD)
                  match executed
                    Err msg => runAbort msg
                    Ok trees =>
                      finishRunEval
                        target
                        jsonMode
                        (checkedFacts report)
                        trees
                        mods
                        (allWarnTriples tsrc target diags)
                        (runEvalPerf
                          perfOn
                          target
                          perfT0
                          perfTCheck
                          allocCheck
                          opCheck)
            (errs, _) => match jsonMode
              -- #2798 review S2: `diags` (the WHOLE list, errors and warnings)
              -- for JSON, matching `check --json`'s per-file diagnostics array
              -- element-wise — `errs` is the errors-only prose projection of it.
              True => runAbortJson [(target, tsrc, diags)]
              False =>
                runAbort
                  (joinNl (map (ppDiagCliLines (srcLinesArr tsrc) target) errs))
        _ => match front.foDriven
          -- Multi-module: resolve rejected the graph.  #186/#1360: per-module
          -- attribution via the loader's `pathMap`, the same seam `checkRoute`
          -- uses (#41).
          None => match jsonMode
            True =>
              -- #2798 review S2: same `relDiagTriple root` normalization as
              -- the typecheck-error arm below.
              runAbortJson
                (map
                  (relDiagTriple root)
                  (resolveErrorJsonTriples front.foDiags))
            False => runAbort (ppDiagBuckets front.foDiags)
          -- A gate of resolve + elaborateModules + hadTypeErrors is only as
          -- sound as the obligations the elaborate driver checks (both channels
          -- since #2705) and renders nothing located; `check`'s predicate prints
          -- the real located `No impl of Display for Foo` for
          -- `println "\{Foo 1}"` with no Display impl.
          Some analysis =>
            let residual = analysis.eaElab.erResidual
            match locatedProjectDiags front.foDiags
              (Some errText, _, _) => match jsonMode
                True =>
                  -- #2798 review S2: normalize each file the SAME way
                  -- `check --json`'s own multi-module arm does
                  -- (`relDiagTriple root`, diagnostics.mdk ~:2478-2482) — an
                  -- imported stdlib module resolves through the absolute
                  -- `stdlibDir` root and must not leak that worktree path
                  -- into the envelope's `file` field.  `nonEmptyTriples` is the
                  -- only filter: like `check --json`'s per-file `diagnostics`
                  -- array, the JSON channel carries warnings beside errors,
                  -- where the prose `errText` is errors-only.
                  let jsonTriples =
                    map
                      (relDiagTriple root)
                      (nonEmptyTriples (map readDiagSrc front.foDiags))
                  runAbortJson jsonTriples
                False => runAbort errText
              (None, projWarns, _) => match isNone report.trChecked
                -- Belt-and-braces: anything only the graph-end drain can
                -- see still aborts before eval.
                True => match jsonMode
                  True =>
                    runAbortJson
                      (map
                        (relDiagTriple root)
                        (residualJsonTriples target pathMap residual))
                  False => runAbort (residualOrGeneric pathMap target residual)
                False =>
                  let _ =
                    runTargetGate
                      jsonMode
                      (relDiagTriple root)
                      target
                      pathMap
                      mods
                      analysis
                  let perfTCheck = now ()
                  let allocCheck = allocSnap ()
                  let opCheck = opSnap ()
                  let _ =
                    emitPhase perfOn "check" (perfTCheck - perfTLoad) target
                  let executed =
                    executedFromReport report executionDriver (coreD, modsD)
                  match executed
                    Err msg => runAbort msg
                    Ok trees =>
                      finishRunEval
                        target
                        jsonMode
                        (checkedFacts report)
                        trees
                        mods
                        projWarns
                        (runEvalPerf
                          perfOn
                          target
                          perfT0
                          perfTCheck
                          allocCheck
                          opCheck)
-- G1 (SOUNDNESS): typecheck the WHOLE module graph and abort before
-- eval unless the drive's report carries a checked program (`trChecked`).  A
-- type error makes evalModulesOutput miscompile (the G1 bug), so we never
-- reach it.  Resolve-phase errors (e.g. PrivateNameAccess) ride a SEPARATE
-- channel the report does not cover, so resolveModulesErrorsByFile is
-- consulted FIRST (mirroring `check`/`build`) and run aborts with the same
-- humane diagnostic before elaborate/eval.

desugarPair : (String, List Decl) -> (String, List Decl)
desugarPair (mid, p) = (mid, desugarIn mid p)

-- (modId, path, decls) → (modId, path): the per-module file map threaded into the
-- `run`'s one elaboration: the analysis its gate reads, and the auto-print
-- evidence `executedTrees` wraps the elaborated trees with.
elaborateRun : DriveInputs ->
  EntryKey ->
  List Decl ->
  List Decl ->
  List (String, List Decl) ->
  <IO> (EntryAnalysis, TcReport, DriveOutputs)
elaborateRun inputs executionDriver rtD coreD modsD =
  let (analysis, report, outputs) =
    analyzeProgramReport
      (executedMainInputs inputs executionDriver modsD)
      (valueMainCandidate coreD modsD)
      (Some executionDriver.binding)
      rtD
      coreD
      modsD
  let _ = match asyncMainShapeError outputs.doEntryOutcome modsD
    Some msg => runAbort msg
    None => ()
  (analysis, report, outputs)

-- B2 (RUN-EFFECTS): evalModulesOutputRunFacts is evalModulesOutput plus the real-I/O
-- externs (File/Env/Stdin/Stderr/Clock), hence the `IO` row.  An `Async` main
-- reaches here already rewritten by `executedTrees`.
runProgramOutput : ProgramFacts ->
  List Decl ->
  List (String, List Decl) ->
  <IO> String
runProgramOutput facts preludeDecls modules =
  evalModulesOutputRunFacts facts preludeDecls modules

-- The facts of the checked program [report] judged.  `executedFromReport` has
-- already refused a report without one, so the absent arm is unreachable.
checkedFacts : TcReport -> ProgramFacts
checkedFacts report = match report.trChecked
  Some checked => factsOfChecked checked
  None =>
    panic "internal error: the typecheck published no checked program to run"

-- ── test ──────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `test` arm + test_main.mdk: read <MEDAKA_ROOT>/stdlib/
-- {runtime,core}.mdk, then drive test_cmd.runTest (doctests + prop tests).
-- runTest reads the three sources itself and prints the report in-band; since
-- P0-212 a read error (prelude OR target) makes runTest return False (a file
-- that can't even be opened is a FAILURE, not a vacuous pass — only a file
-- that parses clean with zero doctests/props is vacuously True).  Roots mirror
-- run: the entry's dir (user modules shadow stdlib) then MEDAKA_ROOT/stdlib.
--
-- Target resolution (#82 row 2): mirrors `medaka lint`/`medaka fmt` — a single
-- literal-file arg keeps the EXACT original single-file path (byte-for-byte,
-- same `runTest` call), so this is backward-compatible.  A directory arg, a
-- `medaka.toml` project dir, or multiple args are expanded via the SAME
-- `expandLintTarget`/`collectMdkFiles` walk lint/fmt use, and every resolved
-- `.mdk` file is tested in turn, aggregating: exit nonzero iff ANY file's
-- tests failed OR couldn't be read (this is also what makes the #212 exit-0
-- bug go away for the directory/project route, not just the single-file one).
-- Bare `medaka test <file>` runs the native engine alone; `--native` is
-- sugar for that same `--engines native`, never an addition to the
-- interpreter. `--engines eval` selects the interpreter and `--engines
-- eval,native` runs both. An unknown `--engines` name is a hard diagnostic
-- naming the valid set — never a silent drop, which would let a typo run
-- nothing and still exit 0 (the exact "didn't run looks like passed" failure
-- this whole arc exists to close).

runTestCmd : List String -> <IO> Unit
runTestCmd argv0 =
  -- C1: the old `testFlagValue`/`testTargets` pair read the space form only,
  -- so `--filter=zzz` was rejected as an unknown flag (loud, but still one of
  -- the two spellings C1 requires every value flag to take).  #2316's own
  -- check and that normalisation are both `args.mdk`'s job now.
  let a = requireArgs testArgSpec argv0
  if flag "--props-worker" a then
    runPropsWorkerCmd a
  else match parseTestEngines a
    Err msg => dieMsg "medaka test: \{msg}"
    Ok engines => match parseTestCasesFlag a
      Err msg => dieMsg "medaka test: \{msg}"
      Ok casesOpt => match parseTestIntFlag "--seed" a
        Err msg => dieMsg "medaka test: \{msg}"
        Ok seedOpt =>
          let _ = match seedOpt
            Some s => seedPropRng s
            None => ()
          let cases = optionOr 100 casesOpt
          let filterOpt = flagValue "--filter" a
          let jsonMode = flag "--json" a
          match a.positionals
            [] =>
              if jsonMode then
                let _ =
                  ePutStrLn
                    "medaka test --json: needs a single file.mdk target; with no target, medaka test runs the whole enclosing project"
                stageExit 1
              else
                runTestProjectCmd engines cases filterOpt seedOpt
            [target] => match listDir target
              Err _ =>
                if jsonMode then
                  runTestJsonCmd engines cases filterOpt target
                else
                  runTestOne engines cases filterOpt target
              Ok _ =>
                if jsonMode then
                  let _ =
                    ePutStrLn
                      "medaka test --json: directory targets are not supported; pass a single file.mdk target"
                  stageExit 1
                else
                  runTestManyTargets engines cases filterOpt seedOpt [target]
            targets =>
              if jsonMode then
                let _ =
                  ePutStrLn
                    "medaka test --json: exactly one file.mdk target is supported"
                stageExit 1
              else
                runTestManyTargets engines cases filterOpt seedOpt targets

-- The supervisor sends a target followed by JSON-string encoded exact `(name,
-- seed, cases)` triples. These are internal replay requests, so they do not share
-- normal test's target expansion or user-facing defaulting rules.
runPropsWorkerCmd : Args -> <IO> Unit
runPropsWorkerCmd a = match parsePropsWorkerPositionals a.positionals
  Err message => dieMsg "medaka test --props-worker: \{message}"
  Ok (target, requests) => runEvalPropsWorker target requests

parsePropsWorkerPositionals : List String ->
  Result String (String, List PropRequest)
parsePropsWorkerPositionals [] =
  Err "expected a target and zero or more property request triples"
parsePropsWorkerPositionals (target :: fields) =
  map (requests => (target, requests)) (parsePropsWorkerRequests fields)

parsePropsWorkerRequests : List String -> Result String (List PropRequest)
parsePropsWorkerRequests [] = Ok []
parsePropsWorkerRequests (nameText :: seedText :: casesText :: rest) = do
  name <- parseWorkerField "name" nameText
  seed <- parseWorkerInt "seed" seedText
  cases <- parseWorkerInt "cases" casesText
  if cases <= 0 then
    Err "property request \{debug name} has a non-positive case budget"
  else do
    requests <- parsePropsWorkerRequests rest
    Ok (PropRequest name seed cases :: requests)
parsePropsWorkerRequests _ =
  Err "property requests must be name, seed, cases triples"

parseWorkerInt : String -> String -> Result String Int
parseWorkerInt role text = do
  field <- parseWorkerField role text
  match toInt field
    Some value => Ok value
    None => Err "property request \{role} is not an integer: \{debug field}"

parseWorkerField : String -> String -> Result String String
parseWorkerField role text = match parseJson text
  Ok json => match asString json
    Some field => Ok field
    None => Err "property request \{role} is not a JSON string"
  Err _ => Err "property request \{role} is not a JSON string"

-- `medaka test` with no target (#3443): test the project enclosing the current
-- directory exactly as `medaka test <root>` would. The root is the NEAREST
-- `medaka.toml` at or above the cwd, the same walk-up the loader, `medaka build`
-- and a no-target `medaka lint` use. A `[workspace]` root is therefore an
-- ordinary root: the directory walk reaches the members beneath it, and a run
-- from inside a member stops at that member's own manifest. The chosen root goes
-- to stderr, because a run started in a subdirectory tests more than that
-- subdirectory. With no manifest anywhere above, it refuses; it never falls back
-- to testing the cwd.
runTestProjectCmd : List Engine ->
  Int ->
  Option String ->
  Option Int ->
  <IO> Unit
runTestProjectCmd engines cases filterOpt seedOpt =
  let cwd = canonicalizePath "."
  match findProjectRoot cwd
    None =>
      dieMsg
        "medaka test: no target given and no medaka.toml in \{cwd} or any directory above it; pass a file.mdk or directory target, or run inside a project"
    Some root =>
      let _ =
        ePutStrLn "medaka test: no target given; testing the project at \{root}"
      runTestManyTargets engines cases filterOpt seedOpt [root]

-- ── test --json (#2295 (d)) ──────────────────────────────────────────────────
-- `medaka test --json <file.mdk>`: structured counterpart of the human
-- `medaka test` report, matching `medaka lint --json`'s flag convention (one
-- JSON object to stdout, exit 1 iff the run failed).  Single-file only for
-- now (mirrors this slice's scope — the directory/multi-target walk stays
-- human-text-only).
--
-- Built on `runTestReport` rather than `mcp.mdk`'s `testReportJson`: that
-- function's envelope deliberately excludes the `test "…"` phase (#1443,
-- #252 scope), and this slice's acceptance requires the JSON and human arms
-- to agree INCLUDING that phase — so a CLI-side renderer that folds in the
-- `test "…"` results `runTestReport` now also returns is needed; adapting
-- `testReportJson` in place would have changed medaka_test's (unrelated,
-- settled) contract.  F1: `cases`/`filterOpt` ARE now threaded through (they
-- are easy to drop here, and dropping them makes `--json --filter`/`--cases`
-- report on ALL tests regardless) — `--seed` already reaches this path
-- unchanged, via `seedPropRng` in `runTestCmd` before this function is called.
runTestJsonCmd : List Engine -> Int -> Option String -> String -> <IO> Unit
runTestJsonCmd engines cases filterOpt target =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let stdlibDir = root ++ "/stdlib"
  let r = do
    prelude <- readPreludeSources stdlibDir
    let _ = seedCheckPrelude prelude
    tsrc <- readSource target
    let userDecls = targetDesugared tsrc
    if filterMatchedNothing filterOpt tsrc userDecls then
      Err
        "medaka test: \{target}: --filter matched no doctests, props, or `test \"…\"` decls"
    else
      let (typeError, runs, props, tests, typecheckSkipped) =
        runTestGradedReport
          engines
          prelude.pnRuntimeSrc
          prelude.pnCoreSrc
          target
          tsrc
          userDecls
          stdlibDir
          cases
          filterOpt
          True
      let _ =
        putStrLn
          (stringify
            (cliGradedTestReportJson
              target
              typeError
              engines
              runs
              props
              tests
              typecheckSkipped))
      Ok (cliGradedTestReportOk typeError runs props tests)
  match r
    Err e => dieMsg e
    Ok ok => if ok then () else stageExit 1

-- Directory/project/multi-target path: expand every target to concrete .mdk
-- files (SAME walk as lint/fmt), then run+aggregate.  C3
-- (docs/ops/CLI-CONFORMANCE.md §3): an empty resolved set (empty dir, or a dir
-- with no .mdk files) is a USAGE ERROR — `(stderr, 1)`, the ONE pair every verb
-- now uses for "no .mdk files found" — and no longer the vacuous exit-0 pass it
-- would otherwise be.  A test command that ran zero tests and exited 0 is precisely the
-- "didn't run looks like passed" failure the test arc exists to close.
-- `runTest`'s single-file zero-doctest pass is a DIFFERENT case and unchanged:
-- there a file was resolved and examined, and it had nothing to assert.
runTestManyTargets : List Engine ->
  Int ->
  Option String ->
  Option Int ->
  List String ->
  <IO> Unit
runTestManyTargets engines cases filterOpt seedOpt targets =
  let files = flatMap expandLintTarget targets
  match files
    [] => dieMsg "medaka test: no .mdk files found"
    _ =>
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let rtPath = root ++ "/stdlib/runtime.mdk"
      let corePath = root ++ "/stdlib/core.mdk"
      let stdlibDir = root ++ "/stdlib"
      let rosterOk = checkTestMdkRoster root targets files
      let _ = reportSupervisedTrees stdlibDir rtPath corePath
      let anyFailed =
        testFilesGo
          engines
          rtPath
          corePath
          stdlibDir
          cases
          filterOpt
          seedOpt
          files
          False
      if anyFailed || not rosterOk then stageExit 1

-- The trees' verdict for a `test` run that hands every file to a child process:
-- the children hold the trees and a passing child's stderr is not shown, so this
-- process reports it, from the files' header and digest alone.
reportSupervisedTrees : String -> String -> String -> <IO> Unit
reportSupervisedTrees stdlibDir rtPath corePath = match (
  readFile rtPath,
  readFile corePath,
)
  (Ok rsrc, Ok csrc) => reportChildTrees (shippedInputs stdlibDir rsrc csrc)
  _ => ()

-- ── doc ───────────────────────────────────────────────────────────────────
-- The `doc` arm: read the target file, parse
-- (capturing decl positions + comments), typecheck a desugared copy through the
-- single-file path for inferred schemes, extract PUBLIC-decl doc entries, and
-- print Markdown to stdout.  Prelude sources (runtime.mdk/core.mdk) come from
-- MEDAKA_ROOT for scheme inference, exactly as check/run/test do.
--
-- S-doc-library-mode adds a second mode, gated on `--out DIR`: one or more
-- module positionals become a small generated library — a page per module
-- (`DIR/<module>.md`), an index (`DIR/index.md`), and a machine-readable
-- inventory (`DIR/inventory.json`, #2306 step 1's artifact). Both modes read
-- the SAME `docArgSpec` value (S-5's `withStrictDash (spec "doc" [...])`
-- shape), so the roster/help/rejection can never drift apart.
docHelpText : String
docHelpText = stringConcat [
  "medaka doc — Generate Markdown documentation for a file or module library\n",
  "\n", "Usage:\n", "  medaka doc <file.mdk>\n",
  "  medaka doc --out DIR <file.mdk> [<file.mdk> ...]\n", "\n",
  "Single-file mode prints Markdown for every PUBLIC declaration (with\n",
  "inferred type schemes) in <file.mdk> to stdout.\n", "\n",
  "Library mode (--out DIR) writes one Markdown page per module, an\n",
  "index.md linking them, and an inventory.json (name -> module ->\n",
  "signature) into DIR.\n", "\n",
  "  --out DIR   output directory; enables library mode\n"
]

-- `withStrictDash` (S-5, #2355 residual A): an undeclared `-x` would otherwise fall
-- through as the target file (AS-FILENAME, exemplar X4); now C2-rejected.
docArgSpec : ArgSpec
docArgSpec =
  withStrictDash
    (spec "doc" [
      value ["--out"] "DIR" "output directory; enables library mode",
    ])

runDocCmd : List String -> <IO> Unit
runDocCmd argv =
  -- C2: same AS-FILENAME hole `check` had (the old shared `dropFlags` passed
  -- an unknown token through as the target).  `--json`/`--types`/`--release`,
  -- which that filter silently ate here (§5c: "accepted and silently
  -- ignored"), are unknown to `doc` and rejected as such.
  let a = requireArgs docArgSpec argv
  match flagValue "--out" a
    Some dir => runDocLibraryTargets dir a.positionals
    None => runDocTargets a.positionals

-- §5f: `medaka doc <a> <b>` would otherwise render <a> and silently ignore every
-- later positional at exit 0.  `doc` is single-file, so a second target is a
-- usage error — mirrors `check`'s own extra-positional arm.
runDocTargets : List String -> <IO> Unit
runDocTargets [] = dieMsg "usage: medaka doc <file.mdk>"
runDocTargets (_ :: _ :: _) =
  dieMsg "usage: medaka doc <file.mdk> (doc takes exactly one file)"
runDocTargets (target :: _) =
  let _ = carryTargetProfile None target
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let stdlibDir = root ++ "/stdlib"
  let roots = entrySearchRoots (dirOf2 target) ++ [stdlibDir]
  let r = do
    prelude <- readPreludeSources stdlibDir
    let _ = seedCheckPrelude prelude
    tsrc <- readSource target
    let _ = orExit (mapErr (ppParseError tsrc target) (parseResult tsrc))
    Ok
      (putStr (runDoc prelude.pnRuntimeSrc prelude.pnCoreSrc tsrc target roots))
  match r
    Err msg => dieMsg msg
    Ok v => v

-- ── doc: library mode (S-doc-library-mode) ──────────────────────────────────
-- `medaka doc --out DIR <file.mdk> [<file.mdk> ...]`: read + doc every target,
-- write one page per module, one index, one inventory.
runDocLibraryTargets : String -> List String -> <IO> Unit
runDocLibraryTargets _ [] =
  dieMsg "usage: medaka doc --out DIR <file.mdk> [<file.mdk> ...]"
runDocLibraryTargets outDir targets =
  let _ = carryTargetProfile None (optionOr "." (head targets))
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let stdlibDir = root ++ "/stdlib"
  let r = do
    prelude <- readPreludeSources stdlibDir
    let _ = seedCheckPrelude prelude
    _ <- ensureOutDir outDir
    -- A `*_test.mdk` sibling holds a module's tests, not library surface, so
    -- the library reference has no page for it ([P-TEST-SIBLING]).
    mds <- collectModuleDocs
      prelude.pnRuntimeSrc
      prelude.pnCoreSrc
      stdlibDir
      (filter (t => not (endsWith "_test.mdk" t)) targets)
    -- `rebucketLibraryImpls` runs at the `List ModuleDoc` level, after
    -- every module is computed and before ANY output is written, so the
    -- pages, the index and the inventory all read the same (already
    -- re-filed) entry lists — an impl cannot be on one page and indexed
    -- under another.
    --
    -- `targets` arrives in whatever order the shell/CLI handed it
    -- (`stdlib/*.mdk` glob expansion), which is locale-dependent —
    -- collation of `.` vs `_` differs across LC_COLLATE settings, so
    -- e.g. `net.mdk`/`net_async.mdk` can swap places between machines.
    -- Sort by module name here so index.md/inventory.json are
    -- byte-identical regardless of invocation order.
    Ok (writeLibraryOutputs outDir (rebucketLibraryImpls (sortOn mdName mds)))
  match r
    Err msg => dieMsg msg
    Ok v => v

-- `makeDir` (global extern) errors EEXIST on an already-present directory;
-- tolerate that one case, exactly like `fs.mdk`'s `mkdirAll` does for its own
-- EEXIST arm — kept local rather than `import fs` to avoid pulling `fs`'s
-- `FileStat` type into this hot module for a single directory create
-- ([T-STDLIB-IMPORT]: a bare new-type import measurably doubled Ir on a
-- throwaway program).
ensureOutDir : String -> <FileWrite> Result String Unit
ensureOutDir dir = match makeDir dir
  Ok _ => Ok ()
  Err e => if isSome (stringIndexOf "exists" e) then Ok () else Err e

-- Read + doc every kept target, short-circuiting on the first read failure.
collectModuleDocs : String ->
  String ->
  String ->
  List String ->
  <IO> Result String (List ModuleDoc)
collectModuleDocs _ _ _ [] = Ok []
collectModuleDocs rsrc csrc stdlibDir (target :: rest) = match readSource target
  Err msg => Err "\{target}: \{msg}"
  Ok tsrc => match docParseError target tsrc
    Some msg => Err msg
    None =>
      let roots = entrySearchRoots (dirOf2 target) ++ [stdlibDir]
      let md = computeModuleDoc rsrc csrc tsrc target roots
      map (md :: _) (collectModuleDocs rsrc csrc stdlibDir rest)

-- A library page is named for its module's DERIVED name (`mdName`: a stdlib
-- module's import id, otherwise the basename minus `.mdk`), so two non-stdlib
-- targets in different directories that share a basename claim the SAME page: `writeLibraryPages` wrote one and then
-- overwrote it with the other, the index grew a dead link plus two
-- identically-titled sections, and `inventory.json` filed both modules' entries
-- under one name — all silently, at exit 0.  Refuse instead, BEFORE writing
-- anything, so a half-written output tree is never left behind.
checkDistinctModuleNames : List ModuleDoc -> <IO> Unit
checkDistinctModuleNames mds = checkDistinctGo mds []

checkDistinctGo : List ModuleDoc -> List String -> <IO> Unit
checkDistinctGo [] _ = ()
checkDistinctGo (md :: rest) seen =
  let n = mdName md
  if elemStrCli n seen then
    let _ =
      ePutStrLn
        "medaka doc --out: two targets share the module name `\{n}` and would write the same page `\{n}.md`; rename one"
    stageExit 1
  else
    checkDistinctGo rest (n :: seen)

elemStrCli : String -> List String -> Bool
elemStrCli _ [] = False
elemStrCli x (y :: ys) = x == y || elemStrCli x ys

writeLibraryOutputs : String -> List ModuleDoc -> <IO> Unit
writeLibraryOutputs outDir mds =
  let _ = checkDistinctModuleNames mds
  let _ = writeLibraryPages outDir mds
  let _ = writeLibraryFile outDir "index.md" (renderIndex mds)
  writeLibraryFile
    outDir
    "inventory.json"
    (stringify (libraryInventoryJson mds))

writeLibraryPages : String -> List ModuleDoc -> <IO> Unit
writeLibraryPages _ [] = ()
writeLibraryPages outDir (md :: rest) =
  let _ = writeLibraryFile outDir (mdName md ++ ".md") (renderModulePage md)
  writeLibraryPages outDir rest

writeLibraryFile : String -> String -> String -> <IO> Unit
writeLibraryFile outDir name contents =
  match writeFile (joinPath outDir name) contents
    Ok _ => ()
    Err msg => dieMsg msg

-- ── check-policy ───────────────────────────────────────────────────────────
-- WS-1a of EFFECTS-CONFORMANCE-ROADMAP.md.  Mirrors bin/main.ml's `check-policy`
-- arm: parse `--allow L1,L2,… / --fn name / <file>`, load and analyze the
-- target as `manifest` does (`analyzeTarget`), read the named fn's inferred
-- effect row, and accept (+ run on a sample request) or reject (+ print the
-- call chain) per the policy.  We print the report and exit 0 (accept) / 1
-- (reject).  Defaults (allow "Cache,Log", fn "transform") match the oracle.
checkPolicyHelpText : String
checkPolicyHelpText = stringConcat [
  "medaka check-policy — Check a plugin's inferred effects against an allow-list\n",
  "\n", "Usage:\n",
  "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]\n", "\n",
  "  --allow L1,L2,...  effect labels the plugin is permitted to use\n",
  "                     (default: Cache,Log)\n",
  "  --fn name          the function whose inferred effect row is checked\n",
  "                     (default: transform)\n", "\n",
  "Prints an accept/reject header; on accept, also runs the plugin on a\n",
  "sample request. Exit 0 on accept, 1 on reject.\n"
]

-- `--allow`/`--fn` take values; only the space form would be read, so
-- `--allow=IO` would fall through as the FIRST POSITIONAL and become the
-- filename (AS-FILENAME, C1's §1 opening transcript).  Both spellings now
-- reach the same key, and the `PolicyArgs` triple is built HERE from the
-- parse rather than by re-scanning raw argv.
-- `withStrictDash` (S-5, #2355 residual A): an undeclared `-x` would otherwise fall
-- through as the target file (AS-FILENAME); now C2-rejected like `--x`.
policyArgSpec : ArgSpec
policyArgSpec =
  withStrictDash
    (spec "check-policy" [
      value ["--allow"] "L1,L2,..." "effect labels the plugin may use",
      value ["--fn"] "NAME" "the function whose effect row is checked",
    ])

runCheckPolicyCmd : List String -> <IO> Unit
runCheckPolicyCmd argv0 =
  let a = requireArgs policyArgSpec argv0
  -- LAST-WINS on both values and FIRST positional as the file; defaults
  -- match `check-policy`'s documented defaults (Cache,Log / transform).
  runCheckPolicyArgs
    (PolicyArgs
      (firstPositional a)
      (optDefault (lastValue "--allow" a) "Cache,Log")
      (optDefault (lastValue "--fn" a) "transform"))

-- The first positional, or `None` — keeps the first bare token and ignores
-- every later one.
firstPositional : Args -> Option String
firstPositional a = match a.positionals
  [] => None
  f :: _ => Some f

optDefault : Option String -> String -> String
optDefault (Some v) _ = v
optDefault None d = d

runCheckPolicyArgs : PolicyArgs -> <IO> Unit
runCheckPolicyArgs (PolicyArgs None _ _) =
  let _ =
    ePutStrLn
      "usage: medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]"
  stageExit 1
runCheckPolicyArgs (PolicyArgs (Some target) allow fn) =
  match analyzeTarget target fn
    Err diags if diags == "no '\{fn}' entry found" =>
      dieMsg ("rejected. " ++ diags)
    -- A target `check` refuses has no row to judge: the refusal names what
    -- failed and carries `check`'s own diagnostics.
    Err diags =>
      let _ =
        ePutStrLn
          "rejected. compiler analysis failed before policy evaluation; `medaka check \{target}` reports:"
      dieMsg diags
    Ok analysis => match runCheckPolicy analysis allow fn
      -- The accepted verdict prints before the sample run is forced, so a
      -- sample that panics leaves the verdict on stdout.

      -- C4 (docs/ops/CLI-CONFORMANCE.md §4): stdout carries the ANSWER,
      -- stderr everything else.  The ACCEPT report is the answer and
      -- stays on stdout; the REJECTION report is the reason for a
      -- nonzero exit — a diagnostic — and moves to stderr, where every
      -- sibling verb already reports failure.  Exit code unchanged.
      PolicyReject report =>
        let _ = ePutStr report
        stageExit 1
      PolicyAccept header sample =>
        let _ = putStr header
        putStr (sample ())

-- `manifest` and `check-policy` load and analyze their target exactly as
-- `medaka check` does: the multi-file loader (project root, sibling and stdlib
-- imports), `check`'s resolve diagnostics, then one elaboration of the graph
-- (`analyzeProgramReport`), refusing on any error `check` would report for it.  The
-- two verbs therefore read the entry's row from the same analysis, and a
-- manifest's claim is one `check-policy` can verify.
analyzeTarget : String -> String -> <IO> Result String EntryAnalysis
analyzeTarget target fn =
  let _ = carryTargetProfile None target
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let stdlibDir = root ++ "/stdlib"
  let roots = entrySearchRoots (dirOf2 target) ++ [stdlibDir]
  -- An unreadable prelude or target is not an analysis result: exit here.
  let prelude = orExit (readPreludeSources stdlibDir)
  let tsrc = orExit (readSource target)
  match loadProgramFilesLocatedE (_ => None) target roots
    Err lerr => match parseResult tsrc
      Err e => Err (ppParseError tsrc target e)
      Ok _ => Err (moduleLoadErrText tsrc target stdlibDir lerr)
    Ok modsWithPath =>
      analyzeLoaded prelude target roots stdlibDir fn modsWithPath

-- One front-end run (`frontEnd`) whose drive is the elaboration the verb reads.
-- A graph resolve rejects is refused with its resolve errors and not driven;
-- past resolve, the gate is `run`'s: the per-module diagnostics of the one elaboration, rendered located
-- against each module's own file, then anything only the graph-end drain saw.
analyzeLoaded : PreludeInputs ->
  String ->
  List String ->
  String ->
  String ->
  List (String, String, List Decl) ->
  <IO> Result String EntryAnalysis
analyzeLoaded prelude target roots stdlibDir fn modsWithPath =
  let rsrc = prelude.pnRuntimeSrc
  let csrc = prelude.pnCoreSrc
  let mods = map dropPathTriple modsWithPath
  let pathMap = map modIdToPath modsWithPath
  let trusted = projectTrustedMods target roots stdlibDir mods
  let rtD = desugaredPrelude rsrc
  let coreD = desugaredPrelude csrc
  let modsD = map desugarPair mods
  let _ = takeShippedPrelude unstaged prelude
  let front =
    frontEnd
      (stdlibExportsReader stdlibDir)
      (d =>
        analyzeProgramReport
          d.fdInputs
          (valueMainCandidate coreD modsD)
          None
          rtD
          coreD
          modsD)
      FrontInput {
        fiInputs = { driveInputsFor !selectedProfile False [] |
          diManifestRequests = [EntryOverPrelude fn HostInvocation],
          diPreludeKey = Some (preludeGeneration rsrc csrc),
        },
        fiAllowInternal = False,
        fiTrusted = trusted,
        fiRuntimeSrc = rsrc,
        fiCoreSrc = csrc,
        fiPolicy = NeverDriveRejected,
        fiProgram = FrontGraph modsWithPath modsD,
      }
  match front.foDriven
    None => Err (ppDiagBuckets front.foDiags)
    Some analysis =>
      let residual = analysis.eaElab.erResidual
      match locatedProjectDiags front.foDiags
        (Some errText, _, _) => Err errText
        (None, _, _) =>
          if isNone
            front.foReport.trChecked then match front.foReport.trResidual
            missing@(_ :: _) if all
              (p => tcCode (snd p) == TManifestEntry)
              missing => Err "no '\{fn}' entry found"
            _ => Err (residualOrGeneric pathMap target residual)
          else
            Ok analysis

-- ── manifest ─────────────────────────────────────────────────────────────────
-- WS-1c of EFFECTS-CONFORMANCE-ROADMAP.md.  Emit a module's verified capability
-- manifest as a TOML artifact.  Given a source file and an optional --fn name
-- (default "main"), typechecks the file, reads the named fn's inferred effect
-- row, and prints:
--
--   [package.capabilities]
--   Net = "idp.example.com/api"
--   Stdout = true
--
-- Every effect label is a host capability, so the whole verified row is emitted.
-- Labels sorted ascending (stable output).  Prefix-param → string TOML value;
-- ⊤/Unit param → boolean `true`.
--
-- WS-1c (deferred): Wasm custom section embedding (see
-- compiler/tools/check_policy.mdk comment + EFFECTS-SEMANTICS.md §7).
manifestHelpText : String
manifestHelpText = stringConcat [
  "medaka manifest — Emit a module's verified capability manifest as TOML\n",
  "\n",
  "Usage:\n",
  "  medaka manifest <file.mdk> [--fn name]\n",
  "\n",
  "  --fn name  the function whose inferred effect row is emitted\n",
  "             (default: main)\n",
  "\n",
  "Prints a [package.capabilities] TOML block: one entry per effect label\n",
  "in the function's inferred effect row (a prefix-param becomes a string\n",
  "value; a Unit/top param becomes `true`).\n",
]

-- Same C1 fix as check-policy: `--fn=main` would otherwise become the filename.
-- `withStrictDash` (S-5, #2355 residual A): an undeclared `-x` would otherwise fall
-- through as the target file (AS-FILENAME); now C2-rejected like `--x`.
manifestArgSpec : ArgSpec
manifestArgSpec =
  withStrictDash
    (spec "manifest" [
      value ["--fn"] "NAME" "the function whose effect row is emitted",
    ])

runManifestCmd : List String -> <IO> Unit
runManifestCmd argv0 =
  let a = requireArgs manifestArgSpec argv0
  runManifestArgs
    (ManifestArgs (firstPositional a) (optDefault (lastValue "--fn" a) "main"))

-- `medaka manifest` loads and analyzes the target exactly as `medaka check`
-- does (`analyzeTarget`), refusing on anything `check` would refuse — an
-- ill-typed target or import, an unresolvable import, or a missing `--fn`
-- binding — all to STDERR at exit 1, nothing on stdout.
runManifestArgs : ManifestArgs -> <IO> Unit
runManifestArgs (ManifestArgs None _) =
  dieMsg "usage: medaka manifest <file.mdk> [--fn name]"
runManifestArgs (ManifestArgs (Some target) fn) = match analyzeTarget target fn
  Err diags => dieMsg diags
  Ok analysis => match runManifest analysis fn
    Ok toml => putStr toml
    Err refusal => dieMsg refusal

-- ── lint ──────────────────────────────────────────────────────────────────
-- Parse target file(s) and run lint rules over the raw pre-desugar AST.
-- Flags:
--   --fix                rewrite fixable findings in-place
--   --unsafe-fixes       with --fix: also apply the fixes marked Unsafe
--   --json               emit the {"files":[...]} structured-diagnostics
--                        envelope (same schema as `check --json`) instead of
--                        human text; --fix is ignored in this mode (#249,
--                        report-only — autofix is out of scope)
--   --cache              reuse per-file results for files whose CONTENT is
--                        unchanged (#395; opt-in, like ESLint's --cache).  See
--                        `lintCacheCtx` for the exact scope and the two ways it
--                        declines.  Output is byte-identical to a run without it
--                        — test/diff_compiler_lint_cache.sh is the gate.
--   --disable=r1,r2,...  suppress findings from the named rules
--   --only=r1,...        keep only findings from the named rules
--   --deny=r1,...        promote findings from the named rules to SevError
--   --baseline=<file>    promote a rule's findings in a file to SevError only
--                        when that file's count EXCEEDS its row in <file> (a
--                        per-(file, rule) count baseline, #2619).  A file with
--                        findings and no row is an error, not a pass.
--   --write-baseline=<f> regenerate <f> from this run instead of reporting;
--                        the ONLY sanctioned way to move a count
-- Target resolution:
--   ≥1 explicit file args   → lint each in order
--   single directory arg    → lint all top-level .mdk files in that dir (sorted)
--   no file arg             → find medaka.toml project root, lint top-level .mdk files
--     (note: top-level only — subdirectory .mdk files are not walked recursively)
-- Exit 0 unless a SevError finding exists (only via --deny in v1 report mode).
-- Declaration order is the roster order, reproducing the old
-- `lintBoolFlags ++ lintValueFlags` rendering.
-- `withStrictDash` (S-5, #2355 residual A): an undeclared `-x` would otherwise fall
-- through as a target path ("these targets do not exist"); now C2-rejected.
lintArgSpec : ArgSpec
lintArgSpec =
  withStrictDash
    (spec "lint" [
      switch ["--fix"] "rewrite fixable findings in place",
      switch
        ["--unsafe-fixes"]
        "with --fix: also apply fixes that may change behaviour",
      switch ["--json"] "emit the structured-diagnostics envelope",
      switch ["--cache"] "reuse per-file results for unchanged files",
      value ["--disable"] "r1,r2,..." "suppress findings from the named rules",
      value ["--only"] "r1,..." "keep only findings from the named rules",
      value
        ["--deny"]
        "r1,..."
        "promote findings from the named rules to error",
      value
        ["--baseline"]
        "<file>"
        "error only where a file's per-rule count exceeds its row in <file>",
      value
        ["--write-baseline"]
        "<file>"
        "regenerate <file> from this run instead of reporting",
      switch ["--list-rules"] "list every rule with its metadata",
      switch ["--markdown"] "with --list-rules: render docs/ops/LINT-RULES.md",
      value
        ["--scope"]
        "universal|internal"
        "with --list-rules: keep one scope",
      value
        ["--ratchet"]
        "gated|baselined"
        "with --list-rules: keep one ratchet",
      value ["--tier"] "file|cross" "with --list-rules: keep one rule tier",
      switch ["--names"] "with --list-rules: print only the rule names",
      value ["--explain"] "<rule>" "print a rule's summary and documentation",
      switch
        ["--internal"]
        "run the internal-scope rules on every target, manifest or not",
    ])

runLintCmd : List String -> <IO> Unit
runLintCmd argv0 =
  let a = requireArgs lintArgSpec argv0
  if flag "--list-rules" a then
    let _ = assertRegistryViewFlags "--list-rules" listRulesBannedFlags a
    runLintListRules a
  else if isSome (flagValue "--explain" a) then
    let _ = assertRegistryViewFlags "--explain" explainBannedFlags a
    runLintExplain a
  else
    let _ = assertNoListOnlyFlags a
    runLintTargets a

-- Flags that mean nothing to a registry view are rejected rather than accepted
-- and ignored.  `--json` is meaningful to `--list-rules` only, and `--markdown`
-- is the page renderer, so it takes no filter or format flag.
lintRunFlags : List String
lintRunFlags = [
  "--fix",
  "--unsafe-fixes",
  "--cache",
  "--internal",
  "--disable",
  "--only",
  "--deny",
  "--baseline",
  "--write-baseline",
]

listRulesBannedFlags : List String
listRulesBannedFlags = ["--explain"] ++ lintRunFlags

explainBannedFlags : List String
explainBannedFlags =
  [
      "--json",
      "--markdown",
      "--names",
      "--scope",
      "--ratchet",
      "--tier",
    ]
    ++ lintRunFlags

flagGiven : Args -> String -> Bool
flagGiven a n = flag n a || isSome (flagValue n a)

assertRegistryViewFlags : String -> List String -> Args -> <IO> Unit
assertRegistryViewFlags mode banned a =
  let bad = filter (flagGiven a) banned
  if not (isEmpty a.positionals) then
    dieMsg "medaka lint: \{mode} takes no target paths"
  else if not (isEmpty bad) then
    dieMsg "medaka lint: \{joinWith ", " bad} cannot be combined with \{mode}"
  else if mode == "--list-rules" && flag "--markdown" a then
    assertMarkdownTakesNoFilter a

assertMarkdownTakesNoFilter : Args -> <IO> Unit
assertMarkdownTakesNoFilter a =
  let bad =
    filter (flagGiven a) ["--json", "--names", "--scope", "--ratchet", "--tier"]
  if not (isEmpty bad) then
    dieMsg
      "medaka lint: \{joinWith ", " bad} cannot be combined with --markdown"

-- `--list-rules` and `--explain` print the registry and read no files; a
-- list-only filter given without `--list-rules` would otherwise be accepted
-- and ignored.
assertNoListOnlyFlags : Args -> <IO> Unit
assertNoListOnlyFlags a =
  if flag "--markdown" a
    || flag "--names" a
    || isSome (flagValue "--scope" a)
    || isSome (flagValue "--ratchet" a)
    || isSome (flagValue "--tier" a) then
    dieMsg
      "medaka lint: --markdown/--names/--scope/--ratchet/--tier require --list-rules"

runLintListRules : Args -> <IO> Unit
runLintListRules a =
  if flag "--markdown" a then
    putStr rulesPageMarkdown
  else
    let picked =
      selectRuleRows
        (flagValue "--scope" a)
        (flagValue "--ratchet" a)
        (flagValue "--tier" a)
    match picked
      Err msg => dieMsg "medaka lint: \{msg}"
      Ok rows =>
        if flag "--json" a then
          putStr (renderRuleRowsJson rows)
        else if flag "--names" a then
          putStr (renderRuleRowsNames rows)
        else
          putStr (renderRuleRowsText rows)

runLintExplain : Args -> <IO> Unit
runLintExplain a = match optDefault (flagValue "--explain" a) ""
  "" => dieMsg "medaka lint: --explain needs a rule name"
  name => match explainRule name
    Err msg => dieMsg "medaka lint: \{msg}"
    Ok text => putStrLn text

runLintTargets : Args -> <IO> Unit
runLintTargets a =
  -- C1: `parseLintFlagList` keys on the `--flag=` prefix (the spelling the
  -- pre-commit hook uses).  Rewriting the space form INTO that prefix instead
  -- leaves `--deny rule-x`'s `rule-x` behind as an ordinary
  -- lint TARGET with the flag applied to nothing.  `args.mdk` accepts BOTH
  -- spellings and hands back one value, so no rewrite is needed and the split
  -- goes straight through `splitLintNames` (the same splitter
  -- `parseLintFlagList` used, so the comma handling is unchanged, empty-string
  -- edge included).  `.githooks/pre-commit:164` uses `--deny=…` and
  -- `test/snapshot_bless.sh` uses the space form `--stages …`; both
  -- still land on the same names.
  -- C2: `lint`'s SILENT-ACCEPT cell — `lintTargets` skipped every `--`-shaped
  -- token, so `medaka lint --zzz ok.mdk` printed nothing and exited 0,
  -- indistinguishable from a clean run.
  let disableNames = lintNamesOf "--disable" a
  let onlyNames = lintNamesOf "--only" a
  let denyNames = lintNamesOf "--deny" a
  let _ = assertLintRuleNames (disableNames ++ onlyNames ++ denyNames)
  let fixMode = flag "--fix" a
  let _ = assertUnsafeFixesNeedFix a
  let jsonMode = flag "--json" a
  let baselineArg = flagValue "--baseline" a
  let writeBaselineArg = flagValue "--write-baseline" a
  let _ = assertBaselineFlagsCoherent baselineArg writeBaselineArg fixMode
  let fileArgs = a.positionals
  let _ = assertLintTargetsExist fileArgs
  let files = resolveLintTargets fileArgs
  -- C3 (docs/ops/CLI-CONFORMANCE.md §3): `lint`'s empty-target cell was the
  -- worst of the three — it printed NOTHING and exited 0, so a directory that
  -- resolved to no .mdk files was byte-indistinguishable from a clean lint of a
  -- real corpus.  Converge on the one pair every verb uses: (stderr, 1).  This
  -- sits BEFORE the `--json` branch deliberately: a machine consumer must learn
  -- that its target set was empty too, and an error on stderr leaves stdout's
  -- one-JSON-document rule intact (C4).
  let _ = assertLintTargetsNonEmpty files
  let _ =
    assertInternalRulesReachable
      (flag "--internal" a)
      (onlyNames ++ denyNames)
      files
  -- The declaration index the rules query: the stdlib's rows, and the
  -- project's too when a project rule is active.  Built at most ONCE per
  -- `medaka lint` invocation and threaded down — a rule's `check` is pure, and
  -- rebuilding it per target file would re-read every shard once per file.
  -- `indexForRun` builds it from the needs of the rules that survive
  -- `--only`/`--disable`, and it self-disables to empty when the stdlib cannot
  -- be read.  `--cache` builds for the whole roster: it persists
  -- `lintEntryOf`'s full-roster findings past this process's flag choices
  -- (under `--cache` `lintEntryOf` runs `allRules`, unfiltered), so an entry
  -- computed from a degraded index would silently omit a rule's findings for
  -- every later `--cache` read.
  let indexResult = indexForRun (flag "--cache" a) onlyNames disableNames files
  match indexResult
    Err (StdlibIndexError { path, source, diagnostic }) =>
      if jsonMode then
        putStr (cjAllToJson [(path, source, [diagnostic])])
      else
        ePutStrLn (ppDiagCliSrc source path diagnostic)
      stageExit 1
    Ok stdlibIdx =>
      runLintWithIndex
        stdlibIdx
        a
        disableNames
        onlyNames
        denyNames
        fixMode
        jsonMode
        baselineArg
        writeBaselineArg
        files

runLintWithIndex : StdlibIndex ->
  Args ->
  List String ->
  List String ->
  List String ->
  Bool ->
  Bool ->
  Option String ->
  Option String ->
  List String ->
  <IO> Unit
runLintWithIndex stdlibIdx a disableNames onlyNames denyNames fixMode jsonMode baselineArg writeBaselineArg files =
  -- The baseline keys on paths relative to the process's working directory (see
  -- lint_baseline.mdk's header), so the anchor is resolved once, here, and
  -- handed down alongside the parsed rows.
  let cwd = canonicalizePath "."
  let baseCtx = loadLintBaselineCtx cwd baselineArg
  let internalFlag = flag "--internal" a
  if isSome writeBaselineArg then
    runLintWriteBaselineCmd
      stdlibIdx
      internalFlag
      disableNames
      onlyNames
      denyNames
      cwd
      (optDefault writeBaselineArg "")
      files
  else if jsonMode then
    runLintJsonCmd
      stdlibIdx
      internalFlag
      disableNames
      onlyNames
      denyNames
      baseCtx
      files
  else
    let multiFile = match files
      _ :: _ :: _ => True
      _ => False
    let cacheCtx = lintCacheCtx (flag "--cache" a) fixMode
    let run = LintRun {
      lrInternal = internalFlag,
      lrFix = fixMode,
      lrUnsafe = flag "--unsafe-fixes" a,
      lrMulti = multiFile,
    }
    let (perFileErr, entries) =
      lintFilesGo
        stdlibIdx
        run
        disableNames
        onlyNames
        denyNames
        baseCtx
        cacheCtx
        files
        False
    -- Project rules only run in the multi-file REPORT path; a single target or
    -- --fix produces nothing (need ≥2 files), keeping single-file output identical.
    let crossErr =
      if multiFile && not fixMode then
        runProjectReport
          stdlibIdx
          internalFlag
          disableNames
          onlyNames
          denyNames
          entries
      else
        False
    -- Persist AFTER reporting: the cache is an optimisation, so a failure to
    -- write one must never change what a run says or whether it exits 0.
    let _ = match cacheCtx
      Some (cacheDir, stamp) => storeEntries cacheDir stamp entries
      None => ()
    if perFileErr || crossErr then stageExit 1

-- ── the lint baseline (#2619) ────────────────────────────────────────────────
--
-- `--baseline` is the third promotion channel after `--deny` and inline
-- directives, and the only one whose answer depends on HOW MANY findings a file
-- has: a rule the tree cannot yet be clean of is still enforceable if its
-- per-file count may only fall.  Everything the decision needs lives in
-- tools/lint_baseline.mdk; this layer resolves the flags, reads the file, and
-- puts the "which count moved" line on stderr next to the promoted findings.

-- The three flags name incompatible jobs — reading a baseline, rewriting one,
-- and rewriting source — and `--fix`'s path never consulted `--baseline` at
-- all (S3-2): it applied every fixable finding regardless of what the
-- baseline would have allowed to pass, so `--fix --baseline=<f>` silently
-- promoted nothing while still exiting 0. Reject every pairing rather than
-- silently letting one win or fixing past what the baseline permits.
assertBaselineFlagsCoherent : Option String ->
  Option String ->
  Bool ->
  <IO> Unit
assertBaselineFlagsCoherent baselineArg writeArg fixMode
  | isSome baselineArg && isSome writeArg =
    dieMsg "medaka lint: --baseline and --write-baseline are mutually exclusive"
  | isSome writeArg && fixMode =
    dieMsg "medaka lint: --write-baseline cannot be combined with --fix"
  | isSome baselineArg && fixMode =
    dieMsg "medaka lint: --baseline cannot be combined with --fix"
  | otherwise = ()

-- `--unsafe-fixes` widens what `--fix` applies; alone it would be accepted and
-- do nothing, which reads as a clean run.
assertUnsafeFixesNeedFix : Args -> <IO> Unit
assertUnsafeFixesNeedFix a =
  if flag "--unsafe-fixes" a && not (flag "--fix" a) then
    dieMsg "medaka lint: --unsafe-fixes requires --fix"

-- An unreadable or malformed baseline is fatal, never an empty one: a baseline
-- that answers "no rows, so nothing exceeds" reports green for every file in the
-- tree (lint_baseline.mdk's invariant).
loadLintBaselineCtx : String ->
  Option String ->
  <IO> Option (String, LintBaseline)
loadLintBaselineCtx _ None = None
loadLintBaselineCtx cwd (Some path) = match readLintBaseline path
  Err msg =>
    let _ = dieMsg "medaka lint: \{msg}"
    None
  Ok base => Some (cwd, base)

-- `--write-baseline`: regenerate the file from THIS run rather than reporting
-- against it.  Counts are read off the same per-file diagnostic triples the
-- `--json` surface emits, so what gets pinned is exactly what a report would
-- have found — a baseline can never be written from a different derivation than
-- the one that checks it.
runLintWriteBaselineCmd : StdlibIndex ->
  Bool ->
  List String ->
  List String ->
  List String ->
  String ->
  String ->
  List String ->
  <IO> Unit
runLintWriteBaselineCmd idx internalFlag disableNames onlyNames denyNames cwd out files =
  let triples =
    lintFilesToDiagTriples
      idx
      internalFlag
      disableNames
      onlyNames
      denyNames
      None
      files
  let parseFailures = flatMap lintBaselineParseFailures triples
  if listLen parseFailures > 0 then
    emitWarningLines parseFailures
    stageExit 1
  else
    let perFile = map (t => baselineFileCodes cwd t) triples
    match writeFile out (renderLintBaseline perFile)
      Err msg => dieMsg "medaka lint: cannot write `\{out}`: \{msg}"
      Ok _ =>
        ePutStrLn
          "medaka lint: wrote \{out} from \{intToString (listLen files)} file(s)"

lintBaselineParseFailures : (String, String, List Diag) -> List String
lintBaselineParseFailures (path, src, diags) =
  map (ppDiagCliSrc src path) (filter isLintParseDiagnostic diags)

isLintParseDiagnostic : Diag -> Bool
isLintParseDiagnostic (Diag _ code _ _ _ _) = diagIdIsSyntax code

-- #1173 rejected the SPACE form of `--disable`/`--only`/`--deny` outright,
-- because the old `lintTargets` skipped any `--`-prefixed token without
-- consuming a following value, so `--deny rule-name` left `rule-name` behind
-- as an ordinary lint TARGET with the flag applied to nothing and no
-- diagnostic saying so.  CLI-CONFORMANCE.md C1 supersedes that ruling: BOTH
-- spellings are accepted by every value-taking flag of every verb, and
-- `lintArgSpec` declares all three as value-taking, so neither spelling can
-- leave a value behind as a target.  #1173's actual harm — the silent drop —
-- is what C1 forbids; the one-spelling rule was only ever the cheap way to
-- prevent it.
--
-- The comma split is `splitLintNames`, the SAME splitter `parseLintFlagList`
-- applied to the text after `--flag=`, so `--disable=` (empty value) still
-- yields `[""]` and is still rejected by name — unchanged, deliberately.
lintNamesOf : String -> Args -> List String
lintNamesOf nm a = match flagValue nm a
  None => []
  Some v => splitLintNames v

-- §5f: an unknown rule name in `--only=`/`--disable=`/`--deny=` would otherwise be
-- accepted silently.  `--only=rule-nosuchrule` then matched NO rule, filtered
-- every finding away, and exited 0 — a typo that reads exactly like a clean
-- file.  Name the offender and the known set, same shape as an unknown flag.
assertLintRuleNames : List String -> <IO> Unit
assertLintRuleNames names =
  let bad = filterList (n => not (contains n allRuleNames)) names
  if isEmpty bad then
    ()
  else
    let _ =
      ePutStrLn
        "medaka lint: unknown rule \{joinWith ", " bad} (known: \{joinWith ", " allRuleNames})"
    stageExit 1

assertInternalRulesReachable : Bool -> List String -> List String -> <IO> Unit
assertInternalRulesReachable internalFlag names files =
  match inactiveInternalRuleUse internalFlag names files
    Some msg => dieMsg "medaka lint: \{msg}"
    None => ()

-- C3's "found nothing is a failure" arm for `lint`, mirroring `fmt`'s and
-- `codemod`'s wording exactly so the three verbs answer the empty case with one
-- message as well as one (stream, code) pair.  Distinct from
-- `assertLintTargetsExist`, which rejects a target that does not exist at all:
-- this one fires when every named target DID exist and simply held no `.mdk`.
assertLintTargetsNonEmpty : List String -> <IO> Unit
assertLintTargetsNonEmpty (_ :: _) = ()
assertLintTargetsNonEmpty [] = dieMsg "medaka lint: no .mdk files found"

assertLintTargetsExist : List String -> <IO> Unit
assertLintTargetsExist [] = ()
assertLintTargetsExist targets =
  let missing = filter (t => not (lintTargetExists t)) targets
  if isEmpty missing then
    ()
  else
    let _ = ePutStrLn "medaka lint: these targets do not exist:"
    dieMsg (joinNl (map (m => "  \{m}") missing))

-- ── snapshot ──────────────────────────────────────────────────────────────
-- `medaka snapshot [--check | --new | --bless] [--out <dir>] [--isolate] <paths...>`
--
-- Directory targets are expanded by the SAME `expandLintTarget`/`collectMdkFiles`
-- pair `medaka lint` and `medaka fmt` already use — dir-vs-file discrimination,
-- dotfile skipping and recursion all live in one place.
--
-- `--worker` is INTERNAL: the supervisor re-spawns this same binary with it (that is
-- the whole crash-resume mechanism, see tools/snapshot.mdk).  `--isolate` forces one
-- process per fixture and is a DEBUG aid only — the steady-state answer to a known
-- crasher is `isolate=true` in its `# META`.
--
-- The three modes are mutually exclusive and one is REQUIRED (an unqualified `medaka
-- snapshot <paths>` exits): "what do you want me to do with these files" has no safe
-- default when one of the answers is "rewrite the expectations".
--
--   --check  compare; write nothing.                                    (the gate)
--   --new    create a MISSING snapshot; never touch an existing one.
--   --bless  rewrite an EXISTING snapshot; never create one; and REFUSE outright if any
--            differing section carries diagnostic prose.  The three locks are argued in
--            tools/snapshot.mdk's header block; the SCOPE lock is enforced right here.
--
-- SCOPE (lock 1).  `--bless` requires explicit targets, and `assertBlessIsScoped` below
-- is the enforcement.  Yes, `files == []` already exits on the usage line — but that is
-- an accident of "no targets means nothing to do", and a later refactor that gave the
-- command a default corpus would silently turn `medaka snapshot --bless` into
-- bless-the-world.  OCaml's promote has a scope and deliberately no `make all`; naming
-- what you approve is the ONLY friction that survives with no CI in the loop, so it gets
-- its own guard with its own reason attached, not a side effect of another check.
--
-- Targets are FIXTURES (`.mdk`), never snapshot `.md` files — in either direction, for
-- every mode.  `--out` flattens fixtures from five different roots into one snapshot
-- dir by basename, so the `.md` -> fixture map is not invertible and a `.md` target
-- could not be resolved back to the source it must re-render.
--
-- A snapshot target that does not exist is a HARNESS error, not a fixture outcome.
--
-- Without this guard, an unreadable path was RENDERED as a snapshot whose entire
-- body was `# CRASH: cannot read fixture` — and `--check` then compared that section
-- against itself, matched, and reported PASS. Forever. So a typo'd path, or a
-- DELETED fixture, silently became a permanently-passing snapshot that tested
-- nothing.
--
-- That is exactly the silent-green bug class this whole harness was built to
-- REPLACE (see TESTING-DESIGN.md §2.3: a missing oracle exiting 2 = SKIP let
-- a fresh clone run zero tests and print "0 failed"). Never let "I could not read
-- it" become an expected output. Fail loudly, up front.
assertSnapshotTargetsExist : List String -> <IO> Unit
assertSnapshotTargetsExist files =
  let missing = filter (f => not (fileExists f)) files
  if isEmpty missing then
    ()
  else
    let _ = ePutStrLn "medaka snapshot: these targets do not exist:"
    dieMsg (joinNl (map (m => "  \{m}") missing))

-- Lock 1, on its own, with its own message.  A `--bless` naming nothing is refused BEFORE
-- target expansion, so the refusal cannot be confused with "your glob matched no files".
assertBlessIsScoped : Bool -> List String -> <IO> Unit
assertBlessIsScoped blessOn targets =
  if not blessOn || not (isEmpty targets) then
    ()
  else
    let _ =
      ePutStrLn
        "medaka snapshot: --bless requires explicit targets; there is no whole-suite bless"
    let _ = ePutStrLn "  name what you are approving, such as:"
    let _ =
      ePutStrLn
        "    medaka snapshot --bless --out test/snapshots/compiler compiler/frontend/lexer.mdk"
    let _ =
      ePutStrLn
        "  or, family-aware: sh test/snapshot_bless.sh --bless compiler/frontend/lexer.mdk"
    stageExit 1

snapshotHelpText : String
snapshotHelpText = stringConcat [
  "medaka snapshot — Per-stage snapshot tests\n", "\n", "Usage:\n",
  "  medaka snapshot [--check | --new | --bless] <paths...>\n",
  "                  [--out <dir>] [--stages <a,b,...>] [--isolate]\n", "\n",
  "One mode is REQUIRED, and the three are mutually exclusive:\n",
  "  --check   compare against the existing snapshot; write nothing\n",
  "  --new     create a MISSING snapshot; never touch an existing one\n",
  "  --bless   rewrite an EXISTING snapshot; never create one; requires\n",
  "            explicit targets (no whole-suite bless)\n", "\n",
  "  --out <dir>       snapshot directory (default derived from MEDAKA_ROOT)\n",
  "  --root <dir>      compiler/stdlib root, overriding MEDAKA_ROOT\n",
  "  --stages a,b,...  restrict to the named stages (default: every stage)\n",
  "  --isolate         run one process per fixture (debug aid for a crasher)\n",
  "\n",
  "  --worker          INTERNAL, not for direct use: the supervisor re-spawns\n",
  "                    this binary with --worker to render one batch in a child\n",
  "                    process, so a fixture that crashes the renderer does not\n",
  "                    take the run down. Documented because the verb parses it\n",
  "                    (an undocumented arm is a lie by omission), not because\n",
  "                    you should type it.\n", "\n",
  "A path may be a file or directory (recursively expanded).\n"
]

-- `--worker` is INTERNAL (the supervisor re-spawns this binary with it) but it
-- is still a flag this verb parses, so it belongs in the known set — omitting
-- it would make the crash-resume mechanism reject itself.
-- Declaration order is the roster order, reproducing the old
-- `snapshotBoolFlags ++ snapshotValueFlags` rendering.  `--worker` is marked
-- `internal`: it is a flag this verb genuinely parses (so it must stay in the
-- roster — omitting it would make the crash-resume mechanism reject itself)
-- but it is not for direct use.
-- `withStrictDash` (S-5, #2355 residual A): an undeclared `-x` would otherwise fall
-- through as a target path ("these targets do not exist"); now C2-rejected.
snapshotArgSpec : ArgSpec
snapshotArgSpec =
  withStrictDash
    (spec "snapshot" [
      switch ["--check"] "compare against the existing snapshot; write nothing",
      switch ["--new"] "create a MISSING snapshot; never touch an existing one",
      switch
        ["--bless"]
        "rewrite an EXISTING snapshot; requires explicit targets",
      switch ["--isolate"] "run one process per fixture",
      internal
        (switch ["--worker"] "INTERNAL: render one batch in a child process"),
      value ["--out"] "DIR" "snapshot directory",
      value ["--root"] "DIR" "compiler/stdlib root, overriding MEDAKA_ROOT",
      value ["--stages"] "a,b,..." "restrict to the named stages",
    ])

runSnapshotCmd : List String -> <IO> Unit
runSnapshotCmd argv0 =
  -- C1: the old `snapFlagValue` read only the space form, so `--stages=parse`
  -- was SILENTLY DROPPED — every stage rendered and nothing said so.
  -- C2: `snapshotTargets` skipped every unrecognized `--`-shaped token, so an
  -- unknown flag was either swallowed by the mode-missing usage line
  -- (REJECT-VAGUE) or, WITH a mode present, dropped without a word.
  let a = requireArgs snapshotArgSpec argv0
  let root = match flagValue "--root" a
    Some r => r
    None => envOr "MEDAKA_ROOT" defaultMedakaRoot
  let sel = snapshotStages a
  let targets = a.positionals
  let _ = assertBlessIsScoped (flag "--bless" a) targets
  let files = flatMap expandLintTarget targets
  let _ = assertSnapshotTargetsExist files
  if isEmpty files then
    let _ =
      ePutStrLn
        "usage: medaka snapshot [--check|--new|--bless] [--out <dir>] [--stages <a,b,…>] <paths...>"
    stageExit 1
  else if flag "--worker" a then
    runSnapshotWorker root sel files
  else match snapshotMode a
    None =>
      let _ =
        ePutStrLn
          "medaka snapshot: pass --check, --new or --bless; exactly one mode is required"
      stageExit 1
    Some mode =>
      let ok =
        runSnapshotSupervisor
          root
          mode
          (flag "--isolate" a)
          (flagValue "--out" a)
          sel
          files
      if ok then () else stageExit 1

-- Exactly one mode, and it is mandatory.  Two modes at once is a hard error rather than
-- a precedence rule: `--check --bless` is a person who does not know which one they
-- meant, and guessing for them is how a verify run turns into a rewrite run.
snapshotMode : Args -> <IO> Option SnapMode
snapshotMode a =
  let modes = filterList (f => flag f a) ["--check", "--new", "--bless"]
  match modes
    ["--check"] => Some SnapCheck
    ["--new"] => Some SnapNew
    ["--bless"] => Some SnapBless
    [] => None
    many =>
      let _ =
        ePutStrLn
          "medaka snapshot: \{joinWith " " many} are mutually exclusive; pass one"
      let _ = stageExit 1
      None

-- `--stages parse,desugar,mark` restricts which sections a fixture renders (see
-- tools/snapshot.mdk).  Absent == every stage.  A typo'd stage name EXITS rather than
-- being dropped: silently rendering fewer sections than asked for would report a clean
-- pass over a stage that never ran.
snapshotStages : Args -> <IO> List String
snapshotStages a = match flagValue "--stages" a
  None => []
  Some spec => match parseStages spec
    Ok names => names
    Err msg =>
      let _ = ePutStrLn "medaka snapshot: \{msg}"
      let _ = stageExit 1
      []

-- `snapshotTargets`/`snapFlagValue` are gone: `Args.positionals` is exactly
-- the non-flag args minus every value-taking flag's VALUE, and `flagValue` is
-- the first-occurrence read `snapFlagValue` performed.

hasSlash : String -> Bool
hasSlash s = hasSlashFrom s (stringLength s)

hasSlashFrom : String -> Int -> Bool
hasSlashFrom _ 0 = False
hasSlashFrom s i = stringSlice (i - 1) i s == "/" || hasSlashFrom s (i - 1)

-- dirname on a POSIX path.  A deliberate duplicate of `support/path.mdk`'s
-- `dirOf`, on the same license as that file's own `lsp.mdk` duplicate: too
-- small to be worth the coupling.  Keep the two bodies identical.
dirOf2 : String -> String
dirOf2 path = dirGo2 path (stringLength path)

dirGo2 : String -> Int -> String
dirGo2 path 0 = "."
dirGo2 path i =
  if stringSlice (i - 1) i path == "/" then
    stringSlice 0 (i - 1) path
  else
    dirGo2 path (i - 1)

-- ── repl ──────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `repl` arm (Repl.run) + repl_main.mdk: read
-- MEDAKA_ROOT/stdlib/{runtime,core}.mdk, init the session, then run the
-- interactive REPL loop.
--
-- Usage text for `medaka repl --help` / `-h` — mirrors lspUsageLine's shape
-- (#321), adapted to describe the interactive session instead of a stdio
-- protocol server.
-- `repl` takes no flags.  Not routed through `requireArgs`: it rejects ANY
-- argument, flag-shaped or not, so its rule is a positional-shape rule and
-- only the SENTENCE is shared.
replArgSpec : ArgSpec
replArgSpec = spec "repl" []

replUsageLine : String
replUsageLine = stringConcat [
  "medaka repl — Start the interactive REPL\n", "\n", "Usage:\n",
  "  medaka repl     Start an interactive session that reads expressions\n",
  "                 from stdin, evaluates them, and prints results until\n",
  "                 stdin closes (EOF) or you enter :quit.\n"
]

-- #657: discarding argv (`runReplCmd _ = ...`) lets `--help`/`-h`/any
-- bogus arg fall silently into the interactive read loop — which blocks on
-- stdin forever if stdin is an open terminal, the same shape as the bug
-- fixed in runLspCmd (#321), runMcpCmd (#299), and runNewCmd (#582). Blocking
-- on stdin with NO args is correct (that's the actual REPL); only an
-- explicit/unknown arg needs handling before the loop starts.
runReplCmd : List String -> <IO> Unit
runReplCmd [] =
  let _ = carryTargetProfile None (canonicalizePath "." ++ "/repl")
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let r = do
    prelude <- readPreludeSources (root ++ "/stdlib")
    -- S-1/#2234 (F-converge): content-keyed prelude memo, same as every other
    -- verb's route; consumed live by `initSession` below.
    let runtimeDecls = desugaredPrelude prelude.pnRuntimeSrc
    let preludeDecls = desugaredPrelude prelude.pnCoreSrc
    let _ = initSession runtimeDecls preludeDecls
    let _ = takeShippedPrelude unstaged prelude
    Ok (replLoop ())
  match r
    Err msg => dieMsg msg
    Ok v => v
runReplCmd ("--help" :: _) =
  let _ = putStrLn replUsageLine
  stageExit 0
runReplCmd ("-h" :: _) =
  let _ = putStrLn replUsageLine
  stageExit 0
runReplCmd (bad :: _) =
  -- C2: `repl` takes no flags, so its known set is empty.
  let _ = ePutStrLn (unknownFlagMessage replArgSpec bad)
  dieMsg replUsageLine

-- ── lsp ───────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `lsp` arm (Lsp_server.run) + lsp_main.mdk: read
-- MEDAKA_ROOT/stdlib/{runtime,core}.mdk, then run the JSON-RPC-over-stdio
-- loop (initialize handshake + publishDiagnostics on didOpen/didChange).
--
-- Usage text for `medaka lsp --help` / `-h` — mirrors mcpUsageLine's one-line
-- description plus the stdio-blocking reminder, adapted for the Language
-- Server Protocol. A plain String (not a function) so it can be printed to
-- either stdout (help) or stderr (error), matching newUsageLine's shape
-- (#582).
-- `lsp` takes no flags either; same shape as `replArgSpec`.
lspArgSpec : ArgSpec
lspArgSpec = spec "lsp" []

lspUsageLine : String
lspUsageLine = stringConcat [
  "medaka lsp — Run the Language Server Protocol server over stdio\n", "\n",
  "Usage:\n",
  "  medaka lsp     Start the server; it reads JSON-RPC requests from stdin\n",
  "                 and writes responses to stdout until stdin closes (EOF).\n",
  "                 This is the normal, correct behavior for an LSP stdio\n",
  "                 server — it is not supposed to be interactive.\n"
]

-- #321: discarding argv (`runLspCmd _ = ...`) lets `--help`/`-h`/any
-- bogus arg fall silently into the JSON-RPC read loop — which blocks on stdin
-- forever if stdin is an open terminal. Blocking on stdin with NO args is
-- correct (that's the actual protocol); only an explicit/unknown arg needs
-- handling before the server starts. Structurally mirrors runMcpCmd (#299,
-- same file) since lsp — like mcp — takes no positional arguments in normal
-- use; the rejection wording is the shared C2 one (`unknownFlagMessage`), as
-- runNewCmd's now is too.
runLspCmd : List String -> <IO> Unit
runLspCmd [] = runLspServerFromEnv ()
runLspCmd ("--help" :: _) =
  let _ = putStrLn lspUsageLine
  stageExit 0
runLspCmd ("-h" :: _) =
  let _ = putStrLn lspUsageLine
  stageExit 0
runLspCmd (bad :: _) =
  -- C2: `lsp` takes no flags either.
  let _ = ePutStrLn (unknownFlagMessage lspArgSpec bad)
  dieMsg lspUsageLine

runLspServerFromEnv : Unit -> <IO> Unit
runLspServerFromEnv _ =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let r = do
    prelude <- readPreludeSources (root ++ "/stdlib")
    let _ = loadCheckPrelude prelude
    Ok (runServer prelude.pnRuntimeSrc prelude.pnCoreSrc medakaVersion)
  match r
    Err msg => dieMsg msg
    Ok v => v

-- `mcp` takes no flags; same shape as `lspArgSpec`.
mcpArgSpec : ArgSpec
mcpArgSpec = spec "mcp" []

-- Usage text for `medaka mcp --help` / `-h`: the one-line description the
-- top-level help gives mcp, plus the reminder that it's a stdio server (so a
-- reader knows why it blocks).
mcpUsageLine : String
mcpUsageLine = stringConcat [
  "medaka mcp — Run the MCP server over stdio (JSON-RPC for agents)\n", "\n",
  "Usage:\n",
  "  medaka mcp     Start the server; it reads JSON-RPC requests from stdin\n",
  "                 and writes responses to stdout until stdin closes (EOF).\n",
  "                 This is the normal, correct behavior for an MCP stdio\n",
  "                 server — it is not supposed to be interactive.\n"
]

-- `medaka mcp`: the MCP (Model Context Protocol) stdio server.  Mirrors
-- runLspCmd exactly — load MEDAKA_ROOT/stdlib/{runtime,core}.mdk and hand the
-- prelude sources to the tools.mcp entry point (they're threaded through so the
-- tools added by later issues can run the compiler pipeline).  Same `<IO>`
-- effect row as runLspCmd (the `Mut`/`Panic` class the issue cited was cut
-- 2026-07-14 — effects are capabilities only).
--
-- #299: discarding argv (`runMcpCmd _ = ...`) lets `--help`/`-h`/any
-- bogus arg fall silently into the JSON-RPC read loop — which blocks on stdin
-- forever if stdin is an open terminal. Blocking on stdin with NO args is
-- correct (that's the actual protocol); only an explicit/unknown arg needs
-- handling before the server starts.
runMcpCmd : List String -> <IO> Unit
runMcpCmd [] = runMcpServerFromEnv ()
runMcpCmd ("--help" :: _) =
  let _ = putStrLn mcpUsageLine
  stageExit 0
runMcpCmd ("-h" :: _) =
  let _ = putStrLn mcpUsageLine
  stageExit 0
runMcpCmd (bad :: _) =
  -- C2: `mcp` takes no flags either.
  let _ = ePutStrLn (unknownFlagMessage mcpArgSpec bad)
  dieMsg mcpUsageLine

runMcpServerFromEnv : Unit -> <IO> Unit
runMcpServerFromEnv _ =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let stdlibDir = root ++ "/stdlib"
  let r = do
    prelude <- readPreludeSources stdlibDir
    let _ = loadCheckPrelude prelude
    Ok
      (runMcpServer
        prelude.pnRuntimeSrc
        prelude.pnCoreSrc
        stdlibDir
        sourceStalenessVerdict
        medakaVersion)
  match r
    Err msg => dieMsg msg
    Ok v => v
# DESUGAR
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true) (mem "codeText" false))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "executedMainInputs" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestSelector" true) (mem "InvocationProtocol" true))))
(DUse false (UseGroup ("tools" "check") ((mem "checkModulesReport" false) (mem "entryExhaust" false))))
(DUse false (UseGroup ("tools" "snapshot") ((mem "runSnapshotWorker" false) (mem "runSnapshotSupervisor" false) (mem "parseStages" false) (mem "SnapMode" true))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSourceChecked" false) (mem "FmtMode" true))))
(DUse false (UseGroup ("tools" "gate_cmd") ((mem "gateHelpText" false) (mem "runGateCmd" false))))
(DUse false (UseGroup ("tools" "interface_cmd") ((mem "interfaceHelpText" false) (mem "runInterfaceCmd" false))))
(DUse false (UseGroup ("tools" "new_cmd") ((mem "newProject" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "BuildReport" false) (mem "BuildTarget" true) (mem "ppBuildReport" false) (mem "runBuild" false) (mem "emitRtObj" false) (mem "emitPreludeObj" false) (mem "envOr" false) (mem "defaultMedakaRoot" false) (mem "readPreludeSources" false) (mem "loadPreludeInterface" false) (mem "PreludeInputs" true) (mem "SideFile" true) (mem "staleLine" false) (mem "shippedInputs" false) (mem "FileVerdict" false) (mem "checkPreludeElab" false) (mem "loadPreludeElab" false) (mem "preludeDeclsVerdict" false) (mem "reportStaleLine" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinNl" false) (mem "joinWith" false) (mem "splitNl" false) (mem "startsWith" false) (mem "endsWith" false) (mem "anyList" false) (mem "filterList" false) (mem "contains" false) (mem "sortUniqS" false) (mem "listLen" false) (mem "schemeLineName" false) (mem "stringTrim" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("support" "opcount") ((mem "setOpCounting" false) (mem "opSnap" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageCountInit" false) (mem "stageDump" false) (mem "stageExit" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false) (mem "joinPath" false))))
(DUse false (UseGroup ("support" "timer") ((mem "perfEnabled" false) (mem "now" false) (mem "emitPhase" false) (mem "emitPhaseAO" false) (mem "allocSnap" false) (mem "emitTotal" false) (mem "perfArm" false) (mem "emitAbortTotal" false) (mem "perfSinkOn" false) (mem "flushPerfSinkProse" false))))
(DUse false (UseGroup ("list") ((mem "sortOn" false) (mem "head" false))))
(DUse false (UseGroup ("driver" "profile_select") ((mem "manifestProfileOf" false) (mem "carryProjectProfile" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "Backend" true) (mem "buildableNames" false) (mem "lookupProfile" false) (mem "profileBackend" false) (mem "runProfile" false) (mem "selectedProfile" false))))
(DUse false (UseGroup ("tools" "target_check") ((mem "targetRefusal" false) (mem "ppTargetDiag" false) (mem "foldTargetDiags" false))))
(DUse false (UseGroup ("string") ((mem "toInt" false))))
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "Args" true) (mem "spec" false) (mem "switch" false) (mem "value" false) (mem "internal" false) (mem "parseArgs" false) (mem "flag" false) (mem "flagValue" false) (mem "lastValue" false) (mem "flagValues" false) (mem "unknownFlagMessage" false) (mem "usageExitCode" false) (mem "withStrictDash" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "letBindName" false) (mem "Decl" true) (mem "ExternDecl" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" false) (mem "LetBind" true) (mem "EvTable" false) (mem "EvId" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "parseWithPositionsLocated" false) (mem "parseResult" false) (mem "parseLocatedResult" false) (mem "Positions" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "preludeGeneration" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugarIn" false))))
(DUse false (UseGroup ("tools" "target_parse") ((mem "targetDesugared" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgramFilesLocatedE" false) (mem "stdinEntry" false) (mem "readStdinProgram" false) (mem "stdinReadOverride" false) (mem "readSource" false) (mem "readSourceE" false) (mem "sourceNotUtf8Message" false) (mem "dropPathTriple" false) (mem "modIdToPath" false) (mem "findProjectRoot" false) (mem "findProjectRootOrSelf" false) (mem "entrySearchRoots" false) (mem "projectTrustedMods" false) (mem "stdlibOwnership" false))))
(DUse false (UseGroup ("driver" "front_gate") ((mem "GateAsk" true) (mem "cliStdlibExports" false) (mem "envelopeWithNotes" false) (mem "moduleLoadErrText" false) (mem "ppParseError" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "desugaredModPairs" false) (mem "CheckDrive" true) (mem "CheckDump" true) (mem "frontEnd" false) (mem "checkFrontDrive" false) (mem "FrontProgram" true) (mem "FrontInput" true) (mem "FrontPolicy" true) (mem "FrontOutput" true) (mem "ppDiagCli" false) (mem "ppDiagCliSrc" false) (mem "ppDiagCliLines" false) (mem "renderTcDiags" false) (mem "ppDiagBuckets" false) (mem "stdlibExportsReader" false) (mem "diagOfResError" false) (mem "diagOfTypeError" false) (mem "relDiagPath" false) (mem "srcLinesArr" false) (mem "Diag" true) (mem "DiagId" true) (mem "diagIdIsSyntax" false) (mem "Severity" true) (mem "Severity" true) (mem "cjPosition" false) (mem "cjRange" false) (mem "cjRangeOfLoc" false) (mem "cjDiagnostic" false) (mem "cjFileEntry" false) (mem "cjAllToJson" false) (mem "flushRunEnvelope" false) (mem "pendingStaleNotice" false) (mem "pendingPreludeNotices" false) (mem "readDiagSrc" false) (mem "optField" false) (mem "cjFixJson" false) (mem "mkDiag" false) (mem "checkJsonFileParts" false) (mem "CheckJson" true) (mem "ppCheckJson" false) (mem "cjFoldIntoFile" false) (mem "readFileSafe" false) (mem "diagIsError" false) (mem "diagIsWarn" false) (mem "cohWarnsOfTriple" false) (mem "joinedOrNone" false) (mem "renderTripleErrors" false) (mem "renderTripleWarnings" false) (mem "residualOrGeneric" false) (mem "coherenceWarnCode" false) (mem "runBuildWarnCodes" false) (mem "isCoherenceWarn" false) (mem "mainShapeWarnings" false) (mem "mainEntryError" false) (mem "ppMainEntryError" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false "parseJson") (mem "asString" false))))
(DUse false (UseGroup ("types" "publish") ((mem "TcReport" true) (mem "tcCode" false))))
(DUse false (UseGroup ("types" "program_facts") ((mem "ProgramFacts" false) (mem "factsOfChecked" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "TcDiag" false) (mem "driveInputsFor" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveInputs" true) (mem "DriveOutputs" true))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "asyncMainShapeError" false) (mem "shouldAutoPrintMain" false) (mem "valueMainCandidate" false) (mem "executedFromReport" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "evalModulesOutputRunFacts" false) (mem "currentEvalFile" false) (mem "modulePathMap" false) (mem "runJsonMode" false) (mem "pendingRunDiags" false) (mem "progArgsRef" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTest" false) (mem "runTestReport" false) (mem "runTestGradedReport" false) (mem "filterMatchedNothing" false) (mem "testHelpText" false) (mem "testArgSpec" false) (mem "parseTestEngines" false) (mem "parseTestCasesFlag" false) (mem "parseTestIntFlag" false) (mem "runTestOne" false) (mem "cliTestReportOk" false) (mem "cliTestReportJson" false) (mem "cliGradedTestReportOk" false) (mem "cliGradedTestReportJson" false) (mem "checkTestMdkRoster" false) (mem "testFilesGo" false) (mem "runEvalPropsWorker" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "seedPropRng" false) (mem "PropRequest" true))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Engine" true))))
(DUse false (UseGroup ("tools" "repl") ((mem "initSession" false) (mem "replLoop" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "runServer" false))))
(DUse false (UseGroup ("tools" "mcp") ((mem "runMcpServer" false))))
(DUse false (UseGroup ("tools" "doc") ((mem "runDoc" false) (mem "ModuleDoc" false) (mem "computeModuleDoc" false) (mem "docParseError" false) (mem "mdName" false) (mem "renderModulePage" false) (mem "renderIndex" false) (mem "libraryInventoryJson" false) (mem "rebucketLibraryImpls" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "allRules" false) (mem "lintProgram" false) (mem "StdlibIndex" false) (mem "StdlibIndexError" true) (mem "indexForRun" false) (mem "applySuppressions" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMultiDirs" false) (mem "collectDirectives" false) (mem "findingToDiag" false) (mem "Finding" false) (mem "Directive" false) (mem "applyFixes" false) (mem "allRuleNames" false) (mem "applyFindingFilters" false) (mem "applyFindingDeny" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "splitLintNames" false))))
(DUse false (UseGroup ("tools" "lint_cache") ((mem "storeEntries" false))))
(DUse false (UseGroup ("tools" "lint_baseline") ((mem "LintBaseline" false) (mem "readLintBaseline" false) (mem "baselineKeyOf" false) (mem "baselineViolations" false) (mem "baselineViolationLine" false) (mem "applyBaselineToFindings" false) (mem "applyBaselineToDiags" false) (mem "baselineDiagViolations" false) (mem "diagCodeOf" false) (mem "findingRuleOf" false) (mem "renderLintBaseline" false))))
(DUse false (UseGroup ("tools" "codemod") ((mem "findCodemod" false) (mem "codemodMk" false) (mem "codemodWarnDecls" false) (mem "codemodListing" false) (mem "codemodSource" false) (mem "CodeMode" true))))
(DUse false (UseGroup ("tools" "lint_cmd") ((mem "explainRule" false) (mem "lintCacheCtx" false) (mem "lintHelpText" false) (mem "renderRuleRowsJson" false) (mem "renderRuleRowsNames" false) (mem "renderRuleRowsText" false) (mem "rulesPageMarkdown" false) (mem "selectRuleRows" false) (mem "runLintJsonCmd" false) (mem "lintFilesToDiagTriples" false) (mem "baselineFileCodes" false) (mem "runProjectReport" false) (mem "resolveLintTargets" false) (mem "lintFilesGo" false) (mem "LintRun" true) (mem "inactiveInternalRuleUse" false))))
(DUse false (UseGroup ("support" "cli_targets") ((mem "lintTargetExists" false) (mem "expandLintTarget" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "runCheckPolicy" false) (mem "PolicyArgs" true) (mem "PolicyOutcome" true) (mem "runManifest" false) (mem "ManifestArgs" true) (mem "analyzeProgramReport" false) (mem "EntryAnalysis" true) (mem "TargetInputs" true))))
(DTypeSig false "medakaVersion" (TyCon "String"))
(DFunDef false "medakaVersion" () (ELit (LString "0.1.0-preview")))
(DTypeSig false "medakaVersionString" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "medakaVersionString" (PWild) (EBlock (DoLet false false (PVar "commit") (EApp (EVar "buildCommit") (ELit LUnit))) (DoLet false false (PVar "date") (EApp (EVar "buildDate") (ELit LUnit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EVar "commit") (ELit (LString ""))) (EBinOp "==" (EVar "date") (ELit (LString "")))) (EBinOp "++" (ELit (LString "medaka ")) (EVar "medakaVersion")) (EIf (EBinOp "==" (EVar "commit") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EVar "display") (EVar "medakaVersion"))) (ELit (LString " (built "))) (EApp (EVar "display") (EVar "date"))) (ELit (LString ")"))) (EIf (EBinOp "==" (EVar "date") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EVar "display") (EVar "medakaVersion"))) (ELit (LString " ("))) (EApp (EVar "display") (EVar "commit"))) (ELit (LString ")"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EVar "display") (EVar "medakaVersion"))) (ELit (LString " ("))) (EApp (EVar "display") (EVar "commit"))) (ELit (LString ", built "))) (EApp (EVar "display") (EVar "date"))) (ELit (LString ")")))))))))
(DTypeSig false "printVersion" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printVersion" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "medakaVersionString") (ELit LUnit))))
(DTypeSig false "liveSourceFingerprint" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "liveSourceFingerprint" ((PVar "root")) (EBlock (DoLet false false (PVar "script") (EApp (EVar "stringConcat") (EListLit (ELit (LString "command -v perl >/dev/null 2>&1 || exit 7; cd \"")) (EVar "root") (ELit (LString "\" && { find compiler -name '*.mdk' -not -name '*_test.mdk' -print;")) (ELit (LString " find stdlib -name '*.mdk' -not -name '*_test.mdk' -print; } | LC_ALL=C sort")) (ELit (LString " | perl -ne 'chomp; print \"$_\\n\"; open F,\"<\",$_ or next; local $/; my $c=<F>; print $c if defined $c; close F' 2>/dev/null")) (ELit (LString " | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; elif command -v shasum >/dev/null 2>&1; then shasum -a 256; else cksum; fi; }")) (ELit (LString " | cut -d' ' -f1"))))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (ELit (LString "-c")) (EVar "script"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "h") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "h") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "h")))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "sourceStalenessVerdict" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sourceStalenessVerdict" (PWild) (EBlock (DoLet false false (PVar "baked") (EApp (EVar "buildFingerprint") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "baked") (ELit (LString ""))) (EVar "None") (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "compilerDir"))) (EVar "None") (EMatch (EApp (EVar "liveSourceFingerprint") (EVar "root")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "live")) () (EIf (EBinOp "==" (EVar "live") (EVar "baked")) (EVar "None") (EApp (EVar "Some") (EVar "compilerDir"))))))))))))
(DTypeSig false "checkSourceStaleness" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "checkSourceStaleness" ((PVar "argv")) (EMatch (EApp (EVar "sourceStalenessVerdict") (ELit LUnit)) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "compilerDir")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EBinOp "++" (ELit (LString "warning: this ./medaka was built from compiler source that differs from ")) (EVar "compilerDir")) (ELit (LString "; rebuild with `make medaka`")))) (DoExpr (EIf (EBinOp "/=" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_STRICT"))) (ELit (LString ""))) (ELit (LString ""))) (EApp (EVar "dieMsg") (EVar "msg")) (EIf (EApp (EVar "runJsonInvocation") (EVar "argv")) (EApp (EApp (EVar "setRef") (EVar "pendingStaleNotice")) (EApp (EVar "Some") (EVar "msg"))) (EApp (EVar "ePutStrLn") (EVar "msg")))))))))
(DTypeSig false "loadCheckPrelude" (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "loadCheckPrelude" ((PVar "prelude")) (EBlock (DoLet false false (PVar "verdict") (EApp (EVar "loadPreludeInterface") (EVar "prelude"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "reportStaleLine") (EVar "dieMsg")) (EVar "None")) (EApp (EApp (EVar "staleLine") (EVar "InterfaceFile")) (EVar "verdict")))) (DoExpr (EApp (EApp (EApp (EVar "reportDecls") (EVar "None")) (EVar "dieMsg")) (EVar "prelude")))))
(DTypeSig false "seedCheckPrelude" (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "seedCheckPrelude" ((PVar "prelude")) (EBlock (DoLet false false PWild (EApp (EVar "loadPreludeInterface") (EVar "prelude"))) (DoExpr (ELit LUnit))))
(DTypeSig false "reportTrees" (TyFun (TyApp (TyCon "Option") (TyFun (TyCon "String") (TyCon "Unit"))) (TyFun (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))) (TyFun (TyCon "FileVerdict") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "reportTrees" ((PVar "staging") (PVar "stop") (PVar "verdict")) (EApp (EApp (EApp (EVar "reportStaleLine") (EVar "stop")) (EVar "staging")) (EApp (EApp (EVar "staleLine") (EVar "TreesFile")) (EVar "verdict"))))
(DTypeSig false "reportDecls" (TyFun (TyApp (TyCon "Option") (TyFun (TyCon "String") (TyCon "Unit"))) (TyFun (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))) (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "reportDecls" ((PVar "staging") (PVar "stop") (PVar "prelude")) (EApp (EApp (EApp (EVar "reportStaleLine") (EVar "stop")) (EVar "staging")) (EApp (EApp (EVar "staleLine") (EVar "DeclsFile")) (EApp (EVar "preludeDeclsVerdict") (EVar "prelude")))))
(DTypeSig false "deferredInto" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "deferredInto" ((PCon "False") PWild) (EVar "None"))
(DFunDef false "deferredInto" ((PCon "True") (PVar "field")) (EApp (EVar "Some") (ELam ((PVar "msg")) (EApp (EApp (EVar "setRef") (EVar "pendingPreludeNotices")) (EBinOp "++" (EUnOp "!" (EVar "pendingPreludeNotices")) (EListLit (ETuple (EVar "field") (EVar "msg"))))))))
(DTypeSig false "unstaged" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "unstaged" (PWild) (EVar "None"))
(DTypeSig false "takeShippedPrelude" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyFun (TyCon "String") (TyCon "Unit")))) (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "takeShippedPrelude" ((PVar "stagingFor") (PVar "prelude")) (EBlock (DoLet false false PWild (EApp (EVar "loadPreludeInterface") (EVar "prelude"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "reportTrees") (EApp (EVar "stagingFor") (ELit (LString "stalePreludeTrees")))) (EVar "runAbort")) (EApp (EVar "loadPreludeElab") (EVar "prelude")))) (DoExpr (EApp (EApp (EApp (EVar "reportDecls") (EApp (EVar "stagingFor") (ELit (LString "stalePreludeDecls")))) (EVar "runAbort")) (EVar "prelude")))))
(DTypeSig false "reportShippedHeaders" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyFun (TyCon "String") (TyCon "Unit")))) (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "reportShippedHeaders" ((PVar "stagingFor") (PVar "prelude")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "reportTrees") (EApp (EVar "stagingFor") (ELit (LString "stalePreludeTrees")))) (EVar "runAbort")) (EApp (EVar "checkPreludeElab") (EVar "prelude")))) (DoExpr (EApp (EApp (EApp (EVar "reportDecls") (EApp (EVar "stagingFor") (ELit (LString "stalePreludeDecls")))) (EVar "runAbort")) (EVar "prelude")))))
(DTypeSig false "reportChildTrees" (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "reportChildTrees" ((PVar "prelude")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "reportTrees") (EVar "None")) (EVar "dieMsg")) (EApp (EVar "checkPreludeElab") (EVar "prelude")))) (DoExpr (EApp (EApp (EApp (EVar "reportDecls") (EVar "None")) (EVar "dieMsg")) (EVar "prelude")))))
(DTypeSig false "runJsonInvocation" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "runJsonInvocation" ((PCons (PLit (LString "run")) (PVar "rest"))) (EApp (EApp (EVar "runFlagGiven") (ELit (LString "--json"))) (EVar "rest")))
(DFunDef false "runJsonInvocation" (PWild) (EVar "False"))
(DTypeSig false "flushStaleNoticeProse" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "flushStaleNoticeProse" (PWild) (EBlock (DoLet false false PWild (EMatch (EUnOp "!" (EVar "pendingStaleNotice")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "msg")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "pendingStaleNotice")) (EVar "None"))) (DoExpr (EApp (EVar "ePutStrLn") (EVar "msg"))))))) (DoLet false false (PVar "notices") (EUnOp "!" (EVar "pendingPreludeNotices"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "pendingPreludeNotices")) (EListLit))) (DoExpr (EApp (EVar "emitWarningLines") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "notices"))))))
(DTypeSig false "dieMsg" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "dieMsg" ((PVar "msg")) (EBlock (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))
(DTypeSig false "runAbort" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runAbort" ((PVar "msg")) (EBlock (DoLet false false PWild (EApp (EVar "flushStaleNoticeProse") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "flushPerfSinkProse") (ELit LUnit))) (DoExpr (EApp (EVar "dieMsg") (EVar "msg")))))
(DTypeSig false "orExit" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")) (TyEffect ("IO") None (TyVar "a"))))
(DFunDef false "orExit" ((PCon "Ok" (PVar "v"))) (EVar "v"))
(DFunDef false "orExit" ((PCon "Err" (PVar "msg"))) (EBlock (DoLet false false PWild (EApp (EVar "runAbort") (EVar "msg"))) (DoExpr (EApp (EVar "panic") (EVar "msg")))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false PWild (EApp (EVar "stageCountInit") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "checkSourceStaleness") (EApp (EVar "args") (ELit LUnit)))) (DoLet false false PWild (EApp (EVar "runCli") (ELit LUnit))) (DoExpr (EApp (EVar "stageDump") (ELit LUnit)))))
(DTypeSig false "runCli" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCli" (PWild) (EMatch (EApp (EVar "args") (ELit LUnit)) (arm (PList) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "-h")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "-v")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "check")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "checkHelpText")) (EVar "runCheckCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "fmt")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "fmtHelpText")) (EVar "runFmtCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "new")) (PVar "rest")) () (EApp (EVar "runNewCmd") (EVar "rest"))) (arm (PCons (PLit (LString "build")) (PVar "rest")) () (EApp (EVar "runBuildCmd") (EVar "rest"))) (arm (PCons (PLit (LString "run")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "runHelpText")) (EVar "runRunCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "test")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "testHelpText")) (EVar "runTestCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "snapshot")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "snapshotHelpText")) (EVar "runSnapshotCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "doc")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "docHelpText")) (EVar "runDocCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "lint")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "lintHelpText")) (EVar "runLintCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "codemod")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "codemodHelpText")) (EVar "runCodemodCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "check-policy")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "checkPolicyHelpText")) (EVar "runCheckPolicyCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "manifest")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "manifestHelpText")) (EVar "runManifestCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "gate")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "gateHelpText")) (EVar "runGateCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "interface")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "interfaceHelpText")) (EVar "runInterfaceCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "repl")) (PVar "rest")) () (EApp (EVar "runReplCmd") (EVar "rest"))) (arm (PCons (PLit (LString "lsp")) (PVar "rest")) () (EApp (EVar "runLspCmd") (EVar "rest"))) (arm (PCons (PLit (LString "mcp")) (PVar "rest")) () (EApp (EVar "runMcpCmd") (EVar "rest"))) (arm (PCons (PVar "sub") PWild) () (EApp (EVar "unknownSubcommand") (EVar "sub")))))
(DTypeSig false "dispatchSub" (TyFun (TyCon "String") (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "dispatchSub" ((PVar "help") PWild (PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "flushStaleNoticeProse") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "help"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "dispatchSub" ((PVar "help") PWild (PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "flushStaleNoticeProse") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "help"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "dispatchSub" (PWild (PVar "run") (PVar "rest")) (EApp (EVar "run") (EVar "rest")))
(DTypeSig false "usage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "usage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka. A functional language compiler\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka                    Show this message\n")) (ELit (LString "  medaka run [--json] [--allow-internal] [--release] <file.mdk | -> [args...]   Type-check and run a program\n")) (ELit (LString "  medaka build <file.mdk> [-o <out>] [--keep-ir]  Compile to a native binary (LLVM + clang)\n")) (ELit (LString "  medaka check [--json] [--types] [--allow-internal] <file.mdk>    Type-check without running\n")) (ELit (LString "  medaka test [--native | --engines eval,native] [--filter <substring>] [--seed <n>] [--cases <n>] [file.mdk]    Run doctests + prop tests (--native runs doctests through a compiled native binary INSTEAD of the interpreter; --engines runs the listed set, exit is the AND)\n")) (ELit (LString "  medaka doc <file.mdk>     Generate Markdown documentation (one file; required)\n")) (ELit (LString "  medaka lint [paths...]    Lint files/dirs (style rules; --fix, --cache, --disable/--only/--deny=<rules,...>)\n")) (ELit (LString "  medaka codemod <name> [flags] [paths...]  Apply a named source-preserving AST transform (--write/--stdout)\n")) (ELit (LString "  medaka snapshot [--check|--new|--bless] [paths...]  Per-stage snapshot tests (--out <dir>, --stages <a,b,..>)\n")) (ELit (LString "  medaka fmt [paths...]     Report unformatted files (default; use --write to rewrite in place)\n")) (ELit (LString "  medaka new <name>         Scaffold a new project directory\n")) (ELit (LString "  medaka repl               Start an interactive REPL (reads stdin until EOF or :quit)\n")) (ELit (LString "  medaka lsp                Run the language server over stdio\n")) (ELit (LString "  medaka mcp                Run the MCP server over stdio (JSON-RPC for agents)\n")) (ELit (LString "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]  Check a plugin's inferred effects against an allow-list\n")) (ELit (LString "  medaka manifest <file.mdk> [--fn name]  Emit the verified capability manifest as TOML\n")) (ELit (LString "  medaka gate list [<selector>...] [--json]  Query the gate registry (test/gates.toml)\n")) (ELit (LString "  medaka gate run [<selector>...] [--dry-run]  Run the selected gates\n")) (ELit (LString "  medaka interface write|verify <module.mdk>, show <file.mdki>  Write, show or verify the prelude interface file\n")) (ELit (LString "  medaka help               Show this message\n")) (ELit (LString "  medaka --version          Show the compiler version\n"))))))
(DTypeSig false "unknownSubcommand" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "unknownSubcommand" ((PVar "sub")) (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka: unknown subcommand `")) (EApp (EVar "display") (EVar "sub"))) (ELit (LString "`; run `medaka help` for the list of subcommands")))))
(DTypeSig false "cliStdlibExportsEnv" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "cliStdlibExportsEnv" ((PVar "names")) (EApp (EApp (EVar "cliStdlibExports") (EBinOp "++" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot")) (ELit (LString "/stdlib")))) (EVar "names")))
(DTypeSig false "checkHelpText" (TyCon "String"))
(DFunDef false "checkHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka check — Type-check a file without running it\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka check [--json] [--types] [--allow-internal] <file.mdk>\n")) (ELit (LString "\n")) (ELit (LString "  --json            emit the {\"files\":[...]} structured-diagnostics\n")) (ELit (LString "                    envelope instead of human text\n")) (ELit (LString "  --types           show the full inferred-scheme dump, prelude included\n")) (ELit (LString "                    (default: only your own top-level bindings; no effect\n")) (ELit (LString "                    under --json — the envelope carries diagnostics, not\n")) (ELit (LString "                    scheme dumps)\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")) (ELit (LString "  --target <name>   refuse a program whose `main` performs a label this\n")) (ELit (LString "                    target profile does not grant (default: [target] in\n")) (ELit (LString "                    medaka.toml, else no target check)\n")))))
(DTypeSig false "checkArgSpec" (TyCon "ArgSpec"))
(DFunDef false "checkArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "check"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the structured-diagnostics envelope"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--types")))) (ELit (LString "show the full inferred-scheme dump"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--allow-internal")))) (ELit (LString "permit internal-only externs outside stdlib/"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--target")))) (ELit (LString "NAME"))) (ELit (LString "target profile `main` must fit")))))))
(DTypeSig false "runCheckCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "checkArgSpec")) (EVar "argv"))) (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false (PVar "perfT0") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a"))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "flag") (ELit (LString "--allow-internal"))) (EVar "a"))) (DoLet false false (PVar "typesMode") (EApp (EApp (EVar "flag") (ELit (LString "--types"))) (EVar "a"))) (DoExpr (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList (PVar "target")) () (EBlock (DoExpr (EApp (EVar "perfArm") (EVar "perfT0"))) (DoExpr (EApp (EApp (EVar "carryTargetProfile") (EApp (EApp (EVar "lastValue") (ELit (LString "--target"))) (EVar "a"))) (EVar "target"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readPreludeSources") (EVar "stdlibDir")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "prelude")) () (EBlock (DoLet false false (PVar "rsrc") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (DoLet false false (PVar "csrc") (EFieldAccess (EVar "prelude") "pnCoreSrc")) (DoLet false false PWild (EApp (EVar "loadCheckPrelude") (EVar "prelude"))) (DoExpr (EIf (EVar "jsonMode") (EBlock (DoLet false false PWild (EIf (EVar "typesMode") (EApp (EVar "ePutStrLn") (ELit (LString "medaka check: --types has no effect under --json; the envelope carries no scheme dump"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "runCheckJsonCmd") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir")))) (EMatch (EApp (EVar "readSource") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "dieMsg") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EVar "map") (EVar "dropPathTriple")) (EVar "modsWithPath"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PVar "inputs") (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "flatStdlib")) (EVar "ownedStdlib"))) (DoLet false false (PVar "perfTLoad") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "load"))) (EBinOp "-" (EVar "perfTLoad") (EVar "perfT0"))) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkRoute") (EVar "inputs")) (EVar "typesMode")) (EVar "allowInternal")) (EVar "trusted")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "modsWithPath"))) (DoLet false false (PVar "perfTCheck") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "check"))) (EBinOp "-" (EVar "perfTCheck") (EVar "perfTLoad"))) (EVar "target"))) (DoExpr (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTCheck") (EVar "perfT0"))))))))))))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check [--json] [--types] [--allow-internal] [--target <profile>] <file.mdk>")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))))
(DTypeSig false "locatedProjectDiags" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Int")))))
(DFunDef false "locatedProjectDiags" ((PVar "results")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "readDiagSrc")) (EVar "results"))) (DoExpr (ETuple (EApp (EVar "joinedOrNone") (EApp (EApp (EVar "flatMap") (EVar "renderTripleErrors")) (EVar "triples"))) (EApp (EApp (EVar "map") (EVar "cohWarnsOfTriple")) (EVar "triples")) (EApp (EVar "length") (EApp (EApp (EVar "flatMap") (EVar "hiddenWarnsOfTriple")) (EApp (EVar "dropEntryTriple") (EVar "triples"))))))))
(DTypeSig false "relDiagTriple" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "relDiagTriple" ((PVar "root") (PTuple (PVar "path") (PVar "src") (PVar "diags"))) (ETuple (EApp (EApp (EVar "relDiagPath") (EVar "root")) (EVar "path")) (EVar "src") (EVar "diags")))
(DTypeSig false "hiddenWarnsOfTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "Diag"))))
(DFunDef false "hiddenWarnsOfTriple" ((PTuple PWild PWild (PVar "diags"))) (EApp (EApp (EVar "filter") (EVar "isHiddenNonEntryWarn")) (EVar "diags")))
(DTypeSig false "isHiddenNonEntryWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isHiddenNonEntryWarn" ((PVar "d")) (EBinOp "&&" (EApp (EVar "diagIsWarn") (EVar "d")) (EApp (EVar "not") (EApp (EVar "isCoherenceWarn") (EVar "d")))))
(DTypeSig false "runAbortJson" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runAbortJson" ((PVar "triples")) (EBlock (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "pendingRunDiags")) (EApp (EVar "nonEmptyTriples") (EVar "triples")))) (DoLet false false PWild (EApp (EVar "flushPendingRunDiags") (EVar "True"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))
(DTypeSig false "resolveErrorJsonTriples" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "resolveErrorJsonTriples" ((PList)) (EListLit))
(DFunDef false "resolveErrorJsonTriples" ((PCons (PTuple PWild (PList)) (PVar "rest"))) (EApp (EVar "resolveErrorJsonTriples") (EVar "rest")))
(DFunDef false "resolveErrorJsonTriples" ((PCons (PTuple (PVar "file") (PVar "diags")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "file") (EApp (EVar "readFileSafe") (EVar "file")) (EVar "diags")) (EApp (EVar "resolveErrorJsonTriples") (EVar "rest"))))
(DTypeSig false "genericResidualDiag" (TyFun (TyCon "String") (TyCon "Diag")))
(DFunDef false "genericResidualDiag" ((PVar "target")) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "TResidual")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type error in ")) (EVar "target")) (ELit (LString ", detected during elaboration; no located diagnostic is available,"))) (ELit (LString " and `medaka check` may not report it")))) (EVar "None")))
(DTypeSig false "residualJsonTriples" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))
(DFunDef false "residualJsonTriples" ((PVar "entryFile") PWild (PList)) (EListLit (ETuple (EVar "entryFile") (EApp (EVar "readFileSafe") (EVar "entryFile")) (EListLit (EApp (EVar "genericResidualDiag") (EVar "entryFile"))))))
(DFunDef false "residualJsonTriples" ((PVar "entryFile") (PVar "pathMap") (PCons (PTuple (PVar "mid") (PVar "d")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "pathMap")) (arm (PCon "Some" (PVar "file")) () (EBinOp "::" (ETuple (EVar "file") (EApp (EVar "readFileSafe") (EVar "file")) (EListLit (EApp (EVar "diagOfTypeError") (EVar "d")))) (EApp (EApp (EApp (EVar "residualJsonTriples") (EVar "entryFile")) (EVar "pathMap")) (EVar "rest")))) (arm (PCon "None") () (EBinOp "::" (ETuple (EVar "entryFile") (EApp (EVar "readFileSafe") (EVar "entryFile")) (EListLit (EApp (EVar "diagOfTypeError") (EVar "d")))) (EApp (EApp (EApp (EVar "residualJsonTriples") (EVar "entryFile")) (EVar "pathMap")) (EVar "rest"))))))
(DTypeSig false "checkRoute" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Unit")))))))))))))
(DFunDef false "checkRoute" ((PVar "inputs") (PVar "typesMode") (PVar "allowInternal") (PVar "trusted") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "modsWithPath")) (EBlock (DoLet false false (PVar "program") (EMatch (EVar "modsWithPath") (arm (PList (PVar "m")) () (EApp (EVar "FrontFile") (EVar "m"))) (arm PWild () (EApp (EApp (EVar "FrontGraph") (EVar "modsWithPath")) (EApp (EVar "desugaredModPairs") (EVar "modsWithPath")))))) (DoLet false false (PVar "front") (EApp (EApp (EApp (EVar "frontEnd") (EVar "cliStdlibExportsEnv")) (EApp (EApp (EVar "checkFrontDrive") (EVar "target")) (EVar "roots"))) (ERecordCreate "FrontInput" ((fa "fiInputs" (EVar "inputs")) (fa "fiAllowInternal" (EVar "allowInternal")) (fa "fiTrusted" (EVar "trusted")) (fa "fiRuntimeSrc" (EVar "rsrc")) (fa "fiCoreSrc" (EVar "csrc")) (fa "fiPolicy" (EVar "NeverDriveRejected")) (fa "fiProgram" (EVar "program")))))) (DoExpr (EMatch (EVar "program") (arm (PCon "FrontFile" (PTuple PWild PWild (PVar "decls"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkFileReport") (EVar "typesMode")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "decls")) (EVar "front"))) (arm (PCon "FrontGraph" (PVar "mods") (PVar "modPairs")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkProjectReport") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "mods")) (EVar "modPairs")) (EVar "front")))))))
(DTypeSig false "checkFileReport" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "FrontOutput") (TyCon "CheckDump")) (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "checkFileReport" ((PVar "typesMode") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "decls") (PVar "front")) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EFieldAccess (EVar "front") "foDiags"))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "diagIsError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false (PVar "warns") (EApp (EApp (EVar "filter") (EVar "diagIsWarn")) (EVar "diags"))) (DoLet false false (PVar "dumpLines") (EMatch (EFieldAccess (EVar "front") "foDriven") (arm (PCon "Some" (PVar "d")) () (EFieldAccess (EVar "d") "cdLines")) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "dump") (EApp (EVar "stripWarningLines") (EApp (EVar "joinNl") (EVar "dumpLines")))) (DoLet false false (PVar "filtered") (EApp (EApp (EVar "userSchemeLines") (EVar "decls")) (EVar "dump"))) (DoLet false false (PVar "report") (EIf (EVar "typesMode") (EVar "dump") (EVar "filtered"))) (DoLet false false PWild (EMatch (EFieldAccess (EVar "front") "foDriven") (arm (PCon "Some" (PVar "d")) () (EApp (EApp (EApp (EApp (EApp (EVar "checkTargetGate") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EFieldAccess (EVar "d") "cdDrive"))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "report"))) (DoLet false false PWild (EIf (EVar "typesMode") (ELit LUnit) (EApp (EVar "putStrLn") (EApp (EApp (EVar "checkOkLine") (EVar "target")) (EVar "filtered"))))) (DoLet false false (PVar "mainWarns") (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EListLit)) (EListLit)) (EListLit)) (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EBinOp "++" (EVar "warns") (EVar "mainWarns")))) (DoExpr (ELit LUnit)))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))))
(DTypeSig false "checkProjectReport" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "FrontOutput") (TyCon "CheckDump")) (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "checkProjectReport" ((PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods") (PVar "modPairs") (PVar "front")) (EMatch (EFieldAccess (EVar "front") "foDriven") (arm (PCon "None") () (EApp (EVar "dieMsg") (EApp (EVar "ppDiagBuckets") (EFieldAccess (EVar "front") "foDiags")))) (arm (PCon "Some" (PVar "dump")) () (EBlock (DoLet false false (PVar "exWarns") (EApp (EApp (EApp (EVar "entryExhaust") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "modPairs"))) (DoExpr (EMatch (EApp (EVar "locatedProjectDiags") (EFieldAccess (EVar "front") "foDiags")) (arm (PTuple (PCon "Some" (PVar "errText")) PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "errText"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PTuple (PCon "None") (PVar "projWarns") (PVar "hiddenCount")) () (EBlock (DoLet false false (PVar "report") (EApp (EApp (EVar "checkModulesReport") (EVar "exWarns")) (EFieldAccess (EFieldAccess (EVar "front") "foReport") "trDiagnostics"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "checkTargetGate") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EFieldAccess (EVar "dump") "cdDrive"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "report"))) (DoLet false false PWild (EApp (EVar "emitWarningLines") (EApp (EApp (EVar "flatMap") (EVar "renderTripleWarnings")) (EApp (EVar "trimEntryTriple") (EVar "projWarns"))))) (DoLet false false PWild (EApp (EVar "emitHiddenDiagNote") (EVar "hiddenCount"))) (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EApp (EApp (EVar "map") (EVar "dropPathTriple")) (EVar "mods"))) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EListLit)) (EListLit)) (EListLit)) (EVar "edecls"))) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EVar "mainWarns")))))))))))
(DTypeSig false "lastModPair" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lastModPair" ((PList)) (EVar "None"))
(DFunDef false "lastModPair" ((PList (PVar "p"))) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "lastModPair" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModPair") (EVar "rest")))
(DTypeSig false "checkTargetGate" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CheckDrive") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "checkTargetGate" ((PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "drive")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "checkTargetRefusal") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EFieldAccess (EVar "drive") "cdPaths")) (EVar "drive")) (arm (PList) () (ELit LUnit)) (arm (PVar "ds") () (EBlock (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppTargetDiag") (EVar "target")) (EVar "tsrc"))) (EVar "ds"))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))
(DTypeSig false "checkTargetRefusal" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CheckDrive") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Diag")))))))))
(DFunDef false "checkTargetRefusal" ((PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "paths") (PVar "drive")) (EMatch (EUnOp "!" (EVar "selectedProfile")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "profile")) () (EApp (EApp (EApp (EApp (EVar "targetRefusal") (EVar "profile")) (EVar "target")) (EVar "paths")) (EApp (EApp (EApp (EVar "checkTargetInputs") (EVar "rsrc")) (EVar "csrc")) (EVar "drive"))))))
(DTypeSig false "checkTargetInputs" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CheckDrive") (TyCon "TargetInputs")))))
(DFunDef false "checkTargetInputs" ((PVar "rsrc") (PVar "csrc") (PVar "drive")) (EBlock (DoLet false false (PVar "core") (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (DoLet false false (PVar "printed") (EIf (EApp (EApp (EApp (EVar "shouldAutoPrintMain") (EFieldAccess (EFieldAccess (EVar "drive") "cdOutputs") "doEntryOutcome")) (EVar "core")) (EFieldAccess (EVar "drive") "cdMods")) (EApp (EApp (EVar "lookupAssoc") (ELit (LString "println"))) (EFieldAccess (EVar "drive") "cdCoreSchemes")) (EVar "None"))) (DoExpr (ERecordCreate "TargetInputs" ((fa "tiSchemes" (EBinOp "++" (EFieldAccess (EVar "drive") "cdEntrySchemes") (EFieldAccess (EVar "drive") "cdCoreSchemes"))) (fa "tiEntryDecls" (EMatch (EApp (EVar "lastModPair") (EFieldAccess (EVar "drive") "cdMods")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EVar "decls")) (arm (PCon "None") () (EListLit)))) (fa "tiAutoPrintCall" (EVar "printed")) (fa "tiCore" (EVar "core")) (fa "tiModules" (EFieldAccess (EVar "drive") "cdMods")) (fa "tiRuntime" (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (fa "tiOutputs" (EFieldAccess (EVar "drive") "cdOutputs")) (fa "tiStdlibOwned" (EListLit)))))))
(DTypeSig false "checkTargetJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CheckJson") (TyFun (TyApp (TyCon "Option") (TyCon "CheckDrive")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "CheckJson"))))))))))
(DFunDef false "checkTargetJson" ((PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir") (PVar "cj") (PVar "drive")) (EMatch (EUnOp "!" (EVar "selectedProfile")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" PWild) () (EMatch (EVar "drive") (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "check --json --target: a clean check left no drive to judge")))) (arm (PCon "Some" (PVar "dr")) () (EBlock (DoLet false false (PVar "paths") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "mid") (PVar "path"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EVar "reportKey") (EVar "stdlibDir")) (EVar "cj")) (EVar "path"))))) (EFieldAccess (EVar "dr") "cdPaths"))) (DoExpr (EMatch (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "checkTargetRefusal") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "paths")) (EVar "dr")) (EVar "cj")) (arm (PTuple (PList) PWild) () (EVar "None")) (arm (PTuple (PVar "ds") (PCon "CjParts" (PVar "entry") (PVar "triples"))) () (EApp (EVar "Some") (EApp (EApp (EVar "CjParts") (EVar "entry")) (EApp (EApp (EApp (EApp (EVar "foldTargetDiags") (EVar "entry")) (EApp (EVar "readFileSafe") (EVar "entry"))) (EVar "ds")) (EVar "triples"))))) (arm PWild () (EVar "None"))))))))))
(DTypeSig false "reportKey" (TyFun (TyCon "String") (TyFun (TyCon "CheckJson") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "reportKey" ((PVar "stdlibDir") (PCon "CjParts" PWild (PVar "triples")) (PVar "path")) (EIf (EApp (EApp (EVar "any") (ELam ((PTuple (PVar "p") PWild PWild)) (EBinOp "==" (EVar "p") (EVar "path")))) (EVar "triples")) (EVar "path") (EApp (EApp (EVar "relDiagPath") (EApp (EVar "dirOf2") (EVar "stdlibDir"))) (EVar "path"))))
(DFunDef false "reportKey" (PWild PWild (PVar "path")) (EVar "path"))
(DTypeSig false "runTargetGate" (TyFun (TyCon "Bool") (TyFun (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "EntryAnalysis") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "runTargetGate" ((PVar "jsonMode") (PVar "rel") (PVar "target") (PVar "pathMap") (PVar "mods") (PVar "analysis")) (EBlock (DoLet false false (PVar "startable") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EApp (EVar "isNone") (EApp (EVar "mainEntryError") (EVar "edecls")))) (arm (PCon "None") () (EVar "False")))) (DoLet false false (PVar "refusal") (EIf (EVar "startable") (EApp (EApp (EApp (EApp (EVar "targetRefusal") (EApp (EVar "runProfile") (EUnOp "!" (EVar "selectedProfile")))) (EVar "target")) (EVar "pathMap")) (EFieldAccess (EVar "analysis") "eaTarget")) (EListLit))) (DoExpr (EMatch (EVar "refusal") (arm (PList) () (ELit LUnit)) (arm (PVar "ds") () (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "target"))) (DoExpr (EMatch (EVar "jsonMode") (arm (PCon "True") () (EApp (EVar "runAbortJson") (EApp (EApp (EVar "map") (EVar "rel")) (EApp (EApp (EApp (EApp (EVar "foldTargetDiags") (EVar "target")) (EVar "src")) (EVar "ds")) (EListLit))))) (arm (PCon "False") () (EApp (EVar "runAbort") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppTargetDiag") (EVar "target")) (EVar "src"))) (EVar "ds")))))))))))))
(DTypeSig false "runArgvFilter" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "runArgvFilter" ((PList)) (EListLit))
(DFunDef false "runArgvFilter" ((PCons (PLit (LString "--json")) (PVar "rest"))) (EApp (EVar "runArgvFilter") (EVar "rest")))
(DFunDef false "runArgvFilter" ((PCons (PLit (LString "--release")) (PVar "rest"))) (EApp (EVar "runArgvFilter") (EVar "rest")))
(DFunDef false "runArgvFilter" ((PCons (PLit (LString "--allow-internal")) (PVar "rest"))) (EApp (EVar "runArgvFilter") (EVar "rest")))
(DFunDef false "runArgvFilter" ((PCons (PLit (LString "--types")) (PVar "rest"))) (EApp (EVar "runArgvFilter") (EVar "rest")))
(DFunDef false "runArgvFilter" ((PCons (PLit (LString "--target")) (PCons PWild (PVar "rest")))) (EApp (EVar "runArgvFilter") (EVar "rest")))
(DFunDef false "runArgvFilter" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--target="))) (EVar "x")) (EApp (EVar "runArgvFilter") (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "runArgvFilter" ((PVar "argv")) (EVar "argv"))
(DTypeSig false "runTargetFlag" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "runTargetFlag" ((PVar "argv")) (EApp (EApp (EVar "runTargetGo") (EVar "None")) (EVar "argv")))
(DTypeSig false "runTargetGo" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "runTargetGo" (PWild (PCons (PLit (LString "--target")) (PCons (PVar "v") (PVar "rest")))) (EApp (EApp (EVar "runTargetGo") (EApp (EVar "Some") (EVar "v"))) (EVar "rest")))
(DFunDef false "runTargetGo" ((PVar "acc") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--target="))) (EVar "x")) (EApp (EApp (EVar "runTargetGo") (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 9))) (EApp (EVar "stringLength") (EVar "x"))) (EVar "x")))) (EVar "rest")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "x") (ELit (LString "--json"))) (EBinOp "==" (EVar "x") (ELit (LString "--release")))) (EBinOp "==" (EVar "x") (ELit (LString "--allow-internal")))) (EBinOp "==" (EVar "x") (ELit (LString "--types")))) (EApp (EApp (EVar "runTargetGo") (EVar "acc")) (EVar "rest")) (EIf (EVar "otherwise") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "runTargetGo" ((PVar "acc") (PList)) (EVar "acc"))
(DTypeSig false "carryTargetProfile" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "carryTargetProfile" ((PVar "flagValue") (PVar "entry")) (EMatch (EApp (EApp (EVar "carryProjectProfile") (EVar "flagValue")) (EVar "entry")) (arm (PCon "Ok" PWild) () (ELit LUnit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "dieMsg") (EBinOp "++" (ELit (LString "error: ")) (EVar "m"))))))
(DTypeSig false "runFlagGiven" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "runFlagGiven" (PWild (PList)) (EVar "False"))
(DFunDef false "runFlagGiven" ((PVar "nm") (PCons (PLit (LString "--target")) (PCons PWild (PVar "rest")))) (EApp (EApp (EVar "runFlagGiven") (EVar "nm")) (EVar "rest")))
(DFunDef false "runFlagGiven" ((PVar "nm") (PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "x") (ELit (LString "--json"))) (EBinOp "==" (EVar "x") (ELit (LString "--release")))) (EBinOp "==" (EVar "x") (ELit (LString "--allow-internal")))) (EBinOp "==" (EVar "x") (ELit (LString "--types")))) (EApp (EApp (EVar "startsWith") (ELit (LString "--target="))) (EVar "x"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "nm")) (EApp (EApp (EVar "runFlagGiven") (EVar "nm")) (EVar "rest"))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "requireArgs" (TyFun (TyCon "ArgSpec") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Args")))))
(DFunDef false "requireArgs" ((PVar "sp") (PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "sp")) (EVar "argv")) (arm (PCon "Ok" (PVar "a")) () (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoLet false false PWild (EApp (EVar "stageExit") (EVar "usageExitCode"))) (DoExpr (ERecordCreate "Args" ((fa "given" (EListLit)) (fa "positionals" (EListLit)) (fa "rest" (EListLit)))))))))
(DTypeSig false "runCheckJsonCmd" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "runCheckJsonCmd" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir")) (EMatch (EApp (EVar "readSourceE") (EVar "target")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "cjSourceReadJson") (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PTuple (PVar "cj") (PVar "hasErr") (PVar "drive")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFileParts") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir"))) (DoLet false false (PVar "refused") (EIf (EVar "hasErr") (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkTargetJson") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "cj")) (EVar "drive")))) (DoExpr (EMatch (EVar "refused") (arm (PCon "Some" (PVar "refusedCj")) () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EVar "ppCheckJson") (EVar "refusedCj")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EVar "ppCheckJson") (EVar "cj")))) (DoExpr (EIf (EVar "hasErr") (EApp (EVar "stageExit") (ELit (LInt 1))) (ELit LUnit)))))))))))
(DTypeSig false "cjBuildFailedJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "cjBuildFailedJson" ((PVar "target") (PVar "msg")) (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "target") (ELit (LString "")) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "Coded") (EVar "RBuildFailed"))) (EVar "msg")) (EVar "None")) (EVar "None")) (EVar "None")))))))
(DTypeSig false "runBuildJsonCmd" (TyFun (TyCon "Args") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "runBuildJsonCmd" ((PVar "a") (PVar "allowInternal") (PVar "root") (PVar "stdlibDir") (PVar "input") (PVar "outOpt") (PVar "target")) (EMatch (EApp (EVar "readSourceE") (EVar "input")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "cjSourceReadJson") (EVar "input")) (EVar "e")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "entrySrc")) () (EMatch (EApp (EVar "readPreludeSources") (EVar "stdlibDir")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "cjBuildFailedJson") (EVar "input")) (EVar "msg")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "prelude")) () (EBlock (DoLet false false (PVar "notices") (EApp (EApp (EVar "jsonPreludeNotices") (EVar "target")) (EVar "prelude"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "keepIrCli") (EApp (EApp (EVar "flag") (ELit (LString "--keep-ir"))) (EVar "a"))) (DoLet false false (PVar "stampBuild") (EApp (EApp (EVar "flag") (ELit (LString "--stamp-build"))) (EVar "a"))) (DoLet false false (PVar "outPath") (EMatch (EVar "outOpt") (arm (PCon "Some" (PVar "o")) () (EVar "o")) (arm (PCon "None") () (EApp (EApp (EVar "defaultOutPath") (EVar "target")) (EVar "input"))))) (DoLet false false (PVar "ask") (ERecordCreate "GateAsk" ((fa "askAllowInternal" (EVar "allowInternal")) (fa "askDiagJson" (EVar "True"))))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuild") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "target")) (EVar "input")) (EVar "outPath")) (EVar "keepIrCli")) (EVar "True")) (EVar "stampBuild")) (EApp (EVar "Some") (EVar "ask"))) (arm (PCon "Ok" (PVar "rep")) () (EMatch (EFieldAccess (EVar "rep") "diagEnvelope") (arm (PCon "Some" (PTuple (PVar "entry") (PVar "envelope"))) () (EApp (EVar "println") (EApp (EApp (EVar "withPreludeFields") (EVar "notices")) (EApp (EApp (EApp (EVar "envelopeWithNotes") (EVar "entry")) (EFieldAccess (EVar "rep") "notes")) (EVar "envelope"))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "withPreludeFields") (EVar "notices")) (EApp (EApp (EVar "cjBuildFailedJson") (EVar "input")) (ELit (LString "error: the emitter wrote no diagnostics envelope; an emitter built from an older medaka does not write one")))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))))) (arm (PCon "Err" (PVar "rep")) () (EMatch (EFieldAccess (EVar "rep") "diagEnvelope") (arm (PCon "Some" (PTuple PWild (PVar "envelope"))) () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "withPreludeFields") (EVar "notices")) (EVar "envelope")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "withPreludeFields") (EVar "notices")) (EApp (EApp (EVar "cjBuildFailedJson") (EVar "input")) (EApp (EVar "ppBuildReport") (EVar "rep")))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))))))))))
(DTypeSig false "jsonPreludeNotices" (TyFun (TyCon "BuildTarget") (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "jsonPreludeNotices" ((PVar "target") (PVar "prelude")) (EBlock (DoLet false false (PVar "staged") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "stage") (ELam ((PVar "field")) (EApp (EVar "Some") (ELam ((PVar "msg")) (EApp (EApp (EVar "setRef") (EVar "staged")) (EBinOp "++" (EFieldAccess (EVar "staged") "value") (EListLit (ETuple (EVar "field") (EVar "msg"))))))))) (DoLet false false (PVar "trees") (EMatch (EVar "target") (arm (PCon "TNative") () (EApp (EApp (EVar "staleLine") (EVar "TreesFile")) (EApp (EVar "checkPreludeElab") (EVar "prelude")))) (arm (PCon "TWasm") () (EVar "None")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "reportStaleLine") (EVar "dieMsg")) (EApp (EVar "stage") (ELit (LString "stalePreludeTrees")))) (EVar "trees"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "reportStaleLine") (EVar "dieMsg")) (EApp (EVar "stage") (ELit (LString "stalePreludeDecls")))) (EApp (EApp (EVar "staleLine") (EVar "DeclsFile")) (EApp (EVar "preludeDeclsVerdict") (EVar "prelude"))))) (DoExpr (EFieldAccess (EVar "staged") "value"))))
(DTypeSig false "withPreludeFields" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "withPreludeFields" ((PList) (PVar "envelope")) (EVar "envelope"))
(DFunDef false "withPreludeFields" ((PVar "notices") (PVar "envelope")) (EMatch (EApp (EVar "parseJson") (EVar "envelope")) (arm (PCon "Ok" (PCon "JObject" (PVar "pairs"))) () (EApp (EVar "stringify") (EApp (EVar "jObject") (EBinOp "++" (EApp (EVar "toList") (EVar "pairs")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "field") (PVar "msg"))) (ETuple (EVar "field") (EApp (EVar "JString") (EVar "msg"))))) (EVar "notices")))))) (arm PWild () (EVar "envelope"))))
(DTypeSig false "cjFileNotFoundJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "cjFileNotFoundJson" ((PVar "target") (PVar "err")) (EApp (EApp (EApp (EVar "cjUnlocatedJson") (EVar "target")) (EVar "RFileNotFound")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot read file `")) (EApp (EVar "display") (EVar "target"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "err"))) (ELit (LString "")))))
(DTypeSig false "cjSourceReadJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "cjSourceReadJson" ((PVar "target") (PCon "Some" (PVar "e"))) (EApp (EApp (EVar "cjFileNotFoundJson") (EVar "target")) (EVar "e")))
(DFunDef false "cjSourceReadJson" ((PVar "target") (PCon "None")) (EApp (EApp (EApp (EVar "cjUnlocatedJson") (EVar "target")) (EVar "RFileNotUtf8")) (EApp (EVar "sourceNotUtf8Message") (EVar "target"))))
(DTypeSig false "cjUnlocatedJson" (TyFun (TyCon "String") (TyFun (TyCon "DiagCode") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "cjUnlocatedJson" ((PVar "target") (PVar "code") (PVar "msg")) (EBlock (DoLet false false (PVar "diagJson") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EApp (EVar "codeText") (EVar "code")))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (ELit (LString "resolve")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))) (ETuple (ELit (LString "range")) (EVar "JNull")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka"))))))) (DoLet false false (PVar "filesJson") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "target"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EListLit (EVar "diagJson"))))))) (DoExpr (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "files")) (EApp (EVar "jArray") (EListLit (EVar "filesJson"))))))))))
(DTypeSig false "stripWarningLines" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripWarningLines" ((PVar "s")) (EApp (EVar "joinNl") (EApp (EApp (EVar "filter") (ELam ((PVar "l")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "Warning: "))) (EVar "l"))))) (EApp (EVar "splitNl") (EVar "s")))))
(DTypeSig false "userSchemeLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "userSchemeLines" ((PVar "decls") (PVar "report")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "omFromNames") (EApp (EVar "topLevelNames") (EVar "decls"))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "joinNl") (EApp (EApp (EVar "filter") (EApp (EVar "namesUserBinding") (EVar "names"))) (EApp (EVar "splitNl") (EVar "report")))))))
(DTypeSig false "checkOkLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "checkOkLine" ((PVar "target") (PVar "filtered")) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "count") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EVar "splitNl") (EVar "filtered")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "-- ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": ok ("))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " declaration(s) checked, 0 errors)"))))))
(DTypeSig false "namesUserBinding" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "namesUserBinding" ((PVar "names") (PVar "l")) (EMatch (EApp (EVar "schemeLineName") (EVar "l")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "topLevelNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topLevelNames" ((PList)) (EListLit))
(DFunDef false "topLevelNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "topLevelNames") (EListLit (EVar "d"))) (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n"))) true)) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")) (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "topLevelNames") (EVar "rest")))
(DTypeSig false "emitLocatedWarnings" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitLocatedWarnings" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "emitLocatedWarnings" ((PVar "src") (PVar "file") (PVar "ws")) (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "file"))) (EVar "ws")))))
(DTypeSig false "emitWarningLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emitWarningLines" ((PList)) (ELit LUnit))
(DFunDef false "emitWarningLines" ((PVar "ls")) (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EVar "ls"))))
(DTypeSig false "emitHiddenDiagNote" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emitHiddenDiagNote" ((PLit (LInt 0))) (ELit LUnit))
(DFunDef false "emitHiddenDiagNote" ((PLit (LInt 1))) (EApp (EVar "ePutStrLn") (ELit (LString "1 further diagnostic in imported modules; rerun with --json to see it"))))
(DFunDef false "emitHiddenDiagNote" ((PVar "n")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " further diagnostics in imported modules; rerun with --json to see them")))))
(DTypeSig false "allWarnTriples" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "allWarnTriples" ((PVar "src") (PVar "file") (PVar "diags")) (EMatch (EApp (EApp (EVar "filter") (EVar "diagIsWarn")) (EVar "diags")) (arm (PList) () (EListLit)) (arm (PVar "ws") () (EListLit (ETuple (EVar "file") (EVar "src") (EVar "ws"))))))
(DTypeSig false "nonEmptyTriples" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "nonEmptyTriples" ((PVar "ts")) (EApp (EApp (EVar "filter") (EVar "tripleHasDiags")) (EVar "ts")))
(DTypeSig false "dropEntryTriple" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "dropEntryTriple" ((PList)) (EListLit))
(DFunDef false "dropEntryTriple" ((PList PWild)) (EListLit))
(DFunDef false "dropEntryTriple" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "dropEntryTriple") (EVar "rest"))))
(DTypeSig false "trimEntryTriple" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "trimEntryTriple" ((PList)) (EListLit))
(DFunDef false "trimEntryTriple" ((PList (PTuple (PVar "p") (PVar "s") (PVar "ds")))) (EListLit (ETuple (EVar "p") (EVar "s") (EApp (EApp (EVar "filter") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EVar "onTypecheckWarnChannel") (EVar "d"))))) (EVar "ds")))))
(DFunDef false "trimEntryTriple" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "trimEntryTriple") (EVar "rest"))))
(DTypeSig false "onTypecheckWarnChannel" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "onTypecheckWarnChannel" ((PCon "Diag" PWild (PVar "c") PWild PWild PWild PWild)) (EBinOp "==" (EVar "c") (EApp (EVar "Coded") (EVar "coherenceWarnCode"))))
(DTypeSig false "tripleHasDiags" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "tripleHasDiags" ((PTuple PWild PWild (PList))) (EVar "False"))
(DFunDef false "tripleHasDiags" (PWild) (EVar "True"))
(DTypeSig false "fmtHelpText" (TyCon "String"))
(DFunDef false "fmtHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka fmt — Format .mdk file(s)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka fmt [--check | --stdout | --write] <path>...\n")) (ELit (LString "\n")) (ELit (LString "Read-only unless --write is given.\n")) (ELit (LString "\n")) (ELit (LString "  (default)    same as --check: reports files that are not formatted\n")) (ELit (LString "               (exit 1 if any); prints nothing when already formatted.\n")) (ELit (LString "               Never writes.\n")) (ELit (LString "  --check      explicit form of the default\n")) (ELit (LString "  --stdout     print the formatted result to stdout (single file only);\n")) (ELit (LString "               never writes\n")) (ELit (LString "  --write, -w  rewrite the file(s) in place and print a one-line summary\n")) (ELit (LString "               (\"formatted N file(s)\" / \"already formatted\")\n")) (ELit (LString "\n")) (ELit (LString "A path may be a file or a directory (recursively expanded; dotfiles and\n")) (ELit (LString "dot-dirs are skipped).\n")))))
(DTypeSig false "runFmtCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runFmtCmd" ((PVar "argv")) (EBlock (DoLet false false PWild (EApp (EVar "assertFmtOneMode") (EVar "argv"))) (DoExpr (EApp (EVar "runFmtArgs") (EApp (EApp (EVar "requireArgs") (EVar "fmtArgSpec")) (EVar "argv"))))))
(DTypeSig false "assertFmtOneMode" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertFmtOneMode" ((PVar "argv")) (EMatch (EApp (EVar "fmtModeConflict") (EVar "argv")) (arm (PList) () (ELit LUnit)) (arm (PList PWild) () (ELit LUnit)) (arm (PVar "many") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka fmt: ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "many")))) (ELit (LString " are mutually exclusive; pass one"))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))
(DTypeSig false "runFmtArgs" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runFmtArgs" ((PVar "a")) (EBlock (DoLet false false PWild (EApp (EVar "assertFmtNoDashTargets") (EFieldAccess (EVar "a") "positionals"))) (DoExpr (EMatch (ETuple (EApp (EVar "fmtModeOf") (EVar "a")) (EFieldAccess (EVar "a") "positionals")) (arm (PTuple PWild (PList)) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Usage: medaka fmt [--check | --stdout | --write] <path>...")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PTuple (PVar "mode") (PList (PVar "target"))) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "fmtOne") (EVar "mode")) (EVar "target"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EListLit (EVar "target")))))) (arm (PTuple (PVar "mode") (PVar "targets")) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EVar "targets")))))))
(DTypeSig false "assertFmtNoDashTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertFmtNoDashTargets" ((PList)) (ELit LUnit))
(DFunDef false "assertFmtNoDashTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "x")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "x")) (ELit (LString "-")))) (EApp (EVar "dieMsg") (EApp (EApp (EVar "unknownFlagMessage") (EVar "fmtArgSpec")) (EVar "x"))) (EApp (EVar "assertFmtNoDashTargets") (EVar "rest"))))
(DTypeSig false "fmtModeOf" (TyFun (TyCon "Args") (TyCon "FmtMode")))
(DFunDef false "fmtModeOf" ((PVar "a")) (EApp (EApp (EVar "fmtModeGo") (EFieldAccess (EVar "a") "given")) (EVar "FmtCheck")))
(DTypeSig false "fmtModeGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "FmtMode") (TyCon "FmtMode"))))
(DFunDef false "fmtModeGo" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "fmtModeGo" ((PCons (PTuple (PVar "k") PWild) (PVar "rest")) (PVar "m")) (EIf (EBinOp "==" (EVar "k") (ELit (LString "--check"))) (EApp (EApp (EVar "fmtModeGo") (EVar "rest")) (EVar "FmtCheck")) (EIf (EBinOp "==" (EVar "k") (ELit (LString "--stdout"))) (EApp (EApp (EVar "fmtModeGo") (EVar "rest")) (EVar "FmtStdout")) (EIf (EBinOp "==" (EVar "k") (ELit (LString "--write"))) (EApp (EApp (EVar "fmtModeGo") (EVar "rest")) (EVar "FmtWrite")) (EIf (EVar "otherwise") (EApp (EApp (EVar "fmtModeGo") (EVar "rest")) (EVar "m")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "fmtManyTargets" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "fmtManyTargets" ((PCon "FmtStdout") PWild) (EApp (EVar "dieMsg") (ELit (LString "medaka fmt: --stdout requires exactly one file"))))
(DFunDef false "fmtManyTargets" ((PVar "mode") (PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EApp (EVar "dieMsg") (ELit (LString "medaka fmt: no .mdk files found")))) (arm PWild () (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "changed")) (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "files")) (ETuple (EVar "False") (ELit (LInt 0))))) (DoLet false false PWild (EMatch (EVar "mode") (arm (PCon "FmtWrite") () (EApp (EVar "putStrLn") (EApp (EVar "fmtWriteSummaryLine") (EVar "changed")))) (arm PWild () (ELit LUnit)))) (DoExpr (EIf (EVar "hadErr") (EApp (EVar "stageExit") (ELit (LInt 1))) (ELit LUnit)))))))))
(DTypeSig false "fmtFilesGo" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "Bool") (TyCon "Int")) (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyCon "Int")))))))
(DFunDef false "fmtFilesGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "fmtFilesGo" ((PVar "mode") (PCons (PVar "f") (PVar "rest")) (PTuple (PVar "errAcc") (PVar "changedAcc"))) (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "changed")) (EApp (EApp (EVar "fmtOneReport") (EVar "mode")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "rest")) (ETuple (EBinOp "||" (EVar "errAcc") (EVar "hadErr")) (EBinOp "+" (EVar "changedAcc") (EIf (EVar "changed") (ELit (LInt 1)) (ELit (LInt 0)))))))))
(DTypeSig false "fmtWriteSummaryLine" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "fmtWriteSummaryLine" ((PLit (LInt 0))) (ELit (LString "already formatted")))
(DFunDef false "fmtWriteSummaryLine" ((PLit (LInt 1))) (ELit (LString "formatted 1 file")))
(DFunDef false "fmtWriteSummaryLine" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "formatted ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " files"))))
(DTypeSig false "sourceReadLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "sourceReadLine" ((PVar "file") (PCon "None")) (EBinOp "++" (EBinOp "++" (ELit (LString "error: ")) (EApp (EVar "display") (EApp (EVar "sourceNotUtf8Message") (EVar "file")))) (ELit (LString ""))))
(DFunDef false "sourceReadLine" ((PVar "file") (PCon "Some" (PVar "msg"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig false "fmtOneReport" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "fmtOneReport" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readSourceE") (EVar "file")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "sourceReadLine") (EVar "file")) (EVar "e")))) (DoExpr (ETuple (EVar "True") (EVar "False"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EMatch (EApp (EApp (EApp (EVar "formatSourceChecked") (EVar "src")) (EVar "toks")) (EVar "pairs")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (ETuple (EVar "True") (EVar "False"))))) (arm (PCon "Ok" (PVar "formatted")) () (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "formatted"))) (DoExpr (ETuple (EVar "False") (EVar "False"))))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ETuple (EVar "False") (EVar "False")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (ETuple (EVar "True") (EVar "False")))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ETuple (EVar "False") (EVar "False")) (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (ETuple (EVar "True") (EVar "False"))))) (arm (PCon "Ok" PWild) () (ETuple (EVar "False") (EVar "True"))))))))))))))
(DTypeSig false "fmtArgSpec" (TyCon "ArgSpec"))
(DFunDef false "fmtArgSpec" () (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--check")))) (ELit (LString "report unformatted files; write nothing"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--stdout")))) (ELit (LString "print the formatted source of one file"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--write")) (ELit (LString "-w")))) (ELit (LString "rewrite the file in place"))))))
(DTypeSig false "fmtModeConflict" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fmtModeConflict" ((PVar "argv")) (EBlock (DoLet false false (PVar "writeOn") (EBinOp "||" (EApp (EApp (EVar "contains") (ELit (LString "--write"))) (EVar "argv")) (EApp (EApp (EVar "contains") (ELit (LString "-w"))) (EVar "argv")))) (DoLet false false (PVar "named") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EApp (EVar "contains") (EVar "f")) (EVar "argv")))) (EListLit (ELit (LString "--check")) (ELit (LString "--stdout"))))) (DoExpr (EIf (EVar "writeOn") (EBinOp "++" (EVar "named") (EListLit (ELit (LString "--write")))) (EVar "named")))))
(DTypeSig false "fmtOne" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "fmtOne" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readSourceE") (EVar "file")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "dieMsg") (EApp (EApp (EVar "sourceReadLine") (EVar "file")) (EVar "e")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EMatch (EApp (EApp (EApp (EVar "formatSourceChecked") (EVar "src")) (EVar "toks")) (EVar "pairs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "dieMsg") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (arm (PCon "Ok" (PVar "formatted")) () (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EApp (EVar "putStr") (EVar "formatted"))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ELit LUnit) (EApp (EVar "dieMsg") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted")))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EApp (EVar "putStrLn") (ELit (LString "already formatted"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStrLn") (ELit (LString "formatted 1 file")))))))))))))))
(DTypeSig false "codemodHelpText" (TyCon "String"))
(DFunDef false "codemodHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka codemod — Apply a named source-preserving AST transform\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka codemod <name> [flags] [--write|--stdout] <paths...>\n")) (ELit (LString "\n")) (ELit (LString "  (default)  dry-run: prints \"would rewrite: <file>\" per changed file,\n")) (ELit (LString "             exits 1 if any file would change. Never writes.\n")) (ELit (LString "  --write    rewrite only the files that actually change\n")) (ELit (LString "  --stdout   print one file's result (single file only)\n")) (ELit (LString "\n")) (ELit (LString "Any other --flag consumes the next token as its value, passed to the\n")) (ELit (LString "named codemod. Run `medaka codemod` with no arguments to list the\n")) (ELit (LString "available codemods.\n")) (ELit (LString "\n")) (ELit (LString "NOTE: `--help`/`-h` is only recognized in the FIRST position — as\n")) (ELit (LString "`medaka codemod --help`, before a codemod name. `medaka codemod <name>\n")) (ELit (LString "--help` is NOT special-cased (it is a codemod flag) and codemod-specific\n")) (ELit (LString "help does not exist yet.\n")))))
(DTypeSig false "runCodemodCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCodemodCmd" ((PList)) (EApp (EVar "listCodemodsAndExit") (ELit LUnit)))
(DFunDef false "runCodemodCmd" ((PCons (PVar "name") (PVar "rest"))) (EMatch (EApp (EVar "findCodemod") (EVar "name")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EIf (EApp (EVar "lintTargetExists") (EVar "name")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: missing codemod name; `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is a path, and the codemod name comes first")))) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: unknown codemod `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`")))))) (DoExpr (EApp (EVar "listCodemodsAndExit") (ELit LUnit))))) (arm (PCon "Some" (PVar "cm")) () (EMatch (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmDry")) (EListLit)) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PTuple (PVar "mode") (PVar "cargs") (PVar "targets"))) () (EMatch (EApp (EApp (EVar "codemodMk") (EVar "cm")) (EVar "cargs")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "xf")) () (EBlock (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EApp (EVar "dieMsg") (ELit (LString "medaka codemod: no .mdk files found")))) (arm PWild () (EMatch (EVar "mode") (arm (PCon "CmStdout") () (EMatch (EVar "files") (arm (PList (PVar "one")) () (EApp (EApp (EApp (EVar "codemodStdout") (EVar "xf")) (EApp (EApp (EVar "codemodWarnDecls") (EVar "cm")) (EVar "cargs"))) (EVar "one"))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka codemod: --stdout requires exactly one file")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))))) (arm PWild () (EIf (EApp (EApp (EApp (EApp (EApp (EVar "codemodFilesGo") (EVar "mode")) (EVar "xf")) (EApp (EApp (EVar "codemodWarnDecls") (EVar "cm")) (EVar "cargs"))) (EVar "files")) (EVar "False")) (EApp (EVar "stageExit") (ELit (LInt 1))) (ELit LUnit)))))))))))))))
(DTypeSig false "listCodemodsAndExit" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "listCodemodsAndExit" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Usage: medaka codemod <name> [flags] [--write|--stdout] <paths...>")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Available codemods:")))) (DoExpr (EApp (EVar "dieMsg") (EVar "codemodListing")))))
(DTypeSig false "splitCodemodArgv" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CodeMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "CodeMode") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "splitCodemodArgv" ((PList) (PVar "mode") (PVar "cargs") (PVar "paths")) (EApp (EVar "Ok") (ETuple (EVar "mode") (EApp (EVar "reverseL") (EVar "cargs")) (EApp (EVar "reverseL") (EVar "paths")))))
(DFunDef false "splitCodemodArgv" ((PCons (PLit (LString "--write")) (PVar "rest")) PWild (PVar "cargs") (PVar "paths")) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmWrite")) (EVar "cargs")) (EVar "paths")))
(DFunDef false "splitCodemodArgv" ((PCons (PLit (LString "--stdout")) (PVar "rest")) PWild (PVar "cargs") (PVar "paths")) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmStdout")) (EVar "cargs")) (EVar "paths")))
(DFunDef false "splitCodemodArgv" ((PCons (PVar "tok") (PVar "rest")) (PVar "mode") (PVar "cargs") (PVar "paths")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "tok")) (EMatch (EApp (EVar "codemodFlagEq") (EVar "tok")) (arm (PCon "Some" (PTuple (PVar "nm") (PVar "v"))) () (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "mode")) (EBinOp "::" (EVar "v") (EBinOp "::" (EVar "nm") (EVar "cargs")))) (EVar "paths"))) (arm (PCon "None") () (EMatch (EVar "rest") (arm (PCons (PVar "v") (PVar "rest2")) () (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest2")) (EVar "mode")) (EBinOp "::" (EVar "v") (EBinOp "::" (EVar "tok") (EVar "cargs")))) (EVar "paths"))) (arm (PList) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: flag `")) (EApp (EVar "display") (EVar "tok"))) (ELit (LString "` requires a value")))))))) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "mode")) (EVar "cargs")) (EBinOp "::" (EVar "tok") (EVar "paths")))))
(DTypeSig false "codemodFlagEq" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "codemodFlagEq" ((PVar "tok")) (EApp (EApp (EApp (EVar "codemodFlagEqGo") (EVar "tok")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "tok"))))
(DTypeSig false "codemodFlagEqGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "codemodFlagEqGo" ((PVar "tok") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "tok")) (ELit (LString "="))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 2))) (EVar "None") (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "tok")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "tok"))))) (EApp (EApp (EApp (EVar "codemodFlagEqGo") (EVar "tok")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig false "codemodStdout" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "codemodStdout" ((PVar "xf") (PVar "warnFn") (PVar "file")) (EMatch (EApp (EVar "readSourceE") (EVar "file")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "dieMsg") (EApp (EApp (EVar "sourceReadLine") (EVar "file")) (EVar "e")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EVar "codemodSource") (EVar "xf")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "dieMsg") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (arm (PCon "Ok" (PVar "result")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitCodemodWarns") (EVar "warnFn")) (EVar "file")) (EVar "src"))) (DoExpr (EMatch (EVar "result") (arm (PCon "None") () (EApp (EVar "putStr") (EVar "src"))) (arm (PCon "Some" (PVar "out")) () (EApp (EVar "putStr") (EVar "out")))))))))))
(DTypeSig false "codemodFilesGo" (TyFun (TyCon "CodeMode") (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "codemodFilesGo" (PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "codemodFilesGo" ((PVar "mode") (PVar "xf") (PVar "warnFn") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "signal") (EApp (EApp (EApp (EApp (EVar "codemodOneReport") (EVar "mode")) (EVar "xf")) (EVar "warnFn")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "codemodFilesGo") (EVar "mode")) (EVar "xf")) (EVar "warnFn")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "signal"))))))
(DTypeSig false "codemodOneReport" (TyFun (TyCon "CodeMode") (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "codemodOneReport" ((PVar "mode") (PVar "xf") (PVar "warnFn") (PVar "file")) (EMatch (EApp (EVar "readSourceE") (EVar "file")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "sourceReadLine") (EVar "file")) (EVar "e")))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EVar "codemodSource") (EVar "xf")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "result")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitCodemodWarns") (EVar "warnFn")) (EVar "file")) (EVar "src"))) (DoExpr (EMatch (EVar "result") (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "out")) () (EMatch (EVar "mode") (arm (PCon "CmWrite") () (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "out")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EVar "False")))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "would rewrite: ")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ""))))) (DoExpr (EVar "True"))))))))))))))
(DTypeSig false "emitCodemodWarns" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitCodemodWarns" ((PVar "warnFn") (PVar "file") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "decls") PWild) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoExpr (EApp (EApp (EVar "emitWarnLines") (EVar "file")) (EApp (EVar "warnFn") (EVar "decls"))))))
(DTypeSig false "emitWarnLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitWarnLines" (PWild (PList)) (ELit LUnit))
(DFunDef false "emitWarnLines" ((PVar "file") (PCons (PVar "w") (PVar "ws"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": warning: "))) (EApp (EVar "display") (EVar "w"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EVar "emitWarnLines") (EVar "file")) (EVar "ws")))))
(DTypeSig false "newUsageLine" (TyCon "String"))
(DFunDef false "newUsageLine" () (ELit (LString "Usage: medaka new <name>")))
(DTypeSig false "newArgSpec" (TyCon "ArgSpec"))
(DFunDef false "newArgSpec" () (EApp (EApp (EVar "spec") (ELit (LString "new"))) (EListLit)))
(DTypeSig false "runNewCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runNewCmd" ((PList (PVar "arg"))) (EIf (EBinOp "||" (EBinOp "==" (EVar "arg") (ELit (LString "--help"))) (EBinOp "==" (EVar "arg") (ELit (LString "-h")))) (EApp (EVar "putStrLn") (EVar "newUsageLine")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "arg")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "arg")) (ELit (LString "-")))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "unknownFlagMessage") (EVar "newArgSpec")) (EVar "arg")))) (DoExpr (EApp (EVar "dieMsg") (EVar "newUsageLine")))) (EBlock (DoLet false false (PVar "code") (EApp (EVar "newProject") (EVar "arg"))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (ELit LUnit) (EApp (EVar "stageExit") (EVar "code"))))))))
(DFunDef false "runNewCmd" ((PVar "args")) (EMatch (EApp (EApp (EVar "filterList") (EApp (EVar "startsWith") (ELit (LString "-")))) (EVar "args")) (arm (PCons (PVar "flagTok") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "unknownFlagMessage") (EVar "newArgSpec")) (EVar "flagTok")))) (DoExpr (EApp (EVar "dieMsg") (EVar "newUsageLine"))))) (arm (PList) () (EApp (EVar "dieMsg") (EVar "newUsageLine")))))
(DTypeSig false "buildArgSpec" (TyCon "ArgSpec"))
(DFunDef false "buildArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "build"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--keep-ir")))) (ELit (LString "keep the emitted IR beside the output"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--allow-internal")))) (ELit (LString "permit internal-only externs outside stdlib/"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the structured-diagnostics envelope"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--stamp-build")))) (ELit (LString "stamp the commit, compiler fingerprint and build date into the binary"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "-o")))) (ELit (LString "PATH"))) (ELit (LString "output path for the binary"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--target")))) (ELit (LString "PROFILE"))) (ELit (LString "target profile to build for"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--emit-rt-obj")))) (ELit (LString "PATH"))) (ELit (LString "precompile the C runtime to an object"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--emit-prelude-obj")))) (ELit (LString "PATH"))) (ELit (LString "precompile the prelude to an object")))))))
(DTypeSig false "runBuildCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildCmd" ((PVar "argv")) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (ELit (LString "--help"))) (EVar "argv")) (EApp (EApp (EVar "contains") (ELit (LString "-h"))) (EVar "argv"))) (EApp (EVar "buildUsage") (ELit LUnit)) (EApp (EVar "runBuildModes") (EApp (EApp (EVar "requireArgs") (EVar "buildArgSpec")) (EVar "argv")))))
(DTypeSig false "runBuildModes" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildModes" ((PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--emit-rt-obj"))) (EVar "a")) (arm (PCon "Some" (PVar "objPath")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "emitRtObj") (EVar "cc")) (EVar "root")) (EVar "objPath")) (arm (PCon "Ok" (PVar "rep")) () (EApp (EVar "println") (EApp (EVar "ppBuildReport") (EVar "rep")))) (arm (PCon "Err" (PVar "rep")) () (EApp (EVar "dieMsg") (EApp (EVar "ppBuildReport") (EVar "rep")))))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--emit-prelude-obj"))) (EVar "a")) (arm (PCon "Some" (PVar "objPath")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "./medaka")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "emitPreludeObj") (EVar "cc")) (EVar "root")) (EVar "medaka")) (EVar "objPath")) (arm (PCon "Ok" (PVar "rep")) () (EApp (EVar "println") (EApp (EVar "ppBuildReport") (EVar "rep")))) (arm (PCon "Err" (PVar "rep")) () (EApp (EVar "dieMsg") (EApp (EVar "ppBuildReport") (EVar "rep")))))))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a")) (EApp (EVar "runBuildJsonEntry") (EVar "a")) (EApp (EVar "runBuildPlainCmd") (EVar "a"))))))))
(DTypeSig false "runBuildPlainCmd" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildPlainCmd" ((PVar "a")) (EBlock (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false (PVar "perfT0") (EApp (EVar "now") (ELit LUnit))) (DoExpr (EMatch (EApp (EVar "parseBuildArgs") (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PTuple (PVar "input") (PVar "outOpt") PWild)) () (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "input"))) (EApp (EVar "dieMsg") (EBinOp "++" (ELit (LString "error: no such file: ")) (EVar "input"))) (EBlock (DoLet false false (PVar "target") (EApp (EApp (EVar "buildTargetOrDie") (EVar "a")) (EVar "input"))) (DoExpr (EApp (EVar "perfArm") (EVar "perfT0"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "inputAbs") (EVar "input")) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "flag") (ELit (LString "--allow-internal"))) (EVar "a"))) (DoLet false false (PVar "keepIrCli") (EApp (EApp (EVar "flag") (ELit (LString "--keep-ir"))) (EVar "a"))) (DoLet false false (PVar "stampBuild") (EApp (EApp (EVar "flag") (ELit (LString "--stamp-build"))) (EVar "a"))) (DoLet false false (PVar "outPath") (EMatch (EVar "outOpt") (arm (PCon "Some" (PVar "o")) () (EVar "o")) (arm (PCon "None") () (EApp (EApp (EVar "defaultOutPath") (EVar "target")) (EVar "input"))))) (DoExpr (EMatch (EApp (EVar "readPreludeSources") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "prelude")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "nativeTreesReport") (EVar "target")) (EVar "prelude"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuild") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "target")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")) (EVar "False")) (EVar "stampBuild")) (EApp (EVar "Some") (ERecordCreate "GateAsk" ((fa "askAllowInternal" (EVar "allowInternal")) (fa "askDiagJson" (EVar "False")))))) (arm (PCon "Ok" (PVar "rep")) () (EBlock (DoLet false false (PVar "perfTEmit") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "emit"))) (EBinOp "-" (EVar "perfTEmit") (EVar "perfT0"))) (EVar "input"))) (DoLet false false PWild (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTEmit") (EVar "perfT0")))) (DoExpr (EApp (EVar "println") (EApp (EVar "ppBuildReport") (EVar "rep")))))) (arm (PCon "Err" (PVar "rep")) () (EApp (EVar "dieMsg") (EApp (EVar "ppBuildReport") (EVar "rep")))))))))))))))))
(DTypeSig false "nativeTreesReport" (TyFun (TyCon "BuildTarget") (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "nativeTreesReport" ((PCon "TNative") (PVar "prelude")) (EApp (EVar "reportChildTrees") (EVar "prelude")))
(DFunDef false "nativeTreesReport" ((PCon "TWasm") (PVar "prelude")) (EApp (EApp (EApp (EVar "reportDecls") (EVar "None")) (EVar "dieMsg")) (EVar "prelude")))
(DTypeSig false "runBuildJsonEntry" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildJsonEntry" ((PVar "a")) (EMatch (EApp (EVar "parseBuildArgs") (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "cjBuildFailedJson") (ELit (LString ""))) (EVar "msg")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PTuple (PVar "input") (PVar "outOpt") PWild)) () (EMatch (EApp (EApp (EVar "selectBuildProfile") (EVar "a")) (EVar "input")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "println") (EApp (EApp (EVar "cjBuildFailedJson") (ELit (LString ""))) (EVar "msg")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "target")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "flag") (ELit (LString "--allow-internal"))) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildJsonCmd") (EVar "a")) (EVar "allowInternal")) (EVar "root")) (EVar "stdlibDir")) (EVar "input")) (EVar "outOpt")) (EVar "target")))))))))
(DTypeSig false "buildUsage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "buildUsage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "usage: medaka build [--target <profile>] <file.mdk> [-o <out>] [--keep-ir] [--allow-internal] [--json] [--stamp-build]\n")) (ELit (LString "\n")) (ELit (LString "  -o <out>          output path for the binary (default: <file> with its extension dropped)\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "  --target <profile> target profile, one of: ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "buildableNames")))) (ELit (LString "\n"))) (ELit (LString "                    (default: [target] profile in medaka.toml, else llvm/native-posix).\n")) (ELit (LString "                    The program is checked against the profile before it is lowered;\n")) (ELit (LString "                    its backend picks the emitter (LLVM + clang, or WasmGC + wasm-tools)\n")) (ELit (LString "  --json            emit the {\"files\":[...]} structured-diagnostics envelope (same\n")) (ELit (LString "                    schema as `medaka check --json`) instead of human text; a genuine\n")) (ELit (LString "                    build-stage (emitter/clang) failure carries code R-BUILD-FAILED\n")) (ELit (LString "  --keep-ir         keep the emitted IR (.ll for native, .wat for wasm) at <out>.ll/.wat\n")) (ELit (LString "                    instead of discarding it with the build's scratch directory; the\n")) (ELit (LString "                    kept path is printed. Env var MEDAKA_KEEP_IR=1 does the same for a\n")) (ELit (LString "                    build invoked by something else (e.g. a test harness)\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")) (ELit (LString "  --stamp-build     bake build provenance into the binary: the project's git commit\n")) (ELit (LString "                    (with a -dirty suffix on a modified tree), the fingerprint of\n")) (ELit (LString "                    the compiler that built it, and the UTC build date, read back at\n")) (ELit (LString "                    run time through buildCommit/buildFingerprint/buildDate. Without\n")) (ELit (LString "                    it those three read \"\", which is what every other build path\n")) (ELit (LString "                    links; a field that cannot be derived is stamped empty\n")) (ELit (LString "  --emit-rt-obj <p> compile only runtime/medaka_rt.c to a reusable object at <p> (with\n")) (ELit (LString "                    the same flags a normal link uses, including ThinLTO bitcode by\n")) (ELit (LString "                    default) and exit; point MEDAKA_RT_OBJ at it to skip recompiling\n")) (ELit (LString "                    the runtime on every subsequent build. MEDAKA_RT_OBJ must be paired\n")) (ELit (LString "                    with the matching link mode (MEDAKA_NO_LTO set for both, or for\n")) (ELit (LString "                    neither) — a mismatch either fails to link or silently loses\n")) (ELit (LString "                    ThinLTO's inlining\n")) (ELit (LString "  --emit-prelude-obj <p>\n")) (ELit (LString "                    compile only stdlib/core.mdk to a reusable object at <p> (with the\n")) (ELit (LString "                    same flags a normal link uses) and exit; point MEDAKA_PRELUDE_OBJ at\n")) (ELit (LString "                    it to skip re-optimising the prelude on every subsequent build.\n")) (ELit (LString "                    Opt-in: separate objects cannot inline the prelude into user code\n")) (ELit (LString "\n")) (ELit (LString "runtime object cache (ON by default):\n")) (ELit (LString "  Every native build links a compiled runtime/medaka_rt.c. Rather than recompile\n")) (ELit (LString "  it each time (~0.76s), build caches the object, keyed on a hash of the .c\n")) (ELit (LString "  source, the C compiler and its version, and the exact compile flags, so a\n")) (ELit (LString "  changed runtime or compiler never reuses a stale object.\n")) (ELit (LString "  Location (first that applies): $MEDAKA_CACHE_DIR, else\n")) (ELit (LString "  $XDG_CACHE_HOME/medaka, else $HOME/.cache/medaka.\n")) (ELit (LString "  MEDAKA_NO_OBJ_CACHE=1  disable the cache; compile medaka_rt.c inline every build\n")) (ELit (LString "  MEDAKA_CACHE_DIR=<d>   put the cache somewhere else (e.g. a per-CI-job scratch dir)\n")) (ELit (LString "  An explicit MEDAKA_RT_OBJ still wins over the cache. Every cache failure is\n")) (ELit (LString "  fail-open: build falls back to the inline compile, never to an error.\n")) (ELit (LString "\n")) (ELit (LString "MEDAKA_NO_LTO=1 (any non-empty value): force the plain link instead of the\n")) (ELit (LString "  default ThinLTO link. For a consumer that needs a NATIVE runtime object\n")) (ELit (LString "  (which `ld -r` can merge and ThinLTO bitcode cannot), e.g.\n")) (ELit (LString "  test/diff_compiler_llvm_ffi.sh and the memcheck probe in\n")) (ELit (LString "  pds/test/constant_time_signing.sh. Set it for both the build that emits\n")) (ELit (LString "  the object and the build that links it.\n"))))))
(DTypeSig false "defaultOutPath" (TyFun (TyCon "BuildTarget") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "defaultOutPath" ((PCon "TNative") (PVar "input")) (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))))
(DFunDef false "defaultOutPath" ((PCon "TWasm") (PVar "input")) (EBinOp "++" (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))) (ELit (LString ".wasm"))))
(DTypeSig false "parseBuildArgs" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))
(DFunDef false "parseBuildArgs" ((PVar "a")) (EMatch (EApp (EVar "buildTargetOf") (EApp (EApp (EVar "lastValue") (ELit (LString "--target"))) (EVar "a"))) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PVar "target")) () (EApp (EApp (EApp (EVar "finishBuildArgs") (EFieldAccess (EVar "a") "positionals")) (EApp (EApp (EVar "lastValue") (ELit (LString "-o"))) (EVar "a"))) (EVar "target")))))
(DTypeSig false "buildTargetOf" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BuildTarget"))))
(DFunDef false "buildTargetOf" ((PCon "None")) (EApp (EVar "Ok") (EVar "TNative")))
(DFunDef false "buildTargetOf" ((PCon "Some" (PVar "v"))) (EApp (EVar "parseTarget") (EVar "v")))
(DTypeSig false "parseTarget" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BuildTarget"))))
(DFunDef false "parseTarget" ((PVar "name")) (EMatch (EApp (EVar "lookupProfile") (EVar "name")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "error: ")) (EVar "m")))) (arm (PCon "Ok" (PVar "p")) () (EMatch (EApp (EVar "profileBackend") (EVar "p")) (arm (PCon "BackendLlvm") () (EApp (EVar "Ok") (EVar "TNative"))) (arm (PCon "BackendWasmgc") () (EApp (EVar "Ok") (EVar "TWasm"))) (arm (PCon "BackendEval") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is not buildable (buildable: "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "buildableNames")))) (ELit (LString ")")))))))))
(DTypeSig false "selectBuildProfile" (TyFun (TyCon "Args") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BuildTarget"))))))
(DFunDef false "selectBuildProfile" ((PVar "a") (PVar "input")) (EBlock (DoLet false false (PVar "named") (EMatch (EApp (EApp (EVar "lastValue") (ELit (LString "--target"))) (EVar "a")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EVar "v"))) (arm (PCon "None") () (EApp (EApp (EVar "map") (EApp (EVar "optionOr") (ELit (LString "llvm/native-posix")))) (EApp (EVar "manifestProfileOf") (EVar "input")))))) (DoExpr (EMatch (EVar "named") (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "error: ")) (EVar "m")))) (arm (PCon "Ok" (PVar "name")) () (EMatch (EApp (EVar "lookupProfile") (EVar "name")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "error: ")) (EVar "m")))) (arm (PCon "Ok" (PVar "p")) () (EMatch (EApp (EVar "parseTarget") (EVar "name")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "target")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EApp (EVar "Some") (EVar "p")))) (DoExpr (EApp (EVar "Ok") (EVar "target")))))))))))))
(DTypeSig false "buildTargetOrDie" (TyFun (TyCon "Args") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildTarget")))))
(DFunDef false "buildTargetOrDie" ((PVar "a") (PVar "input")) (EMatch (EApp (EApp (EVar "selectBuildProfile") (EVar "a")) (EVar "input")) (arm (PCon "Ok" (PVar "target")) () (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "dieMsg") (EVar "msg"))) (DoExpr (EVar "TNative"))))))
(DTypeSig false "finishBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))))
(DFunDef false "finishBuildArgs" ((PList) PWild PWild) (EApp (EVar "Err") (ELit (LString "usage: medaka build [--target <profile>] <file.mdk> [-o <out>]"))))
(DFunDef false "finishBuildArgs" ((PList (PVar "input")) (PVar "out") (PVar "target")) (EApp (EVar "Ok") (ETuple (EVar "input") (EVar "out") (EVar "target"))))
(DFunDef false "finishBuildArgs" (PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: medaka build takes exactly one input file"))))
(DTypeSig false "finishRunEval" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "ProgramFacts") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))) (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "finishRunEval" ((PVar "target") (PVar "jsonMode") (PVar "facts") (PVar "elaborated") (PVar "mods") (PVar "cohWarns") (PVar "postPerf")) (EBlock (DoLet false false (PVar "tsrc") (EApp (EVar "readFileSafe") (EVar "target"))) (DoLet false false PWild (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EMatch (EApp (EVar "mainEntryError") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EMatch (EVar "jsonMode") (arm (PCon "True") () (EApp (EVar "runAbortJson") (EListLit (ETuple (EVar "target") (EVar "tsrc") (EListLit (EVar "d")))))) (arm (PCon "False") () (EApp (EVar "runAbort") (EApp (EApp (EApp (EVar "ppMainEntryError") (EVar "tsrc")) (EVar "target")) (EVar "d")))))) (arm (PCon "None") () (ELit LUnit)))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false PWild (EIf (EVar "jsonMode") (EApp (EApp (EVar "setRef") (EVar "pendingRunDiags")) (EApp (EVar "nonEmptyTriples") (EVar "cohWarns"))) (EApp (EVar "emitWarningLines") (EApp (EApp (EVar "flatMap") (EVar "renderTripleWarnings")) (EVar "cohWarns"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "runJsonMode")) (EVar "jsonMode"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EApp (EApp (EVar "runProgramOutput") (EVar "facts")) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated"))))) (DoLet false false PWild (EApp (EVar "postPerf") (ELit LUnit))) (DoExpr (EApp (EVar "flushPendingRunDiags") (EVar "jsonMode")))))
(DTypeSig false "flushPendingRunDiags" (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "flushPendingRunDiags" ((PCon "False")) (ELit LUnit))
(DFunDef false "flushPendingRunDiags" ((PCon "True")) (EApp (EVar "flushRunEnvelope") (EUnOp "!" (EVar "pendingRunDiags"))))
(DTypeSig false "runHelpText" (TyCon "String"))
(DFunDef false "runHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka run — Type-check and run a program (interpreter)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka run [--json] [--allow-internal] [--release] <file.mdk | -> [args...]\n")) (ELit (LString "\n")) (ELit (LString "  --json            emit the Diag JSON envelope on stderr instead of human\n")) (ELit (LString "                    text, for a runtime panic, a static (resolve/type) error\n")) (ELit (LString "                    in the program, or a warning in a SINGLE-FILE program. A\n")) (ELit (LString "                    clean run emits no envelope at all; a multi-module\n")) (ELit (LString "                    program's warnings are not reported by `run` (issue\n")) (ELit (LString "                    #2818) — use `medaka check --json` for those. KNOWN GAP:\n")) (ELit (LString "                    a usage error (bad flag, missing file) or a load/parse\n")) (ELit (LString "                    failure (bad import, malformed source) still prints human\n")) (ELit (LString "                    text on stderr and exits 1 with no envelope, so a\n")) (ELit (LString "                    consumer must handle both.\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")) (ELit (LString "  --target <name>   target profile `main` must also fit; every run is\n")) (ELit (LString "                    checked against eval/run (default: [target] profile in\n")) (ELit (LString "                    medaka.toml)\n")) (ELit (LString "  --release         accepted, ignored — the interpreter has no release mode.\n")) (ELit (LString "                    There is no `build --release`; a native build is always\n")) (ELit (LString "                    optimized. Kept so a `--release` in a shared script does\n")) (ELit (LString "                    not make `medaka run` fail.\n")) (ELit (LString "\n")) (ELit (LString "`run` is the interpreter: it starts at once but runs slowly. For speed, use\n")) (ELit (LString "`medaka build`, the fast native path.\n")) (ELit (LString "\n")) (ELit (LString "Args after <file.mdk> are passed through to the program's own `args`.\n")) (ELit (LString "`medaka run -` reads the program from standard input (a heredoc), so the\n")) (ELit (LString "program's own `readAll`/`readLine` see end-of-file; a script that is also a\n")) (ELit (LString "filter must be run from a file. Imports resolve against the current directory.\n")) (ELit (LString "Inline-eval (`-e <expr>`) is NOT supported; use `medaka run -` and a heredoc.\n")))))
(DTypeSig false "runArgSpec" (TyCon "ArgSpec"))
(DFunDef false "runArgSpec" () (EApp (EApp (EVar "spec") (ELit (LString "run"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the structured-diagnostics envelope on stderr"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--allow-internal")))) (ELit (LString "permit internal-only externs outside stdlib/"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--release")))) (ELit (LString "accepted and ignored (eval is never optimized)"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--target")))) (ELit (LString "NAME"))) (ELit (LString "target profile `main` must also fit"))))))
(DTypeSig false "runEvalPerf" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Int") (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "runEvalPerf" ((PVar "perfOn") (PVar "target") (PVar "perfT0") (PVar "perfTCheck") (PVar "allocCheck") (PVar "opCheck") PWild) (EBlock (DoLet false false (PVar "perfTEval") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emitPhaseAO") (EVar "perfOn")) (ELit (LString "eval"))) (EBinOp "-" (EVar "perfTEval") (EVar "perfTCheck"))) (EBinOp "-" (EApp (EVar "allocSnap") (ELit LUnit)) (EVar "allocCheck"))) (EVar "target")) (EBinOp "-" (EApp (EVar "opSnap") (ELit LUnit)) (EVar "opCheck")))) (DoExpr (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTEval") (EVar "perfT0"))))))
(DTypeSig false "runRunCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runRunCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "setOpCounting") (EVar "perfOn"))) (DoLet false false (PVar "perfT0") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "runFlagGiven") (ELit (LString "--json"))) (EVar "argv"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "perfSinkOn")) (EBinOp "&&" (EVar "jsonMode") (EVar "perfOn")))) (DoExpr (EMatch (EApp (EVar "runArgvFilter") (EVar "argv")) (arm (PList) () (EApp (EVar "runAbort") (ELit (LString "usage: medaka run [--json] [--allow-internal] [--release] [--target <profile>] <file.mdk | -> [args...]")))) (arm (PCons (PVar "target") PWild) ((GBool (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "target") (ELit (LString "-"))) (EBinOp ">" (EApp (EVar "stringLength") (EVar "target")) (ELit (LInt 0)))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "target")) (ELit (LString "-")))))) (EApp (EVar "runAbort") (EApp (EApp (EVar "unknownFlagMessage") (EVar "runArgSpec")) (EVar "target")))) (arm (PCons (PVar "target") PWild) ((GBool (EBinOp "&&" (EBinOp "||" (EApp (EVar "hasSlash") (EVar "target")) (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "target"))) (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "target")))))) (EApp (EVar "runAbort") (EBinOp "++" (ELit (LString "error: no such file: ")) (EVar "target")))) (arm (PCons (PVar "target") PWild) ((GBool (EBinOp "==" (EVar "target") (EVar "stdinEntry")))) (EApp (EVar "runAbort") (ELit (LString "error: `<stdin>` is not a file; use `medaka run -` to read the program from standard input")))) (arm (PCons (PVar "rawTarget") (PVar "progArgs")) () (EBlock (DoLet false false (PVar "isStdin") (EBinOp "==" (EVar "rawTarget") (ELit (LString "-")))) (DoLet false false (PVar "target") (EIf (EVar "isStdin") (EVar "stdinEntry") (EVar "rawTarget"))) (DoLet false false (PVar "stdinText") (EIf (EVar "isStdin") (EApp (EVar "orExit") (EApp (EVar "readStdinProgram") (ELit LUnit))) (ELit (LString "")))) (DoExpr (EApp (EVar "perfArm") (EVar "perfT0"))) (DoExpr (EApp (EApp (EVar "carryTargetProfile") (EApp (EVar "runTargetFlag") (EVar "argv"))) (EVar "target"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "runFlagGiven") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "progArgsRef")) (EVar "progArgs"))) (DoLet false false (PVar "prelude") (EApp (EVar "orExit") (EApp (EVar "readPreludeSources") (EVar "stdlibDir")))) (DoLet false false (PVar "rsrc") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (DoLet false false (PVar "csrc") (EFieldAccess (EVar "prelude") "pnCoreSrc")) (DoLet false false (PVar "tsrc") (EIf (EVar "isStdin") (EVar "stdinText") (EApp (EVar "readFileSafe") (EVar "target")))) (DoLet false false (PVar "readEntry") (EApp (EVar "stdinReadOverride") (EVar "stdinText"))) (DoLet false false (PVar "modsWithPath") (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (EVar "readEntry")) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "reportShippedHeaders") (EApp (EVar "deferredInto") (EVar "jsonMode"))) (EVar "prelude"))) (DoLet false false PWild (EApp (EVar "orExit") (EApp (EApp (EVar "mapErr") (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target"))) (EApp (EVar "parseResult") (EVar "tsrc"))))) (DoLet false false PWild (EApp (EVar "runAbort") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))) (DoExpr (EApp (EVar "panic") (ELit (LString "unreachable")))))) (arm (PCon "Ok" (PVar "mp")) () (EVar "mp")))) (DoLet false false (PVar "mods") (EApp (EApp (EVar "map") (EVar "dropPathTriple")) (EVar "modsWithPath"))) (DoLet false false (PVar "pathMap") (EApp (EApp (EVar "map") (EVar "modIdToPath")) (EVar "modsWithPath"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "modulePathMap")) (EVar "pathMap"))) (DoLet false false (PVar "rtD") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (DoLet false false (PVar "coreD") (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (DoLet false false (PVar "modsD") (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false PWild (EApp (EApp (EVar "takeShippedPrelude") (EApp (EVar "deferredInto") (EVar "jsonMode"))) (EVar "prelude"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PVar "inputs") (ERecordUpdate (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "flatStdlib")) (EVar "ownedStdlib")) ((fa "diPreludeKey" (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EVar "rsrc")) (EVar "csrc"))))))) (DoLet false false (PVar "perfTLoad") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "load"))) (EBinOp "-" (EVar "perfTLoad") (EVar "perfT0"))) (EVar "target"))) (DoLet false false (PTuple (PVar "program") (PVar "frontTrusted")) (EMatch (EVar "modsWithPath") (arm (PList (PVar "m")) () (ETuple (EApp (EVar "FrontFile") (EVar "m")) (EListLit))) (arm PWild () (ETuple (EApp (EApp (EVar "FrontGraph") (EVar "modsWithPath")) (EVar "modsD")) (EVar "trusted"))))) (DoLet false false (PVar "executionDriver") (ERecordCreate "EntryKey" ((fa "moduleId" (ELit (LString "async"))) (fa "binding" (ELit (LString "runAsyncMain")))))) (DoLet false false (PVar "front") (EApp (EApp (EApp (EVar "frontEnd") (EVar "cliStdlibExportsEnv")) (ELam ((PVar "d")) (EApp (EApp (EApp (EApp (EApp (EVar "elaborateRun") (EFieldAccess (EVar "d") "fdInputs")) (EVar "executionDriver")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD")))) (ERecordCreate "FrontInput" ((fa "fiInputs" (EVar "inputs")) (fa "fiAllowInternal" (EVar "allowInternal")) (fa "fiTrusted" (EVar "frontTrusted")) (fa "fiRuntimeSrc" (EVar "rsrc")) (fa "fiCoreSrc" (EVar "csrc")) (fa "fiPolicy" (EVar "NeverDriveRejected")) (fa "fiProgram" (EVar "program")))))) (DoLet false false (PVar "report") (EFieldAccess (EVar "front") "foReport")) (DoExpr (EMatch (EVar "mods") (arm (PList PWild) () (EBlock (DoLet false false (PVar "tsrc") (EIf (EVar "isStdin") (EVar "stdinText") (EApp (EVar "readFileSafe") (EVar "target")))) (DoLet false false (PVar "diags") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EFieldAccess (EVar "front") "foDiags"))) (DoExpr (EMatch (ETuple (EApp (EApp (EVar "filter") (EVar "diagIsError")) (EVar "diags")) (EFieldAccess (EVar "front") "foDriven")) (arm (PTuple (PList) (PCon "Some" (PVar "analysis"))) () (EBlock (DoLet false false (PVar "residual") (EFieldAccess (EFieldAccess (EVar "analysis") "eaElab") "erResidual")) (DoExpr (EMatch (EApp (EVar "isNone") (EFieldAccess (EVar "report") "trChecked")) (arm (PCon "True") () (EMatch (EVar "jsonMode") (arm (PCon "True") () (EApp (EVar "runAbortJson") (EApp (EApp (EApp (EVar "residualJsonTriples") (EVar "target")) (EVar "pathMap")) (EVar "residual")))) (arm (PCon "False") () (EApp (EVar "runAbort") (EApp (EApp (EApp (EVar "residualOrGeneric") (EVar "pathMap")) (EVar "target")) (EVar "residual")))))) (arm (PCon "False") () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTargetGate") (EVar "jsonMode")) (ELam ((PVar "t")) (EVar "t"))) (EVar "target")) (EVar "pathMap")) (EVar "mods")) (EVar "analysis"))) (DoLet false false (PVar "perfTCheck") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "allocCheck") (EApp (EVar "allocSnap") (ELit LUnit))) (DoLet false false (PVar "opCheck") (EApp (EVar "opSnap") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "check"))) (EBinOp "-" (EVar "perfTCheck") (EVar "perfTLoad"))) (EVar "target"))) (DoLet false false (PVar "executed") (EApp (EApp (EApp (EVar "executedFromReport") (EVar "report")) (EVar "executionDriver")) (ETuple (EVar "coreD") (EVar "modsD")))) (DoExpr (EMatch (EVar "executed") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "runAbort") (EVar "msg"))) (arm (PCon "Ok" (PVar "trees")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EApp (EVar "checkedFacts") (EVar "report"))) (EVar "trees")) (EVar "mods")) (EApp (EApp (EApp (EVar "allWarnTriples") (EVar "tsrc")) (EVar "target")) (EVar "diags"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalPerf") (EVar "perfOn")) (EVar "target")) (EVar "perfT0")) (EVar "perfTCheck")) (EVar "allocCheck")) (EVar "opCheck")))))))))))) (arm (PTuple (PVar "errs") PWild) () (EMatch (EVar "jsonMode") (arm (PCon "True") () (EApp (EVar "runAbortJson") (EListLit (ETuple (EVar "target") (EVar "tsrc") (EVar "diags"))))) (arm (PCon "False") () (EApp (EVar "runAbort") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs"))))))))))) (arm PWild () (EMatch (EFieldAccess (EVar "front") "foDriven") (arm (PCon "None") () (EMatch (EVar "jsonMode") (arm (PCon "True") () (EApp (EVar "runAbortJson") (EApp (EApp (EVar "map") (EApp (EVar "relDiagTriple") (EVar "root"))) (EApp (EVar "resolveErrorJsonTriples") (EFieldAccess (EVar "front") "foDiags"))))) (arm (PCon "False") () (EApp (EVar "runAbort") (EApp (EVar "ppDiagBuckets") (EFieldAccess (EVar "front") "foDiags")))))) (arm (PCon "Some" (PVar "analysis")) () (EBlock (DoLet false false (PVar "residual") (EFieldAccess (EFieldAccess (EVar "analysis") "eaElab") "erResidual")) (DoExpr (EMatch (EApp (EVar "locatedProjectDiags") (EFieldAccess (EVar "front") "foDiags")) (arm (PTuple (PCon "Some" (PVar "errText")) PWild PWild) () (EMatch (EVar "jsonMode") (arm (PCon "True") () (EBlock (DoLet false false (PVar "jsonTriples") (EApp (EApp (EVar "map") (EApp (EVar "relDiagTriple") (EVar "root"))) (EApp (EVar "nonEmptyTriples") (EApp (EApp (EVar "map") (EVar "readDiagSrc")) (EFieldAccess (EVar "front") "foDiags"))))) (DoExpr (EApp (EVar "runAbortJson") (EVar "jsonTriples"))))) (arm (PCon "False") () (EApp (EVar "runAbort") (EVar "errText"))))) (arm (PTuple (PCon "None") (PVar "projWarns") PWild) () (EMatch (EApp (EVar "isNone") (EFieldAccess (EVar "report") "trChecked")) (arm (PCon "True") () (EMatch (EVar "jsonMode") (arm (PCon "True") () (EApp (EVar "runAbortJson") (EApp (EApp (EVar "map") (EApp (EVar "relDiagTriple") (EVar "root"))) (EApp (EApp (EApp (EVar "residualJsonTriples") (EVar "target")) (EVar "pathMap")) (EVar "residual"))))) (arm (PCon "False") () (EApp (EVar "runAbort") (EApp (EApp (EApp (EVar "residualOrGeneric") (EVar "pathMap")) (EVar "target")) (EVar "residual")))))) (arm (PCon "False") () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTargetGate") (EVar "jsonMode")) (EApp (EVar "relDiagTriple") (EVar "root"))) (EVar "target")) (EVar "pathMap")) (EVar "mods")) (EVar "analysis"))) (DoLet false false (PVar "perfTCheck") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "allocCheck") (EApp (EVar "allocSnap") (ELit LUnit))) (DoLet false false (PVar "opCheck") (EApp (EVar "opSnap") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "check"))) (EBinOp "-" (EVar "perfTCheck") (EVar "perfTLoad"))) (EVar "target"))) (DoLet false false (PVar "executed") (EApp (EApp (EApp (EVar "executedFromReport") (EVar "report")) (EVar "executionDriver")) (ETuple (EVar "coreD") (EVar "modsD")))) (DoExpr (EMatch (EVar "executed") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "runAbort") (EVar "msg"))) (arm (PCon "Ok" (PVar "trees")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EApp (EVar "checkedFacts") (EVar "report"))) (EVar "trees")) (EVar "mods")) (EVar "projWarns")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalPerf") (EVar "perfOn")) (EVar "target")) (EVar "perfT0")) (EVar "perfTCheck")) (EVar "allocCheck")) (EVar "opCheck"))))))))))))))))))))))))
(DTypeSig false "desugarPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarPair" ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EApp (EVar "desugarIn") (EVar "mid")) (EVar "p"))))
(DTypeSig false "elaborateRun" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "EntryKey") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyTuple (TyCon "EntryAnalysis") (TyCon "TcReport") (TyCon "DriveOutputs")))))))))
(DFunDef false "elaborateRun" ((PVar "inputs") (PVar "executionDriver") (PVar "rtD") (PVar "coreD") (PVar "modsD")) (EBlock (DoLet false false (PTuple (PVar "analysis") (PVar "report") (PVar "outputs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProgramReport") (EApp (EApp (EApp (EVar "executedMainInputs") (EVar "inputs")) (EVar "executionDriver")) (EVar "modsD"))) (EApp (EApp (EVar "valueMainCandidate") (EVar "coreD")) (EVar "modsD"))) (EApp (EVar "Some") (EFieldAccess (EVar "executionDriver") "binding"))) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoLet false false PWild (EMatch (EApp (EApp (EVar "asyncMainShapeError") (EFieldAccess (EVar "outputs") "doEntryOutcome")) (EVar "modsD")) (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "runAbort") (EVar "msg"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (ETuple (EVar "analysis") (EVar "report") (EVar "outputs")))))
(DTypeSig false "runProgramOutput" (TyFun (TyCon "ProgramFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "runProgramOutput" ((PVar "facts") (PVar "preludeDecls") (PVar "modules")) (EApp (EApp (EApp (EVar "evalModulesOutputRunFacts") (EVar "facts")) (EVar "preludeDecls")) (EVar "modules")))
(DTypeSig false "checkedFacts" (TyFun (TyCon "TcReport") (TyCon "ProgramFacts")))
(DFunDef false "checkedFacts" ((PVar "report")) (EMatch (EFieldAccess (EVar "report") "trChecked") (arm (PCon "Some" (PVar "checked")) () (EApp (EVar "factsOfChecked") (EVar "checked"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "internal error: the typecheck published no checked program to run"))))))
(DTypeSig false "runTestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runTestCmd" ((PVar "argv0")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "testArgSpec")) (EVar "argv0"))) (DoExpr (EIf (EApp (EApp (EVar "flag") (ELit (LString "--props-worker"))) (EVar "a")) (EApp (EVar "runPropsWorkerCmd") (EVar "a")) (EMatch (EApp (EVar "parseTestEngines") (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "engines")) () (EMatch (EApp (EVar "parseTestCasesFlag") (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "casesOpt")) () (EMatch (EApp (EApp (EVar "parseTestIntFlag") (ELit (LString "--seed"))) (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "seedOpt")) () (EBlock (DoLet false false PWild (EMatch (EVar "seedOpt") (arm (PCon "Some" (PVar "s")) () (EApp (EVar "seedPropRng") (EVar "s"))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false (PVar "cases") (EApp (EApp (EVar "optionOr") (ELit (LInt 100))) (EVar "casesOpt"))) (DoLet false false (PVar "filterOpt") (EApp (EApp (EVar "flagValue") (ELit (LString "--filter"))) (EVar "a"))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a"))) (DoExpr (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList) () (EIf (EVar "jsonMode") (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka test --json: needs a single file.mdk target; with no target, medaka test runs the whole enclosing project")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EVar "runTestProjectCmd") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")))) (arm (PList (PVar "target")) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EVar "runTestJsonCmd") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "runTestOne") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "target")))) (arm (PCon "Ok" PWild) () (EIf (EVar "jsonMode") (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka test --json: directory targets are not supported; pass a single file.mdk target")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EApp (EVar "runTestManyTargets") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")) (EListLit (EVar "target"))))))) (arm (PVar "targets") () (EIf (EVar "jsonMode") (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka test --json: exactly one file.mdk target is supported")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EApp (EVar "runTestManyTargets") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")) (EVar "targets")))))))))))))))))
(DTypeSig false "runPropsWorkerCmd" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runPropsWorkerCmd" ((PVar "a")) (EMatch (EApp (EVar "parsePropsWorkerPositionals") (EFieldAccess (EVar "a") "positionals")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test --props-worker: ")) (EApp (EVar "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "target") (PVar "requests"))) () (EApp (EApp (EVar "runEvalPropsWorker") (EVar "target")) (EVar "requests")))))
(DTypeSig false "parsePropsWorkerPositionals" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PropRequest"))))))
(DFunDef false "parsePropsWorkerPositionals" ((PList)) (EApp (EVar "Err") (ELit (LString "expected a target and zero or more property request triples"))))
(DFunDef false "parsePropsWorkerPositionals" ((PCons (PVar "target") (PVar "fields"))) (EApp (EApp (EVar "map") (ELam ((PVar "requests")) (ETuple (EVar "target") (EVar "requests")))) (EApp (EVar "parsePropsWorkerRequests") (EVar "fields"))))
(DTypeSig false "parsePropsWorkerRequests" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PropRequest")))))
(DFunDef false "parsePropsWorkerRequests" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "parsePropsWorkerRequests" ((PCons (PVar "nameText") (PCons (PVar "seedText") (PCons (PVar "casesText") (PVar "rest"))))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "parseWorkerField") (ELit (LString "name"))) (EVar "nameText"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "parseWorkerInt") (ELit (LString "seed"))) (EVar "seedText"))) (ELam ((PVar "seed")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "parseWorkerInt") (ELit (LString "cases"))) (EVar "casesText"))) (ELam ((PVar "cases")) (EIf (EBinOp "<=" (EVar "cases") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "property request ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "name")))) (ELit (LString " has a non-positive case budget")))) (EApp (EApp (EVar "andThen") (EApp (EVar "parsePropsWorkerRequests") (EVar "rest"))) (ELam ((PVar "requests")) (EApp (EVar "Ok") (EBinOp "::" (EApp (EApp (EApp (EVar "PropRequest") (EVar "name")) (EVar "seed")) (EVar "cases")) (EVar "requests")))))))))))))
(DFunDef false "parsePropsWorkerRequests" (PWild) (EApp (EVar "Err") (ELit (LString "property requests must be name, seed, cases triples"))))
(DTypeSig false "parseWorkerInt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "parseWorkerInt" ((PVar "role") (PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "parseWorkerField") (EVar "role")) (EVar "text"))) (ELam ((PVar "field")) (EMatch (EApp (EVar "toInt") (EVar "field")) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "property request ")) (EApp (EVar "display") (EVar "role"))) (ELit (LString " is not an integer: "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "field")))) (ELit (LString "")))))))))
(DTypeSig false "parseWorkerField" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "parseWorkerField" ((PVar "role") (PVar "text")) (EMatch (EApp (EVar "parseJson") (EVar "text")) (arm (PCon "Ok" (PVar "json")) () (EMatch (EApp (EVar "asString") (EVar "json")) (arm (PCon "Some" (PVar "field")) () (EApp (EVar "Ok") (EVar "field"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "property request ")) (EApp (EVar "display") (EVar "role"))) (ELit (LString " is not a JSON string"))))))) (arm (PCon "Err" PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "property request ")) (EApp (EVar "display") (EVar "role"))) (ELit (LString " is not a JSON string")))))))
(DTypeSig false "runTestProjectCmd" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "runTestProjectCmd" ((PVar "engines") (PVar "cases") (PVar "filterOpt") (PVar "seedOpt")) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoExpr (EMatch (EApp (EVar "findProjectRoot") (EVar "cwd")) (arm (PCon "None") () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: no target given and no medaka.toml in ")) (EApp (EVar "display") (EVar "cwd"))) (ELit (LString " or any directory above it; pass a file.mdk or directory target, or run inside a project"))))) (arm (PCon "Some" (PVar "root")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: no target given; testing the project at ")) (EApp (EVar "display") (EVar "root"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "runTestManyTargets") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")) (EListLit (EVar "root"))))))))))
(DTypeSig false "runTestJsonCmd" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "runTestJsonCmd" ((PVar "engines") (PVar "cases") (PVar "filterOpt") (PVar "target")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "r") (EApp (EApp (EVar "andThen") (EApp (EVar "readPreludeSources") (EVar "stdlibDir"))) (ELam ((PVar "prelude")) (ELet false PWild (EApp (EVar "seedCheckPrelude") (EVar "prelude")) (EApp (EApp (EVar "andThen") (EApp (EVar "readSource") (EVar "target"))) (ELam ((PVar "tsrc")) (ELet false (PVar "userDecls") (EApp (EVar "targetDesugared") (EVar "tsrc")) (EIf (EApp (EApp (EApp (EVar "filterMatchedNothing") (EVar "filterOpt")) (EVar "tsrc")) (EVar "userDecls")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": --filter matched no doctests, props, or `test \"…\"` decls")))) (EBlock (DoLet false false (PTuple (PVar "typeError") (PVar "runs") (PVar "props") (PVar "tests") (PVar "typecheckSkipped")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestGradedReport") (EVar "engines")) (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (EFieldAccess (EVar "prelude") "pnCoreSrc")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "stdlibDir")) (EVar "cases")) (EVar "filterOpt")) (EVar "True"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cliGradedTestReportJson") (EVar "target")) (EVar "typeError")) (EVar "engines")) (EVar "runs")) (EVar "props")) (EVar "tests")) (EVar "typecheckSkipped"))))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "cliGradedTestReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")) (EVar "tests"))))))))))))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" (PVar "e")) () (EApp (EVar "dieMsg") (EVar "e"))) (arm (PCon "Ok" (PVar "ok")) () (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "stageExit") (ELit (LInt 1)))))))))
(DTypeSig false "runTestManyTargets" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "runTestManyTargets" ((PVar "engines") (PVar "cases") (PVar "filterOpt") (PVar "seedOpt") (PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EApp (EVar "dieMsg") (ELit (LString "medaka test: no .mdk files found")))) (arm PWild () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "rosterOk") (EApp (EApp (EApp (EVar "checkTestMdkRoster") (EVar "root")) (EVar "targets")) (EVar "files"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "reportSupervisedTrees") (EVar "stdlibDir")) (EVar "rtPath")) (EVar "corePath"))) (DoLet false false (PVar "anyFailed") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")) (EVar "files")) (EVar "False"))) (DoExpr (EIf (EBinOp "||" (EVar "anyFailed") (EApp (EVar "not") (EVar "rosterOk"))) (EApp (EVar "stageExit") (ELit (LInt 1))) (ELit LUnit)))))))))
(DTypeSig false "reportSupervisedTrees" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "reportSupervisedTrees" ((PVar "stdlibDir") (PVar "rtPath") (PVar "corePath")) (EMatch (ETuple (EApp (EVar "readFile") (EVar "rtPath")) (EApp (EVar "readFile") (EVar "corePath"))) (arm (PTuple (PCon "Ok" (PVar "rsrc")) (PCon "Ok" (PVar "csrc"))) () (EApp (EVar "reportChildTrees") (EApp (EApp (EApp (EVar "shippedInputs") (EVar "stdlibDir")) (EVar "rsrc")) (EVar "csrc")))) (arm PWild () (ELit LUnit))))
(DTypeSig false "docHelpText" (TyCon "String"))
(DFunDef false "docHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka doc — Generate Markdown documentation for a file or module library\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka doc <file.mdk>\n")) (ELit (LString "  medaka doc --out DIR <file.mdk> [<file.mdk> ...]\n")) (ELit (LString "\n")) (ELit (LString "Single-file mode prints Markdown for every PUBLIC declaration (with\n")) (ELit (LString "inferred type schemes) in <file.mdk> to stdout.\n")) (ELit (LString "\n")) (ELit (LString "Library mode (--out DIR) writes one Markdown page per module, an\n")) (ELit (LString "index.md linking them, and an inventory.json (name -> module ->\n")) (ELit (LString "signature) into DIR.\n")) (ELit (LString "\n")) (ELit (LString "  --out DIR   output directory; enables library mode\n")))))
(DTypeSig false "docArgSpec" (TyCon "ArgSpec"))
(DFunDef false "docArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "doc"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--out")))) (ELit (LString "DIR"))) (ELit (LString "output directory; enables library mode")))))))
(DTypeSig false "runDocCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runDocCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "docArgSpec")) (EVar "argv"))) (DoExpr (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--out"))) (EVar "a")) (arm (PCon "Some" (PVar "dir")) () (EApp (EApp (EVar "runDocLibraryTargets") (EVar "dir")) (EFieldAccess (EVar "a") "positionals"))) (arm (PCon "None") () (EApp (EVar "runDocTargets") (EFieldAccess (EVar "a") "positionals")))))))
(DTypeSig false "runDocTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runDocTargets" ((PList)) (EApp (EVar "dieMsg") (ELit (LString "usage: medaka doc <file.mdk>"))))
(DFunDef false "runDocTargets" ((PCons PWild (PCons PWild PWild))) (EApp (EVar "dieMsg") (ELit (LString "usage: medaka doc <file.mdk> (doc takes exactly one file)"))))
(DFunDef false "runDocTargets" ((PCons (PVar "target") PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EVar "carryTargetProfile") (EVar "None")) (EVar "target"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "r") (EApp (EApp (EVar "andThen") (EApp (EVar "readPreludeSources") (EVar "stdlibDir"))) (ELam ((PVar "prelude")) (ELet false PWild (EApp (EVar "seedCheckPrelude") (EVar "prelude")) (EApp (EApp (EVar "andThen") (EApp (EVar "readSource") (EVar "target"))) (ELam ((PVar "tsrc")) (ELet false PWild (EApp (EVar "orExit") (EApp (EApp (EVar "mapErr") (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target"))) (EApp (EVar "parseResult") (EVar "tsrc")))) (EApp (EVar "Ok") (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EApp (EVar "runDoc") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (EFieldAccess (EVar "prelude") "pnCoreSrc")) (EVar "tsrc")) (EVar "target")) (EVar "roots"))))))))))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "v")) () (EVar "v"))))))
(DTypeSig false "runDocLibraryTargets" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runDocLibraryTargets" (PWild (PList)) (EApp (EVar "dieMsg") (ELit (LString "usage: medaka doc --out DIR <file.mdk> [<file.mdk> ...]"))))
(DFunDef false "runDocLibraryTargets" ((PVar "outDir") (PVar "targets")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "carryTargetProfile") (EVar "None")) (EApp (EApp (EVar "optionOr") (ELit (LString "."))) (EApp (EVar "head") (EVar "targets"))))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "r") (EApp (EApp (EVar "andThen") (EApp (EVar "readPreludeSources") (EVar "stdlibDir"))) (ELam ((PVar "prelude")) (ELet false PWild (EApp (EVar "seedCheckPrelude") (EVar "prelude")) (EApp (EApp (EVar "andThen") (EApp (EVar "ensureOutDir") (EVar "outDir"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "collectModuleDocs") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (EFieldAccess (EVar "prelude") "pnCoreSrc")) (EVar "stdlibDir")) (EApp (EApp (EVar "filter") (ELam ((PVar "t")) (EApp (EVar "not") (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "t"))))) (EVar "targets")))) (ELam ((PVar "mds")) (EApp (EVar "Ok") (EApp (EApp (EVar "writeLibraryOutputs") (EVar "outDir")) (EApp (EVar "rebucketLibraryImpls") (EApp (EApp (EVar "sortOn") (EVar "mdName")) (EVar "mds"))))))))))))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "v")) () (EVar "v"))))))
(DTypeSig false "ensureOutDir" (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "ensureOutDir" ((PVar "dir")) (EMatch (EApp (EVar "makeDir") (EVar "dir")) (arm (PCon "Ok" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "Err" (PVar "e")) () (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (ELit (LString "exists"))) (EVar "e"))) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EVar "e"))))))
(DTypeSig false "collectModuleDocs" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ModuleDoc")))))))))
(DFunDef false "collectModuleDocs" (PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "collectModuleDocs" ((PVar "rsrc") (PVar "csrc") (PVar "stdlibDir") (PCons (PVar "target") (PVar "rest"))) (EMatch (EApp (EVar "readSource") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EApp (EVar "docParseError") (EVar "target")) (EVar "tsrc")) (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "md") (EApp (EApp (EApp (EApp (EApp (EVar "computeModuleDoc") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "roots"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "md") (EVar "_s")))) (EApp (EApp (EApp (EApp (EVar "collectModuleDocs") (EVar "rsrc")) (EVar "csrc")) (EVar "stdlibDir")) (EVar "rest"))))))))))
(DTypeSig false "checkDistinctModuleNames" (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "checkDistinctModuleNames" ((PVar "mds")) (EApp (EApp (EVar "checkDistinctGo") (EVar "mds")) (EListLit)))
(DTypeSig false "checkDistinctGo" (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "checkDistinctGo" ((PList) PWild) (ELit LUnit))
(DFunDef false "checkDistinctGo" ((PCons (PVar "md") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "mdName") (EVar "md"))) (DoExpr (EIf (EApp (EApp (EVar "elemStrCli") (EVar "n")) (EVar "seen")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka doc --out: two targets share the module name `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` and would write the same page `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ".md`; rename one"))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))) (EApp (EApp (EVar "checkDistinctGo") (EVar "rest")) (EBinOp "::" (EVar "n") (EVar "seen")))))))
(DTypeSig false "elemStrCli" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "elemStrCli" (PWild (PList)) (EVar "False"))
(DFunDef false "elemStrCli" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "elemStrCli") (EVar "x")) (EVar "ys"))))
(DTypeSig false "writeLibraryOutputs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "writeLibraryOutputs" ((PVar "outDir") (PVar "mds")) (EBlock (DoLet false false PWild (EApp (EVar "checkDistinctModuleNames") (EVar "mds"))) (DoLet false false PWild (EApp (EApp (EVar "writeLibraryPages") (EVar "outDir")) (EVar "mds"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "writeLibraryFile") (EVar "outDir")) (ELit (LString "index.md"))) (EApp (EVar "renderIndex") (EVar "mds")))) (DoExpr (EApp (EApp (EApp (EVar "writeLibraryFile") (EVar "outDir")) (ELit (LString "inventory.json"))) (EApp (EVar "stringify") (EApp (EVar "libraryInventoryJson") (EVar "mds")))))))
(DTypeSig false "writeLibraryPages" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "writeLibraryPages" (PWild (PList)) (ELit LUnit))
(DFunDef false "writeLibraryPages" ((PVar "outDir") (PCons (PVar "md") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "writeLibraryFile") (EVar "outDir")) (EBinOp "++" (EApp (EVar "mdName") (EVar "md")) (ELit (LString ".md")))) (EApp (EVar "renderModulePage") (EVar "md")))) (DoExpr (EApp (EApp (EVar "writeLibraryPages") (EVar "outDir")) (EVar "rest")))))
(DTypeSig false "writeLibraryFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "writeLibraryFile" ((PVar "outDir") (PVar "name") (PVar "contents")) (EMatch (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "outDir")) (EVar "name"))) (EVar "contents")) (arm (PCon "Ok" PWild) () (ELit LUnit)) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg")))))
(DTypeSig false "checkPolicyHelpText" (TyCon "String"))
(DFunDef false "checkPolicyHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka check-policy — Check a plugin's inferred effects against an allow-list\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]\n")) (ELit (LString "\n")) (ELit (LString "  --allow L1,L2,...  effect labels the plugin is permitted to use\n")) (ELit (LString "                     (default: Cache,Log)\n")) (ELit (LString "  --fn name          the function whose inferred effect row is checked\n")) (ELit (LString "                     (default: transform)\n")) (ELit (LString "\n")) (ELit (LString "Prints an accept/reject header; on accept, also runs the plugin on a\n")) (ELit (LString "sample request. Exit 0 on accept, 1 on reject.\n")))))
(DTypeSig false "policyArgSpec" (TyCon "ArgSpec"))
(DFunDef false "policyArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "check-policy"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--allow")))) (ELit (LString "L1,L2,..."))) (ELit (LString "effect labels the plugin may use"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--fn")))) (ELit (LString "NAME"))) (ELit (LString "the function whose effect row is checked")))))))
(DTypeSig false "runCheckPolicyCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckPolicyCmd" ((PVar "argv0")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "policyArgSpec")) (EVar "argv0"))) (DoExpr (EApp (EVar "runCheckPolicyArgs") (EApp (EApp (EApp (EVar "PolicyArgs") (EApp (EVar "firstPositional") (EVar "a"))) (EApp (EApp (EVar "optDefault") (EApp (EApp (EVar "lastValue") (ELit (LString "--allow"))) (EVar "a"))) (ELit (LString "Cache,Log")))) (EApp (EApp (EVar "optDefault") (EApp (EApp (EVar "lastValue") (ELit (LString "--fn"))) (EVar "a"))) (ELit (LString "transform"))))))))
(DTypeSig false "firstPositional" (TyFun (TyCon "Args") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "firstPositional" ((PVar "a")) (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList) () (EVar "None")) (arm (PCons (PVar "f") PWild) () (EApp (EVar "Some") (EVar "f")))))
(DTypeSig false "optDefault" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "optDefault" ((PCon "Some" (PVar "v")) PWild) (EVar "v"))
(DFunDef false "optDefault" ((PCon "None") (PVar "d")) (EVar "d"))
(DTypeSig false "runCheckPolicyArgs" (TyFun (TyCon "PolicyArgs") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckPolicyArgs" ((PCon "PolicyArgs" (PCon "None") PWild PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))
(DFunDef false "runCheckPolicyArgs" ((PCon "PolicyArgs" (PCon "Some" (PVar "target")) (PVar "allow") (PVar "fn"))) (EMatch (EApp (EApp (EVar "analyzeTarget") (EVar "target")) (EVar "fn")) (arm (PCon "Err" (PVar "diags")) ((GBool (EBinOp "==" (EVar "diags") (EBinOp "++" (EBinOp "++" (ELit (LString "no '")) (EApp (EVar "display") (EVar "fn"))) (ELit (LString "' entry found")))))) (EApp (EVar "dieMsg") (EBinOp "++" (ELit (LString "rejected. ")) (EVar "diags")))) (arm (PCon "Err" (PVar "diags")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. compiler analysis failed before policy evaluation; `medaka check ")) (EApp (EVar "display") (EVar "target"))) (ELit (LString "` reports:"))))) (DoExpr (EApp (EVar "dieMsg") (EVar "diags"))))) (arm (PCon "Ok" (PVar "analysis")) () (EMatch (EApp (EApp (EApp (EVar "runCheckPolicy") (EVar "analysis")) (EVar "allow")) (EVar "fn")) (arm (PCon "PolicyReject" (PVar "report")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStr") (EVar "report"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "PolicyAccept" (PVar "header") (PVar "sample")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "header"))) (DoExpr (EApp (EVar "putStr") (EApp (EVar "sample") (ELit LUnit))))))))))
(DTypeSig false "analyzeTarget" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EntryAnalysis"))))))
(DFunDef false "analyzeTarget" ((PVar "target") (PVar "fn")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "carryTargetProfile") (EVar "None")) (EVar "target"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "prelude") (EApp (EVar "orExit") (EApp (EVar "readPreludeSources") (EVar "stdlibDir")))) (DoLet false false (PVar "tsrc") (EApp (EVar "orExit") (EApp (EVar "readSource") (EVar "target")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeLoaded") (EVar "prelude")) (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "fn")) (EVar "modsWithPath")))))))
(DTypeSig false "analyzeLoaded" (TyFun (TyCon "PreludeInputs") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EntryAnalysis"))))))))))
(DFunDef false "analyzeLoaded" ((PVar "prelude") (PVar "target") (PVar "roots") (PVar "stdlibDir") (PVar "fn") (PVar "modsWithPath")) (EBlock (DoLet false false (PVar "rsrc") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (DoLet false false (PVar "csrc") (EFieldAccess (EVar "prelude") "pnCoreSrc")) (DoLet false false (PVar "mods") (EApp (EApp (EVar "map") (EVar "dropPathTriple")) (EVar "modsWithPath"))) (DoLet false false (PVar "pathMap") (EApp (EApp (EVar "map") (EVar "modIdToPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PVar "rtD") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (DoLet false false (PVar "coreD") (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (DoLet false false (PVar "modsD") (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false PWild (EApp (EApp (EVar "takeShippedPrelude") (EVar "unstaged")) (EVar "prelude"))) (DoLet false false (PVar "front") (EApp (EApp (EApp (EVar "frontEnd") (EApp (EVar "stdlibExportsReader") (EVar "stdlibDir"))) (ELam ((PVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProgramReport") (EFieldAccess (EVar "d") "fdInputs")) (EApp (EApp (EVar "valueMainCandidate") (EVar "coreD")) (EVar "modsD"))) (EVar "None")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD")))) (ERecordCreate "FrontInput" ((fa "fiInputs" (ERecordUpdate (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "False")) (EListLit)) ((fa "diManifestRequests" (EListLit (EApp (EApp (EVar "EntryOverPrelude") (EVar "fn")) (EVar "HostInvocation")))) (fa "diPreludeKey" (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EVar "rsrc")) (EVar "csrc"))))))) (fa "fiAllowInternal" (EVar "False")) (fa "fiTrusted" (EVar "trusted")) (fa "fiRuntimeSrc" (EVar "rsrc")) (fa "fiCoreSrc" (EVar "csrc")) (fa "fiPolicy" (EVar "NeverDriveRejected")) (fa "fiProgram" (EApp (EApp (EVar "FrontGraph") (EVar "modsWithPath")) (EVar "modsD"))))))) (DoExpr (EMatch (EFieldAccess (EVar "front") "foDriven") (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "ppDiagBuckets") (EFieldAccess (EVar "front") "foDiags")))) (arm (PCon "Some" (PVar "analysis")) () (EBlock (DoLet false false (PVar "residual") (EFieldAccess (EFieldAccess (EVar "analysis") "eaElab") "erResidual")) (DoExpr (EMatch (EApp (EVar "locatedProjectDiags") (EFieldAccess (EVar "front") "foDiags")) (arm (PTuple (PCon "Some" (PVar "errText")) PWild PWild) () (EApp (EVar "Err") (EVar "errText"))) (arm (PTuple (PCon "None") PWild PWild) () (EIf (EApp (EVar "isNone") (EFieldAccess (EFieldAccess (EVar "front") "foReport") "trChecked")) (EMatch (EFieldAccess (EFieldAccess (EVar "front") "foReport") "trResidual") (arm (PAs "missing" (PCons PWild PWild)) ((GBool (EApp (EApp (EVar "all") (ELam ((PVar "p")) (EBinOp "==" (EApp (EVar "tcCode") (EApp (EVar "snd") (EVar "p"))) (EVar "TManifestEntry")))) (EVar "missing")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "no '")) (EApp (EVar "display") (EVar "fn"))) (ELit (LString "' entry found"))))) (arm PWild () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "residualOrGeneric") (EVar "pathMap")) (EVar "target")) (EVar "residual"))))) (EApp (EVar "Ok") (EVar "analysis"))))))))))))
(DTypeSig false "manifestHelpText" (TyCon "String"))
(DFunDef false "manifestHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka manifest — Emit a module's verified capability manifest as TOML\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka manifest <file.mdk> [--fn name]\n")) (ELit (LString "\n")) (ELit (LString "  --fn name  the function whose inferred effect row is emitted\n")) (ELit (LString "             (default: main)\n")) (ELit (LString "\n")) (ELit (LString "Prints a [package.capabilities] TOML block: one entry per effect label\n")) (ELit (LString "in the function's inferred effect row (a prefix-param becomes a string\n")) (ELit (LString "value; a Unit/top param becomes `true`).\n")))))
(DTypeSig false "manifestArgSpec" (TyCon "ArgSpec"))
(DFunDef false "manifestArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "manifest"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--fn")))) (ELit (LString "NAME"))) (ELit (LString "the function whose effect row is emitted")))))))
(DTypeSig false "runManifestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runManifestCmd" ((PVar "argv0")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "manifestArgSpec")) (EVar "argv0"))) (DoExpr (EApp (EVar "runManifestArgs") (EApp (EApp (EVar "ManifestArgs") (EApp (EVar "firstPositional") (EVar "a"))) (EApp (EApp (EVar "optDefault") (EApp (EApp (EVar "lastValue") (ELit (LString "--fn"))) (EVar "a"))) (ELit (LString "main"))))))))
(DTypeSig false "runManifestArgs" (TyFun (TyCon "ManifestArgs") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runManifestArgs" ((PCon "ManifestArgs" (PCon "None") PWild)) (EApp (EVar "dieMsg") (ELit (LString "usage: medaka manifest <file.mdk> [--fn name]"))))
(DFunDef false "runManifestArgs" ((PCon "ManifestArgs" (PCon "Some" (PVar "target")) (PVar "fn"))) (EMatch (EApp (EApp (EVar "analyzeTarget") (EVar "target")) (EVar "fn")) (arm (PCon "Err" (PVar "diags")) () (EApp (EVar "dieMsg") (EVar "diags"))) (arm (PCon "Ok" (PVar "analysis")) () (EMatch (EApp (EApp (EVar "runManifest") (EVar "analysis")) (EVar "fn")) (arm (PCon "Ok" (PVar "toml")) () (EApp (EVar "putStr") (EVar "toml"))) (arm (PCon "Err" (PVar "refusal")) () (EApp (EVar "dieMsg") (EVar "refusal")))))))
(DTypeSig false "lintArgSpec" (TyCon "ArgSpec"))
(DFunDef false "lintArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "lint"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--fix")))) (ELit (LString "rewrite fixable findings in place"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--unsafe-fixes")))) (ELit (LString "with --fix: also apply fixes that may change behaviour"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the structured-diagnostics envelope"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--cache")))) (ELit (LString "reuse per-file results for unchanged files"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--disable")))) (ELit (LString "r1,r2,..."))) (ELit (LString "suppress findings from the named rules"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--only")))) (ELit (LString "r1,..."))) (ELit (LString "keep only findings from the named rules"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--deny")))) (ELit (LString "r1,..."))) (ELit (LString "promote findings from the named rules to error"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--baseline")))) (ELit (LString "<file>"))) (ELit (LString "error only where a file's per-rule count exceeds its row in <file>"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--write-baseline")))) (ELit (LString "<file>"))) (ELit (LString "regenerate <file> from this run instead of reporting"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--list-rules")))) (ELit (LString "list every rule with its metadata"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--markdown")))) (ELit (LString "with --list-rules: render docs/ops/LINT-RULES.md"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--scope")))) (ELit (LString "universal|internal"))) (ELit (LString "with --list-rules: keep one scope"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--ratchet")))) (ELit (LString "gated|baselined"))) (ELit (LString "with --list-rules: keep one ratchet"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--tier")))) (ELit (LString "file|cross"))) (ELit (LString "with --list-rules: keep one rule tier"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--names")))) (ELit (LString "with --list-rules: print only the rule names"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--explain")))) (ELit (LString "<rule>"))) (ELit (LString "print a rule's summary and documentation"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--internal")))) (ELit (LString "run the internal-scope rules on every target, manifest or not")))))))
(DTypeSig false "runLintCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLintCmd" ((PVar "argv0")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "lintArgSpec")) (EVar "argv0"))) (DoExpr (EIf (EApp (EApp (EVar "flag") (ELit (LString "--list-rules"))) (EVar "a")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "assertRegistryViewFlags") (ELit (LString "--list-rules"))) (EVar "listRulesBannedFlags")) (EVar "a"))) (DoExpr (EApp (EVar "runLintListRules") (EVar "a")))) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "flagValue") (ELit (LString "--explain"))) (EVar "a"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "assertRegistryViewFlags") (ELit (LString "--explain"))) (EVar "explainBannedFlags")) (EVar "a"))) (DoExpr (EApp (EVar "runLintExplain") (EVar "a")))) (EBlock (DoLet false false PWild (EApp (EVar "assertNoListOnlyFlags") (EVar "a"))) (DoExpr (EApp (EVar "runLintTargets") (EVar "a")))))))))
(DTypeSig false "lintRunFlags" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "lintRunFlags" () (EListLit (ELit (LString "--fix")) (ELit (LString "--unsafe-fixes")) (ELit (LString "--cache")) (ELit (LString "--internal")) (ELit (LString "--disable")) (ELit (LString "--only")) (ELit (LString "--deny")) (ELit (LString "--baseline")) (ELit (LString "--write-baseline"))))
(DTypeSig false "listRulesBannedFlags" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "listRulesBannedFlags" () (EBinOp "++" (EListLit (ELit (LString "--explain"))) (EVar "lintRunFlags")))
(DTypeSig false "explainBannedFlags" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "explainBannedFlags" () (EBinOp "++" (EListLit (ELit (LString "--json")) (ELit (LString "--markdown")) (ELit (LString "--names")) (ELit (LString "--scope")) (ELit (LString "--ratchet")) (ELit (LString "--tier"))) (EVar "lintRunFlags")))
(DTypeSig false "flagGiven" (TyFun (TyCon "Args") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "flagGiven" ((PVar "a") (PVar "n")) (EBinOp "||" (EApp (EApp (EVar "flag") (EVar "n")) (EVar "a")) (EApp (EVar "isSome") (EApp (EApp (EVar "flagValue") (EVar "n")) (EVar "a")))))
(DTypeSig false "assertRegistryViewFlags" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "assertRegistryViewFlags" ((PVar "mode") (PVar "banned") (PVar "a")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EVar "filter") (EApp (EVar "flagGiven") (EVar "a"))) (EVar "banned"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "isEmpty") (EFieldAccess (EVar "a") "positionals"))) (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EVar "display") (EVar "mode"))) (ELit (LString " takes no target paths")))) (EIf (EApp (EVar "not") (EApp (EVar "isEmpty") (EVar "bad"))) (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "bad")))) (ELit (LString " cannot be combined with "))) (EApp (EVar "display") (EVar "mode"))) (ELit (LString "")))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "mode") (ELit (LString "--list-rules"))) (EApp (EApp (EVar "flag") (ELit (LString "--markdown"))) (EVar "a"))) (EApp (EVar "assertMarkdownTakesNoFilter") (EVar "a")) (ELit LUnit)))))))
(DTypeSig false "assertMarkdownTakesNoFilter" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertMarkdownTakesNoFilter" ((PVar "a")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EVar "filter") (EApp (EVar "flagGiven") (EVar "a"))) (EListLit (ELit (LString "--json")) (ELit (LString "--names")) (ELit (LString "--scope")) (ELit (LString "--ratchet")) (ELit (LString "--tier"))))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "isEmpty") (EVar "bad"))) (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "bad")))) (ELit (LString " cannot be combined with --markdown")))) (ELit LUnit)))))
(DTypeSig false "assertNoListOnlyFlags" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertNoListOnlyFlags" ((PVar "a")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "flag") (ELit (LString "--markdown"))) (EVar "a")) (EApp (EApp (EVar "flag") (ELit (LString "--names"))) (EVar "a"))) (EApp (EVar "isSome") (EApp (EApp (EVar "flagValue") (ELit (LString "--scope"))) (EVar "a")))) (EApp (EVar "isSome") (EApp (EApp (EVar "flagValue") (ELit (LString "--ratchet"))) (EVar "a")))) (EApp (EVar "isSome") (EApp (EApp (EVar "flagValue") (ELit (LString "--tier"))) (EVar "a")))) (EApp (EVar "dieMsg") (ELit (LString "medaka lint: --markdown/--names/--scope/--ratchet/--tier require --list-rules"))) (ELit LUnit)))
(DTypeSig false "runLintListRules" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLintListRules" ((PVar "a")) (EIf (EApp (EApp (EVar "flag") (ELit (LString "--markdown"))) (EVar "a")) (EApp (EVar "putStr") (EVar "rulesPageMarkdown")) (EBlock (DoLet false false (PVar "picked") (EApp (EApp (EApp (EVar "selectRuleRows") (EApp (EApp (EVar "flagValue") (ELit (LString "--scope"))) (EVar "a"))) (EApp (EApp (EVar "flagValue") (ELit (LString "--ratchet"))) (EVar "a"))) (EApp (EApp (EVar "flagValue") (ELit (LString "--tier"))) (EVar "a")))) (DoExpr (EMatch (EVar "picked") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "rows")) () (EIf (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a")) (EApp (EVar "putStr") (EApp (EVar "renderRuleRowsJson") (EVar "rows"))) (EIf (EApp (EApp (EVar "flag") (ELit (LString "--names"))) (EVar "a")) (EApp (EVar "putStr") (EApp (EVar "renderRuleRowsNames") (EVar "rows"))) (EApp (EVar "putStr") (EApp (EVar "renderRuleRowsText") (EVar "rows")))))))))))
(DTypeSig false "runLintExplain" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLintExplain" ((PVar "a")) (EMatch (EApp (EApp (EVar "optDefault") (EApp (EApp (EVar "flagValue") (ELit (LString "--explain"))) (EVar "a"))) (ELit (LString ""))) (arm (PLit (LString "")) () (EApp (EVar "dieMsg") (ELit (LString "medaka lint: --explain needs a rule name")))) (arm (PVar "name") () (EMatch (EApp (EVar "explainRule") (EVar "name")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "text")) () (EApp (EVar "putStrLn") (EVar "text")))))))
(DTypeSig false "runLintTargets" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLintTargets" ((PVar "a")) (EBlock (DoLet false false (PVar "disableNames") (EApp (EApp (EVar "lintNamesOf") (ELit (LString "--disable"))) (EVar "a"))) (DoLet false false (PVar "onlyNames") (EApp (EApp (EVar "lintNamesOf") (ELit (LString "--only"))) (EVar "a"))) (DoLet false false (PVar "denyNames") (EApp (EApp (EVar "lintNamesOf") (ELit (LString "--deny"))) (EVar "a"))) (DoLet false false PWild (EApp (EVar "assertLintRuleNames") (EBinOp "++" (EBinOp "++" (EVar "disableNames") (EVar "onlyNames")) (EVar "denyNames")))) (DoLet false false (PVar "fixMode") (EApp (EApp (EVar "flag") (ELit (LString "--fix"))) (EVar "a"))) (DoLet false false PWild (EApp (EVar "assertUnsafeFixesNeedFix") (EVar "a"))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a"))) (DoLet false false (PVar "baselineArg") (EApp (EApp (EVar "flagValue") (ELit (LString "--baseline"))) (EVar "a"))) (DoLet false false (PVar "writeBaselineArg") (EApp (EApp (EVar "flagValue") (ELit (LString "--write-baseline"))) (EVar "a"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "assertBaselineFlagsCoherent") (EVar "baselineArg")) (EVar "writeBaselineArg")) (EVar "fixMode"))) (DoLet false false (PVar "fileArgs") (EFieldAccess (EVar "a") "positionals")) (DoLet false false PWild (EApp (EVar "assertLintTargetsExist") (EVar "fileArgs"))) (DoLet false false (PVar "files") (EApp (EVar "resolveLintTargets") (EVar "fileArgs"))) (DoLet false false PWild (EApp (EVar "assertLintTargetsNonEmpty") (EVar "files"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "assertInternalRulesReachable") (EApp (EApp (EVar "flag") (ELit (LString "--internal"))) (EVar "a"))) (EBinOp "++" (EVar "onlyNames") (EVar "denyNames"))) (EVar "files"))) (DoLet false false (PVar "indexResult") (EApp (EApp (EApp (EApp (EVar "indexForRun") (EApp (EApp (EVar "flag") (ELit (LString "--cache"))) (EVar "a"))) (EVar "onlyNames")) (EVar "disableNames")) (EVar "files"))) (DoExpr (EMatch (EVar "indexResult") (arm (PCon "Err" (PRec "StdlibIndexError" ((rf "path" None) (rf "source" None) (rf "diagnostic" None)) false)) () (EBlock (DoExpr (EIf (EVar "jsonMode") (EApp (EVar "putStr") (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "path") (EVar "source") (EListLit (EVar "diagnostic")))))) (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "source")) (EVar "path")) (EVar "diagnostic"))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "stdlibIdx")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runLintWithIndex") (EVar "stdlibIdx")) (EVar "a")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "fixMode")) (EVar "jsonMode")) (EVar "baselineArg")) (EVar "writeBaselineArg")) (EVar "files")))))))
(DTypeSig false "runLintWithIndex" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Args") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))))))))))
(DFunDef false "runLintWithIndex" ((PVar "stdlibIdx") (PVar "a") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "fixMode") (PVar "jsonMode") (PVar "baselineArg") (PVar "writeBaselineArg") (PVar "files")) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoLet false false (PVar "baseCtx") (EApp (EApp (EVar "loadLintBaselineCtx") (EVar "cwd")) (EVar "baselineArg"))) (DoLet false false (PVar "internalFlag") (EApp (EApp (EVar "flag") (ELit (LString "--internal"))) (EVar "a"))) (DoExpr (EIf (EApp (EVar "isSome") (EVar "writeBaselineArg")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runLintWriteBaselineCmd") (EVar "stdlibIdx")) (EVar "internalFlag")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cwd")) (EApp (EApp (EVar "optDefault") (EVar "writeBaselineArg")) (ELit (LString "")))) (EVar "files")) (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runLintJsonCmd") (EVar "stdlibIdx")) (EVar "internalFlag")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "files")) (EBlock (DoLet false false (PVar "multiFile") (EMatch (EVar "files") (arm (PCons PWild (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False")))) (DoLet false false (PVar "cacheCtx") (EApp (EApp (EVar "lintCacheCtx") (EApp (EApp (EVar "flag") (ELit (LString "--cache"))) (EVar "a"))) (EVar "fixMode"))) (DoLet false false (PVar "run") (ERecordCreate "LintRun" ((fa "lrInternal" (EVar "internalFlag")) (fa "lrFix" (EVar "fixMode")) (fa "lrUnsafe" (EApp (EApp (EVar "flag") (ELit (LString "--unsafe-fixes"))) (EVar "a"))) (fa "lrMulti" (EVar "multiFile"))))) (DoLet false false (PTuple (PVar "perFileErr") (PVar "entries")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "stdlibIdx")) (EVar "run")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "files")) (EVar "False"))) (DoLet false false (PVar "crossErr") (EIf (EBinOp "&&" (EVar "multiFile") (EApp (EVar "not") (EVar "fixMode"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProjectReport") (EVar "stdlibIdx")) (EVar "internalFlag")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "entries")) (EVar "False"))) (DoLet false false PWild (EMatch (EVar "cacheCtx") (arm (PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) () (EApp (EApp (EApp (EVar "storeEntries") (EVar "cacheDir")) (EVar "stamp")) (EVar "entries"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EIf (EBinOp "||" (EVar "perFileErr") (EVar "crossErr")) (EApp (EVar "stageExit") (ELit (LInt 1))) (ELit LUnit)))))))))
(DTypeSig false "assertBaselineFlagsCoherent" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "assertBaselineFlagsCoherent" ((PVar "baselineArg") (PVar "writeArg") (PVar "fixMode")) (EIf (EBinOp "&&" (EApp (EVar "isSome") (EVar "baselineArg")) (EApp (EVar "isSome") (EVar "writeArg"))) (EApp (EVar "dieMsg") (ELit (LString "medaka lint: --baseline and --write-baseline are mutually exclusive"))) (EIf (EBinOp "&&" (EApp (EVar "isSome") (EVar "writeArg")) (EVar "fixMode")) (EApp (EVar "dieMsg") (ELit (LString "medaka lint: --write-baseline cannot be combined with --fix"))) (EIf (EBinOp "&&" (EApp (EVar "isSome") (EVar "baselineArg")) (EVar "fixMode")) (EApp (EVar "dieMsg") (ELit (LString "medaka lint: --baseline cannot be combined with --fix"))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "assertUnsafeFixesNeedFix" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertUnsafeFixesNeedFix" ((PVar "a")) (EIf (EBinOp "&&" (EApp (EApp (EVar "flag") (ELit (LString "--unsafe-fixes"))) (EVar "a")) (EApp (EVar "not") (EApp (EApp (EVar "flag") (ELit (LString "--fix"))) (EVar "a")))) (EApp (EVar "dieMsg") (ELit (LString "medaka lint: --unsafe-fixes requires --fix"))) (ELit LUnit)))
(DTypeSig false "loadLintBaselineCtx" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline")))))))
(DFunDef false "loadLintBaselineCtx" (PWild (PCon "None")) (EVar "None"))
(DFunDef false "loadLintBaselineCtx" ((PVar "cwd") (PCon "Some" (PVar "path"))) (EMatch (EApp (EVar "readLintBaseline") (EVar "path")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "None")))) (arm (PCon "Ok" (PVar "base")) () (EApp (EVar "Some") (ETuple (EVar "cwd") (EVar "base"))))))
(DTypeSig false "runLintWriteBaselineCmd" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))))))))
(DFunDef false "runLintWriteBaselineCmd" ((PVar "idx") (PVar "internalFlag") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "cwd") (PVar "out") (PVar "files")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "idx")) (EVar "internalFlag")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "None")) (EVar "files"))) (DoLet false false (PVar "parseFailures") (EApp (EApp (EVar "flatMap") (EVar "lintBaselineParseFailures")) (EVar "triples"))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "parseFailures")) (ELit (LInt 0))) (EBlock (DoExpr (EApp (EVar "emitWarningLines") (EVar "parseFailures"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "perFile") (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EApp (EVar "baselineFileCodes") (EVar "cwd")) (EVar "t")))) (EVar "triples"))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "out")) (EApp (EVar "renderLintBaseline") (EVar "perFile"))) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: cannot write `")) (EApp (EVar "display") (EVar "out"))) (ELit (LString "`: "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: wrote ")) (EApp (EVar "display") (EVar "out"))) (ELit (LString " from "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "files"))))) (ELit (LString " file(s)"))))))))))))
(DTypeSig false "lintBaselineParseFailures" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lintBaselineParseFailures" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path"))) (EApp (EApp (EVar "filter") (EVar "isLintParseDiagnostic")) (EVar "diags"))))
(DTypeSig false "isLintParseDiagnostic" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isLintParseDiagnostic" ((PCon "Diag" PWild (PVar "code") PWild PWild PWild PWild)) (EApp (EVar "diagIdIsSyntax") (EVar "code")))
(DTypeSig false "lintNamesOf" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "lintNamesOf" ((PVar "nm") (PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (EVar "nm")) (EVar "a")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "splitLintNames") (EVar "v")))))
(DTypeSig false "assertLintRuleNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertLintRuleNames" ((PVar "names")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "allRuleNames"))))) (EVar "names"))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "bad")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: unknown rule ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "bad")))) (ELit (LString " (known: "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "allRuleNames")))) (ELit (LString ")"))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))))))
(DTypeSig false "assertInternalRulesReachable" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "assertInternalRulesReachable" ((PVar "internalFlag") (PVar "names") (PVar "files")) (EMatch (EApp (EApp (EApp (EVar "inactiveInternalRuleUse") (EVar "internalFlag")) (EVar "names")) (EVar "files")) (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "assertLintTargetsNonEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertLintTargetsNonEmpty" ((PCons PWild PWild)) (ELit LUnit))
(DFunDef false "assertLintTargetsNonEmpty" ((PList)) (EApp (EVar "dieMsg") (ELit (LString "medaka lint: no .mdk files found"))))
(DTypeSig false "assertLintTargetsExist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertLintTargetsExist" ((PList)) (ELit LUnit))
(DFunDef false "assertLintTargetsExist" ((PVar "targets")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EVar "filter") (ELam ((PVar "t")) (EApp (EVar "not") (EApp (EVar "lintTargetExists") (EVar "t"))))) (EVar "targets"))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "missing")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: these targets do not exist:")))) (DoExpr (EApp (EVar "dieMsg") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (EVar "missing"))))))))))
(DTypeSig false "assertSnapshotTargetsExist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertSnapshotTargetsExist" ((PVar "files")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EVar "filter") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "f"))))) (EVar "files"))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "missing")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: these targets do not exist:")))) (DoExpr (EApp (EVar "dieMsg") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (EVar "missing"))))))))))
(DTypeSig false "assertBlessIsScoped" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "assertBlessIsScoped" ((PVar "blessOn") (PVar "targets")) (EIf (EBinOp "||" (EApp (EVar "not") (EVar "blessOn")) (EApp (EVar "not") (EApp (EVar "isEmpty") (EVar "targets")))) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: --bless requires explicit targets; there is no whole-suite bless")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "  name what you are approving, such as:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "    medaka snapshot --bless --out test/snapshots/compiler compiler/frontend/lexer.mdk")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "  or, family-aware: sh test/snapshot_bless.sh --bless compiler/frontend/lexer.mdk")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))))
(DTypeSig false "snapshotHelpText" (TyCon "String"))
(DFunDef false "snapshotHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka snapshot — Per-stage snapshot tests\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka snapshot [--check | --new | --bless] <paths...>\n")) (ELit (LString "                  [--out <dir>] [--stages <a,b,...>] [--isolate]\n")) (ELit (LString "\n")) (ELit (LString "One mode is REQUIRED, and the three are mutually exclusive:\n")) (ELit (LString "  --check   compare against the existing snapshot; write nothing\n")) (ELit (LString "  --new     create a MISSING snapshot; never touch an existing one\n")) (ELit (LString "  --bless   rewrite an EXISTING snapshot; never create one; requires\n")) (ELit (LString "            explicit targets (no whole-suite bless)\n")) (ELit (LString "\n")) (ELit (LString "  --out <dir>       snapshot directory (default derived from MEDAKA_ROOT)\n")) (ELit (LString "  --root <dir>      compiler/stdlib root, overriding MEDAKA_ROOT\n")) (ELit (LString "  --stages a,b,...  restrict to the named stages (default: every stage)\n")) (ELit (LString "  --isolate         run one process per fixture (debug aid for a crasher)\n")) (ELit (LString "\n")) (ELit (LString "  --worker          INTERNAL, not for direct use: the supervisor re-spawns\n")) (ELit (LString "                    this binary with --worker to render one batch in a child\n")) (ELit (LString "                    process, so a fixture that crashes the renderer does not\n")) (ELit (LString "                    take the run down. Documented because the verb parses it\n")) (ELit (LString "                    (an undocumented arm is a lie by omission), not because\n")) (ELit (LString "                    you should type it.\n")) (ELit (LString "\n")) (ELit (LString "A path may be a file or directory (recursively expanded).\n")))))
(DTypeSig false "snapshotArgSpec" (TyCon "ArgSpec"))
(DFunDef false "snapshotArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "snapshot"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--check")))) (ELit (LString "compare against the existing snapshot; write nothing"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--new")))) (ELit (LString "create a MISSING snapshot; never touch an existing one"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--bless")))) (ELit (LString "rewrite an EXISTING snapshot; requires explicit targets"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--isolate")))) (ELit (LString "run one process per fixture"))) (EApp (EVar "internal") (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--worker")))) (ELit (LString "INTERNAL: render one batch in a child process")))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--out")))) (ELit (LString "DIR"))) (ELit (LString "snapshot directory"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--root")))) (ELit (LString "DIR"))) (ELit (LString "compiler/stdlib root, overriding MEDAKA_ROOT"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--stages")))) (ELit (LString "a,b,..."))) (ELit (LString "restrict to the named stages")))))))
(DTypeSig false "runSnapshotCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runSnapshotCmd" ((PVar "argv0")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "snapshotArgSpec")) (EVar "argv0"))) (DoLet false false (PVar "root") (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--root"))) (EVar "a")) (arm (PCon "Some" (PVar "r")) () (EVar "r")) (arm (PCon "None") () (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))))) (DoLet false false (PVar "sel") (EApp (EVar "snapshotStages") (EVar "a"))) (DoLet false false (PVar "targets") (EFieldAccess (EVar "a") "positionals")) (DoLet false false PWild (EApp (EApp (EVar "assertBlessIsScoped") (EApp (EApp (EVar "flag") (ELit (LString "--bless"))) (EVar "a"))) (EVar "targets"))) (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoLet false false PWild (EApp (EVar "assertSnapshotTargetsExist") (EVar "files"))) (DoExpr (EIf (EApp (EVar "isEmpty") (EVar "files")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka snapshot [--check|--new|--bless] [--out <dir>] [--stages <a,b,…>] <paths...>")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))) (EIf (EApp (EApp (EVar "flag") (ELit (LString "--worker"))) (EVar "a")) (EApp (EApp (EApp (EVar "runSnapshotWorker") (EVar "root")) (EVar "sel")) (EVar "files")) (EMatch (EApp (EVar "snapshotMode") (EVar "a")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: pass --check, --new or --bless; exactly one mode is required")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Some" (PVar "mode")) () (EBlock (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSnapshotSupervisor") (EVar "root")) (EVar "mode")) (EApp (EApp (EVar "flag") (ELit (LString "--isolate"))) (EVar "a"))) (EApp (EApp (EVar "flagValue") (ELit (LString "--out"))) (EVar "a"))) (EVar "sel")) (EVar "files"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "stageExit") (ELit (LInt 1)))))))))))))
(DTypeSig false "snapshotMode" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "SnapMode")))))
(DFunDef false "snapshotMode" ((PVar "a")) (EBlock (DoLet false false (PVar "modes") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EApp (EVar "flag") (EVar "f")) (EVar "a")))) (EListLit (ELit (LString "--check")) (ELit (LString "--new")) (ELit (LString "--bless"))))) (DoExpr (EMatch (EVar "modes") (arm (PList (PLit (LString "--check"))) () (EApp (EVar "Some") (EVar "SnapCheck"))) (arm (PList (PLit (LString "--new"))) () (EApp (EVar "Some") (EVar "SnapNew"))) (arm (PList (PLit (LString "--bless"))) () (EApp (EVar "Some") (EVar "SnapBless"))) (arm (PList) () (EVar "None")) (arm (PVar "many") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka snapshot: ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "many")))) (ELit (LString " are mutually exclusive; pass one"))))) (DoLet false false PWild (EApp (EVar "stageExit") (ELit (LInt 1)))) (DoExpr (EVar "None"))))))))
(DTypeSig false "snapshotStages" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "snapshotStages" ((PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--stages"))) (EVar "a")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "spec")) () (EMatch (EApp (EVar "parseStages") (EVar "spec")) (arm (PCon "Ok" (PVar "names")) () (EVar "names")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka snapshot: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "stageExit") (ELit (LInt 1)))) (DoExpr (EListLit))))))))
(DTypeSig false "hasSlash" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasSlash" ((PVar "s")) (EApp (EApp (EVar "hasSlashFrom") (EVar "s")) (EApp (EVar "stringLength") (EVar "s"))))
(DTypeSig false "hasSlashFrom" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "hasSlashFrom" (PWild (PLit (LInt 0))) (EVar "False"))
(DFunDef false "hasSlashFrom" ((PVar "s") (PVar "i")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "s")) (ELit (LString "/"))) (EApp (EApp (EVar "hasSlashFrom") (EVar "s")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "dirOf2" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOf2" ((PVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo2" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo2" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo2" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "replArgSpec" (TyCon "ArgSpec"))
(DFunDef false "replArgSpec" () (EApp (EApp (EVar "spec") (ELit (LString "repl"))) (EListLit)))
(DTypeSig false "replUsageLine" (TyCon "String"))
(DFunDef false "replUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka repl — Start the interactive REPL\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka repl     Start an interactive session that reads expressions\n")) (ELit (LString "                 from stdin, evaluates them, and prints results until\n")) (ELit (LString "                 stdin closes (EOF) or you enter :quit.\n")))))
(DTypeSig false "runReplCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runReplCmd" ((PList)) (EBlock (DoLet false false PWild (EApp (EApp (EVar "carryTargetProfile") (EVar "None")) (EBinOp "++" (EApp (EVar "canonicalizePath") (ELit (LString "."))) (ELit (LString "/repl"))))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "r") (EApp (EApp (EVar "andThen") (EApp (EVar "readPreludeSources") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib"))))) (ELam ((PVar "prelude")) (ELet false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (ELet false (PVar "preludeDecls") (EApp (EVar "desugaredPrelude") (EFieldAccess (EVar "prelude") "pnCoreSrc")) (ELet false PWild (EApp (EApp (EVar "initSession") (EVar "runtimeDecls")) (EVar "preludeDecls")) (ELet false PWild (EApp (EApp (EVar "takeShippedPrelude") (EVar "unstaged")) (EVar "prelude")) (EApp (EVar "Ok") (EApp (EVar "replLoop") (ELit LUnit)))))))))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "v")) () (EVar "v"))))))
(DFunDef false "runReplCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "runReplCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "runReplCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "unknownFlagMessage") (EVar "replArgSpec")) (EVar "bad")))) (DoExpr (EApp (EVar "dieMsg") (EVar "replUsageLine")))))
(DTypeSig false "lspArgSpec" (TyCon "ArgSpec"))
(DFunDef false "lspArgSpec" () (EApp (EApp (EVar "spec") (ELit (LString "lsp"))) (EListLit)))
(DTypeSig false "lspUsageLine" (TyCon "String"))
(DFunDef false "lspUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka lsp — Run the Language Server Protocol server over stdio\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka lsp     Start the server; it reads JSON-RPC requests from stdin\n")) (ELit (LString "                 and writes responses to stdout until stdin closes (EOF).\n")) (ELit (LString "                 This is the normal, correct behavior for an LSP stdio\n")) (ELit (LString "                 server — it is not supposed to be interactive.\n")))))
(DTypeSig false "runLspCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLspCmd" ((PList)) (EApp (EVar "runLspServerFromEnv") (ELit LUnit)))
(DFunDef false "runLspCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "runLspCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "runLspCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "unknownFlagMessage") (EVar "lspArgSpec")) (EVar "bad")))) (DoExpr (EApp (EVar "dieMsg") (EVar "lspUsageLine")))))
(DTypeSig false "runLspServerFromEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLspServerFromEnv" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "r") (EApp (EApp (EVar "andThen") (EApp (EVar "readPreludeSources") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib"))))) (ELam ((PVar "prelude")) (ELet false PWild (EApp (EVar "loadCheckPrelude") (EVar "prelude")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "runServer") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (EFieldAccess (EVar "prelude") "pnCoreSrc")) (EVar "medakaVersion"))))))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "v")) () (EVar "v"))))))
(DTypeSig false "mcpArgSpec" (TyCon "ArgSpec"))
(DFunDef false "mcpArgSpec" () (EApp (EApp (EVar "spec") (ELit (LString "mcp"))) (EListLit)))
(DTypeSig false "mcpUsageLine" (TyCon "String"))
(DFunDef false "mcpUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka mcp — Run the MCP server over stdio (JSON-RPC for agents)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka mcp     Start the server; it reads JSON-RPC requests from stdin\n")) (ELit (LString "                 and writes responses to stdout until stdin closes (EOF).\n")) (ELit (LString "                 This is the normal, correct behavior for an MCP stdio\n")) (ELit (LString "                 server — it is not supposed to be interactive.\n")))))
(DTypeSig false "runMcpCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runMcpCmd" ((PList)) (EApp (EVar "runMcpServerFromEnv") (ELit LUnit)))
(DFunDef false "runMcpCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "mcpUsageLine"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "runMcpCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "mcpUsageLine"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "runMcpCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "unknownFlagMessage") (EVar "mcpArgSpec")) (EVar "bad")))) (DoExpr (EApp (EVar "dieMsg") (EVar "mcpUsageLine")))))
(DTypeSig false "runMcpServerFromEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runMcpServerFromEnv" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "r") (EApp (EApp (EVar "andThen") (EApp (EVar "readPreludeSources") (EVar "stdlibDir"))) (ELam ((PVar "prelude")) (ELet false PWild (EApp (EVar "loadCheckPrelude") (EVar "prelude")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EVar "runMcpServer") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (EFieldAccess (EVar "prelude") "pnCoreSrc")) (EVar "stdlibDir")) (EVar "sourceStalenessVerdict")) (EVar "medakaVersion"))))))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "v")) () (EVar "v"))))))
# MARK
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true) (mem "codeText" false))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "executedMainInputs" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestSelector" true) (mem "InvocationProtocol" true))))
(DUse false (UseGroup ("tools" "check") ((mem "checkModulesReport" false) (mem "entryExhaust" false))))
(DUse false (UseGroup ("tools" "snapshot") ((mem "runSnapshotWorker" false) (mem "runSnapshotSupervisor" false) (mem "parseStages" false) (mem "SnapMode" true))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSourceChecked" false) (mem "FmtMode" true))))
(DUse false (UseGroup ("tools" "gate_cmd") ((mem "gateHelpText" false) (mem "runGateCmd" false))))
(DUse false (UseGroup ("tools" "interface_cmd") ((mem "interfaceHelpText" false) (mem "runInterfaceCmd" false))))
(DUse false (UseGroup ("tools" "new_cmd") ((mem "newProject" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "BuildReport" false) (mem "BuildTarget" true) (mem "ppBuildReport" false) (mem "runBuild" false) (mem "emitRtObj" false) (mem "emitPreludeObj" false) (mem "envOr" false) (mem "defaultMedakaRoot" false) (mem "readPreludeSources" false) (mem "loadPreludeInterface" false) (mem "PreludeInputs" true) (mem "SideFile" true) (mem "staleLine" false) (mem "shippedInputs" false) (mem "FileVerdict" false) (mem "checkPreludeElab" false) (mem "loadPreludeElab" false) (mem "preludeDeclsVerdict" false) (mem "reportStaleLine" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinNl" false) (mem "joinWith" false) (mem "splitNl" false) (mem "startsWith" false) (mem "endsWith" false) (mem "anyList" false) (mem "filterList" false) (mem "contains" false) (mem "sortUniqS" false) (mem "listLen" false) (mem "schemeLineName" false) (mem "stringTrim" false) (mem "lookupAssoc" false))))
(DUse false (UseGroup ("support" "opcount") ((mem "setOpCounting" false) (mem "opSnap" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageCountInit" false) (mem "stageDump" false) (mem "stageExit" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false) (mem "joinPath" false))))
(DUse false (UseGroup ("support" "timer") ((mem "perfEnabled" false) (mem "now" false) (mem "emitPhase" false) (mem "emitPhaseAO" false) (mem "allocSnap" false) (mem "emitTotal" false) (mem "perfArm" false) (mem "emitAbortTotal" false) (mem "perfSinkOn" false) (mem "flushPerfSinkProse" false))))
(DUse false (UseGroup ("list") ((mem "sortOn" false) (mem "head" false))))
(DUse false (UseGroup ("driver" "profile_select") ((mem "manifestProfileOf" false) (mem "carryProjectProfile" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "Backend" true) (mem "buildableNames" false) (mem "lookupProfile" false) (mem "profileBackend" false) (mem "runProfile" false) (mem "selectedProfile" false))))
(DUse false (UseGroup ("tools" "target_check") ((mem "targetRefusal" false) (mem "ppTargetDiag" false) (mem "foldTargetDiags" false))))
(DUse false (UseGroup ("string") ((mem "toInt" false))))
(DUse false (UseGroup ("args") ((mem "ArgSpec" false) (mem "Args" true) (mem "spec" false) (mem "switch" false) (mem "value" false) (mem "internal" false) (mem "parseArgs" false) (mem "flag" false) (mem "flagValue" false) (mem "lastValue" false) (mem "flagValues" false) (mem "unknownFlagMessage" false) (mem "usageExitCode" false) (mem "withStrictDash" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "letBindName" false) (mem "Decl" true) (mem "ExternDecl" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" false) (mem "LetBind" true) (mem "EvTable" false) (mem "EvId" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositions" false) (mem "parseWithPositionsLocated" false) (mem "parseResult" false) (mem "parseLocatedResult" false) (mem "Positions" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "tokenizeWithOffsetPairs" false))))
(DUse false (UseGroup ("frontend" "desugar_cache") ((mem "desugaredPrelude" false) (mem "preludeGeneration" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugarIn" false))))
(DUse false (UseGroup ("tools" "target_parse") ((mem "targetDesugared" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgramFilesLocatedE" false) (mem "stdinEntry" false) (mem "readStdinProgram" false) (mem "stdinReadOverride" false) (mem "readSource" false) (mem "readSourceE" false) (mem "sourceNotUtf8Message" false) (mem "dropPathTriple" false) (mem "modIdToPath" false) (mem "findProjectRoot" false) (mem "findProjectRootOrSelf" false) (mem "entrySearchRoots" false) (mem "projectTrustedMods" false) (mem "stdlibOwnership" false))))
(DUse false (UseGroup ("driver" "front_gate") ((mem "GateAsk" true) (mem "cliStdlibExports" false) (mem "envelopeWithNotes" false) (mem "moduleLoadErrText" false) (mem "ppParseError" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "desugaredModPairs" false) (mem "CheckDrive" true) (mem "CheckDump" true) (mem "frontEnd" false) (mem "checkFrontDrive" false) (mem "FrontProgram" true) (mem "FrontInput" true) (mem "FrontPolicy" true) (mem "FrontOutput" true) (mem "ppDiagCli" false) (mem "ppDiagCliSrc" false) (mem "ppDiagCliLines" false) (mem "renderTcDiags" false) (mem "ppDiagBuckets" false) (mem "stdlibExportsReader" false) (mem "diagOfResError" false) (mem "diagOfTypeError" false) (mem "relDiagPath" false) (mem "srcLinesArr" false) (mem "Diag" true) (mem "DiagId" true) (mem "diagIdIsSyntax" false) (mem "Severity" true) (mem "Severity" true) (mem "cjPosition" false) (mem "cjRange" false) (mem "cjRangeOfLoc" false) (mem "cjDiagnostic" false) (mem "cjFileEntry" false) (mem "cjAllToJson" false) (mem "flushRunEnvelope" false) (mem "pendingStaleNotice" false) (mem "pendingPreludeNotices" false) (mem "readDiagSrc" false) (mem "optField" false) (mem "cjFixJson" false) (mem "mkDiag" false) (mem "checkJsonFileParts" false) (mem "CheckJson" true) (mem "ppCheckJson" false) (mem "cjFoldIntoFile" false) (mem "readFileSafe" false) (mem "diagIsError" false) (mem "diagIsWarn" false) (mem "cohWarnsOfTriple" false) (mem "joinedOrNone" false) (mem "renderTripleErrors" false) (mem "renderTripleWarnings" false) (mem "residualOrGeneric" false) (mem "coherenceWarnCode" false) (mem "runBuildWarnCodes" false) (mem "isCoherenceWarn" false) (mem "mainShapeWarnings" false) (mem "mainEntryError" false) (mem "ppMainEntryError" false))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false) (mem "parse" false "parseJson") (mem "asString" false))))
(DUse false (UseGroup ("types" "publish") ((mem "TcReport" true) (mem "tcCode" false))))
(DUse false (UseGroup ("types" "program_facts") ((mem "ProgramFacts" false) (mem "factsOfChecked" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "TcDiag" false) (mem "driveInputsFor" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveInputs" true) (mem "DriveOutputs" true))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "asyncMainShapeError" false) (mem "shouldAutoPrintMain" false) (mem "valueMainCandidate" false) (mem "executedFromReport" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "evalModulesOutputRunFacts" false) (mem "currentEvalFile" false) (mem "modulePathMap" false) (mem "runJsonMode" false) (mem "pendingRunDiags" false) (mem "progArgsRef" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTest" false) (mem "runTestReport" false) (mem "runTestGradedReport" false) (mem "filterMatchedNothing" false) (mem "testHelpText" false) (mem "testArgSpec" false) (mem "parseTestEngines" false) (mem "parseTestCasesFlag" false) (mem "parseTestIntFlag" false) (mem "runTestOne" false) (mem "cliTestReportOk" false) (mem "cliTestReportJson" false) (mem "cliGradedTestReportOk" false) (mem "cliGradedTestReportJson" false) (mem "checkTestMdkRoster" false) (mem "testFilesGo" false) (mem "runEvalPropsWorker" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "seedPropRng" false) (mem "PropRequest" true))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Engine" true))))
(DUse false (UseGroup ("tools" "repl") ((mem "initSession" false) (mem "replLoop" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "runServer" false))))
(DUse false (UseGroup ("tools" "mcp") ((mem "runMcpServer" false))))
(DUse false (UseGroup ("tools" "doc") ((mem "runDoc" false) (mem "ModuleDoc" false) (mem "computeModuleDoc" false) (mem "docParseError" false) (mem "mdName" false) (mem "renderModulePage" false) (mem "renderIndex" false) (mem "libraryInventoryJson" false) (mem "rebucketLibraryImpls" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "allRules" false) (mem "lintProgram" false) (mem "StdlibIndex" false) (mem "StdlibIndexError" true) (mem "indexForRun" false) (mem "applySuppressions" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMultiDirs" false) (mem "collectDirectives" false) (mem "findingToDiag" false) (mem "Finding" false) (mem "Directive" false) (mem "applyFixes" false) (mem "allRuleNames" false) (mem "applyFindingFilters" false) (mem "applyFindingDeny" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false) (mem "splitLintNames" false))))
(DUse false (UseGroup ("tools" "lint_cache") ((mem "storeEntries" false))))
(DUse false (UseGroup ("tools" "lint_baseline") ((mem "LintBaseline" false) (mem "readLintBaseline" false) (mem "baselineKeyOf" false) (mem "baselineViolations" false) (mem "baselineViolationLine" false) (mem "applyBaselineToFindings" false) (mem "applyBaselineToDiags" false) (mem "baselineDiagViolations" false) (mem "diagCodeOf" false) (mem "findingRuleOf" false) (mem "renderLintBaseline" false))))
(DUse false (UseGroup ("tools" "codemod") ((mem "findCodemod" false) (mem "codemodMk" false) (mem "codemodWarnDecls" false) (mem "codemodListing" false) (mem "codemodSource" false) (mem "CodeMode" true))))
(DUse false (UseGroup ("tools" "lint_cmd") ((mem "explainRule" false) (mem "lintCacheCtx" false) (mem "lintHelpText" false) (mem "renderRuleRowsJson" false) (mem "renderRuleRowsNames" false) (mem "renderRuleRowsText" false) (mem "rulesPageMarkdown" false) (mem "selectRuleRows" false) (mem "runLintJsonCmd" false) (mem "lintFilesToDiagTriples" false) (mem "baselineFileCodes" false) (mem "runProjectReport" false) (mem "resolveLintTargets" false) (mem "lintFilesGo" false) (mem "LintRun" true) (mem "inactiveInternalRuleUse" false))))
(DUse false (UseGroup ("support" "cli_targets") ((mem "lintTargetExists" false) (mem "expandLintTarget" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "runCheckPolicy" false) (mem "PolicyArgs" true) (mem "PolicyOutcome" true) (mem "runManifest" false) (mem "ManifestArgs" true) (mem "analyzeProgramReport" false) (mem "EntryAnalysis" true) (mem "TargetInputs" true))))
(DTypeSig false "medakaVersion" (TyCon "String"))
(DFunDef false "medakaVersion" () (ELit (LString "0.1.0-preview")))
(DTypeSig false "medakaVersionString" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "medakaVersionString" (PWild) (EBlock (DoLet false false (PVar "commit") (EApp (EVar "buildCommit") (ELit LUnit))) (DoLet false false (PVar "date") (EApp (EVar "buildDate") (ELit LUnit))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EVar "commit") (ELit (LString ""))) (EBinOp "==" (EVar "date") (ELit (LString "")))) (EBinOp "++" (ELit (LString "medaka ")) (EVar "medakaVersion")) (EIf (EBinOp "==" (EVar "commit") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EMethodRef "display") (EVar "medakaVersion"))) (ELit (LString " (built "))) (EApp (EMethodRef "display") (EVar "date"))) (ELit (LString ")"))) (EIf (EBinOp "==" (EVar "date") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EMethodRef "display") (EVar "medakaVersion"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EVar "commit"))) (ELit (LString ")"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka ")) (EApp (EMethodRef "display") (EVar "medakaVersion"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EVar "commit"))) (ELit (LString ", built "))) (EApp (EMethodRef "display") (EVar "date"))) (ELit (LString ")")))))))))
(DTypeSig false "printVersion" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printVersion" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "medakaVersionString") (ELit LUnit))))
(DTypeSig false "liveSourceFingerprint" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "liveSourceFingerprint" ((PVar "root")) (EBlock (DoLet false false (PVar "script") (EApp (EVar "stringConcat") (EListLit (ELit (LString "command -v perl >/dev/null 2>&1 || exit 7; cd \"")) (EVar "root") (ELit (LString "\" && { find compiler -name '*.mdk' -not -name '*_test.mdk' -print;")) (ELit (LString " find stdlib -name '*.mdk' -not -name '*_test.mdk' -print; } | LC_ALL=C sort")) (ELit (LString " | perl -ne 'chomp; print \"$_\\n\"; open F,\"<\",$_ or next; local $/; my $c=<F>; print $c if defined $c; close F' 2>/dev/null")) (ELit (LString " | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; elif command -v shasum >/dev/null 2>&1; then shasum -a 256; else cksum; fi; }")) (ELit (LString " | cut -d' ' -f1"))))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (ELit (LString "-c")) (EVar "script"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "h") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "h") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "h")))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "sourceStalenessVerdict" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sourceStalenessVerdict" (PWild) (EBlock (DoLet false false (PVar "baked") (EApp (EVar "buildFingerprint") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "baked") (ELit (LString ""))) (EVar "None") (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "compilerDir"))) (EVar "None") (EMatch (EApp (EVar "liveSourceFingerprint") (EVar "root")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "live")) () (EIf (EBinOp "==" (EVar "live") (EVar "baked")) (EVar "None") (EApp (EVar "Some") (EVar "compilerDir"))))))))))))
(DTypeSig false "checkSourceStaleness" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "checkSourceStaleness" ((PVar "argv")) (EMatch (EApp (EVar "sourceStalenessVerdict") (ELit LUnit)) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "compilerDir")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EBinOp "++" (ELit (LString "warning: this ./medaka was built from compiler source that differs from ")) (EVar "compilerDir")) (ELit (LString "; rebuild with `make medaka`")))) (DoExpr (EIf (EBinOp "/=" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_STRICT"))) (ELit (LString ""))) (ELit (LString ""))) (EApp (EVar "dieMsg") (EVar "msg")) (EIf (EApp (EVar "runJsonInvocation") (EVar "argv")) (EApp (EApp (EVar "setRef") (EVar "pendingStaleNotice")) (EApp (EVar "Some") (EVar "msg"))) (EApp (EVar "ePutStrLn") (EVar "msg")))))))))
(DTypeSig false "loadCheckPrelude" (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "loadCheckPrelude" ((PVar "prelude")) (EBlock (DoLet false false (PVar "verdict") (EApp (EVar "loadPreludeInterface") (EVar "prelude"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "reportStaleLine") (EVar "dieMsg")) (EVar "None")) (EApp (EApp (EVar "staleLine") (EVar "InterfaceFile")) (EVar "verdict")))) (DoExpr (EApp (EApp (EApp (EVar "reportDecls") (EVar "None")) (EVar "dieMsg")) (EVar "prelude")))))
(DTypeSig false "seedCheckPrelude" (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "seedCheckPrelude" ((PVar "prelude")) (EBlock (DoLet false false PWild (EApp (EVar "loadPreludeInterface") (EVar "prelude"))) (DoExpr (ELit LUnit))))
(DTypeSig false "reportTrees" (TyFun (TyApp (TyCon "Option") (TyFun (TyCon "String") (TyCon "Unit"))) (TyFun (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))) (TyFun (TyCon "FileVerdict") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "reportTrees" ((PVar "staging") (PVar "stop") (PVar "verdict")) (EApp (EApp (EApp (EVar "reportStaleLine") (EVar "stop")) (EVar "staging")) (EApp (EApp (EVar "staleLine") (EVar "TreesFile")) (EVar "verdict"))))
(DTypeSig false "reportDecls" (TyFun (TyApp (TyCon "Option") (TyFun (TyCon "String") (TyCon "Unit"))) (TyFun (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))) (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "reportDecls" ((PVar "staging") (PVar "stop") (PVar "prelude")) (EApp (EApp (EApp (EVar "reportStaleLine") (EVar "stop")) (EVar "staging")) (EApp (EApp (EVar "staleLine") (EVar "DeclsFile")) (EApp (EVar "preludeDeclsVerdict") (EVar "prelude")))))
(DTypeSig false "deferredInto" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "deferredInto" ((PCon "False") PWild) (EVar "None"))
(DFunDef false "deferredInto" ((PCon "True") (PVar "field")) (EApp (EVar "Some") (ELam ((PVar "msg")) (EApp (EApp (EVar "setRef") (EVar "pendingPreludeNotices")) (EBinOp "++" (EUnOp "!" (EVar "pendingPreludeNotices")) (EListLit (ETuple (EVar "field") (EVar "msg"))))))))
(DTypeSig false "unstaged" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "unstaged" (PWild) (EVar "None"))
(DTypeSig false "takeShippedPrelude" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyFun (TyCon "String") (TyCon "Unit")))) (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "takeShippedPrelude" ((PVar "stagingFor") (PVar "prelude")) (EBlock (DoLet false false PWild (EApp (EVar "loadPreludeInterface") (EVar "prelude"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "reportTrees") (EApp (EVar "stagingFor") (ELit (LString "stalePreludeTrees")))) (EVar "runAbort")) (EApp (EVar "loadPreludeElab") (EVar "prelude")))) (DoExpr (EApp (EApp (EApp (EVar "reportDecls") (EApp (EVar "stagingFor") (ELit (LString "stalePreludeDecls")))) (EVar "runAbort")) (EVar "prelude")))))
(DTypeSig false "reportShippedHeaders" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyFun (TyCon "String") (TyCon "Unit")))) (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "reportShippedHeaders" ((PVar "stagingFor") (PVar "prelude")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "reportTrees") (EApp (EVar "stagingFor") (ELit (LString "stalePreludeTrees")))) (EVar "runAbort")) (EApp (EVar "checkPreludeElab") (EVar "prelude")))) (DoExpr (EApp (EApp (EApp (EVar "reportDecls") (EApp (EVar "stagingFor") (ELit (LString "stalePreludeDecls")))) (EVar "runAbort")) (EVar "prelude")))))
(DTypeSig false "reportChildTrees" (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "reportChildTrees" ((PVar "prelude")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "reportTrees") (EVar "None")) (EVar "dieMsg")) (EApp (EVar "checkPreludeElab") (EVar "prelude")))) (DoExpr (EApp (EApp (EApp (EVar "reportDecls") (EVar "None")) (EVar "dieMsg")) (EVar "prelude")))))
(DTypeSig false "runJsonInvocation" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "runJsonInvocation" ((PCons (PLit (LString "run")) (PVar "rest"))) (EApp (EApp (EVar "runFlagGiven") (ELit (LString "--json"))) (EVar "rest")))
(DFunDef false "runJsonInvocation" (PWild) (EVar "False"))
(DTypeSig false "flushStaleNoticeProse" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "flushStaleNoticeProse" (PWild) (EBlock (DoLet false false PWild (EMatch (EUnOp "!" (EVar "pendingStaleNotice")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "msg")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "pendingStaleNotice")) (EVar "None"))) (DoExpr (EApp (EVar "ePutStrLn") (EVar "msg"))))))) (DoLet false false (PVar "notices") (EUnOp "!" (EVar "pendingPreludeNotices"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "pendingPreludeNotices")) (EListLit))) (DoExpr (EApp (EVar "emitWarningLines") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "notices"))))))
(DTypeSig false "dieMsg" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "dieMsg" ((PVar "msg")) (EBlock (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))
(DTypeSig false "runAbort" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runAbort" ((PVar "msg")) (EBlock (DoLet false false PWild (EApp (EVar "flushStaleNoticeProse") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "flushPerfSinkProse") (ELit LUnit))) (DoExpr (EApp (EVar "dieMsg") (EVar "msg")))))
(DTypeSig false "orExit" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")) (TyEffect ("IO") None (TyVar "a"))))
(DFunDef false "orExit" ((PCon "Ok" (PVar "v"))) (EVar "v"))
(DFunDef false "orExit" ((PCon "Err" (PVar "msg"))) (EBlock (DoLet false false PWild (EApp (EVar "runAbort") (EVar "msg"))) (DoExpr (EApp (EVar "panic") (EVar "msg")))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false PWild (EApp (EVar "stageCountInit") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "checkSourceStaleness") (EApp (EVar "args") (ELit LUnit)))) (DoLet false false PWild (EApp (EVar "runCli") (ELit LUnit))) (DoExpr (EApp (EVar "stageDump") (ELit LUnit)))))
(DTypeSig false "runCli" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCli" (PWild) (EMatch (EApp (EVar "args") (ELit LUnit)) (arm (PList) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "-h")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "-v")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "check")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "checkHelpText")) (EVar "runCheckCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "fmt")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "fmtHelpText")) (EVar "runFmtCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "new")) (PVar "rest")) () (EApp (EVar "runNewCmd") (EVar "rest"))) (arm (PCons (PLit (LString "build")) (PVar "rest")) () (EApp (EVar "runBuildCmd") (EVar "rest"))) (arm (PCons (PLit (LString "run")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "runHelpText")) (EVar "runRunCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "test")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "testHelpText")) (EVar "runTestCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "snapshot")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "snapshotHelpText")) (EVar "runSnapshotCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "doc")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "docHelpText")) (EVar "runDocCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "lint")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "lintHelpText")) (EVar "runLintCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "codemod")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "codemodHelpText")) (EVar "runCodemodCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "check-policy")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "checkPolicyHelpText")) (EVar "runCheckPolicyCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "manifest")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "manifestHelpText")) (EVar "runManifestCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "gate")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "gateHelpText")) (EVar "runGateCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "interface")) (PVar "rest")) () (EApp (EApp (EApp (EVar "dispatchSub") (EVar "interfaceHelpText")) (EVar "runInterfaceCmd")) (EVar "rest"))) (arm (PCons (PLit (LString "repl")) (PVar "rest")) () (EApp (EVar "runReplCmd") (EVar "rest"))) (arm (PCons (PLit (LString "lsp")) (PVar "rest")) () (EApp (EVar "runLspCmd") (EVar "rest"))) (arm (PCons (PLit (LString "mcp")) (PVar "rest")) () (EApp (EVar "runMcpCmd") (EVar "rest"))) (arm (PCons (PVar "sub") PWild) () (EApp (EVar "unknownSubcommand") (EMethodRef "sub")))))
(DTypeSig false "dispatchSub" (TyFun (TyCon "String") (TyFun (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "dispatchSub" ((PVar "help") PWild (PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "flushStaleNoticeProse") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "help"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "dispatchSub" ((PVar "help") PWild (PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "flushStaleNoticeProse") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "help"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "dispatchSub" (PWild (PVar "run") (PVar "rest")) (EApp (EVar "run") (EVar "rest")))
(DTypeSig false "usage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "usage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka. A functional language compiler\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka                    Show this message\n")) (ELit (LString "  medaka run [--json] [--allow-internal] [--release] <file.mdk | -> [args...]   Type-check and run a program\n")) (ELit (LString "  medaka build <file.mdk> [-o <out>] [--keep-ir]  Compile to a native binary (LLVM + clang)\n")) (ELit (LString "  medaka check [--json] [--types] [--allow-internal] <file.mdk>    Type-check without running\n")) (ELit (LString "  medaka test [--native | --engines eval,native] [--filter <substring>] [--seed <n>] [--cases <n>] [file.mdk]    Run doctests + prop tests (--native runs doctests through a compiled native binary INSTEAD of the interpreter; --engines runs the listed set, exit is the AND)\n")) (ELit (LString "  medaka doc <file.mdk>     Generate Markdown documentation (one file; required)\n")) (ELit (LString "  medaka lint [paths...]    Lint files/dirs (style rules; --fix, --cache, --disable/--only/--deny=<rules,...>)\n")) (ELit (LString "  medaka codemod <name> [flags] [paths...]  Apply a named source-preserving AST transform (--write/--stdout)\n")) (ELit (LString "  medaka snapshot [--check|--new|--bless] [paths...]  Per-stage snapshot tests (--out <dir>, --stages <a,b,..>)\n")) (ELit (LString "  medaka fmt [paths...]     Report unformatted files (default; use --write to rewrite in place)\n")) (ELit (LString "  medaka new <name>         Scaffold a new project directory\n")) (ELit (LString "  medaka repl               Start an interactive REPL (reads stdin until EOF or :quit)\n")) (ELit (LString "  medaka lsp                Run the language server over stdio\n")) (ELit (LString "  medaka mcp                Run the MCP server over stdio (JSON-RPC for agents)\n")) (ELit (LString "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]  Check a plugin's inferred effects against an allow-list\n")) (ELit (LString "  medaka manifest <file.mdk> [--fn name]  Emit the verified capability manifest as TOML\n")) (ELit (LString "  medaka gate list [<selector>...] [--json]  Query the gate registry (test/gates.toml)\n")) (ELit (LString "  medaka gate run [<selector>...] [--dry-run]  Run the selected gates\n")) (ELit (LString "  medaka interface write|verify <module.mdk>, show <file.mdki>  Write, show or verify the prelude interface file\n")) (ELit (LString "  medaka help               Show this message\n")) (ELit (LString "  medaka --version          Show the compiler version\n"))))))
(DTypeSig false "unknownSubcommand" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "unknownSubcommand" ((PVar "sub")) (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka: unknown subcommand `")) (EApp (EMethodRef "display") (EMethodRef "sub"))) (ELit (LString "`; run `medaka help` for the list of subcommands")))))
(DTypeSig false "cliStdlibExportsEnv" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "cliStdlibExportsEnv" ((PVar "names")) (EApp (EApp (EVar "cliStdlibExports") (EBinOp "++" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot")) (ELit (LString "/stdlib")))) (EVar "names")))
(DTypeSig false "checkHelpText" (TyCon "String"))
(DFunDef false "checkHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka check — Type-check a file without running it\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka check [--json] [--types] [--allow-internal] <file.mdk>\n")) (ELit (LString "\n")) (ELit (LString "  --json            emit the {\"files\":[...]} structured-diagnostics\n")) (ELit (LString "                    envelope instead of human text\n")) (ELit (LString "  --types           show the full inferred-scheme dump, prelude included\n")) (ELit (LString "                    (default: only your own top-level bindings; no effect\n")) (ELit (LString "                    under --json — the envelope carries diagnostics, not\n")) (ELit (LString "                    scheme dumps)\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")) (ELit (LString "  --target <name>   refuse a program whose `main` performs a label this\n")) (ELit (LString "                    target profile does not grant (default: [target] in\n")) (ELit (LString "                    medaka.toml, else no target check)\n")))))
(DTypeSig false "checkArgSpec" (TyCon "ArgSpec"))
(DFunDef false "checkArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "check"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the structured-diagnostics envelope"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--types")))) (ELit (LString "show the full inferred-scheme dump"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--allow-internal")))) (ELit (LString "permit internal-only externs outside stdlib/"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--target")))) (ELit (LString "NAME"))) (ELit (LString "target profile `main` must fit")))))))
(DTypeSig false "runCheckCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "checkArgSpec")) (EVar "argv"))) (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false (PVar "perfT0") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a"))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "flag") (ELit (LString "--allow-internal"))) (EVar "a"))) (DoLet false false (PVar "typesMode") (EApp (EApp (EVar "flag") (ELit (LString "--types"))) (EVar "a"))) (DoExpr (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList (PVar "target")) () (EBlock (DoExpr (EApp (EVar "perfArm") (EVar "perfT0"))) (DoExpr (EApp (EApp (EVar "carryTargetProfile") (EApp (EApp (EVar "lastValue") (ELit (LString "--target"))) (EVar "a"))) (EVar "target"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readPreludeSources") (EVar "stdlibDir")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "prelude")) () (EBlock (DoLet false false (PVar "rsrc") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (DoLet false false (PVar "csrc") (EFieldAccess (EVar "prelude") "pnCoreSrc")) (DoLet false false PWild (EApp (EVar "loadCheckPrelude") (EVar "prelude"))) (DoExpr (EIf (EVar "jsonMode") (EBlock (DoLet false false PWild (EIf (EVar "typesMode") (EApp (EVar "ePutStrLn") (ELit (LString "medaka check: --types has no effect under --json; the envelope carries no scheme dump"))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "runCheckJsonCmd") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir")))) (EMatch (EApp (EVar "readSource") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "dieMsg") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EMethodRef "map") (EVar "dropPathTriple")) (EVar "modsWithPath"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PVar "inputs") (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "flatStdlib")) (EVar "ownedStdlib"))) (DoLet false false (PVar "perfTLoad") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "load"))) (EBinOp "-" (EVar "perfTLoad") (EVar "perfT0"))) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkRoute") (EVar "inputs")) (EVar "typesMode")) (EVar "allowInternal")) (EVar "trusted")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "modsWithPath"))) (DoLet false false (PVar "perfTCheck") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "check"))) (EBinOp "-" (EVar "perfTCheck") (EVar "perfTLoad"))) (EVar "target"))) (DoExpr (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTCheck") (EVar "perfT0"))))))))))))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check [--json] [--types] [--allow-internal] [--target <profile>] <file.mdk>")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))))
(DTypeSig false "locatedProjectDiags" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "Int")))))
(DFunDef false "locatedProjectDiags" ((PVar "results")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "readDiagSrc")) (EVar "results"))) (DoExpr (ETuple (EApp (EVar "joinedOrNone") (EApp (EApp (EDictApp "flatMap") (EVar "renderTripleErrors")) (EVar "triples"))) (EApp (EApp (EMethodRef "map") (EVar "cohWarnsOfTriple")) (EVar "triples")) (EApp (EMethodRef "length") (EApp (EApp (EDictApp "flatMap") (EVar "hiddenWarnsOfTriple")) (EApp (EVar "dropEntryTriple") (EVar "triples"))))))))
(DTypeSig false "relDiagTriple" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "relDiagTriple" ((PVar "root") (PTuple (PVar "path") (PVar "src") (PVar "diags"))) (ETuple (EApp (EApp (EVar "relDiagPath") (EVar "root")) (EVar "path")) (EVar "src") (EVar "diags")))
(DTypeSig false "hiddenWarnsOfTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "Diag"))))
(DFunDef false "hiddenWarnsOfTriple" ((PTuple PWild PWild (PVar "diags"))) (EApp (EApp (EMethodRef "filter") (EVar "isHiddenNonEntryWarn")) (EVar "diags")))
(DTypeSig false "isHiddenNonEntryWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isHiddenNonEntryWarn" ((PVar "d")) (EBinOp "&&" (EApp (EVar "diagIsWarn") (EVar "d")) (EApp (EVar "not") (EApp (EVar "isCoherenceWarn") (EVar "d")))))
(DTypeSig false "runAbortJson" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runAbortJson" ((PVar "triples")) (EBlock (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "pendingRunDiags")) (EApp (EVar "nonEmptyTriples") (EVar "triples")))) (DoLet false false PWild (EApp (EVar "flushPendingRunDiags") (EVar "True"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))
(DTypeSig false "resolveErrorJsonTriples" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "resolveErrorJsonTriples" ((PList)) (EListLit))
(DFunDef false "resolveErrorJsonTriples" ((PCons (PTuple PWild (PList)) (PVar "rest"))) (EApp (EVar "resolveErrorJsonTriples") (EVar "rest")))
(DFunDef false "resolveErrorJsonTriples" ((PCons (PTuple (PVar "file") (PVar "diags")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "file") (EApp (EVar "readFileSafe") (EVar "file")) (EVar "diags")) (EApp (EVar "resolveErrorJsonTriples") (EVar "rest"))))
(DTypeSig false "genericResidualDiag" (TyFun (TyCon "String") (TyCon "Diag")))
(DFunDef false "genericResidualDiag" ((PVar "target")) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (EVar "TResidual")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type error in ")) (EVar "target")) (ELit (LString ", detected during elaboration; no located diagnostic is available,"))) (ELit (LString " and `medaka check` may not report it")))) (EVar "None")))
(DTypeSig false "residualJsonTriples" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))
(DFunDef false "residualJsonTriples" ((PVar "entryFile") PWild (PList)) (EListLit (ETuple (EVar "entryFile") (EApp (EVar "readFileSafe") (EVar "entryFile")) (EListLit (EApp (EVar "genericResidualDiag") (EVar "entryFile"))))))
(DFunDef false "residualJsonTriples" ((PVar "entryFile") (PVar "pathMap") (PCons (PTuple (PVar "mid") (PVar "d")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "pathMap")) (arm (PCon "Some" (PVar "file")) () (EBinOp "::" (ETuple (EVar "file") (EApp (EVar "readFileSafe") (EVar "file")) (EListLit (EApp (EVar "diagOfTypeError") (EVar "d")))) (EApp (EApp (EApp (EVar "residualJsonTriples") (EVar "entryFile")) (EVar "pathMap")) (EVar "rest")))) (arm (PCon "None") () (EBinOp "::" (ETuple (EVar "entryFile") (EApp (EVar "readFileSafe") (EVar "entryFile")) (EListLit (EApp (EVar "diagOfTypeError") (EVar "d")))) (EApp (EApp (EApp (EVar "residualJsonTriples") (EVar "entryFile")) (EVar "pathMap")) (EVar "rest"))))))
(DTypeSig false "checkRoute" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Unit")))))))))))))
(DFunDef false "checkRoute" ((PVar "inputs") (PVar "typesMode") (PVar "allowInternal") (PVar "trusted") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "modsWithPath")) (EBlock (DoLet false false (PVar "program") (EMatch (EVar "modsWithPath") (arm (PList (PVar "m")) () (EApp (EVar "FrontFile") (EVar "m"))) (arm PWild () (EApp (EApp (EVar "FrontGraph") (EVar "modsWithPath")) (EApp (EVar "desugaredModPairs") (EVar "modsWithPath")))))) (DoLet false false (PVar "front") (EApp (EApp (EApp (EVar "frontEnd") (EVar "cliStdlibExportsEnv")) (EApp (EApp (EVar "checkFrontDrive") (EVar "target")) (EVar "roots"))) (ERecordCreate "FrontInput" ((fa "fiInputs" (EVar "inputs")) (fa "fiAllowInternal" (EVar "allowInternal")) (fa "fiTrusted" (EVar "trusted")) (fa "fiRuntimeSrc" (EVar "rsrc")) (fa "fiCoreSrc" (EVar "csrc")) (fa "fiPolicy" (EVar "NeverDriveRejected")) (fa "fiProgram" (EVar "program")))))) (DoExpr (EMatch (EVar "program") (arm (PCon "FrontFile" (PTuple PWild PWild (PVar "decls"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkFileReport") (EVar "typesMode")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "decls")) (EVar "front"))) (arm (PCon "FrontGraph" (PVar "mods") (PVar "modPairs")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkProjectReport") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "mods")) (EVar "modPairs")) (EVar "front")))))))
(DTypeSig false "checkFileReport" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "FrontOutput") (TyCon "CheckDump")) (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "checkFileReport" ((PVar "typesMode") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "decls") (PVar "front")) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EFieldAccess (EVar "front") "foDiags"))) (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "diagIsError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false (PVar "warns") (EApp (EApp (EMethodRef "filter") (EVar "diagIsWarn")) (EVar "diags"))) (DoLet false false (PVar "dumpLines") (EMatch (EFieldAccess (EVar "front") "foDriven") (arm (PCon "Some" (PVar "d")) () (EFieldAccess (EVar "d") "cdLines")) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "dump") (EApp (EVar "stripWarningLines") (EApp (EVar "joinNl") (EVar "dumpLines")))) (DoLet false false (PVar "filtered") (EApp (EApp (EVar "userSchemeLines") (EVar "decls")) (EVar "dump"))) (DoLet false false (PVar "report") (EIf (EVar "typesMode") (EVar "dump") (EVar "filtered"))) (DoLet false false PWild (EMatch (EFieldAccess (EVar "front") "foDriven") (arm (PCon "Some" (PVar "d")) () (EApp (EApp (EApp (EApp (EApp (EVar "checkTargetGate") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EFieldAccess (EVar "d") "cdDrive"))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "report"))) (DoLet false false PWild (EIf (EVar "typesMode") (ELit LUnit) (EApp (EVar "putStrLn") (EApp (EApp (EVar "checkOkLine") (EVar "target")) (EVar "filtered"))))) (DoLet false false (PVar "mainWarns") (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EListLit)) (EListLit)) (EListLit)) (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EBinOp "++" (EVar "warns") (EVar "mainWarns")))) (DoExpr (ELit LUnit)))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))))
(DTypeSig false "checkProjectReport" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "FrontOutput") (TyCon "CheckDump")) (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "checkProjectReport" ((PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods") (PVar "modPairs") (PVar "front")) (EMatch (EFieldAccess (EVar "front") "foDriven") (arm (PCon "None") () (EApp (EVar "dieMsg") (EApp (EVar "ppDiagBuckets") (EFieldAccess (EVar "front") "foDiags")))) (arm (PCon "Some" (PVar "dump")) () (EBlock (DoLet false false (PVar "exWarns") (EApp (EApp (EApp (EVar "entryExhaust") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (EVar "modPairs"))) (DoExpr (EMatch (EApp (EVar "locatedProjectDiags") (EFieldAccess (EVar "front") "foDiags")) (arm (PTuple (PCon "Some" (PVar "errText")) PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "errText"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PTuple (PCon "None") (PVar "projWarns") (PVar "hiddenCount")) () (EBlock (DoLet false false (PVar "report") (EApp (EApp (EVar "checkModulesReport") (EVar "exWarns")) (EFieldAccess (EFieldAccess (EVar "front") "foReport") "trDiagnostics"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "checkTargetGate") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EFieldAccess (EVar "dump") "cdDrive"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "report"))) (DoLet false false PWild (EApp (EVar "emitWarningLines") (EApp (EApp (EDictApp "flatMap") (EVar "renderTripleWarnings")) (EApp (EVar "trimEntryTriple") (EVar "projWarns"))))) (DoLet false false PWild (EApp (EVar "emitHiddenDiagNote") (EVar "hiddenCount"))) (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EApp (EApp (EMethodRef "map") (EVar "dropPathTriple")) (EVar "mods"))) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EListLit)) (EListLit)) (EListLit)) (EVar "edecls"))) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EVar "mainWarns")))))))))))
(DTypeSig false "lastModPair" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lastModPair" ((PList)) (EVar "None"))
(DFunDef false "lastModPair" ((PList (PVar "p"))) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "lastModPair" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModPair") (EVar "rest")))
(DTypeSig false "checkTargetGate" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CheckDrive") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "checkTargetGate" ((PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "drive")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "checkTargetRefusal") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EFieldAccess (EVar "drive") "cdPaths")) (EVar "drive")) (arm (PList) () (ELit LUnit)) (arm (PVar "ds") () (EBlock (DoLet false false PWild (EApp (EVar "emitAbortTotal") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppTargetDiag") (EVar "target")) (EVar "tsrc"))) (EVar "ds"))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))
(DTypeSig false "checkTargetRefusal" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CheckDrive") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Diag")))))))))
(DFunDef false "checkTargetRefusal" ((PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "paths") (PVar "drive")) (EMatch (EUnOp "!" (EVar "selectedProfile")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "profile")) () (EApp (EApp (EApp (EApp (EVar "targetRefusal") (EVar "profile")) (EVar "target")) (EVar "paths")) (EApp (EApp (EApp (EVar "checkTargetInputs") (EVar "rsrc")) (EVar "csrc")) (EVar "drive"))))))
(DTypeSig false "checkTargetInputs" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CheckDrive") (TyCon "TargetInputs")))))
(DFunDef false "checkTargetInputs" ((PVar "rsrc") (PVar "csrc") (PVar "drive")) (EBlock (DoLet false false (PVar "core") (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (DoLet false false (PVar "printed") (EIf (EApp (EApp (EApp (EVar "shouldAutoPrintMain") (EFieldAccess (EFieldAccess (EVar "drive") "cdOutputs") "doEntryOutcome")) (EVar "core")) (EFieldAccess (EVar "drive") "cdMods")) (EApp (EApp (EVar "lookupAssoc") (ELit (LString "println"))) (EFieldAccess (EVar "drive") "cdCoreSchemes")) (EVar "None"))) (DoExpr (ERecordCreate "TargetInputs" ((fa "tiSchemes" (EBinOp "++" (EFieldAccess (EVar "drive") "cdEntrySchemes") (EFieldAccess (EVar "drive") "cdCoreSchemes"))) (fa "tiEntryDecls" (EMatch (EApp (EVar "lastModPair") (EFieldAccess (EVar "drive") "cdMods")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EVar "decls")) (arm (PCon "None") () (EListLit)))) (fa "tiAutoPrintCall" (EVar "printed")) (fa "tiCore" (EVar "core")) (fa "tiModules" (EFieldAccess (EVar "drive") "cdMods")) (fa "tiRuntime" (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (fa "tiOutputs" (EFieldAccess (EVar "drive") "cdOutputs")) (fa "tiStdlibOwned" (EListLit)))))))
(DTypeSig false "checkTargetJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CheckJson") (TyFun (TyApp (TyCon "Option") (TyCon "CheckDrive")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "CheckJson"))))))))))
(DFunDef false "checkTargetJson" ((PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir") (PVar "cj") (PVar "drive")) (EMatch (EUnOp "!" (EVar "selectedProfile")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" PWild) () (EMatch (EVar "drive") (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "check --json --target: a clean check left no drive to judge")))) (arm (PCon "Some" (PVar "dr")) () (EBlock (DoLet false false (PVar "paths") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "mid") (PVar "path"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EVar "reportKey") (EVar "stdlibDir")) (EVar "cj")) (EVar "path"))))) (EFieldAccess (EVar "dr") "cdPaths"))) (DoExpr (EMatch (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "checkTargetRefusal") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "paths")) (EVar "dr")) (EVar "cj")) (arm (PTuple (PList) PWild) () (EVar "None")) (arm (PTuple (PVar "ds") (PCon "CjParts" (PVar "entry") (PVar "triples"))) () (EApp (EVar "Some") (EApp (EApp (EVar "CjParts") (EVar "entry")) (EApp (EApp (EApp (EApp (EVar "foldTargetDiags") (EVar "entry")) (EApp (EVar "readFileSafe") (EVar "entry"))) (EVar "ds")) (EVar "triples"))))) (arm PWild () (EVar "None"))))))))))
(DTypeSig false "reportKey" (TyFun (TyCon "String") (TyFun (TyCon "CheckJson") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "reportKey" ((PVar "stdlibDir") (PCon "CjParts" PWild (PVar "triples")) (PVar "path")) (EIf (EApp (EApp (EDictApp "any") (ELam ((PTuple (PVar "p") PWild PWild)) (EBinOp "==" (EVar "p") (EVar "path")))) (EVar "triples")) (EVar "path") (EApp (EApp (EVar "relDiagPath") (EApp (EVar "dirOf2") (EVar "stdlibDir"))) (EVar "path"))))
(DFunDef false "reportKey" (PWild PWild (PVar "path")) (EVar "path"))
(DTypeSig false "runTargetGate" (TyFun (TyCon "Bool") (TyFun (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "EntryAnalysis") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "runTargetGate" ((PVar "jsonMode") (PVar "rel") (PVar "target") (PVar "pathMap") (PVar "mods") (PVar "analysis")) (EBlock (DoLet false false (PVar "startable") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EApp (EVar "isNone") (EApp (EVar "mainEntryError") (EVar "edecls")))) (arm (PCon "None") () (EVar "False")))) (DoLet false false (PVar "refusal") (EIf (EVar "startable") (EApp (EApp (EApp (EApp (EVar "targetRefusal") (EApp (EVar "runProfile") (EUnOp "!" (EVar "selectedProfile")))) (EVar "target")) (EVar "pathMap")) (EFieldAccess (EVar "analysis") "eaTarget")) (EListLit))) (DoExpr (EMatch (EVar "refusal") (arm (PList) () (ELit LUnit)) (arm (PVar "ds") () (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "target"))) (DoExpr (EMatch (EVar "jsonMode") (arm (PCon "True") () (EApp (EVar "runAbortJson") (EApp (EApp (EMethodRef "map") (EVar "rel")) (EApp (EApp (EApp (EApp (EVar "foldTargetDiags") (EVar "target")) (EVar "src")) (EVar "ds")) (EListLit))))) (arm (PCon "False") () (EApp (EVar "runAbort") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppTargetDiag") (EVar "target")) (EVar "src"))) (EVar "ds")))))))))))))
(DTypeSig false "runArgvFilter" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "runArgvFilter" ((PList)) (EListLit))
(DFunDef false "runArgvFilter" ((PCons (PLit (LString "--json")) (PVar "rest"))) (EApp (EVar "runArgvFilter") (EVar "rest")))
(DFunDef false "runArgvFilter" ((PCons (PLit (LString "--release")) (PVar "rest"))) (EApp (EVar "runArgvFilter") (EVar "rest")))
(DFunDef false "runArgvFilter" ((PCons (PLit (LString "--allow-internal")) (PVar "rest"))) (EApp (EVar "runArgvFilter") (EVar "rest")))
(DFunDef false "runArgvFilter" ((PCons (PLit (LString "--types")) (PVar "rest"))) (EApp (EVar "runArgvFilter") (EVar "rest")))
(DFunDef false "runArgvFilter" ((PCons (PLit (LString "--target")) (PCons PWild (PVar "rest")))) (EApp (EVar "runArgvFilter") (EVar "rest")))
(DFunDef false "runArgvFilter" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--target="))) (EVar "x")) (EApp (EVar "runArgvFilter") (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "runArgvFilter" ((PVar "argv")) (EVar "argv"))
(DTypeSig false "runTargetFlag" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "runTargetFlag" ((PVar "argv")) (EApp (EApp (EVar "runTargetGo") (EVar "None")) (EVar "argv")))
(DTypeSig false "runTargetGo" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "runTargetGo" (PWild (PCons (PLit (LString "--target")) (PCons (PVar "v") (PVar "rest")))) (EApp (EApp (EVar "runTargetGo") (EApp (EVar "Some") (EVar "v"))) (EVar "rest")))
(DFunDef false "runTargetGo" ((PVar "acc") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--target="))) (EVar "x")) (EApp (EApp (EVar "runTargetGo") (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 9))) (EApp (EVar "stringLength") (EVar "x"))) (EVar "x")))) (EVar "rest")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "x") (ELit (LString "--json"))) (EBinOp "==" (EVar "x") (ELit (LString "--release")))) (EBinOp "==" (EVar "x") (ELit (LString "--allow-internal")))) (EBinOp "==" (EVar "x") (ELit (LString "--types")))) (EApp (EApp (EVar "runTargetGo") (EVar "acc")) (EVar "rest")) (EIf (EVar "otherwise") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "runTargetGo" ((PVar "acc") (PList)) (EVar "acc"))
(DTypeSig false "carryTargetProfile" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "carryTargetProfile" ((PVar "flagValue") (PVar "entry")) (EMatch (EApp (EApp (EVar "carryProjectProfile") (EVar "flagValue")) (EVar "entry")) (arm (PCon "Ok" PWild) () (ELit LUnit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "dieMsg") (EBinOp "++" (ELit (LString "error: ")) (EVar "m"))))))
(DTypeSig false "runFlagGiven" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "runFlagGiven" (PWild (PList)) (EVar "False"))
(DFunDef false "runFlagGiven" ((PVar "nm") (PCons (PLit (LString "--target")) (PCons PWild (PVar "rest")))) (EApp (EApp (EVar "runFlagGiven") (EVar "nm")) (EVar "rest")))
(DFunDef false "runFlagGiven" ((PVar "nm") (PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "x") (ELit (LString "--json"))) (EBinOp "==" (EVar "x") (ELit (LString "--release")))) (EBinOp "==" (EVar "x") (ELit (LString "--allow-internal")))) (EBinOp "==" (EVar "x") (ELit (LString "--types")))) (EApp (EApp (EVar "startsWith") (ELit (LString "--target="))) (EVar "x"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "nm")) (EApp (EApp (EVar "runFlagGiven") (EVar "nm")) (EVar "rest"))) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "requireArgs" (TyFun (TyCon "ArgSpec") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Args")))))
(DFunDef false "requireArgs" ((PVar "sp") (PVar "argv")) (EMatch (EApp (EApp (EVar "parseArgs") (EVar "sp")) (EVar "argv")) (arm (PCon "Ok" (PVar "a")) () (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoLet false false PWild (EApp (EVar "stageExit") (EVar "usageExitCode"))) (DoExpr (ERecordCreate "Args" ((fa "given" (EListLit)) (fa "positionals" (EListLit)) (fa "rest" (EListLit)))))))))
(DTypeSig false "runCheckJsonCmd" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "runCheckJsonCmd" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir")) (EMatch (EApp (EVar "readSourceE") (EVar "target")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "cjSourceReadJson") (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PTuple (PVar "cj") (PVar "hasErr") (PVar "drive")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFileParts") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir"))) (DoLet false false (PVar "refused") (EIf (EVar "hasErr") (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkTargetJson") (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "cj")) (EVar "drive")))) (DoExpr (EMatch (EVar "refused") (arm (PCon "Some" (PVar "refusedCj")) () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EVar "ppCheckJson") (EVar "refusedCj")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EVar "ppCheckJson") (EVar "cj")))) (DoExpr (EIf (EVar "hasErr") (EApp (EVar "stageExit") (ELit (LInt 1))) (ELit LUnit)))))))))))
(DTypeSig false "cjBuildFailedJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "cjBuildFailedJson" ((PVar "target") (PVar "msg")) (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "target") (ELit (LString "")) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "Coded") (EVar "RBuildFailed"))) (EVar "msg")) (EVar "None")) (EVar "None")) (EVar "None")))))))
(DTypeSig false "runBuildJsonCmd" (TyFun (TyCon "Args") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "runBuildJsonCmd" ((PVar "a") (PVar "allowInternal") (PVar "root") (PVar "stdlibDir") (PVar "input") (PVar "outOpt") (PVar "target")) (EMatch (EApp (EVar "readSourceE") (EVar "input")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "cjSourceReadJson") (EVar "input")) (EVar "e")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "entrySrc")) () (EMatch (EApp (EVar "readPreludeSources") (EVar "stdlibDir")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "cjBuildFailedJson") (EVar "input")) (EVar "msg")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "prelude")) () (EBlock (DoLet false false (PVar "notices") (EApp (EApp (EVar "jsonPreludeNotices") (EVar "target")) (EVar "prelude"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "keepIrCli") (EApp (EApp (EVar "flag") (ELit (LString "--keep-ir"))) (EVar "a"))) (DoLet false false (PVar "stampBuild") (EApp (EApp (EVar "flag") (ELit (LString "--stamp-build"))) (EVar "a"))) (DoLet false false (PVar "outPath") (EMatch (EVar "outOpt") (arm (PCon "Some" (PVar "o")) () (EVar "o")) (arm (PCon "None") () (EApp (EApp (EVar "defaultOutPath") (EVar "target")) (EVar "input"))))) (DoLet false false (PVar "ask") (ERecordCreate "GateAsk" ((fa "askAllowInternal" (EVar "allowInternal")) (fa "askDiagJson" (EVar "True"))))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuild") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "target")) (EVar "input")) (EVar "outPath")) (EVar "keepIrCli")) (EVar "True")) (EVar "stampBuild")) (EApp (EVar "Some") (EVar "ask"))) (arm (PCon "Ok" (PVar "rep")) () (EMatch (EFieldAccess (EVar "rep") "diagEnvelope") (arm (PCon "Some" (PTuple (PVar "entry") (PVar "envelope"))) () (EApp (EDictApp "println") (EApp (EApp (EVar "withPreludeFields") (EVar "notices")) (EApp (EApp (EApp (EVar "envelopeWithNotes") (EVar "entry")) (EFieldAccess (EVar "rep") "notes")) (EVar "envelope"))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "withPreludeFields") (EVar "notices")) (EApp (EApp (EVar "cjBuildFailedJson") (EVar "input")) (ELit (LString "error: the emitter wrote no diagnostics envelope; an emitter built from an older medaka does not write one")))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))))) (arm (PCon "Err" (PVar "rep")) () (EMatch (EFieldAccess (EVar "rep") "diagEnvelope") (arm (PCon "Some" (PTuple PWild (PVar "envelope"))) () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "withPreludeFields") (EVar "notices")) (EVar "envelope")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "withPreludeFields") (EVar "notices")) (EApp (EApp (EVar "cjBuildFailedJson") (EVar "input")) (EApp (EVar "ppBuildReport") (EVar "rep")))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))))))))))
(DTypeSig false "jsonPreludeNotices" (TyFun (TyCon "BuildTarget") (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "jsonPreludeNotices" ((PVar "target") (PVar "prelude")) (EBlock (DoLet false false (PVar "staged") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "stage") (ELam ((PVar "field")) (EApp (EVar "Some") (ELam ((PVar "msg")) (EApp (EApp (EVar "setRef") (EVar "staged")) (EBinOp "++" (EFieldAccess (EVar "staged") "value") (EListLit (ETuple (EVar "field") (EVar "msg"))))))))) (DoLet false false (PVar "trees") (EMatch (EVar "target") (arm (PCon "TNative") () (EApp (EApp (EVar "staleLine") (EVar "TreesFile")) (EApp (EVar "checkPreludeElab") (EVar "prelude")))) (arm (PCon "TWasm") () (EVar "None")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "reportStaleLine") (EVar "dieMsg")) (EApp (EVar "stage") (ELit (LString "stalePreludeTrees")))) (EVar "trees"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "reportStaleLine") (EVar "dieMsg")) (EApp (EVar "stage") (ELit (LString "stalePreludeDecls")))) (EApp (EApp (EVar "staleLine") (EVar "DeclsFile")) (EApp (EVar "preludeDeclsVerdict") (EVar "prelude"))))) (DoExpr (EFieldAccess (EVar "staged") "value"))))
(DTypeSig false "withPreludeFields" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "withPreludeFields" ((PList) (PVar "envelope")) (EVar "envelope"))
(DFunDef false "withPreludeFields" ((PVar "notices") (PVar "envelope")) (EMatch (EApp (EVar "parseJson") (EVar "envelope")) (arm (PCon "Ok" (PCon "JObject" (PVar "pairs"))) () (EApp (EVar "stringify") (EApp (EVar "jObject") (EBinOp "++" (EApp (EMethodRef "toList") (EVar "pairs")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "field") (PVar "msg"))) (ETuple (EVar "field") (EApp (EVar "JString") (EVar "msg"))))) (EVar "notices")))))) (arm PWild () (EVar "envelope"))))
(DTypeSig false "cjFileNotFoundJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "cjFileNotFoundJson" ((PVar "target") (PVar "err")) (EApp (EApp (EApp (EVar "cjUnlocatedJson") (EVar "target")) (EVar "RFileNotFound")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot read file `")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "err"))) (ELit (LString "")))))
(DTypeSig false "cjSourceReadJson" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "cjSourceReadJson" ((PVar "target") (PCon "Some" (PVar "e"))) (EApp (EApp (EVar "cjFileNotFoundJson") (EVar "target")) (EVar "e")))
(DFunDef false "cjSourceReadJson" ((PVar "target") (PCon "None")) (EApp (EApp (EApp (EVar "cjUnlocatedJson") (EVar "target")) (EVar "RFileNotUtf8")) (EApp (EVar "sourceNotUtf8Message") (EVar "target"))))
(DTypeSig false "cjUnlocatedJson" (TyFun (TyCon "String") (TyFun (TyCon "DiagCode") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "cjUnlocatedJson" ((PVar "target") (PVar "code") (PVar "msg")) (EBlock (DoLet false false (PVar "diagJson") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EApp (EVar "codeText") (EVar "code")))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (ELit (LString "resolve")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))) (ETuple (ELit (LString "range")) (EVar "JNull")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka"))))))) (DoLet false false (PVar "filesJson") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "target"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "jArray") (EListLit (EVar "diagJson"))))))) (DoExpr (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "files")) (EApp (EVar "jArray") (EListLit (EVar "filesJson"))))))))))
(DTypeSig false "stripWarningLines" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripWarningLines" ((PVar "s")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "l")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "Warning: "))) (EVar "l"))))) (EApp (EVar "splitNl") (EVar "s")))))
(DTypeSig false "userSchemeLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "userSchemeLines" ((PVar "decls") (PVar "report")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "omFromNames") (EApp (EVar "topLevelNames") (EVar "decls"))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "filter") (EApp (EVar "namesUserBinding") (EVar "names"))) (EApp (EVar "splitNl") (EVar "report")))))))
(DTypeSig false "checkOkLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "checkOkLine" ((PVar "target") (PVar "filtered")) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EDictApp "count") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (ELit (LString ""))))) (EApp (EVar "splitNl") (EVar "filtered")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "-- ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": ok ("))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " declaration(s) checked, 0 errors)"))))))
(DTypeSig false "namesUserBinding" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "namesUserBinding" ((PVar "names") (PVar "l")) (EMatch (EApp (EVar "schemeLineName") (EVar "l")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "topLevelNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topLevelNames" ((PList)) (EListLit))
(DFunDef false "topLevelNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "topLevelNames") (EListLit (EVar "d"))) (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n"))) true)) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")) (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "topLevelNames") (EVar "rest")))
(DTypeSig false "emitLocatedWarnings" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitLocatedWarnings" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "emitLocatedWarnings" ((PVar "src") (PVar "file") (PVar "ws")) (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "src"))) (EVar "file"))) (EVar "ws")))))
(DTypeSig false "emitWarningLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emitWarningLines" ((PList)) (ELit LUnit))
(DFunDef false "emitWarningLines" ((PVar "ls")) (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EVar "ls"))))
(DTypeSig false "emitHiddenDiagNote" (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emitHiddenDiagNote" ((PLit (LInt 0))) (ELit LUnit))
(DFunDef false "emitHiddenDiagNote" ((PLit (LInt 1))) (EApp (EVar "ePutStrLn") (ELit (LString "1 further diagnostic in imported modules; rerun with --json to see it"))))
(DFunDef false "emitHiddenDiagNote" ((PVar "n")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " further diagnostics in imported modules; rerun with --json to see them")))))
(DTypeSig false "allWarnTriples" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "allWarnTriples" ((PVar "src") (PVar "file") (PVar "diags")) (EMatch (EApp (EApp (EMethodRef "filter") (EVar "diagIsWarn")) (EVar "diags")) (arm (PList) () (EListLit)) (arm (PVar "ws") () (EListLit (ETuple (EVar "file") (EVar "src") (EVar "ws"))))))
(DTypeSig false "nonEmptyTriples" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "nonEmptyTriples" ((PVar "ts")) (EApp (EApp (EMethodRef "filter") (EVar "tripleHasDiags")) (EVar "ts")))
(DTypeSig false "dropEntryTriple" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "dropEntryTriple" ((PList)) (EListLit))
(DFunDef false "dropEntryTriple" ((PList PWild)) (EListLit))
(DFunDef false "dropEntryTriple" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "dropEntryTriple") (EVar "rest"))))
(DTypeSig false "trimEntryTriple" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "trimEntryTriple" ((PList)) (EListLit))
(DFunDef false "trimEntryTriple" ((PList (PTuple (PVar "p") (PVar "s") (PVar "ds")))) (EListLit (ETuple (EVar "p") (EVar "s") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EVar "onTypecheckWarnChannel") (EVar "d"))))) (EVar "ds")))))
(DFunDef false "trimEntryTriple" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "trimEntryTriple") (EVar "rest"))))
(DTypeSig false "onTypecheckWarnChannel" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "onTypecheckWarnChannel" ((PCon "Diag" PWild (PVar "c") PWild PWild PWild PWild)) (EBinOp "==" (EVar "c") (EApp (EVar "Coded") (EVar "coherenceWarnCode"))))
(DTypeSig false "tripleHasDiags" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "tripleHasDiags" ((PTuple PWild PWild (PList))) (EVar "False"))
(DFunDef false "tripleHasDiags" (PWild) (EVar "True"))
(DTypeSig false "fmtHelpText" (TyCon "String"))
(DFunDef false "fmtHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka fmt — Format .mdk file(s)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka fmt [--check | --stdout | --write] <path>...\n")) (ELit (LString "\n")) (ELit (LString "Read-only unless --write is given.\n")) (ELit (LString "\n")) (ELit (LString "  (default)    same as --check: reports files that are not formatted\n")) (ELit (LString "               (exit 1 if any); prints nothing when already formatted.\n")) (ELit (LString "               Never writes.\n")) (ELit (LString "  --check      explicit form of the default\n")) (ELit (LString "  --stdout     print the formatted result to stdout (single file only);\n")) (ELit (LString "               never writes\n")) (ELit (LString "  --write, -w  rewrite the file(s) in place and print a one-line summary\n")) (ELit (LString "               (\"formatted N file(s)\" / \"already formatted\")\n")) (ELit (LString "\n")) (ELit (LString "A path may be a file or a directory (recursively expanded; dotfiles and\n")) (ELit (LString "dot-dirs are skipped).\n")))))
(DTypeSig false "runFmtCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runFmtCmd" ((PVar "argv")) (EBlock (DoLet false false PWild (EApp (EVar "assertFmtOneMode") (EVar "argv"))) (DoExpr (EApp (EVar "runFmtArgs") (EApp (EApp (EVar "requireArgs") (EVar "fmtArgSpec")) (EVar "argv"))))))
(DTypeSig false "assertFmtOneMode" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertFmtOneMode" ((PVar "argv")) (EMatch (EApp (EVar "fmtModeConflict") (EVar "argv")) (arm (PList) () (ELit LUnit)) (arm (PList PWild) () (ELit LUnit)) (arm (PVar "many") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka fmt: ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "many")))) (ELit (LString " are mutually exclusive; pass one"))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))))
(DTypeSig false "runFmtArgs" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runFmtArgs" ((PVar "a")) (EBlock (DoLet false false PWild (EApp (EVar "assertFmtNoDashTargets") (EFieldAccess (EVar "a") "positionals"))) (DoExpr (EMatch (ETuple (EApp (EVar "fmtModeOf") (EVar "a")) (EFieldAccess (EVar "a") "positionals")) (arm (PTuple PWild (PList)) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Usage: medaka fmt [--check | --stdout | --write] <path>...")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PTuple (PVar "mode") (PList (PVar "target"))) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "fmtOne") (EVar "mode")) (EVar "target"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EListLit (EVar "target")))))) (arm (PTuple (PVar "mode") (PVar "targets")) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EVar "targets")))))))
(DTypeSig false "assertFmtNoDashTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertFmtNoDashTargets" ((PList)) (ELit LUnit))
(DFunDef false "assertFmtNoDashTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "x")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "x")) (ELit (LString "-")))) (EApp (EVar "dieMsg") (EApp (EApp (EVar "unknownFlagMessage") (EVar "fmtArgSpec")) (EVar "x"))) (EApp (EVar "assertFmtNoDashTargets") (EVar "rest"))))
(DTypeSig false "fmtModeOf" (TyFun (TyCon "Args") (TyCon "FmtMode")))
(DFunDef false "fmtModeOf" ((PVar "a")) (EApp (EApp (EVar "fmtModeGo") (EFieldAccess (EVar "a") "given")) (EVar "FmtCheck")))
(DTypeSig false "fmtModeGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyCon "FmtMode") (TyCon "FmtMode"))))
(DFunDef false "fmtModeGo" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "fmtModeGo" ((PCons (PTuple (PVar "k") PWild) (PVar "rest")) (PVar "m")) (EIf (EBinOp "==" (EVar "k") (ELit (LString "--check"))) (EApp (EApp (EVar "fmtModeGo") (EVar "rest")) (EVar "FmtCheck")) (EIf (EBinOp "==" (EVar "k") (ELit (LString "--stdout"))) (EApp (EApp (EVar "fmtModeGo") (EVar "rest")) (EVar "FmtStdout")) (EIf (EBinOp "==" (EVar "k") (ELit (LString "--write"))) (EApp (EApp (EVar "fmtModeGo") (EVar "rest")) (EVar "FmtWrite")) (EIf (EVar "otherwise") (EApp (EApp (EVar "fmtModeGo") (EVar "rest")) (EVar "m")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "fmtManyTargets" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "fmtManyTargets" ((PCon "FmtStdout") PWild) (EApp (EVar "dieMsg") (ELit (LString "medaka fmt: --stdout requires exactly one file"))))
(DFunDef false "fmtManyTargets" ((PVar "mode") (PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EApp (EVar "dieMsg") (ELit (LString "medaka fmt: no .mdk files found")))) (arm PWild () (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "changed")) (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "files")) (ETuple (EVar "False") (ELit (LInt 0))))) (DoLet false false PWild (EMatch (EVar "mode") (arm (PCon "FmtWrite") () (EApp (EVar "putStrLn") (EApp (EVar "fmtWriteSummaryLine") (EVar "changed")))) (arm PWild () (ELit LUnit)))) (DoExpr (EIf (EVar "hadErr") (EApp (EVar "stageExit") (ELit (LInt 1))) (ELit LUnit)))))))))
(DTypeSig false "fmtFilesGo" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "Bool") (TyCon "Int")) (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyCon "Int")))))))
(DFunDef false "fmtFilesGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "fmtFilesGo" ((PVar "mode") (PCons (PVar "f") (PVar "rest")) (PTuple (PVar "errAcc") (PVar "changedAcc"))) (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "changed")) (EApp (EApp (EVar "fmtOneReport") (EVar "mode")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "rest")) (ETuple (EBinOp "||" (EVar "errAcc") (EVar "hadErr")) (EBinOp "+" (EVar "changedAcc") (EIf (EVar "changed") (ELit (LInt 1)) (ELit (LInt 0)))))))))
(DTypeSig false "fmtWriteSummaryLine" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "fmtWriteSummaryLine" ((PLit (LInt 0))) (ELit (LString "already formatted")))
(DFunDef false "fmtWriteSummaryLine" ((PLit (LInt 1))) (ELit (LString "formatted 1 file")))
(DFunDef false "fmtWriteSummaryLine" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "formatted ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " files"))))
(DTypeSig false "sourceReadLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "sourceReadLine" ((PVar "file") (PCon "None")) (EBinOp "++" (EBinOp "++" (ELit (LString "error: ")) (EApp (EMethodRef "display") (EApp (EVar "sourceNotUtf8Message") (EVar "file")))) (ELit (LString ""))))
(DFunDef false "sourceReadLine" ((PVar "file") (PCon "Some" (PVar "msg"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig false "fmtOneReport" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "fmtOneReport" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readSourceE") (EVar "file")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "sourceReadLine") (EVar "file")) (EVar "e")))) (DoExpr (ETuple (EVar "True") (EVar "False"))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EMatch (EApp (EApp (EApp (EVar "formatSourceChecked") (EVar "src")) (EVar "toks")) (EVar "pairs")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (ETuple (EVar "True") (EVar "False"))))) (arm (PCon "Ok" (PVar "formatted")) () (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "formatted"))) (DoExpr (ETuple (EVar "False") (EVar "False"))))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ETuple (EVar "False") (EVar "False")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (ETuple (EVar "True") (EVar "False")))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ETuple (EVar "False") (EVar "False")) (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (ETuple (EVar "True") (EVar "False"))))) (arm (PCon "Ok" PWild) () (ETuple (EVar "False") (EVar "True"))))))))))))))
(DTypeSig false "fmtArgSpec" (TyCon "ArgSpec"))
(DFunDef false "fmtArgSpec" () (EApp (EApp (EVar "spec") (ELit (LString "fmt"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--check")))) (ELit (LString "report unformatted files; write nothing"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--stdout")))) (ELit (LString "print the formatted source of one file"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--write")) (ELit (LString "-w")))) (ELit (LString "rewrite the file in place"))))))
(DTypeSig false "fmtModeConflict" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "fmtModeConflict" ((PVar "argv")) (EBlock (DoLet false false (PVar "writeOn") (EBinOp "||" (EApp (EApp (EVar "contains") (ELit (LString "--write"))) (EVar "argv")) (EApp (EApp (EVar "contains") (ELit (LString "-w"))) (EVar "argv")))) (DoLet false false (PVar "named") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EApp (EVar "contains") (EVar "f")) (EVar "argv")))) (EListLit (ELit (LString "--check")) (ELit (LString "--stdout"))))) (DoExpr (EIf (EVar "writeOn") (EBinOp "++" (EVar "named") (EListLit (ELit (LString "--write")))) (EVar "named")))))
(DTypeSig false "fmtOne" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "fmtOne" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readSourceE") (EVar "file")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "dieMsg") (EApp (EApp (EVar "sourceReadLine") (EVar "file")) (EVar "e")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EMatch (EApp (EApp (EApp (EVar "formatSourceChecked") (EVar "src")) (EVar "toks")) (EVar "pairs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "dieMsg") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (arm (PCon "Ok" (PVar "formatted")) () (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EApp (EVar "putStr") (EVar "formatted"))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ELit LUnit) (EApp (EVar "dieMsg") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted")))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EApp (EVar "putStrLn") (ELit (LString "already formatted"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "putStrLn") (ELit (LString "formatted 1 file")))))))))))))))
(DTypeSig false "codemodHelpText" (TyCon "String"))
(DFunDef false "codemodHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka codemod — Apply a named source-preserving AST transform\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka codemod <name> [flags] [--write|--stdout] <paths...>\n")) (ELit (LString "\n")) (ELit (LString "  (default)  dry-run: prints \"would rewrite: <file>\" per changed file,\n")) (ELit (LString "             exits 1 if any file would change. Never writes.\n")) (ELit (LString "  --write    rewrite only the files that actually change\n")) (ELit (LString "  --stdout   print one file's result (single file only)\n")) (ELit (LString "\n")) (ELit (LString "Any other --flag consumes the next token as its value, passed to the\n")) (ELit (LString "named codemod. Run `medaka codemod` with no arguments to list the\n")) (ELit (LString "available codemods.\n")) (ELit (LString "\n")) (ELit (LString "NOTE: `--help`/`-h` is only recognized in the FIRST position — as\n")) (ELit (LString "`medaka codemod --help`, before a codemod name. `medaka codemod <name>\n")) (ELit (LString "--help` is NOT special-cased (it is a codemod flag) and codemod-specific\n")) (ELit (LString "help does not exist yet.\n")))))
(DTypeSig false "runCodemodCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCodemodCmd" ((PList)) (EApp (EVar "listCodemodsAndExit") (ELit LUnit)))
(DFunDef false "runCodemodCmd" ((PCons (PVar "name") (PVar "rest"))) (EMatch (EApp (EVar "findCodemod") (EVar "name")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EIf (EApp (EVar "lintTargetExists") (EVar "name")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: missing codemod name; `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is a path, and the codemod name comes first")))) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: unknown codemod `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`")))))) (DoExpr (EApp (EVar "listCodemodsAndExit") (ELit LUnit))))) (arm (PCon "Some" (PVar "cm")) () (EMatch (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmDry")) (EListLit)) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PTuple (PVar "mode") (PVar "cargs") (PVar "targets"))) () (EMatch (EApp (EApp (EVar "codemodMk") (EVar "cm")) (EVar "cargs")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "xf")) () (EBlock (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EApp (EVar "dieMsg") (ELit (LString "medaka codemod: no .mdk files found")))) (arm PWild () (EMatch (EVar "mode") (arm (PCon "CmStdout") () (EMatch (EVar "files") (arm (PList (PVar "one")) () (EApp (EApp (EApp (EVar "codemodStdout") (EVar "xf")) (EApp (EApp (EVar "codemodWarnDecls") (EVar "cm")) (EVar "cargs"))) (EVar "one"))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka codemod: --stdout requires exactly one file")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))))) (arm PWild () (EIf (EApp (EApp (EApp (EApp (EApp (EVar "codemodFilesGo") (EVar "mode")) (EVar "xf")) (EApp (EApp (EVar "codemodWarnDecls") (EVar "cm")) (EVar "cargs"))) (EVar "files")) (EVar "False")) (EApp (EVar "stageExit") (ELit (LInt 1))) (ELit LUnit)))))))))))))))
(DTypeSig false "listCodemodsAndExit" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "listCodemodsAndExit" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Usage: medaka codemod <name> [flags] [--write|--stdout] <paths...>")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Available codemods:")))) (DoExpr (EApp (EVar "dieMsg") (EVar "codemodListing")))))
(DTypeSig false "splitCodemodArgv" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CodeMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "CodeMode") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "splitCodemodArgv" ((PList) (PVar "mode") (PVar "cargs") (PVar "paths")) (EApp (EVar "Ok") (ETuple (EVar "mode") (EApp (EVar "reverseL") (EVar "cargs")) (EApp (EVar "reverseL") (EVar "paths")))))
(DFunDef false "splitCodemodArgv" ((PCons (PLit (LString "--write")) (PVar "rest")) PWild (PVar "cargs") (PVar "paths")) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmWrite")) (EVar "cargs")) (EVar "paths")))
(DFunDef false "splitCodemodArgv" ((PCons (PLit (LString "--stdout")) (PVar "rest")) PWild (PVar "cargs") (PVar "paths")) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmStdout")) (EVar "cargs")) (EVar "paths")))
(DFunDef false "splitCodemodArgv" ((PCons (PVar "tok") (PVar "rest")) (PVar "mode") (PVar "cargs") (PVar "paths")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "tok")) (EMatch (EApp (EVar "codemodFlagEq") (EVar "tok")) (arm (PCon "Some" (PTuple (PVar "nm") (PVar "v"))) () (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "mode")) (EBinOp "::" (EVar "v") (EBinOp "::" (EVar "nm") (EVar "cargs")))) (EVar "paths"))) (arm (PCon "None") () (EMatch (EVar "rest") (arm (PCons (PVar "v") (PVar "rest2")) () (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest2")) (EVar "mode")) (EBinOp "::" (EVar "v") (EBinOp "::" (EVar "tok") (EVar "cargs")))) (EVar "paths"))) (arm (PList) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: flag `")) (EApp (EMethodRef "display") (EVar "tok"))) (ELit (LString "` requires a value")))))))) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "mode")) (EVar "cargs")) (EBinOp "::" (EVar "tok") (EVar "paths")))))
(DTypeSig false "codemodFlagEq" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "codemodFlagEq" ((PVar "tok")) (EApp (EApp (EApp (EVar "codemodFlagEqGo") (EVar "tok")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "tok"))))
(DTypeSig false "codemodFlagEqGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "codemodFlagEqGo" ((PVar "tok") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "tok")) (ELit (LString "="))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 2))) (EVar "None") (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "tok")) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "tok"))))) (EApp (EApp (EApp (EVar "codemodFlagEqGo") (EVar "tok")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig false "codemodStdout" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "codemodStdout" ((PVar "xf") (PVar "warnFn") (PVar "file")) (EMatch (EApp (EVar "readSourceE") (EVar "file")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "dieMsg") (EApp (EApp (EVar "sourceReadLine") (EVar "file")) (EVar "e")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EVar "codemodSource") (EVar "xf")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "dieMsg") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (arm (PCon "Ok" (PVar "result")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitCodemodWarns") (EVar "warnFn")) (EVar "file")) (EVar "src"))) (DoExpr (EMatch (EVar "result") (arm (PCon "None") () (EApp (EVar "putStr") (EVar "src"))) (arm (PCon "Some" (PVar "out")) () (EApp (EVar "putStr") (EVar "out")))))))))))
(DTypeSig false "codemodFilesGo" (TyFun (TyCon "CodeMode") (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "codemodFilesGo" (PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "codemodFilesGo" ((PVar "mode") (PVar "xf") (PVar "warnFn") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "signal") (EApp (EApp (EApp (EApp (EVar "codemodOneReport") (EVar "mode")) (EVar "xf")) (EVar "warnFn")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "codemodFilesGo") (EVar "mode")) (EVar "xf")) (EVar "warnFn")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "signal"))))))
(DTypeSig false "codemodOneReport" (TyFun (TyCon "CodeMode") (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "codemodOneReport" ((PVar "mode") (PVar "xf") (PVar "warnFn") (PVar "file")) (EMatch (EApp (EVar "readSourceE") (EVar "file")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "sourceReadLine") (EVar "file")) (EVar "e")))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EVar "codemodSource") (EVar "xf")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "result")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitCodemodWarns") (EVar "warnFn")) (EVar "file")) (EVar "src"))) (DoExpr (EMatch (EVar "result") (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "out")) () (EMatch (EVar "mode") (arm (PCon "CmWrite") () (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "out")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EVar "False")))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "would rewrite: ")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ""))))) (DoExpr (EVar "True"))))))))))))))
(DTypeSig false "emitCodemodWarns" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitCodemodWarns" ((PVar "warnFn") (PVar "file") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "decls") PWild) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoExpr (EApp (EApp (EVar "emitWarnLines") (EVar "file")) (EApp (EVar "warnFn") (EVar "decls"))))))
(DTypeSig false "emitWarnLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitWarnLines" (PWild (PList)) (ELit LUnit))
(DFunDef false "emitWarnLines" ((PVar "file") (PCons (PVar "w") (PVar "ws"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": warning: "))) (EApp (EMethodRef "display") (EVar "w"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EVar "emitWarnLines") (EVar "file")) (EVar "ws")))))
(DTypeSig false "newUsageLine" (TyCon "String"))
(DFunDef false "newUsageLine" () (ELit (LString "Usage: medaka new <name>")))
(DTypeSig false "newArgSpec" (TyCon "ArgSpec"))
(DFunDef false "newArgSpec" () (EApp (EApp (EVar "spec") (ELit (LString "new"))) (EListLit)))
(DTypeSig false "runNewCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runNewCmd" ((PList (PVar "arg"))) (EIf (EBinOp "||" (EBinOp "==" (EVar "arg") (ELit (LString "--help"))) (EBinOp "==" (EVar "arg") (ELit (LString "-h")))) (EApp (EVar "putStrLn") (EVar "newUsageLine")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "arg")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "arg")) (ELit (LString "-")))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "unknownFlagMessage") (EVar "newArgSpec")) (EVar "arg")))) (DoExpr (EApp (EVar "dieMsg") (EVar "newUsageLine")))) (EBlock (DoLet false false (PVar "code") (EApp (EVar "newProject") (EVar "arg"))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (ELit LUnit) (EApp (EVar "stageExit") (EVar "code"))))))))
(DFunDef false "runNewCmd" ((PVar "args")) (EMatch (EApp (EApp (EVar "filterList") (EApp (EVar "startsWith") (ELit (LString "-")))) (EVar "args")) (arm (PCons (PVar "flagTok") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "unknownFlagMessage") (EVar "newArgSpec")) (EVar "flagTok")))) (DoExpr (EApp (EVar "dieMsg") (EVar "newUsageLine"))))) (arm (PList) () (EApp (EVar "dieMsg") (EVar "newUsageLine")))))
(DTypeSig false "buildArgSpec" (TyCon "ArgSpec"))
(DFunDef false "buildArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "build"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--keep-ir")))) (ELit (LString "keep the emitted IR beside the output"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--allow-internal")))) (ELit (LString "permit internal-only externs outside stdlib/"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the structured-diagnostics envelope"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--stamp-build")))) (ELit (LString "stamp the commit, compiler fingerprint and build date into the binary"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "-o")))) (ELit (LString "PATH"))) (ELit (LString "output path for the binary"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--target")))) (ELit (LString "PROFILE"))) (ELit (LString "target profile to build for"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--emit-rt-obj")))) (ELit (LString "PATH"))) (ELit (LString "precompile the C runtime to an object"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--emit-prelude-obj")))) (ELit (LString "PATH"))) (ELit (LString "precompile the prelude to an object")))))))
(DTypeSig false "runBuildCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildCmd" ((PVar "argv")) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (ELit (LString "--help"))) (EVar "argv")) (EApp (EApp (EVar "contains") (ELit (LString "-h"))) (EVar "argv"))) (EApp (EVar "buildUsage") (ELit LUnit)) (EApp (EVar "runBuildModes") (EApp (EApp (EVar "requireArgs") (EVar "buildArgSpec")) (EVar "argv")))))
(DTypeSig false "runBuildModes" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildModes" ((PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--emit-rt-obj"))) (EVar "a")) (arm (PCon "Some" (PVar "objPath")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "emitRtObj") (EVar "cc")) (EVar "root")) (EVar "objPath")) (arm (PCon "Ok" (PVar "rep")) () (EApp (EDictApp "println") (EApp (EVar "ppBuildReport") (EVar "rep")))) (arm (PCon "Err" (PVar "rep")) () (EApp (EVar "dieMsg") (EApp (EVar "ppBuildReport") (EVar "rep")))))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--emit-prelude-obj"))) (EVar "a")) (arm (PCon "Some" (PVar "objPath")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "./medaka")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "emitPreludeObj") (EVar "cc")) (EVar "root")) (EVar "medaka")) (EVar "objPath")) (arm (PCon "Ok" (PVar "rep")) () (EApp (EDictApp "println") (EApp (EVar "ppBuildReport") (EVar "rep")))) (arm (PCon "Err" (PVar "rep")) () (EApp (EVar "dieMsg") (EApp (EVar "ppBuildReport") (EVar "rep")))))))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a")) (EApp (EVar "runBuildJsonEntry") (EVar "a")) (EApp (EVar "runBuildPlainCmd") (EVar "a"))))))))
(DTypeSig false "runBuildPlainCmd" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildPlainCmd" ((PVar "a")) (EBlock (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false (PVar "perfT0") (EApp (EVar "now") (ELit LUnit))) (DoExpr (EMatch (EApp (EVar "parseBuildArgs") (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PTuple (PVar "input") (PVar "outOpt") PWild)) () (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "input"))) (EApp (EVar "dieMsg") (EBinOp "++" (ELit (LString "error: no such file: ")) (EVar "input"))) (EBlock (DoLet false false (PVar "target") (EApp (EApp (EVar "buildTargetOrDie") (EVar "a")) (EVar "input"))) (DoExpr (EApp (EVar "perfArm") (EVar "perfT0"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "inputAbs") (EVar "input")) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "flag") (ELit (LString "--allow-internal"))) (EVar "a"))) (DoLet false false (PVar "keepIrCli") (EApp (EApp (EVar "flag") (ELit (LString "--keep-ir"))) (EVar "a"))) (DoLet false false (PVar "stampBuild") (EApp (EApp (EVar "flag") (ELit (LString "--stamp-build"))) (EVar "a"))) (DoLet false false (PVar "outPath") (EMatch (EVar "outOpt") (arm (PCon "Some" (PVar "o")) () (EVar "o")) (arm (PCon "None") () (EApp (EApp (EVar "defaultOutPath") (EVar "target")) (EVar "input"))))) (DoExpr (EMatch (EApp (EVar "readPreludeSources") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "prelude")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "nativeTreesReport") (EVar "target")) (EVar "prelude"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuild") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "target")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")) (EVar "False")) (EVar "stampBuild")) (EApp (EVar "Some") (ERecordCreate "GateAsk" ((fa "askAllowInternal" (EVar "allowInternal")) (fa "askDiagJson" (EVar "False")))))) (arm (PCon "Ok" (PVar "rep")) () (EBlock (DoLet false false (PVar "perfTEmit") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "emit"))) (EBinOp "-" (EVar "perfTEmit") (EVar "perfT0"))) (EVar "input"))) (DoLet false false PWild (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTEmit") (EVar "perfT0")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "ppBuildReport") (EVar "rep")))))) (arm (PCon "Err" (PVar "rep")) () (EApp (EVar "dieMsg") (EApp (EVar "ppBuildReport") (EVar "rep")))))))))))))))))
(DTypeSig false "nativeTreesReport" (TyFun (TyCon "BuildTarget") (TyFun (TyCon "PreludeInputs") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "nativeTreesReport" ((PCon "TNative") (PVar "prelude")) (EApp (EVar "reportChildTrees") (EVar "prelude")))
(DFunDef false "nativeTreesReport" ((PCon "TWasm") (PVar "prelude")) (EApp (EApp (EApp (EVar "reportDecls") (EVar "None")) (EVar "dieMsg")) (EVar "prelude")))
(DTypeSig false "runBuildJsonEntry" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildJsonEntry" ((PVar "a")) (EMatch (EApp (EVar "parseBuildArgs") (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "cjBuildFailedJson") (ELit (LString ""))) (EVar "msg")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PTuple (PVar "input") (PVar "outOpt") PWild)) () (EMatch (EApp (EApp (EVar "selectBuildProfile") (EVar "a")) (EVar "input")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EDictApp "println") (EApp (EApp (EVar "cjBuildFailedJson") (ELit (LString ""))) (EVar "msg")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "target")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "flag") (ELit (LString "--allow-internal"))) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildJsonCmd") (EVar "a")) (EVar "allowInternal")) (EVar "root")) (EVar "stdlibDir")) (EVar "input")) (EVar "outOpt")) (EVar "target")))))))))
(DTypeSig false "buildUsage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "buildUsage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "usage: medaka build [--target <profile>] <file.mdk> [-o <out>] [--keep-ir] [--allow-internal] [--json] [--stamp-build]\n")) (ELit (LString "\n")) (ELit (LString "  -o <out>          output path for the binary (default: <file> with its extension dropped)\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "  --target <profile> target profile, one of: ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "buildableNames")))) (ELit (LString "\n"))) (ELit (LString "                    (default: [target] profile in medaka.toml, else llvm/native-posix).\n")) (ELit (LString "                    The program is checked against the profile before it is lowered;\n")) (ELit (LString "                    its backend picks the emitter (LLVM + clang, or WasmGC + wasm-tools)\n")) (ELit (LString "  --json            emit the {\"files\":[...]} structured-diagnostics envelope (same\n")) (ELit (LString "                    schema as `medaka check --json`) instead of human text; a genuine\n")) (ELit (LString "                    build-stage (emitter/clang) failure carries code R-BUILD-FAILED\n")) (ELit (LString "  --keep-ir         keep the emitted IR (.ll for native, .wat for wasm) at <out>.ll/.wat\n")) (ELit (LString "                    instead of discarding it with the build's scratch directory; the\n")) (ELit (LString "                    kept path is printed. Env var MEDAKA_KEEP_IR=1 does the same for a\n")) (ELit (LString "                    build invoked by something else (e.g. a test harness)\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")) (ELit (LString "  --stamp-build     bake build provenance into the binary: the project's git commit\n")) (ELit (LString "                    (with a -dirty suffix on a modified tree), the fingerprint of\n")) (ELit (LString "                    the compiler that built it, and the UTC build date, read back at\n")) (ELit (LString "                    run time through buildCommit/buildFingerprint/buildDate. Without\n")) (ELit (LString "                    it those three read \"\", which is what every other build path\n")) (ELit (LString "                    links; a field that cannot be derived is stamped empty\n")) (ELit (LString "  --emit-rt-obj <p> compile only runtime/medaka_rt.c to a reusable object at <p> (with\n")) (ELit (LString "                    the same flags a normal link uses, including ThinLTO bitcode by\n")) (ELit (LString "                    default) and exit; point MEDAKA_RT_OBJ at it to skip recompiling\n")) (ELit (LString "                    the runtime on every subsequent build. MEDAKA_RT_OBJ must be paired\n")) (ELit (LString "                    with the matching link mode (MEDAKA_NO_LTO set for both, or for\n")) (ELit (LString "                    neither) — a mismatch either fails to link or silently loses\n")) (ELit (LString "                    ThinLTO's inlining\n")) (ELit (LString "  --emit-prelude-obj <p>\n")) (ELit (LString "                    compile only stdlib/core.mdk to a reusable object at <p> (with the\n")) (ELit (LString "                    same flags a normal link uses) and exit; point MEDAKA_PRELUDE_OBJ at\n")) (ELit (LString "                    it to skip re-optimising the prelude on every subsequent build.\n")) (ELit (LString "                    Opt-in: separate objects cannot inline the prelude into user code\n")) (ELit (LString "\n")) (ELit (LString "runtime object cache (ON by default):\n")) (ELit (LString "  Every native build links a compiled runtime/medaka_rt.c. Rather than recompile\n")) (ELit (LString "  it each time (~0.76s), build caches the object, keyed on a hash of the .c\n")) (ELit (LString "  source, the C compiler and its version, and the exact compile flags, so a\n")) (ELit (LString "  changed runtime or compiler never reuses a stale object.\n")) (ELit (LString "  Location (first that applies): $MEDAKA_CACHE_DIR, else\n")) (ELit (LString "  $XDG_CACHE_HOME/medaka, else $HOME/.cache/medaka.\n")) (ELit (LString "  MEDAKA_NO_OBJ_CACHE=1  disable the cache; compile medaka_rt.c inline every build\n")) (ELit (LString "  MEDAKA_CACHE_DIR=<d>   put the cache somewhere else (e.g. a per-CI-job scratch dir)\n")) (ELit (LString "  An explicit MEDAKA_RT_OBJ still wins over the cache. Every cache failure is\n")) (ELit (LString "  fail-open: build falls back to the inline compile, never to an error.\n")) (ELit (LString "\n")) (ELit (LString "MEDAKA_NO_LTO=1 (any non-empty value): force the plain link instead of the\n")) (ELit (LString "  default ThinLTO link. For a consumer that needs a NATIVE runtime object\n")) (ELit (LString "  (which `ld -r` can merge and ThinLTO bitcode cannot), e.g.\n")) (ELit (LString "  test/diff_compiler_llvm_ffi.sh and the memcheck probe in\n")) (ELit (LString "  pds/test/constant_time_signing.sh. Set it for both the build that emits\n")) (ELit (LString "  the object and the build that links it.\n"))))))
(DTypeSig false "defaultOutPath" (TyFun (TyCon "BuildTarget") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "defaultOutPath" ((PCon "TNative") (PVar "input")) (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))))
(DFunDef false "defaultOutPath" ((PCon "TWasm") (PVar "input")) (EBinOp "++" (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))) (ELit (LString ".wasm"))))
(DTypeSig false "parseBuildArgs" (TyFun (TyCon "Args") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))
(DFunDef false "parseBuildArgs" ((PVar "a")) (EMatch (EApp (EVar "buildTargetOf") (EApp (EApp (EVar "lastValue") (ELit (LString "--target"))) (EVar "a"))) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PVar "target")) () (EApp (EApp (EApp (EVar "finishBuildArgs") (EFieldAccess (EVar "a") "positionals")) (EApp (EApp (EVar "lastValue") (ELit (LString "-o"))) (EVar "a"))) (EVar "target")))))
(DTypeSig false "buildTargetOf" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BuildTarget"))))
(DFunDef false "buildTargetOf" ((PCon "None")) (EApp (EVar "Ok") (EVar "TNative")))
(DFunDef false "buildTargetOf" ((PCon "Some" (PVar "v"))) (EApp (EVar "parseTarget") (EVar "v")))
(DTypeSig false "parseTarget" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BuildTarget"))))
(DFunDef false "parseTarget" ((PVar "name")) (EMatch (EApp (EVar "lookupProfile") (EVar "name")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "error: ")) (EVar "m")))) (arm (PCon "Ok" (PVar "p")) () (EMatch (EApp (EVar "profileBackend") (EVar "p")) (arm (PCon "BackendLlvm") () (EApp (EVar "Ok") (EVar "TNative"))) (arm (PCon "BackendWasmgc") () (EApp (EVar "Ok") (EVar "TWasm"))) (arm (PCon "BackendEval") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is not buildable (buildable: "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "buildableNames")))) (ELit (LString ")")))))))))
(DTypeSig false "selectBuildProfile" (TyFun (TyCon "Args") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BuildTarget"))))))
(DFunDef false "selectBuildProfile" ((PVar "a") (PVar "input")) (EBlock (DoLet false false (PVar "named") (EMatch (EApp (EApp (EVar "lastValue") (ELit (LString "--target"))) (EVar "a")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EVar "v"))) (arm (PCon "None") () (EApp (EApp (EMethodRef "map") (EApp (EVar "optionOr") (ELit (LString "llvm/native-posix")))) (EApp (EVar "manifestProfileOf") (EVar "input")))))) (DoExpr (EMatch (EVar "named") (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "error: ")) (EVar "m")))) (arm (PCon "Ok" (PVar "name")) () (EMatch (EApp (EVar "lookupProfile") (EVar "name")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (ELit (LString "error: ")) (EVar "m")))) (arm (PCon "Ok" (PVar "p")) () (EMatch (EApp (EVar "parseTarget") (EVar "name")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "target")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "selectedProfile")) (EApp (EVar "Some") (EVar "p")))) (DoExpr (EApp (EVar "Ok") (EVar "target")))))))))))))
(DTypeSig false "buildTargetOrDie" (TyFun (TyCon "Args") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildTarget")))))
(DFunDef false "buildTargetOrDie" ((PVar "a") (PVar "input")) (EMatch (EApp (EApp (EVar "selectBuildProfile") (EVar "a")) (EVar "input")) (arm (PCon "Ok" (PVar "target")) () (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "dieMsg") (EVar "msg"))) (DoExpr (EVar "TNative"))))))
(DTypeSig false "finishBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))))
(DFunDef false "finishBuildArgs" ((PList) PWild PWild) (EApp (EVar "Err") (ELit (LString "usage: medaka build [--target <profile>] <file.mdk> [-o <out>]"))))
(DFunDef false "finishBuildArgs" ((PList (PVar "input")) (PVar "out") (PVar "target")) (EApp (EVar "Ok") (ETuple (EVar "input") (EVar "out") (EVar "target"))))
(DFunDef false "finishBuildArgs" (PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: medaka build takes exactly one input file"))))
(DTypeSig false "finishRunEval" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "ProgramFacts") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyFun (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))) (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "finishRunEval" ((PVar "target") (PVar "jsonMode") (PVar "facts") (PVar "elaborated") (PVar "mods") (PVar "cohWarns") (PVar "postPerf")) (EBlock (DoLet false false (PVar "tsrc") (EApp (EVar "readFileSafe") (EVar "target"))) (DoLet false false PWild (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EMatch (EApp (EVar "mainEntryError") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EMatch (EVar "jsonMode") (arm (PCon "True") () (EApp (EVar "runAbortJson") (EListLit (ETuple (EVar "target") (EVar "tsrc") (EListLit (EVar "d")))))) (arm (PCon "False") () (EApp (EVar "runAbort") (EApp (EApp (EApp (EVar "ppMainEntryError") (EVar "tsrc")) (EVar "target")) (EVar "d")))))) (arm (PCon "None") () (ELit LUnit)))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false PWild (EIf (EVar "jsonMode") (EApp (EApp (EVar "setRef") (EVar "pendingRunDiags")) (EApp (EVar "nonEmptyTriples") (EVar "cohWarns"))) (EApp (EVar "emitWarningLines") (EApp (EApp (EDictApp "flatMap") (EVar "renderTripleWarnings")) (EVar "cohWarns"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "runJsonMode")) (EVar "jsonMode"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EApp (EApp (EVar "runProgramOutput") (EVar "facts")) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated"))))) (DoLet false false PWild (EApp (EVar "postPerf") (ELit LUnit))) (DoExpr (EApp (EVar "flushPendingRunDiags") (EVar "jsonMode")))))
(DTypeSig false "flushPendingRunDiags" (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "flushPendingRunDiags" ((PCon "False")) (ELit LUnit))
(DFunDef false "flushPendingRunDiags" ((PCon "True")) (EApp (EVar "flushRunEnvelope") (EUnOp "!" (EVar "pendingRunDiags"))))
(DTypeSig false "runHelpText" (TyCon "String"))
(DFunDef false "runHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka run — Type-check and run a program (interpreter)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka run [--json] [--allow-internal] [--release] <file.mdk | -> [args...]\n")) (ELit (LString "\n")) (ELit (LString "  --json            emit the Diag JSON envelope on stderr instead of human\n")) (ELit (LString "                    text, for a runtime panic, a static (resolve/type) error\n")) (ELit (LString "                    in the program, or a warning in a SINGLE-FILE program. A\n")) (ELit (LString "                    clean run emits no envelope at all; a multi-module\n")) (ELit (LString "                    program's warnings are not reported by `run` (issue\n")) (ELit (LString "                    #2818) — use `medaka check --json` for those. KNOWN GAP:\n")) (ELit (LString "                    a usage error (bad flag, missing file) or a load/parse\n")) (ELit (LString "                    failure (bad import, malformed source) still prints human\n")) (ELit (LString "                    text on stderr and exits 1 with no envelope, so a\n")) (ELit (LString "                    consumer must handle both.\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")) (ELit (LString "  --target <name>   target profile `main` must also fit; every run is\n")) (ELit (LString "                    checked against eval/run (default: [target] profile in\n")) (ELit (LString "                    medaka.toml)\n")) (ELit (LString "  --release         accepted, ignored — the interpreter has no release mode.\n")) (ELit (LString "                    There is no `build --release`; a native build is always\n")) (ELit (LString "                    optimized. Kept so a `--release` in a shared script does\n")) (ELit (LString "                    not make `medaka run` fail.\n")) (ELit (LString "\n")) (ELit (LString "`run` is the interpreter: it starts at once but runs slowly. For speed, use\n")) (ELit (LString "`medaka build`, the fast native path.\n")) (ELit (LString "\n")) (ELit (LString "Args after <file.mdk> are passed through to the program's own `args`.\n")) (ELit (LString "`medaka run -` reads the program from standard input (a heredoc), so the\n")) (ELit (LString "program's own `readAll`/`readLine` see end-of-file; a script that is also a\n")) (ELit (LString "filter must be run from a file. Imports resolve against the current directory.\n")) (ELit (LString "Inline-eval (`-e <expr>`) is NOT supported; use `medaka run -` and a heredoc.\n")))))
(DTypeSig false "runArgSpec" (TyCon "ArgSpec"))
(DFunDef false "runArgSpec" () (EApp (EApp (EVar "spec") (ELit (LString "run"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the structured-diagnostics envelope on stderr"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--allow-internal")))) (ELit (LString "permit internal-only externs outside stdlib/"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--release")))) (ELit (LString "accepted and ignored (eval is never optimized)"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--target")))) (ELit (LString "NAME"))) (ELit (LString "target profile `main` must also fit"))))))
(DTypeSig false "runEvalPerf" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "Int") (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "runEvalPerf" ((PVar "perfOn") (PVar "target") (PVar "perfT0") (PVar "perfTCheck") (PVar "allocCheck") (PVar "opCheck") PWild) (EBlock (DoLet false false (PVar "perfTEval") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emitPhaseAO") (EVar "perfOn")) (ELit (LString "eval"))) (EBinOp "-" (EVar "perfTEval") (EVar "perfTCheck"))) (EBinOp "-" (EApp (EVar "allocSnap") (ELit LUnit)) (EVar "allocCheck"))) (EVar "target")) (EBinOp "-" (EApp (EVar "opSnap") (ELit LUnit)) (EVar "opCheck")))) (DoExpr (EApp (EApp (EVar "emitTotal") (EVar "perfOn")) (EBinOp "-" (EVar "perfTEval") (EVar "perfT0"))))))
(DTypeSig false "runRunCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runRunCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "perfOn") (EApp (EVar "perfEnabled") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "setOpCounting") (EVar "perfOn"))) (DoLet false false (PVar "perfT0") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "runFlagGiven") (ELit (LString "--json"))) (EVar "argv"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "perfSinkOn")) (EBinOp "&&" (EVar "jsonMode") (EVar "perfOn")))) (DoExpr (EMatch (EApp (EVar "runArgvFilter") (EVar "argv")) (arm (PList) () (EApp (EVar "runAbort") (ELit (LString "usage: medaka run [--json] [--allow-internal] [--release] [--target <profile>] <file.mdk | -> [args...]")))) (arm (PCons (PVar "target") PWild) ((GBool (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "target") (ELit (LString "-"))) (EBinOp ">" (EApp (EVar "stringLength") (EVar "target")) (ELit (LInt 0)))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "target")) (ELit (LString "-")))))) (EApp (EVar "runAbort") (EApp (EApp (EVar "unknownFlagMessage") (EVar "runArgSpec")) (EVar "target")))) (arm (PCons (PVar "target") PWild) ((GBool (EBinOp "&&" (EBinOp "||" (EApp (EVar "hasSlash") (EVar "target")) (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "target"))) (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "target")))))) (EApp (EVar "runAbort") (EBinOp "++" (ELit (LString "error: no such file: ")) (EVar "target")))) (arm (PCons (PVar "target") PWild) ((GBool (EBinOp "==" (EVar "target") (EVar "stdinEntry")))) (EApp (EVar "runAbort") (ELit (LString "error: `<stdin>` is not a file; use `medaka run -` to read the program from standard input")))) (arm (PCons (PVar "rawTarget") (PVar "progArgs")) () (EBlock (DoLet false false (PVar "isStdin") (EBinOp "==" (EVar "rawTarget") (ELit (LString "-")))) (DoLet false false (PVar "target") (EIf (EVar "isStdin") (EVar "stdinEntry") (EVar "rawTarget"))) (DoLet false false (PVar "stdinText") (EIf (EVar "isStdin") (EApp (EVar "orExit") (EApp (EVar "readStdinProgram") (ELit LUnit))) (ELit (LString "")))) (DoExpr (EApp (EVar "perfArm") (EVar "perfT0"))) (DoExpr (EApp (EApp (EVar "carryTargetProfile") (EApp (EVar "runTargetFlag") (EVar "argv"))) (EVar "target"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "runFlagGiven") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "progArgsRef")) (EVar "progArgs"))) (DoLet false false (PVar "prelude") (EApp (EVar "orExit") (EApp (EVar "readPreludeSources") (EVar "stdlibDir")))) (DoLet false false (PVar "rsrc") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (DoLet false false (PVar "csrc") (EFieldAccess (EVar "prelude") "pnCoreSrc")) (DoLet false false (PVar "tsrc") (EIf (EVar "isStdin") (EVar "stdinText") (EApp (EVar "readFileSafe") (EVar "target")))) (DoLet false false (PVar "readEntry") (EApp (EVar "stdinReadOverride") (EVar "stdinText"))) (DoLet false false (PVar "modsWithPath") (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (EVar "readEntry")) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "reportShippedHeaders") (EApp (EVar "deferredInto") (EVar "jsonMode"))) (EVar "prelude"))) (DoLet false false PWild (EApp (EVar "orExit") (EApp (EApp (EVar "mapErr") (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target"))) (EApp (EVar "parseResult") (EVar "tsrc"))))) (DoLet false false PWild (EApp (EVar "runAbort") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))) (DoExpr (EApp (EVar "panic") (ELit (LString "unreachable")))))) (arm (PCon "Ok" (PVar "mp")) () (EVar "mp")))) (DoLet false false (PVar "mods") (EApp (EApp (EMethodRef "map") (EVar "dropPathTriple")) (EVar "modsWithPath"))) (DoLet false false (PVar "pathMap") (EApp (EApp (EMethodRef "map") (EVar "modIdToPath")) (EVar "modsWithPath"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "modulePathMap")) (EVar "pathMap"))) (DoLet false false (PVar "rtD") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (DoLet false false (PVar "coreD") (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (DoLet false false (PVar "modsD") (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false PWild (EApp (EApp (EVar "takeShippedPrelude") (EApp (EVar "deferredInto") (EVar "jsonMode"))) (EVar "prelude"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PTuple (PVar "flatStdlib") (PVar "ownedStdlib")) (EApp (EApp (EApp (EApp (EVar "stdlibOwnership") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PVar "inputs") (ERecordUpdate (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "flatStdlib")) (EVar "ownedStdlib")) ((fa "diPreludeKey" (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EVar "rsrc")) (EVar "csrc"))))))) (DoLet false false (PVar "perfTLoad") (EApp (EVar "now") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "load"))) (EBinOp "-" (EVar "perfTLoad") (EVar "perfT0"))) (EVar "target"))) (DoLet false false (PTuple (PVar "program") (PVar "frontTrusted")) (EMatch (EVar "modsWithPath") (arm (PList (PVar "m")) () (ETuple (EApp (EVar "FrontFile") (EVar "m")) (EListLit))) (arm PWild () (ETuple (EApp (EApp (EVar "FrontGraph") (EVar "modsWithPath")) (EVar "modsD")) (EVar "trusted"))))) (DoLet false false (PVar "executionDriver") (ERecordCreate "EntryKey" ((fa "moduleId" (ELit (LString "async"))) (fa "binding" (ELit (LString "runAsyncMain")))))) (DoLet false false (PVar "front") (EApp (EApp (EApp (EVar "frontEnd") (EVar "cliStdlibExportsEnv")) (ELam ((PVar "d")) (EApp (EApp (EApp (EApp (EApp (EVar "elaborateRun") (EFieldAccess (EVar "d") "fdInputs")) (EVar "executionDriver")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD")))) (ERecordCreate "FrontInput" ((fa "fiInputs" (EVar "inputs")) (fa "fiAllowInternal" (EVar "allowInternal")) (fa "fiTrusted" (EVar "frontTrusted")) (fa "fiRuntimeSrc" (EVar "rsrc")) (fa "fiCoreSrc" (EVar "csrc")) (fa "fiPolicy" (EVar "NeverDriveRejected")) (fa "fiProgram" (EVar "program")))))) (DoLet false false (PVar "report") (EFieldAccess (EVar "front") "foReport")) (DoExpr (EMatch (EVar "mods") (arm (PList PWild) () (EBlock (DoLet false false (PVar "tsrc") (EIf (EVar "isStdin") (EVar "stdinText") (EApp (EVar "readFileSafe") (EVar "target")))) (DoLet false false (PVar "diags") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EFieldAccess (EVar "front") "foDiags"))) (DoExpr (EMatch (ETuple (EApp (EApp (EMethodRef "filter") (EVar "diagIsError")) (EVar "diags")) (EFieldAccess (EVar "front") "foDriven")) (arm (PTuple (PList) (PCon "Some" (PVar "analysis"))) () (EBlock (DoLet false false (PVar "residual") (EFieldAccess (EFieldAccess (EVar "analysis") "eaElab") "erResidual")) (DoExpr (EMatch (EApp (EVar "isNone") (EFieldAccess (EVar "report") "trChecked")) (arm (PCon "True") () (EMatch (EVar "jsonMode") (arm (PCon "True") () (EApp (EVar "runAbortJson") (EApp (EApp (EApp (EVar "residualJsonTriples") (EVar "target")) (EVar "pathMap")) (EVar "residual")))) (arm (PCon "False") () (EApp (EVar "runAbort") (EApp (EApp (EApp (EVar "residualOrGeneric") (EVar "pathMap")) (EVar "target")) (EVar "residual")))))) (arm (PCon "False") () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTargetGate") (EVar "jsonMode")) (ELam ((PVar "t")) (EVar "t"))) (EVar "target")) (EVar "pathMap")) (EVar "mods")) (EVar "analysis"))) (DoLet false false (PVar "perfTCheck") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "allocCheck") (EApp (EVar "allocSnap") (ELit LUnit))) (DoLet false false (PVar "opCheck") (EApp (EVar "opSnap") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "check"))) (EBinOp "-" (EVar "perfTCheck") (EVar "perfTLoad"))) (EVar "target"))) (DoLet false false (PVar "executed") (EApp (EApp (EApp (EVar "executedFromReport") (EVar "report")) (EVar "executionDriver")) (ETuple (EVar "coreD") (EVar "modsD")))) (DoExpr (EMatch (EVar "executed") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "runAbort") (EVar "msg"))) (arm (PCon "Ok" (PVar "trees")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EApp (EVar "checkedFacts") (EVar "report"))) (EVar "trees")) (EVar "mods")) (EApp (EApp (EApp (EVar "allWarnTriples") (EVar "tsrc")) (EVar "target")) (EVar "diags"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalPerf") (EVar "perfOn")) (EVar "target")) (EVar "perfT0")) (EVar "perfTCheck")) (EVar "allocCheck")) (EVar "opCheck")))))))))))) (arm (PTuple (PVar "errs") PWild) () (EMatch (EVar "jsonMode") (arm (PCon "True") () (EApp (EVar "runAbortJson") (EListLit (ETuple (EVar "target") (EVar "tsrc") (EVar "diags"))))) (arm (PCon "False") () (EApp (EVar "runAbort") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliLines") (EApp (EVar "srcLinesArr") (EVar "tsrc"))) (EVar "target"))) (EVar "errs"))))))))))) (arm PWild () (EMatch (EFieldAccess (EVar "front") "foDriven") (arm (PCon "None") () (EMatch (EVar "jsonMode") (arm (PCon "True") () (EApp (EVar "runAbortJson") (EApp (EApp (EMethodRef "map") (EApp (EVar "relDiagTriple") (EVar "root"))) (EApp (EVar "resolveErrorJsonTriples") (EFieldAccess (EVar "front") "foDiags"))))) (arm (PCon "False") () (EApp (EVar "runAbort") (EApp (EVar "ppDiagBuckets") (EFieldAccess (EVar "front") "foDiags")))))) (arm (PCon "Some" (PVar "analysis")) () (EBlock (DoLet false false (PVar "residual") (EFieldAccess (EFieldAccess (EVar "analysis") "eaElab") "erResidual")) (DoExpr (EMatch (EApp (EVar "locatedProjectDiags") (EFieldAccess (EVar "front") "foDiags")) (arm (PTuple (PCon "Some" (PVar "errText")) PWild PWild) () (EMatch (EVar "jsonMode") (arm (PCon "True") () (EBlock (DoLet false false (PVar "jsonTriples") (EApp (EApp (EMethodRef "map") (EApp (EVar "relDiagTriple") (EVar "root"))) (EApp (EVar "nonEmptyTriples") (EApp (EApp (EMethodRef "map") (EVar "readDiagSrc")) (EFieldAccess (EVar "front") "foDiags"))))) (DoExpr (EApp (EVar "runAbortJson") (EVar "jsonTriples"))))) (arm (PCon "False") () (EApp (EVar "runAbort") (EVar "errText"))))) (arm (PTuple (PCon "None") (PVar "projWarns") PWild) () (EMatch (EApp (EVar "isNone") (EFieldAccess (EVar "report") "trChecked")) (arm (PCon "True") () (EMatch (EVar "jsonMode") (arm (PCon "True") () (EApp (EVar "runAbortJson") (EApp (EApp (EMethodRef "map") (EApp (EVar "relDiagTriple") (EVar "root"))) (EApp (EApp (EApp (EVar "residualJsonTriples") (EVar "target")) (EVar "pathMap")) (EVar "residual"))))) (arm (PCon "False") () (EApp (EVar "runAbort") (EApp (EApp (EApp (EVar "residualOrGeneric") (EVar "pathMap")) (EVar "target")) (EVar "residual")))))) (arm (PCon "False") () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTargetGate") (EVar "jsonMode")) (EApp (EVar "relDiagTriple") (EVar "root"))) (EVar "target")) (EVar "pathMap")) (EVar "mods")) (EVar "analysis"))) (DoLet false false (PVar "perfTCheck") (EApp (EVar "now") (ELit LUnit))) (DoLet false false (PVar "allocCheck") (EApp (EVar "allocSnap") (ELit LUnit))) (DoLet false false (PVar "opCheck") (EApp (EVar "opSnap") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "emitPhase") (EVar "perfOn")) (ELit (LString "check"))) (EBinOp "-" (EVar "perfTCheck") (EVar "perfTLoad"))) (EVar "target"))) (DoLet false false (PVar "executed") (EApp (EApp (EApp (EVar "executedFromReport") (EVar "report")) (EVar "executionDriver")) (ETuple (EVar "coreD") (EVar "modsD")))) (DoExpr (EMatch (EVar "executed") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "runAbort") (EVar "msg"))) (arm (PCon "Ok" (PVar "trees")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EApp (EVar "checkedFacts") (EVar "report"))) (EVar "trees")) (EVar "mods")) (EVar "projWarns")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runEvalPerf") (EVar "perfOn")) (EVar "target")) (EVar "perfT0")) (EVar "perfTCheck")) (EVar "allocCheck")) (EVar "opCheck"))))))))))))))))))))))))
(DTypeSig false "desugarPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarPair" ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EApp (EVar "desugarIn") (EVar "mid")) (EVar "p"))))
(DTypeSig false "elaborateRun" (TyFun (TyCon "DriveInputs") (TyFun (TyCon "EntryKey") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyTuple (TyCon "EntryAnalysis") (TyCon "TcReport") (TyCon "DriveOutputs")))))))))
(DFunDef false "elaborateRun" ((PVar "inputs") (PVar "executionDriver") (PVar "rtD") (PVar "coreD") (PVar "modsD")) (EBlock (DoLet false false (PTuple (PVar "analysis") (PVar "report") (PVar "outputs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProgramReport") (EApp (EApp (EApp (EVar "executedMainInputs") (EVar "inputs")) (EVar "executionDriver")) (EVar "modsD"))) (EApp (EApp (EVar "valueMainCandidate") (EVar "coreD")) (EVar "modsD"))) (EApp (EVar "Some") (EFieldAccess (EVar "executionDriver") "binding"))) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoLet false false PWild (EMatch (EApp (EApp (EVar "asyncMainShapeError") (EFieldAccess (EVar "outputs") "doEntryOutcome")) (EVar "modsD")) (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "runAbort") (EVar "msg"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (ETuple (EVar "analysis") (EVar "report") (EVar "outputs")))))
(DTypeSig false "runProgramOutput" (TyFun (TyCon "ProgramFacts") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "String"))))))
(DFunDef false "runProgramOutput" ((PVar "facts") (PVar "preludeDecls") (PVar "modules")) (EApp (EApp (EApp (EVar "evalModulesOutputRunFacts") (EVar "facts")) (EVar "preludeDecls")) (EVar "modules")))
(DTypeSig false "checkedFacts" (TyFun (TyCon "TcReport") (TyCon "ProgramFacts")))
(DFunDef false "checkedFacts" ((PVar "report")) (EMatch (EFieldAccess (EVar "report") "trChecked") (arm (PCon "Some" (PVar "checked")) () (EApp (EVar "factsOfChecked") (EVar "checked"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "internal error: the typecheck published no checked program to run"))))))
(DTypeSig false "runTestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runTestCmd" ((PVar "argv0")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "testArgSpec")) (EVar "argv0"))) (DoExpr (EIf (EApp (EApp (EVar "flag") (ELit (LString "--props-worker"))) (EVar "a")) (EApp (EVar "runPropsWorkerCmd") (EVar "a")) (EMatch (EApp (EVar "parseTestEngines") (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "engines")) () (EMatch (EApp (EVar "parseTestCasesFlag") (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "casesOpt")) () (EMatch (EApp (EApp (EVar "parseTestIntFlag") (ELit (LString "--seed"))) (EVar "a")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "seedOpt")) () (EBlock (DoLet false false PWild (EMatch (EVar "seedOpt") (arm (PCon "Some" (PVar "s")) () (EApp (EVar "seedPropRng") (EVar "s"))) (arm (PCon "None") () (ELit LUnit)))) (DoLet false false (PVar "cases") (EApp (EApp (EVar "optionOr") (ELit (LInt 100))) (EVar "casesOpt"))) (DoLet false false (PVar "filterOpt") (EApp (EApp (EVar "flagValue") (ELit (LString "--filter"))) (EVar "a"))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a"))) (DoExpr (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList) () (EIf (EVar "jsonMode") (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka test --json: needs a single file.mdk target; with no target, medaka test runs the whole enclosing project")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EVar "runTestProjectCmd") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")))) (arm (PList (PVar "target")) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EVar "runTestJsonCmd") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "target")) (EApp (EApp (EApp (EApp (EVar "runTestOne") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "target")))) (arm (PCon "Ok" PWild) () (EIf (EVar "jsonMode") (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka test --json: directory targets are not supported; pass a single file.mdk target")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EApp (EVar "runTestManyTargets") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")) (EListLit (EVar "target"))))))) (arm (PVar "targets") () (EIf (EVar "jsonMode") (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka test --json: exactly one file.mdk target is supported")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EApp (EVar "runTestManyTargets") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")) (EVar "targets")))))))))))))))))
(DTypeSig false "runPropsWorkerCmd" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runPropsWorkerCmd" ((PVar "a")) (EMatch (EApp (EVar "parsePropsWorkerPositionals") (EFieldAccess (EVar "a") "positionals")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test --props-worker: ")) (EApp (EMethodRef "display") (EVar "message"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "target") (PVar "requests"))) () (EApp (EApp (EVar "runEvalPropsWorker") (EVar "target")) (EVar "requests")))))
(DTypeSig false "parsePropsWorkerPositionals" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "PropRequest"))))))
(DFunDef false "parsePropsWorkerPositionals" ((PList)) (EApp (EVar "Err") (ELit (LString "expected a target and zero or more property request triples"))))
(DFunDef false "parsePropsWorkerPositionals" ((PCons (PVar "target") (PVar "fields"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "requests")) (ETuple (EVar "target") (EVar "requests")))) (EApp (EVar "parsePropsWorkerRequests") (EVar "fields"))))
(DTypeSig false "parsePropsWorkerRequests" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "PropRequest")))))
(DFunDef false "parsePropsWorkerRequests" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "parsePropsWorkerRequests" ((PCons (PVar "nameText") (PCons (PVar "seedText") (PCons (PVar "casesText") (PVar "rest"))))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "parseWorkerField") (ELit (LString "name"))) (EVar "nameText"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "parseWorkerInt") (ELit (LString "seed"))) (EVar "seedText"))) (ELam ((PVar "seed")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "parseWorkerInt") (ELit (LString "cases"))) (EVar "casesText"))) (ELam ((PVar "cases")) (EIf (EBinOp "<=" (EVar "cases") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "property request ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "name")))) (ELit (LString " has a non-positive case budget")))) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "parsePropsWorkerRequests") (EVar "rest"))) (ELam ((PVar "requests")) (EApp (EVar "Ok") (EBinOp "::" (EApp (EApp (EApp (EVar "PropRequest") (EVar "name")) (EVar "seed")) (EVar "cases")) (EVar "requests")))))))))))))
(DFunDef false "parsePropsWorkerRequests" (PWild) (EApp (EVar "Err") (ELit (LString "property requests must be name, seed, cases triples"))))
(DTypeSig false "parseWorkerInt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "parseWorkerInt" ((PVar "role") (PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "parseWorkerField") (EVar "role")) (EVar "text"))) (ELam ((PVar "field")) (EMatch (EApp (EVar "toInt") (EVar "field")) (arm (PCon "Some" (PVar "value")) () (EApp (EVar "Ok") (EVar "value"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "property request ")) (EApp (EMethodRef "display") (EVar "role"))) (ELit (LString " is not an integer: "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "field")))) (ELit (LString "")))))))))
(DTypeSig false "parseWorkerField" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "parseWorkerField" ((PVar "role") (PVar "text")) (EMatch (EApp (EVar "parseJson") (EVar "text")) (arm (PCon "Ok" (PVar "json")) () (EMatch (EApp (EVar "asString") (EVar "json")) (arm (PCon "Some" (PVar "field")) () (EApp (EVar "Ok") (EVar "field"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "property request ")) (EApp (EMethodRef "display") (EVar "role"))) (ELit (LString " is not a JSON string"))))))) (arm (PCon "Err" PWild) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "property request ")) (EApp (EMethodRef "display") (EVar "role"))) (ELit (LString " is not a JSON string")))))))
(DTypeSig false "runTestProjectCmd" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "runTestProjectCmd" ((PVar "engines") (PVar "cases") (PVar "filterOpt") (PVar "seedOpt")) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoExpr (EMatch (EApp (EVar "findProjectRoot") (EVar "cwd")) (arm (PCon "None") () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: no target given and no medaka.toml in ")) (EApp (EMethodRef "display") (EVar "cwd"))) (ELit (LString " or any directory above it; pass a file.mdk or directory target, or run inside a project"))))) (arm (PCon "Some" (PVar "root")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: no target given; testing the project at ")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "runTestManyTargets") (EVar "engines")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")) (EListLit (EVar "root"))))))))))
(DTypeSig false "runTestJsonCmd" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "runTestJsonCmd" ((PVar "engines") (PVar "cases") (PVar "filterOpt") (PVar "target")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "r") (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readPreludeSources") (EVar "stdlibDir"))) (ELam ((PVar "prelude")) (ELet false PWild (EApp (EVar "seedCheckPrelude") (EVar "prelude")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readSource") (EVar "target"))) (ELam ((PVar "tsrc")) (ELet false (PVar "userDecls") (EApp (EVar "targetDesugared") (EVar "tsrc")) (EIf (EApp (EApp (EApp (EVar "filterMatchedNothing") (EVar "filterOpt")) (EVar "tsrc")) (EVar "userDecls")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka test: ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": --filter matched no doctests, props, or `test \"…\"` decls")))) (EBlock (DoLet false false (PTuple (PVar "typeError") (PVar "runs") (PVar "props") (PVar "tests") (PVar "typecheckSkipped")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestGradedReport") (EVar "engines")) (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (EFieldAccess (EVar "prelude") "pnCoreSrc")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "stdlibDir")) (EVar "cases")) (EVar "filterOpt")) (EVar "True"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "stringify") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cliGradedTestReportJson") (EVar "target")) (EVar "typeError")) (EVar "engines")) (EVar "runs")) (EVar "props")) (EVar "tests")) (EVar "typecheckSkipped"))))) (DoExpr (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EVar "cliGradedTestReportOk") (EVar "typeError")) (EVar "runs")) (EVar "props")) (EVar "tests"))))))))))))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" (PVar "e")) () (EApp (EVar "dieMsg") (EVar "e"))) (arm (PCon "Ok" (PVar "ok")) () (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "stageExit") (ELit (LInt 1)))))))))
(DTypeSig false "runTestManyTargets" (TyFun (TyApp (TyCon "List") (TyCon "Engine")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "runTestManyTargets" ((PVar "engines") (PVar "cases") (PVar "filterOpt") (PVar "seedOpt") (PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EApp (EVar "dieMsg") (ELit (LString "medaka test: no .mdk files found")))) (arm PWild () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "rosterOk") (EApp (EApp (EApp (EVar "checkTestMdkRoster") (EVar "root")) (EVar "targets")) (EVar "files"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "reportSupervisedTrees") (EVar "stdlibDir")) (EVar "rtPath")) (EVar "corePath"))) (DoLet false false (PVar "anyFailed") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "engines")) (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "cases")) (EVar "filterOpt")) (EVar "seedOpt")) (EVar "files")) (EVar "False"))) (DoExpr (EIf (EBinOp "||" (EVar "anyFailed") (EApp (EVar "not") (EVar "rosterOk"))) (EApp (EVar "stageExit") (ELit (LInt 1))) (ELit LUnit)))))))))
(DTypeSig false "reportSupervisedTrees" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "reportSupervisedTrees" ((PVar "stdlibDir") (PVar "rtPath") (PVar "corePath")) (EMatch (ETuple (EApp (EVar "readFile") (EVar "rtPath")) (EApp (EVar "readFile") (EVar "corePath"))) (arm (PTuple (PCon "Ok" (PVar "rsrc")) (PCon "Ok" (PVar "csrc"))) () (EApp (EVar "reportChildTrees") (EApp (EApp (EApp (EVar "shippedInputs") (EVar "stdlibDir")) (EVar "rsrc")) (EVar "csrc")))) (arm PWild () (ELit LUnit))))
(DTypeSig false "docHelpText" (TyCon "String"))
(DFunDef false "docHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka doc — Generate Markdown documentation for a file or module library\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka doc <file.mdk>\n")) (ELit (LString "  medaka doc --out DIR <file.mdk> [<file.mdk> ...]\n")) (ELit (LString "\n")) (ELit (LString "Single-file mode prints Markdown for every PUBLIC declaration (with\n")) (ELit (LString "inferred type schemes) in <file.mdk> to stdout.\n")) (ELit (LString "\n")) (ELit (LString "Library mode (--out DIR) writes one Markdown page per module, an\n")) (ELit (LString "index.md linking them, and an inventory.json (name -> module ->\n")) (ELit (LString "signature) into DIR.\n")) (ELit (LString "\n")) (ELit (LString "  --out DIR   output directory; enables library mode\n")))))
(DTypeSig false "docArgSpec" (TyCon "ArgSpec"))
(DFunDef false "docArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "doc"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--out")))) (ELit (LString "DIR"))) (ELit (LString "output directory; enables library mode")))))))
(DTypeSig false "runDocCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runDocCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "docArgSpec")) (EVar "argv"))) (DoExpr (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--out"))) (EVar "a")) (arm (PCon "Some" (PVar "dir")) () (EApp (EApp (EVar "runDocLibraryTargets") (EVar "dir")) (EFieldAccess (EVar "a") "positionals"))) (arm (PCon "None") () (EApp (EVar "runDocTargets") (EFieldAccess (EVar "a") "positionals")))))))
(DTypeSig false "runDocTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runDocTargets" ((PList)) (EApp (EVar "dieMsg") (ELit (LString "usage: medaka doc <file.mdk>"))))
(DFunDef false "runDocTargets" ((PCons PWild (PCons PWild PWild))) (EApp (EVar "dieMsg") (ELit (LString "usage: medaka doc <file.mdk> (doc takes exactly one file)"))))
(DFunDef false "runDocTargets" ((PCons (PVar "target") PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EVar "carryTargetProfile") (EVar "None")) (EVar "target"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "r") (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readPreludeSources") (EVar "stdlibDir"))) (ELam ((PVar "prelude")) (ELet false PWild (EApp (EVar "seedCheckPrelude") (EVar "prelude")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readSource") (EVar "target"))) (ELam ((PVar "tsrc")) (ELet false PWild (EApp (EVar "orExit") (EApp (EApp (EVar "mapErr") (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target"))) (EApp (EVar "parseResult") (EVar "tsrc")))) (EApp (EVar "Ok") (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EApp (EVar "runDoc") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (EFieldAccess (EVar "prelude") "pnCoreSrc")) (EVar "tsrc")) (EVar "target")) (EVar "roots"))))))))))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "v")) () (EVar "v"))))))
(DTypeSig false "runDocLibraryTargets" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "runDocLibraryTargets" (PWild (PList)) (EApp (EVar "dieMsg") (ELit (LString "usage: medaka doc --out DIR <file.mdk> [<file.mdk> ...]"))))
(DFunDef false "runDocLibraryTargets" ((PVar "outDir") (PVar "targets")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "carryTargetProfile") (EVar "None")) (EApp (EApp (EVar "optionOr") (ELit (LString "."))) (EApp (EVar "head") (EVar "targets"))))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "r") (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readPreludeSources") (EVar "stdlibDir"))) (ELam ((PVar "prelude")) (ELet false PWild (EApp (EVar "seedCheckPrelude") (EVar "prelude")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "ensureOutDir") (EVar "outDir"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "collectModuleDocs") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (EFieldAccess (EVar "prelude") "pnCoreSrc")) (EVar "stdlibDir")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "t")) (EApp (EVar "not") (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "t"))))) (EVar "targets")))) (ELam ((PVar "mds")) (EApp (EVar "Ok") (EApp (EApp (EVar "writeLibraryOutputs") (EVar "outDir")) (EApp (EVar "rebucketLibraryImpls") (EApp (EApp (EVar "sortOn") (EVar "mdName")) (EVar "mds"))))))))))))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "v")) () (EVar "v"))))))
(DTypeSig false "ensureOutDir" (TyFun (TyCon "String") (TyEffect ("FileWrite") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "ensureOutDir" ((PVar "dir")) (EMatch (EApp (EVar "makeDir") (EVar "dir")) (arm (PCon "Ok" PWild) () (EApp (EVar "Ok") (ELit LUnit))) (arm (PCon "Err" (PVar "e")) () (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "stringIndexOf") (ELit (LString "exists"))) (EVar "e"))) (EApp (EVar "Ok") (ELit LUnit)) (EApp (EVar "Err") (EVar "e"))))))
(DTypeSig false "collectModuleDocs" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ModuleDoc")))))))))
(DFunDef false "collectModuleDocs" (PWild PWild PWild (PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "collectModuleDocs" ((PVar "rsrc") (PVar "csrc") (PVar "stdlibDir") (PCons (PVar "target") (PVar "rest"))) (EMatch (EApp (EVar "readSource") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EApp (EVar "docParseError") (EVar "target")) (EVar "tsrc")) (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "md") (EApp (EApp (EApp (EApp (EApp (EVar "computeModuleDoc") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "roots"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "md") (EVar "_s")))) (EApp (EApp (EApp (EApp (EVar "collectModuleDocs") (EVar "rsrc")) (EVar "csrc")) (EVar "stdlibDir")) (EVar "rest"))))))))))
(DTypeSig false "checkDistinctModuleNames" (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "checkDistinctModuleNames" ((PVar "mds")) (EApp (EApp (EVar "checkDistinctGo") (EVar "mds")) (EListLit)))
(DTypeSig false "checkDistinctGo" (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "checkDistinctGo" ((PList) PWild) (ELit LUnit))
(DFunDef false "checkDistinctGo" ((PCons (PVar "md") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "mdName") (EVar "md"))) (DoExpr (EIf (EApp (EApp (EVar "elemStrCli") (EVar "n")) (EVar "seen")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka doc --out: two targets share the module name `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` and would write the same page `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ".md`; rename one"))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))) (EApp (EApp (EVar "checkDistinctGo") (EVar "rest")) (EBinOp "::" (EVar "n") (EVar "seen")))))))
(DTypeSig false "elemStrCli" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "elemStrCli" (PWild (PList)) (EVar "False"))
(DFunDef false "elemStrCli" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "elemStrCli") (EVar "x")) (EVar "ys"))))
(DTypeSig false "writeLibraryOutputs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "writeLibraryOutputs" ((PVar "outDir") (PVar "mds")) (EBlock (DoLet false false PWild (EApp (EVar "checkDistinctModuleNames") (EVar "mds"))) (DoLet false false PWild (EApp (EApp (EVar "writeLibraryPages") (EVar "outDir")) (EVar "mds"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "writeLibraryFile") (EVar "outDir")) (ELit (LString "index.md"))) (EApp (EVar "renderIndex") (EVar "mds")))) (DoExpr (EApp (EApp (EApp (EVar "writeLibraryFile") (EVar "outDir")) (ELit (LString "inventory.json"))) (EApp (EVar "stringify") (EApp (EVar "libraryInventoryJson") (EVar "mds")))))))
(DTypeSig false "writeLibraryPages" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ModuleDoc")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "writeLibraryPages" (PWild (PList)) (ELit LUnit))
(DFunDef false "writeLibraryPages" ((PVar "outDir") (PCons (PVar "md") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "writeLibraryFile") (EVar "outDir")) (EBinOp "++" (EApp (EVar "mdName") (EVar "md")) (ELit (LString ".md")))) (EApp (EVar "renderModulePage") (EVar "md")))) (DoExpr (EApp (EApp (EVar "writeLibraryPages") (EVar "outDir")) (EVar "rest")))))
(DTypeSig false "writeLibraryFile" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "writeLibraryFile" ((PVar "outDir") (PVar "name") (PVar "contents")) (EMatch (EApp (EApp (EVar "writeFile") (EApp (EApp (EVar "joinPath") (EVar "outDir")) (EVar "name"))) (EVar "contents")) (arm (PCon "Ok" PWild) () (ELit LUnit)) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg")))))
(DTypeSig false "checkPolicyHelpText" (TyCon "String"))
(DFunDef false "checkPolicyHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka check-policy — Check a plugin's inferred effects against an allow-list\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]\n")) (ELit (LString "\n")) (ELit (LString "  --allow L1,L2,...  effect labels the plugin is permitted to use\n")) (ELit (LString "                     (default: Cache,Log)\n")) (ELit (LString "  --fn name          the function whose inferred effect row is checked\n")) (ELit (LString "                     (default: transform)\n")) (ELit (LString "\n")) (ELit (LString "Prints an accept/reject header; on accept, also runs the plugin on a\n")) (ELit (LString "sample request. Exit 0 on accept, 1 on reject.\n")))))
(DTypeSig false "policyArgSpec" (TyCon "ArgSpec"))
(DFunDef false "policyArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "check-policy"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--allow")))) (ELit (LString "L1,L2,..."))) (ELit (LString "effect labels the plugin may use"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--fn")))) (ELit (LString "NAME"))) (ELit (LString "the function whose effect row is checked")))))))
(DTypeSig false "runCheckPolicyCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckPolicyCmd" ((PVar "argv0")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "policyArgSpec")) (EVar "argv0"))) (DoExpr (EApp (EVar "runCheckPolicyArgs") (EApp (EApp (EApp (EVar "PolicyArgs") (EApp (EVar "firstPositional") (EVar "a"))) (EApp (EApp (EVar "optDefault") (EApp (EApp (EVar "lastValue") (ELit (LString "--allow"))) (EVar "a"))) (ELit (LString "Cache,Log")))) (EApp (EApp (EVar "optDefault") (EApp (EApp (EVar "lastValue") (ELit (LString "--fn"))) (EVar "a"))) (ELit (LString "transform"))))))))
(DTypeSig false "firstPositional" (TyFun (TyCon "Args") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "firstPositional" ((PVar "a")) (EMatch (EFieldAccess (EVar "a") "positionals") (arm (PList) () (EVar "None")) (arm (PCons (PVar "f") PWild) () (EApp (EVar "Some") (EVar "f")))))
(DTypeSig false "optDefault" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "optDefault" ((PCon "Some" (PVar "v")) PWild) (EVar "v"))
(DFunDef false "optDefault" ((PCon "None") (PVar "d")) (EVar "d"))
(DTypeSig false "runCheckPolicyArgs" (TyFun (TyCon "PolicyArgs") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckPolicyArgs" ((PCon "PolicyArgs" (PCon "None") PWild PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))))
(DFunDef false "runCheckPolicyArgs" ((PCon "PolicyArgs" (PCon "Some" (PVar "target")) (PVar "allow") (PVar "fn"))) (EMatch (EApp (EApp (EVar "analyzeTarget") (EVar "target")) (EVar "fn")) (arm (PCon "Err" (PVar "diags")) ((GBool (EBinOp "==" (EVar "diags") (EBinOp "++" (EBinOp "++" (ELit (LString "no '")) (EApp (EMethodRef "display") (EVar "fn"))) (ELit (LString "' entry found")))))) (EApp (EVar "dieMsg") (EBinOp "++" (ELit (LString "rejected. ")) (EVar "diags")))) (arm (PCon "Err" (PVar "diags")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. compiler analysis failed before policy evaluation; `medaka check ")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString "` reports:"))))) (DoExpr (EApp (EVar "dieMsg") (EVar "diags"))))) (arm (PCon "Ok" (PVar "analysis")) () (EMatch (EApp (EApp (EApp (EVar "runCheckPolicy") (EVar "analysis")) (EVar "allow")) (EVar "fn")) (arm (PCon "PolicyReject" (PVar "report")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStr") (EVar "report"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "PolicyAccept" (PVar "header") (PVar "sample")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "header"))) (DoExpr (EApp (EVar "putStr") (EApp (EVar "sample") (ELit LUnit))))))))))
(DTypeSig false "analyzeTarget" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EntryAnalysis"))))))
(DFunDef false "analyzeTarget" ((PVar "target") (PVar "fn")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "carryTargetProfile") (EVar "None")) (EVar "target"))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "prelude") (EApp (EVar "orExit") (EApp (EVar "readPreludeSources") (EVar "stdlibDir")))) (DoLet false false (PVar "tsrc") (EApp (EVar "orExit") (EApp (EVar "readSource") (EVar "target")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeLoaded") (EVar "prelude")) (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "fn")) (EVar "modsWithPath")))))))
(DTypeSig false "analyzeLoaded" (TyFun (TyCon "PreludeInputs") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EntryAnalysis"))))))))))
(DFunDef false "analyzeLoaded" ((PVar "prelude") (PVar "target") (PVar "roots") (PVar "stdlibDir") (PVar "fn") (PVar "modsWithPath")) (EBlock (DoLet false false (PVar "rsrc") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (DoLet false false (PVar "csrc") (EFieldAccess (EVar "prelude") "pnCoreSrc")) (DoLet false false (PVar "mods") (EApp (EApp (EMethodRef "map") (EVar "dropPathTriple")) (EVar "modsWithPath"))) (DoLet false false (PVar "pathMap") (EApp (EApp (EMethodRef "map") (EVar "modIdToPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PVar "rtD") (EApp (EVar "desugaredPrelude") (EVar "rsrc"))) (DoLet false false (PVar "coreD") (EApp (EVar "desugaredPrelude") (EVar "csrc"))) (DoLet false false (PVar "modsD") (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false PWild (EApp (EApp (EVar "takeShippedPrelude") (EVar "unstaged")) (EVar "prelude"))) (DoLet false false (PVar "front") (EApp (EApp (EApp (EVar "frontEnd") (EApp (EVar "stdlibExportsReader") (EVar "stdlibDir"))) (ELam ((PVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProgramReport") (EFieldAccess (EVar "d") "fdInputs")) (EApp (EApp (EVar "valueMainCandidate") (EVar "coreD")) (EVar "modsD"))) (EVar "None")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD")))) (ERecordCreate "FrontInput" ((fa "fiInputs" (ERecordUpdate (EApp (EApp (EApp (EVar "driveInputsFor") (EUnOp "!" (EVar "selectedProfile"))) (EVar "False")) (EListLit)) ((fa "diManifestRequests" (EListLit (EApp (EApp (EVar "EntryOverPrelude") (EVar "fn")) (EVar "HostInvocation")))) (fa "diPreludeKey" (EApp (EVar "Some") (EApp (EApp (EVar "preludeGeneration") (EVar "rsrc")) (EVar "csrc"))))))) (fa "fiAllowInternal" (EVar "False")) (fa "fiTrusted" (EVar "trusted")) (fa "fiRuntimeSrc" (EVar "rsrc")) (fa "fiCoreSrc" (EVar "csrc")) (fa "fiPolicy" (EVar "NeverDriveRejected")) (fa "fiProgram" (EApp (EApp (EVar "FrontGraph") (EVar "modsWithPath")) (EVar "modsD"))))))) (DoExpr (EMatch (EFieldAccess (EVar "front") "foDriven") (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "ppDiagBuckets") (EFieldAccess (EVar "front") "foDiags")))) (arm (PCon "Some" (PVar "analysis")) () (EBlock (DoLet false false (PVar "residual") (EFieldAccess (EFieldAccess (EVar "analysis") "eaElab") "erResidual")) (DoExpr (EMatch (EApp (EVar "locatedProjectDiags") (EFieldAccess (EVar "front") "foDiags")) (arm (PTuple (PCon "Some" (PVar "errText")) PWild PWild) () (EApp (EVar "Err") (EVar "errText"))) (arm (PTuple (PCon "None") PWild PWild) () (EIf (EApp (EVar "isNone") (EFieldAccess (EFieldAccess (EVar "front") "foReport") "trChecked")) (EMatch (EFieldAccess (EFieldAccess (EVar "front") "foReport") "trResidual") (arm (PAs "missing" (PCons PWild PWild)) ((GBool (EApp (EApp (EDictApp "all") (ELam ((PVar "p")) (EBinOp "==" (EApp (EVar "tcCode") (EApp (EVar "snd") (EVar "p"))) (EVar "TManifestEntry")))) (EVar "missing")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "no '")) (EApp (EMethodRef "display") (EVar "fn"))) (ELit (LString "' entry found"))))) (arm PWild () (EApp (EVar "Err") (EApp (EApp (EApp (EVar "residualOrGeneric") (EVar "pathMap")) (EVar "target")) (EVar "residual"))))) (EApp (EVar "Ok") (EVar "analysis"))))))))))))
(DTypeSig false "manifestHelpText" (TyCon "String"))
(DFunDef false "manifestHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka manifest — Emit a module's verified capability manifest as TOML\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka manifest <file.mdk> [--fn name]\n")) (ELit (LString "\n")) (ELit (LString "  --fn name  the function whose inferred effect row is emitted\n")) (ELit (LString "             (default: main)\n")) (ELit (LString "\n")) (ELit (LString "Prints a [package.capabilities] TOML block: one entry per effect label\n")) (ELit (LString "in the function's inferred effect row (a prefix-param becomes a string\n")) (ELit (LString "value; a Unit/top param becomes `true`).\n")))))
(DTypeSig false "manifestArgSpec" (TyCon "ArgSpec"))
(DFunDef false "manifestArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "manifest"))) (EListLit (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--fn")))) (ELit (LString "NAME"))) (ELit (LString "the function whose effect row is emitted")))))))
(DTypeSig false "runManifestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runManifestCmd" ((PVar "argv0")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "manifestArgSpec")) (EVar "argv0"))) (DoExpr (EApp (EVar "runManifestArgs") (EApp (EApp (EVar "ManifestArgs") (EApp (EVar "firstPositional") (EVar "a"))) (EApp (EApp (EVar "optDefault") (EApp (EApp (EVar "lastValue") (ELit (LString "--fn"))) (EVar "a"))) (ELit (LString "main"))))))))
(DTypeSig false "runManifestArgs" (TyFun (TyCon "ManifestArgs") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runManifestArgs" ((PCon "ManifestArgs" (PCon "None") PWild)) (EApp (EVar "dieMsg") (ELit (LString "usage: medaka manifest <file.mdk> [--fn name]"))))
(DFunDef false "runManifestArgs" ((PCon "ManifestArgs" (PCon "Some" (PVar "target")) (PVar "fn"))) (EMatch (EApp (EApp (EVar "analyzeTarget") (EVar "target")) (EVar "fn")) (arm (PCon "Err" (PVar "diags")) () (EApp (EVar "dieMsg") (EVar "diags"))) (arm (PCon "Ok" (PVar "analysis")) () (EMatch (EApp (EApp (EVar "runManifest") (EVar "analysis")) (EVar "fn")) (arm (PCon "Ok" (PVar "toml")) () (EApp (EVar "putStr") (EVar "toml"))) (arm (PCon "Err" (PVar "refusal")) () (EApp (EVar "dieMsg") (EVar "refusal")))))))
(DTypeSig false "lintArgSpec" (TyCon "ArgSpec"))
(DFunDef false "lintArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "lint"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--fix")))) (ELit (LString "rewrite fixable findings in place"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--unsafe-fixes")))) (ELit (LString "with --fix: also apply fixes that may change behaviour"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--json")))) (ELit (LString "emit the structured-diagnostics envelope"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--cache")))) (ELit (LString "reuse per-file results for unchanged files"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--disable")))) (ELit (LString "r1,r2,..."))) (ELit (LString "suppress findings from the named rules"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--only")))) (ELit (LString "r1,..."))) (ELit (LString "keep only findings from the named rules"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--deny")))) (ELit (LString "r1,..."))) (ELit (LString "promote findings from the named rules to error"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--baseline")))) (ELit (LString "<file>"))) (ELit (LString "error only where a file's per-rule count exceeds its row in <file>"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--write-baseline")))) (ELit (LString "<file>"))) (ELit (LString "regenerate <file> from this run instead of reporting"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--list-rules")))) (ELit (LString "list every rule with its metadata"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--markdown")))) (ELit (LString "with --list-rules: render docs/ops/LINT-RULES.md"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--scope")))) (ELit (LString "universal|internal"))) (ELit (LString "with --list-rules: keep one scope"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--ratchet")))) (ELit (LString "gated|baselined"))) (ELit (LString "with --list-rules: keep one ratchet"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--tier")))) (ELit (LString "file|cross"))) (ELit (LString "with --list-rules: keep one rule tier"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--names")))) (ELit (LString "with --list-rules: print only the rule names"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--explain")))) (ELit (LString "<rule>"))) (ELit (LString "print a rule's summary and documentation"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--internal")))) (ELit (LString "run the internal-scope rules on every target, manifest or not")))))))
(DTypeSig false "runLintCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLintCmd" ((PVar "argv0")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "lintArgSpec")) (EVar "argv0"))) (DoExpr (EIf (EApp (EApp (EVar "flag") (ELit (LString "--list-rules"))) (EVar "a")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "assertRegistryViewFlags") (ELit (LString "--list-rules"))) (EVar "listRulesBannedFlags")) (EVar "a"))) (DoExpr (EApp (EVar "runLintListRules") (EVar "a")))) (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "flagValue") (ELit (LString "--explain"))) (EVar "a"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "assertRegistryViewFlags") (ELit (LString "--explain"))) (EVar "explainBannedFlags")) (EVar "a"))) (DoExpr (EApp (EVar "runLintExplain") (EVar "a")))) (EBlock (DoLet false false PWild (EApp (EVar "assertNoListOnlyFlags") (EVar "a"))) (DoExpr (EApp (EVar "runLintTargets") (EVar "a")))))))))
(DTypeSig false "lintRunFlags" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "lintRunFlags" () (EListLit (ELit (LString "--fix")) (ELit (LString "--unsafe-fixes")) (ELit (LString "--cache")) (ELit (LString "--internal")) (ELit (LString "--disable")) (ELit (LString "--only")) (ELit (LString "--deny")) (ELit (LString "--baseline")) (ELit (LString "--write-baseline"))))
(DTypeSig false "listRulesBannedFlags" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "listRulesBannedFlags" () (EBinOp "++" (EListLit (ELit (LString "--explain"))) (EVar "lintRunFlags")))
(DTypeSig false "explainBannedFlags" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "explainBannedFlags" () (EBinOp "++" (EListLit (ELit (LString "--json")) (ELit (LString "--markdown")) (ELit (LString "--names")) (ELit (LString "--scope")) (ELit (LString "--ratchet")) (ELit (LString "--tier"))) (EVar "lintRunFlags")))
(DTypeSig false "flagGiven" (TyFun (TyCon "Args") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "flagGiven" ((PVar "a") (PVar "n")) (EBinOp "||" (EApp (EApp (EVar "flag") (EVar "n")) (EVar "a")) (EApp (EVar "isSome") (EApp (EApp (EVar "flagValue") (EVar "n")) (EVar "a")))))
(DTypeSig false "assertRegistryViewFlags" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "assertRegistryViewFlags" ((PVar "mode") (PVar "banned") (PVar "a")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EMethodRef "filter") (EApp (EVar "flagGiven") (EVar "a"))) (EVar "banned"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EFieldAccess (EVar "a") "positionals"))) (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EMethodRef "display") (EVar "mode"))) (ELit (LString " takes no target paths")))) (EIf (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EVar "bad"))) (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "bad")))) (ELit (LString " cannot be combined with "))) (EApp (EMethodRef "display") (EVar "mode"))) (ELit (LString "")))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "mode") (ELit (LString "--list-rules"))) (EApp (EApp (EVar "flag") (ELit (LString "--markdown"))) (EVar "a"))) (EApp (EVar "assertMarkdownTakesNoFilter") (EVar "a")) (ELit LUnit)))))))
(DTypeSig false "assertMarkdownTakesNoFilter" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertMarkdownTakesNoFilter" ((PVar "a")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EMethodRef "filter") (EApp (EVar "flagGiven") (EVar "a"))) (EListLit (ELit (LString "--json")) (ELit (LString "--names")) (ELit (LString "--scope")) (ELit (LString "--ratchet")) (ELit (LString "--tier"))))) (DoExpr (EIf (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EVar "bad"))) (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "bad")))) (ELit (LString " cannot be combined with --markdown")))) (ELit LUnit)))))
(DTypeSig false "assertNoListOnlyFlags" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertNoListOnlyFlags" ((PVar "a")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "flag") (ELit (LString "--markdown"))) (EVar "a")) (EApp (EApp (EVar "flag") (ELit (LString "--names"))) (EVar "a"))) (EApp (EVar "isSome") (EApp (EApp (EVar "flagValue") (ELit (LString "--scope"))) (EVar "a")))) (EApp (EVar "isSome") (EApp (EApp (EVar "flagValue") (ELit (LString "--ratchet"))) (EVar "a")))) (EApp (EVar "isSome") (EApp (EApp (EVar "flagValue") (ELit (LString "--tier"))) (EVar "a")))) (EApp (EVar "dieMsg") (ELit (LString "medaka lint: --markdown/--names/--scope/--ratchet/--tier require --list-rules"))) (ELit LUnit)))
(DTypeSig false "runLintListRules" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLintListRules" ((PVar "a")) (EIf (EApp (EApp (EVar "flag") (ELit (LString "--markdown"))) (EVar "a")) (EApp (EVar "putStr") (EVar "rulesPageMarkdown")) (EBlock (DoLet false false (PVar "picked") (EApp (EApp (EApp (EVar "selectRuleRows") (EApp (EApp (EVar "flagValue") (ELit (LString "--scope"))) (EVar "a"))) (EApp (EApp (EVar "flagValue") (ELit (LString "--ratchet"))) (EVar "a"))) (EApp (EApp (EVar "flagValue") (ELit (LString "--tier"))) (EVar "a")))) (DoExpr (EMatch (EVar "picked") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "rows")) () (EIf (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a")) (EApp (EVar "putStr") (EApp (EVar "renderRuleRowsJson") (EVar "rows"))) (EIf (EApp (EApp (EVar "flag") (ELit (LString "--names"))) (EVar "a")) (EApp (EVar "putStr") (EApp (EVar "renderRuleRowsNames") (EVar "rows"))) (EApp (EVar "putStr") (EApp (EVar "renderRuleRowsText") (EVar "rows")))))))))))
(DTypeSig false "runLintExplain" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLintExplain" ((PVar "a")) (EMatch (EApp (EApp (EVar "optDefault") (EApp (EApp (EVar "flagValue") (ELit (LString "--explain"))) (EVar "a"))) (ELit (LString ""))) (arm (PLit (LString "")) () (EApp (EVar "dieMsg") (ELit (LString "medaka lint: --explain needs a rule name")))) (arm (PVar "name") () (EMatch (EApp (EVar "explainRule") (EVar "name")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "text")) () (EApp (EVar "putStrLn") (EVar "text")))))))
(DTypeSig false "runLintTargets" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLintTargets" ((PVar "a")) (EBlock (DoLet false false (PVar "disableNames") (EApp (EApp (EVar "lintNamesOf") (ELit (LString "--disable"))) (EVar "a"))) (DoLet false false (PVar "onlyNames") (EApp (EApp (EVar "lintNamesOf") (ELit (LString "--only"))) (EVar "a"))) (DoLet false false (PVar "denyNames") (EApp (EApp (EVar "lintNamesOf") (ELit (LString "--deny"))) (EVar "a"))) (DoLet false false PWild (EApp (EVar "assertLintRuleNames") (EBinOp "++" (EBinOp "++" (EVar "disableNames") (EVar "onlyNames")) (EVar "denyNames")))) (DoLet false false (PVar "fixMode") (EApp (EApp (EVar "flag") (ELit (LString "--fix"))) (EVar "a"))) (DoLet false false PWild (EApp (EVar "assertUnsafeFixesNeedFix") (EVar "a"))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "flag") (ELit (LString "--json"))) (EVar "a"))) (DoLet false false (PVar "baselineArg") (EApp (EApp (EVar "flagValue") (ELit (LString "--baseline"))) (EVar "a"))) (DoLet false false (PVar "writeBaselineArg") (EApp (EApp (EVar "flagValue") (ELit (LString "--write-baseline"))) (EVar "a"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "assertBaselineFlagsCoherent") (EVar "baselineArg")) (EVar "writeBaselineArg")) (EVar "fixMode"))) (DoLet false false (PVar "fileArgs") (EFieldAccess (EVar "a") "positionals")) (DoLet false false PWild (EApp (EVar "assertLintTargetsExist") (EVar "fileArgs"))) (DoLet false false (PVar "files") (EApp (EVar "resolveLintTargets") (EVar "fileArgs"))) (DoLet false false PWild (EApp (EVar "assertLintTargetsNonEmpty") (EVar "files"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "assertInternalRulesReachable") (EApp (EApp (EVar "flag") (ELit (LString "--internal"))) (EVar "a"))) (EBinOp "++" (EVar "onlyNames") (EVar "denyNames"))) (EVar "files"))) (DoLet false false (PVar "indexResult") (EApp (EApp (EApp (EApp (EVar "indexForRun") (EApp (EApp (EVar "flag") (ELit (LString "--cache"))) (EVar "a"))) (EVar "onlyNames")) (EVar "disableNames")) (EVar "files"))) (DoExpr (EMatch (EVar "indexResult") (arm (PCon "Err" (PRec "StdlibIndexError" ((rf "path" None) (rf "source" None) (rf "diagnostic" None)) false)) () (EBlock (DoExpr (EIf (EVar "jsonMode") (EApp (EVar "putStr") (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "path") (EVar "source") (EListLit (EVar "diagnostic")))))) (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "source")) (EVar "path")) (EVar "diagnostic"))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "stdlibIdx")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runLintWithIndex") (EVar "stdlibIdx")) (EVar "a")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "fixMode")) (EVar "jsonMode")) (EVar "baselineArg")) (EVar "writeBaselineArg")) (EVar "files")))))))
(DTypeSig false "runLintWithIndex" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Args") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))))))))))
(DFunDef false "runLintWithIndex" ((PVar "stdlibIdx") (PVar "a") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "fixMode") (PVar "jsonMode") (PVar "baselineArg") (PVar "writeBaselineArg") (PVar "files")) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoLet false false (PVar "baseCtx") (EApp (EApp (EVar "loadLintBaselineCtx") (EVar "cwd")) (EVar "baselineArg"))) (DoLet false false (PVar "internalFlag") (EApp (EApp (EVar "flag") (ELit (LString "--internal"))) (EVar "a"))) (DoExpr (EIf (EApp (EVar "isSome") (EVar "writeBaselineArg")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runLintWriteBaselineCmd") (EVar "stdlibIdx")) (EVar "internalFlag")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cwd")) (EApp (EApp (EVar "optDefault") (EVar "writeBaselineArg")) (ELit (LString "")))) (EVar "files")) (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runLintJsonCmd") (EVar "stdlibIdx")) (EVar "internalFlag")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "files")) (EBlock (DoLet false false (PVar "multiFile") (EMatch (EVar "files") (arm (PCons PWild (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False")))) (DoLet false false (PVar "cacheCtx") (EApp (EApp (EVar "lintCacheCtx") (EApp (EApp (EVar "flag") (ELit (LString "--cache"))) (EVar "a"))) (EVar "fixMode"))) (DoLet false false (PVar "run") (ERecordCreate "LintRun" ((fa "lrInternal" (EVar "internalFlag")) (fa "lrFix" (EVar "fixMode")) (fa "lrUnsafe" (EApp (EApp (EVar "flag") (ELit (LString "--unsafe-fixes"))) (EVar "a"))) (fa "lrMulti" (EVar "multiFile"))))) (DoLet false false (PTuple (PVar "perFileErr") (PVar "entries")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "stdlibIdx")) (EVar "run")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "baseCtx")) (EVar "cacheCtx")) (EVar "files")) (EVar "False"))) (DoLet false false (PVar "crossErr") (EIf (EBinOp "&&" (EVar "multiFile") (EApp (EVar "not") (EVar "fixMode"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runProjectReport") (EVar "stdlibIdx")) (EVar "internalFlag")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "entries")) (EVar "False"))) (DoLet false false PWild (EMatch (EVar "cacheCtx") (arm (PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) () (EApp (EApp (EApp (EVar "storeEntries") (EVar "cacheDir")) (EVar "stamp")) (EVar "entries"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EIf (EBinOp "||" (EVar "perFileErr") (EVar "crossErr")) (EApp (EVar "stageExit") (ELit (LInt 1))) (ELit LUnit)))))))))
(DTypeSig false "assertBaselineFlagsCoherent" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "assertBaselineFlagsCoherent" ((PVar "baselineArg") (PVar "writeArg") (PVar "fixMode")) (EIf (EBinOp "&&" (EApp (EVar "isSome") (EVar "baselineArg")) (EApp (EVar "isSome") (EVar "writeArg"))) (EApp (EVar "dieMsg") (ELit (LString "medaka lint: --baseline and --write-baseline are mutually exclusive"))) (EIf (EBinOp "&&" (EApp (EVar "isSome") (EVar "writeArg")) (EVar "fixMode")) (EApp (EVar "dieMsg") (ELit (LString "medaka lint: --write-baseline cannot be combined with --fix"))) (EIf (EBinOp "&&" (EApp (EVar "isSome") (EVar "baselineArg")) (EVar "fixMode")) (EApp (EVar "dieMsg") (ELit (LString "medaka lint: --baseline cannot be combined with --fix"))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "assertUnsafeFixesNeedFix" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertUnsafeFixesNeedFix" ((PVar "a")) (EIf (EBinOp "&&" (EApp (EApp (EVar "flag") (ELit (LString "--unsafe-fixes"))) (EVar "a")) (EApp (EVar "not") (EApp (EApp (EVar "flag") (ELit (LString "--fix"))) (EVar "a")))) (EApp (EVar "dieMsg") (ELit (LString "medaka lint: --unsafe-fixes requires --fix"))) (ELit LUnit)))
(DTypeSig false "loadLintBaselineCtx" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "LintBaseline")))))))
(DFunDef false "loadLintBaselineCtx" (PWild (PCon "None")) (EVar "None"))
(DFunDef false "loadLintBaselineCtx" ((PVar "cwd") (PCon "Some" (PVar "path"))) (EMatch (EApp (EVar "readLintBaseline") (EVar "path")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "None")))) (arm (PCon "Ok" (PVar "base")) () (EApp (EVar "Some") (ETuple (EVar "cwd") (EVar "base"))))))
(DTypeSig false "runLintWriteBaselineCmd" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))))))))
(DFunDef false "runLintWriteBaselineCmd" ((PVar "idx") (PVar "internalFlag") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "cwd") (PVar "out") (PVar "files")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "idx")) (EVar "internalFlag")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "None")) (EVar "files"))) (DoLet false false (PVar "parseFailures") (EApp (EApp (EDictApp "flatMap") (EVar "lintBaselineParseFailures")) (EVar "triples"))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "parseFailures")) (ELit (LInt 0))) (EBlock (DoExpr (EApp (EVar "emitWarningLines") (EVar "parseFailures"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "perFile") (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EApp (EVar "baselineFileCodes") (EVar "cwd")) (EVar "t")))) (EVar "triples"))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "out")) (EApp (EVar "renderLintBaseline") (EVar "perFile"))) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: cannot write `")) (EApp (EMethodRef "display") (EVar "out"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "Ok" PWild) () (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: wrote ")) (EApp (EMethodRef "display") (EVar "out"))) (ELit (LString " from "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "files"))))) (ELit (LString " file(s)"))))))))))))
(DTypeSig false "lintBaselineParseFailures" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lintBaselineParseFailures" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path"))) (EApp (EApp (EMethodRef "filter") (EVar "isLintParseDiagnostic")) (EVar "diags"))))
(DTypeSig false "isLintParseDiagnostic" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isLintParseDiagnostic" ((PCon "Diag" PWild (PVar "code") PWild PWild PWild PWild)) (EApp (EVar "diagIdIsSyntax") (EVar "code")))
(DTypeSig false "lintNamesOf" (TyFun (TyCon "String") (TyFun (TyCon "Args") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "lintNamesOf" ((PVar "nm") (PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (EVar "nm")) (EVar "a")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "splitLintNames") (EVar "v")))))
(DTypeSig false "assertLintRuleNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertLintRuleNames" ((PVar "names")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "allRuleNames"))))) (EVar "names"))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "bad")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: unknown rule ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "bad")))) (ELit (LString " (known: "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "allRuleNames")))) (ELit (LString ")"))))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))))))
(DTypeSig false "assertInternalRulesReachable" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "assertInternalRulesReachable" ((PVar "internalFlag") (PVar "names") (PVar "files")) (EMatch (EApp (EApp (EApp (EVar "inactiveInternalRuleUse") (EVar "internalFlag")) (EVar "names")) (EVar "files")) (arm (PCon "Some" (PVar "msg")) () (EApp (EVar "dieMsg") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "assertLintTargetsNonEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertLintTargetsNonEmpty" ((PCons PWild PWild)) (ELit LUnit))
(DFunDef false "assertLintTargetsNonEmpty" ((PList)) (EApp (EVar "dieMsg") (ELit (LString "medaka lint: no .mdk files found"))))
(DTypeSig false "assertLintTargetsExist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertLintTargetsExist" ((PList)) (ELit LUnit))
(DFunDef false "assertLintTargetsExist" ((PVar "targets")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "t")) (EApp (EVar "not") (EApp (EVar "lintTargetExists") (EVar "t"))))) (EVar "targets"))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "missing")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: these targets do not exist:")))) (DoExpr (EApp (EVar "dieMsg") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (EVar "missing"))))))))))
(DTypeSig false "assertSnapshotTargetsExist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertSnapshotTargetsExist" ((PVar "files")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "f"))))) (EVar "files"))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "missing")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: these targets do not exist:")))) (DoExpr (EApp (EVar "dieMsg") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (EVar "missing"))))))))))
(DTypeSig false "assertBlessIsScoped" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "assertBlessIsScoped" ((PVar "blessOn") (PVar "targets")) (EIf (EBinOp "||" (EApp (EVar "not") (EVar "blessOn")) (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EVar "targets")))) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: --bless requires explicit targets; there is no whole-suite bless")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "  name what you are approving, such as:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "    medaka snapshot --bless --out test/snapshots/compiler compiler/frontend/lexer.mdk")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "  or, family-aware: sh test/snapshot_bless.sh --bless compiler/frontend/lexer.mdk")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))))
(DTypeSig false "snapshotHelpText" (TyCon "String"))
(DFunDef false "snapshotHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka snapshot — Per-stage snapshot tests\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka snapshot [--check | --new | --bless] <paths...>\n")) (ELit (LString "                  [--out <dir>] [--stages <a,b,...>] [--isolate]\n")) (ELit (LString "\n")) (ELit (LString "One mode is REQUIRED, and the three are mutually exclusive:\n")) (ELit (LString "  --check   compare against the existing snapshot; write nothing\n")) (ELit (LString "  --new     create a MISSING snapshot; never touch an existing one\n")) (ELit (LString "  --bless   rewrite an EXISTING snapshot; never create one; requires\n")) (ELit (LString "            explicit targets (no whole-suite bless)\n")) (ELit (LString "\n")) (ELit (LString "  --out <dir>       snapshot directory (default derived from MEDAKA_ROOT)\n")) (ELit (LString "  --root <dir>      compiler/stdlib root, overriding MEDAKA_ROOT\n")) (ELit (LString "  --stages a,b,...  restrict to the named stages (default: every stage)\n")) (ELit (LString "  --isolate         run one process per fixture (debug aid for a crasher)\n")) (ELit (LString "\n")) (ELit (LString "  --worker          INTERNAL, not for direct use: the supervisor re-spawns\n")) (ELit (LString "                    this binary with --worker to render one batch in a child\n")) (ELit (LString "                    process, so a fixture that crashes the renderer does not\n")) (ELit (LString "                    take the run down. Documented because the verb parses it\n")) (ELit (LString "                    (an undocumented arm is a lie by omission), not because\n")) (ELit (LString "                    you should type it.\n")) (ELit (LString "\n")) (ELit (LString "A path may be a file or directory (recursively expanded).\n")))))
(DTypeSig false "snapshotArgSpec" (TyCon "ArgSpec"))
(DFunDef false "snapshotArgSpec" () (EApp (EVar "withStrictDash") (EApp (EApp (EVar "spec") (ELit (LString "snapshot"))) (EListLit (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--check")))) (ELit (LString "compare against the existing snapshot; write nothing"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--new")))) (ELit (LString "create a MISSING snapshot; never touch an existing one"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--bless")))) (ELit (LString "rewrite an EXISTING snapshot; requires explicit targets"))) (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--isolate")))) (ELit (LString "run one process per fixture"))) (EApp (EVar "internal") (EApp (EApp (EVar "switch") (EListLit (ELit (LString "--worker")))) (ELit (LString "INTERNAL: render one batch in a child process")))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--out")))) (ELit (LString "DIR"))) (ELit (LString "snapshot directory"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--root")))) (ELit (LString "DIR"))) (ELit (LString "compiler/stdlib root, overriding MEDAKA_ROOT"))) (EApp (EApp (EApp (EVar "value") (EListLit (ELit (LString "--stages")))) (ELit (LString "a,b,..."))) (ELit (LString "restrict to the named stages")))))))
(DTypeSig false "runSnapshotCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runSnapshotCmd" ((PVar "argv0")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "requireArgs") (EVar "snapshotArgSpec")) (EVar "argv0"))) (DoLet false false (PVar "root") (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--root"))) (EVar "a")) (arm (PCon "Some" (PVar "r")) () (EVar "r")) (arm (PCon "None") () (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))))) (DoLet false false (PVar "sel") (EApp (EVar "snapshotStages") (EVar "a"))) (DoLet false false (PVar "targets") (EFieldAccess (EVar "a") "positionals")) (DoLet false false PWild (EApp (EApp (EVar "assertBlessIsScoped") (EApp (EApp (EVar "flag") (ELit (LString "--bless"))) (EVar "a"))) (EVar "targets"))) (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoLet false false PWild (EApp (EVar "assertSnapshotTargetsExist") (EVar "files"))) (DoExpr (EIf (EApp (EMethodRef "isEmpty") (EVar "files")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka snapshot [--check|--new|--bless] [--out <dir>] [--stages <a,b,…>] <paths...>")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1))))) (EIf (EApp (EApp (EVar "flag") (ELit (LString "--worker"))) (EVar "a")) (EApp (EApp (EApp (EVar "runSnapshotWorker") (EVar "root")) (EVar "sel")) (EVar "files")) (EMatch (EApp (EVar "snapshotMode") (EVar "a")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: pass --check, --new or --bless; exactly one mode is required")))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 1)))))) (arm (PCon "Some" (PVar "mode")) () (EBlock (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSnapshotSupervisor") (EVar "root")) (EVar "mode")) (EApp (EApp (EVar "flag") (ELit (LString "--isolate"))) (EVar "a"))) (EApp (EApp (EVar "flagValue") (ELit (LString "--out"))) (EVar "a"))) (EVar "sel")) (EVar "files"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "stageExit") (ELit (LInt 1)))))))))))))
(DTypeSig false "snapshotMode" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "SnapMode")))))
(DFunDef false "snapshotMode" ((PVar "a")) (EBlock (DoLet false false (PVar "modes") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EApp (EVar "flag") (EVar "f")) (EVar "a")))) (EListLit (ELit (LString "--check")) (ELit (LString "--new")) (ELit (LString "--bless"))))) (DoExpr (EMatch (EVar "modes") (arm (PList (PLit (LString "--check"))) () (EApp (EVar "Some") (EVar "SnapCheck"))) (arm (PList (PLit (LString "--new"))) () (EApp (EVar "Some") (EVar "SnapNew"))) (arm (PList (PLit (LString "--bless"))) () (EApp (EVar "Some") (EVar "SnapBless"))) (arm (PList) () (EVar "None")) (arm (PVar "many") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka snapshot: ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "many")))) (ELit (LString " are mutually exclusive; pass one"))))) (DoLet false false PWild (EApp (EVar "stageExit") (ELit (LInt 1)))) (DoExpr (EVar "None"))))))))
(DTypeSig false "snapshotStages" (TyFun (TyCon "Args") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "snapshotStages" ((PVar "a")) (EMatch (EApp (EApp (EVar "flagValue") (ELit (LString "--stages"))) (EVar "a")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "spec")) () (EMatch (EApp (EVar "parseStages") (EVar "spec")) (arm (PCon "Ok" (PVar "names")) () (EVar "names")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka snapshot: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "stageExit") (ELit (LInt 1)))) (DoExpr (EListLit))))))))
(DTypeSig false "hasSlash" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasSlash" ((PVar "s")) (EApp (EApp (EVar "hasSlashFrom") (EVar "s")) (EApp (EVar "stringLength") (EVar "s"))))
(DTypeSig false "hasSlashFrom" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "hasSlashFrom" (PWild (PLit (LInt 0))) (EVar "False"))
(DFunDef false "hasSlashFrom" ((PVar "s") (PVar "i")) (EBinOp "||" (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "s")) (ELit (LString "/"))) (EApp (EApp (EVar "hasSlashFrom") (EVar "s")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "dirOf2" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOf2" ((PVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo2" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo2" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo2" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "replArgSpec" (TyCon "ArgSpec"))
(DFunDef false "replArgSpec" () (EApp (EApp (EVar "spec") (ELit (LString "repl"))) (EListLit)))
(DTypeSig false "replUsageLine" (TyCon "String"))
(DFunDef false "replUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka repl — Start the interactive REPL\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka repl     Start an interactive session that reads expressions\n")) (ELit (LString "                 from stdin, evaluates them, and prints results until\n")) (ELit (LString "                 stdin closes (EOF) or you enter :quit.\n")))))
(DTypeSig false "runReplCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runReplCmd" ((PList)) (EBlock (DoLet false false PWild (EApp (EApp (EVar "carryTargetProfile") (EVar "None")) (EBinOp "++" (EApp (EVar "canonicalizePath") (ELit (LString "."))) (ELit (LString "/repl"))))) (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "r") (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readPreludeSources") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib"))))) (ELam ((PVar "prelude")) (ELet false (PVar "runtimeDecls") (EApp (EVar "desugaredPrelude") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (ELet false (PVar "preludeDecls") (EApp (EVar "desugaredPrelude") (EFieldAccess (EVar "prelude") "pnCoreSrc")) (ELet false PWild (EApp (EApp (EVar "initSession") (EVar "runtimeDecls")) (EVar "preludeDecls")) (ELet false PWild (EApp (EApp (EVar "takeShippedPrelude") (EVar "unstaged")) (EVar "prelude")) (EApp (EVar "Ok") (EApp (EVar "replLoop") (ELit LUnit)))))))))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "v")) () (EVar "v"))))))
(DFunDef false "runReplCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "runReplCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "runReplCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "unknownFlagMessage") (EVar "replArgSpec")) (EVar "bad")))) (DoExpr (EApp (EVar "dieMsg") (EVar "replUsageLine")))))
(DTypeSig false "lspArgSpec" (TyCon "ArgSpec"))
(DFunDef false "lspArgSpec" () (EApp (EApp (EVar "spec") (ELit (LString "lsp"))) (EListLit)))
(DTypeSig false "lspUsageLine" (TyCon "String"))
(DFunDef false "lspUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka lsp — Run the Language Server Protocol server over stdio\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka lsp     Start the server; it reads JSON-RPC requests from stdin\n")) (ELit (LString "                 and writes responses to stdout until stdin closes (EOF).\n")) (ELit (LString "                 This is the normal, correct behavior for an LSP stdio\n")) (ELit (LString "                 server — it is not supposed to be interactive.\n")))))
(DTypeSig false "runLspCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLspCmd" ((PList)) (EApp (EVar "runLspServerFromEnv") (ELit LUnit)))
(DFunDef false "runLspCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "runLspCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "runLspCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "unknownFlagMessage") (EVar "lspArgSpec")) (EVar "bad")))) (DoExpr (EApp (EVar "dieMsg") (EVar "lspUsageLine")))))
(DTypeSig false "runLspServerFromEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLspServerFromEnv" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "r") (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readPreludeSources") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib"))))) (ELam ((PVar "prelude")) (ELet false PWild (EApp (EVar "loadCheckPrelude") (EVar "prelude")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "runServer") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (EFieldAccess (EVar "prelude") "pnCoreSrc")) (EVar "medakaVersion"))))))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "v")) () (EVar "v"))))))
(DTypeSig false "mcpArgSpec" (TyCon "ArgSpec"))
(DFunDef false "mcpArgSpec" () (EApp (EApp (EVar "spec") (ELit (LString "mcp"))) (EListLit)))
(DTypeSig false "mcpUsageLine" (TyCon "String"))
(DFunDef false "mcpUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka mcp — Run the MCP server over stdio (JSON-RPC for agents)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka mcp     Start the server; it reads JSON-RPC requests from stdin\n")) (ELit (LString "                 and writes responses to stdout until stdin closes (EOF).\n")) (ELit (LString "                 This is the normal, correct behavior for an MCP stdio\n")) (ELit (LString "                 server — it is not supposed to be interactive.\n")))))
(DTypeSig false "runMcpCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runMcpCmd" ((PList)) (EApp (EVar "runMcpServerFromEnv") (ELit LUnit)))
(DFunDef false "runMcpCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "mcpUsageLine"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "runMcpCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "mcpUsageLine"))) (DoExpr (EApp (EVar "stageExit") (ELit (LInt 0))))))
(DFunDef false "runMcpCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EVar "unknownFlagMessage") (EVar "mcpArgSpec")) (EVar "bad")))) (DoExpr (EApp (EVar "dieMsg") (EVar "mcpUsageLine")))))
(DTypeSig false "runMcpServerFromEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runMcpServerFromEnv" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "r") (EApp (EApp (EMethodRef "andThen") (EApp (EVar "readPreludeSources") (EVar "stdlibDir"))) (ELam ((PVar "prelude")) (ELet false PWild (EApp (EVar "loadCheckPrelude") (EVar "prelude")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EVar "runMcpServer") (EFieldAccess (EVar "prelude") "pnRuntimeSrc")) (EFieldAccess (EVar "prelude") "pnCoreSrc")) (EVar "stdlibDir")) (EVar "sourceStalenessVerdict")) (EVar "medakaVersion"))))))) (DoExpr (EMatch (EVar "r") (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "dieMsg") (EVar "msg"))) (arm (PCon "Ok" (PVar "v")) () (EVar "v"))))))
